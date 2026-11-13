#+build !freestanding
package value_kinds

import "core:testing"

// A record of 152 bytes, as a log record holds (operation.LOG_TEXT_CAPACITY):
// this package does not import the operation contract, so the tests name
// the number.
TEST_RECORD_TEXT :: 152
TEST_RECORD_RUNS :: 8

// A text with no value: no run in its record.
@(test)
a_record_with_no_run :: proc(t: ^testing.T) {
	runs: [4]Value_Run_In_Call
	count := 0
	value_run_add(runs[:], &count, 0, 12, .None)
	value_run_add(runs[:], &count, 5, 5, .Number)
	testing.expect_value(t, count, 0)
	into: [TEST_RECORD_RUNS]Value_Run
	testing.expect_value(t, value_runs_of_record(runs[:count], 0, TEST_RECORD_TEXT, into[:]), 0)
}

// "kernel: free memory 2013 MiB": one run of the kind Size over "2013 MiB".
@(test)
a_record_with_one_run :: proc(t: ^testing.T) {
	text := "kernel: free memory 2013 MiB"
	runs: [4]Value_Run_In_Call
	count := 0
	value_run_add(runs[:], &count, 20, len(text), .Size)
	testing.expect(t, value_runs_check(runs[:count], len(text)))
	into: [TEST_RECORD_RUNS]Value_Run
	kept := value_runs_of_record(runs[:count], 0, len(text), into[:])
	testing.expect_value(t, kept, 1)
	start, end, ok := value_run_in_text(into[0], len(text))
	testing.expect(t, ok)
	testing.expect_value(t, text[start:end], "2013 MiB")
	testing.expect_value(t, into[0].kind, Value_Kind.Size)
}

// A record keeps at most its capacity of runs: the first ones, in order;
// the text after them is plain.
@(test)
a_record_with_the_most_runs_and_more_parts :: proc(t: ^testing.T) {
	runs: [32]Value_Run_In_Call
	count := 0
	for index in 0 ..< 12 {
		value_run_add(runs[:], &count, index * 10, index * 10 + 3, .Number)
	}
	testing.expect_value(t, count, 12)
	testing.expect(t, value_runs_check(runs[:count], 120))
	into: [TEST_RECORD_RUNS]Value_Run
	kept := value_runs_of_record(runs[:count], 0, 120, into[:])
	testing.expect_value(t, kept, TEST_RECORD_RUNS)
	for index in 0 ..< kept {
		testing.expect_value(t, int(into[index].start), index * 10)
		testing.expect_value(t, int(into[index].length), 3)
	}
	// A writer whose table of runs is full adds none: those parts are plain.
	small: [2]Value_Run_In_Call
	small_count := 0
	for index in 0 ..< 5 {
		value_run_add(small[:], &small_count, index * 4, index * 4 + 2, .Time)
	}
	testing.expect_value(t, small_count, 2)
}

// A run that crosses the bound of two records is one run in each, from the
// start of each record.
@(test)
a_run_across_two_records :: proc(t: ^testing.T) {
	runs := [?]Value_Run_In_Call{{start = 140, length = 20, kind = .Version}, {start = 200, length = 4, kind = .Number}}
	testing.expect(t, value_runs_check(runs[:], 300))
	first: [TEST_RECORD_RUNS]Value_Run
	testing.expect_value(t, value_runs_of_record(runs[:], 0, TEST_RECORD_TEXT, first[:]), 1)
	testing.expect_value(t, first[0], Value_Run{start = 140, length = 12, kind = .Version})
	second: [TEST_RECORD_RUNS]Value_Run
	testing.expect_value(t, value_runs_of_record(runs[:], TEST_RECORD_TEXT, TEST_RECORD_TEXT, second[:]), 2)
	testing.expect_value(t, second[0], Value_Run{start = 0, length = 8, kind = .Version})
	testing.expect_value(t, second[1], Value_Run{start = 48, length = 4, kind = .Number})
}

// The cut mark ends a text: no run colors the mark. The rest of a text that
// a writer sends as a second line keeps its runs, from its own start.
@(test)
runs_cut_and_after :: proc(t: ^testing.T) {
	runs := [?]Value_Run_In_Call{{start = 2, length = 4, kind = .Number}, {start = 10, length = 10, kind = .Size}, {start = 30, length = 2, kind = .Time}}
	cut := runs
	testing.expect_value(t, value_runs_cut(cut[:], 3, 15), 2)
	testing.expect_value(t, cut[1], Value_Run_In_Call{start = 10, length = 5, kind = .Size})
	after := runs
	testing.expect_value(t, value_runs_after(after[:], 3, 15), 2)
	testing.expect_value(t, after[0], Value_Run_In_Call{start = 0, length = 5, kind = .Size})
	testing.expect_value(t, after[1], Value_Run_In_Call{start = 15, length = 2, kind = .Time})
}

// The runs come from another program: each wrong table is refused whole.
@(test)
hostile_runs_are_refused :: proc(t: ^testing.T) {
	past_the_text := [?]Value_Run_In_Call{{start = 8, length = 4, kind = .Number}}
	testing.expect(t, !value_runs_check(past_the_text[:], 10))
	empty := [?]Value_Run_In_Call{{start = 0, length = 0, kind = .Number}}
	testing.expect(t, !value_runs_check(empty[:], 10))
	out_of_order := [?]Value_Run_In_Call{{start = 5, length = 2, kind = .Number}, {start = 1, length = 2, kind = .Number}}
	testing.expect(t, !value_runs_check(out_of_order[:], 10))
	overlap := [?]Value_Run_In_Call{{start = 1, length = 4, kind = .Number}, {start = 3, length = 2, kind = .Number}}
	testing.expect(t, !value_runs_check(overlap[:], 10))
	no_kind := [?]Value_Run_In_Call{{start = 1, length = 2, kind = .None}}
	testing.expect(t, !value_runs_check(no_kind[:], 10))
	past_the_kinds := [?]Value_Run_In_Call{{start = 1, length = 2, kind = Value_Kind(200)}}
	testing.expect(t, !value_runs_check(past_the_kinds[:], 10))
	testing.expect(t, value_runs_check(nil, 0))
	// A reader of a record checks a run before it indexes the text.
	_, _, ok := value_run_in_text({start = 150, length = 10, kind = .Size}, TEST_RECORD_TEXT)
	testing.expect(t, !ok)
	testing.expect_value(t, value_kind_of(200), Value_Kind.None)
}

// Each kind has a name, and no two kinds have one name.
@(test)
each_kind_has_one_name :: proc(t: ^testing.T) {
	for kind in Value_Kind {
		if kind == .None {
			continue
		}
		testing.expectf(t, VALUE_KIND_NAMES[kind] != "", "the kind %v has no name", kind)
		for other in Value_Kind {
			testing.expectf(t, other == kind || VALUE_KIND_NAMES[other] != VALUE_KIND_NAMES[kind], "the kinds %v and %v have one name", kind, other)
		}
	}
}
