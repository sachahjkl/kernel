// The bar of the desktop: the names of the programs, and the place of each
// button of the bar and of each line of its two menus, the menu of the
// programs and the menu of the windows. The compositor draws them; the
// kernel tool clicks them in the machine test. The two read this one table.
// The palette (src/library/support/palette) lists the same names.
package bar

import "contract:glyph_cache"
import "support:mark"
import "support:text_shaping"

// The programs that the menu of the programs offers, in its order.
@(rodata)
names := [?]string{"boot", "pages", "log", "console", "monitor", "plasma", "life", "paint", "fault", "temple", "heron", "rings", "threads", "workers", "rights", "origin", "budget", "limits", "processors", "flow", "crowd", "clock", "randomness", "flood", "tally", "manual", "frames", "disk", "notes", "imports", "net", "remote", "server", "inspect", "locks", "errors", "scheduler", "interface_elements", "vector_glyphs", "interface_font", "pointers", "settings", "tables", "interface_through_module", "address_space", "cryptography_vectors", "quic_echo", "extended_state", "return_fault", "fault_ring", "kernel_events"}

// The bar is on the grid of docs/DESIGN.md: 8 pixels.
LABEL :: "programs" // The text of the button that opens the menu of the programs.
CHARACTER_WIDTH :: 8 // The font of the cells.
START :: 80 // After the mark of the system.
PADDING :: 8 // Pixels on each side of the text of a button.
HEIGHT :: 32 // The height of the bar.
BUTTON_Y :: 4 // The top of a button in the bar.
BUTTON_HEIGHT :: 24 // The height of a button.
LINE_HEIGHT :: 24 // One line of a menu.
BORDER :: 1 // The border of a menu, in pixels.
TITLE :: 40 // The title of a menu, as the title of a card.
COLUMNS :: 2 // The menu of the programs has two columns of names.
COLUMN_LEAST :: 120 // The title of the menu fits.

// Layout: the widths of the texts of the bar, measured in the font that
// draws them: the names of the bar are in the interface font; with no
// interface font, in the font of the cells (docs/DESIGN.md, section 5). The
// place of each button and of each line of a menu comes from it, so a
// press lands on the entry that the eye sees. The compositor measures it
// once, and again when the font changes; it writes in its log which font
// it is, and the kernel tool measures the same layout from the same cache.
Layout :: struct {
	label_width:         int, // LABEL.
	windows_label_width: int, // WINDOWS_LABEL.
	longest_name_width:  int, // The widest of the names and of LABEL.
}

// text_width_in gives the width of a text in pixels in the regular weight
// of a glyph cache of the interface font at scale 1, rounded up: the
// measure of src/library/support/interface (text_measured_width). nil: the font of the
// cells.
text_width_in :: proc "contextless" (cache: ^glyph_cache.Cache, text: string) -> int {
	if cache != nil {
		if spacing, ok := text_shaping.spacing_of(cache, 1); ok {
			width, _ := text_shaping.text_width(&spacing, transmute([]u8)text)
			return int((width + 63) / 64)
		}
	}
	return len(text) * CHARACTER_WIDTH
}

// layout_of measures the texts of the bar in a font: the regular cache of
// the interface font, or nil for the font of the cells.
layout_of :: proc "contextless" (cache: ^glyph_cache.Cache) -> (layout: Layout) {
	layout.label_width = text_width_in(cache, LABEL)
	layout.windows_label_width = text_width_in(cache, WINDOWS_LABEL)
	layout.longest_name_width = layout.label_width
	for name in names {
		layout.longest_name_width = max(layout.longest_name_width, text_width_in(cache, name))
	}
	return layout
}

// The mark of the system at the left of the bar, where the name of the
// system was: the heron at a cell size of 1, 24 by 24 pixels, at the height
// of the buttons. It ends before START.
MARK_X :: 16
MARK_Y :: BUTTON_Y // The top of the mark.
MARK_CELL_SIZE :: 1 // One pixel for each cell of the heron.
MARK_SIZE :: mark.HERON_GRID_SIZE * MARK_CELL_SIZE // The side of the mark: 24 pixels.
#assert(MARK_X + MARK_SIZE <= START && MARK_Y + MARK_SIZE <= HEIGHT)

// rows gives the lines of one column of the menu of the programs.
rows :: proc "contextless" () -> int {
	return (len(names) + COLUMNS - 1) / COLUMNS
}

// button gives the place of the button of the bar that opens the menu of
// the programs: its label and a padding on each side.
button :: proc "contextless" (layout: Layout) -> (x, y, width, height: int) {
	return START, BUTTON_Y, layout.label_width + 2 * PADDING, BUTTON_HEIGHT
}

// column_width gives the width of one column of the menu of the programs:
// the widest name and a padding on each side, on the grid.
column_width :: proc "contextless" (layout: Layout) -> int {
	longest := max(layout.longest_name_width, layout.label_width)
	return max((longest + 2 * PADDING + 7) / 8 * 8, COLUMN_LEAST)
}

// menu gives the place of the menu of the programs, under its button.
menu :: proc "contextless" (layout: Layout) -> (x, y, width, height: int) {
	return START, HEIGHT, COLUMNS * column_width(layout) + 2 * BORDER, TITLE + rows() * LINE_HEIGHT + 2 * BORDER
}

// line gives the place of the line of names[index] in the menu.
line :: proc "contextless" (layout: Layout, index: int) -> (x, y, width, height: int) {
	left, top, _, _ := menu(layout)
	return left + BORDER + index / rows() * column_width(layout), top + BORDER + TITLE + index % rows() * LINE_HEIGHT, column_width(layout), LINE_HEIGHT
}

// line_at gives the index of the line of the menu at a point, or -1.
line_at :: proc "contextless" (layout: Layout, point_x, point_y: int) -> int {
	for _, index in names {
		x, y, width, height := line(layout, index)
		if point_x >= x && point_x < x + width && point_y >= y && point_y < y + height {
			return index
		}
	}
	return -1
}

// button_center gives the middle of the button that opens the menu.
button_center :: proc "contextless" (layout: Layout) -> (center_x, center_y: int) {
	x, y, width, height := button(layout)
	return x + width / 2, y + height / 2
}

// center gives the middle of the line of a program in the menu. ok is
// false if the menu does not have the program.
center :: proc "contextless" (layout: Layout, program: string) -> (center_x, center_y: int, ok: bool) {
	for name, index in names {
		if name == program {
			x, y, width, height := line(layout, index)
			return x + width / 2, y + height / 2, true
		}
	}
	return 0, 0, false
}

// The menu of the windows: one line for each window, with its title. A press
// on a line brings the window to the front.
WINDOWS_LABEL :: "windows"
WINDOWS_GAP :: 8 // Between the two buttons.
// The room of a title in the menu of the windows, in pixels: a title is
// cut to it in the font that draws it. It is the room of the 32 cells of
// the longest title of a window (system.Name) in the font of the cells, so
// the menu has one width in both fonts.
WINDOWS_TITLE_ROOM :: 32 * CHARACTER_WIDTH
// The place of a title in its line: after the square that marks the window
// with the focus.
WINDOWS_TITLE_X :: 24

// windows_button gives the place of the button that opens the menu of the windows.
windows_button :: proc "contextless" (layout: Layout) -> (x, y, width, height: int) {
	left, top, button_width, button_height := button(layout)
	return left + button_width + WINDOWS_GAP, top, layout.windows_label_width + 2 * PADDING, button_height
}

// windows_menu gives the place of the menu of count windows, under its button.
windows_menu :: proc "contextless" (layout: Layout, count: int) -> (x, y, width, height: int) {
	left, _, _, _ := windows_button(layout)
	return left, HEIGHT, WINDOWS_TITLE_ROOM + 2 * PADDING + 2 * BORDER, TITLE + count * LINE_HEIGHT + 2 * BORDER
}

// windows_line gives the place of a line of the menu of the windows.
windows_line :: proc "contextless" (layout: Layout, index: int) -> (x, y, width, height: int) {
	left, top, menu_width, _ := windows_menu(layout, 0)
	return left + BORDER, top + BORDER + TITLE + index * LINE_HEIGHT, menu_width - 2 * BORDER, LINE_HEIGHT
}

// windows_line_at gives the index of the line of the menu of count windows
// at a point, or -1.
windows_line_at :: proc "contextless" (layout: Layout, count, point_x, point_y: int) -> int {
	for index in 0 ..< count {
		x, y, width, height := windows_line(layout, index)
		if point_x >= x && point_x < x + width && point_y >= y && point_y < y + height {
			return index
		}
	}
	return -1
}

// windows_button_center gives the middle of the button of the menu of the windows.
windows_button_center :: proc "contextless" (layout: Layout) -> (center_x, center_y: int) {
	x, y, width, height := windows_button(layout)
	return x + width / 2, y + height / 2
}

// windows_line_center gives the middle of a line of the menu of the windows.
windows_line_center :: proc "contextless" (layout: Layout, index: int) -> (center_x, center_y: int) {
	x, y, width, height := windows_line(layout, index)
	return x + width / 2, y + height / 2
}

// A button of the bar.
Bar_Button :: enum u8 {
	None, // No button: the pointer is elsewhere.
	Programs, // The button that opens the menu of the programs.
	Windows, // The button that opens the menu of the windows.
}

// button_at gives the button of the bar at a point.
button_at :: proc "contextless" (layout: Layout, point_x, point_y: int) -> Bar_Button {
	inside :: proc "contextless" (point_x, point_y, x, y, width, height: int) -> bool {
		return point_x >= x && point_x < x + width && point_y >= y && point_y < y + height
	}
	if x, y, width, height := button(layout); inside(point_x, point_y, x, y, width, height) {
		return .Programs
	}
	if x, y, width, height := windows_button(layout); inside(point_x, point_y, x, y, width, height) {
		return .Windows
	}
	return .None
}
