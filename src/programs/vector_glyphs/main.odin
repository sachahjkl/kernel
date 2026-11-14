// The choice of the vector font (docs/FONTS.md, "The font file"): the same
// lines of the system in each candidate font and in Spleen 8x16, one word of
// each enlarged, and the measures of the text path.
//
// The program carries the six subsets of resources/fonts (ASCII only) and
// builds a glyph cache of each one in its own memory: the time of that
// build is the measure of a cache made by each program at run time (the
// first of the three places of docs/FONTS.md, "Where it lives: three places
// weighed").
// The text of the window itself is the text of the system: the glyph
// cache that the root service maps, or Spleen, as the setting says.
//
// **What it is for.** It is the record of a choice: a reader sees the same
// lines in each candidate font at the sizes of the system, and the cost of
// each place where a glyph can come from, before a font becomes the font
// of the system.
//
// **Start**: `start("vector_glyphs")` in the console, or the bar of the
// desktop. It has no grant of `grants_of`.
//
// **What a reader sees**: one block for each candidate and one for Spleen
// 8x16. The log has:
//
// - "vector_glyphs: one glyph from its outline, ...": the time of one glyph
//   at the scales 1, 2 and 3, from the glyph cache of the system, and from
//   Spleen; each time is the least of 50 short batches, so that a batch that
//   the host stopped does not count;
// - one line for each candidate: the time to build its cache of 95
//   characters at 3 scales, and its bytes;
// - "vector_glyphs: ok, 6 candidates beside Spleen 8x16".
//
// **What it does not prove**: the times are measures of this host, not
// bounds.
package vector_glyphs

import "contract:glyph_cache"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:system"
import "support:vector_font"

WIDTH :: 1008
HEIGHT :: 704

Candidate :: struct {
	name:  string,
	bytes: []u8,
}

// The subsets that `kerneltool vector_fonts` writes, with their licenses
// beside them in resources/fonts.
candidates := [?]Candidate {
	{"Paper Mono (default)", #load("../../../resources/fonts/paper_mono.ttf")},
	{"JetBrains Mono", #load("../../../resources/fonts/jetbrains_mono.ttf")},
	{"DejaVu Sans Mono", #load("../../../resources/fonts/dejavu_sans_mono.ttf")},
	{"IBM Mono (Plex)", #load("../../../resources/fonts/ibm_mono.ttf")},
	{"Fira Mono", #load("../../../resources/fonts/fira_mono.ttf")},
	{"Commit Mono", #load("../../../resources/fonts/commit_mono.ttf")},
	{"Iosevka", #load("../../../resources/fonts/iosevka.ttf")},
}

SAMPLE :: "compositor  12.4 ms  2 418 pages {fill} [rings] gi Rb 0O 1lI"
ENLARGED_WORD :: "Rag{0}%"
ENLARGED :: 4

// The glyph cache of one candidate, built here; 8-byte words.
cache_memory: [vector_font.GLYPH_CACHE_LIMIT / 8 + 1]u64
render_memory: vector_font.Render_Memory
build_times: [len(candidates)]u64
cache_sizes: [len(candidates)]int

records_now, records_before: [256]interface.Draw_Record
text_now, text_before: [8192]u8
drawing: interface.Window_Drawing

// with_font draws with one candidate: it builds its cache, gives it to
// src/library/support/graphics, and gives the state of the system to restore after.
with_font :: proc "contextless" (index: int) -> (saved: graphics.Text_State, ok: bool) {
	saved = graphics.text_state
	font, problem := vector_font.font_open(candidates[index].bytes)
	out := ([^]u8)(raw_data(cache_memory[:]))[:vector_font.GLYPH_CACHE_LIMIT]
	start := system.nanoseconds()
	size := 0
	if problem == .None {
		size, problem = vector_font.glyph_cache_build(&font, candidates[index].bytes, candidates[index].name, true, &render_memory, out)
	}
	if problem != .None {
		system.log("vector_glyphs: the font ", candidates[index].name, " is refused: ", vector_font.font_problem_names[problem])
		return saved, false
	}
	build_times[index] = system.nanoseconds() - start
	cache_sizes[index] = size
	if refused := graphics.text_cache_set(out[:size]); refused.kind != .None {
		system.log("vector_glyphs: the cache of ", candidates[index].name, " is refused: ", glyph_cache.problem_sentences[refused.kind])
		return saved, false
	}
	graphics.text_choice_set(.Vector, saved.order)
	return saved, true
}

// enlarged draws a word at scale 1 into a small canvas, then each pixel as a
// square: the coverage of each stripe shows.
enlarged :: proc "contextless" (canvas: graphics.Canvas, x, y: int) {
	small: [8 * len(ENLARGED_WORD) * 16]graphics.Color
	view := graphics.Canvas{pixels = raw_data(small[:]), width = 8 * len(ENLARGED_WORD), height = 16, stride = 8 * len(ENLARGED_WORD)}
	graphics.clear(view, graphics.COLOR_CARD_BOTTOM)
	graphics.text(view, 0, 0, ENLARGED_WORD, graphics.COLOR_TEXT)
	for row in 0 ..< 16 {
		for column in 0 ..< view.width {
			graphics.fill(canvas, x + column * ENLARGED, y + row * ENLARGED, ENLARGED, ENLARGED, small[row * view.width + column])
		}
	}
}

ROW_HEIGHT :: 40
LIST_TOP :: 48
ENLARGED_TOP :: LIST_TOP + (len(candidates) + 1) * ROW_HEIGHT + 16

// draw draws the whole window: the frame with the interface package, then
// the lines of each candidate over it.
draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_begin(&drawing)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	content := interface.card(&frame, {8, 8, WIDTH - 16, HEIGHT - 16}, "THE FONT OF THE SYSTEM", "resources/fonts: seven candidates, ASCII subsets, glyf outlines", graphics.COLOR_MACHINE)
	interface.draw_text(frame.table, content.x, content.y, "the same line in each font, at scale 1 (8 x 16 pixels), then a word enlarged 4 times", graphics.COLOR_DIM)
	for index in 0 ..= len(candidates) {
		y := content.y + LIST_TOP - 24 + index * ROW_HEIGHT
		name := index == 0 ? "Spleen 8x16 (bitmap)" : candidates[index - 1].name
		interface.draw_text(frame.table, content.x, y, name, graphics.COLOR_DIM)
		if index > 0 {
			builder: interface.Text_Builder
			interface.text_put(&builder, "cache built in ")
			interface.text_put_number(&builder, build_times[index - 1] / 1000)
			interface.text_put(&builder, " us, ")
			interface.text_put_number(&builder, u64(cache_sizes[index - 1]))
			interface.text_put(&builder, " bytes")
			interface.draw_text_right(frame.table, content.x + content.width, y, interface.text_of(&builder), graphics.COLOR_DIM)
		}
	}
	interface.window_frame_end(&drawing, &frame, window)

	canvas := window.canvas
	system_state := graphics.text_state
	for index in 0 ..= len(candidates) {
		y := content.y + LIST_TOP - 8 + index * ROW_HEIGHT
		x := content.x + 8
		if index == 0 {
			graphics.text_choice_set(.Spleen, system_state.order)
		} else if _, built := with_font(index - 1); !built {
			continue
		}
		graphics.text(canvas, x, y, SAMPLE, graphics.COLOR_TEXT)
		graphics.text_scaled(canvas, x + 560, y - 16, "12 345", graphics.COLOR_PROGRAM, 2)
		enlarged(canvas, content.x + (index % 4) * 240, content.y + ENLARGED_TOP + (index / 4) * (16 * ENLARGED + 16))
		graphics.text_state = system_state
	}
	display.present(window)
}

// The entry of vector_glyphs: it measures the three sources of a glyph,
// draws the candidates, writes the measures, then draws again after each
// event for ever.
//
// With no window it stops with the code 1. The measures run before the
// first picture, on a scratch canvas that is not the window. The caches of
// the candidates are built during the first `draw`.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "vector_glyphs")
	if !ok {
		system.stop(1)
	}
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])

	// The measures, before the window: one glyph from its outline, in fixed
	// point, at each scale; one glyph from the glyph cache of the system;
	// one glyph of Spleen. The scratch canvas is not the window.
	scratch: [48 * 48]graphics.Color
	scratch_canvas := graphics.Canvas{pixels = raw_data(scratch[:]), width = 48, height = 48, stride = 48}
	font, problem := vector_font.font_open(candidates[0].bytes)
	measures: vector_font.Font_Measures
	if problem == .None {
		measures, problem = vector_font.font_measures(&font, &render_memory)
	}
	// Each measure is the least time of BATCHES short batches: a batch that
	// the host stops in its middle does not count (a loaded host stops the
	// processors of the machine).
	BATCHES :: 50
	outline_times: [3]u64 = max(u64)
	pixels: [vector_font.CELL_WIDTH_LIMIT * vector_font.CELL_HEIGHT_LIMIT]u32
	if problem == .None {
		for scale in 1 ..= 3 {
			style := vector_font.glyph_style_of(measures, 8 * scale, 16 * scale, true)
			for _ in 0 ..< BATCHES / 5 {
				start := system.nanoseconds()
				for character in u8(33) ..= 126 {
					_ = vector_font.glyph_render(&font, measures, style, rune(character), &render_memory, pixels[:])
				}
				outline_times[scale - 1] = min(outline_times[scale - 1], (system.nanoseconds() - start) / 94)
			}
		}
	}
	BATCH :: 64
	sample := "Rag{0}%e"
	least_of_batches :: proc "contextless" (canvas: graphics.Canvas, sample: string) -> u64 {
		least := max(u64)
		for _ in 0 ..< BATCHES {
			start := system.nanoseconds()
			for index in 0 ..< BATCH {
				graphics.character(canvas, 0, 0, sample[index % len(sample)], graphics.COLOR_TEXT)
			}
			least = min(least, (system.nanoseconds() - start) / BATCH)
		}
		return least
	}
	cache_time, spleen_time: u64
	if graphics.text_vector_drawn() {
		cache_time = least_of_batches(scratch_canvas, sample)
	}
	saved := graphics.text_state
	graphics.text_choice_set(.Spleen, saved.order)
	spleen_time = least_of_batches(scratch_canvas, sample)
	graphics.text_state = saved
	system.log("vector_glyphs: one glyph from its outline, in fixed point, with the stripes (the least of batches): scale 1 ", outline_times[0], " ns, scale 2 ", outline_times[1], " ns, scale 3 ", outline_times[2], " ns; from the glyph cache: ", cache_time, " ns; Spleen 8x16: ", spleen_time, " ns")

	draw(&window)
	for size, index in cache_sizes {
		system.log("vector_glyphs: the cache of ", candidates[index].name, ": 95 characters at 3 scales built in ", build_times[index] / 1000, " us, ", u64(size), " bytes")
	}
	system.log("vector_glyphs: ok, ", u64(len(candidates)), " candidates beside Spleen 8x16")
	for {
		display.wait(&window)
		if interface.window_events(&drawing, &window) {
			draw(&window)
		}
	}
}
