// The date of the machine: this service reads the real-time clock of the machine (the CMOS clock, ports 0x70 and 0x71) one time at its start, and writes in the date page the date of the time 0 of the system. Each program reads the date from the page and the time page, with no kernel entry and no call (contract/date).
//
// A driver of a clock is a program, not a part of the kernel: the root service gives this program the two ports and the page with the right Write, and nothing else.
//
// The clock gives whole seconds. The service waits for the clock to change its second, so the date of the time 0 is exact to about one millisecond. The clock of the machine keeps UTC (QEMU: -rtc base=utc). Leap seconds are not counted.
package date_service

import "contract:date"
import "support:calendar"
import "support:system"

PORT_INDEX :: 0x70
PORT_DATA :: 0x71

REGISTER_SECONDS :: 0x00
REGISTER_MINUTES :: 0x02
REGISTER_HOURS :: 0x04
REGISTER_DAY :: 0x07
REGISTER_MONTH :: 0x08
REGISTER_YEAR :: 0x09
REGISTER_STATUS_A :: 0x0A // Bit 7: the clock updates its registers now.
REGISTER_STATUS_B :: 0x0B // Bit 2: binary values (else two decimal digits in a byte). Bit 1: 24 hours (else 12, with bit 7 of the hour for the afternoon).
REGISTER_CENTURY :: 0x32 // The century, in the register that the ACPI table names on QEMU and on most machines.

register_read :: proc "contextless" (register: u8) -> u8 {
	system.port_write_8(PORT_INDEX, register) // Bit 7 is 0: the non-maskable interrupt stays on.
	return system.port_read_8(PORT_DATA)
}

Clock_Reading :: struct {
	second, minute, hour, day, month, year, century: u8,
}

clock_read :: proc "contextless" () -> (reading: Clock_Reading) {
	for register_read(REGISTER_STATUS_A) & 0x80 != 0 {
	}
	reading.second = register_read(REGISTER_SECONDS)
	reading.minute = register_read(REGISTER_MINUTES)
	reading.hour = register_read(REGISTER_HOURS)
	reading.day = register_read(REGISTER_DAY)
	reading.month = register_read(REGISTER_MONTH)
	reading.year = register_read(REGISTER_YEAR)
	reading.century = register_read(REGISTER_CENTURY)
	return reading
}

// stable_read reads the clock until two readings agree: an update between
// two registers gives a wrong mix.
stable_read :: proc "contextless" () -> Clock_Reading {
	reading := clock_read()
	for {
		again := clock_read()
		if again == reading {
			return reading
		}
		reading = again
	}
}

// seconds_of_reading gives the seconds since 1970 of a reading.
seconds_of_reading :: proc "contextless" (reading: Clock_Reading) -> (seconds: i64, valid: bool) {
	status := register_read(REGISTER_STATUS_B)
	binary := status & 0x04 != 0
	hours_24 := status & 0x02 != 0
	value :: proc "contextless" (byte: u8, binary: bool) -> int {
		return binary ? int(byte) : calendar.from_binary_coded_decimal(byte)
	}
	afternoon := !hours_24 && reading.hour & 0x80 != 0
	hour := value(reading.hour & 0x7F, binary)
	if !hours_24 {
		hour = hour % 12 + (afternoon ? 12 : 0)
	}
	century := value(reading.century, binary)
	if century < 19 || century > 99 {
		century = 20 // A clock with no century register.
	}
	civil := calendar.Civil {
		year   = i64(century * 100 + value(reading.year, binary)),
		month  = value(reading.month, binary),
		day    = value(reading.day, binary),
		hour   = hour,
		minute = value(reading.minute, binary),
		second = value(reading.second, binary),
	}
	valid = civil.month >= 1 && civil.month <= 12 && civil.day >= 1 && civil.day <= calendar.days_in_month(civil.year, civil.month) && civil.hour < 24 && civil.minute < 60 && civil.second < 60
	return calendar.seconds_of(civil), valid
}

// One answer of now().
Date :: struct {
	milliseconds: i64, // Since 1970-01-01 00:00:00 UTC.
	year:         i64,
	month:        i64,
	day:          i64,
	hour:         i64,
	minute:       i64,
	second:       i64,
	weekday:      i64, // 1: Monday to 7: Sunday (ISO 8601).
}

page: ^date.Page

// now gives the date and the time of day in UTC, from the date page and the time page: the same value that each program reads with no call. All zero: the machine has no date.
@(export, link_name = "now")
now :: proc "c" (result: ^Date) {
	milliseconds, known := date.milliseconds_now(page, system.time())
	if !known {
		result^ = {}
		return
	}
	value := calendar.civil(calendar.floor_divide(milliseconds, 1000))
	result^ = {milliseconds = milliseconds, year = value.year, month = i64(value.month), day = i64(value.day), hour = i64(value.hour), minute = i64(value.minute), second = i64(value.second), weekday = i64(value.weekday) + 1}
}

RESYNC_MILLISECONDS :: 10_000 // The time between two reads of the clock.

// synchronize waits for the clock to change its second (up to 2 seconds),
// and gives the date of the time 0 of the system at that edge.
synchronize :: proc "contextless" () -> (at_zero: i64, seconds: i64, edge_milliseconds: u64, valid: bool) {
	started := system.nanoseconds()
	first := stable_read()
	reading := first
	edge: u64
	for reading.second == first.second && system.nanoseconds() - started < 2_000_000_000 {
		system.sleep(system.time() + 1)
		reading = stable_read()
		edge = system.nanoseconds()
	}
	seconds, valid = seconds_of_reading(reading)
	if !valid || reading.second == first.second {
		return 0, 0, 0, false
	}
	return seconds * 1000 - i64(edge / 1_000_000), seconds, edge / 1_000_000, true
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	service, _ := system.service_open(ctx)
	address, status := system.memory_map(ctx.handles[date.GRANT_PAGE], {.Write})
	if status != .Ok || ctx.handles[date.GRANT_PORTS] == 0 {
		system.log_in("date", .Error, "date: no date page or no ports of the clock: the system has no date")
		system.stop(1)
	}
	page = (^date.Page)(address)
	started := system.nanoseconds()
	at_zero, seconds, edge, valid := synchronize()
	if !valid {
		system.log_in("date", .Error, "date: the real-time clock gives no valid date: the system has no date")
	} else {
		date.write(page, .Real_Time_Clock, at_zero)
		text: [32]u8
		system.log("date: ok, ", calendar.iso_text(text[:], seconds), " UTC, seconds since 1970 ", seconds, ", from the real-time clock at the time ", edge, " ms of the system; the date of the time 0 in ", (system.nanoseconds() - started) / 1000, " us")
	}
	// The time of the system comes from the cycle counter, with a frequency
	// that the kernel measured at boot: it can run faster or slower than the
	// clock. The service reads the clock again at an interval and corrects the
	// page, so the date never drifts more than the drift of one interval.
	first_at_zero := at_zero
	corrections: u64
	next := system.time() + RESYNC_MILLISECONDS
	for {
		wait: system.Wait
		system.service_wait(&wait, &service)
		system.wait_end(&wait, next)
		system.service_run(&service)
		if system.time() < next {
			continue
		}
		next = system.time() + RESYNC_MILLISECONDS
		corrected, _, edge_now, corrected_valid := synchronize()
		if !corrected_valid {
			continue
		}
		_, known := date.milliseconds_now(page, 0)
		before := page.milliseconds_at_time_zero
		date.write(page, .Real_Time_Clock, corrected)
		corrections += 1
		if !known || corrections == 1 || corrections % 30 == 0 || abs(corrected - before) >= 1000 {
			// The drift since the first read: what the time of the system lost
			// or gained against the clock.
			system.log("date: the clock read again at the time ", edge_now, " ms of the system: the date moved by ", corrected - before, " ms; ", corrected - first_at_zero, " ms since the start, ", corrections, corrections == 1 ? " read" : " reads", " after the first")
		}
	}
}
