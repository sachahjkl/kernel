package kerneltool

import "core:encoding/json"
import "core:image/png"
import "core:strings"
import "core:testing"
import "support:mark"

// The files of the animations read back as the frames of support/mark, and
// the first sprite of each sheet is the still picture that the site shows
// with no script: the head of the home, and the 32 of favicon.ico.
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
		testing.expect_value(t, sheet_image.height, still_image.height * rows)
		testing.expect_value(t, sheet_image.width, still_image.width * columns)
		testing.expect_value(t, sheet_image.channels, still_image.channels)
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
	damaged[SITE_PICTURE_FOLDER + "/" + SITE_MARK_ANIMATION_ICON] = files[SITE_PICTURE_FOLDER + "/" + SITE_MARK_ANIMATION_HOME]
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
	// are in rows, and no side of a sheet is longer than a browser decodes.
	home, _, _, _ := site_mark_animation_pictures()
	sprite_width, sprite_height := site_mark_size(home)
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
TEST_SHEET_ADDRESSES :: [3]string{"pictures/dark.png?v=1", "pictures/light.png?v=2", "pictures/icon.png?v=3"}

// The table in the script is JSON with the counts of support/mark, the
// moves of the tool, the bounds of the still times and the steps of the
// model.
@(test)
site_mark_animation_table_parses :: proc(t: ^testing.T) {
	sprites, ok := site_mark_sprites()
	home, _, _, pictures_ok := site_mark_animation_pictures()
	testing.expect(t, ok && pictures_ok)
	table := site_mark_animation_table_json(&sprites, home, TEST_SHEET_ADDRESSES)
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
	testing.expect_value(t, int(water), SITE_MARK_WATER_ROWS * home.heron_cell)
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
		motion, has_motion := object["motion"].(json.Array)
		testing.expect_value(t, has_motion, site_mark_animation_moves(animation))
		if !has_motion {
			continue
		}
		moving += 1
		keys := 0
		for key in site_mark_motion_keys {
			if key.animation == animation {
				keys += 1
			}
		}
		testing.expect_value(t, len(motion), keys)
		for key in motion {
			values, _ := key.(json.Array)
			testing.expect_value(t, len(values), 7)
		}
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
	script := site_mark_animation_script(&sprites, home, TEST_SHEET_ADDRESSES)
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

// The rules of the style sheet for the heron that plays: the stage has the
// box of the still picture, what moves takes no pointer, the page is cut at
// the sides of the window while the heron crosses it, and a reader who asks
// for reduced motion sees the still picture.
@(test)
site_mark_animation_rules_keep_the_page :: proc(t: ^testing.T) {
	sheet := site_style_sheet("")
	home, _, _, _ := site_mark_animation_pictures()
	width, height := site_mark_size(home)
	testing.expect_value(t, width, 192)
	testing.expect_value(t, height, 192)
	testing.expect(t, strings.contains(sheet, ".mark-stage { display: block; position: relative; width: 192px; height: 192px; }"))
	testing.expect(t, strings.contains(sheet, ".mark-stage canvas { display: block; position: absolute; left: 0; image-rendering: pixelated; pointer-events: none; }"))
	testing.expect(t, strings.contains(sheet, ".mark-heron { top: 0; transform-origin: 50% 100%; }"))
	testing.expect(t, strings.contains(sheet, "html.mark-travel { overflow-x: clip; }"))
	testing.expect(t, strings.contains(sheet, "@media (prefers-reduced-motion: reduce) {\n  .mark-stage { display: none; }\n  .home-head picture.mark-replaced { display: block; }\n}"))
}

// The moves agree with the frames of support/mark: each goes from the
// heron in its place to the heron in its place, over the time of its
// animation, and no key moves the heron while a foot is in the water. A
// table with a fault is found.
@(test)
site_mark_moves_agree_with_the_frames :: proc(t: ^testing.T) {
	problems := site_mark_motion_problems(site_mark_motion_keys[:])
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	// The dash leaves by the right edge and comes back by the left one.
	past_right, past_left := 0, 0
	for key in site_mark_motion_keys {
		if key.edge != .None {
			testing.expect_value(t, key.animation, mark.Animation.Dash)
		}
		if key.edge == .Past_Right {
			past_right += 1
		}
		if key.edge == .Past_Left {
			past_left += 1
		}
	}
	testing.expect_value(t, past_right, 1)
	testing.expect_value(t, past_left, 1)
	// The still heron has a foot in the water; the run of the dash has none.
	still := mark.still_cells()
	testing.expect(t, site_mark_frame_has_foot_in_water(&still))
	run, _ := mark.animation_frame_cells(.Dash, 2)
	testing.expect(t, !site_mark_frame_has_foot_in_water(&run))
	// A key that lifts the heron in the first frame of the hop, where its
	// foot is in the water, is a fault.
	// The fault is in a copy: the tests run at the same time, and the
	// table of the site is read by others.
	faulty := site_mark_motion_keys
	for &key in faulty {
		if key.animation == .Hop && key.at_milliseconds == 180 {
			key.cells_up = 1
		}
	}
	testing.expect(t, len(site_mark_motion_problems(faulty[:])) > 0)
	// A dash that stays past the right edge to its end is a fault too.
	no_return := site_mark_motion_keys
	for &key in no_return {
		if key.edge == .Past_Left {
			key.edge = .Past_Right
		}
	}
	testing.expect(t, len(site_mark_motion_problems(no_return[:])) > 0)
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
