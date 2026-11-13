#+build !freestanding
package palette

import "core:testing"
import "support:graphics"
import "support:interface"
import "support:line_editor"

@(private = "file")
PROGRAMS := [?]string{"boot", "pages", "log", "console", "monitor", "plasma", "life", "paint", "temple", "clock"}

// A panel with the programs above and the windows console (in front) and
// plasma.
@(private = "file")
panel_of_test :: proc(panel: ^Panel) {
	panel.pressed_row = NO_ROW
	entries_collect(panel, PROGRAMS[:], {{title = "console", number = 3, focus = true}, {title = "plasma", number = 7}})
}

@(private = "file")
type_text :: proc(panel: ^Panel, text: string) {
	for index in 0 ..< len(text) {
		typed_edit(panel, .Character, text[index])
	}
}

// The row of the list as "name (kind)", or the heading in brackets.
@(private = "file")
row_text :: proc(panel: ^Panel, row: int) -> string {
	item := panel.rows[row]
	switch item.kind {
	case .Heading_Recent:
		return "[recent]"
	case .Heading_Windows:
		return "[windows]"
	case .Heading_Programs:
		return "[programs]"
	case .Entry:
		entry := &panel.entries[item.entry]
		parts := [?]string{entry_name(entry), " (", kind_words(entry.kind), ")"}
		buffer := make([]u8, 128, context.temp_allocator)
		count := 0
		for part in parts {
			count += copy(buffer[count:], part)
		}
		return string(buffer[:count])
	}
	return ""
}

// Each state with each key: the whole table of key_action.
@(test)
each_key_in_each_state :: proc(t: ^testing.T) {
	for key in Key {
		testing.expect_value(t, key_action(.Closed, key), key == .Super ? Action.Open : Action.None)
	}
	search := [Key]Action {
		.Other     = .None,
		.Super     = .Close,
		.Escape    = .Close,
		.Enter     = .Run,
		.Up        = .Choose_Previous,
		.Down      = .Choose_Next,
		.Page_Up   = .Choose_Page_Before,
		.Page_Down = .Choose_Page_After,
		.Left      = .Edit,
		.Right     = .Edit,
		.Home      = .Edit,
		.End       = .Edit,
		.Backspace = .Edit,
		.Delete    = .Edit,
		.Character = .Edit,
		.Tab       = .None,
	}
	for key in Key {
		testing.expectf(t, key_action(.Search, key) == search[key], "Search, %v: %v", key, key_action(.Search, key))
	}
	// The question: Enter confirms, the key super closes, each other key
	// only goes back: it never edits and never destroys.
	for key in Key {
		expected := Action.Back
		#partial switch key {
		case .Enter:
			expected = .Confirm
		case .Super:
			expected = .Close
		}
		testing.expectf(t, key_action(.Confirm, key) == expected, "Confirm, %v: %v", key, key_action(.Confirm, key))
	}
}

// The state that follows each action.
@(test)
the_state_after_each_action :: proc(t: ^testing.T) {
	testing.expect_value(t, state_after(.Closed, .Open, .Nothing), State.Search)
	testing.expect_value(t, state_after(.Search, .Close, .Runs), State.Closed)
	testing.expect_value(t, state_after(.Confirm, .Close, .Destroys), State.Closed)
	// Enter: an empty list keeps the search, an entry that runs closes the
	// panel, an entry that destroys asks first.
	testing.expect_value(t, state_after(.Search, .Run, .Nothing), State.Search)
	testing.expect_value(t, state_after(.Search, .Run, .Runs), State.Closed)
	testing.expect_value(t, state_after(.Search, .Run, .Destroys), State.Confirm)
	testing.expect_value(t, state_after(.Confirm, .Confirm, .Destroys), State.Closed)
	testing.expect_value(t, state_after(.Confirm, .Back, .Destroys), State.Search)
	// An action that a state does not give changes nothing.
	testing.expect_value(t, state_after(.Search, .Confirm, .Destroys), State.Search)
	testing.expect_value(t, state_after(.Closed, .Run, .Runs), State.Closed)
	for action in ([]Action{.None, .Edit, .Choose_Previous, .Choose_Next, .Choose_Page_Before, .Choose_Page_After}) {
		for state in State {
			testing.expect_value(t, state_after(state, action, .Runs), state)
		}
	}
}

// The entries of the two sources: the windows, the programs, the closes;
// the mark of each one says one fact.
@(test)
entries_of_the_two_sources :: proc(t: ^testing.T) {
	panel := new(Panel)
	defer free(panel)
	panel_of_test(panel)
	testing.expect_value(t, panel.entry_count, 2 + len(PROGRAMS) + 2)
	testing.expect_value(t, entry_name(&panel.entries[0]), "console")
	testing.expect_value(t, panel.entries[0].kind, Entry_Kind.Window)
	testing.expect_value(t, panel.entries[0].mark, Entry_Mark.Has_Focus)
	testing.expect_value(t, panel.entries[0].number, 3)
	testing.expect_value(t, panel.entries[1].mark, Entry_Mark.None)
	for &entry in panel.entries[:panel.entry_count] {
		if entry.kind != .Program {
			continue
		}
		has_window := entry_name(&entry) == "console" || entry_name(&entry) == "plasma"
		testing.expect_value(t, entry.mark, has_window ? Entry_Mark.Has_Window : Entry_Mark.No_Window)
	}
	last := &panel.entries[panel.entry_count - 1]
	testing.expect_value(t, entry_name(last), "close plasma")
	testing.expect_value(t, last.kind, Entry_Kind.Close_Window)
	testing.expect_value(t, last.mark, Entry_Mark.Destroys)
	testing.expect_value(t, last.number, 7)
	testing.expect(t, entry_destroys(last))
	testing.expect_value(t, window_title_of(last), "plasma")
}

// A name is whole or absent: a name longer than its room is not listed,
// and an empty one is not listed.
@(test)
a_name_too_long_is_not_listed :: proc(t: ^testing.T) {
	panel := new(Panel)
	defer free(panel)
	long: [NAME_CAPACITY + 1]u8
	for &character in long {
		character = 'a'
	}
	names := [?]string{"clock", string(long[:]), "", string(long[:NAME_CAPACITY])}
	entries_collect(panel, names[:], nil)
	testing.expect_value(t, panel.entry_count, 2)
	testing.expect_value(t, entry_name(&panel.entries[1]), string(long[:NAME_CAPACITY]))
	testing.expect_value(t, panel.entries[1].number, 3)
}

// One ranked list over the two kinds: with equal scores a window comes
// before the program of the same name, and the close comes last.
@(test)
one_ranked_list_over_the_kinds :: proc(t: ^testing.T) {
	panel := new(Panel)
	defer free(panel)
	panel_of_test(panel)
	type_text(panel, "pla")
	testing.expect_value(t, panel.row_count, 3)
	testing.expect_value(t, panel.matched_count, 3)
	testing.expect_value(t, row_text(panel, 0), "plasma (window)")
	testing.expect_value(t, row_text(panel, 1), "plasma (program)")
	testing.expect_value(t, row_text(panel, 2), "close plasma (close a window)")
	testing.expect_value(t, panel.choice, 0)
	// The matched characters of each name: the places that the row marks.
	testing.expect_value(t, panel.rows[0].places, line_editor.Match_Places{0, 1, 2})
	testing.expect_value(t, panel.rows[2].places, line_editor.Match_Places{6, 7, 8})
	// The match is fuzzy: the characters in their order, not side by side.
	line_editor.line_clear(&panel.line)
	type_text(panel, "closepla")
	testing.expect_value(t, panel.row_count, 1)
	testing.expect_value(t, row_text(panel, 0), "close plasma (close a window)")
	testing.expect_value(t, chosen_of(panel), Chosen.Destroys)
	// No entry has the part: no row, no choice.
	line_editor.line_clear(&panel.line)
	type_text(panel, "xyz")
	testing.expect_value(t, panel.row_count, 0)
	testing.expect_value(t, panel.choice, NO_ROW)
	testing.expect_value(t, chosen_of(panel), Chosen.Nothing)
	testing.expect(t, chosen_entry(panel) == nil)
}

// A recent choice comes first among equal scores only: a better match
// always comes before it.
@(test)
a_recent_choice_wins_a_tie_only :: proc(t: ^testing.T) {
	panel := new(Panel)
	defer free(panel)
	panel_of_test(panel)
	for &entry in panel.entries[:panel.entry_count] {
		if entry.kind == .Program && (entry_name(&entry) == "paint" || entry_name(&entry) == "temple") {
			recent_note(panel, &entry)
		}
	}
	panel_of_test(panel)
	// "p": each name that starts with p has one score; the recent one first,
	// then the window, then the programs in the order of their table.
	type_text(panel, "p")
	testing.expect_value(t, row_text(panel, 0), "paint (program)")
	testing.expect_value(t, row_text(panel, 1), "plasma (window)")
	testing.expect_value(t, row_text(panel, 2), "pages (program)")
	testing.expect_value(t, row_text(panel, 3), "plasma (program)")
	// "pl": plasma holds it at its start, temple in its middle. temple is
	// the newest choice, and still comes after each plasma.
	type_text(panel, "l")
	testing.expect_value(t, row_text(panel, 0), "plasma (window)")
	testing.expect_value(t, row_text(panel, 1), "plasma (program)")
	testing.expect_value(t, row_text(panel, 2), "temple (program)")
}

// With no typed part: the windows, the front one first, then the programs
// in the order of their table, each group under its heading. No recent
// choice: no group "recent". The closes show only for a typed part.
@(test)
the_first_open_shows_groups :: proc(t: ^testing.T) {
	panel := new(Panel)
	defer free(panel)
	panel_of_test(panel)
	testing.expect_value(t, panel.row_count, 1 + 2 + 1 + len(PROGRAMS))
	testing.expect_value(t, row_text(panel, 0), "[windows]")
	testing.expect_value(t, row_text(panel, 1), "console (window)")
	testing.expect_value(t, row_text(panel, 2), "plasma (window)")
	testing.expect_value(t, row_text(panel, 3), "[programs]")
	testing.expect_value(t, row_text(panel, 4), "boot (program)")
	testing.expect_value(t, panel.choice, 1)
	testing.expect_value(t, panel.matched_count, 2 + len(PROGRAMS))
	for row in panel.rows[:panel.row_count] {
		testing.expect(t, row.kind != .Entry || panel.entries[row.entry].kind != .Close_Window)
	}
	// After a choice: the group "recent" is first, the newest choice first.
	recent_note(panel, &panel.entries[2 + 5]) // plasma, the program.
	recent_note(panel, &panel.entries[1]) // plasma, the window.
	panel_of_test(panel)
	testing.expect_value(t, row_text(panel, 0), "[recent]")
	testing.expect_value(t, row_text(panel, 1), "plasma (window)")
	testing.expect_value(t, row_text(panel, 2), "plasma (program)")
	testing.expect_value(t, row_text(panel, 3), "[windows]")
	testing.expect_value(t, panel.choice, 1)
}

// With no window, the list starts with the programs.
@(test)
no_window_no_group :: proc(t: ^testing.T) {
	panel := new(Panel)
	defer free(panel)
	entries_collect(panel, PROGRAMS[:], nil)
	testing.expect_value(t, row_text(panel, 0), "[programs]")
	testing.expect_value(t, panel.choice, 1)
	entries_collect(panel, nil, nil)
	testing.expect_value(t, panel.row_count, 0)
	testing.expect_value(t, panel.choice, NO_ROW)
	testing.expect(t, !choice_move(panel, .Next))
}

// The choice goes from the last entry to the first and back, and never
// stops on a heading. The rows shown always hold it.
@(test)
the_choice_wraps_and_skips_headings :: proc(t: ^testing.T) {
	panel := new(Panel)
	defer free(panel)
	panel_of_test(panel)
	last := panel.row_count - 1
	testing.expect_value(t, panel.choice, 1)
	testing.expect(t, choice_move(panel, .Previous))
	testing.expect_value(t, panel.choice, last)
	testing.expect(t, panel.choice >= panel.first_row && panel.choice < panel.first_row + LIST_ROWS)
	testing.expect(t, choice_move(panel, .Next))
	testing.expect_value(t, panel.choice, 1)
	// The first entry is chosen: its heading shows over it.
	testing.expect_value(t, panel.first_row, 0)
	// Down from the last window: over the heading of the programs.
	testing.expect(t, choice_move(panel, .Next))
	testing.expect_value(t, panel.choice, 2)
	testing.expect(t, choice_move(panel, .Next))
	testing.expect_value(t, panel.choice, 4)
	testing.expect(t, choice_move(panel, .Previous))
	testing.expect_value(t, panel.choice, 2)
	// Each row of a whole turn is an entry, and the view holds it.
	for _ in 0 ..< panel.row_count {
		choice_move(panel, .Next)
		testing.expect(t, row_is_entry(panel, panel.choice))
		testing.expect(t, panel.choice >= panel.first_row && panel.choice < panel.first_row + LIST_ROWS)
	}
}

// A page moves the choice by 11 rows and does not wrap.
@(test)
a_page_does_not_wrap :: proc(t: ^testing.T) {
	panel := new(Panel)
	defer free(panel)
	panel_of_test(panel)
	last := panel.row_count - 1 // 13: the list has 14 rows.
	testing.expect(t, choice_move(panel, .Page_After))
	testing.expect_value(t, panel.choice, 1 + PAGE_ROWS)
	testing.expect(t, choice_move(panel, .Page_After))
	testing.expect_value(t, panel.choice, last)
	testing.expect(t, !choice_move(panel, .Page_After))
	testing.expect_value(t, panel.choice, last)
	testing.expect(t, panel.choice < panel.first_row + LIST_ROWS)
	testing.expect(t, choice_move(panel, .Page_Before))
	testing.expect_value(t, panel.choice, last - PAGE_ROWS)
	// A page up from near the top stops at the first entry, under its heading.
	testing.expect(t, choice_move(panel, .Page_Before))
	testing.expect_value(t, panel.choice, 1)
	testing.expect_value(t, panel.first_row, 0)
	testing.expect(t, !choice_move(panel, .Page_Before))
	// A page that lands on a heading takes the entry after it.
	panel.choice = 1
	entries_collect(panel, PROGRAMS[:], {{title = "a"}, {title = "b"}, {title = "c"}, {title = "d"}, {title = "e"}, {title = "f"}, {title = "g"}, {title = "h"}, {title = "i"}, {title = "j"}, {title = "k"}})
	testing.expect_value(t, panel.rows[1 + PAGE_ROWS].kind, Row_Kind.Heading_Programs)
	testing.expect(t, choice_move(panel, .Page_After))
	testing.expect_value(t, panel.choice, 2 + PAGE_ROWS)
}

// The typed part: the keys of the line edit it, the list follows, and a
// character past its room is refused.
@(test)
the_typed_part :: proc(t: ^testing.T) {
	panel := new(Panel)
	defer free(panel)
	panel_of_test(panel)
	drawn, text_changed := typed_edit(panel, .Character, 'p')
	testing.expect(t, drawn && text_changed)
	drawn, text_changed = typed_edit(panel, .Left, 0)
	testing.expect(t, drawn && !text_changed)
	drawn, text_changed = typed_edit(panel, .Left, 0)
	testing.expect(t, !drawn && !text_changed, "the caret is at the start")
	typed_edit(panel, .Character, 's')
	testing.expect_value(t, typed_text(panel), "sp")
	typed_edit(panel, .End, 0)
	drawn, text_changed = typed_edit(panel, .Backspace, 0)
	testing.expect(t, drawn && text_changed)
	testing.expect_value(t, typed_text(panel), "s")
	drawn, _ = typed_edit(panel, .Other, 0)
	testing.expect(t, !drawn)
	drawn, _ = typed_edit(panel, .Character, 7)
	testing.expect(t, !drawn, "a byte that the font does not draw")
	line_editor.line_clear(&panel.line)
	for _ in 0 ..< TYPED_CAPACITY + 8 {
		typed_edit(panel, .Character, 'a')
	}
	testing.expect_value(t, len(typed_text(panel)), TYPED_CAPACITY)
	// The close empties the typed part and makes the list of the next open.
	panel.state = .Search
	panel_close(panel)
	testing.expect_value(t, panel.state, State.Closed)
	testing.expect_value(t, typed_text(panel), "")
	testing.expect_value(t, row_text(panel, 0), "[windows]")
}

// The remembered choices: the newest first, a choice made again moves to
// the front, the oldest one leaves a full table, an entry that destroys is
// not remembered.
@(test)
the_remembered_choices :: proc(t: ^testing.T) {
	panel := new(Panel)
	defer free(panel)
	names: [RECENT_CAPACITY + 4]string
	letters := "abcdefghijklmnopqrstuvwxyz"
	for &name, index in names {
		name = letters[index:index + 1]
	}
	entries_collect(panel, names[:], {{title = "w"}})
	for index in 0 ..< len(names) {
		recent_note(panel, &panel.entries[1 + index])
	}
	testing.expect_value(t, panel.recent_count, RECENT_CAPACITY)
	testing.expect_value(t, recent_age(panel, .Program, names[len(names) - 1]), 1)
	testing.expect_value(t, recent_age(panel, .Program, names[0]), 0)
	testing.expect_value(t, recent_age(panel, .Program, names[4]), RECENT_CAPACITY)
	// The oldest one, chosen again, is the newest; each other is one older.
	recent_note(panel, &panel.entries[1 + 4])
	testing.expect_value(t, recent_age(panel, .Program, names[4]), 1)
	testing.expect_value(t, recent_age(panel, .Program, names[len(names) - 1]), 2)
	testing.expect_value(t, panel.recent_count, RECENT_CAPACITY)
	// A kind is a part of the choice: the window w is not the program w.
	testing.expect_value(t, recent_age(panel, .Window, names[4]), 0)
	recent_note(panel, &panel.entries[panel.entry_count - 1]) // close w
	testing.expect_value(t, recent_age(panel, .Close_Window, "close w"), 0)
	testing.expect_value(t, recent_age(panel, .Program, names[4]), 1)
}

// A panel that asks for a second Enter goes back to the search when its
// entries change: the entry that it showed can be gone.
@(test)
new_entries_end_the_question :: proc(t: ^testing.T) {
	panel := new(Panel)
	defer free(panel)
	panel_of_test(panel)
	panel.state = .Confirm
	entries_collect(panel, PROGRAMS[:], nil)
	testing.expect_value(t, panel.state, State.Search)
	panel.state = .Closed
	entries_collect(panel, PROGRAMS[:], nil)
	testing.expect_value(t, panel.state, State.Closed)
}

// The parts of the panel under the pointer, and the row at a point.
@(test)
the_parts_under_the_pointer :: proc(t: ^testing.T) {
	panel := new(Panel)
	defer free(panel)
	panel_of_test(panel)
	x, y := panel_place(1024)
	testing.expect_value(t, x, 192)
	testing.expect_value(t, y, 96)
	narrow_x, _ := panel_place(320)
	testing.expect_value(t, narrow_x, 0)
	testing.expect_value(t, part_at(x, y, x - 1, y), Part.Outside)
	testing.expect_value(t, part_at(x, y, x, y - 1), Part.Outside)
	testing.expect_value(t, part_at(x, y, x + PANEL_WIDTH, y), Part.Outside)
	testing.expect_value(t, part_at(x, y, x, y + PANEL_HEIGHT), Part.Outside)
	testing.expect_value(t, part_at(x, y, x, y), Part.Input_Band)
	testing.expect_value(t, part_at(x, y, x + PANEL_WIDTH - 1, y + INPUT_BAND_HEIGHT - 1), Part.Input_Band)
	testing.expect_value(t, part_at(x, y, x + 8, y + INPUT_BAND_HEIGHT), Part.List)
	testing.expect_value(t, part_at(x, y, x + 8, y + DETAIL_TOP), Part.Rest)
	testing.expect_value(t, part_at(x, y, x + 8, y + PANEL_HEIGHT - 1), Part.Rest)
	testing.expect_value(t, row_at(panel, x, y, x + 8, y + LIST_TOP), 0)
	testing.expect_value(t, row_at(panel, x, y, x + 8, y + LIST_TOP + ROW_HEIGHT), 1)
	testing.expect_value(t, row_at(panel, x, y, x + 8, y + LIST_TOP + LIST_HEIGHT - 1), LIST_ROWS - 1)
	testing.expect_value(t, row_at(panel, x, y, x, y + LIST_TOP), NO_ROW) // The border.
	testing.expect_value(t, row_at(panel, x, y, x + 8, y + 8), NO_ROW) // The input band.
	// The pointer chooses an entry, and never a heading.
	testing.expect(t, !choice_set(panel, 0))
	testing.expect(t, !choice_set(panel, 1), "the row is the choice already")
	testing.expect(t, choice_set(panel, 2))
	testing.expect(t, !choice_set(panel, NO_ROW))
	testing.expect_value(t, panel.choice, 2)
	// Under the last row of a short list: no row.
	type_text(panel, "pla")
	testing.expect_value(t, row_at(panel, x, y, x + 8, y + LIST_TOP + 3 * ROW_HEIGHT), NO_ROW)
}

@(private = "file")
SCREEN_WIDTH :: 1024
@(private = "file")
SCREEN_HEIGHT :: 768
@(private = "file")
OUTSIDE_COLOR :: 0x123456 // A color that no record of the panel draws.

@(private = "file")
Screen :: struct {
	records: [256]interface.Draw_Record,
	text:    [4096]u8,
	table:   interface.Draw_Table,
	pixels:  []graphics.Color,
	canvas:  graphics.Canvas,
}

@(private = "file")
screen_make :: proc() -> ^Screen {
	screen := new(Screen)
	screen.table = {records = screen.records[:], text = screen.text[:]}
	screen.pixels = make([]graphics.Color, SCREEN_WIDTH * SCREEN_HEIGHT)
	screen.canvas = {pixels = raw_data(screen.pixels), width = SCREEN_WIDTH, height = SCREEN_HEIGHT, stride = SCREEN_WIDTH}
	return screen
}

@(private = "file")
screen_free :: proc(screen: ^Screen) {
	delete(screen.pixels)
	free(screen)
}

// The draw records of a panel, in the table of a screen.
@(private = "file")
panel_build :: proc(screen: ^Screen, panel: ^Panel) {
	state: interface.Interface_State
	input: interface.Input
	frame := interface.frame_begin(&screen.table, &state, &input)
	x, y := panel_place(SCREEN_WIDTH)
	panel_draw(&frame, panel, x, y)
	interface.frame_end(&frame)
}

@(private = "file")
pixel :: proc(screen: ^Screen, x, y: int) -> graphics.Color {
	return screen.pixels[y * SCREEN_WIDTH + x]
}

// The geometry of the panel, on a drawn canvas. The input band is flush
// with the top, the left and the right edge of the panel: its fill is the
// first pixel at each of the three edges, and no pixel of a border is
// there. The line of 2 pixels under it goes from edge to edge. The rest
// has a border of 1 pixel at the left, the right and the bottom, and none
// at its top. No pixel is drawn outside the panel.
@(test)
the_input_band_is_flush_with_three_edges :: proc(t: ^testing.T) {
	panel := new(Panel)
	defer free(panel)
	panel_of_test(panel)
	panel_open(panel)
	for typed in ([]string{"", "pla"}) {
		line_editor.line_clear(&panel.line)
		list_build(panel)
		type_text(panel, typed)
		screen := screen_make()
		defer screen_free(screen)
		graphics.clear(screen.canvas, OUTSIDE_COLOR)
		panel_build(screen, panel)
		testing.expect(t, !screen.table.full, "the draw table holds the panel")
		interface.execute(&screen.table, screen.canvas)
		x, y := panel_place(SCREEN_WIDTH)
		right := x + PANEL_WIDTH - 1
		line_top := y + INPUT_BAND_HEIGHT - 2
		// The top edge: each pixel of the first row is the fill of the band.
		for column in x ..= right {
			if pixel(screen, column, y) != graphics.COLOR_TRACK {
				testing.expectf(t, false, "typed %q: the top row at x %d is %06x, not the fill of the band", typed, column, u32(pixel(screen, column, y)))
				break
			}
		}
		// The left and the right edge of the band: the fill, on each row.
		for row in y ..< line_top {
			if pixel(screen, x, row) != graphics.COLOR_TRACK || pixel(screen, right, row) != graphics.COLOR_TRACK {
				testing.expectf(t, false, "typed %q: an edge of the band at y %d is %06x and %06x, not its fill", typed, row, u32(pixel(screen, x, row)), u32(pixel(screen, right, row)))
				break
			}
		}
		// The line of 2 pixels, from edge to edge.
		for row in line_top ..< line_top + 2 {
			for column in x ..= right {
				if pixel(screen, column, row) != graphics.COLOR_TITLE {
					testing.expectf(t, false, "typed %q: the line under the band at %d,%d is %06x", typed, column, row, u32(pixel(screen, column, row)))
					break
				}
			}
		}
		// Under the band: a border at the left, the right and the bottom;
		// the pixel inside it is the surface of a card, also on the first
		// row: the rest has no border at its top.
		body_top := y + INPUT_BAND_HEIGHT
		bottom := y + PANEL_HEIGHT - 1
		// With no typed part the first row is a heading, on the surface of
		// the card; with a typed part it is the chosen row.
		inside_color := graphics.Color(typed == "" ? graphics.COLOR_CARD_TOP : graphics.COLOR_CHOSEN)
		testing.expect_value(t, pixel(screen, x + BORDER, body_top), inside_color)
		testing.expect_value(t, pixel(screen, right - BORDER, body_top), inside_color)
		for row in body_top ..= bottom {
			left_pixel, right_pixel := pixel(screen, x, row), pixel(screen, right, row)
			border := interface_border_color(row - body_top, PANEL_HEIGHT - INPUT_BAND_HEIGHT)
			if left_pixel != border || right_pixel != border {
				testing.expectf(t, false, "typed %q: the border at y %d is %06x and %06x, not %06x", typed, row, u32(left_pixel), u32(right_pixel), u32(border))
				break
			}
		}
		for column in x ..= right {
			if pixel(screen, column, bottom) != pixel(screen, x, bottom) {
				testing.expectf(t, false, "typed %q: the bottom border at x %d is %06x", typed, column, u32(pixel(screen, column, bottom)))
				break
			}
		}
		testing.expect(t, pixel(screen, x + 8, bottom - 1) != pixel(screen, x, bottom), "the row over the bottom border is the surface of the card")
		// Nothing around the panel: the pixels beside each edge keep their color.
		for column in x - 1 ..= right + 1 {
			testing.expect_value(t, pixel(screen, column, y - 1), graphics.Color(OUTSIDE_COLOR))
			testing.expect_value(t, pixel(screen, column, bottom + 1), graphics.Color(OUTSIDE_COLOR))
		}
		for row in y ..= bottom {
			testing.expect_value(t, pixel(screen, x - 1, row), graphics.Color(OUTSIDE_COLOR))
			testing.expect_value(t, pixel(screen, right + 1, row), graphics.Color(OUTSIDE_COLOR))
		}
	}
}

// The color of the border of the panel on one row: the gradient of a
// border of a card, as the execution of a vertical gradient computes it.
// The test draws the same record alone and reads its pixel, so it holds no
// arithmetic of its own.
@(private = "file")
interface_border_color :: proc(row, height: int) -> graphics.Color {
	records: [1]interface.Draw_Record
	table := interface.Draw_Table{records = records[:]}
	interface.draw_vertical_gradient(&table, 0, 0, 1, height, graphics.shade(graphics.COLOR_KERNEL, 28), graphics.shade(graphics.COLOR_KERNEL, 14))
	pixels := make([]graphics.Color, height, context.temp_allocator)
	interface.execute(&table, {pixels = raw_data(pixels), width = 1, height = height, stride = 1})
	return pixels[row]
}

// The typed part is at scale 2: the caret is 4 pixels wide and 32 high, in
// the blue of the title bar, 16 pixels from the left edge when the part is
// empty, and one cell of 16 pixels farther for each character.
@(test)
the_caret_follows_the_typed_part :: proc(t: ^testing.T) {
	panel := new(Panel)
	defer free(panel)
	panel_of_test(panel)
	panel_open(panel)
	x, y := panel_place(SCREEN_WIDTH)
	for typed, count in ([]string{"", "p", "pl"}) {
		line_editor.line_clear(&panel.line)
		type_text(panel, typed)
		screen := screen_make()
		defer screen_free(screen)
		panel_build(screen, panel)
		caret_x := x + interface.TEXT_INPUT_LINE_MARGIN + count * graphics.CELL_WIDTH * INPUT_SCALE
		found := false
		for record in screen.table.records[:screen.table.record_count] {
			if record.kind == .Rectangle && record.first_color == graphics.COLOR_TITLE && int(record.width) == 2 * INPUT_SCALE {
				found = true
				testing.expect_value(t, int(record.x), caret_x)
				testing.expect_value(t, int(record.y), y + (INPUT_BAND_HEIGHT - graphics.CELL_HEIGHT * INPUT_SCALE) / 2)
				testing.expect_value(t, int(record.height), graphics.CELL_HEIGHT * INPUT_SCALE)
			}
		}
		testing.expectf(t, found, "typed %q: the panel has a caret", typed)
	}
}

// What the rows say: the chosen row is filled with the chosen blue and
// has the hint of its kind; the row that asks for a second Enter is in the
// color of "stop a program" and says the act in full.
@(test)
the_chosen_row_and_the_question :: proc(t: ^testing.T) {
	panel := new(Panel)
	defer free(panel)
	panel_of_test(panel)
	panel_open(panel)
	type_text(panel, "closepla")
	screen := screen_make()
	defer screen_free(screen)
	x, y := panel_place(SCREEN_WIDTH)
	has_text :: proc(table: ^interface.Draw_Table, text: string) -> bool {
		for record in table.records[:table.record_count] {
			if interface.is_text_kind(record.kind) && string(table.text[record.text_start:][:record.text_count]) == text {
				return true
			}
		}
		return false
	}
	row_fill :: proc(table: ^interface.Draw_Table, panel_x, panel_y: int) -> (color: graphics.Color, found: bool) {
		for record in table.records[:table.record_count] {
			if record.kind == .Rectangle && int(record.x) == panel_x + BORDER && int(record.y) == panel_y + LIST_TOP && int(record.height) == ROW_HEIGHT {
				return graphics.Color(record.first_color), true
			}
		}
		return 0, false
	}
	panel_build(screen, panel)
	color, found := row_fill(&screen.table, x, y)
	testing.expect(t, found)
	testing.expect_value(t, color, graphics.Color(graphics.COLOR_CHOSEN))
	testing.expect(t, has_text(&screen.table, "close plasma"))
	testing.expect(t, has_text(&screen.table, "enter: close"))
	testing.expect(t, has_text(&screen.table, "the client table"))
	testing.expect(t, has_text(&screen.table, "1 of 14"))
	testing.expect(t, has_text(&screen.table, KEYS_OF_SEARCH))
	panel.state = state_after(panel.state, key_action(panel.state, .Enter), chosen_of(panel))
	testing.expect_value(t, panel.state, State.Confirm)
	panel_build(screen, panel)
	color, found = row_fill(&screen.table, x, y)
	testing.expect(t, found)
	testing.expect_value(t, color, graphics.Color(graphics.COLOR_STOP_PROGRAM))
	testing.expect(t, has_text(&screen.table, "stop plasma: its window closes"))
	testing.expect(t, has_text(&screen.table, HINT_OF_CONFIRM))
	testing.expect(t, has_text(&screen.table, KEYS_OF_CONFIRM))
	testing.expect(t, !has_text(&screen.table, "close plasma"))
	// No entry: one line says which part no name has.
	panel.state = .Search
	line_editor.line_clear(&panel.line)
	type_text(panel, "xyz")
	panel_build(screen, panel)
	testing.expect(t, has_text(&screen.table, "nothing has \"xyz\" in its name"))
	testing.expect(t, has_text(&screen.table, "0 of 14"))
	// The first open: the placeholder, and the headings of the groups.
	line_editor.line_clear(&panel.line)
	list_build(panel)
	panel_build(screen, panel)
	testing.expect(t, has_text(&screen.table, PLACEHOLDER))
	testing.expect(t, has_text(&screen.table, HEADING_WINDOWS))
	testing.expect(t, has_text(&screen.table, HEADING_PROGRAMS))
	testing.expect(t, has_text(&screen.table, "enter: to the front"))
}

// A panel drawn in the damage of its difference with the panel before is
// the panel drawn whole, pixel for pixel: each key damages what it changes
// and nothing is left of the frame before.
@(test)
the_damage_of_a_key_is_never_too_small :: proc(t: ^testing.T) {
	panel := new(Panel)
	defer free(panel)
	panel_of_test(panel)
	panel_open(panel)
	before, now := screen_make(), screen_make()
	defer screen_free(before)
	defer screen_free(now)
	whole := make([]graphics.Color, SCREEN_WIDTH * SCREEN_HEIGHT)
	defer delete(whole)
	graphics.clear(before.canvas, OUTSIDE_COLOR)
	panel_build(before, panel)
	interface.execute(&before.table, before.canvas)
	Step :: struct {
		key:       Key,
		character: u8,
	}
	steps := [?]Step{{.Down, 0}, {.Character, 'p'}, {.Character, 'l'}, {.Down, 0}, {.Backspace, 0}, {.Page_Down, 0}, {.Character, 'x'}, {.Character, 'y'}, {.Backspace, 0}, {.Backspace, 0}, {.Backspace, 0}, {.Up, 0}}
	for step, number in steps {
		#partial switch key_action(panel.state, step.key) {
		case .Edit:
			typed_edit(panel, step.key, step.character)
		case .Choose_Next:
			choice_move(panel, .Next)
		case .Choose_Previous:
			choice_move(panel, .Previous)
		case .Choose_Page_After:
			choice_move(panel, .Page_After)
		}
		panel_build(now, panel)
		damage: interface.Damage
		interface.damage_by_difference(&before.table, &now.table, &damage)
		// The frame before, then the new records in the damage only.
		interface.execute_in_rectangles(&now.table, before.canvas, damage.rectangles[:damage.count])
		whole_canvas := graphics.Canvas{pixels = raw_data(whole), width = SCREEN_WIDTH, height = SCREEN_HEIGHT, stride = SCREEN_WIDTH}
		graphics.clear(whole_canvas, OUTSIDE_COLOR)
		interface.execute(&now.table, whole_canvas)
		testing.expectf(t, string(transmute([]u8)before.pixels) == string(transmute([]u8)whole), "step %d (%v): the panel in its damage differs from the whole panel", number, step.key)
		testing.expect(t, interface.draw_table_copy(&before.table, &now.table))
	}
}
