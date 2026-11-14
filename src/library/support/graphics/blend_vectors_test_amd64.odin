#+build !freestanding
package graphics

import "contract:glyph_cache"
import "core:fmt"
import "core:testing"
import "core:time"
import "support:text_shaping"
import "support:vector_font"

// The SSE2 forms of the blends against their scalar forms (docs/SIMD.md):
// the same bytes for every input. The inputs come from a generator with a
// fixed seed, with the edge values often: 0, 1, 254, 255 in each byte, and
// whole words of 0, of all ones and of full coverage. Each row has guard
// words before and after it: a form that writes outside its columns
// changes them.

@(private = "file")
Test_Random :: struct {
	state: u64,
}

// next_random is xorshift64*: enough for test inputs, and the same on each host.
@(private = "file")
next_random :: proc(random: ^Test_Random) -> u32 {
	random.state ~= random.state >> 12
	random.state ~= random.state << 25
	random.state ~= random.state >> 27
	return u32((random.state * 0x2545F4914F6CDD1D) >> 32)
}

@(private = "file")
edge_byte :: proc(random: ^Test_Random) -> u32 {
	switch next_random(random) % 8 {
	case 0:
		return 0
	case 1:
		return 255
	case 2:
		return 1
	case 3:
		return 254
	}
	return next_random(random) & 0xFF
}

@(private = "file")
edge_word :: proc(random: ^Test_Random) -> u32 {
	switch next_random(random) % 10 {
	case 0:
		return 0
	case 1:
		return 0xFFFFFFFF
	case 2:
		return 0x00FFFFFF
	case 3:
		return 0xFF000000
	}
	return edge_byte(random) << 24 | edge_byte(random) << 16 | edge_byte(random) << 8 | edge_byte(random)
}

// The forms of a blend that the tests run.
@(private = "file")
Blend_Form :: enum u8 {
	Scalar,
	Sse2,
}

// The forms that the tests compare with the scalar form.
@(private = "file")
VECTOR_FORMS :: [?]Blend_Form{.Sse2}

@(private = "file")
coverage_row_in_form :: proc(form: Blend_Form, line: [^]Color, words: [^]u32, first, last: int, color: Color, order: Subpixel_Order, table: ^[4096]u8) {
	switch order {
	case .Red_Green_Blue:
		coverage_row_in_form_and_order(form, line, words, first, last, color, .Red_Green_Blue, table)
	case .Blue_Green_Red:
		coverage_row_in_form_and_order(form, line, words, first, last, color, .Blue_Green_Red, table)
	case .None:
		coverage_row_in_form_and_order(form, line, words, first, last, color, .None, table)
	}
}

@(private = "file")
coverage_row_in_form_and_order :: proc(form: Blend_Form, line: [^]Color, words: [^]u32, first, last: int, color: Color, $ORDER: Subpixel_Order, table: ^[4096]u8) {
	switch form {
	case .Scalar:
		blend_coverage_row_in_order(line, words, first, last, color, ORDER, table)
	case .Sse2:
		blend_coverage_row_sse2(line, words, first, last, color, ORDER, table)
	}
}

@(private = "file")
premultiplied_row_in_form :: proc(form: Blend_Form, to: [^]Color, from: [^]u32, count: int) {
	switch form {
	case .Scalar:
		blend_premultiplied_alpha_row_scalar(to, from, count)
	case .Sse2:
		blend_premultiplied_alpha_row_sse2(to, from, count)
	}
}

// Difference is the first pixel where a form differs from the scalar form,
// and the count of pixels that differ outside the columns that the call
// draws: the guard words and the columns before first.
@(private = "file")
Difference :: struct {
	index:         int, // In the array of the test; -1 when no pixel differs.
	expected:      u32,
	found:         u32,
	outside_count: int,
}

@(private = "file")
difference_of :: proc(expected, found: []u32, drawn_start, drawn_end: int) -> (result: Difference) {
	result.index = -1
	for index in 0 ..< len(expected) {
		if expected[index] == found[index] {
			continue
		}
		if result.index < 0 {
			result.index = index
			result.expected = expected[index]
			result.found = found[index]
		}
		if index < drawn_start || index >= drawn_end {
			result.outside_count += 1
		}
	}
	return
}

// Every length from 0 to 67, every place of the words and of the pixels
// against a boundary of 16 bytes (a pixel is 4 bytes, so 4 places), three
// first columns, the three orders.
@(test)
coverage_forms_give_the_bytes_of_the_scalar_form :: proc(t: ^testing.T) {
	table: [4096]u8
	square_root_table_fill(&table)
	forms := VECTOR_FORMS
	random := Test_Random{state = 0x9E3779B97F4A7C15}
	GUARD :: 16
	LONGEST :: 67
	SIZE :: GUARD + 3 + 2 + LONGEST + GUARD
	wrong := 0
	for order in Subpixel_Order {
		for length in 0 ..= LONGEST {
			for word_place in 0 ..< 4 {
				for pixel_place in 0 ..< 4 {
					for first in 0 ..< 3 {
						words, reference: [SIZE]u32
						for &word in words {
							word = edge_word(&random)
						}
						for &pixel in reference {
							pixel = edge_word(&random)
						}
						color := edge_word(&random)
						if next_random(&random) % 2 == 0 {
							color &= 0xFFFFFF
						}
						before := reference
						coverage_row_in_form(.Scalar, raw_data(reference[GUARD + pixel_place:]), raw_data(words[GUARD + word_place:]), first, first + length, color, order, &table)
						for form in forms {
							pixels := before
							coverage_row_in_form(form, raw_data(pixels[GUARD + pixel_place:]), raw_data(words[GUARD + word_place:]), first, first + length, color, order, &table)
							if pixels != reference {
								wrong += 1
								if wrong <= 5 {
									drawn_start := GUARD + pixel_place + first
									found := difference_of(reference[:], pixels[:], drawn_start, drawn_start + length)
									column := found.index - drawn_start
									word: u32 // The word of a column outside the drawn columns is not read.
									if column >= 0 && column < length {
										word = words[GUARD + word_place + first + column]
									}
									testing.expectf(t, false, "%v, order %v, length %d, places %d %d, first %d: column %d (pixel %08x, word %08x, color %08x): scalar %08x, the form %08x; %d pixels differ outside the drawn columns", form, order, length, word_place, pixel_place, first, column, before[found.index], word, color, found.expected, found.found, found.outside_count)
								}
							}
						}
					}
				}
			}
		}
	}
	testing.expect_value(t, wrong, 0)
}

// Each pixel value d and each coverage a of a channel, under colors with
// the edge values and others: each lane of the arithmetic meets each value.
@(test)
coverage_forms_meet_each_channel_value :: proc(t: ^testing.T) {
	table: [4096]u8
	square_root_table_fill(&table)
	forms := VECTOR_FORMS
	colors := [?]Color{0x000000, 0xFFFFFF, 0x01FE80, 0xFE017F, COLOR_TEXT, COLOR_DIM, 0xFF123456}
	wrong := 0
	for order in Subpixel_Order {
		for color in colors {
			for coverage in u32(0) ..= 255 {
				words: [256]u32
				reference: [256]Color
				for column in 0 ..< 256 {
					value := u32(column)
					// Each byte of the word has the coverage, except one
					// stripe in the columns of a third of the row.
					words[column] = coverage << 24 | coverage << 16 | coverage << 8 | coverage
					if column % 3 == 1 {
						words[column] &= 0xFFFF00FF
					}
					reference[column] = (255 - value) << 24 | value << 16 | value << 8 | value
				}
				before := reference
				coverage_row_in_form(.Scalar, raw_data(reference[:]), raw_data(words[:]), 0, 256, color, order, &table)
				for form in forms {
					pixels := before
					coverage_row_in_form(form, raw_data(pixels[:]), raw_data(words[:]), 0, 256, color, order, &table)
					if pixels != reference {
						wrong += 1
						if wrong <= 5 {
							found := difference_of(reference[:], pixels[:], 0, 256)
							testing.expectf(t, false, "%v, order %v, color %08x, coverage %d: column %d (pixel %08x, word %08x): scalar %08x, the form %08x", form, order, color, coverage, found.index, before[found.index], words[found.index], found.expected, found.found)
						}
					}
				}
			}
		}
	}
	testing.expect_value(t, wrong, 0)
}

// The scalar form once read the channels of a pixel 0xFFFFFFFF as 0: it took
// that value for "no pixel yet". A row that starts with such a pixel.
@(test)
coverage_scalar_form_reads_a_pixel_of_all_ones :: proc(t: ^testing.T) {
	table: [4096]u8
	square_root_table_fill(&table)
	pixels := [1]Color{0xFFFFFFFF}
	words := [1]u32{0x00808080}
	blend_coverage_row_in_order(raw_data(pixels[:]), raw_data(words[:]), 0, 1, 0xFFFFFF, .Red_Green_Blue, &table)
	// Under white, white at any coverage is white.
	testing.expect_value(t, pixels[0], Color(0xFFFFFF))
}

@(test)
premultiplied_forms_give_the_bytes_of_the_scalar_form :: proc(t: ^testing.T) {
	forms := VECTOR_FORMS
	random := Test_Random{state = 0x2545F4914F6CDD1D}
	GUARD :: 16
	LONGEST :: 67
	SIZE :: GUARD + 3 + LONGEST + GUARD
	wrong := 0
	for length in 0 ..= LONGEST {
		for source_place in 0 ..< 4 {
			for pixel_place in 0 ..< 4 {
				for _ in 0 ..< 4 {
					source, reference: [SIZE]u32
					for &value in source {
						value = edge_word(&random)
						// Most sources are premultiplied, as a picture is; the
						// others make the channels carry.
						if next_random(&random) % 4 != 0 {
							alpha := value >> 24
							value = alpha << 24 | min(value >> 16 & 0xFF, alpha) << 16 | min(value >> 8 & 0xFF, alpha) << 8 | min(value & 0xFF, alpha)
						}
					}
					for &pixel in reference {
						pixel = edge_word(&random)
					}
					before := reference
					premultiplied_row_in_form(.Scalar, raw_data(reference[GUARD + pixel_place:]), raw_data(source[GUARD + source_place:]), length)
					for form in forms {
						pixels := before
						premultiplied_row_in_form(form, raw_data(pixels[GUARD + pixel_place:]), raw_data(source[GUARD + source_place:]), length)
						if pixels != reference {
							wrong += 1
							if wrong <= 5 {
								drawn_start := GUARD + pixel_place
								found := difference_of(reference[:], pixels[:], drawn_start, drawn_start + length)
								column := found.index - drawn_start
								source_value: u32 // The source of a column outside the drawn columns is not read.
								if column >= 0 && column < length {
									source_value = source[GUARD + source_place + column]
								}
								testing.expectf(t, false, "%v, length %d, places %d %d: column %d (pixel %08x, source %08x): scalar %08x, the form %08x; %d pixels differ outside the drawn columns", form, length, source_place, pixel_place, column, before[found.index], source_value, found.expected, found.found, found.outside_count)
							}
						}
					}
				}
			}
		}
	}
	testing.expect_value(t, wrong, 0)
}

// Each alpha, each destination value, and source values with the edge
// values: 0, the alpha (the largest premultiplied value), and 255 (a value
// that is not premultiplied: the channels carry).
@(test)
premultiplied_forms_meet_each_channel_value :: proc(t: ^testing.T) {
	forms := VECTOR_FORMS
	wrong := 0
	for alpha in u32(0) ..= 255 {
		source_values := [5]u32{0, 1, alpha / 2, alpha, 255}
		for source_value in source_values {
			source: [256]u32
			reference: [256]Color
			for column in 0 ..< 256 {
				value := u32(column)
				source[column] = alpha << 24 | source_value << 16 | (255 - source_value) << 8 | source_value
				reference[column] = (255 - value) << 24 | value << 16 | (255 - value) << 8 | value
			}
			before := reference
			premultiplied_row_in_form(.Scalar, raw_data(reference[:]), raw_data(source[:]), 256)
			for form in forms {
				pixels := before
				premultiplied_row_in_form(form, raw_data(pixels[:]), raw_data(source[:]), 256)
				if pixels != reference {
					wrong += 1
				}
			}
		}
	}
	testing.expect_value(t, wrong, 0)
}

// glyph_in_form draws one glyph as character_vector_with does, with the
// rows blended in one form: the choice of the program does not decide here.
@(private = "file")
glyph_in_form :: proc(form: Blend_Form, cache: ^glyph_cache.Cache, table: ^[4096]u8, order: Subpixel_Order, canvas: Canvas, x, y: int, value: u8, color: Color, scale: int, position := 0) {
	_, entry, found := glyph_cache.glyph_at_position(cache, value, scale, position)
	if !found || entry.row_count == 0 {
		return
	}
	// The words of a row start at the column left of the origin.
	column_x := x + int(entry.left)
	width := int(entry.width)
	first_column := max(0, -column_x)
	last_column := min(width, canvas.width - column_x)
	first_row := max(0, -(y + int(entry.first_row)))
	last_row := min(int(entry.row_count), canvas.height - y - int(entry.first_row))
	if first_column >= last_column || first_row >= last_row {
		return
	}
	words := raw_data(cache.words[entry.word_offset:])
	for row in first_row ..< last_row {
		line := canvas.pixels[(y + int(entry.first_row) + row) * canvas.stride + column_x:]
		coverage_row_in_form(form, line, words[row * width:], first_column, last_column, color, order, table)
	}
}

// The glyphs of the glyph cache drawn in each form: the same pixels, and the
// time of one glyph in each form, on the host. A build of the tests with no
// optimisation puts no procedure inline: its times only rank the forms.
@(test)
glyph_draw_cost_of_each_form :: proc(t: ^testing.T) {
	bytes := #load("../../../../resources/fonts/jetbrains_mono.ttf")
	font, _ := vector_font.font_open(bytes)
	memory := new(vector_font.Render_Memory)
	defer free(memory)
	out := make([]u64, vector_font.GLYPH_CACHE_LIMIT / 8)
	defer delete(out)
	file := ([^]u8)(raw_data(out))[:vector_font.GLYPH_CACHE_LIMIT]
	size, problem := vector_font.glyph_cache_build(&font, bytes, "jetbrains_mono", true, memory, file)
	testing.expect_value(t, problem, vector_font.Font_Problem.None)
	cache, _ := glyph_cache.validate(file[:size])
	table: [4096]u8
	square_root_table_fill(&table)
	sample := "Rag{0}%e"
	WIDTH :: 24 * 10
	HEIGHT :: 48
	draw_all :: proc(form: Blend_Form, cache: ^glyph_cache.Cache, table: ^[4096]u8, pixels: []Color) {
		canvas := Canvas{pixels = raw_data(pixels), width = WIDTH, height = HEIGHT, stride = WIDTH}
		for &pixel, index in pixels {
			pixel = index % 7 == 0 ? COLOR_CARD_TOP : COLOR_CARD_BOTTOM
		}
		for order in Subpixel_Order {
			for scale in 1 ..= 3 {
				for character in u8(32) ..= 126 {
					// Places that cut the glyph at each edge, and places inside.
					x := int(character) % 13 * 19 - 8
					y := int(character) % 5 * 11 - 6
					glyph_in_form(form, cache, table, order, canvas, x, y, character, COLOR_TEXT, scale)
				}
			}
		}
	}
	reference := make([]Color, WIDTH * HEIGHT)
	defer delete(reference)
	draw_all(.Scalar, &cache, &table, reference)
	forms := VECTOR_FORMS
	pixels := make([]Color, WIDTH * HEIGHT)
	defer delete(pixels)
	for form in forms {
		draw_all(form, &cache, &table, pixels)
		found := difference_of(reference, pixels, 0, len(pixels))
		testing.expectf(t, found.index < 0, "%v: the glyphs differ from the scalar form: pixel %d (x %d, y %d): scalar %08x, the form %08x", form, found.index, found.index % WIDTH, found.index / WIDTH, found.expected, found.found)
	}
	canvas := Canvas{pixels = raw_data(pixels), width = WIDTH, height = HEIGHT, stride = WIDTH}
	REPEAT :: 200_000
	all_forms := [?]Blend_Form{.Scalar, .Sse2}
	for form in all_forms {
		start := time.tick_now()
		for index in 0 ..< REPEAT {
			glyph_in_form(form, &cache, &table, .Red_Green_Blue, canvas, 8, 8, sample[index % len(sample)], COLOR_TEXT, 1)
		}
		fmt.printfln("graphics: one glyph from the glyph cache on the host, the %v form: %v ns", form, time.duration_nanoseconds(time.tick_since(start)) / REPEAT)
	}
}

// The glyph caches of the system: Paper Mono with the grid fit at the
// three scales, its SemiBold at scale 1, and B612 with its positions (a
// proportional cache: left sides other than 0, glyphs that overlap).
@(private = "file")
Test_Cache :: struct {
	name:  string,
	words: []u64,
	cache: glyph_cache.Cache,
}

@(private = "file")
test_caches_build :: proc(t: ^testing.T) -> (caches: [3]Test_Cache) {
	memory := new(vector_font.Render_Memory)
	defer free(memory)
	Source :: struct {
		name:         string,
		bytes:        []u8,
		scale_count:  int,
		proportional: bool,
	}
	sources := [3]Source {
		{"paper_mono", #load("../../../../resources/fonts/paper_mono.ttf"), 3, false},
		{"paper_mono_semibold", #load("../../../../resources/fonts/paper_mono_semibold.ttf"), 1, false},
		{"b612", #load("../../../../resources/fonts/b612.ttf"), 3, true},
	}
	positions := [3]int{3, 1, 1}
	for source, index in sources {
		font, problem := vector_font.font_open(source.bytes)
		testing.expect_value(t, problem, vector_font.Font_Problem.None)
		limit := source.proportional ? vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT : vector_font.GLYPH_CACHE_LIMIT
		caches[index].name = source.name
		caches[index].words = make([]u64, limit / 8)
		file := ([^]u8)(raw_data(caches[index].words))[:limit]
		size: int
		if source.proportional {
			size, problem = vector_font.glyph_cache_build_proportional(&font, source.bytes, source.name, true, memory, file, positions[:])
		} else {
			size, problem = vector_font.glyph_cache_build(&font, source.bytes, source.name, true, memory, file, source.scale_count)
		}
		testing.expect_value(t, problem, vector_font.Font_Problem.None)
		refused: glyph_cache.Problem
		caches[index].cache, refused = glyph_cache.validate(file[:size])
		testing.expect_value(t, refused.kind, glyph_cache.Problem_Kind.None)
	}
	return caches
}

// The three blends of a glyph give the same bytes: the table blend of the
// programs (character_vector_with, with its fallback in the form of the
// target), the SSE2 form alone and the scalar form alone. For each cache of
// the system, each scale that it has, each order of the stripes, three
// colors, over a flat color, the gradient of a card, a gradient across and
// noise, in two passes (the second over the first). The glyphs are 6
// pixels apart for each scale, so the glyphs of B612 overlap. The positions
// 1 and 2 of B612 compare the SSE2 form with the scalar form only: the
// table blend draws the position 0 (the draw of placed glyphs is a later
// step).
@(test)
three_blends_give_the_same_bytes_for_each_cache :: proc(t: ^testing.T) {
	caches := test_caches_build(t)
	defer for item in caches {
		delete(item.words)
	}
	table: [4096]u8
	square_root_table_fill(&table)
	tables := new(Blend_Tables)
	defer free(tables)
	WIDTH :: 6 * 3 * 96 + 64
	HEIGHT :: 48
	drawn: [3][]Color
	for &pixels in drawn {
		pixels = make([]Color, WIDTH * HEIGHT)
	}
	defer for pixels in drawn {
		delete(pixels)
	}
	canvases: [3]Canvas
	for pixels, index in drawn {
		canvases[index] = {pixels = raw_data(pixels), width = WIDTH, height = HEIGHT, stride = WIDTH}
	}
	colors := [?]Color{COLOR_TEXT, COLOR_PROGRAM, COLOR_WHITE}
	differences: [2]int // The table blend, then the SSE2 form, against the scalar form.
	for &item in caches {
		for scale in 1 ..= len(item.cache.sizes) {
			position_count := int(item.cache.sizes[scale - 1].position_count)
			for position in 0 ..< position_count {
				for background in Speed_Background {
					for order in Subpixel_Order {
						for color in colors {
							for canvas in canvases {
								background_fill(canvas, background)
							}
							for _ in 0 ..< 2 {
								for character in 32 ..< 127 {
									x := 8 + (character - 32) * 6 * scale
									value := u8(character)
									glyph_in_form(.Scalar, &item.cache, &table, order, canvases[0], x, 0, value, color, scale, position)
									glyph_in_form(.Sse2, &item.cache, &table, order, canvases[1], x, 0, value, color, scale, position)
									if position == 0 {
										character_vector_with(&item.cache, &table, tables, order, canvases[2], x, 0, value, color, scale)
									}
								}
							}
							for pixel, index in drawn[0] {
								if position == 0 && drawn[2][index] != pixel {
									differences[0] += 1
								}
								if drawn[1][index] != pixel {
									differences[1] += 1
								}
							}
						}
					}
				}
			}
		}
		testing.expectf(t, differences == [2]int{}, "%s: the table blend differs from the scalar form in %v pixels, the SSE2 form in %v", item.name, differences[0], differences[1])
		fmt.printfln("graphics: %s: the table blend, the SSE2 form and the scalar form: %v and %v pixels differ", item.name, differences[0], differences[1])
		differences = {}
	}
}

// The time of one glyph at scale 1 of Paper Mono in each blend, over a
// flat color, a gradient across and noise, on the host: run with `taskset
// -c N` and -o:speed, the least of SPEED_BATCHES batches of one line (as
// text_speed_parts). The table blend is the path of the programs; the SSE2
// form alone and the scalar form alone draw each row with that form.
@(test)
text_speed_of_each_blend :: proc(t: ^testing.T) {
	caches := test_caches_build(t)
	defer for item in caches {
		delete(item.words)
	}
	Blend_Speed_Data :: struct {
		cache:  ^glyph_cache.Cache,
		table:  [4096]u8,
		tables: Blend_Tables,
		form:   Blend_Form,
	}
	data := new(Blend_Speed_Data)
	defer free(data)
	data.cache = &caches[0].cache
	square_root_table_fill(&data.table)
	pixels := make([]Color, 640 * 48)
	defer delete(pixels)
	canvas := Canvas{pixels = raw_data(pixels), width = 640, height = 48, stride = 640}
	SAMPLE :: "compositor  12.4 ms  2 418 pages {fill} [rings] gi Rb 0O 1lI"
	#assert(len(SAMPLE) == SPEED_GLYPHS)
	least_of :: proc(canvas: Canvas, background: Speed_Background, data: ^Blend_Speed_Data, tables: bool) -> f64 {
		least := max(i64)
		text := SAMPLE
		for _ in 0 ..< SPEED_BATCHES {
			background_fill(canvas, background) // Not in the time.
			start := time.tick_now()
			for index in 0 ..< SPEED_GLYPHS {
				if tables {
					character_vector_with(data.cache, &data.table, &data.tables, .Red_Green_Blue, canvas, 8 * index, 8, text[index], COLOR_TEXT, 1)
				} else {
					glyph_in_form(data.form, data.cache, &data.table, .Red_Green_Blue, canvas, 8 * index, 8, text[index], COLOR_TEXT, 1)
				}
			}
			least = min(least, time.duration_nanoseconds(time.tick_since(start)))
		}
		return f64(least) / SPEED_GLYPHS
	}
	backgrounds := [3]Speed_Background{.Flat, .Across, .Noise}
	for background in backgrounds {
		data.tables = {}
		with_tables := least_of(canvas, background, data, true)
		data.form = .Sse2
		sse2 := least_of(canvas, background, data, false)
		data.form = .Scalar
		scalar := least_of(canvas, background, data, false)
		fmt.printfln("graphics: one glyph of paper_mono at scale 1 over %v: the table blend %.1f ns, the SSE2 form %.1f ns, the scalar form %.1f ns", background, with_tables, sse2, scalar)
	}
}

// The text of a proportional font, drawn with text_proportional_with (the
// table blend, with the form of the target as its fallback), gives the
// bytes of the same placed glyphs drawn with the SSE2 form alone and with
// the scalar form alone, each glyph at the position that position_of
// gives. The texts have pairs and glyphs that overlap; three places, a
// fraction of a pixel apart; each order of the stripes; the four
// backgrounds.
@(test)
proportional_text_gives_the_same_bytes_in_each_blend :: proc(t: ^testing.T) {
	caches := test_caches_build(t)
	defer for item in caches {
		delete(item.words)
	}
	cache := &caches[2].cache // B612
	spacing, spacing_ok := text_shaping.spacing_of(cache, 1)
	testing.expect(t, spacing_ok)
	table: [4096]u8
	square_root_table_fill(&table)
	tables := new(Blend_Tables)
	defer free(tables)
	WIDTH :: 640
	HEIGHT :: 48
	drawn: [3][]Color
	for &pixels in drawn {
		pixels = make([]Color, WIDTH * HEIGHT)
	}
	defer for pixels in drawn {
		delete(pixels)
	}
	canvases: [3]Canvas
	for pixels, index in drawn {
		canvases[index] = {pixels = raw_data(pixels), width = WIDTH, height = HEIGHT, stride = WIDTH}
	}
	texts := [?]string{"To LT Ty AVATAR Wave", "The quick brown fox jumps over the lazy dog.", "0123456789 {fill} [rings] gi Rb 0O 1lI"}
	places := [3]i64{8 * 64, 8 * 64 + 21, 8 * 64 + 43}
	differences: [2]int
	for sample_text in texts {
		placed: [64]text_shaping.Placed_Glyph
		count, _, _ := text_shaping.shape(&spacing, transmute([]u8)sample_text, placed[:])
		for place in places {
			for background in Speed_Background {
				for order in Subpixel_Order {
					for canvas in canvases {
						background_fill(canvas, background)
					}
					for glyph in placed[:count] {
						pixel, position := glyph_cache.position_of(place + i64(glyph.x), int(cache.sizes[0].position_count))
						value := u8(32 + glyph.glyph)
						glyph_in_form(.Scalar, cache, &table, order, canvases[0], int(pixel), 8, value, COLOR_TEXT, 1, position)
						glyph_in_form(.Sse2, cache, &table, order, canvases[1], int(pixel), 8, value, COLOR_TEXT, 1, position)
					}
					text_proportional_with(cache, &table, tables, order, canvases[2], place, 8, placed[:count], 1, COLOR_TEXT)
					for pixel, index in drawn[0] {
						if drawn[2][index] != pixel {
							differences[0] += 1
						}
						if drawn[1][index] != pixel {
							differences[1] += 1
						}
					}
				}
			}
		}
	}
	testing.expectf(t, differences == [2]int{}, "the text of B612: the table blend differs from the scalar form in %v pixels, the SSE2 form in %v", differences[0], differences[1])
}
