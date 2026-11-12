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

import "support:line_editor"
import "support:system"
import terminal "support:terminal"

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

// The time of the three parts of one key, in nanoseconds.
Key_Time :: struct {
	collect, rank, rows: u64,
}

measure_completion :: proc "contextless" (arguments: []Value) -> Value {
	least, name_count := completion_measure(collect_console_names)
	completion_measure_print("the names of this console", least, name_count)
	worst_names_write()
	least, name_count = completion_measure(collect_worst_names)
	completion_measure_print("512 names of 128 bytes", least, name_count)
	return {}
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
	least = {max(u64), max(u64), max(u64)}
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
			batch.collect += collected - started
			batch.rank += ranked - collected
			batch.rows += written - ranked
		}
		least.collect = min(least.collect, batch.collect / COMPLETION_MEASURE_KEYS)
		least.rank = min(least.rank, batch.rank / COMPLETION_MEASURE_KEYS)
		least.rows = min(least.rows, batch.rows / COMPLETION_MEASURE_KEYS)
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

// completion_measure_print writes one line of the measure, in microseconds
// with one decimal. The line stays under the 192 bytes that print gives to
// one line of the log.
completion_measure_print :: proc "contextless" (what: string, least: Key_Time, name_count: int) {
	print("console: one key with the completion list: the collect ", least.collect / 1000, ".", least.collect / 100 % 10, " us, the rank ", least.rank / 1000, ".", least.rank / 100 % 10, " us, the rows ", least.rows / 1000, ".", least.rows / 100 % 10, " us, over ", u64(name_count), " names (", what, ", the least of ", u64(COMPLETION_MEASURE_BATCHES), " batches of ", u64(COMPLETION_MEASURE_KEYS), ")\n")
}
