// The glyph cache file (docs/FONTS.md, "The glyph cache"): the glyphs of
// one font, already drawn, for each size of the grid. The kernel tool makes
// it at build time from the font file; the boot image holds it as a
// resource; the root service gives each program a read-only mapping of it.
// A program draws a character with a copy and a blend of its words: no
// outline is read at run time.
//
// One file, read in place after one validation. All numbers are
// little-endian; each record has a fixed size.
//
//   Header         128 bytes  at 0
//   Size_Entry     16 bytes   x size_count, at 128
//   Glyph_Entry    8 bytes    x size_count x character_count, after the sizes
//   (zero bytes to a multiple of 64)
//   words          u32 each   at word_offset, word_count of them
//
// A word is 0xGGRRGGBB: the coverage of the whole pixel (for grayscale) in
// the high byte, then the coverage of the red, the green and the blue
// stripe after the filter, with red at the left of the pixel. A glyph keeps
// only its rows with ink: rows first_row ..< first_row + row_count of its
// cell, each a full row of the cell.
package glyph_cache

MAGIC :: u64(0x5345485048594C47) // The bytes "GLYPHSES" ("GLYPH" and "SES").
VERSION :: 1
HEADER_SIZE :: 128
SIZE_ENTRY_SIZE :: 16
GLYPH_ENTRY_SIZE :: 8
SIZE_LIMIT :: 3 // The scales 1, 2 and 3 of the grid (docs/DESIGN.md, section 5).
CHARACTER_LIMIT :: 95 // ASCII 32 to 126.
CELL_WIDTH_LIMIT :: 24
CELL_HEIGHT_LIMIT :: 48

Header :: struct #packed {
	magic:            u64,
	version:          u32,
	renderer_version: u32, // The version of the renderer of support/vector_font that drew the words.
	file_size:        u64,
	first_character:  u32, // 32.
	character_count:  u32, // 95.
	size_count:       u32, // 3: one entry for each scale, in the order 1, 2, 3.
	flags:            u32, // FLAG_GRID_FIT, and the filter in bits 8 to 15.
	word_offset:      u64, // From the start of the file; a multiple of 64.
	word_count:       u64,
	font_hash:        [32]u8, // BLAKE3 of the font file that the glyphs come from: the cache is named by what made it.
	font_name:        [32]u8, // ASCII 32 to 126, then zero bytes.
}
#assert(size_of(Header) <= HEADER_SIZE)

FLAG_GRID_FIT :: 1 // The baseline, the x-height and the cap height are on whole pixels.

Size_Entry :: struct #packed {
	cell_width:  u16, // 8, 16, 24: the advance of every character.
	cell_height: u16, // 16, 32, 48: the line.
	baseline:    u16, // The row of the baseline, from the top of the cell.
	reserved:    u16,
	first_glyph: u32, // The index of the entry of the first character of this size.
	reserved_2:  u32,
}
#assert(size_of(Size_Entry) == SIZE_ENTRY_SIZE)

Glyph_Entry :: struct #packed {
	first_row:   u16,
	row_count:   u16, // 0: a glyph with no ink, a space.
	word_offset: u32, // From the first word: the first word of row first_row.
}
#assert(size_of(Glyph_Entry) == GLYPH_ENTRY_SIZE)

// Problem: why a file was refused. A zero problem is a valid file.
Problem_Kind :: enum u8 {
	None,
	Too_Short, // The file is shorter than its header or than a table.
	Bad_Magic,
	Bad_Version,
	Bad_Size, // file_size is not the size of the file.
	Bad_Count, // A count is 0 or above its limit.
	Bad_Cell, // A cell size or a baseline is out of its limits.
	Bad_Words, // The words are not where the header says.
	Bad_Glyph, // A glyph has rows outside its cell, or words outside the words.
}

Problem :: struct {
	kind:  Problem_Kind,
	index: u32, // The size or the glyph.
	value: u64,
	limit: u64,
}

problem_sentences := [Problem_Kind]string {
	.None        = "the glyph cache is valid",
	.Too_Short   = "the glyph cache is shorter than its header or its tables",
	.Bad_Magic   = "the glyph cache does not start with the bytes GLYPHSES",
	.Bad_Version = "the glyph cache has a version that this reader does not know",
	.Bad_Size    = "the size in the header of the glyph cache is not the size of the file",
	.Bad_Count   = "a count of the glyph cache is 0 or above its limit",
	.Bad_Cell    = "a cell of the glyph cache is out of the limits of the grid",
	.Bad_Words   = "the words of the glyph cache are not where its header says",
	.Bad_Glyph   = "a glyph of the glyph cache has rows outside its cell or words outside the file",
}

// Cache: a valid file, read in place.
Cache :: struct {
	header: ^Header,
	sizes:  []Size_Entry,
	glyphs: []Glyph_Entry,
	words:  []u32,
}

// validate checks a whole file once. After it, a reader trusts each entry.
validate :: proc "contextless" (bytes: []u8) -> (cache: Cache, problem: Problem) {
	if len(bytes) < HEADER_SIZE || uintptr(raw_data(bytes)) % 8 != 0 {
		return {}, {kind = .Too_Short, value = u64(len(bytes)), limit = HEADER_SIZE}
	}
	header := (^Header)(raw_data(bytes))
	if header.magic != MAGIC {
		return {}, {kind = .Bad_Magic, value = header.magic, limit = MAGIC}
	}
	if header.version != VERSION {
		return {}, {kind = .Bad_Version, value = u64(header.version), limit = VERSION}
	}
	if header.file_size != u64(len(bytes)) {
		return {}, {kind = .Bad_Size, value = header.file_size, limit = u64(len(bytes))}
	}
	if header.character_count == 0 || header.character_count > CHARACTER_LIMIT || header.first_character < 32 || u64(header.first_character) + u64(header.character_count) > 127 {
		return {}, {kind = .Bad_Count, value = u64(header.character_count), limit = CHARACTER_LIMIT}
	}
	if header.size_count == 0 || header.size_count > SIZE_LIMIT {
		return {}, {kind = .Bad_Count, value = u64(header.size_count), limit = SIZE_LIMIT}
	}
	glyph_count := int(header.size_count) * int(header.character_count)
	tables_end := HEADER_SIZE + int(header.size_count) * SIZE_ENTRY_SIZE + glyph_count * GLYPH_ENTRY_SIZE
	if tables_end > len(bytes) {
		return {}, {kind = .Too_Short, value = u64(len(bytes)), limit = u64(tables_end)}
	}
	aligned := (tables_end + 63) / 64 * 64
	if header.word_offset != u64(aligned) || header.word_count > u64(len(bytes) - aligned) / 4 || u64(aligned) + header.word_count * 4 != u64(len(bytes)) {
		return {}, {kind = .Bad_Words, value = header.word_offset, limit = u64(aligned)}
	}
	cache.header = header
	cache.sizes = ([^]Size_Entry)(raw_data(bytes[HEADER_SIZE:]))[:header.size_count]
	cache.glyphs = ([^]Glyph_Entry)(raw_data(bytes[HEADER_SIZE + int(header.size_count) * SIZE_ENTRY_SIZE:]))[:glyph_count]
	cache.words = ([^]u32)(raw_data(bytes[aligned:]))[:header.word_count]
	for size, index in cache.sizes {
		scale := u16(index + 1)
		if size.cell_width != 8 * scale || size.cell_height != 16 * scale || size.baseline == 0 || size.baseline > size.cell_height {
			return {}, {kind = .Bad_Cell, index = u32(index), value = u64(size.cell_width), limit = u64(8 * scale)}
		}
		if size.first_glyph != u32(index) * header.character_count {
			return {}, {kind = .Bad_Count, index = u32(index), value = u64(size.first_glyph), limit = u64(index) * u64(header.character_count)}
		}
		for glyph, character in cache.glyphs[size.first_glyph:][:header.character_count] {
			end_row := u64(glyph.first_row) + u64(glyph.row_count)
			end_word := u64(glyph.word_offset) + u64(glyph.row_count) * u64(size.cell_width)
			if end_row > u64(size.cell_height) || end_word > header.word_count {
				return {}, {kind = .Bad_Glyph, index = size.first_glyph + u32(character), value = end_word, limit = header.word_count}
			}
		}
	}
	return cache, {}
}

// glyph gives the entry and the words of one character at one scale (1 to
// 3) of a valid cache; found is false for a character out of the cache.
glyph :: #force_inline proc "contextless" (cache: ^Cache, character: u8, scale: int) -> (size: Size_Entry, entry: Glyph_Entry, found: bool) {
	index := int(character) - int(cache.header.first_character)
	if index < 0 || index >= int(cache.header.character_count) || scale < 1 || scale > len(cache.sizes) {
		return {}, {}, false
	}
	size = cache.sizes[scale - 1]
	return size, cache.glyphs[int(size.first_glyph) + index], true
}
