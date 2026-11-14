package system

import op "modus:contract/operation"

// frame_text writes one frame of a stack trace. With the debug object of
// its module: "fault::three + 0x8 in fault (src/programs/fault/main.odin:15)".
// Without: "fault + 0x1478", with the name of the module in the boot image,
// or the start of its hash. A frame that no module record holds is its
// address. `number`: frame 0 is the instruction, each next frame a return
// address. names can be nil.
frame_text :: proc "contextless" (writer: ^Writer, image: []u8, names: ^Debug_Names, frame: ^op.Stop_Frame, number: int) {
	if frame.base == 0 {
		write_number(writer, frame.address)
		return
	}
	module_name := ""
	if entry := image_entry_of(image, frame.hash); entry != nil {
		module_name = name_of(entry.name[:])
	}
	if module_name != "" && names != nil {
		if place_write(writer, debug_object_of(names, frame.hash), frame.address - frame.base, module_name, number > 0) {
			return
		}
	}
	if module_name != "" {
		write_part(writer, module_name)
	} else {
		write_hash(writer, frame.hash)
	}
	write_part(writer, " + ")
	write_number(writer, frame.address - frame.base)
}
