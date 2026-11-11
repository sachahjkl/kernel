package network

import "contract:datagram"

// The two tables that the network service keeps, as functions with no
// input or output, so that the host runs their tests (tables_test.odin).

// A table of refused frames: one row for each kind in each layer, with the
// count and the last Problem. The network service keeps one for the
// machine (the frames that no endpoint owns) and one for each endpoint
// (the datagrams that reached its local port from a remote that its grant
// does not name).
Problem_Table :: struct {
	rows:  [datagram.Problem_Kind][datagram.Layer]datagram.Problem_Row,
	count: u64,
}

problem_count :: proc "contextless" (table: ^Problem_Table, found: datagram.Problem, scope: datagram.Problem_Scope) {
	kind := found.kind if found.kind <= max(datagram.Problem_Kind) else .None
	layer := found.layer if found.layer <= max(datagram.Layer) else .None
	row := &table.rows[kind][layer]
	row.last = found
	row.count += 1
	row.scope = scope
	table.count += 1
}

// problem_rows writes the rows that an endpoint can read: the rows of its
// own table, then, with the right Inspect of its grant, the rows of the
// machine. It never reads the table of another endpoint: the caller gives
// only the table of the endpoint that asks (property 20). It gives the count
// of the full answer; rows holds the part that fits.
problem_rows :: proc "contextless" (own: ^Problem_Table, machine: ^Problem_Table, inspect: bool, rows: []datagram.Problem_Row) -> (count: int) {
	tables := [2]^Problem_Table{own, inspect ? machine : nil}
	for table in tables {
		if table == nil {
			continue
		}
		for &by_layer in table.rows {
			for &row in by_layer {
				if row.count == 0 {
					continue
				}
				if count < len(rows) {
					rows[count] = row
				}
				count += 1
			}
		}
	}
	return count
}

// The admitted remotes of a listen grant: a remote that sent a SYN to the
// listen port. A segment to send goes out only to an admitted remote
// (docs/NETWORK.md). Each place has the time of its last segment, in or
// out: when the table is full, the oldest place with no segment for
// ADMITTED_IDLE serves again, so that a program that forgets a Release
// cannot close its own port.
ADMITTED_IDLE :: 60_000 // Milliseconds: more than each timer of support/tcp and of `server`.

Admitted_Remote :: struct {
	address: u32,
	port:    u16,
	used:    bool,
	time:    u64, // Milliseconds: the last segment of this remote, in or out.
}

Admitted :: [datagram.ADMITTED_CAPACITY]Admitted_Remote

// admitted_find says if a remote is admitted, and takes now as the time of
// its last segment.
admitted_find :: proc "contextless" (table: ^Admitted, address: u32, port: u16, now: u64) -> bool {
	for &item in table {
		if item.used && item.address == address && item.port == port {
			item.time = now
			return true
		}
	}
	return false
}

// admitted_add admits a remote: a free place, else the oldest place with no
// segment for ADMITTED_IDLE. false: each place had a segment in that time.
admitted_add :: proc "contextless" (table: ^Admitted, address: u32, port: u16, now: u64) -> bool {
	if admitted_find(table, address, port, now) {
		return true
	}
	oldest := -1
	for &item, index in table {
		if !item.used {
			item = {address = address, port = port, used = true, time = now}
			return true
		}
		if now - item.time >= ADMITTED_IDLE && (oldest < 0 || item.time < table[oldest].time) {
			oldest = index
		}
	}
	if oldest < 0 {
		return false
	}
	table[oldest] = {address = address, port = port, used = true, time = now}
	return true
}

// admitted_release forgets a remote. It says if the remote was admitted.
admitted_release :: proc "contextless" (table: ^Admitted, address: u32, port: u16) -> bool {
	for &item in table {
		if item.used && item.address == address && item.port == port {
			item = {}
			return true
		}
	}
	return false
}

// source_valid says if an address can be the source of a segment that the
// network service admits: not 0, not a broadcast (all ones, or the subnet
// broadcast), not multicast (224.0.0.0/4), not the local address.
source_valid :: proc "contextless" (address: u32, local: u32, mask: u32) -> bool {
	switch {
	case address == 0, address == 0xFFFF_FFFF, address == local:
		return false
	case address >> 28 == 0xE:
		return false
	case address & mask == local & mask && address | mask == 0xFFFF_FFFF:
		return false
	}
	return true
}

ARP_CAPACITY :: 16

// One address of the link and its hardware address.
Neighbor :: struct {
	address:  u32,
	hardware: Hardware,
	known:    bool,
	time:     u64, // When the answer came, in milliseconds.
}

Neighbors :: [ARP_CAPACITY]Neighbor

Learned :: enum u8 {
	Not_Asked, // No request of this service waits for this address: the answer is not taken.
	Updated, // The address was in the table: its hardware address is the new one.
	Added, // A free place took the address.
	Replaced, // The table was full: the oldest entry that no request uses took the address.
	Full, // Each entry is in use by a request that waits: the answer is not taken.
}

neighbor_find :: proc "contextless" (table: ^Neighbors, address: u32) -> (hardware: Hardware, ok: bool) {
	for &item in table {
		if item.known && item.address == address {
			return item.hardware, true
		}
	}
	return {}, false
}

// neighbor_learn takes an ARP answer, by this rule: the table learns only an
// address that a request of this service asked (asked), so that an ARP frame
// that nobody asked for changes nothing, also not the entry of the gateway.
// When the table is full, the answer replaces the oldest entry whose address
// no request that waits uses (busy); if each entry is in use, the answer is
// not taken and the request ends with no answer.
neighbor_learn :: proc "contextless" (table: ^Neighbors, address: u32, hardware: Hardware, now: u64, asked: bool, busy: []u32) -> Learned {
	if !asked {
		return .Not_Asked
	}
	free := -1
	for &item, index in table {
		if item.known && item.address == address {
			item.hardware, item.time = hardware, now
			return .Updated
		}
		if !item.known && free < 0 {
			free = index
		}
	}
	if free >= 0 {
		table[free] = {address = address, hardware = hardware, known = true, time = now}
		return .Added
	}
	oldest := -1
	entries: for &item, index in table {
		for used in busy {
			if used == item.address {
				continue entries
			}
		}
		if oldest < 0 || item.time < table[oldest].time {
			oldest = index
		}
	}
	if oldest < 0 {
		return .Full
	}
	table[oldest] = {address = address, hardware = hardware, known = true, time = now}
	return .Replaced
}
