#+build !freestanding
// The transport of QUIC on the host: two connections in memory, a client
// and a server, joined by a channel that the test controls (loss, reorder,
// duplicates, delay) and a fake clock. Each run is the same: the channel
// draws from a generator with a fixed seed.
package quic

import "contract:errors"
import "core:testing"
import "support:random"

CHANNEL_LIMIT :: 512

Channel_Datagram :: struct {
	in_use:     bool,
	to_server:  bool,
	deliver_at: u64,
	length:     int,
	bytes:      [MAX_DATAGRAM_SIZE]u8,
}

// The channel between the two sides. Each rate is in thousandths.
Channel :: struct {
	datagrams:           [CHANNEL_LIMIT]Channel_Datagram,
	state:               u64,
	loss:                u64,
	duplicate:           u64,
	reorder:             u64,
	delay:               u64, // Microseconds, one way.
	drop_to_server_from: int, // The datagrams to the server after this count are lost; 0: none.
	drop_first_to_server: int, // The first datagrams to the server that are lost.
	drop_first_to_client: int,
	cut:                 bool, // Each datagram, both ways, is lost: a peer that went silent. Each one is still counted.
	sent_to_server:      int,
	sent_to_client:      int,
}

channel_next :: proc(channel: ^Channel) -> u64 {
	channel.state ~= channel.state << 13
	channel.state ~= channel.state >> 7
	channel.state ~= channel.state << 17
	return channel.state
}

channel_send :: proc(channel: ^Channel, bytes: []u8, to_server: bool, now: u64) {
	count := to_server ? &channel.sent_to_server : &channel.sent_to_client
	count^ += 1
	if to_server && (count^ <= channel.drop_first_to_server || (channel.drop_to_server_from > 0 && count^ > channel.drop_to_server_from)) {
		return
	}
	if !to_server && count^ <= channel.drop_first_to_client {
		return
	}
	if channel.cut {
		return
	}
	if channel_next(channel) % 1000 < channel.loss {
		return
	}
	copies := channel_next(channel) % 1000 < channel.duplicate ? 2 : 1
	for _ in 0 ..< copies {
		delay := channel.delay
		if channel_next(channel) % 1000 < channel.reorder {
			delay += channel_next(channel) % (3 * channel.delay + 1)
		}
		for &slot in channel.datagrams {
			if slot.in_use {
				continue
			}
			slot.in_use = true
			slot.to_server = to_server
			slot.deliver_at = now + delay
			slot.length = copy(slot.bytes[:], bytes)
			break
		}
	}
}

channel_next_delivery :: proc(channel: ^Channel) -> u64 {
	next := NO_DEADLINE
	for &slot in channel.datagrams {
		if slot.in_use && slot.deliver_at < next {
			next = slot.deliver_at
		}
	}
	return next
}

TEST_STREAMS :: 4 // The stream records of each side of the tests.

Test_Endpoints :: struct {
	cryptography:     Cryptography,
	client_generator: random.Generator,
	server_generator: random.Generator,
	client:           Connection,
	server:           Connection,
	client_streams:   [TEST_STREAMS]Stream,
	server_streams:   [TEST_STREAMS]Stream,
	channel:          Channel,
	now:              u64,
	buffer:           [MAX_DATAGRAM_SIZE]u8,
}

// endpoints_make starts a client and a server with a fixed seed each, the
// server key of the TLS tests, and the key of the server pinned by the
// client. The server has server_stream_count stream records: its window of
// the connection is that count times STREAM_BUFFER_SIZE.
endpoints_make :: proc(idle_timeout_milliseconds: u64 = 30_000, server_stream_count := TEST_STREAMS) -> ^Test_Endpoints {
	endpoints := new(Test_Endpoints)
	endpoints.cryptography = module_cryptography()
	endpoints.channel.state = 0x5155_4943_2026_0d0d
	endpoints.channel.delay = 10_000
	endpoints.now = 1_000_000
	client_seed, server_seed: [random.SEED_SIZE]u8
	for index in 0 ..< random.SEED_SIZE {
		client_seed[index] = u8(7 + index)
		server_seed[index] = u8(77 + index)
	}
	random.generator_seed(&endpoints.client_generator, &client_seed, .Processor)
	random.generator_seed(&endpoints.server_generator, &server_seed, .Processor)
	server_configuration := Connection_Configuration{idle_timeout_milliseconds = idle_timeout_milliseconds}
	server_configuration.tls = {role = .Server, least_seed_strength = .Processor}
	server_configuration.tls.application_protocol_length = text_into(server_configuration.tls.application_protocol[:], "kernel-remote")
	copy(server_configuration.tls.server_private_key[:], bytes_of(SERVER_PRIVATE_KEY_OF_THE_TEST))
	client_configuration := Connection_Configuration{idle_timeout_milliseconds = idle_timeout_milliseconds}
	client_configuration.tls = {role = .Client, least_seed_strength = .Processor}
	client_configuration.tls.application_protocol_length = text_into(client_configuration.tls.application_protocol[:], "kernel-remote")
	error: errors.Error_Record
	secret := string(server_configuration.tls.server_private_key[:])
	result := client_configuration.tls.server_public_key[:]
	endpoints.cryptography.ed25519_public_key(&secret, &result, &error)
	connection_start_server(&endpoints.server, endpoints.server_streams[:server_stream_count], &server_configuration, &endpoints.cryptography, &endpoints.server_generator, endpoints.now, &error)
	connection_start_client(&endpoints.client, endpoints.client_streams[:], &client_configuration, &endpoints.cryptography, &endpoints.client_generator, endpoints.now, &error)
	return endpoints
}

// connection_copy gives a copy of a connection with copies of its stream
// records: a test that changes the copy leaves the original as it was.
connection_copy :: proc(source: ^Connection, allocator := context.allocator) -> ^Connection {
	copy_of_the_connection := new(Connection, allocator)
	copy_of_the_connection^ = source^
	streams := make([]Stream, len(source.streams), allocator)
	copy(streams, source.streams)
	copy_of_the_connection.streams = streams
	return copy_of_the_connection
}

// connection_copy_free frees a copy of connection_copy.
connection_copy_free :: proc(copy_of_the_connection: ^Connection) {
	delete(copy_of_the_connection.streams)
	free(copy_of_the_connection)
}

// endpoints_step sends what each side has, delivers each datagram that is
// due, acts on each deadline that passed, then moves the clock to the next
// event (1 ms at most, so that the applications run).
endpoints_step :: proc(endpoints: ^Test_Endpoints) {
	now := endpoints.now
	for side in 0 ..< 2 {
		connection := side == 0 ? &endpoints.client : &endpoints.server
		for _ in 0 ..< 64 {
			length := connection_datagram_send(connection, endpoints.buffer[:], now)
			if length == 0 {
				break
			}
			channel_send(&endpoints.channel, endpoints.buffer[:length], side == 0, now)
		}
	}
	for {
		earliest: ^Channel_Datagram
		for &slot in endpoints.channel.datagrams {
			if slot.in_use && slot.deliver_at <= now && (earliest == nil || slot.deliver_at < earliest.deliver_at) {
				earliest = &slot
			}
		}
		if earliest == nil {
			break
		}
		earliest.in_use = false
		error: errors.Error_Record
		connection_datagram_receive(earliest.to_server ? &endpoints.server : &endpoints.client, earliest.bytes[:earliest.length], now, &error)
	}
	for connection in ([]^Connection{&endpoints.client, &endpoints.server}) {
		if connection_deadline(connection) <= now {
			connection_time_passes(connection, now)
		}
	}
	next := min(channel_next_delivery(&endpoints.channel), connection_deadline(&endpoints.client), connection_deadline(&endpoints.server), now + 1000)
	endpoints.now = max(now + 1, next)
}

// endpoints_connect steps until both sides are connected and the client
// confirmed the handshake, for 60 s of the clock at most.
endpoints_connect :: proc(endpoints: ^Test_Endpoints) -> bool {
	end := endpoints.now + 60_000_000
	for endpoints.now < end {
		if endpoints.client.state == .Connected && endpoints.server.state == .Connected && endpoints.client.handshake_confirmed {
			return true
		}
		if endpoints.client.state == .Closed || endpoints.server.state == .Closed {
			return false
		}
		endpoints_step(endpoints)
	}
	return false
}

pattern_byte :: proc(index: int) -> u8 {
	return u8((index * 131 + (index >> 9)) & 0xFF)
}

// A handshake with no loss: both sides connected with ChaCha20-Poly1305,
// the client confirmed, the Initial and Handshake keys of both sides
// dropped, the transport parameters applied.
@(test)
handshake_over_the_transport :: proc(t: ^testing.T) {
	endpoints := endpoints_make()
	defer free(endpoints)
	testing.expect(t, endpoints_connect(endpoints))
	for connection in ([]^Connection{&endpoints.client, &endpoints.server}) {
		testing.expect(t, connection.spaces[.Initial].discarded)
		testing.expect(t, connection.spaces[.Handshake].discarded)
		testing.expect(t, connection.peer_parameters_applied)
		testing.expect_value(t, connection.tls.suite, Cipher_Suite.ChaCha20_Poly1305_Sha256)
		testing.expect_value(t, connection.peer_max_data, u64(TEST_STREAMS * STREAM_BUFFER_SIZE))
		testing.expect_value(t, connection.idle_timeout, u64(30_000_000))
	}
	testing.expect_value(t, endpoints.client.peer_max_streams_bidirectional, TEST_STREAMS)
	testing.expect_value(t, endpoints.server.peer_max_streams_bidirectional, 0)
	// Each datagram that carried an Initial packet of the client has 1200
	// bytes; the server never sent more than 3 times what it received
	// before the address was valid.
	testing.expect(t, endpoints.server.address_validated)
}

// echo_run sends total bytes from the client on a stream that it opens;
// the server writes back each byte that it reads; the client checks each
// byte that comes back. It gives the bytes that the client read, for the
// clock limit.
echo_run :: proc(t: ^testing.T, endpoints: ^Test_Endpoints, total: int, clock_limit: u64) -> (client_read: int, server_read: int) {
	pending := make([]u8, STREAM_BUFFER_SIZE)
	defer delete(pending)
	pending_start, pending_end := 0, 0
	server_finished, server_finish_written, client_finished := false, false, false
	written := 0
	chunk: [4096]u8
	end := endpoints.now + clock_limit
	identifier: u64
	opened := false
	for endpoints.now < end && !client_finished {
		if !opened {
			identifier, opened = stream_open(&endpoints.client)
		}
		// The client writes its bytes.
		for opened && written < total {
			count := min(len(chunk), total - written)
			for index in 0 ..< count {
				chunk[index] = pattern_byte(written + index)
			}
			taken := stream_write(&endpoints.client, identifier, chunk[:count], written + count == total)
			written += taken
			if taken < count {
				break
			}
		}
		// The server writes back what it read.
		for {
			if pending_start < pending_end {
				taken := stream_write(&endpoints.server, identifier, pending[pending_start:pending_end], false)
				pending_start += taken
				if pending_start < pending_end {
					break
				}
			}
			pending_start, pending_end = 0, 0
			count, finished, _ := stream_read(&endpoints.server, identifier, pending[:])
			server_read += count
			pending_end = count
			if finished {
				server_finished = true
			}
			if count == 0 {
				break
			}
		}
		if server_finished && pending_start == pending_end && !server_finish_written {
			stream_write(&endpoints.server, identifier, nil, true)
			server_finish_written = true
		}
		// The client checks what comes back.
		for {
			count, finished, _ := stream_read(&endpoints.client, identifier, chunk[:])
			for index in 0 ..< count {
				if chunk[index] != pattern_byte(client_read + index) {
					testing.expectf(t, false, "the byte %d came back changed", client_read + index)
					return
				}
			}
			client_read += count
			if finished {
				client_finished = true
			}
			if count == 0 {
				break
			}
		}
		endpoints_step(endpoints)
	}
	return
}

// An echo of a short text with no loss.
@(test)
echo_with_no_loss :: proc(t: ^testing.T) {
	endpoints := endpoints_make()
	defer free(endpoints)
	testing.expect(t, endpoints_connect(endpoints))
	client_read, server_read := echo_run(t, endpoints, 5000, 10_000_000)
	testing.expect_value(t, server_read, 5000)
	testing.expect_value(t, client_read, 5000)
	// The stream of the client ended, or its last byte went.
	stream := stream_of(&endpoints.client, 0)
	testing.expect(t, stream == nil || stream.finish_sent)
}

// 1 MiB each way, with 5 % of the datagrams lost, 5 % delayed (so that
// they come out of order), and 1 % duplicated; the handshake goes through
// the same channel.
@(test)
one_mebibyte_each_way_with_loss :: proc(t: ^testing.T) {
	endpoints := endpoints_make()
	defer free(endpoints)
	endpoints.channel.loss = 50
	endpoints.channel.reorder = 50
	endpoints.channel.duplicate = 10
	testing.expect(t, endpoints_connect(endpoints))
	total := 1 << 20
	client_read, server_read := echo_run(t, endpoints, total, 600_000_000)
	testing.expect_value(t, server_read, total)
	testing.expect_value(t, client_read, total)
	testing.expect(t, endpoints.client.state == .Connected && endpoints.server.state == .Connected)
}

// The first datagram of each side is lost: the probe timeout sends the
// handshake again.
@(test)
handshake_after_the_first_datagrams_are_lost :: proc(t: ^testing.T) {
	endpoints := endpoints_make()
	defer free(endpoints)
	endpoints.channel.drop_first_to_server = 1
	endpoints.channel.drop_first_to_client = 1
	start := endpoints.now
	testing.expect(t, endpoints_connect(endpoints))
	// One probe timeout at least: 333 ms and more before a sample.
	testing.expect(t, endpoints.now - start >= INITIAL_ROUND_TRIP_TIME)
}

// The server never hears the client after its first datagram: before the
// address is valid, it sends 3 times the bytes that it received at most,
// then it stops, and its timer too.
@(test)
anti_amplification_limit :: proc(t: ^testing.T) {
	endpoints := endpoints_make()
	defer free(endpoints)
	endpoints.channel.drop_to_server_from = 1
	// Under the handshake deadline, at which the record of the server ends.
	end := endpoints.now + HANDSHAKE_TIME_LIMIT - 1_000_000
	for endpoints.now < end {
		endpoints_step(endpoints)
		testing.expect(t, endpoints.server.bytes_sent <= 3 * endpoints.server.bytes_received)
	}
	testing.expect(t, !endpoints.server.address_validated)
	testing.expect(t, endpoints.server.bytes_received >= MAX_DATAGRAM_SIZE)
	testing.expect(t, endpoints.server.bytes_sent > 0)
	_, _, probe := loss_detection_deadline(&endpoints.server)
	testing.expect(t, amplification_budget(&endpoints.server) < MAX_DATAGRAM_SIZE)
	testing.expect(t, !probe)
}

// With no packet for longer than the idle timeout, each side ends the
// connection, and sends nothing.
@(test)
idle_timeout :: proc(t: ^testing.T) {
	endpoints := endpoints_make(idle_timeout_milliseconds = 2000)
	defer free(endpoints)
	testing.expect(t, endpoints_connect(endpoints))
	connected_at := endpoints.now
	for _ in 0 ..< 100_000 {
		if endpoints.client.state == .Closed && endpoints.server.state == .Closed {
			break
		}
		endpoints_step(endpoints)
	}
	testing.expect_value(t, endpoints.client.state, Connection_State.Closed)
	testing.expect_value(t, endpoints.server.state, Connection_State.Closed)
	testing.expect(t, endpoints.client.closed_by_idle_timeout && endpoints.server.closed_by_idle_timeout)
	testing.expect(t, endpoints.now - connected_at >= 2_000_000)
	testing.expect(t, endpoints.client.spaces[.Application].send_keys.key == [32]u8{})
}

// The client closes with an error code of the application: the server
// drains with that code, and both end after three probe timeouts.
@(test)
connection_close_of_the_application :: proc(t: ^testing.T) {
	endpoints := endpoints_make()
	defer free(endpoints)
	testing.expect(t, endpoints_connect(endpoints))
	connection_close(&endpoints.client, 7, endpoints.now)
	testing.expect_value(t, endpoints.client.state, Connection_State.Closing)
	for _ in 0 ..< 100_000 {
		if endpoints.client.state == .Closed && endpoints.server.state == .Closed {
			break
		}
		endpoints_step(endpoints)
	}
	testing.expect_value(t, endpoints.client.state, Connection_State.Closed)
	testing.expect_value(t, endpoints.server.state, Connection_State.Closed)
	testing.expect(t, endpoints.server.closed_by_peer)
	testing.expect_value(t, endpoints.server.close_error_code, 7)
	testing.expect(t, endpoints.server.close_is_application)
}

// A connected pair, made once for the tests of hostile frames: each case
// works on a copy of a side.
connected_endpoints :: proc() -> ^Test_Endpoints {
	endpoints := endpoints_make()
	endpoints_connect(endpoints)
	return endpoints
}

// frames_on_a_copy gives the frames to a copy of a side at a level, and
// gives the copy.
frames_on_a_copy :: proc(side: ^Connection, level: Encryption_Level, frames: []u8) -> ^Connection {
	copy_of_the_side := connection_copy(side, context.temp_allocator)
	frames_process(copy_of_the_side, level, frames, 2_000_000_000)
	return copy_of_the_side
}

// One frame of each type, which a connected server or client accepts.
Frame_Case :: struct {
	name:      string,
	to_client: bool,
	frame:     string,
	// A cut of the frame is a FRAME_ENCODING_ERROR: each field has its
	// length. False for a STREAM frame with no Length, whose data runs to
	// the end of the packet.
	cut_is_an_error: bool,
}

FRAME_CASES := [?]Frame_Case {
	{"PING", false, "01", true},
	{"ACK", false, "0200000000", true},
	{"ACK with ECN", false, "03000000000a0b0c", true},
	{"RESET_STREAM", false, "04000700", true},
	{"STOP_SENDING", false, "050007", true},
	{"CRYPTO", false, "060000", true},
	{"NEW_TOKEN", true, "0701aa", true},
	{"STREAM with no offset and no length", false, "080068656c6c6f", false},
	{"STREAM with a length", false, "0a000568656c6c6f", true},
	{"STREAM with an offset, a length and the end", false, "0f00020568656c6c6f", true},
	{"MAX_DATA", false, "104400", true},
	{"MAX_STREAM_DATA", false, "11004400", true},
	{"MAX_STREAMS bidirectional", false, "1201", true},
	{"MAX_STREAMS unidirectional", false, "1301", true},
	{"DATA_BLOCKED", false, "1400", true},
	{"STREAM_DATA_BLOCKED", false, "150000", true},
	{"STREAMS_BLOCKED bidirectional", false, "1600", true},
	{"STREAMS_BLOCKED unidirectional", false, "1700", true},
	{"NEW_CONNECTION_ID", false, "1801000801020304050607080102030405060708090a0b0c0d0e0f10", true},
	{"RETIRE_CONNECTION_ID", false, "1900", true},
	{"PATH_CHALLENGE", false, "1a0102030405060708", true},
	{"PATH_RESPONSE", false, "1b0102030405060708", true},
	{"CONNECTION_CLOSE", false, "1c070600", true},
	{"CONNECTION_CLOSE of the application", false, "1d0700", true},
	{"HANDSHAKE_DONE", true, "1e", true},
}

// Each frame whole is accepted; each frame cut at each length (its type
// kept) closes the connection with FRAME_ENCODING_ERROR, and never traps.
@(test)
each_frame_cut_at_each_length :: proc(t: ^testing.T) {
	endpoints := connected_endpoints()
	defer free(endpoints)
	testing.expect(t, endpoints.server.state == .Connected && endpoints.client.handshake_confirmed)
	for item in FRAME_CASES {
		side := item.to_client ? &endpoints.client : &endpoints.server
		frame := bytes_of(item.frame)
		whole := frames_on_a_copy(side, .Application, frame)
		testing.expectf(t, whole.state == .Connected || whole.state == .Draining, "%s whole: the state is %v, the error %x", item.name, whole.state, whole.close_error_code)
		for length in 1 ..< len(frame) {
			cut := frames_on_a_copy(side, .Application, frame[:length])
			if item.cut_is_an_error {
				testing.expectf(t, cut.state == .Closing && cut.close_error_code == u64(Transport_Error.Frame_Encoding_Error), "%s cut to %d bytes: the state is %v, the error %x", item.name, length, cut.state, cut.close_error_code)
			}
		}
		free_all(context.temp_allocator)
	}
}

// The error code of each hostile frame: lengths near 2^62, an ACK of a
// packet that was never sent, data past the limits, streams that may not
// be, a final size that changes, a frame at a level where it may not go.
@(test)
hostile_frames_and_their_error_codes :: proc(t: ^testing.T) {
	endpoints := connected_endpoints()
	defer free(endpoints)
	server := &endpoints.server
	never_sent := server.spaces[.Application].next_packet_number
	never_sent_bytes: [8]u8
	never_sent_length := variable_length_integer_write(never_sent_bytes[:], 0, never_sent, variable_length_integer_size(never_sent))
	Case :: struct {
		name:     string,
		to_client: bool,
		level:    Encryption_Level,
		frames:   string,
		expected: Transport_Error,
	}
	largest :: "ffffffffffffffff" // 2^62 - 1 in 8 bytes.
	cases := []Case {
		{"STREAM that ends past 2^62 - 1", false, .Application, "0e00" + largest + "0161", .Frame_Encoding_Error},
		{"STREAM past the limit of the stream", false, .Application, "0e00c00000003ffffffe0161", .Flow_Control_Error},
		{"STREAM one byte past the window", false, .Application, "0e0080010000" + "0161", .Flow_Control_Error},
		{"CRYPTO that ends past 2^62 - 1", false, .Application, "06" + largest + "0161", .Frame_Encoding_Error},
		{"CRYPTO past its buffer", false, .Application, "0650000161", .Crypto_Buffer_Exceeded},
		{"ACK of the largest number", false, .Application, "02" + largest + "000000", .Protocol_Violation},
		{"ACK with a first range past the largest", false, .Application, "0200000001", .Frame_Encoding_Error},
		{"ACK with 2^62 - 1 ranges", false, .Application, "020000" + largest + "00", .Frame_Encoding_Error},
		{"ACK with a gap below 0", false, .Application, "02000001000000", .Frame_Encoding_Error},
		{"MAX_STREAMS over 2^60", false, .Application, "12d000000000000001", .Frame_Encoding_Error},
		{"STREAMS_BLOCKED over 2^60", false, .Application, "16d000000000000001", .Frame_Encoding_Error},
		{"CONNECTION_CLOSE with a reason of 2^62 - 1 bytes", false, .Application, "1c0000" + largest, .Frame_Encoding_Error},
		{"NEW_TOKEN of 2^62 - 1 bytes", true, .Application, "07" + largest, .Frame_Encoding_Error},
		{"NEW_TOKEN of 0 bytes", true, .Application, "0700", .Frame_Encoding_Error},
		{"NEW_TOKEN to a server", false, .Application, "0701aa", .Protocol_Violation},
		{"RESET_STREAM with a final size of 2^62 - 1", false, .Application, "040007" + largest, .Flow_Control_Error},
		{"PING with a type of 2 bytes", false, .Application, "4001", .Protocol_Violation},
		{"a frame type that does not exist", false, .Application, "21", .Frame_Encoding_Error},
		{"STREAM 16: the fifth stream of the client, over the limit of 4", false, .Application, "0a100161", .Stream_Limit_Error},
		{"STREAM 1: a stream of the server that it did not open", false, .Application, "0a010161", .Stream_State_Error},
		{"STREAM 2: a unidirectional stream of the client", false, .Application, "0a020161", .Stream_Limit_Error},
		{"STREAM 3: a unidirectional stream of the server", false, .Application, "0a030161", .Stream_State_Error},
		{"STREAM 0 to a client that did not open it", true, .Application, "0a000161", .Stream_State_Error},
		{"a final size that changes", false, .Application, "0b000161" + "0e00010161", .Final_Size_Error},
		{"a final size below the data", false, .Application, "0a00026161" + "0b000161", .Final_Size_Error},
		{"STREAM in an Initial packet", false, .Initial, "0a000161", .Protocol_Violation},
		{"HANDSHAKE_DONE to a server", false, .Application, "1e", .Protocol_Violation},
		{"NEW_CONNECTION_ID with Retire Prior To above its number", false, .Application, "1801020801020304050607080102030405060708090a0b0c0d0e0f10", .Frame_Encoding_Error},
		{"NEW_CONNECTION_ID of 21 bytes", false, .Application, "1801001501020304050607080910111213141516171819202101020304050607080102030405060708", .Frame_Encoding_Error},
		{"RETIRE_CONNECTION_ID of a number never given", false, .Application, "1901", .Protocol_Violation},
		{"an empty packet", false, .Application, "", .Protocol_Violation},
	}
	for item in cases {
		side := item.to_client ? &endpoints.client : &endpoints.server
		changed := frames_on_a_copy(side, item.level, bytes_of(item.frames))
		testing.expectf(t, changed.state == .Closing && changed.close_error_code == u64(item.expected), "%s: the state is %v, the error %x, not %v", item.name, changed.state, changed.close_error_code, item.expected)
	}
	// An ACK of the next number of the server, which it never sent.
	ack := make([dynamic]u8, context.temp_allocator)
	append(&ack, FRAME_ACK)
	append(&ack, ..never_sent_bytes[:never_sent_length])
	append(&ack, 0, 0, 0)
	changed := frames_on_a_copy(server, .Application, ack[:])
	testing.expect_value(t, changed.close_error_code, u64(Transport_Error.Protocol_Violation))
	// One byte under the window is taken.
	taken := frames_on_a_copy(server, .Application, bytes_of("0e008000ffff0161"))
	testing.expect_value(t, taken.state, Connection_State.Connected)
	taken_stream := stream_of(taken, 0)
	testing.expect(t, taken_stream != nil && taken_stream.highest_received == u64(STREAM_BUFFER_SIZE))
}

// 50 000 random packets that pass the AEAD (sealed with the 1-RTT keys of
// the client, which the test made) and carry random frames, to a connected
// server: none traps. A third are random bytes, a third start with the type
// of a frame, a third are a row of frames with random small fields. The
// server answers each one, and its timers run.
@(test)
random_authentic_packets_never_trap :: proc(t: ^testing.T) {
	endpoints := connected_endpoints()
	defer free(endpoints)
	// The snapshot keeps the state of each stream, not its buffers: the
	// test checks that nothing traps, not the bytes of the streams.
	snapshot := new(Connection)
	defer free(snapshot)
	snapshot^ = endpoints.server
	stream_states: [TEST_STREAMS]Stream_State
	for stream, index in endpoints.server.streams {
		stream_states[index] = stream.state
	}
	server := connection_copy(&endpoints.server)
	defer connection_copy_free(server)
	server_streams := server.streams
	keys := endpoints.client.spaces[.Application].send_keys
	state: u64 = 0x4652_414d_4553_0001
	next :: proc(state: ^u64) -> u64 {
		state^ ~= state^ << 13
		state^ ~= state^ >> 7
		state^ ~= state^ << 17
		return state^
	}
	types := [?]u8{0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x0a, 0x0b, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e}
	packet_number := endpoints.client.spaces[.Application].next_packet_number + 100
	now := endpoints.now
	opened, closed := 0, 0
	packet: [MAX_DATAGRAM_SIZE]u8
	out: [MAX_DATAGRAM_SIZE]u8
	for round in 0 ..< 50_000 {
		payload_length := 1 + int(next(&state) % 200)
		header_length := 1 + CONNECTION_ID_SIZE
		number_offset := header_length
		payload := packet[number_offset + PACKET_NUMBER_SIZE:][:payload_length]
		for &byte in payload {
			byte = u8(next(&state))
		}
		switch round % 3 {
		case 1:
			payload[0] = types[next(&state) % len(types)]
		case 2:
			// A row of frames: a type, then fields of 1 byte (values under
			// 64), so that the reading goes past the first field.
			for index in 0 ..< payload_length {
				payload[index] = index % 4 == 0 ? types[next(&state) % len(types)] : u8(next(&state) % 64)
			}
		}
		packet[0] = FIXED_BIT | u8(PACKET_NUMBER_SIZE - 1)
		copy(packet[1:], server.local_connection_id[:])
		error: errors.Error_Record
		end, sealed := packet_seal(&endpoints.cryptography, &keys, packet[:], 0, number_offset, payload_length, packet_number, &error)
		testing.expect(t, sealed)
		packet_number += 1
		now += 100
		if connection_datagram_receive(server, packet[:end], now, &error) {
			opened += 1
		}
		for _ in 0 ..< 4 {
			if connection_datagram_send(server, out[:], now) == 0 {
				break
			}
		}
		if connection_deadline(server) <= now {
			connection_time_passes(server, now)
		}
		if server.state != .Connected {
			closed += 1
			server^ = snapshot^
			server.streams = server_streams
			for &stream, index in server.streams {
				stream.state = stream_states[index]
			}
		}
	}
	testing.expect(t, opened > 40_000, "the packets did not open: the test reached no frame")
	testing.expect(t, closed > 0)
}

// The first 24 bytes of a preferred_address: 192.0.2.1 port 4433, then
// 2001:db8::1 port 4433 (addresses of documentation).
PREFERRED_ADDRESSES :: "c0000201" + "1151" + "20010db8000000000000000000000001" + "1151"
// The 16 bytes of the stateless reset token of a preferred_address.
PREFERRED_TOKEN :: "000102030405060708090a0b0c0d0e0f"

// The transport parameters of a peer: each rule of RFC 9000, section 18.2,
// that a value can break gives TRANSPORT_PARAMETER_ERROR; an unknown
// parameter is skipped.
@(test)
transport_parameters_of_a_peer :: proc(t: ^testing.T) {
	// initial_source_connection_id of 1 byte (0f 01 aa) at the end of each.
	Case :: struct {
		name:     string,
		sender:   Tls_Role,
		bytes:    string,
		expected: Transport_Error,
	}
	cases := []Case {
		{"the identifier alone", .Client, "0f01aa", .No_Error},
		{"an unknown parameter", .Client, "2102beef" + "0f01aa", .No_Error},
		{"no initial_source_connection_id", .Client, "040101", .Transport_Parameter_Error},
		{"a server with no original_destination_connection_id", .Server, "0f01aa", .Transport_Parameter_Error},
		{"original_destination_connection_id from a client", .Client, "000101" + "0f01aa", .Transport_Parameter_Error},
		{"stateless_reset_token from a client", .Client, "021000000000000000000000000000000000" + "0f01aa", .Transport_Parameter_Error},
		{"a parameter two times", .Client, "040101" + "040101" + "0f01aa", .Transport_Parameter_Error},
		{"max_udp_payload_size of 1199", .Client, "030244af" + "0f01aa", .Transport_Parameter_Error},
		{"ack_delay_exponent of 21", .Client, "0a0115" + "0f01aa", .Transport_Parameter_Error},
		{"max_ack_delay of 2^14", .Client, "0b0480004000" + "0f01aa", .Transport_Parameter_Error},
		{"active_connection_id_limit of 1", .Client, "0e0101" + "0f01aa", .Transport_Parameter_Error},
		{"initial_max_streams_bidi over 2^60", .Client, "0808d000000000000001" + "0f01aa", .Transport_Parameter_Error},
		{"an integer shorter than its length", .Client, "040201" + "0f01aa", .Transport_Parameter_Error},
		{"a connection identifier of 21 bytes", .Client, "0f15000102030405060708090a0b0c0d0e0f1011121314", .Transport_Parameter_Error},
		{"a length past the end", .Client, "0f05aa", .Transport_Parameter_Error},
		{"disable_active_migration with a value", .Client, "0c0101" + "0f01aa", .Transport_Parameter_Error},
		// RFC 9000, section 18.2, gives max_udp_payload_size no largest
		// value: 65528 (80 00 ff f8), one over what UDP carries, is taken.
		{"max_udp_payload_size of 65528", .Client, "03048000fff8" + "0f01aa", .No_Error},
		// preferred_address (0d): 24 bytes of addresses and ports, the length
		// of a connection identifier, the identifier, a token of 16 bytes.
		// The server names its first identifier (00 01 bb) in each case.
		{"preferred_address with an identifier of 4 bytes", .Server, "0d2d" + PREFERRED_ADDRESSES + "04" + "c1c2c3c4" + PREFERRED_TOKEN + "0001bb" + "0f01aa", .No_Error},
		{"preferred_address from a client", .Client, "0d2d" + PREFERRED_ADDRESSES + "04" + "c1c2c3c4" + PREFERRED_TOKEN + "0f01aa", .Transport_Parameter_Error},
		{"preferred_address cut before its identifier", .Server, "0d10" + "c0000201" + "1151" + "20010db8000000000000" + "0001bb" + "0f01aa", .Transport_Parameter_Error},
		{"preferred_address one byte short", .Server, "0d2c" + PREFERRED_ADDRESSES + "04" + "c1c2c3" + PREFERRED_TOKEN + "0001bb" + "0f01aa", .Transport_Parameter_Error},
		{"preferred_address one byte long", .Server, "0d2e" + PREFERRED_ADDRESSES + "04" + "c1c2c3c4" + PREFERRED_TOKEN + "00" + "0001bb" + "0f01aa", .Transport_Parameter_Error},
		{"preferred_address with an empty identifier", .Server, "0d29" + PREFERRED_ADDRESSES + "00" + PREFERRED_TOKEN + "0001bb" + "0f01aa", .Transport_Parameter_Error},
		{"preferred_address with an identifier of 21 bytes", .Server, "0d3e" + PREFERRED_ADDRESSES + "15" + "000102030405060708090a0b0c0d0e0f1011121314" + PREFERRED_TOKEN + "0001bb" + "0f01aa", .Transport_Parameter_Error},
		{"preferred_address from a server with an empty identifier", .Server, "0d2d" + PREFERRED_ADDRESSES + "04" + "c1c2c3c4" + PREFERRED_TOKEN + "0001bb" + "0f00", .Transport_Parameter_Error},
	}
	for item in cases {
		parameters: Transport_Parameters
		result := transport_parameters_read(bytes_of(item.bytes), item.sender, &parameters)
		testing.expectf(t, result == item.expected, "%s: %v, not %v", item.name, result, item.expected)
	}
	// What this side writes, it reads back.
	written: Transport_Parameters = transport_parameters_default()
	written.initial_max_data = 65536
	written.max_idle_timeout = 30_000
	written.initial_source_connection_id_length = copy(written.initial_source_connection_id[:], []u8{1, 2, 3, 4, 5, 6, 7, 8})
	written.has_initial_source_connection_id = true
	written.original_destination_connection_id_length = copy(written.original_destination_connection_id[:], []u8{9, 9, 9, 9, 9, 9, 9, 9})
	written.has_original_destination_connection_id = true
	buffer: [TRANSPORT_PARAMETERS_LIMIT]u8
	length := transport_parameters_write(&written, .Server, buffer[:])
	testing.expect(t, length > 0)
	read: Transport_Parameters
	testing.expect_value(t, transport_parameters_read(buffer[:length], .Server, &read), Transport_Error.No_Error)
	testing.expect_value(t, read.initial_max_data, 65536)
	testing.expect_value(t, read.max_idle_timeout, 30_000)
	testing.expect_value(t, read.initial_source_connection_id_length, 8)
	testing.expect_value(t, read.original_destination_connection_id_length, 8)
}

// authentic_packet_receive seals frames in a 1-RTT packet with the keys of
// the client of the test, gives it to a server, and gives the sealed
// packet.
authentic_packet_receive :: proc(endpoints: ^Test_Endpoints, server: ^Connection, keys: ^Packet_Keys, packet_number: u64, frames: []u8, now: u64) -> (sealed: []u8, processed: bool) {
	packet := make([]u8, 1 + CONNECTION_ID_SIZE + PACKET_NUMBER_SIZE + len(frames) + TAG_SIZE, context.temp_allocator)
	packet[0] = FIXED_BIT | u8(PACKET_NUMBER_SIZE - 1)
	copy(packet[1:], server.local_connection_id[:])
	number_offset := 1 + CONNECTION_ID_SIZE
	copy(packet[number_offset + PACKET_NUMBER_SIZE:], frames)
	error: errors.Error_Record
	end, ok := packet_seal(&endpoints.cryptography, keys, packet, 0, number_offset, len(frames), packet_number, &error)
	assert(ok)
	sealed = packet[:end]
	processed = connection_datagram_receive(server, sealed, now, &error)
	return
}

// A STREAM frame of stream 0 with an offset of 4 bytes and a length of 2
// bytes, with the bytes of the pattern at that offset.
stream_frame_of_the_pattern :: proc(offset: int, length: int) -> []u8 {
	frame := make([]u8, 1 + 1 + 4 + 2 + length, context.temp_allocator)
	frame[0] = FRAME_STREAM | FRAME_STREAM_FLAG_OFFSET | FRAME_STREAM_FLAG_LENGTH
	frame[1] = 0
	variable_length_integer_write(frame, 2, u64(offset), 4)
	variable_length_integer_write(frame, 6, u64(length), 2)
	for index in 0 ..< length {
		frame[8 + index] = pattern_byte(offset + index)
	}
	return frame
}

// Data with more than 32 holes: the islands past the 32nd have no place in
// the set of the stream, so their packets are not acknowledged. The test
// sends again, as a peer does, the data of each packet that was not
// acknowledged, after the holes. Every byte comes once, in order. Before
// the correction, each packet was acknowledged, the dropped islands never
// came again, and the read stopped at the 33rd island (6500 bytes of 8000).
@(test)
data_with_no_place_is_not_acknowledged :: proc(t: ^testing.T) {
	endpoints := connected_endpoints()
	defer free(endpoints)
	server := connection_copy(&endpoints.server)
	defer connection_copy_free(server)
	keys := endpoints.client.spaces[.Application].send_keys
	number := endpoints.client.spaces[.Application].next_packet_number + 10
	now := endpoints.now
	UNIT :: 100
	UNITS :: 80
	numbers: [UNITS]u64
	// The odd units: 40 islands.
	for unit := 1; unit < UNITS; unit += 2 {
		numbers[unit] = number
		_, processed := authentic_packet_receive(endpoints, server, &keys, number, stream_frame_of_the_pattern(unit * UNIT, UNIT), now)
		testing.expect(t, processed)
		number += 1
	}
	not_acknowledged := make([dynamic]int, context.temp_allocator)
	for unit := 1; unit < UNITS; unit += 2 {
		if !range_set_contains(&server.spaces[.Application].received, numbers[unit]) {
			append(&not_acknowledged, unit)
		}
	}
	testing.expect_value(t, len(not_acknowledged), 8)
	// The holes, then the islands that were not acknowledged.
	for unit := 0; unit < UNITS; unit += 2 {
		authentic_packet_receive(endpoints, server, &keys, number, stream_frame_of_the_pattern(unit * UNIT, UNIT), now)
		number += 1
	}
	for unit in not_acknowledged {
		authentic_packet_receive(endpoints, server, &keys, number, stream_frame_of_the_pattern(unit * UNIT, UNIT), now)
		number += 1
	}
	testing.expect_value(t, server.state, Connection_State.Connected)
	read := 0
	buffer: [UNITS * UNIT]u8
	for {
		count, _, _ := stream_read(server, 0, buffer[read:])
		if count == 0 {
			break
		}
		read += count
	}
	testing.expect_value(t, read, UNITS * UNIT)
	for index in 0 ..< read {
		if buffer[index] != pattern_byte(index) {
			testing.expectf(t, false, "the byte %d came changed", index)
			break
		}
	}
}

// The same for CRYPTO data: past 32 islands, a packet whose data had no
// place is not acknowledged. Before the correction, all 40 were.
@(test)
crypto_data_with_no_place_is_not_acknowledged :: proc(t: ^testing.T) {
	endpoints := connected_endpoints()
	defer free(endpoints)
	server := connection_copy(&endpoints.server)
	defer connection_copy_free(server)
	keys := endpoints.client.spaces[.Application].send_keys
	number := endpoints.client.spaces[.Application].next_packet_number + 10
	not_acknowledged := 0
	for island in 0 ..< 40 {
		frame: [1 + 2 + 1 + 10]u8
		frame[0] = FRAME_CRYPTO
		variable_length_integer_write(frame[:], 1, u64(20 * island + 10), 2)
		frame[3] = 10
		authentic_packet_receive(endpoints, server, &keys, number, frame[:], endpoints.now)
		if !range_set_contains(&server.spaces[.Application].received, number) {
			not_acknowledged += 1
		}
		number += 1
	}
	testing.expect_value(t, not_acknowledged, 8)
	testing.expect_value(t, server.state, Connection_State.Connected)
}

// On the send side: a lost packet whose data has no place in the set of the
// bytes to send again stays in flight, and so does an acknowledged packet
// whose data has no place in the set of acknowledged bytes. Before the
// correction, both were removed: the data of the first was never sent
// again, and the second never counted as acknowledged.
@(test)
sent_data_with_no_place_stays_in_flight :: proc(t: ^testing.T) {
	connection := new(Connection)
	defer free(connection)
	streams := make([]Stream, 1)
	defer delete(streams)
	connection.streams = streams
	space := &connection.spaces[.Application]
	stream := &streams[0]
	stream.state = {in_use = true, identifier = 0}
	for index in u64(0) ..< RANGE_SET_LIMIT {
		range_set_insert(&stream.send_again, 10 * index + 2, 10 * index + 5)
		range_set_insert(&stream.send_acknowledged, 10 * index + 2, 10 * index + 5)
	}
	packet := &space.sent[0]
	packet^ = {in_use = true, packet_number = 3, size = 1200, stream_offset = 1000, stream_length = 5}
	space.ack_eliciting_in_flight = 1
	connection.bytes_in_flight = 1200
	sent_packet_lost(connection, .Application, packet)
	testing.expect(t, packet.in_use)
	testing.expect_value(t, connection.bytes_in_flight, 1200)
	sent_packet_acknowledged(connection, .Application, packet)
	testing.expect(t, packet.in_use)
	// With a place, the packet goes, and its data waits to be sent again.
	stream.send_again = {}
	sent_packet_lost(connection, .Application, packet)
	testing.expect(t, !packet.in_use)
	testing.expect_value(t, connection.bytes_in_flight, 0)
	testing.expect(t, range_set_contains(&stream.send_again, 1000))
}

// A datagram of random bytes shaped as an Initial packet of version 1 does
// not take the record of a server: the real client connects after it.
// Before the correction, the server took the Destination Connection ID of
// the random datagram, and refused the real client.
@(test)
a_forged_initial_does_not_take_the_server :: proc(t: ^testing.T) {
	endpoints := endpoints_make()
	defer free(endpoints)
	forged: [MAX_DATAGRAM_SIZE]u8
	state: u64 = 0x464f_5247_4544_0001
	for &byte in forged {
		state ~= state << 13
		state ~= state >> 7
		state ~= state << 17
		byte = u8(state)
	}
	forged[0] = LONG_HEADER_FORM | FIXED_BIT | u8(PACKET_NUMBER_SIZE - 1)
	forged[1], forged[2], forged[3], forged[4] = 0, 0, 0, 1
	forged[5] = CONNECTION_ID_SIZE // Then 8 random bytes.
	forged[14] = 0 // An empty Source Connection ID.
	forged[15] = 0 // An empty token.
	variable_length_integer_write(forged[:], 16, MAX_DATAGRAM_SIZE - 18, 2)
	error: errors.Error_Record
	testing.expect(t, !connection_datagram_receive(&endpoints.server, forged[:], endpoints.now, &error))
	testing.expect(t, !endpoints.server.tls_started)
	testing.expect(t, !endpoints.server.spaces[.Initial].keys_installed)
	testing.expect(t, endpoints_connect(endpoints))
}

// An authentic Initial with no ClientHello takes the record of a server
// (anyone can make one: its keys come from a public value). With no idle
// timeout, the handshake deadline still ends the record. Before the
// correction, the record waited for ever.
@(test)
an_initial_alone_ends_at_the_handshake_deadline :: proc(t: ^testing.T) {
	endpoints := endpoints_make(idle_timeout_milliseconds = 0)
	defer free(endpoints)
	client_keys, server_keys: Packet_Keys
	error: errors.Error_Record
	initial_keys(&endpoints.cryptography, bytes_of(ORIGINAL_DESTINATION_CONNECTION_ID), &client_keys, &server_keys, &error)
	// 23 bytes of header, a PING and PADDING, 16 bytes of tag: 1200.
	frames: [MAX_DATAGRAM_SIZE - 23 - TAG_SIZE]u8
	frames[0] = FRAME_PING
	datagram: [MAX_DATAGRAM_SIZE]u8
	end, ok := long_packet_write(&endpoints.cryptography, &client_keys, datagram[:], 0, .Initial, nil, frames[:], 0, 0, &error)
	testing.expectf(t, ok && end == MAX_DATAGRAM_SIZE, "%v %d", error, end)
	start := endpoints.now
	testing.expect(t, connection_datagram_receive(&endpoints.server, datagram[:end], start, &error))
	testing.expect(t, endpoints.server.tls_started)
	server := &endpoints.server
	out: [MAX_DATAGRAM_SIZE]u8
	for now := start; now < start + 2 * HANDSHAKE_TIME_LIMIT && server.state != .Closed; now += 100_000 {
		for connection_datagram_send(server, out[:], now) > 0 {}
		if connection_deadline(server) <= now {
			connection_time_passes(server, now)
		}
	}
	testing.expect_value(t, server.state, Connection_State.Closed)
	testing.expect(t, server.closed_by_handshake_timeout)
}

// A packet whose number was in a range that the set forgot is refused, even
// when it is authentic: a replay. Before the correction, it was opened and
// its frames were taken a second time (here, a PATH_CHALLENGE answered
// again).
@(test)
a_forgotten_packet_number_is_refused :: proc(t: ^testing.T) {
	endpoints := connected_endpoints()
	defer free(endpoints)
	server := connection_copy(&endpoints.server)
	defer connection_copy_free(server)
	keys := endpoints.client.spaces[.Application].send_keys
	base := endpoints.client.spaces[.Application].next_packet_number + 10
	challenge := []u8{FRAME_PATH_CHALLENGE, 1, 2, 3, 4, 5, 6, 7, 8}
	first, processed := authentic_packet_receive(endpoints, server, &keys, base, challenge, endpoints.now)
	testing.expect(t, processed)
	replay := make([]u8, len(first))
	defer delete(replay)
	copy(replay, first)
	// 40 more numbers with a hole between each two: 41 ranges.
	for index in u64(1) ..= 40 {
		authentic_packet_receive(endpoints, server, &keys, base + 2 * index, []u8{FRAME_PING}, endpoints.now)
	}
	testing.expect(t, server.spaces[.Application].packet_number_floor > base)
	server.pending_controls = {}
	error: errors.Error_Record
	testing.expect(t, !connection_datagram_receive(server, replay, endpoints.now, &error))
	testing.expect(t, .Path_Response not_in server.pending_controls)
}

// The arithmetic of the round-trip time and of the deadlines with values
// that the peer chooses. Before the correction: an ack_delay of 2^64 -
// min_round_trip wrapped min_round_trip + ack_delay to 0, and made the
// adjusted sample larger than the sample itself; a large smoothed time
// wrapped the probe timeout, and a large idle timeout the idle deadline,
// into small values.
@(test)
round_trip_arithmetic_cannot_wrap :: proc(t: ^testing.T) {
	connection := new(Connection)
	defer free(connection)
	connection.has_round_trip_sample = true
	connection.min_round_trip = 10_000
	connection.smoothed_round_trip = 30_000
	connection.round_trip_variation = 0
	round_trip_update(connection, 30_000, max(u64) - 10_000 + 1)
	testing.expect_value(t, connection.smoothed_round_trip, 30_000)
	testing.expect_value(t, connection.round_trip_variation, 0)

	connection.smoothed_round_trip = max(u64) / 4
	connection.probe_timeout_count = 16
	testing.expect_value(t, probe_timeout_duration(connection, .Application), max(u64))

	connection.tls_started = true
	connection.last_activity = 1_000_000
	connection.idle_timeout = max(u64) - 10
	testing.expect_value(t, connection_idle_deadline(connection), max(u64))

	// An idle timeout of 2^62 - 1 milliseconds from the peer.
	parameters := transport_parameters_default()
	parameters.max_idle_timeout = VARIABLE_LENGTH_INTEGER_LARGEST
	testing.expect_value(t, saturating_multiply(parameters.max_idle_timeout, 1000), max(u64))
}

// A configuration that leaves the least seed strength at its zero value is
// refused, by the connection and by TLS; and so is a client with no pinned
// key. Before the correction, both started, and the first one could make
// keys from a weak seed.
@(test)
configurations_that_are_refused :: proc(t: ^testing.T) {
	cryptography := module_cryptography()
	generator: random.Generator
	seed: [random.SEED_SIZE]u8
	random.generator_seed(&generator, &seed, .Weak)
	configuration: Connection_Configuration
	configuration.tls.application_protocol_length = text_into(configuration.tls.application_protocol[:], "kernel-remote")
	configuration.tls.server_public_key[0] = 1
	connection := new(Connection)
	defer free(connection)
	error: errors.Error_Record
	testing.expect(t, !connection_start_server(connection, nil, &configuration, &cryptography, &generator, 0, &error))
	testing.expect_value(t, error.kind, i64(errors.Kind.Bad_Value))
	testing.expect(t, !connection_start_client(connection, nil, &configuration, &cryptography, &generator, 0, &error))
	testing.expect_value(t, error.kind, i64(errors.Kind.Bad_Value))
	handshake := new(Tls_Handshake)
	defer free(handshake)
	tls_configuration := configuration.tls
	tls_configuration.role = .Client
	testing.expect(t, !tls_start(handshake, &tls_configuration, &cryptography, &generator, &error))
	testing.expect_value(t, error.kind, i64(errors.Kind.Bad_Value))
	tls_configuration.least_seed_strength = .Processor
	tls_configuration.server_public_key = {}
	testing.expect(t, !tls_start(handshake, &tls_configuration, &cryptography, &generator, &error))
	testing.expect_value(t, error.kind, i64(errors.Kind.Empty))
	// A failure of TLS for bytes after a change of keys closes with
	// PROTOCOL_VIOLATION, not with an alert.
	connection.tls.protocol_violation = true
	testing.expect_value(t, tls_failure_code(connection), u64(Transport_Error.Protocol_Violation))
}

// expect_record checks the kind, the argument, the value and the limit of an
// error record, and says all four when one differs.
expect_record :: proc(t: ^testing.T, name: string, record: errors.Error_Record, kind: errors.Kind, argument: i64, value: i64, limit: i64) {
	testing.expectf(t, record.kind == i64(kind) && record.argument == argument && record.value == value && record.limit == limit, "%s: kind %d, argument %d, value %d, limit %d; not kind %d, argument %d, value %d, limit %d", name, record.kind, record.argument, record.value, record.limit, i64(kind), argument, value, limit)
}

// Each error record names the argument at fault as its caller gave it, and
// the value that the argument had. Before the correction: a weak least seed
// strength named argument 1 for each caller; a bad length in the facts of a
// token named the remote; an identifier too long of a Retry gave the limit
// as its size; an empty token of a Retry gave Too_Small on the buffer; a
// label or an output of HKDF-Expand-Label named the label with the length of
// the output; each failure of TLS named the bytes of tls_receive.
@(test)
error_records_name_the_argument_at_fault :: proc(t: ^testing.T) {
	cryptography := module_cryptography()
	generator: random.Generator
	// A seed of zeros is refused, and the generator then makes nothing: the
	// starts below that must work need a generator with a seed.
	seed: [random.SEED_SIZE]u8
	for index in 0 ..< random.SEED_SIZE {
		seed[index] = u8(31 + index)
	}
	testing.expect(t, random.generator_seed(&generator, &seed, .Entropy), "the generator of the test has no seed")
	error: errors.Error_Record

	// The least seed strength of a configuration: argument 3 of the two
	// starts, argument 5 of server_init.
	configuration: Connection_Configuration
	configuration.idle_timeout_milliseconds = 30_000
	configuration.tls.application_protocol_length = text_into(configuration.tls.application_protocol[:], "kernel-remote")
	configuration.tls.server_public_key[0] = 1
	connections := make([]Connection, 1)
	defer delete(connections)
	streams := make([]Stream, 1)
	defer delete(streams)
	testing.expect(t, !connection_start_client(&connections[0], streams, &configuration, &cryptography, &generator, 0, &error))
	expect_record(t, "connection_start_client", error, .Bad_Value, 3, 0, i64(random.Seed_Strength.Processor))
	testing.expect(t, !connection_start_server(&connections[0], streams, &configuration, &cryptography, &generator, 0, &error))
	expect_record(t, "connection_start_server", error, .Bad_Value, 3, 0, i64(random.Seed_Strength.Processor))
	server := new(Server)
	defer free(server)
	records: [1]Server_Record
	testing.expect(t, !server_init(server, connections, records[:], streams, &configuration, &cryptography, &generator, SERVER_LIMITS_DEFAULT, &error))
	expect_record(t, "server_init", error, .Bad_Value, 5, 0, i64(random.Seed_Strength.Processor))

	// The facts of a token are argument 5 of retry_token_make.
	key: [RETRY_TOKEN_KEY_SIZE]u8
	token: [RETRY_TOKEN_SIZE]u8
	facts := Retry_Token_Facts{original_destination_connection_id_length = CONNECTION_ID_LIMIT + 1}
	testing.expect(t, !retry_token_make(&cryptography, &key, 1, Remote{0x0A00_0302, 50_000}, &facts, &token, &error))
	expect_record(t, "retry_token_make", error, .Too_Long, 5, CONNECTION_ID_LIMIT + 1, CONNECTION_ID_LIMIT)

	// retry_packet_write: each identifier by its own number, with its size;
	// an empty token is Empty, not a small buffer.
	buffer: [MAX_DATAGRAM_SIZE]u8
	too_long: [CONNECTION_ID_LIMIT + 1]u8
	fitting: [CONNECTION_ID_SIZE]u8
	some_token := [5]u8{1, 2, 3, 4, 5}
	_, ok := retry_packet_write(&cryptography, buffer[:], 0, too_long[:], fitting[:], some_token[:], fitting[:], &error)
	testing.expect(t, !ok)
	expect_record(t, "retry_packet_write, destination", error, .Too_Long, 4, CONNECTION_ID_LIMIT + 1, CONNECTION_ID_LIMIT)
	_, ok = retry_packet_write(&cryptography, buffer[:], 0, fitting[:], too_long[:], some_token[:], fitting[:], &error)
	testing.expect(t, !ok)
	expect_record(t, "retry_packet_write, source", error, .Too_Long, 5, CONNECTION_ID_LIMIT + 1, CONNECTION_ID_LIMIT)
	_, ok = retry_packet_write(&cryptography, buffer[:], 0, fitting[:], fitting[:], some_token[:], too_long[:], &error)
	testing.expect(t, !ok)
	expect_record(t, "retry_packet_write, original destination", error, .Too_Long, 7, CONNECTION_ID_LIMIT + 1, CONNECTION_ID_LIMIT)
	_, ok = retry_packet_write(&cryptography, buffer[:], 0, fitting[:], fitting[:], nil, fitting[:], &error)
	testing.expect(t, !ok)
	expect_record(t, "retry_packet_write, an empty token", error, .Empty, 6, 0, RETRY_TOKEN_LIMIT)
	_, ok = retry_packet_write(&cryptography, buffer[:10], 0, fitting[:], fitting[:], some_token[:], fitting[:], &error)
	testing.expect(t, !ok)
	expect_record(t, "retry_packet_write, a small buffer", error, .Too_Small, 2, 10, 1 + 4 + 1 + CONNECTION_ID_SIZE + 1 + CONNECTION_ID_SIZE + 5 + TAG_SIZE)

	// HKDF-Expand-Label: the label is argument 3, the output argument 4;
	// with a context, the context is argument 4 and the output argument 5.
	secret: [HASH_SIZE]u8
	output: [HASH_SIZE]u8
	long_label_bytes: [LABEL_LIMIT + 1]u8
	for &byte in long_label_bytes {
		byte = 'a'
	}
	long_label := string(long_label_bytes[:])
	long_context: [CONTEXT_LIMIT + 1]u8
	testing.expect(t, !hkdf_expand_label(&cryptography, secret[:], long_label, output[:], &error))
	expect_record(t, "hkdf_expand_label, the label", error, .Too_Long, 3, LABEL_LIMIT + 1, LABEL_LIMIT)
	testing.expect(t, !hkdf_expand_label(&cryptography, secret[:], "quic key", nil, &error))
	expect_record(t, "hkdf_expand_label, no output", error, .Empty, 4, 0, 0xFFFF)
	testing.expect(t, !hkdf_expand_label_with_context(&cryptography, secret[:], long_label, nil, output[:], &error))
	expect_record(t, "hkdf_expand_label_with_context, the label", error, .Too_Long, 3, LABEL_LIMIT + 1, LABEL_LIMIT)
	testing.expect(t, !hkdf_expand_label_with_context(&cryptography, secret[:], "finished", long_context[:], output[:], &error))
	expect_record(t, "hkdf_expand_label_with_context, the context", error, .Too_Long, 4, CONTEXT_LIMIT + 1, CONTEXT_LIMIT)
	testing.expect(t, !hkdf_expand_label_with_context(&cryptography, secret[:], "finished", nil, nil, &error))
	expect_record(t, "hkdf_expand_label_with_context, no output", error, .Empty, 5, 0, 0xFFFF)

	// TLS: the configuration is argument 2 of tls_start; the level is
	// argument 2 of tls_receive, its bytes argument 3; a handshake that
	// failed before names no argument.
	handshake := new(Tls_Handshake)
	defer free(handshake)
	tls_configuration := configuration.tls
	tls_configuration.role = .Client
	testing.expect(t, !tls_start(handshake, &tls_configuration, &cryptography, &generator, &error))
	expect_record(t, "tls_start, the least seed strength", error, .Bad_Value, 2, 0, 0)
	tls_configuration.least_seed_strength = .Processor
	tls_configuration.application_protocol_length = 0
	testing.expect(t, !tls_start(handshake, &tls_configuration, &cryptography, &generator, &error))
	expect_record(t, "tls_start, the protocol name", error, .Bad_Value, 2, 0, 0)
	tls_configuration.application_protocol_length = text_into(tls_configuration.application_protocol[:], "kernel-remote")
	tls_configuration.server_public_key = {}
	testing.expect(t, !tls_start(handshake, &tls_configuration, &cryptography, &generator, &error))
	expect_record(t, "tls_start, no pinned key", error, .Empty, 2, 0, 0)
	tls_configuration.server_public_key[0] = 1
	testing.expect(t, tls_start(handshake, &tls_configuration, &cryptography, &generator, &error))
	level_that_does_not_exist := u8(3)
	testing.expect(t, !tls_receive(handshake, Encryption_Level(level_that_does_not_exist), []u8{1}, &error))
	expect_record(t, "tls_receive, a level that does not exist", error, .Bad_Value, 2, 3, 0)
	testing.expect(t, !tls_receive(handshake, .Initial, []u8{1}, &error))
	expect_record(t, "tls_receive, after a failure", error, .State, 0, 0, 0)
	// A message of a type that the state does not wait for: the bytes.
	testing.expect(t, tls_start(handshake, &tls_configuration, &cryptography, &generator, &error))
	testing.expect(t, !tls_receive(handshake, .Initial, []u8{u8(Handshake_Message.Finished), 0, 0, 0}, &error))
	expect_record(t, "tls_receive, a message out of order", error, .State, 3, i64(Handshake_Message.Finished), 0)
}
