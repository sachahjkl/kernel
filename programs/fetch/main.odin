// A web client of this system: TCP in the program (support/tcp) over a
// segment endpoint with a client grant. The root service granted it
// 10.0.2.100 port 80 and nothing else. In the test of TCP against a stack
// that this project did not write, QEMU gives that address to a listener
// of the kernel tool on the host (`guestfwd`): the TCP at the other end is
// the one of libslirp.
//
// The window shows each case, its answer, and whether it is the expected
// answer; the log has the same lines and the measures.
package fetch

import "contract:datagram"
import "contract:ring"
import "support:display"
import "support:graphics"
import "support:network"
import "support:system"
import "support:tcp"
import "support:web"

REMOTE :: 0x0A000264 // 10.0.2.100
REMOTE_PORT :: 80
OTHER :: 0x0A000202 // 10.0.2.2: a remote that the grant does not name.

CAPACITY :: 4
SEND_SIZE :: 64 * 1024
RECEIVE_SIZE :: 32 * 1024
PLACE_SIZE :: 2048
PLACE_COUNT :: datagram.REGION_PAGES * system.PAGE_SIZE / PLACE_SIZE
RECEIVE_PLACES :: 96
SEND_TAG :: 1000
CALL_TAG :: 100_000
WAIT_LIMIT :: 20_000 // Milliseconds for one case.

WIDTH :: 976
CASE_CAPACITY :: 10
LINE :: 24
HEIGHT :: 16 + 2 * LINE + CASE_CAPACITY * LINE + 16
ANSWER_X :: 304

// The colors of support/graphics/rules.odin: a band under one case of two,
// an expected answer in the color of a program that runs, a wrong one in
// the color "failed".
COLOR_BAND :: graphics.COLOR_CARD_TOP
COLOR_RIGHT :: graphics.COLOR_PROGRAM
COLOR_WRONG :: graphics.COLOR_FAILED

Case :: struct {
	text:   string,
	answer: [112]u8,
	count:  int,
	right:  bool,
}

cases: [CASE_CAPACITY]Case
case_count: int

table: tcp.Table
connections: [CAPACITY]tcp.Connection
endpoint: ring.Ring
region: []u8
free_places: [PLACE_COUNT - RECEIVE_PLACES]u32
free_count: int
segments: [PLACE_COUNT - RECEIVE_PLACES]tcp.Outgoing
events: [CAPACITY]tcp.Event
seen: tcp.Event_Kinds // The events of the connection of the case.
calls: [8]ring.Record // Completions of Send with a tag of CALL_TAG and more.
call_count: int

note :: proc "contextless" (text: string, right: bool, parts: ..system.Part) {
	item := &cases[case_count]
	item.text = text
	item.right = right
	item.count = len(system.format(item.answer[:], ..parts))
	case_count += 1
	system.log("fetch: ", text, ": ", string(item.answer[:item.count]), right ? "" : " (WRONG)")
}

place_bytes :: proc "contextless" (place: u32) -> []u8 {
	return region[int(place) * PLACE_SIZE:][:PLACE_SIZE]
}

// queue puts a command in the ring; a full ring keeps it for the next
// pass, so that no Send and no Receive is lost with its place.
held: [256]ring.Record
held_count: int

command_push_or_hold :: proc "contextless" (record: ring.Record) {
	if held_count == 0 && ring.push(&endpoint.commands, record) {
		return
	}
	if held_count < len(held) {
		held[held_count] = record
		held_count += 1
	}
}

held_commands_push :: proc "contextless" () {
	done := 0
	for done < held_count && ring.push(&endpoint.commands, held[done]) {
		done += 1
	}
	copy(held[:], held[done:held_count])
	held_count -= done
}

post :: proc "contextless" (place: u32) {
	command_push_or_hold(ring.Record{kind = u32(datagram.Command.Receive), tag = place, values = {0 = u64(place) * PLACE_SIZE, 1 = PLACE_SIZE}})
}

// pump reads the completions, runs one step of the table and sends its
// segments; it waits until something happens or until the next timer.
pump :: proc "contextless" () {
	wait := system.wait_begin()
	held_commands_push()
	incoming: [RECEIVE_PLACES]tcp.Incoming
	used: [RECEIVE_PLACES]u32
	count := 0
	for record in system.receive(&endpoint.completions) {
		switch {
		case record.tag < RECEIVE_PLACES:
			if datagram.Status(record.kind) == .Ok {
				incoming[count] = {remote_address = u32(record.values[2]), segment = place_bytes(record.tag)[:min(record.values[1], PLACE_SIZE)]}
				used[count] = record.tag
				count += 1
			} else {
				post(record.tag)
			}
		case record.tag >= SEND_TAG && record.tag < SEND_TAG + PLACE_COUNT:
			free_places[free_count] = record.tag - SEND_TAG
			free_count += 1
		case record.tag >= CALL_TAG:
			if call_count < len(calls) {
				calls[call_count] = record
				call_count += 1
			}
		}
	}
	now := system.nanoseconds() / 1000
	output := tcp.Output{memory = region, place_size = PLACE_SIZE, places = free_places[:free_count], segments = segments[:]}
	deadline, event_count := tcp.step(&table, incoming[:count], now, &output, events[:])
	for event in events[:event_count] {
		if event.connection == 0 {
			seen += event.kinds
		}
	}
	for item in segments[:output.count] {
		command_push_or_hold(ring.Record{kind = u32(datagram.Command.Send), tag = SEND_TAG + item.place, values = {0 = u64(item.place) * PLACE_SIZE, 1 = u64(item.length), 2 = u64(item.remote_address), 3 = u64(item.remote_port)}})
	}
	free_count -= output.count
	copy(free_places[:free_count], free_places[output.count:output.count + free_count])
	for place in used[:count] {
		post(place)
	}
	system.wake_reader(&endpoint.commands)
	if count > 0 || output.count > 0 || event_count > 0 || !ring.empty(&endpoint.completions) {
		return
	}
	system.wait_records(&wait, &endpoint.completions)
	limit := system.time() + 50
	if deadline != max(u64) {
		limit = min(limit, deadline / 1000 + 1)
	}
	system.wait_end(&wait, limit)
}

// call sends one command and waits for its completion.
call :: proc "contextless" (command: datagram.Command, tag: u32, values: [7]u64) -> (record: ring.Record, ok: bool) {
	call_count = 0
	command_push_or_hold(ring.Record{kind = u32(command), tag = tag, values = values})
	system.wake_reader(&endpoint.commands)
	deadline := system.time() + 2000
	for system.time() < deadline {
		for item in calls[:call_count] {
			if item.tag == tag {
				return item, true
			}
		}
		pump()
	}
	return {}, false
}

// Response is what read_response read on the connection.
Response :: struct {
	head:  web.Head,
	body:  [256]u8, // The first bytes of the body.
	bytes: int,
	hash:  u64,
}

// exchange writes a request on connection 0, with a body of the large
// pattern when body > 0, and reads the response.
exchange :: proc "contextless" (request: string, body: int) -> (response: Response, ok: bool) {
	deadline := system.time() + WAIT_LIMIT
	written := 0
	for written < len(request) {
		count, error := tcp.write(&table, 0, transmute([]u8)request[written:])
		if error.kind != 0 {
			return {}, false
		}
		written += count
		pump()
	}
	chunk: [4096]u8
	for sent := 0; sent < body; {
		part := min(len(chunk), body - sent, tcp.send_room(&table, 0))
		if part > 0 {
			web.pattern_fill(chunk[:part], sent)
			count, _ := tcp.write(&table, 0, chunk[:part])
			sent += count
		}
		pump()
		if system.time() > deadline || connections[0].state == .Closed {
			return {}, false
		}
	}
	head: [web.HEAD_LIMIT]u8
	head_length := 0
	response.hash = web.FNV_START
	for {
		if head_length < len(head) && response.head.size == 0 {
			count, _ := tcp.read(&table, 0, head[head_length:])
			head_length += count
			if web.head_end(head[:head_length]) != 0 {
				response.head = web.head_read(head[:head_length]) or_return
				rest := head[response.head.size:head_length]
				copy(response.body[:], rest)
				response.hash = web.fnv(response.hash, rest)
				response.bytes = len(rest)
			}
		} else if response.head.size != 0 {
			for {
				count, _ := tcp.read(&table, 0, chunk[:])
				if count == 0 {
					break
				}
				if response.bytes < len(response.body) {
					copy(response.body[response.bytes:], chunk[:count])
				}
				response.hash = web.fnv(response.hash, chunk[:count])
				response.bytes += count
			}
			if response.bytes >= response.head.content_length {
				return response, true
			}
		}
		if system.time() > deadline || (connections[0].state == .Closed && connections[0].receive_ready == 0) {
			return response, false
		}
		pump()
	}
}

// segment_refused sends a SYN that the grant does not allow, written by
// hand, and gives the completion of the network service.
segment_refused :: proc "contextless" (address: u32, local_port: u16, tag: u32) -> (ring.Record, bool) {
	place := free_places[free_count - 1]
	header := tcp.Header{source_port = local_port, destination_port = REMOTE_PORT, sequence = 1, flags = {.Syn}}
	tcp.header_write(place_bytes(place), table.local_address, address, header, tcp.HEADER)
	return call(.Send, tag, {0 = u64(place) * PLACE_SIZE, 1 = tcp.HEADER, 2 = u64(address), 3 = REMOTE_PORT})
}

cases_run :: proc "contextless" () {
	text: [32]u8
	// 1. The grant.
	info, has_info := call(.Info, CALL_TAG + 1, {})
	grant := datagram.grant_unpack(info.values[6])
	first := u16(info.values[1])
	block := u16(grant.tcp && !grant.listen ? datagram.PORT_BLOCK : 1)
	writer := system.Writer{buffer = text[:]}
	network.address_write(&writer, grant.address)
	note("the grant", has_info && grant.tcp && !grant.listen && grant.address == REMOTE && grant.port == REMOTE_PORT && block == datagram.PORT_BLOCK, "TCP to ", system.written(&writer), " port ", u64(grant.port), " only, from the local ports ", u64(first), " to ", u64(first) + u64(block) - 1)
	table.local_address = u32(info.values[0])
	table.port_first = first
	table.port_count = block

	// 2. A remote that the grant does not name.
	refused, has_refused := segment_refused(OTHER, first, CALL_TAG + 2)
	note("a SYN to 10.0.2.2 port 80", has_refused && datagram.Status(refused.kind) == .Not_Granted && refused.values[2] == REMOTE && refused.values[3] == REMOTE_PORT, "refused by the network service: the grant names 10.0.2.100 port ", refused.values[3])
	// 3. A local port that is not in the block.
	refused, has_refused = segment_refused(REMOTE, 1234, CALL_TAG + 3)
	note("a SYN from the local port 1234", has_refused && datagram.Status(refused.kind) == .Not_Granted && refused.values[4] == 1234 && refused.values[5] == u64(first), "refused: the local ports are ", refused.values[5], " to ", refused.values[5] + refused.values[6] - 1)

	// 4. The handshake.
	start := system.nanoseconds()
	index, error := tcp.connect(&table, REMOTE, REMOTE_PORT, start / 1000)
	for index == 0 && error.kind == 0 && connections[0].state == .Syn_Sent && system.nanoseconds() - start < 5_000_000_000 {
		pump()
	}
	opened := connections[0].state == .Established
	handshake := connections[0].established_at - connections[0].opened_at
	note("the handshake with 10.0.2.100 port 80", opened && .Opened in seen, opened ? "established in " : "no answer", opened ? handshake : 0, opened ? " us, the MSS " : "", opened ? u64(connections[0].mss) : 0)
	if !opened {
		return
	}

	// 5. A small page.
	start = system.nanoseconds()
	response, ok := exchange("GET /hello HTTP/1.1\r\nHost: 10.0.2.100\r\n\r\n", 0)
	took := (system.nanoseconds() - start) / 1000
	body := string(response.body[:min(response.bytes, len(response.body))])
	for len(body) > 0 && (body[len(body) - 1] == '\n' || body[len(body) - 1] == '\r') {
		body = body[:len(body) - 1]
	}
	note("GET /hello", ok && response.head.status == 200, "status ", u64(response.head.status), ", \"", body, "\" in ", took, " us")

	// 6. The large page: 1 MiB from the remote.
	start = system.nanoseconds()
	response, ok = exchange("GET /large HTTP/1.1\r\nHost: 10.0.2.100\r\n\r\n", 0)
	took = system.nanoseconds() - start
	expected := web.pattern_hash(web.LARGE_SIZE)
	speed: [24]u8
	note("GET /large", ok && response.head.status == 200 && response.bytes == web.LARGE_SIZE && response.hash == expected, u64(response.bytes), " bytes, fnv1a64 ", system.Hex(response.hash), response.hash == expected ? " as expected, " : " NOT the expected one, ", megabytes(speed[:], rate(u64(response.bytes), took)))

	// 7. A body of 1 MiB to the remote: it gives the hash that it computed.
	start = system.nanoseconds()
	request: [128]u8
	head := system.format(request[:], "POST /sink HTTP/1.1\r\nHost: 10.0.2.100\r\nContent-Length: ", u64(web.LARGE_SIZE), "\r\n\r\n")
	response, ok = exchange(head, web.LARGE_SIZE)
	took = system.nanoseconds() - start
	answer: [64]u8
	wanted := system.format(answer[:], "received ", u64(web.LARGE_SIZE), " bytes, fnv1a64 ", system.Hex(expected))
	got := string(response.body[:min(response.bytes, len(response.body), len(wanted))])
	note("POST /sink, 1 MiB", ok && response.head.status == 200 && got == wanted, got == wanted ? "the remote got the same hash, " : "the remote answered another hash, ", megabytes(speed[:], rate(u64(web.LARGE_SIZE), took)))

	// 8. The close from this side. The remote acknowledges the FIN; then it
	// sends its own FIN (TIME-WAIT here), or keeps its half of the
	// connection open (FIN-WAIT-2 here). Both are TCP.
	tcp.close(&table, 0)
	deadline := system.time() + 2000
	for connections[0].state != .Time_Wait && system.time() < deadline {
		pump()
	}
	state := connections[0].state
	note("the close from this side", (state == .Time_Wait || state == .Fin_Wait_2) && connections[0].fin_acknowledged, "the remote acknowledged the FIN, ", state == .Time_Wait ? "and sent its own: TIME-WAIT for 10 s" : state == .Fin_Wait_2 ? "and keeps its half open: FIN-WAIT-2" : "WRONG: no ACK of the FIN")
	system.log("fetch: the connection: ", connections[0].segments_sent, " segments sent, ", connections[0].segments_received, " received, ", connections[0].retransmissions, " retransmissions, srtt ", connections[0].smoothed_rtt, " us")
}

rate :: proc "contextless" (bytes: u64, nanoseconds: u64) -> u64 {
	return bytes * 1_000_000 / max(nanoseconds, 1)
}

megabytes :: proc "contextless" (buffer: []u8, kilobytes: u64) -> string {
	return system.format(buffer, kilobytes / 1000, ".", kilobytes % 1000 / 100, " MB/s")
}

draw :: proc "contextless" (window: ^display.Window) {
	canvas := window.canvas
	graphics.clear(canvas, graphics.COLOR_BACKGROUND)
	y := 16
	graphics.text(canvas, 16, y, "a segment endpoint with a client grant: TCP to 10.0.2.100 port 80, and nothing else.", graphics.COLOR_DIM)
	y += LINE
	graphics.text(canvas, 16, y, "the program asks", graphics.COLOR_DIM)
	graphics.text(canvas, ANSWER_X, y, "the answer", graphics.COLOR_DIM)
	y += LINE
	for &item, index in cases[:case_count] {
		if index % 2 == 0 {
			graphics.fill(canvas, 8, y - 4, WIDTH - 16, LINE, COLOR_BAND)
		}
		graphics.text(canvas, 16, y, item.text, graphics.COLOR_DIM)
		graphics.text(canvas, ANSWER_X, y, string(item.answer[:item.count]), item.right ? COLOR_RIGHT : COLOR_WRONG)
		y += LINE
	}
	display.present(window)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "fetch")
	if !ok {
		system.stop(1)
	}
	status: system.Status
	if endpoint, status = system.ring_open(ctx.handles[datagram.GRANT_RING]); status != .Ok {
		system.log("fetch: no endpoint: the program has no grant of the network")
		system.stop(1)
	}
	address, map_status := system.memory_map(ctx.handles[datagram.GRANT_REGION], {.Write})
	if map_status != .Ok {
		system.log("fetch: no datagram region")
		system.stop(1)
	}
	region = ([^]u8)(address)[:datagram.REGION_PAGES * system.PAGE_SIZE]
	// The buffers of the connections: memory of this program (property 14).
	BUFFER_PAGES :: CAPACITY * (SEND_SIZE + RECEIVE_SIZE) / system.PAGE_SIZE
	memory, memory_status := system.memory_create(BUFFER_PAGES)
	buffers, buffers_status := system.memory_map(memory, {.Write})
	if memory_status != .Ok || buffers_status != .Ok {
		system.log("fetch: no memory for the buffers of the connections")
		system.stop(1)
	}
	secret, from_processor := tcp.secret_make(system.cycles())
	tcp.table_init(&table, connections[:], ([^]u8)(buffers)[:BUFFER_PAGES * system.PAGE_SIZE], SEND_SIZE, RECEIVE_SIZE, 0, secret)
	system.log("fetch: the secret of the initial sequence numbers from ", from_processor ? "rdrand" : "the cycle counter")
	for place in 0 ..< RECEIVE_PLACES {
		post(u32(place))
	}
	for place in RECEIVE_PLACES ..< PLACE_COUNT {
		free_places[free_count] = u32(place)
		free_count += 1
	}
	system.wake_reader(&endpoint.commands)
	draw(&window)
	cases_run()
	wrong := 0
	for item in cases[:case_count] {
		if !item.right {
			wrong += 1
		}
	}
	if wrong == 0 && case_count == 8 {
		system.log("fetch: ok, ", u64(case_count), " cases")
	} else {
		system.log("fetch: WRONG: ", u64(wrong), " of ", u64(case_count), " cases")
	}
	draw(&window)
	// A half-closed connection ends with a RST: the library has no timer of
	// FIN-WAIT-2. A connection in TIME-WAIT ends after it.
	if connections[0].state == .Fin_Wait_2 {
		tcp.abort(&table, 0)
	}
	for connections[0].state != .Closed || connections[0].reset_pending {
		pump()
	}
	system.log("fetch: the connection ended, its record is free")
	for {
		display.wait(&window)
		for event in display.next_event(&window) {
			_ = event
		}
	}
}
