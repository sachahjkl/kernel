// A demonstration, for fun: the heron of the mark plays its animations.
//   1 to 9, a to f: play one animation    space: pause    .: next frame
//   s: slow motion    l: the lines of the cells    z: the cell size
//   g: a move on the grid, or free
//
// **What it is for.** It shows the graphics of the system with the mark of
// the system: the heron stands in its water, drawn large from the cells of
// `support/mark`, and plays its 15 animations in an order of chance. Four
// animations move the whole heron: in the dash it leaves the window by the
// right and comes back by the left, in the forms of the crouch and of the
// run. The program draws again only the part of its window that changed,
// and its log says how long a picture takes and how many pixels it damages.
//
// **What a reader sees.** Start it from the menu of the programs, or with
// `start("heron")` in the console. The heron is still for about 40 % of
// the time; between two still times one animation plays. Each animation
// plays once before one plays again, and none follows itself: the rule of
// the home of the site (`mark.next_animation`). Under the heron a band
// names the animation that plays, its frame and its progress, then the
// keys:
//
// - `1` to `9` and `a` to `f` play one animation at once.
// - Space pauses. While the play is paused, `.` shows the next frame, and
//   an animation key shows the first frame of its animation.
// - `s` plays four times slower.
// - `l` shows the lines between the cells, and a white outline around each
//   cell that the frame changed in the still heron: an animation changes a
//   few cells.
// - `z` changes the cell size: 12, 8 or 4 pixels.
// - `g` chooses the way of a move. **On the grid**, the way of the system:
//   the heron takes the forms of `support/mark`, the same drawings as on
//   the home of the site, each in whole square cells, at places in whole
//   cells (`mark.move_pose`, `mark.form_cells`). **Free**, to compare: the
//   frame of the heron is stretched to the box of the form, so its cells
//   become rectangles, and the box goes from a key to the next one pixel
//   by pixel. The way on the grid draws cells; it is not a filter over the
//   free picture.
//
// **The log.** `heron: ok` after the first picture. When an animation that
// a key or a call asked for ends: `heron: dash played: 17 frames, the heron
// left the window and came back, on the grid`, and once, the measure of
// its pictures (`heron: a picture of dash took ... us to draw and damaged
// ... pixels`). When the key `l` or the key `g` changes what the window
// shows: `heron: shows dash at frame 3 of 17, held, on the grid: the form
// run, ...`. An animation of the order of chance writes no line.
//
// **Its grant**: **Serve**, its exports. It needs no other.
//
// **Its exports**: `play`, `animations` and `grid`.
//
// ```
// connect("heron")
// heron.animations()
// heron.play("dash")
// heron.grid(0)
// ```
//
// **What it does not prove.** The time of a picture is a measure of the
// host of the run: no test compares it to a bound.
package heron

import "contract:errors"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:mark"
import "support:random"
import "support:system"

// The stage: the part of the window where the heron stands and moves. It
// is cut in square tiles; each tile is one picture of the window, with a
// generation of its own, so a picture of the heron damages only the tiles
// that it changed (docs/INTERFACE.md, section 2.1).
STAGE_WIDTH :: 640
STAGE_HEIGHT :: 384
TILE :: 32
TILE_COLUMNS :: STAGE_WIDTH / TILE
TILE_ROWS :: STAGE_HEIGHT / TILE
TILE_COUNT :: TILE_COLUMNS * TILE_ROWS
#assert(STAGE_WIDTH % TILE == 0 && STAGE_HEIGHT % TILE == 0)

// The band under the stage: the animation that plays, then the keys.
BAND_HEIGHT :: 104 // The name line, three lines of keys, the line of the controls.
BAND_MARGIN :: 16
WIDTH :: STAGE_WIDTH
HEIGHT :: STAGE_HEIGHT + BAND_HEIGHT

// The sizes of a cell that the key z gives, the largest first.
@(rodata)
cell_sizes := [?]int{12, 8, 4}
CELL_SIZE_MOST :: 12
GROUND_MARGIN :: 16 // Pixels of the stage under the water.
// The highest form of the heron stays inside the stage. A part of the
// heron that a lift takes above the stage is not drawn.
#assert((mark.FORM_ROWS_MOST + mark.WATER_ROWS) * CELL_SIZE_MOST + GROUND_MARGIN <= STAGE_HEIGHT)

// The form picture: the form of the heron that the stage shows, drawn
// once at the cell size in use, with room for the widest and the highest
// form around the place of the natural heron.
FORM_PICTURE_WIDTH :: mark.FORM_COLUMNS_MOST * CELL_SIZE_MOST
FORM_PICTURE_HEIGHT :: mark.FORM_ROWS_MOST * CELL_SIZE_MOST
#assert(mark.FORM_REACH_LEFT + mark.BODY_COLUMNS + mark.FORM_REACH_RIGHT <= mark.FORM_COLUMNS_MOST)
#assert(mark.FORM_REACH_UP + mark.BODY_ROWS <= mark.FORM_ROWS_MOST)

PICTURE_INTERVAL :: 16 // Milliseconds from a picture to the next one while the heron moves: the period of the compositor.
// The most time that the play goes forward from one picture to the next,
// in microseconds. A picture that comes late slows the animation; it never
// skips a part of a move. The shortest frame is longer than this step, so
// each frame is in one picture at least, and the dash has pictures while
// the heron is outside the window.
STEP_MOST :: 40_000
#assert(STEP_MOST < mark.DASH_FRAME_DURATION_LEAST * 1000)
SLOW_FACTOR :: 4 // The play is this many times slower in slow motion.
// The longest time that one picture takes from a still time, in
// microseconds: a day. A longer time is not a still time; the bound keeps
// the time inside the whole numbers of the play.
STILL_STEP_MOST :: 86_400_000_000

COLOR_STAGE :: graphics.COLOR_BACKGROUND
COLOR_LINES :: graphics.COLOR_POINT // The lines between the cells.
COLOR_CHANGED :: graphics.COLOR_WHITE // The outline of a cell that the frame changed in the still heron.

// The color of a pixel of the form picture that no cell covers. A color
// of the mark is 0x00RRGGBB, so no cell has this value.
PICTURE_EMPTY :: graphics.Color(0xFF000000)

// The key of each animation, in the order of mark.Animation.
@(rodata)
animation_keys := [mark.ANIMATION_COUNT]string{"1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"}

// What the heron does now.
State :: enum u8 {
	Still, // It stands, until the still time is over.
	Animation, // One animation plays.
}

state: State
animation: mark.Animation // The animation that plays, or the one that played last.
animation_time: int // Microseconds since the start of the animation.
still_left: int // Microseconds until the next animation.
paused: bool // The play does not go forward.
slow: bool // The play is SLOW_FACTOR times slower.
lines_shown: bool // The stage shows the lines between the cells and the cells that the frame changed.
way: Move_Way // How a move is drawn: on the grid, or free.
cell_size_index: int // The index in cell_sizes of the cell size.
order_memory: mark.Order_Memory // The animations that were played in this round.
program_generator: random.Generator // The numbers of chance of the order and of the still times.

// The animation that plays was asked for by a key or by a call: the log
// gets one line when it ends. These count its pictures.
asked: bool
asked_frames: u32 // One bit for each frame that a picture showed.
asked_ways: u32 // One bit for each way that a picture was drawn in.
asked_left_the_window: bool // A picture had the heron wholly outside the stage.
asked_pictures: u64
asked_draw_time: u64 // Nanoseconds: the sum of the times of its pictures.
asked_damage: u64 // Pixels: the sum of the damage of its pictures.
played_line_waits: bool // The asked animation ended: its line is written after the picture.
measure_line_written: bool // The measure of the pictures is on the log: the program writes it once.
shows_line_waits: bool // A key or a call changed the lines or the way: the line of what the window shows is written after the picture.

// The pixels of the stage, and of the form picture, where a pixel that no
// cell covers is PICTURE_EMPTY. The stage takes the heron from the form
// picture: a picture of a travel copies it, and only a new frame or a new
// form draws it again.
stage_pixels: [STAGE_WIDTH * STAGE_HEIGHT]graphics.Color
stage: graphics.Canvas
form_pixels: [FORM_PICTURE_WIDTH * FORM_PICTURE_HEIGHT]graphics.Color
form_drawn: mark.Form_Cells // The cells of the form that the form picture shows.
frame_cells: mark.Heron_Cells // The cells of the frame on the stage.
tile_generations: [TILE_COUNT]u32
pictures: [TILE_COUNT]graphics.Canvas

// What the stage shows: a picture of the heron draws the stage again only
// when one of these changed.
Scene :: struct {
	drawn:       bool, // The stage was drawn once.
	cell_size:   int,
	frame_key:   int, // The animation and the frame of the cells; 0: the still heron.
	way:         Move_Way,
	form:        mark.Form, // The form of the form picture: the form of the move on the grid, the natural heron in the free way.
	cells_right: int, // On the grid: the place of the heron, in whole cells from its place.
	cells_up:    int,
	body:        interface.Rectangle, // The rectangle of the part of the heron above the water, on the stage.
	lines:       bool,
}
FRAME_KEY_STEP :: 64 // More than the frames of an animation.

shown: Scene
home_body: interface.Rectangle // The rectangle of the natural heron in its place.

// The memory of the interface package for the window (docs/INTERFACE.md):
// one Picture record for each tile, then the records of the band.
records_now, records_before: [TILE_COUNT + 96]interface.Draw_Record
text_now, text_before: [1024]u8
drawing: interface.Window_Drawing

// One row of the table of animations().
Animation_Row :: struct {
	name:     [16]u8, // The name of the animation, as play() takes it.
	frames:   i64, // The count of its frames, the still heron not counted.
	duration: i64, // The time of all its frames, in milliseconds.
	moves:    i64, // 1 when the whole heron moves during the animation, else 0.
}

// play plays one animation of the heron at once, by its name: play("dash").
//
// The animation that plays is replaced. When the asked animation ends, the
// log gets one line, and the order of chance goes on. While the play is
// paused, the window shows the first frame of the animation, and holds it.
//
// - **name**: a name of the first column of [animations](heron.animations), 16 bytes at most. The match is exact.
//
// The result is the count of the frames of the animation. It fails with -1 and an error record: `Absent` when no
// animation has this name; the record names the first argument.
//
// Example, in the console after `connect("heron")`: `heron.play("dash")`.
@(export, link_name = "play")
play :: proc "c" (name: ^string, error: ^errors.Error_Record) -> i64 {
	// One copy: the caller can change the call region during the call.
	wanted: [16]u8
	if len(name^) > len(wanted) {
		return errors.fail(error, -1, .Absent, .None, 1)
	}
	copied := copy(wanted[:], name^)
	asked_animation, found := mark.animation_of_name(string(wanted[:copied]))
	if !found {
		return errors.fail(error, -1, .Absent, .None, 1)
	}
	animation_start(asked_animation, true)
	return i64(mark.animation_frame_count(asked_animation))
}

// animations gives one row for each animation of the heron, in the order of the keys of the window: its name, the count of its frames, its time in milliseconds, and 1 when the whole heron moves during it.
//
// The names, the frames, the times and the moves are the data of `support/mark`: the same as on the home of the site.
//
// - **result**: a table of `Animation_Row` rows that the call fills. A table shorter than the count gets the
//   first rows only; the result still counts every animation.
//
// The result is the count of the animations, 15. It never fails.
@(export, link_name = "animations")
animations :: proc "c" (result: ^[]Animation_Row) -> i64 {
	for candidate, index in mark.Animation {
		if index >= len(result^) {
			break
		}
		row := &result[index]
		row^ = {
			frames   = i64(mark.animation_frame_count(candidate)),
			duration = i64(mark.animation_duration(candidate)),
			moves    = i64(mark.animation_moves(candidate)),
		}
		copy(row.name[:len(row.name) - 1], mark.animation_names[candidate])
	}
	return mark.ANIMATION_COUNT
}

// grid chooses the way of a move of the heron: grid(1) is on the grid, grid(0) is free.
//
// On the grid, the heron takes the drawn forms of the mark, in whole square cells, at places in whole cells:
// the way of the system, and the way of the window at its start. Free, the frame of the heron is stretched to
// the box of the form and is at any pixel: its cells are rectangles. The key `g` of the window does the same.
// The log gets one line that says what the window shows.
//
// - **on**: 0 for the free way; another number for the way on the grid.
//
// The result is 1 when the way is on the grid, else 0. It never fails.
@(export, link_name = "grid")
grid :: proc "c" (on: i64) -> i64 {
	way = .Free
	if on != 0 {
		way = .On_The_Grid
	}
	shows_line_waits = true
	return i64(way == .On_The_Grid)
}

// chance gives a whole number of chance from the random generator of the
// program, for the order of the animations and for a still time.
chance :: proc "contextless" () -> u32 {
	return u32(random.next_u64(&program_generator))
}

// animation_start starts an animation at its first frame. by_request: a
// key or a call asked for it, so its pictures are counted and its end is
// on the log; it does not enter the memory of the order of chance.
animation_start :: proc "contextless" (wanted: mark.Animation, by_request: bool) {
	state = .Animation
	animation = wanted
	animation_time = 0
	asked = by_request
	asked_frames = 0
	asked_ways = 0
	asked_left_the_window = false
	asked_pictures = 0
	asked_draw_time = 0
	asked_damage = 0
	played_line_waits = false
}

// still_start makes the heron stand for a still time of chance.
still_start :: proc "contextless" () {
	state = .Still
	still_left = mark.still_time(chance()) * 1000
}

// animation_end ends the animation that plays: the heron stands again.
animation_end :: proc "contextless" () {
	played_line_waits = asked
	still_start()
}

// frame_now gives the frame that the animation shows now, from 1; 0 while
// the heron is still.
frame_now :: proc "contextless" () -> int {
	if state != .Animation {
		return 0
	}
	frame, _ := mark.animation_frame_at(animation, animation_time / 1000)
	return frame
}

// advance moves the play forward by the time since the last picture, in
// nanoseconds. A still time takes the whole time. An animation takes
// STEP_MOST at most, so a late picture never skips a part of a move.
advance :: proc "contextless" (elapsed: u64) {
	if paused {
		return
	}
	switch state {
	case .Still:
		step := int(min(elapsed / 1000, STILL_STEP_MOST))
		if slow {
			step /= SLOW_FACTOR
		}
		still_left -= max(step, 1)
		if still_left <= 0 {
			animation_start(mark.Animation(mark.next_animation(&order_memory, chance())), false)
		}
	case .Animation:
		step := int(min(elapsed / 1000, STEP_MOST))
		if slow {
			step /= SLOW_FACTOR
		}
		animation_time += step
		if animation_time / 1000 >= mark.animation_duration(animation) {
			animation_end()
		}
	}
}

// frame_step shows the next frame of the animation that is held, while
// the play is paused. After the last frame the heron stands.
frame_step :: proc "contextless" () {
	if !paused || state != .Animation {
		return
	}
	frame := frame_now()
	if frame >= mark.animation_frame_count(animation) {
		// The reader went through the frames by hand: the animation did
		// not play, so its end writes no line.
		asked = false
		animation_end()
		return
	}
	animation_time = mark.animation_frame_start(animation, frame + 1) * 1000
}

// key_take does what a key of the window asks.
key_take :: proc "contextless" (character: u8) {
	switch {
	case character >= '1' && character <= '9':
		animation_start(mark.Animation(character - '1'), true)
	case character >= 'a' && character <= 'f':
		animation_start(mark.Animation(9 + character - 'a'), true)
	case character == ' ':
		paused = !paused
	case character == '.':
		frame_step()
	case character == 's':
		slow = !slow
	case character == 'l':
		lines_shown = !lines_shown
		shows_line_waits = true
	case character == 'g':
		way = way == .On_The_Grid ? Move_Way.Free : Move_Way.On_The_Grid
		shows_line_waits = true
	case character == 'z':
		cell_size_index = (cell_size_index + 1) % len(cell_sizes)
	}
}
// The keys 1 to 9 and a to f name each animation.
#assert(mark.ANIMATION_COUNT == 15)

// stage_rectangle_clear paints a rectangle of the stage with its
// background, and gives a new generation to each tile that it touches: the
// window draws these tiles again.
stage_rectangle_clear :: proc "contextless" (rectangle: interface.Rectangle) {
	cut := interface.intersection(rectangle, {0, 0, STAGE_WIDTH, STAGE_HEIGHT})
	if interface.empty(cut) {
		return
	}
	graphics.fill(stage, cut.left, cut.top, cut.right - cut.left, cut.bottom - cut.top, COLOR_STAGE)
	for row in cut.top / TILE ..= (cut.bottom - 1) / TILE {
		for column in cut.left / TILE ..= (cut.right - 1) / TILE {
			tile_generations[row * TILE_COLUMNS + column] += 1
		}
	}
}

// form_picture_draw draws a form of a frame into the form picture, at a
// cell size: the drawing of support/mark, with the top left corner of the
// natural heron at the reach of the forms from the corner of the picture.
form_picture_draw :: proc "contextless" (form: mark.Form, frame, cell: int) {
	picture := graphics.Canvas{pixels = raw_data(form_pixels[:]), width = mark.FORM_COLUMNS_MOST * cell, height = mark.FORM_ROWS_MOST * cell, stride = FORM_PICTURE_WIDTH}
	graphics.fill(picture, 0, 0, picture.width, picture.height, PICTURE_EMPTY)
	form_drawn, _ = mark.form_cells(form, animation, frame)
	mark.form_cells_draw(picture, &form_drawn, mark.FORM_REACH_LEFT * cell, mark.FORM_REACH_UP * cell, cell, false)
}

// form_picture_part gives a rectangle of cells of the form picture as a
// canvas: column and row are from the corner of the natural heron.
form_picture_part :: proc "contextless" (column, row, columns, rows, cell: int) -> graphics.Canvas {
	return {pixels = raw_data(form_pixels[((mark.FORM_REACH_UP + row) * FORM_PICTURE_WIDTH + mark.FORM_REACH_LEFT + column) * cell:]), width = columns * cell, height = rows * cell, stride = FORM_PICTURE_WIDTH}
}

// covered_pixels_copy copies the pixels of a picture that a cell covers to
// a place of the stage. Nothing is written outside the stage.
covered_pixels_copy :: proc "contextless" (x, y: int, picture: graphics.Canvas) {
	cut := interface.intersection({x, y, x + picture.width, y + picture.height}, {0, 0, STAGE_WIDTH, STAGE_HEIGHT})
	if interface.empty(cut) {
		return
	}
	for line in cut.top ..< cut.bottom {
		source_line := picture.pixels[(line - y) * picture.stride:]
		target_line := stage.pixels[line * stage.stride:]
		for column in cut.left ..< cut.right {
			if color := source_line[column - x]; color != PICTURE_EMPTY {
				target_line[column] = color
			}
		}
	}
}

// water_draw draws the two rows of the water of the frame, which no move
// takes, at their place.
water_draw :: proc "contextless" (water: interface.Rectangle, cell: int) {
	first_line := mark.BODY_ROWS * cell
	for y in 0 ..< water.bottom - water.top {
		for x in 0 ..< water.right - water.left {
			if color, covered := mark.cells_pixel(&frame_cells, cell, x, first_line + y, false); covered {
				graphics.pixel(stage, water.left + x, water.top + y, color)
			}
		}
	}
}

// stage_draw draws the heron of this moment on the stage, when the stage
// does not show it yet. On the grid it asks support/mark for the form and
// the place of the heron at this time, and copies the drawing of that
// form to that place: whole cells at a place in whole cells. In the free
// way it stretches the natural form of the frame to the box of this time.
// It clears the rectangle where the part above the water was and the
// rectangle where it is now. The water is drawn again only when a cell
// changed. A new cell size draws the whole stage.
stage_draw :: proc "contextless" () {
	cell := cell_sizes[cell_size_index]
	size := mark.heron_size(cell)
	home_left := (STAGE_WIDTH - size) / 2
	water_height := mark.WATER_ROWS * cell
	water_top := STAGE_HEIGHT - GROUND_MARGIN - water_height
	natural_top := water_top - mark.BODY_ROWS * cell
	home_body = {home_left, natural_top, home_left + size, water_top}
	// How far the dash goes: until the widest form is outside the stage.
	travel := mark.Move_Travel {
		cells_to_right_edge = (STAGE_WIDTH - home_left + cell - 1) / cell + mark.FORM_REACH_LEFT,
		cells_to_left_edge  = (home_left + cell - 1) / cell + mark.BODY_COLUMNS + mark.FORM_REACH_RIGHT,
	}
	now := Scene{drawn = true, cell_size = cell, way = way, lines = lines_shown}
	frame := frame_now()
	// A time before the first key: the natural heron in its place.
	at := -1
	if frame > 0 {
		at = animation_time / 1000
		now.frame_key = (int(animation) + 1) * FRAME_KEY_STEP + frame
	}
	if way == .On_The_Grid {
		pose := mark.move_pose(animation, at, travel)
		columns, rows := mark.form_size(pose.form)
		left := home_left + (mark.form_first_column(pose.form) + pose.cells_right) * cell
		top := natural_top + (mark.form_first_row(pose.form) - pose.cells_up) * cell
		now.form = pose.form
		now.cells_right = pose.cells_right
		now.cells_up = pose.cells_up
		now.body = {left, top, left + columns * cell, top + rows * cell}
	} else {
		box := free_box_at(animation, at, travel, cell)
		now.form = .Natural
		now.body = {home_left + box.left, natural_top + box.top, home_left + box.left + box.width, natural_top + box.top + box.height}
	}
	if now == shown {
		return
	}
	whole := !shown.drawn || shown.cell_size != cell
	cells_changed := whole || now.frame_key != shown.frame_key
	if cells_changed {
		frame_cells, _ = mark.animation_frame_cells(animation, frame)
	}
	if cells_changed || now.form != shown.form {
		form_picture_draw(now.form, frame, cell)
	}
	water := interface.Rectangle{home_left, water_top, home_left + size, water_top + water_height}
	water_drawn := cells_changed || now.lines != shown.lines
	if whole {
		stage_rectangle_clear({0, 0, STAGE_WIDTH, STAGE_HEIGHT})
	} else {
		stage_rectangle_clear(shown.body)
		stage_rectangle_clear(now.body)
		if water_drawn {
			stage_rectangle_clear(water)
		}
	}
	if now.way == .On_The_Grid {
		covered_pixels_copy(now.body.left, now.body.top, form_picture_part(form_drawn.first_column, form_drawn.first_row, form_drawn.columns, form_drawn.rows, cell))
	} else {
		free_draw(stage, form_picture_part(0, 0, mark.BODY_COLUMNS, mark.BODY_ROWS, cell), now.body, PICTURE_EMPTY)
	}
	if water_drawn {
		water_draw(water, cell)
	}
	if now.lines {
		lines_draw(now.body, water, cell, now.way, now.form, water_drawn)
	}
	shown = now
}

// lines_draw draws the lines between the cells over the heron, and a white
// outline around each cell that the frame changed in the still heron. On
// the grid the lines are the grid itself: each cell of the form is a
// square, and a cell of the form shows a cell of the frame
// (mark.form_source_column, mark.form_source_row). In the free way the
// lines follow the edges of the cells of the frame as they are drawn
// (scaled_cell_edge): the cells are rectangles.
lines_draw :: proc "contextless" (body, water: interface.Rectangle, cell: int, drawn_way: Move_Way, form: mark.Form, with_water: bool) {
	width, height := body.right - body.left, body.bottom - body.top
	columns, rows := mark.BODY_COLUMNS, mark.BODY_ROWS
	// The left edge of each column and the top edge of each row, in pixels
	// from the corner of the rectangle, and the cell of the frame that each
	// one shows.
	column_edges: [mark.FORM_COLUMNS_MOST + 1]int
	row_edges: [mark.FORM_ROWS_MOST + 1]int
	column_sources: [mark.FORM_COLUMNS_MOST]int
	row_sources: [mark.FORM_ROWS_MOST]int
	if drawn_way == .On_The_Grid {
		columns = min(width / cell, mark.FORM_COLUMNS_MOST)
		rows = min(height / cell, mark.FORM_ROWS_MOST)
	} else if width < columns || height < rows {
		return
	}
	for column in 0 ..= columns {
		column_edges[column] = drawn_way == .On_The_Grid ? column * cell : scaled_cell_edge(column, columns, width)
	}
	for row in 0 ..= rows {
		row_edges[row] = drawn_way == .On_The_Grid ? row * cell : scaled_cell_edge(row, rows, height)
	}
	for column in 0 ..< columns {
		column_sources[column] = column
		if drawn_way == .On_The_Grid {
			column_sources[column], _ = mark.form_source_column(form, column)
		}
		graphics.fill(stage, body.left + column_edges[column], body.top, 1, height, COLOR_LINES)
	}
	graphics.fill(stage, body.right - 1, body.top, 1, height, COLOR_LINES)
	for row in 0 ..< rows {
		row_sources[row] = row
		if drawn_way == .On_The_Grid {
			row_sources[row], _ = mark.form_source_row(form, row)
		}
		graphics.fill(stage, body.left, body.top + row_edges[row], width, 1, COLOR_LINES)
	}
	graphics.fill(stage, body.left, body.bottom - 1, width, 1, COLOR_LINES)
	still := mark.still_cells()
	for row in 0 ..< rows {
		for column in 0 ..< columns {
			if frame_cells[row_sources[row]][column_sources[column]] == still[row_sources[row]][column_sources[column]] {
				continue
			}
			graphics.outline(stage, body.left + column_edges[column], body.top + row_edges[row], column_edges[column + 1] - column_edges[column], row_edges[row + 1] - row_edges[row], 1, COLOR_CHANGED)
		}
	}
	if !with_water {
		return
	}
	// The rows of the water never move: their cells have the cell size.
	for column in 0 ..< mark.BODY_COLUMNS {
		graphics.fill(stage, water.left + column * cell, water.top, 1, water.bottom - water.top, COLOR_LINES)
	}
	graphics.fill(stage, water.right - 1, water.top, 1, water.bottom - water.top, COLOR_LINES)
	for row in 0 ..< mark.WATER_ROWS {
		graphics.fill(stage, water.left, water.top + row * cell, water.right - water.left, 1, COLOR_LINES)
	}
	graphics.fill(stage, water.left, water.bottom - 1, water.right - water.left, 1, COLOR_LINES)
	for row in 0 ..< mark.WATER_ROWS {
		for column in 0 ..< mark.BODY_COLUMNS {
			if frame_cells[mark.BODY_ROWS + row][column] != still[mark.BODY_ROWS + row][column] {
				graphics.outline(stage, water.left + column * cell, water.top + row * cell, cell, cell, 1, COLOR_CHANGED)
			}
		}
	}
}

// changed_cells gives the count of the cells of the frame on the stage
// that differ from the still heron.
changed_cells :: proc "contextless" () -> int {
	still := mark.still_cells()
	return mark.cells_differ_count(&frame_cells, &still)
}

// band_key draws one key of the band and what it does, in a color: the
// color of a state that runs for a key whose state is on.
band_key :: proc "contextless" (table: ^interface.Draw_Table, x, y: int, key, text: string, color: graphics.Color) {
	after := interface.draw_text(table, x, y, key, graphics.COLOR_TEXT)
	interface.draw_text(table, after + 8, y, text, color)
}

// state_color gives the color of the text of a key of the band: the color
// of a state that runs when its state is on, else the dim color.
state_color :: proc "contextless" (on: bool) -> graphics.Color {
	return graphics.Color(on ? graphics.COLOR_PROGRAM : graphics.COLOR_DIM)
}

// way_text gives the plain words of the way of a move.
way_text :: proc "contextless" (which: Move_Way) -> string {
	return which == .On_The_Grid ? "on the grid" : "free"
}

// The band is in the font of the cells, in both settings of the font: 8
// pixels for each character. Each text of the band has a box that holds
// its longest value at that width.
BAND_CHARACTER :: 8
// Five keys in a line: with eight, the longest name ended half a character
// before the next key, and the two read as one word ("scratch8").
KEYS_IN_A_LINE :: 5
KEY_LINES :: (len(mark.Animation) + KEYS_IN_A_LINE - 1) / KEYS_IN_A_LINE
KEY_COLUMN :: (WIDTH - 2 * BAND_MARGIN) / KEYS_IN_A_LINE
NAME_LONGEST :: 7 // "scratch", "stretch": the longest name of an animation.
FRAME_TEXT_X :: 96
FRAME_TEXT_LONGEST :: 14 // "frame 17 of 17".
PROGRESS_X :: 224
// A key of an animation, a gap, and the longest name fit a column, with two
// characters or more before the next key.
#assert((1 + 1 + NAME_LONGEST + 2) * BAND_CHARACTER <= KEY_COLUMN)
// The name of the animation ends before the text of the frame, and that
// text before the bar of the progress.
#assert(BAND_MARGIN + NAME_LONGEST * BAND_CHARACTER + BAND_CHARACTER <= FRAME_TEXT_X)
#assert(FRAME_TEXT_X + FRAME_TEXT_LONGEST * BAND_CHARACTER + BAND_CHARACTER <= PROGRESS_X)
// The keys of the play: the place of each, and the characters of its key,
// its gap and its longest text. Each ends 8 pixels before the next one,
// and the last one before the margin.
CONTROL_PAUSE_X :: 16 // "space pause": 11 characters.
CONTROL_FRAME_X :: 120 // ". next frame": 12.
CONTROL_SLOW_X :: 232 // "s slow": 6.
CONTROL_LINES_X :: 296 // "l lines": 7.
CONTROL_CELL_X :: 368 // "z cell 12": 9.
CONTROL_WAY_X :: 456 // "g on the grid": 13.
#assert(CONTROL_PAUSE_X + 12 * BAND_CHARACTER <= CONTROL_FRAME_X)
#assert(CONTROL_FRAME_X + 13 * BAND_CHARACTER <= CONTROL_SLOW_X)
#assert(CONTROL_SLOW_X + 7 * BAND_CHARACTER <= CONTROL_LINES_X)
#assert(CONTROL_LINES_X + 8 * BAND_CHARACTER <= CONTROL_CELL_X)
#assert(CONTROL_CELL_X + 10 * BAND_CHARACTER <= CONTROL_WAY_X)
#assert(CONTROL_WAY_X + 13 * BAND_CHARACTER <= WIDTH - BAND_MARGIN)

// band_draw builds the band under the stage: the animation that plays, its
// frame and its progress, the key of each animation, and the keys of the
// play with their states.
band_draw :: proc "contextless" (frame: ^interface.Frame) {
	table := frame.table
	interface.draw_rectangle(table, 0, STAGE_HEIGHT, WIDTH, 1, graphics.COLOR_TRACK)
	playing := state == .Animation
	y := STAGE_HEIGHT + 8
	interface.draw_text(table, BAND_MARGIN, y, playing ? mark.animation_names[animation] : "still", graphics.COLOR_TEXT, interface.FONT_BOLD)
	builder: interface.Text_Builder
	progress, whole: u64 = 0, 1
	if playing {
		interface.text_put(&builder, "frame ")
		interface.text_put_number(&builder, u64(frame_now()))
		interface.text_put(&builder, " of ")
		interface.text_put_number(&builder, u64(mark.animation_frame_count(animation)))
		interface.draw_text(table, FRAME_TEXT_X, y, interface.text_of(&builder), graphics.COLOR_DIM)
		progress, whole = u64(animation_time / 1000), u64(mark.animation_duration(animation))
	}
	interface.bar(frame, {PROGRESS_X, y + 4, WIDTH - PROGRESS_X - BAND_MARGIN, 8}, progress, whole, graphics.COLOR_KERNEL)
	y += interface.LINE + 8
	for name, index in animation_keys {
		band_key(table, BAND_MARGIN + index % KEYS_IN_A_LINE * KEY_COLUMN, y + index / KEYS_IN_A_LINE * interface.LINE, name, mark.animation_names[mark.Animation(index)], state_color(playing && int(animation) == index))
	}
	y += KEY_LINES * interface.LINE + 4
	band_key(table, CONTROL_PAUSE_X, y, "space", "pause", state_color(paused))
	band_key(table, CONTROL_FRAME_X, y, ".", "next frame", graphics.COLOR_DIM)
	band_key(table, CONTROL_SLOW_X, y, "s", "slow", state_color(slow))
	band_key(table, CONTROL_LINES_X, y, "l", "lines", state_color(lines_shown))
	builder.count = 0
	interface.text_put(&builder, "cell ")
	interface.text_put_number(&builder, u64(cell_sizes[cell_size_index]))
	band_key(table, CONTROL_CELL_X, y, "z", interface.text_of(&builder), graphics.COLOR_DIM)
	// The way of a move is one of two states, and each has its words.
	band_key(table, CONTROL_WAY_X, y, "g", way_text(way), graphics.Color(way == .On_The_Grid ? graphics.COLOR_PROGRAM : graphics.COLOR_BOOT_PROGRAM))
}

// damage_pixels gives the count of the pixels of the damage rectangles of
// the last frame of the window.
damage_pixels :: proc "contextless" (count: int) -> u64 {
	total: u64
	for rectangle in drawing.damage.rectangles[:clamp(count, 0, len(drawing.damage.rectangles))] {
		cut := interface.intersection(rectangle, {0, 0, WIDTH, HEIGHT})
		if !interface.empty(cut) {
			total += u64(cut.right - cut.left) * u64(cut.bottom - cut.top)
		}
	}
	return total
}

// played_line_write writes the line of an asked animation that ended: the
// frames that its pictures showed, what the heron did, and the way of its
// pictures. The measure of its pictures follows once: the mean time of a
// picture and the mean damage, which no test compares to a bound.
played_line_write :: proc "contextless" () {
	name := mark.animation_names[animation]
	frames: u64
	for bit in 0 ..< 32 {
		frames += u64(asked_frames >> uint(bit) & 1)
	}
	what := ""
	if mark.animation_moves(animation) {
		back := shown.body == home_body
		switch {
		case asked_left_the_window && back:
			what = ", the heron left the window and came back"
		case back:
			what = ", the heron moved and came back to its place"
		case:
			what = ", the heron is not back in its place"
		}
	}
	ways := ", on the grid and free"
	if asked_ways == u32(1) << u32(Move_Way.On_The_Grid) {
		ways = ", on the grid"
	} else if asked_ways == u32(1) << u32(Move_Way.Free) {
		ways = ", free"
	}
	system.log("heron: ", name, " played: ", frames, " frames", what, ways)
	if measure_line_written || asked_pictures == 0 {
		return
	}
	measure_line_written = true
	mean := asked_draw_time / asked_pictures
	system.log("heron: a picture of ", name, " took ", mean / 1000, ".", mean / 100 % 10, " us to draw and damaged ", asked_damage / asked_pictures, " pixels of the ", u64(WIDTH * HEIGHT), " of the window, the means of ", asked_pictures, " pictures (a measure)")
}

// shows_line_write writes the line of what the window shows, after a
// change of the lines or of the way. Each value of the line is what the
// program drew: the animation and its frame, whether the play holds it,
// the way with the form and the place of support/mark or with the size of
// the stretched frame, the lines, and the cells that the frame changed.
shows_line_write :: proc "contextless" () {
	lines := lines_shown ? "shown" : "hidden"
	if state != .Animation {
		system.log("heron: shows the still heron, ", way_text(shown.way), "; the lines of the cells ", lines)
		return
	}
	held := paused ? ", held" : ""
	changed := u64(changed_cells())
	if shown.way == .On_The_Grid {
		side := shown.cells_right < 0 ? " cells to the left and " : " cells to the right and "
		system.log("heron: shows ", mark.animation_names[animation], " at frame ", u64(frame_now()), " of ", u64(mark.animation_frame_count(animation)), held, ", on the grid: the form ", mark.form_names[shown.form], ", ", u64(abs(shown.cells_right)), side, u64(max(shown.cells_up, 0)), " up; the lines of the cells ", lines, "; ", changed, " cells of the frame differ from the still heron")
		return
	}
	system.log("heron: shows ", mark.animation_names[animation], " at frame ", u64(frame_now()), " of ", u64(mark.animation_frame_count(animation)), held, ", free: the frame stretched to ", u64(max(shown.body.right - shown.body.left, 0)), " by ", u64(max(shown.body.bottom - shown.body.top, 0)), " pixels; the lines of the cells ", lines, "; ", changed, " cells of the frame differ from the still heron")
}

// entry opens the window and plays the animations until the program is
// stopped.
//
// **The loop**: it runs the calls of its exports, takes the keys of the
// window, moves the play forward by the time since the last picture, draws
// the stage when the heron changed, and builds the window: one picture for
// each tile of the stage, then the band. The interface package draws again
// only the tiles and the texts that changed. The loop then waits for a key,
// a call, the next picture of an animation, or the end of the still time
// (with no end while paused). With no random seed or no window, it stops
// with the code 1.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	if !random.generator_from_context(&program_generator, ctx) {
		system.log("heron: no random seed in the context")
		system.stop(1)
	}
	service, _ := system.service_open(ctx)
	window, ok := display.open(ctx, WIDTH, HEIGHT, "heron")
	if !ok {
		system.stop(1)
	}
	stage = {pixels = raw_data(stage_pixels[:]), width = STAGE_WIDTH, height = STAGE_HEIGHT, stride = STAGE_WIDTH}
	for &picture, index in pictures {
		picture = graphics.view(stage, index % TILE_COLUMNS * TILE, index / TILE_COLUMNS * TILE, TILE, TILE)
	}
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	drawing.now.pictures = pictures[:]
	drawing.before.pictures = pictures[:]
	order_memory = mark.ORDER_MEMORY_EMPTY
	still_start()
	last := system.nanoseconds()
	logged := false
	for {
		system.service_run(&service)
		for event in display.next_event(&window) {
			#partial switch event.kind {
			case .Key:
				if event.pressed {
					key_take(event.character)
				}
			case .Settings_Changed:
				// A new font: each text of the band is drawn again.
				interface.draw_whole_window_next(&drawing)
			}
		}
		start := system.nanoseconds()
		advance(start - last)
		last = start
		counted := state == .Animation && asked && !paused
		stage_draw()
		frame := interface.window_frame_begin(&drawing, &window)
		for generation, index in tile_generations {
			interface.draw_picture(frame.table, index % TILE_COLUMNS * TILE, index / TILE_COLUMNS * TILE, index, generation)
		}
		band_draw(&frame)
		damage_count := interface.window_frame_end(&drawing, &frame, &window)
		if counted {
			asked_pictures += 1
			asked_draw_time += system.nanoseconds() - start
			asked_damage += damage_pixels(damage_count)
			asked_frames |= u32(1) << uint(frame_now())
			asked_ways |= u32(1) << u32(shown.way)
			if shown.body.left >= STAGE_WIDTH || shown.body.right <= 0 {
				asked_left_the_window = true
			}
		}
		if !logged {
			system.log("heron: ok")
			logged = true
		}
		if played_line_waits {
			played_line_waits = false
			played_line_write()
		}
		if shows_line_waits {
			shows_line_waits = false
			shows_line_write()
		}
		deadline: u64 = system.WAIT_FOREVER
		if !paused {
			if state == .Animation {
				deadline = system.time() + PICTURE_INTERVAL
			} else {
				factor: u64 = slow ? SLOW_FACTOR : 1
				deadline = system.time() + u64(max(still_left, 0)) * factor / 1000 + 1
			}
		}
		wait: system.Wait
		display.wait_events(&wait, &window)
		system.service_wait(&wait, &service)
		system.wait_end(&wait, deadline)
	}
}
