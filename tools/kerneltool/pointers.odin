package kerneltool

import "modus:contract/pointer_pictures"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// The pointer themes (docs/POINTERS.md). The command "pointers" reads a
// pointer manifest of resources/pointers, and for a manifest with sources
// the folder of an Xcursor theme, and writes one pointer theme file for
// each theme in build/pointers. `build` runs the same code: each theme file
// is a resource of the boot image.
//
// The folder of the theme of the owner comes from the flake: the variable
// POINTER_THEME_SOURCE, or a path after the command. With neither, the
// tool makes the theme of the system only.

POINTER_THEME_SOURCE_VARIABLE :: "POINTER_THEME_SOURCE"
POINTER_BUILD_FOLDER :: BUILD_FOLDER + "/pointers"
LINK_DEPTH_LIMIT :: 8
GRID_SQUARES_LIMIT :: 12 // The squares of a line of a grid, and its lines. A square is size / 12 pixels.

// One pointer theme that the build makes.
//   resource: its name in the resource table of the boot image.
//   needs_source: the manifest names files of an Xcursor theme.
Pointer_Theme_Build :: struct {
	resource:     string,
	manifest:     string,
	output:       string,
	needs_source: bool,
}

pointer_theme_builds := [?]Pointer_Theme_Build {
	{resource = pointer_pictures.RESOURCE_OF_THE_OWNER, manifest = "resources/pointers/posy.manifest", output = POINTER_BUILD_FOLDER + "/posy.pointers", needs_source = true},
	{resource = pointer_pictures.RESOURCE_OF_THE_SYSTEM, manifest = "resources/pointers/system.manifest", output = POINTER_BUILD_FOLDER + "/system.pointers"},
}

// A theme file that the build made: a resource of the boot image.
Resource_File :: struct {
	name: string,
	path: string,
}

run_pointers :: proc(args: []string) -> int {
	source := len(args) > 0 ? args[0] : os.get_env(POINTER_THEME_SOURCE_VARIABLE, context.temp_allocator)
	_, ok := build_pointer_themes(source, true)
	return ok ? 0 : EXIT_FAILURE
}

// build_pointer_themes makes each theme of pointer_theme_builds whose
// source is there. With print_tables, it prints a table for each theme.
build_pointer_themes :: proc(source: string, print_tables: bool) -> (resources: []Resource_File, ok: bool) {
	if err := os.make_directory_all(POINTER_BUILD_FOLDER); err != nil && err != .Exist {
		fmt.eprintfln("kerneltool: cannot make %s: %v", POINTER_BUILD_FOLDER, err)
		return nil, false
	}
	list := make([dynamic]Resource_File, context.temp_allocator)
	for build in pointer_theme_builds {
		if build.needs_source && source == "" {
			fmt.printfln("kerneltool: pointers: %s is not set: the boot image has no %s, only the theme of the system", POINTER_THEME_SOURCE_VARIABLE, build.resource)
			continue
		}
		text, read_ok := read_file(build.manifest)
		if !read_ok {
			return nil, false
		}
		start := time.tick_now()
		manifest, problem := manifest_parse(build.manifest, string(text))
		if problem != "" {
			fmt.eprintfln("kerneltool: %s", problem)
			return nil, false
		}
		file, rows, made_problem := pointer_theme_make(manifest, build.needs_source ? source : "")
		if made_problem != "" {
			fmt.eprintfln("kerneltool: %s: %s", build.manifest, made_problem)
			return nil, false
		}
		spent := time.tick_since(start)
		if err := os.write_entire_file(build.output, file); err != nil {
			fmt.eprintfln("kerneltool: cannot write %s: %v", build.output, err)
			return nil, false
		}
		head := pointer_pictures.header(file)
		fmt.printfln("kerneltool: pointers: %s: %d shapes, %d pictures, %d bytes, from %s in %.1f ms", build.resource, head.shape_count, head.picture_count, len(file), build.manifest, time.duration_milliseconds(spent))
		if print_tables {
			fmt.printfln("  %-30s %-26s %-10s %6s %9s", "shape", "source", "sizes", "frames", "bytes")
			for row in rows {
				fmt.printfln("  %-30s %-26s %-10s %6s %9s", row.shape, row.source, row.sizes, fmt.tprint(row.frames), fmt.tprint(row.bytes))
			}
		}
		append(&list, Resource_File{name = build.resource, path = build.output})
	}
	return list[:], true
}

// ---- The Xcursor reader ----

XCURSOR_MAGIC :: 0x72756358 // The bytes "Xcur".
XCURSOR_FILE_HEADER :: 16
XCURSOR_IMAGE_TYPE :: 0xFFFD0002
XCURSOR_IMAGE_HEADER :: 36
XCURSOR_SIDE_LIMIT :: 0x7FFF
XCURSOR_ENTRY_LIMIT :: 1 << 16

// One image chunk of an Xcursor file.
Xcursor_Image :: struct {
	nominal_size: u32,
	width:        u32,
	height:       u32,
	hot_spot_x:   u32,
	hot_spot_y:   u32,
	delay:        u32,
	pixels:       []u32,
}

@(private = "file")
word_at :: proc(file: []u8, offset: u64) -> u32 {
	return u32(file[offset]) | u32(file[offset + 1]) << 8 | u32(file[offset + 2]) << 16 | u32(file[offset + 3]) << 24
}

// xcursor_read reads the image chunks of an Xcursor file, in the order of
// its table of contents. The file is hostile input: each offset and count
// is checked before a read. It gives "" or the sentence of the first
// problem, with its byte.
xcursor_read :: proc(file: []u8, images: ^[dynamic]Xcursor_Image) -> string {
	length := u64(len(file))
	if length < XCURSOR_FILE_HEADER {
		return fmt.tprintf("the file has %d bytes; the header of an Xcursor file has 16", length)
	}
	if magic := word_at(file, 0); magic != XCURSOR_MAGIC {
		return fmt.tprintf("byte 0: the magic is 0x%08x, not \"Xcur\"", magic)
	}
	header := u64(word_at(file, 4))
	if header < XCURSOR_FILE_HEADER || header > length {
		return fmt.tprintf("byte 4: the header has %d bytes: not 16 to the size of the file (%d)", header, length)
	}
	entries := u64(word_at(file, 12))
	if entries > XCURSOR_ENTRY_LIMIT || entries * 12 > length - header {
		return fmt.tprintf("byte 12: %d entries of the table of contents do not fit in the %d bytes after the header", entries, length - header)
	}
	for entry in 0 ..< entries {
		at := header + entry * 12
		kind := word_at(file, at)
		subtype := word_at(file, at + 4)
		position := u64(word_at(file, at + 8))
		if kind != XCURSOR_IMAGE_TYPE {
			continue // A comment, or a chunk of another kind.
		}
		if position > length || length - position < XCURSOR_IMAGE_HEADER {
			return fmt.tprintf("byte %d: entry %d puts an image at byte %d, past the end of the file (%d bytes)", at + 8, entry, position, length)
		}
		chunk_header := word_at(file, position)
		chunk_kind := word_at(file, position + 4)
		chunk_subtype := word_at(file, position + 8)
		version := word_at(file, position + 12)
		image := Xcursor_Image {
			nominal_size = chunk_subtype,
			width        = word_at(file, position + 16),
			height       = word_at(file, position + 20),
			hot_spot_x   = word_at(file, position + 24),
			hot_spot_y   = word_at(file, position + 28),
			delay        = word_at(file, position + 32),
		}
		switch {
		case chunk_header != XCURSOR_IMAGE_HEADER:
			return fmt.tprintf("byte %d: the image header has %d bytes, not 36", position, chunk_header)
		case chunk_kind != kind || chunk_subtype != subtype:
			return fmt.tprintf("byte %d: the image has the type 0x%08x and the size %d; the table of contents says 0x%08x and %d", position + 4, chunk_kind, chunk_subtype, kind, subtype)
		case version != 1:
			return fmt.tprintf("byte %d: the image has the version %d, not 1", position + 12, version)
		case image.width == 0 || image.width > XCURSOR_SIDE_LIMIT || image.height == 0 || image.height > XCURSOR_SIDE_LIMIT:
			return fmt.tprintf("byte %d: the image is %d x %d: each side must be 1 to 32767", position + 16, image.width, image.height)
		case image.hot_spot_x >= image.width || image.hot_spot_y >= image.height:
			return fmt.tprintf("byte %d: the hot spot %d,%d is not a pixel of the image of %d x %d", position + 24, image.hot_spot_x, image.hot_spot_y, image.width, image.height)
		}
		count := u64(image.width) * u64(image.height)
		if count * 4 > length - position - XCURSOR_IMAGE_HEADER {
			return fmt.tprintf("byte %d: %d x %d pixels pass the end of the file (%d bytes)", position + 36, image.width, image.height, length)
		}
		image.pixels = make([]u32, count, context.temp_allocator)
		for &pixel, index in image.pixels {
			pixel = word_at(file, position + XCURSOR_IMAGE_HEADER + u64(index) * 4)
		}
		append(images, image)
	}
	if len(images) == 0 {
		return "the file has no image"
	}
	return ""
}

// ---- The manifest ----

// One frame of a grid: its delay and its lines of squares.
Grid_Frame :: struct {
	delay: u32,
	lines: [dynamic]string,
}

Manifest_Shape :: struct {
	shape:        pointer_pictures.Pointer_Shape,
	line:         int, // The line of the statement "shape", for the errors after the parse.
	sources:      [dynamic]string,
	hot_spot:     [2]u32,
	has_hot_spot: bool,
	sizes:        [dynamic]u32, // Empty: the sizes of the manifest.
	frames:       [dynamic]Grid_Frame, // Empty for a shape with sources.
	has_frames:   bool, // The grid has statements "frame": an animation.
}

Manifest :: struct {
	path:        string,
	theme_name:  string,
	license:     string,
	attribution: string,
	sizes:       [dynamic]u32,
	shapes:      [dynamic]Manifest_Shape,
}

// A word of a line: its text and its column (from 1).
@(private = "file")
Word :: struct {
	text:   string,
	column: int,
}

@(private = "file")
words_of :: proc(line: string) -> []Word {
	words := make([dynamic]Word, context.temp_allocator)
	index := 0
	for index < len(line) {
		if line[index] == ' ' {
			index += 1
			continue
		}
		start := index
		for index < len(line) && line[index] != ' ' {
			index += 1
		}
		append(&words, Word{text = line[start:index], column = start + 1})
	}
	return words[:]
}

// manifest_parse reads a pointer manifest (docs/POINTERS.md, section 4).
// An error is one sentence: "path:line:column: expected ...; found ...".
manifest_parse :: proc(path: string, text: string) -> (manifest: Manifest, problem: string) {
	manifest.path = path
	manifest.sizes = make([dynamic]u32, context.temp_allocator)
	manifest.shapes = make([dynamic]Manifest_Shape, context.temp_allocator)
	attribution := strings.builder_make(context.temp_allocator)
	fail :: proc(path: string, line, column: int, expected: string, found: string) -> string {
		return fmt.tprintf("%s:%d:%d: expected %s; found %s", path, line, column, expected, found)
	}
	quoted :: proc(text: string) -> string {
		return len(text) == 0 ? "the end of the line" : fmt.tprintf("\"%s\"", text)
	}
	number_of :: proc(word: Word, low, high: u64) -> (value: u32, ok: bool) {
		parsed, parsed_ok := strconv.parse_u64_of_base(word.text, 10)
		if !parsed_ok || parsed < low || parsed > high {
			return 0, false
		}
		return u32(parsed), true
	}
	sizes_of :: proc(path: string, line: int, words: []Word, end_column: int, sizes: ^[dynamic]u32) -> (rest: []Word, problem: string) {
		index := 0
		for index < len(words) {
			value, ok := number_of(words[index], 1, pointer_pictures.PICTURE_SIDE_LIMIT)
			if !ok {
				break
			}
			if len(sizes) > 0 && value <= sizes[len(sizes) - 1] {
				return nil, fail(path, line, words[index].column, fmt.tprintf("a size larger than %d", sizes[len(sizes) - 1]), quoted(words[index].text))
			}
			append(sizes, value)
			index += 1
		}
		if index == 0 {
			column := len(words) > 0 ? words[0].column : end_column
			return nil, fail(path, line, column, "a nominal size from 1 to 256", quoted(len(words) > 0 ? words[0].text : ""))
		}
		return words[index:], ""
	}

	shape: ^Manifest_Shape
	line_number := 0
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		line_number += 1
		for index in 0 ..< len(line) {
			if line[index] < 32 || line[index] > 126 {
				return {}, fail(path, line_number, index + 1, "a character of ASCII 32 to 126", fmt.tprintf("the byte %d", line[index]))
			}
		}
		// A line of a grid: '|' then squares. A comment cannot follow it: '#'
		// is not a square.
		if len(line) > 0 && line[0] == '|' {
			if shape == nil || len(shape.sources) > 0 {
				return {}, fail(path, line_number, 1, "a grid only after a statement \"shape\" with no source", quoted(line))
			}
			squares := line[1:]
			for index in 0 ..< len(squares) {
				if squares[index] != 'X' && squares[index] != '.' && squares[index] != ' ' {
					return {}, fail(path, line_number, index + 2, "a square \"X\", \".\" or \" \"", quoted(squares[index:index + 1]))
				}
			}
			if len(squares) > GRID_SQUARES_LIMIT {
				return {}, fail(path, line_number, GRID_SQUARES_LIMIT + 2, "at most 12 squares in a line", quoted(squares[GRID_SQUARES_LIMIT:]))
			}
			if len(shape.frames) == 0 {
				append(&shape.frames, Grid_Frame{lines = make([dynamic]string, context.temp_allocator)})
			}
			frame := &shape.frames[len(shape.frames) - 1]
			if len(frame.lines) == GRID_SQUARES_LIMIT {
				return {}, fail(path, line_number, 1, "at most 12 lines in a grid", quoted(line))
			}
			append(&frame.lines, squares)
			continue
		}
		statement := line
		if comment := strings.index_byte(statement, '#'); comment >= 0 {
			statement = statement[:comment]
		}
		words := words_of(statement)
		if len(words) == 0 {
			continue
		}
		keyword := words[0]
		if manifest.theme_name == "" && keyword.text != "theme" {
			return {}, fail(path, line_number, keyword.column, "the statement \"theme\" first", quoted(keyword.text))
		}
		switch keyword.text {
		case "theme", "attribution":
			value := strings.trim_space(statement[keyword.column - 1 + len(keyword.text):])
			if keyword.text == "attribution" {
				if strings.builder_len(attribution) > 0 {
					strings.write_byte(&attribution, ' ')
				}
				strings.write_string(&attribution, value)
				if strings.builder_len(attribution) > pointer_pictures.ATTRIBUTION_CAPACITY - 1 {
					return {}, fail(path, line_number, keyword.column, "at most 399 characters of attribution in all", fmt.tprintf("%d", strings.builder_len(attribution)))
				}
				continue
			}
			if manifest.theme_name != "" {
				return {}, fail(path, line_number, keyword.column, "one statement \"theme\"", "a second one")
			}
			if len(value) == 0 || len(value) > pointer_pictures.NAME_CAPACITY - 1 {
				return {}, fail(path, line_number, len(words) > 1 ? words[1].column : len(line) + 1, "a theme name of 1 to 31 characters", quoted(value))
			}
			manifest.theme_name = value
		case "license":
			if manifest.license != "" {
				return {}, fail(path, line_number, keyword.column, "one statement \"license\"", "a second one")
			}
			if len(words) != 2 || len(words[1].text) > pointer_pictures.LICENSE_CAPACITY - 1 {
				return {}, fail(path, line_number, len(words) > 1 ? words[1].column : len(line) + 1, "one SPDX identifier of 1 to 31 characters", quoted(len(words) > 1 ? statement[words[1].column - 1:] : ""))
			}
			manifest.license = words[1].text
		case "sizes":
			if len(manifest.sizes) > 0 || len(manifest.shapes) > 0 {
				return {}, fail(path, line_number, keyword.column, "one statement \"sizes\", before the shapes", quoted(keyword.text))
			}
			after, sizes_problem := sizes_of(path, line_number, words[1:], len(statement) + 1, &manifest.sizes)
			if sizes_problem != "" {
				return {}, sizes_problem
			}
			if len(after) > 0 {
				return {}, fail(path, line_number, after[0].column, "a nominal size from 1 to 256, or the end of the line", quoted(after[0].text))
			}
		case "shape":
			if len(manifest.sizes) == 0 {
				return {}, fail(path, line_number, keyword.column, "the statement \"sizes\" before the shapes", quoted(keyword.text))
			}
			if len(words) < 2 {
				return {}, fail(path, line_number, len(line) + 1, "a pointer shape name such as \"arrow\"", "the end of the line")
			}
			found, known := pointer_pictures.shape_of_name(words[1].text)
			if !known {
				return {}, fail(path, line_number, words[1].column, "a pointer shape name such as \"arrow\"", quoted(words[1].text))
			}
			for &other in manifest.shapes {
				if other.shape == found {
					return {}, fail(path, line_number, words[1].column, fmt.tprintf("a shape that line %d does not name", other.line), quoted(words[1].text))
				}
			}
			if shape_problem := shape_check_end(&manifest, shape); shape_problem != "" {
				return {}, shape_problem
			}
			append(&manifest.shapes, Manifest_Shape{shape = found, line = line_number, sources = make([dynamic]string, context.temp_allocator), sizes = make([dynamic]u32, context.temp_allocator), frames = make([dynamic]Grid_Frame, context.temp_allocator)})
			shape = &manifest.shapes[len(manifest.shapes) - 1]
			index := 2
			for index < len(words) {
				word := words[index]
				switch word.text {
				case "hot":
					if shape.has_hot_spot {
						return {}, fail(path, line_number, word.column, "one option \"hot\"", "a second one")
					}
					if index + 2 >= len(words) {
						column := index + 1 < len(words) ? words[index + 1].column : len(statement) + 1
						return {}, fail(path, line_number, column, "two numbers after \"hot\"", quoted(strings.trim_space(statement[column - 1:])))
					}
					x, x_ok := number_of(words[index + 1], 0, pointer_pictures.PICTURE_SIDE_LIMIT - 1)
					y, y_ok := number_of(words[index + 2], 0, pointer_pictures.PICTURE_SIDE_LIMIT - 1)
					if !x_ok || !y_ok {
						bad := !x_ok ? words[index + 1] : words[index + 2]
						return {}, fail(path, line_number, bad.column, "a number from 0 to 255", quoted(bad.text))
					}
					shape.hot_spot = {x, y}
					shape.has_hot_spot = true
					index += 3
				case "sizes":
					if len(shape.sizes) > 0 {
						return {}, fail(path, line_number, word.column, "one option \"sizes\"", "a second one")
					}
					after, sizes_problem := sizes_of(path, line_number, words[index + 1:], len(statement) + 1, &shape.sizes)
					if sizes_problem != "" {
						return {}, sizes_problem
					}
					index = len(words) - len(after)
				case:
					if shape.has_hot_spot || len(shape.sizes) > 0 {
						return {}, fail(path, line_number, word.column, "an option \"hot\" or \"sizes\" after the options", quoted(word.text))
					}
					for character in word.text {
						if !(character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character >= '0' && character <= '9' || character == '_' || character == '-') {
							return {}, fail(path, line_number, word.column, "a file name of letters, digits, \"_\" and \"-\"", quoted(word.text))
						}
					}
					append(&shape.sources, word.text)
					index += 1
				}
			}
		case "frame":
			if shape == nil || len(shape.sources) > 0 {
				return {}, fail(path, line_number, keyword.column, "a statement \"frame\" only after a statement \"shape\" with no source", quoted(keyword.text))
			}
			if len(shape.frames) > 0 && !shape.has_frames {
				return {}, fail(path, line_number, keyword.column, "\"frame\" before the first line of the grid", quoted(keyword.text))
			}
			if len(words) != 2 {
				return {}, fail(path, line_number, len(words) > 1 ? words[2].column : len(line) + 1, "one delay in milliseconds", quoted(len(words) > 2 ? words[2].text : ""))
			}
			delay, ok := number_of(words[1], 1, pointer_pictures.DELAY_LIMIT)
			if !ok {
				return {}, fail(path, line_number, words[1].column, "a delay of 1 to 60000 milliseconds", quoted(words[1].text))
			}
			if len(shape.frames) == pointer_pictures.FRAME_COUNT_LIMIT {
				return {}, fail(path, line_number, keyword.column, "at most 256 frames", "one more")
			}
			shape.has_frames = true
			append(&shape.frames, Grid_Frame{delay = delay, lines = make([dynamic]string, context.temp_allocator)})
		case:
			return {}, fail(path, line_number, keyword.column, "a statement \"theme\", \"license\", \"attribution\", \"sizes\", \"shape\" or \"frame\", or a line of a grid", quoted(keyword.text))
		}
	}
	if shape_problem := shape_check_end(&manifest, shape); shape_problem != "" {
		return {}, shape_problem
	}
	end := line_number + 1
	switch {
	case manifest.theme_name == "":
		return {}, fail(path, end, 1, "the statement \"theme\"", "the end of the file")
	case manifest.license == "":
		return {}, fail(path, end, 1, "the statement \"license\"", "the end of the file")
	case len(manifest.shapes) == 0:
		return {}, fail(path, end, 1, "a statement \"shape\"", "the end of the file")
	}
	has_arrow := false
	for &item in manifest.shapes {
		has_arrow ||= item.shape == .Arrow
	}
	if !has_arrow {
		return {}, fail(path, end, 1, "the shape \"arrow\": the shape that the compositor shows by default", "the end of the file")
	}
	manifest.attribution = strings.to_string(attribution)
	return manifest, ""
}

// shape_check_end checks a shape when the statement after it starts: a
// shape with no source has a grid with a hot spot, and an animation has
// two frames at least, each with lines.
@(private = "file")
shape_check_end :: proc(manifest: ^Manifest, shape: ^Manifest_Shape) -> string {
	if shape == nil {
		return ""
	}
	at :: proc(manifest: ^Manifest, shape: ^Manifest_Shape, expected: string) -> string {
		return fmt.tprintf("%s:%d:1: expected %s; found the shape %s with none", manifest.path, shape.line, expected, pointer_pictures.SHAPE_NAMES[shape.shape])
	}
	if len(shape.sources) > 0 {
		return ""
	}
	if len(shape.frames) == 0 {
		return at(manifest, shape, "a source file or the lines of a grid")
	}
	if !shape.has_hot_spot {
		return at(manifest, shape, "the option \"hot\" for a grid")
	}
	if shape.has_frames && len(shape.frames) < 2 {
		return at(manifest, shape, "2 statements \"frame\" at least for an animation")
	}
	for frame in shape.frames {
		if len(frame.lines) == 0 {
			return at(manifest, shape, "the lines of a grid after each \"frame\"")
		}
		width := 0
		for line in frame.lines {
			width = max(width, len(line))
		}
		if int(shape.hot_spot.x) >= width || int(shape.hot_spot.y) >= len(frame.lines) {
			return fmt.tprintf("%s:%d:1: expected a hot spot inside the grid of %d x %d squares; found %d,%d", manifest.path, shape.line, width, len(frame.lines), shape.hot_spot.x, shape.hot_spot.y)
		}
	}
	sizes := len(shape.sizes) > 0 ? shape.sizes[:] : manifest.sizes[:]
	for size in sizes {
		if size % GRID_SQUARES_LIMIT != 0 {
			return fmt.tprintf("%s:%d:1: expected sizes that are multiples of 12 for a grid; found %d", manifest.path, shape.line, size)
		}
	}
	return ""
}

// ---- The conversion ----

// One row of the table that the command prints.
Pointer_Table_Row :: struct {
	shape:  string,
	source: string,
	sizes:  string,
	frames: int,
	bytes:  int,
}

// One picture before the file is written.
@(private = "file")
Made_Picture :: struct {
	entry:  pointer_pictures.Picture_Entry,
	pixels: []u32,
}

// source_resolve finds the first source of a shape in the folder, and
// follows its links inside the folder. It gives the name of the file at the
// end of the links.
@(private = "file")
source_resolve :: proc(folder: string, sources: []string) -> (name: string, data: []u8, problem: string) {
	for source in sources {
		name = source
		for depth := 0; ; depth += 1 {
			path := join(folder, "/", name)
			info, err := os.lstat(path, context.temp_allocator)
			if err != nil {
				name = ""
				break
			}
			if info.type != .Symlink {
				read_err: os.Error
				data, read_err = os.read_entire_file(path, context.temp_allocator)
				if read_err != nil {
					return "", nil, fmt.tprintf("cannot read %s: %v", path, read_err)
				}
				return name, data, ""
			}
			if depth == LINK_DEPTH_LIMIT {
				return "", nil, fmt.tprintf("%s: more than %d links", source, LINK_DEPTH_LIMIT)
			}
			target, link_err := os.read_link(path, context.temp_allocator)
			if link_err != nil {
				return "", nil, fmt.tprintf("cannot read the link %s: %v", path, link_err)
			}
			if strings.contains_rune(target, '/') || target == "" {
				return "", nil, fmt.tprintf("the link %s names %s, out of the folder", path, target)
			}
			name = target
		}
	}
	return "", nil, fmt.tprintf("none of the sources %v is in %s", sources, folder)
}

// pointer_theme_make makes a pointer theme file from a manifest. The folder
// is the Xcursor theme of the sources ("" for a manifest of grids). The
// file passes pointer_pictures.validate before it is given.
pointer_theme_make :: proc(manifest: Manifest, folder: string) -> (file: []u8, rows: []Pointer_Table_Row, problem: string) {
	shapes := make([dynamic]pointer_pictures.Shape_Entry, context.temp_allocator)
	pictures := make([dynamic]Made_Picture, context.temp_allocator)
	table := make([dynamic]Pointer_Table_Row, context.temp_allocator)
	// Two shapes from one file with the same options share their pictures.
	Made_Source :: struct {
		key:   string,
		entry: pointer_pictures.Shape_Entry,
	}
	made := make([dynamic]Made_Source, context.temp_allocator)
	ordered := slice.clone(manifest.shapes[:], context.temp_allocator)
	slice.sort_by(ordered, proc(a, b: Manifest_Shape) -> bool {return a.shape < b.shape})
	for &item in ordered {
		name := pointer_pictures.SHAPE_NAMES[item.shape]
		sizes := len(item.sizes) > 0 ? item.sizes[:] : manifest.sizes[:]
		sizes_text := strings.builder_make(context.temp_allocator)
		for size, index in sizes {
			fmt.sbprintf(&sizes_text, "%s%d", index > 0 ? " " : "", size)
		}
		entry := pointer_pictures.Shape_Entry{shape = u32(item.shape), first_picture = u32(len(pictures)), size_count = u32(len(sizes))}
		row := Pointer_Table_Row{shape = name, sizes = strings.to_string(sizes_text)}
		bytes_before := 0
		for picture in pictures {
			bytes_before += len(picture.pixels) * 4
		}
		if len(item.sources) == 0 {
			// A grid: a square is size / 12 pixels.
			entry.frame_count = u32(len(item.frames))
			for size in sizes {
				square := size / GRID_SQUARES_LIMIT
				for frame in item.frames {
					width := 0
					for line in frame.lines {
						width = max(width, len(line))
					}
					picture := Made_Picture {
						entry = {nominal_size = size, width = u32(width) * square, height = u32(len(frame.lines)) * square, hot_spot_x = item.hot_spot.x * square + square / 2, hot_spot_y = item.hot_spot.y * square + square / 2, delay_milliseconds = item.has_frames ? frame.delay : 0},
					}
					picture.pixels = make([]u32, picture.entry.width * picture.entry.height, context.temp_allocator)
					for line, row_index in frame.lines {
						for column in 0 ..< len(line) {
							color: u32
							switch line[column] {
							case 'X':
								color = 0xFF000000
							case '.':
								color = 0xFFFFFFFF
							case:
								continue
							}
							for y in 0 ..< square {
								for x in 0 ..< square {
									picture.pixels[(u32(row_index) * square + y) * picture.entry.width + u32(column) * square + x] = color
								}
							}
						}
					}
					append(&pictures, picture)
				}
			}
			row.source = item.has_frames ? "a grid, animated" : "a grid"
		} else {
			resolved, data, source_problem := source_resolve(folder, item.sources[:])
			if source_problem != "" {
				return nil, nil, fmt.tprintf("line %d: %s", item.line, source_problem)
			}
			row.source = resolved
			key := fmt.tprintf("%s %v %v %s", resolved, item.has_hot_spot, item.hot_spot, row.sizes)
			shared := false
			for previous in made {
				if previous.key == key {
					entry.first_picture = previous.entry.first_picture
					entry.frame_count = previous.entry.frame_count
					shared = true
				}
			}
			if shared {
				row.source = fmt.tprintf("%s (shared)", resolved)
				row.frames = int(entry.frame_count)
				append(&shapes, entry)
				append(&table, row)
				continue
			}
			images := make([dynamic]Xcursor_Image, context.temp_allocator)
			if read_problem := xcursor_read(data, &images); read_problem != "" {
				return nil, nil, fmt.tprintf("line %d: %s/%s: %s", item.line, folder, resolved, read_problem)
			}
			for size, size_index in sizes {
				frames := 0
				for image in images {
					if image.nominal_size != size {
						continue
					}
					frames += 1
					if image.width > pointer_pictures.PICTURE_SIDE_LIMIT || image.height > pointer_pictures.PICTURE_SIDE_LIMIT {
						return nil, nil, fmt.tprintf("line %d: %s: a picture of %d x %d is larger than 256", item.line, resolved, image.width, image.height)
					}
					picture := Made_Picture {
						entry = {nominal_size = size, width = image.width, height = image.height, hot_spot_x = image.hot_spot_x, hot_spot_y = image.hot_spot_y, delay_milliseconds = image.delay},
						pixels = image.pixels,
					}
					if item.has_hot_spot {
						// In pixels of the smallest size: the other sizes scale it.
						picture.entry.hot_spot_x = item.hot_spot.x * size / sizes[0]
						picture.entry.hot_spot_y = item.hot_spot.y * size / sizes[0]
						if picture.entry.hot_spot_x >= image.width || picture.entry.hot_spot_y >= image.height {
							return nil, nil, fmt.tprintf("line %d: the hot spot %d,%d is not a pixel of the picture of %d x %d at the size %d", item.line, picture.entry.hot_spot_x, picture.entry.hot_spot_y, image.width, image.height, size)
						}
					}
					append(&pictures, picture)
				}
				if frames == 0 {
					have := make([dynamic]u32, context.temp_allocator)
					for image in images {
						if !slice.contains(have[:], image.nominal_size) {
							append(&have, image.nominal_size)
						}
					}
					return nil, nil, fmt.tprintf("line %d: %s has no picture of the size %d; it has %v", item.line, resolved, size, have[:])
				}
				if size_index == 0 {
					entry.frame_count = u32(frames)
				} else if u32(frames) != entry.frame_count {
					return nil, nil, fmt.tprintf("line %d: %s has %d frames at the size %d and %d at the size %d", item.line, resolved, entry.frame_count, sizes[0], frames, size)
				}
			}
			if entry.frame_count == 1 {
				for &picture in pictures[entry.first_picture:] {
					picture.entry.delay_milliseconds = 0
				}
			}
			append(&made, Made_Source{key = key, entry = entry})
		}
		row.frames = int(entry.frame_count)
		after := 0
		for picture in pictures {
			after += len(picture.pixels) * 4
		}
		row.bytes = after - bytes_before
		append(&shapes, entry)
		append(&table, row)
	}

	// The file: the header, the two tables, the pixels.
	offset := pointer_pictures.pixel_offset_for(u64(len(shapes)), u64(len(pictures)))
	pixel_size: u64 = 0
	for &picture in pictures {
		picture.entry.pixel_offset = pixel_size
		pixel_size += u64(len(picture.pixels)) * 4
	}
	// Aligned: the validation reads the tables in place, as the compositor does.
	file, _ = mem.alloc_bytes(int(offset + pixel_size), pointer_pictures.PIXEL_ALIGNMENT, context.temp_allocator)
	head := (^pointer_pictures.Header)(raw_data(file))
	head^ = {magic = pointer_pictures.MAGIC, version = pointer_pictures.VERSION, shape_count = u32(len(shapes)), picture_count = u32(len(pictures)), pixel_offset = offset, pixel_size = pixel_size, file_size = u64(len(file))}
	copy(head.theme_name[:], manifest.theme_name)
	copy(head.license[:], manifest.license)
	copy(head.attribution[:], manifest.attribution)
	shape_table := ([^]pointer_pictures.Shape_Entry)(raw_data(file[pointer_pictures.HEADER_SIZE:]))[:len(shapes)]
	copy(shape_table, shapes[:])
	picture_table := ([^]pointer_pictures.Picture_Entry)(raw_data(file[pointer_pictures.HEADER_SIZE + len(shapes) * pointer_pictures.SHAPE_ENTRY_SIZE:]))[:len(pictures)]
	for picture, index in pictures {
		picture_table[index] = picture.entry
		copy(([^]u32)(raw_data(file[offset + picture.entry.pixel_offset:]))[:len(picture.pixels)], picture.pixels)
	}
	if found := pointer_pictures.validate(file); found.kind != .None {
		buffer: [256]u8
		return nil, nil, fmt.tprintf("the theme file is not valid: %s", pointer_pictures.sentence(found, buffer[:]))
	}
	return file, table[:], ""
}
