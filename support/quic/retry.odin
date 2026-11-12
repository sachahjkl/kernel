package quic

// Retry (RFC 9000, sections 8.1.2 and 17.2.5; RFC 9001, section 5.8): a
// server answers an Initial that carries no token with a Retry packet, and
// keeps nothing. The Retry gives a token; only a client that receives
// datagrams at its address can send its Initial again with that token. So
// a record of the server is taken only for a client that proved its
// address, and a source address that an attacker forged takes nothing.
//
// The token is the server's own: an AEAD value (ChaCha20-Poly1305 of the
// module cryptography) under a key that the server makes at its start, over
//   the original Destination Connection ID of the client (sealed: the
//       server sends it back in the transport parameters),
//   the Source Connection ID of the Retry (sealed: the client must use it
//       as its next Destination Connection ID),
//   the time of the Retry (sealed),
// with the remote address and port as additional data. A token from
// another address or port, a changed byte, a token of another start of the
// server, or a token older than RETRY_TOKEN_LIFETIME does not open.
//
// A replay: whoever sees a token on the path can send it again, from the
// address and port of that client only (the additional data), with the
// identifier that the Retry named, within its lifetime. While the record of
// the client lives, the replay goes to that record. A token takes a record
// once (server_budgets.odin), unless the table of used tokens forgot it.
// An attacker on the path can do worse anyway (drop the datagrams). A
// replay gives nothing to an attacker off the path.

import "contract:errors"

RETRY_TOKEN_FORMAT :: 1
RETRY_TOKEN_KEY_SIZE :: 32
// Microseconds: a client sends its Initial again one round trip after the
// Retry; 10 s covers its probe timeouts while it waits, as the handshake
// deadline does.
RETRY_TOKEN_LIFETIME :: 10_000_000
// The sealed facts: the length and the bytes of the original Destination
// Connection ID (20 bytes, the rest zeros), the Source Connection ID of the
// Retry, the time.
RETRY_TOKEN_FACTS_SIZE :: 1 + CONNECTION_ID_LIMIT + CONNECTION_ID_SIZE + 8
// The format, the counter that makes the nonce, the sealed facts, the tag.
RETRY_TOKEN_SIZE :: 1 + 8 + RETRY_TOKEN_FACTS_SIZE + TAG_SIZE
// The token of a Retry that a client keeps: a server of another stack can
// give a longer one than this server.
RETRY_TOKEN_LIMIT :: 256

Retry_Token_Facts :: struct {
	original_destination_connection_id:        [CONNECTION_ID_LIMIT]u8,
	original_destination_connection_id_length: int,
	retry_source_connection_id:                [CONNECTION_ID_SIZE]u8,
	issued_at:                                 u64,
	counter:                                   u64, // The nonce of the token: retry_token_open gives it, and the server takes each token once.
}

// retry_token_nonce: four zero bytes, then the counter. The server never
// uses a counter two times with one key.
@(private)
retry_token_nonce :: proc "contextless" (counter: u64) -> (nonce: [12]u8) {
	for index in 0 ..< 8 {
		nonce[4 + index] = u8(counter >> (8 * uint(7 - index)))
	}
	return
}

@(private)
retry_token_additional :: proc "contextless" (remote: Remote) -> (additional: [7]u8) {
	additional[0] = RETRY_TOKEN_FORMAT
	additional[1], additional[2], additional[3], additional[4] = u8(remote.address >> 24), u8(remote.address >> 16), u8(remote.address >> 8), u8(remote.address)
	additional[5], additional[6] = u8(remote.port >> 8), u8(remote.port)
	return
}

// retry_token_make writes the token of a Retry for a remote.
retry_token_make :: proc "contextless" (cryptography: ^Cryptography, key: ^[RETRY_TOKEN_KEY_SIZE]u8, counter: u64, remote: Remote, facts: ^Retry_Token_Facts, token: ^[RETRY_TOKEN_SIZE]u8, error: ^errors.Error_Record) -> bool {
	if facts.original_destination_connection_id_length < 0 || facts.original_destination_connection_id_length > CONNECTION_ID_LIMIT {
		return fail_at(error, .Too_Long, 4, facts.original_destination_connection_id_length, CONNECTION_ID_LIMIT)
	}
	plain: [RETRY_TOKEN_FACTS_SIZE]u8
	plain[0] = u8(facts.original_destination_connection_id_length)
	copy(plain[1:], facts.original_destination_connection_id[:facts.original_destination_connection_id_length])
	copy(plain[1 + CONNECTION_ID_LIMIT:], facts.retry_source_connection_id[:])
	for index in 0 ..< 8 {
		plain[1 + CONNECTION_ID_LIMIT + CONNECTION_ID_SIZE + index] = u8(facts.issued_at >> (8 * uint(7 - index)))
	}
	token[0] = RETRY_TOKEN_FORMAT
	for index in 0 ..< 8 {
		token[1 + index] = u8(counter >> (8 * uint(7 - index)))
	}
	nonce := retry_token_nonce(counter)
	additional := retry_token_additional(remote)
	key_text, nonce_text, additional_text, plain_text := string(key[:]), string(nonce[:]), string(additional[:]), string(plain[:])
	result := token[9:]
	return cryptography.seal_with_chacha20_poly1305(&key_text, &nonce_text, &additional_text, &plain_text, &result, error) == RETRY_TOKEN_FACTS_SIZE + TAG_SIZE
}

// retry_token_open opens the token of an Initial from a remote, and gives
// its facts. A token of another form or size, another remote, a changed
// byte or another key gives false; so does a time in the future, or a time
// more than RETRY_TOKEN_LIFETIME ago (Out_Of_Range).
retry_token_open :: proc "contextless" (cryptography: ^Cryptography, key: ^[RETRY_TOKEN_KEY_SIZE]u8, token: []u8, remote: Remote, now: u64, facts: ^Retry_Token_Facts, error: ^errors.Error_Record) -> bool {
	facts^ = {}
	if len(token) != RETRY_TOKEN_SIZE || token[0] != RETRY_TOKEN_FORMAT {
		return fail_at(error, .Bad_Value, 3, len(token), RETRY_TOKEN_SIZE)
	}
	counter: u64
	for index in 0 ..< 8 {
		counter = counter << 8 | u64(token[1 + index])
	}
	nonce := retry_token_nonce(counter)
	additional := retry_token_additional(remote)
	plain: [RETRY_TOKEN_FACTS_SIZE]u8
	key_text, nonce_text, additional_text, sealed := string(key[:]), string(nonce[:]), string(additional[:]), string(token[9:])
	result := plain[:]
	if cryptography.open_with_chacha20_poly1305(&key_text, &nonce_text, &additional_text, &sealed, &result, error) != RETRY_TOKEN_FACTS_SIZE {
		return false
	}
	length := int(plain[0])
	if length > CONNECTION_ID_LIMIT {
		return fail_at(error, .Bad_Value, 3, length, CONNECTION_ID_LIMIT)
	}
	facts.original_destination_connection_id_length = copy(facts.original_destination_connection_id[:], plain[1:][:length])
	copy(facts.retry_source_connection_id[:], plain[1 + CONNECTION_ID_LIMIT:][:CONNECTION_ID_SIZE])
	for index in 0 ..< 8 {
		facts.issued_at = facts.issued_at << 8 | u64(plain[1 + CONNECTION_ID_LIMIT + CONNECTION_ID_SIZE + index])
	}
	facts.counter = counter
	if facts.issued_at > now || now - facts.issued_at > RETRY_TOKEN_LIFETIME {
		return fail_at(error, .Out_Of_Range, 3, int(min(facts.issued_at, u64(max(int)))), int(min(now, u64(max(int)))))
	}
	return true
}

// retry_packet_write writes a Retry packet (RFC 9000, section 17.2.5): to
// the Source Connection ID of the client, from a new identifier of the
// server, with a token, and the Retry Integrity Tag over the original
// Destination Connection ID of the client (RFC 9001, section 5.8).
// unused_bits are the 4 low bits of the first byte, which have no meaning.
// It gives the length of the packet.
retry_packet_write :: proc "contextless" (cryptography: ^Cryptography, buffer: []u8, unused_bits: u8, destination, source, token, original_destination: []u8, error: ^errors.Error_Record) -> (length: int, ok: bool) {
	if len(destination) > CONNECTION_ID_LIMIT || len(source) > CONNECTION_ID_LIMIT || len(original_destination) > CONNECTION_ID_LIMIT {
		return 0, fail_at(error, .Too_Long, 4, CONNECTION_ID_LIMIT)
	}
	needed := 1 + 4 + 1 + len(destination) + 1 + len(source) + len(token) + TAG_SIZE
	if len(token) == 0 || needed > len(buffer) {
		return 0, fail_at(error, .Too_Small, 2, len(buffer), needed)
	}
	at := 0
	buffer[at] = LONG_HEADER_FORM | FIXED_BIT | u8(Packet_Type.Retry) << 4 | (unused_bits & 0x0F)
	at += 1
	buffer[at], buffer[at + 1], buffer[at + 2], buffer[at + 3] = 0, 0, 0, 1
	at += 4
	buffer[at] = u8(len(destination))
	at += 1
	at += copy(buffer[at:], destination)
	buffer[at] = u8(len(source))
	at += 1
	at += copy(buffer[at:], source)
	at += copy(buffer[at:], token)
	tag: [TAG_SIZE]u8
	if !retry_integrity_tag(cryptography, original_destination, buffer[:at], &tag, error) {
		return 0, false
	}
	at += copy(buffer[at:], tag[:])
	return at, true
}
