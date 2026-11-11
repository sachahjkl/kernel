package system

import op "contract:operation"

// frame_text writes one frame of a stack trace: "probe + 0x1a2", with the
// name of the module in the boot image, or the start of its hash. A frame
// that no module record holds is its address.
frame_text :: proc "contextless" (writer: ^Writer, image: []u8, frame: ^op.Stop_Frame) {
	if frame.base == 0 {
		write_number(writer, frame.address)
		return
	}
	if entry := image_entry_of(image, frame.hash); entry != nil {
		write_part(writer, name_of(entry.name[:]))
	} else {
		write_hash(writer, frame.hash)
	}
	write_part(writer, " + ")
	write_number(writer, frame.address - frame.base)
}
