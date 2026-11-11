// The graphics library: drawing with the processor into pixel memory
// (property 18, step 1: no GPU). It is compiled into each program that draws.
package graphics

import "base:intrinsics"

// A color is 0x00RRGGBB.
Color :: u32

rgb :: #force_inline proc "contextless" (red, green, blue: u32) -> Color {
	return red << 16 | green << 8 | blue
}

// A canvas is a rectangle of pixels in memory. Line y starts at pixel y * stride.
Canvas :: struct {
	pixels: [^]Color,
	width:  int,
	height: int,
	stride: int,
}

// view gives the part of a canvas in a rectangle, as a canvas of the same
// memory. The rectangle must be inside the canvas.
view :: proc "contextless" (canvas: Canvas, x, y, width, height: int) -> Canvas {
	return {pixels = canvas.pixels[y * canvas.stride + x:], width = width, height = height, stride = canvas.stride}
}

fill :: proc "contextless" (canvas: Canvas, x, y, width, height: int, color: Color) {
	x0 := max(x, 0)
	y0 := max(y, 0)
	x1 := min(x + width, canvas.width)
	y1 := min(y + height, canvas.height)
	if x0 >= x1 {
		return
	}
	for line in y0 ..< y1 {
		row := canvas.pixels[line * canvas.stride:]
		for column in x0 ..< x1 {
			row[column] = color
		}
	}
}

clear :: proc "contextless" (canvas: Canvas, color: Color) {
	fill(canvas, 0, 0, canvas.width, canvas.height, color)
}

outline :: proc "contextless" (canvas: Canvas, x, y, width, height, thickness: int, color: Color) {
	fill(canvas, x, y, width, thickness, color)
	fill(canvas, x, y + height - thickness, width, thickness, color)
	fill(canvas, x, y, thickness, height, color)
	fill(canvas, x + width - thickness, y, thickness, height, color)
}

pixel :: #force_inline proc "contextless" (canvas: Canvas, x, y: int, color: Color) {
	if x >= 0 && y >= 0 && x < canvas.width && y < canvas.height {
		canvas.pixels[y * canvas.stride + x] = color
	}
}

line :: proc "contextless" (canvas: Canvas, from_x, from_y, to_x, to_y: int, thickness: int, color: Color) {
	x, y := from_x, from_y
	distance_x := abs(to_x - from_x)
	distance_y := -abs(to_y - from_y)
	step_x := from_x < to_x ? 1 : -1
	step_y := from_y < to_y ? 1 : -1
	error := distance_x + distance_y
	for {
		fill(canvas, x - thickness / 2, y - thickness / 2, thickness, thickness, color)
		if x == to_x && y == to_y {
			return
		}
		twice := 2 * error
		if twice >= distance_y {
			error += distance_y
			x += step_x
		}
		if twice <= distance_x {
			error += distance_x
			y += step_y
		}
	}
}

// copy draws all of source at (x, y) of canvas. A source with stride 0
// has one line, that each line of the result copies.
copy :: proc "contextless" (canvas: Canvas, x, y: int, source: Canvas) {
	x0 := max(x, 0)
	y0 := max(y, 0)
	x1 := min(x + source.width, canvas.width)
	y1 := min(y + source.height, canvas.height)
	if x0 >= x1 {
		return
	}
	for line in y0 ..< y1 {
		copy_pixels(canvas.pixels[line * canvas.stride + x0:], source.pixels[(line - y) * source.stride + (x0 - x):], x1 - x0)
	}
}

// copy_pixels copies count pixels, 16 bytes at a time. It does not call
// memcpy: in a program of this system, memcpy is the one of the
// freestanding Odin runtime, which copies one byte at a time and is not
// optimized. The store is volatile, so that the compiler does not make the
// loop a call of memcpy again.
copy_pixels :: #force_inline proc "contextless" (to, from: [^]Color, count: int) {
	Block :: #simd[4]u32
	index := 0
	for ; index + 4 <= count; index += 4 {
		intrinsics.volatile_store((^[4]u32)(&to[index]), transmute([4]u32)intrinsics.unaligned_load((^Block)(&from[index])))
	}
	for ; index < count; index += 1 {
		to[index] = from[index]
	}
}

// text draws characters from (x, y), the top left corner of the first one.
// It gives the x after the last character.
text :: proc "contextless" (canvas: Canvas, x, y: int, characters: string, color: Color) -> int {
	x := x
	for i in 0 ..< len(characters) {
		character(canvas, x, y, characters[i], color)
		x += CELL_WIDTH
	}
	return x
}

character :: proc "contextless" (canvas: Canvas, x, y: int, value: u8, color: Color) {
	if value < FONT_FIRST || value > FONT_LAST {
		return
	}
	glyph := font[value - FONT_FIRST]
	if x >= 0 && y >= 0 && x + CELL_WIDTH <= canvas.width && y + CELL_HEIGHT <= canvas.height {
		// The whole glyph is inside the canvas: no test for each pixel.
		for bits, row in glyph {
			line := canvas.pixels[(y + row) * canvas.stride + x:]
			for column in 0 ..< CELL_WIDTH {
				if bits << uint(column) & 0x80 != 0 {
					line[column] = color
				}
			}
		}
		return
	}
	for bits, row in glyph {
		for column in 0 ..< CELL_WIDTH {
			if bits << uint(column) & 0x80 != 0 {
				pixel(canvas, x + column, y + row, color)
			}
		}
	}
}

text_width :: proc "contextless" (characters: string) -> int {
	return len(characters) * CELL_WIDTH
}

// unsigned draws a number, and gives the x after it.
unsigned :: proc "contextless" (canvas: Canvas, x, y: int, value: u64, color: Color, minimum_digits := 1) -> int {
	digits: [20]u8
	count := 0
	rest := value
	for rest != 0 || count < minimum_digits {
		digits[len(digits) - 1 - count] = u8('0' + rest % 10)
		count += 1
		rest /= 10
	}
	return text(canvas, x, y, string(digits[len(digits) - count:]), color)
}
