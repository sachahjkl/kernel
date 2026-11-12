package quic

// One QUIC connection (RFC 9000, RFC 9002): the transport over the packet
// protection of packets.odin and the TLS handshake of tls_handshake.odin.
// The whole state is one Connection record in memory of the caller, with no
// allocation and no kernel call. The caller gives each datagram that came
// (connection_datagram_receive), takes each datagram to send
// (connection_datagram_send), and calls connection_time_passes at the
// deadline that connection_deadline gives. Time is a count of microseconds
// that the caller gives: the tests give a fake clock.
//
// What this layer does (docs/QUIC.md, section 5):
// - the three packet number spaces, ACK frames, loss detection by the packet
//   threshold and the time threshold, and the probe timeout (RFC 9002);
// - a fixed congestion window (no NewReno yet);
// - bidirectional streams that the client opens, in a table of records of
//   the caller, with flow control for each stream and for the connection
//   (streams.odin);
// - the idle timeout, the anti-amplification limit of a server, and the
//   closing and draining states;
// - the handshake, driven by the TLS state machine.
// Each frame of the peer is hostile input (connection_receive.odin).

import "contract:errors"
import "support:random"

CLOSE_REASON_KEPT :: 48 // The bytes of the reason phrase of a close of the peer that a connection keeps.
MAX_DATAGRAM_SIZE :: 1200 // The datagrams that this side sends: the size that every path of QUIC carries (RFC 9000, section 14).
CONNECTION_ID_SIZE :: 8 // The connection identifiers that this side chooses.
CRYPTO_BUFFER_SIZE :: 4096 // The handshake bytes of one level in each direction: more from the peer is CRYPTO_BUFFER_EXCEEDED.
SENT_PACKET_LIMIT :: 64 // The ack-eliciting packets of one space that wait for an acknowledgement.
// RFC 9002, section 7.2: the initial window, min(10 * 1200, max(14720, 2 *
// 1200)). This layer keeps it fixed: NewReno comes after.
CONGESTION_WINDOW :: 12000
PACKET_THRESHOLD :: 3 // RFC 9002, section 6.1.1.
TIME_THRESHOLD_NUMERATOR :: 9 // RFC 9002, section 6.1.2: 9/8 of the round-trip time.
TIME_THRESHOLD_DENOMINATOR :: 8
GRANULARITY :: 1000 // Microseconds: RFC 9002, section 6.1.2.
INITIAL_ROUND_TRIP_TIME :: 333_000 // Microseconds: RFC 9002, section 6.2.2.
ACK_DELAY_EXPONENT_OF_THIS_SIDE :: 3 // The default of RFC 9000, section 18.2: not sent.
MAX_ACK_DELAY_OF_THIS_SIDE :: 25_000 // Microseconds: the default of RFC 9000, section 18.2, not sent.
ACK_RANGES_SEND_LIMIT :: 16 // The ranges of one ACK frame that this side sends.
ACK_RANGES_READ_LIMIT :: 64 // The ranges of one ACK frame of the peer that this side acts on; the others are read and skipped.
PROBE_PACKETS :: 2 // RFC 9002, section 6.2.4: one or two probes at a probe timeout.
NO_DEADLINE :: max(u64)
// Microseconds from the start of a client, or from the first authentic
// Initial at a server, to the end of the handshake. Anyone can make an
// authentic Initial (its keys come from a public value), so a record that
// waits for a handshake that never ends is freed at this deadline, whatever
// the idle timeout.
HANDSHAKE_TIME_LIMIT :: 10_000_000

Connection_State :: enum u8 {
	Idle, // Not started.
	Handshake,
	Connected, // The handshake of TLS is complete.
	Closing, // This side sent CONNECTION_CLOSE: it answers each datagram with it, for three probe timeouts.
	Draining, // The peer sent CONNECTION_CLOSE: this side sends nothing, for three probe timeouts.
	Closed,
}

// The frames that are not data, which a packet carries and which go again
// when the packet is lost.
Control_Frame :: enum u8 {
	Handshake_Done,
	Max_Data,
	Max_Streams, // The limit of streams that this side gives the peer: a server, when a stream of the client ended.
	Streams_Blocked, // A client that cannot open a stream for the limit of the server.
	Path_Response,
}

// One ack-eliciting packet that waits for an acknowledgement: what it
// carried, to send it again when it is lost.
Sent_Packet :: struct {
	in_use:        bool,
	packet_number: u64,
	time_sent:     u64,
	size:          u64,
	crypto_offset: u64,
	crypto_length: u64,
	// One STREAM frame at most: its stream, its range, its end.
	stream_identifier: u64,
	stream_offset:     u64,
	stream_length:     u64,
	stream_finish:     bool,
	controls:          bit_set[Control_Frame],
	// The control frames of one stream at most.
	stream_controls:            bit_set[Stream_Control],
	stream_controls_identifier: u64,
}

// The handshake bytes of one level: the bytes that TLS gave to send (kept
// until the end: they are small), and the bytes of the peer, given to TLS in
// order.
Crypto_Stream :: struct {
	send:              [CRYPTO_BUFFER_SIZE]u8,
	send_length:       u64,
	send_next:         u64, // The first byte that was never sent.
	send_again:        Range_Set, // Bytes of lost packets.
	send_acknowledged: Range_Set,
	receive:           [CRYPTO_BUFFER_SIZE]u8,
	received:          Range_Set,
	delivered:         u64, // The bytes before this offset went to TLS.
}

Packet_Number_Space :: struct {
	keys_installed:                bool,
	discarded:                     bool,
	send_keys:                     Packet_Keys,
	receive_keys:                  Packet_Keys,
	next_packet_number:            u64,
	// The packets of the peer.
	received:                      Range_Set,
	has_received:                  bool,
	largest_received:              u64,
	largest_received_time:         u64,
	ack_needed:                    bool,
	ack_eliciting_unacknowledged:  int, // Ack-eliciting packets of the peer since the last ACK frame.
	ack_deadline:                  u64,
	// The packets of this side.
	sent:                          [SENT_PACKET_LIMIT]Sent_Packet,
	ack_eliciting_in_flight:       int,
	has_acknowledged:              bool,
	largest_acknowledged:          u64,
	loss_time:                     u64, // 0: no packet waits for the time threshold.
	last_ack_eliciting_sent_time:  u64,
	probes:                        int, // Probe packets to send after a probe timeout.
	// The numbers below this one are refused: the set of received numbers
	// forgot their ranges, and such a packet may have been processed.
	packet_number_floor:           u64,
	crypto:                        Crypto_Stream,
}

Connection_Configuration :: struct {
	// The role, the application protocol, the Ed25519 key of a server or the
	// pinned key of a client, the least seed strength. The connection writes
	// the transport parameters.
	tls:                       Tls_Configuration,
	idle_timeout_milliseconds: u64, // 0: no idle timeout from this side.
}

Connection :: struct {
	configuration:                     Connection_Configuration,
	cryptography:                      ^Cryptography,
	generator:                         ^random.Generator,
	state:                             Connection_State,
	tls:                               Tls_Handshake,
	tls_started:                       bool,
	spaces:                            [Encryption_Level]Packet_Number_Space,
	local_connection_id:               [CONNECTION_ID_SIZE]u8,
	peer_connection_id:                [CONNECTION_ID_LIMIT]u8,
	peer_connection_id_length:         int,
	peer_connection_id_known:          bool, // A client: the server chose its identifier.
	// The Destination Connection ID of the first Initial of the client: the
	// Initial keys come from it. After a Retry it is the Source Connection
	// ID of the Retry (RFC 9001, section 5.2).
	original_destination_connection_id: [CONNECTION_ID_LIMIT]u8,
	original_destination_connection_id_length: int,
	// A Retry (retry.odin). A client: the one Retry that it took. A server:
	// the record of a client that came back with a valid token.
	retried:                           bool,
	retry_first_destination_connection_id: [CONNECTION_ID_LIMIT]u8, // The identifier that the client chose first, before the Retry.
	retry_first_destination_connection_id_length: int,
	retry_source_connection_id:        [CONNECTION_ID_LIMIT]u8, // The Source Connection ID of the Retry.
	retry_source_connection_id_length: int,
	retry_token:                       [RETRY_TOKEN_LIMIT]u8, // A client: the token that each later Initial carries.
	retry_token_length:                int,
	local_parameters:                  Transport_Parameters,
	peer_parameters:                   Transport_Parameters,
	peer_parameters_applied:           bool,
	handshake_confirmed:               bool,
	address_validated:                 bool, // A server: a Handshake packet of the client came. A client: always.
	client_received_handshake_ack:     bool,
	bytes_received:                    u64,
	bytes_sent:                        u64,
	bytes_in_flight:                   u64,
	// The round-trip time (RFC 9002, section 5), in microseconds.
	has_round_trip_sample:             bool,
	latest_round_trip:                 u64,
	smoothed_round_trip:               u64,
	round_trip_variation:              u64,
	min_round_trip:                    u64,
	probe_timeout_count:               u32,
	last_sent_time:                    u64,
	// The idle timeout, in microseconds.
	idle_timeout:                      u64,
	last_activity:                     u64,
	ack_eliciting_sent_since_receive:  bool,
	// The streams (streams.odin): the table of the caller, and the counts
	// of the streams that each side opened.
	streams:                           []Stream,
	streams_opened_by_peer:            u64,
	streams_opened_by_this_side:       u64,
	streams_limit_given:               u64, // The MAX_STREAMS that this side gave the peer: the streams that the peer may open in all.
	peer_max_streams_bidirectional:    u64,
	stream_send_turn:                  int, // The record whose stream sends first in the next packet: each stream gets its turn.
	// Flow control of the connection: the data of all streams.
	peer_max_data:                     u64,
	data_sent_total:                   u64, // The new bytes that this side sent, on all streams.
	receive_window:                    u64,
	receive_max_data:                  u64, // The MAX_DATA that this side gave.
	data_received_total:               u64, // The largest offset of each stream of the peer, summed.
	data_consumed_total:               u64, // The bytes of the peer that the application read, or that a reset of the peer dropped.
	peer_max_ack_delay:                u64, // Microseconds.
	peer_ack_delay_exponent:           u64,
	pending_controls:                  bit_set[Control_Frame],
	path_response:                     [PATH_DATA_SIZE]u8,
	// The close.
	close_error_code:                  u64,
	close_frame_type:                  u64,
	close_is_application:              bool,
	// The first bytes of the reason phrase of the CONNECTION_CLOSE of the
	// peer: a program logs them, to tell why a foreign stack closed.
	close_reason_of_peer:              [CLOSE_REASON_KEPT]u8,
	close_reason_of_peer_length:       int,
	closed_by_peer:                    bool,
	closed_by_idle_timeout:            bool,
	closed_by_handshake_timeout:       bool,
	handshake_deadline:                u64,
	// Set while the frames of one packet are read: data of the packet had no
	// place in a range set, so the packet is not acknowledged.
	packet_data_dropped:               bool,
	close_to_send:                     bool,
	// The closing state answers the 1st, 2nd, 4th, 8th... datagram of the
	// peer, not each one: a third party that knows the identifier and
	// forges the address of the client makes few answers (RFC 9000,
	// section 10.2.1).
	close_datagrams_received:          u64,
	close_next_answer:                 u64,
	close_deadline:                    u64,
	// Private memory: the copy of a datagram that came, and the frames of
	// the packets of a datagram to send.
	datagram_copy:                     [DATAGRAM_LIMIT]u8,
	payloads:                          [Encryption_Level][MAX_DATAGRAM_SIZE]u8,
}

// connection_start_client starts a client: it chooses its connection
// identifier and the Destination Connection ID of its first Initial, and
// makes the ClientHello. The first datagram is ready for
// connection_datagram_send. streams is memory of the caller, never a
// stack: the streams that the client opens at one time.
connection_start_client :: proc "contextless" (connection: ^Connection, streams: []Stream, configuration: ^Connection_Configuration, cryptography: ^Cryptography, generator: ^random.Generator, now: u64, error: ^errors.Error_Record) -> bool {
	connection_reset(connection, streams, configuration, cryptography, generator, now)
	connection.configuration.tls.role = .Client
	connection.address_validated = true
	connection.handshake_deadline = saturating_add(now, HANDSHAKE_TIME_LIMIT)
	if !connection_seed_strength_check(configuration, error) {
		connection.state = .Closed
		return false
	}
	least := configuration.tls.least_seed_strength
	if !random.fill_for_a_key(generator, connection.local_connection_id[:], least, error) || !random.fill_for_a_key(generator, connection.original_destination_connection_id[:CONNECTION_ID_SIZE], least, error) {
		connection.state = .Closed
		return false
	}
	connection.original_destination_connection_id_length = CONNECTION_ID_SIZE
	connection.peer_connection_id_length = copy(connection.peer_connection_id[:], connection.original_destination_connection_id[:CONNECTION_ID_SIZE])
	if !connection_initial_keys_install(connection, error) || !connection_tls_start(connection, error) {
		connection.state = .Closed
		return false
	}
	connection_tls_progress(connection, now)
	return connection.state == .Handshake
}

// connection_start_server prepares a server for one client: the handshake
// starts at the first Initial packet of the client, whose Destination
// Connection ID gives the Initial keys. streams is memory of the caller,
// never a stack: the client may open as many streams at one time.
connection_start_server :: proc "contextless" (connection: ^Connection, streams: []Stream, configuration: ^Connection_Configuration, cryptography: ^Cryptography, generator: ^random.Generator, now: u64, error: ^errors.Error_Record) -> bool {
	connection_reset(connection, streams, configuration, cryptography, generator, now)
	connection.configuration.tls.role = .Server
	connection.streams_limit_given = u64(len(streams))
	if !connection_seed_strength_check(configuration, error) {
		connection.state = .Closed
		return false
	}
	if !random.fill_for_a_key(generator, connection.local_connection_id[:], configuration.tls.least_seed_strength, error) {
		connection.state = .Closed
		return false
	}
	return true
}

// connection_seed_strength_check refuses a configuration whose least seed
// strength is under processor: a field left at its zero value would accept a
// weak seed for the keys (tls_start refuses it too, but a server starts TLS
// only at the first Initial).
@(private)
connection_seed_strength_check :: proc "contextless" (configuration: ^Connection_Configuration, error: ^errors.Error_Record) -> bool {
	if configuration.tls.least_seed_strength < .Processor {
		errors.fail(error, -1, .Bad_Value, .None, 1, i64(configuration.tls.least_seed_strength), i64(random.Seed_Strength.Processor), 0)
		return false
	}
	return true
}

@(private)
connection_reset :: proc "contextless" (connection: ^Connection, streams: []Stream, configuration: ^Connection_Configuration, cryptography: ^Cryptography, generator: ^random.Generator, now: u64) {
	connection^ = {}
	connection.configuration = configuration^
	connection.cryptography = cryptography
	connection.generator = generator
	connection.state = .Handshake
	connection.last_activity = now
	connection.idle_timeout = saturating_multiply(configuration.idle_timeout_milliseconds, 1000)
	connection.streams = streams
	for &stream in streams {
		// A connection that ended with streams still open left their bytes:
		// the next connection of the table never holds them.
		if stream.in_use {
			stream_buffers_erase(&stream)
		}
		stream.state = {}
	}
	// The window of the connection: the buffers of every stream, so the
	// limit of each stream is the one that binds.
	connection.receive_window = u64(max(len(streams), 1)) * STREAM_BUFFER_SIZE
	connection.receive_max_data = connection.receive_window
	connection.peer_max_ack_delay = 25_000
	connection.peer_ack_delay_exponent = 3
}

// connection_initial_keys_install derives the Initial keys from the
// Destination Connection ID of the first Initial of the client.
@(private)
connection_initial_keys_install :: proc "contextless" (connection: ^Connection, error: ^errors.Error_Record) -> bool {
	space := &connection.spaces[.Initial]
	client, server: Packet_Keys
	if !initial_keys(connection.cryptography, connection.original_destination_connection_id[:connection.original_destination_connection_id_length], &client, &server, error) {
		return false
	}
	if connection.configuration.tls.role == .Client {
		space.send_keys, space.receive_keys = client, server
	} else {
		space.send_keys, space.receive_keys = server, client
	}
	secret_erase(&client, size_of(client))
	secret_erase(&server, size_of(server))
	space.keys_installed = true
	return true
}

// connection_tls_start writes the transport parameters of this side and
// starts the handshake of TLS.
@(private)
connection_tls_start :: proc "contextless" (connection: ^Connection, error: ^errors.Error_Record) -> bool {
	parameters := &connection.local_parameters
	parameters^ = transport_parameters_default()
	parameters.max_idle_timeout = connection.configuration.idle_timeout_milliseconds
	parameters.max_udp_payload_size = DATAGRAM_LIMIT
	parameters.initial_max_data = connection.receive_window
	parameters.initial_max_stream_data_bidirectional_local = STREAM_BUFFER_SIZE
	parameters.initial_max_stream_data_bidirectional_remote = STREAM_BUFFER_SIZE
	// Only the client opens streams: a server allows the client one stream
	// for each of its records, a client allows the server none.
	parameters.initial_max_streams_bidirectional = connection.streams_limit_given
	parameters.initial_source_connection_id_length = copy(parameters.initial_source_connection_id[:], connection.local_connection_id[:])
	parameters.has_initial_source_connection_id = true
	if connection.configuration.tls.role == .Server {
		// A server of this library finds a connection by its identifier and
		// by the address and port of its client: the client must not move
		// to another address (RFC 9000, section 9).
		parameters.disable_active_migration = true
		// After a Retry the server names the identifier that the client
		// chose first, and the Source Connection ID of its Retry (RFC 9000,
		// section 7.3).
		if connection.retried {
			parameters.original_destination_connection_id_length = copy(parameters.original_destination_connection_id[:], connection.retry_first_destination_connection_id[:connection.retry_first_destination_connection_id_length])
			parameters.retry_source_connection_id_length = copy(parameters.retry_source_connection_id[:], connection.retry_source_connection_id[:connection.retry_source_connection_id_length])
			parameters.has_retry_source_connection_id = true
		} else {
			parameters.original_destination_connection_id_length = copy(parameters.original_destination_connection_id[:], connection.original_destination_connection_id[:connection.original_destination_connection_id_length])
		}
		parameters.has_original_destination_connection_id = true
	}
	tls_configuration := &connection.configuration.tls
	tls_configuration.transport_parameters_length = transport_parameters_write(parameters, tls_configuration.role, tls_configuration.transport_parameters[:])
	if tls_configuration.transport_parameters_length == 0 {
		return fail_at(error, .Too_Long, 1, TRANSPORT_PARAMETERS_LIMIT)
	}
	connection.tls_started = true
	started := tls_start(&connection.tls, tls_configuration, connection.cryptography, connection.generator, error)
	// The configuration of the connection keeps no copy of the private key
	// of a server: the handshake has its own.
	secret_erase(&tls_configuration.server_private_key, size_of(tls_configuration.server_private_key))
	return started
}

// connection_tls_progress moves the bytes that TLS wrote into the crypto
// streams, installs the keys that are ready, applies the transport
// parameters of the peer, and follows the state of TLS.
@(private)
connection_tls_progress :: proc "contextless" (connection: ^Connection, now: u64) {
	if !connection.tls_started || connection.state == .Closing || connection.state == .Draining || connection.state == .Closed {
		return
	}
	tls := &connection.tls
	for level in Encryption_Level {
		bytes := tls_bytes_to_send(tls, level)
		if len(bytes) == 0 {
			continue
		}
		crypto := &connection.spaces[level].crypto
		if u64(len(bytes)) > CRYPTO_BUFFER_SIZE - crypto.send_length {
			connection_fail(connection, u64(Transport_Error.Internal_Error), FRAME_CRYPTO, now)
			return
		}
		copy(crypto.send[crypto.send_length:], bytes)
		crypto.send_length += u64(len(bytes))
		tls_bytes_sent(tls, level, len(bytes))
	}
	error: errors.Error_Record
	for level in ([]Encryption_Level{.Handshake, .Application}) {
		space := &connection.spaces[level]
		ready := level == .Handshake ? tls.handshake_keys_ready : tls.application_keys_ready
		if !ready || space.keys_installed || space.discarded {
			continue
		}
		if !tls_packet_keys(tls, level, true, &space.send_keys, &error) || !tls_packet_keys(tls, level, false, &space.receive_keys, &error) {
			connection_fail(connection, u64(Transport_Error.Internal_Error), 0, now)
			return
		}
		space.keys_installed = true
	}
	if tls.state == .Failed {
		connection_fail(connection, tls_failure_code(connection), FRAME_CRYPTO, now)
		return
	}
	if !connection.peer_parameters_applied && connection_peer_parameters_are_known(connection) {
		if !connection_peer_parameters_apply(connection, now) {
			return
		}
	}
	if tls.state == .Connected && connection.state == .Handshake {
		connection.state = .Connected
		// Each key is in its space: the secrets of TLS are no longer needed.
		tls_handshake_erase_secrets(tls)
		if connection.configuration.tls.role == .Server {
			// A server confirms the handshake when it completes, and tells
			// the client (RFC 9001, section 4.1.2).
			connection.handshake_confirmed = true
			connection.pending_controls += {.Handshake_Done}
			connection_space_discard(connection, .Handshake)
		}
	}
}

// tls_failure_code gives the error code of a CONNECTION_CLOSE for a failure
// of TLS: 0x100 + its alert, or PROTOCOL_VIOLATION for handshake bytes at a
// level whose keys were replaced (RFC 9001, section 4.1.3).
@(private)
tls_failure_code :: proc "contextless" (connection: ^Connection) -> u64 {
	if connection.tls.bytes_after_key_change {
		return u64(Transport_Error.Protocol_Violation)
	}
	return CRYPTO_ERROR_BASE + u64(connection.tls.alert)
}

// The transport parameters of the peer come in its ClientHello, or in the
// EncryptedExtensions of a server.
@(private)
connection_peer_parameters_are_known :: proc "contextless" (connection: ^Connection) -> bool {
	#partial switch connection.tls.state {
	case .Client_Waits_For_Certificate, .Client_Waits_For_Certificate_Verify, .Client_Waits_For_Finished, .Server_Waits_For_Finished, .Connected:
		return true
	}
	return false
}

@(private)
connection_peer_parameters_apply :: proc "contextless" (connection: ^Connection, now: u64) -> bool {
	peer_role := connection.configuration.tls.role == .Client ? Tls_Role.Server : Tls_Role.Client
	parameters := &connection.peer_parameters
	result := transport_parameters_read(connection.tls.peer_transport_parameters[:connection.tls.peer_transport_parameters_length], peer_role, parameters)
	if result != .No_Error {
		return connection_fail(connection, u64(result), 0, now)
	}
	// The identifiers that the packets carried must be the ones that the
	// handshake authenticated (RFC 9000, section 7.3).
	if !bytes_equal(parameters.initial_source_connection_id[:parameters.initial_source_connection_id_length], connection.peer_connection_id[:connection.peer_connection_id_length]) {
		return connection_fail(connection, u64(Transport_Error.Transport_Parameter_Error), 0, now)
	}
	if peer_role == .Server {
		// The server names the identifier that this client chose first; and,
		// when this client took a Retry, the Source Connection ID of that
		// Retry, and only then (RFC 9000, section 7.3).
		original := connection.original_destination_connection_id[:connection.original_destination_connection_id_length]
		if connection.retried {
			original = connection.retry_first_destination_connection_id[:connection.retry_first_destination_connection_id_length]
		}
		if !bytes_equal(parameters.original_destination_connection_id[:parameters.original_destination_connection_id_length], original) {
			return connection_fail(connection, u64(Transport_Error.Transport_Parameter_Error), 0, now)
		}
		retry_source := connection.retry_source_connection_id[:connection.retry_source_connection_id_length]
		if parameters.has_retry_source_connection_id != connection.retried || (connection.retried && !bytes_equal(parameters.retry_source_connection_id[:parameters.retry_source_connection_id_length], retry_source)) {
			return connection_fail(connection, u64(Transport_Error.Transport_Parameter_Error), 0, now)
		}
	}
	// The limit of each stream comes from these parameters when the stream
	// opens (stream_record_take).
	connection.peer_max_data = parameters.initial_max_data
	connection.peer_max_streams_bidirectional = parameters.initial_max_streams_bidirectional
	connection.peer_max_ack_delay = parameters.max_ack_delay * 1000
	connection.peer_ack_delay_exponent = parameters.ack_delay_exponent
	// The idle timeout is the smaller of the two that are not 0 (RFC 9000,
	// section 10.1).
	peer_idle := saturating_multiply(parameters.max_idle_timeout, 1000)
	if peer_idle != 0 && (connection.idle_timeout == 0 || peer_idle < connection.idle_timeout) {
		connection.idle_timeout = peer_idle
	}
	connection.peer_parameters_applied = true
	return true
}

bytes_equal :: proc "contextless" (left, right: []u8) -> bool {
	if len(left) != len(right) {
		return false
	}
	for index in 0 ..< len(left) {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

// connection_fail closes the connection for an error of the peer or of this
// side: this side sends CONNECTION_CLOSE with the code (RFC 9000, section
// 10.2). It gives false, for the reader that called it.
connection_fail :: proc "contextless" (connection: ^Connection, code: u64, frame_type: u64, now: u64) -> bool {
	if connection.state == .Closing || connection.state == .Draining || connection.state == .Closed {
		return false
	}
	connection.close_error_code = code
	connection.close_frame_type = frame_type
	connection.close_is_application = false
	connection_enter_closing(connection, now)
	return false
}

// connection_close closes the connection for the application, with its
// error code (a CONNECTION_CLOSE of type 0x1d).
connection_close :: proc "contextless" (connection: ^Connection, application_error_code: u64, now: u64) {
	if connection.state != .Handshake && connection.state != .Connected {
		return
	}
	connection.close_error_code = application_error_code
	connection.close_frame_type = 0
	connection.close_is_application = true
	connection_enter_closing(connection, now)
}

@(private)
connection_enter_closing :: proc "contextless" (connection: ^Connection, now: u64) {
	connection.state = .Closing
	connection.close_to_send = true
	connection.close_datagrams_received = 0
	connection.close_next_answer = 1
	connection.close_deadline = saturating_add(now, saturating_multiply(3, probe_timeout_base(connection, .Application)))
	tls_handshake_erase_secrets(&connection.tls)
}

@(private)
connection_enter_draining :: proc "contextless" (connection: ^Connection, code: u64, frame_type: u64, application: bool, now: u64) {
	connection.closed_by_peer = true
	connection.close_error_code = code
	connection.close_frame_type = frame_type
	connection.close_is_application = application
	connection.state = .Draining
	connection.close_to_send = false
	connection.close_deadline = saturating_add(now, saturating_multiply(3, probe_timeout_base(connection, .Application)))
	tls_handshake_erase_secrets(&connection.tls)
}

@(private)
connection_end :: proc "contextless" (connection: ^Connection) {
	connection.state = .Closed
	for level in Encryption_Level {
		space := &connection.spaces[level]
		secret_erase(&space.send_keys, size_of(space.send_keys))
		secret_erase(&space.receive_keys, size_of(space.receive_keys))
		space.keys_installed = false
	}
	tls_handshake_erase_secrets(&connection.tls)
}

// connection_space_discard drops the keys of a space and each packet of it
// that waits (RFC 9001, section 4.9; RFC 9002, section 6.4).
connection_space_discard :: proc "contextless" (connection: ^Connection, level: Encryption_Level) {
	space := &connection.spaces[level]
	if space.discarded {
		return
	}
	space.discarded = true
	for &packet in space.sent {
		if packet.in_use {
			connection.bytes_in_flight -= min(packet.size, connection.bytes_in_flight)
			packet.in_use = false
		}
	}
	space.ack_eliciting_in_flight = 0
	space.loss_time = 0
	space.probes = 0
	space.ack_needed = false
	secret_erase(&space.send_keys, size_of(space.send_keys))
	secret_erase(&space.receive_keys, size_of(space.receive_keys))
	connection.probe_timeout_count = 0
}

// connection_deadline gives the time at which the caller calls
// connection_time_passes: the idle timeout, the loss detection timer, the
// delay of an acknowledgement, or the end of the closing and draining
// states. NO_DEADLINE when nothing waits.
connection_deadline :: proc "contextless" (connection: ^Connection) -> u64 {
	switch connection.state {
	case .Idle, .Closed:
		return NO_DEADLINE
	case .Closing, .Draining:
		return connection.close_deadline
	case .Handshake, .Connected:
	}
	if !connection.tls_started {
		// A server that waits for its first Initial has no timer.
		return NO_DEADLINE
	}
	deadline := connection_idle_deadline(connection)
	loss, _, _ := loss_detection_deadline(connection)
	deadline = min(deadline, loss)
	if connection.state == .Handshake {
		deadline = min(deadline, connection.handshake_deadline)
	}
	application := &connection.spaces[.Application]
	if application.ack_needed && application.ack_deadline < deadline {
		deadline = application.ack_deadline
	}
	return deadline
}

@(private)
connection_idle_deadline :: proc "contextless" (connection: ^Connection) -> u64 {
	if connection.idle_timeout == 0 {
		return NO_DEADLINE
	}
	// At least three probe timeouts, so that a loss does not end a
	// connection that works (RFC 9000, section 10.1: "three times the
	// current Probe Timeout"). The timeout here has no backoff: with the
	// backoff, each probe that the silent peer does not answer doubles the
	// bound, the bound moves past each next probe, and the connection lives
	// until the backoff stops (hours), holding its record. With no backoff,
	// a connection that receives nothing ends at most max(idle timeout,
	// 3 × base probe timeout) after its last activity, whatever the count
	// of probes. The activity is a packet received and processed, or the
	// first ack-eliciting packet sent after it (connection_send.odin); a
	// later probe does not move it.
	return saturating_add(connection.last_activity, max(connection.idle_timeout, saturating_multiply(3, probe_timeout_base(connection, .Application))))
}

// connection_time_passes acts on each deadline that passed.
connection_time_passes :: proc "contextless" (connection: ^Connection, now: u64) {
	switch connection.state {
	case .Idle, .Closed:
		return
	case .Closing, .Draining:
		if now >= connection.close_deadline {
			connection_end(connection)
		}
		return
	case .Handshake, .Connected:
	}
	if !connection.tls_started {
		return
	}
	if connection.state == .Handshake && now >= connection.handshake_deadline {
		connection.closed_by_handshake_timeout = true
		connection_end(connection)
		return
	}
	if now >= connection_idle_deadline(connection) {
		// The idle timeout ends the connection with no packet (RFC 9000,
		// section 10.1).
		connection.closed_by_idle_timeout = true
		connection_end(connection)
		return
	}
	loss_detection_timeout(connection, now)
}
