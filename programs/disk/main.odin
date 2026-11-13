// A check and a measure of the block service (contract/block), on a disk
// of its own: the disk of the measures, that holds no data of a program.
//
// The program reads and writes blocks in five runs: one block in each
// request, with one request in flight and then with 32. The check sends a
// fixed count of requests in each run, and no request must fail. In a
// [measure run](term:measure-run) each run goes on for one second, and
// the program writes the blocks in one second. In the two it
// counts the kernel entries of the two programs for each
// request: its own entries (the system library counts them) and those of
// the block service (the command Statistics). Then it writes a pattern,
// flushes, reads it back and compares.
//
// **What it is for.** It measures the cost of a disk under this design: a
// [block service](term:block-service) that is a program, a
// [block ring](term:block-ring) between two programs, and a
// [data region](term:data-region) that the device reads and writes
// directly. The kernel entries for each request show that the kernel is
// not on the path of the data: an entry is a wait or a wake, and one entry
// serves many requests when several are in flight.
//
// **What a reader sees.** Start it from the menu of the programs, or with
// `start("disk")` in the console. The window has one row for each of the
// five runs: a read or a write, the blocks in each request, the
// requests in flight, a bar of the requests that the check sent, and a bar
// of the kernel entries of this program and of the block service for 100
// requests. In a measure run (`kerneltool measure disk`) the first bar is
// the blocks in one second. Its lines in the log:
//
// - `disk: ok, the disk has <count> blocks, 64 blocks in one request at
//   most`;
// - one line for each run: `disk: read, 1 block in each request, 32 in
//   flight: 256 requests, ...`; in a measure run: `... 32 in flight: <rate>
//   blocks in one second, ...`;
// - `disk: a read of 2 blocks from the last block: ...`, the error record of
//   a read past the end of the disk, which the program checks field by
//   field;
// - `disk: ok, 5 runs, 0 errors, write then read back: 0 wrong`, or
//   `disk: wrong: ...`.
//
// **Its grant**: **Scratch_Disk**: a block service of the
// [disk of the measures](term:disk-of-the-measures), and its block ring.
// The disk holds no data of a program, so the measure writes over it. The
// program has no store and no other disk.
//
// **What it does not prove.** The numbers are those of virtio under QEMU on
// the host of the run, not of a real disk: they are printed as measures,
// and no test compares them to a bound. The measures use the first 4096
// blocks (16 MiB) of the disk only.
package disk

import "contract:block"
import "contract:errors"
import "contract:ring"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:system"

// The window is built with the interface package (docs/INTERFACE.md).
records_now, records_before: [512]interface.Draw_Record
text_now, text_before: [8192]u8
drawing: interface.Window_Drawing

DURATION :: 1000 // Milliseconds of one measure, in a measure run.
REQUESTS_CHECKED :: 256 // The requests of one run of the check.
REGION_PAGES :: 256 // The data region: 1 MiB.
MEASURE_BLOCKS :: 4096 // The blocks that the measures use, from block 0: 16 MiB.

LINE :: 24
BAR_WIDTH :: 200
RATE_X :: 300
ENTRIES_X :: RATE_X + BAR_WIDTH + 90
WIDTH :: ENTRIES_X + BAR_WIDTH + 70
HEIGHT :: 12 + 4 * LINE + len(measures) * LINE + 3 * LINE + 12

COLOR_RATE :: 0x58D878
COLOR_ENTRIES :: 0xE0A040

Measure :: struct {
	write:   bool,
	depth:   u32, // Requests in flight.
	blocks:  u64, // Blocks in each request.
	done:    bool,
	requests: u64, // The requests that the run sent and that were answered.
	rate:    u64, // Blocks in one second: a measure run only.
	client:  u64, // Kernel entries of this program for 100 requests.
	service: u64, // Kernel entries of the block service for 100 requests.
	errors:  u64,
}

measures := [?]Measure {
	{write = false, depth = 1, blocks = 1},
	{write = false, depth = 32, blocks = 1},
	{write = true, depth = 1, blocks = 1},
	{write = true, depth = 32, blocks = 1},
	{write = false, depth = 8, blocks = 16},
}

blocks: ring.Ring
region: [^]u8
disk_blocks: u64
wrong: u64 // The bytes of the check that did not read back as written, and its requests that failed.
statistics_tag: u32 = 1 << 31

// request sends one command, and waits for room if the queue is full.
request :: proc "contextless" (command: block.Command, tag: u32, values: [7]u64 = {}) {
	record := ring.Record{kind = u32(command), tag = tag, values = values}
	for !system.send(&blocks.commands, record) {
		wait: system.Wait
		system.wait_room(&wait, &blocks.commands)
		system.wait_end(&wait)
	}
}

// answer waits for the next completion.
answer :: proc "contextless" () -> ring.Record {
	for {
		if record, ok := system.receive(&blocks.completions); ok {
			return record
		}
		wait: system.Wait
		system.wait_records(&wait, &blocks.completions)
		if !system.wait_spin(&wait) {
			system.wait_end(&wait)
		}
	}
}

// call sends one command and waits for its completion.
call :: proc "contextless" (command: block.Command, values: [7]u64 = {}) -> ring.Record {
	statistics_tag += 1
	request(command, statistics_tag, values)
	for {
		record := answer()
		if record.tag == statistics_tag {
			return record
		}
	}
}

// service_entries gives the kernel entries of the block service so far,
// from the command `Statistics`.
service_entries :: proc "contextless" () -> u64 {
	return call(.Statistics).values[2]
}

// run keeps `measure.depth` requests in flight, each of `measure.blocks`
// blocks, at places that walk the first 4096 blocks of the disk. The check
// ends after REQUESTS_CHECKED answers; a measure run goes on for one
// second, and has the rate. It writes the kernel entries of the two
// programs for 100 requests and the failed requests into the record, and
// one line on the log.
run :: proc "contextless" (measure: ^Measure) {
	measured := system.measure_run()
	command := measure.write ? block.Command.Write : block.Command.Read
	next: u64 // The number of the next request.
	issue :: proc "contextless" (command: block.Command, measure: ^Measure, next: ^u64) {
		place := next^ % u64(measure.depth)
		first := next^ * measure.blocks % (MEASURE_BLOCKS - measure.blocks)
		request(command, u32(place), {0 = first, 1 = measure.blocks, 2 = place * measure.blocks * block.BLOCK_SIZE})
		next^ += 1
	}
	service_before := service_entries()
	client_before := system.kernel_entries()
	start := system.time()
	for _ in 0 ..< measure.depth {
		issue(command, measure, &next)
	}
	done: u64
	for {
		record := answer()
		if block.Status(record.kind) != .Ok {
			measure.errors += 1
		}
		done += 1
		if (measured ? system.time() - start >= DURATION : done >= REQUESTS_CHECKED) {
			break
		}
		issue(command, measure, &next)
	}
	for done < next {
		if block.Status(answer().kind) != .Ok {
			measure.errors += 1
		}
		done += 1
	}
	elapsed := max(system.time() - start, 1)
	client := system.kernel_entries() - client_before
	service := service_entries() - service_before
	measure.requests = done
	measure.client = client * 100 / max(done, 1)
	measure.service = service * 100 / max(done, 1)
	measure.done = true
	if !measured {
		system.log("disk: ", measure.write ? "write" : "read", ", ", measure.blocks, measure.blocks == 1 ? " block" : " blocks", " in each request, ", u64(measure.depth), " in flight: ", done, " requests, kernel entries for 100 requests: ", measure.client, " of this program, ", measure.service, " of the block service, ", measure.errors, " errors")
		return
	}
	measure.rate = done * measure.blocks * 1000 / elapsed
	system.log("disk: ", measure.write ? "write" : "read", ", ", measure.blocks, measure.blocks == 1 ? " block" : " blocks", " in each request, ", u64(measure.depth), " in flight: ", measure.rate, " blocks in one second, kernel entries for 100 requests: ", measure.client, " of this program, ", measure.service, " of the block service, ", measure.errors, " errors")
}

// check writes a pattern in 128 blocks after the blocks of the measures,
// flushes, reads the blocks back into the second half of the region, and
// compares each byte. Each failed request and each wrong byte adds 1 to
// `wrong`.
check :: proc "contextless" () {
	COUNT :: 128
	for index in 0 ..< COUNT * block.BLOCK_SIZE {
		region[index] = u8(index / block.BLOCK_SIZE * 7 + index % 251)
	}
	for request_index in u64(0) ..< COUNT / 16 {
		request(.Write, u32(request_index), {0 = MEASURE_BLOCKS + request_index * 16, 1 = 16, 2 = request_index * 16 * block.BLOCK_SIZE})
	}
	for _ in 0 ..< COUNT / 16 {
		if block.Status(answer().kind) != .Ok {
			wrong += 1
		}
	}
	if block.Status(call(.Flush).kind) != .Ok {
		wrong += 1
	}
	base := u64(COUNT * block.BLOCK_SIZE)
	for request_index in u64(0) ..< COUNT / 16 {
		request(.Read, u32(request_index), {0 = MEASURE_BLOCKS + request_index * 16, 1 = 16, 2 = base + request_index * 16 * block.BLOCK_SIZE})
	}
	for _ in 0 ..< COUNT / 16 {
		if block.Status(answer().kind) != .Ok {
			wrong += 1
		}
	}
	for index in 0 ..< COUNT * block.BLOCK_SIZE {
		if region[base + u64(index)] != region[index] {
			wrong += 1
		}
	}
}

// refusal_text gives the sentence of the error record of a completion
// that failed.
refusal_text :: proc "contextless" (buffer: []u8, completion: ring.Record) -> string {
	error := errors.completion_record(completion.values)
	writer := system.Writer{buffer = buffer}
	system.ring_error_text(&writer, &error, "block", block.command_name(error.operation), block.argument_name(error.operation, error.argument))
	return system.written(&writer)
}

bar :: proc "contextless" (table: ^interface.Draw_Table, x, y: int, value, most: u64, color: graphics.Color) {
	interface.draw_rectangle(table, x, y + 3, BAR_WIDTH, 10, graphics.COLOR_TRACK)
	interface.draw_rectangle(table, x, y + 3, int(value * BAR_WIDTH / max(most, 1)), 10, color)
	interface.draw_unsigned(table, x + BAR_WIDTH + 8, y, value, graphics.COLOR_TEXT)
}

checked: bool

draw :: proc "contextless" (window: ^display.Window) {
	if drawing.now.records == nil {
		drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	}
	frame := interface.window_frame_begin(&drawing, window)
	table := frame.table
	interface.draw_rectangle(table, 0, 0, WIDTH, HEIGHT, graphics.COLOR_BACKGROUND)
	measured := system.measure_run()
	most_rate, most_entries: u64
	for measure in measures {
		most_rate, most_entries = max(most_rate, measured ? measure.rate : measure.requests), max(most_entries, measure.client + measure.service)
	}
	y := 12
	interface.draw_text(table, 12, y, "the block service: a virtio disk, a ring, the data in shared memory.", graphics.COLOR_DIM)
	y += LINE
	interface.draw_text(table, 12, y, "the device reads and writes the memory of this program: no copy.", graphics.COLOR_DIM)
	y += LINE
	interface.draw_text(table, 12, y, "disk:", graphics.COLOR_DIM)
	interface.draw_unsigned(table, 60, y, disk_blocks, graphics.COLOR_TEXT)
	digits := 1
	for value := disk_blocks; value >= 10; value /= 10 {
		digits += 1
	}
	interface.draw_text(table, 60 + 8 * (digits + 1), y, "blocks of 4096 bytes", graphics.COLOR_DIM)
	y += LINE + LINE / 2
	interface.draw_text(table, 12, y, "request         in flight", graphics.COLOR_DIM)
	interface.draw_text(table, RATE_X, y, measured ? "blocks in one second" : "requests answered", graphics.COLOR_DIM)
	interface.draw_text(table, ENTRIES_X, y, "kernel entries, 100 requests", graphics.COLOR_DIM)
	y += LINE
	for measure, index in measures {
		if index % 2 == 0 {
			interface.draw_rectangle(table, 6, y - 4, WIDTH - 12, LINE, graphics.COLOR_CARD_TOP)
		}
		interface.draw_text(table, 12, y, measure.write ? "write" : "read", graphics.COLOR_TEXT)
		interface.draw_unsigned(table, 64, y, measure.blocks, graphics.COLOR_TEXT)
		interface.draw_text(table, 92, y, measure.blocks == 1 ? "block" : "blocks", graphics.COLOR_DIM)
		interface.draw_unsigned(table, 156, y, u64(measure.depth), graphics.COLOR_TEXT)
		if measure.done {
			bar(table, RATE_X, y, measured ? measure.rate : measure.requests - measure.errors, most_rate, measure.errors == 0 ? COLOR_RATE : graphics.COLOR_FAILED)
			bar(table, ENTRIES_X, y, measure.client + measure.service, most_entries, COLOR_ENTRIES)
		} else {
			interface.draw_text(table, RATE_X, y, "...", graphics.COLOR_DIM)
		}
		y += LINE
	}
	y += LINE / 2
	if checked {
		interface.draw_text(table, 12, y, wrong == 0 ? "write, flush, read back: 128 blocks, 0 wrong" : "write, flush, read back: WRONG", wrong == 0 ? COLOR_RATE : graphics.COLOR_FAILED)
	}
	if !measured {
		interface.draw_text(table, 12, y + LINE, "the blocks in one second are a measure: run `kerneltool measure disk`.", graphics.COLOR_DIM)
	}
	interface.window_frame_end(&drawing, &frame, window)
}

// entry runs the five runs once, shows them, then keeps the window open
// until the program is stopped.
//
// **What it does**, in order:
//
// 1. It opens a window, the block ring, and a data region of 256 pages
//    (1 MiB, contiguous: the device reads and writes it).
// 2. It gives the data region to the block service through the block ring,
//    and sends `Attach`. The block service maps the ring when it starts; the
//    program tries again each millisecond, until the hang bound.
// 3. It asks `Info` for the size of the disk.
// 4. It runs each of the five runs (`run`): a count of requests, or one
//    second in a measure run.
// 5. It writes a pattern, flushes, reads it back and compares (`check`).
// 6. It reads 2 blocks from the last block of the disk, and checks the
//    error record of the refusal: kind `Out_Of_Range`, argument 1, value
//    the count of blocks + 1, limit the count of blocks.
// 7. It writes the summary line, then draws the window at each event.
//
// **The stop**: with no window, no block ring, no data region, no block
// service, or a refused `Attach`, it writes the reason on the log and stops
// with the code 1. Else it never returns.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "disk")
	if !ok {
		system.stop(1)
	}
	ring_memory := ctx.handles[block.GRANT_RING]
	status: system.Status
	if blocks, status = system.ring_open(ring_memory); status != .Ok {
		system.log("disk: no block ring")
		system.stop(1)
	}
	memory, memory_status := system.memory_create(REGION_PAGES, 0, {.Contiguous}) // The device reads and writes it.
	address, map_status := system.memory_map(memory, {.Write})
	if memory_status != .Ok || map_status != .Ok {
		system.log("disk: no data region")
		system.stop(1)
	}
	region = ([^]u8)(address)
	// The data region goes to the block service through the block ring.
	// The block service maps the ring when it starts: until then, the kernel
	// does not know the other side. The bound only ends a hang: a loaded
	// host can start the block service late.
	given: system.Handle
	give_status := system.Status.Bad_Handle
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; give_status != .Ok && system.time() < deadline; {
		if given, give_status = system.give(ring_memory, memory, {.Read, .Write}); give_status != .Ok {
			system.sleep(system.time() + 1)
		}
	}
	if give_status != .Ok {
		system.log("disk: the block service does not map the block ring")
		system.stop(1)
	}
	if attached := call(.Attach, {0 = u64(given)}); block.Status(attached.kind) != .Ok {
		text: [240]u8
		system.log("disk: the block service refused the data region: ", refusal_text(text[:], attached))
		system.stop(1)
	}
	info := call(.Info)
	disk_blocks = info.values[0]
	system.log("disk: ok, the disk has ", disk_blocks, " blocks, ", info.values[1], " blocks in one request at most")
	draw(&window)
	error_count: u64
	for &measure in measures {
		run(&measure)
		error_count += measure.errors
		draw(&window)
	}
	check()
	checked = true
	// A request past the end of the disk: the completion holds its error
	// record.
	past := call(.Read, {0 = disk_blocks - 1, 1 = 2, 2 = 0})
	past_error := errors.completion_record(past.values)
	text: [240]u8
	past_right := block.Status(past.kind) == .Out_Of_Range && errors.Kind(past_error.kind) == .Out_Of_Range && past_error.argument == 1 && u64(past_error.value) == disk_blocks + 1 && u64(past_error.limit) == disk_blocks
	system.log("disk: a read of 2 blocks from the last block: ", past_right ? "" : "WRONG: ", refusal_text(text[:], past))
	if error_count == 0 && wrong == 0 {
		system.log("disk: ok, ", u64(len(measures)), " runs, 0 errors, write then read back: 0 wrong")
	} else {
		system.log("disk: wrong: ", error_count, " errors, ", wrong, " wrong bytes")
	}
	for {
		draw(&window)
		display.wait(&window)
		for _ in display.next_event(&window) {
		}
	}
}
