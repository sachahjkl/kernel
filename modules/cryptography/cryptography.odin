// The cryptography of the system as one module of code: each export
// is a primitive of Odin's core:crypto that the system took
// (support/cryptography, docs/CRYPTOGRAPHY.md), in the forms of the system.
// The caller supplies the memory: each Text is bytes of the caller, each
// result is a buffer of the caller, so the module allocates nothing. A failure is an error
// record, never a boolean: an open whose tag does not verify gives the kind
// Not_Authentic and writes no byte. Each copy of a secret in this module is
// erased before the export returns (erase_secret_bytes). A program says
// which cryptography it runs by the hash of this module: the hash names
// exactly the code that runs.
//
// The names of the algorithms stay as their standards write them.
package cryptography

import "base:runtime"
import "contract:errors"
import "support:cryptography/aes"
import "support:cryptography/chacha20poly1305"
import crypto "support:cryptography/compatibility_crypto"
import "support:cryptography/ed25519"
import "support:cryptography/hkdf"
import "support:cryptography/hmac"
import "support:cryptography/sha2"
import "support:cryptography/x25519"

TAG_SIZE :: 16
NONCE_SIZE :: 12
SEAL_LIMIT :: 64 * 1024 // The bytes of one text to seal or open: a QUIC packet has 1500 at most.

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

// text_size_check gives an error record when a Text has not the size that
// it must have (argument from 1).
@(private)
text_size_check :: proc "contextless" (text: ^string, size: int, argument: i64, error: ^errors.Error_Record) -> bool {
	if len(text^) == size {
		return true
	}
	if len(text^) < size {
		errors.fail(error, ERROR, len(text^) == 0 ? .Empty : .Too_Small, .Bytes, argument, i64(len(text^)), i64(size))
	} else {
		errors.fail(error, ERROR, .Too_Long, .Bytes, argument, i64(len(text^)), i64(size))
	}
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

// aead_run seals or opens. A result buffer that is too small gets no byte:
// the count says the size that it needs.
@(private)
aead_run :: proc "contextless" (aead: Aead, sealing: bool, key, nonce, additional, text: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	context = module_context()
	if !text_size_check(key, aead_key_size[aead], 1, error) || !text_size_check(nonce, NONCE_SIZE, 2, error) {
		return ERROR
	}
	if len(text^) > SEAL_LIMIT {
		return errors.fail(error, ERROR, .Too_Long, .Bytes, 4, i64(len(text^)), SEAL_LIMIT)
	}
	if !sealing && len(text^) < TAG_SIZE {
		return errors.fail(error, ERROR, .Too_Small, .Bytes, 4, i64(len(text^)), TAG_SIZE)
	}
	count := sealing ? len(text^) + TAG_SIZE : len(text^) - TAG_SIZE
	if len(result^) < count {
		return i64(count)
	}
	key_copy: [32]u8
	copy(key_copy[:], key^)
	defer crypto.zero_explicit(&key_copy, size_of(key_copy))
	input := transmute([]u8)text^
	output := result^[:count]
	nonce_bytes := transmute([]u8)nonce^
	additional_bytes := transmute([]u8)additional^
	authentic := true
	switch aead {
	case .ChaCha20_Poly1305:
		cipher: chacha20poly1305.Context
		chacha20poly1305.init(&cipher, key_copy[:32])
		if sealing {
			chacha20poly1305.seal(&cipher, output[:len(input)], output[len(input):], nonce_bytes, additional_bytes, input)
		} else {
			authentic = chacha20poly1305.open(&cipher, output, nonce_bytes, additional_bytes, input[:count], input[count:])
		}
		chacha20poly1305.reset(&cipher)
	case .Aes_128_Gcm:
		cipher: aes.Context_GCM
		aes.init_gcm(&cipher, key_copy[:16])
		if sealing {
			aes.seal_gcm(&cipher, output[:len(input)], output[len(input):], nonce_bytes, additional_bytes, input)
		} else {
			authentic = aes.open_gcm(&cipher, output, nonce_bytes, additional_bytes, input[:count], input[count:])
		}
		aes.reset_gcm(&cipher)
	}
	if !authentic {
		crypto.zero_explicit(raw_data(output), len(output))
		return errors.fail(error, ERROR, .Not_Authentic, .Bytes, 4, i64(len(text^)))
	}
	return i64(count)
}

// seal_with_chacha20_poly1305 encrypts a text and appends its tag of 16 bytes (RFC 8439). The key has 32 bytes, the nonce 12; the result has the bytes of the text and 16 more. The result is the count of bytes, or a negative number with an error record: Too_Small, Too_Long or Empty for a key or a nonce of another size, Too_Long for a text over 64 KiB.
@(export, link_name = "seal_with_chacha20_poly1305")
seal_with_chacha20_poly1305 :: proc "c" (key, nonce, additional, text: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	return aead_run(.ChaCha20_Poly1305, true, key, nonce, additional, text, result, error)
}

// open_with_chacha20_poly1305 checks the tag of a sealed text and decrypts it (RFC 8439). The result is the count of bytes, or a negative number with an error record: Not_Authentic when the tag does not verify (no byte is given), Too_Small for a text under 16 bytes.
@(export, link_name = "open_with_chacha20_poly1305")
open_with_chacha20_poly1305 :: proc "c" (key, nonce, additional, sealed: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	return aead_run(.ChaCha20_Poly1305, false, key, nonce, additional, sealed, result, error)
}

// seal_with_aes_128_gcm encrypts a text and appends its tag of 16 bytes (NIST SP 800-38D). The key has 16 bytes, the nonce 12. The result is the count of bytes, or a negative number with an error record.
@(export, link_name = "seal_with_aes_128_gcm")
seal_with_aes_128_gcm :: proc "c" (key, nonce, additional, text: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	return aead_run(.Aes_128_Gcm, true, key, nonce, additional, text, result, error)
}

// open_with_aes_128_gcm checks the tag of a sealed text and decrypts it. The result is the count of bytes, or a negative number with an error record: Not_Authentic when the tag does not verify (no byte is given).
@(export, link_name = "open_with_aes_128_gcm")
open_with_aes_128_gcm :: proc "c" (key, nonce, additional, sealed: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	return aead_run(.Aes_128_Gcm, false, key, nonce, additional, sealed, result, error)
}

// sha256 gives the SHA-256 hash of a text: 32 bytes (FIPS 180-4).
@(export, link_name = "sha256")
sha256 :: proc "c" (text: ^string, result: ^[]u8) -> i64 {
	context = module_context()
	if len(result^) < sha2.DIGEST_SIZE_256 {
		return sha2.DIGEST_SIZE_256
	}
	hash: sha2.Context_256
	sha2.init_256(&hash)
	sha2.update(&hash, transmute([]u8)text^)
	sha2.final(&hash, result^[:sha2.DIGEST_SIZE_256])
	return sha2.DIGEST_SIZE_256
}

// hmac_sha256 gives the HMAC of a text with a key, with SHA-256: 32 bytes (RFC 2104).
@(export, link_name = "hmac_sha256")
hmac_sha256 :: proc "c" (key, text: ^string, result: ^[]u8) -> i64 {
	context = module_context()
	if len(result^) < sha2.DIGEST_SIZE_256 {
		return sha2.DIGEST_SIZE_256
	}
	hmac.sum(.SHA256, result^[:sha2.DIGEST_SIZE_256], transmute([]u8)text^, transmute([]u8)key^)
	return sha2.DIGEST_SIZE_256
}

// hkdf_sha256_extract gives the pseudorandom key of HKDF from a salt and input keying material, with SHA-256: 32 bytes (RFC 5869 2.2).
@(export, link_name = "hkdf_sha256_extract")
hkdf_sha256_extract :: proc "c" (salt, input: ^string, result: ^[]u8) -> i64 {
	context = module_context()
	if len(result^) < sha2.DIGEST_SIZE_256 {
		return sha2.DIGEST_SIZE_256
	}
	hkdf.extract(.SHA256, transmute([]u8)salt^, transmute([]u8)input^, result^[:sha2.DIGEST_SIZE_256])
	return sha2.DIGEST_SIZE_256
}

HKDF_EXPAND_LIMIT :: 255 * sha2.DIGEST_SIZE_256 // RFC 5869 2.3.

// hkdf_sha256_expand gives length bytes of output keying material from a pseudorandom key and an info text, with SHA-256 (RFC 5869 2.3). The key has 32 bytes at least; the length is 1 to 8160. The result is the count of bytes, or a negative number with an error record.
@(export, link_name = "hkdf_sha256_expand")
hkdf_sha256_expand :: proc "c" (key, info: ^string, length: i64, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	context = module_context()
	if len(key^) < sha2.DIGEST_SIZE_256 {
		return errors.fail(error, ERROR, .Too_Small, .Bytes, 1, i64(len(key^)), sha2.DIGEST_SIZE_256)
	}
	if length < 1 || length > HKDF_EXPAND_LIMIT {
		return errors.fail(error, ERROR, .Bad_Value, .Bytes, 3, length, HKDF_EXPAND_LIMIT)
	}
	if i64(len(result^)) < length {
		return length
	}
	hkdf.expand(.SHA256, transmute([]u8)key^, transmute([]u8)info^, result^[:length])
	return length
}

// x25519 gives the shared secret of a scalar of 32 bytes and a point of 32 bytes (RFC 7748); with the point 9 it is the public key of the scalar. A result of 32 zero bytes (a point of small order) is refused with Not_Authentic (RFC 7748 6.1).
@(export, link_name = "x25519")
x25519_export :: proc "c" (scalar, point: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	context = module_context()
	if !text_size_check(scalar, x25519.SCALAR_SIZE, 1, error) || !text_size_check(point, x25519.POINT_SIZE, 2, error) {
		return ERROR
	}
	if len(result^) < x25519.POINT_SIZE {
		return x25519.POINT_SIZE
	}
	scalar_copy: [32]u8
	copy(scalar_copy[:], scalar^)
	defer crypto.zero_explicit(&scalar_copy, size_of(scalar_copy))
	output := result^[:x25519.POINT_SIZE]
	x25519.scalarmult(output, scalar_copy[:], transmute([]u8)point^)
	if crypto.is_zero_constant_time(output) == 1 {
		return errors.fail(error, ERROR, .Not_Authentic, .Bytes, 2)
	}
	return x25519.POINT_SIZE
}

// ed25519_public_key gives the public key of a private key of 32 bytes (RFC 8032 5.1.5).
@(export, link_name = "ed25519_public_key")
ed25519_public_key :: proc "c" (secret: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	context = module_context()
	if !text_size_check(secret, ed25519.PRIVATE_KEY_SIZE, 1, error) {
		return ERROR
	}
	if len(result^) < ed25519.PUBLIC_KEY_SIZE {
		return ed25519.PUBLIC_KEY_SIZE
	}
	private_key: ed25519.Private_Key
	defer ed25519.private_key_clear(&private_key)
	ed25519.private_key_set_bytes(&private_key, transmute([]u8)secret^)
	public_key: ed25519.Public_Key
	ed25519.public_key_set_priv(&public_key, &private_key)
	ed25519.public_key_bytes(&public_key, result^[:ed25519.PUBLIC_KEY_SIZE])
	return ed25519.PUBLIC_KEY_SIZE
}

// ed25519_sign gives the signature of a message, 64 bytes, with a private key of 32 bytes (RFC 8032 5.1.6).
@(export, link_name = "ed25519_sign")
ed25519_sign :: proc "c" (secret, message: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	context = module_context()
	if !text_size_check(secret, ed25519.PRIVATE_KEY_SIZE, 1, error) {
		return ERROR
	}
	if len(result^) < ed25519.SIGNATURE_SIZE {
		return ed25519.SIGNATURE_SIZE
	}
	private_key: ed25519.Private_Key
	defer ed25519.private_key_clear(&private_key)
	ed25519.private_key_set_bytes(&private_key, transmute([]u8)secret^)
	ed25519.sign(&private_key, transmute([]u8)message^, result^[:ed25519.SIGNATURE_SIZE])
	return ed25519.SIGNATURE_SIZE
}

// ed25519_verify checks the signature of a message with a public key of 32 bytes (RFC 8032 5.1.7). The result is 0, or a negative number with an error record: Not_Authentic when the signature does not verify, Bad_Value for a public key that is not a point.
@(export, link_name = "ed25519_verify")
ed25519_verify :: proc "c" (public, message, signature: ^string, error: ^errors.Error_Record) -> i64 {
	context = module_context()
	if !text_size_check(public, ed25519.PUBLIC_KEY_SIZE, 1, error) || !text_size_check(signature, ed25519.SIGNATURE_SIZE, 3, error) {
		return ERROR
	}
	public_key: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&public_key, transmute([]u8)public^) {
		return errors.fail(error, ERROR, .Bad_Value, .Bytes, 1)
	}
	if !ed25519.verify(&public_key, transmute([]u8)message^, transmute([]u8)signature^) {
		return errors.fail(error, ERROR, .Not_Authentic, .Bytes, 3)
	}
	return 0
}
