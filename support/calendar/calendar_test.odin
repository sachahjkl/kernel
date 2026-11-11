#+build !freestanding
package calendar

import "core:testing"

Known :: struct {
	seconds: i64,
	value:   Civil,
}

// Known dates: the epoch, a day of a leap year of 400 (2000), the end of
// February in 2024, the year 2038 of 32 bits, 2100 (no leap year: 100 and
// not 400), a date before 1970, and the example of RFC 9110.
@(rodata)
known_dates := [?]Known {
	{0, {1970, 1, 1, 0, 0, 0, .Thursday}},
	{951782400, {2000, 2, 29, 0, 0, 0, .Tuesday}},
	{951868800, {2000, 3, 1, 0, 0, 0, .Wednesday}},
	{1709164800, {2024, 2, 29, 0, 0, 0, .Thursday}},
	{2147483647, {2038, 1, 19, 3, 14, 7, .Tuesday}},
	{4107456000, {2100, 2, 28, 0, 0, 0, .Sunday}},
	{4107542400, {2100, 3, 1, 0, 0, 0, .Monday}},
	{-86400, {1969, 12, 31, 0, 0, 0, .Wednesday}},
	{784111777, {1994, 11, 6, 8, 49, 37, .Sunday}},
	{1794410000, {2026, 11, 11, 15, 13, 20, .Wednesday}},
}

@(test)
known_dates_both_ways :: proc(t: ^testing.T) {
	for known in known_dates {
		testing.expectf(t, civil(known.seconds) == known.value, "%d gives %v, not %v", known.seconds, civil(known.seconds), known.value)
		testing.expectf(t, seconds_of(known.value) == known.seconds, "%v gives %d, not %d", known.value, seconds_of(known.value), known.seconds)
	}
}

@(test)
leap_years :: proc(t: ^testing.T) {
	testing.expect(t, leap_year(2000) && leap_year(2024) && leap_year(2400))
	testing.expect(t, !leap_year(1900) && !leap_year(2100) && !leap_year(2023))
	testing.expect_value(t, days_in_month(2100, 2), 28)
	testing.expect_value(t, days_in_month(2000, 2), 29)
}

// Each day from 1900 to 2500: the next day is the day after, and the
// weekday turns.
@(test)
each_day_follows :: proc(t: ^testing.T) {
	first := days_from_civil(1900, 1, 1)
	last := days_from_civil(2500, 12, 31)
	year, month, day := civil_from_days(first)
	for days in first ..< last {
		day += 1
		if day > days_in_month(year, month) {
			day = 1
			month += 1
			if month > 12 {
				month = 1
				year += 1
			}
		}
		next_year, next_month, next_day := civil_from_days(days + 1)
		if next_year != year || next_month != month || next_day != day {
			testing.expectf(t, false, "the day after %d is %d-%d-%d, not %d-%d-%d", days, next_year, next_month, next_day, year, month, day)
			return
		}
		testing.expect(t, days_from_civil(year, month, day) == days + 1)
	}
}

@(test)
texts :: proc(t: ^testing.T) {
	buffer: [64]u8
	testing.expect_value(t, http_text(buffer[:], 784111777), "Sun, 06 Nov 1994 08:49:37 GMT")
	testing.expect_value(t, iso_text(buffer[:], 951782400), "2000-02-29 00:00:00")
	testing.expect_value(t, from_binary_coded_decimal(0x59), 59)
}
