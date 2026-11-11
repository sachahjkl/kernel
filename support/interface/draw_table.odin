// The interface package (docs/INTERFACE.md): a program describes its window
// again at each frame, and each call appends draw records to a draw table
// in the memory of the program. The package finds the damage by a
// comparison with the table of the frame before, and draws the records into
// the surface of the program. It never allocates. The core files (the draw
// table, its execution, the difference, the layout, the text, the input,
// the elements) make no kernel call; window_drawing.odin does: it reads the
// events of a window and presents its surface.
package interface

import "support:graphics"

DRAW_RECORD_VERSION :: 5 // A new kind of record, or a new field, is a new version. 2: Folded_Gap, Picture. 3: Text_Grid. 4: Line, and the field line_thickness. 5: the fields filled and background of a cell of a text grid.

Draw_Kind :: enum u8 {
	None                = 0,
	Rectangle           = 1, // One color.
	Vertical_Gradient   = 2, // first_color at the top line, second_color at the bottom line.
	Horizontal_Gradient = 3, // first_color at the left column, second_color at the right column.
	Text                = 4, // The bytes text_start ..< text_start + text_count of the text table, in first_color.
	Clip                = 5, // The next records are cut to this rectangle. Width 0: no cut.
	Point_Grid          = 6, // The grid of points of the background (docs/DESIGN.md, section 3), in first_color.
	// A part with no measure on this scale: the track with two lines at an
	// angle in first_color, the one meaning of such lines (docs/DESIGN.md,
	// section 2).
	Folded_Gap          = 7,
	// The pixels of a picture of the caller: text_start is its index in
	// Draw_Table.pictures, text_count its generation (a new number when its
	// pixels change). The picture is drawn at (x, y), cut to width x height.
	Picture             = 8,
	// A grid of text cells of the caller: text_start is its index in
	// Draw_Table.grids. The cells are drawn on the background that the frame
	// paints. The difference compares the cells one by one: a changed cell
	// damages only its row span (docs/INTERFACE.md, section 2.4).
	Text_Grid           = 9,
	// A straight line in first_color: from (x, y) to (x + width, y + height),
	// so width and height can be negative here; line_thickness is the side
	// of the square drawn at each point of the path (docs/INTERFACE.md,
	// section 2.5).
	Line                = 10,
}

// The largest thickness of a line: past it, the squares of a long line
// cost too much to draw again in each damage rectangle.
LINE_THICKNESS_LIMIT :: 32

// The ends of a line stay inside this distance of the corner of the
// surface: the drawing walks each point of the path, so a line of a
// billion points would stop the program. A surface is far smaller.
LINE_COORDINATE_LIMIT :: 1 << 15

// One cell of a text grid: a character of the font of the system, in its
// color; or, reverse, in the color of the background on a cell of its
// color; or, filled, in its color on a cell of the color background (a
// list drawn over the text, a row that is chosen). A filled cell costs 4
// bytes more than a cell with no background: 12 bytes for each cell.
Text_Grid_Cell :: struct {
	character:  u8, // 0 to 32: no character.
	reverse:    bool,
	filled:     bool,
	color:      graphics.Color,
	background: graphics.Color, // For a filled cell.
}

// A grid of text cells: rows lines of columns cells, a line each stride
// cells. In the table of the frame now, the cells of the caller; in a table
// before, the copy of the cells that the surface shows (draw_table_copy).
Text_Grid :: struct {
	cells:                  []Text_Grid_Cell,
	columns, rows, stride: int,
}

// One thing to draw: 40 bytes, little-endian (docs/INTERFACE.md, section 2.1).
Draw_Record :: struct {
	kind:            Draw_Kind,
	text_scale:      u8, // Text: 1, 2 or 3.
	text_subpixel_x: u8, // Text: the position after x, in 1/64 of a pixel. 0 on the grid of cells: the vector font and Spleen 8x16 (docs/FONTS.md).
	line_thickness:  u8, // Line: 1 to LINE_THICKNESS_LIMIT pixels. 0 for the other kinds.
	x, y:            i32,
	width, height:   i32,
	first_color:     u32,
	second_color:    u32,
	text_start:      u32,
	text_count:      u32,
	element:         u32, // The low 32 bits of the identity of the element that wrote the record.
}

#assert(size_of(Draw_Record) == 40)

// The draw records of one frame and the bytes of their texts, in the memory
// of the program. full: a record or a text did not fit, and is not drawn:
// the table is not the frame, so the next frame is drawn whole. refused: a
// record that the caller asked for could not be made (a picture or a grid
// that the table does not have, a grid whose cells are fewer than its
// size). That record is missing, and each other record is in the table, so
// the difference with the next frame stays exact.
Draw_Table :: struct {
	records:      []Draw_Record,
	record_count: int,
	text:         []u8,
	text_count:   int,
	full:         bool,
	refused:      bool,
	pictures:     []graphics.Canvas, // The pictures that Picture records show.
	grids:        []Text_Grid, // The grids that Text_Grid records show.
}

// A rectangle of the surface. right and bottom are not in it.
Rectangle :: struct {
	left, top, right, bottom: int,
}

draw_table_clear :: proc "contextless" (table: ^Draw_Table) {
	table.record_count = 0
	table.text_count = 0
	table.full = false
	table.refused = false
}

// draw_table_copy makes target a copy of source: the table of the frame
// before, for the next comparison. It gives false if target is too small.
draw_table_copy :: proc "contextless" (target, source: ^Draw_Table) -> bool {
	if len(target.records) < source.record_count || len(target.text) < source.text_count {
		return false
	}
	copy(target.records[:source.record_count], source.records[:source.record_count])
	copy(target.text[:source.text_count], source.text[:source.text_count])
	target.record_count = source.record_count
	target.text_count = source.text_count
	target.full = source.full
	target.refused = source.refused
	target.pictures = source.pictures
	// The cells of each grid: the target keeps its own copy, in its memory.
	if len(target.grids) < len(source.grids) {
		return false
	}
	for grid, index in source.grids {
		size := grid_size(grid)
		if len(target.grids[index].cells) < size {
			return false
		}
		copy(target.grids[index].cells[:size], grid.cells[:size])
		target.grids[index].columns, target.grids[index].rows, target.grids[index].stride = grid.columns, grid.rows, grid.stride
	}
	return true
}

// grid_valid says if the cells of a grid hold each of its rows. The
// numbers come from the caller: the check divides, so a large count of
// rows or a large stride cannot wrap the product and pass.
grid_valid :: proc "contextless" (grid: Text_Grid) -> bool {
	if grid.rows < 0 || grid.columns < 0 || grid.stride < 0 {
		return false
	}
	if grid.rows == 0 || grid.columns == 0 {
		return true
	}
	if grid.stride < grid.columns || grid.columns > len(grid.cells) {
		return false
	}
	// (rows - 1) * stride + columns <= len(cells), with no product.
	return grid.rows - 1 <= (len(grid.cells) - grid.columns) / grid.stride
}

// grid_size gives the count of cells from the first cell of a grid to its
// last one, or 0 for a grid that grid_valid refuses.
grid_size :: proc "contextless" (grid: Text_Grid) -> int {
	if !grid_valid(grid) || grid.rows == 0 || grid.columns == 0 {
		return 0
	}
	return (grid.rows - 1) * grid.stride + grid.columns
}

// record_append appends one record and gives its address, or nil when the
// table is full.
record_append :: proc "contextless" (table: ^Draw_Table, record: Draw_Record) -> ^Draw_Record {
	if table.record_count >= len(table.records) {
		table.full = true
		return nil
	}
	table.records[table.record_count] = record
	table.record_count += 1
	return &table.records[table.record_count - 1]
}

// draw_rectangle appends a rectangle of one color.
draw_rectangle :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int, color: graphics.Color, element: u32 = 0) {
	if width <= 0 || height <= 0 {
		return
	}
	record_append(table, with_place({kind = .Rectangle, first_color = color, element = element}, x, y, width, height))
}

// draw_vertical_gradient appends the block of the rules: from top, on the
// first line, to bottom, on the last line.
draw_vertical_gradient :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int, top, bottom: graphics.Color, element: u32 = 0) {
	if width <= 0 || height <= 0 {
		return
	}
	record_append(table, with_place({kind = .Vertical_Gradient, first_color = top, second_color = bottom, element = element}, x, y, width, height))
}

// draw_horizontal_gradient appends a rectangle whose color goes from left,
// on its first column, to right, on its last column.
draw_horizontal_gradient :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int, left, right: graphics.Color, element: u32 = 0) {
	if width <= 0 || height <= 0 {
		return
	}
	record_append(table, with_place({kind = .Horizontal_Gradient, first_color = left, second_color = right, element = element}, x, y, width, height))
}

// draw_point_grid appends the grid of points of the background.
draw_point_grid :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int) {
	record_append(table, with_place({kind = .Point_Grid, first_color = graphics.COLOR_POINT}, x, y, width, height))
}

// draw_folded_gap appends a part with no measure on this scale.
draw_folded_gap :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int, element: u32 = 0) {
	if width <= 0 || height <= 0 {
		return
	}
	record_append(table, with_place({kind = .Folded_Gap, first_color = graphics.COLOR_DIM, second_color = graphics.COLOR_TRACK, element = element}, x, y, width, height))
}

// draw_picture appends the pixels of picture number index of the table, at
// (x, y). generation is a new number each time its pixels change: the
// difference sees the change.
draw_picture :: proc "contextless" (table: ^Draw_Table, x, y: int, index: int, generation: u32, element: u32 = 0) {
	if index < 0 || index >= len(table.pictures) {
		table.refused = true
		return
	}
	picture := table.pictures[index]
	record_append(table, with_place({kind = .Picture, text_start = u32(index), text_count = generation, element = element}, x, y, picture.width, picture.height))
}

// draw_text_grid appends the grid number index of the table at (x, y): one
// cell of the font of the system for each cell of the grid.
draw_text_grid :: proc "contextless" (table: ^Draw_Table, x, y: int, index: int, element: u32 = 0) {
	if index < 0 || index >= len(table.grids) {
		table.refused = true
		return
	}
	grid := table.grids[index]
	if !grid_valid(grid) {
		table.refused = true
		return
	}
	record_append(table, with_place({kind = .Text_Grid, text_start = u32(index), element = element}, x, y, grid.columns * graphics.CELL_WIDTH, grid.rows * graphics.CELL_HEIGHT))
}

// draw_line appends a straight line from one point to another, with a
// thickness in pixels. The record always goes from the left end (the top
// end when the two ends have one x), so a line and its reverse are one
// record and draw the same pixels. A thickness of 0 or less draws nothing;
// a thickness past LINE_THICKNESS_LIMIT is cut to it. A line with an end
// past LINE_COORDINATE_LIMIT is refused: no record. A line of length 0 is
// one square of its thickness.
draw_line :: proc "contextless" (table: ^Draw_Table, from_x, from_y, to_x, to_y: int, thickness: int, color: graphics.Color, element: u32 = 0) {
	if thickness <= 0 {
		return
	}
	if !inside_line_limit(from_x) || !inside_line_limit(from_y) || !inside_line_limit(to_x) || !inside_line_limit(to_y) {
		return
	}
	start_x, start_y, end_x, end_y := line_ends_in_order(from_x, from_y, to_x, to_y)
	record_append(table, {kind = .Line, line_thickness = u8(min(thickness, LINE_THICKNESS_LIMIT)), x = i32(start_x), y = i32(start_y), width = i32(end_x - start_x), height = i32(end_y - start_y), first_color = color, element = element})
}

// draw_outline appends the border of a rectangle, thickness pixels wide
// inside it, as four rectangles.
draw_outline :: proc "contextless" (table: ^Draw_Table, x, y, width, height, thickness: int, color: graphics.Color, element: u32 = 0) {
	side := min(thickness, width / 2, height / 2)
	if side <= 0 {
		return
	}
	draw_rectangle(table, x, y, width, side, color, element)
	draw_rectangle(table, x, y + height - side, width, side, color, element)
	draw_rectangle(table, x, y + side, side, height - 2 * side, color, element)
	draw_rectangle(table, x + width - side, y + side, side, height - 2 * side, color, element)
}

// inside_line_limit says if a place can be an end of a line. A comparison,
// not abs: abs of the smallest int is still negative.
inside_line_limit :: proc "contextless" (value: int) -> bool {
	return value >= -LINE_COORDINATE_LIMIT && value <= LINE_COORDINATE_LIMIT
}

// line_ends_in_order gives the two ends of a line with the left end first,
// or the top end first when the two ends have one x. The path of the line
// depends on its first end: one order gives one path in both directions.
line_ends_in_order :: proc "contextless" (from_x, from_y, to_x, to_y: int) -> (start_x, start_y, end_x, end_y: int) {
	if to_x < from_x || to_x == from_x && to_y < from_y {
		return to_x, to_y, from_x, from_y
	}
	return from_x, from_y, to_x, to_y
}

// line_record_valid says if the execution draws a line record: a record
// written by a caller with no draw_line can have any bytes.
line_record_valid :: proc "contextless" (record: Draw_Record) -> bool {
	thickness := int(record.line_thickness)
	if thickness < 1 || thickness > LINE_THICKNESS_LIMIT {
		return false
	}
	start_x, start_y := int(record.x), int(record.y)
	end_x, end_y := start_x + int(record.width), start_y + int(record.height)
	return inside_line_limit(start_x) && inside_line_limit(start_y) && inside_line_limit(end_x) && inside_line_limit(end_y)
}

// line_rectangle gives the rectangle that holds each pixel of a line: the
// path stays between the x and the y of its two ends, and the square of
// each point starts half a thickness before the point. The rectangle is
// the damage of the line. Pieces of the path would be tighter, but the
// damage list joins rectangles that touch, and the pieces of one line
// touch. A line that the execution refuses covers nothing.
line_rectangle :: proc "contextless" (record: Draw_Record) -> Rectangle {
	if !line_record_valid(record) {
		return {}
	}
	thickness := int(record.line_thickness)
	before := thickness / 2
	start_x, start_y := int(record.x), int(record.y)
	end_x, end_y := start_x + int(record.width), start_y + int(record.height)
	return {min(start_x, end_x) - before, min(start_y, end_y) - before, max(start_x, end_x) - before + thickness, max(start_y, end_y) - before + thickness}
}

// draw_clip appends a clip: the next records are cut to the rectangle. A
// width of 0 ends the cut.
draw_clip :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int) {
	record_append(table, with_place({kind = .Clip}, x, y, width, height))
}

// draw_text appends a run of text at (x, y), the top left corner of its
// first character, and gives the x after its last character.
draw_text :: proc "contextless" (table: ^Draw_Table, x, y: int, text: string, color: graphics.Color, font: Font = {}, element: u32 = 0) -> int {
	width := text_width(font, text)
	if len(text) == 0 {
		return x
	}
	if table.text_count + len(text) > len(table.text) {
		table.full = true
		return x + width
	}
	start := table.text_count
	copy(table.text[start:], text)
	table.text_count += len(text)
	scale := font_scale(font)
	record_append(table, with_place({kind = .Text, text_scale = u8(scale), first_color = color, text_start = u32(start), text_count = u32(len(text)), element = element}, x, y, width, graphics.CELL_HEIGHT * scale))
	return x + width
}

// draw_text_right appends a run of text that ends at right.
draw_text_right :: proc "contextless" (table: ^Draw_Table, right, y: int, text: string, color: graphics.Color, font: Font = {}, element: u32 = 0) {
	draw_text(table, right - text_width(font, text), y, text, color, font, element)
}

// The places of a record stay inside this distance of the corner of the
// surface. Inside it, a size is the difference of two places and fits the
// i32 of a record. A surface is far smaller.
COORDINATE_LIMIT :: 1 << 30

// with_place gives a record with the place and the size of a rectangle,
// cut to COORDINATE_LIMIT. Each edge is cut, then the size is the
// difference of the two edges: a cut place with its own cut size would move
// the other edge, so a rectangle that covers the surface could draw
// nothing.
@(private)
with_place :: proc "contextless" (record: Draw_Record, x, y, width, height: int) -> Draw_Record {
	placed := record
	left, right := cut_edges(x, width)
	top, bottom := cut_edges(y, height)
	placed.x, placed.width = i32(left), i32(right - left)
	placed.y, placed.height = i32(top), i32(bottom - top)
	return placed
}

// cut_edges gives the two edges of a place and a size, each cut to
// COORDINATE_LIMIT. The sum of the two numbers cannot pass the int.
@(private)
cut_edges :: proc "contextless" (place, size: int) -> (start, end: int) {
	switch {
	case size >= 0 && place > max(int) - size:
		end = max(int)
	case size < 0 && place < min(int) - size:
		end = min(int)
	case:
		end = place + size
	}
	start = clamp(place, -COORDINATE_LIMIT, COORDINATE_LIMIT - 1)
	end = clamp(end, -COORDINATE_LIMIT, COORDINATE_LIMIT - 1)
	return
}

// record_rectangle gives the rectangle that a record covers.
record_rectangle :: proc "contextless" (record: Draw_Record) -> Rectangle {
	if record.kind == .Line {
		return line_rectangle(record)
	}
	return {int(record.x), int(record.y), int(record.x) + int(record.width), int(record.y) + int(record.height)}
}

// draw_unsigned appends a number in decimal, with at least minimum_digits
// digits, and gives the x after it.
draw_unsigned :: proc "contextless" (table: ^Draw_Table, x, y: int, value: u64, color: graphics.Color, minimum_digits := 1) -> int {
	builder: Text_Builder
	return draw_text(table, x, y, number_text(&builder, value, minimum_digits), color)
}

// draw_character appends one character, and gives the x after it.
draw_character :: proc "contextless" (table: ^Draw_Table, x, y: int, character: u8, color: graphics.Color) -> int {
	one := [1]u8{character}
	return draw_text(table, x, y, string(one[:]), color)
}
