#+build !freestanding
package line_editor

import "contract:blake3"
import "core:testing"

// ---- The keys of a line.

type_text :: proc(line: ^Line, text: string) {
	for index in 0 ..< len(text) {
		line_key(line, .Character, text[index])
	}
}

@(test)
each_key_at_the_caret :: proc(t: ^testing.T) {
	line: Line
	type_text(&line, "hello")
	testing.expect_value(t, line_text(&line), "hello")
	testing.expect_value(t, line.caret, 5)
	testing.expect(t, line_key(&line, .Left))
	testing.expect(t, line_key(&line, .Left))
	testing.expect(t, line_key(&line, .Character, 'X'))
	testing.expect_value(t, line_text(&line), "helXlo")
	testing.expect_value(t, line.caret, 4)
	testing.expect(t, line_key(&line, .Home))
	testing.expect_value(t, line.caret, 0)
	testing.expect(t, line_key(&line, .Delete))
	testing.expect_value(t, line_text(&line), "elXlo")
	testing.expect_value(t, line.caret, 0)
	testing.expect(t, line_key(&line, .Right))
	testing.expect(t, line_key(&line, .Backspace))
	testing.expect_value(t, line_text(&line), "lXlo")
	testing.expect_value(t, line.caret, 0)
	testing.expect(t, line_key(&line, .End))
	testing.expect_value(t, line.caret, 4)
	testing.expect(t, line_key(&line, .Backspace))
	testing.expect_value(t, line_text(&line), "lXl")
	testing.expect(t, !line_key(&line, .Right), "Right at the end changes nothing")
	testing.expect(t, !line_key(&line, .Delete), "Delete at the end changes nothing")
	testing.expect(t, !line_key(&line, .End))
	testing.expect(t, !line_key(&line, .Character, 10), "a byte under 32 is not printable")
	testing.expect(t, !line_key(&line, .Character, 200), "a byte over 126 is not printable")
	testing.expect_value(t, line_text(&line), "lXl")
}

@(test)
an_empty_line :: proc(t: ^testing.T) {
	line: Line
	for key in Edit_Key {
		if key != .Character {
			testing.expectf(t, !line_key(&line, key), "%v on an empty line changes nothing", key)
		}
	}
	testing.expect_value(t, line.count, 0)
	testing.expect_value(t, line.caret, 0)
}

@(test)
a_full_line :: proc(t: ^testing.T) {
	line: Line
	for _ in 0 ..< LINE_CAPACITY + 10 {
		line_key(&line, .Character, 'a')
	}
	testing.expect_value(t, line.count, LINE_CAPACITY)
	testing.expect(t, !line_key(&line, .Character, 'b'), "a full line takes no character")
	testing.expect(t, line_key(&line, .Home))
	testing.expect(t, !line_key(&line, .Character, 'b'), "not at the start either")
	testing.expect(t, line_key(&line, .Delete))
	testing.expect(t, line_key(&line, .Character, 'b'))
	testing.expect_value(t, line.bytes[0], 'b')
	testing.expect_value(t, line.count, LINE_CAPACITY)
}

@(test)
counts_written_by_the_caller_are_repaired :: proc(t: ^testing.T) {
	line: Line
	line.count = 5000
	line.caret = -3
	testing.expect(t, line_key(&line, .Character, 'z') == false, "the repaired line is full")
	testing.expect_value(t, line.count, LINE_CAPACITY)
	testing.expect_value(t, line.caret, 0)
	line.count = 3
	line.caret = 99
	testing.expect(t, line_key(&line, .Backspace))
	testing.expect_value(t, line.count, 2)
	testing.expect_value(t, line.caret, 2)
}

@(test)
replace_a_part_of_a_line :: proc(t: ^testing.T) {
	line: Line
	line_set(&line, "x = monitor.co + 1")
	testing.expect(t, line_replace(&line, 12, 14, "count("))
	testing.expect_value(t, line_text(&line), "x = monitor.count( + 1")
	testing.expect_value(t, line.caret, 18)
	testing.expect(t, !line_replace(&line, 0, 0, "a\x01b"), "a byte that is not printable is refused")
	long: [LINE_CAPACITY]u8
	for &b in long {
		b = 'q'
	}
	testing.expect(t, !line_replace(&line, 0, 1, string(long[:])), "a result longer than the line is refused")
	testing.expect_value(t, line_text(&line), "x = monitor.count( + 1")
	line_set(&line, "a\x02b")
	testing.expect_value(t, line_text(&line), "a?b")
}

// ---- The place of the caret.

@(test)
completion_places :: proc(t: ^testing.T) {
	found := completion_context("mon", 3)
	testing.expect_value(t, found.place, Completion_Place.Name)
	testing.expect_value(t, found.query, "mon")
	testing.expect_value(t, found.replace_start, 0)
	testing.expect_value(t, found.replace_end, 3)

	found = completion_context("monitor.cou", 11)
	testing.expect_value(t, found.place, Completion_Place.Member)
	testing.expect_value(t, found.owner, "monitor")
	testing.expect_value(t, found.query, "cou")
	testing.expect_value(t, found.word_start, 0)
	testing.expect_value(t, found.replace_start, 8)
	testing.expect_value(t, found.replace_end, 11)

	// A name with two dots: the owner is all before the last dot.
	found = completion_context("a.b.c", 5)
	testing.expect_value(t, found.place, Completion_Place.Member)
	testing.expect_value(t, found.owner, "a.b")
	testing.expect_value(t, found.query, "c")

	// The caret in the middle of a name: the query is the part before
	// it; a chosen name replaces the whole name, up to the '('.
	found = completion_context("x = monitor.count(", 14)
	testing.expect_value(t, found.place, Completion_Place.Member)
	testing.expect_value(t, found.query, "co")
	testing.expect_value(t, found.replace_start, 12)
	testing.expect_value(t, found.replace_end, 17)
	testing.expect(t, found.call_follows)

	found = completion_context("load(\"ag", 8)
	testing.expect_value(t, found.place, Completion_Place.Quoted)
	testing.expect_value(t, found.owner, "load")
	testing.expect_value(t, found.query, "ag")
	testing.expect_value(t, found.replace_start, 6)
	testing.expect(t, !found.quote_follows)

	found = completion_context("connect( \"mo\")", 12)
	testing.expect_value(t, found.place, Completion_Place.Quoted)
	testing.expect_value(t, found.owner, "connect")
	testing.expect_value(t, found.replace_end, 12)
	testing.expect(t, found.quote_follows)

	testing.expect_value(t, completion_context("revoke(\"monitor\", \"ma", 21).place, Completion_Place.None) // Only the first argument.
	testing.expect_value(t, completion_context("x = \"hello wo", 13).place, Completion_Place.None)
	testing.expect_value(t, completion_context("12ab", 4).place, Completion_Place.None)
	testing.expect_value(t, completion_context("a + ", 4).place, Completion_Place.None)
	testing.expect_value(t, completion_context("", 0).place, Completion_Place.None)
	testing.expect_value(t, completion_context("", 0, allow_empty = true).place, Completion_Place.Name)
	testing.expect_value(t, completion_context(".a", 2).place, Completion_Place.None)
	testing.expect_value(t, completion_context("abc", 99).query, "abc") // A caret past the end is the end.
}

@(test)
the_call_at_the_caret :: proc(t: ^testing.T) {
	expect_call :: proc(t: ^testing.T, text: string, name: string, argument: int) {
		found_name, found_argument, found := call_at_caret(text, len(text))
		testing.expectf(t, found && found_name == name && found_argument == argument, "%q: %q argument %d (found %v), not %q argument %d", text, found_name, found_argument, found, name, argument)
	}
	expect_call(t, "paint.line(40, 30", "paint.line", 1)
	expect_call(t, "write(\"a, b\", ", "write", 1) // The comma in the text does not count.
	expect_call(t, "f(g(1, 2), ", "f", 1)
	expect_call(t, "f(g(1, ", "g", 1)
	expect_call(t, "x = storage.write (", "storage.write", 0)
	_, _, found := call_at_caret("help()", 6)
	testing.expect(t, !found, "a closed call")
	_, _, found = call_at_caret("x = 1 + (2", 10)
	testing.expect(t, !found, "a '(' with no name")
	deep: [40]u8
	deep[0] = 'f'
	for index in 1 ..< len(deep) {
		deep[index] = '('
	}
	_, _, found = call_at_caret(string(deep[:]), len(deep))
	testing.expect(t, !found, "calls deeper than the limit")
}

// ---- The fuzzy match and its order.

// Real names of this system: the exports of monitor, storage, manual,
// compositor, settings and date, as the console names them.
system_names := [?]string {
	"monitor.programs", "monitor.counts", "monitor.count", "monitor.counts_named", "monitor.served",
	"storage.write", "storage.read", "storage.size", "storage.remove", "storage.objects", "storage.stores",
	"storage.versions", "storage.version", "storage.restore", "storage.clone", "storage.compare",
	"manual.modules", "manual.exports", "manual.imports", "manual.importers", "manual.exporters",
	"manual.described", "manual.handles", "manual.slots", "manual.segments", "manual.running",
	"manual.replacements", "manual.problem", "manual.overview", "manual.show", "manual.about", "manual.signature",
	"compositor.pointer", "compositor.windows", "settings.set", "settings.get", "date.now",
}

expect_order :: proc(t: ^testing.T, query: string, expected: []string) {
	candidates: [64]Candidate
	for name, index in system_names {
		candidates[index] = {name = name, kind = .Export}
	}
	ranked: [RANKED_CAPACITY]Ranked
	kept, matched := rank_candidates(query, candidates[:len(system_names)], ranked[:])
	testing.expectf(t, kept == len(expected) && matched == len(expected), "%q: %d names kept, %d matched, not %d", query, kept, matched, len(expected))
	for item, index in ranked[:min(kept, len(expected))] {
		name := candidates[item.candidate].name
		testing.expectf(t, name == expected[index], "%q: place %d is %q (score %d), not %q", query, index, name, item.score, expected[index])
	}
}

// The orders that the scoring rules give. A change of a rule changes one
// of them: the test shows it.
@(test)
order_of_real_names :: proc(t: ^testing.T) {
	// 123: m at the start, c after a dot, n t side by side; 94: c in the middle.
	expect_order(t, "mcnt", {"monitor.count", "monitor.counts", "monitor.counts_named", "manual.replacements"})
	expect_order(t, "stwr", {"storage.write"})
	// 84 for the three counts: c after a dot; 81: c at the start, n far.
	expect_order(t, "cnt", {"monitor.count", "monitor.counts", "monitor.counts_named", "compositor.pointer", "manual.replacements"})
	// 112 for the two names that start with "set" (get before set: the
	// bytes); then the spread matches: 69, 67, 67 (shorter first), 65, 64.
	expect_order(t, "set", {"settings.get", "settings.set", "storage.stores", "storage.write", "storage.restore", "storage.objects", "manual.segments"})
	// 104: "mod" side by side after a dot; 65, 59: spread from the start; 34: no start.
	expect_order(t, "mod", {"manual.modules", "monitor.served", "monitor.counts_named", "compositor.windows"})
	// A query that is a whole name and the start of two others: the whole
	// name first, by its length.
	expect_order(t, "monitor.count", {"monitor.count", "monitor.counts", "monitor.counts_named"})
	// Upper case is lower case.
	expect_order(t, "MCNT", {"monitor.count", "monitor.counts", "monitor.counts_named", "manual.replacements"})
}

@(test)
places_of_a_match :: proc(t: ^testing.T) {
	score, places, matched := fuzzy_match("mcnt", "monitor.count")
	testing.expect(t, matched)
	testing.expect_value(t, score, 123)
	testing.expect_value(t, places, Match_Places{0, 8, 11, 12})
	score, places, matched = fuzzy_match("stwr", "storage.write")
	testing.expect_value(t, score, 144)
	testing.expect_value(t, places, Match_Places{0, 1, 8, 9})
	score, places, matched = fuzzy_match("", "anything")
	testing.expect(t, matched && score == 0 && card(places) == 0, "an empty query matches with no place")
	_, _, matched = fuzzy_match("mx", "monitor.count")
	testing.expect(t, !matched)
}

@(test)
hostile_names :: proc(t: ^testing.T) {
	_, _, matched := fuzzy_match("a", "")
	testing.expect(t, !matched, "a name of 0 bytes matches no character")
	_, _, matched = fuzzy_match("", "")
	testing.expect(t, matched, "a name of 0 bytes matches the empty query")

	long: [1000]u8
	for &b in long {
		b = 'a'
	}
	long[999] = 'z'
	_, _, matched = fuzzy_match("z", string(long[:]))
	testing.expect(t, !matched, "the match reads only the first bytes of a long name")
	_, places, long_matched := fuzzy_match("a", string(long[:]))
	testing.expect(t, long_matched && places == Match_Places{0}, "a long name matches in its start")

	_, places, matched = fuzzy_match("mon", "\x01\x02mon\xff")
	testing.expect(t, matched && places == Match_Places{2, 3, 4}, "bytes under 32 and over 126 are bytes as the others")

	query: [QUERY_LIMIT + 1]u8
	for &b in query {
		b = 'a'
	}
	_, _, matched = fuzzy_match(string(query[:]), string(long[:]))
	testing.expect(t, !matched, "a query longer than the limit matches nothing")
}

@(test)
ten_thousand_candidates :: proc(t: ^testing.T) {
	candidates := make([]Candidate, 10_000)
	defer delete(candidates)
	for &candidate in candidates {
		candidate = {name = "abc"}
	}
	candidates[9_999] = {name = "a"} // The best one, after the limit: it is not read.
	ranked: [RANKED_CAPACITY]Ranked
	kept, matched := rank_candidates("a", candidates, ranked[:])
	testing.expect_value(t, matched, CANDIDATE_SCAN_LIMIT)
	testing.expect_value(t, kept, RANKED_CAPACITY)
	for item in ranked[:kept] {
		testing.expect(t, item.candidate < CANDIDATE_SCAN_LIMIT)
	}
	// A small table keeps the best ones.
	small_candidates := [?]Candidate{{name = "xa"}, {name = "abc"}, {name = "ab"}, {name = "b"}}
	small: [2]Ranked
	kept, matched = rank_candidates("a", small_candidates[:], small[:])
	testing.expect_value(t, kept, 2)
	testing.expect_value(t, matched, 3)
	testing.expect_value(t, small_candidates[small[0].candidate].name, "ab")
	testing.expect_value(t, small_candidates[small[1].candidate].name, "abc")
}

// Long names of one length that differ only in their last byte: their
// order reads NAME_COMPARE_LIMIT bytes, not the whole names, so they are
// equal and stay in the order of the table. A compare of the whole names
// would put them in the order of their last byte, the reverse here. The
// test checks the order only; the bound of the work follows from it.
@(test)
long_names_of_one_length :: proc(t: ^testing.T) {
	NAME_SIZE :: 1000
	COUNT :: CANDIDATE_SCAN_LIMIT
	bytes := make([]u8, NAME_SIZE * COUNT)
	defer delete(bytes)
	candidates := make([]Candidate, COUNT)
	defer delete(candidates)
	for number in 0 ..< COUNT {
		name := bytes[number * NAME_SIZE:][:NAME_SIZE]
		for &b in name {
			b = 'a'
		}
		name[NAME_SIZE - 1] = u8(255 - number % 200) // Down: the reverse of the table.
		candidates[number] = {name = string(name)}
	}
	ranked: [RANKED_CAPACITY]Ranked
	kept, matched := rank_candidates("a", candidates, ranked[:])
	testing.expect_value(t, matched, COUNT)
	testing.expect_value(t, kept, RANKED_CAPACITY)
	for item, index in ranked[:kept] {
		testing.expectf(t, item.candidate == index, "place %d holds the candidate %d", index, item.candidate)
	}
	testing.expect(t, names_equal(candidates[0].name, candidates[1].name), "equal in the bytes that the order reads")
	testing.expect(t, !names_equal("ab", "abc") && !names_equal("ab", "ac") && names_equal("", ""))
}

@(test)
empty_query_order :: proc(t: ^testing.T) {
	names := [?]Candidate{{name = "stop"}, {name = "help"}, {name = "hash"}, {name = "load"}, {name = "modules"}, {name = "time"}}
	ranked: [8]Ranked
	kept, _ := rank_candidates("", names[:], ranked[:])
	expected := [?]string{"hash", "help", "load", "stop", "time", "modules"}
	testing.expect_value(t, kept, len(expected))
	for item, index in ranked[:kept] {
		testing.expect_value(t, names[item.candidate].name, expected[index])
	}
}

// ---- The history and its search.

@(test)
history_ring :: proc(t: ^testing.T) {
	history := new(History)
	defer free(history)
	testing.expect(t, !history_add(history, ""), "an empty line is not kept")
	testing.expect(t, history_add(history, "help()"))
	testing.expect(t, !history_add(history, "help()"), "the same line two times in a row is kept one time")
	testing.expect(t, history_add(history, "time()"))
	testing.expect_value(t, history_count(history), 2)
	newest, _ := history_line(history, 0)
	testing.expect_value(t, newest, "time()")

	// More lines than the capacity: the oldest go.
	history^ = {}
	buffer: [16]u8
	for number in 0 ..< 300 {
		text := fmt_line(buffer[:], number)
		history_add(history, text)
	}
	testing.expect_value(t, history_count(history), HISTORY_LINE_CAPACITY)
	newest, _ = history_line(history, 0)
	testing.expect_value(t, newest, "line 299")
	oldest, _ := history_line(history, HISTORY_LINE_CAPACITY - 1)
	testing.expect_value(t, oldest, "line 44")

	// Long lines: the ring holds fewer of them, each one whole.
	history^ = {}
	long: [LINE_CAPACITY]u8
	for number in 0 ..< 100 {
		for &b in long {
			b = u8('a' + number % 26)
		}
		history_add(history, string(long[:]))
	}
	testing.expect_value(t, history_count(history), 81)
	for age in 0 ..< 81 {
		text, ok := history_line(history, age)
		testing.expect(t, ok && len(text) == LINE_CAPACITY && text[0] == u8('a' + (99 - age) % 26) && text[LINE_CAPACITY - 1] == text[0])
	}
}

fmt_line :: proc(buffer: []u8, number: int) -> string {
	prefix := "line "
	count := copy(buffer, prefix)
	digits: [8]u8
	digit_count := 0
	rest := number
	for {
		digits[digit_count] = u8('0' + rest % 10)
		digit_count += 1
		rest /= 10
		if rest == 0 {
			break
		}
	}
	for index := digit_count - 1; index >= 0; index -= 1 {
		buffer[count] = digits[index]
		count += 1
	}
	return string(buffer[:count])
}

@(test)
hostile_history_fields :: proc(t: ^testing.T) {
	history := new(History)
	defer free(history)
	history_add(history, "help()")
	history.lengths[0] = 60_000
	_, ok := history_line(history, 0)
	testing.expect(t, !ok, "a length longer than a line is refused")
	history.lengths[0] = 6
	history.starts[0] = history.bytes_written + 5
	_, ok = history_line(history, 0)
	testing.expect(t, !ok, "a start after the bytes written is refused")
	history.starts[0] = HISTORY_BYTE_CAPACITY - 2
	history.bytes_written = HISTORY_BYTE_CAPACITY
	_, ok = history_line(history, 0)
	testing.expect(t, !ok, "a line that passes the end of the ring is refused")
	testing.expect_value(t, history_count(history), 0)
}

// The search of the history: the score first, then the newest line, and
// a line that the history holds two times shows one time.
@(test)
history_search_order :: proc(t: ^testing.T) {
	history := new(History)
	defer free(history)
	for text in ([]string{"connect(\"monitor\")", "monitor.count(\"programs\")", "help()", "tally.add(5, \"x\")", "monitor.count(\"processors\")", "help()"}) {
		history_add(history, text)
	}
	candidates: [HISTORY_LINE_CAPACITY]Candidate
	count := history_candidates(history, candidates[:])
	testing.expect_value(t, count, 6)
	ranked: [RANKED_CAPACITY]Ranked
	expect :: proc(t: ^testing.T, query: string, candidates: []Candidate, ranked: []Ranked, expected: []string) {
		kept, _ := rank_candidates(query, candidates, ranked, skip_equal_names = true)
		testing.expectf(t, kept == len(expected), "%q: %d lines, not %d", query, kept, len(expected))
		for item, index in ranked[:min(kept, len(expected))] {
			testing.expectf(t, candidates[item.candidate].name == expected[index], "%q: place %d is %q, not %q", query, index, candidates[item.candidate].name, expected[index])
		}
	}
	// Equal scores (111): the newest line first, though it is longer.
	expect(t, "mco", candidates[:count], ranked[:], {"monitor.count(\"processors\")", "monitor.count(\"programs\")"})
	// No query: each line, the newest first; help() one time.
	expect(t, "", candidates[:count], ranked[:], {"help()", "monitor.count(\"processors\")", "tally.add(5, \"x\")", "monitor.count(\"programs\")", "connect(\"monitor\")"})
	// "prog": the line with "programs" matches side by side; "processors"
	// does not hold a g.
	expect(t, "prog", candidates[:count], ranked[:], {"monitor.count(\"programs\")"})
}

// ---- The line history as a file.

@(test)
history_file_round_trip :: proc(t: ^testing.T) {
	history := new(History)
	defer free(history)
	read_back := new(History)
	defer free(read_back)
	for text in ([]string{"connect(\"monitor\")", "monitor.count(\"processors\")", "help()"}) {
		history_add(history, text)
	}
	buffer: [HISTORY_FILE_SIZE_LIMIT]u8
	bytes := history_file_write(history, buffer[:])
	testing.expect_value(t, len(bytes), HISTORY_FILE_HEADER_SIZE + 3 + 18 + 27 + 6 + HISTORY_FILE_HASH_SIZE)
	testing.expect_value(t, history_file_read(bytes, read_back), History_File_Problem.None)
	testing.expect_value(t, history_count(read_back), 3)
	for age in 0 ..< 3 {
		written, _ := history_line(history, age)
		read, _ := history_line(read_back, age)
		testing.expect_value(t, read, written)
	}
	// An empty history is a file of a header and a hash.
	empty := new(History)
	defer free(empty)
	bytes = history_file_write(empty, buffer[:])
	testing.expect_value(t, len(bytes), HISTORY_FILE_HEADER_SIZE + HISTORY_FILE_HASH_SIZE)
	testing.expect_value(t, history_file_read(bytes, read_back), History_File_Problem.None)
	testing.expect_value(t, history_count(read_back), 0)
	// A buffer too small for a header and a hash gives no file.
	testing.expect(t, history_file_write(history, buffer[:40]) == nil)
}

// A file of one block keeps the newest lines that fit, the oldest of them
// first.
@(test)
history_file_keeps_the_newest_lines :: proc(t: ^testing.T) {
	history := new(History)
	defer free(history)
	read_back := new(History)
	defer free(read_back)
	long: [LINE_CAPACITY]u8
	for number in 0 ..< 40 {
		for &b in long {
			b = u8('a' + number % 26)
		}
		history_add(history, string(long[:]))
	}
	buffer: [HISTORY_FILE_SIZE_LIMIT]u8
	bytes := history_file_write(history, buffer[:])
	// (4096 - 16 - 32) / 201 = 20 lines.
	testing.expect_value(t, history_file_read(bytes, read_back), History_File_Problem.None)
	testing.expect_value(t, history_count(read_back), 20)
	for age in 0 ..< 20 {
		text, _ := history_line(read_back, age)
		testing.expect(t, len(text) == LINE_CAPACITY && text[0] == u8('a' + (39 - age) % 26))
	}
}

// Each hostile file gives an empty history and the name of its problem.
@(test)
history_file_hostile :: proc(t: ^testing.T) {
	history := new(History)
	defer free(history)
	read_back := new(History)
	defer free(read_back)
	history_add(history, "help()")
	history_add(history, "time()")
	buffer: [HISTORY_FILE_SIZE_LIMIT]u8
	good := history_file_write(history, buffer[:])
	copy_of_good: [HISTORY_FILE_SIZE_LIMIT]u8

	// change applies one change to a copy of the good file, and makes its
	// hash again when asked: the checks after the hash see the change.
	expect_problem :: proc(t: ^testing.T, good: []u8, copy_buffer: []u8, read_back: ^History, problem: History_File_Problem, change: proc(bytes: []u8), rehash: bool, name: string) {
		bytes := copy_buffer[:len(good)]
		copy(bytes, good)
		change(bytes)
		if rehash {
			end := len(bytes) - HISTORY_FILE_HASH_SIZE
			hash := blake3.hash(bytes[:end])
			copy(bytes[end:], hash[:])
		}
		history_add(read_back, "left from before")
		found := history_file_read(bytes, read_back)
		testing.expectf(t, found == problem, "%s: %v, not %v", name, found, problem)
		testing.expectf(t, history_count(read_back) == 0, "%s: the history is empty", name)
	}
	expect_problem(t, good, copy_of_good[:], read_back, .Wrong_Magic, proc(bytes: []u8) {bytes[0] = 'X'}, false, "magic")
	expect_problem(t, good, copy_of_good[:], read_back, .Wrong_Version, proc(bytes: []u8) {bytes[4] = 2}, false, "version")
	expect_problem(t, good, copy_of_good[:], read_back, .Wrong_Hash, proc(bytes: []u8) {bytes[17] ~= 1}, false, "a changed byte")
	expect_problem(t, good, copy_of_good[:], read_back, .Too_Many_Lines, proc(bytes: []u8) {bytes[9] = 0xFF}, true, "the count of lines")
	expect_problem(t, good, copy_of_good[:], read_back, .Wrong_Size, proc(bytes: []u8) {bytes[12] += 1}, true, "the count of bytes")
	expect_problem(t, good, copy_of_good[:], read_back, .Wrong_Line, proc(bytes: []u8) {bytes[16] = 0}, true, "a line of 0 bytes")
	expect_problem(t, good, copy_of_good[:], read_back, .Wrong_Line, proc(bytes: []u8) {bytes[16] = 250}, true, "a line longer than the lines")
	expect_problem(t, good, copy_of_good[:], read_back, .Not_Printable, proc(bytes: []u8) {bytes[17] = 7}, true, "a control byte")
	expect_problem(t, good, copy_of_good[:], read_back, .Wrong_Count, proc(bytes: []u8) {bytes[8] = 1}, true, "fewer lines than the bytes")
	expect_problem(t, good, copy_of_good[:], read_back, .Wrong_Count, proc(bytes: []u8) {bytes[8] = 3}, true, "more lines than the bytes")
	short := [10]u8{}
	testing.expect_value(t, history_file_read(short[:], read_back), History_File_Problem.Too_Short)
	testing.expect_value(t, history_file_read(nil, read_back), History_File_Problem.Too_Short)
}

// ---- The keys that come while a line runs.

// Escape stops a call only when the line waits in one that it can stop;
// if not, it waits in order as each key, so the keys of the next line mean
// what they mean when typed slowly.
@(test)
keys_while_a_line_runs :: proc(t: ^testing.T) {
	testing.expect_value(t, running_key_action(false, false, 0, 4), Running_Key_Action.Wait)
	testing.expect_value(t, running_key_action(false, true, 0, 4), Running_Key_Action.Wait)
	testing.expect_value(t, running_key_action(true, true, 0, 4), Running_Key_Action.Stop_Call)
	// The line runs no call that Escape stops: Escape is a key of the next line.
	testing.expect_value(t, running_key_action(true, false, 0, 4), Running_Key_Action.Wait)
	testing.expect_value(t, running_key_action(true, false, 3, 4), Running_Key_Action.Wait)
	// Escape stops the call also when keys wait, and when no key has room.
	testing.expect_value(t, running_key_action(true, true, 4, 4), Running_Key_Action.Stop_Call)
	testing.expect_value(t, running_key_action(true, false, 4, 4), Running_Key_Action.Drop)
	testing.expect_value(t, running_key_action(false, false, 4, 4), Running_Key_Action.Drop)
}

// The program takes a key from its queue while a place is free. With no
// place, it reads on only to find an Escape that can stop a call: in each
// other case the key stays in the queue, and no key is lost.
@(test)
keys_stay_in_the_queue_when_no_key_can_wait_or_act :: proc(t: ^testing.T) {
	testing.expect(t, running_key_can_be_taken(false, 0, 4))
	testing.expect(t, running_key_can_be_taken(false, 3, 4))
	testing.expect(t, running_key_can_be_taken(true, 3, 4))
	testing.expect(t, !running_key_can_be_taken(false, 4, 4), "no place and no call to stop: the key stays in the queue")
	testing.expect(t, running_key_can_be_taken(true, 4, 4), "the program reads on to find Escape")
	// A key that is taken with a place never gives Drop.
	for waiting in 0 ..< 4 {
		for escape in ([2]bool{false, true}) {
			for stoppable in ([2]bool{false, true}) {
				if running_key_can_be_taken(stoppable, waiting, 4) {
					testing.expect(t, running_key_action(escape, stoppable, waiting, 4) != .Drop)
				}
			}
		}
	}
	// With no place, a key is taken only when Escape can stop a call: the
	// one key that is then lost is a key that is not Escape.
	testing.expect_value(t, running_key_action(true, true, 4, 4), Running_Key_Action.Stop_Call)
	testing.expect_value(t, running_key_action(false, true, 4, 4), Running_Key_Action.Drop)
}
