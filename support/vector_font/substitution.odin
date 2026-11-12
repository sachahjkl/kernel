package vector_font

// One form of the substitutions of the table GSUB (OpenType): the single
// substitution (lookup type 1, or type 7 that holds a type 1) of a feature,
// such as "zero", whose lookup maps the glyph of '0' to a slashed zero. The
// kernel tool uses it to put that form of a glyph in a subset
// (docs/FONTS.md, section 6, "The zero of Paper Mono").
//
// The feature is found as a shaper finds it: in the default language
// system of the script DFLT, or of the script latn when DFLT is absent.
//
// The table is hostile input like the rest of the file: each offset is
// checked against the length of the table before a read, each count
// bounds its loop, and the work is bounded: at most SUBSTITUTION_FEATURE_LIMIT
// features of the tag, SUBSTITUTION_LOOKUP_LIMIT lookups of a feature,
// SUBSTITUTION_SUBTABLE_LIMIT subtables of a lookup, and a binary search
// in each coverage (a coverage out of order gives no glyph, never a read
// out of the table).

SUBSTITUTION_FEATURE_LIMIT :: 16
SUBSTITUTION_LOOKUP_LIMIT :: 64
SUBSTITUTION_SUBTABLE_LIMIT :: 64

// A tag of four bytes, as the table writes it.
Feature_Tag :: [4]u8

// part_at gives the bytes of a table from an offset that the table holds:
// false when the offset passes its end.
@(private)
part_at :: proc "contextless" (bytes: []u8, at: int) -> (part: []u8, ok: bool) {
	if at < 0 || at > len(bytes) {
		return nil, false
	}
	return bytes[at:], true
}

@(private)
tag_at :: proc "contextless" (bytes: []u8, at: int) -> (tag: Feature_Tag, ok: bool) {
	if at < 0 || at + 4 > len(bytes) {
		return {}, false
	}
	return {bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]}, true
}

// single_substitution gives the glyph that the feature `tag` puts in the
// place of `glyph` by a single substitution. .No_Feature when the font has
// no table GSUB, no such feature in its default language system, or no
// single substitution of the glyph in its lookups.
single_substitution :: proc "contextless" (font: ^Font_File, tag: Feature_Tag, glyph: int) -> (substitute: int, problem: Font_Problem) {
	if font.gsub.length == 0 {
		return 0, .No_Feature
	}
	if font.gsub.offset < 0 || font.gsub.length < 0 || font.gsub.offset + font.gsub.length > len(font.bytes) {
		return 0, .Too_Short
	}
	table := font.bytes[font.gsub.offset:][:font.gsub.length]
	major, major_read := read_u16(table, 0)
	minor, minor_read := read_u16(table, 2)
	script_list_offset, script_read := read_u16(table, 4)
	feature_list_offset, feature_read := read_u16(table, 6)
	lookup_list_offset, lookup_read := read_u16(table, 8)
	if !major_read || !minor_read || !script_read || !feature_read || !lookup_read {
		return 0, .Too_Short
	}
	if major != 1 || minor > 1 {
		return 0, .Unknown_Format
	}
	script_list, script_list_ok := part_at(table, script_list_offset)
	feature_list, feature_list_ok := part_at(table, feature_list_offset)
	lookup_list, lookup_list_ok := part_at(table, lookup_list_offset)
	if !script_list_ok || !feature_list_ok || !lookup_list_ok {
		return 0, .Too_Short
	}
	// The default language system of DFLT, else of latn.
	language_system: []u8
	system_found := false
	script_count := read_u16(script_list, 0) or_else 0
	for wanted in ([2]Feature_Tag{{'D', 'F', 'L', 'T'}, {'l', 'a', 't', 'n'}}) {
		for index in 0 ..< script_count {
			script_tag, tag_read := tag_at(script_list, 2 + 6 * index)
			script_offset, offset_read := read_u16(script_list, 6 + 6 * index)
			if !tag_read || !offset_read {
				return 0, .Too_Short
			}
			if script_tag != wanted {
				continue
			}
			script, script_ok := part_at(script_list, script_offset)
			default_offset, default_read := read_u16(script, 0)
			if !script_ok || !default_read {
				return 0, .Too_Short
			}
			if default_offset != 0 {
				system_part, system_ok := part_at(script, default_offset)
				if !system_ok {
					return 0, .Too_Short
				}
				language_system = system_part
				system_found = true
			}
			break
		}
		if system_found {
			break
		}
	}
	if !system_found {
		return 0, .No_Feature
	}
	// The features of the language system with the tag, then their lookups.
	feature_count := read_u16(feature_list, 0) or_else 0
	index_count, index_count_read := read_u16(language_system, 4)
	if !index_count_read {
		return 0, .Too_Short
	}
	lookup_count := read_u16(lookup_list, 0) or_else 0
	features_seen := 0
	for index_number in 0 ..< index_count {
		feature_index, index_read := read_u16(language_system, 6 + 2 * index_number)
		if !index_read {
			return 0, .Too_Short
		}
		if feature_index >= feature_count {
			return 0, .Unknown_Format
		}
		feature_tag, feature_tag_read := tag_at(feature_list, 2 + 6 * feature_index)
		feature_offset, feature_offset_read := read_u16(feature_list, 6 + 6 * feature_index)
		if !feature_tag_read || !feature_offset_read {
			return 0, .Too_Short
		}
		if feature_tag != tag {
			continue
		}
		features_seen += 1
		if features_seen > SUBSTITUTION_FEATURE_LIMIT {
			break
		}
		feature, feature_ok := part_at(feature_list, feature_offset)
		lookups_of_feature, lookups_read := read_u16(feature, 2)
		if !feature_ok || !lookups_read {
			return 0, .Too_Short
		}
		for lookup_number in 0 ..< min(lookups_of_feature, SUBSTITUTION_LOOKUP_LIMIT) {
			lookup_index, lookup_index_read := read_u16(feature, 4 + 2 * lookup_number)
			if !lookup_index_read {
				return 0, .Too_Short
			}
			if lookup_index >= lookup_count {
				return 0, .Unknown_Format
			}
			lookup_offset, lookup_offset_read := read_u16(lookup_list, 2 + 2 * lookup_index)
			lookup, lookup_ok := part_at(lookup_list, lookup_offset)
			if !lookup_offset_read || !lookup_ok {
				return 0, .Too_Short
			}
			found, lookup_problem := lookup_single_substitution(lookup, glyph, &substitute)
			if lookup_problem != .None {
				return 0, lookup_problem
			}
			if found {
				if substitute <= 0 || substitute >= font.glyph_count {
					return 0, .Unknown_Format
				}
				return substitute, .None
			}
		}
	}
	return 0, .No_Feature
}

// lookup_single_substitution reads one lookup: type 1, or type 7 (an
// extension) that holds a type 1. Another type substitutes nothing here.
@(private)
lookup_single_substitution :: proc "contextless" (lookup: []u8, glyph: int, substitute: ^int) -> (found: bool, problem: Font_Problem) {
	lookup_type, type_read := read_u16(lookup, 0)
	subtable_count, count_read := read_u16(lookup, 4)
	if !type_read || !count_read {
		return false, .Too_Short
	}
	if lookup_type != 1 && lookup_type != 7 {
		return false, .None
	}
	for number in 0 ..< min(subtable_count, SUBSTITUTION_SUBTABLE_LIMIT) {
		subtable_offset, offset_read := read_u16(lookup, 6 + 2 * number)
		subtable, subtable_ok := part_at(lookup, subtable_offset)
		if !offset_read || !subtable_ok {
			return false, .Too_Short
		}
		if lookup_type == 7 {
			// An extension: format 1, the type of the lookup that it holds,
			// and a 32-bit offset from the extension to that subtable.
			extension_format, extension_format_read := read_u16(subtable, 0)
			held_type, held_read := read_u16(subtable, 2)
			held_offset, held_offset_read := read_u32(subtable, 4)
			if !extension_format_read || !held_read || !held_offset_read {
				return false, .Too_Short
			}
			if extension_format != 1 {
				return false, .Unknown_Format
			}
			if held_type != 1 {
				continue
			}
			subtable, subtable_ok = part_at(subtable, held_offset)
			if !subtable_ok {
				return false, .Too_Short
			}
		}
		format, format_read := read_u16(subtable, 0)
		coverage_offset, coverage_read := read_u16(subtable, 2)
		coverage, coverage_ok := part_at(subtable, coverage_offset)
		if !format_read || !coverage_read || !coverage_ok {
			return false, .Too_Short
		}
		coverage_index := coverage_index_of(coverage, glyph) or_return
		if coverage_index < 0 {
			continue
		}
		switch format {
		case 1:
			delta, delta_read := read_i16(subtable, 4)
			if !delta_read {
				return false, .Too_Short
			}
			substitute^ = (glyph + delta) & 0xFFFF
			return true, .None
		case 2:
			glyph_count, glyph_count_read := read_u16(subtable, 4)
			if !glyph_count_read {
				return false, .Too_Short
			}
			if coverage_index >= glyph_count {
				return false, .Unknown_Format
			}
			value, value_read := read_u16(subtable, 6 + 2 * coverage_index)
			if !value_read {
				return false, .Too_Short
			}
			substitute^ = value
			return true, .None
		case:
			return false, .Unknown_Format
		}
	}
	return false, .None
}

// coverage_index_of gives the index of a glyph in a coverage table, or -1:
// a binary search in format 1 (a sorted list of glyphs) and in format 2
// (sorted ranges, each with the coverage index of its first glyph).
@(private)
coverage_index_of :: proc "contextless" (coverage: []u8, glyph: int) -> (index: int, problem: Font_Problem) {
	format, format_read := read_u16(coverage, 0)
	count, count_read := read_u16(coverage, 2)
	if !format_read || !count_read {
		return -1, .Too_Short
	}
	low, high := 0, count
	switch format {
	case 1:
		if 4 + 2 * count > len(coverage) {
			return -1, .Too_Short
		}
		for low < high {
			middle := low + (high - low) / 2
			value := read_u16(coverage, 4 + 2 * middle) or_else 0
			switch {
			case value == glyph:
				return middle, .None
			case value < glyph:
				low = middle + 1
			case:
				high = middle
			}
		}
	case 2:
		if 4 + 6 * count > len(coverage) {
			return -1, .Too_Short
		}
		for low < high {
			middle := low + (high - low) / 2
			start := read_u16(coverage, 4 + 6 * middle) or_else 0
			end := read_u16(coverage, 6 + 6 * middle) or_else 0
			switch {
			case glyph < start:
				high = middle
			case glyph > end:
				low = middle + 1
			case:
				first_index := read_u16(coverage, 8 + 6 * middle) or_else 0
				return first_index + glyph - start, .None
			}
		}
	case:
		return -1, .Unknown_Format
	}
	return -1, .None
}
