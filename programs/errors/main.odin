// A program that shows the errors of the system: one case for each kind of error. Each case makes the error for real, and shows the sentence of the error record that the system gave (docs/MODULE_CONTRACT.md, section 8).
//
// The cases: kernel operations that the kernel refuses (a right, a handle that was revoked or closed, a budget that cannot pay, an address, a size, a flag); loads that fail (a missing import, a replacement that fails its check); a direct call of a module export that fails; isolated calls of the storage service that fail; and a program that faults three calls deep, with its stack trace.
//
// The program runs each case at its start. A key from a to y, or a click on a case, runs it again.
package errors_program

import "contract:errors"
import "contract:isolated"
import module "contract:module"
import op "contract:operation"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:storage"
import "support:terminal"
import "contract:ring"
import "support:random"
import "support:system"
import "base:intrinsics"

// The window is built with the interface package (docs/INTERFACE.md).
records_now, records_before: [1024]interface.Draw_Record
text_now, text_before: [16384]u8
drawing: interface.Window_Drawing

WIDTH :: 1000
LINE :: 16
TOP :: 8 + 2 * LINE + 8 // The first case.
CASE_HEIGHT :: 2 * LINE
CASE_CAPACITY :: 25
CASES_ON_A_PAGE :: 19 // The window shows one page of cases; Tab shows the other one.
PAGE_COUNT :: (CASE_CAPACITY + CASES_ON_A_PAGE - 1) / CASES_ON_A_PAGE
// One case can have a sentence of two lines (a load error that names an
// export and its difference): the window has one line for it.
HEIGHT :: TOP + CASES_ON_A_PAGE * CASE_HEIGHT + LINE + 8 + LINE + 8
SENTENCE_CAPACITY :: 240
SHOWN :: (WIDTH - 40) / 8 // The characters of a line of the window.

// The colors of docs/DESIGN.md: a name is dim, a value (the sentence of a
// record, the expected kind, the answer) is in the text color, a wrong
// answer is in the color "failed". The colors are the table of
// support/graphics (rules.odin).

// One case: what the program does, the error kind that it expects, and the
// sentence of the error record that the system gave.
Case :: struct {
	text:     string,
	expected: string,
	sentence: [SENTENCE_CAPACITY]u8,
	count:    int,
	right:    bool,
}

cases := [CASE_CAPACITY]Case {
	{text = "map the boot image to write", expected = "Handle_Rights"},
	{text = "use a copy after its revocation", expected = "Handle_Ended"},
	{text = "use a handle after its close", expected = "Handle_Ended"},
	{text = "a budget where a memory goes", expected = "Handle_Kind"},
	{text = "a number that names no handle", expected = "Handle_Absent"},
	{text = "64 pages from a budget of 8", expected = "Budget"},
	{text = "log a text in the kernel half", expected = "Bad_Address"},
	{text = "a program name of 40 bytes", expected = "Too_Long"},
	{text = "memory with an unknown flag", expected = "Bad_Flags"},
	{text = "the kernel operation 99", expected = "Unknown_Operation"},
	{text = "load lonely: its import is absent", expected = "load: Find"},
	{text = "load agenda, calendar_changed", expected = "load: Check"},
	{text = "direct call: square_root(-4)", expected = "Too_Small"},
	{text = "storage.write(\"\", \"x\")", expected = "Empty"},
	{text = "storage.write: a name of 40 bytes", expected = "Too_Long"},
	{text = "storage.write: a zero byte", expected = "Bad_Byte"},
	{text = "storage.write over the limit", expected = "Over_Limit"},
	{text = "storage.size(\"nothing\")", expected = "Absent"},
	{text = "a fault three calls deep", expected = "stack trace"},
	// The second page.
	{text = "the pages of another program (Inspect, Pages)", expected = "Bad_Value"},
	{text = "the pages past the end of the user half", expected = "Bad_Value"},
	// One case for each family of calls that gave a status or a bool only
	// (MODULE_CONTRACT.md, section 8, "The other calls").
	{text = "a wrapper: display.open of 0 by 100 pixels", expected = "Bad_Value"},
	{text = "a wrapper: terminal.open with no terminal", expected = "No_Grant"},
	{text = "a ring: root.Connect(\"storage\"), not callable", expected = "No_Grant"},
	{text = "an export: tally.add, a note of 40 bytes", expected = "Too_Long"},
}

shown_page: int // The page of cases that the window shows.
machine: system.Handle

image: []u8
image_memory: system.Handle
client: storage.Client
connected: bool
ctx_log: system.Handle

// The measures, in nanoseconds for one call.
kernel_good, kernel_failed, direct_good, direct_failed: u64

// The kernel cases use the wrappers of support/system with their last
// parameter `error`: the record is a value of the call, in memory of this
// program. An operation with no wrapper that gives a status uses
// system.call_with_error.

// kernel_text writes the sentence of a record and says if the call failed
// with the expected kind.
kernel_text :: proc "contextless" (writer: ^system.Writer, record: ^errors.Error_Record, status: system.Status, expected: errors.Kind) -> bool {
	system.kernel_error_text(writer, record)
	return status != .Ok && errors.Kind(record.kind) == expected
}

// The pages of another program: Inspect_Kind.Pages answers for the program
// that asks only (a side channel otherwise): the slot 1, the root service,
// is refused with the argument index.
case_pages_of_another_program :: proc "contextless" (writer: ^system.Writer) -> bool {
	record: errors.Error_Record
	report: op.Page_Report
	_, status := system.call_with_error(&record, .Inspect, u64(machine), u64(op.Inspect_Kind.Pages), 1, u64(uintptr(&report)), size_of(report))
	right := kernel_text(writer, &record, status, .Bad_Value)
	return right && status == .Bad_Operation && record.argument == 3 && record.value == 1
}

// The pages past the end of the user half: the 64 pages from the first page
// of the report must be addresses of programs.
case_pages_past_the_user_half :: proc "contextless" (writer: ^system.Writer) -> bool {
	record: errors.Error_Record
	report := op.Page_Report{address = op.USER_END - system.PAGE_SIZE}
	_, status := system.call_with_error(&record, .Inspect, u64(machine), u64(op.Inspect_Kind.Pages), 0, u64(uintptr(&report)), size_of(report))
	right := kernel_text(writer, &record, status, .Bad_Value)
	return right && status == .Bad_Operation && record.argument == 4 && u64(record.value) == op.USER_END - system.PAGE_SIZE
}

case_rights :: proc "contextless" (writer: ^system.Writer) -> bool {
	record: errors.Error_Record
	address, status := system.memory_map(image_memory, {.Write}, error = &record)
	right := kernel_text(writer, &record, status, .Handle_Rights)
	return right && address == nil && .Write in transmute(op.Rights)u32(record.limit) && .Write not_in transmute(op.Rights)u32(record.found)
}

// size_case asks the size of a memory object of a handle that must fail.
size_case :: proc "contextless" (writer: ^system.Writer, handle: system.Handle, expected: errors.Kind) -> (record: errors.Error_Record, right: bool) {
	pages := system.memory_size(handle, &record)
	system.kernel_error_text(writer, &record)
	return record, pages == 0 && errors.Kind(record.kind) == expected
}

case_revoked :: proc "contextless" (writer: ^system.Writer) -> bool {
	memory, _ := system.memory_create(1)
	defer system.close(memory)
	copy, _ := system.give(0, memory, {.Read})
	system.handle_revoke(memory)
	record, right := size_case(writer, copy, .Handle_Ended)
	return right && errors.End(record.found) == .Revoked
}

case_closed :: proc "contextless" (writer: ^system.Writer) -> bool {
	memory, _ := system.memory_create(1)
	system.close(memory)
	record, right := size_case(writer, memory, .Handle_Ended)
	return right && errors.End(record.found) == .Closed
}

case_kind :: proc "contextless" (writer: ^system.Writer) -> bool {
	record, right := size_case(writer, system.own_budget(), .Handle_Kind)
	return right && op.Object_Kind(record.found) == .Budget && op.Object_Kind(record.limit) == .Memory
}

case_absent :: proc "contextless" (writer: ^system.Writer) -> bool {
	_, right := size_case(writer, 0x7F, .Handle_Absent)
	return right
}

case_budget :: proc "contextless" (writer: ^system.Writer) -> bool {
	budget, created := system.budget_create({pages = 8})
	if created != .Ok {
		return false
	}
	defer system.close(budget)
	record: errors.Error_Record
	memory, status := system.memory_create(64, budget, {}, &record)
	right := kernel_text(writer, &record, status, .Budget)
	return right && memory == 0 && errors.Unit(record.unit) == .Pages && record.limit == 65 && record.found == 8
}

case_address :: proc "contextless" (writer: ^system.Writer) -> bool {
	record: errors.Error_Record
	_, status := system.call_with_error(&record, .Log, u64(ctx_log), 0xFFFF_8000_0000_0000, 10, 0, 0, 0)
	return kernel_text(writer, &record, status, .Bad_Address) && record.argument == 2
}

case_name :: proc "contextless" (writer: ^system.Writer) -> bool {
	name := "a name of forty bytes, nine more than 31"
	record: errors.Error_Record
	_, status := system.call_with_error(&record, .Program_Create, u64(system.own_budget()), u64(uintptr(raw_data(name))), u64(len(name)))
	return kernel_text(writer, &record, status, .Too_Long) && record.value == 40 && record.limit == 31
}

case_flags :: proc "contextless" (writer: ^system.Writer) -> bool {
	record: errors.Error_Record
	memory, status := system.memory_create(1, 0, transmute(op.Memory_Flags)u64(0x100) /* A bit that no flag has: 0x4 became Uncommitted. */, &record)
	return kernel_text(writer, &record, status, .Bad_Flags) && memory == 0
}

case_operation :: proc "contextless" (writer: ^system.Writer) -> bool {
	record: errors.Error_Record
	_, status := system.call_with_error(&record, op.Operation(99))
	return kernel_text(writer, &record, status, .Unknown_Operation)
}

// load_case loads a module of the boot image, with replacements, and must
// fail at a stage. It writes the lines of the load error as one sentence.
load_case :: proc "contextless" (writer: ^system.Writer, name: string, replacements: []module.Replacement, stage: module.Load_Stage) -> bool {
	space := system.Module_Space{source = {image = image, replacements = replacements}, next = op.MODULE_BASE}
	error: module.Load_Error
	_, loaded := system.module_space_load(&space, system.image_find(image, name), &error)
	buffer: [SENTENCE_CAPACITY]u8
	lines := system.Writer{buffer = buffer[:]}
	system.load_error_text(&lines, &error)
	text := system.written(&lines)
	system.write_part(writer, "load ")
	system.write_part(writer, name)
	system.write_part(writer, ": ")
	for index in 0 ..< len(text) {
		if text[index] == '\n' {
			system.write_part(writer, index == len(text) - 1 ? "" : "; ")
		} else {
			system.write_part(writer, text[index:index + 1])
		}
	}
	return !loaded && error.stage == stage
}

hash_of :: proc "contextless" (name: string) -> [32]u8 {
	for &entry in system.image_entries(image) {
		if system.name_of(entry.name[:]) == name {
			return entry.hash
		}
	}
	return {}
}

case_missing :: proc "contextless" (writer: ^system.Writer) -> bool {
	return load_case(writer, "lonely", nil, .Find)
}

case_replacement :: proc "contextless" (writer: ^system.Writer) -> bool {
	changed := []module.Replacement{{from = hash_of("calendar"), to = hash_of("calendar_changed")}}
	return load_case(writer, "agenda", changed, .Check)
}

// The module math, loaded in this program: a direct call of its export
// square_root, with the address of an error record.
math_space: system.Module_Space
square_root: proc "c" (value: i64, error: ^errors.Error_Record) -> i64
square_root_export: u32
math_place: int

math_load :: proc "contextless" () -> bool {
	math_space = {source = {image = image}, next = op.MODULE_BASE + 0x1_0000_0000}
	error: module.Load_Error
	place, loaded := system.module_space_load(&math_space, system.image_find(image, "math"), &error)
	if !loaded {
		return false
	}
	math_place = place
	item := &math_space.modules[place]
	square_root_export = module.export_find(item.file, "square_root")
	address, found := module.export_address(item.file, uintptr(item.base), square_root_export)
	function, described := module.function(item.file, square_root_export)
	if !found || !described || function.error_record == 0 {
		return false
	}
	square_root = cast(proc "c" (value: i64, error: ^errors.Error_Record) -> i64)rawptr(address)
	return true
}

// tally, loaded as a library: its export add, called directly.
tally_space: system.Module_Space
tally_add: proc "c" (amount: i64, note: ^string, error: ^errors.Error_Record) -> i64
tally_add_export: u32
tally_place: int

tally_load :: proc "contextless" () -> bool {
	tally_space = {source = {image = image}, next = op.MODULE_BASE + 0x2_0000_0000}
	error: module.Load_Error
	place, loaded := system.module_space_load(&tally_space, system.image_find(image, "tally"), &error)
	if !loaded {
		return false
	}
	tally_place = place
	item := &tally_space.modules[place]
	tally_add_export = module.export_find(item.file, "add")
	address, found := module.export_address(item.file, uintptr(item.base), tally_add_export)
	if !found {
		return false
	}
	tally_add = cast(proc "c" (amount: i64, note: ^string, error: ^errors.Error_Record) -> i64)rawptr(address)
	return true
}

requests: ring.Ring // To the root service: Connect only (the grant Connect), and callable_of gives this program no service.
has_requests: bool
request_tag: u32

// root_connect asks the root service for a connection, and waits for its
// completion.
root_connect :: proc "contextless" (name: string) -> (completion: ring.Record, ok: bool) {
	if !has_requests {
		return {}, false
	}
	request_tag += 1
	packed := system.name_pack(name)
	if !system.send(&requests.commands, ring.Record{kind = u32(system.Root_Command.Connect), tag = request_tag, values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}}) {
		return {}, false
	}
	limit := system.time() + 2000
	for system.time() < limit {
		for record in system.receive(&requests.completions) {
			if record.tag == request_tag {
				return record, true
			}
		}
		wait: system.Wait
		system.wait_records(&wait, &requests.completions)
		system.wait_end(&wait, limit)
	}
	return {}, false
}

the_context: ^system.Context

// case_display_open asks for a surface of 0 by 100 pixels: display.open
// refuses it before any kernel operation.
case_display_open :: proc "contextless" (writer: ^system.Writer) -> bool {
	error: errors.Error_Record
	if _, opened := display.open(the_context, 0, 100, "zero", false, &error); opened {
		return false
	}
	system.wrapper_error_text(writer, &error, "display.open", display.OPEN_ARGUMENTS[:])
	return errors.Kind(error.kind) == .Bad_Value && error.argument == 2 && error.value == 0
}

// case_terminal_open opens the terminal of a program that has none.
case_terminal_open :: proc "contextless" (writer: ^system.Writer) -> bool {
	error: errors.Error_Record
	if _, opened := terminal.open(the_context, &error); opened {
		return false
	}
	system.wrapper_error_text(writer, &error, "terminal.open", {"ctx"})
	return errors.Kind(error.kind) == .No_Grant && errors.Unit(error.unit) == .Terminal
}

// case_root_connect asks the root service for a connection that the grant
// Connect of this program does not give: the completion holds the record.
case_root_connect :: proc "contextless" (writer: ^system.Writer) -> bool {
	completion, answered := root_connect("storage")
	if !answered {
		system.write_part(writer, "the root service did not answer")
		return false
	}
	error := errors.completion_record(completion.values)
	system.ring_error_text(writer, &error, "root", system.root_command_name(error.operation), system.root_argument_name(error.operation, error.argument))
	return system.Status(completion.kind) == .No_Right && errors.Kind(error.kind) == .No_Grant && errors.Unit(error.unit) == .Connection
}

// case_tally_add calls the export add of tally, loaded as a library, with a
// note longer than it keeps.
case_tally_add :: proc "contextless" (writer: ^system.Writer) -> bool {
	if tally_add == nil {
		system.write_part(writer, "the module tally did not load")
		return false
	}
	error: errors.Error_Record
	note := "a note of forty bytes, four more than 36"
	if tally_add(1, &note, &error) >= 0 {
		return false
	}
	error.operation = i64(tally_add_export) // The caller knows the export that it called.
	system.export_error_text(writer, tally_space.modules[tally_place].file, tally_add_export, "tally", &error)
	return errors.Kind(error.kind) == .Too_Long && error.value == 40 && error.limit == 36
}

// The measures of a failed call of each family of section 8 of
// MODULE_CONTRACT.md that is not a kernel operation: family_root in
// nanoseconds, the two others in tenths of a nanosecond.
family_wrapper, family_root, family_export: u64

families_measure :: proc "contextless" (ctx: ^system.Context) {
	WRAPPER_CALLS :: 1_000_000
	error: errors.Error_Record
	start := system.nanoseconds()
	failed := 0
	for _ in 0 ..< WRAPPER_CALLS {
		if _, opened := terminal.open(ctx, &error); !opened {
			failed += 1
		}
	}
	family_wrapper = (system.nanoseconds() - start) * 10 / WRAPPER_CALLS
	ROOT_CALLS :: 2000
	start = system.nanoseconds()
	for _ in 0 ..< ROOT_CALLS {
		if completion, answered := root_connect("storage"); answered && completion.kind != 0 {
			failed += 1
		}
	}
	family_root = (system.nanoseconds() - start) / ROOT_CALLS
	if tally_add != nil {
		EXPORT_CALLS :: 1_000_000
		note := "a note of forty bytes, four more than 36"
		start = system.nanoseconds()
		for _ in 0 ..< EXPORT_CALLS {
			tally_add(1, &note, &error)
		}
		family_export = (system.nanoseconds() - start) * 10 / EXPORT_CALLS
	}
	system.log("errors: a failed call of each family: a wrapper of support (terminal.open with no terminal): ", family_wrapper / 10, ".", family_wrapper % 10, " ns; a command of the root ring (Connect refused): ", family_root, " ns; an export (tally.add with a note of 40 bytes, direct): ", family_export / 10, ".", family_export % 10, " ns; ", u64(failed), " failures")
}

case_direct :: proc "contextless" (writer: ^system.Writer) -> bool {
	if square_root == nil {
		system.write_part(writer, "the module math did not load")
		return false
	}
	error: errors.Error_Record
	result := square_root(-4, &error)
	if result >= 0 {
		return false
	}
	error.operation = i64(square_root_export) // The caller knows the export that it called.
	system.export_error_text(writer, math_space.modules[math_place].file, square_root_export, "math", &error)
	return errors.Kind(error.kind) == .Too_Small && error.value == -4
}

// storage_case makes one isolated call of the storage service that must
// fail with an error kind.
storage_case :: proc "contextless" (writer: ^system.Writer, export: string, expected: errors.Kind, name: string, data: string = "") -> bool {
	if !connected {
		system.write_part(writer, "no connection to the storage service")
		return false
	}
	arguments := [2]isolated.Argument{{text = transmute([]u8)name}, {text = transmute([]u8)data}}
	error: errors.Error_Record
	result, _, status := storage.call(&client, export, arguments[:export == "write" ? 2 : 1], &error)
	storage.error_text(writer, &client, &error)
	return status == .Failed && result < 0 && errors.Kind(error.kind) == expected
}

case_empty :: proc "contextless" (writer: ^system.Writer) -> bool {
	return storage_case(writer, "write", .Empty, "", "x")
}

case_long :: proc "contextless" (writer: ^system.Writer) -> bool {
	return storage_case(writer, "write", .Too_Long, "a name of forty bytes, nine more than 31", "x")
}

case_byte :: proc "contextless" (writer: ^system.Writer) -> bool {
	return storage_case(writer, "write", .Bad_Byte, "a\x00b", "x")
}

case_limit :: proc "contextless" (writer: ^system.Writer) -> bool {
	return storage_case(writer, "write", .Over_Limit, "large", "one block of data, and its list")
}

case_size :: proc "contextless" (writer: ^system.Writer) -> bool {
	return storage_case(writer, "size", .Absent, "nothing")
}

last_fault: system.Handle // The program fault of the last run of its case.

// case_fault starts the program fault, which writes to address 0 three
// calls deep, and reads its stop report: the stack trace.
case_fault :: proc "contextless" (writer: ^system.Writer) -> bool {
	error: module.Load_Error
	program, status := system.program_start(system.image_find(image, "fault"), "fault", {}, random.values_with_seed(&program_generator, {}), {pages = 256, programs = 1, threads = 1, processor = 100_000, log_records = 10}, nil, nil, {image = image}, &error)
	if status != .Ok {
		system.write_part(writer, "the program fault did not start")
		return false
	}
	// The stopped program stays until the next run of this case: a
	// developer tool shows it, with its stop report (docs/TOOLS.md).
	if last_fault != 0 {
		system.close(last_fault)
	}
	last_fault = program
	limit := system.time() + 5000
	for {
		wait := system.wait_begin()
		if state, _ := system.program_state(program); state == .Stopped || system.time() > limit {
			break
		}
		system.wait_end(&wait, limit)
	}
	report := system.program_stop_report(program)
	system.write_part(writer, report.vector == 14 ? "page fault at " : "a fault at ")
	frames := report.frames[:min(report.frame_count, op.STOP_FRAME_CAPACITY)]
	fault_hash := hash_of("fault")
	all_in_fault := len(frames) >= 4
	for &frame, number in frames {
		system.write_part(writer, number == 0 ? "" : ", ")
		system.frame_text(writer, image, &frame)
		all_in_fault &&= frame.hash == fault_hash
	}
	return report.code == op.STOP_CODE_FAULT + 14 && all_in_fault
}

// case_run runs the case of an index.
case_run :: proc "contextless" (index: int, writer: ^system.Writer) -> bool {
	switch index {
	case 0:
		return case_rights(writer)
	case 1:
		return case_revoked(writer)
	case 2:
		return case_closed(writer)
	case 3:
		return case_kind(writer)
	case 4:
		return case_absent(writer)
	case 5:
		return case_budget(writer)
	case 6:
		return case_address(writer)
	case 7:
		return case_name(writer)
	case 8:
		return case_flags(writer)
	case 9:
		return case_operation(writer)
	case 10:
		return case_missing(writer)
	case 11:
		return case_replacement(writer)
	case 12:
		return case_direct(writer)
	case 13:
		return case_empty(writer)
	case 14:
		return case_long(writer)
	case 15:
		return case_byte(writer)
	case 16:
		return case_limit(writer)
	case 17:
		return case_size(writer)
	case 18:
		return case_fault(writer)
	case 19:
		return case_pages_of_another_program(writer)
	case 20:
		return case_pages_past_the_user_half(writer)
	case 21:
		return case_display_open(writer)
	case 22:
		return case_terminal_open(writer)
	case 23:
		return case_root_connect(writer)
	case 24:
		return case_tally_add(writer)
	}
	return false
}

// run runs one case and keeps its sentence.
run :: proc "contextless" (index: int) {
	item := &cases[index]
	writer := system.Writer{buffer = item.sentence[:]}
	item.right = case_run(index, &writer)
	item.count = writer.count
}

// measure gives the nanoseconds of one kernel operation that succeeds and
// of one that fails with its error record, and the same for a direct call.
measure :: proc "contextless" () {
	CALLS :: 200_000
	budget := u64(system.own_budget())
	timed :: proc "contextless" (operation: op.Operation, value: u64) -> u64 {
		start := system.time()
		for _ in 0 ..< CALLS {
			system.call(operation, value, 0)
		}
		return (system.time() - start) * 1_000_000 / CALLS
	}
	best_good, best_failed := max(u64), max(u64)
	for _ in 0 ..< 3 {
		best_good = min(best_good, timed(.Handle_State, budget)) // Ok.
		best_failed = min(best_failed, timed(.Memory_Size, budget)) // Handle_Kind, with its record.
	}
	kernel_good, kernel_failed = best_good, best_failed
	if square_root == nil {
		return
	}
	// A failed call takes a few nanoseconds: the cycle counter gives the
	// time (system.nanoseconds), not the milliseconds of the time page.
	DIRECT :: 2_000_000
	error: errors.Error_Record
	sum: i64
	start := system.nanoseconds()
	for index in 0 ..< DIRECT {
		sum += square_root(i64(index & 0xFF), &error)
	}
	direct_good = (system.nanoseconds() - start) / DIRECT
	start = system.nanoseconds()
	for index in 0 ..< DIRECT {
		sum += square_root(-1 - i64(index & 0xFF), &error)
	}
	direct_failed = (system.nanoseconds() - start) / DIRECT
	if sum == 0 {
		system.log("errors: the sum of the calls is 0")
	}
}

// The refusals that read a budget: a Log over the limit of the budget of the
// program, and a Memory_Create that a budget cannot pay. A refused Log needs
// a program with a log limit of 0: this program starts a copy of itself as
// a child (VALUE_CHILD), with a budget of 0 log records, which measures and
// writes its time in a page that the two map. The locks: System_Report.locks
// before and after each loop, for all the processors.
VALUE_CHILD :: 8
MEASURE_ADDRESS :: 0x0000_3200_0000_0000
REFUSALS :: 100_000

Child_Page :: struct {
	log_ns: u64,
	done:   u64,
}

refused_log_ns, refused_log_control, refused_log_frame: u64
refused_create_ns, refused_create_control, refused_create_frame: u64

lock_takes :: proc "contextless" (machine: system.Handle) -> (control, frame: u64) {
	report: op.System_Report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
	return report.locks[op.Lock_Kind.Control].takes, report.locks[op.Lock_Kind.Frame].takes
}

// child runs REFUSALS refused Log operations, writes their time, and stops.
child :: proc "contextless" (ctx: ^system.Context) -> ! {
	page := (^Child_Page)(uintptr(MEASURE_ADDRESS))
	log := u64(ctx.handles[op.CONTEXT_LOG])
	text := "x"
	start := system.time()
	for _ in 0 ..< REFUSALS {
		system.call(.Log, log, u64(uintptr(raw_data(text))), 1, u64(op.Log_Level.Debug), 0, 0)
	}
	page.log_ns = (system.time() - start) * 1_000_000 / REFUSALS
	intrinsics.atomic_store(&page.done, 1)
	system.stop(0)
}

// refusals measures the two refusals; the machine handle reads the counts of
// the locks.
refusals :: proc "contextless" (ctx: ^system.Context) {
	// The machine handle: the global `machine` (entry sets it).
	memory, _ := system.memory_create(1)
	defer system.close(memory)
	address, _ := system.memory_map(memory)
	page := (^Child_Page)(address)
	grants: [op.CONTEXT_HANDLES]system.Grant
	grants[op.CONTEXT_LOG] = {ctx.handles[op.CONTEXT_LOG], {.Write}}
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_CHILD] = 1
	mappings := [1]system.Mapping{{memory = memory, address = MEASURE_ADDRESS, flags = {.Write}}}
	control, frame := lock_takes(machine)
	error: module.Load_Error
	program, status := system.program_start(system.image_find(image, "errors"), "errors child", grants, random.values_with_seed(&program_generator, values), {pages = 256, programs = 1, threads = 1, processor = 1_000_000, log_records = 0}, mappings[:], nil, {image = image}, &error)
	if status == .Ok {
		for intrinsics.atomic_load(&page.done) == 0 {
			if state, _ := system.program_state(program); state == .Stopped {
				break
			}
			system.sleep(system.time() + 10)
		}
		system.close(program)
	}
	control_after, frame_after := lock_takes(machine)
	refused_log_ns, refused_log_control, refused_log_frame = page.log_ns, control_after - control, frame_after - frame
	budget, _ := system.budget_create({pages = 2})
	defer system.close(budget)
	control, frame = lock_takes(machine)
	start := system.time()
	for _ in 0 ..< REFUSALS {
		system.call(.Memory_Create, u64(budget), 64, 0)
	}
	refused_create_ns = (system.time() - start) * 1_000_000 / REFUSALS
	control_after, frame_after = lock_takes(machine)
	refused_create_control, refused_create_frame = control_after - control, frame_after - frame
	system.log("errors: ", u64(REFUSALS), " refused Log: ", refused_log_ns, " ns each, the control lock taken ", refused_log_control, " times and the frame lock ", refused_log_frame, " times; ", u64(REFUSALS), " refused Memory_Create: ", refused_create_ns, " ns each, the control lock taken ", refused_create_control, " times and the frame lock ", refused_create_frame, " times")
}

// Failures under contention: two threads make failures on the handles that
// a third thread closes and makes again, at the same time. Each record must
// explain its status: the kernel reads the state again after the failure,
// and the state can change between the two (docs/MODULE_CONTRACT.md,
// section 8).
CONTENTION_MILLISECONDS :: 500
SHARED_HANDLES :: 4

Contention :: struct {
	memories: [SHARED_HANDLES]u32, // Copies with the right Read only: a map to write fails.
	budgets:  [SHARED_HANDLES]u32, // Budgets of 2 pages: 64 pages fail.
	stop:     u32,
	failures: [2]u64,
	refused:  [2]u64, // Records of the kind Refused: the cause was gone when the kernel read the state again.
	wrong:    [2]u64, // Records that contradict their status.
	made:     u64, // Handles that the third thread closed and made again.
	source:   system.Handle, // The memory object of the copies.
}

contention: Contention

// explains says if the kind of a record can be the cause of a status, as
// the contract states it.
explains :: proc "contextless" (record: ^errors.Error_Record, status: system.Status) -> bool {
	kind := errors.Kind(record.kind)
	if kind == .Refused {
		return record.found == i64(status)
	}
	#partial switch status {
	case .Bad_Handle:
		return kind == .Handle_Absent || kind == .Handle_Ended || kind == .Handle_Kind || kind == .No_Target
	case .No_Right:
		return kind == .Handle_Rights
	case .No_Budget:
		// A budget record names a cause that holds: the budget holds less
		// than the call asks; a count over its limit.
		return kind == .Budget && record.limit > record.found || kind == .Budget_Hidden || kind == .Over_Limit && record.value > record.limit
	}
	return false
}

// failing makes failures until the stop: thread 0 maps a copy to write,
// thread 1 asks 64 pages of a budget of 2 and the size of a copy.
failing :: proc "c" (parameter: rawptr) -> ! {
	number := int(uintptr(parameter))
	turn := 0
	for intrinsics.atomic_load(&contention.stop) == 0 {
		turn += 1
		record: errors.Error_Record
		status: system.Status
		if number == 0 {
			handle := intrinsics.atomic_load(&contention.memories[turn % SHARED_HANDLES])
			_, status = system.call_with_error(&record, .Memory_Map, u64(handle), 0, 0, transmute(u64)op.Map_Flags{.Write}, 0, 0)
		} else if turn % 2 == 0 {
			handle := intrinsics.atomic_load(&contention.budgets[turn % SHARED_HANDLES])
			_, status = system.call_with_error(&record, .Memory_Create, u64(handle), 64, 0)
		} else {
			handle := intrinsics.atomic_load(&contention.memories[turn % SHARED_HANDLES])
			_, status = system.call_with_error(&record, .Memory_Size, u64(handle) + 0x7F)
		}
		if status == .Ok {
			continue
		}
		contention.failures[number] += 1
		if errors.Kind(record.kind) == .Refused {
			contention.refused[number] += 1
		}
		if !explains(&record, status) {
			contention.wrong[number] += 1
		}
	}
	system.thread_stop()
}

// changing closes and makes again the handles that the failures name.
changing :: proc "c" (parameter: rawptr) -> ! {
	turn := 0
	for intrinsics.atomic_load(&contention.stop) == 0 {
		turn += 1
		place := turn % SHARED_HANDLES
		system.close(system.Handle(intrinsics.atomic_load(&contention.memories[place])))
		copy, _ := system.give(0, contention.source, {.Read})
		intrinsics.atomic_store(&contention.memories[place], u32(copy))
		system.close(system.Handle(intrinsics.atomic_load(&contention.budgets[place])))
		budget, _ := system.budget_create({pages = 2})
		intrinsics.atomic_store(&contention.budgets[place], u32(budget))
		contention.made += 2
	}
	system.thread_stop()
}

// contend runs the two threads of failures and the thread of changes for
// CONTENTION_MILLISECONDS. ok: each record explains its status.
contend :: proc "contextless" () -> bool {
	contention.source, _ = system.memory_create(1)
	threads: [3]system.Thread
	statuses: [3]system.Status
	threads[0], statuses[0] = system.thread_start(failing, rawptr(uintptr(0)))
	threads[1], statuses[1] = system.thread_start(failing, rawptr(uintptr(1)))
	threads[2], statuses[2] = system.thread_start(changing, nil)
	system.sleep(system.time() + CONTENTION_MILLISECONDS)
	intrinsics.atomic_store(&contention.stop, 1)
	started := 0
	for thread, index in threads {
		if statuses[index] == .Ok {
			system.thread_wait(thread)
			started += 1
		}
	}
	for place in 0 ..< SHARED_HANDLES {
		system.close(system.Handle(contention.memories[place]))
		system.close(system.Handle(contention.budgets[place]))
	}
	system.close(contention.source)
	failures := contention.failures[0] + contention.failures[1]
	wrong := contention.wrong[0] + contention.wrong[1]
	refused := contention.refused[0] + contention.refused[1]
	system.log("errors: under contention: ", failures, " failures from 2 threads while a third thread closed and made ", contention.made, " handles; ", wrong, " records contradict their status, ", refused, " records name no cause (Refused)")
	// A record with no cause is right only when the state changed between
	// the failure and the read: most records must name their cause.
	return started == 3 && failures > 0 && contention.made > 0 && wrong == 0 && refused * 2 < failures
}

@(rodata)
key_names := "abcdefghijklmnopqrstuvwxyz0123456789"
FAULT_CASE :: 18

// The random generator of this program (support/random).
program_generator: random.Generator

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	// The random generator of this program, from the seed that its starter
	// gave: it gives the seed of each program that this one starts.
	if !random.generator_from_context(&program_generator, ctx) {
		system.log("errors: no random seed in the context")
		system.stop(1)
	}
	if ctx.values[VALUE_CHILD] != 0 {
		child(ctx)
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, "errors")
	if !ok {
		system.stop(1)
	}
	ctx_log = ctx.handles[op.CONTEXT_LOG]
	the_context = ctx
	machine = ctx.handles[system.GRANT_MACHINE]
	image_memory = ctx.handles[system.GRANT_IMAGE]
	if address, status := system.memory_map(image_memory, {}); status == .Ok {
		image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	}
	client, connected = storage.open(ctx)
	math_load()
	tally_load()
	if ctx.handles[system.GRANT_ROOT] != 0 {
		status: system.Status
		requests, status = system.ring_open(ctx.handles[system.GRANT_ROOT])
		has_requests = status == .Ok
	}

	wrong := 0
	for &item, index in cases {
		run(index)
		if !item.right {
			wrong += 1
		}
		sentence := string(item.sentence[:item.count])
		if index == FAULT_CASE {
			system.log("errors: stack of fault: ", sentence[min(len(sentence), len("page fault at ")):])
		}
		system.log("errors: ", key_names[index:index + 1], " ", item.text, ": ", item.right ? "" : "WRONG: ", sentence)
	}
	if wrong == 0 {
		system.log("errors: ok, ", u64(len(cases)), " cases, each with the expected error record")
	} else {
		system.log("errors: ", u64(wrong), " cases of ", u64(len(cases)), " gave another answer")
	}
	if !contend() {
		system.log("errors: WRONG: the case under contention failed")
	}
	measure()
	families_measure(ctx)
	refusals(ctx)
	system.log("errors: a kernel operation that succeeds: ", kernel_good, " ns; one that fails, with its error record: ", kernel_failed, " ns; a direct call that succeeds: ", direct_good, " ns; one that fails: ", direct_failed, " ns")

	pressed := false
	for {
		draw(&window)
		display.wait(&window)
		for event in display.next_event(&window) {
			chosen := -1
			#partial switch event.kind {
			case .Key:
				if event.pressed && event.code == KEY_TAB {
					shown_page = (shown_page + 1) % PAGE_COUNT
					system.log("errors: the window shows the page ", u64(shown_page + 1), " of the cases")
				} else if event.pressed {
					for index in 0 ..< len(cases) {
						if key_names[index] == event.character {
							chosen = index
						}
					}
				}
			case .Pointer:
				down := event.buttons & 1 != 0
				if down && !pressed {
					chosen = case_at(event.y)
				}
				pressed = down
			}
			if chosen >= 0 {
				run(chosen)
				item := &cases[chosen]
				system.log("errors: case ", key_names[chosen:chosen + 1], " again: ", item.right ? "" : "WRONG: ", string(item.sentence[:item.count]))
			}
		}
	}
}

// sentence_cut gives where the first line of a sentence ends: all of it
// if it fits, else the last space that fits.
sentence_cut :: proc "contextless" (sentence: string) -> int {
	if len(sentence) <= SHOWN {
		return len(sentence)
	}
	for index := SHOWN; index > 0; index -= 1 {
		if sentence[index] == ' ' {
			return index
		}
	}
	return SHOWN
}

case_height :: proc "contextless" (index: int) -> int {
	return cases[index].count > SHOWN ? CASE_HEIGHT + LINE : CASE_HEIGHT
}

KEY_TAB :: 0x0F

// case_at gives the case that is drawn at a height of the window, or -1.
case_at :: proc "contextless" (at: int) -> int {
	y := TOP
	for index in shown_page * CASES_ON_A_PAGE ..< min((shown_page + 1) * CASES_ON_A_PAGE, len(cases)) {
		next := y + case_height(index)
		if at >= y && at < next {
			return index
		}
		y = next
	}
	return -1
}

draw :: proc "contextless" (window: ^display.Window) {
	if drawing.now.records == nil {
		drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	}
	frame := interface.window_frame_begin(&drawing, window)
	table := frame.table
	interface.draw_rectangle(table, 0, 0, WIDTH, HEIGHT, graphics.COLOR_BACKGROUND)
	interface.draw_text(table, 16, 8, "each case makes an error for real; under it, the sentence of its record: errors.Error_Record,", graphics.COLOR_DIM)
	interface.draw_text(table, 16, 8 + LINE, "module.Load_Error, op.Stop_Report.frames. Its key or a click runs a case again; tab: the other page", graphics.COLOR_DIM)
	page_text: [32]u8
	interface.draw_text(table, WIDTH - 120, 8 + LINE, system.format(page_text[:], "page ", u64(shown_page + 1), " of ", u64(PAGE_COUNT)), graphics.COLOR_TEXT)
	y := TOP
	first := shown_page * CASES_ON_A_PAGE
	for &item, place in cases[first:min(first + CASES_ON_A_PAGE, len(cases))] {
		index := first + place
		height := case_height(index)
		if place % 2 == 0 {
			interface.draw_rectangle(table, 8, y, WIDTH - 16, height, graphics.COLOR_TRACK)
		}
		interface.draw_text(table, 16, y, key_names[index:index + 1], graphics.COLOR_DIM)
		interface.draw_text(table, 32, y, item.text, graphics.COLOR_DIM)
		interface.draw_text(table, 440, y, item.expected, graphics.COLOR_TEXT)
		interface.draw_text(table, 640, y, item.right ? "the expected record" : "another answer", item.right ? graphics.COLOR_TEXT : graphics.COLOR_FAILED)
		sentence := string(item.sentence[:item.count])
		cut := sentence_cut(sentence)
		color: u32 = item.right ? graphics.COLOR_TEXT : graphics.COLOR_FAILED
		interface.draw_text(table, 32, y + LINE, sentence[:cut], color)
		if cut < len(sentence) {
			rest := sentence[sentence[cut] == ' ' ? cut + 1 : cut:]
			interface.draw_text(table, 32, y + 2 * LINE, rest[:min(len(rest), SHOWN)], color)
		}
		y += height
	}
	y += 8
	line: [160]u8
	interface.draw_text(table, 16, y, system.format(line[:], "a failure with its error record: ", kernel_failed, " ns in a kernel operation (success: ", kernel_good, " ns), ", direct_failed, " ns in a direct call (success: ", direct_good, " ns)"), graphics.COLOR_DIM)
	interface.window_frame_end(&drawing, &frame, window)
}
