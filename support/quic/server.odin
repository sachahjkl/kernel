package quic

// A QUIC server with several connections (docs/QUIC.md, section 6): a table of
// `Connection` records in memory of the caller, and the choice of the record
// of each datagram that arrives.
//
// One program serves many clients on one UDP port. The server of this file
// reads the header of each datagram, finds the record that it belongs to, or
// decides if a new client gets a record. Most of it is defence: a datagram can
// carry any source address, so the server spends no memory and little work on
// a client until the client proved its address.
//
// **What the caller does.** The server never touches the network. The caller
// gives each datagram with the address and the port of its remote, sends each
// answer and each datagram that the server gives to the remote that it names,
// marks the remotes that the server validated (the command Validate of a UDP
// listen grant), and releases the remotes that the server no longer needs (the
// command Release). One turn of its loop:
//
// 1. `server_batch_order`, then `server_datagram_receive` for each datagram
//   that arrived; act on each `Server_Outcome`.
// 2. `server_time_passes`.
// 3. `server_datagram_send` until it gives 0.
// 4. `server_sweep`; release the remotes that it gives.
// 5. Wait for a datagram, at most until `server_deadline`.
//
// **The rules of a new connection:**
//
// - The server copies each datagram once into its own memory, and decides on
//   that copy only.
// - A datagram goes to a record by its Destination Connection ID and its
//   remote: the identifier of the server, or, in an Initial, the identifier that
//   gave the Initial keys of the record. A known identifier from another remote
//   is dropped: a client of this server does not move (the server sends
//   disable_active_migration), and a NAT that changes the address or the port of
//   a client ends its connection.
// - An Initial with an unknown identifier and no token gets a Retry packet
//   (`retry.odin`), and the server keeps nothing: no record, no key.
// - An Initial with a token takes a free record only when its token opens for
//   its remote (the client proved its address), when the token did not take a
//   record before, under the limits (connections of one remote address,
//   handshakes of one remote address, handshakes at once, a free record, the
//   budget of Initial checks of the address), and when the Initial itself opens.
//   Each limit that needs no cryptography is checked before the Initial is
//   opened. Over a limit it gets no answer: the client tries again.
// - The work of datagrams of unknown identifiers has budgets
//   (`server_budgets.odin`): Retries, token checks, Initial checks, and the
//   Initial checks of one address. Over a budget such a datagram is dropped
//   before any cryptography. The datagrams of known records have no budget
//   (`server_batch_order` lets the caller give them first).
// - A record whose address the server validated asks the caller to validate
//   its remote at each datagram, until the caller confirms that the network
//   service took it (`server_validation_confirmed`).
// - A long header of another version gets one Version Negotiation packet, at
//   most a fixed count in each second.
// - The stateless reset is not done.

import "contract:errors"
import "support:random"

// The limits of a server: how many records one remote address can hold, and
// the budgets of the work of new connections.
//
// The caller gives them to `server_init`, and they do not change after.
// `SERVER_LIMITS_DEFAULT` holds the values of `quic_echo`, with the reason of
// each one. A limit of records is a count; a budget of work is a pair, a rate
// in each second and a depth (`Work_Bucket`).
Server_Limits :: struct {
	connections_per_remote_address:  int, // The most records that one remote address holds, on all its ports: one host cannot take the whole table.
	handshakes_per_remote_address:   int, // The most records in the handshake that one remote address holds: a host that starts handshakes and never ends them holds this many records, each until its handshake deadline.
	handshakes_at_once:              int, // The most records in the handshake, for all remotes: the other records stay for connections that completed.
	version_negotiations_per_second: int, // The most Version Negotiation packets that the server writes in one second of the clock: the others are dropped and counted.
	// The budgets of work: each one a rate in each second and a depth, the
	// most units that a burst takes at once (server_budgets.odin).
	retries_per_second:                    int, // The rate of the budget of Retries: the Retry packets that the server writes in each second, for Initial packets with no token.
	retries_depth:                         int, // The depth of the budget of Retries: the most Retries of one burst.
	token_checks_per_second:               int, // The rate of the budget of token checks: the Retry tokens that the server opens in each second.
	token_checks_depth:                    int, // The depth of the budget of token checks.
	initial_checks_per_second:             int, // The rate of the shared budget of Initial checks: the Initial packets with a valid token that the server opens in each second, for all addresses.
	initial_checks_depth:                  int, // The depth of the shared budget of Initial checks.
	initial_checks_per_address_per_second: int, // The rate of the budget of Initial checks of one address whose token opened (`SERVER_ADDRESS_BUDGETS`): it is taken before the shared budget.
	initial_checks_per_address_depth:      int, // The depth of the budget of Initial checks of one address: the Initial packets that a new client can have opened at once.
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

// The remote of a datagram: the address and the port that it came from, or
// that it goes to.
//
// The server does not interpret the two values: it compares them, and seals
// them into a Retry token. The caller gives them as its endpoint gave them,
// and gets them back in the same form from `server_datagram_send` and
// `server_sweep`.
Remote :: struct {
	address: u32, // The IPv4 address of the remote, as 32 bits. The limits of one remote address and the table of address budgets compare it alone.
	port:    u16, // The UDP port of the remote. A record belongs to one address and one port.
}

// The facts of one record that the `Connection` does not hold: who its client
// is, and what the caller still owes it.
//
// The caller gives a table of them to `server_init`, with one place for each
// `Connection`: the record at a place describes the connection at the same
// place. The caller reads the fields and writes none.
Server_Record :: struct {
	in_use:     bool, // The place holds a client. false: the place is free, and its `Connection` has no meaning.
	remote:     Remote, // The address and the port of the client: the server sends to it, and takes the datagrams of the record only from it.
	started_at: u64, // When the record was taken, in microseconds.
	generation: u64, // A new value each time that the record is taken, never 0: the caller tells two clients of one place apart. A program ties its own state of a place to it, so a new client never takes the state of the client before.
	// The caller confirmed that the network service validated the remote (the
	// command Validate gave 1). Until then each datagram of a record whose address
	// is validated asks the caller to validate the remote: a Validate that came
	// after the network service forgot the remote gives 0, and a later one, after
	// a datagram admitted it again, works.
	validation_confirmed: bool,
}

// What the server counts: the work that a flood costs is visible.
//
// Each counter only grows, from `server_init`. A program logs them or shows
// them, and a test reads them to prove which rule dropped a datagram.
Server_Counters :: struct {
	accepted:                     u64, // Records taken: an Initial with a valid token that passed each limit and opened.
	ended:                        u64, // Records freed by `server_sweep`.
	datagrams:                    u64, // Datagrams given to `server_datagram_receive`, of every kind.
	unreadable:                   u64, // Datagrams over `DATAGRAM_LIMIT`, or whose first header does not read.
	retries:                      u64, // Retry packets written: Initials with no token, within the budget of Retries.
	tokens_refused:               u64, // Tokens that do not open for their remote, or that name another identifier than the one that the Initial uses.
	tokens_expired:               u64, // Tokens older than their lifetime, or of a time to come.
	not_authentic:                u64, // Initials with a valid token that do not open with the Initial keys of their identifier.
	too_small:                    u64, // Initials of an unknown identifier in a datagram under 1200 bytes or with an identifier under 8 bytes, and long headers of another version in a datagram under 1200 bytes: no answer.
	// The Initials refused by a limit: each datagram counts, so a client
	// that waits for its turn counts again at each try.
	refused_remote_limit:         u64, // Initials refused because their remote address holds its most records, or its most records in the handshake.
	refused_handshake_limit:      u64, // Initials refused because `handshakes_at_once` records are in the handshake.
	refused_full:                 u64, // Initials refused because no record is free.
	over_budget:                  u64, // Datagrams of unknown identifiers dropped over a shared budget (Retries, token checks, Initial checks), before any cryptography.
	over_address_budget:          u64, // Initials with a valid token dropped over the budget of Initial checks of their address, before the Initial is opened.
	address_table_full:           u64, // Initials with a valid token of a new address, dropped because no place of the table of address budgets was free or full again.
	tokens_used_again:            u64, // A valid token whose record was taken before.
	used_tokens_forgotten:        u64, // A used token that the full table forgot before it expired: it can take a record again.
	other_remote:                 u64, // A known identifier from another remote.
	no_connection:                u64, // A packet that is not an Initial, for no record.
	version_negotiations:         u64, // Version Negotiation packets written.
	version_negotiations_dropped: u64, // Long headers of another version that got no answer: over the count of the second.
	authenticity_checks:          u64, // Initials opened on a copy: the most costly work of a new connection, about 11 exports of the cryptography module each.
}

// What one datagram asks of the caller: the result of
// `server_datagram_receive`.
//
// The server cannot send, validate or release by itself, so it says what to
// do. The order matters: the caller sends the answer, then validates, then
// releases.
//
// ```odin
// outcome := quic.server_datagram_receive(&server, bytes, remote, answer, now)
// if outcome.answer_length > 0 {
// 	// ... send answer[:outcome.answer_length] to remote ...
// }
// if outcome.validate_remote && outcome.record >= 0 {
// 	// ... the command Validate for remote ...
// }
// if outcome.release_remote {
// 	// ... the command Release for remote ...
// }
// ```
Server_Outcome :: struct {
	record:          int, // The place of the record that took the datagram: an existing connection, or a record that a new client just took. -1: no record took it.
	answer_length:   int, // The bytes of a Retry or of a Version Negotiation packet that the server wrote in the answer buffer, for the remote of the datagram. 0: no answer.
	validate_remote: bool, // The remote proved its address: the caller marks it validated at the network service, before it sends the datagrams of the record, and gives the result to `server_validation_confirmed`. It is asked again at each datagram of the record until a result confirms it.
	release_remote:  bool, // The server keeps nothing of this remote: the caller releases it at the network service, after it sent the answer, so that a flood does not fill the admitted remotes.
}

// The kinds of work of new connections that have a shared budget: one
// `Work_Bucket` for each, in `Server.work_buckets`.
Server_Work :: enum u8 {
	Retry, // One Retry packet written for an Initial with no token: a token sealed and a Retry Integrity Tag.
	Token_Check, // One Retry token opened.
	Initial_Check, // One Initial packet opened on a copy, after its token opened: the Initial keys derived, the header protection removed, the payload opened.
}

// A QUIC server of several connections: the tables of the caller, the limits,
// the budgets and the counters.
//
// The record has about 40 KiB, mostly the table of address budgets: it goes in
// the global memory of the program or in a mapping, never on a stack. The
// connection records, the server records and the stream records are tables of
// the caller, which `server_init` ties to it. One thread uses a server at a
// time. A caller reads `connections`, `records` and `counters`, and writes no
// field.
Server :: struct {
	connections:        []Connection, // The connection records: memory of the caller, a mapping, never a stack. The connection at a place belongs to the server record at the same place.
	records:            []Server_Record, // The server records, one for each connection record: memory of the caller.
	streams:            []Stream, // The stream records of every connection: memory of the caller, `streams_per_connection` for each connection, in the order of the connections.
	streams_per_connection: int, // The stream records of one connection: the streams that one client has open at one time.
	configuration:      Connection_Configuration, // The configuration of each connection, with the role of a server: it holds the private key of the server for the life of the server.
	cryptography:       ^Cryptography, // The cryptography module of the program: each connection uses it too.
	generator:          ^random.Generator, // The random generator of the thread: the key of the tokens, the identifier of each Retry and the identifiers of the connections come from it.
	limits:             Server_Limits, // The limits and the budgets that `server_init` got.
	counters:           Server_Counters, // What the server counted since `server_init`.
	send_next:          int, // The place of the record that sends first at the next call of `server_datagram_send`: each record gets its turn.
	next_generation:    u64, // The generation of the record taken last: the next one gets this value plus 1.
	negotiation_second: u64, // The second of the clock in which the last Version Negotiation packet was asked for.
	negotiation_count:  int, // The Version Negotiation packets written in that second.
	work_buckets:       [Server_Work]Work_Bucket, // The shared budgets of work: one token bucket for each kind of work.
	address_budgets:    [SERVER_ADDRESS_BUDGETS]Server_Address_Budget, // The table of address budgets: the Initial checks of each address whose token opened.
	used_tokens:        [SERVER_USED_TOKENS]Server_Used_Token, // The Retry tokens that took a record, kept for their lifetime: each token takes a record once.
	retry_key:          [RETRY_TOKEN_KEY_SIZE]u8, // The key that seals the Retry tokens, made at `server_init` from the generator: the tokens of another start of the server do not open.
	token_counter:      u64, // The count of tokens made: the nonce of each token, never used two times with one key.
	datagram_copy:      [DATAGRAM_LIMIT]u8, // Private memory: the copy of the datagram, on which each decision is taken. The record that takes the datagram opens these same bytes.
	authenticity_copy:  [DATAGRAM_LIMIT]u8, // Private memory: a second copy, which the check of an Initial changes when it removes the header protection, so that `datagram_copy` stays as it came.
}

// server_init prepares a server over the memory of the caller, and makes the
// key of its Retry tokens.
//
// **Parameters**
//
// - `server`: the record. Memory of the caller, never a stack.
// - `connections`: one `Connection` for each client that the server holds at
//   one time. A mapping, never a stack.
// - `records`: one `Server_Record` for each connection: the same count.
// - `streams`: the stream records of all connections in one table: the same
//   count for each connection, at least one. It is the count of streams that one
//   client may open at one time.
// - `configuration`: the configuration of each connection: the Ed25519 private
//   key of the server, its application protocol, its least seed strength, its
//   idle timeout. The server copies it and sets the role.
// - `cryptography`, `generator`: the cryptography module of the program and
//   the random generator of the thread. The server keeps both pointers.
// - `limits`: the limits and the budgets, for example `SERVER_LIMITS_DEFAULT`.
// - `error`: the error record that a failure writes.
//
// **Result**: true when the server is ready: each record is free, each counter
// and each budget is new. false: `error` says why, and the server must not be
// used.
//
// **Errors**
//
// - `Bad_Value`, argument 2: no connection, or the count of `records` is not
//   the count of `connections`.
// - `Bad_Value`, argument 4: fewer stream records than connections, or a count
//   that is not a multiple of the connections.
// - `Empty`, argument 5, in milliseconds: the idle timeout of the
//   configuration is 0. A record of a server always has a bound: with no idle
//   timeout on either side, a client that vanishes while the server has a packet
//   in flight would keep its record for ever.
// - `Bad_Value`, argument 5: the least seed strength of the configuration is
//   under `.Processor`.
// - The error of `random.fill_for_a_key`: the seed of the generator is weaker
//   than the least seed strength, so the server makes no key.
//
// ```odin
// if !quic.server_init(&server, connections, records[:], streams, &configuration, &cryptography, &generator, quic.SERVER_LIMITS_DEFAULT, &error) {
// 	// ... report the error: the server listens on nothing ...
// }
// ```
server_init :: proc "contextless" (server: ^Server, connections: []Connection, records: []Server_Record, streams: []Stream, configuration: ^Connection_Configuration, cryptography: ^Cryptography, generator: ^random.Generator, limits: Server_Limits, error: ^errors.Error_Record) -> bool {
	if len(connections) == 0 || len(connections) != len(records) {
		errors.fail(error, -1, .Bad_Value, .Records, 2, i64(len(records)), i64(len(connections)), 0)
		return false
	}
	if len(streams) < len(connections) || len(streams) % len(connections) != 0 {
		errors.fail(error, -1, .Bad_Value, .Records, 4, i64(len(streams)), i64(len(connections)), 0)
		return false
	}
	if configuration.idle_timeout_milliseconds == 0 {
		// A record of a server always has a bound: with no idle timeout on
		// either side, a client that vanishes while the server has a packet
		// in flight keeps the record for ever, and the server probes it.
		errors.fail(error, -1, .Empty, .Milliseconds, 5, 0, i64(VARIABLE_LENGTH_INTEGER_LARGEST), 0)
		return false
	}
	server.streams = streams
	server.streams_per_connection = len(streams) / len(connections)
	if !connection_seed_strength_check(configuration, 5, error) {
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

// One datagram of a batch that arrived together, with its remote: an item of
// the batch that `server_batch_order` reads.
Server_Datagram :: struct {
	bytes:  []u8, // The bytes of the datagram, where the caller received them: they are read in place, not copied.
	remote: Remote, // The address and the port that the datagram came from.
}

// server_batch_order gives the order in which the caller gives a batch of
// datagrams to `server_datagram_receive`: first each datagram that goes to a
// record, then the others, each group in the order of arrival.
//
// The budgets of work protect the processor, not the clients that are already
// connected: under a flood, a datagram of a connection that works must not
// wait behind a thousand datagrams of unknown senders. With this order, the
// connections that exist are served first, whatever the count of the others.
//
// - `batch`: the datagrams that arrived together, each with its remote.
// - `order`: where the order goes: indexes of `batch`. Give it the length of
//   the batch.
//
// **Result**: the count of indexes written, the smaller of `len(batch)` and
// `len(order)`. `order` holds each index below that count once.
//
// The header of each datagram is read once, before any datagram is given: a
// datagram that a record would take only after an earlier datagram of the
// batch took that record is in the second group, and is given all the same.
//
// The order is a priority, not a decision of security: it reads the header in
// place, with no copy. If the bytes change under it, a datagram is only given
// earlier or later; `server_datagram_receive` decides on its own copy.
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

// server_validation_confirmed takes the result of the Validate that the caller
// sent for the record at a place: the server then stops asking for it.
//
// - `place`: the place of the record that `Server_Outcome.validate_remote`
//   named.
// - `generation`: the generation of the record when the caller sent the
//   Validate. If the record ended since and the place was taken again, the
//   result is of another client and confirms nothing.
// - `validated`: true when the network service validated the remote.
//
// With true, each record of that remote is confirmed. A result of false
// changes nothing: the next datagram of the record asks again, because the
// network service can have forgotten the remote before the Validate came, and
// admits it again at the next datagram.
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
// answers it, under the limits and the budgets.
//
// **Parameters**
//
// - `received`: the bytes of one UDP datagram.
// - `remote`: the address and the port that it came from.
// - `answer`: where a Retry or a Version Negotiation packet goes: the caller
//   sends it to `remote`. With too little room for an answer, none is written.
// - `now`: the time, in microseconds.
//
// **Result**: a `Server_Outcome`: the record that took the datagram, the
// length of an answer, and whether the caller validates or releases the
// remote.
//
// **What happens to a datagram**
//
// 1. It is copied into the memory of the server. A datagram that is too long,
//   or whose header does not read, is dropped.
// 2. When its Destination Connection ID and its remote name a record, the
//   record takes it (`connection_datagram_receive`), with no budget.
// 3. A known identifier from another remote is dropped.
// 4. A long header of another version gets a Version Negotiation packet
//   (`server_version_negotiation`).
// 5. An Initial of an unknown identifier gets a Retry, or takes a record when
//   its token is valid (`server_new_connection`).
// 6. Any other packet of an unknown identifier is dropped: the server has no
//   stateless reset.
//
// Each datagram that leaves nothing in the server asks the caller to release
// its remote, unless a record has that remote.
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

// server_record_of finds the record of a packet by its Destination Connection
// ID and its remote.
//
// The identifier is the one that the server chose for a record, or, in an
// Initial, the identifier that gave the Initial keys of a record: a client
// uses that one until it learns the identifier of the server.
//
// **Results**: `index`, the place of the record, or -1. `other_remote` is true
// when a record has the identifier and another remote: the datagram is then
// dropped, because a client of this server does not move.
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

// server_remote_has_record says if a record in use has a remote, address and
// port: the server then keeps something of it, and the caller must not release
// it.
@(private)
server_remote_has_record :: proc "contextless" (server: ^Server, remote: Remote) -> bool {
	for record in server.records {
		if record.in_use && record.remote == remote {
			return true
		}
	}
	return false
}

// server_work_take takes one unit of a shared budget of work, with the rate
// and the depth of its kind from the limits.
//
// It gives false when the budget is spent: the datagram is dropped before any
// cryptography, and `Server_Counters.over_budget` counts it.
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

// server_new_connection answers an Initial with an unknown identifier: a Retry
// when it has no token; a free record when its token opens and did not take a
// record before, under the limits, and when the Initial opens.
//
// The checks go from the cheapest to the most costly, and each one that fails
// ends with no answer and one counter:
//
// 1. The datagram has 1200 bytes at least, and the identifier 8 bytes at least
//   (`too_small`).
// 2. With no token: a Retry, within the budget of Retries (`server_retry`).
// 3. The budget of token checks, then the token opens for this remote and is
//   not too old (`tokens_refused`, `tokens_expired`).
// 4. The token names the identifier that the Initial uses (`tokens_refused`),
//   and did not take a record before (`tokens_used_again`).
// 5. The limits of records: connections and handshakes of the remote address,
//   handshakes at once, a free record (`refused_remote_limit`,
//   `refused_handshake_limit`, `refused_full`).
// 6. The budget of Initial checks of the address (`over_address_budget`,
//   `address_table_full`), then the shared budget (`over_budget`).
// 7. The Initial opens on a second copy (`not_authentic`).
//
// The limits that need no cryptography come before the open of the Initial: an
// address whose token is valid cannot spend the shared budget of Initial
// checks with Initials that the limits refuse.
//
// The record that is taken starts with its address validated, since the token
// came back to it (RFC 9000, section 8.1.2), and with the two identifiers of
// the Retry for its transport parameters. It gets a new generation, and the
// token is noted as used.
//
// **Results**: `index`, the place of the record, or -1; `answer_length`, the
// bytes of a Retry in `answer`, or 0.
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

// server_retry writes a Retry packet for an Initial with no token, within the
// budget of Retries (RFC 9000, section 8.1.2).
//
// The server keeps nothing: the token holds what it needs when the client
// comes back. It seals the identifier that the client chose, a new random
// identifier that the client must send to next, and the time, bound to the
// address and the port of the remote (`retry_token_make`). Only a host that
// receives at that address can send the token back.
//
// It gives the length of the packet in `answer`, or 0: the budget is spent,
// the generator or the cryptography module failed, or `answer` is too short.
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

// server_initial_is_authentic says if the first packet of a datagram opens
// with the Initial keys of its Destination Connection ID.
//
// It works on a second copy, because the removal of the header protection
// changes the bytes: the datagram copy is not changed, and the record that
// takes it opens it again. The check comes before the server takes a record,
// so a datagram that does not open costs the work and no memory. The keys are
// erased after it.
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

// server_version_negotiation writes one Version Negotiation packet (RFC 9000,
// section 17.2.1) for a long header of another version.
//
// The packet tells a client which version this server speaks: it lists the
// version 1 alone. It answers only a datagram of 1200 bytes at least (RFC
// 9000, section 6.1: a smaller one may not be the start of a connection), at
// most `version_negotiations_per_second` in each second of the clock. The
// packet has 51 bytes at most for 1200 received: far under the
// anti-amplification limit. It carries the two connection identifiers of the
// datagram, exchanged.
//
// It gives the length of the packet in `answer`, or 0: the datagram is too
// small, the count of the second is spent, or `answer` is too short.
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

// server_datagram_send writes the next datagram of a record in `buffer`, and
// gives it with its remote.
//
// - `buffer`: where the datagram goes: `MAX_DATAGRAM_SIZE` bytes.
// - `now`: the time, in microseconds.
//
// **Results**: `length`, the bytes of the datagram, and `remote`, where the
// caller sends it. A length of 0 says that no record has a datagram now.
//
// Each call starts at the record after the one that sent last, so a record
// with much to send does not hold back the others. The caller calls it until
// it gives 0.
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

// server_deadline gives the earliest deadline of the records in use, in
// microseconds: the time until which the caller waits for a datagram before it
// calls `server_time_passes`. `NO_DEADLINE` when no record has a timer.
server_deadline :: proc "contextless" (server: ^Server) -> u64 {
	deadline := NO_DEADLINE
	for record, place in server.records {
		if record.in_use {
			deadline = min(deadline, connection_deadline(&server.connections[place]))
		}
	}
	return deadline
}

// server_time_passes acts on each deadline that passed: it calls
// `connection_time_passes` for each record in use whose deadline is at or
// before `now`.
//
// It sends nothing and frees nothing. After it the caller calls
// `server_datagram_send` for the probes, and `server_sweep` for the
// connections that ended.
server_time_passes :: proc "contextless" (server: ^Server, now: u64) {
	for record, place in server.records {
		if record.in_use && connection_deadline(&server.connections[place]) <= now {
			connection_time_passes(&server.connections[place], now)
		}
	}
}

// server_sweep frees each record whose connection ended, and writes its remote
// in `released` when no other record has it: the caller releases them.
//
// - `released`: where the remotes go. Give it one place for each record, so
//   that one call frees each record that ended. A record whose remote has no
//   place left is not freed in this call: it stays in use, and the next call
//   frees it and gives its remote. No remote is lost. With no place at all, a
//   record whose remote must be released is never freed.
//
// **Result**: the count of remotes written.
//
// A record ends after its closing or draining time, so its last datagram went
// before. A program reads what it wants of an ended connection (why it ended,
// its counts) before this call: after it the place can go to a new client.
server_sweep :: proc "contextless" (server: ^Server, released: []Remote) -> int {
	count := 0
	for &record, place in server.records {
		if !record.in_use || server.connections[place].state != .Closed {
			continue
		}
		record.in_use = false
		if !server_remote_has_record(server, record.remote) {
			if count >= len(released) {
				// The caller must release this remote, and has no place to
				// learn it now: the record waits for the next call.
				record.in_use = true
				continue
			}
			released[count] = record.remote
			count += 1
		}
		server.counters.ended += 1
	}
	return count
}

// server_connections_in_use counts the records in use: the clients that the
// server holds now, in any state until `server_sweep` frees them.
server_connections_in_use :: proc "contextless" (server: ^Server) -> int {
	count := 0
	for record in server.records {
		if record.in_use {
			count += 1
		}
	}
	return count
}
