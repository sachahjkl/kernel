package kerneltool

import "core:odin/ast"
import "core:slice"
import "core:strings"
import "core:testing"

// The source of a module with one export, for the tests of the check of
// the declarations: a table to read, an integer, a text, a Text result and
// an error record.
@(private = "file")
EXPORT_SOURCE :: `// A module of the tests.
package exports_of_the_test

import "contract:errors"
import "support:system"

Reading :: struct {
	sensor: i64,
	value:  i32,
	flags:  u32,
}

// sum_values gives the sum of the values.
@(export, link_name = "sum_values")
sum_values :: proc "c" (readings: ^system.Table_To_Read(Reading), factor: i64, name: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	return 0
}
`

// The source of an importer: the record has other names and the same
// layout, the procedure has another name and the attribute link_name, and
// the block is inside a when, as a program declares an import for one
// build setting.
@(private = "file")
IMPORTER_HEAD :: `package importer_of_the_test

import "contract:errors"
import "support:system"

Measure :: struct {
	place:  i64,
	amount: `

@(private = "file")
IMPORTER_MIDDLE :: `,
	bits:   u32,
}

when SETTING_OF_THE_TEST {
	foreign _ {
		// A procedure of an assembly file: no import exports it.
		registers_store :: proc "c" (seen: rawptr, level: u64) ---
		@(link_name = "sum_values")
		module_sum_values :: proc "c" `

@(private = "file")
IMPORTER_TAIL :: ` ---
	}
}
`

// declared_difference parses an importer whose record field has the type
// field_type and whose declaration has the given signature, and compares
// it with the export of EXPORT_SOURCE. readable is false when the
// declaration has a type with no description.
@(private = "file")
declared_difference :: proc(t: ^testing.T, field_type, signature: string) -> (difference: string, readable: bool) {
	exports := make([dynamic]Export_Description, context.temp_allocator)
	records: []Record_Description
	if !testing.expect(t, describe_source("exports_of_the_test.odin", EXPORT_SOURCE, &exports, nil, &records)) || !testing.expect_value(t, len(exports), 1) {
		return "the export was not described", false
	}
	described := call_form_of_description(exports[0], records)
	source := strings.concatenate({IMPORTER_HEAD, field_type, IMPORTER_MIDDLE, signature, IMPORTER_TAIL}, context.temp_allocator)
	state: Describe_State
	state.records = make([dynamic]Record_Description, context.temp_allocator)
	state.structs = make(map[string]Struct_Source, context.temp_allocator)
	file, parsed := parse_source("importer_of_the_test.odin", source, &state)
	if !testing.expect(t, parsed) {
		return "the importer was not parsed", false
	}
	declarations := make([dynamic]Foreign_Declaration, context.temp_allocator)
	foreign_declarations_collect(file.decls[:], &declarations)
	// The two procedures of the block inside the when; the second has the
	// name of its attribute.
	if !testing.expect_value(t, len(declarations), 2) || !testing.expect_value(t, declarations[1].link_name, "sum_values") {
		return "the declarations were not found", false
	}
	testing.expect_value(t, declarations[0].link_name, "registers_store")
	type: ^ast.Proc_Type = declarations[1].type
	declared, problem, form_readable := call_form_of_declaration(&state, source, type)
	if !form_readable {
		return problem, false
	}
	return call_forms_difference(declared, described), true
}

@(private = "file")
GOOD_SIGNATURE :: `(rows: ^system.Table_To_Read(Measure), by: i64, label: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64`

// A declaration with other names and the same call form agrees.
@(test)
a_declaration_with_the_call_form_of_its_export_agrees :: proc(t: ^testing.T) {
	difference, readable := declared_difference(t, "i32", GOOD_SIGNATURE)
	testing.expect(t, readable)
	testing.expect_value(t, difference, "")
}

// Each way in which a declaration can pass other registers than the
// export reads is found, with a sentence that names it.
@(test)
a_declaration_with_another_call_form_is_refused :: proc(t: ^testing.T) {
	Case :: struct {
		field_type: string,
		signature:  string,
		sentence:   string, // A part of the difference.
	}
	cases := [?]Case {
		{"i32", `(rows: ^system.Table_To_Read(Measure), label: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64`, "it has 2 parameters, the export has 3"},
		{"i32", `(rows: ^system.Table_To_Read(Measure), by: ^string, label: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64`, "its parameter 2 is Text, the export has Integer"},
		{"i32", `(rows: ^system.Table_To_Change(Measure), by: i64, label: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64`, "its parameter 1 has the direction Change, the export has Read"},
		{"i32", `(rows: ^system.Bytes_To_Read, by: i64, label: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64`, "its parameter 1 is Bytes, the export has Table"},
		{"i32", `(rows: ^system.Table_To_Read(Measure), by: i64, label: ^string, result: ^[]u8) -> i64`, "it has no error record, the export has one"},
		{"i32", `(rows: ^system.Table_To_Read(Measure), by: i64, label: ^string, error: ^errors.Error_Record) -> i64`, "its result is Integer, the export has Text"},
		{"i64", GOOD_SIGNATURE, "its parameter 1: the record Measure has 24 bytes, the export has Reading of 16 bytes"},
		{"u32", GOOD_SIGNATURE, "its parameter 1: the field amount of the record Measure is not the field value of Reading"},
	}
	for item in cases {
		difference, readable := declared_difference(t, item.field_type, item.signature)
		testing.expectf(t, readable, "the declaration %s was not read: %s", item.signature, difference)
		testing.expectf(t, strings.contains(difference, item.sentence), "the declaration %s: the difference is \"%s\", not \"%s\"", item.signature, difference, item.sentence)
	}
	// A type that the description of an export cannot hold.
	problem, readable := declared_difference(t, "i32", `(rows: rawptr, by: i64, label: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64`)
	testing.expect(t, !readable)
	testing.expect(t, strings.has_prefix(problem, "the type rawptr has no description"), problem)
	// A name for a type of the contract: the tool follows no alias, and
	// the sentence says what to write.
	problem, readable = declared_difference(t, "i32", `(rows: ^Rows_Of_The_Test, by: i64, label: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64`)
	testing.expect(t, !readable)
	testing.expect(t, strings.has_prefix(problem, "the type ^Rows_Of_The_Test has no description"), problem)
	testing.expect(t, strings.contains(problem, "The tool does not read a type alias: write the type itself in the declaration"), problem)
}

// declarations_of_source parses one source and gives the procedures of its
// `foreign` blocks that the tool finds.
@(private = "file")
declarations_of_source :: proc(t: ^testing.T, source: string) -> []Foreign_Declaration {
	state: Describe_State
	state.records = make([dynamic]Record_Description, context.temp_allocator)
	state.structs = make(map[string]Struct_Source, context.temp_allocator)
	declarations := make([dynamic]Foreign_Declaration, context.temp_allocator)
	file, parsed := parse_source("declarations_of_the_test.odin", source, &state)
	if testing.expect(t, parsed) {
		foreign_declarations_collect(file.decls[:], &declarations)
	}
	return declarations[:]
}

// The calling convention of a declaration is read: an export is called
// with the convention "c". A declaration with another convention written,
// or with none in a block whose default is not "c", passes one more
// argument than its parameters say: it is refused.
@(test)
a_declaration_with_another_calling_convention_is_refused :: proc(t: ^testing.T) {
	source := `package conventions_of_the_test

foreign _ {
	written_c :: proc "c" (value: i64) -> i64 ---
	not_written :: proc(value: i64) -> i64 ---
	written_odin :: proc "odin" (value: i64) -> i64 ---
	written_contextless :: proc "contextless" (value: i64) -> i64 ---
}

@(default_calling_convention = "c")
foreign _ {
	default_c :: proc(value: i64) -> i64 ---
}

@(default_calling_convention = "odin")
foreign _ {
	default_odin :: proc(value: i64) -> i64 ---
	default_odin_written_c :: proc "c" (value: i64) -> i64 ---
}
`
	declarations := declarations_of_source(t, source)
	Expected :: struct {
		name:    string,
		refused: bool,
	}
	expected := [?]Expected{{"written_c", false}, {"not_written", false}, {"written_odin", true}, {"written_contextless", true}, {"default_c", false}, {"default_odin", true}, {"default_odin_written_c", false}}
	if !testing.expect_value(t, len(declarations), len(expected)) {
		return
	}
	for item, index in expected {
		testing.expect_value(t, declarations[index].link_name, item.name)
		testing.expectf(t, (declarations[index].convention_problem != "") == item.refused, "%s: the problem of its convention is \"%s\"", item.name, declarations[index].convention_problem)
	}
}

// The symbol of a declaration: its name, the text of link_name, or the name
// after the text of the link_prefix of its block. A name that the source
// does not give as a text is not known, and a block in the body of a
// procedure is not read: such a declaration is compared with no export.
@(test)
the_symbol_of_a_declaration :: proc(t: ^testing.T) {
	source := `package symbols_of_the_test

NAME_OF_THE_TEST :: "constant_name"

foreign _ {
	plain_name :: proc "c" (value: i64) -> i64 ---
	@(link_name = "text_name")
	with_a_text :: proc "c" (value: i64) -> i64 ---
	@(link_name = NAME_OF_THE_TEST)
	with_a_constant :: proc "c" (value: i64) -> i64 ---
}

@(link_prefix = "module_")
foreign _ {
	after_a_prefix :: proc "c" (value: i64) -> i64 ---
	@(link_name = "own_name")
	with_its_own_name :: proc "c" (value: i64) -> i64 ---
}

@(link_prefix = NAME_OF_THE_TEST)
foreign _ {
	after_a_constant_prefix :: proc "c" (value: i64) -> i64 ---
}

caller_of_the_test :: proc "c" () -> i64 {
	foreign _ {
		in_a_procedure :: proc "c" (value: i64) -> i64 ---
	}
	return in_a_procedure(1)
}
`
	declarations := declarations_of_source(t, source)
	names := [?]string{"plain_name", "text_name", "", "module_after_a_prefix", "own_name", ""}
	if !testing.expect_value(t, len(declarations), len(names)) {
		return
	}
	for name, index in names {
		testing.expect_value(t, declarations[index].link_name, name)
	}
}

// Each symbol that became a slot of the importer has a compared
// declaration. A symbol with none is a call through a declaration that the
// tool did not find (the three forms of the test above): the build stops
// and names it. Two declarations of one symbol pass: each was compared.
@(test)
each_slot_has_one_compared_declaration :: proc(t: ^testing.T) {
	// A symbol has one slot for each place that holds its address.
	slots := [?]string{"seal", "open", "seal", "sum_values"}
	testing.expect_value(t, declared_symbols_problem(slots[:], {"open", "sum_values", "seal"}), "")
	testing.expect_value(t, declared_symbols_problem(nil, nil), "")
	// A declaration of an export that the module never calls has no slot:
	// it was compared, and it is no problem.
	testing.expect_value(t, declared_symbols_problem(slots[:], {"open", "sum_values", "seal", "never_called"}), "")
	missing := declared_symbols_problem(slots[:], {"seal", "sum_values"})
	testing.expect(t, strings.has_prefix(missing, "the import open is called, and the tool found no declaration of it to compare"), missing)
	testing.expect_value(t, declared_symbols_problem(slots[:], {"seal", "open", "sum_values", "sum_values"}), "")
	none := declared_symbols_problem(slots[:], nil)
	testing.expect(t, strings.has_prefix(none, "the import seal is called"), none)
}

// The sources of the repository: each module of the module table that has
// an import declares each export that it names with the call form of the
// description of that export, read from the source of the import. The
// conversion makes the same check against the module files that it binds
// (import_declarations_check); this test needs no build.
@(test)
each_declaration_of_the_repository_agrees_with_its_export :: proc(t: ^testing.T) {
	for build in module_builds {
		if len(build.imports) == 0 {
			continue
		}
		exports := make([dynamic]Importable_Export, context.temp_allocator)
		for name in build.imports {
			for other in module_builds {
				if other.name != name {
					continue
				}
				description, described := describe_package(other.source)
				if !testing.expectf(t, described, "the module %s was not described", name) {
					return
				}
				for export in description.exports {
					append(&exports, Importable_Export{module_name = name, name = export.name, form = call_form_of_description(export, description.records)})
				}
			}
		}
		paths := make([dynamic]string, context.temp_allocator)
		own_files, listed := files_with_suffix(build.source, ".odin")
		if !testing.expectf(t, listed, "the folder %s was not listed", build.source) {
			return
		}
		append(&paths, ..own_files)
		// The declarations of the drawing module are in the window layer of
		// the interface package, for each program with the setting.
		if slice.contains(build.defines, DRAWING_THROUGH_MODULE) {
			append(&paths, "support/interface/window_drawing.odin")
		}
		compared := 0
		for path in paths {
			if strings.has_suffix(path, "_test.odin") {
				continue
			}
			source, read := read_file(path)
			if !testing.expectf(t, read, "%s was not read", path) {
				return
			}
			if !strings.contains(string(source), "foreign") {
				continue
			}
			count, agree := import_declarations_of_file_agree(build.name, path, exports[:])
			testing.expectf(t, agree, "%s: a declaration of %s does not agree with its export", build.name, path)
			compared += count
		}
		testing.expectf(t, compared > 0, "%s has imports and declares no export of them", build.name)
	}
}

// The rules of a program that draws its window through the drawing module
// (support/interface, window_drawing.odin):
//   - it imports the module, which is a library module of the table;
//   - it draws no picture and no grid of text cells: a draw table names
//     them by an address, and the module cannot read them;
//   - it starts no child of its own file with no load source: the loader
//     of the child would not find the import.
@(test)
programs_that_draw_through_the_module_follow_its_rules :: proc(t: ^testing.T) {
	library_found := false
	for build in module_builds {
		if build.name == DRAWING_MODULE {
			library_found = build.library
		}
	}
	testing.expect(t, library_found, "the drawing module is a library module of the table")
	refused_calls := [?]string{"draw_picture(", "draw_text_grid(", "show_picture(", "window_drawing_of_picture(", ".pictures =", ".grids ="}
	programs := 0
	for build in module_builds {
		if !slice.contains(build.defines, DRAWING_THROUGH_MODULE) {
			continue
		}
		programs += 1
		testing.expectf(t, slice.contains(build.imports, DRAWING_MODULE), "%s has the setting and does not import the drawing module", build.name)
		paths, listed := files_with_suffix(build.source, ".odin")
		if !testing.expectf(t, listed, "the folder %s was not listed", build.source) {
			return
		}
		own_file := strings.concatenate({"image_find(image, \"", build.name, "\")"}, context.temp_allocator)
		for path in paths {
			source, read := read_file(path)
			if !testing.expectf(t, read, "%s was not read", path) {
				return
			}
			for call in refused_calls {
				testing.expectf(t, !strings.contains(string(source), call), "%s draws through the module, and %s has %s: the module draws no picture and no grid", build.name, path, call)
			}
			rest := string(source)
			for line in strings.split_lines_iterator(&rest) {
				if strings.contains(line, "program_start(") && strings.contains(line, own_file) {
					testing.expectf(t, strings.contains(line, "image = "), "%s starts a child of its own file with no load source in %s: the child would not find the drawing module", build.name, path)
				}
			}
		}
	}
	testing.expect(t, programs > 0, "no program draws through the module")
}
