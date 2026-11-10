// A program that shows the errors of the system: one case for each kind of error. Each case makes the error for real, and shows the sentence of the error record that the system gave (docs/MODULE_CONTRACT.md, section 8).
//
// The cases: kernel operations that the kernel refuses (a right, a handle that was revoked or closed, a budget that cannot pay, an address, a size, a flag); loads that fail (a missing import, a replacement that fails its check); a direct call of a module export that fails; isolated calls of the storage service that fail; and a program that faults three calls deep, with its stack trace.
//
// The program runs each case at its start. A key from a to s, or a click on a case, runs it again.
package errors_program

import "contract:errors"
import "contract:isolated"
import module "contract:module"
import op "contract:operation"
import "support:display"
import "support:graphics"
import "support:storage"
import "support:system"

WIDTH :: 1000
LINE :: 16
TOP :: 8 + 2 * LINE + 8 // The first case.
CASE_HEIGHT :: 2 * LINE
CASE_CAPACITY :: 19
HEIGHT :: TOP + CASE_CAPACITY * CASE_HEIGHT + 8 + 2 * LINE + 8
SENTENCE_CAPACITY :: 240
SHOWN :: (WIDTH - 40) / 8 // The characters of a line of the window.

COLOR_BACKGROUND :: 0x10151C
COLOR_PANEL :: 0x18202A
COLOR_TEXT :: 0xD8E0E8
COLOR_DIM :: 0x7A8794
COLOR_RIGHT :: 0x58D878
COLOR_WRONG :: 0xE0B040
COLOR_SENTENCE :: 0xE88070

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
}

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
	memory, status := system.memory_create(1, 0, transmute(op.Memory_Flags)u64(0x4), &record)
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

// case_fault starts the program fault, which writes to address 0 three
// calls deep, and reads its stop report: the stack trace.
case_fault :: proc "contextless" (writer: ^system.Writer) -> bool {
	error: module.Load_Error
	program, status := system.program_start(system.image_find(image, "fault"), "fault", {}, {}, {pages = 256, programs = 1, threads = 1, processor = 100_000, log_records = 10}, nil, nil, {image = image}, &error)
	if status != .Ok {
		system.write_part(writer, "the program fault did not start")
		return false
	}
	defer system.close(program)
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
	DIRECT :: 2_000_000
	error: errors.Error_Record
	sum: i64
	start := system.time()
	for index in 0 ..< DIRECT {
		sum += square_root(i64(index & 0xFF), &error)
	}
	direct_good = (system.time() - start) * 1_000_000 / DIRECT
	start = system.time()
	for index in 0 ..< DIRECT {
		sum += square_root(-1 - i64(index & 0xFF), &error)
	}
	direct_failed = (system.time() - start) * 1_000_000 / DIRECT
	if sum == 0 {
		system.log("errors: the sum of the calls is 0")
	}
}

@(rodata)
key_names := "abcdefghijklmnopqrs"
FAULT_CASE :: 18

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "errors")
	if !ok {
		system.stop(1)
	}
	ctx_log = ctx.handles[op.CONTEXT_LOG]
	image_memory = ctx.handles[system.GRANT_IMAGE]
	if address, status := system.memory_map(image_memory, {}); status == .Ok {
		image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	}
	client, connected = storage.open(ctx)
	math_load()

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
	measure()
	system.log("errors: a kernel operation that succeeds: ", kernel_good, " ns; one that fails, with its error record: ", kernel_failed, " ns; a direct call that succeeds: ", direct_good, " ns; one that fails: ", direct_failed, " ns")

	pressed := false
	for {
		draw(&window)
		display.present(&window)
		display.wait(&window)
		for event in display.next_event(&window) {
			chosen := -1
			#partial switch event.kind {
			case .Key:
				if event.pressed && event.character >= 'a' && int(event.character - 'a') < len(cases) {
					chosen = int(event.character - 'a')
				}
			case .Pointer:
				down := event.buttons & 1 != 0
				if down && !pressed && event.y >= TOP && (event.y - TOP) / CASE_HEIGHT < len(cases) {
					chosen = (event.y - TOP) / CASE_HEIGHT
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

draw :: proc "contextless" (window: ^display.Window) {
	canvas := window.canvas
	graphics.clear(canvas, COLOR_BACKGROUND)
	graphics.text(canvas, 12, 8, "each case makes an error for real; the line under it is the sentence of the error record", COLOR_DIM)
	graphics.text(canvas, 12, 8 + LINE, "a key from a to s, or a click on a case, runs it again", COLOR_DIM)
	for &item, index in cases {
		y := TOP + index * CASE_HEIGHT
		if index % 2 == 0 {
			graphics.fill(canvas, 6, y - 1, WIDTH - 12, CASE_HEIGHT, COLOR_PANEL)
		}
		graphics.text(canvas, 12, y, key_names[index:index + 1], COLOR_DIM)
		graphics.text(canvas, 32, y, item.text, COLOR_TEXT)
		graphics.text(canvas, 440, y, item.expected, COLOR_DIM)
		graphics.text(canvas, 640, y, item.right ? "the expected record" : "another answer", item.right ? COLOR_RIGHT : COLOR_WRONG)
		sentence := string(item.sentence[:min(item.count, SHOWN)])
		graphics.text(canvas, 32, y + LINE, sentence, COLOR_SENTENCE)
	}
	y := TOP + len(cases) * CASE_HEIGHT + 8
	line: [120]u8
	graphics.text(canvas, 12, y, system.format(line[:], "kernel operation: ", kernel_good, " ns when it succeeds, ", kernel_failed, " ns when it fails with its error record"), COLOR_DIM)
	graphics.text(canvas, 12, y + LINE, system.format(line[:], "direct call of an export: ", direct_good, " ns when it succeeds, ", direct_failed, " ns when it fails with its error record"), COLOR_DIM)
}
