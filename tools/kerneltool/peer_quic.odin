package kerneltool

import "core:encoding/hex"
import "core:fmt"
import "core:sync"
import "core:time"
import "contract:errors"
import "support:quic"
import "support:random"
import "support:web"
import cryptography_module "../../modules/cryptography"

// The peer as QUIC clients of the program `quic_echo` (docs/QUIC.md,
// section 6). The tool asks for one case at a time (step Peer_Quic); the
// thread of the peer runs it with support/quic, the library of the system,
// and the module cryptography compiled for the host. The client pins the
// public key that the machine printed (step Quic_Key).
//
// Between its library and the machine, the peer changes the datagrams with
// a generator of numbers that the case seeds, as the TCP cases do: each run
// drops, reorders and repeats the same datagrams.
//
// The flood case sends datagrams from addresses of 198.18.0.0/15 (the range
// of RFC 2544 for tests): the network service routes the answers to them
// through the gateway, which is the peer, so the peer sees each one.

QUIC_SERVER_PORT :: 4433
PEER_QUIC_CAPACITY :: 8
PEER_QUIC_STREAMS :: 4 // The streams of one client at most: the limit that quic_echo gives.
PEER_QUIC_PORT_FIRST :: 41000
PEER_QUIC_TIME_LIMIT :: 120 * time.Second // On the clock of the host: it only ends a case that hangs.
PEER_QUIC_FLOOD :: 1000 // The datagrams of the flood that no key opens.
// The datagrams of the flood in one tick of the peer (1 ms or more): 1000 in
// 200 ms. Faster, the 64 admitted remotes of the network service can be
// full before quic_echo releases the remotes that it refused, and a forged
// datagram is dropped before it reaches the program.
PEER_QUIC_FLOOD_PER_TICK :: 5
// The datagrams of the flood that may wait for their answer: the server
// answers each Initial with a Retry, and the peer reads one frame of the
// machine in each tick. With no bound, the answers pile up in the socket of
// the peer faster than it reads them, and the host drops them: the count
// of the answers then says nothing of the server. The flood goes on after
// PEER_QUIC_FLOOD_STALL with no new answer: the network service may drop a
// datagram of the flood, which is allowed.
PEER_QUIC_FLOOD_WAITING :: 32
PEER_QUIC_FLOOD_STALL :: 50 * time.Millisecond
// The forged part of the flood that is authentic: Initials that open
// (anyone can make one) with no token, 2 from each of 4 forged addresses. With Retry,
// each one gets a Retry to its forged address, and takes no record.
PEER_QUIC_SPOOFED :: 8
// The time after the last datagram of the flood in which an answer can
// still come: the Version Negotiation packet, or an answer to a forged
// Initial, which must not come.
PEER_QUIC_FLOOD_SETTLE :: 2 * time.Second
// The copies of the CONNECTION_CLOSE of a client at the end of a case, sent
// outside the changes of the case (loss, reorder). One close that the case
// drops, or holds for a reorder with no later frame to let it go, leaves
// the server to its idle timeout, and the step that reads "closed by the
// client" then depends on a clock. The server in the draining state sends
// nothing back (RFC 9000, section 10.2.2), so the client cannot learn that
// the close came: it sends copies. The path from the peer to the server
// (the loopback of the host, the device, the network service) drops a
// datagram only when a queue is full, which no case leaves at its end:
// 3 copies stand for the loss of 2 of them.
PEER_QUIC_CLOSE_COPIES :: 3

Peer_Quic :: struct {
	cryptography:  quic.Cryptography,
	generator:     random.Generator,
	configuration: quic.Connection_Configuration,
	pinned:        bool,
	clients:       []quic.Connection,
	client_streams: []quic.Stream, // PEER_QUIC_STREAMS records for each client, in the order of the clients.
	client_count:  int,
	ports:         [PEER_QUIC_CAPACITY]u16,
	next_port:     u16,
	start:         time.Tick,
	// The changes of the datagrams, per thousand.
	random:        u64,
	loss:          u64,
	reorder:       u64,
	duplicate:     u64,
	held:          [dynamic][]u8, // Frames that wait: they go after the next frame.
	dropped, reordered, repeated: int,
	// The case that runs.
	name:          string,
	running:       bool,
	started:       time.Tick,
	total:         int, // The bytes of the echo of each stream.
	streams_per_client: int,
	stream_identifiers: [PEER_QUIC_CAPACITY][PEER_QUIC_STREAMS]u64,
	stream_opened: [PEER_QUIC_CAPACITY][PEER_QUIC_STREAMS]bool,
	written:       [PEER_QUIC_CAPACITY][PEER_QUIC_STREAMS]int,
	read:          [PEER_QUIC_CAPACITY][PEER_QUIC_STREAMS]int,
	finished:      [PEER_QUIC_CAPACITY][PEER_QUIC_STREAMS]bool,
	expect_failure: bool, // The case passes when the handshake fails with bad_certificate.
	vanish:        bool, // The client takes the Retry, sends its Initial with the token, then nothing.
	silent:        bool, // The case "silent": at the end of its echo, the client sends nothing more and takes nothing, with no close.
	silenced:      bool, // The client of the case "silent" went silent: until the next case, its datagrams are dropped both ways.
	vanish_after_bytes: u64, // The bytes that the client of the vanish case had sent when it took the Retry.
	flood_sent:    int,
	flood_ended_at: time.Tick, // The last datagram of the flood went.
	flood_answers: int, // Datagrams of the server to an address of the flood that are not a Retry: there must be none.
	retry_answers: int, // Retry packets to the addresses of the flood: at most one for each Initial of the flood.
	answer_bytes:  [PEER_QUIC_FLOOD + PEER_QUIC_SPOOFED]int, // The bytes of the answers to each address of the flood: at most 3 times the 1200 that it sent.
	most_answer_bytes: int,
	// The Retry packets to each address and port of the flood, which sent
	// one Initial: at most one each.
	retries_to:        [PEER_QUIC_FLOOD + PEER_QUIC_SPOOFED]int,
	most_retries_to:   int,
	last_answer_at: time.Tick, // The last answer to the flood: the flood waits for its answers.
	negotiation_answers: int, // Version Negotiation packets that name version 1.
	failure:       string,
	// Between the threads: the tool writes `wanted`, the peer writes `done`.
	wanted:        int,
	done:          int,
	passed:        bool,
	result:        string,
}

peer_quic_make :: proc() -> ^Peer_Quic {
	state := new(Peer_Quic)
	state.clients = make([]quic.Connection, PEER_QUIC_CAPACITY)
	state.client_streams = make([]quic.Stream, PEER_QUIC_CAPACITY * PEER_QUIC_STREAMS)
	state.cryptography = {
		seal_with_aes_128_gcm                = cryptography_module.seal_with_aes_128_gcm,
		open_with_aes_128_gcm                = cryptography_module.open_with_aes_128_gcm,
		seal_with_chacha20_poly1305          = cryptography_module.seal_with_chacha20_poly1305,
		open_with_chacha20_poly1305          = cryptography_module.open_with_chacha20_poly1305,
		hkdf_sha256_extract                  = cryptography_module.hkdf_sha256_extract,
		hkdf_sha256_expand                   = cryptography_module.hkdf_sha256_expand,
		header_protection_mask_with_aes_128  = cryptography_module.header_protection_mask_with_aes_128,
		header_protection_mask_with_chacha20 = cryptography_module.header_protection_mask_with_chacha20,
		sha256                               = cryptography_module.sha256,
		hmac_sha256                          = cryptography_module.hmac_sha256,
		x25519                               = cryptography_module.x25519_export,
		ed25519_public_key                   = cryptography_module.ed25519_public_key,
		ed25519_sign                         = cryptography_module.ed25519_sign,
		ed25519_verify                       = cryptography_module.ed25519_verify,
	}
	// A client of the test: a fixed seed, so that each run is the same. It
	// says "processor", the least strength that QUIC asks: the keys of this
	// client protect nothing but the test.
	seed: [random.SEED_SIZE]u8
	for index in 0 ..< random.SEED_SIZE {
		seed[index] = u8(0x51 + index)
	}
	random.generator_seed(&state.generator, &seed, .Processor)
	state.configuration = {idle_timeout_milliseconds = 30_000}
	state.configuration.tls = {role = .Client, least_seed_strength = .Processor}
	state.configuration.tls.application_protocol_length = copy(state.configuration.tls.application_protocol[:], "kernel-remote")
	state.next_port = PEER_QUIC_PORT_FIRST
	state.start = time.tick_now()
	return state
}

peer_quic_free :: proc(state: ^Peer_Quic) {
	delete(state.clients)
	delete(state.client_streams)
	for frame in state.held {
		delete(frame)
	}
	delete(state.held)
	free(state)
}

peer_quic_now :: proc(state: ^Peer_Quic) -> u64 {
	return u64(time.tick_since(state.start) / time.Microsecond) + 1
}

peer_quic_random :: proc(state: ^Peer_Quic) -> u64 {
	state.random ~= state.random << 13
	state.random ~= state.random >> 7
	state.random ~= state.random << 17
	return state.random
}

peer_quic_flood_address :: proc(address: [4]u8) -> bool {
	return address[0] == 198 && (address[1] == 18 || address[1] == 19)
}

// peer_quic_pin takes the public key of the server, as 64 hexadecimal
// digits.
peer_quic_pin :: proc(peer: ^Peer, text: string) -> bool {
	key, ok := hex.decode(transmute([]u8)text, context.temp_allocator)
	if !ok || len(key) != 32 {
		return false
	}
	sync.mutex_lock(&peer.lock)
	copy(peer.quic.configuration.tls.server_public_key[:], key)
	peer.quic.pinned = true
	sync.mutex_unlock(&peer.lock)
	return true
}

// peer_quic_case asks the thread of the peer for a case, and waits for its
// end.
peer_quic_case :: proc(peer: ^Peer, name: string) -> (passed: bool, result: string) {
	state := peer.quic
	sync.mutex_lock(&peer.lock)
	state.name = name
	sync.mutex_unlock(&peer.lock)
	serial := sync.atomic_load(&state.wanted) + 1
	sync.atomic_store(&state.wanted, serial)
	start := time.tick_now()
	for sync.atomic_load(&state.done) != serial {
		if time.tick_since(start) > PEER_QUIC_TIME_LIMIT + 10 * time.Second {
			return false, "the peer did not end the case"
		}
		time.sleep(20 * time.Millisecond)
	}
	return state.passed, state.result
}

// peer_quic_case_start prepares the case that the tool asked for: its
// clients, its changes of the datagrams, what it checks.
@(private = "file")
peer_quic_case_start :: proc(peer: ^Peer, state: ^Peer_Quic) -> bool {
	sync.mutex_lock(&peer.lock)
	name := state.name
	pinned := state.pinned
	sync.mutex_unlock(&peer.lock)
	state.running = true
	state.started = time.tick_now()
	state.loss, state.reorder, state.duplicate = 0, 0, 0
	state.dropped, state.reordered, state.repeated = 0, 0, 0
	state.written, state.read, state.finished = {}, {}, {}
	state.stream_identifiers, state.stream_opened = {}, {}
	state.streams_per_client = 1
	state.expect_failure, state.vanish = false, false
	state.silent, state.silenced = false, false
	state.flood_sent, state.flood_answers, state.negotiation_answers, state.retry_answers = 0, 0, 0, 0
	state.answer_bytes, state.most_answer_bytes = {}, 0
	state.retries_to, state.most_retries_to = {}, 0
	state.last_answer_at = time.tick_now()
	state.vanish_after_bytes = 0
	state.failure = ""
	state.client_count = 1
	state.total = 1 << 20
	switch name {
	case "echo":
	case "streams":
		// 4 streams of one client at once, 256 KiB each way on each.
		state.streams_per_client = PEER_QUIC_STREAMS
		state.total = 256 * 1024
	case "loss":
		// The changes of the TCP cases: 5 % lost, 10 % reordered, 10 % repeated.
		state.random, state.loss, state.reorder, state.duplicate = 0x5155_4943_0000_0001, 50, 100, 100
	case "crowd":
		state.client_count = PEER_QUIC_CAPACITY
		state.total = 64 * 1024
	case "wrong key":
		state.expect_failure = true
		state.total = 0
	case "flood":
		state.random = 0x464c_4f4f_4400_0002
		state.total = 64 * 1024
	case "silent":
		// 64 KiB each way, then the client goes silent with no close: the
		// server ends the record at its idle timeout.
		state.silent = true
		state.total = 64 * 1024
	case "vanish":
		state.vanish = true
		state.total = 0
	case:
		state.failure = fmt.aprintf("no QUIC case \"%s\"", name)
		return false
	}
	if !pinned {
		state.failure = "no key is pinned: the step Quic_Key comes before"
		return false
	}
	configuration := state.configuration
	if state.expect_failure {
		configuration.tls.server_public_key[0] ~= 0x01
	}
	error: errors.Error_Record
	for index in 0 ..< state.client_count {
		state.ports[index] = state.next_port
		state.next_port += 1
		streams_of_client := state.client_streams[index * PEER_QUIC_STREAMS:][:PEER_QUIC_STREAMS]
		if !quic.connection_start_client(&state.clients[index], streams_of_client, &configuration, &state.cryptography, &state.generator, peer_quic_now(state), &error) {
			state.failure = "the client did not start"
			return false
		}
	}
	return true
}

// peer_quic_udp builds a frame of a UDP datagram from an address of the
// peer to the QUIC server of the machine. The relay (peer_relay.odin)
// builds its frames with it too.
peer_quic_udp :: proc(peer: ^Peer, source: [4]u8, port: u16, data: []u8) -> []u8 {
	return peer_udp_to_machine(peer, source, port, QUIC_SERVER_PORT, data)
}

// peer_udp_to_machine builds a frame of a UDP datagram from an address and
// a port of the peer to a UDP port of the machine.
peer_udp_to_machine :: proc(peer: ^Peer, source: [4]u8, port: u16, destination_port: u16, data: []u8) -> []u8 {
	length := 8 + len(data)
	frame := make([]u8, max(42 + len(data), 60), context.temp_allocator)
	sync.mutex_lock(&peer.lock)
	hardware := peer.hardware
	sync.mutex_unlock(&peer.lock)
	copy(frame[0:6], hardware[:])
	copy(frame[6:12], PEER_HARDWARE[:])
	put16(frame, 12, 0x0800)
	ip := frame[14:34]
	ip[0] = 0x45
	put16(ip, 2, 20 + length)
	put16(ip, 6, 0x4000)
	ip[8] = 64
	ip[9] = 17
	machine_address := MACHINE_ADDRESS
	address := source
	copy(ip[12:16], address[:])
	copy(ip[16:20], machine_address[:])
	put16(ip, 10, internet_sum(0, ip))
	put16(frame, 34, int(port))
	put16(frame, 36, int(destination_port))
	put16(frame, 38, length)
	copy(frame[42:], data)
	value := internet_sum(pseudo_sum(address[:], machine_address[:], length), frame[34:42 + len(data)])
	put16(frame, 40, value == 0 ? 0xFFFF : value)
	return frame
}

// peer_quic_send sends a frame to the machine, with the changes of the
// case: a lost frame, a frame held until the next one, a frame sent twice.
@(private = "file")
peer_quic_send :: proc(peer: ^Peer, state: ^Peer_Quic, frame: []u8) {
	if state.loss > 0 && peer_quic_random(state) % 1000 < state.loss {
		state.dropped += 1
		return
	}
	if state.reorder > 0 && peer_quic_random(state) % 1000 < state.reorder {
		append(&state.held, clone_bytes(frame))
		state.reordered += 1
		return
	}
	peer_send(peer, frame)
	if state.duplicate > 0 && peer_quic_random(state) % 1000 < state.duplicate {
		peer_send(peer, frame)
		state.repeated += 1
	}
	for held in state.held {
		peer_send(peer, held)
		delete(held)
	}
	clear(&state.held)
}

@(private = "file")
clone_bytes :: proc(bytes: []u8) -> []u8 {
	copy_of_the_bytes := make([]u8, len(bytes))
	copy(copy_of_the_bytes, bytes)
	return copy_of_the_bytes
}

// peer_quic_datagram takes a datagram of the QUIC server of the machine:
// to a client of the case, or to an address of the flood.
peer_quic_datagram :: proc(peer: ^Peer, destination: [4]u8, port: u16, data: []u8) {
	state := peer.quic
	if peer_quic_flood_address(destination) {
		state.last_answer_at = time.tick_now()
		// The bytes to each address: 198.18.x.y is the datagram x * 256 + y of
		// the flood; 198.19.1.z the spoofed Initials of z.
		slot := -1
		if destination[1] == 18 {
			slot = int(destination[2]) << 8 | int(destination[3])
		} else if destination[2] == 1 {
			slot = PEER_QUIC_FLOOD + 2 * int(destination[3]) + int(port) % 2
		}
		if slot >= 0 && slot < len(state.answer_bytes) {
			state.answer_bytes[slot] += len(data)
			state.most_answer_bytes = max(state.most_answer_bytes, state.answer_bytes[slot])
		}
		// A Version Negotiation packet (version 0) that lists version 1, to
		// the address that asked for another version; any other datagram to
		// the flood is an answer to a forged Initial.
		switch {
		case destination == ([4]u8{198, 19, 0, 1}) && len(data) >= 7 && data[0] & 0x80 != 0 && be16(data, 1) == 0 && be16(data, 3) == 0 && be16(data, len(data) - 4) == 0 && be16(data, len(data) - 2) == 1:
			state.negotiation_answers += 1
		case len(data) >= 5 && len(data) <= 3 * quic.MAX_DATAGRAM_SIZE && data[0] & 0xF0 == 0xF0 && be16(data, 1) == 0 && be16(data, 3) == 1:
			// A Retry of version 1 (the form, the fixed bit, the type 3),
			// within 3 times the datagram that it answers.
			state.retry_answers += 1
			if slot >= 0 && slot < len(state.retries_to) {
				state.retries_to[slot] += 1
				state.most_retries_to = max(state.most_retries_to, state.retries_to[slot])
			}
		case:
			state.flood_answers += 1
		}
		return
	}
	if state.loss > 0 && peer_quic_random(state) % 1000 < state.loss {
		state.dropped += 1
		return
	}
	if state.silenced {
		return
	}
	for index in 0 ..< state.client_count {
		if state.ports[index] == port {
			// The client of the vanish case takes the Retry, then nothing.
			if state.vanish && index == 0 && state.clients[0].retried {
				return
			}
			error: errors.Error_Record
			quic.connection_datagram_receive(&state.clients[index], data, peer_quic_now(state), &error)
			return
		}
	}
}

// peer_quic_flood sends a part of the flood at each tick: datagrams of 1200
// random bytes shaped as Initials of version 1, each from its own address
// of 198.18.0.0/15, then one long header of another version.
// peer_quic_authentic_initial builds an authentic Initial of 1200 bytes,
// with a PING and no token, for a Destination Connection ID: anyone can
// make it, because its keys come from that identifier.
@(private = "file")
peer_quic_authentic_initial :: proc(state: ^Peer_Quic, identifier: [quic.CONNECTION_ID_SIZE]u8) -> (datagram: [quic.MAX_DATAGRAM_SIZE]u8) {
	client_keys, server_keys: quic.Packet_Keys
	error: errors.Error_Record
	destination := identifier
	quic.initial_keys(&state.cryptography, destination[:], &client_keys, &server_keys, &error)
	at := 0
	datagram[at] = quic.LONG_HEADER_FORM | quic.FIXED_BIT | 0x03
	at += 1
	datagram[at], datagram[at + 1], datagram[at + 2], datagram[at + 3] = 0, 0, 0, 1
	at += 4
	datagram[at] = quic.CONNECTION_ID_SIZE
	at += 1
	at += copy(datagram[at:], destination[:])
	datagram[at], datagram[at + 1] = 0, 0 // No Source Connection ID, no token.
	at += 2
	frames_length := quic.MAX_DATAGRAM_SIZE - (at + 2 + 4) - quic.TAG_SIZE
	at += quic.variable_length_integer_write(datagram[:], at, u64(4 + frames_length + quic.TAG_SIZE), 2)
	datagram[at + 4] = quic.FRAME_PING
	quic.packet_seal(&state.cryptography, &client_keys, datagram[:], 0, at, frames_length, 0, &error)
	return
}

@(private = "file")
peer_quic_flood :: proc(peer: ^Peer, state: ^Peer_Quic) {
	if state.flood_sent == 0 {
		// The spoofed authentic Initials, 2 from each of 4 addresses.
		for index in 0 ..< PEER_QUIC_SPOOFED {
			identifier: [quic.CONNECTION_ID_SIZE]u8
			identifier[0], identifier[1] = 0x5F, u8(index)
			datagram := peer_quic_authentic_initial(state, identifier)
			peer_send(peer, peer_quic_udp(peer, {198, 19, 1, u8(index / 2)}, u16(40000 + index), datagram[:]))
		}
	}
	waiting := state.flood_sent - state.retry_answers - state.flood_answers
	if waiting >= PEER_QUIC_FLOOD_WAITING && time.tick_since(state.last_answer_at) < PEER_QUIC_FLOOD_STALL {
		return
	}
	for _ in 0 ..< PEER_QUIC_FLOOD_PER_TICK {
		if state.flood_sent >= PEER_QUIC_FLOOD {
			break
		}
		datagram: [quic.MAX_DATAGRAM_SIZE]u8
		for &byte in datagram {
			byte = u8(peer_quic_random(state))
		}
		datagram[0] = quic.LONG_HEADER_FORM | quic.FIXED_BIT | 0x03
		datagram[1], datagram[2], datagram[3], datagram[4] = 0, 0, 0, 1
		datagram[5] = quic.CONNECTION_ID_SIZE
		datagram[14], datagram[15] = 0, 0
		quic.variable_length_integer_write(datagram[:], 16, quic.MAX_DATAGRAM_SIZE - 18, 2)
		source := [4]u8{198, 18, u8(state.flood_sent >> 8), u8(state.flood_sent)}
		peer_send(peer, peer_quic_udp(peer, source, 40000, datagram[:]))
		state.flood_sent += 1
	}
	if state.flood_sent == PEER_QUIC_FLOOD {
		// Another version, in 1200 bytes: the server answers with one
		// Version Negotiation packet.
		datagram: [quic.MAX_DATAGRAM_SIZE]u8
		datagram[0] = quic.LONG_HEADER_FORM | quic.FIXED_BIT
		datagram[1], datagram[2], datagram[3], datagram[4] = 0xFF, 0x00, 0x00, 0x1D
		datagram[5] = 8
		datagram[14] = 8
		peer_send(peer, peer_quic_udp(peer, {198, 19, 0, 1}, 40000, datagram[:]))
		state.flood_sent += 1
		state.flood_ended_at = time.tick_now()
	}
}

// peer_quic_tick runs the case: it starts it, writes and checks the echo,
// and ends the case. The clients of the last case move their datagrams at
// each tick, also after their case ended: their CONNECTION_CLOSE goes to the
// server then.
peer_quic_tick :: proc(peer: ^Peer) {
	state := peer.quic
	if state == nil {
		return
	}
	wanted := sync.atomic_load(&state.wanted)
	if !state.running && wanted != sync.atomic_load(&state.done) {
		if !peer_quic_case_start(peer, state) {
			peer_quic_end(state, wanted, false)
			return
		}
	}
	now := peer_quic_now(state)
	if state.running {
		if state.name == "flood" {
			peer_quic_flood(peer, state)
		}
		peer_quic_echo(state)
	}
	buffer: [quic.MAX_DATAGRAM_SIZE]u8
	for index in 0 ..< state.client_count {
		client := &state.clients[index]
		if state.silenced {
			continue
		}
		if state.vanish && index == 0 && client.retried {
			if state.vanish_after_bytes == 0 {
				state.vanish_after_bytes = client.bytes_sent
			} else if client.bytes_sent > state.vanish_after_bytes {
				continue
			}
		}
		for _ in 0 ..< 64 {
			length := quic.connection_datagram_send(client, buffer[:], now)
			if length == 0 {
				break
			}
			peer_quic_send(peer, state, peer_quic_udp(peer, PEER_ADDRESS, state.ports[index], buffer[:length]))
		}
		if quic.connection_deadline(client) <= now {
			quic.connection_time_passes(client, now)
		}
	}
	if state.running {
		peer_quic_check(peer, state, wanted)
	}
}

// peer_quic_echo writes the pattern of the TCP cases on each stream of
// each client, then checks each byte that comes back. A client opens its
// streams when the limit of the server allows them.
@(private = "file")
peer_quic_echo :: proc(state: ^Peer_Quic) {
	chunk: [4096]u8
	for index in 0 ..< state.client_count {
		client := &state.clients[index]
		for slot in 0 ..< state.streams_per_client {
			if !state.stream_opened[index][slot] {
				identifier, opened := quic.stream_open(client)
				if !opened {
					break
				}
				state.stream_identifiers[index][slot] = identifier
				state.stream_opened[index][slot] = true
			}
			identifier := state.stream_identifiers[index][slot]
			for state.written[index][slot] < state.total {
				count := min(len(chunk), state.total - state.written[index][slot])
				for place in 0 ..< count {
					chunk[place] = web.pattern(state.written[index][slot] + place)
				}
				taken := quic.stream_write(client, identifier, chunk[:count], state.written[index][slot] + count == state.total)
				state.written[index][slot] += taken
				if taken < count {
					break
				}
			}
			for {
				count, ended, _ := quic.stream_read(client, identifier, chunk[:])
				for place in 0 ..< count {
					if chunk[place] != web.pattern(state.read[index][slot] + place) && state.failure == "" {
						state.failure = fmt.aprintf("client %d, stream %d: the byte %d came back changed", index, identifier, state.read[index][slot] + place)
					}
				}
				state.read[index][slot] += count
				state.finished[index][slot] = state.finished[index][slot] || ended
				if count == 0 {
					break
				}
			}
		}
	}
}

// peer_quic_check ends the case when it passed or failed.
@(private = "file")
peer_quic_check :: proc(peer: ^Peer, state: ^Peer_Quic, wanted: int) {
	elapsed := time.tick_since(state.started)
	if state.failure != "" {
		peer_quic_end(state, wanted, false)
		return
	}
	client := &state.clients[0]
	switch {
	case state.expect_failure:
		// A server whose key is not the pinned one: the client refuses it
		// with bad_certificate (0x100 + 42).
		if client.state == .Closing || client.state == .Draining || client.state == .Closed {
			if client.close_error_code == quic.CRYPTO_ERROR_BASE + 42 {
				state.result = "the client refused the server: its key is not the pinned key (bad_certificate)"
				peer_quic_end(state, wanted, true)
			} else {
				state.failure = fmt.aprintf("the client closed with the code %x, not bad_certificate", client.close_error_code)
				peer_quic_end(state, wanted, false)
			}
			return
		}
	case state.vanish:
		// The client took the Retry and sent its Initial with the token: the
		// server took a record, which it ends at the handshake deadline (the
		// scenario reads the log).
		if client.retried && state.vanish_after_bytes > 0 && client.bytes_sent > state.vanish_after_bytes {
			state.result = "a client sent its Initial with the token of the Retry, and vanished"
			peer_quic_end(state, wanted, true)
			return
		}
	case:
		done := true
		for index in 0 ..< state.client_count {
			for slot in 0 ..< state.streams_per_client {
				done = done && state.finished[index][slot] && state.read[index][slot] == state.total
			}
		}
		if state.name == "flood" {
			// The answers of the server come after the flood: the check waits
			// for them.
			done = done && state.flood_sent > PEER_QUIC_FLOOD && time.tick_since(state.flood_ended_at) > PEER_QUIC_FLOOD_SETTLE
		}
		if done {
			if state.flood_answers != 0 {
				state.failure = fmt.aprintf("the server answered %d datagrams of the flood with something else than a Retry", state.flood_answers)
				peer_quic_end(state, wanted, false)
				return
			}
			// What must hold under a flood, which may drop datagrams: no
			// record answers a forged address (any answer that is not a
			// Retry fails above), the server answers, at most one Retry for
			// each Initial, never more than 3 times the 1200 bytes that an
			// address sent, and the real client got its echo (done). The
			// count of Retries is reported.
			if state.name == "flood" && (state.retry_answers == 0 || state.most_retries_to > 1 || state.most_answer_bytes > 3 * quic.MAX_DATAGRAM_SIZE) {
				state.failure = fmt.aprintf("%d Retry packets to the flood (at least 1), the most Retries to one address and port %d (at most 1, for its one Initial), the most bytes to one address %d (at most %d)", state.retry_answers, state.most_retries_to, state.most_answer_bytes, 3 * quic.MAX_DATAGRAM_SIZE)
				peer_quic_end(state, wanted, false)
				return
			}
			if state.name == "flood" && state.negotiation_answers > 1 {
				state.failure = fmt.aprintf("%d Version Negotiation packets for one datagram of another version, not 1, %v after the last datagram of the flood; %d datagrams of the flood sent, %d answers to the flood", state.negotiation_answers, time.tick_since(state.flood_ended_at), state.flood_sent, state.flood_answers)
				peer_quic_end(state, wanted, false)
				return
			}
			if state.silent {
				// No close: the client takes nothing more and sends nothing
				// more. The server has a packet of its own in flight that the
				// client never acknowledges (the end of its stream, or the
				// MAX_STREAMS after it), so it probes until its idle timeout.
				state.silenced = true
			} else {
				for index in 0 ..< state.client_count {
					peer_quic_close(peer, state, index)
				}
			}
			state.result = fmt.aprintf("%d clients of %d streams, %d bytes each way on each stream, srtt %d us; %d datagrams lost, %d reordered, %d repeated; %d datagrams of a flood and %d spoofed Initials, %d Retries to it (the most bytes to one address %d), %d Version Negotiation packet", state.client_count, state.streams_per_client, state.total, client.smoothed_round_trip, state.dropped, state.reordered, state.repeated, min(state.flood_sent, PEER_QUIC_FLOOD), PEER_QUIC_SPOOFED, state.retry_answers, state.most_answer_bytes, state.negotiation_answers)
			peer_quic_end(state, wanted, true)
			return
		}
	}
	if elapsed > PEER_QUIC_TIME_LIMIT {
		state.failure = fmt.aprintf("not done in %v: client 0 in the state %v (closed with %x), %d of %d bytes back; %d datagrams of the flood sent, %d Version Negotiation answers, %d answers to the flood", PEER_QUIC_TIME_LIMIT, client.state, client.close_error_code, state.read[0][0], state.total, state.flood_sent, state.negotiation_answers, state.flood_answers)
		peer_quic_end(state, wanted, false)
	}
}

// peer_quic_close closes a client of a case that ended: its
// CONNECTION_CLOSE goes PEER_QUIC_CLOSE_COPIES times, outside the changes
// of the case, so that the server ends the record by the close and not by
// a clock. Later datagrams of the server get the close again from the
// closing state of the client, through the changes of the case, as any
// datagram of the client does.
@(private = "file")
peer_quic_close :: proc(peer: ^Peer, state: ^Peer_Quic, index: int) {
	client := &state.clients[index]
	now := peer_quic_now(state)
	quic.connection_close(client, 0, now)
	buffer: [quic.MAX_DATAGRAM_SIZE]u8
	length := quic.connection_datagram_send(client, buffer[:], now)
	if length == 0 {
		return
	}
	frame := peer_quic_udp(peer, PEER_ADDRESS, state.ports[index], buffer[:length])
	for _ in 0 ..< PEER_QUIC_CLOSE_COPIES {
		peer_send(peer, frame)
	}
}

// peer_quic_end writes the result of a case. Its clients closed (or, in the
// case "silent", went silent); their datagrams still move at the next
// ticks, until a later case starts its own clients.
@(private = "file")
peer_quic_end :: proc(state: ^Peer_Quic, wanted: int, passed: bool) {
	state.passed = passed
	if !passed {
		state.result = state.failure
	}
	state.running = false
	sync.atomic_store(&state.done, wanted)
}
