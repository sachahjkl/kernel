package heron

import "support:graphics"
import "support:interface"
import "support:mark"

// The free way of a move: what the grid way is compared with. The rule of
// the system is the grid way (docs/DESIGN.md, "The moves"): the heron takes
// the drawn forms of support/mark at places in whole cells. The free way
// reads the same keys and does what a picture that is scaled does: the
// frame of the heron, as it is, is stretched to the box of the form of the
// key, and the box goes from a key to the next one pixel by pixel. So the
// eye, the beak and the legs change their form with the box, and the heron
// stands between two cells. It is in this program only, for a reader to
// see why the forms are drawn.

// The two ways to draw a move from the keys of support/mark.
Move_Way :: enum u8 {
	On_The_Grid, // The drawn form of the key, in whole square cells, at a place in whole cells.
	Free, // The frame stretched to the box of the form, at any pixel.
}

// The rectangle of the part of the heron above the water in the free way,
// in pixels from the top left corner of the natural heron: negative at the
// left of the heron and above it.
Free_Box :: struct {
	left, top, width, height: int,
}

// free_key_box gives the box of the form of a key at the place of the key.
@(private = "file")
free_key_box :: proc "contextless" (key: mark.Move_Key, travel: mark.Move_Travel, cell: int) -> Free_Box {
	columns, rows := mark.form_size(key.form)
	right, up := mark.move_key_place(key, travel)
	return {(mark.form_first_column(key.form) + right) * cell, (mark.form_first_row(key.form) - up) * cell, columns * cell, rows * cell}
}

// free_box_at gives the box of the heron at a time from the start of an
// animation, in milliseconds, at a cell size. At a key it is the box of
// the form of that key at its place. Between two keys each edge goes from
// the first box to the second with the time, in pixels: this is the part
// of the free way that the grid way does not have. A key that holds keeps
// its box until the next key. An animation with no move, and a time before
// its first key, give the box of the natural heron.
free_box_at :: proc "contextless" (animation: mark.Animation, at_milliseconds: int, travel: mark.Move_Travel, cell: int) -> Free_Box {
	first, second: mark.Move_Key
	has_first, has_second := false, false
	for key in mark.move_keys {
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
		return {0, 0, mark.BODY_COLUMNS * cell, mark.BODY_ROWS * cell}
	}
	box := free_key_box(first, travel, cell)
	span := second.at_milliseconds - first.at_milliseconds
	if has_second && first.pace == .Step && span > 0 {
		next := free_key_box(second, travel, cell)
		passed := at_milliseconds - first.at_milliseconds
		box.left += (next.left - box.left) * passed / span
		box.top += (next.top - box.top) * passed / span
		box.width += (next.width - box.width) * passed / span
		box.height += (next.height - box.height) * passed / span
	}
	return box
}

// scaled_source_pixel gives the pixel of a line of source_size pixels that
// the pixel number target of a line of target_size pixels shows, when the
// first line is drawn at the size of the second: the pixel under the
// middle of the target pixel. No color is mixed.
scaled_source_pixel :: proc "contextless" (target, target_size, source_size: int) -> int {
	return (2 * target + 1) * source_size / (2 * target_size)
}

// scaled_cell_edge gives the first pixel that shows the cell number cell
// of a line of cell_count cells, when the line is drawn at target_size
// pixels (scaled_source_pixel). The edge of the cell number cell_count is
// target_size.
scaled_cell_edge :: proc "contextless" (cell, cell_count, target_size: int) -> int {
	return (2 * target_size * cell + cell_count - 1) / (2 * cell_count)
}

// The widest box that free_draw draws, in pixels: wider than the widest
// form at the largest cell size.
FREE_WIDTH_MOST :: 1024

// free_draw draws a picture of the natural heron at the size of a
// rectangle of a canvas: each pixel of the rectangle takes the color of
// one pixel of the picture (scaled_source_pixel), so a cell of the heron
// becomes a rectangle. A pixel of the picture that is `empty` is not
// drawn, and nothing is drawn outside the canvas.
free_draw :: proc "contextless" (canvas: graphics.Canvas, picture: graphics.Canvas, body: interface.Rectangle, empty: graphics.Color) {
	width, height := body.right - body.left, body.bottom - body.top
	cut := interface.intersection(body, {0, 0, canvas.width, canvas.height})
	if interface.empty(cut) || width > FREE_WIDTH_MOST || picture.width < 1 || picture.height < 1 {
		return
	}
	// The column of the picture under each column of the rectangle: one
	// division for a column, not one for each pixel.
	source_columns: [FREE_WIDTH_MOST]i32
	for x in cut.left ..< cut.right {
		source_columns[x - body.left] = i32(scaled_source_pixel(x - body.left, width, picture.width))
	}
	for y in cut.top ..< cut.bottom {
		source_line := picture.pixels[scaled_source_pixel(y - body.top, height, picture.height) * picture.stride:]
		target_line := canvas.pixels[y * canvas.stride:]
		for x in cut.left ..< cut.right {
			if color := source_line[source_columns[x - body.left]]; color != empty {
				target_line[x] = color
			}
		}
	}
}
