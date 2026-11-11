#+build !freestanding
package storage_retention

import "core:testing"

MINUTE :: 60 * 1000

// Each version younger than 10 minutes stays, whatever their count.
@(test)
recent_versions_stay :: proc(t: ^testing.T) {
	times: [600]u64
	keep: [600]bool
	for &time, index in times {
		time = 1_000_000 + u64(index) * 1000 // One each second for 10 minutes.
	}
	now := times[len(times) - 1]
	testing.expect_value(t, keeps(times[:], now, keep[:]), 0)
}

// After 10 minutes, the newest version of each hour stays.
@(test)
one_version_each_hour :: proc(t: ^testing.T) {
	// 3 hours of versions, one each minute, seen 4 hours after the first.
	times: [180]u64
	keep: [180]bool
	for &time, index in times {
		time = u64(index) * MINUTE
	}
	now := u64(4 * HOUR_MILLISECONDS)
	thinned := keeps(times[:], now, keep[:])
	testing.expect_value(t, thinned, 177)
	// The newest of hours 0, 1, 2: minutes 59, 119, 179.
	testing.expect(t, keep[59] && keep[119] && keep[179])
	testing.expect(t, !keep[0] && !keep[60] && !keep[178])
}

// A version younger than 10 minutes stays next to an hour that is thinned.
@(test)
the_zones_meet :: proc(t: ^testing.T) {
	times := [?]u64{0, 30 * MINUTE, 50 * MINUTE, 55 * MINUTE, 58 * MINUTE}
	keep: [5]bool
	// At 64 minutes: 58 and 55 are younger than 10 minutes; 50, 30 and 0 are in the hour zone, all in hour 0: 50 is the newest of them.
	thinned := keeps(times[:], u64(64 * MINUTE), keep[:])
	testing.expect(t, keep[4] && keep[3])
	testing.expect(t, keep[2], "the newest of hour 0 in the hour zone")
	testing.expect(t, !keep[1] && !keep[0])
	testing.expect_value(t, thinned, 2)
}

// After one day, the newest version of each day stays.
@(test)
one_version_each_day :: proc(t: ^testing.T) {
	// One each hour for 3 days, seen on day 10.
	times: [72]u64
	keep: [72]bool
	for &time, index in times {
		time = u64(index) * HOUR_MILLISECONDS
	}
	thinned := keeps(times[:], u64(10 * DAY_MILLISECONDS), keep[:])
	testing.expect_value(t, thinned, 69)
	testing.expect(t, keep[23] && keep[47] && keep[71])
}

// A second application keeps what the first one kept: the rule is stable.
@(test)
the_rule_is_stable :: proc(t: ^testing.T) {
	times: [500]u64
	keep: [500]bool
	for &time, index in times {
		time = u64(index) * 7 * MINUTE
	}
	now := u64(len(times)) * 7 * MINUTE
	keeps(times[:], now, keep[:])
	kept: [500]u64
	count := 0
	for time, index in times {
		if keep[index] {
			kept[count] = time
			count += 1
		}
	}
	again: [500]bool
	testing.expect_value(t, keeps(kept[:count], now, again[:count]), 0)
}

// A time after now (a clock that went back) is a version of age 0: kept.
@(test)
a_time_after_now_stays :: proc(t: ^testing.T) {
	times := [?]u64{5 * DAY_MILLISECONDS}
	keep: [1]bool
	testing.expect_value(t, keeps(times[:], u64(DAY_MILLISECONDS), keep[:]), 0)
}
