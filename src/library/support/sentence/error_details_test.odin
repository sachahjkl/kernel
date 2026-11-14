#+build !freestanding
package sentence

import "contract:errors"
import "core:strings"
import "core:testing"

// An error detail is an error record: the sentence of a record writes it,
// after the number of the detail.
@(test)
error_detail_line :: proc(t: ^testing.T) {
	buffer: [256]u8
	writer := Writer{buffer = buffer[:]}
	detail := errors.error_make(.Absent, .None, 1, 0, 0, 3)
	error_detail_number_text(&writer, 2, 3)
	error_text(&writer, &detail, "monitor.counts_named", "names")
	line := written(&writer)
	testing.expectf(t, strings.has_prefix(line, "detail 2 of 3: monitor.counts_named: row 3 of the argument names"), "the line is %q", line)
}

@(test)
error_details_that_did_not_fit :: proc(t: ^testing.T) {
	buffer: [256]u8
	writer := Writer{buffer = buffer[:]}
	error_details_rest_text(&writer, 16, 16)
	testing.expect_value(t, written(&writer), "")
	error_details_rest_text(&writer, 16, 17)
	testing.expect_value(t, written(&writer), "1 more error detail did not fit in the table of error details")
	writer = Writer{buffer = buffer[:]}
	error_details_rest_text(&writer, 16, 40)
	testing.expect_value(t, written(&writer), "24 more error details did not fit in the table of error details")
}
