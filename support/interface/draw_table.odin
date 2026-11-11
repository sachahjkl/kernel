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

DRAW_RECORD_VERSION :: 3 // A new kind of record, or a new field, is a new version. 2: Folded_Gap, Picture. 3: Text_Grid.

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
}

// One cell of a text grid: a character of the font of the system, in its
// color, or in the color of the background on a cell of its color.
Text_Grid_Cell :: struct {
	character: u8, // 0 to 32: no character.
	reverse:   bool,
	color:     graphics.Color,
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
	reserved:        u8,
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
// of the program. full: a record or a text did not fit, and is not drawn.
Draw_Table :: struct {
	records:      []Draw_Record,
	record_count: int,
	text:         []u8,
	text_count:   int,
	full:         bool,
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

// grid_valid says if the cells of a grid hold each of its rows.
grid_valid :: proc "contextless" (grid: Text_Grid) -> bool {
	if grid.rows <= 0 || grid.columns <= 0 {
		return grid.rows >= 0 && grid.columns >= 0
	}
	return grid.stride >= grid.columns && (grid.rows - 1) * grid.stride + grid.columns <= len(grid.cells)
}

// grid_size gives the count of cells from the first cell of a grid to its
// last one.
grid_size :: proc "contextless" (grid: Text_Grid) -> int {
	if grid.rows <= 0 || grid.columns <= 0 {
		return 0
	}
	return min((grid.rows - 1) * grid.stride + grid.columns, len(grid.cells))
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
	record_append(table, {kind = .Rectangle, x = coordinate(x), y = coordinate(y), width = coordinate(width), height = coordinate(height), first_color = color, element = element})
}

// draw_vertical_gradient appends the block of the rules: from top, on the
// first line, to bottom, on the last line.
draw_vertical_gradient :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int, top, bottom: graphics.Color, element: u32 = 0) {
	if width <= 0 || height <= 0 {
		return
	}
	record_append(table, {kind = .Vertical_Gradient, x = coordinate(x), y = coordinate(y), width = coordinate(width), height = coordinate(height), first_color = top, second_color = bottom, element = element})
}

// draw_horizontal_gradient appends a rectangle whose color goes from left,
// on its first column, to right, on its last column.
draw_horizontal_gradient :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int, left, right: graphics.Color, element: u32 = 0) {
	if width <= 0 || height <= 0 {
		return
	}
	record_append(table, {kind = .Horizontal_Gradient, x = coordinate(x), y = coordinate(y), width = coordinate(width), height = coordinate(height), first_color = left, second_color = right, element = element})
}

// draw_point_grid appends the grid of points of the background.
draw_point_grid :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int) {
	record_append(table, {kind = .Point_Grid, x = coordinate(x), y = coordinate(y), width = coordinate(width), height = coordinate(height), first_color = graphics.COLOR_POINT})
}

// draw_folded_gap appends a part with no measure on this scale.
draw_folded_gap :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int, element: u32 = 0) {
	if width <= 0 || height <= 0 {
		return
	}
	record_append(table, {kind = .Folded_Gap, x = coordinate(x), y = coordinate(y), width = coordinate(width), height = coordinate(height), first_color = graphics.COLOR_DIM, second_color = graphics.COLOR_TRACK, element = element})
}

// draw_picture appends the pixels of picture number index of the table, at
// (x, y). generation is a new number each time its pixels change: the
// difference sees the change.
draw_picture :: proc "contextless" (table: ^Draw_Table, x, y: int, index: int, generation: u32, element: u32 = 0) {
	if index < 0 || index >= len(table.pictures) {
		table.full = true
		return
	}
	picture := table.pictures[index]
	record_append(table, {kind = .Picture, x = coordinate(x), y = coordinate(y), width = coordinate(picture.width), height = coordinate(picture.height), text_start = u32(index), text_count = generation, element = element})
}

// draw_text_grid appends the grid number index of the table at (x, y): one
// cell of the font of the system for each cell of the grid.
draw_text_grid :: proc "contextless" (table: ^Draw_Table, x, y: int, index: int, element: u32 = 0) {
	if index < 0 || index >= len(table.grids) {
		table.full = true
		return
	}
	grid := table.grids[index]
	if !grid_valid(grid) {
		table.full = true
		return
	}
	record_append(table, {kind = .Text_Grid, x = coordinate(x), y = coordinate(y), width = coordinate(grid.columns * graphics.CELL_WIDTH), height = coordinate(grid.rows * graphics.CELL_HEIGHT), text_start = u32(index), element = element})
}

// draw_clip appends a clip: the next records are cut to the rectangle. A
// width of 0 ends the cut.
draw_clip :: proc "contextless" (table: ^Draw_Table, x, y, width, height: int) {
	record_append(table, {kind = .Clip, x = coordinate(x), y = coordinate(y), width = coordinate(width), height = coordinate(height)})
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
	record_append(table, {kind = .Text, text_scale = u8(scale), x = coordinate(x), y = coordinate(y), width = coordinate(width), height = coordinate(graphics.CELL_HEIGHT * scale), first_color = color, text_start = u32(start), text_count = u32(len(text)), element = element})
	return x + width
}

// draw_text_right appends a run of text that ends at right.
draw_text_right :: proc "contextless" (table: ^Draw_Table, right, y: int, text: string, color: graphics.Color, font: Font = {}, element: u32 = 0) {
	draw_text(table, right - text_width(font, text), y, text, color, font, element)
}

// coordinate gives a place or a size as the i32 of a record: a value past
// the i32 is cut to it.
@(private)
coordinate :: #force_inline proc "contextless" (value: int) -> i32 {
	return i32(clamp(value, int(min(i32)), int(max(i32))))
}

// record_rectangle gives the rectangle that a record covers.
record_rectangle :: proc "contextless" (record: Draw_Record) -> Rectangle {
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
