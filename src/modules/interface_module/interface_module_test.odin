#+build !freestanding
package interface_module

import "core:testing"
import "modus:support/interface"
import "modus:support/system"

// A capacity over the largest int, as a hostile caller gives it: the
// capacity is refused, and a table of 4 places takes the two records.
@(test)
hostile_capacity_is_refused :: proc(t: ^testing.T) {
	memory: [4]interface.Draw_Record
	drawn := system.Table_To_Append(interface.Draw_Record){records = &memory[0], count = 0, capacity = 1 << 63}
	area := Area{0, 0, 8, 8}
	testing.expect(t, draw_background(&drawn, &area) < 0, "a capacity over the largest int")
	drawn = {records = &memory[0], count = 0, capacity = 4}
	testing.expect_value(t, draw_background(&drawn, &area), 2)
}

// The Append rule across calls (docs/MODULE_CONTRACT.md, "Did not fit,
// across calls"): the counts are the counts of the full answer, also
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
	// A cell wide enough for the six characters: a text is cut to its cell,
	// and this test is about the counts, not about the cut.
	wide := Area{0, 0, 64, 16}
	empty := ""
	testing.expect_value(t, draw_cell_text(&drawn, &text, &wide, &empty, 0, 0), 4) // Appends nothing.
	words := "abcdef"
	testing.expect_value(t, draw_cell_text(&drawn, &text, &wide, &words, 0, 0), 5)
	testing.expect_value(t, text.count, 6) // The 6 bytes of the full answer; 4 fit.
	testing.expect_value(t, string(text_memory[:4]), "abcd")
	testing.expect_value(t, text_memory[4], 0xA5)
	testing.expect_value(t, memory[3].element, 0xA5A5_A5A5)
}
