package quic

// The transport parameters of QUIC version 1 (RFC 9000, section 18): what
// each side tells the other in the quic_transport_parameters extension of
// TLS. The bytes of the peer are hostile input: each parameter is checked
// for its form and its value, and a failure is TRANSPORT_PARAMETER_ERROR.

// The identifier of the transport parameter `original_destination_connection_id`: the Destination Connection ID of the first Initial packet of the client.
//
// This constant and the ones below are the identifiers of the transport parameters of QUIC version
// 1 (RFC 9000, section 18.2), by their names there. In the encoding each parameter is its
// identifier, a length and its value (RFC 9000, section 18). `Transport_Parameters` holds the
// values, `transport_parameters_write` writes them and `transport_parameters_read` reads them.
//
// Only a server sends this one. The client compares it with the identifier that it chose, so that an
// attacker who changed the first packet is found (RFC 9000, section 7.3).
PARAMETER_ORIGINAL_DESTINATION_CONNECTION_ID :: 0x00
PARAMETER_MAX_IDLE_TIMEOUT :: 0x01 // `max_idle_timeout`: the idle timeout of the sender, in milliseconds; 0 or absent means none.
PARAMETER_STATELESS_RESET_TOKEN :: 0x02 // `stateless_reset_token`: 16 bytes, from a server only. This library checks its size and does not keep it.
PARAMETER_MAX_UDP_PAYLOAD_SIZE :: 0x03 // `max_udp_payload_size`: the largest UDP payload that the sender takes; 1200 at least, 65527 when absent.
PARAMETER_INITIAL_MAX_DATA :: 0x04 // `initial_max_data`: the first limit of the bytes of all the streams of the connection.
PARAMETER_INITIAL_MAX_STREAM_DATA_BIDIRECTIONAL_LOCAL :: 0x05 // `initial_max_stream_data_bidi_local`: the first limit of a bidirectional stream that the sender of the parameter opens.
PARAMETER_INITIAL_MAX_STREAM_DATA_BIDIRECTIONAL_REMOTE :: 0x06 // `initial_max_stream_data_bidi_remote`: the first limit of a bidirectional stream that the receiver of the parameter opens.
PARAMETER_INITIAL_MAX_STREAM_DATA_UNIDIRECTIONAL :: 0x07 // `initial_max_stream_data_uni`: the first limit of a unidirectional stream. This library reads it and never writes it.
PARAMETER_INITIAL_MAX_STREAMS_BIDIRECTIONAL :: 0x08 // `initial_max_streams_bidi`: the count of bidirectional streams that the receiver of the parameter can open; `STREAMS_LIMIT` at most.
PARAMETER_INITIAL_MAX_STREAMS_UNIDIRECTIONAL :: 0x09 // `initial_max_streams_uni`: the same count for unidirectional streams. This library reads it and never writes it: absent means 0, no such stream.
PARAMETER_ACK_DELAY_EXPONENT :: 0x0a // `ack_delay_exponent`: the power of 2 that scales the ACK Delay field of the sender; 3 when absent, `ACK_DELAY_EXPONENT_LARGEST` at most.
PARAMETER_MAX_ACK_DELAY :: 0x0b // `max_ack_delay`: the longest time, in milliseconds, for which the sender holds back an acknowledgment; 25 when absent, under `MAX_ACK_DELAY_LIMIT`.
PARAMETER_DISABLE_ACTIVE_MIGRATION :: 0x0c // `disable_active_migration`: a parameter with no value; the sender takes no packet of this connection from another address.
PARAMETER_PREFERRED_ADDRESS :: 0x0d // `preferred_address`: another address of a server, from a server only. This library checks its form and keeps nothing of it: it does not migrate.
PARAMETER_ACTIVE_CONNECTION_ID_LIMIT :: 0x0e // `active_connection_id_limit`: the count of connection identifiers of the peer that the sender stores; 2 at least, 2 when absent.
PARAMETER_INITIAL_SOURCE_CONNECTION_ID :: 0x0f // `initial_source_connection_id`: the Source Connection ID of the first Initial packet of the sender. Each side must send it.
PARAMETER_RETRY_SOURCE_CONNECTION_ID :: 0x10 // `retry_source_connection_id`: the Source Connection ID of the Retry packet of the server. A server sends it after a Retry, and only then.

// The least value of the transport parameter `max_udp_payload_size`: 1200 bytes.
//
// Each QUIC endpoint must take datagrams of 1200 bytes, the size of a datagram with an Initial
// packet of a client. A smaller value is invalid (RFC 9000, section 18.2), and
// `transport_parameters_read` gives `Transport_Parameter_Error` for it.
SMALLEST_MAX_UDP_PAYLOAD_SIZE :: 1200

// The largest value of the transport parameter `ack_delay_exponent`: 20 (RFC 9000, section 18.2).
//
// The ACK Delay field of an ACK frame counts units of 2^exponent microseconds. A larger exponent is
// invalid: `transport_parameters_read` gives `Transport_Parameter_Error`.
ACK_DELAY_EXPONENT_LARGEST :: 20

// The first invalid value of the transport parameter `max_ack_delay`: 2^14 milliseconds.
//
// A valid value is under this limit (RFC 9000, section 18.2). `transport_parameters_read` gives
// `Transport_Parameter_Error` for this value and for each larger one.
MAX_ACK_DELAY_LIMIT :: 1 << 14

// The offset, in the value of the transport parameter `preferred_address`, of the byte that holds the length of its connection identifier: 24.
//
// Before it come an IPv4 address (4 bytes) and its port (2), then an IPv6 address (16 bytes) and
// its port (2) (RFC 9000, section 18.2).
PREFERRED_ADDRESS_IDENTIFIER_LENGTH_OFFSET :: 4 + 2 + 16 + 2

// The bytes of the value of the transport parameter `preferred_address` without its connection identifier: 41.
//
// The two addresses with their ports, the byte of the length of the identifier, and the stateless
// reset token of 16 bytes after the identifier. A value has these bytes and the 1 to
// `CONNECTION_ID_LIMIT` bytes of its identifier: `transport_parameters_read` gives
// `Transport_Parameter_Error` for each other size.
PREFERRED_ADDRESS_FIXED_SIZE :: PREFERRED_ADDRESS_IDENTIFIER_LENGTH_OFFSET + 1 + STATELESS_RESET_TOKEN_SIZE

// The transport parameters of one side of a connection, as values.
//
// The [transport parameters](term:transport-parameters) are what each side tells the other inside
// the TLS handshake: its limits of flow control, its limit of streams, its timeouts and the
// connection identifiers that it used. They go in the extension `quic_transport_parameters`, so the
// handshake authenticates them. A connection holds two records: its own, which
// `transport_parameters_write` encodes for `Tls_Configuration.transport_parameters`, and the one of
// the peer, which `transport_parameters_read` decodes from
// `Tls_Handshake.peer_transport_parameters`.
//
// A zero record is not the record of an absent parameter: start from
// `transport_parameters_default`, which holds the values that RFC 9000 gives to a parameter that
// does not come.
//
// **The fields that this library never sends.** `transport_parameters_write` does not write
// `initial_max_stream_data_unidirectional`, `initial_max_streams_unidirectional`,
// `ack_delay_exponent`, `max_ack_delay` and `active_connection_id_limit`, whatever their values:
// the peer then uses the defaults of the RFC. These fields have a meaning in a record that
// `transport_parameters_read` filled.
Transport_Parameters :: struct {
	original_destination_connection_id:        [CONNECTION_ID_LIMIT]u8, // A server only: the Destination Connection ID of the first Initial packet of the client, before any Retry.
	original_destination_connection_id_length: int, // The bytes of that identifier: 0 to `CONNECTION_ID_LIMIT`.
	has_original_destination_connection_id:    bool, // The parameter is there. A write of a server sends it only when this is true; a read sets it, and refuses a server without it.
	initial_source_connection_id:              [CONNECTION_ID_LIMIT]u8, // The Source Connection ID of the first Initial packet of the side. The receiver compares it with the identifier that the packets carried.
	initial_source_connection_id_length:       int, // The bytes of that identifier: 0 to `CONNECTION_ID_LIMIT`. An identifier of no byte is valid.
	has_initial_source_connection_id:          bool, // A read sets it, and refuses bytes without the parameter. A write does not read it: it always sends the parameter.
	max_idle_timeout:                          u64, // Milliseconds; 0: no idle timeout from this side. The idle timeout of the connection is the smaller of the two values that are not 0.
	max_udp_payload_size:                      u64, // The largest UDP payload that the side takes, in bytes. A read refuses a value under `SMALLEST_MAX_UDP_PAYLOAD_SIZE`.
	initial_max_data:                          u64, // The first limit of the bytes that the other side can send on all the streams together.
	initial_max_stream_data_bidirectional_local: u64, // The first limit of the bytes that the other side can send on a bidirectional stream that the side of the parameters opens.
	initial_max_stream_data_bidirectional_remote: u64, // The first limit of the bytes that the other side can send on a bidirectional stream that the other side opens.
	initial_max_stream_data_unidirectional:    u64, // The first limit of a unidirectional stream that the other side opens. Read only.
	initial_max_streams_bidirectional:         u64, // The count of bidirectional streams that the other side can open. A read refuses a count over `STREAMS_LIMIT`.
	initial_max_streams_unidirectional:        u64, // The count of unidirectional streams that the other side can open. Read only.
	ack_delay_exponent:                        u64, // The power of 2 that scales the ACK Delay field of the ACK frames of the side. Read only.
	max_ack_delay:                             u64, // Milliseconds: the longest time for which the side holds back an acknowledgment. Read only.
	active_connection_id_limit:                u64, // The count of connection identifiers of the other side that the side stores. Read only.
	disable_active_migration:                  bool, // The side takes no packet of this connection from another address or port.
	retry_source_connection_id:                [CONNECTION_ID_LIMIT]u8, // A server after a Retry: the Source Connection ID of its Retry packet.
	retry_source_connection_id_length:         int, // The bytes of that identifier: 0 to `CONNECTION_ID_LIMIT`.
	has_retry_source_connection_id:            bool, // The parameter is there. The caller of a read checks that it is there after a Retry, and only then.
}

// transport_parameters_default gives the values that RFC 9000 gives to a parameter that does not come.
//
// The values of section 18.2: `max_udp_payload_size` 65527, `ack_delay_exponent` 3, `max_ack_delay`
// 25 ms and `active_connection_id_limit` 2. Each other field is 0, false or empty: no idle timeout,
// no byte of flow control, no stream, no identifier.
//
// A caller that builds the parameters of its own side starts from this record and sets its limits.
// `transport_parameters_read` starts from it too, so a parameter that the peer did not send has its
// default.
transport_parameters_default :: proc "contextless" () -> Transport_Parameters {
	return {max_udp_payload_size = 65527, ack_delay_exponent = 3, max_ack_delay = 25, active_connection_id_limit = 2}
}

// transport_parameters_write encodes the transport parameters of one side into a buffer.
//
// The result is the value of the extension `quic_transport_parameters`: the caller copies it into
// `Tls_Configuration.transport_parameters` before `tls_start`. Each parameter is its identifier, the
// length of its value and the value; an integer value is a variable-length integer in its shortest
// encoding (RFC 9000, section 18).
//
// **Parameters**
//
// - `parameters`: the values of this side.
// - `role`: the role of this side. Only a `Server` writes the two identifiers that a client must
//   not send.
// - `buffer`: where the bytes go.
//
// **What it writes**, in this order:
//
// 1. `original_destination_connection_id`: a server, when its `has_` field is true;
// 2. `max_idle_timeout`: when it is not 0;
// 3. `max_udp_payload_size`: when it is not 65527;
// 4. `initial_max_data`, `initial_max_stream_data_bidi_local`,
//    `initial_max_stream_data_bidi_remote` and `initial_max_streams_bidi`: always, a value of 0 too;
// 5. `initial_source_connection_id`: always, with its length, which can be 0;
// 6. `disable_active_migration`: when it is true;
// 7. `retry_source_connection_id`: a server, when its `has_` field is true.
//
// It writes no other parameter: see `Transport_Parameters` for the fields that it does not send.
//
// **Result**: the count of bytes. **0** when the buffer has no room, or when a value is over
// `VARIABLE_LENGTH_INTEGER_LARGEST`: the buffer then holds a part of the encoding, which the caller
// must not send.
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

// transport_parameters_read decodes the transport parameters that the peer sent, and checks each one.
//
// The bytes are hostile input, although the handshake authenticated them: the peer chose them. Each
// length is checked before a byte is read, and each value is checked against the rules of RFC 9000,
// section 18.2. The caller closes the connection with the result when it is not `No_Error`.
//
// **Parameters**
//
// - `bytes`: the value of the extension, as `Tls_Handshake.peer_transport_parameters` holds it.
// - `sender`: the role of the peer that sent them.
// - `parameters`: where the values go. The read starts from `transport_parameters_default`.
//
// **Result**: `No_Error`, or `Transport_Parameter_Error` when:
//
// - an identifier or a length is cut, or a length passes the end of the bytes;
// - a parameter that this library knows comes two times;
// - a client sends a parameter that only a server sends: `original_destination_connection_id`,
//   `stateless_reset_token`, `preferred_address` or `retry_source_connection_id`;
// - a connection identifier has more than `CONNECTION_ID_LIMIT` bytes;
// - `stateless_reset_token` does not have 16 bytes, or `disable_active_migration` has a value;
// - `preferred_address` does not have its form: an IPv4 address and port (6 bytes), an IPv6 address
//   and port (18 bytes), the length of a connection identifier (1 byte), that identifier, and a
//   stateless reset token (16 bytes), with nothing after;
// - the connection identifier of `preferred_address` has no byte or more than
//   `CONNECTION_ID_LIMIT`, or the server that sends `preferred_address` chose an empty
//   `initial_source_connection_id` (RFC 9000, section 18.2);
// - an integer parameter is not one variable-length integer that fills its value;
// - `max_udp_payload_size` is under 1200 (RFC 9000 gives it no largest value: a value over the
//   65527 bytes that UDP carries is taken as it is, and this side sends 1200 bytes at most), a count of streams is over `STREAMS_LIMIT`,
//   `ack_delay_exponent` is over 20, `max_ack_delay` is 2^14 or more, or
//   `active_connection_id_limit` is under 2;
// - `initial_source_connection_id` is absent, or a server did not send
//   `original_destination_connection_id` (RFC 9000, section 7.3).
//
// After an error, `parameters` holds a part of the values: the caller must not use it.
//
// **What it skips**: a parameter with an identifier over 0x10, which this library does not know (RFC
// 9000, section 7.4.2). Such a parameter can come two times. The addresses of `preferred_address`
// are not kept: only its form is checked, because this library does not migrate. The token of
// `stateless_reset_token` is not kept.
//
// **What it does not check**: that the identifiers are those that the packets carried, and that
// `retry_source_connection_id` is there after a Retry and only then. The transport does both with
// the record.
transport_parameters_read :: proc "contextless" (bytes: []u8, sender: Tls_Role, parameters: ^Transport_Parameters) -> Transport_Error {
	parameters^ = transport_parameters_default()
	seen: bit_set[0 ..= PARAMETER_RETRY_SOURCE_CONNECTION_ID]
	has_preferred_address := false
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
			// Not used: this library does not migrate. Only its form is
			// checked: the two addresses with their ports, a connection
			// identifier with its length, and a stateless reset token. The
			// identifier is never empty (RFC 9000, section 18.2).
			if len(value) < PREFERRED_ADDRESS_FIXED_SIZE {
				return .Transport_Parameter_Error
			}
			identifier_length := int(value[PREFERRED_ADDRESS_IDENTIFIER_LENGTH_OFFSET])
			if identifier_length == 0 || identifier_length > CONNECTION_ID_LIMIT || len(value) != PREFERRED_ADDRESS_FIXED_SIZE + identifier_length {
				return .Transport_Parameter_Error
			}
			has_preferred_address = true
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
	// A server that chose an empty connection identifier gives no preferred
	// address (RFC 9000, section 18.2): a client could not name it there.
	if has_preferred_address && parameters.initial_source_connection_id_length == 0 {
		return .Transport_Parameter_Error
	}
	return .No_Error
}
