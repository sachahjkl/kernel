package system

import info "contract:boot_info"
import debug_object "contract:debug_object"
import "contract:fixed_addresses"
import op "contract:operation"

// The names of a stop report (docs/MODULE_CONTRACT.md, "Debug information").
// The kernel gives each frame as an address in a module record; a program
// with the grant of the debug image names it with the debug object of that
// module: "fault::three + 0x8 in fault (programs/fault/main.odin:15)". The
// kernel reads no debug object.

// debug_image_of gives the debug image that the starter of the program
// mapped, or nil.
debug_image_of :: proc "contextless" (ctx: ^Context) -> []u8 {
	if .Debug_Image not_in fixed_addresses.ranges_mapped(&ctx.values) {
		return nil
	}
	size := ctx.values[op.CONTEXT_VALUE_DEBUG_IMAGE_SIZE]
	if size == 0 || size > fixed_addresses.RANGE_SPAN {
		return nil
	}
	bytes := ([^]u8)(uintptr(fixed_addresses.DEBUG_IMAGE_ADDRESS))
	return bytes[:size]
}

// debug_object_of gives the debug object of the module with a hash, after
// its whole check, or nil: the image has no such object, or the object is
// not whole. The cost is one pass over the object.
debug_object_of :: proc "contextless" (debug_image: []u8, module_hash: [32]u8) -> []u8 {
	entries, _, valid := info.image_tables(debug_image)
	if !valid {
		return nil
	}
	for &entry in entries {
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
