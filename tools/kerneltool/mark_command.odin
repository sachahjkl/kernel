// The command `mark` (docs/TOOLS.md, "The pictures of the mark"): one
// request to the generator of the pictures of the mark, from the words of a
// command line. It computes no picture: it reads the options into a
// request, asks the generator, and writes the file that the generator
// gives, or prints its refusal.
package kerneltool

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "support:mark"

MARK_COMMAND_USAGE :: "kerneltool mark still | frame | tile_map | table | uses | developer" +
	" [--variant smooth|cells] [--cell <pixels>] [--scheme dark|light] [--background none|scheme]" +
	" [--size <pixels> | <width>x<height>] [--name-cell <pixels>] [--gap <pixels>]" +
	" [--animation <name>] [--frame <number>] [--forms yes|no] [--width <pixels>] [--out <file>]"

// The defaults of a request of the command: the picture of the home of the
// site, the smooth heron at 8 pixels for a cell in the dark scheme, on
// nothing; a tile map with the drawn forms.
MARK_COMMAND_CELL :: 8

// mark_command_request reads the words of the command into a request and
// the path of the file to write. problem is the sentence of a word that the
// command does not know, or "".
mark_command_request :: proc(args: []string) -> (request: Mark_Request, out: string, problem: string) {
	if len(args) == 0 {
		return {}, "", "name what to draw"
	}
	found := false
	for name, what in mark_what_names {
		if name == args[0] {
			request.what, found = what, true
		}
	}
	if !found {
		return {}, "", fmt.tprintf("%s is not a kind of picture of the mark", args[0])
	}
	request.picture = Mark_Picture {
		variant    = .Smooth,
		heron_cell = MARK_COMMAND_CELL,
	}
	request.with_forms = true
	extension := ".json" if request.what == .Table else ".png"
	out = strings.concatenate({BUILD_FOLDER, "/mark_", args[0], extension}, context.temp_allocator)
	// A whole number of an option: a fraction, a sign or a letter is not
	// one, and the command refuses it.
	whole :: proc(text: string) -> (value: int, ok: bool) {
		if text == "" {
			return 0, false
		}
		for character in text {
			if character < '0' || character > '9' {
				return 0, false
			}
		}
		return strconv.parse_int(text, 10)
	}
	index := 1
	for index < len(args) {
		option := args[index]
		if index + 1 >= len(args) {
			return {}, "", fmt.tprintf("the option %s has no value", option)
		}
		value := args[index + 1]
		index += 2
		number, is_whole := whole(value)
		not_whole := fmt.tprintf("%s takes a whole count of pixels, not %s: a cell and a picture have no part of a pixel", option, value)
		switch option {
		case "--variant":
			known := false
			for name, variant in mark.variant_names {
				if name == value {
					request.picture.variant, known = variant, true
				}
			}
			if !known {
				return {}, "", fmt.tprintf("%s is not a variant of the mark: smooth or cells", value)
			}
		case "--cell":
			if !is_whole {
				return {}, "", not_whole
			}
			request.picture.heron_cell = number
		case "--scheme":
			if value != "dark" && value != "light" {
				return {}, "", fmt.tprintf("%s is not a color scheme: dark or light", value)
			}
			request.picture.on_light = value == "light"
		case "--background":
			if value != "none" && value != "scheme" {
				return {}, "", fmt.tprintf("%s is not a background: none, or scheme for the background of the color scheme", value)
			}
			request.picture.opaque = value == "scheme"
		case "--size":
			// One number for a square picture, or a width and a height
			// with an x between them.
			width_text, height_text := value, value
			if cross := strings.index_byte(value, 'x'); cross >= 0 {
				width_text, height_text = value[:cross], value[cross + 1:]
			}
			width, width_is_whole := whole(width_text)
			height, height_is_whole := whole(height_text)
			if !width_is_whole || !height_is_whole {
				return {}, "", fmt.tprintf("--size takes a whole count of pixels, or a width and a height as 1200x630, not %s", value)
			}
			request.picture.width, request.picture.height = width, height
		case "--name-cell":
			if !is_whole {
				return {}, "", not_whole
			}
			request.picture.name_cell = number
		case "--gap":
			if !is_whole {
				return {}, "", not_whole
			}
			request.picture.gap = number
		case "--animation":
			request.has_animation = false
			for name, animation in mark.animation_names {
				if name == value {
					request.animation, request.has_animation = animation, true
				}
			}
			if !request.has_animation {
				return {}, "", fmt.tprintf("%s is not an animation of the mark", value)
			}
		case "--frame":
			if !is_whole {
				return {}, "", fmt.tprintf("--frame takes the number of a frame, not %s", value)
			}
			request.frame = number
		case "--forms":
			if value != "yes" && value != "no" {
				return {}, "", fmt.tprintf("--forms takes yes or no, not %s", value)
			}
			request.with_forms = value == "yes"
		case "--width":
			if !is_whole {
				return {}, "", not_whole
			}
			request.width_most = number
		case "--out":
			out = value
		case:
			return {}, "", fmt.tprintf("%s is not an option of the command", option)
		}
	}
	request.picture.file_name = out
	return request, out, ""
}

// mark_uses_print prints the table of the uses of the mark: each file,
// where it goes, what it holds and how it is drawn.
mark_uses_print :: proc() {
	for use in mark_uses {
		picture := use.picture
		place: string = "the repository" if use.place == .Repository else "the site"
		kind := "the still mark"
		switch use.kind {
		case .Picture:
		case .Tile_Map:
			kind = "the tile map of the animations"
		case .Tile_Map_Of_Frames:
			kind = "the tile map of the frames"
		}
		width, height := mark_picture_size(picture)
		scheme: string = "light" if picture.on_light else "dark"
		background: string = "on the background of the scheme" if picture.opaque else "on nothing"
		fmt.printfln("%s, %s: %s: %s, %d pixels for a cell, the %s scheme, %s; a tile or the picture is %d by %d pixels", picture.file_name, place, kind, mark.variant_names[picture.variant], picture.heron_cell, scheme, background, width, height)
	}
}

run_mark :: proc(args: []string) -> int {
	if len(args) == 1 && args[0] == "uses" {
		mark_uses_print()
		return 0
	}
	if len(args) == 1 && args[0] == "developer" {
		return 0 if mark_animations_picture_write() else EXIT_FAILURE
	}
	request, out, problem := mark_command_request(args)
	if problem != "" {
		fmt.eprintfln("kerneltool: mark: %s", problem)
		fmt.eprintln(MARK_COMMAND_USAGE)
		return EXIT_USAGE
	}
	file, refusal := mark_generate(request)
	if refusal != "" {
		fmt.eprintfln("kerneltool: mark: refused: %s", refusal)
		return EXIT_FAILURE
	}
	if strings.has_prefix(out, BUILD_FOLDER + "/") && !make_folder(BUILD_FOLDER) {
		return EXIT_FAILURE
	}
	if err := os.write_entire_file(out, file); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", out, err)
		return EXIT_FAILURE
	}
	scheme: string = "light" if request.picture.on_light else "dark"
	fmt.printfln("kerneltool: wrote %s (%s, %s, %d pixels for a cell, the %s scheme, %d bytes)", out, mark_what_names[request.what], mark.variant_names[request.picture.variant], request.picture.heron_cell, scheme, len(file))
	return 0
}
