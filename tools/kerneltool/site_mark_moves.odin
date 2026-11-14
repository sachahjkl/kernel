// The moves of the heron on the home of the site (docs/SITE.md, "The moves
// of the heron"). The rule is the data of support/mark (motion.odin): the
// forms of the heron, drawn in whole cells, and the keys of each move, in
// whole cells. The site holds no rule of its own. The tool draws each form
// that a move takes into the sprite sheets of the home, as it draws the
// frames, and writes for each animation the list of what the script shows
// and for how long. The script shows pictures of cells and places them at
// whole cells: it scales nothing.
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
// other with the same picture are one step.
site_mark_forms :: proc(sprites: ^Site_Mark_Sprites) -> (forms: Site_Mark_Forms, ok: bool) {
	forms.drawn = make([dynamic]mark.Form_Cells, context.temp_allocator)
	forms.forms = make([dynamic]mark.Form, context.temp_allocator)
	for animation in mark.Animation {
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
			if pose.form != .Natural {
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
SITE_MARK_FORM_BOX_COLUMNS :: mark.FORM_REACH_LEFT + mark.BODY_COLUMNS + mark.FORM_REACH_RIGHT
SITE_MARK_FORM_BOX_ROWS :: mark.BODY_ROWS + mark.FORM_REACH_UP
#assert(SITE_MARK_FORM_BOX_COLUMNS == mark.FORM_COLUMNS_MOST)
#assert(SITE_MARK_FORM_BOX_ROWS == mark.FORM_ROWS_MOST)

// Where the sprites of the frames and the drawings of the forms are in a
// sheet, in pixels. The frames are at the top, in rows; the forms are
// under them, in rows of their own box.
Site_Mark_Sheet_Layout :: struct {
	width:         int, // The sheet.
	height:        int,
	sprite_width:  int, // One sprite of a frame.
	sprite_height: int,
	form_width:    int, // One drawing of a form.
	form_height:   int,
	form_columns:  int, // The drawings in one row.
	form_top:      int, // The first row of pixels of the drawings.
}

// site_mark_sheet_layout gives the layout of a sheet of a picture of the
// mark, for a count of sprites and a count of drawn forms (0: a sheet with
// no form, as the sheet of the icon).
site_mark_sheet_layout :: proc(picture: Site_Mark_Picture, sprite_count, form_count: int) -> (layout: Site_Mark_Sheet_Layout) {
	layout.sprite_width, layout.sprite_height = site_mark_size(picture)
	columns, rows := site_mark_sheet_shape(sprite_count)
	layout.width = layout.sprite_width * columns
	layout.height = layout.sprite_height * rows
	layout.form_top = layout.height
	layout.form_width = SITE_MARK_FORM_BOX_COLUMNS * picture.heron_cell
	layout.form_height = SITE_MARK_FORM_BOX_ROWS * picture.heron_cell
	layout.form_columns = 1
	if form_count > 0 {
		layout.width = max(layout.width, layout.form_width)
		layout.form_columns = layout.width / layout.form_width
		layout.height += layout.form_height * ((form_count + layout.form_columns - 1) / layout.form_columns)
	}
	return
}

// site_mark_form_pixels draws one form in its box, in the colors of a
// picture of the mark: four bytes for each pixel, by row.
site_mark_form_pixels :: proc(picture: Site_Mark_Picture, drawn: ^mark.Form_Cells) -> []u8 {
	cell := picture.heron_cell
	width := SITE_MARK_FORM_BOX_COLUMNS * cell
	height := SITE_MARK_FORM_BOX_ROWS * cell
	pixels := make([]u8, width * height * 4, context.temp_allocator)
	for y in 0 ..< height {
		for x in 0 ..< width {
			color, covered := mark.form_cells_pixel(drawn, cell, x - mark.FORM_REACH_LEFT * cell, y - mark.FORM_REACH_UP * cell, picture.on_light)
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
site_mark_forms_table_write :: proc(b: ^strings.Builder, home: Site_Mark_Picture, forms: ^Site_Mark_Forms, sprite_count: int) {
	layout := site_mark_sheet_layout(home, sprite_count, len(forms.drawn))
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
MARK_ANIMATIONS_FORM_BOX_WIDTH :: SITE_MARK_FORM_BOX_COLUMNS * MARK_ANIMATIONS_CELL_SIZE
MARK_ANIMATIONS_FORM_BOX_HEIGHT :: (SITE_MARK_FORM_BOX_ROWS + mark.WATER_ROWS) * MARK_ANIMATIONS_CELL_SIZE

// mark_animation_forms_height gives the height of the row of the forms of
// an animation in the picture: 0 for an animation that does not move.
mark_animation_forms_height :: proc(animation: mark.Animation) -> int {
	if !mark.animation_moves(animation) {
		return 0
	}
	return MARK_ANIMATIONS_LINE + MARK_ANIMATIONS_FORM_BOX_HEIGHT + MARK_ANIMATIONS_LINE + MARK_ANIMATIONS_GAP
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
		mark.cells_draw(water, &sprites.cells[step.sprite], 0, -mark.BODY_ROWS * cell, cell, false)
		mark.form_cells_draw(canvas, drawn, heron_x, heron_y, cell, false)
		origin := "the frame"
		switch mark.form_origin(forms.forms[step.form]) {
		case .Frame:
		case .Lines:
			origin = "lines"
		case .Corrected:
			origin = "lines, corrected"
		}
		caption := fmt.tprintf("%d ms: %s, %d by %d, %s", start, mark.form_names[forms.forms[step.form]], drawn.columns, drawn.rows, origin)
		graphics.text(canvas, box_x, box_y + MARK_ANIMATIONS_FORM_BOX_HEIGHT + 4, caption, graphics.COLOR_DIM)
		box_x += MARK_ANIMATIONS_FORM_BOX_WIDTH + MARK_ANIMATIONS_GAP
	}
}
