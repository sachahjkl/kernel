package vector_font

// The spacing of a proportional font (docs/FONTS.md, section 12): the
// advance of each glyph (hmtx, read by glyph_advance) and the pair
// adjustments of the table kern. A pair adjustment changes the advance of
// the left glyph of a pair when the right glyph follows it: "To" is closer
// than "T" then "o".
//
// This reader takes the form that OpenType keeps for kern: version 0, and
// a first subtable of format 0 (a list of pairs sorted by the two glyphs),
// horizontal, with no minimum and no cross-stream values. A font with no
// kern table has no adjustment. The pair lookups of the table GPOS are not
// read.
//
// The table is hostile input like the rest of the file: each count and
// each offset is checked against the length of the table before a read,
// and the order of the pairs is checked once, so a search is a binary
// search over records that are inside the table.

KERN_HEADER_SIZE :: 4 // version, count of subtables.
KERN_SUBTABLE_HEADER_SIZE :: 14 // version, length, coverage, count of pairs, and three numbers of the search.
KERN_PAIR_SIZE :: 6 // left glyph, right glyph, adjustment.

// Pair_Table: the pairs of the first subtable of a kern table that
// pair_table_open accepted.
Pair_Table :: struct {
	pairs: []u8, // count records of KERN_PAIR_SIZE bytes, sorted by left glyph then right glyph.
	count: int,
}

// pair_table_open checks the kern table of a font and gives its pairs. A
// font with no kern table gives an empty table and no problem.
pair_table_open :: proc "contextless" (font: ^Font_File) -> (table: Pair_Table, problem: Font_Problem) {
	if font.kern.length == 0 {
		return {}, .None
	}
	if font.kern.offset < 0 || font.kern.length < 0 || font.kern.offset + font.kern.length > len(font.bytes) {
		return {}, .Too_Short
	}
	kern := font.bytes[font.kern.offset:][:font.kern.length]
	version, version_read := read_u16(kern, 0)
	subtables, subtables_read := read_u16(kern, 2)
	if !version_read || !subtables_read {
		return {}, .Too_Short
	}
	// The kern table of Apple starts with the 32-bit version 0x00010000:
	// its first 16 bits are 1, an unknown version here.
	if version != 0 || subtables == 0 {
		return {}, .Unknown_Format
	}
	at := KERN_HEADER_SIZE
	subtable_version, subtable_version_read := read_u16(kern, at)
	coverage, coverage_read := read_u16(kern, at + 4)
	count, count_read := read_u16(kern, at + 6)
	if !subtable_version_read || !coverage_read || !count_read {
		return {}, .Too_Short
	}
	// coverage: the format in the high byte; bit 0 horizontal, bit 1
	// minimum values, bit 2 cross-stream.
	if subtable_version != 0 || coverage >> 8 != 0 || coverage & 0b111 != 0b001 {
		return {}, .Unknown_Format
	}
	// The length field of the subtable has 16 bits, and a subtable of more
	// than 10 920 pairs does not fit in it: fonts write it modulo 65536. The
	// count of pairs and the length of the table are the bounds here.
	first_pair := at + KERN_SUBTABLE_HEADER_SIZE
	pairs_end := first_pair + count * KERN_PAIR_SIZE
	if pairs_end > len(kern) {
		return {}, .Too_Short
	}
	pairs := kern[first_pair:pairs_end]
	previous := -1
	for index in 0 ..< count {
		left := read_u16(pairs, index * KERN_PAIR_SIZE) or_else 0
		right := read_u16(pairs, index * KERN_PAIR_SIZE + 2) or_else 0
		if left >= font.glyph_count || right >= font.glyph_count {
			return {}, .Unknown_Format
		}
		// Sorted, with no pair twice: the search below depends on it.
		key := left << 16 | right
		if key <= previous {
			return {}, .Unknown_Format
		}
		previous = key
	}
	return {pairs = pairs, count = count}, .None
}

// pair_adjustment gives the adjustment of the advance of the glyph left
// when the glyph right follows it, in units of the font: 0 for a pair that
// the table does not have.
pair_adjustment :: proc "contextless" (table: ^Pair_Table, left, right: int) -> int {
	key := left << 16 | right
	low, high := 0, table.count
	for low < high {
		middle := low + (high - low) / 2
		at := middle * KERN_PAIR_SIZE
		pair_left := read_u16(table.pairs, at) or_else 0
		pair_right := read_u16(table.pairs, at + 2) or_else 0
		pair_key := pair_left << 16 | pair_right
		switch {
		case pair_key == key:
			return read_i16(table.pairs, at + 4) or_else 0
		case pair_key < key:
			low = middle + 1
		case:
			high = middle
		}
	}
	return 0
}

// character_pair_adjustment gives the adjustment of a pair of characters,
// through the cmap: 0 when a character has no glyph.
character_pair_adjustment :: proc "contextless" (font: ^Font_File, table: ^Pair_Table, left, right: rune) -> int {
	left_glyph, left_problem := glyph_of(font, left)
	right_glyph, right_problem := glyph_of(font, right)
	if left_problem != .None || right_problem != .None {
		return 0
	}
	return pair_adjustment(table, left_glyph, right_glyph)
}

// character_advance gives the advance of a character in units of the font,
// through the cmap: the advance of the glyph 0 (.notdef) when the
// character has no glyph.
character_advance :: proc "contextless" (font: ^Font_File, character: rune) -> int {
	glyph, problem := glyph_of(font, character)
	if problem != .None {
		glyph = 0
	}
	return glyph_advance(font, glyph)
}
