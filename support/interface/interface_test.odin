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
// field with "ls", and the key after Enter is not taken: Enter taken
// before the characters of its frame would act on an empty field.
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
// of the events leaves the next ones for the next frame: no key is lost.
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

// Each kind of record and each path of the difference: a damage too small
// for one kind would leave old pixels on the screen.
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

// More digits than a number can have: the table of digits must not be
// indexed before its start.
@(test)
number_with_many_digits :: proc(t: ^testing.T) {
	builder: Text_Builder
	testing.expect_value(t, number_text(&builder, 7, 25), "00000000000000000007")
}

// A negative height takes nothing: the next element must not go up.
@(test)
column_negative_height :: proc(t: ^testing.T) {
	column := column_of({0, 0, 50, 100})
	column_take(&column, 30)
	testing.expect_value(t, column_take(&column, -20).height, 0)
	testing.expect_value(t, column_take(&column, 10), Area{0, 30, 50, 10})
}

// Sizes that are negative, larger than the row, or so large that
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

// A press under the last line or on the bar of the list chooses
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

// Two elements with one identity in one frame are reported; a
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

// A place past the i32 of a record is cut to it.
@(test)
coordinates_are_cut_to_i32 :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	draw_rectangle(&table, 1 << 40, -(1 << 40), 10, 10, 1)
	testing.expect_value(t, int(table.records[0].x), COORDINATE_LIMIT - 1)
	testing.expect_value(t, int(table.records[0].y), -COORDINATE_LIMIT)
}

// A record that the frame no longer has leaves no pixel, even
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
	testing.expect(t, now.refused && !now.full, "a picture that the table does not have is refused, and the table is not full")
}

// A text record whose range is past its text table (a table from another
// program, through the interface module): the difference does not fault,
// and the record differs, so its rectangle is damaged.
@(test)
text_range_past_the_table_is_damaged :: proc(t: ^testing.T) {
	text := [4]u8{'a', 'b', 'c', 'd'}
	records := [1]Draw_Record{{kind = .Text, x = 8, width = 8, height = 16, text_start = 2, text_count = 4}}
	before := Draw_Table{records = records[:], record_count = 1, text = text[:], text_count = 4}
	now := Draw_Table{records = records[:], record_count = 1, text = text[:], text_count = 4}
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 1)
	testing.expect_value(t, damage.rectangles[0], Rectangle{8, 0, 16, 16})
	// The same record inside its table: no damage.
	records[0].text_start = 0
	damage = {}
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 0)
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

// A grid where one cell changed damages that cell only; a grid that the
// table before does not have is damaged whole; the copy keeps the cells.
@(test)
text_grid_damage_for_each_cell :: proc(t: ^testing.T) {
	cells_now: [3 * 8]Text_Grid_Cell
	cells_drawn: [3 * 8]Text_Grid_Cell
	for &cell, index in cells_now {
		cell = {u8('a' + index % 26), false, 0xFFFFFF}
	}
	records_now, records_before: [4]Draw_Record
	grids_now := [1]Text_Grid{{cells = cells_now[:], columns = 6, rows = 3, stride = 8}}
	grids_before := [1]Text_Grid{{cells = cells_drawn[:]}}
	now := Draw_Table{records = records_now[:], grids = grids_now[:]}
	before := Draw_Table{records = records_before[:], grids = grids_before[:]}
	draw_text_grid(&now, 10, 20, 0)
	testing.expect(t, now.record_count == 1 && !now.full)
	testing.expect(t, draw_table_copy(&before, &now))
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 0)
	cells_now[1 * 8 + 4].character = 'Z'
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 1)
	testing.expect_value(t, damage.rectangles[0], Rectangle{10 + 4 * 8, 20 + 16, 10 + 5 * 8, 20 + 32})
	// The cells past the columns of a row are not in the grid.
	damage = {}
	testing.expect(t, draw_table_copy(&before, &now))
	cells_now[7].character = 'Q'
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 0)
	// A table before with no room for the cells cannot keep a copy.
	small: [4]Text_Grid_Cell
	grids_small := [1]Text_Grid{{cells = small[:]}}
	before.grids = grids_small[:]
	testing.expect(t, !draw_table_copy(&before, &now))
	// Cells fewer than the rows of the grid: no record.
	grids_now[0].rows = 4
	draw_table_clear(&now)
	draw_text_grid(&now, 0, 0, 0)
	testing.expect(t, now.refused && !now.full && now.record_count == 0)
}

// A grid draws its characters and its reverse cells, cut to the canvas.
@(test)
text_grid_draws_its_cells :: proc(t: ^testing.T) {
	pixels: [40 * 32]graphics.Color
	canvas := graphics.Canvas{pixels = raw_data(pixels[:]), width = 40, height = 32, stride = 40}
	cells := [2 * 6]Text_Grid_Cell{}
	cells[0] = {'#', false, 0x00FF00}
	cells[7] = {' ', true, 0xFF0000}
	cells[5] = {'#', false, 0x0000FF} // Past the canvas: cut.
	grid := Text_Grid{cells = cells[:], columns = 6, rows = 2, stride = 6}
	text_grid_draw(canvas, 0, 0, grid)
	green, red := 0, 0
	for pixel in pixels {
		green += int(pixel == 0x00FF00)
		red += int(pixel == 0xFF0000)
	}
	testing.expect(t, green > 0, "the character of the first cell is drawn")
	testing.expectf(t, red == graphics.CELL_WIDTH * graphics.CELL_HEIGHT, "the reverse cell fills its cell: %d pixels", red)
}

// Two pictures: a frame equal to the older frame of its own picture draws
// nothing, but the screen shows the other picture, which differs: the
// present covers that difference.
@(test)
two_pictures_present_what_the_screen_shows :: proc(t: ^testing.T) {
	records_own, records_shown, records_now: [4]Draw_Record
	own := Draw_Table{records = records_own[:]}
	shown := Draw_Table{records = records_shown[:]}
	now := Draw_Table{records = records_now[:]}
	draw_rectangle(&own, 0, 0, 10, 10, 0xFF0000)
	draw_rectangle(&shown, 0, 0, 10, 10, 0x00FF00) // The frame just before.
	draw_rectangle(&now, 0, 0, 10, 10, 0xFF0000) // Back to the color of two frames before.
	draw, present: Damage
	damage_of_two_pictures(&own, &shown, true, &now, {0, 0, 40, 40}, &draw, &present)
	testing.expect_value(t, draw.count, 0)
	testing.expect_value(t, present.count, 1)
	testing.expect_value(t, present.rectangles[0], Rectangle{0, 0, 10, 10})
	// The table of the other picture is not known: the whole surface is
	// presented, also where no record of now draws.
	draw, present = {}, {}
	damage_of_two_pictures(&own, &shown, false, &now, {0, 0, 40, 40}, &draw, &present)
	testing.expect_value(t, present.count, 1)
	testing.expect_value(t, present.rectangles[0], Rectangle{0, 0, 40, 40})
}

// Two pictures and a screen, as display and the compositor do: each frame
// draws the damage of its own picture, presents a rectangle, and the screen
// takes that rectangle of the picture. After each frame the screen must be
// the frame drawn whole. The frames are those of the terminal: a grid that
// scrolls, bars of the graph that come and go, a thumb that moves.
@(test)
two_pictures_screen_is_each_frame :: proc(t: ^testing.T) {
	WIDTH :: 120
	HEIGHT :: 120
	COLUMNS :: 12
	ROWS :: 5
	pictures: [2][WIDTH * HEIGHT]graphics.Color
	screen, whole: [WIDTH * HEIGHT]graphics.Color
	canvas_of :: proc(pixels: ^[WIDTH * HEIGHT]graphics.Color) -> graphics.Canvas {
		return {pixels = raw_data(pixels[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
	}
	cells: [ROWS * COLUMNS]Text_Grid_Cell
	copies: [2][ROWS * COLUMNS]Text_Grid_Cell
	records_now: [64]Draw_Record
	records_before: [2][64]Draw_Record
	text_now: [256]u8
	text_before: [2][256]u8
	grids_now := [1]Text_Grid{{cells = cells[:], columns = COLUMNS, rows = ROWS, stride = COLUMNS}}
	grids_before := [2][1]Text_Grid{{{cells = copies[0][:]}}, {{cells = copies[1][:]}}}
	now := Draw_Table{records = records_now[:], text = text_now[:], grids = grids_now[:]}
	before := [2]Draw_Table{{records = records_before[0][:], text = text_before[0][:], grids = grids_before[0][:]}, {records = records_before[1][:], text = text_before[1][:], grids = grids_before[1][:]}}
	drawn: [2]bool
	picture := 0
	seed: u32 = 7
	for frame in 0 ..< 200 {
		// The frame: bars, the grid, a thumb.
		draw_table_clear(&now)
		for bar in 0 ..< 6 {
			seed = seed * 1103515245 + 12345
			draw_rectangle(&now, bar * 6, 0, 5, int(seed >> 16) % 3 * 4, 0x30A050)
		}
		for &cell, index in cells {
			cell = {u8('a' + (index / COLUMNS + frame * 3) % 26), (index + frame) % 17 == 0, 0xE0E0E0}
			if (index + frame) % 5 == 0 {
				cell.character = 0
			}
		}
		draw_text_grid(&now, 4, 16, 0)
		draw_rectangle(&now, 110, 16 + frame * 7 % 60, 6, 13, 0x5080C0)
		draw_text(&now, 4, 100, frame % 2 == 0 ? "line 12" : "line 3", 0xFFFFFF)

		// The reference: the frame drawn whole.
		graphics.clear(canvas_of(&whole), graphics.COLOR_BACKGROUND)
		execute(&now, canvas_of(&whole))

		// The frame as window_frame_end draws it.
		own := &before[picture]
		canvas := canvas_of(&pictures[picture])
		present: Rectangle
		if !drawn[picture] {
			graphics.clear(canvas, graphics.COLOR_BACKGROUND)
			execute(&now, canvas)
			present = {0, 0, WIDTH, HEIGHT}
		} else {
			draw, presented: Damage
			damage_of_two_pictures(own, &before[1 - picture], drawn[1 - picture], &now, {0, 0, WIDTH, HEIGHT}, &draw, &presented)
			draw_damage_on_surface(&now, canvas, draw.rectangles[:draw.count])
			present = intersection(damage_bounds(&presented), {0, 0, WIDTH, HEIGHT})
		}
		testing.expect(t, draw_table_copy(own, &now))
		drawn[picture] = true
		for y in present.top ..< present.bottom {
			for x in present.left ..< present.right {
				screen[y * WIDTH + x] = pictures[picture][y * WIDTH + x]
			}
		}
		testing.expectf(t, pictures[picture] == whole, "frame %d: the picture %d is not the frame", frame, picture)
		if screen != whole {
			testing.expectf(t, false, "frame %d: the screen is not the frame", frame)
			return
		}
		picture = 1 - picture
	}
}

@(private = "file")
LINE_TEST_WIDTH :: 8
@(private = "file")
LINE_TEST_HEIGHT :: 6

// line_rows draws one line in a canvas of 8 x 6 pixels and compares each
// row with a row written by hand: '#' is a pixel of the line.
@(private = "file")
line_rows :: proc(t: ^testing.T, name: string, from_x, from_y, to_x, to_y, thickness: int, expected: [LINE_TEST_HEIGHT]string) {
	pixels: [LINE_TEST_WIDTH * LINE_TEST_HEIGHT]graphics.Color
	canvas := graphics.Canvas{pixels = raw_data(pixels[:]), width = LINE_TEST_WIDTH, height = LINE_TEST_HEIGHT, stride = LINE_TEST_WIDTH}
	memory: Tables
	table := table_of(&memory)
	draw_line(&table, from_x, from_y, to_x, to_y, thickness, 0xFFFFFF)
	testing.expectf(t, table.record_count == 1, "%s: one record, not %d", name, table.record_count)
	execute(&table, canvas)
	for row in 0 ..< LINE_TEST_HEIGHT {
		found: [LINE_TEST_WIDTH]u8
		for column in 0 ..< LINE_TEST_WIDTH {
			found[column] = pixels[row * LINE_TEST_WIDTH + column] == 0xFFFFFF ? '#' : '.'
		}
		testing.expectf(t, string(found[:]) == expected[row], "%s, row %d: %s, not %s", name, row, string(found[:]), expected[row])
	}
}

// The pixels of a line, against pixels written by hand.
@(test)
line_pixels_by_hand :: proc(t: ^testing.T) {
	line_rows(t, "horizontal", 1, 1, 4, 1, 1, {
		"........",
		".####...",
		"........",
		"........",
		"........",
		"........",
	})
	line_rows(t, "vertical", 2, 0, 2, 3, 1, {
		"..#.....",
		"..#.....",
		"..#.....",
		"..#.....",
		"........",
		"........",
	})
	line_rows(t, "diagonal", 0, 0, 3, 3, 1, {
		"#.......",
		".#......",
		"..#.....",
		"...#....",
		"........",
		"........",
	})
	// Five columns for two rows: each row of the path is a run of two or
	// three pixels.
	line_rows(t, "shallow", 0, 0, 5, 2, 1, {
		"##......",
		"..##....",
		"....##..",
		"........",
		"........",
		"........",
	})
	// A thickness of 3: a square of 3 x 3 around each point.
	line_rows(t, "thick", 1, 2, 4, 2, 3, {
		"........",
		"######..",
		"######..",
		"######..",
		"........",
		"........",
	})
	// An even thickness starts one pixel before the point.
	line_rows(t, "even thickness", 2, 2, 4, 2, 2, {
		"........",
		".####...",
		".####...",
		"........",
		"........",
		"........",
	})
	// Length 0: one square.
	line_rows(t, "length 0", 5, 4, 5, 4, 3, {
		"........",
		"........",
		"........",
		"....###.",
		"....###.",
		"....###.",
	})
}

// A small generator of numbers for the tests: the same numbers at each run.
@(private = "file")
next_test_number :: proc(seed: ^u32, below: int) -> int {
	seed^ = seed^ * 1103515245 + 12345
	return int(seed^ >> 16) % below
}

// A line and its reverse are one record and draw the same pixels.
@(test)
line_and_its_reverse_are_one :: proc(t: ^testing.T) {
	SIDE :: 40
	seed: u32 = 11
	for round in 0 ..< 300 {
		from_x, from_y := next_test_number(&seed, 60) - 10, next_test_number(&seed, 60) - 10
		to_x, to_y := next_test_number(&seed, 60) - 10, next_test_number(&seed, 60) - 10
		thickness := 1 + next_test_number(&seed, 5)
		forward_memory, backward_memory: Tables
		forward, backward := table_of(&forward_memory), table_of(&backward_memory)
		draw_line(&forward, from_x, from_y, to_x, to_y, thickness, 0xFFFFFF)
		draw_line(&backward, to_x, to_y, from_x, from_y, thickness, 0xFFFFFF)
		testing.expectf(t, forward.records[0] == backward.records[0], "round %d: two records", round)
		forward_pixels, backward_pixels: [SIDE * SIDE]graphics.Color
		execute(&forward, {pixels = raw_data(forward_pixels[:]), width = SIDE, height = SIDE, stride = SIDE})
		execute(&backward, {pixels = raw_data(backward_pixels[:]), width = SIDE, height = SIDE, stride = SIDE})
		if forward_pixels != backward_pixels {
			testing.expectf(t, false, "round %d: (%d, %d) to (%d, %d) and its reverse differ", round, from_x, from_y, to_x, to_y)
			return
		}
	}
}

// When lines change, the damage holds each pixel that changed, and the
// surface drawn again in the damage is the new frame drawn whole.
@(test)
line_damage_holds_each_changed_pixel :: proc(t: ^testing.T) {
	SIDE :: 64
	seed: u32 = 5
	whole_canvas :: proc(pixels: ^[SIDE * SIDE]graphics.Color) -> graphics.Canvas {
		return {pixels = raw_data(pixels[:]), width = SIDE, height = SIDE, stride = SIDE}
	}
	for round in 0 ..< 200 {
		before_memory, now_memory: Tables
		before, now := table_of(&before_memory), table_of(&now_memory)
		both := [2]^Draw_Table{&before, &now}
		for table in both {
			for _ in 0 ..< 1 + next_test_number(&seed, 3) {
				draw_line(table, next_test_number(&seed, 100) - 18, next_test_number(&seed, 100) - 18, next_test_number(&seed, 100) - 18, next_test_number(&seed, 100) - 18, 1 + next_test_number(&seed, 6), graphics.Color(0x203040 + next_test_number(&seed, 3) * 0x402010))
			}
		}
		// Some rounds keep the first line: equal records damage nothing.
		if round % 3 == 0 {
			now.records[0] = before.records[0]
		}
		before_pixels, now_pixels: [SIDE * SIDE]graphics.Color
		graphics.clear(whole_canvas(&before_pixels), graphics.COLOR_BACKGROUND)
		execute(&before, whole_canvas(&before_pixels))
		graphics.clear(whole_canvas(&now_pixels), graphics.COLOR_BACKGROUND)
		execute(&now, whole_canvas(&now_pixels))
		damage: Damage
		damage_by_difference(&before, &now, &damage)
		for y in 0 ..< SIDE {
			for x in 0 ..< SIDE {
				if before_pixels[y * SIDE + x] == now_pixels[y * SIDE + x] {
					continue
				}
				inside := false
				for rectangle in damage.rectangles[:damage.count] {
					if x >= rectangle.left && x < rectangle.right && y >= rectangle.top && y < rectangle.bottom {
						inside = true
					}
				}
				if !inside {
					testing.expectf(t, false, "round %d: the pixel (%d, %d) changed outside the damage", round, x, y)
					return
				}
			}
		}
		draw_damage_on_surface(&now, whole_canvas(&before_pixels), damage.rectangles[:damage.count])
		testing.expectf(t, before_pixels == now_pixels, "round %d: the surface drawn in the damage is not the frame", round)
	}
}

// Hostile lines: refused, cut, or drawn with no pixel outside their place.
@(test)
line_hostile_values :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	// A thickness of 0 or less: no record.
	draw_line(&table, 0, 0, 10, 10, 0, 0xFFFFFF)
	draw_line(&table, 0, 0, 10, 10, -3, 0xFFFFFF)
	testing.expect_value(t, table.record_count, 0)
	// An end past the limit, or the smallest int: no record.
	draw_line(&table, 0, 0, LINE_COORDINATE_LIMIT + 1, 0, 1, 0xFFFFFF)
	draw_line(&table, min(int), 0, 4, 4, 1, 0xFFFFFF)
	draw_line(&table, 0, max(int), 4, 4, 1, 0xFFFFFF)
	testing.expect_value(t, table.record_count, 0)
	// A thickness past the limit is cut to it.
	draw_line(&table, 0, 0, 10, 0, 1000, 0xFFFFFF)
	testing.expect_value(t, table.record_count, 1)
	testing.expect_value(t, int(table.records[0].kind_detail), LINE_THICKNESS_LIMIT)
	// The ends at the limit: a record, and only the pixels in the canvas.
	draw_line(&table, -LINE_COORDINATE_LIMIT, 3, LINE_COORDINATE_LIMIT, 3, 1, 0xFFFFFF)
	testing.expect_value(t, table.record_count, 2)

	SIDE :: 16
	pixels: [SIDE * SIDE]graphics.Color
	canvas := graphics.Canvas{pixels = raw_data(pixels[:]), width = SIDE, height = SIDE, stride = SIDE}
	draw_table_clear(&table)
	draw_line(&table, -LINE_COORDINATE_LIMIT, 3, LINE_COORDINATE_LIMIT, 3, 1, 0xFFFFFF)
	execute(&table, canvas)
	for y in 0 ..< SIDE {
		for x in 0 ..< SIDE {
			testing.expectf(t, (pixels[y * SIDE + x] == 0xFFFFFF) == (y == 3), "the long line at (%d, %d)", x, y)
		}
	}

	// Records written by hand that the execution refuses: no pixel, no damage.
	pixels = {}
	hostile := [?]Draw_Record {
		{kind = .Line, kind_detail = 0, x = 1, y = 1, width = 5, height = 5, first_color = 0xFFFFFF},
		{kind = .Line, kind_detail = 200, x = 1, y = 1, width = 5, height = 5, first_color = 0xFFFFFF},
		{kind = .Line, kind_detail = 1, x = 1, y = 1, width = max(i32), height = 5, first_color = 0xFFFFFF},
		{kind = .Line, kind_detail = 1, x = min(i32), y = min(i32), width = max(i32), height = max(i32), first_color = 0xFFFFFF},
	}
	for record in hostile {
		testing.expect(t, empty(record_rectangle(record)), "a refused line covers nothing")
	}
	draw_table_clear(&table)
	for record in hostile {
		record_append(&table, record)
	}
	// A line fully outside the canvas.
	draw_line(&table, -40, -40, -20, -10, 3, 0xFFFFFF)
	draw_line(&table, SIDE + 4, 0, SIDE + 30, SIDE, 3, 0xFFFFFF)
	execute(&table, canvas)
	testing.expect(t, pixels == [SIDE * SIDE]graphics.Color{}, "no pixel from refused lines or lines outside")
	testing.expect_value(t, record_rectangle(table.records[4]), Rectangle{-41, -41, -18, -8})
}

// A picture record that names another picture of the table, with the same
// size and the same generation, is another thing to draw: it is damaged.
@(test)
picture_index_that_changes_is_damaged :: proc(t: ^testing.T) {
	record_before := [1]Draw_Record{{kind = .Picture, x = 8, y = 8, width = 16, height = 16, text_start = 0, text_count = 7}}
	record_now := [1]Draw_Record{{kind = .Picture, x = 8, y = 8, width = 16, height = 16, text_start = 1, text_count = 7}}
	before := Draw_Table{records = record_before[:], record_count = 1}
	now := Draw_Table{records = record_now[:], record_count = 1}
	damage: Damage
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 1)
	testing.expect_value(t, damage.rectangles[0], Rectangle{8, 8, 24, 24})
	record_now[0].text_start = 0
	damage = {}
	damage_by_difference(&before, &now, &damage)
	testing.expect_value(t, damage.count, 0)
}

// screen_after_damage draws the table before whole on a surface, then the
// table now in its damage only, as window_frame_end does, and says if the
// surface is the table now drawn whole.
@(private = "file")
screen_after_damage :: proc(before, now: ^Draw_Table) -> bool {
	surface := make([]graphics.Color, 320 * 200)
	defer delete(surface)
	whole := make([]graphics.Color, 320 * 200)
	defer delete(whole)
	canvas := graphics.Canvas{pixels = raw_data(surface), width = 320, height = 200, stride = 320}
	graphics.clear(canvas, graphics.COLOR_BACKGROUND)
	execute(before, canvas)
	damage: Damage
	damage_by_difference(before, now, &damage)
	draw_damage_on_surface(now, canvas, damage.rectangles[:damage.count])
	whole_canvas := graphics.Canvas{pixels = raw_data(whole), width = 320, height = 200, stride = 320}
	graphics.clear(whole_canvas, graphics.COLOR_BACKGROUND)
	execute(now, whole_canvas)
	return string(transmute([]u8)surface) == string(transmute([]u8)whole)
}

// Two tables with one grid each, in their own cells.
@(private = "file")
Grid_Tables :: struct {
	records_before, records_now: [8]Draw_Record,
	cells_before, cells_now:     [20 * 12]Text_Grid_Cell,
	grids_before, grids_now:     [1]Text_Grid,
	before, now:                 Draw_Table,
}

@(private = "file")
grid_tables_make :: proc(tables: ^Grid_Tables, columns, rows, stride: int) {
	for &cell, index in tables.cells_now {
		cell = {u8('A' + index % 26), index % 7 == 0, graphics.Color(0x406080 + index % 3 * 0x203010)}
	}
	tables.grids_now[0] = {cells = tables.cells_now[:], columns = columns, rows = rows, stride = stride}
	tables.grids_before[0] = {cells = tables.cells_before[:]}
	tables.now = {records = tables.records_now[:], grids = tables.grids_now[:]}
	tables.before = {records = tables.records_before[:], grids = tables.grids_before[:]}
}

// The grid of the frame before is the copy that draw_table_copy keeps; the
// grid now changes its size, its stride, its place or some cells. In each
// case the surface drawn again in the damage is the frame drawn whole.
@(test)
grid_damage_for_each_change :: proc(t: ^testing.T) {
	Change :: enum {
		Cells,
		Columns,
		Rows,
		Stride,
		Place,
	}
	for change in Change {
		tables: Grid_Tables
		grid_tables_make(&tables, 12, 6, 16)
		// The frame before: its own copy of the cells.
		before_grid := tables.grids_now[0]
		draw_text_grid(&tables.now, 20, 30, 0)
		testing.expect(t, draw_table_copy(&tables.before, &tables.now), "the copy fits")
		testing.expect_value(t, tables.before.grids[0].columns, before_grid.columns)
		draw_table_clear(&tables.now)
		place_x := 20
		switch change {
		case .Cells:
			tables.cells_now[2 * 16 + 5].character = '#'
			tables.cells_now[4 * 16 + 11].reverse = !tables.cells_now[4 * 16 + 11].reverse
		case .Columns:
			tables.grids_now[0].columns = 9
		case .Rows:
			tables.grids_now[0].rows = 8
		case .Stride:
			tables.grids_now[0].stride = 13
		case .Place:
			place_x = 28
		}
		draw_text_grid(&tables.now, place_x, 30, 0)
		testing.expect_value(t, tables.now.record_count, 1)
		testing.expectf(t, screen_after_damage(&tables.before, &tables.now), "%v: the surface drawn in the damage is not the frame", change)
	}
}

// A table before whose grid has fewer cells than its rows (a copy that a
// caller made by hand) is damaged whole: no cell is read past its end.
@(test)
grid_damage_with_too_few_cells_before :: proc(t: ^testing.T) {
	tables: Grid_Tables
	grid_tables_make(&tables, 12, 6, 16)
	draw_text_grid(&tables.now, 20, 30, 0)
	tables.records_before[0] = tables.records_now[0]
	tables.before.record_count = 1
	tables.grids_before[0] = {cells = tables.cells_before[:10], columns = 12, rows = 6, stride = 16}
	damage: Damage
	damage_by_difference(&tables.before, &tables.now, &damage)
	testing.expect_value(t, damage.count, 1)
	testing.expect_value(t, damage.rectangles[0], record_rectangle(tables.records_now[0]))
	// An index past the grids of the table before: the same.
	tables.before.grids = nil
	damage = {}
	damage_by_difference(&tables.before, &tables.now, &damage)
	testing.expect_value(t, damage.rectangles[0], record_rectangle(tables.records_now[0]))
}

// A grid drawn in damage rectangles that cut its cells, at negative places
// and with rectangles smaller than a cell, gives the pixels of the whole
// frame.
@(test)
text_grid_in_rectangles_equals_whole :: proc(t: ^testing.T) {
	tables: Grid_Tables
	grid_tables_make(&tables, 20, 12, 20)
	draw_text_grid(&tables.now, -13, -21, 0)
	whole := make([]graphics.Color, 320 * 200)
	defer delete(whole)
	parts := make([]graphics.Color, 320 * 200)
	defer delete(parts)
	whole_canvas := graphics.Canvas{pixels = raw_data(whole), width = 320, height = 200, stride = 320}
	parts_canvas := graphics.Canvas{pixels = raw_data(parts), width = 320, height = 200, stride = 320}
	graphics.clear(whole_canvas, graphics.COLOR_BACKGROUND)
	execute(&tables.now, whole_canvas)
	graphics.clear(parts_canvas, 0x123456)
	// Rectangles of 5 x 7 pixels, smaller than a cell, that cover the surface.
	for top := 0; top < 200; top += 7 {
		for left := 0; left < 320; left += 5 {
			rectangle := [1]Rectangle{{left, top, min(left + 5, 320), min(top + 7, 200)}}
			draw_damage_on_surface(&tables.now, parts_canvas, rectangle[:])
		}
	}
	testing.expect(t, string(transmute([]u8)whole) == string(transmute([]u8)parts), "the grid drawn in rectangles is the whole frame")
}

// draw_table_copy with too little room gives false: the caller draws the
// next frame of that picture whole.
@(test)
draw_table_copy_with_too_little_room :: proc(t: ^testing.T) {
	memory: Tables
	source := table_of(&memory)
	draw_rectangle(&source, 0, 0, 4, 4, 1)
	draw_text(&source, 0, 0, "twelve bytes", 1)
	few_records: [1]Draw_Record
	enough_text: [64]u8
	target := Draw_Table{records = few_records[:], text = enough_text[:]}
	testing.expect(t, !draw_table_copy(&target, &source), "two records do not fit in one")
	enough_records: [4]Draw_Record
	few_bytes: [4]u8
	target = {records = enough_records[:], text = few_bytes[:]}
	testing.expect(t, !draw_table_copy(&target, &source), "twelve bytes do not fit in four")
	target = {records = enough_records[:], text = enough_text[:]}
	testing.expect(t, draw_table_copy(&target, &source))
	testing.expect_value(t, target.record_count, 2)
}

// damage_add on random rectangles: at the end the rectangles are apart (no
// two touch), there are at most DAMAGE_CAPACITY, and they cover each
// rectangle that was added.
@(test)
damage_add_keeps_rectangles_apart_and_covers_each :: proc(t: ^testing.T) {
	seed: u32 = 23
	for round in 0 ..< 500 {
		damage: Damage
		added: [24]Rectangle
		count := 1 + next_test_number(&seed, len(added))
		for index in 0 ..< count {
			left, top := next_test_number(&seed, 300), next_test_number(&seed, 180)
			added[index] = {left, top, left + 1 + next_test_number(&seed, 40), top + 1 + next_test_number(&seed, 30)}
			damage_add(&damage, added[index])
		}
		testing.expect(t, damage.count <= DAMAGE_CAPACITY)
		for first in 0 ..< damage.count {
			for second in first + 1 ..< damage.count {
				a, b := damage.rectangles[first], damage.rectangles[second]
				apart := a.left > b.right || b.left > a.right || a.top > b.bottom || b.top > a.bottom
				if !apart {
					testing.expectf(t, false, "round %d: the rectangles %v and %v touch", round, a, b)
					return
				}
			}
		}
		for rectangle in added[:count] {
			covered := false
			for kept in damage.rectangles[:damage.count] {
				if kept.left <= rectangle.left && kept.top <= rectangle.top && kept.right >= rectangle.right && kept.bottom >= rectangle.bottom {
					covered = true
				}
			}
			if !covered {
				testing.expectf(t, false, "round %d: %v is not covered", round, rectangle)
				return
			}
		}
	}
}

// A clip that becomes another kind of record at the same index, and two
// clips one after the other: each later record is damaged, and the surface
// is the frame.
@(test)
clip_that_changes_kind :: proc(t: ^testing.T) {
	first, second: Tables
	before, now := table_of(&first), table_of(&second)
	draw_clip(&before, 10, 10, 60, 40)
	draw_rectangle(&before, 0, 0, 200, 100, graphics.COLOR_KERNEL)
	draw_clip(&before, 0, 0, 0, 0)
	draw_rectangle(&now, 10, 10, 60, 40, graphics.COLOR_PROGRAM)
	draw_rectangle(&now, 0, 0, 200, 100, graphics.COLOR_KERNEL)
	draw_clip(&now, 0, 0, 0, 0)
	testing.expect(t, screen_after_damage(&before, &now), "a clip that becomes a rectangle")
	testing.expect(t, screen_after_damage(&now, &before), "a rectangle that becomes a clip")
	draw_table_clear(&before)
	draw_table_clear(&now)
	draw_clip(&before, 0, 0, 100, 100)
	draw_clip(&before, 50, 50, 100, 100)
	draw_rectangle(&before, 0, 0, 320, 200, graphics.COLOR_KERNEL)
	draw_clip(&now, 0, 0, 100, 100)
	draw_clip(&now, 20, 20, 100, 100)
	draw_rectangle(&now, 0, 0, 320, 200, graphics.COLOR_KERNEL)
	testing.expect(t, screen_after_damage(&before, &now), "the second of two clips changes")
}

// The table of the shown picture is not known, and the shown frame had a
// record that the frame now does not have, far from each record of now:
// the present covers it, because it is the whole surface.
@(test)
two_pictures_unknown_shown_table_presents_all :: proc(t: ^testing.T) {
	records_own, records_shown, records_now: [4]Draw_Record
	own := Draw_Table{records = records_own[:]}
	shown := Draw_Table{records = records_shown[:]}
	now := Draw_Table{records = records_now[:]}
	draw_rectangle(&own, 0, 0, 10, 10, 0xFF0000)
	draw_rectangle(&shown, 0, 0, 10, 10, 0xFF0000)
	draw_rectangle(&shown, 200, 150, 20, 20, 0x00FF00) // Only the shown frame has it.
	draw_rectangle(&now, 0, 0, 10, 10, 0xFF0000)
	draw, present: Damage
	damage_of_two_pictures(&own, &shown, false, &now, {0, 0, 320, 200}, &draw, &present)
	testing.expect_value(t, draw.count, 0)
	bounds := damage_bounds(&present)
	testing.expect(t, bounds.left <= 200 && bounds.top <= 150 && bounds.right >= 220 && bounds.bottom >= 170, "the record that only the shown frame had is presented")
}

// Each edge of a record is cut to COORDINATE_LIMIT, then the size is the
// difference: a rectangle that covers the surface with places past the i32
// still covers it.
@(test)
coordinates_cut_by_their_edges :: proc(t: ^testing.T) {
	memory: Tables
	table := table_of(&memory)
	draw_rectangle(&table, -3_000_000_000, -3_000_000_000, 5_000_000_000, 5_000_000_000, 1)
	area := record_rectangle(table.records[0])
	testing.expect(t, area.left <= 0 && area.top <= 0 && area.right >= 320 && area.bottom >= 200, "the rectangle still covers the surface")
	testing.expect(t, table.records[0].width > 0 && table.records[0].height > 0)
	// No sum passes the int.
	draw_rectangle(&table, max(int) - 2, 0, max(int), 10, 1)
	area = record_rectangle(table.records[1])
	testing.expect_value(t, area.left, COORDINATE_LIMIT - 1)
	testing.expect_value(t, area.right, COORDINATE_LIMIT - 1)
	draw_text(&table, min(int) + 1, 0, "text", 1)
	testing.expect_value(t, int(table.records[2].x), -COORDINATE_LIMIT)
	// A rectangle inside the limit keeps its place and its size.
	draw_rectangle(&table, -7, 12, 30, 5, 1)
	testing.expect_value(t, record_rectangle(table.records[3]), Rectangle{-7, 12, 23, 17})
}

// Numbers of a grid that would wrap a product are refused, and the record
// is refused with no change of full.
@(test)
grid_numbers_that_wrap_are_refused :: proc(t: ^testing.T) {
	cells: [16]Text_Grid_Cell
	wrapping := [?]Text_Grid {
		{cells = cells[:], columns = 4, rows = max(int) / 2, stride = 4},
		{cells = cells[:], columns = 4, rows = 3, stride = max(int) / 2 + 1},
		{cells = cells[:], columns = 4, rows = 2, stride = -4},
		{cells = cells[:], columns = 17, rows = 1, stride = 17},
		{cells = cells[:], columns = -1, rows = 1, stride = 4},
	}
	for grid, index in wrapping {
		testing.expectf(t, !grid_valid(grid), "grid %d is refused", index)
		testing.expectf(t, grid_size(grid) == 0, "grid %d has no size", index)
	}
	testing.expect(t, grid_valid({cells = cells[:], columns = 4, rows = 4, stride = 4}))
	testing.expect_value(t, grid_size({cells = cells[:], columns = 3, rows = 4, stride = 4}), 15)
	grids := [1]Text_Grid{wrapping[0]}
	records: [2]Draw_Record
	table := Draw_Table{records = records[:], grids = grids[:]}
	draw_text_grid(&table, 0, 0, 0)
	testing.expect(t, table.refused && !table.full && table.record_count == 0)
}

// A new font makes the next frame of each picture whole: with two pictures,
// the second one must not keep text in the old font.
@(test)
whole_window_next_forgets_each_picture :: proc(t: ^testing.T) {
	drawing: Window_Drawing
	drawing.drawn, drawing.drawn_second = true, true
	draw_whole_window_next(&drawing)
	testing.expect(t, !drawing.drawn && !drawing.drawn_second)
}
