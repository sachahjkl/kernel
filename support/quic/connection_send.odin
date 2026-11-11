package quic

// The send path of a connection: one datagram at a time, with a packet of
// each space that has something to send, in the order Initial, Handshake,
// 1-RTT (RFC 9000, section 12.2). Each packet has a packet number of 4
// bytes, and each long header a Length of 2 bytes: the packets are short,
// and a fixed form keeps the room of each packet known before its frames
// are written.

import "contract:errors"

PACKET_NUMBER_SIZE :: 4
LONG_HEADER_LENGTH_SIZE :: 2
SMALLEST_FRAMES_ROOM :: 8 // A packet with less room for frames is not made.

// What one packet of a datagram carries, before it is sealed.
@(private)
Packet_Plan :: struct {
	built:          bool,
	payload_length: int,
	ack_eliciting:  bool,
	record:         Sent_Packet,
}

// connection_datagram_send writes the next datagram to send in buffer, and
// gives its length: 0 when nothing waits, or when a limit stops it (the
// congestion window, the anti-amplification limit of a server).
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

@(private)
packet_header_size :: proc "contextless" (connection: ^Connection, level: Encryption_Level) -> int {
	if level == .Application {
		return 1 + connection.peer_connection_id_length + PACKET_NUMBER_SIZE
	}
	size := 1 + 4 + 1 + connection.peer_connection_id_length + 1 + CONNECTION_ID_SIZE + LONG_HEADER_LENGTH_SIZE + PACKET_NUMBER_SIZE
	if level == .Initial {
		size += 1 // A token of 0 bytes: its length.
	}
	return size
}

// packet_write_and_seal writes the header of a packet at position, then its
// frames, and seals it. It gives the byte after the packet.
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
			buffer[at] = 0
			at += 1
		}
		at += variable_length_integer_write(buffer, at, u64(PACKET_NUMBER_SIZE + payload_length + TAG_SIZE), LONG_HEADER_LENGTH_SIZE)
	}
	number_offset := at
	copy(buffer[number_offset + PACKET_NUMBER_SIZE:], connection.payloads[level][:payload_length])
	error: errors.Error_Record
	return packet_seal(connection.cryptography, &space.send_keys, buffer, start, number_offset, payload_length, space.next_packet_number, &error)
}

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

@(private)
sent_slot_is_free :: proc "contextless" (space: ^Packet_Number_Space) -> bool {
	return space.ack_eliciting_in_flight < SENT_PACKET_LIMIT
}

// payload_build writes the frames of one packet: an ACK frame when one is
// due, then CRYPTO data, the control frames, STREAM data, and a PING for a
// probe with nothing else. It gives the length of the frames and whether
// they are ack-eliciting; 0 when the packet would carry nothing that must
// go now.
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

// ack_frame_write writes an ACK frame of the packets of the peer in a
// space, from the largest range down, with as many ranges as fit (16 at
// most).
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

// crypto_frame_write writes one CRYPTO frame: the bytes of a lost packet
// first, then new bytes.
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

// control_frames_write writes the control frames that wait, each one when
// it fits.
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
	if .Max_Stream_Data in pending^ && frame_room(writer) >= 2 + variable_length_integer_size(connection.stream.receive_limit) {
		frame_write_integer(writer, FRAME_MAX_STREAM_DATA)
		frame_write_integer(writer, 0)
		frame_write_integer(writer, connection.stream.receive_limit)
		pending^ -= {.Max_Stream_Data}
		record.controls += {.Max_Stream_Data}
		written = true
	}
	if .Path_Response in pending^ && frame_room(writer) >= 1 + PATH_DATA_SIZE {
		frame_write_integer(writer, FRAME_PATH_RESPONSE)
		frame_write_bytes(writer, connection.path_response[:])
		pending^ -= {.Path_Response}
		record.controls += {.Path_Response}
		written = true
	}
	stream := &connection.stream
	if .Reset_Stream in pending^ && frame_room(writer) >= 2 + variable_length_integer_size(stream.reset_code) + variable_length_integer_size(stream.send_length) {
		// The final size is every byte that the application wrote: the
		// peer counts them for flow control.
		frame_write_integer(writer, FRAME_RESET_STREAM)
		frame_write_integer(writer, 0)
		frame_write_integer(writer, stream.reset_code)
		frame_write_integer(writer, stream.send_length)
		pending^ -= {.Reset_Stream}
		record.controls += {.Reset_Stream}
		written = true
	}
	return written
}

// stream_frame_write writes one STREAM frame of stream 0: the bytes of a
// lost packet first, then new bytes within the limits of the peer, and the
// end of the stream when the last byte goes.
@(private)
stream_frame_write :: proc "contextless" (connection: ^Connection, writer: ^Frame_Writer, record: ^Sent_Packet) -> bool {
	stream := &connection.stream
	if connection.state != .Connected || !stream.opened || stream.reset_sent {
		return false
	}
	// The bytes that the peer acknowledged may be written over by new
	// bytes: they are never sent again.
	range_set_remove_below(&stream.send_again, range_set_prefix(&stream.send_acknowledged))
	offset, length: u64
	again := stream.send_again.count > 0
	if again {
		offset, length = stream.send_again.starts[0], stream.send_again.ends[0] - stream.send_again.starts[0]
	} else {
		// One stream: the data of the connection is the data of the stream.
		limit := min(stream.send_limit, connection.peer_max_data, stream.send_length)
		if stream.send_next < limit {
			offset, length = stream.send_next, limit - stream.send_next
		} else if stream.send_finish && !stream.finish_sent && stream.send_next == stream.send_length {
			offset, length = stream.send_next, 0
		} else {
			return false
		}
	}
	// The type, the identifier 0, the offset, and a length of 2 bytes at
	// most (a packet is under 16 KiB).
	overhead := 1 + 1 + variable_length_integer_size(offset) + 2
	room := frame_room(writer)
	if room < overhead || (length > 0 && room == overhead) {
		return false
	}
	length = min(length, u64(room - overhead))
	if again {
		range_set_take_first(&stream.send_again, length)
	} else {
		stream.send_next += length
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
	frame_write_integer(writer, 0)
	if offset > 0 {
		frame_write_integer(writer, offset)
	}
	frame_write_integer(writer, length)
	ring_read(stream.send[:], offset, writer.bytes[writer.position:][:int(length)])
	writer.position += int(length)
	record.stream_offset, record.stream_length, record.stream_finish = offset, length, finish
	return true
}

// close_frame_write writes the CONNECTION_CLOSE of this side in one packet.
// The close of an application is a frame 0x1d in a 1-RTT packet; in an
// Initial or Handshake packet it is a frame 0x1c with APPLICATION_ERROR, so
// that no code of the application goes out before the handshake (RFC 9000,
// section 10.2.3).
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
