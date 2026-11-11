// Not taken from Odin: this file of the system takes the place of
// core/crypto/chacha20/chacha20_impl.odin, which chooses among three
// implementations by the processor (simd256 reads the processor features
// through core:sys/info, which a module of this system does not have). Here
// the one implementation is the portable one of the origin,
// support/cryptography/_chacha20/ref, taken unchanged. The names are the
// names of the origin (docs/CRYPTOGRAPHY.md).
package chacha20

import "support:cryptography/_chacha20/ref"

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
	ref.stream_blocks(&ctx._state, dst, src, nr_blocks)
}

@(private)
hchacha20 :: proc "contextless" (dst, key, iv: []byte, impl: Implementation) {
	ref.hchacha20(dst, key, iv)
}
