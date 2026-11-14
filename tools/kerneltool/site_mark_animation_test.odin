package kerneltool

import "core:encoding/json"
import "core:image/png"
import "core:strings"
import "core:testing"
import "support:mark"

// The files of the animations read back as the frames of support/mark, and
// the first sprite of each sheet is the still picture that the site shows
// with no script: the heron of a page in the color scheme of the sheet.
@(test)
site_mark_animation_sheets_read_back :: proc(t: ^testing.T) {
	files, ok := site_mark_animation_files()
	testing.expect(t, ok)
	if !ok {
		return
	}
	problems := site_mark_animation_problems(files)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	sheets, sheets_ok := site_mark_sheets()
	testing.expect(t, sheets_ok)
	sprites, sprites_ok := site_mark_sprites()
	testing.expect(t, sprites_ok)
	forms, forms_ok := site_mark_forms(&sprites)
	testing.expect(t, forms_ok)
	columns, rows := site_mark_sheet_shape(len(sprites.cells))
	for sheet in sheets {
		still_file, encoded := site_mark_encode(sheet.picture)
		testing.expect(t, encoded)
		still_image, still_error := png.load_from_bytes(still_file, allocator = context.temp_allocator)
		sheet_image, sheet_error := png.load_from_bytes(files[site_mark_sheet_path(sheet.file_name)], allocator = context.temp_allocator)
		if still_error != nil || sheet_error != nil {
			testing.expectf(t, false, "%s or its still picture does not decode", sheet.file_name)
			continue
		}
		// The sprites of the frames at the top; under them, in a sheet of
		// the home, the drawn forms of the moves.
		layout := site_mark_sheet_layout(sheet.picture, len(sprites.cells), len(forms.drawn) if sheet.with_forms else 0)
		testing.expect_value(t, layout.form_top, still_image.height * rows)
		testing.expect_value(t, sheet_image.height, layout.height)
		testing.expect_value(t, sheet_image.width, still_image.width * columns)
		testing.expect_value(t, sheet_image.width, layout.width)
		testing.expect(t, (sheet_image.height > layout.form_top) == sheet.with_forms)
		testing.expect(t, layout.width <= SITE_MARK_SHEET_SIDE_MOST && layout.height <= SITE_MARK_SHEET_SIDE_MOST)
		testing.expect_value(t, sheet_image.channels, still_image.channels)
		// Each drawn form reads back from its box in the sheet.
		if sheet.with_forms && sheet_image.channels == 4 {
			for &drawn, index in forms.drawn {
				expected := site_mark_form_pixels(sheet.picture, &drawn)
				form_row_bytes := layout.form_width * 4
				left := (index % layout.form_columns) * layout.form_width
				top := layout.form_top + (index / layout.form_columns) * layout.form_height
				same_form := true
				for row in 0 ..< layout.form_height {
					if string(sheet_image.pixels[((top + row) * sheet_image.width + left) * 4:][:form_row_bytes]) != string(expected[row * form_row_bytes:][:form_row_bytes]) {
						same_form = false
						break
					}
				}
				testing.expectf(t, same_form, "the drawn form %d of %s is not its cells", index, sheet.file_name)
			}
		}
		row_bytes := still_image.width * still_image.channels
		sheet_row_bytes := sheet_image.width * sheet_image.channels
		same := true
		for row in 0 ..< still_image.height {
			if string(sheet_image.pixels[row * sheet_row_bytes:][:row_bytes]) != string(still_image.pixels[row * row_bytes:][:row_bytes]) {
				same = false
				break
			}
		}
		testing.expectf(t, same, "the first sprite of %s is not its still picture", sheet.file_name)
	}
	// A sheet in the place of another is found.
	damaged := make(map[string][]u8, context.temp_allocator)
	for path, data in files {
		damaged[path] = data
	}
	damaged[SITE_PICTURE_FOLDER + "/" + SITE_MARK_ANIMATION_HOME] = files[SITE_PICTURE_FOLDER + "/" + SITE_MARK_ANIMATION_HOME_LIGHT]
	testing.expect(t, len(site_mark_animation_problems(damaged)) == 1)
}

// The sprites are distinct, the still heron is the first, and a frame that is
// the still heron again is the sprite 0.
@(test)
site_mark_sprites_are_distinct :: proc(t: ^testing.T) {
	sprites, ok := site_mark_sprites()
	testing.expect(t, ok)
	still := mark.still_cells()
	testing.expect_value(t, mark.cells_differ_count(&sprites.cells[0], &still), 0)
	for index in 0 ..< len(sprites.cells) {
		for other in index + 1 ..< len(sprites.cells) {
			testing.expectf(t, mark.cells_differ_count(&sprites.cells[index], &sprites.cells[other]) > 0, "the sprites %d and %d are the same", index, other)
		}
	}
	// The second frame of the look is the still heron.
	testing.expect_value(t, sprites.of_frame[.Look][1], 0)
	// The third frame of the leg repeats its first.
	testing.expect_value(t, sprites.of_frame[.Leg][2], sprites.of_frame[.Leg][0])
	// The scratch starts from the pose of the leg animation: one sprite.
	testing.expect_value(t, sprites.of_frame[.Scratch][0], sprites.of_frame[.Leg][1])
	// A pose that two animations share is one sprite: the wind-up of the
	// dash, the two waves of the landing of the hop, the closed eye of the
	// doze and of the stretch, the still heron in the middle of the wade.
	testing.expect_value(t, sprites.of_frame[.Dash][0], sprites.of_frame[.Leg][1])
	testing.expect_value(t, sprites.of_frame[.Hop][0], sprites.of_frame[.Leg][0])
	testing.expect_value(t, sprites.of_frame[.Hop][2], sprites.of_frame[.Ripple][0])
	testing.expect_value(t, sprites.of_frame[.Hop][3], sprites.of_frame[.Ripple][1])
	testing.expect_value(t, sprites.of_frame[.Doze][0], sprites.of_frame[.Blink][0])
	testing.expect_value(t, sprites.of_frame[.Stretch][0], sprites.of_frame[.Blink][0])
	testing.expect_value(t, sprites.of_frame[.Wade][1], 0)
	// The run of the dash is two sprites.
	testing.expect_value(t, sprites.of_frame[.Dash][13], sprites.of_frame[.Dash][1])
	testing.expect_value(t, sprites.of_frame[.Dash][14], sprites.of_frame[.Dash][2])
	// The still heron, 21 frames of the seven first animations, and 21 of
	// the eight others: 4 of the dash, 1 of the hop, 6 of the fish, 3 of the
	// doze, 1 of the stretch, 2 of the ruffle, 1 of the wade, 3 of the flap.
	testing.expect_value(t, len(sprites.cells), 43)
	// A sprite is the heron alone with one pixel for a cell, 24 pixels
	// wide. The sprites are in rows, and no side of a sheet is longer than
	// a browser decodes.
	home, _, _ := site_mark_animation_pictures()
	testing.expect_value(t, home.heron_cell, 1)
	sprite_width, sprite_height := site_mark_size(home)
	testing.expect_value(t, sprite_width, mark.HERON_GRID_SIZE)
	testing.expect_value(t, sprite_width, mark.heron_size(home.heron_cell))
	testing.expect_value(t, sprite_height, mark.heron_size(home.heron_cell))
	columns, rows := site_mark_sheet_shape(len(sprites.cells))
	testing.expect(t, columns * rows >= len(sprites.cells))
	testing.expect(t, columns <= SITE_MARK_SHEET_COLUMNS)
	testing.expect(t, sprite_width * columns <= SITE_MARK_SHEET_SIDE_MOST)
	testing.expect(t, sprite_height * rows <= SITE_MARK_SHEET_SIDE_MOST)
	single_columns, single_rows := site_mark_sheet_shape(1)
	testing.expect_value(t, single_columns, 1)
	testing.expect_value(t, single_rows, 1)
	full_columns, full_rows := site_mark_sheet_shape(SITE_MARK_SHEET_COLUMNS + 1)
	testing.expect_value(t, full_columns, SITE_MARK_SHEET_COLUMNS)
	testing.expect_value(t, full_rows, 2)
	for animation in mark.Animation {
		testing.expect_value(t, len(sprites.of_frame[animation]), mark.animation_frame_count(animation))
	}
}

// The addresses of the sheets that a test gives to the table.
@(private = "file")
TEST_SHEET_ADDRESSES :: [SITE_MARK_SHEET_COUNT]string{"pictures/dark.png?v=1", "pictures/light.png?v=2"}

// The table in the script is JSON with the counts of support/mark, the
// moves of the tool, the bounds of the still times and the steps of the
// model.
@(test)
site_mark_animation_table_parses :: proc(t: ^testing.T) {
	sprites, ok := site_mark_sprites()
	home, _, pictures_ok := site_mark_animation_pictures()
	testing.expect(t, ok && pictures_ok)
	forms, forms_ok := site_mark_forms(&sprites)
	testing.expect(t, forms_ok)
	table := site_mark_animation_table_json(&sprites, &forms, home, TEST_SHEET_ADDRESSES)
	value, err := json.parse_string(table, .JSON, false, context.temp_allocator)
	root, is_object := value.(json.Object)
	testing.expectf(t, err == .None && is_object, "the table does not parse: %v", err)
	if !is_object {
		return
	}
	count, _ := root["sprites"].(json.Float) // parse_string with no integers: each number is a float.
	testing.expect_value(t, int(count), len(sprites.cells))
	columns, _ := root["columns"].(json.Float)
	testing.expect_value(t, int(columns), SITE_MARK_SHEET_COLUMNS)
	home_table, _ := root["home"].(json.Object)
	dark, _ := home_table["dark"].(json.String)
	testing.expect_value(t, dark, "pictures/dark.png?v=1")
	water, _ := home_table["water"].(json.Float)
	testing.expect_value(t, int(water), mark.WATER_ROWS * home.heron_cell)
	// A sprite is 24 by 24 pixels of the sheet, and its water 2 rows.
	sprite_width, _ := home_table["width"].(json.Float)
	sprite_height, _ := home_table["height"].(json.Float)
	testing.expect_value(t, int(sprite_width), mark.HERON_GRID_SIZE)
	testing.expect_value(t, int(sprite_height), mark.HERON_GRID_SIZE)
	testing.expect_value(t, int(water), 2)
	// The icon of the tab: 32 pixels, the sprite 4 pixels from its edges.
	icon_table, _ := root["icon"].(json.Object)
	icon_size, _ := icon_table["size"].(json.Float)
	icon_margin, _ := icon_table["margin"].(json.Float)
	_, icon_has_sheet := icon_table["sheet"]
	testing.expect_value(t, int(icon_size), 32)
	testing.expect_value(t, int(icon_margin), 4)
	testing.expect(t, !icon_has_sheet)
	// Where the drawn forms are in a sheet of the home, in pixels of the
	// sheet, one for a cell: under the three rows of the sprites, twelve
	// boxes of 32 by 26 in a row, the natural heron 6 from the left of
	// its box and 4 from its top.
	forms_table, _ := root["forms"].(json.Object)
	layout := site_mark_sheet_layout(home, len(sprites.cells), len(forms.drawn))
	form_numbers := [?]struct {
		name:  string,
		value: int,
	} {
		{"count", len(forms.drawn)},
		{"columns", layout.form_columns},
		{"top", layout.form_top},
		{"width", layout.form_width},
		{"height", layout.form_height},
		{"left", mark.FORM_REACH_LEFT * home.heron_cell},
		{"up", mark.FORM_REACH_UP * home.heron_cell},
		{"reachLeft", mark.FORM_REACH_LEFT},
		{"reachRight", mark.FORM_REACH_RIGHT},
	}
	for number in form_numbers {
		written, is_number := forms_table[number.name].(json.Float)
		testing.expectf(t, is_number && int(written) == number.value, "the table says %s: %v, not %d", number.name, written, number.value)
	}
	testing.expect_value(t, len(forms.drawn), 19)
	testing.expect_value(t, layout.form_columns, 12)
	testing.expect_value(t, layout.form_top, 72)
	testing.expect_value(t, layout.form_width, 32)
	testing.expect_value(t, layout.form_height, 26)
	testing.expect_value(t, layout.width, 384)
	testing.expect_value(t, layout.height, 124)
	animations, _ := root["animations"].(json.Array)
	testing.expect_value(t, len(animations), len(mark.Animation))
	moving := 0
	for entry, index in animations {
		animation := mark.Animation(index)
		object, _ := entry.(json.Object)
		name, _ := object["name"].(json.String)
		testing.expect_value(t, name, mark.animation_names[animation])
		duration, _ := object["duration"].(json.Float)
		testing.expect_value(t, int(duration), mark.animation_duration(animation))
		frames, _ := object["frames"].(json.Array)
		testing.expect_value(t, len(frames), mark.animation_frame_count(animation))
		// The steps of the play: each [milliseconds, sprite, form], as the
		// tool computed them from the frames and the keys.
		play_steps, _ := object["steps"].(json.Array)
		expected_steps := forms.steps[animation]
		testing.expect_value(t, len(play_steps), len(expected_steps))
		if len(play_steps) == len(expected_steps) {
			for play_step, step_index in play_steps {
				values, _ := play_step.(json.Array)
				testing.expect_value(t, len(values), 3)
				if len(values) != 3 {
					continue
				}
				milliseconds, _ := values[0].(json.Float)
				sprite, _ := values[1].(json.Float)
				form, _ := values[2].(json.Float)
				testing.expect_value(t, int(milliseconds), expected_steps[step_index].milliseconds)
				testing.expect_value(t, int(sprite), expected_steps[step_index].sprite)
				testing.expect_value(t, int(form), expected_steps[step_index].form)
			}
		}
		motion, has_motion := object["motion"].(json.Array)
		testing.expect_value(t, has_motion, mark.animation_moves(animation))
		if !has_motion {
			continue
		}
		moving += 1
		// The keys of the move: each [milliseconds, cells to the right,
		// cells up, edge, pace], the numbers of support/mark, each whole.
		key_index := 0
		for key in mark.move_keys {
			if key.animation != animation {
				continue
			}
			if key_index < len(motion) {
				values, _ := motion[key_index].(json.Array)
				testing.expect_value(t, len(values), 5)
				if len(values) == 5 {
					expected_values := [5]int{key.at_milliseconds, key.cells_right, key.cells_up, int(key.edge), int(key.pace)}
					for expected_value, value_index in expected_values {
						written, _ := values[value_index].(json.Float)
						testing.expectf(t, written == f64(expected_value), "%v, the key %d: the value %d is %v, not %d", animation, key_index, value_index, written, expected_value)
					}
				}
			}
			key_index += 1
		}
		testing.expect_value(t, len(motion), key_index)
	}
	// The dash, the hop, the stretch and the flap move the heron.
	testing.expect_value(t, moving, 4)
	schedule, _ := root["schedule"].(json.Object)
	still_least, still_most := site_mark_still_bounds()
	written_least, _ := schedule["stillLeast"].(json.Float)
	written_most, _ := schedule["stillMost"].(json.Float)
	written_share, _ := schedule["sharePercent"].(json.Float)
	testing.expect_value(t, int(written_least), still_least)
	testing.expect_value(t, int(written_most), still_most)
	testing.expect_value(t, int(written_share), SITE_MARK_STILL_SHARE_PERCENT)
	// The steps of the model, which the self test of the script compares
	// with its own rule.
	check, _ := root["check"].(json.Object)
	seed, _ := check["seed"].(json.Float)
	testing.expect_value(t, int(seed), SITE_MARK_CHECK_SEED)
	steps, _ := check["steps"].(json.Array)
	expected := site_mark_check_steps()
	testing.expect_value(t, len(steps), len(expected))
	if len(steps) == len(expected) {
		for step, index in steps {
			pair, _ := step.(json.Array)
			testing.expect_value(t, len(pair), 2)
			if len(pair) != 2 {
				continue
			}
			written_still, _ := pair[0].(json.Float)
			written_animation, _ := pair[1].(json.Float)
			testing.expect_value(t, int(written_still), expected[index].still_milliseconds)
			testing.expect_value(t, int(written_animation), expected[index].animation)
		}
	}
	limits, _ := root["limits"].(json.Object)
	frame_least, _ := limits["frameLeast"].(json.Float)
	testing.expect_value(t, int(frame_least), mark.DASH_FRAME_DURATION_LEAST)
	script := site_mark_animation_script(&sprites, &forms, home, TEST_SHEET_ADDRESSES)
	testing.expect(t, !strings.contains(script, "/*TABLE*/"))
	testing.expect(t, strings.contains(script, "mark animation self test: "))
	// The script and the style sheet name the same classes, and the script
	// holds the numbers of the generator of the model.
	sheet := site_style_sheet("")
	for class in ([]string{SITE_MARK_STAGE_CLASS, SITE_MARK_HERON_CLASS, SITE_MARK_WATER_CLASS, SITE_MARK_REPLACED_CLASS, SITE_MARK_TRAVEL_CLASS}) {
		testing.expectf(t, strings.contains(script, strings.concatenate({"\"", class, "\""}, context.temp_allocator)), "the script does not name the class %s", class)
		testing.expectf(t, strings.contains(sheet, class), "the style sheet does not name the class %s", class)
	}
	testing.expect(t, strings.contains(script, "Math.imul(state, 1664525) + 1013904223"))
	testing.expect_value(t, SITE_MARK_GENERATOR_MULTIPLIER, 1664525)
	testing.expect_value(t, SITE_MARK_GENERATOR_INCREMENT, 1013904223)
}

// The rules of the style sheet for the heron of the home. A picture of the
// heron has one pixel for a cell, and the style sheet shows a cell at 8
// pixels of the page: the still picture, the stage, the canvas of the
// heron (the box of a form, 32 by 26 cells) and the canvas of the water
// (24 by 2 cells) each have a size in pixels that is their count of cells
// times 8, and each is shown with no smoothing. What moves takes no
// pointer, the page is cut at the sides of the window while the heron
// crosses it, and a reader who asks for reduced motion sees the still
// picture.
@(test)
site_mark_animation_rules_keep_the_page :: proc(t: ^testing.T) {
	sheet := site_style_sheet("")
	testing.expect_value(t, SITE_MARK_HOME_FACTOR, 8)
	testing.expect_value(t, SITE_MARK_HOME_SIZE, 192)
	testing.expect(t, strings.contains(sheet, ".home-head img.mark { width: 192px; height: 192px; image-rendering: crisp-edges; image-rendering: pixelated; }"))
	testing.expect(t, strings.contains(sheet, ".mark-stage { display: block; position: relative; width: 192px; height: 192px; }"))
	testing.expect(t, strings.contains(sheet, ".mark-stage canvas { display: block; position: absolute; left: 0; image-rendering: crisp-edges; image-rendering: pixelated; pointer-events: none; }"))
	// The canvas of the heron is the box of a form: 6 cells past the stage
	// at its left, its bottom on the line of the water.
	testing.expect(t, strings.contains(sheet, ".mark-stage .mark-heron { left: -48px; bottom: 16px; width: 256px; height: 208px; }"))
	testing.expect(t, strings.contains(sheet, ".mark-stage .mark-water { bottom: 0; width: 192px; height: 16px; }"))
	testing.expect(t, strings.contains(sheet, "html.mark-travel { overflow-x: clip; }"))
	testing.expect(t, strings.contains(sheet, "@media (prefers-reduced-motion: reduce) {\n  .mark-stage { display: none; }\n  .home-head picture.mark-replaced { display: block; }\n}"))
	// Each size of the rules of the mark is a count of pixels that the
	// factor divides: a cell is a whole count of pixels of the page. No
	// size is a part of the page or of the window.
	rules := site_mark_animation_rules()
	sizes := 0
	rest := rules
	for {
		end := strings.index(rest, "px;")
		if end < 0 {
			break
		}
		start := end
		for start > 0 && rest[start - 1] >= '0' && rest[start - 1] <= '9' {
			start -= 1
		}
		value := 0
		for digit in rest[start:end] {
			value = value * 10 + int(digit - '0')
		}
		testing.expectf(t, start < end && value % SITE_MARK_HOME_FACTOR == 0, "the size %s px of the rules of the mark is not a whole count of cells", rest[start:end])
		sizes += 1
		rest = rest[end + len("px;"):]
	}
	// The still picture 2, the stage 2, the heron 4, the water 2.
	testing.expect_value(t, sizes, 10)
	for unit in ([]string{"%", "vw", "vh", "em;", "calc("}) {
		testing.expectf(t, !strings.contains(rules, unit), "the rules of the mark hold a size in %s", unit)
	}
	// The same factor at every width of the window: the rules of the mark
	// hold one rule for a kind of window, the one of the reduced motion,
	// and it holds no size.
	testing.expect_value(t, strings.count(rules, "@media"), 1)
	// No smoothing, in the two words that browsers know, for the still
	// picture and for the canvases; the standard word is the last.
	testing.expect_value(t, strings.count(rules, SITE_MARK_NO_SMOOTHING), 2)
	testing.expect_value(t, SITE_MARK_NO_SMOOTHING, "image-rendering: crisp-edges; image-rendering: pixelated; ")
	// The home shows the heron of a page, 24 by 24 pixels, at 192.
	site := test_site()
	site.readme.mark_description = "The mark"
	head := strings.builder_make(context.temp_allocator)
	site_home_head(&site, &head)
	testing.expect(t, strings.contains(strings.to_string(head), "<img class=\"mark\" src=\"pictures/mark_heron.png\" width=\"192\" height=\"192\" alt=\"The mark\">"))
	testing.expect(t, strings.contains(strings.to_string(head), "<source media=\"(prefers-color-scheme: light)\" srcset=\"pictures/mark_heron_light.png\">"))
}

// A sheet has one pixel for each cell: its size is the count of the cells
// of its sprites and of its drawn forms, 384 by 124. Each pixel that is
// not empty has the color that support/mark gives to its cell at a cell
// size of 1, so the colors of a sheet are colors of the mark only: 271 of
// them in each color scheme, too many for a palette of 256. The sheet is
// the smallest file that the encoder writes, and decodes to the same
// pixels as the file at the common level.
@(test)
site_mark_sheets_have_one_pixel_for_a_cell :: proc(t: ^testing.T) {
	sprites, ok := site_mark_sprites()
	forms, forms_ok := site_mark_forms(&sprites)
	sheets, sheets_ok := site_mark_sheets()
	testing.expect(t, ok && forms_ok && sheets_ok)
	if !ok || !forms_ok || !sheets_ok {
		return
	}
	columns, rows := site_mark_sheet_shape(len(sprites.cells))
	for sheet in sheets {
		testing.expect_value(t, sheet.picture.heron_cell, 1)
		testing.expect(t, sheet.with_forms)
		pixels, width, height, channels := site_mark_sheet_pixels(sheet.picture, &sprites, &forms)
		testing.expect_value(t, channels, 4)
		testing.expect_value(t, width, columns * mark.HERON_GRID_SIZE)
		testing.expect_value(t, width, 384)
		form_rows := (len(forms.drawn) + width / mark.FORM_COLUMNS_MOST - 1) / (width / mark.FORM_COLUMNS_MOST)
		testing.expect_value(t, height, rows * mark.HERON_GRID_SIZE + form_rows * mark.FORM_ROWS_MOST)
		testing.expect_value(t, height, 124)
		// Each sprite, pixel by pixel: the color of the cell.
		colors := make(map[u32]bool, context.temp_allocator)
		for &cells, index in sprites.cells {
			left := (index % SITE_MARK_SHEET_COLUMNS) * mark.HERON_GRID_SIZE
			top := (index / SITE_MARK_SHEET_COLUMNS) * mark.HERON_GRID_SIZE
			for row in 0 ..< mark.HERON_GRID_SIZE {
				for column in 0 ..< mark.HERON_GRID_SIZE {
					pixel := pixels[((top + row) * width + left + column) * 4:][:4]
					color, covered := mark.cells_pixel(&cells, 1, column, row, sheet.picture.on_light)
					written := u32(pixel[0]) << 16 | u32(pixel[1]) << 8 | u32(pixel[2])
					if covered != (pixel[3] == 0xFF) || (covered && written != color) || (!covered && (written != 0 || pixel[3] != 0)) {
						testing.expectf(t, false, "%s: the pixel %d, %d of the sprite %d is not the cell", sheet.file_name, column, row, index)
						return
					}
					if covered {
						colors[color] = true
					}
				}
			}
		}
		// Each drawn form, cell by cell, in its box.
		form_top := rows * mark.HERON_GRID_SIZE
		form_columns := width / mark.FORM_COLUMNS_MOST
		for &drawn, index in forms.drawn {
			left := (index % form_columns) * mark.FORM_COLUMNS_MOST
			top := form_top + (index / form_columns) * mark.FORM_ROWS_MOST
			for row in 0 ..< mark.FORM_ROWS_MOST {
				for column in 0 ..< mark.FORM_COLUMNS_MOST {
					pixel := pixels[((top + row) * width + left + column) * 4:][:4]
					color, covered := mark.form_cells_pixel(&drawn, 1, column - mark.FORM_REACH_LEFT, row - mark.FORM_REACH_UP, sheet.picture.on_light)
					written := u32(pixel[0]) << 16 | u32(pixel[1]) << 8 | u32(pixel[2])
					if covered != (pixel[3] == 0xFF) || (covered && written != color) {
						testing.expectf(t, false, "%s: the pixel %d, %d of the drawn form %d is not the cell", sheet.file_name, column, row, index)
						return
					}
					if covered {
						colors[color] = true
					}
				}
			}
		}
		testing.expect_value(t, len(colors), 271)
		// The smallest file holds the same pixels as the common one, and
		// is not larger.
		smallest, smallest_ok := site_pixels_encode_smallest(sheet.file_name, width, height, channels, pixels)
		common, common_ok := site_pixels_encode(sheet.file_name, width, height, channels, pixels)
		testing.expect(t, smallest_ok && common_ok)
		testing.expectf(t, len(smallest) <= len(common), "%s: %d bytes at the highest level, %d at the common one", sheet.file_name, len(smallest), len(common))
		testing.expect(t, png_has_pixels(smallest, width, height, channels, pixels))
		again, _ := site_pixels_encode_smallest(sheet.file_name, width, height, channels, pixels)
		testing.expect(t, string(again) == string(smallest), "two encodings of one sheet differ")
	}
}

// The icon of the tab that the script draws during an animation is cut
// from the sheet of the light scheme: the icon of 32 pixels of favicon.ico
// is the still heron of that scheme, one pixel for a cell, 4 empty pixels
// from each edge.
@(test)
site_mark_tab_icon_is_the_heron_of_the_light_sheet :: proc(t: ^testing.T) {
	icon, icon_ok := site_mark_tab_icon_picture()
	_, heron_light, pictures_ok := site_mark_animation_pictures()
	testing.expect(t, icon_ok && pictures_ok)
	if !icon_ok || !pictures_ok {
		return
	}
	testing.expect_value(t, SITE_MARK_ANIMATION_ICON_MARGIN, 4)
	icon_width, icon_height := site_mark_size(icon)
	testing.expect_value(t, icon_width, SITE_MARK_ANIMATION_ICON_SIZE)
	testing.expect_value(t, icon_height, SITE_MARK_ANIMATION_ICON_SIZE)
	testing.expect_value(t, site_mark_channels(icon), 4)
	testing.expect(t, heron_light.on_light)
	still := mark.still_cells()
	icon_pixels := site_mark_pixels(icon, &still)
	heron_pixels := site_mark_pixels(heron_light, &still)
	for row in 0 ..< SITE_MARK_ANIMATION_ICON_SIZE {
		for column in 0 ..< SITE_MARK_ANIMATION_ICON_SIZE {
			from_icon := icon_pixels[(row * SITE_MARK_ANIMATION_ICON_SIZE + column) * 4:][:4]
			expected := [4]u8{}
			in_row := row - SITE_MARK_ANIMATION_ICON_MARGIN
			in_column := column - SITE_MARK_ANIMATION_ICON_MARGIN
			if in_row >= 0 && in_row < mark.HERON_GRID_SIZE && in_column >= 0 && in_column < mark.HERON_GRID_SIZE {
				copy(expected[:], heron_pixels[(in_row * mark.HERON_GRID_SIZE + in_column) * 4:][:4])
			}
			if from_icon[0] != expected[0] || from_icon[1] != expected[1] || from_icon[2] != expected[2] || from_icon[3] != expected[3] {
				testing.expectf(t, false, "the pixel %d, %d of the icon is not the heron of the light sheet", column, row)
				return
			}
		}
	}
}

// A cell of the heron never changes its form on the site: the script and
// the rules of the style sheet for the mark change the size of no picture
// and turn none. The script places the heron by a translation of whole
// cells, in steps.
@(test)
site_mark_script_and_style_scale_nothing :: proc(t: ^testing.T) {
	sprites, ok := site_mark_sprites()
	home, _, pictures_ok := site_mark_animation_pictures()
	forms, forms_ok := site_mark_forms(&sprites)
	testing.expect(t, ok && pictures_ok && forms_ok)
	script := site_mark_animation_script(&sprites, &forms, home, TEST_SHEET_ADDRESSES)
	rules := site_mark_animation_rules()
	for word in ([]string{"scale(", "scaleX", "scaleY", "scale3d", "matrix(", "rotate(", "skew", "zoom", "transform-origin"}) {
		testing.expectf(t, !strings.contains(script, word), "the script of the mark holds %s", word)
		testing.expectf(t, !strings.contains(rules, word), "the rules of the mark hold %s", word)
	}
	testing.expect(t, !strings.contains(rules, "transform"))
	testing.expect(t, !strings.contains(rules, "width: 100%") && !strings.contains(rules, "object-fit"))
	// One transform in the script: a translation, of a count of cells
	// times the pixels of a cell, in steps.
	testing.expect_value(t, strings.count(script, "transform:"), 1)
	testing.expect(t, strings.contains(script, "transform: \"translate(\" + place[0] * cell + \"px, \" + -place[1] * cell + \"px)\""))
	testing.expect(t, strings.contains(script, "easing: \"steps(\""))
	testing.expect(t, !strings.contains(script, "ease-") && !strings.contains(script, "linear") && !strings.contains(script, "cubic-bezier"))
	// A picture is copied at its own size: each drawImage of the heron
	// has the same width and height at its source and at its place.
	testing.expect(t, strings.contains(script, "heronContext.drawImage(sheet, left, top, width, above, forms.left, forms.up, width, above);"))
	testing.expect(t, strings.contains(script, "forms.width, forms.height, 0, 0, forms.width, forms.height);"))
	testing.expect(t, strings.contains(script, "waterContext.drawImage(sheet, left, top + above, width, TABLE.home.water, 0, 0, width, TABLE.home.water);"))
	testing.expect(t, strings.contains(script, "width, height, margin, margin, width, height);"))
	// Four copies in all, and the script asks for no smoothing of a copy:
	// a copy at its own size has none.
	testing.expect_value(t, strings.count(script, "drawImage("), 4)
	testing.expect(t, !strings.contains(script, "imageSmoothing"))
	// A canvas has one pixel for a cell: its size is a count of the table,
	// in pixels of the sheet, and the script sets no size of the page.
	testing.expect(t, strings.contains(script, "heron.width = TABLE.forms.width;") && strings.contains(script, "heron.height = TABLE.forms.height;"))
	testing.expect(t, strings.contains(script, "water.width = width;") && strings.contains(script, "water.height = TABLE.home.water;"))
	testing.expect(t, !strings.contains(script, ".style"))
	testing.expect(t, strings.contains(sheet_rule_of_pixels(), "image-rendering: pixelated"))
}

// The rule that keeps the pixels of a canvas of the stage.
@(private = "file")
sheet_rule_of_pixels :: proc() -> string {
	rules := site_mark_animation_rules()
	start := strings.index(rules, "." + SITE_MARK_STAGE_CLASS + " canvas {")
	if start < 0 {
		return ""
	}
	return rules[start:]
}

// The steps of the play of each animation: their times add up to the time
// of the animation; they show the frames in their order; an animation with
// no move shows no drawn form; a step of a move shows the form of the key
// of support/mark at its time, and the sprite of the frame at its time.
@(test)
site_mark_steps_follow_the_frames_and_the_keys :: proc(t: ^testing.T) {
	sprites, ok := site_mark_sprites()
	forms, forms_ok := site_mark_forms(&sprites)
	testing.expect(t, ok && forms_ok)
	if !ok || !forms_ok {
		return
	}
	testing.expect_value(t, len(forms.forms), len(forms.drawn))
	for animation in mark.Animation {
		steps := forms.steps[animation]
		at := 0
		for step, index in steps {
			testing.expectf(t, step.milliseconds > 0, "%v: the step %d lasts %d ms", animation, index, step.milliseconds)
			if index > 0 {
				testing.expectf(t, steps[index - 1].sprite != step.sprite || steps[index - 1].form != step.form, "%v: the steps %d and %d show the same picture", animation, index - 1, index)
			}
			// The frame at the start and at the last millisecond of the step.
			times := [2]int{at, at + step.milliseconds - 1}
			for time in times {
				frame, frame_start := 1, 0
				for frame < mark.animation_frame_count(animation) {
					row, _ := mark.animation_frame(animation, frame)
					if time < frame_start + int(row.duration_milliseconds) {
						break
					}
					frame_start += int(row.duration_milliseconds)
					frame += 1
				}
				testing.expectf(t, step.sprite == sprites.of_frame[animation][frame - 1], "%v at %d ms: the step shows the sprite %d, not the frame %d", animation, time, step.sprite, frame)
				pose := mark.move_pose(animation, time, mark.Move_Travel{})
				if pose.form == .Natural {
					testing.expectf(t, step.form == -1, "%v at %d ms: a drawn form for the natural heron", animation, time)
				} else {
					drawn, found := mark.form_cells(pose.form, animation, frame)
					testing.expectf(t, found && step.form >= 0 && step.form < len(forms.drawn) && forms.drawn[step.form] == drawn, "%v at %d ms: the step does not show the form %v of the frame %d", animation, time, pose.form, frame)
				}
			}
			at += step.milliseconds
		}
		testing.expect_value(t, at, mark.animation_duration(animation))
		if !mark.animation_moves(animation) {
			testing.expect_value(t, len(steps), mark.animation_frame_count(animation) - merged_frames(&sprites, animation))
		}
	}
	// The drawings are distinct.
	for index in 0 ..< len(forms.drawn) {
		for other in index + 1 ..< len(forms.drawn) {
			testing.expectf(t, forms.drawn[index] != forms.drawn[other], "the drawn forms %d and %d are the same", index, other)
		}
	}
	// The dash: the wind-up in two forms, the run in one, the stop in two,
	// the rebound: 7 drawings; then the natural heron.
	dash := forms.steps[.Dash]
	testing.expect_value(t, dash[0], Site_Mark_Play_Step{milliseconds = 90, sprite = sprites.of_frame[.Dash][0], form = -1})
	testing.expect_value(t, dash[1].milliseconds, 90)
	testing.expect_value(t, forms.forms[dash[1].form], mark.Form.Gather)
	testing.expect_value(t, dash[2].milliseconds, 200)
	testing.expect_value(t, forms.forms[dash[2].form], mark.Form.Crouch)
	testing.expect_value(t, dash[3].milliseconds, 70)
	testing.expect_value(t, forms.forms[dash[3].form], mark.Form.Run)
	testing.expect_value(t, dash[len(dash) - 1], Site_Mark_Play_Step{milliseconds = 100, sprite = sprites.of_frame[.Dash][16], form = -1})
	// A fault of the keys has a sentence, and the keys of support/mark
	// have none.
	testing.expect_value(t, site_mark_move_fault_text(mark.move_keys[:]), "")
	faulty := mark.move_keys
	for &key in faulty {
		if key.animation == .Hop && key.at_milliseconds == 120 {
			key.cells_up = 1
		}
	}
	testing.expect_value(t, site_mark_move_fault_text(faulty[:]), "the move of hop, the key at 120 ms: the key moves the heron while a foot is in the water")
}

// merged_frames gives the count of the frames of an animation that show
// the sprite of the frame before them: the play shows them as one step.
@(private = "file")
merged_frames :: proc(sprites: ^Site_Mark_Sprites, animation: mark.Animation) -> int {
	merged := 0
	for sprite, index in sprites.of_frame[animation] {
		if index > 0 && sprites.of_frame[animation][index - 1] == sprite {
			merged += 1
		}
	}
	return merged
}

// The rule of the choice: in each round of the memory each animation plays
// once; no animation follows itself, also from the end of a round to the
// start of the next one; the order is not the same in each round.
@(test)
site_mark_choice_plays_each_animation_once_in_a_round :: proc(t: ^testing.T) {
	seeds := [?]u32{1, 2, 3, 20261114, 0xFFFFFFFF}
	for seed in seeds {
		memory := SITE_MARK_MEMORY_EMPTY
		generator := Site_Mark_Generator{seed}
		previous := -1
		first_round: [SITE_MARK_ANIMATION_COUNT]int
		rounds_as_the_first := 0
		ROUNDS :: 400
		for round in 0 ..< ROUNDS {
			seen: u32
			as_the_first := true
			for place in 0 ..< SITE_MARK_ANIMATION_COUNT {
				animation := site_mark_next_animation(&memory, &generator)
				testing.expectf(t, animation >= 0 && animation < SITE_MARK_ANIMATION_COUNT, "the seed %d: the animation %d does not exist", seed, animation)
				testing.expectf(t, animation != previous, "the seed %d, round %d: the animation %d follows itself", seed, round, animation)
				testing.expectf(t, seen & (u32(1) << uint(animation)) == 0, "the seed %d, round %d: the animation %d plays two times", seed, round, animation)
				seen |= u32(1) << uint(animation)
				previous = animation
				testing.expect_value(t, memory.last, animation)
				if round == 0 {
					first_round[place] = animation
				} else if first_round[place] != animation {
					as_the_first = false
				}
			}
			testing.expect_value(t, seen, (u32(1) << SITE_MARK_ANIMATION_COUNT) - 1)
			testing.expect_value(t, memory.played, seen)
			if round > 0 && as_the_first {
				rounds_as_the_first += 1
			}
		}
		testing.expectf(t, rounds_as_the_first < ROUNDS / 100, "the seed %d: %d rounds have the order of the first round", seed, rounds_as_the_first)
	}
}

// A memory that a page of the visit kept: the play goes on from it. The
// animations that it holds do not play before the others did.
@(test)
site_mark_choice_goes_on_from_a_kept_memory :: proc(t: ^testing.T) {
	kept := Site_Mark_Memory{played = 0b0000_0000_0010_1101, last = 5}
	held := kept.played
	generator := Site_Mark_Generator{7}
	left := 0
	for index in 0 ..< SITE_MARK_ANIMATION_COUNT {
		if held & (u32(1) << uint(index)) == 0 {
			left += 1
		}
	}
	for _ in 0 ..< left {
		animation := site_mark_next_animation(&kept, &generator)
		testing.expectf(t, held & (u32(1) << uint(animation)) == 0, "the animation %d was in the memory", animation)
	}
	testing.expect_value(t, kept.played, (u32(1) << SITE_MARK_ANIMATION_COUNT) - 1)
	// The memory is full: the next choice empties it, and is not the
	// animation played last.
	last := kept.last
	animation := site_mark_next_animation(&kept, &generator)
	testing.expect(t, animation != last)
	testing.expect_value(t, kept.played, u32(1) << uint(animation))
}

// The still share: the bounds of a still time follow from the times of the
// animations, and over a long play of the model the heron is still for the
// still share of the time, within one point.
@(test)
site_mark_heron_is_still_for_its_share :: proc(t: ^testing.T) {
	least, most := site_mark_still_bounds()
	total := site_mark_animations_duration()
	testing.expect_value(t, total, 19310)
	testing.expect_value(t, least, 429)
	testing.expect_value(t, most, 1287)
	// The mean still time times the moving share is the mean time of an
	// animation times the still share, within the rounding of one
	// millisecond for each animation.
	mean_still := (least + most) / 2
	difference := mean_still * (100 - SITE_MARK_STILL_SHARE_PERCENT) * SITE_MARK_ANIMATION_COUNT - total * SITE_MARK_STILL_SHARE_PERCENT
	testing.expectf(t, abs(difference) <= (100 - SITE_MARK_STILL_SHARE_PERCENT) * SITE_MARK_ANIMATION_COUNT, "the mean still time %d ms is not the share of %d ms", mean_still, total)
	// Two animations never read as one: the shortest still time is several
	// of the shortest common frames.
	testing.expect(t, least >= 2 * mark.FRAME_DURATION_LEAST)
	seeds := [?]u32{1, 2, 3, 20261114}
	for seed in seeds {
		memory := SITE_MARK_MEMORY_EMPTY
		generator := Site_Mark_Generator{seed}
		still_time, moving_time := 0, 0
		for _ in 0 ..< 400 * SITE_MARK_ANIMATION_COUNT {
			step := site_mark_step(&memory, &generator)
			testing.expectf(t, step.still_milliseconds >= least && step.still_milliseconds <= most, "a still time of %d ms", step.still_milliseconds)
			still_time += step.still_milliseconds
			moving_time += mark.animation_duration(mark.Animation(step.animation))
		}
		// In thousandths, so that the test has no fraction.
		share := 1000 * still_time / (still_time + moving_time)
		testing.expectf(t, share >= 10 * (SITE_MARK_STILL_SHARE_PERCENT - 1) && share <= 10 * (SITE_MARK_STILL_SHARE_PERCENT + 1), "the seed %d: the heron is still for %d thousandths of the time", seed, share)
	}
}

// The generator of the model gives the numbers that the script computes
// with Math.imul: the product wraps at 32 bits, and a number is under its
// bound.
@(test)
site_mark_generator_wraps_at_32_bits :: proc(t: ^testing.T) {
	generator := Site_Mark_Generator{0}
	first := site_mark_generator_below(&generator, 1 << 16)
	// 1013904223 is 0x3C6EF35F: its upper 16 bits are 0x3C6E.
	testing.expect_value(t, generator.state, u32(1013904223))
	testing.expect_value(t, first, 0x3C6E)
	for bound in 1 ..= 40 {
		value := site_mark_generator_below(&generator, bound)
		testing.expectf(t, value >= 0 && value < bound, "the number %d is not under %d", value, bound)
	}
	// The steps of the check start with an empty memory and do not change
	// from one call to the next.
	once := site_mark_check_steps()
	again := site_mark_check_steps()
	testing.expect_value(t, len(once), SITE_MARK_CHECK_STEP_COUNT)
	for step, index in once {
		testing.expect_value(t, again[index], step)
	}
}

// The name of the mark on a page: the font is a file of the site that the
// style sheet declares once, the class names it, and the box of the name
// has the size of the name in cells at each of the two sizes.
@(test)
site_mark_name_rules_name_the_font :: proc(t: ^testing.T) {
	sheet := site_style_sheet("")
	testing.expect_value(t, strings.count(sheet, "@font-face"), 1)
	testing.expect(t, strings.contains(sheet, "@font-face { font-family: \"" + MARK_FONT_FAMILY + "\"; src: url(\"" + SITE_MARK_FONT + "\") format(\"truetype\");"))
	testing.expect(t, strings.contains(sheet, "font-display: block;"))
	testing.expect(t, strings.contains(sheet, "." + SITE_MARK_NAME_CLASS + " { display: inline-block;"))
	testing.expect(t, strings.contains(sheet, "font-family: \"" + MARK_FONT_FAMILY + "\", var(--mono);"))
	testing.expect(t, strings.contains(sheet, "font-synthesis: none;"))
	// The bar and the foot: cells of 2 pixels. The home: cells of 6 pixels,
	// the cell of the name that the picture of the home had.
	testing.expect(t, strings.contains(sheet, "width: 66px; height: 16px; font-size: 16px; line-height: 16px; vertical-align: -2px; }"))
	testing.expect(t, strings.contains(sheet, ".home-head ." + SITE_MARK_NAME_CLASS + " { width: 198px; height: 48px; font-size: 48px; line-height: 48px; vertical-align: -6px; }"))
	testing.expect_value(t, SITE_MARK_NAME_HTML, "<span class=\"mark-name\">modus</span>")
	// The description of the heron alone does not speak of the name.
	testing.expect_value(t, site_heron_description("A heron, above the name modus in square letters"), "A heron")
	testing.expect_value(t, site_heron_description("The mark"), "The mark")
}
