package quic

// The transport parameters of QUIC version 1 (RFC 9000, section 18): what
// each side tells the other in the quic_transport_parameters extension of
// TLS. The bytes of the peer are hostile input: each parameter is checked
// for its form and its value, and a failure is TRANSPORT_PARAMETER_ERROR.

PARAMETER_ORIGINAL_DESTINATION_CONNECTION_ID :: 0x00
PARAMETER_MAX_IDLE_TIMEOUT :: 0x01
PARAMETER_STATELESS_RESET_TOKEN :: 0x02
PARAMETER_MAX_UDP_PAYLOAD_SIZE :: 0x03
PARAMETER_INITIAL_MAX_DATA :: 0x04
PARAMETER_INITIAL_MAX_STREAM_DATA_BIDIRECTIONAL_LOCAL :: 0x05
PARAMETER_INITIAL_MAX_STREAM_DATA_BIDIRECTIONAL_REMOTE :: 0x06
PARAMETER_INITIAL_MAX_STREAM_DATA_UNIDIRECTIONAL :: 0x07
PARAMETER_INITIAL_MAX_STREAMS_BIDIRECTIONAL :: 0x08
PARAMETER_INITIAL_MAX_STREAMS_UNIDIRECTIONAL :: 0x09
PARAMETER_ACK_DELAY_EXPONENT :: 0x0a
PARAMETER_MAX_ACK_DELAY :: 0x0b
PARAMETER_DISABLE_ACTIVE_MIGRATION :: 0x0c
PARAMETER_PREFERRED_ADDRESS :: 0x0d
PARAMETER_ACTIVE_CONNECTION_ID_LIMIT :: 0x0e
PARAMETER_INITIAL_SOURCE_CONNECTION_ID :: 0x0f
PARAMETER_RETRY_SOURCE_CONNECTION_ID :: 0x10

SMALLEST_MAX_UDP_PAYLOAD_SIZE :: 1200 // RFC 9000, section 18.2: less is invalid.
ACK_DELAY_EXPONENT_LARGEST :: 20
MAX_ACK_DELAY_LIMIT :: 1 << 14 // Milliseconds: this value and more are invalid.

Transport_Parameters :: struct {
	original_destination_connection_id:        [CONNECTION_ID_LIMIT]u8, // A server only: the Destination Connection ID of the first Initial of the client.
	original_destination_connection_id_length: int,
	has_original_destination_connection_id:    bool,
	initial_source_connection_id:              [CONNECTION_ID_LIMIT]u8, // The Source Connection ID of the first packet of the side.
	initial_source_connection_id_length:       int,
	has_initial_source_connection_id:          bool,
	max_idle_timeout:                          u64, // Milliseconds; 0: no idle timeout from this side.
	max_udp_payload_size:                      u64,
	initial_max_data:                          u64,
	initial_max_stream_data_bidirectional_local: u64, // For the bidirectional streams that the side of the parameters opens.
	initial_max_stream_data_bidirectional_remote: u64, // For the bidirectional streams that the other side opens.
	initial_max_stream_data_unidirectional:    u64,
	initial_max_streams_bidirectional:         u64,
	initial_max_streams_unidirectional:        u64,
	ack_delay_exponent:                        u64,
	max_ack_delay:                             u64, // Milliseconds.
	active_connection_id_limit:                u64,
	disable_active_migration:                  bool,
	retry_source_connection_id:                [CONNECTION_ID_LIMIT]u8, // A server after a Retry: the Source Connection ID of its Retry.
	retry_source_connection_id_length:         int,
	has_retry_source_connection_id:            bool,
}

// transport_parameters_default gives the values that RFC 9000, section 18.2,
// gives to a parameter that does not come.
transport_parameters_default :: proc "contextless" () -> Transport_Parameters {
	return {max_udp_payload_size = 65527, ack_delay_exponent = 3, max_ack_delay = 25, active_connection_id_limit = 2}
}

// transport_parameters_write encodes the parameters of one side. Each value
// that equals its default is not written, except the connection
// identifiers. It gives the count of bytes, or 0 when the buffer is too small.
transport_parameters_write :: proc "contextless" (parameters: ^Transport_Parameters, role: Tls_Role, buffer: []u8) -> int {
	writer := Frame_Writer{bytes = buffer}
	integer :: proc "contextless" (writer: ^Frame_Writer, identifier: u64, value: u64) {
		frame_write_integer(writer, identifier)
		frame_write_integer(writer, u64(variable_length_integer_size(value)))
		frame_write_integer(writer, value)
	}
	bytes :: proc "contextless" (writer: ^Frame_Writer, identifier: u64, value: []u8) {
		frame_write_integer(writer, identifier)
		frame_write_integer(writer, u64(len(value)))
		frame_write_bytes(writer, value)
	}
	if role == .Server && parameters.has_original_destination_connection_id {
		bytes(&writer, PARAMETER_ORIGINAL_DESTINATION_CONNECTION_ID, parameters.original_destination_connection_id[:parameters.original_destination_connection_id_length])
	}
	if parameters.max_idle_timeout != 0 {
		integer(&writer, PARAMETER_MAX_IDLE_TIMEOUT, parameters.max_idle_timeout)
	}
	if parameters.max_udp_payload_size != 65527 {
		integer(&writer, PARAMETER_MAX_UDP_PAYLOAD_SIZE, parameters.max_udp_payload_size)
	}
	integer(&writer, PARAMETER_INITIAL_MAX_DATA, parameters.initial_max_data)
	integer(&writer, PARAMETER_INITIAL_MAX_STREAM_DATA_BIDIRECTIONAL_LOCAL, parameters.initial_max_stream_data_bidirectional_local)
	integer(&writer, PARAMETER_INITIAL_MAX_STREAM_DATA_BIDIRECTIONAL_REMOTE, parameters.initial_max_stream_data_bidirectional_remote)
	integer(&writer, PARAMETER_INITIAL_MAX_STREAMS_BIDIRECTIONAL, parameters.initial_max_streams_bidirectional)
	bytes(&writer, PARAMETER_INITIAL_SOURCE_CONNECTION_ID, parameters.initial_source_connection_id[:parameters.initial_source_connection_id_length])
	if parameters.disable_active_migration {
		bytes(&writer, PARAMETER_DISABLE_ACTIVE_MIGRATION, nil)
	}
	if role == .Server && parameters.has_retry_source_connection_id {
		bytes(&writer, PARAMETER_RETRY_SOURCE_CONNECTION_ID, parameters.retry_source_connection_id[:parameters.retry_source_connection_id_length])
	}
	if writer.failed {
		return 0
	}
	return writer.position
}

// transport_parameters_read decodes the parameters that the peer sent.
// sender is the role of the peer. It gives No_Error, or
// Transport_Parameter_Error for any parameter that is malformed, repeated,
// out of its range, or that the role of the sender may not send. A
// parameter that this library does not know is skipped (RFC 9000, section
// 7.4.2).
transport_parameters_read :: proc "contextless" (bytes: []u8, sender: Tls_Role, parameters: ^Transport_Parameters) -> Transport_Error {
	parameters^ = transport_parameters_default()
	seen: bit_set[0 ..= PARAMETER_RETRY_SOURCE_CONNECTION_ID]
	position := 0
	for position < len(bytes) {
		identifier, identifier_size, identifier_ok := variable_length_integer_read(bytes, position)
		if !identifier_ok {
			return .Transport_Parameter_Error
		}
		position += identifier_size
		length, length_size, length_ok := variable_length_integer_read(bytes, position)
		if !length_ok {
			return .Transport_Parameter_Error
		}
		position += length_size
		if length > u64(len(bytes) - position) {
			return .Transport_Parameter_Error
		}
		value := bytes[position:][:int(length)]
		position += int(length)
		if identifier > PARAMETER_RETRY_SOURCE_CONNECTION_ID {
			continue
		}
		if int(identifier) in seen {
			return .Transport_Parameter_Error
		}
		seen += {int(identifier)}
		// The parameters that only a server sends (RFC 9000, section 18.2).
		switch identifier {
		case PARAMETER_ORIGINAL_DESTINATION_CONNECTION_ID, PARAMETER_STATELESS_RESET_TOKEN, PARAMETER_PREFERRED_ADDRESS, PARAMETER_RETRY_SOURCE_CONNECTION_ID:
			if sender != .Server {
				return .Transport_Parameter_Error
			}
		}
		switch identifier {
		case PARAMETER_ORIGINAL_DESTINATION_CONNECTION_ID:
			if len(value) > CONNECTION_ID_LIMIT {
				return .Transport_Parameter_Error
			}
			parameters.original_destination_connection_id_length = copy(parameters.original_destination_connection_id[:], value)
			parameters.has_original_destination_connection_id = true
		case PARAMETER_INITIAL_SOURCE_CONNECTION_ID:
			if len(value) > CONNECTION_ID_LIMIT {
				return .Transport_Parameter_Error
			}
			parameters.initial_source_connection_id_length = copy(parameters.initial_source_connection_id[:], value)
			parameters.has_initial_source_connection_id = true
		case PARAMETER_RETRY_SOURCE_CONNECTION_ID:
			if len(value) > CONNECTION_ID_LIMIT {
				return .Transport_Parameter_Error
			}
			parameters.retry_source_connection_id_length = copy(parameters.retry_source_connection_id[:], value)
			parameters.has_retry_source_connection_id = true
		case PARAMETER_STATELESS_RESET_TOKEN:
			if len(value) != STATELESS_RESET_TOKEN_SIZE {
				return .Transport_Parameter_Error
			}
		case PARAMETER_DISABLE_ACTIVE_MIGRATION:
			if len(value) != 0 {
				return .Transport_Parameter_Error
			}
			parameters.disable_active_migration = true
		case PARAMETER_PREFERRED_ADDRESS:
		// Not used: this library does not migrate. Its form is the
		// server's concern.
		case:
			// An integer: a variable-length integer that fills the value.
			number, size, ok := variable_length_integer_read(value, 0)
			if !ok || size != len(value) {
				return .Transport_Parameter_Error
			}
			switch identifier {
			case PARAMETER_MAX_IDLE_TIMEOUT:
				parameters.max_idle_timeout = number
			case PARAMETER_MAX_UDP_PAYLOAD_SIZE:
				if number < SMALLEST_MAX_UDP_PAYLOAD_SIZE {
					return .Transport_Parameter_Error
				}
				parameters.max_udp_payload_size = number
			case PARAMETER_INITIAL_MAX_DATA:
				parameters.initial_max_data = number
			case PARAMETER_INITIAL_MAX_STREAM_DATA_BIDIRECTIONAL_LOCAL:
				parameters.initial_max_stream_data_bidirectional_local = number
			case PARAMETER_INITIAL_MAX_STREAM_DATA_BIDIRECTIONAL_REMOTE:
				parameters.initial_max_stream_data_bidirectional_remote = number
			case PARAMETER_INITIAL_MAX_STREAM_DATA_UNIDIRECTIONAL:
				parameters.initial_max_stream_data_unidirectional = number
			case PARAMETER_INITIAL_MAX_STREAMS_BIDIRECTIONAL, PARAMETER_INITIAL_MAX_STREAMS_UNIDIRECTIONAL:
				if number > STREAMS_LIMIT {
					return .Transport_Parameter_Error
				}
				if identifier == PARAMETER_INITIAL_MAX_STREAMS_BIDIRECTIONAL {
					parameters.initial_max_streams_bidirectional = number
				} else {
					parameters.initial_max_streams_unidirectional = number
				}
			case PARAMETER_ACK_DELAY_EXPONENT:
				if number > ACK_DELAY_EXPONENT_LARGEST {
					return .Transport_Parameter_Error
				}
				parameters.ack_delay_exponent = number
			case PARAMETER_MAX_ACK_DELAY:
				if number >= MAX_ACK_DELAY_LIMIT {
					return .Transport_Parameter_Error
				}
				parameters.max_ack_delay = number
			case PARAMETER_ACTIVE_CONNECTION_ID_LIMIT:
				if number < 2 {
					return .Transport_Parameter_Error
				}
				parameters.active_connection_id_limit = number
			}
		}
	}
	// Each side gives the identifier of its first packet; a server gives the
	// identifier that the client chose (RFC 9000, section 7.3).
	if !parameters.has_initial_source_connection_id || (sender == .Server && !parameters.has_original_destination_connection_id) {
		return .Transport_Parameter_Error
	}
	return .No_Error
}
