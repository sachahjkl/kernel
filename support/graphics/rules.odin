// The design rules (docs/DESIGN.md) as one table of constants: the grid,
// the surfaces, the colors of the concepts and the colors of the desktop.
// The boot display, the compositor and the programs read this one table.
package graphics

// The grid (DESIGN.md, section 6).
GRID :: 8 // A position and a size are multiples of GRID, or of GRID / 2 inside a form.
LINE_HEIGHT :: 16 // One line of text.
CARD_GAP :: 8 // The space between two cards.
CARD_MARGIN :: 16 // The margin inside a card.
CARD_TITLE :: 40 // The height of the title of a card.

// The surfaces (section 3).
COLOR_BACKGROUND :: 0x0B1018 // Under all cards.
COLOR_POINT :: 0x18212D // The grid of points on the background.
POINT_SIZE :: 2
POINT_STEP :: 24
COLOR_CARD_TOP :: 0x17212E // A card goes from this color at the top...
COLOR_CARD_BOTTOM :: 0x111822 // ...to this color at the bottom.
COLOR_TRACK :: 0x1C2633 // The empty part of a bar, a band or a tube.

// The colors of the concepts (section 4). One color is one concept.
COLOR_FIRMWARE :: 0x8E7CC3
COLOR_BOOT_PROGRAM :: 0xE0A040 // Also the state "starts".
COLOR_KERNEL :: 0x4A9CF0
COLOR_PROGRAM :: 0x58D878 // Also the state "runs", and an expected answer.
COLOR_MEMORY :: 0x38C0B0
COLOR_MACHINE :: 0xD070B0
COLOR_FAILED :: 0xF06060
COLOR_NOT_USABLE :: 0x4A5563
COLOR_TEXT :: 0xDCE4EC
COLOR_DIM :: 0x7C8A99

// The desktop (section 9). The title bar of the window that has the focus
// goes from COLOR_TITLE at the left to COLOR_TITLE_END at the right. The
// title bar of another window goes from COLOR_TITLE_QUIET to
// COLOR_TITLE_QUIET_END.
COLOR_TITLE :: 0x3F7CC4 // The blue of the title bar before the rules.
COLOR_TITLE_END :: 0x162C45 // graphics.shade(COLOR_TITLE, 36).
COLOR_TITLE_QUIET :: 0x2A3442
COLOR_TITLE_QUIET_END :: 0x161D27
COLOR_BLACK :: 0x000000
COLOR_WHITE :: 0xFFFFFF

// mix gives a color between two colors: level 0 is the first, 255 the second.
mix :: proc "contextless" (first, second: Color, level: u32) -> Color {
	part :: proc "contextless" (a, b, level: u32) -> u32 {
		return (a * (255 - level) + b * level) / 255
	}
	return rgb(part(first >> 16 & 0xFF, second >> 16 & 0xFF, level), part(first >> 8 & 0xFF, second >> 8 & 0xFF, level), part(first & 0xFF, second & 0xFF, level))
}

// shade gives a color nearer to black (percent under 100) or nearer to
// white (percent from 100 to 200).
shade :: proc "contextless" (color: Color, percent: u32) -> Color {
	return percent <= 100 ? mix(COLOR_BLACK, color, percent * 255 / 100) : mix(color, COLOR_WHITE, (min(percent, 200) - 100) * 255 / 100)
}

// block draws a rectangle whose color goes from top, on its first line, to
// bottom, on its last line: the sign of depth of the rules.
block :: proc "contextless" (canvas: Canvas, x, y, width, height: int, top, bottom: Color) {
	for row in 0 ..< height {
		fill(canvas, x, y + row, width, 1, mix(top, bottom, u32(row * 255 / max(height - 1, 1))))
	}
}

// gradient puts in row the colors of the columns first ..< first + len(row)
// of a line of total columns, whose color goes from start, at column 0, to
// end, at column total - 1. Each channel steps by a fixed-point number: no
// division for each pixel.
gradient :: proc "contextless" (row: []Color, start, end: Color, total, first: int) {
	steps := i64(max(total - 1, 1))
	value, step: [3]i64
	for channel in 0 ..< 3 {
		shift := uint(16 - 8 * channel)
		from, to := i64(start >> shift & 0xFF), i64(end >> shift & 0xFF)
		step[channel] = (to - from) * 65536 / steps
		value[channel] = from * 65536 + step[channel] * i64(first) + 32768
	}
	for &color in row {
		color = rgb(u32(value[0] >> 16), u32(value[1] >> 16), u32(value[2] >> 16))
		value += step
	}
}
