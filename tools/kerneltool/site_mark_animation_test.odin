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
	home_dark, home_light, icon, pictures_ok := site_mark_animation_pictures()
	testing.expect(t, pictures_ok)
	sheets := [?]struct {
		file_name: string,
		picture:   Site_Mark_Picture,
	}{{SITE_MARK_ANIMATION_HOME, home_dark}, {SITE_MARK_ANIMATION_HOME_LIGHT, home_light}, {SITE_MARK_ANIMATION_ICON, icon}}
	for sheet in sheets {
		still_file, encoded := site_mark_encode(sheet.picture)
		testing.expect(t, encoded)
		still_image, still_error := png.load_from_bytes(still_file, allocator = context.temp_allocator)
		sheet_image, sheet_error := png.load_from_bytes(files[strings.concatenate({SITE_PICTURE_FOLDER, "/", sheet.file_name}, context.temp_allocator)], allocator = context.temp_allocator)
		if still_error != nil || sheet_error != nil {
			testing.expectf(t, false, "%s or its still picture does not decode", sheet.file_name)
			continue
		}
		testing.expect_value(t, sheet_image.height, still_image.height)
		testing.expect_value(t, sheet_image.channels, still_image.channels)
		testing.expect(t, sheet_image.width % still_image.width == 0)
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
	// The still heron, 14 frames of the five first animations, 4 poses of the
	// preen and 3 of the scratch. A sprite of the home is 198 pixels wide, so
	// the home sheets are 4356 pixels wide: one row, under the 8192 pixels
	// that a browser decodes in a picture.
	testing.expect_value(t, len(sprites.cells), 22)
	home, _, _, _ := site_mark_animation_pictures()
	sprite_width, _ := site_mark_size(home)
	testing.expect(t, sprite_width * len(sprites.cells) <= 8192)
	for animation in mark.Animation {
		testing.expect_value(t, len(sprites.of_frame[animation]), mark.animation_frame_count(animation))
	}
}

// The table in the script is JSON with the counts of support/mark.
@(test)
site_mark_animation_table_parses :: proc(t: ^testing.T) {
	sprites, ok := site_mark_sprites()
	home, _, _, pictures_ok := site_mark_animation_pictures()
	testing.expect(t, ok && pictures_ok)
	table := site_mark_animation_table_json(&sprites, home)
	value, err := json.parse_string(table, .JSON, false, context.temp_allocator)
	root, is_object := value.(json.Object)
	testing.expectf(t, err == .None && is_object, "the table does not parse: %v", err)
	if !is_object {
		return
	}
	count, _ := root["sprites"].(json.Float) // parse_string with no integers: each number is a float.
	testing.expect_value(t, int(count), len(sprites.cells))
	animations, _ := root["animations"].(json.Array)
	testing.expect_value(t, len(animations), len(mark.Animation))
	order, _ := root["order"].(json.Array)
	testing.expect_value(t, len(order), len(mark.play_order))
	script := site_mark_animation_script(&sprites, home)
	testing.expect(t, !strings.contains(script, "/*TABLE*/"))
	testing.expect(t, strings.contains(script, "mark animation self test: "))
}
