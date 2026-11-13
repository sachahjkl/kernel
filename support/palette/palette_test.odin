#+build !freestanding
package palette

import "core:strings"
import "core:testing"
import "contract:palette_table"
import "support:graphics"
import "support:interface"
import "support:line_editor"

@(private = "file")
PROGRAMS := [?]string{"boot", "pages", "log", "console", "monitor", "plasma", "life", "paint", "temple", "clock"}

// A panel and its list, in one allocation: the panel is its first field.
@(private = "file")
Panel_Memory :: struct {
	panel: Panel,
	list:  List,
}

@(private = "file")
panel_make :: proc() -> ^Panel {
	memory := new(Panel_Memory)
	memory.panel.list = &memory.list
	memory.panel.pressed_row = NO_ROW
	return &memory.panel
}

@(private = "file")
panel_free :: proc(panel: ^Panel) {
	free((^Panel_Memory)(panel))
}

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
		if _, text_changed := typed_edit(panel, .Character, text[index]); text_changed {
			list_build(panel)
		}
	}
}

// The row of the list as "name (kind)", or the heading in brackets.
@(private = "file")
row_text :: proc(panel: ^Panel, row: int) -> string {
	item := panel.list.rows[row]
	switch item.kind {
	case .Heading_Recent:
		return "[recent]"
	case .Heading_Windows:
		return "[windows]"
	case .Heading_Programs:
		return "[programs]"
	case .Entry:
		entry := &panel.list.entries[item.entry]
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
		.Shift_Tab = .None,
		.Control_Enter = .Open_In_Console,
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
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	testing.expect_value(t, panel.list.entry_count, 2 + len(PROGRAMS) + 2)
	testing.expect_value(t, entry_name(&panel.list.entries[0]), "console")
	testing.expect_value(t, panel.list.entries[0].kind, Entry_Kind.Window)
	testing.expect_value(t, panel.list.entries[0].mark, Entry_Mark.Has_Focus)
	testing.expect_value(t, panel.list.entries[0].number, 3)
	testing.expect_value(t, panel.list.entries[1].mark, Entry_Mark.Window)
	for &entry in panel.list.entries[:panel.list.entry_count] {
		if entry.kind != .Program {
			continue
		}
		has_window := entry_name(&entry) == "console" || entry_name(&entry) == "plasma"
		testing.expect_value(t, entry.mark, has_window ? Entry_Mark.Has_Window : Entry_Mark.No_Window)
	}
	last := &panel.list.entries[panel.list.entry_count - 1]
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
	panel := panel_make()
	defer panel_free(panel)
	long: [NAME_CAPACITY + 1]u8
	for &character in long {
		character = 'a'
	}
	names := [?]string{"clock", string(long[:]), "", string(long[:NAME_CAPACITY])}
	entries_collect(panel, names[:], nil)
	testing.expect_value(t, panel.list.entry_count, 2)
	testing.expect_value(t, entry_name(&panel.list.entries[1]), string(long[:NAME_CAPACITY]))
	testing.expect_value(t, panel.list.entries[1].number, 3)
}

// One ranked list over the two kinds: with equal scores a window comes
// before the program of the same name, and the close comes last.
@(test)
one_ranked_list_over_the_kinds :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	type_text(panel, "pla")
	testing.expect_value(t, panel.list.row_count, 3)
	testing.expect_value(t, panel.list.matched_count, 3)
	testing.expect_value(t, row_text(panel, 0), "plasma (window)")
	testing.expect_value(t, row_text(panel, 1), "plasma (program)")
	testing.expect_value(t, row_text(panel, 2), "close plasma (close a window)")
	testing.expect_value(t, panel.choice, 0)
	// The matched characters of each name: the places that the row marks.
	testing.expect_value(t, panel.list.rows[0].places, line_editor.Match_Places{0, 1, 2})
	testing.expect_value(t, panel.list.rows[2].places, line_editor.Match_Places{6, 7, 8})
	// The match is fuzzy: the characters in their order, not side by side.
	line_editor.line_clear(&panel.line)
	type_text(panel, "closepla")
	testing.expect_value(t, panel.list.row_count, 1)
	testing.expect_value(t, row_text(panel, 0), "close plasma (close a window)")
	testing.expect_value(t, chosen_of(panel), Chosen.Destroys)
	// No entry has the part: no row, no choice.
	line_editor.line_clear(&panel.line)
	type_text(panel, "xyz")
	testing.expect_value(t, panel.list.row_count, 0)
	testing.expect_value(t, panel.choice, NO_ROW)
	testing.expect_value(t, chosen_of(panel), Chosen.Nothing)
	testing.expect(t, chosen_entry(panel) == nil)
}

// A recent choice comes first among equal scores only: a better match
// always comes before it.
@(test)
a_recent_choice_wins_a_tie_only :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	for &entry in panel.list.entries[:panel.list.entry_count] {
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
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	testing.expect_value(t, panel.list.row_count, 1 + 2 + 1 + len(PROGRAMS))
	testing.expect_value(t, row_text(panel, 0), "[windows]")
	testing.expect_value(t, row_text(panel, 1), "console (window)")
	testing.expect_value(t, row_text(panel, 2), "plasma (window)")
	testing.expect_value(t, row_text(panel, 3), "[programs]")
	testing.expect_value(t, row_text(panel, 4), "boot (program)")
	testing.expect_value(t, panel.choice, 1)
	testing.expect_value(t, panel.list.matched_count, 2 + len(PROGRAMS))
	for row in panel.list.rows[:panel.list.row_count] {
		testing.expect(t, row.kind != .Entry || panel.list.entries[row.entry].kind != .Close_Window)
	}
	// After a choice: the group "recent" is first, the newest choice first.
	recent_note(panel, &panel.list.entries[2 + 5]) // plasma, the program.
	recent_note(panel, &panel.list.entries[1]) // plasma, the window.
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
	panel := panel_make()
	defer panel_free(panel)
	entries_collect(panel, PROGRAMS[:], nil)
	testing.expect_value(t, row_text(panel, 0), "[programs]")
	testing.expect_value(t, panel.choice, 1)
	entries_collect(panel, nil, nil)
	testing.expect_value(t, panel.list.row_count, 0)
	testing.expect_value(t, panel.choice, NO_ROW)
	testing.expect(t, !choice_move(panel, .Next))
}

// The choice goes from the last entry to the first and back, and never
// stops on a heading. The rows shown always hold it.
@(test)
the_choice_wraps_and_skips_headings :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	last := panel.list.row_count - 1
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
	for _ in 0 ..< panel.list.row_count {
		choice_move(panel, .Next)
		testing.expect(t, row_is_entry(panel, panel.choice))
		testing.expect(t, panel.choice >= panel.first_row && panel.choice < panel.first_row + LIST_ROWS)
	}
}

// A page moves the choice by 11 rows and does not wrap.
@(test)
a_page_does_not_wrap :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	last := panel.list.row_count - 1 // 13: the list has 14 rows.
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
	testing.expect_value(t, panel.list.rows[1 + PAGE_ROWS].kind, Row_Kind.Heading_Programs)
	testing.expect(t, choice_move(panel, .Page_After))
	testing.expect_value(t, panel.choice, 2 + PAGE_ROWS)
}

// The typed part: the keys of the line edit it, the list follows, and a
// character past its room is refused.
@(test)
the_typed_part :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
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
	list_build(panel)
	testing.expect_value(t, panel.state, State.Closed)
	testing.expect_value(t, typed_text(panel), "")
	testing.expect_value(t, row_text(panel, 0), "[windows]")
}

// The remembered choices: the newest first, a choice made again moves to
// the front, the oldest one leaves a full table, an entry that destroys is
// not remembered.
@(test)
the_remembered_choices :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	names: [RECENT_CAPACITY + 4]string
	letters := "abcdefghijklmnopqrstuvwxyz"
	for &name, index in names {
		name = letters[index:index + 1]
	}
	entries_collect(panel, names[:], {{title = "w"}})
	for index in 0 ..< len(names) {
		recent_note(panel, &panel.list.entries[1 + index])
	}
	testing.expect_value(t, panel.recent_count, RECENT_CAPACITY)
	testing.expect_value(t, recent_age(panel, .Program, names[len(names) - 1]), 1)
	testing.expect_value(t, recent_age(panel, .Program, names[0]), 0)
	testing.expect_value(t, recent_age(panel, .Program, names[4]), RECENT_CAPACITY)
	// The oldest one, chosen again, is the newest; each other is one older.
	recent_note(panel, &panel.list.entries[1 + 4])
	testing.expect_value(t, recent_age(panel, .Program, names[4]), 1)
	testing.expect_value(t, recent_age(panel, .Program, names[len(names) - 1]), 2)
	testing.expect_value(t, panel.recent_count, RECENT_CAPACITY)
	// A kind is a part of the choice: the window w is not the program w.
	testing.expect_value(t, recent_age(panel, .Window, names[4]), 0)
	recent_note(panel, &panel.list.entries[panel.list.entry_count - 1]) // close w
	testing.expect_value(t, recent_age(panel, .Close_Window, "close w"), 0)
	testing.expect_value(t, recent_age(panel, .Program, names[4]), 1)
}

// A panel that asks for a second Enter goes back to the search when its
// entries change: the entry that it showed can be gone.
@(test)
new_entries_end_the_question :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
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
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	panel_open(panel) // The pointer finds a row of an open panel only.
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
	panel := panel_make()
	defer panel_free(panel)
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
		// the card; with a typed part it is the chosen row. A list with
		// more rows than the panel shows has its bar of 2 pixels between
		// the rows and the right border: the row ends before the bar.
		inside_color := graphics.Color(typed == "" ? graphics.COLOR_CARD_TOP : graphics.COLOR_CHOSEN)
		bar_width := panel.list.row_count > LIST_ROWS ? interface.LIST_ROW_SCROLL_WIDTH : 0
		testing.expect_value(t, bar_width, typed == "" ? interface.LIST_ROW_SCROLL_WIDTH : 0)
		testing.expect_value(t, pixel(screen, x + BORDER, body_top), inside_color)
		testing.expect_value(t, pixel(screen, right - BORDER - bar_width, body_top), inside_color)
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
	panel := panel_make()
	defer panel_free(panel)
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
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	panel_open(panel)
	type_text(panel, "closepla")
	screen := screen_make()
	defer screen_free(screen)
	x, y := panel_place(SCREEN_WIDTH)
	has_text :: proc(table: ^interface.Draw_Table, text: string) -> bool {
		for record in table.records[:table.record_count] {
			if interface.is_text_kind(record.kind) && strings.contains(string(table.text[record.text_start:][:record.text_count]), text) {
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
	// The chosen row keeps its kind; the footer says what Enter does, and
	// counts the entries in a plain word.
	testing.expect(t, has_text(&screen.table, "close a window"))
	testing.expect(t, has_text(&screen.table, "enter: close   esc: close"))
	testing.expect(t, has_text(&screen.table, "1 of 14"))
	testing.expect(t, has_text(&screen.table, "entries"))
	testing.expect(t, has_text(&screen.table, NOTE_NO_PROVIDER))
	testing.expect(t, has_text(&screen.table, "Stops the program plasma: its window closes. Asks for a second Enter."))
	panel.state = state_after(panel.state, key_action(panel.state, .Enter), chosen_of(panel))
	testing.expect_value(t, panel.state, State.Confirm)
	panel_build(screen, panel)
	color, found = row_fill(&screen.table, x, y)
	testing.expect(t, found)
	testing.expect_value(t, color, graphics.Color(graphics.COLOR_STOP_PROGRAM))
	testing.expect(t, has_text(&screen.table, "stop plasma: its window closes"))
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
	testing.expect(t, has_text(&screen.table, "The window of the program console. It has the focus."))
}

// A panel drawn in the damage of its difference with the panel before is
// the panel drawn whole, pixel for pixel: each key damages what it changes
// and nothing is left of the frame before.
@(test)
the_damage_of_a_key_is_never_too_small :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
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
			list_build(panel)
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

// A table of a provider, as the console writes it: the memory of the test.
@(private = "file")
Given :: struct {
	name:       string,
	signature:  string,
	about:      string,
	parameters: u8,
	result:     palette_table.Value_Kind,
	destroys:   bool,
	kinds:      [2]palette_table.Value_Kind,
	names:      [2]string,
	setting:    bool,
	value:      u8,
}

@(private = "file")
GIVEN := [?]Given {
	{name = "memory", signature = "memory() -> Record", about = "memory and kernel counters", result = .Record},
	{name = "programs", signature = "programs() -> Table", about = "the programs that run", result = .Table},
	{name = "stop", signature = "stop(Text)", about = "stop a program, by name", parameters = 1, destroys = true},
	{name = "shutdown", signature = "shutdown()", about = "stop the machine", destroys = true},
}

@(private = "file")
table_make :: proc(given: []Given) -> []u8 {
	memory := make([]u8, palette_table.TABLE_BYTES)
	header := (^palette_table.Header)(raw_data(memory))
	header^ = {magic = palette_table.MAGIC, version = palette_table.VERSION, change_count = 6, entry_count = u32(len(given))}
	for item, index in given {
		entry := (^palette_table.Entry)(&memory[palette_table.ENTRIES_OFFSET + index * size_of(palette_table.Entry)])
		entry.kind = .Command
		if item.destroys {
			entry.flags = {.Destroys}
		}
		entry.parameter_count = item.parameters
		entry.result = item.result
		entry.name_length = u8(copy(entry.name[:], item.name))
		entry.signature_length = u8(copy(entry.signature[:], item.signature))
		entry.about_length = u8(copy(entry.about[:], item.about))
		for kind, number in item.kinds {
			entry.parameters[number] = kind
			entry.parameter_name_lengths[number] = u8(copy(entry.parameter_names[number][:], item.names[number]))
		}
		if item.setting {
			entry.kind = .Setting
			entry.setting_value = item.value
		}
	}
	return memory
}

@(private = "file")
collect_with_table :: proc(panel: ^Panel, table: []u8) -> palette_table.Problem {
	problem, _ := list_collect(panel.list, nil, PROGRAMS[:], {{title = "console", number = 3, focus = true}}, table)
	list_build(panel)
	return problem
}

// The entries of a provider join the one ranked list: a command is found
// by its letters, says its kind, and what Enter does on it follows from
// its parameters and from what it destroys.
@(test)
the_entries_of_a_provider :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	table := table_make(GIVEN[:])
	defer delete(table)
	testing.expect_value(t, collect_with_table(panel, table), palette_table.Problem.None)
	testing.expect_value(t, panel.list.provider, Provider_State.Ready)
	testing.expect_value(t, panel.list.snapshot.generation, 6)
	testing.expect_value(t, panel.list.entry_count, 1 + len(PROGRAMS) + 1 + len(GIVEN))
	// With no typed part the commands do not show.
	for row in panel.list.rows[:panel.list.row_count] {
		testing.expect(t, row.kind != .Entry || !entry_of_provider(&panel.list.entries[row.entry]))
	}
	type_text(panel, "mem")
	testing.expect_value(t, row_text(panel, 0), "memory (command)")
	testing.expect_value(t, chosen_of(panel), Chosen.Sends)
	testing.expect_value(t, state_after(.Search, .Run, chosen_of(panel)), State.Running)
	line_editor.line_clear(&panel.line)
	type_text(panel, "stop")
	testing.expect_value(t, row_text(panel, 0), "stop (command)")
	testing.expect_value(t, entry_words(chosen_entry(panel)), "command, needs arguments")
	// A command with parameters opens in the console: the panel closes at
	// once, and asks nothing, also when the command destroys.
	testing.expect_value(t, chosen_of(panel), Chosen.Runs)
	line_editor.line_clear(&panel.line)
	type_text(panel, "shut")
	testing.expect_value(t, chosen_of(panel), Chosen.Destroys_Then_Sends)
	testing.expect_value(t, state_after(.Search, .Run, chosen_of(panel)), State.Confirm)
	testing.expect_value(t, state_after(.Confirm, .Confirm, chosen_of(panel)), State.Running)
	testing.expect_value(t, state_after(.Confirm, .Back, chosen_of(panel)), State.Search)
	// The rows as the panel draws them: the signature after the name, the
	// help sentence in the detail line, the act in full on the row that asks.
	screen := screen_make()
	defer screen_free(screen)
	has :: proc(table: ^interface.Draw_Table, text: string) -> bool {
		for record in table.records[:table.record_count] {
			if interface.is_text_kind(record.kind) && strings.contains(string(table.text[record.text_start:][:record.text_count]), text) {
				return true
			}
		}
		return false
	}
	panel.state = .Search
	panel_build(screen, panel)
	testing.expect(t, has(&screen.table, "shutdown") && has(&screen.table, "()") && has(&screen.table, "stop the machine"))
	testing.expect(t, has(&screen.table, "enter: run") && !has(&screen.table, NOTE_NO_PROVIDER))
	panel.state = .Confirm
	panel_build(screen, panel)
	testing.expect(t, has(&screen.table, "shutdown(): stop the machine"))
	panel.state = .Running
	sent_set(panel, chosen_entry(panel))
	panel_build(screen, panel)
	testing.expect(t, has(&screen.table, WORDS_OF_RUNNING) && has(&screen.table, KEYS_OF_RUNNING))
}

// A table that fails a check gives a list with the programs and the
// windows only, and its problem: each malformed table is refused.
@(test)
a_hostile_table_gives_no_entry :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	Damage :: struct {
		problem: palette_table.Problem,
		change:  proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header),
	}
	damages := [?]Damage {
		{.Bad_Magic, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {header.magic = 1}},
		{.Bad_Version, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {header.version = 99}},
		{.Too_Many_Entries, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {header.entry_count = 4096}},
		{.Never_Stable, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {header.change_count = 7}},
		{.Bad_Length, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.name_length = 0}},
		{.Bad_Length, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.name_length = 200}},
		{.Bad_Length, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.parameter_count = 200}},
		{.Bad_Length, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.about_length = 255}},
		{.Bad_Byte, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.name[1] = 7}},
		{.Bad_Byte, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.about[0] = 200}},
		{.Bad_Kind, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.kind = palette_table.Entry_Kind(9)}},
		{.Bad_Kind, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.result = palette_table.Value_Kind(40)}},
		{.Bad_Kind, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.parameters[5] = palette_table.Value_Kind(7)}},
		{.Bad_Kind, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.flags = transmute(palette_table.Entry_Flags)u8(0x80)}},
		{.Bad_Signature, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.signature[0] = 'x'}},
		{.Bad_Setting, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.setting = 1}},
		{.Bad_Setting, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.kind, entry.setting_value = .Setting, 9}},
		{.Bad_Length, proc(memory: []u8, entry: ^palette_table.Entry, header: ^palette_table.Header) {entry.parameter_name_lengths[0] = 99}},
	}
	for damage, number in damages {
		table := table_make(GIVEN[:])
		defer delete(table)
		// The second entry: the check reads each entry, not the first only.
		damage.change(table, (^palette_table.Entry)(&table[palette_table.ENTRIES_OFFSET + size_of(palette_table.Entry)]), (^palette_table.Header)(raw_data(table)))
		problem := collect_with_table(panel, table)
		testing.expectf(t, problem == damage.problem, "damage %d: %v, not %v", number, problem, damage.problem)
		testing.expect_value(t, panel.list.provider, Provider_State.Refused)
		testing.expect_value(t, panel.list.entry_count, 1 + len(PROGRAMS) + 1)
		testing.expect_value(t, panel.list.snapshot.entry_count, 0)
	}
	// A memory smaller than a table is no table.
	small := make([]u8, 4096)
	defer delete(small)
	testing.expect_value(t, collect_with_table(panel, small), palette_table.Problem.Too_Small)
	// The footer says what the list lacks.
	screen := screen_make()
	defer screen_free(screen)
	panel_open(panel)
	panel_build(screen, panel)
	found := false
	for record in screen.table.records[:screen.table.record_count] {
		if interface.is_text_kind(record.kind) && string(screen.table.text[record.text_start:][:record.text_count]) == NOTE_REFUSED_PROVIDER {
			found = true
		}
	}
	testing.expect(t, found)
}

// The keys of the states Running and Result, and what an answer of the
// provider does to a panel.
@(test)
running_and_result :: proc(t: ^testing.T) {
	for key in Key {
		closes := key == .Super || key == .Escape
		testing.expect_value(t, key_action(.Running, key), closes ? Action.Close : Action.None)
		testing.expect_value(t, key_action(.Result, key), closes ? Action.Close : Action.Back)
	}
	testing.expect_value(t, state_after(.Result, .Back, .Nothing), State.Search)
	testing.expect_value(t, state_after(.Running, .Close, .Sends), State.Closed)
	panel := panel_make()
	defer panel_free(panel)
	table := table_make(GIVEN[:])
	defer delete(table)
	collect_with_table(panel, table)
	type_text(panel, "mem")
	sent_set(panel, chosen_entry(panel))
	result_area := table[palette_table.RESULT_OFFSET:][:palette_table.RESULT_CAPACITY]
	write :: proc(area: []u8, lines: [][2]string) -> u64 {
		writer := palette_table.Result_Writer{buffer = area, fits = true}
		for line in lines {
			palette_table.result_run(&writer, .Label, line[0])
			palette_table.result_run(&writer, .Number, line[1])
			palette_table.result_line_end(&writer)
		}
		return u64(writer.count)
	}
	// A panel that waits for no answer takes none.
	panel.state = .Search
	result_set(panel, u64(palette_table.Outcome.Shown_In_Panel), 3, table, 0)
	testing.expect_value(t, panel.state, State.Search)
	// A Record: its lines in the panel.
	length := write(result_area, {{"memory_megabytes  ", "256"}, {"free_megabytes  ", "198"}})
	panel.state = .Running
	result_set(panel, u64(palette_table.Outcome.Shown_In_Panel), u64(palette_table.Value_Kind.Record), table, length)
	testing.expect_value(t, panel.state, State.Result)
	testing.expect_value(t, panel.result.kind, palette_table.Value_Kind.Record)
	screen := screen_make()
	defer screen_free(screen)
	panel_build(screen, panel)
	texts := [?]string{"memory()", "memory_megabytes  ", "256", "free_megabytes  ", "198", KEYS_OF_RESULT}
	for text in texts {
		found := false
		for record in screen.table.records[:screen.table.record_count] {
			if interface.is_text_kind(record.kind) && string(screen.table.text[record.text_start:][:record.text_count]) == text {
				found = true
			}
		}
		testing.expectf(t, found, "the panel shows %q", text)
	}
	// An Integer: its one number at three times the size of the font.
	length = write(result_area, {{"", "42"}})
	panel.state = .Running
	result_set(panel, u64(palette_table.Outcome.Shown_In_Panel), u64(palette_table.Value_Kind.Integer), table, length)
	panel_build(screen, panel)
	large := false
	for record in screen.table.records[:screen.table.record_count] {
		if interface.is_text_kind(record.kind) && record.text_scale == 3 && string(screen.table.text[record.text_start:][:record.text_count]) == "42" {
			large = true
		}
	}
	testing.expect(t, large)
	// The window of the provider has the result: the panel closes.
	panel.state = .Running
	result_set(panel, u64(palette_table.Outcome.Shown_In_Console), u64(palette_table.Value_Kind.Table), table, 0)
	testing.expect_value(t, panel.state, State.Closed)
	// A hostile answer: a length past the area, a run past the length, a
	// byte that the font does not draw, a part out of its range, too many
	// lines, an outcome that is none. Each one shows the sentence of the
	// panel itself, and nothing of the area.
	Hostile :: struct {
		outcome: u64,
		length:  u64,
		bytes:   []u8,
	}
	many: [2 * (palette_table.RESULT_LINE_CAPACITY + 1)]u8
	for index in 0 ..< palette_table.RESULT_LINE_CAPACITY + 1 {
		many[2 * index] = u8(palette_table.Run_Part.End_Line)
	}
	hostile := [?]Hostile {
		{1, palette_table.RESULT_CAPACITY + 1, {}},
		{1, 4, {0, 200, 'a', 'b'}},
		{1, 3, {0, 1, 7}},
		{1, 3, {99, 1, 'a'}},
		{1, 1, {0}},
		{1, 2, {255, 3}},
		{1, len(many), many[:]},
		{77, 3, {0, 1, 'a'}},
		{1, 0, {}},
	}
	for item, number in hostile {
		copy(result_area, item.bytes)
		panel.state = .Running
		result_set(panel, item.outcome, 1, table, item.length)
		testing.expectf(t, panel.state == .Result && panel.result.outcome == .Refused, "hostile answer %d is refused", number)
		testing.expect(t, palette_table.result_valid(panel.result.runs[:panel.result.count]))
	}
	// The provider left while the panel waited.
	panel.state = .Running
	result_sentence(panel, "the console stopped")
	testing.expect_value(t, panel.state, State.Result)
}

@(private = "file")
FORMS := [?]Given {
	{name = "revoke", signature = "revoke(name: Text, grant: Text) -> Integer", about = "end a grant of a program that runs", parameters = 2, result = .Integer, destroys = true, kinds = {.Text, .Text}, names = {"name", "grant"}},
	{name = "repeat", signature = "repeat(Text, Integer) -> Text", about = "a text, several times", parameters = 2, result = .Text, kinds = {.Text, .Integer}},
	{name = "where", signature = "where(Table, Text, Text) -> Table", about = "the rows of a table", parameters = 3, result = .Table, kinds = {.Table, .Text}},
	{name = "set font to vector", signature = "set font to vector", about = "setting(\"font\", \"vector\")", setting = true, value = 0},
	{name = "set font to spleen", signature = "set font to spleen", about = "setting(\"font\", \"spleen\")", setting = true, value = 1},
	{name = "start", signature = "start(Text)", about = "start a program", parameters = 1, kinds = {.Text, .None}},
}

// The form of an entry: its fields from the record of the provider, the
// order of Tab, what each kind takes, the check, and the typed values that
// go to the provider.
@(test)
the_form_of_an_entry :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	table := table_make(FORMS[:])
	defer delete(table)
	collect_with_table(panel, table)
	// A parameter that no field can give: no form, the console has it.
	type_text(panel, ">where")
	testing.expect_value(t, chosen_of(panel), Chosen.Runs)
	line_editor.line_clear(&panel.line)
	type_text(panel, "repeat")
	testing.expect_value(t, chosen_of(panel), Chosen.Opens_Form)
	testing.expect_value(t, state_after(.Search, .Run, chosen_of(panel)), State.Arguments)
	form_open(panel, chosen_entry(panel))
	form := &panel.form
	testing.expect_value(t, panel.state, State.Arguments)
	testing.expect_value(t, form.field_count, 2)
	testing.expect_value(t, chosen_of(panel), Chosen.Form_Sends)
	// A Text field takes each character but a quote.
	for character in transmute([]u8)string("ab") {
		form_field_edit(panel, .Character, character)
	}
	drawn, leave := form_field_edit(panel, .Character, '"')
	testing.expect(t, drawn && !leave)
	testing.expect_value(t, field_text(form, 0), "ab")
	testing.expect_value(t, form_message(form), "a text holds no quote")
	// Enter in a field that is not the last one goes to the next field.
	ready, moved := form_submit(panel, false)
	testing.expect(t, !ready && moved)
	testing.expect_value(t, form.current, 1)
	testing.expect_value(t, form_message(form), "")
	// An Integer field refuses a letter, and says so; it takes a sign at
	// its start only.
	form_field_edit(panel, .Character, 'x')
	testing.expect_value(t, field_text(form, 1), "")
	testing.expect_value(t, form_message(form), "an Integer takes digits, and one - at its start")
	form_field_edit(panel, .Character, '-')
	form_field_edit(panel, .Character, '3')
	form_field_edit(panel, .Character, '-')
	testing.expect_value(t, field_text(form, 1), "-3")
	// The order of Tab: from the last field to the first, and back.
	testing.expect(t, form_field_move(panel, 1))
	testing.expect_value(t, form.current, 0)
	testing.expect(t, form_field_move(panel, -1))
	testing.expect_value(t, form.current, 1)
	// The typed values: a Text as its bytes, an Integer as a number.
	ready, _ = form_submit(panel, false)
	testing.expect(t, ready)
	parameter, argument, ok := palette_table.argument_unpack(form_argument(form, 0))
	testing.expect(t, ok && parameter == 0 && argument.kind == .Text && string(argument.text[:argument.length]) == "ab")
	parameter, argument, ok = palette_table.argument_unpack(form_argument(form, 1))
	testing.expect(t, ok && parameter == 1 && argument.kind == .Integer && argument.integer == -3)
	testing.expect_value(t, state_after(.Arguments, .Submit, chosen_of(panel)), State.Running)
	// An empty field: the check moves the caret there and says why.
	form_field_move(panel, 1)
	for _ in 0 ..< 2 {
		form_field_edit(panel, .Backspace, 0)
	}
	form_field_move(panel, 1)
	ready, moved = form_submit(panel, true)
	testing.expect(t, !ready && moved)
	testing.expect_value(t, form.current, 0)
	testing.expect_value(t, form_message(form), "empty")
	// Backspace in the first field, empty: back to the search.
	_, leave = form_field_edit(panel, .Backspace, 0)
	testing.expect(t, leave)
	testing.expect_value(t, state_after(.Arguments, .Back, chosen_of(panel)), State.Search)
	// An entry that destroys asks after its arguments, and goes back to
	// its form with the fields kept.
	form_close(panel)
	panel.state = .Search
	line_editor.line_clear(&panel.line)
	type_text(panel, "revoke")
	form_open(panel, chosen_entry(panel))
	testing.expect_value(t, field_name(form, 1), "grant")
	testing.expect_value(t, chosen_of(panel), Chosen.Form_Destroys)
	testing.expect_value(t, state_after(.Arguments, .Submit_All, chosen_of(panel)), State.Confirm)
	testing.expect_value(t, state_after(.Confirm, .Back, chosen_of(panel)), State.Arguments)
	testing.expect_value(t, state_after(.Confirm, .Confirm, chosen_of(panel)), State.Running)
	// The numbers: the bounds of an Integer of 64 bits.
	Number :: struct {
		text:  string,
		value: i64,
		ok:    bool,
	}
	numbers := [?]Number{{"0", 0, true}, {"-0", 0, true}, {"9223372036854775807", max(i64), true}, {"9223372036854775808", 0, false}, {"-9223372036854775808", min(i64), true}, {"-9223372036854775809", 0, false}, {"", 0, false}, {"-", 0, false}, {"1a", 0, false}}
	for number in numbers {
		value, good := integer_of(number.text)
		testing.expectf(t, good == number.ok && (!good || value == number.value), "%q: %v %v", number.text, value, good)
	}
	// The keys of the state.
	testing.expect_value(t, key_action(.Arguments, .Tab), Action.Field_Next)
	testing.expect_value(t, key_action(.Arguments, .Shift_Tab), Action.Field_Previous)
	testing.expect_value(t, key_action(.Arguments, .Enter), Action.Submit)
	testing.expect_value(t, key_action(.Arguments, .Control_Enter), Action.Submit_All)
	testing.expect_value(t, key_action(.Arguments, .Escape), Action.Back)
	testing.expect_value(t, key_action(.Arguments, .Character), Action.Field_Edit)
	testing.expect_value(t, key_action(.Arguments, .Down), Action.Candidate_Next)
	testing.expect_value(t, key_action(.Arguments, .Super), Action.Close)
	// The band of the form, as the panel draws it: the call, and the
	// caret in the current field.
	screen := screen_make()
	defer screen_free(screen)
	for character in transmute([]u8)string("net") {
		form_field_edit(panel, .Character, character)
	}
	panel_build(screen, panel)
	texts := [?]string{"revoke", "name", "net", "grant"}
	for text in texts {
		found := false
		for record in screen.table.records[:screen.table.record_count] {
			if interface.is_text_kind(record.kind) && record.text_scale == INPUT_SCALE && strings.contains(string(screen.table.text[record.text_start:][:record.text_count]), text) {
				found = true
			}
		}
		testing.expectf(t, found, "the band of the form shows %q", text)
	}
}

// The candidates of a field: a checked copy, narrowed by the text of the
// field; Tab takes the chosen one. A hostile area gives none.
@(test)
the_candidates_of_a_field :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	table := table_make(FORMS[:])
	defer delete(table)
	collect_with_table(panel, table)
	type_text(panel, "start")
	form_open(panel, chosen_entry(panel))
	form := &panel.form
	names := [?]string{"console", "plasma", "paint", "life"}
	for name, index in names {
		candidate := (^palette_table.Candidate)(&table[palette_table.CANDIDATES_OFFSET + index * size_of(palette_table.Candidate)])
		candidate.length = u8(copy(candidate.name[:], name))
	}
	form_candidates_set(form, table, u64(len(names)), u64(palette_table.Candidate_Kind.Program))
	testing.expect_value(t, form.shown_count, 4)
	testing.expect_value(t, form.candidate_choice, 0)
	form_field_edit(panel, .Character, 'p')
	testing.expect_value(t, form.shown_count, 2)
	testing.expect_value(t, candidate_name(form, 0), "plasma")
	testing.expect(t, form_candidate_move(form, 1))
	testing.expect_value(t, candidate_name(form, form.candidate_choice), "paint")
	testing.expect(t, form_candidate_move(form, 1))
	testing.expect_value(t, form.candidate_choice, 0)
	testing.expect(t, form_candidate_take(form))
	testing.expect_value(t, field_text(form, 0), "plasma")
	testing.expect(t, !form_candidate_take(form), "the field holds the candidate")
	// A count past the area, a kind out of its range, a name with a byte
	// that the font does not draw: no candidate.
	form_candidates_set(form, table, palette_table.CANDIDATE_CAPACITY + 1, 1)
	testing.expect_value(t, form.candidate_count, 0)
	form_candidates_set(form, table, 4, 99)
	testing.expect_value(t, form.candidate_count, 0)
	table[palette_table.CANDIDATES_OFFSET + 3] = 1
	form_candidates_set(form, table, 4, 1)
	testing.expect_value(t, form.candidate_count, 0)
	testing.expect_value(t, form.candidate_choice, NO_ROW)
}

// A prefix restricts the kinds of the list; the part after it is what the
// names match. A setting says which value is in use.
@(test)
the_prefixes :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	table := table_make(FORMS[:])
	defer delete(table)
	collect_with_table(panel, table)
	kinds_of :: proc(panel: ^Panel) -> (kinds: bit_set[Entry_Kind]) {
		for row in panel.list.rows[:panel.list.row_count] {
			if row.kind == .Entry {
				kinds += {panel.list.entries[row.entry].kind}
			}
		}
		return
	}
	Case :: struct {
		typed: string,
		kinds: bit_set[Entry_Kind],
	}
	cases := [?]Case{{">", {.Command}}, {"@", {.Window, .Close_Window}}, {":", {.Setting}}, {"?", {.Program}}, {">re", {.Command}}, {"?pla", {.Program}}}
	for item in cases {
		line_editor.line_clear(&panel.line)
		type_text(panel, item.typed)
		testing.expectf(t, kinds_of(panel) == item.kinds, "%q lists %v", item.typed, kinds_of(panel))
		// A prefix alone: no heading, each row is an entry.
		for row in panel.list.rows[:panel.list.row_count] {
			testing.expect_value(t, row.kind, Row_Kind.Entry)
		}
	}
	prefix, rest := prefix_of(":font")
	testing.expect(t, prefix == .Settings && rest == "font")
	prefix, rest = prefix_of("font")
	testing.expect(t, prefix == .None && rest == "font")
	// The matched places are those of the name, not of the typed part
	// with its prefix.
	line_editor.line_clear(&panel.line)
	type_text(panel, ">rev")
	testing.expect_value(t, row_text(panel, 0), "revoke (command)")
	testing.expect_value(t, panel.list.rows[0].places, line_editor.Match_Places{0, 1, 2})
	// With the prefix of the manual, a program is sent to the provider.
	line_editor.line_clear(&panel.line)
	type_text(panel, "?pla")
	testing.expect_value(t, row_text(panel, 0), "plasma (program)")
	testing.expect_value(t, chosen_of(panel), Chosen.Sends)
	// The settings: the value in use says so.
	line_editor.line_clear(&panel.line)
	type_text(panel, ":font")
	testing.expect_value(t, panel.list.row_count, 2)
	testing.expect_value(t, chosen_of(panel), Chosen.Sends)
	panel.settings_in_use[0] = 1
	testing.expect(t, !setting_in_use(panel, &panel.list.entries[panel.list.rows[0].entry]))
	testing.expect(t, setting_in_use(panel, &panel.list.entries[panel.list.rows[1].entry]))
}

// A signature longer than its room is cut at the end of a parameter, with
// "...", and never inside one.
@(test)
a_signature_is_cut_at_a_parameter :: proc(t: ^testing.T) {
	buffer: [160]u8
	whole := "(name: Text, grant: Text, count: Integer) -> Table(Program)"
	testing.expect_value(t, signature_fit(whole, len(whole), buffer[:]), whole)
	testing.expect_value(t, signature_fit(whole, len(whole) - 1, buffer[:]), "(name: Text, grant: Text, ...)")
	testing.expect_value(t, signature_fit(whole, 30, buffer[:]), "(name: Text, grant: Text, ...)")
	testing.expect_value(t, signature_fit(whole, 29, buffer[:]), "(name: Text, ...)")
	testing.expect_value(t, signature_fit(whole, 16, buffer[:]), "(...)")
	testing.expect_value(t, signature_fit(whole, 4, buffer[:]), "")
	// A comma inside the type of the result is no end of a parameter.
	nested := "(table: Table(Reading, Read)) -> Integer"
	testing.expect_value(t, signature_fit(nested, 20, buffer[:]), "(...)")
}

// The choice is an entry, not a row. A list that comes for the same typed
// part keeps the chosen entry chosen, at the row that it has now. Only an
// entry that left the list moves the choice to the first row, and Enter
// then runs nothing before a frame showed it.
@(test)
the_choice_follows_its_entry :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	panel_of_test(panel)
	panel_open(panel)
	type_text(panel, "pla")
	// plasma (window), plasma (program), close plasma. The input goes
	// down to the program.
	testing.expect(t, choice_move(panel, .Next))
	testing.expect_value(t, row_text(panel, panel.choice), "plasma (program)")
	// The window of plasma closes behind the panel: the program is now
	// the first row, and it is still the chosen entry.
	adoption := entries_collect(panel, PROGRAMS[:], {{title = "console", number = 3, focus = true}})
	testing.expect_value(t, adoption, Adoption.Kept)
	testing.expect_value(t, panel.choice, 0)
	testing.expect_value(t, row_text(panel, panel.choice), "plasma (program)")
	testing.expect(t, !panel.choice_undrawn)
	// The same list again: nothing changes, and the owner draws nothing.
	testing.expect_value(t, entries_collect(panel, PROGRAMS[:], {{title = "console", number = 3, focus = true}}), Adoption.Same)
	testing.expect_value(t, panel.choice, 0)
	// A window appears: the chosen program goes down one row, and stays
	// chosen there. This is the fault that the rule ends: Enter must not
	// run the row that took the place of the chosen one.
	adoption = entries_collect(panel, PROGRAMS[:], {{title = "plasma", number = 7, focus = true}, {title = "console", number = 3}})
	testing.expect_value(t, adoption, Adoption.Kept)
	testing.expect_value(t, panel.choice, 1)
	testing.expect_value(t, row_text(panel, panel.choice), "plasma (program)")
	testing.expect_value(t, entry_name(chosen_entry(panel)), "plasma")
	testing.expect_value(t, chosen_entry(panel).kind, Entry_Kind.Program)
	// The chosen entry leaves the list: the first entry is chosen, and the
	// panel waits for a frame before an action that runs an entry.
	adoption = entries_collect(panel, PROGRAMS[:5], {{title = "plasma", number = 7, focus = true}})
	testing.expect_value(t, adoption, Adoption.Moved)
	testing.expect_value(t, panel.choice, 0)
	testing.expect_value(t, row_text(panel, 0), "plasma (window)")
	testing.expect(t, panel.choice_undrawn)
	for action in Action {
		runs := action == .Run || action == .Confirm || action == .Submit || action == .Submit_All || action == .Open_In_Console
		testing.expect_value(t, action_runs(action), runs)
	}
	panel_drawn(panel)
	testing.expect(t, !panel.choice_undrawn)
	// A list for a new typed part is the answer to the keys of the input:
	// its first entry is chosen, and Enter means it.
	testing.expect(t, choice_move(panel, .Next))
	type_text(panel, "s")
	testing.expect_value(t, panel.choice, 0)
	testing.expect(t, !panel.choice_undrawn)
	// The question of an entry that destroys follows its entry too: it
	// stays while the entry is in the list, at its new row, and ends when
	// the entry leaves.
	line_editor.line_clear(&panel.line)
	type_text(panel, "close")
	testing.expect_value(t, row_text(panel, panel.choice), "close plasma (close a window)")
	panel.state = .Confirm
	adoption = entries_collect(panel, PROGRAMS[:], {{title = "console", number = 3, focus = true}, {title = "plasma", number = 7}})
	testing.expect_value(t, adoption, Adoption.Kept)
	testing.expect_value(t, panel.state, State.Confirm)
	testing.expect_value(t, row_text(panel, panel.choice), "close plasma (close a window)")
	adoption = entries_collect(panel, PROGRAMS[:], {{title = "console", number = 3, focus = true}})
	testing.expect_value(t, adoption, Adoption.Moved)
	testing.expect_value(t, panel.state, State.Search)
	testing.expect_value(t, row_text(panel, panel.choice), "close console (close a window)")
	testing.expect(t, panel.choice_undrawn)
	// A closed panel has no choice to keep: its next open shows the first
	// entry.
	panel_close(panel)
	panel_drawn(panel)
	list_build(panel)
	testing.expect_value(t, panel.choice, 1)
	testing.expect(t, !panel.choice_undrawn)
}

// Tab before the candidates of a field came waits for them: it never goes
// to the next field while a candidate that it can take is on its way. The
// chosen candidate stays chosen when the text of the field narrows the
// list.
@(test)
tab_waits_for_the_candidates :: proc(t: ^testing.T) {
	panel := panel_make()
	defer panel_free(panel)
	table := table_make(FORMS[:])
	defer delete(table)
	collect_with_table(panel, table)
	type_text(panel, "revoke")
	form_open(panel, chosen_entry(panel))
	form := &panel.form
	// With no request, and no candidate: Tab goes to the next field.
	testing.expect_value(t, form_tab(form), Tab_Effect.Moves)
	// The owner asked: Tab waits, and the caret stays in its field.
	form.candidates_pending = true
	testing.expect_value(t, form_tab(form), Tab_Effect.Waits)
	testing.expect_value(t, form.current, 0)
	names := [?]string{"console", "plasma", "paint"}
	for name, index in names {
		candidate := (^palette_table.Candidate)(&table[palette_table.CANDIDATES_OFFSET + index * size_of(palette_table.Candidate)])
		candidate.length = u8(copy(candidate.name[:], name))
	}
	for character in transmute([]u8)string("pa") {
		form_field_edit(panel, .Character, character)
	}
	// The answer: the wait ends, and Tab takes the candidate that the
	// typed text chose.
	form_candidates_set(form, table, u64(len(names)), u64(palette_table.Candidate_Kind.Program))
	testing.expect(t, !form.candidates_pending)
	testing.expect_value(t, form_tab(form), Tab_Effect.Takes)
	testing.expect_value(t, candidate_name(form, form.candidate_choice), "plasma")
	// The input goes down to paint; one more letter keeps paint chosen,
	// at its new place.
	testing.expect(t, form_candidate_move(form, 1))
	testing.expect_value(t, candidate_name(form, form.candidate_choice), "paint")
	form_field_edit(panel, .Character, 'i')
	testing.expect_value(t, form.shown_count, 1)
	testing.expect_value(t, candidate_name(form, form.candidate_choice), "paint")
	testing.expect(t, form_candidate_take(form))
	testing.expect_value(t, form_tab(form), Tab_Effect.Moves)
	// A move to another field ends the wait for the field before.
	form.candidates_pending = true
	form_field_move(panel, 1)
	testing.expect(t, !form.candidates_pending)
}
