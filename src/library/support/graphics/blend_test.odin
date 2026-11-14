#+build !freestanding
package graphics

import "core:testing"

// The blend gives round(source + destination * (255 - alpha) / 255) for
// each channel, for each alpha, each premultiplied source value and each
// destination value of a channel; the two other channels do not change it.
@(test)
blend_is_exact_for_each_channel_value :: proc(t: ^testing.T) {
	wrong := 0
	for alpha in u32(0) ..= 255 {
		for source in u32(0) ..= alpha {
			for destination in u32(0) ..= 255 {
				// The value in red, a constant in green, another in blue.
				pixel := [1]Color{destination << 16 | 0x40 << 8 | 0xC0}
				picture := [1]u32{alpha << 24 | source << 16 | (0x10 * alpha / 255) << 8 | alpha}
				blend_premultiplied_alpha({pixels = raw_data(pixel[:]), width = 1, height = 1, stride = 1}, 0, 0, {pixels = raw_data(picture[:]), width = 1, height = 1, stride = 1})
				expected := source + (destination * (255 - alpha) + 127) / 255
				if pixel[0] >> 16 != expected || pixel[0] >> 24 != 0 {
					wrong += 1
				}
				expected_blue := alpha + (0xC0 * (255 - alpha) + 127) / 255
				if pixel[0] & 0xFF != expected_blue {
					wrong += 1
				}
			}
		}
	}
	testing.expect_value(t, wrong, 0)
}

// A picture at each place around the canvas, also out of it: the blend
// writes only inside the canvas, and only where the picture is.
@(test)
blend_is_cut_to_the_canvas :: proc(t: ^testing.T) {
	SIDE :: 8
	PICTURE :: 3
	picture: [PICTURE * PICTURE]u32
	for &pixel in picture {
		pixel = 0xFF_FF_FF_FF
	}
	for y in -5 ..= SIDE + 2 {
		for x in -5 ..= SIDE + 2 {
			memory: [(SIDE + 2) * (SIDE + 2)]Color // A frame of one pixel around the canvas.
			canvas := Canvas{pixels = raw_data(memory[SIDE + 2 + 1:]), width = SIDE, height = SIDE, stride = SIDE + 2}
			blend_premultiplied_alpha(canvas, x, y, {pixels = raw_data(picture[:]), width = PICTURE, height = PICTURE, stride = PICTURE})
			for row in 0 ..< SIDE + 2 {
				for column in 0 ..< SIDE + 2 {
					inside_canvas := row >= 1 && row <= SIDE && column >= 1 && column <= SIDE
					canvas_x, canvas_y := column - 1, row - 1
					inside_picture := canvas_x >= x && canvas_x < x + PICTURE && canvas_y >= y && canvas_y < y + PICTURE
					expected := Color(inside_canvas && inside_picture ? 0xFFFFFF : 0)
					testing.expectf(t, memory[row * (SIDE + 2) + column] == expected, "picture at %d,%d: pixel %d,%d", x, y, column, row)
				}
			}
		}
	}
}
