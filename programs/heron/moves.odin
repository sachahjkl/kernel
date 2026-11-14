package heron

import "support:mark"

// The moves of the heron for this program: the keys of each move in whole
// cells, the size and the place of the heron at a time, and the cell of
// the heron that a cell of a deformed heron shows.
//
// A cell of the heron is a square of one size at a place of the grid. A
// squash or a stretch is the heron drawn with other counts of whole cells:
// more columns and fewer rows, or the reverse. A travel is a count of whole
// cells. This is the way "on the grid". The other way, "free", is here to
// compare: the size and the place go from a key to the next one in parts of
// a cell, so the cells become rectangles at any pixel.
//
// This file is all that the program holds of the rule of the moves. The
// rule belongs with the data of the mark (support/mark): when that package
// gives the keys and the deformed cells, the program calls it and this
// file goes.

// The count of the rows of the water, at the bottom of the grid, which no
// move takes with it.
WATER_ROWS :: 2
// The part of the heron above the water, in cells: what a move deforms.
BODY_COLUMNS :: mark.HERON_GRID_SIZE
BODY_ROWS :: mark.HERON_GRID_SIZE - WATER_ROWS
// The most columns and rows of a key: the widest and the highest deformed
// heron. A key with more is cut to them.
MOVE_COLUMNS_MOST :: 32
MOVE_ROWS_MOST :: 25

// Where a key puts the heron across the window.
Move_Edge :: enum u8 {
	None, // In its place, plus the cells of the key.
	Past_Right, // Wholly outside the window, past its right edge.
	Past_Left, // Wholly outside the window, past its left edge.
}

// How the heron goes from a key to the next one.
Move_Ease :: enum u8 {
	Even, // At one speed.
	Slow_At_End, // Fast first, then slower.
	Slow_At_Start, // Slow first, then faster.
	Hold, // It stays as the key says, then is at the next key at once.
}

// One key of a move: at a time from the start of the animation, the size
// of the part of the heron above the water in whole cells, and its travel
// in whole cells. The size changes from the middle of the bottom edge of
// the part: the feet stay on the line of the water.
Move_Key :: struct {
	animation:       mark.Animation, // The animation of the move.
	at_milliseconds: int, // The time of the key, from the start of the animation.
	columns:         int, // The columns of cells of the part; BODY_COLUMNS is the heron itself.
	rows:            int, // The rows of cells of the part; BODY_ROWS is the heron itself.
	cells_right:     int, // Cells toward the right; negative: toward the left.
	cells_up:        int, // Cells upward.
	edge:            Move_Edge, // In its place, or past an edge of the window.
	ease:            Move_Ease, // From this key to the next one.
}

// The keys of each animation that moves, in the order of time. The first
// key is at 0 and the last at the end of the animation, and both are the
// heron in its place at its size. While a foot is in the water, no key
// moves the heron: only its size changes. The counts of columns are even,
// so the heron stays in the middle of its place.
//
// The dash: the heron squashes for the wind-up (28 by 19), leaves to the
// right faster and faster, stretched along its way (32 by 18), and is past
// the right edge when the fifth step of the run ends. It stays outside for
// four steps, then is past the left edge at once and comes in at one
// speed, goes three cells past its place, squashes there against its own
// speed (20 by 25), slides back, and stands.
@(rodata)
move_keys := [?]Move_Key {
	{.Dash, 0, 24, 22, 0, 0, .None, .Slow_At_End},
	{.Dash, 260, 28, 19, 0, 0, .None, .Even},
	{.Dash, 380, 28, 19, 0, 0, .None, .Slow_At_Start},
	{.Dash, 730, 32, 18, 0, 0, .Past_Right, .Hold},
	{.Dash, 1010, 32, 18, 0, 0, .Past_Left, .Even},
	{.Dash, 1360, 32, 18, 3, 0, .None, .Slow_At_End},
	{.Dash, 1460, 20, 25, 3, 0, .None, .Slow_At_End},
	{.Dash, 1580, 24, 22, 0, 0, .None, .Slow_At_End},
	{.Dash, 1660, 26, 21, 0, 0, .None, .Slow_At_End},
	{.Dash, 1780, 24, 22, 0, 0, .None, .Even},
	// The hop: a squash, four cells up and thinner, down, a squash on the
	// water.
	{.Hop, 0, 24, 22, 0, 0, .None, .Slow_At_End},
	{.Hop, 180, 26, 19, 0, 0, .None, .Slow_At_End},
	{.Hop, 340, 22, 24, 0, 4, .None, .Slow_At_Start},
	{.Hop, 500, 22, 23, 0, 0, .None, .Slow_At_End},
	{.Hop, 600, 28, 19, 0, 0, .None, .Slow_At_End},
	{.Hop, 880, 24, 22, 0, 0, .None, .Even},
	// The stretch: taller and thinner, held, then a shake of its width.
	{.Stretch, 0, 24, 22, 0, 0, .None, .Slow_At_End},
	{.Stretch, 300, 22, 25, 0, 0, .None, .Even},
	{.Stretch, 620, 22, 25, 0, 0, .None, .Even},
	{.Stretch, 700, 26, 22, 0, 0, .None, .Even},
	{.Stretch, 780, 22, 22, 0, 0, .None, .Even},
	{.Stretch, 860, 26, 22, 0, 0, .None, .Even},
	{.Stretch, 940, 24, 22, 0, 0, .None, .Even},
	{.Stretch, 1100, 24, 22, 0, 0, .None, .Even},
	// The flap: three cells up while the wing beats, down, a small squash.
	{.Flap, 0, 24, 22, 0, 0, .None, .Even},
	{.Flap, 200, 24, 22, 0, 0, .None, .Slow_At_End},
	{.Flap, 420, 24, 22, 0, 3, .None, .Even},
	{.Flap, 650, 24, 22, 0, 3, .None, .Slow_At_Start},
	{.Flap, 800, 24, 22, 0, 0, .None, .Slow_At_End},
	{.Flap, 880, 26, 20, 0, 0, .None, .Slow_At_End},
	{.Flap, 1000, 24, 22, 0, 0, .None, .Even},
}

// animation_moves tells whether an animation has keys of a move.
animation_moves :: proc "contextless" (animation: mark.Animation) -> bool {
	for key in move_keys {
		if key.animation == animation {
			return true
		}
	}
	return false
}

// The two ways to draw a move from the same keys.
Move_Way :: enum u8 {
	On_The_Grid, // Whole square cells at places of the grid: the size and the travel step by whole cells.
	Free, // The size and the place go from a key to the next one in parts of a cell: the cells are rectangles at any pixel.
}

// A size or a place of a pose is a count of parts of a cell: this many
// parts are one cell. On the grid each value is a whole count of cells.
CELL_PARTS :: 1024
#assert(CELL_PARTS == 1 << 10)

// How far the dash goes, for one window: the whole cells from the place of
// the heron to a place where the widest heron of a move is wholly outside
// the window, at each side.
Move_Travel :: struct {
	cells_to_right_edge: int, // Cells toward the right until the heron is past the right edge.
	cells_to_left_edge:  int, // Cells toward the left until the heron is past the left edge.
}

// The size and the place of the part of the heron above the water at one
// time of a move, in parts of a cell.
Move_Pose :: struct {
	columns: int, // The width of the part.
	rows:    int, // The height of the part.
	left:    int, // The left edge of the part, from the left edge of the heron in its place; negative: to its left.
	up:      int, // How far the bottom edge of the part is above the line of the water.
}

// eased_share gives the share of the way that a move has gone, from the
// share of the time that has passed, each from 0 to CELL_PARTS: at one
// speed, slower at the end (the square of what is left), slower at the
// start (the square), or not at all.
@(private = "file")
eased_share :: proc "contextless" (share: int, ease: Move_Ease) -> int {
	switch ease {
	case .Even:
		return share
	case .Slow_At_End:
		left := CELL_PARTS - share
		return CELL_PARTS - left * left / CELL_PARTS
	case .Slow_At_Start:
		return share * share / CELL_PARTS
	case .Hold:
		return 0
	}
	return share
}

// key_values gives the four values of a key in whole cells: the columns,
// the rows, the travel to the right and the lift. Past an edge, the travel
// is the travel of the window.
@(private = "file")
key_values :: proc "contextless" (key: Move_Key, travel: Move_Travel) -> [4]int {
	right := key.cells_right
	switch key.edge {
	case .None:
	case .Past_Right:
		right = travel.cells_to_right_edge
	case .Past_Left:
		right = -travel.cells_to_left_edge
	}
	return {clamp(key.columns, 1, MOVE_COLUMNS_MOST), clamp(key.rows, 1, MOVE_ROWS_MOST), right, key.cells_up}
}

// move_pose_at gives the size and the place of the part of the heron above
// the water at a time from the start of an animation, in milliseconds, in
// one of the two ways. An animation with no move, and a time before the
// start or after the end, give the heron in its place at its size.
//
// Between two keys each value goes from the value of the first key to the
// value of the second. The free way keeps the value in parts of a cell.
// The way on the grid takes the nearest whole count of cells: the heron
// has a whole count of columns and of rows, and its travel steps by whole
// cells. The way on the grid computes cells; it does not draw the free
// heron first.
//
// The width changes from the middle of the part. On the grid the left edge
// is at a whole cell: a part with an odd count of columns has its extra
// column at the right.
move_pose_at :: proc "contextless" (animation: mark.Animation, at_milliseconds: int, travel: Move_Travel, way: Move_Way) -> Move_Pose {
	home := Move_Pose{columns = BODY_COLUMNS * CELL_PARTS, rows = BODY_ROWS * CELL_PARTS}
	first, second: Move_Key
	has_first, has_second := false, false
	for key in move_keys {
		if key.animation != animation {
			continue
		}
		if key.at_milliseconds <= at_milliseconds {
			first = key
			has_first = true
		} else if !has_second {
			second = key
			has_second = true
		}
	}
	if !has_first || !has_second {
		return home
	}
	span := second.at_milliseconds - first.at_milliseconds
	share := 0
	if span > 0 {
		share = (at_milliseconds - first.at_milliseconds) * CELL_PARTS / span
	}
	share = eased_share(clamp(share, 0, CELL_PARTS), first.ease)
	from, to := key_values(first, travel), key_values(second, travel)
	values: [4]int
	for &value, index in values {
		// The shift rounds a negative number down, as a positive one: a
		// place left of the window moves as a place inside it.
		value = (from[index] * CELL_PARTS * (CELL_PARTS - share) + to[index] * CELL_PARTS * share + CELL_PARTS / 2) >> 10
		if way == .On_The_Grid {
			value = ((value + CELL_PARTS / 2) >> 10) * CELL_PARTS
		}
	}
	inset := (BODY_COLUMNS * CELL_PARTS - values[0]) >> 1
	if way == .On_The_Grid {
		inset = (inset >> 10) * CELL_PARTS
	}
	return {columns = values[0], rows = values[1], left = values[2] + inset, up = values[3]}
}

// deformed_source_cell gives the cell of a line of source_count cells that
// the cell number cell of a line of count cells shows, when the first line
// is drawn with count cells: the cell under the middle of the cell. This
// is the nearest sampling of the cell grid: a deformed heron repeats or
// leaves out whole cells of the heron, and each of its cells is a square.
// The caller keeps cell from 0 to count - 1 and the two counts above 0.
deformed_source_cell :: proc "contextless" (cell, count, source_count: int) -> int {
	return (2 * cell + 1) * source_count / (2 * count)
}
