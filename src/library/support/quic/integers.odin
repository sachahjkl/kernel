// QUIC version 1 in the program (docs/QUIC.md): the parts of RFC 9000 and
// RFC 9001 that protect and read packets. The library is pure code over
// memory of the caller: it allocates nothing, makes no kernel call, and
// gives each failure as an error record.
//
// Who uses it: the remote service (`src/programs/remote`, a server), the
// program `quic_echo` and the kernel tool (a client of the remote
// service). The parts, by file:
//
// - `connection.odin`, `connection_receive.odin`, `connection_send.odin`:
//   one connection (`Connection`): `connection_start_client`,
//   `connection_start_server`, `connection_datagram_receive`,
//   `connection_datagram_send`, `connection_time_passes`.
// - `streams.odin`: the streams of a connection (`Stream`).
// - `server.odin`, `server_budgets.odin`, `retry.odin`: a server of many
//   connections, its bounds and the Retry.
// - `tls_handshake.odin`, `tls_key_schedule.odin`: TLS 1.3 with a raw
//   public key (RFC 8446, RFC 7250).
// - `packets.odin`, `keys.odin`: the packet protection and the header
//   protection (RFC 9001).
// - `frames.odin`, `transport_parameters.odin`, `ranges.odin`,
//   `recovery.odin`: the frames, the parameters, the sets of ranges and the
//   loss detection.
//
// See [packet protection](term:packet-protection),
// [encryption level](term:encryption-level) and (docs/QUIC.md).
//
// This file: the variable-length integers (RFC 9000, section 16) and the
// packet numbers (RFC 9000, section 17.1 and appendix A).
package quic

import "modus:contract/errors"

// The largest value that a variable-length integer holds: 2^62 - 1, in the encoding of 8 bytes.
//
// The two high bits of the first byte give the length, so 62 bits are left for the value (RFC 9000,
// section 16). A packet number, an offset in a stream and a limit of flow control are such integers:
// none of them passes this value. `variable_length_integer_size` gives 0 for a larger value, and
// `variable_length_integer_write` writes nothing.
VARIABLE_LENGTH_INTEGER_LARGEST :: (u64(1) << 62) - 1

// variable_length_integer_read reads the variable-length integer that starts at `offset` in `bytes`.
//
// A variable-length integer is the number form of QUIC (RFC 9000, section 16): the two high bits of
// its first byte give its length (1, 2, 4 or 8 bytes), and the other bits are the value, the most
// significant byte first. Each field of a frame, each length of a header and each transport
// parameter is one. The bytes are hostile input: the read checks the length before it reads a byte.
//
// **Parameters**
//
// - `bytes`: the bytes that hold the integer, for example the private copy of a datagram.
// - `offset`: the place of its first byte.
//
// **Results**
//
// - `value`: the integer, from 0 to `VARIABLE_LENGTH_INTEGER_LARGEST`.
// - `size`: the bytes that it takes: 1, 2, 4 or 8. The caller adds it to its offset.
// - `ok`: false when `offset` is not in `bytes`, or when the length that the first byte gives passes
//   the end of `bytes`. Then `value` and `size` are 0, and nothing was read past the end.
//
// **What it does not check**: that the encoding is the shortest one. RFC 9000 allows a longer
// encoding everywhere but in a frame type; the reader of the frames checks that one case.
//
// ```odin
// // The bytes 7b bd are the integer 15293 in 2 bytes (RFC 9000, appendix A.1).
// value, size, ok := variable_length_integer_read(datagram, position)
// ```
variable_length_integer_read :: proc "contextless" (bytes: []u8, offset: int) -> (value: u64, size: int, ok: bool) {
	if offset < 0 || offset >= len(bytes) {
		return 0, 0, false
	}
	first := bytes[offset]
	size = 1 << (first >> 6)
	if size > len(bytes) - offset {
		return 0, 0, false
	}
	value = u64(first & 0x3F)
	for index in 1 ..< size {
		value = value << 8 | u64(bytes[offset + index])
	}
	return value, size, true
}

// variable_length_integer_size gives the bytes of the shortest encoding of a value: 1, 2, 4 or 8.
//
// A writer calls it to know the room that a field needs before it writes it. The bounds are those of
// RFC 9000, section 16: a value under 2^6 takes 1 byte, under 2^14 takes 2, under 2^30 takes 4, and
// up to `VARIABLE_LENGTH_INTEGER_LARGEST` takes 8.
//
// **Result**: the count of bytes, or **0** for a value over 2^62 - 1, which has no encoding. A caller
// must treat 0 as a refusal, not as a size.
variable_length_integer_size :: proc "contextless" (value: u64) -> int {
	switch {
	case value < 1 << 6:
		return 1
	case value < 1 << 14:
		return 2
	case value < 1 << 30:
		return 4
	case value <= VARIABLE_LENGTH_INTEGER_LARGEST:
		return 8
	}
	return 0
}

// variable_length_integer_write writes a value at `offset` in `bytes`, in the size that the caller gives.
//
// The caller chooses the size because a length field is often written before its value is known. The
// Length of a long header is the example: the sender writes it in a fixed size, then fills the
// packet. `frame_write_integer` is the writer for the usual case, the shortest encoding.
//
// **Parameters**
//
// - `bytes`: the buffer to write in.
// - `offset`: the place of the first byte.
// - `value`: the integer.
// - `size`: 1, 2, 4 or 8. It can be more than the shortest size of the value, never less.
//
// **Result**: the bytes written, which is `size`. **0** means that nothing was written:
//
// - `size` is not 1, 2, 4 or 8;
// - the value does not fit in `size`, or is over `VARIABLE_LENGTH_INTEGER_LARGEST`;
// - `offset` is negative, or `bytes` has no room for `size` bytes at `offset`.
variable_length_integer_write :: proc "contextless" (bytes: []u8, offset: int, value: u64, size: int) -> int {
	prefix: u8
	switch size {
	case 1:
		prefix = 0
	case 2:
		prefix = 1
	case 4:
		prefix = 2
	case 8:
		prefix = 3
	case:
		return 0
	}
	if variable_length_integer_size(value) == 0 || variable_length_integer_size(value) > size || offset < 0 || size > len(bytes) - offset {
		return 0
	}
	for index in 0 ..< size {
		bytes[offset + index] = u8(value >> (8 * uint(size - 1 - index)))
	}
	bytes[offset] |= prefix << 6
	return size
}

// The largest packet number of QUIC: 2^62 - 1 (RFC 9000, section 12.3).
//
// A packet number is never used two times in its [packet number space](term:packet-number-space),
// because it makes the nonce of [packet protection](term:packet-protection). A sender that reaches
// this value must close the connection. `packet_seal` refuses a larger number (`Out_Of_Range`).
PACKET_NUMBER_LARGEST :: VARIABLE_LENGTH_INTEGER_LARGEST

// packet_number_encoded_size gives the bytes (1 to 4) that a packet number needs on the wire.
//
// A packet carries only the low bytes of its packet number, and the receiver rebuilds the rest from
// the largest number that it processed (`packet_number_decode`). That works only if the bytes hold
// at least twice the range of the numbers that the peer did not acknowledge yet (RFC 9000, section
// 17.1 and appendix A.2). The sender calls this procedure for each packet, then writes the size
// minus 1 in the two low bits of the first byte.
//
// **Parameters**
//
// - `full_packet_number`: the number of the packet to send.
// - `largest_acknowledged`: the largest number of this space that the peer acknowledged.
// - `has_acknowledged`: false before the first acknowledgment of the space. The range is then the
//   number plus 1, as the RFC says.
//
// **Result**: 1, 2, 3 or 4. **0** means that no size is right:
//
// - the number is not above `largest_acknowledged`: a sender never sends such a number;
// - more than 2^31 packets are not acknowledged: 4 bytes are not enough, and the sender has too many
//   packets in flight.
//
// Example from the RFC: with 0xabe8b3 acknowledged, the number 0xac5c02 needs 2 bytes: 29 519 packets
// are not acknowledged, and twice that count fits in 16 bits.
packet_number_encoded_size :: proc "contextless" (full_packet_number: u64, largest_acknowledged: u64, has_acknowledged: bool) -> int {
	unacknowledged: u64
	if has_acknowledged {
		if full_packet_number <= largest_acknowledged {
			return 0
		}
		unacknowledged = full_packet_number - largest_acknowledged
	} else {
		unacknowledged = full_packet_number + 1
	}
	// The bits of 2 * unacknowledged: log2(unacknowledged) + 1, rounded up.
	range := unacknowledged * 2
	for size in 1 ..= 4 {
		if range <= u64(1) << uint(8 * size) {
			return size
		}
	}
	return 0
}

// packet_number_decode gives the whole packet number from the truncated number of the wire.
//
// It is the algorithm of RFC 9000, appendix A.3. The whole number is the one closest to the next
// expected number (`largest_packet_number` + 1) whose low bits are the truncated number. The
// receiver calls it when it removes [header protection](term:header-protection)
// (`header_protection_remove`), because the nonce of the open needs the whole number.
//
// **Parameters**
//
// - `largest_packet_number`: the largest number that was processed in the packet number space of
//   the packet.
// - `truncated_packet_number`: the 1 to 4 bytes of the wire, as an integer.
// - `bits`: the count of those bits: 8, 16, 24 or 32. The procedure does not check it.
//
// **Result**: the whole packet number. It never passes 2^62 - 1, and it never goes below 0: the two
// comparisons of the RFC are written so that no value wraps near these two ends.
//
// The result is a guess that the open confirms: a wrong number gives a wrong nonce, and the packet
// is then [not authentic](term:not-authentic).
//
// Example from the RFC: with 0xa82f30ea as the largest number, the 16 bits 0x9b32 give 0xa82f9b32.
packet_number_decode :: proc "contextless" (largest_packet_number: u64, truncated_packet_number: u64, bits: uint) -> u64 {
	expected := largest_packet_number + 1
	window := u64(1) << bits
	half_window := window / 2
	mask := window - 1
	candidate := (expected & ~mask) | truncated_packet_number
	// The comparisons of the RFC, written so that no value wraps.
	if candidate + half_window <= expected && candidate < (u64(1) << 62) - window {
		return candidate + window
	}
	if candidate > expected + half_window && candidate >= window {
		return candidate - window
	}
	return candidate
}

// fail_at writes an error record for a byte of a packet or for an argument, and gives false.
//
// Each procedure of this library that reads hostile bytes ends a failing path with
// `return fail_at(...)`: the caller gets false and an [error record](term:error-record) that says
// where the bytes are wrong. The unit of the record is always `Bytes`. `error` can be nil: the
// caller asked for no record.
//
// **Parameters**
//
// - `error`: the record to fill.
// - `kind`: the error kind, for example `Too_Small` or `Bad_Value`.
// - `argument`: the number, from 1, of the argument of the calling procedure that holds the fault.
// - `value`: most often the offset of the field in the packet, or the size of the argument.
// - `limit`: what the field needed: a largest size, or the offset that the bytes had to reach.
// - `found`: what the packet had.
//
// **Result**: always false, so that a failing path is one line.
@(private)
fail_at :: proc "contextless" (error: ^errors.Error_Record, kind: errors.Kind, argument: i64, value: int, limit: int = 0, found: int = 0) -> bool {
	errors.fail(error, -1, kind, .Bytes, argument, i64(value), i64(limit), i64(found))
	return false
}
