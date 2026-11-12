// The part of `core:mem` of Odin that the Argon2id code taken from
// `core:crypto` uses, in the forms of this system: a compatibility layer
// (docs/CRYPTOGRAPHY.md). The names are the names of the origin; the
// package has its own name.
//
// Not here: the allocators. The caller of Argon2id supplies its blocks (a
// listed adjustment of argon2id.odin), so the code allocates nothing.
package compatibility_memory

import crypto "support:cryptography/compatibility_crypto"

// The result of Argon2id. Out_Of_Memory: the blocks that the caller
// supplied are fewer than the parameters ask, or not aligned on 8 bytes.
Allocator_Error :: enum u8 {
	None          = 0,
	Out_Of_Memory = 1,
}

// zero writes 0 in len bytes at data. The origin uses it for a block that
// it fills again at once: no secret stays because of it.
zero :: proc "contextless" (data: rawptr, len: int) -> rawptr {
	bytes := ([^]u8)(data)[:len]
	for &item in bytes {
		item = 0
	}
	return data
}

// zero_explicit writes 0 in len bytes at data, with a call that the compiler
// cannot remove (compatibility_crypto).
zero_explicit :: proc "contextless" (data: rawptr, len: int) -> rawptr {
	return crypto.zero_explicit(data, len)
}
