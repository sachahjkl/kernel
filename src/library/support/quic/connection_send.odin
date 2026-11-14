package quic

// The send path of a connection: one datagram at a time, with a packet of each
// packet number space that has something to send, in the order Initial,
// Handshake, 1-RTT (RFC 9000, section 12.2).
//
// A datagram is built in two passes. The first pass writes the frames of each
// packet into the private memory of the record (`Connection.payloads`), with
// the room that the datagram still has. The second pass writes each header,
// copies the frames after it, and seals the packet into the buffer of the
// caller. Between the two, PADDING frames fill a datagram that must have 1200
// bytes.
//
// Each packet has a packet number of 4 bytes, and each long header a Length of
// 2 bytes: the packets are short, and a fixed form keeps the room of each
// packet known before its frames are written.

import "contract:errors"

PACKET_NUMBER_SIZE :: 4 // The bytes of the packet number of each packet that this side sends: always 4, the longest form (RFC 9000, section 17.1), so the size of a header does not depend on the number.
LONG_HEADER_LENGTH_SIZE :: 2 // The bytes of the Length field of each long header that this side sends: a variable-length integer of 2 bytes, which counts up to 16 383 bytes. A packet has 1200 bytes at most.
SMALLEST_FRAMES_ROOM :: 8 // The least room for frames, in bytes, for which a packet is made: with less left in the datagram, the space waits for the next datagram.

// What one packet of a datagram carries, before it is sealed: the result of
// the first pass of `connection_datagram_send` for one encryption level.
@(private)
Packet_Plan :: struct {
	built:          bool, // The level has a packet in this datagram.
	payload_length: int, // The bytes of its frames in `Connection.payloads`, with the PADDING frames that were added.
	ack_eliciting:  bool, // The packet carries a frame that the peer must acknowledge: it gets a `Sent_Packet` record.
	record:         Sent_Packet, // What the packet carries, for that record: its ranges of data and its control frames.
}

// connection_datagram_send writes the next datagram to send in `buffer`, and
// gives its length.
//
// The caller calls it in a loop until it gives 0, after each receive, each
// call of `connection_time_passes` and each write on a stream. A datagram that
// it gave counts as sent: its packets have their numbers and their records,
// and the timers started. The caller sends it to the remote of the connection;
// a datagram that the caller cannot send is a lost datagram, and loss
// detection sends its data again.
//
// **Parameters**
//
// - `connection`: the record.
// - `buffer`: where the datagram goes. Give `MAX_DATAGRAM_SIZE` bytes: the
//   call uses no more, and with less a datagram that must have 1200 bytes cannot
//   be made.
// - `now`: the time, in microseconds.
//
// **Result**: the bytes of the datagram, 1 to 1200, or 0 when no datagram goes
// now:
//
// - the connection is idle, draining or closed, or it is closing and its
//   CONNECTION_CLOSE went;
// - nothing waits: no data, no control frame, no probe, and no ACK frame that
//   is due;
// - the congestion window is full: new data waits for an acknowledgement. A
//   probe and an ACK frame go all the same;
// - the anti-amplification limit of a server that did not validate its client
//   leaves too little room (`amplification_budget`);
// - a packet could not be sealed: the connection closes with INTERNAL_ERROR.
//
// **What one datagram holds**
//
// - One packet at most for each space whose keys are installed, Initial first.
//   The 1-RTT space sends only after the handshake completed.
// - In each packet: an ACK frame when one waits, a CRYPTO frame, the control
//   frames, one STREAM frame, or a PING for a probe with nothing else
//   (`payload_build`).
// - In the closing state: only a CONNECTION_CLOSE in each packet.
// - PADDING up to 1200 bytes when the datagram holds an Initial packet of a
//   client, or an ack-eliciting Initial packet of a server (RFC 9000, section
//   14.1).
//
// A client discards its Initial space when it first sends a Handshake packet
// (RFC 9001, section 4.9.1).
//
// ```odin
// for {
// 	length := quic.connection_datagram_send(&connection, buffer[:], now)
// 	if length == 0 {
// 		break
// 	}
// 	// ... send buffer[:length] to the remote ...
// }
// ```
connection_datagram_send :: proc "contextless" (connection: ^Connection, buffer: []u8, now: u64) -> int {
	switch connection.state {
	case .Idle, .Draining, .Closed:
		return 0
	case .Handshake, .Connected, .Closing:
	}
	if connection.state == .Closing && !connection.close_to_send {
		return 0
	}
	limit := min(len(buffer), MAX_DATAGRAM_SIZE)
	limit = int(min(u64(limit), amplification_budget(connection)))
	congestion_allows := connection.bytes_in_flight + MAX_DATAGRAM_SIZE <= CONGESTION_WINDOW
	// A datagram with an Initial packet of a client, or with an
	// ack-eliciting Initial packet of a server, has 1200 bytes (RFC 9000,
	// section 14.1).
	initial := &connection.spaces[.Initial]
	initial_usable := initial.keys_installed && !initial.discarded
	must_pad := false
	if initial_usable {
		has_data := initial.crypto.send_again.count > 0 || initial.crypto.send_next < initial.crypto.send_length
		eliciting := initial.probes > 0 || (congestion_allows && has_data)
		if connection.state == .Closing {
			must_pad = connection.configuration.tls.role == .Client
		} else if connection.configuration.tls.role == .Client {
			must_pad = eliciting || initial.ack_needed
		} else {
			must_pad = eliciting
		}
	}
	if must_pad && limit < MAX_DATAGRAM_SIZE {
		return 0
	}
	plans: [Encryption_Level]Packet_Plan
	position := 0
	last_level := Encryption_Level.Initial
	any_built := false
	for level in Encryption_Level {
		space := &connection.spaces[level]
		if !space.keys_installed || space.discarded {
			continue
		}
		if level == .Application && connection.state == .Handshake {
			continue
		}
		header_size := packet_header_size(connection, level)
		room := limit - position - header_size - TAG_SIZE
		if room < SMALLEST_FRAMES_ROOM {
			continue
		}
		plan := &plans[level]
		payload := connection.payloads[level][:room]
		if connection.state == .Closing {
			plan.payload_length = close_frame_write(connection, level, payload)
		} else {
			plan.payload_length, plan.ack_eliciting = payload_build(connection, level, payload, &plan.record, congestion_allows, now)
		}
		if plan.payload_length == 0 {
			continue
		}
		plan.built = true
		any_built = true
		last_level = level
		position += header_size + plan.payload_length + TAG_SIZE
	}
	if !any_built {
		return 0
	}
	if must_pad && position < MAX_DATAGRAM_SIZE {
		// PADDING frames at the end of the last packet: its room was
		// computed with the whole datagram, so they fit.
		plan := &plans[last_level]
		extra := MAX_DATAGRAM_SIZE - position
		for index in 0 ..< extra {
			connection.payloads[last_level][plan.payload_length + index] = FRAME_PADDING
		}
		plan.payload_length += extra
		position += extra
	}
	end := 0
	for level in Encryption_Level {
		plan := &plans[level]
		if !plan.built {
			continue
		}
		packet_end, sealed := packet_write_and_seal(connection, level, buffer, end, plan.payload_length)
		if !sealed {
			connection_fail(connection, u64(Transport_Error.Internal_Error), 0, now)
			return 0
		}
		if plan.ack_eliciting {
			sent_packet_record(connection, level, &plan.record, u64(packet_end - end), now)
		}
		connection.spaces[level].next_packet_number += 1
		end = packet_end
	}
	connection.bytes_sent += u64(end)
	connection.last_sent_time = now
	if connection.state == .Closing {
		connection.close_to_send = false
	}
	if connection.configuration.tls.role == .Client && plans[.Handshake].built {
		// A client drops its Initial keys when it first sends a Handshake
		// packet (RFC 9001, section 4.9.1).
		connection_space_discard(connection, .Initial)
	}
	return end
}

// packet_header_size gives the bytes of the header of a packet of a level,
// with its packet number: the first pass subtracts it from the room of the
// datagram.
//
// - A 1-RTT packet has a short header (RFC 9000, section 17.3.1): 1 byte, the
//   connection identifier of the peer, and the packet number.
// - An Initial and a Handshake packet have a long header (RFC 9000, section
//   17.2): 1 byte, the version, the two connection identifiers each with its
//   length, the Length field and the packet number.
// - An Initial packet also has its token, with its length: empty, or the Retry
//   token of a client after a Retry.
@(private)
packet_header_size :: proc "contextless" (connection: ^Connection, level: Encryption_Level) -> int {
	if level == .Application {
		return 1 + connection.peer_connection_id_length + PACKET_NUMBER_SIZE
	}
	size := 1 + 4 + 1 + connection.peer_connection_id_length + 1 + CONNECTION_ID_SIZE + LONG_HEADER_LENGTH_SIZE + PACKET_NUMBER_SIZE
	if level == .Initial {
		// The token: its length, then its bytes. A client after a Retry
		// sends the token of the Retry; else it is empty.
		token := connection.retry_token_length
		size += variable_length_integer_size(u64(token)) + token
	}
	return size
}

// packet_write_and_seal writes the header of a packet at `position` in the
// buffer, copies its frames after it, and seals the packet: the payload is
// encrypted and authenticated, and the header is protected (`packet_seal`).
//
// - `level`: the encryption level: it gives the form of the header, the keys
//   and the packet number.
// - `position`: the first byte of the packet in `buffer`: after the packet
//   before it in the datagram.
// - `payload_length`: the bytes of the frames in `Connection.payloads` of the
//   level.
//
// It gives `end`, the byte after the packet, and `ok` false when the seal
// failed. The version in a long header is always 1. The caller adds 1 to the
// packet number of the space after it.
@(private)
packet_write_and_seal :: proc "contextless" (connection: ^Connection, level: Encryption_Level, buffer: []u8, position: int, payload_length: int) -> (end: int, ok: bool) {
	space := &connection.spaces[level]
	start := position
	at := position
	peer := connection.peer_connection_id[:connection.peer_connection_id_length]
	if level == .Application {
		buffer[at] = FIXED_BIT | u8(PACKET_NUMBER_SIZE - 1)
		at += 1
		at += copy(buffer[at:], peer)
	} else {
		type := level == .Initial ? Packet_Type.Initial : Packet_Type.Handshake
		buffer[at] = LONG_HEADER_FORM | FIXED_BIT | u8(type) << 4 | u8(PACKET_NUMBER_SIZE - 1)
		at += 1
		buffer[at], buffer[at + 1], buffer[at + 2], buffer[at + 3] = 0, 0, 0, 1
		at += 4
		buffer[at] = u8(len(peer))
		at += 1
		at += copy(buffer[at:], peer)
		buffer[at] = CONNECTION_ID_SIZE
		at += 1
		at += copy(buffer[at:], connection.local_connection_id[:])
		if level == .Initial {
			token := connection.retry_token[:connection.retry_token_length]
			at += variable_length_integer_write(buffer, at, u64(len(token)), variable_length_integer_size(u64(len(token))))
			at += copy(buffer[at:], token)
		}
		at += variable_length_integer_write(buffer, at, u64(PACKET_NUMBER_SIZE + payload_length + TAG_SIZE), LONG_HEADER_LENGTH_SIZE)
	}
	number_offset := at
	copy(buffer[number_offset + PACKET_NUMBER_SIZE:], connection.payloads[level][:payload_length])
	error: errors.Error_Record
	return packet_seal(connection.cryptography, &space.send_keys, buffer, start, number_offset, payload_length, space.next_packet_number, &error)
}

// sent_packet_record takes a free place of the space for an ack-eliciting
// packet that was just sealed: its number, its time, its size on the wire and
// what it carried.
//
// Its bytes join `Connection.bytes_in_flight`, and the probe timeout of the
// space starts again from `now`. The first ack-eliciting packet after a packet
// of the peer also moves the last activity of the idle timeout (RFC 9000,
// section 10.1); the next ones do not, so the probes to a peer that went
// silent do not keep the connection alive. `payload_build` checked that a
// place is free.
@(private)
sent_packet_record :: proc "contextless" (connection: ^Connection, level: Encryption_Level, record: ^Sent_Packet, size: u64, now: u64) {
	space := &connection.spaces[level]
	for &packet in space.sent {
		if packet.in_use {
			continue
		}
		packet = record^
		packet.in_use = true
		packet.packet_number = space.next_packet_number
		packet.time_sent = now
		packet.size = size
		space.ack_eliciting_in_flight += 1
		space.last_ack_eliciting_sent_time = now
		connection.bytes_in_flight += size
		if !connection.ack_eliciting_sent_since_receive {
			// The idle timer starts again at the first ack-eliciting packet
			// after a packet of the peer (RFC 9000, section 10.1).
			connection.ack_eliciting_sent_since_receive = true
			connection.last_activity = now
		}
		return
	}
}

// sent_slot_is_free says if the space can record one more ack-eliciting
// packet: fewer than `SENT_PACKET_LIMIT` wait. With no place, the space sends
// no ack-eliciting frame, because a packet that is not recorded could not be
// sent again.
@(private)
sent_slot_is_free :: proc "contextless" (space: ^Packet_Number_Space) -> bool {
	return space.ack_eliciting_in_flight < SENT_PACKET_LIMIT
}

// payload_build writes the frames of one packet of a level, in the order of
// their importance: an ACK frame when one waits, then CRYPTO data, the control
// frames, one STREAM frame, and a PING for a probe with nothing else.
//
// - `payload`: where the frames go: its length is the room of the packet.
// - `record`: what the packet carries, filled for the `Sent_Packet` record.
// - `congestion_allows`: one more datagram fits in the congestion window. When
//   false, only a probe carries ack-eliciting frames.
//
// It gives the length of the frames and whether they are ack-eliciting. It
// gives 0 when the packet would carry nothing that must go now, and it then
// changed nothing.
//
// **When an ACK frame goes alone.** In the Initial and Handshake spaces, at
// once. In the 1-RTT space, after two ack-eliciting packets of the peer, or at
// the deadline of `MAX_ACK_DELAY_OF_THIS_SIDE` (RFC 9000, section 13.2.1). An
// ACK frame that waits goes with any ack-eliciting packet before that.
//
// Ack-eliciting frames need a free place for the record of the packet
// (`sent_slot_is_free`). The control frames and the STREAM frame go only in
// the 1-RTT space. A probe that carried an ack-eliciting frame takes one from
// the probes that the space owes.
@(private)
payload_build :: proc "contextless" (connection: ^Connection, level: Encryption_Level, payload: []u8, record: ^Sent_Packet, congestion_allows: bool, now: u64) -> (length: int, ack_eliciting: bool) {
	space := &connection.spaces[level]
	writer := Frame_Writer{bytes = payload}
	ack_written := false
	if space.ack_needed && space.has_received {
		ack_written = ack_frame_write(connection, level, &writer, now)
	}
	probe := space.probes > 0
	if (congestion_allows || probe) && sent_slot_is_free(space) {
		if crypto_frame_write(space, &writer, record) {
			ack_eliciting = true
		}
		if level == .Application {
			if control_frames_write(connection, &writer, record) {
				ack_eliciting = true
			}
			if stream_frame_write(connection, &writer, record) {
				ack_eliciting = true
			}
		}
		if probe && !ack_eliciting && frame_room(&writer) >= 1 {
			frame_write_integer(&writer, FRAME_PING)
			ack_eliciting = true
		}
	}
	if !ack_eliciting {
		// An ACK alone goes at once in the Initial and Handshake spaces, and
		// in the 1-RTT space after two packets or the delay (RFC 9000,
		// section 13.2.1).
		ack_due := ack_written && (level != .Application || space.ack_eliciting_unacknowledged >= 2 || now >= space.ack_deadline)
		if !ack_due {
			return 0, false
		}
	}
	if ack_written {
		space.ack_needed = false
		space.ack_eliciting_unacknowledged = 0
	}
	if probe && ack_eliciting {
		space.probes -= 1
	}
	return writer.position, ack_eliciting
}

// ack_frame_write writes an ACK frame of the packets of the peer in a space
// (RFC 9000, section 19.3), from the largest range down.
//
// It writes as many ranges as fit in the room of the packet,
// `ACK_RANGES_SEND_LIMIT` at most: it drops the oldest ranges until the frame
// fits. The ACK Delay field is the time since the largest packet came, in
// units of 8 microseconds (`ACK_DELAY_EXPONENT_OF_THIS_SIDE`), in the 1-RTT
// space only: the Initial and Handshake spaces send 0. It sends no ECN counts.
//
// It gives false, with nothing written, when no packet of the peer was
// recorded or when not even one range fits.
@(private)
ack_frame_write :: proc "contextless" (connection: ^Connection, level: Encryption_Level, writer: ^Frame_Writer, now: u64) -> bool {
	space := &connection.spaces[level]
	received := &space.received
	if received.count == 0 {
		return false
	}
	top := received.count - 1
	largest := received.ends[top] - 1
	ack_delay: u64
	if level == .Application && now > space.largest_received_time {
		ack_delay = (now - space.largest_received_time) >> ACK_DELAY_EXPONENT_OF_THIS_SIDE
	}
	first_range := largest - received.starts[top]
	count := min(received.count, ACK_RANGES_SEND_LIMIT)
	// Fewer ranges until the frame fits.
	for count >= 1 {
		size := 1 + variable_length_integer_size(largest) + variable_length_integer_size(ack_delay) + variable_length_integer_size(u64(count - 1)) + variable_length_integer_size(first_range)
		for index := top - 1; index > top - count; index -= 1 {
			gap := received.starts[index + 1] - received.ends[index] - 1
			range_length := received.ends[index] - 1 - received.starts[index]
			size += variable_length_integer_size(gap) + variable_length_integer_size(range_length)
		}
		if size <= frame_room(writer) {
			break
		}
		count -= 1
	}
	if count < 1 {
		return false
	}
	frame_write_integer(writer, FRAME_ACK)
	frame_write_integer(writer, largest)
	frame_write_integer(writer, ack_delay)
	frame_write_integer(writer, u64(count - 1))
	frame_write_integer(writer, first_range)
	for index := top - 1; index > top - count; index -= 1 {
		// The gap counts the numbers between two ranges, less one; the
		// length counts the numbers of a range, less one (RFC 9000,
		// section 19.3.1).
		frame_write_integer(writer, received.starts[index + 1] - received.ends[index] - 1)
		frame_write_integer(writer, received.ends[index] - 1 - received.starts[index])
	}
	return !writer.failed
}

// crypto_frame_write writes one CRYPTO frame of the handshake bytes of a
// space: the bytes of a lost packet first, then new bytes.
//
// The frame takes the room that is left, so a long message of TLS goes in
// several packets. It notes the range in `record`, and moves the mark of what
// was sent. It gives false, with nothing written, when no handshake byte waits
// or when the room does not hold the fields and one byte.
@(private)
crypto_frame_write :: proc "contextless" (space: ^Packet_Number_Space, writer: ^Frame_Writer, record: ^Sent_Packet) -> bool {
	crypto := &space.crypto
	offset, length: u64
	again := crypto.send_again.count > 0
	if again {
		offset, length = crypto.send_again.starts[0], crypto.send_again.ends[0] - crypto.send_again.starts[0]
	} else if crypto.send_next < crypto.send_length {
		offset, length = crypto.send_next, crypto.send_length - crypto.send_next
	} else {
		return false
	}
	// The type, the offset, and a length of 2 bytes at most (the buffer has
	// 4096 bytes).
	overhead := 1 + variable_length_integer_size(offset) + 2
	room := frame_room(writer)
	if room <= overhead {
		return false
	}
	length = min(length, u64(room - overhead))
	if again {
		range_set_take_first(&crypto.send_again, length)
	} else {
		crypto.send_next += length
	}
	frame_write_integer(writer, FRAME_CRYPTO)
	frame_write_integer(writer, offset)
	frame_write_integer(writer, length)
	frame_write_bytes(writer, crypto.send[int(offset):int(offset + length)])
	record.crypto_offset, record.crypto_length = offset, length
	return true
}

// control_frames_write writes the control frames that wait, each one when it
// fits: those of the connection, then those of one stream.
//
// Each frame carries the value of now: MAX_DATA carries
// `Connection.receive_max_data`, MAX_STREAMS and STREAMS_BLOCKED the limit of
// streams of their side, PATH_RESPONSE the bytes of the last challenge. A
// frame that went leaves `Connection.pending_controls` and is noted in
// `record`; a frame that did not fit waits for the next packet.
//
// A packet carries the control frames of the first stream record that has
// some, and of no other: its `Sent_Packet` record names one stream. The other
// streams wait for the next packets. It gives true when it wrote a frame.
@(private)
control_frames_write :: proc "contextless" (connection: ^Connection, writer: ^Frame_Writer, record: ^Sent_Packet) -> bool {
	written := false
	pending := &connection.pending_controls
	if .Handshake_Done in pending^ && frame_room(writer) >= 1 {
		frame_write_integer(writer, FRAME_HANDSHAKE_DONE)
		pending^ -= {.Handshake_Done}
		record.controls += {.Handshake_Done}
		written = true
	}
	if .Max_Data in pending^ && frame_room(writer) >= 1 + variable_length_integer_size(connection.receive_max_data) {
		frame_write_integer(writer, FRAME_MAX_DATA)
		frame_write_integer(writer, connection.receive_max_data)
		pending^ -= {.Max_Data}
		record.controls += {.Max_Data}
		written = true
	}
	if .Max_Streams in pending^ && frame_room(writer) >= 1 + variable_length_integer_size(connection.streams_limit_given) {
		frame_write_integer(writer, FRAME_MAX_STREAMS_BIDIRECTIONAL)
		frame_write_integer(writer, connection.streams_limit_given)
		pending^ -= {.Max_Streams}
		record.controls += {.Max_Streams}
		written = true
	}
	if .Streams_Blocked in pending^ && frame_room(writer) >= 1 + variable_length_integer_size(connection.peer_max_streams_bidirectional) {
		frame_write_integer(writer, FRAME_STREAMS_BLOCKED_BIDIRECTIONAL)
		frame_write_integer(writer, connection.peer_max_streams_bidirectional)
		pending^ -= {.Streams_Blocked}
		record.controls += {.Streams_Blocked}
		written = true
	}
	if .Path_Response in pending^ && frame_room(writer) >= 1 + PATH_DATA_SIZE {
		frame_write_integer(writer, FRAME_PATH_RESPONSE)
		frame_write_bytes(writer, connection.path_response[:])
		pending^ -= {.Path_Response}
		record.controls += {.Path_Response}
		written = true
	}
	// The control frames of one stream: a lost packet names one stream, so
	// its frames go again for that stream.
	for &stream in connection.streams {
		if !stream.in_use || stream.pending_controls == {} {
			continue
		}
		if stream_control_frames_write(&stream, writer, record) {
			written = true
		}
		break
	}
	return written
}

// stream_control_frames_write writes the control frames of one stream that
// wait, each one when it fits: MAX_STREAM_DATA, RESET_STREAM, STOP_SENDING.
//
// - MAX_STREAM_DATA carries `receive_limit`, the flow control limit of the
//   stream that this side gives.
// - RESET_STREAM carries the code of the reset and the final size: the largest
//   offset that this side sent, which `stream_reset_send` put in `send_length`.
//   The peer counts it for flow control (RFC 9000, section 4.5).
// - STOP_SENDING carries the code of the application.
//
// The frames that went leave `pending_controls` of the stream, and `record`
// names them with the stream identifier. It gives false when none fits.
@(private)
stream_control_frames_write :: proc "contextless" (stream: ^Stream, writer: ^Frame_Writer, record: ^Sent_Packet) -> bool {
	identifier_size := variable_length_integer_size(stream.identifier)
	written: bit_set[Stream_Control]
	if .Max_Stream_Data in stream.pending_controls && frame_room(writer) >= 1 + identifier_size + variable_length_integer_size(stream.receive_limit) {
		frame_write_integer(writer, FRAME_MAX_STREAM_DATA)
		frame_write_integer(writer, stream.identifier)
		frame_write_integer(writer, stream.receive_limit)
		written += {.Max_Stream_Data}
	}
	if .Reset_Stream in stream.pending_controls && frame_room(writer) >= 1 + identifier_size + variable_length_integer_size(stream.reset_code) + variable_length_integer_size(stream.send_length) {
		// The final size is the largest offset sent: stream_reset_send set
		// send_length to it. The peer counts it for flow control.
		frame_write_integer(writer, FRAME_RESET_STREAM)
		frame_write_integer(writer, stream.identifier)
		frame_write_integer(writer, stream.reset_code)
		frame_write_integer(writer, stream.send_length)
		written += {.Reset_Stream}
	}
	if .Stop_Sending in stream.pending_controls && frame_room(writer) >= 1 + identifier_size + variable_length_integer_size(stream.stop_sending_code) {
		frame_write_integer(writer, FRAME_STOP_SENDING)
		frame_write_integer(writer, stream.identifier)
		frame_write_integer(writer, stream.stop_sending_code)
		written += {.Stop_Sending}
	}
	if written == {} {
		return false
	}
	stream.pending_controls -= written
	record.stream_controls = written
	record.stream_controls_identifier = stream.identifier
	return true
}

// stream_frame_write writes one STREAM frame: of the first stream, from the
// record of its turn, that has bytes or its end to send. Each stream then gets
// its turn.
//
// A packet carries one STREAM frame, so the order decides which stream moves.
// The search starts at `Connection.stream_send_turn` and goes round the table;
// the turn then moves to the record after the one that sent. A stream with
// much to send therefore does not starve the others. Streams send only in the
// state `Connected`, and a stream that this side reset sends no more data. It
// gives false when no stream has anything to send within its limits.
@(private)
stream_frame_write :: proc "contextless" (connection: ^Connection, writer: ^Frame_Writer, record: ^Sent_Packet) -> bool {
	if connection.state != .Connected {
		return false
	}
	count := len(connection.streams)
	for step in 0 ..< count {
		index := (connection.stream_send_turn + step) % count
		stream := &connection.streams[index]
		if !stream.in_use || stream.reset_sent {
			continue
		}
		if stream_frame_write_of(connection, stream, writer, record) {
			connection.stream_send_turn = (index + 1) % count
			return true
		}
	}
	return false
}

// stream_frame_write_of writes one STREAM frame of a stream (RFC 9000, section
// 19.8): the bytes of a lost packet first, then new bytes within the limits of
// the peer, and the end of the stream when the last byte goes.
//
// - **Bytes to send again** come first. The ranges that the peer acknowledged
//   since are removed before, because new bytes of the application can have
//   taken their place in the ring.
// - **New bytes** go up to the least of: the bytes that the application wrote,
//   the flow control limit of the stream (`send_limit`), and the room that the
//   flow control limit of the connection leaves (`Connection.peer_max_data`).
//   Only new bytes count against the limit of the connection.
// - **The end** (the FIN bit) is set when the frame carries the last byte that
//   the application wrote, after `stream_write` got `finish`. A frame with no
//   byte and the FIN bit goes when every byte went before.
//
// The frame always has a Length field, and an Offset field when the offset is
// not 0. It takes the room that is left in the packet. It notes its range in
// `record`. It gives false, with nothing written, when the stream has nothing
// to send now or when the room is too small.
@(private)
stream_frame_write_of :: proc "contextless" (connection: ^Connection, stream: ^Stream, writer: ^Frame_Writer, record: ^Sent_Packet) -> bool {
	// The bytes that the peer acknowledged may be written over by new
	// bytes: they are never sent again.
	range_set_remove_below(&stream.send_again, range_set_prefix(&stream.send_acknowledged))
	offset, length: u64
	again := stream.send_again.count > 0
	if again {
		offset, length = stream.send_again.starts[0], stream.send_again.ends[0] - stream.send_again.starts[0]
	} else {
		connection_room := connection.peer_max_data - min(connection.data_sent_total, connection.peer_max_data)
		limit := min(stream.send_limit, stream.send_length, stream.send_next + connection_room)
		if stream.send_next < limit {
			offset, length = stream.send_next, limit - stream.send_next
		} else if stream.send_finish && !stream.finish_sent && stream.send_next == stream.send_length {
			offset, length = stream.send_next, 0
		} else {
			return false
		}
	}
	// The type, the identifier, the offset, and a length of 2 bytes at most
	// (a packet is under 16 KiB).
	overhead := 1 + variable_length_integer_size(stream.identifier) + variable_length_integer_size(offset) + 2
	room := frame_room(writer)
	if room < overhead || (length > 0 && room == overhead) {
		return false
	}
	length = min(length, u64(room - overhead))
	if again {
		range_set_take_first(&stream.send_again, length)
	} else {
		stream.send_next += length
		connection.data_sent_total += length
	}
	finish := stream.send_finish && offset + length == stream.send_length
	if finish {
		stream.finish_sent = true
	}
	type := u64(FRAME_STREAM | FRAME_STREAM_FLAG_LENGTH)
	if offset > 0 {
		type |= FRAME_STREAM_FLAG_OFFSET
	}
	if finish {
		type |= FRAME_STREAM_FLAG_FINISH
	}
	frame_write_integer(writer, type)
	frame_write_integer(writer, stream.identifier)
	if offset > 0 {
		frame_write_integer(writer, offset)
	}
	frame_write_integer(writer, length)
	ring_read(stream.send[:], offset, writer.bytes[writer.position:][:int(length)])
	writer.position += int(length)
	record.stream_identifier, record.stream_offset, record.stream_length, record.stream_finish = stream.identifier, offset, length, finish
	return true
}

// close_frame_write writes the CONNECTION_CLOSE of this side in one packet
// (RFC 9000, section 19.19), and gives its length, or 0 when it does not fit.
//
// - A close of the transport (`connection_fail`) is a frame of type 0x1c with
//   the error code and the type of the frame that caused it.
// - A close of the application (`connection_close`) is a frame of type 0x1d
//   with the code of the application, in a 1-RTT packet only. In an Initial or a
//   Handshake packet it is a frame of type 0x1c with APPLICATION_ERROR and the
//   frame type 0, so that no code of the application goes out before the
//   handshake (RFC 9000, section 10.2.3).
//
// The reason phrase is always empty. In the closing state each space with keys
// sends this frame, so that a peer at any point of the handshake can read one
// of them.
@(private)
close_frame_write :: proc "contextless" (connection: ^Connection, level: Encryption_Level, payload: []u8) -> int {
	writer := Frame_Writer{bytes = payload}
	if connection.close_is_application && level == .Application {
		frame_write_integer(&writer, FRAME_CONNECTION_CLOSE_APPLICATION)
		frame_write_integer(&writer, connection.close_error_code)
	} else {
		code := connection.close_is_application ? u64(Transport_Error.Application_Error) : connection.close_error_code
		frame_write_integer(&writer, FRAME_CONNECTION_CLOSE)
		frame_write_integer(&writer, code)
		frame_write_integer(&writer, connection.close_is_application ? 0 : connection.close_frame_type)
	}
	frame_write_integer(&writer, 0) // No reason phrase.
	if writer.failed {
		return 0
	}
	return writer.position
}
