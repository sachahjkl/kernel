#+build !freestanding
// A server with several connections on the host: one Server of 16 records,
// clients with their own remote addresses, and a network in memory with a
// delay of 5 ms and a fake clock. The tests feed the server what a network
// can bring: many clients at once, a flood of forged Initials from many
// addresses, a client that vanishes in its handshake, another version.
package quic

import "contract:errors"
import "core:fmt"
import "core:testing"
import "support:random"

HARNESS_RECORDS :: 16
HARNESS_CLIENT_LIMIT :: 16
HARNESS_DELAY :: 5_000

Harness_Datagram :: struct {
	to_server:  bool,
	client:     int, // The client that sent it or that receives it; -1: a remote that is no client.
	remote:     Remote,
	deliver_at: u64,
	length:     int,
	bytes:      [MAX_DATAGRAM_SIZE]u8,
}

Harness :: struct {
	cryptography:         Cryptography,
	server_generator:     random.Generator,
	client_generators:    [HARNESS_CLIENT_LIMIT]random.Generator,
	server:               Server,
	connections:          []Connection,
	records:              []Server_Record,
	clients:              []Connection,
	client_remotes:       [HARNESS_CLIENT_LIMIT]Remote,
	client_configuration: Connection_Configuration,
	vanished:             [HARNESS_CLIENT_LIMIT]bool, // A client whose datagrams are lost, both ways.
	queue:                [dynamic]Harness_Datagram,
	due:                  [dynamic]Harness_Datagram, // The datagrams of one step that are due: a delivery can add to the queue.
	now:                  u64,
	released:             [dynamic]Remote, // Each remote that the server asked to release.
	most_in_use:          int,
	clients_not_started:  int, // A client whose start failed: a fault of the harness, which the failure messages say.
	// The echo of each record.
	echo_pending:         [][STREAM_BUFFER_SIZE]u8,
	echo_start:           [HARNESS_RECORDS]int,
	echo_end:             [HARNESS_RECORDS]int,
	echo_finished:        [HARNESS_RECORDS]bool,
	echo_finish_written:  [HARNESS_RECORDS]bool,
}

harness_make :: proc(client_count: int, client_address := u32(0)) -> ^Harness {
	harness := new(Harness)
	harness.cryptography = module_cryptography()
	harness.now = 1_000_000
	harness.connections = make([]Connection, HARNESS_RECORDS)
	harness.records = make([]Server_Record, HARNESS_RECORDS)
	harness.clients = make([]Connection, client_count)
	harness.echo_pending = make([][STREAM_BUFFER_SIZE]u8, HARNESS_RECORDS)
	// generator_seed erases the seed that it takes: each generator gets a
	// seed array of its own, made just before.
	server_seed := harness_seed(0xA0)
	random.generator_seed(&harness.server_generator, &server_seed, .Processor)
	server_configuration := Connection_Configuration{idle_timeout_milliseconds = 30_000}
	server_configuration.tls = {role = .Server, least_seed_strength = .Processor}
	server_configuration.tls.application_protocol_length = text_into(server_configuration.tls.application_protocol[:], "kernel-remote")
	copy(server_configuration.tls.server_private_key[:], bytes_of(SERVER_PRIVATE_KEY_OF_THE_TEST))
	harness.client_configuration = {idle_timeout_milliseconds = 30_000}
	harness.client_configuration.tls = {role = .Client, least_seed_strength = .Processor}
	harness.client_configuration.tls.application_protocol_length = text_into(harness.client_configuration.tls.application_protocol[:], "kernel-remote")
	error: errors.Error_Record
	secret := string(server_configuration.tls.server_private_key[:])
	result := harness.client_configuration.tls.server_public_key[:]
	harness.cryptography.ed25519_public_key(&secret, &result, &error)
	server_init(&harness.server, harness.connections, harness.records, &server_configuration, &harness.cryptography, &harness.server_generator, SERVER_LIMITS_DEFAULT, &error)
	for index in 0 ..< client_count {
		client_seed := harness_seed(u8(index))
		random.generator_seed(&harness.client_generators[index], &client_seed, .Processor)
		// One address for each client, unless the test gives one for all.
		address := client_address != 0 ? client_address : u32(0x0A00_0300 + index)
		harness.client_remotes[index] = {address, u16(50_000 + index)}
		if !connection_start_client(&harness.clients[index], &harness.client_configuration, &harness.cryptography, &harness.client_generators[index], harness.now, &error) {
			harness.clients_not_started += 1
		}
	}
	return harness
}

// harness_seed gives a seed that no other generator of the harness has:
// its first byte names the generator, and no seed is all zeros.
harness_seed :: proc(first: u8) -> (seed: [random.SEED_SIZE]u8) {
	for index in 0 ..< random.SEED_SIZE {
		seed[index] = u8(41 + index)
	}
	seed[0] = first
	return
}

// harness_describe gives the counters of the server and the state of each
// client, for the message of a failure.
harness_describe :: proc(harness: ^Harness) -> string {
	counters := harness.server.counters
	text := fmt.tprintf("server: accepted %d, ended %d, datagrams %d, unreadable %d, not authentic %d, too small %d, refused by the limit of a remote %d, by the limit of the handshakes %d, table full %d, from another remote %d, of no connection %d, version negotiations %d; records in use %d; clients that did not start %d; clients:", counters.accepted, counters.ended, counters.datagrams, counters.unreadable, counters.not_authentic, counters.too_small, counters.refused_remote_limit, counters.refused_handshake_limit, counters.refused_full, counters.other_remote, counters.no_connection, counters.version_negotiations, server_connections_in_use(&harness.server), harness.clients_not_started)
	for &client, index in harness.clients {
		text = fmt.tprintf("%s [%d: %v, closed with %x, by the handshake deadline %v, by the idle timeout %v, %d bytes sent, %d received]", text, index, client.state, client.close_error_code, client.closed_by_handshake_timeout, client.closed_by_idle_timeout, client.bytes_sent, client.bytes_received)
	}
	return text
}

harness_free :: proc(harness: ^Harness) {
	delete(harness.connections)
	delete(harness.records)
	delete(harness.clients)
	delete(harness.echo_pending)
	delete(harness.queue)
	delete(harness.due)
	delete(harness.released)
	free(harness)
}

harness_send :: proc(harness: ^Harness, to_server: bool, client: int, remote: Remote, bytes: []u8) {
	if client >= 0 && harness.vanished[client] {
		return
	}
	item := Harness_Datagram{to_server = to_server, client = client, remote = remote, deliver_at = harness.now + HARNESS_DELAY}
	item.length = copy(item.bytes[:], bytes)
	append(&harness.queue, item)
}

// harness_client_of gives the client of a remote, or -1.
harness_client_of :: proc(harness: ^Harness, remote: Remote) -> int {
	for index in 0 ..< len(harness.clients) {
		if harness.client_remotes[index] == remote {
			return index
		}
	}
	return -1
}

// harness_server_receive gives one datagram to the server, as a program
// does: the answer to the remote, then the release of the remote.
harness_server_receive :: proc(harness: ^Harness, remote: Remote, bytes: []u8) -> Server_Outcome {
	answer: [MAX_DATAGRAM_SIZE]u8
	outcome := server_datagram_receive(&harness.server, bytes, remote, answer[:], harness.now)
	if outcome.answer_length > 0 {
		harness_send(harness, false, harness_client_of(harness, remote), remote, answer[:outcome.answer_length])
	}
	if outcome.release_remote {
		append(&harness.released, remote)
	}
	return outcome
}

// harness_echo writes back on each record the bytes that it read, and the
// end of the stream after the end of the client.
harness_echo :: proc(harness: ^Harness) {
	for record, place in harness.records {
		if !record.in_use {
			continue
		}
		connection := &harness.connections[place]
		pending := harness.echo_pending[place][:]
		for {
			if harness.echo_start[place] < harness.echo_end[place] {
				harness.echo_start[place] += stream_write(connection, pending[harness.echo_start[place]:harness.echo_end[place]], false)
				if harness.echo_start[place] < harness.echo_end[place] {
					break
				}
			}
			harness.echo_start[place], harness.echo_end[place] = 0, 0
			count, finished, _ := stream_read(connection, pending)
			harness.echo_end[place] = count
			harness.echo_finished[place] = harness.echo_finished[place] || finished
			if count == 0 {
				break
			}
		}
		if harness.echo_finished[place] && harness.echo_start[place] == harness.echo_end[place] && !harness.echo_finish_written[place] {
			stream_write(connection, nil, true)
			harness.echo_finish_written[place] = true
		}
	}
}

// harness_step sends what each side has, delivers each datagram that is
// due, runs the timers, and moves the clock to the next event (1 ms at most).
harness_step :: proc(harness: ^Harness) {
	buffer: [MAX_DATAGRAM_SIZE]u8
	for &client, index in harness.clients {
		for _ in 0 ..< 64 {
			length := connection_datagram_send(&client, buffer[:], harness.now)
			if length == 0 {
				break
			}
			harness_send(harness, true, index, harness.client_remotes[index], buffer[:length])
		}
	}
	for _ in 0 ..< 256 {
		length, remote := server_datagram_send(&harness.server, buffer[:], harness.now)
		if length == 0 {
			break
		}
		harness_send(harness, false, harness_client_of(harness, remote), remote, buffer[:length])
	}
	clear(&harness.due)
	kept := 0
	for item in harness.queue {
		if item.deliver_at > harness.now {
			harness.queue[kept] = item
			kept += 1
		} else {
			append(&harness.due, item)
		}
	}
	resize(&harness.queue, kept)
	for &item in harness.due {
		bytes := item.bytes[:item.length]
		if item.to_server {
			harness_server_receive(harness, item.remote, bytes)
		} else if item.client >= 0 {
			error: errors.Error_Record
			connection_datagram_receive(&harness.clients[item.client], bytes, harness.now, &error)
		}
	}
	for &client in harness.clients {
		if connection_deadline(&client) <= harness.now {
			connection_time_passes(&client, harness.now)
		}
	}
	server_time_passes(&harness.server, harness.now)
	released: [HARNESS_RECORDS]Remote
	count := server_sweep(&harness.server, released[:])
	append(&harness.released, ..released[:count])
	harness.most_in_use = max(harness.most_in_use, server_connections_in_use(&harness.server))
	next := min(server_deadline(&harness.server), harness.now + 1000)
	for &client in harness.clients {
		next = min(next, connection_deadline(&client))
	}
	for item in harness.queue {
		next = min(next, item.deliver_at)
	}
	harness.now = max(harness.now + 1, next)
}

harness_was_released :: proc(harness: ^Harness, remote: Remote) -> bool {
	for item in harness.released {
		if item == remote {
			return true
		}
	}
	return false
}

// A datagram of 1200 random bytes shaped as an Initial of version 1, with a
// Destination Connection ID of 8 random bytes: no key opens it.
forged_initial :: proc(state: ^u64) -> [MAX_DATAGRAM_SIZE]u8 {
	forged: [MAX_DATAGRAM_SIZE]u8
	for &byte in forged {
		state^ ~= state^ << 13
		state^ ~= state^ >> 7
		state^ ~= state^ << 17
		byte = u8(state^)
	}
	forged[0] = LONG_HEADER_FORM | FIXED_BIT | u8(PACKET_NUMBER_SIZE - 1)
	forged[1], forged[2], forged[3], forged[4] = 0, 0, 0, 1
	forged[5] = CONNECTION_ID_SIZE
	forged[14] = 0
	forged[15] = 0
	variable_length_integer_write(forged[:], 16, MAX_DATAGRAM_SIZE - 18, 2)
	return forged
}

// An authentic Initial of 1200 bytes with a PING and no ClientHello, for a
// Destination Connection ID: anyone can make it, because its keys come from
// that identifier.
authentic_initial :: proc(cryptography: ^Cryptography, destination: [CONNECTION_ID_SIZE]u8) -> [MAX_DATAGRAM_SIZE]u8 {
	client_keys, server_keys: Packet_Keys
	error: errors.Error_Record
	identifier := destination
	initial_keys(cryptography, identifier[:], &client_keys, &server_keys, &error)
	datagram: [MAX_DATAGRAM_SIZE]u8
	at := 0
	datagram[at] = LONG_HEADER_FORM | FIXED_BIT | u8(PACKET_NUMBER_SIZE - 1)
	at += 1
	datagram[at], datagram[at + 1], datagram[at + 2], datagram[at + 3] = 0, 0, 0, 1
	at += 4
	datagram[at] = CONNECTION_ID_SIZE
	at += 1
	at += copy(datagram[at:], identifier[:])
	datagram[at] = 0 // An empty Source Connection ID.
	at += 1
	datagram[at] = 0 // An empty token.
	at += 1
	frames_length := MAX_DATAGRAM_SIZE - (at + 2 + PACKET_NUMBER_SIZE) - TAG_SIZE
	at += variable_length_integer_write(datagram[:], at, u64(PACKET_NUMBER_SIZE + frames_length + TAG_SIZE), 2)
	datagram[at + PACKET_NUMBER_SIZE] = FRAME_PING // Then PADDING: zeros.
	end, ok := packet_seal(cryptography, &client_keys, datagram[:], 0, at, frames_length, 0, &error)
	assert(ok && end == MAX_DATAGRAM_SIZE)
	return datagram
}

// harness_run steps until each client that did not vanish ended its echo,
// or the clock passed its limit. It gives the clients that ended.
harness_run :: proc(t: ^testing.T, harness: ^Harness, total: int, clock_limit: u64) -> int {
	written: [HARNESS_CLIENT_LIMIT]int
	read: [HARNESS_CLIENT_LIMIT]int
	finished: [HARNESS_CLIENT_LIMIT]bool
	chunk: [4096]u8
	end := harness.now + clock_limit
	for harness.now < end {
		done := 0
		for &client, index in harness.clients {
			if harness.vanished[index] {
				continue
			}
			for written[index] < total {
				count := min(len(chunk), total - written[index])
				for place in 0 ..< count {
					chunk[place] = pattern_byte(written[index] + place)
				}
				taken := stream_write(&client, chunk[:count], written[index] + count == total)
				written[index] += taken
				if taken < count {
					break
				}
			}
			for {
				count, ended, _ := stream_read(&client, chunk[:])
				for place in 0 ..< count {
					if chunk[place] != pattern_byte(read[index] + place) {
						testing.expectf(t, false, "client %d: the byte %d came back changed", index, read[index] + place)
						return done
					}
				}
				read[index] += count
				finished[index] = finished[index] || ended
				if count == 0 {
					break
				}
			}
			if finished[index] {
				done += 1
			}
		}
		active := 0
		for index in 0 ..< len(harness.clients) {
			if !harness.vanished[index] {
				active += 1
			}
		}
		if done == active {
			return done
		}
		harness_echo(harness)
		harness_step(harness)
	}
	done := 0
	for index in 0 ..< len(harness.clients) {
		if finished[index] {
			done += 1
		}
	}
	return done
}

// Eight clients at once, each from its own address, each with an echo of
// 64 KiB through one server.
@(test)
eight_clients_at_once :: proc(t: ^testing.T) {
	harness := harness_make(8)
	defer harness_free(harness)
	// Each client started: its generator took its seed.
	testing.expectf(t, harness.clients_not_started == 0, "%s", harness_describe(harness))
	ended := harness_run(t, harness, 64 * 1024, 60_000_000)
	testing.expectf(t, ended == 8, "%d clients ended their echo, not 8; %s", ended, harness_describe(harness))
	testing.expectf(t, harness.server.counters.accepted == 8, "%v, not %v; %s", harness.server.counters.accepted, 8, harness_describe(harness))
	testing.expectf(t, harness.most_in_use <= HARNESS_RECORDS, "%s", harness_describe(harness))
	for client in harness.clients {
		testing.expectf(t, client.state == Connection_State.Connected, "%v, not %v; %s", client.state, Connection_State.Connected, harness_describe(harness))
	}
}

// Eight clients of one address: at most 2 of them in the handshake at once.
// The others get no answer, try again at their probe timeout, and each one
// connects in the end.
@(test)
clients_of_one_address_wait_their_turn :: proc(t: ^testing.T) {
	harness := harness_make(8, 0x0A00_0399)
	defer harness_free(harness)
	// Each client started: its generator took its seed.
	testing.expectf(t, harness.clients_not_started == 0, "%s", harness_describe(harness))
	ended := harness_run(t, harness, 4096, 60_000_000)
	testing.expectf(t, ended == 8, "%d clients ended their echo, not 8; %s", ended, harness_describe(harness))
	testing.expectf(t, harness.server.counters.refused_remote_limit > 0, "%s", harness_describe(harness))
	testing.expectf(t, harness.server.counters.accepted == 8, "%v, not %v; %s", harness.server.counters.accepted, 8, harness_describe(harness))
}

// A flood: 1000 datagrams shaped as Initials, from 1000 addresses, which no
// key opens, and 5 authentic Initials (with no ClientHello) from each of 3
// addresses. No forged datagram takes a record, and each one has its remote
// released; the authentic ones take 2 records for each address, the limit
// of the handshakes of one address. Then the real client connects, and the
// handshake deadline frees the 6 records that wait.
@(test)
a_flood_of_forged_initials :: proc(t: ^testing.T) {
	harness := harness_make(1)
	defer harness_free(harness)
	// Each client started: its generator took its seed.
	testing.expectf(t, harness.clients_not_started == 0, "%s", harness_describe(harness))
	state: u64 = 0x464c_4f4f_4400_0001
	for index in 0 ..< 1000 {
		forged := forged_initial(&state)
		remote := Remote{u32(0x0B00_0000 + index), 40_000}
		outcome := harness_server_receive(harness, remote, forged[:])
		testing.expect(t, outcome.record < 0 && outcome.release_remote)
	}
	testing.expectf(t, harness.server.counters.not_authentic == 1000, "%v, not %v; %s", harness.server.counters.not_authentic, 1000, harness_describe(harness))
	testing.expectf(t, server_connections_in_use(&harness.server) == 0, "%v, not %v; %s", server_connections_in_use(&harness.server), 0, harness_describe(harness))
	for address in 0 ..< 3 {
		for index in 0 ..< 5 {
			identifier: [CONNECTION_ID_SIZE]u8
			identifier[0], identifier[1] = u8(address), u8(index)
			datagram := authentic_initial(&harness.cryptography, identifier)
			harness_server_receive(harness, {u32(0x0C00_0000 + address), u16(40_000 + index)}, datagram[:])
		}
	}
	testing.expectf(t, server_connections_in_use(&harness.server) == 6, "%v, not %v; %s", server_connections_in_use(&harness.server), 6, harness_describe(harness))
	testing.expectf(t, harness.server.counters.refused_remote_limit == 9, "%v, not %v; %s", harness.server.counters.refused_remote_limit, 9, harness_describe(harness))
	testing.expectf(t, harness.server.counters.authenticity_checks == 1015, "%v, not %v; %s", harness.server.counters.authenticity_checks, 1015, harness_describe(harness))
	start := harness.now
	ended := harness_run(t, harness, 4096, 30_000_000)
	testing.expectf(t, ended == 1, "%d clients ended their echo, not 1; %s", ended, harness_describe(harness))
	// The 6 records of the authentic flood end at the handshake deadline.
	for harness.now < start + 2 * HANDSHAKE_TIME_LIMIT && server_connections_in_use(&harness.server) > 1 {
		harness_step(harness)
	}
	testing.expectf(t, server_connections_in_use(&harness.server) == 1, "%v, not %v; %s", server_connections_in_use(&harness.server), 1, harness_describe(harness))
	testing.expectf(t, harness_was_released(harness, {0x0C00_0000, 40_000}), "%s", harness_describe(harness))
	testing.expectf(t, harness.most_in_use <= 7, "%s", harness_describe(harness))
}

// A client that vanishes after its first datagram: the handshake deadline
// ends its record, and its remote is released.
@(test)
a_client_that_vanishes_in_the_handshake :: proc(t: ^testing.T) {
	harness := harness_make(1)
	defer harness_free(harness)
	// Each client started: its generator took its seed.
	testing.expectf(t, harness.clients_not_started == 0, "%s", harness_describe(harness))
	harness_step(harness) // The first datagram of the client leaves.
	harness.vanished[0] = true
	for harness.now < 1_000_000 + 2 * HANDSHAKE_TIME_LIMIT && harness.server.counters.ended == 0 {
		harness_step(harness)
	}
	testing.expectf(t, harness.server.counters.accepted == 1, "%v, not %v; %s", harness.server.counters.accepted, 1, harness_describe(harness))
	testing.expectf(t, harness.server.counters.ended == 1, "%v, not %v; %s", harness.server.counters.ended, 1, harness_describe(harness))
	testing.expectf(t, server_connections_in_use(&harness.server) == 0, "%v, not %v; %s", server_connections_in_use(&harness.server), 0, harness_describe(harness))
	testing.expectf(t, harness_was_released(harness, harness.client_remotes[0]), "%s", harness_describe(harness))
	testing.expectf(t, harness.connections[0].closed_by_handshake_timeout, "%s", harness_describe(harness))
}

// A long header of another version, in 1200 bytes: one Version Negotiation
// packet, which lists version 1 and swaps the identifiers; 16 in one
// second at most; none for a datagram under 1200 bytes.
@(test)
version_negotiation_for_another_version :: proc(t: ^testing.T) {
	harness := harness_make(0)
	defer harness_free(harness)
	datagram: [MAX_DATAGRAM_SIZE]u8
	datagram[0] = LONG_HEADER_FORM | FIXED_BIT
	datagram[1], datagram[2], datagram[3], datagram[4] = 0xFF, 0x00, 0x00, 0x1D
	datagram[5] = 8
	copy(datagram[6:14], []u8{1, 1, 1, 1, 1, 1, 1, 1})
	datagram[14] = 8
	copy(datagram[15:23], []u8{2, 2, 2, 2, 2, 2, 2, 2})
	answer: [MAX_DATAGRAM_SIZE]u8
	outcome := server_datagram_receive(&harness.server, datagram[:], {0x0A00_0302, 40_000}, answer[:], harness.now)
	testing.expectf(t, outcome.answer_length == 27, "%v, not %v; %s", outcome.answer_length, 27, harness_describe(harness))
	testing.expectf(t, outcome.release_remote, "%s", harness_describe(harness))
	testing.expect_value(t, hex_of(answer[:27]), "800000000008020202020202020208010101010101010100000001")
	for _ in 0 ..< 20 {
		server_datagram_receive(&harness.server, datagram[:], {0x0A00_0302, 40_000}, answer[:], harness.now)
	}
	testing.expectf(t, harness.server.counters.version_negotiations == 16, "%v, not %v; %s", harness.server.counters.version_negotiations, 16, harness_describe(harness))
	testing.expectf(t, harness.server.counters.version_negotiations_dropped == 5, "%v, not %v; %s", harness.server.counters.version_negotiations_dropped, 5, harness_describe(harness))
	outcome = server_datagram_receive(&harness.server, datagram[:100], {0x0A00_0302, 40_000}, answer[:], harness.now + 2_000_000)
	testing.expectf(t, outcome.answer_length == 0, "%v, not %v; %s", outcome.answer_length, 0, harness_describe(harness))
}

// A datagram with the identifier of a connection, from another remote, does
// not reach the connection: a client of this server does not move.
@(test)
a_known_identifier_from_another_remote_is_dropped :: proc(t: ^testing.T) {
	harness := harness_make(1)
	defer harness_free(harness)
	// Each client started: its generator took its seed.
	testing.expectf(t, harness.clients_not_started == 0, "%s", harness_describe(harness))
	ended := harness_run(t, harness, 1024, 10_000_000)
	testing.expectf(t, ended == 1, "%d clients ended their echo, not 1; %s", ended, harness_describe(harness))
	client := &harness.clients[0]
	buffer: [MAX_DATAGRAM_SIZE]u8
	connection_close(client, 0, harness.now)
	length := connection_datagram_send(client, buffer[:], harness.now)
	testing.expectf(t, length > 0, "%s", harness_describe(harness))
	outcome := harness_server_receive(harness, {0x0A00_0399, 40_000}, buffer[:length])
	testing.expectf(t, outcome.record == -1, "%v, not %v; %s", outcome.record, -1, harness_describe(harness))
	testing.expectf(t, harness.server.counters.other_remote == 1, "%v, not %v; %s", harness.server.counters.other_remote, 1, harness_describe(harness))
	testing.expectf(t, harness.connections[0].state == Connection_State.Connected, "%v, not %v; %s", harness.connections[0].state, Connection_State.Connected, harness_describe(harness))
}
