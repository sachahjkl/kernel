package inspect

import "modus:contract/errors"
import "modus:contract/isolated"
import op "modus:contract/operation"
import "modus:support/addresses"
import "modus:support/system"

// The same facts as the window, as tables of records, not text: a caller
// that acts for the principal reads them, the remote service among them:
// kerneltool call "inspect.mappings(\"console\")". The facts are of another
// program, and a program sees no other program, so a caller that does not
// act for the principal gets a refusal.

// One mapping of a program: mappings().
Mapping :: struct {
	address: i64,
	module:  [32]u8, // The module that holds the address, or empty.
	offset:  i64, // The offset of the address in that module.
	pages:   i64,
	present: i64, // The pages with a page frame.
	kind:    [16]u8, // module code, module constants, module data, thread area, device, shared, memory.
	rights:  [4]u8, // r, w, x: what the program can do with the pages.
	object:  i64, // The serial of the memory object: two rows with one serial map one object.
	names:   i64, // The handles and the mappings that name the memory object, in all programs.
}

// One thread of a program: threads().
Thread :: struct {
	number:    i64, // The thread area.
	state:     [8]u8, // created, ready, waiting or stopped.
	processor: i64, // 1 + the processor that runs it. 0: none.
	home:      i64, // The processor of its run queue.
	weight:    i64,
	request:   i64, // Microseconds.
	virtual:   i64,
	lag:       i64,
	time:      i64, // Milliseconds of processor time.
	words:     i64, // The words of its word wait.
	deadline:  i64, // The end of its wait, in milliseconds since the start; -1: none.
}

// One module of a program: modules().
Module :: struct {
	name: [32]u8, // The name in the boot image, or empty.
	hash: [64]u8,
	base: i64,
	size: i64,
}

ERROR_ACTS_FOR_PRINCIPAL :: -1
ERROR_ABSENT :: -2
ERROR_CHANGED :: -3 // The program of the slot changed during the call, three times.

service: system.Service
// The reports of a call: memory of this program, not of the window.
call_mappings: op.Program_Mapping_Report
call_modules: op.Module_Report
call_threads: op.Thread_Table_Report

@(private = "file")
program_find :: proc "contextless" (name: ^string, error: ^errors.Error_Record) -> (slot: u64, failure: i64) {
	if caller := system.service_caller(); caller != nil && caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL == 0 {
		return 0, errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	// One copy: the caller can change the call region during the call.
	copied: [32]u8
	if len(name^) >= len(copied) {
		return 0, errors.fail(error, ERROR_ABSENT, .Absent, .Programs, 1)
	}
	count := copy(copied[:], name^)
	slot = slot_of(string(copied[:count]))
	if slot == 0 {
		return 0, errors.fail(error, ERROR_ABSENT, .Absent, .Programs, 1)
	}
	return slot, 0
}

// mappings gives one row for each mapping of the program with this name, in the order of the addresses: the address, the module and the offset when a module holds it, the pages, the pages with a page frame, the kind, the rights, the memory object and how many handles and mappings name it. The result is the count of rows, or a negative number with an error record. The error kinds: No_Grant (-1, the caller does not act for the principal); Absent (-2, no program has this name); Absent (-3, a new program took the slot during the call, three times).
//
// **What it is for.** It shows where the memory of a program is and what
// holds it: the code and the data of each module, the thread areas, the
// device memory, the memory that two programs share. A caller compares two
// rows by `object`: one serial is one [memory object](term:memory-object).
//
// **Parameter**: `program`, the name of a program that runs, as
// `programs()` lists it (at most 31 bytes). If two programs have that name,
// the one in the lowest slot answers.
//
// **Grant**: the caller must **act for the principal**: the facts are of
// another program, and a program sees no other program.
//
// **A row** (`Mapping`): `address`; `module` and `offset` when a module
// record holds the address; `pages`; `present`, the pages with a page
// frame; `kind`; `rights`, as `r`, `w`, `x` or `-`; `object`, the serial of
// the memory object; `names`, the handles and mappings that name it in all
// programs.
//
// **Errors**:
//
// - `No_Grant` (-1): the caller does not act for the principal.
// - `Absent` (-2): no program has this name, or the name has 32 bytes or
//   more.
// - `Absent` (-3): a new program took the slot between the two reports of
//   the call, three times in a row.
//
// ```
// connect("inspect")
// where(inspect.mappings("console"), "kind", "shared")
// ```
@(export, link_name = "mappings")
mappings :: proc "c" (program: ^string, result: ^[]Mapping, error: ^errors.Error_Record) -> i64 {
	slot, failure := program_find(program, error)
	if slot == 0 {
		return failure
	}
	// Two reports: read them again when a new program took the slot between
	// them (their serials differ).
	for _ in 0 ..< 3 {
		inspect_call(.Program_Mappings, slot, &call_mappings, size_of(call_mappings))
		inspect_call(.Modules, slot, &call_modules, size_of(call_modules))
		if call_mappings.program_serial == call_modules.program_serial {
			break
		}
	}
	if call_mappings.program_serial != call_modules.program_serial {
		return errors.fail(error, ERROR_CHANGED, .Absent, .Programs, 1) // The program of that name is not there at one instant.
	}
	modules := call_modules.modules[:min(call_modules.count, op.PROGRAM_MODULE_CAPACITY)]
	count := int(min(call_mappings.count, op.MAPPING_REPORT_CAPACITY))
	for &item, number in call_mappings.mappings[:count] {
		if number >= len(result^) {
			break
		}
		row := &result[number]
		row^ = {address = i64(item.address), pages = i64(item.page_count), present = i64(item.present), object = i64(item.region_serial), names = i64(item.references)}
		if index, offset := addresses.module_of(item.address, modules); index >= 0 {
			row.offset = i64(offset)
			if entry := system.image_entry_of(image, modules[index].hash); entry != nil {
				copy(row.module[:len(row.module) - 1], system.name_of(entry.name[:]))
			}
		}
		copy(row.kind[:], addresses.KIND_NAMES[addresses.kind_of(item, modules)])
		row.rights = {'r', .Write in item.flags ? 'w' : '-', .Execute in item.flags ? 'x' : '-', 0}
	}
	return i64(count)
}

@(rodata)
thread_states := [op.Program_State]string {
	.None    = "",
	.Created = "created",
	.Ready   = "ready",
	.Waiting = "waiting",
	.Stopped = "stopped",
}

// threads gives one row for each thread of the program with this name: its thread area, its state, the processor that runs it and its home queue, its weight and its request, its virtual time and its lag, its processor time, the words of its word wait and the end of its wait. The result is the count of rows, or a negative number with an error record. The error kinds: No_Grant (-1, the caller does not act for the principal); Absent (-2, no program has this name).
//
// **Parameter**: `program`, the name of a program that runs, as
// `programs()` lists it (at most 31 bytes). If two programs have that name,
// the one in the lowest slot answers.
//
// **Grant**: the caller must **act for the principal**: the facts are of
// another program, and a program sees no other program.
//
// **A row** (`Thread`): `number`, the thread area; `state` (`ready`,
// `waiting`, `stopped`, or `created` before its first run); `processor`, 1 +
// the processor that runs it, or 0; `home`, the processor of its run queue;
// `weight` and `request` (docs/SCHEDULING.md); `virtual` and `lag`, the
// state of the fair strategies; `time`, milliseconds of processor time;
// `words`, the words of its word wait; `deadline`, the end of its wait in
// milliseconds since the start, or -1. The kernel reads these fields with no
// lock: each field is whole, two fields can come from two instants.
//
// **Errors**: `No_Grant` (-1), the caller does not act for the principal;
// `Absent` (-2), no program has this name.
//
// ```
// connect("inspect")
// inspect.threads("console")
// ```
@(export, link_name = "threads")
threads :: proc "c" (program: ^string, result: ^[]Thread, error: ^errors.Error_Record) -> i64 {
	slot, failure := program_find(program, error)
	if slot == 0 {
		return failure
	}
	inspect_call(.Threads, slot, &call_threads, size_of(call_threads))
	count := int(min(call_threads.count, op.THREAD_REPORT_CAPACITY))
	for &item, number in call_threads.threads[:count] {
		if number >= len(result^) {
			break
		}
		result[number] = {
			number    = i64(item.number),
			processor = i64(item.processor),
			home      = i64(item.home),
			weight    = i64(item.weight),
			request   = i64(item.request),
			virtual   = i64(item.virtual),
			lag       = item.lag,
			time      = i64(item.run_time),
			words     = i64(item.words),
			deadline  = item.deadline == op.WAIT_FOREVER || item.deadline == 0 ? -1 : i64(item.deadline),
		}
		if item.state <= max(op.Program_State) {
			copy(result[number].state[:], thread_states[item.state])
		}
	}
	return i64(count)
}

// modules gives one row for each module record of the program with this name: the name in the boot image, the hash, the base and the size. The result is the count of rows, or a negative number with an error record. The error kinds: No_Grant (-1, the caller does not act for the principal); Absent (-2, no program has this name).
//
// A program holds one module, its own, until a loader puts more in it: the
// console after `load`, a program with imports. Each row is one
// [module record](term:module-record) of the kernel: the identity of the
// code that the program runs.
//
// **Parameter**: `program`, the name of a program that runs, as
// `programs()` lists it (at most 31 bytes). If two programs have that name,
// the one in the lowest slot answers.
//
// **Grant**: the caller must **act for the principal**: the facts are of
// another program, and a program sees no other program.
//
// **A row** (`Module`): `name`, the name in the boot image, or empty when
// no module of the boot image has the hash; `hash`, the BLAKE3 hash in hex;
// `base` and `size`, its place in the address space.
//
// **Errors**: `No_Grant` (-1), the caller does not act for the principal;
// `Absent` (-2), no program has this name.
//
// ```
// connect("inspect")
// inspect.modules("console")
// ```
@(export, link_name = "modules")
modules :: proc "c" (program: ^string, result: ^[]Module, error: ^errors.Error_Record) -> i64 {
	slot, failure := program_find(program, error)
	if slot == 0 {
		return failure
	}
	inspect_call(.Modules, slot, &call_modules, size_of(call_modules))
	count := int(min(call_modules.count, op.PROGRAM_MODULE_CAPACITY))
	for &item, number in call_modules.modules[:count] {
		if number >= len(result^) {
			break
		}
		row := &result[number]
		row^ = {base = i64(item.base), size = i64(item.size)}
		if entry := system.image_entry_of(image, item.hash); entry != nil {
			copy(row.name[:len(row.name) - 1], system.name_of(entry.name[:]))
		}
		writer := system.Writer{buffer = row.hash[:]}
		digits := system.HEX_DIGITS
		for byte in item.hash {
			system.write_bytes(&writer, {digits[byte >> 4], digits[byte & 15]})
		}
	}
	return i64(count)
}
