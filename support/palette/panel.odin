package palette

import "support:graphics"
import "support:interface"

// The geometry of the panel (docs/DESIGN.md, "Palette"), on the grid of 8
// pixels. From the top: the input band, the list, a gap, the detail line,
// the footer, a margin.
PANEL_WIDTH :: 640
PANEL_TOP :: 96 // The top of the panel on the screen: fixed, so the input band never moves when the list changes.
INPUT_BAND_HEIGHT :: 48 // The input band, with the line of 2 pixels that is its last 2 pixels.
INPUT_SCALE :: 2 // The typed part: cells of 16 x 32 pixels.
ROW_HEIGHT :: interface.TABLE_LINE // One row of the list.
LIST_TOP :: INPUT_BAND_HEIGHT // From the top of the panel to the list.
LIST_HEIGHT :: LIST_ROWS * ROW_HEIGHT
LIST_GAP :: 8 // Between the list and the detail line.
DETAIL_TOP :: LIST_TOP + LIST_HEIGHT + LIST_GAP // The detail line: what the chosen entry does.
DETAIL_HEIGHT :: 24
FOOTER_TOP :: DETAIL_TOP + DETAIL_HEIGHT // The footer: the source of the chosen entry, the count, the keys.
FOOTER_HEIGHT :: 24
BOTTOM_MARGIN :: 8
PANEL_HEIGHT :: FOOTER_TOP + FOOTER_HEIGHT + BOTTOM_MARGIN
BORDER :: 1 // The border of the panel under the input band: at the left, the right and the bottom.
TEXT_MARGIN :: 16 // From a side of the panel to a text.

#assert(PANEL_HEIGHT == 400)
#assert(PANEL_WIDTH % graphics.GRID == 0 && PANEL_TOP % graphics.GRID == 0 && INPUT_BAND_HEIGHT % graphics.GRID == 0)

// panel_place gives the top left corner of the panel on a screen: in the
// middle of its width, on the grid, at a fixed height in its upper third.
panel_place :: proc "contextless" (screen_width: int) -> (x, y: int) {
	return max(screen_width - PANEL_WIDTH, 0) / 2 / graphics.GRID * graphics.GRID, PANEL_TOP
}

// A part of the panel, for the pointer.
Part :: enum u8 {
	Outside    = 0, // Not in the panel: a press there closes it.
	Input_Band = 1, // The input band: the pointer has the shape of a text.
	List       = 2, // The area of the list, on a row or under the last one.
	Rest       = 3, // The detail line, the footer, the margins: a press there does nothing.
}

// part_at gives the part of the panel at a point of the screen. panel_x
// and panel_y: the corner of the panel.
part_at :: proc "contextless" (panel_x, panel_y, x, y: int) -> Part {
	if x < panel_x || x >= panel_x + PANEL_WIDTH || y < panel_y || y >= panel_y + PANEL_HEIGHT {
		return .Outside
	}
	switch {
	case y < panel_y + INPUT_BAND_HEIGHT:
		return .Input_Band
	case y < panel_y + LIST_TOP + LIST_HEIGHT:
		return .List
	}
	return .Rest
}

// row_at gives the row of the list at a point of the screen, or NO_ROW: a
// row that the panel shows now, an entry or a heading.
row_at :: proc "contextless" (panel: ^Panel, panel_x, panel_y, x, y: int) -> int {
	if part_at(panel_x, panel_y, x, y) != .List || x < panel_x + BORDER || x >= panel_x + PANEL_WIDTH - BORDER {
		return NO_ROW
	}
	row := panel.first_row + (y - panel_y - LIST_TOP) / ROW_HEIGHT
	return row < panel.row_count ? row : NO_ROW
}

// kind_words gives what a kind is, in words: the text at the right of a row.
kind_words :: proc "contextless" (kind: Entry_Kind) -> string {
	switch kind {
	case .Window:
		return "window"
	case .Program:
		return "program"
	case .Close_Window:
		return "close a window"
	}
	return ""
}

// kind_hint gives the key hint of the chosen row of a kind: what Enter does.
kind_hint :: proc "contextless" (kind: Entry_Kind) -> string {
	switch kind {
	case .Window:
		return "enter: to the front"
	case .Program:
		return "enter: start"
	case .Close_Window:
		return "enter: close"
	}
	return ""
}

// kind_source gives the name of the table that the entries of a kind come
// from: a reader can find the source of each row.
kind_source :: proc "contextless" (kind: Entry_Kind) -> string {
	switch kind {
	case .Window, .Close_Window:
		return "the client table"
	case .Program:
		return "bar.names"
	}
	return ""
}

// entry_about gives the sentence of the detail line: what the choice of
// the entry does.
entry_about :: proc "contextless" (entry: ^Entry) -> string {
	switch entry.kind {
	case .Window:
		return entry.mark == .Has_Focus ? "This window has the focus." : "Brings this window to the front and gives it the focus."
	case .Program:
		return entry.mark == .Has_Window ? "Starts this program one more time: it has a window now." : "Starts this program."
	case .Close_Window:
		return "Stops the program of this window. The panel asks for a second Enter."
	}
	return ""
}

// mark_color gives the color of the mark of an entry: the color of the
// concept that its fact names. shown is false for an entry with no mark.
mark_color :: proc "contextless" (mark: Entry_Mark) -> (color: graphics.Color, shown: bool) {
	switch mark {
	case .None:
		return 0, false
	case .Has_Window:
		return graphics.COLOR_PROGRAM, true
	case .No_Window:
		return graphics.COLOR_NOT_USABLE, true
	case .Has_Focus:
		return graphics.COLOR_TITLE, true
	case .Destroys:
		return graphics.COLOR_STOP_PROGRAM, true
	}
	return 0, false
}

HEADING_RECENT :: "recent"
HEADING_WINDOWS :: "windows"
HEADING_PROGRAMS :: "programs"
PLACEHOLDER :: "type a part of a name"
KEYS_OF_SEARCH :: "up down: choose   enter: run   esc: close"
KEYS_OF_CONFIRM :: "enter: confirm   another key: back"
HINT_OF_CONFIRM :: "enter: confirm"

// panel_draw appends the draw records of an open panel whose corner is at
// (x, y). The work is the 12 rows that the panel shows and a fixed count
// of other records: it does not grow with the entries.
//
// The input band is the top of the panel: its fill touches the top, the
// left and the right edge, and nothing is around it. The line of 2 pixels
// under it goes from edge to edge. The rest has a border of 1 pixel at the
// left, the right and the bottom.
panel_draw :: proc "contextless" (frame: ^interface.Frame, panel: ^Panel, x, y: int) {
	table := frame.table
	interface.text_input_line(frame, {x, y, PANEL_WIDTH, INPUT_BAND_HEIGHT}, typed_text(panel), panel.line.caret, INPUT_SCALE, PLACEHOLDER)

	// Under the band: the border, as the menus of the bar have it, then
	// the surface of a card. The border has no top side: the line of the
	// band is the edge there.
	body_top := y + INPUT_BAND_HEIGHT
	body_height := PANEL_HEIGHT - INPUT_BAND_HEIGHT
	interface.draw_vertical_gradient(table, x, body_top, PANEL_WIDTH, body_height, graphics.shade(graphics.COLOR_KERNEL, 28), graphics.shade(graphics.COLOR_KERNEL, 14))
	interface.draw_vertical_gradient(table, x + BORDER, body_top, PANEL_WIDTH - 2 * BORDER, body_height - BORDER, graphics.COLOR_CARD_TOP, graphics.COLOR_CARD_BOTTOM)

	// The rows that the panel shows.
	list_area := interface.Area{x + BORDER, y + LIST_TOP, PANEL_WIDTH - 2 * BORDER, LIST_HEIGHT}
	chosen := chosen_entry(panel)
	confirm_text: interface.Text_Builder
	rows: [LIST_ROWS]interface.List_Row
	first := clamp(panel.first_row, 0, max(panel.row_count - 1, 0))
	shown_count := clamp(panel.row_count - first, 0, LIST_ROWS)
	chosen_shown := NO_ROW
	for index in 0 ..< shown_count {
		row := panel.rows[first + index]
		switch row.kind {
		case .Heading_Recent:
			rows[index] = {kind = .Heading, name = HEADING_RECENT}
		case .Heading_Windows:
			rows[index] = {kind = .Heading, name = HEADING_WINDOWS}
		case .Heading_Programs:
			rows[index] = {kind = .Heading, name = HEADING_PROGRAMS}
		case .Entry:
			entry := &panel.entries[min(int(row.entry), ENTRY_CAPACITY - 1)]
			color, shown := mark_color(entry.mark)
			rows[index] = {kind = .Entry, name = entry_name(entry), matched_places = transmute(u128)row.places, mark_shown = shown, mark_color = color, right_text = kind_words(entry.kind)}
			if first + index == panel.choice {
				chosen_shown = index
				if panel.state == .Confirm {
					// The row says the act in full, and no letter is marked:
					// the text is no longer the name that the input searched.
					interface.text_put(&confirm_text, confirm_sentence_start(entry.kind))
					interface.text_put(&confirm_text, window_title_of(entry))
					interface.text_put(&confirm_text, confirm_sentence_end(entry.kind))
					rows[index].name = interface.text_of(&confirm_text)
					rows[index].matched_places = 0
				}
			}
		}
	}
	options := interface.List_Rows_Options{chosen = chosen_shown, first = first, total = panel.row_count}
	if chosen != nil {
		options.chosen_hint = kind_hint(chosen.kind)
	}
	if panel.state == .Confirm {
		options.chosen_color = graphics.COLOR_STOP_PROGRAM
		options.chosen_hint = HINT_OF_CONFIRM
	}
	interface.list_of_rows(frame, list_area, rows[:shown_count], options)
	if panel.row_count == 0 {
		// No entry has the typed part: one dim line says so.
		empty: interface.Text_Builder
		interface.text_put(&empty, "nothing has \"")
		interface.text_put(&empty, typed_text(panel))
		interface.text_put(&empty, "\" in its name")
		interface.draw_text(table, x + TEXT_MARGIN, y + LIST_TOP + 4, interface.text_fit(table, interface.FONT_INTERFACE, interface.text_of(&empty), PANEL_WIDTH - 2 * TEXT_MARGIN), graphics.COLOR_DIM, interface.FONT_INTERFACE)
	}

	// The detail line: what the chosen entry does, whole.
	text_room := PANEL_WIDTH - 2 * TEXT_MARGIN
	if chosen != nil {
		interface.draw_text(table, x + TEXT_MARGIN, y + DETAIL_TOP + 4, interface.text_fit(table, interface.FONT_INTERFACE, entry_about(chosen), text_room), graphics.COLOR_DIM, interface.FONT_INTERFACE)
	}

	// The footer: at the right the keys of the state; at the left the
	// source of the chosen entry, then the count of the entries that match
	// of all the entries. The count is a value: the font of the cells.
	keys := panel.state == .Confirm ? KEYS_OF_CONFIRM : KEYS_OF_SEARCH
	keys_width := interface.text_measured_width(table, interface.FONT_INTERFACE, keys)
	interface.draw_text_right(table, x + PANEL_WIDTH - TEXT_MARGIN, y + FOOTER_TOP + 4, keys, graphics.COLOR_DIM, interface.FONT_INTERFACE)
	count: interface.Text_Builder
	interface.text_put_number(&count, u64(panel.matched_count))
	interface.text_put(&count, " of ")
	interface.text_put_number(&count, u64(panel.entry_count))
	count_width := interface.text_measured_width(table, {}, interface.text_of(&count))
	after := x + TEXT_MARGIN
	if chosen != nil {
		source_room := text_room - keys_width - 16 - count_width - 16
		after = interface.draw_text(table, after, y + FOOTER_TOP + 4, interface.text_fit(table, interface.FONT_INTERFACE, kind_source(chosen.kind), source_room), graphics.COLOR_DIM, interface.FONT_INTERFACE) + 16
	}
	interface.draw_text(table, after, y + FOOTER_TOP + 4, interface.text_of(&count), graphics.COLOR_TEXT)
}

// window_title_of gives the title of the window of an entry: the name of a
// window entry, or the name of a close entry after its start.
window_title_of :: proc "contextless" (entry: ^Entry) -> string {
	name := entry_name(entry)
	if entry.kind == .Close_Window && len(name) >= len(CLOSE_NAME_START) {
		return name[len(CLOSE_NAME_START):]
	}
	return name
}

// The sentence of the row that asks for a second Enter says the act in
// full: "stop plasma: its window closes". Only an entry that destroys has
// one.
@(private)
confirm_sentence_start :: proc "contextless" (kind: Entry_Kind) -> string {
	return kind == .Close_Window ? "stop " : ""
}

@(private)
confirm_sentence_end :: proc "contextless" (kind: Entry_Kind) -> string {
	return kind == .Close_Window ? ": its window closes" : ""
}
