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
// the play (still, the frames, still) changes more than FRAME_CHANGE_LIMIT
// cells. No frame is further from the still heron than that limit either.
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
			testing.expectf(t, from_still <= FRAME_CHANGE_LIMIT, "%v frame %d: %d cells from the still heron; at most %d", animation, frame, from_still, FRAME_CHANGE_LIMIT)
			testing.expectf(t, step <= FRAME_CHANGE_LIMIT, "%v frame %d: %d cells from the frame before; at most %d", animation, frame, step, FRAME_CHANGE_LIMIT)
			if frame == 1 || frame == count {
				testing.expectf(t, from_still > 0, "%v: the frame %d does not move", animation, frame)
			}
			previous = cells
		}
		back := cells_differ_count(&previous, &still)
		testing.expectf(t, back <= FRAME_CHANGE_LIMIT, "%v: %d cells from the last frame back to the still heron; at most %d", animation, back, FRAME_CHANGE_LIMIT)
	}
	// Pinned: the blink closes the eye, and nothing else.
	blink, _ := animation_frame_cells(.Blink, 1)
	testing.expect_value(t, blink[2][17], u8('h'))
	testing.expect_value(t, cells_differ_count(&blink, &still), 1)
}

// The durations are in their range, each animation is in the order of play,
// and the order has a still time in its range before each animation.
@(test)
durations_and_order_are_in_range :: proc(t: ^testing.T) {
	for row in animation_frames {
		duration := int(row.duration_milliseconds)
		testing.expectf(t, duration >= FRAME_DURATION_LEAST && duration <= FRAME_DURATION_MOST, "%v frame %d: %d ms", row.animation, row.frame, duration)
	}
	for animation in Animation {
		total := animation_duration(animation)
		testing.expectf(t, total > 0 && total <= ANIMATION_DURATION_MOST, "%v: %d ms in all", animation, total)
		testing.expectf(t, animation_weight(animation) >= 1, "%v is not in the order of play", animation)
	}
	weights := 0
	for step in play_order {
		still := int(step.still_milliseconds)
		testing.expectf(t, still >= STILL_DURATION_LEAST && still <= STILL_DURATION_MOST, "a still time of %d ms", still)
	}
	for animation in Animation {
		weights += animation_weight(animation)
	}
	testing.expect_value(t, weights, len(play_order))
	// No animation follows itself, also across the end of the order.
	for index in 0 ..< len(play_order) {
		next := play_order[(index + 1) % len(play_order)]
		testing.expectf(t, next.animation != play_order[index].animation, "the step %d and the next play %v", index, next.animation)
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
				frame_color, frame_covered := cells_pixel(&still, 2, x, y, on_light)
				still_color, still_covered := mark_pixel(2, x, y, on_light)
				if frame_color != still_color || frame_covered != still_covered {
					testing.expectf(t, false, "pixel %d, %d differs from mark_pixel", x, y)
					return
				}
			}
		}
	}
	_, refused := cells_pixel(&still, CELL_SIZE_LIMIT + 1, 0, 0, false)
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
	cells_draw(view, &look, PLACE_X, PLACE_Y, 2, false)
	for y in 0 ..< SIDE {
		for x in 0 ..< SIDE {
			expected := DRAW_TEST_SENTINEL
			if x >= VIEW_LEFT && x < VIEW_LEFT + VIEW_SIDE && y >= VIEW_LEFT && y < VIEW_LEFT + VIEW_SIDE {
				if color, covered := cells_pixel(&look, 2, x - VIEW_LEFT - PLACE_X, y - VIEW_LEFT - PLACE_Y, false); covered {
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
