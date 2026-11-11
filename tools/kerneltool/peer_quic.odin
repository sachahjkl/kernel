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
PEER_QUIC_PORT_FIRST :: 41000
PEER_QUIC_TIME_LIMIT :: 120 * time.Second // On the clock of the host: it only ends a case that hangs.
PEER_QUIC_FLOOD :: 1000 // The datagrams of the flood that no key opens.

Peer_Quic :: struct {
	cryptography:  quic.Cryptography,
	generator:     random.Generator,
	configuration: quic.Connection_Configuration,
	pinned:        bool,
	clients:       []quic.Connection,
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
	total:         int, // The bytes of the echo of each client.
	written:       [PEER_QUIC_CAPACITY]int,
	read:          [PEER_QUIC_CAPACITY]int,
	finished:      [PEER_QUIC_CAPACITY]bool,
	expect_failure: bool, // The case passes when the handshake fails with bad_certificate.
	vanish:        bool, // The client sends its first datagram, then nothing.
	flood_sent:    int,
	flood_answers: int, // Datagrams of the server to an address of the flood that no key opens: there must be none.
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
	state.expect_failure, state.vanish = false, false
	state.flood_sent, state.flood_answers, state.negotiation_answers = 0, 0, 0
	state.failure = ""
	state.client_count = 1
	state.total = 1 << 20
	switch name {
	case "echo":
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
		if !quic.connection_start_client(&state.clients[index], &configuration, &state.cryptography, &state.generator, peer_quic_now(state), &error) {
			state.failure = "the client did not start"
			return false
		}
	}
	return true
}

// peer_quic_udp builds a frame of a UDP datagram from an address of the
// peer to the QUIC server of the machine.
@(private = "file")
peer_quic_udp :: proc(peer: ^Peer, source: [4]u8, port: u16, data: []u8) -> []u8 {
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
	put16(frame, 36, QUIC_SERVER_PORT)
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
		// A Version Negotiation packet (version 0) that lists version 1, to
		// the address that asked for another version; any other datagram to
		// the flood is an answer to a forged Initial.
		if destination == ([4]u8{198, 19, 0, 1}) && len(data) >= 7 && data[0] & 0x80 != 0 && be16(data, 1) == 0 && be16(data, 3) == 0 && be16(data, len(data) - 4) == 0 && be16(data, len(data) - 2) == 1 {
			state.negotiation_answers += 1
		} else {
			state.flood_answers += 1
		}
		return
	}
	if state.loss > 0 && peer_quic_random(state) % 1000 < state.loss {
		state.dropped += 1
		return
	}
	for index in 0 ..< state.client_count {
		if state.ports[index] == port {
			if state.vanish && index == 0 {
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
@(private = "file")
peer_quic_flood :: proc(peer: ^Peer, state: ^Peer_Quic) {
	for _ in 0 ..< 25 {
		if state.flood_sent >= PEER_QUIC_FLOOD {
			return
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
		if state.vanish && index == 0 && client.bytes_sent > 0 {
			continue
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
		peer_quic_check(state, wanted)
	}
}

// peer_quic_echo writes the pattern of the TCP cases on the stream of each
// client, then checks each byte that comes back.
@(private = "file")
peer_quic_echo :: proc(state: ^Peer_Quic) {
	chunk: [4096]u8
	for index in 0 ..< state.client_count {
		client := &state.clients[index]
		for state.written[index] < state.total {
			count := min(len(chunk), state.total - state.written[index])
			for place in 0 ..< count {
				chunk[place] = web.pattern(state.written[index] + place)
			}
			taken := quic.stream_write(client, chunk[:count], state.written[index] + count == state.total)
			state.written[index] += taken
			if taken < count {
				break
			}
		}
		for {
			count, ended, _ := quic.stream_read(client, chunk[:])
			for place in 0 ..< count {
				if chunk[place] != web.pattern(state.read[index] + place) && state.failure == "" {
					state.failure = fmt.aprintf("client %d: the byte %d came back changed", index, state.read[index] + place)
				}
			}
			state.read[index] += count
			state.finished[index] = state.finished[index] || ended
			if count == 0 {
				break
			}
		}
	}
}

// peer_quic_check ends the case when it passed or failed.
@(private = "file")
peer_quic_check :: proc(state: ^Peer_Quic, wanted: int) {
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
		// The client sent its first datagram; the server ends the record at
		// its handshake deadline (the scenario reads the log).
		if client.bytes_sent > 0 {
			state.result = "a client sent its first Initial and vanished"
			peer_quic_end(state, wanted, true)
			return
		}
	case:
		done := true
		for index in 0 ..< state.client_count {
			done = done && state.finished[index] && state.read[index] == state.total
		}
		if state.name == "flood" {
			done = done && state.flood_sent > PEER_QUIC_FLOOD
		}
		if done {
			if state.flood_answers != 0 {
				state.failure = fmt.aprintf("the server answered %d datagrams of the flood that no key opens", state.flood_answers)
				peer_quic_end(state, wanted, false)
				return
			}
			if state.name == "flood" && state.negotiation_answers != 1 {
				state.failure = fmt.aprintf("%d Version Negotiation packets for one datagram of another version, not 1", state.negotiation_answers)
				peer_quic_end(state, wanted, false)
				return
			}
			for index in 0 ..< state.client_count {
				quic.connection_close(&state.clients[index], 0, peer_quic_now(state))
			}
			state.result = fmt.aprintf("%d clients, %d bytes each way, srtt %d us; %d datagrams lost, %d reordered, %d repeated; %d datagrams of a flood, no answer", state.client_count, state.total, client.smoothed_round_trip, state.dropped, state.reordered, state.repeated, min(state.flood_sent, PEER_QUIC_FLOOD))
			peer_quic_end(state, wanted, true)
			return
		}
	}
	if elapsed > PEER_QUIC_TIME_LIMIT {
		state.failure = fmt.aprintf("not done in %v: client 0 in the state %v, %d of %d bytes back", PEER_QUIC_TIME_LIMIT, client.state, state.read[0], state.total)
		peer_quic_end(state, wanted, false)
	}
}

// peer_quic_end writes the result of a case. The clients that closed send
// their CONNECTION_CLOSE at the next ticks of a later case: the server ends
// their records by the close, or at its idle timeout.
@(private = "file")
peer_quic_end :: proc(state: ^Peer_Quic, wanted: int, passed: bool) {
	state.passed = passed
	if !passed {
		state.result = state.failure
	}
	state.running = false
	sync.atomic_store(&state.done, wanted)
}
