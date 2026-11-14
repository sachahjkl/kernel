// Not taken from Odin: the place of core/crypto/_aes/hw, whose AES-NI and
// carry-less multiply need core:simd/x86 and core:sys/info. This package of
// the system says that no hardware GHASH is used, so aes_gcm.odin of the
// origin takes its portable path (docs/CRYPTOGRAPHY.md).
package aes_hw

HAS_GHASH :: false

is_ghash_supported :: proc "contextless" () -> bool {
	return false
}
