package quic

// The frames of QUIC version 1 (RFC 9000, section 19), and the error codes
// of a connection (RFC 9000, section 20.1). The reading of each frame is in
// connection_receive.odin; this file holds the numbers and the writing.

FRAME_PADDING :: 0x00
FRAME_PING :: 0x01
FRAME_ACK :: 0x02
FRAME_ACK_WITH_ECN :: 0x03
FRAME_RESET_STREAM :: 0x04
FRAME_STOP_SENDING :: 0x05
FRAME_CRYPTO :: 0x06
FRAME_NEW_TOKEN :: 0x07
FRAME_STREAM :: 0x08 // To 0x0f: the low 3 bits are the flags below.
FRAME_STREAM_FLAG_OFFSET :: 0x04
FRAME_STREAM_FLAG_LENGTH :: 0x02
FRAME_STREAM_FLAG_FINISH :: 0x01
FRAME_MAX_DATA :: 0x10
FRAME_MAX_STREAM_DATA :: 0x11
FRAME_MAX_STREAMS_BIDIRECTIONAL :: 0x12
FRAME_MAX_STREAMS_UNIDIRECTIONAL :: 0x13
FRAME_DATA_BLOCKED :: 0x14
FRAME_STREAM_DATA_BLOCKED :: 0x15
FRAME_STREAMS_BLOCKED_BIDIRECTIONAL :: 0x16
FRAME_STREAMS_BLOCKED_UNIDIRECTIONAL :: 0x17
FRAME_NEW_CONNECTION_ID :: 0x18
FRAME_RETIRE_CONNECTION_ID :: 0x19
FRAME_PATH_CHALLENGE :: 0x1a
FRAME_PATH_RESPONSE :: 0x1b
FRAME_CONNECTION_CLOSE :: 0x1c // An error of QUIC, or of TLS.
FRAME_CONNECTION_CLOSE_APPLICATION :: 0x1d // An error of the application: 1-RTT packets only.
FRAME_HANDSHAKE_DONE :: 0x1e

STREAMS_LIMIT :: u64(1) << 60 // RFC 9000, section 19.11: a count of streams over this is an encoding error.
STATELESS_RESET_TOKEN_SIZE :: 16
PATH_DATA_SIZE :: 8

// The error code of a CONNECTION_CLOSE of QUIC (RFC 9000, section 20.1). A
// failure of TLS is CRYPTO_ERROR_BASE + its alert.
Transport_Error :: enum u64 {
	No_Error                  = 0x00,
	Internal_Error            = 0x01,
	Connection_Refused        = 0x02,
	Flow_Control_Error        = 0x03,
	Stream_Limit_Error        = 0x04,
	Stream_State_Error        = 0x05,
	Final_Size_Error          = 0x06,
	Frame_Encoding_Error      = 0x07,
	Transport_Parameter_Error = 0x08,
	Connection_Id_Limit_Error = 0x09,
	Protocol_Violation        = 0x0a,
	Invalid_Token             = 0x0b,
	Application_Error         = 0x0c,
	Crypto_Buffer_Exceeded    = 0x0d,
	Key_Update_Error          = 0x0e,
	Aead_Limit_Reached        = 0x0f,
	No_Viable_Path            = 0x10,
}
CRYPTO_ERROR_BASE :: 0x0100

// A writer of frames into the payload of one packet: each write checks the
// room first, and a write with no room sets failed and writes nothing.
Frame_Writer :: struct {
	bytes:    []u8,
	position: int,
	failed:   bool,
}

frame_write_integer :: proc "contextless" (writer: ^Frame_Writer, value: u64) {
	size := variable_length_integer_size(value)
	if writer.failed || size == 0 || size > len(writer.bytes) - writer.position {
		writer.failed = true
		return
	}
	writer.position += variable_length_integer_write(writer.bytes, writer.position, value, size)
}

frame_write_bytes :: proc "contextless" (writer: ^Frame_Writer, bytes: []u8) {
	if writer.failed || len(bytes) > len(writer.bytes) - writer.position {
		writer.failed = true
		return
	}
	writer.position += copy(writer.bytes[writer.position:], bytes)
}

frame_room :: proc "contextless" (writer: ^Frame_Writer) -> int {
	return writer.failed ? 0 : len(writer.bytes) - writer.position
}

// frame_type_is_allowed says if a frame type may come at a level (RFC 9000,
// section 12.4, table 3): Initial and Handshake packets carry PADDING, PING,
// ACK, CRYPTO and the CONNECTION_CLOSE of QUIC only.
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
