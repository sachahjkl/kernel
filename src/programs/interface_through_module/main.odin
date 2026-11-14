// The interface package as a module, for one program (docs/INTERFACE.md,
// section 7). This program builds the same frame in two ways: through the
// exports of the module interface_module, which it imports (each call
// passes the draw table and the text table of this program as table
// parameters, with no copy), and with the package src/library/support/interface
// compiled in. It compares the two draw tables and measures the two builds.
// It draws its window through the drawing module, which it imports too:
// the damage by difference and the draw of the records into its pixels are
// the two exports of that module. Then it draws one frame two times, with
// the package compiled in and through the drawing module, into two
// canvases of its own, and compares their bytes: the package draws with
// the text settings that this program loaded, the module with those that
// the module loaded.
//
// **What it is for.** It shows that one code module can be a library in
// another program with no loss: the [interface package](term:interface-package)
// as the module `interface_module` gives the same
// [draw table](term:draw-table) as the package compiled in, and a
// [table parameter](term:table-parameter) passes the tables of the caller
// with no copy. The measures give the cost of a call through an import.
//
// **What a reader sees.** Start it from the menu of the programs, or with
// `start("interface_through_module")` in the console. The window is drawn
// through the module. The log gets the times of the two builds, the time
// of the damage and the drawing through the module and the size of its
// code, the case of a draw table of 16 places that is too small, then
// `interface_through_module: ok, the two draw tables are equal`, or
// `wrong: the two draw tables differ`, then the line of the two canvases,
// which ends with `the same bytes: as it must`.
//
// **Its grant**: **Image**: it reads the size of the code of
// `interface_module` in the boot image.
package interface_through_module

import "contract:errors"
import "support:display"
import "support:graphics"
import "support:interface"
import module "contract:module"
import "support:system"

// The records of the module, as this program declares them: the layout is
// the description.
Area :: struct {
	x, y, width, height: i64,
}
Label_Value :: struct {
	x, y, width, height: i64,
	value_x:             i64,
	color:               i64,
}
Bar_Value :: struct {
	x, y, width, height: i64,
	value, maximum:      i64,
	color:               i64,
}
Damage_Rectangle :: struct {
	left, top, right, bottom: i64,
}
Canvas_Shape :: struct {
	width, height, stride: i64,
	fill_background:       i64,
	background:            i64,
}

Drawn :: system.Table_To_Append(interface.Draw_Record)

foreign _ {
	draw_background :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), area: ^Area) -> i64 ---
	draw_card :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), text: ^system.Bytes_To_Append, area: ^system.Table_To_Change(Area), title: ^string, caption: ^string, accent: i64) -> i64 ---
	draw_cell_text :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), text: ^system.Bytes_To_Append, cell: ^Area, words: ^string, color: i64, right: i64) -> i64 ---
	draw_label_value_line :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), text: ^system.Bytes_To_Append, line: ^Label_Value, label: ^string, value: ^string) -> i64 ---
	draw_table_band :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), area: ^Area, index: i64) -> i64 ---
	draw_bar :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), bar: ^Bar_Value) -> i64 ---
	// The two exports of the drawing module.
	damage_of_draw_table_7 :: proc "c" (before: ^system.Table_To_Read(interface.Draw_Record), before_text: ^system.Bytes_To_Read, now: ^system.Table_To_Read(interface.Draw_Record), now_text: ^system.Bytes_To_Read, result: ^[]Damage_Rectangle, error: ^errors.Error_Record) -> i64 ---
	execute_draw_table_7 :: proc "c" (now: ^system.Table_To_Read(interface.Draw_Record), now_text: ^system.Bytes_To_Read, rectangles: ^system.Table_To_Read(Damage_Rectangle), pixels: ^system.Bytes_To_Change, shape: ^Canvas_Shape, error: ^errors.Error_Record) -> i64 ---
}

WIDTH :: 816
HEIGHT :: 336
LINE :: interface.TABLE_LINE
RECORD_CAPACITY :: 256
TEXT_CAPACITY :: 4096

// What the frame shows: the measures of the frame before.
Shown :: struct {
	calls:            u64, // Element calls through the module in one frame.
	module_time:      u64, // Nanoseconds of one build through the module.
	package_time:     u64, // Nanoseconds of one build with the package compiled in.
	equal:            bool,
	records:          u64,
	text_bytes:       u64,
	module_code:      u64, // Bytes of code of interface_module.
	draw_time:        u64, // Nanoseconds: the damage and the execution through the module.
}
shown: Shown

// The two tables of the frame through the module, and of the frame before.
records_now, records_before: [RECORD_CAPACITY]interface.Draw_Record
text_now, text_before: [TEXT_CAPACITY]u8
drawn: Drawn
text: system.Bytes_To_Append
calls: u64

// The tables of the frame with the package compiled in.
package_records: [RECORD_CAPACITY]interface.Draw_Record
package_text: [TEXT_CAPACITY]u8

COLOR_MODULE :: graphics.COLOR_MEMORY
COLOR_PACKAGE :: graphics.COLOR_KERNEL

number_text :: proc "contextless" (buffer: []u8, value: u64) -> string {
	return system.format(buffer, value)
}

// The layout: the same places in the two ways.
CONTENT :: interface.Area{8 + graphics.CARD_MARGIN, 8 + graphics.CARD_TITLE, WIDTH - 16 - 2 * graphics.CARD_MARGIN, HEIGHT - 16 - graphics.CARD_TITLE - 8}
line_area :: proc "contextless" (number: int) -> interface.Area {
	return {CONTENT.x, CONTENT.y + number * LINE, CONTENT.width, LINE}
}
CELL_X :: [4]int{0, 200, 520, 640}
CELL_WIDTH :: [4]int{184, 304, 104, 112}
cell_area :: proc "contextless" (line: interface.Area, column: int) -> interface.Area {
	xs, widths := CELL_X, CELL_WIDTH
	return {line.x + xs[column], line.y, widths[column], line.height}
}
to_area :: proc "contextless" (area: interface.Area) -> Area {
	return {i64(area.x), i64(area.y), i64(area.width), i64(area.height)}
}

TITLE :: "THE INTERFACE AS A MODULE"
CAPTION :: "interface_module: the draw table and the text table are parameters"

// The texts of one frame, made once: the two builds draw the same bytes.
Texts :: struct {
	buffers: [8][24]u8,
	calls, module_time, package_time, per_call, records, code, draw_time: string,
	equal: string,
}

texts_of :: proc "contextless" (texts: ^Texts) {
	texts.calls = number_text(texts.buffers[0][:], shown.calls)
	texts.module_time = number_text(texts.buffers[1][:], shown.module_time)
	texts.package_time = number_text(texts.buffers[2][:], shown.package_time)
	texts.per_call = number_text(texts.buffers[3][:], shown.calls == 0 ? 0 : (max(shown.module_time, shown.package_time) - shown.package_time) / shown.calls)
	texts.records = system.format(texts.buffers[4][:], shown.records, " records, ", shown.text_bytes, " bytes")
	texts.code = system.format(texts.buffers[5][:], shown.module_code, " bytes")
	texts.draw_time = number_text(texts.buffers[6][:], shown.draw_time)
	texts.equal = shown.equal ? "equal" : "different"
}

// build_through_module builds the frame with the exports of the module.
build_through_module :: proc "contextless" (texts: ^Texts) {
	drawn = {records = &records_now[0], count = 0, capacity = record_capacity_of_build}
	text = {bytes = &text_now[0], count = 0, capacity = TEXT_CAPACITY}
	calls = 0
	whole := Area{0, 0, WIDTH, HEIGHT}
	draw_background(&drawn, &whole)
	card_area := [1]Area{{8, 8, WIDTH - 16, HEIGHT - 16}}
	place := system.Table_To_Change(Area){records = &card_area[0], count = 1, capacity = 1}
	title, caption := TITLE, CAPTION
	draw_card(&drawn, &text, &place, &title, &caption, i64(graphics.COLOR_KERNEL))
	calls += 2
	sentence := "each element is one call through an import slot; the module keeps no state of this program."
	first := to_area(line_area(0))
	draw_cell_text(&drawn, &text, &first, &sentence, i64(graphics.COLOR_DIM), 0)
	headers := [4]string{"way", "one frame, ns", "", "ns per call"}
	header_line := line_area(2)
	for column in 0 ..< 4 {
		cell := to_area(cell_area(header_line, column))
		draw_cell_text(&drawn, &text, &cell, &headers[column], i64(graphics.COLOR_DIM), column >= 2 ? 1 : 0)
	}
	calls += 5
	names := [2]string{"through the module", "compiled in"}
	times := [2]string{texts.module_time, texts.package_time}
	per := [2]string{texts.per_call, ""}
	values := [2]u64{shown.module_time, shown.package_time}
	colors := [2]i64{i64(COLOR_MODULE), i64(COLOR_PACKAGE)}
	for row in 0 ..< 2 {
		line := line_area(3 + row)
		band := Area{i64(line.x - 8), i64(line.y), i64(line.width + 16), i64(line.height)}
		draw_table_band(&drawn, &band, i64(row))
		cell := to_area(cell_area(line, 0))
		draw_cell_text(&drawn, &text, &cell, &names[row], colors[row], 0)
		bar_cell := cell_area(line, 1)
		bar := Bar_Value{i64(bar_cell.x), i64(bar_cell.y + 8), i64(bar_cell.width), 8, i64(values[row]), i64(max(values[0], values[1])), colors[row]}
		draw_bar(&drawn, &bar)
		cell = to_area(cell_area(line, 2))
		draw_cell_text(&drawn, &text, &cell, &times[row], i64(graphics.COLOR_TEXT), 1)
		cell = to_area(cell_area(line, 3))
		draw_cell_text(&drawn, &text, &cell, &per[row], i64(graphics.COLOR_TEXT), 1)
		calls += 5
	}
	labels := [4]string{"element calls in one frame", "the two draw tables", "code of interface_module", "damage and drawing, ns"}
	answers := [4]string{texts.calls, texts.equal, texts.code, texts.draw_time}
	details := [4]string{"", texts.records, "one copy, shared", ""}
	for index in 0 ..< 4 {
		line := line_area(6 + index)
		label_line := Label_Value{i64(line.x), i64(line.y), i64(line.width), i64(line.height), 320, i64(graphics.COLOR_TEXT)}
		draw_label_value_line(&drawn, &text, &label_line, &labels[index], &answers[index])
		cell := Area{i64(line.x + 440), i64(line.y), i64(line.width - 440), i64(line.height)}
		draw_cell_text(&drawn, &text, &cell, &details[index], i64(graphics.COLOR_DIM), 0)
		calls += 2
	}
}

// build_compiled_in builds the same frame with the package.
build_compiled_in :: proc "contextless" (texts: ^Texts, table: ^interface.Draw_Table) {
	state: interface.Interface_State
	input: interface.Input
	frame := interface.frame_begin(table, &state, &input)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	interface.card(&frame, {8, 8, WIDTH - 16, HEIGHT - 16}, TITLE, CAPTION, graphics.COLOR_KERNEL)
	interface.cell_text(&frame, line_area(0), "each element is one call through an import slot; the module keeps no state of this program.", graphics.COLOR_DIM)
	headers := [4]string{"way", "one frame, ns", "", "ns per call"}
	for column in 0 ..< 4 {
		interface.cell_text(&frame, cell_area(line_area(2), column), headers[column], graphics.COLOR_DIM, column >= 2 ? .Right : .Left)
	}
	names := [2]string{"through the module", "compiled in"}
	times := [2]string{texts.module_time, texts.package_time}
	per := [2]string{texts.per_call, ""}
	values := [2]u64{shown.module_time, shown.package_time}
	colors := [2]graphics.Color{COLOR_MODULE, COLOR_PACKAGE}
	for row in 0 ..< 2 {
		line := line_area(3 + row)
		interface.table_band(&frame, {line.x - 8, line.y, line.width + 16, line.height}, row)
		interface.cell_text(&frame, cell_area(line, 0), names[row], colors[row])
		bar_cell := cell_area(line, 1)
		interface.bar(&frame, {bar_cell.x, bar_cell.y + 8, bar_cell.width, 8}, values[row], max(values[0], values[1]), colors[row])
		interface.cell_text(&frame, cell_area(line, 2), times[row], graphics.COLOR_TEXT, .Right)
		interface.cell_text(&frame, cell_area(line, 3), per[row], graphics.COLOR_TEXT, .Right)
	}
	labels := [4]string{"element calls in one frame", "the two draw tables", "code of interface_module", "damage and drawing, ns"}
	answers := [4]string{texts.calls, texts.equal, texts.code, texts.draw_time}
	details := [4]string{"", texts.records, "one copy, shared", ""}
	for index in 0 ..< 4 {
		line := line_area(6 + index)
		interface.label_value_line(&frame, line, labels[index], answers[index], graphics.COLOR_TEXT, 320)
		interface.cell_text(&frame, {line.x + 440, line.y, line.width - 440, line.height}, details[index], graphics.COLOR_DIM)
	}
}

// tables_equal compares the draw table through the module with the draw
// table of the package: the same records, and the same text bytes.
tables_equal :: proc "contextless" (table: ^interface.Draw_Table) -> bool {
	if u64(table.record_count) != drawn.count || u64(table.text_count) != text.count {
		return false
	}
	for index in 0 ..< table.record_count {
		if table.records[index] != records_now[index] {
			return false
		}
	}
	return string(table.text[:table.text_count]) == string(text_now[:text.count])
}

// code_bytes gives the bytes of the segments of a module that execute.
code_bytes :: proc "contextless" (file: []u8) -> (bytes: u64) {
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		if .Execute in segment.flags {
			bytes += segment.memory_size
		}
	}
	return bytes
}

drawn_before: bool

// The capacity of the draw table of a build: RECORD_CAPACITY, or less for
// the case of a frame that does not fit.
record_capacity_of_build: u64 = RECORD_CAPACITY

// kept_counts gives the records and the bytes of the frame that the tables
// hold: a table that did not fit has a count larger than its capacity, so
// the count as it comes is never an index.
kept_counts :: proc "contextless" () -> (records, bytes: u64) {
	return min(drawn.count, drawn.capacity), min(text.count, text.capacity)
}
before_count, before_text_count: u64

// present draws the frame through the module: the damage by difference
// with the frame before, then the records in each damage rectangle.
present :: proc "contextless" (window: ^display.Window) {
	start := system.nanoseconds()
	kept_records, kept_bytes := kept_counts()
	now_table := system.Table_To_Read(interface.Draw_Record){records = &records_now[0], count = kept_records, capacity = kept_records}
	now_text := system.Bytes_To_Read{bytes = &text_now[0], count = kept_bytes, capacity = kept_bytes}
	rectangles: [interface.DAMAGE_CAPACITY]Damage_Rectangle
	count: i64
	if !drawn_before || window.two {
		rectangles[0] = {0, 0, WIDTH, HEIGHT}
		count = 1
	} else {
		before_table := system.Table_To_Read(interface.Draw_Record){records = &records_before[0], count = before_count, capacity = before_count}
		before_bytes := system.Bytes_To_Read{bytes = &text_before[0], count = before_text_count, capacity = before_text_count}
		buffer := rectangles[:]
		count = min(damage_of_draw_table_7(&before_table, &before_bytes, &now_table, &now_text, &buffer, nil), interface.DAMAGE_CAPACITY)
		if count < 0 {
			// The module refused the tables: the whole frame.
			rectangles[0] = {0, 0, WIDTH, HEIGHT}
			count = 1
		}
	}
	canvas := window.canvas
	pixels := system.Bytes_To_Change{bytes = ([^]u8)(canvas.pixels), count = u64(canvas.stride * canvas.height * 4), capacity = u64(canvas.stride * canvas.height * 4)}
	shape := Canvas_Shape{width = i64(canvas.width), height = i64(canvas.height), stride = i64(canvas.stride), fill_background = 1, background = i64(graphics.COLOR_BACKGROUND)}
	damage := system.Table_To_Read(Damage_Rectangle){records = &rectangles[0], count = u64(count), capacity = u64(count)}
	execute_draw_table_7(&now_table, &now_text, &damage, &pixels, &shape, nil)
	shown.draw_time = system.nanoseconds() - start
	if count > 0 {
		left, top, right, bottom := rectangles[0].left, rectangles[0].top, rectangles[0].right, rectangles[0].bottom
		for rectangle in rectangles[1:count] {
			left, top, right, bottom = min(left, rectangle.left), min(top, rectangle.top), max(right, rectangle.right), max(bottom, rectangle.bottom)
		}
		display.present_rectangle(window, int(left), int(top), int(right - left), int(bottom - top))
	}
	copy(records_before[:kept_records], records_now[:kept_records])
	copy(text_before[:kept_bytes], text_now[:kept_bytes])
	before_count, before_text_count = kept_records, kept_bytes
	drawn_before = true
}

// The two canvases of the proof of the same pixels: the top left part of
// the frame, which holds the title, a sentence, the heads of the table and
// its two lines with their bars.
PROOF_WIDTH :: 320
PROOF_HEIGHT :: 144
package_pixels, module_pixels: [PROOF_WIDTH * PROOF_HEIGHT]graphics.Color

// canvases_compare draws one draw table two times: with the package
// compiled in, as a window drew a whole frame before the drawing module
// (the clear, then the execution), and through the export of the drawing
// module. It gives the count of the pixels that differ. The package draws
// with the text state of this program, the module with its own: the two
// are loaded from the same context by two copies of the code, and equal
// bytes say that they chose the same fonts. compared is false when the
// module refused the call: refused has its record.
canvases_compare :: proc "contextless" (table: ^interface.Draw_Table, refused: ^errors.Error_Record) -> (different: u64, compared: bool) {
	package_canvas := graphics.Canvas{pixels = raw_data(package_pixels[:]), width = PROOF_WIDTH, height = PROOF_HEIGHT, stride = PROOF_WIDTH}
	graphics.clear(package_canvas, graphics.COLOR_BACKGROUND)
	interface.execute(table, package_canvas)
	records := system.Table_To_Read(interface.Draw_Record){records = raw_data(table.records), count = u64(table.record_count), capacity = u64(len(table.records))}
	bytes := system.Bytes_To_Read{bytes = raw_data(table.text), count = u64(table.text_count), capacity = u64(len(table.text))}
	whole := [1]Damage_Rectangle{{0, 0, PROOF_WIDTH, PROOF_HEIGHT}}
	places := system.Table_To_Read(Damage_Rectangle){records = &whole[0], count = 1, capacity = 1}
	pixels := system.Bytes_To_Change{bytes = ([^]u8)(raw_data(module_pixels[:])), count = size_of(module_pixels), capacity = size_of(module_pixels)}
	shape := Canvas_Shape{width = PROOF_WIDTH, height = PROOF_HEIGHT, stride = PROOF_WIDTH, fill_background = 1, background = i64(graphics.COLOR_BACKGROUND)}
	if execute_draw_table_7(&records, &bytes, &places, &pixels, &shape, refused) < 0 {
		return 0, false
	}
	for index in 0 ..< len(package_pixels) {
		if package_pixels[index] != module_pixels[index] {
			different += 1
		}
	}
	return different, true
}

BUILDS :: 200

// entry builds the frame through the module and with the package, compares
// the two draw tables, measures both builds and the case of a table that is
// too small, writes the lines on the log, then draws its window through the
// module at each event until the program is stopped. With no window, it
// stops with the code 1.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "interface_through_module")
	if !ok {
		system.stop(1)
	}
	if address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {}); status == .Ok {
		image := ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
		shown.module_code = code_bytes(system.image_find(image, "interface_module"))
	}
	// The module, in a direct call, finds the interface font of this
	// program at its fixed ranges: the package compiled in takes the same
	// font, so the two tables can be equal.
	package_table := interface.Draw_Table{records = package_records[:], text = package_text[:], interface_font = display.interface_font_of()}
	texts: Texts
	// Three rounds: the measures of a round are the texts of the next.
	for _ in 0 ..< 3 {
		texts_of(&texts)
		least_module, least_package := max(u64), max(u64)
		for _ in 0 ..< BUILDS {
			start := system.nanoseconds()
			build_through_module(&texts)
			middle := system.nanoseconds()
			build_compiled_in(&texts, &package_table)
			least_module = min(least_module, middle - start)
			least_package = min(least_package, system.nanoseconds() - middle)
		}
		shown.module_time, shown.package_time = least_module, least_package
		shown.calls = calls
		shown.equal = tables_equal(&package_table)
		shown.records, shown.text_bytes = drawn.count, text.count
		present(&window)
	}
	system.log("interface_through_module: one frame of ", shown.records, " draw records and ", shown.text_bytes, " text bytes in ", shown.calls, " element calls: ", shown.module_time, " ns through the module, ", shown.package_time, " ns with the package compiled in, the least of ", u64(BUILDS))
	system.log("interface_through_module: the damage and the drawing through the module: ", shown.draw_time, " ns; interface_module has ", shown.module_code, " bytes of code")
	// A frame that does not fit: a draw table of 16 places. The module gives
	// the count of the full frame; the program draws the 16 records that it
	// holds, and says it.
	record_capacity_of_build = 16
	build_through_module(&texts)
	asked := drawn.count
	present(&window)
	// The count is the count of the full answer, across the element calls
	// (docs/MODULE_CONTRACT.md, "Did not fit, across calls"): the records of
	// the whole frame.
	system.log("interface_through_module: a draw table of 16 places: the frame did not fit, ", asked, " records asked, ", min(asked, 16), " drawn, ", asked == shown.records ? "the count of the full frame" : "not the count of the full frame")
	record_capacity_of_build = RECORD_CAPACITY
	build_through_module(&texts)
	present(&window)
	if shown.equal && drawn.count <= RECORD_CAPACITY && shown.records > 0 {
		system.log("interface_through_module: ok, the two draw tables are equal")
	} else {
		system.log("interface_through_module: wrong: the two draw tables differ")
	}
	// The proof of the same pixels in the machine: the frame of the package,
	// drawn by the package and by the drawing module.
	text_records: u64
	for record in package_table.records[:package_table.record_count] {
		if interface.is_text_kind(record.kind) {
			text_records += 1
		}
	}
	refused: errors.Error_Record
	if different, compared := canvases_compare(&package_table, &refused); !compared {
		system.log("interface_through_module: the drawing module refused the frame, with the error kind ", u64(refused.kind), " of the argument ", u64(refused.argument), ": WRONG")
	} else if different == 0 && text_records > 0 {
		system.log("interface_through_module: one frame drawn by the package compiled in and by the drawing module: ", u64(PROOF_WIDTH * PROOF_HEIGHT), " pixels, ", text_records, " text records, the same bytes: as it must")
	} else {
		system.log("interface_through_module: one frame drawn by the package compiled in and by the drawing module: ", different, " of ", u64(PROOF_WIDTH * PROOF_HEIGHT), " pixels differ, ", text_records, " text records: WRONG")
	}
	for {
		display.wait(&window)
		for _ in display.next_event(&window) {
		}
	}
}
