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

Drawn :: system.Table_To_Append(interface.Draw_Record)

// A frame of the package over the tables of the caller.
@(private)
Over_Tables :: struct {
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

@(private)
over :: proc "contextless" (over: ^Over_Tables, drawn: ^Drawn, text: ^system.Bytes_To_Append) {
	over.table = {records = drawn.records[:drawn.capacity], record_count = int(min(drawn.count, drawn.capacity))}
	if text != nil {
		over.table.text, over.table.text_count = text.bytes[:text.capacity], int(min(text.count, text.capacity))
	}
	over.frame = {table = &over.table, state = &no_state, input = &no_input}
}

// back writes the counts of the package table into the two places. A table
// that is full gives a count larger than its capacity: "did not fit".
@(private)
back :: proc "contextless" (over: ^Over_Tables, drawn: ^Drawn, text: ^system.Bytes_To_Append) -> i64 {
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

// draw_background appends the background of the rules on an area: one color and the grid of points. The result is the count of draw records.
@(export, link_name = "draw_background")
draw_background :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), area: ^Area) -> i64 {
	frame: Over_Tables
	over(&frame, drawn, nil)
	interface.background(&frame.frame, area_of(area^))
	return back(&frame, drawn, nil)
}

// draw_card appends the frame of one subject: its border, its surface, its title in the accent and its caption. It writes the area of its content in the one row of `area`. The result is the count of draw records.
@(export, link_name = "draw_card")
draw_card :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), text: ^system.Bytes_To_Append, area: ^system.Table_To_Change(Area), title: ^string, caption: ^string, accent: i64) -> i64 {
	frame: Over_Tables
	over(&frame, drawn, text)
	if area.count == 1 {
		content := interface.card(&frame.frame, area_of(area.records[0]), title^, caption^, graphics.Color(accent))
		area.records[0] = {i64(content.x), i64(content.y), i64(content.width), i64(content.height)}
	}
	return back(&frame, drawn, text)
}

// draw_cell_text appends a text in a cell of a line, at the left, or at the right when `right` is not 0. The result is the count of draw records.
@(export, link_name = "draw_cell_text")
draw_cell_text :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), text: ^system.Bytes_To_Append, cell: ^Area, words: ^string, color: i64, right: i64) -> i64 {
	frame: Over_Tables
	over(&frame, drawn, text)
	interface.cell_text(&frame.frame, area_of(cell^), words^, graphics.Color(color), right != 0 ? .Right : .Left)
	return back(&frame, drawn, text)
}

// draw_label_value_line appends a name in the dim color and its value. The result is the count of draw records.
@(export, link_name = "draw_label_value_line")
draw_label_value_line :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), text: ^system.Bytes_To_Append, line: ^Label_Value, label: ^string, value: ^string) -> i64 {
	frame: Over_Tables
	over(&frame, drawn, text)
	interface.label_value_line(&frame.frame, {int(line.x), int(line.y), int(line.width), int(line.height)}, label^, value^, graphics.Color(line.color), int(line.value_x))
	return back(&frame, drawn, text)
}

// draw_table_band appends the band under line `index` of a table: every second line has the surface of a card. The result is the count of draw records.
@(export, link_name = "draw_table_band")
draw_table_band :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), area: ^Area, index: i64) -> i64 {
	frame: Over_Tables
	over(&frame, drawn, nil)
	interface.table_band(&frame.frame, area_of(area^), int(index))
	return back(&frame, drawn, nil)
}

// draw_bar appends a value against a maximum: the track and the full part. The result is the count of draw records.
@(export, link_name = "draw_bar")
draw_bar :: proc "c" (drawn: ^system.Table_To_Append(interface.Draw_Record), bar: ^Bar_Value) -> i64 {
	frame: Over_Tables
	over(&frame, drawn, nil)
	interface.bar(&frame.frame, {int(bar.x), int(bar.y), int(bar.width), int(bar.height)}, u64(max(bar.value, 0)), u64(max(bar.maximum, 0)), graphics.Color(bar.color))
	return back(&frame, drawn, nil)
}

@(private)
table_of :: proc "contextless" (records: ^system.Table_To_Read(interface.Draw_Record), text: ^system.Bytes_To_Read) -> interface.Draw_Table {
	return {records = records.records[:records.count], record_count = int(records.count), text = text.bytes[:text.count], text_count = int(text.count)}
}

// damage_by_difference gives the rectangles of the surface that differ between the draw table before and the draw table now. The result is a Table of at most 8 rectangles.
@(export, link_name = "damage_by_difference")
damage_by_difference :: proc "c" (before: ^system.Table_To_Read(interface.Draw_Record), before_text: ^system.Bytes_To_Read, now: ^system.Table_To_Read(interface.Draw_Record), now_text: ^system.Bytes_To_Read, result: ^[]Damage_Rectangle) -> i64 {
	before_table, now_table := table_of(before, before_text), table_of(now, now_text)
	damage: interface.Damage
	interface.damage_by_difference(&before_table, &now_table, &damage)
	for rectangle, index in damage.rectangles[:damage.count] {
		if index < len(result) {
			result[index] = {i64(rectangle.left), i64(rectangle.top), i64(rectangle.right), i64(rectangle.bottom)}
		}
	}
	return i64(damage.count)
}

// execute_in_rectangles draws the records of a draw table into the pixels of a canvas, in each rectangle, cut to it. The pixels are the memory of the caller: no copy in a direct call. The result is the count of rectangles.
@(export, link_name = "execute_in_rectangles")
execute_in_rectangles :: proc "c" (now: ^system.Table_To_Read(interface.Draw_Record), now_text: ^system.Bytes_To_Read, rectangles: ^system.Table_To_Read(Damage_Rectangle), pixels: ^system.Bytes_To_Change, shape: ^Canvas_Shape) -> i64 {
	if shape.width <= 0 || shape.height <= 0 || shape.stride < shape.width || u64(shape.stride) * u64(shape.height) * 4 > pixels.count {
		return -1
	}
	table := table_of(now, now_text)
	canvas := graphics.Canvas{pixels = ([^]graphics.Color)(pixels.bytes), width = int(shape.width), height = int(shape.height), stride = int(shape.stride)}
	for rectangle in system.table_records(rectangles) {
		interface.execute_in_rectangle(&table, canvas, {int(rectangle.left), int(rectangle.top), int(rectangle.right), int(rectangle.bottom)})
	}
	return i64(rectangles.count)
}
