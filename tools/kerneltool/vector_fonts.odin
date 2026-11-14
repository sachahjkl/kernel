package kerneltool

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "contract:glyph_cache"
import "support:vector_font"

// The vector fonts of the system (docs/FONTS.md).
//
// The command "vector_fonts" reads the font files of the candidates from
// the build inputs of flake.nix (VECTOR_FONT_SOURCES), and writes for each
// one a subset in resources/fonts: the characters 32 to 126 and the glyph
// .notdef, each glyph a simple glyph with no hinting instructions. The
// subsets are in the repository, as the output of the command "font" is:
// a build does not need the build inputs. The command also writes
// build/fonts/candidates.png, the picture of the choice, from the same
// renderer as the system.
//
// The build makes the glyph caches of the default font and of the interface font (build_glyph_caches):
// the boot image holds it as the resource "glyph_cache".

VECTOR_FONT_SOURCES_VARIABLE :: "VECTOR_FONT_SOURCES"
VECTOR_FONT_FOLDER :: "resources/fonts"
VECTOR_FONT_BUILD_FOLDER :: BUILD_FOLDER + "/fonts"
GLYPH_CACHE_OUTPUT :: VECTOR_FONT_BUILD_FOLDER + "/glyph_cache.bin"
GLYPH_CACHE_RESOURCE :: "glyph_cache"
GLYPH_CACHE_WITHOUT_GRID_FIT_OUTPUT :: VECTOR_FONT_BUILD_FOLDER + "/glyph_cache_no_grid_fit.bin"
GLYPH_CACHE_WITHOUT_GRID_FIT_RESOURCE :: "glyph_cache_no_grid_fit"
GLYPH_CACHE_BOLD_OUTPUT :: VECTOR_FONT_BUILD_FOLDER + "/glyph_cache_bold.bin"
GLYPH_CACHE_BOLD_RESOURCE :: "glyph_cache_bold"
CANDIDATES_PICTURE :: VECTOR_FONT_BUILD_FOLDER + "/candidates.png"
INTERFACE_GLYPH_CACHE_OUTPUT :: VECTOR_FONT_BUILD_FOLDER + "/interface_glyph_cache.bin"
INTERFACE_GLYPH_CACHE_BOLD_OUTPUT :: VECTOR_FONT_BUILD_FOLDER + "/interface_glyph_cache_bold.bin"
INTERFACE_GLYPH_CACHE_RESOURCE :: "interface_glyph_cache"
INTERFACE_GLYPH_CACHE_BOLD_RESOURCE :: "interface_glyph_cache_bold"

// The default font of the system: one line to change (docs/FONTS.md, "The
// font file").
DEFAULT_VECTOR_FONT :: "paper_mono"

// The candidates, in the order of the picture. family: the name that the
// subset carries. A font with a Reserved Font Name (SIL OFL 1.1) is renamed
// in its subset: a subset is a Modified Version (OFL FAQ 2.6).
Vector_Font_Candidate :: struct {
	name:         string, // The file name in resources/fonts, and the key in VECTOR_FONT_SOURCES.
	family:       string,
	license:      string,
	license_file: string, // The full text of the license, in resources/fonts.
	zero_form:    Zero_Form,
}

// The form of the zero in a subset. Slashed: the glyph that the feature
// "zero" of the table GSUB gives for '0' (a single substitution), read from
// the font file; a font with no such feature keeps its zero, and the tool
// says so. The default zero of Paper Mono looks like its capital O.
Zero_Form :: enum u8 {
	Of_The_Font,
	Slashed,
}
ZERO_FEATURE :: vector_font.Feature_Tag{'z', 'e', 'r', 'o'}

vector_font_candidates := [?]Vector_Font_Candidate {
	{"paper_mono", "Paper Mono ASCII", "SIL OFL 1.1, no Reserved Font Name", "OFL.txt", .Slashed},
	{"dejavu_sans_mono", "DejaVu Sans Mono ASCII", "Bitstream Vera license; DejaVu changes in the public domain", "BITSTREAM_VERA_LICENSE.txt", .Of_The_Font},
	{"jetbrains_mono", "JetBrains Mono ASCII", "SIL OFL 1.1, no Reserved Font Name", "OFL.txt", .Of_The_Font},
	{"ibm_mono", "IBM Mono ASCII", "SIL OFL 1.1, Reserved Font Name Plex: renamed", "OFL.txt", .Of_The_Font},
	{"fira_mono", "Fira Mono ASCII", "SIL OFL 1.1", "OFL.txt", .Of_The_Font},
	{"commit_mono", "CommitMono ASCII", "SIL OFL 1.1 in the font file; MIT in its repository", "OFL.txt", .Of_The_Font},
	{"iosevka", "Iosevka ASCII", "SIL OFL 1.1, no Reserved Font Name", "OFL.txt", .Of_The_Font},
}

// The weight of the default font for emphasis (the titles of the cards):
// subset with the candidates, drawn at scale 1 only. Paper Mono has a
// SemiBold and no Bold: the SemiBold is the emphasis.
vector_font_emphasis := [?]Vector_Font_Candidate {
	{"paper_mono_semibold", "Paper Mono ASCII SemiBold", "SIL OFL 1.1, no Reserved Font Name", "OFL.txt", .Slashed},
}
EMPHASIS_VECTOR_FONT :: "paper_mono_semibold"

// The interface font (docs/FONTS.md, section 12): proportional, its two
// weights. Not a candidate of the picture: the grid of cells is not its
// place.
vector_font_interface := [?]Vector_Font_Candidate {
	{"b612", "B612 ASCII", "SIL OFL 1.1, no Reserved Font Name", "OFL.txt", .Of_The_Font},
	{"b612_bold", "B612 ASCII Bold", "SIL OFL 1.1, no Reserved Font Name", "OFL.txt", .Of_The_Font},
}
INTERFACE_VECTOR_FONT :: "b612"
INTERFACE_EMPHASIS_VECTOR_FONT :: "b612_bold"

run_vector_fonts :: proc(args: []string) -> int {
	sources := os.get_env(VECTOR_FONT_SOURCES_VARIABLE, context.temp_allocator)
	if sources == "" {
		fmt.eprintln("kerneltool: " + VECTOR_FONT_SOURCES_VARIABLE + " is not set. Use the development shell: nix develop")
		return EXIT_FAILURE
	}
	make_folder(VECTOR_FONT_FOLDER)
	make_folder(VECTOR_FONT_BUILD_FOLDER)
	fmt.printfln("%-18s %10s %8s %10s %8s %8s %8s %6s %s", "font", "source", "subset", "composite", "advance", "x-height", "cap", "pairs", "zero")
	// proportional: each character has its own advance; the subset keeps
	// the pair adjustments of kern.
	Subset_Request :: struct {
		candidate:    Vector_Font_Candidate,
		proportional: bool,
	}
	all := make([dynamic]Subset_Request, context.temp_allocator)
	for candidate in vector_font_candidates {
		append(&all, Subset_Request{candidate, false})
	}
	for candidate in vector_font_emphasis {
		append(&all, Subset_Request{candidate, false})
	}
	for candidate in vector_font_interface {
		append(&all, Subset_Request{candidate, true})
	}
	for request in all {
		candidate := request.candidate
		path := ""
		rest := sources
		for item in strings.split_iterator(&rest, ";") {
			if strings.has_prefix(item, strings.concatenate({candidate.name, "="}, context.temp_allocator)) {
				path = item[len(candidate.name) + 1:]
			}
		}
		if path == "" {
			fmt.eprintfln("kerneltool: %s has no %s", VECTOR_FONT_SOURCES_VARIABLE, candidate.name)
			return EXIT_FAILURE
		}
		source, read := read_file(path)
		if !read {
			return EXIT_FAILURE
		}
		subset, report, ok := font_subset(source, candidate, request.proportional)
		if !ok {
			fmt.eprintfln("kerneltool: %s: %s", path, report.problem)
			return EXIT_FAILURE
		}
		output := join(VECTOR_FONT_FOLDER, "/", candidate.name, ".ttf")
		if err := os.write_entire_file(output, subset); err != nil {
			fmt.eprintfln("kerneltool: cannot write %s: %v", output, err)
			return EXIT_FAILURE
		}
		license_path := join(VECTOR_FONT_FOLDER, "/", candidate.name, ".license")
		if err := os.write_entire_file(license_path, transmute([]u8)report.license_text); err != nil {
			fmt.eprintfln("kerneltool: cannot write %s: %v", license_path, err)
			return EXIT_FAILURE
		}
		fmt.printfln("%-18s %10d %8d %10d %8d %8d %8d %6d %s", candidate.name, len(source), len(subset), report.composites, report.measures.advance, report.measures.x_height, report.measures.cap_height, report.pairs, report.zero)
		if candidate.zero_form == .Slashed && report.zero_glyph == 0 {
			fmt.printfln("kerneltool: %s has no single substitution of the feature zero for '0': its subset keeps the zero of the font", candidate.name)
		}
	}
	_, interface_written := interface_glyph_caches_write()
	if !candidates_picture_write() || !interface_written {
		return EXIT_FAILURE
	}
	fmt.printfln("kerneltool: the subsets are in %s, the picture of the choice is %s", VECTOR_FONT_FOLDER, CANDIDATES_PICTURE)
	return 0
}

Subset_Report :: struct {
	problem:      string,
	composites:   int, // Glyphs made of glyphs, made simple.
	pairs:        int, // The pair adjustments of the characters 32 to 126 that the subset keeps.
	zero_glyph:   int, // The glyph of the source that the subset draws for '0' in place of the glyph of the cmap; 0: the zero of the font.
	zero:         string, // For the table of the command: "slashed (glyph n)" or "of the font".
	measures:     vector_font.Font_Measures,
	license_text: string,
}

// The glyphs of a subset: .notdef, then the characters 32 to 126.
SUBSET_GLYPHS :: 96

// font_subset writes a TrueType file with the characters 32 to 126 of a
// font, from the first face of a collection.
font_subset :: proc(source: []u8, candidate: Vector_Font_Candidate, proportional: bool) -> (subset: []u8, report: Subset_Report, ok: bool) {
	face, face_problem := vector_font.collection_face_offset(source, 0)
	font, problem := vector_font.font_open(source, face)
	if face_problem != .None || problem != .None {
		report.problem = vector_font.font_problem_names[face_problem != .None ? face_problem : problem]
		return nil, report, false
	}
	memory := new(vector_font.Render_Memory, context.temp_allocator)
	report.measures, problem = vector_font.font_measures(&font, memory)
	if problem != .None || !report.measures.monospace && !proportional {
		report.problem = problem != .None ? vector_font.font_problem_names[problem] : "the font is not monospace"
		return nil, report, false
	}
	report.zero = "of the font"
	// The pair adjustments, read from the source as hostile input: each
	// pair of two characters of the subset, by the glyphs of the subset.
	kern: []u8
	if proportional {
		// The measures that the glyph cache uses: the stated cap height and
		// x-height, and the units of one cell in place of an advance.
		report.measures, problem = vector_font.proportional_measures(&font, report.measures)
		if problem != .None {
			report.problem = vector_font.font_problem_names[problem]
			return nil, report, false
		}
		pair_table, pair_problem := vector_font.pair_table_open(&font)
		if pair_problem != .None {
			report.problem = fmt.tprintf("the table kern: %s", vector_font.font_problem_names[pair_problem])
			return nil, report, false
		}
		kern, report.pairs = kern_table_write(&font, &pair_table)
	}
	// The glyphs, each as a simple glyph.
	glyphs := make([dynamic]u8, context.temp_allocator)
	offsets: [SUBSET_GLYPHS + 1]u32
	advances: [SUBSET_GLYPHS]u16
	left_sides: [SUBSET_GLYPHS]i16
	box := [4]i32{max(i32), max(i32), min(i32), min(i32)}
	most_points, most_contours := 0, 0
	outline := vector_font.Outline{points = memory.points[:], contour_ends = memory.contours[:]}
	for index in 0 ..< SUBSET_GLYPHS {
		glyph := 0
		if index > 0 {
			glyph, problem = vector_font.glyph_of(&font, rune(31 + index))
			if problem != .None {
				report.problem = fmt.tprintf("the character %d: %s", 31 + index, vector_font.font_problem_names[problem])
				return nil, report, false
			}
			if 31 + index == '0' && candidate.zero_form == .Slashed {
				substitute, substitution_problem := vector_font.single_substitution(&font, ZERO_FEATURE, glyph)
				#partial switch substitution_problem {
				case .None:
					glyph = substitute
					report.zero_glyph = substitute
					report.zero = fmt.tprintf("slashed (glyph %d)", substitute)
				case .No_Feature:
				case:
					report.problem = fmt.tprintf("the table GSUB: %s", vector_font.font_problem_names[substitution_problem])
					return nil, report, false
				}
			}
		}
		if is_composite(&font, glyph) {
			report.composites += 1
		}
		if problem = vector_font.glyph_outline(&font, glyph, &outline); problem != .None {
			report.problem = fmt.tprintf("the glyph %d: %s", glyph, vector_font.font_problem_names[problem])
			return nil, report, false
		}
		offsets[index] = u32(len(glyphs))
		advances[index] = u16(outline.advance)
		if outline.point_count > 0 {
			glyph_box := simple_glyph_write(&glyphs, &outline)
			left_sides[index] = i16(glyph_box[0])
			box = {min(box[0], glyph_box[0]), min(box[1], glyph_box[1]), max(box[2], glyph_box[2]), max(box[3], glyph_box[3])}
			most_points = max(most_points, outline.point_count)
			most_contours = max(most_contours, outline.contour_count)
		}
	}
	offsets[SUBSET_GLYPHS] = u32(len(glyphs))
	tables := make([dynamic]Subset_Table, context.temp_allocator)
	// OS/2: the table of the source, as it is.
	if font.os2.length > 0 {
		append(&tables, Subset_Table{"OS/2", slice.clone(source[font.os2.offset:][:font.os2.length], context.temp_allocator)})
	}
	append(&tables, Subset_Table{"cmap", character_map_write()})
	append(&tables, Subset_Table{"glyf", glyphs[:]})
	head := slice.clone(source[font.head.offset:][:54], context.temp_allocator)
	put_u32(head, 8, 0) // checkSumAdjustment, set at the end.
	put_u16(head, 36, u16(i16(box[0])))
	put_u16(head, 38, u16(i16(box[1])))
	put_u16(head, 40, u16(i16(box[2])))
	put_u16(head, 42, u16(i16(box[3])))
	put_u16(head, 50, 1) // Long offsets in loca.
	append(&tables, Subset_Table{"head", head})
	hhea := slice.clone(source[font.hhea.offset:][:36], context.temp_allocator)
	put_u16(hhea, 10, slice.max(advances[:])) // advanceWidthMax.
	put_u16(hhea, 34, SUBSET_GLYPHS)
	append(&tables, Subset_Table{"hhea", hhea})
	metrics := make([]u8, 4 * SUBSET_GLYPHS, context.temp_allocator)
	for index in 0 ..< SUBSET_GLYPHS {
		put_u16(metrics, 4 * index, advances[index])
		put_u16(metrics, 4 * index + 2, u16(left_sides[index]))
	}
	append(&tables, Subset_Table{"hmtx", metrics})
	if len(kern) > 0 {
		append(&tables, Subset_Table{"kern", kern})
	}
	loca := make([]u8, 4 * (SUBSET_GLYPHS + 1), context.temp_allocator)
	for offset, index in offsets {
		put_u32(loca, 4 * index, offset)
	}
	append(&tables, Subset_Table{"loca", loca})
	maxp := make([]u8, 32, context.temp_allocator)
	put_u32(maxp, 0, 0x00010000)
	put_u16(maxp, 4, SUBSET_GLYPHS)
	put_u16(maxp, 6, u16(most_points))
	put_u16(maxp, 8, u16(most_contours))
	put_u16(maxp, 14, 2) // maxZones.
	append(&tables, Subset_Table{"maxp", maxp})
	copyright := name_string(&font, 0)
	license := name_string(&font, 13)
	license_place := name_string(&font, 14)
	append(&tables, Subset_Table{"name", name_table_write(candidate.family, copyright, license, license_place)})
	post := make([]u8, 32, context.temp_allocator)
	put_u32(post, 0, 0x00030000)
	if font.post.length >= 32 {
		copy(post[4:16], source[font.post.offset + 4:][:12]) // The angle and the underline.
	}
	put_u32(post, 12, proportional ? 0 : 1) // isFixedPitch.
	append(&tables, Subset_Table{"post", post})
	subset = sfnt_write(tables[:])
	report.license_text = fmt.aprintf(
		"%s\n\nThis file is a subset of %s, made by \"kerneltool vector_fonts\" (docs/FONTS.md):\nthe characters 32 to 126 and the glyph .notdef, each glyph a simple glyph\n(%d glyphs made of glyphs were made simple), no hinting instructions, no\nOpenType layout tables%s. The subset carries the name \"%s\".\nLicense of the source: %s.\n\nThe text of the license in the source font file:\n\n%s\n\nURL of the license: %s\nThe full text of the license: %s, in this folder.\n",
		copyright, candidate.name, report.composites, strings.concatenate({proportional ? fmt.tprintf("; the %d pair adjustments of its table kern between\nthese characters", report.pairs) : "", report.zero_glyph != 0 ? fmt.tprintf(";\nthe character 0 is the glyph %d of the source, the slashed zero of its\nfeature zero", report.zero_glyph) : ""}, context.temp_allocator), candidate.family, candidate.license, license, license_place, candidate.license_file,
		allocator = context.temp_allocator,
	)
	return subset, report, true
}

// kern_table_write gives a kern table of version 0 with one subtable of
// format 0: the pairs of the characters 32 to 126 whose adjustment is not
// 0, by the glyphs of the subset (character c is glyph c - 31). The loops
// go in the order of the glyphs, so the pairs are sorted.
@(private = "file")
kern_table_write :: proc(font: ^vector_font.Font_File, pair_table: ^vector_font.Pair_Table) -> (table: []u8, count: int) {
	pairs := make([dynamic]u8, context.temp_allocator)
	for left in rune(32) ..= 126 {
		for right in rune(32) ..= 126 {
			adjustment := vector_font.character_pair_adjustment(font, pair_table, left, right)
			if adjustment != 0 {
				append_u16(&pairs, u16(left - 31))
				append_u16(&pairs, u16(right - 31))
				append_u16(&pairs, u16(i16(adjustment)))
				count += 1
			}
		}
	}
	if count == 0 {
		return nil, 0
	}
	out := make([dynamic]u8, context.temp_allocator)
	append_u16(&out, 0) // version
	append_u16(&out, 1) // one subtable
	append_u16(&out, 0) // the version of the subtable
	append_u16(&out, u16(vector_font.KERN_SUBTABLE_HEADER_SIZE + len(pairs)))
	append_u16(&out, 0x0001) // format 0, horizontal
	append_u16(&out, u16(count))
	power := 1
	exponent := 0
	for power * 2 <= count {
		power *= 2
		exponent += 1
	}
	append_u16(&out, u16(vector_font.KERN_PAIR_SIZE * power)) // searchRange
	append_u16(&out, u16(exponent)) // entrySelector
	append_u16(&out, u16(vector_font.KERN_PAIR_SIZE * (count - power))) // rangeShift
	append(&out, ..pairs[:])
	return out[:], count
}

// is_composite says if a glyph is made of other glyphs.
@(private = "file")
is_composite :: proc(font: ^vector_font.Font_File, glyph: int) -> bool {
	loca := font.bytes[font.loca.offset:][:font.loca.length]
	start := font.long_offsets ? int(get_u32(loca, 4 * glyph)) : 2 * int(get_u16(loca, 2 * glyph))
	end := font.long_offsets ? int(get_u32(loca, 4 * glyph + 4)) : 2 * int(get_u16(loca, 2 * glyph + 2))
	if end <= start {
		return false
	}
	return i16(get_u16(font.bytes, font.glyf.offset + start)) < 0
}

// simple_glyph_write appends a simple glyph: each coordinate as a 16-bit
// difference, no instruction. It pads to 4 bytes and gives the box.
@(private = "file")
simple_glyph_write :: proc(out: ^[dynamic]u8, outline: ^vector_font.Outline) -> (box: [4]i32) {
	box = {max(i32), max(i32), min(i32), min(i32)}
	for point in outline.points[:outline.point_count] {
		box = {min(box[0], point.x), min(box[1], point.y), max(box[2], point.x), max(box[3], point.y)}
	}
	append_u16(out, u16(outline.contour_count))
	for value in box {
		append_u16(out, u16(i16(value)))
	}
	for end in outline.contour_ends[:outline.contour_count] {
		append_u16(out, u16(end - 1))
	}
	append_u16(out, 0) // No instruction.
	for point in outline.points[:outline.point_count] {
		append(out, point.on_curve ? 1 : 0) // 16-bit differences on both axes.
	}
	previous: i32
	for point in outline.points[:outline.point_count] {
		append_u16(out, u16(i16(point.x - previous)))
		previous = point.x
	}
	previous = 0
	for point in outline.points[:outline.point_count] {
		append_u16(out, u16(i16(point.y - previous)))
		previous = point.y
	}
	for len(out) % 4 != 0 {
		append(out, 0)
	}
	return box
}

// character_map_write gives a cmap with one subtable of format 4: the
// characters 32 to 126 are the glyphs 1 to 95.
@(private = "file")
character_map_write :: proc() -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	append_u16(&out, 0)
	append_u16(&out, 1)
	append_u16(&out, 3) // Windows, Unicode basic plane.
	append_u16(&out, 1)
	append_u32(&out, 12)
	segments :: 2
	append_u16(&out, 4)
	append_u16(&out, 16 + 8 * segments) // length
	append_u16(&out, 0) // language
	append_u16(&out, 2 * segments)
	append_u16(&out, 4) // searchRange: 2 * 2^floor(log2(2)).
	append_u16(&out, 1) // entrySelector.
	append_u16(&out, 0) // rangeShift.
	append_u16(&out, 126)
	append_u16(&out, 0xFFFF)
	append_u16(&out, 0) // reservedPad
	append_u16(&out, 32)
	append_u16(&out, 0xFFFF)
	append_u16(&out, 0x10000 - 31) // 32 + (65536 - 31) is the glyph 1, modulo 65536.
	append_u16(&out, 1)
	append_u16(&out, 0)
	append_u16(&out, 0)
	return out[:]
}

// name_string gives a name of the font (Windows, Unicode) as UTF-16 code
// units turned to bytes: ASCII stays, another character becomes "?" but
// for the copyright sign.
@(private = "file")
name_string :: proc(font: ^vector_font.Font_File, name_id: int) -> string {
	table := font.bytes[font.name.offset:][:font.name.length]
	if len(table) < 6 {
		return ""
	}
	count := int(get_u16(table, 2))
	storage := int(get_u16(table, 4))
	for index in 0 ..< count {
		record := 6 + 12 * index
		if record + 12 > len(table) {
			break
		}
		if get_u16(table, record) != 3 || int(get_u16(table, record + 6)) != name_id {
			continue
		}
		length := int(get_u16(table, record + 8))
		offset := storage + int(get_u16(table, record + 10))
		if offset + length > len(table) {
			break
		}
		builder := strings.builder_make(context.temp_allocator)
		for at := offset; at + 1 < offset + length; at += 2 {
			unit := get_u16(table, at)
			switch {
			case unit == 0xA9:
				strings.write_string(&builder, "(c)")
			case unit == '\n' || unit >= 32 && unit < 127:
				strings.write_byte(&builder, u8(unit))
			case:
				strings.write_byte(&builder, '?')
			}
		}
		return strings.to_string(builder)
	}
	return ""
}

// name_table_write gives a name table of format 0 with the copyright, the
// family, the style, the full name, the license and its place.
@(private = "file")
name_table_write :: proc(family, copyright, license, license_place: string) -> []u8 {
	names := [?]struct {
		id:   u16,
		text: string,
	}{{0, copyright}, {1, family}, {2, "Regular"}, {4, family}, {13, license}, {14, license_place}}
	out := make([dynamic]u8, context.temp_allocator)
	append_u16(&out, 0)
	append_u16(&out, u16(len(names)))
	append_u16(&out, u16(6 + 12 * len(names)))
	offset := 0
	for name in names {
		append_u16(&out, 3)
		append_u16(&out, 1)
		append_u16(&out, 0x409)
		append_u16(&out, name.id)
		append_u16(&out, u16(2 * len(name.text)))
		append_u16(&out, u16(offset))
		offset += 2 * len(name.text)
	}
	for name in names {
		for character in transmute([]u8)name.text {
			append_u16(&out, u16(character))
		}
	}
	return out[:]
}

Subset_Table :: struct {
	tag:  string,
	data: []u8,
}

// sfnt_write gives a TrueType file of tables in the order of their tags,
// with the checksums and the checksum adjustment of head. The font of the
// name of the mark is written with it too (mark_font.odin).
sfnt_write :: proc(tables: []Subset_Table) -> []u8 {
	count := len(tables)
	out := make([dynamic]u8, context.temp_allocator)
	append_u32(&out, 0x00010000)
	append_u16(&out, u16(count))
	power := 1
	exponent := 0
	for power * 2 <= count {
		power *= 2
		exponent += 1
	}
	append_u16(&out, u16(16 * power))
	append_u16(&out, u16(exponent))
	append_u16(&out, u16(16 * count - 16 * power))
	offset := 12 + 16 * count
	head_offset := 0
	for table in tables {
		append(&out, ..transmute([]u8)table.tag)
		append_u32(&out, table_checksum(table.data))
		append_u32(&out, u32(offset))
		append_u32(&out, u32(len(table.data)))
		if table.tag == "head" {
			head_offset = offset
		}
		offset += (len(table.data) + 3) / 4 * 4
	}
	for table in tables {
		append(&out, ..table.data)
		for len(out) % 4 != 0 {
			append(&out, 0)
		}
	}
	put_u32(out[:], head_offset + 8, 0xB1B0AFBA - table_checksum(out[:]))
	return out[:]
}

// table_checksum gives the checksum of a table or of a whole file: the sum
// of its words of 32 bits, big endian, with zeros after its last byte up to
// a whole word. The sum wraps at 32 bits.
table_checksum :: proc(data: []u8) -> (sum: u32) {
	for at := 0; at < len(data); at += 4 {
		word: u32
		for index in 0 ..< 4 {
			word <<= 8
			if at + index < len(data) {
				word |= u32(data[at + index])
			}
		}
		sum += word
	}
	return sum
}

get_u16 :: proc(data: []u8, at: int) -> u16 {
	if at < 0 || at + 2 > len(data) {
		return 0
	}
	return u16(data[at]) << 8 | u16(data[at + 1])
}

get_u32 :: proc(data: []u8, at: int) -> u32 {
	return u32(get_u16(data, at)) << 16 | u32(get_u16(data, at + 2))
}

put_u16 :: proc(data: []u8, at: int, value: u16) {
	data[at] = u8(value >> 8)
	data[at + 1] = u8(value)
}

put_u32 :: proc(data: []u8, at: int, value: u32) {
	put_u16(data, at, u16(value >> 16))
	put_u16(data, at + 2, u16(value))
}

append_u16 :: proc(out: ^[dynamic]u8, value: u16) {
	append(out, u8(value >> 8), u8(value))
}

append_u32 :: proc(out: ^[dynamic]u8, value: u32) {
	append_u16(out, u16(value >> 16))
	append_u16(out, u16(value))
}

// glyph_cache_of draws the characters 32 to 126 of a font file at the three
// scales of the grid, and gives the glyph cache file (src/library/contract/glyph_cache),
// in memory aligned on 8 bytes.
glyph_cache_of :: proc(font_bytes: []u8, font_name: string, grid_fit: bool, scale_count := 3) -> (cache: []u8, ok: bool) {
	font, problem := vector_font.font_open(font_bytes)
	memory := new(vector_font.Render_Memory, context.temp_allocator)
	words := make([]u64, vector_font.GLYPH_CACHE_LIMIT / 8, context.temp_allocator)
	out := ([^]u8)(raw_data(words))[:vector_font.GLYPH_CACHE_LIMIT]
	size := 0
	if problem == .None {
		size, problem = vector_font.glyph_cache_build(&font, font_bytes, font_name, grid_fit, memory, out, scale_count)
	}
	if problem != .None {
		fmt.eprintfln("kerneltool: the font %s: %s", font_name, vector_font.font_problem_names[problem])
		return nil, false
	}
	// The reader of the programs checks the cache here too: a cache that it
	// refuses is found at the build, not at the boot.
	if _, refused := glyph_cache.validate(out[:size]); refused.kind != .None {
		fmt.eprintfln("kerneltool: the glyph cache of %s is refused: %s, value %d, limit %d", font_name, glyph_cache.problem_sentences[refused.kind], refused.value, refused.limit)
		return nil, false
	}
	return out[:size], true
}

// build_glyph_caches writes the glyph caches of the default font, with the
// grid fit and without it, and of its bold weight at scale 1, and gives
// them as resources of the boot image. The setting "grid_fit" of the
// system chooses one of the first two at run time.
build_glyph_caches :: proc() -> (resources: [5]Resource_File, ok: bool) {
	make_folder(VECTOR_FONT_BUILD_FOLDER)
	builds := [3]struct {
		font:         string,
		grid_fit:     bool,
		scale_count:  int,
		output, name: string,
	}{{DEFAULT_VECTOR_FONT, true, 3, GLYPH_CACHE_OUTPUT, GLYPH_CACHE_RESOURCE}, {DEFAULT_VECTOR_FONT, false, 3, GLYPH_CACHE_WITHOUT_GRID_FIT_OUTPUT, GLYPH_CACHE_WITHOUT_GRID_FIT_RESOURCE}, {EMPHASIS_VECTOR_FONT, true, 1, GLYPH_CACHE_BOLD_OUTPUT, GLYPH_CACHE_BOLD_RESOURCE}}
	for build, index in builds {
		font := read_file(join(VECTOR_FONT_FOLDER, "/", build.font, ".ttf")) or_return
		cache := glyph_cache_of(font, build.font, build.grid_fit, build.scale_count) or_return
		if err := os.write_entire_file(build.output, cache); err != nil {
			fmt.eprintfln("kerneltool: cannot write %s: %v", build.output, err)
			return {}, false
		}
		resources[index] = {name = build.name, path = build.output}
	}
	// The two caches of the interface font (docs/FONTS.md, section 12).
	interface_resources := interface_glyph_caches_write() or_return
	resources[3], resources[4] = interface_resources[0], interface_resources[1]
	return resources, true
}

// The subpixel positions of the caches of the interface font, for each
// scale (docs/FONTS.md, section 12.4): three at scale 1, one at the scales
// 2 and 3; the bold weight at scale 1 only, for the titles.
INTERFACE_POSITIONS := [3]int{3, 1, 1}
INTERFACE_BOLD_POSITIONS := [1]int{3}

// interface_glyph_caches_write draws the two glyph caches of the interface
// font from its subsets, checks them with the reader of the programs (so a
// resource is never shorter than its header, and states its own size), and
// writes them with their sizes: the two resources of the boot image of the
// interface font.
interface_glyph_caches_write :: proc() -> (resources: [2]Resource_File, ok: bool) {
	builds := [2]struct {
		font, output, name: string,
		positions:          []int,
	}{{INTERFACE_VECTOR_FONT, INTERFACE_GLYPH_CACHE_OUTPUT, INTERFACE_GLYPH_CACHE_RESOURCE, INTERFACE_POSITIONS[:]}, {INTERFACE_EMPHASIS_VECTOR_FONT, INTERFACE_GLYPH_CACHE_BOLD_OUTPUT, INTERFACE_GLYPH_CACHE_BOLD_RESOURCE, INTERFACE_BOLD_POSITIONS[:]}}
	for build, index in builds {
		font_bytes := read_file(join(VECTOR_FONT_FOLDER, "/", build.font, ".ttf")) or_return
		font, problem := vector_font.font_open(font_bytes)
		memory := new(vector_font.Render_Memory, context.temp_allocator)
		words := make([]u64, vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT / 8, context.temp_allocator)
		out := ([^]u8)(raw_data(words))[:vector_font.PROPORTIONAL_GLYPH_CACHE_LIMIT]
		size := 0
		if problem == .None {
			size, problem = vector_font.glyph_cache_build_proportional(&font, font_bytes, build.font, true, memory, out, build.positions)
		}
		if problem != .None {
			fmt.eprintfln("kerneltool: the interface font %s: %s", build.font, vector_font.font_problem_names[problem])
			return {}, false
		}
		if _, refused := glyph_cache.validate(out[:size]); refused.kind != .None {
			fmt.eprintfln("kerneltool: the glyph cache of %s is refused: %s", build.font, glyph_cache.problem_sentences[refused.kind])
			return {}, false
		}
		if err := os.write_entire_file(build.output, out[:size]); err != nil {
			fmt.eprintfln("kerneltool: cannot write %s: %v", build.output, err)
			return {}, false
		}
		fmt.printfln("kerneltool: the glyph cache of %s with the positions %v: %d bytes, in %s", build.font, build.positions, size, build.output)
		resources[index] = {name = build.name, path = build.output}
	}
	return resources, true
}
