// The Gregorian calendar in UTC: the year, the month, the day, the time of
// day and the weekday of a count of seconds since 1970-01-01 00:00:00 UTC,
// and back. Pure code, with host tests. Leap seconds are not counted (each
// day has 86400 seconds, as the time of POSIX).
//
// The days from 1970 use the algorithm of Howard Hinnant ("chrono-compatible
// low-level date algorithms"): eras of 400 years, each of 146097 days, so
// the rules of 4, 100 and 400 years come from one division.
package calendar

import "base:intrinsics"

SECONDS_IN_A_DAY :: 86400

Weekday :: enum u8 {
	Monday    = 0,
	Tuesday   = 1,
	Wednesday = 2,
	Thursday  = 3,
	Friday    = 4,
	Saturday  = 5,
	Sunday    = 6,
}

Civil :: struct {
	year:    i64,
	month:   int, // 1 to 12.
	day:     int, // 1 to 31.
	hour:    int,
	minute:  int,
	second:  int,
	weekday: Weekday,
}

@(rodata)
WEEKDAY_SHORT_NAMES := [Weekday]string{.Monday = "Mon", .Tuesday = "Tue", .Wednesday = "Wed", .Thursday = "Thu", .Friday = "Fri", .Saturday = "Sat", .Sunday = "Sun"}

@(rodata)
MONTH_SHORT_NAMES := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

leap_year :: proc "contextless" (year: i64) -> bool {
	return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

days_in_month :: proc "contextless" (year: i64, month: int) -> int {
	lengths := [12]int{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
	if month == 2 && leap_year(year) {
		return 29
	}
	return lengths[clamp(month, 1, 12) - 1]
}

// floor_divide divides and rounds toward minus infinity.
floor_divide :: proc "contextless" (value, divisor: i64) -> i64 {
	quotient := value / divisor
	if value % divisor != 0 && (value < 0) != (divisor < 0) {
		quotient -= 1
	}
	return quotient
}

// days_from_civil gives the days from 1970-01-01 to a date.
days_from_civil :: proc "contextless" (year: i64, month: int, day: int) -> i64 {
	shifted := month <= 2 ? year - 1 : year
	era := floor_divide(shifted, 400)
	year_of_era := shifted - era * 400
	month_from_march := i64(month > 2 ? month - 3 : month + 9)
	day_of_year := (153 * month_from_march + 2) / 5 + i64(day) - 1
	day_of_era := year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year
	return era * 146097 + day_of_era - 719468
}

// civil_from_days gives the date of a count of days from 1970-01-01.
civil_from_days :: proc "contextless" (days: i64) -> (year: i64, month: int, day: int) {
	shifted := days + 719468
	era := floor_divide(shifted, 146097)
	day_of_era := shifted - era * 146097
	year_of_era := (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096) / 365
	day_of_year := day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100)
	month_from_march := (5 * day_of_year + 2) / 153
	day = int(day_of_year - (153 * month_from_march + 2) / 5 + 1)
	month = int(month_from_march < 10 ? month_from_march + 3 : month_from_march - 9)
	year = year_of_era + era * 400 + (month <= 2 ? 1 : 0)
	return year, month, day
}

// civil gives the date and the time of day of a count of seconds since 1970.
civil :: proc "contextless" (seconds: i64) -> (result: Civil) {
	days := floor_divide(seconds, SECONDS_IN_A_DAY)
	in_day := seconds - days * SECONDS_IN_A_DAY
	result.year, result.month, result.day = civil_from_days(days)
	result.hour = int(in_day / 3600)
	result.minute = int(in_day / 60 % 60)
	result.second = int(in_day % 60)
	// 1970-01-01 was a Thursday.
	result.weekday = Weekday((floor_divide(days, 1) % 7 + 7 + 3) % 7)
	return result
}

// seconds_of gives the seconds since 1970 of a date and a time of day.
seconds_of :: proc "contextless" (value: Civil) -> i64 {
	return days_from_civil(value.year, value.month, value.day) * SECONDS_IN_A_DAY + i64(value.hour) * 3600 + i64(value.minute) * 60 + i64(value.second)
}

@(private)
put_digits :: proc "contextless" (buffer: []u8, at: ^int, value: i64, digits: int) {
	for place := digits - 1; place >= 0; place -= 1 {
		divisor: i64 = 1
		for _ in 0 ..< place {
			divisor *= 10
		}
		if at^ < len(buffer) {
			buffer[at^] = u8('0' + value / divisor % 10)
		}
		at^ += 1
	}
}

@(private)
put_text :: proc "contextless" (buffer: []u8, at: ^int, text: string) {
	for byte in transmute([]u8)text {
		if at^ < len(buffer) {
			buffer[at^] = byte
		}
		at^ += 1
	}
}

// iso_text writes "2026-11-11 16:30:05" into buffer and gives it.
iso_text :: proc "contextless" (buffer: []u8, seconds: i64) -> string {
	value := civil(seconds)
	at := 0
	put_digits(buffer, &at, value.year, 4)
	put_text(buffer, &at, "-")
	put_digits(buffer, &at, i64(value.month), 2)
	put_text(buffer, &at, "-")
	put_digits(buffer, &at, i64(value.day), 2)
	put_text(buffer, &at, " ")
	put_digits(buffer, &at, i64(value.hour), 2)
	put_text(buffer, &at, ":")
	put_digits(buffer, &at, i64(value.minute), 2)
	put_text(buffer, &at, ":")
	put_digits(buffer, &at, i64(value.second), 2)
	return string(buffer[:min(at, len(buffer))])
}

// http_text writes the date of HTTP (RFC 9110, 5.6.7, IMF-fixdate):
// "Sun, 06 Nov 1994 08:49:37 GMT".
http_text :: proc "contextless" (buffer: []u8, seconds: i64) -> string {
	value := civil(seconds)
	at := 0
	put_text(buffer, &at, WEEKDAY_SHORT_NAMES[value.weekday])
	put_text(buffer, &at, ", ")
	put_digits(buffer, &at, i64(value.day), 2)
	put_text(buffer, &at, " ")
	put_text(buffer, &at, MONTH_SHORT_NAMES[value.month - 1])
	put_text(buffer, &at, " ")
	put_digits(buffer, &at, value.year, 4)
	put_text(buffer, &at, " ")
	put_digits(buffer, &at, i64(value.hour), 2)
	put_text(buffer, &at, ":")
	put_digits(buffer, &at, i64(value.minute), 2)
	put_text(buffer, &at, ":")
	put_digits(buffer, &at, i64(value.second), 2)
	put_text(buffer, &at, " GMT")
	return string(buffer[:min(at, len(buffer))])
}

// from_binary_coded_decimal gives the value of a byte of two decimal digits.
from_binary_coded_decimal :: proc "contextless" (value: u8) -> int {
	return int(value >> 4) * 10 + int(value & 0x0F)
}

_ :: intrinsics
