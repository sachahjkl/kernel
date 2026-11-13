// The first layer of the network, shown case by case: the link and the
// address, an ARP answer of the gateway, an echo of the gateway, a UDP
// datagram to an echo server and its answer, the refusals of the grant, the
// frames from the wire that the network service refused, and the measures.
//
// The program holds one endpoint (contract/datagram): the root service
// granted it the remote 10.0.2.2, port 7, and nothing else. It has no
// address to choose and no port to open. The window shows each case, the
// answer, and whether it is the expected answer.
//
// **What it is for.** It shows that a network grant is a capability: the
// program reaches the one remote of its grant, and the network service
// refuses each other request with the detail of the grant. It also measures
// what one datagram costs when no kernel entry is on the path of the data.
//
// **Start**: `start("net")` in the console, or the bar of the desktop.
//
// **Grants**, as the root service gives them:
//
// - **Network**: one datagram endpoint, the remote 10.0.2.2 port 7.
// - **Inspect**: the machine, read for the frequency of the cycle counter
//   and for the kernel entries of the two services. With no such grant,
//   the window says "the services: no right Inspect".
//
// **What a reader sees**: the window lists the cases; the log has one line
// for each case ("net: ...: answer", with "(WRONG)" after an unexpected
// answer), then "net: ok, N cases", then the measures:
//
// - the round trip of one datagram of 64 bytes, least and middle;
// - the time from a refused command to its completion;
// - the rate of a burst with 64 datagrams in flight;
// - the kernel entries for each datagram, of this program, of the network
//   service and of the frame service.
//
// After the measures, each key sends one more datagram to the remote. After
// `revoke("net", "network")` in the console, that datagram is refused: the
// grant ends while the program runs.
//
// **What it does not prove**: in the test of the network the echo server at
// the gateway is the peer of the kernel tool (`tools/kerneltool/peer.odin`),
// not a stack of another project; the test of TCP against libslirp is the
// program fetch.
package net

import "contract:datagram"
import "contract:errors"
import op "contract:operation"
import "contract:ring"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:network"
import "support:system"

// The window is built with the interface package (docs/INTERFACE.md).
records_now, records_before: [1024]interface.Draw_Record
text_now, text_before: [16384]u8
drawing: interface.Window_Drawing

GATEWAY :: 0x0A000202 // 10.0.2.2: the gateway, and the echo server of the test.
LOCAL :: 0x0A00020F // 10.0.2.15
ECHO_PORT :: 7 // The port of the grant.
OTHER_PORT :: 9 // A port that the grant does not give.

PLACE_SIZE :: 2048
RECEIVE_COUNT :: 128 // Places 0 to 127 of the region: datagrams that arrive.
SEND_FIRST :: RECEIVE_COUNT // Places 128 to 255: data to send.
REGION_PAGES :: 256 * PLACE_SIZE / system.PAGE_SIZE // All of datagram.REGION_PAGES.
SEND_TAG :: 1000 // Tags from 1000: a Send. Under 1000: a Receive of the same place.
CALL_TAG :: 100_000 // Tags from 100 000: one command and its answer.

ROUND_TRIPS :: 1000
BURST_IN_FLIGHT :: 64
BURST_TIME :: 1000 // Milliseconds.
DATA_BYTES :: 64

// The frames that the peer of the test sends before its first answer, and
// that the network service must refuse: one of each row (tools/kerneltool,
// peer.odin). Ten have no endpoint: facts of the machine, that this program
// reads with the right Inspect of its grant. One came to the local port of
// this endpoint from a remote that its grant does not name: a fact of this
// endpoint.
Expected_Row :: struct {
	kind:  datagram.Problem_Kind,
	layer: datagram.Layer,
}
@(rodata)
expected_machine_rows := [?]Expected_Row {
	{.Too_Short, .Ethernet},
	{.Unsupported, .Ethernet},
	{.Bad_Checksum, .Ipv4},
	{.Bad_Header, .Ipv4},
	{.Bad_Length, .Ipv4},
	{.Unsupported, .Ipv4},
	{.Bad_Checksum, .Udp},
	{.Bad_Length, .Udp},
	{.No_Endpoint, .Udp},
	{.Bad_Header, .Arp},
}

// The window follows docs/DESIGN.md where it is cheap now: rectangles, a
// grid of 8 pixels, names in the dim color, values in the text color, the
// state of a case in the color of a program that runs or in the color
// "failed", with a text that says the same.
LINE :: 24
LEFT :: 16
ANSWER_X :: 376
WIDTH :: 864
CASE_CAPACITY :: 11
HEIGHT :: 16 + 2 * LINE + CASE_CAPACITY * LINE + 4 * LINE + 16


Case :: struct {
	text:   string,
	answer: [240]u8, // A sentence of an error record fits.
	count:  int,
	right:  bool,
}

cases: [CASE_CAPACITY]Case
case_count: int

datagrams: ring.Ring
region: [^]u8
next_tag: u32 = CALL_TAG
cycle_frequency: u64

// The measures.
round_least, round_middle: u64 // Microseconds.
burst_rate, burst_lost: u64
entries_program, entries_network, entries_frame: u64 // Hundredths of an entry for each datagram.
measured: bool
inspect: bool // The grant has the right Inspect: the facts of the machine.

note :: proc "contextless" (text: string, right: bool, parts: ..system.Part) {
	item := &cases[case_count]
	item.text = text
	item.right = right
	item.count = len(system.format(item.answer[:], ..parts))
	case_count += 1
	system.log("net: ", text, ": ", string(item.answer[:item.count]), right ? "" : " (WRONG)")
}

microseconds :: proc "contextless" (cycles: u64) -> u64 {
	return cycles * 1_000_000 / max(cycle_frequency, 1)
}

request :: proc "contextless" (command: datagram.Command, tag: u32, values: [7]u64 = {}) {
	record := ring.Record{kind = u32(command), tag = tag, values = values}
	for !system.send(&datagrams.commands, record) {
		wait: system.Wait
		system.wait_room(&wait, &datagrams.commands)
		system.wait_end(&wait)
	}
}

// answer waits for the next completion, until a deadline.
answer :: proc "contextless" (deadline: u64 = system.WAIT_FOREVER) -> (record: ring.Record, ok: bool) {
	for {
		if record, ok = system.receive(&datagrams.completions); ok {
			return record, true
		}
		wait: system.Wait
		system.wait_records(&wait, &datagrams.completions)
		if system.wait_spin(&wait) {
			continue
		}
		if system.wait_end(&wait, deadline) >= deadline {
			return system.receive(&datagrams.completions)
		}
	}
}

// call sends one command and waits for its completion. The completions of
// other tags that arrive meanwhile are dropped. The bound only ends a hang.
call :: proc "contextless" (command: datagram.Command, values: [7]u64 = {}) -> (record: ring.Record, ok: bool) {
	next_tag += 1
	request(command, next_tag, values)
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	for {
		record = answer(deadline) or_return
		if record.tag == next_tag {
			return record, true
		}
	}
}

place_of :: proc "contextless" (place: int) -> []u8 {
	return region[place * PLACE_SIZE:][:PLACE_SIZE]
}

post :: proc "contextless" (place: int) {
	request(.Receive, u32(place), {0 = u64(place * PLACE_SIZE), 1 = PLACE_SIZE})
}

send :: proc "contextless" (place: int, count: int, port: u64 = ECHO_PORT) {
	request(.Send, SEND_TAG + u32(place), {0 = u64(place * PLACE_SIZE), 1 = u64(count), 2 = GATEWAY, 3 = port})
}

address_text :: proc "contextless" (buffer: []u8, address: u32) -> string {
	writer := system.Writer{buffer = buffer}
	network.address_write(&writer, address)
	return system.written(&writer)
}

hardware_text :: proc "contextless" (buffer: []u8, value: u64) -> string {
	writer := system.Writer{buffer = buffer}
	address: network.Hardware
	for &byte, index in address {
		byte = u8(value >> (8 * uint(index)))
	}
	network.hardware_write(&writer, address)
	return system.written(&writer)
}

hundredths :: proc "contextless" (buffer: []u8, value: u64) -> string {
	tenths := value % 100
	return system.format(buffer, value / 100, ".", tenths < 10 ? "0" : "", tenths)
}

// datagram_wait waits for the answer of one datagram: the Receive of a
// place. It gives the place, its bytes and the remote.
datagram_wait :: proc "contextless" (deadline: u64) -> (place: int, count: u64, remote: u64, port: u64, ok: bool) {
	for {
		record := answer(deadline) or_return
		if record.tag < SEND_TAG && datagram.Status(record.kind) == .Ok {
			return int(record.tag), record.values[1], record.values[2], record.values[3], true
		}
	}
}

cases_run :: proc "contextless" () {
	text: [32]u8
	other: [32]u8

	// 1. The link and the address.
	info, has_info := call(.Info)
	link := has_info && datagram.Status(info.kind) == .Ok
	grant := datagram.grant_unpack(info.values[6])
	inspect = grant.inspect
	note("the link and the address", link && info.values[0] == LOCAL && info.values[3] == 24 && info.values[5] == 1 && grant.address == GATEWAY && grant.port == ECHO_PORT && !grant.tcp, address_text(text[:], u32(info.values[0])), "/24, the link is ", info.values[5] == 1 ? "up, " : "down, ", hardware_text(other[:], info.values[4]))

	// 2. The hardware address of the gateway (ARP).
	start := system.cycles()
	resolved, has_resolved := call(.Resolve, {0 = GATEWAY})
	took := microseconds(system.cycles() - start)
	note("ARP: who has 10.0.2.2", has_resolved && datagram.Status(resolved.kind) == .Ok && resolved.values[0] != 0 && resolved.values[1] == GATEWAY, "the gateway answered ", hardware_text(text[:], resolved.values[0]), " in ", took, " us")

	// 3. An echo of the gateway (ICMP).
	start = system.cycles()
	echo, has_echo := call(.Echo, {0 = GATEWAY, 1 = 1, 2 = 56})
	took = microseconds(system.cycles() - start)
	note("ICMP echo to 10.0.2.2, 56 bytes", has_echo && datagram.Status(echo.kind) == .Ok && echo.values[0] == 1 && echo.values[1] == 56, "the echo reply came in ", took, " us, time to live ", echo.values[2])

	// 4. A datagram to the echo server, and its answer.
	for place in 0 ..< RECEIVE_COUNT {
		post(place)
	}
	MESSAGE :: "the first datagram of the network service"
	copy(place_of(SEND_FIRST), MESSAGE)
	start = system.cycles()
	send(SEND_FIRST, len(MESSAGE))
	place, count, remote, port, has_answer := datagram_wait(system.time() + system.TEST_HANG_BOUND_MILLISECONDS)
	took = microseconds(system.cycles() - start)
	same := has_answer && count == len(MESSAGE) && string(place_of(place)[:count]) == MESSAGE && remote == GATEWAY && port == ECHO_PORT
	note("UDP to 10.0.2.2 port 7, 41 bytes", same, "the same 41 bytes came back from ", address_text(text[:], u32(remote)), " port ", port, " in ", took, " us")
	if has_answer {
		post(place)
	}

	// 5. A port that the grant does not give.
	copy(place_of(SEND_FIRST + 1), "not granted")
	// The completion of a refusal holds its error record: the note shows
	// its sentence.
	sentence: [240]u8
	refused, has_refused := call(.Send, {0 = (SEND_FIRST + 1) * PLACE_SIZE, 1 = 11, 2 = GATEWAY, 3 = OTHER_PORT})
	refusal_writer := system.Writer{buffer = sentence[:]}
	error := network.completion_error_text(&refusal_writer, refused)
	note("UDP to 10.0.2.2 port 9", has_refused && datagram.Status(refused.kind) == .Not_Granted && errors.Kind(error.kind) == .No_Grant && error.argument == 3 && error.value == errors.endpoint_pack(GATEWAY, OTHER_PORT) && error.limit == errors.endpoint_pack(GATEWAY, ECHO_PORT), "refused: ", system.written(&refusal_writer))

	// 6. An echo of another address.
	refused, has_refused = call(.Echo, {0 = 0x0A000203, 1 = 2, 2 = 8})
	refusal_writer = {buffer = sentence[:]}
	error = network.completion_error_text(&refusal_writer, refused)
	note("ICMP echo to 10.0.2.3", has_refused && datagram.Status(refused.kind) == .Not_Granted && errors.Kind(error.kind) == .No_Grant && error.value == errors.endpoint_pack(0x0A000203, 0), "refused: ", system.written(&refusal_writer))

	// 7. A datagram larger than one frame.
	refused, has_refused = call(.Send, {0 = 0, 1 = 2000, 2 = GATEWAY, 3 = ECHO_PORT})
	refusal_writer = {buffer = sentence[:]}
	error = network.completion_error_text(&refusal_writer, refused)
	note("UDP of 2000 bytes", has_refused && datagram.Status(refused.kind) == .Too_Large && errors.Kind(error.kind) == .Too_Long && error.value == 2000 && error.limit == datagram.DATA_LIMIT, "refused, no fragment: ", system.written(&refusal_writer))

	// 8 and 9. The frames that the network service refused. The peer sent
	// them before its first answer, so they arrived before case 4. A row of
	// this endpoint: any endpoint reads its own. A row of the machine: only
	// with the right Inspect of the grant. No row of another endpoint.
	rows_place := SEND_FIRST + 8
	problems, has_problems := call(.Problems, {0 = u64(rows_place * PLACE_SIZE), 1 = PLACE_SIZE / size_of(datagram.Problem_Row)})
	rows := ([^]datagram.Problem_Row)(raw_data(place_of(rows_place)))[:min(problems.values[0], PLACE_SIZE / size_of(datagram.Problem_Row))]
	own_rows, own_right, machine_rows, machine_found: int
	machine_total: u64
	own_from: u64
	for row in rows {
		buffer: [128]u8
		writer := system.Writer{buffer = buffer[:]}
		network.problem_write(&writer, row.last)
		switch row.scope {
		case .Endpoint:
			own_rows += 1
			// Its own row names the port of its own grant, and nothing else.
			if row.last.kind == .Not_Granted && row.last.layer == .Udp && row.last.limit == ECHO_PORT {
				own_right += 1
				own_from = u64(row.last.value)
			}
			system.log("net: refused for this endpoint: ", row.count, " x ", system.written(&writer))
		case .Machine:
			machine_rows += 1
			machine_total += row.count
			for wanted in expected_machine_rows {
				if row.last.kind == wanted.kind && row.last.layer == wanted.layer {
					machine_found += 1
				}
			}
			system.log("net: refused for the machine: ", row.count, " x ", system.written(&writer))
		case:
			machine_rows += 1000 // A scope that the contract does not have.
		}
	}
	note("UDP from 10.0.2.2 port 9 to this endpoint", has_problems && own_rows == 1 && own_right == 1 && own_from == OTHER_PORT, "refused: from port ", own_from, "; a row of this endpoint")
	if inspect {
		note("malformed frames from the wire", has_problems && machine_found == len(expected_machine_rows) && machine_rows == len(expected_machine_rows), machine_total, " refused in ", u64(machine_rows), " kinds, ", u64(machine_found), " of ", u64(len(expected_machine_rows)), " expected; no fault")
	} else {
		note("malformed frames from the wire", has_problems && machine_rows == 0, "not shown: the grant has no right Inspect")
	}

	// 10. The echo requests of the gateway, that the network service answered.
	statistics, has_statistics := call(.Statistics)
	if inspect {
		note("ICMP echo from 10.0.2.2 to this machine", has_statistics && statistics.values[5] >= 1, "the network service answered ", statistics.values[5], statistics.values[5] == 1 ? " request" : " requests")
	} else {
		note("ICMP echo from 10.0.2.2 to this machine", has_statistics && statistics.values[5] == 0, "not shown: the grant has no right Inspect")
	}
}

// measure_round_trips sends one datagram at a time and waits for its answer.
measure_round_trips :: proc "contextless" () {
	times: [ROUND_TRIPS]u64
	for index in 0 ..< ROUND_TRIPS {
		start := system.cycles()
		send(SEND_FIRST, DATA_BYTES)
		place, _, _, _, ok := datagram_wait(system.time() + 1000)
		times[index] = system.cycles() - start
		if !ok {
			times[index] = max(u64)
			continue
		}
		post(place)
	}
	// The least and the middle: a sort by insertion of 1000 numbers.
	for index in 1 ..< ROUND_TRIPS {
		value := times[index]
		place := index
		for place > 0 && times[place - 1] > value {
			times[place] = times[place - 1]
			place -= 1
		}
		times[place] = value
	}
	round_least = microseconds(times[0])
	round_middle = microseconds(times[ROUND_TRIPS / 2])
	system.log("net: the round trip of one datagram of ", u64(DATA_BYTES), " bytes: ", round_least, " us at least, ", round_middle, " us in the middle, over ", u64(ROUND_TRIPS))
}

// measure_refusals measures a request that the network service refuses
// (a Send of 2000 bytes: Too_Large), from the command to its completion.
measure_refusals :: proc "contextless" () {
	REFUSALS :: 2000
	start := system.cycles()
	refused := 0
	for _ in 0 ..< REFUSALS {
		record, ok := call(.Send, {0 = 0, 1 = 2000, 2 = GATEWAY, 3 = ECHO_PORT})
		if ok && datagram.Status(record.kind) == .Too_Large {
			refused += 1
		}
	}
	nanoseconds := microseconds(system.cycles() - start) * 1000 / REFUSALS
	system.log("net: a refused request of the datagram ring (Send of 2000 bytes, Too_Large), from the command to its completion: ", nanoseconds, " ns, ", u64(refused), " of ", u64(REFUSALS), " refused")
}

// measure_burst keeps BURST_IN_FLIGHT datagrams in flight for one second:
// each answer sends the next datagram.
measure_burst :: proc "contextless" () {
	before, _ := call(.Statistics)
	entries := system.kernel_entries()
	sent, received: u64
	for index in 0 ..< BURST_IN_FLIGHT {
		send(SEND_FIRST + index, DATA_BYTES)
		sent += 1
	}
	start := system.time()
	for system.time() - start < BURST_TIME {
		place, _, _, _, ok := datagram_wait(system.time() + 1000)
		if !ok {
			break
		}
		received += 1
		post(place)
		if system.time() - start < BURST_TIME {
			send(SEND_FIRST + int(sent % BURST_IN_FLIGHT), DATA_BYTES)
			sent += 1
		}
	}
	elapsed := max(system.time() - start, 1)
	for received < sent {
		place, _, _, _, ok := datagram_wait(system.time() + 300)
		if !ok {
			break
		}
		received += 1
		post(place)
	}
	program := system.kernel_entries() - entries
	after, _ := call(.Statistics)
	burst_rate = received * 1000 / elapsed
	burst_lost = sent - received
	entries_program = program * 100 / max(received, 1)
	entries_network = (after.values[2] - before.values[2]) * 100 / max(received, 1)
	entries_frame = (after.values[3] - before.values[3]) * 100 / max(received, 1)
	a, b, c: [16]u8
	system.log("net: a burst with ", u64(BURST_IN_FLIGHT), " datagrams in flight: ", burst_rate, " datagrams in one second, sent and answered, ", burst_lost, " lost")
	system.log("net: kernel entries for each datagram: ", hundredths(a[:], entries_program), " of this program, ", hundredths(b[:], entries_network), " of the network service, ", hundredths(c[:], entries_frame), " of the frame service")
}

draw :: proc "contextless" (window: ^display.Window) {
	if drawing.now.records == nil {
		drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	}
	frame := interface.window_frame_begin(&drawing, window)
	table := frame.table
	interface.draw_rectangle(table, 0, 0, WIDTH, HEIGHT, graphics.COLOR_BACKGROUND)
	y := 16
	interface.draw_text(table, LEFT, y, "an endpoint of datagrams: the root service granted 10.0.2.2 port 7, and nothing else.", graphics.COLOR_DIM)
	y += LINE
	interface.draw_text(table, LEFT, y, "the program asks", graphics.COLOR_DIM)
	interface.draw_text(table, ANSWER_X, y, "the network answers", graphics.COLOR_DIM)
	y += LINE
	for &item, index in cases[:case_count] {
		if index % 2 == 0 {
			interface.draw_rectangle(table, 8, y - 4, WIDTH - 16, LINE, graphics.COLOR_CARD_TOP)
		}
		interface.draw_text(table, LEFT, y, item.text, graphics.COLOR_DIM)
		end := interface.draw_text(table, ANSWER_X, y, string(item.answer[:item.count]), item.right ? graphics.COLOR_PROGRAM : graphics.COLOR_FAILED)
		if !item.right {
			interface.draw_text(table, end + 8, y, "not expected", graphics.COLOR_FAILED)
		}
		y += LINE
	}
	y += LINE / 2
	Measure :: struct {
		name:  string,
		value: string,
	}
	values: [3][96]u8
	measures: [3]Measure
	if measured {
		a, b, c: [16]u8
		measures[0] = {"round trip, one datagram of 64 bytes", system.format(values[0][:], round_least, " us at least, ", round_middle, " us in the middle")}
		measures[1] = {"a burst, 64 datagrams in flight", system.format(values[1][:], burst_rate, " in one second, sent and answered, ", burst_lost, " lost")}
		if inspect {
			measures[2] = {"kernel entries for each datagram", system.format(values[2][:], hundredths(a[:], entries_program), " here, ", hundredths(b[:], entries_network), " network, ", hundredths(c[:], entries_frame), " frame")}
		} else {
			measures[2] = {"kernel entries for each datagram", system.format(values[2][:], hundredths(a[:], entries_program), " here; the services: no right Inspect")}
		}
	} else {
		measures[0] = {"measures", "not known yet"}
	}
	for item in measures {
		if item.name == "" {
			continue
		}
		interface.draw_text(table, LEFT, y, item.name, graphics.COLOR_DIM)
		interface.draw_text(table, ANSWER_X, y, item.value, measured ? graphics.COLOR_TEXT : graphics.COLOR_DIM)
		y += LINE
	}
	interface.window_frame_end(&drawing, &frame, window)
}

// The entry of net: it runs the cases of its endpoint once, then the
// measures, then sends one datagram after each key.
//
// The entry opens its window (with none, it stops with the code 1), reads
// the frequency of the cycle counter, and opens its endpoint and its
// datagram region. With no endpoint it writes "net: no endpoint: the
// program has no grant of the network" and stops with the code 1. Then it
// runs the cases, writes "net: ok, N cases" or "net: WRONG: ...", runs the
// three measures, and writes "net: the measures are done". The program
// then waits for keys for ever: each key runs `after_key`.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "net")
	if !ok {
		system.stop(1)
	}
	boot: op.Boot_Report
	system.call(.Inspect, u64(ctx.handles[system.GRANT_MACHINE]), u64(op.Inspect_Kind.Boot), 0, u64(uintptr(&boot)), size_of(boot))
	cycle_frequency = boot.cycle_frequency
	ring_memory := ctx.handles[datagram.GRANT_RING]
	status: system.Status
	if datagrams, status = system.ring_open(ring_memory); status != .Ok {
		system.log("net: no endpoint: the program has no grant of the network")
		system.stop(1)
	}
	// The datagram region: the root service made it, with the ring.
	region_memory := ctx.handles[datagram.GRANT_REGION]
	address, map_status := system.memory_map(region_memory, {.Write})
	if map_status != .Ok || system.memory_size(region_memory) < REGION_PAGES {
		system.log("net: no datagram region")
		system.stop(1)
	}
	region = ([^]u8)(address)
	draw(&window)
	cases_run()
	draw(&window)
	wrong := 0
	for item in cases[:case_count] {
		if !item.right {
			wrong += 1
		}
	}
	if wrong == 0 {
		system.log("net: ok, ", u64(case_count), " cases")
	} else {
		system.log("net: WRONG: ", u64(wrong), " of ", u64(case_count), " cases")
	}
	measure_round_trips()
	measure_refusals()
	measure_burst()
	measured = true
	system.log("net: the measures are done")
	for {
		draw(&window)
		display.wait(&window)
		for event in display.next_event(&window) {
			if event.kind == .Key && event.pressed {
				after_key()
			}
		}
	}
}

// after_key sends one datagram to the remote of the grant, and shows the
// answer: after a revocation of the grant, the network service refuses it.
after_key :: proc "contextless" () {
	copy(place_of(SEND_FIRST), "after a key")
	sent, has_sent := call(.Send, {0 = SEND_FIRST * PLACE_SIZE, 1 = 11, 2 = GATEWAY, 3 = ECHO_PORT})
	item := &cases[CASE_CAPACITY - 1]
	item.text = "UDP to 10.0.2.2 port 7, after a key"
	switch {
	case !has_sent:
		item.count = len(system.format(item.answer[:], "no answer of the network service"))
		item.right = false
	case datagram.Status(sent.kind) == .Not_Granted && errors.completion_record(sent.values).limit == 0:
		writer := system.Writer{buffer = item.answer[:]}
		system.write_part(&writer, "refused, the endpoint has no grant now: ")
		network.completion_error_text(&writer, sent)
		item.count = len(system.written(&writer))
		item.right = true
	case datagram.Status(sent.kind) == .Ok:
		place, count, _, _, ok := datagram_wait(system.time() + system.TEST_HANG_BOUND_MILLISECONDS)
		if ok {
			post(place)
		}
		item.count = len(system.format(item.answer[:], ok ? "sent, and " : "sent, and no ", "answer"))
		item.right = ok && count == 11
	case:
		writer := system.Writer{buffer = item.answer[:]}
		system.write_part(&writer, "refused: ")
		network.completion_error_text(&writer, sent)
		item.count = len(system.written(&writer))
		item.right = false
	}
	case_count = CASE_CAPACITY
	system.log("net: a datagram to 10.0.2.2 port 7 after a key: ", string(item.answer[:item.count]))
}
#assert(REGION_PAGES == datagram.REGION_PAGES)
