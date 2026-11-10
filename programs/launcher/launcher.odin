// The launcher: the menu of the bar that starts the programs. This table
// holds the names of the programs and the place of the button and of each
// line of the menu. The compositor draws them; the kernel tool clicks them
// in the machine test. The two read this one table.
package launcher

@(rodata)
names := [?]string{"boot", "pages", "log", "console", "monitor", "plasma", "life", "paint", "fault", "temple", "rings", "threads", "workers", "rights", "budget", "processors", "flow", "crowd", "clock", "terminal"}

LABEL :: "programs" // The text of the button that opens the menu.
CHARACTER_WIDTH :: 8 // The font of the system.
START :: 76 // After the name of the system.
PADDING :: 8
BAR_HEIGHT :: 28
LINE_HEIGHT :: 22 // One line of the menu.
BORDER :: 1

// button gives the place of the button of the bar that opens the menu.
button :: proc "contextless" () -> (x, y, width, height: int) {
	return START, 3, len(LABEL) * CHARACTER_WIDTH + 2 * PADDING, BAR_HEIGHT - 6
}

// menu gives the place of the menu, under the button.
menu :: proc "contextless" () -> (x, y, width, height: int) {
	longest := len(LABEL)
	for name in names {
		longest = max(longest, len(name))
	}
	return START, BAR_HEIGHT, longest * CHARACTER_WIDTH + 2 * PADDING + 2 * BORDER, len(names) * LINE_HEIGHT + 2 * BORDER
}

// line gives the place of the line of names[index] in the menu.
line :: proc "contextless" (index: int) -> (x, y, width, height: int) {
	left, top, menu_width, _ := menu()
	return left + BORDER, top + BORDER + index * LINE_HEIGHT, menu_width - 2 * BORDER, LINE_HEIGHT
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
// false if the launcher does not have the program.
center :: proc "contextless" (program: string) -> (center_x, center_y: int, ok: bool) {
	for name, index in names {
		if name == program {
			x, y, width, height := line(index)
			return x + width / 2, y + height / 2, true
		}
	}
	return 0, 0, false
}
