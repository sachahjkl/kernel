package kerneltool

import "core:fmt"
import "core:image/png"
import "core:os"
import "support:mark"

// The files of the mark of the system (docs/DESIGN.md, section "The mark").
// support/mark holds the mark as data; the command `logo` draws each file
// from it, and `check` verifies that the files of the repository have the
// pixels that the data gives now.
//
// The PNG writer is the one of the Odin standard library (core:image/png):
// it compresses the pixels and it writes an alpha channel. The writer of the
// pictures of the screen (png_encode) has neither, and a mark of 1024 by 1024
// pixels with no compression is 3 MiB in the repository.

LOGO_FOLDER :: "resources/logo"
PROJECT_IMAGE :: ".project/image.png"

// What is under the mark. A transparent picture has an alpha channel: the
// heron keeps the colors of the dark background.
Logo_Background :: enum {
	Dark,
	Light,
	Transparent,
}

// One file of the mark: a square picture, the heron at its place, and the
// name under it or no name.
Logo_Picture :: struct {
	path:            string,
	size:            int, // The width and the height, in pixels.
	background:      Logo_Background,
	heron_cell_size: int,
	heron_left:      int,
	heron_top:       int,
	with_name:       bool,
	name_cell_size:  int,
	name_left:       int,
	name_top:        int,
}

// The mark with the name: the heron with cells of 24 pixels, the name with
// cells of 20 pixels, 44 pixels between them, the whole centred. These are
// twice the sizes of the picture that the owner chose.
LOGO_WITH_NAME_SIZE :: 1024
LOGO_WITH_NAME_HERON_CELL_SIZE :: 24
LOGO_WITH_NAME_NAME_CELL_SIZE :: 20
LOGO_WITH_NAME_GAP :: 44

logo_pictures :: proc() -> []Logo_Picture {
	pictures := make([dynamic]Logo_Picture, context.temp_allocator)
	heron_size := mark.heron_size(LOGO_WITH_NAME_HERON_CELL_SIZE)
	name_width, name_height := mark.name_size(LOGO_WITH_NAME_NAME_CELL_SIZE)
	top := (LOGO_WITH_NAME_SIZE - (heron_size + LOGO_WITH_NAME_GAP + name_height)) / 2
	with_name := Logo_Picture {
		size            = LOGO_WITH_NAME_SIZE,
		heron_cell_size = LOGO_WITH_NAME_HERON_CELL_SIZE,
		heron_left      = (LOGO_WITH_NAME_SIZE - heron_size) / 2,
		heron_top       = top,
		with_name       = true,
		name_cell_size  = LOGO_WITH_NAME_NAME_CELL_SIZE,
		name_left       = (LOGO_WITH_NAME_SIZE - name_width) / 2,
		name_top        = top + heron_size + LOGO_WITH_NAME_GAP,
	}
	with_name.path = LOGO_FOLDER + "/modus.png"
	with_name.background = .Dark
	append(&pictures, with_name)
	with_name.path = LOGO_FOLDER + "/modus_light.png"
	with_name.background = .Light
	append(&pictures, with_name)
	// The heron alone, on nothing, for a file to use, and the sizes of an
	// icon: one cell is 32, 1, 2, 4 or 8 pixels.
	heron_alone := [?]struct {
		path:      string,
		cell_size: int,
	} {
		{LOGO_FOLDER + "/heron_768.png", 32},
		{LOGO_FOLDER + "/heron_24.png", 1},
		{LOGO_FOLDER + "/heron_48.png", 2},
		{LOGO_FOLDER + "/heron_96.png", 4},
		{LOGO_FOLDER + "/heron_192.png", 8},
	}
	for alone in heron_alone {
		append(&pictures, Logo_Picture{path = alone.path, size = mark.heron_size(alone.cell_size), background = .Transparent, heron_cell_size = alone.cell_size})
	}
	// The mark of the project, where the other projects of the owner keep
	// theirs: the heron alone, centred, on the dark background.
	PROJECT_IMAGE_SIZE :: 512
	PROJECT_IMAGE_CELL_SIZE :: 16
	project_margin := (PROJECT_IMAGE_SIZE - mark.heron_size(PROJECT_IMAGE_CELL_SIZE)) / 2
	append(&pictures, Logo_Picture{path = PROJECT_IMAGE, size = PROJECT_IMAGE_SIZE, background = .Dark, heron_cell_size = PROJECT_IMAGE_CELL_SIZE, heron_left = project_margin, heron_top = project_margin})
	return pictures[:]
}

logo_picture_channels :: proc(picture: Logo_Picture) -> int {
	return 4 if picture.background == .Transparent else 3
}

// logo_picture_pixels draws one file of the mark: red, green and blue for
// each pixel, and alpha when the background is transparent.
logo_picture_pixels :: proc(picture: Logo_Picture) -> []u8 {
	channels := logo_picture_channels(picture)
	on_light := picture.background == .Light
	pixels := make([]u8, picture.size * picture.size * channels, context.temp_allocator)
	for y in 0 ..< picture.size {
		for x in 0 ..< picture.size {
			color, covered := mark.mark_pixel(picture.heron_cell_size, x - picture.heron_left, y - picture.heron_top, on_light)
			if !covered && picture.with_name {
				color, covered = mark.name_pixel(picture.name_cell_size, x - picture.name_left, y - picture.name_top, on_light)
			}
			if !covered && picture.background != .Transparent {
				color, covered = mark.background_color(on_light), true
			}
			pixel := pixels[(y * picture.size + x) * channels:][:channels]
			if !covered {
				continue // Transparent: all four bytes stay 0.
			}
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

logo_picture_encode :: proc(picture: Logo_Picture) -> (file: []u8, ok: bool) {
	pixels := logo_picture_pixels(picture)
	image := png.Image {
		width    = picture.size,
		height   = picture.size,
		channels = logo_picture_channels(picture),
		depth    = 8,
	}
	image.pixels = make([dynamic]u8, len(pixels), len(pixels), context.temp_allocator)
	copy(image.pixels[:], pixels)
	output := make([dynamic]u8, context.temp_allocator)
	if err := png.save_to_buffer(&output, &image, allocator = context.temp_allocator); err != nil {
		fmt.eprintfln("kerneltool: cannot encode %s: %v", picture.path, err)
		return nil, false
	}
	return output[:], true
}

run_logo :: proc(args: []string) -> int {
	if len(args) != 0 {
		fmt.eprintln("kerneltool: logo takes no argument")
		return EXIT_USAGE
	}
	if !make_folder(LOGO_FOLDER) || !make_folder(".project") {
		return EXIT_FAILURE
	}
	for picture in logo_pictures() {
		file, ok := logo_picture_encode(picture)
		if !ok {
			return EXIT_FAILURE
		}
		if err := os.write_entire_file(picture.path, file); err != nil {
			fmt.eprintfln("kerneltool: cannot write %s: %v", picture.path, err)
			return EXIT_FAILURE
		}
		fmt.printfln("kerneltool: wrote %s (%d by %d pixels, %d bytes)", picture.path, picture.size, picture.size, len(file))
	}
	return 0
}

// logo_check verifies that each file of the mark in the repository has the
// size, the channels and the pixels that support/mark gives now. It compares
// the pixels, not the bytes of the file: the bytes of the compressed stream
// depend on the compressor of the Odin release, the pixels do not.
logo_check :: proc() -> bool {
	for picture in logo_pictures() {
		data, read_error := os.read_entire_file(picture.path, context.temp_allocator)
		if read_error != nil {
			fmt.eprintfln("kerneltool: test failed: cannot read %s (%v): run kerneltool logo", picture.path, read_error)
			return false
		}
		image, load_error := png.load_from_bytes(data)
		if load_error != nil {
			fmt.eprintfln("kerneltool: test failed: %s is not a PNG file that can be read (%v): run kerneltool logo", picture.path, load_error)
			return false
		}
		defer png.destroy(image)
		expected := logo_picture_pixels(picture)
		same := image.width == picture.size && image.height == picture.size && image.channels == logo_picture_channels(picture) && image.depth == 8 && len(image.pixels) == len(expected)
		if same {
			for index in 0 ..< len(expected) {
				if image.pixels[index] != expected[index] {
					same = false
					break
				}
			}
		}
		if !same {
			fmt.eprintfln("kerneltool: test failed: %s is not the picture of the data of support/mark: run kerneltool logo", picture.path)
			return false
		}
		fmt.printfln("kerneltool: test passed: %s is the picture of the data of support/mark", picture.path)
	}
	return true
}
