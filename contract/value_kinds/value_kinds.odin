// The kinds of the values that the system shows, and the value runs of a
// text: which bytes of a text are a number, a size, a time or a module.
//
// One enumeration of kinds for the system and for the site of the system:
// the site writes each kind with its class and its icon, a program draws it
// in its color, and both take the color from one table of the design rules
// (support/graphics/value_colors.odin). A writer states the kind of each
// part that it writes: no text is classified by its look.
//
// A log record keeps the runs of its text (operation.Log_Record), so that a
// reader shows each value in the color of its kind. The text itself does
// not change: the serial port, the machine tests and a reader that ignores
// the runs read the same bytes as before (docs/TOOLS.md, "The log").
package value_kinds

Value_Kind :: enum u8 {
	None      = 0, // Not a value: a name or a text.
	Number    = 1, // A count, a place, an index or an address.
	Size      = 2, // A size in bytes, pages or blocks.
	Time      = 3, // A duration, a date or a time.
	Handle    = 4,
	Value     = 5, // A plain value of the context of a program: not a handle.
	Grant     = 6,
	Status    = 7, // A status, an error kind or the state of a property.
	Type      = 8,
	Operation = 9,
	Command   = 10,
	Module    = 11, // A module or a program.
	File      = 12,
	Guide     = 13,
	Term      = 14,
	Version   = 15, // A version, a release, a commit or a hash.
	Yes       = 16,
	No        = 17,
	Procedure = 18,
	Constant  = 19,
	Variable  = 20,
}

// The name of each kind: the class "value-<name>" of the site, and the kind
// of a value run in a table of the log.
@(rodata)
VALUE_KIND_NAMES := [Value_Kind]string {
	.None      = "",
	.Number    = "number",
	.Size      = "size",
	.Time      = "time",
	.Handle    = "handle",
	.Value     = "value",
	.Grant     = "grant",
	.Status    = "status",
	.Type      = "type",
	.Operation = "operation",
	.Command   = "command",
	.Module    = "module",
	.File      = "file",
	.Guide     = "guide",
	.Term      = "term",
	.Version   = "version",
	.Yes       = "yes",
	.No        = "no",
	.Procedure = "procedure",
	.Constant  = "constant",
	.Variable  = "variable",
}

// value_kind_of gives the kind of a byte that another party wrote: a value
// past the kinds is None.
value_kind_of :: proc "contextless" (value: u8) -> Value_Kind {
	return value <= u8(max(Value_Kind)) ? Value_Kind(value) : Value_Kind.None
}

// A value run of a log record: start and length in bytes of the text of the
// record. A record has fewer than 256 bytes of text, so a byte holds its
// start.
Value_Run :: struct {
	start:  u8,
	length: u8,
	kind:   Value_Kind,
}
#assert(size_of(Value_Run) == 3)

// A value run of a text that is longer than one record: the text of one Log
// operation (at most 4096 bytes), or the text that the kernel writes for
// itself. The kernel cuts these runs at the bounds of the records.
Value_Run_In_Call :: struct {
	start:    u16,
	length:   u16,
	kind:     Value_Kind,
	reserved: u8,
}
#assert(size_of(Value_Run_In_Call) == 6)

// The typed parts of a line of the log. Each one writes exactly the text
// that a number and a text after it wrote before the kinds existed: the
// value in decimal, then the unit with a space before it. The run covers the
// number and its unit.

Size_Unit :: enum u8 {
	Bytes     = 0,
	Kibibytes = 1,
	Mebibytes = 2,
	Pages     = 3,
	Blocks    = 4,
}

@(rodata)
SIZE_UNIT_TEXTS := [Size_Unit]string {
	.Bytes     = " bytes",
	.Kibibytes = " KiB",
	.Mebibytes = " MiB",
	.Pages     = " pages",
	.Blocks    = " blocks",
}

// A size: the value in its unit. "Size{64, .Mebibytes}" writes "64 MiB".
Size :: struct {
	value: u64,
	unit:  Size_Unit,
}

Duration_Unit :: enum u8 {
	Nanoseconds  = 0,
	Microseconds = 1,
	Milliseconds = 2,
	Seconds      = 3,
}

@(rodata)
DURATION_UNIT_TEXTS := [Duration_Unit]string {
	.Nanoseconds  = " ns",
	.Microseconds = " us",
	.Milliseconds = " ms",
	.Seconds      = " s",
}

// A duration: the value in its unit. "Duration{820, .Microseconds}" writes
// "820 us".
Duration :: struct {
	value: u64,
	unit:  Duration_Unit,
}

// A hash, or the head of one: two hexadecimal digits for each byte, the
// first byte first. The kind is Version.
Hash :: struct {
	bytes: []u8,
}

// The name of a program or of a module, as it is. The kind is Module.
Module_Name :: struct {
	name: string,
}

size_unit_text :: proc "contextless" (unit: Size_Unit) -> string {
	return unit <= max(Size_Unit) ? SIZE_UNIT_TEXTS[unit] : ""
}

duration_unit_text :: proc "contextless" (unit: Duration_Unit) -> string {
	return unit <= max(Duration_Unit) ? DURATION_UNIT_TEXTS[unit] : ""
}

// value_run_add adds the run of a part that a writer put at the bytes
// start ..< end of its text. A part of no kind, a part with no byte, a part
// past the bytes that a start can name, or a table of runs that is full:
// no run, and the part stays plain. The text never changes.
value_run_add :: proc "contextless" (runs: []Value_Run_In_Call, count: ^int, start, end: int, kind: Value_Kind) {
	if kind == .None || start < 0 || end <= start || end > 0xFFFF || count^ >= len(runs) {
		return
	}
	runs[count^] = {start = u16(start), length = u16(end - start), kind = kind}
	count^ += 1
}

// value_runs_cut keeps the runs inside the first `length` bytes of a text:
// a run that starts at or after the end goes, and a run that crosses it
// ends there. It gives the new count. A writer calls it when the text ends
// with the cut mark, so that no run colors the mark.
value_runs_cut :: proc "contextless" (runs: []Value_Run_In_Call, count: int, length: int) -> int {
	kept := 0
	for index in 0 ..< min(count, len(runs)) {
		run := runs[index]
		if int(run.start) >= length {
			break
		}
		run.length = u16(min(int(run.length), length - int(run.start)))
		runs[kept] = run
		kept += 1
	}
	return kept
}

// value_runs_after keeps the parts of the runs at or after the byte `from`
// of a text, from the start of what follows it: a writer that sent the first
// `from` bytes as one line keeps the runs of the rest. It gives the new
// count.
value_runs_after :: proc "contextless" (runs: []Value_Run_In_Call, count: int, from: int) -> int {
	kept := 0
	for index in 0 ..< min(count, len(runs)) {
		run := runs[index]
		start := int(run.start)
		end := start + int(run.length)
		if end <= from {
			continue
		}
		start = max(start, from)
		runs[kept] = {start = u16(start - from), length = u16(end - start), kind = run.kind}
		kept += 1
	}
	return kept
}

// value_runs_check says if the runs fit a text of `length` bytes: each run
// inside the text, after the run before it, with at least one byte and a
// kind that exists and is not None. The runs come from another program: the
// kernel checks them once, in its own copy, before it uses them.
value_runs_check :: proc "contextless" (runs: []Value_Run_In_Call, length: int) -> bool {
	end := 0
	for run in runs {
		if run.length == 0 || int(run.start) < end || int(run.start) + int(run.length) > length {
			return false
		}
		if run.kind == .None || u8(run.kind) > u8(max(Value_Kind)) {
			return false
		}
		end = int(run.start) + int(run.length)
	}
	return true
}

// value_runs_of_record gives the runs of one record: the part of the runs
// of a text that falls in the bytes record_start ..< record_start +
// record_length, from the start of the record. A run that crosses the bound
// of two records is one run in each. At most len(into) runs: a record with
// more parts keeps its first runs, and the rest of its text is plain. The
// runs must be in order (value_runs_check). The work is one pass over the
// runs: at most len(runs) steps.
value_runs_of_record :: proc "contextless" (runs: []Value_Run_In_Call, record_start, record_length: int, into: []Value_Run) -> int {
	count := 0
	record_end := record_start + record_length
	for run in runs {
		run_start := int(run.start)
		run_end := run_start + int(run.length)
		if run_end <= record_start {
			continue
		}
		if run_start >= record_end || count == len(into) {
			break
		}
		start := max(run_start, record_start) - record_start
		end := min(run_end, record_end) - record_start
		if start > 0xFF || end - start > 0xFF {
			break
		}
		into[count] = {start = u8(start), length = u8(end - start), kind = run.kind}
		count += 1
	}
	return count
}

// value_run_in_text gives the bytes of a run of a record inside a text of
// text_count bytes: a run that the record cannot hold gives nothing. A
// reader of a record calls it before it indexes the text.
value_run_in_text :: proc "contextless" (run: Value_Run, text_count: int) -> (start, end: int, ok: bool) {
	start = int(run.start)
	end = start + int(run.length)
	if run.length == 0 || end > text_count || run.kind == .None || u8(run.kind) > u8(max(Value_Kind)) {
		return 0, 0, false
	}
	return start, end, true
}
