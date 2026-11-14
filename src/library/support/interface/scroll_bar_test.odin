#+build !freestanding
package interface

import "support:display"
import "support:graphics"
import "core:testing"

// The tests of the scroll bar: its geometry, the part under a point, what
// a press, a hold, a page and a drag do, and the draw records of each
// state against the table of src/library/support/graphics/scroll_bar.odin. A hold is
// tested with the time of each frame as a number: no test waits.

@(private = "file")
Bar_Tables :: struct {
	records: [128]Draw_Record,
	text:    [64]u8,
}

@(private = "file")
bar_table_of :: proc(memory: ^Bar_Tables) -> Draw_Table {
	return {records = memory.records[:], text = memory.text[:]}
}

// The bar of the tests: the scroll bar of the console, 17 by 428 pixels,
// over 100 lines of which the view shows 26.
@(private = "file")
BAR_AREA :: Area{0, 0, SCROLL_BAR_THICKNESS, 428}

@(private = "file")
bar_frame :: proc(table: ^Draw_Table, state: ^Interface_State, input: ^Input, first: int, time: u64 = 0, steps: Scroll_Bar_Steps = {}) -> Scroll_Bar_Result {
	frame := frame_begin(table, state, input, time)
	result := scroll_bar(&frame, BAR_AREA, identity("bar"), .Vertical, {total = 100, visible = 26, first = first}, steps)
	frame_end(&frame)
	input_clear(input)
	return result
}

@(private = "file")
pointer_at :: proc(input: ^Input, x, y: int, held: bool) {
	input_add(input, {kind = .Pointer, x = x, y = y, buttons = held ? display.BUTTON_LEFT : 0})
}

@(test)
scroll_bar_geometry_places_the_thumb :: proc(t: ^testing.T) {
	geometry := scroll_bar_geometry(428, 17, {total = 100, visible = 26, first = 0})
	testing.expect_value(t, geometry.arrow_length, 17)
	testing.expect_value(t, geometry.track_start, 17)
	testing.expect_value(t, geometry.track_length, 394)
	// The share of the view: 394 * 26 / 100.
	testing.expect_value(t, geometry.thumb_length, 102)
	testing.expect_value(t, geometry.thumb_room, 292)
	testing.expect_value(t, geometry.range, 74)
	testing.expect_value(t, geometry.thumb_start, 17)
	testing.expect(t, geometry.grip)
	// The last view: the thumb ends where the track ends.
	geometry = scroll_bar_geometry(428, 17, {total = 100, visible = 26, first = 74})
	testing.expect_value(t, geometry.thumb_start + geometry.thumb_length, 411)
	// The middle, and a first unit past the range.
	geometry = scroll_bar_geometry(428, 17, {total = 100, visible = 26, first = 37})
	testing.expect_value(t, geometry.thumb_start, 163)
	geometry = scroll_bar_geometry(428, 17, {total = 100, visible = 26, first = 5000})
	testing.expect_value(t, geometry.first, 74)
	geometry = scroll_bar_geometry(428, 17, {total = 100, visible = 26, first = -3})
	testing.expect_value(t, geometry.first, 0)
}

@(test)
scroll_bar_thumb_has_a_least_length :: proc(t: ^testing.T) {
	// A long content: 8 percent of the track of 394 pixels.
	geometry := scroll_bar_geometry(428, 17, {total = 100000, visible = 26, first = 0})
	testing.expect_value(t, geometry.thumb_length, 394 * graphics.SCROLL_BAR_THUMB_LEAST_PERCENT / 100)
	testing.expect(t, geometry.grip)
	// A short track: the least count of pixels, and no grip.
	geometry = scroll_bar_geometry(84, 17, {total = 100000, visible = 26, first = 0})
	testing.expect_value(t, geometry.track_length, 50)
	testing.expect_value(t, geometry.thumb_length, graphics.SCROLL_BAR_THUMB_LEAST)
	testing.expect(t, !geometry.grip)
	// A view that shows the whole content: the thumb is the track.
	geometry = scroll_bar_geometry(428, 17, {total = 10, visible = 26, first = 4})
	testing.expect_value(t, geometry.thumb_length, 394)
	testing.expect_value(t, geometry.range, 0)
	testing.expect_value(t, geometry.first, 0)
	// A bar too short for its arrow buttons: the track takes it whole.
	geometry = scroll_bar_geometry(41, 17, {total = 100, visible = 26, first = 0})
	testing.expect_value(t, geometry.arrow_length, 0)
	testing.expect_value(t, geometry.track_length, 41)
	geometry = scroll_bar_geometry(42, 17, {total = 100, visible = 26, first = 0})
	testing.expect_value(t, geometry.arrow_length, 17)
	// No content, a negative size and a huge total divide by nothing and
	// stay inside the bar.
	geometry = scroll_bar_geometry(428, 17, {})
	testing.expect_value(t, geometry.thumb_start, 17)
	geometry = scroll_bar_geometry(-5, 17, {total = 100, visible = 26})
	testing.expect_value(t, geometry.thumb_length, 0)
	geometry = scroll_bar_geometry(428, 17, {total = max(int), visible = 26, first = max(int)})
	testing.expect(t, geometry.thumb_start + geometry.thumb_length <= 411)
}

@(test)
scroll_bar_grip_needs_a_thumb_longer_than_twenty_pixels :: proc(t: ^testing.T) {
	// A track of 100 pixels.
	geometry := scroll_bar_geometry(134, 17, {total = 5, visible = 1, first = 0})
	testing.expect_value(t, geometry.thumb_length, 20)
	testing.expect(t, !geometry.grip)
	geometry = scroll_bar_geometry(134, 17, {total = 100, visible = 21, first = 0})
	testing.expect_value(t, geometry.thumb_length, 21)
	testing.expect(t, geometry.grip)
}

@(test)
scroll_bar_part_under_a_point :: proc(t: ^testing.T) {
	// The thumb is at 163 ..< 265.
	geometry := scroll_bar_geometry(428, 17, {total = 100, visible = 26, first = 37})
	Case :: struct {
		along: int,
		part:  Scroll_Bar_Part,
	}
	cases := [?]Case {
		{-1, .None},
		{0, .Arrow_Back},
		{16, .Arrow_Back},
		{17, .Track_Back},
		{162, .Track_Back},
		{163, .Thumb},
		{264, .Thumb},
		{265, .Track_Forward},
		{410, .Track_Forward},
		{411, .Arrow_Forward},
		{427, .Arrow_Forward},
		{428, .None},
	}
	for item in cases {
		testing.expectf(t, scroll_bar_part_at(geometry, item.along) == item.part, "at %d: %v, not %v", item.along, scroll_bar_part_at(geometry, item.along), item.part)
	}
	// The first unit of a thumb at a place: the two ends, the middle, and
	// a place past each end.
	testing.expect_value(t, scroll_bar_first_at(geometry, 17), 0)
	testing.expect_value(t, scroll_bar_first_at(geometry, 309), 74)
	testing.expect_value(t, scroll_bar_first_at(geometry, 163), 37)
	testing.expect_value(t, scroll_bar_first_at(geometry, -400), 0)
	testing.expect_value(t, scroll_bar_first_at(geometry, 4000), 74)
}

@(test)
scroll_bar_arrow_button_steps_and_repeats_by_the_clock :: proc(t: ^testing.T) {
	memory: Bar_Tables
	table := bar_table_of(&memory)
	state: Interface_State
	input: Input
	first := 37
	// A press on the arrow button at the end: one line, at once.
	pointer_at(&input, 8, 420, true)
	result := bar_frame(&table, &state, &input, first, 1000)
	testing.expect_value(t, result.first, 38)
	testing.expect(t, result.changed)
	testing.expect_value(t, result.pressed_now, Scroll_Bar_Part.Arrow_Forward)
	testing.expect_value(t, state.scroll_bar_repeat_at, u64(1000 + graphics.SCROLL_BAR_REPEAT_AFTER))
	first = result.first
	// Held, before the time of the first repeat: no step.
	result = bar_frame(&table, &state, &input, first, 1399)
	testing.expect(t, !result.changed)
	testing.expect_value(t, result.held, Scroll_Bar_Part.Arrow_Forward)
	// At the time: one step, and the next one after the short period.
	result = bar_frame(&table, &state, &input, first, 1400)
	testing.expect_value(t, result.first, 39)
	testing.expect_value(t, state.scroll_bar_repeat_at, u64(1400 + graphics.SCROLL_BAR_REPEAT_EVERY))
	first = result.first
	result = bar_frame(&table, &state, &input, first, 1459)
	testing.expect(t, !result.changed)
	result = bar_frame(&table, &state, &input, first, 1460)
	testing.expect_value(t, result.first, 40)
	first = result.first
	// The pointer leaves the button with the button held: no step is due.
	pointer_at(&input, 8, 200, true)
	result = bar_frame(&table, &state, &input, first, 9000)
	testing.expect(t, !result.changed)
	testing.expect_value(t, state.scroll_bar_repeat_at, u64(0))
	// It comes back: the steps start again after one period.
	pointer_at(&input, 8, 420, true)
	result = bar_frame(&table, &state, &input, first, 9100)
	testing.expect(t, !result.changed)
	result = bar_frame(&table, &state, &input, first, 9100 + graphics.SCROLL_BAR_REPEAT_EVERY)
	testing.expect_value(t, result.first, 41)
	first = result.first
	// The button goes up: nothing is held, and no step is due.
	pointer_at(&input, 8, 420, false)
	result = bar_frame(&table, &state, &input, first, 9200)
	testing.expect(t, !result.changed)
	testing.expect_value(t, state.pressed, Element_Identity(0))
	testing.expect_value(t, state.scroll_bar_part, Scroll_Bar_Part.None)
	testing.expect_value(t, state.scroll_bar_repeat_at, u64(0))
	result = bar_frame(&table, &state, &input, first, 99000)
	testing.expect(t, !result.changed)
	// The arrow button at the start, and a line of 3 units; at the first
	// unit a press changes nothing.
	pointer_at(&input, 8, 3, true)
	result = bar_frame(&table, &state, &input, first, 99100, {line = 3})
	testing.expect_value(t, result.first, 38)
	pointer_at(&input, 8, 3, false)
	bar_frame(&table, &state, &input, 38, 99200)
	pointer_at(&input, 8, 3, true)
	result = bar_frame(&table, &state, &input, 0, 99300)
	testing.expect_value(t, result.first, 0)
	testing.expect(t, !result.changed)
	// A frame with no clock: the press steps, the hold does not.
	pointer_at(&input, 8, 3, false)
	bar_frame(&table, &state, &input, 0)
	pointer_at(&input, 8, 420, true)
	result = bar_frame(&table, &state, &input, 10)
	testing.expect_value(t, result.first, 11)
	testing.expect_value(t, state.scroll_bar_repeat_at, u64(0))
	result = bar_frame(&table, &state, &input, 11)
	testing.expect(t, !result.changed)
}

@(test)
scroll_bar_press_on_the_track_pages :: proc(t: ^testing.T) {
	memory: Bar_Tables
	table := bar_table_of(&memory)
	state: Interface_State
	input: Input
	// After the thumb (163 ..< 265): one page forward, the units in view.
	pointer_at(&input, 8, 300, true)
	result := bar_frame(&table, &state, &input, 37)
	testing.expect_value(t, result.pressed_now, Scroll_Bar_Part.Track_Forward)
	testing.expect_value(t, result.first, 63)
	// Held on the track: no second page.
	result = bar_frame(&table, &state, &input, 63, 5000)
	testing.expect(t, !result.changed)
	pointer_at(&input, 8, 300, false)
	bar_frame(&table, &state, &input, 63)
	// Before the thumb, with a page of 25 units.
	pointer_at(&input, 8, 50, true)
	result = bar_frame(&table, &state, &input, 37, 0, {page = 25})
	testing.expect_value(t, result.pressed_now, Scroll_Bar_Part.Track_Back)
	testing.expect_value(t, result.first, 12)
	pointer_at(&input, 8, 50, false)
	bar_frame(&table, &state, &input, 12)
	// A page past the end stops at the last view.
	pointer_at(&input, 8, 405, true)
	result = bar_frame(&table, &state, &input, 60)
	testing.expect_value(t, result.first, 74)
}

@(test)
scroll_bar_thumb_follows_the_pointer_while_it_is_held :: proc(t: ^testing.T) {
	memory: Bar_Tables
	table := bar_table_of(&memory)
	state: Interface_State
	input: Input
	// A press on the thumb moves nothing.
	pointer_at(&input, 8, 200, true)
	result := bar_frame(&table, &state, &input, 37)
	testing.expect_value(t, result.pressed_now, Scroll_Bar_Part.Thumb)
	testing.expect(t, !result.changed)
	testing.expect_value(t, state.scroll_bar_grab, 37)
	// The pointer goes down by 146 pixels: the thumb starts at 309, the
	// last view.
	pointer_at(&input, 8, 346, true)
	result = bar_frame(&table, &state, &input, 37)
	testing.expect_value(t, result.first, 74)
	testing.expect_value(t, result.held, Scroll_Bar_Part.Thumb)
	// The pointer leaves the bar, far above it: the bar keeps the press,
	// and the view is the first one.
	pointer_at(&input, 500, -50, true)
	result = bar_frame(&table, &state, &input, 74)
	testing.expect_value(t, result.first, 0)
	testing.expect(t, !result.under_pointer)
	testing.expect_value(t, state.scroll_bar_lit, identity("bar"))
	// The button goes up there: the drag ends, and the bar is at rest.
	pointer_at(&input, 500, -50, false)
	result = bar_frame(&table, &state, &input, 0)
	testing.expect(t, result.drag_ended)
	testing.expect_value(t, state.pressed, Element_Identity(0))
	testing.expect_value(t, state.scroll_bar_lit, Element_Identity(0))
	// A pointer that moves over the bar with no button moves nothing.
	pointer_at(&input, 8, 300, false)
	result = bar_frame(&table, &state, &input, 0)
	testing.expect(t, !result.changed)
	testing.expect(t, result.under_pointer)
	// One frame that holds a press, a move and a release: the press is
	// at its own place, on the thumb, and the move is a drag.
	pointer_at(&input, 8, 200, true)
	pointer_at(&input, 8, 346, true)
	pointer_at(&input, 8, 346, false)
	result = bar_frame(&table, &state, &input, 37)
	testing.expect_value(t, result.pressed_now, Scroll_Bar_Part.Thumb)
	testing.expect_value(t, result.first, 74)
	testing.expect(t, result.drag_ended)
}

@(test)
scroll_bar_asks_for_a_frame_only_for_its_pointer :: proc(t: ^testing.T) {
	memory: Bar_Tables
	table := bar_table_of(&memory)
	state: Interface_State
	input: Input
	bar_identity := identity("bar")
	testing.expect(t, !scroll_bar_wants_frame(&state, &input, BAR_AREA, bar_identity))
	// A pointer beside the bar.
	pointer_at(&input, 300, 200, false)
	testing.expect(t, !scroll_bar_wants_frame(&state, &input, BAR_AREA, bar_identity))
	// On it: a frame, which draws the bar lit.
	pointer_at(&input, 8, 200, false)
	testing.expect(t, scroll_bar_wants_frame(&state, &input, BAR_AREA, bar_identity))
	bar_frame(&table, &state, &input, 37)
	// Beside it again: one frame more, which draws the bar at rest.
	pointer_at(&input, 300, 200, false)
	testing.expect(t, scroll_bar_wants_frame(&state, &input, BAR_AREA, bar_identity))
	bar_frame(&table, &state, &input, 37)
	testing.expect(t, !scroll_bar_wants_frame(&state, &input, BAR_AREA, bar_identity))
}

// The records of one color and one kind, and the last of them.
@(private = "file")
records_of :: proc(table: ^Draw_Table, kind: Draw_Kind, color: graphics.Color) -> (count: int, last: Draw_Record) {
	for record in table.records[:table.record_count] {
		if record.kind == kind && record.first_color == u32(color) {
			count += 1
			last = record
		}
	}
	return
}

@(private = "file")
expect_record :: proc(t: ^testing.T, record: Draw_Record, kind: Draw_Kind, x, y, width, height: i32, first_color: graphics.Color, second_color: graphics.Color = 0, loc := #caller_location) {
	testing.expectf(t, record.kind == kind && record.x == x && record.y == y && record.width == width && record.height == height && record.first_color == u32(first_color) && record.second_color == u32(second_color), "the record is %v at %d,%d of %d by %d in %06x and %06x", record.kind, record.x, record.y, record.width, record.height, record.first_color, record.second_color, loc = loc)
}

@(test)
scroll_bar_at_rest_draws_the_table :: proc(t: ^testing.T) {
	memory: Bar_Tables
	table := bar_table_of(&memory)
	state: Interface_State
	input: Input
	bar_frame(&table, &state, &input, 37)
	colors := graphics.scroll_bar_colors_dark
	records := table.records[:table.record_count]
	testing.expect_value(t, table.record_count, 24)
	if table.record_count != 24 {
		return
	}
	// The track: its border under the whole bar, then its three stops as
	// two gradients across the 15 pixels inside the border.
	expect_record(t, records[0], .Rectangle, 0, 0, 17, 428, colors.track_border)
	expect_record(t, records[1], .Horizontal_Gradient, 1, 1, 8, 426, colors.track[0], colors.track[1])
	expect_record(t, records[2], .Horizontal_Gradient, 8, 1, 8, 426, colors.track[1], colors.track[2])
	// At rest an arrow button is its triangle: rows of 1, 3, 5 and 7
	// pixels, the point toward its end of the bar, on the column 8.
	expect_record(t, records[3], .Rectangle, 8, 6, 1, 1, colors.triangle)
	expect_record(t, records[4], .Rectangle, 7, 7, 3, 1, colors.triangle)
	expect_record(t, records[5], .Rectangle, 6, 8, 5, 1, colors.triangle)
	expect_record(t, records[6], .Rectangle, 5, 9, 7, 1, colors.triangle)
	expect_record(t, records[7], .Rectangle, 5, 417, 7, 1, colors.triangle)
	expect_record(t, records[10], .Rectangle, 8, 420, 1, 1, colors.triangle)
	// The thumb, at 163 ..< 265: its border, the inner line (the stops of
	// its fill moved toward white), its fill inside the line, the two
	// sides of the line.
	expect_record(t, records[11], .Rectangle, 0, 163, 17, 102, colors.thumb_border)
	lined: [4]graphics.Color
	for &color, index in lined {
		color = graphics.mix(colors.thumb_rest[index], graphics.COLOR_WHITE, colors.thumb_line_level)
	}
	expect_record(t, records[12], .Horizontal_Gradient, 1, 164, 7, 100, lined[0], lined[1])
	expect_record(t, records[13], .Horizontal_Gradient, 7, 164, 3, 100, lined[1], lined[2])
	expect_record(t, records[14], .Horizontal_Gradient, 9, 164, 7, 100, lined[2], lined[3])
	expect_record(t, records[15], .Horizontal_Gradient, 1, 165, 7, 98, colors.thumb_rest[0], colors.thumb_rest[1])
	expect_record(t, records[16], .Horizontal_Gradient, 7, 165, 3, 98, colors.thumb_rest[1], colors.thumb_rest[2])
	expect_record(t, records[17], .Horizontal_Gradient, 9, 165, 7, 98, colors.thumb_rest[2], colors.thumb_rest[3])
	expect_record(t, records[18], .Rectangle, 1, 165, 1, 98, lined[0])
	expect_record(t, records[19], .Rectangle, 15, 165, 1, 98, lined[3])
	// The grip: four lines of 7 pixels in the middle of the thumb.
	for grip_line in 0 ..< 4 {
		expect_record(t, records[20 + grip_line], .Rectangle, 5, i32(210 + 2 * grip_line), 7, 1, colors.grip)
	}
	// Each record has the identity of the bar, and stays inside it.
	for record in records {
		testing.expect_value(t, record.element, u32(identity("bar")))
		testing.expect(t, record.x >= 0 && record.y >= 0 && record.x + record.width <= 17 && record.y + record.height <= 428)
	}
}

@(test)
scroll_bar_states_draw_the_colors_of_the_table :: proc(t: ^testing.T) {
	memory: Bar_Tables
	table := bar_table_of(&memory)
	state: Interface_State
	input: Input
	colors := graphics.scroll_bar_colors_dark
	count: int
	record: Draw_Record

	// The pointer over the thumb: the whole bar is lit. Each arrow button
	// has the lit border and the lit fill; the thumb has the hot border,
	// the hot fill and the lit grip.
	pointer_at(&input, 8, 200, false)
	bar_frame(&table, &state, &input, 37)
	testing.expect_value(t, table.record_count, 28)
	count, record = records_of(&table, .Rectangle, colors.lit_border)
	testing.expect_value(t, count, 2)
	expect_record(t, record, .Rectangle, 0, 411, 17, 17, colors.lit_border)
	count, record = records_of(&table, .Horizontal_Gradient, colors.arrow_lit[0])
	testing.expect_value(t, count, 2)
	expect_record(t, record, .Horizontal_Gradient, 1, 412, 15, 15, colors.arrow_lit[0], colors.arrow_lit[1])
	count, record = records_of(&table, .Rectangle, colors.hot_border)
	testing.expect_value(t, count, 1)
	expect_record(t, record, .Rectangle, 0, 163, 17, 102, colors.hot_border)
	count, _ = records_of(&table, .Horizontal_Gradient, colors.thumb_hot[0])
	testing.expect_value(t, count, 1)
	count, _ = records_of(&table, .Rectangle, colors.grip_lit)
	testing.expect_value(t, count, 4)
	count, _ = records_of(&table, .Rectangle, colors.triangle)
	testing.expect_value(t, count, 8)

	// The pointer over the arrow button at the end: that button is hot,
	// the other one lit.
	pointer_at(&input, 8, 420, false)
	bar_frame(&table, &state, &input, 37)
	count, record = records_of(&table, .Horizontal_Gradient, colors.arrow_hot[0])
	testing.expect_value(t, count, 1)
	expect_record(t, record, .Horizontal_Gradient, 1, 412, 15, 15, colors.arrow_hot[0], colors.arrow_hot[1])
	count, _ = records_of(&table, .Horizontal_Gradient, colors.arrow_lit[0])
	testing.expect_value(t, count, 1)
	count, _ = records_of(&table, .Rectangle, colors.triangle_hot)
	testing.expect_value(t, count, 4)
	count, _ = records_of(&table, .Rectangle, colors.triangle)
	testing.expect_value(t, count, 4)
	// The hot border: the hot button and the thumb of a lit bar.
	count, _ = records_of(&table, .Rectangle, colors.hot_border)
	testing.expect_value(t, count, 2)

	// The button held: the pressed fill.
	pointer_at(&input, 8, 420, true)
	bar_frame(&table, &state, &input, 37)
	count, record = records_of(&table, .Horizontal_Gradient, colors.arrow_pressed[0])
	testing.expect_value(t, count, 1)
	expect_record(t, record, .Horizontal_Gradient, 1, 412, 15, 15, colors.arrow_pressed[0], colors.arrow_pressed[1])
	pointer_at(&input, 8, 420, false)
	bar_frame(&table, &state, &input, 37)

	// The thumb held, with the pointer outside the bar: the pressed fill,
	// and the bar stays lit.
	pointer_at(&input, 8, 200, true)
	bar_frame(&table, &state, &input, 37)
	pointer_at(&input, 300, 200, true)
	bar_frame(&table, &state, &input, 37)
	count, _ = records_of(&table, .Horizontal_Gradient, colors.thumb_pressed[0])
	testing.expect_value(t, count, 1)
	count, _ = records_of(&table, .Rectangle, colors.lit_border)
	testing.expect_value(t, count, 2)
	count, _ = records_of(&table, .Rectangle, colors.grip_lit)
	testing.expect_value(t, count, 4)
	pointer_at(&input, 300, 200, false)
	bar_frame(&table, &state, &input, 37)

	// The pointer away: the records of the bar at rest.
	testing.expect_value(t, table.record_count, 24)
	count, _ = records_of(&table, .Rectangle, colors.thumb_border)
	testing.expect_value(t, count, 1)
}

@(test)
scroll_bar_horizontal_is_the_vertical_one_turned :: proc(t: ^testing.T) {
	memory: Bar_Tables
	table := bar_table_of(&memory)
	colors := graphics.scroll_bar_colors_dark
	scroll_bar_draw(&table, {0, 0, 428, 17}, .Horizontal, scroll_bar_geometry(428, 17, {total = 100, visible = 26, first = 37}))
	records := table.records[:table.record_count]
	testing.expect_value(t, table.record_count, 24)
	if table.record_count != 24 {
		return
	}
	// The gradients go from the top down.
	expect_record(t, records[0], .Rectangle, 0, 0, 428, 17, colors.track_border)
	expect_record(t, records[1], .Vertical_Gradient, 1, 1, 426, 8, colors.track[0], colors.track[1])
	expect_record(t, records[2], .Vertical_Gradient, 1, 8, 426, 8, colors.track[1], colors.track[2])
	// The triangle of the first arrow button points to the left.
	expect_record(t, records[3], .Rectangle, 6, 8, 1, 1, colors.triangle)
	expect_record(t, records[6], .Rectangle, 9, 5, 1, 7, colors.triangle)
	expect_record(t, records[11], .Rectangle, 163, 0, 102, 17, colors.thumb_border)
	// The lines of the grip stand.
	expect_record(t, records[20], .Rectangle, 210, 5, 1, 7, colors.grip)
}

@(test)
scroll_bar_light_form_draws_the_light_colors :: proc(t: ^testing.T) {
	memory: Bar_Tables
	table := bar_table_of(&memory)
	colors := graphics.scroll_bar_colors_light
	scroll_bar_draw(&table, BAR_AREA, .Vertical, scroll_bar_geometry(428, 17, {total = 100, visible = 26, first = 37}), {}, &colors)
	testing.expect_value(t, table.records[0].first_color, u32(colors.track_border))
	count, _ := records_of(&table, .Rectangle, colors.thumb_border)
	testing.expect_value(t, count, 1)
}

// A short bar (a list of two rows) has no arrow button; a thumb too short
// for its grip has none.
@(test)
scroll_bar_short_bar_draws_its_track_and_its_thumb :: proc(t: ^testing.T) {
	memory: Bar_Tables
	table := bar_table_of(&memory)
	colors := graphics.scroll_bar_colors_dark
	scroll_bar_draw(&table, {0, 0, 17, 32}, .Vertical, scroll_bar_geometry(32, 17, {total = 40, visible = 2, first = 10}))
	count, _ := records_of(&table, .Rectangle, colors.triangle)
	testing.expect_value(t, count, 0)
	count, _ = records_of(&table, .Rectangle, colors.grip)
	testing.expect_value(t, count, 0)
	thumb: Draw_Record
	count, thumb = records_of(&table, .Rectangle, colors.thumb_border)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, int(thumb.height), graphics.SCROLL_BAR_THUMB_LEAST)
}

// The scroll bar of a list with a choice moves the choice, which the view
// follows.
@(test)
list_with_choice_scroll_bar_moves_the_choice :: proc(t: ^testing.T) {
	memory: Bar_Tables
	table := bar_table_of(&memory)
	state: Interface_State
	input: Input
	names := []string{"a", "b", "c", "d", "e", "f", "g", "h", "i", "j"}
	choice := 0
	area := Area{0, 0, 200, 4 * TABLE_LINE}
	// The bar is the last 17 pixels of the list, 96 pixels high. A press
	// on its arrow button at the end: the view starts at the line 1, and
	// the choice is its last line.
	pointer_at(&input, 190, 90, true)
	frame := frame_begin(&table, &state, &input)
	result := list_with_choice(&frame, area, identity("list"), names, &choice)
	frame_end(&frame)
	input_clear(&input)
	testing.expect_value(t, choice, 4)
	testing.expect(t, result.changed)
	// The fill of the chosen line stops before the bar.
	count, fill := records_of(&table, .Rectangle, graphics.COLOR_CHOSEN)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, int(fill.width), 200 - SCROLL_BAR_THICKNESS)
	// A list whose lines fit has no bar: no record of the track.
	pointer_at(&input, 190, 90, false)
	frame = frame_begin(&table, &state, &input)
	list_with_choice(&frame, area, identity("list"), names[:3], &choice)
	frame_end(&frame)
	count, _ = records_of(&table, .Rectangle, graphics.scroll_bar_colors_dark.track_border)
	testing.expect_value(t, count, 0)
}

// The inner line of the thumb is an opaque color: the fill moved toward
// white by the level of the table.
@(test)
scroll_bar_inner_line_is_opaque :: proc(t: ^testing.T) {
	colors := graphics.scroll_bar_colors_dark
	line_color := graphics.scroll_bar_thumb_line_color(&colors, colors.thumb_rest[0])
	testing.expect_value(t, line_color, graphics.mix(colors.thumb_rest[0], graphics.COLOR_WHITE, 0x1F))
	testing.expect(t, line_color & 0xFF000000 == 0)
	// The places of the stops across the 15 pixels inside the border.
	percents := graphics.SCROLL_BAR_THUMB_STOP_PERCENTS
	testing.expect_value(t, graphics.scroll_bar_stop_place(percents[0], 15), 0)
	testing.expect_value(t, graphics.scroll_bar_stop_place(percents[1], 15), 6)
	testing.expect_value(t, graphics.scroll_bar_stop_place(percents[2], 15), 8)
	testing.expect_value(t, graphics.scroll_bar_stop_place(percents[3], 15), 14)
}
