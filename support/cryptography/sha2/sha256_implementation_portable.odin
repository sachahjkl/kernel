// Not taken from Odin: on amd64 the origin compiles
// core/crypto/sha2/sha256_impl_hw_intel.odin, which reads the processor
// features with core:sys/info, which a module of this system does not
// have. This file of the system takes its place, as
// core/crypto/sha2/sha256_impl_hw_gen.odin does on the other processors
// (its procedures, unchanged): SHA-256 runs in the portable code of
// sha2.odin (docs/CRYPTOGRAPHY.md).
package sha2

is_hardware_accelerated_256 :: proc "contextless" () -> bool {
	return false
}

@(private)
sha256_transf_hw :: proc "contextless" (ctx: ^Context_256, data: []byte) {
	panic_contextless(ERR_HW_NOT_SUPPORTED)
}
