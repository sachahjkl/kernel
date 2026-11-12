// The interface package as a module (docs/INTERFACE.md, section 7; the
// test of the claim "the functions are written so the package can become a
// module later with the same calls"). Each export calls one function of
// support/interface over two tables in memory of the caller: the draw
// table (Table of Draw_Record, Append) and the text table (Bytes, Append).
// The module holds no state of the program: a frame of the package is made
// over the two tables for the time of one call.
package interface_module

import "base:intrinsics"
import "contract:glyph_cache"
import "contract:settings"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:system"

// A rectangle of the surface: the place of an element.
Area :: struct {
	x:      i64,
	y:      i64,
	width:  i64,
	height: i64,
}

// A line with a name and a value.
Label_Value :: struct {
	x:       i64,
	y:       i64,
	width:   i64,
	height:  i64,
	value_x: i64, // 0: the value at the right of the area.
	color:   i64, // The color of the value.
}

// A value against a maximum, in a color.
Bar_Value :: struct {
	x:       i64,
	y:       i64,
	width:   i64,
	height:  i64,
	value:   i64,
	maximum: i64,
	color:   i64,
}

// A damage rectangle: right and bottom are not in it.
Damage_Rectangle :: struct {
	left:   i64,
	top:    i64,
	right:  i64,
	bottom: i64,
}

// The shape of the pixels of a canvas: 4 bytes for each pixel.
Canvas_Shape :: struct {
	width:  i64,
	height: i64,
	stride: i64, // Pixels from one line to the next.
}

Draw_Records_To_Append :: system.Table_To_Append(interface.Draw_Record)

// The records and the text bytes that one element call can make: the
// element is built into an element frame of these sizes, then appended to
// the tables of the caller. An element larger than this is refused with -1.
ELEMENT_RECORD_CAPACITY :: 64
ELEMENT_TEXT_CAPACITY :: 4096

// One element call: a frame of the package over a draw table and a text
// table of its own, on the stack of the export. The tables of the caller
// are never the table of the package: the count of an Append table is the
// count of the full answer across calls (docs/MODULE_CONTRACT.md, "Did not
// fit, across calls"), which the package does not count; the module counts
// it when it appends (decision of the coordinator after the second hostile
// read: before, a count over the capacity on entry was a mark that the
// contract refused, and it worked in a direct call only).
@(private)
Element_Frame :: struct {
	records: [ELEMENT_RECORD_CAPACITY]interface.Draw_Record,
	text:    [ELEMENT_TEXT_CAPACITY]u8,
	table:   interface.Draw_Table,
	frame:   interface.Frame,
}

// The interface state and the input of each frame: empty. The elements of
// this module take no input and never write them, so the module keeps no
// state of a program in them; one empty record serves each call, with no
// zero bytes to write at each call.
@(private)
no_state: interface.Interface_State
@(private)
no_input: interface.Input

// The interface font of the program that runs the module, validated once:
// in a direct call the caller, whose starter maps the caches at their
// fixed ranges; in an isolated call the call host, which has none, so its
// elements draw in the font of the cells. The state: 0 not looked at yet,
// 1 given, 2 none. Two threads that look at once validate the same caches
// and write the same values.
@(private)
module_interface_font: display.Interface_Font
@(private)
module_interface_font_state: u32

// A context with no bit set: what a host test reads, as it has no
// context of a program.
@(private)
no_context: system.Context

@(private)
interface_font_of_program :: proc "contextless" () -> ^display.Interface_Font {
	state := intrinsics.atomic_load_explicit(&module_interface_font_state, .Acquire)
	if state == 0 {
		context_record := &no_context
		when ODIN_OS == .Freestanding {
			context_record = system.context_record()
		}
		weights := [2]settings.Glyph_Cache{.Interface, .Interface_Bold}
		caches: [2]glyph_cache.Cache
		state = 1
		for weight, index in weights {
			problem: glyph_cache.Problem
			caches[index], problem = settings.glyph_cache_open(&context_record.values, weight)
			if problem.kind != .None || caches[index].header.flags & glyph_cache.FLAG_PROPORTIONAL == 0 {
				state = 2
			}
		}
		if state == 1 {
			module_interface_font = {regular = caches[0], bold = caches[1]}
		}
		intrinsics.atomic_store_explicit(&module_interface_font_state, state, .Release)
	}
	return state == 1 ? &module_interface_font : nil
}

// The most records or bytes of a table of a caller, its count included: no
// count times a size wraps, and a count holds in the i64 of the result.
@(private)
TABLE_LIMIT :: u64(1) << 40

// element_frame_begin starts one element call. It gives false for a table
// over TABLE_LIMIT (a capacity of 2^63 is a negative int).
@(private)
element_frame_begin :: proc "contextless" (element: ^Element_Frame, drawn: ^Draw_Records_To_Append, text: ^system.Bytes_To_Append) -> bool {
	if drawn.capacity > TABLE_LIMIT || drawn.count > TABLE_LIMIT || text != nil && (text.capacity > TABLE_LIMIT || text.count > TABLE_LIMIT) {
		return false
	}
	element.table = {records = element.records[:], text = element.text[:], interface_font = interface_font_of_program()}
	element.frame = {table = &element.table, state = &no_state, input = &no_input}
	return true
}

// element_frame_append_to_caller appends the records and the text of one
// element to the tables of the caller, by the Append rule: what fits is
// written, the count grows by all of it, and nothing is written at or after
// a capacity. A text record names its bytes at the count of the text table
// on entry: when they did not fit, the record names bytes past the text
// table, and the readers of a draw table check each range. The result is
// the count of draw records of the full answer, or -1 for an element larger
// than the element frame, or a text table past 2^32 bytes (text_start is a
// u32).
@(private)
element_frame_append_to_caller :: proc "contextless" (element: ^Element_Frame, drawn: ^Draw_Records_To_Append, text: ^system.Bytes_To_Append) -> i64 {
	if element.table.full {
		return -1
	}
	text_base := text != nil ? text.count : 0
	if text_base + u64(element.table.text_count) > u64(max(u32)) {
		return -1
	}
	for record in element.records[:element.table.record_count] {
		placed := record
		if interface.is_text_kind(placed.kind) {
			placed.text_start += u32(text_base)
		}
		system.table_append(drawn, placed)
	}
	if text != nil {
		system.bytes_append(text, element.text[:element.table.text_count])
	}
	return i64(min(drawn.count, u64(max(i64))))
}

@(private)
area_of :: proc "contextless" (area: Area) -> interface.Area {
	return {int(area.x), int(area.y), int(area.width), int(area.height)}
}

// draw_background appends the background of the rules on an area: one color and the grid of points. The result is the count of draw records of the full answer (larger than the capacity: it did not fit), or -1 for a table over 2^40 records or bytes or an element over 64 records or 4096 bytes of text.
@(export, link_name = "draw_background")
draw_background :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), area: ^Area) -> i64 {
	element: Element_Frame
	if !element_frame_begin(&element, drawn, nil) {
		return -1
	}
	interface.background(&element.frame, area_of(area^))
	return element_frame_append_to_caller(&element, drawn, nil)
}

// draw_card appends the frame of one subject: its border, its surface, its title in the accent and its caption. It writes the area of its content in the one row of `area`. The result is the count of draw records of the full answer (larger than the capacity: it did not fit), or -1 for a table over 2^40 records or bytes or an element over 64 records or 4096 bytes of text.
@(export, link_name = "draw_card")
draw_card :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), text: ^system.Bytes_To_Append, area: ^system.Table_To_Change(Area), title: ^string, caption: ^string, accent: i64) -> i64 {
	element: Element_Frame
	if !element_frame_begin(&element, drawn, text) {
		return -1
	}
	if area.count == 1 {
		// One copy of the record: the rule of an export (docs/MODULE_CONTRACT.md).
		content := interface.card(&element.frame, area_of(intrinsics.volatile_load(&area.records[0])), title^, caption^, graphics.Color(accent))
		area.records[0] = {i64(content.x), i64(content.y), i64(content.width), i64(content.height)}
	}
	return element_frame_append_to_caller(&element, drawn, text)
}

// draw_cell_text appends a text in a cell of a line, at the left, or at the right when `right` is not 0. The result is the count of draw records of the full answer (larger than the capacity: it did not fit), or -1 for a table over 2^40 records or bytes or an element over 64 records or 4096 bytes of text.
@(export, link_name = "draw_cell_text")
draw_cell_text :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), text: ^system.Bytes_To_Append, cell: ^Area, words: ^string, color: i64, right: i64) -> i64 {
	element: Element_Frame
	if !element_frame_begin(&element, drawn, text) {
		return -1
	}
	interface.cell_text(&element.frame, area_of(cell^), words^, graphics.Color(color), right != 0 ? .Right : .Left)
	return element_frame_append_to_caller(&element, drawn, text)
}

// draw_label_value_line appends a name in the dim color and its value. The result is the count of draw records of the full answer (larger than the capacity: it did not fit), or -1 for a table over 2^40 records or bytes or an element over 64 records or 4096 bytes of text.
@(export, link_name = "draw_label_value_line")
draw_label_value_line :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), text: ^system.Bytes_To_Append, line: ^Label_Value, label: ^string, value: ^string) -> i64 {
	element: Element_Frame
	if !element_frame_begin(&element, drawn, text) {
		return -1
	}
	interface.label_value_line(&element.frame, {int(line.x), int(line.y), int(line.width), int(line.height)}, label^, value^, graphics.Color(line.color), int(line.value_x))
	return element_frame_append_to_caller(&element, drawn, text)
}

// draw_table_band appends the band under line `index` of a table: every second line has the surface of a card. The result is the count of draw records of the full answer (larger than the capacity: it did not fit), or -1 for a table over 2^40 records or bytes or an element over 64 records or 4096 bytes of text.
@(export, link_name = "draw_table_band")
draw_table_band :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), area: ^Area, index: i64) -> i64 {
	element: Element_Frame
	if !element_frame_begin(&element, drawn, nil) {
		return -1
	}
	interface.table_band(&element.frame, area_of(area^), int(index))
	return element_frame_append_to_caller(&element, drawn, nil)
}

// draw_bar appends a value against a maximum: the track and the full part. The result is the count of draw records of the full answer (larger than the capacity: it did not fit), or -1 for a table over 2^40 records or bytes or an element over 64 records or 4096 bytes of text.
@(export, link_name = "draw_bar")
draw_bar :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), bar: ^Bar_Value) -> i64 {
	element: Element_Frame
	if !element_frame_begin(&element, drawn, nil) {
		return -1
	}
	interface.bar(&element.frame, {int(bar.x), int(bar.y), int(bar.width), int(bar.height)}, u64(max(bar.value, 0)), u64(max(bar.maximum, 0)), graphics.Color(bar.color))
	return element_frame_append_to_caller(&element, drawn, nil)
}

// draw_table_to_read_of makes a draw table of the package over a Read
// table and its text. ok is false when a count passes TABLE_LIMIT. The
// module does not check the text range of each record here: the records
// are in memory that the caller can change during the call, so a check
// here and a read later in the package would read two values. The package
// checks each range where it reads it, on its one copy of the record
// (support/interface, difference.odin and execute.odin; finding W-new of the
// second hostile read).
@(private)
draw_table_to_read_of :: proc "contextless" (records: ^system.Table_To_Read(interface.Draw_Record), text: ^system.Bytes_To_Read) -> (table: interface.Draw_Table, ok: bool) {
	if records.count > TABLE_LIMIT || text.count > TABLE_LIMIT {
		return {}, false
	}
	return {records = records.records[:records.count], record_count = int(records.count), text = text.bytes[:text.count], text_count = int(text.count), interface_font = interface_font_of_program()}, true
}

// damage_by_difference gives the rectangles of the surface that differ between the draw table before and the draw table now. The result is a Table of at most 8 rectangles, or -1 for a table over 2^40 records or bytes. A text record that names bytes past its text table differs from each record: its rectangle is damaged.
@(export, link_name = "damage_by_difference")
damage_by_difference :: proc "c" (before: ^system.Table_To_Read(interface.Draw_Record), before_text: ^system.Bytes_To_Read, now: ^system.Table_To_Read(interface.Draw_Record), now_text: ^system.Bytes_To_Read, result: ^[]Damage_Rectangle) -> i64 {
	before_table, before_ok := draw_table_to_read_of(before, before_text)
	now_table, now_ok := draw_table_to_read_of(now, now_text)
	if !before_ok || !now_ok {
		return -1
	}
	damage: interface.Damage
	interface.damage_by_difference(&before_table, &now_table, &damage)
	for rectangle, index in damage.rectangles[:damage.count] {
		if index < len(result) {
			result[index] = {i64(rectangle.left), i64(rectangle.top), i64(rectangle.right), i64(rectangle.bottom)}
		}
	}
	return i64(damage.count)
}

// execute_in_rectangles draws the records of a draw table into the pixels of a canvas, in each rectangle, cut to it. The pixels are the memory of the caller: no copy in a direct call. The result is the count of rectangles, or -1 for a canvas shape that the pixels do not hold. A text record that names bytes past its text table draws nothing.
@(export, link_name = "execute_in_rectangles")
execute_in_rectangles :: proc "c" (now: ^system.Table_To_Read(interface.Draw_Record), now_text: ^system.Bytes_To_Read, rectangles: ^system.Table_To_Read(Damage_Rectangle), pixels: ^system.Bytes_To_Change, shape: ^Canvas_Shape) -> i64 {
	// No product wraps (finding F2 of the hostile read): the stride is
	// compared with the pixels of one line that the bytes hold.
	if shape.width <= 0 || shape.height <= 0 || shape.stride < shape.width || u64(shape.stride) > pixels.count / 4 / u64(shape.height) {
		return -1
	}
	table, ok := draw_table_to_read_of(now, now_text)
	if !ok || rectangles.count > TABLE_LIMIT {
		return -1
	}
	canvas := graphics.Canvas{pixels = ([^]graphics.Color)(pixels.bytes), width = int(shape.width), height = int(shape.height), stride = int(shape.stride)}
	for rectangle in system.table_records(rectangles) {
		interface.execute_in_rectangle(&table, canvas, {int(rectangle.left), int(rectangle.top), int(rectangle.right), int(rectangle.bottom)})
	}
	return i64(rectangles.count)
}
