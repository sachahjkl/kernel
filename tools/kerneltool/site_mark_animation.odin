// The animations of the mark on the site (docs/DESIGN.md, "The mark", "The
// animations"): the large heron of the home and the icon of the tab move;
// the small mark of the bar does not. The frames are the animations of
// support/mark, drawn by the same code as the still pictures of the mark
// (site_pictures.odin, site_icons.odin). Which animation plays, and how the
// heron moves on the page, is in site_mark_schedule.odin
// (docs/SITE.md, "The rhythm of the animations").
//
// What the site gets:
//   pictures/mark_animation_home.png and mark_animation_home_light.png: one
//     sprite sheet for each color scheme. Each sprite is the whole picture of
//     the head of the home (the heron alone) for one distinct frame, in rows
//     of SITE_MARK_SHEET_COLUMNS sprites; the first sprite is the still
//     heron, the same pixels as mark_home.png.
//   pictures/mark_animation_icon.png: the same sprites at the size of the
//     icon of the tab (32 pixels, the drawing of the 32 of favicon.ico).
//     One sheet is one request; the script cuts it on a canvas.
//   mark_animation.js: the script, with the table of the sprites, of the
//     frames, of the moves and of the rule of the choice written into it: no
//     other request.
// The home loads the script; no other page does.
package kerneltool

import "core:fmt"
import "core:image/png"
import "core:os"
import "core:strings"
import "support:graphics"
import "support:mark"

SITE_MARK_ANIMATION_SCRIPT :: "mark_animation.js"
SITE_MARK_ANIMATION_HOME :: "mark_animation_home.png"
SITE_MARK_ANIMATION_HOME_LIGHT :: "mark_animation_home_light.png"
SITE_MARK_ANIMATION_ICON :: "mark_animation_icon.png"
SITE_MARK_ANIMATION_ICON_SIZE :: 32

// The sprites of a sheet are in rows of this many: one row of all the
// sprites of the home is wider than a browser decodes in a picture.
SITE_MARK_SHEET_COLUMNS :: 16
// The widest and the highest picture that a browser decodes, in pixels.
SITE_MARK_SHEET_SIDE_MOST :: 8192

// The classes of the page that the script and the style sheet share. The
// stage takes the place of the still picture while the script plays; it
// holds the water, which stays, and the heron above the water, which a
// move takes with it.
SITE_MARK_STAGE_CLASS :: "mark-stage"
SITE_MARK_HERON_CLASS :: "mark-heron"
SITE_MARK_WATER_CLASS :: "mark-water"
SITE_MARK_REPLACED_CLASS :: "mark-replaced"
SITE_MARK_TRAVEL_CLASS :: "mark-travel"

// The distinct frames of all the animations. Two frames with the same cells
// (a frame of an animation that is the still heron again, a pose that an
// animation takes two times) are one sprite.
Site_Mark_Sprites :: struct {
	cells:    [dynamic]mark.Heron_Cells, // The first is the still heron.
	of_frame: [mark.Animation][]int, // For each animation, the sprite of its frames 1, 2, ...
}

site_mark_sprites :: proc() -> (sprites: Site_Mark_Sprites, ok: bool) {
	sprites.cells = make([dynamic]mark.Heron_Cells, context.temp_allocator)
	append(&sprites.cells, mark.still_cells())
	for animation in mark.Animation {
		count := mark.animation_frame_count(animation)
		places := make([]int, count, context.temp_allocator)
		for frame in 1 ..= count {
			cells, found := mark.animation_frame_cells(animation, frame)
			if !found {
				fmt.eprintfln("kerneltool: the animation %s of the mark has no frame %d", mark.animation_names[animation], frame)
				return {}, false
			}
			place := -1
			for &known, index in sprites.cells {
				if mark.cells_differ_count(&known, &cells) == 0 {
					place = index
					break
				}
			}
			if place < 0 {
				place = len(sprites.cells)
				append(&sprites.cells, cells)
			}
			places[frame - 1] = place
		}
		sprites.of_frame[animation] = places
	}
	return sprites, true
}

// The pictures of the mark that the sheets repeat: the head of the home in
// its two color schemes, and the 32 of favicon.ico.
site_mark_animation_pictures :: proc() -> (home_dark, home_light, icon: Site_Mark_Picture, ok: bool) {
	found_dark, found_light, found_icon := false, false, false
	for picture in site_mark_pictures {
		switch picture.file_name {
		case SITE_MARK_HOME:
			home_dark, found_dark = picture, true
		case SITE_MARK_HOME_LIGHT:
			home_light, found_light = picture, true
		}
	}
	for candidate in site_icons {
		if candidate.in_favicon && candidate.size == SITE_MARK_ANIMATION_ICON_SIZE {
			icon, found_icon = site_icon_picture(candidate), true
		}
	}
	if !found_dark || !found_light || !found_icon {
		fmt.eprintln("kerneltool: site: the pictures of the home or the icon of 32 pixels are not in the tables of the mark")
		return {}, {}, {}, false
	}
	return home_dark, home_light, icon, true
}

// site_mark_sheet_shape gives the count of the columns and of the rows of
// a sheet of a count of sprites.
site_mark_sheet_shape :: proc(sprite_count: int) -> (columns, rows: int) {
	columns = min(sprite_count, SITE_MARK_SHEET_COLUMNS)
	rows = (sprite_count + SITE_MARK_SHEET_COLUMNS - 1) / SITE_MARK_SHEET_COLUMNS
	return
}

// site_mark_sheet_pixels gives the sprite sheet of a picture of the mark:
// each sprite drawn as that picture, from the left, in rows from the top.
// The places after the last sprite are empty. With forms, the drawn forms
// of the moves are under the sprites, each in the box of a form
// (site_mark_moves.odin); forms is nil for a sheet with no form.
site_mark_sheet_pixels :: proc(picture: Site_Mark_Picture, sprites: ^Site_Mark_Sprites, forms: ^Site_Mark_Forms) -> (pixels: []u8, width, height, channels: int) {
	layout := site_mark_sheet_layout(picture, len(sprites.cells), len(forms.drawn) if forms != nil else 0)
	sprite_width, sprite_height := layout.sprite_width, layout.sprite_height
	channels = site_mark_channels(picture)
	width = layout.width
	height = layout.height
	pixels = make([]u8, width * height * channels, context.temp_allocator)
	for &cells, index in sprites.cells {
		sprite := site_mark_pixels(picture, &cells)
		row_bytes := sprite_width * channels
		left := (index % SITE_MARK_SHEET_COLUMNS) * sprite_width
		top := (index / SITE_MARK_SHEET_COLUMNS) * sprite_height
		for row in 0 ..< sprite_height {
			copy(pixels[((top + row) * width + left) * channels:][:row_bytes], sprite[row * row_bytes:][:row_bytes])
		}
	}
	// A drawing of a form has four bytes for each pixel: a sheet with forms
	// is a sheet of a transparent picture.
	if forms != nil && channels == 4 {
		for &drawn, index in forms.drawn {
			form := site_mark_form_pixels(picture, &drawn)
			row_bytes := layout.form_width * channels
			left := (index % layout.form_columns) * layout.form_width
			top := layout.form_top + (index / layout.form_columns) * layout.form_height
			for row in 0 ..< layout.form_height {
				copy(pixels[((top + row) * width + left) * channels:][:row_bytes], form[row * row_bytes:][:row_bytes])
			}
		}
	}
	return
}

// The sheets, each with the picture of the mark that its sprites repeat.
// The sheets of the home hold the drawn forms of the moves; the icon of
// the tab does not move, so its sheet holds the frames only.
Site_Mark_Sheet :: struct {
	file_name:  string,
	picture:    Site_Mark_Picture,
	with_forms: bool,
}

site_mark_sheets :: proc() -> (sheets: [3]Site_Mark_Sheet, ok: bool) {
	home_dark, home_light, icon := site_mark_animation_pictures() or_return
	sheets = [3]Site_Mark_Sheet{{SITE_MARK_ANIMATION_HOME, home_dark, true}, {SITE_MARK_ANIMATION_HOME_LIGHT, home_light, true}, {SITE_MARK_ANIMATION_ICON, icon, false}}
	return sheets, true
}

site_mark_sheet_path :: proc(file_name: string) -> string {
	return strings.concatenate({SITE_PICTURE_FOLDER, "/", file_name}, context.temp_allocator)
}

// site_mark_animation_files gives the files of the animations, by their
// path in the site: the three sheets and the script. The script names each
// sheet with the version of its bytes: a sheet changes when a frame of an
// animation changes, and a script must never cut the sheet of another
// build that a cache kept.
site_mark_animation_files :: proc() -> (files: map[string][]u8, ok: bool) {
	sprites := site_mark_sprites() or_return
	sheets := site_mark_sheets() or_return
	forms := site_mark_forms(&sprites) or_return
	files = make(map[string][]u8, context.temp_allocator)
	addresses: [3]string
	for sheet, index in sheets {
		sheet_forms: ^Site_Mark_Forms
		if sheet.with_forms {
			sheet_forms = &forms
		}
		pixels, width, height, channels := site_mark_sheet_pixels(sheet.picture, &sprites, sheet_forms)
		data := site_pixels_encode(sheet.file_name, width, height, channels, pixels) or_return
		path := site_mark_sheet_path(sheet.file_name)
		files[path] = data
		addresses[index] = strings.concatenate({path, "?v=", site_bytes_version(data)}, context.temp_allocator)
	}
	files[SITE_MARK_ANIMATION_SCRIPT] = transmute([]u8)site_mark_animation_script(&sprites, &forms, sheets[0].picture, addresses)
	return files, true
}

// site_mark_animation_write writes the files of the animations into the
// site, after the check that each sheet reads back as the frames of
// support/mark and that the moves agree with the frames.
site_mark_animation_write :: proc(site: ^Site) -> bool {
	files := site_mark_animation_files() or_return
	problems := site_mark_animation_problems(files)
	if len(problems) > 0 {
		for problem in problems {
			fmt.eprintfln("kerneltool: site: %s", problem)
		}
		return false
	}
	for path, data in files {
		site_write_file(site, path, data) or_return
	}
	sprites, _ := site_mark_sprites()
	still_least, still_most := site_mark_still_bounds()
	fmt.printfln(
		"kerneltool: site: the animations of the mark: %d animations, %d ms in all, %d sprites; a still time of %d to %d ms; %s %d bytes, %s %d bytes, %s %d bytes, %s %d bytes",
		len(mark.Animation),
		site_mark_animations_duration(),
		len(sprites.cells),
		still_least,
		still_most,
		SITE_MARK_ANIMATION_HOME,
		len(files[site_mark_sheet_path(SITE_MARK_ANIMATION_HOME)]),
		SITE_MARK_ANIMATION_HOME_LIGHT,
		len(files[site_mark_sheet_path(SITE_MARK_ANIMATION_HOME_LIGHT)]),
		SITE_MARK_ANIMATION_ICON,
		len(files[site_mark_sheet_path(SITE_MARK_ANIMATION_ICON)]),
		SITE_MARK_ANIMATION_SCRIPT,
		len(files[SITE_MARK_ANIMATION_SCRIPT]),
	)
	return true
}

// site_mark_animation_problems checks the files of the animations: each
// sheet decodes, has the size of its sprites, no side longer than a
// browser decodes, and each sprite has the pixels of its frame in
// support/mark; the script has its table; the moves agree with the frames.
site_mark_animation_problems :: proc(files: map[string][]u8) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	sprites, sprites_ok := site_mark_sprites()
	sheets, sheets_ok := site_mark_sheets()
	if !sprites_ok || !sheets_ok {
		append(&problems, "the frames or the pictures of the animations of the mark are not readable")
		return problems[:]
	}
	forms, forms_ok := site_mark_forms(&sprites)
	if !forms_ok {
		append(&problems, "a form of a move of the mark is not readable")
		return problems[:]
	}
	for sheet in sheets {
		path := site_mark_sheet_path(sheet.file_name)
		data, found := files[path]
		if !found {
			append(&problems, fmt.tprintf("%s is not written", path))
			continue
		}
		image, load_error := png.load_from_bytes(data, allocator = context.temp_allocator)
		if load_error != nil || image == nil {
			append(&problems, fmt.tprintf("%s does not decode", path))
			continue
		}
		sheet_forms: ^Site_Mark_Forms
		if sheet.with_forms {
			sheet_forms = &forms
		}
		expected, width, height, channels := site_mark_sheet_pixels(sheet.picture, &sprites, sheet_forms)
		same := image.width == width && image.height == height && image.channels == channels && image.depth == 8 && len(image.pixels) == len(expected)
		for index := 0; same && index < len(expected); index += 1 {
			same = image.pixels[index] == expected[index]
		}
		if !same {
			append(&problems, fmt.tprintf("%s is not the frames of the animations of support/mark", path))
		}
		if width > SITE_MARK_SHEET_SIDE_MOST || height > SITE_MARK_SHEET_SIDE_MOST {
			append(&problems, fmt.tprintf("%s is %d by %d pixels: a browser decodes at most %d", path, width, height, SITE_MARK_SHEET_SIDE_MOST))
		}
	}
	script, has_script := files[SITE_MARK_ANIMATION_SCRIPT]
	if !has_script || strings.contains(string(script), "/*TABLE*/") {
		append(&problems, SITE_MARK_ANIMATION_SCRIPT + " has no table of the frames")
	}
	if fault := site_mark_move_fault_text(mark.move_keys[:]); fault != "" {
		append(&problems, fault)
	}
	return problems[:]
}

// site_mark_animation_table_json gives the table that the script reads:
//   sprites, columns: the count of sprites in each sheet, and how many are
//     in one row;
//   cells: the count of the cells of a side of the heron;
//   home: the two sheets of the head of the home, the size of a sprite, and
//     the height of the rows of the water at its bottom;
//   icon: the sheet of the icon and the size of a sprite;
//   forms: where the drawn forms of the moves are in a sheet of the home
//     (site_mark_forms_table_write);
//   animations: for each animation its name, its time, its frames, each
//     frame [sprite, milliseconds], the steps of its play and, when it
//     moves, the keys of its move (site_mark_animation_play_write);
//   schedule: the bounds of a still time and the still share, in percent;
//   check: the seed and the first steps of the model of the choice, each
//     [still milliseconds, animation], which the self test compares;
//   limits: the bounds of support/mark for a frame.
// The paths are relative to the folder of the script: the root of the site.
site_mark_animation_table_json :: proc(sprites: ^Site_Mark_Sprites, forms: ^Site_Mark_Forms, home: Site_Mark_Picture, sheet_addresses: [3]string) -> string {
	// The braces are written as text, never through a format of fmt.
	b := strings.builder_make(context.temp_allocator)
	write :: proc(b: ^strings.Builder, text: string) {
		strings.write_string(b, text)
	}
	number :: proc(b: ^strings.Builder, value: int) {
		strings.write_string(b, fmt.tprintf("%d", value))
	}
	width, height := site_mark_size(home)
	write(&b, "{\"sprites\":")
	number(&b, len(sprites.cells))
	write(&b, ",\"columns\":")
	number(&b, SITE_MARK_SHEET_COLUMNS)
	write(&b, ",\"cells\":")
	number(&b, mark.HERON_GRID_SIZE)
	write(&b, ",\"forms\":")
	site_mark_forms_table_write(&b, home, forms, len(sprites.cells))
	write(&b, ",\"home\":{\"dark\":")
	site_json_string(&b, sheet_addresses[0])
	write(&b, ",\"light\":")
	site_json_string(&b, sheet_addresses[1])
	write(&b, ",\"width\":")
	number(&b, width)
	write(&b, ",\"height\":")
	number(&b, height)
	write(&b, ",\"water\":")
	number(&b, mark.WATER_ROWS * home.heron_cell)
	write(&b, "},\"icon\":{\"sheet\":")
	site_json_string(&b, sheet_addresses[2])
	write(&b, ",\"size\":")
	number(&b, SITE_MARK_ANIMATION_ICON_SIZE)
	write(&b, "},\"animations\":[")
	first_animation := true
	frame_least := mark.FRAME_DURATION_LEAST
	for animation in mark.Animation {
		frame_least = min(frame_least, mark.animation_frame_duration_least[animation])
		write(&b, first_animation ? "{\"name\":" : ",{\"name\":")
		first_animation = false
		site_json_string(&b, mark.animation_names[animation])
		write(&b, ",\"duration\":")
		number(&b, mark.animation_duration(animation))
		write(&b, ",\"frames\":[")
		for sprite, frame_index in sprites.of_frame[animation] {
			row, _ := mark.animation_frame(animation, frame_index + 1)
			write(&b, frame_index > 0 ? ",[" : "[")
			number(&b, sprite)
			write(&b, ",")
			number(&b, int(row.duration_milliseconds))
			write(&b, "]")
		}
		write(&b, "]")
		site_mark_animation_play_write(&b, animation, forms)
		write(&b, "}")
	}
	still_least, still_most := site_mark_still_bounds()
	write(&b, "],\"schedule\":{\"stillLeast\":")
	number(&b, still_least)
	write(&b, ",\"stillMost\":")
	number(&b, still_most)
	write(&b, ",\"sharePercent\":")
	number(&b, SITE_MARK_STILL_SHARE_PERCENT)
	write(&b, "},\"check\":{\"seed\":")
	number(&b, SITE_MARK_CHECK_SEED)
	write(&b, ",\"steps\":[")
	for step, index in site_mark_check_steps() {
		write(&b, index > 0 ? ",[" : "[")
		number(&b, step.still_milliseconds)
		write(&b, ",")
		number(&b, step.animation)
		write(&b, "]")
	}
	write(&b, "]},\"limits\":{\"frameLeast\":")
	number(&b, frame_least)
	write(&b, ",\"frameMost\":")
	number(&b, mark.FRAME_DURATION_MOST)
	write(&b, "}}")
	return strings.to_string(b)
}

// site_mark_animation_script gives mark_animation.js: the source below with
// the table in its place.
site_mark_animation_script :: proc(sprites: ^Site_Mark_Sprites, forms: ^Site_Mark_Forms, home: Site_Mark_Picture, sheet_addresses: [3]string) -> string {
	script, _ := strings.replace_all(SITE_MARK_ANIMATION_SCRIPT_SOURCE, "/*TABLE*/null", site_mark_animation_table_json(sprites, forms, home, sheet_addresses), context.temp_allocator)
	return script
}

// site_mark_animation_rules gives the rules of the style sheet for the
// heron of the home while its script plays. The stage has the box of the
// still picture, so nothing beside it moves when it takes its place. No
// rule changes the size of a picture of the heron: a cell of the heron is
// a square of one size, and a squashed heron is another drawing. The
// two canvases take no pointer: a heron that crosses the page never takes
// a click from a link under it. While the heron crosses the window, the
// page is cut at the sides of the window, so no scroll bar appears for a
// heron that is outside. For a reader who asks for reduced motion the
// stage is never shown, also when a script puts it in the page.
site_mark_animation_rules :: proc() -> string {
	home, _, _, _ := site_mark_animation_pictures()
	width, height := site_mark_size(home)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "/* The heron of the home while its script plays. */\n")
	// The braces are written as text, never through a format of fmt.
	strings.write_string(&b, "." + SITE_MARK_STAGE_CLASS + " { display: block; position: relative; ")
	fmt.sbprintf(&b, "width: %dpx; height: %dpx; ", width, height)
	strings.write_string(&b, "}\n")
	strings.write_string(&b, "." + SITE_MARK_STAGE_CLASS + " canvas { display: block; position: absolute; left: 0; image-rendering: pixelated; pointer-events: none; }\n")
	// The canvas of the heron is the box of a form: it passes the stage at
	// its left, at its right and above it by the room of the widest and
	// of the highest form, and its bottom is on the line of the water. It
	// has the pixels of its pictures: no rule changes its size.
	strings.write_string(&b, "." + SITE_MARK_STAGE_CLASS + " ." + SITE_MARK_HERON_CLASS + " { ")
	fmt.sbprintf(&b, "left: -%dpx; bottom: %dpx; ", mark.FORM_REACH_LEFT * home.heron_cell, mark.WATER_ROWS * home.heron_cell)
	strings.write_string(&b, "}\n")
	strings.write_string(&b, "." + SITE_MARK_STAGE_CLASS + " ." + SITE_MARK_WATER_CLASS + " { bottom: 0; }\n")
	strings.write_string(&b, ".home-head picture." + SITE_MARK_REPLACED_CLASS + " { display: none; }\n")
	strings.write_string(&b, "html." + SITE_MARK_TRAVEL_CLASS + " { overflow-x: clip; }\n")
	strings.write_string(&b, "@media (prefers-reduced-motion: reduce) {\n  ." + SITE_MARK_STAGE_CLASS + " { display: none; }\n  .home-head picture." + SITE_MARK_REPLACED_CLASS + " { display: block; }\n}\n")
	return strings.to_string(b)
}

// The picture of every frame for a developer, written by `kerneltool logo`
// into the build folder: one row for each animation, its frames from the
// still heron at cells of 8 pixels, each with its duration. It is not a
// file of the site or of the repository.
MARK_ANIMATIONS_PICTURE :: BUILD_FOLDER + "/mark_animations.png"
MARK_ANIMATIONS_CELL_SIZE :: 8
MARK_ANIMATIONS_MARGIN :: 32
MARK_ANIMATIONS_GAP :: 16
MARK_ANIMATIONS_LINE :: 24 // A line of text of the font of 8 by 16.

mark_animations_picture_write :: proc() -> bool {
	heron := mark.heron_size(MARK_ANIMATIONS_CELL_SIZE)
	most_frames := 0
	for animation in mark.Animation {
		most_frames = max(most_frames, mark.animation_frame_count(animation))
	}
	// The still heron, then each frame.
	column_width := heron + MARK_ANIMATIONS_GAP
	row_height := MARK_ANIMATIONS_LINE + heron + MARK_ANIMATIONS_LINE + MARK_ANIMATIONS_GAP
	width := 2 * MARK_ANIMATIONS_MARGIN + (most_frames + 1) * column_width
	height := 2 * MARK_ANIMATIONS_MARGIN + MARK_ANIMATIONS_LINE + len(mark.Animation) * row_height + MARK_ANIMATIONS_LINE
	// Under the frames of an animation that moves, the forms of its move.
	sprites := site_mark_sprites() or_return
	forms := site_mark_forms(&sprites) or_return
	width = max(width, 2 * MARK_ANIMATIONS_MARGIN + mark_animation_forms_width(&forms))
	for animation in mark.Animation {
		height += mark_animation_forms_height(animation)
	}
	colors := make([]graphics.Color, width * height, context.temp_allocator)
	canvas := graphics.Canvas{pixels = raw_data(colors), width = width, height = height, stride = width}
	graphics.clear(canvas, graphics.COLOR_BACKGROUND)
	saved := graphics.text_state
	defer graphics.text_state = saved
	graphics.text_choice_set(.Spleen, .Red_Green_Blue)

	y := MARK_ANIMATIONS_MARGIN
	graphics.text(canvas, MARK_ANIMATIONS_MARGIN, y, "The animations of the mark (support/mark): frame 0 is the still heron; cells of 8 pixels", graphics.COLOR_TEXT)
	y += MARK_ANIMATIONS_LINE
	for animation in mark.Animation {
		moves := "" if !mark.animation_moves(animation) else "; the home of the site moves the heron"
		heading := fmt.tprintf("%s: %d frames, %d ms%s", mark.animation_names[animation], mark.animation_frame_count(animation), mark.animation_duration(animation), moves)
		graphics.text(canvas, MARK_ANIMATIONS_MARGIN, y, heading, graphics.COLOR_KERNEL)
		count := mark.animation_frame_count(animation)
		for frame in 0 ..= count {
			x := MARK_ANIMATIONS_MARGIN + frame * column_width
			cells, _ := mark.animation_frame_cells(animation, frame)
			graphics.fill(canvas, x, y + MARK_ANIMATIONS_LINE, heron, heron, graphics.COLOR_CARD_TOP)
			mark.cells_draw(canvas, &cells, x, y + MARK_ANIMATIONS_LINE, MARK_ANIMATIONS_CELL_SIZE, false)
			caption := "still"
			if frame > 0 {
				row, _ := mark.animation_frame(animation, frame)
				still := mark.still_cells()
				caption = fmt.tprintf("%d: %d ms, %d cells", frame, row.duration_milliseconds, mark.cells_differ_count(&cells, &still))
			}
			graphics.text(canvas, x, y + MARK_ANIMATIONS_LINE + heron + 4, caption, graphics.COLOR_DIM)
		}
		y += row_height
		if mark.animation_moves(animation) {
			mark_animation_forms_draw(canvas, MARK_ANIMATIONS_MARGIN, y, animation, &sprites, &forms)
			y += mark_animation_forms_height(animation)
		}
	}
	still_least, still_most := site_mark_still_bounds()
	graphics.text(canvas, MARK_ANIMATIONS_MARGIN, y, fmt.tprintf("On the home of the site: each animation once in a round, in an order of chance; still for %d to %d ms between two", still_least, still_most), graphics.COLOR_TEXT)

	rgb := make([]u8, 3 * len(colors), context.temp_allocator)
	for color, index in colors {
		rgb[3 * index] = u8(color >> 16)
		rgb[3 * index + 1] = u8(color >> 8)
		rgb[3 * index + 2] = u8(color)
	}
	data := site_pixels_encode(MARK_ANIMATIONS_PICTURE, width, height, 3, rgb) or_return
	if !make_folder(BUILD_FOLDER) {
		return false
	}
	if err := os.write_entire_file(MARK_ANIMATIONS_PICTURE, data); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", MARK_ANIMATIONS_PICTURE, err)
		return false
	}
	fmt.printfln("kerneltool: wrote %s (%d by %d pixels, %d bytes): every frame of the animations of the mark", MARK_ANIMATIONS_PICTURE, width, height, len(data))
	return true
}

// The script. It changes nothing for a reader who asks for reduced motion,
// nothing in a hidden tab, and nothing while the reader types in a field.
// The still picture stays in the page: a browser with no script shows it,
// and the script puts the stage, of the same size, in its place only while
// it plays. The script sets no style: it sets classes, and it moves the
// heron through the animations of the browser, which a style rule of the
// host does not refuse. It changes the size of no picture: a squashed or a
// stretched heron is a drawing of the sheet, and a move puts the heron at
// a whole count of cells from its place.
SITE_MARK_ANIMATION_SCRIPT_SOURCE :: `// The animations of the mark on the home, written by kerneltool site
// (tools/kerneltool/site_mark_animation.odin and site_mark_schedule.odin)
// from support/mark/animation.odin.
// The large heron of the head and the icon of the tab move. Each animation
// plays once before one plays again, in an order of chance; between two
// animations the heron is still.
// Nothing moves when the reader asks for reduced motion, nothing runs in a
// hidden tab, and nothing plays while the reader types in a field.
// ?selftest=1 in the address checks the table and the rule of the choice.
// #heron=<name> in the address plays one animation again and again, for a
// developer who looks at it: #heron=dash.
"use strict";
(function () {
  const TABLE = /*TABLE*/null;
  const script = document.currentScript;
  if (!script || !TABLE) return;
  const root = new URL(".", script.src);
  const COUNT = TABLE.animations.length;
  const EVERY = Math.pow(2, COUNT) - 1;
  const STORE = "modus.mark.played";

  // The rule of the choice, as site_mark_next_animation of the tool. The
  // memory holds the animations that were played, one bit each, and the one
  // played last. The next one is chosen among those that the memory does
  // not hold. When the memory holds every animation, it is emptied first,
  // and the one played last is left out: no animation follows itself.
  // below(bound) gives a whole number from 0 to bound - 1.
  function nextAnimation(memory, below) {
    if ((memory.played & EVERY) === EVERY) memory.played = 0;
    const open = [];
    for (let index = 0; index < COUNT; index++) {
      if ((memory.played & (1 << index)) === 0 && index !== memory.last) open.push(index);
    }
    const pick = open.length > 0 ? open[below(open.length)] : 0;
    memory.played |= 1 << pick;
    memory.last = pick;
    return pick;
  }
  // The still time before an animation: each whole number of milliseconds
  // of the range has the same chance.
  function stillTime(below) {
    return TABLE.schedule.stillLeast + below(TABLE.schedule.stillMost - TABLE.schedule.stillLeast + 1);
  }
  // The generator of the model of the tool: the same seed gives the same
  // numbers there and here. Only the self test uses it.
  function seeded(seed) {
    let state = seed >>> 0;
    return function (bound) {
      state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
      return (state >>> 16) % bound;
    };
  }
  function chance(bound) { return Math.floor(Math.random() * bound); }

  function selfTest() {
    const cases = [];
    function check(name, passed) { cases.push({ name: name, passed: passed }); }
    const limits = TABLE.limits, schedule = TABLE.schedule;
    check("a sheet has sprites in rows", TABLE.sprites >= 1 && TABLE.columns >= 1);
    check("a sprite of the home has a size and its water", TABLE.home.width > 0 && TABLE.home.height > TABLE.home.water && TABLE.home.water > 0);
    check("a sprite of the icon has a size", TABLE.icon.size > 0);
    const forms = TABLE.forms, whole = Number.isInteger;
    check("the box of a drawn form holds the heron above the water", forms.count >= 1 && forms.columns >= 1 && forms.top > 0 &&
      forms.width >= forms.left + TABLE.home.width && forms.height === forms.up + TABLE.home.height - TABLE.home.water);
    check("a cell is a whole count of pixels", whole(TABLE.home.width / TABLE.cells) && whole(forms.left * TABLE.cells / TABLE.home.width) && whole(forms.up * TABLE.cells / TABLE.home.width));
    check("the memory holds each animation in one bit", COUNT >= 2 && COUNT <= 30);
    TABLE.animations.forEach(animation => {
      const name = animation.name;
      check(name + ": frames", animation.frames.length >= 1);
      check(name + ": each sprite is in the sheet", animation.frames.every(f => Number.isInteger(f[0]) && f[0] >= 0 && f[0] < TABLE.sprites));
      check(name + ": each duration is in its range", animation.frames.every(f => f[1] >= limits.frameLeast && f[1] <= limits.frameMost));
      check(name + ": the first frame moves", animation.frames[0][0] !== 0);
      check(name + ": its time is the time of its frames", animation.frames.reduce((sum, f) => sum + f[1], 0) === animation.duration);
      check(name + ": the time of its steps is its time", animation.steps.reduce((sum, s) => sum + s[0], 0) === animation.duration);
      check(name + ": each step shows a sprite, and a drawn form or none", animation.steps.every(s => s.length === 3 && whole(s[0]) && s[0] > 0 &&
        whole(s[1]) && s[1] >= 0 && s[1] < TABLE.sprites && whole(s[2]) && s[2] >= -1 && s[2] < forms.count));
      check(name + ": the steps show its frames in their order", animation.steps.map(s => s[1]).filter((s, index, all) => index === 0 || s !== all[index - 1]).join() ===
        animation.frames.map(f => f[0]).filter((s, index, all) => index === 0 || s !== all[index - 1]).join());
      check(name + ": only a move draws a form", !!animation.motion || animation.steps.every(s => s[2] === -1));
      if (animation.motion) {
        const keys = animation.motion;
        check(name + ": its move goes from its start to its end", keys.length >= 2 && keys[0][0] === 0 && keys[keys.length - 1][0] === animation.duration);
        check(name + ": the keys of its move are in the order of time", keys.every((key, index) => index === 0 || key[0] > keys[index - 1][0]));
        check(name + ": each key is whole cells, an edge and a pace", keys.every(key => key.length === 5 && key.every(whole) && key[3] >= 0 && key[3] <= 2 && key[4] >= 0 && key[4] <= 1));
        check(name + ": its move starts and ends in its place", [keys[0], keys[keys.length - 1]].every(key => key[1] === 0 && key[2] === 0 && key[3] === 0));
        check(name + ": no way goes to the right and upward at once", keys.every((key, index) => index === 0 || key[2] === keys[index - 1][2] || (key[1] === keys[index - 1][1] && key[3] === keys[index - 1][3])));
      }
    });
    check("the still times have a range", schedule.stillLeast >= limits.frameLeast && schedule.stillMost >= schedule.stillLeast);
    // The rule of this script against the model of the tool: the same
    // generator, the same steps.
    const memory = { played: 0, last: -1 }, below = seeded(TABLE.check.seed);
    let agree = 0;
    TABLE.check.steps.forEach(step => {
      const still = stillTime(below), animation = nextAnimation(memory, below);
      if (still === step[0] && animation === step[1]) agree++;
    });
    check("the choice agrees with the model of the tool on " + TABLE.check.steps.length + " steps", agree === TABLE.check.steps.length && agree > 2 * COUNT);
    // A long play: 200 rounds of the memory.
    const longMemory = { played: 0, last: -1 }, source = seeded(TABLE.check.seed + 1);
    let stillSum = 0, movingSum = 0, follows = 0, twice = 0, round = 0, before = -1;
    for (let step = 0; step < 200 * COUNT; step++) {
      stillSum += stillTime(source);
      const animation = nextAnimation(longMemory, source);
      if (animation === before) follows++;
      if (round & (1 << animation)) twice++;
      round |= 1 << animation;
      if (round === EVERY) round = 0;
      movingSum += TABLE.animations[animation].duration;
      before = animation;
    }
    check("no animation follows itself in a long play", follows === 0);
    check("no animation plays two times in one round of the memory", twice === 0);
    check("the heron is still for about its share of a long play", Math.abs(100 * stillSum / (stillSum + movingSum) - schedule.sharePercent) <= 1);
    const passed = cases.filter(c => c.passed).length;
    const first = cases.find(c => !c.passed);
    return first ? "mark animation self test: FAIL, " + passed + " of " + cases.length + " cases pass; the first that fails: " + first.name :
      "mark animation self test: " + passed + " of " + cases.length + " cases pass";
  }
  if (new URLSearchParams(location.search).get("selftest") === "1") {
    const line = selfTest();
    console.log(line);
    document.documentElement.setAttribute("data-mark-animation-self-test", line);
  }

  const picture = document.querySelector(".home-head picture");
  const still = picture && picture.querySelector("img.mark");
  if (!picture || !still) return;
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
  const light = window.matchMedia("(prefers-color-scheme: light)");

  // The memory of the visit: the storage of the tab keeps it from one page
  // to the next, and the browser drops it when the tab closes. A memory of
  // another count of animations is a memory of another build: it is not
  // used.
  function recall() {
    try {
      const kept = JSON.parse(window.sessionStorage.getItem(STORE));
      if (kept && kept.count === COUNT && Number.isInteger(kept.played) && kept.played >= 0 && kept.played <= EVERY &&
          Number.isInteger(kept.last) && kept.last >= -1 && kept.last < COUNT) {
        return { played: kept.played, last: kept.last };
      }
    } catch (error) { /* No storage, or a text that is not a memory. */ }
    return { played: 0, last: -1 };
  }
  function keep() {
    try {
      window.sessionStorage.setItem(STORE, JSON.stringify({ count: COUNT, played: memory.played, last: memory.last }));
    } catch (error) { /* No storage: the memory lasts as long as the page. */ }
  }
  const memory = recall();

  // The animation that the address asks for, or -1.
  function asked() {
    const match = /^#heron=([a-z]+)$/.exec(window.location.hash);
    return match ? TABLE.animations.findIndex(animation => animation.name === match[1]) : -1;
  }

  let sheets = null, loading = null;
  let stage = null, heron = null, heronContext = null, water = null, waterContext = null;
  let playing = false, shown = -1, shownForm = -1, timer = 0, current = -1, step = -1, due = 0, motion = null;
  let typing = isField(document.activeElement);
  let iconLink = null, iconSprite = -1;
  const iconAddresses = [];

  function isField(element) {
    return !!element && (element.tagName === "INPUT" || element.tagName === "TEXTAREA" || element.tagName === "SELECT" || element.isContentEditable === true);
  }

  function load() {
    if (!loading) {
      const paths = [TABLE.home.dark, TABLE.home.light, TABLE.icon.sheet];
      const images = paths.map(path => { const image = new Image(); image.src = new URL(path, root).href; return image; });
      loading = Promise.all(images.map(image => image.decode())).then(() => {
        sheets = { dark: images[0], light: images[1], icon: images[2] };
      }).catch(() => { sheets = null; });
    }
    return loading;
  }

  // The stage: the water at the bottom, which stays, and the heron above
  // it, which a move takes with it. The stage is the box of the still
  // picture. The canvas of the heron is the box of a drawn form: it passes
  // the stage by the room of the widest and of the highest form, and each
  // of its pixels is a pixel of the sheet.
  function build() {
    const width = TABLE.home.width;
    stage = document.createElement("span");
    stage.className = "mark-stage";
    stage.setAttribute("role", "img");
    stage.setAttribute("aria-label", still.alt);
    water = document.createElement("canvas");
    water.className = "mark-water";
    water.width = width;
    water.height = TABLE.home.water;
    heron = document.createElement("canvas");
    heron.className = "mark-heron";
    heron.width = TABLE.forms.width;
    heron.height = TABLE.forms.height;
    stage.append(water, heron);
    waterContext = water.getContext("2d");
    heronContext = heron.getContext("2d");
  }

  // One picture, from the sheet of the color scheme of now: the water of
  // the sprite of a frame, and above it the heron of that sprite (form -1)
  // or a drawn form of it. Each picture is copied pixel for pixel: a cell
  // of the heron has one size.
  function draw(sprite, form) {
    const sheet = light.matches ? sheets.light : sheets.dark;
    const forms = TABLE.forms;
    const width = TABLE.home.width, height = TABLE.home.height, above = height - TABLE.home.water;
    const left = (sprite % TABLE.columns) * width, top = Math.floor(sprite / TABLE.columns) * height;
    heronContext.clearRect(0, 0, forms.width, forms.height);
    if (form < 0) {
      heronContext.drawImage(sheet, left, top, width, above, forms.left, forms.up, width, above);
    } else {
      heronContext.drawImage(sheet, (form % forms.columns) * forms.width, forms.top + Math.floor(form / forms.columns) * forms.height,
        forms.width, forms.height, 0, 0, forms.width, forms.height);
    }
    waterContext.clearRect(0, 0, width, TABLE.home.water);
    waterContext.drawImage(sheet, left, top + above, width, TABLE.home.water, 0, 0, width, TABLE.home.water);
    shown = sprite;
    shownForm = form;
  }

  // The icon of the tab: one sprite at 32 pixels, as a data address. Each
  // address is made once. The link is in the head only during an animation.
  function iconAddress(sprite) {
    if (!iconAddresses[sprite]) {
      const size = TABLE.icon.size;
      const icon = document.createElement("canvas");
      icon.width = size;
      icon.height = size;
      icon.getContext("2d").drawImage(sheets.icon, (sprite % TABLE.columns) * size, Math.floor(sprite / TABLE.columns) * size, size, size, 0, 0, size, size);
      iconAddresses[sprite] = icon.toDataURL("image/png");
    }
    return iconAddresses[sprite];
  }
  function showIcon(sprite) {
    if (sprite === iconSprite) return;
    if (!iconLink) {
      iconLink = document.createElement("link");
      iconLink.rel = "icon";
      iconLink.type = "image/png";
      iconLink.setAttribute("sizes", TABLE.icon.size + "x" + TABLE.icon.size);
      document.head.append(iconLink);
    }
    iconLink.href = iconAddress(sprite);
    iconSprite = sprite;
  }
  // The end of an animation: the still icon, then the icons of the page
  // again.
  function stillIcon() {
    if (!iconLink) return;
    iconLink.href = iconAddress(0);
    iconLink.remove();
    iconLink = null;
    iconSprite = -1;
  }

  // The move of an animation: the places of its keys as one animation of
  // the browser on the heron above the water. A place is a whole count of
  // cells from the place of the heron. A key past an edge puts the heron,
  // in its widest form, wholly outside the window at that side, a whole
  // count of cells away. From a key to the next one the heron goes cell by
  // cell, in as many even steps as the way has cells (or in one step, at
  // the end, for a key that holds): it is never between two cells. While
  // the heron crosses the window, the page is cut at the sides of the
  // window.
  function startMove(animation) {
    if (!animation.motion || typeof heron.animate !== "function") return;
    const box = stage.getBoundingClientRect();
    const cell = box.width / TABLE.cells;
    const far = [0, Math.ceil((document.documentElement.clientWidth - box.left) / cell) + TABLE.forms.reachLeft,
      -(Math.ceil(box.right / cell) + TABLE.forms.reachRight)];
    const places = animation.motion.map(key => [key[1] + far[key[3]], key[2]]);
    let crosses = false;
    const keys = animation.motion.map((key, index) => {
      if (key[3] !== 0) crosses = true;
      const place = places[index], next = places[Math.min(index + 1, places.length - 1)];
      const cells = Math.abs(next[0] - place[0]) + Math.abs(next[1] - place[1]);
      return {
        offset: key[0] / animation.duration,
        easing: "steps(" + (key[4] === 1 ? 1 : Math.max(1, cells)) + ", end)",
        transform: "translate(" + place[0] * cell + "px, " + -place[1] * cell + "px)"
      };
    });
    if (crosses) document.documentElement.classList.add("mark-travel");
    motion = heron.animate(keys, { duration: animation.duration });
  }
  function endMove() {
    if (motion) motion.cancel();
    motion = null;
    document.documentElement.classList.remove("mark-travel");
  }

  // The play: the still heron for a still time, then one animation, step
  // by step. Each step ends at its time from the start of the animation,
  // so a timer that is late does not make the next ones late: the pictures
  // stay in step with the move.
  function rest() {
    current = -1;
    step = -1;
    endMove();
    if (shown !== 0 || shownForm !== -1) draw(0, -1);
    stillIcon();
    timer = window.setTimeout(play, asked() >= 0 ? TABLE.schedule.stillLeast : stillTime(chance));
  }
  function play() {
    const only = asked();
    if (only >= 0) {
      current = only;
    } else {
      current = nextAnimation(memory, chance);
      keep();
    }
    step = -1;
    due = window.performance.now();
    startMove(TABLE.animations[current]);
    next();
  }
  function next() {
    const steps = TABLE.animations[current].steps;
    step++;
    if (step >= steps.length) { rest(); return; }
    if (steps[step][1] !== shown || steps[step][2] !== shownForm) draw(steps[step][1], steps[step][2]);
    showIcon(steps[step][1]);
    due += steps[step][0];
    timer = window.setTimeout(next, Math.max(0, due - window.performance.now()));
  }

  function canPlay() { return !reduce.matches && !document.hidden && !typing; }

  function start() {
    if (!canPlay() || playing) return;
    load().then(() => {
      if (!sheets || !canPlay() || playing) return;
      if (!stage) build();
      playing = true;
      draw(0, -1);
      // The style sheet hides the still picture by this class, and shows
      // it again for a reader who asks for reduced motion.
      picture.after(stage);
      picture.classList.add("mark-replaced");
      rest();
    });
  }

  // Back to the still picture of the page and to the icons of the page.
  function stop() {
    if (timer) window.clearTimeout(timer);
    timer = 0;
    playing = false;
    endMove();
    if (stage && stage.parentNode) stage.remove();
    picture.classList.remove("mark-replaced");
    shown = -1;
    if (sheets) stillIcon();
  }

  function fit() { if (canPlay()) start(); else stop(); }
  reduce.addEventListener("change", fit);
  document.addEventListener("visibilitychange", fit);
  document.addEventListener("focusin", event => { typing = isField(event.target); fit(); });
  document.addEventListener("focusout", () => { typing = false; fit(); });
  light.addEventListener("change", () => { if (playing && shown >= 0) draw(shown, shownForm); });
  // Another animation asked for in the address: the play starts again.
  window.addEventListener("hashchange", () => { if (playing) { stop(); fit(); } });
  fit();
})();
`
