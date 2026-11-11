package interface

import "base:intrinsics"

DAMAGE_CAPACITY :: 8 // The rectangles that one frame keeps, as the compositor does.

// Damage: the rectangles of a surface that changed between two frames. The
// caller gives the memory of the rectangles.
Damage :: struct {
	rectangles: [DAMAGE_CAPACITY]Rectangle,
	count:      int,
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
	old_without_place.text_start, new_without_place.text_start = 0, 0
	if (transmute([size_of(Draw_Record)]u8)old_without_place) != (transmute([size_of(Draw_Record)]u8)new_without_place) {
		return false
	}
	if old.kind != .Text {
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
