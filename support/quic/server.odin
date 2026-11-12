package quic

// A QUIC server with several connections (docs/QUIC.md, section 6): a table
// of Connection records in memory of the caller, and the choice of the
// record of each datagram that arrives. The caller gives each datagram with
// the address and the port of its remote, sends each answer and each
// datagram that the server gives to the remote that it names, marks the
// remotes that the server validated (the command Validate of a UDP listen
// grant), and releases the remotes that the server no longer needs (the
// command Release).
//
// The rules of a new connection:
// - The server copies each datagram once into its own memory, and decides
//   on that copy only.
// - A datagram goes to a record by its Destination Connection ID and its
//   remote: the identifier of the server, or, in an Initial, the identifier
//   that gave the Initial keys of the record. A known identifier from
//   another remote is dropped: a client of this server does not move (the
//   server sends disable_active_migration), and a NAT that changes the
//   address or the port of a client ends its connection.
// - An Initial with an unknown identifier and no token gets a Retry packet
//   (retry.odin), and the server keeps nothing: no record, no key.
// - An Initial with a token takes a free record only when its token opens
//   for its remote (the client proved its address), when the token did not
//   take a record before, under the limits (connections of one remote
//   address, handshakes of one remote address, handshakes at once, a free
//   record, the budget of Initial checks of the address), and when the
//   Initial itself opens. Each limit that needs no cryptography is checked
//   before the Initial is opened. Over a limit it gets no answer: the
//   client tries again.
// - The work of datagrams of unknown identifiers has budgets
//   (server_budgets.odin): Retries, token checks, Initial checks, and the
//   Initial checks of one address. Over a budget such a datagram is
//   dropped before any cryptography. The datagrams of known records have no
//   budget (server_batch_order lets the caller give them first).
// - A record whose address the server validated asks the caller to
//   validate its remote at each datagram, until the caller confirms that
//   the network service took it (server_validation_confirmed).
// - A long header of another version gets one Version Negotiation packet,
//   at most a fixed count in each second.
// - The stateless reset is not done.

import "contract:errors"
import "support:random"

Server_Limits :: struct {
	connections_per_remote_address:  int, // Records that one remote address holds.
	handshakes_per_remote_address:   int, // Records in the handshake that one remote address holds.
	handshakes_at_once:              int, // Records in the handshake, for all remotes.
	version_negotiations_per_second: int,
	// The budgets of work: each one a rate in each second and a depth, the
	// most units that a burst takes at once (server_budgets.odin).
	retries_per_second:                    int,
	retries_depth:                         int,
	token_checks_per_second:               int,
	token_checks_depth:                    int,
	initial_checks_per_second:             int,
	initial_checks_depth:                  int,
	initial_checks_per_address_per_second: int, // For each address whose token opened.
	initial_checks_per_address_depth:      int,
}

// The limits of quic_echo, and of the tests: a table of 16 records. The
// budgets of work are a share of one processor, by the costs of each piece
// of work, from the speeds of docs/CRYPTOGRAPHY.md, section 6, with the
// erasure of 16 KiB of stack after each export (the speed test
// the_cost_of_the_work_of_new_connections measures them on the host):
// - a Retry: 8 random bytes, one ChaCha20-Poly1305 seal of 37 bytes (the
//   token), one AES-128-GCM tag over a packet of about 100 bytes: two
//   exports, about 10 us;
// - a token check: one ChaCha20-Poly1305 open of 37 bytes: one export,
//   about 3 us;
// - an Initial check: 9 HKDF exports for the Initial keys, one mask, one
//   AES-128-GCM open of about 1160 bytes: 11 exports, about 30 us.
// 20 000 Retries, 30 000 token checks and 2000 Initial checks in one
// second take about 200 + 90 + 60 = 350 ms of one processor: 35 % in the
// worst second, when every budget is spent. A flood must then bring 24 MB/s
// of Initials with no token, or 36 MB/s with tokens, to spend a budget.
// The depth is a tenth of a second of each rate. One address whose token
// opened gets 4 Initial checks at once, then 1 in each second: a client
// needs one, and one more for each Initial that the network loses. The
// table of address budgets has 1024 places, so addresses that rotate
// through it get at most 1024 checks in each second after the depths:
// half of the shared budget, which keeps the other half for addresses
// that the table refuses or that come back.
SERVER_LIMITS_DEFAULT :: Server_Limits {
	connections_per_remote_address        = 8,
	handshakes_per_remote_address         = 2,
	handshakes_at_once                    = 8,
	version_negotiations_per_second       = 16,
	retries_per_second                    = 20_000,
	retries_depth                         = 2000,
	token_checks_per_second               = 30_000,
	token_checks_depth                    = 3000,
	initial_checks_per_second             = 2000,
	initial_checks_depth                  = 200,
	initial_checks_per_address_per_second = 1,
	initial_checks_per_address_depth      = 4,
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
	generation: u64, // A new value each time that the record is taken: the caller tells two clients of one place apart.
	// The caller confirmed that the network service validated the remote
	// (the command Validate gave 1). Until then each datagram of a record
	// whose address is validated asks the caller to validate the remote:
	// a Validate that came after the network service forgot the remote
	// gives 0, and a later one, after a datagram admitted it again, works.
	validation_confirmed: bool,
}

// What the server counts: the work that a flood costs is visible.
Server_Counters :: struct {
	accepted:                     u64, // Records that an Initial with a valid token took.
	ended:                        u64, // Records freed.
	datagrams:                    u64,
	unreadable:                   u64, // A datagram whose first header does not read.
	retries:                      u64, // Retry packets sent: Initials with no token.
	tokens_refused:               u64, // A token that does not open for its remote, or names another identifier.
	tokens_expired:               u64, // A token older than its lifetime, or of a time to come.
	not_authentic:                u64, // An Initial with a valid token that does not open.
	too_small:                    u64, // An Initial in a datagram under 1200 bytes, or with an identifier under 8 bytes.
	// The Initials refused by a limit: each datagram counts, so a client
	// that waits for its turn counts again at each try.
	refused_remote_limit:         u64,
	refused_handshake_limit:      u64,
	refused_full:                 u64,
	over_budget:                  u64, // Datagrams of unknown identifiers dropped over a shared budget, before any cryptography.
	over_address_budget:          u64, // Initials with a valid token dropped over the budget of Initial checks of their address, before the Initial is opened.
	address_table_full:           u64, // Initials with a valid token of a new address, dropped because no place of the table of address budgets was free or full again.
	tokens_used_again:            u64, // A valid token whose record was taken before.
	used_tokens_forgotten:        u64, // A used token that the full table forgot before it expired: it can take a record again.
	other_remote:                 u64, // A known identifier from another remote.
	no_connection:                u64, // A packet that is not an Initial, for no record.
	version_negotiations:         u64,
	version_negotiations_dropped: u64, // Over the count of the second.
	authenticity_checks:          u64, // Initials opened on a copy: the work of new connections.
}

// What one datagram asks of the caller.
Server_Outcome :: struct {
	record:          int, // The record that took the datagram; -1: none.
	answer_length:   int, // A Retry or a Version Negotiation packet in the answer buffer, for the remote.
	validate_remote: bool, // The remote proved its address: the caller marks it validated, before it sends the datagrams of the record, and gives the result to server_validation_confirmed.
	release_remote:  bool, // The server keeps nothing of this remote: the caller releases it, after it sent the answer.
}

Server_Work :: enum u8 {
	Retry,
	Token_Check,
	Initial_Check,
}

Server :: struct {
	connections:        []Connection, // Memory of the caller: a mapping, never a stack.
	records:            []Server_Record,
	streams:            []Stream, // Memory of the caller: the stream records of each connection, streams_per_connection each, in the order of the connections.
	streams_per_connection: int,
	configuration:      Connection_Configuration,
	cryptography:       ^Cryptography,
	generator:          ^random.Generator,
	limits:             Server_Limits,
	counters:           Server_Counters,
	send_next:          int, // The record that sends first at the next call: each record gets its turn.
	next_generation:    u64,
	negotiation_second: u64,
	negotiation_count:  int,
	work_buckets:       [Server_Work]Work_Bucket,
	address_budgets:    [SERVER_ADDRESS_BUDGETS]Server_Address_Budget,
	used_tokens:        [SERVER_USED_TOKENS]Server_Used_Token,
	retry_key:          [RETRY_TOKEN_KEY_SIZE]u8, // Made at the start, from the generator: the tokens of another start do not open.
	token_counter:      u64, // The nonce of each token: never two times with one key.
	datagram_copy:      [DATAGRAM_LIMIT]u8, // Private memory: the copy of the datagram, on which each decision is taken.
	authenticity_copy:  [DATAGRAM_LIMIT]u8, // Private memory: a second copy, which the check of an Initial changes when it removes the header protection.
}

// server_init prepares a server over the memory of the caller: one
// Connection and one Server_Record for each place, and the same count of
// stream records for each place (at least one): the streams that one
// client may open at one time. The configuration is the one of each
// connection: the role server, its key, its least seed strength. It makes
// the key of the tokens of Retry.
server_init :: proc "contextless" (server: ^Server, connections: []Connection, records: []Server_Record, streams: []Stream, configuration: ^Connection_Configuration, cryptography: ^Cryptography, generator: ^random.Generator, limits: Server_Limits, error: ^errors.Error_Record) -> bool {
	if len(connections) == 0 || len(connections) != len(records) {
		errors.fail(error, -1, .Bad_Value, .Records, 2, i64(len(records)), i64(len(connections)), 0)
		return false
	}
	if len(streams) < len(connections) || len(streams) % len(connections) != 0 {
		errors.fail(error, -1, .Bad_Value, .Records, 3, i64(len(streams)), i64(len(connections)), 0)
		return false
	}
	server.streams = streams
	server.streams_per_connection = len(streams) / len(connections)
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
	server.token_counter = 0
	server.work_buckets = {}
	server.address_budgets = {}
	server.used_tokens = {}
	for &record in records {
		record = {}
	}
	return random.fill_for_a_key(generator, server.retry_key[:], configuration.tls.least_seed_strength, error)
}

// One datagram of a batch that arrived together, with its remote.
Server_Datagram :: struct {
	bytes:  []u8,
	remote: Remote,
}

// server_batch_order gives the order in which the caller gives a batch of
// datagrams to server_datagram_receive: first each datagram that goes to a
// record, then the others, each group in the order of arrival. order holds
// each index of the batch once, and the count is the smaller of len(batch)
// and len(order). The header of each datagram is read once, before any
// datagram is given: a datagram that a record would take only after an
// earlier datagram of the batch took that record is in the second group,
// and is given all the same.
//
// The order is a priority, not a decision of security: it reads the header
// in place, with no copy. If the bytes change under it, a datagram is only
// given earlier or later; server_datagram_receive decides on its own copy.
server_batch_order :: proc "contextless" (server: ^Server, batch: []Server_Datagram, order: []int) -> int {
	count := min(len(batch), len(order))
	// The known datagrams fill order from its front, the others from its
	// back; the back part is then turned round, to the order of arrival.
	front, back := 0, count
	for index in 0 ..< count {
		item := batch[index]
		error: errors.Error_Record
		header: Packet_Header
		known := false
		if len(item.bytes) <= DATAGRAM_LIMIT && header_read(item.bytes, 0, CONNECTION_ID_SIZE, &header, &error) {
			record, _ := server_record_of(server, &header, item.remote)
			known = record >= 0
		}
		if known {
			order[front] = index
			front += 1
		} else {
			back -= 1
			order[back] = index
		}
	}
	for left, right := front, count - 1; left < right; left, right = left + 1, right - 1 {
		order[left], order[right] = order[right], order[left]
	}
	return count
}

// server_validation_confirmed takes the result of the Validate that the
// caller sent for the record at place, when the record was of the
// generation given: true when the network service validated the remote.
// Each record of that remote is then confirmed. A result of false changes
// nothing: the next datagram of the record asks again.
server_validation_confirmed :: proc "contextless" (server: ^Server, place: int, generation: u64, validated: bool) {
	if !validated || place < 0 || place >= len(server.records) {
		return
	}
	record := server.records[place]
	if !record.in_use || record.generation != generation {
		return
	}
	for &other in server.records {
		if other.in_use && other.remote == record.remote {
			other.validation_confirmed = true
		}
	}
}

// server_datagram_receive gives one datagram of a remote to its record, or
// answers it, under the limits and the budgets. The answer goes in answer.
server_datagram_receive :: proc "contextless" (server: ^Server, received: []u8, remote: Remote, answer: []u8, now: u64) -> (outcome: Server_Outcome) {
	outcome.record = -1
	server.counters.datagrams += 1
	error: errors.Error_Record
	// One copy, in the memory of the server: each decision below reads it,
	// and the record opens the same bytes.
	datagram, taken := datagram_take(received, server.datagram_copy[:], &error)
	if !taken {
		server.counters.unreadable += 1
		outcome.release_remote = !server_remote_has_record(server, remote)
		return
	}
	header: Packet_Header
	if !header_read(datagram, 0, CONNECTION_ID_SIZE, &header, &error) {
		server.counters.unreadable += 1
		outcome.release_remote = !server_remote_has_record(server, remote)
		return
	}
	index, other_remote := server_record_of(server, &header, remote)
	if index >= 0 {
		connection := &server.connections[index]
		connection_datagram_receive(connection, datagram, now, &error)
		outcome.record = index
		outcome.validate_remote = connection.address_validated && !server.records[index].validation_confirmed
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
		index, outcome.answer_length = server_new_connection(server, datagram, &header, remote, answer, now)
		if index >= 0 {
			outcome.record = index
			outcome.validate_remote = true
			outcome.release_remote = false
		}
	case:
		server.counters.no_connection += 1
	}
	return
}

// server_record_of finds the record of a packet: its Destination Connection
// ID is the identifier of a record, or, in an Initial, the identifier that
// gave the Initial keys of a record. other_remote: a record has the
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

// server_work_take takes one unit of a shared budget: false when the
// budget is spent, and the datagram is dropped before any cryptography.
@(private)
server_work_take :: proc "contextless" (server: ^Server, work: Server_Work, now: u64) -> bool {
	rate, depth: int
	switch work {
	case .Retry:
		rate, depth = server.limits.retries_per_second, server.limits.retries_depth
	case .Token_Check:
		rate, depth = server.limits.token_checks_per_second, server.limits.token_checks_depth
	case .Initial_Check:
		rate, depth = server.limits.initial_checks_per_second, server.limits.initial_checks_depth
	}
	if !work_bucket_take(&server.work_buckets[work], rate, depth, now) {
		server.counters.over_budget += 1
		return false
	}
	return true
}

// server_new_connection answers an Initial with an unknown identifier: a
// Retry when it has no token; a free record when its token opens and did
// not take a record before, under the limits, and when the Initial opens.
// The limits that need no cryptography come before the open of the
// Initial: an address whose token is valid cannot spend the shared budget
// of Initial checks with Initials that the limits refuse. It gives the
// record or -1, and the length of an answer in answer.
@(private)
server_new_connection :: proc "contextless" (server: ^Server, datagram: []u8, header: ^Packet_Header, remote: Remote, answer: []u8, now: u64) -> (index: int, answer_length: int) {
	if len(datagram) < SMALLEST_MAX_UDP_PAYLOAD_SIZE || header.destination_connection_id_length < CONNECTION_ID_SIZE {
		server.counters.too_small += 1
		return -1, 0
	}
	if header.token_length == 0 {
		return -1, server_retry(server, header, remote, answer, now)
	}
	if !server_work_take(server, .Token_Check, now) {
		return -1, 0
	}
	error: errors.Error_Record
	facts: Retry_Token_Facts
	if !retry_token_open(server.cryptography, &server.retry_key, datagram[header.token_offset:][:header.token_length], remote, now, &facts, &error) {
		if error.kind == i64(errors.Kind.Out_Of_Range) {
			server.counters.tokens_expired += 1
		} else {
			server.counters.tokens_refused += 1
		}
		return -1, 0
	}
	// The client sends to the identifier that the Retry named, and to no
	// other: one token gives the Initial keys of one identifier.
	if !bytes_equal(header.destination_connection_id[:header.destination_connection_id_length], facts.retry_source_connection_id[:]) {
		server.counters.tokens_refused += 1
		return -1, 0
	}
	if server_token_was_used(server, facts.counter) {
		server.counters.tokens_used_again += 1
		return -1, 0
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
		return -1, 0
	case handshakes >= server.limits.handshakes_at_once:
		server.counters.refused_handshake_limit += 1
		return -1, 0
	case free < 0:
		server.counters.refused_full += 1
		return -1, 0
	}
	switch server_address_budget_take(server, remote.address, now) {
	case .Taken:
	case .Over_Budget:
		server.counters.over_address_budget += 1
		return -1, 0
	case .Table_Full:
		server.counters.address_table_full += 1
		return -1, 0
	}
	if !server_work_take(server, .Initial_Check, now) {
		return -1, 0
	}
	if !server_initial_is_authentic(server, datagram, header) {
		server.counters.not_authentic += 1
		return -1, 0
	}
	connection := &server.connections[free]
	streams_of_place := server.streams[free * server.streams_per_connection:][:server.streams_per_connection]
	if !connection_start_server(connection, streams_of_place, &server.configuration, server.cryptography, server.generator, now, &error) {
		return -1, 0
	}
	// The record of a client that came back with its token: its address is
	// valid (RFC 9000, section 8.1.2), and its transport parameters name
	// the identifier that it chose first and the identifier of the Retry.
	connection.address_validated = true
	connection.retried = true
	connection.retry_first_destination_connection_id_length = copy(connection.retry_first_destination_connection_id[:], facts.original_destination_connection_id[:facts.original_destination_connection_id_length])
	connection.retry_source_connection_id_length = copy(connection.retry_source_connection_id[:], facts.retry_source_connection_id[:])
	connection_datagram_receive(connection, datagram, now, &error)
	if !connection.tls_started {
		// It opened on the copy: this does not happen, but a record that
		// did not take the packet is not kept.
		connection.state = .Closed
		return -1, 0
	}
	server.next_generation += 1
	server.records[free] = {in_use = true, remote = remote, started_at = now, generation = server.next_generation}
	server_token_mark_used(server, facts.counter, facts.issued_at, now)
	server.counters.accepted += 1
	return free, 0
}

// server_retry writes a Retry packet for an Initial with no token, within
// the budget of Retries. The server keeps nothing: the token holds what
// it needs when the client comes back. It gives the length, or 0.
@(private)
server_retry :: proc "contextless" (server: ^Server, header: ^Packet_Header, remote: Remote, answer: []u8, now: u64) -> int {
	if !server_work_take(server, .Retry, now) {
		return 0
	}
	error: errors.Error_Record
	facts := Retry_Token_Facts{issued_at = now}
	facts.original_destination_connection_id_length = copy(facts.original_destination_connection_id[:], header.destination_connection_id[:header.destination_connection_id_length])
	if !random.fill_for_a_key(server.generator, facts.retry_source_connection_id[:], server.configuration.tls.least_seed_strength, &error) {
		return 0
	}
	token: [RETRY_TOKEN_SIZE]u8
	server.token_counter += 1
	if !retry_token_make(server.cryptography, &server.retry_key, server.token_counter, remote, &facts, &token, &error) {
		return 0
	}
	length, ok := retry_packet_write(server.cryptography, answer, 0, header.source_connection_id[:header.source_connection_id_length], facts.retry_source_connection_id[:], token[:], facts.original_destination_connection_id[:facts.original_destination_connection_id_length], &error)
	if !ok {
		return 0
	}
	server.counters.retries += 1
	return length
}

// server_initial_is_authentic opens a second copy of the first packet of a
// datagram with the Initial keys of its Destination Connection ID. The
// datagram copy is not changed: the record that takes it opens it again.
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
