package kerneltool

import "support:launcher"
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
FILM_FOLDER :: BUILD_FOLDER + "/film"
FILM_FRAME :: FILM_FOLDER + "/%05d.ppm"
FILM_RATE :: 25 // Pictures in one second.
FILM_FRAME_TIME :: time.Second / FILM_RATE
STEP_TIMEOUT :: 20 * time.Second
KEY_PAUSE :: 45 * time.Millisecond
MOUSE_PAUSE :: 25 * time.Millisecond
MOUSE_STEP :: 40
// The exit status of QEMU when the kernel stops the machine with code 0.
MACHINE_STOP_OK :: 1

Step_Kind :: enum {
	Wait, // The log of the kernel has text, after the text of the last Wait.
	Type, // Press the keys of text, then Enter.
	Key, // Press one key: text is its QEMU name.
	Click, // Press the left button at (x, y).
	Launch, // Open the menu of the launcher, and press the line of the program text.
	Drag, // Hold the left button from (x, y) to (to_x, to_y).
	Shot, // Save the screen as text.png.
	Move, // Drag the window with the title text to the place (to_x, to_y). The tool reads the place of the window in the log, before and after.
	Front, // Open the menu of the windows, and press the line of the last window with the title text: the window comes to the front. The tool reads the lines of the menu in the log.
	Close, // Press the close button of the window with the title text. The tool reads the place and the size of the window in the log.
	Film, // Save the screen 25 times in one second, for x milliseconds, as the next pictures of the film.
	Quit, // End QEMU: the machine does not stop by itself.
}

Step :: struct {
	kind:       Step_Kind,
	text:       string,
	x, y:       int,
	to_x, to_y: int,
	// For Wait: the next Wait searches from the same place. Use it when two
	// programs print in an order that the system does not fix.
	any_order:  bool,
}

// A start that fails: the boot image has no compositor. The boot display
// stays on the screen with the failure, and the machine does not stop.
scenario_fails := [?]Step {
	{kind = .Wait, text = "boot program: ok"},
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "root: ok"},
	{kind = .Wait, text = "root: cannot start the compositor: status "},
	{kind = .Wait, text = "root: the boot display shows the failure"},
	{kind = .Shot, text = "boot_fails"},
	{kind = .Quit},
}

// A test of the kernel on itself (boot_info.Self_Test): the kernel does one
// thing that its page tables must refuse. The processor refuses, and the
// kernel reports the fault and stops the machine with code 2.
Self_Test :: struct {
	number:  int, // boot_info.Self_Test.
	does:    string,
	reports: []string, // Parts of the report of the fault.
}

MACHINE_STOP_FAULT :: 2 << 1 | 1 // The status of QEMU for the code 2.

self_tests := [?]Self_Test {
	{1, "use more than the kernel stack", {" vector 8 ", ": the kernel stack of the processor is full"}},
	{2, "write to the code of the kernel", {" vector 14 ", ": write to a read-only page"}},
	{3, "write to the code of the kernel through the direct map", {" vector 14 ", ": write to a read-only page"}},
	{4, "execute the data of the kernel", {" vector 14 ", ": execute of a page that is not code"}},
	{5, "read the memory of a program outside a copy", {" vector 14 ", ": the kernel used memory of a program outside a copy"}},
	{6, "execute the code of a program", {" vector 14 ", ": the kernel executed memory of a program"}},
}

self_test_file :: proc(pattern: string, number: int) -> string {
	// The machine test frees the temporary memory: this text stays.
	return fmt.aprintf(pattern, number)
}

self_tests_run :: proc() -> bool {
	for test in self_tests {
		steps := make([dynamic]Step)
		append(&steps, Step{kind = .Wait, text = "kernel: ok"})
		append(&steps, Step{kind = .Wait, text = fmt.aprintf("kernel: self test: %s", test.does)})
		for report in test.reports {
			append(&steps, Step{kind = .Wait, text = report, any_order = true})
		}
		if !machine_test(steps[:], self_test_file(BOOT_VOLUME_SELF_TEST, test.number), self_test_file(TEST_OUTPUT_SELF_TEST, test.number), MACHINE_STOP_FAULT) {
			return false
		}
	}
	return true
}

// The positions below come from programs/compositor/main.odin: the launcher
// in the bar, and the place of window n at (60 + 36 n, 52 + 30 n).
scenario := [?]Step {
	{kind = .Wait, text = "boot program: ok"},
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "root: ok"},
	{kind = .Wait, text = "input: ok"},
	// The two come in an order that the system does not fix.
	{kind = .Wait, text = "compositor: first frame", any_order = true},
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
	{kind = .Wait, text = "life: ok", any_order = true},
	{kind = .Wait, text = "compositor: surface life"},
	{kind = .Shot, text = "console"},

	// The desktop: start programs from the launcher, and move the windows.
	{kind = .Drag, x = 172, y = 92, to_x = 100, to_y = 420}, // life
	{kind = .Launch, text = "monitor"},
	{kind = .Wait, text = "compositor: surface monitor"},
	{kind = .Drag, x = 172, y = 122, to_x = 610, to_y = 50},
	{kind = .Launch, text = "paint"},
	{kind = .Wait, text = "compositor: surface paint"},
	{kind = .Drag, x = 208, y = 152, to_x = 560, to_y = 420},
	{kind = .Click, x = 582, y = 446}, // The red color.
	{kind = .Drag, x = 560, y = 520, to_x = 760, to_y = 700},
	{kind = .Click, x = 662, y = 446}, // The blue color.
	{kind = .Drag, x = 760, y = 520, to_x = 560, to_y = 700},
	{kind = .Drag, x = 800, y = 600, to_x = 960, to_y = 600},
	{kind = .Launch, text = "plasma"},
	{kind = .Wait, text = "plasma: ok", any_order = true},
	{kind = .Wait, text = "compositor: surface plasma"},
	{kind = .Drag, x = 250, y = 182, to_x = 276, to_y = 150},
	{kind = .Shot, text = "desktop"},
	// The menu of the launcher: the button of the bar opens and closes it.
	{kind = .Click, x = 116, y = 14},
	{kind = .Shot, text = "launcher"},
	{kind = .Click, x = 116, y = 14},
	// The menu of the windows: a press on a line brings the window to the
	// front.
	{kind = .Click, x = 200, y = 14},
	{kind = .Wait, text = "compositor: windows: "},
	{kind = .Shot, text = "windows"},
	{kind = .Click, x = 200, y = 14},
	{kind = .Front, text = "console"},
	{kind = .Front, text = "plasma"},

	// A program that fails stops alone. The close button stops a program.
	{kind = .Launch, text = "fault"},
	{kind = .Wait, text = "stopped: page fault"},
	{kind = .Wait, text = "root: fault stopped"},
	{kind = .Click, x = 540, y = 152}, // The close button of plasma.
	{kind = .Wait, text = "root: plasma stopped"},

	// Back to the console: the system tools, then stop the machine.
	{kind = .Front, text = "console"},
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
	{kind = .Type, text = "load(\"plasma\")"},
	{kind = .Wait, text = "exports no command"},
	{kind = .Type, text = "next_prime(1000) * gcd(84, 36)"},
	{kind = .Wait, text = "[console] 12108"},
	// A Text result: the console gives a buffer, the export writes in it.
	{kind = .Type, text = "reverse(roman(2026)) + roman(length(roman(3888)))"},
	{kind = .Wait, text = "[console] IVXXMMXV"},
	{kind = .Type, text = "help()"},
	{kind = .Wait, text = "[console] shutdown()"},
	{kind = .Wait, text = "[console] number(text: Text) -> Integer"},
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
	// A module that does not return. The line runs in the second thread of
	// the console: the console keeps the keys of the next line, and Escape
	// stops the call. Then the line that waited runs.
	{kind = .Type, text = "spin()"},
	{kind = .Type, text = "count() + gcd(84, 36)"},
	{kind = .Shot, text = "running"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "console: Escape stops the line after "},
	{kind = .Wait, text = "[console] error: the person stopped the call of spin"},
	{kind = .Wait, text = "[console] 13"},
	{kind = .Type, text = "programs()"},
	{kind = .Wait, text = "probe"},
	{kind = .Shot, text = "isolated"},

	// A record and a lent handle in an isolated call. The record goes as
	// bytes with described fields. The module receives a copy of the handle
	// with the rights of the description, for the time of the call.
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "isolate(\"sample\")"},
	{kind = .Wait, text = "[console] sample: 10 commands in a sandboxed program"},
	{kind = .Type, text = "r = Rectangle(1, 2, 30, 4)"},
	{kind = .Type, text = "area(r)"},
	{kind = .Wait, text = "[console] 120"},
	{kind = .Type, text = "grow(r, 5)"},
	{kind = .Wait, text = "[console] Rectangle{x = -4, y = -3, width = 40, height = 14}"},
	{kind = .Type, text = "b = buffer(1)"},
	{kind = .Type, text = "fill(b, 3)"},
	{kind = .Wait, text = "[console] 4096"},
	// The module wrote in the memory of the console: the object is shared, not copied.
	{kind = .Type, text = "byte(b, 4095)"},
	{kind = .Wait, text = "[console] 3"},
	// A handle in a field of a record.
	{kind = .Type, text = "span_total(Span(b, 96, 10))"},
	{kind = .Wait, text = "[console] 30"},
	// The description of spoil asks Read: the module cannot write. 7: no right.
	{kind = .Type, text = "spoil(b)"},
	{kind = .Wait, text = "[console] 7"},
	// A lent handle ends with its call. 2: no handle.
	{kind = .Type, text = "keep(b)"},
	{kind = .Wait, text = "[console] 12288"},
	{kind = .Type, text = "kept()"},
	{kind = .Wait, text = "[console] 2"},
	{kind = .Type, text = "area(Span(b, 0, 1))"},
	{kind = .Wait, text = "[console] error: area: argument 1 is Rectangle, not Span"},
	{kind = .Type, text = "b"},
	{kind = .Wait, text = ": Memory (Give, Read, Write, Execute)"},
	{kind = .Shot, text = "records"},

	// Revocation. The console revokes what it lent at the end of each
	// call: the mapping that the module kept is gone, and the next read
	// stops the program of the module on a page fault.
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "hold(b)"},
	{kind = .Wait, text = "[console] 3"},
	{kind = .Type, text = "look()"},
	{kind = .Wait, text = "[console] error: the program sample stopped: page fault"},
	// The root service ends one grant of a program that runs. The window of
	// monitor goes below the console for the picture, then back.
	{kind = .Drag, x = 900, y = 50, to_x = 900, to_y = 560},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "grants(\"monitor\")"},
	{kind = .Wait, text = "[console] monitor has: log, machine"},
	{kind = .Type, text = "revoke(\"monitor\", \"machine\")"},
	{kind = .Wait, text = "root: revoked the grant machine of monitor, holdings ended: 1", any_order = true},
	{kind = .Wait, text = "[console] monitor lost the grant machine, holdings ended: 1", any_order = true},
	{kind = .Wait, text = "monitor: no grant to inspect the machine"},
	{kind = .Type, text = "grants(\"monitor\")"},
	{kind = .Wait, text = "[console] monitor has: log"},
	{kind = .Wait, text = "[console] monitor lost: machine"},
	{kind = .Type, text = "revoke(\"monitor\", \"machine\")"},
	{kind = .Wait, text = "[console] error: the program monitor does not have the grant machine"},
	{kind = .Type, text = "revoke(\"monitor\", \"keys\")"},
	{kind = .Wait, text = "[console] error: no grant has the name keys"},
	{kind = .Shot, text = "revocation"},
	{kind = .Drag, x = 900, y = 570, to_x = 900, to_y = 60},
	{kind = .Front, text = "console"},
	// The same descriptions serve a direct call. The module is then in the
	// console: it has the handles of the console, and kept gives 0.
	{kind = .Type, text = "unload(\"sample\")"},
	{kind = .Wait, text = "[console] sample: 10 commands removed, its sandboxed program stops"},
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "load(\"sample\")"},
	{kind = .Wait, text = "[console] sample: 10 commands, hash"},
	{kind = .Type, text = "g = grow(r, 5)"},
	{kind = .Type, text = "g.width * g.height + keep(b) + kept()"},
	{kind = .Wait, text = "[console] 12848"},
	{kind = .Type, text = "unload(\"sample\")"},
	{kind = .Wait, text = "[console] sample: 10 commands removed, the module left the memory of the console"},
	{kind = .Type, text = "release(b)"},

	// The temple of Jon, then back to the console.
	{kind = .Launch, text = "temple"},
	{kind = .Wait, text = "temple: ok", any_order = true},
	{kind = .Wait, text = "compositor: surface temple"},
	{kind = .Shot, text = "temple"},

	// Communication between programs: six programs pass records through
	// six rings. A stopped program takes no record: the records wait.
	{kind = .Launch, text = "rings"},
	{kind = .Wait, text = "rings: ok, 6 programs, 6 rings, 5 records"},
	{kind = .Drag, x = 600, y = 243, to_x = 500, to_y = 71},
	{kind = .Type, text = "aaa"},
	{kind = .Shot, text = "rings"},
	{kind = .Type, text = "4"},
	{kind = .Wait, text = "rings: node 4 stopped"},
	{kind = .Wait, text = "rings: node 4 does not run: "},
	{kind = .Shot, text = "rings_stopped"},
	{kind = .Type, text = "4"},
	{kind = .Wait, text = "rings: node 4 started"},

	// Threads: one program, five threads, one surface. A thread ends and
	// the first thread reads its result. A stopped thread draws no more.
	{kind = .Launch, text = "threads"},
	{kind = .Wait, text = "threads: a thread added the numbers to 1000: 500500"},
	{kind = .Wait, text = "threads: ok, 4 threads draw in one surface"},
	{kind = .Type, text = "3"},
	{kind = .Wait, text = "threads: thread 3 stopped at frame "},
	{kind = .Shot, text = "threads"},
	{kind = .Type, text = "3"},
	{kind = .Wait, text = "threads: thread 3 started"},

	// The lock and the word wait: four threads add to one number, then take
	// tiles from one queue.
	{kind = .Launch, text = "workers"},
	{kind = .Wait, text = "workers: the lock lost no addition"},
	{kind = .Wait, text = "workers: ok, 4 threads computed 140 tiles: "},
	{kind = .Drag, x = 400, y = 62, to_x = 640, to_y = 340},
	{kind = .Shot, text = "workers"},

	// Rights: a program with a part of the rights of two handles. The
	// kernel refuses each operation that needs another right.
	{kind = .Launch, text = "rights"},
	{kind = .Wait, text = "rights: ok, 4 allowed, 5 refused", any_order = true},
	{kind = .Wait, text = "compositor: surface rights"},
	{kind = .Shot, text = "rights"},

	// The origin of a handle: the kernel ends what came from a handle, in
	// this program and in another one.
	{kind = .Launch, text = "origin"},
	{kind = .Wait, text = "origin: ok, 12 cases", any_order = true},
	{kind = .Wait, text = "origin: lend a handle and take it back: ", any_order = true},
	{kind = .Wait, text = "compositor: surface origin"},
	{kind = .Shot, text = "origin"},

	// Budgets: no object comes from nothing. The program creates until
	// its budget cannot pay; what it frees returns.
	{kind = .Launch, text = "budget"},
	{kind = .Wait, text = "budget: ok, ", any_order = true},
	{kind = .Wait, text = "compositor: surface budget"},
	{kind = .Shot, text = "budget"},

	// The limits of a budget: the kernel stops a thread at the processor
	// time of its budget, and refuses the log records above the limit.
	{kind = .Launch, text = "limits"},
	{kind = .Wait, text = "limits: ok, 4 budgets within their processor time, ", any_order = true},
	{kind = .Wait, text = "compositor: surface limits", any_order = true},
	{kind = .Shot, text = "limits"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"limits\")"},
	{kind = .Wait, text = "root: limits stopped"},

	// One ring between two threads: the records of one second, and the
	// kernel entries that they cost, for two capacities and two ways to wait.
	{kind = .Launch, text = "flow"},
	{kind = .Wait, text = "flow: capacity 32, wait at once: ", any_order = true},
	{kind = .Wait, text = "flow: capacity 1024, read the counters then wait: "},
	{kind = .Wait, text = "flow: ok, 4 measures, 0 records lost"},
	{kind = .Shot, text = "flow"},

	// One queue for several writers and several readers, with no lock; one
	// event starts the threads of each measure.
	{kind = .Launch, text = "crowd"},
	{kind = .Wait, text = "crowd: shared queue, 1 writers, 1 readers: ", any_order = true},
	{kind = .Wait, text = "crowd: shared queue, 2 writers, 2 readers: "},
	{kind = .Wait, text = "crowd: shared queue, 3 writers, 1 readers: "},
	{kind = .Wait, text = "crowd: shared queue, 1 writers, 3 readers: "},
	{kind = .Wait, text = "crowd: queue with a lock, 2 writers, 2 readers: "},
	{kind = .Wait, text = "crowd: ok, 5 measures, each record written is read one time, each event started all the threads"},
	{kind = .Shot, text = "crowd"},

	// The time is in a page that each program reads: no kernel entry.
	{kind = .Launch, text = "clock"},
	{kind = .Wait, text = "clock: the time page: "},
	{kind = .Wait, text = " reads in one second, 0 kernel entries for one million reads"},
	{kind = .Wait, text = "clock: a kernel entry: "},
	{kind = .Wait, text = "clock: ok, the time never went back, the page and the kernel give the same time, the kernel refuses to remove the time page"},
	{kind = .Shot, text = "clock"},

	// Several processors: the kernel says that the four processors ran
	// threads of one program at the same time. Then 1, 2 and 4 threads
	// compute the same picture.
	{kind = .Launch, text = "processors"},
	{kind = .Wait, text = "processors: ok, 4 processors ran the program at the same time"},
	{kind = .Wait, text = "processors: the picture took "},
	{kind = .Shot, text = "processors"},

	// The boot display in a window: how the machine started, with the
	// records that the kernel has now.
	{kind = .Launch, text = "boot"},
	{kind = .Wait, text = "boot: ok, 7 stages, "},
	{kind = .Shot, text = "boot"},
	// The window covers the screen: move it down, away from the console.
	{kind = .Move, text = "boot", to_x = 60, to_y = 742},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"boot\")"},
	{kind = .Wait, text = "root: boot stopped"},
	{kind = .Type, text = "programs()"},
	{kind = .Wait, text = "   threads     "},

	// Paging: the kernel reads its own page tables. No page is both
	// writable and executable, and each kernel stack has its guard pages.
	{kind = .Launch, text = "pages"},
	{kind = .Wait, text = "pages: the kernel half: ", any_order = true},
	{kind = .Wait, text = " 0 write and execute, 48 guard pages of 48"},
	{kind = .Wait, text = "pages: ok, the page tables keep the rules"},
	{kind = .Wait, text = "pages: the processor refuses the memory of programs to the kernel"},
	{kind = .Shot, text = "pages"},
	{kind = .Move, text = "pages", to_x = 168, to_y = 742}, // The window covers the console.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"pages\")"},
	{kind = .Wait, text = "root: pages stopped"},

	// Paging as a tool of the system: pages on first use, and the shared
	// code of a module. The program starts its twins and measures.
	{kind = .Launch, text = "frames"},
	{kind = .Wait, text = "frames: 4 twins: ", any_order = true},
	{kind = .Wait, text = "frames: create and map 8192 pages: ", any_order = true},
	{kind = .Wait, text = "frames: the first use of a page: ", any_order = true},
	{kind = .Wait, text = "frames: start a twin: ", any_order = true},
	{kind = .Wait, text = "frames: ok, 10 cases", any_order = true},
	{kind = .Wait, text = "compositor: surface frames"},
	{kind = .Shot, text = "frames"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"frames\")"},
	{kind = .Wait, text = "root: frames stopped"},

	// A service serves its own exports while it runs. The root service makes
	// the connection; the console reads the descriptions in the file of the
	// program, and each export is a command.
	{kind = .Launch, text = "paint"},
	{kind = .Wait, text = "compositor: surface paint"},
	{kind = .Move, text = "paint", to_x = 516, to_y = 408}, // Below the console, at the right.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "connect(\"paint\")"},
	{kind = .Wait, text = "root: connected console to the service paint"},
	{kind = .Wait, text = "[console] paint: 4 commands of a service that runs"},
	{kind = .Type, text = "connect(\"life\")"},
	{kind = .Wait, text = "[console] life: 3 commands of a service that runs"},
	{kind = .Type, text = "connect(\"monitor\")"},
	{kind = .Wait, text = "error: cannot connect to monitor: no service runs with this name"},
	{kind = .Type, text = "help()"},
	{kind = .Wait, text = "paint.write(x: Integer, y: Integer, text: Text, color: Integer)"},
	{kind = .Type, text = "paint.line(40, 30, 440, 250, 1)"},
	{kind = .Type, text = "paint.line(40, 250, 440, 30, 3)"},
	{kind = .Type, text = "paint.write(150, 20, \"drawn by isolated calls\", 0)"},
	{kind = .Type, text = "paint.lines()"},
	{kind = .Wait, text = "[console] 2"},
	{kind = .Type, text = "life.empty()"},
	{kind = .Type, text = "life.glider(10, 10)"},
	{kind = .Type, text = "life.population()"},
	{kind = .Wait, text = "[console] 5"},
	{kind = .Front, text = "paint"},
	{kind = .Shot, text = "services"},
	{kind = .Front, text = "console"},
	// The service stops: the call fails, and the console continues. The
	// service starts again: the next call makes a new connection.
	{kind = .Type, text = "stop(\"paint\")"},
	{kind = .Wait, text = "root: paint stopped"},
	{kind = .Wait, text = "root: disconnected console from the service paint"},
	{kind = .Type, text = "paint.lines()"},
	{kind = .Wait, text = "error: no service runs with the name paint"},
	{kind = .Launch, text = "paint"},
	{kind = .Wait, text = "compositor: surface paint"},
	{kind = .Move, text = "paint", to_x = 460, to_y = 688}, // The window covers the console: move it down.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "paint.lines()"},
	{kind = .Wait, text = "root: connected console to the service paint"},
	{kind = .Wait, text = "[console] 0"},
	{kind = .Type, text = "stop(\"paint\")"},
	{kind = .Wait, text = "root: paint stopped"},

	// One module in each role: the file of tally is a program, a service, a
	// library in the memory of the console, and a sandboxed program. Each
	// program that runs the module has its own count.
	{kind = .Launch, text = "tally"},
	{kind = .Wait, text = "tally: ok"},
	{kind = .Wait, text = "compositor: surface tally"},
	{kind = .Move, text = "tally", to_x = 616, to_y = 530}, // Under the console, at the right.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "connect(\"tally\")"},
	{kind = .Wait, text = "[console] tally: 5 commands of a service that runs"},
	{kind = .Type, text = "tally.add(5, \"from the console, to the service\")"},
	{kind = .Wait, text = "[console] 5"},
	{kind = .Type, text = "load(\"tally\")"},
	{kind = .Wait, text = "[console] tally: 5 commands, hash"},
	{kind = .Type, text = "add(2, \"in the console\") + add(2, \"in the console\")"},
	{kind = .Wait, text = "[console] 6"},
	{kind = .Type, text = "tally.total()"},
	{kind = .Wait, text = "[console] 5"},
	{kind = .Type, text = "isolate(\"tally\")"},
	{kind = .Wait, text = "error: the module tally is loaded; unload(\"tally\") removes it"},
	{kind = .Type, text = "unload(\"tally\")"},
	{kind = .Wait, text = "[console] tally: 5 commands removed, the module left the memory of the console"},
	{kind = .Type, text = "total()"},
	{kind = .Wait, text = "error: no command has the name total"},
	{kind = .Type, text = "isolate(\"tally\")"},
	{kind = .Wait, text = "[console] tally: 5 commands in a sandboxed program"},
	{kind = .Type, text = "add(30, \"in a sandboxed program\") + adds()"},
	{kind = .Wait, text = "[console] 31"},
	{kind = .Type, text = "last()"},
	{kind = .Wait, text = "[console] in a sandboxed program"},
	{kind = .Type, text = "tally.last()"},
	{kind = .Wait, text = "[console] from the console, to the service"},
	{kind = .Shot, text = "roles"},
	{kind = .Type, text = "unload(\"tally\")"},
	{kind = .Wait, text = "[console] tally: 5 commands removed, its sandboxed program stops"},
	{kind = .Type, text = "tally.total()"},
	{kind = .Wait, text = "[console] 5"},

	// The manual shows the documentation that each module carries. It is a
	// service: the console asks for a page, and reads a description as text.
	{kind = .Launch, text = "manual"},
	{kind = .Wait, text = "compositor: surface manual", any_order = true},
	{kind = .Wait, text = "manual: ok, "},
	{kind = .Move, text = "manual", to_x = 204, to_y = 742},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"manual\")"},
	{kind = .Wait, text = "[console] manual: 3 commands of a service that runs"},
	{kind = .Type, text = "manual.about(\"math\")"},
	{kind = .Wait, text = "[console] A module of commands (property 19)"},
	{kind = .Type, text = "manual.signature(\"tally\", 1)"},
	{kind = .Wait, text = "[console] add(amount: Integer, note: Text) -> Integer"},
	{kind = .Type, text = "manual.show(\"nothing\")"},
	{kind = .Wait, text = "[console] -1"},
	{kind = .Type, text = "manual.show(\"tally\")"},
	{kind = .Wait, text = "manual: tally: a program, 5 exports, "},
	{kind = .Move, text = "manual", to_x = 76, to_y = 60},
	{kind = .Shot, text = "manual"},
	// The keys of the manual: the next module of the boot image, then the one before.
	{kind = .Key, text = "down"},
	{kind = .Wait, text = "manual: manual: a program, 3 exports, "},
	{kind = .Key, text = "pgdn"},
	{kind = .Key, text = "up"},
	{kind = .Wait, text = "manual: tally: a program, 5 exports, "},
	{kind = .Move, text = "manual", to_x = 204, to_y = 742},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"manual\")"},
	{kind = .Wait, text = "root: manual stopped"},
	{kind = .Type, text = "stop(\"tally\")"},
	{kind = .Wait, text = "root: tally stopped"},

	// The log: records in channels. The kernel sets the program of each
	// record; a program with the grant reads the records.
	{kind = .Launch, text = "log"},
	{kind = .Wait, text = "[log:log] log: the kernel wrote 7 records in the channel boot"},
	{kind = .Wait, text = "[log:log] log: ok, ", any_order = true},
	{kind = .Wait, text = " 0 lost, "},
	{kind = .Shot, text = "log"},
	// The window covers the console: move it down.
	{kind = .Move, text = "log", to_x = 96, to_y = 742},
	{kind = .Front, text = "console"},
	// The terminal: a program gives text as records with a style, in a ring
	// of 4096 records. The terminal reads them in one thread and draws in
	// another: the display does not slow the program.
	// The root service starts the program and its terminal: the terminal
	// starts no program, and has nothing of the role of the program.
	{kind = .Launch, text = "flood"},
	{kind = .Wait, text = "flood: ok", any_order = true},
	{kind = .Wait, text = "terminal: ok, flood writes in a ring of 4096 records", any_order = true},
	{kind = .Wait, text = "root: started flood, with a terminal"},
	{kind = .Move, text = "flood", to_x = 158, to_y = 104}, // The place of the pictures and of the clicks below.
	{kind = .Wait, text = "terminal: flood wrote "},
	{kind = .Shot, text = "terminal"},
	// The terminal keeps Page Up and Page Down: its view stays, the program continues.
	{kind = .Key, text = "pgup"},
	{kind = .Wait, text = "terminal: the view stays at line "},
	{kind = .Key, text = "pgup"},
	{kind = .Shot, text = "terminal_held"},
	// Each other key is a record for the program. flood stops its lines at
	// the key Space, and shows it in the line that it changes.
	{kind = .Key, text = "spc"},
	{kind = .Wait, text = "terminal: the first key goes to flood", any_order = true},
	{kind = .Wait, text = "flood: the person pressed Space: no more lines after "},
	{kind = .Shot, text = "terminal_keys"},
	{kind = .Key, text = "spc"},
	{kind = .Wait, text = "flood: the person pressed Space: the lines continue"},
	// The program stops: its terminal stays, with what the program wrote.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"flood\")"},
	{kind = .Wait, text = "terminal: flood stopped with code 0 after "},
	{kind = .Click, x = 940, y = 400}, // A part of the window that the console does not cover.
	{kind = .Shot, text = "terminal_stopped"},
	// The person closes the window: the terminal stops.
	{kind = .Close, text = "flood"},
	{kind = .Wait, text = "root: terminal stopped"},
	{kind = .Front, text = "console"},
	// Each page is free or paid, after all the starts and stops of this test.
	{kind = .Type, text = "memory()"},
	{kind = .Wait, text = " pages: all the free pages"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// The film of the terminal: the program flood writes lines, the person
// holds the view, moves in the lines, then stops the lines with a key and
// starts them again.
@(rodata)
scenario_film := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Launch, text = "flood"},
	{kind = .Wait, text = "terminal: ok, flood writes in a ring of 4096 records"},
	{kind = .Film, x = 5000},
	{kind = .Key, text = "pgup"},
	{kind = .Film, x = 2500},
	{kind = .Key, text = "spc"},
	{kind = .Film, x = 2500},
	{kind = .Key, text = "pgup"},
	{kind = .Film, x = 500},
	{kind = .Key, text = "pgup"},
	{kind = .Film, x = 500},
	{kind = .Key, text = "pgup"},
	{kind = .Film, x = 1500},
	{kind = .Key, text = "spc"},
	{kind = .Film, x = 4000},
	{kind = .Shot, text = "film_end"},
	{kind = .Quit},
}

Machine :: struct {
	process:   os.Process,
	monitor:   ^os.File,
	seen:      int, // The bytes of the log that the Wait steps used.
	output:    string, // The file of the log of the kernel.
	x, y:      int, // The pointer.
	pointer_known: bool, // The tool knows where the pointer is.
	film_frames: int, // The pictures of the film that the tool asked for.
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

WINDOW_GRAB_X :: 100 // A point of the title bar of each window.
WINDOW_GRAB_Y :: 12
// The close button of a window, as the compositor draws it: its center, from
// the right side and from the top of the window.
WINDOW_BORDER :: 2
WINDOW_CLOSE_RIGHT :: 14
WINDOW_CLOSE_Y :: 12

// window_width gives the width of the surface of the last window with a
// title: "compositor: surface title 480x320 at 276,232".
window_width :: proc(machine: ^Machine, title: string) -> (width: int, ok: bool) {
	text := log_read(machine)
	mark := strings.concatenate({"compositor: surface ", title, " "}, context.temp_allocator)
	made := strings.last_index(text, mark)
	if made < 0 {
		return 0, false
	}
	size := text[made + len(mark):]
	return strconv.parse_int(size[:max(strings.index_byte(size, 'x'), 0)])
}

// window_place gives the place of the last window with a title. The
// compositor writes it when it makes the window, and when a person puts the
// window down: "compositor: surface title 480x320 at 276,232" and
// "compositor: window title moved to 60,742".
window_place :: proc(machine: ^Machine, title: string) -> (x, y: int, ok: bool) {
	text := log_read(machine)
	made := strings.last_index(text, strings.concatenate({"compositor: surface ", title, " "}, context.temp_allocator))
	moved := strings.last_index(text, strings.concatenate({"compositor: window ", title, " moved to "}, context.temp_allocator))
	start := max(made, moved)
	if start < 0 {
		return 0, 0, false
	}
	line := text[start:]
	if end := strings.index_byte(line, '\n'); end >= 0 {
		line = line[:end]
	}
	mark := moved > made ? " moved to " : " at "
	at := strings.index(line, mark)
	if at < 0 {
		return 0, 0, false
	}
	place := strings.trim_space(line[at + len(mark):])
	comma := strings.index_byte(place, ',')
	if comma < 0 {
		return 0, 0, false
	}
	x = strconv.parse_int(place[:comma]) or_return
	y = strconv.parse_int(place[comma + 1:]) or_return
	return x, y, true
}

// log_read gives the complete lines of the log of the machine. QEMU writes
// the log one byte at a time: the last line can be a part of a line, and a
// part of "at 168,142" reads as another place.
log_read :: proc(machine: ^Machine) -> string {
	log, err := os.read_entire_file(machine.output, context.temp_allocator)
	if err != nil {
		return ""
	}
	return string(log[:strings.last_index_byte(string(log), '\n') + 1])
}

// windows_line gives the line of the last window with a title in the menu
// of the windows. The compositor writes the lines when the menu opens:
// "compositor: windows: console, life, monitor". from: the bytes of the
// log before the menu opened.
windows_line :: proc(machine: ^Machine, title: string, from: int) -> (line: int, ok: bool) {
	MARK :: "compositor: windows: "
	for start := time.now(); time.since(start) < STEP_TIMEOUT; {
		text := log_read(machine)
		at := len(text) > from ? strings.index(text[from:], MARK) : -1
		if at < 0 {
			time.sleep(50 * time.Millisecond)
			continue
		}
		text = text[from + at + len(MARK):]
		titles := strings.split(strings.trim_right(text[:strings.index_byte(text, '\n')], "\r"), ", ", context.temp_allocator)
		#reverse for name, index in titles {
			if name == title {
				return index, true
			}
		}
		return 0, false
	}
	return 0, false
}

log_wait :: proc(machine: ^Machine, text: string, any_order := false) -> bool {
	start := time.now()
	for time.since(start) < STEP_TIMEOUT {
		log := log_read(machine)
		if len(log) > machine.seen {
			if index := strings.index(log[machine.seen:], text); index >= 0 {
				if !any_order {
					machine.seen += index + len(text)
				}
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

// machine_test runs a scenario on a boot volume. It passes when each step
// passes and QEMU ends with the status exit_status.
machine_test :: proc(steps: []Step, volume: string, output: string, exit_status: int) -> bool {
	command, ok := machine_command(volume, output)
	if !ok {
		return false
	}
	_ = os.remove(output)
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
		output  = output,
	}
	passed := scenario_run(&machine, steps)
	state: os.Process_State
	if passed {
		wait_err: os.Error
		state, wait_err = os.process_wait(process, STEP_TIMEOUT)
		if wait_err != nil || !state.exited {
			fmt.eprintln("kerneltool: test failed: the machine did not stop")
			passed = false
		} else if state.exit_code != exit_status {
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
		log, _ := os.read_entire_file(output, context.temp_allocator)
		lines := strings.split_lines(string(log), context.temp_allocator)
		fmt.eprintln("kerneltool: the end of the log of the kernel:")
		for line in lines[max(len(lines) - 25, 0):] {
			fmt.eprintln("   ", line)
		}
	}
	return passed
}

scenario_run :: proc(machine: ^Machine, steps: []Step) -> bool {
	for step, index in steps {
		switch step.kind {
		case .Wait:
			if !log_wait(machine, step.text, step.any_order) {
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
		case .Key:
			monitor_send(machine, "sendkey ", step.text, " 20")
			time.sleep(KEY_PAUSE)
		case .Click, .Drag, .Launch, .Move, .Close, .Front:
			step := step
			moved_title: string
			moved_x, moved_y: int
			before := len(log_read(machine))
			if step.kind == .Close {
				x, y, found := window_place(machine, step.text)
				width, sized := window_width(machine, step.text)
				if !found || !sized {
					fmt.eprintfln("kerneltool: test failed: step %d: the log does not have the place of the window %s", index + 1, step.text)
					return false
				}
				step.kind = .Click
				step.x, step.y = x + width + 2 * WINDOW_BORDER - WINDOW_CLOSE_RIGHT, y + WINDOW_CLOSE_Y
			}
			if step.kind == .Move {
				// The compositor wrote where it put the window. The pointer
				// takes the title bar.
				x, y: int
				found: bool
				for start := time.now(); !found && time.since(start) < STEP_TIMEOUT; {
					if x, y, found = window_place(machine, step.text); !found {
						time.sleep(50 * time.Millisecond)
					}
				}
				if !found {
					fmt.eprintfln("kerneltool: test failed: step %d: the log does not have the place of the window %s", index + 1, step.text)
					return false
				}
				moved_title, moved_x, moved_y = step.text, step.to_x, step.to_y
				step.kind = .Drag
				step.x, step.y = x + WINDOW_GRAB_X, y + WINDOW_GRAB_Y
				step.to_x, step.to_y = step.to_x + WINDOW_GRAB_X, step.to_y + WINDOW_GRAB_Y
			}
			if step.kind == .Launch {
				found: bool
				step.x, step.y, found = launcher.center(step.text)
				if !found {
					fmt.eprintfln("error: the launcher does not have the program %s", step.text)
					return false
				}
			}
			if !machine.pointer_known {
				// The pointer starts at an unknown place: push it to the corner.
				machine.pointer_known = true
				for _ in 0 ..< 40 {
					monitor_send(machine, "mouse_move -100 -100")
					time.sleep(MOUSE_PAUSE)
				}
			}
			if step.kind == .Launch {
				menu_x, menu_y := launcher.button_center()
				pointer_move(machine, menu_x, menu_y)
				pointer_button(machine, true)
				pointer_button(machine, false)
			}
			if step.kind == .Front {
				menu_x, menu_y := launcher.windows_button_center()
				pointer_move(machine, menu_x, menu_y)
				pointer_button(machine, true)
				pointer_button(machine, false)
				line, found := windows_line(machine, step.text, before)
				if !found {
					fmt.eprintfln("kerneltool: test failed: step %d: the menu of the windows does not have %s", index + 1, step.text)
					return false
				}
				step.x, step.y = launcher.windows_line_center(line)
			}
			pointer_move(machine, step.x, step.y)
			pointer_button(machine, true)
			if step.kind == .Drag {
				pointer_move(machine, step.to_x, step.to_y)
			}
			pointer_button(machine, false)
			if step.kind == .Front {
				// The compositor writes that the window is in front.
				mark := strings.concatenate({"compositor: window ", step.text, " in front"}, context.temp_allocator)
				arrived := false
				for start := time.now(); !arrived && time.since(start) < STEP_TIMEOUT; {
					text := log_read(machine)
					if arrived = len(text) > before && strings.contains(text[before:], mark); !arrived {
						time.sleep(50 * time.Millisecond)
					}
				}
				if !arrived {
					fmt.eprintfln("kerneltool: test failed: step %d: the window %s did not come to the front", index + 1, step.text)
					return false
				}
				fmt.printfln("kerneltool: test passed: the window %s came to the front", step.text)
			}
			if moved_title != "" {
				// The compositor writes the new place: the window did move.
				arrived := false
				for start := time.now(); !arrived && time.since(start) < STEP_TIMEOUT; {
					x, y, found := window_place(machine, moved_title)
					if arrived = found && x == moved_x && y == moved_y; !arrived {
						time.sleep(50 * time.Millisecond)
					}
				}
				if !arrived {
					fmt.eprintfln("kerneltool: test failed: step %d: the window %s is not at %d,%d", index + 1, moved_title, moved_x, moved_y)
					return false
				}
			}
		case .Quit:
			monitor_send(machine, "quit")
		case .Shot:
			if !screen_save(machine, step.text) {
				return false
			}
		case .Film:
			// QEMU does the commands of the monitor in order: one file for each picture.
			start := time.tick_now()
			for time.tick_since(start) < time.Duration(step.x) * time.Millisecond {
				monitor_send(machine, "screendump ", fmt.tprintf(FILM_FRAME, machine.film_frames))
				machine.film_frames += 1
				time.sleep(FILM_FRAME_TIME - time.tick_since(start) % FILM_FRAME_TIME)
			}
		}
		free_all(context.temp_allocator)
	}
	return true
}
