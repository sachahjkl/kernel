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
HARNESS_STREAMS :: 2 // The stream records of each record of the server and of each client.
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
	streams:              []Stream, // The stream records of the server.
	client_streams:       []Stream, // HARNESS_STREAMS records for each client, in the order of the clients.
	client_remotes:       [HARNESS_CLIENT_LIMIT]Remote,
	client_configuration: Connection_Configuration,
	vanished:             [HARNESS_CLIENT_LIMIT]bool, // A client whose datagrams are lost, both ways.
	queue:                [dynamic]Harness_Datagram,
	due:                  [dynamic]Harness_Datagram, // The datagrams of one step that are due: a delivery can add to the queue.
	now:                  u64,
	released:             [dynamic]Remote, // Each remote that the server asked to release.
	most_in_use:          int,
	clients_not_started:  int, // A client whose start failed: a fault of the harness, which the failure messages say.
	// The echo of each stream record of the server.
	stream_echoes:        []Server_Stream_Echo,
}

harness_make :: proc(client_count: int, client_address := u32(0)) -> ^Harness {
	harness := new(Harness)
	harness.cryptography = module_cryptography()
	harness.now = 1_000_000
	harness.connections = make([]Connection, HARNESS_RECORDS)
	harness.records = make([]Server_Record, HARNESS_RECORDS)
	harness.clients = make([]Connection, client_count)
	harness.streams = make([]Stream, HARNESS_RECORDS * HARNESS_STREAMS)
	harness.client_streams = make([]Stream, max(client_count, 1) * HARNESS_STREAMS)
	harness.stream_echoes = make([]Server_Stream_Echo, HARNESS_RECORDS * HARNESS_STREAMS)
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
	server_init(&harness.server, harness.connections, harness.records, harness.streams, &server_configuration, &harness.cryptography, &harness.server_generator, SERVER_LIMITS_DEFAULT, &error)
	for index in 0 ..< client_count {
		client_seed := harness_seed(u8(index))
		random.generator_seed(&harness.client_generators[index], &client_seed, .Processor)
		// One address for each client, unless the test gives one for all.
		address := client_address != 0 ? client_address : u32(0x0A00_0300 + index)
		harness.client_remotes[index] = {address, u16(50_000 + index)}
		if !connection_start_client(&harness.clients[index], harness_client_streams(harness, index), &harness.client_configuration, &harness.cryptography, &harness.client_generators[index], harness.now, &error) {
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
	text := fmt.tprintf("server: accepted %d, ended %d, datagrams %d, unreadable %d, Retries %d, tokens refused %d, tokens expired %d, not authentic %d, too small %d, refused by the limit of a remote %d, by the limit of the handshakes %d, table full %d, over the budget %d, over the budget of an address %d, no place in the table of address budgets %d, tokens used again %d, used tokens forgotten %d, from another remote %d, of no connection %d, version negotiations %d; records in use %d; clients that did not start %d; clients:", counters.accepted, counters.ended, counters.datagrams, counters.unreadable, counters.retries, counters.tokens_refused, counters.tokens_expired, counters.not_authentic, counters.too_small, counters.refused_remote_limit, counters.refused_handshake_limit, counters.refused_full, counters.over_budget, counters.over_address_budget, counters.address_table_full, counters.tokens_used_again, counters.used_tokens_forgotten, counters.other_remote, counters.no_connection, counters.version_negotiations, server_connections_in_use(&harness.server), harness.clients_not_started)
	for &client, index in harness.clients {
		text = fmt.tprintf("%s [%d: %v, a Retry taken %v, closed with %x, by the handshake deadline %v, by the idle timeout %v, %d bytes sent, %d received]", text, index, client.state, client.retried, client.close_error_code, client.closed_by_handshake_timeout, client.closed_by_idle_timeout, client.bytes_sent, client.bytes_received)
	}
	return text
}

harness_free :: proc(harness: ^Harness) {
	delete(harness.connections)
	delete(harness.records)
	delete(harness.clients)
	delete(harness.streams)
	delete(harness.client_streams)
	delete(harness.stream_echoes)
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

// harness_client_streams gives the stream records of a client.
harness_client_streams :: proc(harness: ^Harness, client: int) -> []Stream {
	return harness.client_streams[client * HARNESS_STREAMS:][:HARNESS_STREAMS]
}

// harness_echo writes back on each stream of each record the bytes that it
// read, and the end of the stream after the end of the client.
harness_echo :: proc(harness: ^Harness) {
	for record, place in harness.records {
		if record.in_use {
			server_streams_echo(&harness.connections[place], harness.stream_echoes[place * HARNESS_STREAMS:][:HARNESS_STREAMS])
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
authentic_initial :: proc(cryptography: ^Cryptography, destination: [CONNECTION_ID_SIZE]u8, token: []u8 = nil) -> [MAX_DATAGRAM_SIZE]u8 {
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
	at += variable_length_integer_write(datagram[:], at, u64(len(token)), variable_length_integer_size(u64(len(token))))
	at += copy(datagram[at:], token)
	frames_length := MAX_DATAGRAM_SIZE - (at + 2 + PACKET_NUMBER_SIZE) - TAG_SIZE
	at += variable_length_integer_write(datagram[:], at, u64(PACKET_NUMBER_SIZE + frames_length + TAG_SIZE), 2)
	datagram[at + PACKET_NUMBER_SIZE] = FRAME_PING // Then PADDING: zeros.
	end, ok := packet_seal(cryptography, &client_keys, datagram[:], 0, at, frames_length, 0, &error)
	assert(ok && end == MAX_DATAGRAM_SIZE)
	return datagram
}

// harness_run steps until each client that did not vanish ended its echo
// on a stream that it opens, or the clock passed its limit. It gives the
// clients that ended.
harness_run :: proc(t: ^testing.T, harness: ^Harness, total: int, clock_limit: u64) -> int {
	identifiers: [HARNESS_CLIENT_LIMIT]u64
	opened: [HARNESS_CLIENT_LIMIT]bool
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
			if !opened[index] {
				identifiers[index], opened[index] = stream_open(&client)
			}
			for opened[index] && written[index] < total {
				count := min(len(chunk), total - written[index])
				for place in 0 ..< count {
					chunk[place] = pattern_byte(written[index] + place)
				}
				taken := stream_write(&client, identifiers[index], chunk[:count], written[index] + count == total)
				written[index] += taken
				if taken < count {
					break
				}
			}
			for opened[index] {
				count, ended, _ := stream_read(&client, identifiers[index], chunk[:])
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
// key opens, and 15 authentic Initials from 3 addresses. None carries a
// token: each one gets a Retry, and none takes a record or costs the open
// of an Initial. Then the real client connects through its own Retry.
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
	for address in 0 ..< 3 {
		for index in 0 ..< 5 {
			identifier: [CONNECTION_ID_SIZE]u8
			identifier[0], identifier[1] = u8(address), u8(index)
			datagram := authentic_initial(&harness.cryptography, identifier)
			harness_server_receive(harness, {u32(0x0C00_0000 + address), u16(40_000 + index)}, datagram[:])
		}
	}
	testing.expectf(t, server_connections_in_use(&harness.server) == 0, "%s", harness_describe(harness))
	testing.expectf(t, harness.server.counters.retries == 1015, "%s", harness_describe(harness))
	testing.expectf(t, harness.server.counters.authenticity_checks == 0, "%s", harness_describe(harness))
	start := harness.now
	ended := harness_run(t, harness, 4096, 30_000_000)
	testing.expectf(t, ended == 1, "%d clients ended their echo, not 1; %s", ended, harness_describe(harness))
	testing.expectf(t, harness.server.counters.accepted == 1 && harness.most_in_use == 1, "%s", harness_describe(harness))
	testing.expectf(t, harness.now - start < 1_000_000, "the client connected after %d us; %s", harness.now - start, harness_describe(harness))
}

// A flood of authentic Initials from forged sources: 8 authentic Initials
// (anyone can make one), 2 from each of 4 forged addresses, every 10 s. Each one gets a Retry to its
// forged address, and no record. A real client that starts in the middle
// of it, 15 s in, at the time of a new round, connects at once. Before
// Retry, these 8 Initials held the 8 handshake places for ever.
@(test)
spoofed_authentic_initials_take_no_record :: proc(t: ^testing.T) {
	harness := harness_make(1)
	defer harness_free(harness)
	testing.expectf(t, harness.clients_not_started == 0, "%s", harness_describe(harness))
	// The client of harness_make waits: the real client starts later.
	harness.vanished[0] = true
	round := 0
	attack :: proc(harness: ^Harness, round: int) {
		for index in 0 ..< 8 {
			identifier: [CONNECTION_ID_SIZE]u8
			identifier[0], identifier[1] = u8(round), u8(index)
			datagram := authentic_initial(&harness.cryptography, identifier)
			harness_server_receive(harness, {u32(0x0D00_0000 + index / 2), u16(40_000 + index)}, datagram[:])
		}
	}
	start := harness.now
	for harness.now < start + 15_000_000 {
		if harness.now >= start + u64(round) * 10_000_000 {
			attack(harness, round)
			round += 1
		}
		harness_step(harness)
		testing.expectf(t, server_connections_in_use(&harness.server) == 0, "%s", harness_describe(harness))
	}
	harness.vanished[0] = false
	clear(&harness.queue)
	error: errors.Error_Record
	testing.expect(t, connection_start_client(&harness.clients[0], harness_client_streams(harness, 0), &harness.client_configuration, &harness.cryptography, &harness.client_generators[0], harness.now, &error))
	attack(harness, round)
	connected_at := harness.now
	ended := harness_run(t, harness, 4096, 30_000_000)
	testing.expectf(t, ended == 1, "%d clients ended their echo, not 1; %s", ended, harness_describe(harness))
	testing.expectf(t, harness.now - connected_at < 1_000_000, "the client ended its echo after %d us; %s", harness.now - connected_at, harness_describe(harness))
	testing.expectf(t, harness.server.counters.retries >= 24 && harness.server.counters.accepted == 1 && harness.most_in_use == 1, "%s", harness_describe(harness))
}

// A client that vanishes after it came back with its token: its record
// ends at the handshake deadline, and its remote is released.
@(test)
a_client_that_vanishes_in_the_handshake :: proc(t: ^testing.T) {
	harness := harness_make(1)
	defer harness_free(harness)
	testing.expectf(t, harness.clients_not_started == 0, "%s", harness_describe(harness))
	for harness.server.counters.accepted == 0 && harness.now < 1_000_000 + HANDSHAKE_TIME_LIMIT {
		harness_step(harness)
	}
	harness.vanished[0] = true
	clear(&harness.queue)
	for harness.now < 1_000_000 + 2 * HANDSHAKE_TIME_LIMIT && harness.server.counters.ended == 0 {
		harness_step(harness)
	}
	testing.expectf(t, harness.server.counters.retries == 1, "%s", harness_describe(harness))
	testing.expectf(t, harness.server.counters.accepted == 1, "%s", harness_describe(harness))
	testing.expectf(t, harness.server.counters.ended == 1, "%s", harness_describe(harness))
	testing.expectf(t, server_connections_in_use(&harness.server) == 0, "%s", harness_describe(harness))
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

// A client like the one of OpenSSL, whose own connection identifier has 0
// bytes, comes back after the Retry with its token and a real ClientHello
// whose transport parameters name that empty identifier. The client of this
// library always has 8 bytes, so the test writes the Initial itself. The
// server must take a record, keep the handshake going (the empty
// initial_source_connection_id matches the empty Source Connection ID of
// the packets), and send its first datagram to the empty identifier: an
// Initial and a Handshake packet, each with a Destination Connection ID of
// 0 bytes and the identifier of the record as its source, the Initial open
// with the keys of the identifier of the Retry, in 1200 bytes.
@(test)
a_handshake_with_a_client_with_an_empty_identifier :: proc(t: ^testing.T) {
	harness := harness_make(1)
	defer harness_free(harness)
	error: errors.Error_Record
	remote := Remote{0x0A00_0202, 42_000}
	// The first Initial, with no token: the answer is a Retry.
	first := authentic_initial(&harness.cryptography, {0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7})
	answer: [MAX_DATAGRAM_SIZE]u8
	outcome := server_datagram_receive(&harness.server, first[:], remote, answer[:], harness.now)
	if !testing.expectf(t, outcome.answer_length > 0 && outcome.record < 0, "%s", harness_describe(harness)) {
		return
	}
	retry := answer[:outcome.answer_length]
	retry_header: Packet_Header
	if !testing.expectf(t, header_read(retry, 0, 0, &retry_header, &error) && retry_header.type == .Retry, "%v", error) {
		return
	}
	retry_source := retry_header.source_connection_id[:retry_header.source_connection_id_length]
	testing.expect_value(t, len(retry_source), CONNECTION_ID_SIZE)
	token := retry[retry_header.token_offset:][:retry_header.token_length]
	// The ClientHello of a client whose transport parameters name an empty
	// identifier.
	parameters := transport_parameters_default()
	parameters.initial_max_data = STREAM_BUFFER_SIZE
	parameters.initial_max_stream_data_bidirectional_local = STREAM_BUFFER_SIZE
	parameters.initial_max_stream_data_bidirectional_remote = STREAM_BUFFER_SIZE
	parameters.has_initial_source_connection_id = true
	parameters.initial_source_connection_id_length = 0
	configuration := harness.client_configuration.tls
	configuration.transport_parameters_length = transport_parameters_write(&parameters, .Client, configuration.transport_parameters[:])
	testing.expect(t, configuration.transport_parameters_length > 0)
	client := new(Tls_Handshake)
	defer free(client)
	if !testing.expectf(t, tls_start(client, &configuration, &harness.cryptography, &harness.client_generators[0], &error), "%v", error) {
		return
	}
	hello := tls_bytes_to_send(client, .Initial)
	testing.expect(t, len(hello) > 0)
	// The Initial of the client: to the identifier of the Retry, from an
	// empty identifier, with the token, a CRYPTO frame with the ClientHello,
	// then PADDING to 1200 bytes.
	client_keys, server_keys: Packet_Keys
	testing.expect(t, initial_keys(&harness.cryptography, retry_source, &client_keys, &server_keys, &error))
	datagram: [MAX_DATAGRAM_SIZE]u8
	at := 0
	datagram[at] = LONG_HEADER_FORM | FIXED_BIT | u8(PACKET_NUMBER_SIZE - 1)
	at += 1
	datagram[at], datagram[at + 1], datagram[at + 2], datagram[at + 3] = 0, 0, 0, 1
	at += 4
	datagram[at] = u8(len(retry_source))
	at += 1
	at += copy(datagram[at:], retry_source)
	datagram[at] = 0 // The empty Source Connection ID.
	at += 1
	at += variable_length_integer_write(datagram[:], at, u64(len(token)), variable_length_integer_size(u64(len(token))))
	at += copy(datagram[at:], token)
	frames_length := MAX_DATAGRAM_SIZE - (at + 2 + PACKET_NUMBER_SIZE) - TAG_SIZE
	at += variable_length_integer_write(datagram[:], at, u64(PACKET_NUMBER_SIZE + frames_length + TAG_SIZE), 2)
	frames := datagram[at + PACKET_NUMBER_SIZE:][:frames_length]
	frames[0] = FRAME_CRYPTO
	frames[1] = 0 // The offset.
	written := 2 + variable_length_integer_write(frames, 2, u64(len(hello)), 2)
	copy(frames[written:], hello) // Then PADDING: zeros.
	end, sealed := packet_seal(&harness.cryptography, &client_keys, datagram[:], 0, at, frames_length, 1, &error)
	if !testing.expectf(t, sealed && end == MAX_DATAGRAM_SIZE, "%v", error) {
		return
	}
	outcome = server_datagram_receive(&harness.server, datagram[:], remote, answer[:], harness.now)
	if !testing.expectf(t, outcome.record >= 0, "%s", harness_describe(harness)) {
		return
	}
	connection := &harness.connections[outcome.record]
	testing.expectf(t, connection.state == .Handshake, "the record closed with the code %x, the frame type %x", connection.close_error_code, connection.close_frame_type)
	testing.expect_value(t, connection.peer_connection_id_length, 0)
	// The first datagram of the server.
	buffer: [MAX_DATAGRAM_SIZE]u8
	length, to := server_datagram_send(&harness.server, buffer[:], harness.now)
	testing.expect(t, to == remote)
	if !testing.expect_value(t, length, MAX_DATAGRAM_SIZE) {
		return
	}
	sent := buffer[:length]
	initial: Packet_Header
	if !testing.expectf(t, header_read(sent, 0, 0, &initial, &error), "%v", error) {
		return
	}
	testing.expect(t, initial.type == .Initial && initial.destination_connection_id_length == 0 && initial.token_length == 0)
	testing.expect_value(t, hex_of(initial.source_connection_id[:initial.source_connection_id_length]), hex_of(connection.local_connection_id[:]))
	handshake: Packet_Header
	if !testing.expectf(t, header_read(sent, initial.end, 0, &handshake, &error), "%v", error) {
		return
	}
	testing.expect(t, handshake.type == .Handshake && handshake.destination_connection_id_length == 0)
	testing.expect_value(t, hex_of(handshake.source_connection_id[:handshake.source_connection_id_length]), hex_of(connection.local_connection_id[:]))
	opened: Opened_Packet
	testing.expectf(t, packet_open(&harness.cryptography, &server_keys, sent, &initial, 0, &opened, &error), "%v", error)
	secret_erase(&client_keys, size_of(client_keys))
	secret_erase(&server_keys, size_of(server_keys))
}

// retry_of sends an authentic Initial with no token from a remote, and
// gives the token and the identifier of the Retry that answers it.
retry_of :: proc(harness: ^Harness, remote: Remote, identifier: [CONNECTION_ID_SIZE]u8) -> (token: [RETRY_TOKEN_SIZE]u8, retry_source: [CONNECTION_ID_SIZE]u8, ok: bool) {
	first := authentic_initial(&harness.cryptography, identifier)
	answer: [MAX_DATAGRAM_SIZE]u8
	outcome := server_datagram_receive(&harness.server, first[:], remote, answer[:], harness.now)
	error: errors.Error_Record
	header: Packet_Header
	if outcome.answer_length == 0 || !header_read(answer[:outcome.answer_length], 0, 0, &header, &error) || header.type != .Retry || header.token_length != RETRY_TOKEN_SIZE {
		return
	}
	copy(token[:], answer[header.token_offset:][:header.token_length])
	copy(retry_source[:], header.source_connection_id[:header.source_connection_id_length])
	return token, retry_source, true
}

// One host with a real address takes one Retry, then sends 500 Initials in
// each second with its valid token and the identifier of the Retry, each
// with a changed byte, so that none opens. They pass the token check, but
// the budget of Initial checks of that address refuses all of them after
// its 4 at once and 1 in each second, before any open: the shared budget
// is not spent. A real client that starts at the same time connects and
// ends its echo.
@(test)
one_address_with_a_valid_token_cannot_spend_the_budget_of_initial_checks :: proc(t: ^testing.T) {
	harness := harness_make(1)
	defer harness_free(harness)
	testing.expectf(t, harness.clients_not_started == 0, "%s", harness_describe(harness))
	attacker := Remote{0x0B00_0001, 40_000}
	token, retry_source, has_retry := retry_of(harness, attacker, {0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7})
	if !testing.expectf(t, has_retry, "%s", harness_describe(harness)) {
		return
	}
	garbage := authentic_initial(&harness.cryptography, retry_source, token[:])
	garbage[MAX_DATAGRAM_SIZE - 1] ~= 0x01 // The tag: the Initial does not open.
	start := harness.now
	next_attack := start
	attacks := 0
	for harness.now < start + 2_000_000 {
		for next_attack <= harness.now {
			harness_server_receive(harness, attacker, garbage[:])
			attacks += 1
			next_attack += 2000 // 500 in each second.
		}
		harness_echo(harness)
		harness_step(harness)
	}
	counters := harness.server.counters
	testing.expectf(t, attacks >= 1000, "%d Initials of the attacker", attacks)
	// 4 at once, then 1 in each second, for the attacker; the real client
	// needs one or a few.
	testing.expectf(t, counters.authenticity_checks <= 4 + 2 * 1 + 4, "%d Initial checks; %s", counters.authenticity_checks, harness_describe(harness))
	testing.expectf(t, counters.over_address_budget >= u64(attacks) - 4 - 2 * 1 - 1, "%s", harness_describe(harness))
	testing.expectf(t, counters.over_budget == 0, "%s", harness_describe(harness))
	testing.expectf(t, counters.accepted == 1 && harness.clients[0].state == .Connected, "the real client did not connect during the attack; %s", harness_describe(harness))
	ended := harness_run(t, harness, 4096, 10_000_000)
	testing.expectf(t, ended == 1, "%d clients ended their echo, not 1; %s", ended, harness_describe(harness))
}

// A token takes a record once: after its record ended, the same Initial
// with the same token, from the same remote and within the lifetime of the
// token, takes no record.
@(test)
a_token_takes_a_record_once :: proc(t: ^testing.T) {
	harness := harness_make(0)
	defer harness_free(harness)
	remote := Remote{0x0B00_0002, 40_001}
	token, retry_source, has_retry := retry_of(harness, remote, {0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7})
	if !testing.expectf(t, has_retry, "%s", harness_describe(harness)) {
		return
	}
	initial := authentic_initial(&harness.cryptography, retry_source, token[:])
	answer: [MAX_DATAGRAM_SIZE]u8
	outcome := server_datagram_receive(&harness.server, initial[:], remote, answer[:], harness.now)
	if !testing.expectf(t, outcome.record >= 0 && harness.server.counters.accepted == 1, "%s", harness_describe(harness)) {
		return
	}
	// The record ends.
	harness.connections[outcome.record].state = .Closed
	released: [HARNESS_RECORDS]Remote
	testing.expect_value(t, server_sweep(&harness.server, released[:]), 1)
	harness.now += 1000
	outcome = server_datagram_receive(&harness.server, initial[:], remote, answer[:], harness.now)
	testing.expectf(t, outcome.record < 0 && harness.server.counters.accepted == 1 && harness.server.counters.tokens_used_again == 1, "%s", harness_describe(harness))
	testing.expectf(t, harness.server.counters.authenticity_checks == 1, "%s", harness_describe(harness))
}

// Two datagrams of a client that came back with its token arrive in one
// batch, after a datagram of a known record. The order is decided once:
// the known datagram first, then both new ones; the first new one takes a
// record, and the second one goes to that record.
@(test)
two_datagrams_of_a_new_connection_in_one_batch :: proc(t: ^testing.T) {
	harness := harness_make(0)
	defer harness_free(harness)
	answer: [MAX_DATAGRAM_SIZE]u8
	known_remote := Remote{0x0B00_0003, 40_002}
	known_token, known_source, known_retry := retry_of(harness, known_remote, {0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7})
	new_remote := Remote{0x0B00_0004, 40_003}
	new_token, new_source, new_retry := retry_of(harness, new_remote, {0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7})
	if !testing.expectf(t, known_retry && new_retry, "%s", harness_describe(harness)) {
		return
	}
	known := authentic_initial(&harness.cryptography, known_source, known_token[:])
	outcome := server_datagram_receive(&harness.server, known[:], known_remote, answer[:], harness.now)
	testing.expect(t, outcome.record >= 0)
	first := authentic_initial(&harness.cryptography, new_source, new_token[:])
	second := first
	batch := []Server_Datagram{{first[:], new_remote}, {second[:], new_remote}, {known[:], known_remote}}
	order: [3]int
	testing.expect_value(t, server_batch_order(&harness.server, batch, order[:]), 3)
	testing.expect_value(t, order, [3]int{2, 0, 1})
	records: [3]int
	for index in order {
		records[index] = server_datagram_receive(&harness.server, batch[index].bytes, batch[index].remote, answer[:], harness.now).record
	}
	testing.expectf(t, records[0] >= 0 && records[1] == records[0] && records[2] != records[0], "the records of the batch: %v; %s", records, harness_describe(harness))
	testing.expectf(t, harness.server.counters.accepted == 2, "%s", harness_describe(harness))
}

// A record asks the caller to validate its remote at each datagram until
// the caller confirms it: a Validate that gave 0 (the network service had
// forgotten the remote) or a result for an older generation of the place
// confirms nothing.
@(test)
a_record_asks_for_its_validation_until_it_is_confirmed :: proc(t: ^testing.T) {
	harness := harness_make(0)
	defer harness_free(harness)
	remote := Remote{0x0B00_0005, 40_004}
	token, retry_source, has_retry := retry_of(harness, remote, {0xF0, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7})
	if !testing.expectf(t, has_retry, "%s", harness_describe(harness)) {
		return
	}
	initial := authentic_initial(&harness.cryptography, retry_source, token[:])
	answer: [MAX_DATAGRAM_SIZE]u8
	outcome := server_datagram_receive(&harness.server, initial[:], remote, answer[:], harness.now)
	if !testing.expect(t, outcome.record >= 0 && outcome.validate_remote) {
		return
	}
	place := outcome.record
	generation := harness.records[place].generation
	// Each next datagram of the record: the same Initial again.
	again :: proc(harness: ^Harness, initial: []u8, remote: Remote) -> Server_Outcome {
		answer: [MAX_DATAGRAM_SIZE]u8
		return server_datagram_receive(&harness.server, initial, remote, answer[:], harness.now)
	}
	testing.expect(t, again(harness, initial[:], remote).validate_remote)
	server_validation_confirmed(&harness.server, place, generation, false)
	testing.expect(t, again(harness, initial[:], remote).validate_remote)
	server_validation_confirmed(&harness.server, place, generation + 1, true)
	testing.expect(t, again(harness, initial[:], remote).validate_remote)
	server_validation_confirmed(&harness.server, place, generation, true)
	outcome = again(harness, initial[:], remote)
	testing.expect(t, outcome.record == place && !outcome.validate_remote)
}

// rotating_attack takes a token for each of address_count real addresses,
// then sends Initials with those tokens that do not open, from the
// addresses in turn, datagrams_per_second in all, for duration, while the
// harness runs. Client 0 starts with the attack. Client 1 waits, and starts
// late_start after the start of the attack. It gives the count of the
// Initials of the attack.
rotating_attack :: proc(t: ^testing.T, harness: ^Harness, address_count: int, datagrams_per_second: u64, duration: u64, late_start: u64) -> int {
	harness.vanished[1] = true
	garbage := make([][MAX_DATAGRAM_SIZE]u8, address_count)
	defer delete(garbage)
	for index in 0 ..< address_count {
		identifier: [CONNECTION_ID_SIZE]u8
		identifier[0], identifier[1], identifier[2] = 0x7A, u8(index >> 8), u8(index)
		remote := Remote{u32(0x0C00_0000 + index), 40_000}
		token, retry_source, has_retry := retry_of(harness, remote, identifier)
		if !testing.expectf(t, has_retry, "no Retry for the address %d; %s", index, harness_describe(harness)) {
			return 0
		}
		garbage[index] = authentic_initial(&harness.cryptography, retry_source, token[:])
		garbage[index][MAX_DATAGRAM_SIZE - 1] ~= 0x01 // The tag: the Initial does not open.
	}
	// The budget of Retries refills before the attack: the real clients
	// get their own Retry.
	harness.now += 200_000
	start := harness.now
	interval := 1_000_000 / datagrams_per_second
	next_attack := start
	attacks := 0
	late_started := false
	for harness.now < start + duration {
		if !late_started && harness.now >= start + late_start {
			late_started = true
			harness.vanished[1] = false
			error: errors.Error_Record
			testing.expect(t, connection_start_client(&harness.clients[1], harness_client_streams(harness, 1), &harness.client_configuration, &harness.cryptography, &harness.client_generators[1], harness.now, &error))
		}
		for next_attack <= harness.now {
			index := attacks % address_count
			harness_server_receive(harness, {u32(0x0C00_0000 + index), 40_000}, garbage[index][:])
			attacks += 1
			next_attack += interval
		}
		harness_echo(harness)
		harness_step(harness)
	}
	return attacks
}

// 33 real addresses, each with a valid token, send 2000 Initials a second
// in turn for 2 s, each one an Initial that does not open. Before, each
// address found its place taken by the 32 others since, took the place
// used the longest time ago with a full bucket, and spent the shared
// budget: every new client was dropped. Now a place moves only when its
// bucket is full again, so the 33 addresses get at most 33 buckets: 4
// checks at once and 1 in each second each. The shared budget is never
// spent, and a real client that starts with the attack and another that
// starts 1 s into it both connect during the attack.
@(test)
thirty_three_addresses_that_rotate_get_bounded_checks :: proc(t: ^testing.T) {
	harness := harness_make(2)
	defer harness_free(harness)
	testing.expectf(t, harness.clients_not_started == 0, "%s", harness_describe(harness))
	attacks := rotating_attack(t, harness, 33, 2000, 2_000_000, 1_000_000)
	counters := harness.server.counters
	testing.expectf(t, attacks >= 3900, "%d Initials of the attack", attacks)
	testing.expectf(t, counters.authenticity_checks <= 33 * (4 + 2) + 8, "%d Initial checks; %s", counters.authenticity_checks, harness_describe(harness))
	testing.expectf(t, counters.over_budget == 0 && counters.address_table_full == 0, "%s", harness_describe(harness))
	testing.expectf(t, counters.accepted == 2 && harness.clients[0].state == .Connected && harness.clients[1].state == .Connected, "the real clients did not connect during the attack; %s", harness_describe(harness))
	ended := harness_run(t, harness, 4096, 10_000_000)
	testing.expectf(t, ended == 2, "%d clients ended their echo, not 2; %s", ended, harness_describe(harness))
}

// 2000 real addresses, each with a valid token, send 2400 Initials a
// second in turn for 2 s: each address comes back every 0.83 s.
// - The bound: the table is 1024 buckets of 4 checks at once and 1 in each
//   second, so the checks of the 2 s are at most 1024 × 4 + 1024 × 2, and
//   each real client adds at most its own 4.
// - The first 1024 addresses take the places. Each one takes a check at
//   each visit, faster than its bucket refills, so its bucket never comes
//   back to its depth, and its place never moves while the attack lasts.
//   The other 976 addresses get no check (address_table_full).
// - A real client that starts with the attack takes a place before the
//   table is full, and connects. It then needs no more checks: its place
//   is full again 1 s after its one check, and a refused address of the
//   attack takes it within a millisecond, because those ask about 1200
//   times a second.
// - A real client that starts 1.5 s into the attack finds no place that
//   can move, and gets no check until the attack stops. The design gives a
//   new client no bound while more than 1024 real addresses keep the table:
//   it gets a place only when one frees and it asks before the attack does.
// - After the attack the places refill within 4 s, and that client connects.
@(test)
two_thousand_addresses_that_rotate_fill_the_table :: proc(t: ^testing.T) {
	harness := harness_make(2)
	defer harness_free(harness)
	testing.expectf(t, harness.clients_not_started == 0, "%s", harness_describe(harness))
	attacks := rotating_attack(t, harness, 2000, 2400, 2_000_000, 1_500_000)
	counters := harness.server.counters
	limits := SERVER_LIMITS_DEFAULT
	attack_seconds := 2
	bound := SERVER_ADDRESS_BUDGETS * (limits.initial_checks_per_address_depth + limits.initial_checks_per_address_per_second * attack_seconds) + 2 * limits.initial_checks_per_address_depth
	testing.expectf(t, attacks >= 4700, "%d Initials of the attack", attacks)
	testing.expectf(t, counters.authenticity_checks <= u64(bound), "%d Initial checks, over the bound %d; %s", counters.authenticity_checks, bound, harness_describe(harness))
	testing.expectf(t, counters.address_table_full > 0, "%s", harness_describe(harness))
	testing.expectf(t, harness.clients[0].state == .Connected, "the client that started with the attack did not connect; %s", harness_describe(harness))
	testing.expectf(t, harness.clients[1].state == .Handshake, "the client that started in the full table: %v; %s", harness.clients[1].state, harness_describe(harness))
	ended := harness_run(t, harness, 4096, 9_000_000)
	testing.expectf(t, ended == 2, "%d clients ended their echo, not 2; %s", ended, harness_describe(harness))
}
