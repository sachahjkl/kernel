#+build !freestanding
package interface_module

import "core:testing"
import "support:interface"
import "support:system"

// A canvas whose stride times its height wraps (finding F2 of the hostile
// read): the export refuses it, and draws nothing.
@(test)
canvas_shape_that_wraps_is_refused :: proc(t: ^testing.T) {
	pixels: [16]u32
	records := [1]interface.Draw_Record{{kind = .Rectangle, x = 0, y = 0, width = 1, height = 4, first_color = 0xFFFFFF}}
	now := system.Table_To_Read(interface.Draw_Record){records = &records[0], count = 1, capacity = 1}
	text := system.Bytes_To_Read{}
	rectangles := [1]Damage_Rectangle{{0, 0, 1, 4}}
	damage := system.Table_To_Read(Damage_Rectangle){records = &rectangles[0], count = 1, capacity = 1}
	bytes := system.Bytes_To_Change{bytes = ([^]u8)(&pixels[0]), count = size_of(pixels), capacity = size_of(pixels)}
	shape := Canvas_Shape{width = 1, height = 4, stride = (1 << 62) + 1}
	testing.expect_value(t, execute_in_rectangles(&now, &text, &damage, &bytes, &shape), -1)
	shape = {width = 1, height = 0, stride = 1}
	testing.expect_value(t, execute_in_rectangles(&now, &text, &damage, &bytes, &shape), -1)
	shape = {width = 1, height = 4, stride = 4}
	testing.expect_value(t, execute_in_rectangles(&now, &text, &damage, &bytes, &shape), 1)
	testing.expect_value(t, pixels[4], 0xFFFFFF)
}

// A text record that names bytes past the text table, and a capacity over
// the largest int (finding W4): a refusal, not a fault.
@(test)
hostile_records_are_refused :: proc(t: ^testing.T) {
	text_bytes := [4]u8{'a', 'b', 'c', 'd'}
	before_records := [1]interface.Draw_Record{{kind = .Text, width = 8, height = 16, text_start = 2, text_count = 4}}
	now_records := [1]interface.Draw_Record{{kind = .Text, width = 8, height = 16, text_start = 0, text_count = 4}}
	before := system.Table_To_Read(interface.Draw_Record){records = &before_records[0], count = 1, capacity = 1}
	now := system.Table_To_Read(interface.Draw_Record){records = &now_records[0], count = 1, capacity = 1}
	text := system.Bytes_To_Read{bytes = &text_bytes[0], count = 4, capacity = 4}
	buffer: [8]Damage_Rectangle
	result := buffer[:]
	testing.expect(t, damage_by_difference(&before, &text, &now, &text, &result) < 0, "a text past the text table")
	memory: [4]interface.Draw_Record
	drawn := system.Table_To_Append(interface.Draw_Record){records = &memory[0], count = 0, capacity = 1 << 63}
	area := Area{0, 0, 8, 8}
	testing.expect(t, draw_background(&drawn, &area) < 0, "a capacity over the largest int")
	drawn = {records = &memory[0], count = 0, capacity = 4}
	testing.expect_value(t, draw_background(&drawn, &area), 2)
}
