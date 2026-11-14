package quic

// The frames of QUIC version 1 (RFC 9000, section 19), and the error codes
// of a connection (RFC 9000, section 20.1). The reading of each frame is in
// connection_receive.odin; this file holds the numbers and the writing.

// PADDING: one byte 0 with no meaning, which only makes a packet longer (RFC 9000, section 19.1).
//
// This constant and the ones below are the frame types of QUIC version 1, by their names in RFC
// 9000, section 19 (the table of the types is in section 12.4). A frame starts with its type as a
// variable-length integer, then its fields. What the transport does with each frame is in the guide
// (docs/QUIC.md, "The frames").
//
// A sender uses PADDING to bring a datagram with an [Initial packet](term:initial-packet) to 1200
// bytes, and to give a short packet the 4 bytes that the sample of header protection needs
// (`packet_seal`). A packet with only PADDING is not ack-eliciting.
FRAME_PADDING :: 0x00
FRAME_PING :: 0x01 // PING: no field; it only makes the peer acknowledge the packet (RFC 9000, section 19.2). A probe with no data to send again carries one.
FRAME_ACK :: 0x02 // ACK: the packet numbers that the sender received, as ranges, and the delay of the acknowledgment (RFC 9000, section 19.3).
FRAME_ACK_WITH_ECN :: 0x03 // ACK with the three ECN counts after the ranges (RFC 9000, section 19.3.2). This library reads the counts and does not use them.
FRAME_RESET_STREAM :: 0x04 // RESET_STREAM: the sender ends its direction of a stream at once, with an error code of the application and the final size (RFC 9000, section 19.4).
FRAME_STOP_SENDING :: 0x05 // STOP_SENDING: the sender asks the peer to send no more on a stream, with an error code of the application (RFC 9000, section 19.5).
FRAME_CRYPTO :: 0x06 // CRYPTO: an offset, a length and bytes of the TLS handshake at the encryption level of its packet (RFC 9000, section 19.6). `tls_receive` takes these bytes in order.
FRAME_NEW_TOKEN :: 0x07 // NEW_TOKEN: a token that a server gives a client for a later connection (RFC 9000, section 19.7). It is not the token of a Retry; a client of this library keeps none.

// STREAM: bytes of one stream (RFC 9000, section 19.8). The types 0x08 to 0x0f are all STREAM.
//
// The three low bits of the type are flags, which say which fields the frame has:
// `FRAME_STREAM_FLAG_OFFSET`, `FRAME_STREAM_FLAG_LENGTH` and `FRAME_STREAM_FLAG_FINISH`. A reader
// tests `type & ~0x07 == FRAME_STREAM`, then each flag.
FRAME_STREAM :: 0x08
FRAME_STREAM_FLAG_OFFSET :: 0x04 // The OFF bit of a STREAM type: the frame has an Offset field. Without it the bytes start at offset 0 of the stream.
FRAME_STREAM_FLAG_LENGTH :: 0x02 // The LEN bit of a STREAM type: the frame has a Length field. Without it the bytes run to the end of the packet.
FRAME_STREAM_FLAG_FINISH :: 0x01 // The FIN bit of a STREAM type: the last byte of the frame is the last byte of the stream. The offset after it is the final size.
FRAME_MAX_DATA :: 0x10 // MAX_DATA: the new limit of the bytes that the peer can send on all the streams of the connection (RFC 9000, section 19.9).
FRAME_MAX_STREAM_DATA :: 0x11 // MAX_STREAM_DATA: the new limit of the bytes that the peer can send on one stream (RFC 9000, section 19.10).
FRAME_MAX_STREAMS_BIDIRECTIONAL :: 0x12 // MAX_STREAMS for bidirectional streams: the new count of streams that the peer can open (RFC 9000, section 19.11). A count over `STREAMS_LIMIT` is an encoding error.
FRAME_MAX_STREAMS_UNIDIRECTIONAL :: 0x13 // MAX_STREAMS for unidirectional streams (RFC 9000, section 19.11). This library allows no unidirectional stream.
FRAME_DATA_BLOCKED :: 0x14 // DATA_BLOCKED: the sender has bytes to send and the limit of the connection stops it (RFC 9000, section 19.12). It carries that limit.
FRAME_STREAM_DATA_BLOCKED :: 0x15 // STREAM_DATA_BLOCKED: the sender has bytes to send and the limit of one stream stops it (RFC 9000, section 19.13).
FRAME_STREAMS_BLOCKED_BIDIRECTIONAL :: 0x16 // STREAMS_BLOCKED for bidirectional streams: the sender wants to open a stream and the limit of streams stops it (RFC 9000, section 19.14).
FRAME_STREAMS_BLOCKED_UNIDIRECTIONAL :: 0x17 // STREAMS_BLOCKED for unidirectional streams (RFC 9000, section 19.14).
FRAME_NEW_CONNECTION_ID :: 0x18 // NEW_CONNECTION_ID: one more connection identifier that the peer can use for the sender, with its stateless reset token (RFC 9000, section 19.15).
FRAME_RETIRE_CONNECTION_ID :: 0x19 // RETIRE_CONNECTION_ID: the sender no longer uses one connection identifier that the peer gave it (RFC 9000, section 19.16).
FRAME_PATH_CHALLENGE :: 0x1a // PATH_CHALLENGE: `PATH_DATA_SIZE` bytes that the peer must send back, to prove that it receives on this path (RFC 9000, section 19.17).
FRAME_PATH_RESPONSE :: 0x1b // PATH_RESPONSE: the bytes of a PATH_CHALLENGE, sent back (RFC 9000, section 19.18).
FRAME_CONNECTION_CLOSE :: 0x1c // CONNECTION_CLOSE with a `Transport_Error`, or with `CRYPTO_ERROR_BASE` + an alert of TLS, and the type of the frame that caused it (RFC 9000, section 19.19). It can go at each encryption level.
FRAME_CONNECTION_CLOSE_APPLICATION :: 0x1d // CONNECTION_CLOSE with an error code of the application (RFC 9000, section 19.19). It goes in 1-RTT packets only: before them a close of the application is sent as `FRAME_CONNECTION_CLOSE` with `Application_Error`.
FRAME_HANDSHAKE_DONE :: 0x1e // HANDSHAKE_DONE: no field; a server tells the client that the handshake is confirmed (RFC 9000, section 19.20). Only a server sends it.

// The largest count of streams that a MAX_STREAMS frame or a transport parameter can name: 2^60.
//
// A stream identifier is a variable-length integer, and its two low bits say who opened the stream
// and whether it is bidirectional. So 2^60 streams of one kind are all that 62 bits can name (RFC
// 9000, section 19.11). A larger count in a frame is `Frame_Encoding_Error`; in a transport
// parameter, `transport_parameters_read` gives `Transport_Parameter_Error`.
STREAMS_LIMIT :: u64(1) << 60

// The bytes of a stateless reset token: 16 (RFC 9000, section 10.3).
//
// The token comes in the transport parameter `stateless_reset_token` and in each NEW_CONNECTION_ID
// frame. This library checks its size and keeps no token: it sends no
// [stateless reset](term:stateless-reset) and detects none.
STATELESS_RESET_TOKEN_SIZE :: 16

// The bytes of the data of a PATH_CHALLENGE and of a PATH_RESPONSE frame: 8 (RFC 9000, section 19.17).
PATH_DATA_SIZE :: 8

// The error code of a CONNECTION_CLOSE frame of QUIC (RFC 9000, section 20.1).
//
// A side that finds a fault in what the peer sent closes the connection with one of these codes: the
// code tells the peer which rule it broke. The names are those of the RFC, in the case of this
// project: `Protocol_Violation` is PROTOCOL_VIOLATION.
//
// A failure of TLS has no member here: its code is `CRYPTO_ERROR_BASE` + the [alert](term:alert),
// for example 0x012a for bad_certificate. The procedures of this library that read the bytes of the
// peer give a member as their result (`transport_parameters_read`), with `No_Error` for bytes that
// are right.
//
// These codes are not the error codes of an application, which go in RESET_STREAM, STOP_SENDING and
// `FRAME_CONNECTION_CLOSE_APPLICATION`, and whose meaning the application chooses.
Transport_Error :: enum u64 {
	No_Error                  = 0x00, // NO_ERROR: the connection closes with no fault. Also the result of a read that found none.
	Internal_Error            = 0x01, // INTERNAL_ERROR: the side that closes failed by itself, and the peer did nothing wrong.
	Connection_Refused        = 0x02, // CONNECTION_REFUSED: a server takes no new connection.
	Flow_Control_Error        = 0x03, // FLOW_CONTROL_ERROR: the peer sent more bytes than a limit of flow control allowed, on a stream or on the connection.
	Stream_Limit_Error        = 0x04, // STREAM_LIMIT_ERROR: a frame names a stream past the limit of streams that this side gave.
	Stream_State_Error        = 0x05, // STREAM_STATE_ERROR: a frame names a stream in a state that does not allow that frame, for example a stream of this side that it did not open.
	Final_Size_Error          = 0x06, // FINAL_SIZE_ERROR: the final size of a stream changed, or is under the bytes that already came.
	Frame_Encoding_Error      = 0x07, // FRAME_ENCODING_ERROR: a frame is malformed: it is cut, a length passes the packet, or its type does not exist.
	Transport_Parameter_Error = 0x08, // TRANSPORT_PARAMETER_ERROR: a transport parameter is malformed, repeated, out of its range, absent when it is required, or not allowed for its sender (`transport_parameters_read`).
	Connection_Id_Limit_Error = 0x09, // CONNECTION_ID_LIMIT_ERROR: the peer gave more connection identifiers than the `active_connection_id_limit` of this side.
	Protocol_Violation        = 0x0a, // PROTOCOL_VIOLATION: a fault of the protocol that no other code names: a frame at a level where it cannot go, reserved bits that are not 0, handshake bytes at a level that the side left.
	Invalid_Token             = 0x0b, // INVALID_TOKEN: a server received an Initial packet with a token that it does not accept.
	Application_Error         = 0x0c, // APPLICATION_ERROR: the application closes before the 1-RTT keys; the code of the application cannot go in an Initial or a Handshake packet.
	Crypto_Buffer_Exceeded    = 0x0d, // CRYPTO_BUFFER_EXCEEDED: the peer sent more handshake bytes at one level than this side buffers (`CRYPTO_BUFFER_SIZE`).
	Key_Update_Error          = 0x0e, // KEY_UPDATE_ERROR: a fault in a key update.
	Aead_Limit_Reached        = 0x0f, // AEAD_LIMIT_REACHED: the keys protected, or failed to open, as many packets as their AEAD allows.
	No_Viable_Path            = 0x10, // NO_VIABLE_PATH: no network path carries the connection. This library does not migrate and does not send it.
}

// The first error code of a failure of TLS: the code of an alert n is `CRYPTO_ERROR_BASE` + n.
//
// QUIC has no alert message. A handshake that fails closes the connection with a CONNECTION_CLOSE
// whose code is in the range 0x0100 to 0x01ff (RFC 9000, section 20.1; RFC 9001, section 4.8). The
// alert is `Tls_Handshake.alert`: bad_certificate (42) goes as 0x012a.
CRYPTO_ERROR_BASE :: 0x0100

// A writer of frames into the payload of one packet, which never writes past its buffer.
//
// The sender of a packet makes one writer over the room of the payload, then writes each frame field
// by field with `frame_write_integer` and `frame_write_bytes`. Each write checks the room first. A
// write with no room writes nothing and sets `failed`, and each later write does nothing. So the
// caller checks `failed` once, after the last field, and not after each one. A zero record with
// `bytes` set is ready.
//
// The transport parameters use the same writer (`transport_parameters_write`): their encoding is
// made of the same integers and bytes.
//
// ```odin
// writer := Frame_Writer{bytes = payload}
// frame_write_integer(&writer, FRAME_MAX_DATA)
// frame_write_integer(&writer, limit)
// if writer.failed {
// 	// The packet has no room for this frame.
// }
// ```
Frame_Writer :: struct {
	bytes:    []u8, // The room of the payload. The writer never changes this slice.
	position: int, // The bytes written so far: the next write starts there, and at the end it is the length of the payload.
	failed:   bool, // A write had no room, or a value had no encoding: the payload is not whole, and the caller must not send it.
}

// frame_write_integer writes a variable-length integer in its shortest encoding.
//
// **Parameters**
//
// - `writer`: the writer of the payload.
// - `value`: the integer, up to `VARIABLE_LENGTH_INTEGER_LARGEST`.
//
// It sets `writer.failed` and writes nothing when the writer failed before, when the value is over
// 2^62 - 1, or when the room is less than the size of the value (`variable_length_integer_size`).
frame_write_integer :: proc "contextless" (writer: ^Frame_Writer, value: u64) {
	size := variable_length_integer_size(value)
	if writer.failed || size == 0 || size > len(writer.bytes) - writer.position {
		writer.failed = true
		return
	}
	writer.position += variable_length_integer_write(writer.bytes, writer.position, value, size)
}

// frame_write_bytes writes bytes as they are, with no length before them.
//
// The caller writes the length first, with `frame_write_integer`, when the frame has one.
//
// **Parameters**
//
// - `writer`: the writer of the payload.
// - `bytes`: the bytes to copy. No byte is a valid count: the writer stays as it is.
//
// It sets `writer.failed` and writes nothing when the writer failed before, or when the room is less
// than the bytes: a part of the bytes is never written.
frame_write_bytes :: proc "contextless" (writer: ^Frame_Writer, bytes: []u8) {
	if writer.failed || len(bytes) > len(writer.bytes) - writer.position {
		writer.failed = true
		return
	}
	writer.position += copy(writer.bytes[writer.position:], bytes)
}

// frame_room gives the bytes that the payload has left, and 0 after a failed write.
//
// A sender asks it before a frame whose size it can choose: the bytes of a STREAM or a CRYPTO frame
// are cut to the room that is left after the type, the offset and the length.
frame_room :: proc "contextless" (writer: ^Frame_Writer) -> int {
	return writer.failed ? 0 : len(writer.bytes) - writer.position
}

// frame_type_is_allowed says if a frame type can come in a packet of an encryption level.
//
// Initial and Handshake packets carry only PADDING, PING, ACK (with or without ECN counts), CRYPTO
// and the CONNECTION_CLOSE of QUIC (RFC 9000, section 12.4). A peer that sends another frame there
// breaks the protocol: the reader of the frames closes with `Protocol_Violation`.
//
// **Parameters**
//
// - `type`: the frame type, as the reader decoded it.
// - `level`: the [encryption level](term:encryption-level) of the packet.
//
// **Result**: true when the type can come at the level. At the `Application` level each type is
// allowed, so the result is true for a type that does not exist too: the reader of the frames
// refuses an unknown type by itself. The rules that depend on the role (only a server sends
// HANDSHAKE_DONE and NEW_TOKEN) are not here.
frame_type_is_allowed :: proc "contextless" (type: u64, level: Encryption_Level) -> bool {
	if level == .Application {
		return true
	}
	switch type {
	case FRAME_PADDING, FRAME_PING, FRAME_ACK, FRAME_ACK_WITH_ECN, FRAME_CRYPTO, FRAME_CONNECTION_CLOSE:
		return true
	}
	return false
}
