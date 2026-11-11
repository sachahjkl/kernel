// The date (docs/ARCHITECTURE.md, "The date"): one page that the root
// service creates. The program `date` is its one writer: it reads the
// real-time clock of the machine through two ports: a driver is a program, not a part
// of the kernel and writes the date of the time 0 of the system. Each
// program that the root service starts maps the page with the right Read
// only, at PAGE_ADDRESS; the context value VALUE_PAGE says where it is (0:
// the program has no page).
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
import op "contract:operation"

PAGE_ADDRESS :: 0x0000_3400_0000_0000
VALUE_PAGE :: 15 // The value of the context with the address of the page, for each program that the root service starts.
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
	return ctx.values[VALUE_PAGE] == PAGE_ADDRESS ? (^Page)(uintptr(PAGE_ADDRESS)) : nil
}

// milliseconds_now gives the milliseconds since 1970 (UTC) at the time
// `system_milliseconds` of the system (system.time()). known is false when
// the program has no page or the page has no date.
milliseconds_now :: proc "contextless" (page: ^Page, system_milliseconds: u64) -> (milliseconds: i64, known: bool) {
	if page == nil {
		return 0, false
	}
	for {
		before := intrinsics.atomic_load_explicit(&page.change_count, .Acquire)
		if before & 1 != 0 {
			continue
		}
		source := Source(intrinsics.atomic_load_explicit((^u32)(&page.source), .Acquire))
		at_zero := intrinsics.atomic_load_explicit(&page.milliseconds_at_time_zero, .Acquire)
		if intrinsics.atomic_load_explicit(&page.change_count, .Acquire) == before {
			if source == .None {
				return 0, false
			}
			return at_zero + i64(system_milliseconds), true
		}
	}
}

// write sets the date of the time 0. The one writer is the program `date`.
write :: proc "contextless" (page: ^Page, source: Source, milliseconds_at_time_zero: i64) {
	intrinsics.atomic_store_explicit(&page.change_count, page.change_count + 1, .Release)
	intrinsics.atomic_store_explicit((^u32)(&page.source), u32(source), .Release)
	intrinsics.atomic_store_explicit(&page.milliseconds_at_time_zero, milliseconds_at_time_zero, .Release)
	intrinsics.atomic_store_explicit(&page.change_count, page.change_count + 1, .Release)
}
