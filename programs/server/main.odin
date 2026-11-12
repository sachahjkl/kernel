// A simple HTTP/1.1 server of this system (RFC 9110, RFC 9112): TCP in the
// program (support/tcp), one thread, one table of connections, and records
// of fixed size for all its state. It allocates nothing.
//
// What it can reach comes from its grants only, with no ambient access:
//   a segment endpoint with a listen grant: the TCP port 80, and the
//       remotes that send a SYN to it;
//   a private store in the storage service, as each program has: the pages
//       that it serves, by name;
//   a service ring: the console calls its exports server.put,
//       server.pages, server.remove and server.served, functions with
//       typed parameters.
// No shared folder: a person puts a page with server.put from the console.
// PUT and DELETE over HTTP are refused (405): the network is not
// authenticated.
//
// main.odin: the TCP side and the loop. http.odin: the requests and the
// answers. pages.odin: the pages of the store, and the exports. draw.odin:
// the window.
package server

import "contract:date"
import "contract:datagram"
import "contract:ring"
import "support:display"
import "support:network"
import "support:storage"
import "support:random"
import "support:system"
import "support:tcp"

CAPACITY :: 48 // Connections at one time, with the ones in TIME-WAIT.
REMOTE_LIMIT :: 24 // The open connections of one remote address: half the table (tcp.Table.remote_limit).
SEND_SIZE :: 64 * 1024
RECEIVE_SIZE :: 32 * 1024
BUFFER_PAGES :: CAPACITY * (SEND_SIZE + RECEIVE_SIZE) / system.PAGE_SIZE

// The datagram region: 256 places of 2048 bytes.
PLACE_SIZE :: 2048
PLACE_COUNT :: datagram.REGION_PAGES * system.PAGE_SIZE / PLACE_SIZE
RECEIVE_PLACES :: 96 // Places 0 to 95: segments that arrive. The others: segments to send.
SEND_TAG :: 1000 // Tags from 1000: a Send of place tag - 1000.
CALL_TAG :: 100_000 // Info and Release.
// Commands that the ring did not take: they go at the next pass. A proven
// bound, not a guess: a Send or a Receive names
// one place, and a place is in one command at most: PLACE_COUNT; a Release
// is held only while fewer than RELEASE_WAITING_CAPACITY are held. So the
// held commands never pass HELD_CAPACITY; command_push_or_hold checks it.
RELEASE_WAITING_CAPACITY :: 2 * CAPACITY + RECEIVE_PLACES
HELD_CAPACITY :: PLACE_COUNT + RELEASE_WAITING_CAPACITY

CONNECTION_HISTORY :: 16 // Connections that ended, that the window still shows.

// A connection that ended, as the window shows it.
Ended_Connection :: struct {
	record: tcp.Connection,
	how:    string,
	known:  bool,
}

table: tcp.Table
connections: [CAPACITY]tcp.Connection
ended_connections: [CONNECTION_HISTORY]Ended_Connection
ended_connection_next: int

endpoint: ring.Ring
region: []u8
free_places: [PLACE_COUNT - RECEIVE_PLACES]u32
free_count: int
segments: [PLACE_COUNT - RECEIVE_PLACES]tcp.Outgoing
events: [CAPACITY]tcp.Event
local_address: u32
listen_port: u16
program_generator: random.Generator // The random generator of this program, from the seed of its starter.
held_commands: [HELD_CAPACITY]ring.Record // Commands that the ring did not take.
held_command_count: int
held_release_count: int // The Releases among the held commands.
releases_lost: u64 // Releases that found releases_waiting full: the network service frees their place after ADMITTED_IDLE.
store_client: storage.Client
store_connected: bool
service: system.Service

// Totals and measures of TCP.
accepted: u64
most_open: int
bytes_in, bytes_out: u64
retransmissions, resets, timeouts: u64
aborted_count: u64 // Connections that this server ended for a limit.
released_strays: u64 // Remotes released because a segment of theirs had no record.
handshake_last, handshake_least: u64 // Microseconds.
draw_time: u64
start_time: u64

fail :: proc "contextless" (text: string) -> ! {
	system.log("server: ", text)
	system.stop(1)
}

now_microseconds :: proc "contextless" () -> u64 {
	return system.nanoseconds() / 1000
}

place_bytes :: proc "contextless" (place: u32) -> []u8 {
	return region[int(place) * PLACE_SIZE:][:PLACE_SIZE]
}

// command_push_or_hold puts a command in the ring. A full ring keeps it for
// the next pass: a Send, a Receive or a Release is never lost, so no place
// and no admitted remote leaks.
command_push_or_hold :: proc "contextless" (record: ring.Record) {
	if held_command_count == 0 && ring.push(&endpoint.commands, record) {
		return
	}
	if held_command_count == HELD_CAPACITY {
		fail("the held commands passed their proven bound")
	}
	held_commands[held_command_count] = record
	held_command_count += 1
	if record.kind == u32(datagram.Command.Release) {
		held_release_count += 1
	}
}

held_commands_push :: proc "contextless" () {
	done := 0
	for done < held_command_count && ring.push(&endpoint.commands, held_commands[done]) {
		if held_commands[done].kind == u32(datagram.Command.Release) {
			held_release_count -= 1
		}
		done += 1
	}
	copy(held_commands[:], held_commands[done:held_command_count])
	held_command_count -= done
}

post :: proc "contextless" (place: u32) {
	command_push_or_hold(ring.Record{kind = u32(datagram.Command.Receive), tag = place, values = {0 = u64(place) * PLACE_SIZE, 1 = PLACE_SIZE}})
}

address_text :: proc "contextless" (buffer: []u8, address: u32, port: u16) -> string {
	writer := system.Writer{buffer = buffer}
	network.address_write(&writer, address)
	system.write_bytes(&writer, transmute([]u8)string(" port "))
	system.write_unsigned(&writer, u64(port))
	return system.written(&writer)
}

// kilobytes_per_second gives kilobytes in one second.
kilobytes_per_second :: proc "contextless" (bytes: u64, nanoseconds: u64) -> u64 {
	return bytes * 1_000_000 / max(nanoseconds, 1)
}

// megabytes writes a rate of kilobytes in one second as "12.3 MB/s".
megabytes :: proc "contextless" (buffer: []u8, kilobytes: u64) -> string {
	return system.format(buffer, kilobytes / 1000, ".", kilobytes % 1000 / 100, " MB/s")
}

// A release asks the network service to forget a remote, after the RST or
// the last segment of its connection: a Release before them makes the
// service refuse them. So a release waits until the Sends of the pass are
// in the ring, and until its record has no RST to send (connection -1: no
// record).
Release_Waiting :: struct {
	address:    u32,
	port:       u16,
	connection: int,
}
releases_waiting: [RELEASE_WAITING_CAPACITY]Release_Waiting
releases_waiting_count: int

release :: proc "contextless" (address: u32, port: u16, connection := -1) {
	if releases_waiting_count == len(releases_waiting) {
		releases_send_now()
	}
	if releases_waiting_count < len(releases_waiting) {
		releases_waiting[releases_waiting_count] = {address, port, connection}
		releases_waiting_count += 1
	} else {
		releases_lost += 1
	}
}

// releases_send_now sends each release whose record sent its RST.
releases_send_now :: proc "contextless" () {
	kept := 0
	for item in releases_waiting[:releases_waiting_count] {
		// A release waits for the RST of its record, and for room among
		// the held commands (the bound of HELD_CAPACITY).
		if (item.connection >= 0 && connections[item.connection].reset_pending) || held_release_count >= RELEASE_WAITING_CAPACITY {
			releases_waiting[kept] = item
			kept += 1
			continue
		}
		command_push_or_hold(ring.Record{kind = u32(datagram.Command.Release), tag = CALL_TAG, values = {0 = u64(item.address), 1 = u64(item.port)}})
	}
	releases_waiting_count = kept
}

// The log lines of the ends of connections, in one second at most: a remote
// that opens and closes connections must not fill the log limit of the
// program, or the lines of its other work are lost. The others are counted, and one line
// says how many.
CONNECTION_LOG_LIMIT :: 50
connection_log_second: u64
connection_log_count: u64
connections_not_logged: u64

// connection_log_second_end writes, after a second, how many ends of
// connections were not on the log in it. Each pass calls it, so the line
// does not wait for the next end of a connection.
connection_log_second_end :: proc "contextless" () {
	second := system.time() / 1000
	if second == connection_log_second {
		return
	}
	if connections_not_logged > 0 {
		system.log("server: ", connections_not_logged, " ends of connections in one second are not on the log (the limit is 50)")
	}
	connection_log_second, connection_log_count, connections_not_logged = second, 0, 0
}

// connection_log_allowed says if one more line of the end of a connection
// goes on the log in this second.
connection_log_allowed :: proc "contextless" () -> bool {
	connection_log_second_end()
	if connection_log_count < CONNECTION_LOG_LIMIT {
		connection_log_count += 1
		return true
	}
	connections_not_logged += 1
	return false
}

// ended_log writes the end of a connection on the log and in the history:
// when it ends, or when it enters TIME-WAIT (this side closed first: the
// record stays 10 s more, and has nothing more to say).
ended_log :: proc "contextless" (index: int, how: string) {
	connection := &connections[index]
	session := &sessions[index]
	if session.logged {
		return
	}
	session.logged = true
	ended_connections[ended_connection_next] = {record = connection^, how = how, known = true}
	ended_connection_next = (ended_connection_next + 1) % CONNECTION_HISTORY
	bytes_in += connection.bytes_received
	bytes_out += connection.bytes_sent
	retransmissions += connection.retransmissions
	if !connection_log_allowed() {
		keep_alive_measure(index)
		return
	}
	remote_text: [32]u8
	system.log("server: ", address_text(remote_text[:], connection.remote_address, connection.remote_port), " ", how, ": ", u64(session.requests), " requests, in ", connection.bytes_received, ", out ", connection.bytes_sent, ", srtt ", connection.smoothed_rtt, " us, ", connection.retransmissions, " retransmissions, ", connection.probes, " probes, ", connection.challenges, " challenges")
	keep_alive_measure(index)
}

// ended takes the end of a connection: the record is free after this
// event, and the network service forgets its remote. A passive open that
// never reached Established (a SYN, then a RST or no ACK) is not on the
// log: one host can send many.
ended :: proc "contextless" (index: int, how: string) {
	connection := &connections[index]
	if connection.established_at != 0 {
		ended_log(index, how)
	}
	release(connection.remote_address, connection.remote_port, index)
	sessions[index] = {}
}

// aborted ends a connection for a limit of this server: a RST, the log, and
// the release of the remote. tcp.abort gives no event.
aborted :: proc "contextless" (index: int, how: string) {
	aborted_count += 1
	tcp.abort(&table, index)
	ended(index, how)
}

event_take :: proc "contextless" (event: tcp.Event) {
	index := int(event.connection)
	connection := &connections[index]
	if .Accepted in event.kinds {
		accepted += 1
		sessions[index] = {}
		sessions[index].progress_at = system.time()
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
		http_remote_closed(index)
	}
}

// exchange runs one step of the table: the segments that arrived, the
// events, the requests and the answers, and the segments to send.
exchange :: proc "contextless" (incoming: []tcp.Incoming) -> (deadline: u64) {
	now := now_microseconds()
	output := tcp.Output{memory = region, place_size = PLACE_SIZE, places = free_places[:free_count], segments = segments[:]}
	count: int
	deadline, count = tcp.step(&table, incoming, now, &output, events[:])
	// The events and the answers write data; the next step sends it. A few
	// rounds end the work of one pass; what is left waits for the next pass.
	for round := 0; round < 4; round += 1 {
		for event in events[:count] {
			event_take(event)
		}
		for &connection, index in connections {
			if connection.state == .Time_Wait {
				ended_log(index, "closed, this server first")
			}
			if connection.state == .Established || connection.state == .Close_Wait {
				http_connection_work(index)
			}
			// The limits: also after this server closed, while it has bytes
			// to send (FIN-WAIT-1, CLOSING, LAST-ACK).
			#partial switch connection.state {
			case .Established, .Close_Wait, .Fin_Wait_1, .Fin_Wait_2, .Closing, .Last_Ack:
				if round == 0 {
					http_limits(index, system.time())
				}
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
		event_take(event)
	}
	// Send each segment: the ring takes them, then one wake.
	for item in segments[:output.count] {
		command_push_or_hold(ring.Record{kind = u32(datagram.Command.Send), tag = SEND_TAG + item.place, values = {0 = u64(item.place) * PLACE_SIZE, 1 = u64(item.length), 2 = u64(item.remote_address), 3 = u64(item.remote_port)}})
		// A RST for a segment of no connection: no connection will release
		// this remote, so it is released after the RST.
		if item.connection < 0 {
			release(item.remote_address, item.remote_port)
		}
	}
	// The places that the step used are not free until their Send completes.
	free_count -= output.count
	copy(free_places[:free_count], free_places[output.count:output.count + free_count])
	// A segment whose connection has no record (a RST or an ACK of a
	// connection that ended, a segment that the library refused): no event
	// will release its remote, so it is released now.
	for item in incoming {
		header, read := tcp.header_read(item.segment)
		if !read || tcp.find(&table, item.remote_address, header.destination_port, header.source_port) < 0 {
			if len(item.segment) >= 4 {
				released_strays += 1
				release(item.remote_address, tcp.read_16(item.segment, 0))
			}
		}
	}
	// The remotes of records in TIME-WAIT that a SYN took: no Closed event
	// comes for them.
	for remote in table.reclaimed_remotes[:table.reclaimed_remote_count] {
		release(remote.address, remote.port)
	}
	table.reclaimed_remote_count = 0
	// After the Sends of this pass: the releases.
	releases_send_now()
	connection_log_second_end()
	// The limits of the open connections, the measure of each second and
	// the line of the ends that were not logged need a time even when no
	// segment and no timer of TCP comes.
	if tcp.open_count(&table) > 0 || second_requests > 0 || connections_not_logged > 0 {
		deadline = min(deadline, now + 1_000_000)
	}
	return deadline
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	if !random.generator_from_context(&program_generator, ctx) {
		system.log("server: no random seed in the context")
		system.stop(1)
	}
	date_page = date.page_of(ctx)
	window, ok := display.open(ctx, WIDTH, HEIGHT, "server")
	if !ok {
		system.stop(1)
	}
	start_time = system.time()
	service, _ = system.service_open(ctx)
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
	// program, which gives the library all the memory that it uses.
	memory, memory_status := system.memory_create(BUFFER_PAGES)
	buffers, buffers_status := system.memory_map(memory, {.Write})
	if memory_status != .Ok || buffers_status != .Ok {
		fail("no memory for the buffers of the connections")
	}
	// The secret of the initial sequence numbers (RFC 6528): 32 bytes of
	// the generator of this program (docs/RANDOMNESS.md).
	secret: [32]u8
	random.fill(&program_generator, secret[:])
	if error := tcp.table_init(&table, connections[:], ([^]u8)(buffers)[:BUFFER_PAGES * system.PAGE_SIZE], SEND_SIZE, RECEIVE_SIZE, local_address, secret); error.kind != 0 {
		fail("the connection table refused its memory")
	}
	table.listen_port = listen_port
	secret = {}
	table.remote_limit = REMOTE_LIMIT
	// The pages of the private store.
	pages_load(ctx)
	for place in 0 ..< RECEIVE_PLACES {
		post(u32(place))
	}
	for place in RECEIVE_PLACES ..< PLACE_COUNT {
		free_places[free_count] = u32(place)
		free_count += 1
	}
	system.wake_reader(&endpoint.commands)
	system.log("server: listening on the TCP port ", u64(listen_port), ", a table of ", u64(CAPACITY), " connections, the secret of the initial sequence numbers from the generator of the program")

	incoming: [RECEIVE_PLACES]tcp.Incoming
	used: [RECEIVE_PLACES]u32
	last_draw: u64
	changed := true
	for {
		wait := system.wait_begin()
		held_commands_push()
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
		second_measure(system.time())
		// The calls of the console: server.put, server.pages, ...
		calls_before := service.calls
		system.service_run(&service)
		if count > 0 || service.calls != calls_before {
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
		system.service_wait(&wait, &service)
		limit := changed ? last_draw + 100 : system.WAIT_FOREVER
		if deadline != max(u64) {
			limit = min(limit, deadline / 1000 + 1)
		}
		system.wait_end(&wait, limit)
	}
}
