// The date (docs/ARCHITECTURE.md, "The date"): one page that the root
// service creates. The program `date` is its one writer: it reads the
// real-time clock of the machine through two ports (a driver is a program,
// not a part of the kernel) and writes the date of the time 0 of the
// system. Each program that the root service starts by its name, and the
// compositor, map the page with the right Read only, at PAGE_ADDRESS; the
// bit of the range Date_Page in the context value
// op.CONTEXT_VALUE_FIXED_RANGES_MAPPED says that it is mapped (clear: the
// program has no page). A
// terminal has no page: it shows the text of another program, and needs no
// date. A program that another program starts has none either.
//
// The date of now is milliseconds_at_time_zero + the milliseconds of the
// time page (system.time()): no kernel entry. The date is in UTC; the time
// zone will be a setting of the person (not built). Leap seconds are not
// counted: a day has 86400 seconds, as in the time of POSIX.
//
// A change: the writer makes change_count odd, writes the fields, makes it
// even again. A reader copies the fields while change_count stays even and
// the same (read). All zero is valid (ZII): no date is known.
package date

import "base:intrinsics"
import "contract:fixed_addresses"
import op "contract:operation"

PAGE_ADDRESS :: fixed_addresses.DATE_PAGE_ADDRESS
GRANT_PAGE :: 6 // The handle of the context of the program `date`: the page, with Read and Write.
GRANT_PORTS :: 7 // The handle of the context of the program `date`: the ports 0x70 and 0x71 of the real-time clock.

Source :: enum u32 {
	None           = 0, // No date is known.
	Real_Time_Clock = 1, // The real-time clock of the machine (CMOS), read at the start.
}

Page :: struct {
	change_count:              u32, // Even when the page is stable. Each change adds 2.
	source:                    Source,
	milliseconds_at_time_zero: i64, // Milliseconds since 1970-01-01 00:00:00 UTC at the time 0 of the system.
	zone_offset_seconds:       i64, // The time zone of the person: 0, UTC, until the settings have it.
}
#assert(size_of(Page) <= 4096)

// page_of gives the date page of a program, or nil.
page_of :: proc "contextless" (ctx: ^op.Context) -> ^Page {
	return .Date_Page in fixed_addresses.ranges_mapped(&ctx.values) ? (^Page)(uintptr(PAGE_ADDRESS)) : nil
}

// The dates that a reader takes: from 1970 to the end of the year 9999. A
// page with another date gives no date.
DATE_MILLISECONDS_LIMIT :: i64(253402300800) * 1000

// READ_TRIES is the most reads of a page that changes, or that a writer left
// in the middle of a change (a writer stopped between its two stores): the
// reader then gives no date, and never waits on another program.
READ_TRIES :: 64

// milliseconds_now gives the milliseconds since 1970 (UTC) at the time
// `system_milliseconds` of the system (system.time()). known is false when
// the program has no page, when the page has no date, when the date is not
// from 1970 to 9999, and when the page changed at each of READ_TRIES reads.
milliseconds_now :: proc "contextless" (page: ^Page, system_milliseconds: u64) -> (milliseconds: i64, known: bool) {
	if page == nil {
		return 0, false
	}
	for _ in 0 ..< READ_TRIES {
		before := intrinsics.atomic_load_explicit(&page.change_count, .Acquire)
		if before & 1 != 0 {
			intrinsics.cpu_relax()
			continue
		}
		source := Source(intrinsics.atomic_load_explicit((^u32)(&page.source), .Acquire))
		at_zero := intrinsics.atomic_load_explicit(&page.milliseconds_at_time_zero, .Acquire)
		if intrinsics.atomic_load_explicit(&page.change_count, .Acquire) != before {
			continue
		}
		if source == .None || system_milliseconds > u64(DATE_MILLISECONDS_LIMIT) {
			return 0, false
		}
		milliseconds = at_zero + i64(system_milliseconds)
		if at_zero <= 0 || milliseconds <= 0 || milliseconds >= DATE_MILLISECONDS_LIMIT {
			return 0, false
		}
		return milliseconds, true
	}
	return 0, false
}

// write sets the date of the time 0. The one writer is the program `date`.
write :: proc "contextless" (page: ^Page, source: Source, milliseconds_at_time_zero: i64) {
	intrinsics.atomic_store_explicit(&page.change_count, page.change_count + 1, .Release)
	intrinsics.atomic_store_explicit((^u32)(&page.source), u32(source), .Release)
	intrinsics.atomic_store_explicit(&page.milliseconds_at_time_zero, milliseconds_at_time_zero, .Release)
	intrinsics.atomic_store_explicit(&page.change_count, page.change_count + 1, .Release)
}
