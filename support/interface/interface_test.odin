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

// The keys of one frame act in their order: Enter after "ls" activates the
// field with "ls", and the key after Enter is not taken (review W2).
@(test)
text_input_keys_in_their_order :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	state: Interface_State
	input: Input
	text: [8]u8
	count := 0
	state.focus = identity("input")
	key(&input, 0x26, 'l')
	key(&input, 0x1F, 's')
	key(&input, display.KEY_ENTER)
	key(&input, 0x2D, 'x')
	frame := frame_begin(&table, &state, &input)
	result := text_input(&frame, {0, 0, 200, 24}, identity("input"), text[:], &count)
	frame_end(&frame)
	testing.expect(t, result.activated)
	testing.expect_value(t, string(text[:count]), "ls")
	testing.expect(t, !input.keys[3].taken, "the key after Enter stays for the next element")
}

// The input of a frame takes 16 keys; then it has no room, and the reader
// of the events leaves the next ones for the next frame (review W3).
@(test)
a_full_input_says_so :: proc(t: ^testing.T) {
	input: Input
	for index in 0 ..< KEY_CAPACITY {
		testing.expect(t, input_has_room(&input))
		testing.expect(t, input_add(&input, {kind = .Key, code = u32(0x10 + index), character = 'a', pressed = true}))
	}
	testing.expect(t, !input_has_room(&input))
	testing.expect(t, !input_add(&input, {kind = .Key, code = 0x30, character = 'b', pressed = true}))
	input_clear(&input)
	testing.expect(t, input_has_room(&input))
}

// partial_equals_whole draws the table before whole, then the table now in
// its damage only, and compares the result with the table now drawn whole.
@(private = "file")
partial_equals_whole :: proc(t: ^testing.T, before, now: ^Draw_Table, name: string) {
	partial := make([]graphics.Color, 320 * 200)
	defer delete(partial)
	whole := make([]graphics.Color, 320 * 200)
	defer delete(whole)
	draw_whole(before, partial)
	damage: Damage
	damage_by_difference(before, now, &damage)
	canvas := graphics.Canvas{pixels = raw_data(partial), width = 320, height = 200, stride = 320}
	execute_in_rectangles(now, canvas, damage.rectangles[:damage.count])
	draw_whole(now, whole)
	testing.expectf(t, string(transmute([]u8)partial) == string(transmute([]u8)whole), "%s: the frame in its damage differs from the whole frame", name)
}

@(private = "file")
Case_Builder :: proc(table: ^Draw_Table, variant: int)

// Each kind of record and each path of the difference (review W4).
@(test)
damage_is_never_too_small_for_each_kind :: proc(t: ^testing.T) {
	cases := [?]struct {
		name:  string,
		build: Case_Builder,
	} {
		{"a clip that changes", proc(table: ^Draw_Table, variant: int) {
				draw_rectangle(table, 0, 0, 320, 200, graphics.COLOR_BACKGROUND)
				draw_clip(table, 10, 10, variant == 0 ? 100 : 60, 50)
				draw_rectangle(table, 0, 0, 200, 100, graphics.COLOR_KERNEL)
				draw_clip(table, 0, 0, 0, 0)
				draw_rectangle(table, 150, 150, 20, 20, graphics.COLOR_PROGRAM)
			}},
		{"horizontal gradients", proc(table: ^Draw_Table, variant: int) {
				draw_rectangle(table, 0, 0, 320, 200, graphics.COLOR_BACKGROUND)
				draw_horizontal_gradient(table, 5, 5, 300, 24, graphics.COLOR_TITLE, variant == 0 ? graphics.COLOR_TITLE_END : graphics.COLOR_FAILED)
				draw_horizontal_gradient(table, -40, 60, 700, 3, graphics.COLOR_TEXT, graphics.COLOR_DIM)
			}},
		{"text at the scales 1, 2 and 3", proc(table: ^Draw_Table, variant: int) {
				draw_rectangle(table, 0, 0, 320, 200, graphics.COLOR_BACKGROUND)
				draw_text(table, 4, 4, variant == 0 ? "one" : "two", graphics.COLOR_TEXT)
				draw_text(table, 4, 30, variant == 0 ? "12" : "13", graphics.COLOR_TEXT, FONT_MEDIUM)
				draw_text(table, 4, 70, variant == 0 ? "45" : "46", graphics.COLOR_TEXT, FONT_LARGE)
			}},
		{"records outside the surface", proc(table: ^Draw_Table, variant: int) {
				draw_rectangle(table, 0, 0, 320, 200, graphics.COLOR_BACKGROUND)
				draw_rectangle(table, -50 + variant * 7, -20, 80, 60, graphics.COLOR_MEMORY)
				draw_rectangle(table, 300, 190 - variant * 3, 100, 100, graphics.COLOR_MACHINE)
				draw_text(table, -12 + variant, 190, "edge", graphics.COLOR_TEXT)
				draw_point_grid(table, -30, -30, 400, 300)
			}},
		{"a record of one line", proc(table: ^Draw_Table, variant: int) {
				draw_rectangle(table, 0, 0, 320, 200, graphics.COLOR_BACKGROUND)
				draw_rectangle(table, 10, 100 + variant, 300, 1, graphics.COLOR_TEXT)
				draw_vertical_gradient(table, 10, 120, 300, 1, graphics.COLOR_KERNEL, graphics.COLOR_FAILED)
			}},
		{"more than 8 rectangles of damage", proc(table: ^Draw_Table, variant: int) {
				draw_rectangle(table, 0, 0, 320, 200, graphics.COLOR_BACKGROUND)
				for index in 0 ..< 12 {
					draw_rectangle(table, (index % 4) * 80 + 4, (index / 4) * 64 + 4, 10, 10, variant == 0 ? graphics.COLOR_KERNEL : graphics.Color(graphics.COLOR_PROGRAM + u32(index)))
				}
			}},
		{"a table that is full", proc(table: ^Draw_Table, variant: int) {
				draw_rectangle(table, 0, 0, 320, 200, graphics.COLOR_BACKGROUND)
				for index in 0 ..< 400 {
					draw_rectangle(table, index % 300, (index * 7) % 190, 4, 4, graphics.Color(index * 977 + variant))
				}
			}},
	}
	for item in cases {
		first, second: Tables
		before, now := table_of(&first), table_of(&second)
		item.build(&before, 0)
		item.build(&now, 1)
		partial_equals_whole(t, &before, &now, item.name)
	}
	// The merge path: 12 changes far apart give at most 8 rectangles.
	first, second: Tables
	before, now := table_of(&first), table_of(&second)
	cases[5].build(&before, 0)
	cases[5].build(&now, 1)
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect(t, damage.count <= DAMAGE_CAPACITY)
	// The full table: 256 records fit, the others are dropped, and it says so.
	cases[6].build(&now, 1)
	testing.expect(t, now.full)
}

// Review N1: more digits than a number can have.
@(test)
number_with_many_digits :: proc(t: ^testing.T) {
	builder: Text_Builder
	testing.expect_value(t, number_text(&builder, 7, 25), "00000000000000000007")
}

// Review N2: a negative height takes nothing.
@(test)
column_negative_height :: proc(t: ^testing.T) {
	column := column_of({0, 0, 50, 100})
	column_take(&column, 30)
	testing.expect_value(t, column_take(&column, -20).height, 0)
	testing.expect_value(t, column_take(&column, 10), Area{0, 30, 50, 10})
}

// Review N3: sizes that are negative, larger than the row, or so large that
// a product overflows.
@(test)
row_split_checks_its_sizes :: proc(t: ^testing.T) {
	columns: [3]Area
	row_split({0, 0, 100, 24}, {pixels(-40), share(1), pixels(30)}, columns[:])
	testing.expect_value(t, columns[0].width, 0)
	testing.expect_value(t, columns[1].width, 70)
	row_split({0, 0, 100, 24}, {pixels(300), share(1), characters(4)}, columns[:])
	for column in columns {
		testing.expect(t, column.width >= 0 && column.x + column.width <= 100, "each column is inside the row")
	}
	row_split({0, 0, 100, 24}, {share(max(int) / 2), share(max(int) / 2), share(-5)}, columns[:])
	total := 0
	for column in columns {
		testing.expect(t, column.width >= 0)
		total += column.width
	}
	testing.expect_value(t, total, 100)
}

// Review N4: a press under the last line or on the bar of the list chooses
// nothing; a choice that the list cuts is reported as changed.
@(test)
list_press_and_cut_choice :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	state: Interface_State
	input: Input
	names := []string{"a", "b", "c", "d", "e"}
	choice := 0
	// 3 lines of 24 and 10 pixels more: a press at y = 80 is under the last line.
	input_add(&input, {kind = .Pointer, x = 10, y = 80, buttons = display.BUTTON_LEFT})
	frame := frame_begin(&table, &state, &input)
	result := list_with_choice(&frame, {0, 0, 200, 82}, identity("list"), names, &choice)
	frame_end(&frame)
	testing.expect_value(t, choice, 0)
	testing.expect(t, !result.changed)
	// A press on the bar at the right chooses nothing.
	input_clear(&input)
	input_add(&input, {kind = .Pointer, x = 199, y = 30, buttons = 0})
	input_add(&input, {kind = .Pointer, x = 199, y = 30, buttons = display.BUTTON_LEFT})
	frame = frame_begin(&table, &state, &input)
	result = list_with_choice(&frame, {0, 0, 200, 82}, identity("list"), names, &choice)
	frame_end(&frame)
	testing.expect_value(t, choice, 0)
	// The list has fewer names than the choice: the choice is cut, and changed.
	choice = 4
	input_clear(&input)
	frame = frame_begin(&table, &state, &input)
	result = list_with_choice(&frame, {0, 0, 200, 82}, identity("list"), names[:2], &choice)
	frame_end(&frame)
	testing.expect_value(t, choice, 1)
	testing.expect(t, result.changed)
}

// Review N6: two elements with one identity in one frame are reported; a
// row number makes them two.
@(test)
identity_collision :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	state: Interface_State
	input: Input
	frame := frame_begin(&table, &state, &input)
	button(&frame, {0, 0, 80, 24}, identity("delete"), "delete")
	button(&frame, {0, 32, 80, 24}, identity("delete"), "delete")
	testing.expect_value(t, frame.identity_collisions, 1)
	frame_end(&frame)
	frame = frame_begin(&table, &state, &input)
	button(&frame, {0, 0, 80, 24}, identity_with(identity("delete"), 0), "delete")
	button(&frame, {0, 32, 80, 24}, identity_with(identity("delete"), 1), "delete")
	testing.expect_value(t, frame.identity_collisions, 0)
	frame_end(&frame)
}

// Review N7: a place past the i32 of a record is cut to it.
@(test)
coordinates_are_cut_to_i32 :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	draw_rectangle(&table, 1 << 40, -(1 << 40), 10, 10, 1)
	testing.expect_value(t, table.records[0].x, max(i32))
	testing.expect_value(t, table.records[0].y, min(i32))
}

// Review N9: a record that the frame no longer has leaves no pixel, even
// when no record of the frame covers its place.
@(test)
a_gone_record_leaves_no_pixel :: proc(t: ^testing.T) {
	first, second: Tables
	before, now := table_of(&first), table_of(&second)
	draw_rectangle(&before, 0, 0, 10, 10, graphics.COLOR_BACKGROUND)
	draw_rectangle(&before, 50, 50, 20, 20, graphics.COLOR_FAILED)
	draw_rectangle(&now, 0, 0, 10, 10, graphics.COLOR_BACKGROUND)
	pixels := make([]graphics.Color, 320 * 200)
	defer delete(pixels)
	canvas := graphics.Canvas{pixels = raw_data(pixels), width = 320, height = 200, stride = 320}
	graphics.clear(canvas, graphics.COLOR_BACKGROUND)
	execute(&before, canvas)
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	draw_damage_on_surface(&now, canvas, damage.rectangles[:damage.count])
	testing.expect_value(t, pixels[60 * 320 + 60], graphics.COLOR_BACKGROUND)
}

// A picture record: the difference sees a new generation, and the frame in
// its damage equals the whole frame; a folded gap draws like the others.
@(test)
picture_and_folded_gap :: proc(t: ^testing.T) {
	first, second: Tables
	before, now := table_of(&first), table_of(&second)
	cells: [16 * 8]graphics.Color
	for &cell, index in cells {
		cell = graphics.Color(index * 0x010203)
	}
	pictures := []graphics.Canvas{{pixels = raw_data(cells[:]), width = 16, height = 8, stride = 16}}
	before.pictures, now.pictures = pictures, pictures
	draw_rectangle(&before, 0, 0, 320, 200, graphics.COLOR_BACKGROUND)
	draw_picture(&before, 40, 40, 0, 1)
	draw_folded_gap(&before, 100, 100, 40, 24)
	draw_rectangle(&now, 0, 0, 320, 200, graphics.COLOR_BACKGROUND)
	draw_picture(&now, 40, 40, 0, 2)
	draw_folded_gap(&now, 100, 100, 40, 24)
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 1)
	testing.expect_value(t, damage.rectangles[0], Rectangle{40, 40, 56, 48})
	partial_equals_whole(t, &before, &now, "a picture")
	draw_picture(&now, 0, 0, 3, 1)
	testing.expect(t, now.full, "a picture that the table does not have is refused")
}

// A narrow card cuts its caption: no text record passes its right border.
@(test)
card_caption_stays_inside :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	state: Interface_State
	input: Input
	frame := frame_begin(&table, &state, &input)
	card(&frame, {8, 8, 200, 100}, "SLOTS", "Program_Report and a long caption", graphics.COLOR_PROGRAM, "34")
	for record in table.records[:table.record_count] {
		if record.kind == .Text {
			testing.expectf(t, int(record.x + record.width) <= 8 + 200 - 16 + 1, "a text ends at %d, past the border", record.x + record.width)
		}
	}
}
