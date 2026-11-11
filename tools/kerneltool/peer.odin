package kerneltool

import "contract:errors"
import "contract:remote"
import "core:fmt"
import "core:net"
import "core:sync"
import "core:thread"
import "core:time"

// The peer of the network of the test machine: the gateway 10.0.2.2 of the
// network of the machine, and an echo server on its port 7. QEMU sends each
// frame of the network device of the machine as one UDP datagram to the
// peer, on the loopback of the host (`-netdev dgram`), and gives each
// datagram of the peer to the device as one frame. No frame leaves the host:
// the test is closed, and it has the same answers at each run.
//
// The peer reads each frame with its own code, not with support/network:
// a fault of the network service in a checksum or a length is a fault that
// the peer sees. It answers ARP, an echo request (ICMP) and a datagram to
// port 7. Before it answers the first datagram, it sends the frames that the
// network service must refuse (peer_refused), then one echo request to the
// machine. The order of the frames is kept, so the network service reads
// them before the answer of that first datagram.
//
// The peer is also the host for the remote service (docs/MODULE_CONTRACT.md,
// "A call from the host"): it receives call requests on a UDP socket of the
// loopback (call_port), writes each one in a datagram from 10.0.2.2 port
// remote.HOST_PORT to the endpoint of the remote service, and gives each
// datagram of the remote service to the program that sent the last call
// request. It learns the port of the endpoint from the first datagram of
// the remote service (the status Started), and then sends the malformed
// call requests of remote_malformed: the remote service must refuse each
// one with its error record.

@(rodata)
PEER_HARDWARE := [6]u8{0x52, 0x55, 0x0A, 0x00, 0x02, 0x02}
@(rodata)
PEER_ADDRESS := [4]u8{10, 0, 2, 2}
@(rodata)
MACHINE_ADDRESS := [4]u8{10, 0, 2, 15}
MACHINE_HARDWARE :: "52:54:00:12:34:56"
PEER_ECHO_PORT :: 7
PEER_PING_IDENTIFIER :: 0x7065

Peer :: struct {
	call_thread:  ^thread.Thread, // It receives the call requests of the host.
	socket:       net.UDP_Socket,
	port:         int, // QEMU sends the frames of the machine to this port.
	thread:       ^thread.Thread,
	stop:         bool,
	machine:      net.Endpoint, // Where QEMU receives the frames for the machine.
	hardware:     [6]u8, // The hardware address of the machine.
	machine_port: u16, // The local port of the first datagram of the machine.
	refused_sent: bool,
	// The firmware of the machine uses the device before the kernel starts
	// (its own network stack). The peer reads each frame from the first ARP
	// frame of the address of the machine, the first frame of the network
	// service, and only counts the frames before it.
	started:      bool,
	firmware:     int, // Frames before the network service.
	// The counts, read after the thread ended.
	frames:       int,
	wrong:        int,
	first_wrong:  string,
	arp_answers:  int,
	echo_answers: int,
	udp_answers:  int,
	ping_replies: int, // Echo replies of the machine to the echo request of the peer.
	// The host of the remote service.
	call_socket:      net.UDP_Socket,
	call_port:        int, // The call requests arrive on 127.0.0.1 at this port.
	lock:             sync.Mutex, // The fields below, and machine and hardware: two threads read them.
	client:           net.Endpoint, // Where the last call request came from.
	has_client:       bool,
	remote_port:      u16, // The local port of the endpoint of the remote service. 0: not known yet.
	remote_starts:    int,
	remote_datagrams: int, // Datagrams of the remote service, to the host.
	malformed_sent:   int,
	malformed_right:  int, // The answers of the remote service to the malformed requests that have the expected refusal.
	malformed_wrong:  string,
}

// peer_start starts the peer. call_port: the port of the call requests on
// the loopback; 0 lets the system choose it.
peer_start :: proc(peer: ^Peer, call_port := 0) -> bool {
	socket, err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if err != nil {
		fmt.eprintfln("kerneltool: the peer has no UDP socket: %v", err)
		return false
	}
	bound, bound_err := net.bound_endpoint(socket)
	if bound_err != nil {
		net.close(socket)
		return false
	}
	_ = net.set_option(socket, .Receive_Timeout, 100 * time.Millisecond)
	calls, calls_err := net.make_bound_udp_socket(net.IP4_Loopback, call_port)
	if calls_err != nil {
		fmt.eprintfln("kerneltool: the peer cannot receive call requests on 127.0.0.1 port %d: %v", call_port, calls_err)
		net.close(socket)
		return false
	}
	calls_bound, _ := net.bound_endpoint(calls)
	_ = net.set_option(calls, .Receive_Timeout, 100 * time.Millisecond)
	peer^ = {socket = socket, port = bound.port, call_socket = calls, call_port = calls_bound.port}
	peer.thread = thread.create_and_start_with_poly_data(peer, peer_run)
	peer.call_thread = thread.create_and_start_with_poly_data(peer, peer_calls)
	return true
}

peer_stop :: proc(peer: ^Peer) {
	if peer.thread == nil {
		return
	}
	sync.atomic_store(&peer.stop, true)
	thread.join(peer.thread)
	thread.destroy(peer.thread)
	thread.join(peer.call_thread)
	thread.destroy(peer.call_thread)
	net.close(peer.socket)
	net.close(peer.call_socket)
	peer.thread = nil
}

// peer_check says if the peer saw only correct frames, and if the network
// service answered its echo request.
peer_check :: proc(peer: ^Peer) -> bool {
	if peer.wrong != 0 {
		fmt.eprintfln("kerneltool: test failed: the peer received %d wrong frames from the machine; the first: %s", peer.wrong, peer.first_wrong)
		return false
	}
	if peer.refused_sent && peer.ping_replies < 1 {
		fmt.eprintln("kerneltool: test failed: the machine did not answer the echo request of the peer")
		return false
	}
	if peer.frames != 0 {
		fmt.printfln("kerneltool: test passed: the peer received %d frames from the network service, 0 wrong: %d ARP, %d echo and %d UDP answered, %d echo replies of the machine; %d frames of the firmware before it", peer.frames, peer.arp_answers, peer.echo_answers, peer.udp_answers, peer.ping_replies, peer.firmware)
	}
	if peer.remote_starts != 0 {
		if peer.malformed_right != len(remote_malformed) {
			fmt.eprintfln("kerneltool: test failed: the remote service refused %d of the %d malformed call requests with the expected error record; the first other answer: %s", peer.malformed_right, len(remote_malformed), peer.malformed_wrong)
			return false
		}
		fmt.printfln("kerneltool: test passed: the remote service started %d times, sent %d datagrams to the host, and refused each of the %d malformed call requests with the expected error record", peer.remote_starts, peer.remote_datagrams, len(remote_malformed))
	}
	return true
}

@(private = "file")
be16 :: proc(bytes: []u8, offset: int) -> int {
	return int(bytes[offset]) << 8 | int(bytes[offset + 1])
}

@(private = "file")
put16 :: proc(bytes: []u8, offset: int, value: int) {
	bytes[offset] = u8(value >> 8)
	bytes[offset + 1] = u8(value)
}

// internet_sum is the checksum of RFC 1071 over bytes, with a start value:
// the 16 bits that the field must hold.
@(private = "file")
internet_sum :: proc(start: u32, bytes: []u8) -> int {
	total := start
	for index := 0; index < len(bytes); index += 2 {
		word := u32(bytes[index]) << 8
		if index + 1 < len(bytes) {
			word |= u32(bytes[index + 1])
		}
		total += word
	}
	for total > 0xFFFF {
		total = (total & 0xFFFF) + (total >> 16)
	}
	return int(~u16(total))
}

@(private = "file")
pseudo_sum :: proc(source, destination: []u8, length: int) -> u32 {
	return u32(be16(source, 0) + be16(source, 2) + be16(destination, 0) + be16(destination, 2) + 17 + length)
}

peer_run :: proc(peer: ^Peer) {
	buffer: [2048]u8
	for !sync.atomic_load(&peer.stop) {
		count, from, err := net.recv_udp(peer.socket, buffer[:])
		if err != nil || count == 0 {
			continue
		}
		sync.mutex_lock(&peer.lock)
		peer.machine = from
		sync.mutex_unlock(&peer.lock)
		frame := buffer[:count]
		if !peer.started {
			// An ARP frame (kind 0x0806) whose sender address is 10.0.2.15.
			if count >= 42 && frame[12] == 0x08 && frame[13] == 0x06 && address_at(frame, 28) == MACHINE_ADDRESS {
				peer.started = true
			} else {
				peer.firmware += 1
				continue
			}
		}
		peer.frames += 1
		peer_frame(peer, frame)
	}
}

@(private = "file")
peer_wrong :: proc(peer: ^Peer, text: string) {
	if peer.wrong == 0 {
		peer.first_wrong = text
	}
	peer.wrong += 1
}

@(private = "file")
peer_send :: proc(peer: ^Peer, frame: []u8) {
	sync.mutex_lock(&peer.lock)
	machine := peer.machine
	sync.mutex_unlock(&peer.lock)
	_, _ = net.send_udp(peer.socket, frame, machine)
}

@(private = "file")
peer_frame :: proc(peer: ^Peer, frame: []u8) {
	if len(frame) < 14 {
		peer_wrong(peer, "a frame shorter than its header")
		return
	}
	if len(frame) < 60 {
		peer_wrong(peer, "a frame shorter than 60 bytes")
		return
	}
	sync.mutex_lock(&peer.lock)
	copy(peer.hardware[:], frame[6:12])
	sync.mutex_unlock(&peer.lock)
	if fmt.tprintf("%02x:%02x:%02x:%02x:%02x:%02x", frame[6], frame[7], frame[8], frame[9], frame[10], frame[11]) != MACHINE_HARDWARE {
		peer_wrong(peer, "a frame from another hardware address")
		return
	}
	switch be16(frame, 12) {
	case 0x0806:
		arp := frame[14:]
		if be16(arp, 0) != 1 || be16(arp, 2) != 0x0800 || arp[4] != 6 || arp[5] != 4 || address_at(arp, 14) != MACHINE_ADDRESS {
			peer_wrong(peer, "an ARP frame with a wrong field")
			return
		}
		if be16(arp, 6) == 1 && address_at(arp, 24) == PEER_ADDRESS {
			if be16(frame, 0) != 0xFFFF {
				peer_wrong(peer, "an ARP request that is not broadcast")
				return
			}
			reply: [60]u8
			copy(reply[0:6], frame[6:12])
			copy(reply[6:12], PEER_HARDWARE[:])
			put16(reply[:], 12, 0x0806)
			copy(reply[14:22], arp[0:8])
			put16(reply[:], 20, 2)
			copy(reply[22:28], PEER_HARDWARE[:])
			copy(reply[28:32], PEER_ADDRESS[:])
			copy(reply[32:38], arp[8:14])
			copy(reply[38:42], arp[14:18])
			peer_send(peer, reply[:])
			peer.arp_answers += 1
		}
	case 0x0800:
		ip := frame[14:]
		if ip[0] != 0x45 || internet_sum(0, ip[:20]) != 0 {
			peer_wrong(peer, "an IPv4 header with a wrong version, length or checksum")
			return
		}
		total := be16(ip, 2)
		if total < 20 || total > len(ip) || be16(ip, 6) & 0x3FFF != 0 || address_at(ip, 12) != MACHINE_ADDRESS || address_at(ip, 16) != PEER_ADDRESS {
			peer_wrong(peer, "an IPv4 header with a wrong length, fragment or address")
			return
		}
		payload := ip[20:total]
		switch ip[9] {
		case 1:
			if len(payload) < 8 || internet_sum(0, payload) != 0 {
				peer_wrong(peer, "an ICMP message with a wrong length or checksum")
				return
			}
			switch payload[0] {
			case 8:
				reply := make([]u8, 14 + total, context.temp_allocator)
				peer_ipv4(reply, frame[6:12], total - 20, 1)
				copy(reply[34:], payload)
				reply[34] = 0
				put16(reply, 36, 0)
				put16(reply, 36, internet_sum(0, reply[34:]))
				peer_send(peer, peer_pad(reply))
				peer.echo_answers += 1
			case 0:
				if be16(payload, 4) == PEER_PING_IDENTIFIER && string(payload[8:]) == "an echo request of the peer" {
					peer.ping_replies += 1
				} else {
					peer_wrong(peer, "an echo reply that is not the request of the peer")
				}
			case:
				peer_wrong(peer, "an ICMP message of another kind")
			}
		case 17:
			if len(payload) < 8 || be16(payload, 4) != len(payload) || be16(payload, 6) == 0 || internet_sum(pseudo_sum(ip[12:16], ip[16:20], len(payload)), payload) != 0 {
				peer_wrong(peer, "a UDP datagram with a wrong length or checksum")
				return
			}
			if be16(payload, 2) == remote.HOST_PORT {
				peer_remote(peer, u16(be16(payload, 0)), payload[8:])
				free_all(context.temp_allocator)
				return
			}
			if be16(payload, 2) != PEER_ECHO_PORT {
				peer_wrong(peer, "a UDP datagram to another port than 7 and than the port of the host")
				return
			}
			if !peer.refused_sent {
				peer.machine_port = u16(be16(payload, 0))
				peer_refused(peer)
				peer.refused_sent = true
			}
			reply := make([]u8, 14 + total, context.temp_allocator)
			peer_ipv4(reply, frame[6:12], total - 20, 17)
			put16(reply, 34, PEER_ECHO_PORT)
			put16(reply, 36, be16(payload, 0))
			put16(reply, 38, len(payload))
			copy(reply[42:], payload[8:])
			put16(reply, 40, 0)
			value := internet_sum(pseudo_sum(PEER_ADDRESS[:], MACHINE_ADDRESS[:], len(payload)), reply[34:])
			put16(reply, 40, value == 0 ? 0xFFFF : value)
			peer_send(peer, peer_pad(reply))
			peer.udp_answers += 1
		case:
			peer_wrong(peer, "an IPv4 packet of another protocol")
		}
	case:
		peer_wrong(peer, "a frame of another kind than ARP and IPv4")
	}
	free_all(context.temp_allocator)
}

// peer_ipv4 writes the headers of Ethernet and IPv4 of a frame from the
// peer to the machine.
@(private = "file")
peer_ipv4 :: proc(frame: []u8, destination: []u8, payload: int, protocol: u8) {
	copy(frame[0:6], destination)
	copy(frame[6:12], PEER_HARDWARE[:])
	put16(frame, 12, 0x0800)
	ip := frame[14:34]
	ip[0] = 0x45
	put16(ip, 2, 20 + payload)
	put16(ip, 6, 0x4000)
	ip[8] = 64
	ip[9] = protocol
	copy(ip[12:16], PEER_ADDRESS[:])
	copy(ip[16:20], MACHINE_ADDRESS[:])
	put16(ip, 10, 0)
	put16(ip, 10, internet_sum(0, ip))
}

@(private = "file")
peer_pad :: proc(frame: []u8) -> []u8 {
	if len(frame) >= 60 {
		return frame
	}
	padded := make([]u8, 60, context.temp_allocator)
	copy(padded, frame)
	return padded
}

// peer_udp gives a correct datagram from the peer to the machine, from a
// port to a port, with data.
@(private = "file")
peer_udp :: proc(peer: ^Peer, from, to: int, data: string) -> []u8 {
	length := 8 + len(data)
	frame := make([]u8, max(42 + len(data), 60), context.temp_allocator)
	sync.mutex_lock(&peer.lock)
	hardware := peer.hardware
	sync.mutex_unlock(&peer.lock)
	peer_ipv4(frame, hardware[:], length, 17)
	put16(frame, 34, from)
	put16(frame, 36, to)
	put16(frame, 38, length)
	copy(frame[42:], data)
	value := internet_sum(pseudo_sum(PEER_ADDRESS[:], MACHINE_ADDRESS[:], length), frame[34:42 + len(data)])
	put16(frame, 40, value == 0 ? 0xFFFF : value)
	return frame
}

@(private = "file")
peer_header_fix :: proc(frame: []u8) {
	put16(frame, 24, 0)
	put16(frame, 24, internet_sum(0, frame[14:34]))
}

// peer_refused sends the frames that the network service must refuse: ten
// that no endpoint owns (programs/net, expected_machine_rows) and one to the
// endpoint of `net` from a remote that its grant does not name, then one
// correct echo request to the machine.
@(private = "file")
peer_refused :: proc(peer: ^Peer) {
	port := int(peer.machine_port)
	// 1. Shorter than the header of Ethernet.
	peer_send(peer, peer_udp(peer, PEER_ECHO_PORT, port, "junk")[:10])
	// 2. An IPv6 frame.
	frame := peer_udp(peer, PEER_ECHO_PORT, port, "junk")
	put16(frame, 12, 0x86DD)
	peer_send(peer, frame)
	// 3. A wrong checksum of the IPv4 header.
	frame = peer_udp(peer, PEER_ECHO_PORT, port, "junk")
	frame[24] ~= 0x55
	peer_send(peer, frame)
	// 4. An IPv4 header of 16 bytes.
	frame = peer_udp(peer, PEER_ECHO_PORT, port, "junk")
	frame[14] = 0x44
	peer_header_fix(frame)
	peer_send(peer, frame)
	// 5. A total length after the end of the frame.
	frame = peer_udp(peer, PEER_ECHO_PORT, port, "junk")
	put16(frame, 16, 1000)
	peer_header_fix(frame)
	peer_send(peer, frame)
	// 6. A fragment.
	frame = peer_udp(peer, PEER_ECHO_PORT, port, "junk")
	put16(frame, 20, 0x2000)
	peer_header_fix(frame)
	peer_send(peer, frame)
	// 7. A wrong UDP checksum.
	frame = peer_udp(peer, PEER_ECHO_PORT, port, "junk")
	frame[42] ~= 0x01
	peer_send(peer, frame)
	// 8. A UDP length after the end of the packet.
	frame = peer_udp(peer, PEER_ECHO_PORT, port, "junk")
	put16(frame, 38, 500)
	peer_send(peer, frame)
	// 9. A port of no endpoint.
	peer_send(peer, peer_udp(peer, PEER_ECHO_PORT, 9999, "junk"))
	// 10. A remote port that the grant of the endpoint does not name.
	peer_send(peer, peer_udp(peer, 9, port, "junk"))
	// 11. An ARP frame with a hardware address of 8 bytes.
	arp: [60]u8
	copy(arp[0:6], peer.hardware[:])
	copy(arp[6:12], PEER_HARDWARE[:])
	put16(arp[:], 12, 0x0806)
	put16(arp[:], 14, 1)
	put16(arp[:], 16, 0x0800)
	arp[18] = 8
	arp[19] = 4
	put16(arp[:], 20, 1)
	peer_send(peer, arp[:])
	// A correct echo request to the machine: the network service answers it.
	DATA :: "an echo request of the peer"
	ping := make([]u8, 42 + len(DATA), context.temp_allocator)
	peer_ipv4(ping, peer.hardware[:], 8 + len(DATA), 1)
	ping[34] = 8
	put16(ping, 38, PEER_PING_IDENTIFIER)
	put16(ping, 40, 1)
	copy(ping[42:], DATA)
	put16(ping, 36, internet_sum(0, ping[34:]))
	peer_send(peer, ping)
}

@(private = "file")
address_at :: proc(bytes: []u8, offset: int) -> (address: [4]u8) {
	copy(address[:], bytes[offset:][:4])
	return address
}

// The malformed call requests that the peer sends to the remote service
// when it starts, and the refusal that each one must have: the field of the
// request (the argument of the error record) and the error kind.
Malformed :: struct {
	number:   u64, // The number of the request; the answer has it. 0: the request is too short to have one.
	argument: i64,
	kind:     errors.Kind,
}

@(rodata)
remote_malformed := [?]Malformed {
	{0, 0, .Too_Small}, // 20 bytes: shorter than the header.
	{remote.PEER_NUMBERS | 2, remote.FIELD_KIND, .Bad_Value}, // An unknown kind.
	{remote.PEER_NUMBERS | 3, remote.FIELD_ARGUMENTS, .Too_Long}, // More bytes of arguments than the datagram has.
	{remote.PEER_NUMBERS | 4, remote.FIELD_RESULT_COUNT, .Too_Long}, // A result past the end of the call region.
	{remote.PEER_NUMBERS | 5, remote.FIELD_ERROR_START, .Bad_Value}, // An error record that is not aligned on 8.
	{remote.PEER_NUMBERS | 6, remote.FIELD_SERVICE, .No_Grant}, // A service that the root service does not let it call.
}

// peer_remote takes a datagram of the remote service to the host.
@(private = "file")
peer_remote :: proc(peer: ^Peer, port: u16, data: []u8) {
	sync.mutex_lock(&peer.lock)
	peer.remote_port = port
	peer.remote_datagrams += 1
	client, has_client := peer.client, peer.has_client
	sync.mutex_unlock(&peer.lock)
	header, _, ok := remote.answer_check(data)
	if !ok {
		peer_wrong(peer, "a datagram of the remote service that is not a call answer")
		return
	}
	if header.status == .Started {
		peer.remote_starts += 1
		if peer.malformed_sent == 0 {
			peer_malformed(peer)
		}
		return
	}
	if header.number & remote.PEER_NUMBERS != 0 || (header.number == 0 && header.status == .Refused) {
		for item in remote_malformed {
			if item.number == header.number {
				if header.status == .Refused && header.error.argument == item.argument && header.error.kind == i64(item.kind) {
					peer.malformed_right += 1
				} else if peer.malformed_wrong == "" {
					peer.malformed_wrong = fmt.aprintf("request %x: status %v, argument %d, kind %d", header.number, header.status, header.error.argument, header.error.kind)
				}
			}
		}
		return
	}
	if has_client {
		_, _ = net.send_udp(peer.call_socket, data, client)
	}
}

// peer_malformed sends the malformed call requests of remote_malformed.
@(private = "file")
peer_malformed :: proc(peer: ^Peer) {
	peer.malformed_sent = len(remote_malformed)
	send :: proc(peer: ^Peer, bytes: []u8) {
		sync.mutex_lock(&peer.lock)
		port := peer.remote_port
		sync.mutex_unlock(&peer.lock)
		peer_send(peer, peer_udp(peer, remote.HOST_PORT, int(port), string(bytes)))
	}
	short: [20]u8
	send(peer, short[:])
	arguments: [16]u8
	out: [remote.DATAGRAM_LIMIT]u8
	for item in remote_malformed[1:] {
		request := remote.Request {
			kind         = .Call,
			number       = item.number,
			export       = 1,
			record_size  = 8,
			result_start = 64,
			result_count = 64,
			result_unit  = 1,
			error_start  = 24,
		}
		remote.name_set(&request.service, "manual")
		switch item.argument {
		case remote.FIELD_KIND:
			request.kind = remote.Request_Kind(9)
		case remote.FIELD_RESULT_COUNT:
			request.result_count = remote.REGION_SIZE
		case remote.FIELD_ERROR_START:
			request.error_start = 28
		case remote.FIELD_SERVICE:
			remote.name_set(&request.service, "console")
		}
		bytes, _ := remote.request_write(out[:], request, arguments[:])
		if item.argument == remote.FIELD_ARGUMENTS {
			(^remote.Request)(&out[0]).arguments = 400
		}
		send(peer, bytes)
	}
}

// peer_calls receives the call requests of the host on the loopback, and
// gives each one to the remote service.
peer_calls :: proc(peer: ^Peer) {
	buffer: [remote.DATAGRAM_LIMIT + 1]u8
	for !sync.atomic_load(&peer.stop) {
		count, from, err := net.recv_udp(peer.call_socket, buffer[:])
		if err != nil || count == 0 || count > remote.DATAGRAM_LIMIT {
			continue
		}
		sync.mutex_lock(&peer.lock)
		peer.client, peer.has_client = from, true
		port := peer.remote_port
		sync.mutex_unlock(&peer.lock)
		if port != 0 {
			peer_send(peer, peer_udp(peer, remote.HOST_PORT, int(port), string(buffer[:count])))
		}
		free_all(context.temp_allocator)
	}
}
