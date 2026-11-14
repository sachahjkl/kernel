package quic

// A set of ranges of numbers, with no allocation.
//
// Three things of a connection are sets of numbers that come in runs: the
// packet numbers that a side received (for its ACK frames), the bytes of a
// stream that came or that the peer acknowledged, and the bytes that wait to
// be sent again. A set stores each run as one range, so a million bytes in
// order take one place.
//
// Each range is [start, end): `start` is in it, `end` is not. The ranges are
// in ascending order, and two ranges never touch or overlap: an insert merges
// them. A set holds `RANGE_SET_LIMIT` ranges; what a caller does when a set is
// full is the rule of `range_set_insert`.

RANGE_SET_LIMIT :: 32 // The ranges that one set holds. A set fills only when the numbers come with that many gaps at one time: a peer that sends in order uses one range.

// A set of numbers, stored as at most `RANGE_SET_LIMIT` ranges in ascending
// order. Its zero value is the empty set.
//
// A caller reads the fields to walk the ranges (an ACK frame is written from
// them), and changes the set only through the procedures of this file, which
// keep the order and the merge.
Range_Set :: struct {
	starts: [RANGE_SET_LIMIT]u64, // The first number of each range, in ascending order.
	ends:   [RANGE_SET_LIMIT]u64, // The number after the last number of each range: the range with the index n is [starts[n], ends[n]).
	count:  int, // The ranges in use: the first `count` places of `starts` and `ends`.
}

// range_set_insert adds the numbers of [start, end) to a set, and merges the
// ranges that the new range overlaps or touches.
//
// - `start`, `end`: the range to add. An empty range (`start` not below `end`)
//   adds nothing and gives true.
//
// **Result**: true when the numbers are in the set. false when the result
// would need more than `RANGE_SET_LIMIT` ranges: the set then does not change.
//
// A caller that gets false acts as if the numbers never came. A packet whose
// data had no place is not acknowledged, so the peer sends the data again; a
// sent packet whose data had no place stays in flight. A set that is full
// therefore costs time, and never loses or repeats a byte.
range_set_insert :: proc "contextless" (set: ^Range_Set, start, end: u64) -> bool {
	if start >= end {
		return true
	}
	starts: [RANGE_SET_LIMIT + 1]u64
	ends: [RANGE_SET_LIMIT + 1]u64
	count := 0
	merged_start, merged_end := start, end
	placed := false
	for index in 0 ..< set.count {
		range_start, range_end := set.starts[index], set.ends[index]
		switch {
		case range_end < merged_start:
			starts[count], ends[count] = range_start, range_end
			count += 1
		case range_start > merged_end:
			if !placed {
				starts[count], ends[count] = merged_start, merged_end
				count += 1
				placed = true
			}
			starts[count], ends[count] = range_start, range_end
			count += 1
		case:
			merged_start = min(merged_start, range_start)
			merged_end = max(merged_end, range_end)
		}
		if count > RANGE_SET_LIMIT {
			return false
		}
	}
	if !placed {
		if count >= RANGE_SET_LIMIT {
			return false
		}
		starts[count], ends[count] = merged_start, merged_end
		count += 1
	}
	copy(set.starts[:], starts[:count])
	copy(set.ends[:], ends[:count])
	set.count = count
	return true
}

// range_set_drop_lowest removes the lowest range of a set: for packet numbers,
// the oldest ones.
//
// The set of received packet numbers uses it when a new number has no place:
// it forgets its oldest range to make room, and the packet number floor then
// refuses those numbers (`Packet_Number_Space.packet_number_floor`). An empty
// set does not change.
range_set_drop_lowest :: proc "contextless" (set: ^Range_Set) {
	if set.count == 0 {
		return
	}
	copy(set.starts[:], set.starts[1:set.count])
	copy(set.ends[:], set.ends[1:set.count])
	set.count -= 1
}

// range_set_contains says if a number is in a set. The receive path uses it to
// refuse a packet number that came before.
range_set_contains :: proc "contextless" (set: ^Range_Set, value: u64) -> bool {
	for index in 0 ..< set.count {
		if value >= set.starts[index] && value < set.ends[index] {
			return true
		}
	}
	return false
}

// range_set_prefix gives the end of the range that starts at 0: every number
// below it is in the set. 0 when the set has no range from 0.
//
// For the bytes of a stream that came, it is the count of bytes that are there
// in order, with no gap: what the application, or TLS, can read. For
// acknowledged bytes, it is the offset below which the peer has every byte.
range_set_prefix :: proc "contextless" (set: ^Range_Set) -> u64 {
	if set.count > 0 && set.starts[0] == 0 {
		return set.ends[0]
	}
	return 0
}

// range_set_remove_below removes each number below `value` from a set: a range
// that ends at or below it goes, and a range that crosses it is cut to start
// at `value`.
range_set_remove_below :: proc "contextless" (set: ^Range_Set, value: u64) {
	kept := 0
	for index in 0 ..< set.count {
		if set.ends[index] <= value {
			continue
		}
		set.starts[kept] = max(set.starts[index], value)
		set.ends[kept] = set.ends[index]
		kept += 1
	}
	set.count = kept
}

// range_set_take_first removes the first `limit` numbers of the lowest range,
// or the whole range when it is shorter, and gives them.
//
// The send path uses it to take, from the bytes that must go again, as many as
// one frame holds.
//
// - `limit`: the most numbers to take.
//
// **Results**: `start` and `length` of the numbers taken, and `ok` false when
// the set is empty or `limit` is 0.
range_set_take_first :: proc "contextless" (set: ^Range_Set, limit: u64) -> (start: u64, length: u64, ok: bool) {
	if set.count == 0 || limit == 0 {
		return 0, 0, false
	}
	start = set.starts[0]
	length = min(set.ends[0] - start, limit)
	set.starts[0] += length
	if set.starts[0] == set.ends[0] {
		range_set_drop_lowest(set)
	}
	return start, length, true
}

// range_set_largest gives the largest number of a set, and `ok` false when the
// set is empty.
range_set_largest :: proc "contextless" (set: ^Range_Set) -> (largest: u64, ok: bool) {
	if set.count == 0 {
		return 0, false
	}
	return set.ends[set.count - 1] - 1, true
}
