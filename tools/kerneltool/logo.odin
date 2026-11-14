package kerneltool

import "core:fmt"
import "core:image/png"
import "core:os"
import "support:mark"

// The files of the mark of the system in the repository (docs/DESIGN.md,
// section "The mark"). support/mark holds the mark as data. The command
// `logo` is a caller of the generator of the pictures of the mark
// (mark_pictures.odin): it asks for each row of the repository of the table
// of the uses, and writes the file. `check` verifies that the files of the
// repository have the pixels that the data gives now. This file computes
// no picture.
//
// The name of the mark is also a font file, written beside the pictures
// (mark_font.odin): a page that shows the heron alone writes the name as
// text in that font.

run_logo :: proc(args: []string) -> int {
	if len(args) != 0 {
		fmt.eprintln("kerneltool: logo takes no argument")
		return EXIT_USAGE
	}
	if !make_folder(LOGO_FOLDER) || !make_folder(".project") {
		return EXIT_FAILURE
	}
	for picture in mark_uses_pictures(.Repository, .Picture) {
		file, ok := mark_picture_png(picture)
		if !ok {
			return EXIT_FAILURE
		}
		if err := os.write_entire_file(picture.file_name, file); err != nil {
			fmt.eprintfln("kerneltool: cannot write %s: %v", picture.file_name, err)
			return EXIT_FAILURE
		}
		width, height := mark_picture_size(picture)
		fmt.printfln("kerneltool: wrote %s (%s, %d pixels for a cell, %d by %d pixels, %d bytes)", picture.file_name, mark.variant_names[picture.variant], picture.heron_cell, width, height, len(file))
	}
	// The font of the name of the mark, from the same letters as the pictures.
	if !mark_font_write() {
		return EXIT_FAILURE
	}
	// Every frame of the animations, for a developer to look at; in the build
	// folder, not in the repository.
	if !mark_animations_picture_write() {
		return EXIT_FAILURE
	}
	return 0
}

// logo_check verifies that each file of the mark in the repository has the
// size, the channels and the pixels that the generator gives now for its
// row of the table of the uses. It compares the pixels, not the bytes of
// the file: the bytes of the compressed stream depend on the compressor of
// the Odin release, the pixels do not. The font of the name is compared by
// its bytes: the tool writes each of them.
logo_check :: proc() -> bool {
	still := mark.still_cells()
	for picture in mark_uses_pictures(.Repository, .Picture) {
		data, read_error := os.read_entire_file(picture.file_name, context.temp_allocator)
		if read_error != nil {
			fmt.eprintfln("kerneltool: test failed: cannot read %s (%v): run kerneltool logo", picture.file_name, read_error)
			return false
		}
		image, load_error := png.load_from_bytes(data)
		if load_error != nil {
			fmt.eprintfln("kerneltool: test failed: %s is not a PNG file that can be read (%v): run kerneltool logo", picture.file_name, load_error)
			return false
		}
		defer png.destroy(image)
		if refusal := mark_picture_refusal(picture); refusal != "" {
			fmt.eprintfln("kerneltool: test failed: the picture %s of the table of the uses of the mark is refused: %s", picture.file_name, refusal)
			return false
		}
		width, height := mark_picture_size(picture)
		expected := mark_picture_pixels(picture, &still)
		same := image.width == width && image.height == height && image.channels == mark_picture_channels(picture) && image.depth == 8 && len(image.pixels) == len(expected)
		if same {
			for index in 0 ..< len(expected) {
				if image.pixels[index] != expected[index] {
					same = false
					break
				}
			}
		}
		if !same {
			fmt.eprintfln("kerneltool: test failed: %s is not the picture of the data of support/mark: run kerneltool logo", picture.file_name)
			return false
		}
		test_passed_print("%s is the picture of the data of support/mark", picture.file_name)
	}
	return mark_font_check()
}
