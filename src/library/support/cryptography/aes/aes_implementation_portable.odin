// Not taken from Odin: on amd64 the origin compiles the hardware AES of
// core/crypto/aes/aes_*_hw.odin and core/crypto/_aes/hw (AES-NI through
// core:simd/x86 and core:sys/info). This file of the system takes their
// place with the procedures of core/crypto/aes/aes_impl_hw_gen.odin,
// unchanged: AES runs in the constant-time bitsliced code of _aes/ct64
// (docs/CRYPTOGRAPHY.md).
package aes

@(private = "file")
ERR_HW_NOT_SUPPORTED :: "crypto/aes: hardware implementation unsupported"

is_hardware_accelerated :: proc "contextless" () -> bool {
	return false
}

@(private)
Context_Impl_Hardware :: struct {}

@(private)
init_impl_hw :: proc(ctx: ^Context_Impl_Hardware, key: []byte) {
	panic(ERR_HW_NOT_SUPPORTED)
}

@(private)
encrypt_block_hw :: proc(ctx: ^Context_Impl_Hardware, dst, src: []byte) {
	panic(ERR_HW_NOT_SUPPORTED)
}

@(private)
decrypt_block_hw :: proc(ctx: ^Context_Impl_Hardware, dst, src: []byte) {
	panic(ERR_HW_NOT_SUPPORTED)
}

@(private)
ctr_blocks_hw :: proc(ctx: ^Context_CTR, dst, src: []byte, nr_blocks: int) {
	panic(ERR_HW_NOT_SUPPORTED)
}

@(private)
gcm_seal_hw :: proc(ctx: ^Context_Impl_Hardware, dst, tag, iv, aad, plaintext: []byte) {
	panic(ERR_HW_NOT_SUPPORTED)
}

@(private)
gcm_open_hw :: proc(ctx: ^Context_Impl_Hardware, dst, iv, aad, ciphertext, tag: []byte) -> bool {
	panic(ERR_HW_NOT_SUPPORTED)
}
