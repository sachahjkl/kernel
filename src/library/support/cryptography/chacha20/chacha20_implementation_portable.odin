// Not taken from Odin: this file of the system takes the place of
// core/crypto/chacha20/chacha20_impl.odin, which chooses among three
// implementations by the processor (simd256 reads the processor features
// through core:sys/info, which a module of this system does not have). Here
// the one implementation is the portable one of the origin,
// src/library/support/cryptography/_chacha20/ref, taken unchanged. The names are the
// names of the origin (docs/CRYPTOGRAPHY.md).
package chacha20

import "modus:support/cryptography/_chacha20/ref"

DEFAULT_IMPLEMENTATION :: Implementation.Portable

Implementation :: enum {
	Portable,
}

@(private)
init_impl :: proc(ctx: ^Context, impl: Implementation) {
	ctx._impl = .Portable
}

@(private)
stream_blocks :: proc(ctx: ^Context, dst, src: []byte, nr_blocks: int) {
	// The implementation increments the counter as a value of 64 bits. In
	// the IETF form the counter has 32 bits, and the increment after the
	// last block carries into the first word of the IV: put that word back,
	// so that a seek after the last block gives the keystream of this IV.
	first_word_of_the_iv := ctx._state._s[13]
	ref.stream_blocks(&ctx._state, dst, src, nr_blocks)
	if ctx._state._is_ietf_flavor {
		ctx._state._s[13] = first_word_of_the_iv
	}
}

@(private)
hchacha20 :: proc "contextless" (dst, key, iv: []byte, impl: Implementation) {
	ref.hchacha20(dst, key, iv)
}
