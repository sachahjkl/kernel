// A module of commands that take a record, a handle or a table, never text
// that the module must parse. A record is bytes with described fields: the
// caller and the module read the same layout. A handle is lent for the time of one call, with the
// rights that the description names and no other right. A table is records
// of one description in memory of the caller, with a direction: Read,
// Change or Append.
// The console calls it with load("sample"), isolate("sample") or
// connect("sample"): the module has an entry, so the same module also runs
// as a program that serves its exports. A service holds no export that is
// wrong on purpose: those are in the module hostile_exports, which no
// service holds.
//
// **What it is for.** It is the reference module of the call form for
// everything that is not an integer or a text: records, lent handles, and
// tables in each direction. The program `tables` calls it in three ways
// with the same arguments and compares the answers; the console tests call
// it the same way.
//
// **Example**, in the console:
//
// ```
// load("sample")
// t = readings(4)        a table of 4 readings: values 10, 20, 30, 40
// sum_values(t)          100
// scale_values(t, 3)     4; t now holds 30, 60, 90, 120
// ```
//
// **As a service**: the root service starts it on demand when a program
// with the grant to connect to it asks for `sample`. Its only grant is
// **Serve**.
//
// The design: (docs/MODULE_CONTRACT.md, "Tables and bytes as parameters")
// and (docs/MODULE_CONTRACT.md, "Records and handles, as implemented").
package sample

import "base:intrinsics"
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
//
// The rectangle is a record of four integers; the caller writes it as `Rectangle{x = 0, y = 0, width = 3, height = 4}`, and the result is 12. A negative width gives a negative area: the module checks nothing.
@(export, link_name = "area")
area :: proc "c" (rectangle: ^Rectangle) -> i64 {
	return rectangle.width * rectangle.height
}

// grow gives a rectangle with a margin of `by` on each side.
//
// The result is a record that the export writes in the memory of the caller (in an isolated call, in the call region). A negative `by` shrinks the rectangle.
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
//
// The handle is lent for this call only: the module cannot keep it. The value is taken modulo 256. A negative
// result is the status of the kernel, negated, when the map is refused.
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
//
// A negative result is the status of the kernel, negated, when the map is refused.
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
//
// A span outside the object gives 0: the export checks first, count and their sum against the size. The handle
// in a record is lent as a handle parameter is: the rights of the field description, for the call only.
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
//
// The handle has the right Read only, as the description says, so the kernel refuses the map with Write. The
// result 0 means that the lent handle had more rights than its description.
@(export, link_name = "spoil")
spoil :: proc "c" (memory: system.Lent({.Read})) -> i64 {
	bytes, status := bytes_of(memory.handle, {.Write})
	if status == .Ok {
		bytes[0] = 0xFF
		system.memory_unmap(raw_data(bytes))
	}
	return i64(status)
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

// sum_words writes in each word the sum of the bytes of the text that the word names, and gives the sum of all. A word that names bytes after the end of the text is an error, not a fault: the result is -1 with an error record of the kind Out_Of_Range (the end of the bytes of the word, the count of bytes of the text, and the number of the word).
@(export, link_name = "sum_words")
sum_words :: proc "c" (words: ^system.Table_To_Change(Word), text: ^system.Bytes_To_Read, error: ^errors.Error_Record) -> i64 {
	total: i64
	for &word, number in system.table_changed_records(words) {
		// The rule of an export (docs/MODULE_CONTRACT.md): it copies a
		// record before it checks it, and uses only the copy. In an
		// isolated call the records are in the call region, which another
		// thread of the caller can change during the call. One volatile
		// load: the compiler cannot read the record a second time.
		copied := intrinsics.volatile_load(&word)
		end := u64(copied.start) + u64(copied.count)
		if end > text.count {
			return errors.fail(error, -1, .Out_Of_Range, .Bytes, 1, i64(end), i64(text.count), i64(number + 1))
		}
		sum: i64
		for b in text.bytes[copied.start:end] {
			sum += i64(b)
		}
		word.sum = sum
		total += sum
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

// scale_values_up_to multiplies the value, the minimum and the maximum of each reading by a factor, in order, in the memory of the caller (the direction Change), while each new value stays at most largest_value, and gives the count of readings. At the first reading whose value would pass it, it stops with -1 and an error record Bad_Value for the factor, with the largest factor that this reading takes: the readings before it are already changed. A caller in another program receives none of these changes: a failed export gives back only its table of error details.
//
// A factor under 1 fails at once with -1 and an error record `Too_Small` for the factor, with the limit 1; no
// reading changes.
@(export, link_name = "scale_values_up_to")
scale_values_up_to :: proc "c" (readings: ^system.Table_To_Change(Reading), factor: i64, largest_value: i64, error: ^errors.Error_Record) -> i64 {
	if factor < 1 {
		return errors.fail(error, -1, .Too_Small, .None, 2, factor, 1)
	}
	for &reading in system.table_changed_records(readings) {
		// The record is copied before it is checked: in an isolated call it
		// is in the call region, which the caller can change during the call.
		copied := intrinsics.volatile_load(&reading)
		if copied.value > largest_value / factor {
			return errors.fail(error, -1, .Bad_Value, .None, 2, factor, copied.value > 0 ? largest_value / copied.value : 0)
		}
		reading = {sensor = copied.sensor, time = copied.time, value = copied.value * factor, minimum = copied.minimum * factor, maximum = copied.maximum * factor}
	}
	return i64(readings.count)
}

// The same module as a program: a service that serves the exports above.
// An export needs nothing from the entry.
//
// The entry opens the service ring; with none it writes "sample: no service
// ring" and stops with the code 1. It writes "sample: serves its exports",
// then waits for calls and runs them for ever. It has no window.
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
