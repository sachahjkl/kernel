package interface

import "support:display"
import "support:graphics"

// The elements of the rules (docs/DESIGN.md, section 10). Each one appends
// draw records to the table of the frame; an element that takes input
// gives an Element_Result.
//
// The two fonts (docs/DESIGN.md, section 5; docs/FONTS.md, section 12.6):
// a text that names or explains (a title, a caption, a label, the name of a
// button, a line of a list, the title of a column) is in the interface
// font; a value (a number, a hash, a text that a person types, the count of
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

Alignment :: enum u8 {
	Left,
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
// a bar at the right when the lines do not fit. With the focus, up and down
// move the choice; Enter, or a press on a line, activates it. It gives
// changed when the choice changed.
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
	scroll_width := len(names) > rows ? 8 : 0
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
	if scroll_width != 0 {
		track := rows * TABLE_LINE
		x := area.x + area.width - 2
		draw_rectangle(frame.table, x, area.y, 2, track, graphics.COLOR_TRACK)
		draw_rectangle(frame.table, x, area.y + first * track / len(names), 2, max(rows * track / len(names), 2), graphics.COLOR_DIM)
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
