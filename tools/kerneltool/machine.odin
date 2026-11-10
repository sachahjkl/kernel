package kerneltool

import "core:fmt"
import "core:hash"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// The machine test: the tool starts the machine under QEMU, and it acts as
// the person. It presses keys and moves the mouse through the QEMU monitor,
// it reads the log of the kernel, and it saves pictures of the screen.

SCREENSHOT_FOLDER :: BUILD_FOLDER + "/screenshots"
SCREEN_DUMP :: BUILD_FOLDER + "/screen.ppm"
STEP_TIMEOUT :: 20 * time.Second
KEY_PAUSE :: 45 * time.Millisecond
MOUSE_PAUSE :: 25 * time.Millisecond
MOUSE_STEP :: 40
// The exit status of QEMU when the kernel stops the machine with code 0.
MACHINE_STOP_OK :: 1

Step_Kind :: enum {
	Wait, // The log of the kernel has text, after the text of the last Wait.
	Type, // Press the keys of text, then Enter.
	Click, // Press the left button at (x, y).
	Drag, // Hold the left button from (x, y) to (to_x, to_y).
	Shot, // Save the screen as text.png.
}

Step :: struct {
	kind:       Step_Kind,
	text:       string,
	x, y:       int,
	to_x, to_y: int,
}

// The positions below come from programs/compositor/main.odin: the launcher
// in the bar, and the place of window n at (60 + 36 n, 52 + 30 n).
scenario := [?]Step {
	{kind = .Wait, text = "boot program: ok"},
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "root: ok"},
	{kind = .Wait, text = "input: ok"},
	{kind = .Wait, text = "compositor: first frame"},
	{kind = .Wait, text = "compositor: surface console"},

	// The console: a language with typed commands.
	{kind = .Type, text = "1 + 2 * 3"},
	{kind = .Wait, text = "[console] 7"},
	{kind = .Type, text = "name = \"kernel\""},
	{kind = .Type, text = "length(name + \"!\") * 2"},
	{kind = .Wait, text = "[console] 14"},
	{kind = .Type, text = "hash(\"abc\")"},
	{kind = .Wait, text = "[console] 6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"},
	{kind = .Type, text = "length(5)"},
	{kind = .Wait, text = "error: length: argument 1 is Text, not Integer"},
	{kind = .Type, text = "modules()"},
	{kind = .Wait, text = "[console] compositor"},
	{kind = .Type, text = "start(\"life\")"},
	{kind = .Wait, text = "life: ok"},
	{kind = .Wait, text = "compositor: surface life"},
	{kind = .Shot, text = "console"},

	// The desktop: start programs from the launcher, and move the windows.
	{kind = .Drag, x = 172, y = 92, to_x = 100, to_y = 420}, // life
	{kind = .Click, x = 190, y = 14}, // monitor
	{kind = .Wait, text = "compositor: surface monitor"},
	{kind = .Drag, x = 172, y = 122, to_x = 610, to_y = 50},
	{kind = .Click, x = 384, y = 14}, // paint
	{kind = .Wait, text = "compositor: surface paint"},
	{kind = .Drag, x = 208, y = 152, to_x = 560, to_y = 420},
	{kind = .Click, x = 582, y = 446}, // The red color.
	{kind = .Drag, x = 560, y = 520, to_x = 760, to_y = 700},
	{kind = .Click, x = 662, y = 446}, // The blue color.
	{kind = .Drag, x = 760, y = 520, to_x = 560, to_y = 700},
	{kind = .Drag, x = 800, y = 600, to_x = 960, to_y = 600},
	{kind = .Click, x = 264, y = 14}, // plasma
	{kind = .Wait, text = "plasma: ok"},
	{kind = .Wait, text = "compositor: surface plasma"},
	{kind = .Drag, x = 250, y = 182, to_x = 276, to_y = 150},
	{kind = .Shot, text = "desktop"},

	// A program that fails stops alone. The close button stops a program.
	{kind = .Click, x = 446, y = 14}, // fault
	{kind = .Wait, text = "stopped: page fault"},
	{kind = .Wait, text = "root: fault stopped"},
	{kind = .Click, x = 540, y = 152}, // The close button of plasma.
	{kind = .Wait, text = "root: plasma stopped"},

	// Back to the console: the system tools, then stop the machine.
	{kind = .Click, x = 300, y = 300},
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "programs()"},
	{kind = .Wait, text = "[console] slot name"},
	{kind = .Wait, text = "paint"},
	{kind = .Type, text = "memory()"},
	{kind = .Wait, text = "[console] interrupts"},
	{kind = .Type, text = "stop(\"paint\")"},
	{kind = .Wait, text = "root: paint stopped"},
	// A command is an export of a module: the console loads the module and
	// calls its exports from their descriptions.
	{kind = .Type, text = "gcd(84, 36)"},
	{kind = .Wait, text = "error: no command has the name gcd"},
	{kind = .Type, text = "load(\"math\")"},
	{kind = .Wait, text = "[console] math: 7 commands"},
	{kind = .Type, text = "gcd(84, 36) + power(2, 10)"},
	{kind = .Wait, text = "[console] 1036"},
	{kind = .Type, text = "number(\"41\") + fibonacci(10)"},
	{kind = .Wait, text = "[console] 96"},
	{kind = .Type, text = "next_prime(\"x\")"},
	{kind = .Wait, text = "error: next_prime: argument 1 is Integer, not Text"},
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "load(\"life\")"},
	{kind = .Wait, text = "exports no command"},
	{kind = .Type, text = "next_prime(1000) * gcd(84, 36)"},
	{kind = .Wait, text = "[console] 12108"},
	// A Text result: the console gives a buffer, the export writes in it.
	{kind = .Type, text = "reverse(roman(2026)) + roman(length(roman(3888)))"},
	{kind = .Wait, text = "[console] IVXXMMXV"},
	{kind = .Type, text = "help()"},
	{kind = .Wait, text = "[console] shutdown()"},
	{kind = .Wait, text = "[console] number(Text) -> Integer"},
	{kind = .Shot, text = "tools"},

	// An isolated call: the module runs in a sandboxed program. The
	// arguments go through a ring. The description is the same.
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "isolate(\"probe\")"},
	{kind = .Wait, text = "[console] probe: 7 commands in a sandboxed program"},
	{kind = .Wait, text = "[probe] host: ready, 7 exports"},
	{kind = .Type, text = "count() + count() * 10"},
	{kind = .Wait, text = "[console] 21"},
	{kind = .Type, text = "checksum(\"abc\" + name)"},
	{kind = .Wait, text = "[console] 935"},
	// A Text result through the ring: the module writes in the call region.
	{kind = .Type, text = "shout(\"abc\" + name) + shout(\"\")"},
	{kind = .Wait, text = "[console] ABCKERNEL"},
	// A module that gives a false count: the console reads no more than its buffer.
	{kind = .Type, text = "lie(100000)"},
	{kind = .Wait, text = "[console] error: the result of lie has 100000 bytes: it does not fit"},
	{kind = .Type, text = "length(lie(3))"},
	{kind = .Wait, text = "[console] 3"},
	{kind = .Type, text = "checksum(7)"},
	{kind = .Wait, text = "error: checksum: argument 1 is Text, not Integer"},
	// The module has no handle: it cannot stop the machine.
	{kind = .Type, text = "stop_machine(1) + stop_machine(2) + stop_machine(3)"},
	{kind = .Wait, text = "[console] 6"},
	// A fault in the module stops its program only. The next call starts a
	// new program, with new data.
	{kind = .Type, text = "peek(0)"},
	{kind = .Wait, text = "kernel: program probe stopped: page fault"},
	{kind = .Wait, text = "[console] error: the program probe stopped: page fault"},
	{kind = .Type, text = "count()"},
	{kind = .Wait, text = "[probe] host: ready"},
	{kind = .Wait, text = "[console] 1"},
	// A module that does not return: the console stops its program.
	{kind = .Type, text = "spin()"},
	{kind = .Wait, text = "[console] error: the program probe did not answer in 2000 ms"},
	{kind = .Type, text = "count() + gcd(84, 36)"},
	{kind = .Wait, text = "[console] 13"},
	{kind = .Type, text = "programs()"},
	{kind = .Wait, text = "probe"},
	{kind = .Shot, text = "isolated"},

	// The temple of Jon, then back to the console.
	{kind = .Click, x = 512, y = 14}, // temple
	{kind = .Wait, text = "temple: ok"},
	{kind = .Wait, text = "compositor: surface temple"},
	{kind = .Shot, text = "temple"},

	// Communication between programs: six programs pass records through
	// six rings. A stopped program takes no record: the records wait.
	{kind = .Click, x = 578, y = 14}, // rings
	{kind = .Wait, text = "rings: ok, 6 programs, 6 rings, 5 records"},
	{kind = .Wait, text = "compositor: surface rings"},
	{kind = .Drag, x = 600, y = 243, to_x = 500, to_y = 71},
	{kind = .Type, text = "aaa"},
	{kind = .Shot, text = "rings"},
	{kind = .Type, text = "4"},
	{kind = .Wait, text = "rings: node 4 stopped"},
	{kind = .Wait, text = "rings: node 4 does not run: "},
	{kind = .Shot, text = "rings_stopped"},
	{kind = .Type, text = "4"},
	{kind = .Wait, text = "rings: node 4 started"},
	{kind = .Click, x = 70, y = 300},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

Machine :: struct {
	process:   os.Process,
	monitor:   ^os.File,
	seen:      int, // The bytes of the log that the Wait steps used.
	x, y:      int, // The pointer.
	pointer_known: bool, // The tool knows where the pointer is.
}

monitor_send :: proc(machine: ^Machine, parts: ..string) {
	line := strings.concatenate({strings.concatenate(parts, context.temp_allocator), "\n"}, context.temp_allocator)
	_, _ = os.write_string(machine.monitor, line)
}

// key_name gives the QEMU name of the key, or keys, of a character.
key_name :: proc(character: u8) -> string {
	switch character {
	case 'a' ..= 'z', '0' ..= '9':
		return strings.clone_from_bytes({character}, context.temp_allocator)
	case 'A' ..= 'Z':
		return join("shift-", strings.clone_from_bytes({character + 32}, context.temp_allocator))
	case ' ':
		return "spc"
	case '(':
		return "shift-9"
	case ')':
		return "shift-0"
	case '"':
		return "shift-apostrophe"
	case '!':
		return "shift-1"
	case '%':
		return "shift-5"
	case '*':
		return "shift-8"
	case '+':
		return "shift-equal"
	case '=':
		return "equal"
	case '-':
		return "minus"
	case '_':
		return "shift-minus"
	case ',':
		return "comma"
	case '.':
		return "dot"
	case '/':
		return "slash"
	}
	return ""
}

pointer_move :: proc(machine: ^Machine, x, y: int) {
	for machine.x != x || machine.y != y {
		step_x := clamp(x - machine.x, -MOUSE_STEP, MOUSE_STEP)
		step_y := clamp(y - machine.y, -MOUSE_STEP, MOUSE_STEP)
		monitor_send(machine, fmt.tprintf("mouse_move %d %d", step_x, step_y))
		machine.x += step_x
		machine.y += step_y
		time.sleep(MOUSE_PAUSE)
	}
}

pointer_button :: proc(machine: ^Machine, down: bool) {
	monitor_send(machine, down ? "mouse_button 1" : "mouse_button 0")
	time.sleep(4 * MOUSE_PAUSE)
}

log_wait :: proc(machine: ^Machine, text: string) -> bool {
	start := time.now()
	for time.since(start) < STEP_TIMEOUT {
		log, err := os.read_entire_file(TEST_OUTPUT, context.temp_allocator)
		if err == nil && len(log) > machine.seen {
			if index := strings.index(string(log[machine.seen:]), text); index >= 0 {
				machine.seen += index + len(text)
				return true
			}
		}
		time.sleep(50 * time.Millisecond)
	}
	return false
}

// screen_save saves the screen of the machine as a PNG file.
screen_save :: proc(machine: ^Machine, name: string) -> bool {
	time.sleep(400 * time.Millisecond) // The compositor shows the last change.
	_ = os.remove(SCREEN_DUMP)
	monitor_send(machine, "screendump ", SCREEN_DUMP)
	for _ in 0 ..< 100 {
		time.sleep(100 * time.Millisecond)
		dump, err := os.read_entire_file(SCREEN_DUMP, context.temp_allocator)
		if err != nil {
			continue
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
			continue
		}
		path := join(SCREENSHOT_FOLDER, "/", name, ".png")
		if write_err := os.write_entire_file(path, png_encode(width, height, dump[position:][:width * height * 3])); err != nil {
			fmt.eprintfln("kerneltool: cannot write %s: %v", path, write_err)
			return false
		}
		fmt.printfln("kerneltool: screen saved: %s (%dx%d)", path, width, height)
		return true
	}
	fmt.eprintln("kerneltool: QEMU did not save the screen")
	return false
}

// png_encode gives a PNG file of pixels that are 3 bytes each: red, green,
// blue. The data is not compressed: the tool needs no compression library.
png_encode :: proc(width, height: int, pixels: []u8) -> []u8 {
	big_endian :: proc(out: ^[dynamic]u8, value: u32) {
		append(out, u8(value >> 24), u8(value >> 16), u8(value >> 8), u8(value))
	}
	chunk :: proc(out: ^[dynamic]u8, kind: string, data: []u8) {
		big_endian(out, u32(len(data)))
		start := len(out)
		append(out, kind)
		append(out, ..data)
		big_endian(out, hash.crc32(out[start:]))
	}

	// Each line: one filter byte (0: none), then the pixels.
	line_size := 1 + width * 3
	lines := make([]u8, height * line_size, context.temp_allocator)
	for y in 0 ..< height {
		copy(lines[y * line_size + 1:][:width * 3], pixels[y * width * 3:])
	}
	// A zlib stream of stored blocks.
	stream := make([dynamic]u8, context.temp_allocator)
	append(&stream, 0x78, 0x01)
	BLOCK :: 65535
	for start := 0; start < len(lines); start += BLOCK {
		count := min(BLOCK, len(lines) - start)
		append(&stream, u8(start + count == len(lines)), u8(count), u8(count >> 8), u8(~count), u8(~count >> 8))
		append(&stream, ..lines[start:][:count])
	}
	big_endian(&stream, hash.adler32(lines))

	out := make([dynamic]u8, context.temp_allocator)
	append(&out, 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n')
	header := make([dynamic]u8, context.temp_allocator)
	big_endian(&header, u32(width))
	big_endian(&header, u32(height))
	append(&header, 8, 2, 0, 0, 0) // 8 bits, red green blue.
	chunk(&out, "IHDR", header[:])
	chunk(&out, "IDAT", stream[:])
	chunk(&out, "IEND", nil)
	return out[:]
}

// machine_test runs the scenario. It passes when each step passes and the
// kernel stops the machine with code 0.
machine_test :: proc() -> bool {
	command, ok := machine_command(true)
	if !ok || !reset_folder(SCREENSHOT_FOLDER) {
		return false
	}
	_ = os.remove(TEST_OUTPUT)
	monitor_read, monitor_write, pipe_err := os.pipe()
	if pipe_err != nil {
		fmt.eprintfln("kerneltool: cannot create a pipe: %v", pipe_err)
		return false
	}
	process, start_err := os.process_start({command = command, stdin = monitor_read, stderr = os.stderr})
	if start_err != nil {
		fmt.eprintfln("kerneltool: cannot start %s: %v", command[0], start_err)
		return false
	}
	machine := Machine {
		process = process,
		monitor = monitor_write,
	}
	passed := scenario_run(&machine)
	state: os.Process_State
	if passed {
		wait_err: os.Error
		state, wait_err = os.process_wait(process, STEP_TIMEOUT)
		if wait_err != nil || !state.exited {
			fmt.eprintln("kerneltool: test failed: the machine did not stop")
			passed = false
		} else if state.exit_code != MACHINE_STOP_OK {
			fmt.eprintfln("kerneltool: test failed: QEMU ended with status %d", state.exit_code)
			passed = false
		}
	}
	if !state.exited {
		_ = os.process_kill(process)
		_, _ = os.process_wait(process)
	}
	os.close(monitor_write)
	os.close(monitor_read)
	if !passed {
		log, _ := os.read_entire_file(TEST_OUTPUT, context.temp_allocator)
		lines := strings.split_lines(string(log), context.temp_allocator)
		fmt.eprintln("kerneltool: the end of the log of the kernel:")
		for line in lines[max(len(lines) - 25, 0):] {
			fmt.eprintln("   ", line)
		}
	}
	return passed
}

scenario_run :: proc(machine: ^Machine) -> bool {
	for step, index in scenario {
		switch step.kind {
		case .Wait:
			if !log_wait(machine, step.text) {
				fmt.eprintfln("kerneltool: test failed: step %d: the machine did not print \"%s\"", index + 1, step.text)
				return false
			}
			fmt.printfln("kerneltool: test passed: the machine printed \"%s\"", step.text)
		case .Type:
			for i in 0 ..< len(step.text) {
				name := key_name(step.text[i])
				if name == "" {
					fmt.eprintfln("kerneltool: step %d: no key for '%c'", index + 1, step.text[i])
					return false
				}
				monitor_send(machine, "sendkey ", name, " 20")
				time.sleep(KEY_PAUSE)
			}
			monitor_send(machine, "sendkey ret 20")
			time.sleep(KEY_PAUSE)
		case .Click, .Drag:
			if !machine.pointer_known {
				// The pointer starts at an unknown place: push it to the corner.
				machine.pointer_known = true
				for _ in 0 ..< 40 {
					monitor_send(machine, "mouse_move -100 -100")
					time.sleep(MOUSE_PAUSE)
				}
			}
			pointer_move(machine, step.x, step.y)
			pointer_button(machine, true)
			if step.kind == .Drag {
				pointer_move(machine, step.to_x, step.to_y)
			}
			pointer_button(machine, false)
		case .Shot:
			if !screen_save(machine, step.text) {
				return false
			}
		}
		free_all(context.temp_allocator)
	}
	return true
}
