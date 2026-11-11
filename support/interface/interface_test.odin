#+build !freestanding
package interface

import "support:display"
import "support:graphics"
import "core:testing"

@(private = "file")
Tables :: struct {
	records: [256]Draw_Record,
	text:    [4096]u8,
}

@(private = "file")
table_of :: proc(memory: ^Tables) -> Draw_Table {
	return {records = memory.records[:], text = memory.text[:]}
}

// A window of a few elements, with one number that changes.
@(private = "file")
build_window :: proc(table: ^Draw_Table, state: ^Interface_State, input: ^Input, number: u64, moved: bool) {
	frame := frame_begin(table, state, input)
	background(&frame, {0, 0, 320, 200})
	content := card(&frame, {8, 8, 304, 184}, "CARD", "a caption", graphics.COLOR_KERNEL, "3")
	column := column_of(content)
	builder: Text_Builder
	label_value_line(&frame, column_take(&column, TABLE_LINE), "a number", number_text(&builder, number))
	bar(&frame, column_take(&column, 8), number, 100, graphics.COLOR_PROGRAM)
	line := column_take(&column, TABLE_LINE)
	if moved {
		line.x += 8
	}
	button(&frame, line, identity("button"), "press")
	frame_end(&frame)
}

@(private = "file")
draw_whole :: proc(table: ^Draw_Table, pixels: []graphics.Color) {
	canvas := graphics.Canvas{pixels = raw_data(pixels), width = 320, height = 200, stride = 320}
	graphics.clear(canvas, 0x123456)
	execute(table, canvas)
}

@(test)
row_split_fills_the_area :: proc(t: ^testing.T) {
	columns: [4]Area
	row_split({10, 0, 300, 24}, {pixels(40), characters(5), share(1), share(2)}, columns[:], 8)
	testing.expect_value(t, columns[0], Area{10, 0, 40, 24})
	testing.expect_value(t, columns[1], Area{58, 0, 40, 24})
	// What is left: 300 - 40 - 40 - 3 * 8 = 196; one third, then the rest.
	testing.expect_value(t, columns[2].width, 65)
	testing.expect_value(t, columns[3].width, 131)
	testing.expect_value(t, columns[3].x + columns[3].width, 310)
}

@(test)
column_gives_areas_down :: proc(t: ^testing.T) {
	column := column_of({0, 100, 50, 60}, 8)
	testing.expect_value(t, column_take(&column, 24), Area{0, 100, 50, 24})
	testing.expect_value(t, column_take(&column, 24), Area{0, 132, 50, 24})
	testing.expect_value(t, column_take(&column, 24), Area{0, 164, 50, 0}) // Past the bottom.
	testing.expect_value(t, column_rest(&column).height, 0)
}

@(test)
text_measure :: proc(t: ^testing.T) {
	testing.expect_value(t, text_width({}, "abc"), 24)
	testing.expect_value(t, text_width(FONT_LARGE, "12"), 48)
	testing.expect_value(t, line_height(FONT_MEDIUM), 32)
}

@(test)
no_change_no_damage :: proc(t: ^testing.T) {
	first, second: Tables
	before, now := table_of(&first), table_of(&second)
	state: Interface_State
	input: Input
	build_window(&before, &state, &input, 42, false)
	build_window(&now, &state, &input, 42, false)
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 0)
	testing.expect(t, !now.full)
}

@(test)
one_number_damages_its_place :: proc(t: ^testing.T) {
	first, second: Tables
	before, now := table_of(&first), table_of(&second)
	state: Interface_State
	input: Input
	build_window(&before, &state, &input, 42, false)
	build_window(&now, &state, &input, 57, false)
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	// The number and the bar changed: two records each, near each other.
	testing.expect(t, damage.count >= 1)
	bounds := damage_bounds(&damage)
	testing.expect(t, bounds.right - bounds.left <= 288 && bounds.bottom - bounds.top <= 40, "the damage is the line of the number and the bar")
}

@(test)
text_at_another_place_is_equal :: proc(t: ^testing.T) {
	first, second: Tables
	before, now := table_of(&first), table_of(&second)
	draw_text(&before, 0, 0, "same", graphics.COLOR_TEXT)
	draw_text(&now, 0, 30, "other", graphics.COLOR_TEXT)
	draw_table_clear(&now)
	now.text_count = 7 // The text of the run starts at another place.
	draw_text(&now, 0, 0, "same", graphics.COLOR_TEXT)
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 0)
}

// A frame drawn in its damage rectangles over the frame before is the same
// frame, pixel for pixel, as the frame drawn whole.
@(test)
damage_is_never_too_small :: proc(t: ^testing.T) {
	first, second: Tables
	before, now := table_of(&first), table_of(&second)
	state: Interface_State
	input: Input
	cases := [?]struct {
		number_before, number_now: u64,
		moved:                     bool,
	}{{42, 57, false}, {0, 100, false}, {7, 7, true}, {99, 3, true}}
	for item in cases {
		build_window(&before, &state, &input, item.number_before, false)
		build_window(&now, &state, &input, item.number_now, item.moved)
		partial := make([]graphics.Color, 320 * 200)
		defer delete(partial)
		whole := make([]graphics.Color, 320 * 200)
		defer delete(whole)
		draw_whole(&before, partial)
		damage: Damage
		damage_by_difference(&before, &now, &damage)
		canvas := graphics.Canvas{pixels = raw_data(partial), width = 320, height = 200, stride = 320}
		execute_in_rectangles(&now, canvas, damage.rectangles[:damage.count])
		draw_whole(&now, whole)
		testing.expectf(t, string(transmute([]u8)partial) == string(transmute([]u8)whole), "the frame in its damage differs from the whole frame: %v", item)
	}
}

@(test)
fewer_records_damage_the_rest :: proc(t: ^testing.T) {
	first, second: Tables
	before, now := table_of(&first), table_of(&second)
	draw_rectangle(&before, 0, 0, 10, 10, 1)
	draw_rectangle(&before, 50, 50, 10, 10, 2)
	draw_rectangle(&now, 0, 0, 10, 10, 1)
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 1)
	testing.expect_value(t, damage.rectangles[0], Rectangle{50, 50, 60, 60})
}

@(test)
full_table_says_so :: proc(t: ^testing.T) {
	records: [2]Draw_Record
	text: [4]u8
	table := Draw_Table{records = records[:], text = text[:]}
	draw_rectangle(&table, 0, 0, 1, 1, 0)
	draw_rectangle(&table, 0, 0, 1, 1, 0)
	testing.expect(t, !table.full)
	draw_rectangle(&table, 0, 0, 1, 1, 0)
	testing.expect(t, table.full)
	draw_table_clear(&table)
	draw_text(&table, 0, 0, "too long", 0)
	testing.expect(t, table.full)
}

@(private = "file")
key :: proc(input: ^Input, code: u32, character: u8 = 0, modifiers: u32 = 0) {
	input_add(input, {kind = .Key, code = code, character = character, pressed = true, modifiers = modifiers})
}

@(private = "file")
two_buttons :: proc(table: ^Draw_Table, state: ^Interface_State, input: ^Input) -> (first, second: Element_Result) {
	frame := frame_begin(table, state, input)
	first = button(&frame, {0, 0, 80, 24}, identity("first"), "first")
	second = button(&frame, {0, 32, 80, 24}, identity("second"), "second")
	frame_end(&frame)
	input_clear(input)
	return
}

@(test)
keyboard_moves_the_focus_and_presses :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	state: Interface_State
	input: Input
	two_buttons(&table, &state, &input) // The first frame makes the order of the focus.
	key(&input, KEY_TAB)
	first, second := two_buttons(&table, &state, &input)
	testing.expect(t, first.focused && !second.focused, "Tab gives the focus to the first element")
	key(&input, KEY_TAB)
	key(&input, display.KEY_ENTER)
	first, second = two_buttons(&table, &state, &input)
	testing.expect(t, second.focused && second.activated && !first.activated, "Tab, then Enter presses the second")
	key(&input, KEY_TAB, 0, display.MODIFIER_SHIFT)
	key(&input, 0x39, ' ')
	first, second = two_buttons(&table, &state, &input)
	testing.expect(t, first.focused && first.activated, "Shift+Tab, then Space presses the first")
}

@(test)
pointer_presses_on_release :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	state: Interface_State
	input: Input
	input_add(&input, {kind = .Pointer, x = 10, y = 40, buttons = display.BUTTON_LEFT})
	first, second := two_buttons(&table, &state, &input)
	testing.expect(t, second.under_pointer && !second.activated && second.focused, "the press gives the focus; no activation yet")
	input_add(&input, {kind = .Pointer, x = 12, y = 41, buttons = 0})
	first, second = two_buttons(&table, &state, &input)
	testing.expect(t, second.activated && !first.activated, "the release on the same element activates it")
}

@(test)
text_input_and_list :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	state: Interface_State
	input: Input
	text: [8]u8
	count := 0
	choice := 0
	names := []string{"boot", "pages", "log"}
	build :: proc(table: ^Draw_Table, state: ^Interface_State, input: ^Input, text: []u8, count: ^int, names: []string, choice: ^int) -> (typed, listed: Element_Result) {
		frame := frame_begin(table, state, input)
		typed = text_input(&frame, {0, 0, 200, 24}, identity("input"), text, count, "type")
		listed = list_with_choice(&frame, {0, 32, 200, 72}, identity("list"), names, choice, {marked = string(text[:count^])})
		frame_end(&frame)
		input_clear(input)
		return
	}
	build(&table, &state, &input, text[:], &count, names, &choice)
	state.focus = identity("input")
	key(&input, 0x26, 'l')
	key(&input, 0x18, 'o')
	key(&input, 0x39, ' ')
	key(&input, display.KEY_BACKSPACE)
	typed, _ := build(&table, &state, &input, text[:], &count, names, &choice)
	testing.expect(t, typed.changed)
	testing.expect_value(t, string(text[:count]), "lo")
	key(&input, KEY_TAB)
	key(&input, display.KEY_DOWN)
	key(&input, display.KEY_DOWN)
	_, listed := build(&table, &state, &input, text[:], &count, names, &choice)
	testing.expect(t, listed.focused && listed.changed)
	testing.expect_value(t, choice, 2)
	key(&input, display.KEY_DOWN)
	key(&input, display.KEY_ENTER)
	_, listed = build(&table, &state, &input, text[:], &count, names, &choice)
	testing.expect_value(t, choice, 0) // From the last line to the first.
	testing.expect(t, listed.activated)
}
