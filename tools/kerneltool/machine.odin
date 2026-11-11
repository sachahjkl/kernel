package kerneltool

import "contract:store"
import "support:bar"
import "core:fmt"
import "core:hash"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
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
// The bound of the first Wait of each machine: its boot ("compositor:
// surface console" and its like). A boot that is slow under the load of the
// host says nothing about the system; a later step that is slow does, so it
// keeps STEP_TIMEOUT (owner, 2026-11-11: a boot timed out at a host load of
// 62 while eight agents ran on the computer).
BOOT_WAIT_TIMEOUT :: 180 * time.Second
KEY_PAUSE :: 45 * time.Millisecond
MOUSE_PAUSE :: 25 * time.Millisecond
MOUSE_STEP :: 40
// The exit status of QEMU when the kernel stops the machine with code 0.
MACHINE_STOP_OK :: 1

Step_Kind :: enum {
	Wait, // The log of the kernel has text, after the text of the last Wait.
	Date, // As Wait; then the number after text is a date of the machine in seconds since 1970, and the host time must be within DATE_TOLERANCE_SECONDS of it.
	Type, // Press the keys of text, then Enter.
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
	Trace, // The log has text, after the text of the last Wait, then a stack trace to the end of the line: the tool names each frame from the linked file of its module, and the names start with `names`.
	Record, // A log record with the program `program`, the channel `channel`, the level `level` and a text that has `text`, after the record of the last Record step: the tool reads log.records() through the remote service (call.odin). With any_order, the next Record step searches from the same place.
	Agree, // The program `text`: the mapped pages and the threads that inspect.mappings() and inspect.threads() give are the ones that monitor.programs() gives (two tools, two reports of the kernel).
	Power_Loss, // The disk that the tool serves loses its power at the first write of a root after a seeded count of writes (1 to 40 after this step): it answers nothing more, and the tool ends QEMU with no warning (power_loss.odin).
	Call, // Call an export of a service from the host (call.odin), through the remote service: what the tool prints has `expected`. With `rows_call`, that call gives the count of rows of the Table. With `repeat`, the tool also measures the round trip and the calls in one second.
	Peer, // The peer runs the TCP case text (peer_tcp.odin) and checks its answers.
	Point, // Move the pointer to (x, y) with no press, then read compositor.pointer(): its shape must be the name text (docs/POINTERS.md). With inside_window, (x, y) are from the corner of that window, its title bar included; a negative x is from its right side. It needs the confirmation of the pointer (a Call with pointer before it).
	Remember, // The rest of the line after the text, in the log after the last Wait, is kept for the step Distinct (a value that the machine drew).
	Distinct, // Each value that Remember kept in this test part differs from each other one; text names them.
	Peer_Start, // The peer starts the TCP case text; the next steps run while it runs.
	Peer_Result, // The end of the case of the last Peer_Start: it must pass. text is its name.
	Fetch, // The TCP of the host fetches the page text of `server` through QEMU user networking (web_host.odin).
	Http, // The TCP of the host runs the HTTP case text against `server` (web_host.odin, http_case_run); `expected` is the body that a page must have.
}

Step :: struct {
	kind:       Step_Kind,
	text:       string,
	x, y:       int,
	to_x, to_y: int,
	// For Wait: the next Wait searches from the same place. Use it when two
	// programs print in an order that the system does not fix.
	any_order:  bool,
	names:      string, // For Trace: the names of the functions of the first frames, separated by spaces.
	expected:   string, // For Call: a part of what the tool prints.
	outcome:    Call_Outcome, // For Call: Result, Failed or Refused.
	rows_call:  string, // For Call: a call whose Integer result is the count of rows of the Table.
	lose:       int, // For Call: the peer drops this many datagrams of the answer; the tool sends the request again, and monitor.served() shows that the call ran one time.
	wrong_hash: bool, // For Call: the request names another hash of the module.
	program:    string, // For Record: the program that wrote the record.
	channel:    string, // For Record: its channel ("" for none).
	level:      string, // For Record: info, debug, warning or error.
	pointer:    bool, // For Call: when the call has its result, the tool confirms each place of the pointer from now on (pointer_confirm).
	repeat:     int, // For Call: the calls of the measure of the round trip.
	parts:      int, // For Call: the least count of datagrams of the answer.
	inside_window: string, // For Click: (x, y) are inside the surface of the window with this title, as the log of the compositor places it. For Point: from the corner of the window.
	date_after: string, // For Call: the number after this text in what the tool prints is a date of the machine in milliseconds since 1970: it must be within DATE_TOLERANCE_SECONDS of the host time.
}

DATE_TOLERANCE_SECONDS :: 5

// date_check compares a date of the machine, in seconds since 1970, with
// the time of the host. QEMU gives the machine the clock of the host as its
// real-time clock (-rtc base=utc).
date_check :: proc(index: int, machine_seconds: i64, what: string) -> bool {
	host := time.time_to_unix(time.now())
	apart := abs(host - machine_seconds)
	if apart > DATE_TOLERANCE_SECONDS {
		fmt.eprintfln("kerneltool: test failed: step %d: the date of the machine (%s) is %d, the host gives %d: %d s apart", index + 1, what, machine_seconds, host, apart)
		return false
	}
	fmt.printfln("kerneltool: test passed: the date of the machine (%s) is %d s since 1970, the host gives %d: %d s apart", what, machine_seconds, host, apart)
	return true
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
scenario_fails := [?]Step {
	{kind = .Wait, text = "boot program: ok"},
	{kind = .Wait, text = "kernel: ok"},
	{kind = .Wait, text = "root: ok"},
	{kind = .Wait, text = "root: cannot start the compositor: status "},
	{kind = .Wait, text = "root: the boot display shows the failure"},
	{kind = .Shot, text = "boot_fails"},
	{kind = .Quit},
}

// Persistence: three machines with one data disk. The first one starts
// from a new disk: the person types a note in `notes` and counts 1000 (1000
// commits), then stops the machine. The second one finds the note and the
// count; the person counts again, and the tool ends QEMU in the middle of
// the commits, with no stop of the machine. The third one finds a store
// that the checks accept, and a count of one commit: its three blocks agree.
scenario_persist_first := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "root: started storage"},
	{kind = .Wait, text = "storage: ok, a new disk: generation 1, 16384 blocks", any_order = true},
	{kind = .Wait, text = "root: started notes"},
	{kind = .Wait, text = "notes: a new store: no note, the count 0", any_order = true},
	{kind = .Wait, text = "compositor: surface notes"},
	{kind = .Type, text = "kept across a restart"},
	{kind = .Wait, text = "notes: the note is \"kept across a restart\", generation 22"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "notes: count 1000, stopped: 1000 commits in "},
	{kind = .Wait, text = "notes: the versions of the count: 1000 rows in "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

scenario_persist_second := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "storage: ok, generation 1022: 1 stores, 2 objects, ", any_order = true},
	{kind = .Wait, text = " blocks checked, 0 wrong, in ", any_order = true},
	{kind = .Wait, text = "notes: restored the note \"kept across a restart\" and the count 1000, its 3 blocks agree", any_order = true},
	{kind = .Wait, text = "compositor: surface notes"},
	{kind = .Shot, text = "notes"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "notes: count 1100"},
	{kind = .Quit}, // In the middle of the commits: the machine does not stop.
}

scenario_persist_crash := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
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
	{kind = .Wait, text = "compositor: surface console"},
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
	{kind = .Wait, text = "compositor: surface console"},
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
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "storage: the newest root names a block with a wrong check, and the root before it names none: the root before it is used", any_order = true},
	{kind = .Wait, text = " blocks checked, 0 wrong, in ", any_order = true},
	{kind = .Wait, text = "notes: restored the note \"agai\" and the count ", any_order = true},
	{kind = .Quit},
}

// A format that a stop cut: a first root with a wrong check, and no commit
// after it. The disk holds no object: the storage service formats again.
scenario_persist_first_cut := [?]Step {
	{kind = .Wait, text = "compositor: surface console"},
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
	{kind = .Wait, text = "compositor: surface console"},
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
// case, then the measures. The person revokes the grant of the network:
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
	{kind = .Wait, text = "network: the headers and the checksum of a datagram of 1472 bytes: ", any_order = true},
	{kind = .Wait, text = "network: an endpoint for net: the local port 49152, the grant 10.0.2.2 port 7", any_order = true},
	{kind = .Wait, text = "root: started net"},
	{kind = .Wait, text = "net: the link and the address: 10.0.2.15/24, the link is up, 52:54:00:12:34:56"},
	{kind = .Wait, text = "net: ARP: who has 10.0.2.2: the gateway answered 52:55:0a:00:02:02 in "},
	{kind = .Wait, text = "net: ICMP echo to 10.0.2.2, 56 bytes: the echo reply came in "},
	{kind = .Wait, text = "net: UDP to 10.0.2.2 port 7, 41 bytes: the same 41 bytes came back from 10.0.2.2 port 7 in "},
	{kind = .Wait, text = "net: UDP to 10.0.2.2 port 9: refused: datagram.Send: the argument address, 10.0.2.2 port 9, is refused: the grant names 10.0.2.2 port 7 only"},
	{kind = .Wait, text = "net: ICMP echo to 10.0.2.3: refused: datagram.Echo: the argument address, 10.0.2.3, is refused: the grant names 10.0.2.2 port 7 only"},
	{kind = .Wait, text = "net: UDP of 2000 bytes: refused, no fragment: datagram.Send: the argument count has 2000 bytes; it can have at most 1472 bytes"},
	// The row of the endpoint names its own grant; the rows of the machine
	// need the right Inspect, that `net` has with the machine.
	{kind = .Wait, text = "net: refused for this endpoint: 1 x udp, byte 34: the remote port 9 is not the port of the grant, 7"},
	{kind = .Wait, text = "net: refused for the machine: 1 x udp, byte 40: the checksum is 0x"},
	{kind = .Wait, text = "net: UDP from 10.0.2.2 port 9 to this endpoint: refused: from port 9; a row of this endpoint"},
	{kind = .Wait, text = "net: malformed frames from the wire: 10 refused in 10 kinds, 10 of 10 expected; no fault"},
	{kind = .Wait, text = "net: ICMP echo from 10.0.2.2 to this machine: the network service answered 1 request"},
	{kind = .Wait, text = "net: ok, 10 cases"},
	{kind = .Wait, text = "net: the round trip of one datagram of 64 bytes: "},
	{kind = .Wait, text = "net: a burst with 64 datagrams in flight: "},
	{kind = .Wait, text = " datagrams in one second, sent and answered, 0 lost"},
	{kind = .Wait, text = "net: kernel entries for each datagram: "},
	{kind = .Wait, text = "net: the measures are done"},
	{kind = .Shot, text = "network"},
	// The grant is a record of the root service: the person sees it and
	// revokes it. The network service ends the grant of the endpoint.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "grants(\"net\")"},
	{kind = .Wait, text = "[console] net has: log, machine, network"},
	{kind = .Type, text = "revoke(\"net\", \"network\")"},
	{kind = .Wait, text = "root: revoked the grant network of net, endpoints changed: 1", any_order = true}, // The network service can write its line first.
	{kind = .Wait, text = "network: the grant of the endpoint of net changed: none"},
	{kind = .Front, text = "net"},
	{kind = .Key, text = "spc"},
	{kind = .Wait, text = "net: a datagram to 10.0.2.2 port 7 after a key: refused, the endpoint has no grant now: datagram.Send: the argument address, 10.0.2.2 port 7, is refused: the grant names no remote"},
	{kind = .Close, text = "net"},
	{kind = .Wait, text = "root: net stopped with code 0"},
	{kind = .Wait, text = "network: the endpoint of net ended: "},
	// The calls of the host (docs/MODULE_CONTRACT.md, "A call from the
	// host"). The remote service holds an endpoint whose grant names the
	// host, and connects to the services that the root service names for it.
	{kind = .Launch, text = "monitor"},
	{kind = .Wait, text = "compositor: surface monitor"},
	{kind = .Launch, text = "manual"},
	{kind = .Wait, text = "compositor: surface manual"},
	{kind = .Launch, text = "remote"},
	{kind = .Wait, text = "root: started remote"},
	{kind = .Wait, text = "remote: ok, an endpoint with the grant 10.0.2.2 port 7100; the call requests of the host arrive there", any_order = true},
	// The peer sends six malformed call requests when the remote service
	// starts: each one has its error record, and no call runs.
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
	// A lost datagram: the tool sends the request again, and the remote
	// service sends the answer that it kept; the call runs one time.
	{kind = .Call, text = "monitor.count(\"processors\")", expected = "4", lose = 1},
	{kind = .Wait, text = "remote: the request "},
	{kind = .Wait, text = " came again: its answer went again, and the call did not run again; 1 in all"},
	// Another module than the one that runs: the remote service refuses it,
	// and the tool names the two hashes.
	{kind = .Call, text = "monitor.count(\"processors\")", outcome = .Refused, wrong_hash = true, expected = "the request named "},
	{kind = .Wait, text = "remote: refused a request: remote: the argument hash has the value 0, which the call refuses"},
	{kind = .Call, text = "monitor.counts()", expected = "15 rows of Count"},
	// A Record: the counts of the monitor itself, which each caller sees.
	{kind = .Call, text = "monitor.served()", expected = "Served{calls = "},
	// A result larger than one datagram.
	{kind = .Call, text = "manual.modules()", expected = " rows of Module", parts = 2},
	{kind = .Call, text = "manual.running()", expected = " rows of Running"},
	// A Text, from a service that starts at the first connection.
	{kind = .Call, text = "storage.stores()", expected = " blocks in use"},
	// Failures: the sentence of the error record of the service.
	{kind = .Call, text = "monitor.count(\"nothing\")", outcome = .Failed, expected = "error: monitor.count: the argument name names nothing that exists (-3)"},
	{kind = .Call, text = "storage.size(\"note\")", outcome = .Failed, expected = "error: storage.size: the caller has no grant for this: a private store (-1)"},
	{kind = .Call, text = "manual.exports(\"nothing\")", outcome = .Failed, expected = "error: manual.exports: the argument name names none of the modules (-1)"},
	// The tool checks the arguments against the description before it sends.
	{kind = .Call, text = "monitor.count(4)", outcome = .Wrong, expected = "error: the parameter name of monitor.count is a Text, the argument is an Integer"},
	// The person sees the grant, and revokes it: the services refuse what
	// they give only to a caller that acts for the person.
	// The developer tool serves its tables to a caller that acts for the
	// person: the remote service, until the revocation below.
	{kind = .Launch, text = "inspect"},
	{kind = .Wait, text = "inspect: ok, "},
	{kind = .Call, text = "inspect.mappings(\"remote\")", expected = " rows of Mapping"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "grants(\"remote\")"},
	{kind = .Wait, text = "[console] remote has: log, network, person"},
	{kind = .Type, text = "revoke(\"remote\", \"person\")"},
	{kind = .Wait, text = "root: revoked the grant person of remote, connections changed: 5"},
	{kind = .Call, text = "inspect.mappings(\"remote\")", outcome = .Failed, expected = "error: inspect.mappings: the caller has no grant for this: to act for the person (-1)"},
	{kind = .Call, text = "inspect.threads(\"remote\")", outcome = .Failed, expected = "error: inspect.threads: the caller has no grant for this: to act for the person (-1)"},
	{kind = .Call, text = "inspect.modules(\"remote\")", outcome = .Failed, expected = "error: inspect.modules: the caller has no grant for this: to act for the person (-1)"},
	{kind = .Call, text = "monitor.programs()", outcome = .Failed, expected = "error: monitor.programs: the caller has no grant for this: to act for the person (-1)"},
	// The place of the pointer is a fact of the screen of the person: the
	// tool moves the pointer with no confirmation again.
	{kind = .Call, text = "compositor.pointer()", outcome = .Failed, pointer = true, expected = "error: compositor.pointer: the caller has no grant for this: to act for the person (-1)"},
	// The window of inspect covers the windows under it: it closes now.
	{kind = .Close, text = "inspect"},
	{kind = .Wait, text = "root: inspect stopped with code 0"},
	{kind = .Call, text = "manual.running()", outcome = .Failed, expected = "error: manual.running: the caller has no grant for this: to act for the person (-3)"},
	{kind = .Call, text = "storage.stores()", expected = "no grant to see the stores"},
	{kind = .Call, text = "manual.modules()", expected = " rows of Module"},
	{kind = .Call, text = "monitor.served()", expected = "Served{calls = "},
	{kind = .Front, text = "remote"},
	{kind = .Shot, text = "remote"},
	// The desktop: the person closes remote and manual, the launcher starts
	// two programs, and the person places four windows. The title bar of
	// the window in front goes from blue to a darker blue; the other title
	// bars are quiet.
	{kind = .Close, text = "remote"},
	{kind = .Wait, text = "root: remote stopped"},
	{kind = .Close, text = "manual"},
	{kind = .Wait, text = "root: manual stopped"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the launcher is open"},
	{kind = .Keys, text = "lif"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the launcher starts life"},
	{kind = .Wait, text = "compositor: surface life"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the launcher is open"},
	{kind = .Keys, text = "pla"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the launcher starts plasma"},
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
	// The list narrows at each key: the names that start with the typed
	// part come first. The arrows move the choice.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the launcher is open"},
	{kind = .Keys, text = "p"},
	{kind = .Wait, text = " for \"p\": pages, plasma, paint, processors, "},
	{kind = .Key, text = "down"},
	{kind = .Wait, text = "compositor: the launcher chooses plasma"},
	{kind = .Shot, text = "launcher"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the launcher is closed by the key escape"},
	// A part that no name has: the list is empty, and Enter starts nothing.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the launcher is open"},
	{kind = .Keys, text = "xyz"},
	{kind = .Wait, text = "compositor: the launcher lists 0 of "},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the launcher has no program to start"},
	{kind = .Shot, text = "launcher_empty"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the launcher is closed by the key super"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "memory()"},
	{kind = .Wait, text = " pages: all the free pages"},
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
		table: store.Table
		disk_block(file, entry.table.block, &table) or_return
		for &object in table.objects {
			if name_of(object.name[:]) != object_name || object.list.block == 0 {
				continue
			}
			list: store.List
			disk_block(file, object.list.block, &list) or_return
			number := list.data[0].block
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

// The positions below come from programs/compositor/main.odin: the launcher
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
	// The launcher: the key super opens it, the typed part narrows the
	// list, and Enter starts the chosen program.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the launcher is open"},
	{kind = .Keys, text = "pla"},
	{kind = .Wait, text = "compositor: the launcher lists 1 of "},
	{kind = .Wait, text = " for \"pla\": plasma"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the launcher starts plasma"},
	{kind = .Wait, text = "plasma: ok", any_order = true},
	{kind = .Wait, text = "compositor: surface plasma"},
	{kind = .Move, text = "plasma", to_x = 232, to_y = 144},
	{kind = .Shot, text = "desktop_moved"},
	// The menu of the programs: the button of the bar opens and closes it.
	{kind = .Click, x = 116, y = 14},
	{kind = .Shot, text = "menu"},
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
	{kind = .Close, text = "plasma"},
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
	{kind = .Wait, text = "[console] math: 8 commands"},
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
	{kind = .Type, text = "help()"},
	{kind = .Wait, text = "[console] shutdown()"},
	{kind = .Wait, text = "[console] number(text: Text) -> Integer"},
	{kind = .Shot, text = "tools"},

	// An isolated call: the module runs in a sandboxed program. The
	// arguments go through a ring. The description is the same.
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "isolate(\"probe\")"},
	{kind = .Wait, text = "[probe] host: ready, 7 exports"},
	{kind = .Wait, text = "[console] probe: 7 commands in a sandboxed program"},
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
	// The exports that are wrong on purpose are in a module of their own,
	// which no service holds.
	{kind = .Type, text = "isolate(\"hostile_exports\")"},
	{kind = .Wait, text = "[console] hostile_exports: 4 commands in a sandboxed program"},
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
	{kind = .Wait, text = "[console] error: the program hostile_exports stopped: page fault"},
	// The root service ends one grant of a program that runs. The window of
	// monitor goes below the console for the picture, then back.
	{kind = .Move, text = "monitor", to_x = 568, to_y = 552},
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
	{kind = .Wait, text = "[console] error: root.Revoke: the argument grant names none of the grants of the program"},
	{kind = .Type, text = "revoke(\"monitor\", \"keys\")"},
	{kind = .Wait, text = "[console] error: no grant has the name keys"},
	{kind = .Shot, text = "revocation"},
	{kind = .Move, text = "monitor", to_x = 568, to_y = 40},
	{kind = .Front, text = "console"},
	// The same descriptions serve a direct call. The module is then in the
	// console: it has the handles of the console, and kept gives 0.
	{kind = .Type, text = "unload(\"sample\")"},
	{kind = .Wait, text = "[console] sample: 10 commands removed, its sandboxed program stops"},
	{kind = .Type, text = "unload(\"hostile_exports\")"},
	{kind = .Wait, text = "[console] hostile_exports: 4 commands removed"},
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "load(\"sample\")"},
	{kind = .Wait, text = "[console] sample: 10 commands, hash"},
	{kind = .Type, text = "load(\"hostile_exports\")"},
	{kind = .Wait, text = "[console] hostile_exports: 4 commands, hash"},
	{kind = .Type, text = "g = grow(r, 5)"},
	{kind = .Type, text = "g.width * g.height + keep(b) + kept()"},
	{kind = .Wait, text = "[console] 12848"},
	{kind = .Type, text = "unload(\"sample\")"},
	{kind = .Wait, text = "[console] sample: 10 commands removed, the module left the memory of the console"},
	{kind = .Type, text = "unload(\"hostile_exports\")"},
	{kind = .Wait, text = "[console] hostile_exports: 4 commands removed, the module left the memory of the console"},
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
	{kind = .Wait, text = "remote: ok, an endpoint with the grant 10.0.2.2 port 7100; the call requests of the host arrive there", any_order = true},
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
	{kind = .Wait, text = "locks: kernel entries in one second, each locker on its own objects: "},
	{kind = .Wait, text = "locks: pages on first use in one second, each locker in its own memory: "},
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
	{kind = .Launch, text = "scheduler"},
	{kind = .Wait, text = "scheduler: round robin: two threads that wake each other, a spinner on each processor: "},
	{kind = .Wait, text = "scheduler: fair: two threads that wake each other, a spinner on each processor: "},
	{kind = .Wait, text = "scheduler: EEVDF: two threads that wake each other, a spinner on each processor: "},
	{kind = .Wait, text = "scheduler: one Strategy_Set, with its kernel entry: "},
	{kind = .Wait, text = "scheduler: stress: 100 changes of strategy while "},
	{kind = .Wait, text = "scheduler: ok, no spinner starved under 3 strategies, EEVDF woke "},
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
	{kind = .Wait, text = "address_space: large pages: one random read over 64 MiB: "},
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
	{kind = .Wait, text = "[console] paint: 4 commands of a service that runs"},
	{kind = .Type, text = "connect(\"life\")"},
	{kind = .Wait, text = "[console] life: 3 commands of a service that runs"},
	{kind = .Type, text = "connect(\"plasma\")"},
	{kind = .Wait, text = "error: cannot connect to plasma: root.Connect: the argument name names none of the services that run"},
	// The monitor serves its tables; its grant of the machine was revoked
	// above, so the kernel refuses its reports.
	{kind = .Type, text = "connect(\"monitor\")"},
	{kind = .Wait, text = "[console] monitor: 5 commands of a service that runs"},
	{kind = .Type, text = "monitor.count(\"processors\")"},
	{kind = .Wait, text = "[console] error: monitor.count: refused with the status "},
	{kind = .Type, text = "help()"},
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
	// The measures of the information functions: all the modules and all
	// their exports, and one reverse question.
	{kind = .Wait, text = "manual: information: ", any_order = true},
	{kind = .Wait, text = "manual: ok, "},
	{kind = .Move, text = "manual", to_x = 208, to_y = 744},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"manual\")"},
	{kind = .Wait, text = "[console] manual: 16 commands of a service that runs"},
	{kind = .Type, text = "manual.about(\"math\")"},
	{kind = .Wait, text = "[console] A module of commands (property 19)"},
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
	{kind = .Wait, text = "manual: manual: a program, 16 exports, "},
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
	{kind = .Wait, text = "[console] agenda: 3 commands, hash"},
	{kind = .Wait, text = "[console]   imports calendar "},
	// calendar has a fault: 2000 has 365 days, and February 28.
	{kind = .Type, text = "year_days(2000) + month_days(2, 2000)"},
	{kind = .Wait, text = "[console] 393"},
	// Each module one time: calendar is in the console as the import of agenda.
	{kind = .Type, text = "load(\"calendar\")"},
	{kind = .Wait, text = "[console] calendar: 1 commands, hash"},
	{kind = .Type, text = "unload(\"calendar\")"},
	{kind = .Wait, text = "[console] calendar: 1 commands removed, the module stays: a module of the console imports it"},
	{kind = .Type, text = "unload(\"agenda\")"},
	{kind = .Wait, text = "[console] agenda: 3 commands removed, the module left the memory of the console"},
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
	{kind = .Wait, text = "[console] calendar_fixed replaces calendar in the loads that follow"},
	{kind = .Type, text = "replace(\"calendar_fixed\", \"math\")"},
	{kind = .Wait, text = "[console] error: a chain of replacements is refused: calendar_fixed, math"},
	{kind = .Type, text = "replacements()"},
	{kind = .Wait, text = "...: replaced by calendar_fixed "},
	{kind = .Type, text = "load(\"agenda\")"},
	{kind = .Wait, text = "[console] agenda: 3 commands, hash"},
	{kind = .Wait, text = ": the loader gave calendar_fixed "},
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
	{kind = .Type, text = "programs()"},
	{kind = .Wait, text = " in place of calendar "},
	// A fault in the module of the replacement: the kernel names
	// calendar_fixed, not calendar.
	{kind = .Type, text = "unload(\"agenda\")"},
	{kind = .Type, text = "isolate(\"agenda\")"},
	{kind = .Wait, text = "[console] agenda: 3 commands in a sandboxed program"},
	{kind = .Wait, text = "[console]   with calendar_fixed "},
	{kind = .Type, text = "year_days(2000)"},
	{kind = .Wait, text = "[console] 366"},
	{kind = .Type, text = "month_days(13, 2000)"},
	{kind = .Wait, text = "kernel: program agenda stopped: invalid instruction"},
	{kind = .Wait, text = ", which replaces "},
	{kind = .Wait, text = "[console] error: the program agenda stopped: invalid instruction"},
	{kind = .Wait, text = "[console] error: the instruction is at offset "},
	{kind = .Wait, text = "... runs in place of calendar "},
	{kind = .Type, text = "replacements()"},
	{kind = .Wait, text = "...: replaced by calendar_fixed "},
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
	{kind = .Wait, text = "[console] agenda: 3 commands removed, its sandboxed program stops"},
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
	// An export that refuses: the console writes the sentence of its error
	// record from the description of the export.
	{kind = .Type, text = "load(\"tally\")"},
	{kind = .Wait, text = "[console] tally: 5 commands, hash"},
	{kind = .Type, text = "add(1, \"a note of forty bytes, four more than 36\")"},
	{kind = .Wait, text = "the argument note has 40 bytes; it can have at most 36 bytes"},
	{kind = .Type, text = "add(-6, \"below zero\")"},
	{kind = .Wait, text = "the argument amount has -6; it must have at least 0"},
	{kind = .Type, text = "unload(\"tally\")"},
	{kind = .Wait, text = "[console] tally: 5 commands removed, the module left the memory of the console"},
	{kind = .Launch, text = "paint"},
	{kind = .Wait, text = "compositor: surface paint"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "paint.line(0, 0, 10, 10, 9)"},
	{kind = .Wait, text = "error: paint.line: the argument color has the value 9, which the call refuses; it takes at most 5"},
	{kind = .Type, text = "stop(\"paint\")"},
	{kind = .Wait, text = "root: paint stopped"},
	// (After the check of the log: these lines do not push the boot
	// records out of the log.)
	{kind = .Type, text = "load(\"sample\")"},
	{kind = .Wait, text = "[console] sample: 10 commands, hash"},
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
	{kind = .Wait, text = "[console] sample: 10 commands removed, the module left the memory of the console"},
	// A table goes into an isolated call: the rows go into the call
	// region, and the rows of a Change table come back.
	{kind = .Type, text = "isolate(\"sample\")"},
	{kind = .Wait, text = "[console] sample: 10 commands in a sandboxed program"},
	{kind = .Type, text = "t = readings(4)"},
	{kind = .Type, text = "scale_values(t, 3)"},
	{kind = .Type, text = "sum_values(t)"},
	{kind = .Wait, text = "[console] 300"},
	{kind = .Type, text = "unload(\"sample\")"},
	{kind = .Wait, text = "[console] sample: 10 commands removed, its sandboxed program stops"},
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
	{kind = .Record, program = "disk", level = "info", text = "disk: ok, 5 measures, 0 errors, write then read back: 0 wrong"},
	{kind = .Wait, text = "disk: a read of 2 blocks from the last block: block.Read: the argument first reaches 8193 blocks, past the end: there are 8192 blocks"},
	{kind = .Shot, text = "disk"},
	// The client stops: its block service stops, and the device stops
	// using memory.
	{kind = .Close, text = "disk"},
	{kind = .Record, program = "root", channel = "programs", level = "info", text = "root: disk stopped with code 0"},
	{kind = .Record, program = "root", channel = "programs", level = "info", text = "root: block stopped with code 0"},
	// The storage service starts when a program asks for it, with the block
	// service of the data disk. The console has a private store of 4 blocks,
	// by its name; it acts for the person, so it also sees all the stores.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"storage\")"},
	{kind = .Record, program = "root", channel = "devices", level = "info", text = "root: started block for the device at the place 16 of the bus"},
	{kind = .Record, program = "root", channel = "programs", level = "info", text = "root: started storage"},
	{kind = .Record, program = "storage", level = "info", text = "storage: ok, a new disk: generation 1, 16384 blocks", any_order = true},
	{kind = .Record, program = "root", channel = "calls", level = "info", text = "root: connected console to the service storage"},
	{kind = .Type, text = "storage.write(\"greeting\", \"kept on the disk\")"},
	{kind = .Wait, text = "[console] 2"},
	{kind = .Type, text = "storage.read(\"greeting\")"},
	{kind = .Wait, text = "[console] kept on the disk"},
	// The limit of the store: one more object needs two more blocks.
	{kind = .Type, text = "storage.write(\"second\", \"one block more\")"},
	{kind = .Wait, text = "[console] error: storage.write: the call needs 5 blocks in all, with no earlier version kept; the limit is 4 blocks (-2)"},
	// A change of the object at the limit: the version of its state before
	// does not fit, and the same commit thins it.
	{kind = .Type, text = "storage.write(\"greeting\", \"changed at the limit\")"},
	{kind = .Wait, text = "[console] 3"},
	{kind = .Record, program = "storage", level = "info", text = "storage: the store console is at its limit of 4 blocks: the commit of generation 3 thinned 1 version, the oldest of the store first", any_order = true},
	// An error of a service is a record: the console writes it as a sentence.
	{kind = .Type, text = "storage.write(\"\", \"x\")"},
	{kind = .Wait, text = "[console] error: storage.write: the argument name is empty; it must have 1 to 39 bytes (-3)"},
	{kind = .Type, text = "storage.read(\"nothing\")"},
	{kind = .Wait, text = "[console] error: storage.read: the argument name: the store has no object with this name (-7)"},
	{kind = .Type, text = "storage.objects()"},
	{kind = .Wait, text = "[console] greeting 20 bytes, generation 3"},
	{kind = .Type, text = "storage.stores()"},
	{kind = .Wait, text = "[console] console: 1 objects, 0 versions, 3 of 4 blocks, 0 shared, 1 connection"},
	// The person sees the grant and revokes it: the store stays on the disk,
	// and the console cannot reach it.
	{kind = .Type, text = "grants(\"console\")"},
	{kind = .Wait, text = "[console] console has: log, machine, image, store, person"},
	{kind = .Type, text = "revoke(\"console\", \"store\")"},
	{kind = .Record, program = "root", channel = "programs", level = "info", text = "root: revoked the grant store of console, connections changed: 1"},
	{kind = .Type, text = "storage.write(\"greeting\", \"changed\")"},
	{kind = .Wait, text = "[console] error: storage.write: the caller has no grant for this: a private store (-1)"},
	{kind = .Type, text = "storage.stores()"},
	{kind = .Wait, text = "[console] console: 1 objects, 0 versions, 3 of 4 blocks, 0 shared, 0 connections"},
	{kind = .Type, text = "grants(\"console\")"},
	{kind = .Wait, text = "[console] console lost: store"},
	{kind = .Shot, text = "storage"},
	// Versions: notes commits each key, and the storage service
	// keeps the state before each commit. The person steps back through the
	// versions of the note and restores one; nothing is lost.
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "notes: a new store: no note, the count 0", any_order = true},
	{kind = .Wait, text = "compositor: surface notes"},
	{kind = .Type, text = "versions"},
	{kind = .Wait, text = "notes: the note is \"versions\", generation 11, 7 versions; one commit of the note: "},
	{kind = .Key, text = "up"},
	{kind = .Wait, text = "notes: the version 7 of 8, generation 10, 20"}, // A version has the date of its commit.
	{kind = .Wait, text = ": \"version\""},
	{kind = .Key, text = "up"},
	{kind = .Wait, text = "notes: the version 6 of 8, generation 9, "},
	{kind = .Wait, text = ": \"versio\""},
	{kind = .Shot, text = "notes_versions"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "notes: restored the version of generation 9: \"versio\", in the commit of generation 12 in "},
	// The exports of the versions, from the host: the remote service acts
	// for the person, so it names the store of notes.
	{kind = .Call, text = "storage.versions(\"notes\", \"note\")", expected = "9 rows of Version"},
	// The date of the machine, from the host, some minutes after its start:
	// it advanced with the host.
	{kind = .Call, text = "date.now()", expected = "Date{milliseconds = ", date_after = "milliseconds = "},
	{kind = .Call, text = "storage.version(\"notes\", \"note\", 7)", expected = "vers"},
	{kind = .Call, text = "storage.compare(\"notes\", \"note\", 6, 11)", expected = "1 rows of Byte_Range"},
	{kind = .Call, text = "storage.version(\"notes\", \"note\", 99)", outcome = .Failed, expected = "error: storage.version: the argument generation: the object has no version of the generation 99 (-9)"},
	{kind = .Call, text = "storage.restore(\"notes\", \"note\", 11)", expected = "13"},
	{kind = .Call, text = "storage.clone(\"notes\", \"note\", \"copy\")", expected = "14"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "storage.stores()"},
	{kind = .Wait, text = "[console] notes: 2 objects, 9 versions, "},
	{kind = .Shot, text = "storage_versions"},
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
	{kind = .Wait, text = "errors: t the pages of another program (Inspect, Pages): Inspect: the argument index has the value 1, which the call refuses"},
	{kind = .Wait, text = "errors: u the pages past the end of the user half: Inspect: the argument address has the value 140737488351232, which the call refuses; it takes at most 140737488093184"},
	{kind = .Wait, text = "errors: v a wrapper: display.open of 0 by 100 pixels: display.open: the argument width has the value 0, which the call refuses; it takes at most 2048"},
	{kind = .Wait, text = "errors: w a wrapper: terminal.open with no terminal: terminal.open: the caller has no grant for this: a terminal"},
	{kind = .Wait, text = "errors: x a ring: root.Connect(\"storage\"), not callable: root.Connect: the caller has no grant for this: a connection to this service"},
	{kind = .Wait, text = "errors: y an export: tally.add, a note of 40 bytes: tally.add: the argument note has 40 bytes; it can have at most 36 bytes"},
	{kind = .Wait, text = "errors: ok, 25 cases, each with the expected error record"},
	{kind = .Wait, text = "errors: under contention: "},
	// A text longer than one row of log.records (160 bytes): its end is in
	// the next row, and the tool joins the rows.
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
	{kind = .Wait, text = "inspect: fault stopped: page fault at 0x0; stack: fault + "},
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
	// The vector font of the system (docs/FONTS.md): the six candidates,
	// each from a glyph cache that the program builds, beside Spleen 8x16.
	{kind = .Launch, text = "vector_glyphs"},
	{kind = .Wait, text = "vector_glyphs: one glyph from its outline, in fixed point"},
	{kind = .Wait, text = "vector_glyphs: ok, "},
	{kind = .Shot, text = "font_candidates"},
	{kind = .Close, text = "vector_glyphs"},
	{kind = .Wait, text = "root: vector_glyphs stopped"},
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
	{kind = .Wait, text = "compositor: the launcher is open"},
	{kind = .Point, x = 400, y = 260, text = "text"}, // The input line of the launcher.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the launcher is closed by the key super"},
	// The settings of the person: the font and the order of the stripes
	// change while the programs run; each window draws again, with no code
	// of its own for it.
	{kind = .Launch, text = "settings"},
	{kind = .Wait, text = "compositor: surface settings", any_order = true},
	{kind = .Wait, text = "settings: ok, font vector, subpixel order rgb"},
	{kind = .Move, text = "settings", to_x = 392, to_y = 40},
	{kind = .Front, text = "monitor"},
	{kind = .Move, text = "monitor", to_x = 8, to_y = 400},
	{kind = .Shot, text = "font_vector"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"settings\")"},
	{kind = .Wait, text = "[console] settings: 2 commands of a service that runs"},
	{kind = .Type, text = "settings.set(\"font\", \"spleen\")"},
	{kind = .Wait, text = "compositor: the settings changed: font spleen, subpixel order rgb; ", any_order = true},
	{kind = .Wait, text = "settings: drawn with the font spleen, subpixel order rgb"},
	{kind = .Front, text = "settings"},
	{kind = .Shot, text = "font_spleen"},
	{kind = .Call, text = "settings.get(\"font\")", expected = "spleen"},
	{kind = .Call, text = "settings.set(\"font\", \"vector\")", expected = "1"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb; "},
	{kind = .Call, text = "settings.set(\"subpixel_order\", \"bgr\")", expected = "1"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order bgr; "},
	{kind = .Call, text = "settings.get(\"subpixel_order\")", expected = "bgr"},
	{kind = .Call, text = "settings.set(\"font\", \"comic\")", outcome = .Failed, expected = "(-3)"},
	{kind = .Call, text = "settings.set(\"colour\", \"red\")", outcome = .Failed, expected = "(-2)"},
	{kind = .Call, text = "settings.set(\"subpixel_order\", \"rgb\")", expected = "1"},
	{kind = .Wait, text = "settings: drawn with the font vector, subpixel order rgb"},
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
	// Each page is free or paid, after all the starts and stops of this test.
	{kind = .Type, text = "memory()"},
	{kind = .Wait, text = " pages: all the free pages"},
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
	{kind = .Front, text = "console"},
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
	{kind = .Wait, text = "address_space: large pages: one random read over 64 MiB: "},
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
	{kind = .Wait, text = "scheduler: stress: 100 changes of strategy while "},
	{kind = .Wait, text = "scheduler: the window took "},
	{kind = .Front, text = "console"},
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
	call_port:   int, // The peer receives the call requests of the host there.
	peer:        ^Peer,
	confirm:     bool, // The tool reads compositor.pointer() before each press: see pointer_confirm.
	keys_confirmed: int, // Keys that the tool sent only after the compositor had the key before (key_send).
	confirmations: [dynamic]time.Duration, // The time of each confirmation of a place.
	corrected:   int, // The places that needed a correction.
	record_next: i64, // The number of the log record where the next Record step searches.
	powered_off: bool, // A step Power_Loss ended QEMU: the machine has no exit status.
	disk_server: ^Network_Block_Device, // The data disk, when the tool serves it.
	client:      Call_Client,
	client_open: bool,
	forward:     Forward, // QEMU user networking: the port of hostfwd and the listener of guestfwd.
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

// KEY_TAKEN_TIME: how long the tool waits for the machine to take one key.
KEY_TAKEN_TIME :: 20 * time.Second

// key_records_read gives the count of the key records that the compositor
// received, through the remote service.
key_records_read :: proc(machine: ^Machine) -> (count: i64, ok: bool) {
	values := record_fields(&machine.client, "compositor.pointer()", {"keys"}) or_return
	return values[0], true
}

// key_pause_without_confirmation gives the wait after a key when the tool
// cannot ask the compositor if the key arrived (a scenario with no remote).
// On a host with more runnable work than processors, the machine runs that
// much later: the wait grows with the load of the host for each processor,
// so that the machine reads each key before the next one fills its
// keyboard (measured at a load of 60 on 16 processors with the fixed wait:
// `connect("server")` arrived as `connect("`).
key_pause_without_confirmation :: proc() -> time.Duration {
	load, parsed := strconv.parse_f64(load_of_the_host())
	if !parsed {
		return KEY_PAUSE
	}
	late := max(load / f64(max(os.get_processor_core_count(), 1)), 1)
	return time.Duration(f64(KEY_PAUSE) * min(late * late, 40))
}

// key_send presses and releases one key of the QEMU monitor ("a",
// "shift-a", "ret"). When the tool can call the compositor (machine.confirm),
// it waits until the compositor received the records of that key: a press
// and a release for each part of the name. A loaded host runs the machine
// late: the keyboard of the machine holds few scancodes, and a key sent
// before the machine read the last ones is lost (measured: "start("fetch")"
// arrived as "start("ETCH")": the release of shift and the f were lost).
// With the wait, the tool never sends a key before the last one arrived.
// Before remote runs, the tool waits a fixed time, as before.
key_send :: proc(machine: ^Machine, name: string) -> bool {
	if !machine.confirm {
		monitor_send(machine, "sendkey ", name, " 20")
		time.sleep(key_pause_without_confirmation())
		return true
	}
	before, read := key_records_read(machine)
	if !read {
		// The person revoked the grant of remote, or remote stopped: the
		// wait with no confirmation.
		monitor_send(machine, "sendkey ", name, " 20")
		time.sleep(key_pause_without_confirmation())
		return true
	}
	wanted := before + 2 * i64(strings.count(name, "-") + 1)
	monitor_send(machine, "sendkey ", name, " 20")
	start := time.tick_now()
	for time.tick_since(start) < KEY_TAKEN_TIME {
		time.sleep(5 * time.Millisecond)
		now, ok := key_records_read(machine)
		if !ok {
			time.sleep(KEY_PAUSE)
			return true
		}
		if now >= wanted {
			machine.keys_confirmed += 1
			return true
		}
	}
	return false
}

// POINTER_TRIES: the reads of the place before the tool says that the
// pointer is not where a step wants it.
POINTER_TRIES :: 6

// pointer_confirm reads the place of the pointer from the compositor, through
// the remote service, and moves it again until it is (x, y): a loaded host
// can lose a move of the QEMU monitor, and the press then lands elsewhere.
// Before remote runs, the tool moves the pointer with no confirmation.
pointer_confirm :: proc(machine: ^Machine, x, y: int) -> bool {
	if !machine.confirm {
		return true
	}
	start := time.tick_now()
	found_x, found_y: i64
	for try in 0 ..< POINTER_TRIES {
		values, ok := record_fields(&machine.client, "compositor.pointer()", {"x", "y"})
		if ok {
			found_x, found_y = values[0], values[1]
			if found_x == i64(x) && found_y == i64(y) {
				machine.x, machine.y = x, y
				append(&machine.confirmations, time.tick_since(start))
				if try > 0 {
					machine.corrected += 1
				}
				return true
			}
			// The pointer is where the compositor says: move from there.
			machine.x, machine.y = int(found_x), int(found_y)
			pointer_move_blind(machine, x, y)
		}
		time.sleep(MOUSE_PAUSE)
	}
	fmt.eprintfln("kerneltool: test failed: the pointer is at %d,%d after %d tries, not at %d,%d", found_x, found_y, POINTER_TRIES, x, y)
	return false
}

// pointer_move moves the pointer to (x, y), and confirms the place when the
// tool can read it.
pointer_move :: proc(machine: ^Machine, x, y: int) -> bool {
	pointer_move_blind(machine, x, y)
	return pointer_confirm(machine, x, y)
}

// pointer_move_blind moves the pointer from the place that the tool
// believes, with relative moves of the QEMU monitor.
pointer_move_blind :: proc(machine: ^Machine, x, y: int) {
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
// compositor writes it when it makes the window, and when a person puts the
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
// itself. The tool reads it once it has the grant person (a step Call with
// pointer); before that step, the places come from the log.
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

log_wait :: proc(machine: ^Machine, text: string, any_order := false, limit := STEP_TIMEOUT) -> bool {
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
machine_test :: proc(steps: []Step, volume: string, output: string, exit_status: int, data_disk: string = TEST_DATA_DISK, user_network := false, disk_server: ^Network_Block_Device = nil, processor_without_random := false) -> bool {
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
	command, ok := machine_command(volume, output, data_disk, &peer, forward, processor_without_random)
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
		process   = process,
		monitor   = monitor_write,
		output    = output,
		call_port = peer.call_port,
		peer      = &peer,
		forward   = forward,
		disk_server = disk_server,
	}
	passed := scenario_run(&machine, steps)
	if len(machine.confirmations) > 0 {
		slice.sort(machine.confirmations[:])
		fmt.printfln("kerneltool: test passed: the tool confirmed %d places of the pointer through compositor.pointer(), %d after a correction; one confirmation took %d us at least, %d us in the middle", len(machine.confirmations), machine.corrected, i64(machine.confirmations[0] / time.Microsecond), i64(machine.confirmations[len(machine.confirmations) / 2] / time.Microsecond))
	}
	if machine.keys_confirmed > 0 {
		fmt.printfln("kerneltool: test passed: the tool sent %d keys, each one after the compositor had received the key before it", machine.keys_confirmed)
	}
	if machine.client_open {
		call_client_close(&machine.client)
	}
	state: os.Process_State
	if passed && machine.powered_off {
		state, _ = os.process_wait(process, STEP_TIMEOUT)
	} else if passed {
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
	peer_stop(&peer)
	if passed {
		passed = peer_check(&peer)
	}
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

// The values that the steps Remember kept, in one test part (several
// machines): the step Distinct compares them.
remembered_values: [dynamic]string

scenario_run :: proc(machine: ^Machine, steps: []Step) -> bool {
	peer_case_started := 0 // The number of the case of the last step Peer_Start.
	first_wait := true // The first Wait of the machine is its boot: BOOT_WAIT_TIMEOUT.
	for step, index in steps {
		switch step.kind {
		case .Wait:
			limit := first_wait ? BOOT_WAIT_TIMEOUT : STEP_TIMEOUT
			first_wait = false
			if !log_wait(machine, step.text, step.any_order, limit) {
				fmt.eprintfln("kerneltool: test failed: step %d: the machine did not print \"%s\"", index + 1, step.text)
				return false
			}
			fmt.printfln("kerneltool: test passed: the machine printed \"%s\"", step.text)
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
			date_check(index, value, step.text) or_return
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
			fmt.printfln("kerneltool: test passed: the stack trace after \"%s\" names the functions %s", step.text, found)
		case .Type, .Keys:
			for i in 0 ..< len(step.text) {
				name := key_name(step.text[i])
				if name == "" {
					fmt.eprintfln("kerneltool: step %d: no key for '%c'", index + 1, step.text[i])
					return false
				}
				if !key_send(machine, name) {
					fmt.eprintfln("kerneltool: test failed: step %d: the machine did not take the key %s of \"%s\"", index + 1, name, step.text)
					return false
				}
			}
			if step.kind == .Type {
				if !key_send(machine, "ret") {
					fmt.eprintfln("kerneltool: test failed: step %d: the machine did not take the key ret of \"%s\"", index + 1, step.text)
					return false
				}
			}
		case .Key:
			if !key_send(machine, step.text) {
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
			for start := time.now(); time.since(start) < STEP_TIMEOUT; {
				read, ok := record_text_field(&machine.client, "compositor.pointer()", "shape")
				if ok {
					shape = read
				}
				if shape == step.text {
					break
				}
				time.sleep(50 * time.Millisecond)
			}
			if shape != step.text {
				fmt.eprintfln("kerneltool: test failed: step %d: the pointer at %d,%d has the shape \"%s\", not \"%s\"", index + 1, x, y, shape, step.text)
				return false
			}
			fmt.printfln("kerneltool: test passed: the pointer at %d,%d has the shape %s", x, y, step.text)
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
				step.x, step.y, found = bar.center(step.text)
				if !found {
					fmt.eprintfln("error: the menu of the programs does not have the program %s", step.text)
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
				menu_x, menu_y := bar.button_center()
				if !pointer_move(machine, menu_x, menu_y) {
					fmt.eprintfln("kerneltool: test failed: step %d: the pointer did not reach its place", index + 1)
					return false
				}
				pointer_button(machine, true)
				pointer_button(machine, false)
				// The compositor writes that the menu is open: a press that
				// the machine did not receive is a failure of this step, with
				// its cause, and not of a later one.
				open := false
				for start := time.now(); !open && time.since(start) < STEP_TIMEOUT; {
					text := log_read(machine)
					if open = len(text) > before && strings.contains(text[before:], "compositor: the menu of the programs is open"); !open {
						time.sleep(50 * time.Millisecond)
					}
				}
				if !open {
					fmt.eprintfln("kerneltool: test failed: step %d: the menu of the programs did not open for %s: the machine did not receive the press on its button", index + 1, step.text)
					return false
				}
			}
			if step.kind == .Front {
				menu_x, menu_y := bar.windows_button_center()
				if !pointer_move(machine, menu_x, menu_y) {
					fmt.eprintfln("kerneltool: test failed: step %d: the pointer did not reach its place", index + 1)
					return false
				}
				pointer_button(machine, true)
				pointer_button(machine, false)
				line, found := windows_line(machine, step.text, before)
				if !found {
					fmt.eprintfln("kerneltool: test failed: step %d: the menu of the windows does not have %s", index + 1, step.text)
					return false
				}
				step.x, step.y = bar.windows_line_center(line)
			}
			if !pointer_move(machine, step.x, step.y) {
				fmt.eprintfln("kerneltool: test failed: step %d: the pointer did not reach its place", index + 1)
				return false
			}
			pointer_button(machine, true)
			if step.kind == .Drag {
				if !pointer_move(machine, step.to_x, step.to_y) {
					fmt.eprintfln("kerneltool: test failed: step %d: the pointer did not reach its place", index + 1)
					return false
				}
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
		case .Record:
			if !machine.client_open {
				if !call_client_open(&machine.client, machine.call_port) {
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
			for start := time.now(); !found && time.since(start) < STEP_TIMEOUT; {
				table, ok := table_call(&machine.client, fmt.tprintf("log.records(%d)", from))
				reads += 1
				rows := ok ? len(table.rows) / table.size : 0
				last_rows, last_total, last_ok = rows, table.total, ok
				last_table = table
				// A text goes on in the next row when its row says so
				// (log.records: a row has 160 bytes of text): the rows of one
				// text are joined before the comparison.
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
						fmt.printfln("kerneltool: test passed: the log record %d of %s, channel \"%s\", level %s, has \"%s\" (%d calls of log.records, %d rows)", number, step.program, step.channel, step.level, step.text, reads, last - row + 1)
						break
					}
					from = last_number + 1
					row = last + 1
				}
				if !found && rows == 0 {
					time.sleep(50 * time.Millisecond)
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
			// The program list of the monitor, and the reports of inspect.
			monitor, has_monitor := table_call(&machine.client, "monitor.programs()")
			mapped, threads_count := -1, -1
			if has_monitor {
				for row in 0 ..< len(monitor.rows) / monitor.size {
					if table_value(&monitor, row, "name") == step.text {
						mapped, _ = strconv.parse_int(table_value(&monitor, row, "mapped"))
						threads_count, _ = strconv.parse_int(table_value(&monitor, row, "threads"))
					}
				}
			}
			mappings, has_mappings := table_call(&machine.client, fmt.tprintf("inspect.mappings(%q)", step.text))
			threads, has_threads := table_call(&machine.client, fmt.tprintf("inspect.threads(%q)", step.text))
			pages := 0
			if has_mappings {
				for row in 0 ..< len(mappings.rows) / mappings.size {
					value, _ := strconv.parse_int(table_value(&mappings, row, "pages"))
					pages += value
				}
			}
			if !has_monitor || !has_mappings || !has_threads || mapped < 0 || pages != mapped || int(threads.total) != threads_count {
				fmt.eprintfln("kerneltool: test failed: step %d: %s: monitor.programs() gives %d mapped pages and %d threads, inspect gives %d pages in %d mappings and %d threads", index + 1, step.text, mapped, threads_count, pages, mappings.total, threads.total)
				return false
			}
			fmt.printfln("kerneltool: test passed: %s: inspect gives %d pages in %d mappings and %d threads, as monitor.programs() gives", step.text, pages, mappings.total, threads.total)
		case .Call:
			if !machine.client_open {
				if !call_client_open(&machine.client, machine.call_port) {
					return false
				}
				machine.client_open = true
			}
			served_before: i64
			if step.lose > 0 {
				before, has_before := record_field(&machine.client, "monitor.served()", "calls")
				if !has_before {
					fmt.eprintfln("kerneltool: test failed: step %d: monitor.served() gave no record", index + 1)
					return false
				}
				served_before = before
				sync.atomic_store(&machine.peer.lose, step.lose)
			}
			machine.client.wrong_hash = step.wrong_hash
			result := call_run(&machine.client, step.text)
			sends := machine.client.sends
			if step.pointer {
				// A result: the tool confirms each place from now on. A
				// refusal (the grant person was revoked): the blind way again.
				machine.confirm = result.outcome == .Result
				fmt.printfln("kerneltool: test passed: the tool %s the place of the pointer through compositor.pointer() from now on", machine.confirm ? "reads" : "no longer reads")
			}
			printed := strings.join(result.lines[:], "\n", context.temp_allocator)
			for line in result.lines {
				fmt.printfln("kerneltool: call %s: %s", step.text, line)
			}
			if result.outcome != step.outcome || !strings.contains(printed, step.expected) {
				fmt.eprintfln("kerneltool: test failed: step %d: the call %s gave %v, not %v with \"%s\"", index + 1, step.text, result.outcome, step.outcome, step.expected)
				return false
			}
			if result.datagrams < step.parts {
				fmt.eprintfln("kerneltool: test failed: step %d: the answer of %s came in %d datagrams, not %d or more", index + 1, step.text, result.datagrams, step.parts)
				return false
			}
			fmt.printfln("kerneltool: test passed: the call %s printed \"%s\", in %d datagrams", step.text, step.expected, result.datagrams)
			if step.date_after != "" {
				milliseconds, found := number_after(printed, step.date_after)
				if !found {
					fmt.eprintfln("kerneltool: test failed: step %d: no number after \"%s\" in the answer of %s", index + 1, step.date_after, step.text)
					return false
				}
				date_check(index, milliseconds / 1000, step.text) or_return
			}
			if step.lose > 0 {
				// The request went again; the service ran the call one time:
				// served() counts the call of the step and its own call before.
				after, has_after := record_field(&machine.client, "monitor.served()", "calls")
				if sends < 2 || !has_after || after - served_before != 2 {
					fmt.eprintfln("kerneltool: test failed: step %d: after %d lost datagrams the request went %d times, and the monitor ran %d calls, not 2", index + 1, step.lose, sends, after - served_before)
					return false
				}
				fmt.printfln("kerneltool: test passed: the peer dropped %d datagrams of the answer of %s; the tool sent the request %d times, and the monitor ran the call one time", step.lose, step.text, sends)
			}
			if step.rows_call != "" {
				// Another call gives the count of the rows.
				counted := call_run(&machine.client, step.rows_call)
				if counted.outcome != .Result || counted.value != i64(result.rows) {
					fmt.eprintfln("kerneltool: test failed: step %d: the call gave %d rows, %s gives %d", index + 1, result.rows, step.rows_call, counted.value)
					return false
				}
				fmt.printfln("kerneltool: test passed: the call gave %d rows, and %s gives %d", result.rows, step.rows_call, counted.value)
			}
			if step.repeat > 0 {
				least, middle, per_second, measured := call_measure(&machine.client, step.text, step.repeat)
				if !measured {
					fmt.eprintfln("kerneltool: test failed: step %d: the measure of %s had a call with no answer", index + 1, step.text)
					return false
				}
				fmt.printfln("kerneltool: test passed: the call %s from the host: the round trip %d us at least, %d us in the middle, over %d calls; %d calls in one second, one after the other", step.text, i64(least / time.Microsecond), i64(middle / time.Microsecond), step.repeat, per_second)
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
			fmt.printfln("kerneltool: test passed: %s: %d values, each different", step.text, len(remembered_values))
		case .Peer_Start:
			peer_case_started = peer_case_start_from_the_tool(machine.peer, step.text)
			fmt.printfln("kerneltool: the TCP case \"%s\" of the peer runs; the next steps run with it", step.text)
		case .Peer_Result:
			passed, result := peer_case_result(machine.peer, peer_case_started)
			if !passed {
				fmt.eprintfln("kerneltool: test failed: step %d: the TCP case \"%s\" of the peer: %s", index + 1, step.text, result)
				return false
			}
			fmt.printfln("kerneltool: test passed: the TCP case \"%s\" of the peer: %s", step.text, result)
		case .Peer:
			passed, result := peer_case(machine.peer, step.text)
			if !passed {
				fmt.eprintfln("kerneltool: test failed: step %d: the TCP case \"%s\" of the peer: %s", index + 1, step.text, result)
				return false
			}
			fmt.printfln("kerneltool: test passed: the TCP case \"%s\" of the peer: %s", step.text, result)
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
			for start := time.now(); !sync.atomic_load(&server.powered_off) && time.since(start) < STEP_TIMEOUT; {
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
	if !machine_test(steps[:], BOOT_VOLUME, TEST_OUTPUT_MEASURE_WINDOWS, MACHINE_STOP_OK, TEST_DATA_DISK) {
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
