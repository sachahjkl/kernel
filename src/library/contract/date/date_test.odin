#+build !freestanding
package date

import "core:testing"

@(test)
a_page_with_a_date :: proc(t: ^testing.T) {
	page: Page
	write(&page, .Real_Time_Clock, 1_794_400_000_000)
	milliseconds, known := milliseconds_now(&page, 5000)
	testing.expect(t, known)
	testing.expect_value(t, milliseconds, i64(1_794_400_005_000))
	testing.expect_value(t, page.change_count, u32(2))
}

// A writer stopped between its two stores leaves the count odd: a reader
// gives no date after READ_TRIES reads, and does not wait.
@(test)
a_writer_stopped_in_a_change :: proc(t: ^testing.T) {
	page: Page
	write(&page, .Real_Time_Clock, 1_794_400_000_000)
	page.change_count += 1
	_, known := milliseconds_now(&page, 5000)
	testing.expect(t, !known)
}

@(test)
pages_with_no_date :: proc(t: ^testing.T) {
	_, known := milliseconds_now(nil, 5000)
	testing.expect(t, !known)
	page: Page
	_, known = milliseconds_now(&page, 5000) // All zero: no source.
	testing.expect(t, !known)
	write(&page, .Real_Time_Clock, -86_400_000) // 1969.
	_, known = milliseconds_now(&page, 5000)
	testing.expect(t, !known)
	write(&page, .Real_Time_Clock, DATE_MILLISECONDS_LIMIT) // The year 10000.
	_, known = milliseconds_now(&page, 0)
	testing.expect(t, !known)
}
