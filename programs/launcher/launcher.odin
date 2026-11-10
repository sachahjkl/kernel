// The launcher of the bar: the names of the programs and the place of
// each button. The compositor draws the buttons; the kernel tool clicks
// them in the machine test. The two read this one table.
package launcher

@(rodata)
names := [?]string{"console", "monitor", "plasma", "life", "paint", "fault", "temple", "rings", "threads", "workers", "rights", "budget", "processors"}

CHARACTER_WIDTH :: 8 // The font of the system.
START :: 76 // After the name of the system.
PADDING :: 6
GAP :: 4
BAR_HEIGHT :: 28

// button gives the left side and the width of the button of names[index].
button :: proc "contextless" (index: int) -> (x, width: int) {
	x = START
	for name in names[:index] {
		x += len(name) * CHARACTER_WIDTH + 2 * PADDING + GAP
	}
	return x, len(names[index]) * CHARACTER_WIDTH + 2 * PADDING
}

// center gives the middle of the button of a program. ok is false if the
// launcher does not have the program.
center :: proc "contextless" (program: string) -> (x, y: int, ok: bool) {
	for name, index in names {
		if name == program {
			left, width := button(index)
			return left + width / 2, BAR_HEIGHT / 2, true
		}
	}
	return 0, 0, false
}
