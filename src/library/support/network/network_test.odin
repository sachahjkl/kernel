#+build !freestanding
package network

import "core:math/rand"
import "core:testing"
import "support:system"

@(private = "file")
LOCAL :: Hardware{0x52, 0x54, 0x00, 0x12, 0x34, 0x56}
@(private = "file")
GATEWAY :: Hardware{0x52, 0x55, 0x0A, 0x00, 0x02, 0x02}
@(private = "file")
LOCAL_ADDRESS :: 0x0A00020F // 10.0.2.15
@(private = "file")
GATEWAY_ADDRESS :: 0x0A000202 // 10.0.2.2

// The two examples of a known answer: the sum of RFC 1071, section 3, and
// an IPv4 header with a correct checksum (0xB861) from the description of
// the header of IPv4.
@(test)
known_checksums :: proc(t: ^testing.T) {
	words := []u8{0x00, 0x01, 0xF2, 0x03, 0xF4, 0xF5, 0xF6, 0xF7}
	testing.expect_value(t, sum(0, words), 0xDDF2)
	testing.expect_value(t, checksum(sum(0, words)), 0x220D)
	header := []u8{0x45, 0x00, 0x00, 0x73, 0x00, 0x00, 0x40, 0x00, 0x40, 0x11, 0xB8, 0x61, 0xC0, 0xA8, 0x00, 0x01, 0xC0, 0xA8, 0x00, 0xC7}
	ok, expected := checked(header, 10, 0)
	testing.expect(t, ok)
	testing.expect_value(t, expected, 0xB861)
	testing.expect_value(t, sum(0, header), 0xFFFF)
}

// udp_example writes a frame as the two parts write it: the program writes
// the header and the checksum of the datagram, the network service the
// headers of IPv4 and Ethernet.
@(private = "file")
udp_example :: proc(frame: []u8, data: string) -> int {
	copy(frame[IPV4_DATA + UDP_HEADER:], data)
	length := udp_header_write(frame[IPV4_DATA:], LOCAL_ADDRESS, GATEWAY_ADDRESS, 49152, 7, len(data))
	return ipv4_frame(frame, GATEWAY, LOCAL, LOCAL_ADDRESS, GATEWAY_ADDRESS, PROTOCOL_UDP, length, 1)
}

@(test)
udp_written_then_read :: proc(t: ^testing.T) {
	frame: [2048]u8
	length := udp_example(frame[:], "a datagram")
	testing.expect_value(t, length, FRAME_LEAST) // 52 bytes, padded.
	packet, problem := parse(frame[:length])
	testing.expect_value(t, problem.kind, Problem_Kind.None)
	testing.expect_value(t, packet.kind, Packet_Kind.Udp)
	testing.expect_value(t, packet.source_port, 49152)
	testing.expect_value(t, packet.destination_port, 7)
	testing.expect_value(t, packet.source_address, LOCAL_ADDRESS)
	testing.expect_value(t, packet.destination_address, GATEWAY_ADDRESS)
	// The packet holds the whole datagram: the program reads its data, and
	// checks its checksum with the two addresses.
	testing.expect_value(t, len(packet.data), UDP_HEADER + len("a datagram"))
	data, ok := udp_data_read(packet.data, LOCAL_ADDRESS, GATEWAY_ADDRESS, .Verify)
	testing.expect(t, ok)
	testing.expect_value(t, string(data), "a datagram")
	testing.expect(t, packet.destination == GATEWAY && packet.source == LOCAL)
	// The largest datagram of one frame, and one byte more.
	datagram := frame[IPV4_DATA:]
	large := udp_header_write(datagram, LOCAL_ADDRESS, GATEWAY_ADDRESS, 1, 2, UDP_DATA_LIMIT)
	testing.expect_value(t, large, MTU - IPV4_HEADER)
	whole := ipv4_frame(frame[:], GATEWAY, LOCAL, LOCAL_ADDRESS, GATEWAY_ADDRESS, PROTOCOL_UDP, large, 2)
	testing.expect_value(t, whole, ETHERNET_HEADER + MTU)
	_, problem = parse(frame[:whole])
	testing.expect_value(t, problem.kind, Problem_Kind.None)
	testing.expect_value(t, udp_header_write(datagram, LOCAL_ADDRESS, GATEWAY_ADDRESS, 1, 2, UDP_DATA_LIMIT + 1), 0)
	testing.expect_value(t, udp_header_write(datagram[:80], LOCAL_ADDRESS, GATEWAY_ADDRESS, 1, 2, 80), 0)
	testing.expect_value(t, ipv4_frame(frame[:100], GATEWAY, LOCAL, LOCAL_ADDRESS, GATEWAY_ADDRESS, PROTOCOL_UDP, 88, 2), 0)
}

// The checksum of a datagram is for the program: parse gives a datagram
// with a wrong checksum to the endpoint of its port, and udp_data_read
// refuses it with the rule Verify. The pseudo-header counts: the same
// bytes with another address are refused too.
@(test)
udp_checksum_is_checked_by_the_program :: proc(t: ^testing.T) {
	frame: [128]u8
	length := udp_example(frame[:], "a datagram")
	frame[IPV4_DATA + UDP_HEADER + 3] ~= 1 // One bit of the data.
	packet, problem := parse(frame[:length])
	testing.expect_value(t, problem.kind, Problem_Kind.None)
	testing.expect_value(t, packet.kind, Packet_Kind.Udp)
	_, ok := udp_data_read(packet.data, LOCAL_ADDRESS, GATEWAY_ADDRESS, .Verify)
	testing.expect(t, !ok)
	// A protocol that authenticates each datagram itself takes the bytes.
	data, taken := udp_data_read(packet.data, LOCAL_ADDRESS, GATEWAY_ADDRESS, .Do_Not_Verify)
	testing.expect(t, taken && len(data) == len("a datagram"))
	// A correct datagram, and the same bytes from another address.
	length = udp_example(frame[:], "a datagram")
	packet, problem = parse(frame[:length])
	_, ok = udp_data_read(packet.data, LOCAL_ADDRESS, GATEWAY_ADDRESS, .Verify)
	testing.expect(t, problem.kind == .None && ok)
	_, ok = udp_data_read(packet.data, LOCAL_ADDRESS + 1, GATEWAY_ADDRESS, .Verify)
	testing.expect(t, !ok)
	// A datagram whose length field is not its length, and one shorter than
	// its header: refused with each rule.
	_, ok = udp_data_read(packet.data[:len(packet.data) - 1], LOCAL_ADDRESS, GATEWAY_ADDRESS, .Do_Not_Verify)
	testing.expect(t, !ok)
	_, ok = udp_data_read(packet.data[:4], LOCAL_ADDRESS, GATEWAY_ADDRESS, .Do_Not_Verify)
	testing.expect(t, !ok)
}

// A checksum that sums to zero goes on the wire as 0xFFFF, and is taken.
@(test)
udp_checksum_of_zero_is_written_as_ones :: proc(t: ^testing.T) {
	datagram: [UDP_HEADER + 2]u8
	// Find the two bytes of data that make the checksum zero: the sum of
	// the other words, complemented.
	length := udp_header_write(datagram[:], LOCAL_ADDRESS, GATEWAY_ADDRESS, 49152, 7, 2)
	testing.expect_value(t, length, UDP_HEADER + 2)
	field := read_16(datagram[:], 6)
	write_16(datagram[:], UDP_HEADER, field) // The data takes what the checksum held: the sum is now all ones.
	length = udp_header_write(datagram[:], LOCAL_ADDRESS, GATEWAY_ADDRESS, 49152, 7, 2)
	testing.expect_value(t, read_16(datagram[:], 6), 0xFFFF)
	_, ok := udp_data_read(datagram[:length], LOCAL_ADDRESS, GATEWAY_ADDRESS, .Verify)
	testing.expect(t, ok)
}

// A datagram with an odd count of bytes: its last byte is the high byte of
// the last word of the sum. The test sums the words by hand, apart from the
// library: the pseudo-header, the header with its checksum and the data
// fold to all ones. The last byte is in the checksum: one changed bit of it
// is refused.
@(test)
udp_checksum_with_an_odd_length :: proc(t: ^testing.T) {
	for text in ([]string{"after a key", "x", "an odd text of 23 bytes"}) {
		datagram: [UDP_HEADER + 32]u8
		copy(datagram[UDP_HEADER:], text)
		length := udp_header_write(datagram[:], LOCAL_ADDRESS, GATEWAY_ADDRESS, 49152, 7, len(text))
		testing.expect_value(t, length, UDP_HEADER + len(text))
		testing.expect_value(t, length % 2, 1)
		total := u32(LOCAL_ADDRESS >> 16) + u32(LOCAL_ADDRESS & 0xFFFF) + u32(GATEWAY_ADDRESS >> 16) + u32(GATEWAY_ADDRESS & 0xFFFF) + u32(PROTOCOL_UDP) + u32(length)
		for index := 0; index < length; index += 2 {
			total += u32(datagram[index]) << 8
			if index + 1 < length {
				total += u32(datagram[index + 1])
			}
		}
		for total > 0xFFFF {
			total = (total & 0xFFFF) + (total >> 16)
		}
		testing.expect_value(t, total, 0xFFFF)
		data, ok := udp_data_read(datagram[:length], LOCAL_ADDRESS, GATEWAY_ADDRESS, .Verify)
		testing.expect(t, ok && string(data) == text)
		datagram[length - 1] ~= 0x01
		_, ok = udp_data_read(datagram[:length], LOCAL_ADDRESS, GATEWAY_ADDRESS, .Verify)
		testing.expect(t, !ok, "the last byte of an odd datagram is not in the checksum")
		datagram[length - 1] ~= 0x01
		// The length field one more and one less than the count: refused
		// with each rule, before any read of the checksum.
		write_16(datagram[:], 4, u16(length + 1))
		_, ok = udp_data_read(datagram[:length], LOCAL_ADDRESS, GATEWAY_ADDRESS, .Do_Not_Verify)
		testing.expect(t, !ok)
		write_16(datagram[:], 4, u16(length - 1))
		_, ok = udp_data_read(datagram[:length], LOCAL_ADDRESS, GATEWAY_ADDRESS, .Verify)
		testing.expect(t, !ok)
	}
	// A datagram of 7 bytes, whose field would say 7: under its header.
	short: [7]u8
	write_16(short[:], 4, 7)
	_, short_taken := udp_data_read(short[:], LOCAL_ADDRESS, GATEWAY_ADDRESS, .Do_Not_Verify)
	testing.expect(t, !short_taken)
}

@(test)
arp_and_echo_written_then_read :: proc(t: ^testing.T) {
	frame: [128]u8
	length := arp_frame(frame[:], ARP_REQUEST, LOCAL, LOCAL_ADDRESS, {}, GATEWAY_ADDRESS)
	packet, problem := parse(frame[:length])
	testing.expect_value(t, problem.kind, Problem_Kind.None)
	testing.expect_value(t, packet.kind, Packet_Kind.Arp)
	testing.expect_value(t, packet.operation, ARP_REQUEST)
	testing.expect(t, packet.destination == BROADCAST && packet.sender_hardware == LOCAL)
	testing.expect_value(t, packet.target_address, GATEWAY_ADDRESS)
	length = arp_frame(frame[:], ARP_REPLY, GATEWAY, GATEWAY_ADDRESS, LOCAL, LOCAL_ADDRESS)
	packet, problem = parse(frame[:length])
	testing.expect(t, problem.kind == .None && packet.operation == ARP_REPLY && packet.destination == LOCAL && packet.target_hardware == LOCAL && packet.sender_address == GATEWAY_ADDRESS)

	copy(frame[ICMP_DATA:], "ping")
	length = echo_frame(frame[:], GATEWAY, LOCAL, LOCAL_ADDRESS, GATEWAY_ADDRESS, ICMP_ECHO_REQUEST, 3, 9, 4, 5)
	packet, problem = parse(frame[:length])
	testing.expect_value(t, problem.kind, Problem_Kind.None)
	testing.expect_value(t, packet.kind, Packet_Kind.Icmp)
	testing.expect(t, packet.icmp_kind == ICMP_ECHO_REQUEST && packet.identifier == 3 && packet.sequence == 9 && string(packet.data) == "ping")
	testing.expect_value(t, frame[ETHERNET_HEADER + 8], TTL)
}

// One malformed frame, and the problem that parse must give.
@(private = "file")
Malformed :: struct {
	name:   string,
	change: proc(frame: []u8) -> int, // Changes a valid UDP frame of 52 bytes; gives the new length.
	kind:   Problem_Kind,
	layer:  Layer,
	offset: u16,
	value:  u32,
	limit:  u32,
}

@(private = "file")
fix_ipv4 :: proc(frame: []u8) {
	write_16(frame, ETHERNET_HEADER + 10, 0)
	write_16(frame, ETHERNET_HEADER + 10, checksum(sum(0, frame[ETHERNET_HEADER:][:IPV4_HEADER])))
}

@(test)
malformed_frames :: proc(t: ^testing.T) {
	cases := []Malformed {
		{"10 bytes", proc(frame: []u8) -> int {return 10}, .Too_Short, .Ethernet, 0, 10, 14},
		{"IPv6", proc(frame: []u8) -> int {write_16(frame, 12, 0x86DD); return 60}, .Unsupported, .Ethernet, 12, 0x86DD, 0},
		{"30 bytes of IPv4", proc(frame: []u8) -> int {return 30}, .Too_Short, .Ipv4, 14, 16, 20},
		{"version 6", proc(frame: []u8) -> int {frame[14] = 0x65; return 60}, .Bad_Header, .Ipv4, 14, 6, 4},
		{"header of 16 bytes", proc(frame: []u8) -> int {frame[14] = 0x44; return 60}, .Bad_Header, .Ipv4, 14, 4, 5},
		{"header longer than the frame", proc(frame: []u8) -> int {frame[14] = 0x4F; return 60}, .Too_Short, .Ipv4, 14, 46, 60},
		{"total length after the frame", proc(frame: []u8) -> int {write_16(frame, 16, 400); fix_ipv4(frame); return 60}, .Bad_Length, .Ipv4, 16, 400, 46},
		{"total length in the header", proc(frame: []u8) -> int {write_16(frame, 16, 12); fix_ipv4(frame); return 60}, .Bad_Length, .Ipv4, 16, 12, 20},
		{"header checksum", proc(frame: []u8) -> int {frame[24] ~= 0xFF; return 60}, .Bad_Checksum, .Ipv4, 24, 0, 0},
		{"a fragment", proc(frame: []u8) -> int {write_16(frame, 20, 0x2000); fix_ipv4(frame); return 60}, .Unsupported, .Ipv4, 20, 0x2000, 0},
		{"protocol 99", proc(frame: []u8) -> int {frame[23] = 99; fix_ipv4(frame); return 60}, .Unsupported, .Ipv4, 23, 99, 0},
		{"UDP of 4 bytes", proc(frame: []u8) -> int {write_16(frame, 16, 24); fix_ipv4(frame); return 60}, .Too_Short, .Udp, 34, 4, 8},
		{"UDP length after the datagram", proc(frame: []u8) -> int {write_16(frame, 38, 300); return 60}, .Bad_Length, .Udp, 38, 300, 18},
		{"UDP length under the header", proc(frame: []u8) -> int {write_16(frame, 38, 3); return 60}, .Bad_Length, .Udp, 38, 3, 8},
		{"ARP of 20 bytes", proc(frame: []u8) -> int {write_16(frame, 12, KIND_ARP); return 34}, .Too_Short, .Arp, 14, 20, 28},
		{"ARP hardware size 8", proc(frame: []u8) -> int {
				arp_frame(frame, ARP_REQUEST, LOCAL, LOCAL_ADDRESS, {}, GATEWAY_ADDRESS)
				frame[18] = 8
				return 60
			}, .Bad_Header, .Arp, 18, 8, 6},
		{"ICMP checksum", proc(frame: []u8) -> int {
				copy(frame[ICMP_DATA:], "ping")
				echo_frame(frame, GATEWAY, LOCAL, LOCAL_ADDRESS, GATEWAY_ADDRESS, ICMP_ECHO_REQUEST, 1, 1, 4, 1)
				frame[ICMP_DATA] ~= 0x40
				return 60
			}, .Bad_Checksum, .Icmp, 36, 0, 0},
		{"ICMP of another kind", proc(frame: []u8) -> int {
				echo_frame(frame, GATEWAY, LOCAL, LOCAL_ADDRESS, GATEWAY_ADDRESS, 13, 1, 1, 0, 1)
				return 60
			}, .Unsupported, .Icmp, 34, 13 << 8, 0},
	}
	for item in cases {
		frame: [128]u8
		udp_example(frame[:], "a datagram")
		length := item.change(frame[:])
		packet, problem := parse(frame[:length])
		testing.expectf(t, problem.kind == item.kind && problem.layer == item.layer && problem.offset == item.offset, "%s: %v", item.name, problem)
		if item.kind != .Bad_Checksum {
			testing.expectf(t, problem.value == item.value && problem.limit == item.limit, "%s: %v", item.name, problem)
		} else {
			testing.expectf(t, problem.value != problem.limit, "%s: %v", item.name, problem)
		}
		testing.expectf(t, packet.kind == .None, "%s: a packet from a malformed frame", item.name)
	}
}

// A checksum of zero in UDP means "no checksum": the datagram is read.
@(test)
udp_with_no_checksum :: proc(t: ^testing.T) {
	frame: [128]u8
	length := udp_example(frame[:], "no check")
	write_16(frame[:], 40, 0)
	packet, problem := parse(frame[:length])
	data, ok := udp_data_read(packet.data, LOCAL_ADDRESS, GATEWAY_ADDRESS, .Verify)
	testing.expect(t, problem.kind == .None && ok && string(data) == "no check")
}

// Random damage: each byte can change, and the frame can end anywhere.
// parse never reads outside the frame (the test build checks each index),
// and the data of a packet is always inside the frame.
@(test)
random_damage :: proc(t: ^testing.T) {
	valid: [3][2048]u8
	lengths: [3]int
	lengths[0] = udp_example(valid[0][:], "a datagram with some bytes")
	lengths[1] = arp_frame(valid[1][:], ARP_REPLY, GATEWAY, GATEWAY_ADDRESS, LOCAL, LOCAL_ADDRESS)
	copy(valid[2][ICMP_DATA:], "echo")
	lengths[2] = echo_frame(valid[2][:], GATEWAY, LOCAL, LOCAL_ADDRESS, GATEWAY_ADDRESS, ICMP_ECHO_REPLY, 1, 2, 4, 3)
	read := 0
	for round in 0 ..< 20_000 {
		which := round % 3
		frame := valid[which]
		length := lengths[which]
		for _ in 0 ..< 1 + rand.int_max(4) {
			frame[rand.int_max(length)] = u8(rand.int_max(256))
		}
		if rand.int_max(4) == 0 {
			length = rand.int_max(length + 1)
		}
		packet, problem := parse(frame[:length])
		if problem.kind == .None {
			read += 1
			base := uintptr(raw_data(frame[:]))
			start := uintptr(raw_data(packet.data))
			testing.expect(t, len(packet.data) == 0 || (start >= base && start + uintptr(len(packet.data)) <= base + uintptr(length)))
		} else {
			testing.expect(t, int(problem.offset) <= length)
		}
	}
	testing.expect(t, read > 0)
}

@(test)
problem_sentence :: proc(t: ^testing.T) {
	buffer: [128]u8
	writer := system.Writer{buffer = buffer[:]}
	problem_write(&writer, {kind = .Bad_Checksum, layer = .Ipv4, offset = 24, value = 0x1234, limit = 0xABCD})
	testing.expect_value(t, system.written(&writer), "ipv4, byte 24: the checksum is 0x1234, the bytes give 0xabcd")
	writer.count = 0
	problem_write(&writer, {kind = Problem_Kind(200), layer = Layer(77)})
	testing.expect_value(t, system.written(&writer), "frame, byte 0: an unknown problem")
}

// tcp_example writes a frame with a segment from the gateway to this
// machine: 20 bytes of header, then data, with its checksum.
@(private = "file")
tcp_example :: proc(frame: []u8, data: string) -> int {
	segment := frame[IPV4_DATA:][:TCP_HEADER + len(data)]
	write_16(segment, 0, 80)
	write_16(segment, 2, 49200)
	write_32(segment, 4, 1000)
	write_32(segment, 8, 2000)
	segment[12] = 5 << 4
	segment[13] = 0x18 // PSH, ACK.
	write_16(segment, 14, 8192)
	copy(segment[TCP_HEADER:], data)
	write_16(segment, 16, checksum(sum(pseudo(GATEWAY_ADDRESS, LOCAL_ADDRESS, PROTOCOL_TCP, len(segment)), segment)))
	return ipv4_frame(frame, LOCAL, GATEWAY, GATEWAY_ADDRESS, LOCAL_ADDRESS, PROTOCOL_TCP, len(segment), 7)
}

@(test)
tcp_segment_read :: proc(t: ^testing.T) {
	frame: [128]u8
	length := tcp_example(frame[:], "GET / HTTP/1.1")
	packet, problem := parse(frame[:length])
	testing.expect_value(t, problem.kind, Problem_Kind.None)
	testing.expect_value(t, packet.kind, Packet_Kind.Tcp)
	testing.expect_value(t, packet.source_port, 80)
	testing.expect_value(t, packet.destination_port, 49200)
	testing.expect_value(t, packet.tcp_flags, 0x18)
	testing.expect_value(t, len(packet.data), TCP_HEADER + 14)
	testing.expect_value(t, string(packet.data[TCP_HEADER:]), "GET / HTTP/1.1")
}

@(test)
tcp_malformed :: proc(t: ^testing.T) {
	Case :: struct {
		name:   string,
		change: proc(frame: []u8) -> int,
		kind:   Problem_Kind,
		offset: u16,
		value:  u32,
		limit:  u32,
	}
	cases := []Case {
		{"a segment of 10 bytes", proc(frame: []u8) -> int {write_16(frame, 16, 30); fix_ipv4(frame); return 60}, .Too_Short, 34, 10, 20},
		{"a data offset of 16 bytes", proc(frame: []u8) -> int {frame[46] = 4 << 4; return 74}, .Bad_Header, 46, 4, 5},
		{"a data offset after the segment", proc(frame: []u8) -> int {frame[46] = 15 << 4; return 74}, .Bad_Length, 46, 60, 40},
	}
	for item in cases {
		frame: [128]u8
		tcp_example(frame[:], "twenty bytes of data")
		length := item.change(frame[:])
		packet, problem := parse(frame[:length])
		testing.expectf(t, problem.kind == item.kind && problem.layer == .Tcp && problem.offset == item.offset, "%s: %v", item.name, problem)
		testing.expectf(t, problem.value == item.value && problem.limit == item.limit, "%s: %v", item.name, problem)
		testing.expectf(t, packet.kind == .None, "%s: a packet from a malformed frame", item.name)
	}
}

// The checksum of a segment is for TCP in the program: parse gives a
// segment with a wrong checksum to the endpoint of its port.
@(test)
tcp_checksum_is_not_checked_here :: proc(t: ^testing.T) {
	frame: [128]u8
	length := tcp_example(frame[:], "twenty bytes of data")
	frame[60] ~= 1 // One bit of the data.
	packet, problem := parse(frame[:length])
	testing.expect_value(t, problem.kind, Problem_Kind.None)
	testing.expect_value(t, packet.kind, Packet_Kind.Tcp)
	testing.expect_value(t, len(packet.data), TCP_HEADER + 20)
}
