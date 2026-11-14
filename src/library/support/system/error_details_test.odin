#+build !freestanding
package system

import "modus:contract/errors"
import "core:testing"

// A nil table: the caller asked for no details. Nothing is written, and the
// call goes on.
@(test)
error_detail_append_with_no_table :: proc(t: ^testing.T) {
	error_detail_append(nil, errors.error_make(.Absent, .None, 1, 0, 0, 2))
	testing.expect_value(t, len(error_details_written(nil)), 0)
}

// A table too small keeps the count of the full answer: the caller learns
// how many details there were. No record is written at or after the
// capacity.
@(test)
error_detail_append_to_a_small_table :: proc(t: ^testing.T) {
	records: [3]errors.Error_Record
	records[2] = {kind = 99}
	details := Error_Details{records = &records[0], count = 0, capacity = 2}
	for row in 1 ..= 5 {
		error_detail_append(&details, errors.error_make(.Absent, .None, 1, 0, 0, i64(row)))
	}
	testing.expect_value(t, details.count, 5)
	written := error_details_written(&details)
	testing.expect_value(t, len(written), 2)
	testing.expect_value(t, written[0].found, 1)
	testing.expect_value(t, written[1].found, 2)
	testing.expect_value(t, records[2].kind, 99)
	// A table with no place: the count only.
	empty := Error_Details{}
	error_detail_append(&empty, errors.error_make(.Absent))
	testing.expect_value(t, empty.count, 1)
	testing.expect_value(t, len(error_details_written(&empty)), 0)
}
