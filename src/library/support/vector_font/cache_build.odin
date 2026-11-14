package vector_font

import "modus:contract/blake3"
import "modus:contract/glyph_cache"

FIRST_CHARACTER :: 32 // The first character of a glyph cache: the space.
#assert(int(max(Stripe_Filter)) + 1 == glyph_cache.FILTER_COUNT)
CHARACTER_COUNT :: glyph_cache.CHARACTER_LIMIT // The characters of a glyph cache: 32 to 126.

// The places of the tables of a glyph cache file (modus:contract/glyph_cache).
@(private)
Cache_Layout :: struct {
	sizes, glyphs, advances, pairs, words: int, // The offset of each table in the file.
	glyph_count:                           int, // The glyph entries: each position of each size times the characters.
}

// cache_layout_of gives the offsets of the tables of a cache with one size
// for each count of positions, and `pair_count` pairs for each size. The
// words start on 64 bytes.
@(private)
cache_layout_of :: proc "contextless" (positions: []int, pair_count: int) -> (layout: Cache_Layout) {
	for count in positions {
		layout.glyph_count += count * CHARACTER_COUNT
	}
	layout.sizes = glyph_cache.HEADER_SIZE
	layout.glyphs = layout.sizes + len(positions) * glyph_cache.SIZE_ENTRY_SIZE
	layout.advances = layout.glyphs + layout.glyph_count * glyph_cache.GLYPH_ENTRY_SIZE
	layout.pairs = layout.advances + len(positions) * CHARACTER_COUNT * glyph_cache.ADVANCE_SIZE
	layout.words = (layout.pairs + len(positions) * pair_count * glyph_cache.PAIR_ENTRY_SIZE + 63) / 64 * 64
	return layout
}

// The tables of a cache in the memory of the caller, all zero.
@(private)
Cache_Tables :: struct {
	sizes:    []glyph_cache.Size_Entry, // One entry for each size.
	glyphs:   []glyph_cache.Glyph_Entry, // One entry for each glyph of each position of each size.
	advances: []i32, // The advance of each character at each size.
	pairs:    []glyph_cache.Pair_Entry, // The pair adjustments of each size.
	words:    []u32, // The coverage words of the glyphs.
}

// cache_tables_of empties the memory of a cache and gives its tables. ok is
// false when the memory is too small or not aligned on 8.
@(private)
cache_tables_of :: proc "contextless" (out: []u8, layout: Cache_Layout, size_count, pair_count: int) -> (tables: Cache_Tables, ok: bool) {
	if len(out) < layout.words || uintptr(raw_data(out)) % 8 != 0 {
		return {}, false
	}
	for &byte in out[:layout.words] {
		byte = 0
	}
	tables.sizes = ([^]glyph_cache.Size_Entry)(raw_data(out[layout.sizes:]))[:size_count]
	tables.glyphs = ([^]glyph_cache.Glyph_Entry)(raw_data(out[layout.glyphs:]))[:layout.glyph_count]
	tables.advances = ([^]i32)(raw_data(out[layout.advances:]))[:size_count * CHARACTER_COUNT]
	tables.pairs = ([^]glyph_cache.Pair_Entry)(raw_data(out[layout.pairs:]))[:size_count * pair_count]
	tables.words = ([^]u32)(raw_data(out[layout.words:]))[:(len(out) - layout.words) / 4]
	return tables, true
}

// cache_header_write writes the header of a cache: its magic, the hash of
// the font, its options and the places of its tables. It gives the bytes of
// the file.
@(private)
cache_header_write :: proc "contextless" (out: []u8, font_bytes: []u8, font_name: string, grid_fit, proportional: bool, layout: Cache_Layout, size_count, pair_count, word_count: int) -> int {
	header := (^glyph_cache.Header)(raw_data(out))
	header^ = {
		magic            = glyph_cache.MAGIC,
		version          = glyph_cache.VERSION,
		renderer_version = RENDERER_VERSION,
		file_size        = u64(layout.words + 4 * word_count),
		first_character  = FIRST_CHARACTER,
		character_count  = CHARACTER_COUNT,
		size_count       = u32(size_count),
		flags            = (grid_fit ? glyph_cache.FLAG_GRID_FIT : 0) | (proportional ? glyph_cache.FLAG_PROPORTIONAL : 0) | u32(Stripe_Filter.Five_Taps) << glyph_cache.FILTER_SHIFT,
		word_offset      = u64(layout.words),
		word_count       = u64(word_count),
		font_hash        = blake3.hash(font_bytes),
		pair_count       = u32(pair_count),
	}
	// Printable bytes and an end (validate checks it): another byte is a
	// question mark.
	for index in 0 ..< min(len(font_name), len(header.font_name) - 1) {
		byte := font_name[index]
		header.font_name[index] = byte >= 32 && byte <= 126 ? byte : '?'
	}
	return layout.words + 4 * word_count
}

// glyph_cache_build draws the characters 32 to 126 of a monospace font at
// the three scales of the grid and writes a glyph cache file
// (modus:contract/glyph_cache) into the memory of the caller: one position, each
// glyph the full width of its cell, each advance the width of the cell, no
// pair. The kernel tool makes the cache of the boot image with it; a
// program makes its own cache of another font with it. It gives the size
// of the file, or a problem; .Too_Many_Points also when out is too small.
// scale_count: 3 for the text of the system, 1 for a weight that draws only
// at scale 1 (the bold of the card titles).
glyph_cache_build :: proc "contextless" (font: ^Font_File, font_bytes: []u8, font_name: string, grid_fit: bool, memory: ^Render_Memory, out: []u8, scale_count_asked := glyph_cache.SIZE_LIMIT) -> (size: int, problem: Font_Problem) {
	scale_count := clamp(scale_count_asked, 1, glyph_cache.SIZE_LIMIT)
	measures := font_measures(font, memory) or_return
	one_position := [glyph_cache.SIZE_LIMIT]int{1, 1, 1}
	layout := cache_layout_of(one_position[:scale_count], 0)
	tables, ok := cache_tables_of(out, layout, scale_count, 0)
	if !ok {
		return 0, .Too_Many_Points
	}
	word_count := 0
	pixels: [CELL_WIDTH_LIMIT * CELL_HEIGHT_LIMIT]u32
	for scale in 1 ..= scale_count {
		style := glyph_style_of(measures, 8 * scale, 16 * scale, grid_fit)
		tables.sizes[scale - 1] = {cell_width = u16(style.cell_width), cell_height = u16(style.cell_height), baseline = u16(style.baseline), position_count = 1, first_glyph = u32((scale - 1) * CHARACTER_COUNT)}
		for index in 0 ..< CHARACTER_COUNT {
			tables.advances[(scale - 1) * CHARACTER_COUNT + index] = i32(style.cell_width * glyph_cache.SUBPIXEL)
			glyph_render(font, measures, style, rune(FIRST_CHARACTER + index), memory, pixels[:]) or_return
			// Only the rows with ink.
			first, last := style.cell_height, -1
			for row in 0 ..< style.cell_height {
				for word in pixels[row * style.cell_width:][:style.cell_width] {
					if word != 0 {
						first = min(first, row)
						last = max(last, row)
					}
				}
			}
			entry := &tables.glyphs[(scale - 1) * CHARACTER_COUNT + index]
			entry.word_offset = u32(word_count)
			entry.width = u16(style.cell_width)
			if last >= first {
				count := (last - first + 1) * style.cell_width
				if word_count + count > len(tables.words) {
					return 0, .Too_Many_Points
				}
				entry.first_row = u16(first)
				entry.row_count = u16(last - first + 1)
				copy(tables.words[word_count:], pixels[first * style.cell_width:][:count])
				word_count += count
			}
		}
	}
	return cache_header_write(out, font_bytes, font_name, grid_fit, false, layout, scale_count, 0, word_count), .None
}

// glyph_cache_build_proportional draws the characters 32 to 126 of a
// proportional font (docs/FONTS.md, section 12.4) and writes a glyph cache
// file into the memory of the caller: for each scale 1 ..= len(positions),
// each glyph at positions[scale - 1] subpixel positions, each kept as the
// box of its ink; the advance of each character and the pair adjustments of
// its kern table, in 1/64 of a pixel. Each advance and each adjustment is
// rounded once, on its own (units_to_subpixels); a reader adds the
// integers, so the advance of a glyph followed by a pair is the rounded
// advance plus the rounded adjustment, not the rounded sum. It gives the size of the file, or a
// problem; .Too_Many_Points also when out is too small.
glyph_cache_build_proportional :: proc "contextless" (font: ^Font_File, font_bytes: []u8, font_name: string, grid_fit: bool, memory: ^Render_Memory, out: []u8, positions: []int) -> (size: int, problem: Font_Problem) {
	scale_count := len(positions)
	if scale_count < 1 || scale_count > glyph_cache.SIZE_LIMIT {
		return 0, .Unknown_Format
	}
	for count in positions {
		if count < 1 || count > glyph_cache.POSITION_LIMIT {
			return 0, .Unknown_Format
		}
	}
	measures := proportional_measures(font, font_measures(font, memory) or_return) or_return
	pair_table := pair_table_open(font) or_return
	pair_count := 0
	for left in rune(FIRST_CHARACTER) ..< FIRST_CHARACTER + CHARACTER_COUNT {
		for right in rune(FIRST_CHARACTER) ..< FIRST_CHARACTER + CHARACTER_COUNT {
			if character_pair_adjustment(font, &pair_table, left, right) != 0 {
				pair_count += 1
			}
		}
	}
	layout := cache_layout_of(positions, pair_count)
	tables, ok := cache_tables_of(out, layout, scale_count, pair_count)
	if !ok {
		return 0, .Too_Many_Points
	}
	word_count := 0
	first_glyph := 0
	for scale in 1 ..= scale_count {
		style := glyph_style_of(measures, 8 * scale, 16 * scale, grid_fit)
		position_count := positions[scale - 1]
		tables.sizes[scale - 1] = {cell_width = u16(style.cell_width), cell_height = u16(style.cell_height), baseline = u16(style.baseline), position_count = u16(position_count), first_glyph = u32(first_glyph)}
		for index in 0 ..< CHARACTER_COUNT {
			advance := character_advance(font, rune(FIRST_CHARACTER + index))
			tables.advances[(scale - 1) * CHARACTER_COUNT + index] = units_to_subpixels(advance, scale, measures.advance)
		}
		// The pairs in the order of the characters: sorted.
		pair := (scale - 1) * pair_count
		for left in 0 ..< CHARACTER_COUNT {
			for right in 0 ..< CHARACTER_COUNT {
				adjustment := character_pair_adjustment(font, &pair_table, rune(FIRST_CHARACTER + left), rune(FIRST_CHARACTER + right))
				if adjustment != 0 {
					tables.pairs[pair] = {left = u8(FIRST_CHARACTER + left), right = u8(FIRST_CHARACTER + right), adjustment = units_to_subpixels(adjustment, scale, measures.advance)}
					pair += 1
				}
			}
		}
		for position in 0 ..< position_count {
			for index in 0 ..< CHARACTER_COUNT {
				box := glyph_render_placed(font, measures, style, rune(FIRST_CHARACTER + index), position, position_count, memory) or_return
				entry := &tables.glyphs[first_glyph + position * CHARACTER_COUNT + index]
				entry.word_offset = u32(word_count)
				if box.row_count == 0 {
					continue
				}
				count := box.row_count * box.width
				if word_count + count > len(tables.words) {
					return 0, .Too_Many_Points
				}
				entry^ = {first_row = u16(box.first_row), row_count = u16(box.row_count), word_offset = u32(word_count), left = i16(box.left), width = u16(box.width)}
				for row in 0 ..< box.row_count {
					copy(tables.words[word_count + row * box.width:][:box.width], memory.placed[(box.first_row + row) * PLACED_WIDTH_LIMIT + box.first_column:][:box.width])
				}
				word_count += count
			}
		}
		first_glyph += position_count * CHARACTER_COUNT
	}
	return cache_header_write(out, font_bytes, font_name, grid_fit, true, layout, scale_count, pair_count, word_count), .None
}

// GLYPH_CACHE_LIMIT: room for the glyph cache of one monospace font with
// each cell full at the three scales: a caller that gives this much never
// gets a problem of room.
GLYPH_CACHE_LIMIT :: 1024 + 3 * glyph_cache.GLYPH_ENTRY_SIZE * 95 + 3 * glyph_cache.ADVANCE_SIZE * 95 + 4 * 95 * (8 * 16 + 16 * 32 + 24 * 48)

// PROPORTIONAL_GLYPH_CACHE_LIMIT: room for the glyph cache of one
// proportional font at the three scales, each with POSITION_LIMIT
// positions, each glyph as wide as the work row and as high as its line.
PROPORTIONAL_GLYPH_CACHE_LIMIT :: 1024 + 3 * glyph_cache.POSITION_LIMIT * glyph_cache.GLYPH_ENTRY_SIZE * 95 + 3 * glyph_cache.ADVANCE_SIZE * 95 + 3 * glyph_cache.PAIR_LIMIT * glyph_cache.PAIR_ENTRY_SIZE + 4 * glyph_cache.POSITION_LIMIT * 95 * PLACED_WIDTH_LIMIT * (16 + 32 + 48)
