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

// The age of a version: the smaller of the two ages.
@(test)
ages_of_versions :: proc(t: ^testing.T) {
	DAY_SECONDS :: 86400
	now_date := u64(1_794_400_000) // 2026.
	// No date: the age in running time.
	testing.expect_value(t, age(10 * MINUTE, 4 * MINUTE, 0, 0), u64(6 * MINUTE))
	// The machine was off for a day: the date says one day, the running
	// time says 5 minutes. The smaller one: 5 minutes. A wrong clock on one
	// start cannot make a version older than the time that machines ran.
	testing.expect_value(t, age(10 * MINUTE, 5 * MINUTE, now_date, now_date - DAY_SECONDS), u64(5 * MINUTE))
	// An empty battery on the start of the version: its date is the year
	// 2000. The date says 26 years; the running time says 3 minutes.
	testing.expect_value(t, age(10 * MINUTE, 7 * MINUTE, now_date, 946_684_800), u64(3 * MINUTE))
	// The date of now went back: the version is after now, age 0.
	testing.expect_value(t, age(10 * MINUTE, 7 * MINUTE, now_date - DAY_SECONDS, now_date), u64(0))
	// A date that wrapped from before 1970 is not a date.
	testing.expect_value(t, age(10 * MINUTE, 7 * MINUTE, now_date, max(u64) - 5), u64(3 * MINUTE))
	// A time after now (a disk of another machine): age 0.
	testing.expect_value(t, age(1 * MINUTE, 7 * MINUTE, 0, 0), u64(0))
	testing.expect_value(t, rule_now(5, now_date), now_date * 1000)
	testing.expect_value(t, rule_now(5, 0), u64(5))
}

// Versions of one start with a clock of the year 2000, seen on a start with
// the right date a few minutes of running time later: none is thinned.
@(test)
a_clock_that_jumps_forward_thins_nothing :: proc(t: ^testing.T) {
	now_time := u64(20 * MINUTE)
	now_date := u64(1_794_400_000)
	times: [8]u64
	keep: [8]bool
	now := rule_now(now_time, now_date)
	for &time, index in times {
		version_time := u64(11 * MINUTE) + u64(index) * MINUTE // 2 to 9 minutes of running time ago.
		time = now - age(now_time, version_time, now_date, 946_684_800 + u64(index) * 60)
	}
	testing.expect_value(t, keeps(times[:], now, keep[:]), 0)
}
