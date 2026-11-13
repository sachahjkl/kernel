package kerneltool

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:thread"
import "core:time"

// How the machine test sends input and saves pictures
// (docs/TOOLS.md, "How the tool sends input and waits").
//
// The keys and the moves of the pointer go to the virtual keyboard and the
// virtual mouse of QEMU, several in one command, and the tool then waits
// for a condition: the system read each byte of the devices, or the
// compositor received each record. One wait of this file is a fixed time:
// the one before a picture, which its constant explains.

// The period of the poll of a condition that the tool reads through QEMU
// or through the remote service: the time between two reads, never the
// time of a wait.
CONDITION_POLL_PERIOD :: time.Millisecond
// The period of the poll of the log of the machine when no change of the
// file woke the wait (log_watch_linux.odin).
LOG_POLL_PERIOD :: 50 * time.Millisecond
// The time before a picture of the screen, for the program whose window
// the picture shows: the program draws after the line of the log that the
// step before waited for, and nothing that the tool reads says when its
// last picture is on the screen
// (docs/TOOLS.md, "How the tool sends input and waits").
PICTURE_SETTLE_PAUSE :: 400 * time.Millisecond

// log_change_wait ends when the log of the machine changed, or after
// LOG_POLL_PERIOD: the caller reads the log again.
log_change_wait :: proc(machine: ^Machine) {
	log_watch_wait(&machine.log_watch, machine.output)
}

// machine_command_send sends one command of input to QEMU. A machine that
// ended takes no input and is no failure here: the system stopped it, or
// the next step that waits for it fails with its own message.
machine_command_send :: proc(machine: ^Machine, command: string) -> bool {
	_, sent := qmp_command(&machine.qmp, command)
	return sent || machine.qmp.ended
}

// controller_status_read reads the status of the keyboard controller of
// the machine through the monitor of QEMU. The read changes nothing in the
// controller.
controller_status_read :: proc(machine: ^Machine) -> (status: u8, ok: bool) {
	printed, answered := qmp_command(&machine.qmp, qmp_monitor_command(CONTROLLER_STATUS_LINE))
	if !answered {
		// A machine that ended holds no byte: the end of the test checks
		// how it ended.
		return 0, machine.qmp.ended
	}
	status, ok = controller_status_parse(printed)
	if !ok {
		fmt.eprintfln("kerneltool: test failed: the monitor of QEMU printed %s for \"%s\", not the status of the keyboard controller", printed, CONTROLLER_STATUS_LINE)
	}
	return status, ok
}

// input_read_wait waits until the system read each byte that the virtual
// keyboard and the virtual mouse hold: the keyboard controller then says
// that it holds no byte.
input_read_wait :: proc(machine: ^Machine) -> bool {
	for start := time.tick_now(); time.tick_since(start) < HANG_BOUND; {
		status := controller_status_read(machine) or_return
		if status & CONTROLLER_OUTPUT_FULL == 0 {
			machine.device_bytes = 0
			return true
		}
		time.sleep(CONDITION_POLL_PERIOD)
	}
	fmt.eprintfln("kerneltool: test failed: the system did not read the bytes of the keyboard controller within %v: the tool sent %d bytes of keys and of moves that wait there", HANG_BOUND, machine.device_bytes)
	return false
}

// input_room_wait makes room for bytes more in the queue of a virtual
// device: when the bytes that the tool sent since the queues were empty,
// with these, are more than a queue holds, it waits until the system read
// them all. QEMU drops a byte that finds the queue full.
input_room_wait :: proc(machine: ^Machine, bytes: int) -> bool {
	if machine.device_bytes + bytes > DEVICE_QUEUE_BYTES {
		input_read_wait(machine) or_return
	}
	machine.device_bytes += bytes
	return true
}

// key_records_read gives the count of the key records that the compositor
// received, through the remote service.
key_records_read :: proc(machine: ^Machine) -> (count: i64, ok: bool) {
	values := record_fields(&machine.client, "compositor.pointer()", {"keys"}) or_return
	return values[0], true
}

// keys_send presses and releases each key of a list of names of the
// scenario ("a", "shift-a", "ret"), in order. The keys of one command fit
// in the queue of the virtual keyboard, which holds few bytes: the tool
// sends the next command when the system read the bytes before. what
// names the step in a message of failure.
//
// The condition after the last command: when the tool can call the
// compositor (machine.confirm), the count of its key records grew by the
// records of the list, one for each press and each release; else, and
// when the scenario revoked the grant of remote or remote stopped during
// the keys, the system read each byte of the keyboard.
keys_send :: proc(machine: ^Machine, names: []string, what: string) -> bool {
	keys_started := time.tick_now()
	defer test_times_keys_note(machine, len(names), keys_started)
	before: i64
	counted := false
	if machine.confirm {
		before, counted = key_records_read(machine)
	}
	for chunk in key_chunks(names) {
		bytes := 0
		for name in chunk {
			bytes += key_device_bytes(name)
		}
		input_room_wait(machine, bytes) or_return
		machine_command_send(machine, qmp_key_events_command(chunk)) or_return
	}
	if !counted {
		return input_read_wait(machine)
	}
	wanted := before + key_record_count(names)
	received := before
	for start := time.tick_now(); time.tick_since(start) < HANG_BOUND; {
		now, read := key_records_read(machine)
		if !read {
			return input_read_wait(machine)
		}
		received = now
		if received >= wanted {
			// The compositor has each record: the input service read each byte.
			machine.device_bytes = 0
			machine.keys_confirmed += len(names)
			machine.key_batches_confirmed += 1
			return true
		}
		time.sleep(CONDITION_POLL_PERIOD)
	}
	fmt.eprintfln("kerneltool: test failed: the compositor received %d of the %d key records of %s within %v (a press and a release are one record each)", received - before, wanted - before, what, HANG_BOUND)
	return false
}

// pointer_packet_send sends one command that makes one packet of the
// virtual mouse: a move or a change of a button.
pointer_packet_send :: proc(machine: ^Machine, command: string) -> bool {
	input_room_wait(machine, POINTER_PACKET_BYTES) or_return
	machine_command_send(machine, command) or_return
	machine.pointer_packets += 1
	return true
}

// pointer_move_blind moves the pointer from the place that the tool
// believes, with relative moves of the virtual mouse, one packet for each.
pointer_move_blind :: proc(machine: ^Machine, x, y: int) -> bool {
	for machine.x != x || machine.y != y {
		step_x := clamp(x - machine.x, -MOUSE_STEP, MOUSE_STEP)
		step_y := clamp(y - machine.y, -MOUSE_STEP, MOUSE_STEP)
		pointer_packet_send(machine, qmp_pointer_move_command(step_x, step_y)) or_return
		machine.x += step_x
		machine.y += step_y
	}
	return true
}

// pointer_corner_push pushes the pointer to the top left corner of the
// screen, from a place that the tool does not know: the compositor keeps
// the pointer on the screen.
pointer_corner_push :: proc(machine: ^Machine) -> bool {
	for _ in 0 ..< 40 {
		pointer_packet_send(machine, qmp_pointer_move_command(-100, -100)) or_return
	}
	return true
}

// POINTER_TRIES: the moves to one place before the tool says that the
// pointer is not where a step wants it. It is a count, not a time.
POINTER_TRIES :: 6

@(private = "file")
Pointer_Read :: struct {
	x, y:  i64,
	moves: i64, // The pointer records that the compositor received.
}

@(private = "file")
pointer_read :: proc(machine: ^Machine) -> (read: Pointer_Read, ok: bool) {
	values := record_fields(&machine.client, "compositor.pointer()", {"x", "y", "moves"}) or_return
	return Pointer_Read{values[0], values[1], values[2]}, true
}

@(private = "file")
pointer_confirmed :: proc(machine: ^Machine, x, y: int, try: int, started: time.Tick) -> bool {
	machine.x, machine.y = x, y
	append(&machine.confirmations, time.tick_since(started))
	if try > 0 {
		machine.corrected += 1
	}
	return true
}

// pointer_confirm moves the pointer to (x, y) and reads its place from the
// compositor, through the remote service, until it is there. After the
// packets of a move, it waits until the compositor has the place, or
// received each packet: a pointer that is elsewhere then moves again from
// the place that the compositor gives. When remote does not answer (the
// scenario revoked its grant, or it stopped), the move is blind.
pointer_confirm :: proc(machine: ^Machine, x, y: int) -> bool {
	started := time.tick_now()
	found: Pointer_Read
	for try in 0 ..< POINTER_TRIES {
		before, read := pointer_read(machine)
		if !read {
			return pointer_move_blind(machine, x, y) && input_read_wait(machine)
		}
		found = before
		if before.x == i64(x) && before.y == i64(y) {
			return pointer_confirmed(machine, x, y, try, started)
		}
		// The pointer is where the compositor says: move from there.
		machine.x, machine.y = int(before.x), int(before.y)
		packets_before := machine.pointer_packets
		pointer_move_blind(machine, x, y) or_return
		wanted := before.moves + i64(machine.pointer_packets - packets_before)
		arrived := false
		for start := time.tick_now(); !arrived && time.tick_since(start) < HANG_BOUND; {
			now, now_read := pointer_read(machine)
			if !now_read {
				return input_read_wait(machine)
			}
			found = now
			if now.x == i64(x) && now.y == i64(y) {
				return pointer_confirmed(machine, x, y, try, started)
			}
			if arrived = now.moves >= wanted; !arrived {
				time.sleep(CONDITION_POLL_PERIOD)
			}
		}
		if !arrived {
			fmt.eprintfln("kerneltool: test failed: the compositor received %d of the %d pointer records of a move to %d,%d within %v", found.moves - before.moves, wanted - before.moves, x, y, HANG_BOUND)
			return false
		}
	}
	fmt.eprintfln("kerneltool: test failed: the pointer is at %d,%d after %d tries, not at %d,%d", found.x, found.y, POINTER_TRIES, x, y)
	return false
}

// pointer_move moves the pointer to (x, y). When the tool can read the
// place, it confirms it; else it waits until the system read each packet
// of the move.
pointer_move :: proc(machine: ^Machine, x, y: int) -> bool {
	if machine.confirm {
		return pointer_confirm(machine, x, y)
	}
	return pointer_move_blind(machine, x, y) && input_read_wait(machine)
}

// pointer_button presses or releases the left button. The condition: the
// compositor has the button in that state, when the tool can read it;
// else the system read the packet.
pointer_button :: proc(machine: ^Machine, down: bool) -> bool {
	pointer_packet_send(machine, qmp_pointer_button_command(down)) or_return
	if !machine.confirm {
		return input_read_wait(machine)
	}
	for start := time.tick_now(); time.tick_since(start) < HANG_BOUND; {
		values, read := record_fields(&machine.client, "compositor.pointer()", {"buttons"})
		if !read {
			// The press ended remote or its grant: the other condition.
			return input_read_wait(machine)
		}
		if (values[0] & 1 != 0) == down {
			return true
		}
		time.sleep(CONDITION_POLL_PERIOD)
	}
	fmt.eprintfln("kerneltool: test failed: the compositor did not see the left button %s within %v", down ? "down" : "up", HANG_BOUND)
	return false
}

// One picture of the screen that a worker thread turns into a PNG file,
// while the scenario goes on.
Picture_Job :: struct {
	worker:     ^thread.Thread,
	path:       string,
	width:      int,
	height:     int,
	file:       []u8, // The file that QEMU wrote.
	pixels:     []u8, // The pixels, in file.
	step_place: int, // The place of the record of its step in the times of the test.
	failure:    string, // Why the PNG file is not written, or "".
	bytes:      int, // The bytes of the PNG file.
	conversion: time.Duration,
	write:      time.Duration,
}

@(private = "file")
picture_job_run :: proc(job: ^Picture_Job) {
	defer free_all(context.temp_allocator)
	started := time.tick_now()
	file, encode_error := png_encode(job.width, job.height, 3, job.pixels)
	job.conversion = time.tick_since(started)
	if encode_error != nil {
		job.failure = fmt.aprintf("cannot encode %s: %v", job.path, encode_error)
		return
	}
	write_started := time.tick_now()
	if write_error := os.write_entire_file(job.path, file); write_error != nil {
		job.failure = fmt.aprintf("cannot write %s: %v", job.path, write_error)
		return
	}
	job.write = time.tick_since(write_started)
	job.bytes = len(file)
}

// screen_save saves the screen of the machine as a PNG file. QEMU writes
// the picture in a file and replies when the file is whole; a worker
// thread then makes the PNG file, and pictures_join gives its result.
screen_save :: proc(machine: ^Machine, name: string) -> bool {
	picture_started := time.tick_now()
	time.sleep(PICTURE_SETTLE_PAUSE)
	dump_started := time.tick_now()
	_ = os.remove(SCREEN_DUMP)
	if _, dumped := qmp_command(&machine.qmp, qmp_screendump_command(SCREEN_DUMP)); !dumped {
		fmt.eprintln("kerneltool: QEMU did not save the screen")
		return false
	}
	read_started := time.tick_now()
	// Not in the temporary allocator: the worker reads the bytes after the
	// scenario freed it.
	dump, read_error := os.read_entire_file(SCREEN_DUMP, context.allocator)
	if read_error != nil {
		fmt.eprintfln("kerneltool: cannot read %s: %v", SCREEN_DUMP, read_error)
		return false
	}
	// "P6", width, height, 255, one space character, then the bytes.
	position := 0
	fields: [4]string
	for &field in fields {
		for position < len(dump) && (dump[position] == ' ' || dump[position] == '\n') {
			position += 1
		}
		start := position
		for position < len(dump) && dump[position] != ' ' && dump[position] != '\n' {
			position += 1
		}
		field = string(dump[start:position])
	}
	position += 1
	width, _ := strconv.parse_int(fields[1])
	height, _ := strconv.parse_int(fields[2])
	if fields[0] != "P6" || width <= 0 || height <= 0 || len(dump) - position < width * height * 3 {
		fmt.eprintfln("kerneltool: QEMU wrote %s, which is not a whole picture of the screen (%d bytes)", SCREEN_DUMP, len(dump))
		delete(dump)
		return false
	}
	job := new(Picture_Job)
	job^ = {
		path       = fmt.aprintf("%s/%s.png", SCREENSHOT_FOLDER, name),
		width      = width,
		height     = height,
		file       = dump,
		pixels     = dump[position:][:width * height * 3],
		step_place = len(test_times.steps),
	}
	test_times_picture_note(machine, {settle = time.tick_diff(picture_started, dump_started), dump = time.tick_diff(dump_started, read_started), read = time.tick_since(read_started)})
	job.worker = thread.create_and_start_with_poly_data(job, picture_job_run)
	append(&machine.picture_jobs, job)
	return true
}

// pictures_join waits for the worker of each picture of the machine, and
// says if each PNG file is written. It adds the time of each conversion
// and of each write to the times of the step of its picture.
pictures_join :: proc(machine: ^Machine) -> bool {
	written := true
	for job in machine.picture_jobs {
		thread.join(job.worker)
		thread.destroy(job.worker)
		if job.failure != "" {
			fmt.eprintfln("kerneltool: test failed: %s", job.failure)
			written = false
		} else {
			fmt.printfln("kerneltool: screen saved: %s (%dx%d, %d bytes)", job.path, job.width, job.height, job.bytes)
		}
		test_times_picture_worker_note(job.step_place, job.conversion, job.write)
		delete(job.failure)
		delete(job.path)
		delete(job.file)
		free(job)
	}
	clear(&machine.picture_jobs)
	return written
}
