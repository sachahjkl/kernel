#+build !freestanding
package console_language

import "core:testing"
import terminal "support:terminal"

// The names of a console of the tests.
test_name_role :: proc "contextless" (data: rawptr, name: string) -> Name_Role {
	switch name {
	case "monitor.count", "length", "help":
		return .Function
	case "Rectangle":
		return .Record
	case "monitor", "storage":
		return .Module
	case "x", "r":
		return .Variable
	}
	return .Unknown
}

test_names := Name_Lookup {
	role_of = test_name_role,
}

Expected_Run :: struct {
	text: string,
	kind: terminal.Code_Kind,
}

// expect_runs compares the runs of a text with the parts expected, in order.
expect_runs :: proc(t: ^testing.T, text: string, runs: []terminal.Code_Run, expected: []Expected_Run, loc := #caller_location) {
	testing.expectf(t, len(runs) == len(expected), "%q: %d runs, not %d", text, len(runs), len(expected), loc = loc)
	for index in 0 ..< min(len(runs), len(expected)) {
		run := runs[index]
		part := text[int(run.start):][:int(run.length)]
		testing.expectf(t, part == expected[index].text && run.kind == expected[index].kind, "%q: run %d is %q %v, not %q %v", text, index, part, run.kind, expected[index].text, expected[index].kind, loc = loc)
	}
}

// expect_cover checks that the runs are inside the text, in order, with no
// overlap, and that each byte between two runs is a space: no part of a
// finished line is left with no kind, unless the runs are full.
expect_cover :: proc(t: ^testing.T, text: string, runs: []terminal.Code_Run, loc := #caller_location) {
	end := 0
	for run, index in runs {
		start := int(run.start)
		testing.expectf(t, run.length > 0 && start >= end && start + int(run.length) <= len(text) && run.kind != .None, "run %d (%d, %d, %v) of a text of %d bytes, after %d", index, start, run.length, run.kind, len(text), end, loc = loc)
		for place in end ..< min(start, len(text)) {
			testing.expectf(t, text[place] == ' ', "the byte %d (%d) is in no run and is not a space", place, text[place], loc = loc)
		}
		end = start + int(run.length)
	}
	if len(runs) < terminal.CODE_RUN_LIMIT {
		for place in end ..< len(text) {
			testing.expectf(t, text[place] == ' ', "the byte %d (%d) after the last run is not a space", place, text[place], loc = loc)
		}
	}
}

// The scanner that the parser reads: where a name, a number and a text end.
@(test)
scanner_of_the_parser :: proc(t: ^testing.T) {
	testing.expect_value(t, name_end("9abc", 0), 0) // A name does not start with a digit.
	testing.expect_value(t, name_end("monitor.count9 + 1", 0), 14)
	testing.expect_value(t, name_end("_a", 0), 2)
	testing.expect_value(t, name_end("", 0), 0)
	testing.expect_value(t, number_end("123abc", 0), 3)
	end, finished := text_end("\"ab\"c", 0)
	testing.expect(t, end == 4 && finished)
	end, finished = text_end("\"ab", 0)
	testing.expect(t, end == 3 && !finished)
	testing.expect_value(t, space_end("   x", 0), 3)
	testing.expect_value(t, space_end("x", 9), 1) // A place past the end is the end.
	token := token_next("  -> x", 0)
	testing.expect(t, token.kind == .Arrow && token.start == 2 && token.end == 4)
	token = token_next("  ", 0)
	testing.expect(t, token.kind == .None && token.start == 2)
	token = token_next("#", 0)
	testing.expect(t, token.kind == .Unknown && token.end == 1)
}

// Each kind of a line, in a finished line.
@(test)
line_runs_of_each_kind :: proc(t: ^testing.T) {
	text := "x = monitor.count(\"processors\") + 12 * length(\"ab\") % Rectangle(1, 2) # r.y"
	runs: [terminal.CODE_RUN_LIMIT]terminal.Code_Run
	count := line_runs(text, 0, NO_CARET, test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{
		{"x", .Variable}, {"=", .Operator},
		{"monitor", .Module}, {".", .Operator}, {"count", .Function}, {"(", .Operator}, {"\"processors\"", .Text}, {")", .Operator},
		{"+", .Operator}, {"12", .Number}, {"*", .Operator},
		{"length", .Function}, {"(", .Operator}, {"\"ab\"", .Text}, {")", .Operator},
		{"%", .Operator}, {"Rectangle", .Type}, {"(", .Operator}, {"1", .Number}, {",", .Operator}, {"2", .Number}, {")", .Operator},
		{"#", .Unknown}, {"r.y", .Variable},
	})
	expect_cover(t, text, runs[:count])
}

// A name that the console does not know is marked only after the person
// typed a byte after it; a name that it knows has its kind at once.
@(test)
line_runs_of_a_name_being_typed :: proc(t: ^testing.T) {
	runs: [terminal.CODE_RUN_LIMIT]terminal.Code_Run
	Case :: struct {
		text:     string,
		caret:    int,
		expected: []Expected_Run,
	}
	cases := [?]Case {
		{"> foo", 5, {}}, // Still typed: no mark.
		{"> foo ", 6, {{"foo", .Unknown}}}, // A space after it.
		{"> foo(", 6, {{"foo", .Unknown}, {"(", .Operator}}},
		{"> foo bar", 5, {}}, // foo ends at the caret; bar ends at the end of the line.
		{"> length", 8, {{"length", .Function}}}, // Known while typed.
		{"> monitor.", 10, {{"monitor", .Module}, {".", .Operator}}},
		{"> monitor.cou", 13, {{"monitor", .Module}, {".", .Operator}}},
		{"> monitor.cou ", 14, {{"monitor", .Module}, {".", .Operator}, {"cou", .Unknown}}},
		{"> monitor.count", 15, {{"monitor", .Module}, {".", .Operator}, {"count", .Function}}},
		{"> y = 1", 7, {{"y", .Variable}, {"=", .Operator}, {"1", .Number}}}, // A new variable.
	}
	for item in cases {
		count := line_runs(item.text, 2, item.caret, test_names, runs[:])
		expect_runs(t, item.text, runs[:count], item.expected)
	}
	// In a line that is finished, an unknown name is marked at its end too.
	count := line_runs("foo", 0, NO_CARET, test_names, runs[:])
	expect_runs(t, "foo", runs[:count], []Expected_Run{{"foo", .Unknown}})
}

// A text with no end quote is a text that the person still types: its own
// kind, which the terminal draws as a text.
@(test)
line_runs_of_an_unfinished_text :: proc(t: ^testing.T) {
	runs: [terminal.CODE_RUN_LIMIT]terminal.Code_Run
	text := "> length(\"abc"
	count := line_runs(text, 2, len(text), test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{{"length", .Function}, {"(", .Operator}, {"\"abc", .Text_Unfinished}})
	text = "> length(\"abc\")"
	count = line_runs(text, 2, len(text), test_names, runs[:])
	expect_runs(t, text, runs[:count], []Expected_Run{{"length", .Function}, {"(", .Operator}, {"\"abc\"", .Text}, {")", .Operator}})
	testing.expect_value(t, terminal.code_kind_classes[.Text_Unfinished], terminal.code_kind_classes[.Text])
}

// The rows of the completion list: words, the module, the parameters, the
// types with what their parentheses hold, the arrow.
@(test)
signature_runs_of_the_rows :: proc(t: ^testing.T) {
	runs: [terminal.CODE_RUN_LIMIT]terminal.Code_Run
	Case :: struct {
		text:     string,
		expected: []Expected_Run,
	}
	cases := [?]Case {
		{"export of monitor (name: Text) -> Integer", {{"export", .Words}, {"of", .Words}, {"monitor", .Module}, {"(", .Operator}, {"name", .Parameter}, {":", .Operator}, {"Text", .Type}, {")", .Operator}, {"->", .Arrow}, {"Integer", .Type}}},
		{"export of monitor () -> Table(Count)", {{"export", .Words}, {"of", .Words}, {"monitor", .Module}, {"(", .Operator}, {")", .Operator}, {"->", .Arrow}, {"Table", .Type}, {"(", .Operator}, {"Count", .Type}, {")", .Operator}}},
		{
			"export of monitor (names: Table(Count_Name, Read)) -> Table(Count)",
			{{"export", .Words}, {"of", .Words}, {"monitor", .Module}, {"(", .Operator}, {"names", .Parameter}, {":", .Operator}, {"Table", .Type}, {"(", .Operator}, {"Count_Name", .Type}, {",", .Operator}, {"Read", .Type}, {")", .Operator}, {")", .Operator}, {"->", .Arrow}, {"Table", .Type}, {"(", .Operator}, {"Count", .Type}, {")", .Operator}},
		},
		{"command (a: Integer, b: Value) -> Integer", {{"command", .Words}, {"(", .Operator}, {"a", .Parameter}, {":", .Operator}, {"Integer", .Type}, {",", .Operator}, {"b", .Parameter}, {":", .Operator}, {"Value", .Type}, {")", .Operator}, {"->", .Arrow}, {"Integer", .Type}}},
		{"record (Integer)", {{"record", .Words}, {"(", .Operator}, {"Integer", .Type}, {")", .Operator}}}, // A parameter with no name.
		{"variable: Integer", {{"variable", .Words}, {":", .Operator}, {"Integer", .Type}}},
		{"3 lines ago", {{"3", .Words}, {"lines", .Words}, {"ago", .Words}}},
		{"program that runs", {{"program", .Words}, {"that", .Words}, {"runs", .Words}}},
	}
	for item in cases {
		count := signature_runs(item.text, 0, runs[:])
		expect_runs(t, item.text, runs[:count], item.expected)
		expect_cover(t, item.text, runs[:count])
	}
	// From the end of the name: the runs are places in the whole row.
	row := "countexport of monitor (name: Text) -> Integer"
	count := signature_runs(row, 5, runs[:])
	testing.expect(t, count == 10 && runs[0].start == 5 && runs[0].length == 6)
}

// A line of 200 bytes: the runs stop at CODE_RUN_LIMIT, in order, inside
// the line; the text past them has no run.
@(test)
line_runs_of_a_long_line :: proc(t: ^testing.T) {
	bytes: [202]u8
	piece := "length(x)+1-" // 7 runs in 12 bytes: about 116 runs in the line.
	count := copy(bytes[:], "> ")
	for count < len(bytes) {
		count += copy(bytes[count:], piece)
	}
	text := string(bytes[:])
	runs: [terminal.CODE_RUN_LIMIT]terminal.Code_Run
	run_count := line_runs(text, 2, len(text), test_names, runs[:])
	testing.expect_value(t, run_count, terminal.CODE_RUN_LIMIT)
	expect_cover(t, text, runs[:run_count])
	// Each run fits the row of the terminal.
	row := terminal.Code_Runs{runs = runs, count = run_count}
	testing.expect(t, terminal.code_runs_check(&row, len(text)))
}

// Any byte, in any order: the runs stay inside the text and in order, each
// byte that is not a space is in a run, and the scanner does not stop.
@(test)
line_runs_of_hostile_bytes :: proc(t: ^testing.T) {
	bytes: [256]u8
	for &b, index in bytes {
		b = u8(255 - index) // The quote comes late: most bytes are tokens of their own.
	}
	runs: [terminal.CODE_RUN_LIMIT]terminal.Code_Run
	text := string(bytes[:60])
	count := line_runs(text, 0, NO_CARET, test_names, runs[:])
	expect_cover(t, text, runs[:count])
	text = string(bytes[:])
	count = line_runs(text, 0, NO_CARET, test_names, runs[:])
	testing.expect_value(t, count, terminal.CODE_RUN_LIMIT)
	expect_cover(t, text, runs[:count])
	count = signature_runs(text, 0, runs[:])
	expect_cover(t, text, runs[:count])
	// A name of 300 bytes: two runs, none starts past the byte 255.
	long: [300]u8
	for &b in long {
		b = 'a'
	}
	count = line_runs(string(long[:]), 0, NO_CARET, test_names, runs[:])
	testing.expect_value(t, count, 2)
	testing.expect(t, runs[0].start == 0 && runs[0].length == 255 && runs[1].start == 255)
	// A caret past the text and a first byte past the text.
	testing.expect_value(t, line_runs("ab", 9, 40, test_names, runs[:]), 0)
	testing.expect_value(t, line_runs("ab", 0, 40, {}, runs[:0]), 0)
}
