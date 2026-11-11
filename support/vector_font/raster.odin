package vector_font

// The coverage of a glyph by exact area: each line segment of the outline
// adds its signed area to the cells of an accumulation buffer, and a prefix
// sum along each line gives the part of each pixel that the glyph covers
// (the method of font-rs and of stb_truetype 2). The quadratic curves are
// cut into line segments.

// Coverage: the memory of the caller for one glyph. cells has width x
// height accumulations, coverage the result, 0 to 255 for each pixel (or
// for each third of a pixel, with color stripes).
Coverage :: struct {
	cells:         []f32,
	coverage:      []u8,
	width, height: int,
}

@(private)
floor_of :: #force_inline proc "contextless" (value: f32) -> f32 {
	whole := f32(int(value))
	return whole > value ? whole - 1 : whole
}

@(private)
ceil_of :: #force_inline proc "contextless" (value: f32) -> f32 {
	whole := f32(int(value))
	return whole < value ? whole + 1 : whole
}

// line_add adds the signed area of one line segment, in pixels, y down.
line_add :: proc "contextless" (target: ^Coverage, x0, y0, x1, y1: f32) {
	if y0 == y1 {
		return
	}
	direction: f32 = 1
	from_x, from_y, to_x, to_y := x0, y0, x1, y1
	if from_y > to_y {
		direction = -1
		from_x, from_y, to_x, to_y = x1, y1, x0, y0
	}
	slope := (to_x - from_x) / (to_y - from_y)
	x := from_x
	if from_y < 0 {
		x -= from_y * slope
	}
	first := max(int(floor_of(from_y)), 0)
	last := min(int(ceil_of(to_y)), target.height)
	for y in first ..< last {
		row := target.cells[y * target.width:][:target.width]
		dy := min(f32(y + 1), to_y) - max(f32(y), from_y)
		x_next := x + slope * dy
		d := dy * direction
		left, right := min(x, x_next), max(x, x_next)
		left_floor := floor_of(left)
		left_index := int(left_floor)
		right_ceil := ceil_of(right)
		right_index := int(right_ceil)
		if left_index < 0 || right_index >= target.width {
			// The prototype keeps the outline inside its box: a point outside is cut.
			left_index = clamp(left_index, 0, target.width - 2)
			right_index = clamp(right_index, left_index + 1, target.width - 1)
		}
		if right_index <= left_index + 1 {
			middle := 0.5 * (x + x_next) - left_floor
			row[left_index] += d - d * middle
			row[left_index + 1] += d * middle
		} else {
			inverse := 1 / (right - left)
			left_part := left - left_floor
			first_area := 0.5 * inverse * (1 - left_part) * (1 - left_part)
			right_part := right - right_ceil + 1
			last_area := 0.5 * inverse * right_part * right_part
			row[left_index] += d * first_area
			if right_index == left_index + 2 {
				row[left_index + 1] += d * (1 - first_area - last_area)
			} else {
				step_area := inverse * (1.5 - left_part)
				row[left_index + 1] += d * (step_area - first_area)
				for index in left_index + 2 ..< right_index - 1 {
					row[index] += d * inverse
				}
				before_last := step_area + f32(right_index - left_index - 3) * inverse
				row[right_index - 1] += d * (1 - before_last - last_area)
			}
			row[right_index] += d * last_area
		}
		x = x_next
	}
}

// quadratic_add adds a quadratic curve as line segments: more segments for
// a curve that bends more, from 1 to 16.
quadratic_add :: proc "contextless" (target: ^Coverage, x0, y0, control_x, control_y, x1, y1: f32) {
	bend_x := x0 - 2 * control_x + x1
	bend_y := y0 - 2 * control_y + y1
	bend := abs(bend_x) + abs(bend_y)
	count := clamp(int(bend * 2) + 1, 1, 16)
	previous_x, previous_y := x0, y0
	for step in 1 ..= count {
		t := f32(step) / f32(count)
		u := 1 - t
		x := u * u * x0 + 2 * u * t * control_x + t * t * x1
		y := u * u * y0 + 2 * u * t * control_y + t * t * y1
		line_add(target, previous_x, previous_y, x, y)
		previous_x, previous_y = x, y
	}
}

// Placement: how an outline goes into the pixels of a coverage.
Placement :: struct {
	scale:     f32, // Pixels for one unit of the font. 3 times more across, with color stripes.
	scale_y:   f32,
	origin_x:  f32, // Where the point (0, 0) of the font is: the start of the advance...
	origin_y:  f32, // ...and the baseline, from the top.
}

// outline_add adds each contour of an outline, with the points between two
// points that are off the curve (TrueType).
outline_add :: proc "contextless" (target: ^Coverage, outline: ^Outline, placement: Placement) {
	place :: proc "contextless" (point: Outline_Point, placement: Placement) -> (x, y: f32) {
		return placement.origin_x + point.x * placement.scale, placement.origin_y - point.y * placement.scale_y
	}
	first := 0
	for contour in 0 ..< outline.contour_count {
		end := outline.contour_ends[contour]
		count := end - first
		if count < 2 {
			first = end
			continue
		}
		points := outline.points[first:end]
		// The start: a point on the curve, or the middle of two that are not.
		start := 0
		for start < count && !points[start].on_curve {
			start += 1
		}
		start_x, start_y: f32
		if start == count {
			a_x, a_y := place(points[0], placement)
			b_x, b_y := place(points[1], placement)
			start_x, start_y = (a_x + b_x) / 2, (a_y + b_y) / 2
			start = 0
		} else {
			start_x, start_y = place(points[start], placement)
		}
		current_x, current_y := start_x, start_y
		control_x, control_y: f32
		has_control := false
		for step in 1 ..= count {
			point := points[(start + step) % count]
			x, y := place(point, placement)
			if point.on_curve {
				if has_control {
					quadratic_add(target, current_x, current_y, control_x, control_y, x, y)
				} else {
					line_add(target, current_x, current_y, x, y)
				}
				current_x, current_y = x, y
				has_control = false
			} else {
				if has_control {
					middle_x, middle_y := (control_x + x) / 2, (control_y + y) / 2
					quadratic_add(target, current_x, current_y, control_x, control_y, middle_x, middle_y)
					current_x, current_y = middle_x, middle_y
				}
				control_x, control_y = x, y
				has_control = true
			}
		}
		if has_control {
			quadratic_add(target, current_x, current_y, control_x, control_y, start_x, start_y)
		} else if current_x != start_x || current_y != start_y {
			line_add(target, current_x, current_y, start_x, start_y)
		}
		first = end
	}
}

// coverage_finish makes the coverage of each cell from the accumulations,
// and clears the accumulations for the next glyph.
coverage_finish :: proc "contextless" (target: ^Coverage) {
	for y in 0 ..< target.height {
		sum: f32
		for x in 0 ..< target.width {
			index := y * target.width + x
			sum += target.cells[index]
			target.cells[index] = 0
			target.coverage[index] = u8(min(abs(sum), 1) * 255 + 0.5)
		}
	}
}

// stripes_filter spreads the coverage of each third of a pixel over its
// neighbours, with the weights 8, 77, 86, 77, 8 of 256: the colors at the
// edges are fainter. thirds has 3 x width values for each line; colors gets
// width x 3 values (red, green, blue).
stripes_filter :: proc "contextless" (thirds: []u8, colors: []u8, width, height: int) {
	WEIGHTS :: [5]int{8, 77, 86, 77, 8}
	line := 3 * width
	for y in 0 ..< height {
		for index in 0 ..< line {
			sum := 0
			for weight, offset in WEIGHTS {
				at := index + offset - 2
				if at >= 0 && at < line {
					sum += weight * int(thirds[y * line + at])
				}
			}
			colors[y * line + index] = u8(min(sum / 256, 255))
		}
	}
}
