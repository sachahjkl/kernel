package quic

// The keys of packet protection (RFC 9001, section 5): the procedures of the
// module `cryptography` that the library calls, the derivation of keys with
// HKDF-Expand-Label, the Initial keys from a connection identifier, and the
// integrity tag of a Retry packet.

import "contract:errors"

// Cryptography holds the procedures of the module `cryptography` that QUIC calls.
//
// The library has no cryptography of its own: each primitive is an export of the
// [cryptography module](term:cryptography-module). This record is the one seam between the two. A
// program fills it once from the import slots of the module, so each call is a direct call of an
// export. The host tests fill it with the same procedures of the module package. Each procedure of
// this library that needs a primitive takes a pointer to the record as its first parameter.
//
// **The form of each procedure** is the form of an export of a module: each text is a pointer to a
// string, `result` is a pointer to the slice that receives the bytes, and the number that comes
// back is the count of bytes written, or a negative number with an error record. The library
// compares that count with the size that it expects, so a short result is a failure.
//
// Each result must be **private memory of the caller**, and it is: the keys are in records of the
// program, and a packet is opened in the private copy of its datagram (`datagram_take`).
//
// It is the one place where a batch form of an export (a table of packets in one call) can take
// the place of these procedures, when the module contract describes a table as a parameter
// (docs/QUIC.md, "2. The form of the library").
Cryptography :: struct {
	// AES-128-GCM, seal: the text and its tag of 16 bytes. Key of 16 bytes, nonce of 12. It protects the
	// Initial packets, the packets of the suite `Aes_128_Gcm_Sha256`, and makes the Retry Integrity Tag.
	seal_with_aes_128_gcm:               Aead_Procedure,
	// AES-128-GCM, open: it checks the tag, then gives the text. `Not_Authentic` when the tag does not
	// verify; the result then keeps no byte of the text.
	open_with_aes_128_gcm:               Aead_Procedure,
	// ChaCha20-Poly1305, seal: key of 32 bytes, nonce of 12. It protects the packets of the suite
	// `ChaCha20_Poly1305_Sha256`, and seals the retry token of a server.
	seal_with_chacha20_poly1305:         Aead_Procedure,
	// ChaCha20-Poly1305, open: the same rules as the open with AES-128-GCM.
	open_with_chacha20_poly1305:         Aead_Procedure,
	// HKDF-Extract with SHA-256 (RFC 5869, section 2.2): 32 bytes from a salt and an input. It has no
	// error record; the library takes a count other than 32 as a refusal.
	hkdf_sha256_extract:                 proc "c" (salt, input: ^string, result: ^[]u8) -> i64,
	// HKDF-Expand with SHA-256 (RFC 5869, section 2.3): `length` bytes from a key and an info text. The
	// info is an HkdfLabel of TLS 1.3 here (`hkdf_expand_label`).
	hkdf_sha256_expand:                  proc "c" (key, info: ^string, length: i64, result: ^[]u8, error: ^errors.Error_Record) -> i64,
	// The header protection mask of the suites with AES: 5 bytes from a key of 16 bytes and a sample of
	// 16 bytes (RFC 9001, section 5.4.3).
	header_protection_mask_with_aes_128: Mask_Procedure,
	// The header protection mask of the suite with ChaCha20: 5 bytes from a key of 32 bytes and a sample
	// of 16 bytes (RFC 9001, section 5.4.4).
	header_protection_mask_with_chacha20: Mask_Procedure,
	// SHA-256: the 32 bytes of the hash of a text. The handshake of TLS hashes its transcript with it
	// (`hash_of`). The procedures from here to the end of the record serve TLS 1.3 only.
	sha256:                              proc "c" (text: ^string, result: ^[]u8) -> i64,
	// HMAC with SHA-256: 32 bytes. It makes the verify_data of a Finished message
	// (`finished_verify_data`).
	hmac_sha256:                         proc "c" (key, text: ^string, result: ^[]u8) -> i64,
	// X25519: the product of a scalar of 32 bytes and a point of 32 bytes. With the base point it gives
	// the public key of a key share; with the key share of the peer it gives the shared secret. The
	// handshake takes a refusal of a key share of the peer as illegal_parameter.
	x25519:                              proc "c" (scalar, point: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64,
	// Ed25519: the public key of 32 bytes of a private key of 32 bytes. A server computes the key that
	// its Certificate carries.
	ed25519_public_key:                  proc "c" (secret: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64,
	// Ed25519: the signature of 64 bytes of a message. A server signs its CertificateVerify.
	ed25519_sign:                        proc "c" (secret, message: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64,
	// Ed25519: the check of a signature. It gives 0 when the signature verifies, a negative number with
	// `Not_Authentic` when it does not. A client checks the CertificateVerify of the server.
	ed25519_verify:                      proc "c" (public, message, signature: ^string, error: ^errors.Error_Record) -> i64,
}

// The form of a seal or an open of the module `cryptography`, with any of its AEAD algorithms.
//
// - `key`, `nonce`: the key of the algorithm and a nonce of 12 bytes.
// - `additional`: the additional data, which is authenticated and not encrypted: 2048 bytes at
//   most.
// - `text`: the plain text of a seal, or the sealed text with its tag of an open.
// - `result`: where the bytes go. It can be the bytes of `text`: the library seals and opens a
//   packet in place.
// - `error`: the error record of a failure.
//
// **Result**: the count of bytes written: the text and 16 bytes for a seal, the sealed text minus
// 16 bytes for an open. A negative number at a failure.
Aead_Procedure :: #type proc "c" (key, nonce, additional, text: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64

// The form of a header protection mask of the module `cryptography`.
//
// - `key`: the header protection key of the suite.
// - `sample`: the `SAMPLE_SIZE` bytes of the protected packet.
// - `result`: where the `MASK_SIZE` bytes go.
// - `error`: the error record of a failure.
//
// **Result**: 5, the count of bytes of the mask, or a negative number at a failure.
Mask_Procedure :: #type proc "c" (key, sample: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64

// A cipher suite of TLS 1.3 that this library protects packets with: an AEAD algorithm and SHA-256.
//
// The suite of a `Packet_Keys` record chooses the AEAD of [packet protection](term:packet-protection)
// and the cipher of [header protection](term:header-protection).
//
// - AES-128-GCM protects each [Initial packet](term:initial-packet), whatever the handshake chooses
//   later (RFC 9001, section 5.2).
// - ChaCha20-Poly1305 is the suite that this system prefers after the handshake: its code runs 4.6
//   times faster than the portable AES here (docs/CRYPTOGRAPHY.md, section 6). A server takes it
//   when the client offers it.
//
// The value 0 is no suite: a zero `Packet_Keys` record is refused by each procedure.
//
// **What this library does not have**: TLS_AES_256_GCM_SHA384 and the two suites with AES-128-CCM.
// A client offers the two suites below only, and a server that finds neither in a ClientHello fails
// the handshake with handshake_failure.
Cipher_Suite :: enum u8 {
	Aes_128_Gcm_Sha256       = 1, // TLS_AES_128_GCM_SHA256, the suite 0x1301 of TLS (`TLS_SUITE_AES_128_GCM_SHA256`): keys of 16 bytes.
	ChaCha20_Poly1305_Sha256 = 2, // TLS_CHACHA20_POLY1305_SHA256, the suite 0x1303 of TLS (`TLS_SUITE_CHACHA20_POLY1305_SHA256`): keys of 32 bytes.
}

// The bytes of a secret of TLS 1.3 with SHA-256: 32, the size of the hash of both suites.
//
// `packet_keys_from_secret` refuses a secret of another size. The same number is `HASH_SIZE` in the
// key schedule.
SECRET_SIZE :: 32

// The bytes of the iv of packet protection: 12, the size of the nonce of both AEAD algorithms (RFC 9001, section 5.3).
IV_SIZE :: 12

// The bytes of the authentication tag of both AEAD algorithms: 16.
//
// Each protected packet ends with this tag, so its payload is 16 bytes longer than its frames. The
// Retry Integrity Tag and the tag of a retry token have the same size.
TAG_SIZE :: 16

// The bytes of the sample of header protection: 16 (RFC 9001, section 5.4.2).
//
// The sample is taken from the protected payload, 4 bytes after the start of the packet number. A
// packet too short to hold it is discarded (`header_read`).
SAMPLE_SIZE :: 16

// The bytes of the header protection mask: 5 (RFC 9001, section 5.4.1).
//
// The first byte masks the low bits of the first byte of the packet; the other 4 mask the packet
// number, which has 1 to 4 bytes.
MASK_SIZE :: 5

// The bytes of the packet protection key, and of the header protection key, of each suite.
//
// AES-128 takes 16 bytes and ChaCha20 takes 32. A `Packet_Keys` record holds 32 bytes for each key,
// and only the first bytes of this count have a meaning.
@(rodata)
packet_key_sizes := [Cipher_Suite]int {
	.Aes_128_Gcm_Sha256       = 16,
	.ChaCha20_Poly1305_Sha256 = 32,
}

// The keys of one direction of one encryption level.
//
// A connection has one such record to send and one to receive at each
// [encryption level](term:encryption-level). The three values come from one secret
// (`packet_keys_from_secret`): the secret of the Initial level comes from a connection identifier
// (`initial_keys`), and the secrets of the Handshake and the Application levels come from TLS
// (`tls_packet_keys`).
//
// A zero record has no suite: each procedure refuses it (`Bad_Value`), so keys that are not ready
// cannot protect or open a packet by mistake. The program keeps the record in its own memory and
// erases it when the level ends (RFC 9001, section 4.9; `secret_erase`).
Packet_Keys :: struct {
	suite:                 Cipher_Suite, // The AEAD and the header protection cipher of these keys. 0: the record holds no keys.
	key:                   [32]u8, // The key of the AEAD: the first `packet_key_sizes[suite]` bytes. The label "quic key".
	iv:                    [IV_SIZE]u8, // The iv: the nonce of a packet is the iv with the packet number in its last 8 bytes, by exclusive or. The label "quic iv".
	header_protection_key: [32]u8, // The key of the header protection mask: the first `packet_key_sizes[suite]` bytes. The label "quic hp". A key update does not change it.
}

// The salt of the Initial secrets of QUIC version 1 (RFC 9001, section 5.2).
//
// The salt is a public constant of the version: `initial_secrets` gives it to HKDF-Extract with the
// Destination Connection ID of the first Initial packet of the client. So whoever sees that packet
// can compute the Initial keys: they protect against a damaged or blind packet, and they prove
// nothing about the sender. Another version of QUIC has another salt.
@(rodata)
INITIAL_SALT := [20]u8{0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a}

// The key of the Retry Integrity Tag of QUIC version 1: 16 bytes of AES-128-GCM (RFC 9001, section 5.8).
//
// It is a public constant of the version, as `RETRY_NONCE` is. `retry_integrity_tag` uses the two.
@(rodata)
RETRY_KEY := [16]u8{0xbe, 0x0c, 0x69, 0x0b, 0x9f, 0x66, 0x57, 0x5a, 0x1d, 0x76, 0x6b, 0x54, 0xe3, 0x68, 0xc8, 0x4e}

// The nonce of the Retry Integrity Tag of QUIC version 1: 12 bytes (RFC 9001, section 5.8).
//
// The key and the nonce are fixed, and that is safe here only because the tag keeps nothing secret
// and encrypts no text: the Retry Pseudo-Packet is the additional data.
@(rodata)
RETRY_NONCE := [12]u8{0x46, 0x15, 0x99, 0xd3, 0x5d, 0x63, 0x2b, 0xf2, 0x23, 0x98, 0x25, 0xbb}

// The most bytes of a label of an HkdfLabel, without its prefix: 249.
//
// The length of the label is one byte in the HkdfLabel of TLS 1.3 and counts the prefix "tls13 ",
// which has 6 bytes (RFC 8446, section 7.1). The labels of this library have 12 bytes at most.
LABEL_LIMIT :: 255 - 6

// The most bytes of an HkdfLabel with an empty context: 259.
//
// 2 bytes of length, 1 byte of the length of the label, the 6 bytes of "tls13 ", `LABEL_LIMIT`
// bytes of label and 1 byte for the empty context. It is the size of the buffer that
// `hkdf_label_write` fills.
HKDF_LABEL_LIMIT :: 2 + 1 + 6 + LABEL_LIMIT + 1

// hkdf_label_write writes the HkdfLabel of TLS 1.3 with an empty context.
//
// The HkdfLabel is the info text of HKDF-Expand-Label (RFC 8446, section 7.1). QUIC derives its
// packet keys with it and an empty context (RFC 9001, section 5.1). The bytes, in this order: the
// length of the output as 2 bytes, the length of "tls13 " and the label as 1 byte, "tls13 " and the
// label, then a byte 0 for the empty context.
//
// **Parameters**
//
// - `buffer`: where the bytes go.
// - `label`: the label without its prefix, for example "quic key". `LABEL_LIMIT` bytes at most.
// - `length`: the bytes of output that the caller asks of HKDF: 1 to 65535.
//
// **Result**: the bytes written, a slice of `buffer` of 10 bytes and the label. **nil** for a label
// over `LABEL_LIMIT`, or a length out of 1 to 65535.
//
// The form with a context is `hkdf_label_with_context_write`.
hkdf_label_write :: proc "contextless" (buffer: ^[HKDF_LABEL_LIMIT]u8, label: string, length: int) -> []u8 {
	if len(label) > LABEL_LIMIT || length < 1 || length > 0xFFFF {
		return nil
	}
	buffer[0] = u8(length >> 8)
	buffer[1] = u8(length)
	buffer[2] = u8(6 + len(label))
	copy(buffer[3:], "tls13 ")
	copy(buffer[9:], label)
	buffer[9 + len(label)] = 0
	return buffer[:10 + len(label)]
}

// hkdf_expand_label gives the bytes of HKDF-Expand-Label(secret, label, "", length) with SHA-256.
//
// It is the one derivation of QUIC: each key, each iv and each Initial secret is one call (RFC
// 9001, section 5.1; RFC 8446, section 7.1). The length of the output is `len(output)`.
//
// **Parameters**
//
// - `cryptography`: the procedures of the module.
// - `secret`: the secret to expand: 32 bytes, a secret of TLS or an Initial secret.
// - `label`: the label without the prefix "tls13 ".
// - `output`: where the bytes go; its length is the length asked.
// - `error`: the error record of a failure.
//
// **Result**: true when `output` is whole. False:
//
// - `Too_Long` (argument 3): the label is over `LABEL_LIMIT`. The record holds the length of the
//   label as its value and the limit;
// - `Empty` (argument 4): the output has no byte;
// - `Too_Long` (argument 4): the output has more than 65535 bytes. The record holds its length as
//   its value and 65535 as its limit;
// - an error of HKDF-Expand of the module, with its own record.
hkdf_expand_label :: proc "contextless" (cryptography: ^Cryptography, secret: []u8, label: string, output: []u8, error: ^errors.Error_Record) -> bool {
	buffer: [HKDF_LABEL_LIMIT]u8
	hkdf_label := hkdf_label_write(&buffer, label, len(output))
	if hkdf_label == nil {
		// The label writer gives no reason: the record names the argument
		// that broke its rule, with the size that it had.
		switch {
		case len(label) > LABEL_LIMIT:
			return fail_at(error, .Too_Long, 3, len(label), LABEL_LIMIT)
		case len(output) == 0:
			return fail_at(error, .Empty, 4, 0, 0xFFFF)
		}
		return fail_at(error, .Too_Long, 4, len(output), 0xFFFF)
	}
	key := string(secret)
	info := string(hkdf_label)
	result := output
	return cryptography.hkdf_sha256_expand(&key, &info, i64(len(output)), &result, error) == i64(len(output))
}

// packet_keys_from_secret gives the key, the iv and the header protection key of one direction from its secret.
//
// Three calls of `hkdf_expand_label`, with the labels "quic key", "quic iv" and "quic hp" (RFC
// 9001, section 5.1). The size of the two keys is the size of the suite. The secret is the Initial
// secret of a side, or a traffic secret of TLS.
//
// **Parameters**
//
// - `cryptography`: the procedures of the module.
// - `suite`: the suite of the keys.
// - `secret`: the secret of the direction: `SECRET_SIZE` bytes.
// - `keys`: where the keys go.
// - `error`: the error record of a failure.
//
// **Result**: true, and `keys` holds the three values and the suite. False, and `keys` is a zero
// record, which no procedure accepts:
//
// - `Bad_Value` (argument 2): the suite is not a member of `Cipher_Suite`;
// - `Bad_Value` (argument 3): the secret does not have 32 bytes;
// - an error of the module.
//
// The caller erases the secret when it has no more use.
packet_keys_from_secret :: proc "contextless" (cryptography: ^Cryptography, suite: Cipher_Suite, secret: []u8, keys: ^Packet_Keys, error: ^errors.Error_Record) -> bool {
	keys^ = {}
	if suite != .Aes_128_Gcm_Sha256 && suite != .ChaCha20_Poly1305_Sha256 {
		return fail_at(error, .Bad_Value, 2, int(suite))
	}
	if len(secret) != SECRET_SIZE {
		return fail_at(error, .Bad_Value, 3, len(secret), SECRET_SIZE)
	}
	size := packet_key_sizes[suite]
	if !hkdf_expand_label(cryptography, secret, "quic key", keys.key[:size], error) || !hkdf_expand_label(cryptography, secret, "quic iv", keys.iv[:], error) || !hkdf_expand_label(cryptography, secret, "quic hp", keys.header_protection_key[:size], error) {
		keys^ = {}
		return false
	}
	keys.suite = suite
	return true
}

// The most bytes of a connection identifier of QUIC version 1: 20 (RFC 9000, section 17.2).
//
// A [connection identifier](term:connection-identifier) is 0 to 20 bytes. Each place that holds
// one has this size, and `header_read` refuses a longer one, for a version that it does not speak
// too. The identifiers that this library chooses have `CONNECTION_ID_SIZE` bytes.
CONNECTION_ID_LIMIT :: 20

// The three secrets of the Initial level, before the keys.
//
// `initial_secrets` fills it. A connection does not keep it: `initial_keys` makes the keys and
// erases it. It is a type of its own so that the tests compare each secret with the values of RFC
// 9001, appendix A.1.
Initial_Secrets :: struct {
	initial: [SECRET_SIZE]u8, // The initial secret: HKDF-Extract of `INITIAL_SALT` and the Destination Connection ID.
	client:  [SECRET_SIZE]u8, // The secret of the Initial packets that the client sends: the label "client in".
	server:  [SECRET_SIZE]u8, // The secret of the Initial packets that the server sends: the label "server in".
}

// initial_secrets gives the Initial secrets of a connection from a Destination Connection ID.
//
// The identifier is the Destination Connection ID of the first Initial packet of the client: a
// value that the client chose at random and that both sides know before any key exists (RFC 9001,
// section 5.2). After a Retry, the client derives the secrets again from the Source Connection ID
// of the Retry, which is its new Destination Connection ID.
//
// **Parameters**
//
// - `cryptography`: the procedures of the module.
// - `destination_connection_id`: the identifier: 0 to `CONNECTION_ID_LIMIT` bytes.
// - `secrets`: where the three secrets go.
// - `error`: the error record of a failure.
//
// **Result**: true when the three secrets are whole. False, and `secrets` is zero:
//
// - `Too_Long` (argument 2): the identifier has more than 20 bytes;
// - `Refused` (argument 1): HKDF-Extract of the module did not give 32 bytes;
// - an error of `hkdf_expand_label`.
//
// These secrets are not secret from the path: see `INITIAL_SALT`.
initial_secrets :: proc "contextless" (cryptography: ^Cryptography, destination_connection_id: []u8, secrets: ^Initial_Secrets, error: ^errors.Error_Record) -> bool {
	secrets^ = {}
	if len(destination_connection_id) > CONNECTION_ID_LIMIT {
		return fail_at(error, .Too_Long, 2, len(destination_connection_id), CONNECTION_ID_LIMIT)
	}
	salt := string(INITIAL_SALT[:])
	input := string(destination_connection_id)
	initial_result := secrets.initial[:]
	if cryptography.hkdf_sha256_extract(&salt, &input, &initial_result) != SECRET_SIZE {
		return fail_at(error, .Refused, 1, 0)
	}
	if !hkdf_expand_label(cryptography, secrets.initial[:], "client in", secrets.client[:], error) || !hkdf_expand_label(cryptography, secrets.initial[:], "server in", secrets.server[:], error) {
		secrets^ = {}
		return false
	}
	return true
}

// initial_keys gives the keys of the Initial packets of the client and of the server, and erases the secrets that made them.
//
// It is `initial_secrets`, then `packet_keys_from_secret` for each side, with AES-128-GCM: the
// suite of the Initial level never depends on the handshake. A client sends with `client` and
// opens with `server`; a server does the reverse.
//
// **Parameters**
//
// - `cryptography`: the procedures of the module.
// - `destination_connection_id`: the Destination Connection ID of the first Initial packet of the
//   client, or of the Retry (`initial_secrets`).
// - `client`, `server`: where the keys of each side go.
// - `error`: the error record of a failure.
//
// **Result**: true when both records are whole. False with the error of the step that failed; a
// record that was not made is zero.
//
// A server calls it for each Initial packet with an identifier that it does not know: about 9
// exports of the module, which is why a server spends a budget of work on it
// (docs/QUIC.md, "The budgets of work").
initial_keys :: proc "contextless" (cryptography: ^Cryptography, destination_connection_id: []u8, client, server: ^Packet_Keys, error: ^errors.Error_Record) -> bool {
	secrets: Initial_Secrets
	defer secret_erase(&secrets, size_of(secrets))
	if !initial_secrets(cryptography, destination_connection_id, &secrets, error) {
		return false
	}
	return packet_keys_from_secret(cryptography, .Aes_128_Gcm_Sha256, secrets.client[:], client, error) && packet_keys_from_secret(cryptography, .Aes_128_Gcm_Sha256, secrets.server[:], server, error)
}

// secret_erase writes 0 in each byte of a secret, with a call that the compiler cannot remove.
//
// A plain loop that writes zeros in memory that is not read again is dead code to a compiler, and
// an optimized build can drop it. The bytes are written by a procedure in assembly
// (`runtime/memory.asm`), which the compiler does not see through. The library erases each secret
// when its use ends: the Initial secrets, the shared secret of X25519, the secrets of the key
// schedule, the private keys of a handshake.
//
// **Parameters**
//
// - `data`: the first byte of the secret.
// - `count`: its bytes, most often `size_of` the value.
secret_erase :: proc "contextless" (data: rawptr, count: int) {
	erase_secret_bytes(data, count)
}

when ODIN_OS == .Freestanding {
	foreign _ {
		// The procedure of the runtime of a program of the system that writes `count` zero bytes at
		// `destination`. `secret_erase` is its one caller.
		erase_secret_bytes :: proc "c" (destination: rawptr, count: int) -> rawptr ---
	}
} else {
	foreign import memory "../../runtime/memory_for_host_tests.asm"
	@(default_calling_convention = "c")
	foreign memory {
		// The same procedure for a build on the host: the host tests and the kernel tool link the assembly
		// file of the runtime made for them.
		erase_secret_bytes :: proc(destination: rawptr, count: int) -> rawptr ---
	}
}

// The most bytes of a Retry Pseudo-Packet: 2048.
//
// The pseudo-packet is the additional data of one call of the module, which takes 2048 bytes at
// most (`ADDITIONAL_LIMIT` in `modules/cryptography`). One byte and 20 bytes are kept for the
// original Destination Connection ID, so `retry_integrity_tag` takes a Retry packet of 2027 bytes
// without its tag, 2043 with it: more than a datagram of a path of 1500 bytes.
RETRY_PSEUDO_PACKET_LIMIT :: 2048

// retry_integrity_tag gives the Retry Integrity Tag of a Retry packet without its tag.
//
// The tag is the 16 bytes of AES-128-GCM with the fixed key and nonce of version 1 (`RETRY_KEY`,
// `RETRY_NONCE`), an empty text, and the Retry Pseudo-Packet as the additional data (RFC 9001,
// section 5.8). The pseudo-packet is the length of the original Destination Connection ID as one
// byte, that identifier, then the packet.
//
// **What the tag proves.** The key is public, so the tag is not a proof of who sent the Retry. It
// ties the Retry to the identifier that the client chose: only an endpoint that saw the Initial
// packet of the client can make it. It also catches a packet that the network damaged.
//
// **Parameters**
//
// - `cryptography`: the procedures of the module.
// - `original_destination_connection_id`: the Destination Connection ID of the Initial packet that
//   the Retry answers.
// - `packet_without_tag`: the Retry packet from its first byte to the end of its token.
// - `tag`: where the 16 bytes go.
// - `error`: the error record of a failure.
//
// **Result**: true when the tag is whole. False:
//
// - `Too_Long` (argument 2): the identifier has more than `CONNECTION_ID_LIMIT` bytes;
// - `Too_Long` (argument 3): the packet has more than 2027 bytes (`RETRY_PSEUDO_PACKET_LIMIT`);
// - an error of the seal of the module.
//
// A server calls it through `retry_packet_write`, a client through `retry_integrity_check`.
retry_integrity_tag :: proc "contextless" (cryptography: ^Cryptography, original_destination_connection_id: []u8, packet_without_tag: []u8, tag: ^[TAG_SIZE]u8, error: ^errors.Error_Record) -> bool {
	if len(original_destination_connection_id) > CONNECTION_ID_LIMIT {
		return fail_at(error, .Too_Long, 2, len(original_destination_connection_id), CONNECTION_ID_LIMIT)
	}
	if len(packet_without_tag) > RETRY_PSEUDO_PACKET_LIMIT - 1 - CONNECTION_ID_LIMIT {
		return fail_at(error, .Too_Long, 3, len(packet_without_tag), RETRY_PSEUDO_PACKET_LIMIT - 1 - CONNECTION_ID_LIMIT)
	}
	pseudo_packet: [RETRY_PSEUDO_PACKET_LIMIT]u8
	pseudo_packet[0] = u8(len(original_destination_connection_id))
	copy(pseudo_packet[1:], original_destination_connection_id)
	count := 1 + len(original_destination_connection_id)
	count += copy(pseudo_packet[count:], packet_without_tag)
	key, nonce, empty := string(RETRY_KEY[:]), string(RETRY_NONCE[:]), ""
	additional := string(pseudo_packet[:count])
	result := tag[:]
	return cryptography.seal_with_aes_128_gcm(&key, &nonce, &additional, &empty, &result, error) == TAG_SIZE
}
