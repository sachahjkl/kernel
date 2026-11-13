// A QUIC echo server (docs/QUIC.md, section 6): QUIC in the program
// (support/quic), over a datagram endpoint with a listen grant of UDP. A
// client opens up to STREAMS_PER_CONNECTION streams at one time; on each
// one the server writes back each byte that it reads, then ends the stream
// after the client ended it, or resets it after the client reset it.
//
// What it can reach comes from its grants only:
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
// **What it is for.** It is the test bench of the QUIC library on a real
// network path: the handshake of TLS 1.3, streams in both directions, Retry,
// the budgets of work against a hostile client, and the idle end. Its echo
// has no other use: the peer of the kernel tool writes a pattern on each
// stream and checks each byte that comes back. The service `remote` uses
// the same library and the same limits.
//
// **Start**: `start("quic_echo")` in the console, or the bar of the
// desktop. A client needs the public key from the log or the window.
//
// **Grants**, as the root service gives them:
//
// - **Network**: a listen grant of UDP on port 4433. The network service
//   admits a new remote only on a datagram of 1200 bytes or more, and holds
//   the limit of three times the bytes that came from it.
//
// It needs no other grant: the cryptography is the module `cryptography`,
// which the loader gives through the imports of this program.
//
// **What a reader sees**: a window with the key and the counts of the
// server. The log has "quic_echo: the public key of this server: ...",
// "quic_echo: listening on the UDP port 4433, ...", one line for each
// connection that starts and ends, a line on each idle end that says if it
// held its bound, and the counters of the server when they change: the
// connections accepted and ended, the Retries, the Initials refused by each
// limit, the datagrams over the budget.
//
// **What it does not prove**: the client is the peer of the kernel tool,
// not a QUIC stack of another project. 0-RTT and the migration of a
// connection are not built (docs/QUIC.md, section 9).
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
STREAMS_PER_CONNECTION :: 4 // The streams that one client may open at one time.
// The bytes that one stream read and did not write back yet: the echo
// writes them back before it reads more.
ECHO_BUFFER_SIZE :: 16384
// The memory of the connections, of their streams and of their echo: one
// mapping of this program, never a stack.
CONNECTION_BYTES :: CAPACITY * size_of(quic.Connection)
STREAM_BYTES :: CAPACITY * STREAMS_PER_CONNECTION * size_of(quic.Stream)
ECHO_BYTES :: CAPACITY * STREAMS_PER_CONNECTION * ECHO_BUFFER_SIZE
TABLE_PAGES :: (CONNECTION_BYTES + STREAM_BYTES + ECHO_BYTES + system.PAGE_SIZE - 1) / system.PAGE_SIZE
APPLICATION_PROTOCOL :: "kernel-remote"
IDLE_TIMEOUT_MILLISECONDS :: 30_000

// The datagram region: 256 places of 2048 bytes.
PLACE_SIZE :: 2048
PLACE_COUNT :: datagram.REGION_PAGES * system.PAGE_SIZE / PLACE_SIZE
RECEIVE_PLACES :: 96 // Places 0 to 95: datagrams that arrive. The others: datagrams to send.
SEND_TAG :: 1000 // Tags from 1000: a Send of place tag - 1000.
CALL_TAG :: 100_000 // Info and Release.
// The tag of a Validate: its top bit, the low 27 bits of the generation of
// the record, and the place of the record in the low 4 bits. A result that
// comes after its record ended and the place was taken again names the old
// generation, and confirms nothing: 2^27 records would have to be taken
// in one round of the ring for it to match.
VALIDATE_TAG :: u32(1) << 31
VALIDATE_PLACE_BITS :: 4
VALIDATE_GENERATION_MASK :: (u64(1) << (31 - VALIDATE_PLACE_BITS)) - 1
#assert(CAPACITY <= 1 << VALIDATE_PLACE_BITS)
// Commands that the ring did not take: a Send or a Receive names one place,
// and a place is in one command at most; a Release follows a Send or a
// datagram that arrived, and the releases of one pass are at most the
// datagrams of the pass and the records that ended.
// A Validate follows a datagram that arrived, as a Release does.
HELD_CAPACITY :: PLACE_COUNT + 2 * RECEIVE_PLACES + CAPACITY

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
streams: []quic.Stream
echo_buffers: [][ECHO_BUFFER_SIZE]u8
public_key: [32]u8
weak_seed: bool // The seed is weaker than "processor": no key, no endpoint.
listen_port: u16

// The echo of one stream: the bytes read and not yet written back.
Stream_Echo :: struct {
	active:         bool,
	identifier:     u64, // The stream of this echo: the stream record of the same place of the connection.
	start, end:     int,
	finished:       bool,
	finish_written: bool,
}

// The echo of each record.
Echo :: struct {
	generation: u64, // The generation of the record that this echo belongs to.
	logged:     bool,
	streams:    [STREAMS_PER_CONNECTION]Stream_Echo,
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
// The Sends that the network service refused (a remote no longer admitted,
// the limit of 3 times for a remote that is not validated), and the status
// of the last one: they are on the log with the counts.
sends_refused: u64
sends_refused_logged: u64
send_refusal_last: datagram.Status
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

// validate tells the network service that the remote of the record at
// place proved its address: it lifts the limit of 3 times the bytes that
// came from it. It goes before the Sends of the record, which the ring
// keeps in order. Its completion goes to the server
// (server_validation_confirmed) when the record of its tag is still the
// record of the place (validation_completed).
validate :: proc "contextless" (remote: quic.Remote, place: int) {
	tag := VALIDATE_TAG | u32(records[place].generation & VALIDATE_GENERATION_MASK) << VALIDATE_PLACE_BITS | u32(place)
	command_push_or_hold(ring.Record{kind = u32(datagram.Command.Validate), tag = tag, values = {0 = u64(remote.address), 1 = u64(remote.port)}})
}

// validation_completed gives the result of a Validate to the server, for
// the record that its tag names, if that record still holds the place.
validation_completed :: proc "contextless" (completion: ring.Record) {
	place := int(completion.tag & ((1 << VALIDATE_PLACE_BITS) - 1))
	generation_bits := u64(completion.tag & ~VALIDATE_TAG) >> VALIDATE_PLACE_BITS
	if place >= CAPACITY || !records[place].in_use || records[place].generation & VALIDATE_GENERATION_MASK != generation_bits {
		return
	}
	quic.server_validation_confirmed(&server, place, records[place].generation, datagram.Status(completion.kind) == .Ok && completion.values[0] == 1)
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

// idle_end_log writes how long a connection that ended by its idle timeout
// received nothing, in time of the machine, against its bound: at least
// its idle timeout. The line also gives its bound (the larger of the idle
// timeout and three probe timeouts with no backoff) and how late after it
// the end came: the program learns that the deadline passed when its wait
// ends, and how late a busy or slow machine wakes it depends on the host,
// so no verdict checks that side. A test reads the verdict; the numbers
// are on the line.
idle_end_log :: proc "contextless" (connection: ^quic.Connection, remote: quic.Remote) {
	silence := (connection.ended_at - min(connection.last_activity, connection.ended_at)) / 1000
	idle_timeout := connection.idle_timeout / 1000
	bound := quic.connection_idle_bound(connection) / 1000
	held := silence >= idle_timeout
	text: [40]u8
	system.log("quic_echo: ", address_text(text[:], remote), held ? ": the idle end held its bound: " : ": the idle end did NOT hold its bound: ", silence, " ms with no packet of the client, the idle timeout ", idle_timeout, " ms, the bound ", bound, " ms, ", silence - min(silence, bound), " ms after the bound")
}

// printable_text copies the bytes of a text of the network into place,
// each byte that is not printable ASCII as '?': a log line stays one line.
printable_text :: proc "contextless" (place: []u8, bytes: []u8) -> string {
	count := min(len(place), len(bytes))
	for index in 0 ..< count {
		character := bytes[index]
		place[index] = character >= 0x20 && character < 0x7F ? character : '?'
	}
	return string(place[:count])
}

// echo_work writes back what each connection read, and logs each new
// connection and each end.
echo_work :: proc "contextless" () {
	for record, place in records {
		if !record.in_use {
			continue
		}
		echo := &echoes[place]
		if echo.generation != record.generation {
			echo^ = {generation = record.generation}
			if log_allowed() {
				text: [40]u8
				system.log("quic_echo: a connection from ", address_text(text[:], record.remote))
			}
		}
		connection := &connections[place]
		// Each stream is read to its end, or to the reset of the client: a
		// stream record is freed only when the application read that end
		// (stream_read), so a stream left unread would keep its record, and
		// the client would get no stream in its place.
		for &stream, slot in connection.streams {
			stream_echo := &echo.streams[slot]
			if !stream.in_use {
				stream_echo.active = false
				continue
			}
			if !stream_echo.active || stream_echo.identifier != stream.identifier {
				stream_echo^ = {active = true, identifier = stream.identifier}
			}
			stream_echo_work(connection, stream_echo, echo_buffers[place * STREAMS_PER_CONNECTION + slot][:])
		}
		if connection.state == .Closed && !echo.logged {
			echo.logged = true
			if log_allowed() {
				text: [40]u8
				// The code, the frame type and the reason of the close tell
				// why a client of another stack failed: the code of a TLS
				// alert is 0x100 plus the alert.
				reason: [quic.CLOSE_REASON_KEPT]u8
				reason_text := printable_text(reason[:], connection.close_reason_of_peer[:connection.close_reason_of_peer_length])
				system.log("quic_echo: ", address_text(text[:], record.remote), " ended (", end_reason(connection), ", the code ", system.Hex(connection.close_error_code), connection.close_is_application ? " of the application" : "", ", the frame type ", system.Hex(connection.close_frame_type), ", the reason of the client \"", reason_text, "\"): in ", connection.data_consumed_total, " bytes, out ", connection.data_sent_total, " bytes, srtt ", connection.smoothed_round_trip, " us")
				if connection.closed_by_idle_timeout {
					idle_end_log(connection, record.remote)
				}
			}
		}
	}
}

// stream_echo_work writes back what one stream read, then its end; a
// stream that the client reset is reset with the same code.
stream_echo_work :: proc "contextless" (connection: ^quic.Connection, stream_echo: ^Stream_Echo, pending: []u8) {
	for {
		if stream_echo.start < stream_echo.end {
			stream_echo.start += quic.stream_write(connection, stream_echo.identifier, pending[stream_echo.start:stream_echo.end], false)
			if stream_echo.start < stream_echo.end {
				return
			}
		}
		stream_echo.start, stream_echo.end = 0, 0
		// The code of a reset of the client, before the read that can end
		// the stream.
		code: u64
		if stream := quic.stream_of(connection, stream_echo.identifier); stream != nil {
			code = stream.peer_reset_code
		}
		count, finished, reset := quic.stream_read(connection, stream_echo.identifier, pending)
		if reset {
			quic.stream_reset(connection, stream_echo.identifier, code)
			return
		}
		stream_echo.end = count
		stream_echo.finished = stream_echo.finished || finished
		if count == 0 {
			break
		}
	}
	if stream_echo.finished && stream_echo.start == stream_echo.end && !stream_echo.finish_written {
		quic.stream_write(connection, stream_echo.identifier, nil, true)
		stream_echo.finish_written = true
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
	if counters == counters_logged && sends_refused == sends_refused_logged {
		return
	}
	counters_second = second
	counters_logged = server.counters
	sends_refused_logged = sends_refused
	system.log("quic_echo: accepted ", counters.accepted, ", ended ", counters.ended, ", Retries ", counters.retries, ", tokens refused ", counters.tokens_refused + counters.tokens_expired, ", not authentic ", counters.not_authentic, ", too small ", counters.too_small, ", Initials refused by a limit (each try of a client counts) ", counters.refused_remote_limit + counters.refused_handshake_limit, ", Initials refused with a full table ", counters.refused_full, ", over the budget ", counters.over_budget, ", over the budget of an address ", counters.over_address_budget, ", new addresses with no place in the table of address budgets ", counters.address_table_full, ", tokens used again ", counters.tokens_used_again, ", version negotiations ", counters.version_negotiations, ", Sends refused by the network service ", sends_refused, " (the last status ", u64(send_refusal_last), ")")
}

// exchange gives the server the datagrams that arrived, runs its timers,
// writes back the streams, and sends what the connections have.
exchange :: proc "contextless" (arrived: []ring.Record) -> (deadline: u64) {
	now := now_microseconds()
	// The datagrams of known connections first: a flood of new identifiers
	// never makes them wait behind its cryptography. The order is decided
	// once for the batch, so each datagram is given once.
	batch: [RECEIVE_PLACES]quic.Server_Datagram
	for record, index in arrived {
		batch[index] = {place_bytes(record.tag)[:min(record.values[1], PLACE_SIZE)], quic.Remote{u32(record.values[2]), u16(record.values[3])}}
	}
	order: [RECEIVE_PLACES]int
	count := quic.server_batch_order(&server, batch[:len(arrived)], order[:])
	for index in order[:count] {
		bytes, remote := batch[index].bytes, batch[index].remote
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
		if outcome.validate_remote && outcome.record >= 0 {
			validate(remote, outcome.record)
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
	ended_count := quic.server_sweep(&server, ended[:])
	for remote in ended[:ended_count] {
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

// The entry of quic_echo: it makes its key, checks its grant, then runs the
// QUIC server until the machine stops.
//
// The entry, in order:
//
// 1. takes its random generator (with no seed it stops: `fail`) and opens
//    its window;
// 2. makes its Ed25519 key. With a seed under the strength "processor" it
//    writes "quic_echo: the random seed of this program is weak: ..." and
//    then only draws its window;
// 3. writes the public key on the log;
// 4. opens its endpoint and its datagram region, and asks the network
//    service for its grant; a grant that is not a listen grant of UDP stops
//    it;
// 5. maps the table of the connections and their streams, and starts the
//    QUIC server;
// 6. writes "quic_echo: listening on the UDP port 4433, ...".
//
// Then one loop runs for ever. Each pass gives the datagrams that arrived
// to the server, which echoes the bytes of each stream, and draws the
// window at most ten times in one second. It waits for a datagram, an event
// of the window, the next deadline of QUIC, or one second.
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
		// The rule on a weak seed: the program chooses what it
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
	streams = ([^]quic.Stream)(rawptr(uintptr(table) + CONNECTION_BYTES))[:CAPACITY * STREAMS_PER_CONNECTION]
	echo_buffers = ([^][ECHO_BUFFER_SIZE]u8)(rawptr(uintptr(table) + CONNECTION_BYTES + STREAM_BYTES))[:CAPACITY * STREAMS_PER_CONNECTION]
	error: errors.Error_Record
	if !quic.server_init(&server, connections, records[:], streams, &configuration, &cryptography, &program_generator, quic.SERVER_LIMITS_DEFAULT, &error) {
		fail("the server refused its configuration")
	}
	// The server keeps its own copy of the key. A plain store of zeros to a
	// record that is not read again can be removed by the compiler.
	quic.secret_erase(&configuration.tls.server_private_key, size_of(configuration.tls.server_private_key))
	for place in 0 ..< RECEIVE_PLACES {
		post(u32(place))
	}
	for place in RECEIVE_PLACES ..< PLACE_COUNT {
		free_places[free_count] = u32(place)
		free_count += 1
	}
	system.wake_reader(&endpoint.commands)
	system.log("quic_echo: listening on the UDP port ", u64(listen_port), ", a table of ", u64(CAPACITY), " connections of ", u64(size_of(quic.Connection) / 1024), " KiB, each with ", u64(STREAMS_PER_CONNECTION), " streams of ", u64(size_of(quic.Stream) / 1024), " KiB, the key of this server from the generator of the program")

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
			case record.tag & VALIDATE_TAG != 0:
				validation_completed(record)
			case record.tag >= SEND_TAG && record.tag < SEND_TAG + PLACE_COUNT:
				free_places[free_count] = record.tag - SEND_TAG
				free_count += 1
				if datagram.Status(record.kind) != .Ok {
					sends_refused += 1
					send_refusal_last = datagram.Status(record.kind)
				}
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
