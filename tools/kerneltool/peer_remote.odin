package kerneltool

import "contract:errors"
import "contract:remote"
import "core:encoding/hex"
import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:sync"
import "core:time"
import "support:quic"
import "support:random"
import cryptography_module "../../modules/cryptography"

// The peer as the QUIC client of the remote service (docs/QUIC.md,
// section 7). The thread of the peer holds one connection to `remote` and
// carries each call on its own bidirectional stream: the request, then the
// end of the stream; the answer, up to the end of the stream of `remote`.
// It pins the public key that the machine printed (step Remote_Key), or the
// key that a call of the host names (`kerneltool call <key> ...`).
//
// The tool gives a call to the peer on a Unix socket that only its user
// reaches (call_socket_linux.odin): one connection for each call
// (peer_remote_serve_socket), with a Call_Socket_Request header, the bytes
// of the request, and the end of the sending; the peer answers with a
// Call_Socket_Result, the bytes of the
// answer, and the end. The test cases of the peer (peer_remote_case) give
// their calls to the thread of the peer directly.
//
// The connection: one for the calls of a session, made at the first call.
// The peer closes it and makes a new one at a call when its last packet
// came more than PEER_REMOTE_REUSE_LIMIT ago: under the idle timeout of
// `remote` (30 s), so that no call goes on a connection that `remote` may
// have ended. A connection that ended (its idle timeout, a close of
// `remote`, a new start of `remote` with a new key) fails the calls that
// were open on it, with the reason; the next call makes a new connection.
// A call that may have run is never sent again: the tool says that it may
// have run.

PEER_REMOTE_PORT_FIRST :: 43000 // The local UDP port of the first connection of the peer to `remote`; one more for each next one.
PEER_REMOTE_REUSE_LIMIT :: 20 * time.Second
// On the clock of the host: the case "silence" waits at most this long for
// a quiet connection; a quiet connection needs one round trip and the delay
// of an acknowledgement (25 ms).
PEER_REMOTE_QUIET_LIMIT :: 10 * time.Second
// The calls that the peer holds at one time: the calls at once of one
// connection, and the calls that wait for a stream.
PEER_REMOTE_CALLS :: 2 * remote.CALLS_AT_ONCE
// On the clock of the host: it only ends a call that hangs. The bounds of
// `remote` are on the clock of the machine, and its log says if each one
// held.
PEER_REMOTE_CALL_LIMIT :: 60 * time.Second
// An address that the listen grant of `remote` does not admit (the range
// TEST-NET-2 of RFC 5737): the network service routes an answer to it
// through the gateway, which is the peer, so the peer would see one.
@(rodata)
PEER_REMOTE_STRANGER := [4]u8{198, 51, 100, 7}

Remote_Call_State :: enum u8 {
	Free,
	Submitted, // A thread gave the call; it waits for a connection and a stream.
	Open, // On a stream.
	Done, // The outcome is there; the thread that gave it reads it.
}

// What a call gave, at the peer.
Remote_Call_Outcome :: enum u32 {
	Answer, // The whole answer, up to the end of the stream of `remote`.
	Reset, // `remote` reset the stream: code is a remote.Stream_Error.
	Lost, // The connection ended before the answer: the call may have run.
	No_Key, // No key of `remote` is pinned since its last start.
	Answer_Too_Large, // More than remote.ANSWER_LIMIT bytes: the peer reset the stream.
	Key_Refused, // `remote` presented another key than the pinned one, or the call named another one: the reason gives both.
	Bad_Socket_Call, // The bytes on the socket of the calls are not a header and the request that it counts.
}

Remote_Call :: struct {
	state:          Remote_Call_State,
	request:        []u8, // remote.REQUEST_LIMIT + 1 bytes: a case sends one byte more than the limit.
	request_length: int,
	// The case "a part and no end": the request goes without the end of
	// its stream.
	no_end:         bool,
	written:        int,
	stream:         u64,
	answer:         []u8, // remote.ANSWER_LIMIT + 1 bytes: one byte more than the limit is Answer_Too_Large.
	received:       int,
	outcome:        Remote_Call_Outcome,
	code:           u64,
	reason:         string, // Why the call has no answer: a constant text, or the text of a refused key in the memory of the peer.
	datagrams:      int, // The datagrams of `remote` that came while the call was not done.
	new_connection: bool, // The call made a new connection.
	submitted_at:   time.Tick,
	done:           sync.Sema,
}

Peer_Remote :: struct {
	lock:             sync.Mutex, // Each field below: the thread of the peer, the thread of the socket of the calls, and the tool read them.
	cryptography:     quic.Cryptography,
	generator:        random.Generator,
	configuration:    quic.Connection_Configuration,
	// The pin belongs to one start of `remote`: the tool sets it from the
	// log line of that start (step Remote_Key), and clears it when it
	// starts or closes `remote` (peer_remote_unpin).
	pinned:           bool,
	// The peer of `kerneltool run` takes the key that a call names (the
	// person reads it in the window); the peer of a machine test takes the
	// key of the log only, and refuses a call that names another one.
	keys_from_calls:  bool,
	// `remote` presented another key than the pinned one: each call fails at
	// once with key_refusal, and no connection is made, until a new pin.
	key_refused:      bool,
	key_refusal:      [256]u8,
	key_refusal_length: int,
	// The connection reached the end of its handshake: a connection that
	// ends before it fails the calls that wait for it, and is not made
	// again for them.
	connected:        bool,
	client:           quic.Connection,
	streams:          []quic.Stream, // remote.CALLS_AT_ONCE stream records.
	active:           bool, // The client holds a connection that did not end.
	port:             u16, // The local UDP port of the connection.
	next_port:        u16,
	connections_made: int,
	start:            time.Tick,
	calls:            [PEER_REMOTE_CALLS]Remote_Call,
	most_open:        int, // The most calls open at one time, since the last case reset it.
	// The test switches.
	lose:             int, // The next datagrams of `remote` to the host that the peer drops: the test of a lost datagram.
	lost:             int,
	silent:           bool, // The peer drops each datagram of the connection, both ways: the test of a lost connection.
	// The case "silence" asks for the silence; the thread of the peer
	// starts it only when the connection is quiet (peer_remote_quiet), so
	// that `remote` holds no stream of it and the record can end only by
	// its idle bound.
	silence_wanted:   bool,
	stranger_answers: int, // Datagrams of `remote` to an address that its grant does not admit: there must be none.
	// The socket of the calls of the tool (call_socket_linux.odin).
	listener:         linux.Fd,
	socket_path:      string,
}

// The form of one call on the socket of the calls, before the bytes of the
// request. The peer reads the bytes as they come; the mark and the count
// make a header that is not at the start of the bytes, or a request that
// is cut, a refusal, not a call with a wrong key or a wrong request.
Call_Socket_Request :: struct {
	mark:           u64, // CALL_SOCKET_MARK.
	request_length: u64, // The bytes of the request after this header.
	key:            [32]u8, // The public key of `remote` that the call names; all zero: the key that the peer pinned.
}
CALL_SOCKET_MARK :: u64(0x6c6c_6163_6574_6f6d) // "moteecall", read as a little-endian number: any value that a request does not start with.

// The form of the outcome of one call on the socket of the calls, before
// the bytes of the answer.
Call_Socket_Result :: struct {
	outcome:        Remote_Call_Outcome,
	new_connection: u32,
	code:           u64,
	datagrams:      u64,
	reason:         [256]u8, // The reason of a call with no answer, with zero bytes after it.
}

peer_remote_make :: proc() -> ^Peer_Remote {
	state := new(Peer_Remote)
	state.streams = make([]quic.Stream, remote.CALLS_AT_ONCE)
	for &call in state.calls {
		call.request = make([]u8, remote.REQUEST_LIMIT + 1)
		call.answer = make([]u8, remote.ANSWER_LIMIT + 1)
	}
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
	// A client of the test: a fixed seed, as the QUIC cases. Its keys
	// protect nothing but the test; the key of `remote` is the one that is
	// pinned.
	seed: [random.SEED_SIZE]u8
	for index in 0 ..< random.SEED_SIZE {
		seed[index] = u8(0x72 + index)
	}
	random.generator_seed(&state.generator, &seed, .Processor)
	state.configuration = {idle_timeout_milliseconds = 30_000}
	state.configuration.tls = {role = .Client, least_seed_strength = .Processor}
	state.configuration.tls.application_protocol_length = copy(state.configuration.tls.application_protocol[:], remote.APPLICATION_PROTOCOL)
	state.next_port = PEER_REMOTE_PORT_FIRST
	state.start = time.tick_now()
	return state
}

peer_remote_free :: proc(state: ^Peer_Remote) {
	delete(state.streams)
	for &call in state.calls {
		delete(call.request)
		delete(call.answer)
	}
	free(state)
}

peer_remote_now :: proc(state: ^Peer_Remote) -> u64 {
	return u64(time.tick_since(state.start) / time.Microsecond) + 1
}

// peer_remote_pin takes the public key of one start of `remote`. A key that
// differs from the key of the connection closes the connection: the next
// call makes a new one with the new key.
peer_remote_pin :: proc(state: ^Peer_Remote, key: [32]u8) {
	sync.mutex_lock(&state.lock)
	defer sync.mutex_unlock(&state.lock)
	if state.pinned && state.configuration.tls.server_public_key == key {
		return
	}
	state.configuration.tls.server_public_key = key
	state.pinned = true
	state.key_refused = false
	if state.active {
		quic.connection_close(&state.client, u64(remote.Stream_Error.Cancelled), peer_remote_now(state))
	}
}

// peer_remote_unpin forgets the key: the tool starts or closes `remote`,
// and the next start makes a new key. A call before the next pin fails at
// once (No_Key), and never goes to a connection with the key of an earlier
// start.
peer_remote_unpin :: proc(state: ^Peer_Remote) {
	sync.mutex_lock(&state.lock)
	defer sync.mutex_unlock(&state.lock)
	state.pinned = false
	state.key_refused = false
	state.configuration.tls.server_public_key = {}
	if state.active {
		quic.connection_close(&state.client, u64(remote.Stream_Error.Cancelled), peer_remote_now(state))
	}
}

// peer_remote_key_refusal_write writes the text of a refused key, with the
// key that is pinned and the key that came. The lock is held.
@(private = "file")
peer_remote_key_refusal_write :: proc(state: ^Peer_Remote, what: string, given: [32]u8) {
	other := given // A parameter has no address: the copy can be sliced.
	pinned := state.configuration.tls.server_public_key
	text := fmt.bprintf(state.key_refusal[:], "the pin does not match: the pinned key of remote is %s, %s %s", hex_of(pinned[:]), what, hex_of(other[:]))
	state.key_refusal_length = len(text)
}

// peer_remote_pin_text takes the public key of `remote` as 64 hexadecimal
// digits.
peer_remote_pin_text :: proc(state: ^Peer_Remote, text: string) -> bool {
	bytes, ok := hex.decode(transmute([]u8)text, context.temp_allocator)
	if !ok || len(bytes) != 32 {
		return false
	}
	key: [32]u8
	copy(key[:], bytes)
	peer_remote_pin(state, key)
	return true
}

// peer_remote_submit gives a call to the thread of the peer, and gives its
// place. false: each place holds a call.
peer_remote_submit :: proc(state: ^Peer_Remote, request: []u8, no_end := false) -> (place: int, ok: bool) {
	sync.mutex_lock(&state.lock)
	defer sync.mutex_unlock(&state.lock)
	for &call, index in state.calls {
		if call.state != .Free {
			continue
		}
		count := copy(call.request, request)
		call.request_length = count
		call.no_end = no_end
		call.written, call.received, call.datagrams = 0, 0, 0
		call.stream, call.code, call.reason = 0, 0, ""
		call.outcome, call.new_connection = .Answer, false
		call.submitted_at = time.tick_now()
		call.state = .Submitted
		return index, true
	}
	return -1, false
}

// What a call gave, for the thread that gave it: the answer is a copy.
Remote_Call_Result :: struct {
	outcome:        Remote_Call_Outcome,
	code:           u64,
	reason:         string,
	answer:         []u8, // In the temporary memory.
	datagrams:      int,
	new_connection: bool,
}

// peer_remote_wait waits for the end of a call that peer_remote_submit
// gave, and frees its place. The bound is on the clock of the host: it only
// ends a call that hangs.
peer_remote_wait :: proc(state: ^Peer_Remote, place: int) -> (result: Remote_Call_Result) {
	call := &state.calls[place]
	if !sync.sema_wait_with_timeout(&call.done, PEER_REMOTE_CALL_LIMIT + 5 * time.Second) {
		// The thread of the peer ends a call at PEER_REMOTE_CALL_LIMIT; this
		// is a peer that stopped.
		return {outcome = .Lost, reason = "the peer did not end the call"}
	}
	sync.mutex_lock(&state.lock)
	defer sync.mutex_unlock(&state.lock)
	// The reason can be in the memory of the peer, which a later refusal
	// writes again: a copy.
	result = {outcome = call.outcome, code = call.code, reason = strings.clone(call.reason, context.temp_allocator), datagrams = call.datagrams, new_connection = call.new_connection}
	if call.outcome == .Answer {
		result.answer = make([]u8, call.received, context.temp_allocator)
		copy(result.answer, call.answer[:call.received])
	}
	call.state = .Free
	return result
}

// peer_remote_call_end gives a call its outcome. The lock is held.
@(private = "file")
peer_remote_call_end :: proc(call: ^Remote_Call, outcome: Remote_Call_Outcome, code: u64 = 0, reason: string = "") {
	call.outcome, call.code, call.reason = outcome, code, reason
	call.state = .Done
	sync.sema_post(&call.done)
}

// peer_remote_end_reason gives why the connection ended.
@(private = "file")
peer_remote_end_reason :: proc(client: ^quic.Connection) -> string {
	switch {
	case client.closed_by_handshake_timeout:
		return "the handshake did not end in 10 s: does the machine run the program remote, with the key that the tool pinned?"
	case client.closed_by_idle_timeout:
		return "the connection ended at its idle timeout: the call may have run"
	case client.closed_by_peer:
		return "remote closed the connection: the call may have run"
	case client.close_error_code == quic.CRYPTO_ERROR_BASE + 42:
		return "the key of remote is not the pinned key (bad_certificate): start remote again, or pin its new key"
	}
	return "the connection ended: the call may have run"
}

// peer_remote_datagram takes a datagram of `remote`: to the peer (the
// gateway), or to an address that the grant of `remote` does not admit.
peer_remote_datagram :: proc(peer: ^Peer, destination: [4]u8, port: u16, data: []u8) {
	state := peer.remote
	sync.mutex_lock(&state.lock)
	defer sync.mutex_unlock(&state.lock)
	if destination != PEER_ADDRESS {
		state.stranger_answers += 1
		return
	}
	if state.silent || !state.active || port != state.port {
		return
	}
	if state.lose > 0 {
		state.lose -= 1
		state.lost += 1
		return
	}
	for &call in state.calls {
		if call.state == .Submitted || call.state == .Open {
			call.datagrams += 1
		}
	}
	error: errors.Error_Record
	quic.connection_datagram_receive(&state.client, data, peer_remote_now(state), &error)
}

// peer_remote_send sends what the connection has, as the gateway, from the
// port of the connection to the port of `remote`. The lock is held.
@(private = "file")
peer_remote_send :: proc(peer: ^Peer, state: ^Peer_Remote, now: u64) {
	buffer: [quic.MAX_DATAGRAM_SIZE]u8
	for _ in 0 ..< 64 {
		length := quic.connection_datagram_send(&state.client, buffer[:], now)
		if length == 0 {
			return
		}
		if !state.silent {
			peer_send(peer, peer_udp_to_machine(peer, PEER_ADDRESS, state.port, remote.LISTEN_PORT, buffer[:length]))
		}
	}
}

// peer_remote_call_work moves one open call: it writes the request, and
// reads the answer up to the end of the stream of `remote`, or its reset.
// The lock is held.
@(private = "file")
peer_remote_call_work :: proc(state: ^Peer_Remote, call: ^Remote_Call) {
	client := &state.client
	for call.written < call.request_length {
		taken := quic.stream_write(client, call.stream, call.request[call.written:call.request_length], !call.no_end)
		call.written += taken
		if taken == 0 {
			break
		}
	}
	for {
		code: u64
		if stream := quic.stream_of(client, call.stream); stream != nil {
			code = stream.peer_reset_code
		}
		count, finished, reset := quic.stream_read(client, call.stream, call.answer[call.received:])
		if reset {
			peer_remote_call_end(call, .Reset, code)
			return
		}
		call.received += count
		switch remote.stream_progress(u64(call.received), finished, remote.ANSWER_LIMIT) {
		case .Too_Large:
			quic.stream_stop_sending(client, call.stream, u64(remote.Stream_Error.Too_Large))
			quic.stream_reset(client, call.stream, u64(remote.Stream_Error.Too_Large))
			peer_remote_call_end(call, .Answer_Too_Large)
			return
		case .Complete:
			peer_remote_call_end(call, .Answer)
			return
		case .Waiting:
		}
		if count == 0 {
			return
		}
	}
}

// peer_remote_tick runs the calls: a connection when a call waits for one,
// a stream for each call, the request and the answer of each stream, the
// timers of the connection. The thread of the peer calls it.
peer_remote_tick :: proc(peer: ^Peer) {
	state := peer.remote
	if state == nil {
		return
	}
	sync.mutex_lock(&state.lock)
	defer sync.mutex_unlock(&state.lock)
	now := peer_remote_now(state)
	client := &state.client
	if state.active && client.state == .Connected {
		state.connected = true
	}
	if state.active && client.state == .Closed {
		// The connection ended: each call on it ends with the reason. A
		// call that waits for a stream gets the next connection only when
		// this one had completed its handshake: a handshake that failed fails
		// the same way again, and is not tried again in a loop.
		state.active = false
		reason := peer_remote_end_reason(client)
		outcome := Remote_Call_Outcome.Lost
		if client.close_error_code == quic.CRYPTO_ERROR_BASE + 42 && !client.closed_by_peer {
			// `remote` presented another key than the pinned one: no call
			// goes until the tool pins a key again.
			state.key_refused = true
			peer_remote_key_refusal_write(state, "and remote presented", client.tls.refused_server_public_key)
		}
		if state.key_refused {
			outcome = .Key_Refused
			reason = string(state.key_refusal[:state.key_refusal_length])
		}
		for &call in state.calls {
			if call.state == .Open || (call.state == .Submitted && !state.connected) {
				peer_remote_call_end(&call, outcome, 0, reason)
			}
		}
		state.connected = false
	}
	submitted, open := 0, 0
	for &call in state.calls {
		#partial switch call.state {
		case .Submitted:
			submitted += 1
		case .Open:
			open += 1
		}
	}
	if submitted > 0 && (!state.pinned || state.key_refused) {
		for &call in state.calls {
			if call.state != .Submitted {
				continue
			}
			if state.key_refused {
				peer_remote_call_end(&call, .Key_Refused, 0, string(state.key_refusal[:state.key_refusal_length]))
			} else {
				peer_remote_call_end(&call, .No_Key, 0, "no key of remote is pinned since its last start: the step Remote_Key reads it from the log")
			}
		}
		submitted = 0
	}
	if submitted > 0 && open == 0 {
		// A connection whose last packet is old may have ended at `remote`:
		// the peer closes it, and the calls take a new one.
		last := client.last_activity
		stale := state.active && now - min(last, now) > u64(PEER_REMOTE_REUSE_LIMIT / time.Microsecond)
		if stale {
			quic.connection_close(client, u64(remote.Stream_Error.Cancelled), now)
			peer_remote_send(peer, state, now)
			state.active = false
		}
		if !state.active {
			error: errors.Error_Record
			state.port = state.next_port
			state.next_port += 1
			state.connected = false
			if quic.connection_start_client(client, state.streams, &state.configuration, &state.cryptography, &state.generator, now, &error) {
				state.active = true
				state.connections_made += 1
				for &call in state.calls {
					if call.state == .Submitted {
						call.new_connection = true
					}
				}
			} else {
				for &call in state.calls {
					if call.state == .Submitted {
						peer_remote_call_end(&call, .Lost, 0, "the QUIC client of the peer did not start")
					}
				}
			}
		}
	}
	if !state.active {
		return
	}
	// A stream for each call that waits, in the order of the places; past
	// the limit of `remote` the client tells it with STREAMS_BLOCKED, and
	// the call waits for MAX_STREAMS.
	open = 0
	for &call in state.calls {
		if call.state == .Submitted {
			identifier, opened := quic.stream_open(client)
			if opened {
				call.stream = identifier
				call.state = .Open
			}
		}
		if call.state == .Open {
			open += 1
		}
	}
	state.most_open = max(state.most_open, open)
	for &call in state.calls {
		if call.state == .Open {
			peer_remote_call_work(state, &call)
		}
	}
	for &call in state.calls {
		if (call.state == .Submitted || call.state == .Open) && time.tick_since(call.submitted_at) > PEER_REMOTE_CALL_LIMIT {
			if call.state == .Open {
				quic.stream_stop_sending(client, call.stream, u64(remote.Stream_Error.Cancelled))
				quic.stream_reset(client, call.stream, u64(remote.Stream_Error.Cancelled))
			}
			peer_remote_call_end(&call, .Lost, 0, "no end of the call in 60 s of the host: the call may have run")
		}
	}
	peer_remote_send(peer, state, now)
	if quic.connection_deadline(client) <= now {
		quic.connection_time_passes(client, now)
	}
	// After the sends of this tick: the last acknowledgement of the client
	// went before the silence.
	if state.silence_wanted && peer_remote_quiet(state) {
		state.silent = true
		state.silence_wanted = false
	}
}

// peer_remote_quiet says if the connection holds nothing that `remote`
// waits for: no call, no stream record of the client in use (each one
// frees when the client read the end of `remote` and `remote` acknowledged
// the end of the client), and no acknowledgement that the client owes. The
// acknowledgement of the end of the last answer is then sent, so `remote`
// frees its stream record too: with the peer silent from then on, its
// record can end only at its idle bound, not by a bound of a stream (an
// answer that the host does not acknowledge is reset 10 s after the call,
// and the connection closed 10 s after that). The lock is held.
@(private = "file")
peer_remote_quiet :: proc(state: ^Peer_Remote) -> bool {
	client := &state.client
	if !state.active || client.state != .Connected || client.spaces[.Application].ack_needed {
		return false
	}
	for &call in state.calls {
		if call.state == .Submitted || call.state == .Open {
			return false
		}
	}
	for &stream in client.streams {
		if stream.in_use {
			return false
		}
	}
	return true
}

// peer_remote_socket_start takes the socket of the calls of the tool, in
// the private folder of the user (call_socket_linux.odin), at a name.
peer_remote_socket_start :: proc(state: ^Peer_Remote, name: string) -> bool {
	path, problem := call_socket_path(name)
	if problem != "" {
		fmt.eprintfln("kerneltool: the peer takes no calls: %s", problem)
		return false
	}
	listener, listening := call_socket_listen(path)
	if !listening {
		return false
	}
	state.listener = listener
	state.socket_path = strings.clone(path)
	return true
}

// peer_remote_socket_stop closes the socket of the calls and removes it.
peer_remote_socket_stop :: proc(state: ^Peer_Remote) {
	call_socket_remove(state.listener, state.socket_path)
	delete(state.socket_path)
	state.socket_path = ""
}

// peer_remote_serve_socket takes the calls of the tool on its socket, one
// connection at a time, and gives each one to the thread of the peer. It
// runs in its own thread until the peer stops: an accept ends each 100 ms.
peer_remote_serve_socket :: proc(peer: ^Peer) {
	state := peer.remote
	for !sync.atomic_load(&peer.stop) {
		connection, accepted := call_socket_accept(state.listener)
		if !accepted {
			continue
		}
		peer_remote_serve_one(state, connection)
		call_socket_close(connection)
		free_all(context.temp_allocator)
	}
}

// peer_remote_call_key_taken takes the key that a call of the socket names.
// The peer of `kerneltool run` pins it; the peer of a machine test takes it
// only when it is the pinned key.
@(private = "file")
peer_remote_call_key_taken :: proc(state: ^Peer_Remote, key: [32]u8) -> bool {
	sync.mutex_lock(&state.lock)
	keys_from_calls := state.keys_from_calls
	same := state.pinned && state.configuration.tls.server_public_key == key
	sync.mutex_unlock(&state.lock)
	if same {
		return true
	}
	if !keys_from_calls {
		return false
	}
	peer_remote_pin(state, key)
	return true
}

// peer_remote_key_refusal_text gives the text of a call that names another
// key than the pinned one, in the temporary memory.
@(private = "file")
peer_remote_key_refusal_text :: proc(state: ^Peer_Remote, given: [32]u8) -> string {
	key := given // A parameter has no address: the copy can be sliced.
	sync.mutex_lock(&state.lock)
	defer sync.mutex_unlock(&state.lock)
	pinned := state.configuration.tls.server_public_key
	if !state.pinned {
		return fmt.tprintf("the call names the key %s, and the peer of a machine test takes the key of the log only: no key is pinned", hex_of(key[:]))
	}
	return fmt.tprintf("the pin does not match: the pinned key of remote is %s, the call names %s", hex_of(pinned[:]), hex_of(key[:]))
}

// peer_remote_serve_one reads one call of the socket, gives it to the thread
// of the peer, and writes its outcome.
@(private = "file")
peer_remote_serve_one :: proc(state: ^Peer_Remote, connection: linux.Fd) {
	buffer := make([]u8, size_of(Call_Socket_Request) + remote.REQUEST_LIMIT + 1, context.temp_allocator)
	count, ended := call_socket_receive_all(connection, buffer, PEER_REMOTE_CALL_LIMIT)
	answer: Call_Socket_Result
	result: Remote_Call_Result
	header: Call_Socket_Request
	if count >= size_of(Call_Socket_Request) {
		header = (^Call_Socket_Request)(raw_data(buffer))^
	}
	switch {
	case !ended || count < size_of(Call_Socket_Request) || header.mark != CALL_SOCKET_MARK || header.request_length != u64(count - size_of(Call_Socket_Request)):
		result = {outcome = .Bad_Socket_Call, reason = fmt.tprintf("the peer read %d bytes on the socket of the calls (the end: %v), not a header and the request that it counts", count, ended)}
	case header.key != ([32]u8{}) && !peer_remote_call_key_taken(state, header.key):
		result = {outcome = .Key_Refused, reason = peer_remote_key_refusal_text(state, header.key)}
	case:
		place, taken := peer_remote_submit(state, buffer[size_of(Call_Socket_Request):count])
		if taken {
			result = peer_remote_wait(state, place)
		} else {
			result = {outcome = .Lost, reason = "the peer holds as many calls as it can"}
		}
	}
	answer.outcome = result.outcome
	answer.code = result.code
	answer.datagrams = u64(result.datagrams)
	answer.new_connection = result.new_connection ? 1 : 0
	copy(answer.reason[:len(answer.reason) - 1], result.reason)
	answer_bytes := transmute([size_of(Call_Socket_Result)]u8)answer
	if call_socket_send_all(connection, answer_bytes[:]) {
		call_socket_send_all(connection, result.answer)
	}
}

// peer_remote_report prints what the peer counted of `remote`, when it made
// a connection.
peer_remote_report :: proc(state: ^Peer_Remote) {
	if state.connections_made == 0 {
		return
	}
	fmt.printfln("kerneltool: the QUIC client of remote in the peer: %d connections, %d datagrams of remote dropped by a step, %d answers to an address that the grant does not admit", state.connections_made, state.lost, state.stranger_answers)
}

// peer_remote_lose asks the peer to drop the next count datagrams of
// `remote` to the host, and gives the count of the datagrams that it
// dropped before.
peer_remote_lose :: proc(state: ^Peer_Remote, count: int) -> (lost_before: int) {
	sync.mutex_lock(&state.lock)
	defer sync.mutex_unlock(&state.lock)
	state.lose = count
	return state.lost
}

// peer_remote_lost gives the count of the datagrams of `remote` that the
// peer dropped for a step.
peer_remote_lost :: proc(state: ^Peer_Remote) -> int {
	sync.mutex_lock(&state.lock)
	defer sync.mutex_unlock(&state.lock)
	return state.lost
}

// remote_case_request gives the bytes of a whole request of a call text, in
// the temporary memory.
@(private = "file")
remote_case_request :: proc(machine: ^Machine, text: string) -> (bytes: []u8, problem: string) {
	call, call_problem := call_prepare(&machine.client, text)
	if call_problem != "" {
		return nil, call_problem
	}
	out := make([]u8, remote.REQUEST_LIMIT, context.temp_allocator)
	written: bool
	bytes, written = remote.request_write(out, call.request, call.bytes)
	if !written {
		return nil, "the request does not fit"
	}
	return bytes, ""
}

// remote_case_call gives one call to the thread of the peer and waits for
// its outcome.
@(private = "file")
remote_case_call :: proc(state: ^Peer_Remote, request: []u8, no_end := false) -> Remote_Call_Result {
	place, taken := peer_remote_submit(state, request, no_end)
	if !taken {
		return {outcome = .Lost, reason = "the peer holds as many calls as it can"}
	}
	return peer_remote_wait(state, place)
}

// remote_case_answer checks that a call gave a whole answer with a status,
// and gives its header.
@(private = "file")
remote_case_answer :: proc(result: Remote_Call_Result, status: remote.Status) -> (header: remote.Answer, problem: string) {
	if result.outcome != .Answer {
		return {}, fmt.tprintf("the call gave %v (code %d: %s) and no answer: %s", result.outcome, result.code, remote.stream_error_name(result.code), result.reason)
	}
	checked, _, ok := remote.answer_check(result.answer)
	if !ok {
		return {}, fmt.tprintf("an answer of %d bytes that is not a header and the bytes that it names", len(result.answer))
	}
	if checked.status != status {
		return checked, fmt.tprintf("an answer with the status %v, not %v", checked.status, status)
	}
	return checked, ""
}

// The malformed call requests of the case "malformed", and the refusal that
// each one must have: the field of the request (the argument of the error
// record) and the error kind.
Malformed :: struct {
	argument: i64,
	kind:     errors.Kind,
}

@(rodata)
remote_malformed := [?]Malformed {
	{0, .Too_Small}, // 20 bytes: shorter than the header.
	{remote.FIELD_KIND, .Bad_Value}, // An unknown kind.
	{remote.FIELD_ARGUMENTS, .Too_Long}, // More bytes of arguments than the stream has.
	{remote.FIELD_RESULT_COUNT, .Too_Long}, // A result past the end of the call region.
	{remote.FIELD_ERROR_START, .Bad_Value}, // An error record that is not aligned on 8.
	{remote.FIELD_SERVICE, .No_Grant}, // A service that the root service does not let it call.
}

// remote_case_run runs one case of the transport of `remote` (docs/QUIC.md,
// section 7) and says if it passed. The calls of a case go to the thread of
// the peer directly, on the connection of the step Call.
remote_case_run :: proc(machine: ^Machine, name: string) -> (passed: bool, result: string) {
	state := machine.peer.remote
	switch name {
	case "malformed":
		// One at a time: the log lines of the refusals come in this order.
		for item in remote_malformed {
			bytes: []u8
			if item.argument == 0 {
				bytes = make([]u8, 20, context.temp_allocator)
			} else {
				request := remote.Request {
					kind         = .Call,
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
				arguments: [16]u8
				out := make([]u8, remote.REQUEST_SIZE + len(arguments), context.temp_allocator)
				bytes, _ = remote.request_write(out, request, arguments[:])
				if item.argument == remote.FIELD_ARGUMENTS {
					(^remote.Request)(raw_data(out)).arguments = 400
				}
			}
			header, problem := remote_case_answer(remote_case_call(state, bytes), .Refused)
			if problem != "" {
				return false, fmt.tprintf("the request with the wrong field %d: %s", item.argument, problem)
			}
			if header.error.argument != item.argument || header.error.kind != i64(item.kind) {
				return false, fmt.tprintf("the request with the wrong field %d: refused with the field %d and the kind %d, not %v", item.argument, header.error.argument, header.error.kind, item.kind)
			}
		}
		return true, fmt.tprintf("remote refused each of the %d malformed requests with the expected error record, each on its own stream", len(remote_malformed))
	case "two at once":
		first, first_problem := remote_case_request(machine, "monitor.programs()")
		second, second_problem := remote_case_request(machine, "monitor.count(\"processors\")")
		if first_problem != "" || second_problem != "" {
			return false, fmt.tprintf("the requests: %s%s", first_problem, second_problem)
		}
		sync.mutex_lock(&state.lock)
		state.most_open = 0
		sync.mutex_unlock(&state.lock)
		first_place, first_taken := peer_remote_submit(state, first)
		second_place, second_taken := peer_remote_submit(state, second)
		if !first_taken || !second_taken {
			return false, "the peer did not take the two calls"
		}
		second_result := peer_remote_wait(state, second_place)
		first_result := peer_remote_wait(state, first_place)
		first_header, problem := remote_case_answer(first_result, .Ok)
		if problem != "" {
			return false, fmt.tprintf("monitor.programs(): %s", problem)
		}
		second_header, second_answer_problem := remote_case_answer(second_result, .Ok)
		if second_answer_problem != "" {
			return false, fmt.tprintf("monitor.count(\"processors\"): %s", second_answer_problem)
		}
		if first_header.value < 1 || second_header.value != 4 {
			return false, fmt.tprintf("monitor.programs() gave %d rows, and monitor.count(\"processors\") gave %d, not 4", first_header.value, second_header.value)
		}
		sync.mutex_lock(&state.lock)
		most := state.most_open
		sync.mutex_unlock(&state.lock)
		if most < 2 {
			return false, fmt.tprintf("the two calls were never on two streams at one time (the most at one time: %d)", most)
		}
		return true, fmt.tprintf("monitor.programs() (%d rows, %d bytes) and monitor.count(\"processors\") (4) on two streams at one time, each answer on its own stream", first_header.value, len(first_result.answer))
	case "too large":
		bytes := make([]u8, remote.REQUEST_LIMIT + 1, context.temp_allocator)
		outcome := remote_case_call(state, bytes)
		if outcome.outcome != .Reset || outcome.code != u64(remote.Stream_Error.Too_Large) {
			return false, fmt.tprintf("a request of %d bytes gave %v with the code %d (%s), not a reset with Too_Large: %s", len(bytes), outcome.outcome, outcome.code, remote.stream_error_name(outcome.code), outcome.reason)
		}
		return true, fmt.tprintf("a request of %d bytes: remote reset the stream with the code Too_Large", len(bytes))
	case "a part and no end":
		whole, problem := remote_case_request(machine, "monitor.count(\"processors\")")
		if problem != "" {
			return false, problem
		}
		outcome := remote_case_call(state, whole[:50], true)
		if outcome.outcome != .Reset || outcome.code != u64(remote.Stream_Error.Timeout) {
			return false, fmt.tprintf("50 bytes of a request and no end gave %v with the code %d (%s), not a reset with Timeout: %s", outcome.outcome, outcome.code, remote.stream_error_name(outcome.code), outcome.reason)
		}
		return true, "50 bytes of a request and no end: remote reset the stream with the code Timeout (its log says if the bound held, in time of the machine)"
	case "stranger":
		// An Initial of version 1 in 1200 bytes, from an address that the
		// grant does not admit. A call of the host goes after it: when its
		// answer came, any answer to the stranger came before it, because
		// the network service and remote take the datagrams in order.
		datagram: [quic.MAX_DATAGRAM_SIZE]u8
		datagram[0] = quic.LONG_HEADER_FORM | quic.FIXED_BIT | 0x03
		datagram[1], datagram[2], datagram[3], datagram[4] = 0, 0, 0, 1
		datagram[5] = quic.CONNECTION_ID_SIZE
		datagram[14], datagram[15] = 0, 0
		quic.variable_length_integer_write(datagram[:], 16, quic.MAX_DATAGRAM_SIZE - 18, 2)
		peer_send(machine.peer, peer_udp_to_machine(machine.peer, PEER_REMOTE_STRANGER, 40000, remote.LISTEN_PORT, datagram[:]))
		request, problem := remote_case_request(machine, "monitor.count(\"processors\")")
		if problem != "" {
			return false, problem
		}
		if _, answer_problem := remote_case_answer(remote_case_call(state, request), .Ok); answer_problem != "" {
			return false, fmt.tprintf("the call after the datagram of the stranger: %s", answer_problem)
		}
		sync.mutex_lock(&state.lock)
		answers := state.stranger_answers
		sync.mutex_unlock(&state.lock)
		if answers != 0 {
			return false, fmt.tprintf("remote answered %d datagrams to 198.51.100.7, which its grant does not admit", answers)
		}
		return true, "an Initial from 198.51.100.7, which the grant does not admit, got nothing; the call of the host after it got its answer"
	case "silence":
		sync.mutex_lock(&state.lock)
		state.silence_wanted = true
		sync.mutex_unlock(&state.lock)
		// The bound is on the clock of the host: it only ends a case whose
		// connection never becomes quiet.
		start := time.tick_now()
		for {
			sync.mutex_lock(&state.lock)
			silent, active := state.silent, state.active
			sync.mutex_unlock(&state.lock)
			if silent {
				break
			}
			if !active || time.tick_since(start) > PEER_REMOTE_QUIET_LIMIT {
				sync.mutex_lock(&state.lock)
				state.silence_wanted = false
				sync.mutex_unlock(&state.lock)
				return false, fmt.tprintf("the connection to remote did not become quiet (no call, no stream, no acknowledgement owed) in %v: the silence would not test the idle bound alone", PEER_REMOTE_QUIET_LIMIT)
			}
			time.sleep(5 * time.Millisecond)
		}
		return true, "the connection was quiet (no call, no stream, no acknowledgement owed); the peer now drops each datagram of it, both ways"
	case "silence ends":
		sync.mutex_lock(&state.lock)
		state.silent = false
		before := state.connections_made
		sync.mutex_unlock(&state.lock)
		request, problem := remote_case_request(machine, "monitor.count(\"processors\")")
		if problem != "" {
			return false, problem
		}
		outcome := remote_case_call(state, request)
		if _, answer_problem := remote_case_answer(outcome, .Ok); answer_problem != "" {
			return false, fmt.tprintf("the first call after the silence: %s", answer_problem)
		}
		sync.mutex_lock(&state.lock)
		after := state.connections_made
		sync.mutex_unlock(&state.lock)
		if !outcome.new_connection || after != before + 1 {
			return false, fmt.tprintf("the first call after the silence did not open a new connection (%d connections before, %d after)", before, after)
		}
		return true, "the first call after the silence opened a new connection, and got its answer"
	}
	return false, fmt.tprintf("no case \"%s\" of remote", name)
}
