package console

import "contract:isolated"
import module "contract:module"
import "contract:ring"
import "contract:value_kinds"
import "support:system"
import terminal "support:terminal"

// The log records of a line.
//
// While a line calls an export, the console shows under the line the log
// records that the called program writes: grouped by channel, with each
// value in the color of its value kind, as the window of the log draws
// them (docs/CONSOLE.md, "The log records of a line").
//
// The console has no grant to read the memory of the log. It reads the
// records as any caller that acts for the principal does: it calls the
// exports `records` and `value_runs` of the service `log`, through a
// connection that the root service gives. With no service `log`, or with a
// refusal, a line shows no record: the console gets no other access.
//
// Which records: those that a program called by the line wrote, from the
// first call of the line on. A module that `load` put in the console
// writes as the console. The lines go to the terminal only: the records are
// in the log already.

LINE_RECORD_SERVICE :: "log" // The service that serves the log records.
LINE_RECORD_BATCH :: 32 // The records that the console draws from one answer of the service.
LINE_RECORD_ANSWERS :: 8 // The most answers that the console reads at one time: a program that writes faster keeps its records in the log.
LINE_RECORD_PROGRAMS :: 4 // The programs that one line follows.
LINE_RECORD_ANSWER_LIMIT :: 1000 // Milliseconds: the service that does not answer in this time is not asked again in the line.
LINE_RECORD_INDENT :: 4 // The column of the text of a record.

Line_Records :: struct {
	file:        []u8, // The file of the log service in the boot image: the descriptions of its exports.
	file_hash:   [32]u8,
	records:     module.Function,
	records_export: u32,
	value_runs:  module.Function,
	value_runs_export: u32,
	next:        u64, // The number of the first log record that the console did not read.
	marked:      bool, // The line called a program: next is the first record of the line.
	unavailable: bool, // The service gave no answer for this line.
	refused:     bool, // The root service gave no connection: the console asks again after a start or a connect.
	programs:    [LINE_RECORD_PROGRAMS]string, // The programs that the line called.
	program_count: int,
	// The group of the last record that the console drew: a record of the
	// same program and channel needs no new head.
	head_program: [32]u8,
	head_channel: [16]u8,
	head_drawn:   bool,
	rows:        [LINE_RECORD_BATCH * module.RECORD_SIZE_LIMIT]u8, // The rows of one answer that the console draws.
}

line_records: Line_Records

// line_records_start forgets the calls of the line before.
line_records_start :: proc "contextless" () {
	line_records.marked, line_records.unavailable, line_records.program_count, line_records.head_drawn = false, false, 0, false
}

// line_records_try_again lets the console ask for the connection again: a
// program started, or a service was connected.
line_records_try_again :: proc "contextless" () {
	line_records.refused = false
}

// line_records_sandbox gives the connection to the log service, or nil.
line_records_sandbox :: proc "contextless" () -> (found: ^Sandbox, number: int) {
	for &sandbox, index in sandboxes {
		if sandbox.service && sandbox.name == LINE_RECORD_SERVICE {
			return &sandbox, index + 1
		}
	}
	return nil, 0
}

// line_records_connect gives a connection to the log service that runs:
// the one that connect("log") made, or one that the console asks for
// itself, with no command. false: no service, or the root service refused.
line_records_connect :: proc "contextless" () -> bool {
	sandbox, _ := line_records_sandbox()
	if sandbox == nil {
		if line_records.refused {
			return false
		}
		place, _ := sandbox_free()
		if place == nil {
			return false
		}
		place^ = {
			name    = LINE_RECORD_SERVICE,
			service = true,
			quiet   = true,
		}
		sandbox = place
	}
	if sandbox.program == 0 {
		if line_records.refused {
			return false
		}
		if service_connect(sandbox) != .Ok {
			// A connection of the console itself that the root service
			// refuses leaves no place taken.
			if sandbox.quiet {
				sandbox^ = {}
			}
			line_records.refused = true
			return false
		}
	}
	// The descriptions of the two exports, from the file that the root
	// service named by its hash.
	if line_records.file == nil || line_records.file_hash != sandbox.hash {
		line_records.file = nil
		entry := system.image_entry_of(image, sandbox.hash)
		if entry == nil {
			return false
		}
		file := image[entry.offset:][:entry.size]
		if module.validate(file) != .None {
			return false
		}
		records_export := module.export_find(file, "records")
		value_runs_export := module.export_find(file, "value_runs")
		records, has_records := module.function(file, records_export)
		value_runs, has_value_runs := module.function(file, value_runs_export)
		if records_export == 0 || value_runs_export == 0 || !has_records || !has_value_runs || records.parameter_count != 1 || value_runs.parameter_count != 1 || records.result != .Table || value_runs.result != .Table {
			return false
		}
		line_records.file, line_records.file_hash = file, sandbox.hash
		line_records.records, line_records.records_export = records, records_export
		line_records.value_runs, line_records.value_runs_export = value_runs, value_runs_export
	}
	return true
}

// line_records_ask calls one export of the log service with the number of
// a log record, and gives the rows of its table: they are in the call
// region, until the next call. total is the count of the rows of the full
// answer. The service wrote the rows and the count: the console reads no
// more than the buffer, and reads each row with the description.
line_records_ask :: proc "contextless" (function: module.Function, export: u32, after: u64) -> (table: Value, total: u64, ok: bool) {
	sandbox, _ := line_records_sandbox()
	if sandbox == nil || sandbox.program == 0 {
		return {}, 0, false
	}
	arguments := [1]isolated.Argument{{integer = after}}
	offset, size, buffer, _, encoded := isolated.encode(line_records.file, function, arguments[:], sandbox.region)
	if !encoded {
		return {}, 0, false
	}
	sandbox.calls += 1
	if !system.send(&sandbox.ring.commands, ring.Record{kind = export, tag = sandbox.calls, values = {0 = offset, 1 = size}}) {
		return {}, 0, false
	}
	limit := system.time() + LINE_RECORD_ANSWER_LIMIT
	for {
		wait := system.wait_begin()
		for _ in 0 ..< ring.CAPACITY {
			completion, has_completion := system.receive(&sandbox.ring.completions)
			if !has_completion {
				break
			}
			if completion.tag != sandbox.calls {
				continue
			}
			if isolated.Status(completion.kind) != .Ok || i64(completion.values[0]) < 0 {
				return {}, 0, false
			}
			described, has_record := module.record_type(line_records.file, function.result_detail)
			if !has_record {
				return {}, 0, false
			}
			rows, _ := isolated.result_table(sandbox.region, buffer, completion.values[0], u64(described.size))
			return {kind = .Table, record = rows, file = line_records.file, detail = function.result_detail}, completion.values[0], true
		}
		if state, _ := system.program_state(sandbox.program); state == .Stopped {
			return {}, 0, false
		}
		system.wait_records(&wait, &sandbox.ring.completions)
		if system.wait_end(&wait, limit) >= limit {
			return {}, 0, false
		}
	}
}

// line_records_call_begins notes that the line calls a program now. At the
// first call of a line, the console finds the number of the next log
// record: the records before it are not records of the line.
line_records_call_begins :: proc "contextless" (program: string) {
	// The console reads the records through the log service: it does not
	// call it while the line calls it.
	if program == LINE_RECORD_SERVICE || line_records.unavailable {
		return
	}
	known := false
	for name in line_records.programs[:line_records.program_count] {
		known ||= name == program
	}
	if !known && line_records.program_count < LINE_RECORD_PROGRAMS {
		line_records.programs[line_records.program_count] = program
		line_records.program_count += 1
	}
	if line_records.marked {
		return
	}
	line_records.marked = true
	if !line_records_connect() {
		line_records.unavailable = true
		return
	}
	// The count of the rows from a number on is the count of the records
	// that the log has from it: the next record has the number after them.
	for _ in 0 ..< LINE_RECORD_ANSWERS {
		answer, total, ok := line_records_ask(line_records.records, line_records.records_export, line_records.next)
		table, valid := table_of(answer)
		if !ok {
			line_records.unavailable = true
			return
		}
		if !valid || table.rows == 0 || total == 0 {
			return
		}
		number, has_number := table_field(table, "number")
		if !has_number {
			line_records.unavailable = true
			return
		}
		first := u64(max(module.field_integer(table_row(table, answer, 0), number), 0))
		reached := first + total
		if reached <= line_records.next {
			return
		}
		line_records.next = reached
	}
}

// line_records_follows says if the line called a program with a name.
line_records_follows :: proc "contextless" (program: string) -> bool {
	for name in line_records.programs[:line_records.program_count] {
		if name == program {
			return true
		}
	}
	return false
}

// line_records_show_during shows the new records while a call waits for
// its program. active: the sandbox of the call; the console does not use
// the connection of a call that runs.
line_records_show_during :: proc "contextless" (active: int) {
	if _, number := line_records_sandbox(); number == active {
		return
	}
	line_records_show()
}

// line_records_show reads the log records that came since the last read,
// and draws those of the programs that the line called.
line_records_show :: proc "contextless" () {
	if !line_records.marked || line_records.unavailable || line_records.program_count == 0 {
		return
	}
	for _ in 0 ..< LINE_RECORD_ANSWERS {
		answer, total, ok := line_records_ask(line_records.records, line_records.records_export, line_records.next)
		if !ok {
			line_records.unavailable = true
			return
		}
		table, valid := table_of(answer)
		if !valid || table.rows == 0 || table.size > module.RECORD_SIZE_LIMIT {
			return
		}
		number, has_number := table_field(table, "number")
		program, has_program := table_field(table, "program")
		runs, has_runs := table_field(table, "runs")
		if !has_number || !has_program || !has_runs {
			line_records.unavailable = true
			return
		}
		// The rows of the programs of the line, out of the call region:
		// the next call writes over it.
		kept := 0
		taken := 0
		with_runs := false
		for index in 0 ..< table.rows {
			if kept == LINE_RECORD_BATCH {
				break
			}
			row := table_row(table, answer, index)
			taken += 1
			line_records.next = max(line_records.next, u64(max(module.field_integer(row, number), 0)) + 1)
			if !line_records_follows(module.field_text(row, program)) {
				continue
			}
			copy(line_records.rows[kept * table.size:][:table.size], row)
			with_runs ||= module.field_integer(row, runs) > 0
			kept += 1
		}
		if kept > 0 {
			kept_rows := Value{kind = .Table, record = line_records.rows[:kept * table.size], file = answer.file, detail = answer.detail}
			line_records_draw(table, kept_rows, kept, with_runs)
		}
		if taken == table.rows && total <= u64(table.rows) {
			return
		}
	}
}

// line_records_draw draws records of one answer: for each program and
// channel, in the order of its first record, one head line and its
// records. With runs, the console asks the service for the value runs of
// the records from the first one on.
line_records_draw :: proc "contextless" (table: Table, kept_rows: Value, kept: int, with_runs: bool) {
	number, _ := table_field(table, "number")
	program, _ := table_field(table, "program")
	channel, has_channel := table_field(table, "channel")
	level, has_level := table_field(table, "level")
	text, has_text := table_field(table, "text")
	continues, has_continues := table_field(table, "continues")
	if !has_channel || !has_level || !has_text || !has_continues {
		return
	}
	run_rows: Value
	run_table: Table
	has_run_table := false
	if with_runs {
		first := u64(max(module.field_integer(table_row(table, kept_rows, 0), number), 0))
		if answer, _, ok := line_records_ask(line_records.value_runs, line_records.value_runs_export, first); ok {
			run_rows = answer
			run_table, has_run_table = table_of(answer)
		}
	}
	system.lock(&output_lock)
	defer system.unlock(&output_lock)
	// The records are in the log already: these lines go to the terminal
	// only.
	output_logged = false
	defer output_logged = true
	drawn: [LINE_RECORD_BATCH]bool
	for first in 0 ..< kept {
		if drawn[first] {
			continue
		}
		first_row := table_row(table, kept_rows, first)
		group_program := module.field_text(first_row, program)
		group_channel := module.field_text(first_row, channel)
		if !line_records.head_drawn || system.name_of(line_records.head_program[:]) != group_program || system.name_of(line_records.head_channel[:]) != group_channel {
			line_records.head_program, line_records.head_channel = {}, {}
			copy(line_records.head_program[:len(line_records.head_program) - 1], group_program)
			copy(line_records.head_channel[:len(line_records.head_channel) - 1], group_channel)
			line_records.head_drawn = true
			output_continuation = LINE_RECORD_INDENT
			emit("  ", {})
			emit(group_program, value_kind_style(.Module))
			if group_channel != "" {
				emit(" ", {})
				emit(group_channel, {tone = .Accent})
			}
			emit_end()
		}
		open := false // The text of the record before goes on in this one.
		for index in first ..< kept {
			row := table_row(table, kept_rows, index)
			if drawn[index] || module.field_text(row, program) != group_program || module.field_text(row, channel) != group_channel {
				continue
			}
			drawn[index] = true
			plain: terminal.Style
			if module.field_text(row, level) == "error" {
				plain.tone = .Bad
			}
			output_continuation = LINE_RECORD_INDENT
			if !open {
				emit("    ", {})
			}
			record_text := module.field_text(row, text)
			place := 0
			if has_run_table {
				place = line_records_runs_emit(run_table, run_rows, module.field_integer(row, number), record_text, plain)
			}
			emit(record_text[place:], plain)
			open = module.field_integer(row, continues) != 0
			if !open {
				emit_end()
			}
		}
		if open {
			emit_end()
		}
	}
	output_continuation = 0
}

// line_records_runs_emit writes the text of a record up to the end of its
// last value run: each run in the color of its value kind, the text
// between two runs plain. It gives the count of the bytes that it wrote.
// A run that is not in the text after the run before it is not drawn: the
// service wrote the rows.
line_records_runs_emit :: proc "contextless" (run_table: Table, run_rows: Value, record_number: i64, record_text: string, plain: terminal.Style) -> (place: int) {
	number, has_number := table_field(run_table, "number")
	start_field, has_start := table_field(run_table, "start")
	length_field, has_length := table_field(run_table, "length")
	kind_field, has_kind := table_field(run_table, "kind")
	if !has_number || !has_start || !has_length || !has_kind {
		return 0
	}
	for index in 0 ..< run_table.rows {
		row := table_row(run_table, run_rows, index)
		of_record := module.field_integer(row, number)
		// The rows are in the order of the records.
		if of_record > record_number {
			break
		}
		if of_record != record_number {
			continue
		}
		start_value, length_value := module.field_integer(row, start_field), module.field_integer(row, length_field)
		if start_value < i64(place) || length_value < 1 || start_value > i64(len(record_text)) || length_value > i64(len(record_text)) - start_value {
			continue
		}
		start, length := int(start_value), int(length_value)
		kind := value_kinds.Value_Kind.None
		kind_name := module.field_text(row, kind_field)
		for candidate in value_kinds.Value_Kind {
			if candidate != .None && value_kinds.VALUE_KIND_NAMES[candidate] == kind_name {
				kind = candidate
			}
		}
		emit(record_text[place:start], plain)
		emit(record_text[start:start + length], kind == .None ? plain : value_kind_style(kind))
		place = start + length
	}
	return place
}
