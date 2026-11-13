package debugging

// The frames of one stack walk. A deeper stack is cut at this count.
FRAME_CAPACITY :: 32

// One frame of a stack.
Frame :: struct {
	instruction:    u64, // The frame 0: the next instruction of the thread. Each other frame: the return address of the call, the instruction after it.
	frame_pointer:  u64, // The frame pointer of the frame. 0: not known.
	return_address: u64, // Where the frame returns to: the instruction of the next frame. 0: not known, the walk ended here.
}

// Where the instruction of the frame 0 is in its procedure. A procedure
// that the compiler wrote starts with `push rbp`, then `mov rbp, rsp`:
// before these two instructions the frame pointer is still the one of the
// caller, and the return address is at the stack pointer.
Entry_Place :: enum {
	In_Body                  = 0, // After the two instructions, or not known: the frame pointer is the one of the frame.
	At_First_Instruction     = 1, // Before `push rbp`: the return address is the word at the stack pointer.
	After_Frame_Pointer_Push = 2, // After `push rbp`, before `mov rbp, rsp`: the return address is the word 8 bytes above the stack pointer.
}

// frames_walk gives the frames of a stack, from the registers of a held
// thread: the frame 0 is the instruction, each next frame a return
// address. Each procedure that the compiler wrote keeps the frame pointer:
// the word at the frame pointer is the frame pointer of the caller, and
// the word 8 bytes after it is the return address. The walk needs no
// table.
//
// It ends at a frame pointer that is 0, that is not a multiple of 8, that
// the program does not map, or that is not above the one before it; at a
// return address 0; and after len(frames) frames. It gives the count of
// frames, 1 at least when `frames` has room.
frames_walk :: proc "contextless" (reader: Memory_Reader, instruction, frame_pointer, stack_pointer: u64, entry: Entry_Place, frames: []Frame) -> (count: int) {
	if len(frames) == 0 {
		return 0
	}
	frames[0] = {instruction = instruction, frame_pointer = frame_pointer}
	count = 1
	current := 0
	if entry != .In_Body {
		// The procedure has no frame of its own yet: its caller is the
		// frame of the frame pointer.
		return_address, read := memory_word(reader, stack_pointer + (entry == .After_Frame_Pointer_Push ? 8 : 0))
		if !read {
			return count
		}
		frames[0].return_address = return_address
		if return_address == 0 || len(frames) == 1 {
			return count
		}
		frames[1] = {instruction = return_address, frame_pointer = frame_pointer}
		count = 2
		current = 1
	}
	for {
		pointer := frames[current].frame_pointer
		if pointer == 0 || pointer % 8 != 0 {
			break
		}
		caller_pointer, pointer_read := memory_word(reader, pointer)
		return_address, address_read := memory_word(reader, pointer + 8)
		if !pointer_read || !address_read {
			break
		}
		frames[current].return_address = return_address
		if return_address == 0 || count == len(frames) {
			break
		}
		// A stack grows down: the frame of a caller is above. A frame
		// pointer that is not above is a broken chain, or a loop.
		if caller_pointer != 0 && caller_pointer <= pointer {
			break
		}
		frames[count] = {instruction = return_address, frame_pointer = caller_pointer}
		current = count
		count += 1
	}
	return count
}

// frame_lookup_address gives the address that names the procedure and the
// line of a frame: the instruction of the frame 0, and for each other
// frame the byte before the return address, which is inside the call.
frame_lookup_address :: proc "contextless" (frame: Frame, number: int) -> u64 {
	if number == 0 || frame.instruction == 0 {
		return frame.instruction
	}
	return frame.instruction - 1
}
