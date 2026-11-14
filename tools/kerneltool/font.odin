package kerneltool

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// The font of the graphics library is Spleen 8x16, a bitmap font that is
// drawn for this size. The command "font" converts its BDF file to Odin data.
// The result is in the repository, so that a build does not need the BDF file.

FONT_SOURCE_VARIABLE :: "FONT_SOURCE"
FONT_OUTPUT :: SOURCE_FOLDER_SUPPORT + "/graphics/font.odin"
FONT_FIRST :: 32
FONT_LAST :: 126
FONT_WIDTH :: 8
FONT_HEIGHT :: 16

run_font :: proc(args: []string) -> int {
	path := os.get_env(FONT_SOURCE_VARIABLE, context.temp_allocator)
	if path == "" {
		fmt.eprintln("kerneltool: " + FONT_SOURCE_VARIABLE + " is not set. Use the development shell: nix develop")
		return EXIT_FAILURE
	}
	source, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("kerneltool: cannot read %s: %v", path, err)
		return EXIT_FAILURE
	}
	glyphs: [FONT_LAST - FONT_FIRST + 1][FONT_HEIGHT]u8
	found := 0
	encoding := -1
	row := -1 // The next line of the bitmap; -1 outside a bitmap.
	text := string(source)
	for line in strings.split_lines_iterator(&text) {
		switch {
		case strings.has_prefix(line, "ENCODING "):
			encoding, _ = strconv.parse_int(line[len("ENCODING "):])
		case strings.has_prefix(line, "BBX ") && line != "BBX 8 16 0 -4":
			fmt.eprintfln("kerneltool: %s: a glyph is not %dx%d: %s", path, FONT_WIDTH, FONT_HEIGHT, line)
			return EXIT_FAILURE
		case line == "BITMAP":
			row = 0
		case line == "ENDCHAR":
			if encoding >= FONT_FIRST && encoding <= FONT_LAST && row == FONT_HEIGHT {
				found += 1
			}
			row = -1
		case row >= 0 && row < FONT_HEIGHT:
			if encoding >= FONT_FIRST && encoding <= FONT_LAST {
				bits, _ := strconv.parse_uint(line, 16)
				glyphs[encoding - FONT_FIRST][row] = u8(bits)
			}
			row += 1
		}
	}
	if found != len(glyphs) {
		fmt.eprintfln("kerneltool: %s has %d of the %d characters", path, found, len(glyphs))
		return EXIT_FAILURE
	}

	out := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&out, "// This file is the output of \"kerneltool font\". Do not change it by hand.")
	fmt.sbprintln(&out, "//")
	fmt.sbprintln(&out, "// The font is Spleen 8x16 2.1.0, Copyright (c) 2018-2024, Frederic Cambus.")
	fmt.sbprintln(&out, "// Its license is BSD 2-Clause: see " + SITE_SPLEEN_LICENSE_FILE + ".")
	fmt.sbprintln(&out, "package graphics")
	fmt.sbprintln(&out)
	fmt.sbprintln(&out, "// One glyph is one byte per line, from the top. Bit 7 is the left pixel.")
	fmt.sbprintfln(&out, "FONT_FIRST :: %d", FONT_FIRST)
	fmt.sbprintfln(&out, "FONT_LAST :: %d", FONT_LAST)
	fmt.sbprintfln(&out, "CELL_WIDTH :: %d", FONT_WIDTH)
	fmt.sbprintfln(&out, "CELL_HEIGHT :: %d", FONT_HEIGHT)
	fmt.sbprintln(&out)
	fmt.sbprintln(&out, "@(rodata)")
	fmt.sbprintln(&out, "font := [FONT_LAST - FONT_FIRST + 1][CELL_HEIGHT]u8 {")
	for glyph, index in glyphs {
		fmt.sbprint(&out, "\t{")
		for bits, line in glyph {
			fmt.sbprintf(&out, "%s0x%02X", line == 0 ? "" : ", ", bits)
		}
		fmt.sbprintfln(&out, "}, // %d", FONT_FIRST + index)
	}
	fmt.sbprintln(&out, "}")
	if write_err := os.write_entire_file(FONT_OUTPUT, strings.to_string(out)); write_err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", FONT_OUTPUT, write_err)
		return EXIT_FAILURE
	}
	fmt.printfln("kerneltool: wrote %s: %d characters of %dx%d pixels", FONT_OUTPUT, found, FONT_WIDTH, FONT_HEIGHT)
	return 0
}
