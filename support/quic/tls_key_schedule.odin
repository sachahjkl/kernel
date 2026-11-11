package quic

// The key schedule of TLS 1.3 with SHA-256 (RFC 8446, section 7.1), as
// QUIC uses it: no pre-shared key, so the early secret comes from zeros, and
// no 0-RTT secret. Each secret is a record of the handshake in memory of the
// caller, erased when the handshake ends.

import "contract:errors"

HASH_SIZE :: 32 // SHA-256.
CONTEXT_LIMIT :: HASH_SIZE // The context of an HkdfLabel here is a transcript hash, or empty.
HKDF_LABEL_WITH_CONTEXT_LIMIT :: 2 + 1 + 6 + LABEL_LIMIT + 1 + CONTEXT_LIMIT

// hkdf_label_with_context_write writes the HkdfLabel of TLS 1.3 (RFC 8446,
// section 7.1): uint16 length, uint8 length of "tls13 " + label, "tls13 " +
// label, uint8 length of the context, the context. It gives the bytes, or
// nil for a label, a context or a length out of their bounds.
hkdf_label_with_context_write :: proc "contextless" (buffer: ^[HKDF_LABEL_WITH_CONTEXT_LIMIT]u8, label: string, context_bytes: []u8, length: int) -> []u8 {
	if len(label) > LABEL_LIMIT || len(context_bytes) > CONTEXT_LIMIT || length < 1 || length > 0xFFFF {
		return nil
	}
	buffer[0] = u8(length >> 8)
	buffer[1] = u8(length)
	buffer[2] = u8(6 + len(label))
	copy(buffer[3:], "tls13 ")
	copy(buffer[9:], label)
	position := 9 + len(label)
	buffer[position] = u8(len(context_bytes))
	copy(buffer[position + 1:], context_bytes)
	return buffer[:position + 1 + len(context_bytes)]
}

// hkdf_expand_label_with_context gives HKDF-Expand-Label(secret, label,
// context, len(output)) with SHA-256.
hkdf_expand_label_with_context :: proc "contextless" (cryptography: ^Cryptography, secret: []u8, label: string, context_bytes: []u8, output: []u8, error: ^errors.Error_Record) -> bool {
	buffer: [HKDF_LABEL_WITH_CONTEXT_LIMIT]u8
	hkdf_label := hkdf_label_with_context_write(&buffer, label, context_bytes, len(output))
	if hkdf_label == nil {
		return fail_at(error, .Bad_Value, 3, len(output), 0xFFFF, len(label))
	}
	key := string(secret)
	info := string(hkdf_label)
	result := output
	return cryptography.hkdf_sha256_expand(&key, &info, i64(len(output)), &result, error) == i64(len(output))
}

// hkdf_extract gives HKDF-Extract(salt, input) with SHA-256 (RFC 5869,
// section 2.2): a salt of no byte is a salt of 32 zero bytes there.
hkdf_extract :: proc "contextless" (cryptography: ^Cryptography, salt, input: []u8, output: ^[HASH_SIZE]u8, error: ^errors.Error_Record) -> bool {
	salt_text, input_text := string(salt), string(input)
	result := output[:]
	if cryptography.hkdf_sha256_extract(&salt_text, &input_text, &result) != HASH_SIZE {
		return fail_at(error, .Refused, 1, 0)
	}
	return true
}

// hash_of gives the SHA-256 hash of bytes.
hash_of :: proc "contextless" (cryptography: ^Cryptography, bytes: []u8, output: ^[HASH_SIZE]u8) -> bool {
	text := string(bytes)
	result := output[:]
	return cryptography.sha256(&text, &result) == HASH_SIZE
}

// derive_secret gives Derive-Secret(secret, label, messages) of RFC 8446,
// section 7.1, from the transcript hash of the messages.
derive_secret :: proc "contextless" (cryptography: ^Cryptography, secret: []u8, label: string, transcript_hash: []u8, output: ^[HASH_SIZE]u8, error: ^errors.Error_Record) -> bool {
	return hkdf_expand_label_with_context(cryptography, secret, label, transcript_hash, output[:], error)
}

// The secrets of one handshake, from the shared secret of X25519 and the
// transcript hashes.
Key_Schedule :: struct {
	early:                      [HASH_SIZE]u8,
	handshake:                  [HASH_SIZE]u8,
	master:                     [HASH_SIZE]u8,
	client_handshake_traffic:   [HASH_SIZE]u8,
	server_handshake_traffic:   [HASH_SIZE]u8,
	client_application_traffic: [HASH_SIZE]u8,
	server_application_traffic: [HASH_SIZE]u8,
}

// key_schedule_handshake gives the early, handshake and master secrets and
// the two handshake traffic secrets, from the shared secret and the hash of
// ClientHello and ServerHello.
key_schedule_handshake :: proc "contextless" (cryptography: ^Cryptography, schedule: ^Key_Schedule, shared_secret: []u8, hash_of_hellos: []u8, error: ^errors.Error_Record) -> bool {
	zeros: [HASH_SIZE]u8
	hash_of_nothing: [HASH_SIZE]u8
	derived: [HASH_SIZE]u8
	defer secret_erase(&derived, size_of(derived))
	if !hash_of(cryptography, nil, &hash_of_nothing) {
		return fail_at(error, .Refused, 1, 0)
	}
	// With no pre-shared key, the input of the early secret is 32 zero bytes.
	return hkdf_extract(cryptography, nil, zeros[:], &schedule.early, error) &&
		derive_secret(cryptography, schedule.early[:], "derived", hash_of_nothing[:], &derived, error) &&
		hkdf_extract(cryptography, derived[:], shared_secret, &schedule.handshake, error) &&
		derive_secret(cryptography, schedule.handshake[:], "c hs traffic", hash_of_hellos, &schedule.client_handshake_traffic, error) &&
		derive_secret(cryptography, schedule.handshake[:], "s hs traffic", hash_of_hellos, &schedule.server_handshake_traffic, error) &&
		derive_secret(cryptography, schedule.handshake[:], "derived", hash_of_nothing[:], &derived, error) &&
		hkdf_extract(cryptography, derived[:], zeros[:], &schedule.master, error)
}

// key_schedule_application gives the two application traffic secrets from
// the master secret and the hash of the messages up to the Finished of the
// server.
key_schedule_application :: proc "contextless" (cryptography: ^Cryptography, schedule: ^Key_Schedule, hash_to_server_finished: []u8, error: ^errors.Error_Record) -> bool {
	return derive_secret(cryptography, schedule.master[:], "c ap traffic", hash_to_server_finished, &schedule.client_application_traffic, error) && derive_secret(cryptography, schedule.master[:], "s ap traffic", hash_to_server_finished, &schedule.server_application_traffic, error)
}

// finished_verify_data gives the verify_data of a Finished message (RFC
// 8446, section 4.4.4): HMAC of the transcript hash with the finished key
// of the traffic secret of the sender.
finished_verify_data :: proc "contextless" (cryptography: ^Cryptography, traffic_secret: []u8, transcript_hash: []u8, output: ^[HASH_SIZE]u8, error: ^errors.Error_Record) -> bool {
	finished_key: [HASH_SIZE]u8
	defer secret_erase(&finished_key, size_of(finished_key))
	if !hkdf_expand_label_with_context(cryptography, traffic_secret, "finished", nil, finished_key[:], error) {
		return false
	}
	key, text := string(finished_key[:]), string(transcript_hash)
	result := output[:]
	if cryptography.hmac_sha256(&key, &text, &result) != HASH_SIZE {
		return fail_at(error, .Refused, 1, 0)
	}
	return true
}
