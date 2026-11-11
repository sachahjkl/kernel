package kerneltool

import "core:testing"

// The first difference of two LLVM IR files is a line, with both texts.
@(test)
first_difference_names_the_line_of_the_ir :: proc(t: ^testing.T) {
	first := "; module\n%a = type { i64 }\n@x = global i32 1\n"
	other := "; module\n%a = type { i64 }\n@y = global i32 1\n"
	testing.expect_value(t, first_difference("LLVM IR", transmute([]u8)first, transmute([]u8)other), "line 3 is\n    first: @x = global i32 1\n    this:  @y = global i32 1")
	testing.expect_value(t, first_difference("object", transmute([]u8)first, transmute([]u8)other), "byte 28 of 45 and 45 bytes")
}

// The summary gives the count of builds of each distinct result, in the
// order of their first build.
@(test)
summary_counts_the_builds_of_each_result :: proc(t: ^testing.T) {
	one := Distinct_Results{}
	append(&one.builds_of_each, 30)
	append(&one.contents, nil)
	defer free_results(&one)
	testing.expect_value(t, summary_of_results(one), "1 distinct in 30 builds")
	three := Distinct_Results{}
	append(&three.builds_of_each, 27, 2, 1)
	append(&three.contents, nil, nil, nil)
	defer free_results(&three)
	testing.expect_value(t, summary_of_results(three), "3 distinct in 30 builds: 27, 2, 1")
}
