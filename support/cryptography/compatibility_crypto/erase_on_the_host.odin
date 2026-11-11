#+build !freestanding
package compatibility_crypto

// The tests on the host link the host form of runtime/memory.asm. The path
// is from this folder; the assembler includes runtime/memory.asm from the
// root of the repository, where the kernel tool runs the tests.
foreign import memory "../../../runtime/memory_for_host_tests.asm"

@(default_calling_convention = "c")
foreign memory {
	erase_secret_bytes :: proc(destination: rawptr, count: int) -> rawptr ---
}
