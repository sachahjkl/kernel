#+build !freestanding
package interface

import "contract:glyph_cache"
import "core:testing"
import "support:display"
import "support:graphics"
import "support:vector_font"

// The interface font of the tests: B612 Regular (three positions at scale
// 1, one at the scales 2 and 3) and B612 Bold (scale 1, three positions),
// built from the subsets, in memory that the caller frees.
@(private = "file")
Test_Interface_Font :: struct {
	font:           display.Interface_Font,
	regular_memory: []u64,
	bold_memory:    []u64,
}

@(private = "file")
test_interface_font :: proc(t: ^testing.T) -> (result: Test_Interface_Font) {
	Weight :: struct {
		bytes:     []u8,
		name:      string,
		positions: []int,
	}
	regular_positions := [3]int{3, 1, 1}
	bold_positions := [1]int{3}
	weights := [2]Weight{{#load("../../resources/fonts/b612.ttf"), "b612", regular_positions[:]}, {#load("../../resources/fonts/b612_bold.ttf"), "b612_bold", bold_positions[:]}}
	render := new(vector_font.Render_Memory)
	defer free(render)
	for weight, index in weights {
		file, problem := vector_font.font_open(weight.bytes)
		testing.expect_value(t, problem, vector_font.Font_Problem.None)
		memory := make([]u64, vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT / 8)
		out := ([^]u8)(raw_data(memory))[:vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT]
		size: int
		size, problem = vector_font.glyph_cache_build_proportional(&file, weight.bytes, weight.name, true, render, out, weight.positions)
		testing.expect_value(t, problem, vector_font.Font_Problem.None)
		cache, refused := glyph_cache.validate(out[:size])
		testing.expect_value(t, refused.kind, glyph_cache.Problem_Kind.None)
		if index == 0 {
			result.font.regular, result.regular_memory = cache, memory
		} else {
			result.font.bold, result.bold_memory = cache, memory
		}
	}
	return result
}

@(private = "file")
test_interface_font_free :: proc(font: ^Test_Interface_Font) {
	delete(font.regular_memory)
	delete(font.bold_memory)
}

@(private = "file")
Font_Tables :: struct {
	records: [256]Draw_Record,
	text:    [4096]u8,
}

@(private = "file")
font_table_of :: proc(memory: ^Font_Tables, font: ^display.Interface_Font) -> Draw_Table {
	return {records = memory.records[:], text = memory.text[:], interface_font = font}
}

// The generator of the tests: the same numbers on each host.
@(private = "file")
next_number :: proc(state: ^u32) -> int {
	state^ = state^ * 1664525 + 1013904223
	return int(state^ >> 8)
}

@(private = "file")
WORDS :: [?]string{"To", "LT", "Ty", "settings", "AVATAR", "Wave", "launcher", "jj", "fill", "rings", "0O 1lI", "Monitor", "the clock", "W", "i"}

// The parts of a frame of build_labels that a change can name.
@(private = "file")
LABEL_PARTS :: 17

// pick gives the next number of the generator; for the part that changed,
// the number after it, so that this part shows another word, place, weight
// or color. The generator takes the same steps in both frames, so each
// other part is the same.
@(private = "file")
pick :: proc(state: ^u32, part: ^int, changed: int) -> int {
	number := next_number(state)
	if part^ == changed {
		number += 1
	}
	part^ += 1
	return number
}

// One frame of labels in the interface font, side by side so that their
// ink margins overlap, with a label and a value, a button and a card, all
// from one seed; the part `changed` differs from the frame with no change.
@(private = "file")
build_labels :: proc(table: ^Draw_Table, seed: u32, changed: int) {
	words := WORDS
	state := seed
	part := 0
	draw_table_clear(table)
	draw_rectangle(table, 0, 0, 320, 200, graphics.COLOR_BACKGROUND)
	card_state := Interface_State{}
	card_input := Input{}
	frame := Frame{table = table, state = &card_state, input = &card_input}
	title := words[pick(&state, &part, changed) % len(words)]
	caption := words[pick(&state, &part, changed) % len(words)]
	card(&frame, {4, 4, 312, 72}, title, caption, graphics.COLOR_KERNEL, "12")
	x := 8
	for _ in 0 ..< 6 {
		chosen := pick(&state, &part, changed)
		word := words[chosen % len(words)]
		font := (chosen / 16) % 4 == 0 ? FONT_INTERFACE_BOLD : FONT_INTERFACE
		color := (chosen / 64) % 3 == 0 ? graphics.COLOR_DIM : graphics.COLOR_TEXT
		after := draw_text(table, x, 40, word, u32(color), font)
		// The next label starts at the end of this one, or 1 or 2 pixels
		// before it: their ink margins overlap.
		x = after - (chosen / 256) % 3
	}
	// Texts that end at a place: their origins are at a third of a pixel.
	for row in 0 ..< 3 {
		chosen := pick(&state, &part, changed)
		right := 200 + chosen % 7
		draw_text_right(table, right, 80 + row * 18, words[(chosen / 8) % len(words)], graphics.COLOR_TEXT, FONT_INTERFACE)
		next := pick(&state, &part, changed)
		draw_text(table, right + 4 - next % 3, 80 + row * 18, words[(next / 4) % len(words)], graphics.COLOR_PROGRAM, FONT_INTERFACE)
	}
	label := words[pick(&state, &part, changed) % len(words)]
	value := words[pick(&state, &part, changed) % len(words)]
	label_value_line(&frame, {8, 140, 300, 16}, label, value)
	button(&frame, {8, 164, 140, 24}, identity("press"), words[pick(&state, &part, changed) % len(words)])
	draw_text(table, 160, 168, words[pick(&state, &part, changed) % len(words)], graphics.COLOR_TEXT, {kind = .Interface, scale = 2})
}

// The damage of a frame in the interface font, drawn as a window draws it
// (each damage rectangle painted with the background, then each record
// that touches it drawn again, in order), gives the bytes of the whole
// frame: no stale pixel and no missing pixel, for 200 pairs of frames that
// differ in one part (or in none).
@(test)
damage_of_interface_text_equals_the_whole_frame :: proc(t: ^testing.T) {
	font := test_interface_font(t)
	defer test_interface_font_free(&font)
	first, second := new(Font_Tables), new(Font_Tables)
	defer free(first)
	defer free(second)
	before, now := font_table_of(first, &font.font), font_table_of(second, &font.font)
	partial := make([]graphics.Color, 320 * 200)
	defer delete(partial)
	whole := make([]graphics.Color, 320 * 200)
	defer delete(whole)
	partial_canvas := graphics.Canvas{pixels = raw_data(partial), width = 320, height = 200, stride = 320}
	whole_canvas := graphics.Canvas{pixels = raw_data(whole), width = 320, height = 200, stride = 320}
	differing_frames := 0
	interface_records := 0
	damaged_frames := 0
	for pair in 0 ..< 200 {
		// The two frames from one seed; in the second, one part changed
		// (the part LABEL_PARTS changes nothing: the same frame).
		seed := u32(pair * 7919 + 1)
		build_labels(&before, seed, LABEL_PARTS)
		build_labels(&now, seed, pair % (LABEL_PARTS + 1))
		for record in now.records[:now.record_count] {
			if record.kind == .Interface_Text {
				interface_records += 1
			}
		}
		graphics.clear(partial_canvas, graphics.COLOR_BACKGROUND)
		execute(&before, partial_canvas)
		damage: Damage
		damage_by_difference(&before, &now, &damage)
		if damage.count > 0 {
			damaged_frames += 1
		}
		draw_damage_on_surface(&now, partial_canvas, damage.rectangles[:damage.count])
		graphics.clear(whole_canvas, graphics.COLOR_BACKGROUND)
		execute(&now, whole_canvas)
		if string(transmute([]u8)partial) != string(transmute([]u8)whole) {
			differing_frames += 1
		}
	}
	testing.expect(t, interface_records > 0, "the frames hold texts in the interface font")
	testing.expect(t, damaged_frames > 100, "most pairs of frames differ")
	testing.expectf(t, differing_frames == 0, "%v of 200 frames drawn in their damage differ from the whole frame", differing_frames)
}

// The box of the measure of a text record: its rectangle without its ink
// margin.
@(private = "file")
measured_box :: proc(record: Draw_Record) -> Rectangle {
	box := record_rectangle(record)
	if record.kind == .Interface_Text {
		margin := int(record.second_color)
		box.left += margin
		box.right -= margin
	}
	return box
}

// No element lets a text pass its box, in the font of the cells and in
// the interface font: each element with texts too long for it, then each
// text record of its frame inside the area of the element. The large
// number of a card is not in the list: it is a value that the caller
// places, with no box.
@(test)
no_element_passes_its_box_in_either_font :: proc(t: ^testing.T) {
	font := test_interface_font(t)
	defer test_interface_font_free(&font)
	LONG :: "a name far too long for its box, WWWWW MMMMM, and more text after it"
	Element_Case :: struct {
		name: string,
		area: Area,
		draw: proc(frame: ^Frame, area: Area),
	}
	cases := [?]Element_Case {
		{"card", {8, 8, 200, 80}, proc(frame: ^Frame, area: Area) {card(frame, area, LONG, LONG, graphics.COLOR_KERNEL, "12 345")}},
		{"label and value at the right", {8, 8, 200, 16}, proc(frame: ^Frame, area: Area) {label_value_line(frame, area, LONG, "1 234 567")}},
		{"label and value at a column", {8, 8, 200, 16}, proc(frame: ^Frame, area: Area) {label_value_line(frame, area, LONG, LONG, graphics.COLOR_TEXT, 96)}},
		{"button", {8, 8, 120, 24}, proc(frame: ^Frame, area: Area) {button(frame, area, identity("button"), LONG)}},
		{"list", {8, 8, 160, 72}, proc(frame: ^Frame, area: Area) {
				names := [?]string{LONG, "WWWWWWWWWWWWWWWWWWWWWW", "short"}
				choice := 0
				list_with_choice(frame, area, identity("list"), names[:], &choice, {marked = "far", chosen_hint = "enter: start"})
			}},
		{"empty list", {8, 8, 120, 72}, proc(frame: ^Frame, area: Area) {
				choice := 0
				list_with_choice(frame, area, identity("empty"), nil, &choice, {empty_text = LONG})
			}},
		{"table header", {8, 8, 240, 24}, proc(frame: ^Frame, area: Area) {
				cells: [3]Area
				sizes := [3]Size{share(), characters(6), characters(6)}
				row_split(area, sizes[:], cells[:], 8)
				table_header(frame, cells[:], {LONG, LONG, "bytes"}, {.Left, .Right, .Right})
			}},
		{"cell text in the interface font", {8, 8, 100, 24}, proc(frame: ^Frame, area: Area) {cell_text(frame, area, LONG, graphics.COLOR_TEXT, .Right, FONT_INTERFACE)}},
		{"cell text in the font of the cells", {8, 8, 100, 24}, proc(frame: ^Frame, area: Area) {cell_text(frame, area, LONG, graphics.COLOR_TEXT)}},
		{"text input", {8, 8, 120, 24}, proc(frame: ^Frame, area: Area) {
				typed: [64]u8
				count := copy(typed[:], LONG)
				text_input(frame, area, identity("input"), typed[:], &count)
				empty := 0
				text_input(frame, area, identity("placeholder"), typed[:], &empty, LONG)
			}},
	}
	fonts := [2]^display.Interface_Font{nil, &font.font}
	for interface_font in fonts {
		for item in cases {
			memory := new(Font_Tables)
			defer free(memory)
			table := font_table_of(memory, interface_font)
			state: Interface_State
			input: Input
			frame := frame_begin(&table, &state, &input)
			item.draw(&frame, item.area)
			frame_end(&frame)
			for record in table.records[:table.record_count] {
				if !is_text_kind(record.kind) {
					continue
				}
				box := measured_box(record)
				inside := box.left >= item.area.x && box.right <= item.area.x + item.area.width && box.top >= item.area.y && box.bottom <= item.area.y + item.area.height
				testing.expectf(t, inside, "%s (interface font: %v): a text at %v passes the area %v", item.name, interface_font != nil, box, item.area)
				testing.expectf(t, (record.kind == .Interface_Text) == false || interface_font != nil, "%s: an interface text with no interface font", item.name)
			}
		}
	}
}

// A text in the interface font is measured and drawn in the font that the
// table has: with no interface font, or when the text is longer than the
// limit, it is a text of the font of the cells, measured as one.
@(test)
the_font_of_a_text_is_the_font_of_its_measure :: proc(t: ^testing.T) {
	font := test_interface_font(t)
	defer test_interface_font_free(&font)
	with_font, without_font := new(Font_Tables), new(Font_Tables)
	defer free(with_font)
	defer free(without_font)
	table := font_table_of(with_font, &font.font)
	plain := font_table_of(without_font, nil)
	after := draw_text(&table, 10, 0, "To LT", graphics.COLOR_TEXT, FONT_INTERFACE)
	testing.expect_value(t, table.records[0].kind, Draw_Kind.Interface_Text)
	testing.expect_value(t, after, 10 + text_measured_width(&table, FONT_INTERFACE, "To LT"))
	margin := int(table.records[0].second_color)
	testing.expect_value(t, margin, graphics.PROPORTIONAL_INK_MARGIN)
	testing.expect_value(t, int(table.records[0].x), 10 - margin)
	plain_after := draw_text(&plain, 10, 0, "To LT", graphics.COLOR_TEXT, FONT_INTERFACE)
	testing.expect_value(t, plain.records[0].kind, Draw_Kind.Text)
	testing.expect_value(t, plain_after, 10 + 5 * graphics.CELL_WIDTH)
	long: [INTERFACE_TEXT_LIMIT + 1]u8
	for &byte in long {
		byte = 'a'
	}
	draw_text(&table, 0, 20, string(long[:]), graphics.COLOR_TEXT, FONT_INTERFACE)
	testing.expect_value(t, table.records[1].kind, Draw_Kind.Text)
	// A text that ends at a place: its origin is at a third of a pixel, and
	// its measured box ends at the place, rounded up.
	draw_text_right(&table, 100, 40, "Ty", graphics.COLOR_TEXT, FONT_INTERFACE)
	record := table.records[2]
	testing.expect(t, record.text_origin_thirds <= 2)
	testing.expect(t, int(record.x + record.width) - int(record.second_color) <= 101)
	// The measure of many texts in one call gives the measures one by one.
	texts := [?]string{"To", "LT", "launcher", "", "W"}
	widths: [len(texts)]int
	texts_measure(&table, FONT_INTERFACE, texts[:], widths[:])
	for text, index in texts {
		testing.expect_value(t, widths[index], text_measured_width(&table, FONT_INTERFACE, text))
	}
	fitted := text_fit(&table, FONT_INTERFACE, "settings and more", 40)
	testing.expect(t, text_measured_width(&table, FONT_INTERFACE, fitted) <= 40 && len(fitted) < len("settings and more"))
}

// An Interface_Text record that a caller wrote by hand: a range outside
// the text table, a third of 3, an ink margin that would wrap or pass its
// limit, a scale of 0 or 4: it draws nothing and makes no fault, and a
// record with a range outside its table is equal to no record.
@(test)
hostile_interface_text_records_draw_nothing :: proc(t: ^testing.T) {
	font := test_interface_font(t)
	defer test_interface_font_free(&font)
	memory := new(Font_Tables)
	defer free(memory)
	table := font_table_of(memory, &font.font)
	copy(table.text[:], "To LT")
	table.text_count = 5
	good := Draw_Record{kind = .Interface_Text, text_scale = 1, first_color = graphics.COLOR_TEXT, second_color = 2, x = 0, y = 0, width = 60, height = 16, text_start = 0, text_count = 5}
	hostile := [?]Draw_Record {
		{kind = .Interface_Text, text_scale = 1, first_color = graphics.COLOR_TEXT, second_color = 2, width = 60, height = 16, text_start = 3, text_count = 5},
		{kind = .Interface_Text, text_scale = 1, first_color = graphics.COLOR_TEXT, second_color = 2, width = 60, height = 16, text_start = max(u32), text_count = max(u32)},
		{kind = .Interface_Text, text_scale = 1, text_origin_thirds = 3, first_color = graphics.COLOR_TEXT, second_color = 2, width = 60, height = 16, text_count = 5},
		{kind = .Interface_Text, text_scale = 1, first_color = graphics.COLOR_TEXT, second_color = max(u32), width = 60, height = 16, text_count = 5},
		{kind = .Interface_Text, text_scale = 1, first_color = graphics.COLOR_TEXT, second_color = INK_MARGIN_LIMIT + 1, width = 60, height = 16, text_count = 5},
		{kind = .Interface_Text, text_scale = 0, first_color = graphics.COLOR_TEXT, second_color = 2, width = 60, height = 16, text_count = 5},
		{kind = .Interface_Text, text_scale = 4, first_color = graphics.COLOR_TEXT, second_color = 2, width = 60, height = 16, text_count = 5},
		{kind = .Interface_Text, text_scale = 1, first_color = graphics.COLOR_TEXT, second_color = 2, x = max(i32), y = max(i32), width = max(i32), height = max(i32), text_count = 5},
	}
	pixels: [64 * 16]graphics.Color
	canvas := graphics.Canvas{pixels = raw_data(pixels[:]), width = 64, height = 16, stride = 64}
	for record, index in hostile {
		table.records[0] = record
		table.record_count = 1
		pixels = {}
		execute(&table, canvas)
		testing.expectf(t, pixels == [64 * 16]graphics.Color{}, "the hostile record %v draws", index)
	}
	// The good record draws.
	table.records[0] = good
	execute(&table, canvas)
	testing.expect(t, pixels != [64 * 16]graphics.Color{}, "the good record draws")
	// A range outside the table is equal to no record, so it is damaged.
	testing.expect(t, !records_equal(&table, hostile[0], &table, hostile[0]))
	testing.expect(t, records_equal(&table, good, &table, good))
}
