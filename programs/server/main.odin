// A web server of this system: TCP in the program (support/tcp), one
// thread, one connection table, and a small HTTP/1.1 (support/web).
//
// The root service gave it one segment endpoint with a listen grant: the
// TCP port 80, and the remotes that send a segment to it. It reaches no
// other machine. Its pages come from what it has: its own counts.
//
//   GET /             a page of text: the connections and the counts.
//   GET /large        LARGE_SIZE bytes of a known pattern (support/web).
//   POST /sink        reads a body of Content-Length bytes, and answers
//                     with its length and its hash.
//
// The window shows the connection table live: the state of each
// connection, its bytes, its round trip, its congestion window, its
// retransmissions; and the totals and the measures.
package server

import "contract:datagram"
import "contract:ring"
import "support:display"
import "support:network"
import "support:system"
import "support:tcp"
import "support:web"

CAPACITY :: 32 // Connections at one time, with the ones in TIME-WAIT.
SEND_SIZE :: 64 * 1024
RECEIVE_SIZE :: 32 * 1024
BUFFER_PAGES :: CAPACITY * (SEND_SIZE + RECEIVE_SIZE) / system.PAGE_SIZE

// The datagram region: 256 places of 2048 bytes.
PLACE_SIZE :: 2048
PLACE_COUNT :: datagram.REGION_PAGES * system.PAGE_SIZE / PLACE_SIZE
RECEIVE_PLACES :: 96 // Places 0 to 95: segments that arrive. The others: segments to send.
SEND_TAG :: 1000 // Tags from 1000: a Send of place tag - 1000.
CALL_TAG :: 100_000 // Info and Release.

HISTORY :: 16 // Connections that ended, that the window still shows.

Page :: enum u8 {
	None,
	Root,
	Large,
	Sink,
	Missing,
	Bad,
}

// The HTTP side of one connection: the record with the same index as its
// connection in the table.
Session :: struct {
	head:           [web.HEAD_LIMIT]u8,
	head_length:    int,
	request:        web.Head,
	page:           Page,
	body_left:      int,
	body_hash:      u64,
	body_bytes:     int,
	pending:        [1024]u8, // The head of the answer, and a small body.
	pending_length: int,
	pending_done:   int,
	large_left:     int,
	large_offset:   int,
	written:        u64, // The bytes that this side wrote in the connection.
	answer_bytes:   u64,
	wait_ack:       bool, // The answer is written: its time ends at the ACK of its last byte.
	acked_at:       u64, // written at the end of the answer: the bytes_sent that ends it.
	request_start:  u64, // Nanoseconds.
	body_start:     u64,
	close_after:    bool,
	closing:        bool,
	logged:         bool, // The end of the connection is on the log and in the history.
	requests:       int,
}

// A connection that ended, as the window shows it.
Ended :: struct {
	record: tcp.Connection,
	how:    string,
	known:  bool,
}

table: tcp.Table
connections: [CAPACITY]tcp.Connection
sessions: [CAPACITY]Session
history: [HISTORY]Ended
history_next: int

endpoint: ring.Ring
region: []u8
free_places: [PLACE_COUNT - RECEIVE_PLACES]u32
free_count: int
segments: [PLACE_COUNT - RECEIVE_PLACES]tcp.Outgoing
events: [CAPACITY]tcp.Event
local_address: u32
listen_port: u16
secret_source: string

// Totals and measures.
accepted: u64
requests: u64
most_open: int
bytes_in, bytes_out: u64
retransmissions, resets, timeouts: u64
handshake_last, handshake_least: u64 // Microseconds.
request_last: u64 // Microseconds: the last answer of a small page, to its ACK.
send_rate, receive_rate: u64 // Kilobytes in one second: the last /large and the last /sink.
draw_time: u64
start_time: u64

fail :: proc "contextless" (text: string) -> ! {
	system.log("server: ", text)
	system.stop(1)
}

now_us :: proc "contextless" () -> u64 {
	return system.nanoseconds() / 1000
}

place_bytes :: proc "contextless" (place: u32) -> []u8 {
	return region[int(place) * PLACE_SIZE:][:PLACE_SIZE]
}

post :: proc "contextless" (place: u32) {
	ring.push(&endpoint.commands, ring.Record{kind = u32(datagram.Command.Receive), tag = place, values = {0 = u64(place) * PLACE_SIZE, 1 = PLACE_SIZE}})
}

address_text :: proc "contextless" (buffer: []u8, address: u32, port: u16) -> string {
	writer := system.Writer{buffer = buffer}
	network.address_write(&writer, address)
	system.write_bytes(&writer, transmute([]u8)string(" port "))
	system.write_unsigned(&writer, u64(port))
	return system.written(&writer)
}

// rate gives kilobytes in one second.
rate :: proc "contextless" (bytes: u64, nanoseconds: u64) -> u64 {
	return bytes * 1_000_000 / max(nanoseconds, 1)
}

// megabytes writes a rate of kilobytes in one second as "12.3 MB/s".
megabytes :: proc "contextless" (buffer: []u8, kilobytes: u64) -> string {
	return system.format(buffer, kilobytes / 1000, ".", kilobytes % 1000 / 100, " MB/s")
}

session_reset :: proc "contextless" (session: ^Session) {
	keep_written := session.written
	keep_requests := session.requests
	keep_closing := session.closing
	session^ = {}
	session.written = keep_written
	session.requests = keep_requests
	session.closing = keep_closing
}

// answer_start makes the head of the answer of a request.
answer_start :: proc "contextless" (index: int) {
	session := &sessions[index]
	request := &session.request
	body: [512]u8
	text: string
	status := "200 OK"
	length := 0
	switch session.page {
	case .Root:
		open := tcp.open_count(&table)
		text = system.format(body[:], "server: TCP in the program, one thread, one table.\nconnections open: ", u64(open), ", most at once: ", u64(most_open), ", accepted: ", accepted, "\nrequests: ", requests, ", bytes in: ", bytes_in, ", bytes out: ", bytes_out, "\nretransmissions: ", retransmissions, ", resets: ", resets, "\nuptime: ", system.time() - start_time, " ms, kernel entries: ", system.kernel_entries(), "\n")
		length = len(text)
	case .Large:
		length = web.LARGE_SIZE
		session.large_left = web.LARGE_SIZE
	case .Sink:
		text = system.format(body[:], "received ", u64(session.body_bytes), " bytes, fnv1a64 ", system.Hex(session.body_hash), "\n")
		length = len(text)
	case .Missing:
		status = "404 Not Found"
		text = "no such page\n"
		length = len(text)
	case .Bad, .None:
		status = "400 Bad Request"
		text = "a request that this server cannot read\n"
		length = len(text)
		session.close_after = true
	}
	if request.close {
		session.close_after = true
	}
	head := system.format(session.pending[:], "HTTP/1.1 ", status, "\r\nContent-Length: ", u64(length), "\r\nContent-Type: text/plain\r\n", session.close_after ? "Connection: close\r\n" : "", "\r\n")
	session.pending_length = len(head) + copy(session.pending[len(head):], text)
	session.pending_done = 0
	session.answer_bytes = u64(len(head) + length)
}

// answer_write writes what the send buffer takes. It gives true when the
// answer is all written.
answer_write :: proc "contextless" (index: int) -> bool {
	session := &sessions[index]
	if session.pending_done < session.pending_length {
		count, _ := tcp.write(&table, index, session.pending[session.pending_done:session.pending_length])
		session.pending_done += count
		session.written += u64(count)
		if session.pending_done < session.pending_length {
			return false
		}
	}
	chunk: [4096]u8
	for session.large_left > 0 {
		room := tcp.send_room(&table, index)
		if room == 0 {
			return false
		}
		part := min(session.large_left, len(chunk), room)
		web.pattern_fill(chunk[:part], session.large_offset)
		count, _ := tcp.write(&table, index, chunk[:part])
		session.large_left -= count
		session.large_offset += count
		session.written += u64(count)
	}
	return true
}

// request_take reads the bytes that arrived on a connection, and answers.
request_take :: proc "contextless" (index: int, now: u64) {
	session := &sessions[index]
	connection := &connections[index]
	for !session.closing {
		// An answer in progress: write more of it.
		if session.page != .None && session.body_left == 0 {
			if !session.wait_ack {
				if !answer_write(index) {
					return
				}
				session.wait_ack = true
				session.acked_at = session.written
			}
			return // The next request waits for the ACK of this answer.
		}
		chunk: [4096]u8
		room := len(chunk)
		if session.page == .None {
			room = min(room, len(session.head) - session.head_length)
		} else {
			room = min(room, session.body_left)
		}
		count, _ := tcp.read(&table, index, chunk[:room])
		if count == 0 {
			if session.page == .None && session.head_length == len(session.head) {
				session.page = .Bad // A head longer than HEAD_LIMIT.
				answer_start(index)
				continue
			}
			return
		}
		if session.page == .Sink {
			session.body_hash = web.fnv(session.body_hash, chunk[:count])
			session.body_bytes += count
			session.body_left -= count
			if session.body_left == 0 {
				answer_start(index)
			}
			continue
		}
		if session.head_length == 0 {
			session.request_start = system.nanoseconds()
		}
		copy(session.head[session.head_length:], chunk[:count])
		session.head_length += count
		end := web.head_end(session.head[:session.head_length])
		if end == 0 {
			continue
		}
		head, ok := web.head_read(session.head[:session.head_length])
		session.request = head
		rest := session.head[end:session.head_length]
		switch {
		case !ok:
			session.page = .Bad
		case head.method == .Get && web.path(&head) == "/":
			session.page = .Root
		case head.method == .Get && web.path(&head) == "/large":
			session.page = .Large
		case head.method == .Post && web.path(&head) == "/sink" && head.content_length >= 0:
			session.page = .Sink
			session.body_left = head.content_length
			session.body_hash = web.FNV_START
			session.body_start = system.nanoseconds()
			taken := min(len(rest), session.body_left)
			session.body_hash = web.fnv(session.body_hash, rest[:taken])
			session.body_bytes = taken
			session.body_left -= taken
		case:
			session.page = .Missing
		}
		if session.page != .Sink || session.body_left == 0 {
			answer_start(index)
		}
	}
	_ = connection
	_ = now
}

// answered ends a request whose answer the remote acknowledged.
answered :: proc "contextless" (index: int) {
	session := &sessions[index]
	connection := &connections[index]
	took := system.nanoseconds() - session.request_start
	requests += 1
	session.requests += 1
	who: [32]u8
	remote := address_text(who[:], connection.remote_address, connection.remote_port)
	speed: [24]u8
	#partial switch session.page {
	case .Large:
		send_rate = rate(u64(web.LARGE_SIZE), took)
		system.log("server: sent /large to ", remote, ": ", u64(web.LARGE_SIZE), " bytes in ", took / 1000, " us, ", megabytes(speed[:], send_rate), ", ", connection.retransmissions, " retransmissions, ", connection.probes, " probes")
	case .Sink:
		receive_rate = rate(u64(session.body_bytes), system.nanoseconds() - session.body_start)
		system.log("server: received /sink from ", remote, ": ", u64(session.body_bytes), " bytes, fnv1a64 ", system.Hex(session.body_hash), ", ", megabytes(speed[:], receive_rate))
	case .Root:
		request_last = took / 1000
		system.log("server: GET / for ", remote, ": ", session.answer_bytes, " bytes, answered and acknowledged in ", request_last, " us")
	case:
		system.log("server: a refused request of ", remote, ": ", session.answer_bytes, " bytes")
	}
	close_after := session.close_after
	session_reset(session)
	if close_after {
		session.closing = true
		tcp.close(&table, index)
	}
}

// ended_log writes the end of a connection on the log and in the history:
// when it ends, or when it enters TIME-WAIT (this side closed first: the
// record stays 10 s more, and has nothing more to say).
ended_log :: proc "contextless" (index: int, how: string) {
	connection := &connections[index]
	if sessions[index].logged {
		return
	}
	sessions[index].logged = true
	history[history_next] = {record = connection^, how = how, known = true}
	history_next = (history_next + 1) % HISTORY
	bytes_in += connection.bytes_received
	bytes_out += connection.bytes_sent
	retransmissions += connection.retransmissions
	who: [32]u8
	system.log("server: ", address_text(who[:], connection.remote_address, connection.remote_port), " ", how, ": in ", connection.bytes_received, ", out ", connection.bytes_sent, ", srtt ", connection.smoothed_rtt, " us, ", connection.retransmissions, " retransmissions, ", connection.probes, " probes, ", connection.challenges, " challenges")
}

// ended takes the end of a connection: the record is free after this
// event, and the network service forgets its remote.
ended :: proc "contextless" (index: int, how: string) {
	connection := &connections[index]
	ended_log(index, how)
	release(connection.remote_address, connection.remote_port)
	sessions[index] = {}
}

release :: proc "contextless" (address: u32, port: u16) {
	ring.push(&endpoint.commands, ring.Record{kind = u32(datagram.Command.Release), tag = CALL_TAG, values = {0 = u64(address), 1 = u64(port)}})
}

event_take :: proc "contextless" (event: tcp.Event, now: u64) {
	index := int(event.connection)
	connection := &connections[index]
	if .Accepted in event.kinds {
		accepted += 1
		sessions[index] = {}
		handshake_last = connection.established_at - connection.opened_at
		handshake_least = handshake_least == 0 ? handshake_last : min(handshake_least, handshake_last)
		open := tcp.open_count(&table)
		if open > most_open {
			most_open = open
			system.log("server: ", u64(open), " connections open at once")
		}
	}
	switch {
	case .Reset in event.kinds:
		resets += 1
		ended(index, "reset by the remote")
		return
	case .Timed_Out in event.kinds:
		timeouts += 1
		ended(index, "timed out")
		return
	case .Closed in event.kinds:
		ended(index, connection.closed_by_remote ? "closed, the remote first" : "closed, this server first")
		return
	}
	if .Peer_Closed in event.kinds {
		session := &sessions[index]
		if session.page == .None && session.head_length == 0 && !session.closing {
			session.closing = true
			tcp.close(&table, index)
		} else {
			session.close_after = true
		}
	}
}

// exchange runs one step of the table: the segments that arrived, the
// events, the answers, and the segments to send.
exchange :: proc "contextless" (incoming: []tcp.Incoming) -> (deadline: u64) {
	now := now_us()
	output := tcp.Output{memory = region, place_size = PLACE_SIZE, places = free_places[:free_count], segments = segments[:]}
	count: int
	deadline, count = tcp.step(&table, incoming, now, &output, events[:])
	// The events and the answers write data; the next step sends it. A few
	// rounds end the work of one pass; what is left waits for the next pass.
	for round := 0; round < 4; round += 1 {
		for event in events[:count] {
			event_take(event, now)
		}
		for &connection, index in connections {
			if connection.state == .Time_Wait {
				ended_log(index, "closed, this server first")
			}
			if connection.state == .Established || connection.state == .Close_Wait {
				session := &sessions[index]
				if session.wait_ack && connection.bytes_sent >= session.acked_at {
					answered(index)
				}
				request_take(index, now)
			}
		}
		more := tcp.Output{memory = region, place_size = PLACE_SIZE, places = free_places[output.count:free_count], segments = segments[output.count:]}
		next: u64
		next, count = tcp.step(&table, nil, now, &more, events[:])
		deadline = min(deadline, next)
		output.count += more.count
		if count == 0 && more.count == 0 {
			break
		}
		if round == 3 {
			deadline = now // More work: the next pass comes at once.
		}
	}
	for event in events[:count] {
		event_take(event, now)
	}
	// Send each segment: the ring takes them, then one wake.
	for item in segments[:output.count] {
		ring.push(&endpoint.commands, ring.Record{kind = u32(datagram.Command.Send), tag = SEND_TAG + item.place, values = {0 = u64(item.place) * PLACE_SIZE, 1 = u64(item.length), 2 = u64(item.remote_address), 3 = u64(item.remote_port)}})
		// A RST for a segment of no connection: no connection will release
		// this remote, so it is released after the RST.
		if item.connection < 0 {
			release(item.remote_address, item.remote_port)
		}
	}
	// The places that the step used are not free until their Send completes.
	free_count -= output.count
	copy(free_places[:free_count], free_places[output.count:output.count + free_count])
	return deadline
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "server")
	if !ok {
		system.stop(1)
	}
	start_time = system.time()
	status: system.Status
	if endpoint, status = system.ring_open(ctx.handles[datagram.GRANT_RING]); status != .Ok {
		fail("no endpoint: the program has no grant of the network")
	}
	region_memory := ctx.handles[datagram.GRANT_REGION]
	address, map_status := system.memory_map(region_memory, {.Write})
	if map_status != .Ok {
		fail("no datagram region")
	}
	region = ([^]u8)(address)[:datagram.REGION_PAGES * system.PAGE_SIZE]
	// The grant.
	system.send(&endpoint.commands, ring.Record{kind = u32(datagram.Command.Info), tag = CALL_TAG})
	info: ring.Record
	for {
		record, has := system.receive(&endpoint.completions)
		if has {
			info = record
			break
		}
		wait: system.Wait
		system.wait_records(&wait, &endpoint.completions)
		system.wait_end(&wait, system.time() + 2000)
	}
	grant := datagram.grant_unpack(info.values[6])
	if !grant.tcp || !grant.listen {
		fail("the grant is not a listen grant of TCP")
	}
	local_address = u32(info.values[0])
	listen_port = grant.port
	// The connection table: its records and its buffers are memory of this
	// program (property 14).
	memory, memory_status := system.memory_create(BUFFER_PAGES)
	buffers, buffers_status := system.memory_map(memory, {.Write})
	if memory_status != .Ok || buffers_status != .Ok {
		fail("no memory for the buffers of the connections")
	}
	secret, from_processor := tcp.secret_make(system.cycles())
	secret_source = from_processor ? "rdrand" : "the cycle counter"
	if error := tcp.table_init(&table, connections[:], ([^]u8)(buffers)[:BUFFER_PAGES * system.PAGE_SIZE], SEND_SIZE, RECEIVE_SIZE, local_address, secret); error.kind != 0 {
		fail("the connection table refused its memory")
	}
	table.listen_port = listen_port
	for place in 0 ..< RECEIVE_PLACES {
		post(u32(place))
	}
	for place in RECEIVE_PLACES ..< PLACE_COUNT {
		free_places[free_count] = u32(place)
		free_count += 1
	}
	system.wake_reader(&endpoint.commands)
	system.log("server: listening on the TCP port ", u64(listen_port), ", a table of ", u64(CAPACITY), " connections, the secret of the initial sequence numbers from ", secret_source)

	incoming: [RECEIVE_PLACES]tcp.Incoming
	used: [RECEIVE_PLACES]u32
	last_draw: u64
	changed := true
	for {
		wait := system.wait_begin()
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
			}
		}
		deadline := exchange(incoming[:count])
		// The places of the segments that the step read are free again.
		for place in used[:count] {
			post(place)
		}
		system.wake_reader(&endpoint.commands)
		if count > 0 {
			changed = true
		}
		for event in display.next_event(&window) {
			_ = event
		}
		now := system.time()
		if changed && now - last_draw >= 100 {
			draw(&window)
			last_draw = now
			changed = false
		}
		if !ring.empty(&endpoint.completions) {
			continue
		}
		system.wait_records(&wait, &endpoint.completions)
		display.wait_events(&wait, &window)
		limit := changed ? last_draw + 100 : system.WAIT_FOREVER
		if deadline != max(u64) {
			limit = min(limit, deadline / 1000 + 1)
		}
		system.wait_end(&wait, limit)
	}
}
