// Tables and bytes as parameters (docs/MODULE_CONTRACT.md, "Tables and
// bytes as parameters"): one description, three ways to call.
//
// This program calls the exports of the module sample with tables in its
// own memory, in three ways, with the same arguments: a direct call of the
// module that it loaded in its own address space, an isolated call of a
// call host that it starts, and an isolated call of the service "sample"
// (the same module, started by the root service as a program). It shows
// each answer, the hostile cases, and the cost of each way for tables of
// 64, 1024 and 65536 records of 40 bytes.
package tables

import "base:intrinsics"
import "contract:errors"
import "contract:isolated"
import module "contract:module"
import op "contract:operation"
import "contract:ring"
import "support:display"
import "support:graphics"
import "support:system"

// The records of sample, as this program declares them: the layout is the
// description (a program in C declares the same struct).
Reading :: struct {
	sensor:  i64,
	time:    i64,
	value:   i64,
	minimum: i64,
	maximum: i64,
}
#assert(size_of(Reading) == 40)

Word :: struct {
	start: u32,
	count: u32,
	sum:   i64,
}

Way :: enum {
	Direct,
	Call_Host,
	Service,
}

@(rodata)
way_names := [Way]string {
	.Direct    = "direct call",
	.Call_Host = "call host",
	.Service   = "service",
}

ANSWER_SIZE :: 40

Answer :: struct {
	text:  [ANSWER_SIZE]u8,
	count: int,
	right: bool,
	done:  bool,
}

CASE_CAPACITY :: 12

Case :: struct {
	name:    string,
	answers: [Way]Answer,
}

cases: [CASE_CAPACITY]Case
case_count: int

answer_set :: proc "contextless" (answer: ^Answer, right: bool, parts: ..system.Part) {
	written := system.format(answer.text[:], ..parts)
	answer.count = len(written)
	answer.right, answer.done = right, true
}

image: []u8
image_memory: system.Handle
space: system.Module_Space
sample_file: []u8
sample_base: u64
host: system.Call_Connection
service: system.Call_Connection
requests: ring.Ring
ways_ready: [Way]bool

// The table of the measures, in a memory object: the same records are the
// table of a direct call and the table of a lent memory object.
LARGE_COUNT :: 65536
large_memory: system.Handle
large: []Reading

export_of :: proc "contextless" (name: string) -> (index: u32, function: module.Function, address: uintptr) {
	index = module.export_find(sample_file, name)
	function, _ = module.function(sample_file, index)
	address, _ = module.export_address(sample_file, uintptr(sample_base), index)
	return
}

// call runs one export with the same arguments in one way.
call :: proc "contextless" (way: Way, name: string, arguments: []isolated.Argument, error: ^errors.Error_Record = nil) -> (result: i64, status: system.Call_Status) {
	index, function, address := export_of(name)
	switch way {
	case .Direct:
		result = system.call_direct(sample_file, address, function, arguments, error)
		if function.error_record != 0 && result < 0 {
			status = .Failed
		}
		return
	case .Call_Host:
		return system.call_isolated(&host, sample_file, index, arguments, error)
	case .Service:
		return system.call_isolated(&service, sample_file, index, arguments, error)
	}
	return
}

bytes_of :: proc "contextless" (memory: rawptr, count: int) -> []u8 {
	return ([^]u8)(memory)[:count]
}

GUARD :: u8(0xA5)

guard_fill :: proc "contextless" (bytes: []u8) {
	for &b in bytes {
		b = GUARD
	}
}

answer_text :: proc "contextless" (answer: ^Answer) -> string {
	return string(answer.text[:answer.count])
}

guard_holds :: proc "contextless" (bytes: []u8) -> bool {
	for b in bytes {
		if b != GUARD {
			return false
		}
	}
	return true
}

readings_four :: proc "contextless" (memory: ^[8]Reading) {
	memory^ = {}
	for index in 0 ..< 4 {
		value := i64(index + 1) * 10
		memory[index] = {sensor = i64(index), time = i64(index), value = value, minimum = value, maximum = value}
	}
}

case_add :: proc "contextless" (name: string) -> ^Case {
	item := &cases[case_count]
	item.name = name
	case_count += 1
	return item
}

run_cases :: proc "contextless" () {
	sum := case_add("sum_values  Read, 4 rows")
	scale := case_add("scale_values  Change, x3")
	appended := case_add("append_readings  5 after 2, cap 6")
	empty := case_add("append_readings  capacity 0")
	words := case_add("sum_words  offsets into Bytes")
	outside := case_add("sum_words  a word past the text")
	upper := case_add("upper_case  Bytes(Change)")
	past := case_add("a callee writes past capacity")
	for way in Way {
		if !ways_ready[way] {
			for &item in cases[:case_count] {
				answer_set(&item.answers[way], false, "not reached")
			}
			continue
		}
		memory: [8]Reading
		readings_four(&memory)
		arguments := [3]isolated.Argument{}
		arguments[0].table = {records = bytes_of(&memory, 4 * 40), count = 4}
		result, status := call(way, "sum_values", arguments[:1])
		answer_set(&sum.answers[way], status == .Ok && result == 100, result)

		readings_four(&memory)
		arguments[0].table = {records = bytes_of(&memory, 4 * 40), count = 4}
		arguments[1] = {integer = 3}
		result, status = call(way, "scale_values", arguments[:2])
		answer_set(&scale.answers[way], status == .Ok && result == 4 && memory[3].value == 120 && memory[0].maximum == 30 && memory[4] == {}, result, " rows; row 4: ", memory[3].value)

		// 8 places: the table has a capacity of 6, then a guard of 2 records.
		readings_four(&memory)
		guard_fill(bytes_of(&memory[6], 2 * 40))
		arguments[0] = {integer = 5}
		arguments[1] = {integer = 100}
		arguments[2].table = {records = bytes_of(&memory, 6 * 40), count = 2}
		result, status = call(way, "append_readings", arguments[:3])
		answer_set(&appended.answers[way], status == .Ok && result == 4 && arguments[2].table.count == 7 && memory[2].value == 100 && memory[5].value == 103 && memory[1].value == 20 && guard_holds(bytes_of(&memory[6], 80)), result, " written, count ", arguments[2].table.count)

		arguments[2].table = {count = 0}
		arguments[0] = {integer = 3}
		result, status = call(way, "append_readings", arguments[:3])
		answer_set(&empty.answers[way], status == .Ok && result == 0 && arguments[2].table.count == 3, result, " written, count ", arguments[2].table.count)

		text := "tables go in"
		list := [3]Word{{0, 6, 0}, {7, 2, 0}, {10, 2, 0}}
		arguments[0].table = {records = bytes_of(&list, size_of(list)), count = 3}
		arguments[1] = {}
		arguments[1].table = {records = transmute([]u8)text, count = u64(len(text))}
		error: errors.Error_Record
		result, status = call(way, "sum_words", arguments[:2], &error)
		answer_set(&words.answers[way], status == .Ok && result == 1064 && list[0].sum == 635 && list[1].sum == 214, result, "; words ", list[0].sum, " ", list[1].sum, " ", list[2].sum)

		list[1] = {7, 9, 0}
		error = {}
		result, status = call(way, "sum_words", arguments[:2], &error)
		answer_set(&outside.answers[way], status == .Failed && result == -1 && errors.Kind(error.kind) == .Outside && error.found == 2 && error.value == 16 && error.limit == 12, "Outside: word ", error.found, ", end ", error.value)

		changed: [12]u8
		copy(changed[:], "tables go in")
		arguments[0] = {}
		arguments[0].table = {records = changed[:], count = 12}
		result, status = call(way, "upper_case", arguments[:1])
		answer_set(&upper.answers[way], status == .Ok && result == 10 && string(changed[:]) == "TABLES GO IN", result, " letters: ", string(changed[:]))

		// The export writes 4 records after the capacity, against the rule.
		// A direct call has one address space: the guard is written. An
		// isolated call: the caller copies up to the capacity only.
		memory = {}
		guard_fill(bytes_of(&memory[2], 6 * 40))
		arguments[0] = {}
		arguments[0].table = {records = bytes_of(&memory, 2 * 40), count = 0}
		result, status = call(way, "append_past_capacity", arguments[:1])
		holds := guard_holds(bytes_of(&memory[2], 6 * 40))
		answer_set(&past.answers[way], way == .Direct ? !holds : holds && status == .Ok, holds ? "the guard holds" : "guard written: one space")
	}
}

// The hostile cases, through the call host.
Hostile :: struct {
	name:   string,
	answer: Answer,
}
hostile: [6]Hostile
hostile_count: int

hostile_add :: proc "contextless" (name: string, right: bool, parts: ..system.Part) {
	item := &hostile[hostile_count]
	item.name = name
	answer_set(&item.answer, right, ..parts)
	hostile_count += 1
}

// raw_call sends an argument record that this program wrote itself, as a
// hostile caller does, and gives the status of the completion.
raw_call :: proc "contextless" (connection: ^system.Call_Connection, export: u32, size: u64) -> isolated.Status {
	connection.tag += 1
	system.send(&connection.calls.commands, ring.Record{kind = export, tag = connection.tag, values = {0 = 0, 1 = size}})
	for {
		wait := system.wait_begin()
		for record in system.receive(&connection.calls.completions) {
			if record.tag == connection.tag {
				return isolated.Status(record.kind)
			}
		}
		if state, _ := system.program_state(connection.program); state == .Stopped {
			return isolated.Status(max(u32))
		}
		system.wait_records(&wait, &connection.calls.completions)
		system.wait_end(&wait)
	}
}

run_hostile :: proc "contextless" () {
	if !ways_ready[.Call_Host] {
		hostile_add("the hostile cases", false, "no call host")
		return
	}
	index, function, _ := export_of("sum_values")
	arguments := [2]isolated.Argument{}
	arguments[0].table = {records = bytes_of(raw_data(large), LARGE_COUNT * 40), count = LARGE_COUNT}
	_, status := system.call_isolated(&host, sample_file, index, arguments[:1])
	missing := isolated.room_missing(sample_file, function, arguments[:1], u64(len(host.region)))
	hostile_add("65536 rows in the call region", status == .No_Room && missing.needed == LARGE_COUNT * 40, "refused: ", missing.needed, " bytes, ", missing.free, " free")

	arguments[0].table.memory = u64(large_memory)
	result, lent_status := system.call_isolated(&host, sample_file, index, arguments[:1])
	expected := i64(LARGE_COUNT) * (LARGE_COUNT - 1) / 2
	hostile_add("the same rows in a lent memory object", lent_status == .Ok && result == expected, result)

	// A Change table in a memory object that this program lends with Read
	// only: the receiver proves the rights of the direction.
	scale_index, scale_function, _ := export_of("scale_values")
	copy_handle, give_status := system.give(0, large_memory, {.Read, .Give})
	receiver: system.Handle
	if give_status == .Ok {
		receiver, give_status = system.give(host.ring_memory, copy_handle, {.Read})
	}
	arguments[0].table = {records = bytes_of(raw_data(large), 64 * 40), count = 64, memory = u64(receiver)}
	arguments[1] = {integer = 2}
	_, size, _, _, encoded := isolated.encode(sample_file, scale_function, arguments[:2], host.region)
	refused := encoded && give_status == .Ok ? raw_call(&host, scale_index, size) : .Ok
	system.handle_revoke(copy_handle)
	system.close(copy_handle)
	hostile_add("a Change table lent with Read only", refused == .Bad_Handle && large[63].value == 63, "status ", u64(refused), ": Bad_Handle; rows unchanged")

	// A count larger than the call region, written by hand.
	arguments[0].table = {records = bytes_of(raw_data(large), 64 * 40), count = 64}
	_, size, _, _, encoded = isolated.encode(sample_file, function, arguments[:1], host.region)
	field := (^isolated.Table_Field)(raw_data(host.region))
	field.count = 1 << 40
	refused = encoded ? raw_call(&host, index, size) : .Ok
	hostile_add("a count of 2^40 rows", refused == .Bad_Arguments, "status ", u64(refused), ": Bad_Arguments")

	// A start that wraps.
	_, size, _, _, encoded = isolated.encode(sample_file, function, arguments[:1], host.region)
	field.start = max(u64) - 7
	refused = encoded ? raw_call(&host, index, size) : .Ok
	hostile_add("a start that wraps", refused == .Bad_Arguments, "status ", u64(refused), ": Bad_Arguments")
}

// The measures: the least time of several runs, for one call of sum_values
// over 64, 1024 and 65536 readings.
SIZES :: [3]int{64, 1024, LARGE_COUNT}
Measure_Way :: enum {
	Direct,
	Region,
	Memory_Object,
	Service_Region,
}
@(rodata)
measure_names := [Measure_Way]string {
	.Direct         = "direct call",
	.Region         = "call host, call region",
	.Memory_Object  = "call host, memory object",
	.Service_Region = "service, call region",
}
measures: [Measure_Way][3]u64 // Nanoseconds for one call. 0: refused.

measure :: proc "contextless" () {
	index, function, address := export_of("sum_values")
	direct := cast(proc "c" (readings: ^system.Table_To_Read(Reading)) -> i64)rawptr(address)
	sizes := SIZES
	for size, column in sizes {
		repeat := max(4, 262144 / size)
		table := system.Table_To_Read(Reading){records = raw_data(large), count = u64(size), capacity = u64(size)}
		least := max(u64)
		for _ in 0 ..< 5 {
			start := system.nanoseconds()
			for _ in 0 ..< repeat {
				intrinsics.volatile_store(&sink, direct(&table))
			}
			least = min(least, (system.nanoseconds() - start) / u64(repeat))
		}
		measures[.Direct][column] = max(least, 1)
		for way in ([3]Measure_Way{.Region, .Memory_Object, .Service_Region}) {
			connection := way == .Service_Region ? &service : &host
			if !ways_ready[way == .Service_Region ? .Service : .Call_Host] {
				continue
			}
			arguments := [1]isolated.Argument{}
			arguments[0].table = {records = bytes_of(raw_data(large), size * 40), count = u64(size)}
			if way == .Memory_Object {
				arguments[0].table.memory = u64(large_memory)
			}
			calls := way == .Memory_Object ? max(4, repeat / 16) : max(4, repeat / 4)
			least = max(u64)
			for _ in 0 ..< 3 {
				start := system.nanoseconds()
				ok := true
				for _ in 0 ..< calls {
					result, status := system.call_isolated(connection, sample_file, index, arguments[:])
					intrinsics.volatile_store(&sink, result)
					ok &&= status == .Ok
				}
				if !ok {
					least = 0
					break
				}
				least = min(least, (system.nanoseconds() - start) / u64(calls))
			}
			measures[way][column] = least
		}
	}
	_ = function
}
sink: i64

WIDTH :: 1000
HEIGHT :: 680
LINE :: 24
NAME_X :: 40 // The column of the names, in a card.
ANSWER_X :: 312 // The first column of the answers.
COLUMN_WIDTH :: 224

card :: proc "contextless" (canvas: graphics.Canvas, x, y, width, height: int, title, caption: string, accent: graphics.Color) {
	graphics.block(canvas, x, y, width, height, graphics.COLOR_CARD_TOP, graphics.COLOR_CARD_BOTTOM)
	graphics.outline(canvas, x, y, width, height, 1, graphics.mix(graphics.COLOR_CARD_BOTTOM, accent, 72))
	graphics.fill(canvas, x, y, 4, height, accent)
	graphics.text(canvas, x + 16, y + 12, title, accent)
	graphics.text(canvas, x + width - 16 - graphics.text_width(caption), y + 12, caption, graphics.COLOR_DIM)
}

// mark draws the square of an answer: the color of a program when it is
// the expected answer, the color "failed" when it is not.
mark :: proc "contextless" (canvas: graphics.Canvas, x, y: int, right: bool) {
	graphics.fill(canvas, x, y + 4, 8, 8, right ? graphics.COLOR_PROGRAM : graphics.COLOR_FAILED)
}

draw :: proc "contextless" (canvas: graphics.Canvas) {
	graphics.clear(canvas, graphics.COLOR_BACKGROUND)
	for y := 12; y < HEIGHT; y += 24 {
		for x := 12; x < WIDTH; x += 24 {
			graphics.fill(canvas, x, y, 2, 2, graphics.COLOR_POINT)
		}
	}
	// The cases: one row for each, one column for each way.
	y := 16
	height := 48 + (case_count + 1) * LINE
	card(canvas, 16, y, WIDTH - 32, height, "one description, three ways to call", "module sample, the same arguments", graphics.COLOR_KERNEL)
	y += 40
	graphics.text(canvas, NAME_X, y, "export  table", graphics.COLOR_DIM)
	for way in Way {
		graphics.text(canvas, ANSWER_X + int(way) * COLUMN_WIDTH, y, way_names[way], graphics.COLOR_DIM)
	}
	y += LINE
	for &item in cases[:case_count] {
		graphics.text(canvas, NAME_X, y, item.name, graphics.COLOR_TEXT)
		for way in Way {
			answer := &item.answers[way]
			x := ANSWER_X + int(way) * COLUMN_WIDTH
			mark(canvas, x, y, answer.right)
			graphics.text(canvas, x + 16, y, answer_text(answer), answer.right ? graphics.COLOR_TEXT : graphics.COLOR_FAILED)
		}
		y += LINE
	}
	// The hostile cases, with their answers.
	y = 16 + height + 16
	hostile_height := 48 + hostile_count * LINE
	card(canvas, 16, y, WIDTH - 32, hostile_height, "a hostile caller, through the call host", "isolated.decode, export_serve", graphics.COLOR_FAILED)
	row := y + 40
	for &item in hostile[:hostile_count] {
		mark(canvas, NAME_X, row, item.answer.right)
		graphics.text(canvas, NAME_X + 16, row, item.name, graphics.COLOR_TEXT)
		graphics.text(canvas, ANSWER_X + 16, row, answer_text(&item.answer), item.answer.right ? graphics.COLOR_TEXT : graphics.COLOR_FAILED)
		row += LINE
	}
	// The measures.
	y += hostile_height + 16
	card(canvas, 16, y, WIDTH - 32, 48 + 5 * LINE, "nanoseconds for one call of sum_values", "rows of 40 bytes, the least of several runs", graphics.COLOR_MEMORY)
	row = y + 40
	graphics.text(canvas, NAME_X, row, "the way", graphics.COLOR_DIM)
	sizes := SIZES
	buffer: [24]u8
	for size, column in sizes {
		graphics.text(canvas, ANSWER_X + 16 + column * 160, row, system.format(buffer[:], u64(size), " rows"), graphics.COLOR_DIM)
	}
	row += LINE
	for way in Measure_Way {
		graphics.text(canvas, NAME_X, row, measure_names[way], graphics.COLOR_TEXT)
		for column in 0 ..< 3 {
			value := measures[way][column]
			graphics.text(canvas, ANSWER_X + 16 + column * 160, row, value == 0 ? "does not fit" : system.format(buffer[:], value), value == 0 ? graphics.COLOR_DIM : graphics.COLOR_TEXT)
		}
		row += LINE
	}
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, opened := display.open(ctx, WIDTH, HEIGHT, "tables")
	if !opened {
		system.stop(1)
	}
	image_memory = ctx.handles[system.GRANT_IMAGE]
	if address, status := system.memory_map(image_memory, {}); status == .Ok {
		image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	}
	sample_file = system.image_find(image, "sample")

	// The direct way: the module in this program.
	space = {source = {image = image}, next = op.MODULE_BASE}
	load_error: module.Load_Error
	if place, loaded := system.module_space_load(&space, sample_file, &load_error); loaded {
		sample_base = space.modules[place].base
		ways_ready[.Direct] = true
	}
	// The call host: the module in a program of its own.
	status: system.Status
	if host, status = system.call_host_start(image, image_memory, sample_file, "sample host", &load_error); status == .Ok {
		ways_ready[.Call_Host] = true
	} else {
		buffer: [256]u8
		writer := system.Writer{buffer = buffer[:]}
		system.load_error_text(&writer, &load_error)
		system.log("tables: the call host did not start: status ", u64(status), "; ", system.written(&writer))
	}
	// The service: the root service starts sample as a program.
	if ring_handle := ctx.handles[system.GRANT_ROOT]; ring_handle != 0 {
		if requests, status = system.ring_open(ring_handle); status == .Ok {
			if service, status = system.service_connection(&requests, 1, "sample"); status == .Ok {
				ways_ready[.Service] = true
			}
		}
	}
	system.log("tables: the ways: direct ", ways_ready[.Direct] ? "ready" : "refused", ", call host ", ways_ready[.Call_Host] ? "ready" : "refused", ", service ", ways_ready[.Service] ? "ready" : "refused")

	// The table of the measures: 65536 readings in a memory object.
	pages := u64(LARGE_COUNT * size_of(Reading) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	if large_memory, status = system.memory_create(pages); status == .Ok {
		if address, map_status := system.memory_map(large_memory); map_status == .Ok {
			large = ([^]Reading)(address)[:LARGE_COUNT]
			for &reading, index in large {
				reading = {sensor = i64(index), value = i64(index)}
			}
		}
	}

	run_cases()
	run_hostile()
	if len(large) != 0 {
		measure()
	}
	wrong := 0
	for &item in cases[:case_count] {
		for way in Way {
			if !item.answers[way].right {
				wrong += 1
				system.log("tables: wrong answer: ", item.name, ", ", way_names[way], ": ", answer_text(&item.answers[way]))
			}
		}
	}
	for &item in hostile[:hostile_count] {
		if !item.answer.right {
			wrong += 1
			system.log("tables: wrong answer: ", item.name, ": ", answer_text(&item.answer))
		}
	}
	for &item in hostile[:hostile_count] {
		system.log("tables: ", item.name, ": ", answer_text(&item.answer))
	}
	for way in Measure_Way {
		system.log("tables: sum_values, ", measure_names[way], ": ", measures[way][0], " ns for 64 rows, ", measures[way][1], " ns for 1024 rows, ", measures[way][2], " ns for 65536 rows (0: refused)")
	}
	if wrong == 0 {
		system.log("tables: ok, ", u64(case_count), " cases in 3 ways and ", u64(hostile_count), " hostile cases")
	}

	for {
		draw(window.canvas)
		display.present(&window)
		display.wait(&window)
		for _ in display.next_event(&window) {
		}
	}
}
