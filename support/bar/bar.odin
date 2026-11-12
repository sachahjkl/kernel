// The bar of the desktop: the names of the programs, and the place of each
// button of the bar and of each line of its two menus, the menu of the
// programs and the menu of the windows. The compositor draws them; the
// kernel tool clicks them in the machine test. The two read this one table.
// The launcher (launcher.odin) lists the same names.
package bar

import "support:mark"

@(rodata)
names := [?]string{"boot", "pages", "log", "console", "monitor", "plasma", "life", "paint", "fault", "temple", "rings", "threads", "workers", "rights", "origin", "budget", "limits", "processors", "flow", "crowd", "clock", "randomness", "flood", "tally", "manual", "frames", "disk", "notes", "imports", "net", "remote", "server", "inspect", "locks", "errors", "scheduler", "interface_elements", "vector_glyphs", "interface_font", "pointers", "settings", "tables", "interface_through_module", "address_space", "cryptography_vectors", "quic_echo"}

// The bar is on the grid of docs/DESIGN.md: 8 pixels.
LABEL :: "programs" // The text of the button that opens the menu of the programs.
CHARACTER_WIDTH :: 8 // The font of the system.
START :: 80 // After the mark of the system.
PADDING :: 8
HEIGHT :: 32 // The height of the bar.
BUTTON_Y :: 4
BUTTON_HEIGHT :: 24
LINE_HEIGHT :: 24 // One line of a menu.
BORDER :: 1
TITLE :: 40 // The title of a menu, as the title of a card.
COLUMNS :: 2 // The menu of the programs has two columns of names.
COLUMN_LEAST :: 120 // The title of the menu fits.

// The mark of the system at the left of the bar, where the name of the
// system was: the heron at a cell size of 1, 24 by 24 pixels, at the height
// of the buttons. It ends before START.
MARK_X :: 16
MARK_Y :: BUTTON_Y
MARK_CELL_SIZE :: 1
MARK_SIZE :: mark.HERON_GRID_SIZE * MARK_CELL_SIZE
#assert(MARK_X + MARK_SIZE <= START && MARK_Y + MARK_SIZE <= HEIGHT)

// rows gives the lines of one column of the menu of the programs.
rows :: proc "contextless" () -> int {
	return (len(names) + COLUMNS - 1) / COLUMNS
}

// button gives the place of the button of the bar that opens the menu of the programs.
button :: proc "contextless" () -> (x, y, width, height: int) {
	return START, BUTTON_Y, len(LABEL) * CHARACTER_WIDTH + 2 * PADDING, BUTTON_HEIGHT
}

// column_width gives the width of one column of the menu of the programs.
column_width :: proc "contextless" () -> int {
	longest := len(LABEL)
	for name in names {
		longest = max(longest, len(name))
	}
	return max((longest * CHARACTER_WIDTH + 2 * PADDING + 7) / 8 * 8, COLUMN_LEAST)
}

// menu gives the place of the menu of the programs, under its button.
menu :: proc "contextless" () -> (x, y, width, height: int) {
	return START, HEIGHT, COLUMNS * column_width() + 2 * BORDER, TITLE + rows() * LINE_HEIGHT + 2 * BORDER
}

// line gives the place of the line of names[index] in the menu.
line :: proc "contextless" (index: int) -> (x, y, width, height: int) {
	left, top, _, _ := menu()
	return left + BORDER + index / rows() * column_width(), top + BORDER + TITLE + index % rows() * LINE_HEIGHT, column_width(), LINE_HEIGHT
}

// line_at gives the index of the line of the menu at a point, or -1.
line_at :: proc "contextless" (point_x, point_y: int) -> int {
	for _, index in names {
		x, y, width, height := line(index)
		if point_x >= x && point_x < x + width && point_y >= y && point_y < y + height {
			return index
		}
	}
	return -1
}

// button_center gives the middle of the button that opens the menu.
button_center :: proc "contextless" () -> (center_x, center_y: int) {
	x, y, width, height := button()
	return x + width / 2, y + height / 2
}

// center gives the middle of the line of a program in the menu. ok is
// false if the menu does not have the program.
center :: proc "contextless" (program: string) -> (center_x, center_y: int, ok: bool) {
	for name, index in names {
		if name == program {
			x, y, width, height := line(index)
			return x + width / 2, y + height / 2, true
		}
	}
	return 0, 0, false
}

// The menu of the windows: one line for each window, with its title. A press
// on a line brings the window to the front.
WINDOWS_LABEL :: "windows"
WINDOWS_GAP :: 8 // Between the two buttons.
WINDOWS_CHARACTERS :: 32 // The longest title.

// windows_button gives the place of the button that opens the menu of the windows.
windows_button :: proc "contextless" () -> (x, y, width, height: int) {
	left, top, button_width, button_height := button()
	return left + button_width + WINDOWS_GAP, top, len(WINDOWS_LABEL) * CHARACTER_WIDTH + 2 * PADDING, button_height
}

// windows_menu gives the place of the menu of count windows, under its button.
windows_menu :: proc "contextless" (count: int) -> (x, y, width, height: int) {
	left, _, _, _ := windows_button()
	return left, HEIGHT, WINDOWS_CHARACTERS * CHARACTER_WIDTH + 2 * PADDING + 2 * BORDER, TITLE + count * LINE_HEIGHT + 2 * BORDER
}

// windows_line gives the place of a line of the menu of the windows.
windows_line :: proc "contextless" (index: int) -> (x, y, width, height: int) {
	left, top, menu_width, _ := windows_menu(0)
	return left + BORDER, top + BORDER + TITLE + index * LINE_HEIGHT, menu_width - 2 * BORDER, LINE_HEIGHT
}

// windows_line_at gives the index of the line of the menu of count windows
// at a point, or -1.
windows_line_at :: proc "contextless" (count, point_x, point_y: int) -> int {
	for index in 0 ..< count {
		x, y, width, height := windows_line(index)
		if point_x >= x && point_x < x + width && point_y >= y && point_y < y + height {
			return index
		}
	}
	return -1
}

// windows_button_center gives the middle of the button of the menu of the windows.
windows_button_center :: proc "contextless" () -> (center_x, center_y: int) {
	x, y, width, height := windows_button()
	return x + width / 2, y + height / 2
}

// windows_line_center gives the middle of a line of the menu of the windows.
windows_line_center :: proc "contextless" (index: int) -> (center_x, center_y: int) {
	x, y, width, height := windows_line(index)
	return x + width / 2, y + height / 2
}
