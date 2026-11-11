#+build !freestanding
package tcp

import "core:testing"

// The tests of the faults that a read of the library as hostile input
// found (choices of the step after 309 in docs/FIRST_MILESTONE.md), and the
// cases that it found with no test.

// F1: a RST with data whose first byte is before RCV.NXT and whose end is
// in the window. RFC 5961 3.2 tests the sequence of the segment as it came:
// it is not RCV.NXT, so the answer is a challenge ACK, not a reset.
@(test)
reset_with_data_before_the_window :: proc(t: ^testing.T) {
	link := link_make(20)
	defer link_free(link)
	if !established(t, link) {
		return
	}
	a := &link.sides[0].connections[0]
	b := &link.sides[1].connections[0]
	data: [20]u8
	inject(link, {source_port = a.local_port, destination_port = PORT_B, sequence = b.receive_next - 10, flags = {.Rst}}, data[:])
	wait(link, 10_000)
	testing.expect_value(t, b.state, State.Established)
	testing.expect_value(t, b.challenges, 1)
}

// F2: the remote gave a window of 0, then went away: the probes end with
// Timed_Out, not never.
@(test)
probes_give_up :: proc(t: ^testing.T) {
	link := link_make(21, 64 * 1024, 16 * 1024)
	defer link_free(link)
	link.transfer = {total = 120_000, reading = false}
	connect(&link.sides[0].table, ADDRESS_B, PORT_B, link.now)
	link_run(link, 3_000_000, proc(link: ^Link) -> bool {return false}, transfer_work)
	a := &link.sides[0].connections[0]
	testing.expect_value(t, a.send_window, 0)
	link.block = true
	ok := link_run(link, 1_000_000_000, proc(link: ^Link) -> bool {return .Timed_Out in link.sides[0].seen})
	testing.expect(t, ok)
}

// F4: a SYN, then nothing: the passive record ends after fewer retries than
// an established connection, and the program gets an event for it.
@(test)
syn_received_ends_soon :: proc(t: ^testing.T) {
	link := link_make(22)
	defer link_free(link)
	// The link drops each answer of B: A sees no SYN, ACK (it would answer
	// with a RST, which ends the record at once).
	inject(link, {source_port = 41000, destination_port = PORT_B, sequence = 5000, flags = {.Syn}, window = 8192})
	link.block = true
	wait(link, 100)
	b := &link.sides[1].connections[0]
	testing.expect_value(t, b.state, State.Syn_Received)
	start := link.now
	ok := link_run(link, 300_000_000, proc(link: ^Link) -> bool {return .Timed_Out in link.sides[1].seen})
	testing.expect(t, ok)
	testing.expectf(t, link.now - start < 20_000_000, "the record ended after %d us", link.now - start)
}

// B1: a SYN, then a RST at the exact sequence: the passive record ends with
// an event, so that the program releases the remote.
@(test)
passive_reset_has_an_event :: proc(t: ^testing.T) {
	link := link_make(23)
	defer link_free(link)
	inject(link, {source_port = 41001, destination_port = PORT_B, sequence = 7000, flags = {.Syn}, window = 8192})
	wait(link, 1000)
	inject(link, {source_port = 41001, destination_port = PORT_B, sequence = 7001, flags = {.Rst}})
	wait(link, 1000)
	testing.expect(t, .Reset in link.sides[1].seen)
	testing.expect(t, available(&link.sides[1].connections[0]))
}

// W1: a flood of segments out of the window gets a bounded count of
// answers in one second (a limit for each connection: CVE-2016-5696 came
// from one limit for all).
@(test)
answers_are_limited :: proc(t: ^testing.T) {
	link := link_make(24)
	defer link_free(link)
	if !established(t, link) {
		return
	}
	a := &link.sides[0].connections[0]
	b := &link.sides[1].connections[0]
	before := link.sides[1].sent_out
	// One segment each 500 us, for 100 ms: each one comes in its own step.
	for index in 0 ..< 100 {
		inject(link, {source_port = a.local_port, destination_port = PORT_B, sequence = b.receive_next + 1000 + u32(index), flags = {.Rst}})
		wait(link, 500)
		inject(link, {source_port = a.local_port, destination_port = PORT_B, sequence = b.receive_next + 500_000, flags = {.Ack}, acknowledgment = b.send_next})
		wait(link, 500)
	}
	testing.expectf(t, link.sides[1].sent_out - before <= ANSWER_LIMIT, "%d answers to 200 segments", link.sides[1].sent_out - before)
	testing.expect_value(t, b.state, State.Established)
}

// W2: after a timeout, recover is the highest sequence sent (RFC 6582 3.2,
// step 4).
@(test)
recover_after_a_timeout :: proc(t: ^testing.T) {
	link := link_make(25)
	defer link_free(link)
	if !established(t, link) {
		return
	}
	write(&link.sides[0].table, 0, make([]u8, 20_000, context.temp_allocator))
	wait(link, 200)
	link.block = true
	link_run(link, 5_000_000, proc(link: ^Link) -> bool {return link.sides[0].connections[0].timeouts > 0})
	a := &link.sides[0].connections[0]
	testing.expect_value(t, a.recover, a.send_most)
}

// W2: outside recovery, recover follows the acknowledged edge: a fast
// retransmit still starts after 2^31 bytes.
@(test)
recover_follows_the_edge :: proc(t: ^testing.T) {
	link := link_make(26)
	defer link_free(link)
	link.transfer = {total = 100_000, reading = true}
	transfer_run(t, link, 100_000)
	a := &link.sides[0].connections[0]
	testing.expect(t, !before(a.recover, a.send_unacknowledged - 2 * u32(a.mss) - 1))
}

// W3: the SYN counts in the acknowledged bytes once, by the state, not
// when SND.UNA is again the initial sequence after 2^32 bytes.
@(test)
syn_acknowledged_once :: proc(t: ^testing.T) {
	link := link_make(27)
	defer link_free(link)
	if !established(t, link) {
		return
	}
	a := &link.sides[0].connections[0]
	b := &link.sides[1].connections[0]
	// A as after 2^32 bytes: SND.UNA is the initial sequence again, with
	// 100 bytes in flight.
	write(&link.sides[0].table, 0, make([]u8, 100, context.temp_allocator))
	a.send_unacknowledged = a.initial_send
	a.send_next = a.initial_send
	a.send_most = a.initial_send
	b.receive_next = a.initial_send
	b.receive_edge = b.receive_next + 16_000
	wait(link, 50_000)
	testing.expect_value(t, a.bytes_sent, 100)
	testing.expect_value(t, a.send_length, 0)
}

// W4: a second FIN at RCV.NXT, after the first: nothing moves. In
// TIME-WAIT, a FIN again restarts the timer.
@(test)
second_fin :: proc(t: ^testing.T) {
	link := link_make(28)
	defer link_free(link)
	if !established(t, link) {
		return
	}
	a := &link.sides[0].connections[0]
	b := &link.sides[1].connections[0]
	close(&link.sides[0].table, 0)
	link_run(link, 1_000_000, proc(link: ^Link) -> bool {return link.sides[1].connections[0].state == .Close_Wait})
	next := b.receive_next
	inject(link, {source_port = a.local_port, destination_port = PORT_B, sequence = next, acknowledgment = b.send_next, flags = {.Fin, .Ack}, window = 8192})
	wait(link, 1000)
	testing.expect_value(t, b.receive_next, next)
	testing.expect_value(t, b.state, State.Close_Wait)
}

// The FIN-WAIT-2 timer: the remote acknowledged the FIN of this side and
// never sends its own.
@(test)
fin_wait_2_ends :: proc(t: ^testing.T) {
	link := link_make(29)
	defer link_free(link)
	if !established(t, link) {
		return
	}
	close(&link.sides[0].table, 0) // B never closes.
	ok := link_run(link, 120_000_000, proc(link: ^Link) -> bool {return available(&link.sides[0].connections[0])})
	testing.expect(t, ok)
	testing.expect(t, link.now < FIN_WAIT_2 + 2_000_000)
}

// A limit of connections for each remote address: the next SYN gets a RST.
@(test)
remote_limit :: proc(t: ^testing.T) {
	link := link_make(30)
	defer link_free(link)
	link.sides[1].table.remote_limit = 2
	for _ in 0 ..< 3 {
		connect(&link.sides[0].table, ADDRESS_B, PORT_B, link.now)
	}
	wait(link, 100_000)
	open := 0
	for &item in link.sides[0].connections[:3] {
		if item.state == .Established {
			open += 1
		}
	}
	testing.expect_value(t, open, 2)
	testing.expect(t, .Refused in link.sides[0].seen_by[2])
}

// A SYN to a full table: a RST, so that the remote knows at once; with a
// record in TIME-WAIT, the oldest one ends, and the SYN that comes again
// takes it.
@(test)
syn_to_a_full_table :: proc(t: ^testing.T) {
	link := link_make(31)
	defer link_free(link)
	for _ in 0 ..< CAPACITY {
		connect(&link.sides[0].table, ADDRESS_B, PORT_B, link.now)
	}
	wait(link, 100_000)
	inject(link, {source_port = 42000, destination_port = PORT_B, sequence = 9000, flags = {.Syn}, window = 8192})
	wait(link, 1000)
	testing.expect_value(t, link.sides[1].table.refused_syns, 1)
	// B closes connection 1 first, then A: B is in TIME-WAIT.
	close(&link.sides[1].table, 1)
	link_run(link, 1_000_000, proc(link: ^Link) -> bool {return link.sides[0].connections[1].state == .Close_Wait})
	close(&link.sides[0].table, 1)
	link_run(link, 1_000_000, proc(link: ^Link) -> bool {return link.sides[1].connections[1].state == .Time_Wait})
	inject(link, {source_port = 42001, destination_port = PORT_B, sequence = 9000, flags = {.Syn}, window = 8192})
	wait(link, 1000)
	testing.expect(t, available(&link.sides[1].connections[1]))
	testing.expect(t, .Closed in link.sides[1].seen_by[1])
	inject(link, {source_port = 42001, destination_port = PORT_B, sequence = 9000, flags = {.Syn}, window = 8192})
	wait(link, 100) // Before the SYN, ACK reaches A, which knows no such connection.
	testing.expect_value(t, link.sides[1].connections[1].state, State.Syn_Received)
	testing.expect_value(t, link.sides[1].connections[1].remote_port, 42001)
}

// A simultaneous open: each side sends a SYN to the other.
@(test)
simultaneous_open :: proc(t: ^testing.T) {
	link := link_make(32)
	defer link_free(link)
	link.sides[1].table.listen_port = 0
	link.sides[0].table.port_first, link.sides[0].table.port_count = 5000, 1
	link.sides[1].table.port_first, link.sides[1].table.port_count = 6000, 1
	connect(&link.sides[0].table, ADDRESS_B, 6000, link.now)
	connect(&link.sides[1].table, ADDRESS_A, 5000, link.now)
	ok := link_run(link, 5_000_000, proc(link: ^Link) -> bool {
		return link.sides[0].connections[0].state == .Established && link.sides[1].connections[0].state == .Established
	})
	testing.expect(t, ok)
	testing.expect(t, .Opened in link.sides[0].seen && .Opened in link.sides[1].seen)
}

// The 8 ranges full, a ninth that is not kept, then one segment that
// covers several ranges, then the hole: each byte arrives once, in order.
@(test)
ranges_full :: proc(t: ^testing.T) {
	link := link_make(33)
	defer link_free(link)
	if !established(t, link) {
		return
	}
	a := &link.sides[0].connections[0]
	b := &link.sides[1].connections[0]
	first := b.receive_next
	data: [2000]u8
	for &byte, index in data {
		byte = u8(index * 13)
	}
	segment :: proc(link: ^Link, port: u16, first: u32, ack: u32, data: []u8, from, to: int) {
		inject(link, {source_port = port, destination_port = PORT_B, sequence = first + u32(from), acknowledgment = ack, flags = {.Ack}, window = 8192}, data[from:to])
	}
	// Ranges at 100, 200, ... 900: nine, one more than RANGE_CAPACITY.
	for index in 1 ..= 9 {
		segment(link, a.local_port, first, b.send_next, data[:], index * 100, index * 100 + 50)
	}
	wait(link, 1000)
	testing.expect_value(t, b.range_count, RANGE_CAPACITY)
	// One segment that covers the ranges from 150 to 650.
	segment(link, a.local_port, first, b.send_next, data[:], 150, 650)
	wait(link, 1000)
	// The hole, then the rest.
	segment(link, a.local_port, first, b.send_next, data[:], 0, 150)
	segment(link, a.local_port, first, b.send_next, data[:], 650, 2000)
	wait(link, 50_000)
	got: [2100]u8
	count, _ := read(&link.sides[1].table, 0, got[:])
	testing.expect_value(t, count, 2000)
	testing.expect(t, string(got[:2000]) == string(data[:]))
	testing.expect_value(t, b.range_count, 0)
}

// Loss, reorder and duplicates at the wrap of 2^32.
@(test)
changes_at_the_wrap :: proc(t: ^testing.T) {
	link := link_make(34)
	defer link_free(link)
	link.loss, link.reorder, link.duplicate = 50, 50, 50
	link.sides[0].table.has_initial = true
	link.sides[0].table.initial = 0xFFFF_0000 // 64 KiB before the wrap.
	link.sides[1].table.has_initial = true
	link.sides[1].table.initial = 0xFFFF_FFF0
	transfer_run(t, link, 300_000)
	testing.expect(t, link.sides[0].connections[0].retransmissions > 0)
}

// Karn: a SYN, ACK that went two times gives no round trip sample.
@(test)
resent_syn_ack_is_not_timed :: proc(t: ^testing.T) {
	link := link_make(35)
	defer link_free(link)
	link.block = true // A must not answer the SYN, ACK with a RST.
	inject(link, {source_port = 41002, destination_port = PORT_B, sequence = 3000, flags = {.Syn}, window = 8192})
	wait(link, 100)
	b := &link.sides[1].connections[0]
	testing.expect(t, b.timing)
	inject(link, {source_port = 41002, destination_port = PORT_B, sequence = 3000, flags = {.Syn}, window = 8192})
	wait(link, 100)
	testing.expect_value(t, b.state, State.Syn_Received)
	testing.expect(t, !b.timing)
}

// The send window takes no update from an ACK below SND.UNA.
@(test)
old_ack_does_not_move_the_window :: proc(t: ^testing.T) {
	link := link_make(36)
	defer link_free(link)
	if !established(t, link) {
		return
	}
	write(&link.sides[1].table, 0, make([]u8, 3000, context.temp_allocator))
	wait(link, 100_000)
	a := &link.sides[0].connections[0]
	b := &link.sides[1].connections[0]
	window := b.send_window
	inject(link, {source_port = a.local_port, destination_port = PORT_B, sequence = b.receive_next + 1, acknowledgment = b.send_unacknowledged - 1000, flags = {.Ack}, window = 7})
	wait(link, 1000)
	testing.expect_value(t, b.send_window, window)
}

@(test)
options_that_break_a_rule :: proc(t: ^testing.T) {
	segment: [32]u8
	segment[12] = 6 << 4
	segment[20] = 2 // An option of length 0.
	segment[21] = 0
	_, ok := header_read(segment[:24])
	testing.expect(t, !ok)
	segment[20] = 8 // An option of length 10 in a header of 24 bytes.
	segment[21] = 10
	_, ok = header_read(segment[:24])
	testing.expect(t, !ok)
}
