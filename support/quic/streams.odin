package quic

// The streams of a connection (RFC 9000, sections 2 to 4; docs/QUIC.md,
// section 5).
//
// A QUIC stream is an ordered sequence of bytes in each direction, inside one
// connection: a loss on one stream does not hold the bytes of another. The
// caller gives a table of stream records with the connection: their count is
// the bound of the streams that are open at one time. Each record holds its
// own buffers, so a stream never waits for the memory of another.
//
// **The calls of an application:** `stream_open` (a client), `stream_write`,
// `stream_read`, `stream_reset`, `stream_stop_sending`, each with the stream
// identifier. A server finds the streams that its client opened by a walk of
// `Connection.streams`.
//
// **The rules of this layer:**
//
// - Only bidirectional streams, and only the client opens them. A server gives
//   the client a limit of streams (MAX_STREAMS) equal to its free records, so
//   each stream that the client can open has a record. A server that opened
//   streams too would take records that the limit promised.
// - A frame that names a stream of the client that the client did not open yet
//   opens it, and each lower stream of the client that is not open yet (RFC
//   9000, section 3.2). The limit that this side gave bounds that number, and
//   the limit counts free records only.
// - When both directions of a stream ended (the last byte of this side or its
//   reset acknowledged, and the end of the peer read by the application), its
//   record is free again. A server then gives the client one more stream with
//   MAX_STREAMS. A frame for a stream that ended is dropped: its identifier is
//   never used again.
// - Flow control for each stream (MAX_STREAM_DATA) and for the connection
//   (MAX_DATA), in both directions. Data past a limit that this side gave is
//   FLOW_CONTROL_ERROR; a final size that changes is FINAL_SIZE_ERROR.

STREAM_BUFFER_SIZE :: 65536 // The bytes of each of the two buffers of a stream record: 64 KiB. To send, it holds the bytes that the application wrote and that the peer did not acknowledge yet; to receive, the bytes of the peer that the application did not read yet. It is also the flow control limit of a stream that this side gives.

// The control frames of one stream, which a packet carries and which go again
// when the packet is lost.
//
// As for `Control_Frame`, each one is a bit: `Stream_State.pending_controls`
// holds the frames that wait, and `Sent_Packet.stream_controls` those that one
// packet carried. A frame is written with the value of the time when it goes.
Stream_Control :: enum u8 {
	Max_Stream_Data, // MAX_STREAM_DATA: a new flow control limit of the stream for the peer, `receive_limit`. Set when the application read half of the limit.
	Reset_Stream, // RESET_STREAM: this side ends its sending part, with `reset_code` and its final size. It goes again until the peer acknowledges it.
	Stop_Sending, // STOP_SENDING: this side asks the peer to end its sending part, with `stop_sending_code`.
}

// The state of one stream, without its buffers: a new stream clears this part
// only, under 2 KiB, and not the 128 KiB of buffers.
//
// A stream has two independent directions. The sending part counts offsets
// from 0: what the application wrote, what went, what must go again, what the
// peer acknowledged. The receiving part does the same for the bytes of the
// peer. The stream ends when both parts ended (`stream_release_when_ended`).
Stream_State :: struct {
	in_use:              bool, // The record holds an open stream. false: the record is free, and the other fields have no meaning.
	identifier:          u64, // The stream identifier (RFC 9000, section 2.1): 4 times the index of the stream, so 0, 4, 8... for the bidirectional streams of the client. An identifier names one stream for the life of the connection.
	// Sending: the bytes that the application wrote, in the ring send by
	// offset.
	send_length:         u64, // The bytes that the application wrote, from offset 0: the end of the data to send. After a reset of this side it is the final size instead: the largest offset sent.
	send_next:           u64, // The first offset that was never sent: new bytes go from here.
	send_again:          Range_Set, // The ranges of offsets of lost packets, and of the packets that a probe chose: they go before any new byte.
	send_acknowledged:   Range_Set, // The ranges of offsets that the peer acknowledged. The bytes below its range from 0 leave the ring: `stream_write` can write over them.
	send_finish:         bool, // The application wrote its last byte (`stream_write` with `finish`): the stream takes no more bytes.
	finish_sent:         bool, // A STREAM frame with the FIN bit went. It is false again when that packet is lost, so the end goes again.
	finish_acknowledged: bool, // The peer acknowledged a packet that carried the FIN bit.
	send_limit:          u64, // The flow control limit of the stream that the peer gave (MAX_STREAM_DATA): this side sends no byte at or past this offset. It starts at the value of the transport parameters of the peer, and only grows.
	reset_sent:          bool, // This side ended its sending part with RESET_STREAM: at a STOP_SENDING of the peer, or at a call of `stream_reset`. No more data and no FIN go.
	reset_code:          u64, // The application error code of that reset.
	reset_acknowledged:  bool, // The peer acknowledged a packet that carried the RESET_STREAM: the sending part ended.
	// Receiving: the bytes of the peer, in the ring receive by offset.
	received:            Range_Set, // The ranges of offsets of the peer that came. Its range from 0 is what the application can read.
	read_offset:         u64, // The first offset that the application did not read: `stream_read` gives bytes from here.
	receive_limit:       u64, // The flow control limit of the stream that this side gave the peer (MAX_STREAM_DATA): data at or past this offset is a FLOW_CONTROL_ERROR. It is always `read_offset` of some time plus `STREAM_BUFFER_SIZE`, so the bytes within it fit the ring.
	highest_received:    u64, // The end of the data of the peer so far: its largest offset plus 1. It counts against the flow control limit of the connection.
	has_final_size:      bool, // The peer gave the end of the stream: a STREAM frame with the FIN bit, or a RESET_STREAM.
	final_size:          u64, // The final size: the bytes of the stream of the peer in all. It never changes once known (RFC 9000, section 4.5).
	reset_received:      bool, // The peer ended its sending part with RESET_STREAM: the application gets no more of its bytes.
	peer_reset_code:     u64, // The application error code of the reset of the peer.
	end_read:            bool, // The application read the end of the peer through `stream_read`: its last byte, or its reset. The receiving part ended.
	stop_sending_sent:   bool, // This side asked the peer to stop (`stream_stop_sending`): a second call does nothing.
	stop_sending_code:   u64, // The application error code of that STOP_SENDING.
	pending_controls:    bit_set[Stream_Control], // The control frames of this stream that wait to be sent.
}

// One stream record of the table of the caller: the state of a stream and its
// two buffers of 64 KiB, about 129 KiB in all.
//
// The caller owns the table and gives it at the start of the connection: it
// goes in the global memory of the program or in a mapping, never on a stack.
// An application does not write the fields: it uses the calls of this file. It
// can read them, for example `in_use` and `identifier` to find the streams
// that the peer opened.
//
// Each buffer is a ring: the byte of the stream at an offset is at the index
// offset modulo `STREAM_BUFFER_SIZE`. Flow control keeps the bytes that are in
// use within one turn of the ring.
Stream :: struct {
	using state: Stream_State, // The state of the stream. With `using`, its fields are read as fields of the record: `stream.identifier`.
	send:        [STREAM_BUFFER_SIZE]u8, // The ring of the bytes that this side sends: from the first byte not acknowledged to the last byte written.
	receive:     [STREAM_BUFFER_SIZE]u8, // The ring of the bytes of the peer: from the first byte not read to the flow control limit of the stream.
}

// stream_of gives the record of an open stream, or nil.
//
// - `identifier`: the stream identifier.
//
// nil means that no open stream has the identifier: the stream was never
// opened, or it ended and its record is free. The pointer is good until the
// stream ends; a call of `stream_read` can end it.
stream_of :: proc "contextless" (connection: ^Connection, identifier: u64) -> ^Stream {
	for &stream in connection.streams {
		if stream.in_use && stream.identifier == identifier {
			return &stream
		}
	}
	return nil
}

// stream_is_of_client says if a stream identifier names a stream that the
// client opens: its lowest bit is 0 (RFC 9000, section 2.1). The next bit is 1
// for a unidirectional stream.
@(private)
stream_is_of_client :: proc "contextless" (identifier: u64) -> bool {
	return identifier & 0x01 == 0
}

// stream_record_take gives a free record to a new stream, or nil when each
// record is in use.
//
// It clears the state of the record, not its buffers, and sets the two flow
// control limits: `STREAM_BUFFER_SIZE` to receive, and to send the value that
// the peer gave in its transport parameters for a stream of this kind. That
// value is `initial_max_stream_data_bidi_local` of the peer for a stream that
// the peer opened, and `initial_max_stream_data_bidi_remote` for a stream that
// this side opened (RFC 9000, section 18.2).
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

// stream_of_frame gives the stream that a frame of the peer names, after the
// checks of its stream identifier. A stream of the peer that is not open yet
// is opened, with each lower one (RFC 9000, section 3.2).
//
// - `identifier`: the Stream ID field of the frame.
// - `frame_type`: the type of the frame, for the CONNECTION_CLOSE of a
//   failure.
//
// **Results**
//
// - A stream and `ok` true: the frame acts on it.
// - nil and `ok` true: the stream ended. The caller drops the frame.
// - nil and `ok` false: the connection closed.
//
// **What closes the connection**
//
// - A unidirectional stream: STREAM_LIMIT_ERROR for one of the peer (this side
//   allows none), STREAM_STATE_ERROR for one of this side (it opens none).
// - A stream of the peer at or past the limit of streams that this side gave,
//   and any stream of a server at a client: STREAM_LIMIT_ERROR (RFC 9000,
//   section 4.6).
// - A stream of this side that it did not open: STREAM_STATE_ERROR.
//
// The limit is checked before any record is taken, so a stream identifier far
// ahead takes only records that exist.
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

// stream_data_receive takes the data of a STREAM frame into the ring of its
// stream (RFC 9000, sections 4.1 and 4.5).
//
// - `offset`, `data`: the Offset field and the bytes of the frame.
// - `finish`: the frame has the FIN bit: its end is the final size of the
//   stream.
//
// **What closes the connection** (the result is then false)
//
// - FINAL_SIZE_ERROR: data past a final size that is known, a second final
//   size that differs, or a final size under data that came already.
// - FLOW_CONTROL_ERROR: the end of the data is past the flow control limit of
//   the stream, or its new part is past the limit of the connection
//   (`stream_received_offset_allowed`).
//
// Data that comes again is harmless: the bytes that the application read are
// skipped, and the others are written again at the same place. Data on a
// stream that the peer reset is counted and dropped. When the set of ranges
// has no place for the data, it is dropped and
// `Connection.packet_data_dropped` is set: the packet is not acknowledged, and
// the peer sends it again.
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
// reached on a stream against the flow control limit of the stream and the one
// of the connection, and counts it for the connection.
//
// - `end`: the offset after the last byte of a STREAM frame, or the final size
//   of a RESET_STREAM.
//
// Only the growth of the largest offset counts against the connection (RFC
// 9000, section 4.1): data that comes again, or that fills a gap, costs
// nothing more. Past either limit the connection closes with
// FLOW_CONTROL_ERROR, and the result is false.
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

// stream_reset_receive ends the receiving part of a stream at a RESET_STREAM
// of the peer (RFC 9000, section 19.4).
//
// - `code`: the application error code of the peer: `stream_read` then reports
//   the reset, and `Stream_State.peer_reset_code` holds the code.
// - `final_size`: the bytes that the peer sent on the stream in all. It must
//   agree with a final size that is known, and cover the data that came: else
//   FINAL_SIZE_ERROR. It is checked against flow control as data is.
//
// The bytes that the application did not read will never be read. They give
// their room back to the connection: they count as consumed, and the limit of
// the connection can move forward (MAX_DATA). A second RESET_STREAM changes
// nothing. It gives false when the frame closed the connection.
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
// STOP_SENDING of the peer: this side answers with RESET_STREAM and the same
// application error code (RFC 9000, section 3.5).
@(private)
stream_stop_sending_receive :: proc "contextless" (stream: ^Stream, code: u64) {
	stream_reset_send(stream, code)
}

// stream_reset_send ends the sending part of a stream with RESET_STREAM.
//
// The final size of a reset is the largest offset that this side sent, not the
// bytes that the application wrote (RFC 9000, section 4.5): the peer counts it
// against its flow control. Bytes that flow control held back were never
// counted by the peer, so the stream forgets them here: after this,
// `send_length` is the final size, no byte is sent again, no end of the stream
// (FIN) is sent, and `stream_write` takes no byte (it gives 0).
//
// It does nothing when a reset went already, or when every byte and the end of
// the stream were acknowledged: the sending part ended in order, and a reset
// would say otherwise.
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

// connection_receive_window_update gives the peer a new flow control limit of
// the connection (MAX_DATA) when half of the limit was used up.
//
// The limit is always the bytes that the application consumed plus
// `Connection.receive_window`. Moving it at each read would send a frame for
// each read; moving it at half of the window sends few frames and never lets
// the peer run out.
@(private)
connection_receive_window_update :: proc "contextless" (connection: ^Connection) {
	if connection.data_consumed_total + connection.receive_window - connection.receive_max_data >= connection.receive_window / 2 {
		connection.receive_max_data = connection.data_consumed_total + connection.receive_window
		connection.pending_controls += {.Max_Data}
	}
}

// stream_release_when_ended frees the record of a stream whose two directions
// ended.
//
// - **The receiving part** ended when the application read the end of the peer
//   (`end_read`).
// - **The sending part** ended when the peer acknowledged every byte and the
//   end of the stream, or acknowledged the RESET_STREAM of this side.
//
// The bytes that the stream left in its rings are erased, and the record can
// take a new stream. For a stream that the peer opened, a server adds one to
// the limit of streams and queues MAX_STREAMS: the client gets one more stream
// for the record that is free. `stream_read` and the acknowledgement of a
// packet call it, since either one can be the last event.
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

// stream_buffers_erase writes zeros over the bytes that a stream left in its
// rings, so that a later stream of the record, or a fault, never holds the
// bytes of an earlier peer.
//
// Only the part that the stream used is written: the bytes before its largest
// offset, each ring at most once. After a reset of this side, `send_length` no
// longer counts the bytes that the application wrote, so the whole send ring
// is erased.
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

// stream_open opens a new stream of a client, and gives its stream identifier.
//
// A stream costs nothing on the wire until its first byte goes: the server
// learns of it from the first STREAM frame. The identifiers go 0, 4, 8...
//
// **Result**: the identifier and `ok` true. `ok` false when:
//
// - this side is a server: only the client opens streams;
// - the connection is not in the state `Handshake` or `Connected`;
// - the limit of streams of the server is reached. The client then tells the
//   server with STREAMS_BLOCKED, and tries again after a stream ended. Before
//   the transport parameters of the server came the limit is 0, so a client
//   opens its first stream once the handshake brought them
//   (`Connection.peer_parameters_applied`);
// - no stream record is free: the table of the caller bounds the streams that
//   are open at one time.
//
// ```odin
// identifier, opened := quic.stream_open(&connection)
// if opened {
// 	quic.stream_write(&connection, identifier, request, true)
// }
// ```
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

// stream_write gives bytes of the application to a stream, and gives the count
// that it took.
//
// The bytes go into the send ring; `connection_datagram_send` then sends them,
// within the congestion window and the flow control limits of the peer. So a
// write never waits: it takes what the ring holds.
//
// - `identifier`: the stream identifier.
// - `bytes`: the bytes to send, in order after the bytes of the earlier
//   writes.
// - `finish`: these are the last bytes. The stream is marked ended only when
//   the call took every byte; a write with no byte and `finish` true ends a
//   stream with nothing more to send.
//
// **Result**: the count of bytes that the ring took, 0 to `len(bytes)`. The
// room is `STREAM_BUFFER_SIZE` less the bytes that the peer did not
// acknowledge in order. When the count is short, the caller keeps the rest and
// writes it again after the peer acknowledged some.
//
// It takes nothing, and gives 0, when the connection is not in the state
// `Handshake` or `Connected`, when no open stream has the identifier, after a
// write with `finish`, and after a reset of this side.
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

// stream_read gives the application the bytes of the peer on a stream that
// came in order, and reports the end of the stream.
//
// - `identifier`: the stream identifier.
// - `buffer`: where the bytes go.
//
// **Results**
//
// - `count`: the bytes written in `buffer`. 0 when the next byte did not come
//   yet, also when later bytes wait behind a gap.
// - `finished`: the peer sent its last byte and this call, or an earlier one,
//   read it. It can be true with a `count` above 0.
// - `reset`: the peer reset the stream: it gives no more bytes, and the bytes
//   that were not read are dropped. `Stream_State.peer_reset_code` holds the
//   code.
//
// A stream that is not open (it never was, or it ended) gives 0, false, false.
//
// A read gives room back to the peer: when half of a flow control limit was
// read, the stream queues MAX_STREAM_DATA and the connection MAX_DATA. The
// caller therefore calls `connection_datagram_send` after its reads.
//
// **A program reads each stream to its end.** A record is freed only when the
// application read the end of the peer here (`finished` or `reset` true), and
// the last byte of this side or its reset was acknowledged. A program that
// never reads a stream to its end keeps the record for the life of the
// connection, and a server then gives the client no stream in its place: a
// program reads each stream to its end, or resets it and reads the reset of
// the peer. Once the stream ended, a read of it gives nothing.
//
// ```odin
// count, finished, reset := quic.stream_read(&connection, identifier, buffer[:])
// ```
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
// error code of the application: the bytes not yet acknowledged are not sent
// again.
//
// - `identifier`: the stream identifier. A stream that is not open is left
//   alone.
// - `code`: the application error code that the peer gets.
//
// Use it to give up a stream: the peer learns that the data is not whole. The
// receiving part is not touched: the application still reads the peer to its
// end, or asks it to stop with `stream_stop_sending`. It does nothing when the
// stream was reset before, or when the peer acknowledged every byte and the
// end of the stream.
stream_reset :: proc "contextless" (connection: ^Connection, identifier: u64, code: u64) {
	if stream := stream_of(connection, identifier); stream != nil {
		stream_reset_send(stream, code)
	}
}

// stream_stop_sending asks the peer to end its sending part of a stream
// (STOP_SENDING, with an error code of the application). The peer answers with
// RESET_STREAM.
//
// - `identifier`: the stream identifier. A stream that is not open is left
//   alone.
// - `code`: the application error code that the peer gets.
//
// The application then reads the stream until `stream_read` reports the reset:
// only that read ends the receiving part. It does nothing when it was asked
// before, or when the peer gave the end of its stream already.
stream_stop_sending :: proc "contextless" (connection: ^Connection, identifier: u64, code: u64) {
	stream := stream_of(connection, identifier)
	if stream == nil || stream.stop_sending_sent || stream.has_final_size {
		return
	}
	stream.stop_sending_sent = true
	stream.stop_sending_code = code
	stream.pending_controls += {.Stop_Sending}
}

// ring_write copies bytes into the ring of a stream from an offset of the
// stream: the byte at an offset is at the index offset modulo the size of the
// ring, and a copy that reaches the end of the ring goes on at its start. The
// caller gives no more bytes than the ring has.
@(private)
ring_write :: proc "contextless" (ring: []u8, offset: u64, bytes: []u8) {
	start := int(offset % u64(len(ring)))
	first := copy(ring[start:], bytes)
	copy(ring, bytes[first:])
}

// ring_read copies bytes out of the ring of a stream from an offset of the
// stream, into `bytes`: the reverse of `ring_write`. It fills the whole of
// `bytes`, which is no longer than the ring.
@(private)
ring_read :: proc "contextless" (ring: []u8, offset: u64, bytes: []u8) {
	start := int(offset % u64(len(ring)))
	first := copy(bytes, ring[start:])
	copy(bytes[first:], ring)
}
