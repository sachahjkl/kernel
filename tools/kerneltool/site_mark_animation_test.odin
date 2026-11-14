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
	tile_maps, tile_maps_ok := site_mark_tile_maps()
	testing.expect(t, tile_maps_ok)
	if !tile_maps_ok {
		return
	}
	// The three files are in the site, with the sizes of their tile maps:
	// the two of the home with the drawn forms, the one of the icon of
	// the tab with the frames only.
	testing.expect_value(t, len(files), SITE_MARK_SHEET_COUNT + 1)
	testing.expect_value(t, tile_maps.dark.layout.width, 3072)
	testing.expect_value(t, tile_maps.dark.layout.height, 992)
	testing.expect_value(t, tile_maps.light.layout, tile_maps.dark.layout)
	testing.expect_value(t, len(tile_maps.dark.forms.drawn), 19)
	testing.expect_value(t, tile_maps.icon.layout.width, 384)
	testing.expect_value(t, tile_maps.icon.layout.height, 72)
	testing.expect_value(t, len(tile_maps.icon.forms.drawn), 0)
	testing.expect_value(t, tile_maps.icon.picture.variant, mark.Variant.Cells)
	testing.expect_value(t, tile_maps.dark.picture.variant, mark.Variant.Smooth)
	// The first tile of each tile map of the home is the still picture of
	// the home of its color scheme, pixel for pixel: the heron does not
	// change when the script starts.
	stills := [2]string{SITE_MARK_HOME, SITE_MARK_HOME_LIGHT}
	for tile_map, index in ([2]^Mark_Tile_Map{&tile_maps.dark, &tile_maps.light}) {
		still_picture, still_found := mark_use_picture(stills[index])
		testing.expect(t, still_found)
		still_file, encoded := mark_picture_png(still_picture)
		testing.expect(t, encoded)
		still_image, still_error := png.load_from_bytes(still_file, allocator = context.temp_allocator)
		sheet_image, sheet_error := png.load_from_bytes(files[site_mark_sheet_path(tile_map.picture.file_name)], allocator = context.temp_allocator)
		if still_error != nil || sheet_error != nil {
			testing.expectf(t, false, "%s or its still picture does not decode", tile_map.picture.file_name)
			continue
		}
		testing.expect_value(t, sheet_image.width, tile_map.layout.width)
		testing.expect_value(t, sheet_image.height, tile_map.layout.height)
		testing.expect_value(t, sheet_image.channels, still_image.channels)
		testing.expect_value(t, tile_map.layout.sprite_width, still_image.width)
		row_bytes := still_image.width * still_image.channels
		sheet_row_bytes := sheet_image.width * sheet_image.channels
		same := true
		for row in 0 ..< still_image.height {
			if string(sheet_image.pixels[row * sheet_row_bytes:][:row_bytes]) != string(still_image.pixels[row * row_bytes:][:row_bytes]) {
				same = false
				break
			}
		}
		testing.expectf(t, same, "the first sprite of %s is not its still picture", tile_map.picture.file_name)
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
	// A sprite of the home is the heron alone, 192 pixels wide. The sprites
	// are in rows, and no side of a tile map is longer than a browser
	// decodes.
	home, _ := mark_use_picture(SITE_MARK_HOME)
	sprite_width, sprite_height := mark_picture_size(home)
	testing.expect_value(t, sprite_width, mark.heron_size(home.heron_cell))
	testing.expect_value(t, sprite_height, mark.heron_size(home.heron_cell))
	columns, rows := site_mark_sheet_shape(len(sprites.cells))
	testing.expect(t, columns * rows >= len(sprites.cells))
	testing.expect(t, columns <= MARK_TILE_MAP_COLUMNS)
	testing.expect(t, sprite_width * columns <= MARK_PICTURE_SIDE_MOST)
	testing.expect(t, sprite_height * rows <= MARK_PICTURE_SIDE_MOST)
	single_columns, single_rows := site_mark_sheet_shape(1)
	testing.expect_value(t, single_columns, 1)
	testing.expect_value(t, single_rows, 1)
	full_columns, full_rows := site_mark_sheet_shape(MARK_TILE_MAP_COLUMNS + 1)
	testing.expect_value(t, full_columns, MARK_TILE_MAP_COLUMNS)
	testing.expect_value(t, full_rows, 2)
	for animation in mark.Animation {
		testing.expect_value(t, len(sprites.of_frame[animation]), mark.animation_frame_count(animation))
	}
}

// The addresses of the sheets that a test gives to the table.
@(private = "file")
TEST_SHEET_ADDRESSES :: [SITE_MARK_SHEET_COUNT]string{"pictures/dark.png?v=1", "pictures/light.png?v=2", "pictures/icon.png?v=3"}

// The table in the script is JSON with the counts of support/mark, the
// moves of the tool, the bounds of the still times and the steps of the
// model.
@(test)
site_mark_animation_table_parses :: proc(t: ^testing.T) {
	tile_maps, tile_maps_ok := site_mark_tile_maps()
	testing.expect(t, tile_maps_ok)
	if !tile_maps_ok {
		return
	}
	sprites := tile_maps.dark.sprites
	forms := tile_maps.dark.forms
	home := tile_maps.dark.picture
	table := site_mark_animation_table_json(&tile_maps, TEST_SHEET_ADDRESSES)
	value, err := json.parse_string(table, .JSON, false, context.temp_allocator)
	root, is_object := value.(json.Object)
	testing.expectf(t, err == .None && is_object, "the table does not parse: %v", err)
	if !is_object {
		return
	}
	count, _ := root["sprites"].(json.Float) // parse_string with no integers: each number is a float.
	testing.expect_value(t, int(count), len(sprites.cells))
	columns, _ := root["columns"].(json.Float)
	testing.expect_value(t, int(columns), MARK_TILE_MAP_COLUMNS)
	// The three tile maps, by their addresses.
	sheets_table, _ := root["sheets"].(json.Object)
	dark, _ := sheets_table["dark"].(json.String)
	light, _ := sheets_table["light"].(json.String)
	icon_sheet, _ := sheets_table["icon"].(json.String)
	testing.expect_value(t, dark, "pictures/dark.png?v=1")
	testing.expect_value(t, light, "pictures/light.png?v=2")
	testing.expect_value(t, icon_sheet, "pictures/icon.png?v=3")
	// A tile of the home is 192 by 192 pixels, and its water 16.
	tile_table, _ := root["tile"].(json.Object)
	water, _ := tile_table["water"].(json.Float)
	sprite_width, _ := tile_table["width"].(json.Float)
	sprite_height, _ := tile_table["height"].(json.Float)
	testing.expect_value(t, int(water), mark.WATER_ROWS * home.heron_cell)
	testing.expect_value(t, int(sprite_width), 192)
	testing.expect_value(t, int(sprite_height), 192)
	testing.expect_value(t, int(water), 16)
	// The icon of the tab: 32 pixels, a tile of 24 pixels of its tile map
	// 4 pixels from its edges, 16 tiles in a row.
	icon_table, _ := root["icon"].(json.Object)
	icon_size, _ := icon_table["size"].(json.Float)
	icon_margin, _ := icon_table["margin"].(json.Float)
	icon_tile, _ := icon_table["tile"].(json.Float)
	icon_columns, _ := icon_table["columns"].(json.Float)
	testing.expect_value(t, int(icon_size), 32)
	testing.expect_value(t, int(icon_margin), 4)
	testing.expect_value(t, int(icon_tile), 24)
	testing.expect_value(t, int(icon_columns), MARK_TILE_MAP_COLUMNS)
	// Where the drawn forms are in a tile map of the home, in pixels: under
	// the three rows of the sprites, twelve boxes of 256 by 208 in a row,
	// the natural heron 48 from the left of its box and 32 from its top.
	forms_table, _ := root["forms"].(json.Object)
	layout := tile_maps.dark.layout
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
	testing.expect_value(t, layout.form_top, 576)
	testing.expect_value(t, layout.form_width, 256)
	testing.expect_value(t, layout.form_height, 208)
	testing.expect_value(t, layout.width, 3072)
	testing.expect_value(t, layout.height, 992)
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
	still_least, still_most := mark.still_bounds()
	written_least, _ := schedule["stillLeast"].(json.Float)
	written_most, _ := schedule["stillMost"].(json.Float)
	written_share, _ := schedule["sharePercent"].(json.Float)
	testing.expect_value(t, int(written_least), still_least)
	testing.expect_value(t, int(written_most), still_most)
	testing.expect_value(t, int(written_share), mark.STILL_SHARE_PERCENT)
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
	script := site_mark_animation_script(&tile_maps, TEST_SHEET_ADDRESSES)
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
	testing.expect_value(t, mark.GENERATOR_MULTIPLIER, 1664525)
	testing.expect_value(t, mark.GENERATOR_INCREMENT, 1013904223)
}

// The rules of the style sheet for the heron of the home. The pictures of
// the home are the smooth variant, 8 pixels for a cell, and the page shows
// them at their own size: the stage, the canvas of the heron (the box of a
// form, 32 by 26 cells) and the canvas of the water (24 by 2 cells) each
// have a size in pixels that is their count of cells times the pixels of
// a cell of the still picture of the home, which the table of the uses of
// the mark gives. What moves takes no pointer, the page is cut at the
// sides of the window while the heron crosses it, and a reader who asks
// for reduced motion sees the still picture.
@(test)
site_mark_animation_rules_keep_the_page :: proc(t: ^testing.T) {
	sheet := site_style_sheet("")
	home, home_found := mark_use_picture(SITE_MARK_HOME)
	testing.expect(t, home_found)
	factor := home.heron_cell
	testing.expect_value(t, factor, 8)
	testing.expect_value(t, home.variant, mark.Variant.Smooth)
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
		testing.expectf(t, start < end && value % factor == 0, "the size %s px of the rules of the mark is not a whole count of cells", rest[start:end])
		sizes += 1
		rest = rest[end + len("px;"):]
	}
	// The stage 2, the heron 4, the water 2.
	testing.expect_value(t, sizes, 8)
	for unit in ([]string{"%", "vw", "vh", "em;", "calc("}) {
		testing.expectf(t, !strings.contains(rules, unit), "the rules of the mark hold a size in %s", unit)
	}
	// The same factor at every width of the window: the rules of the mark
	// hold one rule for a kind of window, the one of the reduced motion,
	// and it holds no size.
	testing.expect_value(t, strings.count(rules, "@media"), 1)
	// No smoothing, in the two words that browsers know, for the canvases;
	// the standard word is the last.
	testing.expect_value(t, strings.count(rules, SITE_MARK_NO_SMOOTHING), 1)
	testing.expect_value(t, SITE_MARK_NO_SMOOTHING, "image-rendering: crisp-edges; image-rendering: pixelated; ")
	// The home shows its still picture, the smooth variant, at its size.
	site := test_site()
	site.readme.mark_description = "The mark"
	head := strings.builder_make(context.temp_allocator)
	site_home_head(&site, &head)
	testing.expect(t, strings.contains(strings.to_string(head), "<img class=\"mark\" src=\"pictures/mark_home.png\" width=\"192\" height=\"192\" alt=\"The mark\">"))
	testing.expect(t, strings.contains(strings.to_string(head), "<source media=\"(prefers-color-scheme: light)\" srcset=\"pictures/mark_home_light.png\">"))
}

// The icon of the tab that the script draws during an animation is a tile
// of the tile map of the icon: the icon of 32 pixels of favicon.ico is the
// still heron of that tile map, the cells variant, one pixel for a cell, in
// the light scheme, 4 empty pixels from each edge.
@(test)
site_mark_tab_icon_is_a_tile_of_its_tile_map :: proc(t: ^testing.T) {
	icon, icon_ok := site_mark_tab_icon_picture()
	heron_light, pictures_ok := mark_use_picture(SITE_MARK_ANIMATION_ICON)
	testing.expect(t, icon_ok && pictures_ok)
	if !icon_ok || !pictures_ok {
		return
	}
	testing.expect_value(t, SITE_MARK_ANIMATION_ICON_MARGIN, 4)
	icon_width, icon_height := mark_picture_size(icon)
	testing.expect_value(t, icon_width, SITE_MARK_ANIMATION_ICON_SIZE)
	testing.expect_value(t, icon_height, SITE_MARK_ANIMATION_ICON_SIZE)
	testing.expect_value(t, mark_picture_channels(icon), 4)
	testing.expect(t, heron_light.on_light)
	testing.expect_value(t, heron_light.variant, icon.variant)
	testing.expect_value(t, heron_light.heron_cell, icon.heron_cell)
	still := mark.still_cells()
	icon_pixels := mark_picture_pixels(icon, &still)
	heron_pixels := mark_picture_pixels(heron_light, &still)
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
				testing.expectf(t, false, "the pixel %d, %d of the icon is not the heron of its tile map", column, row)
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
	tile_maps, tile_maps_ok := site_mark_tile_maps()
	testing.expect(t, tile_maps_ok)
	script := site_mark_animation_script(&tile_maps, TEST_SHEET_ADDRESSES)
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
	testing.expect(t, strings.contains(script, "waterContext.drawImage(sheet, left, top + above, width, TABLE.tile.water, 0, 0, width, TABLE.tile.water);"))
	testing.expect(t, strings.contains(script, "tile, tile, margin, margin, tile, tile);"))
	// Four copies in all, and the script asks for no smoothing of a copy:
	// a copy at its own size has none.
	testing.expect_value(t, strings.count(script, "drawImage("), 4)
	testing.expect(t, !strings.contains(script, "imageSmoothing"))
	// A canvas has the pixels of its tiles: its size is a count of the table,
	// in pixels of the sheet, and the script sets no size of the page.
	testing.expect(t, strings.contains(script, "heron.width = TABLE.forms.width;") && strings.contains(script, "heron.height = TABLE.forms.height;"))
	testing.expect(t, strings.contains(script, "water.width = width;") && strings.contains(script, "water.height = TABLE.tile.water;"))
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

// The list that ties the script to the rule of support/mark (the tests of
// the rule itself are there: play_test.odin). The steps start with an
// empty memory, do not change from one call to the next, hold each
// animation once in each of the two whole rounds, and no animation follows
// itself, also where the memory is emptied.
@(test)
site_mark_check_steps_follow_the_rule :: proc(t: ^testing.T) {
	once := site_mark_check_steps()
	again := site_mark_check_steps()
	testing.expect_value(t, len(once), SITE_MARK_CHECK_STEP_COUNT)
	testing.expect_value(t, len(once), 2 * mark.ANIMATION_COUNT + 3)
	least, most := mark.still_bounds()
	previous := -1
	seen: u32
	for step, index in once {
		testing.expect_value(t, again[index], step)
		testing.expectf(t, step.still_milliseconds >= least && step.still_milliseconds <= most, "the step %d: a still time of %d ms", index, step.still_milliseconds)
		testing.expectf(t, step.animation != previous, "the step %d: the animation %d follows itself", index, step.animation)
		previous = step.animation
		if index % mark.ANIMATION_COUNT == 0 {
			seen = 0
		}
		testing.expectf(t, seen & (u32(1) << uint(step.animation)) == 0, "the step %d: the animation %d plays two times in its round", index, step.animation)
		seen |= u32(1) << uint(step.animation)
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
