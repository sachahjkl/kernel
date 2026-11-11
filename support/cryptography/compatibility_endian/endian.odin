// The part of `core:encoding/endian` that the cryptography of `core:crypto`
// uses: loads and stores of 32 and 64 bits at any alignment, with no check
// of the length (the callers check it). A compatibility layer
// (docs/CRYPTOGRAPHY.md); the names are the names of the origin. The machine
// is little endian (x86-64).
package compatibility_endian

import "base:intrinsics"

unchecked_get_u32le :: #force_inline proc "contextless" (b: []byte) -> u32 {
	return intrinsics.unaligned_load((^u32)(raw_data(b)))
}
unchecked_get_u64le :: #force_inline proc "contextless" (b: []byte) -> u64 {
	return intrinsics.unaligned_load((^u64)(raw_data(b)))
}
unchecked_get_u32be :: #force_inline proc "contextless" (b: []byte) -> u32 {
	return intrinsics.byte_swap(intrinsics.unaligned_load((^u32)(raw_data(b))))
}
unchecked_get_u64be :: #force_inline proc "contextless" (b: []byte) -> u64 {
	return intrinsics.byte_swap(intrinsics.unaligned_load((^u64)(raw_data(b))))
}
unchecked_put_u32le :: #force_inline proc "contextless" (b: []byte, v: u32) {
	intrinsics.unaligned_store((^u32)(raw_data(b)), v)
}
unchecked_put_u64le :: #force_inline proc "contextless" (b: []byte, v: u64) {
	intrinsics.unaligned_store((^u64)(raw_data(b)), v)
}
unchecked_put_u32be :: #force_inline proc "contextless" (b: []byte, v: u32) {
	intrinsics.unaligned_store((^u32)(raw_data(b)), intrinsics.byte_swap(v))
}
unchecked_put_u64be :: #force_inline proc "contextless" (b: []byte, v: u64) {
	intrinsics.unaligned_store((^u64)(raw_data(b)), intrinsics.byte_swap(v))
}
