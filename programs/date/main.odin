// The date of the machine: this service reads the real-time clock of the machine (the CMOS clock, ports 0x70 and 0x71) at its start and each 10 seconds, and writes in the date page the date of the time 0 of the system. Each program reads the date from the page and the time page, with no kernel entry and no call (contract/date).
//
// A driver of a clock is a program, not a part of the kernel: the root service gives this program the two ports and the page with the right Write, and nothing else.
//
// The clock gives whole seconds. The service waits for the clock to change its second, so the date of the time 0 is exact to about one millisecond. The clock of the machine keeps UTC (QEMU: -rtc base=utc). Leap seconds are not counted. The year has two digits: the dates are from 2020 to 2099 (support/calendar, clock_seconds).
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
REGISTER_STATUS_B :: 0x0B // The mode of the values (calendar.CLOCK_STATUS_BINARY, CLOCK_STATUS_24_HOURS).

// The bounds of the reads: a clock that never ends an update, or whose
// registers change at each read, gives no date; the service then waits for
// no clock.
UPDATE_READS_LIMIT :: 10_000 // An update takes about 2 ms; one read of a port takes about 1 us.
STABLE_READS_LIMIT :: 8

// register_read reads one register of the clock. Bit 7 of the index is 0,
// so the non-maskable interrupt stays on. The grant of the two ports lets
// this program write any index and read any byte of the memory of the
// clock: the processor gives a program a port, not a value of a port.
register_read :: proc "contextless" (register: u8) -> u8 {
	system.port_write_8(PORT_INDEX, register)
	return system.port_read_8(PORT_DATA)
}

// clock_read reads the registers of the date, after the end of an update.
clock_read :: proc "contextless" () -> (reading: calendar.Clock_Reading, valid: bool) {
	for reads := 0; register_read(REGISTER_STATUS_A) & 0x80 != 0; reads += 1 {
		if reads >= UPDATE_READS_LIMIT {
			return {}, false
		}
	}
	reading.second = register_read(REGISTER_SECONDS)
	reading.minute = register_read(REGISTER_MINUTES)
	reading.hour = register_read(REGISTER_HOURS)
	reading.day = register_read(REGISTER_DAY)
	reading.month = register_read(REGISTER_MONTH)
	reading.year = register_read(REGISTER_YEAR)
	return reading, true
}

// stable_read reads the clock until two readings agree: an update between
// two registers gives a wrong mix.
stable_read :: proc "contextless" () -> (reading: calendar.Clock_Reading, valid: bool) {
	reading = clock_read() or_return
	for _ in 0 ..< STABLE_READS_LIMIT {
		again := clock_read() or_return
		if again == reading {
			return reading, true
		}
		reading = again
	}
	return {}, false
}

// seconds_of_reading gives the seconds since 1970 of a reading, in the mode
// of the clock (calendar.clock_seconds checks each field).
seconds_of_reading :: proc "contextless" (reading: calendar.Clock_Reading) -> (seconds: i64, valid: bool) {
	return calendar.clock_seconds(reading, register_read(REGISTER_STATUS_B))
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
	first := stable_read() or_return
	reading := first
	edge: u64
	for reading.second == first.second && system.nanoseconds() - started < 2_000_000_000 {
		system.sleep(system.time() + 1)
		reading = stable_read() or_return
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
			system.log("date: the clock read again at the time ", edge_now, " ms of the system: the date moved by ", corrected - before, " ms; ", corrected - first_at_zero, " ms since the start, ", corrections, corrections == 1 ? string(" read") : string(" reads"), " after the first")
		}
	}
}
