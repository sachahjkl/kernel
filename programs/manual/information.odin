package manual

import "contract:errors"
import "contract:isolated"
import "support:graphics"
import "support:information"
import "support:sentence"
import "support:system"

// The manual is also the service of the information of the modules
// (property 12): each export below gives a table of records, from the flat
// tables of the modules of the boot image (support/information). The
// console combines the tables with where, sort, join and columns.
//
// What runs comes from the kernel: the module records of each program,
// with the replacements that the loader applied. The manual reads them with
// its grant, the machine with the right Inspect, and gives them only to a
// caller that acts for the person (property 20).
//
// The window shows the same facts: the key Tab, or overview(), shows the
// table of all the modules; the page of a module has its sizes, the modules
// that import it, and the programs that run it.

KEY_TAB :: 0x0F

machine: system.Handle

// The rows of the window and of the measures: memory of this program.
module_rows: [128]information.Module
export_rows: [512]information.Export
import_rows: [128]information.Import
running_rows: [512]information.Running

catalog :: proc "contextless" () -> information.Catalog {
	return {image = image, replacements = system.replacements_read(replacement_table, &replacement_records)}
}

// table_count gives the count of a Table result: the count of rows, or a
// negative error.
// A failure writes the error record (contract/errors): Absent (-1), the
// module of the argument 1 breaks a rule of the format: Malformed (-2), with
// the kind of the problem and the byte of the file, or the kernel refused a
// report: Refused (-3), with the status.
@(private = "file")
table_count :: proc "contextless" (count: int, problem: information.Problem, error: ^errors.Error_Record) -> i64 {
	#partial switch problem.kind {
	case .None:
		return i64(count)
	case .No_Module:
		return errors.fail(error, -1, .Absent, .Modules, 1)
	case .Refused:
		return errors.fail(error, -3, .Refused, .None, 0, 0, 0, i64(problem.value))
	}
	return errors.fail(error, -2, .Malformed, .None, 1, i64(problem.kind), 0, i64(problem.offset))
}

// modules gives one row for each module of the boot image: its name, its hash, its sizes (code, constants, data, zero), whether it has an entry, its counts of exports, imports and records. A module that breaks a rule of the format has a row too: problem, place, index and offset say where. The result is the count of rows.
@(export, link_name = "modules")
modules :: proc "c" (result: ^[]information.Module) -> i64 {
	return i64(information.modules(catalog(), result^))
}

// exports gives one row for each export of a module, by name or by hash, with its signature and the rights that it asks of its handles. The module "" gives the exports of each module. The result is the count of rows, or a negative number with an error record. The error kinds: Absent (-1, no module has this name); Malformed (-2, the module breaks a rule of the format: problem(name) says where).
@(export, link_name = "exports")
exports :: proc "c" (name: ^string, result: ^[]information.Export, error: ^errors.Error_Record) -> i64 {
	count, problem := information.exports(catalog(), name^, result^)
	return table_count(count, problem, error)
}

// imports gives one row for each import of a module, by name or by hash: the hash and the name of the imported module, its slots, and the module that the replacement table of the machine gives in its place. The module "" gives the imports of each module. The result is the count of rows, or a negative number with an error record. The error kinds: Absent (-1, no module has this name); Malformed (-2, the module breaks a rule of the format).
@(export, link_name = "imports")
imports :: proc "c" (name: ^string, result: ^[]information.Import, error: ^errors.Error_Record) -> i64 {
	count, problem := information.imports(catalog(), name^, result^)
	return table_count(count, problem, error)
}

// importers gives the imports, in each module of the boot image, of a module, by name or by hash: who imports it. An import that a replacement of the machine changes to this module is a row too. The result is the count of rows, or a negative number with an error record. The error kind: Absent (-1, no module has this name).
@(export, link_name = "importers")
importers :: proc "c" (name: ^string, result: ^[]information.Import, error: ^errors.Error_Record) -> i64 {
	found, problem := information.find(catalog(), name^)
	if problem.kind == .No_Module {
		return errors.fail(error, -1, .Absent, .Modules, 1)
	}
	return i64(information.importers(catalog(), found.hash, result^))
}

// exporters gives the exports with a name, in each module of the boot image: which modules export a function with this name. The result is the count of rows.
@(export, link_name = "exporters")
exporters :: proc "c" (name: ^string, result: ^[]information.Export) -> i64 {
	return i64(information.exporters(catalog(), name^, result^))
}

// described gives the exports, in each module of the boot image, whose help or documentation holds a text: which modules export a function that does this. The result is the count of rows.
@(export, link_name = "described")
described :: proc "c" (words: ^string, result: ^[]information.Export) -> i64 {
	return i64(information.described(catalog(), words^, result^))
}

// handles gives the exports, in each module of the boot image, that take a handle with a right: Read, Write, Control, and the other rights of the kernel. The result is the count of rows, or a negative number with an error record. The error kind: Absent (-1, no right has this name).
@(export, link_name = "handles")
handles :: proc "c" (right: ^string, result: ^[]information.Export, error: ^errors.Error_Record) -> i64 {
	for name, which in sentence.right_names {
		if name == right^ {
			return i64(information.handles(catalog(), which, result^))
		}
	}
	return errors.fail(error, -1, .Absent, .None, 1)
}

// slots gives one row for each slot of a module, by name or by hash: the import and the export that the loader writes in it. The result is the count of rows, or a negative number with an error record. The error kinds: Absent (-1, no module has this name); Malformed (-2, the module breaks a rule of the format).
@(export, link_name = "slots")
slots :: proc "c" (name: ^string, result: ^[]information.Slot, error: ^errors.Error_Record) -> i64 {
	count, problem := information.slots(catalog(), name^, result^)
	return table_count(count, problem, error)
}

// segments gives one row for each segment of a module, by name or by hash: its kind, its place in memory and in the file. The result is the count of rows, or a negative number with an error record. The error kinds: Absent (-1, no module has this name); Malformed (-2, the module breaks a rule of the format).
@(export, link_name = "segments")
segments :: proc "c" (name: ^string, result: ^[]information.Segment, error: ^errors.Error_Record) -> i64 {
	count, problem := information.segments(catalog(), name^, result^)
	return table_count(count, problem, error)
}

// running gives one row for each module that runs in a program, from the module records of the kernel: the program, the module, its hash, and the hash that a replacement changed. The result is the count of rows, or a negative number with an error record. The error kinds: No_Grant (-3, the caller does not act for the person); Refused (-3, the kernel refused the report to this program, with its status).
@(export, link_name = "running")
running :: proc "c" (result: ^[]information.Running, error: ^errors.Error_Record) -> i64 {
	if caller := system.service_caller(); caller != nil && caller.grant & isolated.CALLER_PERSON == 0 {
		return errors.fail(error, -3, .No_Grant, .Person)
	}
	count, problem := information.running(machine, catalog(), result^)
	return table_count(count, problem, error)
}

// replacements gives one row for each record of the replacement table of the machine: where an import names the module `from`, a loader gives the module `to`. The result is the count of rows.
@(export, link_name = "replacements")
replacements :: proc "c" (result: ^[]information.Replacement) -> i64 {
	return i64(information.replacements(catalog(), result^))
}

// problem gives the first rule of the format that a module breaks, by name or by hash, as a sentence: the table, the record and the byte of the file. The text is empty when the module keeps each rule.
@(export, link_name = "problem")
problem :: proc "c" (name: ^string, result: ^[]u8) -> i64 {
	found, problem := information.find(catalog(), name^)
	if problem.kind == .None {
		return 0
	}
	buffer: [256]u8
	writer := system.Writer {
		buffer = buffer[:],
	}
	information.problem_write(&writer, found.name != "" ? found.name : name^, problem)
	return text_result(system.written(&writer), result)
}

// overview shows in the window the table of all the modules of the boot image: their sizes, their counts of exports and imports, who imports each one, and the programs that run it. The result is the count of modules.
@(export, link_name = "overview")
overview :: proc "c" () -> i64 {
	return i64(overview_build())
}

// importer_count gives the count of modules that import a module, through
// the replacements of the machine too.
@(private = "file")
importer_count :: proc "contextless" (hash: [32]u8) -> int {
	return information.importers(catalog(), hash, nil)
}

// running_count gives the count of programs that run a module, from the
// rows of running().
@(private = "file")
running_count :: proc "contextless" (hash: string, count: int) -> (programs: int) {
	for &row in running_rows[:min(count, len(running_rows))] {
		programs += int(string(row.hash[:]) == hash)
	}
	return programs
}

// overview_build writes the page of the table of all the modules, and
// writes on the log what it shows.
overview_build :: proc "contextless" () -> int {
	line_count, built_count, first_line = 0, 0, 0
	showing_overview = true
	count := min(information.modules(catalog(), module_rows[:]), len(module_rows))
	run_count, _ := information.running(machine, catalog(), running_rows[:])
	put_built(0, COLOR_TITLE, "ALL MODULES (", u64(count), ")")
	put("The flat tables of each module of the boot image, read by support/information.", 0, COLOR_DIM)
	put("Sizes in bytes of memory. Tab: this table; up, down: the page of a module.", 0, COLOR_DIM)
	put("", 0, 0)
	put("name             code   const    data    zero  exports imports  by  runs", 0, COLOR_HEADING)
	totals: [4]i64
	export_total, import_total, run_total := 0, 0, 0
	for &row in module_rows[:count] {
		name := system.name_of(row.name[:])
		hash, _ := information.hash_parse(string(row.hash[:]))
		by := importer_count(hash)
		runs := running_count(string(row.hash[:]), run_count)
		color := graphics.Color(COLOR_TEXT)
		switch {
		case row.problem[0] != 0:
			color = 0xF07070
		case runs > 0:
			color = COLOR_EXPORT
		case row.entry == 0:
			color = COLOR_TITLE
		}
		put_built(0, color, padded(name, 15), right(row.code, 6), right(row.constants, 8), right(row.data, 8), right(row.zero, 8), right(row.exports, 9), right(row.imports, 8), right(i64(by), 4), right(i64(runs), 6))
		totals += {row.code, row.constants, row.data, row.zero}
		export_total += int(row.exports)
		import_total += int(row.imports)
		run_total += runs
	}
	put("", 0, 0)
	put_built(0, COLOR_DIM, padded("all", 15), right(totals[0], 6), right(totals[1], 8), right(totals[2], 8), right(totals[3], 8), right(i64(export_total), 9), right(i64(import_total), 8), "     ", right(i64(run_total), 6))
	put("", 0, 0)
	put("green: a program runs it. yellow: no entry, a library. red: it breaks a rule.", 0, COLOR_DIM)
	system.log("manual: overview: ", u64(count), " modules, ", u64(export_total), " exports, ", u64(import_total), " imports, ", u64(run_count), " modules that run in programs")
	return count
}

showing_overview: bool

// padded gives a text and spaces after it, in the built lines.
@(private = "file")
padded :: proc "contextless" (text: string, width: int) -> string {
	writer := system.Writer {
		buffer = built[built_count:],
	}
	system.write_part(&writer, text[:min(len(text), width)])
	for writer.count < width + 1 {
		system.write_part(&writer, " ")
	}
	built_count += writer.count
	return system.written(&writer)
}

// right gives a number with spaces before it, in a field of `width`
// characters, in the built lines.
@(private = "file")
right :: proc "contextless" (value: i64, width: int) -> string {
	digits: [24]u8
	text := system.format(digits[:], value)
	writer := system.Writer {
		buffer = built[built_count:],
	}
	for _ in len(text) ..< width {
		system.write_part(&writer, " ")
	}
	system.write_part(&writer, text)
	built_count += writer.count
	return system.written(&writer)
}

// information_page writes the facts of one module that the information
// functions give: its sizes, who imports it, and the programs that run it.
information_page :: proc "contextless" (hash: [32]u8) {
	showing_overview = false
	found, problem := information.find(catalog(), hex_of(hash))
	if problem.kind != .None {
		writer := system.Writer {
			buffer = built[built_count:],
		}
		information.problem_write(&writer, found.name, problem)
		built_count += writer.count
		put("PROBLEM", 0, COLOR_HEADING)
		put_paragraph(system.written(&writer), 0, 0xF07070)
		put("", 0, 0)
		return
	}
	row: information.Module
	information.module_row(found, &row)
	put("SIZES", 0, COLOR_HEADING)
	put_built(2, COLOR_TEXT, "code ", u64(row.code), ", constants ", u64(row.constants), ", data ", u64(row.data), ", zero data ", u64(row.zero), " bytes")
	put("", 0, 0)
	count := min(information.importers(catalog(), hash, import_rows[:]), len(import_rows))
	put_built(0, COLOR_HEADING, "IMPORTED BY (", u64(count), ")")
	for &item in import_rows[:count] {
		replacement := system.name_of(item.replacement[:])
		module_name := system.name_of(item.module[:])
		if replacement != "" {
			put_built(2, COLOR_CODE, module_name, ", import ", u64(item.number), ", slots ", u64(item.slots), ", through the replacement of ", system.name_of(item.name[:]))
		} else {
			put_built(2, COLOR_CODE, module_name, ", import ", u64(item.number), ", slots ", u64(item.slots))
		}
	}
	put("", 0, 0)
	run_count, _ := information.running(machine, catalog(), running_rows[:])
	text := hex_of(hash)
	programs := running_count(text, run_count)
	put_built(0, COLOR_HEADING, "PROGRAMS THAT RUN IT (", u64(programs), ")")
	for &item in running_rows[:min(run_count, len(running_rows))] {
		if string(item.hash[:]) != text {
			continue
		}
		program := system.name_of(item.program[:])
		if item.replaces[0] != 0 {
			replaced, _ := information.hash_parse(string(item.replaces[:]))
			put_built(2, COLOR_EXPORT, program, " (slot ", u64(item.slot), ") at ", system.Hex(u64(item.base)), ", in place of ", module_text(replaced))
		} else {
			put_built(2, COLOR_EXPORT, program, " (slot ", u64(item.slot), ") at ", system.Hex(u64(item.base)))
		}
	}
	put("", 0, 0)
}

// hex_of gives a hash in hexadecimal, in the built lines.
@(private = "file")
hex_of :: proc "contextless" (hash: [32]u8) -> string {
	text: [64]u8
	information.hash_text(hash, &text)
	start := built_count
	built_count += copy(built[built_count:], text[:])
	return string(built[start:built_count])
}

// information_start keeps the machine handle and measures the functions:
// the time to list all the modules and all their exports, and the time of
// one reverse question. A measure repeats the work for 50 ms or more, so
// that the clock of 1 ms gives microseconds.
information_start :: proc "contextless" (ctx: ^system.Context) {
	machine = ctx.handles[system.GRANT_MACHINE]
	modules_count, exports_count, rounds := 0, 0, 0
	start := system.time()
	for rounds < 10 || system.time() - start < 50 {
		modules_count = information.modules(catalog(), module_rows[:])
		exports_count, _ = information.exports(catalog(), "", export_rows[:])
		rounds += 1
	}
	list_time := (system.time() - start) * 1000 / u64(rounds)
	question, _ := information.find(catalog(), "calendar")
	importer_total, question_rounds := 0, 0
	start = system.time()
	for question_rounds < 10 || system.time() - start < 50 {
		importer_total = information.importers(catalog(), question.hash, import_rows[:])
		question_rounds += 1
	}
	question_time := (system.time() - start) * 1000 / u64(question_rounds)
	problems := 0
	for &row in module_rows[:min(modules_count, len(module_rows))] {
		problems += int(row.problem[0] != 0)
	}
	system.log("manual: information: ", u64(modules_count), " modules and ", u64(exports_count), " exports listed in ", list_time, " us; who imports calendar: ", u64(importer_total), " modules, in ", question_time, " us; ", u64(problems), " modules break a rule")
}