package vector_font

import "contract:blake3"
import "contract:glyph_cache"

// glyph_cache_build draws the characters 32 to 126 of a font at the three
// scales of the grid and writes a glyph cache file (contract:glyph_cache)
// into the memory of the caller. The kernel tool makes the cache of the boot
// image with it; a program makes its own cache of another font with it. It
// gives the size of the file, or a problem; .Too_Many_Points also when out
// is too small.
// scale_count: 3 for the text of the system, 1 for a weight that draws only
// at scale 1 (the bold of the card titles).
glyph_cache_build :: proc "contextless" (font: ^Font_File, font_bytes: []u8, font_name: string, grid_fit: bool, memory: ^Render_Memory, out: []u8, scale_count_asked := glyph_cache.SIZE_LIMIT) -> (size: int, problem: Font_Problem) {
	scale_count := clamp(scale_count_asked, 1, glyph_cache.SIZE_LIMIT)
	measures := font_measures(font, memory) or_return
	FIRST :: 32
	COUNT :: glyph_cache.CHARACTER_LIMIT
	sizes_place := glyph_cache.HEADER_SIZE
	glyphs_place := sizes_place + scale_count * glyph_cache.SIZE_ENTRY_SIZE
	word_place := (glyphs_place + scale_count * COUNT * glyph_cache.GLYPH_ENTRY_SIZE + 63) / 64 * 64
	if len(out) < word_place || uintptr(raw_data(out)) % 8 != 0 {
		return 0, .Too_Many_Points
	}
	for &byte in out[:word_place] {
		byte = 0
	}
	sizes := ([^]glyph_cache.Size_Entry)(raw_data(out[sizes_place:]))[:scale_count]
	entries := ([^]glyph_cache.Glyph_Entry)(raw_data(out[glyphs_place:]))[:scale_count * COUNT]
	words := ([^]u32)(raw_data(out[word_place:]))[:(len(out) - word_place) / 4]
	word_count := 0
	pixels: [CELL_WIDTH_LIMIT * CELL_HEIGHT_LIMIT]u32
	for scale in 1 ..= scale_count {
		style := glyph_style_of(measures, 8 * scale, 16 * scale, grid_fit)
		sizes[scale - 1] = {cell_width = u16(style.cell_width), cell_height = u16(style.cell_height), baseline = u16(style.baseline), first_glyph = u32((scale - 1) * COUNT)}
		for index in 0 ..< COUNT {
			glyph_render(font, measures, style, rune(FIRST + index), memory, pixels[:]) or_return
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
			entry := &entries[(scale - 1) * COUNT + index]
			entry.word_offset = u32(word_count)
			if last >= first {
				count := (last - first + 1) * style.cell_width
				if word_count + count > len(words) {
					return 0, .Too_Many_Points
				}
				entry.first_row = u16(first)
				entry.row_count = u16(last - first + 1)
				copy(words[word_count:], pixels[first * style.cell_width:][:count])
				word_count += count
			}
		}
	}
	header := (^glyph_cache.Header)(raw_data(out))
	header^ = {
		magic            = glyph_cache.MAGIC,
		version          = glyph_cache.VERSION,
		renderer_version = RENDERER_VERSION,
		file_size        = u64(word_place + 4 * word_count),
		first_character  = FIRST,
		character_count  = COUNT,
		size_count       = u32(scale_count),
		flags            = (grid_fit ? glyph_cache.FLAG_GRID_FIT : 0) | u32(Stripe_Filter.Five_Taps) << 8,
		word_offset      = u64(word_place),
		word_count       = u64(word_count),
		font_hash        = blake3.hash(font_bytes),
	}
	copy(header.font_name[:31], font_name)
	return word_place + 4 * word_count, .None
}

// GLYPH_CACHE_LIMIT: room for the glyph cache of one font with each cell
// full at the three scales: a caller that gives this much never gets a
// problem of room.
GLYPH_CACHE_LIMIT :: 1024 + 3 * 2 * 8 * 95 + 4 * 95 * (8 * 16 + 16 * 32 + 24 * 48)
