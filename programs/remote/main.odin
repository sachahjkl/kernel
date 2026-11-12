// The remote service: the calls of the host (docs/MODULE_CONTRACT.md,
// section 4, "A call from the host"; docs/QUIC.md, section 7).
//
// QUIC in the program (support/quic), over a datagram endpoint with a
// listen grant of UDP on the port remote.LISTEN_PORT that admits the
// address of the host only (remote.HOST_ADDRESS): the network service drops
// a datagram of another address before this program sees it. Each call is
// one bidirectional stream: the request (a remote.Request header and the
// bytes of the call region), then the end of the stream; the answer (a
// remote.Answer header and the bytes of the result), then the end of the
// stream. A call that fails before its answer is reset with a code of
// remote.Stream_Error.
//
// The key of the service: an Ed25519 key that this program makes at its
// start from its own generator (fill_for_a_key, the strength "processor" at
// least). Its public key goes on the log and in the window: the host pins
// it. A new start makes a new key. A seed weaker than "processor" makes no
// key: the program says so, and listens on nothing.
//
// It holds a ring to the root service that serves Connect and Disconnect
// only, to the services that the root service names for it. It copies the
// bytes of a whole request in the call region of its connection to the
// service, makes the isolated call, and writes the call answer. It does not
// read the descriptions: the host encoded the call with them, and the
// service checks the call region. It trusts nothing in a request
// (remote.request_check).
//
// The window shows the public key, the counts of the calls and of the
// resets, the connections to services, and the last calls.
package remote_service

import "base:intrinsics"
import "contract:datagram"
import "contract:errors"
import "contract:isolated"
import "contract:remote"
import "contract:ring"
import "support:display"
import "support:interface"
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

// The QUIC connections and their calls: remote.CONNECTION_CAPACITY records,
// each with remote.CALLS_AT_ONCE stream records, and one buffer for each
// stream, which holds its request, then its answer.
CAPACITY :: remote.CONNECTION_CAPACITY
STREAMS_PER_CONNECTION :: remote.CALLS_AT_ONCE
CALL_COUNT :: CAPACITY * STREAMS_PER_CONNECTION
CALL_BUFFER_SIZE :: remote.ANSWER_LIMIT
#assert(remote.REQUEST_LIMIT <= CALL_BUFFER_SIZE)
// The memory of the connections, of their streams and of their buffers: one
// mapping of this program, never a stack.
CONNECTION_BYTES :: CAPACITY * size_of(quic.Connection)
STREAM_BYTES :: CALL_COUNT * size_of(quic.Stream)
BUFFER_BYTES :: CALL_COUNT * CALL_BUFFER_SIZE
TABLE_PAGES :: (CONNECTION_BYTES + STREAM_BYTES + BUFFER_BYTES + system.PAGE_SIZE - 1) / system.PAGE_SIZE
IDLE_TIMEOUT_MILLISECONDS :: 30_000

// The bounds of a call stream, in milliseconds of the machine. Each one
// starts again at each phase of the call (Call.phase_started_at), and the
// wait of the loop ends at the nearest one (calls_deadline).
// A request must be whole (its last byte and the end of its stream) this
// long after its stream came; else the stream is reset with Timeout.
REQUEST_TIME_LIMIT :: 10_000
// The host must take the whole answer (each byte and the end acknowledged)
// this long after the call ended; else the stream is reset with Timeout.
ANSWER_TIME_LIMIT :: 10_000
// After this side reset a stream, the host must end its own direction this
// long after; else the connection ends (CONNECTION_CLOSE, Timeout): a
// stream record that the host never ends would hold one call of the 8.
RELEASE_TIME_LIMIT :: 10_000
// The time that the program may see a deadline after it passed: it learns
// it when its wait ends, and a busy or slow machine, or an isolated call
// (CALL_LIMIT), wakes it late. A log line of a bound says "held" when the
// time is at least the bound and at most the bound and this margin.
LATE_WAKE_MILLISECONDS :: 5000

// The datagram region: 256 places of 2048 bytes.
PLACE_SIZE :: 2048
PLACE_COUNT :: datagram.REGION_PAGES * system.PAGE_SIZE / PLACE_SIZE
RECEIVE_PLACES :: 64 // Places 0 to 63: datagrams that arrive. The others: datagrams to send.
SEND_TAG :: 1000 // Tags from 1000: a Send of place tag - 1000.
CALL_TAG :: 100_000 // Info and Release.
// The tag of a Validate: its top bit, the low 27 bits of the generation of
// the record, and the place of the record in the low 4 bits (as quic_echo).
VALIDATE_TAG :: u32(1) << 31
VALIDATE_PLACE_BITS :: 4
VALIDATE_GENERATION_MASK :: (u64(1) << (31 - VALIDATE_PLACE_BITS)) - 1
#assert(CAPACITY <= 1 << VALIDATE_PLACE_BITS)
// Commands that the ring did not take: a Send or a Receive names one place,
// and a place is in one command at most; a Release or a Validate follows a
// datagram that arrived, or a record that ended.
HELD_CAPACITY :: PLACE_COUNT + 2 * RECEIVE_PLACES + CAPACITY

CALL_LIMIT :: 5000 // Milliseconds: an isolated call that takes longer ends the connection to its service.
CONNECT_LIMIT :: 10_000 // Milliseconds for the root service to make a connection: it can start the service first.
LOG_REFUSALS :: 16 // The refusals that this program writes on the log; it counts the others.
LOG_LIMIT :: 50 // Lines of connections and of streams in one second at most: a host that opens many must not fill the log limit of the program.

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
quic_connections: []quic.Connection
streams: []quic.Stream
call_buffers: [][CALL_BUFFER_SIZE]u8
public_key: [32]u8
weak_seed: bool // The seed is weaker than "processor": no key, no endpoint.
listen_port: u16

// The phases of one call stream. A record of a stream frees when the host
// read the end of this side and this side read the end of the host
// (support/quic, stream_read); the call place is then empty again.
Call_Phase :: enum u8 {
	None, // No stream in this place.
	Reading, // The request comes. Bound: REQUEST_TIME_LIMIT.
	Waiting, // The request is whole: it waits for its turn. One isolated call runs at a time, in the order in which the requests became whole.
	Answering, // The answer goes, as the stream buffer takes it, then the end of the stream. Bound: ANSWER_TIME_LIMIT.
	Discarding, // This side reset the stream: it drops what comes, until the end of the host. Bound: RELEASE_TIME_LIMIT.
}

Call :: struct {
	phase:            Call_Phase,
	identifier:       u64, // The stream.
	generation:       u64, // The generation of the record: a stream of an earlier client of the place is another call.
	received:         int, // The bytes of the request in the buffer.
	answer_length:    int,
	answer_written:   int, // The bytes of the answer that the stream took.
	phase_started_at: u64, // Milliseconds of the machine: the start of the bound of the phase.
	order:            u64, // The turn of a whole request.
}
calls: [CALL_COUNT]Call
next_order: u64

// What this program logged of each record.
Record_Log :: struct {
	generation: u64,
	end_logged: bool,
}
record_logs: [CAPACITY]Record_Log

// A connection to one service: the root service made it.
Service_Connection :: struct {
	name:          [32]u8, // Empty: the place is free.
	program:       system.Handle, // The service, with the right Read: its state.
	ring_memory:   system.Handle,
	region_memory: system.Handle,
	calls:         ring.Ring,
	region:        []u8,
	hash:          [32]u8, // The hash of the module file of the service.
	tag:           u32,
	count:         u64, // The calls through this connection.
}

SERVICE_CONNECTION_CAPACITY :: 8 // The services of callable_of("remote") in the root service, and room for more.

service_connections: [SERVICE_CONNECTION_CAPACITY]Service_Connection

// The counts that the window shows.
Counts :: struct {
	requests:    u64, // The whole requests.
	calls:       u64, // The isolated calls that ran.
	failed:      u64, // The calls whose export gave a negative result with an error record.
	refused:     u64, // The requests that this program refused with its error record.
	too_large:   u64, // Streams reset with Too_Large.
	timeouts:    u64, // Streams reset with Timeout.
	cancelled:   u64, // Calls that the host gave up before their turn.
	closed_held: u64, // Connections that this program closed for a stream that the host did not end.
	bytes_in:    u64, // The bytes of whole requests.
	bytes_out:   u64, // The bytes of answers.
	sends_refused: u64, // Sends that the network service refused.
}
counts: Counts

// The last calls, for the window.
Recent :: struct {
	service:      [32]u8,
	export:       u32,
	status:       remote.Status,
	call_status:  u32,
	text:         [96]u8, // A refusal: the sentence of its error record.
	text_count:   int,
	value:        i64,
	error:        i64, // The kind of the error record, or 0.
	bytes:        u64,
	microseconds: u64,
}
RECENT_CAPACITY :: 8
recent: [RECENT_CAPACITY]Recent
recent_count: u64

endpoint: ring.Ring
region: []u8
requests: ring.Ring // To the root service.
request_tag: u32
draw_logged: bool
free_places: [PLACE_COUNT - RECEIVE_PLACES]u32
free_count: int
held_commands: [HELD_CAPACITY]ring.Record
held_command_count: int
log_second: u64
log_count: u64

fail :: proc "contextless" (text: string) -> ! {
	system.log("remote: ", text)
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

send :: proc "contextless" (place: u32, length: int, peer: quic.Remote) {
	command_push_or_hold(ring.Record{kind = u32(datagram.Command.Send), tag = SEND_TAG + place, values = {0 = u64(place) * PLACE_SIZE, 1 = u64(length), 2 = u64(peer.address), 3 = u64(peer.port)}})
}

// validate tells the network service that the remote of the record at
// place proved its address (a token of its Retry): it lifts the limit of 3
// times the bytes that came from it. It goes before the Sends of the
// record, which the ring keeps in order.
validate :: proc "contextless" (peer: quic.Remote, place: int) {
	tag := VALIDATE_TAG | u32(records[place].generation & VALIDATE_GENERATION_MASK) << VALIDATE_PLACE_BITS | u32(place)
	command_push_or_hold(ring.Record{kind = u32(datagram.Command.Validate), tag = tag, values = {0 = u64(peer.address), 1 = u64(peer.port)}})
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
release :: proc "contextless" (peer: quic.Remote) {
	command_push_or_hold(ring.Record{kind = u32(datagram.Command.Release), tag = CALL_TAG, values = {0 = u64(peer.address), 1 = u64(peer.port)}})
}

place_take :: proc "contextless" () -> (place: u32, ok: bool) {
	if free_count == 0 {
		return 0, false
	}
	free_count -= 1
	return free_places[free_count], true
}

address_text :: proc "contextless" (buffer: []u8, peer: quic.Remote) -> string {
	writer := system.Writer{buffer = buffer}
	network.address_write(&writer, peer.address)
	system.write_bytes(&writer, transmute([]u8)string(" port "))
	system.write_unsigned(&writer, u64(peer.port))
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

// log_allowed says if one more line of a connection or of a stream goes on
// the log in this second.
log_allowed :: proc "contextless" () -> bool {
	second := system.time() / 1000
	if second != log_second {
		log_second, log_count = second, 0
	}
	log_count += 1
	return log_count <= LOG_LIMIT
}

// bound_verdict gives the words of a log line of a bound: held when the
// time is at least the bound and at most the bound and a late wake.
bound_verdict :: proc "contextless" (elapsed, bound: u64) -> string {
	if elapsed >= bound && elapsed <= bound + LATE_WAKE_MILLISECONDS {
		return "held"
	}
	return "did NOT hold"
}

end_reason :: proc "contextless" (connection: ^quic.Connection) -> string {
	switch {
	case connection.closed_by_handshake_timeout:
		return "the handshake deadline"
	case connection.closed_by_idle_timeout:
		return "the idle timeout"
	case connection.closed_by_peer:
		return "closed by the host"
	}
	return "closed by this service"
}

// idle_end_log writes how long a connection that ended by its idle timeout
// received nothing, in time of the machine, against its bound: at least
// its idle timeout, and at most its bound and a late wake of the program.
// A test reads the verdict; the numbers are on the line.
idle_end_log :: proc "contextless" (connection: ^quic.Connection, peer: quic.Remote) {
	silence := (connection.ended_at - min(connection.last_activity, connection.ended_at)) / 1000
	idle_timeout := connection.idle_timeout / 1000
	bound := quic.connection_idle_bound(connection) / 1000
	held := silence >= idle_timeout && silence <= bound + LATE_WAKE_MILLISECONDS
	text: [40]u8
	system.log("remote: ", address_text(text[:], peer), held ? ": the idle end held its bound: " : ": the idle end did NOT hold its bound: ", silence, " ms with no packet of the host, the idle timeout ", idle_timeout, " ms, the bound ", bound, " ms, a late wake of the program up to ", u64(LATE_WAKE_MILLISECONDS), " ms")
}

// stream_refuse ends a call stream with a code: STOP_SENDING (the host stops
// its request, when it did not end it) and RESET_STREAM. The place then
// drops what still comes, until the end of the host.
stream_refuse :: proc "contextless" (connection: ^quic.Connection, call: ^Call, code: remote.Stream_Error, now: u64) {
	quic.stream_stop_sending(connection, call.identifier, u64(code))
	quic.stream_reset(connection, call.identifier, u64(code))
	call.phase = .Discarding
	call.phase_started_at = now
}

// call_work moves one call stream: it reads the request, writes the answer,
// and applies the bound of the phase.
call_work :: proc "contextless" (connection: ^quic.Connection, peer: quic.Remote, call: ^Call, buffer: []u8, now: u64) {
	text: [40]u8
	elapsed := now - min(call.phase_started_at, now)
	switch call.phase {
	case .None, .Waiting:
	case .Reading:
		for {
			// The buffer holds REQUEST_LIMIT bytes; one byte more is read into
			// a place of its own, and makes the request Too_Large.
			count: int
			finished, reset: bool
			if call.received < remote.REQUEST_LIMIT {
				count, finished, reset = quic.stream_read(connection, call.identifier, buffer[call.received:remote.REQUEST_LIMIT])
			} else {
				one_more: [1]u8
				count, finished, reset = quic.stream_read(connection, call.identifier, one_more[:])
			}
			if reset {
				// The host gave up its request: no call. This side ends its
				// own direction, and the record frees.
				quic.stream_reset(connection, call.identifier, u64(remote.Stream_Error.Cancelled))
				call.phase = .Discarding
				call.phase_started_at = now
				counts.cancelled += 1
				return
			}
			call.received += count
			switch remote.stream_progress(u64(call.received), finished, remote.REQUEST_LIMIT) {
			case .Too_Large:
				stream_refuse(connection, call, .Too_Large, now)
				counts.too_large += 1
				if log_allowed() {
					system.log("remote: ", address_text(text[:], peer), ", the stream ", call.identifier, ": a request of more than ", u64(remote.REQUEST_LIMIT), " bytes: reset with the code Too_Large, and no call")
				}
				return
			case .Complete:
				call.phase = .Waiting
				call.order = next_order
				next_order += 1
				return
			case .Waiting:
			}
			if count == 0 {
				break
			}
		}
		if elapsed >= REQUEST_TIME_LIMIT {
			stream_refuse(connection, call, .Timeout, now)
			counts.timeouts += 1
			if log_allowed() {
				system.log("remote: ", address_text(text[:], peer), ", the stream ", call.identifier, ": no whole request in ", u64(REQUEST_TIME_LIMIT), " ms (", u64(call.received), " bytes came): reset with the code Timeout after ", elapsed, " ms of the machine; the bound of a request ", bound_verdict(elapsed, REQUEST_TIME_LIMIT))
			}
		}
	case .Answering:
		if call.answer_written < call.answer_length {
			call.answer_written += quic.stream_write(connection, call.identifier, buffer[call.answer_written:call.answer_length], true)
		}
		if elapsed >= ANSWER_TIME_LIMIT {
			stream_refuse(connection, call, .Timeout, now)
			counts.timeouts += 1
			if log_allowed() {
				system.log("remote: ", address_text(text[:], peer), ", the stream ", call.identifier, ": the host did not take the answer in ", u64(ANSWER_TIME_LIMIT), " ms (", u64(call.answer_written), " of ", u64(call.answer_length), " bytes in the stream): reset with the code Timeout after ", elapsed, " ms of the machine; the bound of an answer ", bound_verdict(elapsed, ANSWER_TIME_LIMIT))
			}
		}
	case .Discarding:
		for {
			dropped: [4096]u8
			count, _, _ := quic.stream_read(connection, call.identifier, dropped[:])
			if count == 0 {
				break
			}
		}
		if elapsed >= RELEASE_TIME_LIMIT {
			if connection.state == .Connected {
				quic.connection_close(connection, u64(remote.Stream_Error.Timeout), now_microseconds())
				counts.closed_held += 1
				if log_allowed() {
					system.log("remote: ", address_text(text[:], peer), ", the stream ", call.identifier, ": the host did not end it ", u64(RELEASE_TIME_LIMIT), " ms after its reset: the connection ends with the code Timeout after ", elapsed, " ms of the machine")
				}
			}
			// The connection ends by its closing state; the next bound is
			// later, so that the wait of the loop does not end at once until
			// the record is free.
			call.phase_started_at = now
		}
	}
}

// calls_work moves each call stream of each record, and logs each new
// connection and each end.
calls_work :: proc "contextless" () {
	now := system.time()
	for record, place in records {
		place_calls := calls[place * STREAMS_PER_CONNECTION:][:STREAMS_PER_CONNECTION]
		if !record.in_use {
			for &call in place_calls {
				call = {}
			}
			continue
		}
		text: [40]u8
		record_log := &record_logs[place]
		if record_log.generation != record.generation {
			record_log^ = {generation = record.generation}
			if log_allowed() {
				system.log("remote: a connection from ", address_text(text[:], record.remote))
			}
		}
		connection := &quic_connections[place]
		// Each stream is read to its end, or to the reset of the host: a
		// stream record is freed only when this program read that end
		// (quic.stream_read), so a stream left unread would keep its record,
		// and the host would get no stream in its place.
		for &stream, slot in connection.streams {
			call := &place_calls[slot]
			if !stream.in_use {
				call^ = {}
				continue
			}
			if call.phase == .None || call.identifier != stream.identifier || call.generation != record.generation {
				call^ = {phase = .Reading, identifier = stream.identifier, generation = record.generation, phase_started_at = now}
			}
			call_work(connection, record.remote, call, call_buffers[place * STREAMS_PER_CONNECTION + slot][:], now)
		}
		if connection.state == .Closed && !record_log.end_logged {
			record_log.end_logged = true
			if log_allowed() {
				system.log("remote: ", address_text(text[:], record.remote), " ended (", end_reason(connection), ", the code ", system.Hex(connection.close_error_code), connection.close_is_application ? " of the application" : "", "): in ", connection.data_consumed_total, " bytes, out ", connection.data_sent_total, " bytes")
				if connection.closed_by_idle_timeout {
					idle_end_log(connection, record.remote)
				}
			}
		}
	}
}

// calls_deadline gives the nearest bound of a call, in milliseconds of the
// machine, or max(u64).
calls_deadline :: proc "contextless" () -> u64 {
	deadline := max(u64)
	for &call in calls {
		bound: u64
		switch call.phase {
		case .None, .Waiting:
			continue
		case .Reading:
			bound = REQUEST_TIME_LIMIT
		case .Answering:
			bound = ANSWER_TIME_LIMIT
		case .Discarding:
			bound = RELEASE_TIME_LIMIT
		}
		deadline = min(deadline, call.phase_started_at + bound)
	}
	return deadline
}

// exchange gives the server the datagrams that arrived, runs its timers,
// moves the calls, and sends what the connections have.
exchange :: proc "contextless" (arrived: []ring.Record) -> (deadline: u64) {
	now := now_microseconds()
	// The datagrams of known connections first, as quic_echo: the order is
	// decided once for the batch, so each datagram is given once.
	batch: [RECEIVE_PLACES]quic.Server_Datagram
	for record, index in arrived {
		batch[index] = {place_bytes(record.tag)[:min(record.values[1], PLACE_SIZE)], quic.Remote{u32(record.values[2]), u16(record.values[3])}}
	}
	order: [RECEIVE_PLACES]int
	count := quic.server_batch_order(&server, batch[:len(arrived)], order[:])
	for index in order[:count] {
		bytes, peer := batch[index].bytes, batch[index].remote
		answer_place, has_place := place_take()
		answer: []u8
		if has_place {
			answer = place_bytes(answer_place)
		}
		outcome := quic.server_datagram_receive(&server, bytes, peer, answer, now)
		if outcome.answer_length > 0 {
			send(answer_place, outcome.answer_length, peer)
		} else if has_place {
			free_places[free_count] = answer_place
			free_count += 1
		}
		if outcome.validate_remote && outcome.record >= 0 {
			validate(peer, outcome.record)
		}
		if outcome.release_remote {
			release(peer)
		}
	}
	quic.server_time_passes(&server, now)
	for _ in 0 ..< 4 {
		calls_work()
		sent := 0
		for free_count > 0 {
			place, _ := place_take()
			length, peer := quic.server_datagram_send(&server, place_bytes(place), now)
			if length == 0 {
				free_places[free_count] = place
				free_count += 1
				break
			}
			send(place, length, peer)
			sent += 1
		}
		if sent == 0 {
			break
		}
	}
	ended: [CAPACITY]quic.Remote
	ended_count := quic.server_sweep(&server, ended[:])
	for peer in ended[:ended_count] {
		release(peer)
	}
	return quic.server_deadline(&server)
}

// serve_next makes the isolated call of the request that became whole
// first, and puts its answer in the buffer of its stream. false: no request
// waits.
serve_next :: proc "contextless" () -> bool {
	chosen := -1
	for &call, index in calls {
		if call.phase == .Waiting && (chosen < 0 || call.order < calls[chosen].order) {
			chosen = index
		}
	}
	if chosen < 0 {
		return false
	}
	call := &calls[chosen]
	place := chosen / STREAMS_PER_CONNECTION
	connection := &quic_connections[place]
	stream := quic.stream_of(connection, call.identifier)
	if stream == nil || !records[place].in_use || records[place].generation != call.generation {
		call^ = {}
		return true
	}
	if stream.reset_received || stream.reset_sent {
		// The host gave up the call before its turn (a reset, or a
		// STOP_SENDING): no call.
		quic.stream_reset(connection, call.identifier, u64(remote.Stream_Error.Cancelled))
		call.phase = .Discarding
		call.phase_started_at = system.time()
		counts.cancelled += 1
		return true
	}
	call.answer_length = serve(call_buffers[chosen][:], call.received)
	call.answer_written = 0
	call.phase = .Answering
	// The bound of the answer starts when the answer exists: the time of
	// the isolated call is bounded by CALL_LIMIT.
	call.phase_started_at = system.time()
	return true
}

// answer_put writes an answer in the buffer of a stream, and gives its
// length.
answer_put :: proc "contextless" (buffer: []u8, header: remote.Answer, result: []u8) -> int {
	bytes, written := remote.answer_write(buffer, header, result)
	if !written {
		// A result is cut to the call region, and the buffer holds an answer
		// of a whole call region: this does not happen.
		bytes, _ = remote.answer_write(buffer, header, nil)
	}
	counts.bytes_out += u64(len(bytes))
	return len(bytes)
}

// refuse answers a request that this program refused, and writes the
// sentence of its error record on the log while the log has room for it.
refuse :: proc "contextless" (buffer: []u8, error: errors.Error_Record, service: string = "", hash: [32]u8 = {}) -> int {
	counts.refused += 1
	error := error
	// One sentence, for the log and for the window.
	sentence: [256]u8
	writer := system.Writer{buffer = sentence[:]}
	field := ""
	if error.argument >= 1 && error.argument <= len(remote.REQUEST_FIELD_NAMES) {
		field = remote.REQUEST_FIELD_NAMES[error.argument - 1]
	}
	system.error_text(&writer, &error, "remote", field)
	if counts.refused <= LOG_REFUSALS {
		if counts.refused == LOG_REFUSALS {
			system.log("remote: refused a request: ", system.written(&writer), "; the next refusals are counted only")
		} else {
			system.log("remote: refused a request: ", system.written(&writer))
		}
	}
	answer := remote.Answer{status = .Refused, error = error, hash = hash}
	item := recent_add(service, 0, answer, 0, 0)
	item.text_count = copy(item.text[:], system.written(&writer))
	return answer_put(buffer, answer, nil)
}

recent_add :: proc "contextless" (service: string, export: u32, answer: remote.Answer, bytes: u64, microseconds: u64) -> ^Recent {
	item := &recent[recent_count % RECENT_CAPACITY]
	item^ = {export = export, status = answer.status, call_status = answer.call_status, value = answer.value, error = answer.error.kind, bytes = bytes, microseconds = microseconds}
	copy(item.service[:len(item.service) - 1], service)
	recent_count += 1
	return item
}

// connection_find gives the connection to a service, and asks the root
// service for one when this program has none. On a failure it gives the
// error record of the answer.
connection_find :: proc "contextless" (name: string) -> (connection: ^Service_Connection, error: errors.Error_Record) {
	free: ^Service_Connection
	for &item in service_connections {
		if item.name[0] == 0 {
			free = &item
		} else if remote.name_text(&item.name) == name {
			return &item, {}
		}
	}
	if free == nil {
		return nil, errors.error_make(.Full, .None, remote.FIELD_SERVICE, 0, SERVICE_CONNECTION_CAPACITY)
	}
	packed := system.name_pack(name)
	request_tag += 1
	if !system.send(&requests.commands, ring.Record{kind = u32(system.Root_Command.Connect), tag = request_tag, values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}}) {
		return nil, errors.error_make(.Refused, .None, remote.FIELD_SERVICE, 0, 0, i64(system.Status.No_Slot))
	}
	limit := system.time() + CONNECT_LIMIT
	for {
		for record in system.receive(&requests.completions) {
			if record.tag != request_tag {
				continue
			}
			status := system.Status(record.kind)
			#partial switch status {
			case .Ok:
			case .Bad_Handle:
				// No service runs with this name.
				return nil, errors.error_make(.Absent, .None, remote.FIELD_SERVICE)
			case .No_Right:
				return nil, errors.error_make(.No_Grant, .Connection, remote.FIELD_SERVICE)
			case:
				return nil, errors.error_make(.Refused, .None, remote.FIELD_SERVICE, 0, 0, i64(status))
			}
			connection = free
			connection^ = {
				program       = system.Handle(record.values[0]),
				ring_memory   = system.Handle(record.values[1]),
				region_memory = system.Handle(record.values[2]),
				hash          = transmute([32]u8)[4]u64{record.values[3], record.values[4], record.values[5], record.values[6]},
			}
			copy(connection.name[:len(connection.name) - 1], name)
			ring_status: system.Status
			connection.calls, ring_status = system.ring_open(connection.ring_memory)
			address, map_status := system.memory_map(connection.region_memory)
			if ring_status != .Ok || map_status != .Ok {
				connection_end(connection, false)
				return nil, errors.error_make(.Refused, .None, remote.FIELD_SERVICE, 0, 0, i64(ring_status != .Ok ? ring_status : map_status))
			}
			connection.region = ([^]u8)(address)[:system.memory_size(connection.region_memory) * system.PAGE_SIZE]
			system.log("remote: connected to the service ", name)
			return connection, {}
		}
		wait: system.Wait
		system.wait_records(&wait, &requests.completions)
		if system.wait_end(&wait, limit) >= limit {
			return nil, errors.error_make(.Over_Limit, .Milliseconds, remote.FIELD_SERVICE, CONNECT_LIMIT, CONNECT_LIMIT)
		}
	}
}

// connection_end closes what this program holds of a connection to a
// service. tell: ask the root service to end it too (the service still
// runs).
connection_end :: proc "contextless" (connection: ^Service_Connection, tell: bool) {
	if tell {
		packed := system.name_pack(remote.name_text(&connection.name))
		request_tag += 1
		system.send(&requests.commands, ring.Record{kind = u32(system.Root_Command.Disconnect), tag = request_tag, values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}})
	}
	if connection.calls.head != nil {
		system.ring_close(&connection.calls)
	}
	if connection.region != nil {
		system.memory_unmap(raw_data(connection.region))
	}
	for handle in ([3]system.Handle{connection.program, connection.ring_memory, connection.region_memory}) {
		if handle != 0 {
			system.close(handle)
		}
	}
	connection^ = {}
}

// isolated_call_make makes the isolated call of a request through a
// connection, and gives the completion. On a failure of the connection it gives an error record.
// While it waits, this program runs no QUIC: an isolated call is bounded by
// CALL_LIMIT, and a peer of QUIC sends again what it does not see
// acknowledged.
isolated_call_make :: proc "contextless" (connection: ^Service_Connection, request: remote.Request, arguments: []u8) -> (completion: ring.Record, error: errors.Error_Record, ok: bool) {
	// The bytes after the arguments are zero: a request that names a place
	// of the result reads no byte of a call before it.
	copied := copy(connection.region, arguments)
	if copied < len(connection.region) {
		intrinsics.mem_zero(raw_data(connection.region[copied:]), len(connection.region) - copied)
	}
	connection.tag += 1
	if !system.send(&connection.calls.commands, ring.Record{kind = request.export, tag = connection.tag, values = {0 = 0, 1 = u64(request.record_size)}}) {
		return {}, errors.error_make(.Full, .Records, 0, 0, i64(ring.capacity(&connection.calls.commands))), false
	}
	start := system.time()
	limit := start + CALL_LIMIT
	for {
		// The stop of the service is an event of this thread.
		wait := system.wait_begin()
		for _ in 0 ..< ring.CAPACITY {
			record, has := system.receive(&connection.calls.completions)
			if !has {
				break
			}
			if record.tag == connection.tag {
				return record, {}, true
			}
		}
		if state, _ := system.program_state(connection.program); state == .Stopped || state == .None {
			system.log("remote: the service ", remote.name_text(&connection.name), " stopped during a call")
			connection_end(connection, false)
			return {}, errors.error_make(.State, .None, remote.FIELD_SERVICE, 0, 0, i64(state)), false
		}
		system.wait_records(&wait, &connection.calls.completions)
		if system.wait_spin(&wait) {
			continue
		}
		if now := system.wait_end(&wait, limit); now >= limit {
			system.log("remote: the service ", remote.name_text(&connection.name), " did not answer in ", u64(CALL_LIMIT), " ms: the connection ends")
			connection_end(connection, true)
			return {}, errors.error_make(.Over_Limit, .Milliseconds, remote.FIELD_EXPORT, i64(now - start), CALL_LIMIT), false
		}
	}
}

// serve reads one whole request in the buffer of its stream, makes the
// call, and writes the answer in the same buffer: the request is copied
// into the call region before the answer is written. It gives the length
// of the answer.
serve :: proc "contextless" (buffer: []u8, received: int) -> int {
	counts.requests += 1
	counts.bytes_in += u64(received)
	start := system.nanoseconds()
	request, arguments, error, ok := remote.request_check(buffer[:received], remote.REGION_SIZE)
	if !ok {
		return refuse(buffer, error)
	}
	service := remote.name_text(&request.service)
	connection, connection_error := connection_find(service)
	if connection == nil {
		return refuse(buffer, connection_error, service)
	}
	if connection.hash != request.hash {
		return refuse(buffer, errors.error_make(.Bad_Value, .None, remote.FIELD_HASH), service, connection.hash)
	}
	if u64(len(connection.region)) < remote.REGION_SIZE {
		return refuse(buffer, errors.error_make(.Too_Small, .Bytes, remote.FIELD_SERVICE, i64(len(connection.region)), remote.REGION_SIZE), service, connection.hash)
	}
	completion, call_error, called := isolated_call_make(connection, request, arguments)
	if !called {
		return refuse(buffer, call_error, service, connection.hash)
	}
	connection.count += 1
	counts.calls += 1
	answer := remote.Answer {
		status      = .Ok,
		call_status = completion.kind,
		value       = i64(completion.values[0]),
		hash        = connection.hash,
	}
	result: []u8
	if isolated.Status(completion.kind) == .Ok {
		if request.error_start != 0 && answer.value < 0 {
			// The service wrote it: values only, copied as values.
			answer.error = (^errors.Error_Record)(raw_data(connection.region[request.error_start:]))^
			counts.failed += 1
			// The bytes of a failed call are its error details.
			details, details_count := remote.details_bytes(request, connection.region[:remote.REGION_SIZE])
			answer.details = u32(min(details_count, u64(max(u32))))
			result = details
		} else {
			result = connection.region[request.result_start:][:remote.result_bytes(request, answer.value)]
		}
	}
	length := answer_put(buffer, answer, result)
	recent_add(service, request.export, answer, u64(len(result)), (system.nanoseconds() - start) / 1000)
	return length
}

// key_make makes the Ed25519 key of this service from the generator of the
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
	window, has_window := display.open(ctx, WIDTH, HEIGHT, "remote")
	configuration := quic.Connection_Configuration{idle_timeout_milliseconds = IDLE_TIMEOUT_MILLISECONDS}
	configuration.tls = {role = .Server, least_seed_strength = .Processor}
	configuration.tls.application_protocol_length = copy(configuration.tls.application_protocol[:], remote.APPLICATION_PROTOCOL)
	if !key_make(&configuration) {
		// A seed under the least strength is an error that the program
		// shows: no key, and no endpoint.
		weak_seed = true
		system.log("remote: the random seed of this program is weak: it makes no key, and listens on nothing")
		for {
			if has_window {
				draw(&window)
				display.wait(&window, system.time() + 1000)
				for event in display.next_event(&window) {
					_ = event
				}
			} else {
				wait: system.Wait
				system.wait_end(&wait, system.time() + 1000)
			}
		}
	}
	key_text: [64]u8
	system.log("remote: the public key of this service: ", hex_text(key_text[:], public_key[:]))
	status: system.Status
	if endpoint, status = system.ring_open(ctx.handles[datagram.GRANT_RING]); status != .Ok {
		fail("no endpoint: the program has no grant of the network")
	}
	address, map_status := system.memory_map(ctx.handles[datagram.GRANT_REGION], {.Write})
	if map_status != .Ok || system.memory_size(ctx.handles[datagram.GRANT_REGION]) < datagram.REGION_PAGES {
		fail("no datagram region")
	}
	region = ([^]u8)(address)[:datagram.REGION_PAGES * system.PAGE_SIZE]
	if requests, status = system.ring_open(ctx.handles[system.GRANT_ROOT]); status != .Ok {
		fail("no ring to the root service")
	}
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
	if grant.tcp || !grant.listen || grant.address != remote.HOST_ADDRESS {
		// The rule of who may call is the grant: a listen grant that admits
		// each address would let any machine of the network call as the
		// person.
		fail("the grant is not a listen grant of UDP for the address of the host only")
	}
	listen_port = grant.port
	// The connections, their streams and their buffers: one mapping.
	memory, memory_status := system.memory_create(TABLE_PAGES)
	table, table_status := system.memory_map(memory, {.Write})
	if memory_status != .Ok || table_status != .Ok {
		fail("no memory for the table of connections")
	}
	quic_connections = ([^]quic.Connection)(table)[:CAPACITY]
	streams = ([^]quic.Stream)(rawptr(uintptr(table) + CONNECTION_BYTES))[:CALL_COUNT]
	call_buffers = ([^][CALL_BUFFER_SIZE]u8)(rawptr(uintptr(table) + CONNECTION_BYTES + STREAM_BYTES))[:CALL_COUNT]
	// The limits of quic_echo, for a table of 2 records: one address (the
	// host) may hold both, in the handshake too.
	limits := quic.SERVER_LIMITS_DEFAULT
	limits.connections_per_remote_address = CAPACITY
	limits.handshakes_per_remote_address = CAPACITY
	limits.handshakes_at_once = CAPACITY
	error: errors.Error_Record
	if !quic.server_init(&server, quic_connections, records[:], streams, &configuration, &cryptography, &program_generator, limits, &error) {
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
	system.log("remote: listening on the UDP port ", u64(listen_port), ", for the host 10.0.2.2 only: ", u64(CAPACITY), " connections, each with ", u64(STREAMS_PER_CONNECTION), " calls at one time")

	arrived: [RECEIVE_PLACES]ring.Record
	drawn: u64
	dirty := true
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
					counts.sends_refused += 1
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
			dirty = true
		}
		// One isolated call in each pass: the datagrams of the connections
		// move between two calls.
		served := serve_next()
		if served {
			dirty = true
		}
		now := system.time()
		if has_window {
			interface.window_events(&drawing, &window)
			// The window changes at most ten times in one second: a burst of
			// calls does not wait for the drawing.
			if dirty && now - drawn >= 100 {
				start := system.nanoseconds()
				draw(&window)
				drawn, dirty = now, false
				// The time of one picture, one time, when the window has calls
				// to show (docs/DESIGN.md, section 7).
				if !draw_logged && counts.calls >= 1000 {
					draw_logged = true
					system.log("remote: the window drew one picture in ", (system.nanoseconds() - start) / 1000, " us")
					system.log("remote: the interface: ", u64(drawing.now.record_count), " records, ", u64(drawing.damage.count), " damage rectangles; build ", drawing.build_time / 1000, " us, difference ", drawing.difference_time / 1000, " us, draw ", drawing.draw_time / 1000, " us")
				}
			}
		}
		if served || !ring.empty(&endpoint.completions) {
			// The answer goes at once: the next pass writes it in its stream.
			continue
		}
		system.wait_records(&wait, &endpoint.completions)
		if has_window {
			display.wait_events(&wait, &window)
		}
		if system.wait_spin(&wait) {
			continue
		}
		limit := dirty && has_window ? drawn + 100 : system.WAIT_FOREVER
		if deadline != max(u64) {
			limit = min(limit, deadline / 1000 + 1)
		}
		limit = min(limit, calls_deadline())
		system.wait_end(&wait, limit)
	}
}
