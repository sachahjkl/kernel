#+build !freestanding
package mark

import "core:testing"
import "support:graphics"

// Each change is inside the grid, names a part or an empty cell, belongs to
// a frame of the table, changes its cell (a change to the letter that the
// cell has already is a fault of the table), and no frame changes one cell
// two times.
@(test)
every_change_is_a_cell_of_the_grid :: proc(t: ^testing.T) {
	for change, index in animation_changes {
		testing.expectf(t, int(change.column) < HERON_GRID_SIZE && int(change.row) < HERON_GRID_SIZE, "change %d: the cell %d, %d is outside the grid", index, change.column, change.row)
		_, is_part := part_of_letter(change.letter)
		testing.expectf(t, change.letter == '.' || is_part, "change %d: the letter %c is not a part", index, change.letter)
		row, found := animation_frame(change.animation, int(change.frame))
		testing.expectf(t, found, "change %d: %v has no frame %d", index, change.animation, change.frame)
		if !found || int(change.column) >= HERON_GRID_SIZE || int(change.row) >= HERON_GRID_SIZE {
			continue
		}
		base, base_found := animation_frame_cells(change.animation, int(row.base_frame))
		testing.expect(t, base_found)
		testing.expectf(t, base[change.row][change.column] != change.letter, "change %d: the cell %d, %d of %v frame %d has that letter already", index, change.column, change.row, change.animation, change.frame)
		for other in animation_changes[index + 1:] {
			same_cell := other.animation == change.animation && other.frame == change.frame && other.column == change.column && other.row == change.row
			testing.expectf(t, !same_cell, "change %d: %v frame %d changes the cell %d, %d two times", index, change.animation, change.frame, change.column, change.row)
		}
	}
}

// The frames of each animation are 1, 2, ... in the order of the table, and
// each base frame is an earlier frame.
@(test)
frames_are_numbered_in_order :: proc(t: ^testing.T) {
	for animation in Animation {
		expected := 1
		for row in animation_frames {
			if row.animation != animation {
				continue
			}
			testing.expectf(t, int(row.frame) == expected, "%v: the frame %d comes where the frame %d is expected", animation, row.frame, expected)
			testing.expectf(t, row.base_frame < row.frame, "%v frame %d: the base frame %d is not earlier", animation, row.frame, row.base_frame)
			expected += 1
		}
		testing.expectf(t, expected > 1, "%v has no frame", animation)
		testing.expect_value(t, animation_frame_count(animation), expected - 1)
		testing.expectf(t, animation_names[animation] != "", "%v has no name", animation)
	}
}

// Each animation starts at the still heron and ends at it: frame 0 is the
// still heron, the first and the last frame move a few cells, and no step of
// the play (still, the frames, still) changes more than the limit of its
// animation. No frame is further from the still heron than that limit either.
@(test)
each_animation_starts_and_ends_at_the_still_heron :: proc(t: ^testing.T) {
	still := still_cells()
	for animation in Animation {
		start, start_found := animation_frame_cells(animation, 0)
		testing.expect(t, start_found)
		testing.expectf(t, cells_differ_count(&start, &still) == 0, "%v: frame 0 is not the still heron", animation)
		count := animation_frame_count(animation)
		_, past_found := animation_frame_cells(animation, count + 1)
		testing.expectf(t, !past_found, "%v has a frame past its last", animation)
		previous := still
		for frame in 1 ..= count {
			cells, found := animation_frame_cells(animation, frame)
			testing.expectf(t, found, "%v: no frame %d", animation, frame)
			from_still := cells_differ_count(&cells, &still)
			step := cells_differ_count(&cells, &previous)
			testing.expectf(t, from_still <= animation_change_limits[animation], "%v frame %d: %d cells from the still heron; at most %d", animation, frame, from_still, animation_change_limits[animation])
			testing.expectf(t, step <= animation_change_limits[animation], "%v frame %d: %d cells from the frame before; at most %d", animation, frame, step, animation_change_limits[animation])
			if frame == 1 || frame == count {
				testing.expectf(t, from_still > 0, "%v: the frame %d does not move", animation, frame)
			}
			previous = cells
		}
		back := cells_differ_count(&previous, &still)
		testing.expectf(t, back <= animation_change_limits[animation], "%v: %d cells from the last frame back to the still heron; at most %d", animation, back, animation_change_limits[animation])
	}
	// Pinned: the blink closes the eye, and nothing else.
	blink, _ := animation_frame_cells(.Blink, 1)
	testing.expect_value(t, blink[2][17], u8('h'))
	testing.expect_value(t, cells_differ_count(&blink, &still), 1)
}

// The durations are in their range: each frame between the shortest frame
// of its animation and the longest frame, each animation under its limit.
// Only the dash has frames shorter than the common shortest frame.
@(test)
durations_are_in_range :: proc(t: ^testing.T) {
	for row in animation_frames {
		duration := int(row.duration_milliseconds)
		least := animation_frame_duration_least[row.animation]
		testing.expectf(t, duration >= least && duration <= FRAME_DURATION_MOST, "%v frame %d: %d ms", row.animation, row.frame, duration)
	}
	for animation in Animation {
		total := animation_duration(animation)
		testing.expectf(t, total > 0 && total <= ANIMATION_DURATION_MOST, "%v: %d ms in all", animation, total)
		least := animation_frame_duration_least[animation]
		if animation == .Dash {
			testing.expect_value(t, least, DASH_FRAME_DURATION_LEAST)
		} else {
			testing.expectf(t, least == FRAME_DURATION_LEAST, "%v has the shortest frame %d ms, not the common %d", animation, least, FRAME_DURATION_LEAST)
		}
	}
}

// The still frame through cells_pixel is the still heron of mark_pixel, and
// cells_draw writes the pixels of cells_pixel and nothing outside the canvas.
@(test)
frame_pixels_are_the_pixels_of_the_mark :: proc(t: ^testing.T) {
	still := still_cells()
	backgrounds := [2]bool{false, true}
	for on_light in backgrounds {
		for y in 0 ..< heron_size(2) {
			for x in 0 ..< heron_size(2) {
				frame_color, frame_covered := cells_pixel(&still, 2, x, y, .Smooth, on_light)
				still_color, still_covered := mark_pixel(2, x, y, .Smooth, on_light)
				if frame_color != still_color || frame_covered != still_covered {
					testing.expectf(t, false, "pixel %d, %d differs from mark_pixel", x, y)
					return
				}
			}
		}
	}
	_, refused := cells_pixel(&still, CELL_SIZE_LIMIT + 1, 0, 0, .Smooth, false)
	testing.expect(t, !refused)
	look, _ := animation_frame_cells(.Look, 1)
	SIDE :: 64
	VIEW_LEFT :: 8
	VIEW_SIDE :: 40
	buffer: [SIDE * SIDE]graphics.Color
	for &pixel in buffer {
		pixel = DRAW_TEST_SENTINEL
	}
	view := graphics.Canvas{pixels = ([^]graphics.Color)(&buffer[VIEW_LEFT * SIDE + VIEW_LEFT]), width = VIEW_SIDE, height = VIEW_SIDE, stride = SIDE}
	PLACE_X :: -9
	PLACE_Y :: 3
	cells_draw(view, &look, PLACE_X, PLACE_Y, 2, .Smooth, false)
	for y in 0 ..< SIDE {
		for x in 0 ..< SIDE {
			expected := DRAW_TEST_SENTINEL
			if x >= VIEW_LEFT && x < VIEW_LEFT + VIEW_SIDE && y >= VIEW_LEFT && y < VIEW_LEFT + VIEW_SIDE {
				if color, covered := cells_pixel(&look, 2, x - VIEW_LEFT - PLACE_X, y - VIEW_LEFT - PLACE_Y, .Smooth, false); covered {
					expected = color
				}
			}
			if buffer[y * SIDE + x] != expected {
				testing.expectf(t, false, "pixel %d, %d of the buffer: 0x%06X, not 0x%06X", x, y, buffer[y * SIDE + x], expected)
				return
			}
		}
	}
}

// A frame that an animation does not have is not found.
@(test)
a_frame_that_does_not_exist :: proc(t: ^testing.T) {
	_, found := animation_frame_cells(.Blink, 2)
	testing.expect(t, !found)
	_, found = animation_frame_cells(.Blink, -1)
	testing.expect(t, !found)
	_, found = animation_frame_cells(.Dip, 1000)
	testing.expect(t, !found)
}

// Each animation has its limit of changed cells in the data. Only the preen
// and the dash are above the common limit, and their limits are stated.
@(test)
the_limit_of_each_animation :: proc(t: ^testing.T) {
	for animation in Animation {
		limit := animation_change_limits[animation]
		#partial switch animation {
		case .Preen:
			testing.expect_value(t, limit, PREEN_FRAME_CHANGE_LIMIT)
		case .Dash:
			testing.expect_value(t, limit, DASH_FRAME_CHANGE_LIMIT)
		case:
			testing.expectf(t, limit == FRAME_CHANGE_LIMIT, "%v has the limit %d, not the common %d", animation, limit, FRAME_CHANGE_LIMIT)
		}
	}
}

// Pinned frames of the animations that share a pose, or that the place that
// plays them cuts at the line of the water: the wind-up of the dash and the
// gathering of the hop are poses of the leg animation; the landing of the
// hop is the ripple; the doze and the stretch start as the blink; a frame
// in which the heron leaves the water has no foot in the two rows of the
// water, and the water is whole there.
@(test)
new_animations_pinned_cells :: proc(t: ^testing.T) {
	still := still_cells()
	knee_in, _ := animation_frame_cells(.Leg, 2)
	wind_up, _ := animation_frame_cells(.Dash, 1)
	testing.expect_value(t, cells_differ_count(&wind_up, &knee_in), 0)
	knee_half_in, _ := animation_frame_cells(.Leg, 1)
	gather, _ := animation_frame_cells(.Hop, 1)
	testing.expect_value(t, cells_differ_count(&gather, &knee_half_in), 0)
	for frame in 1 ..= 2 {
		wave, _ := animation_frame_cells(.Ripple, frame)
		landing, _ := animation_frame_cells(.Hop, frame + 2)
		testing.expect_value(t, cells_differ_count(&landing, &wave), 0)
	}
	blink, _ := animation_frame_cells(.Blink, 1)
	doze, _ := animation_frame_cells(.Doze, 1)
	stretch, _ := animation_frame_cells(.Stretch, 1)
	testing.expect_value(t, cells_differ_count(&doze, &blink), 0)
	testing.expect_value(t, cells_differ_count(&stretch, &blink), 0)
	// The run has two poses, and the fourteen steps alternate them.
	apart, _ := animation_frame_cells(.Dash, 2)
	together, _ := animation_frame_cells(.Dash, 3)
	testing.expect_value(t, cells_differ_count(&apart, &still), 32)
	testing.expect_value(t, cells_differ_count(&together, &still), 24)
	for frame in 4 ..= 15 {
		step, _ := animation_frame_cells(.Dash, frame)
		pose := &apart if frame % 2 == 0 else &together
		testing.expectf(t, cells_differ_count(&step, pose) == 0, "the step %d of the run is not its pose", frame)
	}
	// Out of the water: the two rows of the water hold water only, and the
	// row 22 is whole from the column 2 to the column 18.
	Lifted :: struct {
		animation: Animation,
		frame:     int,
	}
	lifted := [?]Lifted{{.Dash, 2}, {.Dash, 3}, {.Dash, 16}, {.Hop, 2}, {.Flap, 2}, {.Flap, 3}, {.Flap, 5}}
	for entry in lifted {
		cells, found := animation_frame_cells(entry.animation, entry.frame)
		testing.expect(t, found)
		for row in HERON_GRID_SIZE - 2 ..< HERON_GRID_SIZE {
			for column in 0 ..< HERON_GRID_SIZE {
				letter := cells[row][column]
				testing.expectf(t, letter == '.' || letter == 't', "%v frame %d: the cell %d, %d of the water is %c", entry.animation, entry.frame, column, row, letter)
			}
		}
		for column in 2 ..= 18 {
			testing.expectf(t, cells[22][column] == 't', "%v frame %d: the water is open at the column %d", entry.animation, entry.frame, column)
		}
	}
	// The other leg of the wade stands in the water.
	wade, _ := animation_frame_cells(.Wade, 1)
	testing.expect_value(t, wade[22][12], u8('o'))
	testing.expect_value(t, wade[22][14], u8('o'))
	testing.expect_value(t, wade[22][9], u8('t'))
	testing.expect_value(t, cells_differ_count(&wade, &still), 18)
	// The wing of the flap leaves the body.
	wing_up, _ := animation_frame_cells(.Flap, 1)
	testing.expect_value(t, wing_up[13][7], u8('b'))
	testing.expect_value(t, wing_up[10][7], u8('d'))
	testing.expect_value(t, cells_differ_count(&wing_up, &still), 17)
	last, _ := animation_frame_cells(.Flap, 6)
	testing.expect_value(t, cells_differ_count(&last, &wing_up), 0)
	testing.expect_value(t, animation_frame_count(.Dash), 17)
	testing.expect_value(t, animation_duration(.Dash), 1780)
	testing.expect_value(t, animation_duration(.Hop), 880)
	testing.expect_value(t, animation_duration(.Fish), 1250)
	testing.expect_value(t, animation_duration(.Doze), 2400)
	testing.expect_value(t, animation_duration(.Stretch), 1100)
	testing.expect_value(t, animation_duration(.Ruffle), 900)
	testing.expect_value(t, animation_duration(.Wade), 1050)
	testing.expect_value(t, animation_duration(.Flap), 1000)
}

// Pinned frames of the preen and the scratch: the head on the back with the
// beak in the feathers, a stroke, the scratch that starts from the pose of
// the leg animation, and its foot on the row of the ground.
@(test)
preen_and_scratch_pinned_cells :: proc(t: ^testing.T) {
	still := still_cells()
	on_the_back, _ := animation_frame_cells(.Preen, 3)
	testing.expect_value(t, on_the_back[9][11], u8('k')) // The eye, lower and to the left.
	testing.expect_value(t, on_the_back[10][7], u8('y')) // The tip of the beak on the body.
	testing.expect_value(t, on_the_back[2][17], u8('.')) // The place of the eye of the still heron is empty.
	for column in 0 ..< HERON_GRID_SIZE {
		testing.expectf(t, on_the_back[0][column] == '.' && on_the_back[6][column] == '.', "the column %d above the folded head is not empty", column)
	}
	testing.expect_value(t, cells_differ_count(&on_the_back, &still), 47)
	stroke, _ := animation_frame_cells(.Preen, 4)
	testing.expect_value(t, cells_differ_count(&stroke, &on_the_back), 2)
	testing.expect_value(t, stroke[10][7], u8('.'))
	testing.expect_value(t, stroke[10][6], u8('b'))
	// The frames 5 and 7 repeat the frame 3, the frame 9 the frame 1.
	repeated, _ := animation_frame_cells(.Preen, 7)
	testing.expect_value(t, cells_differ_count(&repeated, &on_the_back), 0)
	knee_in, _ := animation_frame_cells(.Leg, 2)
	scratch_start, _ := animation_frame_cells(.Scratch, 1)
	testing.expect_value(t, cells_differ_count(&scratch_start, &knee_in), 0)
	forward, _ := animation_frame_cells(.Scratch, 2)
	testing.expect_value(t, forward[22][14], u8('o'))
	testing.expect_value(t, forward[22][15], u8('o'))
	testing.expect_value(t, forward[22][12], u8('t')) // Water between the two feet.
	back, _ := animation_frame_cells(.Scratch, 3)
	testing.expect_value(t, back[22][13], u8('o'))
	testing.expect_value(t, back[21][16], u8('t'))
	testing.expect_value(t, animation_frame_count(.Preen), 9)
	testing.expect_value(t, animation_frame_count(.Scratch), 8)
	testing.expect_value(t, animation_duration(.Preen), 2090)
	testing.expect_value(t, animation_duration(.Scratch), 1680)
}
