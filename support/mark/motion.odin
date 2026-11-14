package mark

import "support:graphics"

// The moves of the heron (docs/DESIGN.md, "The mark", "The moves"): during
// some animations the heron squashes, stretches, lifts, or crosses the
// window. A cell of the heron is always a square of one size at a place of
// the grid. So a squashed heron is not the picture of the heron made wider:
// it is another drawing of the heron, in the same cells, with more columns
// and fewer rows. And the heron travels by whole cells.
//
// The form of the data:
//   form_lines: for each form, the columns and the rows of the heron that
//     the form draws two times, and those that it leaves out. The lines are
//     chosen by hand: the body and the neck change, the head, the eye, the
//     beak and the crest never do.
//   form_corrections: the cells of a form that are then set or cleared by
//     hand, where the lines alone give a poor drawing: a leg two cells
//     wide, a tail too far from the body.
//   move_keys: for each animation that moves, its keys in the order of
//     time. A key gives the form of the heron from that time to the next
//     key, and the place of the heron at that time, in whole cells.
//
// Only the part of the heron above the water takes a form and a place: the
// two rows of the water stay.

// The count of the rows of the water, at the bottom of the grid, which no
// move takes with it.
WATER_ROWS :: 2
// The part of the heron above the water, in cells: what a form draws.
BODY_COLUMNS :: HERON_GRID_SIZE
BODY_ROWS :: HERON_GRID_SIZE - WATER_ROWS
// The column of the leg that the heron stands on. Its foot is in the rows
// of the water, which stay: so this column is at the same place in every
// form, and no form draws it two times or leaves it out.
STANDING_LEG_COLUMN :: 9
// The first column of the head and the last row of the head: no form
// changes a column from this one to the right, or a row down to that one.
// The eye stays one cell, the beak keeps its cells and the crest its two.
HEAD_FIRST_COLUMN :: 13
HEAD_LAST_ROW :: 3

// A set of columns, or of rows, of the heron.
Line_Set :: bit_set[0 ..< HERON_GRID_SIZE;u32]

// A form of the heron: one drawing of the part above the water.
Form :: enum u8 {
	Natural, // The heron as the frame has it: 24 by 22.
	Gather, // A little wider and lower: before a squash, and after one.
	Crouch, // Wide and low: the squash before a start, and on a landing.
	Run, // Long and low: the body and the tail along the way, the legs near the water.
	Brake, // Narrow, with a long neck: the stop of the dash against its own speed.
	Slide, // A little narrow: the heron slides back to its place.
	Rebound, // A little wide and low, on shorter legs: after a stop or a landing.
	Tall, // Narrow, with a longer neck: in the air.
	Thin, // A little narrow and a little high: one side of a shake.
	Neck, // The neck two rows longer.
	Long_Neck, // The neck four rows longer.
}

// The name of each form, for a test and a caption.
@(rodata)
form_names := [Form]string {
	.Natural   = "natural",
	.Gather    = "gather",
	.Crouch    = "crouch",
	.Run       = "run",
	.Brake     = "brake",
	.Slide     = "slide",
	.Rebound   = "rebound",
	.Tall      = "tall",
	.Thin      = "thin",
	.Neck      = "neck",
	.Long_Neck = "long neck",
}

// The lines of a form: the columns and the rows of the frame that the form
// draws two times, side by side, and those that it does not draw.
Form_Lines :: struct {
	columns_twice: Line_Set, // Drawn two times.
	columns_out:   Line_Set, // Not drawn.
	rows_twice:    Line_Set, // Drawn two times.
	rows_out:      Line_Set, // Not drawn.
}

// The lines of each form, chosen on the still heron. The columns 4 to 7
// are the body behind the standing leg, 10 and 11 the body in front of it,
// 1 to 3 the tail. The rows 4 to 10 are the neck, 16 to 21 the legs. A wide
// form repeats columns of the body at each side of the standing leg, never
// a column of a leg. A low form leaves out a row of the neck that repeats
// its neighbour (5, 8), and a row of the straight part of the legs (17).
// The forms of the run and of the stop leave out rows under the feet of a
// heron that runs: its legs end above them, and the body comes down.
@(rodata)
form_lines := [Form]Form_Lines {
	.Natural = {},
	.Gather = {columns_twice = {5, 10}, rows_out = {5}},
	.Crouch = {columns_twice = {4, 5, 10, 11}, rows_out = {5, 8, 17}},
	.Run = {columns_twice = {1, 2, 4, 5, 6, 7, 10, 11}, rows_out = {20, 21}},
	.Brake = {columns_out = {3, 5, 6, 7}, rows_twice = {5, 7, 9}, rows_out = {19, 20}},
	.Slide = {columns_out = {5, 6}, rows_twice = {7}, rows_out = {19, 20}},
	.Rebound = {columns_twice = {5, 10}, rows_out = {5, 17}},
	.Tall = {columns_out = {5, 6}, rows_twice = {6, 9}},
	.Thin = {columns_out = {5, 6}, rows_twice = {7}},
	.Neck = {rows_twice = {6, 9}},
	.Long_Neck = {rows_twice = {4, 6, 7, 9}},
}

// The most columns and rows of a form, and how far a form goes past the
// place of the natural heron: to the left, to the right and upward, in
// cells. A place that draws the forms keeps this room around the heron.
// The host tests hold form_lines to these bounds.
FORM_COLUMNS_MOST :: 32
FORM_ROWS_MOST :: 26
FORM_REACH_LEFT :: 6
FORM_REACH_RIGHT :: 2
FORM_REACH_UP :: 4

// One cell of a form that is set or cleared by hand, after the lines.
Form_Correction :: struct {
	form:      Form, // The form of the cell.
	animation: Animation, // The animation of the frame; not read when frame is 0.
	frame:     u8, // The frame, from 1; 0: every frame of every animation in this form.
	column:    u8, // The column of the cell in the form, from 0.
	row:       u8, // The row of the cell in the form, from 0.
	letter:    u8, // The letter of a part, or '.' for an empty cell.
}

// The corrections. A frame that repeats a pose with no change of its own
// (the steps of the run of the dash) takes the corrections of that pose.
@(rodata)
form_corrections := [?]Form_Correction {
	// Crouch: the two repeated columns of the body widen the gap between
	// the tip of the tail and the body in the last row of the body. One
	// cell of body closes it to the two cells of the still heron.
	{.Crouch, .Blink, 0, 5, 13, 'b'},
	// Run: the same gap, in the same row.
	{.Run, .Blink, 0, 7, 15, 'b'},
	// Run, the legs apart: the back leg crosses three repeated columns, so
	// its lower part is two cells thick and its foot four cells long. The
	// leg is one cell wide again, on its diagonal, and the foot two cells.
	{.Run, .Dash, 2, 12, 18, '.'},
	{.Run, .Dash, 2, 8, 19, '.'},
	{.Run, .Dash, 2, 9, 19, '.'},
	{.Run, .Dash, 2, 10, 19, '.'},
	{.Run, .Dash, 2, 12, 19, 'o'},
	// Run, the legs together: the two feet are on the two repeated columns
	// between the legs, and join in a bar of four cells. Each foot is one
	// cell again, under its leg toward the other.
	{.Run, .Dash, 3, 17, 18, '.'},
	{.Run, .Dash, 3, 18, 18, '.'},
}

// How a form was drawn.
Form_Origin :: enum u8 {
	Frame, // The frame itself: no line and no correction.
	Lines, // The lines alone.
	Corrected, // The lines, then corrections by hand.
}

// form_origin tells how a form was drawn.
form_origin :: proc "contextless" (form: Form) -> Form_Origin {
	for correction in form_corrections {
		if correction.form == form {
			return .Corrected
		}
	}
	lines := form_lines[form]
	if card(lines.columns_twice) + card(lines.columns_out) + card(lines.rows_twice) + card(lines.rows_out) == 0 {
		return .Frame
	}
	return .Lines
}

// line_times gives how many times a form draws a line of the frame: 0, 1
// or 2. A line in both sets is not drawn: the host tests refuse such a
// table.
@(private)
line_times :: proc "contextless" (line: int, twice, out: Line_Set) -> int {
	if line in out {
		return 0
	}
	if line in twice {
		return 2
	}
	return 1
}

// line_source gives the line of the frame that the line number target of a
// form shows, among the first count lines of the frame.
@(private)
line_source :: proc "contextless" (count: int, twice, out: Line_Set, target: int) -> (source: int, found: bool) {
	drawn := 0
	for line in 0 ..< count {
		drawn += line_times(line, twice, out)
		if target < drawn {
			return line, target >= 0
		}
	}
	return 0, false
}

// line_count gives the count of the lines of a form.
@(private)
line_count :: proc "contextless" (count: int, twice, out: Line_Set) -> int {
	drawn := 0
	for line in 0 ..< count {
		drawn += line_times(line, twice, out)
	}
	return drawn
}

// form_size gives the columns and the rows of a form, in cells.
form_size :: proc "contextless" (form: Form) -> (columns, rows: int) {
	lines := form_lines[form]
	return line_count(BODY_COLUMNS, lines.columns_twice, lines.columns_out), line_count(BODY_ROWS, lines.rows_twice, lines.rows_out)
}

// form_source_column gives the column of the frame that a column of a form
// shows.
form_source_column :: proc "contextless" (form: Form, column: int) -> (source: int, found: bool) {
	lines := form_lines[form]
	return line_source(BODY_COLUMNS, lines.columns_twice, lines.columns_out, column)
}

// form_source_row gives the row of the frame that a row of a form shows.
form_source_row :: proc "contextless" (form: Form, row: int) -> (source: int, found: bool) {
	lines := form_lines[form]
	return line_source(BODY_ROWS, lines.rows_twice, lines.rows_out, row)
}

// form_first_column gives the column of the grid of the natural heron
// where the first column of a form is: negative when the form goes past
// the left edge of the heron. The column of the standing leg keeps its
// place: the leg stays above its foot in the water.
form_first_column :: proc "contextless" (form: Form) -> int {
	lines := form_lines[form]
	return STANDING_LEG_COLUMN - line_count(STANDING_LEG_COLUMN, lines.columns_twice, lines.columns_out)
}

// form_first_row gives the row of the grid of the natural heron where the
// first row of a form is: negative when the form is higher than the heron.
// The last row of a form is on the line of the water.
form_first_row :: proc "contextless" (form: Form) -> int {
	_, rows := form_size(form)
	return BODY_ROWS - rows
}

// The cells of the part of the heron above the water in one form: the
// letters by row, then by column, and where the first cell is in the grid
// of the natural heron. A cell past the columns or the rows of the form is
// empty.
Form_Cells :: struct {
	columns:      int, // The columns of the form.
	rows:         int, // The rows of the form.
	first_column: int, // The column of the natural grid of the first column.
	first_row:    int, // The row of the natural grid of the first row.
	cells:        [FORM_ROWS_MOST][FORM_COLUMNS_MOST]u8, // The letters.
}

// animation_pose_frame gives the frame whose pose a frame repeats: a frame
// that starts from an earlier frame and changes no cell is that earlier
// frame again. A frame with a change of its own is its own pose.
animation_pose_frame :: proc "contextless" (animation: Animation, frame: int) -> int {
	pose := frame
	for _ in 0 ..< BASE_FRAME_DEPTH_LIMIT {
		row, found := animation_frame(animation, pose)
		if !found || row.base_frame == 0 {
			return pose
		}
		for change in animation_changes {
			if change.animation == animation && int(change.frame) == pose {
				return pose
			}
		}
		pose = int(row.base_frame)
	}
	return pose
}

// form_cells gives the cells of one frame of an animation in a form: the
// lines of the form over the cells of the frame, then the corrections of
// the form for that frame. found is false for a frame that the animation
// does not have. A correction outside the form, or to a letter that is not
// a part, is not applied: the host tests refuse such a table.
form_cells :: proc "contextless" (form: Form, animation: Animation, frame: int) -> (drawn: Form_Cells, found: bool) {
	frame_cells := animation_frame_cells(animation, frame) or_return
	drawn.columns, drawn.rows = form_size(form)
	drawn.first_column = form_first_column(form)
	drawn.first_row = form_first_row(form)
	if drawn.columns > FORM_COLUMNS_MOST || drawn.rows > FORM_ROWS_MOST {
		return {}, false
	}
	for row in 0 ..< FORM_ROWS_MOST {
		source_row, has_row := form_source_row(form, row)
		for column in 0 ..< FORM_COLUMNS_MOST {
			source_column, has_column := form_source_column(form, column)
			drawn.cells[row][column] = '.'
			if has_row && has_column {
				drawn.cells[row][column] = frame_cells[source_row][source_column]
			}
		}
	}
	pose := animation_pose_frame(animation, frame)
	for correction in form_corrections {
		if correction.form != form {
			continue
		}
		if correction.frame != 0 && (correction.animation != animation || int(correction.frame) != pose) {
			continue
		}
		_, is_part := part_of_letter(correction.letter)
		if int(correction.column) >= drawn.columns || int(correction.row) >= drawn.rows || (correction.letter != '.' && !is_part) {
			continue
		}
		drawn.cells[correction.row][correction.column] = correction.letter
	}
	return drawn, true
}

// form_cells_pixel gives the color of one pixel of a form. (x, y) is from
// the top left corner of the natural heron, so it is negative at the left
// of the heron and above it. A cell takes the color of its part at its
// place, as a cell of a frame does: the gradient over the box of the part
// in the still heron, and past that box the color of the nearer end.
form_cells_pixel :: proc "contextless" (drawn: ^Form_Cells, cell_size, x, y: int, on_light: bool) -> (color: u32, covered: bool) {
	if !cell_size_is_accepted(cell_size) {
		return 0, false
	}
	from_left := x - drawn.first_column * cell_size
	from_top := y - drawn.first_row * cell_size
	if from_left < 0 || from_top < 0 || from_left >= drawn.columns * cell_size || from_top >= drawn.rows * cell_size {
		return 0, false
	}
	index, found := part_of_letter(drawn.cells[from_top / cell_size][from_left / cell_size])
	if !found {
		return 0, false
	}
	return part_pixel(index, cell_size, x, y, on_light), true
}

// form_cells_draw draws a form into a canvas. (x, y) is the place in the
// canvas of the top left corner of the natural heron: the form is drawn
// around it, so that the standing leg and the line of the water are where
// cells_draw puts them. The covered pixels only, nothing outside the
// canvas.
form_cells_draw :: proc "contextless" (canvas: graphics.Canvas, drawn: ^Form_Cells, x, y, cell_size: int, on_light: bool, order := Channel_Order.Red_In_High_Byte) {
	if !cell_size_is_accepted(cell_size) {
		return
	}
	left := x + drawn.first_column * cell_size
	top := y + drawn.first_row * cell_size
	first_x, first_y, last_x, last_y, inside := place_in_canvas(canvas, left, top, drawn.columns * cell_size, drawn.rows * cell_size)
	if !inside {
		return
	}
	for canvas_y in first_y ..< last_y {
		for canvas_x in first_x ..< last_x {
			if color, covered := form_cells_pixel(drawn, cell_size, canvas_x - x, canvas_y - y, on_light); covered {
				canvas.pixels[canvas_y * canvas.stride + canvas_x] = color_in_order(color, order)
			}
		}
	}
}

// cells_have_foot_in_water tells whether a frame has a cell that is not
// water in the rows of the water: a foot, which stays with the water when
// the part above it moves.
cells_have_foot_in_water :: proc "contextless" (cells: ^Heron_Cells) -> bool {
	for row in BODY_ROWS ..< HERON_GRID_SIZE {
		for column in 0 ..< HERON_GRID_SIZE {
			if cells[row][column] != '.' && cells[row][column] != 't' {
				return true
			}
		}
	}
	return false
}

// Where a key puts the heron across the window.
Move_Edge :: enum u8 {
	None, // In its place, plus the cells of the key.
	Past_Right, // Wholly outside the window, past its right edge.
	Past_Left, // Wholly outside the window, past its left edge.
}

// How the place of the heron goes from a key to the next one.
Move_Pace :: enum u8 {
	Step, // Cell by cell, the cells spread evenly over the time.
	Hold, // It stays at the place of the key, then is at the next key at once.
}

// One key of a move: at a time from the start of the animation, the form
// that the heron takes until the next key, and its place at that time. A
// place is a whole count of cells: the type holds no part of a cell.
Move_Key :: struct {
	animation:       Animation, // The animation of the move.
	at_milliseconds: int, // The time of the key, from the start of the animation.
	form:            Form, // The form from this key to the next one.
	cells_right:     int, // Cells toward the right; negative: toward the left.
	cells_up:        int, // Cells upward.
	edge:            Move_Edge, // In its place, or past an edge of the window.
	pace:            Move_Pace, // From this key to the next one.
}

// The keys of each animation that moves, in the order of time. The first
// key is at 0 and the last at the end of the animation, and both are the
// natural heron in its place. While a foot is in the water, no key moves
// the heron: only its form changes.
//
// The dash: the heron gathers, then crouches for the wind-up. With the
// first step of the run it takes the form of the run and leaves to the
// right: 4 cells while the first step lasts, 10 more in the second one,
// then at one speed to a place past the right edge, which it reaches when
// the fifth one ends.
// It stays outside for four steps, then is past the left edge at once and
// comes in at one speed, to 3 cells past its place. There it brakes for
// 100 ms, slides back in 120 ms, rebounds on its legs, and stands.
@(rodata)
move_keys := [?]Move_Key {
	{.Dash, 0, .Natural, 0, 0, .None, .Step},
	{.Dash, 90, .Gather, 0, 0, .None, .Step},
	{.Dash, 180, .Crouch, 0, 0, .None, .Step},
	{.Dash, 380, .Run, 0, 0, .None, .Step},
	{.Dash, 450, .Run, 4, 0, .None, .Step},
	{.Dash, 520, .Run, 14, 0, .None, .Step},
	{.Dash, 730, .Run, 0, 0, .Past_Right, .Hold},
	{.Dash, 1010, .Run, 0, 0, .Past_Left, .Step},
	{.Dash, 1360, .Brake, 3, 0, .None, .Step},
	{.Dash, 1460, .Slide, 3, 0, .None, .Step},
	{.Dash, 1580, .Rebound, 0, 0, .None, .Step},
	{.Dash, 1680, .Natural, 0, 0, .None, .Step},
	{.Dash, 1780, .Natural, 0, 0, .None, .Step},
	// The hop: the heron gathers and crouches, is tall in the air, 4 cells
	// up and down again, crouches on the water, rebounds, and stands.
	{.Hop, 0, .Natural, 0, 0, .None, .Step},
	{.Hop, 60, .Gather, 0, 0, .None, .Step},
	{.Hop, 120, .Crouch, 0, 0, .None, .Step},
	{.Hop, 180, .Tall, 0, 0, .None, .Step},
	{.Hop, 340, .Tall, 0, 4, .None, .Step},
	{.Hop, 500, .Crouch, 0, 0, .None, .Step},
	{.Hop, 600, .Rebound, 0, 0, .None, .Step},
	{.Hop, 700, .Gather, 0, 0, .None, .Step},
	{.Hop, 790, .Natural, 0, 0, .None, .Step},
	{.Hop, 880, .Natural, 0, 0, .None, .Step},
	// The stretch: the neck two rows longer, then four, held; then a shake:
	// wide, thin, wide, thin.
	{.Stretch, 0, .Natural, 0, 0, .None, .Step},
	{.Stretch, 100, .Neck, 0, 0, .None, .Step},
	{.Stretch, 200, .Long_Neck, 0, 0, .None, .Step},
	{.Stretch, 620, .Gather, 0, 0, .None, .Step},
	{.Stretch, 700, .Thin, 0, 0, .None, .Step},
	{.Stretch, 780, .Gather, 0, 0, .None, .Step},
	{.Stretch, 860, .Thin, 0, 0, .None, .Step},
	{.Stretch, 940, .Natural, 0, 0, .None, .Step},
	{.Stretch, 1100, .Natural, 0, 0, .None, .Step},
	// The flap: 3 cells up while the wing beats, down, a rebound on the
	// legs.
	{.Flap, 0, .Natural, 0, 0, .None, .Step},
	{.Flap, 200, .Natural, 0, 0, .None, .Step},
	{.Flap, 420, .Natural, 0, 3, .None, .Step},
	{.Flap, 650, .Natural, 0, 3, .None, .Step},
	{.Flap, 800, .Rebound, 0, 0, .None, .Step},
	{.Flap, 900, .Natural, 0, 0, .None, .Step},
	{.Flap, 1000, .Natural, 0, 0, .None, .Step},
}

// animation_moves tells whether an animation has keys of a move.
animation_moves :: proc "contextless" (animation: Animation) -> bool {
	for key in move_keys {
		if key.animation == animation {
			return true
		}
	}
	return false
}

// How far the dash goes, for one window: the whole cells from the place of
// the heron to a place where the heron, in any form, is wholly outside the
// window, at each side.
Move_Travel :: struct {
	cells_to_right_edge: int, // Cells toward the right until the heron is past the right edge.
	cells_to_left_edge:  int, // Cells toward the left until the heron is past the left edge.
}

// The form and the place of the heron at one time of a move, in whole
// cells from its place.
Move_Pose :: struct {
	form:        Form, // The form of the heron.
	cells_right: int, // Cells toward the right; negative: toward the left.
	cells_up:    int, // Cells upward.
}

// move_key_place gives the place of a key in whole cells, for one window.
move_key_place :: proc "contextless" (key: Move_Key, travel: Move_Travel) -> (cells_right, cells_up: int) {
	switch key.edge {
	case .None:
	case .Past_Right:
		return key.cells_right + travel.cells_to_right_edge, key.cells_up
	case .Past_Left:
		return key.cells_right - travel.cells_to_left_edge, key.cells_up
	}
	return key.cells_right, key.cells_up
}

// move_pose gives the form and the place of the heron at a time from the
// start of an animation, in milliseconds. An animation with no move, and a
// time before its first key, give the natural heron in its place; a time
// at or after its last key gives that key.
//
// The form is the form of the last key at or before the time: a form is a
// drawing, and no form exists between two of them. The place goes from
// the place of that key to the place of the next one cell by cell: the
// cells of the way times the part of the time that has passed, cut to a
// whole count of cells. So the heron is never between two cells.
move_pose :: proc "contextless" (animation: Animation, at_milliseconds: int, travel: Move_Travel) -> Move_Pose {
	first, second: Move_Key
	has_first, has_second := false, false
	for key in move_keys {
		if key.animation != animation {
			continue
		}
		if key.at_milliseconds <= at_milliseconds {
			first, has_first = key, true
		} else if !has_second {
			second, has_second = key, true
		}
	}
	if !has_first {
		return Move_Pose{}
	}
	right, up := move_key_place(first, travel)
	span := second.at_milliseconds - first.at_milliseconds
	if has_second && first.pace == .Step && span > 0 {
		next_right, next_up := move_key_place(second, travel)
		passed := at_milliseconds - first.at_milliseconds
		right += (next_right - right) * passed / span
		up += (next_up - up) * passed / span
	}
	return Move_Pose{form = first.form, cells_right = right, cells_up = up}
}

// A fault of a table of keys.
Move_Fault :: enum u8 {
	None, // The table has no fault.
	Times, // The keys of an animation do not go from 0 to its end, each later than the one before.
	Ends, // The first or the last key of an animation is not the natural heron in its place.
	Two_Ways, // Two keys that follow each other differ to the right and upward: the steps of such a way are not whole cells.
	Edge, // A key past the right edge does not hold, or the next one is not past the left edge; or a key past the left edge has no key past the right edge before it.
	Foot_In_Water, // A key moves the heron while a frame has a foot in the water.
	Foot_Not_Above_Leg, // A frame with a foot in the water is drawn in a form whose last row is not the last row of the frame.
}

// move_keys_fault checks a table of keys against the frames of the
// animations and gives its first fault, with the animation and the time of
// the key. The host tests check move_keys with it, and tables with a fault.
move_keys_fault :: proc "contextless" (table: []Move_Key) -> (fault: Move_Fault, animation: Animation, at_milliseconds: int) {
	for candidate in Animation {
		count := 0
		previous: Move_Key
		last: Move_Key
		for key in table {
			if key.animation != candidate {
				continue
			}
			natural := key.form == .Natural && key.cells_right == 0 && key.cells_up == 0 && key.edge == .None
			if count == 0 && key.at_milliseconds != 0 {
				return .Times, candidate, key.at_milliseconds
			}
			if count == 0 && !natural {
				return .Ends, candidate, key.at_milliseconds
			}
			if count > 0 {
				if key.at_milliseconds <= previous.at_milliseconds {
					return .Times, candidate, key.at_milliseconds
				}
				same_right := key.cells_right == previous.cells_right && key.edge == previous.edge
				if !same_right && key.cells_up != previous.cells_up && previous.pace == .Step {
					return .Two_Ways, candidate, key.at_milliseconds
				}
				if previous.edge == .Past_Right && (previous.pace != .Hold || key.edge != .Past_Left) {
					return .Edge, candidate, previous.at_milliseconds
				}
				if key.edge == .Past_Left && previous.edge != .Past_Right {
					return .Edge, candidate, key.at_milliseconds
				}
			}
			previous = key
			last = key
			count += 1
		}
		if count == 0 {
			continue
		}
		duration := animation_duration(candidate)
		if count < 2 || last.at_milliseconds != duration {
			return .Times, candidate, last.at_milliseconds
		}
		if last.form != .Natural || last.cells_right != 0 || last.cells_up != 0 || last.edge != .None {
			return .Ends, candidate, last.at_milliseconds
		}
		// A frame with a foot in the water: from the key at or before its
		// start to the key at or after its end, no key moves the heron, and
		// each form keeps the last row of the frame, where the leg meets
		// the foot.
		start := 0
		for frame in 1 ..= animation_frame_count(candidate) {
			row, _ := animation_frame(candidate, frame)
			cells, _ := animation_frame_cells(candidate, frame)
			end := start + int(row.duration_milliseconds)
			if cells_have_foot_in_water(&cells) {
				from, to := 0, duration
				for key in table {
					if key.animation == candidate && key.at_milliseconds <= start {
						from = key.at_milliseconds
					}
				}
				#reverse for key in table {
					if key.animation == candidate && key.at_milliseconds >= end {
						to = key.at_milliseconds
					}
				}
				for key in table {
					if key.animation != candidate || key.at_milliseconds < from || key.at_milliseconds > to {
						continue
					}
					if key.cells_right != 0 || key.cells_up != 0 || key.edge != .None {
						return .Foot_In_Water, candidate, key.at_milliseconds
					}
					if key.at_milliseconds < end && (BODY_ROWS - 1) in form_lines[key.form].rows_out {
						return .Foot_Not_Above_Leg, candidate, key.at_milliseconds
					}
				}
			}
			start = end
		}
	}
	return .None, .Blink, 0
}
