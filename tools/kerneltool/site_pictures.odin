// The pictures of the mark that the site draws itself from support/mark
// (docs/SITE.md, "The mark on the site"). On the pages the mark is drawn on
// nothing: a transparent picture over the page, one for each color scheme.
// The heron of a page has one pixel for each cell, and the style sheet of
// the page gives a cell its size, a whole count of page pixels, with no
// smoothing. The picture for other sites (the card) has its real pixels and
// keeps the dark background: those sites show it on white, with no style
// sheet of this site.
package kerneltool

import "core:fmt"
import "core:image/png"
import "support:mark"

Site_Mark_Picture :: struct {
	file_name:  string, // In the picture folder of the site.
	heron_cell: int,
	name_cell:  int, // 0: the heron alone.
	gap:        int, // Pixels between the heron and the name.
	on_light:   bool, // The colors of the light background: the darker neck, the dark name.
	opaque:     bool, // On the dark background of the system, not transparent.
	width:      int, // 0: the size of the drawing. Else the drawing is centred in width by height.
	height:     int,
}

SITE_MARK_HERON :: "mark_heron.png"
SITE_MARK_HERON_LIGHT :: "mark_heron_light.png"
SITE_MARK_CARD :: "mark_card.png"

// The heron of a page is one picture with one pixel for each cell, 24 by
// 24 pixels: a cell of the heron has one color, so more pixels for a cell
// say nothing more. The page gives the cell its size: the style sheet
// shows the picture at a whole count of page pixels for each cell, with no
// smoothing. The bar shows it at 1 pixel for a cell, the head of the home
// at this many.
SITE_MARK_HOME_FACTOR :: 8
SITE_MARK_HOME_SIZE :: SITE_MARK_HOME_FACTOR * mark.HERON_GRID_SIZE

// The heron alone, cells of 1 pixel, in its two color schemes: the bar and
// the head of the home show it. On a page the name is text in the font of
// the name of the mark (site_mark_name.odin). The card for other sites,
// 1200 by 630, holds the name: it is one picture that another site shows
// with no page, no font and no style sheet of this site around it, so it
// has its real pixels.
site_mark_pictures := [?]Site_Mark_Picture {
	{file_name = SITE_MARK_HERON, heron_cell = 1},
	{file_name = SITE_MARK_HERON_LIGHT, heron_cell = 1, on_light = true},
	{file_name = SITE_MARK_CARD, heron_cell = 16, name_cell = 12, gap = 32, opaque = true, width = 1200, height = 630},
}

// site_mark_drawing_size gives the size of the heron and the name under it.
site_mark_drawing_size :: proc(picture: Site_Mark_Picture) -> (width, height: int) {
	heron := mark.heron_size(picture.heron_cell)
	width, height = heron, heron
	if picture.name_cell > 0 {
		name_width, name_height := mark.name_size(picture.name_cell)
		width = max(width, name_width)
		height = heron + picture.gap + name_height
	}
	return
}

site_mark_size :: proc(picture: Site_Mark_Picture) -> (width, height: int) {
	if picture.width > 0 {
		return picture.width, picture.height
	}
	return site_mark_drawing_size(picture)
}

// site_png_compress gives a PNG file with the same pixels as another, written
// by the encoder of the standard library (core:image/png: a row filter
// chosen for each row, then the deflate of core:compress/deflate at its
// default level). The screen pictures of the repository are stored with no
// compression, about 2.3 MB for 1024 by 768. The encoder reads no clock, no
// random number and no thread, so the same pixels give the same bytes at
// each build of the same compiler. Only 8 bits a channel: the pictures of
// the repository have no other depth.
site_png_compress :: proc(data: []u8) -> (compressed: []u8, ok: bool) {
	source, load_error := png.load_from_bytes(data, allocator = context.temp_allocator)
	if load_error != nil || source == nil || source.depth != 8 {
		return nil, false
	}
	output := make([dynamic]u8, context.temp_allocator)
	if save_error := png.save_to_buffer(&output, source, allocator = context.temp_allocator); save_error != nil {
		return nil, false
	}
	return output[:], true
}

// site_mark_encode draws one picture of the mark and gives its PNG file.
site_mark_encode :: proc(picture: Site_Mark_Picture) -> (file: []u8, ok: bool) {
	still := mark.still_cells()
	width, height := site_mark_size(picture)
	return site_pixels_encode(picture.file_name, width, height, site_mark_channels(picture), site_mark_pixels(picture, &still))
}

// site_mark_channels gives the bytes of a pixel of a picture of the mark:
// red, green and blue, and alpha when it is transparent.
site_mark_channels :: proc(picture: Site_Mark_Picture) -> int {
	return 3 if picture.opaque else 4
}

// site_mark_pixels draws one picture of the mark with the cells of one frame
// of the heron (the still heron, or a frame of an animation of
// support/mark): the bytes of each pixel, row by row.
site_mark_pixels :: proc(picture: Site_Mark_Picture, cells: ^mark.Heron_Cells) -> []u8 {
	width, height := site_mark_size(picture)
	drawing_width, drawing_height := site_mark_drawing_size(picture)
	left := (width - drawing_width) / 2
	top := (height - drawing_height) / 2
	heron := mark.heron_size(picture.heron_cell)
	heron_left := left + (drawing_width - heron) / 2
	name_width := 0
	if picture.name_cell > 0 {
		name_width, _ = mark.name_size(picture.name_cell)
	}
	name_left := left + (drawing_width - name_width) / 2
	name_top := top + heron + picture.gap
	channels := site_mark_channels(picture)
	pixels := make([]u8, width * height * channels, context.temp_allocator)
	for y in 0 ..< height {
		for x in 0 ..< width {
			color, covered := mark.cells_pixel(cells, picture.heron_cell, x - heron_left, y - top, picture.on_light)
			if !covered && picture.name_cell > 0 {
				color, covered = mark.name_pixel(picture.name_cell, x - name_left, y - name_top, picture.on_light)
			}
			if !covered && picture.opaque {
				color, covered = mark.background_color(picture.on_light), true
			}
			if !covered {
				continue // Transparent: the four bytes stay 0.
			}
			pixel := pixels[(y * width + x) * channels:][:channels]
			pixel[0] = u8(color >> 16)
			pixel[1] = u8(color >> 8)
			pixel[2] = u8(color)
			if channels == 4 {
				pixel[3] = 0xFF
			}
		}
	}
	return pixels
}

// site_pixels_encode gives the PNG file of pixels of 3 or 4 bytes; the name
// is for the message of a failure.
site_pixels_encode :: proc(name: string, width, height, channels: int, pixels: []u8) -> (file: []u8, ok: bool) {
	image := png.Image {
		width    = width,
		height   = height,
		channels = channels,
		depth    = 8,
	}
	image.pixels = make([dynamic]u8, len(pixels), len(pixels), context.temp_allocator)
	copy(image.pixels[:], pixels)
	output := make([dynamic]u8, context.temp_allocator)
	if err := png.save_to_buffer(&output, &image, allocator = context.temp_allocator); err != nil {
		fmt.eprintfln("kerneltool: site: cannot encode %s: %v", name, err)
		return nil, false
	}
	return output[:], true
}

// site_pixels_encode_smallest gives the smallest PNG file that the encoder
// of the standard library writes for pixels of 3 or 4 bytes: the highest
// level of its deflate, and each of its row filters in turn (none, sub,
// up, average, Paeth, and the one chosen row by row), the smallest file
// kept. The pixels are the same in each: nothing is lost. It is for a
// small picture that each reader of the site loads: it compresses the
// pixels six times. Which filter wins depends on the pixels only, so the
// same pixels give the same bytes.
site_pixels_encode_smallest :: proc(name: string, width, height, channels: int, pixels: []u8) -> (file: []u8, ok: bool) {
	image := png.Image {
		width    = width,
		height   = height,
		channels = channels,
		depth    = 8,
	}
	image.pixels = make([dynamic]u8, len(pixels), len(pixels), context.temp_allocator)
	copy(image.pixels[:], pixels)
	for strategy in png.Filter_Strategy {
		output := make([dynamic]u8, context.temp_allocator)
		if err := png.save_to_buffer(&output, &image, level = .Best, filter = strategy, allocator = context.temp_allocator); err != nil {
			fmt.eprintfln("kerneltool: site: cannot encode %s: %v", name, err)
			return nil, false
		}
		if file == nil || len(output) < len(file) {
			file = output[:]
		}
	}
	return file, true
}
