package kerneltool

import "contract:system_description"
import "support:cryptography/ed25519"
import "core:testing"

// The test signing key of the repository is the key of RFC 8032, section
// 7.1, TEST 1, and its public key is the one that the boot program knows as
// the test key.
@(test)
the_test_signing_key_is_the_published_one :: proc(t: ^testing.T) {
	seed, ok := signing_key_file_read(TEST_SIGNING_KEY_FILE)
	testing.expect(t, ok)
	private_key: ed25519.Private_Key
	testing.expect(t, ed25519.private_key_set_bytes(&private_key, seed[:]))
	public: [system_description.PUBLIC_KEY_SIZE]u8
	ed25519.private_key_public_bytes(&private_key, public[:])
	testing.expect(t, public == system_description.TEST_PUBLIC_KEY)
	// A signature of a signed message verifies with the public key, and
	// not after one bit of the message changed.
	message: [system_description.SIGNED_MESSAGE_SIZE]u8
	message[3] = 7
	signature: [system_description.SIGNATURE_SIZE]u8
	ed25519.sign(&private_key, message[:], signature[:])
	public_key: ed25519.Public_Key
	testing.expect(t, ed25519.public_key_set_bytes(&public_key, public[:]))
	testing.expect(t, ed25519.verify(&public_key, message[:], signature[:]))
	message[40] ~= 1
	testing.expect(t, !ed25519.verify(&public_key, message[:], signature[:]))
}

@(test)
a_private_key_stays_outside_the_repository :: proc(t: ^testing.T) {
	testing.expect(t, path_inside_repository(TEST_SIGNING_KEY_FILE))
	testing.expect(t, path_inside_repository("tools/signing_key"))
	testing.expect(t, path_inside_repository("."))
	testing.expect(t, !path_inside_repository("/nonexistent_folder_of_a_test/signing_key"))
}

@(test)
a_key_file_is_64_hexadecimal_digits :: proc(t: ^testing.T) {
	for character in "0123456789abcdefABCDEF" {
		_, valid := signing_key_digit(u8(character))
		testing.expect(t, valid)
	}
	for character in "g /x" {
		_, valid := signing_key_digit(u8(character))
		testing.expect(t, !valid)
	}
}

// The value of the measure register depends on each byte of the
// description: one changed byte gives another value.
@(test)
the_measure_depends_on_the_description :: proc(t: ^testing.T) {
	description := []u8{1, 2, 3, 4}
	changed := []u8{1, 2, 3, 5}
	testing.expect(t, measure_expected(description) == measure_expected(description))
	testing.expect(t, measure_expected(description) != measure_expected(changed))
	zero: [32]u8
	testing.expect(t, measure_expected(description) != zero)
}
