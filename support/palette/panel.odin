package palette

import "contract:palette_table"
import "contract:value_kinds"
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
	if panel.list == nil || panel.state == .Result || panel.state == .Running {
		return NO_ROW
	}
	row := panel.first_row + (y - panel_y - LIST_TOP) / ROW_HEIGHT
	return row < panel.list.row_count ? row : NO_ROW
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
	case .Command:
		return "command"
	case .Export:
		return "export"
	}
	return ""
}

// entry_words gives the text at the right of the row of an entry: its
// kind, and that the panel cannot run it when it has parameters.
entry_words :: proc "contextless" (entry: ^Entry) -> string {
	if .Needs_Arguments in entry.flags {
		return entry.kind == .Command ? "command, needs arguments" : "export, needs arguments"
	}
	return kind_words(entry.kind)
}

// entry_hint gives what Enter does on an entry: the footer says it.
entry_hint :: proc "contextless" (entry: ^Entry) -> string {
	switch entry.kind {
	case .Window:
		return "enter: to the front"
	case .Program:
		return "enter: start"
	case .Close_Window:
		return "enter: close"
	case .Command, .Export:
		return .Needs_Arguments in entry.flags ? "enter: arguments in the console" : "enter: run"
	}
	return ""
}

// given_of gives the record that the provider wrote for an entry, in the
// checked copy of its table; nil for an entry of the compositor.
given_of :: proc "contextless" (list: ^List, entry: ^Entry) -> ^palette_table.Entry {
	if !entry_of_provider(entry) || int(entry.number) >= list.snapshot.entry_count {
		return nil
	}
	return &list.snapshot.entries[entry.number]
}

// entry_about writes the sentence of the detail line: what the choice of
// the entry does, with the facts of now. An entry of a provider has the
// help sentence that the provider gave.
entry_about :: proc "contextless" (builder: ^interface.Text_Builder, list: ^List, entry: ^Entry) {
	switch entry.kind {
	case .Window:
		if entry.mark == .Has_Focus {
			interface.text_put(builder, "The window of the program ")
			interface.text_put(builder, entry_name(entry))
			interface.text_put(builder, ". It has the focus.")
		} else {
			interface.text_put(builder, "Brings the window of the program ")
			interface.text_put(builder, entry_name(entry))
			interface.text_put(builder, " to the front and gives it the focus.")
		}
	case .Program:
		interface.text_put(builder, "Starts the program ")
		interface.text_put(builder, entry_name(entry))
		if entry.windows == 0 {
			interface.text_put(builder, ". It has no window now.")
		} else {
			interface.text_put(builder, " one more time. It has ")
			interface.text_put_number(builder, u64(entry.windows))
			interface.text_put(builder, entry.windows == 1 ? " window now." : " windows now.")
		}
	case .Close_Window:
		interface.text_put(builder, "Stops the program ")
		interface.text_put(builder, window_title_of(entry))
		interface.text_put(builder, ": its window closes. Asks for a second Enter.")
	case .Command, .Export:
		if given := given_of(list, entry); given != nil {
			interface.text_put(builder, string(given.about[:given.about_length]))
		}
	}
}

// mark_color gives the color of the mark of an entry, the color of the
// concept that its fact names, and its form: a full square, or the outline
// of a square for a window, so that a reader who does not tell the colors
// apart still tells a window from a program. shown is false for an entry
// with no mark.
mark_color :: proc "contextless" (mark: Entry_Mark) -> (color: graphics.Color, outlined: bool, shown: bool) {
	switch mark {
	case .None:
		return 0, false, false
	case .Has_Window:
		return graphics.COLOR_PROGRAM, false, true
	case .No_Window:
		return graphics.COLOR_NOT_USABLE, false, true
	case .Has_Focus:
		return graphics.COLOR_TITLE, true, true
	case .Window:
		return graphics.COLOR_DIM, true, true
	case .Destroys:
		return graphics.COLOR_STOP_PROGRAM, false, true
	}
	return 0, false, false
}

// part_color gives the color of a run of a result: a value has the color
// of its value kind, as in the console, in the log and on the site.
part_color :: proc "contextless" (part: palette_table.Run_Part) -> graphics.Color {
	switch part {
	case .Plain:
		return graphics.COLOR_TEXT
	case .Label, .Note, .End_Line:
		return graphics.COLOR_DIM
	case .Failure:
		return graphics.COLOR_FAILED
	case .Number:
		return graphics.value_kind_color(value_kinds.Value_Kind.Number, false)
	case .Handle:
		return graphics.value_kind_color(value_kinds.Value_Kind.Handle, false)
	case .Type:
		return graphics.value_kind_color(value_kinds.Value_Kind.Type, false)
	case .Status:
		return graphics.value_kind_color(value_kinds.Value_Kind.Status, false)
	case .Operation:
		return graphics.value_kind_color(value_kinds.Value_Kind.Operation, false)
	}
	return graphics.COLOR_TEXT
}

HEADING_RECENT :: "recent"
HEADING_WINDOWS :: "windows"
HEADING_PROGRAMS :: "programs"
PLACEHOLDER :: "type a part of a name"
KEYS_START :: "up down: choose   "
KEYS_END :: "   esc: close"
KEYS_OF_CONFIRM :: "enter: confirm   another key: back"
KEYS_OF_RUNNING :: "esc: close; the line goes on in the console"
KEYS_OF_RESULT :: "esc: close   another key: back"
WORDS_OF_RUNNING :: "runs in the console"
NOTE_NO_PROVIDER :: "the console gives no commands"
NOTE_REFUSED_PROVIDER :: "the commands of the console were refused"
RESULT_CALL_TOP :: 8 // From the top of the list area to the line of the call of a result.
RESULT_LINES_TOP :: 40 // From the top of the list area to the first line of a result.

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
	list := panel.list
	interface.text_input_line(frame, {x, y, PANEL_WIDTH, INPUT_BAND_HEIGHT}, typed_text(panel), panel.line.caret, INPUT_SCALE, PLACEHOLDER)

	// Under the band: the border, as the menus of the bar have it, then
	// the surface of a card. The border has no top side: the line of the
	// band is the edge there.
	body_top := y + INPUT_BAND_HEIGHT
	body_height := PANEL_HEIGHT - INPUT_BAND_HEIGHT
	interface.draw_vertical_gradient(table, x, body_top, PANEL_WIDTH, body_height, graphics.shade(graphics.COLOR_KERNEL, 28), graphics.shade(graphics.COLOR_KERNEL, 14))
	interface.draw_vertical_gradient(table, x + BORDER, body_top, PANEL_WIDTH - 2 * BORDER, body_height - BORDER, graphics.COLOR_CARD_TOP, graphics.COLOR_CARD_BOTTOM)
	if list == nil {
		return
	}
	text_room := PANEL_WIDTH - 2 * TEXT_MARGIN
	chosen := chosen_entry(panel)

	if panel.state == .Result || panel.state == .Running {
		// The list makes room for the entry that the panel sent: a new
		// list can come while the provider runs it.
		result_draw(frame, panel, x, y)
	} else {
		// The rows that the panel shows.
		list_area := interface.Area{x + BORDER, y + LIST_TOP, PANEL_WIDTH - 2 * BORDER, LIST_HEIGHT}
		confirm_text: interface.Text_Builder
		rows: [LIST_ROWS]interface.List_Row
		first := clamp(panel.first_row, 0, max(list.row_count - 1, 0))
		shown_count := clamp(list.row_count - first, 0, LIST_ROWS)
		chosen_shown := NO_ROW
		for index in 0 ..< shown_count {
			row := list.rows[first + index]
			switch row.kind {
			case .Heading_Recent:
				rows[index] = {kind = .Heading, name = HEADING_RECENT}
			case .Heading_Windows:
				rows[index] = {kind = .Heading, name = HEADING_WINDOWS}
			case .Heading_Programs:
				rows[index] = {kind = .Heading, name = HEADING_PROGRAMS}
			case .Entry:
				entry := &list.entries[min(int(row.entry), ENTRY_CAPACITY - 1)]
				color, outlined, shown := mark_color(entry.mark)
				rows[index] = {kind = .Entry, name = entry_name(entry), matched_places = transmute(u128)row.places, mark_shown = shown, mark_outlined = outlined, mark_color = color, right_text = entry_words(entry)}
				if given := given_of(list, entry); given != nil {
					// A command is code: its name in the font of the cells,
					// then its parameters and its result, quiet. A command
					// that the panel cannot run is dim.
					rows[index].name_in_cells = true
					rows[index].name_color = .Needs_Arguments in entry.flags ? graphics.Color(graphics.COLOR_DIM) : graphics.code_class_color(.Name, false)
					rows[index].detail = string(given.signature[given.name_length:given.signature_length])
				}
				if first + index == panel.choice {
					chosen_shown = index
					if panel.state == .Confirm {
						// The row says the act in full, and no letter is marked:
						// the text is no longer the name that the input searched.
						confirm_sentence(&confirm_text, list, entry)
						rows[index] = {kind = .Entry, name = interface.text_of(&confirm_text), mark_shown = shown, mark_outlined = outlined, mark_color = color, right_text = rows[index].right_text}
					}
				}
			}
		}
		// The chosen row keeps its kind at its right, in white: two rows
		// with one name stay two things. What Enter does is in the footer.
		options := interface.List_Rows_Options{chosen = chosen_shown, first = first, total = list.row_count}
		if panel.state == .Confirm {
			options.chosen_color = graphics.COLOR_STOP_PROGRAM
		}
		interface.list_of_rows(frame, list_area, rows[:shown_count], options)
		if list.row_count == 0 {
			// No entry has the typed part: one dim line says so.
			empty: interface.Text_Builder
			interface.text_put(&empty, "nothing has \"")
			interface.text_put(&empty, typed_text(panel))
			interface.text_put(&empty, "\" in its name")
			interface.draw_text(table, x + TEXT_MARGIN, y + LIST_TOP + 4, interface.text_fit(table, interface.FONT_INTERFACE, interface.text_of(&empty), text_room), graphics.COLOR_DIM, interface.FONT_INTERFACE)
		}
		// The detail line: what the chosen entry does, whole.
		if chosen != nil {
			about: interface.Text_Builder
			entry_about(&about, list, chosen)
			interface.draw_text(table, x + TEXT_MARGIN, y + DETAIL_TOP + 4, interface.text_fit(table, interface.FONT_INTERFACE, interface.text_of(&about), text_room), graphics.COLOR_DIM, interface.FONT_INTERFACE)
		}
	}

	// The footer: at the right the keys of the state, with what Enter does
	// on the chosen entry; at the left the count of the entries that match
	// of all the entries, then what the list lacks when the console gives
	// no commands. The count is a value: the font of the cells.
	keys: interface.Text_Builder
	switch panel.state {
	case .Closed, .Search:
		interface.text_put(&keys, KEYS_START)
		interface.text_put(&keys, chosen != nil ? entry_hint(chosen) : "enter: run")
		interface.text_put(&keys, KEYS_END)
	case .Confirm:
		interface.text_put(&keys, KEYS_OF_CONFIRM)
	case .Running:
		interface.text_put(&keys, KEYS_OF_RUNNING)
	case .Result:
		interface.text_put(&keys, KEYS_OF_RESULT)
	}
	keys_width := interface.text_measured_width(table, interface.FONT_INTERFACE, interface.text_of(&keys))
	interface.draw_text_right(table, x + PANEL_WIDTH - TEXT_MARGIN, y + FOOTER_TOP + 4, interface.text_of(&keys), graphics.COLOR_DIM, interface.FONT_INTERFACE)
	count: interface.Text_Builder
	interface.text_put_number(&count, u64(list.matched_count))
	interface.text_put(&count, " of ")
	interface.text_put_number(&count, u64(list.entry_count))
	after := interface.draw_text(table, x + TEXT_MARGIN, y + FOOTER_TOP + 4, interface.text_of(&count), graphics.COLOR_TEXT)
	after = interface.draw_text(table, after + 8, y + FOOTER_TOP + 4, "entries", graphics.COLOR_DIM, interface.FONT_INTERFACE)
	if list.provider != .Ready {
		note := list.provider == .Absent ? NOTE_NO_PROVIDER : NOTE_REFUSED_PROVIDER
		note_room := x + PANEL_WIDTH - TEXT_MARGIN - keys_width - 16 - (after + 16)
		interface.draw_text(table, after + 16, y + FOOTER_TOP + 4, interface.text_fit(table, interface.FONT_INTERFACE, note, note_room), graphics.COLOR_DIM, interface.FONT_INTERFACE)
	}
}

// result_draw draws, in the place of the list, the entry that the panel
// sent and what the provider gave: the call, then, while the panel waits,
// that it runs; after that the lines of the result, each run in the color of what it is.
// The one number of an Integer result is at three times the size of the
// font. The runs are a checked copy; the bounds are checked here once
// more, so a fault of the check draws less and reads nothing else.
@(private)
result_draw :: proc "contextless" (frame: ^interface.Frame, panel: ^Panel, x, y: int) {
	table := frame.table
	result := &panel.result
	call: interface.Text_Builder
	interface.text_put(&call, sent_text(panel))
	interface.text_put(&call, "()")
	after_call := interface.draw_text(table, x + TEXT_MARGIN, y + LIST_TOP + RESULT_CALL_TOP, interface.text_of(&call), graphics.code_class_color(.Name, false))
	if panel.state == .Running {
		interface.draw_text(table, after_call + 16, y + LIST_TOP + RESULT_CALL_TOP, WORDS_OF_RUNNING, graphics.COLOR_DIM, interface.FONT_INTERFACE)
		return
	}
	runs := result.runs[:clamp(result.count, 0, len(result.runs))]
	large := result.outcome == .Shown_In_Panel && result.kind == .Integer
	place, line := 0, 0
	run_x := x + TEXT_MARGIN
	for place + 2 <= len(runs) && line < palette_table.RESULT_LINE_CAPACITY {
		part, length := runs[place], int(runs[place + 1])
		place += 2
		if part == u8(palette_table.Run_Part.End_Line) {
			line += 1
			run_x = x + TEXT_MARGIN
			continue
		}
		if part > u8(palette_table.Run_Part.Operation) || length > len(runs) - place {
			return
		}
		text := string(runs[place:][:length])
		place += length
		line_y := y + LIST_TOP + RESULT_LINES_TOP + line * interface.LINE
		if large && line == 0 {
			run_x = interface.large_number(frame, run_x, line_y, text, part_color(palette_table.Run_Part(part)))
			continue
		}
		run_x = interface.draw_text(table, run_x, line_y, text, part_color(palette_table.Run_Part(part)))
	}
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

// confirm_sentence writes the text of the row that asks for a second
// Enter. It says the act in full: "stop plasma: its window closes" for the
// close of a window; the call and the help sentence of a command of a
// provider, "shutdown(): stop the machine".
@(private)
confirm_sentence :: proc "contextless" (builder: ^interface.Text_Builder, list: ^List, entry: ^Entry) {
	if entry.kind == .Close_Window {
		interface.text_put(builder, "stop ")
		interface.text_put(builder, window_title_of(entry))
		interface.text_put(builder, ": its window closes")
		return
	}
	interface.text_put(builder, entry_name(entry))
	interface.text_put(builder, "()")
	if given := given_of(list, entry); given != nil && given.about_length > 0 {
		interface.text_put(builder, ": ")
		interface.text_put(builder, string(given.about[:given.about_length]))
	}
}
