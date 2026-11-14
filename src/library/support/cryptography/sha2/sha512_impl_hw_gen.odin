// Altered source: Odin dev-2026-11a, core/crypto/sha2/sha512_impl_hw_gen.odin; only its imports changed (src/library/support/cryptography/origin.manifest, docs/CRYPTOGRAPHY.md).
#+build !arm64
package sha2

// is_hardware_accelerated_512 returns true if and only if (⟺) hardware
// accelerated SHA-384, SHA-512, and SHA-512/256 are supported.
is_hardware_accelerated_512 :: proc "contextless" () -> bool {
	return false
}

@(private)
sha512_transf_hw :: proc "contextless" (ctx: ^Context_512, data: []byte) {
	panic_contextless(ERR_HW_NOT_SUPPORTED)
}
