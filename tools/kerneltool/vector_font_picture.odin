package kerneltool

import "core:fmt"
import "core:os"
import "support:graphics"

// The picture of the choice of the font (docs/FONTS.md, "The font file"):
// the same lines of the system in each candidate and in Spleen, at the
// scales 1, 2 and 3, then one word of each enlarged 5 times so that the
// pixels and the color stripes show. support/graphics draws it, as in the
// system: the same glyph cache, the same blend.

CANDIDATE_LINES := [?]string {
	"> print(monitor.programs())   31 programs, 4 processors, 1 204 pages",
	"compositor     12.4 ms    2 418 pages   runs   0x4F3A..9C21",
	"KERNEL ENTRIES  Boot_Report.stages   ok: {fill} [rings] gi Rb 0O 1lI",
}

PICTURE_WIDTH :: 1296
BLOCK_WIDTH :: 640
BLOCK_HEIGHT :: 216
CROP_SCALE :: 5
CROP_TEXT :: "Rag{0}%"

Picture_Font :: struct {
	label:    string,
	cache:    []u8, // nil: Spleen.
	grid_fit: bool,
}

candidates_picture_write :: proc() -> bool {
	fonts := make([dynamic]Picture_Font, context.temp_allocator)
	append(&fonts, Picture_Font{label = "Spleen 8x16 (bitmap, the fallback)"})
	for candidate in vector_font_candidates {
		path := join(VECTOR_FONT_FOLDER, "/", candidate.name, ".ttf")
		bytes := read_file(path) or_return
		cache := glyph_cache_of(bytes, candidate.name, true) or_return
		label := fmt.tprintf("%s%s", candidate.family, candidate.name == DEFAULT_VECTOR_FONT ? " (default)" : "")
		append(&fonts, Picture_Font{label = label, cache = cache, grid_fit = true})
		if candidate.name == DEFAULT_VECTOR_FONT {
			no_fit := glyph_cache_of(bytes, candidate.name, false) or_return
			append(&fonts, Picture_Font{label = fmt.tprintf("%s, no grid fit", candidate.family), cache = no_fit})
		}
	}
	rows := (len(fonts) + 1) / 2
	crop_rows := (len(fonts) + 3) / 4
	crop_height := 16 * CROP_SCALE + 24
	height := 8 + rows * BLOCK_HEIGHT + crop_rows * crop_height + 8
	pixels := make([]graphics.Color, PICTURE_WIDTH * height, context.temp_allocator)
	canvas := graphics.Canvas{pixels = raw_data(pixels), width = PICTURE_WIDTH, height = height, stride = PICTURE_WIDTH}
	graphics.clear(canvas, graphics.COLOR_BACKGROUND)
	saved := graphics.text_state
	defer graphics.text_state = saved
	for font, index in fonts {
		picture_font_use(font)
		x := 8 + (index % 2) * (BLOCK_WIDTH + 8)
		y := 8 + (index / 2) * BLOCK_HEIGHT
		graphics.block(canvas, x, y, BLOCK_WIDTH, BLOCK_HEIGHT - 8, graphics.COLOR_CARD_TOP, graphics.COLOR_CARD_BOTTOM)
		graphics.fill(canvas, x + 16, y + 12, 4, 16, graphics.COLOR_MACHINE)
		graphics.text(canvas, x + 28, y + 12, font.label, graphics.COLOR_MACHINE)
		line_y := y + 40
		for line, line_index in CANDIDATE_LINES {
			color := graphics.Color(line_index == 2 ? graphics.COLOR_KERNEL : graphics.COLOR_TEXT)
			graphics.text(canvas, x + 16, line_y, line, color)
			line_y += 16
		}
		graphics.text_scaled(canvas, x + 16, line_y + 8, "EEVDF fair 1.5x", graphics.COLOR_PROGRAM, 2)
		graphics.text_scaled(canvas, x + 16, line_y + 48, "12 345", graphics.COLOR_TEXT, 3)
		graphics.text(canvas, x + 176, line_y + 72, "wakes in one second", graphics.COLOR_DIM)
	}
	// The crops: one word at scale 1, each pixel as a square of CROP_SCALE.
	crop_top := 8 + rows * BLOCK_HEIGHT
	for font, index in fonts {
		picture_font_use(font)
		small: [8 * len(CROP_TEXT) * 16]graphics.Color
		small_canvas := graphics.Canvas{pixels = raw_data(small[:]), width = 8 * len(CROP_TEXT), height = 16, stride = 8 * len(CROP_TEXT)}
		graphics.clear(small_canvas, graphics.COLOR_CARD_BOTTOM)
		graphics.text(small_canvas, 0, 0, CROP_TEXT, graphics.COLOR_TEXT)
		x := 8 + (index % 4) * 320
		y := crop_top + (index / 4) * crop_height
		graphics.text(canvas, x, y, font.label[:min(len(font.label), 38)], graphics.COLOR_DIM)
		for row in 0 ..< 16 {
			for column in 0 ..< small_canvas.width {
				graphics.fill(canvas, x + column * CROP_SCALE, y + 20 + row * CROP_SCALE, CROP_SCALE, CROP_SCALE, small[row * small_canvas.width + column])
			}
		}
	}
	picture_font_use({})
	rgb := make([]u8, 3 * len(pixels), context.temp_allocator)
	for color, index in pixels {
		rgb[3 * index] = u8(color >> 16)
		rgb[3 * index + 1] = u8(color >> 8)
		rgb[3 * index + 2] = u8(color)
	}
	file, encode_error := png_encode(PICTURE_WIDTH, height, 3, rgb)
	if encode_error != nil {
		fmt.eprintfln("kerneltool: cannot encode %s: %v", CANDIDATES_PICTURE, encode_error)
		return false
	}
	if write_error := os.write_entire_file(CANDIDATES_PICTURE, file); write_error != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", CANDIDATES_PICTURE, write_error)
		return false
	}
	return true
}

@(private = "file")
picture_font_use :: proc(font: Picture_Font) {
	if font.cache == nil {
		graphics.text_choice_set(.Spleen, .Red_Green_Blue)
		return
	}
	if problem := graphics.text_cache_set(font.cache); problem.kind != .None {
		fmt.eprintfln("kerneltool: a glyph cache of the picture is refused: %v", problem)
	}
	graphics.text_choice_set(.Vector, .Red_Green_Blue)
}
