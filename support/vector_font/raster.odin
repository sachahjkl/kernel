package vector_font

// The coverage of a glyph by exact area, in integers (docs/FONTS.md,
// "Fixed point"). Each line segment of the outline adds its signed area to
// the cells of an accumulation; a prefix sum along each row gives the part
// of each pixel that the glyph covers (the method of font-rs and of
// stb_truetype 2, here with no floating point).
//
// Coordinates are in subunits: SUBUNITS_PER_PIXEL to a pixel on each axis
// (24.8 fixed point), y down. A segment is cut at each row and at each
// column of pixels; the place of a cut is a function of the segment and of
// the line of the cut only, so two pieces that meet use the same point, and
// the sum of the coverage of a closed outline is exactly the area of the
// polygon of its cut points.
//
// The units of an accumulation: a piece of height h subunits whose two ends
// are at ra and rb subunits from the left of its column adds
// h * (512 - ra - rb) to its cell and h * (ra + rb) to the next cell. A full
// pixel is 256 * 512 = FULL_PIXEL. The overflow argument: a piece adds at
// most FULL_PIXEL to a cell; a glyph has at most SEGMENT_LIMIT pieces in one
// row of cells (each segment gives at most one piece to one cell), so a cell
// and a prefix sum stay under SEGMENT_LIMIT * FULL_PIXEL = 2^30, which an
// i32 holds.

SUBUNITS_PER_PIXEL :: 256
FULL_PIXEL :: 256 * 512
SEGMENT_LIMIT :: 8192
CURVE_SEGMENT_LIMIT :: 16 // A quadratic curve is cut into 1 to 16 line segments.

// Accumulation: the memory of the caller for the cells of one glyph. A row
// has width + 1 cells: the cell after the last column takes what a piece on
// the right side of the last column gives to its right.
Accumulation :: struct {
	cells:         []i32,
	width, height: int,
	segments:      int, // The line segments added since the last finish.
}

// accumulation_of makes an accumulation over the memory of the caller, all
// zero. It gives false if the memory is too small.
accumulation_of :: proc "contextless" (cells: []i32, width, height: int) -> (target: Accumulation, ok: bool) {
	if width < 1 || height < 1 || (width + 1) * height > len(cells) {
		return {}, false
	}
	for &cell in cells[:(width + 1) * height] {
		cell = 0
	}
	return {cells = cells[:(width + 1) * height], width = width, height = height}, true
}

// divide_rounded gives numerator / denominator rounded to the nearest
// integer, half up, for a denominator above 0 and a numerator of any sign.
divide_rounded :: #force_inline proc "contextless" (numerator, denominator: i64) -> i64 {
	twice := 2 * numerator + denominator
	quotient := twice / (2 * denominator)
	if twice % (2 * denominator) < 0 {
		quotient -= 1 // Division to minus infinity.
	}
	return quotient
}

@(private)
floor_divide :: #force_inline proc "contextless" (value, by: i64) -> i64 {
	quotient := value / by
	if value % by < 0 {
		quotient -= 1
	}
	return quotient
}

// line_add adds the signed area of one line segment, in subunits.
line_add :: proc "contextless" (target: ^Accumulation, x0, y0, x1, y1: i32) {
	if y0 == y1 || target.segments >= SEGMENT_LIMIT {
		return // A segment past the limit is dropped: the overflow argument holds.
	}
	target.segments += 1
	sign: i64 = 1
	from_x, from_y, to_x, to_y := i64(x0), i64(y0), i64(x1), i64(y1)
	if from_y > to_y {
		sign = -1
		from_x, from_y, to_x, to_y = to_x, to_y, from_x, from_y
	}
	// The x of the segment at a y: a function of the segment and of y only.
	x_at :: #force_inline proc "contextless" (from_x, from_y, to_x, to_y, y: i64) -> i64 {
		if y == from_y {
			return from_x
		}
		if y == to_y {
			return to_x
		}
		return from_x + divide_rounded((to_x - from_x) * (y - from_y), to_y - from_y)
	}
	limit_x := i64(target.width * SUBUNITS_PER_PIXEL)
	first_row := max(floor_divide(from_y, SUBUNITS_PER_PIXEL), 0)
	last_row := min(floor_divide(to_y - 1, SUBUNITS_PER_PIXEL), i64(target.height - 1))
	for row in first_row ..= last_row {
		top := max(from_y, row * SUBUNITS_PER_PIXEL)
		bottom := min(to_y, (row + 1) * SUBUNITS_PER_PIXEL)
		if top >= bottom {
			continue
		}
		// What is left of the accumulation lies on its left side, what is
		// right of it on its right side: the coverage of each pixel inside
		// stays exact.
		top_x := clamp(x_at(from_x, from_y, to_x, to_y, top), 0, limit_x)
		bottom_x := clamp(x_at(from_x, from_y, to_x, to_y, bottom), 0, limit_x)
		row_cells := target.cells[int(row) * (target.width + 1):][:target.width + 1]
		row_add(row_cells, top_x, top, bottom_x, bottom, sign, target.width)
	}
}

// row_add adds a piece of a segment inside one row: from (top_x, top) to
// (bottom_x, bottom), top < bottom, both x inside [0, width * 256]. It cuts
// the piece at each column.
@(private)
row_add :: proc "contextless" (cells: []i32, top_x, top, bottom_x, bottom: i64, sign: i64, width: int) {
	// The ends in the order of x.
	left_x, left_y, right_x, right_y := top_x, top, bottom_x, bottom
	if left_x > right_x {
		left_x, left_y, right_x, right_y = bottom_x, bottom, top_x, top
	}
	first_column := min(floor_divide(left_x, SUBUNITS_PER_PIXEL), i64(width - 1))
	last_column := max(floor_divide(right_x - 1, SUBUNITS_PER_PIXEL), first_column)
	// The y of the piece at an x: a function of the piece and of x only.
	y_at :: #force_inline proc "contextless" (left_x, left_y, right_x, right_y, x: i64) -> i64 {
		if x <= left_x {
			return left_y
		}
		if x >= right_x {
			return right_y
		}
		return left_y + divide_rounded((right_y - left_y) * (x - left_x), right_x - left_x)
	}
	from_x, from_y := left_x, left_y
	for column in first_column ..= last_column {
		// The last piece ends at the end of the segment: also for a vertical
		// piece, whose two ends have one x.
		to_x, to_y := right_x, right_y
		if column != last_column {
			to_x = (column + 1) * SUBUNITS_PER_PIXEL
			to_y = y_at(left_x, left_y, right_x, right_y, to_x)
		}
		height := abs(to_y - from_y) * sign
		start := column * SUBUNITS_PER_PIXEL
		sum := (from_x - start) + (to_x - start) // 0 to 512.
		cells[column] += i32(height * (512 - sum))
		cells[column + 1] += i32(height * sum)
		from_x, from_y = to_x, to_y
	}
}

// quadratic_add adds a quadratic curve as line segments: the count makes the
// distance of the segments from the curve at most 1/8 of a pixel, from 1
// to CURVE_SEGMENT_LIMIT. Each point is computed from the ends and the
// control point, rounded: no error adds up along the curve.
quadratic_add :: proc "contextless" (target: ^Accumulation, x0, y0, control_x, control_y, x1, y1: i32) {
	// The distance of the curve from its chord is at most |p0 - 2c + p1| / 4;
	// with n segments, a quarter of that over n * n.
	bend := abs(i64(x0) - 2 * i64(control_x) + i64(x1)) + abs(i64(y0) - 2 * i64(control_y) + i64(y1))
	count: i64 = 1
	for count < CURVE_SEGMENT_LIMIT && bend > 128 * count * count {
		count += 1
	}
	previous_x, previous_y := x0, y0
	square := count * count
	for step in 1 ..= count {
		before := count - step
		x := divide_rounded(before * before * i64(x0) + 2 * step * before * i64(control_x) + step * step * i64(x1), square)
		y := divide_rounded(before * before * i64(y0) + 2 * step * before * i64(control_y) + step * step * i64(y1), square)
		line_add(target, previous_x, previous_y, i32(x), i32(y))
		previous_x, previous_y = i32(x), i32(y)
	}
}

// coverage_finish makes the coverage of each pixel, 0 to 255, from the
// accumulations, and clears the accumulations for the next glyph. coverage
// has width x height bytes. The coverage of a pixel covered two times (two
// contours that overlap with one direction) is the coverage of one.
coverage_finish :: proc "contextless" (target: ^Accumulation, coverage: []u8) {
	stride := target.width + 1
	for row in 0 ..< target.height {
		sum: i32
		cells := target.cells[row * stride:][:stride]
		out := coverage[row * target.width:][:target.width]
		for column in 0 ..< target.width {
			sum += cells[column]
			cells[column] = 0
			out[column] = u8((min(abs(sum), FULL_PIXEL) * 255 + FULL_PIXEL / 2) / FULL_PIXEL)
		}
		cells[target.width] = 0
	}
	target.segments = 0
}

// coverage_sum gives the sum of the exact coverage of all pixels, in units
// of 1 / FULL_PIXEL of a pixel, with no clear: the host tests compare it
// with the area of a shape.
coverage_sum :: proc "contextless" (target: ^Accumulation) -> i64 {
	total: i64
	stride := target.width + 1
	for row in 0 ..< target.height {
		sum: i64
		for column in 0 ..< target.width {
			sum += i64(target.cells[row * stride + column])
			total += sum
		}
	}
	return total
}

// The filters of the coverage of the color stripes, in 1/256 (docs/FONTS.md,
// "Subpixel bands"). Each third of a pixel spreads over its neighbours, so
// that a side of a stem does not show one color alone.
Stripe_Filter :: enum u8 {
	Five_Taps, // 8, 77, 86, 77, 8: the default filter of the usual LCD rendering.
	Three_Taps, // 85, 86, 85: sharper, more color at the edges.
	None, // Each third as it is: the most color.
}

stripe_filter_weights := [Stripe_Filter][5]i32 {
	.Five_Taps  = {8, 77, 86, 77, 8},
	.Three_Taps = {0, 85, 86, 85, 0},
	.None       = {0, 0, 256, 0, 0},
}

// stripes_filter filters one row of thirds: out[i] = the weighted sum of
// thirds[i - 2 .. i + 2], in 0 to 255. thirds and out have the same length;
// a third outside the row is 0.
stripes_filter :: proc "contextless" (thirds: []u8, out: []u8, filter: Stripe_Filter) {
	weights := stripe_filter_weights[filter]
	count := len(thirds)
	for index in 0 ..< count {
		sum: i32
		for weight, offset in weights {
			at := index + offset - 2
			if at >= 0 && at < count {
				sum += weight * i32(thirds[at])
			}
		}
		out[index] = u8(min((sum + 128) >> 8, 255))
	}
}
