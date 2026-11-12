// The unlock of a named principal (docs/PRINCIPALS.md): the program that
// keeps the record of a named principal in its private store, and asks for
// its passphrase in its window.
//
// A principal is a key pair: an Ed25519 key, to sign grants, and an X25519
// key, to unlock documents. Its record is the file "principal" of the store
// of this program: its name, its two public keys, and its two secret keys
// sealed with ChaCha20-Poly1305 under a key that Argon2id derives from the
// passphrase and a salt (support/principals). A wrong passphrase gives
// another key, and the seal does not open: no passphrase and no hash of it
// is kept or compared.
//
// The root service starts this program at boot. With no file it stops at
// once: the machine runs as principal 0 only, with no unlock. With a file
// it gives the public part of the record to the root service and asks for
// the passphrase; when the seal opens, it tells the root service, which
// starts the session of the principal, and it stops. The secret keys are
// erased at once: no part of the system uses them yet. The root service
// starts it again after a lock. To create a principal, the root service
// starts it with a name: the passphrase is typed two times, the keys are
// made from the generator of the program, and the session starts.
//
// The passphrase shows as dots. The seal by the TPM is not built: the
// strength of the record is the strength of the passphrase against
// Argon2id with 19 MiB and 2 passes, on a copy of the disk.
package unlock

import "base:intrinsics"
import "contract:errors"
import "contract:ring"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:principals"
import "support:random"
import "support:storage"
import "support:system"

// The cost record of the export argon2id of the module cryptography: the
// same fields, in the same order (modules/cryptography).
Argon2id_Cost :: struct {
	memory_kibibytes: i64,
	passes:           i64,
	lanes:            i64,
	tag_bytes:        i64,
}

foreign _ {
	argon2id :: proc "c" (password, salt: ^string, cost: ^Argon2id_Cost, work: ^system.Bytes_To_Change, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	seal_with_chacha20_poly1305 :: proc "c" (key, nonce, additional, text: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	open_with_chacha20_poly1305 :: proc "c" (key, nonce, additional, sealed: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	x25519 :: proc "c" (scalar, point: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
	ed25519_public_key :: proc "c" (secret: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 ---
}

WIDTH :: 520
HEIGHT :: 180
// The bound of an answer of the root service: it answers each command at
// once, so this bound only ends a wait for a service that stopped.
ROOT_ANSWER_LIMIT :: 10_000

records_now, records_before: [256]interface.Draw_Record
text_now, text_before: [4096]u8
drawing: interface.Window_Drawing

Mode :: enum {
	Unlock, // The passphrase of the principal of the file.
	Create_First, // The passphrase of a new principal.
	Create_Again, // The same passphrase again.
	Done,
}

mode: Mode
requests: ring.Ring
request_tag: u32
generator: random.Generator
client: storage.Client

name: [principals.NAME_LIMIT]u8
name_length: int
number: u64 // The number of the principal in the root service.
file: principals.Principal_File
file_bytes: [principals.FILE_SIZE]u8

typed: [principals.PASSPHRASE_LIMIT]u8
typed_count: int
first: [principals.PASSPHRASE_LIMIT]u8 // The first passphrase of a creation, until the second one.
first_count: int
message: string = ""
message_failed: bool
refusals: u64 // The wrong passphrases since the start.

// The blocks of Argon2id: 19 MiB, one memory object of this program.
work: system.Bytes_To_Change

// erase writes 0 over a secret with volatile stores, which the compiler
// cannot remove.
erase :: proc "contextless" (bytes: []u8) {
	for &item in bytes {
		intrinsics.volatile_store(&item, 0)
	}
}

the_name :: proc "contextless" () -> string {
	return string(name[:name_length])
}

// root_command sends a command of the principals to the root service and
// waits for its completion.
root_command :: proc "contextless" (kind: system.Root_Command, values: [7]u64) -> (completion: ring.Record, answered: bool) {
	request_tag += 1
	if !system.send(&requests.commands, ring.Record{kind = u32(kind), tag = request_tag, values = values}) {
		return {}, false
	}
	limit := system.time() + ROOT_ANSWER_LIMIT
	for {
		for record in system.receive(&requests.completions) {
			if record.tag == request_tag {
				return record, true
			}
		}
		wait: system.Wait
		system.wait_records(&wait, &requests.completions)
		if system.wait_end(&wait, limit) >= limit {
			return {}, false
		}
	}
}

// record_give gives the public part of the record to the root service, and
// keeps the number that it answers.
record_give :: proc "contextless" () -> bool {
	key := transmute([4]u64)file.signing_public_key
	packed := principals.name_pack(the_name())
	completion, answered := root_command(.Principal_Record, {key[0], key[1], key[2], key[3], packed[0], packed[1], packed[2]})
	if !answered || system.Status(completion.kind) != .Ok {
		system.log("unlock: the root service did not take the record of the principal \"", the_name(), "\": status ", u64(completion.kind))
		return false
	}
	number = completion.values[0]
	return true
}

// derive gives the key of the seal from a passphrase and the salt of the file.
derive :: proc "contextless" (passphrase: []u8, key: ^[principals.KEY_SIZE]u8) -> bool {
	password := string(passphrase)
	salt := string(file.salt[:])
	result := key^[:]
	error: errors.Error_Record
	cost := Argon2id_Cost {
		memory_kibibytes = principals.DERIVATION_MEMORY_KIBIBYTES,
		passes           = principals.DERIVATION_PASSES,
		lanes            = 1,
		tag_bytes        = principals.KEY_SIZE,
	}
	count := argon2id(&password, &salt, &cost, &work, &result, &error)
	if count != principals.KEY_SIZE {
		system.log("unlock: Argon2id refused the derivation: kind ", error.kind, ", argument ", error.argument)
		return false
	}
	return true
}

// public_keys_of gives the two public keys of the two secret keys.
public_keys_of :: proc "contextless" (secrets: ^[principals.SECRET_KEYS_SIZE]u8) -> (signing, unlocking: [principals.PUBLIC_KEY_SIZE]u8, ok: bool) {
	error: errors.Error_Record
	seed := string(secrets^[:32])
	signing_result := signing[:]
	if ed25519_public_key(&seed, &signing_result, &error) != 32 {
		return {}, {}, false
	}
	base_point: [32]u8
	base_point[0] = 9 // The base point of X25519 (RFC 7748, section 4.1).
	scalar := string(secrets^[32:])
	point := string(base_point[:])
	unlocking_result := unlocking[:]
	if x25519(&scalar, &point, &unlocking_result, &error) != 32 {
		return {}, {}, false
	}
	return signing, unlocking, true
}

// create makes a new principal: its keys, its file, its record in the root
// service, and its session.
create :: proc "contextless" () {
	secrets: [principals.SECRET_KEYS_SIZE]u8
	key: [principals.KEY_SIZE]u8
	defer erase(secrets[:])
	defer erase(key[:])
	error: errors.Error_Record
	// The keys come from the generator of this program, seeded by the root
	// service from the sources of the processor; a weak seed is refused.
	if !random.fill_for_a_key(&generator, secrets[:], .Processor, &error) || !random.fill_for_a_key(&generator, file.salt[:], .Processor, &error) || !random.fill_for_a_key(&generator, file.nonce[:], .Processor, &error) {
		system.log("unlock: the seed of this program is too weak for a key: no principal is created")
		message, message_failed = "the seed of the machine is too weak for a key", true
		return
	}
	ok: bool
	file.signing_public_key, file.unlock_public_key, ok = public_keys_of(&secrets)
	if !ok {
		message, message_failed = "the module cryptography refused the keys", true
		return
	}
	file.name, file.name_length = name, name_length
	started := system.time()
	if !derive(typed[:typed_count], &key) {
		message, message_failed = "the derivation of the key failed", true
		return
	}
	derived := system.time() - started
	principals.file_encode(&file, &file_bytes)
	key_text := string(key[:])
	nonce_text := string(file.nonce[:])
	additional := string(principals.file_additional_data(&file_bytes))
	text := string(secrets[:])
	sealed := file.sealed[:]
	if seal_with_chacha20_poly1305(&key_text, &nonce_text, &additional, &text, &sealed, &error) != principals.SEALED_SIZE {
		message, message_failed = "the seal of the keys failed", true
		return
	}
	principals.file_encode(&file, &file_bytes)
	if _, status := storage.write(&client, principals.FILE_OBJECT, file_bytes[:]); status != .Ok {
		system.log("unlock: the store did not keep the file of the principal: status ", u64(status))
		message, message_failed = "the store did not keep the principal", true
		return
	}
	if !record_give() {
		message, message_failed = "the root service did not take the record", true
		return
	}
	system.log("unlock: principal ", number, " \"", the_name(), "\" is created: its keys are sealed in the store of unlock under a key of Argon2id, 19456 KiB and 2 passes, derived in ", derived, " ms")
	session_start()
}

// passphrase_try opens the seal with the passphrase typed. A wrong passphrase gives
// another key: the open fails, and nothing is unlocked.
passphrase_try :: proc "contextless" () {
	secrets: [principals.SECRET_KEYS_SIZE]u8
	key: [principals.KEY_SIZE]u8
	defer erase(secrets[:])
	defer erase(key[:])
	if !derive(typed[:typed_count], &key) {
		message, message_failed = "the derivation of the key failed", true
		return
	}
	error: errors.Error_Record
	key_text := string(key[:])
	nonce_text := string(file.nonce[:])
	additional := string(principals.file_additional_data(&file_bytes))
	sealed := string(file.sealed[:])
	result := secrets[:]
	if open_with_chacha20_poly1305(&key_text, &nonce_text, &additional, &sealed, &result, &error) != principals.SECRET_KEYS_SIZE {
		refusals += 1
		system.log("unlock: the passphrase of principal ", number, " \"", the_name(), "\" is wrong: the seal does not open, nothing is unlocked (", refusals, " in all)")
		message, message_failed = "the passphrase is wrong: nothing is unlocked", true
		return
	}
	// The secret keys must be the keys of the record: a file whose public
	// part does not match its seal is refused.
	signing, unlocking, ok := public_keys_of(&secrets)
	if !ok || signing != file.signing_public_key || unlocking != file.unlock_public_key {
		system.log("unlock: the sealed keys of principal ", number, " do not match its public keys: nothing is unlocked")
		message, message_failed = "the record is not consistent: nothing is unlocked", true
		return
	}
	system.log("unlock: the passphrase of principal ", number, " \"", the_name(), "\" opens its seal; the secret keys are erased: nothing uses them yet")
	session_start()
}

session_start :: proc "contextless" () {
	completion, answered := root_command(.Principal_Unlock, {4 = number})
	if !answered || system.Status(completion.kind) != .Ok {
		system.log("unlock: the root service did not start the session of principal ", number, ": status ", u64(completion.kind))
		message, message_failed = "the root service did not start the session", true
		return
	}
	mode = .Done
}

draw :: proc "contextless" (window: ^display.Window) {
	if drawing.now.records == nil {
		drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	}
	frame := interface.window_frame_begin(&drawing, window)
	table := frame.table
	interface.draw_rectangle(table, 0, 0, WIDTH, HEIGHT, graphics.COLOR_BACKGROUND)
	x := interface.draw_text(table, 12, 12, mode == .Unlock ? "principal  " : "new principal  ", graphics.COLOR_DIM)
	interface.draw_text(table, x, 12, the_name(), graphics.COLOR_TEXT)
	prompt := "passphrase  "
	switch mode {
	case .Create_Again:
		prompt = "again  "
	case .Unlock, .Create_First, .Done:
	}
	x = interface.draw_text(table, 12, 48, prompt, graphics.COLOR_DIM)
	// One dot for each byte typed: the passphrase itself is never drawn.
	for index in 0 ..< typed_count {
		interface.draw_rectangle(table, x + 2 + index * 10, 54, 6, 6, graphics.COLOR_TEXT)
	}
	interface.draw_rectangle(table, x + 2 + typed_count * 10, 48, 2, 16, graphics.COLOR_TEXT)
	if message != "" {
		interface.draw_text(table, 12, 84, message, message_failed ? graphics.COLOR_FAILED : graphics.COLOR_PROGRAM)
	}
	interface.draw_text(table, 12, 116, "no TPM seal: the passphrase alone protects the keys", graphics.COLOR_DIM)
	interface.draw_text(table, 12, HEIGHT - 26, "enter: unlock; escape: clear", graphics.COLOR_DIM)
	interface.window_frame_end(&drawing, &frame, window)
}

// enter acts on the passphrase typed.
enter :: proc "contextless" (window: ^display.Window) {
	switch mode {
	case .Unlock:
		message, message_failed = "deriving the key", false
		draw(window)
		passphrase_try()
	case .Create_First:
		if problem := principals.passphrase_problem(typed[:typed_count]); problem != .None {
			message, message_failed = principals.passphrase_problem_sentences[problem], true
		} else {
			first_count = copy(first[:], typed[:typed_count])
			mode = .Create_Again
			message, message_failed = "type it again", false
		}
	case .Create_Again:
		if string(first[:first_count]) != string(typed[:typed_count]) {
			message, message_failed = "the two passphrases differ: type a new one", true
			mode = .Create_First
		} else {
			message, message_failed = "deriving the key", false
			draw(window)
			create()
			if mode != .Done {
				mode = .Create_First
			}
		}
		erase(first[:])
		first_count = 0
	case .Done:
	}
	erase(typed[:])
	typed_count = 0
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	// With no seed, each key is refused (create).
	if !random.generator_from_context(&generator, ctx) {
		system.log("unlock: the root service gave no random seed")
	}
	status: system.Status
	if requests, status = system.ring_open(ctx.handles[system.GRANT_ROOT]); status != .Ok {
		system.log("unlock: no ring to the root service")
		system.stop(1)
	}
	ok: bool
	if client, ok = storage.open(ctx); !ok {
		system.log("unlock: no store: no named principal can be kept")
		system.stop(1)
	}
	if ctx.values[principals.VALUE_CREATE] == 1 {
		name, name_length = principals.name_unpack({ctx.values[principals.VALUE_NAME], ctx.values[principals.VALUE_NAME + 1], ctx.values[principals.VALUE_NAME + 2]})
		if principals.name_problem(the_name()) != .None {
			system.log("unlock: the name of the new principal is refused")
			system.stop(1)
		}
		mode = .Create_First
		message = "type a passphrase of 8 bytes at least"
	} else {
		buffer: [principals.FILE_SIZE + 1]u8
		bytes, found, read_status := storage.read(&client, principals.FILE_OBJECT, buffer[:])
		if read_status == .Ok && !found {
			system.log("unlock: no named principal: the machine runs as principal 0, with no unlock")
			system.stop(0)
		}
		if read_status != .Ok {
			system.log("unlock: the store did not give the file of the principal: status ", u64(read_status))
			system.stop(1)
		}
		problem: principals.File_Problem
		file, file_bytes, problem = principals.file_decode(bytes)
		if problem != .None {
			system.log("unlock: the file of the principal is refused: ", principals.file_problem_sentences[problem])
			system.stop(1)
		}
		name, name_length = file.name, file.name_length
		if !record_give() {
			system.stop(1)
		}
		mode = .Unlock
		system.log("unlock: principal ", number, " \"", the_name(), "\" is locked: its passphrase opens its session")
	}
	// The blocks of Argon2id.
	memory, memory_status := system.memory_create(principals.DERIVATION_MEMORY_PAGES)
	address: rawptr
	if memory_status == .Ok {
		address, memory_status = system.memory_map(memory)
	}
	if memory_status != .Ok {
		system.log("unlock: no memory for the derivation of the key: status ", u64(memory_status))
		system.stop(1)
	}
	work = {bytes = ([^]u8)(address), count = 0, capacity = principals.DERIVATION_MEMORY_KIBIBYTES * 1024}
	window, opened := display.open(ctx, WIDTH, HEIGHT, "unlock")
	if !opened {
		system.stop(1)
	}
	for mode != .Done {
		draw(&window)
		wait: system.Wait
		display.wait_events(&wait, &window)
		system.wait_end(&wait)
		for event in display.next_event(&window) {
			if event.kind != .Key || !event.pressed {
				continue
			}
			switch {
			case event.code == display.KEY_ESCAPE:
				erase(typed[:])
				typed_count = 0
			case event.character == '\n':
				enter(&window)
			case event.character == 8:
				if typed_count > 0 {
					typed_count -= 1
					typed[typed_count] = 0
				}
			case event.character >= ' ' && event.character <= '~':
				if typed_count < len(typed) {
					typed[typed_count] = event.character
					typed_count += 1
				}
			}
			if mode == .Done {
				break
			}
		}
	}
	system.stop(0)
}
