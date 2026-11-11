// The part of `core:math/bits` that the cryptography of `core:crypto` uses,
// over the intrinsics of the compiler: a compatibility layer, so that the
// code taken from Odin compiles unchanged in a module of this system
// (docs/CRYPTOGRAPHY.md). The names are the names of the origin.
package compatibility_bits

import "base:intrinsics"

rotate_left32 :: #force_inline proc "contextless" (x: u32, k: int) -> u32 {
	n :: 32
	s := uint(k) & (n - 1)
	return x << s | x >> (n - s)
}

rotate_left64 :: #force_inline proc "contextless" (x: u64, k: int) -> u64 {
	n :: 64
	s := uint(k) & (n - 1)
	return x << s | x >> (n - s)
}

// add_u64 gives x + y + carry and the carry out (0 or 1).
add_u64 :: #force_inline proc "contextless" (x, y, carry: u64) -> (sum, carry_out: u64) {
	sum = x + y + carry
	carry_out = ((x & y) | ((x | y) &~ sum)) >> 63
	return
}

// sub_u64 gives x - y - borrow and the borrow out (0 or 1).
sub_u64 :: #force_inline proc "contextless" (x, y, borrow: u64) -> (difference, borrow_out: u64) {
	difference = x - y - borrow
	borrow_out = ((~x & y) | (~(x ~ y) & difference)) >> 63
	return
}

// mul_u64 gives the 128-bit product of x and y, as its high and low halves.
mul_u64 :: #force_inline proc "contextless" (x, y: u64) -> (high, low: u64) {
	product := u128(x) * u128(y)
	return u64(product >> 64), u64(product)
}

from_le_u32 :: #force_inline proc "contextless" (value: u32) -> u32 {return value}
from_le_u64 :: #force_inline proc "contextless" (value: u64) -> u64 {return value}
to_le_u32 :: #force_inline proc "contextless" (value: u32) -> u32 {return value}
to_le_u64 :: #force_inline proc "contextless" (value: u64) -> u64 {return value}
from_be_u32 :: #force_inline proc "contextless" (value: u32) -> u32 {return intrinsics.byte_swap(value)}
from_be_u64 :: #force_inline proc "contextless" (value: u64) -> u64 {return intrinsics.byte_swap(value)}
to_be_u32 :: #force_inline proc "contextless" (value: u32) -> u32 {return intrinsics.byte_swap(value)}
to_be_u64 :: #force_inline proc "contextless" (value: u64) -> u64 {return intrinsics.byte_swap(value)}
