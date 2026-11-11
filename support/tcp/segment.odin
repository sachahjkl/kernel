// The TCP library: TCP in the program that uses it (property 5,
// docs/NETWORK.md). This file: the numbers of TCP, the order of sequence
// numbers, and the header of a segment.
//
// A segment is the bytes of TCP: the header, its options and the data,
// with no IPv4 header. Numbers are in the order of the machine; a segment
// holds them in network order (the first byte is the high byte). An IPv4
// address is a u32: 10.0.2.15 is 0x0A00020F.
package tcp

PROTOCOL :: 6 // The protocol number of TCP in the IPv4 header.
HEADER :: 20 // The header with no option.
HEADER_MSS :: 24 // The header with the MSS option: each SYN that this library sends.
SEGMENT_LIMIT :: 1480 // One frame of Ethernet (1500 bytes of IPv4) less the IPv4 header.
MSS_LOCAL :: 1460 // The MSS that this library gives: SEGMENT_LIMIT less the header.
MSS_DEFAULT :: 536 // The MSS of a remote that gave no MSS option (RFC 9293 3.7.1).
WINDOW_LIMIT :: 65535 // No window scaling: the window field is the window.

Flag :: enum u8 {
	Fin = 0,
	Syn = 1,
	Rst = 2,
	Psh = 3,
	Ack = 4,
	Urg = 5,
	Ece = 6,
	Cwr = 7,
}
Flags :: bit_set[Flag;u8] // The byte 13 of the header.

// Header is what header_read found in a segment. data is a part of the segment.
Header :: struct {
	source_port:      u16,
	destination_port: u16,
	sequence:         u32,
	acknowledgment:   u32,
	flags:            Flags,
	window:           u16,
	mss:              u16, // The MSS option. 0: the segment has none.
	data:             []u8,
}

// The order of sequence numbers is modulo 2^32 (RFC 9293 3.4): a is before
// b when b - a, as a signed number of 32 bits, is positive. The comparison
// holds for two numbers that are less than 2^31 apart.
before :: #force_inline proc "contextless" (a, b: u32) -> bool {
	return i32(a - b) < 0
}

after :: #force_inline proc "contextless" (a, b: u32) -> bool {
	return i32(a - b) > 0
}

before_or_same :: #force_inline proc "contextless" (a, b: u32) -> bool {
	return i32(a - b) <= 0
}

after_or_same :: #force_inline proc "contextless" (a, b: u32) -> bool {
	return i32(a - b) >= 0
}

// inside says if value is in [first, first + count).
inside :: #force_inline proc "contextless" (value, first, count: u32) -> bool {
	return value - first < count
}

read_16 :: #force_inline proc "contextless" (bytes: []u8, offset: int) -> u16 {
	return u16(bytes[offset]) << 8 | u16(bytes[offset + 1])
}

read_32 :: #force_inline proc "contextless" (bytes: []u8, offset: int) -> u32 {
	return u32(bytes[offset]) << 24 | u32(bytes[offset + 1]) << 16 | u32(bytes[offset + 2]) << 8 | u32(bytes[offset + 3])
}

write_16 :: #force_inline proc "contextless" (bytes: []u8, offset: int, value: u16) {
	bytes[offset] = u8(value >> 8)
	bytes[offset + 1] = u8(value)
}

write_32 :: #force_inline proc "contextless" (bytes: []u8, offset: int, value: u32) {
	bytes[offset] = u8(value >> 24)
	bytes[offset + 1] = u8(value >> 16)
	bytes[offset + 2] = u8(value >> 8)
	bytes[offset + 3] = u8(value)
}

// sum adds bytes as 16-bit words in network order to a sum of the checksum
// of the Internet (RFC 1071). An odd last byte is the high byte of a word.
sum :: proc "contextless" (total: u64, bytes: []u8) -> u64 {
	total := total
	count := len(bytes)
	index := 0
	for ; index + 1 < count; index += 2 {
		total += u64(bytes[index]) << 8 | u64(bytes[index + 1])
	}
	if index < count {
		total += u64(bytes[index]) << 8
	}
	return total
}

// fold ends a sum: the 16 bits that the checksum field holds.
fold :: proc "contextless" (total: u64) -> u16 {
	total := total
	for total > 0xFFFF {
		total = (total & 0xFFFF) + (total >> 16)
	}
	return ~u16(total)
}

// pseudo gives the sum of the pseudo-header of TCP over IPv4.
pseudo :: proc "contextless" (source, destination: u32, length: int) -> u64 {
	return u64(source >> 16) + u64(source & 0xFFFF) + u64(destination >> 16) + u64(destination & 0xFFFF) + PROTOCOL + u64(length)
}

// checksum gives the checksum of a segment from source to destination, with
// its checksum field taken as zero.
checksum :: proc "contextless" (source, destination: u32, segment: []u8) -> u16 {
	return fold(sum(sum(pseudo(source, destination, len(segment)), segment[:16]), segment[18:]))
}

// checksum_valid says if a segment holds its checksum. The network service
// checks each segment that arrives (support/network): a program that reads
// segments from it does not call this.
checksum_valid :: proc "contextless" (source, destination: u32, segment: []u8) -> bool {
	return len(segment) >= HEADER && fold(sum(pseudo(source, destination, len(segment)), segment)) == 0
}

// header_read reads the header of a segment. ok is false when the segment
// is shorter than its header, or when its data offset or an option breaks a
// rule. An option that the library does not know is passed over.
header_read :: proc "contextless" (segment: []u8) -> (header: Header, ok: bool) {
	if len(segment) < HEADER {
		return {}, false
	}
	offset := int(segment[12] >> 4) * 4
	if offset < HEADER || offset > len(segment) {
		return {}, false
	}
	header.source_port = read_16(segment, 0)
	header.destination_port = read_16(segment, 2)
	header.sequence = read_32(segment, 4)
	header.acknowledgment = read_32(segment, 8)
	header.flags = transmute(Flags)segment[13]
	header.window = read_16(segment, 14)
	header.data = segment[offset:]
	options := segment[HEADER:offset]
	for place := 0; place < len(options); {
		kind := options[place]
		if kind == 0 {
			break // The end of the options.
		}
		if kind == 1 {
			place += 1 // No operation.
			continue
		}
		if place + 1 >= len(options) {
			return {}, false
		}
		length := int(options[place + 1])
		if length < 2 || place + length > len(options) {
			return {}, false
		}
		if kind == 2 && length == 4 {
			header.mss = read_16(options, place + 2)
		}
		place += length
	}
	return header, true
}

// header_write writes the header of a segment whose data is already at
// segment[HEADER or HEADER_MSS:], and its checksum. length is the bytes of
// the whole segment.
header_write :: proc "contextless" (segment: []u8, source, destination: u32, header: Header, length: int) {
	offset := header.mss != 0 ? HEADER_MSS : HEADER
	write_16(segment, 0, header.source_port)
	write_16(segment, 2, header.destination_port)
	write_32(segment, 4, header.sequence)
	write_32(segment, 8, header.acknowledgment)
	segment[12] = u8(offset / 4) << 4
	segment[13] = transmute(u8)header.flags
	write_16(segment, 14, header.window)
	write_16(segment, 16, 0)
	write_16(segment, 18, 0) // No urgent data.
	if header.mss != 0 {
		segment[20] = 2
		segment[21] = 4
		write_16(segment, 22, header.mss)
	}
	write_16(segment, 16, checksum(source, destination, segment[:length]))
}
