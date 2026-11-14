#+build !freestanding
// Retry on the host: the packet of RFC 9001, appendix A.4, byte for byte; a
// client through a Retry; the tokens that must not open; the Retries that a
// client must refuse; the budgets of the work of a server; the answers of
// the closing state.
package quic

import "contract:errors"
import "core:testing"

// RFC 9001, appendix A.4: retry_packet_write gives the Retry packet of the
// RFC, byte for byte: to an empty Destination Connection ID, from the
// identifier f067a5502a4262b5, the token "token", the tag over the
// original identifier 8394c8f03e515708, and the 4 unused bits 1111.
@(test)
retry_packet_of_rfc_9001_appendix_a_4 :: proc(t: ^testing.T) {
	cryptography := module_cryptography()
	error: errors.Error_Record
	buffer: [MAX_DATAGRAM_SIZE]u8
	token := "token"
	length, ok := retry_packet_write(&cryptography, buffer[:], 0x0F, nil, bytes_of("f067a5502a4262b5"), transmute([]u8)token, bytes_of(ORIGINAL_DESTINATION_CONNECTION_ID), &error)
	testing.expectf(t, ok, "%v", error)
	testing.expect_value(t, hex_of(buffer[:length]), RETRY_PACKET)
}

// A client connects through a Retry: one Retry, a record with the
// identifiers of the Retry in its transport parameters, which the client
// checks, and an echo.
@(test)
a_client_connects_through_a_retry :: proc(t: ^testing.T) {
	harness := harness_make(1)
	defer harness_free(harness)
	testing.expectf(t, harness.clients_not_started == 0, "%s", harness_describe(harness))
	ended := harness_run(t, harness, 4096, 10_000_000)
	testing.expectf(t, ended == 1, "%s", harness_describe(harness))
	client := &harness.clients[0]
	record := &harness.connections[0]
	testing.expectf(t, harness.server.counters.retries == 1 && harness.server.counters.accepted == 1, "%s", harness_describe(harness))
	testing.expect(t, client.retried && record.retried)
	testing.expect(t, client.peer_parameters_applied && client.peer_parameters.has_retry_source_connection_id)
	testing.expect(t, bytes_equal(client.peer_parameters.original_destination_connection_id[:client.peer_parameters.original_destination_connection_id_length], client.retry_first_destination_connection_id[:client.retry_first_destination_connection_id_length]))
	testing.expect(t, record.address_validated)
}

// The tokens that must not open: another address, another port, each byte
// changed, a time older than the lifetime, a time to come, another key. The
// token of the right remote, in time, opens with its facts.
@(test)
retry_tokens_that_do_not_open :: proc(t: ^testing.T) {
	cryptography := module_cryptography()
	error: errors.Error_Record
	key: [RETRY_TOKEN_KEY_SIZE]u8
	key[0] = 7
	remote := Remote{0x0A00_0302, 50_000}
	facts := Retry_Token_Facts{issued_at = 5_000_000}
	facts.original_destination_connection_id_length = copy(facts.original_destination_connection_id[:], bytes_of(ORIGINAL_DESTINATION_CONNECTION_ID))
	copy(facts.retry_source_connection_id[:], bytes_of("0102030405060708"))
	token: [RETRY_TOKEN_SIZE]u8
	testing.expect(t, retry_token_make(&cryptography, &key, 1, remote, &facts, &token, &error))
	opened: Retry_Token_Facts
	testing.expect(t, retry_token_open(&cryptography, &key, token[:], remote, 6_000_000, &opened, &error))
	testing.expect(t, opened.issued_at == facts.issued_at && opened.retry_source_connection_id == facts.retry_source_connection_id)
	testing.expect_value(t, hex_of(opened.original_destination_connection_id[:opened.original_destination_connection_id_length]), ORIGINAL_DESTINATION_CONNECTION_ID)
	testing.expect(t, !retry_token_open(&cryptography, &key, token[:], {0x0A00_0303, 50_000}, 6_000_000, &opened, &error))
	testing.expect(t, !retry_token_open(&cryptography, &key, token[:], {0x0A00_0302, 50_001}, 6_000_000, &opened, &error))
	for index in 0 ..< RETRY_TOKEN_SIZE {
		changed := token
		changed[index] ~= 0x01
		testing.expectf(t, !retry_token_open(&cryptography, &key, changed[:], remote, 6_000_000, &opened, &error), "the byte %d changed: the token opened", index)
	}
	testing.expect(t, !retry_token_open(&cryptography, &key, token[:], remote, 5_000_000 + RETRY_TOKEN_LIFETIME + 1, &opened, &error))
	testing.expect_value(t, error.kind, i64(errors.Kind.Out_Of_Range))
	testing.expect(t, !retry_token_open(&cryptography, &key, token[:], remote, 4_000_000, &opened, &error))
	other_key := key
	other_key[1] = 1
	testing.expect(t, !retry_token_open(&cryptography, &other_key, token[:], remote, 6_000_000, &opened, &error))
	testing.expect(t, !retry_token_open(&cryptography, &key, token[:RETRY_TOKEN_SIZE - 1], remote, 6_000_000, &opened, &error))
}

// An Initial that carries a token of the server, at the server: from
// another remote, to another identifier, or too old, it takes no record;
// from its remote, to the identifier of its Retry, in time, it takes one,
// and the remote is to be validated.
@(test)
the_server_checks_each_token :: proc(t: ^testing.T) {
	harness := harness_make(0)
	defer harness_free(harness)
	server := &harness.server
	error: errors.Error_Record
	remote := Remote{0x0A00_0305, 50_000}
	retry_source: [CONNECTION_ID_SIZE]u8 = {9, 9, 9, 9, 9, 9, 9, 1}
	token_for :: proc(harness: ^Harness, remote: Remote, retry_source: [CONNECTION_ID_SIZE]u8, issued_at: u64) -> [RETRY_TOKEN_SIZE]u8 {
		error: errors.Error_Record
		facts := Retry_Token_Facts{issued_at = issued_at, retry_source_connection_id = retry_source}
		facts.original_destination_connection_id_length = copy(facts.original_destination_connection_id[:], bytes_of(ORIGINAL_DESTINATION_CONNECTION_ID))
		token: [RETRY_TOKEN_SIZE]u8
		harness.server.token_counter += 1
		retry_token_make(&harness.cryptography, &harness.server.retry_key, harness.server.token_counter, remote, &facts, &token, &error)
		return token
	}
	answer: [MAX_DATAGRAM_SIZE]u8
	token := token_for(harness, remote, retry_source, harness.now)
	datagram := authentic_initial(&harness.cryptography, retry_source, token[:])
	// Another remote.
	outcome := server_datagram_receive(server, datagram[:], {0x0A00_0306, 50_000}, answer[:], harness.now)
	testing.expectf(t, outcome.record < 0 && server.counters.tokens_refused == 1, "%s", harness_describe(harness))
	// Another identifier than the one of the Retry.
	other_identifier: [CONNECTION_ID_SIZE]u8 = {9, 9, 9, 9, 9, 9, 9, 2}
	other := authentic_initial(&harness.cryptography, other_identifier, token[:])
	outcome = server_datagram_receive(server, other[:], remote, answer[:], harness.now)
	testing.expectf(t, outcome.record < 0 && server.counters.tokens_refused == 2, "%s", harness_describe(harness))
	// Too old.
	old := token_for(harness, remote, retry_source, harness.now)
	old_datagram := authentic_initial(&harness.cryptography, retry_source, old[:])
	outcome = server_datagram_receive(server, old_datagram[:], remote, answer[:], harness.now + RETRY_TOKEN_LIFETIME + 1)
	testing.expectf(t, outcome.record < 0 && server.counters.tokens_expired == 1, "%s", harness_describe(harness))
	// The right one.
	outcome = server_datagram_receive(server, datagram[:], remote, answer[:], harness.now)
	testing.expectf(t, outcome.record == 0 && outcome.validate_remote && !outcome.release_remote && server.counters.accepted == 1, "%s", harness_describe(harness))
	testing.expect(t, harness.connections[0].retried && harness.connections[0].address_validated)
	_ = error
}

// A client takes one Retry only: a Retry with a bad tag, or whose Source
// Connection ID is the identifier that the client chose, changes nothing;
// a second Retry after one is refused.
@(test)
retries_that_a_client_refuses :: proc(t: ^testing.T) {
	harness := harness_make(1)
	defer harness_free(harness)
	testing.expectf(t, harness.clients_not_started == 0, "%s", harness_describe(harness))
	client := &harness.clients[0]
	error: errors.Error_Record
	retry: [MAX_DATAGRAM_SIZE]u8
	token := "a token of the server"
	original := client.original_destination_connection_id
	original_length := client.original_destination_connection_id_length
	first_source := bytes_of("1111111111111111")
	// A bad tag: computed over another original identifier.
	wrong := bytes_of("0000000000000000")
	length, _ := retry_packet_write(&harness.cryptography, retry[:], 0, client.local_connection_id[:], first_source, transmute([]u8)token, wrong, &error)
	connection_datagram_receive(client, retry[:length], harness.now, &error)
	testing.expect(t, !client.retried)
	// A Source Connection ID that is the identifier of the client.
	length, _ = retry_packet_write(&harness.cryptography, retry[:], 0, client.local_connection_id[:], original[:original_length], transmute([]u8)token, original[:original_length], &error)
	connection_datagram_receive(client, retry[:length], harness.now, &error)
	testing.expect(t, !client.retried)
	// A right Retry.
	length, _ = retry_packet_write(&harness.cryptography, retry[:], 0, client.local_connection_id[:], first_source, transmute([]u8)token, original[:original_length], &error)
	connection_datagram_receive(client, retry[:length], harness.now, &error)
	testing.expect(t, client.retried)
	testing.expect_value(t, hex_of(client.retry_token[:client.retry_token_length]), hex_of(transmute([]u8)token))
	testing.expect_value(t, hex_of(client.peer_connection_id[:client.peer_connection_id_length]), "1111111111111111")
	// A second Retry, with a right tag over each identifier that the client
	// had: refused.
	for over in ([][]u8{original[:original_length], first_source}) {
		length, _ = retry_packet_write(&harness.cryptography, retry[:], 0, client.local_connection_id[:], bytes_of("2222222222222222"), transmute([]u8)token, over, &error)
		connection_datagram_receive(client, retry[:length], harness.now, &error)
		testing.expect_value(t, hex_of(client.retry_source_connection_id[:client.retry_source_connection_id_length]), "1111111111111111")
	}
}

// The shared budgets are token buckets. 3000 Initials with no token at one
// time get the depth of 2000 Retries, and 1000 are dropped before any
// cryptography. 1 ms later the bucket gained 20 Retries, not a new second
// of budget: a burst at any time gets the depth and the rate, never twice
// the budget. 100 ms later it is full again. 4000 Initials with tokens
// that do not open cost the depth of 3000 token checks, and no Initial
// check.
@(test)
the_work_of_new_connections_has_token_buckets :: proc(t: ^testing.T) {
	harness := harness_make(0)
	defer harness_free(harness)
	server := &harness.server
	answer: [MAX_DATAGRAM_SIZE]u8
	state: u64 = 0x4255_4447_4554_0001
	start := harness.now
	burst :: proc(server: ^Server, state: ^u64, count: int, first_address: u32, now: u64, answer: []u8) {
		for index in 0 ..< count {
			forged := forged_initial(state)
			server_datagram_receive(server, forged[:], {first_address + u32(index), 40_000}, answer, now)
		}
	}
	burst(server, &state, 3000, 0x0E00_0000, start, answer[:])
	testing.expectf(t, server.counters.retries == 2000 && server.counters.over_budget == 1000, "%s", harness_describe(harness))
	burst(server, &state, 100, 0x0E10_0000, start + 1000, answer[:])
	testing.expectf(t, server.counters.retries == 2020 && server.counters.over_budget == 1080, "%s", harness_describe(harness))
	burst(server, &state, 3000, 0x0E20_0000, start + 101_000, answer[:])
	testing.expectf(t, server.counters.retries == 4020 && server.counters.over_budget == 2080, "%s", harness_describe(harness))
	garbage: [RETRY_TOKEN_SIZE]u8
	garbage[0] = RETRY_TOKEN_FORMAT
	identifier: [CONNECTION_ID_SIZE]u8 = {3, 3, 3, 3, 3, 3, 3, 3}
	datagram := authentic_initial(&harness.cryptography, identifier, garbage[:])
	for index in 0 ..< 4000 {
		server_datagram_receive(server, datagram[:], {u32(0x0F00_0000 + index), 40_000}, answer[:], start + 101_000)
	}
	testing.expectf(t, server.counters.tokens_refused == 3000 && server.counters.over_budget == 3080, "%s", harness_describe(harness))
	testing.expectf(t, server.counters.authenticity_checks == 0, "%s", harness_describe(harness))
}

// A datagram of a known record comes first in the order of a batch, before
// any cryptography; the same bytes from another remote, and a forged
// Initial, come after it.
@(test)
a_datagram_of_a_record_comes_first :: proc(t: ^testing.T) {
	harness := harness_make(1)
	defer harness_free(harness)
	testing.expectf(t, harness_run(t, harness, 1024, 10_000_000) == 1, "%s", harness_describe(harness))
	client := &harness.clients[0]
	buffer: [MAX_DATAGRAM_SIZE]u8
	connection_close(client, 0, harness.now)
	length := connection_datagram_send(client, buffer[:], harness.now)
	testing.expect(t, length > 0)
	state: u64 = 0x4b4e_4f57_4e00_0001
	forged := forged_initial(&state)
	batch := []Server_Datagram{{forged[:], harness.client_remotes[0]}, {buffer[:length], {0x0A00_0399, 1}}, {buffer[:length], harness.client_remotes[0]}}
	order: [3]int
	testing.expect_value(t, server_batch_order(&harness.server, batch, order[:]), 3)
	testing.expect_value(t, order, [3]int{2, 0, 1})
	testing.expect(t, harness.records[0].generation == 1)
}

// The closing state answers the 1st, 2nd, 4th and 8th datagram of the
// peer, not each one: 15 datagrams with its identifier get 4 answers.
// Before, each one got a CONNECTION_CLOSE.
@(test)
the_closing_state_answers_few_datagrams :: proc(t: ^testing.T) {
	endpoints := endpoints_make()
	defer free(endpoints)
	testing.expect(t, endpoints_connect(endpoints))
	client := &endpoints.client
	connection_close(client, 0, endpoints.now)
	buffer: [MAX_DATAGRAM_SIZE]u8
	for connection_datagram_send(client, buffer[:], endpoints.now) > 0 {}
	// A short header with the identifier of the client and 40 bytes.
	datagram: [1 + CONNECTION_ID_SIZE + 40]u8
	datagram[0] = FIXED_BIT | 0x03
	copy(datagram[1:], client.local_connection_id[:])
	answers := 0
	error: errors.Error_Record
	for _ in 0 ..< 15 {
		connection_datagram_receive(client, datagram[:], endpoints.now, &error)
		for connection_datagram_send(client, buffer[:], endpoints.now) > 0 {
			answers += 1
		}
	}
	testing.expect_value(t, answers, 4)
}

// The Retry of the server for a client like the one of OpenSSL, whose own
// connection identifier has 0 bytes, with an original Destination
// Connection ID of 8 bytes and of 20 bytes: the Retry has an empty
// Destination Connection ID, the identifier of the server, the token, and
// a tag that this test computes by the rule of RFC 9001, section 5.8:
// AES-128-GCM with the fixed key and nonce of version 1 (the values of the
// RFC text), an empty text, and as additional data the length of the
// original identifier, its bytes, then the Retry without its tag. The
// client of this system always has 8 bytes: no test had 0 before.
@(test)
a_retry_for_a_client_with_an_empty_identifier :: proc(t: ^testing.T) {
	harness := harness_make(0)
	defer harness_free(harness)
	error: errors.Error_Record
	for original_length in ([]int{8, 20}) {
		datagram: [MAX_DATAGRAM_SIZE]u8
		datagram[0] = LONG_HEADER_FORM | FIXED_BIT | 0x03
		datagram[1], datagram[2], datagram[3], datagram[4] = 0, 0, 0, 1
		datagram[5] = u8(original_length)
		original := datagram[6:][:original_length]
		for &value, index in original {
			value = u8(0xA0 + index)
		}
		at := 6 + original_length
		datagram[at] = 0 // The Source Connection ID of the client: 0 bytes.
		datagram[at + 1] = 0 // No token.
		at += 2
		variable_length_integer_write(datagram[:], at, u64(MAX_DATAGRAM_SIZE - at - 2), 2)
		answer: [MAX_DATAGRAM_SIZE]u8
		outcome := server_datagram_receive(&harness.server, datagram[:], {0x0A00_0202, u16(40_000 + original_length)}, answer[:], harness.now)
		testing.expectf(t, outcome.answer_length > 0 && outcome.record < 0, "%s", harness_describe(harness))
		retry := answer[:outcome.answer_length]
		testing.expect_value(t, len(retry), 1 + 4 + 1 + 0 + 1 + CONNECTION_ID_SIZE + RETRY_TOKEN_SIZE + TAG_SIZE)
		testing.expect_value(t, retry[0] & 0xF0, 0xF0) // Long header, fixed bit, type 3.
		testing.expect_value(t, hex_of(retry[1:5]), "00000001")
		testing.expect_value(t, retry[5], 0) // The empty identifier of the client.
		testing.expect_value(t, retry[6], CONNECTION_ID_SIZE)
		pseudo_packet := make([dynamic]u8, context.temp_allocator)
		append(&pseudo_packet, u8(original_length))
		append(&pseudo_packet, ..original)
		append(&pseudo_packet, ..retry[:len(retry) - TAG_SIZE])
		key, nonce, additional, empty := string(bytes_of("be0c690b9f66575a1d766b54e368c84e")), string(bytes_of("461599d35d632bf2239825bb")), string(pseudo_packet[:]), ""
		tag: [TAG_SIZE]u8
		result := tag[:]
		testing.expect_value(t, harness.cryptography.seal_with_aes_128_gcm(&key, &nonce, &additional, &empty, &result, &error), TAG_SIZE)
		testing.expect_value(t, hex_of(retry[len(retry) - TAG_SIZE:]), hex_of(tag[:]))
		// The reader of a client takes it: the header, then the tag.
		header: Packet_Header
		testing.expectf(t, header_read(retry, 0, 0, &header, &error), "%v", error)
		testing.expect(t, header.type == .Retry && header.destination_connection_id_length == 0 && header.token_length == RETRY_TOKEN_SIZE)
		testing.expectf(t, retry_integrity_check(&harness.cryptography, original, retry, &header, &error), "%v", error)
	}
}
