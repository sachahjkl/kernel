package terminal_records

// The runs of code of a row: what each part of a line of code is, so that
// the terminal colors it (docs/CONSOLE.md, section 7). The program sends
// kinds, not colors: the terminal maps each kind to a class of the colors
// of code of the system (support/graphics/code_colors.odin), so one table
// changes the colors of every terminal.
//
// Two forms carry kinds:
//   - a Text record: Style.code, one kind for the whole run of text: the
//     lines that the terminal keeps have runs already;
//   - a Code_Runs record: the runs of the next Edit record, or of the next
//     List_Row record of one row: a row that the terminal keeps whole.
// A run gives a color, never text: a run that is refused, or a row with
// more runs than CODE_RUN_LIMIT, leaves the text whole and plain.

import "contract:ring"
import "support:graphics"

// What a run of code is.
Code_Kind :: enum u8 {
	None            = 0, // No kind: the color of the style of the text.
	Function        = 1, // The name of a command or of an export: in a call, or at the start of its signature.
	Module          = 2, // The name of a module or of a service: before the dot of its export, or alone.
	Type            = 3, // Integer, Text, Table, Bytes, Handle, a record, and what a type holds in its parentheses.
	Parameter       = 4, // The name of a parameter in a signature, before its ':'.
	Variable        = 5, // The name of a variable of the console, also before '=' and before '.field'.
	Number          = 6,
	Text            = 7, // A text in double quotes, with its quotes.
	Text_Unfinished = 8, // A text with no end quote yet: the person still types it.
	Operator        = 9, // An operator or punctuation: + - * / % = ( ) , : . { }
	Arrow           = 10, // '->' before the result of a signature.
	Words           = 11, // The words of a row of a list that are not code: "export of", "command", "3 lines ago".
	Unknown         = 12, // A name that is no command, module or variable, or a byte that the language does not take.
}

// One run: start and length in bytes of the text of its row. A row has at
// most RUN_LIMIT bytes: a byte holds its start. A part of one kind that is
// longer than 255 bytes is two runs.
Code_Run :: struct {
	start:    u8,
	length:   u8,
	kind:     Code_Kind,
	reserved: u8,
}
#assert(size_of(Code_Run) == 4)

// The runs of one row: the bytes of one record of the text region.
CODE_RUN_LIMIT :: RUN_LIMIT / size_of(Code_Run)

Code_Runs :: struct {
	runs:  [CODE_RUN_LIMIT]Code_Run,
	count: int,
}

// The class of the colors of code of each kind. Parameter, Module and
// Variable have the color of the text around them, as the names of the
// parameters on the site; an unfinished text has the color of a text, so
// that a text does not change its color at each key; an unknown name is
// quiet, not red: the error comes when the line runs.
@(rodata)
code_kind_classes := [Code_Kind]graphics.Code_Class {
	.None            = .None,
	.Function        = .Name,
	.Module          = .None,
	.Type            = .Type,
	.Parameter       = .None,
	.Variable        = .None,
	.Number          = .Literal,
	.Text            = .Literal,
	.Text_Unfinished = .Literal,
	.Operator        = .Punctuation,
	.Arrow           = .Punctuation,
	.Words           = .Comment,
	.Unknown         = .Comment,
}

// code_kind_of gives the kind of a byte that a program wrote: a value past
// the kinds is None.
code_kind_of :: proc "contextless" (value: u8) -> Code_Kind {
	return value <= u8(max(Code_Kind)) ? Code_Kind(value) : Code_Kind.None
}

// code_kind_color gives the color of a kind on a dark surface, or plain
// when the kind has no class of its own.
code_kind_color :: proc "contextless" (kind: Code_Kind, plain: graphics.Color) -> graphics.Color {
	class := code_kind_classes[kind]
	return class == .None ? plain : graphics.code_class_color(class, false)
}

// code_runs_send gives the runs of the next record of a target: Kind.Edit,
// or Kind.List_Row with the number of its row. The program sends it just
// before that record. No runs: nothing is sent, and the record is plain.
code_runs_send :: proc "contextless" (terminal: ^Terminal, target: Kind, row: int, runs: []Code_Run) {
	count := min(len(runs), CODE_RUN_LIMIT)
	if count == 0 {
		return
	}
	append(terminal, string(([^]u8)(raw_data(runs))[:count * size_of(Code_Run)]))
	push(terminal, ring.Record{kind = u32(Kind.Code_Runs), tag = u32(count * size_of(Code_Run)), values = {0 = u64(target), 1 = u64(max(row, 0))}})
}

// code_runs_read copies the runs of a Code_Runs record from its two parts
// of the text region. A count of bytes that is not a whole count of runs
// gives no runs, and false.
code_runs_read :: proc "contextless" (first, second: []u8) -> (read: Code_Runs, ok: bool) {
	size := len(first) + len(second)
	if size % size_of(Code_Run) != 0 || size > CODE_RUN_LIMIT * size_of(Code_Run) {
		return {}, false
	}
	bytes := ([^]u8)(&read.runs)[:CODE_RUN_LIMIT * size_of(Code_Run)]
	copied := copy(bytes, first)
	copied += copy(bytes[copied:], second)
	read.count = copied / size_of(Code_Run)
	return read, true
}

// code_runs_check keeps the runs of a row of length bytes when each run is
// inside the row, after the run before it, with at least one byte and a
// kind that exists. One run that is not: the row has no runs, and false.
// The text is not changed in either case.
code_runs_check :: proc "contextless" (runs: ^Code_Runs, length: int) -> bool {
	count := clamp(runs.count, 0, CODE_RUN_LIMIT)
	end := 0
	for run in runs.runs[:count] {
		start := int(run.start)
		if run.length == 0 || start < end || start + int(run.length) > length || u8(run.kind) > u8(max(Code_Kind)) || run.kind == .None {
			runs.count = 0
			return false
		}
		end = start + int(run.length)
	}
	runs.count = count
	return true
}

// code_runs_kind_at gives the kind of the byte place of a row, from the
// place of the run that covered the byte before (a cursor that a loop over
// the bytes in order keeps): each byte costs one step at most.
code_runs_kind_at :: proc "contextless" (runs: ^Code_Runs, place: int, cursor: ^int) -> Code_Kind {
	count := clamp(runs.count, 0, CODE_RUN_LIMIT)
	for cursor^ < count && int(runs.runs[cursor^].start) + int(runs.runs[cursor^].length) <= place {
		cursor^ += 1
	}
	if cursor^ < count && int(runs.runs[cursor^].start) <= place {
		return runs.runs[cursor^].kind
	}
	return .None
}
