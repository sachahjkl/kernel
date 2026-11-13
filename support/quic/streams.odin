package quic

// The streams of a connection (RFC 9000, sections 2 to 4; docs/QUIC.md,
// section 5). The caller gives a table of stream records with the
// connection: their count is the bound of the streams that are open at one
// time. Each record holds its own buffers, so a stream never waits for the
// memory of another.
//
// The rules of this layer:
// - Only bidirectional streams, and only the client opens them. A server
//   gives the client a limit of streams (MAX_STREAMS) equal to its free
//   records, so each stream that the client can open has a record. A server
//   that opened streams too would take records that the limit promised.
// - A frame that names a stream of the client that the client did not open
//   yet opens it, and each lower stream of the client that is not open yet
//   (RFC 9000, section 3.2). The limit that this side gave bounds that
//   number, and the limit counts free records only.
// - When both directions of a stream ended (the last byte of this side or
//   its reset acknowledged, and the end of the peer read by the
//   application), its record is free again. A server then gives the client
//   one more stream with MAX_STREAMS. A frame for a stream that ended is
//   dropped: its identifier is never used again.
// - Flow control for each stream (MAX_STREAM_DATA) and for the connection
//   (MAX_DATA), in both directions. Data past a limit that this side gave
//   is FLOW_CONTROL_ERROR; a final size that changes is FINAL_SIZE_ERROR.

STREAM_BUFFER_SIZE :: 65536 // The bytes of a stream in each direction that wait: to be acknowledged, or to be read.

// The control frames of one stream, which a packet carries and which go
// again when the packet is lost.
Stream_Control :: enum u8 {
	Max_Stream_Data, // A new limit of the data of the stream for the peer.
	Reset_Stream, // This side ends its sending.
	Stop_Sending, // This side asks the peer to end its sending.
}

// The state of one stream, without its buffers: a new stream clears this
// part only.
Stream_State :: struct {
	in_use:              bool, // The record holds an open stream.
	identifier:          u64, // The stream identifier: 0, 4, 8... for the streams of the client.
	// Sending: the bytes that the application wrote, in the ring send by
	// offset.
	send_length:         u64, // The bytes that the application wrote, from offset 0.
	send_next:           u64, // The first offset that was never sent.
	send_again:          Range_Set, // Offsets of lost packets, to send again.
	send_acknowledged:   Range_Set, // Offsets that the peer acknowledged.
	send_finish:         bool, // The application wrote its last byte.
	finish_sent:         bool, // A STREAM frame with FIN was sent.
	finish_acknowledged: bool, // The peer acknowledged it.
	send_limit:          u64, // The MAX_STREAM_DATA of the peer.
	reset_sent:          bool, // This side ended its sending with RESET_STREAM: at a STOP_SENDING of the peer, or at a call of the application.
	reset_code:          u64, // The application error code of that reset.
	reset_acknowledged:  bool, // The peer acknowledged it.
	// Receiving: the bytes of the peer, in the ring receive by offset.
	received:            Range_Set, // The offsets of the peer that came.
	read_offset:         u64, // The first offset that the application did not read.
	receive_limit:       u64, // The MAX_STREAM_DATA that this side gave.
	highest_received:    u64, // The end of the data of the peer so far: its largest offset plus 1.
	has_final_size:      bool, // The peer gave the end of the stream.
	final_size:          u64, // Its bytes in all.
	reset_received:      bool, // The peer ended its sending with RESET_STREAM.
	peer_reset_code:     u64, // Its application error code.
	end_read:            bool, // The application read the end of the peer: its last byte, or its reset.
	stop_sending_sent:   bool, // This side sent STOP_SENDING.
	stop_sending_code:   u64, // Its application error code.
	pending_controls:    bit_set[Stream_Control], // The control frames that wait to be sent.
}

// One stream record of the table of the caller: its state and its two
// buffers of 64 KiB.
Stream :: struct {
	using state: Stream_State,
	send:        [STREAM_BUFFER_SIZE]u8, // The bytes that this side sends, by offset modulo the size.
	receive:     [STREAM_BUFFER_SIZE]u8, // The bytes of the peer, by offset modulo the size.
}

// stream_of gives the record of an open stream, or nil.
stream_of :: proc "contextless" (connection: ^Connection, identifier: u64) -> ^Stream {
	for &stream in connection.streams {
		if stream.in_use && stream.identifier == identifier {
			return &stream
		}
	}
	return nil
}

// stream_is_of_client says if a stream identifier names a stream that the
// client opens.
@(private)
stream_is_of_client :: proc "contextless" (identifier: u64) -> bool {
	return identifier & 0x01 == 0
}

// stream_record_take gives a free record to a new stream, or nil.
@(private)
stream_record_take :: proc "contextless" (connection: ^Connection, identifier: u64) -> ^Stream {
	for &stream in connection.streams {
		if stream.in_use {
			continue
		}
		stream.state = {in_use = true, identifier = identifier, receive_limit = STREAM_BUFFER_SIZE}
		// The limit that the peer gave for a stream of this kind: its
		// "bidirectional local" for a stream that the peer opened, its
		// "bidirectional remote" for a stream that this side opened.
		opened_by_this_side := stream_is_of_client(identifier) == (connection.configuration.tls.role == .Client)
		if opened_by_this_side {
			stream.send_limit = connection.peer_parameters.initial_max_stream_data_bidirectional_remote
		} else {
			stream.send_limit = connection.peer_parameters.initial_max_stream_data_bidirectional_local
		}
		return &stream
	}
	return nil
}

// stream_of_frame gives the stream that a frame of the peer names, after
// its checks: a unidirectional stream (this side allows none and opens
// none), a stream of the peer over the limit that this side gave
// (STREAM_LIMIT_ERROR), a stream of this side that it did not open
// (STREAM_STATE_ERROR). A stream of the peer that is not open yet is
// opened, with each lower one. It gives nil and ok true for a stream that
// ended: the caller drops the frame. ok false: the connection closed.
@(private)
stream_of_frame :: proc "contextless" (connection: ^Connection, identifier: u64, frame_type: u64, now: u64) -> (stream: ^Stream, ok: bool) {
	role := connection.configuration.tls.role
	opened_by_peer := stream_is_of_client(identifier) == (role == .Server)
	index := identifier >> 2
	if identifier & 0x02 != 0 {
		code := opened_by_peer ? Transport_Error.Stream_Limit_Error : Transport_Error.Stream_State_Error
		return nil, connection_fail(connection, u64(code), frame_type, now)
	}
	if opened_by_peer {
		if role == .Client || index >= connection.streams_limit_given {
			// A client gives the server no stream.
			return nil, connection_fail(connection, u64(Transport_Error.Stream_Limit_Error), frame_type, now)
		}
		for connection.streams_opened_by_peer <= index {
			next := connection.streams_opened_by_peer << 2 | identifier & 0x03
			if stream_record_take(connection, next) == nil {
				// The limit counts free records only: this does not happen.
				return nil, connection_fail(connection, u64(Transport_Error.Internal_Error), frame_type, now)
			}
			connection.streams_opened_by_peer += 1
		}
	} else if index >= connection.streams_opened_by_this_side {
		return nil, connection_fail(connection, u64(Transport_Error.Stream_State_Error), frame_type, now)
	}
	return stream_of(connection, identifier), true
}

// stream_data_receive takes the data of a STREAM frame: its end within the
// limits that this side gave, for the stream and for the connection, and a
// final size that never changes (RFC 9000, sections 4.1, 4.5).
@(private)
stream_data_receive :: proc "contextless" (connection: ^Connection, stream: ^Stream, offset: u64, data: []u8, finish: bool, now: u64) -> bool {
	end := offset + u64(len(data))
	if stream.has_final_size && (end > stream.final_size || (finish && end != stream.final_size)) {
		return connection_fail(connection, u64(Transport_Error.Final_Size_Error), FRAME_STREAM, now)
	}
	if finish && end < stream.highest_received {
		return connection_fail(connection, u64(Transport_Error.Final_Size_Error), FRAME_STREAM, now)
	}
	if !stream_received_offset_allowed(connection, stream, end, FRAME_STREAM, now) {
		return false
	}
	if stream.reset_received {
		return true
	}
	if finish {
		stream.has_final_size = true
		stream.final_size = end
	}
	// The bytes that were read already are not written again; the limit
	// above keeps each other byte inside the ring.
	from := max(offset, stream.read_offset)
	if from < end {
		if !range_set_insert(&stream.received, from, end) {
			// No place to note the data: it is dropped, and its packet is
			// not acknowledged (packet_receive).
			connection.packet_data_dropped = true
			return true
		}
		ring_write(stream.receive[:], from, data[int(from - offset):])
	}
	return true
}

// stream_received_offset_allowed checks the largest offset that the peer
// sent on a stream against the limit of the stream and the limit of the
// connection, and counts it for the connection.
@(private)
stream_received_offset_allowed :: proc "contextless" (connection: ^Connection, stream: ^Stream, end: u64, frame_type: u64, now: u64) -> bool {
	if end > stream.receive_limit {
		return connection_fail(connection, u64(Transport_Error.Flow_Control_Error), frame_type, now)
	}
	if end > stream.highest_received {
		growth := end - stream.highest_received
		if growth > connection.receive_max_data - min(connection.data_received_total, connection.receive_max_data) {
			return connection_fail(connection, u64(Transport_Error.Flow_Control_Error), frame_type, now)
		}
		connection.data_received_total += growth
		stream.highest_received = end
	}
	return true
}

// stream_reset_receive ends the receiving part of a stream at a
// RESET_STREAM of the peer (RFC 9000, section 19.4). The bytes that will
// never be read give their room back to the connection.
@(private)
stream_reset_receive :: proc "contextless" (connection: ^Connection, stream: ^Stream, code: u64, final_size: u64, now: u64) -> bool {
	if (stream.has_final_size && final_size != stream.final_size) || final_size < stream.highest_received {
		return connection_fail(connection, u64(Transport_Error.Final_Size_Error), FRAME_RESET_STREAM, now)
	}
	if !stream_received_offset_allowed(connection, stream, final_size, FRAME_RESET_STREAM, now) {
		return false
	}
	stream.has_final_size = true
	stream.final_size = final_size
	if !stream.reset_received {
		stream.reset_received = true
		stream.peer_reset_code = code
		connection.data_consumed_total += final_size - min(stream.read_offset, final_size)
		connection_receive_window_update(connection)
	}
	return true
}

// stream_stop_sending_receive ends the sending part of a stream at a
// STOP_SENDING of the peer: this side sends RESET_STREAM with the same code
// (RFC 9000, section 3.5).
@(private)
stream_stop_sending_receive :: proc "contextless" (stream: ^Stream, code: u64) {
	stream_reset_send(stream, code)
}

// stream_reset_send ends the sending part of a stream with RESET_STREAM.
// The final size of a reset is the largest offset that this side sent, not
// the bytes that the application wrote (RFC 9000, section 4.5): the peer
// counts it against its flow control. Bytes that flow control held back
// were never counted by the peer, so the stream forgets them here: after
// this, send_length is the final size, no byte is sent again, no end of the
// stream (FIN) is sent, and stream_write takes no byte (it gives 0).
@(private)
stream_reset_send :: proc "contextless" (stream: ^Stream, code: u64) {
	all_acknowledged := stream.finish_acknowledged && range_set_prefix(&stream.send_acknowledged) >= stream.send_length
	if stream.reset_sent || all_acknowledged {
		return
	}
	stream.reset_sent = true
	stream.reset_code = code
	stream.send_again = {}
	stream.send_length = stream.send_next
	stream.pending_controls += {.Reset_Stream}
}

// connection_receive_window_update gives the peer a new limit of the
// connection when half of the window was read (MAX_DATA).
@(private)
connection_receive_window_update :: proc "contextless" (connection: ^Connection) {
	if connection.data_consumed_total + connection.receive_window - connection.receive_max_data >= connection.receive_window / 2 {
		connection.receive_max_data = connection.data_consumed_total + connection.receive_window
		connection.pending_controls += {.Max_Data}
	}
}

// stream_release_when_ended frees the record of a stream whose two
// directions ended. A server gives the client one more stream for it.
@(private)
stream_release_when_ended :: proc "contextless" (connection: ^Connection, stream: ^Stream) {
	if !stream.in_use || !stream.end_read {
		return
	}
	sent_all := stream.finish_acknowledged && range_set_prefix(&stream.send_acknowledged) >= stream.send_length
	if !sent_all && !(stream.reset_sent && stream.reset_acknowledged) {
		return
	}
	stream.in_use = false
	stream_buffers_erase(stream)
	if stream_is_of_client(stream.identifier) == (connection.configuration.tls.role == .Server) {
		connection.streams_limit_given += 1
		connection.pending_controls += {.Max_Streams}
	}
}

// stream_buffers_erase writes zeros over the bytes that a stream left in
// its rings, so that a later stream of the record, or a fault, never holds
// the bytes of an earlier peer. Only the part that the stream used is
// written: the bytes before its largest offset, each ring at most once.
// After a reset of this side, send_length no longer counts the bytes that
// the application wrote, so the whole send ring is erased.
@(private)
stream_buffers_erase :: proc "contextless" (stream: ^Stream) {
	received := int(min(stream.highest_received, STREAM_BUFFER_SIZE))
	sent := stream.reset_sent ? STREAM_BUFFER_SIZE : int(min(stream.send_length, STREAM_BUFFER_SIZE))
	if received > 0 {
		secret_erase(&stream.receive[0], received)
	}
	if sent > 0 {
		secret_erase(&stream.send[0], sent)
	}
}

// stream_open opens a new stream of a client, and gives its identifier.
// false: this side is a server, the limit of the server is reached (the
// client tells it with STREAMS_BLOCKED), or no record is free.
stream_open :: proc "contextless" (connection: ^Connection) -> (identifier: u64, ok: bool) {
	if connection.configuration.tls.role != .Client || (connection.state != .Handshake && connection.state != .Connected) {
		return 0, false
	}
	if connection.streams_opened_by_this_side >= connection.peer_max_streams_bidirectional {
		if connection.peer_parameters_applied {
			connection.pending_controls += {.Streams_Blocked}
		}
		return 0, false
	}
	identifier = connection.streams_opened_by_this_side << 2
	if stream_record_take(connection, identifier) == nil {
		return 0, false
	}
	connection.streams_opened_by_this_side += 1
	return identifier, true
}

// stream_write gives bytes to a stream; it gives the count that it took
// (the room of the stream buffer). finish says that these are the last
// bytes.
stream_write :: proc "contextless" (connection: ^Connection, identifier: u64, bytes: []u8, finish: bool) -> int {
	if connection.state != .Handshake && connection.state != .Connected {
		return 0
	}
	stream := stream_of(connection, identifier)
	if stream == nil || stream.send_finish || stream.reset_sent {
		return 0
	}
	acknowledged := range_set_prefix(&stream.send_acknowledged)
	free := STREAM_BUFFER_SIZE - (stream.send_length - acknowledged)
	count := int(min(u64(len(bytes)), free))
	ring_write(stream.send[:], stream.send_length, bytes[:count])
	stream.send_length += u64(count)
	if finish && count == len(bytes) {
		stream.send_finish = true
	}
	return count
}

// stream_read gives the bytes of the peer on a stream that came in order.
// finished says that the peer sent its last byte and that it was read. A
// stream that the peer reset gives no more bytes, and reset is true. After
// the end was read, and this side ended its own direction, the stream
// ends: a read of it then gives nothing.
//
// A record is freed only when the application read the end of the peer
// here (finished or reset true), and this side's last byte or reset was
// acknowledged. A program that never reads a stream to its end keeps the
// record for the life of the connection, and a server then gives the
// client no stream in its place: a program reads each stream to its end,
// or resets it and reads the reset of the peer.
stream_read :: proc "contextless" (connection: ^Connection, identifier: u64, buffer: []u8) -> (count: int, finished: bool, reset: bool) {
	stream := stream_of(connection, identifier)
	if stream == nil {
		return 0, false, false
	}
	if stream.reset_received {
		stream.end_read = true
		stream_release_when_ended(connection, stream)
		return 0, false, true
	}
	available := range_set_prefix(&stream.received) - stream.read_offset
	count = int(min(available, u64(len(buffer))))
	ring_read(stream.receive[:], stream.read_offset, buffer[:count])
	stream.read_offset += u64(count)
	connection.data_consumed_total += u64(count)
	// Flow control: a new limit when half of the window was read.
	if stream.read_offset + STREAM_BUFFER_SIZE - stream.receive_limit >= STREAM_BUFFER_SIZE / 2 && !stream.has_final_size {
		stream.receive_limit = stream.read_offset + STREAM_BUFFER_SIZE
		stream.pending_controls += {.Max_Stream_Data}
	}
	connection_receive_window_update(connection)
	finished = stream.has_final_size && stream.read_offset == stream.final_size
	if finished {
		stream.end_read = true
		stream_release_when_ended(connection, stream)
	}
	return
}

// stream_reset ends the sending part of a stream with RESET_STREAM and an
// error code of the application: the bytes not yet acknowledged are not
// sent again.
stream_reset :: proc "contextless" (connection: ^Connection, identifier: u64, code: u64) {
	if stream := stream_of(connection, identifier); stream != nil {
		stream_reset_send(stream, code)
	}
}

// stream_stop_sending asks the peer to end its sending part of a stream
// (STOP_SENDING, with an error code of the application). The peer answers
// with RESET_STREAM.
stream_stop_sending :: proc "contextless" (connection: ^Connection, identifier: u64, code: u64) {
	stream := stream_of(connection, identifier)
	if stream == nil || stream.stop_sending_sent || stream.has_final_size {
		return
	}
	stream.stop_sending_sent = true
	stream.stop_sending_code = code
	stream.pending_controls += {.Stop_Sending}
}

// The ring of a stream: the byte at offset is at offset modulo the size.
@(private)
ring_write :: proc "contextless" (ring: []u8, offset: u64, bytes: []u8) {
	start := int(offset % u64(len(ring)))
	first := copy(ring[start:], bytes)
	copy(ring, bytes[first:])
}

@(private)
ring_read :: proc "contextless" (ring: []u8, offset: u64, bytes: []u8) {
	start := int(offset % u64(len(ring)))
	first := copy(bytes, ring[start:])
	copy(bytes[first:], ring)
}
