#+build !freestanding
// The exports of the module on the host: what a caller sees, with hostile
// arguments and with bytes that another thread changes during the call.
package cryptography

import "base:intrinsics"
import "modus:contract/errors"
import "core:encoding/hex"
import "core:testing"
import "core:thread"

bytes_of :: proc(text: string) -> []u8 {
	bytes, ok := hex.decode(transmute([]u8)text, context.temp_allocator)
	assert(ok, text)
	return bytes
}

SUNSCREEN :: "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."

// The memory that a second thread changes during the calls: a sealed text
// or a message, and one byte of it that flips between two values.
Changing_Bytes :: struct {
	bytes:    [256]u8,
	count:    int,
	place:    int, // The byte that flips.
	first:    u8,
	second:   u8,
	stop:     bool,
}

flip_until_stopped :: proc(data: rawptr) {
	shared := (^Changing_Bytes)(data)
	for !intrinsics.atomic_load(&shared.stop) {
		intrinsics.volatile_store(&shared.bytes[shared.place], shared.second)
		intrinsics.volatile_store(&shared.bytes[shared.place], shared.first)
	}
}

// An open reads each byte of the sealed text once (the tag check and the
// decryption use one copy). Another thread flips one byte of the sealed text
// during 200 000 opens of each AEAD: each open gives the true text, or
// Not_Authentic; never a count with other bytes. Before, the tag was checked
// over one read and the text decrypted from a second read: a flip between
// the two gave a forged text with a positive count. Both outcomes must be
// seen, else the thread did not race with the calls and the test says
// nothing.
@(test)
an_open_while_another_thread_changes_the_sealed_text :: proc(t: ^testing.T) {
	for aead in Aead {
		key := aead == .ChaCha20_Poly1305 ? bytes_of("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f") : bytes_of("feffe9928665731c6d6a8f9467308308")
		key_text := string(key)
		nonce := string(bytes_of("070000004041424344454647"))
		additional := string(bytes_of("50515253c0c1c2c3c4c5c6c7"))
		text := SUNSCREEN
		shared: Changing_Bytes
		sealed_buffer := shared.bytes[:]
		error: errors.Error_Record
		shared.count = int(aead_export(aead, true, &key_text, &nonce, &additional, &text, &sealed_buffer, &error))
		testing.expect_value(t, shared.count, len(SUNSCREEN) + TAG_SIZE)
		shared.place = 20
		shared.first = shared.bytes[20]
		shared.second = shared.bytes[20] ~ 0x40
		changer := thread.create_and_start_with_data(&shared, flip_until_stopped)
		true_texts, refusals, wrong_texts := 0, 0, 0
		for _ in 0 ..< 200_000 {
			sealed := string(shared.bytes[:shared.count])
			opened: [256]u8
			opened_buffer := opened[:]
			count := aead_export(aead, false, &key_text, &nonce, &additional, &sealed, &opened_buffer, &error)
			switch {
			case count == i64(len(SUNSCREEN)) && string(opened[:count]) == SUNSCREEN:
				true_texts += 1
			case count < 0 && error.kind == i64(errors.Kind.Not_Authentic):
				refusals += 1
			case:
				wrong_texts += 1
			}
		}
		intrinsics.atomic_store(&shared.stop, true)
		thread.join(changer)
		thread.destroy(changer)
		testing.expectf(t, wrong_texts == 0, "%v: %d opens gave a text that is not the sealed one", aead, wrong_texts)
		testing.expectf(t, true_texts > 0 && refusals > 0, "%v: the thread did not race with the opens (%d true, %d refused)", aead, true_texts, refusals)
	}
}

// A signature reads the message once: another thread flips one byte of the
// message during 20 000 signatures, and each signature verifies for one of
// the two messages. Before, the message was hashed two times; a flip between
// the two gave a signature of neither message, with the same r as a true
// signature: two such signatures give the private key.
@(test)
a_signature_while_another_thread_changes_the_message :: proc(t: ^testing.T) {
	secret := string(bytes_of("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"))
	public := string(bytes_of("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"))
	shared: Changing_Bytes
	shared.count = 64
	for &byte, index in shared.bytes[:64] {
		byte = u8(index)
	}
	shared.place = 7
	shared.first = shared.bytes[7]
	shared.second = 0xEE
	changer := thread.create_and_start_with_data(&shared, flip_until_stopped)
	error: errors.Error_Record
	of_first, of_second, of_neither := 0, 0, 0
	first_message, second_message: [64]u8
	copy(first_message[:], shared.bytes[:64])
	copy(second_message[:], shared.bytes[:64])
	second_message[7] = 0xEE
	first_text, second_text := string(first_message[:]), string(second_message[:])
	for _ in 0 ..< 20_000 {
		message := string(shared.bytes[:shared.count])
		signature: [64]u8
		signature_buffer := signature[:]
		testing.expect_value(t, ed25519_sign(&secret, &message, &signature_buffer, &error), 64)
		signature_text := string(signature[:])
		switch {
		case ed25519_verify(&public, &first_text, &signature_text, &error) == 0:
			of_first += 1
		case ed25519_verify(&public, &second_text, &signature_text, &error) == 0:
			of_second += 1
		case:
			of_neither += 1
		}
	}
	intrinsics.atomic_store(&shared.stop, true)
	thread.join(changer)
	thread.destroy(changer)
	testing.expectf(t, of_neither == 0, "%d signatures are of neither message", of_neither)
	testing.expectf(t, of_first > 0 && of_second > 0, "the thread did not race with the signatures (%d, %d)", of_first, of_second)
}

// Each wrong size of a key, a nonce or a text is an error record with the
// number of its argument, never a stop of the program.
@(test)
arguments_of_a_wrong_size :: proc(t: ^testing.T) {
	key_bytes: [40]u8
	nonce_bytes: [16]u8
	text := "some text"
	empty := ""
	output: [64]u8
	result := output[:]
	error: errors.Error_Record
	for size in ([]int{0, 15, 17, 31, 33}) {
		key := string(key_bytes[:size])
		nonce := string(nonce_bytes[:NONCE_SIZE])
		testing.expect(t, seal_with_chacha20_poly1305(&key, &nonce, &empty, &text, &result, &error) < 0 && error.argument == 1, "a ChaCha20 key of a wrong size")
		if size != 16 {
			testing.expect(t, seal_with_aes_128_gcm(&key, &nonce, &empty, &text, &result, &error) < 0 && error.argument == 1, "an AES key of a wrong size")
		}
	}
	key := string(key_bytes[:32])
	for size in ([]int{11, 13}) {
		nonce := string(nonce_bytes[:size])
		testing.expect(t, seal_with_chacha20_poly1305(&key, &nonce, &empty, &text, &result, &error) < 0 && error.argument == 2)
	}
	nonce := string(nonce_bytes[:NONCE_SIZE])
	short := string(output[:15])
	testing.expect(t, open_with_chacha20_poly1305(&key, &nonce, &empty, &short, &result, &error) < 0 && error.kind == i64(errors.Kind.Too_Small) && error.argument == 4)
	long_additional := string(make([]u8, ADDITIONAL_LIMIT + 1, context.temp_allocator))
	testing.expect(t, seal_with_chacha20_poly1305(&key, &nonce, &long_additional, &text, &result, &error) < 0 && error.argument == 3)
}

// A seal into a buffer with no room tells the size that it needs (a count,
// no byte written); an open into a buffer with no room is an error record,
// so that no caller reads the old bytes of its buffer as a text.
@(test)
a_result_with_no_room :: proc(t: ^testing.T) {
	key_bytes: [32]u8
	nonce_bytes: [NONCE_SIZE]u8
	key, nonce, empty := string(key_bytes[:]), string(nonce_bytes[:]), ""
	text := SUNSCREEN
	sealed_bytes: [256]u8
	sealed_buffer := sealed_bytes[:]
	error: errors.Error_Record
	small: [8]u8
	small_buffer := small[:]
	testing.expect_value(t, seal_with_chacha20_poly1305(&key, &nonce, &empty, &text, &small_buffer, &error), i64(len(SUNSCREEN) + TAG_SIZE))
	testing.expect(t, small == [8]u8{})
	count := seal_with_chacha20_poly1305(&key, &nonce, &empty, &text, &sealed_buffer, &error)
	sealed := string(sealed_bytes[:count])
	testing.expect(t, open_with_chacha20_poly1305(&key, &nonce, &empty, &sealed, &small_buffer, &error) < 0 && error.kind == i64(errors.Kind.Too_Small) && error.argument == 5)
}

// A result that overlaps the text with an offset is an error record (the
// code of the origin stops the program); the same address, in place, is
// right. A refused open leaves no byte of the text in the result.
@(test)
results_that_overlap_and_refused_opens :: proc(t: ^testing.T) {
	key_bytes: [32]u8
	nonce_bytes: [NONCE_SIZE]u8
	key, nonce, empty := string(key_bytes[:]), string(nonce_bytes[:]), ""
	area: [300]u8
	copy(area[:], SUNSCREEN)
	error: errors.Error_Record
	text := string(area[:len(SUNSCREEN)])
	shifted := area[1:]
	testing.expect(t, seal_with_chacha20_poly1305(&key, &nonce, &empty, &text, &shifted, &error) < 0 && error.kind == i64(errors.Kind.Bad_Value) && error.argument == 5)
	in_place := area[:]
	count := seal_with_chacha20_poly1305(&key, &nonce, &empty, &text, &in_place, &error)
	testing.expect_value(t, count, i64(len(SUNSCREEN) + TAG_SIZE))
	sealed := string(area[:count])
	opened_in_place := area[:]
	testing.expect_value(t, open_with_chacha20_poly1305(&key, &nonce, &empty, &sealed, &opened_in_place, &error), i64(len(SUNSCREEN)))
	testing.expect_value(t, string(area[:len(SUNSCREEN)]), SUNSCREEN)
	count = seal_with_aes_128_gcm(&key, &nonce, &empty, &text, &in_place, &error)
	testing.expect(t, count < 0) // An AES key of 32 bytes: argument 1.
	aes_key := string(key_bytes[:16])
	count = seal_with_aes_128_gcm(&aes_key, &nonce, &empty, &text, &in_place, &error)
	area[count - 1] ~= 1
	sealed = string(area[:count])
	opened: [256]u8
	for &byte in opened {
		byte = 0xA5
	}
	opened_buffer := opened[:]
	testing.expect(t, open_with_aes_128_gcm(&aes_key, &nonce, &empty, &sealed, &opened_buffer, &error) < 0 && error.kind == i64(errors.Kind.Not_Authentic))
	for byte in opened[:len(SUNSCREEN)] {
		testing.expect_value(t, byte, 0)
	}
}

// HKDF expand gives 8160 bytes at most (RFC 5869, section 2.3): 8160 is
// given, 8161 is an error record.
@(test)
hkdf_expand_at_its_limit :: proc(t: ^testing.T) {
	key_bytes: [32]u8
	key, info := string(key_bytes[:]), "label"
	output := make([]u8, HKDF_EXPAND_LIMIT + 1, context.temp_allocator)
	error: errors.Error_Record
	testing.expect_value(t, hkdf_sha256_expand(&key, &info, HKDF_EXPAND_LIMIT, &output, &error), HKDF_EXPAND_LIMIT)
	testing.expect(t, hkdf_sha256_expand(&key, &info, HKDF_EXPAND_LIMIT + 1, &output, &error) < 0 && error.kind == i64(errors.Kind.Bad_Value) && error.argument == 3)
	long_info := string(make([]u8, INFO_LIMIT + 1, context.temp_allocator))
	testing.expect(t, hkdf_sha256_expand(&key, &long_info, 32, &output, &error) < 0 && error.argument == 2)
}

// Each point of small order gives Bad_Value from the export x25519: its
// shared secret would be 32 zero bytes (RFC 7748, section 6.1).
@(test)
x25519_refuses_points_of_small_order :: proc(t: ^testing.T) {
	points := [?]string {
		"0000000000000000000000000000000000000000000000000000000000000000",
		"0100000000000000000000000000000000000000000000000000000000000000",
		"e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
		"5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
		"ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
		"edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
		"eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
	}
	scalar := string(bytes_of("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"))
	for point_text in points {
		point := string(bytes_of(point_text))
		output: [32]u8
		result := output[:]
		error: errors.Error_Record
		testing.expectf(t, x25519_export(&scalar, &point, &result, &error) < 0 && error.kind == i64(errors.Kind.Bad_Value) && error.argument == 2, "the point %s", point_text)
		testing.expect(t, output == [32]u8{})
	}
}
