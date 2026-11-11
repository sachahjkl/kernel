// The prototype of a vector font beside the font of the system
// (docs/INTERFACE.md, section 9). Spleen 8x16 stays the font of the system
// (owner, 2026-11-10): this window is a picture for the owner to judge.
//
// One text in Spleen 8x16, then in DejaVu Sans Mono (FONT_LICENSE) drawn
// from its outlines: in grayscale with each glyph at its exact place (a
// subpixel position), in grayscale with each glyph on a whole pixel, with
// a coverage for each color stripe, and at two larger sizes. The log has
// the time of one glyph in each way.
package vector_glyphs

import "support:display"
import "support:graphics"
import "support:interface"
import "support:system"
import "support:vector_font"

font_bytes := #load("DejaVuSansMono.ttf")

WIDTH :: 816
HEIGHT :: 600
SAMPLE :: "The kernel draws text: Rb 0123456789 {fill} gi"

font: vector_font.Font_File
points: [512]vector_font.Outline_Point
contours: [64]int
// The memory of one glyph: accumulations and coverage, three times wider
// with color stripes.
CELL_CAPACITY :: 3 * 64 * 64
cells: [CELL_CAPACITY]f32
coverage: [CELL_CAPACITY]u8
stripes: [CELL_CAPACITY]u8

Way :: enum {
	Grayscale, // Each glyph at its exact place.
	Whole_Pixel, // Each glyph on a whole pixel.
	Color_Stripes, // A coverage for each third of a pixel, filtered.
}

// glyph_draw draws one glyph at (x, y), the top of its line, in a size of
// pixels for one em, and gives the advance in pixels.
glyph_draw :: proc "contextless" (canvas: graphics.Canvas, x: f32, y: int, character: rune, size: f32, way: Way, color: graphics.Color) -> f32 {
	glyph, found := vector_font.glyph_of(&font, character)
	outline := vector_font.Outline{points = points[:], contour_ends = contours[:]}
	if found != .None || vector_font.glyph_outline(&font, glyph, &outline) != .None {
		return size * 0.6
	}
	scale := size / f32(font.units_per_em)
	advance := f32(outline.advance) * scale
	start := way == .Whole_Pixel ? f32(int(x + 0.5)) : x
	left := int(start) - 1
	fraction := start - f32(left)
	height := int(f32(font.ascender - font.descender) * scale) + 2
	width := int(advance) + 4
	across := way == .Color_Stripes ? 3 : 1
	if width * across * height > CELL_CAPACITY {
		return advance
	}
	target := vector_font.Coverage{cells = cells[:], coverage = coverage[:], width = width * across, height = height}
	placement := vector_font.Placement{scale = scale * f32(across), scale_y = scale, origin_x = fraction * f32(across), origin_y = f32(font.ascender) * scale}
	vector_font.outline_add(&target, &outline, placement)
	vector_font.coverage_finish(&target)
	if way == .Color_Stripes {
		vector_font.stripes_filter(coverage[:], stripes[:], width, height)
	}
	for row in 0 ..< height {
		for column in 0 ..< width {
			pixel_x, pixel_y := left + column, y + row
			if pixel_x < 0 || pixel_y < 0 || pixel_x >= canvas.width || pixel_y >= canvas.height {
				continue
			}
			under := canvas.pixels[pixel_y * canvas.stride + pixel_x]
			result: graphics.Color
			for channel in 0 ..< 3 {
				shift := uint(16 - 8 * channel)
				level := way == .Color_Stripes ? u32(stripes[row * width * 3 + column * 3 + channel]) : u32(coverage[row * width + column])
				back := under >> shift & 0xFF
				front := color >> shift & 0xFF
				result |= (back * (255 - level) + front * level) / 255 << shift
			}
			canvas.pixels[pixel_y * canvas.stride + pixel_x] = result
		}
	}
	return advance
}

// line_draw draws the sample in one way and one size, and gives the time of
// one glyph in nanoseconds.
line_draw :: proc "contextless" (canvas: graphics.Canvas, x, y: int, size: f32, way: Way, text: string = SAMPLE) -> u64 {
	start := system.nanoseconds()
	at := f32(x)
	for index in 0 ..< len(text) {
		at += glyph_draw(canvas, at, y, rune(text[index]), size, way, graphics.COLOR_TEXT)
	}
	return (system.nanoseconds() - start) / u64(len(text))
}

records_now, records_before: [256]interface.Draw_Record
text_now, text_before: [8192]u8
drawing: interface.Window_Drawing

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "vector_glyphs")
	if !ok {
		system.stop(1)
	}
	problem: vector_font.Font_Problem
	font, problem = vector_font.font_open(font_bytes)
	if problem != .None {
		system.log("vector_glyphs: the font is refused: problem ", u64(problem))
		system.stop(1)
	}
	// The frame of the window, with the interface package.
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	frame := interface.window_frame_begin(&drawing, &window)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	content := interface.card(&frame, {8, 8, WIDTH - 16, HEIGHT - 16}, "A VECTOR FONT, PROTOTYPE", "DejaVu Sans Mono, glyf outlines; Spleen 8x16 stays", graphics.COLOR_MACHINE)
	Row :: struct {
		name:   string,
		y:      int,
		size:   f32,
		way:    Way,
		spleen: bool,
	}
	rows := [?]Row {
		{"Spleen 8x16, the font of the system", 0, 0, .Grayscale, true},
		{"13 pixel_x, grayscale, exact place", 48, 13.3, .Grayscale, false},
		{"13 pixel_x, grayscale, whole pixel", 96, 13.3, .Whole_Pixel, false},
		{"13 pixel_x, color stripes", 144, 13.3, .Color_Stripes, false},
		{"16 pixel_x, grayscale", 192, 16, .Grayscale, false},
		{"32 pixel_x, grayscale", 248, 32, .Grayscale, false},
	}
	for row in rows {
		interface.draw_text(frame.table, content.x, content.y + row.y, row.name, graphics.COLOR_DIM)
		if row.spleen {
			interface.draw_text(frame.table, content.x, content.y + row.y + 20, SAMPLE, graphics.COLOR_TEXT)
		}
	}
	interface.draw_text(frame.table, content.x, content.y + 320, "a glyph at 13 pixel_x, enlarged 8 times: grayscale, then color stripes", graphics.COLOR_DIM)
	interface.window_frame_end(&drawing, &frame, &window)

	// The vector rows, over the frame.
	canvas := window.canvas
	times: [Way]u64
	for row in rows[1:] {
		time := line_draw(canvas, content.x, content.y + row.y + 20, row.size, row.way, row.size > 20 ? "Rb 0123 {fill} gi" : SAMPLE)
		if row.size < 14 {
			times[row.way] = time
		}
	}
	// One glyph enlarged: each pixel as a square of 8, so that the coverage shows.
	ENLARGED :: 8
	for way, index in ([2]Way{.Grayscale, .Color_Stripes}) {
		small: [24 * 24]graphics.Color
		view := graphics.Canvas{pixels = raw_data(small[:]), width = 24, height = 24, stride = 24}
		graphics.clear(view, graphics.COLOR_CARD_BOTTOM)
		glyph_draw(view, 4.3, 2, 'g', 13.3, way, graphics.COLOR_TEXT)
		for y in 0 ..< 24 {
			for x in 0 ..< 24 {
				graphics.fill(canvas, content.x + index * 216 + x * ENLARGED, content.y + 344 + y * ENLARGED, ENLARGED, ENLARGED, small[y * 24 + x])
			}
		}
	}
	// The time of a glyph of Spleen: a copy of the bits of the font.
	scratch: [16 * 16]graphics.Color // The measure draws here, not on the window.
	scratch_canvas := graphics.Canvas{pixels = raw_data(scratch[:]), width = 16, height = 16, stride = 16}
	spleen_start := system.nanoseconds()
	for _ in 0 ..< 1000 {
		graphics.character(scratch_canvas, 0, 0, 'g', graphics.COLOR_TEXT)
	}
	spleen := (system.nanoseconds() - spleen_start) / 1000
	display.present(&window)
	system.log("vector_glyphs: one glyph: Spleen 8x16 ", spleen, " ns; 13 pixel_x from its outline: grayscale ", times[.Grayscale], " ns, whole pixel ", times[.Whole_Pixel], " ns, color stripes ", times[.Color_Stripes], " ns")
	system.log("vector_glyphs: ok, ", u64(font.glyph_count), " glyphs in the font, ", u64(len(font_bytes)), " bytes")
	for {
		display.wait(&window)
		interface.window_events(&drawing, &window)
	}
}
