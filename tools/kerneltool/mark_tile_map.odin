// The tile map of the animations of the mark, a part of the generator of
// the pictures of the mark (mark_pictures.odin; docs/TOOLS.md, "The
// pictures of the mark"). A tile map is one picture that holds a tile for
// each distinct frame of its animations and, under them, a tile for each
// drawn form of their moves. Its table says where each tile is, how long
// each picture of an animation stays, and how the heron moves, in whole
// cells. A script that plays the animations copies tiles and places them:
// it computes no picture.
//
// The rule of the animations and of the moves is the data of src/library/support/mark
// (animation.odin, motion.odin). Also here: the row of the drawn forms of
// the picture for a developer.
package kerneltool

import "core:fmt"
import "core:strings"
import "support:graphics"
import "support:mark"

// One step of the play of an animation on the home: one picture for a
// time. The picture is the sprite of a frame, or a drawn form of that
// frame above the water of the sprite.
Site_Mark_Play_Step :: struct {
	milliseconds: int, // How long the picture stays.
	sprite:       int, // The sprite of the frame: its water, and its heron when form is -1.
	form:         int, // The drawn form of the heron above the water, or -1: the sprite itself.
}

// The drawn forms of all the moves. Two steps with the same cells are one
// drawing.
Site_Mark_Forms :: struct {
	drawn: [dynamic]mark.Form_Cells, // The distinct drawings.
	forms: [dynamic]mark.Form, // For each drawing, the form that it is.
	steps: [mark.Animation][]Site_Mark_Play_Step, // For each animation, its steps in the order of play.
}

// site_mark_forms gives the steps of each animation and the drawings that
// they show. The steps of an animation change where a frame starts and
// where a key of its move gives another form; two steps that follow each
// other with the same picture are one step. An animation whose frames are
// not among the sprites has no step. Without the forms, each step shows
// the sprite of its frame: for a place that shows no move, as the icon of
// a tab.
site_mark_forms :: proc(sprites: ^Site_Mark_Sprites, with_forms := true) -> (forms: Site_Mark_Forms, ok: bool) {
	forms.drawn = make([dynamic]mark.Form_Cells, context.temp_allocator)
	forms.forms = make([dynamic]mark.Form, context.temp_allocator)
	for animation in mark.Animation {
		if len(sprites.of_frame[animation]) == 0 {
			continue
		}
		duration := mark.animation_duration(animation)
		steps := make([dynamic]Site_Mark_Play_Step, context.temp_allocator)
		frame := 1
		frame_start := 0
		at := 0
		for at < duration {
			row, row_found := mark.animation_frame(animation, frame)
			if !row_found {
				fmt.eprintfln("kerneltool: the animation %s of the mark has no frame %d", mark.animation_names[animation], frame)
				return {}, false
			}
			frame_end := frame_start + int(row.duration_milliseconds)
			// The next time where the picture can change: the end of the
			// frame, or the next key of the move.
			change := min(frame_end, duration)
			for key in mark.move_keys {
				if key.animation == animation && key.at_milliseconds > at && key.at_milliseconds < change {
					change = key.at_milliseconds
				}
			}
			pose := mark.move_pose(animation, at, mark.Move_Travel{})
			step := Site_Mark_Play_Step {
				milliseconds = change - at,
				sprite       = sprites.of_frame[animation][frame - 1],
				form         = -1,
			}
			if with_forms && pose.form != .Natural {
				drawn, drawn_found := mark.form_cells(pose.form, animation, frame)
				if !drawn_found {
					fmt.eprintfln("kerneltool: the frame %d of the animation %s of the mark has no form %s", frame, mark.animation_names[animation], mark.form_names[pose.form])
					return {}, false
				}
				for known, index in forms.drawn {
					if known == drawn {
						step.form = index
						break
					}
				}
				if step.form < 0 {
					step.form = len(forms.drawn)
					append(&forms.drawn, drawn)
					append(&forms.forms, pose.form)
				}
			}
			if count := len(steps); count > 0 && steps[count - 1].sprite == step.sprite && steps[count - 1].form == step.form {
				steps[count - 1].milliseconds += step.milliseconds
			} else {
				append(&steps, step)
			}
			at = change
			if at >= frame_end {
				frame += 1
				frame_start = frame_end
			}
		}
		forms.steps[animation] = steps[:]
	}
	return forms, true
}

// The box of a drawn form in a sheet, in cells: the natural heron above
// the water, with the room that the forms take at its left, at its right
// and above it. Each drawing is in such a box, so the script places each
// one in the same way.
MARK_FORM_BOX_COLUMNS :: mark.FORM_REACH_LEFT + mark.BODY_COLUMNS + mark.FORM_REACH_RIGHT
MARK_FORM_BOX_ROWS :: mark.BODY_ROWS + mark.FORM_REACH_UP
#assert(MARK_FORM_BOX_COLUMNS == mark.FORM_COLUMNS_MOST)
#assert(MARK_FORM_BOX_ROWS == mark.FORM_ROWS_MOST)

// Where the sprites of the frames and the drawings of the forms are in a
// sheet, in pixels. The frames are at the top, in rows; the forms are
// under them, in rows of their own box.
Site_Mark_Sheet_Layout :: struct {
	width:         int, // The sheet.
	height:        int,
	sprite_width:  int, // One sprite of a frame.
	sprite_height: int,
	sprite_columns: int, // The sprites in one row.
	form_width:    int, // One drawing of a form.
	form_height:   int,
	form_columns:  int, // The drawings in one row.
	form_top:      int, // The first row of pixels of the drawings.
}

// The sprites of a tile map are in rows of this many when no width is
// asked: one row of all the sprites at 8 pixels for a cell is wider than a
// browser decodes in a picture.
MARK_TILE_MAP_COLUMNS :: 16

// site_mark_sheet_shape gives the count of the columns and of the rows of
// a sheet of a count of sprites, in rows of at most columns_most.
site_mark_sheet_shape :: proc(sprite_count: int, columns_most := MARK_TILE_MAP_COLUMNS) -> (columns, rows: int) {
	columns = max(1, min(sprite_count, columns_most))
	rows = (sprite_count + columns - 1) / columns
	return
}

// site_mark_sheet_layout gives the layout of a sheet of a picture of the
// mark, for a count of sprites and a count of drawn forms (0: a sheet with
// no form, as the sheet of the icon), with rows of at most width_most
// pixels (0: rows of MARK_TILE_MAP_COLUMNS sprites).
site_mark_sheet_layout :: proc(picture: Mark_Picture, sprite_count, form_count: int, width_most := 0) -> (layout: Site_Mark_Sheet_Layout) {
	layout.sprite_width, layout.sprite_height = mark_picture_size(picture)
	columns_most := MARK_TILE_MAP_COLUMNS
	if width_most > 0 {
		columns_most = max(1, width_most / layout.sprite_width)
	}
	columns, rows := site_mark_sheet_shape(sprite_count, columns_most)
	layout.sprite_columns = columns_most
	layout.width = layout.sprite_width * columns
	layout.height = layout.sprite_height * rows
	layout.form_top = layout.height
	layout.form_width = MARK_FORM_BOX_COLUMNS * picture.heron_cell
	layout.form_height = MARK_FORM_BOX_ROWS * picture.heron_cell
	layout.form_columns = 1
	if form_count > 0 {
		layout.width = max(layout.width, layout.form_width)
		layout.form_columns = layout.width / layout.form_width
		if width_most > 0 {
			layout.form_columns = max(1, width_most / layout.form_width)
			layout.width = max(layout.width, layout.form_width * min(form_count, layout.form_columns))
		}
		layout.height += layout.form_height * ((form_count + layout.form_columns - 1) / layout.form_columns)
	}
	return
}

// site_mark_form_pixels draws one form in its box, in the colors of a
// picture of the mark: four bytes for each pixel, by row.
site_mark_form_pixels :: proc(picture: Mark_Picture, drawn: ^mark.Form_Cells) -> []u8 {
	cell := picture.heron_cell
	width := MARK_FORM_BOX_COLUMNS * cell
	height := MARK_FORM_BOX_ROWS * cell
	pixels := make([]u8, width * height * 4, context.temp_allocator)
	for y in 0 ..< height {
		for x in 0 ..< width {
			color, covered := mark.form_cells_pixel(drawn, cell, x - mark.FORM_REACH_LEFT * cell, y - mark.FORM_REACH_UP * cell, picture.variant, picture.on_light)
			if !covered {
				continue // Transparent: the four bytes stay 0.
			}
			pixel := pixels[(y * width + x) * 4:][:4]
			pixel[0] = u8(color >> 16)
			pixel[1] = u8(color >> 8)
			pixel[2] = u8(color)
			pixel[3] = 0xFF
		}
	}
	return pixels
}

// A tile map: how its tiles are drawn, its sprites, its drawn forms and
// the steps of its animations, and where each tile is.
Mark_Tile_Map :: struct {
	picture: Mark_Picture, // How a tile is drawn: the variant, the cell, the color scheme.
	sprites: Site_Mark_Sprites, // The distinct frames.
	forms:   Site_Mark_Forms, // The drawn forms, and the steps of each animation.
	layout:  Site_Mark_Sheet_Layout, // The places of the tiles, in pixels.
}

// mark_tile_map_build gives the tile map of one animation or of all, with
// the drawn forms of the moves or with the frames only, in rows of at most
// width_most pixels (0: rows of MARK_TILE_MAP_COLUMNS sprites). The caller
// asks mark_request_refusal first, or gives a row of the table of the
// uses.
mark_tile_map_build :: proc(picture: Mark_Picture, has_animation: bool, animation: mark.Animation, with_forms: bool, width_most: int) -> (tile_map: Mark_Tile_Map, ok: bool) {
	tile_map.picture = picture
	tile_map.sprites = site_mark_sprites(has_animation, animation) or_return
	tile_map.forms = site_mark_forms(&tile_map.sprites, with_forms) or_return
	tile_map.layout = site_mark_sheet_layout(picture, len(tile_map.sprites.cells), len(tile_map.forms.drawn), width_most)
	return tile_map, true
}

// mark_tile_map_pixels gives the pixels of a tile map: each sprite drawn
// as the picture of the tile map, from the left, in rows from the top; the
// places after the last sprite are empty. Under the sprites, each drawn
// form in the box of a form. Four bytes for each pixel: a tile map is
// transparent.
mark_tile_map_pixels :: proc(tile_map: ^Mark_Tile_Map) -> (pixels: []u8, width, height, channels: int) {
	layout := tile_map.layout
	channels = 4
	width = layout.width
	height = layout.height
	pixels = make([]u8, width * height * channels, context.temp_allocator)
	for &cells, index in tile_map.sprites.cells {
		sprite := mark_picture_pixels(tile_map.picture, &cells)
		row_bytes := layout.sprite_width * channels
		left := (index % layout.sprite_columns) * layout.sprite_width
		top := (index / layout.sprite_columns) * layout.sprite_height
		for row in 0 ..< layout.sprite_height {
			copy(pixels[((top + row) * width + left) * channels:][:row_bytes], sprite[row * row_bytes:][:row_bytes])
		}
	}
	for &drawn, index in tile_map.forms.drawn {
		form := site_mark_form_pixels(tile_map.picture, &drawn)
		row_bytes := layout.form_width * channels
		left := (index % layout.form_columns) * layout.form_width
		top := layout.form_top + (index / layout.form_columns) * layout.form_height
		for row in 0 ..< layout.form_height {
			copy(pixels[((top + row) * width + left) * channels:][:row_bytes], form[row * row_bytes:][:row_bytes])
		}
	}
	return
}

// mark_tile_map_png gives the PNG file of a tile map, the smallest that
// the encoder writes for its pixels.
mark_tile_map_png :: proc(tile_map: ^Mark_Tile_Map) -> (file: []u8, ok: bool) {
	if tile_map.layout.width > MARK_PICTURE_SIDE_MOST || tile_map.layout.height > MARK_PICTURE_SIDE_MOST {
		fmt.eprintfln("kerneltool: the tile map %s of the mark is %d by %d pixels: a side is at most %d; ask for narrower rows", tile_map.picture.file_name, tile_map.layout.width, tile_map.layout.height, MARK_PICTURE_SIDE_MOST)
		return nil, false
	}
	pixels, width, height, channels := mark_tile_map_pixels(tile_map)
	return mark_pixels_png(tile_map.picture.file_name, width, height, channels, pixels)
}

// mark_tile_map_table_fields_write writes the fields of the table of a
// tile map, with no brace around them, so that a caller adds fields of its
// own:
//   sprites, columns: the count of the sprites, and how many are in a row;
//   cells: the count of the cells of a side of the heron;
//   tile: the width and the height of a sprite and the height of the rows
//     of the water at its bottom, in pixels;
//   forms: where the drawn forms are (site_mark_forms_table_write);
//   animations: for each animation of the tile map its name, its time, its
//     frames, each [sprite, milliseconds], the steps of its play and, when
//     it moves, the keys of its move (site_mark_animation_play_write).
// Each number comes from src/library/support/mark or from the layout: a script that
// reads the table holds no number of the mark of its own.
mark_tile_map_table_fields_write :: proc(b: ^strings.Builder, tile_map: ^Mark_Tile_Map) {
	layout := tile_map.layout
	// The braces are written as text, never through a format of fmt.
	fmt.sbprintf(b, "\"sprites\":%d,\"columns\":%d,\"cells\":%d,\"tile\":", len(tile_map.sprites.cells), layout.sprite_columns, mark.HERON_GRID_SIZE)
	strings.write_string(b, "{")
	fmt.sbprintf(b, "\"width\":%d,\"height\":%d,\"water\":%d", layout.sprite_width, layout.sprite_height, mark.WATER_ROWS * tile_map.picture.heron_cell)
	strings.write_string(b, "},\"forms\":")
	site_mark_forms_table_write(b, tile_map.picture, &tile_map.forms, layout)
	strings.write_string(b, ",\"animations\":[")
	first_animation := true
	for animation in mark.Animation {
		frames := tile_map.sprites.of_frame[animation]
		if len(frames) == 0 {
			continue
		}
		if !first_animation {
			strings.write_string(b, ",")
		}
		first_animation = false
		strings.write_string(b, "{\"name\":")
		site_json_string(b, mark.animation_names[animation])
		fmt.sbprintf(b, ",\"duration\":%d,\"frames\":[", mark.animation_duration(animation))
		for sprite, frame_index in frames {
			row, _ := mark.animation_frame(animation, frame_index + 1)
			if frame_index > 0 {
				strings.write_string(b, ",")
			}
			fmt.sbprintf(b, "[%d,%d]", sprite, int(row.duration_milliseconds))
		}
		strings.write_string(b, "]")
		site_mark_animation_play_write(b, animation, &tile_map.forms)
		strings.write_string(b, "}")
	}
	strings.write_string(b, "]")
}

// The distinct frames of the animations of a tile map. Two frames with the
// same cells (a frame of an animation that is the still heron again, a pose
// that an animation takes two times) are one sprite.
Site_Mark_Sprites :: struct {
	cells:    [dynamic]mark.Heron_Cells, // The first is the still heron.
	of_frame: [mark.Animation][]int, // For each animation of the tile map, the sprite of its frames 1, 2, ...; none for the others.
}

// site_mark_sprites gives the sprites of every animation, or of one.
site_mark_sprites :: proc(has_animation := false, only := mark.Animation.Blink) -> (sprites: Site_Mark_Sprites, ok: bool) {
	sprites.cells = make([dynamic]mark.Heron_Cells, context.temp_allocator)
	append(&sprites.cells, mark.still_cells())
	for animation in mark.Animation {
		if has_animation && animation != only {
			continue
		}
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

// site_mark_move_fault_text gives the sentence of a fault of the keys of
// the moves, or "" for a table with no fault.
site_mark_move_fault_text :: proc(table: []mark.Move_Key) -> string {
	fault, animation, at := mark.move_keys_fault(table)
	what: string
	switch fault {
	case .None:
		return ""
	case .Times:
		what = "the keys do not go from 0 to the end of the animation, each later than the one before"
	case .Ends:
		what = "the first or the last key is not the natural heron in its place"
	case .Two_Ways:
		what = "the way to this key goes to the right and upward at once"
	case .Edge:
		what = "a key past the right edge must hold, and the next one must be past the left edge"
	case .Foot_In_Water:
		what = "the key moves the heron while a foot is in the water"
	case .Foot_Not_Above_Leg:
		what = "the form of the key leaves out the last row of a frame with a foot in the water"
	}
	return fmt.tprintf("the move of %s, the key at %d ms: %s", mark.animation_names[animation], at, what)
}

// site_mark_forms_table_write writes the part of the table of the script
// that says where the drawn forms are in a sheet of the home, in pixels:
//   count, columns: the drawings, and how many are in one row;
//   top: the first row of pixels of the drawings in the sheet;
//   width, height: the box of one drawing;
//   left, up: where the natural heron is in that box;
//   reachLeft, reachRight: how far a form goes past the natural heron, in
//     cells: the dash goes that much farther to be outside the window.
site_mark_forms_table_write :: proc(b: ^strings.Builder, home: Mark_Picture, forms: ^Site_Mark_Forms, layout: Site_Mark_Sheet_Layout) {
	names := [9]string{"count", "columns", "top", "width", "height", "left", "up", "reachLeft", "reachRight"}
	values := [9]int {
		len(forms.drawn),
		layout.form_columns,
		layout.form_top,
		layout.form_width,
		layout.form_height,
		mark.FORM_REACH_LEFT * home.heron_cell,
		mark.FORM_REACH_UP * home.heron_cell,
		mark.FORM_REACH_LEFT,
		mark.FORM_REACH_RIGHT,
	}
	// The braces are written as text, never through a format of fmt.
	strings.write_string(b, "{")
	for name, index in names {
		if index > 0 {
			strings.write_string(b, ",")
		}
		site_json_string(b, name)
		fmt.sbprintf(b, ":%d", values[index])
	}
	strings.write_string(b, "}")
}

// site_mark_animation_play_write writes, for one animation, what the
// script plays:
//   steps: each [milliseconds, sprite, form], the form -1 for the sprite
//     itself;
//   motion, when the animation moves: the keys of its move, each
//     [milliseconds, cells to the right, cells up, edge, pace]. Each number
//     is a whole number: a place is a count of cells.
site_mark_animation_play_write :: proc(b: ^strings.Builder, animation: mark.Animation, forms: ^Site_Mark_Forms) {
	strings.write_string(b, ",\"steps\":[")
	for step, index in forms.steps[animation] {
		if index > 0 {
			strings.write_string(b, ",")
		}
		fmt.sbprintf(b, "[%d,%d,%d]", step.milliseconds, step.sprite, step.form)
	}
	strings.write_string(b, "]")
	if !mark.animation_moves(animation) {
		return
	}
	strings.write_string(b, ",\"motion\":[")
	first := true
	for key in mark.move_keys {
		if key.animation != animation {
			continue
		}
		if !first {
			strings.write_string(b, ",")
		}
		first = false
		fmt.sbprintf(b, "[%d,%d,%d,%d,%d]", key.at_milliseconds, key.cells_right, key.cells_up, int(key.edge), int(key.pace))
	}
	strings.write_string(b, "]")
}

// The picture of the forms for a developer, a part of the picture that
// `kerneltool logo` writes: under the frames of an animation that moves,
// each drawing that its move shows, at the cells of the frames, in the box
// of a form with the water of its frame under it.
MARK_ANIMATIONS_CHARACTER_WIDTH :: 8 // The font of the picture, 8 by 16.
MARK_ANIMATIONS_FORM_BOX_WIDTH :: MARK_FORM_BOX_COLUMNS * MARK_ANIMATIONS_CELL_SIZE
MARK_ANIMATIONS_FORM_BOX_HEIGHT :: (MARK_FORM_BOX_ROWS + mark.WATER_ROWS) * MARK_ANIMATIONS_CELL_SIZE

// mark_animation_forms_height gives the height of the row of the forms of
// an animation in the picture: 0 for an animation that does not move.
mark_animation_forms_height :: proc(animation: mark.Animation) -> int {
	if !mark.animation_moves(animation) {
		return 0
	}
	// A heading, the boxes, two lines of text under each box.
	return MARK_ANIMATIONS_LINE + MARK_ANIMATIONS_FORM_BOX_HEIGHT + 2 * MARK_ANIMATIONS_LINE + MARK_ANIMATIONS_GAP
}

// mark_animation_forms_width gives the width of the widest row of forms.
mark_animation_forms_width :: proc(forms: ^Site_Mark_Forms) -> int {
	most := 0
	for animation in mark.Animation {
		count := 0
		for step in forms.steps[animation] {
			if step.form >= 0 {
				count += 1
			}
		}
		most = max(most, count)
	}
	return most * (MARK_ANIMATIONS_FORM_BOX_WIDTH + MARK_ANIMATIONS_GAP)
}

// mark_animation_forms_draw draws the row of the forms of an animation at
// (x, y) of the picture: each step of its play that shows a drawn form,
// in the order of play, with the time of the step, the name and the size
// of the form, and how the form was drawn.
mark_animation_forms_draw :: proc(canvas: graphics.Canvas, x, y: int, animation: mark.Animation, sprites: ^Site_Mark_Sprites, forms: ^Site_Mark_Forms) {
	cell := MARK_ANIMATIONS_CELL_SIZE
	graphics.text(canvas, x, y, fmt.tprintf("the forms of the move of %s: whole cells; the standing leg and the water keep their place", mark.animation_names[animation]), graphics.COLOR_DIM)
	box_x := x
	at := 0
	for step in forms.steps[animation] {
		start := at
		at += step.milliseconds
		if step.form < 0 {
			continue
		}
		drawn := &forms.drawn[step.form]
		box_y := y + MARK_ANIMATIONS_LINE
		graphics.fill(canvas, box_x, box_y, MARK_ANIMATIONS_FORM_BOX_WIDTH, MARK_ANIMATIONS_FORM_BOX_HEIGHT, graphics.COLOR_CARD_TOP)
		// The place of the natural heron in the box.
		heron_x := box_x + mark.FORM_REACH_LEFT * cell
		heron_y := box_y + mark.FORM_REACH_UP * cell
		// The water of the frame: a view of the picture that holds its two
		// rows only, so that the frame draws nothing above them.
		water_y := heron_y + mark.BODY_ROWS * cell
		water := graphics.Canvas {
			pixels = canvas.pixels[water_y * canvas.stride + heron_x:],
			width  = mark.heron_size(cell),
			height = mark.WATER_ROWS * cell,
			stride = canvas.stride,
		}
		mark.cells_draw(water, &sprites.cells[step.sprite], 0, -mark.BODY_ROWS * cell, cell, .Smooth, false)
		mark.form_cells_draw(canvas, drawn, heron_x, heron_y, cell, .Smooth, false)
		origin := "the frame"
		switch mark.form_origin(forms.forms[step.form]) {
		case .Frame:
		case .Lines:
			origin = "lines"
		case .Corrected:
			origin = "lines, corrected"
		}
		// Two lines under the box: one line of the whole text is wider than
		// the box, and it would lie over the text of the next box.
		caption := [2]string {
			fmt.tprintf("%d ms: %s, %d by %d", start, mark.form_names[forms.forms[step.form]], drawn.columns, drawn.rows),
			origin,
		}
		for line, index in caption {
			fmt.assertf(len(line) * MARK_ANIMATIONS_CHARACTER_WIDTH <= MARK_ANIMATIONS_FORM_BOX_WIDTH, "the text %q under a form is wider than its box", line)
			graphics.text(canvas, box_x, box_y + MARK_ANIMATIONS_FORM_BOX_HEIGHT + 4 + index * MARK_ANIMATIONS_LINE, line, graphics.COLOR_DIM)
		}
		box_x += MARK_ANIMATIONS_FORM_BOX_WIDTH + MARK_ANIMATIONS_GAP
	}
}
