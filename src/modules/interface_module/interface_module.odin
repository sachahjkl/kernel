// The interface package as a module (docs/INTERFACE.md, section 7; the
// test of the claim "the functions are written so the package can become a
// module later with the same calls"). Each export calls one function of
// src/library/support/interface over two tables in memory of the caller: the draw
// table (Table of Draw_Record, Append) and the text table (Bytes, Append).
// The module holds no state of the program: a frame of the package is made
// over the two tables for the time of one call.
//
// **What it is for.** It checks a claim of the interface package by doing
// it: the same functions, called through the call form, give the same draw
// records as a call of the package in the program. The program
// `interface_through_module` loads it, draws its window through it, and
// compares the records and the time of each way.
//
// **The rule of the results** of each export that appends: the result is
// the count of draw records of the whole answer. A result larger than the
// capacity of the table says that the answer did not fit, and the caller
// gives a larger table. The result is -1 for a table over 2^40 records or
// bytes, or for one element over 64 records or 4096 bytes of text.
//
// **What it does not hold**: the damage of a frame and the draw of its
// records into pixels. They are the two exports of the drawing module
// (`src/modules/drawing`), which each program with a window imports. This
// module keeps the elements only: it shows what one element call through a
// border costs, and why the elements stay compiled into each program.
package interface_module

import "base:intrinsics"
import "modus:contract/glyph_cache"
import "modus:contract/settings"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/system"

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
// it when it appends. A count over the capacity on entry is not a mark of
// the module: such a mark works in a direct call only, and the contract
// refuses it.
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
