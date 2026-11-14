package console

// The measure of one key with the completion list open: the three parts of
// the work of the first thread for a key that changes the name at the
// caret. The collect fills the table of names; the rank matches the query
// against each one and keeps the best; the rows write the text of the rows
// that the terminal receives (at most 8: the name, and what it is).
//
// The command runs in the second thread, with its own tables: the first
// thread keeps its list. Each measure is the least time of
// COMPLETION_MEASURE_BATCHES batches of COMPLETION_MEASURE_KEYS keys: a
// batch that an interrupt or another program cut is longer, and the least
// one is the time of the work.

import "modus:support/line_editor"
import "modus:support/system"
import terminal "modus:support/terminal"

COMPLETION_MEASURE_BATCHES :: 20
COMPLETION_MEASURE_KEYS :: 10
COMPLETION_MEASURE_QUERY :: "mcnt"

// The worst case that the console can have: CANDIDATE_CAPACITY names of
// NAME_SCAN_LIMIT bytes, each one a match whose characters are far apart,
// so that the two passes of the match read the whole name.
WORST_NAME_SIZE :: line_editor.NAME_SCAN_LIMIT
worst_name_bytes: [CANDIDATE_CAPACITY * WORST_NAME_SIZE]u8
measure_names: Candidate_Table
measure_ranked: [line_editor.RANKED_CAPACITY]line_editor.Ranked

// The time of the four parts of one key, in nanoseconds. colors: the runs
// of code of the edit line, a line of LINE_CAPACITY bytes, and of the rows.
Key_Time :: struct {
	collect, rank, rows, colors: u64,
}

// The edit line of the measure of the colors: calls, texts, numbers and
// operators up to LINE_CAPACITY bytes, the longest line that the input can
// type, after the prompt. It has more parts than CODE_RUN_LIMIT: the runs
// are full, the most work of one line.
measure_line_bytes: [len(PROMPT) + LINE_CAPACITY]u8
measure_line: string

measure_line_write :: proc "contextless" () {
	PIECE :: "monitor.count(\"ab\") + 12 * x - "
	count := copy(measure_line_bytes[:], PROMPT)
	for count < len(measure_line_bytes) {
		count += copy(measure_line_bytes[count:], PIECE)
	}
	measure_line = string(measure_line_bytes[:count])
}

measure_completion :: proc "contextless" (arguments: []Value) -> Value {
	columns := [6]Column{text_column("names_of", 32), integer_column("names"), integer_column("collect_nanoseconds"), integer_column("rank_nanoseconds"), integer_column("rows_nanoseconds"), integer_column("colors_nanoseconds")}
	table, made := made_table("Completion_Measure", columns[:])
	if !made {
		return fail("measure_completion: the line has no room for the description")
	}
	measure_line_write()
	least, name_count := completion_measure(collect_console_names)
	completion_measure_log("the names of this console", least, name_count)
	completion_measure_row(&table, "the names of this console", least, name_count)
	worst_names_write()
	least, name_count = completion_measure(collect_worst_names)
	completion_measure_log("512 names of 128 bytes", least, name_count)
	completion_measure_row(&table, "512 names of 128 bytes", least, name_count)
	return made_value(&table, "measure_completion")
}

// collect_console_names fills the table as a key at the start of a name
// does: the commands, the services, the variables.
collect_console_names :: proc "contextless" (table: ^Candidate_Table) {
	names_collect(table, {place = .Name, query = COMPLETION_MEASURE_QUERY})
}

// worst_names_write writes the names of the worst case: "m", three digits
// that make each name its own, then "x" up to "cnt" at the end, and one
// "x" after it.
worst_names_write :: proc "contextless" () {
	for number in 0 ..< CANDIDATE_CAPACITY {
		name := worst_name_bytes[number * WORST_NAME_SIZE:][:WORST_NAME_SIZE]
		for &b in name {
			b = 'x'
		}
		name[0] = 'm'
		name[1] = u8('0' + number / 100 % 10)
		name[2] = u8('0' + number / 10 % 10)
		name[3] = u8('0' + number % 10)
		name[WORST_NAME_SIZE - 4] = 'c'
		name[WORST_NAME_SIZE - 3] = 'n'
		name[WORST_NAME_SIZE - 2] = 't'
	}
}

collect_worst_names :: proc "contextless" (table: ^Candidate_Table) {
	table.count, table.dropped = 0, 0
	for number in 0 ..< CANDIDATE_CAPACITY {
		candidate_add(table, string(worst_name_bytes[number * WORST_NAME_SIZE:][:WORST_NAME_SIZE]), .Module, number)
	}
}

// completion_measure gives the least time of each part of one key over the
// batches, and the count of names that the collect gave.
completion_measure :: proc "contextless" (collect: proc "contextless" (table: ^Candidate_Table)) -> (least: Key_Time, name_count: int) {
	least = {max(u64), max(u64), max(u64), max(u64)}
	for _ in 0 ..< COMPLETION_MEASURE_BATCHES {
		batch: Key_Time
		for _ in 0 ..< COMPLETION_MEASURE_KEYS {
			started := system.nanoseconds()
			collect(&measure_names)
			collected := system.nanoseconds()
			kept, _ := line_editor.rank_candidates(COMPLETION_MEASURE_QUERY, measure_names.items[:measure_names.count], measure_ranked[:])
			ranked := system.nanoseconds()
			rows_write(kept)
			written := system.nanoseconds()
			colors_write(kept)
			colored := system.nanoseconds()
			batch.collect += collected - started
			batch.rank += ranked - collected
			batch.rows += written - ranked
			batch.colors += colored - written
		}
		least.collect = min(least.collect, batch.collect / COMPLETION_MEASURE_KEYS)
		least.rank = min(least.rank, batch.rank / COMPLETION_MEASURE_KEYS)
		least.rows = min(least.rows, batch.rows / COMPLETION_MEASURE_KEYS)
		least.colors = min(least.colors, batch.colors / COMPLETION_MEASURE_KEYS)
	}
	return least, measure_names.count
}

// rows_write writes the text of the rows that list_send gives the
// terminal: the name and what it is, for the first rows of the ranking.
// The bytes go to a buffer of the measure, not to the terminal.
rows_write :: proc "contextless" (kept: int) {
	row: [terminal.RUN_LIMIT]u8
	for item in measure_ranked[:min(kept, terminal.LIST_ROWS)] {
		candidate := measure_names.items[item.candidate]
		writer := system.Writer {
			buffer = row[:],
		}
		system.write_part(&writer, candidate.name)
		candidate_about(&writer, candidate)
	}
}

// colors_write makes the runs of code of one key: the edit line of the
// measure, and the rows that list_send gives the terminal. The runs go to
// a buffer of the measure, not to the terminal.
colors_write :: proc "contextless" (kept: int) {
	runs: [terminal.CODE_RUN_LIMIT]terminal.Code_Run
	_ = edit_runs(measure_line, len(measure_line), runs[:])
	for item in measure_ranked[:min(kept, terminal.LIST_ROWS)] {
		buffer: [terminal.RUN_LIMIT]u8
		_, _, _ = candidate_row_runs(&buffer, measure_names.items[item.candidate], runs[:])
	}
}

// completion_measure_log writes one line of the measure on the log, in
// microseconds with one decimal: the machine tests read the measure there.
completion_measure_log :: proc "contextless" (what: string, least: Key_Time, name_count: int) {
	system.log("console: one key with the completion list: the collect ", least.collect / 1000, ".", least.collect / 100 % 10, " us, the rank ", least.rank / 1000, ".", least.rank / 100 % 10, " us, the rows ", least.rows / 1000, ".", least.rows / 100 % 10, " us, the colors ", least.colors / 1000, ".", least.colors / 100 % 10, " us, over ", u64(name_count), " names (", what, ", the least of ", u64(COMPLETION_MEASURE_BATCHES), " batches of ", u64(COMPLETION_MEASURE_KEYS), ")")
}

// completion_measure_row adds the measure as one row of the result, in
// nanoseconds.
completion_measure_row :: proc "contextless" (table: ^Made_Table, what: string, least: Key_Time, name_count: int) {
	row := made_row(table)
	made_text(table, row, 0, what)
	made_integer(table, row, 1, i64(name_count))
	made_integer(table, row, 2, i64(least.collect))
	made_integer(table, row, 3, i64(least.rank))
	made_integer(table, row, 4, i64(least.rows))
	made_integer(table, row, 5, i64(least.colors))
}
