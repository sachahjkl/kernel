package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"

// Secure Boot (docs/TRUSTED_BOOT.md, section 7): the firmware starts only a
// boot program that the firmware signing key signed.
//
// UEFI verifies Authenticode signatures with RSA keys and X.509
// certificates, not Ed25519. So the person who owns the machine has a second
// key: the firmware signing key, an RSA-2048 key and its certificate, in the
// folder of the signing key. Three programs of Nixpkgs do the work that the
// tool does not write itself:
//   openssl         makes the key and the certificate;
//   sbsign          (sbsigntool) signs the boot program;
//   virt-fw-vars    (python3Packages.virt-firmware) writes a variable store
//                   of the firmware with the certificate as PK, KEK and db,
//                   and Secure Boot on.
// With no SYSTEM_SIGNING_KEY, the build uses the test firmware signing key
// of resources/keys, whose private key is in the repository.

FIRMWARE_SIGNING_KEY_FILE_NAME :: "firmware_signing_key.pem"
FIRMWARE_CERTIFICATE_FILE_NAME :: "firmware_signing_key.crt"
TEST_FIRMWARE_SIGNING_KEY_FILE :: RESOURCE_FOLDER + "/keys/test_" + FIRMWARE_SIGNING_KEY_FILE_NAME
TEST_FIRMWARE_CERTIFICATE_FILE :: RESOURCE_FOLDER + "/keys/test_" + FIRMWARE_CERTIFICATE_FILE_NAME
// The boot program signed for Secure Boot. BOOT_PROGRAM stays the unsigned
// output of the link, which the repeated builds compare.
BOOT_PROGRAM_SIGNED :: BOOT_OBJECT_FOLDER + "/BOOTX64.signed.EFI"
// The variable store of the machine with Secure Boot on: OVMF_FULL_VARS
// with the certificate enrolled. machine_command copies it for each machine.
SECURE_BOOT_VARIABLES :: BUILD_FOLDER + "/ovmf_vars_secure_boot.fd"
// The owner of the enrolled certificates (SignatureOwner in the UEFI
// signature lists): a fixed identifier of this system, which the firmware
// stores and does not check.
SECURE_BOOT_OWNER :: "8a2f6c1e-5d3b-4e7a-9c0f-2b4d6e8a1c3f"
// The subject of a new certificate. It names the role, not a person.
FIRMWARE_CERTIFICATE_SUBJECT :: "/CN=firmware signing key of the system/"

Firmware_Signing_Key :: struct {
	key_path:         string,
	certificate_path: string,
	is_test:          bool,
}

// What the build does to the boot program of one volume for Secure Boot.
Firmware_Signature :: enum {
	None, // The boot program is not signed: a firmware with Secure Boot on refuses it.
	Signed,
	Signed_Then_Changed, // One byte of the signed boot program changes: the firmware refuses it.
}

// firmware_signing_key_find gives the firmware signing key of the build:
// the two files beside the private key that SYSTEM_SIGNING_KEY names, or
// the test pair.
firmware_signing_key_find :: proc() -> (key: Firmware_Signing_Key, ok: bool) {
	signing_key := os.get_env(SIGNING_KEY_VARIABLE, context.temp_allocator)
	if signing_key == "" {
		return {key_path = TEST_FIRMWARE_SIGNING_KEY_FILE, certificate_path = TEST_FIRMWARE_CERTIFICATE_FILE, is_test = true}, true
	}
	slash := strings.last_index_byte(signing_key, '/')
	folder := slash < 0 ? "." : signing_key[:max(slash, 1)]
	key = {
		key_path         = strings.concatenate({folder, "/", FIRMWARE_SIGNING_KEY_FILE_NAME}, context.temp_allocator),
		certificate_path = strings.concatenate({folder, "/", FIRMWARE_CERTIFICATE_FILE_NAME}, context.temp_allocator),
	}
	if !os.exists(key.key_path) || !os.exists(key.certificate_path) {
		fmt.eprintfln("kerneltool: %s and %s must be beside %s: run `kerneltool key new` for a new folder", key.key_path, key.certificate_path, signing_key)
		return {}, false
	}
	if path_inside_repository(key.key_path) {
		fmt.eprintfln("kerneltool: %s is inside the repository: the private key of the person who owns the machine stays outside it", key.key_path)
		return {}, false
	}
	if !private_key_file_check(key.key_path) {
		return {}, false
	}
	return key, true
}

// firmware_signing_key_new makes an RSA-2048 key and a self-signed
// certificate with openssl, in a folder that only its owner can open.
// openssl writes the private key with the mode 0600; the tool checks it.
// With test, it writes the test pair of the repository, once.
firmware_signing_key_new :: proc(folder: string, test: bool) -> bool {
	prefix := test ? "test_" : ""
	key_path := strings.concatenate({folder, "/", prefix, FIRMWARE_SIGNING_KEY_FILE_NAME}, context.temp_allocator)
	certificate_path := strings.concatenate({folder, "/", prefix, FIRMWARE_CERTIFICATE_FILE_NAME}, context.temp_allocator)
	if os.exists(key_path) || os.exists(certificate_path) {
		fmt.eprintfln("kerneltool: %s already holds a firmware signing key: a new key does not replace one", folder)
		return false
	}
	// -days 36500: the firmware does not check the dates of a db
	// certificate; a short life gives no protection here, only a failure of
	// the tools that do check it.
	run({"openssl", "req", "-new", "-x509", "-newkey", "rsa:2048", "-sha256", "-days", "36500", "-nodes", "-subj", FIRMWARE_CERTIFICATE_SUBJECT, "-keyout", key_path, "-out", certificate_path}) or_return
	if !test {
		if err := os.change_mode(key_path, os.perm(0o600)); err != nil {
			fmt.eprintfln("kerneltool: cannot make %s private: %v", key_path, err)
			return false
		}
		private_key_file_check(key_path) or_return
	}
	fmt.printfln("kerneltool: wrote %s and %s: the firmware signing key, for Secure Boot", key_path, certificate_path)
	return true
}

// boot_program_sign writes the signed copy of BOOT_PROGRAM, and changes one
// byte of it for a test that the firmware refuses it.
boot_program_sign :: proc(signature: Firmware_Signature) -> bool {
	key := firmware_signing_key_find() or_return
	_ = os.remove(BOOT_PROGRAM_SIGNED)
	run({"sbsign", "--key", key.key_path, "--cert", key.certificate_path, "--output", BOOT_PROGRAM_SIGNED, BOOT_PROGRAM}) or_return
	if signature == .Signed_Then_Changed {
		program := read_file(BOOT_PROGRAM_SIGNED) or_return
		// The middle of the file is in the boot image that the boot program
		// holds: a byte that the Authenticode hash covers. The signature is
		// at the end of the file.
		program[len(program) / 2] ~= 0x01
		if err := os.write_entire_file(BOOT_PROGRAM_SIGNED, program); err != nil {
			fmt.eprintfln("kerneltool: cannot write %s: %v", BOOT_PROGRAM_SIGNED, err)
			return false
		}
	}
	return true
}

// secure_boot_variables_write writes SECURE_BOOT_VARIABLES: the empty
// variable store of the firmware with Secure Boot, with the certificate of
// the firmware signing key as the platform key, the key exchange key and
// the one entry of db, and Secure Boot on. No key of another vendor is
// enrolled: the firmware starts only what this certificate signed.
secure_boot_variables_write :: proc() -> bool {
	key := firmware_signing_key_find() or_return
	template := os.get_env("OVMF_FULL_VARS", context.temp_allocator)
	if template == "" {
		fmt.eprintln("kerneltool: OVMF_FULL_VARS is not set. Use the development shell: nix develop")
		return false
	}
	_ = os.remove(SECURE_BOOT_VARIABLES)
	return run({"virt-fw-vars", "--input", template, "--output", SECURE_BOOT_VARIABLES, "--set-pk", SECURE_BOOT_OWNER, key.certificate_path, "--add-kek", SECURE_BOOT_OWNER, key.certificate_path, "--add-db", SECURE_BOOT_OWNER, key.certificate_path, "--secure-boot"})
}
