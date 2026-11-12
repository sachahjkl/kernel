package quic

// The receive path of a connection: each datagram of the peer, each packet
// in it, and each frame in each packet, read as hostile input. A packet that
// cannot be read or opened is dropped, with no effect on the connection. A
// frame that breaks a rule of RFC 9000 closes the connection with the error
// code that the RFC names.

import "contract:errors"

// connection_datagram_receive takes one datagram from the peer. It gives
// true when at least one packet of it was processed. A datagram or a packet
// that is dropped gives an error record and changes nothing; a frame that
// breaks a rule moves the connection to the closing state.
connection_datagram_receive :: proc "contextless" (connection: ^Connection, received: []u8, now: u64, error: ^errors.Error_Record) -> bool {
	switch connection.state {
	case .Idle, .Draining, .Closed:
		return fail_at(error, .State, 1, int(connection.state))
	case .Handshake, .Connected, .Closing:
	}
	datagram, taken := datagram_take(received, connection.datagram_copy[:], error)
	if !taken {
		return false
	}
	processed := false
	start := 0
	for start < len(datagram) {
		header: Packet_Header
		if !header_read(datagram, start, CONNECTION_ID_SIZE, &header, error) {
			break
		}
		start = header.end
		if connection.state == .Closing {
			// In the closing state, a packet of the peer gets the
			// CONNECTION_CLOSE again, once for each datagram (RFC 9000,
			// section 10.2.1); it is not opened.
			if connection_id_is_ours(connection, &header) {
				connection.close_datagrams_received += 1
				if connection.close_datagrams_received >= connection.close_next_answer {
					connection.close_to_send = true
					connection.close_next_answer = saturating_multiply(connection.close_next_answer, 2)
				}
				processed = true
			}
			break
		}
		if packet_receive(connection, datagram, &header, now, error) {
			processed = true
			// The keys that this packet made ready open the next packet of
			// the datagram: a server sends its Initial and Handshake packets
			// together.
			connection_tls_progress(connection, now)
		}
		if connection.state != .Handshake && connection.state != .Connected {
			break
		}
	}
	if processed {
		connection.bytes_received += u64(len(datagram))
	}
	return processed
}

// connection_id_is_ours says if a packet is for this connection: its
// Destination Connection ID is the identifier of this side, or, in an
// Initial packet that a server receives, the identifier that the client
// chose first.
@(private)
connection_id_is_ours :: proc "contextless" (connection: ^Connection, header: ^Packet_Header) -> bool {
	destination := header.destination_connection_id[:header.destination_connection_id_length]
	if bytes_equal(destination, connection.local_connection_id[:]) {
		return true
	}
	if connection.configuration.tls.role == .Server && header.type == .Initial {
		return !connection.tls_started || bytes_equal(destination, connection.original_destination_connection_id[:connection.original_destination_connection_id_length])
	}
	return false
}

// packet_receive opens one packet and processes its frames.
@(private)
packet_receive :: proc "contextless" (connection: ^Connection, datagram: []u8, header: ^Packet_Header, now: u64, error: ^errors.Error_Record) -> bool {
	level: Encryption_Level
	#partial switch header.type {
	case .Initial:
		level = .Initial
	case .Handshake:
		level = .Handshake
	case .One_Rtt:
		level = .Application
	case .Retry:
		if !connection_id_is_ours(connection, header) {
			return fail_at(error, .Bad_Value, 1, header.start)
		}
		return client_retry_receive(connection, datagram, header, now, error)
	case:
		// 0-RTT, Version Negotiation and other versions: this layer does
		// none of them, and drops the packet.
		return fail_at(error, .Unsupported, 1, header.start, 0, int(header.type))
	}
	role := connection.configuration.tls.role
	if !connection_id_is_ours(connection, header) {
		return fail_at(error, .Bad_Value, 1, header.start)
	}
	source := header.source_connection_id[:header.source_connection_id_length]
	if header.type == .Initial {
		if role == .Server {
			// A client Initial comes in a datagram of 1200 bytes at least
			// (RFC 9000, section 14.1).
			if len(datagram) < SMALLEST_MAX_UDP_PAYLOAD_SIZE {
				return fail_at(error, .Too_Small, 1, len(datagram), SMALLEST_MAX_UDP_PAYLOAD_SIZE)
			}
		} else if header.token_length > 0 {
			// A server Initial carries no token (RFC 9000, section 17.2.2).
			return fail_at(error, .Bad_Value, 1, header.token_offset)
		}
	}
	if header.type != .One_Rtt && connection.peer_connection_id_known && !bytes_equal(source, connection.peer_connection_id[:connection.peer_connection_id_length]) {
		// The peer keeps the identifier that it chose (RFC 9000, section 7.2).
		return fail_at(error, .Bad_Value, 1, header.start)
	}
	space := &connection.spaces[level]
	// The first Initial of a client: its keys come from its Destination
	// Connection ID, into local records. The record of the connection takes
	// them, and that identifier, only when the packet is authentic.
	first_initial := role == .Server && header.type == .Initial && !connection.tls_started
	first_client_keys, first_server_keys: Packet_Keys
	defer secret_erase(&first_client_keys, size_of(first_client_keys))
	defer secret_erase(&first_server_keys, size_of(first_server_keys))
	receive_keys := &space.receive_keys
	if first_initial {
		if header.destination_connection_id_length < CONNECTION_ID_SIZE {
			// RFC 9000, section 7.2: 8 bytes at least in the first Initial.
			return fail_at(error, .Too_Small, 1, header.destination_connection_id_length, CONNECTION_ID_SIZE)
		}
		if !initial_keys(connection.cryptography, header.destination_connection_id[:header.destination_connection_id_length], &first_client_keys, &first_server_keys, error) {
			return false
		}
		receive_keys = &first_client_keys
	} else if !space.keys_installed || space.discarded {
		return fail_at(error, .State, 1, header.start, 0, int(level))
	}
	if level == .Application && role == .Server && connection.state != .Connected {
		// A server opens no 1-RTT packet before the handshake completes (RFC
		// 9001, section 5.7); the client sends it again.
		return fail_at(error, .State, 1, header.start, 0, int(level))
	}
	unprotected: Unprotected_Header
	if !header_protection_remove(connection.cryptography, receive_keys, datagram, header, space.largest_received, &unprotected, error) {
		return false
	}
	if unprotected.key_phase {
		// This layer does no key update: a packet of the next phase does
		// not open with the keys of this phase.
		return fail_at(error, .Unsupported, 1, header.start, 0, 1)
	}
	number := unprotected.packet_number
	// A number below the floor belongs to a range that the set forgot: it
	// may have been processed already, so it is refused (RFC 9000, section
	// 12.3).
	if number < space.packet_number_floor || range_set_contains(&space.received, number) {
		return fail_at(error, .Bad_Value, 1, header.start)
	}
	opened: Opened_Packet
	if !packet_payload_open(connection.cryptography, receive_keys, datagram, header, &unprotected, &opened, error) {
		if error.kind == i64(errors.Kind.Bad_Value) && !first_initial {
			// Reserved bits that are not 0 in an authentic packet (RFC
			// 9000, section 17.2).
			connection_fail(connection, u64(Transport_Error.Protocol_Violation), 0, now)
		}
		return false
	}
	if first_initial && !server_first_initial(connection, header, &first_client_keys, &first_server_keys, now, error) {
		return false
	}
	if role == .Client && header.type == .Initial && !connection.peer_connection_id_known {
		// The client sends to the identifier that the server chose (RFC
		// 9000, section 7.2).
		connection.peer_connection_id_length = copy(connection.peer_connection_id[:], source)
		connection.peer_connection_id_known = true
	}
	payload := datagram[opened.payload_offset:][:opened.payload_length]
	connection.packet_data_dropped = false
	ack_eliciting, frames_ok := frames_process(connection, level, payload, now)
	if !frames_ok {
		return true
	}
	if connection.packet_data_dropped {
		// Data of this packet had no place: the packet is not recorded and
		// not acknowledged, so the peer declares it lost and sends its data
		// again. Its other frames were taken; each one has the same effect
		// when it comes again. It does not move the last activity: a packet
		// that is not recorded is not seen as a duplicate when it comes
		// again, so a replay of it by whoever saw it on the path would keep
		// a silent connection alive. The packet of the peer that sends the
		// data again is recorded, and moves it.
		return true
	}
	// The last activity moves only for a packet that is recorded: a replay
	// of it is then refused as a duplicate before its open.
	connection.last_activity = now
	connection.ack_eliciting_sent_since_receive = false
	if !range_set_insert(&space.received, number, number + 1) {
		space.packet_number_floor = max(space.packet_number_floor, space.received.ends[0])
		range_set_drop_lowest(&space.received)
		range_set_insert(&space.received, number, number + 1)
	}
	if !space.has_received || number > space.largest_received {
		space.has_received = true
		space.largest_received = number
		space.largest_received_time = now
	}
	if ack_eliciting {
		if !space.ack_needed {
			space.ack_deadline = saturating_add(now, MAX_ACK_DELAY_OF_THIS_SIDE)
		}
		space.ack_needed = true
		space.ack_eliciting_unacknowledged += 1
	}
	if role == .Server && level == .Handshake && !space.discarded {
		// A Handshake packet proves that the client has the address (RFC
		// 9000, section 8.1), and ends the Initial space (RFC 9001, section
		// 4.9.1).
		connection.address_validated = true
		connection_space_discard(connection, .Initial)
	}
	return true
}

// client_retry_receive takes a Retry packet of the server (RFC 9000,
// section 17.2.5.2): one at most, before any Initial of the server, with a
// Source Connection ID that is not the identifier that the client chose,
// and a Retry Integrity Tag over that identifier. The client then sends to
// the identifier of the Retry, derives its Initial keys from it, and sends
// its ClientHello again in Initial packets that carry the token. The packet
// numbers go on: they never repeat in a space.
@(private)
client_retry_receive :: proc "contextless" (connection: ^Connection, datagram: []u8, header: ^Packet_Header, now: u64, error: ^errors.Error_Record) -> bool {
	if connection.configuration.tls.role != .Client || connection.state != .Handshake || connection.retried || connection.peer_connection_id_known {
		return fail_at(error, .State, 1, header.start, 0, int(header.type))
	}
	original := connection.original_destination_connection_id[:connection.original_destination_connection_id_length]
	source := header.source_connection_id[:header.source_connection_id_length]
	if bytes_equal(source, original) || header.token_length > RETRY_TOKEN_LIMIT {
		return fail_at(error, .Bad_Value, 1, header.start)
	}
	if !retry_integrity_check(connection.cryptography, original, datagram, header, error) {
		return false
	}
	connection.retried = true
	connection.retry_first_destination_connection_id_length = copy(connection.retry_first_destination_connection_id[:], original)
	connection.retry_source_connection_id_length = copy(connection.retry_source_connection_id[:], source)
	connection.retry_token_length = copy(connection.retry_token[:], datagram[header.token_offset:][:header.token_length])
	connection.peer_connection_id_length = copy(connection.peer_connection_id[:], source)
	connection.original_destination_connection_id_length = copy(connection.original_destination_connection_id[:], source)
	if !connection_initial_keys_install(connection, error) {
		connection_fail(connection, u64(Transport_Error.Internal_Error), 0, now)
		return false
	}
	// The Initial packets before the Retry are not acknowledged, and none
	// will be: they leave the flight, and the ClientHello goes again from
	// its first byte.
	space := &connection.spaces[.Initial]
	for &packet in space.sent {
		if packet.in_use {
			sent_packet_remove(connection, space, &packet)
		}
	}
	space.loss_time = 0
	space.crypto.send_next = 0
	space.crypto.send_again = {}
	space.crypto.send_acknowledged = {}
	connection.probe_timeout_count = 0
	connection.last_activity = now
	return true
}

// server_first_initial gives the record of a server to a client, at the
// first Initial packet of the client that opened: the Destination
// Connection ID of the client gave the Initial keys, and its Source
// Connection ID is where the server sends. The handshake must complete
// before the handshake deadline, or the record ends.
@(private)
server_first_initial :: proc "contextless" (connection: ^Connection, header: ^Packet_Header, client_keys, server_keys: ^Packet_Keys, now: u64, error: ^errors.Error_Record) -> bool {
	connection.original_destination_connection_id_length = copy(connection.original_destination_connection_id[:], header.destination_connection_id[:header.destination_connection_id_length])
	connection.peer_connection_id_length = copy(connection.peer_connection_id[:], header.source_connection_id[:header.source_connection_id_length])
	connection.peer_connection_id_known = true
	space := &connection.spaces[.Initial]
	space.send_keys, space.receive_keys = server_keys^, client_keys^
	space.keys_installed = true
	connection.handshake_deadline = saturating_add(now, HANDSHAKE_TIME_LIMIT)
	connection.last_activity = now
	if !connection_tls_start(connection, error) {
		connection_tls_progress(connection, now)
		return false
	}
	return true
}

// A reader of the frames of one packet: each read checks its length first,
// and a read past the end sets failed and gives zeros.
@(private)
Frame_Reader :: struct {
	bytes:    []u8,
	position: int,
	failed:   bool,
}

@(private)
frame_read_integer :: proc "contextless" (reader: ^Frame_Reader) -> u64 {
	if reader.failed {
		return 0
	}
	value, size, ok := variable_length_integer_read(reader.bytes, reader.position)
	if !ok {
		reader.failed = true
		return 0
	}
	reader.position += size
	return value
}

@(private)
frame_read_bytes :: proc "contextless" (reader: ^Frame_Reader, length: u64) -> []u8 {
	if reader.failed || length > u64(len(reader.bytes) - reader.position) {
		reader.failed = true
		return nil
	}
	bytes := reader.bytes[reader.position:][:int(length)]
	reader.position += int(length)
	return bytes
}

// frames_process reads each frame of a packet and acts on it. It gives
// whether the packet is ack-eliciting, and false in ok when a frame closed
// the connection.
frames_process :: proc "contextless" (connection: ^Connection, level: Encryption_Level, payload: []u8, now: u64) -> (ack_eliciting: bool, ok: bool) {
	if len(payload) == 0 {
		// RFC 9000, section 12.4: a packet with no frame.
		return false, connection_fail(connection, u64(Transport_Error.Protocol_Violation), 0, now)
	}
	reader := Frame_Reader{bytes = payload}
	for reader.position < len(payload) {
		type_start := reader.position
		type := frame_read_integer(&reader)
		if reader.failed {
			return false, connection_fail(connection, u64(Transport_Error.Frame_Encoding_Error), 0, now)
		}
		if reader.position - type_start != variable_length_integer_size(type) {
			// The type of a frame has its shortest encoding (RFC 9000,
			// section 12.4).
			return false, connection_fail(connection, u64(Transport_Error.Protocol_Violation), type, now)
		}
		if !frame_type_is_allowed(type, level) {
			return false, connection_fail(connection, u64(Transport_Error.Protocol_Violation), type, now)
		}
		switch type {
		case FRAME_PADDING, FRAME_ACK, FRAME_ACK_WITH_ECN, FRAME_CONNECTION_CLOSE, FRAME_CONNECTION_CLOSE_APPLICATION:
		case:
			ack_eliciting = true
		}
		if !frame_process(connection, level, type, &reader, now) {
			return ack_eliciting, false
		}
		if connection.state == .Draining {
			// A CONNECTION_CLOSE: the frames after it do not matter.
			return ack_eliciting, false
		}
	}
	return ack_eliciting, true
}

// frame_process reads the fields of one frame after its type, and acts on
// it.
@(private)
frame_process :: proc "contextless" (connection: ^Connection, level: Encryption_Level, type: u64, reader: ^Frame_Reader, now: u64) -> bool {
	encoding_error :: proc "contextless" (connection: ^Connection, type: u64, now: u64) -> bool {
		return connection_fail(connection, u64(Transport_Error.Frame_Encoding_Error), type, now)
	}
	role := connection.configuration.tls.role
	switch type {
	case FRAME_PADDING:
		for reader.position < len(reader.bytes) && reader.bytes[reader.position] == 0 {
			reader.position += 1
		}
	case FRAME_PING:
	case FRAME_ACK, FRAME_ACK_WITH_ECN:
		return ack_frame_process(connection, level, type, reader, now)
	case FRAME_RESET_STREAM:
		stream_id := frame_read_integer(reader)
		code := frame_read_integer(reader)
		final_size := frame_read_integer(reader)
		if reader.failed {
			return encoding_error(connection, type, now)
		}
		stream, ok := stream_of_frame(connection, stream_id, type, now)
		if !ok {
			return false
		}
		if stream != nil {
			return stream_reset_receive(connection, stream, code, final_size, now)
		}
	case FRAME_STOP_SENDING:
		stream_id := frame_read_integer(reader)
		code := frame_read_integer(reader)
		if reader.failed {
			return encoding_error(connection, type, now)
		}
		stream, ok := stream_of_frame(connection, stream_id, type, now)
		if !ok {
			return false
		}
		if stream != nil {
			stream_stop_sending_receive(stream, code)
		}
	case FRAME_CRYPTO:
		offset := frame_read_integer(reader)
		length := frame_read_integer(reader)
		data := frame_read_bytes(reader, length)
		if reader.failed || offset > VARIABLE_LENGTH_INTEGER_LARGEST - length {
			return encoding_error(connection, type, now)
		}
		return crypto_frame_receive(connection, level, offset, data, now)
	case FRAME_NEW_TOKEN:
		length := frame_read_integer(reader)
		frame_read_bytes(reader, length)
		if reader.failed || length == 0 {
			return encoding_error(connection, type, now)
		}
		if role == .Server {
			return connection_fail(connection, u64(Transport_Error.Protocol_Violation), type, now)
		}
	// A client keeps no token: it never connects again with one.
	case FRAME_STREAM ..= FRAME_STREAM + 0x07:
		stream_id := frame_read_integer(reader)
		offset: u64
		if type & FRAME_STREAM_FLAG_OFFSET != 0 {
			offset = frame_read_integer(reader)
		}
		length := u64(len(reader.bytes) - reader.position)
		if type & FRAME_STREAM_FLAG_LENGTH != 0 {
			length = frame_read_integer(reader)
		}
		data := frame_read_bytes(reader, length)
		if reader.failed {
			return encoding_error(connection, type, now)
		}
		if offset > VARIABLE_LENGTH_INTEGER_LARGEST - u64(len(data)) {
			// RFC 9000, section 19.8: the end of the data past 2^62 - 1.
			return encoding_error(connection, type, now)
		}
		stream, ok := stream_of_frame(connection, stream_id, type, now)
		if !ok {
			return false
		}
		if stream == nil {
			// A stream that ended: its data came before.
			return true
		}
		return stream_data_receive(connection, stream, offset, data, type & FRAME_STREAM_FLAG_FINISH != 0, now)
	case FRAME_MAX_DATA:
		maximum := frame_read_integer(reader)
		if reader.failed {
			return encoding_error(connection, type, now)
		}
		connection.peer_max_data = max(connection.peer_max_data, maximum)
	case FRAME_MAX_STREAM_DATA:
		stream_id := frame_read_integer(reader)
		maximum := frame_read_integer(reader)
		if reader.failed {
			return encoding_error(connection, type, now)
		}
		stream, ok := stream_of_frame(connection, stream_id, type, now)
		if !ok {
			return false
		}
		if stream != nil {
			stream.send_limit = max(stream.send_limit, maximum)
		}
	case FRAME_MAX_STREAMS_BIDIRECTIONAL, FRAME_MAX_STREAMS_UNIDIRECTIONAL:
		maximum := frame_read_integer(reader)
		if reader.failed || maximum > STREAMS_LIMIT {
			return encoding_error(connection, type, now)
		}
		if type == FRAME_MAX_STREAMS_BIDIRECTIONAL {
			connection.peer_max_streams_bidirectional = max(connection.peer_max_streams_bidirectional, maximum)
		}
	case FRAME_DATA_BLOCKED:
		frame_read_integer(reader)
		if reader.failed {
			return encoding_error(connection, type, now)
		}
	case FRAME_STREAM_DATA_BLOCKED:
		stream_id := frame_read_integer(reader)
		frame_read_integer(reader)
		if reader.failed {
			return encoding_error(connection, type, now)
		}
		_, ok := stream_of_frame(connection, stream_id, type, now)
		return ok
	case FRAME_STREAMS_BLOCKED_BIDIRECTIONAL, FRAME_STREAMS_BLOCKED_UNIDIRECTIONAL:
		maximum := frame_read_integer(reader)
		if reader.failed || maximum > STREAMS_LIMIT {
			return encoding_error(connection, type, now)
		}
	case FRAME_NEW_CONNECTION_ID:
		// Read for its form, and not used: this layer keeps the one
		// identifier of the peer from the handshake (no migration).
		sequence := frame_read_integer(reader)
		retire_prior_to := frame_read_integer(reader)
		length_bytes := frame_read_bytes(reader, 1)
		if reader.failed {
			return encoding_error(connection, type, now)
		}
		length := u64(length_bytes[0])
		frame_read_bytes(reader, length)
		frame_read_bytes(reader, STATELESS_RESET_TOKEN_SIZE)
		if reader.failed || length < 1 || length > CONNECTION_ID_LIMIT || retire_prior_to > sequence {
			return encoding_error(connection, type, now)
		}
		if retire_prior_to > 0 {
			// The peer asks this side to stop using the identifier of the
			// handshake: this layer has no other, and closes.
			return connection_fail(connection, u64(Transport_Error.Protocol_Violation), type, now)
		}
	case FRAME_RETIRE_CONNECTION_ID:
		sequence := frame_read_integer(reader)
		if reader.failed {
			return encoding_error(connection, type, now)
		}
		// This side gave no identifier past the one of the handshake
		// (sequence 0): a larger number is a violation (RFC 9000, section
		// 19.16).
		if sequence > 0 {
			return connection_fail(connection, u64(Transport_Error.Protocol_Violation), type, now)
		}
	case FRAME_PATH_CHALLENGE:
		data := frame_read_bytes(reader, PATH_DATA_SIZE)
		if reader.failed {
			return encoding_error(connection, type, now)
		}
		copy(connection.path_response[:], data)
		connection.pending_controls += {.Path_Response}
	case FRAME_PATH_RESPONSE:
		// This side sends no PATH_CHALLENGE: the response is read and
		// dropped.
		frame_read_bytes(reader, PATH_DATA_SIZE)
		if reader.failed {
			return encoding_error(connection, type, now)
		}
	case FRAME_CONNECTION_CLOSE, FRAME_CONNECTION_CLOSE_APPLICATION:
		code := frame_read_integer(reader)
		frame_type: u64
		if type == FRAME_CONNECTION_CLOSE {
			frame_type = frame_read_integer(reader)
		}
		reason_length := frame_read_integer(reader)
		reason := frame_read_bytes(reader, reason_length)
		if reader.failed {
			return encoding_error(connection, type, now)
		}
		connection_enter_draining(connection, code, frame_type, type == FRAME_CONNECTION_CLOSE_APPLICATION, now)
		connection.close_reason_of_peer_length = copy(connection.close_reason_of_peer[:], reason)
	case FRAME_HANDSHAKE_DONE:
		if role == .Server {
			return connection_fail(connection, u64(Transport_Error.Protocol_Violation), type, now)
		}
		if !connection.handshake_confirmed {
			connection.handshake_confirmed = true
			connection_space_discard(connection, .Handshake)
		}
	case:
		return encoding_error(connection, type, now)
	}
	return true
}

// ack_frame_process reads an ACK frame (RFC 9000, section 19.3): each range
// is checked so that no number goes below 0, and a number that this side
// never sent is a PROTOCOL_VIOLATION (RFC 9000, section 13.1).
@(private)
ack_frame_process :: proc "contextless" (connection: ^Connection, level: Encryption_Level, type: u64, reader: ^Frame_Reader, now: u64) -> bool {
	largest := frame_read_integer(reader)
	ack_delay := frame_read_integer(reader)
	range_count := frame_read_integer(reader)
	first_range := frame_read_integer(reader)
	if reader.failed || first_range > largest {
		return connection_fail(connection, u64(Transport_Error.Frame_Encoding_Error), type, now)
	}
	ranges: [ACK_RANGES_READ_LIMIT]Acknowledged_Range
	ranges[0] = {largest - first_range, largest}
	count := 1
	smallest := largest - first_range
	// Each range reads 2 bytes at least, so a count larger than the packet
	// ends with a failed read.
	for index: u64 = 0; index < range_count; index += 1 {
		gap := frame_read_integer(reader)
		length := frame_read_integer(reader)
		if reader.failed || gap + 2 > smallest {
			return connection_fail(connection, u64(Transport_Error.Frame_Encoding_Error), type, now)
		}
		range_largest := smallest - gap - 2
		if length > range_largest {
			return connection_fail(connection, u64(Transport_Error.Frame_Encoding_Error), type, now)
		}
		smallest = range_largest - length
		if count < ACK_RANGES_READ_LIMIT {
			ranges[count] = {smallest, range_largest}
			count += 1
		}
	}
	if type == FRAME_ACK_WITH_ECN {
		for _ in 0 ..< 3 {
			frame_read_integer(reader)
		}
		if reader.failed {
			return connection_fail(connection, u64(Transport_Error.Frame_Encoding_Error), type, now)
		}
	}
	if largest >= connection.spaces[level].next_packet_number {
		return connection_fail(connection, u64(Transport_Error.Protocol_Violation), type, now)
	}
	acknowledgement_receive(connection, level, ranges[:count], largest, ack_delay, now)
	return true
}

// crypto_frame_receive takes the handshake bytes of a CRYPTO frame, and
// gives TLS the bytes that came in order (RFC 9000, section 19.6).
@(private)
crypto_frame_receive :: proc "contextless" (connection: ^Connection, level: Encryption_Level, offset: u64, data: []u8, now: u64) -> bool {
	end := offset + u64(len(data))
	if end > CRYPTO_BUFFER_SIZE {
		return connection_fail(connection, u64(Transport_Error.Crypto_Buffer_Exceeded), FRAME_CRYPTO, now)
	}
	crypto := &connection.spaces[level].crypto
	from := max(offset, crypto.delivered)
	if from < end {
		if !range_set_insert(&crypto.received, from, end) {
			// No place to note the data: it is dropped, and its packet is
			// not acknowledged (packet_receive).
			connection.packet_data_dropped = true
			return true
		}
		copy(crypto.receive[int(from):int(end)], data[int(from - offset):])
	}
	ready := range_set_prefix(&crypto.received)
	if ready <= crypto.delivered {
		return true
	}
	bytes := crypto.receive[int(crypto.delivered):int(ready)]
	crypto.delivered = ready
	error: errors.Error_Record
	if !tls_receive(&connection.tls, level, bytes, &error) {
		return connection_fail(connection, tls_failure_code(connection), FRAME_CRYPTO, now)
	}
	return true
}
