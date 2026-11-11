package quic

// A QUIC server with several connections (docs/QUIC.md, section 6): a table
// of Connection records in memory of the caller, and the choice of the
// record of each datagram that arrives. The caller gives each datagram with
// the address and the port of its remote, sends each datagram that the
// server gives to the remote that it names, and releases the remotes that
// the server no longer needs (the command Release of a UDP listen grant).
//
// The rules of a new connection:
// - A datagram goes to a record by its Destination Connection ID and its
//   remote: the identifier of the server, or, in an Initial, the identifier
//   that the client chose first. A known identifier from another remote is
//   dropped: a client of this server does not move (the server sends
//   disable_active_migration).
// - An Initial with an unknown identifier takes a free record only when it
//   is authentic: the server opens a copy of it with the Initial keys of its
//   identifier first, so a forged datagram never touches a record.
// - Then the limits: connections of one remote address, handshakes of one
//   remote address, handshakes at once, and a free record. A datagram over a
//   limit gets no answer: the client tries again until its handshake
//   deadline.
// - A long header of another version gets one Version Negotiation packet,
//   at most a fixed count in each second.
// - The stateless reset is not done.

import "contract:errors"
import "support:random"

Server_Limits :: struct {
	connections_per_remote_address: int, // Records that one remote address holds.
	handshakes_per_remote_address:  int, // Records in the handshake that one remote address holds.
	handshakes_at_once:             int, // Records in the handshake, for all remotes.
	version_negotiations_per_second: int,
}

// The limits of quic_echo, and of the tests: a table of 16 records.
SERVER_LIMITS_DEFAULT :: Server_Limits {
	connections_per_remote_address  = 8,
	handshakes_per_remote_address   = 2,
	handshakes_at_once              = 8,
	version_negotiations_per_second = 16,
}

Remote :: struct {
	address: u32,
	port:    u16,
}

// The facts of one record that the Connection does not hold.
Server_Record :: struct {
	in_use:     bool,
	remote:     Remote,
	started_at: u64,
}

// What the server counts: the work that a flood costs is visible.
Server_Counters :: struct {
	accepted:                     u64, // Records that an authentic Initial took.
	ended:                        u64, // Records freed.
	datagrams:                    u64,
	unreadable:                   u64, // A datagram whose first header does not read.
	not_authentic:                u64, // An Initial with an unknown identifier that does not open.
	too_small:                    u64, // An Initial in a datagram under 1200 bytes, or with an identifier under 8 bytes.
	// The Initials refused by a limit: each datagram counts, so a client
	// that waits for its turn counts again at each try.
	refused_remote_limit:         u64,
	refused_handshake_limit:      u64,
	refused_full:                 u64,
	other_remote:                 u64, // A known identifier from another remote.
	no_connection:                u64, // A packet that is not an Initial, for no record.
	version_negotiations:         u64,
	version_negotiations_dropped: u64, // Over the count of the second.
	authenticity_checks:          u64, // Initials opened on a copy: the work of a flood.
}

// The answer to one datagram.
Server_Outcome :: struct {
	record:         int, // The record that took the datagram; -1: none.
	release_remote: bool, // The server keeps nothing of this remote: the caller releases it, after it sent the answer.
	answer_length:  int, // A Version Negotiation packet in the answer buffer, for the remote.
}

Server :: struct {
	connections:          []Connection, // Memory of the caller: a mapping, never a stack.
	records:              []Server_Record,
	configuration:        Connection_Configuration,
	cryptography:         ^Cryptography,
	generator:            ^random.Generator,
	limits:               Server_Limits,
	counters:             Server_Counters,
	send_next:            int, // The record that sends first at the next call: each record gets its turn.
	negotiation_second:   u64,
	negotiation_count:    int,
	authenticity_copy:    [DATAGRAM_LIMIT]u8, // Private memory: the copy of an Initial that is opened to check it.
}

// server_init prepares a server over the memory of the caller: one
// Connection and one Server_Record for each place. The configuration is the
// one of each connection: the role server, its key, its least seed
// strength.
server_init :: proc "contextless" (server: ^Server, connections: []Connection, records: []Server_Record, configuration: ^Connection_Configuration, cryptography: ^Cryptography, generator: ^random.Generator, limits: Server_Limits, error: ^errors.Error_Record) -> bool {
	if len(connections) == 0 || len(connections) != len(records) {
		errors.fail(error, -1, .Bad_Value, .Records, 2, i64(len(records)), i64(len(connections)), 0)
		return false
	}
	if !connection_seed_strength_check(configuration, error) {
		return false
	}
	server.connections = connections
	server.records = records
	server.configuration = configuration^
	server.configuration.tls.role = .Server
	server.cryptography = cryptography
	server.generator = generator
	server.limits = limits
	server.counters = {}
	for &record in records {
		record = {}
	}
	return true
}

// server_datagram_receive gives one datagram of a remote to its record, or
// to a new record, under the limits. A Version Negotiation packet goes in
// answer when one is due.
server_datagram_receive :: proc "contextless" (server: ^Server, datagram: []u8, remote: Remote, answer: []u8, now: u64) -> (outcome: Server_Outcome) {
	outcome.record = -1
	server.counters.datagrams += 1
	error: errors.Error_Record
	header: Packet_Header
	if !header_read(datagram, 0, CONNECTION_ID_SIZE, &header, &error) {
		server.counters.unreadable += 1
		outcome.release_remote = !server_remote_has_record(server, remote)
		return
	}
	index, other_remote := server_record_of(server, &header, remote)
	if index >= 0 {
		connection_datagram_receive(&server.connections[index], datagram, now, &error)
		outcome.record = index
		return
	}
	outcome.release_remote = !server_remote_has_record(server, remote)
	if other_remote {
		server.counters.other_remote += 1
		return
	}
	#partial switch header.type {
	case .Unknown_Version:
		outcome.answer_length = server_version_negotiation(server, datagram, &header, answer, now)
	case .Initial:
		if index = server_new_connection(server, datagram, &header, remote, now); index >= 0 {
			outcome.record = index
			outcome.release_remote = false
		}
	case:
		server.counters.no_connection += 1
	}
	return
}

// server_record_of finds the record of a packet: its Destination Connection
// ID is the identifier of a record, or, in an Initial, the identifier that
// the client of a record chose first. other_remote: a record has the
// identifier, but another remote.
@(private)
server_record_of :: proc "contextless" (server: ^Server, header: ^Packet_Header, remote: Remote) -> (index: int, other_remote: bool) {
	destination := header.destination_connection_id[:header.destination_connection_id_length]
	for &record, place in server.records {
		if !record.in_use {
			continue
		}
		connection := &server.connections[place]
		ours := bytes_equal(destination, connection.local_connection_id[:])
		if !ours && header.type == .Initial {
			ours = bytes_equal(destination, connection.original_destination_connection_id[:connection.original_destination_connection_id_length])
		}
		if !ours {
			continue
		}
		if record.remote != remote {
			return -1, true
		}
		return place, false
	}
	return -1, false
}

@(private)
server_remote_has_record :: proc "contextless" (server: ^Server, remote: Remote) -> bool {
	for record in server.records {
		if record.in_use && record.remote == remote {
			return true
		}
	}
	return false
}

// server_new_connection gives an Initial with an unknown identifier a free
// record: when it is authentic, and under the limits. It gives the record,
// or -1.
@(private)
server_new_connection :: proc "contextless" (server: ^Server, datagram: []u8, header: ^Packet_Header, remote: Remote, now: u64) -> int {
	if len(datagram) < SMALLEST_MAX_UDP_PAYLOAD_SIZE || header.destination_connection_id_length < CONNECTION_ID_SIZE {
		server.counters.too_small += 1
		return -1
	}
	if !server_initial_is_authentic(server, datagram, header) {
		server.counters.not_authentic += 1
		return -1
	}
	of_address, handshakes_of_address, handshakes := 0, 0, 0
	free := -1
	for record, place in server.records {
		if !record.in_use {
			if free < 0 {
				free = place
			}
			continue
		}
		in_handshake := server.connections[place].state == .Handshake
		if in_handshake {
			handshakes += 1
		}
		if record.remote.address == remote.address {
			of_address += 1
			if in_handshake {
				handshakes_of_address += 1
			}
		}
	}
	switch {
	case of_address >= server.limits.connections_per_remote_address, handshakes_of_address >= server.limits.handshakes_per_remote_address:
		server.counters.refused_remote_limit += 1
		return -1
	case handshakes >= server.limits.handshakes_at_once:
		server.counters.refused_handshake_limit += 1
		return -1
	case free < 0:
		server.counters.refused_full += 1
		return -1
	}
	connection := &server.connections[free]
	error: errors.Error_Record
	if !connection_start_server(connection, &server.configuration, server.cryptography, server.generator, now, &error) {
		return -1
	}
	connection_datagram_receive(connection, datagram, now, &error)
	if !connection.tls_started {
		// It opened on the copy: this does not happen, but a record that
		// did not take the packet is not kept.
		connection.state = .Closed
		return -1
	}
	server.records[free] = {in_use = true, remote = remote, started_at = now}
	server.counters.accepted += 1
	return free
}

// server_initial_is_authentic opens a copy of the first packet of a
// datagram with the Initial keys of its Destination Connection ID. The
// datagram itself is not changed: the record that takes it opens it again.
@(private)
server_initial_is_authentic :: proc "contextless" (server: ^Server, datagram: []u8, header: ^Packet_Header) -> bool {
	server.counters.authenticity_checks += 1
	error: errors.Error_Record
	copy_of_the_datagram, taken := datagram_take(datagram, server.authenticity_copy[:], &error)
	if !taken {
		return false
	}
	client_keys, server_keys: Packet_Keys
	defer secret_erase(&client_keys, size_of(client_keys))
	defer secret_erase(&server_keys, size_of(server_keys))
	if !initial_keys(server.cryptography, header.destination_connection_id[:header.destination_connection_id_length], &client_keys, &server_keys, &error) {
		return false
	}
	unprotected: Unprotected_Header
	if !header_protection_remove(server.cryptography, &client_keys, copy_of_the_datagram, header, 0, &unprotected, &error) {
		return false
	}
	opened: Opened_Packet
	return packet_payload_open(server.cryptography, &client_keys, copy_of_the_datagram, header, &unprotected, &opened, &error)
}

// server_version_negotiation writes one Version Negotiation packet (RFC
// 9000, section 17.2.1) for a long header of another version, in a datagram
// of 1200 bytes at least (RFC 9000, section 6.1: a smaller one may not be
// the start of a connection), at most a fixed count in each second. The
// packet has 51 bytes at most for 1200 received: far under the
// anti-amplification limit. It gives the length, or 0.
@(private)
server_version_negotiation :: proc "contextless" (server: ^Server, datagram: []u8, header: ^Packet_Header, answer: []u8, now: u64) -> int {
	if len(datagram) < SMALLEST_MAX_UDP_PAYLOAD_SIZE {
		server.counters.too_small += 1
		return 0
	}
	second := now / 1_000_000
	if second != server.negotiation_second {
		server.negotiation_second, server.negotiation_count = second, 0
	}
	if server.negotiation_count >= server.limits.version_negotiations_per_second {
		server.counters.version_negotiations_dropped += 1
		return 0
	}
	destination := header.source_connection_id[:header.source_connection_id_length]
	source := header.destination_connection_id[:header.destination_connection_id_length]
	length := 1 + 4 + 1 + len(destination) + 1 + len(source) + 4
	if len(answer) < length {
		return 0
	}
	at := 0
	answer[at] = LONG_HEADER_FORM // The other bits have no meaning in this packet.
	at += 1
	answer[at], answer[at + 1], answer[at + 2], answer[at + 3] = 0, 0, 0, 0 // The version 0.
	at += 4
	answer[at] = u8(len(destination))
	at += 1
	at += copy(answer[at:], destination)
	answer[at] = u8(len(source))
	at += 1
	at += copy(answer[at:], source)
	answer[at], answer[at + 1], answer[at + 2], answer[at + 3] = 0, 0, 0, 1 // The one version that this library speaks.
	server.negotiation_count += 1
	server.counters.version_negotiations += 1
	return length
}

// server_datagram_send writes the next datagram of a record in buffer, and
// gives it with its remote; 0 when no record has one. Each call starts at
// the record after the one that sent last.
server_datagram_send :: proc "contextless" (server: ^Server, buffer: []u8, now: u64) -> (length: int, remote: Remote) {
	count := len(server.records)
	for step in 0 ..< count {
		place := (server.send_next + step) % count
		if !server.records[place].in_use {
			continue
		}
		length = connection_datagram_send(&server.connections[place], buffer, now)
		if length > 0 {
			server.send_next = (place + 1) % count
			return length, server.records[place].remote
		}
	}
	return 0, {}
}

// server_deadline gives the earliest deadline of the records.
server_deadline :: proc "contextless" (server: ^Server) -> u64 {
	deadline := NO_DEADLINE
	for record, place in server.records {
		if record.in_use {
			deadline = min(deadline, connection_deadline(&server.connections[place]))
		}
	}
	return deadline
}

// server_time_passes acts on each deadline that passed.
server_time_passes :: proc "contextless" (server: ^Server, now: u64) {
	for record, place in server.records {
		if record.in_use && connection_deadline(&server.connections[place]) <= now {
			connection_time_passes(&server.connections[place], now)
		}
	}
}

// server_sweep frees each record whose connection ended, and writes its
// remote in released when no other record has it: the caller releases
// them. A record ends after its closing or draining time, so its last
// datagram went before. It gives the count of remotes written.
server_sweep :: proc "contextless" (server: ^Server, released: []Remote) -> int {
	count := 0
	for &record, place in server.records {
		if !record.in_use || server.connections[place].state != .Closed {
			continue
		}
		record.in_use = false
		server.counters.ended += 1
		if !server_remote_has_record(server, record.remote) && count < len(released) {
			released[count] = record.remote
			count += 1
		}
	}
	return count
}

// server_connections_in_use counts the records in use.
server_connections_in_use :: proc "contextless" (server: ^Server) -> int {
	count := 0
	for record in server.records {
		if record.in_use {
			count += 1
		}
	}
	return count
}
