package kerneltool

import "core:strings"
import "core:testing"

// The lines of a procedure come from the source: a comment or a line added
// above the procedure moves them.
@(test)
source_lines_follow_the_procedure :: proc(t: ^testing.T) {
	source := "package fault\n\nthree :: #force_no_inline proc \"contextless\" (address: uintptr) {\n\twrite(address)\n}\n\ntwo :: proc() {\n\tif true {\n\t}\n\tthree(0)\n}\n"
	first_line, last_line, found := source_lines_of_procedure(source, "three")
	testing.expect(t, found)
	testing.expect_value(t, first_line, 3)
	testing.expect_value(t, last_line, 5)
	first_line, last_line, found = source_lines_of_procedure(source, "two")
	testing.expect(t, found)
	testing.expect_value(t, first_line, 7)
	testing.expect_value(t, last_line, 11)
	moved := "// A new comment.\n// A second line.\n"
	first_line, last_line, found = source_lines_of_procedure(strings.concatenate({moved, source}, context.temp_allocator), "three")
	testing.expect(t, found)
	testing.expect_value(t, first_line, 5)
	testing.expect_value(t, last_line, 7)
}

// A name that is not a procedure of the top level is not found: a constant,
// a name that only starts the same, a procedure with no end.
@(test)
source_lines_refuse_what_is_not_a_procedure :: proc(t: ^testing.T) {
	source := "three_count :: 3\nthree :: 3\nfour :: proc() {\n\treturn\n"
	_, _, found := source_lines_of_procedure(source, "three")
	testing.expect(t, !found)
	_, _, found = source_lines_of_procedure(source, "four")
	testing.expect(t, !found)
	_, _, found = source_lines_of_procedure(source, "five")
	testing.expect(t, !found)
}
