package quic

// The handshake of TLS 1.3 as QUIC carries it (RFC 8446, RFC 9001,
// docs/QUIC.md): the messages go in CRYPTO frames at their encryption
// level, with no record layer. Both sides, as one state machine over bytes
// in memory of the caller, with no allocation.
//
// What this handshake does, and nothing more:
// - X25519 as the one group, Ed25519 as the one signature algorithm;
// - TLS_CHACHA20_POLY1305_SHA256 first, TLS_AES_128_GCM_SHA256 also;
// - the server proves its key with a raw public key (RFC 7250): its
//   Certificate holds the SubjectPublicKeyInfo of an Ed25519 key, and the
//   client compares that key with the key that its caller pinned; no X.509
//   is read;
// - one application protocol (ALPN), and the quic_transport_parameters of
//   each side, carried as bytes;
// - no session resumption, no 0-RTT, no HelloRetryRequest, no client
//   certificate.
//
// Each message of the peer is hostile input: each length is checked before
// a byte is read, an extension that this side does not know is skipped in a
// ClientHello and refused where it was not offered, an extension that comes
// two times is refused, and each failure gives the alert of TLS (for the
// CONNECTION_CLOSE of QUIC, 0x100 + alert, RFC 9001 section 4.8) and an
// error record whose found field is the alert.

import "contract:errors"
import "support:random"

TLS_LEGACY_VERSION :: 0x0303
TLS_VERSION_1_3 :: 0x0304
TLS_GROUP_X25519 :: 0x001D
TLS_SIGNATURE_ED25519 :: 0x0807
TLS_SUITE_AES_128_GCM_SHA256 :: 0x1301
TLS_SUITE_CHACHA20_POLY1305_SHA256 :: 0x1303
CERTIFICATE_TYPE_RAW_PUBLIC_KEY :: 2 // RFC 7250, section 3.

// The extensions that this handshake reads or writes (RFC 8446, section
// 4.2; RFC 7250; RFC 9001, section 8.2).
Extension :: enum u16 {
	Server_Name             = 0,
	Supported_Groups        = 10,
	Signature_Algorithms    = 13,
	Application_Protocol    = 16,
	Client_Certificate_Type = 19,
	Server_Certificate_Type = 20,
	Pre_Shared_Key          = 41,
	Early_Data              = 42,
	Supported_Versions      = 43,
	Psk_Key_Exchange_Modes  = 45,
	Key_Share               = 51,
	Quic_Transport_Parameters = 57,
}

// The handshake messages (RFC 8446, section 4).
Handshake_Message :: enum u8 {
	Client_Hello         = 1,
	Server_Hello         = 2,
	New_Session_Ticket   = 4,
	Encrypted_Extensions = 8,
	Certificate          = 11,
	Certificate_Verify   = 15,
	Finished             = 20,
	Key_Update           = 24,
}

// The alerts that this handshake gives (RFC 8446, section 6).
Alert :: enum u8 {
	None                     = 0,
	Unexpected_Message       = 10,
	Handshake_Failure        = 40,
	Bad_Certificate          = 42,
	Unsupported_Certificate  = 43,
	Illegal_Parameter        = 47,
	Decode_Error             = 50,
	Decrypt_Error            = 51,
	Protocol_Version         = 70,
	Internal_Error           = 80,
	Missing_Extension        = 109,
	Unsupported_Extension    = 110,
	No_Application_Protocol  = 120,
}

// An encryption level of QUIC: the CRYPTO frames of each one carry their own
// sequence of handshake bytes (RFC 9001, section 4).
Encryption_Level :: enum u8 {
	Initial     = 0,
	Handshake   = 1,
	Application = 2,
}

Tls_Role :: enum u8 {
	Client,
	Server,
}

Tls_State :: enum u8 {
	Start,
	Client_Waits_For_Server_Hello,
	Client_Waits_For_Encrypted_Extensions,
	Client_Waits_For_Certificate,
	Client_Waits_For_Certificate_Verify,
	Client_Waits_For_Finished,
	Server_Waits_For_Client_Hello,
	Server_Waits_For_Finished,
	Connected,
	Failed,
}

APPLICATION_PROTOCOL_LIMIT :: 255 // One protocol name of ALPN (RFC 7301).
TRANSPORT_PARAMETERS_LIMIT :: 512 // The quic_transport_parameters of one side.
LEVEL_BUFFER_SIZE :: 4096 // The handshake bytes of one level that wait, in each direction.
// The handshake messages to the Finished of the client. Those of this
// system have under 2 KiB; a ClientHello of a peer can have up to 4092 bytes
// (a large key share and padding), and the flight of the server about 600
// bytes more.
TRANSCRIPT_LIMIT :: 8192
MESSAGE_HEADER_SIZE :: 4 // The type and a length of 24 bits.
EXTENSION_TYPES_LIMIT :: 48 // Extensions of one block: more is refused.
ED25519_KEY_SIZE :: 32
ED25519_SIGNATURE_SIZE :: 64
PUBLIC_KEY_INFORMATION_SIZE :: 12 + ED25519_KEY_SIZE
// The 12 bytes of an Ed25519 SubjectPublicKeyInfo before the key (RFC 8410,
// section 4; RFC 7250, section 3). A raw public key is these 44 bytes and
// nothing else: no other DER is read.
@(rodata)
ED25519_PUBLIC_KEY_INFORMATION_PREFIX := [12]u8{0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00}
// The Random of a HelloRetryRequest (RFC 8446, section 4.1.3).
@(rodata)
HELLO_RETRY_REQUEST_RANDOM := [32]u8{0xcf, 0x21, 0xad, 0x74, 0xe5, 0x9a, 0x61, 0x11, 0xbe, 0x1d, 0x8c, 0x02, 0x1e, 0x65, 0xb8, 0x91, 0xc2, 0xa2, 0x11, 0x16, 0x7a, 0xbb, 0x8c, 0x5e, 0x07, 0x9e, 0x09, 0xe2, 0xc8, 0xa8, 0x33, 0x9c}
SERVER_SIGNATURE_CONTEXT :: "TLS 1.3, server CertificateVerify" // RFC 8446, section 4.4.3.

// What the caller of each side gives.
Tls_Configuration :: struct {
	role:                       Tls_Role,
	application_protocol:       [APPLICATION_PROTOCOL_LIMIT]u8, // The client offers it; the server accepts it only.
	application_protocol_length: int,
	transport_parameters:       [TRANSPORT_PARAMETERS_LIMIT]u8, // Encoded by the transport (RFC 9000, section 18).
	transport_parameters_length: int,
	// The server: its Ed25519 private key (32 bytes). Its program holds it;
	// it never leaves the memory of the program.
	server_private_key:         [ED25519_KEY_SIZE]u8,
	// The client: the Ed25519 public key of the server that it accepts, and
	// no other (pinned by its caller).
	server_public_key:          [ED25519_KEY_SIZE]u8,
	// The least strength of the random seed that the caller accepts for the
	// key share and the random values (support/random). QUIC asks for
	// processor at least.
	least_seed_strength:        random.Seed_Strength,
}

// The handshake bytes of one level in one direction.
Level_Bytes :: struct {
	bytes:  [LEVEL_BUFFER_SIZE]u8,
	length: int,
}

Tls_Handshake :: struct {
	configuration:                 Tls_Configuration,
	cryptography:                  ^Cryptography,
	generator:                     ^random.Generator,
	state:                         Tls_State,
	alert:                         Alert, // The alert of a failure: QUIC closes with 0x100 + alert.
	suite:                         Cipher_Suite,
	x25519_private_key:            [32]u8,
	x25519_public_key:             [32]u8,
	client_random:                 [32]u8,
	schedule:                      Key_Schedule,
	transcript:                    [TRANSCRIPT_LIMIT]u8,
	transcript_length:             int,
	received:                      [Encryption_Level]Level_Bytes, // Bytes of the peer that do not make a whole message yet.
	to_send:                       [Encryption_Level]Level_Bytes, // Bytes that the transport sends in CRYPTO frames.
	peer_transport_parameters:     [TRANSPORT_PARAMETERS_LIMIT]u8,
	peer_transport_parameters_length: int,
	server_public_key:             [ED25519_KEY_SIZE]u8, // The server: its own public key; the client: the key that the server proved.
	// The client: the key that a server presented and that is not the
	// pinned key (alert bad_certificate). A public value: the caller says
	// which key came, so that a reader sees a stale pin at once.
	refused_server_public_key:     [ED25519_KEY_SIZE]u8,
	handshake_keys_ready:          bool,
	application_keys_ready:        bool,
	// Bytes of the peer came at a level after the keys of the next level
	// were in use: a PROTOCOL_VIOLATION of QUIC (RFC 9001, section 4.1.3),
	// not an alert of TLS.
	bytes_after_key_change:        bool,
}

// tls_receive_level gives the level at which the peer sends in a state: the
// bytes of an earlier level after that are refused.
tls_receive_level :: proc "contextless" (state: Tls_State) -> Encryption_Level {
	#partial switch state {
	case .Client_Waits_For_Encrypted_Extensions, .Client_Waits_For_Certificate, .Client_Waits_For_Certificate_Verify, .Client_Waits_For_Finished, .Server_Waits_For_Finished:
		return .Handshake
	case .Connected:
		return .Application
	}
	return .Initial
}

// tls_fail ends a handshake with an alert and an error record (argument:
// the argument of the call that holds the bad bytes; value: an offset in the
// message; found: the alert).
@(private)
tls_fail :: proc "contextless" (handshake: ^Tls_Handshake, error: ^errors.Error_Record, alert: Alert, kind: errors.Kind, value: int = 0) -> bool {
	handshake.state = .Failed
	handshake.alert = alert
	errors.fail(error, -1, kind, .Bytes, 3, i64(value), 0, i64(alert))
	tls_handshake_erase_secrets(handshake)
	return false
}

// tls_handshake_erase_secrets erases each secret of a handshake: at a
// failure, and when the transport took the application keys.
tls_handshake_erase_secrets :: proc "contextless" (handshake: ^Tls_Handshake) {
	secret_erase(&handshake.x25519_private_key, size_of(handshake.x25519_private_key))
	secret_erase(&handshake.schedule, size_of(handshake.schedule))
	secret_erase(&handshake.configuration.server_private_key, size_of(handshake.configuration.server_private_key))
}

// A reader of the bytes of one message: each read checks its length first,
// and a read past the end sets failed and gives zeros.
@(private)
Reader :: struct {
	bytes:    []u8,
	position: int,
	failed:   bool,
}

@(private)
read_integer :: proc "contextless" (reader: ^Reader, size: int) -> int {
	if reader.failed || size > len(reader.bytes) - reader.position {
		reader.failed = true
		return 0
	}
	value := 0
	for index in 0 ..< size {
		value = value << 8 | int(reader.bytes[reader.position + index])
	}
	reader.position += size
	return value
}

@(private)
read_bytes :: proc "contextless" (reader: ^Reader, count: int) -> []u8 {
	if reader.failed || count < 0 || count > len(reader.bytes) - reader.position {
		reader.failed = true
		return nil
	}
	bytes := reader.bytes[reader.position:][:count]
	reader.position += count
	return bytes
}

// read_vector reads a length of length_size bytes, then that many bytes.
@(private)
read_vector :: proc "contextless" (reader: ^Reader, length_size: int) -> []u8 {
	return read_bytes(reader, read_integer(reader, length_size))
}

@(private)
read_done :: proc "contextless" (reader: ^Reader) -> bool {
	return !reader.failed && reader.position == len(reader.bytes)
}

// A writer into one buffer: a write past the end sets failed.
@(private)
Writer :: struct {
	bytes:    []u8,
	position: int,
	failed:   bool,
}

@(private)
write_integer :: proc "contextless" (writer: ^Writer, value: int, size: int) {
	if writer.failed || size > len(writer.bytes) - writer.position {
		writer.failed = true
		return
	}
	for index in 0 ..< size {
		writer.bytes[writer.position + index] = u8(value >> (8 * uint(size - 1 - index)))
	}
	writer.position += size
}

@(private)
write_bytes :: proc "contextless" (writer: ^Writer, bytes: []u8) {
	if writer.failed || len(bytes) > len(writer.bytes) - writer.position {
		writer.failed = true
		return
	}
	copy(writer.bytes[writer.position:], bytes)
	writer.position += len(bytes)
}

// vector_start writes a length of length_size bytes to fill later, and
// gives its place; vector_end writes it.
@(private)
vector_start :: proc "contextless" (writer: ^Writer, length_size: int) -> int {
	place := writer.position
	write_integer(writer, 0, length_size)
	return place
}

@(private)
vector_end :: proc "contextless" (writer: ^Writer, place: int, length_size: int) {
	if writer.failed {
		return
	}
	length := writer.position - place - length_size
	if length >= 1 << uint(8 * length_size) {
		writer.failed = true
		return
	}
	for index in 0 ..< length_size {
		writer.bytes[place + index] = u8(length >> (8 * uint(length_size - 1 - index)))
	}
}

// The extensions of one block, read once: the data of each one that this
// side knows, and the check that none comes two times.
@(private)
Extensions :: struct {
	data:    #sparse[Extension][]u8,
	present: bit_set[Extension],
}

// extensions_read reads an extension block. known is the extensions that
// this message may hold; an extension of a type that this side does not know
// is skipped when unknown_allowed (a ClientHello), else it is refused with
// unsupported_extension. An extension of a known type that the message may
// not hold is refused too. Each type comes once at most.
@(private)
extensions_read :: proc "contextless" (handshake: ^Tls_Handshake, block: []u8, known: bit_set[Extension], unknown_allowed: bool, extensions: ^Extensions, error: ^errors.Error_Record) -> bool {
	extensions^ = {}
	reader := Reader{bytes = block}
	seen: [EXTENSION_TYPES_LIMIT]u16
	seen_count := 0
	for reader.position < len(block) {
		start := reader.position
		type := u16(read_integer(&reader, 2))
		data := read_vector(&reader, 2)
		if reader.failed {
			return tls_fail(handshake, error, .Decode_Error, .Bad_Value, start)
		}
		for earlier in seen[:seen_count] {
			if earlier == type {
				return tls_fail(handshake, error, .Illegal_Parameter, .Bad_Value, start)
			}
		}
		if seen_count == EXTENSION_TYPES_LIMIT {
			return tls_fail(handshake, error, .Decode_Error, .Too_Long, start)
		}
		seen[seen_count] = type
		seen_count += 1
		known_type := false
		for extension in Extension {
			if u16(extension) == type {
				known_type = true
				if extension not_in known {
					return tls_fail(handshake, error, .Unsupported_Extension, .Unsupported, start)
				}
				extensions.data[extension] = data
				extensions.present += {extension}
			}
		}
		if !known_type && !unknown_allowed {
			return tls_fail(handshake, error, .Unsupported_Extension, .Unsupported, start)
		}
	}
	return true
}

// list_has says if a list of values of value_size bytes, with a length of
// length_size bytes before it, holds a value. A list that is malformed (its
// length not a multiple of the size, or past the data) gives ok false.
@(private)
list_has :: proc "contextless" (data: []u8, length_size: int, value_size: int, value: int) -> (has: bool, ok: bool) {
	reader := Reader{bytes = data}
	list := read_vector(&reader, length_size)
	if !read_done(&reader) || len(list) == 0 || len(list) % value_size != 0 {
		return false, false
	}
	items := Reader{bytes = list}
	for items.position < len(list) {
		if read_integer(&items, value_size) == value {
			has = true
		}
	}
	return has, true
}

// message_append adds a whole message to the transcript and to the bytes to
// send at a level.
@(private)
message_send :: proc "contextless" (handshake: ^Tls_Handshake, level: Encryption_Level, message: []u8, error: ^errors.Error_Record) -> bool {
	if !transcript_add(handshake, message, error) {
		return false
	}
	output := &handshake.to_send[level]
	if len(message) > LEVEL_BUFFER_SIZE - output.length {
		return tls_fail(handshake, error, .Internal_Error, .Full, len(message))
	}
	copy(output.bytes[output.length:], message)
	output.length += len(message)
	return true
}

@(private)
transcript_add :: proc "contextless" (handshake: ^Tls_Handshake, message: []u8, error: ^errors.Error_Record) -> bool {
	if len(message) > TRANSCRIPT_LIMIT - handshake.transcript_length {
		return tls_fail(handshake, error, .Internal_Error, .Full, len(message))
	}
	copy(handshake.transcript[handshake.transcript_length:], message)
	handshake.transcript_length += len(message)
	return true
}

@(private)
transcript_hash :: proc "contextless" (handshake: ^Tls_Handshake, output: ^[HASH_SIZE]u8, error: ^errors.Error_Record) -> bool {
	if !hash_of(handshake.cryptography, handshake.transcript[:handshake.transcript_length], output) {
		return tls_fail(handshake, error, .Internal_Error, .Refused)
	}
	return true
}

// key_share_make draws the X25519 private key and computes its public key,
// with the least seed strength of the configuration.
@(private)
key_share_make :: proc "contextless" (handshake: ^Tls_Handshake, error: ^errors.Error_Record) -> bool {
	if !random.fill_for_a_key(handshake.generator, handshake.x25519_private_key[:], handshake.configuration.least_seed_strength, error) {
		handshake.state = .Failed
		handshake.alert = .Internal_Error
		return false
	}
	base_point: [32]u8
	base_point[0] = 9
	scalar, point := string(handshake.x25519_private_key[:]), string(base_point[:])
	result := handshake.x25519_public_key[:]
	if handshake.cryptography.x25519(&scalar, &point, &result, error) != 32 {
		return tls_fail(handshake, error, .Internal_Error, .Refused)
	}
	return true
}

// shared_secret_and_handshake_keys computes the X25519 shared secret with
// the key share of the peer, then the handshake secrets from the transcript
// of the two Hello messages. A key share of small order gives
// illegal_parameter.
@(private)
shared_secret_and_handshake_keys :: proc "contextless" (handshake: ^Tls_Handshake, peer_key_share: []u8, error: ^errors.Error_Record) -> bool {
	shared: [32]u8
	defer secret_erase(&shared, size_of(shared))
	scalar, point := string(handshake.x25519_private_key[:]), string(peer_key_share)
	result := shared[:]
	if handshake.cryptography.x25519(&scalar, &point, &result, error) != 32 {
		return tls_fail(handshake, error, .Illegal_Parameter, .Bad_Value)
	}
	secret_erase(&handshake.x25519_private_key, size_of(handshake.x25519_private_key))
	hash: [HASH_SIZE]u8
	if !transcript_hash(handshake, &hash, error) || !key_schedule_handshake(handshake.cryptography, &handshake.schedule, shared[:], hash[:], error) {
		return tls_fail(handshake, error, .Internal_Error, .Refused)
	}
	handshake.handshake_keys_ready = true
	return true
}

// tls_start begins a handshake. A client writes its ClientHello at the
// Initial level; a server waits for one. The generator gives the random
// values and the key share, with the least seed strength that the
// configuration asks.
tls_start :: proc "contextless" (handshake: ^Tls_Handshake, configuration: ^Tls_Configuration, cryptography: ^Cryptography, generator: ^random.Generator, error: ^errors.Error_Record) -> bool {
	handshake^ = {configuration = configuration^, cryptography = cryptography, generator = generator}
	// QUIC asks for a seed of the processor at least: a configuration that
	// leaves the field at its zero value would accept a weak seed for its
	// keys.
	if configuration.least_seed_strength < .Processor {
		return tls_fail(handshake, error, .Internal_Error, .Bad_Value, int(configuration.least_seed_strength))
	}
	// A client with no pinned key (32 zeros, a point of small order) could
	// never verify a server: it is refused here, with its own reason.
	if configuration.role == .Client && configuration.server_public_key == ([ED25519_KEY_SIZE]u8{}) {
		return tls_fail(handshake, error, .Internal_Error, .Empty)
	}
	if configuration.application_protocol_length < 1 || configuration.application_protocol_length > APPLICATION_PROTOCOL_LIMIT || configuration.transport_parameters_length < 0 || configuration.transport_parameters_length > TRANSPORT_PARAMETERS_LIMIT {
		return tls_fail(handshake, error, .Internal_Error, .Bad_Value)
	}
	if configuration.role == .Server {
		// The public key that the Certificate carries, from the private key.
		secret := string(handshake.configuration.server_private_key[:])
		result := handshake.server_public_key[:]
		if cryptography.ed25519_public_key(&secret, &result, error) != ED25519_KEY_SIZE {
			return tls_fail(handshake, error, .Internal_Error, .Refused)
		}
		handshake.state = .Server_Waits_For_Client_Hello
		return true
	}
	if !random.fill_for_a_key(generator, handshake.client_random[:], configuration.least_seed_strength, error) {
		handshake.state = .Failed
		handshake.alert = .Internal_Error
		return false
	}
	if !key_share_make(handshake, error) {
		return false
	}
	message: [LEVEL_BUFFER_SIZE]u8
	writer := Writer{bytes = message[:]}
	write_integer(&writer, int(Handshake_Message.Client_Hello), 1)
	body := vector_start(&writer, 3)
	write_integer(&writer, TLS_LEGACY_VERSION, 2)
	write_bytes(&writer, handshake.client_random[:])
	write_integer(&writer, 0, 1) // legacy_session_id: empty (RFC 9001, section 8.4).
	write_integer(&writer, 4, 2)
	write_integer(&writer, TLS_SUITE_CHACHA20_POLY1305_SHA256, 2)
	write_integer(&writer, TLS_SUITE_AES_128_GCM_SHA256, 2)
	write_integer(&writer, 1, 1)
	write_integer(&writer, 0, 1) // legacy_compression_methods: null only.
	extensions := vector_start(&writer, 2)
	write_extension_supported_versions_of_a_client(&writer)
	write_integer(&writer, int(Extension.Supported_Groups), 2)
	write_integer(&writer, 4, 2)
	write_integer(&writer, 2, 2)
	write_integer(&writer, TLS_GROUP_X25519, 2)
	write_integer(&writer, int(Extension.Signature_Algorithms), 2)
	write_integer(&writer, 4, 2)
	write_integer(&writer, 2, 2)
	write_integer(&writer, TLS_SIGNATURE_ED25519, 2)
	write_integer(&writer, int(Extension.Key_Share), 2)
	share := vector_start(&writer, 2)
	shares := vector_start(&writer, 2)
	write_integer(&writer, TLS_GROUP_X25519, 2)
	write_integer(&writer, 32, 2)
	write_bytes(&writer, handshake.x25519_public_key[:])
	vector_end(&writer, shares, 2)
	vector_end(&writer, share, 2)
	write_integer(&writer, int(Extension.Server_Certificate_Type), 2)
	write_integer(&writer, 2, 2)
	write_integer(&writer, 1, 1)
	write_integer(&writer, CERTIFICATE_TYPE_RAW_PUBLIC_KEY, 1)
	write_extension_application_protocol(&writer, &handshake.configuration)
	write_extension_transport_parameters(&writer, &handshake.configuration)
	vector_end(&writer, extensions, 2)
	vector_end(&writer, body, 3)
	if writer.failed {
		return tls_fail(handshake, error, .Internal_Error, .Too_Long)
	}
	if !message_send(handshake, .Initial, message[:writer.position], error) {
		return false
	}
	handshake.state = .Client_Waits_For_Server_Hello
	return true
}

@(private)
write_extension_supported_versions_of_a_client :: proc "contextless" (writer: ^Writer) {
	write_integer(writer, int(Extension.Supported_Versions), 2)
	write_integer(writer, 3, 2)
	write_integer(writer, 2, 1)
	write_integer(writer, TLS_VERSION_1_3, 2)
}

@(private)
write_extension_application_protocol :: proc "contextless" (writer: ^Writer, configuration: ^Tls_Configuration) {
	write_integer(writer, int(Extension.Application_Protocol), 2)
	data := vector_start(writer, 2)
	list := vector_start(writer, 2)
	write_integer(writer, configuration.application_protocol_length, 1)
	write_bytes(writer, configuration.application_protocol[:configuration.application_protocol_length])
	vector_end(writer, list, 2)
	vector_end(writer, data, 2)
}

@(private)
write_extension_transport_parameters :: proc "contextless" (writer: ^Writer, configuration: ^Tls_Configuration) {
	write_integer(writer, int(Extension.Quic_Transport_Parameters), 2)
	write_integer(writer, configuration.transport_parameters_length, 2)
	write_bytes(writer, configuration.transport_parameters[:configuration.transport_parameters_length])
}

// application_protocol_matches reads the extension of ALPN: a list of
// protocol names. One name of the list must be the name of the
// configuration; exactly_one asks that the list holds that one name only
// (the answer of a server).
@(private)
application_protocol_matches :: proc "contextless" (configuration: ^Tls_Configuration, data: []u8, exactly_one: bool) -> (matches: bool, well_formed: bool) {
	reader := Reader{bytes = data}
	list := read_vector(&reader, 2)
	if !read_done(&reader) || len(list) == 0 {
		return false, false
	}
	names := Reader{bytes = list}
	count := 0
	own := configuration.application_protocol[:configuration.application_protocol_length]
	for names.position < len(list) {
		name := read_vector(&names, 1)
		if names.failed || len(name) == 0 {
			return false, false
		}
		count += 1
		if string(name) == string(own) {
			matches = true
		}
	}
	if exactly_one && count != 1 {
		return false, false
	}
	return matches, true
}

// transport_parameters_take checks the form of the transport parameters of
// the peer (each parameter a variable-length identifier, a variable-length
// length and that many bytes; RFC 9000, section 18) and keeps them for the
// transport. The transport reads their values.
@(private)
transport_parameters_take :: proc "contextless" (handshake: ^Tls_Handshake, data: []u8, error: ^errors.Error_Record) -> bool {
	if len(data) > TRANSPORT_PARAMETERS_LIMIT {
		return tls_fail(handshake, error, .Illegal_Parameter, .Too_Long, len(data))
	}
	position := 0
	for position < len(data) {
		_, identifier_size, identifier_ok := variable_length_integer_read(data, position)
		if !identifier_ok {
			return tls_fail(handshake, error, .Decode_Error, .Bad_Value, position)
		}
		length, length_size, length_ok := variable_length_integer_read(data, position + identifier_size)
		if !length_ok || length > u64(len(data) - position - identifier_size - length_size) {
			return tls_fail(handshake, error, .Decode_Error, .Bad_Value, position)
		}
		position += identifier_size + length_size + int(length)
	}
	handshake.peer_transport_parameters_length = copy(handshake.peer_transport_parameters[:], data)
	return true
}

// tls_receive takes handshake bytes of the peer at a level, in order (the
// transport puts the CRYPTO frames in order), and reads each whole message.
// It writes the answers in the bytes to send, and makes the keys of each
// level ready. false: the handshake failed; handshake.alert is the alert to
// send in CONNECTION_CLOSE.
tls_receive :: proc "contextless" (handshake: ^Tls_Handshake, level: Encryption_Level, bytes: []u8, error: ^errors.Error_Record) -> bool {
	if handshake.state == .Failed {
		return tls_fail(handshake, error, handshake.alert == .None ? Alert.Internal_Error : handshake.alert, .State)
	}
	if level > .Application {
		return tls_fail(handshake, error, .Internal_Error, .Bad_Value, int(level))
	}
	if level < tls_receive_level(handshake.state) && len(bytes) > 0 {
		handshake.bytes_after_key_change = true
		return tls_fail(handshake, error, .Unexpected_Message, .State, int(level))
	}
	input := &handshake.received[level]
	if len(bytes) > LEVEL_BUFFER_SIZE - input.length {
		return tls_fail(handshake, error, .Unexpected_Message, .Too_Long, len(bytes))
	}
	copy(input.bytes[input.length:], bytes)
	input.length += len(bytes)
	for input.length >= MESSAGE_HEADER_SIZE {
		length := int(input.bytes[1]) << 16 | int(input.bytes[2]) << 8 | int(input.bytes[3])
		if length > LEVEL_BUFFER_SIZE - MESSAGE_HEADER_SIZE {
			return tls_fail(handshake, error, .Decode_Error, .Too_Long, 1)
		}
		if MESSAGE_HEADER_SIZE + length > input.length {
			return true // The rest of the message comes later.
		}
		message := input.bytes[:MESSAGE_HEADER_SIZE + length]
		if !message_read(handshake, level, message, error) {
			return false
		}
		rest := input.length - len(message)
		copy(input.bytes[:], input.bytes[len(message):input.length])
		input.length = rest
		if rest > 0 && tls_receive_level(handshake.state) > level {
			// The message moved the handshake to the keys of the next
			// level, and bytes of this level are left.
			handshake.bytes_after_key_change = true
			return tls_fail(handshake, error, .Unexpected_Message, .State, rest)
		}
	}
	return true
}

// message_read reads one whole message of the peer at a level, in the
// state of the handshake.
@(private)
message_read :: proc "contextless" (handshake: ^Tls_Handshake, level: Encryption_Level, message: []u8, error: ^errors.Error_Record) -> bool {
	type := Handshake_Message(message[0])
	body := message[MESSAGE_HEADER_SIZE:]
	Expected :: struct {
		state: Tls_State,
		level: Encryption_Level,
		type:  Handshake_Message,
	}
	expected := [?]Expected {
		{.Server_Waits_For_Client_Hello, .Initial, .Client_Hello},
		{.Client_Waits_For_Server_Hello, .Initial, .Server_Hello},
		{.Client_Waits_For_Encrypted_Extensions, .Handshake, .Encrypted_Extensions},
		{.Client_Waits_For_Certificate, .Handshake, .Certificate},
		{.Client_Waits_For_Certificate_Verify, .Handshake, .Certificate_Verify},
		{.Client_Waits_For_Finished, .Handshake, .Finished},
		{.Server_Waits_For_Finished, .Handshake, .Finished},
	}
	for item in expected {
		if item.state == handshake.state && item.level == level && item.type == type {
			switch handshake.state {
			case .Server_Waits_For_Client_Hello:
				return client_hello_read(handshake, message, body, error)
			case .Client_Waits_For_Server_Hello:
				return server_hello_read(handshake, message, body, error)
			case .Client_Waits_For_Encrypted_Extensions:
				return encrypted_extensions_read(handshake, message, body, error)
			case .Client_Waits_For_Certificate:
				return certificate_read(handshake, message, body, error)
			case .Client_Waits_For_Certificate_Verify:
				return certificate_verify_read(handshake, message, body, error)
			case .Client_Waits_For_Finished:
				return server_finished_read(handshake, message, body, error)
			case .Server_Waits_For_Finished:
				return client_finished_read(handshake, message, body, error)
			case .Start, .Connected, .Failed:
			}
		}
	}
	// A message of another type, at another level, or after the end: no
	// session ticket is used, and QUIC forbids KeyUpdate (RFC 9001, section
	// 6). A ticket of the server after the end is taken and dropped.
	if handshake.state == .Connected && handshake.configuration.role == .Client && level == .Application && type == .New_Session_Ticket {
		return true
	}
	return tls_fail(handshake, error, .Unexpected_Message, .State, int(type))
}

// client_hello_read: the server reads the ClientHello, chooses, and answers
// with ServerHello at the Initial level, then EncryptedExtensions,
// Certificate, CertificateVerify and Finished at the Handshake level.
@(private)
client_hello_read :: proc "contextless" (handshake: ^Tls_Handshake, message: []u8, body: []u8, error: ^errors.Error_Record) -> bool {
	reader := Reader{bytes = body}
	legacy_version := read_integer(&reader, 2)
	read_bytes(&reader, 32) // The random of the client: in the transcript only.
	session := read_vector(&reader, 1)
	suites := read_vector(&reader, 2)
	compressions := read_vector(&reader, 1)
	block := read_vector(&reader, 2)
	if !read_done(&reader) || len(suites) == 0 || len(suites) % 2 != 0 {
		return tls_fail(handshake, error, .Decode_Error, .Bad_Value, reader.position)
	}
	if legacy_version != TLS_LEGACY_VERSION {
		return tls_fail(handshake, error, .Protocol_Version, .Unsupported, 0)
	}
	if len(session) != 0 {
		// RFC 9001, section 8.4: a QUIC client does not ask for the
		// compatibility mode of TLS.
		return tls_fail(handshake, error, .Illegal_Parameter, .Bad_Value, 34)
	}
	if len(compressions) != 1 || compressions[0] != 0 {
		return tls_fail(handshake, error, .Illegal_Parameter, .Bad_Value, 0)
	}
	// The suite: ChaCha20-Poly1305 when the client offers it, else AES.
	chacha, aes := false, false
	for index := 0; index < len(suites); index += 2 {
		suite := int(suites[index]) << 8 | int(suites[index + 1])
		chacha ||= suite == TLS_SUITE_CHACHA20_POLY1305_SHA256
		aes ||= suite == TLS_SUITE_AES_128_GCM_SHA256
	}
	switch {
	case chacha:
		handshake.suite = .ChaCha20_Poly1305_Sha256
	case aes:
		handshake.suite = .Aes_128_Gcm_Sha256
	case:
		return tls_fail(handshake, error, .Handshake_Failure, .Unsupported, 0)
	}
	extensions: Extensions
	// Each extension that this side knows may come in a ClientHello; one that
	// it does not know is skipped.
	if !extensions_read(handshake, block, ~bit_set[Extension]{}, true, &extensions, error) {
		return false
	}
	required := bit_set[Extension]{.Supported_Versions, .Supported_Groups, .Signature_Algorithms, .Key_Share, .Server_Certificate_Type, .Application_Protocol, .Quic_Transport_Parameters}
	if required - extensions.present != {} {
		return tls_fail(handshake, error, .Missing_Extension, .Absent, 0)
	}
	if has, ok := list_has(extensions.data[.Supported_Versions], 1, 2, TLS_VERSION_1_3); !ok || !has {
		return tls_fail(handshake, error, ok ? Alert.Protocol_Version : Alert.Decode_Error, ok ? errors.Kind.Unsupported : errors.Kind.Bad_Value)
	}
	if has, ok := list_has(extensions.data[.Supported_Groups], 2, 2, TLS_GROUP_X25519); !ok || !has {
		return tls_fail(handshake, error, ok ? Alert.Handshake_Failure : Alert.Decode_Error, ok ? errors.Kind.Unsupported : errors.Kind.Bad_Value)
	}
	if has, ok := list_has(extensions.data[.Signature_Algorithms], 2, 2, TLS_SIGNATURE_ED25519); !ok || !has {
		return tls_fail(handshake, error, ok ? Alert.Handshake_Failure : Alert.Decode_Error, ok ? errors.Kind.Unsupported : errors.Kind.Bad_Value)
	}
	if has, ok := list_has(extensions.data[.Server_Certificate_Type], 1, 1, CERTIFICATE_TYPE_RAW_PUBLIC_KEY); !ok || !has {
		return tls_fail(handshake, error, ok ? Alert.Unsupported_Certificate : Alert.Decode_Error, ok ? errors.Kind.Unsupported : errors.Kind.Bad_Value)
	}
	if matches, ok := application_protocol_matches(&handshake.configuration, extensions.data[.Application_Protocol], false); !ok || !matches {
		return tls_fail(handshake, error, ok ? Alert.No_Application_Protocol : Alert.Decode_Error, ok ? errors.Kind.Unsupported : errors.Kind.Bad_Value)
	}
	// The key share of X25519 in the list of the client.
	peer_key_share: []u8
	shares_reader := Reader{bytes = extensions.data[.Key_Share]}
	shares := read_vector(&shares_reader, 2)
	if !read_done(&shares_reader) {
		return tls_fail(handshake, error, .Decode_Error, .Bad_Value)
	}
	entries := Reader{bytes = shares}
	for entries.position < len(shares) {
		group := read_integer(&entries, 2)
		key := read_vector(&entries, 2)
		if entries.failed {
			return tls_fail(handshake, error, .Decode_Error, .Bad_Value)
		}
		if group == TLS_GROUP_X25519 {
			if peer_key_share != nil || len(key) != 32 {
				return tls_fail(handshake, error, .Illegal_Parameter, .Bad_Value)
			}
			peer_key_share = key
		}
	}
	if peer_key_share == nil {
		// A HelloRetryRequest would ask for it: this handshake does not send
		// one.
		return tls_fail(handshake, error, .Handshake_Failure, .Unsupported)
	}
	if !transport_parameters_take(handshake, extensions.data[.Quic_Transport_Parameters], error) {
		return false
	}
	server_random: [32]u8
	if !random.fill_for_a_key(handshake.generator, server_random[:], handshake.configuration.least_seed_strength, error) {
		handshake.state = .Failed
		handshake.alert = .Internal_Error
		return false
	}
	if !key_share_make(handshake, error) || !transcript_add(handshake, message, error) {
		return false
	}
	// ServerHello.
	hello: [256]u8
	writer := Writer{bytes = hello[:]}
	write_integer(&writer, int(Handshake_Message.Server_Hello), 1)
	body_place := vector_start(&writer, 3)
	write_integer(&writer, TLS_LEGACY_VERSION, 2)
	write_bytes(&writer, server_random[:])
	write_integer(&writer, 0, 1) // The empty legacy_session_id of the client, echoed.
	write_integer(&writer, handshake.suite == .ChaCha20_Poly1305_Sha256 ? TLS_SUITE_CHACHA20_POLY1305_SHA256 : TLS_SUITE_AES_128_GCM_SHA256, 2)
	write_integer(&writer, 0, 1)
	server_extensions := vector_start(&writer, 2)
	write_integer(&writer, int(Extension.Supported_Versions), 2)
	write_integer(&writer, 2, 2)
	write_integer(&writer, TLS_VERSION_1_3, 2)
	write_integer(&writer, int(Extension.Key_Share), 2)
	write_integer(&writer, 2 + 2 + 32, 2)
	write_integer(&writer, TLS_GROUP_X25519, 2)
	write_integer(&writer, 32, 2)
	write_bytes(&writer, handshake.x25519_public_key[:])
	vector_end(&writer, server_extensions, 2)
	vector_end(&writer, body_place, 3)
	if writer.failed || !message_send(handshake, .Initial, hello[:writer.position], error) {
		return writer.failed ? tls_fail(handshake, error, .Internal_Error, .Too_Long) : false
	}
	if !shared_secret_and_handshake_keys(handshake, peer_key_share, error) {
		return false
	}
	return server_flight_send(handshake, error)
}

// server_flight_send writes EncryptedExtensions, Certificate,
// CertificateVerify and Finished at the Handshake level, then makes the
// application secrets ready.
@(private)
server_flight_send :: proc "contextless" (handshake: ^Tls_Handshake, error: ^errors.Error_Record) -> bool {
	buffer: [LEVEL_BUFFER_SIZE]u8
	// EncryptedExtensions: ALPN, the certificate type, the transport
	// parameters.
	writer := Writer{bytes = buffer[:]}
	write_integer(&writer, int(Handshake_Message.Encrypted_Extensions), 1)
	body := vector_start(&writer, 3)
	block := vector_start(&writer, 2)
	write_extension_application_protocol(&writer, &handshake.configuration)
	write_integer(&writer, int(Extension.Server_Certificate_Type), 2)
	write_integer(&writer, 1, 2)
	write_integer(&writer, CERTIFICATE_TYPE_RAW_PUBLIC_KEY, 1)
	write_extension_transport_parameters(&writer, &handshake.configuration)
	vector_end(&writer, block, 2)
	vector_end(&writer, body, 3)
	if writer.failed || !message_send(handshake, .Handshake, buffer[:writer.position], error) {
		return writer.failed ? tls_fail(handshake, error, .Internal_Error, .Too_Long) : false
	}
	// Certificate: an empty request context, one entry with the raw public
	// key and no extension.
	writer = Writer{bytes = buffer[:]}
	write_integer(&writer, int(Handshake_Message.Certificate), 1)
	body = vector_start(&writer, 3)
	write_integer(&writer, 0, 1)
	list := vector_start(&writer, 3)
	write_integer(&writer, PUBLIC_KEY_INFORMATION_SIZE, 3)
	write_bytes(&writer, ED25519_PUBLIC_KEY_INFORMATION_PREFIX[:])
	write_bytes(&writer, handshake.server_public_key[:])
	write_integer(&writer, 0, 2)
	vector_end(&writer, list, 3)
	vector_end(&writer, body, 3)
	if writer.failed || !message_send(handshake, .Handshake, buffer[:writer.position], error) {
		return writer.failed ? tls_fail(handshake, error, .Internal_Error, .Too_Long) : false
	}
	// CertificateVerify: the signature of the transcript to the Certificate.
	content: [SIGNATURE_CONTENT_SIZE]u8
	if !signature_content(handshake, &content, error) {
		return false
	}
	signature: [ED25519_SIGNATURE_SIZE]u8
	secret, signed := string(handshake.configuration.server_private_key[:]), string(content[:])
	result := signature[:]
	if handshake.cryptography.ed25519_sign(&secret, &signed, &result, error) != ED25519_SIGNATURE_SIZE {
		return tls_fail(handshake, error, .Internal_Error, .Refused)
	}
	writer = Writer{bytes = buffer[:]}
	write_integer(&writer, int(Handshake_Message.Certificate_Verify), 1)
	body = vector_start(&writer, 3)
	write_integer(&writer, TLS_SIGNATURE_ED25519, 2)
	write_integer(&writer, ED25519_SIGNATURE_SIZE, 2)
	write_bytes(&writer, signature[:])
	vector_end(&writer, body, 3)
	if writer.failed || !message_send(handshake, .Handshake, buffer[:writer.position], error) {
		return writer.failed ? tls_fail(handshake, error, .Internal_Error, .Too_Long) : false
	}
	// Finished of the server, then the application secrets.
	if !finished_send(handshake, handshake.schedule.server_handshake_traffic[:], error) {
		return false
	}
	hash: [HASH_SIZE]u8
	if !transcript_hash(handshake, &hash, error) || !key_schedule_application(handshake.cryptography, &handshake.schedule, hash[:], error) {
		return tls_fail(handshake, error, .Internal_Error, .Refused)
	}
	handshake.application_keys_ready = true
	handshake.state = .Server_Waits_For_Finished
	return true
}

SIGNATURE_CONTENT_SIZE :: 64 + len(SERVER_SIGNATURE_CONTEXT) + 1 + HASH_SIZE

// signature_content writes what CertificateVerify signs (RFC 8446, section
// 4.4.3): 64 spaces, the context string, a zero byte, the transcript hash.
@(private)
signature_content :: proc "contextless" (handshake: ^Tls_Handshake, content: ^[SIGNATURE_CONTENT_SIZE]u8, error: ^errors.Error_Record) -> bool {
	for index in 0 ..< 64 {
		content[index] = 0x20
	}
	copy(content[64:], SERVER_SIGNATURE_CONTEXT)
	content[64 + len(SERVER_SIGNATURE_CONTEXT)] = 0
	hash: [HASH_SIZE]u8
	if !transcript_hash(handshake, &hash, error) {
		return false
	}
	copy(content[64 + len(SERVER_SIGNATURE_CONTEXT) + 1:], hash[:])
	return true
}

// finished_send writes a Finished at the Handshake level with the traffic
// secret of the sender.
@(private)
finished_send :: proc "contextless" (handshake: ^Tls_Handshake, traffic_secret: []u8, error: ^errors.Error_Record) -> bool {
	hash, verify_data: [HASH_SIZE]u8
	if !transcript_hash(handshake, &hash, error) || !finished_verify_data(handshake.cryptography, traffic_secret, hash[:], &verify_data, error) {
		return tls_fail(handshake, error, .Internal_Error, .Refused)
	}
	message: [MESSAGE_HEADER_SIZE + HASH_SIZE]u8
	message[0] = u8(Handshake_Message.Finished)
	message[3] = HASH_SIZE
	copy(message[MESSAGE_HEADER_SIZE:], verify_data[:])
	return message_send(handshake, .Handshake, message[:], error)
}

// finished_check compares the verify_data of a Finished of the peer with
// the value of the transcript before it, in a time that depends on the
// length only.
@(private)
finished_check :: proc "contextless" (handshake: ^Tls_Handshake, body: []u8, traffic_secret: []u8, error: ^errors.Error_Record) -> bool {
	if len(body) != HASH_SIZE {
		return tls_fail(handshake, error, .Decode_Error, .Bad_Value, len(body))
	}
	hash, expected: [HASH_SIZE]u8
	if !transcript_hash(handshake, &hash, error) || !finished_verify_data(handshake.cryptography, traffic_secret, hash[:], &expected, error) {
		return tls_fail(handshake, error, .Internal_Error, .Refused)
	}
	difference: u8
	for index in 0 ..< HASH_SIZE {
		difference |= expected[index] ~ body[index]
	}
	if difference != 0 {
		return tls_fail(handshake, error, .Decrypt_Error, .Not_Authentic)
	}
	return true
}

// server_hello_read: the client reads the ServerHello and makes the
// handshake keys.
@(private)
server_hello_read :: proc "contextless" (handshake: ^Tls_Handshake, message: []u8, body: []u8, error: ^errors.Error_Record) -> bool {
	reader := Reader{bytes = body}
	legacy_version := read_integer(&reader, 2)
	server_random := read_bytes(&reader, 32)
	session := read_vector(&reader, 1)
	suite := read_integer(&reader, 2)
	compression := read_integer(&reader, 1)
	block := read_vector(&reader, 2)
	if !read_done(&reader) {
		return tls_fail(handshake, error, .Decode_Error, .Bad_Value, reader.position)
	}
	if string(server_random) == string(HELLO_RETRY_REQUEST_RANDOM[:]) {
		// The client offered its one group: a HelloRetryRequest asks for
		// what this handshake does not have.
		return tls_fail(handshake, error, .Handshake_Failure, .Unsupported, 2)
	}
	if legacy_version != TLS_LEGACY_VERSION || len(session) != 0 || compression != 0 {
		return tls_fail(handshake, error, .Illegal_Parameter, .Bad_Value)
	}
	switch suite {
	case TLS_SUITE_CHACHA20_POLY1305_SHA256:
		handshake.suite = .ChaCha20_Poly1305_Sha256
	case TLS_SUITE_AES_128_GCM_SHA256:
		handshake.suite = .Aes_128_Gcm_Sha256
	case:
		return tls_fail(handshake, error, .Illegal_Parameter, .Bad_Value, suite)
	}
	extensions: Extensions
	if !extensions_read(handshake, block, {.Supported_Versions, .Key_Share}, false, &extensions, error) {
		return false
	}
	if extensions.present != {.Supported_Versions, .Key_Share} {
		return tls_fail(handshake, error, .Missing_Extension, .Absent)
	}
	versions := Reader{bytes = extensions.data[.Supported_Versions]}
	if read_integer(&versions, 2) != TLS_VERSION_1_3 || !read_done(&versions) {
		return tls_fail(handshake, error, .Illegal_Parameter, .Bad_Value)
	}
	share := Reader{bytes = extensions.data[.Key_Share]}
	group := read_integer(&share, 2)
	key := read_vector(&share, 2)
	if !read_done(&share) || group != TLS_GROUP_X25519 || len(key) != 32 {
		return tls_fail(handshake, error, .Illegal_Parameter, .Bad_Value)
	}
	if !transcript_add(handshake, message, error) || !shared_secret_and_handshake_keys(handshake, key, error) {
		return false
	}
	handshake.state = .Client_Waits_For_Encrypted_Extensions
	return true
}

// encrypted_extensions_read: the protocol that the server chose, the type
// of its certificate, and its transport parameters.
@(private)
encrypted_extensions_read :: proc "contextless" (handshake: ^Tls_Handshake, message: []u8, body: []u8, error: ^errors.Error_Record) -> bool {
	reader := Reader{bytes = body}
	block := read_vector(&reader, 2)
	if !read_done(&reader) {
		return tls_fail(handshake, error, .Decode_Error, .Bad_Value)
	}
	extensions: Extensions
	if !extensions_read(handshake, block, {.Application_Protocol, .Server_Certificate_Type, .Quic_Transport_Parameters}, false, &extensions, error) {
		return false
	}
	if .Application_Protocol not_in extensions.present {
		// RFC 9001, section 8.1: a server that chose no protocol.
		return tls_fail(handshake, error, .No_Application_Protocol, .Absent)
	}
	if matches, ok := application_protocol_matches(&handshake.configuration, extensions.data[.Application_Protocol], true); !ok || !matches {
		return tls_fail(handshake, error, ok ? Alert.Illegal_Parameter : Alert.Decode_Error, .Bad_Value)
	}
	if .Server_Certificate_Type not_in extensions.present {
		// No answer means X.509 (RFC 7250, section 4.2), which this
		// handshake does not read.
		return tls_fail(handshake, error, .Unsupported_Certificate, .Unsupported)
	}
	type := extensions.data[.Server_Certificate_Type]
	if len(type) != 1 || type[0] != CERTIFICATE_TYPE_RAW_PUBLIC_KEY {
		return tls_fail(handshake, error, .Unsupported_Certificate, .Unsupported)
	}
	if .Quic_Transport_Parameters not_in extensions.present {
		return tls_fail(handshake, error, .Missing_Extension, .Absent)
	}
	if !transport_parameters_take(handshake, extensions.data[.Quic_Transport_Parameters], error) || !transcript_add(handshake, message, error) {
		return false
	}
	handshake.state = .Client_Waits_For_Certificate
	return true
}

// certificate_read: one raw public key, which must be the pinned key.
@(private)
certificate_read :: proc "contextless" (handshake: ^Tls_Handshake, message: []u8, body: []u8, error: ^errors.Error_Record) -> bool {
	reader := Reader{bytes = body}
	request_context := read_vector(&reader, 1)
	list := read_vector(&reader, 3)
	if !read_done(&reader) || len(request_context) != 0 {
		return tls_fail(handshake, error, .Decode_Error, .Bad_Value)
	}
	entries := Reader{bytes = list}
	information := read_vector(&entries, 3)
	read_vector(&entries, 2) // The extensions of the entry: none is used.
	if !read_done(&entries) {
		// No entry, or more than one: a raw public key is one entry.
		return tls_fail(handshake, error, .Decode_Error, .Bad_Value)
	}
	if len(information) != PUBLIC_KEY_INFORMATION_SIZE || string(information[:12]) != string(ED25519_PUBLIC_KEY_INFORMATION_PREFIX[:]) {
		return tls_fail(handshake, error, .Unsupported_Certificate, .Unsupported)
	}
	if string(information[12:]) != string(handshake.configuration.server_public_key[:]) {
		// Not the key that the caller pinned: whoever holds it is not the
		// server that the caller wants.
		copy(handshake.refused_server_public_key[:], information[12:])
		return tls_fail(handshake, error, .Bad_Certificate, .Not_Authentic)
	}
	copy(handshake.server_public_key[:], information[12:])
	if !transcript_add(handshake, message, error) {
		return false
	}
	handshake.state = .Client_Waits_For_Certificate_Verify
	return true
}

// certificate_verify_read: the signature of the server over the transcript
// to its Certificate, with its key.
@(private)
certificate_verify_read :: proc "contextless" (handshake: ^Tls_Handshake, message: []u8, body: []u8, error: ^errors.Error_Record) -> bool {
	reader := Reader{bytes = body}
	algorithm := read_integer(&reader, 2)
	signature := read_vector(&reader, 2)
	if !read_done(&reader) {
		return tls_fail(handshake, error, .Decode_Error, .Bad_Value)
	}
	if algorithm != TLS_SIGNATURE_ED25519 || len(signature) != ED25519_SIGNATURE_SIZE {
		return tls_fail(handshake, error, .Illegal_Parameter, .Bad_Value)
	}
	content: [SIGNATURE_CONTENT_SIZE]u8
	if !signature_content(handshake, &content, error) {
		return false
	}
	public, signed, signature_text := string(handshake.server_public_key[:]), string(content[:]), string(signature)
	if handshake.cryptography.ed25519_verify(&public, &signed, &signature_text, error) != 0 {
		return tls_fail(handshake, error, .Decrypt_Error, .Not_Authentic)
	}
	if !transcript_add(handshake, message, error) {
		return false
	}
	handshake.state = .Client_Waits_For_Finished
	return true
}

// server_finished_read: the client checks the Finished of the server, makes
// the application secrets, and sends its own Finished.
@(private)
server_finished_read :: proc "contextless" (handshake: ^Tls_Handshake, message: []u8, body: []u8, error: ^errors.Error_Record) -> bool {
	if !finished_check(handshake, body, handshake.schedule.server_handshake_traffic[:], error) || !transcript_add(handshake, message, error) {
		return false
	}
	hash: [HASH_SIZE]u8
	if !transcript_hash(handshake, &hash, error) || !key_schedule_application(handshake.cryptography, &handshake.schedule, hash[:], error) {
		return tls_fail(handshake, error, .Internal_Error, .Refused)
	}
	if !finished_send(handshake, handshake.schedule.client_handshake_traffic[:], error) {
		return false
	}
	handshake.application_keys_ready = true
	handshake.state = .Connected
	return true
}

// client_finished_read: the server checks the Finished of the client.
@(private)
client_finished_read :: proc "contextless" (handshake: ^Tls_Handshake, message: []u8, body: []u8, error: ^errors.Error_Record) -> bool {
	if !finished_check(handshake, body, handshake.schedule.client_handshake_traffic[:], error) || !transcript_add(handshake, message, error) {
		return false
	}
	handshake.state = .Connected
	return true
}

// tls_bytes_to_send gives the handshake bytes that wait to go at a level;
// tls_bytes_sent says that the transport took count of them.
tls_bytes_to_send :: proc "contextless" (handshake: ^Tls_Handshake, level: Encryption_Level) -> []u8 {
	output := &handshake.to_send[level]
	return output.bytes[:output.length]
}

tls_bytes_sent :: proc "contextless" (handshake: ^Tls_Handshake, level: Encryption_Level, count: int) {
	output := &handshake.to_send[level]
	taken := min(max(count, 0), output.length)
	copy(output.bytes[:], output.bytes[taken:output.length])
	output.length -= taken
}

// tls_packet_keys gives the packet keys of QUIC for the Handshake or the
// Application level, in one direction, when they are ready (RFC 9001,
// section 5.1). The Initial keys come from the connection identifier
// (initial_keys).
tls_packet_keys :: proc "contextless" (handshake: ^Tls_Handshake, level: Encryption_Level, sending: bool, keys: ^Packet_Keys, error: ^errors.Error_Record) -> bool {
	keys^ = {}
	client_side := (handshake.configuration.role == .Client) == sending
	secret: []u8
	switch level {
	case .Handshake:
		if !handshake.handshake_keys_ready {
			return fail_at(error, .State, 2, int(level))
		}
		secret = client_side ? handshake.schedule.client_handshake_traffic[:] : handshake.schedule.server_handshake_traffic[:]
	case .Application:
		if !handshake.application_keys_ready {
			return fail_at(error, .State, 2, int(level))
		}
		secret = client_side ? handshake.schedule.client_application_traffic[:] : handshake.schedule.server_application_traffic[:]
	case .Initial:
		return fail_at(error, .Bad_Value, 2, int(level))
	}
	return packet_keys_from_secret(handshake.cryptography, handshake.suite, secret, keys, error)
}
