package interface

import "support:graphics"

// An area of the surface, where an element draws.
Area :: struct {
	x, y, width, height: int,
}

LINE :: graphics.LINE_HEIGHT // A line of text.
TABLE_LINE :: 24 // A line of a table or a list: a line of text and 8 pixels.

area_rectangle :: proc "contextless" (area: Area) -> Rectangle {
	return {area.x, area.y, area.x + area.width, area.y + area.height}
}

// area_inset gives the area inside a margin on each side.
area_inset :: proc "contextless" (area: Area, margin: int) -> Area {
	return {area.x + margin, area.y + margin, max(area.width - 2 * margin, 0), max(area.height - 2 * margin, 0)}
}

// area_contains says if a point is in an area.
area_contains :: proc "contextless" (area: Area, x, y: int) -> bool {
	return x >= area.x && y >= area.y && x < area.x + area.width && y < area.y + area.height
}

// A column gives areas from the top of its area down, with a gap between two.
Column :: struct {
	area: Area,
	used: int, // The pixels from the top that the column gave.
	gap:  int,
}

column_of :: proc "contextless" (area: Area, gap: int = 0) -> Column {
	return {area = area, gap = gap}
}

// column_take gives the next area of a column, of a height, as wide as the
// column. An area past the bottom has a height of 0.
column_take :: proc "contextless" (column: ^Column, height: int) -> Area {
	top := column.used + (column.used > 0 ? column.gap : 0)
	taken := clamp(height, 0, max(column.area.height - top, 0))
	column.used = top + max(height, 0)
	return {column.area.x, column.area.y + top, column.area.width, taken}
}

// column_rest gives what is left of a column.
column_rest :: proc "contextless" (column: ^Column) -> Area {
	top := column.used + (column.used > 0 ? column.gap : 0)
	return {column.area.x, column.area.y + top, column.area.width, max(column.area.height - top, 0)}
}

Size_Kind :: enum u8 {
	Pixels, // value pixels.
	Characters, // value characters of the font of the system.
	Share, // A part of what the fixed sizes leave, in proportion to value.
}

Size :: struct {
	kind:  Size_Kind,
	value: int,
}

pixels :: proc "contextless" (value: int) -> Size {
	return {.Pixels, value}
}
characters :: proc "contextless" (value: int) -> Size {
	return {.Characters, value}
}
share :: proc "contextless" (value: int = 1) -> Size {
	return {.Share, value}
}

// row_split splits an area into columns, in one pass: the caller gives the
// size of each column before it draws in them. The columns go into the
// memory of the caller. A Share column takes a part of the width that the
// fixed sizes and the gaps leave; the last Share column takes what the
// division leaves, so the columns fill the area. A negative size is 0; the
// fixed sizes are cut to the row; each column stays inside the row.
row_split :: proc "contextless" (area: Area, sizes: []Size, columns: []Area, gap: int = 0) {
	count := min(len(sizes), len(columns))
	if count == 0 {
		return
	}
	width := max(area.width, 0)
	fixed_width :: proc "contextless" (size: Size) -> int {
		switch size.kind {
		case .Pixels:
			return clamp(size.value, 0, 1 << 20)
		case .Characters:
			return clamp(size.value, 0, 1 << 16) * graphics.CELL_WIDTH
		case .Share:
		}
		return 0
	}
	fixed := max(gap, 0) * (count - 1)
	shares := 0
	last_share := -1
	for size, index in sizes[:count] {
		fixed += fixed_width(size)
		if size.kind == .Share {
			shares += clamp(size.value, 0, 1 << 20)
			last_share = index
		}
	}
	free := max(width - fixed, 0)
	given := 0
	x := area.x
	right := area.x + width
	for size, index in sizes[:count] {
		column_width := fixed_width(size)
		if size.kind == .Share {
			column_width = index == last_share ? free - given : free * clamp(size.value, 0, 1 << 20) / max(shares, 1)
			given += column_width
		}
		start := min(x, right)
		columns[index] = {start, area.y, clamp(column_width, 0, right - start), area.height}
		x += column_width + max(gap, 0)
	}
}
