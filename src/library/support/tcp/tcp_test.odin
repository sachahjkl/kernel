#+build !freestanding
package tcp

import "core:testing"

// Two connection tables on one link that the test controls: it drops,
// delays and repeats segments with a generator of numbers that each test
// seeds, so each run makes the same changes. The time is the time of the
// test, in microseconds: the clock jumps to the next timer or the next
// segment on the link.

ADDRESS_A :: 0x0A00020F
ADDRESS_B :: 0x0A000202
PORT_B :: 80
CAPACITY :: 4
PLACES :: 64
PLACE_SIZE :: 2048
LINK_DELAY :: 500 // Microseconds from one side to the other.

Side :: struct {
	table:       Table,
	connections: [CAPACITY]Connection,
	buffers:     []u8,
	memory:      []u8,
	places:      [PLACES]u32,
	segments:    [PLACES]Outgoing,
	events:      [CAPACITY]Event,
	address:     u32,
	seen:        Event_Kinds, // Each event kind that a step reported, for connection 0.
	seen_by:     [CAPACITY]Event_Kinds, // The same, for each connection.
	sent_out:    int, // The segments that this side put on the link.
}

Flying :: struct {
	at:       u64,
	to:       int, // 0: side A, 1: side B.
	from:     u32,
	bytes:    [PLACE_SIZE]u8,
	length:   int,
}

// The state of a transfer of A to B, for the procedures of link_run.
Transfer :: struct {
	total:    int,
	written:  int,
	read:     int,
	wrong:    int,
	closed:   bool,
	reading:  bool,
}

Link :: struct {
	sides:     [2]Side,
	flying:    [dynamic]Flying,
	now:       u64,
	random:    u64,
	loss:      u64, // Per thousand.
	reorder:   u64, // Per thousand: the segment arrives 3 link delays later.
	duplicate: u64, // Per thousand.
	block:     bool, // Drop each segment.
	dropped:   int,
	transfer:  Transfer,
	drop_data: int, // Drop the data segment of A with this number, from 1. 0: none.
	data_sent: int, // The data segments that A sent.
}

next_random :: proc(link: ^Link) -> u64 {
	link.random ~= link.random << 13
	link.random ~= link.random >> 7
	link.random ~= link.random << 17
	return link.random
}

side_init :: proc(side: ^Side, address: u32, send_size, receive_size: u32) {
	side.buffers = make([]u8, CAPACITY * int(send_size + receive_size))
	side.memory = make([]u8, PLACES * PLACE_SIZE)
	side.address = address
	secret: [32]u8
	secret[0] = u8(address)
	error := table_init(&side.table, side.connections[:], side.buffers, send_size, receive_size, address, secret)
	assert(error.kind == 0)
	side.table.port_first = 40000
	side.table.port_count = 16
}

link_make :: proc(seed: u64, send_size: u32 = 64 * 1024, receive_size: u32 = 32 * 1024) -> ^Link {
	link := new(Link)
	link.random = seed
	side_init(&link.sides[0], ADDRESS_A, send_size, receive_size)
	side_init(&link.sides[1], ADDRESS_B, send_size, receive_size)
	link.sides[1].table.listen_port = PORT_B
	return link
}

link_free :: proc(link: ^Link) {
	for &side in link.sides {
		delete(side.buffers)
		delete(side.memory)
	}
	delete(link.flying)
	free(link)
}

// side_step runs step on one side with the segments that arrived, and puts
// its segments on the link.
side_step :: proc(link: ^Link, index: int, arrived: []Incoming) -> u64 {
	side := &link.sides[index]
	for &place, n in side.places {
		place = u32(n)
	}
	output := Output{memory = side.memory, place_size = PLACE_SIZE, places = side.places[:], segments = side.segments[:]}
	deadline, count := step(&side.table, arrived, link.now, &output, side.events[:])
	for event in side.events[:count] {
		if event.connection == 0 {
			side.seen += event.kinds
		}
		side.seen_by[event.connection] += event.kinds
	}
	side.sent_out += output.count
	for item in side.segments[:output.count] {
		bytes := side.memory[int(item.place) * PLACE_SIZE:][:item.length]
		if !checksum_valid(side.address, item.remote_address, bytes) {
			panic("a segment with a wrong checksum")
		}
		if index == 0 && item.length > HEADER {
			link.data_sent += 1
			if link.data_sent == link.drop_data {
				link.dropped += 1
				continue
			}
		}
		if link.block || next_random(link) % 1000 < link.loss {
			link.dropped += 1
			continue
		}
		copies := next_random(link) % 1000 < link.duplicate ? 2 : 1
		for _ in 0 ..< copies {
			flying := Flying{at = link.now + LINK_DELAY, to = 1 - index, from = side.address, length = len(bytes)}
			if next_random(link) % 1000 < link.reorder {
				flying.at += 3 * LINK_DELAY
			}
			copy(flying.bytes[:], bytes)
			append(&link.flying, flying)
		}
	}
	return deadline
}

// link_run moves the time until done says so, or until the time limit.
link_run :: proc(link: ^Link, limit: u64, done: proc(link: ^Link) -> bool, work: proc(link: ^Link) = nil) -> bool {
	end := link.now + limit
	deadlines := [2]u64{0, 0}
	for link.now <= end {
		if work != nil {
			work(link)
		}
		for index in 0 ..< 2 {
			// The segments that arrive are copied out of the link first: the
			// step puts new segments on the link.
			arriving := make([dynamic]Flying, context.temp_allocator)
			kept := make([dynamic]Flying, context.temp_allocator)
			for &item in link.flying {
				if item.to == index && item.at <= link.now {
					append(&arriving, item)
				} else {
					append(&kept, item)
				}
			}
			arrived := make([]Incoming, len(arriving), context.temp_allocator)
			for &item, place in arriving {
				arrived[place] = {remote_address = item.from, segment = item.bytes[:item.length]}
			}
			clear(&link.flying)
			for item in kept {
				append(&link.flying, item)
			}
			// side_step puts the segments of this step on the link.
			deadlines[index] = side_step(link, index, arrived[:])
		}
		if done(link) {
			free_all(context.temp_allocator)
			return true
		}
		next := min(deadlines[0], deadlines[1], link.now + 1000)
		for item in link.flying {
			next = min(next, item.at)
		}
		link.now = max(next, link.now + 1)
		free_all(context.temp_allocator)
	}
	return false
}

pattern :: proc(offset: int) -> u8 {
	return u8(offset * 7 + offset >> 9)
}


transfer_work :: proc(link: ^Link) {
	a := &link.sides[0]
	b := &link.sides[1]
	if a.connections[0].state == .Established && link.transfer.written < link.transfer.total {
		chunk: [4096]u8
		count := min(len(chunk), link.transfer.total - link.transfer.written)
		for index in 0 ..< count {
			chunk[index] = pattern(link.transfer.written + index)
		}
		taken, _ := write(&a.table, 0, chunk[:count])
		link.transfer.written += taken
	}
	if link.transfer.written == link.transfer.total && !link.transfer.closed && a.connections[0].state == .Established {
		close(&a.table, 0)
		link.transfer.closed = true
	}
	if link.transfer.reading {
		buffer: [4096]u8
		for {
			count, _ := read(&b.table, 0, buffer[:])
			if count == 0 {
				break
			}
			for index in 0 ..< count {
				if buffer[index] != pattern(link.transfer.read + index) {
					link.transfer.wrong += 1
				}
			}
			link.transfer.read += count
		}
		if b.connections[0].state == .Close_Wait {
			close(&b.table, 0)
		}
	}
}

transfer_done :: proc(link: ^Link) -> bool {
	return link.transfer.read == link.transfer.total && link.sides[1].connections[0].state == .Closed && link.sides[0].connections[0].state == .Time_Wait
}

// transfer_run sends total bytes from A to B, then closes from A, then
// from B. It checks each byte.
transfer_run :: proc(t: ^testing.T, link: ^Link, total: int) -> bool {
	link.transfer = {total = total, reading = true}
	_, error := connect(&link.sides[0].table, ADDRESS_B, PORT_B, link.now)
	testing.expect_value(t, error.kind, 0)
	ok := link_run(link, 120_000_000, transfer_done, transfer_work)
	testing.expectf(t, ok, "the transfer did not end: read %d of %d, A %v, B %v", link.transfer.read, link.transfer.total, link.sides[0].connections[0].state, link.sides[1].connections[0].state)
	testing.expect_value(t, link.transfer.wrong, 0)
	return ok && link.transfer.wrong == 0
}

@(test)
sequence_order :: proc(t: ^testing.T) {
	testing.expect(t, before(0xFFFF_FFF0, 0x10))
	testing.expect(t, after(0x10, 0xFFFF_FFF0))
	testing.expect(t, !before(0x10, 0xFFFF_FFF0))
	testing.expect(t, before_or_same(5, 5))
	testing.expect(t, inside(0x5, 0xFFFF_FFF0, 0x20))
	testing.expect(t, !inside(0x10, 0xFFFF_FFF0, 0x20))
	testing.expect(t, after(0x8000_0000, 1))
}

@(test)
handshake_data_close :: proc(t: ^testing.T) {
	link := link_make(1)
	defer link_free(link)
	if !transfer_run(t, link, 300_000) {
		return
	}
	a := &link.sides[0].connections[0]
	b := &link.sides[1].connections[0]
	testing.expect(t, .Opened in link.sides[0].seen)
	testing.expect(t, .Accepted in link.sides[1].seen)
	testing.expect(t, .Closed in link.sides[1].seen)
	testing.expect_value(t, a.bytes_sent, 300_000)
	testing.expect_value(t, b.bytes_received, 300_000)
	testing.expect_value(t, a.retransmissions, 0)
	testing.expect(t, b.closed_by_remote)
	testing.expect(t, a.rtt_samples > 0)
	testing.expect_value(t, a.mss, MSS_LOCAL)
	// TIME-WAIT ends after its time, and the record is free.
	link_run(link, TIME_WAIT + 1_000_000, proc(link: ^Link) -> bool {return available(&link.sides[0].connections[0])})
	testing.expect(t, available(a))
	testing.expect(t, .Closed in link.sides[0].seen)
}

@(test)
wrap_of_sequence :: proc(t: ^testing.T) {
	link := link_make(2)
	defer link_free(link)
	// Both sides start 1000 bytes before 2^32: the data crosses the wrap.
	link.sides[0].table.has_initial = true
	link.sides[0].table.initial = 0xFFFF_FC00
	link.sides[1].table.has_initial = true
	link.sides[1].table.initial = 0xFFFF_FFF0
	transfer_run(t, link, 100_000)
	testing.expect_value(t, link.sides[0].connections[0].bytes_sent, 100_000)
}

@(test)
loss_reorder_duplicate :: proc(t: ^testing.T) {
	for seed in u64(3) ..< 8 {
		link := link_make(seed)
		link.loss = 50
		link.reorder = 50
		link.duplicate = 50
		transfer_run(t, link, 500_000)
		a := &link.sides[0].connections[0]
		b := &link.sides[1].connections[0]
		testing.expect(t, link.dropped > 0)
		testing.expect(t, a.retransmissions > 0)
		testing.expect(t, b.out_of_order > 0)
		testing.expect(t, b.duplicates > 0)
		link_free(link)
	}
}

@(test)
fast_retransmit :: proc(t: ^testing.T) {
	// One loss in a long run of data: three duplicate ACKs, no timeout.
	link := link_make(9)
	defer link_free(link)
	link.drop_data = 40
	transfer_run(t, link, 200_000)
	a := &link.sides[0].connections[0]
	testing.expect_value(t, link.dropped, 1)
	testing.expect_value(t, a.fast_retransmits, 1)
	testing.expect_value(t, a.timeouts, 0)
	testing.expect_value(t, a.retransmissions, 1)
}

@(test)
round_trip_timer :: proc(t: ^testing.T) {
	connection: Connection
	connection.rto = RTO_INITIAL
	// RFC 6298 2.2: the first sample R gives SRTT = R, RTTVAR = R / 2.
	rtt_sample(&connection, 100_000)
	testing.expect_value(t, connection.smoothed_rtt, 100_000)
	testing.expect_value(t, connection.rtt_variance, 50_000)
	testing.expect_value(t, connection.rto, 300_000)
	// 2.3: RTTVAR = 3/4 RTTVAR + 1/4 |SRTT - R|, then SRTT = 7/8 SRTT + 1/8 R.
	rtt_sample(&connection, 60_000)
	testing.expect_value(t, connection.rtt_variance, 47_500)
	testing.expect_value(t, connection.smoothed_rtt, 95_000)
	testing.expect_value(t, connection.rto, 285_000)
	// The least is RTO_LEAST.
	for _ in 0 ..< 50 {
		rtt_sample(&connection, 100)
	}
	testing.expect_value(t, connection.rto, RTO_LEAST)
}

@(test)
timeouts_double :: proc(t: ^testing.T) {
	// The remote never answers: the SYN goes again after 1, 2, 4 ... s,
	// then the connection ends.
	link := link_make(10)
	defer link_free(link)
	link.block = true
	connect(&link.sides[0].table, ADDRESS_B, PORT_B, link.now)
	times: [dynamic]u64
	defer delete(times)
	last_count: u64
	ok := link_run(link, 1_000_000_000, proc(link: ^Link) -> bool {
		return .Timed_Out in link.sides[0].seen
	})
	_ = last_count
	testing.expect(t, ok)
	a := &link.sides[0].connections[0]
	testing.expect_value(t, a.timeouts, RETRIES + 1)
	// 1 + 2 + 4 + 8 + 16 + 32 + 60 + 60 + 60 s: the timer doubles to
	// RTO_MOST. The ninth timeout ends the connection.
	testing.expectf(t, link.now >= 243_000_000 && link.now < 244_000_000, "the end came at %d us", link.now)
	testing.expect_value(t, a.retransmissions, RETRIES)
}

@(test)
zero_window :: proc(t: ^testing.T) {
	// B reads nothing for 5 s: its window goes to 0, A sends probes, then B
	// reads and the window opens.
	link := link_make(11, 64 * 1024, 16 * 1024)
	defer link_free(link)
	link.transfer = {total = 120_000, reading = false}
	connect(&link.sides[0].table, ADDRESS_B, PORT_B, link.now)
	ok := link_run(link, 5_000_000, proc(link: ^Link) -> bool {return false}, transfer_work)
	testing.expect(t, !ok)
	a := &link.sides[0].connections[0]
	testing.expect_value(t, a.send_window, 0)
	testing.expect(t, a.probes >= 2)
	testing.expect(t, a.zero_windows >= 1)
	link.transfer.reading = true
	ok = link_run(link, 60_000_000, transfer_done, transfer_work)
	testing.expect(t, ok)
	testing.expect_value(t, link.transfer.wrong, 0)
	testing.expect_value(t, link.transfer.read, 120_000)
}

// established opens one connection from A to B.
established :: proc(t: ^testing.T, link: ^Link) -> bool {
	connect(&link.sides[0].table, ADDRESS_B, PORT_B, link.now)
	ok := link_run(link, 5_000_000, proc(link: ^Link) -> bool {
		return link.sides[0].connections[0].state == .Established && link.sides[1].connections[0].state == .Established
	})
	testing.expect(t, ok)
	return ok
}

// inject puts one segment from A to B on the link, with data.
inject :: proc(link: ^Link, header: Header, data: []u8 = nil) {
	offset := header.mss != 0 ? HEADER_MSS : HEADER
	flying := Flying{at = link.now, to = 1, from = ADDRESS_A, length = offset + len(data)}
	copy(flying.bytes[offset:], data)
	header_write(flying.bytes[:], ADDRESS_A, ADDRESS_B, header, flying.length)
	append(&link.flying, flying)
}

// wait runs the link for a time, with no end condition.
wait :: proc(link: ^Link, time: u64) {
	link_run(link, time, proc(link: ^Link) -> bool {return false})
}

@(test)
resets_and_challenges :: proc(t: ^testing.T) {
	link := link_make(12)
	defer link_free(link)
	if !established(t, link) {
		return
	}
	a := &link.sides[0].connections[0]
	b := &link.sides[1].connections[0]
	// A RST in the window but not at RCV.NXT: a challenge ACK, and the
	// connection stays (RFC 5961 3.2).
	inject(link, {source_port = a.local_port, destination_port = PORT_B, sequence = b.receive_next + 100, flags = {.Rst}})
	link_run(link, 10_000, proc(link: ^Link) -> bool {return false})
	testing.expect_value(t, b.challenges, 1)
	testing.expect_value(t, b.state, State.Established)
	// A SYN in a synchronized state: a challenge ACK (RFC 5961 4.2).
	inject(link, {source_port = a.local_port, destination_port = PORT_B, sequence = 12345, flags = {.Syn}})
	link_run(link, 10_000, proc(link: ^Link) -> bool {return false})
	testing.expect_value(t, b.challenges, 2)
	testing.expect_value(t, b.state, State.Established)
	// A RST out of the window: dropped, no answer.
	inject(link, {source_port = a.local_port, destination_port = PORT_B, sequence = b.receive_next + 200_000, flags = {.Rst}})
	link_run(link, 10_000, proc(link: ^Link) -> bool {return false})
	testing.expect_value(t, b.challenges, 2)
	testing.expect_value(t, b.state, State.Established)
	// A RST at RCV.NXT ends the connection.
	inject(link, {source_port = a.local_port, destination_port = PORT_B, sequence = b.receive_next, flags = {.Rst}})
	link_run(link, 10_000, proc(link: ^Link) -> bool {return false})
	testing.expect(t, .Reset in link.sides[1].seen)
	testing.expect(t, available(b))
	// A has its connection; its next segment gets a RST, which ends it.
	write(&link.sides[0].table, 0, transmute([]u8)string("after the reset"))
	ok := link_run(link, 5_000_000, proc(link: ^Link) -> bool {return .Reset in link.sides[0].seen})
	testing.expect(t, ok)
	testing.expect(t, link.sides[1].table.resets_sent >= 1)
}

@(test)
abort_sends_reset :: proc(t: ^testing.T) {
	link := link_make(13)
	defer link_free(link)
	if !established(t, link) {
		return
	}
	abort(&link.sides[0].table, 0)
	ok := link_run(link, 1_000_000, proc(link: ^Link) -> bool {return .Reset in link.sides[1].seen})
	testing.expect(t, ok)
	testing.expect(t, available(&link.sides[0].connections[0]))
}

@(test)
refused_connection :: proc(t: ^testing.T) {
	link := link_make(14)
	defer link_free(link)
	link.sides[1].table.listen_port = 0 // B listens on no port: it answers the SYN with a RST.
	connect(&link.sides[0].table, ADDRESS_B, PORT_B, link.now)
	ok := link_run(link, 1_000_000, proc(link: ^Link) -> bool {return .Refused in link.sides[0].seen})
	testing.expect(t, ok)
}

@(test)
close_from_both_sides :: proc(t: ^testing.T) {
	// Both sides close at the same time: FIN-WAIT-1, CLOSING, TIME-WAIT on each.
	link := link_make(15)
	defer link_free(link)
	if !established(t, link) {
		return
	}
	close(&link.sides[0].table, 0)
	close(&link.sides[1].table, 0)
	ok := link_run(link, 1_000_000, proc(link: ^Link) -> bool {
		return link.sides[0].connections[0].state == .Time_Wait && link.sides[1].connections[0].state == .Time_Wait
	})
	testing.expect(t, ok)
}

@(test)
errors_are_records :: proc(t: ^testing.T) {
	link := link_make(16)
	defer link_free(link)
	for _ in 0 ..< CAPACITY {
		_, error := connect(&link.sides[0].table, ADDRESS_B, PORT_B, 0)
		testing.expect_value(t, error.kind, 0)
	}
	_, error := connect(&link.sides[0].table, ADDRESS_B, PORT_B, 0)
	testing.expect_value(t, error.kind, 15) // Full.
	testing.expect_value(t, error.limit, CAPACITY)
	_, error = write(&link.sides[1].table, 0, {1})
	testing.expect_value(t, error.kind, 16) // State: the record is Closed.
	_, error = read(&link.sides[1].table, 99, nil)
	testing.expect_value(t, error.kind, 4) // Bad_Value.
}

@(test)
malformed_segments :: proc(t: ^testing.T) {
	segment: [64]u8
	_, ok := header_read(segment[:10])
	testing.expect(t, !ok)
	segment[12] = 4 << 4 // A data offset of 16 bytes.
	_, ok = header_read(segment[:])
	testing.expect(t, !ok)
	segment[12] = 15 << 4 // 60 bytes, after the end of a segment of 40.
	_, ok = header_read(segment[:40])
	testing.expect(t, !ok)
	segment[12] = 6 << 4
	segment[20] = 2 // An MSS option of length 1.
	segment[21] = 1
	_, ok = header_read(segment[:])
	testing.expect(t, !ok)
	segment[21] = 4
	write_16(segment[:], 22, 1000)
	header: Header
	header, ok = header_read(segment[:])
	testing.expect(t, ok)
	testing.expect_value(t, header.mss, 1000)
}

@(test)
record_size :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Connection), 424)
}
