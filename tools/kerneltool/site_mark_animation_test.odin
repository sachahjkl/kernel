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
	// Where the drawn forms are in a sheet of the home: under the three
	// rows of the sprites, twelve boxes of 256 by 208 pixels in a row, the
	// natural heron 48 pixels from the left of its box and 32 from its top.
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
	// The canvas of the heron is the box of a form: 6 cells past the stage
	// at its left, its bottom on the line of the water.
	testing.expect(t, strings.contains(sheet, ".mark-stage .mark-heron { left: -48px; bottom: 16px; }"))
	testing.expect(t, strings.contains(sheet, ".mark-stage .mark-water { bottom: 0; }"))
	testing.expect(t, strings.contains(sheet, "html.mark-travel { overflow-x: clip; }"))
	testing.expect(t, strings.contains(sheet, "@media (prefers-reduced-motion: reduce) {\n  .mark-stage { display: none; }\n  .home-head picture.mark-replaced { display: block; }\n}"))
}

// A cell of the heron never changes its form on the site: the script and
// the rules of the style sheet for the mark change the size of no picture
// and turn none. The script places the heron by a translation of whole
// cells, in steps.
@(test)
site_mark_script_and_style_scale_nothing :: proc(t: ^testing.T) {
	sprites, ok := site_mark_sprites()
	home, _, _, pictures_ok := site_mark_animation_pictures()
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
