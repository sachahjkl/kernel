#+build !freestanding
package vectors

import "core:testing"
import "modus:support/cryptography/argon2id"
import "modus:support/cryptography/blake2b"

// RFC 7693, appendix A: BLAKE2b-512 of "abc".
@(test)
blake2b_of_rfc_7693 :: proc(t: ^testing.T) {
	ctx: blake2b.Context
	blake2b.init(&ctx)
	blake2b.update(&ctx, transmute([]byte)string("abc"))
	digest: [blake2b.DIGEST_SIZE]byte
	blake2b.final(&ctx, digest[:])
	testing.expect_value(t, hex_of(digest[:]), "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
}

// RFC 9106, section 5.3: Argon2id with 32 KiB, 3 passes, 4 lanes, a secret
// and associated data. The caller supplies the blocks; fewer blocks than
// the parameters ask is Out_Of_Memory, and nothing is derived.
@(test)
argon2id_of_rfc_9106 :: proc(t: ^testing.T) {
	password, salt, secret, associated: [32]byte
	for index in 0 ..< 32 {
		password[index], salt[index], secret[index], associated[index] = 0x01, 0x02, 0x03, 0x04
	}
	parameters := argon2id.Parameters{memory_size = 32, passes = 3, parallelism = 4}
	blocks := make([]u64, 32 * 1024 / 8, context.temp_allocator)
	work := ([^]byte)(raw_data(blocks))[:32 * 1024]
	tag: [32]byte
	result := argon2id.derive(&parameters, password[:], salt[:16], tag[:], secret[:8], associated[:12], work_memory = work)
	testing.expect(t, result == .None)
	testing.expect_value(t, hex_of(tag[:]), "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")
	// The work memory is erased after the derivation.
	for value in blocks {
		testing.expect_value(t, value, 0)
	}
	short: [32]byte
	testing.expect(t, argon2id.derive(&parameters, password[:], salt[:16], short[:], work_memory = work[:31 * 1024]) == .Out_Of_Memory)
	testing.expect_value(t, short, [32]byte{})
}
