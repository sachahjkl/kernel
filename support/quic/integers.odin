// QUIC version 1 in the program (docs/QUIC.md): the parts of RFC 9000 and
// RFC 9001 that protect and read packets. The library is pure code over
// memory of the caller: it allocates nothing, makes no kernel call, and
// gives each failure as an error record.
//
// Who uses it: the remote service (`programs/remote`, a server), the
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

import "contract:errors"

VARIABLE_LENGTH_INTEGER_LARGEST :: (u64(1) << 62) - 1 // The largest value of 8 bytes of encoding.

// variable_length_integer_read reads a variable-length integer at offset.
// size is the bytes that it takes. A first byte past the bytes, or a length
// that the bytes do not hold, gives ok false: nothing is read past the end.
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

// variable_length_integer_size gives the bytes of the shortest encoding of
// a value, 0 for a value over 2^62 - 1.
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

// variable_length_integer_write writes a value at offset in the size that
// the caller gives (1, 2, 4 or 8; a length field is often written in a size
// fixed before its value is known). It gives the bytes written, 0 when the
// value does not fit the size or the bytes have no room.
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

PACKET_NUMBER_LARGEST :: VARIABLE_LENGTH_INTEGER_LARGEST // RFC 9000, section 12.3.

// packet_number_encoded_size gives the bytes (1 to 4) that a packet number
// needs on the wire, so that a receiver that has the largest acknowledged
// number decodes it (RFC 9000, appendix A.2): at least twice the range of the
// packet numbers that are not acknowledged. has_acknowledged is false before
// the first acknowledgment. 0: more than 4 bytes would be needed (the sender
// has too many packets in flight).
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

// packet_number_decode gives the full packet number from the truncated
// number of the wire and the largest number that was processed in its space
// (RFC 9000, appendix A.3). bits is 8, 16, 24 or 32.
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

// fail_at gives an error record for a byte of a packet: argument is the
// argument of the call that holds the packet, value the offset of the
// field, limit what the field needed, found what the packet had.
@(private)
fail_at :: proc "contextless" (error: ^errors.Error_Record, kind: errors.Kind, argument: i64, value: int, limit: int = 0, found: int = 0) -> bool {
	errors.fail(error, -1, kind, .Bytes, argument, i64(value), i64(limit), i64(found))
	return false
}
