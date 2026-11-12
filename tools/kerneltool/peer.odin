package kerneltool

import "contract:remote"
import "core:fmt"
import "core:net"
import "core:sync"
import "core:sys/linux"
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
// "A call from the host"): its QUIC client of `remote` (peer_remote.odin)
// carries each call of the tool on a stream. The tool gives it the calls on
// a Unix socket that only its user reaches (call_socket, in
// call_socket_linux.odin).

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
	call_socket:  string, // The path of the Unix socket where the tool gives the calls.
	lock:         sync.Mutex, // machine and hardware: two threads read them.
	remote:       ^Peer_Remote, // The peer as the QUIC client of `remote` (peer_remote.odin).
	tcp:          ^Peer_Tcp, // The peer as a TCP client (peer_tcp.odin).
	quic:         ^Peer_Quic, // The peer as QUIC clients (peer_quic.odin).
	relay:        Peer_Relay, // UDP of programs of the host to the machine (peer_relay.odin).
	tcp_segments: int, // TCP segments of the machine.
}

// The peers that this process started: the name of the socket of the calls
// of a machine test.
peers_started: int

// peer_start starts the peer. call_socket_name: the name of the socket of
// the calls in the private folder of the user; "" gives a name of this
// process and of this peer, so that two machine tests never share one.
peer_start :: proc(peer: ^Peer, call_socket_name := "") -> bool {
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
	// The receive of the frames ends each 1 ms: the TCP case of the peer
	// (peer_tcp.odin) runs its timers between two frames.
	_ = net.set_option(socket, .Receive_Timeout, 1 * time.Millisecond)
	// A margin for the bursts of the machine (a flood of QUIC Initials
	// gets one Retry each). The host may hold the buffer under this size
	// (net.core.rmem_max): peer_run reads every frame that waits before
	// the next sends, and the QUIC flood waits for its answers.
	_ = net.set_option(socket, .Receive_Buffer_Size, 4 << 20)
	// The port where QEMU receives the frames for the machine: the peer
	// chooses it, so that it can send the first frame (a SYN).
	machine_socket, machine_err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if machine_err != nil {
		net.close(socket)
		return false
	}
	machine_bound, _ := net.bound_endpoint(machine_socket)
	net.close(machine_socket)
	peer^ = {socket = socket, port = bound.port, machine = machine_bound}
	peer.remote = peer_remote_make()
	socket_name := call_socket_name
	if socket_name == "" {
		peers_started += 1
		socket_name = fmt.tprintf("test-%d-%d", int(linux.getpid()), peers_started)
	}
	if !peer_remote_socket_start(peer.remote, socket_name) {
		peer_remote_free(peer.remote)
		peer.remote = nil
		net.close(socket)
		return false
	}
	peer.call_socket = peer.remote.socket_path
	peer.tcp = peer_tcp_make()
	peer.quic = peer_quic_make()
	if !peer_relay_start(&peer.relay) {
		peer_tcp_free(peer.tcp)
		peer_quic_free(peer.quic)
		peer_remote_socket_stop(peer.remote)
		peer_remote_free(peer.remote)
		peer.tcp, peer.quic, peer.remote = nil, nil, nil
		net.close(socket)
		return false
	}
	hardware_of_machine := [6]u8{0x52, 0x54, 0x00, 0x12, 0x34, 0x56}
	peer.hardware = hardware_of_machine
	peer.thread = thread.create_and_start_with_poly_data(peer, peer_run)
	peer.call_thread = thread.create_and_start_with_poly_data(peer, peer_remote_serve_socket)
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
	peer_remote_socket_stop(peer.remote)
	peer.call_socket = ""
	peer.thread = nil
	peer_tcp_free(peer.tcp)
	peer.tcp = nil
	peer_quic_free(peer.quic)
	peer.quic = nil
	peer_relay_report(&peer.relay)
	peer_relay_stop(&peer.relay)
	peer_remote_report(peer.remote)
	peer_remote_free(peer.remote)
	peer.remote = nil
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
		test_passed_print("the peer received %d frames from the network service, 0 wrong: %d ARP, %d echo and %d UDP answered, %d echo replies of the machine, %d TCP segments; %d frames of the firmware before it", peer.frames, peer.arp_answers, peer.echo_answers, peer.udp_answers, peer.ping_replies, peer.tcp_segments, peer.firmware)
	}
	return true
}

be16 :: proc(bytes: []u8, offset: int) -> int {
	return int(bytes[offset]) << 8 | int(bytes[offset + 1])
}

put16 :: proc(bytes: []u8, offset: int, value: int) {
	bytes[offset] = u8(value >> 8)
	bytes[offset + 1] = u8(value)
}

// internet_sum is the checksum of RFC 1071 over bytes, with a start value:
// the 16 bits that the field must hold.
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

pseudo_sum :: proc(source, destination: []u8, length: int, protocol := 17) -> u32 {
	return u32(be16(source, 0) + be16(source, 2) + be16(destination, 0) + be16(destination, 2) + protocol + length)
}

// peer_run reads the frames of the machine, and runs the ticks of the cases
// and of the relay when no frame waits, and at most once in a millisecond
// while frames come: each frame that waits is read before the next sends of
// the cases, so the answers of the machine never pile up in the socket.
peer_run :: proc(peer: ^Peer) {
	buffer: [2048]u8
	last_tick := time.tick_now()
	for !sync.atomic_load(&peer.stop) {
		count, from, err := net.recv_udp(peer.socket, buffer[:])
		if err != nil || count == 0 || time.tick_since(last_tick) >= time.Millisecond {
			// The TCP case of the tool, if one runs: its timers and its clients.
			peer_tcp_tick(peer, nil)
			// The QUIC case of the tool, if one runs.
			peer_quic_tick(peer)
			// The calls of the host to `remote`.
			peer_remote_tick(peer)
			// The datagrams of programs of the host for the machine.
			peer_relay_tick(peer)
			last_tick = time.tick_now()
		}
		free_all(context.temp_allocator)
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

peer_wrong :: proc(peer: ^Peer, text: string) {
	if peer.wrong == 0 {
		peer.first_wrong = text
	}
	peer.wrong += 1
}

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
		// A datagram of the QUIC server to an address of the flood of the
		// peer (peer_quic.odin) goes through the gateway: the peer.
		to_flood := ip[9] == 17 && total >= 28 && peer_quic_flood_address(address_at(ip, 16)) && be16(ip, 20) == QUIC_SERVER_PORT
		// A datagram of `remote` to an address that its grant does not
		// admit: the peer counts it (peer_remote.odin), and there must be
		// none.
		to_stranger := ip[9] == 17 && total >= 28 && address_at(ip, 16) == PEER_REMOTE_STRANGER && be16(ip, 20) == remote.LISTEN_PORT
		if total < 20 || total > len(ip) || be16(ip, 6) & 0x3FFF != 0 || address_at(ip, 12) != MACHINE_ADDRESS || (address_at(ip, 16) != PEER_ADDRESS && !to_flood && !to_stranger) {
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
			if be16(payload, 0) == QUIC_SERVER_PORT {
				if address_at(ip, 16) == PEER_ADDRESS && peer_relay_datagram(peer, u16(be16(payload, 2)), payload[8:]) {
					free_all(context.temp_allocator)
					return
				}
				peer_quic_datagram(peer, address_at(ip, 16), u16(be16(payload, 2)), payload[8:])
				free_all(context.temp_allocator)
				return
			}
			if be16(payload, 0) == remote.LISTEN_PORT {
				peer_remote_datagram(peer, address_at(ip, 16), u16(be16(payload, 2)), payload[8:])
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
		case 6:
			if incoming, ok := peer_tcp_frame(peer, ip, payload); ok {
				peer_tcp_tick(peer, {incoming})
			}
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
