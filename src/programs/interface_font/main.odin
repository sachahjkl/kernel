// The interface font (docs/FONTS.md, section 12): B612 Regular and Bold,
// placed by src/library/support/text_shaping and drawn by graphics.text_proportional.
// It shows a paragraph, three pairs with and without their adjustment, one
// word at the three positions of a pixel, enlarged, the digits in columns,
// and the time of one line.
//
// The two glyph caches are resources of the boot image that the root
// service maps read-only at their fixed ranges (display.interface_font_open
// validates them). The labels of the window are the text of the system.
//
// **What it is for.** It shows the [interface font](term:interface-font)
// as the system draws it: [text shaping](term:text-shaping) with the
// [pair adjustments](term:pair-adjustment) of the font, glyphs at a
// [subpixel position](term:subpixel-position), and the
// [glyph caches](term:glyph-cache) that the build computes once. A reader
// compares a pair with and without its adjustment, and one word at three
// positions of a pixel.
//
// **What a reader sees.** Start it from the menu of the programs, or with
// `start("interface_font")` in the console. The log gets the time of
// shaping and of drawing one line, then `interface_font: ok, B612 Regular
// and Bold, <count> and <count> pairs, ...`. With no valid glyph cache in
// the boot image, it writes `interface_font: the boot image gives no valid
// cache of the interface font`.
//
// **Its grants**: none. The root service maps the glyph caches into each
// program that it starts.
package interface_font

import "modus:contract/glyph_cache"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/system"
import "modus:support/text_shaping"

WIDTH :: 800
HEIGHT :: 640

regular_cache, bold_cache: glyph_cache.Cache
// The spacing of the regular weight at scale 1 and at scale 3, the bold
// weight at scale 1, and the regular weight at scale 3 with no pair.
regular_spacing, regular_spacing_large, bold_spacing, no_pair_spacing_large: text_shaping.Spacing

// The most characters of one line of this window.
LINE_LIMIT :: 96

PARAGRAPH := [?]string {
	"B612 was drawn for the screens of a cockpit: small text, read at a glance.",
	"Each character has its own advance, and pairs such as To, LT and Ty come closer.",
	"The interface takes it for titles, labels, buttons, menus and the bar.",
}
BOLD_LINE :: "Settings   Palette   Notes   Console   Monitor"
PAIRS :: "To  LT  Ty"
ENLARGED_WORD :: "Rag To"
ENLARGED :: 4
ENLARGED_COLUMNS :: 48 // The columns of the small canvas that are enlarged: the word and its margins.
// The places of the enlarged word in a pixel, in 1/64: 0, a third, two thirds.
ENLARGED_FRACTIONS := [3]i64{0, 21, 43}
NUMBERS := [?]string{"7", "42", "1 024", "65 536", "4 294 967 296", "100 000"}

// One line of B612 drawn into a canvas of its own: the enlarged word, and
// the measure of the time of one line.
SMALL_WIDTH :: 96
small_pixels: [SMALL_WIDTH * 16]graphics.Color
MEASURE_WIDTH :: 720
measure_pixels: [MEASURE_WIDTH * 16]graphics.Color
shaping_time, drawing_time: u64

records_now, records_before: [128]interface.Draw_Record
text_now, text_before: [4096]u8
drawing: interface.Window_Drawing

// line_draw places a text and draws it, its origin at the whole pixel x and
// the top of its line at y; it gives the width in 1/64 of a pixel.
line_draw :: proc "contextless" (canvas: graphics.Canvas, place: i64, y: int, text: string, spacing: ^text_shaping.Spacing, cache: ^glyph_cache.Cache, scale: int, color: graphics.Color) -> (width: i64) {
	placed: [LINE_LIMIT]text_shaping.Placed_Glyph
	count := min(len(text), LINE_LIMIT)
	_, width, _ = text_shaping.shape(spacing, transmute([]u8)(text[:count]), placed[:count])
	graphics.text_proportional(canvas, place, y, placed[:count], cache, scale, color)
	return width
}

// line_width gives the width of a text in 1/64 of a pixel.
line_width :: proc "contextless" (text: string, spacing: ^text_shaping.Spacing) -> i64 {
	width, _ := text_shaping.text_width(spacing, transmute([]u8)(text[:min(len(text), LINE_LIMIT)]))
	return width
}

// The rows of the window, from the top of the content of its card.
PARAGRAPH_TOP :: 24
PAIRS_TOP :: 152
ENLARGED_TOP :: 256
DIGITS_TOP :: 392
TIME_TOP :: 536

draw :: proc "contextless" (window: ^display.Window) {
	interface.draw_whole_window_next(&drawing)
	frame := interface.window_frame_begin(&drawing)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	content := interface.card(&frame, {8, 8, WIDTH - 16, HEIGHT - 16}, "THE INTERFACE FONT", "B612 Regular and Bold: proportional, with its pairs, at three positions in a pixel", graphics.COLOR_MACHINE)
	labels := [?]struct {
		top:  int,
		text: string,
	} {
		{0, "a paragraph in B612 Regular, a line in B612 Bold, at scale 1"},
		{PAIRS_TOP - 24, "three pairs at scale 3: with the adjustment of the font, then without"},
		{ENLARGED_TOP - 24, "one word at 0, 1/3 and 2/3 of a pixel, enlarged 4 times"},
		{DIGITS_TOP - 24, "digits in columns: each digit has the same advance, so a column aligns"},
	}
	for label in labels {
		interface.draw_text(frame.table, content.x, content.y + label.top, label.text, graphics.COLOR_DIM)
	}
	timing: interface.Text_Builder
	interface.text_put(&timing, "one line of ")
	interface.text_put_number(&timing, u64(len(PARAGRAPH[1])))
	interface.text_put(&timing, " characters: shaping ")
	interface.text_put_number(&timing, shaping_time)
	interface.text_put(&timing, " ns, drawing ")
	interface.text_put_number(&timing, drawing_time)
	interface.text_put(&timing, " ns; caches of ")
	interface.text_put_number(&timing, regular_cache.header.file_size)
	interface.text_put(&timing, " and ")
	interface.text_put_number(&timing, bold_cache.header.file_size)
	interface.text_put(&timing, " bytes, from the boot image")
	interface.draw_text(frame.table, content.x, content.y + TIME_TOP, interface.text_of(&timing), graphics.COLOR_DIM)
	interface.window_frame_end(&drawing, &frame, window)

	canvas := window.canvas
	x := i64(content.x) * 64
	// The paragraph and the bold line.
	for line, index in PARAGRAPH {
		line_draw(canvas, x, content.y + PARAGRAPH_TOP + index * 20, line, &regular_spacing, &regular_cache, 1, graphics.COLOR_TEXT)
	}
	line_draw(canvas, x, content.y + PARAGRAPH_TOP + len(PARAGRAPH) * 20 + 8, BOLD_LINE, &bold_spacing, &bold_cache, 1, graphics.COLOR_TEXT)
	// The pairs at scale 3, with and without their adjustment.
	line_draw(canvas, x, content.y + PAIRS_TOP, PAIRS, &regular_spacing_large, &regular_cache, 3, graphics.COLOR_TEXT)
	line_draw(canvas, x + 360 * 64, content.y + PAIRS_TOP, PAIRS, &no_pair_spacing_large, &regular_cache, 3, graphics.COLOR_DIM)
	// One word at the three positions, each pixel enlarged.
	small := graphics.Canvas{pixels = raw_data(small_pixels[:]), width = SMALL_WIDTH, height = 16, stride = SMALL_WIDTH}
	for fraction, index in ENLARGED_FRACTIONS {
		graphics.clear(small, graphics.COLOR_CARD_BOTTOM)
		line_draw(small, 2 * 64 + fraction, 0, ENLARGED_WORD, &regular_spacing, &regular_cache, 1, graphics.COLOR_TEXT)
		left := content.x + index * (ENLARGED_COLUMNS * ENLARGED + 24)
		for row in 0 ..< 16 {
			for column in 0 ..< ENLARGED_COLUMNS {
				graphics.fill(canvas, left + column * ENLARGED, content.y + ENLARGED_TOP + row * ENLARGED, ENLARGED, ENLARGED, small_pixels[row * SMALL_WIDTH + column])
			}
		}
	}
	// The digits: each number at the right of its column, in each weight.
	column_right := i64(content.x + 200) * 64
	bold_right := i64(content.x + 440) * 64
	for number, index in NUMBERS {
		y := content.y + DIGITS_TOP + index * 20
		line_draw(canvas, column_right - line_width(number, &regular_spacing), y, number, &regular_spacing, &regular_cache, 1, graphics.COLOR_TEXT)
		line_draw(canvas, bold_right - line_width(number, &bold_spacing), y, number, &bold_spacing, &bold_cache, 1, graphics.COLOR_PROGRAM)
	}
	display.present(window)
}

// measure gives the least time of one line in batches, so that a batch
// that the host stops in its middle does not count: the shaping, then the
// shaping and the drawing, into a canvas that is not the window.
measure :: proc "contextless" () {
	BATCHES :: 50
	canvas := graphics.Canvas{pixels = raw_data(measure_pixels[:]), width = MEASURE_WIDTH, height = 16, stride = MEASURE_WIDTH}
	text := transmute([]u8)(PARAGRAPH[1])
	placed: [LINE_LIMIT]text_shaping.Placed_Glyph
	shaping_time, drawing_time = max(u64), max(u64)
	for _ in 0 ..< BATCHES {
		graphics.clear(canvas, graphics.COLOR_CARD_BOTTOM)
		start := system.nanoseconds()
		count, _, _ := text_shaping.shape(&regular_spacing, text, placed[:])
		shaped := system.nanoseconds()
		graphics.text_proportional(canvas, 0, 0, placed[:count], &regular_cache, 1, graphics.COLOR_TEXT)
		drawn := system.nanoseconds()
		shaping_time = min(shaping_time, shaped - start)
		drawing_time = min(drawing_time, drawn - shaped)
	}
}

// entry opens the window, opens the glyph caches of the interface font,
// measures one line, writes the lines on the log, then draws the window at
// each event until the program is stopped. With no window, it stops with
// the code 1.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "interface_font")
	if !ok {
		system.stop(1)
	}
	font, font_ok := display.interface_font_open(ctx)
	if !font_ok {
		system.log("interface_font: the boot image gives no valid cache of the interface font")
		system.stop(1)
	}
	regular_cache, bold_cache = font.regular, font.bold
	spacing_ok: [3]bool
	regular_spacing, spacing_ok[0] = text_shaping.spacing_of(&regular_cache, 1)
	regular_spacing_large, spacing_ok[1] = text_shaping.spacing_of(&regular_cache, 3)
	bold_spacing, spacing_ok[2] = text_shaping.spacing_of(&bold_cache, 1)
	if !spacing_ok[0] || !spacing_ok[1] || !spacing_ok[2] {
		system.stop(1)
	}
	no_pair_spacing_large = {advances = regular_spacing_large.advances}
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	measure()
	system.log("interface_font: one line of ", u64(len(PARAGRAPH[1])), " characters in B612 at scale 1 (the least of 50 batches): shaping ", shaping_time, " ns, drawing ", drawing_time, " ns; the caches of ", regular_cache.header.file_size, " and ", bold_cache.header.file_size, " bytes, from the boot image")
	draw(&window)
	system.log("interface_font: ok, B612 Regular and Bold, ", u64(regular_cache.header.pair_count), " and ", u64(bold_cache.header.pair_count), " pairs")
	for {
		display.wait(&window)
		if interface.window_events(&drawing, &window) {
			draw(&window)
		}
	}
}
