// The kind icons (docs/DESIGN.md, "The icons of the kinds"): one small
// picture for each kind of thing that a display lists, as data. An icon is
// a grid of 12 by 12 square cells, as the heron of the mark is cells: the
// system draws each cell as whole pixels, and the site of the system draws
// the same cells as rectangles of an SVG picture. One table gives both, so
// that a handle or a module has one picture wherever it is shown.
//
// The package holds no color: the color of a value kind is in the table of
// the design rules (src/library/support/graphics/value_colors.odin), and a display that
// draws an icon gives its color.
//
// It makes no call and never allocates.
package kind_icons

import "contract:value_kinds"

// The side of an icon, in cells. A cell is one pixel at the size that a row
// of a list and the site show: 12 pixels, in a line of 16 or a row of 24.
ICON_SIZE :: 12

// The cells of one icon: 12 rows of 12 characters, from the top. "#" is a
// cell of the icon, "." is empty.
Cells :: [ICON_SIZE]string

// A kind of thing of the desktop that is not a value kind: a display lists
// it beside the values, and it has an icon as they have.
Desktop_Kind :: enum u8 {
	Window  = 0, // A window of a program.
	Setting = 1, // One value of one setting of the machine.
	Export  = 2, // An export of a module or of a service.
	Stop    = 3, // An act that destroys: the close of a window, a command that stops the machine.
}

// The icon of each value kind. The kind None has no icon.
@(rodata)
value_kind_cells := [value_kinds.Value_Kind]Cells {
	.None = {},
	// A hash sign.
	.Number = {"............", "...##..##...", "...##..##...", ".##########.", "...##..##...", "...##..##...", "...##..##...", ".##########.", "...##..##...", "...##..##...", "............", "............"},
	// Three stacked bars, each wider than the one above.
	.Size = {"............", "..########..", "..########..", "............", ".##########.", ".##########.", "............", "############", "############", "............", "............", "............"},
	// A square with two hands.
	.Time = {"............", ".##########.", ".#........#.", ".#...##...#.", ".#...##...#.", ".#...####.#.", ".#...####.#.", ".#........#.", ".#........#.", ".##########.", "............", "............"},
	// A square ring on a stem.
	.Handle = {"............", "...######...", "...#....#...", "...#....#...", "...######...", ".....##.....", ".....##.....", ".....##.....", "....####....", "....####....", "............", "............"},
	// One small square.
	.Value = {"............", "............", "............", "....####....", "....####....", "....####....", "....####....", "............", "............", "............", "............", "............"},
	// A check mark in steps.
	.Grant = {"............", "..........##", ".........##.", "........##..", ".......##...", "##....##....", ".##..##.....", "..####......", "...##.......", "............", "............", "............"},
	// A flag on its pole.
	.Status = {"............", ".##.........", ".#######....", ".########...", ".#######....", ".##.........", ".##.........", ".##.........", ".##.........", ".##.........", "............", "............"},
	// Two angle brackets.
	.Type = {"............", "...##..##...", "..##....##..", ".##......##.", "##........##", ".##......##.", "..##....##..", "...##..##...", "............", "............", "............", "............"},
	// A line into a box.
	.Operation = {"............", "......######", "......#....#", "......#....#", "##########.#", "##########.#", "......#....#", "......#....#", "......######", "............", "............", "............"},
	// The prompt of a console: an angle and a line.
	.Command = {"............", ".##.........", "..##........", "...##.......", "....##......", "...##.......", "..##........", ".##...#####.", "......#####.", "............", "............", "............"},
	// A block with a notch in its top.
	.Module = {"............", ".###....###.", ".###....###.", ".##########.", ".##########.", ".##########.", ".##########.", ".##########.", "............", "............", "............", "............"},
	// A page with a corner of steps.
	.File = {".######.....", ".#....##....", ".#.....##...", ".#......##..", ".#.......#..", ".#.......#..", ".#.......#..", ".#.......#..", ".#.......#..", ".#########..", "............", "............"},
	// A page with three lines of text.
	.Guide = {"............", ".##########.", ".#........#.", ".#.######.#.", ".#........#.", ".#.######.#.", ".#........#.", ".#.####...#.", ".#........#.", ".##########.", "............", "............"},
	// The capital letter T.
	.Term = {"............", ".##########.", ".##########.", ".....##.....", ".....##.....", ".....##.....", ".....##.....", ".....##.....", ".....##.....", "....####....", "............", "............"},
	// A tag with a hole.
	.Version = {"............", "...#######..", "..##.....#..", ".##..##..#..", ".##..##..#..", "..##.....#..", "...#######..", "............", "............", "............", "............", "............"},
	// A filled square.
	.Yes = {"............", ".##########.", ".##########.", ".##########.", ".##########.", ".##########.", ".##########.", ".##########.", ".##########.", ".##########.", "............", "............"},
	// An empty square.
	.No = {"............", ".##########.", ".#........#.", ".#........#.", ".#........#.", ".#........#.", ".#........#.", ".#........#.", ".#........#.", ".##########.", "............", "............"},
	// Two parentheses.
	.Procedure = {"............", "...#....#...", "..##....##..", "..#......#..", ".##......##.", ".##......##.", ".##......##.", "..#......#..", "..##....##..", "...#....#...", "............", "............"},
	// A lock.
	.Constant = {"............", "....####....", "...#....#...", "...#....#...", "..########..", "..########..", "..###..###..", "..###..###..", "..########..", "..########..", "............", "............"},
	// A cross of two diagonals.
	.Variable = {"............", ".##......##.", "..##....##..", "...##..##...", "....####....", ".....##.....", "....####....", "...##..##...", "..##....##..", ".##......##.", "............", "............"},
}

// The icon of each desktop kind.
@(rodata)
desktop_kind_cells := [Desktop_Kind]Cells {
	// A frame under a title bar of three rows.
	.Window = {"............", ".##########.", ".##########.", ".##########.", ".#........#.", ".#........#.", ".#........#.", ".#........#.", ".#........#.", ".##########.", "............", "............"},
	// Two sliders: a line with a knob at the left, a line with a knob at
	// the right.
	.Setting = {"............", "............", "...###......", ".##########.", "...###......", "............", "......###...", ".##########.", "......###...", "............", "............", "............"},
	// An arrow out of a box: the reverse of the icon of an operation.
	.Export = {"............", "######......", "#....#...#..", "#....#...##.", "#.##########", "#.##########", "#....#...##.", "#....#...#..", "######......", "............", "............", "............"},
	// A full block with a cross cut out of it, as the close button of a
	// window is a red square with a cross.
	.Stop = {"............", ".##########.", ".##########.", ".##.####.##.", ".###.##.###.", ".####..####.", ".####..####.", ".###.##.###.", ".##.####.##.", ".##########.", ".##########.", "............"},
}

// cells_of_value_kind gives the icon of a value kind, or nil for the kind
// None and for a value past the kinds.
cells_of_value_kind :: proc "contextless" (kind: value_kinds.Value_Kind) -> ^Cells {
	if kind == .None || u8(kind) > u8(max(value_kinds.Value_Kind)) {
		return nil
	}
	return &value_kind_cells[kind]
}

// cells_of_desktop_kind gives the icon of a desktop kind, or nil for a
// value past the kinds.
cells_of_desktop_kind :: proc "contextless" (kind: Desktop_Kind) -> ^Cells {
	if u8(kind) > u8(max(Desktop_Kind)) {
		return nil
	}
	return &desktop_kind_cells[kind]
}

// cell_is_set says if the cell of column x and row y is a cell of the
// icon. A place outside the grid, and a place past the end of a short row,
// is empty.
cell_is_set :: proc "contextless" (cells: ^Cells, x, y: int) -> bool {
	if cells == nil || x < 0 || y < 0 || y >= ICON_SIZE {
		return false
	}
	row := cells[y]
	return x < min(len(row), ICON_SIZE) && row[x] == '#'
}

// A rectangle of cells of an icon: its corner and its size, in cells.
Cell_Rectangle :: struct {
	x, y:          u8, // The column and the row of its top left cell.
	width, height: u8, // Its columns and its rows.
}

// The most rectangles that an icon can need: a host test holds each icon
// under it, so a display knows the records that a list of icons takes.
RECTANGLE_LIMIT :: 20

// rectangles_of gives the cells of an icon as rectangles that do not
// overlap, and their count: one for each run of cells of a row, and a run
// that the rows under it repeat exactly is one rectangle with them. A frame
// of one cell is then four rectangles, not one for each row. An icon that
// needs more than RECTANGLE_LIMIT rectangles gives its first ones.
rectangles_of :: proc "contextless" (cells: ^Cells, into: ^[RECTANGLE_LIMIT]Cell_Rectangle) -> int {
	count := 0
	for y in 0 ..< ICON_SIZE {
		x := 0
		for x < ICON_SIZE {
			if !cell_is_set(cells, x, y) {
				x += 1
				continue
			}
			start := x
			for x < ICON_SIZE && cell_is_set(cells, x, y) {
				x += 1
			}
			// The row above has the same run: its rectangle holds this one.
			if run_is_exact(cells, start, x, y - 1) {
				continue
			}
			height := 1
			for run_is_exact(cells, start, x, y + height) {
				height += 1
			}
			if count == RECTANGLE_LIMIT {
				return count
			}
			into[count] = {x = u8(start), y = u8(y), width = u8(x - start), height = u8(height)}
			count += 1
		}
	}
	return count
}

// run_is_exact says if the cells start ..< end of row y are one whole run:
// each one is set, and the cell before and the cell after are empty.
@(private)
run_is_exact :: proc "contextless" (cells: ^Cells, start, end, y: int) -> bool {
	if y < 0 || y >= ICON_SIZE || cell_is_set(cells, start - 1, y) || cell_is_set(cells, end, y) {
		return false
	}
	for x in start ..< end {
		if !cell_is_set(cells, x, y) {
			return false
		}
	}
	return true
}
