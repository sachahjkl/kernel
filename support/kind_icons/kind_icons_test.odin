#+build !freestanding
package kind_icons

import "contract:value_kinds"
import "core:fmt"
import "core:strings"
import "core:testing"

// The least cells of an icon: with fewer, a form of 12 pixels does not read.
@(private = "file")
SET_CELLS_LEAST :: 12

// One icon of the test: its name and its cells.
@(private = "file")
Named_Icon :: struct {
	name:  string,
	cells: ^Cells,
}

// Each icon of the package, the value kinds first.
@(private = "file")
each_icon :: proc() -> []Named_Icon {
	icons := make([dynamic]Named_Icon, context.temp_allocator)
	for kind in value_kinds.Value_Kind {
		if kind != .None {
			append(&icons, Named_Icon{fmt.tprintf("value kind %v", kind), cells_of_value_kind(kind)})
		}
	}
	for kind in Desktop_Kind {
		append(&icons, Named_Icon{fmt.tprintf("desktop kind %v", kind), cells_of_desktop_kind(kind)})
	}
	return icons[:]
}

// The text art of an icon: two characters for each cell, so that a cell is
// about square in a log.
@(private = "file")
text_art :: proc(cells: ^Cells) -> string {
	art := strings.builder_make(context.temp_allocator)
	for y in 0 ..< ICON_SIZE {
		strings.write_string(&art, "\n    ")
		for x in 0 ..< ICON_SIZE {
			strings.write_string(&art, cell_is_set(cells, x, y) ? "##" : " .")
		}
	}
	return strings.to_string(art)
}

// Each kind has an icon; each icon is 12 rows of 12 cells, set or empty;
// each has enough cells to read; no two icons are equal. The log shows
// each icon as text art, for a reader of the test.
@(test)
each_icon_is_whole_and_no_two_are_equal :: proc(t: ^testing.T) {
	seen := make(map[string]string, context.temp_allocator)
	for icon in each_icon() {
		if !testing.expectf(t, icon.cells != nil, "the %s has no icon", icon.name) {
			continue
		}
		set_cells := 0
		for row in icon.cells^ {
			testing.expectf(t, len(row) == ICON_SIZE, "a row of the icon of the %s has %d cells", icon.name, len(row))
			for index in 0 ..< len(row) {
				testing.expectf(t, row[index] == '#' || row[index] == '.', "the icon of the %s has the cell %c", icon.name, row[index])
				set_cells += row[index] == '#' ? 1 : 0
			}
		}
		testing.expectf(t, set_cells >= SET_CELLS_LEAST, "the icon of the %s has %d cells; at least %d", icon.name, set_cells, SET_CELLS_LEAST)
		joined := strings.join(icon.cells^[:], "", context.temp_allocator)
		if other, found := seen[joined]; found {
			testing.expectf(t, false, "the %s and the %s have the same icon", icon.name, other)
		}
		seen[joined] = icon.name
		rectangles: [RECTANGLE_LIMIT]Cell_Rectangle
		fmt.printfln("kind_icons: the %s: %d cells, %d rectangles%s", icon.name, set_cells, rectangles_of(icon.cells, &rectangles), text_art(icon.cells))
	}
	// The kind None and a kind past the enumerations have no icon.
	testing.expect(t, cells_of_value_kind(.None) == nil)
	testing.expect(t, cells_of_value_kind(value_kinds.Value_Kind(200)) == nil)
	testing.expect(t, cells_of_desktop_kind(Desktop_Kind(200)) == nil)
}

// The rectangles of an icon cover each of its cells once and no empty
// cell, stay inside the grid, and are fewer than the limit: a display that
// draws the rectangles draws the icon.
@(test)
rectangles_are_the_cells :: proc(t: ^testing.T) {
	for icon in each_icon() {
		if icon.cells == nil {
			continue
		}
		rectangles: [RECTANGLE_LIMIT]Cell_Rectangle
		count := rectangles_of(icon.cells, &rectangles)
		testing.expectf(t, count > 0 && count < RECTANGLE_LIMIT, "the icon of the %s has %d rectangles; under %d", icon.name, count, RECTANGLE_LIMIT)
		covered: [ICON_SIZE][ICON_SIZE]int
		for rectangle in rectangles[:count] {
			testing.expectf(t, rectangle.width > 0 && rectangle.height > 0 && int(rectangle.x) + int(rectangle.width) <= ICON_SIZE && int(rectangle.y) + int(rectangle.height) <= ICON_SIZE, "a rectangle of the icon of the %s is not in the grid: %v", icon.name, rectangle)
			for y in int(rectangle.y) ..< min(int(rectangle.y) + int(rectangle.height), ICON_SIZE) {
				for x in int(rectangle.x) ..< min(int(rectangle.x) + int(rectangle.width), ICON_SIZE) {
					covered[y][x] += 1
				}
			}
		}
		for y in 0 ..< ICON_SIZE {
			for x in 0 ..< ICON_SIZE {
				expected := cell_is_set(icon.cells, x, y) ? 1 : 0
				testing.expectf(t, covered[y][x] == expected, "the icon of the %s: the cell %d,%d is covered %d times, not %d", icon.name, x, y, covered[y][x], expected)
			}
		}
	}
}

// A frame of one cell is four rectangles, a full block one, and two runs
// that only touch stay apart.
@(test)
rectangles_join_the_rows_of_one_run :: proc(t: ^testing.T) {
	rectangles: [RECTANGLE_LIMIT]Cell_Rectangle
	// The icon of the kind No: an empty square, rows 1 to 9, columns 1 to 10.
	count := rectangles_of(cells_of_value_kind(.No), &rectangles)
	testing.expect_value(t, count, 4)
	testing.expect_value(t, rectangles[0], Cell_Rectangle{1, 1, 10, 1})
	testing.expect_value(t, rectangles[1], Cell_Rectangle{1, 2, 1, 7})
	testing.expect_value(t, rectangles[2], Cell_Rectangle{10, 2, 1, 7})
	testing.expect_value(t, rectangles[3], Cell_Rectangle{1, 9, 10, 1})
	// The icon of the kind Yes: one block.
	count = rectangles_of(cells_of_value_kind(.Yes), &rectangles)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, rectangles[0], Cell_Rectangle{1, 1, 10, 9})
	// No icon: no rectangle, and no cell is set outside the grid.
	testing.expect_value(t, rectangles_of(nil, &rectangles), 0)
	testing.expect(t, !cell_is_set(cells_of_value_kind(.Yes), -1, 1) && !cell_is_set(cells_of_value_kind(.Yes), 1, ICON_SIZE) && !cell_is_set(cells_of_value_kind(.Yes), ICON_SIZE, 1))
	testing.expect(t, cell_is_set(cells_of_value_kind(.Yes), 1, 1))
}
