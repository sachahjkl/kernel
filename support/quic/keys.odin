package quic

// The keys of packet protection (RFC 9001, section 5): the procedures of the
// module `cryptography` that the library calls, the derivation of keys with
// HKDF-Expand-Label, the Initial keys from a connection identifier, and the
// integrity tag of a Retry packet.

import "contract:errors"

// Cryptography holds the exports of the module `cryptography` that QUIC
// calls. A program fills it from the import slots of the module (as each
// export, a direct call); the host tests fill it with the same procedures of
// the module package. It is the one place where a batch form of an export
// (a table of packets in one call) will take the place of these procedures,
// when the module contract describes a table as a parameter.
Cryptography :: struct {
	seal_with_aes_128_gcm:               Aead_Procedure,
	open_with_aes_128_gcm:               Aead_Procedure,
	seal_with_chacha20_poly1305:         Aead_Procedure,
	open_with_chacha20_poly1305:         Aead_Procedure,
	hkdf_sha256_extract:                 proc "c" (salt, input: ^string, result: ^[]u8) -> i64,
	hkdf_sha256_expand:                  proc "c" (key, info: ^string, length: i64, result: ^[]u8, error: ^errors.Error_Record) -> i64,
	header_protection_mask_with_aes_128: Mask_Procedure,
	header_protection_mask_with_chacha20: Mask_Procedure,
	// TLS 1.3 (tls_handshake.odin): the transcript hash, Finished, the key
	// exchange and the signature of the server.
	sha256:                              proc "c" (text: ^string, result: ^[]u8) -> i64,
	hmac_sha256:                         proc "c" (key, text: ^string, result: ^[]u8) -> i64,
	x25519:                              proc "c" (scalar, point: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64,
	ed25519_public_key:                  proc "c" (secret: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64,
	ed25519_sign:                        proc "c" (secret, message: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64,
	ed25519_verify:                      proc "c" (public, message, signature: ^string, error: ^errors.Error_Record) -> i64,
}

Aead_Procedure :: #type proc "c" (key, nonce, additional, text: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64
Mask_Procedure :: #type proc "c" (key, sample: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64

// The two cipher suites of TLS 1.3 that this library protects packets with.
// AES-128-GCM protects each Initial packet (RFC 9001, section 5.2);
// ChaCha20-Poly1305 is the suite that this system prefers after the
// handshake: its code runs 4.6 times faster than the portable AES here
// (docs/CRYPTOGRAPHY.md, section 6).
Cipher_Suite :: enum u8 {
	Aes_128_Gcm_Sha256       = 1, // TLS_AES_128_GCM_SHA256, 0x1301.
	ChaCha20_Poly1305_Sha256 = 2, // TLS_CHACHA20_POLY1305_SHA256, 0x1303.
}

SECRET_SIZE :: 32 // SHA-256: the hash of both suites.
IV_SIZE :: 12
TAG_SIZE :: 16
SAMPLE_SIZE :: 16
MASK_SIZE :: 5

@(rodata)
packet_key_sizes := [Cipher_Suite]int {
	.Aes_128_Gcm_Sha256       = 16,
	.ChaCha20_Poly1305_Sha256 = 32,
}

// The keys of one direction of one encryption level. A zero record has no
// suite: each procedure refuses it. The program keeps it in its own memory
// and erases it when the level ends (RFC 9001, section 4.9).
Packet_Keys :: struct {
	suite:                 Cipher_Suite,
	key:                   [32]u8, // The first packet_key_sizes[suite] bytes.
	iv:                    [IV_SIZE]u8,
	header_protection_key: [32]u8, // The first packet_key_sizes[suite] bytes.
}

// The salt of the Initial secrets of QUIC version 1 (RFC 9001, section 5.2).
@(rodata)
INITIAL_SALT := [20]u8{0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad, 0xcc, 0xbb, 0x7f, 0x0a}

// The key and the nonce of the Retry integrity tag of QUIC version 1 (RFC
// 9001, section 5.8).
@(rodata)
RETRY_KEY := [16]u8{0xbe, 0x0c, 0x69, 0x0b, 0x9f, 0x66, 0x57, 0x5a, 0x1d, 0x76, 0x6b, 0x54, 0xe3, 0x68, 0xc8, 0x4e}
@(rodata)
RETRY_NONCE := [12]u8{0x46, 0x15, 0x99, 0xd3, 0x5d, 0x63, 0x2b, 0xf2, 0x23, 0x98, 0x25, 0xbb}

LABEL_LIMIT :: 255 - 6 // The label of an HkdfLabel has 255 bytes with its prefix "tls13 ".

HKDF_LABEL_LIMIT :: 2 + 1 + 6 + LABEL_LIMIT + 1

// hkdf_label_write writes the HkdfLabel of TLS 1.3 (RFC 8446, section 7.1)
// with an empty context, as QUIC uses it (RFC 9001, section 5.1): uint16
// length, uint8 length of "tls13 " + label, "tls13 " + label, uint8 0. It
// gives the bytes, or nil for a label over LABEL_LIMIT or a length out of
// 1 to 65535.
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

// hkdf_expand_label gives len(output) bytes of HKDF-Expand-Label(secret,
// label, "", len(output)) with SHA-256.
hkdf_expand_label :: proc "contextless" (cryptography: ^Cryptography, secret: []u8, label: string, output: []u8, error: ^errors.Error_Record) -> bool {
	buffer: [HKDF_LABEL_LIMIT]u8
	hkdf_label := hkdf_label_write(&buffer, label, len(output))
	if hkdf_label == nil {
		return fail_at(error, .Bad_Value, 3, len(output), 0xFFFF, len(label))
	}
	key := string(secret)
	info := string(hkdf_label)
	result := output
	return cryptography.hkdf_sha256_expand(&key, &info, i64(len(output)), &result, error) == i64(len(output))
}

// packet_keys_from_secret gives the key, the iv and the header protection key
// of one direction from its traffic secret (RFC 9001, section 5.1).
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

CONNECTION_ID_LIMIT :: 20 // RFC 9000, section 17.2: a connection identifier of version 1 has 20 bytes at most.

// The secrets of the Initial level, before the keys: the tests compare them
// with RFC 9001, appendix A.1.
Initial_Secrets :: struct {
	initial: [SECRET_SIZE]u8,
	client:  [SECRET_SIZE]u8,
	server:  [SECRET_SIZE]u8,
}

// initial_secrets gives the Initial secrets of a connection from the
// Destination Connection ID of the first Initial packet of the client (RFC
// 9001, section 5.2).
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

// initial_keys gives the keys of the Initial packets of the client and of
// the server, and erases the secrets that made them.
initial_keys :: proc "contextless" (cryptography: ^Cryptography, destination_connection_id: []u8, client, server: ^Packet_Keys, error: ^errors.Error_Record) -> bool {
	secrets: Initial_Secrets
	defer secret_erase(&secrets, size_of(secrets))
	if !initial_secrets(cryptography, destination_connection_id, &secrets, error) {
		return false
	}
	return packet_keys_from_secret(cryptography, .Aes_128_Gcm_Sha256, secrets.client[:], client, error) && packet_keys_from_secret(cryptography, .Aes_128_Gcm_Sha256, secrets.server[:], server, error)
}

// secret_erase writes 0 in a secret with a call that the compiler cannot
// remove (runtime/memory.asm).
secret_erase :: proc "contextless" (data: rawptr, count: int) {
	erase_secret_bytes(data, count)
}

when ODIN_OS == .Freestanding {
	foreign _ {
		erase_secret_bytes :: proc "c" (destination: rawptr, count: int) -> rawptr ---
	}
} else {
	foreign import memory "../../runtime/memory_for_host_tests.asm"
	@(default_calling_convention = "c")
	foreign memory {
		erase_secret_bytes :: proc(destination: rawptr, count: int) -> rawptr ---
	}
}

RETRY_PSEUDO_PACKET_LIMIT :: 1 + CONNECTION_ID_LIMIT + 1500 // The original Destination Connection ID, then a Retry packet of one datagram.

// retry_integrity_tag gives the Retry Integrity Tag of a Retry packet
// without its tag: AES-128-GCM with the fixed key and nonce of version 1,
// an empty text, and the Retry Pseudo-Packet as the additional data (RFC
// 9001, section 5.8). The pseudo-packet is the length and the bytes of the
// original Destination Connection ID, then the packet.
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
	// A pseudo-packet over the limit of the additional data of the module
	// (1024 bytes) is refused there: a Retry token of this system is short.
	return cryptography.seal_with_aes_128_gcm(&key, &nonce, &additional, &empty, &result, error) == TAG_SIZE
}
