// The protocols of the network service: Ethernet, ARP, IPv4, ICMP echo and
// UDP, and the checks of a TCP segment (its header and its checksum; TCP
// itself is support/tcp, in the program). The functions read and write frames in memory that the caller gives;
// they do no input or output, allocate nothing and keep no state, so the
// host runs their tests (network_test.odin).
//
// A frame from the wire is input that nobody checked. parse reads each field
// only after it checked that the bytes are there; a frame that breaks a
// rule gives a Problem: the layer, the kind, the byte of the frame, the bad
// value and the value that the layer needs. It never faults.
//
// Numbers are in the order of the machine; the frame holds them in network
// order (the first byte is the high byte). An IPv4 address is a u32:
// 10.0.2.15 is 0x0A00020F.
package network

import "contract:datagram"
import "contract:errors"
import "contract:ring"
import "support:system"

Hardware :: [6]u8 // A hardware address of Ethernet.
BROADCAST :: Hardware{0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}

ETHERNET_HEADER :: 14
IPV4_HEADER :: 20 // With no options: the header that this library writes.
UDP_HEADER :: 8
TCP_HEADER :: 20 // With no option.
ICMP_HEADER :: 8
ARP_SIZE :: 28
FRAME_LEAST :: 60 // A shorter frame gets zero bytes at its end.
MTU :: 1500 // The bytes of IPv4 in one frame.
UDP_DATA :: ETHERNET_HEADER + IPV4_HEADER + UDP_HEADER // The place of the data of a UDP datagram that this library writes.
ICMP_DATA :: ETHERNET_HEADER + IPV4_HEADER + ICMP_HEADER
IPV4_DATA :: ETHERNET_HEADER + IPV4_HEADER // The place of a segment in a frame that this library writes.
UDP_DATA_LIMIT :: MTU - IPV4_HEADER - UDP_HEADER // 1472: no fragment.
ICMP_DATA_LIMIT :: MTU - IPV4_HEADER - ICMP_HEADER

KIND_IPV4 :: 0x0800
KIND_ARP :: 0x0806
PROTOCOL_ICMP :: 1
PROTOCOL_UDP :: 17
PROTOCOL_TCP :: 6
ICMP_ECHO_REPLY :: 0
ICMP_ECHO_REQUEST :: 8
ARP_REQUEST :: 1
ARP_REPLY :: 2
TTL :: 64

// The error of a frame is a record of the datagram contract, because the
// network service gives it to programs, and an error must inform the
// program that receives it. parse gives the kinds Too_Short to Unsupported.
Layer :: datagram.Layer
Problem_Kind :: datagram.Problem_Kind
Problem :: datagram.Problem

Packet_Kind :: enum u8 {
	None = 0,
	Arp  = 1,
	Icmp = 2,
	Udp  = 3,
	Tcp  = 4,
}

// What parse found in a frame. data is a part of the frame.
Packet :: struct {
	kind:             Packet_Kind,
	destination:      Hardware,
	source:           Hardware,
	// ARP.
	operation:        u16,
	sender_hardware:  Hardware,
	target_hardware:  Hardware,
	sender_address:   u32,
	target_address:   u32,
	// IPv4.
	source_address:   u32,
	destination_address: u32,
	ttl:              u8,
	// ICMP echo.
	icmp_kind:        u8,
	identifier:       u16,
	sequence:         u16,
	// UDP and TCP.
	source_port:      u16,
	destination_port: u16,
	data:             []u8, // UDP: the data. TCP: the whole segment, with its header.
	tcp_flags:        u8,
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

// pseudo gives the sum of the pseudo-header of UDP over IPv4.
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
	// A checksum of zero: the sender computed none (IPv4 permits it).
	if read_16(datagram, 6) != 0 {
		ok, expected := checked(datagram[:length], 6, pseudo(packet.source_address, packet.destination_address, PROTOCOL_UDP, length))
		if expected == 0 {
			expected = 0xFFFF // UDP sends a zero checksum as 0xFFFF.
			ok = read_16(datagram, 6) == expected
		}
		if !ok {
			return packet, {kind = .Bad_Checksum, layer = .Udp, offset = u16(offset + 6), value = u32(read_16(datagram, 6)), limit = u32(expected)}
		}
	}
	packet.source_port = read_16(datagram, 0)
	packet.destination_port = read_16(datagram, 2)
	packet.data = datagram[UDP_HEADER:length]
	packet.kind = .Udp
	return packet, {}
}

// tcp_parse checks a segment: its length, its data offset and its
// checksum. The rest of the segment is for TCP in the program.
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
	if ok, expected := checked(segment, 16, pseudo(packet.source_address, packet.destination_address, PROTOCOL_TCP, len(segment))); !ok {
		return packet, {kind = .Bad_Checksum, layer = .Tcp, offset = u16(offset + 16), value = u32(read_16(segment, 16)), limit = u32(expected)}
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

// udp_frame writes the headers of a UDP datagram whose data_length bytes
// are already at frame[UDP_DATA:], and its checksum. It gives the length of
// the frame, or 0 when the data is too large for one frame or for frame.
udp_frame :: proc "contextless" (frame: []u8, destination, source: Hardware, source_address, destination_address: u32, source_port, destination_port: u16, data_length: int, identification: u16) -> int {
	if data_length < 0 || data_length > UDP_DATA_LIMIT || len(frame) < max(UDP_DATA + data_length, FRAME_LEAST) {
		return 0
	}
	length := UDP_HEADER + data_length
	ethernet_write(frame, destination, source, KIND_IPV4)
	ipv4_write(frame, source_address, destination_address, PROTOCOL_UDP, length, identification)
	datagram := frame[ETHERNET_HEADER + IPV4_HEADER:][:length]
	write_16(datagram, 0, source_port)
	write_16(datagram, 2, destination_port)
	write_16(datagram, 4, u16(length))
	write_16(datagram, 6, 0)
	value := checksum(sum(pseudo(source_address, destination_address, PROTOCOL_UDP, length), datagram))
	write_16(datagram, 6, value == 0 ? 0xFFFF : value)
	return pad(frame, UDP_DATA + data_length)
}

// ipv4_frame writes the headers of Ethernet and IPv4 of a frame whose
// payload of payload bytes is already at frame[IPV4_DATA:]: a segment that
// the program wrote with its checksum. It gives the length of the frame, or
// 0 when the payload is too large.
ipv4_frame :: proc "contextless" (frame: []u8, destination, source: Hardware, source_address, destination_address: u32, protocol: u8, payload: int, identification: u16) -> int {
	if payload < 0 || payload > MTU - IPV4_HEADER || len(frame) < max(IPV4_DATA + payload, FRAME_LEAST) {
		return 0
	}
	ethernet_write(frame, destination, source, KIND_IPV4)
	ipv4_write(frame, source_address, destination_address, protocol, payload, identification)
	return pad(frame, IPV4_DATA + payload)
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

// problem_write writes a problem as one sentence for a person:
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
