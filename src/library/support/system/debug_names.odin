package system

import info "contract:boot_info"
import debug_object "contract:debug_object"
import "contract:fixed_addresses"
import op "contract:operation"

// The names of a stop report (docs/MODULE_CONTRACT.md, "Debug information").
// The kernel gives each frame as an address in a module record; a program
// with the grant of the debug image names it with the debug object of that
// module: "fault::three + 0x8 in fault (src/programs/fault/main.odin:15)". The
// kernel reads no debug object.

// The entries of a debug image that a lookup reads: the image of the build
// has one for each module (83 today). A hostile image of 256 MiB has
// millions of entries; the bound keeps a lookup short.
DEBUG_IMAGE_ENTRY_LIMIT :: 4096
// The debug objects whose check a reader keeps: a stack trace names a few
// modules, each many times.
DEBUG_OBJECT_VERDICT_CAPACITY :: 16

// The verdict of one search: the module, and its debug object after the
// whole check, or nil (no object, or an object that is not whole).
Debug_Object_Verdict :: struct {
	module_hash: [32]u8, // The module that was searched.
	object:      []u8, // Its debug object, inside the image, or nil.
}

// The debug image of a program and the verdicts of its searches. Each
// object is searched and checked once, then each lookup is two binary
// searches. One thread uses one of them: it is not shared.
Debug_Names :: struct {
	image:         []u8, // The debug image that the starter mapped. nil: none.
	verdicts:      [DEBUG_OBJECT_VERDICT_CAPACITY]Debug_Object_Verdict, // The modules searched so far.
	verdict_count: int, // The verdicts in use.
	next_verdict:  int, // The place of the next verdict when all are taken.
}

// debug_names_of gives the debug image that the starter of the program
// mapped, with no verdict yet. Its image is nil with no debug image.
debug_names_of :: proc "contextless" (ctx: ^Context) -> (names: Debug_Names) {
	if .Debug_Image not_in fixed_addresses.ranges_mapped(&ctx.values) {
		return
	}
	size := ctx.values[op.CONTEXT_VALUE_DEBUG_IMAGE_SIZE]
	if size == 0 || size > fixed_addresses.RANGE_SPAN {
		return
	}
	bytes := ([^]u8)(uintptr(fixed_addresses.DEBUG_IMAGE_ADDRESS))
	names.image = bytes[:size]
	return
}

// debug_object_of gives the debug object of the module with a hash, after
// its whole check, or nil: the image has no such object, or the object is
// not whole. The first search of a module walks the entries and checks the
// object; its verdict stays, so the next ones cost a comparison of hashes.
debug_object_of :: proc "contextless" (names: ^Debug_Names, module_hash: [32]u8) -> []u8 {
	if names == nil || names.image == nil {
		return nil
	}
	for &verdict in names.verdicts[:names.verdict_count] {
		if verdict.module_hash == module_hash {
			return verdict.object
		}
	}
	found := debug_object_search(names.image, module_hash)
	place := names.verdict_count
	if place < DEBUG_OBJECT_VERDICT_CAPACITY {
		names.verdict_count += 1
	} else {
		place = names.next_verdict
		names.next_verdict = (names.next_verdict + 1) % DEBUG_OBJECT_VERDICT_CAPACITY
	}
	names.verdicts[place] = {module_hash = module_hash, object = found}
	return found
}

// debug_object_search walks the entries of the image, at most
// DEBUG_IMAGE_ENTRY_LIMIT, for the object of a module, and checks it whole.
// An entry whose object does not start on a page is skipped: the tables of
// an object are read as records of 4-byte fields, which the tool puts at
// offsets that are multiples of 4 from the start of a page.
debug_object_search :: proc "contextless" (debug_image: []u8, module_hash: [32]u8) -> []u8 {
	entries, _, valid := info.image_tables(debug_image)
	if !valid {
		return nil
	}
	for &entry in entries[:min(len(entries), DEBUG_IMAGE_ENTRY_LIMIT)] {
		if entry.offset % info.PAGE_SIZE != 0 {
			continue
		}
		object, inside := info.image_entry_bytes(debug_image, &entry)
		if !inside {
			continue
		}
		if hash, described := debug_object.module_hash_of(object); described && hash == module_hash {
			if debug_object.check(object) != .None {
				return nil
			}
			return object
		}
	}
	return nil
}

// place_write writes the name of an offset of a module, from its debug
// object: "fault::three + 0x8", then " in " and the module name, then the
// file and the line in parentheses. It writes nothing and gives false when
// no procedure holds the offset. `return_address`: the offset is a return
// address, the instruction after a call; the procedure and the line are
// those of the call, the byte before it.
place_write :: proc "contextless" (writer: ^Writer, object: []u8, offset: u64, module_name: string, return_address: bool) -> bool {
	if object == nil {
		return false
	}
	looked := return_address && offset > 0 ? offset - 1 : offset
	place := debug_object.place_of(object, looked)
	if place.procedure == "" {
		return false
	}
	write_part(writer, place.procedure)
	write_part(writer, " + ")
	write_number(writer, place.offset_in_procedure + (offset - looked))
	write_part(writer, " in ")
	write_part(writer, module_name)
	if place.file != "" {
		write_part(writer, " (")
		write_part(writer, place.file)
		write_part(writer, ":")
		write_part(writer, u64(place.line))
		write_part(writer, ")")
	}
	return true
}
