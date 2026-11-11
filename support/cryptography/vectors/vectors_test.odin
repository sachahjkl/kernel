#+build !freestanding
// The published test vectors of each primitive that the system took from
// Odin's core:crypto (docs/CRYPTOGRAPHY.md), on the host. The same code runs
// in the module `cryptography` on the machine (kerneltool test crypto).
package vectors

import "core:encoding/hex"
import "core:testing"
import "support:cryptography/aes"
import "support:cryptography/chacha20poly1305"
import "support:cryptography/ed25519"
import hash "support:cryptography/compatibility_hash"
import "support:cryptography/hkdf"
import "support:cryptography/hmac"
import "support:cryptography/poly1305"
import "support:cryptography/sha2"
import "support:cryptography/x25519"

bytes_of :: proc(text: string) -> []byte {
	bytes, ok := hex.decode(transmute([]byte)text, context.temp_allocator)
	assert(ok, text)
	return bytes
}

hex_of :: proc(bytes: []byte) -> string {
	return string(hex.encode(bytes, context.temp_allocator))
}

SUNSCREEN :: "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."

// RFC 8439 2.5.2.
@(test)
poly1305_of_rfc_8439 :: proc(t: ^testing.T) {
	tag: [16]byte
	poly1305.sum(tag[:], transmute([]byte)string("Cryptographic Forum Research Group"), bytes_of("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b"))
	testing.expect_value(t, hex_of(tag[:]), "a8061dc1305136c6c22b8baf0c0127a9")
}

// RFC 8439 2.8.2, and a changed byte that the open refuses.
@(test)
chacha20_poly1305_of_rfc_8439 :: proc(t: ^testing.T) {
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, bytes_of("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"))
	iv := bytes_of("070000004041424344454647")
	aad := bytes_of("50515253c0c1c2c3c4c5c6c7")
	sealed := make([]byte, len(SUNSCREEN), context.temp_allocator)
	tag: [16]byte
	chacha20poly1305.seal(&ctx, sealed, tag[:], iv, aad, transmute([]byte)string(SUNSCREEN))
	testing.expect_value(t, hex_of(sealed), "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b6116")
	testing.expect_value(t, hex_of(tag[:]), "1ae10b594f09e26a7e902ecbd0600691")
	opened := make([]byte, len(sealed), context.temp_allocator)
	testing.expect(t, chacha20poly1305.open(&ctx, opened, iv, aad, sealed, tag[:]))
	testing.expect_value(t, string(opened), SUNSCREEN)
	sealed[3] ~= 1
	testing.expect(t, !chacha20poly1305.open(&ctx, opened, iv, aad, sealed, tag[:]))
}

// FIPS 180-4 examples "abc".
@(test)
sha2_of_abc :: proc(t: ^testing.T) {
	abc := transmute([]byte)string("abc")
	digest_256: [32]byte
	digest_384: [48]byte
	digest_512: [64]byte
	context_256: sha2.Context_256
	sha2.init_256(&context_256)
	sha2.update(&context_256, abc)
	sha2.final(&context_256, digest_256[:])
	testing.expect_value(t, hex_of(digest_256[:]), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	context_512: sha2.Context_512
	sha2.init_384(&context_512)
	sha2.update(&context_512, abc)
	sha2.final(&context_512, digest_384[:])
	testing.expect_value(t, hex_of(digest_384[:]), "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7")
	sha2.init_512(&context_512)
	sha2.update(&context_512, abc)
	sha2.final(&context_512, digest_512[:])
	testing.expect_value(t, hex_of(digest_512[:]), "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
}

// RFC 4231 test case 2.
@(test)
hmac_of_rfc_4231 :: proc(t: ^testing.T) {
	tag: [32]byte
	hmac.sum(.SHA256, tag[:], transmute([]byte)string("what do ya want for nothing?"), transmute([]byte)string("Jefe"))
	testing.expect_value(t, hex_of(tag[:]), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
}

// RFC 5869 A.1 and A.3.
@(test)
hkdf_of_rfc_5869 :: proc(t: ^testing.T) {
	ikm := bytes_of("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
	pseudorandom_key: [32]byte
	hkdf.extract(.SHA256, bytes_of("000102030405060708090a0b0c"), ikm, pseudorandom_key[:])
	testing.expect_value(t, hex_of(pseudorandom_key[:]), "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")
	output: [42]byte
	hkdf.expand(.SHA256, pseudorandom_key[:], bytes_of("f0f1f2f3f4f5f6f7f8f9"), output[:])
	testing.expect_value(t, hex_of(output[:]), "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
	hkdf.extract_and_expand(.SHA256, nil, ikm, nil, output[:])
	testing.expect_value(t, hex_of(output[:]), "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8")
	_ = hash.Algorithm.SHA384
}

// RFC 7748 5.2 (the first vector) and 6.1.
@(test)
x25519_of_rfc_7748 :: proc(t: ^testing.T) {
	out: [32]byte
	x25519.scalarmult(out[:], bytes_of("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"), bytes_of("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"))
	testing.expect_value(t, hex_of(out[:]), "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")
	alice := bytes_of("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
	bob := bytes_of("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
	alice_public, bob_public, shared: [32]byte
	x25519.scalarmult_basepoint(alice_public[:], alice)
	x25519.scalarmult_basepoint(bob_public[:], bob)
	testing.expect_value(t, hex_of(alice_public[:]), "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
	testing.expect_value(t, hex_of(bob_public[:]), "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
	x25519.scalarmult(shared[:], alice, bob_public[:])
	testing.expect_value(t, hex_of(shared[:]), "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
}

// RFC 8032 7.1, tests 1 and 2, and a changed signature that verify refuses.
@(test)
ed25519_of_rfc_8032 :: proc(t: ^testing.T) {
	Case :: struct {
		secret, public, message, signature: string,
	}
	cases := []Case {
		{"9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "", "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"},
		{"4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb", "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72", "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"},
	}
	for item in cases {
		private_key: ed25519.Private_Key
		testing.expect(t, ed25519.private_key_set_bytes(&private_key, bytes_of(item.secret)))
		public_key: ed25519.Public_Key
		ed25519.public_key_set_priv(&public_key, &private_key)
		public_bytes: [32]byte
		ed25519.public_key_bytes(&public_key, public_bytes[:])
		testing.expect_value(t, hex_of(public_bytes[:]), item.public)
		signature: [64]byte
		ed25519.sign(&private_key, bytes_of(item.message), signature[:])
		testing.expect_value(t, hex_of(signature[:]), item.signature)
		testing.expect(t, ed25519.verify(&public_key, bytes_of(item.message), signature[:]))
		signature[10] ~= 1
		testing.expect(t, !ed25519.verify(&public_key, bytes_of(item.message), signature[:]))
	}
}

// The GCM specification of McGrew and Viega, test case 4 (AES-128).
@(test)
aes_128_gcm_test_case_4 :: proc(t: ^testing.T) {
	ctx: aes.Context_GCM
	aes.init_gcm(&ctx, bytes_of("feffe9928665731c6d6a8f9467308308"))
	plaintext := bytes_of("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39")
	iv := bytes_of("cafebabefacedbaddecaf888")
	aad := bytes_of("feedfacedeadbeeffeedfacedeadbeefabaddad2")
	sealed := make([]byte, len(plaintext), context.temp_allocator)
	tag: [16]byte
	aes.seal_gcm(&ctx, sealed, tag[:], iv, aad, plaintext)
	testing.expect_value(t, hex_of(sealed), "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091")
	testing.expect_value(t, hex_of(tag[:]), "5bc94fbc3221a5db94fae95ae7121a47")
	opened := make([]byte, len(plaintext), context.temp_allocator)
	testing.expect(t, aes.open_gcm(&ctx, opened, iv, aad, sealed, tag[:]))
	tag[0] ~= 1
	testing.expect(t, !aes.open_gcm(&ctx, opened, iv, aad, sealed, tag[:]))
}
