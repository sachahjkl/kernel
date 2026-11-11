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
// the largest int (findings W4 and W-new): no fault; the record past the
// text differs, so its rectangle is damaged; the capacity is refused.
@(test)
hostile_records_are_refused :: proc(t: ^testing.T) {
	text_bytes := [4]u8{'a', 'b', 'c', 'd'}
	before_records := [1]interface.Draw_Record{{kind = .Text, x = 8, width = 8, height = 16, text_start = 2, text_count = 4}}
	now_records := [1]interface.Draw_Record{{kind = .Text, x = 8, width = 8, height = 16, text_start = 2, text_count = 4}}
	before := system.Table_To_Read(interface.Draw_Record){records = &before_records[0], count = 1, capacity = 1}
	now := system.Table_To_Read(interface.Draw_Record){records = &now_records[0], count = 1, capacity = 1}
	text := system.Bytes_To_Read{bytes = &text_bytes[0], count = 4, capacity = 4}
	buffer: [8]Damage_Rectangle
	result := buffer[:]
	testing.expect_value(t, damage_by_difference(&before, &text, &now, &text, &result), 1)
	testing.expect_value(t, buffer[0], Damage_Rectangle{8, 0, 16, 16})
	memory: [4]interface.Draw_Record
	drawn := system.Table_To_Append(interface.Draw_Record){records = &memory[0], count = 0, capacity = 1 << 63}
	area := Area{0, 0, 8, 8}
	testing.expect(t, draw_background(&drawn, &area) < 0, "a capacity over the largest int")
	drawn = {records = &memory[0], count = 0, capacity = 4}
	testing.expect_value(t, draw_background(&drawn, &area), 2)
}

// The Append rule across calls (decision of the coordinator after the
// second hostile read): the counts are the counts of the full answer, also
// after a call that did not fit and a call that appends nothing; nothing
// is written at or after a capacity.
@(test)
counts_of_the_full_answer_across_calls :: proc(t: ^testing.T) {
	memory: [4]interface.Draw_Record // 3 places, then a guard record.
	memory[3] = {element = 0xA5A5_A5A5}
	drawn := system.Table_To_Append(interface.Draw_Record){records = &memory[0], count = 0, capacity = 3}
	text_memory: [8]u8
	text_memory[4] = 0xA5
	text := system.Bytes_To_Append{bytes = &text_memory[0], count = 0, capacity = 4}
	area := Area{0, 0, 8, 8}
	testing.expect_value(t, draw_background(&drawn, &area), 2) // A rectangle and the grid.
	testing.expect_value(t, draw_background(&drawn, &area), 4) // 1 of 2 fits.
	empty := ""
	testing.expect_value(t, draw_cell_text(&drawn, &text, &area, &empty, 0, 0), 4) // Appends nothing.
	words := "abcdef"
	testing.expect_value(t, draw_cell_text(&drawn, &text, &area, &words, 0, 0), 5)
	testing.expect_value(t, text.count, 6) // The 6 bytes of the full answer; 4 fit.
	testing.expect_value(t, string(text_memory[:4]), "abcd")
	testing.expect_value(t, text_memory[4], 0xA5)
	testing.expect_value(t, memory[3].element, 0xA5A5_A5A5)
}
