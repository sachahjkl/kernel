// The graphics library: drawing with the processor into pixel memory
// (the system has no GPU code yet, and programs draw on the processor
// first: docs/PROPERTIES.md, "One graphics interface"). It is compiled into
// each program that draws.
//
// Who uses it: the boot program (the boot display), the compositor, and
// each program with a window, often through `support/interface`. It draws
// into memory that the caller gives (a `Canvas`); it allocates nothing and
// calls the kernel never. The parts:
//
// - `Canvas`, `Color`, `fill`, `line`, `outline`, `view`: shapes.
// - `text`, `text_scaled`, `text_bold`, `character` (`text.odin`): the text of
//   the system, from a glyph cache or from Spleen 8x16 (`font.odin`).
// - `Blend_Tables` (`blend.odin`): the blend of a glyph over a color.
// - The design rules (`rules.odin`): the grid, the surfaces and one color
//   for each concept.
// - `value_kind_colors`, `Code_Class_Color`: the colors of the values of the
//   log and of the classes of code.
//
// See (docs/DESIGN.md) for the rules and (docs/FONTS.md) for the text.
package graphics

import "base:intrinsics"

// A color is 0x00RRGGBB.
Color :: u32

// rgb gives the color of three channels, each from 0 to 255.
//
// Example: `rgb(0x3F, 0x7C, 0xC4)` is `COLOR_TITLE`.
rgb :: #force_inline proc "contextless" (red, green, blue: u32) -> Color {
	return red << 16 | green << 8 | blue
}

// A canvas is a rectangle of pixels in memory. Line y starts at pixel y * stride.
//
// A canvas does not own its pixels: a surface of the compositor, a picture
// of a program, or the framebuffer. Each procedure of this package cuts what
// it draws to the canvas, so a shape partly outside it is drawn in part.
Canvas :: struct {
	pixels: [^]Color, // The first pixel of line 0.
	width:  int, // Pixels of a line that belong to the canvas.
	height: int, // Lines.
	stride: int, // Pixels from one line to the next: at least `width`.
}

// view gives the part of a canvas in a rectangle, as a canvas of the same
// memory. The rectangle must be inside the canvas.
view :: proc "contextless" (canvas: Canvas, x, y, width, height: int) -> Canvas {
	return {pixels = canvas.pixels[y * canvas.stride + x:], width = width, height = height, stride = canvas.stride}
}

// fill paints a rectangle in one color, cut to the canvas.
//
// Example: `graphics.fill(canvas, 0, 0, 100, 24, graphics.COLOR_TRACK)`.
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

// clear paints the whole canvas in one color.
clear :: proc "contextless" (canvas: Canvas, color: Color) {
	fill(canvas, 0, 0, canvas.width, canvas.height, color)
}

// outline paints the border of a rectangle, `thickness` pixels wide, inside
// the rectangle.
outline :: proc "contextless" (canvas: Canvas, x, y, width, height, thickness: int, color: Color) {
	fill(canvas, x, y, width, thickness, color)
	fill(canvas, x, y + height - thickness, width, thickness, color)
	fill(canvas, x, y, thickness, height, color)
	fill(canvas, x + width - thickness, y, thickness, height, color)
}

// pixel paints one pixel, when it is inside the canvas.
pixel :: #force_inline proc "contextless" (canvas: Canvas, x, y: int, color: Color) {
	if x >= 0 && y >= 0 && x < canvas.width && y < canvas.height {
		canvas.pixels[y * canvas.stride + x] = color
	}
}

// line paints a straight line from one point to another, both included: a
// square of `thickness` pixels at each point of the path (the algorithm of
// Bresenham). Its cost grows with the length: a caller bounds the points
// (`interface.LINE_COORDINATE_LIMIT`).
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
		intrinsics.mem_copy_non_overlapping(
			&canvas.pixels[line * canvas.stride + x0],
			&source.pixels[(line - y) * source.stride + (x0 - x)],
			(x1 - x0) * size_of(Color),
		)
	}
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
