#+build !freestanding
package mark

import "core:log"
import "core:testing"
import "modus:support/graphics"

// The forms that the keys of the moves use, each with a frame that plays
// while its key holds: what a place that plays the moves draws.
@(private = "file")
Used_Form :: struct {
	animation: Animation,
	frame:     int,
	form:      Form,
}

// used_forms gives each form with each frame that plays during a key of
// that form, once.
@(private = "file")
used_forms :: proc() -> [dynamic]Used_Form {
	used := make([dynamic]Used_Form, context.temp_allocator)
	for key, index in move_keys {
		// The time of the key, and of the next key of its animation.
		until := animation_duration(key.animation)
		if index + 1 < len(move_keys) && move_keys[index + 1].animation == key.animation {
			until = move_keys[index + 1].at_milliseconds
		}
		start := 0
		for frame in 1 ..= animation_frame_count(key.animation) {
			row, _ := animation_frame(key.animation, frame)
			end := start + int(row.duration_milliseconds)
			if start < until && end > key.at_milliseconds {
				entry := Used_Form{key.animation, animation_pose_frame(key.animation, frame), key.form}
				known := false
				for other in used {
					if other == entry {
						known = true
					}
				}
				if !known {
					append(&used, entry)
				}
			}
			start = end
		}
	}
	return used
}

// The size of each form, and where it is around the natural heron. The
// column of the standing leg is at its place in every form, and the last
// row of every form is on the line of the water. The bounds of the forms
// are reached, and no form passes them.
@(test)
forms_have_their_sizes_and_keep_the_standing_leg :: proc(t: ^testing.T) {
	Size :: struct {
		columns, rows, first_column: int,
	}
	sizes := [Form]Size {
		.Natural   = {24, 22, 0},
		.Gather    = {26, 21, -1},
		.Crouch    = {28, 19, -2},
		.Run       = {32, 20, -6},
		.Brake     = {20, 23, 4},
		.Slide     = {22, 21, 2},
		.Rebound   = {26, 20, -1},
		.Tall      = {22, 24, 2},
		.Thin      = {22, 23, 2},
		.Neck      = {24, 24, 0},
		.Long_Neck = {24, 26, 0},
	}
	reach_left, reach_right, reach_up, columns_most, rows_most := 0, 0, 0, 0, 0
	for form in Form {
		columns, rows := form_size(form)
		testing.expectf(t, columns == sizes[form].columns && rows == sizes[form].rows, "%v is %d by %d cells", form, columns, rows)
		testing.expect_value(t, form_first_column(form), sizes[form].first_column)
		testing.expect_value(t, form_first_row(form), BODY_ROWS - rows)
		testing.expectf(t, form_names[form] != "", "%v has no name", form)
		lines := form_lines[form]
		testing.expectf(t, card(lines.columns_twice & lines.columns_out) == 0, "%v draws a column two times and leaves it out", form)
		testing.expectf(t, card(lines.rows_twice & lines.rows_out) == 0, "%v draws a row two times and leaves it out", form)
		// The standing leg, the head, the beak and the crest are never
		// drawn two times and never left out.
		for column in 0 ..< BODY_COLUMNS {
			changed := column in lines.columns_twice || column in lines.columns_out
			testing.expectf(t, !changed || (column != STANDING_LEG_COLUMN && column < HEAD_FIRST_COLUMN), "%v changes the column %d", form, column)
		}
		for row in 0 ..< HERON_GRID_SIZE {
			changed := row in lines.rows_twice || row in lines.rows_out
			testing.expectf(t, !changed || (row > HEAD_LAST_ROW && row < BODY_ROWS), "%v changes the row %d", form, row)
		}
		// Each column and each row of the form shows a line of the frame,
		// in the order of the frame, and the next one past the form shows
		// none.
		previous := -1
		for column in 0 ..< columns {
			source, found := form_source_column(form, column)
			testing.expectf(t, found && source >= previous && source < BODY_COLUMNS, "%v: the column %d shows the column %d", form, column, source)
			previous = source
			if source == STANDING_LEG_COLUMN {
				testing.expectf(t, column + form_first_column(form) == STANDING_LEG_COLUMN, "%v: the standing leg is at the column %d of the grid", form, column + form_first_column(form))
			}
		}
		_, past_columns := form_source_column(form, columns)
		_, before_columns := form_source_column(form, -1)
		testing.expect(t, !past_columns && !before_columns)
		previous = -1
		for row in 0 ..< rows {
			source, found := form_source_row(form, row)
			testing.expectf(t, found && source >= previous && source < BODY_ROWS, "%v: the row %d shows the row %d", form, row, source)
			previous = source
		}
		_, past_rows := form_source_row(form, rows)
		testing.expect(t, !past_rows)
		reach_left = max(reach_left, -form_first_column(form))
		reach_right = max(reach_right, form_first_column(form) + columns - BODY_COLUMNS)
		reach_up = max(reach_up, rows - BODY_ROWS)
		columns_most = max(columns_most, columns)
		rows_most = max(rows_most, rows)
	}
	testing.expect_value(t, reach_left, FORM_REACH_LEFT)
	testing.expect_value(t, reach_right, FORM_REACH_RIGHT)
	testing.expect_value(t, reach_up, FORM_REACH_UP)
	testing.expect_value(t, columns_most, FORM_COLUMNS_MOST)
	testing.expect_value(t, rows_most, FORM_ROWS_MOST)
	testing.expect_value(t, FORM_REACH_LEFT + BODY_COLUMNS + FORM_REACH_RIGHT, FORM_COLUMNS_MOST)
	testing.expect_value(t, form_origin(.Natural), Form_Origin.Frame)
	testing.expect_value(t, form_origin(.Gather), Form_Origin.Lines)
	testing.expect_value(t, form_origin(.Crouch), Form_Origin.Corrected)
	testing.expect_value(t, form_origin(.Run), Form_Origin.Corrected)
	testing.expect_value(t, form_origin(.Brake), Form_Origin.Lines)
}

// count_letter gives the count of the cells of one letter in the part of a
// frame above the water.
@(private = "file")
count_letter_of_frame :: proc(cells: ^Heron_Cells, letter: u8) -> int {
	count := 0
	for row in 0 ..< BODY_ROWS {
		for column in 0 ..< BODY_COLUMNS {
			if cells[row][column] == letter {
				count += 1
			}
		}
	}
	return count
}

@(private = "file")
count_letter_of_form :: proc(drawn: ^Form_Cells, letter: u8) -> int {
	count := 0
	for row in 0 ..< FORM_ROWS_MOST {
		for column in 0 ..< FORM_COLUMNS_MOST {
			if drawn.cells[row][column] == letter {
				count += 1
			}
		}
	}
	return count
}

// longest_leg_run gives the longest count of cells of a leg side by side
// in one row.
@(private = "file")
longest_leg_run_of_form :: proc(drawn: ^Form_Cells) -> int {
	longest := 0
	for row in 0 ..< drawn.rows {
		run := 0
		for column in 0 ..< drawn.columns {
			run = run + 1 if drawn.cells[row][column] == 'o' else 0
			longest = max(longest, run)
		}
	}
	return longest
}

@(private = "file")
longest_leg_run_of_frame :: proc(cells: ^Heron_Cells) -> int {
	longest := 0
	for row in 0 ..< BODY_ROWS {
		run := 0
		for column in 0 ..< BODY_COLUMNS {
			run = run + 1 if cells[row][column] == 'o' else 0
			longest = max(longest, run)
		}
	}
	return longest
}

// Each form that a move draws, with each frame that it draws it for: the
// eye is one cell where the frame has an eye, the beak and the crest have
// the cells of the frame, the head is the head of the frame cell for cell,
// no leg is wider than in the frame, and no cell is outside the form. The
// log holds each drawing as text, for a reader to look at.
@(test)
drawn_forms_keep_the_eye_the_beak_and_the_legs :: proc(t: ^testing.T) {
	used := used_forms()
	testing.expect(t, len(used) >= 19)
	for entry in used {
		cells, cells_found := animation_frame_cells(entry.animation, entry.frame)
		drawn, found := form_cells(entry.form, entry.animation, entry.frame)
		testing.expect(t, cells_found && found)
		if !found {
			continue
		}
		log.infof("%s frame %d as %s: %d by %d cells, the first column at %d of the grid, %v", animation_names[entry.animation], entry.frame, form_names[entry.form], drawn.columns, drawn.rows, drawn.first_column, form_origin(entry.form))
		for row in 0 ..< drawn.rows {
			log.info(string(drawn.cells[row][:drawn.columns]))
		}
		testing.expectf(t, count_letter_of_form(&drawn, 'k') == count_letter_of_frame(&cells, 'k'), "%v frame %d as %v: the eye", entry.animation, entry.frame, entry.form)
		testing.expectf(t, count_letter_of_form(&drawn, 'y') == count_letter_of_frame(&cells, 'y'), "%v frame %d as %v: the beak", entry.animation, entry.frame, entry.form)
		// The head: each cell from the first column of the head, in the
		// rows of the head, is the cell of the frame. A column of the head
		// is in the form once; the columns of the head follow each other.
		head_start := -1
		for column in 0 ..< drawn.columns {
			if source, _ := form_source_column(entry.form, column); source == HEAD_FIRST_COLUMN {
				head_start = column
			}
		}
		testing.expect_value(t, head_start + BODY_COLUMNS - HEAD_FIRST_COLUMN, drawn.columns)
		for row in 0 ..= HEAD_LAST_ROW {
			for column in HEAD_FIRST_COLUMN ..< BODY_COLUMNS {
				in_form := head_start + column - HEAD_FIRST_COLUMN
				testing.expectf(t, in_form >= 0 && in_form < drawn.columns && drawn.cells[row][in_form] == cells[row][column], "%v frame %d as %v: the cell %d, %d of the head", entry.animation, entry.frame, entry.form, column, row)
			}
		}
		// The tip of the beak is the last cell of its row.
		tip := drawn.columns - 1
		if cells[2][BODY_COLUMNS - 1] == 'y' {
			testing.expect_value(t, drawn.cells[2][tip], u8('y'))
		}
		testing.expectf(t, longest_leg_run_of_form(&drawn) <= longest_leg_run_of_frame(&cells), "%v frame %d as %v: a leg is %d cells wide", entry.animation, entry.frame, entry.form, longest_leg_run_of_form(&drawn))
		// Nothing past the size of the form, and each cell is a part or
		// empty.
		for row in 0 ..< FORM_ROWS_MOST {
			for column in 0 ..< FORM_COLUMNS_MOST {
				letter := drawn.cells[row][column]
				_, is_part := part_of_letter(letter)
				inside := row < drawn.rows && column < drawn.columns
				testing.expectf(t, letter == '.' || (inside && is_part), "%v frame %d as %v: the cell %d, %d holds %c", entry.animation, entry.frame, entry.form, column, row, letter)
			}
		}
		// A frame with a foot in the water: the standing leg comes down to
		// the last row of the form, above its foot.
		if cells_have_foot_in_water(&cells) && cells[BODY_ROWS - 1][STANDING_LEG_COLUMN] == 'o' {
			testing.expectf(t, drawn.cells[drawn.rows - 1][STANDING_LEG_COLUMN - drawn.first_column] == 'o', "%v frame %d as %v: the standing leg does not reach the water", entry.animation, entry.frame, entry.form)
		}
	}
	// The natural form of a frame is the frame.
	still := still_cells()
	natural, _ := form_cells(.Natural, .Blink, 0)
	testing.expect_value(t, natural.columns, BODY_COLUMNS)
	testing.expect_value(t, natural.rows, BODY_ROWS)
	for row in 0 ..< BODY_ROWS {
		for column in 0 ..< BODY_COLUMNS {
			if natural.cells[row][column] != still[row][column] {
				testing.expectf(t, false, "the natural form differs from the still heron at %d, %d", column, row)
				return
			}
		}
	}
	_, missing := form_cells(.Crouch, .Blink, 2)
	testing.expect(t, !missing)
}

// The squash that the wind-up of the dash holds, 28 by 19 cells, cell by
// cell: the eye, the tip of the beak, the crest, the legs, the wider body.
@(test)
crouch_of_the_dash_pinned_cells :: proc(t: ^testing.T) {
	drawn, found := form_cells(.Crouch, .Dash, 1)
	testing.expect(t, found)
	testing.expect_value(t, drawn.columns, 28)
	testing.expect_value(t, drawn.rows, 19)
	testing.expect_value(t, drawn.first_column, -2)
	testing.expect_value(t, drawn.first_row, 3)
	rows := [19]string {
		"..................vv........",
		"...................hhhh.....",
		"..................hhhkhyyyyy",
		"...................hhhhyyy..",
		"...................hh.......",
		"..................hh........",
		".................hh.........",
		"..................hh........",
		"..................hhh.......",
		"........bbbbbbbbbbbhh.......",
		"....bbbbbbbbbbbbbbbbh.......",
		"..vvbbbbbddddddddbbbb.......",
		".vvvbbbbbbddddddbbbb........",
		"vvv..bbbbbbbbbbbbbb.........",
		"...........o....o...........",
		"...........o....o...........",
		"...........o.....o..........",
		"...........o....o...........",
		"...........o....o...........",
	}
	for row, index in rows {
		testing.expectf(t, string(drawn.cells[index][:drawn.columns]) == row, "the row %d is %s", index, string(drawn.cells[index][:drawn.columns]))
	}
	// The run, the legs apart: each leg is one cell wide on its diagonal.
	run, _ := form_cells(.Run, .Dash, 2)
	testing.expect_value(t, string(run.cells[16][:run.columns]), "...............o....o...........")
	testing.expect_value(t, string(run.cells[17][:run.columns]), "..............o......o..........")
	testing.expect_value(t, string(run.cells[18][:run.columns]), ".............o........o.........")
	testing.expect_value(t, string(run.cells[19][:run.columns]), "...........oo..........oo.......")
	testing.expect_value(t, string(run.cells[3][:run.columns]), "........hhhhhhhhhh.....hhhhyyy..")
	// A later step of the run takes the corrections of its pose.
	testing.expect_value(t, animation_pose_frame(.Dash, 14), 2)
	testing.expect_value(t, animation_pose_frame(.Dash, 15), 3)
	testing.expect_value(t, animation_pose_frame(.Dash, 16), 16)
	testing.expect_value(t, animation_pose_frame(.Flap, 4), 2)
	testing.expect_value(t, animation_pose_frame(.Flap, 6), 1)
	later, _ := form_cells(.Run, .Dash, 14)
	testing.expect_value(t, string(later.cells[19][:later.columns]), "...........oo..........oo.......")
	together, _ := form_cells(.Run, .Dash, 15)
	testing.expect_value(t, string(together.cells[18][:together.columns]), "................o..o............")
}

// Each correction is a cell of its form, names a part or an empty cell,
// names a frame that plays in that form, changes its cell, and no two
// corrections set the same cell of the same frame.
@(test)
every_correction_is_a_cell_of_its_form :: proc(t: ^testing.T) {
	used := used_forms()
	for correction, index in form_corrections {
		columns, rows := form_size(correction.form)
		testing.expectf(t, int(correction.column) < columns && int(correction.row) < rows, "correction %d: the cell %d, %d is outside %v", index, correction.column, correction.row, correction.form)
		_, is_part := part_of_letter(correction.letter)
		testing.expectf(t, correction.letter == '.' || is_part, "correction %d: the letter %c is not a part", index, correction.letter)
		applies := 0
		for entry in used {
			if entry.form != correction.form || (correction.frame != 0 && (entry.animation != correction.animation || entry.frame != int(correction.frame))) {
				continue
			}
			applies += 1
			// The cell before the corrections: the lines over the frame.
			cells, _ := animation_frame_cells(entry.animation, entry.frame)
			source_column, _ := form_source_column(correction.form, int(correction.column))
			source_row, _ := form_source_row(correction.form, int(correction.row))
			testing.expectf(t, cells[source_row][source_column] != correction.letter, "correction %d: the cell of %v frame %d has that letter already", index, entry.animation, entry.frame)
		}
		testing.expectf(t, applies > 0, "correction %d: no move draws %v for that frame", index, correction.form)
		for other in form_corrections[index + 1:] {
			same_frame := other.frame == 0 || correction.frame == 0 || (other.animation == correction.animation && other.frame == correction.frame)
			same_cell := other.form == correction.form && other.column == correction.column && other.row == correction.row && same_frame
			testing.expectf(t, !same_cell, "correction %d: the cell %d, %d of %v is corrected two times", index, correction.column, correction.row, correction.form)
		}
	}
}

// The table of the keys has no fault, and a table with a fault is found:
// a key that lifts the heron while its foot is in the water, a dash that
// does not come back, a way to the right and upward at once, a last key
// that is not the natural heron.
@(test)
move_keys_have_no_fault :: proc(t: ^testing.T) {
	fault, animation, at := move_keys_fault(move_keys[:])
	testing.expectf(t, fault == .None, "the keys: %v at %d ms of %v", fault, at, animation)
	moving := 0
	for candidate in Animation {
		if animation_moves(candidate) {
			moving += 1
		}
	}
	// The dash, the hop, the stretch and the flap.
	testing.expect_value(t, moving, 4)
	testing.expect(t, animation_moves(.Dash) && animation_moves(.Hop) && animation_moves(.Stretch) && animation_moves(.Flap))
	// Each fault is made in a copy: the tests run at the same time.
	lifted := move_keys
	for &key in lifted {
		if key.animation == .Hop && key.at_milliseconds == 120 {
			key.cells_up = 1
		}
	}
	fault, _, at = move_keys_fault(lifted[:])
	testing.expect_value(t, fault, Move_Fault.Foot_In_Water)
	testing.expect_value(t, at, 120)
	no_return := move_keys
	for &key in no_return {
		if key.edge == .Past_Left {
			key.edge = .None
		}
	}
	fault, _, _ = move_keys_fault(no_return[:])
	testing.expect_value(t, fault, Move_Fault.Edge)
	two_ways := move_keys
	for &key in two_ways {
		if key.animation == .Hop && key.at_milliseconds == 340 {
			key.cells_right = 2
		}
	}
	fault, _, _ = move_keys_fault(two_ways[:])
	testing.expect_value(t, fault, Move_Fault.Two_Ways)
	not_natural := move_keys
	for &key in not_natural {
		if key.animation == .Flap && key.at_milliseconds == 1000 {
			key.form = .Rebound
		}
	}
	fault, _, _ = move_keys_fault(not_natural[:])
	testing.expect_value(t, fault, Move_Fault.Ends)
	late := move_keys
	for &key in late {
		if key.animation == .Stretch && key.at_milliseconds == 1100 {
			key.at_milliseconds = 1099
		}
	}
	fault, _, _ = move_keys_fault(late[:])
	testing.expect_value(t, fault, Move_Fault.Times)
	// The legs of the run are above the last row: a frame with a foot in
	// the water must not take that form.
	no_last_row := move_keys
	for &key in no_last_row {
		if key.animation == .Stretch && key.at_milliseconds == 100 {
			key.form = .Run
		}
	}
	fault, _, _ = move_keys_fault(no_last_row[:])
	testing.expect_value(t, fault, Move_Fault.Foot_Not_Above_Leg)
}

// The place of the heron at each millisecond of each move is a whole count
// of cells that never goes back on its way between two keys, and the form
// is the form of the last key. Pinned: the dash is 2 cells out at the
// middle of its first step, the hop 2 cells up at the middle of its rise.
@(test)
the_heron_moves_by_whole_cells :: proc(t: ^testing.T) {
	travel := Move_Travel{cells_to_right_edge = 100, cells_to_left_edge = 60}
	for animation in Animation {
		duration := animation_duration(animation)
		if !animation_moves(animation) {
			pose := move_pose(animation, duration / 2, travel)
			testing.expect_value(t, pose, Move_Pose{})
			continue
		}
		previous := move_pose(animation, 0, travel)
		testing.expect_value(t, previous, Move_Pose{})
		jumps := 0
		for at in 1 ..= duration {
			pose := move_pose(animation, at, travel)
			step_right := abs(pose.cells_right - previous.cells_right)
			step_up := abs(pose.cells_up - previous.cells_up)
			// One millisecond is at most a few cells of a way, but for the
			// one jump of the dash from an edge to the other.
			if step_right > 4 {
				jumps += 1
				testing.expect_value(t, step_right, travel.cells_to_right_edge + travel.cells_to_left_edge)
			}
			testing.expectf(t, step_up <= 1, "%v at %d ms: %d cells up in one millisecond", animation, at, step_up)
			previous = pose
		}
		testing.expect_value(t, jumps, 1 if animation == .Dash else 0)
		testing.expect_value(t, previous, Move_Pose{})
		testing.expect_value(t, move_pose(animation, duration + 1000, travel), Move_Pose{})
		testing.expect_value(t, move_pose(animation, -1, travel), Move_Pose{})
	}
	testing.expect_value(t, move_pose(.Dash, 379, travel), Move_Pose{form = .Crouch})
	testing.expect_value(t, move_pose(.Dash, 380, travel), Move_Pose{form = .Run})
	testing.expect_value(t, move_pose(.Dash, 415, travel), Move_Pose{form = .Run, cells_right = 2})
	testing.expect_value(t, move_pose(.Dash, 450, travel), Move_Pose{form = .Run, cells_right = 4})
	testing.expect_value(t, move_pose(.Dash, 730, travel), Move_Pose{form = .Run, cells_right = 100})
	testing.expect_value(t, move_pose(.Dash, 1009, travel), Move_Pose{form = .Run, cells_right = 100})
	testing.expect_value(t, move_pose(.Dash, 1010, travel), Move_Pose{form = .Run, cells_right = -60})
	testing.expect_value(t, move_pose(.Dash, 1360, travel), Move_Pose{form = .Brake, cells_right = 3})
	testing.expect_value(t, move_pose(.Dash, 1520, travel), Move_Pose{form = .Slide, cells_right = 2})
	testing.expect_value(t, move_pose(.Dash, 1580, travel), Move_Pose{form = .Rebound})
	testing.expect_value(t, move_pose(.Hop, 260, travel), Move_Pose{form = .Tall, cells_up = 2})
	testing.expect_value(t, move_pose(.Hop, 340, travel), Move_Pose{form = .Tall, cells_up = 4})
	testing.expect_value(t, move_pose(.Hop, 499, travel), Move_Pose{form = .Tall, cells_up = 1})
	testing.expect_value(t, move_pose(.Flap, 500, travel), Move_Pose{form = .Natural, cells_up = 3})
}

// form_cells_pixel gives the color of the part of each cell at its place,
// and form_cells_draw writes those pixels around the place of the natural
// heron and nothing outside the canvas. The natural form of the still
// heron has the pixels of the mark above the water.
@(test)
form_pixels_are_the_pixels_of_their_cells :: proc(t: ^testing.T) {
	natural, _ := form_cells(.Natural, .Blink, 0)
	for y in 0 ..< BODY_ROWS * 2 {
		for x in 0 ..< BODY_COLUMNS * 2 {
			form_color, form_covered := form_cells_pixel(&natural, 2, x, y, .Smooth, false)
			still_color, still_covered := mark_pixel(2, x, y, .Smooth, false)
			if form_color != still_color || form_covered != still_covered {
				testing.expectf(t, false, "pixel %d, %d of the natural form differs from mark_pixel", x, y)
				return
			}
		}
	}
	_, in_water := form_cells_pixel(&natural, 2, 20, BODY_ROWS * 2, .Smooth, false)
	testing.expect(t, !in_water)
	_, refused := form_cells_pixel(&natural, CELL_SIZE_LIMIT + 1, 0, 0, .Smooth, false)
	testing.expect(t, !refused)
	// The smooth variant is not drawn at one pixel for a cell; the cells
	// variant is, and a cell of a form at the left of the heron has the
	// color of its cell at any cell size.
	_, smooth_at_one := form_cells_pixel(&natural, 1, 14, 0, .Smooth, false)
	testing.expect(t, !smooth_at_one)
	run_form, _ := form_cells(.Run, .Dash, 2)
	tail_cell, tail_cell_covered := form_cells_pixel(&run_form, 1, -6, 17, .Cells, false)
	testing.expect(t, tail_cell_covered)
	for inside in 0 ..< 8 {
		large, large_covered := form_cells_pixel(&run_form, 8, -48 + inside, 17 * 8 + inside, .Cells, false)
		testing.expectf(t, large_covered && large == tail_cell, "the pixel %d of the cell of the tail is 0x%06X, the cell is 0x%06X", inside, large, tail_cell)
	}
	// The run goes 6 cells past the left edge of the heron: the tip of its
	// tail is the first cell of its row 15, which is the row 17 of the
	// grid.
	run, _ := form_cells(.Run, .Dash, 2)
	testing.expect_value(t, run.cells[15][0], u8('v'))
	_, tail := form_cells_pixel(&run, 2, -12, 34, .Smooth, false)
	testing.expect(t, tail)
	_, past_tail := form_cells_pixel(&run, 2, -13, 34, .Smooth, false)
	testing.expect(t, !past_tail)
	SIDE :: 96
	VIEW_LEFT :: 8
	VIEW_SIDE :: 72
	buffer: [SIDE * SIDE]graphics.Color
	for &pixel in buffer {
		pixel = DRAW_TEST_SENTINEL
	}
	view := graphics.Canvas{pixels = ([^]graphics.Color)(&buffer[VIEW_LEFT * SIDE + VIEW_LEFT]), width = VIEW_SIDE, height = VIEW_SIDE, stride = SIDE}
	PLACE_X :: 5
	PLACE_Y :: 9
	form_cells_draw(view, &run, PLACE_X, PLACE_Y, 2, .Smooth, false)
	written := 0
	for y in 0 ..< SIDE {
		for x in 0 ..< SIDE {
			expected := DRAW_TEST_SENTINEL
			if x >= VIEW_LEFT && x < VIEW_LEFT + VIEW_SIDE && y >= VIEW_LEFT && y < VIEW_LEFT + VIEW_SIDE {
				if color, covered := form_cells_pixel(&run, 2, x - VIEW_LEFT - PLACE_X, y - VIEW_LEFT - PLACE_Y, .Smooth, false); covered {
					expected = color
					written += 1
				}
			}
			if buffer[y * SIDE + x] != expected {
				testing.expectf(t, false, "pixel %d, %d of the buffer: 0x%06X, not 0x%06X", x, y, buffer[y * SIDE + x], expected)
				return
			}
		}
	}
	// The left part of the run is cut by the canvas: fewer pixels than its
	// cells have.
	testing.expect(t, written > 0 && written < 4 * (count_letter_of_form(&run, 'b') + count_letter_of_form(&run, 'v') + count_letter_of_form(&run, 'h') + count_letter_of_form(&run, 'd') + count_letter_of_form(&run, 'o') + count_letter_of_form(&run, 'k') + count_letter_of_form(&run, 'y')))
}
