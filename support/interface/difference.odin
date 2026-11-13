package interface

import "base:intrinsics"
import "support:graphics"

DAMAGE_CAPACITY :: 8 // The rectangles that one frame keeps, as the compositor does.

// Damage: the rectangles of a surface that changed between two frames. The
// caller gives the memory of the rectangles.
Damage :: struct {
	rectangles: [DAMAGE_CAPACITY]Rectangle, // The rectangles; no two of them touch.
	count:      int, // The rectangles in use.
}

// damage_add records that a rectangle changed. Rectangles that touch become
// one rectangle; with no room left, the new rectangle joins the first one.
damage_add :: proc "contextless" (damage: ^Damage, rectangle: Rectangle) {
	area := rectangle
	if empty(area) {
		return
	}
	index := 0
	for index < damage.count {
		other := damage.rectangles[index]
		apart := area.left > other.right || other.left > area.right || area.top > other.bottom || other.top > area.bottom
		if apart && damage.count < DAMAGE_CAPACITY {
			index += 1
			continue
		}
		area = {min(area.left, other.left), min(area.top, other.top), max(area.right, other.right), max(area.bottom, other.bottom)}
		damage.count -= 1
		damage.rectangles[index] = damage.rectangles[damage.count]
		index = 0 // The larger rectangle can touch one that it did not touch before.
	}
	damage.rectangles[damage.count] = area
	damage.count += 1
}

// damage_bounds gives the one rectangle that holds each damage rectangle.
damage_bounds :: proc "contextless" (damage: ^Damage) -> Rectangle {
	if damage.count == 0 {
		return {}
	}
	bounds := damage.rectangles[0]
	for rectangle in damage.rectangles[1:damage.count] {
		bounds = {min(bounds.left, rectangle.left), min(bounds.top, rectangle.top), max(bounds.right, rectangle.right), max(bounds.bottom, rectangle.bottom)}
	}
	return bounds
}

// records_equal says if two records draw the same thing: their 40 bytes are
// equal, except the places of their texts in the two text tables, and the
// bytes of their texts are equal. A text record whose range is not inside
// its text table is equal to no record: its rectangle is damaged, and the
// execution draws nothing for it. The check is on the records that it
// receives, the copies that it compares.
records_equal :: proc "contextless" (before: ^Draw_Table, old: Draw_Record, now: ^Draw_Table, new: Draw_Record) -> bool {
	old_without_place, new_without_place := old, new
	// Only a text has a place that can change with no change of what is
	// drawn. For a picture or a text grid, the same field is its index.
	if is_text_kind(old.kind) && old.kind == new.kind {
		old_without_place.text_start, new_without_place.text_start = 0, 0
	}
	if (transmute([size_of(Draw_Record)]u8)old_without_place) != (transmute([size_of(Draw_Record)]u8)new_without_place) {
		return false
	}
	if !is_text_kind(old.kind) {
		return true
	}
	if u64(old.text_start) + u64(old.text_count) > u64(before.text_count) || u64(new.text_start) + u64(new.text_count) > u64(now.text_count) {
		return false
	}
	return string(before.text[old.text_start:][:old.text_count]) == string(now.text[new.text_start:][:new.text_count])
}

// damage_by_difference finds what changed from the table before to the
// table now, record by record at the same index: where two records differ,
// the rectangle of the old one and the rectangle of the new one are damaged;
// the records after the end of the shorter table are damaged. A record added
// in the middle damages each record after it: the damage can be too large,
// never too small (docs/INTERFACE.md, section 2.2).
damage_by_difference :: proc "contextless" (before, now: ^Draw_Table, damage: ^Damage) {
	shared := min(before.record_count, now.record_count)
	for index in 0 ..< shared {
		// One copy of each record: a table can be in memory that another
		// program writes during the call (the interface as a module).
		old := intrinsics.volatile_load(&before.records[index])
		new := intrinsics.volatile_load(&now.records[index])
		if records_equal(before, old, now, new) {
			if new.kind == .Text_Grid {
				grid_damage(before, now, new, damage)
			}
			continue
		}
		// A clip that changes changes what the next records draw.
		if old.kind == .Clip || new.kind == .Clip {
			damage_rest(before, now, index, damage)
			return
		}
		damage_add(damage, record_rectangle(old))
		damage_add(damage, record_rectangle(new))
	}
	for record in before.records[shared:before.record_count] {
		damage_add(damage, record_rectangle(record))
	}
	for record in now.records[shared:now.record_count] {
		damage_add(damage, record_rectangle(record))
	}
}

// damage_rest damages each record of the two tables from an index to the end.
@(private)
damage_rest :: proc "contextless" (before, now: ^Draw_Table, first: int, damage: ^Damage) {
	for record in before.records[first:before.record_count] {
		if record.kind != .Clip {
			damage_add(damage, record_rectangle(record))
		}
	}
	for record in now.records[first:now.record_count] {
		if record.kind != .Clip {
			damage_add(damage, record_rectangle(record))
		}
	}
}

// grid_damage damages, in each row of a grid that did not move, the span
// from the first changed cell to the last one. A grid that the table before
// does not have is damaged whole.
@(private)
grid_damage :: proc "contextless" (before, now: ^Draw_Table, record: Draw_Record, damage: ^Damage) {
	index := int(record.text_start)
	if index >= len(before.grids) || index >= len(now.grids) {
		damage_add(damage, record_rectangle(record))
		return
	}
	old, new := before.grids[index], now.grids[index]
	if old.columns != new.columns || old.rows != new.rows || !grid_valid(old) || !grid_valid(new) {
		damage_add(damage, record_rectangle(record))
		return
	}
	x, y := int(record.x), int(record.y)
	for row in 0 ..< new.rows {
		old_row := old.cells[row * old.stride:][:new.columns]
		new_row := new.cells[row * new.stride:][:new.columns]
		first, last := -1, -1
		for column in 0 ..< new.columns {
			if old_row[column] != new_row[column] {
				if first < 0 {
					first = column
				}
				last = column
			}
		}
		if first >= 0 {
			top := y + row * graphics.CELL_HEIGHT
			damage_add(damage, {x + first * graphics.CELL_WIDTH, top, x + (last + 1) * graphics.CELL_WIDTH, top + graphics.CELL_HEIGHT})
		}
	}
}

// damage_of_two_pictures finds, for a surface with two pictures, what to
// draw and what to present. The program draws into the picture that showed
// the table own_before; the screen shows the other picture, with the table
// shown. draw: the difference with own_before, the pixels of this picture
// to make again. present: draw and the difference with shown, because the
// screen must change wherever it shows something other than now. When the
// table of the shown picture is not known, the screen can show anything
// that an older frame drew, also where the frame now draws nothing: present
// is then the whole surface.
damage_of_two_pictures :: proc "contextless" (own_before, shown: ^Draw_Table, shown_drawn: bool, now: ^Draw_Table, surface: Rectangle, draw, present: ^Damage) {
	damage_by_difference(own_before, now, draw)
	present^ = draw^
	if !shown_drawn {
		damage_add(present, surface)
		return
	}
	shown_damage: Damage
	damage_by_difference(shown, now, &shown_damage)
	for rectangle in shown_damage.rectangles[:shown_damage.count] {
		damage_add(present, rectangle)
	}
}
