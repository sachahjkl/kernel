package quic

// The key schedule of TLS 1.3 with SHA-256 (RFC 8446, section 7.1), as
// QUIC uses it: no pre-shared key, so the early secret comes from zeros, and
// no 0-RTT secret. Each secret is a record of the handshake in memory of the
// caller, erased when the handshake ends.

import "contract:errors"

// The bytes of a SHA-256 hash: 32.
//
// SHA-256 is the hash of both cipher suites of this library, so each transcript hash, each secret
// of the key schedule and each verify_data of a Finished message has this size.
HASH_SIZE :: 32

// The most bytes of the context of an HkdfLabel in this library: 32.
//
// The context of the key schedule is a transcript hash, or nothing. TLS 1.3 allows 255 bytes; no
// derivation here needs more than a hash.
CONTEXT_LIMIT :: HASH_SIZE

// The most bytes of an HkdfLabel with a context: 291.
//
// The 259 bytes of `HKDF_LABEL_LIMIT`, whose last byte is the length of the context, and
// `CONTEXT_LIMIT` bytes of context. It is the size of the buffer that
// `hkdf_label_with_context_write` fills.
HKDF_LABEL_WITH_CONTEXT_LIMIT :: 2 + 1 + 6 + LABEL_LIMIT + 1 + CONTEXT_LIMIT

// hkdf_label_with_context_write writes the HkdfLabel of TLS 1.3 with a context.
//
// The HkdfLabel is the info text of HKDF-Expand-Label (RFC 8446, section 7.1). The bytes, in this
// order: the length of the output as 2 bytes, the length of "tls13 " and the label as 1 byte,
// "tls13 " and the label, the length of the context as 1 byte, the context. The key schedule of
// TLS uses it with a transcript hash as the context; the packet keys of QUIC use the form with no
// context (`hkdf_label_write`).
//
// **Parameters**
//
// - `buffer`: where the bytes go.
// - `label`: the label without its prefix, for example "c hs traffic". `LABEL_LIMIT` bytes at most.
// - `context_bytes`: the context: `CONTEXT_LIMIT` bytes at most, and none is valid.
// - `length`: the bytes of output that the caller asks of HKDF: 1 to 65535.
//
// **Result**: the bytes written, a slice of `buffer`. **nil** for a label over `LABEL_LIMIT`, a
// context over `CONTEXT_LIMIT`, or a length out of 1 to 65535.
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

// hkdf_expand_label_with_context gives the bytes of HKDF-Expand-Label(secret, label, context, length) with SHA-256.
//
// The length of the output is `len(output)`. Each secret of the key schedule after an extract is
// one call (`derive_secret`), and so is the finished key (RFC 8446, section 7.1).
//
// **Parameters**
//
// - `cryptography`: the procedures of the module.
// - `secret`: the secret to expand: 32 bytes.
// - `label`: the label without the prefix "tls13 ".
// - `context_bytes`: a transcript hash, or nil for an empty context.
// - `output`: where the bytes go; its length is the length asked.
// - `error`: the error record of a failure.
//
// **Result**: true when `output` is whole. False:
//
// - `Too_Long` (argument 3): the label is over `LABEL_LIMIT`. The record holds the length of the
//   label as its value and the limit;
// - `Too_Long` (argument 4): the context is over `CONTEXT_LIMIT`, with its length and the limit;
// - `Empty` (argument 5): the output has no byte;
// - `Too_Long` (argument 5): the output has more than 65535 bytes, with its length and 65535;
// - an error of HKDF-Expand of the module, with its own record.
hkdf_expand_label_with_context :: proc "contextless" (cryptography: ^Cryptography, secret: []u8, label: string, context_bytes: []u8, output: []u8, error: ^errors.Error_Record) -> bool {
	buffer: [HKDF_LABEL_WITH_CONTEXT_LIMIT]u8
	hkdf_label := hkdf_label_with_context_write(&buffer, label, context_bytes, len(output))
	if hkdf_label == nil {
		// The label writer gives no reason: the record names the argument
		// that broke its rule, with the size that it had.
		switch {
		case len(label) > LABEL_LIMIT:
			return fail_at(error, .Too_Long, 3, len(label), LABEL_LIMIT)
		case len(context_bytes) > CONTEXT_LIMIT:
			return fail_at(error, .Too_Long, 4, len(context_bytes), CONTEXT_LIMIT)
		case len(output) == 0:
			return fail_at(error, .Empty, 5, 0, 0xFFFF)
		}
		return fail_at(error, .Too_Long, 5, len(output), 0xFFFF)
	}
	key := string(secret)
	info := string(hkdf_label)
	result := output
	return cryptography.hkdf_sha256_expand(&key, &info, i64(len(output)), &result, error) == i64(len(output))
}

// hkdf_extract gives HKDF-Extract(salt, input) with SHA-256: 32 bytes (RFC 5869, section 2.2).
//
// The key schedule calls it three times: for the early secret, the handshake secret and the master
// secret. A salt of no byte is a salt of 32 zero bytes in HKDF: the early secret uses that.
//
// **Parameters**
//
// - `cryptography`: the procedures of the module.
// - `salt`: the salt, or nil.
// - `input`: the input keying material.
// - `output`: where the 32 bytes go.
// - `error`: the error record of a failure.
//
// **Result**: true, or false with `Refused` (argument 1) when the module did not give 32 bytes. The
// export of the module has no error record of its own.
hkdf_extract :: proc "contextless" (cryptography: ^Cryptography, salt, input: []u8, output: ^[HASH_SIZE]u8, error: ^errors.Error_Record) -> bool {
	salt_text, input_text := string(salt), string(input)
	result := output[:]
	if cryptography.hkdf_sha256_extract(&salt_text, &input_text, &result) != HASH_SIZE {
		return fail_at(error, .Refused, 1, 0)
	}
	return true
}

// hash_of gives the SHA-256 hash of bytes.
//
// The handshake hashes its [transcript](term:transcript) with it at each point where the key
// schedule, a signature or a Finished message needs the hash. No byte is a valid input: the key
// schedule uses the hash of nothing.
//
// **Result**: true when the module gave 32 bytes in `output`. It takes no error record: the caller
// writes one.
hash_of :: proc "contextless" (cryptography: ^Cryptography, bytes: []u8, output: ^[HASH_SIZE]u8) -> bool {
	text := string(bytes)
	result := output[:]
	return cryptography.sha256(&text, &result) == HASH_SIZE
}

// derive_secret gives Derive-Secret(secret, label, messages) of TLS 1.3 from the hash of the messages.
//
// Derive-Secret is HKDF-Expand-Label with the transcript hash of the messages as its context, for
// 32 bytes (RFC 8446, section 7.1). The caller gives the hash, not the messages: the handshake
// holds the transcript and hashes it once for each point.
//
// **Parameters**
//
// - `cryptography`: the procedures of the module.
// - `secret`: the secret of the stage: early, handshake or master.
// - `label`: the label: "derived", "c hs traffic", "s hs traffic", "c ap traffic" or
//   "s ap traffic" in this library.
// - `transcript_hash`: the hash of the messages up to the point of the secret: 32 bytes.
// - `output`: where the secret goes.
// - `error`: the error record of a failure.
//
// **Result**: true, or false with the error of `hkdf_expand_label_with_context`.
derive_secret :: proc "contextless" (cryptography: ^Cryptography, secret: []u8, label: string, transcript_hash: []u8, output: ^[HASH_SIZE]u8, error: ^errors.Error_Record) -> bool {
	return hkdf_expand_label_with_context(cryptography, secret, label, transcript_hash, output[:], error)
}

// The secrets of one handshake of TLS 1.3, in the order in which the key schedule makes them.
//
// The [key schedule](term:key-schedule) is a chain: each secret comes from the one before, with
// HKDF and a transcript hash (RFC 8446, section 7.1). The shared secret of X25519 enters at the
// handshake secret, so no one who lacks a private key of the exchange can compute what follows.
// The hashes tie each secret to the messages: a changed message gives other secrets on one side,
// and the Finished messages then fail.
//
// `key_schedule_handshake` fills the first five fields, `key_schedule_application` the last two.
// QUIC takes its packet keys from the four traffic secrets (`tls_packet_keys`). The record is in
// the `Tls_Handshake` of the caller, and `tls_handshake_erase_secrets` erases it.
//
// **What this schedule does not have**: a pre-shared key, so the early secret comes from zeros; the
// secrets of 0-RTT; the exporter and the resumption secrets; the next traffic secrets of a key
// update.
Key_Schedule :: struct {
	early:                      [HASH_SIZE]u8, // The early secret: HKDF-Extract of no salt and 32 zero bytes. With no pre-shared key it is the same for each handshake.
	handshake:                  [HASH_SIZE]u8, // The handshake secret: HKDF-Extract of the secret derived from `early` and the shared secret of X25519.
	master:                     [HASH_SIZE]u8, // The master secret: HKDF-Extract of the secret derived from `handshake` and 32 zero bytes.
	client_handshake_traffic:   [HASH_SIZE]u8, // The secret of the Handshake packets that the client sends, and of its Finished: the label "c hs traffic" over the two Hello messages.
	server_handshake_traffic:   [HASH_SIZE]u8, // The secret of the Handshake packets that the server sends, and of its Finished: the label "s hs traffic" over the two Hello messages.
	client_application_traffic: [HASH_SIZE]u8, // The secret of the 1-RTT packets that the client sends: the label "c ap traffic" over the messages up to the Finished of the server.
	server_application_traffic: [HASH_SIZE]u8, // The secret of the 1-RTT packets that the server sends: the label "s ap traffic" over the same messages.
}

// key_schedule_handshake gives the early, handshake and master secrets and the two handshake traffic secrets.
//
// Each side calls it once, when it has the key share of the peer and both Hello messages: a server
// after it wrote its ServerHello, a client after it read it. The chain (RFC 8446, section 7.1):
//
// 1. the early secret, from no salt and 32 zero bytes: there is no pre-shared key;
// 2. the handshake secret, from the secret "derived" of the early secret and the shared secret;
// 3. the two handshake traffic secrets, with the hash of ClientHello and ServerHello;
// 4. the master secret, from the secret "derived" of the handshake secret and 32 zero bytes.
//
// **Parameters**
//
// - `cryptography`: the procedures of the module.
// - `schedule`: where the five secrets go.
// - `shared_secret`: the 32 bytes of the X25519 exchange. The caller erases them after the call.
// - `hash_of_hellos`: the transcript hash of ClientHello and ServerHello.
// - `error`: the error record of a failure.
//
// **Result**: true when the five secrets are whole. False with `Refused` when the hash of nothing
// did not come, or with the error of the step that failed: `schedule` then holds a part of the
// chain, and the caller erases it. The two secrets "derived" are erased before the return.
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

// key_schedule_application gives the two application traffic secrets from the master secret.
//
// Each side calls it once, when its transcript holds each message up to the Finished of the server:
// a server after it wrote that Finished, a client after it checked it. The secrets are
// Derive-Secret of the master secret with the labels "c ap traffic" and "s ap traffic" (RFC 8446,
// section 7.1). They give the 1-RTT keys of QUIC.
//
// **Parameters**
//
// - `cryptography`: the procedures of the module.
// - `schedule`: the schedule that `key_schedule_handshake` filled.
// - `hash_to_server_finished`: the transcript hash from ClientHello to the Finished of the server.
// - `error`: the error record of a failure.
//
// **Result**: true, or false with the error of `derive_secret`.
//
// The Finished of the client is not in this hash: a server has its 1-RTT keys before it knows that
// the client is the peer of the handshake. The transport decides what a server sends before then.
key_schedule_application :: proc "contextless" (cryptography: ^Cryptography, schedule: ^Key_Schedule, hash_to_server_finished: []u8, error: ^errors.Error_Record) -> bool {
	return derive_secret(cryptography, schedule.master[:], "c ap traffic", hash_to_server_finished, &schedule.client_application_traffic, error) && derive_secret(cryptography, schedule.master[:], "s ap traffic", hash_to_server_finished, &schedule.server_application_traffic, error)
}

// finished_verify_data gives the verify_data of a Finished message.
//
// A Finished message proves that its sender holds the handshake secrets and saw the same
// [transcript](term:transcript) as its peer. Its verify_data is the HMAC with SHA-256 of the
// transcript hash, under the finished key: HKDF-Expand-Label of the handshake traffic secret of the
// sender with the label "finished" and no context (RFC 8446, section 4.4.4).
//
// **Parameters**
//
// - `cryptography`: the procedures of the module.
// - `traffic_secret`: the handshake traffic secret of the side that sends the Finished.
// - `transcript_hash`: the hash of the messages before that Finished.
// - `output`: where the 32 bytes go.
// - `error`: the error record of a failure.
//
// **Result**: true, or false with the error of the expand, or `Refused` (argument 1) when the HMAC
// of the module did not give 32 bytes. The finished key is erased before the return.
//
// The sender writes the bytes in its Finished; the receiver computes them again and compares the
// two in a time that does not depend on the bytes.
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
