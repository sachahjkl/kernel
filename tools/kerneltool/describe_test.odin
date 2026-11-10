package kerneltool

import module "contract:module"
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
	// The documentation text: one line for each paragraph.
	testing.expect_value(
		t,
		package_text,
		"A sample of a module. The second sentence of the first paragraph.\n\nA list:\n  one line that stays\n- a point\n- a second point, on two lines",
	)
	testing.expect_value(t, about_of(package_text, ""), "A sample of a module")
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
		{"an entry with an integer", "package p\n@(export)\nentry :: proc \"c\" (a: i64) -> ! {for {}}\n"},
	}
	for item in cases {
		list := make([dynamic]Export_Description, context.temp_allocator)
		testing.expectf(t, !describe_source("case.odin", item.source, &list), "%s", item.about)
	}
}
