// A module of commands that take a record or a handle (property 19). A
// record is bytes with described fields: the caller and the module read the
// same layout. A handle is lent for the time of one call, with the rights
// that the description names and no other right.
// The console calls it with load("sample") or isolate("sample").
package sample

import op "contract:operation"
import "support:system"

// A rectangle, in any unit.
Rectangle :: struct {
	x:      i64,
	y:      i64,
	width:  i64,
	height: i64,
}

// A part of a memory object: `count` bytes from byte `first`.
Span :: struct {
	memory: system.Lent({.Read}),
	first:  i64,
	count:  i64,
}

// area gives the width of a rectangle times its height.
@(export, link_name = "area")
area :: proc "c" (rectangle: ^Rectangle) -> i64 {
	return rectangle.width * rectangle.height
}

// grow gives a rectangle with a margin of `by` on each side.
@(export, link_name = "grow")
grow :: proc "c" (rectangle: ^Rectangle, by: i64, result: ^Rectangle) {
	result^ = {rectangle.x - by, rectangle.y - by, rectangle.width + 2 * by, rectangle.height + 2 * by}
}

// bytes_of maps a memory object for the time of one export. count is 0 when
// the kernel refuses; then status says why.
@(private)
bytes_of :: proc "contextless" (memory: system.Handle, flags: op.Map_Flags) -> (bytes: []u8, status: system.Status) {
	address := system.memory_map(memory, flags) or_return
	return ([^]u8)(address)[:system.memory_size(memory) * system.PAGE_SIZE], .Ok
}

// fill writes a value in each byte of a memory object, and gives the count
// of bytes. The caller lends the object to read and to write.
@(export, link_name = "fill")
fill :: proc "c" (memory: system.Lent({.Read, .Write}), value: i64) -> i64 {
	bytes, status := bytes_of(memory.handle, {.Write})
	if status != .Ok {
		return -i64(status)
	}
	for &b in bytes {
		b = u8(value)
	}
	system.memory_unmap(raw_data(bytes))
	return i64(len(bytes))
}

// total adds the bytes of a memory object. The caller lends the object to
// read only.
@(export, link_name = "total")
total :: proc "c" (memory: system.Lent({.Read})) -> i64 {
	bytes, status := bytes_of(memory.handle, {})
	if status != .Ok {
		return -i64(status)
	}
	sum: i64
	for b in bytes {
		sum += i64(b)
	}
	system.memory_unmap(raw_data(bytes))
	return sum
}

// span_total adds the bytes of a part of a memory object. The handle is a
// field of the record.
@(export, link_name = "span_total")
span_total :: proc "c" (span: ^Span) -> i64 {
	bytes, status := bytes_of(span.memory.handle, {})
	if status != .Ok {
		return -i64(status)
	}
	sum: i64
	if span.first >= 0 && span.count >= 0 && span.first <= i64(len(bytes)) && span.count <= i64(len(bytes)) - span.first {
		for b in bytes[span.first:][:span.count] {
			sum += i64(b)
		}
	}
	system.memory_unmap(raw_data(bytes))
	return sum
}

// spoil tries to write in a memory object that the caller lent to read. The
// result is the status of the kernel: 7 is "no right".
@(export, link_name = "spoil")
spoil :: proc "c" (memory: system.Lent({.Read})) -> i64 {
	bytes, status := bytes_of(memory.handle, {.Write})
	if status == .Ok {
		bytes[0] = 0xFF
		system.memory_unmap(raw_data(bytes))
	}
	return i64(status)
}

held: system.Handle

// keep remembers the handle that the caller lent, for a later call of kept.
@(export, link_name = "keep")
keep :: proc "c" (memory: system.Lent({.Read})) -> i64 {
	held = memory.handle
	return total(memory)
}

// kept uses the handle that keep remembered. The result is the status of
// the kernel: 2 is "no handle", because a lent handle ends with its call.
@(export, link_name = "kept")
kept :: proc "c" () -> i64 {
	bytes, status := bytes_of(held, {})
	if status == .Ok {
		system.memory_unmap(raw_data(bytes))
	}
	return i64(status)
}

view: []u8

// hold maps a memory object that the caller lent, keeps the mapping for a
// later call of look, and gives the first byte.
@(export, link_name = "hold")
hold :: proc "c" (memory: system.Lent({.Read})) -> i64 {
	bytes, status := bytes_of(memory.handle, {})
	if status != .Ok {
		return -i64(status)
	}
	view = bytes
	return i64(bytes[0])
}

// look reads the first byte through the mapping that hold kept. After an
// isolated call the caller revoked what it lent: the kernel removed the
// mapping, and the program of this module stops on a page fault.
@(export, link_name = "look")
look :: proc "c" () -> i64 {
	return len(view) == 0 ? -1 : i64(view[0])
}
