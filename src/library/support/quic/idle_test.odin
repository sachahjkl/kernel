#+build !freestanding
// The idle timeout when the peer goes silent: the bound holds whatever the
// probes of this side. Each test cuts the channel of the endpoints in both
// ways, and drives the fake clock of the endpoints.
package quic

import "contract:errors"
import "core:testing"
import "support:random"

// idle_bound gives the latest end of a connection that receives nothing:
// its last activity plus the larger of its idle timeout and three probe
// timeouts with no backoff.
idle_bound :: proc(connection: ^Connection) -> u64 {
	return connection.last_activity + max(connection.idle_timeout, 3 * probe_timeout_base(connection, .Application))
}

// steps_until_closed steps the endpoints until the server is closed, for
// clock_limit at most, and gives the time of its end.
steps_until_closed :: proc(endpoints: ^Test_Endpoints, clock_limit: u64) -> u64 {
	end := endpoints.now + clock_limit
	// A step handles the time that it starts at, then moves the clock: the
	// time of the end is the time of the step that closed the server.
	closed_at := endpoints.now
	for endpoints.now < end && endpoints.server.state != .Closed {
		closed_at = endpoints.now
		endpoints_step(endpoints)
	}
	return closed_at
}

// The probes that a connection sends after its last ack-eliciting packet,
// before its idle bound: a probe timeout k (from 1) comes at
// base × (2^k - 1) after that packet, each later by the delay of its
// send, and each one sends PROBE_PACKETS datagrams. The endpoints of the
// tests send the probes of a timeout at their next step, 1 ms later at
// most: the count with a delay of 0 and the count with a delay of 1 ms
// bound the count of a run.
expected_probe_datagrams :: proc(base: u64, sent_at: u64, bound: u64, delay_of_each_send: u64) -> int {
	timeouts := 0
	at := sent_at + base + delay_of_each_send
	for at < bound {
		timeouts += 1
		at += (base << uint(timeouts)) + delay_of_each_send
	}
	return timeouts * PROBE_PACKETS
}

// A client that goes silent while the server has data in flight. The
// server probes, the backoff doubles each probe timeout, and the server
// still ends the connection at its idle bound: max(idle timeout,
// 3 × base probe timeout) after its last activity. Before the correction,
// the bound grew with the backoff, moved past each next probe, and the
// connection lived for hours: this test would have run out of its clock of
// one hour of the test.
@(test)
a_silent_peer_ends_the_connection_at_the_idle_timeout_whatever_the_probes :: proc(t: ^testing.T) {
	endpoints := endpoints_make()
	defer free(endpoints)
	testing.expect(t, endpoints_connect(endpoints))
	client, server := &endpoints.client, &endpoints.server
	identifier, opened := stream_open(client)
	if !testing.expect(t, opened) {
		return
	}
	data: [100]u8
	testing.expect_value(t, stream_write(client, identifier, data[:], false), 100)
	for _ in 0 ..< 2000 {
		if stream := stream_of(server, identifier); stream != nil && stream.highest_received == 100 {
			break
		}
		endpoints_step(endpoints)
	}
	// Each acknowledgement of the client before the cut.
	for _ in 0 ..< 200 {
		endpoints_step(endpoints)
	}
	endpoints.channel.cut = true
	sent_before := endpoints.channel.sent_to_client
	// The server writes back: a packet that the client never acknowledges.
	testing.expect_value(t, stream_write(server, identifier, data[:], false), 100)
	endpoints_step(endpoints)
	space := &server.spaces[.Application]
	if !testing.expect(t, space.ack_eliciting_in_flight > 0) {
		return
	}
	sent_at := space.last_ack_eliciting_sent_time
	bound := idle_bound(server)
	base := probe_timeout_base(server, .Application)
	testing.expect_value(t, server.last_activity, sent_at)
	ended_at := steps_until_closed(endpoints, 3600_000_000)
	testing.expectf(t, server.state == .Closed && server.closed_by_idle_timeout, "the server is %v after %d us", server.state, ended_at - sent_at)
	testing.expectf(t, ended_at >= server.idle_timeout + sent_at && ended_at <= bound, "the server ended %d us after its last activity; its bound is %d us", ended_at - sent_at, bound - sent_at)
	testing.expectf(t, server.probe_timeout_count > 5, "%d probe timeouts: the test did not reach the backoff", server.probe_timeout_count)
	// The datagram of the data, then the probes.
	probes := endpoints.channel.sent_to_client - sent_before - 1
	fewest := expected_probe_datagrams(base, sent_at, bound, 1000)
	most := expected_probe_datagrams(base, sent_at, bound, 0)
	testing.expectf(t, probes >= fewest && probes <= most, "%d datagrams of probes, not %d to %d (base probe timeout %d us)", probes, fewest, most, base)
}

// A client that goes silent while nothing of the server is in flight: the
// server sends nothing, and ends at its idle bound.
@(test)
a_silent_peer_with_nothing_in_flight_ends_at_the_idle_timeout :: proc(t: ^testing.T) {
	endpoints := endpoints_make()
	defer free(endpoints)
	testing.expect(t, endpoints_connect(endpoints))
	_, server_read := echo_run(t, endpoints, 5000, 10_000_000)
	testing.expect_value(t, server_read, 5000)
	for _ in 0 ..< 2000 {
		endpoints_step(endpoints)
	}
	server := &endpoints.server
	if !testing.expect_value(t, server.spaces[.Application].ack_eliciting_in_flight, 0) {
		return
	}
	endpoints.channel.cut = true
	sent_before := endpoints.channel.sent_to_client
	last_activity := server.last_activity
	bound := idle_bound(server)
	ended_at := steps_until_closed(endpoints, 3600_000_000)
	testing.expect(t, server.state == .Closed && server.closed_by_idle_timeout)
	testing.expectf(t, ended_at >= last_activity + server.idle_timeout && ended_at <= bound, "the server ended %d us after its last activity; its bound is %d us", ended_at - last_activity, bound - last_activity)
	testing.expect_value(t, endpoints.channel.sent_to_client, sent_before)
}

// A packet of the client 29 s into the silence moves the last activity of
// the server: the connection ends 30 s after that packet, not 30 s after
// the first silence. The ACK that the server sends for it is not
// ack-eliciting, so it does not move the bound again.
@(test)
a_packet_before_the_idle_timeout_moves_the_deadline :: proc(t: ^testing.T) {
	endpoints := endpoints_make()
	defer free(endpoints)
	testing.expect(t, endpoints_connect(endpoints))
	for _ in 0 ..< 2000 {
		endpoints_step(endpoints)
	}
	server := &endpoints.server
	if !testing.expect_value(t, server.spaces[.Application].ack_eliciting_in_flight, 0) {
		return
	}
	endpoints.channel.cut = true
	first_bound := idle_bound(server)
	ping_at := server.last_activity + 29_000_000
	for endpoints.now < ping_at {
		endpoints_step(endpoints)
	}
	testing.expect(t, server.state == .Connected)
	keys := endpoints.client.spaces[.Application].send_keys
	number := endpoints.client.spaces[.Application].next_packet_number + 100
	_, processed := authentic_packet_receive(endpoints, server, &keys, number, []u8{FRAME_PING}, endpoints.now)
	testing.expect(t, processed)
	testing.expect_value(t, server.last_activity, endpoints.now)
	second_bound := idle_bound(server)
	ended_at := steps_until_closed(endpoints, 3600_000_000)
	testing.expect(t, server.state == .Closed && server.closed_by_idle_timeout)
	testing.expectf(t, ended_at > first_bound && ended_at <= second_bound, "the server ended at %d; the first bound %d, the second %d", ended_at, first_bound, second_bound)
}

// The closing state lasts three probe timeouts with no backoff, whatever
// the probes before the close: a record in the closing state is freed in
// a bounded time.
@(test)
the_closing_state_lasts_three_base_probe_timeouts :: proc(t: ^testing.T) {
	endpoints := endpoints_make()
	defer free(endpoints)
	testing.expect(t, endpoints_connect(endpoints))
	server := &endpoints.server
	server.probe_timeout_count = 16
	closed_at := endpoints.now
	connection_close(server, 0, closed_at)
	testing.expect_value(t, server.close_deadline, closed_at + 3 * probe_timeout_base(server, .Application))
}

// Datagrams that must not keep a silent connection alive. The server
// records 32 islands of data on a stream, which fill the set of its
// received ranges, then the client goes silent. During the silence the
// server gets: a datagram with its connection identifier that does not
// authenticate; a replay of an authentic packet that it recorded; an
// authentic packet whose data has no place in the set (it is processed,
// not recorded, not acknowledged); and a replay of that one. None moves
// the last activity, and the record ends at the bound of the last packet
// that was recorded. Before, the packet with no place moved the last
// activity, and so did each replay of it.
@(test)
datagrams_during_a_silence_do_not_move_the_idle_bound :: proc(t: ^testing.T) {
	endpoints := connected_endpoints()
	defer free(endpoints)
	for _ in 0 ..< 2000 {
		endpoints_step(endpoints)
	}
	server := &endpoints.server
	if !testing.expect_value(t, server.spaces[.Application].ack_eliciting_in_flight, 0) {
		return
	}
	endpoints.channel.cut = true
	keys := endpoints.client.spaces[.Application].send_keys
	number := endpoints.client.spaces[.Application].next_packet_number + 10
	UNIT :: 100
	recorded: [dynamic]u8
	defer delete(recorded)
	for island in 0 ..< RANGE_SET_LIMIT {
		sealed, processed := authentic_packet_receive(endpoints, server, &keys, number, stream_frame_of_the_pattern((2 * island + 1) * UNIT, UNIT), endpoints.now)
		testing.expect(t, processed)
		if island == 0 {
			append(&recorded, ..sealed)
		}
		number += 1
	}
	reference := server.last_activity
	bound := idle_bound(server)
	testing.expect_value(t, reference, endpoints.now)
	advance :: proc(endpoints: ^Test_Endpoints, until: u64) {
		for endpoints.now < until {
			endpoints_step(endpoints)
		}
	}
	error: errors.Error_Record
	// 10 s in: a datagram with the identifier of the server that does not
	// authenticate.
	advance(endpoints, reference + 10_000_000)
	forged: [64]u8
	forged[0] = FIXED_BIT | u8(PACKET_NUMBER_SIZE - 1)
	copy(forged[1:], server.local_connection_id[:])
	for index in 1 + CONNECTION_ID_SIZE ..< len(forged) {
		forged[index] = u8(index * 37)
	}
	testing.expect(t, !connection_datagram_receive(server, forged[:], endpoints.now, &error))
	testing.expect_value(t, server.last_activity, reference)
	// 15 s in: a replay of the first island, which the server recorded.
	advance(endpoints, reference + 15_000_000)
	testing.expect(t, !connection_datagram_receive(server, recorded[:], endpoints.now, &error))
	testing.expect_value(t, server.last_activity, reference)
	// 20 s in: an authentic island past the 32nd: processed, not recorded.
	advance(endpoints, reference + 20_000_000)
	no_place, processed := authentic_packet_receive(endpoints, server, &keys, number, stream_frame_of_the_pattern((2 * RANGE_SET_LIMIT + 1) * UNIT, UNIT), endpoints.now)
	testing.expect(t, processed)
	testing.expect(t, !range_set_contains(&server.spaces[.Application].received, number))
	testing.expect_value(t, server.last_activity, reference)
	replay := make([]u8, len(no_place))
	defer delete(replay)
	copy(replay, no_place)
	// 25 s in: its replay.
	advance(endpoints, reference + 25_000_000)
	connection_datagram_receive(server, replay, endpoints.now, &error)
	testing.expect_value(t, server.last_activity, reference)
	ended_at := steps_until_closed(endpoints, 3600_000_000)
	testing.expect(t, server.state == .Closed && server.closed_by_idle_timeout)
	testing.expectf(t, ended_at >= reference + server.idle_timeout && ended_at <= bound, "the server ended %d us after the last recorded packet; its bound is %d us", ended_at - reference, bound - reference)
	testing.expect_value(t, server.ended_at, ended_at)
}

// A server with no idle timeout is refused: with no idle timeout on either
// side, a client that vanishes with data of the server in flight would keep
// its record for ever. The error says which argument, and what it must
// have: "argument 5 is empty; it must have 1 to 4611686018427387903
// milliseconds".
@(test)
a_server_with_no_idle_timeout_is_refused :: proc(t: ^testing.T) {
	cryptography := module_cryptography()
	generator: random.Generator
	connections := make([]Connection, 1)
	defer delete(connections)
	records := make([]Server_Record, 1)
	defer delete(records)
	streams := make([]Stream, 1)
	defer delete(streams)
	server := new(Server)
	defer free(server)
	configuration := Connection_Configuration{idle_timeout_milliseconds = 0}
	configuration.tls = {role = .Server, least_seed_strength = .Processor}
	error: errors.Error_Record
	testing.expect(t, !server_init(server, connections, records, streams, &configuration, &cryptography, &generator, SERVER_LIMITS_DEFAULT, &error))
	testing.expect_value(t, error.kind, i64(errors.Kind.Empty))
	testing.expect_value(t, error.unit, i64(errors.Unit.Milliseconds))
	testing.expect_value(t, error.argument, 5)
	testing.expect_value(t, error.limit, i64(VARIABLE_LENGTH_INTEGER_LARGEST))
}

// The draining state ends by the clock after three probe timeouts with no
// backoff, whatever the probes before the close of the peer: a server that
// probed 16 times, then gets the CONNECTION_CLOSE of the client, ends 3
// base probe timeouts later.
@(test)
the_draining_state_ends_by_the_clock :: proc(t: ^testing.T) {
	endpoints := connected_endpoints()
	defer free(endpoints)
	endpoints.channel.cut = true
	server := &endpoints.server
	server.probe_timeout_count = 16
	keys := endpoints.client.spaces[.Application].send_keys
	number := endpoints.client.spaces[.Application].next_packet_number + 10
	// CONNECTION_CLOSE of the application: the code 0, no reason.
	_, processed := authentic_packet_receive(endpoints, server, &keys, number, []u8{FRAME_CONNECTION_CLOSE_APPLICATION, 0, 0}, endpoints.now)
	testing.expect(t, processed)
	testing.expect_value(t, server.state, Connection_State.Draining)
	closed_by_peer_at := endpoints.now
	deadline := closed_by_peer_at + 3 * probe_timeout_base(server, .Application)
	testing.expect_value(t, server.close_deadline, deadline)
	ended_at := steps_until_closed(endpoints, 3600_000_000)
	testing.expect_value(t, server.state, Connection_State.Closed)
	testing.expectf(t, ended_at >= deadline && ended_at <= deadline + 1000, "the draining state ended %d us after the close; its deadline was %d us after it", ended_at - closed_by_peer_at, deadline - closed_by_peer_at)
	testing.expect_value(t, server.ended_at, ended_at)
}
