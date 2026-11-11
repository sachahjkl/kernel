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

@(private = "file")
udp_example :: proc(frame: []u8, data: string) -> int {
	copy(frame[UDP_DATA:], data)
	return udp_frame(frame, GATEWAY, LOCAL, LOCAL_ADDRESS, GATEWAY_ADDRESS, 49152, 7, len(data), 1)
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
	testing.expect_value(t, string(packet.data), "a datagram")
	testing.expect(t, packet.destination == GATEWAY && packet.source == LOCAL)
	// The largest datagram of one frame, and one byte more.
	large := udp_frame(frame[:], GATEWAY, LOCAL, LOCAL_ADDRESS, GATEWAY_ADDRESS, 1, 2, UDP_DATA_LIMIT, 2)
	testing.expect_value(t, large, ETHERNET_HEADER + MTU)
	_, problem = parse(frame[:large])
	testing.expect_value(t, problem.kind, Problem_Kind.None)
	testing.expect_value(t, udp_frame(frame[:], GATEWAY, LOCAL, LOCAL_ADDRESS, GATEWAY_ADDRESS, 1, 2, UDP_DATA_LIMIT + 1, 2), 0)
	testing.expect_value(t, udp_frame(frame[:100], GATEWAY, LOCAL, LOCAL_ADDRESS, GATEWAY_ADDRESS, 1, 2, 80, 2), 0)
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
		{"UDP checksum", proc(frame: []u8) -> int {frame[45] ~= 1; return 60}, .Bad_Checksum, .Udp, 40, 0, 0},
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
	testing.expect(t, problem.kind == .None && string(packet.data) == "no check")
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
		{"the checksum", proc(frame: []u8) -> int {frame[60] ~= 1; return 74}, .Bad_Checksum, 50, 0, 0},
	}
	for item in cases {
		frame: [128]u8
		tcp_example(frame[:], "twenty bytes of data")
		length := item.change(frame[:])
		packet, problem := parse(frame[:length])
		testing.expectf(t, problem.kind == item.kind && problem.layer == .Tcp && problem.offset == item.offset, "%s: %v", item.name, problem)
		if item.kind != .Bad_Checksum {
			testing.expectf(t, problem.value == item.value && problem.limit == item.limit, "%s: %v", item.name, problem)
		}
		testing.expectf(t, packet.kind == .None, "%s: a packet from a malformed frame", item.name)
	}
}
