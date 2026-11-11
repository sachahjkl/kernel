#+build !freestanding
package chacha20

import "core:encoding/hex"
import "core:testing"

hex_bytes :: proc(text: string) -> []byte {
	bytes, ok := hex.decode(transmute([]byte)text, context.temp_allocator)
	assert(ok)
	return bytes
}

// RFC 8439 2.3.2: the block function with the key 00..1f, the nonce
// 000000090000004a00000000 and the counter 1.
@(test)
block_of_rfc_8439_section_2_3_2 :: proc(t: ^testing.T) {
	key := hex_bytes("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
	nonce := hex_bytes("000000090000004a00000000")
	ctx: Context
	init(&ctx, key, nonce)
	seek(&ctx, 1)
	block: [64]byte
	keystream_bytes(&ctx, block[:])
	testing.expect_value(t, string(hex.encode(block[:], context.temp_allocator)), "10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4ed2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e")
}

// RFC 8439 2.4.2: the encryption of the sunscreen text with the counter 1.
@(test)
encryption_of_rfc_8439_section_2_4_2 :: proc(t: ^testing.T) {
	key := hex_bytes("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
	nonce := hex_bytes("000000000000004a00000000")
	plaintext := "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
	ctx: Context
	init(&ctx, key, nonce)
	seek(&ctx, 1)
	sealed := make([]byte, len(plaintext), context.temp_allocator)
	xor_bytes(&ctx, sealed, transmute([]byte)plaintext)
	testing.expect_value(t, string(hex.encode(sealed, context.temp_allocator)), "6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0bf91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d807ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab77937365af90bbf74a35be6b40b8eedf2785e42874d")
}

// RFC 8439 A.1: the block function, vectors 1 (key and nonce 0, counter 0)
// and 5 (key 0..0 with its last byte 02... : here the vector 2, counter 1).
@(test)
blocks_of_rfc_8439_appendix_a_1 :: proc(t: ^testing.T) {
	zero_key: [32]byte
	zero_nonce: [12]byte
	ctx: Context
	init(&ctx, zero_key[:], zero_nonce[:])
	block: [64]byte
	keystream_bytes(&ctx, block[:])
	testing.expect_value(t, string(hex.encode(block[:], context.temp_allocator)), "76b8e0ada0f13d90405d6ae55386bd28bdd219b8a08ded1aa836efcc8b770dc7da41597c5157488d7724e03fb8d84a376a43b8f41518a11cc387b669b2ee6586")
	keystream_bytes(&ctx, block[:])
	testing.expect_value(t, string(hex.encode(block[:], context.temp_allocator)), "9f07e7be5551387a98ba977c732d080dcb0f29a048e3656912c6533e32ee7aed29b721769ce64e43d57133b074d839d531ed1f28510afb45ace10a1f4b794d6f")
}
