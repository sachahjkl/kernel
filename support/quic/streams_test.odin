#+build !freestanding
// Several streams in one connection, on the host: the echo of each stream,
// the limit of streams that moves when a stream ends, flow control of the
// connection, the resets, and the frames of a hostile peer that name
// streams.
package quic

import "core:testing"

STREAM_ECHO_SIZE :: 16384

// The echo of one stream record of a server: the bytes read and not yet
// written back.
Server_Stream_Echo :: struct {
	active:         bool,
	identifier:     u64,
	pending:        [STREAM_ECHO_SIZE]u8,
	start, end:     int,
	finished:       bool,
	finish_written: bool,
}

// server_streams_echo writes back on each stream of a connection the bytes
// that it read, then the end after the end of the peer; a stream that the
// peer reset is reset. echoes has one place for each stream record.
server_streams_echo :: proc(connection: ^Connection, echoes: []Server_Stream_Echo) {
	for &stream, slot in connection.streams {
		echo := &echoes[slot]
		if !stream.in_use {
			echo.active = false
			continue
		}
		if !echo.active || echo.identifier != stream.identifier {
			echo.active, echo.identifier = true, stream.identifier
			echo.start, echo.end, echo.finished, echo.finish_written = 0, 0, false, false
		}
		for {
			if echo.start < echo.end {
				echo.start += stream_write(connection, echo.identifier, echo.pending[echo.start:echo.end], false)
				if echo.start < echo.end {
					break
				}
			}
			echo.start, echo.end = 0, 0
			count, finished, reset := stream_read(connection, echo.identifier, echo.pending[:])
			if reset {
				stream_reset(connection, echo.identifier, 0)
				break
			}
			echo.end = count
			echo.finished = echo.finished || finished
			if count == 0 {
				break
			}
		}
		if echo.finished && echo.start == echo.end && !echo.finish_written {
			stream_write(connection, echo.identifier, nil, true)
			echo.finish_written = true
		}
	}
}

// One stream of the client of a test.
Client_Stream_Echo :: struct {
	identifier: u64,
	opened:     bool,
	written:    int,
	read:       int,
	finished:   bool,
}

// The byte at an index of the stream at a place of the client: each
// stream has its own pattern, so a byte of one stream on another is seen.
stream_pattern_byte :: proc(place: int, index: int) -> u8 {
	return pattern_byte(index + 7 * place)
}

// streams_echo_run opens streams of the client of the endpoints, as the
// limit of the server and the records of the client allow, sends total
// bytes on each, and checks each byte that comes back; the server writes
// back each stream. It gives the count of the streams whose echo ended,
// for the clock limit.
streams_echo_run :: proc(t: ^testing.T, endpoints: ^Test_Endpoints, streams: []Client_Stream_Echo, total: int, clock_limit: u64) -> int {
	echoes := make([]Server_Stream_Echo, len(endpoints.server.streams))
	defer delete(echoes)
	chunk: [4096]u8
	end := endpoints.now + clock_limit
	for endpoints.now < end {
		done := 0
		for &item, place in streams {
			if !item.opened {
				item.identifier, item.opened = stream_open(&endpoints.client)
				if !item.opened {
					continue
				}
			}
			for item.written < total {
				count := min(len(chunk), total - item.written)
				for index in 0 ..< count {
					chunk[index] = stream_pattern_byte(place, item.written + index)
				}
				taken := stream_write(&endpoints.client, item.identifier, chunk[:count], item.written + count == total)
				item.written += taken
				if taken < count {
					break
				}
			}
			for {
				count, finished, _ := stream_read(&endpoints.client, item.identifier, chunk[:])
				for index in 0 ..< count {
					if chunk[index] != stream_pattern_byte(place, item.read + index) {
						testing.expectf(t, false, "stream %d: the byte %d came back changed", item.identifier, item.read + index)
						return done
					}
				}
				item.read += count
				item.finished = item.finished || finished
				if count == 0 {
					break
				}
			}
			if item.finished && item.read == total {
				done += 1
			}
		}
		if done == len(streams) {
			return done
		}
		server_streams_echo(&endpoints.server, echoes)
		endpoints_step(endpoints)
	}
	done := 0
	for item in streams {
		if item.finished && item.read == total {
			done += 1
		}
	}
	return done
}

// Four streams at once, 100 KiB each way on each, with 2 % of the
// datagrams lost and 5 % out of order: each byte comes back on its own
// stream, and each stream ends on both sides.
@(test)
four_streams_at_once :: proc(t: ^testing.T) {
	endpoints := endpoints_make()
	defer free(endpoints)
	endpoints.channel.loss = 20
	endpoints.channel.reorder = 50
	testing.expect(t, endpoints_connect(endpoints))
	streams: [TEST_STREAMS]Client_Stream_Echo
	done := streams_echo_run(t, endpoints, streams[:], 100 * 1024, 60_000_000)
	testing.expectf(t, done == TEST_STREAMS, "%d streams ended their echo, not %d", done, TEST_STREAMS)
	identifiers: [TEST_STREAMS]u64
	for item, place in streams {
		identifiers[place] = item.identifier
	}
	testing.expect_value(t, identifiers, [TEST_STREAMS]u64{0, 4, 8, 12})
	testing.expect_value(t, endpoints.client.data_sent_total, u64(TEST_STREAMS * 100 * 1024))
}

// Twelve streams through a server that gives 4 at a time: the client
// opens 4, is blocked (STREAMS_BLOCKED), and opens the next ones as the
// server gives more with MAX_STREAMS, each time a stream ended on both
// sides. Every record of both sides is free at the end.
@(test)
the_limit_of_streams_moves_when_streams_end :: proc(t: ^testing.T) {
	endpoints := endpoints_make()
	defer free(endpoints)
	testing.expect(t, endpoints_connect(endpoints))
	streams: [12]Client_Stream_Echo
	done := streams_echo_run(t, endpoints, streams[:], 3000, 60_000_000)
	testing.expectf(t, done == 12, "%d streams ended their echo, not 12", done)
	testing.expect_value(t, endpoints.client.streams_opened_by_this_side, 12)
	testing.expect_value(t, endpoints.server.streams_opened_by_peer, 12)
	// The acknowledgements of the last ends, then each record is free.
	for _ in 0 ..< 2000 {
		endpoints_step(endpoints)
	}
	for side in ([]^Connection{&endpoints.client, &endpoints.server}) {
		for stream in side.streams {
			testing.expectf(t, !stream.in_use, "the stream %d is still open", stream.identifier)
		}
	}
	testing.expect_value(t, endpoints.server.streams_limit_given, u64(12 + TEST_STREAMS))
	testing.expect_value(t, endpoints.client.peer_max_streams_bidirectional, u64(12 + TEST_STREAMS))
}

// A stream that the client resets, and asks the server to reset
// (STOP_SENDING): the server reads the reset, resets its own direction with
// the code of the STOP_SENDING, and both records end. The bytes that the
// server never read give their room back to the window of the connection.
@(test)
a_stream_reset_by_both_sides :: proc(t: ^testing.T) {
	endpoints := endpoints_make()
	defer free(endpoints)
	testing.expect(t, endpoints_connect(endpoints))
	identifier, opened := stream_open(&endpoints.client)
	if !testing.expect(t, opened) {
		return
	}
	data: [3000]u8
	testing.expect_value(t, stream_write(&endpoints.client, identifier, data[:], false), 3000)
	for _ in 0 ..< 100 {
		endpoints_step(endpoints)
	}
	stream_reset(&endpoints.client, identifier, 7)
	stream_stop_sending(&endpoints.client, identifier, 9)
	echoes := make([]Server_Stream_Echo, TEST_STREAMS)
	defer delete(echoes)
	client_reset := false
	for _ in 0 ..< 3000 {
		// The server reads nothing before the reset: its echo runs after.
		if stream := stream_of(&endpoints.server, identifier); stream != nil && stream.reset_received {
			testing.expect_value(t, stream.peer_reset_code, 7)
			server_streams_echo(&endpoints.server, echoes)
		}
		if stream := stream_of(&endpoints.client, identifier); stream != nil && stream.reset_received && !client_reset {
			testing.expect_value(t, stream.peer_reset_code, 9)
			_, _, reset := stream_read(&endpoints.client, identifier, data[:])
			client_reset = reset
		}
		endpoints_step(endpoints)
	}
	testing.expect(t, client_reset)
	testing.expect(t, stream_of(&endpoints.client, identifier) == nil && stream_of(&endpoints.server, identifier) == nil)
	testing.expect_value(t, endpoints.server.streams_limit_given, u64(TEST_STREAMS + 1))
	// The 3000 bytes that the server never read count as read for the
	// window of the connection.
	testing.expect_value(t, endpoints.server.data_consumed_total, 3000)
}

// The frames of a hostile peer that name streams.
@(test)
hostile_frames_that_name_streams :: proc(t: ^testing.T) {
	endpoints := connected_endpoints()
	defer free(endpoints)
	server := &endpoints.server
	// A stream far ahead within the limit opens it and each lower stream of
	// the client.
	ahead := frames_on_a_copy(server, .Application, bytes_of("0a0c0161"))
	testing.expect_value(t, ahead.state, Connection_State.Connected)
	testing.expect_value(t, ahead.streams_opened_by_peer, 4)
	for identifier in ([]u64{0, 4, 8, 12}) {
		testing.expectf(t, stream_of(ahead, identifier) != nil, "the stream %d is not open", identifier)
	}
	// One past the limit, after the four: STREAM_LIMIT_ERROR.
	over := frames_on_a_copy(server, .Application, bytes_of("0a0c0161" + "0a100161"))
	testing.expect_value(t, over.close_error_code, u64(Transport_Error.Stream_Limit_Error))
	// A stream number near 2^62: STREAM_LIMIT_ERROR, and no stream opens.
	far := frames_on_a_copy(server, .Application, bytes_of("0afffffffffffffffc0161"))
	testing.expect_value(t, far.close_error_code, u64(Transport_Error.Stream_Limit_Error))
	testing.expect_value(t, far.streams_opened_by_peer, 0)
	// Data within the limit of each stream, past the limit of the
	// connection: FLOW_CONTROL_ERROR.
	limited := connection_copy(server, context.temp_allocator)
	limited.receive_max_data = limited.data_received_total + 100
	frames: [2 * (3 + 60)]u8
	for index in 0 ..< 2 {
		at := index * (3 + 60)
		frames[at], frames[at + 1], frames[at + 2] = FRAME_STREAM | FRAME_STREAM_FLAG_LENGTH, u8(4 * index), 60
	}
	frames_process(limited, .Application, frames[:], 2_000_000_000)
	testing.expect_value(t, limited.close_error_code, u64(Transport_Error.Flow_Control_Error))
	// A reset whose final size is under the data, or that changes the end
	// that the peer gave: FINAL_SIZE_ERROR.
	under := frames_on_a_copy(server, .Application, bytes_of("0a00026161" + "04000701"))
	testing.expect_value(t, under.close_error_code, u64(Transport_Error.Final_Size_Error))
	changed := frames_on_a_copy(server, .Application, bytes_of("0b00026161" + "04000703"))
	testing.expect_value(t, changed.close_error_code, u64(Transport_Error.Final_Size_Error))
	// A reset with the final size of the data is taken: the stream reads
	// as reset, and its bytes count as read for the connection.
	reset := frames_on_a_copy(server, .Application, bytes_of("0a00026161" + "04000702"))
	testing.expect_value(t, reset.state, Connection_State.Connected)
	_, _, was_reset := stream_read(reset, 0, nil)
	testing.expect(t, was_reset)
	// STOP_SENDING ends the sending part of this side with RESET_STREAM.
	stopped := frames_on_a_copy(server, .Application, bytes_of("0a000161" + "050009"))
	stopped_stream := stream_of(stopped, 0)
	testing.expect(t, stopped_stream != nil && stopped_stream.reset_sent && stopped_stream.reset_code == 9 && .Reset_Stream in stopped_stream.pending_controls)
	testing.expect_value(t, stream_write(stopped, 0, []u8{1}, false), 0)
	// A server opens no stream; a client opens no stream past the limit of
	// the server.
	_, server_opened := stream_open(server)
	testing.expect(t, !server_opened)
}

// A reset of this side states the bytes that it sent, not the bytes that
// the application wrote (RFC 9000, section 4.5). The server has 2 stream
// records, so its window of the connection is 128 KiB. On each of two
// streams the client writes 64 KiB, which the server never reads, then
// 32 KiB more, which the limit of the stream (64 KiB) holds back. Then the
// stream is reset: by the client (stream_reset), then by a STOP_SENDING of
// the server.
// - The final size that the server takes is 64 KiB, the bytes sent. With
//   the bytes written (96 KiB) the server, which counts a final size
//   against its limits, closed the connection with FLOW_CONTROL_ERROR.
// - The two sides count the same bytes for the connection.
// - The server gives back the room of the bytes that it never read: its
//   limit grows to 256 KiB. The client then fills two new streams up to
//   that limit exactly, and the server does not close.
@(test)
a_reset_states_the_bytes_sent :: proc(t: ^testing.T) {
	endpoints := endpoints_make(server_stream_count = 2)
	defer free(endpoints)
	testing.expect(t, endpoints_connect(endpoints))
	client, server := &endpoints.client, &endpoints.server
	testing.expect_value(t, server.receive_window, u64(2 * STREAM_BUFFER_SIZE))
	data := make([]u8, STREAM_BUFFER_SIZE)
	defer delete(data)
	for by_stop_sending in ([]bool{false, true}) {
		identifier, opened := stream_open(client)
		if !testing.expectf(t, opened, "the client opened no stream (by STOP_SENDING: %v)", by_stop_sending) {
			return
		}
		testing.expect_value(t, stream_write(client, identifier, data, false), STREAM_BUFFER_SIZE)
		// Each byte goes and is acknowledged: the ring is free again, and
		// the limit of the stream is reached.
		for _ in 0 ..< 20_000 {
			sending := stream_of(client, identifier)
			if sending == nil || range_set_prefix(&sending.send_acknowledged) == STREAM_BUFFER_SIZE {
				break
			}
			endpoints_step(endpoints)
		}
		testing.expect_value(t, stream_write(client, identifier, data[:STREAM_BUFFER_SIZE / 2], false), STREAM_BUFFER_SIZE / 2)
		held := stream_of(client, identifier)
		testing.expect(t, held != nil && held.send_next == STREAM_BUFFER_SIZE && held.send_length == STREAM_BUFFER_SIZE + STREAM_BUFFER_SIZE / 2)
		if by_stop_sending {
			stream_stop_sending(server, identifier, 9)
		} else {
			stream_reset(client, identifier, 5)
		}
		for _ in 0 ..< 20_000 {
			taken := stream_of(server, identifier)
			if server.state != .Connected || (taken != nil && taken.reset_received) {
				break
			}
			endpoints_step(endpoints)
		}
		if !testing.expectf(t, server.state == .Connected, "the server closed with the code %x (by STOP_SENDING: %v)", server.close_error_code, by_stop_sending) {
			return
		}
		reset_stream := stream_of(server, identifier)
		testing.expectf(t, reset_stream != nil && reset_stream.reset_received && reset_stream.final_size == STREAM_BUFFER_SIZE, "the final size is not the 65536 bytes sent (by STOP_SENDING: %v)", by_stop_sending)
		testing.expect_value(t, client.data_sent_total, server.data_received_total)
		// Both directions end: the server reads the reset and ends its own
		// direction; the client reads that end.
		stream_read(server, identifier, nil)
		stream_write(server, identifier, nil, true)
		for _ in 0 ..< 20_000 {
			_, finished, _ := stream_read(client, identifier, data)
			if finished || stream_of(client, identifier) == nil {
				break
			}
			endpoints_step(endpoints)
		}
	}
	// The acknowledgements of the ends, the limit of streams, the limit of
	// the connection.
	for _ in 0 ..< 2000 {
		endpoints_step(endpoints)
	}
	testing.expect_value(t, server.data_received_total, u64(2 * STREAM_BUFFER_SIZE))
	testing.expect_value(t, server.receive_max_data, u64(4 * STREAM_BUFFER_SIZE))
	testing.expect_value(t, client.peer_max_data, u64(4 * STREAM_BUFFER_SIZE))
	for _ in 0 ..< 2 {
		identifier: u64
		opened := false
		for _ in 0 ..< 20_000 {
			identifier, opened = stream_open(client)
			if opened {
				break
			}
			endpoints_step(endpoints)
		}
		if !testing.expect(t, opened) {
			return
		}
		testing.expect_value(t, stream_write(client, identifier, data, false), STREAM_BUFFER_SIZE)
	}
	for _ in 0 ..< 20_000 {
		if server.state != .Connected || server.data_received_total == 4 * STREAM_BUFFER_SIZE {
			break
		}
		endpoints_step(endpoints)
	}
	testing.expectf(t, server.state == .Connected, "the server closed with the code %x", server.close_error_code)
	testing.expect_value(t, server.data_received_total, u64(4 * STREAM_BUFFER_SIZE))
	testing.expect_value(t, client.data_sent_total, server.data_received_total)
	testing.expect_value(t, server.data_received_total, server.receive_max_data)
}

// The bytes of a stream are erased when its record is freed: the rings of
// the record that held an echo are zero after the stream ended.
@(test)
the_rings_of_a_stream_that_ended_are_zero :: proc(t: ^testing.T) {
	endpoints := endpoints_make()
	defer free(endpoints)
	testing.expect(t, endpoints_connect(endpoints))
	streams: [1]Client_Stream_Echo
	testing.expect_value(t, streams_echo_run(t, endpoints, streams[:], 5000, 10_000_000), 1)
	for _ in 0 ..< 2000 {
		endpoints_step(endpoints)
	}
	for side in ([]^Connection{&endpoints.client, &endpoints.server}) {
		record := &side.streams[0]
		testing.expect(t, !record.in_use)
		zero := true
		for index in 0 ..< 5000 {
			zero = zero && record.send[index] == 0 && record.receive[index] == 0
		}
		testing.expectf(t, zero, "the record of the %v keeps bytes of the stream", side.configuration.tls.role)
	}
}
