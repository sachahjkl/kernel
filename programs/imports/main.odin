// A demonstration of the loader: a module with imports, and the replacement
// of an import (docs/MODULE_CONTRACT.md, "Replacement of an import").
//
// The module agenda imports the module calendar. calendar has a fault: the
// year 2000 has 365 days. calendar_fixed has the correction and the same
// description; calendar_changed has another description. This program loads
// agenda in its own memory with the loader of the system, with no
// replacement and with each replacement, and shows what the loader answers.
// It also imports calendar itself: the root service gave it the
// replacements of the machine when it started it.
package imports

import "base:intrinsics"
import "support:display"
import "support:graphics"
import "support:interface"
import module "contract:module"
import op "contract:operation"
import "support:system"

// The window is built with the interface package (docs/INTERFACE.md).
records_now, records_before: [512]interface.Draw_Record
text_now, text_before: [8192]u8
drawing: interface.Window_Drawing

foreign _ {
	days_in_month :: proc "c" (month, year: i64) -> i64 ---
}

LINE :: 22
ANSWER_X :: 440
WIDTH :: 760
CASE_CAPACITY :: 12
HEIGHT :: 12 + 4 * LINE + CASE_CAPACITY * LINE + 4 * LINE + 12

COLOR_WRONG :: 0xE0B040

// One case: what the program asked the loader, and the answer.
Case :: struct {
	text:   string,
	answer: string,
	right:  bool,
}

cases: [CASE_CAPACITY]Case
case_count: int
texts: [2048]u8
text_count: int

note :: proc "contextless" (text: string, right: bool, answer: ..system.Part) {
	written := system.format(texts[text_count:], ..answer)
	text_count += len(written)
	cases[case_count] = {text, written, right}
	case_count += 1
}

image: []u8
machine: system.Handle
boot: op.Boot_Report

hash_of :: proc "contextless" (name: string) -> [32]u8 {
	for &entry in system.image_entries(image) {
		if system.name_of(entry.name[:]) == name {
			return entry.hash
		}
	}
	return {}
}

// Each space has its own addresses: the same module can be in two of them.
SPACE_DISTANCE :: 0x0000_0001_0000_0000

space_of :: proc "contextless" (number: u64, replacements: []module.Replacement) -> system.Module_Space {
	return {source = {image = image, replacements = replacements}, next = op.MODULE_BASE + number * SPACE_DISTANCE}
}

used :: proc "contextless" (space: ^system.Module_Space) -> (count: int) {
	for &item in space.modules {
		count += item.users != 0 ? 1 : 0
	}
	return count
}

export :: proc "contextless" (space: ^system.Module_Space, place: int, name: string) -> uintptr {
	item := &space.modules[place]
	address, _ := module.export_address(item.file, uintptr(item.base), module.export_find(item.file, name))
	return address
}

year_days :: proc "contextless" (space: ^system.Module_Space, place: int, year: i64) -> i64 {
	call := cast(proc "c" (year: i64) -> i64)rawptr(export(space, place, "year_days"))
	return call(year)
}

CALLS :: 1_000_000
BINDS :: 1000
MEASURE_RUNS :: 5

// The measures, in cycles of the processor.
call_direct, call_replaced: u64 // For CALLS calls.
load_direct, load_replaced: u64 // One load of agenda and its import.
bind_direct, bind_replaced: u64 // For BINDS binds of agenda.

// tenths gives a number of cycles as tenths of nanoseconds, for count times.
tenths :: proc "contextless" (cycles: u64, count: u64) -> (whole, tenth: u64) {
	per_microsecond := max(boot.cycle_frequency / 1_000_000, 1)
	value := cycles * 10_000 / per_microsecond / count
	return value / 10, value % 10
}

measure_calls :: proc "contextless" (space: ^system.Module_Space, place: int) -> u64 {
	call := cast(proc "c" (count: i64) -> i64)rawptr(export(space, place, "calls"))
	call(1000) // The code and the data in the cache.
	start := system.cycles()
	total := call(CALLS)
	cycles := system.cycles() - start
	intrinsics.volatile_store(&sink, total)
	return cycles
}
sink: i64

VALUE_CHILD :: 8 // Not 0: this program waits, so that its code stays mapped.
shared_pages, shared_mappings: u64

// code_segments gives the count of segments of a module that the loader
// never writes: the part Code of the table of prepared modules.
code_segments :: proc "contextless" (file: []u8) -> (count: u64) {
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		count += .Write not_in segment.flags ? 1 : 0
	}
	return count
}

// measure_binds binds agenda again, in memory of this program, BINDS times:
// the cost of the bind with the import that the space gave.
measure_binds :: proc "contextless" (space: ^system.Module_Space, place: int) -> u64 {
	item := &space.modules[place]
	head, _ := module.header(item.file)
	memory_object, status := system.memory_create(head.memory_size / system.PAGE_SIZE)
	if status != .Ok {
		return 0
	}
	defer system.close(memory_object)
	address, _ := system.memory_map(memory_object)
	defer system.memory_unmap(address)
	memory := ([^]u8)(address)[:head.memory_size]
	module.copy_segments(item.file, memory)
	imports: [system.IMPORT_CAPACITY]module.Bound_Import
	for number in 0 ..< int(item.import_count) {
		record, _ := module.record(item.file, .Imports, u32(number + 1), module.Import)
		bound := &space.modules[item.import_places[number]]
		imports[number] = {file = bound.file, base = uintptr(bound.base)}
		if bound.hash != record.hash {
			imports[number].named = bound.original
		}
	}
	error: module.Load_Error
	start := system.cycles()
	for _ in 0 ..< BINDS {
		module.bind(item.file, memory, imports[:item.import_count], &error)
	}
	return system.cycles() - start
}

// own_replaced says if the loader of this program gave it a module in place
// of an import: the module records that the kernel keeps for it.
own_replaced :: proc "contextless" () -> (replaced: bool, found: bool) {
	report: op.System_Report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
	for slot in 1 ..< report.program_slots {
		program: op.Program_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program), slot, u64(uintptr(&program)), size_of(program))
		if system.name_of(program.name[:]) != "imports" || program.state == .None || program.state == .Stopped {
			continue
		}
		modules := &module_report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Modules), slot, u64(uintptr(modules)), size_of(modules^))
		for item in modules.modules[:modules.count] {
			replaced ||= item.replaces != {}
		}
		return replaced, true
	}
	return false, false
}
module_report: op.Module_Report

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	// A program that this program started to share calendar: it waits.
	if ctx.values[VALUE_CHILD] != 0 {
		for {
			system.sleep(max(u64))
		}
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, "imports")
	if !ok {
		system.stop(1)
	}
	machine = ctx.handles[system.GRANT_MACHINE]
	if address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {}); status == .Ok {
		image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	}
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Boot), 0, u64(uintptr(&boot)), size_of(boot))
	agenda := system.image_find(image, "agenda")
	fixed := []module.Replacement{{from = hash_of("calendar"), to = hash_of("calendar_fixed")}}
	changed := []module.Replacement{{from = hash_of("calendar"), to = hash_of("calendar_changed")}}
	cycle := []module.Replacement{{from = hash_of("calendar"), to = hash_of("agenda")}}

	// 1. No replacement: the fault of calendar is visible.
	error: module.Load_Error
	direct := space_of(1, nil)
	start := system.cycles()
	place, loaded := system.module_space_load(&direct, agenda, &error)
	load_direct = system.cycles() - start
	days := loaded ? year_days(&direct, place, 2000) : 0
	note("agenda, with calendar: year_days(2000)", loaded && error.stage == .None && days == 365, days, ": the fault of calendar")

	// 2. calendar_fixed in place of calendar: the same file of agenda.
	replaced := space_of(2, fixed)
	start = system.cycles()
	fixed_place, fixed_ok := system.module_space_load(&replaced, agenda, &error)
	load_replaced = system.cycles() - start
	days = fixed_ok ? year_days(&replaced, fixed_place, 2000) : 0
	same := fixed_ok && loaded && replaced.modules[fixed_place].hash == direct.modules[place].hash
	note("calendar_fixed in place of calendar: year_days(2000)", fixed_ok && days == 366 && same, days, ", the same hash of agenda")
	note("the module record of the replacement", fixed_ok && replaced.modules[replaced.modules[fixed_place].import_places[0]].replaces == hash_of("calendar"), "calendar_fixed in place of calendar")

	if loaded && fixed_ok {
		// The two paths in turn, five times: the least time of each one.
		call_direct, call_replaced, bind_direct, bind_replaced = max(u64), max(u64), max(u64), max(u64)
		for _ in 0 ..< MEASURE_RUNS {
			call_direct = min(call_direct, measure_calls(&direct, place))
			call_replaced = min(call_replaced, measure_calls(&replaced, fixed_place))
			bind_direct = min(bind_direct, measure_binds(&direct, place))
			bind_replaced = min(bind_replaced, measure_binds(&replaced, fixed_place))
		}
		system.module_space_release(&direct, place, &error)
		system.module_space_release(&replaced, fixed_place, &error)
	}
	note("unload agenda: its import leaves too", used(&direct) == 0 && used(&replaced) == 0 && error.stage == .None, "0 modules in each space")

	// 3. A replacement with another description: the record names the
	// modules, the export and the two descriptions.
	refused := space_of(3, changed)
	system.module_space_load(&refused, agenda, &error)
	note("calendar_changed in place of calendar",
		error.stage == .Check && error.difference == .Parameter_Count && error.expected.detail == 2 && error.found.detail == 3 &&
		module.name_get(&error.export) == "days_in_month" && error.module.hash == hash_of("agenda") && error.imported.hash == hash_of("calendar") &&
		error.replacement.hash == hash_of("calendar_changed") && used(&refused) == 0,
		"refused: 3 parameters, not 2")
	// The check of two descriptions with another type: the record has both.
	math := system.image_find(image, "math")
	difference, parameter, expected, given := module.functions_compare(math, module.export_find(math, "number"), math, module.export_find(math, "fibonacci"))
	note("the check of number against fibonacci (math)", difference == .Parameter_Type && parameter == 1 && expected.type == .Text && given.type == .Integer, "parameter 1: Integer, not Text")

	// 4. An import that is not in what the program was granted.
	lonely := space_of(4, nil)
	system.module_space_load(&lonely, system.image_find(image, "lonely"), &error)
	note("lonely: its import is not in the boot image", error.stage == .Find && error.module.hash == hash_of("lonely") && error.imported.hash != {} && system.image_entry_of(image, error.imported.hash) == nil && used(&lonely) == 0, "refused: missing import")

	// 5. A replacement that makes a cycle.
	cycled := space_of(5, cycle)
	system.module_space_load(&cycled, agenda, &error)
	note("agenda in place of calendar", error.stage == .Cycle && error.imported.hash == hash_of("calendar") && error.replacement.hash == hash_of("agenda") && used(&cycled) == 0, "refused: an import cycle")

	// 6. Each module one time: agenda, then calendar, share one calendar.
	shared := space_of(6, nil)
	first, first_ok := system.module_space_load(&shared, agenda, &error)
	second, second_ok := system.module_space_load(&shared, system.image_find(image, "calendar"), &error)
	note("load agenda, then load calendar", first_ok && second_ok && used(&shared) == 2 && shared.modules[second].users == 2, "2 modules, not 3")
	if first_ok && second_ok {
		system.module_space_release(&shared, first, &error)
		left := used(&shared)
		system.module_space_release(&shared, second, &error)
		note("unload agenda, then calendar", left == 1 && used(&shared) == 0, "1 module stays, then 0")
	}

	// 7. Two programs that import calendar, at two places: this program,
	// started again, and agenda. With one table of prepared modules, the
	// code of calendar is one memory object that the two map.
	{
		table: system.Prepared_Modules
		values: [op.CONTEXT_VALUES]u64
		values[VALUE_CHILD] = 1
		amounts := system.Budget_Amounts{pages = 256, programs = 1, threads = 1, processor = 10_000, log_records = 10}
		own := system.image_find(image, "imports")
		first_program, first_status := system.program_start(own, "imports child", {}, values, amounts, nil, &table, {image = image}, &error)
		second_program, second_status := system.program_start(agenda, "agenda", {}, {}, amounts, nil, &table, {image = image}, &error)
		copies, mappings, pages: u64
		for &item in table.modules {
			if item.memory != 0 && item.hash == hash_of("calendar") && item.part == .Code {
				copies += 1
				mappings = system.handle_holdings(item.memory)
				pages = item.pages
			}
		}
		// The place of calendar: after the module of the program.
		own_head, _ := module.header(own)
		agenda_head, _ := module.header(agenda)
		segments := code_segments(system.image_find(image, "calendar"))
		note("two programs import calendar at two places", first_status == .Ok && second_status == .Ok && copies == 1 && mappings == 2 * segments && own_head.memory_size != agenda_head.memory_size, copies, " copy of its code, ", pages, " pages, ", mappings, " mappings")
		shared_pages, shared_mappings = pages, mappings
		system.close(first_program)
		system.close(second_program)
		for item in table.modules {
			if item.memory != 0 {
				system.close(item.memory)
			}
		}
	}

	// 8. This program: the root service loaded calendar for its import, or
	// the module of the replacement of the machine.
	own_days := days_in_month(2, 2000)
	own, found := own_replaced()
	note("this program: days_in_month(2, 2000)", found && own_days == (own ? 29 : 28), own_days, own ? ": the root service gave calendar_fixed" : ": calendar, no replacement")

	wrong: u64
	for item in cases[:case_count] {
		if !item.right {
			wrong += 1
			system.log("imports: wrong answer: ", item.text, ": ", item.answer)
		}
	}
	if wrong == 0 {
		system.log("imports: ok, ", u64(case_count), " cases")
	}
	call_whole, call_tenth := tenths(call_direct, CALLS)
	replaced_whole, replaced_tenth := tenths(call_replaced, CALLS)
	system.log("imports: a call through an import slot: ", call_whole, ".", call_tenth, " ns to calendar, ", replaced_whole, ".", replaced_tenth, " ns to calendar_fixed in its place, the least of ", u64(MEASURE_RUNS), " runs of ", u64(CALLS), " calls")
	bind_whole, bind_tenth := tenths(bind_direct, BINDS)
	checked_whole, checked_tenth := tenths(bind_replaced, BINDS)
	load_whole, _ := tenths(load_direct, 1)
	load_replaced_whole, _ := tenths(load_replaced, 1)
	system.log("imports: the bind of agenda: ", bind_whole, ".", bind_tenth, " ns, and ", checked_whole, ".", checked_tenth, " ns with the check of the replacement; the load of agenda and its import: ", load_whole / 1000, " us, and ", load_replaced_whole / 1000, " us")
	system.log("imports: two programs import calendar at two places: one copy of its code, ", shared_pages, " pages, mapped ", shared_mappings, " times")

	for {
		if drawing.now.records == nil {
			drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
		}
		frame := interface.window_frame_begin(&drawing, &window)
		table := frame.table
		interface.draw_rectangle(table, 0, 0, WIDTH, HEIGHT, graphics.COLOR_BACKGROUND)
		y := 12
		interface.draw_text(table, 12, y, "agenda imports calendar. calendar has a fault; calendar_fixed corrects it.", graphics.COLOR_DIM)
		y += LINE
		interface.draw_text(table, 12, y, "the loader gives a replacement only if each export that agenda uses is the same.", graphics.COLOR_DIM)
		y += LINE + LINE / 2
		interface.draw_text(table, 12, y, "the program asks the loader", graphics.COLOR_DIM)
		interface.draw_text(table, ANSWER_X, y, "the answer", graphics.COLOR_DIM)
		y += LINE
		for item, index in cases[:case_count] {
			if index % 2 == 0 {
				interface.draw_rectangle(table, 6, y - 3, WIDTH - 12, LINE, graphics.COLOR_CARD_TOP)
			}
			interface.draw_text(table, 12, y, item.text, graphics.COLOR_TEXT)
			interface.draw_text(table, ANSWER_X, y, item.answer, item.right ? graphics.COLOR_PROGRAM : COLOR_WRONG)
			y += LINE
		}
		y += LINE / 2
		line: [112]u8
		interface.draw_text(table, 12, y, system.format(line[:], "a call through the slot: ", call_whole, ".", call_tenth, " ns to calendar, ", replaced_whole, ".", replaced_tenth, " ns to calendar_fixed"), graphics.COLOR_DIM)
		y += LINE
		interface.draw_text(table, 12, y, system.format(line[:], "the bind of agenda: ", bind_whole, ".", bind_tenth, " ns; with the check of the replacement: ", checked_whole, ".", checked_tenth, " ns"), graphics.COLOR_DIM)
		y += LINE
		interface.draw_text(table, 12, y, system.format(line[:], "the load of agenda and calendar: ", load_whole / 1000, " us; with the replacement: ", load_replaced_whole / 1000, " us"), graphics.COLOR_DIM)
		interface.window_frame_end(&drawing, &frame, &window)
		display.wait(&window)
		for _ in display.next_event(&window) {
		}
	}
}
