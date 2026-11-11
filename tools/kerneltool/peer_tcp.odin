package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "support:tcp"
import "support:web"

// The peer as a TCP client of the program `server` (docs/NETWORK.md, "With
// the controlled peer"). The tool asks for one case at a time (step Peer);
// the thread of the peer runs it with support/tcp, the library of the
// system, so the cases test the library against itself; the machine with
// libslirp tests it against another implementation.
//
// Between its library and the machine, the peer changes the frames of TCP
// with a generator of numbers that the case seeds: each run drops,
// reorders and repeats the same frames. It reads each frame of the machine
// with its own checks (peer.odin), also the TCP checksum.

PEER_TCP_CAPACITY :: 96
PEER_TCP_SEND :: 64 * 1024
PEER_TCP_RECEIVE :: 32 * 1024
PEER_TCP_PLACES :: 64
PEER_TCP_PLACE_SIZE :: 2048
MACHINE_TCP_ADDRESS :: 0x0A00020F
PEER_TCP_ADDRESS :: 0x0A000202
SERVER_PORT :: 80
CASE_TIME_LIMIT :: 60 * time.Second

// The connections of a host that wants to keep the records of the server
// (case "slow"; an independent read of the step, B2).
Attack :: enum {
	None,
	Idle, // A handshake, then nothing.
	Half_Head, // Half a head, then nothing.
	Trickle, // A body of 1 000 000 bytes at one byte in one second.
	No_Fin, // A request that the server refuses, then no FIN after the FIN of the server.
	Half_Head_Fin, // Half a head, then a FIN.
	Zero_Window, // /large, and a window of 0 for ever.
	Huge, // A Content-Length of 999 999 999 999.
}

Client_Phase :: enum {
	Connect,
	Request,
	Response,
	Close,
	Done,
	Failed,
}

// One connection of a case, and what it must find.
Client :: struct {
	connection:   int,
	phase:        Client_Phase,
	request:      string,
	body:         int, // Bytes of the large pattern after the request.
	body_sent:    int,
	written:      int,
	head:         [web.HEAD_LIMIT]u8,
	head_length:  int,
	response:     web.Head,
	content:      [256]u8,
	bytes:        int,
	hash:         u64,
	expect_text:  string, // The start of the body.
	expect_large: bool, // The body is the large page.
	close_first:  bool, // The peer closes after the response; else the server closes.
	pause_after:  int, // Stop reading after this many bytes of the body...
	pause_time:   time.Duration, // ...for this time: the window of the peer goes to 0.
	paused_at:    time.Tick,
	paused:       bool,
	pause_done:   bool,
	abort_after:  int, // Send a RST after this many bytes of the body.
	challenge:    bool, // After the response: a RST and a SYN that the server must answer with an ACK.
	challenged:   int,
	again:        bool, // After the challenges, one more request.
	failure:      string,
	attack:       Attack,
	delayed:      bool, // The client connects when each attack ended.
	refused:      bool, // The server answered the SYN with a RST.
	ended_at:     time.Duration, // The server ended the connection: the time from the start of the case.
	trickle_at:   time.Tick,
	attempts:     int,
	first_byte_at: time.Tick, // The first byte of the body of the answer, at the peer.
	last_byte_at:  time.Tick,
	written_at:    time.Tick, // The request and its body were in the send buffer of the peer.
}

Peer_Tcp :: struct {
	table:       tcp.Table,
	connections: [PEER_TCP_CAPACITY]tcp.Connection,
	buffers:     []u8,
	memory:      []u8,
	places:      [PEER_TCP_PLACES]u32,
	segments:    [PEER_TCP_PLACES]tcp.Outgoing,
	events:      [PEER_TCP_CAPACITY]tcp.Event,
	start:       time.Tick,
	// The changes of the frames, per thousand.
	random:      u64,
	loss:        u64,
	reorder:     u64,
	duplicate:   u64,
	held:        [dynamic][]u8, // Frames that wait: they go after the next frame.
	dropped:     int,
	reordered:   int,
	repeated:    int,
	// The case that runs.
	name:        string,
	clients:     [PEER_TCP_CAPACITY]Client,
	client_count: int,
	started:     time.Tick,
	stray_reset: bool, // The RST of the server for the segment of no connection.
	stray_sent:  bool,
	acks_seen:   int, // ACKs that arrived for a connection in a challenge.
	seen_by:     [PEER_TCP_CAPACITY]tcp.Event_Kinds, // The events of each record in the case.
	raw:         [dynamic][]u8, // Segments that the case sends by hand, a few at each tick.
	raw_sent:    int,
	raw_time:    time.Duration, // The last segment by hand went: the time from the start of the case.
	fetch_at:    time.Duration, // The page came: the time from the start of the case.
	// Between the threads: the tool writes `wanted`, the peer writes `done`.
	wanted:      int,
	started_case: int, // The number of the case that peer_case_start prepared.
	done:        int,
	passed:      bool,
	result:      string,
}

peer_tcp_now :: proc(state: ^Peer_Tcp) -> u64 {
	return u64(time.tick_since(state.start) / time.Microsecond) + 1
}

peer_random :: proc(state: ^Peer_Tcp) -> u64 {
	state.random ~= state.random << 13
	state.random ~= state.random >> 7
	state.random ~= state.random << 17
	return state.random
}

peer_tcp_make :: proc() -> ^Peer_Tcp {
	state := new(Peer_Tcp)
	state.buffers = make([]u8, PEER_TCP_CAPACITY * (PEER_TCP_SEND + PEER_TCP_RECEIVE))
	state.memory = make([]u8, PEER_TCP_PLACES * PEER_TCP_PLACE_SIZE)
	secret: [32]u8
	secret[0] = 0x70
	tcp.table_init(&state.table, state.connections[:], state.buffers, PEER_TCP_SEND, PEER_TCP_RECEIVE, PEER_TCP_ADDRESS, secret)
	state.table.port_first = 40000
	state.table.port_count = 2000
	state.start = time.tick_now()
	return state
}

peer_tcp_free :: proc(state: ^Peer_Tcp) {
	delete(state.buffers)
	delete(state.memory)
	for frame in state.held {
		delete(frame)
	}
	delete(state.held)
	free(state)
}

// peer_case asks the thread of the peer for a case, and waits for its end.
peer_case :: proc(peer: ^Peer, name: string) -> (passed: bool, result: string) {
	state := peer.tcp
	state.name = name
	serial := sync.atomic_load(&state.wanted) + 1
	sync.atomic_store(&state.wanted, serial)
	start := time.tick_now()
	for sync.atomic_load(&state.done) != serial {
		if time.tick_since(start) > CASE_TIME_LIMIT + 5 * time.Second {
			return false, "the peer did not end the case"
		}
		time.sleep(20 * time.Millisecond)
	}
	return state.passed, state.result
}

// The client for each kind of request.
client_page :: proc(close_first: bool) -> Client {
	return {request = "GET / HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n", expect_text = "<!doctype html>", close_first = close_first}
}

client_large :: proc() -> Client {
	return {request = "GET /large HTTP/1.1\r\nHost: 10.0.2.15\r\nConnection: close\r\n\r\n", expect_large = true}
}

client_sink :: proc() -> Client {
	return {request = fmt.aprintf("POST /sink HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", web.LARGE_SIZE), body = web.LARGE_SIZE, expect_text = fmt.aprintf("received %d bytes, fnv1a64 %016x", web.LARGE_SIZE, web.pattern_hash(web.LARGE_SIZE))}
}

// segment_by_hand_add adds a segment to send by hand, from a port of the peer to
// the port 80 of the machine.
segment_by_hand_add :: proc(state: ^Peer_Tcp, port: u16, sequence: u32, flags: tcp.Flags, bad_option := false) {
	length := bad_option ? tcp.HEADER_MSS : tcp.HEADER
	segment := make([]u8, length)
	header := tcp.Header{source_port = port, destination_port = SERVER_PORT, sequence = sequence, acknowledgment = 777, flags = flags, window = 8192, mss = bad_option ? 1460 : 0}
	tcp.header_write(segment, PEER_TCP_ADDRESS, MACHINE_TCP_ADDRESS, header, length)
	if bad_option {
		segment[21] = 0 // An option of length 0: the library refuses the segment.
		tcp.write_16(segment, 16, 0)
		tcp.write_16(segment, 16, tcp.checksum(PEER_TCP_ADDRESS, MACHINE_TCP_ADDRESS, segment))
	}
	append(&state.raw, segment)
}

// peer_case_start prepares the clients of a case.
peer_case_start :: proc(state: ^Peer_Tcp, name: string) -> bool {
	state.client_count = 0
	state.loss, state.reorder, state.duplicate = 0, 0, 0
	state.dropped, state.reordered, state.repeated = 0, 0, 0
	state.stray_reset, state.stray_sent = false, false
	state.acks_seen = 0
	state.seen_by = {}
	for segment in state.raw {
		delete(segment)
	}
	clear(&state.raw)
	state.raw_sent = 0
	state.fetch_at = 0
	state.random = 0x9E37_79B9_7F4A_7C15 ~ u64(len(name)) * 0x1234_5678
	add :: proc(state: ^Peer_Tcp, client: Client) {
		state.clients[state.client_count] = client
		state.client_count += 1
	}
	switch name {
	case "page":
		add(state, client_page(true))
	case "large", "large again":
		add(state, client_large())
	case "sink", "sink again":
		add(state, client_sink())
	case "loss":
		state.loss = 50
		add(state, client_large())
		add(state, client_sink())
	case "reorder":
		state.reorder = 100
		add(state, client_large())
		add(state, client_sink())
	case "duplicate":
		state.duplicate = 100
		add(state, client_large())
		add(state, client_sink())
	case "zero window":
		client := client_large()
		client.pause_after = 64 * 1024
		client.pause_time = 1500 * time.Millisecond
		add(state, client)
	case "reset":
		client := client_large()
		client.abort_after = 100 * 1024
		add(state, client)
	case "stray":
		// No client: one segment of no connection.
	case "challenge":
		client := client_page(true)
		client.challenge = true
		add(state, client)
	case "crowd":
		for _ in 0 ..< 16 {
			add(state, client_page(true))
		}
	case "leak":
		// B1: 64 ports each of a bare RST, a bare ACK, a SYN then a RST at
		// its exact sequence, and a SYN with an option that the library
		// refuses. With the old admission, 64 of them fill the admitted
		// remotes and each later SYN is refused. Then a page.
		for index in 0 ..< 64 {
			segment_by_hand_add(state, u16(30000 + index), 1000, {.Rst})
			segment_by_hand_add(state, u16(31000 + index), 1000, {.Ack})
			segment_by_hand_add(state, u16(32000 + index), 5000, {.Syn})
			segment_by_hand_add(state, u16(32000 + index), 5001, {.Rst})
			segment_by_hand_add(state, u16(33000 + index), 1000, {.Syn}, bad_option = true)
		}
		client := client_page(true)
		client.delayed = true
		add(state, client)
	case "slow":
		// B2: 32 connections of one host, 7 kinds in turn, then a page.
		for index in 0 ..< 32 {
			add(state, {attack = Attack(1 + index % 7)})
		}
		client := client_page(true)
		client.delayed = true
		add(state, client)
	case:
		return false
	}
	for &client in state.clients[:state.client_count] {
		client.connection = -1
		if client.delayed {
			continue
		}
		if !client_connect(state, &client) {
			return false
		}
	}
	state.started = time.tick_now()
	return true
}

client_connect :: proc(state: ^Peer_Tcp, client: ^Client) -> bool {
	index, error := tcp.connect(&state.table, MACHINE_TCP_ADDRESS, SERVER_PORT, peer_tcp_now(state))
	if error.kind != 0 {
		return false
	}
	state.seen_by[index] = {}
	client.connection = index
	client.hash = web.FNV_START
	client.attempts += 1
	return true
}

// peer_tcp_tick runs the case that the tool asked for: one step of the
// library, the frames, the clients.
peer_tcp_tick :: proc(peer: ^Peer, incoming: []tcp.Incoming) {
	state := peer.tcp
	wanted := sync.atomic_load(&state.wanted)
	running := wanted != sync.atomic_load(&state.done)
	if running && state.started_case != wanted {
		state.started_case = wanted
		if !peer_case_start(state, state.name) {
			peer_case_end(state, wanted, false, fmt.aprintf("the peer cannot start the case %s", state.name))
			return
		}
	}
	now := peer_tcp_now(state)
	for &place, index in state.places {
		place = u32(index)
	}
	output := tcp.Output{memory = state.memory, place_size = PEER_TCP_PLACE_SIZE, places = state.places[:], segments = state.segments[:]}
	_, event_count := tcp.step(&state.table, incoming, now, &output, state.events[:])
	for event in state.events[:event_count] {
		state.seen_by[event.connection] += event.kinds
	}
	if running {
		// The segments by hand: 8 at each tick, so that the receive places
		// of the machine keep up.
		for count := 0; count < 8 && state.raw_sent < len(state.raw); count += 1 {
			peer_tcp_send(peer, state.raw[state.raw_sent], false)
			state.raw_sent += 1
		}
		for &client in state.clients[:state.client_count] {
			client_run(peer, state, &client, now)
		}
		output_more := tcp.Output{memory = state.memory, place_size = PEER_TCP_PLACE_SIZE, places = state.places[output.count:], segments = state.segments[output.count:]}
		_, more_events := tcp.step(&state.table, nil, now, &output_more, state.events[:])
		for event in state.events[:more_events] {
			state.seen_by[event.connection] += event.kinds
		}
		output.count += output_more.count
	}
	for item in state.segments[:output.count] {
		segment := state.memory[int(item.place) * PEER_TCP_PLACE_SIZE:][:item.length]
		peer_tcp_send(peer, segment)
	}
	// Frames that wait for a reorder go after 5 ms at most.
	if len(state.held) > 0 && output.count == 0 {
		for frame in state.held {
			peer_send(peer, frame)
			delete(frame)
		}
		clear(&state.held)
	}
	if !running {
		return
	}
	if state.name == "stray" {
		peer_stray(peer, state, wanted)
		return
	}
	all_done := true
	for &client in state.clients[:state.client_count] {
		if client.phase == .Failed {
			peer_case_end(state, wanted, false, fmt.aprintf("case %s: connection %d: %s", state.name, client.connection, client.failure))
			return
		}
		if client.phase != .Done {
			all_done = false
		}
	}
	if all_done {
		peer_case_end(state, wanted, true, peer_case_summary(state))
		return
	}
	if time.tick_since(state.started) > CASE_TIME_LIMIT {
		phases := strings.builder_make(context.temp_allocator)
		for &client in state.clients[:state.client_count] {
			if client.connection < 0 {
				fmt.sbprintf(&phases, " [%v %v not connected]", client.attack, client.phase)
				continue
			}
			c := &state.connections[client.connection]
			fmt.sbprintf(&phases, " [%v %v %v body %d/%d]", client.attack, client.phase, c.state, client.bytes, client.response.content_length)
		}
		peer_case_end(state, wanted, false, fmt.aprintf("case %s: no end after %v:%s", state.name, CASE_TIME_LIMIT, strings.to_string(phases)))
	}
}

peer_case_end :: proc(state: ^Peer_Tcp, serial: int, passed: bool, result: string) {
	// The connections of the peer that the case leaves open end now.
	for &connection, index in state.connections {
		if connection.state != .Closed && connection.state != .Time_Wait {
			tcp.abort(&state.table, index)
		}
	}
	state.client_count = 0
	state.loss, state.reorder, state.duplicate = 0, 0, 0
	state.passed = passed
	state.result = result
	sync.atomic_store(&state.done, serial)
}

peer_case_summary :: proc(state: ^Peer_Tcp) -> string {
	retransmitted, outside: u64
	for &client in state.clients[:state.client_count] {
		if client.connection < 0 {
			continue
		}
		c := &state.connections[client.connection]
		retransmitted += c.retransmissions
		outside += c.duplicates
	}
	switch state.name {
	case "zero window":
		return fmt.aprintf("the peer read nothing for 1.5 s after 64 KiB: its window went to 0, and it answered %d segments of the server outside its window (the probes); then the 1 MiB came whole", outside)
	case "challenge":
		return fmt.aprintf("a RST in the window and a SYN on the connection: the server answered with %d ACKs and kept the connection, then served one more request", state.acks_seen)
	case "reset":
		return "the peer sent a RST after 100 KiB of /large"
	case "crowd":
		return fmt.aprintf("%d connections at once, each with GET / and a close from the peer", state.client_count)
	case "large", "large again":
		client := &state.clients[0]
		took := time.tick_diff(client.first_byte_at, client.last_byte_at)
		return fmt.aprintf("1 MiB from the server, at the peer: %.1f ms from its first byte to its last one, %.1f MB/s; the load of the host %s", time.duration_milliseconds(took), f64(web.LARGE_SIZE) / max(time.duration_seconds(took), 1e-9) / 1e6, host_load())
	case "leak":
		return fmt.aprintf("%d segments by hand from 256 ports: a bare RST, a bare ACK, a SYN then a RST, a SYN that the library refuses; then a page came in %.1f ms", len(state.raw), time.duration_milliseconds(state.fetch_at - state.raw_time))
	case "slow":
		accepted, refused, latest := 0, 0, time.Duration(0)
		for &client in state.clients[:state.client_count] {
			if client.attack == .None {
				continue
			}
			if client.refused {
				refused += 1
			} else {
				accepted += 1
				latest = max(latest, client.ended_at)
			}
		}
		return fmt.aprintf("32 connections of one host in 7 kinds: %d accepted, %d refused with a RST (24 for each remote); the server ended the last one after %.1f s; then a page came after %.1f s", accepted, refused, time.duration_seconds(latest), time.duration_seconds(state.fetch_at))
	}
	return fmt.aprintf("%d connections, the frames: %d dropped, %d reordered, %d repeated; the peer sent %d segments again", state.client_count, state.dropped, state.reordered, state.repeated, retransmitted)
}

@(rodata)
attack_texts := [Attack]string {
	.None          = "",
	.Idle          = "",
	.Half_Head     = "GET / HTTP/1.1\r\nHo",
	.Trickle       = "POST /sink HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: 1000000\r\n\r\n",
	.No_Fin        = "x\r\n\r\n",
	.Half_Head_Fin = "GET / HT",
	.Zero_Window   = "GET /large HTTP/1.1\r\nHost: 10.0.2.15\r\n\r\n",
	.Huge          = "POST /sink HTTP/1.1\r\nHost: 10.0.2.15\r\nContent-Length: 999999999999\r\n\r\n",
}

each_attack_ended :: proc(state: ^Peer_Tcp) -> bool {
	for &client in state.clients[:state.client_count] {
		if client.attack != .None && client.phase != .Done {
			return false
		}
	}
	return true
}

// host_load gives the load average of the host over one minute, from
// /proc/loadavg: the measures of the tests run while other machines run.
host_load :: proc() -> string {
	bytes, err := os.read_entire_file("/proc/loadavg", context.temp_allocator)
	if err != nil || len(bytes) == 0 {
		return "not known"
	}
	text := string(bytes)
	end := strings.index_byte(text, ' ')
	return strings.clone(text[:max(end, 0)])
}

// client_run moves one client of a case.
client_run :: proc(peer: ^Peer, state: ^Peer_Tcp, client: ^Client, now: u64) {
	if client.connection < 0 {
		// A delayed client: it connects when each attack ended and each
		// segment by hand went, 100 ms later, then each second after a RST.
		if !client.delayed || !each_attack_ended(state) || state.raw_sent < len(state.raw) {
			return
		}
		if len(state.raw) > 0 && state.raw_time == 0 {
			state.raw_time = time.tick_since(state.started)
			client.trickle_at = time.tick_now()
		}
		wait := client.attempts == 0 ? 100 * time.Millisecond : time.Second
		if client.trickle_at == {} || time.tick_since(client.trickle_at) >= wait {
			client_connect(state, client)
		}
		return
	}
	index := client.connection
	connection := &state.connections[index]
	fail :: proc(client: ^Client, text: string) {
		client.phase = .Failed
		client.failure = text
	}
	switch client.phase {
	case .Connect:
		#partial switch connection.state {
		case .Established:
			client.phase = .Request
		case .Closed:
			switch {
			case client.attack != .None && .Refused in state.seen_by[index]:
				client.refused = true
				client.phase = .Done
			case client.delayed && .Refused in state.seen_by[index]:
				client.connection = -1 // Again in one second.
				client.trickle_at = time.tick_now()
			case:
				fail(client, "the server did not accept the connection")
			}
		}
	case .Request:
		if client.attack != .None {
			text := attack_texts[client.attack]
			if len(text) > 0 {
				tcp.write(&state.table, index, transmute([]u8)text)
			}
			if client.attack == .Half_Head_Fin {
				tcp.close(&state.table, index)
			}
			client.trickle_at = time.tick_now()
			client.phase = .Response
			return
		}
		if connection.state != .Established {
			fail(client, fmt.aprintf("the connection is %v before the request was sent", connection.state))
			return
		}
		for client.written < len(client.request) {
			count, _ := tcp.write(&state.table, index, transmute([]u8)client.request[client.written:])
			if count == 0 {
				return
			}
			client.written += count
		}
		chunk: [16384]u8
		for client.body_sent < client.body {
			part := min(len(chunk), client.body - client.body_sent, tcp.send_room(&state.table, index))
			if part == 0 {
				return
			}
			web.pattern_fill(chunk[:part], client.body_sent)
			count, _ := tcp.write(&state.table, index, chunk[:part])
			client.body_sent += count
		}
		client.phase = .Response
	case .Response:
		if client.attack != .None {
			// The server must end the connection: a RST, or its FIN.
			kinds := state.seen_by[index]
			if connection.state == .Closed || .Reset in kinds || .Peer_Closed in kinds || .Timed_Out in kinds {
				client.ended_at = time.tick_since(state.started)
				client.phase = .Done
				return
			}
			#partial switch client.attack {
			case .Trickle:
				if time.tick_since(client.trickle_at) >= time.Second {
					tcp.write(&state.table, index, {'x'})
					client.trickle_at = time.tick_now()
				}
			case .Zero_Window:
			// It never reads: its window goes to 0 and stays there.
			case:
				chunk: [4096]u8
				for {
					count, _ := tcp.read(&state.table, index, chunk[:])
					if count == 0 {
						break
					}
				}
			}
			return
		}
		if client.paused {
			if time.tick_since(client.paused_at) < client.pause_time {
				return
			}
			client.paused = false
			client.pause_done = true
		}
		chunk: [16384]u8
		for {
			room := len(chunk)
			if client.pause_after > 0 && !client.pause_done && client.response.size != 0 {
				room = min(room, max(client.pause_after - client.bytes, 0))
				if room == 0 {
					client.paused = true
					client.paused_at = time.tick_now()
					return
				}
			}
			count, _ := tcp.read(&state.table, index, chunk[:room])
			if count == 0 {
				break
			}
			bytes := chunk[:count]
			if client.response.size == 0 {
				taken := min(count, len(client.head) - client.head_length)
				copy(client.head[client.head_length:], bytes[:taken])
				client.head_length += taken
				if web.head_end(client.head[:client.head_length]) == 0 {
					continue
				}
				ok: bool
				client.response, ok = web.head_read(client.head[:client.head_length])
				if !ok || client.response.status != 200 {
					fail(client, fmt.aprintf("a response with the status %d", client.response.status))
					return
				}
				bytes = client.head[client.response.size:client.head_length]
			}
			if client.bytes < len(client.content) {
				copy(client.content[client.bytes:], bytes)
			}
			if len(bytes) > 0 {
				if client.first_byte_at == {} {
					client.first_byte_at = time.tick_now()
				}
				client.last_byte_at = time.tick_now()
			}
			client.hash = web.fnv(client.hash, bytes)
			client.bytes += len(bytes)
			if client.abort_after > 0 && client.bytes >= client.abort_after {
				tcp.abort(&state.table, index)
				client.phase = .Done
				return
			}
		}
		if client.response.size == 0 || client.bytes < client.response.content_length {
			if connection.state == .Closed {
				fail(client, fmt.aprintf("the connection ended after %d bytes of the body", client.bytes))
			}
			return
		}
		if client.bytes != client.response.content_length {
			fail(client, fmt.aprintf("%d bytes for a Content-Length of %d", client.bytes, client.response.content_length))
			return
		}
		if client.expect_large && (client.bytes != web.LARGE_SIZE || client.hash != web.pattern_hash(web.LARGE_SIZE)) {
			fail(client, fmt.aprintf("/large: %d bytes and the hash %016x", client.bytes, client.hash))
			return
		}
		if client.expect_text != "" && !strings.has_prefix(string(client.content[:min(client.bytes, len(client.content))]), client.expect_text) {
			fail(client, fmt.aprintf("the body \"%s\" does not start with \"%s\"", string(client.content[:min(client.bytes, 80)]), client.expect_text))
			return
		}
		// The challenges, one at a time: a RST in the window but not at
		// RCV.NXT of the server, then a SYN on the connection. Each gets a
		// challenge ACK (RFC 5961), and the connection stays.
		if client.challenge && client.challenged == 0 {
			client.challenged = 1
			state.acks_seen = 0
			peer_inject(peer, state, connection, {.Rst}, connection.send_next + 1000)
			return
		}
		if client.challenge && client.challenged == 1 {
			if state.acks_seen < 1 {
				return
			}
			client.challenged = 2
			state.acks_seen = 0
			peer_inject(peer, state, connection, {.Syn}, connection.send_next + 77)
			return
		}
		if client.challenge && client.challenged == 2 {
			if state.acks_seen < 1 {
				return
			}
			if connection.state != .Established {
				fail(client, "the connection ended after the challenges")
				return
			}
			client.challenged = 3
			state.acks_seen = 2
			// One more request on the same connection.
			client.written, client.head_length, client.bytes, client.response = 0, 0, 0, {}
			client.hash = web.FNV_START
			client.phase = .Request
			return
		}
		client.phase = .Close
		if client.close_first {
			tcp.close(&state.table, index)
		}
	case .Close:
		// The peer closed first: TIME-WAIT here. The server closed first:
		// the peer answers its FIN and ends with LAST-ACK, then Closed.
		if client.close_first && connection.state == .Time_Wait {
			client.phase = .Done
			if client.delayed {
				state.fetch_at = time.tick_since(state.started)
			}
		} else if !client.close_first && connection.state == .Close_Wait {
			tcp.close(&state.table, index)
		} else if !client.close_first && connection.state == .Closed {
			client.phase = .Done
		}
	case .Done, .Failed:
	}
}

// peer_inject sends a segment that the library of the peer did not make,
// on the connection of a client.
peer_inject :: proc(peer: ^Peer, state: ^Peer_Tcp, connection: ^tcp.Connection, flags: tcp.Flags, sequence: u32) {
	segment: [tcp.HEADER]u8
	header := tcp.Header{source_port = connection.local_port, destination_port = connection.remote_port, sequence = sequence, flags = flags, window = 8192}
	tcp.header_write(segment[:], PEER_TCP_ADDRESS, MACHINE_TCP_ADDRESS, header, tcp.HEADER)
	peer_tcp_send(peer, segment[:], false)
}

// peer_stray sends an ACK from a port with no connection. The network
// service admits a remote on a SYN only, so the segment does not reach the
// server, and nothing answers it (B1): after 1 s, no RST came.
peer_stray :: proc(peer: ^Peer, state: ^Peer_Tcp, serial: int) {
	if !state.stray_sent {
		state.stray_sent = true
		state.started = time.tick_now()
		segment: [tcp.HEADER]u8
		header := tcp.Header{source_port = 45000, destination_port = SERVER_PORT, sequence = 1000, acknowledgment = 777_777, flags = {.Ack}, window = 8192}
		tcp.header_write(segment[:], PEER_TCP_ADDRESS, MACHINE_TCP_ADDRESS, header, tcp.HEADER)
		peer_tcp_send(peer, segment[:], false)
		return
	}
	if state.stray_reset {
		peer_case_end(state, serial, false, "a RST came for an ACK of a remote that sent no SYN: the network service gave the segment to the server")
		return
	}
	if time.tick_since(state.started) > time.Second {
		peer_case_end(state, serial, true, "an ACK of no connection from the port 45000: the network service did not give it to the server (a remote is admitted on a SYN only), and no RST came in 1 s")
	}
}

// peer_tcp_send sends a segment to the machine, with the changes of the case.
peer_tcp_send :: proc(peer: ^Peer, segment: []u8, change := true) {
	state := peer.tcp
	frame := make([]u8, max(34 + len(segment), 60))
	peer_ipv4(frame, peer.hardware[:], len(segment), 6)
	copy(frame[34:], segment)
	if change && peer_random(state) % 1000 < state.loss {
		state.dropped += 1
		delete(frame)
		return
	}
	copies := 1
	if change && peer_random(state) % 1000 < state.duplicate {
		copies = 2
		state.repeated += 1
	}
	if change && peer_random(state) % 1000 < state.reorder {
		state.reordered += 1
		append(&state.held, frame)
		return
	}
	for _ in 0 ..< copies {
		peer_send(peer, frame)
	}
	// A held frame goes after this one: the two are in the other order.
	for held in state.held {
		peer_send(peer, held)
		delete(held)
	}
	clear(&state.held)
	delete(frame)
}

// peer_tcp_frame takes a segment of the machine, that peer.odin checked up
// to its IPv4 header. It checks the TCP checksum with its own code.
peer_tcp_frame :: proc(peer: ^Peer, ip: []u8, segment: []u8) -> (incoming: tcp.Incoming, ok: bool) {
	if peer.tcp == nil {
		peer_wrong(peer, "a TCP segment, and the peer has no TCP case")
		return {}, false
	}
	state := peer.tcp
	if len(segment) < 20 || internet_sum(pseudo_sum(ip[12:16], ip[16:20], len(segment), 6), segment) != 0 {
		peer_wrong(peer, "a TCP segment with a wrong length or checksum")
		return {}, false
	}
	peer.tcp_segments += 1
	header, read := tcp.header_read(segment)
	if !read {
		peer_wrong(peer, "a TCP segment with a wrong header")
		return {}, false
	}
	if header.destination_port == 45000 && .Rst in header.flags && header.sequence == 777_777 {
		state.stray_reset = true
		return {}, false
	}
	if .Ack in header.flags && len(header.data) == 0 && header.flags & {.Syn, .Fin, .Rst} == {} {
		state.acks_seen += 1
	}
	// The changes of the case, for the segments of the machine too.
	if peer_random(state) % 1000 < state.loss {
		state.dropped += 1
		return {}, false
	}
	copied := make([]u8, len(segment), context.temp_allocator)
	copy(copied, segment)
	return {remote_address = MACHINE_TCP_ADDRESS, segment = copied}, true
}
