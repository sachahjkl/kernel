package tcp

// The connections of one program: a table of records of fixed size, with
// the buffers in one block of memory that the caller gives (property 14).
// The library allocates nothing and calls no kernel operation; one call,
// step, reads a batch of segments, runs the timers and writes the segments
// to send. docs/NETWORK.md has the rules and their sources.

import "contract:blake3"
import "contract:errors"

RTO_INITIAL :: 1_000_000 // Microseconds before the first retransmission (RFC 6298 2.1).
RTO_LEAST :: 200_000 // Not the 1 s of RFC 6298 2.4: the round trips of the link are under 1 ms.
RTO_MOST :: 60_000_000
RETRIES :: 8 // Timeouts in a row that end a connection.
DELAYED_ACK :: 40_000 // The most that an ACK waits.
TIME_WAIT :: 10_000_000 // 2 MSL, with an MSL of 5 s for one link.
RANGE_CAPACITY :: 8 // The ranges of data after a hole that a connection remembers.
SLOW_START_THRESHOLD :: 1 << 30 // At the start: no threshold (RFC 5681 3.1).
FIN_WAIT_2 :: 20_000_000 // The most that a record waits for the FIN of the remote after the ACK of its own.
SYN_RECEIVED_RETRIES :: 3 // Timeouts of a SYN, ACK that end a passive open: 1 + 2 + 4 + 8 s.
ANSWER_LIMIT :: 10 // The ACKs that answer segments out of the window, and the challenge ACKs, of one connection...
ANSWER_PERIOD :: 1_000_000 // ...in this time.

State :: enum u8 {
	Closed       = 0, // The record is free when it also has no event and no RST to send.
	Syn_Sent     = 1,
	Syn_Received = 2,
	Established  = 3,
	Fin_Wait_1   = 4,
	Fin_Wait_2   = 5,
	Closing      = 6,
	Time_Wait    = 7,
	Close_Wait   = 8,
	Last_Ack     = 9,
}

Event_Kind :: enum u8 {
	Opened      = 0, // An active open reached Established.
	Accepted    = 1, // A passive open reached Established: a new connection of the listen port.
	Readable    = 2, // Data arrived in order: read can give bytes.
	Writable    = 3, // The remote acknowledged data: the send buffer has more room.
	Peer_Closed = 4, // The remote sent its FIN: no more data comes. The record stays.
	Closed      = 5, // The connection ended after a FIN from each side. The record is free after this event.
	Reset       = 6, // The remote sent a RST. The record is free after this event.
	Timed_Out   = 7, // RETRIES timeouts in a row: the library sent a RST. The record is free after this event.
	Refused     = 8, // The remote answered the SYN with a RST. The record is free after this event.
}
Event_Kinds :: bit_set[Event_Kind;u16]

// Event says what happened to one connection in one step.
Event :: struct {
	connection: u32,
	kinds:      Event_Kinds,
	reserved:   u16,
}
#assert(size_of(Event) == 8)

// A range of sequence numbers that arrived after a hole: [first, end).
Range :: struct {
	first: u32,
	end:   u32,
}

// Connection is the record of one connection. The program reads and can
// change each field. Times are microseconds of the clock of the caller.
Connection :: struct {
	state:                 State,
	passive:               bool, // A SYN from the remote opened it.
	closed_by_remote:      bool, // The FIN of the remote came before this side closed.
	fin_queued:            bool, // The program closed: a FIN follows the data.
	fin_sent:              bool, // The FIN at fin_sequence was sent at least one time.
	fin_acknowledged:      bool,
	fin_waiting:           bool, // A FIN arrived after a hole, at receive_fin.
	ack_now:               bool, // Send an ACK at the next step.
	reset_pending:         bool, // Send a RST at the next step.
	retransmit_one:        bool, // Send one segment at send_unacknowledged: fast retransmit, or a partial ACK.
	probe_now:             bool, // Send a probe of the zero window.
	timing:                bool, // The segment that ends at rtt_sequence is timed.
	in_recovery:           bool, // Fast recovery, until recover is acknowledged.
	syn_acknowledged:      bool, // The remote acknowledged the SYN of this side.
	events:                Event_Kinds, // The events that the next step reports.
	local_port:            u16,
	remote_port:           u16,
	mss:                   u16, // The bytes of data in one segment: the least of the two MSS.
	remote_address:        u32,

	// Send: SND.UNA, SND.NXT, SND.WND, SND.WL1, SND.WL2 of RFC 9293.
	initial_send:          u32,
	send_unacknowledged:   u32,
	send_next:             u32,
	send_most:             u32, // The highest SND.NXT: a segment before it is a retransmission.
	send_window:           u32,
	send_window_most:      u32,
	window_sequence:       u32,
	window_acknowledgment: u32,
	send_start:            u32, // The place of the byte at send_unacknowledged in the send buffer.
	send_length:           u32, // The bytes of the send buffer from send_unacknowledged, sent or not.
	fin_sequence:          u32,

	// Receive: IRS, RCV.NXT of RFC 9293, and the right edge of the window.
	initial_receive:       u32,
	receive_next:          u32,
	receive_edge:          u32, // receive_next + the window that the last segment gave. It never moves back.
	receive_start:         u32, // The place of the first byte that the program did not read.
	receive_ready:         u32, // The bytes in order that the program did not read.
	receive_fin:           u32,
	unacknowledged_bytes:  u32, // The bytes in order since the last ACK.
	acks_owed:             u32, // One ACK for each segment after a hole, also in one batch (RFC 5681 4.2).
	range_count:           u32,
	ranges:                [RANGE_CAPACITY]Range,

	// Congestion (RFC 5681, RFC 6582), in bytes.
	congestion_window:     u32,
	slow_start_threshold:  u32,
	recover:               u32,
	duplicate_acks:        u32,

	// Timers: the time when each one ends. 0: off.
	retransmit_at:         u64,
	ack_at:                u64,
	persist_at:            u64,
	end_at:                u64, // TIME-WAIT, or FIN-WAIT-2: the end of the record.

	// The round trip (RFC 6298), in microseconds.
	smoothed_rtt:          u64,
	rtt_variance:          u64,
	rto:                   u64,
	rtt_last:              u64,
	rtt_start:             u64,
	rtt_sequence:          u32,
	backoff:               u32, // Timeouts in a row.
	probe_backoff:         u32,
	probes_unanswered:     u32, // Probes of a zero window with no segment of the remote after them.
	answers:               u32, // Answers to segments out of the window in the period that starts at answers_at.
	answers_at:            u64,
	rtt_samples:           u32,

	// What happened, for the program and for a person.
	opened_at:             u64,
	established_at:        u64,
	closed_at:             u64,
	bytes_sent:            u64, // Bytes of data that the remote acknowledged.
	bytes_received:        u64, // Bytes of data that arrived in order.
	segments_sent:         u64,
	segments_received:     u64,
	retransmissions:       u64, // Segments sent again: after a timeout, a fast retransmit or a partial ACK.
	timeouts:              u64,
	fast_retransmits:      u64,
	probes:                u64, // Probes of a zero window.
	zero_windows:          u64, // Times that the remote gave a window of 0.
	duplicates:            u64, // Segments with nothing new: old data, or out of the window.
	out_of_order:          u64, // Segments after a hole.
	challenges:            u64, // Challenge ACKs sent (RFC 5961).
}
#assert(size_of(Connection) == 424)

// Table is the connection table of one program.
Table :: struct {
	connections:      []Connection,
	buffers:          []u8, // len(connections) * (send_size + receive_size) bytes.
	send_size:        u32,
	receive_size:     u32,
	local_address:    u32,
	listen_port:      u16, // 0: no passive open.
	remote_limit:     u16, // The open connections of one remote address that a passive open accepts. 0: no limit.
	port_first:       u16, // The local TCP ports of an active open: a block of port_count.
	port_count:       u16,
	port_next:        u16,
	mss:              u16, // The MSS that this side gives. 0: MSS_LOCAL.
	has_initial:      bool, // The next initial sequence number is `initial`, not RFC 6528.
	reserved:         u8,
	initial:          u32,
	secret:           [32]u8, // The secret of the initial sequence numbers (RFC 6528).

	// Segments that no connection took.
	resets_sent:      u64,
	refused_syns:     u64, // A SYN to the listen port when no record is free, or over remote_limit.
	reclaimed:        u64, // Records in TIME-WAIT that a SYN ended early, when no record was free.
	unknown_segments: u64,
	malformed:        u64,
}

// Incoming is one segment that arrived, from a remote address.
Incoming :: struct {
	remote_address: u32,
	segment:        []u8,
}

// Outgoing is one segment that step wrote: at the place `place` of the
// memory of the output, length bytes.
Outgoing :: struct {
	remote_address: u32,
	remote_port:    u16,
	length:         u16,
	place:          u32,
	connection:     i32, // -1: a RST for a segment of no connection.
}

// Output is where step writes segments. The caller gives the free places:
// segment n goes to memory[places[n] * place_size:]. A place has at least
// SEGMENT_LIMIT bytes.
Output :: struct {
	memory:     []u8,
	place_size: int,
	places:     []u32,
	segments:   []Outgoing, // At least len(places) records.
	count:      int,
}

// table_init prepares a table: connections and buffers are memory of the
// caller. The secret is for the initial sequence numbers.
table_init :: proc "contextless" (table: ^Table, connections: []Connection, buffers: []u8, send_size, receive_size: u32, local_address: u32, secret: [32]u8) -> (error: errors.Error_Record) {
	if send_size == 0 || receive_size == 0 {
		return {kind = i64(errors.Kind.Too_Small), unit = i64(errors.Unit.Bytes), argument = 4, value = i64(min(send_size, receive_size)), limit = 1}
	}
	needed := len(connections) * int(send_size + receive_size)
	if len(buffers) < needed {
		return {kind = i64(errors.Kind.Too_Small), unit = i64(errors.Unit.Bytes), argument = 3, value = i64(len(buffers)), limit = i64(needed)}
	}
	for &item in connections {
		item = {}
	}
	table^ = {connections = connections, buffers = buffers, send_size = send_size, receive_size = receive_size, local_address = local_address, secret = secret, mss = MSS_LOCAL}
	return {}
}

send_buffer :: proc "contextless" (table: ^Table, index: int) -> []u8 {
	return table.buffers[index * int(table.send_size + table.receive_size):][:table.send_size]
}

receive_buffer :: proc "contextless" (table: ^Table, index: int) -> []u8 {
	return table.buffers[index * int(table.send_size + table.receive_size) + int(table.send_size):][:table.receive_size]
}

// free says if a record can serve a new connection.
available :: proc "contextless" (connection: ^Connection) -> bool {
	return connection.state == .Closed && connection.events == {} && !connection.reset_pending
}

// open_count gives the connections that are open: not Closed, and not in
// TIME-WAIT (a record that only waits for old segments).
open_count :: proc "contextless" (table: ^Table) -> (count: int) {
	for &item in table.connections {
		if item.state != .Closed && item.state != .Time_Wait {
			count += 1
		}
	}
	return count
}

// initial_sequence gives the initial sequence number of RFC 6528: a counter
// of 4 microseconds, and the first 4 bytes of BLAKE3 of the secret and the
// four values that name the connection.
initial_sequence :: proc "contextless" (table: ^Table, remote_address: u32, local_port, remote_port: u16, now: u64) -> u32 {
	if table.has_initial {
		table.has_initial = false
		return table.initial
	}
	input: [44]u8
	copy(input[:32], table.secret[:])
	write_32(input[:], 32, table.local_address)
	write_16(input[:], 36, local_port)
	write_32(input[:], 38, remote_address)
	write_16(input[:], 42, remote_port)
	hash := blake3.hash(input[:])
	return u32(now / 4) + read_32(hash[:], 0)
}

@(private)
connection_start :: proc "contextless" (table: ^Table, connection: ^Connection, remote_address: u32, local_port, remote_port: u16, now: u64) {
	connection^ = {
		remote_address       = remote_address,
		local_port           = local_port,
		remote_port          = remote_port,
		rto                  = RTO_INITIAL,
		slow_start_threshold = SLOW_START_THRESHOLD,
		opened_at            = now,
		mss                  = MSS_DEFAULT,
	}
	connection.initial_send = initial_sequence(table, remote_address, local_port, remote_port, now)
	connection.send_unacknowledged = connection.initial_send
	connection.send_next = connection.initial_send // The SYN is not sent yet.
	connection.send_most = connection.initial_send
	connection.recover = connection.initial_send // RFC 6582 3.2, step 1.
}

// mss_agree takes the MSS option of a SYN: the least of it and the MSS of
// this side, and the initial congestion window of RFC 5681 3.1.
@(private)
mss_agree :: proc "contextless" (table: ^Table, connection: ^Connection, option: u16) {
	remote := option != 0 ? option : MSS_DEFAULT
	connection.mss = max(min(remote, table.mss != 0 ? table.mss : MSS_LOCAL), 64)
	mss := u32(connection.mss)
	switch {
	case mss > 2190:
		connection.congestion_window = 2 * mss
	case mss > 1095:
		connection.congestion_window = 3 * mss
	case:
		connection.congestion_window = 4 * mss
	}
}

// connect starts an active open to a remote, from a free local port of the
// block of the table. The SYN goes at the next step.
connect :: proc "contextless" (table: ^Table, remote_address: u32, remote_port: u16, now: u64) -> (index: int, error: errors.Error_Record) {
	index = -1
	for &item, place in table.connections {
		if available(&item) {
			index = place
			break
		}
	}
	if index < 0 {
		return -1, {kind = i64(errors.Kind.Full), unit = i64(errors.Unit.Connections), limit = i64(len(table.connections))}
	}
	// A local port that no other connection to this remote uses.
	port: u16
	for attempt in 0 ..< table.port_count {
		candidate := table.port_first + (table.port_next + attempt) % table.port_count
		used := false
		for &item in table.connections {
			if !available(&item) && item.local_port == candidate && item.remote_address == remote_address && item.remote_port == remote_port {
				used = true
				break
			}
		}
		if !used {
			port = candidate
			table.port_next = (table.port_next + attempt + 1) % table.port_count
			break
		}
	}
	if port == 0 {
		return -1, {kind = i64(errors.Kind.Full), unit = i64(errors.Unit.Tcp_Ports), limit = i64(table.port_count)}
	}
	connection := &table.connections[index]
	connection_start(table, connection, remote_address, port, remote_port, now)
	connection.state = .Syn_Sent
	return index, {}
}

@(private)
state_error :: proc "contextless" (index: int, connection: ^Connection, argument: i64) -> errors.Error_Record {
	return {kind = i64(errors.Kind.State), unit = i64(errors.Unit.Connections), argument = argument, value = i64(index), found = i64(connection.state)}
}

@(private)
index_error :: proc "contextless" (table: ^Table, index: int) -> (errors.Error_Record, bool) {
	if index < 0 || index >= len(table.connections) {
		return {kind = i64(errors.Kind.Bad_Value), unit = i64(errors.Unit.Connections), argument = 2, value = i64(index), limit = i64(len(table.connections) - 1)}, true
	}
	return {}, false
}

// write puts bytes in the send buffer of a connection. It gives the bytes
// that it took: fewer than len(bytes) when the buffer is full.
write :: proc "contextless" (table: ^Table, index: int, bytes: []u8) -> (count: int, error: errors.Error_Record) {
	if wrong, bad := index_error(table, index); bad {
		return 0, wrong
	}
	connection := &table.connections[index]
	#partial switch connection.state {
	case .Syn_Sent, .Syn_Received, .Established, .Close_Wait:
	case:
		return 0, state_error(index, connection, 2)
	}
	if connection.fin_queued {
		return 0, state_error(index, connection, 2)
	}
	buffer := send_buffer(table, index)
	room := table.send_size - connection.send_length
	count = min(int(room), len(bytes))
	end := (connection.send_start + connection.send_length) % table.send_size
	first := min(count, int(table.send_size - end))
	copy(buffer[end:][:first], bytes[:first])
	copy(buffer[:count - first], bytes[first:count])
	connection.send_length += u32(count)
	return count, {}
}

// send_room gives the free bytes of the send buffer of a connection.
send_room :: proc "contextless" (table: ^Table, index: int) -> int {
	return int(table.send_size - table.connections[index].send_length)
}

// read takes the bytes that arrived in order, at most len(buffer).
read :: proc "contextless" (table: ^Table, index: int, buffer: []u8) -> (count: int, error: errors.Error_Record) {
	if wrong, bad := index_error(table, index); bad {
		return 0, wrong
	}
	connection := &table.connections[index]
	source := receive_buffer(table, index)
	count = min(int(connection.receive_ready), len(buffer))
	first := min(count, int(table.receive_size - connection.receive_start))
	copy(buffer[:first], source[connection.receive_start:][:first])
	copy(buffer[first:count], source[:count - first])
	connection.receive_start = (connection.receive_start + u32(count)) % table.receive_size
	connection.receive_ready -= u32(count)
	// A window that grew by one MSS or half the buffer is news for the
	// remote: it can wait on a zero window (RFC 9293 3.8.6.2.2).
	if count > 0 && connection.state != .Closed {
		before := connection.receive_edge
		window_offer(table, connection)
		if connection.receive_edge != before {
			connection.ack_now = true
		}
	}
	return count, {}
}

// close ends the data of this side: a FIN follows the data of the send
// buffer. The connection then waits for the FIN of the remote.
close :: proc "contextless" (table: ^Table, index: int) -> errors.Error_Record {
	if wrong, bad := index_error(table, index); bad {
		return wrong
	}
	connection := &table.connections[index]
	#partial switch connection.state {
	case .Established:
		connection.state = .Fin_Wait_1
	case .Close_Wait:
		connection.state = .Last_Ack
	case .Syn_Sent:
		connection.state = .Closed // No SYN was answered: nothing to end.
		connection.retransmit_at = 0
		return {}
	case .Syn_Received:
		abort(table, index)
		return {}
	case:
		return state_error(index, connection, 2)
	}
	connection.fin_queued = true
	return {}
}

// abort ends a connection at once: a RST goes at the next step, and the
// data that was not sent is lost. No event follows.
abort :: proc "contextless" (table: ^Table, index: int) -> errors.Error_Record {
	if wrong, bad := index_error(table, index); bad {
		return wrong
	}
	connection := &table.connections[index]
	if connection.state == .Closed {
		return state_error(index, connection, 2)
	}
	connection.reset_pending = connection.state != .Syn_Sent
	connection_end(connection, 0, {})
	return {}
}

// connection_end makes a connection Closed with an event. now 0: no time.
@(private)
connection_end :: proc "contextless" (connection: ^Connection, now: u64, kinds: Event_Kinds) {
	connection.state = .Closed
	connection.events += kinds
	connection.retransmit_at = 0
	connection.ack_at = 0
	connection.persist_at = 0
	connection.end_at = 0
	connection.ack_now = false
	connection.retransmit_one = false
	connection.probe_now = false
	if now != 0 {
		connection.closed_at = now
	}
}

// window_offer moves the right edge of the receive window if the free room
// lets it move by one MSS or by half the buffer (avoidance of the silly
// window), and gives the window to send. The edge never moves back.
@(private)
window_offer :: proc "contextless" (table: ^Table, connection: ^Connection) -> u32 {
	room := min(table.receive_size - connection.receive_ready, WINDOW_LIMIT)
	candidate := connection.receive_next + room
	if before(connection.receive_edge, connection.receive_next) {
		connection.receive_edge = connection.receive_next
	}
	if after(candidate, connection.receive_edge) {
		least := min(table.receive_size / 2, u32(table.mss != 0 ? table.mss : MSS_LOCAL))
		if candidate - connection.receive_edge >= least || connection.receive_edge == connection.receive_next {
			connection.receive_edge = candidate
		}
	}
	return connection.receive_edge - connection.receive_next
}

// rtt_sample takes one measured round trip (RFC 6298 2.2, 2.3).
rtt_sample :: proc "contextless" (connection: ^Connection, measured: u64) {
	sample := max(measured, 1)
	if connection.rtt_samples == 0 {
		connection.smoothed_rtt = sample
		connection.rtt_variance = sample / 2
	} else {
		difference := connection.smoothed_rtt > sample ? connection.smoothed_rtt - sample : sample - connection.smoothed_rtt
		connection.rtt_variance = (3 * connection.rtt_variance + difference) / 4
		connection.smoothed_rtt = (7 * connection.smoothed_rtt + sample) / 8
	}
	connection.rtt_samples += 1
	connection.rtt_last = sample
	// The clock has a granularity of 1 microsecond: G is 1.
	connection.rto = min(max(connection.smoothed_rtt + max(1, 4 * connection.rtt_variance), RTO_LEAST), RTO_MOST)
}

// answer says if a connection can send one more ACK that answers a segment
// out of the window, or a challenge ACK: ANSWER_LIMIT in each ANSWER_PERIOD,
// for each connection (RFC 5961 7; one limit for all connections tells an
// attacker of the traffic of the others: CVE-2016-5696).
@(private)
answer_out_of_window_allowed :: proc "contextless" (connection: ^Connection, now: u64) -> bool {
	if now - connection.answers_at >= ANSWER_PERIOD {
		connection.answers_at = now
		connection.answers = 0
	}
	if connection.answers >= ANSWER_LIMIT {
		return false
	}
	connection.answers += 1
	connection.ack_now = true
	return true
}

// flight gives the bytes sent and not acknowledged.
@(private)
flight :: #force_inline proc "contextless" (connection: ^Connection) -> u32 {
	return connection.send_next - connection.send_unacknowledged
}

// The bytes of the send buffer that were sent at least one time at the
// current send_next, and those that were not.
@(private)
data_sent :: proc "contextless" (connection: ^Connection) -> u32 {
	return min(connection.send_next - connection.send_unacknowledged, connection.send_length)
}

// timeout is the end of the retransmission timer (RFC 6298 5.4 to 5.7,
// RFC 5681 3.1): the timer doubles, the congestion window is one segment,
// and the sending starts again at send_unacknowledged.
@(private)
timeout :: proc "contextless" (connection: ^Connection, now: u64) {
	connection.retransmit_at = 0
	connection.backoff += 1
	connection.timeouts += 1
	retries := u32(connection.state == .Syn_Received && connection.passive ? SYN_RECEIVED_RETRIES : RETRIES)
	if connection.backoff > retries {
		connection.reset_pending = true
		connection_end(connection, now, {.Timed_Out})
		return
	}
	connection.rto = min(connection.rto * 2, RTO_MOST)
	connection.timing = false
	#partial switch connection.state {
	case .Syn_Sent, .Syn_Received:
		connection.send_next = connection.initial_send // The SYN goes again.
		return
	}
	mss := u32(connection.mss)
	connection.slow_start_threshold = max(flight(connection) / 2, 2 * mss)
	connection.congestion_window = mss
	connection.in_recovery = false
	connection.duplicate_acks = 0
	connection.retransmit_one = false
	connection.recover = connection.send_most // RFC 6582 3.2, step 4.
	connection.send_next = connection.send_unacknowledged
}

// step does the work of one batch: it reads each segment that arrived, runs
// the timers at the time now, and writes the segments to send in output.
// It writes one event for each connection with news (a table with one place
// for each connection is enough; an event that does not fit waits for the
// next step). It gives the time of the next timer; now itself when output
// is full and more segments wait.
step :: proc "contextless" (table: ^Table, incoming: []Incoming, now: u64, output: ^Output, events: []Event) -> (deadline: u64, event_count: int) {
	for item in incoming {
		arrive(table, item, now, output)
	}
	full := false
	deadline = max(u64)
	for &connection, index in table.connections {
		if connection.state != .Closed {
			timers(&connection, now)
		}
		if !full && !connection_output(table, index, now, output) {
			full = true
		}
		for at in ([4]u64{connection.retransmit_at, connection.ack_at, connection.persist_at, connection.end_at}) {
			if at != 0 {
				deadline = min(deadline, at)
			}
		}
		if connection.events != {} && event_count < len(events) {
			events[event_count] = {connection = u32(index), kinds = connection.events}
			event_count += 1
			connection.events = {}
		}
	}
	if full {
		deadline = now
	}
	return deadline, event_count
}

@(private)
timers :: proc "contextless" (connection: ^Connection, now: u64) {
	if connection.end_at != 0 && now >= connection.end_at {
		if connection.state == .Fin_Wait_2 {
			// The remote never sent its FIN: a RST says that the record ends.
			connection.reset_pending = true
			connection_end(connection, now, {.Timed_Out})
			return
		}
		connection_end(connection, now, {.Closed})
		return
	}
	if connection.retransmit_at != 0 && now >= connection.retransmit_at {
		timeout(connection, now)
	}
	if connection.persist_at != 0 && now >= connection.persist_at {
		connection.probes_unanswered += 1
		if connection.probes_unanswered > RETRIES {
			// No segment of the remote after RETRIES probes: it went away.
			connection.reset_pending = true
			connection_end(connection, now, {.Timed_Out})
			return
		}
		connection.probe_now = true
		connection.probes += 1
		connection.probe_backoff = min(connection.probe_backoff + 1, 16)
		connection.persist_at = now + min(connection.rto << connection.probe_backoff, RTO_MOST)
	}
}

// find gives the record of a connection: its remote and its two ports.
// -1: no record. A program uses it to know if a segment had a connection.
find :: proc "contextless" (table: ^Table, remote_address: u32, local_port, remote_port: u16) -> int {
	for &item, index in table.connections {
		if item.state != .Closed && item.remote_address == remote_address && item.local_port == local_port && item.remote_port == remote_port {
			return index
		}
	}
	return -1
}

// emit writes one segment in the next place of the output. false: the
// output is full.
@(private)
emit :: proc "contextless" (table: ^Table, output: ^Output, connection_index: int, remote_address: u32, header: Header, first, second: []u8) -> bool {
	if output.count >= len(output.places) || output.count >= len(output.segments) {
		return false
	}
	place := output.places[output.count]
	segment := output.memory[int(place) * output.place_size:][:output.place_size]
	offset := header.mss != 0 ? HEADER_MSS : HEADER
	length := offset + len(first) + len(second)
	copy(segment[offset:], first)
	copy(segment[offset + len(first):], second)
	header_write(segment, table.local_address, remote_address, header, length)
	output.segments[output.count] = {remote_address = remote_address, remote_port = header.destination_port, length = u16(length), place = place, connection = i32(connection_index)}
	output.count += 1
	return true
}

// reset_answer sends the RST of RFC 9293 3.10.7.1 for a segment of no
// connection. It is lost when the output is full: the remote sends again.
@(private)
reset_answer :: proc "contextless" (table: ^Table, output: ^Output, remote_address: u32, header: Header, connection_index := -1) {
	answer := Header{source_port = header.destination_port, destination_port = header.source_port}
	if .Ack in header.flags {
		answer.sequence = header.acknowledgment
		answer.flags = {.Rst}
	} else {
		length := u32(len(header.data)) + u32(.Syn in header.flags) + u32(.Fin in header.flags)
		answer.acknowledgment = header.sequence + length
		answer.flags = {.Rst, .Ack}
	}
	if emit(table, output, connection_index, remote_address, answer, nil, nil) {
		table.resets_sent += 1
	}
}

// segment_send writes one segment of a connection, with the data of the
// send buffer from offset bytes after send_unacknowledged.
@(private)
segment_send :: proc "contextless" (table: ^Table, output: ^Output, index: int, flags: Flags, sequence: u32, offset, count: u32, mss: u16 = 0) -> bool {
	connection := &table.connections[index]
	header := Header {
		source_port      = connection.local_port,
		destination_port = connection.remote_port,
		sequence         = sequence,
		flags            = flags,
		mss              = mss,
	}
	if .Ack in flags {
		header.acknowledgment = connection.receive_next
	}
	header.window = u16(window_offer(table, connection))
	first, second: []u8
	if count > 0 {
		buffer := send_buffer(table, index)
		start := (connection.send_start + offset) % table.send_size
		part := min(count, table.send_size - start)
		first = buffer[start:][:part]
		second = buffer[:count - part]
	}
	if !emit(table, output, index, connection.remote_address, header, first, second) {
		return false
	}
	connection.segments_sent += 1
	if .Ack in flags {
		if connection.acks_owed > 0 {
			connection.acks_owed -= 1
		}
		connection.ack_now = false
		connection.ack_at = 0
		connection.unacknowledged_bytes = 0
	}
	return true
}

// connection_output writes the segments that a connection must send now.
// false: the output is full.
@(private)
connection_output :: proc "contextless" (table: ^Table, index: int, now: u64, output: ^Output) -> bool {
	connection := &table.connections[index]
	mss := u32(connection.mss)
	#partial switch connection.state {
	case .Closed:
		if connection.reset_pending {
			if !segment_send(table, output, index, {.Rst, .Ack}, connection.send_next, 0, 0) {
				return false
			}
			connection.reset_pending = false
			table.resets_sent += 1
		}
		return true
	case .Syn_Sent, .Syn_Received:
		if connection.send_next == connection.initial_send {
			flags := connection.state == .Syn_Sent ? Flags{.Syn} : Flags{.Syn, .Ack}
			if !segment_send(table, output, index, flags, connection.initial_send, 0, 0, table.mss != 0 ? table.mss : MSS_LOCAL) {
				return false
			}
			first := connection.send_most == connection.initial_send
			connection.send_next = connection.initial_send + 1
			connection.send_most = connection.send_next
			// Karn: a SYN or a SYN, ACK that goes again gives no sample.
			if !first {
				connection.timing = false
			}
			if first {
				connection.timing = true
				connection.rtt_sequence = connection.send_next
				connection.rtt_start = now
			} else {
				connection.retransmissions += 1
			}
			if connection.retransmit_at == 0 {
				connection.retransmit_at = now + connection.rto
			}
		}
		// In SYN-RECEIVED after the SYN, ACK: an ACK that answers a segment
		// out of the window (the SYN, ACK of a simultaneous open).
		if connection.state == .Syn_Received && connection.send_next != connection.initial_send && connection.ack_now {
			if !segment_send(table, output, index, {.Ack}, connection.send_next, 0, 0) {
				return false
			}
		}
		return true
	}
	// A fast retransmit, or the next segment after a partial ACK.
	if connection.retransmit_one {
		count := min(data_sent(connection), mss)
		fin := connection.fin_sent && !connection.fin_acknowledged && connection.send_unacknowledged + count == connection.fin_sequence
		if count > 0 || fin {
			flags := Flags{.Ack}
			if fin {
				flags += {.Fin}
			}
			if !segment_send(table, output, index, flags, connection.send_unacknowledged, 0, count) {
				return false
			}
			connection.retransmissions += 1
			connection.timing = false
			if connection.retransmit_at == 0 {
				connection.retransmit_at = now + connection.rto
			}
		}
		connection.retransmit_one = false
	}
	// New data, and data again after a timeout, as the windows let it.
	#partial switch connection.state {
	case .Established, .Close_Wait, .Fin_Wait_1, .Closing, .Last_Ack:
		for {
			sent := data_sent(connection)
			unsent := connection.send_length - sent
			if unsent == 0 {
				break
			}
			// Limited Transmit (RFC 3042): the first two duplicate ACKs each
			// let one new segment go, so that a small window still makes
			// the three duplicate ACKs of a fast retransmit.
			limited := connection.in_recovery ? 0 : min(connection.duplicate_acks, 2) * mss
			window := min(connection.send_window, connection.congestion_window + limited)
			in_flight := flight(connection)
			if in_flight >= window {
				break
			}
			usable := window - in_flight
			count := min(unsent, mss, usable)
			// Avoidance of the silly window by the sender (RFC 9293
			// 3.8.6.2.1): a small segment only when it is the last data, or
			// when the window is at least half the largest one, or when the
			// persist timer ended with nothing in flight.
			if count < mss && count < unsent && usable < connection.send_window_most / 2 && !connection.probe_now {
				break
			}
			connection.probe_now = false
			fin := connection.fin_queued && count == unsent
			flags := Flags{.Ack}
			if count == unsent {
				flags += {.Psh}
			}
			if fin {
				flags += {.Fin}
			}
			sequence := connection.send_next
			if !segment_send(table, output, index, flags, sequence, sent, count) {
				return false
			}
			again := before(sequence, connection.send_most)
			connection.send_next += count
			if fin {
				connection.fin_sequence = connection.send_next
				connection.fin_sent = true
				connection.send_next += 1
			}
			if again {
				connection.retransmissions += 1
			} else if !connection.timing {
				connection.timing = true
				connection.rtt_sequence = connection.send_next
				connection.rtt_start = now
			}
			if after(connection.send_next, connection.send_most) {
				connection.send_most = connection.send_next
			}
			if connection.retransmit_at == 0 {
				connection.retransmit_at = now + connection.rto
			}
		}
		// A FIN alone, when the data is sent.
		data_end := connection.send_unacknowledged + connection.send_length
		if connection.fin_queued && !connection.fin_acknowledged && connection.send_next == data_end && (!connection.fin_sent || connection.fin_sequence == data_end) {
			sequence := connection.send_next
			if !segment_send(table, output, index, {.Fin, .Ack}, sequence, 0, 0) {
				return false
			}
			if connection.fin_sent || before(sequence, connection.send_most) {
				connection.retransmissions += 1
			}
			connection.fin_sequence = sequence
			connection.fin_sent = true
			connection.send_next = sequence + 1
			if after(connection.send_next, connection.send_most) {
				connection.send_most = connection.send_next
			}
			if connection.retransmit_at == 0 {
				connection.retransmit_at = now + connection.rto
			}
		}
		// Data to send and nothing in flight, so no ACK will come: a zero
		// window, or a window too small for the rule above. The persist
		// timer ends it.
		if connection.send_length > data_sent(connection) && flight(connection) == 0 && connection.retransmit_at == 0 && connection.persist_at == 0 {
			connection.persist_at = now + min(connection.rto << connection.probe_backoff, RTO_MOST)
		}
	}
	if connection.probe_now {
		// A zero window: one sequence number before send_unacknowledged,
		// with no data. The remote answers with its window.
		if !segment_send(table, output, index, {.Ack}, connection.send_unacknowledged - 1, 0, 0) {
			return false
		}
		connection.probe_now = false
	}
	if connection.ack_now || (connection.ack_at != 0 && now >= connection.ack_at) {
		if !segment_send(table, output, index, {.Ack}, connection.send_next, 0, 0) {
			return false
		}
	}
	// The duplicate ACKs that a batch of segments after a hole owes. Each
	// segment with an ACK, also one with data above, pays one
	// (segment_send).
	for connection.acks_owed > 0 {
		if !segment_send(table, output, index, {.Ack}, connection.send_next, 0, 0) {
			return false
		}
	}
	return true
}

// arrive reads one segment.
@(private)
arrive :: proc "contextless" (table: ^Table, item: Incoming, now: u64, output: ^Output) {
	header, ok := header_read(item.segment)
	if !ok {
		table.malformed += 1
		return
	}
	index := find(table, item.remote_address, header.destination_port, header.source_port)
	if index < 0 {
		if .Rst in header.flags {
			table.unknown_segments += 1
			return
		}
		if table.listen_port != 0 && header.destination_port == table.listen_port && header.flags & {.Syn, .Ack} == {.Syn} {
			listen(table, item.remote_address, header, now, output)
			return
		}
		table.unknown_segments += 1
		reset_answer(table, output, item.remote_address, header)
		return
	}
	connection := &table.connections[index]
	connection.segments_received += 1
	if connection.state == .Syn_Sent {
		syn_sent(table, index, item.remote_address, header, now, output)
		return
	}
	synchronized(table, index, header, now, output)
}

// listen takes a SYN to the listen port: a passive open (RFC 9293 3.10.7.2).
@(private)
listen :: proc "contextless" (table: ^Table, remote_address: u32, header: Header, now: u64, output: ^Output) {
	index := -1
	for &item, place in table.connections {
		if available(&item) {
			index = place
			break
		}
	}
	// A limit for each remote address: one host cannot take each record.
	if table.remote_limit != 0 {
		open := 0
		for &item in table.connections {
			if item.remote_address == remote_address && item.state != .Closed && item.state != .Time_Wait {
				open += 1
			}
		}
		if open >= int(table.remote_limit) {
			table.refused_syns += 1
			reset_answer(table, output, remote_address, header)
			return
		}
	}
	if index < 0 {
		// No SYN cookies. A record in TIME-WAIT only waits for old
		// segments: the oldest one ends now, and the SYN is dropped; the
		// remote sends it again in 1 s and takes the record. With none, a
		// RST tells the remote at once.
		oldest := -1
		for &item, place in table.connections {
			if item.state == .Time_Wait && (oldest < 0 || before_time(item.end_at, table.connections[oldest].end_at)) {
				oldest = place
			}
		}
		if oldest >= 0 {
			table.reclaimed += 1
			connection_end(&table.connections[oldest], now, {.Closed})
			return
		}
		table.refused_syns += 1
		reset_answer(table, output, remote_address, header)
		return
	}
	connection := &table.connections[index]
	connection_start(table, connection, remote_address, header.destination_port, header.source_port, now)
	connection.state = .Syn_Received
	connection.passive = true
	connection.segments_received = 1
	connection.initial_receive = header.sequence
	connection.receive_next = header.sequence + 1
	connection.receive_edge = connection.receive_next
	mss_agree(table, connection, header.mss)
	connection.send_window = u32(header.window)
	connection.send_window_most = u32(header.window)
	connection.window_sequence = header.sequence
	window_offer(table, connection)
}

@(private)
before_time :: #force_inline proc "contextless" (a, b: u64) -> bool {
	return a < b
}

// syn_sent reads a segment in the state Syn_Sent (RFC 9293 3.10.7.3).
@(private)
syn_sent :: proc "contextless" (table: ^Table, index: int, remote_address: u32, header: Header, now: u64, output: ^Output) {
	connection := &table.connections[index]
	has_ack := .Ack in header.flags
	if has_ack && (before_or_same(header.acknowledgment, connection.initial_send) || after(header.acknowledgment, connection.send_most)) {
		if .Rst not_in header.flags {
			reset_answer(table, output, remote_address, header, index)
		}
		return
	}
	if .Rst in header.flags {
		if has_ack {
			connection_end(connection, now, {.Refused})
		}
		return
	}
	if .Syn not_in header.flags {
		return
	}
	connection.initial_receive = header.sequence
	connection.receive_next = header.sequence + 1
	connection.receive_edge = connection.receive_next
	mss_agree(table, connection, header.mss)
	window_offer(table, connection)
	if has_ack {
		connection.send_unacknowledged = header.acknowledgment
		connection.syn_acknowledged = true
		// A timeout can have set send_next back to send the SYN again.
		if before(connection.send_next, connection.send_unacknowledged) {
			connection.send_next = connection.send_unacknowledged
		}
		connection.state = .Established
		connection.established_at = now
		connection.events += {.Opened}
		connection.send_window = u32(header.window)
		connection.send_window_most = u32(header.window)
		connection.window_sequence = header.sequence
		connection.window_acknowledgment = header.acknowledgment
		if connection.timing && connection.backoff == 0 {
			rtt_sample(connection, now - connection.rtt_start)
		}
		connection.timing = false
		connection.backoff = 0
		connection.retransmit_at = 0
		connection.ack_now = true
		return
	}
	// A simultaneous open: send SYN, ACK from the same initial sequence.
	connection.state = .Syn_Received
	connection.send_next = connection.initial_send
	connection.retransmit_at = 0
}

// The bytes of a segment in sequence space: its data, and 1 for a SYN and for a FIN.
@(private)
sequence_length :: proc "contextless" (header: Header) -> u32 {
	return u32(len(header.data)) + u32(.Syn in header.flags) + u32(.Fin in header.flags)
}

// synchronized reads a segment in each state after Syn_Sent (RFC 9293
// 3.10.7.4, with the checks of RFC 5961).
@(private)
synchronized :: proc "contextless" (table: ^Table, index: int, header: Header, now: u64, output: ^Output) {
	connection := &table.connections[index]
	header := header
	// A SYN that came again before the ACK of the SYN, ACK: send it again.
	if connection.state == .Syn_Received && .Syn in header.flags && .Ack not_in header.flags && header.sequence == connection.initial_receive {
		connection.send_next = connection.initial_send
		connection.retransmit_at = 0
		connection.timing = false // Karn: the SYN, ACK goes two times.
		return
	}
	// A SYN in a synchronized state, at any sequence: a challenge ACK
	// (RFC 5961 4.2). In SYN-RECEIVED (a simultaneous open), the SYN, ACK of
	// the remote goes to the check of the window: it is out of it, and its
	// answer is the ACK that ends the open.
	if .Syn in header.flags && .Rst not_in header.flags && connection.state != .Syn_Received {
		if answer_out_of_window_allowed(connection, now) {
			connection.challenges += 1
		}
		return
	}
	original := header.sequence // The sequence of the segment as it came (RFC 5961 3.2).
	// 1. Is the segment in the window?
	length := sequence_length(header)
	window := connection.receive_edge - connection.receive_next
	acceptable: bool
	if length == 0 {
		acceptable = window == 0 ? header.sequence == connection.receive_next : inside(header.sequence, connection.receive_next, window)
	} else {
		acceptable = window != 0 && (inside(header.sequence, connection.receive_next, window) || inside(header.sequence + length - 1, connection.receive_next, window))
	}
	if !acceptable {
		// A zero window takes the ACK of a segment with data at
		// receive_next, and drops its data (RFC 9293 3.10.7.4).
		if window == 0 && header.sequence == connection.receive_next && .Rst not_in header.flags {
			header.data = nil
			header.flags -= {.Fin, .Syn}
		} else {
			if .Rst not_in header.flags {
				connection.duplicates += 1
				answer_out_of_window_allowed(connection, now)
				if connection.state == .Time_Wait && .Fin in header.flags {
					connection.end_at = now + TIME_WAIT // A FIN again: the remote lost the ACK.
				}
			}
			return
		}
	}
	// Cut the bytes before receive_next and after the window.
	if before(header.sequence, connection.receive_next) {
		cut := connection.receive_next - header.sequence
		if .Syn in header.flags {
			header.flags -= {.Syn}
			cut -= 1
			header.sequence += 1
		}
		data_cut := min(cut, u32(len(header.data)))
		header.data = header.data[data_cut:]
		header.sequence += data_cut
		if cut > data_cut {
			header.flags -= {.Fin} // A FIN that arrived before.
		}
	}
	room := connection.receive_edge - header.sequence
	if u32(len(header.data)) > room {
		header.data = header.data[:room]
		header.flags -= {.Fin}
	}
	// 2. RST: only at exactly receive_next (RFC 5961 3.2).
	if .Rst in header.flags {
		if original != connection.receive_next {
			if answer_out_of_window_allowed(connection, now) {
				connection.challenges += 1
			}
			return
		}
		// Also a passive open that the program never saw Accepted: the event
		// tells it to release the remote.
		connection_end(connection, now, {.Reset})
		return
	}
	// 4. ACK.
	if .Ack not_in header.flags {
		return
	}
	if connection.state == .Syn_Received {
		if after(header.acknowledgment, connection.send_unacknowledged) && before_or_same(header.acknowledgment, connection.send_most) {
			connection.state = .Established
			connection.established_at = now
			connection.events += connection.passive ? {.Accepted} : {.Opened}
			connection.window_sequence = header.sequence
			connection.window_acknowledgment = header.acknowledgment
			connection.send_window = u32(header.window)
			connection.send_window_most = max(connection.send_window_most, connection.send_window)
		} else {
			reset_answer(table, output, connection.remote_address, header, index)
			return
		}
	}
	if !acknowledge(table, connection, header, now) {
		return
	}
	// 5. Data.
	#partial switch connection.state {
	case .Established, .Fin_Wait_1, .Fin_Wait_2:
		if len(header.data) > 0 {
			receive(table, index, header, now)
		}
	}
	// 6. FIN: only before the FIN of the remote (RFC 9293 3.10.7.4, eighth).
	// A FIN again in TIME-WAIT restarts its timer.
	if .Fin in header.flags && connection.state == .Time_Wait {
		connection.end_at = now + TIME_WAIT
		connection.ack_now = true
	}
	fin_states := connection.state == .Established || connection.state == .Fin_Wait_1 || connection.state == .Fin_Wait_2
	if .Fin in header.flags && fin_states {
		fin_sequence := header.sequence + u32(len(header.data))
		if fin_sequence == connection.receive_next {
			fin_take(connection, now)
		} else if after(fin_sequence, connection.receive_next) {
			connection.fin_waiting = true
			connection.receive_fin = fin_sequence
			connection.ack_now = true
		}
	}
}

// acknowledge reads the ACK of a segment (RFC 9293 3.10.7.4, RFC 5961 5.2,
// RFC 5681, RFC 6582). false: the segment ends here.
@(private)
acknowledge :: proc "contextless" (table: ^Table, connection: ^Connection, header: Header, now: u64) -> bool {
	ack := header.acknowledgment
	mss := u32(connection.mss)
	// A segment of the remote came after the probes: it is there.
	connection.probes_unanswered = 0
	if after(ack, connection.send_most) {
		if answer_out_of_window_allowed(connection, now) { // An ACK of data that was never sent.
			connection.challenges += 1
		}
		return false
	}
	if before(ack, connection.send_unacknowledged - max(connection.send_window_most, 1)) {
		if answer_out_of_window_allowed(connection, now) { // Too old: a challenge ACK (RFC 5961 5.2).
			connection.challenges += 1
		}
		return false
	}
	if after(ack, connection.send_unacknowledged) {
		acknowledged := ack - connection.send_unacknowledged
		if !connection.syn_acknowledged {
			acknowledged -= 1 // The SYN, one time: by the state, not by the sequence.
			connection.syn_acknowledged = true
		}
		fin_now := connection.fin_sent && !connection.fin_acknowledged && after(ack, connection.fin_sequence)
		if fin_now {
			acknowledged -= 1
			connection.fin_acknowledged = true
		}
		data := min(acknowledged, connection.send_length)
		connection.send_start = (connection.send_start + data) % table.send_size
		connection.send_length -= data
		connection.bytes_sent += u64(data)
		connection.send_unacknowledged = ack
		if before(connection.send_next, ack) {
			connection.send_next = ack
		}
		if connection.timing && after_or_same(ack, connection.rtt_sequence) {
			rtt_sample(connection, now - connection.rtt_start)
			connection.timing = false
		}
		connection.backoff = 0
		if data > 0 {
			connection.events += {.Writable}
			connection.persist_at = 0
			connection.probe_backoff = 0
		}
		// Congestion (RFC 5681 3.1, RFC 6582 3.2).
		if connection.in_recovery {
			if after_or_same(ack, connection.recover) {
				connection.congestion_window = connection.slow_start_threshold
				connection.in_recovery = false
			} else {
				connection.retransmit_one = true
				connection.congestion_window = connection.congestion_window > data ? connection.congestion_window - data : 0
				if data >= mss {
					connection.congestion_window += mss
				}
				connection.retransmit_at = now + connection.rto
			}
		} else if connection.congestion_window < connection.slow_start_threshold {
			connection.congestion_window += min(data, mss)
		} else {
			connection.congestion_window += max(mss * mss / max(connection.congestion_window, 1), 1)
		}
		// A congestion window over the largest window of the remote says
		// nothing: the send window limits the data first.
		connection.congestion_window = min(connection.congestion_window, max(connection.send_window_most, 4 * mss))
		// Outside recovery, recover follows the acknowledged edge, so that
		// "ack after recover" holds after 2^31 bytes too (RFC 6582 3.2).
		if !connection.in_recovery && after(ack, connection.recover) {
			connection.recover = ack - 1
		}
		connection.duplicate_acks = 0
		if connection.send_unacknowledged == connection.send_next {
			connection.retransmit_at = 0
		} else if !connection.in_recovery {
			connection.retransmit_at = now + connection.rto
		}
		if fin_now {
			#partial switch connection.state {
			case .Fin_Wait_1:
				connection.state = .Fin_Wait_2
				connection.end_at = now + FIN_WAIT_2
			case .Closing:
				connection.state = .Time_Wait
				connection.end_at = now + TIME_WAIT
			case .Last_Ack:
				connection_end(connection, now, {.Closed})
				return false
			}
		}
	} else if ack == connection.send_unacknowledged && len(header.data) == 0 && header.flags & {.Syn, .Fin} == {} && u32(header.window) == connection.send_window && connection.send_next != connection.send_unacknowledged {
		// A duplicate ACK (RFC 5681 2).
		connection.duplicate_acks += 1
		if connection.duplicate_acks == 3 && !connection.in_recovery && after(ack, connection.recover) {
			connection.slow_start_threshold = max(flight(connection) / 2, 2 * mss)
			connection.recover = connection.send_most
			connection.retransmit_one = true
			connection.congestion_window = connection.slow_start_threshold + 3 * mss
			connection.in_recovery = true
			connection.fast_retransmits += 1
			connection.timing = false
		} else if connection.in_recovery {
			// The inflation of fast recovery, with the same limit.
			connection.congestion_window = min(connection.congestion_window + mss, max(connection.send_window_most, 4 * mss) + 3 * mss)
		}
	}
	// The send window: from the newest segment (SND.WL1, SND.WL2), with an
	// ACK in [SND.UNA, SND.NXT] (RFC 9293 3.10.7.4).
	newest := before(connection.window_sequence, header.sequence) || (connection.window_sequence == header.sequence && before_or_same(connection.window_acknowledgment, ack))
	if newest && !before(ack, connection.send_unacknowledged) {
		if header.window == 0 && connection.send_window != 0 {
			connection.zero_windows += 1
		}
		connection.send_window = u32(header.window)
		connection.send_window_most = max(connection.send_window_most, connection.send_window)
		connection.window_sequence = header.sequence
		connection.window_acknowledgment = ack
		if connection.send_window != 0 {
			connection.persist_at = 0
			connection.probe_backoff = 0
		}
	}
	return true
}

// receive takes the data of a segment that is in the window.
@(private)
receive :: proc "contextless" (table: ^Table, index: int, header: Header, now: u64) {
	connection := &table.connections[index]
	buffer := receive_buffer(table, index)
	offset := header.sequence - connection.receive_next
	count := u32(len(header.data))
	// The place of the first byte, after the bytes that wait to be read.
	start := (connection.receive_start + connection.receive_ready + offset) % table.receive_size
	part := min(count, table.receive_size - start)
	copy(buffer[start:][:part], header.data[:part])
	copy(buffer[:count - part], header.data[part:])
	if offset != 0 {
		range_add(connection, header.sequence, header.sequence + count)
		connection.out_of_order += 1
		// One ACK at once for each segment after a hole (RFC 5681 4.2): the
		// sender counts them to retransmit fast.
		connection.acks_owed += 1
		return
	}
	connection.receive_next += count
	connection.receive_ready += count
	connection.bytes_received += u64(count)
	connection.unacknowledged_bytes += count
	connection.events += {.Readable}
	if ranges_take(table, connection, now) {
		connection.ack_now = true // A hole is filled.
	}
	if connection.unacknowledged_bytes >= 2 * u32(connection.mss) {
		connection.ack_now = true
	} else if connection.ack_at == 0 {
		connection.ack_at = now + DELAYED_ACK
	}
}

// range_add remembers data after a hole. When no place is free, the range
// is not kept: the remote sends it again.
@(private)
range_add :: proc "contextless" (connection: ^Connection, first, end: u32) {
	first, end := first, end
	// Merge each range that touches the new one.
	for index := 0; index < int(connection.range_count); {
		item := connection.ranges[index]
		if before(end, item.first) || after(first, item.end) {
			index += 1
			continue
		}
		if before(item.first, first) {
			first = item.first
		}
		if after(item.end, end) {
			end = item.end
		}
		connection.ranges[index] = connection.ranges[connection.range_count - 1]
		connection.range_count -= 1
	}
	if connection.range_count < RANGE_CAPACITY {
		connection.ranges[connection.range_count] = {first, end}
		connection.range_count += 1
	}
}

// ranges_take moves receive_next over each range that it reaches. It says
// if one did.
@(private)
ranges_take :: proc "contextless" (table: ^Table, connection: ^Connection, now: u64) -> (took: bool) {
	for moved := true; moved; {
		moved = false
		for index := 0; index < int(connection.range_count); index += 1 {
			item := connection.ranges[index]
			if after(item.first, connection.receive_next) {
				continue
			}
			if after(item.end, connection.receive_next) {
				count := item.end - connection.receive_next
				connection.receive_next = item.end
				connection.receive_ready += count
				connection.bytes_received += u64(count)
			}
			connection.ranges[index] = connection.ranges[connection.range_count - 1]
			connection.range_count -= 1
			moved, took = true, true
			break
		}
	}
	if connection.fin_waiting && connection.receive_fin == connection.receive_next {
		connection.fin_waiting = false
		fin_take(connection, now)
	}
	return took
}

// fin_take takes the FIN of the remote, in order.
@(private)
fin_take :: proc "contextless" (connection: ^Connection, now: u64) {
	connection.receive_next += 1
	connection.receive_edge = max_sequence(connection.receive_edge, connection.receive_next)
	connection.ack_now = true
	connection.events += {.Peer_Closed}
	#partial switch connection.state {
	case .Established:
		connection.state = .Close_Wait
		connection.closed_by_remote = true
	case .Fin_Wait_1:
		connection.state = .Closing
	case .Fin_Wait_2:
		connection.state = .Time_Wait
		connection.end_at = now + TIME_WAIT
	}
}

@(private)
max_sequence :: proc "contextless" (a, b: u32) -> u32 {
	return after(a, b) ? a : b
}
