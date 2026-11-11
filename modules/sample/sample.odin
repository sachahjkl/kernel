// A module of commands that take a record, a handle or a table (property
// 19). A record is bytes with described fields: the caller and the module
// read the same layout. A handle is lent for the time of one call, with the
// rights that the description names and no other right. A table is records
// of one description in memory of the caller, with a direction: Read,
// Change or Append.
// The console calls it with load("sample"), isolate("sample") or
// connect("sample"): the module has an entry, so the same module also runs
// as a program that serves its exports.
package sample

import "contract:errors"
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

// A reading of a sensor: one record of 40 bytes of a table.
Reading :: struct {
	sensor:  i64,
	time:    i64,
	value:   i64,
	minimum: i64,
	maximum: i64,
}

// readings gives a table of `count` readings: sensor n, time n, value 10 * (n + 1). The result is a Table of the readings that fit in the memory of the caller, and its count is `count`.
@(export, link_name = "readings")
readings :: proc "c" (count: i64, result: ^[]Reading) -> i64 {
	for number in 0 ..< max(count, 0) {
		if int(number) < len(result) {
			value := 10 * (number + 1)
			result[number] = {sensor = number, time = number, value = value, minimum = value, maximum = value}
		}
	}
	return max(count, 0)
}

// sum_values gives the sum of the values of a table of readings. The export reads the table: the direction Read.
@(export, link_name = "sum_values")
sum_values :: proc "c" (readings: ^system.Table_To_Read(Reading)) -> i64 {
	sum: i64
	for reading in system.table_records(readings) {
		sum += reading.value
	}
	return sum
}

// scale_values multiplies the value, the minimum and the maximum of each reading by a factor, in the memory of the caller (the direction Change), and gives the count of readings.
@(export, link_name = "scale_values")
scale_values :: proc "c" (readings: ^system.Table_To_Change(Reading), factor: i64) -> i64 {
	for &reading in system.table_changed_records(readings) {
		reading.value *= factor
		reading.minimum *= factor
		reading.maximum *= factor
	}
	return i64(readings.count)
}

// append_readings appends `count` readings after those of the table (the direction Append): sensor n, time n, value first_value + n. It writes those that fit before the capacity, and adds `count` to the count of the table: a count larger than the capacity says that they did not all fit. The result is the count of readings that it wrote.
@(export, link_name = "append_readings")
append_readings :: proc "c" (count: i64, first_value: i64, readings: ^system.Table_To_Append(Reading)) -> i64 {
	written: i64
	for number in 0 ..< max(count, 0) {
		value := first_value + number
		reading := Reading{sensor = i64(readings.count), time = number, value = value, minimum = value, maximum = value}
		written += system.table_append(readings, reading) ? 1 : 0
	}
	return written
}

// A word of a text: the record names its bytes by offset in another
// parameter; it holds no address.
Word :: struct {
	start: u32, // The first byte of the word in the text.
	count: u32, // Its bytes.
	sum:   i64, // Written by the export: the sum of its bytes.
}

// sum_words writes in each word the sum of the bytes of the text that the word names, and gives the sum of all. A word that names bytes after the end of the text is an error, not a fault: the result is -1 with an error record of the kind Outside (the number of the word, the end of its bytes, the count of bytes of the text).
@(export, link_name = "sum_words")
sum_words :: proc "c" (words: ^system.Table_To_Change(Word), text: ^system.Bytes_To_Read, error: ^errors.Error_Record) -> i64 {
	total: i64
	for &word, number in system.table_changed_records(words) {
		end := u64(word.start) + u64(word.count)
		if end > text.count {
			return errors.fail(error, -1, .Outside, .Bytes, 1, i64(end), i64(text.count), i64(number + 1))
		}
		word.sum = 0
		for b in text.bytes[word.start:end] {
			word.sum += i64(b)
		}
		total += word.sum
	}
	return total
}

// upper_case changes each letter of a range of bytes to upper case, in the memory of the caller (Bytes with the direction Change), and gives the count of letters that it changed.
@(export, link_name = "upper_case")
upper_case :: proc "c" (text: ^system.Bytes_To_Change) -> i64 {
	changed: i64
	for &b in text.bytes[:text.count] {
		if b >= 'a' && b <= 'z' {
			b -= 'a' - 'A'
			changed += 1
		}
	}
	return changed
}

// append_past_capacity writes 4 readings after the capacity of the table, against the rule of the direction Append: a test of the caller. In a direct call the caller and the module share one address space, and the caller has no protection. In an isolated call the caller copies back the readings up to the capacity only.
@(export, link_name = "append_past_capacity")
append_past_capacity :: proc "c" (readings: ^system.Table_To_Append(Reading)) -> i64 {
	for number in readings.capacity ..< readings.capacity + 4 {
		readings.records[number] = {sensor = -1, time = -1, value = -1, minimum = -1, maximum = -1}
	}
	readings.count = readings.capacity + 4
	return 4
}

// The same module as a program: a service that serves the exports above.
// An export needs nothing from the entry.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	service, ok := system.service_open(ctx)
	if !ok {
		system.log("sample: no service ring")
		system.stop(1)
	}
	system.log("sample: serves its exports")
	for {
		wait: system.Wait
		system.service_wait(&wait, &service)
		system.wait_end(&wait)
		system.service_run(&service)
	}
}
