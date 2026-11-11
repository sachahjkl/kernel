// A prototype of a vector font (docs/INTERFACE.md, section 9): a parser of a
// subset of TrueType and a rasterizer with exact area coverage. It is
// research for a decision of the owner, not the font of the system:
// Spleen 8x16 stays (owner, 2026-11-10). It uses floating point, which the
// design rules do not allow for a display (docs/DESIGN.md, section 7): a
// version for the system needs fixed point.
//
// A font file is hostile input: each read is checked against the length of
// the file, and each problem is a value.
package vector_font

Font_Problem :: enum u8 {
	None,
	Too_Short, // A read past the end of the file or of a table.
	Missing_Table, // head, hhea, maxp, hmtx, loca, glyf or cmap is not there.
	Unknown_Format, // No cmap of format 4, or a loca format other than 0 and 1.
	Composite_Glyph, // A glyph made of other glyphs: not in this subset.
	Too_Many_Points, // The glyph has more points or contours than the memory of the caller.
	No_Glyph, // The character has no glyph.
}

// The tables of a font file, as offsets in the file.
Font_File :: struct {
	bytes:                []u8,
	units_per_em:         int,
	ascender, descender:  int,
	glyph_count:          int,
	long_offsets:         bool,
	horizontal_metrics:   int,
	head, hhea, maxp:     Table,
	hmtx, loca, glyf:     Table,
	character_map:        Table, // The cmap subtable of format 4.
}

Table :: struct {
	offset, length: int,
}

// A point of an outline, in units of the font, y up.
Outline_Point :: struct {
	x, y:     f32,
	on_curve: bool,
}

// An outline in the memory of the caller: the points, and the index after
// the last point of each contour.
Outline :: struct {
	points:         []Outline_Point,
	point_count:    int,
	contour_ends:   []int,
	contour_count:  int,
	advance:        int, // The advance width, in units of the font.
}

@(private)
read_u16 :: proc "contextless" (bytes: []u8, at: int) -> (value: int, ok: bool) {
	if at < 0 || at + 2 > len(bytes) {
		return 0, false
	}
	return int(bytes[at]) << 8 | int(bytes[at + 1]), true
}

@(private)
read_i16 :: proc "contextless" (bytes: []u8, at: int) -> (value: int, ok: bool) {
	unsigned := read_u16(bytes, at) or_return
	return unsigned >= 0x8000 ? unsigned - 0x10000 : unsigned, true
}

@(private)
read_u32 :: proc "contextless" (bytes: []u8, at: int) -> (value: int, ok: bool) {
	high := read_u16(bytes, at) or_return
	low := read_u16(bytes, at + 2) or_return
	return high << 16 | low, true
}

// font_open finds the tables of a font file.
font_open :: proc "contextless" (bytes: []u8) -> (font: Font_File, problem: Font_Problem) {
	font.bytes = bytes
	count, ok := read_u16(bytes, 4)
	if !ok {
		return font, .Too_Short
	}
	for index in 0 ..< count {
		record := 12 + index * 16
		if record + 16 > len(bytes) {
			return font, .Too_Short
		}
		offset, _ := read_u32(bytes, record + 8)
		length, _ := read_u32(bytes, record + 12)
		if offset + length > len(bytes) {
			return font, .Too_Short
		}
		table := Table{offset, length}
		switch string(bytes[record:record + 4]) {
		case "head":
			font.head = table
		case "hhea":
			font.hhea = table
		case "maxp":
			font.maxp = table
		case "hmtx":
			font.hmtx = table
		case "loca":
			font.loca = table
		case "glyf":
			font.glyf = table
		case "cmap":
			font.character_map = table
		}
	}
	for table in ([?]Table{font.head, font.hhea, font.maxp, font.hmtx, font.loca, font.glyf, font.character_map}) {
		if table.length == 0 {
			return font, .Missing_Table
		}
	}
	head := bytes[font.head.offset:][:font.head.length]
	font.units_per_em = read_u16(head, 18) or_else 0
	format := read_i16(head, 50) or_else -1
	if font.units_per_em == 0 || format < 0 || format > 1 {
		return font, .Unknown_Format
	}
	font.long_offsets = format == 1
	hhea := bytes[font.hhea.offset:][:font.hhea.length]
	font.ascender = read_i16(hhea, 4) or_else 0
	font.descender = read_i16(hhea, 6) or_else 0
	font.horizontal_metrics = read_u16(hhea, 34) or_else 0
	font.glyph_count = read_u16(bytes[font.maxp.offset:][:font.maxp.length], 4) or_else 0
	// The subtable of format 4 of the cmap (Unicode, the basic plane).
	map_table := bytes[font.character_map.offset:][:font.character_map.length]
	subtables := read_u16(map_table, 2) or_else 0
	found := false
	for index in 0 ..< subtables {
		platform := read_u16(map_table, 4 + index * 8) or_else 0xFFFF
		encoding := read_u16(map_table, 6 + index * 8) or_else 0xFFFF
		offset := read_u32(map_table, 8 + index * 8) or_else len(map_table)
		if (platform == 3 && encoding == 1 || platform == 0) && (read_u16(map_table, offset) or_else 0) == 4 {
			length := read_u16(map_table, offset + 2) or_else 0
			if offset + length > len(map_table) {
				return font, .Too_Short
			}
			font.character_map = {font.character_map.offset + offset, length}
			found = true
			break
		}
	}
	if !found {
		return font, .Unknown_Format
	}
	return font, .None
}

// glyph_of gives the glyph of a character, from the cmap of format 4.
glyph_of :: proc "contextless" (font: ^Font_File, character: rune) -> (glyph: int, problem: Font_Problem) {
	table := font.bytes[font.character_map.offset:][:font.character_map.length]
	segments := (read_u16(table, 6) or_else 0) / 2
	code := int(character)
	for segment in 0 ..< segments {
		end := read_u16(table, 14 + 2 * segment) or_else -1
		if code > end {
			continue
		}
		start := read_u16(table, 16 + 2 * segments + 2 * segment) or_else 0x10000
		if code < start {
			return 0, .No_Glyph
		}
		delta := read_i16(table, 16 + 4 * segments + 2 * segment) or_else 0
		range_place := 16 + 6 * segments + 2 * segment
		range_offset := read_u16(table, range_place) or_else 0
		if range_offset == 0 {
			return (code + delta) & 0xFFFF, .None
		}
		value, ok := read_u16(table, range_place + range_offset + 2 * (code - start))
		if !ok {
			return 0, .Too_Short
		}
		if value == 0 {
			return 0, .No_Glyph
		}
		return (value + delta) & 0xFFFF, .None
	}
	return 0, .No_Glyph
}

// glyph_outline reads the outline of a simple glyph into the memory of the
// caller.
glyph_outline :: proc "contextless" (font: ^Font_File, glyph: int, outline: ^Outline) -> Font_Problem {
	outline.point_count = 0
	outline.contour_count = 0
	if glyph < 0 || glyph >= font.glyph_count {
		return .No_Glyph
	}
	metrics := font.bytes[font.hmtx.offset:][:font.hmtx.length]
	metric := min(glyph, max(font.horizontal_metrics - 1, 0))
	outline.advance = read_u16(metrics, 4 * metric) or_else 0
	loca := font.bytes[font.loca.offset:][:font.loca.length]
	start, end: int
	start_read, end_read: bool
	if font.long_offsets {
		start, start_read = read_u32(loca, 4 * glyph)
		end, end_read = read_u32(loca, 4 * glyph + 4)
	} else {
		start, start_read = read_u16(loca, 2 * glyph)
		end, end_read = read_u16(loca, 2 * glyph + 2)
		start, end = start * 2, end * 2
	}
	if !start_read || !end_read || start > end || end > font.glyf.length {
		return .Too_Short
	}
	if start == end {
		return .None // A glyph with no outline: a space.
	}
	glyph_bytes := font.bytes[font.glyf.offset + start:][:end - start]
	contours, ok := read_i16(glyph_bytes, 0)
	if !ok {
		return .Too_Short
	}
	if contours < 0 {
		return .Composite_Glyph
	}
	if contours > len(outline.contour_ends) {
		return .Too_Many_Points
	}
	points := 0
	for contour in 0 ..< contours {
		last, read := read_u16(glyph_bytes, 10 + 2 * contour)
		if !read {
			return .Too_Short
		}
		if last + 1 <= points {
			return .Unknown_Format // The ends must grow.
		}
		points = last + 1
		outline.contour_ends[contour] = points
	}
	if points > len(outline.points) {
		return .Too_Many_Points
	}
	instructions, read := read_u16(glyph_bytes, 10 + 2 * contours)
	if !read {
		return .Too_Short
	}
	at := 12 + 2 * contours + instructions
	// The flags, with their repeats.
	flags: [512]u8
	if points > len(flags) {
		return .Too_Many_Points
	}
	for index := 0; index < points; {
		if at >= len(glyph_bytes) {
			return .Too_Short
		}
		flag := glyph_bytes[at]
		at += 1
		repeat := 1
		if flag & 8 != 0 {
			if at >= len(glyph_bytes) {
				return .Too_Short
			}
			repeat += int(glyph_bytes[at])
			at += 1
		}
		for _ in 0 ..< repeat {
			if index >= points {
				return .Unknown_Format
			}
			flags[index] = flag
			index += 1
		}
	}
	// The x coordinates, then the y coordinates, as differences.
	for axis in 0 ..< 2 {
		short_bit := u8(axis == 0 ? 2 : 4)
		same_bit := u8(axis == 0 ? 16 : 32)
		value := 0
		for index in 0 ..< points {
			flag := flags[index]
			switch {
			case flag & short_bit != 0:
				if at >= len(glyph_bytes) {
					return .Too_Short
				}
				step := int(glyph_bytes[at])
				at += 1
				value += flag & same_bit != 0 ? step : -step
			case flag & same_bit == 0:
				step, step_read := read_i16(glyph_bytes, at)
				if !step_read {
					return .Too_Short
				}
				at += 2
				value += step
			}
			if axis == 0 {
				outline.points[index].x = f32(value)
				outline.points[index].on_curve = flag & 1 != 0
			} else {
				outline.points[index].y = f32(value)
			}
		}
	}
	outline.point_count = points
	outline.contour_count = contours
	return .None
}
