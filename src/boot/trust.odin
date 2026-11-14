package boot

// The trusted boot of the boot program (docs/TRUSTED_BOOT.md): before the
// kernel starts, it verifies the description signature with the public key
// that it holds, then the hash of the kernel and of each module and
// resource of the boot image against the system description; then it asks
// the firmware to measure the description into the TPM. A failed check
// stops the boot with the failure on the boot display.
//
// What this proves depends on what verified the boot program itself. With
// Secure Boot off, nothing did: whoever can write the boot volume can
// replace the boot program, its public key and its checks. The checks then
// find a damaged or swapped file, not an attacker.

import "base:intrinsics"
import "base:runtime"
import "contract:blake3"
import info "contract:boot_info"
import "contract:system_description"
import "support:bootscreen"
import "support:cryptography/ed25519"

// The public key of the signing key, 32 bytes: the tool writes it before
// it builds the boot program (tools/kerneltool/system_description.odin).
system_public_key := #load(#config(SYSTEM_PUBLIC_KEY, "../../build/system_public_key.bin"))

// trust_check verifies the system description of the boot image and gives
// its bytes. It fills the trust record. It does not return when a check
// fails.
trust_check :: proc "contextless" (boot: ^info.Boot_Info, image: []u8) -> (description: []u8) {
	trust := &boot.trust
	start := u64(intrinsics.read_cycle_counter())
	if len(system_public_key) != system_description.PUBLIC_KEY_SIZE {
		trust_fail(boot, .Boot_Image, "the boot program holds no public key of 32 bytes")
	}
	copy(trust.public_key[:], system_public_key)
	trust.key_kind = trust.public_key == system_description.TEST_PUBLIC_KEY ? info.Signing_Key_Kind.Test : info.Signing_Key_Kind.Person
	signature: []u8
	found: bool
	description, signature, found = system_description.trust_resources(image)
	if !found {
		trust_fail(boot, .Boot_Image, "the boot image has no system description and description signature as its two last resources")
	}
	list, valid := system_description.entries(description)
	if !valid {
		trust_fail(boot, .Boot_Image, "the system description does not follow its format")
	}
	message := system_description.signed_message(description)
	if !signature_verifies(trust.public_key[:], message[:], signature) {
		trust_fail(boot, .Boot_Image, "the signature of the system description is wrong")
	}
	if kernel_result := system_description.kernel_check(description, kernel_file); kernel_result.fault != .None {
		check_fail(boot, .Kernel_Module, &kernel_result)
	}
	if image_result := system_description.image_check(description, image); image_result.fault != .None {
		check_fail(boot, .Boot_Image, &image_result)
	}
	trust.verifier = secure_boot_on() ? info.Verifier.Firmware_And_Boot_Program : info.Verifier.Boot_Program
	trust.description_hash = blake3.hash(description)
	trust.entry_count = u64(len(list))
	trust.check_cycles = u64(intrinsics.read_cycle_counter()) - start

	text: bootscreen.Text
	bootscreen.put(&text, "boot program: the system description has ")
	bootscreen.put_number(&text, trust.entry_count)
	bootscreen.put(&text, " entries, BLAKE3 ")
	print(string(text.bytes[:text.count]))
	hash_digits := system_description.hexadecimal(trust.description_hash)
	print(string(hash_digits[:]))
	print("\r\n")
	if trust.key_kind == .Test {
		print("boot program: the signature is from the test signing key, whose private key is published: this system is not trusted\r\n")
	} else {
		key_digits := system_description.hexadecimal(trust.public_key)
		print("boot program: the signature is from the key ")
		print(string(key_digits[:]))
		print("\r\n")
	}
	if trust.verifier == .Firmware_And_Boot_Program {
		print("boot program: verified by the firmware (Secure Boot), then by the boot program\r\n")
	} else {
		print("boot program: verified by the boot program, which the firmware did not verify\r\n")
	}
	print("boot program: the kernel and each module and resource have the hash of the system description\r\n")
	return
}

// signature_verifies checks an Ed25519 signature with the code that the
// module cryptography also runs (docs/CRYPTOGRAPHY.md). A public key that is
// not a point, or a point of small order, fails.
signature_verifies :: #force_no_inline proc "contextless" (public_key, message, signature: []u8) -> bool {
	// The code of the origin needs a context; a zero one, as in the module
	// cryptography: it allocates nothing here.
	context = runtime.Context{}
	key: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&key, public_key) {
		return false
	}
	return ed25519.verify(&key, message, signature)
}

// secure_boot_on reads the variable SecureBoot of the firmware: 1 when the
// firmware starts only a boot program that a key of its db signed.
secure_boot_on :: proc "contextless" () -> bool {
	name := [?]u16{'S', 'e', 'c', 'u', 'r', 'e', 'B', 'o', 'o', 't', 0}
	guid := EFI_GLOBAL_VARIABLE_GUID
	value: u8
	size := uint(1)
	if system.runtime_services.get_variable(raw_data(name[:]), &guid, nil, &size, &value) != 0 {
		return false
	}
	return size == 1 && value == 1
}

// check_fail writes the failure of a check of the hashes, with the expected
// and the found value, then stops.
check_fail :: proc "contextless" (boot: ^info.Boot_Info, step: bootscreen.Step, result: ^system_description.Check) -> ! {
	name := system_description.name_of(&result.name)
	sentence := system_description.fault_sentences[result.fault]
	shown: bootscreen.Text
	numbers: bootscreen.Text
	print("boot program: ")
	switch result.fault {
	case .None, .Not_Valid, .Image_Not_Valid:
		print(sentence)
		bootscreen.put(&shown, sentence)
	case .Count_Differs:
		print(sentence)
		bootscreen.put(&numbers, ": expected ")
		bootscreen.put_number(&numbers, result.expected_size)
		bootscreen.put(&numbers, ", found ")
		bootscreen.put_number(&numbers, result.found_size)
		print(string(numbers.bytes[:numbers.count]))
		bootscreen.put(&shown, "the boot image has another count of entries")
		bootscreen.put(&shown, string(numbers.bytes[:numbers.count]))
	case .Name_Differs, .Kind_Differs, .Outside_Image:
		print(name)
		print(": ")
		print(sentence)
		bootscreen.put(&shown, name)
		bootscreen.put(&shown, ": ")
		bootscreen.put(&shown, sentence)
	case .Size_Differs:
		print(name)
		print(" ")
		print(sentence)
		bootscreen.put(&numbers, ": expected ")
		bootscreen.put_number(&numbers, result.expected_size)
		bootscreen.put(&numbers, " bytes, found ")
		bootscreen.put_number(&numbers, result.found_size)
		bootscreen.put(&numbers, " bytes")
		print(string(numbers.bytes[:numbers.count]))
		bootscreen.put(&shown, name)
		bootscreen.put(&shown, ": wrong size")
		bootscreen.put(&shown, string(numbers.bytes[:numbers.count]))
	case .Hash_Differs, .Stated_Hash_Differs:
		expected := system_description.hexadecimal(result.expected_hash)
		found := system_description.hexadecimal(result.found_hash)
		print(name)
		print(" ")
		print(sentence)
		print(": expected ")
		print(string(expected[:]))
		print(", found ")
		print(string(found[:]))
		bootscreen.put(&shown, name)
		bootscreen.put(&shown, result.fault == .Hash_Differs ? ": wrong hash: expected " : ": wrong stated hash: expected ")
		bootscreen.put(&shown, string(expected[:16]))
		bootscreen.put(&shown, ", found ")
		bootscreen.put(&shown, string(found[:16]))
	}
	print("\r\n")
	// The card of the boot image names the file whole, also when the head
	// has no room for its whole sentence.
	#partial switch result.fault {
	case .Name_Differs, .Kind_Differs, .Outside_Image, .Size_Differs, .Hash_Differs, .Stated_Hash_Differs:
		display_data.failed_name = name
	}
	trust_stop(boot, step, string(shown.bytes[:shown.count]))
}

// trust_fail writes one failure on the log and on the boot display, then
// stops.
trust_fail :: proc "contextless" (boot: ^info.Boot_Info, step: bootscreen.Step, text: string) -> ! {
	print("boot program: ")
	print(text)
	print("\r\n")
	trust_stop(boot, step, text)
}

// trust_stop shows the failure and keeps it on the screen. The watchdog of
// the firmware restarts the machine after 5 minutes and starts the same
// boot program again: the boot program turns the watchdog off, so the
// failure stays until a person stops the machine.
trust_stop :: proc "contextless" (boot: ^info.Boot_Info, step: bootscreen.Step, text: string) -> ! {
	display(boot, text, .Failed, step)
	// After the draw, print writes on the serial port only (src/boot/main.odin).
	print("boot program: the boot display shows the failure\r\n")
	system.boot_services.set_watchdog_timer(0, 0, 0, nil)
	for {
		intrinsics.cpu_relax()
	}
}

// The commands of the TPM that the boot program sends (TPM 2.0 Library,
// Part 3): the read of one register in the SHA-256 bank.
TPM_ST_NO_SESSIONS :: 0x8001
TPM_CC_PCR_READ :: 0x0000_017E
TPM_ALG_SHA256 :: 0x000B
// TPM2_PCR_Read: tag, size, command code, one selection of 3 bytes.
TPM_PCR_READ_COMMAND_SIZE :: 2 + 4 + 4 + 4 + 2 + 1 + 3
// The registers that a selection of 3 bytes names: PCR 0 to 23.
TPM_SELECTION_SIZE :: 3

// The tries of the measure. A command of the TPM that the interface of the
// firmware does not finish in its time is reported as a device error; a
// slow interface can finish the next one. 4 tries, 0.5 s apart, add 1.5 s
// at most to a boot whose TPM refuses for good.
MEASURE_TRY_COUNT :: 4
MEASURE_TRY_WAIT_MICROSECONDS :: 500_000

// measure asks the firmware to extend the measure register with the
// SHA-256 hash of the system description, then reads the register back.
//
// The rule when it fails (docs/TRUSTED_BOOT.md, "The measure"): the boot
// continues, and the trust record, the boot display and the log say which
// state holds: no TPM, measured, refused, or measured with no read. No key
// is sealed to the measure yet, so a stop would protect nothing: a missing
// measure is visible to a party that reads PCR 11.
measure :: proc "contextless" (boot: ^info.Boot_Info, description: []u8) {
	trust := &boot.trust
	trust.measure_register = info.MEASURE_REGISTER
	guid := EFI_TCG2_GUID
	tpm: ^Efi_Tcg2_Protocol
	if system.boot_services.locate_protocol(&guid, nil, (^rawptr)(&tpm)) != 0 || tpm == nil {
		trust.measure = .No_Tpm
		print("boot program: the firmware has no TPM protocol: the system description is not measured\r\n")
		return
	}
	// The event data is the signed message: the event log names the
	// description by its BLAKE3 hash, the identity of the system.
	message := system_description.signed_message(description)
	event: [EFI_TCG2_EVENT_DATA_OFFSET + system_description.SIGNED_MESSAGE_SIZE]u8
	put_little_endian_u32(event[0:], u32(len(event)))
	put_little_endian_u32(event[4:], EFI_TCG2_EVENT_HEADER_SIZE)
	event[8] = EFI_TCG2_EVENT_HEADER_VERSION
	put_little_endian_u32(event[10:], u32(info.MEASURE_REGISTER))
	put_little_endian_u32(event[14:], TCG_EVENT_IPL)
	copy(event[EFI_TCG2_EVENT_DATA_OFFSET:], message[:])
	text: bootscreen.Text
	status: Efi_Status
	for attempt in 1 ..= MEASURE_TRY_COUNT {
		trust.measure_tries = u64(attempt)
		status = tpm.hash_log_extend_event(tpm, 0, u64(uintptr(raw_data(description))), u64(len(description)), raw_data(event[:]))
		if status == 0 {
			break
		}
		text.count = 0
		bootscreen.put(&text, "boot program: try ")
		bootscreen.put_number(&text, u64(attempt))
		bootscreen.put(&text, " of the measure: the firmware answered status ")
		bootscreen.put_hex(&text, u64(status), 16)
		print(string(text.bytes[:text.count]))
		print("\r\n")
		if attempt < MEASURE_TRY_COUNT {
			system.boot_services.stall(MEASURE_TRY_WAIT_MICROSECONDS)
		}
	}
	text.count = 0
	if status != 0 {
		trust.measure = .Refused
		trust.measure_status = u64(status)
		bootscreen.put(&text, "boot program: the TPM refused the measure of the system description: status ")
		bootscreen.put_hex(&text, u64(status), 16)
		print(string(text.bytes[:text.count]))
		print("\r\n")
		// Which part refuses: when a read through the same protocol fails
		// too, with no command at the TPM, the firmware has marked its TPM
		// as absent after an earlier error of its own.
		_, probe_status, probe_read := register_read(tpm, info.MEASURE_REGISTER)
		text.count = 0
		bootscreen.put(&text, "boot program: a read of PCR 11 through the same firmware: ")
		if probe_read {
			bootscreen.put(&text, "it works")
		} else {
			bootscreen.put(&text, "status ")
			bootscreen.put_hex(&text, probe_status, 16)
		}
		print(string(text.bytes[:text.count]))
		print("\r\n")
		return
	}
	if trust.measure_tries > 1 {
		bootscreen.put(&text, "boot program: the measure succeeded at try ")
		bootscreen.put_number(&text, trust.measure_tries)
		print(string(text.bytes[:text.count]))
		print("\r\n")
		text.count = 0
	}
	value, read_status, read := register_read(tpm, info.MEASURE_REGISTER)
	if !read {
		trust.measure = .Not_Read
		trust.measure_status = read_status
		bootscreen.put(&text, "boot program: the system description is measured, but the read of the register failed: ")
		bootscreen.put_hex(&text, read_status, 16)
		print(string(text.bytes[:text.count]))
		print("\r\n")
		return
	}
	trust.measure = .Measured
	trust.measure_value = value
	digits := system_description.hexadecimal(value)
	bootscreen.put(&text, "boot program: PCR ")
	bootscreen.put_number(&text, info.MEASURE_REGISTER)
	bootscreen.put(&text, " = ")
	print(string(text.bytes[:text.count]))
	print(string(digits[:]))
	print("\r\n")
}

// register_read reads one register of the SHA-256 bank with TPM2_PCR_Read,
// through the firmware. status is the status of the firmware or the
// response code of the TPM when read is false.
register_read :: proc "contextless" (tpm: ^Efi_Tcg2_Protocol, register: u64) -> (value: [32]u8, status: u64, read: bool) {
	command: [TPM_PCR_READ_COMMAND_SIZE]u8
	put_big_endian_u16(command[0:], TPM_ST_NO_SESSIONS)
	put_big_endian_u32(command[2:], TPM_PCR_READ_COMMAND_SIZE)
	put_big_endian_u32(command[6:], TPM_CC_PCR_READ)
	put_big_endian_u32(command[10:], 1) // One selection.
	put_big_endian_u16(command[14:], TPM_ALG_SHA256)
	command[16] = TPM_SELECTION_SIZE
	command[17 + register / 8] = u8(1) << (register % 8)
	response: [256]u8
	firmware_status := tpm.submit_command(tpm, u32(len(command)), raw_data(command[:]), u32(len(response)), raw_data(response[:]))
	if firmware_status != 0 {
		return {}, u64(firmware_status), false
	}
	// The response: tag (2 bytes), size (4), response code (4), the update
	// counter (4), the selections that the TPM read, then the digests.
	size := int(big_endian_u32(response[2:]))
	code := big_endian_u32(response[6:])
	if code != 0 {
		return {}, u64(code), false
	}
	if size > len(response) {
		return {}, 0, false
	}
	at := 14
	if at + 4 + 3 + TPM_SELECTION_SIZE + 4 + 2 + 32 > size || big_endian_u32(response[at:]) != 1 {
		return {}, 0, false
	}
	at += 4
	algorithm := big_endian_u16(response[at:])
	selection_size := int(response[at + 2])
	at += 3
	// A TPM with no SHA-256 bank, or that did not read the register, gives
	// an empty selection.
	if algorithm != TPM_ALG_SHA256 || selection_size != TPM_SELECTION_SIZE || response[at + int(register / 8)] & (u8(1) << (register % 8)) == 0 {
		return {}, 0, false
	}
	at += selection_size
	if big_endian_u32(response[at:]) != 1 || big_endian_u16(response[at + 4:]) != 32 {
		return {}, 0, false
	}
	at += 6
	copy(value[:], response[at:][:32])
	return value, 0, true
}

put_little_endian_u32 :: proc "contextless" (bytes: []u8, value: u32) {
	for index in 0 ..< 4 {
		bytes[index] = u8(value >> (8 * u32(index)))
	}
}

put_big_endian_u32 :: proc "contextless" (bytes: []u8, value: u32) {
	for index in 0 ..< 4 {
		bytes[index] = u8(value >> (8 * u32(3 - index)))
	}
}

put_big_endian_u16 :: proc "contextless" (bytes: []u8, value: u16) {
	bytes[0] = u8(value >> 8)
	bytes[1] = u8(value)
}

big_endian_u32 :: proc "contextless" (bytes: []u8) -> u32 {
	return u32(bytes[0]) << 24 | u32(bytes[1]) << 16 | u32(bytes[2]) << 8 | u32(bytes[3])
}

big_endian_u16 :: proc "contextless" (bytes: []u8) -> u16 {
	return u16(bytes[0]) << 8 | u16(bytes[1])
}

// The first serial port of a PC: the log of the machine tests reads it.
SERIAL_PORT :: 0x3F8
SERIAL_PORT_LINE_STATUS :: SERIAL_PORT + 5
SERIAL_PORT_CAN_TAKE_A_BYTE :: 0x20
// A port that never becomes ready (no serial port on this machine) must not
// hold the boot: after this count of reads the byte is dropped.
SERIAL_PORT_WAIT_LIMIT :: 100_000

serial_port_write_in_registers :: asm(port: u16, value: u8) -> (port_after: u16, value_after: u8) [
	port -> port_after   = %dx,
	value -> value_after = %al,
	#volatile,
	#clobber memory,
] {
	out
}

serial_port_read_in_registers :: asm(port: u16, before: u8) -> (port_after: u16, value: u8) [
	port -> port_after = %dx,
	before -> value    = %al,
	#volatile,
	#clobber memory,
] {
	in
}

// serial_port_print writes ASCII text on the serial port with the
// instructions of the processor, not through the console of the firmware:
// the text does not reach the screen.
serial_port_print :: proc "contextless" (text: string) {
	for index in 0 ..< len(text) {
		for _ in 0 ..< SERIAL_PORT_WAIT_LIMIT {
			_, status := serial_port_read_in_registers(SERIAL_PORT_LINE_STATUS, 0)
			if status & SERIAL_PORT_CAN_TAKE_A_BYTE != 0 {
				break
			}
		}
		_, _ = serial_port_write_in_registers(SERIAL_PORT, text[index])
	}
}
