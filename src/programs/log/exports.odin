package log

import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/value_kinds"
import op "modus:contract/operation"
import "modus:support/system"
import "base:intrinsics"

// The log is also a service: records() gives the log records as a table of
// records with typed fields, so that a reader checks the
// program, the channel and the level of a record, not a line of text. The
// serial port keeps the same records as lines: it works before any service
// runs, and when the network does not.
//
// The records of the log are facts of all the programs, and a program sees
// no other program: the export gives them only to a caller that acts for
// the principal.

// One row of the log: records(). A row has 256 bytes, the most that a
// record of a description has, and holds one log record: its text has the
// 152 bytes of the text of a log record. A row says that its text goes on in
// the next row (continues), as a log record says that its text goes on in
// the next log record (Log_Record.more).
Record :: struct {
	number:    i64, // The number of the log record, from 0.
	time:      i64, // Microseconds since the start of the machine.
	program:   [32]u8, // The name of the program, or "kernel".
	slot:      i64, // The slot of the program. 0: the kernel.
	level:     [8]u8, // info, debug, warning or error.
	channel:   [16]u8, // Empty: the program gave no channel.
	lost:      i64, // The first row only: the log records after `after` that the kernel wrote over before this call read them.
	continues: i64, // 1: the text goes on in the next row.
	runs:      i64, // The count of the value runs of the text: value_runs() gives them.
	text:      [152]u8, // op.LOG_TEXT_CAPACITY: the tool that reads the descriptions needs the number.
}
#assert(size_of(Record) == 256)
#assert(op.LOG_TEXT_CAPACITY == 152)

// One value run of a log record: value_runs(). It says that the bytes start ..<
// start + length of the text of the record `number` are a value of the
// kind `kind`: number, size, time, module, version, status...
Value_Run :: struct {
	number: i64, // The number of the log record.
	start:  i64, // From 0, in bytes of the text of the record.
	length: i64, // In bytes, at least 1.
	kind:   [16]u8, // The name of the value kind, as the site names it.
}

ERROR_ACTS_FOR_PRINCIPAL :: -1

@(rodata)
level_names := [system.Log_Level]string {
	.Info    = "info",
	.Debug   = "debug",
	.Warning = "warning",
	.Error   = "error",
}

service: system.Service
reader_head: ^op.Log_Head
reader_records: [^]op.Log_Record

// first_kept gives the first record from `after` on that the kernel did not
// write over, and the count of the records before it that it wrote over.
first_kept :: proc "contextless" (after: i64, written: u64) -> (next, lost: u64) {
	next = min(u64(max(after, 0)), written)
	if written - next > op.LOG_RECORD_CAPACITY {
		lost = written - next - op.LOG_RECORD_CAPACITY
		next += lost
	}
	return next, lost
}

// records gives the log records from the number `after` on, one row each: the number, the time in microseconds, the program and its slot, the level, the channel, the count of its value runs, and the text. A row says when its text goes on in the next row. The first row also gives the records that the kernel wrote over before this call read them. The result is the count of the rows from `after` to the last record, or a negative number with an error record. The error kind: No_Grant (-1, the caller does not act for the principal).
//
// **What it is for.** A reader of the log checks the program, the channel
// and the level of a record as fields, not by a search in a line of text.
// The machine test reads the log this way, through the remote service.
//
// **Parameter**: `after`, the number of the first record to give, from 0.
// A negative number is 0. A number past the last record gives no row.
//
// **A row** (`Record`): `number`; `time`, microseconds since the start of
// the machine; `program`, its name or `kernel`; `slot`, 0 for the kernel;
// `level`, `info`, `debug`, `warning` or `error`; `channel`, empty when the
// program gave none; `lost`, in the first row only; `continues`, 1 when the
// text goes on in the next row; `runs`, the count of its value runs; `text`,
// at most 152 bytes.
//
// **The result** counts the rows from `after` to the last record, also the
// ones that do not fit in the table of the caller: a caller that gets a
// result larger than its table calls again with `after` set past its last
// row. The kernel keeps the last 2047 records only: `lost` in the first row
// counts the records after `after` that the kernel wrote over before the
// read, and the rows start after them.
//
// **Grant**: the caller must **act for the principal**: the records are
// facts of all the programs. A caller without it gets the error kind
// `No_Grant`, with the result -1.
//
// ```
// connect("log")
// log.records(0)
// where(log.records(0), "program", "console")
// ```
@(export, link_name = "records")
records :: proc "c" (after: i64, result: ^[]Record, error: ^errors.Error_Record) -> i64 {
	if caller := system.service_caller(); caller != nil && caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL == 0 {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	written := intrinsics.atomic_load(&reader_head.written)
	next, lost := first_kept(after, written)
	total := written - next
	count := 0
	for next < written && count < len(result^) {
		record := reader_records[next % op.LOG_RECORD_CAPACITY]
		// The kernel can write over the record during the copy.
		if intrinsics.atomic_load(&reader_head.written) - next > op.LOG_RECORD_CAPACITY {
			lost += 1
			next += 1
			continue
		}
		// Each place of the result has a row (a Table result: the caller
		// reads min(count, capacity) rows).
		text_count := min(int(record.text_count), len(record.text))
		row := &result[count]
		row^ = {number = i64(record.sequence), time = i64(record.time), slot = i64(record.program)}
		copy(row.program[:len(row.program) - 1], system.name_of(record.name[:]))
		if record.level <= max(system.Log_Level) {
			copy(row.level[:], level_names[record.level])
		}
		copy(row.channel[:], system.name_of(record.channel[:]))
		copy(row.text[:], record.text[:text_count])
		row.continues = record.more != 0 ? 1 : 0
		row.runs = i64(min(int(record.run_count), len(record.runs)))
		count += 1
		next += 1
	}
	if count > 0 {
		result[0].lost = i64(lost)
	}
	return i64(total)
}

// value_runs gives the value runs of the log records from the number `after` on: for each one, the number of its record, its start and its length in bytes of the text of the record, and the name of its kind (number, size, time, module, version, status...). The rows of one record are in the order of its text. The result is the count of the runs from `after` to the last record, or a negative number with an error record. The error kind: No_Grant (-1, the caller does not act for the principal).
//
// **What it is for.** A value run says that a part of the text of a record
// is a value of a known kind. A reader joins these rows to the rows of
// `records` by `number`, and finds each value without a parse of the text:
// the window of the log draws each run in the color of its kind.
//
// **Parameter**: `after`, the number of the first record, as for
// `records`. The records that the kernel wrote over are skipped.
//
// **A row** (`Value_Run`): `number`, the record; `start` and `length`, in
// bytes of its text; `kind`, the name of the value kind. A run that does
// not fit in the text of its record gives no row.
//
// **The result** counts all the runs from `after` on, also the ones that do
// not fit in the table of the caller.
//
// **Grant**: the caller must **act for the principal**; else the error
// kind `No_Grant`, with the result -1.
//
// ```
// connect("log")
// join(log.records(0), log.value_runs(0), "number")
// ```
@(export, link_name = "value_runs")
value_runs :: proc "c" (after: i64, result: ^[]Value_Run, error: ^errors.Error_Record) -> i64 {
	if caller := system.service_caller(); caller != nil && caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL == 0 {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	written := intrinsics.atomic_load(&reader_head.written)
	next, _ := first_kept(after, written)
	total := 0
	count := 0
	for ; next < written; next += 1 {
		record := reader_records[next % op.LOG_RECORD_CAPACITY]
		// The kernel can write over the record during the copy.
		if intrinsics.atomic_load(&reader_head.written) - next > op.LOG_RECORD_CAPACITY {
			continue
		}
		text_count := min(int(record.text_count), len(record.text))
		for index in 0 ..< min(int(record.run_count), len(record.runs)) {
			run := record.runs[index]
			start, end, ok := value_kinds.value_run_in_text(run, text_count)
			if !ok {
				continue
			}
			total += 1
			if count < len(result^) {
				row := &result[count]
				row^ = {number = i64(record.sequence), start = i64(start), length = i64(end - start)}
				copy(row.kind[:], value_kinds.VALUE_KIND_NAMES[run.kind])
				count += 1
			}
		}
	}
	return i64(total)
}
