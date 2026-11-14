#+build !freestanding
package network

import "modus:contract/datagram"
import "core:testing"

// Two endpoints and the machine. Endpoint A has a grant of port 7 and
// received a datagram from port 9; endpoint B has a grant of port 5353 and
// no right Inspect. B must read no row of A and no row of the machine.
@(test)
problem_rows_of_one_endpoint :: proc(t: ^testing.T) {
	a, b, machine: Problem_Table
	problem_count(&a, {kind = .Not_Granted, layer = .Udp, offset = 34, value = 9, limit = 7}, .Endpoint)
	problem_count(&machine, {kind = .No_Endpoint, layer = .Udp, offset = 36, value = 9999}, .Machine)
	problem_count(&machine, {kind = .Bad_Checksum, layer = .Ipv4, offset = 24, value = 1, limit = 2}, .Machine)
	rows: [8]datagram.Problem_Row

	// B, with no row of its own and no right: nothing.
	testing.expect_value(t, problem_rows(&b, &machine, false, rows[:]), 0)
	// B with the right Inspect: the two rows of the machine, never the row of A.
	count := problem_rows(&b, &machine, true, rows[:])
	testing.expect_value(t, count, 2)
	for row in rows[:count] {
		testing.expect_value(t, row.scope, datagram.Problem_Scope.Machine)
		testing.expect(t, row.last.kind != .Not_Granted && row.last.limit != 7)
	}
	// A with no right: its own row only, with the port of its own grant.
	count = problem_rows(&a, &machine, false, rows[:])
	testing.expect_value(t, count, 1)
	testing.expect(t, rows[0].scope == .Endpoint && rows[0].last.kind == .Not_Granted && rows[0].last.limit == 7 && rows[0].count == 1)
	// The count of the full answer when the rows do not fit.
	testing.expect_value(t, problem_rows(&a, &machine, true, rows[:1]), 3)
	testing.expect_value(t, a.count, 1)
	testing.expect_value(t, machine.count, 2)
	// A value that another program wrote does not index outside the table.
	problem_count(&b, {kind = datagram.Problem_Kind(250), layer = datagram.Layer(99)}, .Endpoint)
	testing.expect_value(t, b.rows[.None][.None].count, 1)
}

@(private = "file")
GATEWAY_HARDWARE :: Hardware{0x52, 0x55, 0x0A, 0x00, 0x02, 0x02}
@(private = "file")
OTHER_HARDWARE :: Hardware{0x02, 0, 0, 0, 0, 0x66}

@(test)
neighbors_learn_what_was_asked :: proc(t: ^testing.T) {
	table: Neighbors
	// An answer that no request asked for changes nothing.
	testing.expect_value(t, neighbor_learn(&table, 0x0A000202, GATEWAY_HARDWARE, 1, false, nil), Learned.Not_Asked)
	_, known := neighbor_find(&table, 0x0A000202)
	testing.expect(t, !known)
	testing.expect_value(t, neighbor_learn(&table, 0x0A000202, GATEWAY_HARDWARE, 2, true, nil), Learned.Added)
	// Another machine answers for the gateway, and nobody asked: the entry stays.
	testing.expect_value(t, neighbor_learn(&table, 0x0A000202, OTHER_HARDWARE, 3, false, nil), Learned.Not_Asked)
	found, _ := neighbor_find(&table, 0x0A000202)
	testing.expect(t, found == GATEWAY_HARDWARE)
	// A request asked again (Resolve): the new answer updates it.
	testing.expect_value(t, neighbor_learn(&table, 0x0A000202, OTHER_HARDWARE, 4, true, nil), Learned.Updated)
}

@(test)
neighbors_full_table :: proc(t: ^testing.T) {
	table: Neighbors
	for index in 0 ..< ARP_CAPACITY {
		testing.expect_value(t, neighbor_learn(&table, u32(0x0A000100 + index), GATEWAY_HARDWARE, u64(10 + index), true, nil), Learned.Added)
	}
	// Full: the oldest entry that no request uses goes. Entry 0 (time 10) is
	// in use by a request that waits, so entry 1 (time 11) goes.
	busy := []u32{0x0A000100}
	testing.expect_value(t, neighbor_learn(&table, 0x0A000200, OTHER_HARDWARE, 100, true, busy), Learned.Replaced)
	_, kept := neighbor_find(&table, 0x0A000100)
	_, gone := neighbor_find(&table, 0x0A000101)
	_, added := neighbor_find(&table, 0x0A000200)
	testing.expect(t, kept && !gone && added)
	// Each entry in use: the answer is not taken, and no entry changes.
	all: [ARP_CAPACITY]u32
	for item, index in table {
		all[index] = item.address
	}
	before := table
	testing.expect_value(t, neighbor_learn(&table, 0x0A000300, OTHER_HARDWARE, 200, true, all[:]), Learned.Full)
	testing.expect(t, before == table)
}

// The admitted remotes of a listen grant: a remote is admitted one time,
// a full table refuses a new remote while each place had a segment in the
// last ADMITTED_IDLE, a release frees its place, and the oldest idle place
// serves again.
@(test)
admitted_remotes :: proc(t: ^testing.T) {
	table: Admitted
	for index in 0 ..< datagram.ADMITTED_CAPACITY {
		testing.expect(t, admitted_add(&table, 0x0A000202, u16(40000 + index), u64(1000 + index)))
	}
	testing.expect(t, admitted_add(&table, 0x0A000202, 40000, 2000)) // Already admitted.
	testing.expect(t, !admitted_add(&table, 0x0A000203, 40000, 3000))
	testing.expect(t, admitted_find(&table, 0x0A000202, 40001, 3000))
	testing.expect(t, !admitted_find(&table, 0x0A000203, 40001, 3000))
	testing.expect(t, admitted_release(&table, 0x0A000202, 40001))
	testing.expect(t, !admitted_release(&table, 0x0A000202, 40001))
	testing.expect(t, !admitted_find(&table, 0x0A000202, 40001, 3000))
	testing.expect(t, admitted_add(&table, 0x0A000203, 40000, 3000))
	// Full again. More than ADMITTED_IDLE after the port 40002 (time 1002),
	// it is the only idle place, and the oldest: it serves again.
	testing.expect(t, !admitted_add(&table, 0x0A000204, 1, 4000))
	testing.expect(t, !admitted_add(&table, 0x0A000204, 1, 1002 + ADMITTED_IDLE))
	testing.expect(t, admitted_add(&table, 0x0A000204, 1, 1002 + ADMITTED_IDLE + 1))
	testing.expect(t, !admitted_find(&table, 0x0A000202, 40002, 70_000))
	testing.expect(t, admitted_find(&table, 0x0A000202, 40003, 70_000))
}

@(test)
sources_that_are_refused :: proc(t: ^testing.T) {
	LOCAL :: 0x0A00020F
	MASK :: 0xFFFF_FF00
	testing.expect(t, source_valid(0x0A000202, LOCAL, MASK))
	testing.expect(t, source_valid(0x08080808, LOCAL, MASK))
	testing.expect(t, !source_valid(0, LOCAL, MASK))
	testing.expect(t, !source_valid(0xFFFF_FFFF, LOCAL, MASK))
	testing.expect(t, !source_valid(0x0A0002FF, LOCAL, MASK)) // The subnet broadcast.
	testing.expect(t, !source_valid(LOCAL, LOCAL, MASK))
	testing.expect(t, !source_valid(0xE000_0001, LOCAL, MASK))
}

// A remote with no segment for 60 s is live: 60 s is RTO_MOST of
// src/library/support/tcp, the longest gap between two probes of a zero window. A full
// table must not give its place to a new remote then: its place serves
// again only after twice that time.
@(test)
admitted_remote_at_the_longest_gap_of_tcp :: proc(t: ^testing.T) {
	table: Admitted
	for index in 0 ..< datagram.ADMITTED_CAPACITY {
		testing.expect(t, admitted_add(&table, 0x0A000202, u16(40000 + index), 1000))
	}
	testing.expect(t, !admitted_add(&table, 0x0A000203, 40000, 1000 + 60_000))
	testing.expect(t, !admitted_add(&table, 0x0A000203, 40000, 1000 + 2 * 60_000))
	testing.expect(t, admitted_add(&table, 0x0A000203, 40000, 1000 + 2 * 60_000 + 1))
	// A time before the time of a place (a clock that went back) takes no place.
	testing.expect(t, !admitted_add(&table, 0x0A000204, 40000, 500))
}

// A UDP listen grant sends to a remote that did not prove its address at
// most 3 times the bytes that came from it; a send keeps no place alive; a
// remote that the program validated has no such limit. Before, a send to
// an admitted remote had no limit and kept its place for ever.
@(test)
admitted_remote_amplification_limit :: proc(t: ^testing.T) {
	table: Admitted
	testing.expect(t, admitted_add(&table, 0x0A000202, 40000, 1000))
	testing.expect(t, admitted_received(&table, 0x0A000202, 40000, 1200, 1000))
	allowed, admitted, limit, _ := admitted_send_allowed(&table, 0x0A000202, 40000, 3000)
	testing.expect(t, allowed && admitted && limit == 3600)
	allowed, admitted, limit, _ = admitted_send_allowed(&table, 0x0A000202, 40000, 601)
	testing.expect(t, !allowed && admitted)
	allowed, _, _, _ = admitted_send_allowed(&table, 0x0A000202, 40000, 600)
	testing.expect(t, allowed)
	// A second datagram of the remote: 3 times more.
	testing.expect(t, admitted_received(&table, 0x0A000202, 40000, 100, 1000))
	allowed, _, _, _ = admitted_send_allowed(&table, 0x0A000202, 40000, 300)
	testing.expect(t, allowed)
	allowed, _, _, _ = admitted_send_allowed(&table, 0x0A000202, 40000, 1)
	testing.expect(t, !allowed)
	// Validated: no limit.
	testing.expect(t, admitted_validate(&table, 0x0A000202, 40000))
	allowed, _, _, _ = admitted_send_allowed(&table, 0x0A000202, 40000, 1_000_000)
	testing.expect(t, allowed)
	testing.expect(t, !admitted_validate(&table, 0x0A000203, 40000))
	_, admitted, _, _ = admitted_send_allowed(&table, 0x0A000203, 40000, 1)
	testing.expect(t, !admitted)
	// Sends do not keep a place: with the table full, the place of this
	// remote, whose last datagram came at 1000, serves again after
	// ADMITTED_IDLE, though the program sent to it later.
	for index in 1 ..< datagram.ADMITTED_CAPACITY {
		testing.expect(t, admitted_add(&table, 0x0A000204, u16(index), 1000 + ADMITTED_IDLE))
	}
	admitted_send_allowed(&table, 0x0A000202, 40000, 1)
	testing.expect(t, admitted_add(&table, 0x0A000205, 1, 1000 + ADMITTED_IDLE + 1))
	testing.expect(t, !admitted_received(&table, 0x0A000202, 40000, 1, 1000 + ADMITTED_IDLE + 1))
}

// A listen port has one holder. The table holds the ports of each endpoint
// that exists, with or without a grant: the UDP listen port 4433 of an
// endpoint whose grant was revoked is still taken, and it is free again
// when the endpoint is removed.
@(test)
listen_port_has_one_holder :: proc(t: ^testing.T) {
	CLIENT_FIRST :: 49152
	TCP_CLIENT_FIRST :: 50176
	held := [4]Local_Ports {
		{tcp = false, first = CLIENT_FIRST, count = 1}, // A client grant of UDP.
		{tcp = false, first = 4433, count = 1}, // A listen grant of UDP; the rule does not read its grant.
		{tcp = true, first = 80, count = 1}, // A listen grant of TCP.
		{tcp = true, first = TCP_CLIENT_FIRST + 3 * 64, count = 64}, // A client grant of TCP.
	}
	// UDP.
	testing.expect(t, listen_port_taken(false, 4433, CLIENT_FIRST, 8, held[:]))
	testing.expect(t, !listen_port_taken(false, 4434, CLIENT_FIRST, 8, held[:]))
	testing.expect(t, !listen_port_taken(false, 80, CLIENT_FIRST, 8, held[:]), "a TCP port takes no UDP port")
	testing.expect(t, listen_port_taken(false, CLIENT_FIRST, CLIENT_FIRST, 8, held[:]))
	testing.expect(t, listen_port_taken(false, CLIENT_FIRST + 7, CLIENT_FIRST, 8, held[:]), "a port of the client range that no endpoint has yet")
	testing.expect(t, !listen_port_taken(false, CLIENT_FIRST + 8, CLIENT_FIRST, 8, held[:]))
	testing.expect(t, !listen_port_taken(false, CLIENT_FIRST - 1, CLIENT_FIRST, 8, held[:]))
	// TCP.
	testing.expect(t, listen_port_taken(true, 80, TCP_CLIENT_FIRST, 8 * 64, held[:]))
	testing.expect(t, !listen_port_taken(true, 4433, TCP_CLIENT_FIRST, 8 * 64, held[:]), "a UDP port takes no TCP port")
	testing.expect(t, listen_port_taken(true, TCP_CLIENT_FIRST, TCP_CLIENT_FIRST, 8 * 64, held[:]))
	testing.expect(t, listen_port_taken(true, TCP_CLIENT_FIRST + 8 * 64 - 1, TCP_CLIENT_FIRST, 8 * 64, held[:]))
	testing.expect(t, !listen_port_taken(true, TCP_CLIENT_FIRST + 8 * 64, TCP_CLIENT_FIRST, 8 * 64, held[:]))
	// The largest port does not wrap.
	testing.expect(t, !listen_port_taken(true, 65535, TCP_CLIENT_FIRST, 8 * 64, held[:]))
	held[0] = {tcp = false, first = 65535, count = 1}
	testing.expect(t, listen_port_taken(false, 65535, CLIENT_FIRST, 8, held[:]))
	// The endpoint is removed: its place is free, and so is its port.
	held[1] = {}
	testing.expect(t, !listen_port_taken(false, 4433, CLIENT_FIRST, 8, held[:]))
	testing.expect(t, !listen_port_taken(false, 0, CLIENT_FIRST, 8, held[:]), "a free place holds no port")
}
