// The base package `core:crypto` of Odin, as the cryptography taken from it
// uses it, in the forms of this system: a compatibility layer
// (docs/CRYPTOGRAPHY.md). The names of its procedures are the names of the
// origin; the package has its own name.
//
// Not here: rand_bytes and random_generator of the origin, which ask the
// operating system for entropy. A program of this system has its own
// generator (support/random), seeded by the root service.
package compatibility_crypto

import subtle "support:cryptography/_subtle"

// zero_explicit writes 0 in len bytes at data, with erase_secret_bytes of
// runtime/memory.asm: a call that the compiler cannot remove.
zero_explicit :: proc "contextless" (data: rawptr, len: int) -> rawptr {
	return erase_secret_bytes(data, len)
}

// set writes value in len bytes at data.
set :: proc "contextless" (data: rawptr, value: byte, len: int) -> rawptr {
	bytes := ([^]byte)(data)[:len]
	for &item in bytes {
		item = value
	}
	return data
}

// compare_constant_time gives 1 when a and b are equal, else 0. Its time
// depends only on the lengths (the code of the origin).
compare_constant_time :: proc "contextless" (a, b: []byte) -> int {
	n := len(a)
	if n != len(b) {
		return 0
	}
	return compare_byte_ptrs_constant_time(raw_data(a), raw_data(b), n)
}

@(optimization_mode = "none")
compare_byte_ptrs_constant_time :: proc "contextless" (a, b: ^byte, n: int) -> int {
	x := ([^]byte)(a)[:n]
	y := ([^]byte)(b)[:n]
	v: byte
	for i in 0 ..< n {
		v |= x[i] ~ y[i]
	}
	return subtle.eq(0, v)
}

// is_zero_constant_time gives 1 when each byte of b is 0, else 0.
is_zero_constant_time :: proc "contextless" (b: []byte) -> int {
	v: byte
	for b_ in b {
		v |= b_
	}
	return subtle.byte_eq(0, v)
}
