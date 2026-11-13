package kerneltool

import "contract:glyph_cache"
import "contract:store"
import tree "support:storage_tree"
import "support:bar"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

// The machine test: the tool starts the machine under QEMU, and it acts as
// the input. It presses keys and moves the mouse through the QEMU monitor,
// it reads the log of the kernel, and it saves pictures of the screen.

SCREENSHOT_FOLDER :: BUILD_FOLDER + "/screenshots"
SCREEN_DUMP :: BUILD_FOLDER + "/screen.ppm"
FILM_FOLDER :: BUILD_FOLDER + "/film"
FILM_FRAME :: FILM_FOLDER + "/%05d.ppm"
FILM_RATE :: 25 // Pictures in one second.
FILM_FRAME_TIME :: time.Second / FILM_RATE
// The one role of a time in a test of the tool: it ends a test that hangs.
// A test checks a condition (a line, a value, a state), never a speed, so
// this bound is generous and the same for each wait of the tool that has no
// reason of its own: a loaded host runs the machine many times slower, and
// that says nothing about the system. It is larger than the bound of a hang
// in the checks of a program (TEST_HANG_BOUND_MILLISECONDS in
// support/system, 60 s), so that the program writes its own report first.
HANG_BOUND :: 120 * time.Second
// The bound of a Wait for the line of a case that writes a count of its
// progress, which the program reads: the program bounds a stall of the
// count and the whole case (TEST_PROGRESS_OVERALL_BOUND_MILLISECONDS in
// support/system, 600 s), and this bound is larger, so that the report of
// the program comes first.
PROGRESS_CASE_HANG_BOUND_SECONDS :: 660
// The bound of the first Wait of each machine: its boot ("compositor:
// surface console" and its like). The boot runs the firmware and the start
// of every service at once, the part of a machine test that a loaded host
// slows the most.
BOOT_HANG_BOUND :: 180 * time.Second
// The most pixels of one relative move of the virtual mouse, on each axis.
MOUSE_STEP :: 40
// The exit status of QEMU when the kernel stops the machine with code 0.
MACHINE_STOP_OK :: 1

// A line of 100 keys, none with Shift, so that the terminal sends 100 key
// presses for it: 1000 less 24 times 1, which is 976.
KEYS_HELD_LINE :: "1000 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1 - 1"
#assert(len(KEYS_HELD_LINE) == 100)

Step_Kind :: enum {
	Wait, // The log of the kernel has text, after the text of the last Wait.
	Date, // As Wait; then the number after text is a date of the machine in seconds since 1970, which date_check checks by order against the clock of the host.
	Type, // Press the keys of text, then Enter. When the console is in front, the tool then waits for the echo of the line on the log (console_echo.odin).
	Keys, // Press the keys of text, with no Enter.
	Key, // Press one key: text is its QEMU name.
	Click, // Press the left button at (x, y).
	Launch, // Open the menu of the programs, and press the line of the program text.
	Drag, // Hold the left button from (x, y) to (to_x, to_y).
	Shot, // Save the screen as text.png.
	Move, // Drag the window with the title text to the place (to_x, to_y). The tool reads the place of the window in the log, before and after.
	Front, // Open the menu of the windows, and press the line of the last window with the title text: the window comes to the front. The tool reads the lines of the menu in the log.
	Close, // Press the close button of the window with the title text. The tool reads the place and the size of the window in the log.
	Film, // Save the screen 25 times in one second, for x milliseconds, as the next pictures of the film.
	Quit, // End QEMU: the machine does not stop by itself.
	Monitor, // Send the line text to the QEMU monitor, as it is (for example "nmi": a non-maskable interrupt to each processor).
	Trace, // The log has text, after the text of the last Wait, then a stack trace to the end of the line: the tool takes the name that the system wrote in a frame, or names a frame "module + offset" from the debug object of its module, and the names start with `names`.
	Record, // A log record with the program `program`, the channel `channel`, the level `level` and a text that has `text`, after the record of the last Record step: the tool reads log.records() through the remote service (call.odin). With any_order, the next Record step searches from the same place.
	Agree, // The program `text`: the mapped pages and the threads that inspect.mappings() and inspect.threads() give are the ones that monitor.programs() gives (two tools, two reports of the kernel).
	Power_Loss, // The disk that the tool serves loses its power at the first write of a root after a seeded count of writes (1 to 40 after this step): it answers nothing more, and the tool ends QEMU with no warning (power_loss.odin).
	Call, // Call an export of a service from the host (call.odin), through the remote service: what the tool prints has `expected`. With `rows_call`, that call gives the count of rows of the Table. With `repeat`, the tool also measures the round trip and the calls in one second.
	Peer, // The peer runs the TCP case text (peer_tcp.odin) and checks its answers.
	Point, // Move the pointer to (x, y) with no press, then read compositor.pointer(): its shape must be the name text (docs/POINTERS.md). With inside_window, (x, y) are from the corner of that window, its title bar included; a negative x is from its right side. It needs the confirmation of the pointer (a Call with pointer before it).
	Remember, // The rest of the line after the text, in the log after the last Wait, is kept for the step Distinct (a value that the machine drew).
	Distinct, // Each value that Remember kept in this test part differs from each other one; text names them.
	// As Wait; then the number after text is the base of the generations of
	// the storage service for the steps after it: a later step names
	// {generation} or {generation+N} in its text or its expected text. A
	// generation counts the commits of the whole disk, and the console
	// commits its line history after each line: a step counts from a base
	// near it, not from the format of the disk.
	Generation,
	Peer_Start, // The peer starts the TCP case text; the next steps run while it runs.
	Peer_Result, // The end of the case of the last Peer_Start: it must pass. text is its name.
	Peer_Mark, // The case of the last Peer_Start learns that the action that it waits for comes now, at the next step. text is its name.
	Fetch, // The TCP of the host fetches the page text of `server` through QEMU user networking (web_host.odin).
	Http, // The TCP of the host runs the HTTP case text against `server` (web_host.odin, http_case_run); `expected` is the body that a page must have.
	Quic_Key, // As Remember: the 64 hexadecimal digits after text, in the log after the last Wait, are the public key of a QUIC server, which the QUIC client of the peer pins (peer_quic.odin).
	Peer_Quic, // The peer runs the QUIC case text (peer_quic.odin) and checks its answers.
	Openssl_Quic, // `openssl s_client -quic` of the host sends the line text to quic_echo through the UDP relay of the peer, and must get it back, from the key that the step Quic_Key read (quic_real.odin, peer_relay.odin).
	Remote_Key, // As Quic_Key, for the QUIC client of `remote` in the peer (peer_remote.odin): each Call after it goes over QUIC with this key.
	Remote_Case, // The peer runs the case text of `remote` (peer_remote.odin, remote_case_run) and checks its outcome.
}

Step :: struct {
	kind:       Step_Kind,
	text:       string,
	x, y:       int,
	to_x, to_y: int,
	// For Wait: the next Wait searches from the same place. Use it when two
	// programs print in an order that the system does not fix.
	any_order:  bool,
	// For Wait: the bound of a hang of this step in seconds, in place of
	// HANG_BOUND, for a step with a reason of its own that is not speed. It
	// is a named constant whose comment gives that reason: kerneltool check
	// refuses a number here.
	seconds:    int,
	fails_on:   string, // For Wait: a text that ends the wait as a failure when the machine prints it first: the step names its two outcomes.
	names:      string, // For Trace: the names of the functions of the first frames, separated by spaces.
	expected:   string, // For Call: a part of what the tool prints.
	outcome:    Call_Outcome, // For Call: Result, Failed or Refused.
	rows_call:  string, // For Call: a call whose Integer result is the count of rows of the Table.
	lose:       int, // For Call: the peer drops this many datagrams of `remote` to the host; QUIC sends them again, and monitor.served() shows that the call ran one time.
	wrong_hash: bool, // For Call: the request names another hash of the module.
	program:    string, // For Record: the program that wrote the record.
	channel:    string, // For Record: its channel ("" for none).
	level:      string, // For Record: info, debug, warning or error.
	pointer:    bool, // For Call: when the call has its result, the tool confirms each place of the pointer from now on (pointer_confirm).
	repeat:     int, // For Call: the calls of the measure of the round trip.
	least_answer_bytes: int, // For Call: the least bytes of the answer on its stream.
	inside_window: string, // For Click: (x, y) are inside the surface of the window with this title, as the log of the compositor places it. For Point: from the corner of the window.
	date_after: string, // For Call: the number after this text in what the tool prints is a date of the machine in milliseconds since 1970, which date_check checks by order against the clock of the host.
}

// The two clocks agree to whole seconds: the machine reads its real-time
// clock in whole seconds, and a date can be rounded down on one side and up
// on the other. It is not a bound on a delay: date_check checks by order.
DATE_TOLERANCE_SECONDS :: 5

// date_check checks a date of the machine, in seconds since 1970, by order
// against the clock of the host: not before earliest, a date of the host
// before the machine wrote it, and not after the date of the host now. QEMU
// gives the machine the clock of the host as its real-time clock (-rtc
// base=utc). The time between the two dates of the host is how late the
// tool read the date, which a loaded host stretches: it is no fault.
date_check :: proc(index: int, machine_seconds: i64, what: string, earliest: i64) -> bool {
	host := time.time_to_unix(time.now())
	if machine_seconds < earliest - DATE_TOLERANCE_SECONDS || machine_seconds > host + DATE_TOLERANCE_SECONDS {
		fmt.eprintfln("kerneltool: test failed: step %d: the date of the machine (%s) is %d, not between %d and %d, the dates of the host before it was written and now", index + 1, what, machine_seconds, earliest, host)
		return false
	}
	test_passed_print("the date of the machine (%s) is %d s since 1970, between %d and %d on the host", what, machine_seconds, earliest, host)
	return true
}

// generation_expand writes the base of the generations in a text: each
// {generation} is the base, and each {generation+N} the base and N. A mark
// with no end, or an N that is not a number, stays as it is: the step then
// waits for a text that the machine does not print, and fails.
generation_expand :: proc(text: string, base: i64) -> string {
	MARK :: "{generation"
	if !strings.contains(text, MARK) {
		return text
	}
	builder := strings.builder_make(context.temp_allocator)
	rest := text
	for {
		at := strings.index(rest, MARK)
		if at < 0 {
			strings.write_string(&builder, rest)
			break
		}
		strings.write_string(&builder, rest[:at])
		after := rest[at + len(MARK):]
		end := strings.index_byte(after, '}')
		offset: i64
		ok := end >= 0
		if ok && end > 0 {
			ok = after[0] == '+'
			if ok {
				offset, ok = strconv.parse_i64(after[1:end])
			}
		}
		if !ok {
			strings.write_string(&builder, MARK)
			rest = after
			continue
		}
		strings.write_i64(&builder, base + offset)
		rest = after[end + 1:]
	}
	return strings.to_string(builder)
}

// number_after reads the decimal number after a text in another text.
number_after :: proc(text: string, after: string) -> (value: i64, found: bool) {
	at := strings.index(text, after)
	if at < 0 {
		return 0, false
	}
	rest := text[at + len(after):]
	end := 0
	for end < len(rest) && (rest[end] >= '0' && rest[end] <= '9' || end == 0 && rest[end] == '-') {
		end += 1
	}
	return strconv.parse_i64(rest[:end])
}

// A start that fails: the boot image has no compositor. The boot display
// stays on the screen with the failure, and the machine does not stop.
// Before it, the trusted boot of a machine with no TPM: the boot program
// verifies the system description and says that nothing verified it, and
// the root service checks the boot image.
scenario_fails := [?]Step {
	// The test signing key, or the key of SYSTEM_SIGNING_KEY.
	{kind = .Wait, text = "boot program: the signature is from the "},
	{kind = .Wait, text = "boot program: verified by the boot program, which the firmware did not verify"},
	{kind = .Wait, text = "boot program: the kernel and each module and resource have the hash of the system description"},
	{kind = .Wait, text = "boot program: the firmware has no TPM protocol: the system description is not measured"},
	{kind = .Wait, text = "boot program: ok"},
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "root: ok"},
	{kind = .Wait, text = "root: the boot image agrees with the system description that the boot program verified: "},
	{kind = .Wait, text = "root: the system description is not measured into the TPM"},
	{kind = .Wait, text = "root: cannot start the compositor: status "},
	{kind = .Wait, text = "root: the boot display shows the failure"},
	{kind = .Shot, text = "boot_fails"},
	{kind = .Quit},
}

// Persistence: three machines with one data disk. The first one starts
// from a new disk: the scenario types a note in `notes` and counts 1000 (1000
// commits), then stops the machine. The second one finds the note and the
// count; the scenario counts again, and the tool ends QEMU in the middle of
// the commits, with no stop of the machine. The third one finds a store
// that the checks accept, and a count of one commit: its three blocks agree.
scenario_persist_first := [?]Step {
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	// The storage service starts at boot, for the boot pass of settings.
	{kind = .Wait, text = "root: started storage", any_order = true},
	{kind = .Wait, text = "storage: ok, a new disk: generation 1, 16384 blocks", any_order = true},
	{kind = .Wait, text = "settings: the boot pass: no settings kept: the defaults", any_order = true},
	{kind = .Wait, text = "root: settings stopped with code 0"},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "root: started notes"},
	{kind = .Wait, text = "notes: a new store: no note, the count 0", any_order = true},
	{kind = .Wait, text = "compositor: surface notes"},
	{kind = .Type, text = "kept across a restart"},
	{kind = .Wait, text = "notes: the note is \"kept across a restart\", generation 22"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "notes: count 1000, stopped: 1000 commits in "},
	{kind = .Wait, text = "notes: the versions of the count: 1000 rows in "},
	// A setting that the next machine finds (the boot pass of settings).
	{kind = .Launch, text = "settings"},
	{kind = .Wait, text = "compositor: surface settings", any_order = true},
	{kind = .Wait, text = "settings: ok, "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"settings\")"},
	{kind = .Wait, text = "[console]   module     settings"},
	{kind = .Wait, text = "[console]   commands   3"},
	{kind = .Wait, text = "[console]   call       service"},
	{kind = .Type, text = "settings.set(\"font\", \"spleen\")"},
	{kind = .Wait, text = "settings: font spleen, subpixel order rgb, pointer theme owner, grid fit on; kept in the store"},
	// A line for the next machine: the console keeps its line history in
	// its store, after each line and before shutdown().
	{kind = .Type, text = "length(\"kept across a stop\")"},
	{kind = .Wait, text = "[console] 18"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

scenario_persist_second := [?]Step {
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	// 1 + 21 commits of the note, 1000 of the count, 1 of the settings, and
	// 4 of the line history of the console: after connect, after set,
	// after length, and before shutdown(). The stores of notes, settings
	// and the history of the console; the history is one object.
	{kind = .Wait, text = "storage: ok, generation 1027: 3 stores, 4 objects, ", any_order = true},
	{kind = .Wait, text = "console: the line history: 4 lines kept from before the stop", any_order = true},
	// The setting of the machine before: the desktop draws in Spleen 8x16.
	{kind = .Wait, text = "settings: the boot pass: the settings kept in the store: font spleen, subpixel order rgb, pointer theme owner, grid fit on; in ", any_order = true},
	{kind = .Wait, text = " blocks checked, 0 wrong, in ", any_order = true},
	{kind = .Wait, text = "compositor: the settings changed: font spleen, subpixel order rgb, pointer theme owner, grid fit on; "},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "notes: restored the note \"kept across a restart\" and the count 1000, its 3 blocks agree", any_order = true},
	{kind = .Wait, text = "compositor: surface notes"},
	{kind = .Shot, text = "notes"},
	// The vector font again, for the machines after this one.
	{kind = .Launch, text = "settings"},
	{kind = .Wait, text = "compositor: surface settings", any_order = true},
	{kind = .Wait, text = "settings: ok, font spleen, subpixel order rgb, pointer theme owner, grid fit on"},
	{kind = .Shot, text = "settings_kept"},
	{kind = .Front, text = "console"},
	// The line history of the machine before: Up gives shutdown(), a second
	// Up the line before it; Enter runs it.
	{kind = .Key, text = "up"},
	{kind = .Key, text = "up"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "> length(\"kept across a stop\")"},
	{kind = .Wait, text = "[console] 18"},
	// The search finds it too: Enter puts it in the input, a second Enter
	// runs it.
	{kind = .Key, text = "ctrl-r"},
	{kind = .Keys, text = "kept"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "console: the history search gave the line length(\"kept across a stop\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] 18"},
	{kind = .Type, text = "connect(\"settings\")"},
	{kind = .Wait, text = "[console]   module     settings"},
	{kind = .Wait, text = "[console]   commands   3"},
	{kind = .Wait, text = "[console]   call       service"},
	{kind = .Type, text = "settings.set(\"font\", \"vector\")"},
	{kind = .Wait, text = "settings: font vector, subpixel order rgb, pointer theme owner, grid fit on; kept in the store"},
	{kind = .Front, text = "notes"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "notes: count 1100"},
	{kind = .Quit}, // In the middle of the commits: the machine does not stop.
}

scenario_persist_crash := [?]Step {
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "storage: ok, generation ", any_order = true},
	{kind = .Wait, text = " blocks checked, 0 wrong, in ", any_order = true},
	{kind = .Wait, text = "notes: restored the note \"kept across a restart\" and the count ", any_order = true},
	{kind = .Wait, text = ", its 3 blocks agree, the last run stopped before its end", any_order = true},
	{kind = .Wait, text = "compositor: surface notes"},
	{kind = .Shot, text = "notes_crash"},
	{kind = .Quit},
}

// A block of data that changed on the disk outside the service: the tool
// changes one byte of the note. Each valid root names the block, so no
// root is better: the storage service serves, with one damaged object. The
// count is whole. `notes` says that the note is damaged, and does not take
// it for an empty note. A key writes a new note in place of it.
scenario_persist_damaged := [?]Step {
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "storage: 1 blocks have a wrong check: 1 objects and 0 stores are damaged; the service serves the others", any_order = true},
	{kind = .Wait, text = " blocks checked, 1 wrong, in ", any_order = true},
	{kind = .Wait, text = "notes: WRONG: the storage service cannot give the note: the object is damaged; restored the count ", any_order = true},
	{kind = .Wait, text = "compositor: surface notes"},
	{kind = .Shot, text = "notes_damaged"},
	{kind = .Type, text = "again"},
	{kind = .Wait, text = "notes: the note is \"again\", generation "},
	{kind = .Quit},
}

// After the new note: no wrong block, and the note and the count.
scenario_persist_replaced := [?]Step {
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = " blocks checked, 0 wrong, in ", any_order = true},
	{kind = .Wait, text = "notes: restored the note \"again\" and the count ", any_order = true},
	{kind = .Wait, text = "compositor: surface notes"},
	{kind = .Quit},
}

// A wrong block that only the newest root names: the last commit is not
// whole on the disk. The root before it names no wrong block, so the
// storage service uses it: the note is the note before its last letter.
scenario_persist_older := [?]Step {
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "storage: the newest root names a block with a wrong check, and the root before it names none: the root before it is used", any_order = true},
	{kind = .Wait, text = " blocks checked, 0 wrong, in ", any_order = true},
	{kind = .Wait, text = "notes: restored the note \"agai\" and the count ", any_order = true},
	{kind = .Quit},
}

// A format that a stop cut: a first root with a wrong check, and no commit
// after it. The disk holds no object: the storage service formats again.
scenario_persist_first_cut := [?]Step {
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "storage: the first root of the disk has a wrong check and no commit followed it", any_order = true},
	{kind = .Wait, text = "storage: ok, a new disk: generation 1, 16384 blocks", any_order = true},
	{kind = .Wait, text = "notes: a new store: no note, the count 0", any_order = true},
	{kind = .Quit},
}

// A root block that a stop cut: the tool writes zero bytes over the second
// half of the root with the highest generation, as a write that the machine
// did not finish. The storage service finds the wrong check and uses the
// root before it: the count of the commit before.
scenario_persist_cut := [?]Step {
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = " has a wrong check: a write that a stop cut; the service uses the root before it", any_order = true},
	{kind = .Wait, text = " blocks checked, 0 wrong, in ", any_order = true},
	{kind = .Wait, text = "notes: restored the note \"kept across a restart\" and the count ", any_order = true},
	{kind = .Wait, text = ", its 3 blocks agree, the last run stopped before its end", any_order = true},
	{kind = .Wait, text = "compositor: surface notes"},
	{kind = .Quit},
}

// The network: a machine of its own. The network service starts when `net`
// starts, with the frame service of the network device. The peer of the
// tool (peer.odin) is the gateway and the echo server. `net` shows each
// case, then the measures. The scenario revokes the grant of the network:
// the next datagram is refused. Then the endpoint ends with its program,
// and each page is free or paid.
TEST_OUTPUT_NETWORK :: BUILD_FOLDER + "/test_output_network.txt"

scenario_network := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Launch, text = "net"},
	{kind = .Wait, text = "root: started frame for the device at the place 18 of the bus"},
	{kind = .Wait, text = "frame: ok, the hardware address 52:54:00:12:34:56, the link is up", any_order = true},
	{kind = .Wait, text = "root: started network"},
	{kind = .Wait, text = "network: ok, the address 10.0.2.15/24 52:54:00:12:34:56, the gateway 10.0.2.2, the link is up", any_order = true},
	{kind = .Wait, text = "network: the headers of IPv4 and Ethernet of a frame with a payload of 1480 bytes: ", any_order = true},
	{kind = .Wait, text = "network: an endpoint for net: the local port 49152, the grant 10.0.2.2 port 7", any_order = true},
	{kind = .Wait, text = "root: started net"},
	{kind = .Wait, text = "net: the link and the address: 10.0.2.15/24, the link is up, 52:54:00:12:34:56"},
	{kind = .Wait, text = "net: ARP: who has 10.0.2.2: the gateway answered 52:55:0a:00:02:02 in "},
	{kind = .Wait, text = "net: ICMP echo to 10.0.2.2, 56 bytes: the echo reply came in "},
	{kind = .Wait, text = "net: UDP to 10.0.2.2 port 7, 41 bytes: the same 41 bytes came back from 10.0.2.2 port 7 in "},
	{kind = .Wait, text = "net: UDP to 10.0.2.2 port 9: refused: datagram.Send: the argument address, 10.0.2.2 port 9, is refused: the grant names 10.0.2.2 port 7 only"},
	{kind = .Wait, text = "net: ICMP echo to 10.0.2.3: refused: datagram.Echo: the argument address, 10.0.2.3, is refused: the grant names 10.0.2.2 port 7 only"},
	{kind = .Wait, text = "net: UDP of 2000 bytes: refused, no fragment: datagram.Send: the argument count has 2000 bytes; it can have at most 1480 bytes"},
	// The program writes the UDP header: the network service checks the
	// source port in its own copy of it.
	{kind = .Wait, text = "net: UDP from the source port 1234: refused: the source port 1234 of the header is not the local port of this endpoint, 49152"},
	// The network service refuses a datagram whose length field is not its
	// count of bytes, and a datagram shorter than its header.
	{kind = .Wait, text = "net: UDP with a wrong length field: refused: the length field of the header says 29 bytes, the Send has 28"},
	{kind = .Wait, text = "net: UDP of 7 bytes: refused: the Send has 7 bytes, a datagram has 8 bytes at least, its header"},
	// The network service computes no checksum of a datagram: the datagram
	// of the peer with a wrong one reaches the endpoint of its port, and
	// the program drops it.
	{kind = .Wait, text = "net: UDP from 10.0.2.2 port 7 with a wrong checksum: dropped by this program: 1 datagram; the network service gave it to the endpoint of its port"},
	// The row of the endpoint names its own grant; the rows of the machine
	// need the right Inspect, that `net` has with the machine.
	{kind = .Wait, text = "net: refused for this endpoint: 1 x udp, byte 34: the remote port 9 is not the port of the grant, 7"},
	{kind = .Wait, text = "net: refused for the machine: 1 x ipv4, byte 24: the checksum is 0x"},
	{kind = .Wait, text = "net: UDP from 10.0.2.2 port 9 to this endpoint: refused: from port 9; a row of this endpoint"},
	{kind = .Wait, text = "net: malformed frames from the wire: 9 refused in 9 kinds, 9 of 9 expected; no fault"},
	{kind = .Wait, text = "net: ICMP echo from 10.0.2.2 to this machine: the network service answered 1 request"},
	{kind = .Wait, text = "net: ok, 14 cases"},
	{kind = .Wait, text = "net: the header and the checksum of a datagram of 1472 bytes: "},
	{kind = .Wait, text = "net: the round trip of one datagram of 64 bytes: "},
	{kind = .Wait, text = "net: a burst with 64 datagrams in flight: "},
	{kind = .Wait, text = " datagrams in one second, sent and answered, 0 lost"},
	{kind = .Wait, text = "net: kernel entries for each datagram: "},
	{kind = .Wait, text = "net: the measures are done"},
	{kind = .Shot, text = "network"},
	// The grant is a record of the root service: the scenario lists it and
	// revokes it. The network service ends the grant of the endpoint.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "grants(\"net\")"},
	{kind = .Wait, text = "[console] net      log      held"},
	{kind = .Wait, text = "[console] net      machine  held"},
	{kind = .Wait, text = "[console] net      network  held"},
	{kind = .Type, text = "revoke(\"net\", \"network\")"},
	{kind = .Wait, text = "root: revoked the grant network of net, endpoints changed: 1", any_order = true}, // The network service can write its line first.
	{kind = .Wait, text = "network: the grant of the endpoint of net changed: none"},
	{kind = .Front, text = "net"},
	{kind = .Key, text = "spc"},
	{kind = .Wait, text = "net: a datagram to 10.0.2.2 port 7 after a key: refused, the endpoint has no grant now: datagram.Send: the argument address, 10.0.2.2 port 7, is refused: the grant names no remote"},
	{kind = .Close, text = "net"},
	{kind = .Wait, text = "root: net stopped with code 0"},
	{kind = .Wait, text = "network: the endpoint of net ended: "},
	// The passes of the network service over the bytes of the datagrams of
	// `net`: a measure, then the structural count: one copy each way, and no
	// checksum.
	{kind = .Wait, text = "network: a measure: the endpoint of net, UDP: the passes of this service over the data for each payload byte: "},
	{kind = .Wait, text = "network: the endpoint of net, UDP: this service read each payload byte one time on receive and one time on send, for the copy, and computed no checksum of it: as it must"},
	// The calls of the host (docs/MODULE_CONTRACT.md, "A call from the
	// host"). The remote service holds an endpoint whose grant names the
	// host, and connects to the services that the root service names for it.
	{kind = .Launch, text = "monitor"},
	{kind = .Wait, text = "compositor: surface monitor"},
	{kind = .Launch, text = "manual"},
	{kind = .Wait, text = "compositor: surface manual"},
	{kind = .Launch, text = "remote"},
	{kind = .Wait, text = "root: started remote"},
	{kind = .Remote_Key, text = "remote: the public key of this service: "},
	{kind = .Wait, text = "remote: listening on the UDP port 7100, for the host 10.0.2.2 only", any_order = true},
	// Six malformed call requests, each on its own stream: each one has its
	// error record, and no call runs.
	{kind = .Remote_Case, text = "malformed"},
	{kind = .Wait, text = "remote: refused a request: remote: the call has 20 bytes; it must have at least 104 bytes"},
	{kind = .Wait, text = "remote: refused a request: remote: the argument kind has the value 9, which the call refuses; it takes at most 1"},
	{kind = .Wait, text = "remote: refused a request: remote: the argument arguments has 400 bytes; it can have at most 16 bytes"},
	{kind = .Wait, text = "remote: refused a request: remote: the argument result_count has 65536 bytes; it can have at most 65472 bytes"},
	{kind = .Wait, text = "remote: refused a request: remote: the argument error_start has the value 28, which the call refuses; it takes at most 65480"},
	{kind = .Wait, text = "remote: refused a request: remote: the caller has no grant for this: a connection to this service"},
	// The place of the pointer and the windows: each press from now on is
	// confirmed.
	{kind = .Call, text = "compositor.pointer()", expected = "1 rows of Pointer", pointer = true},
	{kind = .Call, text = "compositor.windows()", expected = "rows of Window"},
	// An Integer, with the measure of a small call.
	{kind = .Call, text = "monitor.count(\"processors\")", expected = "4", repeat = 1000},
	{kind = .Wait, text = "root: connected remote to the service monitor", any_order = true},
	{kind = .Wait, text = "remote: connected to the service monitor"},
	{kind = .Wait, text = "remote: the window drew one picture in ", any_order = true},
	// A Table: the row of the remote service is there, and the count of the
	// rows is the count that the monitor wrote on the log.
	{kind = .Call, text = "monitor.programs()", expected = "remote", rows_call = "monitor.count(\"programs\")"},
	// A lost datagram: QUIC sends it again, and the call runs one time.
	{kind = .Call, text = "monitor.count(\"processors\")", expected = "4", lose = 1},
	// Another module than the one that runs: the remote service refuses it,
	// and the tool names the two hashes.
	{kind = .Call, text = "monitor.count(\"processors\")", outcome = .Refused, wrong_hash = true, expected = "the request named "},
	{kind = .Wait, text = "remote: refused a request: remote: the argument hash has the value 0, which the call refuses"},
	{kind = .Call, text = "monitor.counts()", expected = "15 rows of Count"},
	// A Record: the counts of the monitor itself, which each caller sees.
	{kind = .Call, text = "monitor.served()", expected = "Served{calls = "},
	// A result larger than one datagram, on one stream.
	{kind = .Call, text = "manual.modules()", expected = " rows of Module", least_answer_bytes = 1201},
	{kind = .Call, text = "manual.running()", expected = " rows of Running"},
	// A Text, from a service that starts at the first connection.
	{kind = .Call, text = "storage.stores()", expected = " blocks in use"},
	// Failures: the sentence of the error record of the service.
	{kind = .Call, text = "monitor.count(\"nothing\")", outcome = .Failed, expected = "error: monitor.count: the argument name names nothing that exists (-3)"},
	{kind = .Call, text = "storage.size(0, \"note\")", outcome = .Failed, expected = "error: storage.size: the caller has no grant for this: a private store (-1)"},
	{kind = .Call, text = "manual.exports(\"nothing\")", outcome = .Failed, expected = "error: manual.exports: the argument name names none of the modules (-1)"},
	// The tool checks the arguments against the description before it sends.
	{kind = .Call, text = "monitor.count(4)", outcome = .Wrong, expected = "error: the parameter name of monitor.count is a Text, the argument is an Integer"},
	// The transport (docs/QUIC.md, section 7). Two calls at one time, on two
	// streams: each answer on its own stream, in any order.
	{kind = .Remote_Case, text = "two at once"},
	// A request of more than a header and a call region: reset with
	// Too_Large, and no call.
	{kind = .Remote_Case, text = "too large"},
	{kind = .Wait, text = ": a request of more than 65640 bytes: reset with the code Too_Large, and no call"},
	// A stream with a part of a request and no end: reset with Timeout at
	// the bound of a request, in time of the machine.
	{kind = .Remote_Case, text = "a part and no end"},
	{kind = .Wait, text = " ms of the machine; the bound of a request held"},
	// A datagram from an address that the listen grant does not admit gets
	// nothing: the network service drops it before remote.
	{kind = .Remote_Case, text = "stranger"},
	// The connection of the peer lost: remote ends it at its idle bound, in
	// time of the machine, and the next call opens a new connection.
	{kind = .Remote_Case, text = "silence"},
	{kind = .Wait, text = ": the idle end held its bound: "},
	{kind = .Remote_Case, text = "silence ends"},
	// The scenario lists the grant, and revokes it: the services refuse what
	// they give only to a caller that acts for the principal.
	// The developer tool serves its tables to a caller that acts for the
	// principal: the remote service, until the revocation below.
	{kind = .Launch, text = "inspect"},
	{kind = .Wait, text = "inspect: ok, "},
	{kind = .Call, text = "inspect.mappings(\"remote\")", expected = " rows of Mapping"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "grants(\"remote\")"},
	{kind = .Wait, text = "[console] remote   log                 held"},
	{kind = .Wait, text = "[console] remote   network             held"},
	{kind = .Wait, text = "[console] remote   acts_for_principal  held"},
	{kind = .Type, text = "revoke(\"remote\", \"acts_for_principal\")"},
	{kind = .Wait, text = "root: revoked the grant acts_for_principal of remote, connections changed: 5"},
	{kind = .Call, text = "inspect.mappings(\"remote\")", outcome = .Failed, expected = "error: inspect.mappings: the caller has no grant for this: to act for the principal (-1)"},
	{kind = .Call, text = "inspect.threads(\"remote\")", outcome = .Failed, expected = "error: inspect.threads: the caller has no grant for this: to act for the principal (-1)"},
	{kind = .Call, text = "inspect.modules(\"remote\")", outcome = .Failed, expected = "error: inspect.modules: the caller has no grant for this: to act for the principal (-1)"},
	{kind = .Call, text = "monitor.programs()", outcome = .Failed, expected = "error: monitor.programs: the caller has no grant for this: to act for the principal (-1)"},
	// The place of the pointer is a fact of the screen: the
	// tool moves the pointer with no confirmation again.
	{kind = .Call, text = "compositor.pointer()", outcome = .Failed, pointer = true, expected = "error: compositor.pointer: the caller has no grant for this: to act for the principal (-1)"},
	// The window of inspect covers the windows under it: it closes now.
	{kind = .Close, text = "inspect"},
	{kind = .Wait, text = "root: inspect stopped with code 0"},
	{kind = .Call, text = "manual.running()", outcome = .Failed, expected = "error: manual.running: the caller has no grant for this: to act for the principal (-3)"},
	{kind = .Call, text = "storage.stores()", expected = "no grant to see the stores"},
	{kind = .Call, text = "manual.modules()", expected = " rows of Module"},
	{kind = .Call, text = "monitor.served()", expected = "Served{calls = "},
	{kind = .Front, text = "remote"},
	{kind = .Shot, text = "remote"},
	// The desktop: the scenario closes remote and manual, the palette starts
	// two programs, and the scenario places four windows. The title bar of
	// the window in front goes from blue to a darker blue; the other title
	// bars are quiet.
	{kind = .Close, text = "remote"},
	{kind = .Wait, text = "root: remote stopped"},
	{kind = .Close, text = "manual"},
	{kind = .Wait, text = "root: manual stopped"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "lif"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette starts life"},
	{kind = .Wait, text = "compositor: surface life"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "pla"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette starts plasma"},
	{kind = .Wait, text = "compositor: surface plasma"},
	// The windows move from the one in front to the one at the back: no
	// window covers the title bar of the next one. The console covers the
	// title bar of monitor: monitor comes to the front first. Then each
	// window comes to the front, from the back to the front.
	{kind = .Move, text = "plasma", to_x = 440, to_y = 120},
	{kind = .Move, text = "life", to_x = 8, to_y = 416},
	{kind = .Front, text = "monitor"},
	{kind = .Move, text = "monitor", to_x = 576, to_y = 384},
	{kind = .Move, text = "console", to_x = 8, to_y = 40},
	{kind = .Front, text = "life"},
	{kind = .Front, text = "monitor"},
	{kind = .Front, text = "plasma"},
	{kind = .Shot, text = "desktop"},
	// The list narrows at each key, over the programs and the windows in
	// one ranking. Each name that starts with the typed part has one score:
	// the program that the palette started last comes first, then the
	// window, then the programs in the order of their table. The arrows
	// move the choice.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "p"},
	{kind = .Wait, text = " for \"p\": plasma (program), plasma (window), pages (program), paint (program), ..."},
	{kind = .Key, text = "down"},
	{kind = .Wait, text = "compositor: the palette chooses plasma (window)"},
	{kind = .Shot, text = "palette"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	// A part that no name has: the list is empty, and Enter runs nothing.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "xyz"},
	{kind = .Wait, text = "compositor: the palette lists 0 of "},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette has no entry to run"},
	{kind = .Shot, text = "palette_empty"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is closed by the key super"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "memory()"},
	{kind = .Wait, text = "free_pages_no_budget_holds  0"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// The data disk of the test of persistence, read with the format of the
// storage service (contract/store).
disk_open :: proc(path: string) -> (file: ^os.File, ok: bool) {
	err: os.Error
	if file, err = os.open(path, {.Read, .Write}); err != nil {
		fmt.eprintfln("kerneltool: cannot open %s: %v", path, err)
		return nil, false
	}
	return file, true
}

disk_block :: proc(file: ^os.File, number: u64, value: ^$T) -> bool where size_of(T) == store.BLOCK_SIZE {
	count, err := os.read_at(file, ([^]u8)(value)[:store.BLOCK_SIZE], i64(number * store.BLOCK_SIZE))
	if err != nil || count != store.BLOCK_SIZE {
		fmt.eprintfln("kerneltool: cannot read the block %d of the disk", number)
		return false
	}
	return true
}

// disk_root gives the valid root with the highest generation, and its place.
disk_root :: proc(file: ^os.File, root: ^store.Root) -> (place: u64, ok: bool) {
	roots: [2]store.Root
	disk_block(file, 0, &roots[0]) or_return
	disk_block(file, 1, &roots[1]) or_return
	found := false
	for &candidate, index in roots {
		if store.root_valid(&candidate, store.DISK_BLOCKS_LIMIT) && (!found || candidate.generation > root.generation) {
			root^, place, found = candidate, u64(index), true
		}
	}
	if !found {
		fmt.eprintln("kerneltool: the disk has no valid root")
	}
	return place, found
}

// root_cut writes zero bytes over the second half of the valid root block
// with the highest generation, as a write that the machine did not finish.
root_cut :: proc(path: string) -> bool {
	file := disk_open(path) or_return
	defer os.close(file)
	root: store.Root
	place := disk_root(file, &root) or_return
	zero: [store.BLOCK_SIZE / 2]u8
	if _, err := os.write_at(file, zero[:], i64(place * store.BLOCK_SIZE + store.BLOCK_SIZE / 2)); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", path, err)
		return false
	}
	fmt.printfln("kerneltool: the root block %d of %s is cut, generation %d", place, path, root.generation)
	return true
}

// object_damage changes one byte of the first block of data of an object:
// a change on the disk that the storage service did not make.
object_damage :: proc(path: string, store_name: string, object_name: string) -> bool {
	file := disk_open(path) or_return
	defer os.close(file)
	root: store.Root
	disk_root(file, &root) or_return
	name_of :: proc(bytes: []u8) -> string {
		count := 0
		for count < len(bytes) && bytes[count] != 0 {
			count += 1
		}
		return string(bytes[:count])
	}
	for &entry in root.stores {
		if name_of(entry.name[:]) != store_name {
			continue
		}
		block: store.Store_Block
		disk_block(file, entry.store.block, &block) or_return
		object, found := tree_entry_find(file, block.tree, object_name) or_return
		if found && object.kind == .Object && object.pointer.block != 0 {
			// The first block of data: down the first child of each object
			// node, or the root of an object of one block.
			number := object.pointer.block
			for level := store.object_levels(object.size); level >= 1 && number != 0; level -= 1 {
				node: store.Object_Node
				disk_block(file, number, &node) or_return
				next: u64
				for child in node.children {
					if child.block != 0 {
						next = child.block
						break
					}
				}
				number = next
			}
			if number == 0 {
				break
			}
			at := i64(number * store.BLOCK_SIZE)
			one: [1]u8
			if count, err := os.read_at(file, one[:], at); err != nil || count != 1 {
				return false
			}
			one[0] ~= 0x40
			if _, err := os.write_at(file, one[:], at); err != nil {
				fmt.eprintfln("kerneltool: cannot write %s: %v", path, err)
				return false
			}
			fmt.printfln("kerneltool: one byte of the block %d is changed: the first block of data of the object %s of the store %s, under the root of generation %d", number, object_name, store_name, root.generation)
			return true
		}
	}
	fmt.eprintfln("kerneltool: the disk has no object %s in a store %s", object_name, store_name)
	return false
}

// tree_entry_find finds an entry of a tree on a disk file: the walk down
// the B+ tree of the tree, as support/storage_tree does.
tree_entry_find :: proc(file: ^os.File, root: store.Pointer, name: string) -> (found_entry: store.Entry, found: bool, ok: bool) {
	key := store.entry_name(name)
	pointer := root
	for _ in 0 ..< store.TREE_DEPTH_LIMIT {
		if pointer.block == 0 {
			return {}, false, true
		}
		node: [store.BLOCK_SIZE]u8
		disk_block(file, pointer.block, &node) or_return
		header := (^store.Tree_Header)(&node)
		if header.level == 0 {
			size := size_of(store.Entry_Name) + size_of(store.Entry)
			for index in 0 ..< int(min(header.count, store.LEAF_CAPACITY)) {
				record := node[store.TREE_HEADER_SIZE + index * size:][:size]
				if tree.compare(record[:size_of(store.Entry_Name)], key[:]) == 0 {
					return (^store.Entry)(raw_data(record[size_of(store.Entry_Name):]))^, true, true
				}
			}
			return {}, false, true
		}
		size := size_of(store.Entry_Name) + size_of(store.Pointer)
		next := 0
		for index in 1 ..< int(min(header.count, store.BRANCH_CAPACITY)) {
			if tree.compare(node[store.TREE_HEADER_SIZE + index * size:][:size_of(store.Entry_Name)], key[:]) <= 0 {
				next = index
			}
		}
		pointer = (^store.Pointer)(raw_data(node[store.TREE_HEADER_SIZE + next * size + size_of(store.Entry_Name):]))^
	}
	return {}, false, true
}

// first_root_cut makes a new disk with a first root that a stop cut: the
// first half of a first root in block 1, and zero bytes after it.
first_root_cut :: proc(path: string) -> bool {
	disk_prepare(path, DATA_DISK_SIZE, true) or_return
	file := disk_open(path) or_return
	defer os.close(file)
	root := store.Root{magic = store.ROOT_MAGIC, generation = 1, disk_blocks = DATA_DISK_SIZE / store.BLOCK_SIZE}
	if _, err := os.write_at(file, ([^]u8)(&root)[:store.BLOCK_SIZE / 2], store.BLOCK_SIZE); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", path, err)
		return false
	}
	fmt.printfln("kerneltool: %s has a first root with no check: a format that a stop cut", path)
	return true
}

persistence_run :: proc() -> bool {
	disk_prepare(TEST_PERSIST_DISK, DATA_DISK_SIZE, true) or_return
	machine_test(scenario_persist_first[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_PERSIST, 1), MACHINE_STOP_OK, TEST_PERSIST_DISK) or_return
	machine_test(scenario_persist_second[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_PERSIST, 2), 0, TEST_PERSIST_DISK) or_return
	machine_test(scenario_persist_crash[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_PERSIST, 3), 0, TEST_PERSIST_DISK) or_return
	root_cut(TEST_PERSIST_DISK) or_return
	machine_test(scenario_persist_cut[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_PERSIST, 4), 0, TEST_PERSIST_DISK) or_return
	object_damage(TEST_PERSIST_DISK, "notes", "note") or_return
	machine_test(scenario_persist_damaged[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_PERSIST, 5), 0, TEST_PERSIST_DISK) or_return
	machine_test(scenario_persist_replaced[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_PERSIST, 6), 0, TEST_PERSIST_DISK) or_return
	// The last commit wrote the last letter of the note: only the newest
	// root names the block of data that the tool changes now.
	object_damage(TEST_PERSIST_DISK, "notes", "note") or_return
	machine_test(scenario_persist_older[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_PERSIST, 7), 0, TEST_PERSIST_DISK) or_return
	first_root_cut(TEST_PERSIST_DISK) or_return
	return machine_test(scenario_persist_first_cut[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_PERSIST, 8), 0, TEST_PERSIST_DISK)
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
		if !machine_test(steps[:], self_test_file(BOOT_VOLUME_SELF_TEST, test.number), self_test_file(TEST_OUTPUT_SELF_TEST, test.number), MACHINE_STOP_FAULT, TEST_DATA_DISK) {
			return false
		}
	}
	return true
}

// The positions below come from programs/compositor/main.odin: the buttons
// in the bar, and the place of window n at (60 + 36 n, 52 + 30 n).
scenario := [?]Step {
	{kind = .Wait, text = "boot program: ok"},
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "root: ok"},
	{kind = .Wait, text = "input: ok"},
	// The date: the program `date` starts after the input service and reads the real-time clock of the machine,
	// which QEMU takes from the clock of the host. The date must be within a
	// few seconds of the host.
	{kind = .Date, text = " UTC, seconds since 1970 ", any_order = true},
	// The measure of the copy and the fill of runtime/memory.asm, at the start
	// of the compositor, before its first frame.
	{kind = .Wait, text = "compositor: copy_bytes_without_overlap, ns for 8 64 512 4096 65536 3145600 bytes, aligned: ", any_order = true},
	{kind = .Wait, text = "compositor: fill_bytes_with_value, not aligned: ", any_order = true},
	{kind = .Wait, text = "compositor: the processor: ERMS ", any_order = true},
	// The two come in an order that the system does not fix.
	{kind = .Wait, text = "compositor: first frame", any_order = true},
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	// The boot pass of settings: the storage service starts at boot, with
	// the block service of the data disk; a new disk keeps no settings.
	{kind = .Wait, text = "storage: ok, a new disk: generation 1, 16384 blocks", any_order = true},
	// The console asks for the store of its line history at its start: the
	// root service answers after the start of the boot pass, so the storage
	// service runs.
	{kind = .Wait, text = "root: connected console to the store of its line history in the service storage, 4 blocks", any_order = true},
	{kind = .Wait, text = "console: no line history kept: the history starts empty", any_order = true},
	{kind = .Wait, text = "settings: the boot pass: no settings kept: the defaults: font vector, subpixel order rgb, pointer theme owner, grid fit on; in ", any_order = true},
	{kind = .Wait, text = "root: settings stopped with code 0"},

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
	{kind = .Type, text = "where(modules(), \"name\", \"compositor\")"},
	{kind = .Wait, text = "[console] compositor  "},
	{kind = .Type, text = "start(\"life\")"},
	{kind = .Wait, text = "life: ok", any_order = true},
	{kind = .Wait, text = "compositor: surface life"},
	{kind = .Shot, text = "console"},

	// The desktop: start programs from the menu of the bar and from the
	// palette, and move the windows.
	{kind = .Move, text = "life", to_x = 24, to_y = 408},
	{kind = .Launch, text = "monitor"},
	{kind = .Wait, text = "compositor: surface monitor"},
	{kind = .Move, text = "monitor", to_x = 568, to_y = 40},
	{kind = .Launch, text = "paint"},
	{kind = .Wait, text = "compositor: surface paint"},
	{kind = .Move, text = "paint", to_x = 520, to_y = 408},
	{kind = .Click, x = 60, y = 10, inside_window = "paint"}, // The red color.
	{kind = .Drag, x = 560, y = 520, to_x = 760, to_y = 700},
	{kind = .Click, x = 140, y = 10, inside_window = "paint"}, // The blue color.
	{kind = .Drag, x = 760, y = 520, to_x = 560, to_y = 700},
	{kind = .Drag, x = 800, y = 600, to_x = 960, to_y = 600},
	// The palette: the key super opens it. With no letter it lists the
	// windows, the front one first, then the programs.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Shot, text = "palette_open"},
	// Letters of a program: the list narrows at each key, over the windows
	// and the programs in one ranking, and each matched letter is marked.
	// Enter starts the chosen program.
	{kind = .Keys, text = "p"},
	{kind = .Wait, text = "compositor: the palette lists "},
	{kind = .Wait, text = " for \"p\": "},
	{kind = .Shot, text = "palette_programs"},
	{kind = .Keys, text = "la"},
	{kind = .Wait, text = " for \"pla\": plasma (program)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette starts plasma"},
	{kind = .Wait, text = "plasma: ok", any_order = true},
	{kind = .Wait, text = "compositor: surface plasma"},
	{kind = .Move, text = "plasma", to_x = 232, to_y = 144},
	{kind = .Shot, text = "desktop_moved"},
	// Letters of the title of a window: with equal scores the window comes
	// before the program of the same name. Enter brings the window to the
	// front.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "mon"},
	{kind = .Wait, text = " for \"mon\": monitor (window), monitor (program)"},
	{kind = .Shot, text = "palette_windows"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette brings monitor to the front"},
	{kind = .Wait, text = "compositor: window monitor in front"},
	// Escape closes the panel, and no program gets the key.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	// A part that no name has: the list is empty, and Enter runs nothing.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "xyz"},
	{kind = .Wait, text = "compositor: the palette lists 0 of "},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette has no entry to run"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is closed by the key super"},
	// The menu of the programs: the button of the bar opens and closes it.
	{kind = .Click, text = BAR_PROGRAMS_BUTTON},
	{kind = .Shot, text = "menu"},
	{kind = .Click, text = BAR_PROGRAMS_BUTTON},
	// The menu of the windows: a press on a line brings the window to the
	// front.
	{kind = .Click, text = BAR_WINDOWS_BUTTON},
	{kind = .Wait, text = "compositor: windows: "},
	{kind = .Shot, text = "windows"},
	{kind = .Click, text = BAR_WINDOWS_BUTTON},
	{kind = .Front, text = "console"},
	{kind = .Front, text = "plasma"},

	// A program that fails stops alone.
	{kind = .Launch, text = "fault"},
	{kind = .Wait, text = "stopped: page fault"},
	{kind = .Wait, text = "root: fault stopped"},
	// The palette closes a window. The match is fuzzy: "closepla" has the
	// letters of "close plasma" in their order. The entry destroys, so the
	// panel asks for a second Enter; another key goes back to the search
	// and stops nothing.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "closepla"},
	{kind = .Wait, text = " for \"closepla\": close plasma (close a window)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette asks to confirm: close plasma"},
	{kind = .Shot, text = "palette_confirm"},
	{kind = .Key, text = "down"},
	{kind = .Wait, text = "compositor: the palette goes back to the search"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette asks to confirm: close plasma"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette closes the window plasma"},
	{kind = .Wait, text = "root: plasma stopped"},

	// The commands of the console in the palette: the console is the
	// palette provider. A command with no parameter runs from the panel,
	// as a line of the console: memory() gives a Record, which the panel
	// shows.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "memo"},
	{kind = .Wait, text = " for \"memo\": memory (command)"},
	{kind = .Shot, text = "palette_commands"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette sends memory to the console"},
	{kind = .Wait, text = "console: the palette runs memory()"},
	{kind = .Wait, text = "console: the palette gets Record, "},
	{kind = .Wait, text = "compositor: the palette shows a Record"},
	{kind = .Shot, text = "palette_result"},
	// Another key leaves the result; Escape then closes the panel.
	{kind = .Key, text = "down"},
	{kind = .Wait, text = "compositor: the palette goes back to the search"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	// A Table is too large for the panel: the panel closes, and the
	// window of the console comes to the front with the line and its table.
	{kind = .Front, text = "monitor"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "programs"},
	{kind = .Wait, text = " for \"programs\": programs (command)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette sends programs to the console"},
	{kind = .Wait, text = "console: the palette runs programs()"},
	{kind = .Wait, text = "console: the result of the palette choice is in the console: Table"},
	{kind = .Wait, text = "compositor: the result of the palette is in the console"},
	{kind = .Wait, text = "compositor: window console in front"},
	// A command with parameters: Enter turns the input band into its form,
	// one field for each parameter. The console gives the candidates of a
	// field: the modules of the boot image for start. Tab takes the chosen
	// one, and Enter in the last field runs the line that the console
	// builds from the typed values.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "start"},
	{kind = .Wait, text = " for \"start\": start (command)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette asks for the arguments of start"},
	{kind = .Wait, text = " candidates for the parameter 0 of start"},
	{kind = .Wait, text = " candidates for the field 0"},
	{kind = .Keys, text = "plasm"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "compositor: the palette takes the candidate plasma"},
	{kind = .Shot, text = "palette_arguments"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette sends start with 1 arguments to the console"},
	{kind = .Wait, text = "console: the palette runs start(\"plasma\")"},
	{kind = .Wait, text = "compositor: the palette shows no value", any_order = true},
	{kind = .Wait, text = "compositor: surface plasma"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	// Two fields, and a command that destroys: the programs that run for
	// the first field, the grants for the second one. The panel asks for a
	// second Enter after the arguments.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "revoke"},
	{kind = .Wait, text = " for \"revoke\": revoke (command)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette asks for the arguments of revoke"},
	{kind = .Wait, text = " candidates for the parameter 0 of revoke"},
	{kind = .Wait, text = " candidates for the field 0"},
	{kind = .Keys, text = "plasm"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "compositor: the palette takes the candidate plasma"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = " candidates for the parameter 1 of revoke"},
	{kind = .Wait, text = " candidates for the field 1"},
	{kind = .Keys, text = "log"},
	{kind = .Shot, text = "palette_arguments_two"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette asks to confirm: revoke"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette sends revoke with 2 arguments to the console"},
	{kind = .Wait, text = "console: the palette runs revoke(\"plasma\", \"log\")"},
	{kind = .Wait, text = "root: revoked the grant log of plasma"},
	{kind = .Wait, text = "compositor: the palette shows an Integer"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	// A prefix restricts the kinds: ">" lists the commands only.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = ">mem"},
	{kind = .Wait, text = " for \">mem\": memory (command)"},
	{kind = .Shot, text = "palette_prefix"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	// The settings: the palette starts the program settings, then ":"
	// lists one entry for each value of each setting. The font changes
	// behind the open panel, and the value in use has the mark. After the
	// first choice a new list comes for the same typed part (the console
	// has new commands, and the chosen entry is a recent one): the choice
	// stays on its entry at whatever row it has, so one arrow down from
	// "spleen" is "vector" in each order of the two rows, and Enter runs
	// the row that the screen shows.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "settings"},
	{kind = .Wait, text = " for \"settings\": settings (program)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette starts settings"},
	{kind = .Wait, text = "compositor: surface settings", any_order = true},
	{kind = .Wait, text = "settings: ok, "},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = ":font"},
	{kind = .Wait, text = " for \":font\": set font to vector (setting), set font to spleen (setting)"},
	{kind = .Key, text = "down"},
	{kind = .Wait, text = "compositor: the palette chooses set font to spleen (setting)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette sends set font to spleen to the console"},
	{kind = .Wait, text = "console: the palette runs setting(\"font\", \"spleen\")"},
	{kind = .Wait, text = "compositor: the settings changed: font spleen", any_order = true},
	{kind = .Wait, text = "compositor: the palette did: set font to spleen"},
	{kind = .Shot, text = "palette_settings"},
	{kind = .Key, text = "down"},
	{kind = .Wait, text = "compositor: the palette chooses set font to vector (setting)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "console: the palette runs setting(\"font\", \"vector\")"},
	{kind = .Wait, text = "compositor: the settings changed: font vector", any_order = true},
	{kind = .Wait, text = "compositor: the palette did: set font to vector"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	{kind = .Close, text = "settings"},
	{kind = .Wait, text = "root: settings stopped"},
	{kind = .Close, text = "plasma"},
	{kind = .Wait, text = "root: plasma stopped"},
	// A command that destroys asks for a second Enter, on a row that says
	// the act in full. Another key goes back, and nothing stops.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "shutd"},
	{kind = .Wait, text = " for \"shutd\": shutdown (command)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette asks to confirm: shutdown"},
	{kind = .Shot, text = "palette_confirm_command"},
	{kind = .Key, text = "down"},
	{kind = .Wait, text = "compositor: the palette goes back to the search"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	// The grant of the provider ends: the commands leave the list, and the
	// palette keeps the programs and the windows.
	{kind = .Type, text = "revoke(\"console\", \"palette\")"},
	{kind = .Wait, text = "console: the console is no more the palette provider"},
	// The root service and the compositor write in an order that the
	// system does not fix.
	{kind = .Wait, text = "root: revoked the grant palette of console, holdings ended: ", any_order = true},
	{kind = .Wait, text = "compositor: the palette has no provider"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "shutd"},
	{kind = .Wait, text = "compositor: the palette lists 0 of "},
	{kind = .Shot, text = "palette_no_provider"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is closed by the key super"},

	// Back to the console: the system tools, then stop the machine.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "where(programs(), \"name\", \"paint\")"},
	{kind = .Wait, text = "[console] slot  name"},
	{kind = .Wait, text = "paint  "},
	{kind = .Type, text = "memory()"},
	{kind = .Wait, text = "[console]   interrupts"},
	{kind = .Type, text = "stop(\"paint\")"},
	{kind = .Wait, text = "root: paint stopped"},
	// A command is an export of a module: the console loads the module and
	// calls its exports from their descriptions.
	{kind = .Type, text = "gcd(84, 36)"},
	{kind = .Wait, text = "error: no command has the name gcd"},
	{kind = .Type, text = "load(\"math\")"},
	{kind = .Wait, text = "[console]   module     math"},
	{kind = .Type, text = "gcd(84, 36) + power(2, 10)"},
	{kind = .Wait, text = "[console] 1036"},
	// An export that fails gives an error record in a direct call too.
	{kind = .Type, text = "square_root(1000000) + square_root(-4)"},
	{kind = .Wait, text = "[console] error: square_root: the argument value has -4; it must have at least 0 (-1)"},
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
	{kind = .Type, text = "where(help(), \"name\", \"shutdown\")"},
	{kind = .Wait, text = "[console] shutdown  shutdown()  stop the machine"},
	{kind = .Type, text = "where(help(), \"name\", \"number\")"},
	{kind = .Wait, text = "[console] number  number(text: Text) -> Integer"},
	{kind = .Shot, text = "tools"},

	// An isolated call: the module runs in a sandboxed program. The
	// arguments go through a ring. The description is the same.
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "isolate(\"probe\")"},
	{kind = .Wait, text = "[probe] host: ready, 8 exports"},
	{kind = .Wait, text = "[console]   module     probe"},
	{kind = .Wait, text = "[console]   commands   8"},
	{kind = .Wait, text = "[console]   call       isolated"},
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
	{kind = .Wait, text = "[console] error: Escape stopped the call of spin"},
	{kind = .Wait, text = "[console] 13"},
	// No key is lost while the console does not take a line: 100 keys
	// typed during a call that does not return wait, in order, and are the
	// next line. The count of the keys that wait is exact, the echo is the
	// exact line, and no queue of the path of a key wrote that a record is
	// lost (docs/ARCHITECTURE.md, "The path of a key").
	{kind = .Type, text = "spin()"},
	{kind = .Keys, text = KEYS_HELD_LINE},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "console: Escape stops the line after "},
	{kind = .Wait, text = " ms; keys that wait: 100"},
	{kind = .Wait, text = "[console] error: Escape stopped the call of spin"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] > " + KEYS_HELD_LINE, fails_on = "is lost"},
	{kind = .Wait, text = "[console] 976"},
	// The Escape stopped the sandboxed program of probe: a call starts it
	// again, so that the list of the programs has it for the picture.
	{kind = .Type, text = "count()"},
	{kind = .Wait, text = "[probe] host: ready"},
	{kind = .Wait, text = "[console] 1"},
	{kind = .Type, text = "where(programs(), \"name\", \"probe\")"},
	{kind = .Wait, text = "probe  "},
	{kind = .Shot, text = "isolated"},

	// A record and a lent handle in an isolated call. The record goes as
	// bytes with described fields. The module receives a copy of the handle
	// with the rights of the description, for the time of the call.
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "isolate(\"sample\")"},
	{kind = .Wait, text = "[console]   module     sample"},
	{kind = .Wait, text = "[console]   commands   11"},
	{kind = .Wait, text = "[console]   call       isolated"},
	// The exports that are wrong on purpose are in a module of their own,
	// which no service holds.
	{kind = .Type, text = "isolate(\"hostile_exports\")"},
	{kind = .Wait, text = "[console]   module     hostile_exports"},
	{kind = .Wait, text = "[console]   commands   4"},
	{kind = .Wait, text = "[console]   call       isolated"},
	{kind = .Type, text = "r = Rectangle(1, 2, 30, 4)"},
	{kind = .Type, text = "area(r)"},
	{kind = .Wait, text = "[console] 120"},
	{kind = .Type, text = "grow(r, 5)"},
	{kind = .Wait, text = "[console]   height  14"},
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
	{kind = .Wait, text = "[console] error: the program hostile_exports stopped: page fault"},
	// The root service ends one grant of a program that runs. The window of
	// monitor goes below the console for the picture, then back.
	{kind = .Move, text = "monitor", to_x = 568, to_y = 552},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "grants(\"monitor\")"},
	{kind = .Wait, text = "[console] monitor  log      held"},
	{kind = .Wait, text = "[console] monitor  machine  held"},
	{kind = .Type, text = "revoke(\"monitor\", \"machine\")"},
	{kind = .Wait, text = "root: revoked the grant machine of monitor, holdings ended: 1", any_order = true},
	{kind = .Wait, text = "[console] 1", any_order = true},
	{kind = .Wait, text = "monitor: no grant to inspect the machine"},
	{kind = .Type, text = "grants(\"monitor\")"},
	{kind = .Wait, text = "[console] monitor  log      held"},
	{kind = .Wait, text = "[console] monitor  machine  lost"},
	{kind = .Type, text = "revoke(\"monitor\", \"machine\")"},
	{kind = .Wait, text = "[console] error: root.Revoke: the argument grant names none of the grants of the program"},
	{kind = .Type, text = "revoke(\"monitor\", \"keys\")"},
	{kind = .Wait, text = "[console] error: no grant has the name keys"},
	{kind = .Shot, text = "revocation"},
	{kind = .Move, text = "monitor", to_x = 568, to_y = 40},
	{kind = .Front, text = "console"},
	// The same descriptions serve a direct call. The module is then in the
	// console: it has the handles of the console, and kept gives 0.
	{kind = .Type, text = "unload(\"sample\")"},
	{kind = .Wait, text = "[console]   module    sample"},
	{kind = .Wait, text = "[console]   commands  11"},
	{kind = .Wait, text = "[console]   memory    its sandboxed program stopped"},
	{kind = .Type, text = "unload(\"hostile_exports\")"},
	{kind = .Wait, text = "[console]   module    hostile_exports"},
	{kind = .Wait, text = "[console]   commands  4"},
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "load(\"sample\")"},
	{kind = .Wait, text = "[console]   module     sample"},
	{kind = .Wait, text = "[console]   commands   11"},
	{kind = .Wait, text = "[console]   call       direct"},
	{kind = .Type, text = "load(\"hostile_exports\")"},
	{kind = .Wait, text = "[console]   module     hostile_exports"},
	{kind = .Wait, text = "[console]   commands   4"},
	{kind = .Wait, text = "[console]   call       direct"},
	{kind = .Type, text = "g = grow(r, 5)"},
	{kind = .Type, text = "g.width * g.height + keep(b) + kept()"},
	{kind = .Wait, text = "[console] 12848"},
	{kind = .Type, text = "unload(\"sample\")"},
	{kind = .Wait, text = "[console]   module    sample"},
	{kind = .Wait, text = "[console]   commands  11"},
	{kind = .Wait, text = "[console]   memory    left the console"},
	{kind = .Type, text = "unload(\"hostile_exports\")"},
	{kind = .Wait, text = "[console]   module    hostile_exports"},
	{kind = .Wait, text = "[console]   commands  4"},
	{kind = .Wait, text = "[console]   memory    left the console"},
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
	{kind = .Move, text = "rings", to_x = 176, to_y = 32},
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
	{kind = .Move, text = "workers", to_x = 304, to_y = 328},
	{kind = .Shot, text = "workers"},

	// The calls of the host (docs/MODULE_CONTRACT.md, "A call from the
	// host"). Here, after the steps that press at fixed places inside
	// windows that the compositor placed: a new window moves the place of
	// each window that comes after it. This launch is blind; from the next
	// press on, the tool reads the place of the pointer from the compositor
	// and corrects it before each press.
	{kind = .Launch, text = "remote"},
	{kind = .Wait, text = "root: started remote"},
	{kind = .Remote_Key, text = "remote: the public key of this service: "},
	{kind = .Wait, text = "remote: listening on the UDP port 7100, for the host 10.0.2.2 only", any_order = true},
	{kind = .Call, text = "compositor.pointer()", expected = "1 rows of Pointer", pointer = true},
	{kind = .Call, text = "compositor.windows()", expected = "remote"},

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

	// One ring between two threads: 200000 records in order, and the
	// kernel entries that they cost, for two capacities and two ways to wait.
	{kind = .Launch, text = "flow"},
	{kind = .Wait, text = "flow: capacity 32, wait at once: ", any_order = true},
	{kind = .Wait, text = "flow: capacity 1024, read the counters then wait: "},
	{kind = .Wait, text = "flow: ok, 4 rings, 0 records lost"},
	{kind = .Shot, text = "flow"},

	// One queue for several writers and several readers, with no lock; one
	// event starts the threads of each run.
	{kind = .Launch, text = "crowd"},
	{kind = .Wait, text = "crowd: shared queue, 1 writers, 1 readers: ", any_order = true},
	{kind = .Wait, text = "crowd: shared queue, 2 writers, 2 readers: "},
	{kind = .Wait, text = "crowd: shared queue, 3 writers, 1 readers: "},
	{kind = .Wait, text = "crowd: shared queue, 1 writers, 3 readers: "},
	{kind = .Wait, text = "crowd: queue with a lock, 2 writers, 2 readers: "},
	{kind = .Wait, text = "crowd: ok, 5 runs, each record written is read one time, each event started all the threads"},
	{kind = .Shot, text = "crowd"},

	// The time is in a page that each program reads: no kernel entry.
	{kind = .Launch, text = "clock"},
	{kind = .Wait, text = "clock: the check of the time page: 1000000 reads, 0 kernel entries"},
	{kind = .Wait, text = "clock: the check of a kernel entry: 100000 reads, "},
	{kind = .Wait, text = "clock: the time page and the cycle counter: in "},
	{kind = .Wait, text = "clock: ok, the time never went back, the page and the kernel give the same time, the kernel refuses to remove the time page"},
	{kind = .Shot, text = "clock"},

	// Several processors: the kernel says that the four processors ran
	// threads of one program at the same time. Then 1, 2 and 4 threads
	// compute the same picture.
	{kind = .Launch, text = "processors"},
	{kind = .Wait, text = "processors: ok, 4 processors ran the program at the same time"},
	{kind = .Wait, text = "processors: the picture took "},
	{kind = .Shot, text = "processors"},

	// The locks of the kernel: four programs that each work on their own
	// objects, with 1, 2 and 4 at one time; two threads that wake each
	// other. The program checks the counts, not the speed.
	{kind = .Launch, text = "locks"},
	{kind = .Wait, text = "locks: kernel entries, each locker on its own objects: 1 locker 16384, 2 lockers 32768, 4 lockers 65536"},
	{kind = .Wait, text = "locks: pages on first use, each locker in its own memory: 1 locker 2048, 2 lockers 4096, 4 lockers 8192"},
	{kind = .Wait, text = "locks: word wait, two threads wake each other: "},
	{kind = .Wait, text = "locks: frames: "},
	{kind = .Wait, text = "locks: frame caches after the measures (frames now, batches taken, batches given, drains): processor 0: "},
	{kind = .Wait, text = "locks: ok, the kernel counted each entry, each page returned, no wake was lost, each stopped program returned its pages, its slot and its threads"},
	{kind = .Shot, text = "locks"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"locks\")"},
	{kind = .Wait, text = "root: locks stopped"},

	// The scheduling strategies: the same cases under round robin, the
	// fair strategy and EEVDF, then 100 changes of strategy while threads
	// start, stop, wake each other and move. The program checks what does
	// not depend on the load of the host. Two keys change the strategy.
	// The schedule of a live thread: a thread reads and writes its own
	// weight and request, the kernel refuses each write that it must
	// refuse, the weights written through the machine handle order the
	// shares, and writes during the changes of strategy lose no thread. A
	// thread of another program is written through the machine handle, and
	// a weight limit holds against the writes and the new threads of its
	// thread. The placement of a thread on the processors: a thread narrows
	// its own set, the kernel refuses each write that it must refuse, a
	// limit holds against the writes and the new threads of its thread, a
	// thread in each state moves into a new set, two groups of spinners
	// with no common processor stay apart, a queue of threads that a
	// processor cannot take does not stop the balance, and writes during
	// the changes of strategy lose no thread. The machine of the test has
	// 4 processors: the lines name them.
	{kind = .Launch, text = "scheduler"},
	{kind = .Wait, text = "scheduler: a thread created with the weight 300 and the request 700 us read its own schedule: weight 300, request 700 us; after it lowered them to 150 and 350 us: weight 150, request 350 us; its own writes of the weight 300 and of the request 700 us: Bad_Operation and Bad_Operation, and the schedule stayed: 1; the first thread: weight 1024, request 3000 us: as it must"},
	{kind = .Wait, text = "scheduler: refused writes of a schedule: a weight above the full weight Bad_Operation, a request above the limit Bad_Operation, and the schedule stayed: 1; the machine handle with no right Schedule No_Right; a read and a write through the machine handle with Schedule and no Inspect No_Right and No_Right; a thread handle with Inspect and no Control No_Right, and it reads: 1; another command with the machine handle Bad_Handle; the machine number of a thread that ended Bad_State: as it must"},
	{kind = .Wait, text = "scheduler: a thread of another program, the root service, found by its name and its serial: through the machine handle its schedule was read, written, read back and written back: as it must"},
	{kind = .Wait, text = "scheduler: the weight limit 256 written through the machine handle: the thread has the weight 256; its own write of the full weight Bad_Operation, the error record has the weight of the thread: 1; its own write of the full limit changed nothing: 1; 1000 rounds of its own writes of the weights 256, 1, 1024 and 256, then the weight 256 through the machine handle: 2000 of its own accepted, 2000 refused, 1000 raised by the machine handle, a wrong weight or limit 0 times: as it must"},
	{kind = .Wait, text = "scheduler: under the weight limit 256: a new thread with the weight 257 Bad_Operation; a new thread with the weight 0 has the weight 256 and the limit 256, and its own write of the full weight Bad_Operation; after the machine handle wrote the full limit the first thread has the weight 1024: as it must"},
	{kind = .Wait, text = "scheduler: at least 100 rounds on a held spinner under EEVDF, until one had a lag below 0: the spinner lowered to the weight 1 and ran a tick, a Stop, its own writes of the full weight and of the request 1 us, the full weight through the machine handle, a Resume: 0 of its raises were not refused, the reported lag changed after 0 of its writes, and was not 0 after 0 raises of the machine handle: as it must"},
	{kind = .Wait, text = "scheduler: a thread read its own placement: each of the 4 processors in its set and in its limit: 1; its own write of the processor 3 alone: Ok, and it then read that processor alone, with the same limit: 1; in 50 samples of its thread report, each after one more tick of its run, its home or its processor was another one 0 times: as it must"},
	{kind = .Wait, text = "scheduler: refused sets of a placement, on a spinner that the machine handle keeps on the processor 0: through its thread handle a wider set Bad_Operation and a processor that the machine does not have Bad_Operation, with their error records: 1; through the machine handle a limit of no processor of the machine Bad_Operation and a set outside its limit Bad_Operation, with their error records: 1; the placement stayed: 1: as it must"},
	{kind = .Wait, text = "scheduler: the rights of a placement: the machine handle with no right Schedule No_Right; a read and a write through the machine handle with Schedule and no Inspect No_Right and No_Right; a thread handle with Inspect and no Control No_Right, and it reads: 1; the placement stayed: 1; a read and a write by the machine number of a thread that ended Bad_State and Bad_State: as it must"},
	{kind = .Wait, text = "scheduler: the limit of the processors 0 to 1 written through the machine handle: the thread has that set: 1; its own write of each processor Bad_Operation, the error record has the set of the thread: 1; its own write of a wider limit changed nothing: 1: as it must"},
	{kind = .Wait, text = "scheduler: under that limit, 1000 rounds of the own writes of the thread, of the processor 0, of the set of the limit and of each processor, then the limit again through the machine handle: 1000 of its own accepted, 2000 refused, 1000 widened by the machine handle, a wrong set or limit 0 times: as it must"},
	{kind = .Wait, text = "scheduler: under that limit: a new thread has the limit as its set and as its limit: 1, its home is a processor of the limit: 1, and its own write of each processor Bad_Operation; after the machine handle wrote the zero record the first thread has each processor in its set and in its limit: 1: as it must"},
	{kind = .Wait, text = "scheduler: a set without the home of a thread, written through the machine handle: a thread that waits has a home of the set in the next report: 1, and after its wake it ran inside the set: 1, outside in 0 reports; a spinner that a Stop holds has a home of the set in the next report: 1, and after the Resume it ran inside the set: 1, outside in 0 reports: as it must"},
	{kind = .Wait, text = "scheduler: a set without the home of a spinner, written through the machine handle: a spinner in a list ran inside the set: 1, outside in 0 reports after the first one inside; a spinner on a processor ran inside the set: 1, outside in 0 reports after the first one inside: as it must"},
	{kind = .Wait, text = "scheduler: two groups of 3 spinners, each created under the limit of its group, the processors 0 to 1 and 2 to 3: each spinner has that limit as its set and as its limit: 1; each of the 4 processors ran a spinner of its group: 1; in at least 200 reports of the threads a spinner had a home or a processor of the other group 0 times: as it must"},
	{kind = .Wait, text = "scheduler: 5 spinners that only the processor 0 can run make its queue the busiest, and each processor from 2 runs a spinner of its own; two spinners of the queue of the processor 1 got the processors 1 to 3: a report showed the two on two processors at one time: 1: as it must"},
	{kind = .Wait, text = "scheduler: 5 threads of a budget with no processor time, in the queue of the processor 0, make it the busiest, and each processor from 2 runs a spinner of its own; two spinners of the queue of the processor 1 got the processors 1 to 3: a report showed the two on two processors at one time: 1: as it must"},
	{kind = .Wait, text = "scheduler: two spinners and the first thread kept on the processor 0; the spinner of the list got the processor 1 too through the machine handle: a report showed it on the processor 1: 1: as it must"},
	{kind = .Wait, text = "scheduler: writes of a placement through the machine handle while the strategy changed 100 times: none was refused, each of the 8 spinners ran after them and has each processor again: as it must"},
	{kind = .Wait, text = "scheduler: round robin: two threads that wake each other, a spinner on each processor: "},
	{kind = .Wait, text = "scheduler: fair: two threads that wake each other, a spinner on each processor: "},
	{kind = .Wait, text = "scheduler: EEVDF: two threads that wake each other, a spinner on each processor: "},
	{kind = .Wait, text = "scheduler: the weights 1 2 4 written through the machine handle while 12 spinners ran: each write was read back, and the heavier weight got more under fair and EEVDF: as it must"},
	{kind = .Wait, text = "scheduler: one Strategy_Set, with its kernel entry: "},
	{kind = .Wait, text = "scheduler: stress: 100 changes of strategy while "},
	{kind = .Wait, text = "scheduler: writes of a schedule through the machine handle while the strategy changed 100 times: none was refused, each of the 8 spinners ran after them and has the schedule written last: as it must"},
	{kind = .Wait, text = "scheduler: ok, no spinner starved under 3 strategies, a wake ended "},
	{kind = .Wait, text = "scheduler: the window took "},
	{kind = .Shot, text = "scheduler"},
	{kind = .Key, text = "1"},
	{kind = .Wait, text = "scheduler: the strategy is now round robin, it was EEVDF"},
	// The tiles are buttons of the interface package: Tab moves the focus
	// from tile to tile, Enter chooses the third. The scenario writes no
	// more log lines than with the key 3: the ring of the log is full when
	// the program log reads its oldest records.
	{kind = .Key, text = "tab"},
	{kind = .Key, text = "tab"},
	{kind = .Key, text = "tab"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "scheduler: the strategy is now EEVDF, it was round robin"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"scheduler\")"},
	{kind = .Wait, text = "root: scheduler stopped"},

	// A program drives its own virtual memory: an arena and a sparse table
	// of 1 GiB of addresses, commit and decommit, a protection change with
	// its shoot-down, a guard page, large pages, the refusals.
	{kind = .Launch, text = "address_space"},
	{kind = .Wait, text = "address_space: arena: 1 GiB of addresses in one mapping, "},
	{kind = .Wait, text = "address_space: sparse table: 1024 pages committed of 262144, 1024 with a frame; decommit: 1024 pages back in the budget at once"},
	{kind = .Wait, text = "address_space: protection of 64 pages, one call with its shoot-down, the middle of 40 calls"},
	{kind = .Wait, text = "address_space: guard page: the child stopped with vector 14 at "},
	{kind = .Wait, text = "address_space: edge case: a map with a flag that the kernel does not know is refused: right", any_order = true},
	{kind = .Wait, text = "address_space: large pages: one random read over 64 MiB: "},
	// Each page table that a mapping made returns to the budget with its
	// unmap, at three levels, for a reservation, for a large page, and
	// while another thread uses a page of the same table.
	{kind = .Wait, text = "address_space: page tables: 64 mappings of one page, each at its own entry of three levels: 3 to 3 pages of tables while mapped, 0 pages kept after the unmap: as it must"},
	{kind = .Wait, text = "address_space: page tables: a reservation of 1024 pages: 4 pages of tables, the same after a commit and a decommit of 16 pages, 0 pages kept after the unmap: as it must"},
	{kind = .Wait, text = "address_space: page tables: a large page: 2 pages of tables above it while mapped, 0 pages kept after the unmap: as it must"},
	{kind = .Wait, text = "address_space: page tables: 1000 rounds of a map and an unmap beside a page that another thread writes and reads: 1000 rounds right, the page of the other thread stayed right, 0 pages kept: as it must"},
	{kind = .Wait, text = "address_space: ok, the arena and the sparse table paid only what they used, the decommit gave each page back, the protection changed with its shoot-down, the guard page stopped the child, the large pages are in the report, each refusal has its error record"},
	{kind = .Shot, text = "address_space"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"address_space\")"},
	{kind = .Wait, text = "root: address_space stopped"},

	// The boot display in a window: how the machine started, with the
	// records that the kernel has now.
	{kind = .Launch, text = "boot"},
	{kind = .Wait, text = "boot: ok, 7 stages, "},
	{kind = .Shot, text = "boot"},
	// The window covers the screen: move it down, away from the console.
	{kind = .Move, text = "boot", to_x = 64, to_y = 744},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"boot\")"},
	{kind = .Wait, text = "root: boot stopped"},
	{kind = .Type, text = "program_modules()"},
	{kind = .Wait, text = "[console] slot  program"},

	// Paging: the kernel reads its own page tables. No page is both
	// writable and executable, and each kernel stack has its guard pages.
	{kind = .Launch, text = "pages"},
	{kind = .Wait, text = "pages: the kernel half: ", any_order = true},
	{kind = .Wait, text = " 0 write and execute, 24 guard pages of 24"},
	{kind = .Wait, text = "pages: ok, the page tables keep the rules"},
	{kind = .Wait, text = "pages: the processor refuses the memory of programs to the kernel"},
	{kind = .Shot, text = "pages"},
	{kind = .Move, text = "pages", to_x = 168, to_y = 744}, // The window covers the console.
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
	{kind = .Move, text = "paint", to_x = 520, to_y = 408}, // Below the console, at the right.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "connect(\"paint\")"},
	{kind = .Wait, text = "root: connected console to the service paint"},
	{kind = .Wait, text = "[console]   module     paint"},
	{kind = .Wait, text = "[console]   commands   4"},
	{kind = .Wait, text = "[console]   call       service"},
	{kind = .Type, text = "connect(\"life\")"},
	{kind = .Wait, text = "[console]   module     life"},
	{kind = .Wait, text = "[console]   commands   3"},
	{kind = .Wait, text = "[console]   call       service"},
	{kind = .Type, text = "connect(\"plasma\")"},
	{kind = .Wait, text = "error: cannot connect to plasma: root.Connect: the argument name names none of the services that run"},
	// The monitor serves its tables; its grant of the machine was revoked
	// above, so the kernel refuses its reports.
	{kind = .Type, text = "connect(\"monitor\")"},
	{kind = .Wait, text = "[console]   module     monitor"},
	{kind = .Wait, text = "[console]   commands   5"},
	{kind = .Wait, text = "[console]   call       service"},
	{kind = .Type, text = "monitor.count(\"processors\")"},
	{kind = .Wait, text = "[console] error: monitor.count: refused with the status "},
	{kind = .Type, text = "where(help(), \"name\", \"paint.write\")"},
	{kind = .Wait, text = "paint.write(x: Integer, y: Integer, text: Text, color: Integer)"},
	// One line for three calls: each result is a line of the log, and the
	// check of the log below needs each record since the boot.
	{kind = .Type, text = "paint.line(40, 30, 440, 250, 1) + paint.line(40, 250, 440, 30, 3) + paint.write(150, 20, \"drawn by isolated calls\", 0)"},
	{kind = .Wait, text = "[console] 26"}, // 1 and 2 lines, and 23 bytes of text.
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
	{kind = .Move, text = "paint", to_x = 464, to_y = 688}, // The window covers the console: move it down.
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
	{kind = .Wait, text = "tally: ok", any_order = true}, // The compositor can write the line of the surface first.
	{kind = .Wait, text = "compositor: surface tally"},
	{kind = .Move, text = "tally", to_x = 616, to_y = 528}, // Under the console, at the right.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "connect(\"tally\")"},
	{kind = .Wait, text = "[console]   module     tally"},
	{kind = .Wait, text = "[console]   commands   5"},
	{kind = .Wait, text = "[console]   call       service"},
	{kind = .Type, text = "tally.add(5, \"from the console, to the service\")"},
	{kind = .Wait, text = "[console] 5"},
	{kind = .Type, text = "load(\"tally\")"},
	{kind = .Wait, text = "[console]   module     tally"},
	{kind = .Wait, text = "[console]   commands   5"},
	{kind = .Wait, text = "[console]   call       direct"},
	{kind = .Type, text = "add(2, \"in the console\") + add(2, \"in the console\")"},
	{kind = .Wait, text = "[console] 6"},
	{kind = .Type, text = "tally.total()"},
	{kind = .Wait, text = "[console] 5"},
	{kind = .Type, text = "isolate(\"tally\")"},
	{kind = .Wait, text = "error: the module tally is loaded; unload(\"tally\") removes it"},
	{kind = .Type, text = "unload(\"tally\")"},
	{kind = .Wait, text = "[console]   module    tally"},
	{kind = .Wait, text = "[console]   commands  5"},
	{kind = .Wait, text = "[console]   memory    left the console"},
	{kind = .Type, text = "total()"},
	{kind = .Wait, text = "error: no command has the name total"},
	{kind = .Type, text = "isolate(\"tally\")"},
	{kind = .Wait, text = "[console]   module     tally"},
	{kind = .Wait, text = "[console]   commands   5"},
	{kind = .Wait, text = "[console]   call       isolated"},
	{kind = .Type, text = "add(30, \"in a sandboxed program\") + adds()"},
	{kind = .Wait, text = "[console] 31"},
	{kind = .Type, text = "last()"},
	{kind = .Wait, text = "[console] in a sandboxed program"},
	{kind = .Type, text = "tally.last()"},
	{kind = .Wait, text = "[console] from the console, to the service"},
	{kind = .Shot, text = "roles"},
	{kind = .Type, text = "unload(\"tally\")"},
	{kind = .Wait, text = "[console]   module    tally"},
	{kind = .Wait, text = "[console]   commands  5"},
	{kind = .Wait, text = "[console]   memory    its sandboxed program stopped"},
	{kind = .Type, text = "tally.total()"},
	{kind = .Wait, text = "[console] 5"},

	// The manual shows the documentation that each module carries. It is a
	// service: the console asks for a page, and reads a description as text.
	{kind = .Launch, text = "manual"},
	{kind = .Wait, text = "compositor: surface manual", any_order = true},
	// The measures of the information functions: all the modules and all
	// their exports, and one reverse question.
	{kind = .Wait, text = "manual: information: ", any_order = true},
	{kind = .Wait, text = "manual: ok, "},
	// The manual reads the Markdown of the documentation: it checks its own
	// page, whose comments have each mark.
	{kind = .Wait, text = "manual: the Markdown of its page: bold, italics, code, list items and links that open a page; no mark is left and no row passes the window: as it must", fails_on = "manual: the Markdown of its page: FAILED"},
	{kind = .Move, text = "manual", to_x = 208, to_y = 744},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"manual\")"},
	{kind = .Wait, text = "[console]   module     manual"},
	{kind = .Wait, text = "[console]   commands   17"},
	{kind = .Wait, text = "[console]   call       service"},
	{kind = .Type, text = "manual.about(\"math\")"},
	{kind = .Wait, text = "[console] A module of commands: each command is a function"},
	{kind = .Type, text = "manual.signature(\"tally\", 1)"},
	{kind = .Wait, text = "[console] add(amount: Integer, note: Text) -> Integer"},
	{kind = .Type, text = "manual.show(\"nothing\")"},
	{kind = .Wait, text = "[console] -1"},
	{kind = .Type, text = "manual.show(\"tally\")"},
	{kind = .Wait, text = "manual: tally: a program, 5 exports, "},
	{kind = .Move, text = "manual", to_x = 80, to_y = 64},
	{kind = .Shot, text = "manual"},
	// The keys of the manual: the next module of the boot image, then the one before.
	{kind = .Key, text = "down"},
	{kind = .Wait, text = "manual: manual: a program, 17 exports, "},
	{kind = .Key, text = "pgdn"},
	{kind = .Key, text = "up"},
	{kind = .Wait, text = "manual: tally: a program, 5 exports, "},
	{kind = .Move, text = "manual", to_x = 208, to_y = 744},
	{kind = .Front, text = "console"},

	// A module with imports: agenda imports calendar. The loader finds an
	// import only in what the console was granted: lonely imports a module
	// that is not in the boot image.
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "load(\"lonely\")"},
	// An error is a record: the console prints its lines.
	{kind = .Wait, text = "[console] error: cannot load lonely"},
	{kind = .Wait, text = "..., and the load source has no file with its hash"},
	{kind = .Type, text = "load(\"agenda\")"},
	{kind = .Wait, text = "[console]   module     agenda"},
	{kind = .Wait, text = "[console]   commands   3"},
	{kind = .Wait, text = "[console]   call       direct"},
	{kind = .Type, text = "where(loaded(), \"imported_by\", \"agenda\")"},
	{kind = .Wait, text = "[console] calendar  direct  agenda"},
	// calendar has a fault: 2000 has 365 days, and February 28.
	{kind = .Type, text = "year_days(2000) + month_days(2, 2000)"},
	{kind = .Wait, text = "[console] 393"},
	// Each module one time: calendar is in the console as the import of agenda.
	{kind = .Type, text = "load(\"calendar\")"},
	{kind = .Wait, text = "[console]   module     calendar"},
	{kind = .Wait, text = "[console]   commands   1"},
	{kind = .Wait, text = "[console]   call       direct"},
	{kind = .Type, text = "unload(\"calendar\")"},
	{kind = .Wait, text = "[console]   module    calendar"},
	{kind = .Wait, text = "[console]   commands  1"},
	{kind = .Wait, text = "[console]   memory    stays: another module imports it"},
	{kind = .Type, text = "unload(\"agenda\")"},
	{kind = .Wait, text = "[console]   module    agenda"},
	{kind = .Wait, text = "[console]   commands  3"},
	{kind = .Wait, text = "[console]   memory    left the console"},
	// The replacement of an import. The root service holds the table of the
	// machine; the loader checks each export that agenda uses.
	{kind = .Type, text = "replace(\"calendar\", \"calendar_changed\")"},
	{kind = .Wait, text = "root: calendar_changed replaces calendar in each load that follows"},
	{kind = .Type, text = "load(\"agenda\")"},
	{kind = .Wait, text = "[console] error: cannot load agenda"},
	{kind = .Wait, text = "[console] error: agenda imports calendar, and its replacement calendar_changed fails the check"},
	{kind = .Wait, text = "[console] error: export days_in_month of calendar_changed: 3 parameters, calendar has 2"},
	// A replacement that makes an import cycle.
	{kind = .Type, text = "replace(\"calendar\", \"agenda\")"},
	{kind = .Wait, text = "root: agenda replaces calendar in each load that follows"},
	{kind = .Type, text = "load(\"agenda\")"},
	{kind = .Wait, text = "[console] error: cannot load agenda"},
	{kind = .Wait, text = "[console] error: an import cycle: agenda imports calendar, and agenda still loads its imports"},
	{kind = .Wait, text = "[console] error: the replacement table gives agenda in place of calendar: that makes the cycle"},
	{kind = .Type, text = "replace(\"calendar\", \"calendar_fixed\")"},
	{kind = .Wait, text = "root: calendar_fixed replaces calendar in each load that follows"},
	{kind = .Type, text = "replace(\"calendar_fixed\", \"math\")"},
	{kind = .Wait, text = "[console] error: a chain of replacements is refused: calendar_fixed, math"},
	{kind = .Type, text = "replacements()"},
	{kind = .Wait, text = "calendar  calendar_fixed  "},
	{kind = .Type, text = "load(\"agenda\")"},
	{kind = .Wait, text = "[console]   module     agenda"},
	{kind = .Wait, text = "[console]   commands   3"},
	{kind = .Wait, text = "[console]   call       direct"},
	{kind = .Type, text = "where(loaded(), \"in_place_of\", \"calendar\")"},
	{kind = .Wait, text = "calendar_fixed  direct  agenda       calendar  "},
	{kind = .Type, text = "year_days(2000) + month_days(2, 2000)"},
	{kind = .Wait, text = "[console] 395"},
	{kind = .Type, text = "manual.show(\"agenda\")"},
	{kind = .Wait, text = "manual: agenda: a program, 3 exports, "},
	// A program that imports calendar: the root service gives it the
	// replacements of the machine when it starts it.
	{kind = .Launch, text = "imports"},
	{kind = .Wait, text = "compositor: surface imports", any_order = true},
	{kind = .Wait, text = "imports: ok, 12 cases"},
	{kind = .Wait, text = "imports: a call through an import slot: "},
	{kind = .Wait, text = "imports: the bind of agenda: "},
	{kind = .Wait, text = "imports: two programs import calendar at two places: one copy of its code, "},
	{kind = .Move, text = "imports", to_x = 136, to_y = 304},
	{kind = .Shot, text = "imports"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "where(program_modules(), \"replaces\", \"calendar\")"},
	{kind = .Wait, text = "calendar_fixed  calendar  "},
	// A fault in the module of the replacement: the kernel names
	// calendar_fixed, not calendar.
	{kind = .Type, text = "unload(\"agenda\")"},
	{kind = .Type, text = "isolate(\"agenda\")"},
	{kind = .Wait, text = "[console]   module     agenda"},
	{kind = .Wait, text = "[console]   commands   3"},
	{kind = .Wait, text = "[console]   call       isolated"},
	{kind = .Type, text = "where(loaded(), \"imported_by\", \"agenda\")"},
	{kind = .Wait, text = "[console] calendar_fixed  isolated  agenda"},
	{kind = .Type, text = "year_days(2000)"},
	{kind = .Wait, text = "[console] 366"},
	{kind = .Type, text = "month_days(13, 2000)"},
	{kind = .Wait, text = "kernel: program agenda stopped: invalid instruction"},
	{kind = .Wait, text = ", which replaces "},
	{kind = .Wait, text = "[console] error: the program agenda stopped: invalid instruction"},
	// The debug image names the procedure of the instruction, in the module
	// that ran: calendar_fixed, not calendar.
	{kind = .Wait, text = "[console] error: the instruction is at "},
	{kind = .Wait, text = " in calendar_fixed"},
	{kind = .Wait, text = "... runs in place of calendar "},
	{kind = .Type, text = "replacements()"},
	{kind = .Wait, text = "calendar  calendar_fixed  "},
	{kind = .Shot, text = "replacement"},
	// The information of the modules: the manual serves tables of records
	// that it reads in the flat tables of the modules, and in the module
	// records of the kernel. The console combines them with generic
	// commands that read the description of the records.
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "columns(manual.importers(\"calendar_fixed\"), \"module name replacement slots\")"},
	{kind = .Wait, text = "[console] agenda "},
	{kind = .Wait, text = "[console] imports "},
	{kind = .Wait, text = "[console] 2 rows of Import"},
	{kind = .Type, text = "columns(where(manual.running(), \"module\", \"calendar_fixed\"), \"program slot module replaces\")"},
	{kind = .Wait, text = "[console] imports "},
	{kind = .Wait, text = " of Running"},
	// The graph of the modules as it runs: in the program imports, the
	// module imports imports calendar_fixed, which a replacement put in
	// place of calendar. The first column is the importer.
	{kind = .Type, text = "columns(where(manual.edges(), \"replaces\", \"calendar\"), \"imported_by module replaces program\")"},
	{kind = .Wait, text = "[console] imports      calendar_fixed  calendar  imports"},
	{kind = .Wait, text = " of Edge"},
	{kind = .Type, text = "sort(columns(manual.handles(\"Write\"), \"module name rights\"), \"name\")"},
	{kind = .Wait, text = "[console] sample "},
	{kind = .Wait, text = " of Export"},
	{kind = .Type, text = "join(columns(manual.running(), \"program hash\"), columns(manual.modules(), \"hash name code exports\"), \"hash\")"},
	{kind = .Wait, text = " rows of Running_Module"},
	{kind = .Type, text = "rows(manual.exports(\"\")) - rows(manual.exporters(\"show\"))"},
	{kind = .Wait, text = "[console] "},
	{kind = .Type, text = "manual.exports(\"nothing\")"},
	{kind = .Wait, text = "[console] error: manual.exports: the argument name names none of the modules (-1)"},
	{kind = .Type, text = "where(manual.modules(), \"code\", \"large\")"},
	{kind = .Wait, text = "[console] error: where: the field code is Integer, the value is Text"},
	{kind = .Type, text = "manual.overview()"},
	{kind = .Wait, text = "manual: overview: "},
	{kind = .Front, text = "manual"},
	{kind = .Move, text = "manual", to_x = 80, to_y = 64},
	{kind = .Shot, text = "modules"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "manual.show(\"calendar_fixed\")"},
	{kind = .Wait, text = "manual: calendar_fixed: no entry, "},
	{kind = .Front, text = "manual"},
	{kind = .Shot, text = "module_information"},
	{kind = .Move, text = "manual", to_x = 208, to_y = 744},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "unload(\"agenda\")"},
	{kind = .Wait, text = "[console]   module    agenda"},
	{kind = .Wait, text = "[console]   commands  3"},
	{kind = .Wait, text = "[console]   memory    its sandboxed program stopped"},
	{kind = .Type, text = "stop(\"imports\")"},
	{kind = .Wait, text = "root: imports stopped"},
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
	{kind = .Move, text = "log", to_x = 96, to_y = 744},
	// The log records as a table with typed fields, through the remote
	// service: from here on some checks read the program, the channel and
	// the level of a record (step Record), not only a line of text.
	{kind = .Call, text = "log.records(0)", expected = " rows of Record"},
	// Each record keeps the kind of each value of its text: the kernel
	// writes its free memory as a size ("kernel: free memory 2013 MiB"), so
	// the first records have a run of the kind size.
	{kind = .Call, text = "log.value_runs(0)", expected = "  size"},
	{kind = .Front, text = "console"},
	// The refusals of the console come after the check of the log, which
	// needs each record since the boot (" 0 lost"): the lines before it stay
	// few.
	// The refusals of the root service give an error record: the console
	// writes its sentence.
	{kind = .Type, text = "start(\"nothing\")"},
	{kind = .Wait, text = "[console] error: root.Start: the argument name names none of the modules"},
	{kind = .Type, text = "stop(\"compositor\")"},
	{kind = .Wait, text = "[console] error: root.Stop: the argument name names a program of the system: it starts at boot, or it is a device service, and the call does not act on it"},
	{kind = .Type, text = "revoke(\"nobody\", \"log\")"},
	{kind = .Wait, text = "[console] error: root.Revoke: the argument name names none of the programs"},
	// A text is never cut in silence. The ring of the root service holds a
	// name of 31 bytes: the console refuses a longer one, which a cut could
	// make the name of another program.
	{kind = .Type, text = "start(\"a_name_longer_than_the_ring_holds_today\")"},
	{kind = .Wait, text = "[console] error: root.Start: the argument name has 39 bytes; it can have at most 31 bytes"},
	// A log text of 1500 bytes: the module in its call host logs it in
	// lines of 512 bytes, and its end is on the log. After the check of the
	// log: these lines take 9 records of the ring.
	{kind = .Type, text = "log_long(1500)"},
	{kind = .Wait, text = "01234 the end of the long text"},
	{kind = .Wait, text = "[console] 1500"},
	// An export that refuses: the console writes the sentence of its error
	// record from the description of the export.
	{kind = .Type, text = "load(\"tally\")"},
	{kind = .Wait, text = "[console]   module     tally"},
	{kind = .Wait, text = "[console]   commands   5"},
	{kind = .Wait, text = "[console]   call       direct"},
	{kind = .Type, text = "add(1, \"a note of forty bytes, four more than 36\")"},
	{kind = .Wait, text = "the argument note has 40 bytes; it can have at most 36 bytes"},
	{kind = .Type, text = "add(-6, \"below zero\")"},
	{kind = .Wait, text = "the argument amount has -6; it must have at least 0"},
	{kind = .Type, text = "unload(\"tally\")"},
	{kind = .Wait, text = "[console]   module    tally"},
	{kind = .Wait, text = "[console]   commands  5"},
	{kind = .Wait, text = "[console]   memory    left the console"},
	{kind = .Launch, text = "paint"},
	{kind = .Wait, text = "compositor: surface paint"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "paint.line(0, 0, 10, 10, 9)"},
	{kind = .Wait, text = "error: paint.line: the argument color has the value 9, which the call refuses; it takes at most 5"},
	// A text below the last row of the paper, and a glider at a negative
	// column: each is refused with its record, and draws nothing.
	{kind = .Type, text = "paint.write(0, 296, \"below the paper\", 0)"},
	{kind = .Wait, text = "error: paint.write: the argument y has the value 296, which the call refuses; it takes at most 295"},
	{kind = .Type, text = "life.glider(-1, 10)"},
	{kind = .Wait, text = "error: life.glider: the argument column has -1; it must have at least 0"},
	{kind = .Type, text = "stop(\"paint\")"},
	{kind = .Wait, text = "root: paint stopped"},
	// (After the check of the log: these lines do not push the boot
	// records out of the log.)
	{kind = .Type, text = "load(\"sample\")"},
	{kind = .Wait, text = "[console]   module     sample"},
	{kind = .Wait, text = "[console]   commands   11"},
	{kind = .Wait, text = "[console]   call       direct"},
	// A table goes into a direct call: the export reads and changes the
	// memory of the variable, with no copy. A table from where() goes in;
	// a table from columns() has another record, and the console refuses it.
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "t = readings(4)"},
	{kind = .Type, text = "sum_values(t)"},
	{kind = .Wait, text = "[console] 100"},
	{kind = .Type, text = "scale_values(t, 7)"},
	{kind = .Type, text = "t"},
	{kind = .Wait, text = "4 rows of Reading"},
	{kind = .Type, text = "sum_values(where(t, \"sensor\", 2))"},
	{kind = .Wait, text = "[console] 210"},
	{kind = .Type, text = "sum_values(columns(t, \"sensor value\"))"},
	{kind = .Wait, text = "[console] error: sum_values: argument 1 is Table(Reading, Read), not Table(Reading)"},
	{kind = .Shot, text = "table_argument"},
	{kind = .Type, text = "unload(\"sample\")"},
	{kind = .Wait, text = "[console]   module    sample"},
	{kind = .Wait, text = "[console]   commands  11"},
	{kind = .Wait, text = "[console]   memory    left the console"},
	// A table goes into an isolated call: the rows go into the call
	// region, and the rows of a Change table come back.
	{kind = .Type, text = "isolate(\"sample\")"},
	{kind = .Wait, text = "[console]   module     sample"},
	{kind = .Wait, text = "[console]   commands   11"},
	{kind = .Wait, text = "[console]   call       isolated"},
	{kind = .Type, text = "t = readings(4)"},
	{kind = .Type, text = "scale_values(t, 3)"},
	{kind = .Type, text = "sum_values(t)"},
	{kind = .Wait, text = "[console] 300"},
	// An export that fails after it changed rows of a Change table: only
	// its error record and its table of error details come back, so the
	// variable keeps its rows. scale_values_up_to changes the readings 1
	// and 2 (30 and 60, by 3, stay under 200), then refuses the reading 3
	// (90 by 3 is 270): with the changes, the sum would be 480.
	{kind = .Type, text = "scale_values_up_to(t, 3, 200)"},
	{kind = .Wait, text = "[console] error: scale_values_up_to: the argument factor has the value 3, which the call refuses; it takes at most 2 (-1)"},
	{kind = .Type, text = "sum_values(t)"},
	{kind = .Wait, text = "[console] 300"},
	{kind = .Type, text = "unload(\"sample\")"},
	{kind = .Wait, text = "[console]   module    sample"},
	{kind = .Wait, text = "[console]   commands  11"},
	{kind = .Wait, text = "[console]   memory    its sandboxed program stopped"},
	// The signature of an export with a table and bytes: one form in the
	// manual, the console and the errors.
	{kind = .Type, text = "start(\"manual\")"},
	{kind = .Wait, text = "root: started manual"},
	{kind = .Wait, text = "manual: ok, "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "manual.signature(\"sample\", 11)"},
	{kind = .Wait, text = "[console] sum_words(words: Table(Word, Change), text: Bytes(Read)) -> Integer"},
	{kind = .Type, text = "manual.show(\"sample\")"},
	{kind = .Wait, text = "manual: sample: a program, "},
	{kind = .Front, text = "manual"},
	{kind = .Key, text = "pgdn"},
	{kind = .Key, text = "pgdn"},
	{kind = .Shot, text = "manual_tables"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"manual\")"},
	{kind = .Wait, text = "root: manual stopped"},
	{kind = .Type, text = "clear()"},
	// The terminal: a program gives text as records with a style, in a ring
	// of 4096 records. The terminal reads them in one thread and draws in
	// another: the display does not slow the program.
	// The root service starts the program and its terminal: the terminal
	// starts no program, and has nothing of the role of the program.
	{kind = .Launch, text = "flood"},
	{kind = .Wait, text = "flood: ok", any_order = true},
	{kind = .Wait, text = "terminal: ok, flood writes in a ring of 4096 records", any_order = true},
	{kind = .Wait, text = "root: started flood, with a terminal"},
	{kind = .Move, text = "flood", to_x = 160, to_y = 104}, // The place of the pictures and of the clicks below.
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
	{kind = .Wait, text = "flood: Space: no more lines after "},
	{kind = .Shot, text = "terminal_keys"},
	{kind = .Key, text = "spc"},
	{kind = .Wait, text = "flood: Space: the lines continue"},
	// The program stops: its terminal stays, with what the program wrote.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"flood\")"},
	{kind = .Wait, text = "terminal: flood stopped with code 0 after "},
	{kind = .Click, x = 940, y = 400}, // A part of the window that the console does not cover.
	{kind = .Shot, text = "terminal_stopped"},
	// The scenario closes the window: the terminal stops.
	{kind = .Close, text = "flood"},
	{kind = .Wait, text = "root: terminal stopped"},
	// The block service: the root service gives one virtio disk to one
	// block service, and the block ring to its client. The device reads and
	// writes the memory of the client.
	{kind = .Launch, text = "disk"},
	{kind = .Record, program = "root", channel = "devices", level = "info", text = "root: started block for the device at the place 17 of the bus"},
	{kind = .Record, program = "block", level = "info", text = "block: ok, 8192 blocks of 4096 bytes, a queue of ", any_order = true},
	{kind = .Wait, text = "disk: ok, the disk has 8192 blocks"},
	{kind = .Wait, text = "disk: read, 1 block in each request, 1 in flight: "},
	{kind = .Wait, text = "disk: read, 1 block in each request, 32 in flight: "},
	{kind = .Wait, text = "disk: write, 1 block in each request, 1 in flight: "},
	{kind = .Wait, text = "disk: write, 1 block in each request, 32 in flight: "},
	{kind = .Wait, text = "disk: read, 16 blocks in each request, 8 in flight: "},
	{kind = .Record, program = "disk", level = "info", text = "disk: ok, 5 runs, 0 errors, write then read back: 0 wrong"},
	{kind = .Wait, text = "disk: a read of 2 blocks from the last block: block.Read: the argument first reaches 8193 blocks, past the end: there are 8192 blocks"},
	{kind = .Shot, text = "disk"},
	// The client stops: its block service stops, and the device stops
	// using memory.
	{kind = .Close, text = "disk"},
	{kind = .Record, program = "root", channel = "programs", level = "info", text = "root: disk stopped with code 0"},
	{kind = .Record, program = "root", channel = "programs", level = "info", text = "root: block stopped with code 0"},
	// The storage service runs since the boot (the boot pass of settings
	// needs it), with the block service of the data disk. The console has a
	// private store of 3 blocks, by its name; it acts for the principal, so it
	// also sees all the stores.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"storage\")"},
	{kind = .Record, program = "root", channel = "calls", level = "info", text = "root: connected console to the service storage"},
	{kind = .Type, text = "storage.write(0, \"greeting\", \"kept on the disk\")"},
	// The generation of this commit is the base: the console committed its
	// line history after each line before this one.
	{kind = .Wait, text = "> storage.write(0, \"greeting\", \"kept on the disk\")"},
	{kind = .Generation, text = "[console] "},
	{kind = .Type, text = "storage.read(0, \"greeting\")"},
	{kind = .Wait, text = "[console] kept on the disk"},
	// The limit of the store: one more object needs one more block: its one
	// block of data.
	{kind = .Type, text = "storage.write(0, \"second\", \"one block more\")"},
	{kind = .Wait, text = "[console] error: storage.write: the call needs 4 blocks in all, with no earlier version kept; the limit is 3 blocks (-2)"},
	// A change of the object at the limit: the version of its state before
	// does not fit, and the same commit thins it.
	// Each line commits the line history after it: the base and 1 after
	// the line of the base, 2 after the read, 3 after the refused write;
	// this write is the commit 4.
	{kind = .Type, text = "storage.write(0, \"greeting\", \"changed at the limit\")"},
	{kind = .Wait, text = "[console] {generation+4}"},
	{kind = .Record, program = "storage", level = "info", text = "storage: the store console is at its limit of 3 blocks: the commit of generation {generation+4} thinned 1 version, the oldest of the store first", any_order = true},
	// An error of a service is a record: the console writes it as a sentence.
	{kind = .Type, text = "storage.write(0, \"\", \"x\")"},
	{kind = .Wait, text = "[console] error: storage.write: the argument name is empty; it must have 1 to 64 bytes (-3)"},
	{kind = .Type, text = "storage.read(0, \"nothing\")"},
	{kind = .Wait, text = "[console] error: storage.read: the argument name: the store has no object with this name (-7)"},
	{kind = .Type, text = "storage.size(0, \"greeting\")"},
	{kind = .Wait, text = "[console] 20"},
	{kind = .Type, text = "storage.stores()"},
	{kind = .Wait, text = "[console] console: 1 objects, 0 trees, 0 versions, 3 of 3 blocks, 0 shared, 1 connection"},
	// The scenario lists the grant and revokes it: the store stays on the disk,
	// and the console cannot reach it.
	{kind = .Type, text = "grants(\"console\")"},
	{kind = .Wait, text = "[console] console  log                 held"},
	{kind = .Wait, text = "[console] console  machine             held"},
	{kind = .Wait, text = "[console] console  image               held"},
	{kind = .Wait, text = "[console] console  store               held"},
	{kind = .Wait, text = "[console] console  acts_for_principal  held"},
	{kind = .Type, text = "revoke(\"console\", \"store\")"},
	{kind = .Record, program = "root", channel = "programs", level = "info", text = "root: revoked the grant store of console, connections changed: 1"},
	{kind = .Type, text = "storage.write(0, \"greeting\", \"changed\")"},
	{kind = .Wait, text = "[console] error: storage.write: the caller has no grant for this: a private store (-1)"},
	{kind = .Type, text = "storage.stores()"},
	{kind = .Wait, text = "[console] console: 1 objects, 0 trees, 0 versions, 3 of 3 blocks, 0 shared, 0 connections"},
	{kind = .Type, text = "where(grants(\"console\"), \"state\", \"lost\")"},
	// The grant palette was revoked before: the column has its width.
	{kind = .Wait, text = "[console] console  store    lost"},
	{kind = .Shot, text = "storage"},
	// Versions: notes commits each key, and the storage service
	// keeps the state before each commit. The scenario steps back through the
	// versions of the note and restores one; nothing is lost.
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "notes: a new store: no note, the count 0", any_order = true},
	{kind = .Wait, text = "compositor: surface notes"},
	{kind = .Type, text = "versions"},
	// The 13 lines of the console from the base each committed the history
	// (the base and 14 at the last one); the 8 keys of the note are the
	// commits 15 to 22.
	{kind = .Wait, text = "notes: the note is \"versions\", generation {generation+22}, 7 versions; one commit of the note: "},
	{kind = .Key, text = "up"},
	{kind = .Wait, text = "notes: the version 7 of 8, generation {generation+21}, 20"}, // A version has the date of its commit.
	{kind = .Wait, text = ": \"version\""},
	{kind = .Key, text = "up"},
	{kind = .Wait, text = "notes: the version 6 of 8, generation {generation+20}, "},
	{kind = .Wait, text = ": \"versio\""},
	{kind = .Shot, text = "notes_versions"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "notes: restored the version of generation {generation+20}: \"versio\", in the commit of generation {generation+23} in "},
	// The exports of the versions, from the host: the remote service acts
	// for the principal, so it names the store of notes.
	// A place on the store of notes: the first place of the service, 1.
	{kind = .Call, text = "storage.open_store(\"notes\")", expected = "1"},
	{kind = .Call, text = "storage.versions(1, \"note\")", expected = "9 rows of Version"},
	// The date of the machine, from the host, some minutes after its start:
	// it advanced with the host.
	{kind = .Call, text = "date.now()", expected = "Date{milliseconds = ", date_after = "milliseconds = "},
	{kind = .Call, text = "storage.version(1, \"note\", {generation+18})", expected = "vers"},
	{kind = .Call, text = "storage.compare(1, \"note\", {generation+17}, {generation+22})", expected = "1 rows of Byte_Range"},
	// The generation 1 is the format of the disk: no object has it.
	{kind = .Call, text = "storage.version(1, \"note\", 1)", outcome = .Failed, expected = "error: storage.version: the argument generation: the object has no version of the generation 1 (-9)"},
	{kind = .Call, text = "storage.restore(1, \"note\", {generation+22})", expected = "{generation+24}"},
	{kind = .Call, text = "storage.clone(1, \"note\", \"copy\")", expected = "{generation+25}"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "storage.stores()"},
	// The answer of stores() has one line for each store: with the store
	// of the line history, more than 256 bytes. The console prints a
	// result whole, at any length.
	{kind = .Wait, text = "[console] console.history: 1 objects, ", any_order = true},
	{kind = .Wait, text = "[console] notes: 2 objects, 0 trees, 9 versions, "},
	{kind = .Shot, text = "storage_versions"},
	// A result of 324 bytes on one line: before, the console cut it at 256
	// bytes in the terminal and at 192 bytes in the log, with no sign.
	{kind = .Type, text = "repeat(\"0123456789\", 30) + \"the end of a long result\""},
	{kind = .Wait, text = "01234567890123456789the end of a long result"},
	{kind = .Type, text = "stop(\"notes\")"},
	{kind = .Wait, text = "root: notes stopped"},
	// Errors that diagnose: each case makes an error for real, and the
	// window shows the sentence of its error record. The program fault
	// stops three calls deep: the tool names the functions of its stack
	// trace from the linked file of the module.
	{kind = .Launch, text = "errors"},
	// The window opens while the cases run: its line can come before or
	// after any case.
	{kind = .Wait, text = "compositor: surface errors", any_order = true},
	{kind = .Trace, text = "errors: stack of fault: ", names = "fault::three fault::two fault::one entry"},
	// The program errors names each frame from the debug image: the
	// procedure, the module and the source file. No step names a line
	// number: a line added to the source of fault moves it. The tool checks
	// the lines of fault::three against the source (trace.odin).
	{kind = .Wait, text = " in fault (programs/fault/main.odin:"},
	{kind = .Wait, text = "), fault::two + 0x"},
	{kind = .Wait, text = " in fault (programs/fault/main.odin:"},
	{kind = .Wait, text = "), fault::one + 0x"},
	{kind = .Wait, text = "errors: t the pages of another program (Inspect, Pages): Inspect: the argument index has the value 1, which the call refuses"},
	{kind = .Wait, text = "errors: u the pages past the end of the user half: Inspect: the argument address has the value 140737488351232, which the call refuses; it takes at most 140737488093184"},
	{kind = .Wait, text = "errors: v a wrapper: display.open of 0 by 100 pixels: display.open: the argument width has the value 0, which the call refuses; it takes at most 2048"},
	{kind = .Wait, text = "errors: w a wrapper: terminal.open with no terminal: terminal.open: the caller has no grant for this: a terminal"},
	{kind = .Wait, text = "errors: x a ring: root.Connect(\"storage\"), not callable: root.Connect: the caller has no grant for this: a connection to this service"},
	{kind = .Wait, text = "errors: y an export: tally.add, a note of 40 bytes: tally.add: the argument note has 40 bytes; it can have at most 36 bytes"},
	{kind = .Wait, text = "errors: ok, 25 cases, each with the expected error record"},
	{kind = .Wait, text = "errors: under contention: "},
	// A text longer than one row of log.records (one log record, 152
	// bytes): its end is in the next row, and the tool joins the rows.
	{kind = .Record, program = "errors", level = "info", text = " records name no cause (Refused)", any_order = true},
	{kind = .Wait, text = " handles; 0 records contradict their status, "},
	{kind = .Wait, text = "errors: a failed call of each family: a wrapper of support (terminal.open with no terminal): ", any_order = true},
	{kind = .Wait, text = " refused Memory_Create: "},
	{kind = .Wait, text = "errors: a kernel operation that succeeds: "},
	{kind = .Front, text = "errors"},
	{kind = .Key, text = "b"},
	{kind = .Wait, text = "errors: case b again: Memory_Size: the argument memory, handle "},
	{kind = .Wait, text = " was revoked"},
	{kind = .Shot, text = "errors"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "errors: the window shows the page 2 of the cases"},
	{kind = .Shot, text = "errors_families"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "errors: the window shows the page 1 of the cases"},
	// A developer tool (docs/TOOLS.md): the memory and the execution of one
	// program, from the reports of the kernel. errors still holds the
	// program fault that stopped: its stop report stays.
	// The machine grant of monitor was revoked above: a new monitor has it
	// again, so that the test compares two tools on two reports.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"monitor\")"},
	{kind = .Record, program = "root", channel = "programs", level = "info", text = "root: monitor stopped with code"},
	{kind = .Type, text = "start(\"monitor\")"},
	{kind = .Record, program = "monitor", level = "info", text = "monitor: ok"},
	{kind = .Launch, text = "inspect"},
	{kind = .Wait, text = "inspect: ok, "},
	{kind = .Type, text = "threads"},
	{kind = .Wait, text = "inspect: threads: "},
	{kind = .Wait, text = "inspect: one sample of threads took "},
	{kind = .Agree, text = "threads"},
	{kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"},
	{kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"},
	{kind = .Type, text = "console"},
	{kind = .Wait, text = "inspect: console: "},
	{kind = .Agree, text = "console"},
	// The whole list again, with console chosen.
	{kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"},
	{kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"},
	{kind = .Wait, text = "inspect: the list shows all "},
	{kind = .Shot, text = "inspect"},
	{kind = .Key, text = "spc"},
	{kind = .Wait, text = "inspect: the sample is frozen"},
	{kind = .Key, text = "spc"},
	{kind = .Wait, text = "inspect: the sample is live"},
	// A click on the list: "rk" keeps workers and network; the click on the
	// second line chooses network.
	{kind = .Type, text = "rk"},
	{kind = .Wait, text = "inspect: workers: "},
	{kind = .Click, inside_window = "inspect", x = 48, y = 96}, // The second line of the list: programs/inspect, LIST_ROWS_Y + 16 + 8.
	{kind = .Wait, text = "inspect: network: "},
	{kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"},
	{kind = .Type, text = "fault"},
	{kind = .Wait, text = "inspect: fault stopped: page fault at 0x0; stack: fault::three + 0x"},
	{kind = .Wait, text = " in fault (programs/fault/main.odin:"},
	{kind = .Wait, text = "), fault::two + 0x"},
	{kind = .Shot, text = "inspect_stopped"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "inspect: the bytes of the memory of inspect"},
	{kind = .Shot, text = "inspect_hex"},
	{kind = .Key, text = "tab"},
	// The same facts as tables, from the host.
	{kind = .Call, text = "inspect.mappings(\"console\")", expected = " rows of Mapping"},
	{kind = .Call, text = "inspect.threads(\"threads\")", expected = " rows of Thread"},
	{kind = .Call, text = "inspect.modules(\"console\")", expected = "console "},
	{kind = .Call, text = "inspect.mappings(\"nothing\")", outcome = .Failed, expected = "error: inspect.mappings: the argument program names none of the programs (-2)"},
	// A table from the host: rows of field values go into the call region
	// of the monitor. A Change table is refused by the tool: its rows would
	// not come back. The service sample is not reachable from the network
	// (callable_of("remote")).
	{kind = .Call, text = "monitor.counts_named([(\"programs\"), (\"processors\")])", expected = "2 rows of Count"},
	{kind = .Call, text = "monitor.counts_named([(\"programs\"), (\"nothing\")])", outcome = .Failed, expected = "names nothing that exists"},
	// The table of error details: each row that names nothing, not only the first.
	{kind = .Call, text = "monitor.counts_named([(\"nothing\"), (\"programs\"), (\"none\")])", outcome = .Failed, expected = "detail 2 of 2: monitor.counts_named: row 3 of the argument names"},
	{kind = .Call, text = "sample.scale_values([(0, 0, 10, 10, 10)], 2)", outcome = .Wrong, expected = "error: the parameter readings of sample.scale_values is Table(Reading, Change): a call from the host gives tables to read only"},
	{kind = .Call, text = "sample.sum_values([(0, 0, 10, 10, 10)])", outcome = .Refused, expected = "no grant"},
	{kind = .Close, text = "inspect"},
	{kind = .Close, text = "errors"},
	{kind = .Record, program = "root", channel = "programs", level = "info", text = "root: errors stopped with code 0"},
	// The interface package: each element live, the draw table of the last
	// frame, the damage by difference. The keyboard is a first path: Tab
	// moves the focus, Enter presses, the arrows move the choice.
	{kind = .Launch, text = "interface_elements"},
	{kind = .Wait, text = "compositor: surface interface_elements", any_order = true},
	{kind = .Wait, text = "interface_elements: nothing changed: "},
	{kind = .Wait, text = "interface_elements: one number changed: "},
	{kind = .Wait, text = "interface_elements: everything moved: "},
	{kind = .Wait, text = "interface_elements: one whole frame, built and drawn (the least of 20): the font of the cells "},
	{kind = .Wait, text = "interface_elements: ok, the whole frame drawn in "},
	{kind = .Key, text = "tab"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "interface_elements: the button was pressed 1 times"},
	{kind = .Key, text = "tab"},
	{kind = .Key, text = "down"},
	{kind = .Wait, text = "interface_elements: the list chooses clock"},
	{kind = .Key, text = "tab"},
	{kind = .Keys, text = "hello"},
	{kind = .Wait, text = "interface_elements: the text is \"hello\""},
	{kind = .Shot, text = "interface_elements"},
	{kind = .Key, text = "tab"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "interface_elements: the damage is shown"},
	{kind = .Shot, text = "interface_damage"},
	{kind = .Close, text = "interface_elements"},
	{kind = .Wait, text = "root: interface_elements stopped"},
	// The vector font of the system (docs/FONTS.md): the seven candidates,
	// each from a glyph cache that the program builds, beside Spleen 8x16.
	{kind = .Launch, text = "vector_glyphs"},
	{kind = .Wait, text = "vector_glyphs: one glyph from its outline, in fixed point"},
	{kind = .Wait, text = "vector_glyphs: ok, "},
	{kind = .Shot, text = "font_candidates"},
	{kind = .Close, text = "vector_glyphs"},
	{kind = .Wait, text = "root: vector_glyphs stopped"},
	// The interface font (docs/FONTS.md, section 12): B612 placed by
	// support/text_shaping and drawn by graphics.text_proportional.
	{kind = .Launch, text = "interface_font"},
	{kind = .Wait, text = "interface_font: one line of "},
	{kind = .Wait, text = "interface_font: ok, "},
	{kind = .Shot, text = "interface_font"},
	{kind = .Close, text = "interface_font"},
	{kind = .Wait, text = "root: interface_font stopped"},
	// The pointer pictures (docs/POINTERS.md): the shape that the compositor
	// chooses for what is under the pointer, and the shape that a program
	// asks for over its own surface. The window of pointers shows each
	// shape of the theme of the owner, then of the theme of the system.
	{kind = .Launch, text = "pointers"},
	{kind = .Wait, text = "pointers: ok, ", any_order = true},
	{kind = .Wait, text = "compositor: surface pointers"},
	{kind = .Point, inside_window = "pointers", x = 100, y = 12, text = "move"}, // The title bar.
	{kind = .Point, inside_window = "pointers", x = -14, y = 12, text = "pointing_hand"}, // The close button.
	{kind = .Point, inside_window = "pointers", x = 1, y = 300, text = "arrow"}, // The left border.
	{kind = .Point, inside_window = "pointers", x = 2 + 208 + 60, y = 24 + 368 + 60, text = "wait"}, // The tile of wait (programs/pointers, tile_area(6)): the request of the program.
	{kind = .Wait, text = "compositor: pointers asks for the pointer shape wait over its surface"},
	{kind = .Shot, text = "pointers"},
	{kind = .Point, inside_window = "pointers", x = 2 + 16 + 60, y = 24 + 216 + 60, text = "arrow"}, // The tile of arrow.
	{kind = .Point, inside_window = "pointers", x = 2 + 592 + 60, y = 24 + 216 + 60, text = "move"}, // The tile of move.
	{kind = .Click, inside_window = "pointers", x = 300, y = 60}, // The second button: the theme of the system.
	{kind = .Wait, text = "pointers: the theme pointers_system is shown"},
	{kind = .Point, inside_window = "pointers", x = 2 + 784 + 60, y = 24 + 368 + 60, text = "help"}, // The tile of help, in the theme of the system.
	{kind = .Shot, text = "pointers_system"},
	{kind = .Close, text = "pointers"},
	{kind = .Wait, text = "root: pointers stopped"},
	{kind = .Point, x = 116, y = 14, text = "pointing_hand"}, // The button of the programs in the bar.
	{kind = .Point, x = 600, y = 16, text = "arrow"}, // The bar.
	{kind = .Front, text = "console"},
	{kind = .Point, inside_window = "console", x = 200, y = 120, text = "text"}, // The surface of the terminal: its request.
	{kind = .Shot, text = "pointer_text"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Point, x = 400, y = 120, text = "text"}, // The input band of the palette.
	{kind = .Point, x = 400, y = 180, text = "pointing_hand"}, // The first entry of its list, under the heading of its group.
	{kind = .Point, x = 400, y = 476, text = "arrow"}, // Its footer.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is closed by the key super"},
	// The settings of the system: the font, the order of the stripes, the
	// pointer theme and the grid fit change while the programs run; each
	// window draws again, with no code of its own for it. Each change is
	// kept in the private store of settings.
	{kind = .Launch, text = "settings"},
	{kind = .Wait, text = "compositor: surface settings", any_order = true},
	{kind = .Wait, text = "settings: ok, font vector, subpixel order rgb, pointer theme owner, grid fit on"},
	{kind = .Front, text = "monitor"},
	{kind = .Move, text = "monitor", to_x = 8, to_y = 408},
	{kind = .Front, text = "settings"},
	{kind = .Move, text = "settings", to_x = 456, to_y = 40},
	{kind = .Shot, text = "font_vector"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"settings\")"},
	{kind = .Wait, text = "[console]   module     settings"},
	{kind = .Wait, text = "[console]   commands   3"},
	{kind = .Wait, text = "[console]   call       service"},
	{kind = .Type, text = "settings.set(\"font\", \"spleen\")"},
	{kind = .Wait, text = "compositor: the settings changed: font spleen, subpixel order rgb, pointer theme owner, grid fit on; ", any_order = true},
	{kind = .Wait, text = "settings: drawn with font spleen, subpixel order rgb, pointer theme owner, grid fit on"},
	{kind = .Front, text = "settings"},
	{kind = .Shot, text = "font_spleen"},
	{kind = .Call, text = "settings.get(\"font\")", expected = "spleen"},
	{kind = .Call, text = "settings.set(\"font\", \"vector\")", expected = "1"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on; "},
	{kind = .Call, text = "settings.set(\"grid_fit\", \"off\")", expected = "1"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit off; "},
	{kind = .Wait, text = "settings: drawn with font vector, subpixel order rgb, pointer theme owner, grid fit off"},
	{kind = .Shot, text = "font_without_grid_fit"},
	{kind = .Call, text = "settings.set(\"pointer_theme\", \"system\")", expected = "1"},
	{kind = .Wait, text = "compositor: the pointer theme in use: System", any_order = true}, // Written before the line of the change.
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme system, grid fit off; "},
	{kind = .Point, inside_window = "settings", x = 100, y = 12, text = "move"}, // The title bar, in the theme of the system.
	{kind = .Call, text = "settings.set(\"subpixel_order\", \"bgr\")", expected = "1"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order bgr, pointer theme system, grid fit off; "},
	{kind = .Call, text = "settings.get(\"subpixel_order\")", expected = "bgr"},
	{kind = .Call, text = "settings.set(\"font\", \"comic\")", outcome = .Failed, expected = "(-3)"},
	{kind = .Call, text = "settings.set(\"colour\", \"red\")", outcome = .Failed, expected = "(-2)"},
	{kind = .Call, text = "settings.set(\"subpixel_order\", \"rgb\")", expected = "1"},
	{kind = .Call, text = "settings.set(\"pointer_theme\", \"owner\")", expected = "1"},
	{kind = .Call, text = "settings.set(\"grid_fit\", \"on\")", expected = "1"},
	{kind = .Wait, text = "settings: drawn with font vector, subpixel order rgb, pointer theme owner, grid fit on"},
	{kind = .Shot, text = "settings"},
	{kind = .Close, text = "settings"},
	{kind = .Wait, text = "root: settings stopped"},
	// Tables and bytes as parameters: one description, three ways to call
	// (docs/MODULE_CONTRACT.md). The program loads sample, starts a call
	// host of it, and connects to the service sample, which the root
	// service starts: the same module, the same arguments, the same answers.
	{kind = .Launch, text = "tables"},
	{kind = .Wait, text = "compositor: surface tables", any_order = true},
	{kind = .Wait, text = "tables: the ways: direct ready, call host ready, service ready"},
	{kind = .Wait, text = "tables: sum_values, direct call: "},
	{kind = .Wait, text = "tables: ok, 8 cases in 3 ways and 8 hostile cases"},
	{kind = .Shot, text = "tables"},
	{kind = .Close, text = "tables"},
	{kind = .Wait, text = "root: tables stopped"},
	// The interface package as a module for one program: the same frame
	// through the exports of interface_module and with the package compiled
	// in gives the same draw table.
	{kind = .Launch, text = "interface_through_module"},
	{kind = .Wait, text = "compositor: surface interface_through_module", any_order = true},
	{kind = .Wait, text = "interface_through_module: one frame of "},
	{kind = .Wait, text = " records asked, 16 drawn, the count of the full frame"},
	{kind = .Wait, text = "interface_through_module: ok, the two draw tables are equal"},
	{kind = .Shot, text = "interface_module"},
	{kind = .Close, text = "interface_through_module"},
	{kind = .Wait, text = "root: interface_through_module stopped"},
	{kind = .Front, text = "console"},
	// The line editor of the console. The console writes a log line only
	// when the input asks (Tab, a take): the lines that the scenario types
	// before this place add no record to the log.
	// Fuzzy completion: "mcnt" holds the letters of monitor.count in their
	// order. The list opens while the line is typed; Escape closes it, Tab
	// opens it again, and Enter takes the first name, with its '('.
	{kind = .Type, text = "clear()"},
	{kind = .Keys, text = "mcnt"},
	{kind = .Key, text = "esc"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "console: the completion list opens by Tab: "},
	{kind = .Wait, text = " match \"mcnt\", the first is monitor.count; one ranking takes "},
	// The colors of the first row, from the log and not from a pixel:
	// monitor . count, then export of monitor ( name : Text ) -> Integer.
	{kind = .Wait, text = " keys; its first row has 13 runs of code"},
	// The picture shows the signatures of the rows in the colors of code,
	// and the edit line "> mcnt" plain: the name is still being typed.
	{kind = .Shot, text = "console_completion"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "console: the completion gave the line monitor.count("},
	{kind = .Keys, text = "\"processors\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "> monitor.count(\"processors\")"},
	// The cursor inside the line: Home, Right, a character at the cursor,
	// End, Left, Delete, Backspace. The printed text shows each change in
	// its place: "acdf" becomes "abce".
	{kind = .Keys, text = "\"acdf\""},
	{kind = .Key, text = "home"},
	{kind = .Key, text = "right"},
	{kind = .Key, text = "right"},
	{kind = .Keys, text = "b"},
	{kind = .Key, text = "end"},
	{kind = .Key, text = "left"},
	{kind = .Key, text = "left"},
	{kind = .Key, text = "delete"},
	{kind = .Key, text = "backspace"},
	{kind = .Keys, text = "e"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] abce"},
	// The search of the history: Control-R opens it over the lines entered,
	// the newest first; "leng" keeps the lines that start with "length",
	// these two first (equal scores: the newest first). Control-R goes to
	// the older one, Control-S back to the newer one; Enter puts the chosen
	// line in the input, and a second Enter runs it.
	{kind = .Type, text = "length(\"first search line\")"},
	{kind = .Wait, text = "[console] 17"},
	{kind = .Type, text = "length(\"second\")"},
	{kind = .Wait, text = "[console] 6"},
	{kind = .Key, text = "ctrl-r"},
	{kind = .Keys, text = "leng"},
	{kind = .Key, text = "ctrl-r"},
	{kind = .Key, text = "ctrl-s"},
	{kind = .Key, text = "ctrl-r"},
	{kind = .Shot, text = "console_history_search"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "console: the history search gave the line length(\"first search line\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "> length(\"first search line\")"},
	{kind = .Wait, text = "[console] 17"},
	// The time of one key with the list open, for the names of this console
	// and for the worst case of 512 names of 128 bytes.
	{kind = .Type, text = "measure_completion()"},
	{kind = .Wait, text = "console: one key with the completion list: the collect "},
	{kind = .Wait, text = " names (the names of this console, the least of 20 batches of 10)"},
	{kind = .Wait, text = "console: one key with the completion list: the collect "},
	{kind = .Wait, text = " over 512 names (512 names of 128 bytes, the least of 20 batches of 10)"},
	// Each page is free or paid, after all the starts and stops of this test.
	{kind = .Type, text = "memory()"},
	{kind = .Wait, text = "free_pages_no_budget_holds  0"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// The measures of the locks of the kernel, with only the desktop.
@(rodata)
scenario_measure := [?]Step {
	{kind = .Wait, text = "boot program: ok"},
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "root: ok"},
	{kind = .Wait, text = "compositor: first frame", any_order = true},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Launch, text = "locks"},
	{kind = .Wait, text = "locks: kernel entries in one second, each locker on its own objects: "},
	{kind = .Wait, text = "locks: pages on first use in one second, each locker in its own memory: "},
	{kind = .Wait, text = "locks: word wait, two threads wake each other: "},
	{kind = .Wait, text = "locks: frames: "},
	{kind = .Wait, text = "locks: frame caches after the measures (frames now, batches taken, batches given, drains): processor 0: "},
	{kind = .Wait, text = "locks: ok, the kernel counted each entry, each page returned, no wake was lost, each stopped program returned its pages, its slot and its threads"},
	{kind = .Shot, text = "locks_alone"},
	// One empty kernel entry with xmm, ymm and zmm in use: the cost of the
	// save of the extended state (docs/ARCHITECTURE.md, "The extended state
	// of the processor", section 4).
	{kind = .Launch, text = "extended_state"},
	{kind = .Wait, text = "extended_state: the parts of a save and a restore, each alone in this program, cycles of the cycle counter for one loop (ns): "},
	{kind = .Wait, text = "extended_state: each instruction alone, cycles of the cycle counter for one loop (ns), the loop included: "},
	{kind = .Wait, text = "extended_state: a hand-over between two threads by the word wait (a wake, a wait, and the save and restore of the thread that waits and of the thread that runs): "},
	{kind = .Wait, text = "extended_state: an empty kernel entry, 100000 times: "},
	{kind = .Wait, text = "extended_state: ok, "},
	{kind = .Front, text = "console"},
	// One key of the completion list of the console, with no other load.
	{kind = .Type, text = "measure_completion()"},
	{kind = .Wait, text = " names (the names of this console, the least of 20 batches of 10)"},
	{kind = .Wait, text = " over 512 names (512 names of 128 bytes, the least of 20 batches of 10)"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// The shortage of frames: a machine whose boot image has no desktop; the
// root service gives nearly all its pages to the program shortage, which
// takes all the frames, drains the stacks, frees all, and stops the machine
// (`kerneltool test shortage`, `kerneltool measure without_checks shortage`).
@(rodata)
scenario_shortage := [?]Step {
	{kind = .Wait, text = "boot program: ok"},
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "root: started shortage with "},
	{kind = .Wait, text = "shortage: full: "},
	{kind = .Wait, text = "shortage: ok, the stacks were drained for takes that cannot fail, a new object failed only when its budget could pay no page, and each frame returned"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// The virtual memory of a program with only the desktop (`kerneltool
// measure address_space`).
@(rodata)
scenario_measure_address_space := [?]Step {
	{kind = .Wait, text = "boot program: ok"},
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "root: ok"},
	{kind = .Wait, text = "compositor: first frame", any_order = true},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Launch, text = "address_space"},
	{kind = .Wait, text = "address_space: arena: 1 GiB of addresses in one mapping, "},
	{kind = .Wait, text = "address_space: sparse table: 1024 pages committed of 262144, 1024 with a frame; decommit: 1024 pages back in the budget at once"},
	{kind = .Wait, text = "address_space: protection of 64 pages, one call with its shoot-down, the middle of 40 calls"},
	{kind = .Wait, text = "address_space: guard page: the child stopped with vector 14 at "},
	{kind = .Wait, text = "address_space: edge case: a map with a flag that the kernel does not know is refused: right", any_order = true},
	{kind = .Wait, text = "address_space: large pages: one random read over 64 MiB: "},
	// Each page table that a mapping made returns to the budget with its
	// unmap, at three levels, for a reservation, for a large page, and
	// while another thread uses a page of the same table.
	{kind = .Wait, text = "address_space: page tables: 64 mappings of one page, each at its own entry of three levels: 3 to 3 pages of tables while mapped, 0 pages kept after the unmap: as it must"},
	{kind = .Wait, text = "address_space: page tables: a reservation of 1024 pages: 4 pages of tables, the same after a commit and a decommit of 16 pages, 0 pages kept after the unmap: as it must"},
	{kind = .Wait, text = "address_space: page tables: a large page: 2 pages of tables above it while mapped, 0 pages kept after the unmap: as it must"},
	{kind = .Wait, text = "address_space: page tables: 1000 rounds of a map and an unmap beside a page that another thread writes and reads: 1000 rounds right, the page of the other thread stayed right, 0 pages kept: as it must"},
	{kind = .Wait, text = "address_space: ok, the arena and the sparse table paid only what they used, the decommit gave each page back, the protection changed with its shoot-down, the guard page stopped the child, the large pages are in the report, each refusal has its error record"},
	{kind = .Shot, text = "address_space"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// The scheduling strategies with only the desktop (`kerneltool measure
// scheduler N`).
@(rodata)
scenario_measure_scheduler := [?]Step {
	{kind = .Wait, text = "boot program: ok"},
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "root: ok"},
	{kind = .Wait, text = "compositor: first frame", any_order = true},
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Launch, text = "scheduler"},
	{kind = .Wait, text = "scheduler: EEVDF: two threads that wake each other, a spinner on each processor: "},
	{kind = .Wait, text = "scheduler: stress: 100 changes of strategy while "},
	{kind = .Wait, text = "scheduler: EEVDF woke "},
	{kind = .Wait, text = "scheduler: the window took "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// The film of the terminal: the program flood writes lines, the scenario
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
	call_socket: string, // The socket where the peer receives the calls of the tool.
	peer:        ^Peer,
	confirm:     bool, // The tool reads compositor.pointer() before each press: see pointer_confirm.
	keys_confirmed: int, // Keys whose records the compositor received before the tool went on (keys_send).
	key_batches_confirmed: int, // The sends of keys that ended with that count of the compositor.
	qmp:         Qmp, // The connection to the machine protocol of QEMU: the keys, the pointer, the pictures.
	log_watch:   Log_Watch, // The wait for a change of the log (log_watch_linux.odin).
	device_bytes: int, // The bytes that the tool sent to the virtual keyboard and mouse since the system had read them all.
	pointer_packets: int, // The packets of the virtual mouse that the tool sent.
	picture_jobs: [dynamic]^Picture_Job, // The pictures that worker threads turn into PNG files.
	picture_time: Picture_Time, // The times of the picture that the tool takes now: each picture of QEMU and each read of its file.
	pictures_settled_by_calls: int, // The pictures that the tool took when the programs and the compositor said that the screen was settled (screen_settle.odin).
	pictures_settled_by_pictures: int, // The pictures that the tool took when two pictures in a row were the same.
	confirmations: [dynamic]time.Duration, // The time of each confirmation of a place.
	corrected:   int, // The places that needed a correction.
	record_next: i64, // The number of the log record where the next Record step searches.
	powered_off: bool, // A step Power_Loss ended QEMU: the machine has no exit status.
	disk_server: ^Network_Block_Device, // The data disk, when the tool serves it.
	client:      Call_Client,
	client_open: bool,
	forward:     Forward, // QEMU user networking: the port of hostfwd and the listener of guestfwd.
	started_at:  time.Tick, // When QEMU started: the first Wait says how long the boot took.
	started_unix: i64, // When QEMU started, in seconds since 1970: no date that the machine prints is before it.
	times:       Machine_Step_Times, // The times of the step that runs (test_times.odin).
	echo:        Console_Echo, // The lines typed into the console whose echo the tool waits for (console_echo.odin).
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
	case ':':
		return "shift-semicolon"
	case ';':
		return "semicolon"
	case '[':
		return "bracket_left"
	case ']':
		return "bracket_right"
	case '^':
		return "shift-6"
	case '>':
		return "shift-dot"
	case '<':
		return "shift-comma"
	case '?':
		return "shift-slash"
	case '@':
		return "shift-2"
	}
	return ""
}

// The text of a Click step that presses a button of the bar: the tool
// takes its middle from the layout of the bar (machine_bar_layout), not
// from a typed place, because the width of a button is the width of its
// name in the font that draws it.
BAR_PROGRAMS_BUTTON :: "the button programs of the bar"
BAR_WINDOWS_BUTTON :: "the button windows of the bar"

WINDOW_GRAB_X :: 100 // A point of the title bar of each window.
WINDOW_GRAB_Y :: 12
// The close button of a window, as the compositor draws it: its center, from
// the right side and from the top of the window.
WINDOW_BORDER :: 2
WINDOW_TITLE_HEIGHT :: 24 // The title bar of a window, above its surface.
WINDOW_CLOSE_RIGHT :: 14
WINDOW_CLOSE_Y :: 12

// window_width gives the width of the surface of the last window with a
// title: "compositor: surface title 480x320 at 276,232".
window_width :: proc(machine: ^Machine, title: string) -> (width: int, ok: bool) {
	if machine.confirm {
		_, _, outer_width := window_of_compositor(machine, title) or_return
		return outer_width - 2 * WINDOW_BORDER, true
	}
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
// compositor writes it when it makes the window, and when the pointer puts the
// window down: "compositor: surface title 480x320 at 276,232" and
// "compositor: window title moved to 60,742".
window_place :: proc(machine: ^Machine, title: string) -> (x, y: int, ok: bool) {
	if machine.confirm {
		x, y, _ = window_of_compositor(machine, title) or_return
		return x, y, true
	}
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

// window_of_compositor gives the place and the outer width of the window
// with a title, from compositor.windows(): the table of the compositor
// itself. The tool reads it once it has the grant `acts_for_principal` (a
// step Call with pointer); before that step, the places come from the log.
window_of_compositor :: proc(machine: ^Machine, title: string) -> (x, y, width: int, ok: bool) {
	table := table_call(&machine.client, "compositor.windows()") or_return
	for row in 0 ..< len(table.rows) / table.size {
		if table_value(&table, row, "title") != title {
			continue
		}
		x = strconv.parse_int(table_value(&table, row, "x")) or_return
		y = strconv.parse_int(table_value(&table, row, "y")) or_return
		width = strconv.parse_int(table_value(&table, row, "width")) or_return
		return x, y, width, true
	}
	return 0, 0, 0, false
}

// log_read gives the complete lines of the log of the machine. QEMU writes
// the log one byte at a time: the last line can be a part of a line, and a
// part of "at 168,142" reads as another place.
// The regular cache of the interface font, read once from the build: the
// bytes of the resource interface_glyph_cache of the boot image.
machine_interface_cache: glyph_cache.Cache
machine_interface_cache_words: []u64

// machine_bar_layout gives the places of the bar of the compositor of the
// machine. The last line of the log that names the font of the bar says
// which font it is; in the interface font, the tool measures the layout
// from the cache file of the build, and confirms it against the numbers
// that the compositor wrote: a press must land on the entry that the eye
// sees. ok is false, with a line, when the two measures differ or the log
// has no such line yet.
machine_bar_layout :: proc(machine: ^Machine) -> (layout: bar.Layout, ok: bool) {
	INTERFACE_LINE :: "compositor: the bar is in the interface font: "
	CELLS_LINE :: "compositor: the bar is in the font of the cells"
	text := log_read(machine)
	interface_at := strings.last_index(text, INTERFACE_LINE)
	cells_at := strings.last_index(text, CELLS_LINE)
	if interface_at < 0 && cells_at < 0 {
		fmt.eprintln("kerneltool: test failed: the log does not say in which font the compositor draws its bar")
		return {}, false
	}
	if interface_at < cells_at {
		return bar.layout_of(nil), true
	}
	if machine_interface_cache_words == nil {
		bytes, read_error := os.read_entire_file(INTERFACE_GLYPH_CACHE_OUTPUT, context.allocator)
		if read_error != nil {
			fmt.eprintfln("kerneltool: test failed: cannot read %s: %v", INTERFACE_GLYPH_CACHE_OUTPUT, read_error)
			return {}, false
		}
		// validate needs memory aligned on 8 bytes.
		machine_interface_cache_words = make([]u64, (len(bytes) + 7) / 8)
		aligned := ([^]u8)(raw_data(machine_interface_cache_words))[:len(bytes)]
		copy(aligned, bytes)
		delete(bytes)
		refused: glyph_cache.Problem
		machine_interface_cache, refused = glyph_cache.validate(aligned)
		if refused.kind != .None {
			fmt.eprintfln("kerneltool: test failed: %s is refused: %s", INTERFACE_GLYPH_CACHE_OUTPUT, glyph_cache.problem_sentences[refused.kind])
			delete(machine_interface_cache_words)
			machine_interface_cache_words = nil
			return {}, false
		}
	}
	layout = bar.layout_of(&machine_interface_cache)
	expected := fmt.tprintf("%sprograms %d pixels, windows %d, the widest name %d", INTERFACE_LINE, layout.label_width, layout.windows_label_width, layout.longest_name_width)
	if !strings.has_prefix(text[interface_at:], expected) {
		end := strings.index_byte(text[interface_at:], '\n')
		fmt.eprintfln("kerneltool: test failed: the tool measures the bar as \"%s\", the compositor wrote \"%s\"", expected, text[interface_at:][:end < 0 ? len(text) - interface_at : end])
		return {}, false
	}
	return layout, true
}

log_read :: proc(machine: ^Machine) -> string {
	log, err := os.read_entire_file(machine.output, context.temp_allocator)
	if err != nil {
		return ""
	}
	text := string(log[:strings.last_index_byte(string(log), '\n') + 1])
	test_times_first_line_note(machine, len(text))
	return text
}

// windows_line gives the line of the last window with a title in the menu
// of the windows. The compositor writes the lines when the menu opens:
// "compositor: windows: console, life, monitor". from: the bytes of the
// log before the menu opened.
windows_line :: proc(machine: ^Machine, title: string, from: int) -> (line: int, ok: bool) {
	MARK :: "compositor: windows: "
	for start := time.now(); time.since(start) < HANG_BOUND; {
		text := log_read(machine)
		at := len(text) > from ? strings.index(text[from:], MARK) : -1
		if at < 0 {
			log_change_wait(machine)
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

log_wait :: proc(machine: ^Machine, text: string, any_order := false, limit := HANG_BOUND) -> bool {
	wait_started := time.tick_now()
	defer test_times_wait_note(machine, wait_started)
	start := time.now()
	for time.since(start) < limit {
		log := log_read(machine)
		if len(log) > machine.seen {
			if index := strings.index(log[machine.seen:], text); index >= 0 {
				if !any_order {
					machine.seen += index + len(text)
				}
				return true
			}
		}
		log_change_wait(machine)
	}
	return false
}

// log_wait_or_failure waits until the log, after the last Wait, has text or
// failure. It gives the line of failure when failure came first, and
// text_found when text came first. It does not move the place of the log:
// the Wait that follows finds text there at once.
log_wait_or_failure :: proc(machine: ^Machine, text, failure: string, limit: time.Duration) -> (failure_line: string, text_found: bool) {
	wait_started := time.tick_now()
	defer test_times_wait_note(machine, wait_started)
	start := time.now()
	for time.since(start) < limit {
		log := log_read(machine)
		if len(log) > machine.seen {
			rest := log[machine.seen:]
			text_at := strings.index(rest, text)
			failure_at := strings.index(rest, failure)
			if failure_at >= 0 && (text_at < 0 || failure_at < text_at) {
				line := rest[failure_at:]
				end := strings.index_byte(line, '\n')
				return strings.trim_right(end < 0 ? line : line[:end], "\r"), false
			}
			if text_at >= 0 {
				return "", true
			}
		}
		log_change_wait(machine)
	}
	return "", false
}

// log_last_line gives the last line of the log of the machine that has a
// text, from that text, or "" when none has it.
log_last_line :: proc(machine: ^Machine, text: string) -> string {
	log := log_read(machine)
	at := strings.last_index(log, text)
	if at < 0 {
		return ""
	}
	rest := log[at:]
	end := strings.index_byte(rest, '\n')
	return strings.trim_right(end < 0 ? rest : rest[:end], "\r")
}

// machine_test runs a scenario on a boot volume. It passes when each step
// passes and QEMU ends with the status exit_status.
machine_test :: proc(steps: []Step, volume: string, output: string, exit_status: int, data_disk: string = TEST_DATA_DISK, user_network := false, disk_server: ^Network_Block_Device = nil, processor: Processor_Model = .Maximum, firmware: Machine_Firmware = .Usual) -> bool {
	machine_test_started := time.tick_now()
	// The software TPM runs before QEMU and ends after it, with a folder of
	// its own for each machine.
	tpm: Tpm_Process
	if firmware == .With_Tpm && !tpm_start(&tpm, output) {
		return false
	}
	defer tpm_stop(&tpm)
	peer: Peer
	if !peer_start(&peer) {
		return false
	}
	defer peer_stop(&peer)
	listener: Listener
	forward: Forward
	if user_network {
		port, free := free_port()
		if !free || !listener_start(&listener) {
			fmt.eprintln("kerneltool: no port of the loopback for the TCP of QEMU")
			return false
		}
		forward = {host_port = port, listener = &listener}
	}
	defer listener_stop(&listener)
	command, ok := machine_command(volume, output, data_disk, &peer, forward, processor, firmware)
	if !ok {
		return false
	}
	_ = os.remove(output)
	_ = os.remove(qmp_socket_of(output))
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
		started_at = time.tick_now(),
		started_unix = time.time_to_unix(time.now()),
		process   = process,
		monitor   = monitor_write,
		output    = output,
		call_socket = peer.call_socket,
		peer      = &peer,
		forward   = forward,
		disk_server = disk_server,
	}
	// The keys, the moves of the pointer and the pictures go through the
	// machine protocol of QEMU: QEMU listens when it started.
	passed := qmp_open(&machine.qmp, qmp_socket_of(output)) && scenario_run(&machine, steps)
	scenario_ended := time.tick_now()
	if !passed && firmware != .Usual {
		// While QEMU still runs: what the firmware shows and wrote.
		firmware_failure_report(&machine, output)
	}
	// Each picture has its PNG file before the test ends: a picture that
	// is not written fails the test.
	if !pictures_join(&machine) {
		passed = false
	}
	if machine.pictures_settled_by_calls + machine.pictures_settled_by_pictures > 0 {
		test_passed_print("the tool took %d pictures when the programs were in a wait and the compositor had drawn each picture that it received, and %d when two pictures in a row were the same", machine.pictures_settled_by_calls, machine.pictures_settled_by_pictures)
	}
	if len(machine.confirmations) > 0 {
		slice.sort(machine.confirmations[:])
		test_passed_print("the tool confirmed %d places of the pointer through compositor.pointer(), %d after a correction; one confirmation took %d us at least, %d us in the middle", len(machine.confirmations), machine.corrected, i64(machine.confirmations[0] / time.Microsecond), i64(machine.confirmations[len(machine.confirmations) / 2] / time.Microsecond))
	}
	if machine.keys_confirmed > 0 {
		test_passed_print("the tool sent %d keys in %d sends, and went on after each send only when the compositor had received each record of its keys", machine.keys_confirmed, machine.key_batches_confirmed)
	}
	if machine.client_open {
		call_client_close(&machine.client)
	}
	state: os.Process_State
	if passed && machine.powered_off {
		state, _ = os.process_wait(process, HANG_BOUND)
	} else if passed {
		wait_err: os.Error
		state, wait_err = os.process_wait(process, HANG_BOUND)
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
	qmp_close(&machine.qmp)
	log_watch_close(&machine.log_watch)
	delete(machine.picture_jobs)
	peer_stop(&peer)
	if passed {
		passed = peer_check(&peer)
	}
	// The kernel with a check skipped runs only from its own boot volume:
	// another machine that prints its line ran a kernel of the test by
	// mistake, and its result is not a result of the kernel.
	if passed && volume != BOOT_VOLUME_WITHOUT_RETURN_CHECK {
		log, _ := os.read_entire_file(output, context.temp_allocator)
		if strings.contains(string(log), TEST_KERNEL_WITHOUT_RETURN_CHECK_LINE) {
			fmt.eprintfln("kerneltool: test failed: the machine of %s ran the kernel of the test with a check skipped: \"%s\"", volume, TEST_KERNEL_WITHOUT_RETURN_CHECK_LINE)
			passed = false
		}
	}
	if !passed {
		log, _ := os.read_entire_file(output, context.temp_allocator)
		lines := strings.split_lines(string(log), context.temp_allocator)
		fmt.eprintln("kerneltool: the end of the log of the kernel:")
		for line in lines[max(len(lines) - 25, 0):] {
			fmt.eprintln("   ", line)
		}
	}
	test_times_machine_end(&machine, passed, machine_test_started, machine.started_at, scenario_ended)
	return passed
}

// The values that the steps Remember kept, in one test part (several
// machines): the step Distinct compares them.
remembered_values: [dynamic]string

// remote_starts_or_ends says if a step starts `remote` or closes it: the
// next start makes a new key, so the key of the log is read again.
remote_starts_or_ends :: proc(step: Step) -> bool {
	#partial switch step.kind {
	case .Launch, .Close:
		return step.text == "remote"
	case .Type:
		return strings.contains(step.text, "start(\"remote\")")
	case .Power_Loss:
		return true
	}
	return false
}

// remote_key_problem names the first step that calls `remote` with no step
// Remote_Key since the last start of `remote`, or gives "". The key of
// `remote` belongs to one start: a call with the key of an earlier start,
// or of another machine, is refused by the pin, so a scenario that could
// make one does not run.
remote_key_problem :: proc(steps: []Step) -> string {
	key_read := false
	for step, index in steps {
		if remote_starts_or_ends(step) {
			key_read = false
			continue
		}
		#partial switch step.kind {
		case .Remote_Key:
			key_read = true
		case .Call, .Record, .Agree, .Remote_Case, .Point:
			if !key_read {
				return fmt.tprintf("step %d (%v %s) calls remote with no step Remote_Key since the last start of remote", index + 1, step.kind, step.text)
			}
		}
	}
	return ""
}

scenario_run :: proc(machine: ^Machine, steps: []Step) -> bool {
	if problem := remote_key_problem(steps); problem != "" {
		fmt.eprintfln("kerneltool: test failed: the scenario is refused before it runs: %s", problem)
		return false
	}
	peer_case_started := 0 // The number of the case of the last step Peer_Start.
	first_wait := true // The first Wait of the machine is its boot: BOOT_HANG_BOUND.
	generation_base: i64 = -1 // The number that the last step Generation read; -1: none.
	for given_step, index in steps {
		step := given_step
		// The time of the step, for a step that passes and for one that fails.
		step_started := time.tick_now()
		test_times_step_start(machine)
		defer test_times_step_end(machine, index, given_step, step_started)
		if index > 0 {
			console_echo_note_step(&machine.echo, steps[index - 1]) // The step before passed.
		}
		if index > 0 && remote_starts_or_ends(steps[index - 1]) && machine.peer != nil && machine.peer.remote != nil {
			// The step before started or closed `remote`: its key of the
			// start before is forgotten, and the tool no longer reads the
			// pointer through it until a call with pointer again.
			peer_remote_unpin(machine.peer.remote)
			machine.confirm = false
		}
		if strings.contains(step.text, "{generation") || strings.contains(step.expected, "{generation") {
			if generation_base < 0 {
				fmt.eprintfln("kerneltool: test failed: step %d names {generation} before a step Generation", index + 1)
				return false
			}
			step.text = generation_expand(step.text, generation_base)
			step.expected = generation_expand(step.expected, generation_base)
		}
		switch step.kind {
		case .Wait:
			limit := first_wait ? BOOT_HANG_BOUND : HANG_BOUND
			if step.seconds > 0 {
				limit = time.Duration(step.seconds) * time.Second
			}
			was_first_wait := first_wait
			first_wait = false
			if step.fails_on != "" {
				failure_line, text_found := log_wait_or_failure(machine, step.text, step.fails_on, limit)
				if failure_line != "" {
					fmt.eprintfln("kerneltool: test failed: step %d: the machine printed \"%s\" before \"%s\"", index + 1, failure_line, step.text)
					return false
				}
				if !text_found {
					fmt.eprintfln("kerneltool: test failed: step %d: the machine printed neither \"%s\" nor \"%s\" within %v", index + 1, step.text, step.fails_on, limit)
					return false
				}
			}
			if !log_wait(machine, step.text, step.any_order, limit) {
				fmt.eprintfln("kerneltool: test failed: step %d: the machine did not print \"%s\" within %v", index + 1, step.text, limit)
				return false
			}
			if was_first_wait {
				test_passed_print("the machine printed \"%s\", %.1f s after the start of QEMU", step.text, time.duration_seconds(time.tick_since(machine.started_at)))
			} else {
				test_passed_print("the machine printed \"%s\"", step.text)
			}
		case .Date:
			seen_before := machine.seen
			if !log_wait(machine, step.text, step.any_order) {
				fmt.eprintfln("kerneltool: test failed: step %d: the machine did not print \"%s\"", index + 1, step.text)
				return false
			}
			log := log_read(machine)
			value, found := number_after(log[seen_before:], step.text)
			if !found {
				fmt.eprintfln("kerneltool: test failed: step %d: no number after \"%s\"", index + 1, step.text)
				return false
			}
			date_check(index, value, step.text, machine.started_unix) or_return
		case .Generation:
			seen_before := machine.seen
			if !log_wait(machine, step.text, step.any_order) {
				fmt.eprintfln("kerneltool: test failed: step %d: the machine did not print \"%s\"", index + 1, step.text)
				return false
			}
			log := log_read(machine)
			value, found := number_after(log[seen_before:], step.text)
			if !found || value < 1 {
				fmt.eprintfln("kerneltool: test failed: step %d: no generation after \"%s\"", index + 1, step.text)
				return false
			}
			generation_base = value
			fmt.printfln("kerneltool: the base of the generations is %d (after \"%s\")", value, step.text)
		case .Trace:
			if !log_wait(machine, step.text) {
				fmt.eprintfln("kerneltool: test failed: step %d: the machine did not print \"%s\"", index + 1, step.text)
				return false
			}
			log := log_read(machine)
			rest := log[machine.seen:]
			line := rest[:max(strings.index_byte(rest, '\n'), 0)]
			found, named := trace_check(strings.trim_right(line, "\r"), step.names)
			if !named {
				fmt.eprintfln("kerneltool: test failed: step %d: the stack trace names %s, not %s", index + 1, found, step.names)
				return false
			}
			test_passed_print("the stack trace after \"%s\" names the functions %s", step.text, found)
		case .Type, .Keys:
			// The keys of the line, and its Enter, go as one list.
			names, unknown := key_names_of_a_text(step.text)
			if unknown >= 0 {
				fmt.eprintfln("kerneltool: step %d: no key for '%c'", index + 1, step.text[unknown])
				return false
			}
			keys := make([dynamic]string, 0, len(names) + 1, context.temp_allocator)
			append(&keys, ..names)
			if step.kind == .Type {
				append(&keys, "ret")
			}
			// A line that goes to the console: the console writes it on the
			// log when it enters it (console_echo.odin).
			echo_wanted := step.kind == .Type && console_echo_wanted(&machine.echo, step.text)
			if echo_wanted {
				console_echo_owe(machine, step.text)
			}
			if !keys_send(machine, keys[:], fmt.tprintf("\"%s\"", step.text)) {
				fmt.eprintfln("kerneltool: test failed: step %d: the machine did not take the keys of \"%s\"", index + 1, step.text)
				return false
			}
			if echo_wanted && !machine.echo.line_can_run && !console_echo_wait(machine, index + 1) {
				return false
			}
		case .Key:
			if !keys_send(machine, []string{step.text}, fmt.tprintf("the key %s", step.text)) {
				fmt.eprintfln("kerneltool: test failed: step %d: the machine did not take the key %s", index + 1, step.text)
				return false
			}
		case .Point:
			x, y := step.x, step.y
			if step.inside_window != "" {
				window_x, window_y, placed := window_place(machine, step.inside_window)
				width, sized := window_width(machine, step.inside_window)
				if !placed || !sized {
					fmt.eprintfln("kerneltool: test failed: step %d: the log does not have the place of the window %s", index + 1, step.inside_window)
					return false
				}
				x = step.x < 0 ? window_x + width + 2 * WINDOW_BORDER + step.x : window_x + step.x
				y = window_y + step.y
			}
			if !machine.confirm {
				fmt.eprintfln("kerneltool: test failed: step %d: a step Point reads compositor.pointer(): the tool does not confirm the pointer yet", index + 1)
				return false
			}
			if !pointer_move(machine, x, y) {
				fmt.eprintfln("kerneltool: test failed: step %d: the pointer did not reach its place", index + 1)
				return false
			}
			// The compositor chooses the shape after the input record and after
			// a request of a program: read it until it is the expected one.
			shape: string
			for start := time.now(); time.since(start) < HANG_BOUND; {
				read, ok := record_text_field(&machine.client, "compositor.pointer()", "shape")
				if ok {
					shape = read
				}
				if shape == step.text {
					break
				}
				time.sleep(CONDITION_POLL_PERIOD)
			}
			if shape != step.text {
				fmt.eprintfln("kerneltool: test failed: step %d: the pointer at %d,%d has the shape \"%s\", not \"%s\"", index + 1, x, y, shape, step.text)
				return false
			}
			test_passed_print("the pointer at %d,%d has the shape %s", x, y, step.text)
		case .Click, .Drag, .Launch, .Move, .Close, .Front:
			step := step
			moved_title: string
			moved_x, moved_y: int
			before := len(log_read(machine))
			if step.kind == .Click && step.inside_window != "" {
				window_x, window_y, placed := window_place(machine, step.inside_window)
				if !placed {
					fmt.eprintfln("kerneltool: test failed: step %d: the log does not have the place of the window %s", index + 1, step.inside_window)
					return false
				}
				step.x += window_x + WINDOW_BORDER
				step.y += window_y + WINDOW_TITLE_HEIGHT
			}
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
				for start := time.now(); !found && time.since(start) < HANG_BOUND; {
					if x, y, found = window_place(machine, step.text); !found {
						log_change_wait(machine)
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
			// The places of the bar come from the font that draws it: the
			// layout that the compositor wrote in its log, measured here
			// from the same cache of the build.
			layout: bar.Layout
			if step.kind == .Launch || step.kind == .Front || step.kind == .Click && (step.text == BAR_PROGRAMS_BUTTON || step.text == BAR_WINDOWS_BUTTON) {
				known: bool
				if layout, known = machine_bar_layout(machine); !known {
					return false
				}
			}
			if step.kind == .Click && step.text == BAR_PROGRAMS_BUTTON {
				step.x, step.y = bar.button_center(layout)
			}
			if step.kind == .Click && step.text == BAR_WINDOWS_BUTTON {
				step.x, step.y = bar.windows_button_center(layout)
			}
			if step.kind == .Launch {
				found: bool
				step.x, step.y, found = bar.center(layout, step.text)
				if !found {
					fmt.eprintfln("error: the menu of the programs does not have the program %s", step.text)
					return false
				}
			}
			if !machine.pointer_known {
				// The pointer starts at an unknown place: push it to the corner.
				machine.pointer_known = true
				if !pointer_corner_push(machine) {
					fmt.eprintfln("kerneltool: test failed: step %d: the pointer did not go to the corner of the screen", index + 1)
					return false
				}
			}
			if step.kind == .Launch {
				menu_x, menu_y := bar.button_center(layout)
				if !pointer_move(machine, menu_x, menu_y) {
					fmt.eprintfln("kerneltool: test failed: step %d: the pointer did not reach its place", index + 1)
					return false
				}
				pointer_button(machine, true) or_return
				pointer_button(machine, false) or_return
				// The compositor writes that the menu is open: a press that
				// the machine did not receive is a failure of this step, with
				// its cause, and not of a later one.
				open := false
				for start := time.now(); !open && time.since(start) < HANG_BOUND; {
					text := log_read(machine)
					if open = len(text) > before && strings.contains(text[before:], "compositor: the menu of the programs is open"); !open {
						log_change_wait(machine)
					}
				}
				if !open {
					fmt.eprintfln("kerneltool: test failed: step %d: the menu of the programs did not open for %s: the machine did not receive the press on its button", index + 1, step.text)
					return false
				}
			}
			if step.kind == .Front {
				menu_x, menu_y := bar.windows_button_center(layout)
				if !pointer_move(machine, menu_x, menu_y) {
					fmt.eprintfln("kerneltool: test failed: step %d: the pointer did not reach its place", index + 1)
					return false
				}
				pointer_button(machine, true) or_return
				pointer_button(machine, false) or_return
				line, found := windows_line(machine, step.text, before)
				if !found {
					fmt.eprintfln("kerneltool: test failed: step %d: the menu of the windows does not have %s", index + 1, step.text)
					return false
				}
				step.x, step.y = bar.windows_line_center(layout, line)
			}
			if !pointer_move(machine, step.x, step.y) {
				fmt.eprintfln("kerneltool: test failed: step %d: the pointer did not reach its place", index + 1)
				return false
			}
			pointer_button(machine, true) or_return
			if step.kind == .Drag {
				if !pointer_move(machine, step.to_x, step.to_y) {
					fmt.eprintfln("kerneltool: test failed: step %d: the pointer did not reach its place", index + 1)
					return false
				}
			}
			pointer_button(machine, false) or_return
			if step.kind == .Front {
				// The compositor writes that the window is in front.
				mark := strings.concatenate({"compositor: window ", step.text, " in front"}, context.temp_allocator)
				arrived := false
				for start := time.now(); !arrived && time.since(start) < HANG_BOUND; {
					text := log_read(machine)
					if arrived = len(text) > before && strings.contains(text[before:], mark); !arrived {
						log_change_wait(machine)
					}
				}
				if !arrived {
					fmt.eprintfln("kerneltool: test failed: step %d: the window %s did not come to the front", index + 1, step.text)
					return false
				}
				test_passed_print("the window %s came to the front", step.text)
			}
			if moved_title != "" {
				// The compositor writes the new place: the window did move.
				arrived := false
				for start := time.now(); !arrived && time.since(start) < HANG_BOUND; {
					x, y, found := window_place(machine, moved_title)
					if arrived = found && x == moved_x && y == moved_y; !arrived {
						log_change_wait(machine)
					}
				}
				if !arrived {
					fmt.eprintfln("kerneltool: test failed: step %d: the window %s is not at %d,%d", index + 1, moved_title, moved_x, moved_y)
					return false
				}
			}
		case .Record:
			if !machine.client_open {
				if !call_client_open(&machine.client, machine.call_socket) {
					return false
				}
				machine.client_open = true
			}
			found := false
			from := machine.record_next
			reads := 0
			last_rows, last_total := 0, i64(0)
			last_ok := false
			last_table: Call_Table
			for start := time.now(); !found && time.since(start) < HANG_BOUND; {
				table, ok := table_call(&machine.client, fmt.tprintf("log.records(%d)", from))
				reads += 1
				rows := ok ? len(table.rows) / table.size : 0
				last_rows, last_total, last_ok = rows, table.total, ok
				last_table = table
				// A text goes on in the next row when its row says so
				// (log.records: a row is one log record, of 152 bytes of
				// text): the rows of one text are joined before the
				// comparison.
				for row := 0; row < rows; {
					last := row
					for last < rows - 1 && table_value(&table, last, "continues") == "1" {
						last += 1
					}
					if table_value(&table, last, "continues") == "1" {
						break // The rest of the text is after the rows of this call: read again from it.
					}
					joined := strings.builder_make(context.temp_allocator)
					for part in row ..= last {
						strings.write_string(&joined, table_value(&table, part, "text"))
					}
					number, _ := strconv.parse_i64(table_value(&table, row, "number"))
					last_number, _ := strconv.parse_i64(table_value(&table, last, "number"))
					if table_value(&table, row, "program") == step.program && table_value(&table, row, "channel") == step.channel && table_value(&table, row, "level") == step.level && strings.contains(strings.to_string(joined), step.text) {
						found = true
						if !step.any_order {
							machine.record_next = last_number + 1
						}
						test_passed_print("the log record %d of %s, channel \"%s\", level %s, has \"%s\" (%d calls of log.records, %d rows)", number, step.program, step.channel, step.level, step.text, reads, last - row + 1)
						break
					}
					from = last_number + 1
					row = last + 1
				}
				if !found && rows == 0 {
					time.sleep(CONDITION_POLL_PERIOD)
				}
			}
			if !found {
				fmt.eprintfln("kerneltool: test failed: step %d: no log record of %s, channel \"%s\", level %s, has \"%s\" (%d calls of log.records, the last one from %d: %v, %d rows of %d)", index + 1, step.program, step.channel, step.level, step.text, reads, from, last_ok, last_rows, last_total)
				compact := strings.builder_make(context.temp_allocator)
				for row in 0 ..< last_rows {
					fmt.sbprintf(&compact, "%s:%s ", table_value(&last_table, row, "number"), table_value(&last_table, row, "continues"))
				}
				fmt.eprintfln("kerneltool:     the rows (number:continues): %s", strings.to_string(compact))
				return false
			}
		case .Agree:
			// The program list of the monitor, and the reports of inspect. The
			// monitor reads the programs of the machine at its own rhythm: a
			// program that just started is in its list at its next read. So
			// the step asks again until the two agree; the bound only ends a
			// hang.
			monitor, mappings, threads: Call_Table
			has_monitor, has_mappings, has_threads: bool
			mapped, threads_count, pages: int
			agree_started := time.now()
			for {
				monitor, has_monitor = table_call(&machine.client, "monitor.programs()")
				mapped, threads_count = -1, -1
				if has_monitor {
					for row in 0 ..< len(monitor.rows) / monitor.size {
						if table_value(&monitor, row, "name") == step.text {
							mapped, _ = strconv.parse_int(table_value(&monitor, row, "mapped"))
							threads_count, _ = strconv.parse_int(table_value(&monitor, row, "threads"))
						}
					}
				}
				mappings, has_mappings = table_call(&machine.client, fmt.tprintf("inspect.mappings(%q)", step.text))
				threads, has_threads = table_call(&machine.client, fmt.tprintf("inspect.threads(%q)", step.text))
				pages = 0
				if has_mappings {
					for row in 0 ..< len(mappings.rows) / mappings.size {
						value, _ := strconv.parse_int(table_value(&mappings, row, "pages"))
						pages += value
					}
				}
				if (has_monitor && has_mappings && has_threads && mapped >= 0 && pages == mapped && int(threads.total) == threads_count) || time.since(agree_started) > HANG_BOUND {
					break
				}
				time.sleep(CONDITION_POLL_PERIOD)
			}
			if !has_monitor || !has_mappings || !has_threads || mapped < 0 || pages != mapped || int(threads.total) != threads_count {
				fmt.eprintfln("kerneltool: test failed: step %d: %s: monitor.programs() gives %d mapped pages and %d threads, inspect gives %d pages in %d mappings and %d threads", index + 1, step.text, mapped, threads_count, pages, mappings.total, threads.total)
				return false
			}
			test_passed_print("%s: inspect gives %d pages in %d mappings and %d threads, as monitor.programs() gives", step.text, pages, mappings.total, threads.total)
		case .Call:
			call_started_unix := time.time_to_unix(time.now()) // No date in the answer is before it.
			if !machine.client_open {
				if !call_client_open(&machine.client, machine.call_socket) {
					return false
				}
				machine.client_open = true
			}
			served_before: i64
			lost_before: int
			if step.lose > 0 {
				before, has_before := record_field(&machine.client, "monitor.served()", "calls")
				if !has_before {
					fmt.eprintfln("kerneltool: test failed: step %d: monitor.served() gave no record", index + 1)
					return false
				}
				served_before = before
				lost_before = peer_remote_lose(machine.peer.remote, step.lose)
			}
			machine.client.wrong_hash = step.wrong_hash
			result := call_run(&machine.client, step.text)
			if step.pointer {
				// A result: the tool confirms each place from now on. A
				// refusal (the grant `acts_for_principal` was revoked): the blind way
				// again.
				machine.confirm = result.outcome == .Result
				test_passed_print("the tool %s the place of the pointer through compositor.pointer() from now on", machine.confirm ? "reads" : "no longer reads")
			}
			printed := strings.join(result.lines[:], "\n", context.temp_allocator)
			for line in result.lines {
				fmt.printfln("kerneltool: call %s: %s", step.text, line)
			}
			if result.outcome != step.outcome || !strings.contains(printed, step.expected) {
				fmt.eprintfln("kerneltool: test failed: step %d: the call %s gave %v, not %v with \"%s\"", index + 1, step.text, result.outcome, step.outcome, step.expected)
				return false
			}
			if result.answer_bytes < step.least_answer_bytes {
				fmt.eprintfln("kerneltool: test failed: step %d: the answer of %s has %d bytes, not %d or more", index + 1, step.text, result.answer_bytes, step.least_answer_bytes)
				return false
			}
			test_passed_print("the call %s printed \"%s\", an answer of %d bytes on one stream, %d datagrams of remote during the call%s", step.text, step.expected, result.answer_bytes, result.datagrams, result.new_connection ? ", on a new connection" : "")
			if step.date_after != "" {
				milliseconds, found := number_after(printed, step.date_after)
				if !found {
					fmt.eprintfln("kerneltool: test failed: step %d: no number after \"%s\" in the answer of %s", index + 1, step.date_after, step.text)
					return false
				}
				date_check(index, milliseconds / 1000, step.text, call_started_unix) or_return
			}
			if step.lose > 0 {
				// QUIC sent the dropped datagrams again; the service ran the
				// call one time: served() counts the call of the step and its
				// own call before.
				lost := peer_remote_lost(machine.peer.remote) - lost_before
				after, has_after := record_field(&machine.client, "monitor.served()", "calls")
				if lost < step.lose || !has_after || after - served_before != 2 {
					fmt.eprintfln("kerneltool: test failed: step %d: the peer dropped %d datagrams of remote (%d asked), and the monitor ran %d calls, not 2", index + 1, lost, step.lose, after - served_before)
					return false
				}
				test_passed_print("the peer dropped %d datagrams of remote during %s; QUIC sent them again, and the monitor ran the call one time", lost, step.text)
			}
			if step.rows_call != "" {
				// Another call gives the count of the rows.
				counted := call_run(&machine.client, step.rows_call)
				if counted.outcome != .Result || counted.value != i64(result.rows) {
					fmt.eprintfln("kerneltool: test failed: step %d: the call gave %d rows, %s gives %d", index + 1, result.rows, step.rows_call, counted.value)
					return false
				}
				test_passed_print("the call gave %d rows, and %s gives %d", result.rows, step.rows_call, counted.value)
			}
			if step.repeat > 0 {
				least, middle, per_second, measured := call_measure(&machine.client, step.text, step.repeat)
				if !measured {
					fmt.eprintfln("kerneltool: test failed: step %d: the measure of %s had a call with no answer", index + 1, step.text)
					return false
				}
				test_passed_print("the call %s from the host: the round trip %d us at least, %d us in the middle, over %d calls; %d calls in one second, one after the other", step.text, i64(least / time.Microsecond), i64(middle / time.Microsecond), step.repeat, per_second)
			}
		case .Remember:
			if !log_wait(machine, step.text, false) {
				fmt.eprintfln("kerneltool: test failed: step %d: the machine did not print \"%s\"", index + 1, step.text)
				return false
			}
			log := log_read(machine)
			rest := log[machine.seen:]
			line := strings.trim_right(rest[:max(strings.index_byte(rest, '\n'), 0)], "\r")
			append(&remembered_values, strings.clone(line))
			fmt.printfln("kerneltool: the machine drew \"%s\" after \"%s\"", line, step.text)
		case .Distinct:
			for value, first in remembered_values {
				for other in remembered_values[first + 1:] {
					if value == other {
						fmt.eprintfln("kerneltool: test failed: step %d: %s: the value \"%s\" came two times", index + 1, step.text, value)
						return false
					}
				}
			}
			test_passed_print("%s: %d values, each different", step.text, len(remembered_values))
		case .Quic_Key:
			if !log_wait(machine, step.text, false) {
				fmt.eprintfln("kerneltool: test failed: step %d: the machine did not print \"%s\"", index + 1, step.text)
				return false
			}
			log := log_read(machine)
			rest := log[machine.seen:]
			line := strings.trim_right(rest[:max(strings.index_byte(rest, '\n'), 0)], "\r")
			if !peer_quic_pin(machine.peer, line) {
				fmt.eprintfln("kerneltool: test failed: step %d: \"%s\" is not a public key of 64 hexadecimal digits", index + 1, line)
				return false
			}
			fmt.printfln("kerneltool: the QUIC client of the peer pins the key %s", line)
		case .Remote_Key:
			if !log_wait(machine, step.text, false) {
				fmt.eprintfln("kerneltool: test failed: step %d: the machine did not print \"%s\"", index + 1, step.text)
				return false
			}
			log := log_read(machine)
			rest := log[machine.seen:]
			line := strings.trim_right(rest[:max(strings.index_byte(rest, '\n'), 0)], "\r")
			if !peer_remote_pin_text(machine.peer.remote, line) {
				fmt.eprintfln("kerneltool: test failed: step %d: \"%s\" is not a public key of 64 hexadecimal digits", index + 1, line)
				return false
			}
			fmt.printfln("kerneltool: the QUIC client of remote in the peer pins the key %s", line)
		case .Remote_Case:
			if !machine.client_open {
				if !call_client_open(&machine.client, machine.call_socket) {
					return false
				}
				machine.client_open = true
			}
			passed, result := remote_case_run(machine, step.text)
			if !passed {
				fmt.eprintfln("kerneltool: test failed: step %d: the case \"%s\" of remote: %s", index + 1, step.text, result)
				return false
			}
			test_passed_print("the case \"%s\" of remote: %s", step.text, result)
		case .Openssl_Quic:
			if !openssl_quic_run(machine, step.text) {
				fmt.eprintfln("kerneltool: test failed: step %d: the QUIC client of OpenSSL", index + 1)
				return false
			}
		case .Peer_Quic:
			passed, result := peer_quic_case(machine.peer, step.text)
			// The last counts of the server that the log has, for the
			// message: quic_echo writes them once in a second when they
			// change, so they can be older than the case. No step reads them
			// here: a step Wait reads a count that the scenario needs. No
			// time passes between two cases: a case that needs the budgets
			// of the server to be full again waits for that itself
			// (peer_quic.odin, peer_quic_connect_again).
			counts := log_last_line(machine, "quic_echo: accepted ")
			if !passed {
				fmt.eprintfln("kerneltool: test failed: step %d: the QUIC case \"%s\" of the peer: %s; the last counts of the server in the log: %s", index + 1, step.text, result, counts)
				return false
			}
			test_passed_print("the QUIC case \"%s\" of the peer: %s; the last counts of the server in the log: %s", step.text, result, counts)
		case .Peer_Start:
			peer_case_started = peer_case_start_from_the_tool(machine.peer, step.text)
			fmt.printfln("kerneltool: the TCP case \"%s\" of the peer runs; the next steps run with it", step.text)
		case .Peer_Mark:
			peer_case_mark(machine.peer, peer_case_started)
			fmt.printfln("kerneltool: the TCP case \"%s\" of the peer is marked: the next step acts", step.text)
		case .Peer_Result:
			passed, result := peer_case_result(machine.peer, peer_case_started)
			if !passed {
				fmt.eprintfln("kerneltool: test failed: step %d: the TCP case \"%s\" of the peer: %s", index + 1, step.text, result)
				return false
			}
			test_passed_print("the TCP case \"%s\" of the peer: %s", step.text, result)
		case .Peer:
			passed, result := peer_case(machine.peer, step.text)
			if !passed {
				fmt.eprintfln("kerneltool: test failed: step %d: the TCP case \"%s\" of the peer: %s", index + 1, step.text, result)
				return false
			}
			test_passed_print("the TCP case \"%s\" of the peer: %s", step.text, result)
		case .Fetch:
			if !forward_fetch(machine.forward, step.text) {
				return false
			}
		case .Http:
			if !http_case_run(machine.forward, step.text, step.expected) {
				fmt.eprintfln("kerneltool: test failed: step %d: the HTTP case \"%s\"", index + 1, step.text)
				return false
			}
		case .Quit:
			monitor_send(machine, "quit")
		case .Monitor:
			monitor_send(machine, step.text)
		case .Power_Loss:
			server := machine.disk_server
			if server == nil {
				fmt.eprintfln("kerneltool: test failed: step %d: the tool does not serve the data disk", index + 1)
				return false
			}
			generator := rand.create_u64(POWER_LOSS_SEED)
			after := 1 + rand.int_max(40, rand.default_random_generator(&generator))
			sync.mutex_lock(&server.lock)
			server.power_off_after_write = server.writes + after
			sync.mutex_unlock(&server.lock)
			for start := time.now(); !sync.atomic_load(&server.powered_off) && time.since(start) < HANG_BOUND; {
				time.sleep(time.Millisecond)
			}
			// A kill: QEMU writes nothing more. The tool knows what was
			// durable when the disk lost its power.
			_ = os.process_kill(machine.process)
			machine.powered_off = true
			if !sync.atomic_load(&server.powered_off) {
				fmt.eprintfln("kerneltool: test failed: step %d: the machine made no write for %d writes", index + 1, after)
				return false
			}
			fmt.printfln("kerneltool: the power of the disk went off at its write %d, the write of a root, %d writes or more after the step before (seed %d)", server.writes, after, POWER_LOSS_SEED)
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

// The windows that the interface package draws (docs/INTERFACE.md, "State
// of the conversions"), for `kerneltool measure windows`. often: the program
// draws a picture each second or more, so the log has the mean of 10.
@(rodata)
measured_windows := [?]struct {
	name:  string,
	often: bool,
} {
	{"clock", true},
	{"life", true},
	{"monitor", true},
	{"inspect", true},
	{"scheduler", true},
	{"locks", false},
	{"budget", false},
	{"rights", false},
	{"origin", false},
	{"limits", false},
	{"frames", false},
	{"imports", false},
	{"flow", false},
	{"crowd", false},
	{"tally", false},
	{"manual", false},
	{"errors", false},
	{"interface_elements", true},
}

TEST_OUTPUT_MEASURE_WINDOWS :: BUILD_FOLDER + "/test_output_measure_windows.txt"

// measure_windows starts each window of measured_windows alone, waits for
// the time of its pictures, closes it, then prints one table. A measure is
// valid when the load of the host is under 8: the table says the load.
measure_windows :: proc() -> bool {
	// Not in the temporary allocator: the scenario frees it after each step.
	steps := make([dynamic]Step)
	defer delete(steps)
	texts := make([dynamic]string)
	defer {
		for text in texts {
			delete(text)
		}
		delete(texts)
	}
	append(&steps, Step{kind = .Wait, text = "compositor: surface console"})
	for window in measured_windows {
		append(&steps, Step{kind = .Launch, text = window.name})
		drew := strings.concatenate({"display: ", window.name, " drew one picture in "})
		stopped := strings.concatenate({"root: ", window.name, " stopped"})
		append(&texts, drew, stopped)
		append(&steps, Step{kind = .Wait, text = drew})
		if window.often {
			append(&steps, Step{kind = .Wait, text = " the mean of 10"})
		}
		append(&steps, Step{kind = .Close, text = window.name})
		append(&steps, Step{kind = .Wait, text = stopped})
	}
	append(&steps, Step{kind = .Front, text = "console"}, Step{kind = .Type, text = "shutdown()"}, Step{kind = .Wait, text = "kernel: the machine stops with code 0"})
	// A copy outside the temporary allocator: the scenario frees it.
	load_before := strings.clone(load_of_the_host())
	defer delete(load_before)
	if !machine_test(steps[:], BOOT_VOLUME_MEASURE, TEST_OUTPUT_MEASURE_WINDOWS, MACHINE_STOP_OK, TEST_DATA_DISK) {
		return false
	}
	load_after := load_of_the_host()
	log, _ := os.read_entire_file(TEST_OUTPUT_MEASURE_WINDOWS, context.temp_allocator)
	highest := max(strconv.parse_f64(load_before) or_else 99, strconv.parse_f64(load_after) or_else 99)
	fmt.printfln("kerneltool: the time of one picture of each window, us (the load of the host: %s at the start, %s at the end%s)", load_before, load_after, highest <= 8 ? "" : "; ABOVE 8: NOT VALID")
	fmt.printfln("%-20s %12s %12s %12s", "window", "first", "mean of 3", "mean of 10")
	for window in measured_windows {
		mark := strings.concatenate({"display: ", window.name, " drew one picture in "}, context.temp_allocator)
		values: [3]string = {"-", "-", "-"}
		for line in strings.split_lines(string(log), context.temp_allocator) {
			at := strings.index(line, mark)
			if at < 0 {
				continue
			}
			rest := line[at + len(mark):]
			value := rest[:max(strings.index(rest, " us"), 0)]
			switch {
			case strings.has_suffix(strings.trim_space(line), "the mean of 1"):
				values[0] = value
			case strings.has_suffix(strings.trim_space(line), "the mean of 3"):
				values[1] = value
			case strings.has_suffix(strings.trim_space(line), "the mean of 10"):
				values[2] = value
			}
		}
		fmt.printfln("%-20s %12s %12s %12s", window.name, values[0], values[1], values[2])
	}
	return true
}

// load_of_the_host gives the load of the host over one minute, from /proc/loadavg.
load_of_the_host :: proc() -> string {
	text, err := os.read_entire_file("/proc/loadavg", context.temp_allocator)
	if err != nil {
		return "unknown"
	}
	return string(text[:max(strings.index_byte(string(text), ' '), 0)])
}
