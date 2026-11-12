package kerneltool

import "core:fmt"
import "core:net"
import "core:sync"
import "core:time"

// A UDP relay in the peer of the tool (docs/QUIC.md, section 6): a program
// of the host, such as the QUIC client of OpenSSL, reaches the UDP port
// 4433 of the machine through the peer, with no network of the host but
// its loopback. QEMU user networking with restrict=on drops each UDP
// datagram of the machine (libslirp, udp_input), so the machine of
// `test quic-real` has the network device of the peer (-netdev dgram).
//
// - The relay has one UDP socket on the loopback of the host, at a port
//   that the system chooses (relay_port of the peer).
// - A datagram of a local client becomes a frame from 10.0.2.2, from a
//   source port that the relay gives that client (RELAY_PORT_FIRST + its
//   place), to 10.0.2.15 port 4433.
// - A datagram of the machine to 10.0.2.2 at a port of the relay goes back
//   to its client, from the socket of the relay.
// - A table of RELAY_CLIENTS clients: a new client takes a free place, or
//   the place with the oldest datagram.
// - A datagram over RELAY_DATA_LIMIT bytes, from either side, is dropped
//   and counted.
//
// The thread of the peer runs the relay: peer_run reads every frame of the
// machine that waits before it runs the ticks, and runs them at most once
// in a millisecond, so the answers of the machine never pile up in its
// socket. The relay socket does not block: each tick takes each datagram
// that waits there, RELAY_PER_TICK at most.

RELAY_CLIENTS :: 16
RELAY_PORT_FIRST :: 42000
RELAY_DATA_LIMIT :: 1472 // The UDP data of one Ethernet frame of 1500 bytes, with no fragment.
RELAY_PER_TICK :: 64
RELAY_TRACE_LIMIT :: 60 // Datagrams that the relay describes, for the message of a failure.

Relay_Client :: struct {
	used:      bool,
	client:    net.Endpoint,
	last_used: time.Tick,
}

Peer_Relay :: struct {
	socket:          net.UDP_Socket,
	port:            int, // The port of the relay on the loopback of the host.
	clients:         [RELAY_CLIENTS]Relay_Client,
	// The counts, read after the thread of the peer ended.
	to_machine:      int,
	to_host:         int,
	too_long:        int,
	no_client:       int, // A datagram of the machine to a port of the relay that no client holds.
	replaced:        int, // Clients whose place a new client took.
	// The first datagrams, described: the tool prints them when a step fails.
	trace:           [dynamic]string,
}

// peer_relay_start opens the socket of the relay. The peer starts it.
peer_relay_start :: proc(relay: ^Peer_Relay) -> bool {
	socket, err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if err != nil {
		fmt.eprintfln("kerneltool: the UDP relay of the peer has no socket: %v", err)
		return false
	}
	bound, bound_err := net.bound_endpoint(socket)
	if bound_err != nil {
		net.close(socket)
		return false
	}
	_ = net.set_blocking(socket, false)
	relay^ = {socket = socket, port = bound.port}
	return true
}

peer_relay_stop :: proc(relay: ^Peer_Relay) {
	net.close(relay.socket)
	for line in relay.trace {
		delete(line)
	}
	delete(relay.trace)
}

// peer_relay_describe keeps a line on one datagram, for the message of a
// failure: the direction, the ports, the length, the first bytes.
@(private = "file")
peer_relay_describe :: proc(peer: ^Peer, to_machine: bool, port: u16, data: []u8) {
	relay := &peer.relay
	sync.mutex_lock(&peer.lock)
	defer sync.mutex_unlock(&peer.lock)
	if len(relay.trace) >= RELAY_TRACE_LIMIT {
		return
	}
	shown := data[:min(len(data), 160)]
	append(&relay.trace, fmt.aprintf("%s, the relay port %d, %d bytes: %x%s", to_machine ? "host to machine" : "machine to host", port, len(data), shown, len(data) > len(shown) ? "..." : ""))
}

// peer_relay_tick takes each datagram that waits on the socket of the
// relay, and sends it to the machine as a frame.
peer_relay_tick :: proc(peer: ^Peer) {
	relay := &peer.relay
	if relay.port == 0 {
		return
	}
	buffer: [65536]u8
	for _ in 0 ..< RELAY_PER_TICK {
		count, from, err := net.recv_udp(relay.socket, buffer[:])
		if err != nil || count <= 0 {
			return
		}
		if count > RELAY_DATA_LIMIT {
			relay.too_long += 1
			continue
		}
		// The place of this client; else a free place; else the place whose
		// last datagram is the oldest.
		place, free, oldest := -1, -1, -1
		for &item, index in relay.clients {
			switch {
			case item.used && same_endpoint(item.client, from):
				place = index
			case !item.used:
				if free < 0 {
					free = index
				}
			case oldest < 0 || time.tick_diff(item.last_used, relay.clients[oldest].last_used) > 0:
				oldest = index
			}
			if place >= 0 {
				break
			}
		}
		if place < 0 {
			place = free >= 0 ? free : oldest
			if relay.clients[place].used {
				relay.replaced += 1
			}
			relay.clients[place] = {used = true, client = from}
		}
		relay.clients[place].last_used = time.tick_now()
		port := u16(RELAY_PORT_FIRST + place)
		peer_relay_describe(peer, true, port, buffer[:count])
		peer_send(peer, peer_quic_udp(peer, PEER_ADDRESS, port, buffer[:count]))
		relay.to_machine += 1
	}
}

// same_endpoint compares two endpoints of the loopback of the host.
@(private = "file")
same_endpoint :: proc(first, second: net.Endpoint) -> bool {
	first_address, first_four := first.address.(net.IP4_Address)
	second_address, second_four := second.address.(net.IP4_Address)
	return first.port == second.port && first_four && second_four && first_address == second_address
}

// peer_relay_datagram takes a datagram of the machine to 10.0.2.2: when its
// port is a port of the relay, it goes back to its client, and the call
// gives true.
peer_relay_datagram :: proc(peer: ^Peer, port: u16, data: []u8) -> bool {
	relay := &peer.relay
	if relay.port == 0 || port < RELAY_PORT_FIRST || int(port) >= RELAY_PORT_FIRST + RELAY_CLIENTS {
		return false
	}
	place := int(port) - RELAY_PORT_FIRST
	peer_relay_describe(peer, false, port, data)
	switch {
	case !relay.clients[place].used:
		relay.no_client += 1
	case len(data) > RELAY_DATA_LIMIT:
		relay.too_long += 1
	case:
		_, _ = net.send_udp(relay.socket, data, relay.clients[place].client)
		relay.to_host += 1
	}
	return true
}

// peer_relay_report prints the counts of the relay, when it carried a
// datagram.
peer_relay_report :: proc(relay: ^Peer_Relay) {
	if relay.to_machine == 0 && relay.to_host == 0 {
		return
	}
	fmt.printfln("kerneltool: the UDP relay of the peer: %d datagrams to the machine, %d to the host, %d too long, %d to a port with no client, %d clients replaced", relay.to_machine, relay.to_host, relay.too_long, relay.no_client, relay.replaced)
}

// peer_relay_trace_print prints the datagrams that the relay described.
peer_relay_trace_print :: proc(peer: ^Peer) {
	sync.mutex_lock(&peer.lock)
	defer sync.mutex_unlock(&peer.lock)
	if len(peer.relay.trace) == 0 {
		fmt.eprintln("kerneltool: the UDP relay of the peer carried no datagram")
		return
	}
	for line in peer.relay.trace {
		fmt.eprintfln("kerneltool: the relay: %s", line)
	}
}
