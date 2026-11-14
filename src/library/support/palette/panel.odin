package palette

import "modus:contract/palette_table"
import "modus:contract/value_kinds"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/kind_icons"

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
	if panel.list == nil || panel.state != .Search && panel.state != .Confirm || panel.form.active {
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
	case .Setting:
		return "setting"
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

// entry_hint gives what Enter does on an entry: the footer says it. form:
// the panel has a field for each parameter of the entry. manual: the typed
// part has the prefix of the manual.
entry_hint :: proc "contextless" (entry: ^Entry, form: bool, manual: bool) -> string {
	if manual && entry.kind == .Program {
		return "enter: its page of the manual"
	}
	switch entry.kind {
	case .Window:
		return "enter: to the front"
	case .Program:
		return "enter: start"
	case .Close_Window:
		return "enter: close"
	case .Command, .Export:
		if .Needs_Arguments not_in entry.flags {
			return "enter: run"
		}
		return form ? "enter: arguments" : "enter: arguments in the console"
	case .Setting:
		return "enter: set"
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
	case .Command, .Export, .Setting:
		if given := given_of(list, entry); given != nil {
			interface.text_put(builder, string(given.about[:given.about_length]))
		}
	}
}

// setting_in_use says if a Setting entry is the value that the machine
// uses now, from the values that the owner of the panel gave.
setting_in_use :: proc "contextless" (panel: ^Panel, entry: ^Entry) -> bool {
	given := given_of(panel.list, entry)
	if given == nil || given.kind != .Setting || int(given.setting) >= len(panel.settings_in_use) {
		return false
	}
	return panel.settings_in_use[given.setting] == given.setting_value
}

// signature_fit gives the parameters and the result of a command for a
// room in cells: whole when they fit; else the parameters that fit whole,
// then ", ...)"; else "(...)". The text is never cut inside a parameter.
// buffer holds the cut form.
signature_fit :: proc "contextless" (detail: string, cells: int, buffer: []u8) -> string {
	if len(detail) <= cells {
		return detail
	}
	// The end of each parameter: the place of ", " at the level of the
	// parentheses of the call.
	depth := 0
	best := 0
	for index in 0 ..< len(detail) {
		switch detail[index] {
		case '(':
			depth += 1
		case ')':
			depth -= 1
		case ',':
			if depth == 1 && index + len(", ...)") <= cells {
				best = index
			}
		}
	}
	if best == 0 {
		short := "(...)"
		return len(short) <= cells ? short : ""
	}
	count := copy(buffer, detail[:best])
	count += copy(buffer[count:], ", ...)")
	return string(buffer[:count])
}

// The color of the icon of an entry that destroys: the red of "stop a
// program" in its brighter form, the red of the close button under the
// pointer. The deep red of the button is too near the surface of a card for
// the thin parts of an icon.
ICON_COLOR_OF_STOP :: graphics.COLOR_STOP_PROGRAM_POINTER_OVER
// The color of the icon of an entry in its quiet state: a program with no
// window, a window that has not the focus, a value of a setting that the
// machine does not use, a command that the panel cannot run at once.
ICON_COLOR_QUIET :: graphics.COLOR_DIM

// entry_icon gives the icon of an entry and its color on a row that is not
// chosen (docs/DESIGN.md, "The icons of the kinds"). The form says what the
// entry is, so a reader who does not tell the colors apart still tells a
// window from a program; an entry that destroys has the icon of that act,
// whatever its kind. The color says one fact of the entry: the color of
// its kind when the thing is there or in use, the quiet color when it is
// not. in_use: the entry is the value of a setting that the machine uses
// now.
entry_icon :: proc "contextless" (entry: ^Entry, in_use: bool) -> (icon: ^kind_icons.Cells, color: graphics.Color) {
	if entry.mark == .Destroys || entry.kind == .Close_Window {
		return kind_icons.cells_of_desktop_kind(.Stop), ICON_COLOR_OF_STOP
	}
	quiet := .Needs_Arguments in entry.flags
	switch entry.kind {
	case .Window:
		icon = kind_icons.cells_of_desktop_kind(.Window)
		color = graphics.COLOR_TITLE
		quiet = entry.mark != .Has_Focus
	case .Program:
		icon = kind_icons.cells_of_value_kind(.Module)
		color = graphics.value_kind_color(value_kinds.Value_Kind.Module, false)
		quiet = entry.mark != .Has_Window
	case .Close_Window:
	case .Command:
		icon = kind_icons.cells_of_value_kind(.Command)
		color = graphics.value_kind_color(value_kinds.Value_Kind.Command, false)
	case .Export:
		// An export is a part of a module: the color of a module.
		icon = kind_icons.cells_of_desktop_kind(.Export)
		color = graphics.value_kind_color(value_kinds.Value_Kind.Module, false)
	case .Setting:
		icon = kind_icons.cells_of_desktop_kind(.Setting)
		color = graphics.COLOR_TEXT
		quiet = !in_use
	}
	if quiet {
		color = ICON_COLOR_QUIET
	}
	return
}

// candidate_icon gives the icon of the candidates of a field of a form and
// its color: the kind of what the field takes.
candidate_icon :: proc "contextless" (kind: palette_table.Candidate_Kind) -> (icon: ^kind_icons.Cells, color: graphics.Color) {
	switch kind {
	case .None:
	case .Program, .Module:
		return kind_icons.cells_of_value_kind(.Module), graphics.value_kind_color(value_kinds.Value_Kind.Module, false)
	case .Grant:
		return kind_icons.cells_of_value_kind(.Grant), graphics.value_kind_color(value_kinds.Value_Kind.Grant, false)
	}
	return nil, 0
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
KEYS_END :: "   esc: close"
KEYS_OF_PREFIXES :: "> commands  @ windows  : settings  ? manual"
KEYS_OF_ARGUMENTS :: "tab: next field   enter: run   esc: back"
KEYS_OF_ARGUMENTS_MORE :: "tab, enter: next field   ctrl enter: run   esc: back"
KEYS_OF_CONFIRM :: "enter: confirm   another key: back"
KEYS_OF_RUNNING :: "esc: close; the line goes on in the console"
KEYS_OF_RESULT :: "esc: close   another key: back"
WORDS_OF_RUNNING :: "runs in the console"
NOTE_NO_PROVIDER :: "entries, no commands"
NOTE_REFUSED_PROVIDER :: "entries, commands refused"
WORD_OF_COUNT :: "entries"
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
	with_form := panel.form.active && panel.state != .Result
	prefix, _ := prefix_of(typed_text(panel))
	if with_form {
		form_band_draw(frame, &panel.form, x, y)
	} else {
		interface.text_input_line(frame, {x, y, PANEL_WIDTH, INPUT_BAND_HEIGHT}, typed_text(panel), panel.line.caret, INPUT_SCALE, PLACEHOLDER)
		// The word of the prefix, at the right of the band: what the list
		// is restricted to.
		if word := prefix_words(prefix); word != "" {
			interface.draw_text_right(table, x + PANEL_WIDTH - TEXT_MARGIN, y + (INPUT_BAND_HEIGHT - interface.LINE) / 2, word, graphics.COLOR_DIM, interface.FONT_INTERFACE)
		}
	}

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

	if panel.state == .Arguments || panel.state == .Confirm && with_form {
		form_list_draw(frame, panel, x, y)
	} else if panel.state == .Result || panel.state == .Running {
		// The list makes room for the entry that the panel sent: a new
		// list can come while the provider runs it.
		result_draw(frame, panel, x, y)
	} else {
		// The rows that the panel shows.
		list_area := interface.Area{x + BORDER, y + LIST_TOP, PANEL_WIDTH - 2 * BORDER, LIST_HEIGHT}
		confirm_text: interface.Text_Builder
		signatures: [LIST_ROWS][palette_table.SIGNATURE_CAPACITY + 8]u8
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
				in_use := entry.kind == .Setting && setting_in_use(panel, entry)
				icon, icon_color := entry_icon(entry, in_use)
				rows[index] = {kind = .Entry, name = entry_name(entry), matched_places = transmute(u128)row.places, icon = icon, icon_color = icon_color, right_text = entry_words(entry)}
				if entry.kind == .Setting {
					// The value in use has its icon in the text color, and
					// says so in words.
					if in_use {
						rows[index].right_text = "setting, in use"
					}
				} else if given := given_of(list, entry); given != nil {
					// A command is code: its name in the font of the cells,
					// then its parameters and its result, quiet. A command
					// that the panel cannot run is dim.
					rows[index].name_in_cells = true
					rows[index].name_color = .Needs_Arguments in entry.flags ? graphics.Color(graphics.COLOR_DIM) : graphics.code_class_color(.Name, false)
					// The room of the signature: the row, less its name and the
					// words at its right. It is cut at the end of a parameter.
					words_width := interface.text_measured_width(table, interface.FONT_INTERFACE, rows[index].right_text)
					room := list_area.width - (list.row_count > LIST_ROWS ? interface.LIST_ROW_SCROLL_WIDTH : 0) - interface.LIST_ROW_NAME_X - interface.LIST_ROW_RIGHT_MARGIN - words_width - 16 - int(given.name_length) * graphics.CELL_WIDTH
					rows[index].detail = signature_fit(string(given.signature[given.name_length:given.signature_length]), room / graphics.CELL_WIDTH, signatures[index][:])
				}
				if first + index == panel.choice {
					chosen_shown = index
					if panel.state == .Confirm {
						// The row says the act in full, and no letter is marked:
						// the text is no longer the name that the input searched.
						confirm_sentence(&confirm_text, list, entry)
						rows[index] = {kind = .Entry, name = interface.text_of(&confirm_text), icon = icon, icon_color = icon_color, right_text = rows[index].right_text}
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
	// on the chosen entry, or the prefixes while nothing is typed; at the
	// left, in the search only, the count of the entries that match of all
	// the entries, and what the list lacks when the console gives no
	// commands. The count is a value: the font of the cells.
	keys: interface.Text_Builder
	switch panel.state {
	case .Closed, .Search:
		if len(typed_text(panel)) == 0 && list.provider == .Ready {
			// Nothing is typed: the footer teaches the prefixes. With no
			// provider two of them list nothing, and the footer says
			// what the list lacks.
			interface.text_put(&keys, KEYS_OF_PREFIXES)
		} else {
			interface.text_put(&keys, chosen != nil ? entry_hint(chosen, form_can_open(given_of(list, chosen)), prefix == .Manual) : "enter: run")
			interface.text_put(&keys, KEYS_END)
		}
	case .Confirm:
		interface.text_put(&keys, KEYS_OF_CONFIRM)
	case .Running:
		interface.text_put(&keys, KEYS_OF_RUNNING)
	case .Result:
		interface.text_put(&keys, KEYS_OF_RESULT)
	case .Arguments:
		interface.text_put(&keys, panel.form.field_count > 1 ? KEYS_OF_ARGUMENTS_MORE : KEYS_OF_ARGUMENTS)
	}
	keys_width := interface.text_measured_width(table, interface.FONT_INTERFACE, interface.text_of(&keys))
	interface.draw_text_right(table, x + PANEL_WIDTH - TEXT_MARGIN, y + FOOTER_TOP + 4, interface.text_of(&keys), graphics.COLOR_DIM, interface.FONT_INTERFACE)
	if panel.state != .Search && panel.state != .Closed {
		return
	}
	count: interface.Text_Builder
	interface.text_put_number(&count, u64(list.matched_count))
	interface.text_put(&count, " of ")
	interface.text_put_number(&count, u64(list.entry_count))
	after := interface.draw_text(table, x + TEXT_MARGIN, y + FOOTER_TOP + 4, interface.text_of(&count), graphics.COLOR_TEXT)
	words := WORD_OF_COUNT
	switch list.provider {
	case .Ready:
	case .Absent:
		words = NOTE_NO_PROVIDER
	case .Refused:
		words = NOTE_REFUSED_PROVIDER
	}
	words_room := x + PANEL_WIDTH - TEXT_MARGIN - keys_width - 16 - (after + 8)
	interface.draw_text(table, after + 8, y + FOOTER_TOP + 4, interface.text_fit(table, interface.FONT_INTERFACE, words, words_room), graphics.COLOR_DIM, interface.FONT_INTERFACE)
}

// The classes of the characters of the band of a form.
@(private)
Band_Class :: enum u8 {
	Name, // The name of the command.
	Quiet, // Punctuation, and the name of a parameter that has not the caret.
	Label, // The name of the parameter that has the caret.
	Value, // What the input typed.
}

// form_band_draw draws the input band of a form: the call as code, at the
// scale of the typed part: the name of the command, then each parameter
// with its name and what the input typed in it, and the caret in the
// current field: "revoke(name: console, grant: |)". A call wider than the
// band shows the part that holds the caret.
@(private)
form_band_draw :: proc "contextless" (frame: ^interface.Frame, form: ^Form, x, y: int) {
	table := frame.table
	characters: [512]u8
	classes: [512]Band_Class
	count, caret := 0, 0
	put :: proc "contextless" (into: ^[512]u8, kinds: ^[512]Band_Class, used: ^int, text: string, class: Band_Class) {
		for index in 0 ..< len(text) {
			if used^ < len(into) {
				into[used^] = text[index]
				kinds[used^] = class
				used^ += 1
			}
		}
	}
	put(&characters, &classes, &count, entry_name(&form.entry), .Name)
	put(&characters, &classes, &count, "(", .Quiet)
	for field in 0 ..< form.field_count {
		if field > 0 {
			put(&characters, &classes, &count, ", ", .Quiet)
		}
		if name := field_name(form, field); name != "" {
			put(&characters, &classes, &count, name, field == form.current ? Band_Class.Label : Band_Class.Quiet)
			put(&characters, &classes, &count, ": ", .Quiet)
		}
		if field == form.current {
			caret = count + clamp(form.fields[field].caret, 0, form.fields[field].count)
		}
		put(&characters, &classes, &count, field_text(form, field), .Value)
	}
	put(&characters, &classes, &count, ")", .Quiet)

	cell_width := graphics.CELL_WIDTH * INPUT_SCALE
	text_height := graphics.CELL_HEIGHT * INPUT_SCALE
	caret_width := 2 * INPUT_SCALE
	interface.draw_rectangle(table, x, y, PANEL_WIDTH, INPUT_BAND_HEIGHT - 2, graphics.COLOR_TRACK)
	interface.draw_rectangle(table, x, y + INPUT_BAND_HEIGHT - 2, PANEL_WIDTH, 2, graphics.COLOR_TITLE)
	text_x := x + interface.TEXT_INPUT_LINE_MARGIN
	text_y := y + (INPUT_BAND_HEIGHT - text_height) / 2
	fit := (PANEL_WIDTH - 2 * interface.TEXT_INPUT_LINE_MARGIN - caret_width) / cell_width
	first := count > fit ? clamp(caret - fit + 4, 0, count - fit) : 0
	last := min(first + fit, count)
	interface.draw_rectangle(table, text_x + (caret - first) * cell_width, text_y, caret_width, text_height, graphics.COLOR_TITLE)
	font := interface.Font{scale = INPUT_SCALE}
	// One text record for each run of one class.
	start := first
	for start < last {
		end := start + 1
		for end < last && classes[end] == classes[start] {
			end += 1
		}
		color: graphics.Color
		switch classes[start] {
		case .Name:
			color = graphics.code_class_color(.Name, false)
		case .Quiet:
			color = graphics.code_class_color(.Punctuation, false)
		case .Label:
			color = graphics.COLOR_TEXT
		case .Value:
			color = graphics.COLOR_WHITE
		}
		interface.draw_text(table, text_x + (start - first) * cell_width, text_y, string(characters[start:end]), color, font)
		start = end
	}
}

// form_list_draw draws the list area and the detail line of a form: the
// candidates of the field that has the caret, the chosen one filled; and
// under them why a key or a field was refused, or the signature of the
// command. While the panel asks for a second Enter after a form, the list
// area has the one row that says the act.
@(private)
form_list_draw :: proc "contextless" (frame: ^interface.Frame, panel: ^Panel, x, y: int) {
	table := frame.table
	form := &panel.form
	list_area := interface.Area{x + BORDER, y + LIST_TOP, PANEL_WIDTH - 2 * BORDER, LIST_HEIGHT}
	text_room := PANEL_WIDTH - 2 * TEXT_MARGIN
	rows: [LIST_ROWS]interface.List_Row
	if panel.state == .Confirm {
		act: interface.Text_Builder
		interface.text_put(&act, entry_name(&form.entry))
		interface.text_put(&act, "(")
		for field in 0 ..< form.field_count {
			interface.text_put(&act, field > 0 ? ", " : "")
			interface.text_put(&act, field_text(form, field))
		}
		interface.text_put(&act, "): ")
		interface.text_put(&act, string(form.given.about[:form.given.about_length]))
		rows[0] = {kind = .Entry, name = interface.text_of(&act), icon = kind_icons.cells_of_desktop_kind(.Stop), icon_color = ICON_COLOR_OF_STOP, right_text = entry_words(&form.entry)}
		interface.list_of_rows(frame, list_area, rows[:1], {chosen = 0, chosen_color = graphics.COLOR_STOP_PROGRAM, total = 1})
		return
	}
	words := ""
	switch form.candidate_kind {
	case .None:
	case .Program:
		words = "program"
	case .Module:
		words = "module"
	case .Grant:
		words = "grant"
	}
	candidates_icon, candidates_color := candidate_icon(form.candidate_kind)
	choice := form.candidate_choice
	first := choice >= LIST_ROWS ? choice - LIST_ROWS + 1 : 0
	shown_count := clamp(form.shown_count - first, 0, LIST_ROWS)
	for index in 0 ..< shown_count {
		rows[index] = {kind = .Entry, name = candidate_name(form, first + index), icon = candidates_icon, icon_color = candidates_color, right_text = words}
	}
	interface.list_of_rows(frame, list_area, rows[:shown_count], {chosen = choice - first, first = first, total = form.shown_count})
	if form.shown_count == 0 {
		prompt: interface.Text_Builder
		interface.text_put(&prompt, "type the value of ")
		name := field_name(form, form.current)
		interface.text_put(&prompt, name != "" ? name : "the parameter")
		interface.text_put(&prompt, form.given.parameters[form.current] == .Integer ? ": an Integer" : ": a Text")
		interface.draw_text(table, x + TEXT_MARGIN, y + LIST_TOP + 4, interface.text_fit(table, interface.FONT_INTERFACE, interface.text_of(&prompt), text_room), graphics.COLOR_DIM, interface.FONT_INTERFACE)
	}
	if message := form_message(form); message != "" {
		interface.draw_text(table, x + TEXT_MARGIN, y + DETAIL_TOP + 4, interface.text_fit(table, interface.FONT_INTERFACE, message, text_room), graphics.COLOR_FAILED, interface.FONT_INTERFACE)
		return
	}
	// The whole signature, as code, then the help sentence.
	signature := string(form.given.signature[:form.given.signature_length])
	after := interface.draw_text(table, x + TEXT_MARGIN, y + DETAIL_TOP + 4, interface.text_fit(table, {}, signature, text_room), graphics.code_class_color(.Punctuation, false))
	about := string(form.given.about[:form.given.about_length])
	interface.draw_text(table, after + 16, y + DETAIL_TOP + 4, interface.text_fit(table, interface.FONT_INTERFACE, about, x + TEXT_MARGIN + text_room - after - 16), graphics.COLOR_DIM, interface.FONT_INTERFACE)
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
