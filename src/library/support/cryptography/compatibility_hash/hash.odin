// The part of `core:crypto/hash` that HMAC and HKDF of the origin use, with
// the SHA-2 algorithms only: a compatibility layer (docs/CRYPTOGRAPHY.md).
// The origin package imports every hash of Odin, `core:io` and `core:os`;
// this one dispatches to src/library/support/cryptography/sha2 and nothing else. The
// names are the names of the origin.
package compatibility_hash

import "support:cryptography/sha2"

MAX_DIGEST_SIZE :: 64 // The largest digest: SHA-512.
MAX_BLOCK_SIZE :: sha2.BLOCK_SIZE_512 // The largest block: 128 bytes.

// A hash of this layer.
Algorithm :: enum {
	Invalid, // No hash: init refuses it.
	SHA256, // SHA-256.
	SHA384, // SHA-384.
	SHA512, // SHA-512.
}

// The bytes of the digest of each hash.
DIGEST_SIZES := [Algorithm]int {
	.Invalid = 0,
	.SHA256  = sha2.DIGEST_SIZE_256,
	.SHA384  = sha2.DIGEST_SIZE_384,
	.SHA512  = sha2.DIGEST_SIZE_512,
}

// The bytes of the block of each hash.
BLOCK_SIZES := [Algorithm]int {
	.Invalid = 0,
	.SHA256  = sha2.BLOCK_SIZE_256,
	.SHA384  = sha2.BLOCK_SIZE_512,
	.SHA512  = sha2.BLOCK_SIZE_512,
}

// The state of one hash in progress.
Context :: struct {
	_algo: Algorithm, // The hash.
	_impl: union { // The state of SHA-256, or of SHA-384 and SHA-512.
		sha2.Context_256,
		sha2.Context_512,
	},
}

// init starts a hash of an algorithm.
init :: proc(ctx: ^Context, algorithm: Algorithm) {
	ctx._algo = algorithm
	switch algorithm {
	case .SHA256:
		ctx._impl = sha2.Context_256{}
		sha2.init_256(&ctx._impl.(sha2.Context_256))
	case .SHA384:
		ctx._impl = sha2.Context_512{}
		sha2.init_384(&ctx._impl.(sha2.Context_512))
	case .SHA512:
		ctx._impl = sha2.Context_512{}
		sha2.init_512(&ctx._impl.(sha2.Context_512))
	case .Invalid:
		panic("crypto/hash: invalid algorithm")
	}
}

// update adds bytes to the hash.
update :: proc(ctx: ^Context, data: []byte) {
	switch &impl in ctx._impl {
	case sha2.Context_256:
		sha2.update(&impl, data)
	case sha2.Context_512:
		sha2.update(&impl, data)
	case:
		panic("crypto/hash: uninitialized algorithm")
	}
}

// final writes the digest in `hash` and ends the hash; with
// finalize_clone, the context stays usable for more bytes.
final :: proc(ctx: ^Context, hash: []byte, finalize_clone: bool = false) {
	switch &impl in ctx._impl {
	case sha2.Context_256:
		sha2.final(&impl, hash, finalize_clone)
	case sha2.Context_512:
		sha2.final(&impl, hash, finalize_clone)
	case:
		panic("crypto/hash: uninitialized algorithm")
	}
	if !finalize_clone {
		reset(ctx)
	}
}

// clone makes ctx a copy of the hash in progress of other.
clone :: proc(ctx, other: ^Context) {
	if ctx == other {
		return
	}
	reset(ctx)
	ctx._algo = other._algo
	switch &src_impl in other._impl {
	case sha2.Context_256:
		ctx._impl = sha2.Context_256{}
		sha2.clone(&ctx._impl.(sha2.Context_256), &src_impl)
	case sha2.Context_512:
		ctx._impl = sha2.Context_512{}
		sha2.clone(&ctx._impl.(sha2.Context_512), &src_impl)
	case:
		panic("crypto/hash: uninitialized algorithm")
	}
}

// reset erases the state of a hash.
reset :: proc(ctx: ^Context) {
	switch &impl in ctx._impl {
	case sha2.Context_256:
		sha2.reset(&impl)
	case sha2.Context_512:
		sha2.reset(&impl)
	case:
	}
	ctx._algo = .Invalid
	ctx._impl = nil
}

// algorithm gives the hash of a context.
algorithm :: proc(ctx: ^Context) -> Algorithm {
	return ctx._algo
}

// digest_size gives the bytes of the digest of a context.
digest_size :: proc(ctx: ^Context) -> int {
	return DIGEST_SIZES[ctx._algo]
}

// block_size gives the bytes of the block of a context.
block_size :: proc(ctx: ^Context) -> int {
	return BLOCK_SIZES[ctx._algo]
}
