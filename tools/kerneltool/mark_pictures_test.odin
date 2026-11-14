package kerneltool

import "core:encoding/json"
import "core:image/png"
import "core:os"
import "core:strings"
import "core:testing"
import "modus:support/mark"

// The request of a test: the still picture of the home of the site.
@(private = "file")
home_request :: proc(what: Mark_What) -> Mark_Request {
	return Mark_Request{what = what, picture = Mark_Picture{file_name = "test.png", variant = .Smooth, heron_cell = 8}, with_forms = true}
}

// Each kind of request gives its file: the still mark and a frame are PNG
// pictures of the size of the request with the pixels of src/library/support/mark; a
// tile map is a PNG picture of the size of its layout; a table is JSON.
@(test)
mark_generator_serves_each_kind_of_request :: proc(t: ^testing.T) {
	// The still mark, smooth, 8 pixels for a cell: 192 by 192 pixels.
	still_file, still_refusal := mark_generate(home_request(.Still))
	testing.expect_value(t, still_refusal, "")
	still := mark.still_cells()
	still_request := home_request(.Still)
	testing.expect(t, png_has_pixels(still_file, 192, 192, 4, mark_picture_pixels(still_request.picture, &still)))
	// The same in the cells variant at one pixel for a cell, on the
	// background of the light scheme, centred in 32 by 32: no alpha.
	icon := Mark_Request{what = .Still, picture = Mark_Picture{file_name = "test.png", variant = .Cells, heron_cell = 1, on_light = true, opaque = true, width = 32, height = 32}}
	icon_file, icon_refusal := mark_generate(icon)
	testing.expect_value(t, icon_refusal, "")
	icon_pixels := mark_picture_pixels(icon.picture, &still)
	testing.expect(t, png_has_pixels(icon_file, 32, 32, 3, icon_pixels))
	icon_image, icon_error := png.load_from_bytes(icon_file, allocator = context.temp_allocator)
	testing.expect(t, icon_error == nil && icon_image != nil)
	if icon_image != nil {
		testing.expect_value(t, icon_image.width, 32)
		testing.expect_value(t, icon_image.channels, 3)
	}
	// The corner is the light background; each pixel of the heron is the
	// color of its cell, 4 pixels in.
	background := mark.background_color(true)
	testing.expect_value(t, icon_pixels[0], u8(background >> 16))
	covered_count := 0
	for row in 0 ..< mark.HERON_GRID_SIZE {
		for column in 0 ..< mark.HERON_GRID_SIZE {
			color, covered := mark.mark_pixel(1, column, row, .Cells, true)
			if !covered {
				continue
			}
			covered_count += 1
			pixel := icon_pixels[((row + 4) * 32 + column + 4) * 3:][:3]
			testing.expectf(t, u32(pixel[0]) << 16 | u32(pixel[1]) << 8 | u32(pixel[2]) == color, "the pixel of the cell %d, %d of the icon is not the color of the cell", column, row)
		}
	}
	testing.expect(t, covered_count > 0)
	// A frame: the second frame of the dash.
	frame := home_request(.Frame)
	frame.has_animation, frame.animation, frame.frame = true, .Dash, 2
	frame_file, frame_refusal := mark_generate(frame)
	testing.expect_value(t, frame_refusal, "")
	run, _ := mark.animation_frame_cells(.Dash, 2)
	testing.expect(t, png_has_pixels(frame_file, 192, 192, 4, mark_picture_pixels(frame.picture, &run)))
	testing.expect(t, !png_has_pixels(frame_file, 192, 192, 4, mark_picture_pixels(frame.picture, &still)))
	// The tile map of one animation, with its forms, in rows of at most
	// 1024 pixels: the still heron and the distinct frames of the dash, 5
	// in a row; under them its 7 drawn forms, 4 in a row.
	sheet := home_request(.Tile_Map)
	sheet.has_animation, sheet.animation, sheet.width_most = true, .Dash, 1024
	tile_map, built := mark_tile_map_build(sheet.picture, true, .Dash, true, 1024)
	testing.expect(t, built)
	sprite_count := len(tile_map.sprites.cells)
	testing.expect(t, sprite_count > 5 && sprite_count <= 1 + mark.animation_frame_count(.Dash))
	testing.expect_value(t, len(tile_map.forms.drawn), 7)
	testing.expect_value(t, tile_map.layout.sprite_columns, 5)
	testing.expect_value(t, tile_map.layout.form_columns, 4)
	testing.expect_value(t, tile_map.layout.width, 1024)
	testing.expect_value(t, tile_map.layout.height, ((sprite_count + 4) / 5) * 192 + 2 * 208)
	testing.expect_value(t, len(tile_map.sprites.of_frame[.Hop]), 0)
	testing.expect_value(t, len(tile_map.forms.steps[.Hop]), 0)
	sheet_file, sheet_refusal := mark_generate(sheet)
	testing.expect_value(t, sheet_refusal, "")
	pixels, width, height, channels := mark_tile_map_pixels(&tile_map)
	testing.expect(t, png_has_pixels(sheet_file, width, height, channels, pixels))
	// The table of that tile map: JSON, with the one animation, its steps
	// and the keys of its move.
	table_request := sheet
	table_request.what = .Table
	table_file, table_refusal := mark_generate(table_request)
	testing.expect_value(t, table_refusal, "")
	value, err := json.parse_string(string(table_file), .JSON, false, context.temp_allocator)
	root, is_object := value.(json.Object)
	testing.expectf(t, err == .None && is_object, "the table does not parse: %v", err)
	if is_object {
		animations, _ := root["animations"].(json.Array)
		testing.expect_value(t, len(animations), 1)
		sprites, _ := root["sprites"].(json.Float)
		columns, _ := root["columns"].(json.Float)
		testing.expect_value(t, int(sprites), sprite_count)
		testing.expect_value(t, int(columns), 5)
		if len(animations) == 1 {
			dash, _ := animations[0].(json.Object)
			name, _ := dash["name"].(json.String)
			motion, has_motion := dash["motion"].(json.Array)
			testing.expect_value(t, name, "dash")
			testing.expect(t, has_motion && len(motion) > 1)
		}
	}
	// The tile map of the frames only, in the cells variant: no form, and
	// each step shows the sprite of its frame.
	frames_only, frames_built := mark_tile_map_build(Mark_Picture{variant = .Cells, heron_cell = 1, on_light = true}, false, .Blink, false, 0)
	testing.expect(t, frames_built)
	testing.expect_value(t, len(frames_only.forms.drawn), 0)
	testing.expect_value(t, frames_only.layout.width, 384)
	testing.expect_value(t, frames_only.layout.height, 72)
	for step in frames_only.forms.steps[.Dash] {
		testing.expect_value(t, step.form, -1)
	}
	// Each pixel of a tile of the cells tile map is the color of its cell.
	cells_pixels, cells_width, _, _ := mark_tile_map_pixels(&frames_only)
	for &cells, index in frames_only.sprites.cells {
		left := (index % MARK_TILE_MAP_COLUMNS) * mark.HERON_GRID_SIZE
		top := (index / MARK_TILE_MAP_COLUMNS) * mark.HERON_GRID_SIZE
		for row in 0 ..< mark.HERON_GRID_SIZE {
			for column in 0 ..< mark.HERON_GRID_SIZE {
				pixel := cells_pixels[((top + row) * cells_width + left + column) * 4:][:4]
				color, covered := mark.cells_pixel(&cells, 1, column, row, .Cells, true)
				written := u32(pixel[0]) << 16 | u32(pixel[1]) << 8 | u32(pixel[2])
				if covered != (pixel[3] == 0xFF) || (covered && written != color) {
					testing.expectf(t, false, "the pixel %d, %d of the sprite %d of the cells tile map is not its cell", column, row, index)
					return
				}
			}
		}
	}
}

// A request with no sense is refused with a sentence that says why. The
// generator bends no request into another one.
@(test)
mark_generator_refuses_a_request_with_no_sense :: proc(t: ^testing.T) {
	Case :: struct {
		request: Mark_Request,
		words:   string, // Words of the sentence of the refusal.
	}
	smooth_at_one := home_request(.Still)
	smooth_at_one.picture.heron_cell = 1
	no_cell := home_request(.Still)
	no_cell.picture.heron_cell = 0
	too_large_cell := home_request(.Still)
	too_large_cell.picture.heron_cell = mark.CELL_SIZE_LIMIT + 1
	half_size := home_request(.Still)
	half_size.picture.width = 400
	too_small := home_request(.Still)
	too_small.picture.width, too_small.picture.height = 100, 100
	too_wide := home_request(.Still)
	too_wide.picture.heron_cell = 400
	gap_alone := home_request(.Still)
	gap_alone.picture.gap = 8
	still_frame := home_request(.Still)
	still_frame.frame = 2
	frame_of_nothing := home_request(.Frame)
	frame_past_end := home_request(.Frame)
	frame_past_end.has_animation, frame_past_end.animation, frame_past_end.frame = true, .Blink, 1000
	sheet_with_name := home_request(.Tile_Map)
	sheet_with_name.picture.name_cell = 4
	sheet_opaque := home_request(.Tile_Map)
	sheet_opaque.picture.opaque = true
	sheet_of_frame := home_request(.Tile_Map)
	sheet_of_frame.frame = 1
	sheet_too_narrow := home_request(.Table)
	sheet_too_narrow.width_most = 200
	cases := [?]Case {
		{smooth_at_one, "the smooth variant needs at least 2 pixels for a cell"},
		{no_cell, "a whole count of pixels from 1"},
		{too_large_cell, "a whole count of pixels from 1"},
		{half_size, "a width and a height, or neither"},
		{too_small, "the drawing does not fit"},
		{too_wide, "a side is at most 8192"},
		{gap_alone, "a gap under the heron needs the name"},
		{still_frame, "the still mark has no animation and no frame"},
		{frame_of_nothing, "name the animation"},
		{frame_past_end, "and 0 is the still heron: not 1000"},
		{sheet_with_name, "a tile map holds the heron alone"},
		{sheet_opaque, "a tile map holds the heron alone"},
		{sheet_of_frame, "it takes no frame"},
		{sheet_too_narrow, "one tile is wider"},
	}
	for entry, index in cases {
		file, refusal := mark_generate(entry.request)
		testing.expectf(t, file == nil && strings.contains(refusal, entry.words), "the case %d: the refusal is %q", index, refusal)
	}
	// The same pictures with sense are served: the cells variant at one
	// pixel for a cell, and the smooth one at two.
	cells_at_one := home_request(.Still)
	cells_at_one.picture.variant, cells_at_one.picture.heron_cell = .Cells, 1
	testing.expect_value(t, mark_request_refusal(cells_at_one), "")
	smooth_at_two := home_request(.Still)
	smooth_at_two.picture.heron_cell = 2
	testing.expect_value(t, mark_request_refusal(smooth_at_two), "")
	frame_zero := home_request(.Frame)
	frame_zero.has_animation, frame_zero.animation = true, .Blink
	testing.expect_value(t, mark_request_refusal(frame_zero), "")
}

// The table of the uses: no row is refused; no two rows are one file; a
// picture of one pixel for a cell is the cells variant and each other one
// the smooth variant; the pair of a color scheme differs by its colors
// only; a tile map is the heron alone on nothing. The guide quotes the
// table (docs/DESIGN.md, "The variants of the mark"), and `kerneltool mark
// uses` prints it.
@(test)
mark_uses_name_a_variant_that_fits_each_file :: proc(t: ^testing.T) {
	testing.expect_value(t, len(mark_uses), 18)
	testing.expect_value(t, len(mark_uses_pictures(.Repository, .Picture)), 10)
	testing.expect_value(t, len(mark_uses_pictures(.Site, .Picture)), 5)
	testing.expect_value(t, len(mark_uses_pictures(.Site, .Tile_Map)), 2)
	testing.expect_value(t, len(mark_uses_pictures(.Site, .Tile_Map_Of_Frames)), 1)
	for use, index in mark_uses {
		picture := use.picture
		testing.expectf(t, mark_picture_refusal(picture) == "", "%s is refused: %s", picture.file_name, mark_picture_refusal(picture))
		testing.expectf(t, (picture.heron_cell == 1) == (picture.variant == .Cells), "%s: %v at %d pixels for a cell", picture.file_name, picture.variant, picture.heron_cell)
		for other in mark_uses[index + 1:] {
			testing.expectf(t, other.picture.file_name != picture.file_name, "%s is in the table two times", picture.file_name)
		}
		if use.kind != .Picture {
			request := Mark_Request{what = .Tile_Map, picture = picture, with_forms = use.kind == .Tile_Map}
			testing.expectf(t, mark_request_refusal(request) == "", "the tile map %s is refused: %s", picture.file_name, mark_request_refusal(request))
		}
		found, is_found := mark_use_picture(picture.file_name)
		testing.expect(t, is_found && found == picture)
	}
	// Pinned: the uses that the variants were decided for.
	Pinned :: struct {
		file_name: string,
		variant:   mark.Variant,
		cell:      int,
	}
	pinned := [?]Pinned {
		{SITE_MARK_HOME, .Smooth, 8},
		{SITE_MARK_HOME_LIGHT, .Smooth, 8},
		{SITE_MARK_ANIMATION_HOME, .Smooth, 8},
		{SITE_MARK_ANIMATION_HOME_LIGHT, .Smooth, 8},
		{SITE_MARK_BAR, .Cells, 1},
		{SITE_MARK_BAR_LIGHT, .Cells, 1},
		{SITE_MARK_ANIMATION_ICON, .Cells, 1},
		{SITE_MARK_CARD, .Smooth, 16},
		{LOGO_FOLDER + "/heron_24.png", .Cells, 1},
		{LOGO_FOLDER + "/heron_48.png", .Smooth, 2},
		{LOGO_FOLDER + "/modus.png", .Smooth, 24},
		{PROJECT_IMAGE, .Smooth, 16},
	}
	for entry in pinned {
		picture, found := mark_use_picture(entry.file_name)
		testing.expectf(t, found && picture.variant == entry.variant && picture.heron_cell == entry.cell, "%s: %v at %d pixels for a cell", entry.file_name, picture.variant, picture.heron_cell)
	}
	// The icons of the site follow the same rule; their rows are in the
	// table of the icons.
	for icon in site_icons {
		picture := site_icon_picture(icon)
		testing.expectf(t, mark_picture_refusal(picture) == "" && (picture.heron_cell == 1) == (picture.variant == .Cells), "the icon of %d pixels: %v at %d pixels for a cell", icon.size, picture.variant, picture.heron_cell)
	}
	_, missing := mark_use_picture("no_such_file.png")
	testing.expect(t, !missing)
}

// The PNG file of the generator is the smallest of the encoder: not larger
// than the file at the common level, with the same pixels, and the same
// bytes at each call.
@(test)
mark_png_is_the_smallest_of_the_encoder :: proc(t: ^testing.T) {
	picture := Mark_Picture{file_name = "test.png", variant = .Smooth, heron_cell = 4}
	still := mark.still_cells()
	pixels := mark_picture_pixels(picture, &still)
	smallest, smallest_ok := mark_pixels_png("test.png", 96, 96, 4, pixels)
	common, common_ok := mark_pixels_png_quick("test.png", 96, 96, 4, pixels)
	testing.expect(t, smallest_ok && common_ok)
	testing.expectf(t, len(smallest) <= len(common), "%d bytes at the highest level, %d at the common one", len(smallest), len(common))
	testing.expect(t, png_has_pixels(smallest, 96, 96, 4, pixels))
	testing.expect(t, png_has_pixels(common, 96, 96, 4, pixels))
	again, _ := mark_pixels_png("test.png", 96, 96, 4, pixels)
	testing.expect(t, string(again) == string(smallest), "two encodings of one picture differ")
}

// The command reads its words into a request: what, then pairs of an
// option and a value. A word that it does not know, a value with a part
// of a pixel and an option with no value are refused with a sentence.
@(test)
mark_command_reads_a_request :: proc(t: ^testing.T) {
	request, out, problem := mark_command_request([]string{"tile_map", "--animation", "dash", "--variant", "smooth", "--cell", "8", "--scheme", "light", "--width", "1024", "--out", "build/x.png"})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, out, "build/x.png")
	testing.expect_value(t, request.what, Mark_What.Tile_Map)
	testing.expect(t, request.has_animation && request.animation == .Dash && request.with_forms)
	testing.expect_value(t, request.picture.variant, mark.Variant.Smooth)
	testing.expect_value(t, request.picture.heron_cell, 8)
	testing.expect(t, request.picture.on_light && !request.picture.opaque)
	testing.expect_value(t, request.width_most, 1024)
	testing.expect_value(t, mark_request_refusal(request), "")
	// The defaults: the smooth heron at 8 pixels for a cell, dark, on
	// nothing, in the build folder.
	request, out, problem = mark_command_request([]string{"still"})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, out, BUILD_FOLDER + "/mark_still.png")
	testing.expect_value(t, request.picture, Mark_Picture{file_name = BUILD_FOLDER + "/mark_still.png", variant = .Smooth, heron_cell = 8})
	request, out, problem = mark_command_request([]string{"table", "--forms", "no"})
	testing.expect_value(t, problem, "")
	testing.expect_value(t, out, BUILD_FOLDER + "/mark_table.json")
	testing.expect(t, request.what == .Table && !request.with_forms)
	request, _, problem = mark_command_request([]string{"still", "--variant", "cells", "--cell", "1", "--background", "scheme", "--size", "32"})
	testing.expect_value(t, problem, "")
	testing.expect(t, request.picture.variant == .Cells && request.picture.heron_cell == 1 && request.picture.opaque && request.picture.width == 32 && request.picture.height == 32)
	// The card for other sites, as a request of the command: the row of the
	// table of the uses, but for the name of the file.
	request, _, problem = mark_command_request([]string{"still", "--cell", "16", "--name-cell", "12", "--gap", "32", "--background", "scheme", "--size", "1200x630", "--out", SITE_MARK_CARD})
	testing.expect_value(t, problem, "")
	card, card_found := mark_use_picture(SITE_MARK_CARD)
	testing.expect(t, card_found)
	testing.expect_value(t, request.picture, card)
	// The command reads the smooth variant at one pixel; the generator
	// refuses it.
	request, _, problem = mark_command_request([]string{"still", "--cell", "1"})
	testing.expect_value(t, problem, "")
	testing.expect(t, strings.contains(mark_request_refusal(request), "ask for the cells variant"))
	// Each case is the words of a command, joined by a space.
	problems := [?]string {
		"",
		"poster",
		"still --cell 1.5",
		"still --cell -2",
		"still --cell",
		"still --variant flat",
		"still --scheme sepia",
		"still --background white",
		"frame --animation moonwalk",
		"frame --frame two",
		"tile_map --forms maybe",
		"still --format svg",
		"still --size 1200x",
		"still --size 12.5x30",
	}
	for words, index in problems {
		_, _, sentence := mark_command_request(strings.fields(words, context.temp_allocator))
		testing.expectf(t, sentence != "", "the case %d of the command is not refused", index)
	}
	_, _, fraction := mark_command_request([]string{"still", "--cell", "1.5"})
	testing.expect(t, strings.contains(fraction, "no part of a pixel"))
}

// The files of the tool that draw a picture of the mark: the generator.
@(private = "file")
MARK_DRAWING_FILES :: [?]string{"tools/kerneltool/mark_pictures.odin", "tools/kerneltool/mark_tile_map.odin", "tools/kerneltool/mark_developer_picture.odin"}

// No other file of the tool calls a drawing procedure of src/library/support/mark:
// each picture file of the mark comes from the generator. The search is by
// the names of the procedures.
@(test)
only_the_generator_draws_the_mark :: proc(t: ^testing.T) {
	files := make([dynamic]string, context.temp_allocator)
	if !source_files_of_a_folder("tools/kerneltool", &files) {
		// The test does not run from the root of the repository: it has no
		// file to read, and says so.
		testing.expect(t, false, "the sources of tools/kerneltool are not readable from the folder of the test")
		return
	}
	procedures := [?]string{"mark.mark_draw(", "mark.mark_pixel(", "mark.cells_draw(", "mark.cells_pixel(", "mark.form_cells_draw(", "mark.form_cells_pixel(", "mark.name_draw(", "mark.name_pixel("}
	allowed := MARK_DRAWING_FILES
	read := 0
	for path in files {
		if strings.has_suffix(path, "_test.odin") {
			continue
		}
		is_allowed := false
		for allowed_path in allowed {
			if strings.has_suffix(path, allowed_path) || strings.has_suffix(allowed_path, path) {
				is_allowed = true
			}
		}
		bytes, read_error := os.read_entire_file(path, context.temp_allocator)
		if read_error != nil {
			testing.expectf(t, false, "cannot read %s", path)
			continue
		}
		read += 1
		for procedure in procedures {
			testing.expectf(t, is_allowed || !strings.contains(string(bytes), procedure), "%s calls %s: a picture of the mark comes from the generator", path, procedure)
		}
	}
	testing.expect(t, read > 50)
}
