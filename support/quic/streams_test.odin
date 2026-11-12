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
