// The module `cryptography` as it ships, at work (docs/CRYPTOGRAPHY.md).
//
// This program imports the module through its import slots, as `agenda`
// imports `calendar`: each call is a direct call of an export. It runs the
// published vectors of each primitive through the exports, checks that a
// changed byte, or a point of small order, gives its error record and no
// byte of output, measures the speed of
// each primitive and the cost of one call of an export, and shows the hash
// of the module in the boot image: the hash names the code that ran.
//
// **What it is for.** A reader trusts a primitive of cryptography only when
// it gives the published answers. This program checks the
// [cryptography module](term:cryptography-module) that the system ships,
// through the same exports that the QUIC of the remote service calls, and
// names it by its hash, so the check is of that exact code.
//
// **What a reader sees.** Start it from the menu of the programs, or with
// `start("cryptography_vectors")` in the console. The window has one row
// for each primitive and its standard, passed or failed, then the speeds.
// The log gets one line for each primitive (`cryptography_vectors: <name>
// (<standard>): passed; a bad input is refused`), one line for each speed,
// the cost of one call of an export, and the summary with the BLAKE3 hash
// of the module.
//
// **Its grant**: **Image**: it reads the hash of the module
// `cryptography` in the boot image. The module itself comes through its
// imports, as for any program.
//
// **What it does not prove.** Vectors show that the code gives the right
// answers on those inputs. They do not show that it runs in constant time,
// or that it has no fault on other inputs. The speeds are measures of the
// host of the run.
package cryptography_vectors

import "contract:blake3"
import "contract:errors"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:system"

foreign _ {
	seal_with_chacha20_poly1305 :: proc "c" (key, nonce, additional, text: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	open_with_chacha20_poly1305 :: proc "c" (key, nonce, additional, sealed: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	seal_with_aes_128_gcm :: proc "c" (key, nonce, additional, text: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	open_with_aes_128_gcm :: proc "c" (key, nonce, additional, sealed: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	sha256 :: proc "c" (text: ^string, result: ^[]u8) -> i64 ---
	hmac_sha256 :: proc "c" (key, text: ^string, result: ^[]u8) -> i64 ---
	hkdf_sha256_extract :: proc "c" (salt, input: ^string, result: ^[]u8) -> i64 ---
	hkdf_sha256_expand :: proc "c" (key, info: ^string, length: i64, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	x25519 :: proc "c" (scalar, point: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	ed25519_public_key :: proc "c" (secret: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	ed25519_sign :: proc "c" (secret, message: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	ed25519_verify :: proc "c" (public, message, signature: ^string, error: ^errors.Error_Record) -> i64 ---
}

LINE :: interface.TABLE_LINE
WIDTH :: 960
HEIGHT :: 640
VECTOR_CAPACITY :: 16
SPEED_CAPACITY :: 8

Vector :: struct {
	name:     string,
	standard: string,
	passed:   bool,
	refused:  bool, // A changed byte, or a point of small order, was refused with its error kind, and no byte was given.
	checks:   bool, // The primitive checks a tag or a signature.
}

Speed :: struct {
	name:                string,
	bytes:               int, // The bytes of one call.
	nanoseconds_of_call: u64, // The mean of one call.
}

vectors: [VECTOR_CAPACITY]Vector
vector_count: int
speeds: [SPEED_CAPACITY]Speed
speed_count: int
module_hash: blake3.Hash
module_size: int
empty_call_nanoseconds: u64
done: bool

records_now, records_before: [768]interface.Draw_Record
text_now, text_before: [16384]u8
drawing: interface.Window_Drawing

// bytes_from_hex reads hexadecimal into a buffer of the caller.
bytes_from_hex :: proc "contextless" (buffer: []u8, text: string) -> string {
	value :: proc "contextless" (character: u8) -> u8 {
		switch character {
		case '0' ..= '9':
			return character - '0'
		case 'a' ..= 'f':
			return character - 'a' + 10
		}
		return 0
	}
	count := min(len(text) / 2, len(buffer))
	for index in 0 ..< count {
		buffer[index] = value(text[2 * index]) << 4 | value(text[2 * index + 1])
	}
	return string(buffer[:count])
}

same_as_hex :: proc "contextless" (bytes: []u8, text: string) -> bool {
	expected: [256]u8
	return len(text) == 2 * len(bytes) && bytes_from_hex(expected[:], text) == string(bytes)
}

record_vector :: proc "contextless" (name, standard: string, passed: bool, checks := false, refused := false) {
	vectors[vector_count] = {name = name, standard = standard, passed = passed, checks = checks, refused = refused}
	vector_count += 1
	system.log("cryptography_vectors: ", name, " (", standard, "): ", passed ? "passed" : "FAILED", checks ? (refused ? "; a bad input is refused with no byte given" : "; a bad input was NOT refused") : "")
}

// no_byte_given says that a refused open left no byte of the text: the
// module erases what it wrote.
no_byte_given :: proc "contextless" (output: []u8) -> bool {
	for byte in output {
		if byte != 0 {
			return false
		}
	}
	return true
}

SUNSCREEN :: "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."

vectors_run :: proc "contextless" () {
	key_buffer, nonce_buffer, additional_buffer, other_buffer: [128]u8
	output: [256]u8
	opened: [256]u8
	result := output[:]
	error: errors.Error_Record

	// ChaCha20-Poly1305, RFC 8439 2.8.2.
	{
		key := bytes_from_hex(key_buffer[:], "808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
		nonce := bytes_from_hex(nonce_buffer[:], "070000004041424344454647")
		additional := bytes_from_hex(additional_buffer[:], "50515253c0c1c2c3c4c5c6c7")
		text := SUNSCREEN
		count := seal_with_chacha20_poly1305(&key, &nonce, &additional, &text, &result, &error)
		passed := count == i64(len(SUNSCREEN) + 16) && same_as_hex(output[:16], "d31a8d34648e60db7b86afbc53ef7ec2") && same_as_hex(output[len(SUNSCREEN):][:16], "1ae10b594f09e26a7e902ecbd0600691")
		sealed := string(output[:count])
		opened_result := opened[:]
		passed &&= open_with_chacha20_poly1305(&key, &nonce, &additional, &sealed, &opened_result, &error) == i64(len(SUNSCREEN)) && string(opened[:len(SUNSCREEN)]) == SUNSCREEN
		output[5] ~= 1
		refused := open_with_chacha20_poly1305(&key, &nonce, &additional, &sealed, &opened_result, &error) < 0 && error.kind == i64(errors.Kind.Not_Authentic) && no_byte_given(opened[:len(SUNSCREEN)])
		record_vector("ChaCha20-Poly1305", "RFC 8439 2.8.2", passed, true, refused)
	}
	// AES-128-GCM, the test case 4 of the GCM specification.
	{
		key := bytes_from_hex(key_buffer[:], "feffe9928665731c6d6a8f9467308308")
		nonce := bytes_from_hex(nonce_buffer[:], "cafebabefacedbaddecaf888")
		additional := bytes_from_hex(additional_buffer[:], "feedfacedeadbeeffeedfacedeadbeefabaddad2")
		text := bytes_from_hex(other_buffer[:], "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b39")
		count := seal_with_aes_128_gcm(&key, &nonce, &additional, &text, &result, &error)
		passed := count == 76 && same_as_hex(output[:16], "42831ec2217774244b7221b784d0d49c") && same_as_hex(output[60:76], "5bc94fbc3221a5db94fae95ae7121a47")
		sealed := string(output[:count])
		opened_result := opened[:]
		passed &&= open_with_aes_128_gcm(&key, &nonce, &additional, &sealed, &opened_result, &error) == 60 && string(opened[:60]) == text
		output[70] ~= 1
		refused := open_with_aes_128_gcm(&key, &nonce, &additional, &sealed, &opened_result, &error) < 0 && error.kind == i64(errors.Kind.Not_Authentic) && no_byte_given(opened[:60])
		record_vector("AES-128-GCM", "GCM test case 4", passed, true, refused)
	}
	// SHA-256, FIPS 180-4.
	{
		text := "abc"
		passed := sha256(&text, &result) == 32 && same_as_hex(output[:32], "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
		record_vector("SHA-256", "FIPS 180-4", passed)
	}
	// HMAC-SHA-256, RFC 4231 test case 2.
	{
		key := "Jefe"
		text := "what do ya want for nothing?"
		passed := hmac_sha256(&key, &text, &result) == 32 && same_as_hex(output[:32], "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
		record_vector("HMAC-SHA-256", "RFC 4231 2", passed)
	}
	// HKDF-SHA-256, RFC 5869 A.1.
	{
		salt := bytes_from_hex(key_buffer[:], "000102030405060708090a0b0c")
		input := bytes_from_hex(nonce_buffer[:], "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
		passed := hkdf_sha256_extract(&salt, &input, &result) == 32 && same_as_hex(output[:32], "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")
		pseudorandom := string(bytes_from_hex(other_buffer[:], "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"))
		info := bytes_from_hex(additional_buffer[:], "f0f1f2f3f4f5f6f7f8f9")
		passed &&= hkdf_sha256_expand(&pseudorandom, &info, 42, &result, &error) == 42 && same_as_hex(output[:42], "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
		record_vector("HKDF-SHA-256", "RFC 5869 A.1", passed)
	}
	// X25519, RFC 7748 5.2 and 6.1; the point 1, of small order, gives
	// Bad_Value: its shared secret would be 32 zero bytes.
	{
		scalar := bytes_from_hex(key_buffer[:], "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4")
		point := bytes_from_hex(nonce_buffer[:], "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")
		passed := x25519(&scalar, &point, &result, &error) == 32 && same_as_hex(output[:32], "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")
		alice := bytes_from_hex(key_buffer[:], "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
		bob_public := bytes_from_hex(nonce_buffer[:], "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
		passed &&= x25519(&alice, &bob_public, &result, &error) == 32 && same_as_hex(output[:32], "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
		zero_point := bytes_from_hex(nonce_buffer[:], "0100000000000000000000000000000000000000000000000000000000000000")
		output[0] = 0xA5
		refused := x25519(&alice, &zero_point, &result, &error) < 0 && error.kind == i64(errors.Kind.Bad_Value) && output[0] == 0xA5
		record_vector("X25519", "RFC 7748 5.2, 6.1", passed, true, refused)
	}
	// Ed25519, RFC 8032 7.1 test 1 (an empty message) and test 2; a changed
	// signature gives Not_Authentic.
	{
		secret := bytes_from_hex(key_buffer[:], "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
		message := ""
		passed := ed25519_public_key(&secret, &result, &error) == 32 && same_as_hex(output[:32], "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
		public := string(bytes_from_hex(nonce_buffer[:], "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"))
		passed &&= ed25519_sign(&secret, &message, &result, &error) == 64 && same_as_hex(output[:64], "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
		signature := string(output[:64])
		passed &&= ed25519_verify(&public, &message, &signature, &error) == 0
		output[40] ~= 1
		refused := ed25519_verify(&public, &message, &signature, &error) < 0 && error.kind == i64(errors.Kind.Not_Authentic)
		record_vector("Ed25519", "RFC 8032 7.1 test 1", passed, true, refused)
	}
	{
		secret := bytes_from_hex(key_buffer[:], "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
		message := bytes_from_hex(additional_buffer[:], "72")
		passed := ed25519_public_key(&secret, &result, &error) == 32 && same_as_hex(output[:32], "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")
		public := string(bytes_from_hex(nonce_buffer[:], "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"))
		passed &&= ed25519_sign(&secret, &message, &result, &error) == 64 && same_as_hex(output[:64], "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00")
		signature := string(output[:64])
		passed &&= ed25519_verify(&public, &message, &signature, &error) == 0
		output[1] ~= 1
		refused := ed25519_verify(&public, &message, &signature, &error) < 0 && error.kind == i64(errors.Kind.Not_Authentic)
		record_vector("Ed25519", "RFC 8032 7.1 test 2", passed, true, refused)
	}
}

// speed_measure gives the mean nanoseconds of one call over 100 calls of
// work, after one call that warms the caches.
speeds_run :: proc "contextless" () {
	key_bytes: [32]u8
	nonce_bytes: [12]u8
	packet: [1200]u8
	output: [1300]u8
	result := output[:]
	error: errors.Error_Record
	key, nonce, empty := string(key_bytes[:]), string(nonce_bytes[:]), ""
	packet_text := string(packet[:])
	short_key := string(key_bytes[:16])
	ROUNDS :: 100
	measure :: proc "contextless" (name: string, bytes: int, start: u64) {
		speeds[speed_count] = {name = name, bytes = bytes, nanoseconds_of_call = (system.nanoseconds() - start) / ROUNDS}
		speed_count += 1
	}
	// The cost of a call of an export: an export that does nothing, the
	// smallest one (sha256 of nothing into a buffer that is too small).
	small: []u8
	start := system.nanoseconds()
	for _ in 0 ..< ROUNDS {
		sha256(&empty, &small)
	}
	empty_call_nanoseconds = (system.nanoseconds() - start) / ROUNDS
	seal_with_chacha20_poly1305(&key, &nonce, &empty, &packet_text, &result, &error)
	start = system.nanoseconds()
	for _ in 0 ..< ROUNDS {
		seal_with_chacha20_poly1305(&key, &nonce, &empty, &packet_text, &result, &error)
	}
	measure("seal ChaCha20-Poly1305", len(packet), start)
	start = system.nanoseconds()
	for _ in 0 ..< ROUNDS {
		seal_with_aes_128_gcm(&short_key, &nonce, &empty, &packet_text, &result, &error)
	}
	measure("seal AES-128-GCM", len(packet), start)
	start = system.nanoseconds()
	for _ in 0 ..< ROUNDS {
		sha256(&packet_text, &result)
	}
	measure("SHA-256", len(packet), start)
	start = system.nanoseconds()
	for _ in 0 ..< ROUNDS {
		hkdf_sha256_expand(&key, &empty, 32, &result, &error)
	}
	measure("HKDF expand, 32 bytes", 32, start)
	key_bytes[0] = 9
	start = system.nanoseconds()
	for _ in 0 ..< ROUNDS {
		x25519(&key, &key, &result, &error)
	}
	measure("X25519", 32, start)
	start = system.nanoseconds()
	for _ in 0 ..< ROUNDS {
		ed25519_sign(&key, &key, &result, &error)
	}
	measure("Ed25519 sign, 32 bytes", 32, start)
	signature := string(output[:64])
	public_output: [32]u8
	public_result := public_output[:]
	ed25519_public_key(&key, &public_result, &error)
	public := string(public_output[:])
	start = system.nanoseconds()
	for _ in 0 ..< ROUNDS {
		ed25519_verify(&public, &key, &signature, &error)
	}
	measure("Ed25519 verify, 32 bytes", 32, start)
	for speed in speeds[:speed_count] {
		system.log("cryptography_vectors: ", speed.name, ": ", speed.nanoseconds_of_call, " ns for ", u64(speed.bytes), " bytes, ", u64(speed.bytes) * 1000 / max(speed.nanoseconds_of_call, 1), " MB/s")
	}
	system.log("cryptography_vectors: one call of an export of the module, through its import slot: ", empty_call_nanoseconds, " ns")
}

hash_text :: proc "contextless" (builder: ^interface.Text_Builder, bytes: []u8) -> string {
	digits := "0123456789abcdef"
	builder.count = 0
	for byte in bytes {
		pair := [2]u8{digits[byte >> 4], digits[byte & 15]}
		interface.text_put(builder, string(pair[:]))
	}
	return interface.text_of(builder)
}

draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_begin(&drawing, window)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	builder: interface.Text_Builder
	content := interface.card(&frame, {8, 8, WIDTH - 16, 100}, "THE MODULE", "cryptography: Odin core:crypto dev-2026-05, taken with a proof of origin", graphics.COLOR_KERNEL)
	column := interface.column_of(content)
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "BLAKE3", hash_text(&builder, module_hash[:]), graphics.COLOR_TEXT, 120)
	builder.count = 0
	interface.text_put_number(&builder, u64(module_size))
	interface.text_put(&builder, " bytes; one call of an export: ")
	interface.text_put_number(&builder, empty_call_nanoseconds)
	interface.text_put(&builder, " ns")
	interface.label_value_line(&frame, interface.column_take(&column, LINE), "size", interface.text_of(&builder), graphics.COLOR_TEXT, 120)

	content = interface.card(&frame, {8, 116, WIDTH - 16, 276}, "THE VECTORS", "through the exports of the module, live", graphics.COLOR_PROGRAM)
	column = interface.column_of(content)
	cells: [4]interface.Area
	sizes := [4]interface.Size{interface.characters(20), interface.characters(22), interface.characters(8), interface.share()}
	interface.row_split(interface.column_take(&column, LINE), sizes[:], cells[:], 16)
	interface.table_header(&frame, cells[:], {"primitive", "standard", "vector", "a bad input"}, {.Left, .Left, .Left, .Left})
	for vector, index in vectors[:vector_count] {
		line := interface.column_take(&column, LINE)
		interface.table_band(&frame, {line.x - 8, line.y, line.width + 16, line.height}, index)
		interface.row_split(line, sizes[:], cells[:], 16)
		interface.cell_text(&frame, cells[0], vector.name, graphics.COLOR_TEXT)
		interface.cell_text(&frame, cells[1], vector.standard, graphics.COLOR_DIM)
		interface.cell_text(&frame, cells[2], vector.passed ? "passed" : "FAILED", vector.passed ? graphics.COLOR_PROGRAM : graphics.COLOR_FAILED)
		if vector.checks {
			interface.cell_text(&frame, cells[3], vector.refused ? "refused, no byte given" : "NOT refused", vector.refused ? graphics.COLOR_PROGRAM : graphics.COLOR_FAILED)
		}
	}

	content = interface.card(&frame, {8, 400, WIDTH - 16, HEIGHT - 408}, "THE SPEEDS", "the mean of 100 calls, system.nanoseconds", graphics.COLOR_MACHINE)
	column = interface.column_of(content)
	most: u64 = 1
	for speed in speeds[:speed_count] {
		most = max(most, speed.nanoseconds_of_call)
	}
	speed_sizes := [4]interface.Size{interface.characters(26), interface.share(), interface.characters(12), interface.characters(14)}
	interface.row_split(interface.column_take(&column, LINE), speed_sizes[:], cells[:], 16)
	interface.table_header(&frame, cells[:], {"call", "time of one call", "", "in one second"}, {.Left, .Left, .Right, .Right})
	for speed, index in speeds[:speed_count] {
		line := interface.column_take(&column, LINE)
		interface.table_band(&frame, {line.x - 8, line.y, line.width + 16, line.height}, index)
		interface.row_split(line, speed_sizes[:], cells[:], 16)
		interface.cell_text(&frame, cells[0], speed.name, graphics.COLOR_TEXT)
		interface.bar(&frame, {cells[1].x, cells[1].y + 8, cells[1].width, 8}, speed.nanoseconds_of_call, most, graphics.COLOR_MACHINE)
		builder.count = 0
		interface.text_put_number(&builder, speed.nanoseconds_of_call)
		interface.text_put(&builder, " ns")
		interface.cell_text(&frame, cells[2], interface.text_of(&builder), graphics.COLOR_TEXT, .Right)
		// Bytes in one second for a text to seal or hash; calls in one
		// second for an operation on a key, whose speed is not a rate of bytes.
		builder.count = 0
		if speed.bytes >= 1000 {
			interface.text_put_number(&builder, u64(speed.bytes) * 1000 / max(speed.nanoseconds_of_call, 1))
			interface.text_put(&builder, " MB")
		} else {
			interface.text_put_number(&builder, 1_000_000_000 / max(speed.nanoseconds_of_call, 1))
			interface.text_put(&builder, " calls")
		}
		interface.cell_text(&frame, cells[3], interface.text_of(&builder), graphics.COLOR_TEXT, .Right)
	}
	interface.window_frame_end(&drawing, &frame, window)
}

// entry runs the vectors of each primitive, the refused inputs, the
// measures of speed and of one call, reads the hash of the module, writes
// the lines on the log, then keeps the window open until the program is
// stopped. With no window, it stops with the code 1.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "cryptography_vectors")
	if !ok {
		system.stop(1)
	}
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	if address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {}); status == .Ok {
		image := ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
		file := system.image_find(image, "cryptography")
		module_hash = blake3.hash(file)
		module_size = len(file)
	}
	vectors_run()
	draw(&window)
	speeds_run()
	failed := 0
	for vector in vectors[:vector_count] {
		if !vector.passed || (vector.checks && !vector.refused) {
			failed += 1
		}
	}
	hash: interface.Text_Builder
	system.log("cryptography_vectors: the module cryptography, BLAKE3 ", hash_text(&hash, module_hash[:16]), "...: ", u64(vector_count - failed), " of ", u64(vector_count), " vectors passed")
	done = true
	for {
		draw(&window)
		display.wait(&window, system.time() + 1000)
		interface.window_events(&drawing, &window)
	}
}
