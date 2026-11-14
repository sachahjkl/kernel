// The protocols of the network service: Ethernet, ARP, IPv4 and ICMP echo,
// and the checks of the header of a UDP datagram and of a TCP segment. The
// functions read and write frames in memory that the caller gives; they do
// no input or output, allocate nothing and keep no state, so the host runs
// their tests (network_test.odin).
//
// The network service reads no byte of the data of a datagram or of a
// segment here: `parse` checks the lengths and the header, not the
// checksum of the transport. The program checks that checksum, after the
// network service found its endpoint: TCP in src/library/support/tcp, UDP with
// `udp_data_read` of this package. The program also writes the header and
// the checksum of what it sends: `udp_header_write` for a datagram
// (docs/NETWORK.md, "The path of a datagram and of a segment").
//
// A frame from the wire is input that nobody checked. parse reads each field
// only after it checked that the bytes are there; a frame that breaks a
// rule gives a Problem: the layer, the kind, the byte of the frame, the bad
// value and the value that the layer needs. It never faults.
//
// Numbers are in the order of the machine; the frame holds them in network
// order (the first byte is the high byte). An IPv4 address is a u32:
// 10.0.2.15 is 0x0A00020F.
//
// Who uses it: the network service (`src/programs/network`), which parses each
// frame of the frame service with `parse` and writes the frames of its
// endpoints with the `_frame` procedures, and keeps the tables of
// `tables.odin` (the refused frames, the admitted remotes, the neighbors);
// and each program with a datagram endpoint, which writes and reads its
// datagrams with `udp_header_write` and `udp_data_read`.
//
// See [network service](term:network-service) and (docs/NETWORK.md).
package network

import "modus:contract/datagram"
import "modus:contract/errors"
import "modus:contract/ring"
import "modus:support/system"

Hardware :: [6]u8 // A hardware address of Ethernet.
BROADCAST :: Hardware{0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF} // The hardware address of each device of the link.

ETHERNET_HEADER :: 14 // Two hardware addresses and the kind.
IPV4_HEADER :: 20 // With no options: the header that this library writes.
UDP_HEADER :: 8 // The header of UDP.
TCP_HEADER :: 20 // With no option.
ICMP_HEADER :: 8 // The header of an ICMP echo.
ARP_SIZE :: 28 // An ARP message of Ethernet and IPv4.
FRAME_LEAST :: 60 // A shorter frame gets zero bytes at its end.
MTU :: 1500 // The bytes of IPv4 in one frame.
ICMP_DATA :: ETHERNET_HEADER + IPV4_HEADER + ICMP_HEADER // The place of the data of an echo that this library writes.
IPV4_DATA :: ETHERNET_HEADER + IPV4_HEADER // The place of a datagram or a segment in a frame that this library writes.
UDP_DATA_LIMIT :: MTU - IPV4_HEADER - UDP_HEADER // 1472: no fragment.
ICMP_DATA_LIMIT :: MTU - IPV4_HEADER - ICMP_HEADER // 1472: the data of one echo with no fragment.

KIND_IPV4 :: 0x0800 // The kind of an Ethernet frame of IPv4.
KIND_ARP :: 0x0806 // The kind of an Ethernet frame of ARP.
PROTOCOL_ICMP :: 1 // The protocol number of ICMP in IPv4.
PROTOCOL_UDP :: 17 // The protocol number of UDP.
PROTOCOL_TCP :: 6 // The protocol number of TCP.
ICMP_ECHO_REPLY :: 0 // The type of an echo reply.
ICMP_ECHO_REQUEST :: 8 // The type of an echo request.
ARP_REQUEST :: 1 // The operation of an ARP request.
ARP_REPLY :: 2 // The operation of an ARP reply.
TTL :: 64 // The time to live of each packet that this library writes.

// The error of a frame is a record of the datagram contract, because the
// network service gives it to programs, and an error must inform the
// program that receives it. parse gives the kinds Too_Short to Unsupported.
Layer :: datagram.Layer
Problem_Kind :: datagram.Problem_Kind
Problem :: datagram.Problem

// What a frame holds, as `parse` found it.
Packet_Kind :: enum u8 {
	None = 0, // Nothing that the library takes.
	Arp  = 1, // An ARP message.
	Icmp = 2, // An ICMP echo.
	Udp  = 3, // A UDP datagram.
	Tcp  = 4, // A TCP segment.
}

// What parse found in a frame. data is a part of the frame.
Packet :: struct {
	kind:             Packet_Kind, // What the frame holds.
	destination:      Hardware, // The hardware address of the receiver.
	source:           Hardware, // The hardware address of the sender.
	// ARP.
	operation:        u16,
	sender_hardware:  Hardware, // ARP: the hardware address of the sender.
	target_hardware:  Hardware, // ARP: the hardware address asked or answered.
	sender_address:   u32, // ARP: the IPv4 address of the sender.
	target_address:   u32, // ARP: the IPv4 address asked.
	// IPv4.
	source_address:   u32,
	destination_address: u32, // IPv4: the receiver.
	ttl:              u8, // IPv4: the time to live.
	// ICMP echo.
	icmp_kind:        u8,
	identifier:       u16, // ICMP echo: the identifier.
	sequence:         u16, // ICMP echo: the sequence number.
	// UDP and TCP.
	source_port:      u16,
	destination_port: u16, // UDP and TCP: the port of the receiver.
	data:             []u8, // ICMP echo: the data. UDP: the whole datagram, with its header. TCP: the whole segment, with its header.
	tcp_flags:        u8, // TCP: the control bits.
}

// read_16 reads a number of 16 bits in network order.
read_16 :: #force_inline proc "contextless" (bytes: []u8, offset: int) -> u16 {
	return u16(bytes[offset]) << 8 | u16(bytes[offset + 1])
}

// read_32 reads a number of 32 bits in network order.
read_32 :: #force_inline proc "contextless" (bytes: []u8, offset: int) -> u32 {
	return u32(bytes[offset]) << 24 | u32(bytes[offset + 1]) << 16 | u32(bytes[offset + 2]) << 8 | u32(bytes[offset + 3])
}

// write_16 writes a number of 16 bits in network order.
write_16 :: #force_inline proc "contextless" (bytes: []u8, offset: int, value: u16) {
	bytes[offset] = u8(value >> 8)
	bytes[offset + 1] = u8(value)
}

// write_32 writes a number of 32 bits in network order.
write_32 :: #force_inline proc "contextless" (bytes: []u8, offset: int, value: u32) {
	bytes[offset] = u8(value >> 24)
	bytes[offset + 1] = u8(value >> 16)
	bytes[offset + 2] = u8(value >> 8)
	bytes[offset + 3] = u8(value)
}

// sum adds the bytes as 16-bit words in network order, to a sum of the
// checksum of the Internet (RFC 1071). An odd last byte is the high byte of
// a word.
sum :: proc "contextless" (total: u32, bytes: []u8) -> u32 {
	total := u64(total)
	count := len(bytes)
	index := 0
	for ; index + 1 < count; index += 2 {
		total += u64(bytes[index]) << 8 | u64(bytes[index + 1])
	}
	if index < count {
		total += u64(bytes[index]) << 8
	}
	for total > 0xFFFF {
		total = (total & 0xFFFF) + (total >> 16)
	}
	return u32(total)
}

// checksum ends a sum: the 16 bits that the field holds.
checksum :: proc "contextless" (total: u32) -> u16 {
	return ~u16(sum(total, nil))
}

// pseudo gives the sum of the pseudo-header of UDP or of TCP over IPv4.
pseudo :: proc "contextless" (source, destination: u32, protocol: u8, length: int) -> u32 {
	return (source >> 16) + (source & 0xFFFF) + (destination >> 16) + (destination & 0xFFFF) + u32(protocol) + u32(length)
}

// checked tells if the 16-bit field at `field` of bytes holds the checksum of
// the bytes, with a sum to add (a pseudo-header). It gives the checksum of
// the bytes with the field as zero.
checked :: proc "contextless" (bytes: []u8, field: int, extra: u32) -> (ok: bool, expected: u16) {
	total := sum(sum(extra, bytes[:field]), bytes[field + 2:])
	expected = checksum(total)
	return read_16(bytes, field) == expected, expected
}

// parse reads one frame. problem.kind is None when the frame has a known
// packet; then packet.kind says which.
parse :: proc "contextless" (frame: []u8) -> (packet: Packet, problem: Problem) {
	if len(frame) < ETHERNET_HEADER {
		return {}, {kind = .Too_Short, layer = .Ethernet, offset = 0, value = u32(len(frame)), limit = ETHERNET_HEADER}
	}
	copy(packet.destination[:], frame[0:6])
	copy(packet.source[:], frame[6:12])
	kind := read_16(frame, 12)
	switch kind {
	case KIND_ARP:
		return arp_parse(frame, packet)
	case KIND_IPV4:
		return ipv4_parse(frame, packet)
	}
	return packet, {kind = .Unsupported, layer = .Ethernet, offset = 12, value = u32(kind)}
}

// arp_parse reads the ARP message of a frame.
@(private)
arp_parse :: proc "contextless" (frame: []u8, packet: Packet) -> (Packet, Problem) {
	packet := packet
	B :: ETHERNET_HEADER
	if len(frame) - B < ARP_SIZE {
		return packet, {kind = .Too_Short, layer = .Arp, offset = B, value = u32(len(frame) - B), limit = ARP_SIZE}
	}
	Field :: struct {
		offset, size: int,
		value:        u32,
	}
	// Ethernet, IPv4, 6 bytes, 4 bytes.
	fields := [4]Field{{0, 2, 1}, {2, 2, KIND_IPV4}, {4, 1, 6}, {5, 1, 4}}
	for field in fields {
		value := field.size == 2 ? u32(read_16(frame, B + field.offset)) : u32(frame[B + field.offset])
		if value != field.value {
			return packet, {kind = .Bad_Header, layer = .Arp, offset = u16(B + field.offset), value = value, limit = field.value}
		}
	}
	packet.operation = read_16(frame, B + 6)
	if packet.operation != ARP_REQUEST && packet.operation != ARP_REPLY {
		return packet, {kind = .Unsupported, layer = .Arp, offset = B + 6, value = u32(packet.operation)}
	}
	copy(packet.sender_hardware[:], frame[B + 8:][:6])
	packet.sender_address = read_32(frame, B + 14)
	copy(packet.target_hardware[:], frame[B + 18:][:6])
	packet.target_address = read_32(frame, B + 24)
	packet.kind = .Arp
	return packet, {}
}

// ipv4_parse reads the IPv4 header of a frame, then its ICMP, UDP or TCP.
@(private)
ipv4_parse :: proc "contextless" (frame: []u8, packet: Packet) -> (Packet, Problem) {
	packet := packet
	B :: ETHERNET_HEADER
	available := len(frame) - B
	if available < IPV4_HEADER {
		return packet, {kind = .Too_Short, layer = .Ipv4, offset = B, value = u32(available), limit = IPV4_HEADER}
	}
	version := frame[B] >> 4
	if version != 4 {
		return packet, {kind = .Bad_Header, layer = .Ipv4, offset = B, value = u32(version), limit = 4}
	}
	header := int(frame[B] & 15) * 4
	if header < IPV4_HEADER {
		return packet, {kind = .Bad_Header, layer = .Ipv4, offset = B, value = u32(header / 4), limit = IPV4_HEADER / 4}
	}
	if header > available {
		return packet, {kind = .Too_Short, layer = .Ipv4, offset = B, value = u32(available), limit = u32(header)}
	}
	total := int(read_16(frame, B + 2))
	if total < header {
		return packet, {kind = .Bad_Length, layer = .Ipv4, offset = B + 2, value = u32(total), limit = u32(header)}
	}
	if total > available {
		return packet, {kind = .Bad_Length, layer = .Ipv4, offset = B + 2, value = u32(total), limit = u32(available)}
	}
	if ok, expected := checked(frame[B:][:header], 10, 0); !ok {
		return packet, {kind = .Bad_Checksum, layer = .Ipv4, offset = B + 10, value = u32(read_16(frame, B + 10)), limit = u32(expected)}
	}
	fragment := read_16(frame, B + 6)
	if fragment & 0x3FFF != 0 { // More fragments, or a fragment after the first.
		return packet, {kind = .Unsupported, layer = .Ipv4, offset = B + 6, value = u32(fragment)}
	}
	packet.ttl = frame[B + 8]
	packet.source_address = read_32(frame, B + 12)
	packet.destination_address = read_32(frame, B + 16)
	// The bytes after total are the zero bytes of a short frame.
	payload := frame[B + header:B + total]
	offset := B + header
	switch frame[B + 9] {
	case PROTOCOL_ICMP:
		return icmp_parse(payload, offset, packet)
	case PROTOCOL_UDP:
		return udp_parse(payload, offset, packet)
	case PROTOCOL_TCP:
		return tcp_parse(payload, offset, packet)
	}
	return packet, {kind = .Unsupported, layer = .Ipv4, offset = B + 9, value = u32(frame[B + 9])}
}

// icmp_parse reads an ICMP echo.
@(private)
icmp_parse :: proc "contextless" (message: []u8, offset: int, packet: Packet) -> (Packet, Problem) {
	packet := packet
	if len(message) < ICMP_HEADER {
		return packet, {kind = .Too_Short, layer = .Icmp, offset = u16(offset), value = u32(len(message)), limit = ICMP_HEADER}
	}
	if ok, expected := checked(message, 2, 0); !ok {
		return packet, {kind = .Bad_Checksum, layer = .Icmp, offset = u16(offset + 2), value = u32(read_16(message, 2)), limit = u32(expected)}
	}
	packet.icmp_kind = message[0]
	if (packet.icmp_kind != ICMP_ECHO_REQUEST && packet.icmp_kind != ICMP_ECHO_REPLY) || message[1] != 0 {
		return packet, {kind = .Unsupported, layer = .Icmp, offset = u16(offset), value = u32(packet.icmp_kind) << 8 | u32(message[1])}
	}
	packet.identifier = read_16(message, 4)
	packet.sequence = read_16(message, 6)
	packet.data = message[ICMP_HEADER:]
	packet.kind = .Icmp
	return packet, {}
}

// udp_parse checks the header of a UDP datagram: its length. It reads no
// byte of the data: the checksum is for the program (udp_data_read).
@(private)
udp_parse :: proc "contextless" (datagram: []u8, offset: int, packet: Packet) -> (Packet, Problem) {
	packet := packet
	if len(datagram) < UDP_HEADER {
		return packet, {kind = .Too_Short, layer = .Udp, offset = u16(offset), value = u32(len(datagram)), limit = UDP_HEADER}
	}
	length := int(read_16(datagram, 4))
	if length < UDP_HEADER {
		return packet, {kind = .Bad_Length, layer = .Udp, offset = u16(offset + 4), value = u32(length), limit = UDP_HEADER}
	}
	if length > len(datagram) {
		return packet, {kind = .Bad_Length, layer = .Udp, offset = u16(offset + 4), value = u32(length), limit = u32(len(datagram))}
	}
	packet.source_port = read_16(datagram, 0)
	packet.destination_port = read_16(datagram, 2)
	packet.data = datagram[:length]
	packet.kind = .Udp
	return packet, {}
}

// tcp_parse checks the header of a segment: its length and its data
// offset. It reads no byte of the data: the checksum and the rest of the
// segment are for TCP in the program (src/library/support/tcp).
@(private)
tcp_parse :: proc "contextless" (segment: []u8, offset: int, packet: Packet) -> (Packet, Problem) {
	packet := packet
	if len(segment) < TCP_HEADER {
		return packet, {kind = .Too_Short, layer = .Tcp, offset = u16(offset), value = u32(len(segment)), limit = TCP_HEADER}
	}
	header := int(segment[12] >> 4) * 4
	if header < TCP_HEADER {
		return packet, {kind = .Bad_Header, layer = .Tcp, offset = u16(offset + 12), value = u32(header / 4), limit = TCP_HEADER / 4}
	}
	if header > len(segment) {
		return packet, {kind = .Bad_Length, layer = .Tcp, offset = u16(offset + 12), value = u32(header), limit = u32(len(segment))}
	}
	packet.source_port = read_16(segment, 0)
	packet.destination_port = read_16(segment, 2)
	packet.tcp_flags = segment[13]
	packet.data = segment
	packet.kind = .Tcp
	return packet, {}
}

// ethernet_write writes the header of a frame.
ethernet_write :: proc "contextless" (frame: []u8, destination, source: Hardware, kind: u16) {
	hardware_put(frame, 0, destination)
	hardware_put(frame, 6, source)
	write_16(frame, 12, kind)
}

// ipv4_write writes the header of IPv4 after the header of Ethernet, for
// payload bytes after it. No fragment: the flag "do not fragment" is set.
ipv4_write :: proc "contextless" (frame: []u8, source, destination: u32, protocol: u8, payload: int, identification: u16) {
	header := frame[ETHERNET_HEADER:][:IPV4_HEADER]
	header[0] = 0x45
	header[1] = 0
	write_16(header, 2, u16(IPV4_HEADER + payload))
	write_16(header, 4, identification)
	write_16(header, 6, 0x4000)
	header[8] = TTL
	header[9] = protocol
	write_16(header, 10, 0)
	write_32(header, 12, source)
	write_32(header, 16, destination)
	write_16(header, 10, checksum(sum(0, header)))
}

// pad writes zero bytes after a frame of length bytes up to FRAME_LEAST,
// and gives the length to send.
pad :: proc "contextless" (frame: []u8, length: int) -> int {
	if length >= FRAME_LEAST {
		return length
	}
	for index in length ..< FRAME_LEAST {
		frame[index] = 0
	}
	return FRAME_LEAST
}

// arp_frame writes an ARP request (to the broadcast address) or reply. It
// gives the length of the frame, or 0 when frame is too small.
arp_frame :: proc "contextless" (frame: []u8, operation: u16, sender_hardware: Hardware, sender_address: u32, target_hardware: Hardware, target_address: u32) -> int {
	if len(frame) < FRAME_LEAST {
		return 0
	}
	ethernet_write(frame, operation == ARP_REQUEST ? BROADCAST : target_hardware, sender_hardware, KIND_ARP)
	arp := frame[ETHERNET_HEADER:][:ARP_SIZE]
	write_16(arp, 0, 1)
	write_16(arp, 2, KIND_IPV4)
	arp[4] = 6
	arp[5] = 4
	write_16(arp, 6, operation)
	hardware_put(arp, 8, sender_hardware)
	write_32(arp, 14, sender_address)
	hardware_put(arp, 18, operation == ARP_REQUEST ? Hardware{} : target_hardware)
	write_32(arp, 24, target_address)
	return pad(frame, ETHERNET_HEADER + ARP_SIZE)
}

// ipv4_frame writes the headers of Ethernet and IPv4 of a frame whose
// payload of payload bytes is already at frame[IPV4_DATA:]: a datagram or a
// segment that the program wrote with its header and its checksum. It
// reads no byte of the payload. It gives the length of the frame, or 0 when
// the payload is too large.
ipv4_frame :: proc "contextless" (frame: []u8, destination, source: Hardware, source_address, destination_address: u32, protocol: u8, payload: int, identification: u16) -> int {
	if payload < 0 || payload > MTU - IPV4_HEADER || len(frame) < max(IPV4_DATA + payload, FRAME_LEAST) {
		return 0
	}
	ethernet_write(frame, destination, source, KIND_IPV4)
	ipv4_write(frame, source_address, destination_address, protocol, payload, identification)
	return pad(frame, IPV4_DATA + payload)
}

// udp_header_write writes the header of a UDP datagram whose data_length
// bytes of data are already at datagram[UDP_HEADER:], and its checksum over
// the pseudo-header, the header and the data. It gives the length of the
// datagram, or 0 when the data is too large for one frame or for datagram.
//
// A program with a datagram endpoint calls it before each Send: the
// network service copies the datagram and computes no checksum. The source
// address and the source port are the local address and the local port of
// the endpoint (the command Info gives them); the network service refuses
// a datagram with another source port.
udp_header_write :: proc "contextless" (datagram: []u8, source_address, destination_address: u32, source_port, destination_port: u16, data_length: int) -> int {
	if data_length < 0 || data_length > UDP_DATA_LIMIT || len(datagram) < UDP_HEADER + data_length {
		return 0
	}
	length := UDP_HEADER + data_length
	whole := datagram[:length]
	write_16(whole, 0, source_port)
	write_16(whole, 2, destination_port)
	write_16(whole, 4, u16(length))
	// The sum passes over the checksum field, and the field is written one
	// time: the datagram never holds a checksum of zero, which says "no
	// checksum", also not for a moment.
	value := checksum(sum(sum(pseudo(source_address, destination_address, PROTOCOL_UDP, length), whole[:6]), whole[UDP_HEADER:]))
	write_16(whole, 6, value == 0 ? 0xFFFF : value) // UDP sends a zero checksum as 0xFFFF.
	return length
}

// What udp_data_read does with the checksum of a datagram.
Udp_Checksum_Rule :: enum u8 {
	// Refuse a datagram whose checksum is not the one of its bytes. A
	// checksum of zero is taken: the sender computed none (IPv4 permits it).
	Verify        = 0,
	// Do not read the bytes for a checksum: for a protocol that
	// authenticates each datagram itself (QUIC), where the checksum adds
	// nothing.
	Do_Not_Verify = 1,
}

// udp_data_read gives the data of a UDP datagram that an endpoint
// received: the whole datagram, with its header, as the network service
// copied it. The network service checked the lengths and the ports, not
// the checksum: with the rule Verify, this procedure checks it, over the
// pseudo-header of the remote address and the local address. ok is false
// for a datagram that is shorter than its header, whose length field is
// not its length, or whose checksum is wrong: the program drops it and
// counts it.
udp_data_read :: proc "contextless" (datagram: []u8, remote_address, local_address: u32, rule: Udp_Checksum_Rule) -> (data: []u8, ok: bool) {
	if len(datagram) < UDP_HEADER || int(read_16(datagram, 4)) != len(datagram) {
		return nil, false
	}
	if rule == .Verify && read_16(datagram, 6) != 0 {
		matches, expected := checked(datagram, 6, pseudo(remote_address, local_address, PROTOCOL_UDP, len(datagram)))
		if expected == 0 {
			matches = read_16(datagram, 6) == 0xFFFF // The sender wrote a zero checksum as 0xFFFF.
		}
		if !matches {
			return nil, false
		}
	}
	return datagram[UDP_HEADER:], true
}

// echo_frame writes the headers of an ICMP echo request or reply whose
// data_length bytes are already at frame[ICMP_DATA:]. It gives the length
// of the frame, or 0.
echo_frame :: proc "contextless" (frame: []u8, destination, source: Hardware, source_address, destination_address: u32, kind: u8, identifier, sequence: u16, data_length: int, identification: u16) -> int {
	if data_length < 0 || data_length > ICMP_DATA_LIMIT || len(frame) < max(ICMP_DATA + data_length, FRAME_LEAST) {
		return 0
	}
	length := ICMP_HEADER + data_length
	ethernet_write(frame, destination, source, KIND_IPV4)
	ipv4_write(frame, source_address, destination_address, PROTOCOL_ICMP, length, identification)
	message := frame[ETHERNET_HEADER + IPV4_HEADER:][:length]
	message[0] = kind
	message[1] = 0
	write_16(message, 2, 0)
	write_16(message, 4, identifier)
	write_16(message, 6, sequence)
	write_16(message, 2, checksum(sum(0, message)))
	return pad(frame, ICMP_DATA + data_length)
}

// address_write writes an IPv4 address as four numbers.
address_write :: proc "contextless" (writer: ^system.Writer, address: u32) {
	for index in 0 ..< 4 {
		if index != 0 {
			system.write_bytes(writer, {'.'})
		}
		system.write_unsigned(writer, u64(address >> uint(24 - 8 * index) & 0xFF))
	}
}

// hardware_write writes a hardware address as six hexadecimal pairs.
hardware_write :: proc "contextless" (writer: ^system.Writer, address: Hardware) {
	for byte, index in address {
		if index != 0 {
			system.write_bytes(writer, {':'})
		}
		system.write_hex(writer, u64(byte), 2)
	}
}

// The name of each layer, for the line of a refused frame.
@(rodata)
layer_names := [Layer]string {
	.None     = "frame",
	.Ethernet = "ethernet",
	.Arp      = "arp",
	.Ipv4     = "ipv4",
	.Icmp     = "icmp",
	.Udp      = "udp",
	.Tcp      = "tcp",
}

// The words of each problem kind, for the line of a refused frame.
@(rodata)
problem_names := [Problem_Kind]string {
	.None         = "no problem",
	.Too_Short    = "too short",
	.Bad_Header   = "bad header",
	.Bad_Length   = "bad length",
	.Bad_Checksum = "bad checksum",
	.Unsupported  = "not supported",
	.No_Endpoint  = "no endpoint",
	.Not_Granted  = "not granted",
	.Full         = "full",
}

// problem_name gives the short name of a kind of problem, also for a value
// that another program wrote.
problem_name :: proc "contextless" (kind: Problem_Kind) -> string {
	return problem_names[kind] if kind <= max(Problem_Kind) else "unknown"
}

// layer_name gives the name of a layer, also for a value that another
// program wrote.
layer_name :: proc "contextless" (layer: Layer) -> string {
	return layer_names[layer] if layer <= max(Layer) else "frame"
}

// problem_write writes a problem as one sentence for a reader:
// "ipv4, byte 24: the checksum is 0x1234, the bytes give 0xabcd".
problem_write :: proc "contextless" (writer: ^system.Writer, problem: Problem) {
	put :: proc "contextless" (writer: ^system.Writer, text: string) {
		system.write_bytes(writer, transmute([]u8)text)
	}
	put(writer, layer_name(problem.layer))
	put(writer, ", byte ")
	system.write_unsigned(writer, u64(problem.offset))
	put(writer, ": ")
	#partial switch problem.kind {
	case .None:
		put(writer, "no problem")
	case .Too_Short:
		system.write_unsigned(writer, u64(problem.value))
		put(writer, " bytes, the header needs ")
		system.write_unsigned(writer, u64(problem.limit))
	case .Bad_Header:
		put(writer, "the field holds ")
		system.write_unsigned(writer, u64(problem.value))
		put(writer, ", the layer needs ")
		system.write_unsigned(writer, u64(problem.limit))
	case .Bad_Length:
		put(writer, "the length field gives ")
		system.write_unsigned(writer, u64(problem.value))
		put(writer, ", the limit is ")
		system.write_unsigned(writer, u64(problem.limit))
	case .Bad_Checksum:
		put(writer, "the checksum is 0x")
		system.write_hex(writer, u64(problem.value), 4)
		put(writer, ", the bytes give 0x")
		system.write_hex(writer, u64(problem.limit), 4)
	case .Unsupported:
		put(writer, "the value 0x")
		system.write_hex(writer, u64(problem.value), 4)
		put(writer, " is not supported")
	case .No_Endpoint:
		put(writer, "no endpoint has the port ")
		system.write_unsigned(writer, u64(problem.value))
	case .Not_Granted:
		put(writer, "the remote port ")
		system.write_unsigned(writer, u64(problem.value))
		put(writer, " is not the port of the grant, ")
		system.write_unsigned(writer, u64(problem.limit))
	case .Full:
		put(writer, "the remote port ")
		system.write_unsigned(writer, u64(problem.value))
		put(writer, " is new, and the admitted remotes are full, ")
		system.write_unsigned(writer, u64(problem.limit))
	case:
		put(writer, "an unknown problem")
	}
}

// hardware_put writes a hardware address at offset.
hardware_put :: proc "contextless" (bytes: []u8, offset: int, address: Hardware) {
	for byte, index in address {
		bytes[offset + index] = byte
	}
}

// completion_error_text writes the sentence of the error record of a
// completion of the datagram ring that failed, and gives the record.
completion_error_text :: proc "contextless" (writer: ^system.Writer, record: ring.Record) -> (error: errors.Error_Record) {
	error = errors.completion_record(record.values)
	system.ring_error_text(writer, &error, "datagram", datagram.command_name(error.operation), datagram.argument_name(error.operation, error.argument))
	return error
}
