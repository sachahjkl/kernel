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

// A clock in decimal mode and 24 hours, as QEMU gives it.
@(test)
a_reading_of_the_clock :: proc(t: ^testing.T) {
	reading := Clock_Reading{second = 0x20, minute = 0x13, hour = 0x15, day = 0x11, month = 0x11, year = 0x26}
	seconds, valid := clock_seconds(reading, CLOCK_STATUS_24_HOURS)
	testing.expect(t, valid)
	testing.expect_value(t, seconds, i64(1794410000)) // 2026-11-11 15:13:20.
	binary := Clock_Reading{second = 20, minute = 13, hour = 15, day = 11, month = 11, year = 26}
	seconds, valid = clock_seconds(binary, CLOCK_STATUS_24_HOURS | CLOCK_STATUS_BINARY)
	testing.expect(t, valid && seconds == 1794410000)
}

// Bytes that are not values: a half of a byte above 9 in decimal mode, a
// year of 3 digits, a month 13, the day 30 of February, an hour 24.
@(test)
readings_that_are_refused :: proc(t: ^testing.T) {
	good := Clock_Reading{second = 0x20, minute = 0x13, hour = 0x15, day = 0x11, month = 0x11, year = 0x26}
	for change in 0 ..< 6 {
		reading := good
		switch change {
		case 0:
			reading.year = 0xFF
		case 1:
			reading.second = 0x5A
		case 2:
			reading.month = 0x13
		case 3:
			reading.month, reading.day = 0x02, 0x30
		case 4:
			reading.hour = 0x24
		case 5:
			reading.minute = 0x60
		}
		_, valid := clock_seconds(reading, CLOCK_STATUS_24_HOURS)
		testing.expectf(t, !valid, "the change %d gave a valid date", change)
	}
	binary := good
	binary.year = 100
	_, valid := clock_seconds(binary, CLOCK_STATUS_24_HOURS | CLOCK_STATUS_BINARY)
	testing.expect(t, !valid)
}

// 12 hours: 12 in the morning is 0, 12 in the afternoon is 12, 3 in the
// afternoon is 15; 0 and 13 are not hours.
@(test)
twelve_hours :: proc(t: ^testing.T) {
	base := Clock_Reading{second = 0, minute = 0, day = 0x01, month = 0x01, year = 0x30}
	midnight := seconds_of({year = 2030, month = 1, day = 1})
	cases := [?]struct {
		hour:  u8,
		valid: bool,
		value: i64,
	}{{0x12, true, 0}, {0x92, true, 12}, {0x83, true, 15}, {0x01, true, 1}, {0x00, false, 0}, {0x13, false, 0}, {0x93, false, 0}}
	for item in cases {
		reading := base
		reading.hour = item.hour
		seconds, valid := clock_seconds(reading, 0)
		testing.expectf(t, valid == item.valid, "the hour byte %x", item.hour)
		if item.valid {
			testing.expect_value(t, seconds, midnight + item.value * 3600)
		}
	}
}

// The window on the year: 20 to 99 are 2020 to 2099; 00 to 19 give no
// date (an empty battery starts the clock again at 2000).
@(test)
the_window_of_the_year :: proc(t: ^testing.T) {
	reading := Clock_Reading{second = 0, minute = 0, hour = 0, day = 0x01, month = 0x01, year = 0x00}
	_, valid := clock_seconds(reading, CLOCK_STATUS_24_HOURS)
	testing.expect(t, !valid)
	reading.year = 0x19
	_, valid = clock_seconds(reading, CLOCK_STATUS_24_HOURS)
	testing.expect(t, !valid)
	reading.year = 0x20
	seconds: i64
	seconds, valid = clock_seconds(reading, CLOCK_STATUS_24_HOURS)
	testing.expect(t, valid)
	testing.expect_value(t, civil(seconds).year, i64(2020))
	reading.year = 0x99
	seconds, valid = clock_seconds(reading, CLOCK_STATUS_24_HOURS)
	testing.expect(t, valid)
	testing.expect_value(t, civil(seconds).year, i64(2099))
}
