// Exports that are wrong on purpose, for the tests of the callers
// (docs/MODULE_CONTRACT.md, "Tables and bytes as parameters"). This module
// has no entry: no service holds it, and `remote` cannot reach it. A
// program loads it, or a call host runs it, and only a test does so.
//
// **What it is for.** A caller must survive a callee that breaks the
// rules. Each export breaks one rule of the call form, and the program
// `tables` checks what the caller sees:
//
// - keep and kept: a lent handle ends with its call, so a later use of it
//   gets "no handle";
// - hold and look: a mapping of a lent object ends with its call, so a
//   later read through it faults in the program of the module, not in the
//   caller;
// - append_past_capacity: a write past the capacity of a table reaches the
//   caller only in a direct call, where the two share one address space.
//
// The lesson: an isolated call protects the caller; a direct call trusts
// the module.
package hostile_exports

import op "modus:contract/operation"
import "modus:support/system"

// bytes_of maps a memory object for the time of one export. count is 0 when
// the kernel refuses; then status says why.
@(private)
bytes_of :: proc "contextless" (memory: system.Handle, flags: op.Map_Flags) -> (bytes: []u8, status: system.Status) {
	address := system.memory_map(memory, flags) or_return
	return ([^]u8)(address)[:system.memory_size(memory) * system.PAGE_SIZE], .Ok
}

// total adds the bytes of a memory object.
@(private)
total :: proc "contextless" (memory: system.Lent({.Read})) -> i64 {
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

held: system.Handle

// keep remembers the handle that the caller lent, for a later call of kept.
//
// The result is the sum of the bytes of the object, read during the call, or a negative status of the kernel.
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
//
// A negative result is the status of the kernel, negated, when the map is refused.
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
//
// In a direct call nothing was revoked: the mapping is still there, and the result is the first byte. With no
// earlier hold, the result is -1.
@(export, link_name = "look")
look :: proc "c" () -> i64 {
	return len(view) == 0 ? -1 : i64(view[0])
}

// A reading of a sensor: the record of sample, 40 bytes.
Reading :: struct {
	sensor:  i64,
	time:    i64,
	value:   i64,
	minimum: i64,
	maximum: i64,
}

// append_past_capacity writes 4 readings after the capacity of the table, against the rule of the direction Append: a test of the caller. In a direct call the caller and the module share one address space, and the caller has no protection. In an isolated call the caller copies back the readings up to the capacity only.
//
// The result is 4, and the count of the table claims 4 records more than its capacity: the caller must not believe
// it.
@(export, link_name = "append_past_capacity")
append_past_capacity :: proc "c" (readings: ^system.Table_To_Append(Reading)) -> i64 {
	for number in readings.capacity ..< readings.capacity + 4 {
		readings.records[number] = {sensor = -1, time = -1, value = -1, minimum = -1, maximum = -1}
	}
	readings.count = readings.capacity + 4
	return 4
}

