package quic

// The receive path of a connection: each datagram of the peer, each packet in
// it, and each frame in each packet, read as hostile input.
//
// The path has three levels, and each one has its own answer to bad input:
//
// - **A datagram** (`connection_datagram_receive`) is copied once into the
//   record, and holds one packet or several (RFC 9000, section 12.2).
// - **A packet** (`packet_receive`) that cannot be read or opened is dropped,
//   with an error record and no effect on the connection: anyone on the network
//   can send such bytes, so they must not close a connection.
// - **A frame** (`frames_process`) is in a packet that opened, so only the
//   peer wrote it. A frame that breaks a rule of RFC 9000 closes the connection
//   with the error code that the RFC names (`connection_fail`).
//
// Each field is read with its length checked first (`Frame_Reader`): no read
// goes past the end of a packet.

import "contract:errors"

// connection_datagram_receive takes one datagram from the peer, and processes
// each packet in it.
//
// The datagram is copied into the record first, and the copy is what the
// library reads and opens in place: the bytes of the caller do not change. A
// server sends its Initial and Handshake packets in one datagram, so after
// each packet the keys that it made ready are installed before the next packet
// is read. After this call the caller calls `connection_datagram_send`: an
// acknowledgement, the next bytes of the handshake or a CONNECTION_CLOSE can
// wait.
//
// **Parameters**
//
// - `connection`: the record, in the state `Handshake`, `Connected` or
//   `Closing`.
// - `received`: the bytes of one UDP datagram, `DATAGRAM_LIMIT` at most.
// - `now`: the time, in microseconds.
// - `error`: the error record that a dropped datagram or packet writes. It can
//   be written when the result is true too: one packet of the datagram was
//   processed and another was dropped.
//
// **Result**: true when at least one packet of the datagram was processed. Its
// bytes then count for the anti-amplification limit of a server. A frame that
// broke a rule gives true too: the packet was authentic, and the connection is
// now in the closing state. In the closing state, true says that the datagram
// names this connection: it is not opened, and the 1st, 2nd, 4th, 8th... of
// them asks for the CONNECTION_CLOSE again.
//
// **Errors**, each for a datagram or a packet that was dropped with no effect:
//
// - `State`: the record is idle, draining or closed; the keys of the level of
//   the packet are not installed yet or were discarded (the peer sends the
//   packet again); a 1-RTT packet came to a server before its handshake
//   completed; a Retry came to a server, or to a client that cannot take one.
// - `Too_Long`: the datagram has more than `DATAGRAM_LIMIT` bytes.
// - `Bad_Value`: the packet names another connection; its Source Connection ID
//   is not the one that the peer chose; an Initial packet of a server carries a
//   token; its packet number came before, or is below the packet number floor.
// - `Too_Small`: a server got an Initial packet of a client in a datagram
//   under 1200 bytes, or a first Initial packet with a Destination Connection ID
//   under 8 bytes.
// - `Unsupported`: a 0-RTT packet, a Version Negotiation packet, a packet of
//   another version, or a 1-RTT packet of the next key phase.
// - The error of `header_read`, `header_protection_remove` or
//   `packet_payload_open`: the header does not read, or the packet does not
//   authenticate.
//
// ```odin
// if quic.connection_datagram_receive(&connection, datagram, now, &error) {
// 	// ... a packet was processed: send what waits ...
// }
// ```
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

// connection_id_is_ours says if a packet is for this connection, by its
// Destination Connection ID.
//
// The identifier is the one that this side chose. A server also takes an
// Initial packet with the identifier that the client chose first, because a
// client keeps it until it learns the identifier of the server; and before its
// handshake started, a server record takes an Initial packet with any
// identifier: that packet is the one that gives the record to a client.
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

// packet_receive opens one packet of a datagram and processes its frames.
//
// It gives true when the packet was authentic and its frames were read, also
// when a frame closed the connection. It gives false, with an error record,
// for a packet that is dropped: the connection does not change. The order of
// the checks matters: each check that needs no cryptography comes before the
// open, and nothing of the record changes before the packet proved authentic.
//
// 1. The type of the packet gives its encryption level. A Retry goes to
//   `client_retry_receive`; 0-RTT, Version Negotiation and another version are
//   dropped.
// 2. The packet must name this connection, and a long header must carry the
//   Source Connection ID that the peer chose (RFC 9000, section 7.2).
// 3. An Initial packet of a client must come in a datagram of 1200 bytes at
//   least (RFC 9000, section 14.1); an Initial packet of a server must carry no
//   token (RFC 9000, section 17.2.2).
// 4. The first Initial packet at a server derives its keys into local records:
//   the record of the connection takes them only in the sixth point.
// 5. The header protection is removed, and the packet number is read. A number
//   that came before, or below the packet number floor, is dropped before the
//   open (RFC 9000, section 12.3).
// 6. The packet is opened. An authentic packet with reserved bits that are not
//   0 closes the connection with PROTOCOL_VIOLATION (RFC 9000, section 17.2).
//   The first Initial packet then gives the record to its client
//   (`server_first_initial`).
// 7. The frames are processed (`frames_process`).
// 8. The packet is recorded: its number goes in the set of the space, it moves
//   the last activity of the idle timeout, and an ack-eliciting packet asks for
//   an ACK frame, at the latest `MAX_ACK_DELAY_OF_THIS_SIDE` later.
// 9. At a server, a Handshake packet validates the address of the client (RFC
//   9000, section 8.1) and discards the Initial space (RFC 9001, section 4.9.1).
//
// A packet whose data had no place in a range set stops after the seventh
// point: it is not recorded and not acknowledged, so the peer sends its data
// again. A packet whose frame closed the connection stops there too.
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

// client_retry_receive takes a Retry packet of the server (RFC 9000, section
// 17.2.5.2; RFC 9001, section 5.8).
//
// A server sends a Retry to make a client prove its address before the server
// keeps anything for it. The client accepts one at most, before any Initial
// packet of the server, with a Source Connection ID that is not the identifier
// that the client chose, and a Retry Integrity Tag that verifies over that
// identifier. The client then:
//
// - sends to the identifier of the Retry, and derives new Initial keys from
//   it;
// - keeps the token: each later Initial packet carries it;
// - forgets the Initial packets that it sent (none will be acknowledged), and
//   sends its ClientHello again from its first byte;
// - goes on with its packet numbers: they never repeat in a space.
//
// It gives false, with no effect, for a Retry that it does not take:
//
// - `State`: this side is a server, the handshake is over, a Retry was taken
//   before, or an Initial packet of the server came already;
// - `Bad_Value`: the Source Connection ID is the identifier that the client
//   chose, or the token has more than `RETRY_TOKEN_LIMIT` bytes;
// - the error of `retry_integrity_check`: the tag does not verify, so the
//   packet is not of the server that got the Initial packet.
//
// A Retry with an empty token is refused before, by `header_read`. If the new
// Initial keys cannot be derived, the connection closes with INTERNAL_ERROR.
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

// server_first_initial gives the record of a server to a client, at the first
// Initial packet of the client that opened.
//
// Before this packet the record held nothing of a client. Now it takes the
// Destination Connection ID of the packet (which gave the Initial keys), the
// keys that opened it, and the Source Connection ID of the client, where the
// server sends. It starts the handshake of TLS, the handshake deadline
// (`HANDSHAKE_TIME_LIMIT` from `now`) and the idle timeout.
//
// Only a packet that opened reaches it, so a datagram that does not
// authenticate never takes a record. An authentic Initial packet proves little
// all the same, because its keys come from a public value: the handshake
// deadline frees the record of a client that goes no further. It gives false
// when TLS does not start: the packet is dropped, and a failure of TLS closes
// the connection.
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

// A reader of the frames of one packet: each read checks its length first, and
// a read past the end sets `failed` and gives zeros.
//
// A frame has several fields, so a procedure reads them all and tests `failed`
// once, after the last one: once a read failed, each later read fails too and
// moves nothing. A frame that is cut is then a FRAME_ENCODING_ERROR, and no
// index goes past the end of the packet.
@(private)
Frame_Reader :: struct {
	bytes:    []u8, // The payload of the packet, after its open: the frames, one after the other.
	position: int, // The index of the next byte to read.
	failed:   bool, // A read went past the end, or a variable-length integer was cut: each later read gives zero or nil.
}

// frame_read_integer reads one variable-length integer of a frame (RFC 9000,
// section 16): 1, 2, 4 or 8 bytes, a value of 62 bits at most.
//
// It gives the value and moves the reader past it. It gives 0 and sets
// `failed` when the integer is cut, or when an earlier read failed.
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

// frame_read_bytes reads `length` bytes of a frame, and gives them as a slice
// of the payload: no copy.
//
// `length` comes from the peer. It is compared with the bytes that remain
// before anything else, so a length past the end of the packet gives nil and
// sets `failed`.
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

// frames_process reads each frame of the payload of one packet that opened,
// and acts on it (RFC 9000, section 12.4).
//
// **Parameters**
//
// - `connection`: the record.
// - `level`: the encryption level of the packet. The Initial and Handshake
//   levels allow only PADDING, PING, ACK, CRYPTO and a transport
//   CONNECTION_CLOSE (`frame_type_is_allowed`).
// - `payload`: the bytes of the packet after its open.
// - `now`: the time, in microseconds.
//
// **Results**
//
// - `ack_eliciting`: the packet carried a frame other than PADDING, ACK and
//   CONNECTION_CLOSE, so the peer waits for an acknowledgement (RFC 9002,
//   section 2).
// - `ok`: false when a frame closed the connection, or when a CONNECTION_CLOSE
//   of the peer came: the frames after it are not read.
//
// **What closes the connection**, before any frame is acted on:
//
// - a packet with no frame: PROTOCOL_VIOLATION;
// - a frame type that is cut: FRAME_ENCODING_ERROR;
// - a frame type that is not in its shortest form, or a frame that its level
//   does not allow: PROTOCOL_VIOLATION.
//
// Each frame is then given to `frame_process`.
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

// frame_process reads the fields of one frame after its type, and acts on it.
// It gives false when the frame closed the connection.
//
// A frame that is cut, a length past the end of the packet, an end of data
// past 2^62 - 1, a count of streams over 2^60 or a type that does not exist
// closes the connection with FRAME_ENCODING_ERROR. What each frame does (RFC
// 9000, section 19):
//
// - **PADDING**: each byte of zeros that follows is skipped. **PING**:
//   nothing; it only makes the packet ack-eliciting.
// - **ACK**, with or without ECN counts: `ack_frame_process`.
// - **CRYPTO**: `crypto_frame_receive`.
// - **STREAM**: the data goes to its stream (`stream_data_receive`). A frame
//   with no Length field takes the rest of the packet. A frame for a stream that
//   ended is dropped.
// - **RESET_STREAM**: `stream_reset_receive`. **STOP_SENDING**: this side
//   answers with RESET_STREAM and the same code.
// - **MAX_DATA**, **MAX_STREAM_DATA**, **MAX_STREAMS**: a limit that the peer
//   gives this side. It only grows: a smaller value changes nothing. MAX_STREAMS
//   for unidirectional streams is read and not used.
// - **DATA_BLOCKED**, **STREAM_DATA_BLOCKED**, **STREAMS_BLOCKED**: read and
//   not used. STREAM_DATA_BLOCKED checks its stream as a STREAM frame does.
// - **NEW_TOKEN**: a client reads it and keeps no token, because it never
//   connects again with one. An empty token is FRAME_ENCODING_ERROR. To a server
//   it is PROTOCOL_VIOLATION.
// - **NEW_CONNECTION_ID**: read for its form and not used: this layer keeps
//   the one identifier of the peer from the handshake. A Retire Prior To above 0
//   asks this side to stop using that identifier: it has no other, and closes
//   with PROTOCOL_VIOLATION.
// - **RETIRE_CONNECTION_ID**: this side gave only the identifier of the
//   handshake, with the sequence number 0. A larger number is PROTOCOL_VIOLATION
//   (RFC 9000, section 19.16).
// - **PATH_CHALLENGE**: its 8 bytes are kept, and a PATH_RESPONSE with them is
//   queued. **PATH_RESPONSE**: read and dropped, because this side sends no
//   challenge.
// - **CONNECTION_CLOSE**, of the transport or of the application: the
//   connection goes to the draining state, with the code and the first bytes of
//   the reason phrase kept for the program.
// - **HANDSHAKE_DONE**: a client confirms the handshake and discards the
//   Handshake space. To a server it is PROTOCOL_VIOLATION.
//
// Each frame that names a stream goes through `stream_of_frame`, which checks
// the stream identifier against the limit of streams and opens a new stream of
// the peer.
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

// ack_frame_process reads an ACK frame (RFC 9000, section 19.3) and gives its
// ranges to loss detection (`acknowledgement_receive`).
//
// The frame gives the largest acknowledged number, the delay of the peer, then
// ranges that go down: each one is a gap and a length, counted from the range
// before it. Each subtraction is checked first, so no number goes below 0: a
// range that would is FRAME_ENCODING_ERROR. A count of ranges larger than the
// packet ends with a failed read, since each range takes 2 bytes at least.
//
// - At most `ACK_RANGES_READ_LIMIT` ranges are acted on, from the largest
//   number down. The others are read for their form and skipped: their packets
//   are acknowledged by a later frame, or declared lost and sent again.
// - The three ECN counts of an ACK frame of type 0x03 are read and not used.
// - A largest acknowledged number that this side never sent is
//   PROTOCOL_VIOLATION (RFC 9000, section 13.1): the peer acknowledges a packet
//   that does not exist.
//
// It gives false when the frame closed the connection.
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

// crypto_frame_receive takes the handshake bytes of a CRYPTO frame, and gives
// TLS the bytes that came in order (RFC 9000, section 19.6).
//
// CRYPTO frames can come in any order and can repeat. The bytes go to their
// offset in `Crypto_Stream.receive`, the set `received` notes the range, and
// TLS gets the new bytes of the range from 0, each byte once (`tls_receive`).
//
// - `offset`, `data`: the Offset field and the bytes of the frame. The reader
//   checked that their sum does not pass 2^62 - 1.
// - **CRYPTO_BUFFER_EXCEEDED**: the frame ends past `CRYPTO_BUFFER_SIZE`. The
//   connection closes.
// - **No place in the set of ranges**: the bytes are dropped and
//   `Connection.packet_data_dropped` is set, so the packet is not acknowledged
//   and the peer sends them again. The result is true: the connection goes on.
// - **A failure of TLS** (a message that does not read, a signature that does
//   not verify, a key that is not the pinned key) closes the connection with
//   `tls_failure_code`.
//
// It gives false when the frame closed the connection.
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
