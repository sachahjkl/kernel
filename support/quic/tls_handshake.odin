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

// The value of the `legacy_version` field of a ClientHello and a ServerHello of TLS 1.3: 0x0303, the number of TLS 1.2.
//
// TLS 1.3 keeps this field at the old number so that old middleboxes let the handshake pass; the
// real version is in the extension `supported_versions` (RFC 8446, section 4.1.2). A ClientHello
// with another value fails with protocol_version, a ServerHello with illegal_parameter.
TLS_LEGACY_VERSION :: 0x0303

// The number of TLS 1.3 in the extension `supported_versions`: 0x0304, the one version of TLS that QUIC allows (RFC 9001, section 4.2).
//
// A client offers this version alone. A server refuses a ClientHello whose list does not hold it
// (protocol_version), and a client refuses a ServerHello that selects another one
// (illegal_parameter).
TLS_VERSION_1_3 :: 0x0304

// The number of the group X25519 in TLS: 0x001d, the one group of the key exchange of this handshake (RFC 8446, section 4.2.7).
//
// A client offers this group alone, with its key share. A server refuses a ClientHello that does
// not list it, or that has no key share for it (handshake_failure): it sends no HelloRetryRequest
// to ask for one.
TLS_GROUP_X25519 :: 0x001D

// The number of the signature scheme ed25519 in TLS: 0x0807, the one signature of this handshake (RFC 8446, section 4.2.3).
//
// The server signs its CertificateVerify with its Ed25519 key. A server refuses a ClientHello that
// does not list this scheme (handshake_failure); a client refuses a CertificateVerify with another
// one (illegal_parameter).
TLS_SIGNATURE_ED25519 :: 0x0807

// The number of the cipher suite TLS_AES_128_GCM_SHA256 in TLS: 0x1301. `Cipher_Suite.Aes_128_Gcm_Sha256` in this library.
TLS_SUITE_AES_128_GCM_SHA256 :: 0x1301

// The number of the cipher suite TLS_CHACHA20_POLY1305_SHA256 in TLS: 0x1303. `Cipher_Suite.ChaCha20_Poly1305_Sha256` in this library.
//
// A client lists it first, and a server takes it whenever a ClientHello offers it.
TLS_SUITE_CHACHA20_POLY1305_SHA256 :: 0x1303

// The number of the certificate type RawPublicKey: 2 (RFC 7250, section 3).
//
// A client offers this type alone in `server_certificate_type`, and the server answers with it. The
// Certificate of the server then holds a [raw public key](term:raw-public-key), not an X.509
// certificate.
CERTIFICATE_TYPE_RAW_PUBLIC_KEY :: 2

// The extensions of TLS that this handshake knows, by their numbers (RFC 8446, section 4.2).
//
// An extension that is a member here is known: the handshake reads it, or names it to accept or to
// refuse it. Each other number is not known. The difference matters (`extensions_read`):
//
// - in a **ClientHello**, each known extension can come, and an extension that is not known is
//   skipped: a client of another stack sends many;
// - in a **ServerHello** and in **EncryptedExtensions**, only the extensions that the member below
//   names can come. Each other one, known or not, fails with unsupported_extension: the client did
//   not offer it.
//
// A client of this handshake writes seven of them, in this order: `Supported_Versions`,
// `Supported_Groups`, `Signature_Algorithms`, `Key_Share`, `Server_Certificate_Type`,
// `Application_Protocol` and `Quic_Transport_Parameters`. A server requires these seven in a
// ClientHello (missing_extension).
Extension :: enum u16 {
	Server_Name             = 0, // `server_name` (RFC 6066). A server takes it in a ClientHello and does not read it: a key is pinned, not a name. A client does not send it.
	Supported_Groups        = 10, // `supported_groups` (RFC 8446, section 4.2.7): the groups of the key exchange. The list of a ClientHello must hold `TLS_GROUP_X25519`. A client takes it in EncryptedExtensions, where a server names the groups that it prefers, and does not read it.
	Signature_Algorithms    = 13, // `signature_algorithms` (RFC 8446, section 4.2.3): the signature schemes that the client verifies. ClientHello only; the list must hold `TLS_SIGNATURE_ED25519`.
	Application_Protocol    = 16, // `application_layer_protocol_negotiation`, ALPN (RFC 7301): the protocol names of the client in a ClientHello, the one chosen name in EncryptedExtensions. QUIC requires it (RFC 9001, section 8.1).
	Client_Certificate_Type = 19, // `client_certificate_type` (RFC 7250). A server takes it in a ClientHello and does not read it: this handshake asks no certificate of a client.
	Server_Certificate_Type = 20, // `server_certificate_type` (RFC 7250): the certificate types that the client takes in a ClientHello, the one chosen type in EncryptedExtensions. Both must be `CERTIFICATE_TYPE_RAW_PUBLIC_KEY`.
	Pre_Shared_Key          = 41, // `pre_shared_key` (RFC 8446, section 4.2.11). A server takes it in a ClientHello and does not read it: no session is resumed, and the handshake is always a full one.
	Early_Data              = 42, // `early_data` (RFC 8446, section 4.2.10). A server takes it in a ClientHello and does not read it: no 0-RTT data is accepted.
	Supported_Versions      = 43, // `supported_versions` (RFC 8446, section 4.2.1): the versions of the client in a ClientHello, the one selected version in a ServerHello. Both must be `TLS_VERSION_1_3`.
	Psk_Key_Exchange_Modes  = 45, // `psk_key_exchange_modes` (RFC 8446, section 4.2.9). A server takes it in a ClientHello and does not read it.
	Key_Share               = 51, // `key_share` (RFC 8446, section 4.2.8): the public keys of the exchange. The list of a ClientHello must hold one X25519 key of 32 bytes; a ServerHello holds the X25519 key of the server.
	Quic_Transport_Parameters = 57, // `quic_transport_parameters` (RFC 9001, section 8.2): the transport parameters of the side, in a ClientHello and in EncryptedExtensions. The handshake checks their form and keeps the bytes for the transport.
}

// The types of the handshake messages of TLS 1.3 that this handshake names (RFC 8446, section 4).
//
// Each message starts with its type as one byte and its length as 3 bytes (`MESSAGE_HEADER_SIZE`).
// A message is taken only in the state and at the encryption level where it belongs
// (`message_read`); each other message fails the handshake with unexpected_message. That is true
// of a type that is not a member too: CertificateRequest, EndOfEarlyData and each unknown type.
Handshake_Message :: enum u8 {
	Client_Hello         = 1, // ClientHello (section 4.1.2): the offer of the client, at the Initial level. `tls_start` writes it; a server reads it first.
	Server_Hello         = 2, // ServerHello (section 4.1.3): the choice of the server and its key share, at the Initial level. A ServerHello with the Random of a HelloRetryRequest is refused.
	New_Session_Ticket   = 4, // NewSessionTicket (section 4.6.1). A server of this handshake sends none. A client that is connected takes one at the Application level and drops it: no session is resumed.
	Encrypted_Extensions = 8, // EncryptedExtensions (section 4.3.1): ALPN, the certificate type and the transport parameters of the server, at the Handshake level.
	Certificate          = 11, // Certificate (section 4.4.2): one entry, the raw public key of the server, at the Handshake level.
	Certificate_Verify   = 15, // CertificateVerify (section 4.4.3): the Ed25519 signature of the server over the transcript, at the Handshake level.
	Finished             = 20, // Finished (section 4.4.4): the HMAC of the transcript, from the server then from the client, at the Handshake level.
	Key_Update           = 24, // KeyUpdate (section 4.6.3). QUIC forbids it (RFC 9001, section 6): it always fails with unexpected_message.
}

// The alerts of TLS that this handshake gives: the reason of a failure, as one byte (RFC 8446, section 6).
//
// A handshake that fails writes its [alert](term:alert) in `Tls_Handshake.alert` and in the
// `found` field of its error record. QUIC has no alert message: the transport closes the connection
// with the error code `CRYPTO_ERROR_BASE` + alert (RFC 9001, section 4.8), so the peer learns the
// reason. The names are those of the RFC: `Bad_Certificate` is bad_certificate.
//
// A handshake that failed stays failed: each later `tls_receive` gives the same alert.
Alert :: enum u8 {
	None                     = 0, // No failure. The value 0 is close_notify in TLS, which QUIC does not use.
	Unexpected_Message       = 10, // unexpected_message: a message of a type that the state does not wait for, or at the wrong encryption level; bytes at a level that the handshake left; more bytes than a level buffers.
	Handshake_Failure        = 40, // handshake_failure: the two sides share no parameters. A ClientHello with neither cipher suite, without X25519, without ed25519 or without an X25519 key share; at a client, a HelloRetryRequest.
	Bad_Certificate          = 42, // bad_certificate: the key of the server is not the pinned key. `Tls_Handshake.refused_server_public_key` holds the key that came.
	Unsupported_Certificate  = 43, // unsupported_certificate: the client did not offer the raw public key type, the server did not answer with it, or the entry of the Certificate is not an Ed25519 SubjectPublicKeyInfo of 44 bytes.
	Illegal_Parameter        = 47, // illegal_parameter: a field that is well formed and has a wrong value: an extension that comes two times, a session identifier that is not empty (in a ClientHello the transport closes with PROTOCOL_VIOLATION instead), a compression method, a key share of another size or of small order, a ServerHello that selects what was not offered, transport parameters over `TRANSPORT_PARAMETERS_LIMIT`.
	Decode_Error             = 50, // decode_error: a message that is malformed: a length that passes its bytes, bytes left after the last field, a list of a wrong size, a message over 4096 bytes, more than `EXTENSION_TYPES_LIMIT` extensions.
	Decrypt_Error            = 51, // decrypt_error: the signature of CertificateVerify or the verify_data of a Finished does not verify.
	Protocol_Version         = 70, // protocol_version: a ClientHello whose `legacy_version` is not 0x0303, or whose `supported_versions` does not hold TLS 1.3.
	Internal_Error           = 80, // internal_error: this side failed by itself: a configuration that `tls_start` refuses, a random seed that is too weak, a refusal of the module, a buffer of the handshake that is full.
	Missing_Extension        = 109, // missing_extension: a required extension is absent from a ClientHello, a ServerHello or EncryptedExtensions.
	Unsupported_Extension    = 110, // unsupported_extension: a ServerHello or EncryptedExtensions holds an extension that the client did not offer.
	No_Application_Protocol  = 120, // no_application_protocol: the ClientHello does not name the protocol of the server, or EncryptedExtensions names none (RFC 9001, section 8.1).
}

// An encryption level of QUIC: Initial, Handshake or Application.
//
// An [encryption level](term:encryption-level) is one set of packet keys. The handshake moves
// through the three in order, and the CRYPTO frames of each level carry their own sequence of
// handshake bytes, from offset 0 (RFC 9001, section 4). So each call of this handshake that takes
// or gives bytes names a level: `tls_receive`, `tls_bytes_to_send`, `tls_packet_keys`.
//
// The order of the members is the order of the levels: the handshake compares them to refuse the
// bytes of a level that it left (`tls_receive_level`). There is no member for 0-RTT, which this
// library does not do.
Encryption_Level :: enum u8 {
	Initial     = 0, // The keys from a connection identifier (`initial_keys`). It carries ClientHello and ServerHello.
	Handshake   = 1, // The keys from the handshake traffic secrets. It carries EncryptedExtensions, Certificate, CertificateVerify and both Finished messages.
	Application = 2, // The 1-RTT keys, from the application traffic secrets. It carries the streams; of TLS, only a NewSessionTicket that a client drops.
}

// The side of a handshake: the client, which starts it, or the server, which proves its key.
//
// The role is in `Tls_Configuration.role`. It chooses the first state of the handshake, which
// secret is the sending one (`tls_packet_keys`), and which transport parameters a side can send
// (`transport_parameters_read`).
Tls_Role :: enum u8 {
	Client, // The side that writes the ClientHello and pins the key of the server. The zero value: a configuration with no role is a client.
	Server, // The side that holds an Ed25519 private key and signs the handshake with it.
}

// The state of a handshake: the message that the side waits for, or its end.
//
// The handshake is one state machine for both roles. Each state but the first and the last two
// waits for exactly one message at one encryption level (`message_read`); that message moves the
// handshake to the next state, and each other message fails it.
//
// - A **client** goes through `Client_Waits_For_Server_Hello`,
//   `Client_Waits_For_Encrypted_Extensions`, `Client_Waits_For_Certificate`,
//   `Client_Waits_For_Certificate_Verify` and `Client_Waits_For_Finished`, then `Connected`.
// - A **server** goes through `Server_Waits_For_Client_Hello` and `Server_Waits_For_Finished`, then
//   `Connected`.
// - Each failure goes to `Failed`, from any state.
Tls_State :: enum u8 {
	Start, // A zero record: `tls_start` was not called. `tls_receive` fails each message in this state.
	Client_Waits_For_Server_Hello, // The client wrote its ClientHello and waits for the ServerHello, at the Initial level.
	Client_Waits_For_Encrypted_Extensions, // The client has the handshake keys and waits for EncryptedExtensions, at the Handshake level.
	Client_Waits_For_Certificate, // The client waits for the Certificate with the raw public key of the server.
	Client_Waits_For_Certificate_Verify, // The key is the pinned key; the client waits for the signature that proves that the server holds its private key.
	Client_Waits_For_Finished, // The client waits for the Finished of the server. After it the client writes its own Finished and is connected.
	Server_Waits_For_Client_Hello, // The server waits for the ClientHello, at the Initial level. It wrote nothing yet.
	Server_Waits_For_Finished, // The server wrote its whole flight and has its application secrets; it waits for the Finished of the client, at the Handshake level.
	Connected, // The handshake is complete: both Finished messages verified. A client still takes a NewSessionTicket and drops it; each other message fails the handshake.
	Failed, // The handshake failed: `Tls_Handshake.alert` holds the reason, and the secrets were erased. Each later `tls_receive` fails again.
}

// The most bytes of one protocol name of ALPN: 255 (RFC 7301).
//
// The length of a name is one byte on the wire. `tls_start` refuses a configuration whose name has
// no byte or more than this.
APPLICATION_PROTOCOL_LIMIT :: 255

// The most bytes of the `quic_transport_parameters` of one side that this handshake carries: 512.
//
// The parameters of this library take under 100 bytes. A peer that sends more than 512 bytes fails
// the handshake with illegal_parameter (`transport_parameters_take`).
TRANSPORT_PARAMETERS_LIMIT :: 512

// The handshake bytes of one encryption level that wait in a handshake, in each direction: 4096.
//
// It bounds three things:
//
// - the bytes of the peer that do not make a whole message yet: `tls_receive` fails when more
//   come (unexpected_message);
// - one message of the peer, with its header of 4 bytes: a longer one fails with decode_error. A
//   ClientHello can then have a body of 4092 bytes;
// - the bytes that this side wrote and that the transport did not take yet.
LEVEL_BUFFER_SIZE :: 4096

// The most bytes of the transcript of one handshake: 8192.
//
// The [transcript](term:transcript) holds each handshake message from the ClientHello to the
// Finished of the client, because each hash of the key schedule is a hash of all of them from the
// first. The messages of this system have under 2 KiB. A ClientHello of a peer can have 4096 bytes
// (a large key share and padding), and the flight of the server about 600 bytes more. A message
// that does not fit fails the handshake with internal_error.
TRANSCRIPT_LIMIT :: 8192

// The bytes of the header of a handshake message: 4, its type as one byte and the length of its body as 3 bytes (RFC 8446, section 4).
MESSAGE_HEADER_SIZE :: 4

// The most extensions of one extension block: 48.
//
// `extensions_read` keeps the type of each extension that it met, to refuse one that comes two
// times. A block with more types than this fails with decode_error. A ClientHello of a browser has
// about 20.
EXTENSION_TYPES_LIMIT :: 48

// The bytes of an Ed25519 key, private or public: 32.
ED25519_KEY_SIZE :: 32

// The bytes of an Ed25519 signature: 64.
ED25519_SIGNATURE_SIZE :: 64

// The bytes of the SubjectPublicKeyInfo of an Ed25519 key: 44, the 12 bytes of its prefix and the 32 bytes of the key.
//
// It is the whole content of the one entry of the Certificate of a server
// (`ED25519_PUBLIC_KEY_INFORMATION_PREFIX`).
PUBLIC_KEY_INFORMATION_SIZE :: 12 + ED25519_KEY_SIZE

// The 12 bytes of an Ed25519 SubjectPublicKeyInfo before the key (RFC 8410, section 4; RFC 7250, section 3).
//
// In DER: a sequence of 42 bytes, which holds the algorithm identifier of Ed25519 (the object
// identifier 1.3.101.112, with no parameters) and a bit string of 33 bytes, whose first byte says
// that no bit is unused. The 32 bytes of the key follow.
//
// A [raw public key](term:raw-public-key) of this handshake is these 12 bytes and the key, and
// nothing else. **No DER is parsed**: a client compares the 12 bytes with this constant, and an
// entry of another size or with another prefix fails with unsupported_certificate. So a key of
// another algorithm, or the same key in another valid encoding, is refused.
@(rodata)
ED25519_PUBLIC_KEY_INFORMATION_PREFIX := [12]u8{0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00}

// The Random of a HelloRetryRequest: the SHA-256 hash of the text "HelloRetryRequest" (RFC 8446, section 4.1.3).
//
// A HelloRetryRequest is a ServerHello with this fixed Random: a server sends it to ask the client
// for another key share. A client of this handshake offered its one group, so it has nothing else
// to give: it compares the Random of each ServerHello with this constant, and fails with
// handshake_failure when they are equal. A server of this handshake never sends one.
@(rodata)
HELLO_RETRY_REQUEST_RANDOM := [32]u8{0xcf, 0x21, 0xad, 0x74, 0xe5, 0x9a, 0x61, 0x11, 0xbe, 0x1d, 0x8c, 0x02, 0x1e, 0x65, 0xb8, 0x91, 0xc2, 0xa2, 0x11, 0x16, 0x7a, 0xbb, 0x8c, 0x5e, 0x07, 0x9e, 0x09, 0xe2, 0xc8, 0xa8, 0x33, 0x9c}

// The context string of the signature of a server in CertificateVerify (RFC 8446, section 4.4.3).
//
// The string is part of what the server signs (`signature_content`). It makes a signature of a
// handshake of no use anywhere else: a signature of a client, or of another protocol, has another
// string.
SERVER_SIGNATURE_CONTEXT :: "TLS 1.3, server CertificateVerify"

// What the caller of each side gives to a handshake: its role, its protocol, its transport parameters and its key.
//
// `tls_start` copies the record into the handshake, so the caller can change its own copy after the
// call. A zero record is not a valid configuration: `tls_start` refuses a protocol name of no byte,
// a least seed strength under `Processor`, and a client with no pinned key.
//
// **What a client sets**: `role`, `application_protocol`, `transport_parameters`,
// `server_public_key` and `least_seed_strength`. **What a server sets**: the same, with
// `server_private_key` in place of `server_public_key`.
Tls_Configuration :: struct {
	// The side of this handshake.
	role:                       Tls_Role,
	// The one protocol name of ALPN, for example "modus-remote-call". A client offers this name alone.
	// A server accepts a ClientHello only when its list holds this name, and answers with it.
	application_protocol:       [APPLICATION_PROTOCOL_LIMIT]u8,
	// The bytes of the name: 1 to `APPLICATION_PROTOCOL_LIMIT`.
	application_protocol_length: int,
	// The transport parameters of this side, encoded by the transport (`transport_parameters_write`;
	// RFC 9000, section 18). The handshake sends the bytes as they are.
	transport_parameters:       [TRANSPORT_PARAMETERS_LIMIT]u8,
	// The bytes of the parameters: 0 to `TRANSPORT_PARAMETERS_LIMIT`.
	transport_parameters_length: int,
	// The server: its Ed25519 private key, 32 bytes. Its program holds it; it never leaves the memory
	// of the program. The handshake erases its copy when it fails and when its secrets are erased
	// (`tls_handshake_erase_secrets`). A client leaves it at zero.
	server_private_key:         [ED25519_KEY_SIZE]u8,
	// The client: the [pinned key](term:pinned-key), the Ed25519 public key of the server that it
	// accepts, and no other. Its caller gives it. 32 zero bytes mean that no key was pinned:
	// `tls_start` refuses them. A server leaves it at zero: it computes its public key from its
	// private key.
	server_public_key:          [ED25519_KEY_SIZE]u8,
	// The least [seed strength](term:seed-strength) of the random generator that the caller accepts for
	// the key share and the random values (`random.fill_for_a_key`). QUIC asks for `Processor` at
	// least: `tls_start` refuses a lower value, the zero value too.
	least_seed_strength:        random.Seed_Strength,
}

// The handshake bytes of one encryption level in one direction, with their count.
//
// A `Tls_Handshake` has one for each level and direction: the bytes of the peer that wait for the
// rest of their message, and the bytes of this side that wait for the transport.
Level_Bytes :: struct {
	bytes:  [LEVEL_BUFFER_SIZE]u8, // The buffer. The bytes that wait are at its start.
	length: int, // The count of bytes that wait: 0 to `LEVEL_BUFFER_SIZE`.
}

// One handshake of TLS 1.3 as QUIC carries it: the state of one side, in memory of the caller.
//
// The record holds all of the state of the handshake: no allocation, no kernel call. It has about
// 33 KiB, most of them the transcript and the six buffers of the levels. The transport owns it and
// drives it with five calls:
//
// 1. `tls_start`: once. A client writes its ClientHello.
// 2. `tls_receive`: for the bytes of each CRYPTO frame of the peer, in order, with their level.
// 3. `tls_bytes_to_send` and `tls_bytes_sent`: after each of the two calls above, for each level.
//    The transport puts the bytes in CRYPTO frames.
// 4. `tls_packet_keys`: when `handshake_keys_ready`, then `application_keys_ready`, becomes true,
//    and before the secrets are erased.
// 5. `tls_handshake_erase_secrets`: when the transport took the application keys.
//
// ```odin
// if !tls_receive(&handshake, level, bytes, &error) {
// 	// Close the connection with CRYPTO_ERROR_BASE + handshake.alert.
// }
// if handshake.handshake_keys_ready {
// 	tls_packet_keys(&handshake, .Handshake, true, &send_keys, &error)
// }
// ```
//
// **What this handshake does**:
//
// - the group X25519 and the signature Ed25519, and no other;
// - the cipher suite TLS_CHACHA20_POLY1305_SHA256 first, TLS_AES_128_GCM_SHA256 also;
// - the proof of the server with a [raw public key](term:raw-public-key) (RFC 7250), which the
//   client compares with its [pinned key](term:pinned-key);
// - one application protocol (ALPN), and the `quic_transport_parameters` of each side.
//
// **What this handshake does not do**, as the code refuses it:
//
// - **X.509 certificates**: a server that does not answer `server_certificate_type` with the raw
//   public key fails the client (unsupported_certificate). There is no certificate authority, no
//   name and no date.
// - **HelloRetryRequest**: a server does not send one, so a ClientHello without an X25519 key share
//   fails (handshake_failure). A client that receives one fails the same way.
// - **Session resumption and 0-RTT**: a server takes `pre_shared_key`, `early_data` and
//   `psk_key_exchange_modes` in a ClientHello and does not read them; it sends no
//   NewSessionTicket. A client drops a NewSessionTicket.
// - **A certificate of the client**: a server sends no CertificateRequest, and a client that
//   receives one fails (unexpected_message).
// - **KeyUpdate**, which QUIC forbids, and the compatibility mode of TLS 1.3 for middleboxes: a
//   ServerHello with a session identifier fails (illegal_parameter), and a ClientHello with one
//   fails as a PROTOCOL_VIOLATION of QUIC (`protocol_violation`).
// - **The other groups, signatures and suites**: no P-256, no RSA, no ECDSA, no
//   TLS_AES_256_GCM_SHA384, no AES-128-CCM.
//
// See (docs/QUIC.md, "9. What is not built, and will not be in version 1 of this library").
Tls_Handshake :: struct {
	// The copy of the configuration that `tls_start` made. It holds the copy of the private key of a
	// server.
	configuration:                 Tls_Configuration,
	// The procedures of the module `cryptography`. The record that it points to must live as long as
	// the handshake.
	cryptography:                  ^Cryptography,
	// The random generator of the program: the source of the Random of each Hello and of the X25519
	// private key.
	generator:                     ^random.Generator,
	// The state of the handshake. The transport reads it: `Connected` is the end of the handshake of
	// TLS, `Failed` its failure.
	state:                         Tls_State,
	// The alert of a failure; `None` while the handshake did not fail. QUIC closes with
	// `CRYPTO_ERROR_BASE` + alert.
	alert:                         Alert,
	// The cipher suite of the connection: the server chooses it when it reads the ClientHello, the
	// client learns it from the ServerHello. It has a meaning from `handshake_keys_ready`.
	suite:                         Cipher_Suite,
	// The private key of the key share of this side: 32 random bytes. It is erased as soon as the
	// shared secret is made.
	x25519_private_key:            [32]u8,
	// The public key of the key share: the product of the private key and the base point. It goes in
	// the `key_share` of the Hello message of this side.
	x25519_public_key:             [32]u8,
	// A client: the Random of its ClientHello. A server does not use it: the Random of the client is in
	// the transcript only.
	client_random:                 [32]u8,
	// The secrets of the key schedule.
	schedule:                      Key_Schedule,
	// The handshake messages of both sides, each with its header, in the order of the handshake.
	transcript:                    [TRANSCRIPT_LIMIT]u8,
	// The bytes of the transcript: 0 to `TRANSCRIPT_LIMIT`.
	transcript_length:             int,
	// For each level: the bytes of the peer that do not make a whole message yet. A whole message
	// leaves the buffer as soon as it is read.
	received:                      [Encryption_Level]Level_Bytes,
	// For each level: the bytes of this side that the transport sends in CRYPTO frames
	// (`tls_bytes_to_send`, `tls_bytes_sent`).
	to_send:                       [Encryption_Level]Level_Bytes,
	// The `quic_transport_parameters` of the peer, as bytes whose form was checked. The transport
	// decodes them with `transport_parameters_read`. A server has them after the ClientHello, a client
	// after EncryptedExtensions.
	peer_transport_parameters:     [TRANSPORT_PARAMETERS_LIMIT]u8,
	// The bytes of those parameters: 0 to `TRANSPORT_PARAMETERS_LIMIT`.
	peer_transport_parameters_length: int,
	// The server: its own Ed25519 public key, which `tls_start` computes from its private key. The
	// client: the key of the Certificate of the server, once it equals the pinned key.
	server_public_key:             [ED25519_KEY_SIZE]u8,
	// The client: the key that a server presented and that is not the pinned key (alert
	// bad_certificate). It is a public value: the caller says which key came, so that a reader sees a
	// stale pin at once. All zeros when no key was refused.
	refused_server_public_key:     [ED25519_KEY_SIZE]u8,
	// The two handshake traffic secrets exist: `tls_packet_keys` gives the keys of the Handshake level.
	// It is false again once the secrets are erased.
	handshake_keys_ready:          bool,
	// The two application traffic secrets exist: `tls_packet_keys` gives the 1-RTT keys. A server has
	// them after it wrote its Finished, a client after it wrote its own. It is false again once the
	// secrets are erased.
	application_keys_ready:        bool,
	// The failure is a PROTOCOL_VIOLATION of QUIC, not an alert of TLS: the transport reads this field
	// after a failure, and closes with that code. Two faults set it: bytes of the peer at a level
	// after the keys of the next level were in use (RFC 9001, section 4.1.3), and a ClientHello with
	// a session identifier, which asks for the compatibility mode of TLS (RFC 9001, section 8.4).
	protocol_violation:            bool,
}

// tls_receive_level gives the encryption level at which the peer sends its next message in a state.
//
// The handshake uses it to refuse the bytes of a level that it left: once a message moved it to
// the next level, bytes of an earlier level can only be a mistake of the peer or a forgery (RFC
// 9001, section 4.1.3).
//
// **Result**: `Handshake` in the five states that wait for a message of the Handshake level;
// `Application` when the handshake is connected; `Initial` in each other state, the first one and
// the failed one too.
tls_receive_level :: proc "contextless" (state: Tls_State) -> Encryption_Level {
	#partial switch state {
	case .Client_Waits_For_Encrypted_Extensions, .Client_Waits_For_Certificate, .Client_Waits_For_Certificate_Verify, .Client_Waits_For_Finished, .Server_Waits_For_Finished:
		return .Handshake
	case .Connected:
		return .Application
	}
	return .Initial
}

// tls_fail ends a handshake with an alert and an error record, erases its secrets, and gives false.
//
// Each failing path of the handshake is `return tls_fail(...)`. It keeps four things true at each
// failure: the state is `Failed`, `Tls_Handshake.alert` holds the reason, the record of the caller
// says where, and no secret stays in the handshake (`tls_handshake_erase_secrets`).
//
// **Parameters**
//
// - `handshake`: the handshake that fails.
// - `error`: the error record to fill. It replaces a record that a call before wrote.
// - `alert`: the alert of TLS.
// - `kind`: the error kind of the record, for example `Bad_Value` or `Not_Authentic`.
// - `value`: where the fault is: an offset in the message, a size, or the wrong value.
// - `argument`: the number of the argument at fault, as the caller of `tls_start` or of
//   `tls_receive` sees it. 3, the bytes of `tls_receive`, when it is not given: most failures are
//   a message of the peer. 2 for the configuration of `tls_start` and for the level of
//   `tls_receive`. 0 for a failure that no argument caused: a refusal of the module, a buffer of
//   the handshake with no room, a handshake that failed before.
//
// **The record**: the unit `Bytes`, `argument`, `value`, and the alert in `found`.
//
// **Result**: always false.
@(private)
tls_fail :: proc "contextless" (handshake: ^Tls_Handshake, error: ^errors.Error_Record, alert: Alert, kind: errors.Kind, value: int = 0, argument: i64 = 3) -> bool {
	handshake.state = .Failed
	handshake.alert = alert
	errors.fail(error, -1, kind, .Bytes, argument, i64(value), 0, i64(alert))
	tls_handshake_erase_secrets(handshake)
	return false
}

// tls_handshake_erase_secrets erases each secret of a handshake.
//
// It writes zeros over the X25519 private key, the whole key schedule and the copy of the Ed25519
// private key of a server (`secret_erase`). The handshake calls it at each failure. The transport
// calls it when it took the application keys, and when it ends a connection: after that no secret
// of TLS is in the record, only public values.
//
// **Call it only after the last `tls_packet_keys`.** The two flags that say that the keys are
// ready become false, because the secrets no longer exist: a later call of `tls_packet_keys` fails
// with `State`, and never gives keys of a secret of zeros.
//
// It is safe to call it two times, and on a handshake that never started.
tls_handshake_erase_secrets :: proc "contextless" (handshake: ^Tls_Handshake) {
	handshake.handshake_keys_ready = false
	handshake.application_keys_ready = false
	secret_erase(&handshake.x25519_private_key, size_of(handshake.x25519_private_key))
	secret_erase(&handshake.schedule, size_of(handshake.schedule))
	secret_erase(&handshake.configuration.server_private_key, size_of(handshake.configuration.server_private_key))
}

// A reader of the bytes of one message of the peer, which never reads past their end.
//
// Each read checks its length first. A read past the end reads nothing, sets `failed` and gives
// zeros or nil, and each later read does the same. So the reader of a message reads all its fields
// in a row and checks once, with `read_done`, that the reads fit and that no byte is left.
@(private)
Reader :: struct {
	bytes:    []u8, // The bytes of the message, or of one field that holds a list.
	position: int, // The offset of the next byte to read.
	failed:   bool, // A read passed the end: the message is malformed.
}

// read_integer reads an unsigned integer of `size` bytes, the most significant byte first.
//
// TLS writes each number that way. It gives 0 and sets `failed` when `size` bytes are not left.
// The callers ask for 1, 2 or 3 bytes.
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

// read_bytes reads `count` bytes, and gives them as a slice of the bytes of the reader.
//
// No byte is copied. It gives nil and sets `failed` when `count` is negative or more than the
// bytes that are left.
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

// read_vector reads a vector of TLS: a length of `length_size` bytes, then that many bytes.
//
// TLS writes each field of a variable size that way (RFC 8446, section 3.4). The result is a slice
// of the bytes of the reader, or nil with `failed` set when the length passes the end.
@(private)
read_vector :: proc "contextless" (reader: ^Reader, length_size: int) -> []u8 {
	return read_bytes(reader, read_integer(reader, length_size))
}

// read_done says that each read fit and that the reader is at the end of its bytes.
//
// A message with bytes after its last field is malformed, as a message that is cut: the reader of
// each message answers both with decode_error.
@(private)
read_done :: proc "contextless" (reader: ^Reader) -> bool {
	return !reader.failed && reader.position == len(reader.bytes)
}

// A writer of the bytes of one message into a buffer, which never writes past its end.
//
// A write with no room writes nothing and sets `failed`, and each later write does nothing. The
// writer of a message writes all its fields in a row and checks `failed` once.
@(private)
Writer :: struct {
	bytes:    []u8, // The buffer of the message.
	position: int, // The bytes written so far: at the end, the length of the message.
	failed:   bool, // A write had no room: the message is not whole.
}

// write_integer writes an unsigned integer in `size` bytes, the most significant byte first.
//
// It sets `failed` when `size` bytes are not left. The caller gives a value that fits the size.
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

// write_bytes writes bytes as they are. It sets `failed` and writes nothing when they do not fit.
@(private)
write_bytes :: proc "contextless" (writer: ^Writer, bytes: []u8) {
	if writer.failed || len(bytes) > len(writer.bytes) - writer.position {
		writer.failed = true
		return
	}
	copy(writer.bytes[writer.position:], bytes)
	writer.position += len(bytes)
}

// vector_start writes a length of `length_size` bytes to fill later, and gives its place.
//
// The length of a vector of TLS comes before its bytes, and the writer knows it only after it
// wrote them. So it writes zeros, writes the content, then calls `vector_end` with the place: the
// pair nests, as the extensions nest in a message.
@(private)
vector_start :: proc "contextless" (writer: ^Writer, length_size: int) -> int {
	place := writer.position
	write_integer(writer, 0, length_size)
	return place
}

// vector_end writes the length of a vector that `vector_start` opened at `place`.
//
// The length is the bytes written since the place, without the length field itself. It sets
// `failed` when that count does not fit in `length_size` bytes.
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

// The extensions of one extension block, read once.
//
// `extensions_read` fills it. The reader of a message then asks which extensions are present, and
// reads the data of each one.
@(private)
Extensions :: struct {
	data:    #sparse[Extension][]u8, // For each known extension that came: its data, a slice of the message. nil for one that did not come.
	present: bit_set[Extension], // The known extensions that came. An extension with no data is present too.
}

// extensions_read reads an extension block, and refuses each extension that the message cannot hold.
//
// An extension block is a row of extensions: for each one a type of 2 bytes, then its data as a
// vector with a length of 2 bytes (RFC 8446, section 4.2).
//
// **Parameters**
//
// - `handshake`: the handshake, which fails here when the block is wrong.
// - `block`: the bytes of the block, without its own length.
// - `known`: the members of `Extension` that this message can hold.
// - `unknown_allowed`: true for a ClientHello, where an extension that is not a member of
//   `Extension` is skipped. False for a message of a server, where it is refused.
// - `extensions`: where the data of each extension goes.
// - `error`: the error record of a failure.
//
// **Result**: true when the block is whole and each extension is allowed. False, with the offset
// of the extension in the block as the value of the record:
//
// - decode_error: an extension is cut, or the block has more than `EXTENSION_TYPES_LIMIT`
//   extensions;
// - illegal_parameter: one type comes two times, a known type or not;
// - unsupported_extension: a known type that is not in `known`, or a type that is not known when
//   `unknown_allowed` is false.
//
// It does not check that a required extension came: the caller reads `present`.
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

// list_has says if a list of numbers of a fixed size holds one value.
//
// Several extensions are such a list: a length of `length_size` bytes, then values of `value_size`
// bytes each (the versions, the groups, the signature schemes, the certificate types).
//
// **Results**
//
// - `has`: the list holds `value`.
// - `ok`: the list is well formed. False when its length passes the data, when bytes follow it,
//   when it is empty, or when its length is not a multiple of `value_size`.
//
// The caller answers a malformed list with decode_error, and a list without the value with the
// alert of that extension.
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

// message_send adds a whole message of this side to the transcript and to the bytes to send at a level.
//
// Each message that this side writes goes through it, so no message can go on the wire without
// being in the transcript: the two would then disagree with the peer, and the Finished messages
// would fail.
//
// **Result**: true. False, with internal_error and `Full`, when the transcript or the buffer of
// the level has no room for the message.
@(private)
message_send :: proc "contextless" (handshake: ^Tls_Handshake, level: Encryption_Level, message: []u8, error: ^errors.Error_Record) -> bool {
	if !transcript_add(handshake, message, error) {
		return false
	}
	output := &handshake.to_send[level]
	if len(message) > LEVEL_BUFFER_SIZE - output.length {
		return tls_fail(handshake, error, .Internal_Error, .Full, len(message), 0)
	}
	copy(output.bytes[output.length:], message)
	output.length += len(message)
	return true
}

// transcript_add appends one whole message, with its header, to the transcript.
//
// The reader of each message of the peer calls it only after it accepted the message. False, with
// internal_error and `Full`, when the message does not fit in `TRANSCRIPT_LIMIT`.
@(private)
transcript_add :: proc "contextless" (handshake: ^Tls_Handshake, message: []u8, error: ^errors.Error_Record) -> bool {
	if len(message) > TRANSCRIPT_LIMIT - handshake.transcript_length {
		return tls_fail(handshake, error, .Internal_Error, .Full, len(message), 0)
	}
	copy(handshake.transcript[handshake.transcript_length:], message)
	handshake.transcript_length += len(message)
	return true
}

// transcript_hash gives the SHA-256 hash of the transcript as it is now.
//
// The whole transcript is hashed at each call: the handshake keeps the messages, not a running
// hash, because the module gives a hash of a whole text. False, with internal_error, when the
// module refuses.
@(private)
transcript_hash :: proc "contextless" (handshake: ^Tls_Handshake, output: ^[HASH_SIZE]u8, error: ^errors.Error_Record) -> bool {
	if !hash_of(handshake.cryptography, handshake.transcript[:handshake.transcript_length], output) {
		return tls_fail(handshake, error, .Internal_Error, .Refused, argument = 0)
	}
	return true
}

// key_share_make draws the X25519 private key of this side and computes its public key.
//
// The private key is 32 random bytes from the generator of the program, with the least seed
// strength of the configuration (`random.fill_for_a_key`). The public key is the product of the
// private key and the base point of the curve, the point 9.
//
// **Result**: true when both keys are in the handshake. False:
//
// - the seed of the generator is weaker than the configuration asks: the state is `Failed`, the
//   alert internal_error, and the record is the one of the generator (`Seed_Too_Weak`). No byte
//   was drawn;
// - the module refused the product: internal_error.
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
		return tls_fail(handshake, error, .Internal_Error, .Refused, argument = 0)
	}
	return true
}

// shared_secret_and_handshake_keys computes the X25519 shared secret, then the handshake secrets.
//
// Each side calls it when the transcript holds exactly ClientHello and ServerHello. It multiplies
// the private key of this side by the key share of the peer, erases the private key, hashes the
// transcript and runs `key_schedule_handshake`. Then it sets `handshake_keys_ready`. The shared
// secret is erased before the return.
//
// **Parameters**
//
// - `handshake`: the handshake.
// - `peer_key_share`: the 32 bytes of the X25519 key of the peer.
// - `error`: the error record of a failure.
//
// **Result**: true. False:
//
// - illegal_parameter: the module refused the key share of the peer: a point of small order, whose
//   shared secret would be all zeros;
// - internal_error: the hash or the key schedule failed.
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
		return tls_fail(handshake, error, .Internal_Error, .Refused, argument = 0)
	}
	handshake.handshake_keys_ready = true
	return true
}

// tls_start begins a handshake: a client writes its ClientHello, a server waits for one.
//
// It makes the record new: each field of an earlier handshake is gone. It copies the configuration
// and checks it, then:
//
// - a **server** computes its Ed25519 public key from its private key, and waits
//   (`Server_Waits_For_Client_Hello`);
// - a **client** draws its Random and its X25519 key share, writes its ClientHello in the bytes to
//   send of the Initial level, and waits for the ServerHello.
//
// **Parameters**
//
// - `handshake`: the record of the handshake, in memory of the caller.
// - `configuration`: the role, the protocol, the transport parameters and the key of this side.
// - `cryptography`: the procedures of the module.
// - `generator`: the random generator of the program.
// - `error`: the error record of a failure.
//
// **The ClientHello of a client** (RFC 8446, section 4.1.2): the legacy version 0x0303, the Random,
// an empty session identifier (RFC 9001, section 8.4), the two cipher suites with
// ChaCha20-Poly1305 first, the null compression, then seven extensions: `supported_versions` with
// TLS 1.3, `supported_groups` with X25519, `signature_algorithms` with ed25519, `key_share` with
// one X25519 key, `server_certificate_type` with the raw public key, ALPN with the one name, and
// `quic_transport_parameters`. It has no `server_name` and no padding.
//
// **Result**: true when the handshake started. False, with the state `Failed` and the alert
// internal_error (nothing is sent to a peer):
//
// - `Bad_Value`, argument 2: the least seed strength of the configuration is under `Processor`.
//   A field left at its zero value would accept a weak seed for the keys. The record holds the
//   strength as its value;
// - `Empty`, argument 2: a client whose pinned key is 32 zero bytes. No key was pinned, and such
//   a client could never verify a server;
// - `Bad_Value`, argument 2: the protocol name does not have 1 to `APPLICATION_PROTOCOL_LIMIT`
//   bytes, or the transport parameters have more than `TRANSPORT_PARAMETERS_LIMIT`. The record
//   holds the count of bytes at fault as its value;
// - `Refused`, argument 0: the module did not give the public key of the server, or the key
//   share;
// - `Seed_Too_Weak`, the record of the generator: the seed of the program is weaker than the
//   configuration asks. A server meets this later, when it reads the ClientHello.
tls_start :: proc "contextless" (handshake: ^Tls_Handshake, configuration: ^Tls_Configuration, cryptography: ^Cryptography, generator: ^random.Generator, error: ^errors.Error_Record) -> bool {
	handshake^ = {configuration = configuration^, cryptography = cryptography, generator = generator}
	// QUIC asks for a seed of the processor at least: a configuration that
	// leaves the field at its zero value would accept a weak seed for its
	// keys.
	if configuration.least_seed_strength < .Processor {
		return tls_fail(handshake, error, .Internal_Error, .Bad_Value, int(configuration.least_seed_strength), 2)
	}
	// A client with no pinned key (32 zeros, a point of small order) could
	// never verify a server: it is refused here, with its own reason.
	if configuration.role == .Client && configuration.server_public_key == ([ED25519_KEY_SIZE]u8{}) {
		return tls_fail(handshake, error, .Internal_Error, .Empty, 0, 2)
	}
	if configuration.application_protocol_length < 1 || configuration.application_protocol_length > APPLICATION_PROTOCOL_LIMIT {
		return tls_fail(handshake, error, .Internal_Error, .Bad_Value, configuration.application_protocol_length, 2)
	}
	if configuration.transport_parameters_length < 0 || configuration.transport_parameters_length > TRANSPORT_PARAMETERS_LIMIT {
		return tls_fail(handshake, error, .Internal_Error, .Bad_Value, configuration.transport_parameters_length, 2)
	}
	if configuration.role == .Server {
		// The public key that the Certificate carries, from the private key.
		secret := string(handshake.configuration.server_private_key[:])
		result := handshake.server_public_key[:]
		if cryptography.ed25519_public_key(&secret, &result, error) != ED25519_KEY_SIZE {
			return tls_fail(handshake, error, .Internal_Error, .Refused, argument = 0)
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
		return tls_fail(handshake, error, .Internal_Error, .Too_Long, argument = 0)
	}
	if !message_send(handshake, .Initial, message[:writer.position], error) {
		return false
	}
	handshake.state = .Client_Waits_For_Server_Hello
	return true
}

// write_extension_supported_versions_of_a_client writes the extension `supported_versions` of a ClientHello: a list with TLS 1.3 alone.
//
// The form of a server is another one (the selected version, with no list), which the writer of
// the ServerHello writes itself.
@(private)
write_extension_supported_versions_of_a_client :: proc "contextless" (writer: ^Writer) {
	write_integer(writer, int(Extension.Supported_Versions), 2)
	write_integer(writer, 3, 2)
	write_integer(writer, 2, 1)
	write_integer(writer, TLS_VERSION_1_3, 2)
}

// write_extension_application_protocol writes the extension of ALPN with the one protocol name of the configuration.
//
// The form is the same in a ClientHello and in EncryptedExtensions: a list of names, each with a
// length of one byte (RFC 7301). Here the list has one name: the offer of a client, and the choice
// of a server.
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

// write_extension_transport_parameters writes the extension `quic_transport_parameters` with the bytes of the configuration.
//
// The handshake does not read these bytes: the transport encoded them (RFC 9001, section 8.2).
@(private)
write_extension_transport_parameters :: proc "contextless" (writer: ^Writer, configuration: ^Tls_Configuration) {
	write_integer(writer, int(Extension.Quic_Transport_Parameters), 2)
	write_integer(writer, configuration.transport_parameters_length, 2)
	write_bytes(writer, configuration.transport_parameters[:configuration.transport_parameters_length])
}

// application_protocol_matches reads the extension of ALPN, and says if it names the protocol of the configuration.
//
// The data is a list of protocol names, each with a length of one byte.
//
// **Parameters**
//
// - `configuration`: the configuration, with the name of this side.
// - `data`: the data of the extension.
// - `exactly_one`: true for the answer of a server, which must hold one name. False for the offer
//   of a client, which can hold several.
//
// **Results**
//
// - `matches`: one name of the list is the name of the configuration, byte for byte.
// - `well_formed`: false for a list that is cut, that is empty, that holds an empty name, or that
//   holds another count than one name when `exactly_one`.
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

// transport_parameters_take checks the form of the transport parameters of the peer, and keeps them for the transport.
//
// The handshake does not know the parameters; it checks only that the bytes are a row of
// parameters, each one a variable-length identifier, a variable-length length and that many bytes
// (RFC 9000, section 18). The transport reads the values later, with `transport_parameters_read`,
// from `Tls_Handshake.peer_transport_parameters`.
//
// **Result**: true when the bytes are kept. False:
//
// - illegal_parameter (`Too_Long`): more than `TRANSPORT_PARAMETERS_LIMIT` bytes;
// - decode_error: an identifier or a length is cut, or a length passes the end.
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

// tls_receive takes handshake bytes of the peer at one encryption level, and reads each whole message that they complete.
//
// The transport calls it with the bytes of the CRYPTO frames of a level, **in order**: the
// handshake has no offsets, so the transport puts the frames in order first. The bytes can end
// anywhere: a message that is not whole waits in the handshake for the rest. Each whole message is
// read in the state of the handshake (`message_read`): it can move the state, write answers in the
// bytes to send, and make the keys of the next level ready.
//
// **Parameters**
//
// - `handshake`: the handshake.
// - `level`: the encryption level of the packet that carried the bytes.
// - `bytes`: the bytes, the next ones of the level. No byte is valid, and changes nothing.
// - `error`: the error record of a failure.
//
// **Result**: true when the bytes were taken, a part of a message too. After a true result the
// caller reads `tls_bytes_to_send` for each level, and the two flags of the keys.
//
// False: the handshake failed. `handshake.alert` is the alert for the CONNECTION_CLOSE, the record
// holds it in `found`, and the secrets are erased. The failures of this procedure itself:
//
// - unexpected_message (`State`): bytes came at a level below the level of the state (argument 2,
//   with the level as the value), or bytes of a level are left after the message that moved the
//   handshake to the next level (argument 3, with their count). Both set `protocol_violation`:
//   the transport closes with PROTOCOL_VIOLATION;
// - unexpected_message (`Too_Long`): more than `LEVEL_BUFFER_SIZE` bytes wait at the level;
// - decode_error (`Too_Long`): a message says that its body has more than 4092 bytes;
// - internal_error (argument 2): `level` is not a member of `Encryption_Level`;
// - the alert of the first failure, again (`State`, argument 0), when the handshake failed before.
//
// The record names argument 3, the bytes, for each fault of a message of the peer, and argument 0
// for a failure of this side that no argument caused (`tls_fail`).
//
// Each other failure is the failure of the reader of one message: see `Alert` for the alerts and
// when each one comes.
//
// **The bytes are hostile input.** Each length is checked before a byte is read, and no message is
// trusted before its Finished: the client knows its server only at `Connected`, and the transport
// must not treat a peer as known before that state.
tls_receive :: proc "contextless" (handshake: ^Tls_Handshake, level: Encryption_Level, bytes: []u8, error: ^errors.Error_Record) -> bool {
	if handshake.state == .Failed {
		return tls_fail(handshake, error, handshake.alert == .None ? Alert.Internal_Error : handshake.alert, .State, 0, 0)
	}
	if level > .Application {
		return tls_fail(handshake, error, .Internal_Error, .Bad_Value, int(level), 2)
	}
	if level < tls_receive_level(handshake.state) && len(bytes) > 0 {
		handshake.protocol_violation = true
		return tls_fail(handshake, error, .Unexpected_Message, .State, int(level), 2)
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
			handshake.protocol_violation = true
			return tls_fail(handshake, error, .Unexpected_Message, .State, rest)
		}
	}
	return true
}

// message_read reads one whole message of the peer, when the state waits for that message at that level.
//
// It is the table of the state machine: for each state that waits, the one message type and the
// one encryption level that are right. A message that matches goes to its reader; the reader
// checks it, adds it to the transcript and moves the state.
//
// **The one exception**: a client that is connected takes a NewSessionTicket at the Application
// level and drops it. No session is resumed, so the ticket has no use, and a server of another
// stack sends some.
//
// Each other message fails with unexpected_message, with its type as the value of the record: a
// message of another type, at another level, or after the end. That includes KeyUpdate, which QUIC
// forbids (RFC 9001, section 6), CertificateRequest, and each message to a server that is
// connected.
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

// client_hello_read is the server side of the handshake: it reads the ClientHello, chooses, and writes the whole flight of the server.
//
// **What it checks**, in this order, with the alert of each refusal (RFC 8446, section 4.1.2):
//
// 1. the form of the message, and a list of cipher suites that is not empty and has an even
//    length: decode_error;
// 2. the legacy version 0x0303: protocol_version;
// 3. an empty session identifier, because QUIC has no compatibility mode (RFC 9001, section 8.4).
//    A session identifier sets `protocol_violation`: the transport closes with
//    PROTOCOL_VIOLATION, not with the alert (illegal_parameter, which the record still holds);
// 4. the null compression alone: illegal_parameter;
// 5. a cipher suite of this library: handshake_failure. ChaCha20-Poly1305 wins when the client
//    offers it, in any place of its list; else AES-128-GCM;
// 6. the extension block (`extensions_read`). Each extension that is not known is skipped;
// 7. the seven required extensions: missing_extension;
// 8. TLS 1.3 in `supported_versions`: protocol_version;
// 9. X25519 in `supported_groups` and ed25519 in `signature_algorithms`: handshake_failure;
// 10. the raw public key in `server_certificate_type`: unsupported_certificate;
// 11. the protocol of the server in the list of ALPN: no_application_protocol;
// 12. one X25519 key share of 32 bytes: illegal_parameter for two of them or for another size,
//     handshake_failure for none. A HelloRetryRequest would ask for one; this handshake sends
//     none;
// 13. the form of the transport parameters (`transport_parameters_take`).
//
// A list that is malformed is decode_error in each case.
//
// **What it writes**: the ServerHello at the Initial level (the Random of the server, the chosen
// suite, `supported_versions` and its X25519 key share), then the handshake secrets
// (`shared_secret_and_handshake_keys`), then the rest of the flight at the Handshake level
// (`server_flight_send`).
//
// A seed of the program that is too weak stops the handshake before any byte is written
// (`Seed_Too_Weak`). On that path the copy of the private key of the server is not erased here:
// the transport erases it when it ends the connection.
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
		// compatibility mode of TLS, and a server treats the request as a
		// PROTOCOL_VIOLATION of QUIC. The alert stays for the record only.
		handshake.protocol_violation = true
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
		return writer.failed ? tls_fail(handshake, error, .Internal_Error, .Too_Long, argument = 0) : false
	}
	if !shared_secret_and_handshake_keys(handshake, peer_key_share, error) {
		return false
	}
	return server_flight_send(handshake, error)
}

// server_flight_send writes the four messages of a server at the Handshake level, then makes the application secrets.
//
// The messages, in the order of RFC 8446, section 4:
//
// 1. **EncryptedExtensions**: ALPN with the one name, `server_certificate_type` with the raw public
//    key, and the transport parameters of the server.
// 2. **Certificate**: an empty request context and one entry: the 44 bytes of the
//    SubjectPublicKeyInfo of the Ed25519 key, with no extension.
// 3. **CertificateVerify**: the scheme ed25519 and the signature of 64 bytes over the content of
//    `signature_content`, which holds the hash of the transcript up to the Certificate. It proves
//    that the server holds the private key of the key that it showed.
// 4. **Finished**: the HMAC of the transcript up to CertificateVerify (`finished_send`).
//
// Then it derives the two application traffic secrets from the transcript up to its own Finished
// (`key_schedule_application`), sets `application_keys_ready`, and waits for the Finished of the
// client (`Server_Waits_For_Finished`).
//
// It sends no CertificateRequest and no NewSessionTicket. Each failure is internal_error: a refusal
// of the module, or a buffer with no room.
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
		return writer.failed ? tls_fail(handshake, error, .Internal_Error, .Too_Long, argument = 0) : false
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
		return writer.failed ? tls_fail(handshake, error, .Internal_Error, .Too_Long, argument = 0) : false
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
		return tls_fail(handshake, error, .Internal_Error, .Refused, argument = 0)
	}
	writer = Writer{bytes = buffer[:]}
	write_integer(&writer, int(Handshake_Message.Certificate_Verify), 1)
	body = vector_start(&writer, 3)
	write_integer(&writer, TLS_SIGNATURE_ED25519, 2)
	write_integer(&writer, ED25519_SIGNATURE_SIZE, 2)
	write_bytes(&writer, signature[:])
	vector_end(&writer, body, 3)
	if writer.failed || !message_send(handshake, .Handshake, buffer[:writer.position], error) {
		return writer.failed ? tls_fail(handshake, error, .Internal_Error, .Too_Long, argument = 0) : false
	}
	// Finished of the server, then the application secrets.
	if !finished_send(handshake, handshake.schedule.server_handshake_traffic[:], error) {
		return false
	}
	hash: [HASH_SIZE]u8
	if !transcript_hash(handshake, &hash, error) || !key_schedule_application(handshake.cryptography, &handshake.schedule, hash[:], error) {
		return tls_fail(handshake, error, .Internal_Error, .Refused, argument = 0)
	}
	handshake.application_keys_ready = true
	handshake.state = .Server_Waits_For_Finished
	return true
}

// The bytes of what a CertificateVerify signs: 130.
//
// 64 spaces, the 33 bytes of `SERVER_SIGNATURE_CONTEXT`, one zero byte and the 32 bytes of the
// transcript hash.
SIGNATURE_CONTENT_SIZE :: 64 + len(SERVER_SIGNATURE_CONTEXT) + 1 + HASH_SIZE

// signature_content writes what the CertificateVerify of a server signs.
//
// The content is 64 bytes 0x20 (spaces), the context string of a server, one zero byte, then the
// hash of the transcript as it is now (RFC 8446, section 4.4.3). The server calls it after it
// wrote its Certificate, the client after it read it: both then hash the same messages, from
// ClientHello to Certificate. The spaces and the string keep the signature from being a valid
// signature of anything else.
//
// False, with internal_error, when the hash of the transcript fails.
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

// finished_send writes the Finished message of this side at the Handshake level.
//
// The message is 4 bytes of header and the 32 bytes of verify_data: the HMAC of the hash of the
// transcript as it is now, under the finished key of the traffic secret that the caller gives
// (`finished_verify_data`). The caller gives the handshake traffic secret of its own side.
//
// False, with internal_error, when the hash, the HMAC or the buffers fail.
@(private)
finished_send :: proc "contextless" (handshake: ^Tls_Handshake, traffic_secret: []u8, error: ^errors.Error_Record) -> bool {
	hash, verify_data: [HASH_SIZE]u8
	if !transcript_hash(handshake, &hash, error) || !finished_verify_data(handshake.cryptography, traffic_secret, hash[:], &verify_data, error) {
		return tls_fail(handshake, error, .Internal_Error, .Refused, argument = 0)
	}
	message: [MESSAGE_HEADER_SIZE + HASH_SIZE]u8
	message[0] = u8(Handshake_Message.Finished)
	message[3] = HASH_SIZE
	copy(message[MESSAGE_HEADER_SIZE:], verify_data[:])
	return message_send(handshake, .Handshake, message[:], error)
}

// finished_check says if the Finished message of the peer holds the verify_data of the transcript before it.
//
// It computes the value that the peer must have sent (`finished_verify_data`, with the handshake
// traffic secret of the peer and the hash of the transcript before the Finished), and compares the
// two with no early exit: the time does not depend on which byte differs, so the comparison tells
// an attacker nothing about the right value.
//
// **Parameters**
//
// - `handshake`: the handshake.
// - `body`: the body of the Finished message.
// - `traffic_secret`: the handshake traffic secret of the side that sent it.
// - `error`: the error record of a failure.
//
// **Result**: true when the values are equal. False:
//
// - decode_error: the body does not have 32 bytes;
// - decrypt_error (`Not_Authentic`): the values differ. The peer does not hold the handshake
//   secrets, or a message of the transcript was changed on the path;
// - internal_error: the hash or the HMAC failed.
@(private)
finished_check :: proc "contextless" (handshake: ^Tls_Handshake, body: []u8, traffic_secret: []u8, error: ^errors.Error_Record) -> bool {
	if len(body) != HASH_SIZE {
		return tls_fail(handshake, error, .Decode_Error, .Bad_Value, len(body))
	}
	hash, expected: [HASH_SIZE]u8
	if !transcript_hash(handshake, &hash, error) || !finished_verify_data(handshake.cryptography, traffic_secret, hash[:], &expected, error) {
		return tls_fail(handshake, error, .Internal_Error, .Refused, argument = 0)
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

// server_hello_read is the first step of the client side: it reads the ServerHello and makes the handshake keys.
//
// **What it checks**, with the alert of each refusal (RFC 8446, section 4.1.3):
//
// - the form of the message: decode_error;
// - a Random that is not the Random of a HelloRetryRequest: handshake_failure. The client offered
//   its one group, so it has no other key share to give;
// - the legacy version 0x0303, an empty session identifier, the null compression:
//   illegal_parameter;
// - one of the two cipher suites of this library: illegal_parameter;
// - the extensions `supported_versions` and `key_share`, both and no other: unsupported_extension
//   for another one, missing_extension for one that is absent;
// - TLS 1.3 as the selected version, and an X25519 key share of 32 bytes: illegal_parameter.
//
// Then it adds the message to the transcript, computes the shared secret and the handshake secrets
// (`shared_secret_and_handshake_keys`), and waits for EncryptedExtensions at the Handshake level.
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

// encrypted_extensions_read reads the EncryptedExtensions of the server: its protocol, the type of its certificate and its transport parameters.
//
// **What it checks**, with the alert of each refusal:
//
// - the form of the message: decode_error;
// - only the extensions that the client offered and that RFC 8446, section 4.2, lets a server
//   answer there: ALPN, `server_certificate_type`, `quic_transport_parameters` and
//   `supported_groups`. Each other extension fails with unsupported_extension. That includes
//   `server_name`, `client_certificate_type` and `early_data`: the RFC lets a server send them
//   there only as an answer, and this client offers none of them;
// - `supported_groups` is taken and not read: it names the groups that the server prefers for a
//   later connection (RFC 8446, section 4.2.7), and this client has one group;
// - ALPN is there: no_application_protocol (RFC 9001, section 8.1); it holds one name, the name of
//   the client: illegal_parameter;
// - `server_certificate_type` is there and is the raw public key: unsupported_certificate. No
//   answer means X.509 (RFC 7250, section 4.2), which this handshake does not read;
// - the transport parameters are there: missing_extension; their form is right
//   (`transport_parameters_take`).
//
// Then it adds the message to the transcript and waits for the Certificate.
@(private)
encrypted_extensions_read :: proc "contextless" (handshake: ^Tls_Handshake, message: []u8, body: []u8, error: ^errors.Error_Record) -> bool {
	reader := Reader{bytes = body}
	block := read_vector(&reader, 2)
	if !read_done(&reader) {
		return tls_fail(handshake, error, .Decode_Error, .Bad_Value)
	}
	extensions: Extensions
	// supported_groups is taken and not read: a server may name there the
	// groups that it prefers, to a client that offered the extension.
	if !extensions_read(handshake, block, {.Application_Protocol, .Server_Certificate_Type, .Quic_Transport_Parameters, .Supported_Groups}, false, &extensions, error) {
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

// certificate_read reads the Certificate of the server: one raw public key, which must be the pinned key.
//
// **What it checks**, with the alert of each refusal (RFC 8446, section 4.4.2):
//
// - an empty request context, and a list with exactly one entry: decode_error. A raw public key
//   is one entry; the extensions of the entry are read past and not used;
// - the entry is 44 bytes that start with `ED25519_PUBLIC_KEY_INFORMATION_PREFIX`:
//   unsupported_certificate;
// - the 32 bytes after the prefix equal `Tls_Configuration.server_public_key`: bad_certificate,
//   with `Not_Authentic`. The key that came is kept in
//   `Tls_Handshake.refused_server_public_key`, so that the caller can show both keys.
//
// Then the key is in `Tls_Handshake.server_public_key`, the message is in the transcript, and the
// client waits for CertificateVerify.
//
// **The key is not yet proven here.** Anyone can send the public key of the server. The proof is
// the signature of the next message, which only the holder of the private key can make.
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

// certificate_verify_read checks the signature of the server over the transcript, with the pinned key.
//
// It is the step that authenticates the server (RFC 8446, section 4.4.3). The client builds the
// signed content from its own transcript (`signature_content`), up to the Certificate, and asks
// the module to verify the signature with the key of the Certificate. A server that does not hold
// the private key cannot make it; a server whose transcript differs from the one of the client,
// because the path changed a message, cannot either.
//
// **What it checks**, with the alert of each refusal:
//
// - the form of the message: decode_error;
// - the scheme ed25519 and a signature of 64 bytes: illegal_parameter;
// - the signature: decrypt_error, with `Not_Authentic`.
//
// Then it adds the message to the transcript and waits for the Finished of the server.
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

// server_finished_read is the last step of the client side: it checks the Finished of the server, makes the application secrets, and writes its own Finished.
//
// In this order:
//
// 1. it checks the Finished of the server (`finished_check`, with the handshake traffic secret of
//    the server), and adds it to the transcript;
// 2. it derives the two application traffic secrets from the transcript up to that Finished
//    (`key_schedule_application`);
// 3. it writes the Finished of the client at the Handshake level (`finished_send`);
// 4. it sets `application_keys_ready` and the state `Connected`.
//
// For TLS the client is connected now. For QUIC the handshake is confirmed later, when the
// HANDSHAKE_DONE frame of the server comes: that is the transport's.
@(private)
server_finished_read :: proc "contextless" (handshake: ^Tls_Handshake, message: []u8, body: []u8, error: ^errors.Error_Record) -> bool {
	if !finished_check(handshake, body, handshake.schedule.server_handshake_traffic[:], error) || !transcript_add(handshake, message, error) {
		return false
	}
	hash: [HASH_SIZE]u8
	if !transcript_hash(handshake, &hash, error) || !key_schedule_application(handshake.cryptography, &handshake.schedule, hash[:], error) {
		return tls_fail(handshake, error, .Internal_Error, .Refused, argument = 0)
	}
	if !finished_send(handshake, handshake.schedule.client_handshake_traffic[:], error) {
		return false
	}
	handshake.application_keys_ready = true
	handshake.state = .Connected
	return true
}

// client_finished_read is the last step of the server side: it checks the Finished of the client.
//
// The check (`finished_check`, with the handshake traffic secret of the client) proves that the
// client holds the handshake secrets and saw the flight of the server unchanged. The message goes
// in the transcript and the state is `Connected`.
//
// It proves nothing about who the client is: this handshake asks no certificate of a client.
@(private)
client_finished_read :: proc "contextless" (handshake: ^Tls_Handshake, message: []u8, body: []u8, error: ^errors.Error_Record) -> bool {
	if !finished_check(handshake, body, handshake.schedule.client_handshake_traffic[:], error) || !transcript_add(handshake, message, error) {
		return false
	}
	handshake.state = .Connected
	return true
}

// tls_bytes_to_send gives the handshake bytes of this side that wait to go at one encryption level.
//
// The transport calls it for each level after `tls_start` and after each `tls_receive`, puts the
// bytes in CRYPTO frames of that level, then calls `tls_bytes_sent`. The bytes are whole messages,
// one after the other; the offset of the first one in the CRYPTO stream of the level is the count
// of bytes that the transport took before.
//
// **Result**: a slice of the buffer of the handshake, empty when nothing waits. It is valid until
// the next call that changes the handshake.
tls_bytes_to_send :: proc "contextless" (handshake: ^Tls_Handshake, level: Encryption_Level) -> []u8 {
	output := &handshake.to_send[level]
	return output.bytes[:output.length]
}

// tls_bytes_sent says that the transport took the first `count` bytes that waited at a level.
//
// The bytes leave the buffer of the handshake, and the bytes after them move to its start. "Took"
// means that the transport copied them into its own buffer of the CRYPTO stream: the handshake
// does not send a byte again, so the transport keeps them until the peer acknowledges them.
//
// A count below 0 is 0, and a count over the bytes that wait takes them all.
tls_bytes_sent :: proc "contextless" (handshake: ^Tls_Handshake, level: Encryption_Level, count: int) {
	output := &handshake.to_send[level]
	taken := min(max(count, 0), output.length)
	copy(output.bytes[:], output.bytes[taken:output.length])
	output.length -= taken
}

// tls_packet_keys gives the packet keys of QUIC for the Handshake or the Application level, in one direction.
//
// It is the bridge from TLS to packet protection (RFC 9001, section 5.1): it chooses the traffic
// secret of the level and of the direction, and derives the key, the iv and the header protection
// key with the suite of the handshake (`packet_keys_from_secret`).
//
// **Parameters**
//
// - `handshake`: the handshake.
// - `level`: `Handshake` or `Application`.
// - `sending`: true for the keys that protect the packets of this side, false for the keys that
//   open the packets of the peer. A client sends with the client secret; a server with the server
//   secret.
// - `keys`: where the keys go. It is zero after a failure.
// - `error`: the error record of a failure.
//
// **Result**: true when the keys are whole. False:
//
// - `State` (argument 2): the secrets of the level do not exist (`handshake_keys_ready`,
//   `application_keys_ready`): the handshake did not make them yet, or they were erased;
// - `Bad_Value` (argument 2): the level is `Initial`. The Initial keys come from a connection
//   identifier, not from TLS (`initial_keys`);
// - an error of the derivation.
//
// A failure here does not fail the handshake: the state and the alert stay as they are.
//
// **Take the keys before the secrets are erased**: after `tls_handshake_erase_secrets`, or after a
// failure of the handshake, the secrets are zeros, the flags are false, and the call fails with
// `State`.
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
