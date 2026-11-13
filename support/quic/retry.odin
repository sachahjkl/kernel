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

// The format number of a retry token of this server: its first byte, and the first byte of its additional data.
//
// The byte lets a later version of the server change the form of the token: `retry_token_open`
// refuses a token whose first byte is another value (`Bad_Value`), before any cryptography. The byte
// is authenticated too, because it is in the additional data of the seal.
RETRY_TOKEN_FORMAT :: 1

// The bytes of the key that seals each retry token: 32, the key of ChaCha20-Poly1305.
//
// The server makes this key once, at its start, from its random generator, and keeps it in its own
// memory. A token of another start of the server does not open: the key is another one.
RETRY_TOKEN_KEY_SIZE :: 32

// The time for which a retry token opens, in microseconds: 10 s.
//
// A client sends its Initial packet again one round trip after the Retry. The 10 s cover its probe
// timeouts while it waits, as the handshake deadline does. `retry_token_open` refuses an older token
// (`Out_Of_Range`), so a token that someone saw on the path is of use for 10 s at most.
RETRY_TOKEN_LIFETIME :: 10_000_000

// The bytes of the sealed facts of a retry token: 37.
//
// The plain text of the seal, in this order:
//
// - 1 byte: the length of the original Destination Connection ID;
// - `CONNECTION_ID_LIMIT` bytes (20): that identifier, then zeros to the end;
// - `CONNECTION_ID_SIZE` bytes (8): the Source Connection ID of the Retry;
// - 8 bytes: the time of the Retry, the most significant byte first.
//
// The size is fixed, whatever the length of the identifier, so that the size of a token tells
// nothing.
RETRY_TOKEN_FACTS_SIZE :: 1 + CONNECTION_ID_LIMIT + CONNECTION_ID_SIZE + 8

// The bytes of a retry token of this server: 62.
//
// A token is, in this order:
//
// - 1 byte: `RETRY_TOKEN_FORMAT`;
// - 8 bytes: the counter that makes the nonce, in clear, the most significant byte first;
// - `RETRY_TOKEN_FACTS_SIZE` bytes (37): the sealed facts;
// - `TAG_SIZE` bytes (16): the tag of ChaCha20-Poly1305.
//
// `retry_token_open` refuses a token of another size before any cryptography.
RETRY_TOKEN_SIZE :: 1 + 8 + RETRY_TOKEN_FACTS_SIZE + TAG_SIZE

// The largest retry token that a client of this library keeps: 256 bytes.
//
// A client stores the token of the Retry and sends it in each later Initial packet. A server of
// another stack can give a longer token than the 62 bytes of this server, so the place is larger.
// A client drops a Retry whose token is longer than this.
RETRY_TOKEN_LIMIT :: 256

// The facts that a retry token carries, as the server reads and writes them.
//
// The server fills a record and calls `retry_token_make` when it answers an Initial packet with a
// Retry. When the client comes back, `retry_token_open` gives the same facts from the token alone:
// the server kept nothing between the two. The facts let it check that the client now sends to the
// identifier that the Retry named, and send back both identifiers in its
// [transport parameters](term:transport-parameters) (`original_destination_connection_id` and
// `retry_source_connection_id`).
//
// See [retry token](term:retry-token) and (docs/QUIC.md, "The token of a Retry").
Retry_Token_Facts :: struct {
	original_destination_connection_id:        [CONNECTION_ID_LIMIT]u8, // The Destination Connection ID of the first Initial packet of the client, before the Retry. The bytes after its length are zeros.
	original_destination_connection_id_length: int, // The bytes of that identifier: 0 to `CONNECTION_ID_LIMIT`.
	retry_source_connection_id:                [CONNECTION_ID_SIZE]u8, // The Source Connection ID of the Retry packet, which the server chose: the client must use it as its next Destination Connection ID.
	issued_at:                                 u64, // The time of the Retry, in microseconds of the clock that the caller gives. `retry_token_open` compares it with `now`.
	counter:                                   u64, // The counter that made the nonce of the token. `retry_token_make` does not read it: its counter is a parameter. `retry_token_open` writes it, and the server uses it to take each token once.
}

// retry_token_nonce gives the nonce of a retry token: four zero bytes, then the counter.
//
// The counter goes in the last 8 bytes, the most significant byte first. One nonce must never seal
// two texts with one key: the server adds 1 to its counter at each Retry, and makes a new key at
// each start, so the pair of key and nonce never comes back.
@(private)
retry_token_nonce :: proc "contextless" (counter: u64) -> (nonce: [12]u8) {
	for index in 0 ..< 8 {
		nonce[4 + index] = u8(counter >> (8 * uint(7 - index)))
	}
	return
}

// retry_token_additional gives the additional data of a retry token: the format, the address and the port of the remote.
//
// The 7 bytes are `RETRY_TOKEN_FORMAT`, the 4 bytes of the IPv4 address and the 2 bytes of the UDP
// port, each number with its most significant byte first. The additional data is not in the token:
// the server builds it again from the [remote](term:remote) of the datagram that carries the token.
// So a token opens only in a datagram from the address and the port that received the Retry, and
// that is the proof that the client receives datagrams there.
@(private)
retry_token_additional :: proc "contextless" (remote: Remote) -> (additional: [7]u8) {
	additional[0] = RETRY_TOKEN_FORMAT
	additional[1], additional[2], additional[3], additional[4] = u8(remote.address >> 24), u8(remote.address >> 16), u8(remote.address >> 8), u8(remote.address)
	additional[5], additional[6] = u8(remote.port >> 8), u8(remote.port)
	return
}

// retry_token_make writes the retry token of a Retry for one remote.
//
// The token is the server's own format: an AEAD value (ChaCha20-Poly1305 of the
// [cryptography module](term:cryptography-module)) that seals the facts under the key of the server,
// with the remote as additional data. The server puts it in the Retry packet
// (`retry_packet_write`) and keeps nothing.
//
// **Parameters**
//
// - `cryptography`: the procedures of the module.
// - `key`: the key of the server, of `RETRY_TOKEN_KEY_SIZE` bytes.
// - `counter`: the counter of this token. **The caller must give each counter once for one key**:
//   it makes the nonce.
// - `remote`: the address and the port that sent the Initial packet.
// - `facts`: the two identifiers and the time. Its `counter` field is not read.
// - `token`: where the `RETRY_TOKEN_SIZE` bytes go.
// - `error`: the error record of a failure.
//
// **Result**: true when the token is whole. False:
//
// - `Too_Long`: the length of the original identifier in `facts` is not 0 to `CONNECTION_ID_LIMIT`;
// - an error of the seal of the module, with its own record.
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

// retry_token_open opens the retry token of an Initial packet from one remote, and gives its facts.
//
// It is the check that a client proved its address: the token opens only when this server sealed it,
// for this address and port, less than `RETRY_TOKEN_LIFETIME` ago. The token is hostile input: its
// size and its format are checked first, then the module opens it into a private buffer.
//
// **Parameters**
//
// - `cryptography`: the procedures of the module.
// - `key`: the key of the server, the one of `retry_token_make`.
// - `token`: the bytes of the Token field of the Initial packet.
// - `remote`: the address and the port that sent the datagram.
// - `now`: the time, in microseconds of the clock of `Retry_Token_Facts.issued_at`.
// - `facts`: where the facts go. It is zero after each failure but the last one of the list below.
// - `error`: the error record of a failure.
//
// **Result**: true when the token is authentic and in its lifetime. False:
//
// - `Bad_Value`: the token does not have `RETRY_TOKEN_SIZE` bytes, or its first byte is not
//   `RETRY_TOKEN_FORMAT`; or the sealed length of the identifier is over `CONNECTION_ID_LIMIT`,
//   which a token of this server never has;
// - `Not_Authentic`, from the module: a changed byte, another address or port, or another key
//   (another start of the server);
// - `Out_Of_Range`: the time of the token is after `now`, or more than `RETRY_TOKEN_LIFETIME`
//   before it. The record holds that time as its value and `now` as its limit, and `facts` is
//   filled.
//
// **What it does not check**: that the token was not used before, and that the datagram goes to the
// identifier that the Retry named. The server does both with the facts
// (docs/QUIC.md, "The token of a Retry").
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

// retry_packet_write writes a Retry packet with its Retry Integrity Tag.
//
// A [Retry packet](term:retry-packet) is a long header with no packet number and no payload (RFC
// 9000, section 17.2.5): the first byte, the version 1, the two connection identifiers with their
// lengths, the token, then a tag of 16 bytes. The tag is not a secret: it uses the fixed key of
// version 1, over the packet and the original Destination Connection ID (RFC 9001, section 5.8,
// `retry_integrity_tag`). It proves to the client only that the sender saw its Initial packet.
//
// **Parameters**
//
// - `cryptography`: the procedures of the module.
// - `buffer`: where the packet goes.
// - `unused_bits`: the 4 low bits of the first byte, which have no meaning. Only the 4 low bits of
//   the value are used.
// - `destination`: the Destination Connection ID of the Retry: the Source Connection ID of the
//   Initial packet of the client. It can be empty.
// - `source`: the Source Connection ID of the Retry: a new identifier that the server chose.
// - `token`: the retry token. It must not be empty: a client discards a Retry with no token.
// - `original_destination`: the Destination Connection ID of the Initial packet of the client. It
//   is in the tag, not in the packet.
// - `error`: the error record of a failure.
//
// **Results**: the length of the packet and true. 0 and false:
//
// - `Too_Long`: one of the three identifiers has more than `CONNECTION_ID_LIMIT` bytes;
// - `Too_Small`: the token is empty, or the buffer has less than the packet needs (the record holds
//   the size of the buffer as its value and the size needed as its limit);
// - an error of `retry_integrity_tag`.
//
// A Retry of this server has 113 bytes at most: 7 bytes of header, two identifiers of 20 and 8
// bytes, the token of 62 bytes and the tag.
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
