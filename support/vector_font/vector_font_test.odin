#+build !freestanding
package vector_font

import "core:fmt"
import "contract:glyph_cache"
import "core:testing"

@(private = "file")
font_bytes := #load("../../resources/fonts/dejavu_sans_mono.ttf")

@(test)
reads_the_font :: proc(t: ^testing.T) {
	font, problem := font_open(font_bytes)
	testing.expect_value(t, problem, Font_Problem.None)
	testing.expect_value(t, font.units_per_em, 2048)
	memory := new(Render_Memory)
	defer free(memory)
	outline := Outline{points = memory.points[:], contour_ends = memory.contours[:]}
	for character in rune(33) ..= 126 {
		glyph, found := glyph_of(&font, character)
		testing.expectf(t, found == .None && glyph != 0, "%c has a glyph", character)
		testing.expectf(t, glyph_outline(&font, glyph, &outline) == .None && outline.point_count > 0, "%c has an outline", character)
		testing.expect_value(t, outline.advance, 1233) // A monospace font.
	}
	measures, measured := font_measures(&font, memory)
	testing.expect_value(t, measured, Font_Problem.None)
	testing.expect(t, measures.monospace)
}

// A file cut at any length, or with bytes changed, gives a problem and no
// fault: each read is checked. The glyphs that it reads are drawn too.
@(test)
hostile_files :: proc(t: ^testing.T) {
	memory := new(Render_Memory)
	defer free(memory)
	pixels: [CELL_WIDTH_LIMIT * CELL_HEIGHT_LIMIT]u32
	measures := Font_Measures{advance = 1233, x_height = 1120, cap_height = 1493, top = 1901, bottom = -483, monospace = true}
	try :: proc(bytes: []u8, measures: Font_Measures, memory: ^Render_Memory, pixels: []u32) {
		font, problem := font_open(bytes)
		if problem != .None {
			return
		}
		_, _ = font_measures(&font, memory)
		for scale in 1 ..= 3 {
			style := glyph_style_of(measures, 8 * scale, 16 * scale, scale == 1)
			for character in rune(0) ..= 130 {
				_ = glyph_render(&font, measures, style, character, memory, pixels)
			}
		}
	}
	for length := 0; length < len(font_bytes); length += 211 {
		try(font_bytes[:length], measures, memory, pixels[:])
	}
	changed := make([]u8, len(font_bytes))
	defer delete(changed)
	for seed in 0 ..< 48 {
		copy(changed, font_bytes)
		state := u32(seed * 2654435761 + 1)
		for _ in 0 ..< 64 {
			state = state * 1664525 + 1013904223
			changed[int(state >> 8) % len(changed)] = u8(state >> 24)
		}
		try(changed, measures, memory, pixels[:])
	}
}

// A polygon in subunits; its area by the shoelace sum, in the units of
// coverage_sum (1 / FULL_PIXEL of a pixel: 2 for each square subunit).
@(private = "file")
polygon_add :: proc(target: ^Accumulation, points: [][2]i32) -> (area: i64) {
	for point, index in points {
		next := points[(index + 1) % len(points)]
		line_add(target, point.x, point.y, next.x, next.y)
		area += i64(point.x) * i64(next.y) - i64(next.x) * i64(point.y)
	}
	return abs(area) // Twice the area in square subunits.
}

// The sum of the coverage of a closed outline is its area: exact for edges
// that the cuts do not round (along the axes, at 45 degrees), within the
// rounding of the cut points for any other edge.
@(test)
coverage_is_the_area :: proc(t: ^testing.T) {
	cells: [(32 + 1) * 32]i32
	target, ok := accumulation_of(cells[:], 32, 32)
	testing.expect(t, ok)
	shapes := [][][2]i32 {
		{{300, 300}, {5000, 300}, {5000, 4000}, {300, 4000}}, // A rectangle at subunits that are not on a pixel.
		{{256, 256}, {2560, 256}, {256, 2560}}, // A triangle at 45 degrees.
		{{1000, 1000}, {3000, 3000}, {1000, 5000}}, // Two edges at 45 degrees, from a point inside a pixel.
		{{0, 0}, {8192, 0}, {8192, 8192}, {0, 8192}}, // The whole accumulation.
	}
	for shape in shapes {
		area := polygon_add(&target, shape)
		testing.expectf(t, abs(coverage_sum(&target)) == area, "a shape of %v: coverage %v, area %v", len(shape), coverage_sum(&target), area)
		scratch: [32 * 32]u8
		coverage_finish(&target, scratch[:])
	}
	worst: f64
	// Convex polygons (points on a circle): no crossing, the area compares.
	for count in 3 ..= 12 {
		points: [12][2]i32
		// The points of a regular polygon from a table of sines in 1/1024.
		SINES := [12][2]i32{{1024, 0}, {887, 512}, {512, 887}, {0, 1024}, {-512, 887}, {-887, 512}, {-1024, 0}, {-887, -512}, {-512, -887}, {0, -1024}, {512, -887}, {887, -512}}
		for index in 0 ..< count {
			direction := SINES[(index * 12) / count]
			points[index] = {4100 + direction.x * 3, 4000 + direction.y * 3}
		}
		area := polygon_add(&target, points[:count])
		sum := coverage_sum(&target)
		difference := f64(abs(abs(sum) - area)) / f64(area)
		worst = max(worst, difference)
		scratch: [32 * 32]u8
		coverage_finish(&target, scratch[:])
	}
	testing.expectf(t, worst < 0.0005, "a convex polygon: the coverage differs from the area by %v of the area", worst)
	fmt.printfln("vector_font: the coverage of a convex polygon differs from its area by at most %.6f of the area", worst)
}

// A vertical edge exactly on the right side of the last column, with a
// width of 1 and of 2: the accumulation has a cell for it, and each pixel
// is full. An outline that passes the sides is cut, and the coverage of the
// pixels inside stays exact.
@(test)
the_last_column :: proc(t: ^testing.T) {
	for width in 1 ..= 3 {
		cells: [(3 + 1) * 4]i32
		target, ok := accumulation_of(cells[:], width, 4)
		testing.expect(t, ok)
		right := i32(width * SUBUNITS_PER_PIXEL)
		_ = polygon_add(&target, {{0, 0}, {right, 0}, {right, 1024}, {0, 1024}})
		coverage: [3 * 4]u8
		coverage_finish(&target, coverage[:])
		for value in coverage[:width * 4] {
			testing.expectf(t, value == 255, "width %v: a pixel is %v, not full", width, value)
		}
		// Wider than the accumulation on both sides, and higher.
		_ = polygon_add(&target, {{-700, -300}, {right + 900, -300}, {right + 900, 1500}, {-700, 1500}})
		coverage_finish(&target, coverage[:])
		for value in coverage[:width * 4] {
			testing.expectf(t, value == 255, "width %v, an outline past the sides: a pixel is %v, not full", width, value)
		}
		// A vertical edge on the right side only: the pixel left of it is
		// full, nothing passes the end of a row.
		_ = polygon_add(&target, {{right - 128, 0}, {right, 0}, {right, 1024}, {right - 128, 1024}})
		coverage_finish(&target, coverage[:])
		testing.expect_value(t, coverage[width - 1], 128)
		// The accumulation is clear after a finish.
		for cell in cells[:(width + 1) * 4] {
			testing.expect_value(t, cell, 0)
		}
	}
}

// The filter: the fringe (the largest difference between two stripes of
// one pixel) and the spread (the thirds with more than 10 percent of ink)
// of each filter, on a stem of one pixel at the three places of a third.
@(test)
filters_measured :: proc(t: ^testing.T) {
	for filter in Stripe_Filter {
		fringe, spread, peak := 0, 0, 0
		for phase in 0 ..< 3 {
			thirds: [30]u8
			for index in 12 + phase ..< 15 + phase {
				thirds[index] = 255
			}
			out: [30]u8
			stripes_filter(thirds[:], out[:], filter)
			for pixel in 0 ..< 10 {
				values := out[3 * pixel:][:3]
				fringe = max(fringe, int(max(values[0], values[1], values[2])) - int(min(values[0], values[1], values[2])))
			}
			for value in out {
				if value > 25 {
					spread += 1
				}
				peak = max(peak, int(value))
			}
		}
		fmt.printfln("vector_font: filter %v: fringe %v of 255, %v thirds with ink for a stem of 3 thirds, peak %v", filter, fringe, spread / 3, peak)
	}
}

// The glyph cache of one fixed font, JetBrains Mono (a candidate, not the
// default: a test of the renderer must not change when the default
// changes): its words at each scale have a known hash, so that a change of the renderer is seen. A
// change that is wanted gives new hashes here and a new RENDERER_VERSION.
@(test)
golden_glyph_cache :: proc(t: ^testing.T) {
	bytes := #load("../../resources/fonts/jetbrains_mono.ttf")
	font, problem := font_open(bytes)
	testing.expect_value(t, problem, Font_Problem.None)
	memory := new(Render_Memory)
	defer free(memory)
	out := make([]u64, GLYPH_CACHE_LIMIT / 8)
	defer delete(out)
	file := ([^]u8)(raw_data(out))[:GLYPH_CACHE_LIMIT]
	size: int
	size, problem = glyph_cache_build(&font, bytes, "jetbrains_mono", true, memory, file)
	testing.expect_value(t, problem, Font_Problem.None)
	cache, refused := glyph_cache.validate(file[:size])
	testing.expect_value(t, refused.kind, glyph_cache.Problem_Kind.None)
	hashes: [3]u64
	for size_entry, index in cache.sizes {
		hash: u64 = 0xCBF2_9CE4_8422_2325
		for glyph in cache.glyphs[size_entry.first_glyph:][:cache.header.character_count] {
			testing.expect(t, glyph.left == 0 && glyph.width == size_entry.cell_width) // A monospace cache: each glyph is its cell.
			words := cache.words[glyph.word_offset:][:int(glyph.row_count) * int(glyph.width)]
			hash = (hash ~ u64(glyph.first_row) << 16 ~ u64(glyph.row_count)) * 0x0000_0100_0000_01B3
			for word in words {
				hash = (hash ~ u64(word)) * 0x0000_0100_0000_01B3
			}
		}
		hashes[index] = hash
	}
	fmt.printfln("vector_font: the glyph cache of jetbrains_mono: %v bytes, the hashes of its scales %16x %16x %16x", size, hashes[0], hashes[1], hashes[2])
	testing.expect_value(t, hashes, GOLDEN_HASHES)
	// The same font gives the same file: the build does not change it.
	again := make([]u64, GLYPH_CACHE_LIMIT / 8)
	defer delete(again)
	second := ([^]u8)(raw_data(again))[:GLYPH_CACHE_LIMIT]
	second_size, _ := glyph_cache_build(&font, bytes, "jetbrains_mono", true, memory, second)
	testing.expect(t, second_size == size && string(second[:size]) == string(file[:size]))
}

// The hashes of the words of the three scales of the glyph cache of
// JetBrains Mono, renderer version 1.
GOLDEN_HASHES :: [3]u64{0xae38c0ced203328f, 0xc47346a333a5063b, 0x8eb7b6620568c018}

// A glyph cache with a damaged field is refused, with the field named; no
// damage makes a fault.
@(test)
damaged_glyph_cache :: proc(t: ^testing.T) {
	bytes := #load("../../resources/fonts/jetbrains_mono.ttf")
	font, _ := font_open(bytes)
	memory := new(Render_Memory)
	defer free(memory)
	out := make([]u64, GLYPH_CACHE_LIMIT / 8)
	defer delete(out)
	file := ([^]u8)(raw_data(out))[:GLYPH_CACHE_LIMIT]
	size, _ := glyph_cache_build(&font, bytes, "jetbrains_mono", true, memory, file)
	good := make([]u8, size)
	defer delete(good)
	copy(good, file[:size])
	Damage :: struct {
		offset: int,
		value:  u8,
		kind:   glyph_cache.Problem_Kind,
	}
	damages := [?]Damage {
		{0, 0x00, .Bad_Magic},
		{8, 9, .Bad_Version},
		{16, 1, .Bad_Size},
		{28, 96, .Bad_Count}, // character_count
		{32, 4, .Bad_Count}, // size_count
		{40, 8, .Bad_Words}, // word_offset
		{glyph_cache.HEADER_SIZE, 9, .Bad_Cell}, // the width of scale 1
		{glyph_cache.HEADER_SIZE + 4, 0, .Bad_Cell}, // a baseline of 0
		{glyph_cache.HEADER_SIZE + 3 * glyph_cache.SIZE_ENTRY_SIZE + 2, 200, .Bad_Glyph}, // the rows of a glyph
		{glyph_cache.HEADER_SIZE + 3 * glyph_cache.SIZE_ENTRY_SIZE + 7, 0x7F, .Bad_Glyph}, // the words of a glyph
		// A monospace cache keeps each glyph in its cell, from its left side:
		// the damage of a grid of text cells depends on it.
		{glyph_cache.HEADER_SIZE + 3 * glyph_cache.SIZE_ENTRY_SIZE + 8, 1, .Bad_Glyph}, // a left side of 1
		{glyph_cache.HEADER_SIZE + 3 * glyph_cache.SIZE_ENTRY_SIZE + 8, 0xFF, .Bad_Glyph}, // a left side of 255
		{glyph_cache.HEADER_SIZE + 3 * glyph_cache.SIZE_ENTRY_SIZE + 10, 9, .Bad_Glyph}, // a width of 9 in a cell of 8
		{glyph_cache.HEADER_SIZE + 6, 3, .Bad_Count}, // three positions
		{glyph_cache.HEADER_SIZE + 3 * glyph_cache.SIZE_ENTRY_SIZE + 3 * 95 * glyph_cache.GLYPH_ENTRY_SIZE, 0x01, .Bad_Advance}, // an advance of 513 in a cell of 8
		{120, 1, .Bad_Count}, // a pair
		// The flags and the name.
		{36, 0x04, .Bad_Flags}, // a flag that no reader knows
		{37, 3, .Bad_Flags}, // a filter past the three
		{88, 0x01, .Bad_Name}, // a control byte
		{88 + 31, 'a', .Bad_Name}, // no end
	}
	for damage in damages {
		copy(file[:size], good)
		file[damage.offset] = damage.value
		_, problem := glyph_cache.validate(file[:size])
		testing.expectf(t, problem.kind == damage.kind, "a damage at %v: %v, expected %v", damage.offset, problem.kind, damage.kind)
	}
	// Cut at any length: refused, no fault.
	for length := 0; length < size; length += 977 {
		copy(file[:size], good)
		_, problem := glyph_cache.validate(file[:length])
		testing.expect(t, problem.kind != .None)
	}
}

// A vertical segment on the last column, and a coverage of width 1, write
// nothing outside their rows: the cell after the accumulation stays 0. The
// rasterizer in floating point that came before wrote there.
@(test)
segments_at_the_edges_stay_in_their_rows :: proc(t: ^testing.T) {
	cells: [(5 + 1) * 3 + 1]i32
	target, ok := accumulation_of(cells[:(5 + 1) * 3], 5, 3)
	testing.expect(t, ok)
	line_add(&target, 4 * SUBUNITS_PER_PIXEL, 0, 4 * SUBUNITS_PER_PIXEL, 3 * SUBUNITS_PER_PIXEL)
	line_add(&target, 5 * SUBUNITS_PER_PIXEL, 0, 5 * SUBUNITS_PER_PIXEL, 3 * SUBUNITS_PER_PIXEL)
	testing.expect_value(t, cells[(5 + 1) * 3], 0) // The cell after the last row is not touched.
	narrow_cells: [(1 + 1) * 3 + 1]i32
	narrow, narrow_ok := accumulation_of(narrow_cells[:(1 + 1) * 3], 1, 3)
	testing.expect(t, narrow_ok)
	line_add(&narrow, SUBUNITS_PER_PIXEL / 2, 0, SUBUNITS_PER_PIXEL / 2, 3 * SUBUNITS_PER_PIXEL)
	coverage: [3]u8
	coverage_finish(&narrow, coverage[:])
	testing.expect_value(t, narrow_cells[(1 + 1) * 3], 0)
}
