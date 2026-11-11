// The remote service: the calls of the host (docs/MODULE_CONTRACT.md,
// section 4, "A call from the host").
//
// The program holds one endpoint whose grant names the host (10.0.2.2, port
// remote.HOST_PORT), and a ring to the root service that serves Connect and
// Disconnect only, to the services that the root service names for it. A
// call request from the host names a service, an export and the bytes of
// the call region; this program copies them in the call region of its
// connection to the service, makes the isolated call, and sends the call
// answer. It does not read the descriptions: the host encoded the call with
// them, and the service checks the call region.
//
// It trusts nothing in a datagram (remote.request_check). It keeps the last
// call answer: a request with its number gets it again, and the call does
// not run two times.
//
// The window shows the counts of the requests, the answers and the
// refusals, the connections, and the last calls.
package remote_service

import "contract:datagram"
import "contract:errors"
import "contract:isolated"
import "contract:remote"
import "contract:ring"
import "support:display"
import "support:system"

GATEWAY :: 0x0A000202 // 10.0.2.2: the host.

PLACE_SIZE :: 2048
RECEIVE_COUNT :: 64 // Places 0 to 63 of the datagram region: call requests that arrive.
SEND_FIRST :: RECEIVE_COUNT // Places 64 to 255: the datagrams of call answers.
SEND_COUNT :: 256 - RECEIVE_COUNT
SEND_TAG :: 1000 // Tags from 1000: a Send of place tag - 1000. Under 1000: a Receive of the same place.
CALL_LIMIT :: 5000 // Milliseconds: a call that takes longer ends the connection.
CONNECT_LIMIT :: 10_000 // Milliseconds for the root service to make a connection: it can start the service first.
LOG_REFUSALS :: 16 // The refusals that this program writes on the log; it counts the others.

#assert(SEND_FIRST + SEND_COUNT == datagram.REGION_PAGES * system.PAGE_SIZE / PLACE_SIZE)
#assert(remote.DATAGRAM_LIMIT <= PLACE_SIZE)

// A connection to one service: the root service made it.
Connection :: struct {
	name:          [32]u8, // Empty: the place is free.
	program:       system.Handle, // The service, with the right Read: its state.
	ring_memory:   system.Handle,
	region_memory: system.Handle,
	calls:         ring.Ring,
	region:        []u8,
	hash:          [32]u8, // The hash of the module file of the service.
	tag:           u32,
	count:         u64, // The calls through this connection.
}

CONNECTION_CAPACITY :: 4

connections: [CONNECTION_CAPACITY]Connection

// The counts that the window shows.
Counts :: struct {
	requests:  u64, // The datagrams that arrived.
	calls:     u64, // The isolated calls that ran.
	failed:    u64, // The calls whose export gave a negative result with an error record.
	refused:   u64, // The requests that this program refused.
	repeated:  u64, // The requests with the number of the last answer: the answer went again.
	datagrams: u64, // The datagrams of the answers.
	bytes_in:  u64,
	bytes_out: u64,
	lost:      u64, // Sends that the network service refused.
}
counts: Counts

// The last calls, for the window.
Recent :: struct {
	service:      [32]u8,
	export:       u32,
	status:       remote.Status,
	call_status:  u32,
	text:         [96]u8, // A refusal: the sentence of its error record.
	text_count:   int,
	value:        i64,
	error:        i64, // The kind of the error record, or 0.
	bytes:        u64,
	microseconds: u64,
}
RECENT_CAPACITY :: 8
recent: [RECENT_CAPACITY]Recent
recent_count: u64

datagrams: ring.Ring
region: [^]u8
requests: ring.Ring // To the root service.
request_tag: u32
local_port: u64
draw_logged: bool

// The call requests that arrived and that wait: a place and its bytes.
Waiting :: struct {
	place: int,
	count: int,
}
waiting: [RECEIVE_COUNT]Waiting
waiting_first, waiting_count: int

// The places of the region for the datagrams of answers that are free.
free_sends: [SEND_COUNT]int
free_count: int

// The last call answer: its header, and the bytes of its result.
last_number: u64
last_answer: remote.Answer
last_result: [remote.REGION_SIZE]u8
last_total: int

place_of :: proc "contextless" (place: int) -> []u8 {
	return region[place * PLACE_SIZE:][:PLACE_SIZE]
}

datagram_request :: proc "contextless" (command: datagram.Command, tag: u32, values: [7]u64) {
	record := ring.Record{kind = u32(command), tag = tag, values = values}
	for !system.send(&datagrams.commands, record) {
		wait: system.Wait
		system.wait_room(&wait, &datagrams.commands)
		system.wait_end(&wait)
	}
}

post :: proc "contextless" (place: int) {
	datagram_request(.Receive, u32(place), {0 = u64(place * PLACE_SIZE), 1 = PLACE_SIZE})
}

// completions_take reads the completions of the datagram ring: a Send frees
// its place, a Receive waits for this program to read it.
completions_take :: proc "contextless" () {
	for _ in 0 ..< datagram.RING_CAPACITY {
		record, ok := system.receive(&datagrams.completions)
		if !ok {
			return
		}
		status := datagram.Status(record.kind)
		if record.tag >= SEND_TAG {
			place := int(record.tag - SEND_TAG)
			if place >= SEND_FIRST && place < SEND_FIRST + SEND_COUNT && free_count < SEND_COUNT {
				free_sends[free_count] = place
				free_count += 1
			}
			if status != .Ok {
				counts.lost += 1
			}
			continue
		}
		place := int(record.tag)
		if place >= RECEIVE_COUNT {
			continue
		}
		if status != .Ok || waiting_count == RECEIVE_COUNT {
			post(place)
			continue
		}
		waiting[(waiting_first + waiting_count) % RECEIVE_COUNT] = {place, int(min(record.values[1], PLACE_SIZE))}
		waiting_count += 1
	}
}

// send_place gives a free place for a datagram of an answer: it waits for
// the network service to copy one when none is free.
send_place :: proc "contextless" () -> int {
	for free_count == 0 {
		wait: system.Wait
		system.wait_records(&wait, &datagrams.completions)
		system.wait_end(&wait, system.time() + 1000)
		completions_take()
	}
	free_count -= 1
	return free_sends[free_count]
}

// answer_send sends a call answer: the header and the result, in as many
// datagrams as it needs.
answer_send :: proc "contextless" (header: remote.Answer, result: []u8) {
	for part in 0 ..< remote.part_count(u64(len(result))) {
		place := send_place()
		bytes, ok := remote.answer_write(place_of(place), header, result, part)
		if !ok {
			free_sends[free_count] = place
			free_count += 1
			return
		}
		datagram_request(.Send, SEND_TAG + u32(place), {0 = u64(place * PLACE_SIZE), 1 = u64(len(bytes)), 2 = GATEWAY, 3 = remote.HOST_PORT})
		counts.datagrams += 1
		counts.bytes_out += u64(len(bytes))
	}
}

// answer_keep keeps a call answer for a request with the same number, and
// sends it.
answer_keep :: proc "contextless" (header: remote.Answer, result: []u8) {
	if header.number != 0 {
		last_number = header.number
		last_answer = header
		last_total = copy(last_result[:], result)
	}
	answer_send(header, result)
}

// refuse answers a request that this program refused, and writes the
// sentence of its error record on the log while the log has room for it.
refuse :: proc "contextless" (number: u64, error: errors.Error_Record, service: string = "", hash: [32]u8 = {}) {
	counts.refused += 1
	error := error
	if counts.refused <= LOG_REFUSALS {
		buffer: [256]u8
		writer := system.Writer{buffer = buffer[:]}
		field := ""
		if error.argument >= 1 && error.argument <= len(remote.REQUEST_FIELD_NAMES) {
			field = remote.REQUEST_FIELD_NAMES[error.argument - 1]
		}
		system.error_text(&writer, &error, "remote", field)
		if counts.refused == LOG_REFUSALS {
			system.log("remote: refused a request: ", system.written(&writer), "; the next refusals are counted only")
		} else {
			system.log("remote: refused a request: ", system.written(&writer))
		}
	}
	answer := remote.Answer{status = .Refused, number = number, error = error, hash = hash}
	answer_keep(answer, nil)
	item := recent_add(service, 0, answer, 0, 0)
	buffer: [256]u8
	writer := system.Writer{buffer = buffer[:]}
	field := ""
	if error.argument >= 1 && error.argument <= len(remote.REQUEST_FIELD_NAMES) {
		field = remote.REQUEST_FIELD_NAMES[error.argument - 1]
	}
	system.error_text(&writer, &error, "remote", field)
	item.text_count = copy(item.text[:], system.written(&writer))
}

recent_add :: proc "contextless" (service: string, export: u32, answer: remote.Answer, bytes: u64, microseconds: u64) -> ^Recent {
	item := &recent[recent_count % RECENT_CAPACITY]
	item^ = {export = export, status = answer.status, call_status = answer.call_status, value = answer.value, error = answer.error.kind, bytes = bytes, microseconds = microseconds}
	copy(item.service[:len(item.service) - 1], service)
	recent_count += 1
	return item
}

// connection_find gives the connection to a service, and asks the root
// service for one when this program has none. On a failure it gives the
// error record of the answer.
connection_find :: proc "contextless" (name: string) -> (connection: ^Connection, error: errors.Error_Record) {
	free: ^Connection
	for &item in connections {
		if item.name[0] == 0 {
			free = &item
		} else if remote.name_text(&item.name) == name {
			return &item, {}
		}
	}
	if free == nil {
		return nil, errors.error_make(.Full, .None, remote.FIELD_SERVICE, 0, CONNECTION_CAPACITY)
	}
	packed := system.name_pack(name)
	request_tag += 1
	if !system.send(&requests.commands, ring.Record{kind = u32(system.Root_Command.Connect), tag = request_tag, values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}}) {
		return nil, errors.error_make(.Refused, .None, remote.FIELD_SERVICE, 0, 0, i64(system.Status.No_Slot))
	}
	limit := system.time() + CONNECT_LIMIT
	for {
		for record in system.receive(&requests.completions) {
			if record.tag != request_tag {
				continue
			}
			status := system.Status(record.kind)
			#partial switch status {
			case .Ok:
			case .Bad_Handle:
				// No service runs with this name.
				return nil, errors.error_make(.Absent, .None, remote.FIELD_SERVICE)
			case .No_Right:
				return nil, errors.error_make(.No_Grant, .Connection, remote.FIELD_SERVICE)
			case:
				return nil, errors.error_make(.Refused, .None, remote.FIELD_SERVICE, 0, 0, i64(status))
			}
			connection = free
			connection^ = {
				program       = system.Handle(record.values[0]),
				ring_memory   = system.Handle(record.values[1]),
				region_memory = system.Handle(record.values[2]),
				hash          = transmute([32]u8)[4]u64{record.values[3], record.values[4], record.values[5], record.values[6]},
			}
			copy(connection.name[:len(connection.name) - 1], name)
			ring_status: system.Status
			connection.calls, ring_status = system.ring_open(connection.ring_memory)
			address, map_status := system.memory_map(connection.region_memory)
			if ring_status != .Ok || map_status != .Ok {
				connection_end(connection, false)
				return nil, errors.error_make(.Refused, .None, remote.FIELD_SERVICE, 0, 0, i64(ring_status != .Ok ? ring_status : map_status))
			}
			connection.region = ([^]u8)(address)[:system.memory_size(connection.region_memory) * system.PAGE_SIZE]
			system.log("remote: connected to the service ", name)
			return connection, {}
		}
		wait: system.Wait
		system.wait_records(&wait, &requests.completions)
		if system.wait_end(&wait, limit) >= limit {
			return nil, errors.error_make(.Over_Limit, .Milliseconds, remote.FIELD_SERVICE, CONNECT_LIMIT, CONNECT_LIMIT)
		}
	}
}

// connection_end closes what this program holds of a connection. tell: ask
// the root service to end it too (the service still runs).
connection_end :: proc "contextless" (connection: ^Connection, tell: bool) {
	if tell {
		packed := system.name_pack(remote.name_text(&connection.name))
		request_tag += 1
		system.send(&requests.commands, ring.Record{kind = u32(system.Root_Command.Disconnect), tag = request_tag, values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}})
	}
	if connection.calls.head != nil {
		system.ring_close(&connection.calls)
	}
	if connection.region != nil {
		system.memory_unmap(raw_data(connection.region))
	}
	for handle in ([3]system.Handle{connection.program, connection.ring_memory, connection.region_memory}) {
		if handle != 0 {
			system.close(handle)
		}
	}
	connection^ = {}
}

// call makes the isolated call of a request through a connection, and gives
// the completion. On a failure of the connection it gives an error record.
call :: proc "contextless" (connection: ^Connection, request: remote.Request, arguments: []u8) -> (completion: ring.Record, error: errors.Error_Record, ok: bool) {
	copy(connection.region, arguments)
	connection.tag += 1
	if !system.send(&connection.calls.commands, ring.Record{kind = request.export, tag = connection.tag, values = {0 = 0, 1 = u64(request.record_size)}}) {
		return {}, errors.error_make(.Full, .Records, 0, 0, i64(ring.capacity(&connection.calls.commands))), false
	}
	start := system.time()
	limit := start + CALL_LIMIT
	for {
		// The stop of the service is an event of this thread.
		wait := system.wait_begin()
		for _ in 0 ..< ring.CAPACITY {
			record, has := system.receive(&connection.calls.completions)
			if !has {
				break
			}
			if record.tag == connection.tag {
				return record, {}, true
			}
		}
		if state, _ := system.program_state(connection.program); state == .Stopped || state == .None {
			system.log("remote: the service ", remote.name_text(&connection.name), " stopped during a call")
			connection_end(connection, false)
			return {}, errors.error_make(.State, .None, remote.FIELD_SERVICE, 0, 0, i64(state)), false
		}
		system.wait_records(&wait, &connection.calls.completions)
		if system.wait_spin(&wait) {
			continue
		}
		if now := system.wait_end(&wait, limit); now >= limit {
			system.log("remote: the service ", remote.name_text(&connection.name), " did not answer in ", u64(CALL_LIMIT), " ms: the connection ends")
			connection_end(connection, true)
			return {}, errors.error_make(.Over_Limit, .Milliseconds, remote.FIELD_EXPORT, i64(now - start), CALL_LIMIT), false
		}
	}
}

// serve reads one call request, makes the call, and answers it.
serve :: proc "contextless" (bytes: []u8) {
	counts.requests += 1
	counts.bytes_in += u64(len(bytes))
	start := system.nanoseconds()
	request, arguments, error, ok := remote.request_check(bytes, remote.REGION_SIZE)
	if !ok {
		refuse(request.number, error)
		return
	}
	service := remote.name_text(&request.service)
	if request.number == last_number {
		counts.repeated += 1
		answer_send(last_answer, last_result[:last_total])
		return
	}
	connection, connection_error := connection_find(service)
	if connection == nil {
		refuse(request.number, connection_error, service)
		return
	}
	if connection.hash != request.hash {
		refuse(request.number, errors.error_make(.Bad_Value, .None, remote.FIELD_HASH), service, connection.hash)
		return
	}
	if u64(len(connection.region)) < remote.REGION_SIZE {
		refuse(request.number, errors.error_make(.Too_Small, .Bytes, remote.FIELD_SERVICE, i64(len(connection.region)), remote.REGION_SIZE), service, connection.hash)
		return
	}
	completion, call_error, called := call(connection, request, arguments)
	if !called {
		refuse(request.number, call_error, service, connection.hash)
		return
	}
	connection.count += 1
	counts.calls += 1
	answer := remote.Answer {
		status      = .Ok,
		call_status = completion.kind,
		number      = request.number,
		value       = i64(completion.values[0]),
		hash        = connection.hash,
	}
	result: []u8
	if isolated.Status(completion.kind) == .Ok {
		if request.error_start != 0 && answer.value < 0 {
			// The service wrote it: values only, copied as values.
			answer.error = (^errors.Error_Record)(raw_data(connection.region[request.error_start:]))^
			counts.failed += 1
		} else {
			result = connection.region[request.result_start:][:remote.result_bytes(request, answer.value)]
		}
	}
	answer_keep(answer, result)
	recent_add(service, request.export, answer, u64(len(result)), (system.nanoseconds() - start) / 1000)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, has_window := display.open(ctx, WIDTH, HEIGHT, "remote")
	status: system.Status
	if datagrams, status = system.ring_open(ctx.handles[datagram.GRANT_RING]); status != .Ok {
		system.log("remote: no endpoint: the program has no grant of the network")
		system.stop(1)
	}
	address, map_status := system.memory_map(ctx.handles[datagram.GRANT_REGION], {.Write})
	if map_status != .Ok || system.memory_size(ctx.handles[datagram.GRANT_REGION]) < datagram.REGION_PAGES {
		system.log("remote: no datagram region")
		system.stop(1)
	}
	region = ([^]u8)(address)
	if requests, status = system.ring_open(ctx.handles[system.GRANT_ROOT]); status != .Ok {
		system.log("remote: no ring to the root service")
		system.stop(1)
	}
	for place in SEND_FIRST ..< SEND_FIRST + SEND_COUNT {
		free_sends[free_count] = place
		free_count += 1
	}
	// The grant and the local port of the endpoint, before the places of
	// the requests: no other completion arrives before this one.
	datagram_request(.Info, SEND_TAG - 1, {})
	for {
		record, ok := system.receive(&datagrams.completions)
		if ok && record.tag == SEND_TAG - 1 {
			granted_address, granted_port, _ := datagram.grant_unpack(record.values[6])
			local_port = record.values[1]
			system.log("remote: ok, an endpoint with the grant ", granted_address == GATEWAY ? "10.0.2.2" : "another address", " port ", u64(granted_port), "; the call requests of the host arrive there")
			break
		}
		wait: system.Wait
		system.wait_records(&wait, &datagrams.completions)
		system.wait_end(&wait, system.time() + 1000)
	}
	for place in 0 ..< RECEIVE_COUNT {
		post(place)
	}
	// The host learns the local port of the endpoint from this answer.
	answer_send({status = .Started}, nil)
	drawn: u64
	dirty := true
	for {
		completions_take()
		for waiting_count > 0 {
			item := waiting[waiting_first]
			waiting_first = (waiting_first + 1) % RECEIVE_COUNT
			waiting_count -= 1
			// One copy: the network service writes the region.
			bytes: [PLACE_SIZE]u8
			copy(bytes[:item.count], place_of(item.place)[:item.count])
			post(item.place)
			serve(bytes[:item.count])
			dirty = true
			completions_take()
		}
		now := system.time()
		if has_window {
			for _ in display.next_event(&window) {}
			// The window changes at most ten times in one second: a burst of
			// calls does not wait for the drawing.
			if dirty && now - drawn >= 100 {
				start := system.nanoseconds()
				draw(&window)
				drawn, dirty = now, false
				// The time of one picture, one time, when the window has calls
				// to show (docs/DESIGN.md, section 7).
				if !draw_logged && counts.calls >= 1000 {
					draw_logged = true
					system.log("remote: the window drew one picture in ", (system.nanoseconds() - start) / 1000, " us")
				}
			}
		}
		wait: system.Wait
		system.wait_records(&wait, &datagrams.completions)
		if has_window {
			display.wait_events(&wait, &window)
		}
		if system.wait_spin(&wait) {
			continue
		}
		system.wait_end(&wait, dirty ? drawn + 100 : system.WAIT_FOREVER)
	}
}
