package vector_font

// One glyph into one cell of the grid (docs/FONTS.md, "The grid"): the
// advance of the font is exactly the width of the cell, the line is the
// height of the cell, and the result is one 32-bit word for each pixel:
// the coverage of the red, green and blue stripes after the filter, and the
// coverage of the whole pixel for grayscale.

// The measures of a font that place it on the grid, in units of the font,
// from the outlines of the printable ASCII characters.
Font_Measures :: struct {
	advance:    int, // The advance of a character: one for all, in a monospace font.
	x_height:   int, // The top of x.
	cap_height: int, // The top of H.
	top:        int, // The highest point of a character.
	bottom:     int, // The lowest point of a character, below 0.
	monospace:  bool, // Each character has the advance of the others.
}

// Glyph_Style: how a glyph goes into a cell.
Glyph_Style :: struct {
	cell_width, cell_height: int, // In pixels: 8 x 16 at scale 1.
	baseline:                int, // The row of the baseline, from the top of the cell.
	grid_fit:                bool, // The baseline, the x-height and the cap height on whole pixels.
	filter:                  Stripe_Filter,
}

// The version of the renderer: a glyph cache keeps it, and a change of the
// pixels that the renderer gives is a new version (property 11: the cache
// is a function of the font file and of the renderer).
RENDERER_VERSION :: 1

// The largest cell: scale 3 of the grid.
CELL_WIDTH_LIMIT :: 24
CELL_HEIGHT_LIMIT :: 48
// The thirds of a pixel on each side of a cell that the filter reads: ink
// that passes the side of a cell gives its color to the pixel at the side.
STRIPE_MARGIN :: 6
STRIPE_ROW_LIMIT :: 3 * CELL_WIDTH_LIMIT + 2 * STRIPE_MARGIN

// Render_Memory: the memory of the caller for the work on one glyph.
Render_Memory :: struct {
	points:   [POINT_LIMIT]Outline_Point,
	contours: [128]int,
	cells:    [(STRIPE_ROW_LIMIT + 1) * CELL_HEIGHT_LIMIT]i32,
	thirds:   [STRIPE_ROW_LIMIT * CELL_HEIGHT_LIMIT]u8,
	filtered: [STRIPE_ROW_LIMIT]u8,
}

// Placement: where the points of an outline go, in subunits, y down.
Placement :: struct {
	origin_x:                   i64, // The x of the point x = 0 of the font.
	horizontal_numerator:       i64, // x subunits = x units * numerator / denominator.
	horizontal_denominator:     i64,
	origin_y:                   i64, // The baseline.
	vertical_numerator:         i64,
	vertical_denominator:       i64,
	grid_fit:                   bool,
	x_height, x_height_place:   i64, // Units, and subunits on a whole pixel.
	cap_height, cap_height_place: i64,
}

// place_x and place_y give the subunits of a point of the font.
place_x :: #force_inline proc "contextless" (placement: ^Placement, x: i32) -> i32 {
	return i32(placement.origin_x + divide_rounded(i64(x) * placement.horizontal_numerator, placement.horizontal_denominator))
}

place_y :: proc "contextless" (placement: ^Placement, y: i32) -> i32 {
	units := i64(y)
	height: i64
	switch {
	case !placement.grid_fit || units <= 0:
		height = divide_rounded(units * placement.vertical_numerator, placement.vertical_denominator)
	case units <= placement.x_height:
		height = divide_rounded(units * placement.x_height_place, placement.x_height)
	case units <= placement.cap_height:
		height = placement.x_height_place + divide_rounded((units - placement.x_height) * (placement.cap_height_place - placement.x_height_place), placement.cap_height - placement.x_height)
	case:
		height = placement.cap_height_place + divide_rounded((units - placement.cap_height) * placement.vertical_numerator, placement.vertical_denominator)
	}
	return i32(placement.origin_y - height)
}

// outline_add adds each contour of an outline, with the points between two
// points that are off the curve (TrueType).
outline_add :: proc "contextless" (target: ^Accumulation, outline: ^Outline, placement: ^Placement) {
	first := 0
	for contour in 0 ..< outline.contour_count {
		end := outline.contour_ends[contour]
		count := end - first
		if count < 2 || end > outline.point_count {
			first = end
			continue
		}
		points := outline.points[first:end]
		place :: #force_inline proc "contextless" (point: Outline_Point, placement: ^Placement) -> (x, y: i32) {
			return place_x(placement, point.x), place_y(placement, point.y)
		}
		// The start: a point on the curve, or the middle of two that are not.
		start := 0
		for start < count && !points[start].on_curve {
			start += 1
		}
		start_x, start_y: i32
		if start == count {
			a_x, a_y := place(points[0], placement)
			b_x, b_y := place(points[1], placement)
			start_x, start_y = (a_x + b_x) / 2, (a_y + b_y) / 2
			start = 0
		} else {
			start_x, start_y = place(points[start], placement)
		}
		current_x, current_y := start_x, start_y
		control_x, control_y: i32
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

// font_measures reads the measures of a font from its outlines of the
// characters 33 to 126.
font_measures :: proc "contextless" (font: ^Font_File, memory: ^Render_Memory) -> (measures: Font_Measures, problem: Font_Problem) {
	outline := Outline{points = memory.points[:], contour_ends = memory.contours[:]}
	measures.monospace = true
	measures.top = -1 << 30
	measures.bottom = 1 << 30
	for character in rune(33) ..= 126 {
		glyph := glyph_of(font, character) or_return
		glyph_outline(font, glyph, &outline) or_return
		if measures.advance == 0 {
			measures.advance = outline.advance
		} else if measures.advance != outline.advance {
			measures.monospace = false
		}
		highest := -1 << 30
		for point in outline.points[:outline.point_count] {
			measures.top = max(measures.top, int(point.y))
			measures.bottom = min(measures.bottom, int(point.y))
			highest = max(highest, int(point.y))
		}
		switch character {
		case 'x':
			measures.x_height = highest
		case 'H':
			measures.cap_height = highest
		}
	}
	if measures.advance <= 0 || measures.x_height <= 0 || measures.cap_height <= measures.x_height || measures.top <= 0 {
		return measures, .Unknown_Format
	}
	return measures, .None
}

// glyph_style_of places a font in a cell of cell_width x cell_height pixels:
// the advance is the width of the cell, the scale is one on both axes, and
// the baseline puts the middle of the ink of the characters at the middle
// of the cell.
glyph_style_of :: proc "contextless" (measures: Font_Measures, cell_width, cell_height: int, grid_fit: bool, filter := Stripe_Filter.Five_Taps) -> Glyph_Style {
	// The ink goes from top * scale above the baseline to bottom * scale
	// below it; scale = cell_width / advance.
	middle_twice := i64(cell_height) * i64(measures.advance) + i64(measures.top + measures.bottom) * i64(cell_width)
	baseline := divide_rounded(middle_twice, 2 * i64(measures.advance))
	return {cell_width = cell_width, cell_height = cell_height, baseline = int(clamp(baseline, 1, i64(cell_height))), grid_fit = grid_fit, filter = filter}
}

// placement_of gives the placement of the outlines of a font in a cell, in
// thirds of a pixel across when thirds is true.
placement_of :: proc "contextless" (measures: Font_Measures, style: Glyph_Style, thirds: bool) -> Placement {
	across := i64(thirds ? 3 : 1)
	pixel_width := i64(style.cell_width) * SUBUNITS_PER_PIXEL
	placement := Placement {
		origin_x               = (thirds ? STRIPE_MARGIN : 0) * SUBUNITS_PER_PIXEL,
		horizontal_numerator   = pixel_width * across,
		horizontal_denominator = i64(measures.advance),
		origin_y               = i64(style.baseline) * SUBUNITS_PER_PIXEL,
		vertical_numerator     = pixel_width,
		vertical_denominator   = i64(measures.advance),
		grid_fit               = style.grid_fit,
		x_height               = i64(measures.x_height),
		cap_height             = i64(measures.cap_height),
	}
	whole :: proc "contextless" (units, numerator, denominator: i64) -> i64 {
		return max(divide_rounded(units * numerator, denominator * SUBUNITS_PER_PIXEL), 1) * SUBUNITS_PER_PIXEL
	}
	placement.x_height_place = whole(placement.x_height, pixel_width, placement.vertical_denominator)
	placement.cap_height_place = max(whole(placement.cap_height, pixel_width, placement.vertical_denominator), placement.x_height_place + SUBUNITS_PER_PIXEL)
	return placement
}

// glyph_render draws the glyph of one character into a cell: pixels gets
// cell_width x cell_height words, each 0xGGRRGGBB: the coverage of the
// whole pixel in the high byte, then the coverage of the red, the green and
// the blue stripe (the order red, green, blue from the left; a screen with
// blue first swaps them at the blend). A character with no outline gives
// zero words.
glyph_render :: proc "contextless" (font: ^Font_File, measures: Font_Measures, style: Glyph_Style, character: rune, memory: ^Render_Memory, pixels: []u32) -> Font_Problem {
	width, height := style.cell_width, style.cell_height
	if width < 1 || height < 1 || width > CELL_WIDTH_LIMIT || height > CELL_HEIGHT_LIMIT || len(pixels) < width * height {
		return .Too_Many_Points
	}
	for &pixel in pixels[:width * height] {
		pixel = 0
	}
	glyph := glyph_of(font, character) or_return
	outline := Outline{points = memory.points[:], contour_ends = memory.contours[:]}
	glyph_outline(font, glyph, &outline) or_return
	row_length := 3 * width + 2 * STRIPE_MARGIN
	target, _ := accumulation_of(memory.cells[:], row_length, height)
	placement := placement_of(measures, style, true)
	outline_add(&target, &outline, &placement)
	coverage_finish(&target, memory.thirds[:])
	for row in 0 ..< height {
		thirds := memory.thirds[row * row_length:][:row_length]
		stripes_filter(thirds, memory.filtered[:row_length], style.filter)
		for column in 0 ..< width {
			at := STRIPE_MARGIN + 3 * column
			red, green, blue := u32(memory.filtered[at]), u32(memory.filtered[at + 1]), u32(memory.filtered[at + 2])
			gray := (u32(thirds[at]) + u32(thirds[at + 1]) + u32(thirds[at + 2]) + 1) / 3
			pixels[row * width + column] = gray << 24 | red << 16 | green << 8 | blue
		}
	}
	return .None
}
