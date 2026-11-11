#+build !freestanding
package vector_font

import "core:testing"

@(private = "file")
font_bytes := #load("../../programs/vector_glyphs/DejaVuSansMono.ttf")

@(private = "file")
Glyph_Memory :: struct {
	points:   [512]Outline_Point,
	contours: [64]int,
}

@(test)
reads_the_font :: proc(t: ^testing.T) {
	font, problem := font_open(font_bytes)
	testing.expect_value(t, problem, Font_Problem.None)
	testing.expect_value(t, font.units_per_em, 2048)
	memory: Glyph_Memory
	outline := Outline{points = memory.points[:], contour_ends = memory.contours[:]}
	for character in rune(33) ..= 126 {
		glyph, found := glyph_of(&font, character)
		testing.expectf(t, found == .None && glyph != 0, "%c has a glyph", character)
		testing.expectf(t, glyph_outline(&font, glyph, &outline) == .None && outline.point_count > 0, "%c has an outline", character)
		testing.expect_value(t, outline.advance, 1233) // A monospace font.
	}
}

// A file cut at any length, or with bytes changed, gives a problem and no
// fault: each read is checked.
@(test)
hostile_files :: proc(t: ^testing.T) {
	memory: Glyph_Memory
	outline := Outline{points = memory.points[:], contour_ends = memory.contours[:]}
	for length := 0; length < len(font_bytes); length += 997 {
		font, problem := font_open(font_bytes[:length])
		if problem != .None {
			continue
		}
		for character in rune(33) ..= 126 {
			if glyph, found := glyph_of(&font, character); found == .None {
				_ = glyph_outline(&font, glyph, &outline)
			}
		}
	}
	changed := make([]u8, len(font_bytes))
	defer delete(changed)
	for seed in 0 ..< 64 {
		copy(changed, font_bytes)
		state := u32(seed * 2654435761 + 1)
		for _ in 0 ..< 64 {
			state = state * 1664525 + 1013904223
			changed[int(state >> 8) % len(changed)] = u8(state >> 24)
		}
		font, problem := font_open(changed)
		if problem != .None {
			continue
		}
		for character in rune(33) ..= 126 {
			if glyph, found := glyph_of(&font, character); found == .None {
				_ = glyph_outline(&font, glyph, &outline)
			}
		}
	}
}

// A square from (1, 1) to (3, 3.5) of the pixels: full inside, empty
// outside, half on the line y = 3.5.
@(test)
square_coverage :: proc(t: ^testing.T) {
	cells: [5 * 5]f32
	result: [5 * 5]u8
	target := Coverage{cells = cells[:], coverage = result[:], width = 5, height = 5}
	line_add(&target, 1, 1, 3, 1)
	line_add(&target, 3, 1, 3, 3.5)
	line_add(&target, 3, 3.5, 1, 3.5)
	line_add(&target, 1, 3.5, 1, 1)
	coverage_finish(&target)
	testing.expect_value(t, result[1 * 5 + 1], 255)
	testing.expect_value(t, result[2 * 5 + 2], 255)
	testing.expect_value(t, result[0 * 5 + 1], 0)
	testing.expect_value(t, result[1 * 5 + 3], 0)
	testing.expect_value(t, result[3 * 5 + 1], 128)
	testing.expect_value(t, result[4 * 5 + 1], 0)
}
