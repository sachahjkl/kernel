#+build freestanding
package compatibility_crypto

// The module links src/runtime/memory.asm, which gives this symbol.
foreign _ {
	erase_secret_bytes :: proc "c" (destination: rawptr, count: int) -> rawptr ---
	// Erases the 16 KiB below the stack pointer of the caller: the frames of
	// the procedures that it called (src/runtime/memory.asm).
	erase_stack_below_the_caller :: proc "c" () ---
}
