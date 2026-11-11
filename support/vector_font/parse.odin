// The vector font of the system (docs/FONTS.md): a reader of a subset of
// TrueType, and a rasterizer in fixed point with coverage for each color
// stripe. The kernel tool uses it at build time to make the glyph cache;
// a program uses it to draw a glyph from its outline.
//
// A font file is hostile input: each read is checked against the length of
// the file, and each problem is a value. No floating point: a result does
// not depend on the build.
package vector_font

Font_Problem :: enum u8 {
	None,
	Too_Short, // A read past the end of the file or of a table.
	Missing_Table, // head, hhea, maxp, hmtx, loca, glyf or cmap is not there.
	Unknown_Format, // No cmap of format 4, a loca format other than 0 and 1, or a glyph that breaks a rule of the format.
	Composite_Too_Deep, // A glyph made of glyphs, more than COMPOSITE_DEPTH levels deep.
	Too_Many_Points, // The glyph has more points or contours than the memory of the caller.
	No_Glyph, // The character has no glyph.
}

font_problem_names := [Font_Problem]string {
	.None               = "none",
	.Too_Short          = "a read passes the end of the file or of a table",
	.Missing_Table      = "a table that the reader needs is not in the file",
	.Unknown_Format     = "a table or a glyph has a form that the reader does not know",
	.Composite_Too_Deep = "a glyph made of glyphs is too deep",
	.Too_Many_Points    = "a glyph has more points or contours than the memory of the caller",
	.No_Glyph           = "the character has no glyph",
}

// The tables of a font file, as offsets in the file.
Font_File :: struct {
	bytes:               []u8,
	units_per_em:        int,
	ascender, descender: int,
	glyph_count:         int,
	long_offsets:        bool,
	horizontal_metrics:  int,
	head, hhea, maxp:    Table,
	hmtx, loca, glyf:    Table,
	character_map:       Table, // The cmap subtable of format 4.
	name, os2, post:     Table, // Read by the tool only.
}

Table :: struct {
	offset, length: int,
}

// A point of an outline, in units of the font, y up.
Outline_Point :: struct {
	x, y:     i32,
	on_curve: bool,
}

// An outline in the memory of the caller: the points, and the index after
// the last point of each contour.
Outline :: struct {
	points:        []Outline_Point,
	point_count:   int,
	contour_ends:  []int,
	contour_count: int,
	advance:       int, // The advance width, in units of the font.
}

// A glyph made of glyphs can name glyphs made of glyphs: at most this deep.
COMPOSITE_DEPTH :: 4
// The flags of one simple glyph are read into a table of this size.
POINT_LIMIT :: 1024

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

// collection_face_offset gives the place of the table directory of one face
// of a TrueType collection ("ttcf"), or 0 for a file with one face.
collection_face_offset :: proc "contextless" (bytes: []u8, face: int) -> (offset: int, problem: Font_Problem) {
	if len(bytes) >= 4 && string(bytes[:4]) == "ttcf" {
		count := read_u32(bytes, 8) or_else 0
		if face < 0 || face >= count {
			return 0, .No_Glyph
		}
		place, ok := read_u32(bytes, 12 + 4 * face)
		if !ok {
			return 0, .Too_Short
		}
		return place, .None
	}
	return 0, .None
}

// font_open finds the tables of a font file. directory is the place of the
// table directory: 0, or the place of a face of a collection.
font_open :: proc "contextless" (bytes: []u8, directory: int = 0) -> (font: Font_File, problem: Font_Problem) {
	font.bytes = bytes
	count, ok := read_u16(bytes, directory + 4)
	if !ok {
		return font, .Too_Short
	}
	for index in 0 ..< count {
		record := directory + 12 + index * 16
		if record < 0 || record + 16 > len(bytes) {
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
		case "name":
			font.name = table
		case "OS/2":
			font.os2 = table
		case "post":
			font.post = table
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
	if font.units_per_em < 16 || format < 0 || format > 1 {
		return font, .Unknown_Format
	}
	font.long_offsets = format == 1
	hhea := bytes[font.hhea.offset:][:font.hhea.length]
	font.ascender = read_i16(hhea, 4) or_else 0
	font.descender = read_i16(hhea, 6) or_else 0
	font.horizontal_metrics = read_u16(hhea, 34) or_else 0
	font.glyph_count = read_u16(bytes[font.maxp.offset:][:font.maxp.length], 4) or_else 0
	if font.horizontal_metrics == 0 || font.horizontal_metrics * 4 > font.hmtx.length {
		return font, .Too_Short
	}
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
			glyph = (code + delta) & 0xFFFF
		} else {
			value, ok := read_u16(table, range_place + range_offset + 2 * (code - start))
			if !ok {
				return 0, .Too_Short
			}
			if value == 0 {
				return 0, .No_Glyph
			}
			glyph = (value + delta) & 0xFFFF
		}
		if glyph == 0 || glyph >= font.glyph_count {
			return 0, .No_Glyph
		}
		return glyph, .None
	}
	return 0, .No_Glyph
}

// glyph_advance gives the advance width of a glyph, in units of the font.
glyph_advance :: proc "contextless" (font: ^Font_File, glyph: int) -> int {
	metrics := font.bytes[font.hmtx.offset:][:font.hmtx.length]
	metric := clamp(glyph, 0, font.horizontal_metrics - 1)
	return read_u16(metrics, 4 * metric) or_else 0
}

// glyph_data gives the bytes of a glyph in the glyf table; empty for a
// glyph with no outline (a space).
@(private)
glyph_data :: proc "contextless" (font: ^Font_File, glyph: int) -> (data: []u8, problem: Font_Problem) {
	if glyph < 0 || glyph >= font.glyph_count {
		return nil, .No_Glyph
	}
	loca := font.bytes[font.loca.offset:][:font.loca.length]
	start, end: int
	ok_start, ok_end: bool
	if font.long_offsets {
		start, ok_start = read_u32(loca, 4 * glyph)
		end, ok_end = read_u32(loca, 4 * glyph + 4)
	} else {
		start, ok_start = read_u16(loca, 2 * glyph)
		end, ok_end = read_u16(loca, 2 * glyph + 2)
		start, end = start * 2, end * 2
	}
	if !ok_start || !ok_end || start > end || end > font.glyf.length {
		return nil, .Too_Short
	}
	return font.bytes[font.glyf.offset + start:][:end - start], .None
}

// glyph_outline reads the outline of a glyph into the memory of the caller.
// A glyph made of other glyphs (a composite) becomes one outline: each part
// moved and scaled by its record, with whole units of the font.
glyph_outline :: proc "contextless" (font: ^Font_File, glyph: int, outline: ^Outline) -> Font_Problem {
	outline.point_count = 0
	outline.contour_count = 0
	if glyph < 0 || glyph >= font.glyph_count {
		return .No_Glyph
	}
	outline.advance = glyph_advance(font, glyph)
	return glyph_outline_add(font, glyph, outline, {65536, 0, 0, 65536, 0, 0}, 0)
}

// A transform of the points of a part of a composite: x' = a x + c y + e,
// y' = b x + d y + f, with a, b, c, d in 1/65536.
@(private)
Part_Transform :: struct {
	a, b, c, d: i64,
	e, f:       i64,
}

@(private)
glyph_outline_add :: proc "contextless" (font: ^Font_File, glyph: int, outline: ^Outline, transform: Part_Transform, depth: int) -> Font_Problem {
	data := glyph_data(font, glyph) or_return
	if len(data) == 0 {
		return .None // A glyph with no outline: a space.
	}
	contours, ok := read_i16(data, 0)
	if !ok {
		return .Too_Short
	}
	if contours >= 0 {
		return simple_glyph_add(data, contours, outline, transform)
	}
	if depth >= COMPOSITE_DEPTH {
		return .Composite_Too_Deep
	}
	// The parts: a flag word, a glyph, two offsets, then a scale. A read
	// past the end gives 0 from read_part and sets the flag short.
	short := false
	read_part :: proc "contextless" (data: []u8, at: int, short: ^bool) -> int {
		value, ok := read_i16(data, at)
		if !ok {
			short^ = true
		}
		return value
	}
	at := 10
	for {
		flags := read_part(data, at, &short) & 0xFFFF
		part := read_part(data, at + 2, &short) & 0xFFFF
		at += 4
		dx, dy: int
		if flags & 0x0001 != 0 {
			dx = read_part(data, at, &short)
			dy = read_part(data, at + 2, &short)
			at += 4
		} else {
			if at + 2 > len(data) {
				return .Too_Short
			}
			dx = int(i8(data[at]))
			dy = int(i8(data[at + 1]))
			at += 2
		}
		if short {
			return .Too_Short
		}
		if flags & 0x0002 == 0 {
			return .Unknown_Format // Parts placed by points: not in this subset.
		}
		// A scale in 2.14: 16384 is 1.
		a, b, c, d := 16384, 0, 0, 16384
		switch {
		case flags & 0x0008 != 0:
			a = read_part(data, at, &short)
			d = a
			at += 2
		case flags & 0x0040 != 0:
			a = read_part(data, at, &short)
			d = read_part(data, at + 2, &short)
			at += 4
		case flags & 0x0080 != 0:
			a = read_part(data, at, &short)
			b = read_part(data, at + 2, &short)
			c = read_part(data, at + 4, &short)
			d = read_part(data, at + 6, &short)
			at += 8
		}
		if short {
			return .Too_Short
		}
		// The part transform, then the transform of the caller.
		inner := Part_Transform{i64(a) * 4, i64(b) * 4, i64(c) * 4, i64(d) * 4, i64(dx), i64(dy)}
		combined := Part_Transform {
			a = (transform.a * inner.a + transform.c * inner.b) / 65536,
			b = (transform.b * inner.a + transform.d * inner.b) / 65536,
			c = (transform.a * inner.c + transform.c * inner.d) / 65536,
			d = (transform.b * inner.c + transform.d * inner.d) / 65536,
			e = (transform.a * inner.e + transform.c * inner.f) / 65536 + transform.e,
			f = (transform.b * inner.e + transform.d * inner.f) / 65536 + transform.f,
		}
		glyph_outline_add(font, part, outline, combined, depth + 1) or_return
		if flags & 0x0020 == 0 {
			break
		}
	}
	return .None
}

@(private)
simple_glyph_add :: proc "contextless" (data: []u8, contours: int, outline: ^Outline, transform: Part_Transform) -> Font_Problem {
	first_point := outline.point_count
	if outline.contour_count + contours > len(outline.contour_ends) {
		return .Too_Many_Points
	}
	points := 0
	for contour in 0 ..< contours {
		last, read := read_u16(data, 10 + 2 * contour)
		if !read {
			return .Too_Short
		}
		if last + 1 <= points {
			return .Unknown_Format // The ends must grow.
		}
		points = last + 1
	}
	if points > POINT_LIMIT || first_point + points > len(outline.points) {
		return .Too_Many_Points
	}
	for contour in 0 ..< contours {
		last, _ := read_u16(data, 10 + 2 * contour)
		outline.contour_ends[outline.contour_count + contour] = first_point + last + 1
	}
	instructions, read := read_u16(data, 10 + 2 * contours)
	if !read {
		return .Too_Short
	}
	at := 12 + 2 * contours + instructions
	// The flags, with their repeats.
	flags: [POINT_LIMIT]u8
	for index := 0; index < points; {
		if at >= len(data) {
			return .Too_Short
		}
		flag := data[at]
		at += 1
		repeat := 1
		if flag & 8 != 0 {
			if at >= len(data) {
				return .Too_Short
			}
			repeat += int(data[at])
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
				if at >= len(data) {
					return .Too_Short
				}
				step := int(data[at])
				at += 1
				value += flag & same_bit != 0 ? step : -step
			case flag & same_bit == 0:
				step, step_read := read_i16(data, at)
				if !step_read {
					return .Too_Short
				}
				at += 2
				value += step
			}
			point := &outline.points[first_point + index]
			if axis == 0 {
				point.x = i32(value)
				point.on_curve = flag & 1 != 0
			} else {
				point.y = i32(value)
			}
		}
	}
	// The transform of a part of a composite; none for a glyph alone.
	if transform != {65536, 0, 0, 65536, 0, 0} {
		for &point in outline.points[first_point:][:points] {
			x, y := i64(point.x), i64(point.y)
			point.x = i32(clamp((transform.a * x + transform.c * y + 32768) >> 16 + transform.e, -32768, 32767))
			point.y = i32(clamp((transform.b * x + transform.d * y + 32768) >> 16 + transform.f, -32768, 32767))
		}
	}
	outline.point_count += points
	outline.contour_count += contours
	return .None
}
