// The icons of the site (docs/SITE.md, "The icons"): favicon.ico at the root,
// an SVG icon, the icon of a phone and the icons of the manifest. Each one is
// drawn from the table of the heron of src/library/support/mark: a raster icon is the
// drawing at a whole cell size, centred with an even margin, so that each
// cell keeps square pixels; the SVG icon is the cells as rectangles.
//
// A transparent icon shows on the tab of a browser, light or dark: it takes
// the colors of the light form, whose darker neck reads on both. The icon of
// a phone and the maskable icon are opaque, on the dark background of the
// system, in the dark form: a phone fills or cuts the transparent part.
package kerneltool

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "support:mark"

SITE_FAVICON :: "favicon.ico"
SITE_ICON_SVG :: "icon.svg"
SITE_ICON_TOUCH :: "icon_180.png"
SITE_ICON_192 :: "icon_192.png"
SITE_ICON_512 :: "icon_512.png"
SITE_ICON_MASKABLE :: "icon_512_maskable.png"

Site_Icon :: struct {
	file_name:  string, // In the picture folder; "" for an entry of favicon.ico only.
	size:       int, // Width and height in pixels.
	variant:    mark.Variant, // The variant of the mark: cells for the icon of one pixel for a cell, smooth for the others.
	heron_cell: int, // The cell size: 24 cells of this many pixels.
	opaque:     bool, // On the dark background, in the dark form.
	in_favicon: bool, // An entry of favicon.ico.
}

// The sizes: 32 is the heron at cells of 1 with a margin of 4; 48 at cells
// of 2; 180 at 7 (168) with a margin of 6; 192 at 8; 512 at 21 (504) with a
// margin of 4. The maskable icon is at 12 (288) with a margin of 112: a
// phone can cut it to a circle of 80 percent of its width, and the whole
// grid of the heron is inside that circle. 16 pixels cannot hold the 24
// cells: there is no icon of 16, and a browser scales the 32.
site_icons := [?]Site_Icon {
	{file_name = "", size = 32, variant = .Cells, heron_cell = 1, in_favicon = true},
	{file_name = "", size = 48, variant = .Smooth, heron_cell = 2, in_favicon = true},
	{file_name = SITE_ICON_TOUCH, size = 180, variant = .Smooth, heron_cell = 7, opaque = true},
	{file_name = SITE_ICON_192, size = 192, variant = .Smooth, heron_cell = 8},
	{file_name = SITE_ICON_512, size = 512, variant = .Smooth, heron_cell = 21},
	{file_name = SITE_ICON_MASKABLE, size = 512, variant = .Smooth, heron_cell = 12, opaque = true},
}

// site_icon_picture gives the picture of the mark that an icon is: the
// request that the generator of the pictures of the mark draws
// (mark_pictures.odin).
site_icon_picture :: proc(icon: Site_Icon) -> Mark_Picture {
	return Mark_Picture{file_name = icon.file_name, variant = icon.variant, heron_cell = icon.heron_cell, on_light = !icon.opaque, opaque = icon.opaque, width = icon.size, height = icon.size}
}

// site_icon_files gives each icon file of the site, by its path in the site:
// favicon.ico at the root, the PNG icons and the SVG icon in the picture
// folder.
site_icon_files :: proc() -> (files: map[string][]u8, ok: bool) {
	files = make(map[string][]u8, context.temp_allocator)
	favicon_pictures := make([dynamic][]u8, context.temp_allocator)
	for icon in site_icons {
		data := mark_picture_png(site_icon_picture(icon)) or_return
		if icon.in_favicon {
			append(&favicon_pictures, data)
			continue
		}
		files[strings.concatenate({SITE_PICTURE_FOLDER, "/", icon.file_name}, context.temp_allocator)] = data
	}
	favicon := site_ico_encode(favicon_pictures[:]) or_return
	files[SITE_FAVICON] = favicon
	files[SITE_PICTURE_FOLDER + "/" + SITE_ICON_SVG] = transmute([]u8)site_icon_svg()
	return files, true
}

// One entry of the directory of an ICO file.
Site_Icon_Entry :: struct {
	width:  int,
	height: int,
	bytes:  int,
	offset: int,
}

SITE_ICO_HEADER_SIZE :: 6
SITE_ICO_ENTRY_SIZE :: 16

// site_ico_encode gives an ICO file whose entries are PNG files: a header
// of 6 bytes (0, the type 1, the count), one entry of 16 bytes for each
// picture (width, height, 0 colors, 0, 1 plane, 32 bits, the bytes, the
// offset; little endian; a size of 256 is written 0), then the PNG files.
site_ico_encode :: proc(pictures: [][]u8) -> (file: []u8, ok: bool) {
	if len(pictures) == 0 || len(pictures) > 0xFFFF {
		return nil, false
	}
	output := make([dynamic]u8, context.temp_allocator)
	little_16 :: proc(output: ^[dynamic]u8, value: int) {
		append(output, u8(value), u8(value >> 8))
	}
	little_32 :: proc(output: ^[dynamic]u8, value: int) {
		append(output, u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24))
	}
	little_16(&output, 0)
	little_16(&output, 1)
	little_16(&output, len(pictures))
	offset := SITE_ICO_HEADER_SIZE + SITE_ICO_ENTRY_SIZE * len(pictures)
	for picture in pictures {
		width, height, is_png := site_png_size(picture)
		if !is_png || width < 1 || width > 256 || height < 1 || height > 256 {
			return nil, false
		}
		append(&output, u8(width & 0xFF), u8(height & 0xFF), 0, 0)
		little_16(&output, 1)
		little_16(&output, 32)
		little_32(&output, len(picture))
		little_32(&output, offset)
		offset += len(picture)
	}
	for picture in pictures {
		append(&output, ..picture)
	}
	return output[:], true
}

// site_ico_read reads the directory of an ICO file, and checks that each
// entry lies inside the file and is a PNG file of the size of its entry.
site_ico_read :: proc(file: []u8) -> (entries: []Site_Icon_Entry, problem: string) {
	little :: proc(bytes: []u8) -> int {
		value := 0
		for index := len(bytes) - 1; index >= 0; index -= 1 {
			value = value << 8 | int(bytes[index])
		}
		return value
	}
	if len(file) < SITE_ICO_HEADER_SIZE || little(file[0:2]) != 0 || little(file[2:4]) != 1 {
		return nil, "not an ICO file"
	}
	count := little(file[4:6])
	if count == 0 || len(file) < SITE_ICO_HEADER_SIZE + SITE_ICO_ENTRY_SIZE * count {
		return nil, "no entry, or a directory longer than the file"
	}
	list := make([]Site_Icon_Entry, count, context.temp_allocator)
	for index in 0 ..< count {
		entry_bytes := file[SITE_ICO_HEADER_SIZE + SITE_ICO_ENTRY_SIZE * index:][:SITE_ICO_ENTRY_SIZE]
		entry := Site_Icon_Entry {
			width  = int(entry_bytes[0]) == 0 ? 256 : int(entry_bytes[0]),
			height = int(entry_bytes[1]) == 0 ? 256 : int(entry_bytes[1]),
			bytes  = little(entry_bytes[8:12]),
			offset = little(entry_bytes[12:16]),
		}
		if entry.offset < 0 || entry.bytes <= 0 || entry.offset > len(file) || entry.bytes > len(file) - entry.offset {
			return nil, fmt.tprintf("the entry %d lies outside the file", index)
		}
		width, height, is_png := site_png_size(file[entry.offset:][:entry.bytes])
		if !is_png || width != entry.width || height != entry.height {
			return nil, fmt.tprintf("the entry %d is not a PNG file of %d by %d", index, entry.width, entry.height)
		}
		list[index] = entry
	}
	return list, ""
}

// site_color_hex gives "#rrggbb".
site_color_hex :: proc(color: u32) -> string {
	return fmt.tprintf("#%06x", color & 0xFFFFFF)
}

// site_gradient_end_colors gives the colors of a part at the start and at
// the end of its gradient, as src/library/support/mark computes them: a channel c is
// 0.7 * c + 76.5 at the start and 0.7 * c at the end, rounded to the
// nearest whole value.
site_gradient_end_colors :: proc(base: u32) -> (start, end: u32) {
	for shift in ([]u32{16, 8, 0}) {
		channel := int((base >> shift) & 0xFF)
		start |= u32(min((14 * channel + 1530 + 10) / 20, 255)) << shift
		end |= u32((7 * channel + 5) / 10) << shift
	}
	return
}

// site_icon_svg gives the heron as an SVG file: one rectangle for each run
// of cells of one part in a row, each part filled with its gradient (an SVG
// gradient along the diagonal of the box of the part, in cells, which is the
// gradient of src/library/support/mark) or its flat color. The colors are those of the
// light form, which reads on a light and on a dark tab; a rule for a dark
// scheme gives the dark form where the two forms differ. A browser that
// does not apply the rule shows the light form.
site_icon_svg :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	grid := mark.HERON_GRID_SIZE
	fmt.sbprintf(&b, "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 %d %d\" width=\"%d\" height=\"%d\" shape-rendering=\"crispEdges\">\n", grid, grid, grid, grid)
	// The rule of the dark scheme: only the parts whose two forms differ.
	dark_rules := strings.builder_make(context.temp_allocator)
	for part in mark.parts {
		if part.color_on_light == part.color_on_dark {
			continue
		}
		// The rules are joined from pieces: a brace is not written through a
		// format of fmt.
		letter := string([]u8{part.letter})
		if part.flat {
			strings.write_string(&dark_rules, strings.concatenate({".part-", letter, " { fill: ", site_color_hex(part.color_on_dark), "; }\n"}, context.temp_allocator))
		} else {
			start, end := site_gradient_end_colors(part.color_on_dark)
			strings.write_string(&dark_rules, strings.concatenate({".stop-", letter, "-start { stop-color: ", site_color_hex(start), "; }\n"}, context.temp_allocator))
			strings.write_string(&dark_rules, strings.concatenate({".stop-", letter, "-end { stop-color: ", site_color_hex(end), "; }\n"}, context.temp_allocator))
		}
	}
	if strings.builder_len(dark_rules) > 0 {
		strings.write_string(&b, "<style>\n@media (prefers-color-scheme: dark) {\n")
		strings.write_string(&b, strings.to_string(dark_rules))
		strings.write_string(&b, "}\n</style>\n")
	}
	strings.write_string(&b, "<defs>\n")
	for part in mark.parts {
		if part.flat {
			continue
		}
		start, end := site_gradient_end_colors(part.color_on_light)
		box := part.box
		fmt.sbprintf(&b, "<linearGradient id=\"gradient-%c\" gradientUnits=\"userSpaceOnUse\" x1=\"%d\" y1=\"%d\" x2=\"%d\" y2=\"%d\">", rune(part.letter), box.first_column, box.first_row, box.last_column + 1, box.last_row + 1)
		fmt.sbprintf(&b, "<stop offset=\"0\" class=\"stop-%c-start\" stop-color=\"%s\"/><stop offset=\"1\" class=\"stop-%c-end\" stop-color=\"%s\"/></linearGradient>\n", rune(part.letter), site_color_hex(start), rune(part.letter), site_color_hex(end))
	}
	strings.write_string(&b, "</defs>\n")
	for row in 0 ..< grid {
		column := 0
		for column < grid {
			index, found := mark.heron_cell_part(column, row)
			if !found {
				column += 1
				continue
			}
			run_end := column + 1
			for run_end < grid {
				next, next_found := mark.heron_cell_part(run_end, row)
				if !next_found || next != index {
					break
				}
				run_end += 1
			}
			part := mark.parts[index]
			if part.flat {
				fmt.sbprintf(&b, "<rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"1\" class=\"part-%c\" fill=\"%s\"/>\n", column, row, run_end - column, rune(part.letter), site_color_hex(part.color_on_light))
			} else {
				fmt.sbprintf(&b, "<rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"1\" fill=\"url(#gradient-%c)\"/>\n", column, row, run_end - column, rune(part.letter))
			}
			column = run_end
		}
	}
	strings.write_string(&b, "</svg>\n")
	return strings.to_string(b)
}

// site_icon_problems checks the icons that the pages and the manifest name:
//   favicon.ico is at the root, its directory reads back, and it has a
//   picture of 32 by 32;
//   each icon of the head of each page and of the manifest is a file of the
//   site, with the size that the page or the manifest states;
//   the icon of a phone and each maskable icon are opaque;
//   the manifest has an icon of 192 and of 512 for any use, and a maskable
//   one of 512.
// The icon files are each file of the site that the check reads: their path
// in the site and their bytes.
site_icon_problems :: proc(pages: []Site_Page, written: map[string]string, manifest: string, icon_files: map[string][]u8) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	if favicon, has_favicon := icon_files[SITE_FAVICON]; !has_favicon {
		append(&problems, SITE_FAVICON + " is not at the root of the site")
	} else {
		entries, problem := site_ico_read(favicon)
		if problem != "" {
			append(&problems, fmt.tprintf("%s: %s", SITE_FAVICON, problem))
		}
		has_32 := false
		for entry in entries {
			has_32 ||= entry.width == 32 && entry.height == 32
		}
		if problem == "" && !has_32 {
			append(&problems, SITE_FAVICON + " has no picture of 32 by 32")
		}
	}
	// size_problem checks one icon: it exists, a stated size is its size,
	// and an icon that must be opaque is.
	size_problem :: proc(icon_files: map[string][]u8, path, sizes: string, must_be_opaque: bool) -> string {
		data, found := icon_files[path]
		if !found {
			return fmt.tprintf("%s is not an icon that the command wrote", path)
		}
		if strings.has_suffix(path, ".png") {
			width, height, _ := site_png_size(data)
			if sizes != "" && sizes != fmt.tprintf("%dx%d", width, height) {
				return fmt.tprintf("%s is %d by %d, and its size is stated as %s", path, width, height, sizes)
			}
			if must_be_opaque && !site_png_is_opaque(data) {
				return fmt.tprintf("%s is not opaque", path)
			}
		} else if must_be_opaque {
			return fmt.tprintf("%s must be an opaque PNG file", path)
		}
		return ""
	}
	for page in pages {
		html := written[page.path]
		folder := page.path[:max(strings.last_index_byte(page.path, '/'), 0)]
		rest := html
		head_icons := 0
		for {
			start := strings.index(rest, "<link ")
			if start < 0 {
				break
			}
			end := strings.index_byte(rest[start:], '>')
			if end < 0 {
				break
			}
			tag := rest[start:start + end]
			rest = rest[start + end:]
			relation := site_first_attribute_value(tag, "rel=\"")
			if relation != "icon" && relation != "apple-touch-icon" {
				continue
			}
			head_icons += 1
			path := site_path_join(folder, site_first_attribute_value(tag, "href=\""))
			sizes := site_first_attribute_value(tag, "sizes=\"")
			if strings.has_suffix(path, ".ico") {
				sizes = "" // The ICO holds several sizes; its directory is checked above.
			}
			if problem := size_problem(icon_files, path, sizes, relation == "apple-touch-icon"); problem != "" {
				append(&problems, fmt.tprintf("%s: %s", page.path, problem))
			}
		}
		if head_icons == 0 {
			append(&problems, fmt.tprintf("%s: no icon in the head", page.path))
		}
	}
	value, err := json.parse_string(manifest, .JSON, false, context.temp_allocator)
	root, is_object := value.(json.Object)
	if err != .None || !is_object {
		append(&problems, SITE_MANIFEST + " does not parse")
		return problems[:]
	}
	icons, _ := root["icons"].(json.Array)
	any_192, any_512, maskable_512 := false, false, false
	for icon in icons {
		object, is_icon := icon.(json.Object)
		if !is_icon {
			continue
		}
		source, _ := object["src"].(json.String)
		sizes, _ := object["sizes"].(json.String)
		purpose, _ := object["purpose"].(json.String)
		maskable := purpose == "maskable"
		if problem := size_problem(icon_files, source, sizes, maskable); problem != "" {
			append(&problems, fmt.tprintf("%s: %s", SITE_MANIFEST, problem))
		}
		any_192 ||= !maskable && sizes == "192x192"
		any_512 ||= !maskable && sizes == "512x512"
		maskable_512 ||= maskable && sizes == "512x512"
	}
	if !any_192 || !any_512 || !maskable_512 {
		append(&problems, SITE_MANIFEST + " needs an icon of 192 and of 512 for any use, and a maskable icon of 512")
	}
	return problems[:]
}
