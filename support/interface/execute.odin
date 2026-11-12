package interface

import "support:graphics"

// execute draws each record of a table into a canvas, in order. The records
// are in the coordinates of the surface; (origin_x, origin_y) is where the
// point (0, 0) of the surface is in the canvas. The canvas cuts each record.
execute :: proc "contextless" (table: ^Draw_Table, canvas: graphics.Canvas, origin_x: int = 0, origin_y: int = 0) {
	execute_in_rectangle(table, canvas, {-origin_x, -origin_y, canvas.width - origin_x, canvas.height - origin_y}, origin_x, origin_y)
}

// draw_damage_on_surface draws the damage of a frame on the surface of a
// program: each damage rectangle is painted with the background first, so a
// record that the frame no longer has leaves no pixel, then the records
// that touch it are drawn again. The compositor draws a panel over other
// windows: it calls execute_in_rectangle, which paints only the records.
draw_damage_on_surface :: proc "contextless" (table: ^Draw_Table, canvas: graphics.Canvas, rectangles: []Rectangle) {
	for rectangle in rectangles {
		area := intersection(rectangle, {0, 0, canvas.width, canvas.height})
		if !empty(area) {
			graphics.fill(canvas, area.left, area.top, area.right - area.left, area.bottom - area.top, graphics.COLOR_BACKGROUND)
		}
		execute_in_rectangle(table, canvas, rectangle)
	}
}

// execute_in_rectangles draws again, in each rectangle, the records that
// touch it, cut to it. The rectangles are in the coordinates of the surface.
execute_in_rectangles :: proc "contextless" (table: ^Draw_Table, canvas: graphics.Canvas, rectangles: []Rectangle, origin_x: int = 0, origin_y: int = 0) {
	for rectangle in rectangles {
		execute_in_rectangle(table, canvas, rectangle, origin_x, origin_y)
	}
}

// execute_in_rectangle draws the records that touch one rectangle of the
// surface, cut to it.
execute_in_rectangle :: proc "contextless" (table: ^Draw_Table, canvas: graphics.Canvas, rectangle: Rectangle, origin_x: int = 0, origin_y: int = 0) {
	limit := intersection(rectangle, {-origin_x, -origin_y, canvas.width - origin_x, canvas.height - origin_y})
	if empty(limit) {
		return
	}
	cut := limit
	for record in table.records[:table.record_count] {
		if record.kind == .Clip {
			cut = record.width == 0 ? limit : intersection(limit, record_rectangle(record))
			continue
		}
		area := intersection(cut, record_rectangle(record))
		if empty(area) {
			continue
		}
		// The part of the canvas where this record can draw: the record draws
		// in its own coordinates, and the view cuts it.
		view := graphics.view(canvas, area.left + origin_x, area.top + origin_y, area.right - area.left, area.bottom - area.top)
		x, y := int(record.x) - area.left, int(record.y) - area.top
		width, height := int(record.width), int(record.height)
		switch record.kind {
		case .None, .Clip:
		case .Rectangle:
			graphics.fill(view, x, y, width, height, record.first_color)
		case .Vertical_Gradient:
			// One mix for each line: only the lines in the view.
			first := max(0, -y)
			last := min(height, view.height - y)
			for row in first ..< last {
				graphics.fill(view, x, y + row, width, 1, graphics.mix(record.first_color, record.second_color, u32(row * 255 / max(height - 1, 1))))
			}
		case .Horizontal_Gradient:
			// One row of colors for the columns in the view, in parts of
			// 512 pixels, then a copy of the row to each line.
			row: [512]graphics.Color
			last := min(width, view.width - x)
			for part := max(0, -x); part < last; part += len(row) {
				count := min(len(row), last - part)
				graphics.gradient(row[:count], record.first_color, record.second_color, width, part)
				graphics.copy(view, x + part, y, {pixels = raw_data(row[:]), width = count, height = height})
			}
		case .Text:
			start := int(record.text_start)
			count := int(record.text_count)
			if start + count <= table.text_count {
				text_draw(view, x, y, string(table.text[start:start + count]), record.first_color, int(record.text_scale), record.kind_detail == u8(Font_Weight.Bold) ? .Bold : .Regular)
			}
		case .Folded_Gap:
			graphics.fill(view, x, y, width, height, record.second_color)
			// Two lines at an angle, from the bottom left up to the right.
			graphics.line(view, x + 2, y + height - 4, x + width - 4, y + 4, 1, record.first_color)
			graphics.line(view, x + 6, y + height - 4, x + width, y + 8, 1, record.first_color)
		case .Picture:
			index := int(record.text_start)
			if index < len(table.pictures) {
				picture := table.pictures[index]
				graphics.copy(view, x, y, {pixels = picture.pixels, width = min(picture.width, width), height = min(picture.height, height), stride = picture.stride})
			}
		case .Text_Grid:
			index := int(record.text_start)
			if index < len(table.grids) {
				text_grid_draw(view, x, y, table.grids[index])
			}
		case .Line:
			// (x, y) is the first end in the view; the path is the one of
			// graphics.line from the end that line_ends_in_order puts first.
			start_x, start_y, end_x, end_y := line_ends_in_order(x, y, x + width, y + height)
			graphics.line(view, start_x, start_y, end_x, end_y, int(record.kind_detail), record.first_color)
		case .Point_Grid:
			// The points are at 12 + 24 n of the surface, so that two areas
			// of one surface show one grid. A point that starts before the
			// area can reach into it: the loop starts one step before.
			half := graphics.POINT_STEP / 2
			first_x := half + max(0, (area.left - half) / graphics.POINT_STEP - 1) * graphics.POINT_STEP
			first_y := half + max(0, (area.top - half) / graphics.POINT_STEP - 1) * graphics.POINT_STEP
			for point_y := first_y; point_y < area.bottom; point_y += graphics.POINT_STEP {
				for point_x := first_x; point_x < area.right; point_x += graphics.POINT_STEP {
					graphics.fill(view, point_x - area.left, point_y - area.top, graphics.POINT_SIZE, graphics.POINT_SIZE, record.first_color)
				}
			}
		}
	}
}

// text_grid_draw draws the cells of a grid that the view shows, with its
// first cell at (x, y). The cells of one color that follow each other are
// one text: the font draws each text once.
text_grid_draw :: proc "contextless" (canvas: graphics.Canvas, x, y: int, grid: Text_Grid) {
	if !grid_valid(grid) {
		return
	}
	first_row := max(0, -y / graphics.CELL_HEIGHT)
	last_row := min(grid.rows, (canvas.height - y + graphics.CELL_HEIGHT - 1) / graphics.CELL_HEIGHT)
	first_column := max(0, -x / graphics.CELL_WIDTH)
	last_column := min(grid.columns, (canvas.width - x + graphics.CELL_WIDTH - 1) / graphics.CELL_WIDTH)
	run: [256]u8
	for row in first_row ..< last_row {
		cells := grid.cells[row * grid.stride:][:grid.columns]
		top := y + row * graphics.CELL_HEIGHT
		column := first_column
		for column < last_column {
			cell := cells[column]
			left := x + column * graphics.CELL_WIDTH
			if cell.reverse {
				graphics.fill(canvas, left, top, graphics.CELL_WIDTH, graphics.CELL_HEIGHT, cell.color)
				run[0] = max(cell.character, ' ')
				text_draw(canvas, left, top, string(run[:1]), graphics.COLOR_BACKGROUND, 1)
				column += 1
				continue
			}
			if cell.filled {
				// A run of filled cells of one color and one background:
				// one fill, then one text. An empty cell is a space.
				count := 0
				for column + count < last_column && count < len(run) {
					next := cells[column + count]
					if next.reverse || !next.filled || next.color != cell.color || next.background != cell.background {
						break
					}
					run[count] = max(next.character, ' ')
					count += 1
				}
				graphics.fill(canvas, left, top, count * graphics.CELL_WIDTH, graphics.CELL_HEIGHT, cell.background)
				text_draw(canvas, left, top, string(run[:count]), cell.color, 1)
				column += count
				continue
			}
			if cell.character <= ' ' {
				column += 1
				continue
			}
			// A run: the cells of this color, spaces too, up to a reverse
			// cell, a filled cell, an empty cell or the end of the room.
			count := 0
			for column + count < last_column && count < len(run) {
				next := cells[column + count]
				if next.reverse || next.filled || next.character < ' ' || next.color != cell.color {
					break
				}
				run[count] = next.character
				count += 1
			}
			text_draw(canvas, left, top, string(run[:count]), cell.color, 1)
			column += count
		}
	}
}

// text_draw draws characters of the font of the system, each pixel of the
// font as a square of scale pixels.
text_draw :: proc "contextless" (canvas: graphics.Canvas, x, y: int, text: string, color: graphics.Color, scale: int, weight: Font_Weight = .Regular) {
	if weight == .Bold && scale <= 1 {
		graphics.text_bold(canvas, x, y, text, color)
		return
	}
	graphics.text_scaled(canvas, x, y, text, color, scale)
}

intersection :: proc "contextless" (first, second: Rectangle) -> Rectangle {
	return {max(first.left, second.left), max(first.top, second.top), min(first.right, second.right), min(first.bottom, second.bottom)}
}

empty :: proc "contextless" (rectangle: Rectangle) -> bool {
	return rectangle.left >= rectangle.right || rectangle.top >= rectangle.bottom
}
