#+build !freestanding
package network

import "contract:datagram"
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
