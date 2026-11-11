#+build freestanding
package compatibility_crypto

// The module links runtime/memory.asm, which gives this symbol.
foreign _ {
	erase_secret_bytes :: proc "c" (destination: rawptr, count: int) -> rawptr ---
}
