// The interface package as a module (docs/INTERFACE.md, section 7; the
// test of the claim "the functions are written so the package can become a
// module later with the same calls"). Each export calls one function of
// support/interface over two tables in memory of the caller: the draw
// table (Table of Draw_Record, Append) and the text table (Bytes, Append).
// The module holds no state of the program: a frame of the package is made
// over the two tables for the time of one call.
package interface_module

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

// A frame of the package over the tables of the caller.
@(private)
Frame_Over_Caller_Tables :: struct {
	table: interface.Draw_Table,
	frame: interface.Frame,
}

// The interface state and the input of each frame: empty. The elements of
// this module take no input and never write them, so the module keeps no
// state of a program in them; one empty record serves each call, with no
// zero bytes to write at each call.
@(private)
no_state: interface.Interface_State
@(private)
no_input: interface.Input

// The most records or bytes of a table of a caller: an int of the package
// holds each count, and no count times a size wraps.
@(private)
TABLE_LIMIT :: u64(1) << 40

// frame_over_caller_tables makes a frame of the package over the tables of
// the caller. It gives false for a table that the package cannot hold: a
// capacity over TABLE_LIMIT (a capacity of 2^63 is a negative int).
@(private)
frame_over_caller_tables :: proc "contextless" (over: ^Frame_Over_Caller_Tables, drawn: ^Draw_Records_To_Append, text: ^system.Bytes_To_Append) -> bool {
	if drawn.capacity > TABLE_LIMIT || text != nil && text.capacity > TABLE_LIMIT {
		return false
	}
	over.table = {records = drawn.records[:drawn.capacity], record_count = int(min(drawn.count, drawn.capacity))}
	if text != nil {
		over.table.text, over.table.text_count = text.bytes[:text.capacity], int(min(text.count, text.capacity))
	}
	over.frame = {table = &over.table, state = &no_state, input = &no_input}
	return true
}

// counts_write_back writes the counts of the package table into the two
// table places. A table that is full gives a count larger than its
// capacity: "did not fit".
@(private)
counts_write_back :: proc "contextless" (over: ^Frame_Over_Caller_Tables, drawn: ^Draw_Records_To_Append, text: ^system.Bytes_To_Append) -> i64 {
	drawn.count = u64(over.table.record_count)
	if text != nil {
		text.count = u64(over.table.text_count)
	}
	if over.table.full {
		if over.table.record_count >= len(over.table.records) {
			drawn.count = drawn.capacity + 1
		} else if text != nil {
			text.count = text.capacity + 1
		}
	}
	return i64(drawn.count)
}

@(private)
area_of :: proc "contextless" (area: Area) -> interface.Area {
	return {int(area.x), int(area.y), int(area.width), int(area.height)}
}

// draw_background appends the background of the rules on an area: one color and the grid of points. The result is the count of draw records, or -1 for a table over 2^40 records or bytes.
@(export, link_name = "draw_background")
draw_background :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), area: ^Area) -> i64 {
	frame: Frame_Over_Caller_Tables
	if !frame_over_caller_tables(&frame, drawn, nil) {
		return -1
	}
	interface.background(&frame.frame, area_of(area^))
	return counts_write_back(&frame, drawn, nil)
}

// draw_card appends the frame of one subject: its border, its surface, its title in the accent and its caption. It writes the area of its content in the one row of `area`. The result is the count of draw records, or -1 for a table over 2^40 records or bytes.
@(export, link_name = "draw_card")
draw_card :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), text: ^system.Bytes_To_Append, area: ^system.Table_To_Change(Area), title: ^string, caption: ^string, accent: i64) -> i64 {
	frame: Frame_Over_Caller_Tables
	if !frame_over_caller_tables(&frame, drawn, text) {
		return -1
	}
	if area.count == 1 {
		content := interface.card(&frame.frame, area_of(area.records[0]), title^, caption^, graphics.Color(accent))
		area.records[0] = {i64(content.x), i64(content.y), i64(content.width), i64(content.height)}
	}
	return counts_write_back(&frame, drawn, text)
}

// draw_cell_text appends a text in a cell of a line, at the left, or at the right when `right` is not 0. The result is the count of draw records, or -1 for a table over 2^40 records or bytes.
@(export, link_name = "draw_cell_text")
draw_cell_text :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), text: ^system.Bytes_To_Append, cell: ^Area, words: ^string, color: i64, right: i64) -> i64 {
	frame: Frame_Over_Caller_Tables
	if !frame_over_caller_tables(&frame, drawn, text) {
		return -1
	}
	interface.cell_text(&frame.frame, area_of(cell^), words^, graphics.Color(color), right != 0 ? .Right : .Left)
	return counts_write_back(&frame, drawn, text)
}

// draw_label_value_line appends a name in the dim color and its value. The result is the count of draw records, or -1 for a table over 2^40 records or bytes.
@(export, link_name = "draw_label_value_line")
draw_label_value_line :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), text: ^system.Bytes_To_Append, line: ^Label_Value, label: ^string, value: ^string) -> i64 {
	frame: Frame_Over_Caller_Tables
	if !frame_over_caller_tables(&frame, drawn, text) {
		return -1
	}
	interface.label_value_line(&frame.frame, {int(line.x), int(line.y), int(line.width), int(line.height)}, label^, value^, graphics.Color(line.color), int(line.value_x))
	return counts_write_back(&frame, drawn, text)
}

// draw_table_band appends the band under line `index` of a table: every second line has the surface of a card. The result is the count of draw records, or -1 for a table over 2^40 records or bytes.
@(export, link_name = "draw_table_band")
draw_table_band :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), area: ^Area, index: i64) -> i64 {
	frame: Frame_Over_Caller_Tables
	if !frame_over_caller_tables(&frame, drawn, nil) {
		return -1
	}
	interface.table_band(&frame.frame, area_of(area^), int(index))
	return counts_write_back(&frame, drawn, nil)
}

// draw_bar appends a value against a maximum: the track and the full part. The result is the count of draw records, or -1 for a table over 2^40 records or bytes.
@(export, link_name = "draw_bar")
draw_bar :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), bar: ^Bar_Value) -> i64 {
	frame: Frame_Over_Caller_Tables
	if !frame_over_caller_tables(&frame, drawn, nil) {
		return -1
	}
	interface.bar(&frame.frame, {int(bar.x), int(bar.y), int(bar.width), int(bar.height)}, u64(max(bar.value, 0)), u64(max(bar.maximum, 0)), graphics.Color(bar.color))
	return counts_write_back(&frame, drawn, nil)
}

// draw_table_to_read_of makes a draw table of the package over a Read
// table and its text. ok is false when a count passes TABLE_LIMIT or a text
// record names bytes past the text: the callee checks each offset, and
// gives a refusal, never a fault (finding W4 of the hostile read).
@(private)
draw_table_to_read_of :: proc "contextless" (records: ^system.Table_To_Read(interface.Draw_Record), text: ^system.Bytes_To_Read) -> (table: interface.Draw_Table, ok: bool) {
	if records.count > TABLE_LIMIT || text.count > TABLE_LIMIT {
		return {}, false
	}
	for record in system.table_records(records) {
		if record.kind == .Text && u64(record.text_start) + u64(record.text_count) > text.count {
			return {}, false
		}
	}
	return {records = records.records[:records.count], record_count = int(records.count), text = text.bytes[:text.count], text_count = int(text.count)}, true
}

// damage_by_difference gives the rectangles of the surface that differ between the draw table before and the draw table now. The result is a Table of at most 8 rectangles, or -1 for a text record that names bytes past its text table.
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

// execute_in_rectangles draws the records of a draw table into the pixels of a canvas, in each rectangle, cut to it. The pixels are the memory of the caller: no copy in a direct call. The result is the count of rectangles, or -1 for a canvas shape that the pixels do not hold or a text record that names bytes past its text table.
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
