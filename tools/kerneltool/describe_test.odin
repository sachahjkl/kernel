package kerneltool

import module "contract:module"
import op "contract:operation"
import "base:runtime"
import "core:odin/tokenizer"
import "core:testing"

// The tokenizer of the Odin library fills its table of keywords at its
// first use. Two threads that use it first at the same time fill the
// table twice, and the second one stops on an assertion ("runtime
// assertion: import"). The test runner gives each test a thread, so the
// table is filled here, before the threads start.
@(init)
keywords_prepare :: proc "contextless" () {
	context = runtime.default_context()
	scanner: tokenizer.Tokenizer
	tokenizer.init(&scanner, "", "")
}

@(private = "file")
DESCRIBED_SOURCE :: `// A sample of a module. The second sentence
// of the first paragraph.
//
// A list:
//   one line that stays
// - a point
// - a second point,
// on two lines
package sample

helper :: proc "c" (x: i64) -> i64 {return x}

// scale gives a number times a factor. The second sentence is not help.
@(export, link_name = "scale")
scale_function :: proc "c" (number, factor: i64) -> i64 {return number * factor}

// title gives a text
// in capital letters.
@(export)
title :: proc "c" (text: ^string, result: ^[]u8) -> i64 {return 0}

// note writes a text to the log.
@(export, link_name = "note")
note :: proc "c" (text: ^string) {}

@(export, link_name = "entry")
entry :: proc "c" (start: rawptr) -> ! {for {}}
`

// The description of each export comes from the source: the name, the names
// and the types of the parameters, the result, and the help.
@(test)
describe_reads_the_source :: proc(t: ^testing.T) {
	list := make([dynamic]Export_Description, context.temp_allocator)
	package_text: string
	testing.expect(t, describe_source("sample.odin", DESCRIBED_SOURCE, &list, &package_text))
	// The documentation text: the comment as its author wrote it. The
	// reader of the system joins the lines of a paragraph.
	testing.expect_value(
		t,
		package_text,
		"A sample of a module. The second sentence\nof the first paragraph.\n\nA list:\n  one line that stays\n- a point\n- a second point,\non two lines",
	)
	testing.expect_value(t, about_of(documentation_text_of_markdown(package_text), ""), "A sample of a module")
	testing.expect_value(t, len(list), 4)
	if len(list) != 4 {
		return
	}
	scale := list[0]
	testing.expect_value(t, scale.name, "scale")
	testing.expect_value(t, scale.about, "gives a number times a factor")
	testing.expect_value(t, scale.text, "scale gives a number times a factor. The second sentence is not help.")
	testing.expect_value(t, scale.result, module.Type.Integer)
	testing.expect_value(t, len(scale.parameters), 2)
	testing.expect_value(t, scale.names[0], "number")
	testing.expect_value(t, scale.names[1], "factor")
	testing.expect_value(t, scale.parameters[1], module.Type.Integer)

	title := list[1]
	testing.expect_value(t, title.name, "title")
	testing.expect_value(t, title.about, "gives a text in capital letters")
	testing.expect_value(t, title.result, module.Type.Text)
	testing.expect_value(t, len(title.parameters), 1)
	testing.expect_value(t, title.parameters[0], module.Type.Text)
	testing.expect_value(t, title.names[0], "text")

	testing.expect_value(t, list[2].result, module.Type.None)
	testing.expect_value(t, list[3].name, "entry")
	testing.expect_value(t, len(list[3].parameters), 0)
}

@(private = "file")
RECORD_SOURCE :: `// Records and handles.
package sample

Span :: struct {
	memory: system.Lent({.Read}),
	first, count: i64,
}

Pair :: struct {
	left:  i64,
	right: i64,
}

Unused :: struct {
	value: i64,
}

// swap gives a pair in the other order.
@(export)
swap :: proc "c" (pair: ^Pair, result: ^Pair) {}

// sum adds the bytes of a span, and writes them.
@(export)
sum :: proc "c" (span: ^Span, target: Lent({.Read, .Write}), pair: ^Pair) -> i64 {return 0}
`

// A struct of the package is a Record with the layout of the C language,
// and Lent is a Handle with the rights that the callee needs.
@(test)
describe_reads_records_and_handles :: proc(t: ^testing.T) {
	list := make([dynamic]Export_Description, context.temp_allocator)
	records: []Record_Description
	testing.expect(t, describe_source("sample.odin", RECORD_SOURCE, &list, nil, &records))
	if len(list) != 2 || len(records) != 2 {
		testing.expectf(t, false, "%d exports and %d records", len(list), len(records))
		return
	}
	// Each record one time, in the order of the first use. Unused has no description.
	pair, span := records[0], records[1]
	testing.expect_value(t, pair.name, "Pair")
	testing.expect_value(t, pair.size, 16)
	testing.expect_value(t, span.name, "Span")
	testing.expect_value(t, span.size, 24)
	testing.expect_value(t, len(span.fields), 3)
	if len(span.fields) == 3 {
		testing.expect_value(t, span.fields[0], Field_Description{"memory", 0, .Handle, transmute(u32)op.Rights{.Read}, false})
		testing.expect_value(t, span.fields[1], Field_Description{"first", 8, .Integer, 0, false})
		testing.expect_value(t, span.fields[2], Field_Description{"count", 16, .Integer, 0, false})
	}
	swap, sum := list[0], list[1]
	testing.expect_value(t, swap.result, module.Type.Record)
	testing.expect_value(t, swap.result_detail, 1)
	testing.expect_value(t, len(swap.parameters), 1)
	testing.expect_value(t, swap.details[0], 1)
	testing.expect_value(t, sum.result, module.Type.Integer)
	testing.expect_value(t, len(sum.parameters), 3)
	if len(sum.parameters) == 3 {
		testing.expect_value(t, sum.parameters[0], module.Type.Record)
		testing.expect_value(t, sum.details[0], 2)
		testing.expect_value(t, sum.parameters[1], module.Type.Handle)
		testing.expect_value(t, sum.details[1], transmute(u32)op.Rights{.Read, .Write})
		testing.expect_value(t, sum.details[2], 1)
	}
}

@(private = "file")
TABLE_SOURCE :: `// Tables of records.
package sample

Row :: struct {
	name:  [20]u8,
	count: i64,
	tag:   [3]u8,
}

// rows gives the rows of a sample, in the memory of the caller.
@(export)
rows :: proc "c" (first: i64, result: ^[]Row) -> i64 {return 0}
`

// A field [N]u8 is a Text of N bytes, and a last parameter result: ^[]Name
// is the buffer of a Table result.
@(test)
describe_reads_tables :: proc(t: ^testing.T) {
	list := make([dynamic]Export_Description, context.temp_allocator)
	records: []Record_Description
	testing.expect(t, describe_source("sample.odin", TABLE_SOURCE, &list, nil, &records))
	if len(list) != 1 || len(records) != 1 {
		testing.expectf(t, false, "%d exports and %d records", len(list), len(records))
		return
	}
	row := records[0]
	testing.expect_value(t, row.size, 40)
	testing.expect_value(t, len(row.fields), 3)
	if len(row.fields) == 3 {
		testing.expect_value(t, row.fields[0], Field_Description{"name", 0, .Text, 20, false})
		testing.expect_value(t, row.fields[1], Field_Description{"count", 24, .Integer, 0, false})
		testing.expect_value(t, row.fields[2], Field_Description{"tag", 32, .Text, 3, false})
	}
	testing.expect_value(t, list[0].result, module.Type.Table)
	testing.expect_value(t, list[0].result_detail, 1)
	testing.expect_value(t, len(list[0].parameters), 1)
}

@(private = "file")
TABLE_PARAMETER_SOURCE :: `// Tables as parameters.
package sample

import "support:system"

Kind :: enum u8 {
	None = 0,
	Box  = 1,
}

Draw :: struct {
	kind:        Kind,
	scale:       u8,
	x, y:        i32,
	color:       u32,
	text_start:  u32,
	text_count:  u32,
	element:     u64,
}

// draw appends the draw records of a frame and their text.
@(export)
draw :: proc "c" (drawn: ^system.Table_To_Read(Draw), changed: ^system.Table_To_Change(Draw), added: ^system.Table_To_Append(Draw), text: ^system.Bytes_To_Append, from: ^system.Bytes_To_Read, packets: ^system.Bytes_To_Change) -> i64 {return 0}
`

// ^system.Table_To_Read(Name) and its forms are Tables with a direction;
// ^system.Bytes_To_Read and its forms are Bytes. A field u8, i32, u32 or an
// enum u8 is an Integer of its size, at its natural alignment.
@(test)
describe_reads_table_parameters :: proc(t: ^testing.T) {
	list := make([dynamic]Export_Description, context.temp_allocator)
	records: []Record_Description
	testing.expect(t, describe_source("sample.odin", TABLE_PARAMETER_SOURCE, &list, nil, &records))
	if len(list) != 1 || len(records) != 1 {
		testing.expectf(t, false, "%d exports and %d records", len(list), len(records))
		return
	}
	draw := records[0]
	testing.expect_value(t, draw.size, 32)
	expected := [?]Field_Description {
		{"kind", 0, .Integer, 1, true},
		{"scale", 1, .Integer, 1, true},
		{"x", 4, .Integer, 4, false},
		{"y", 8, .Integer, 4, false},
		{"color", 12, .Integer, 4, true},
		{"text_start", 16, .Integer, 4, true},
		{"text_count", 20, .Integer, 4, true},
		{"element", 24, .Integer, 0, true},
	}
	testing.expect_value(t, len(draw.fields), len(expected))
	for item, index in expected[:min(len(expected), len(draw.fields))] {
		testing.expect_value(t, draw.fields[index], item)
	}
	export := list[0]
	testing.expect_value(t, len(export.parameters), 6)
	types := [6]module.Type{.Table, .Table, .Table, .Bytes, .Bytes, .Bytes}
	directions := [6]module.Direction{.Read, .Change, .Append, .Append, .Read, .Change}
	details := [6]u32{1, 1, 1, 0, 0, 0}
	for index in 0 ..< min(6, len(export.parameters)) {
		testing.expect_value(t, export.parameters[index], types[index])
		testing.expect_value(t, export.directions[index], directions[index])
		testing.expect_value(t, export.details[index], details[index])
	}
}

// The tool does not guess: a source that breaks a rule gives no description.
@(test)
describe_rejects_what_has_no_description :: proc(t: ^testing.T) {
	Case :: struct {
		about:  string,
		source: string,
	}
	cases := [?]Case {
		{"a parameter of 32 bits", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (x: u32) -> i64 {return 0}\n"},
		{"a float result", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (x: i64) -> f64 {return 0}\n"},
		{"the Odin calling convention", "package p\n// f gives x.\n@(export)\nf :: proc(x: i64) -> i64 {return 0}\n"},
		{"no comment", "package p\n@(export)\nf :: proc \"c\" (x: i64) -> i64 {return 0}\n"},
		{"an export of data", "package p\n// d is data.\n@(export)\nd: i64\n"},
		{"a buffer that is not the last parameter", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (result: ^[]u8, x: i64) -> i64 {return 0}\n"},
		{"a Text result with no count", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (result: ^[]u8) {}\n"},
		{"seven parameters", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (a, b, c, d, e, g, h: i64) -> i64 {return 0}\n"},
		{"a Text result and six parameters", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (a, b, c, d, e, g: i64, result: ^[]u8) -> i64 {return 0}\n"},
		{"a function that does not return", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (x: i64) -> ! {for {}}\n"},
		{"an entry with two parameters", "package p\n@(export)\nentry :: proc \"c\" (a, b: rawptr) -> ! {for {}}\n"},
		{"a record with a float field", "package p\nR :: struct {a: f32}\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^R) -> i64 {return 0}\n"},
		{"a packed record", "package p\nR :: struct #packed {a: i64}\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^R) -> i64 {return 0}\n"},
		{"a record that is too large", "package p\nR :: struct {a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z, aa, ab, ac, ad, ae, af, ag: i64}\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^R) -> i64 {return 0}\n"},
		{"a result record with a handle", "package p\nR :: struct {h: Lent({.Read})}\n// f gives x.\n@(export)\nf :: proc \"c\" (x: i64, result: ^R) {}\n"},
		{"a record result and a result type", "package p\nR :: struct {a: i64}\n// f gives x.\n@(export)\nf :: proc \"c\" (x: i64, result: ^R) -> i64 {return 0}\n"},
		{"a record result and six parameters", "package p\nR :: struct {a: i64}\n// f gives x.\n@(export)\nf :: proc \"c\" (a, b, c, d, e, g: i64, result: ^R) {}\n"},
		{"a pointer to an unknown type", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^Other) -> i64 {return 0}\n"},
		{"a right that does not exist", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (h: Lent({.Fly})) -> i64 {return 0}\n"},
		{"a handle result", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (x: i64) -> Lent({.Read}) {return {}}\n"},
		{"an entry with an integer", "package p\n@(export)\nentry :: proc \"c\" (a: i64) -> ! {for {}}\n"},
		{"a Table result with no count", "package p\nR :: struct {a: i64}\n// f gives x.\n@(export)\nf :: proc \"c\" (result: ^[]R) {}\n"},
		{"a Table that is not the result", "package p\nR :: struct {a: i64}\n// f gives x.\n@(export)\nf :: proc \"c\" (rows: ^[]R, x: i64) -> i64 {return 0}\n"},
		{"a Table of records with a handle", "package p\nR :: struct {h: Lent({.Read})}\n// f gives x.\n@(export)\nf :: proc \"c\" (result: ^[]R) -> i64 {return 0}\n"},
		{"a Text field with a size that is not a number", "package p\nN :: 4\nR :: struct {a: [N]u8}\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^R) -> i64 {return 0}\n"},
		{"a table parameter of records with a handle", "package p\nR :: struct {h: Lent({.Read})}\n// f gives x.\n@(export)\nf :: proc \"c\" (rows: ^Table_To_Read(R)) -> i64 {return 0}\n"},
		{"a table parameter of a type that is not a record", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (rows: ^Table_To_Change(i64)) -> i64 {return 0}\n"},
		{"a table parameter with two types", "package p\nR :: struct {a: i64}\n// f gives x.\n@(export)\nf :: proc \"c\" (rows: ^Table_To_Append(R, R)) -> i64 {return 0}\n"},
		{"an integer field of an enum with no backing type", "package p\nK :: enum {A}\nR :: struct {k: K}\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^R) -> i64 {return 0}\n"},
		{"a Text field of 300 bytes", "package p\nR :: struct {a: [300]u8}\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^R) -> i64 {return 0}\n"},
	}
	for item in cases {
		list := make([dynamic]Export_Description, context.temp_allocator)
		testing.expectf(t, !describe_source("case.odin", item.source, &list), "%s", item.about)
	}
}
