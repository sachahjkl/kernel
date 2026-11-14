package interface

import "support:display"
import "support:graphics"
import "support:kind_icons"

// The elements of the rules (docs/DESIGN.md, section 10). Each one appends
// draw records to the table of the frame; an element that takes input
// gives an Element_Result.
//
// The two fonts (docs/DESIGN.md, section 5; docs/FONTS.md, section 12.6):
// a text that names or explains (a title, a caption, a label, the name of a
// button, a line of a list, the title of a column) is in the interface
// font; a value (a number, a hash, a text that the input types, the count of
// a card, the cells of a table) is in the font of the cells, so values
// align by character. Each element measures a text in the font that draws
// it, and cuts it to its box: no text passes its element in either font.

// background draws the background of the rules on an area: one color and
// the grid of points.
background :: proc "contextless" (frame: ^Frame, area: Area) {
	draw_rectangle(frame.table, area.x, area.y, area.width, area.height, graphics.COLOR_BACKGROUND)
	draw_point_grid(frame.table, area.x, area.y, area.width, area.height)
}

// card draws the frame of one subject (docs/DESIGN.md, section 3): a border
// of 1 pixel in its accent, the surface of a card, a bar of 4 x 16 pixels
// and the title in the accent, the caption of its record in the dim color,
// and a count at the right. It gives the area of its content.
card :: proc "contextless" (frame: ^Frame, area: Area, title, caption: string, accent: graphics.Color, count := "") -> Area {
	table := frame.table
	draw_vertical_gradient(table, area.x, area.y, area.width, area.height, graphics.shade(accent, 28), graphics.shade(accent, 14))
	draw_vertical_gradient(table, area.x + 1, area.y + 1, area.width - 2, area.height - 2, graphics.COLOR_CARD_TOP, graphics.COLOR_CARD_BOTTOM)
	draw_vertical_gradient(table, area.x + graphics.CARD_MARGIN, area.y + 12, 4, 16, graphics.shade(accent, 130), accent)
	// The title, then the caption, take the room before the count: a
	// narrow card cuts them, so they never run past the border.
	title_left := area.x + graphics.CARD_MARGIN + 12
	right := area.x + area.width - graphics.CARD_MARGIN
	if count != "" {
		right -= text_measured_width(table, {}, count) + 16
	}
	after := draw_text(table, title_left, area.y + 12, text_fit(table, FONT_INTERFACE_BOLD, title, right - title_left), accent, FONT_INTERFACE_BOLD)
	if count != "" {
		draw_text_right(table, area.x + area.width - graphics.CARD_MARGIN, area.y + 12, count, graphics.COLOR_TEXT)
	}
	draw_text(table, after + 16, area.y + 12, text_fit(table, FONT_INTERFACE, caption, right - (after + 16)), graphics.COLOR_DIM, FONT_INTERFACE)
	return {area.x + graphics.CARD_MARGIN, area.y + graphics.CARD_TITLE, area.width - 2 * graphics.CARD_MARGIN, area.height - graphics.CARD_TITLE - 8}
}

// label_value_line draws a name in the dim color and its value: at
// value_x from the left of the area, or at the right of the area (a number,
// docs/DESIGN.md section 5) when value_x is 0.
label_value_line :: proc "contextless" (frame: ^Frame, area: Area, label, value: string, value_color: graphics.Color = graphics.COLOR_TEXT, value_x := 0) {
	table := frame.table
	y := area.y + (area.height - LINE) / 2
	// The value, in the font of the cells, takes its room first; the label
	// takes what is left, with a gap of 8 pixels.
	value_room := value_x == 0 ? area.width : area.width - value_x
	shown_value := text_fit(table, {}, value, value_room)
	label_room := value_x == 0 ? area.width - text_measured_width(table, {}, shown_value) - 8 : value_x - 8
	draw_text(table, area.x, y, text_fit(table, FONT_INTERFACE, label, label_room), graphics.COLOR_DIM, FONT_INTERFACE)
	if value_x == 0 {
		draw_text_right(table, area.x + area.width, y, shown_value, value_color)
	} else {
		draw_text(table, area.x + value_x, y, shown_value, value_color)
	}
}

// table_band draws the band under a line of a table: every second line,
// from the first, has the surface of a card (docs/DESIGN.md, section 3).
table_band :: proc "contextless" (frame: ^Frame, area: Area, index: int) {
	if index % 2 == 0 {
		draw_rectangle(frame.table, area.x, area.y, area.width, area.height, graphics.COLOR_CARD_TOP)
	}
}

// Where a text sits in the width of a cell.
Alignment :: enum u8 {
	Left, // Names and texts.
	Right, // Numbers, with their unit.
}

// cell_text draws a text in a cell of a line, in the middle of its height,
// cut to the width of the cell. Its font is the font of the cells unless
// the caller names another: a cell of a table holds a value.
cell_text :: proc "contextless" (frame: ^Frame, cell: Area, text: string, color: graphics.Color, alignment: Alignment = .Left, font: Font = {}) {
	y := cell.y + (cell.height - line_height(font)) / 2
	shown := text_fit(frame.table, font, text, cell.width)
	if alignment == .Right {
		draw_text_right(frame.table, cell.x + cell.width, y, shown, color, font)
	} else {
		draw_text(frame.table, cell.x, y, shown, color, font)
	}
}

// table_header draws the titles of the columns of a table, in the dim color
// and the interface font: a title names its column.
table_header :: proc "contextless" (frame: ^Frame, cells: []Area, titles: []string, alignments: []Alignment = nil) {
	for title, index in titles[:min(len(titles), len(cells))] {
		cell_text(frame, cells[index], title, graphics.COLOR_DIM, index < len(alignments) ? alignments[index] : .Left, FONT_INTERFACE)
	}
}

// bar draws a value against a maximum: the track, and the full part from
// 125 % of its color at the top to 78 % at the bottom (docs/DESIGN.md,
// section 3). A value above 0 has a full part of 2 pixels at least.
bar :: proc "contextless" (frame: ^Frame, area: Area, value, maximum: u64, color: graphics.Color) {
	draw_rectangle(frame.table, area.x, area.y, area.width, area.height, graphics.COLOR_TRACK)
	full_width := int(min(value, max(maximum, 1)) * u64(area.width) / max(maximum, 1))
	if value > 0 {
		full_width = max(full_width, 2)
	}
	draw_vertical_gradient(frame.table, area.x, area.y, full_width, area.height, graphics.shade(color, 125), graphics.shade(color, 78))
}

// bar_parts draws parts of one total side by side on a track, each in its
// color: the width of a part is its count.
bar_parts :: proc "contextless" (frame: ^Frame, area: Area, counts: []u64, colors: []graphics.Color, total: u64) {
	draw_rectangle(frame.table, area.x, area.y, area.width, area.height, graphics.COLOR_TRACK)
	x := area.x
	for count, index in counts[:min(len(counts), len(colors))] {
		width := int(count * u64(area.width) / max(total, 1))
		draw_vertical_gradient(frame.table, x, area.y, width, area.height, graphics.shade(colors[index], 125), graphics.shade(colors[index], 78))
		x += width
	}
}

// mark draws a square: a point or a mark of the rules.
mark :: proc "contextless" (frame: ^Frame, x, y, size: int, color: graphics.Color) {
	draw_rectangle(frame.table, x, y, size, size, color)
}

// large_number draws the one number of a card, three times the size of the
// font, and gives the x after it.
large_number :: proc "contextless" (frame: ^Frame, x, y: int, text: string, color: graphics.Color) -> int {
	return draw_text(frame.table, x, y, text, color, FONT_LARGE)
}

// button draws a button with a label: the track, blue when it has the focus
// or the pointer is over it. Enter or Space with the focus, or a press and a
// release of the pointer on it, activate it.
button :: proc "contextless" (frame: ^Frame, area: Area, element: Element_Identity, label: string, open := false) -> Element_Result {
	result := element_interact(frame, element, area, .Button)
	color := graphics.Color(graphics.COLOR_TRACK)
	switch {
	case open || result.focused && result.under_pointer:
		color = graphics.COLOR_CHOSEN
	case result.focused || result.under_pointer:
		color = graphics.shade(graphics.COLOR_TITLE, 60)
	}
	draw_rectangle(frame.table, area.x, area.y, area.width, area.height, color, u32(element))
	shown := text_fit(frame.table, FONT_INTERFACE, label, area.width - 16)
	draw_text(frame.table, area.x + 8, area.y + (area.height - LINE) / 2, shown, color == graphics.COLOR_TRACK ? graphics.COLOR_TEXT : graphics.COLOR_WHITE, FONT_INTERFACE, u32(element))
	return result
}

// The lines of a list whose names are measured in one call; the lines past
// it are measured one by one.
LIST_MEASURE_CAPACITY :: 64

// List_Options: what a list with a choice shows beside its names.
List_Options :: struct {
	marked:      string, // A line of 2 pixels is under this part of each name (a search).
	chosen_hint: string, // A text at the right of the chosen line ("enter: start").
	empty_text:  string, // The text of a list with no line.
}

// list_with_choice draws the lines of a list, the chosen line in blue, and
// a scroll bar at the right when the lines do not fit. With the focus, up
// and down move the choice; Enter, or a press on a line, activates it. The
// scroll bar moves the choice, which the view follows. It gives changed
// when the choice changed.
list_with_choice :: proc "contextless" (frame: ^Frame, area: Area, element: Element_Identity, names: []string, choice: ^int, options: List_Options = {}) -> Element_Result {
	result := element_interact(frame, element, area, .List)
	rows := max(area.height / TABLE_LINE, 1)
	before := choice^
	if len(names) > 0 {
		choice^ = clamp(choice^, 0, len(names) - 1)
	}
	if result.focused {
		for &key in frame.input.keys[:frame.input.key_count] {
			if key.taken || len(names) == 0 {
				continue
			}
			switch key.code {
			case display.KEY_UP:
				choice^ = (choice^ + len(names) - 1) % len(names)
				key.taken = true
			case display.KEY_DOWN:
				choice^ = (choice^ + 1) % len(names)
				key.taken = true
			}
		}
	}
	first := max(choice^ - rows + 1, 0)
	// A press on a line chooses it.
	input := frame.input
	scroll_width := len(names) > rows ? SCROLL_BAR_THICKNESS : 0
	if scroll_width != 0 {
		// The view of this list follows its choice, so the scroll bar
		// moves the choice: to the last line of the view that it asks for.
		bar_area := Area{area.x + area.width - scroll_width, area.y, scroll_width, rows * TABLE_LINE}
		moved := scroll_bar(frame, bar_area, identity_in(element, "scroll bar"), .Vertical, {total = len(names), visible = rows, first = first})
		if moved.changed {
			choice^ = min(moved.first + rows - 1, len(names) - 1)
			first = max(choice^ - rows + 1, 0)
		}
	}
	if result.under_pointer && input.pressed {
		// A press on a line that the list shows chooses it; a press under
		// the last line or on the bar at the right chooses nothing.
		row := (input.pointer_y - area.y) / TABLE_LINE
		line := first + row
		if row < rows && line < len(names) && input.pointer_x < area.x + area.width - scroll_width {
			choice^ = line
		}
		first = max(choice^ - rows + 1, 0)
	}
	result.changed = choice^ != before
	table := frame.table
	if len(names) == 0 && options.empty_text != "" {
		draw_text(table, area.x + 8, area.y + 4, text_fit(table, FONT_INTERFACE, options.empty_text, area.width - 16), graphics.COLOR_DIM, FONT_INTERFACE)
	}
	// The names of the lines that the list shows, measured in one call.
	shown_count := max(min(len(names) - first, rows), 0)
	widths: [LIST_MEASURE_CAPACITY]int
	measured_count := min(shown_count, LIST_MEASURE_CAPACITY)
	if measured_count > 0 {
		texts_measure(table, FONT_INTERFACE, names[first:][:measured_count], widths[:measured_count])
	}
	line_width := area.width - scroll_width
	hint_width := options.chosen_hint != "" ? text_measured_width(table, FONT_INTERFACE, options.chosen_hint) : 0
	for row in 0 ..< shown_count {
		index := first + row
		y := area.y + row * TABLE_LINE
		chosen := index == choice^
		name_room := line_width - 16
		if chosen {
			draw_rectangle(table, area.x, y, line_width, TABLE_LINE, graphics.COLOR_CHOSEN, u32(element))
			if options.chosen_hint != "" && hint_width <= line_width - 16 {
				draw_text_right(table, area.x + line_width - 8, y + 4, options.chosen_hint, graphics.COLOR_WHITE, FONT_INTERFACE)
				name_room -= hint_width + 8
			}
		}
		name := names[index]
		if row >= measured_count || widths[row] > name_room {
			name = text_fit(table, FONT_INTERFACE, name, name_room)
		}
		draw_text(table, area.x + 8, y + 4, name, chosen ? graphics.COLOR_WHITE : graphics.COLOR_TEXT, FONT_INTERFACE)
		// The marked part, measured in the font of the name.
		if at := find_without_case(name, options.marked); len(options.marked) > 0 && at >= 0 {
			start := text_measured_width(table, FONT_INTERFACE, name[:at])
			end := text_measured_width(table, FONT_INTERFACE, name[:at + len(options.marked)])
			draw_rectangle(table, area.x + 8 + start, y + 20, end - start, 2, chosen ? graphics.COLOR_WHITE : graphics.COLOR_KERNEL)
		}
	}
	return result
}

// text_input draws a field of one line: the text in white and, with the
// focus, a caret; the placeholder in the dim color when it is empty. With
// the focus, a character adds to the text and Backspace removes the last
// one; Enter activates it, in the order of the keys of the frame: the keys
// after Enter are not taken. The text is in the memory of the caller.
text_input :: proc "contextless" (frame: ^Frame, area: Area, element: Element_Identity, text: []u8, count: ^int, placeholder := "") -> Element_Result {
	result := element_interact(frame, element, area, .Text_Input)
	if result.focused {
		keys: for &key in frame.input.keys[:frame.input.key_count] {
			if key.taken {
				continue
			}
			switch {
			case key.code == display.KEY_ENTER:
				// The keys after Enter stay for what Enter starts.
				key.taken = true
				result.activated = true
				break keys
			case key.code == display.KEY_BACKSPACE:
				key.taken = true
				if count^ > 0 {
					count^ -= 1
					result.changed = true
				}
			case key.character >= ' ' && key.character <= '~':
				key.taken = true
				if count^ < len(text) {
					text[count^] = key.character
					count^ += 1
					result.changed = true
				}
			}
		}
	}
	table := frame.table
	draw_rectangle(table, area.x, area.y, area.width, area.height, graphics.COLOR_TRACK, u32(element))
	draw_rectangle(table, area.x, area.y + area.height - 2, area.width, 2, result.focused ? graphics.COLOR_TITLE : graphics.COLOR_NOT_USABLE)
	y := area.y + (area.height - LINE) / 2
	// The typed text is a value, in the font of the cells: its end shows,
	// with room for the caret, so it never passes the field.
	visible := string(text[:count^])
	keep := max(area.width - 16 - 3, 0) / graphics.CELL_WIDTH
	if len(visible) > keep {
		visible = visible[len(visible) - keep:]
	}
	after := draw_text(table, area.x + 8, y, visible, graphics.COLOR_WHITE)
	if result.focused {
		draw_rectangle(table, after + 1, y, 2, LINE, graphics.COLOR_TITLE)
	}
	if count^ == 0 && placeholder != "" {
		draw_text(table, after + 8, y, text_fit(table, FONT_INTERFACE, placeholder, area.x + area.width - 8 - (after + 8)), graphics.COLOR_DIM, FONT_INTERFACE)
	}
	return result
}

// find_without_case gives the first place of part in name, or -1. The
// letters match without their case.
find_without_case :: proc "contextless" (name, part: string) -> int {
	lower :: proc "contextless" (character: u8) -> u8 {
		return character >= 'A' && character <= 'Z' ? character + 32 : character
	}
	for at in 0 ..= len(name) - len(part) {
		same := true
		for index in 0 ..< len(part) {
			if lower(name[at + index]) != lower(part[index]) {
				same = false
				break
			}
		}
		if same {
			return at
		}
	}
	return -1
}

// What a row of a list of rows is.
List_Row_Kind :: enum u8 {
	Entry, // A thing that the input can choose: an icon, a name, a text at the right.
	Heading, // A dim line that names the group of the rows under it. It is never the chosen row.
}

// One row of a list of rows (list_of_rows). The texts stay in the memory of
// the caller.
List_Row :: struct {
	kind:           List_Row_Kind, // An entry or the heading of a group.
	name:           string, // The name, in the interface font.
	matched_places: u128, // Bit n: the byte n of the name matched the search. A line of 2 pixels is under each such character.
	icon:           ^kind_icons.Cells, // The icon of the kind of the entry, before the name: its form says what the entry is. nil: no icon.
	icon_color:     graphics.Color, // The color of the icon on a row that is not chosen: the color of the kind, or of one fact of the entry.
	right_text:     string, // A dim text at the right of the row: what the entry is, in words.
	name_in_cells:  bool, // The name is code: it is in the font of the cells.
	name_color:     graphics.Color, // The color of the name on a row that is not chosen. 0: the text color.
	detail:         string, // A quiet text right after the name, in the font of the cells: the parameters and the result of a command. It is cut to its room.
}

// List_Rows_Options: what a list of rows shows beside its rows.
List_Rows_Options :: struct {
	chosen:       int, // The chosen row, as an index in the rows given; -1: none.
	chosen_color: graphics.Color, // The fill of the chosen row. 0: COLOR_CHOSEN.
	chosen_hint:  string, // On the chosen row, this text takes the place of right_text, in white ("enter: start").
	first:        int, // The index of the first row given in the whole list: the place of the thumb of the scroll bar at the right.
	total:        int, // The rows of the whole list. More than the rows of the area: a scroll bar at the right, which shows the place and takes no input.
}

LIST_ROW_ICON_X :: 16 // From the left of a row to its icon, and to the text of a heading.
LIST_ROW_ICON_SIZE :: kind_icons.ICON_SIZE // The side of the icon: one pixel for each cell.
LIST_ROW_NAME_X :: LIST_ROW_ICON_X + LIST_ROW_ICON_SIZE + 8 // From the left of a row to its name.
LIST_ROW_RIGHT_MARGIN :: 16 // From the text at the right to the right of a row.
LIST_ROW_SCROLL_WIDTH :: SCROLL_BAR_THICKNESS // The scroll bar at the right of a list that does not show each row.

#assert(LIST_ROW_ICON_SIZE <= LINE && (TABLE_LINE - LIST_ROW_ICON_SIZE) % 2 == 0)

// draw_kind_icon appends an icon of a kind (support/kind_icons) whose top
// left corner is at (x, y): each cell is a square of cell_size pixels, so
// the icon is sharp at each size, and the records are the rectangles of
// the icon, at most kind_icons.RECTANGLE_LIMIT. An icon that is nil and a
// cell size under 1 draw nothing.
draw_kind_icon :: proc "contextless" (table: ^Draw_Table, x, y: int, icon: ^kind_icons.Cells, cell_size: int, color: graphics.Color, element: u32 = 0) {
	if icon == nil || cell_size < 1 {
		return
	}
	rectangles: [kind_icons.RECTANGLE_LIMIT]kind_icons.Cell_Rectangle
	count := kind_icons.rectangles_of(icon, &rectangles)
	for index in 0 ..< count {
		part := rectangles[index]
		draw_rectangle(table, x + int(part.x) * cell_size, y + int(part.y) * cell_size, int(part.width) * cell_size, int(part.height) * cell_size, color, element)
	}
}

// list_of_rows draws rows of 24 pixels: for each one the icon of its kind,
// a name with a line of 2 pixels under each matched character, a quiet
// detail after a name that is code, and a dim text at the right; the
// chosen row filled, with its icon and its text in white, and at its
// right its hint when the caller gives one, else the same text as the
// other rows. It takes no input: the caller owns the choice and gives only the
// rows that the area shows, so the work is the rows on the screen, not the
// rows of the list. It gives the count of the rows that it drew.
list_of_rows :: proc "contextless" (frame: ^Frame, area: Area, rows: []List_Row, options: List_Rows_Options) -> int {
	table := frame.table
	shown_count := min(len(rows), area.height / TABLE_LINE, LIST_MEASURE_CAPACITY)
	visible_rows := area.height / TABLE_LINE
	scroll_width := options.total > visible_rows ? LIST_ROW_SCROLL_WIDTH : 0
	line_width := area.width - scroll_width
	chosen_color := options.chosen_color != 0 ? options.chosen_color : graphics.Color(graphics.COLOR_CHOSEN)
	// The names of the rows, measured in one call.
	names: [LIST_MEASURE_CAPACITY]string
	widths: [LIST_MEASURE_CAPACITY]int
	for index in 0 ..< shown_count {
		names[index] = rows[index].name
	}
	if shown_count > 0 {
		texts_measure(table, FONT_INTERFACE, names[:shown_count], widths[:shown_count])
	}
	for index in 0 ..< shown_count {
		row := rows[index]
		y := area.y + index * TABLE_LINE
		if row.kind == .Heading {
			draw_text(table, area.x + LIST_ROW_ICON_X, y + 4, text_fit(table, FONT_INTERFACE, row.name, line_width - 2 * LIST_ROW_ICON_X), graphics.COLOR_DIM, FONT_INTERFACE)
			continue
		}
		chosen := index == options.chosen
		if chosen {
			draw_rectangle(table, area.x, y, line_width, TABLE_LINE, chosen_color)
		}
		// The icon of a chosen row is white, as its text is: no color of
		// the rules keeps the contrast of a graphic on each fill of a
		// chosen row.
		draw_kind_icon(table, area.x + LIST_ROW_ICON_X, y + (TABLE_LINE - LIST_ROW_ICON_SIZE) / 2, row.icon, 1, chosen ? graphics.COLOR_WHITE : row.icon_color)
		// The text at the right takes its room first; the name takes the rest.
		right_text := chosen && options.chosen_hint != "" ? options.chosen_hint : row.right_text
		name_room := line_width - LIST_ROW_NAME_X - LIST_ROW_RIGHT_MARGIN
		if right_text != "" {
			right_width := text_measured_width(table, FONT_INTERFACE, right_text)
			if right_width <= name_room - 16 {
				draw_text_right(table, area.x + line_width - LIST_ROW_RIGHT_MARGIN, y + 4, right_text, chosen ? graphics.COLOR_WHITE : graphics.COLOR_DIM, FONT_INTERFACE)
				name_room -= right_width + 16
			}
		}
		name := row.name
		name_font := row.name_in_cells ? Font{} : FONT_INTERFACE
		name_width := row.name_in_cells ? text_width(name_font, name) : widths[index]
		if name_width > name_room {
			name = text_fit(table, name_font, name, name_room)
			name_width = text_measured_width(table, name_font, name)
		}
		name_x := area.x + LIST_ROW_NAME_X
		name_color := row.name_color != 0 ? row.name_color : graphics.Color(graphics.COLOR_TEXT)
		draw_text(table, name_x, y + 4, name, chosen ? graphics.COLOR_WHITE : name_color, name_font)
		if row.detail != "" {
			draw_text(table, name_x + name_width, y + 4, text_fit(table, {}, row.detail, name_room - name_width), chosen ? graphics.COLOR_WHITE : graphics.COLOR_DIM)
		}
		// One line under each run of matched characters, measured in the
		// font of the name: at most one measure for each end of a run.
		places := row.matched_places
		at := 0
		for places != 0 && at < min(len(name), 128) {
			if places & (u128(1) << uint(at)) == 0 {
				at += 1
				continue
			}
			run_start := at
			for at < min(len(name), 128) && places & (u128(1) << uint(at)) != 0 {
				places &~= u128(1) << uint(at)
				at += 1
			}
			start_x := text_measured_width(table, name_font, name[:run_start])
			end_x := text_measured_width(table, name_font, name[:at])
			draw_rectangle(table, name_x + start_x, y + 20, end_x - start_x, 2, chosen ? graphics.COLOR_WHITE : graphics.COLOR_KERNEL)
		}
	}
	if scroll_width != 0 && options.total > 0 {
		// The caller owns the choice and the pointer: the bar shows the
		// place of the rows, with no input.
		bar_length := visible_rows * TABLE_LINE
		scroll_bar_draw(table, {area.x + area.width - scroll_width, area.y, scroll_width, bar_length}, .Vertical, scroll_bar_geometry(bar_length, scroll_width, {total = options.total, visible = visible_rows, first = options.first}))
	}
	return shown_count
}

TEXT_INPUT_LINE_MARGIN :: 16 // From the left and the right of the field to its text.

// text_input_line draws a field of one line whose text has a caret at any
// place, at a scale of 1 to 3: the track, the line of 2 pixels in the blue
// of the title bar at its bottom, the text in white in the font of the
// cells, the caret (2 pixels wide for each unit of the scale, as high as
// the text), and the placeholder in the dim color when the text is empty.
// The field has no border: its fill reaches each edge of its area. A text
// longer than the field shows the part that holds the caret. It takes no
// input: the caller edits the line (support/line_editor).
text_input_line :: proc "contextless" (frame: ^Frame, area: Area, text: string, caret: int, scale: int, placeholder := "") {
	table := frame.table
	used_scale := clamp(scale, 1, 3)
	font := Font{scale = u8(used_scale)}
	cell_width := graphics.CELL_WIDTH * used_scale
	text_height := graphics.CELL_HEIGHT * used_scale
	caret_width := 2 * used_scale
	draw_rectangle(table, area.x, area.y, area.width, area.height - 2, graphics.COLOR_TRACK)
	draw_rectangle(table, area.x, area.y + area.height - 2, area.width, 2, graphics.COLOR_TITLE)
	text_x := area.x + TEXT_INPUT_LINE_MARGIN
	text_y := area.y + (area.height - text_height) / 2
	fit := max((area.width - 2 * TEXT_INPUT_LINE_MARGIN - caret_width) / cell_width, 1)
	caret_place := clamp(caret, 0, len(text))
	first := len(text) > fit ? max(caret_place - fit, 0) : 0
	shown := text[first:min(first + fit, len(text))]
	// The caret first: a glyph beside it draws over its edge, not under it.
	draw_rectangle(table, text_x + (caret_place - first) * cell_width, text_y, caret_width, text_height, graphics.COLOR_TITLE)
	draw_text(table, text_x, text_y, shown, graphics.COLOR_WHITE, font)
	if len(text) == 0 && placeholder != "" {
		placeholder_x := text_x + cell_width
		placeholder_font := Font{kind = .Interface, scale = u8(used_scale)}
		draw_text(table, placeholder_x, text_y, text_fit(table, placeholder_font, placeholder, area.x + area.width - TEXT_INPUT_LINE_MARGIN - placeholder_x), graphics.COLOR_DIM, placeholder_font)
	}
}
