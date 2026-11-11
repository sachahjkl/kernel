package quic

// A set of ranges of numbers, with no allocation: the packet numbers that a
// side received (for its ACK frames), the bytes of a stream that came or that
// the peer acknowledged, and the bytes that wait to be sent again. Each range
// is [start, end), in ascending order; two ranges never touch.

RANGE_SET_LIMIT :: 32

Range_Set :: struct {
	starts: [RANGE_SET_LIMIT]u64,
	ends:   [RANGE_SET_LIMIT]u64,
	count:  int,
}

// range_set_insert adds [start, end) and merges the ranges that it touches.
// If the result would need more than RANGE_SET_LIMIT ranges, the set does not
// change and the call gives false: the caller drops what it inserts (a peer
// that sends data with many holes gets it acknowledged later).
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

// range_set_drop_lowest removes the lowest range: the packet numbers that are
// the oldest, when a new one has no place.
range_set_drop_lowest :: proc "contextless" (set: ^Range_Set) {
	if set.count == 0 {
		return
	}
	copy(set.starts[:], set.starts[1:set.count])
	copy(set.ends[:], set.ends[1:set.count])
	set.count -= 1
}

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
range_set_prefix :: proc "contextless" (set: ^Range_Set) -> u64 {
	if set.count > 0 && set.starts[0] == 0 {
		return set.ends[0]
	}
	return 0
}

// range_set_remove_below removes each number below value.
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

// range_set_take_first removes the first limit numbers of the lowest range,
// or the whole range when it is shorter, and gives them.
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

// range_set_largest gives the largest number of the set.
range_set_largest :: proc "contextless" (set: ^Range_Set) -> (largest: u64, ok: bool) {
	if set.count == 0 {
		return 0, false
	}
	return set.ends[set.count - 1] - 1, true
}
