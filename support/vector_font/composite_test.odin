#+build !freestanding
package vector_font

import "core:testing"

// The parts of each hostile composite glyph: as many as one glyph holds
// with offsets of 16 bits (6 bytes for each part).
@(private = "file")
HOSTILE_PARTS :: 21_000

// hostile_composite_font makes the tables that glyph_outline reads (hmtx,
// loca with long offsets, glyf) for glyph_count glyphs: each glyph before
// the last is a composite of HOSTILE_PARTS parts that name the glyph
// target_of(glyph); the last glyph is empty.
@(private = "file")
hostile_composite_font :: proc(glyph_count: int, target_of: proc(glyph: int) -> int) -> Font_File {
	put_u16 :: proc(bytes: []u8, at: int, value: int) {
		bytes[at] = u8(value >> 8)
		bytes[at + 1] = u8(value)
	}
	put_u32 :: proc(bytes: []u8, at: int, value: int) {
		put_u16(bytes, at, value >> 16)
		put_u16(bytes, at + 2, value & 0xFFFF)
	}
	glyph_size := 10 + 6 * HOSTILE_PARTS
	hmtx := 0
	loca := 4
	glyf := loca + 4 * (glyph_count + 1)
	bytes := make([]u8, glyf + (glyph_count - 1) * glyph_size)
	put_u16(bytes, hmtx, 1000)
	for glyph in 0 ..< glyph_count {
		start := glyph < glyph_count - 1 ? glyph * glyph_size : (glyph_count - 1) * glyph_size
		put_u32(bytes, loca + 4 * glyph, start)
		if glyph == glyph_count - 1 {
			continue
		}
		at := glyf + start
		put_u16(bytes, at, 0xFFFF) // numberOfContours -1: a composite.
		for part in 0 ..< HOSTILE_PARTS {
			place := at + 10 + 6 * part
			more := part < HOSTILE_PARTS - 1 ? 0x0020 : 0
			put_u16(bytes, place, 0x0002 | more) // Offsets as x and y, of 8 bits.
			put_u16(bytes, place + 2, target_of(glyph))
		}
	}
	put_u32(bytes, loca + 4 * glyph_count, (glyph_count - 1) * glyph_size)
	return {
		bytes              = bytes,
		units_per_em       = 1000,
		glyph_count        = glyph_count,
		long_offsets       = true,
		horizontal_metrics = 1,
		hmtx               = {hmtx, 4},
		loca               = {loca, 4 * (glyph_count + 1)},
		glyf               = {glyf, len(bytes) - glyf},
	}
}

// A composite glyph of 21 000 parts, in four levels whose last parts name
// an empty glyph, gives no point and reaches no depth limit: without a
// budget of parts the reader makes 21 000 to the power 4 calls. With the
// budget it stops at once. The same for a composite that names itself. The
// problem Composite_Too_Deep is the proof: the levels stay under the depth
// limit, so only the budget of parts gives it; a time would only measure
// the host.
@(test)
a_composite_of_many_empty_parts_ends_at_once :: proc(t: ^testing.T) {
	memory := new(Render_Memory)
	defer free(memory)
	outline := Outline{points = memory.points[:], contour_ends = memory.contours[:]}
	chain := hostile_composite_font(5, proc(glyph: int) -> int {return glyph + 1})
	defer delete(chain.bytes)
	itself := hostile_composite_font(2, proc(glyph: int) -> int {return glyph})
	defer delete(itself.bytes)
	testing.expect_value(t, glyph_outline(&chain, 0, &outline), Font_Problem.Composite_Too_Deep)
	testing.expect_value(t, glyph_outline(&itself, 0, &outline), Font_Problem.Composite_Too_Deep)
	testing.expect_value(t, outline.point_count, 0)
	// One level of 21 000 parts that name the empty glyph: past the budget.
	testing.expect_value(t, glyph_outline(&chain, 3, &outline), Font_Problem.Composite_Too_Deep)
}

// A face number past the faces of a collection has its own problem, not
// "the character has no glyph".
@(test)
a_face_past_the_collection :: proc(t: ^testing.T) {
	collection := [16]u8{'t', 't', 'c', 'f', 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 16}
	offset, problem := collection_face_offset(collection[:], 0)
	testing.expect(t, problem == .None && offset == 16)
	_, past := collection_face_offset(collection[:], 1)
	testing.expect_value(t, past, Font_Problem.No_Face)
	_, negative := collection_face_offset(collection[:], -1)
	testing.expect_value(t, negative, Font_Problem.No_Face)
}
