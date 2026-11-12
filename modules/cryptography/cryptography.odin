// The cryptography of the system as one module of code: each export is a
// primitive of Odin's core:crypto that the system took (support/cryptography,
// docs/CRYPTOGRAPHY.md), in the forms of the system.
//
// - The caller supplies the memory: each Text is bytes of the caller, each
//   result is a buffer of the caller, so the module allocates nothing.
// - Each byte of the caller is read once. The headers of the Texts and of the
//   result are read once at the entry. Each input that the code of the origin
//   reads more than once (a nonce, the additional data, a message to sign,
//   the info of HKDF, a tag) is first copied into memory of the module, with
//   a limit. So another thread or another program that writes the memory of
//   the caller during the call cannot make the export check some bytes and
//   use others.
// - The result buffer must be private memory of the caller: an open and a
//   seal write it and read it back (the origin decrypts in place after the
//   tag check, and computes the tag of a seal over the bytes that it wrote).
//   docs/CRYPTOGRAPHY.md, section 6, says which arguments must be private.
// - A failure is an error record and a negative count, never a boolean that a
//   caller can forget. An open whose tag does not verify gives Not_Authentic
//   and leaves no byte of the text in the result.
// - The copies of secrets that the module makes are erased, and so is the
//   stack below each export after the work (erase_stack_below_the_caller):
//   the frames of the origin hold expanded keys and hash states.
//
// A program says which cryptography it runs by the hash of this module: the
// hash names exactly the code that runs. The names of the algorithms stay as
// their standards write them.
package cryptography

import "base:runtime"
import "contract:errors"
import "support:cryptography/aes"
import "support:cryptography/argon2id"
import "support:cryptography/chacha20"
import "support:cryptography/chacha20poly1305"
import bytes "support:cryptography/compatibility_bytes"
import crypto "support:cryptography/compatibility_crypto"
import "support:cryptography/ed25519"
import "support:cryptography/hkdf"
import "support:cryptography/hmac"
import "support:cryptography/sha2"
import "support:cryptography/x25519"
import "support:system"

TAG_SIZE :: 16
NONCE_SIZE :: 12
SEAL_LIMIT :: 64 * 1024 // The bytes of one text to seal or open: a QUIC packet has 1500 at most.
// The additional data of an AEAD, copied into the module: the header of a
// QUIC packet, with its token. An Initial packet carries the token of the
// server whole (RFC 9000, section 17.2.2, sets no limit to it), and the
// Retry Pseudo-Packet holds a Retry packet (RFC 9001, section 5.8): one
// datagram of 2048 bytes at most (support/quic, DATAGRAM_LIMIT).
ADDITIONAL_LIMIT :: 2048
// A message that Ed25519 signs or verifies, copied into the module: the
// content of a TLS 1.3 CertificateVerify has 64 + 34 + 48 bytes at most
// (RFC 8446, section 4.4.3).
MESSAGE_LIMIT :: 4096
// The info of HKDF, copied into the module: a TLS 1.3 HkdfLabel has
// 2 + 1 + 255 + 1 + 255 bytes at most (RFC 8446, section 7.1).
INFO_LIMIT :: 1024
HKDF_EXPAND_LIMIT :: 255 * sha2.DIGEST_SIZE_256 // RFC 5869, section 2.3.

ERROR :: -1

// module_context gives the context of the code of the origin: all zero. The
// origin uses no allocator here, and an assertion with no procedure goes to
// the default one of the runtime (it stops the program). Not
// runtime.default_context(): it stores the default random generator, whose
// thread-local state a module does not have (the convert step of the tool
// refuses thread-local data).
@(private)
module_context :: #force_inline proc "contextless" () -> runtime.Context {
	return {}
}

// size_check gives an error record when an input has not the size that it
// must have (argument from 1).
@(private)
size_check :: proc "contextless" (input: []u8, size: int, argument: i64, error: ^errors.Error_Record) -> bool {
	if len(input) == size {
		return true
	}
	if len(input) < size {
		errors.fail(error, ERROR, len(input) == 0 ? .Empty : .Too_Small, .Bytes, argument, i64(len(input)), i64(size))
	} else {
		errors.fail(error, ERROR, .Too_Long, .Bytes, argument, i64(len(input)), i64(size))
	}
	return false
}

// limit_check gives an error record when an input is over its limit.
@(private)
limit_check :: proc "contextless" (input: []u8, limit: int, argument: i64, error: ^errors.Error_Record) -> bool {
	if len(input) <= limit {
		return true
	}
	errors.fail(error, ERROR, .Too_Long, .Bytes, argument, i64(len(input)), i64(limit))
	return false
}

// Which AEAD an export runs.
@(private)
Aead :: enum {
	ChaCha20_Poly1305,
	Aes_128_Gcm,
}

@(private)
aead_key_size := [Aead]int {
	.ChaCha20_Poly1305 = 32,
	.Aes_128_Gcm       = 16,
}

// aead_run seals or opens; aead_export calls it, then erases the stack
// below. It reads each header once, copies the key, the nonce, the additional
// data and the tag, and reads each byte of the text once.
@(private)
aead_run :: #force_no_inline proc "contextless" (aead: Aead, sealing: bool, key_text, nonce_text, additional_text, input_text: string, output_buffer: []u8, error: ^errors.Error_Record) -> i64 {
	context = module_context()
	key := transmute([]u8)key_text
	nonce := transmute([]u8)nonce_text
	additional := transmute([]u8)additional_text
	input := transmute([]u8)input_text
	if !size_check(key, aead_key_size[aead], 1, error) || !size_check(nonce, NONCE_SIZE, 2, error) || !limit_check(additional, ADDITIONAL_LIMIT, 3, error) || !limit_check(input, SEAL_LIMIT, 4, error) {
		return ERROR
	}
	if !sealing && len(input) < TAG_SIZE {
		return errors.fail(error, ERROR, .Too_Small, .Bytes, 4, i64(len(input)), TAG_SIZE)
	}
	count := sealing ? len(input) + TAG_SIZE : len(input) - TAG_SIZE
	if len(output_buffer) < count {
		// A seal tells the size that it needs, as each Text result does. An
		// open does not: a caller that reads a count of zero or more as a
		// success would read the old bytes of its buffer as an authentic text.
		if sealing {
			return i64(count)
		}
		return errors.fail(error, ERROR, .Too_Small, .Bytes, 5, i64(len(output_buffer)), i64(count))
	}
	output := output_buffer[:count]
	// A result that overlaps the text with an offset would stop the program
	// in the origin; here it is an error record. An exact overlap (in place)
	// is right.
	if bytes.alias_inexactly(output, input) || bytes.alias(output, key) || bytes.alias(output, nonce) || bytes.alias(output, additional) {
		return errors.fail(error, ERROR, .Bad_Value, .Bytes, 5)
	}
	key_copy: [32]u8
	nonce_copy: [NONCE_SIZE]u8
	additional_copy: [ADDITIONAL_LIMIT]u8
	tag_copy: [TAG_SIZE]u8
	copy(key_copy[:], key)
	copy(nonce_copy[:], nonce)
	copy(additional_copy[:], additional)
	defer crypto.zero_explicit(&key_copy, size_of(key_copy))
	private_additional := additional_copy[:len(additional)]
	authentic := true
	if sealing {
		// The text is read once, as the cipher writes the result.
		switch aead {
		case .ChaCha20_Poly1305:
			cipher: chacha20poly1305.Context
			chacha20poly1305.init(&cipher, key_copy[:32])
			chacha20poly1305.seal(&cipher, output[:len(input)], output[len(input):], nonce_copy[:], private_additional, input)
			chacha20poly1305.reset(&cipher)
		case .Aes_128_Gcm:
			cipher: aes.Context_GCM
			aes.init_gcm(&cipher, key_copy[:16])
			aes.seal_gcm(&cipher, output[:len(input)], output[len(input):], nonce_copy[:], private_additional, input)
			aes.reset_gcm(&cipher)
		}
		return i64(count)
	}
	// An open: the tag into the module, the sealed text into the result
	// (each byte read once), then the check and the decryption in place.
	copy(tag_copy[:], input[count:])
	if raw_data(output) != raw_data(input) {
		copy(output, input[:count])
	}
	switch aead {
	case .ChaCha20_Poly1305:
		cipher: chacha20poly1305.Context
		chacha20poly1305.init(&cipher, key_copy[:32])
		authentic = chacha20poly1305.open(&cipher, output, nonce_copy[:], private_additional, output, tag_copy[:])
		chacha20poly1305.reset(&cipher)
	case .Aes_128_Gcm:
		cipher: aes.Context_GCM
		aes.init_gcm(&cipher, key_copy[:16])
		authentic = aes.open_gcm(&cipher, output, nonce_copy[:], private_additional, output, tag_copy[:])
		aes.reset_gcm(&cipher)
	}
	if !authentic {
		crypto.zero_explicit(raw_data(output), len(output))
		return errors.fail(error, ERROR, .Not_Authentic, .Bytes, 4, i64(len(input)))
	}
	return i64(count)
}

// aead_export reads each header of the caller once, runs the AEAD, and
// erases the stack where the code of the origin held the expanded key.
@(private)
aead_export :: proc "contextless" (aead: Aead, sealing: bool, key, nonce, additional, text: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	count := aead_run(aead, sealing, key^, nonce^, additional^, text^, result^, error)
	crypto.erase_stack_below_the_caller()
	return count
}

// seal_with_chacha20_poly1305 encrypts a text and appends its tag of 16 bytes (RFC 8439). The key has 32 bytes, the nonce 12, the additional data 1024 at most; the result has the bytes of the text and 16 more, and must be private memory of the caller. A nonce must never come two times with one key: that is the duty of the caller. The result is the count of bytes (the size that the result needs, when it is too small), or a negative number with an error record: Empty, Too_Small or Too_Long for a key, a nonce or a text of another size, Bad_Value for a result that overlaps an argument.
@(export, link_name = "seal_with_chacha20_poly1305")
seal_with_chacha20_poly1305 :: proc "c" (key, nonce, additional, text: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	return aead_export(.ChaCha20_Poly1305, true, key, nonce, additional, text, result, error)
}

// open_with_chacha20_poly1305 checks the tag of a sealed text and decrypts it (RFC 8439). The result must be private memory of the caller, with room for the text. The result is the count of bytes, or a negative number with an error record: Not_Authentic when the tag does not verify (the result keeps no byte of the text), Too_Small for a sealed text under 16 bytes or a result with no room, Bad_Value for a result that overlaps an argument.
@(export, link_name = "open_with_chacha20_poly1305")
open_with_chacha20_poly1305 :: proc "c" (key, nonce, additional, sealed: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	return aead_export(.ChaCha20_Poly1305, false, key, nonce, additional, sealed, result, error)
}

// seal_with_aes_128_gcm encrypts a text and appends its tag of 16 bytes (NIST SP 800-38D). The key has 16 bytes, the nonce 12. A nonce must never come two times with one key: with AES-GCM a repeated nonce gives away the key of the tag, and with it forgeries. The rules of the arguments and of the result are those of seal_with_chacha20_poly1305.
@(export, link_name = "seal_with_aes_128_gcm")
seal_with_aes_128_gcm :: proc "c" (key, nonce, additional, text: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	return aead_export(.Aes_128_Gcm, true, key, nonce, additional, text, result, error)
}

// open_with_aes_128_gcm checks the tag of a sealed text and decrypts it. The rules of the arguments, of the result and of the errors are those of open_with_chacha20_poly1305.
@(export, link_name = "open_with_aes_128_gcm")
open_with_aes_128_gcm :: proc "c" (key, nonce, additional, sealed: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	return aead_export(.Aes_128_Gcm, false, key, nonce, additional, sealed, result, error)
}

@(private)
sha256_run :: #force_no_inline proc "contextless" (text: string, output: []u8) -> i64 {
	context = module_context()
	if len(output) < sha2.DIGEST_SIZE_256 {
		return sha2.DIGEST_SIZE_256
	}
	hash: sha2.Context_256
	sha2.init_256(&hash)
	sha2.update(&hash, transmute([]u8)text)
	sha2.final(&hash, output[:sha2.DIGEST_SIZE_256])
	return sha2.DIGEST_SIZE_256
}

// sha256 gives the SHA-256 hash of a text: 32 bytes (FIPS 180-4).
@(export, link_name = "sha256")
sha256 :: proc "c" (text: ^string, result: ^[]u8) -> i64 {
	count := sha256_run(text^, result^)
	// The text can be a secret (a transcript, a key); the frames of the hash
	// held its words.
	crypto.erase_stack_below_the_caller()
	return count
}

@(private)
hmac_sha256_run :: #force_no_inline proc "contextless" (key, text: string, output: []u8) -> i64 {
	context = module_context()
	if len(output) < sha2.DIGEST_SIZE_256 {
		return sha2.DIGEST_SIZE_256
	}
	// Into the module first: the origin computes in the result, which can be
	// read by another party before the last step.
	tag: [sha2.DIGEST_SIZE_256]u8
	hmac.sum(.SHA256, tag[:], transmute([]u8)text, transmute([]u8)key)
	copy(output, tag[:])
	crypto.zero_explicit(&tag, size_of(tag))
	return sha2.DIGEST_SIZE_256
}

// hmac_sha256 gives the HMAC of a text with a key, with SHA-256: 32 bytes (RFC 2104).
@(export, link_name = "hmac_sha256")
hmac_sha256 :: proc "c" (key, text: ^string, result: ^[]u8) -> i64 {
	count := hmac_sha256_run(key^, text^, result^)
	crypto.erase_stack_below_the_caller()
	return count
}

@(private)
hkdf_sha256_extract_run :: #force_no_inline proc "contextless" (salt, input: string, output: []u8) -> i64 {
	context = module_context()
	if len(output) < sha2.DIGEST_SIZE_256 {
		return sha2.DIGEST_SIZE_256
	}
	key: [sha2.DIGEST_SIZE_256]u8
	hkdf.extract(.SHA256, transmute([]u8)salt, transmute([]u8)input, key[:])
	copy(output, key[:])
	crypto.zero_explicit(&key, size_of(key))
	return sha2.DIGEST_SIZE_256
}

// hkdf_sha256_extract gives the pseudorandom key of HKDF from a salt and input keying material, with SHA-256: 32 bytes (RFC 5869, section 2.2).
@(export, link_name = "hkdf_sha256_extract")
hkdf_sha256_extract :: proc "c" (salt, input: ^string, result: ^[]u8) -> i64 {
	count := hkdf_sha256_extract_run(salt^, input^, result^)
	crypto.erase_stack_below_the_caller()
	return count
}

@(private)
hkdf_sha256_expand_run :: #force_no_inline proc "contextless" (key_text, info_text: string, length: i64, output: []u8, error: ^errors.Error_Record) -> i64 {
	context = module_context()
	key := transmute([]u8)key_text
	info := transmute([]u8)info_text
	if len(key) < sha2.DIGEST_SIZE_256 {
		return errors.fail(error, ERROR, .Too_Small, .Bytes, 1, i64(len(key)), sha2.DIGEST_SIZE_256)
	}
	if !limit_check(info, INFO_LIMIT, 2, error) {
		return ERROR
	}
	if length < 1 || length > HKDF_EXPAND_LIMIT {
		return errors.fail(error, ERROR, .Bad_Value, .Bytes, 3, length, HKDF_EXPAND_LIMIT)
	}
	if i64(len(output)) < length {
		return length
	}
	// The origin reads the info once for each block, and reads each block
	// back from its output: the info and the output are memory of the module,
	// and the result gets the whole output at the end.
	info_copy: [INFO_LIMIT]u8
	copy(info_copy[:], info)
	expanded: [HKDF_EXPAND_LIMIT]u8
	hkdf.expand(.SHA256, key, info_copy[:len(info)], expanded[:length])
	copy(output, expanded[:length])
	crypto.zero_explicit(&expanded, int(length))
	return length
}

// hkdf_sha256_expand gives length bytes of output keying material from a pseudorandom key and an info text, with SHA-256 (RFC 5869, section 2.3). The key has 32 bytes at least, the info 1024 at most; the length is 1 to 8160. The result is the count of bytes, or a negative number with an error record.
@(export, link_name = "hkdf_sha256_expand")
hkdf_sha256_expand :: proc "c" (key, info: ^string, length: i64, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	count := hkdf_sha256_expand_run(key^, info^, length, result^, error)
	crypto.erase_stack_below_the_caller()
	return count
}

@(private)
x25519_run :: #force_no_inline proc "contextless" (scalar_text, point_text: string, output: []u8, error: ^errors.Error_Record) -> i64 {
	context = module_context()
	scalar := transmute([]u8)scalar_text
	point := transmute([]u8)point_text
	if !size_check(scalar, x25519.SCALAR_SIZE, 1, error) || !size_check(point, x25519.POINT_SIZE, 2, error) {
		return ERROR
	}
	if len(output) < x25519.POINT_SIZE {
		return x25519.POINT_SIZE
	}
	scalar_copy, point_copy, shared: [32]u8
	copy(scalar_copy[:], scalar)
	copy(point_copy[:], point)
	defer crypto.zero_explicit(&scalar_copy, size_of(scalar_copy))
	defer crypto.zero_explicit(&shared, size_of(shared))
	x25519.scalarmult(shared[:], scalar_copy[:], point_copy[:])
	if crypto.is_zero_constant_time(shared[:]) == 1 {
		// A point of small order gives a shared secret of zeros (RFC 7748,
		// section 6.1): no secret is shared, so the point is refused.
		return errors.fail(error, ERROR, .Bad_Value, .Bytes, 2)
	}
	copy(output, shared[:])
	return x25519.POINT_SIZE
}

// x25519 gives the shared secret of a scalar of 32 bytes and a point of 32 bytes (RFC 7748); with the point 9 it is the public key of the scalar. A point of small order, whose shared secret is 32 zero bytes, is refused with Bad_Value (RFC 7748, section 6.1).
@(export, link_name = "x25519")
x25519_export :: proc "c" (scalar, point: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	count := x25519_run(scalar^, point^, result^, error)
	crypto.erase_stack_below_the_caller()
	return count
}

@(private)
ed25519_public_key_run :: #force_no_inline proc "contextless" (secret_text: string, output: []u8, error: ^errors.Error_Record) -> i64 {
	context = module_context()
	secret := transmute([]u8)secret_text
	if !size_check(secret, ed25519.PRIVATE_KEY_SIZE, 1, error) {
		return ERROR
	}
	if len(output) < ed25519.PUBLIC_KEY_SIZE {
		return ed25519.PUBLIC_KEY_SIZE
	}
	secret_copy: [ed25519.PRIVATE_KEY_SIZE]u8
	copy(secret_copy[:], secret)
	defer crypto.zero_explicit(&secret_copy, size_of(secret_copy))
	private_key: ed25519.Private_Key
	defer ed25519.private_key_clear(&private_key)
	// The copy has the size of a private key: the origin refuses only
	// another size.
	if !ed25519.private_key_set_bytes(&private_key, secret_copy[:]) {
		return ERROR
	}
	public_key: ed25519.Public_Key
	ed25519.public_key_set_priv(&public_key, &private_key)
	ed25519.public_key_bytes(&public_key, output[:ed25519.PUBLIC_KEY_SIZE])
	return ed25519.PUBLIC_KEY_SIZE
}

// ed25519_public_key gives the public key of a private key of 32 bytes (RFC 8032, section 5.1.5).
@(export, link_name = "ed25519_public_key")
ed25519_public_key :: proc "c" (secret: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	count := ed25519_public_key_run(secret^, result^, error)
	crypto.erase_stack_below_the_caller()
	return count
}

@(private)
ed25519_sign_run :: #force_no_inline proc "contextless" (secret_text, message_text: string, output: []u8, error: ^errors.Error_Record) -> i64 {
	context = module_context()
	secret := transmute([]u8)secret_text
	message := transmute([]u8)message_text
	if !size_check(secret, ed25519.PRIVATE_KEY_SIZE, 1, error) || !limit_check(message, MESSAGE_LIMIT, 2, error) {
		return ERROR
	}
	if len(output) < ed25519.SIGNATURE_SIZE {
		return ed25519.SIGNATURE_SIZE
	}
	// The origin hashes the message two times (for r, then for the digest
	// of R, A and M), and reads R back from the signature that it writes. A
	// message or a signature that changes between the two gives two
	// signatures with one r, and from them the private key: so both are
	// memory of the module.
	secret_copy: [ed25519.PRIVATE_KEY_SIZE]u8
	message_copy: [MESSAGE_LIMIT]u8
	signature: [ed25519.SIGNATURE_SIZE]u8
	copy(secret_copy[:], secret)
	copy(message_copy[:], message)
	defer crypto.zero_explicit(&secret_copy, size_of(secret_copy))
	private_key: ed25519.Private_Key
	defer ed25519.private_key_clear(&private_key)
	// The copy has the size of a private key: the origin refuses only
	// another size.
	if !ed25519.private_key_set_bytes(&private_key, secret_copy[:]) {
		return ERROR
	}
	ed25519.sign(&private_key, message_copy[:len(message)], signature[:])
	copy(output, signature[:])
	return ed25519.SIGNATURE_SIZE
}

// ed25519_sign gives the signature of a message of 4096 bytes at most, 64 bytes, with a private key of 32 bytes (RFC 8032, section 5.1.6).
@(export, link_name = "ed25519_sign")
ed25519_sign :: proc "c" (secret, message: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	count := ed25519_sign_run(secret^, message^, result^, error)
	crypto.erase_stack_below_the_caller()
	return count
}

@(private)
ed25519_verify_run :: #force_no_inline proc "contextless" (public_text, message_text, signature_text: string, error: ^errors.Error_Record) -> i64 {
	context = module_context()
	public := transmute([]u8)public_text
	message := transmute([]u8)message_text
	signature := transmute([]u8)signature_text
	if !size_check(public, ed25519.PUBLIC_KEY_SIZE, 1, error) || !limit_check(message, MESSAGE_LIMIT, 2, error) || !size_check(signature, ed25519.SIGNATURE_SIZE, 3, error) {
		return ERROR
	}
	public_copy: [ed25519.PUBLIC_KEY_SIZE]u8
	message_copy: [MESSAGE_LIMIT]u8
	signature_copy: [ed25519.SIGNATURE_SIZE]u8
	copy(public_copy[:], public)
	copy(message_copy[:], message)
	copy(signature_copy[:], signature)
	public_key: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&public_key, public_copy[:]) {
		return errors.fail(error, ERROR, .Bad_Value, .Bytes, 1)
	}
	if !ed25519.verify(&public_key, message_copy[:len(message)], signature_copy[:]) {
		return errors.fail(error, ERROR, .Not_Authentic, .Bytes, 3)
	}
	return 0
}

// ed25519_verify checks the signature of a message of 4096 bytes at most with a public key of 32 bytes (RFC 8032, section 5.1.7; strict: a signature with a non-canonical S or R, or a public key of small order, is refused). The result is 0, or a negative number with an error record: Not_Authentic when the signature does not verify, Bad_Value for a public key that is not a point.
@(export, link_name = "ed25519_verify")
ed25519_verify :: proc "c" (public, message, signature: ^string, error: ^errors.Error_Record) -> i64 {
	count := ed25519_verify_run(public^, message^, signature^, error)
	crypto.erase_stack_below_the_caller()
	return count
}

// The limits of the inputs of Argon2id, copied into the module: a
// passphrase typed at the keyboard is far shorter. A salt of 8 bytes at
// least (RFC 9106, section 3.1).
PASSWORD_LIMIT :: 1024
SALT_LEAST :: 8
SALT_LIMIT :: 64
// The KiB of the blocks: 8 for each lane at least (RFC 9106), 4 GiB at
// most, which the parameter of the origin can count.
ARGON2ID_MEMORY_LIMIT :: 4 * 1024 * 1024
ARGON2ID_PASSES_LIMIT :: 64
// The origin computes the lanes one after the other, in one thread: more
// lanes cost the same time, and a limit keeps the record small.
ARGON2ID_LANES_LIMIT :: 16
// The tag: 4 bytes at least (RFC 9106); 64 at most, a key and more.
ARGON2ID_TAG_LEAST :: 4
ARGON2ID_TAG_LIMIT :: 64

// The cost of one derivation of Argon2id, as one record: an export has at
// most 6 parameters (docs/MODULE_CONTRACT.md, section 4).
Argon2id_Cost :: struct {
	memory_kibibytes: i64, // The KiB of the blocks: 8 for each lane at least.
	passes:           i64, // 1 to 64.
	lanes:            i64, // 1 to 16.
	tag_bytes:        i64, // The bytes of the result: 4 to 64.
}

@(private)
argon2id_run :: #force_no_inline proc "contextless" (password_text, salt_text: string, cost: Argon2id_Cost, work: system.Bytes_To_Change, output: []u8, error: ^errors.Error_Record) -> i64 {
	context = module_context()
	password := transmute([]u8)password_text
	salt := transmute([]u8)salt_text
	if !limit_check(password, PASSWORD_LIMIT, 1, error) {
		return ERROR
	}
	if len(salt) < SALT_LEAST {
		return errors.fail(error, ERROR, len(salt) == 0 ? .Empty : .Too_Small, .Bytes, 2, i64(len(salt)), SALT_LEAST)
	}
	if !limit_check(salt, SALT_LIMIT, 2, error) {
		return ERROR
	}
	// The record is a copy: the caller cannot change it after these checks.
	if cost.lanes < 1 || cost.lanes > ARGON2ID_LANES_LIMIT || cost.passes < 1 || cost.passes > ARGON2ID_PASSES_LIMIT || cost.tag_bytes < ARGON2ID_TAG_LEAST || cost.tag_bytes > ARGON2ID_TAG_LIMIT {
		return errors.fail(error, ERROR, .Bad_Value, .None, 3)
	}
	if cost.memory_kibibytes < 8 * cost.lanes || cost.memory_kibibytes > ARGON2ID_MEMORY_LIMIT {
		return errors.fail(error, ERROR, .Bad_Value, .None, 3, cost.memory_kibibytes, ARGON2ID_MEMORY_LIMIT)
	}
	// The header of the work memory is read once (the argument is a copy).
	needed := u64(cost.memory_kibibytes) * 1024
	if work.bytes == nil || work.capacity < needed || uintptr(work.bytes) % 8 != 0 {
		return errors.fail(error, ERROR, .Too_Small, .Bytes, 4, i64(min(work.capacity, 1 << 62)), i64(needed))
	}
	tag_size := int(cost.tag_bytes)
	if len(output) < tag_size {
		return i64(tag_size)
	}
	password_copy: [PASSWORD_LIMIT]u8
	salt_copy: [SALT_LIMIT]u8
	tag: [ARGON2ID_TAG_LIMIT]u8
	copy(password_copy[:], password)
	copy(salt_copy[:], salt)
	defer crypto.zero_explicit(&password_copy, size_of(password_copy))
	defer crypto.zero_explicit(&tag, size_of(tag))
	parameters := argon2id.Parameters {
		memory_size = u32(cost.memory_kibibytes),
		passes      = u32(cost.passes),
		parallelism = u32(cost.lanes),
	}
	// The origin erases the blocks at its end (sanitize).
	if argon2id.derive(&parameters, password_copy[:len(password)], salt_copy[:len(salt)], tag[:tag_size], work_memory = work.bytes[:needed]) != .None {
		return errors.fail(error, ERROR, .Too_Small, .Bytes, 4, i64(min(work.capacity, 1 << 62)), i64(needed))
	}
	copy(output, tag[:tag_size])
	return i64(tag_size)
}

// argon2id derives a key from a password and a salt with Argon2id (RFC 9106), at the cost of the record: the KiB of the blocks, the passes, the lanes and the bytes of the key. The caller supplies the blocks in work: memory_kibibytes * 1024 bytes of its own memory, aligned on 8 bytes, which the module erases at the end. The password has 1024 bytes at most, the salt 8 to 64. The result is the count of the bytes of the key, or a negative number with an error record: Too_Long for the password (1), Too_Small or Too_Long for the salt (2), Bad_Value for the cost (3), Too_Small for the work memory (4).
@(export, link_name = "argon2id")
argon2id_export :: proc "c" (password, salt: ^string, cost: ^Argon2id_Cost, work: ^system.Bytes_To_Change, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	count := argon2id_run(password^, salt^, cost^, work^, result^, error)
	crypto.erase_stack_below_the_caller()
	return count
}

HEADER_PROTECTION_SAMPLE_SIZE :: 16
HEADER_PROTECTION_MASK_SIZE :: 5

@(private)
Header_Protection :: enum {
	Aes_128,
	ChaCha20,
}

@(private)
header_protection_mask_run :: #force_no_inline proc "contextless" (kind: Header_Protection, key_text, sample_text: string, output: []u8, error: ^errors.Error_Record) -> i64 {
	context = module_context()
	key := transmute([]u8)key_text
	sample := transmute([]u8)sample_text
	if !size_check(key, kind == .Aes_128 ? 16 : 32, 1, error) || !size_check(sample, HEADER_PROTECTION_SAMPLE_SIZE, 2, error) {
		return ERROR
	}
	if len(output) < HEADER_PROTECTION_MASK_SIZE {
		return HEADER_PROTECTION_MASK_SIZE
	}
	key_copy: [32]u8
	sample_copy, block: [HEADER_PROTECTION_SAMPLE_SIZE]u8
	copy(key_copy[:], key)
	copy(sample_copy[:], sample)
	defer crypto.zero_explicit(&key_copy, size_of(key_copy))
	switch kind {
	case .Aes_128:
		// RFC 9001, section 5.4.3: the mask is AES-ECB of the sample.
		cipher: aes.Context_ECB
		aes.init_ecb(&cipher, key_copy[:16])
		aes.encrypt_ecb(&cipher, block[:], sample_copy[:])
		aes.reset_ecb(&cipher)
	case .ChaCha20:
		// RFC 9001, section 5.4.4: the first 4 bytes of the sample are the
		// block counter (little-endian), the other 12 the nonce; the mask is
		// ChaCha20 over 5 zero bytes, its keystream.
		counter := u64(sample_copy[0]) | u64(sample_copy[1]) << 8 | u64(sample_copy[2]) << 16 | u64(sample_copy[3]) << 24
		cipher: chacha20.Context
		chacha20.init(&cipher, key_copy[:32], sample_copy[4:16])
		chacha20.seek(&cipher, counter)
		chacha20.keystream_bytes(&cipher, block[:HEADER_PROTECTION_MASK_SIZE])
		chacha20.reset(&cipher)
	}
	copy(output, block[:HEADER_PROTECTION_MASK_SIZE])
	return HEADER_PROTECTION_MASK_SIZE
}

// header_protection_mask_with_aes_128 gives the 5 bytes of the QUIC header protection mask of a sample of 16 bytes with a key of 16 bytes: AES-128 of the sample (RFC 9001, section 5.4.3). The result is 5, or a negative number with an error record for a key or a sample of another size.
@(export, link_name = "header_protection_mask_with_aes_128")
header_protection_mask_with_aes_128 :: proc "c" (key, sample: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	count := header_protection_mask_run(.Aes_128, key^, sample^, result^, error)
	crypto.erase_stack_below_the_caller()
	return count
}

// header_protection_mask_with_chacha20 gives the 5 bytes of the QUIC header protection mask of a sample of 16 bytes with a key of 32 bytes: the ChaCha20 keystream at the counter and the nonce that the sample gives (RFC 9001, section 5.4.4). The result is 5, or a negative number with an error record for a key or a sample of another size.
@(export, link_name = "header_protection_mask_with_chacha20")
header_protection_mask_with_chacha20 :: proc "c" (key, sample: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	count := header_protection_mask_run(.ChaCha20, key^, sample^, result^, error)
	crypto.erase_stack_below_the_caller()
	return count
}
