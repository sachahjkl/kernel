// A QUIC echo server (docs/QUIC.md, section 6): QUIC in the program
// (support/quic), over a datagram endpoint with a listen grant of UDP. Each
// connection has one stream; the server writes back each byte that it
// reads, then ends the stream after the client ended it.
//
// What it can reach comes from its grants only (property 20):
//   a datagram endpoint with a listen grant: the UDP port 4433, and the
//       remotes that send a datagram of 1200 bytes to it;
//   the module cryptography, through its import slots.
//
// The key of the server: an Ed25519 key that this program makes at its
// start from its own generator (fill_for_a_key, the strength "processor" at
// least). Its public key goes on the log and in the window: a client pins
// it. The private key stays in the memory of this program; a new start
// makes a new key. A seed weaker than "processor" makes no key: the
// program says so in its window, and listens on nothing.
//
// main.odin: the endpoint, the server and the loop. draw.odin: the window.
package quic_echo

import "contract:datagram"
import "contract:errors"
import "contract:ring"
import "support:display"
import "support:network"
import "support:quic"
import "support:random"
import "support:system"

foreign _ {
	seal_with_chacha20_poly1305 :: proc "c" (key, nonce, additional, text: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	open_with_chacha20_poly1305 :: proc "c" (key, nonce, additional, sealed: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	seal_with_aes_128_gcm :: proc "c" (key, nonce, additional, text: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	open_with_aes_128_gcm :: proc "c" (key, nonce, additional, sealed: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	sha256 :: proc "c" (text: ^string, result: ^[]u8) -> i64 ---
	hmac_sha256 :: proc "c" (key, text: ^string, result: ^[]u8) -> i64 ---
	hkdf_sha256_extract :: proc "c" (salt, input: ^string, result: ^[]u8) -> i64 ---
	hkdf_sha256_expand :: proc "c" (key, info: ^string, length: i64, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	x25519 :: proc "c" (scalar, point: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	ed25519_public_key :: proc "c" (secret: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	ed25519_sign :: proc "c" (secret, message: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	ed25519_verify :: proc "c" (public, message, signature: ^string, error: ^errors.Error_Record) -> i64 ---
	header_protection_mask_with_aes_128 :: proc "c" (key, sample: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	header_protection_mask_with_chacha20 :: proc "c" (key, sample: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
}

CAPACITY :: 16 // Connections at one time.
// The memory of the connections and of their echo: one mapping of this
// program, never a stack (a connection has about 214 KiB).
CONNECTION_BYTES :: CAPACITY * size_of(quic.Connection)
ECHO_BYTES :: CAPACITY * quic.STREAM_BUFFER_SIZE
TABLE_PAGES :: (CONNECTION_BYTES + ECHO_BYTES + system.PAGE_SIZE - 1) / system.PAGE_SIZE
APPLICATION_PROTOCOL :: "kernel-remote"
IDLE_TIMEOUT_MILLISECONDS :: 30_000

// The datagram region: 256 places of 2048 bytes.
PLACE_SIZE :: 2048
PLACE_COUNT :: datagram.REGION_PAGES * system.PAGE_SIZE / PLACE_SIZE
RECEIVE_PLACES :: 96 // Places 0 to 95: datagrams that arrive. The others: datagrams to send.
SEND_TAG :: 1000 // Tags from 1000: a Send of place tag - 1000.
CALL_TAG :: 100_000 // Info and Release.
// Commands that the ring did not take: a Send or a Receive names one place,
// and a place is in one command at most; a Release follows a Send or a
// datagram that arrived, and the releases of one pass are at most the
// datagrams of the pass and the records that ended.
HELD_CAPACITY :: PLACE_COUNT + RECEIVE_PLACES + CAPACITY

LOG_LIMIT :: 50 // Lines of connections in one second at most: a client that opens many must not fill the log limit of the program.

cryptography := quic.Cryptography {
	seal_with_aes_128_gcm                = seal_with_aes_128_gcm,
	open_with_aes_128_gcm                = open_with_aes_128_gcm,
	seal_with_chacha20_poly1305          = seal_with_chacha20_poly1305,
	open_with_chacha20_poly1305          = open_with_chacha20_poly1305,
	hkdf_sha256_extract                  = hkdf_sha256_extract,
	hkdf_sha256_expand                   = hkdf_sha256_expand,
	header_protection_mask_with_aes_128  = header_protection_mask_with_aes_128,
	header_protection_mask_with_chacha20 = header_protection_mask_with_chacha20,
	sha256                               = sha256,
	hmac_sha256                          = hmac_sha256,
	x25519                               = x25519,
	ed25519_public_key                   = ed25519_public_key,
	ed25519_sign                         = ed25519_sign,
	ed25519_verify                       = ed25519_verify,
}

program_generator: random.Generator
server: quic.Server
records: [CAPACITY]quic.Server_Record
connections: []quic.Connection
echo_buffers: [][quic.STREAM_BUFFER_SIZE]u8
public_key: [32]u8
weak_seed: bool // The seed is weaker than "processor": no key, no endpoint.
listen_port: u16

// The echo of each record: the bytes read and not yet written back.
Echo :: struct {
	started_at:     u64, // The start of the record that this echo belongs to.
	start, end:     int,
	finished:       bool,
	finish_written: bool,
	logged:         bool,
}
echoes: [CAPACITY]Echo

endpoint: ring.Ring
region: []u8
free_places: [PLACE_COUNT - RECEIVE_PLACES]u32
free_count: int
held_commands: [HELD_CAPACITY]ring.Record
held_command_count: int
log_second: u64
log_count: u64
counters_logged: quic.Server_Counters
counters_second: u64

fail :: proc "contextless" (text: string) -> ! {
	system.log("quic_echo: ", text)
	system.stop(1)
}

now_microseconds :: proc "contextless" () -> u64 {
	return system.nanoseconds() / 1000
}

place_bytes :: proc "contextless" (place: u32) -> []u8 {
	return region[int(place) * PLACE_SIZE:][:PLACE_SIZE]
}

// command_push_or_hold puts a command in the ring. A full ring keeps it for
// the next pass: no place and no admitted remote leaks.
command_push_or_hold :: proc "contextless" (record: ring.Record) {
	if held_command_count == 0 && ring.push(&endpoint.commands, record) {
		return
	}
	if held_command_count == HELD_CAPACITY {
		fail("the held commands passed their bound")
	}
	held_commands[held_command_count] = record
	held_command_count += 1
}

held_commands_push :: proc "contextless" () {
	done := 0
	for done < held_command_count && ring.push(&endpoint.commands, held_commands[done]) {
		done += 1
	}
	copy(held_commands[:], held_commands[done:held_command_count])
	held_command_count -= done
}

post :: proc "contextless" (place: u32) {
	command_push_or_hold(ring.Record{kind = u32(datagram.Command.Receive), tag = place, values = {0 = u64(place) * PLACE_SIZE, 1 = PLACE_SIZE}})
}

send :: proc "contextless" (place: u32, length: int, remote: quic.Remote) {
	command_push_or_hold(ring.Record{kind = u32(datagram.Command.Send), tag = SEND_TAG + place, values = {0 = u64(place) * PLACE_SIZE, 1 = u64(length), 2 = u64(remote.address), 3 = u64(remote.port)}})
}

// release asks the network service to forget a remote: after the Sends to
// it, which the ring keeps in order.
release :: proc "contextless" (remote: quic.Remote) {
	command_push_or_hold(ring.Record{kind = u32(datagram.Command.Release), tag = CALL_TAG, values = {0 = u64(remote.address), 1 = u64(remote.port)}})
}

place_take :: proc "contextless" () -> (place: u32, ok: bool) {
	if free_count == 0 {
		return 0, false
	}
	free_count -= 1
	return free_places[free_count], true
}

address_text :: proc "contextless" (buffer: []u8, remote: quic.Remote) -> string {
	writer := system.Writer{buffer = buffer}
	network.address_write(&writer, remote.address)
	system.write_bytes(&writer, transmute([]u8)string(" port "))
	system.write_unsigned(&writer, u64(remote.port))
	return system.written(&writer)
}

hex_text :: proc "contextless" (buffer: []u8, bytes: []u8) -> string {
	digits := "0123456789abcdef"
	count := 0
	for byte in bytes {
		if count + 2 > len(buffer) {
			break
		}
		buffer[count], buffer[count + 1] = digits[byte >> 4], digits[byte & 0x0F]
		count += 2
	}
	return string(buffer[:count])
}

// log_allowed says if one more line of a connection goes on the log in this
// second.
log_allowed :: proc "contextless" () -> bool {
	second := system.time() / 1000
	if second != log_second {
		log_second, log_count = second, 0
	}
	log_count += 1
	return log_count <= LOG_LIMIT
}

end_reason :: proc "contextless" (connection: ^quic.Connection) -> string {
	switch {
	case connection.closed_by_handshake_timeout:
		return "the handshake deadline"
	case connection.closed_by_idle_timeout:
		return "the idle timeout"
	case connection.closed_by_peer:
		return "closed by the client"
	}
	return "closed by this server"
}

// echo_work writes back what each connection read, and logs each new
// connection and each end.
echo_work :: proc "contextless" () {
	for record, place in records {
		if !record.in_use {
			continue
		}
		echo := &echoes[place]
		if echo.started_at != record.started_at {
			echo^ = {started_at = record.started_at}
			if log_allowed() {
				text: [40]u8
				system.log("quic_echo: a connection from ", address_text(text[:], record.remote))
			}
		}
		connection := &connections[place]
		pending := echo_buffers[place][:]
		for {
			if echo.start < echo.end {
				echo.start += quic.stream_write(connection, pending[echo.start:echo.end], false)
				if echo.start < echo.end {
					break
				}
			}
			echo.start, echo.end = 0, 0
			count, finished, _ := quic.stream_read(connection, pending)
			echo.end = count
			echo.finished = echo.finished || finished
			if count == 0 {
				break
			}
		}
		if echo.finished && echo.start == echo.end && !echo.finish_written {
			quic.stream_write(connection, nil, true)
			echo.finish_written = true
		}
		if connection.state == .Closed && !echo.logged {
			echo.logged = true
			if log_allowed() {
				text: [40]u8
				system.log("quic_echo: ", address_text(text[:], record.remote), " ended (", end_reason(connection), "): in ", connection.stream.read_offset, " bytes, out ", connection.stream.send_length, " bytes, srtt ", connection.smoothed_round_trip, " us")
			}
		}
	}
}

// counters_log writes the counts of the server when they changed, once in
// a second at most: a flood is visible on the log in a few lines.
counters_log :: proc "contextless" () {
	second := system.time() / 1000
	if second == counters_second {
		return
	}
	counters := server.counters
	// The counts of each datagram change at each pass: they are in the
	// window, not on the log.
	counters.datagrams = counters_logged.datagrams
	counters.authenticity_checks = counters_logged.authenticity_checks
	if counters == counters_logged {
		return
	}
	counters_second = second
	counters_logged = server.counters
	system.log("quic_echo: accepted ", counters.accepted, ", ended ", counters.ended, ", not authentic ", counters.not_authentic, ", too small ", counters.too_small, ", refused by a limit ", counters.refused_remote_limit + counters.refused_handshake_limit, ", table full ", counters.refused_full, ", version negotiations ", counters.version_negotiations)
}

// exchange gives the server the datagrams that arrived, runs its timers,
// writes back the streams, and sends what the connections have.
exchange :: proc "contextless" (arrived: []ring.Record) -> (deadline: u64) {
	now := now_microseconds()
	for record in arrived {
		bytes := place_bytes(record.tag)[:min(record.values[1], PLACE_SIZE)]
		remote := quic.Remote{u32(record.values[2]), u16(record.values[3])}
		answer_place, has_place := place_take()
		answer: []u8
		if has_place {
			answer = place_bytes(answer_place)
		}
		outcome := quic.server_datagram_receive(&server, bytes, remote, answer, now)
		if outcome.answer_length > 0 {
			send(answer_place, outcome.answer_length, remote)
		} else if has_place {
			free_places[free_count] = answer_place
			free_count += 1
		}
		if outcome.release_remote {
			release(remote)
		}
	}
	quic.server_time_passes(&server, now)
	for round in 0 ..< 4 {
		echo_work()
		sent := 0
		for free_count > 0 {
			place, _ := place_take()
			length, remote := quic.server_datagram_send(&server, place_bytes(place), now)
			if length == 0 {
				free_places[free_count] = place
				free_count += 1
				break
			}
			send(place, length, remote)
			sent += 1
		}
		if sent == 0 {
			break
		}
		_ = round
	}
	ended: [CAPACITY]quic.Remote
	count := quic.server_sweep(&server, ended[:])
	for remote in ended[:count] {
		release(remote)
	}
	counters_log()
	return quic.server_deadline(&server)
}

// key_make makes the Ed25519 key of this server from the generator of the
// program, with the strength "processor" at least. false: the seed is
// weaker; nothing is made.
key_make :: proc "contextless" (configuration: ^quic.Connection_Configuration) -> bool {
	error: errors.Error_Record
	if !random.fill_for_a_key(&program_generator, configuration.tls.server_private_key[:], .Processor, &error) {
		return false
	}
	secret := string(configuration.tls.server_private_key[:])
	result := public_key[:]
	if ed25519_public_key(&secret, &result, &error) != 32 {
		fail("the module cryptography refused to make the public key")
	}
	return true
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	if !random.generator_from_context(&program_generator, ctx) {
		fail("no random seed in the context")
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, "quic_echo")
	if !ok {
		system.stop(1)
	}
	drawing_prepare()
	configuration := quic.Connection_Configuration{idle_timeout_milliseconds = IDLE_TIMEOUT_MILLISECONDS}
	configuration.tls = {role = .Server, least_seed_strength = .Processor}
	configuration.tls.application_protocol_length = copy(configuration.tls.application_protocol[:], APPLICATION_PROTOCOL)
	if !key_make(&configuration) {
		// The rule of the owner on a weak seed: the program chooses what it
		// accepts, and a seed under it is an error that it shows.
		weak_seed = true
		system.log("quic_echo: the random seed of this program is weak: it makes no key of a server, and listens on nothing")
		for {
			draw(&window)
			display.wait(&window, system.time() + 1000)
			for event in display.next_event(&window) {
				_ = event
			}
		}
	}
	text: [64]u8
	system.log("quic_echo: the public key of this server: ", hex_text(text[:], public_key[:]))
	status: system.Status
	if endpoint, status = system.ring_open(ctx.handles[datagram.GRANT_RING]); status != .Ok {
		fail("no endpoint: the program has no grant of the network")
	}
	address, map_status := system.memory_map(ctx.handles[datagram.GRANT_REGION], {.Write})
	if map_status != .Ok {
		fail("no datagram region")
	}
	region = ([^]u8)(address)[:datagram.REGION_PAGES * system.PAGE_SIZE]
	system.send(&endpoint.commands, ring.Record{kind = u32(datagram.Command.Info), tag = CALL_TAG})
	info: ring.Record
	for {
		record, has := system.receive(&endpoint.completions)
		if has {
			info = record
			break
		}
		wait: system.Wait
		system.wait_records(&wait, &endpoint.completions)
		system.wait_end(&wait, system.time() + 2000)
	}
	grant := datagram.grant_unpack(info.values[6])
	if grant.tcp || !grant.listen {
		fail("the grant is not a listen grant of UDP")
	}
	listen_port = grant.port
	// The connections and their echo: one mapping of this program.
	memory, memory_status := system.memory_create(TABLE_PAGES)
	table, table_status := system.memory_map(memory, {.Write})
	if memory_status != .Ok || table_status != .Ok {
		fail("no memory for the table of connections")
	}
	connections = ([^]quic.Connection)(table)[:CAPACITY]
	echo_buffers = ([^][quic.STREAM_BUFFER_SIZE]u8)(rawptr(uintptr(table) + CONNECTION_BYTES))[:CAPACITY]
	error: errors.Error_Record
	if !quic.server_init(&server, connections, records[:], &configuration, &cryptography, &program_generator, quic.SERVER_LIMITS_DEFAULT, &error) {
		fail("the server refused its configuration")
	}
	// The server keeps its own copy of the key.
	configuration.tls.server_private_key = {}
	for place in 0 ..< RECEIVE_PLACES {
		post(u32(place))
	}
	for place in RECEIVE_PLACES ..< PLACE_COUNT {
		free_places[free_count] = u32(place)
		free_count += 1
	}
	system.wake_reader(&endpoint.commands)
	system.log("quic_echo: listening on the UDP port ", u64(listen_port), ", a table of ", u64(CAPACITY), " connections of ", u64(size_of(quic.Connection) / 1024), " KiB, the key of this server from the generator of the program")

	arrived: [RECEIVE_PLACES]ring.Record
	last_draw: u64
	changed := true
	for {
		wait := system.wait_begin()
		held_commands_push()
		count := 0
		for record in system.receive(&endpoint.completions) {
			switch {
			case record.tag < RECEIVE_PLACES:
				if datagram.Status(record.kind) == .Ok {
					arrived[count] = record
					count += 1
				} else {
					post(record.tag)
				}
			case record.tag >= SEND_TAG && record.tag < SEND_TAG + PLACE_COUNT:
				free_places[free_count] = record.tag - SEND_TAG
				free_count += 1
			}
		}
		deadline := exchange(arrived[:count])
		// The places that the server read are free again: each record copied
		// its datagram.
		for record in arrived[:count] {
			post(record.tag)
		}
		system.wake_reader(&endpoint.commands)
		if count > 0 {
			changed = true
		}
		for event in display.next_event(&window) {
			_ = event
		}
		now := system.time()
		if changed && now - last_draw >= 100 {
			draw(&window)
			last_draw = now
			changed = false
		}
		if !ring.empty(&endpoint.completions) {
			continue
		}
		system.wait_records(&wait, &endpoint.completions)
		display.wait_events(&wait, &window)
		limit := changed ? last_draw + 100 : now + 1000
		if deadline != max(u64) {
			limit = min(limit, deadline / 1000 + 1)
		}
		system.wait_end(&wait, limit)
	}
}
