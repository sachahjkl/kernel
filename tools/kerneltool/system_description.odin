package kerneltool

import "contract:blake3"
import info "contract:boot_info"
import "contract:system_description"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import crypto "support:cryptography/compatibility_crypto"
import "support:cryptography/ed25519"
import "support:cryptography/sha2"

// The system description and its signature (docs/TRUSTED_BOOT.md).
//
// The build writes one boot image without a description
// (build_boot_image). For each boot volume, this file writes a copy of it
// with two more resources at the end: the system description of the kernel
// and of each file of that image, and its description signature, made with
// the signing key. The boot program holds the public key of the same key.
//
// The signing key is the file that SYSTEM_SIGNING_KEY names: the private
// key of the person who owns the machine, outside the repository. With no
// such variable, the build signs with the test signing key of
// resources/keys, whose private key is published: the machine then says
// that it is not trusted. The private key never goes into the boot volume:
// only the public key and the signature do.

SIGNING_KEY_VARIABLE :: "SYSTEM_SIGNING_KEY"
TEST_SIGNING_KEY_FILE :: RESOURCE_FOLDER + "/keys/test_signing_key"
// The public key of the build, 32 bytes, for the boot program (#load).
SYSTEM_PUBLIC_KEY_FILE :: BUILD_FOLDER + "/system_public_key.bin"
SIGNING_KEY_FILE_NAME :: "signing_key"
SIGNING_KEY_PUBLIC_SUFFIX :: ".public"
SIGNING_KEY_SIZE :: 32

Signing_Key :: struct {
	private_key: ed25519.Private_Key,
	public_key:  [system_description.PUBLIC_KEY_SIZE]u8,
	is_test:     bool, // The test signing key: its private key is published.
	path:        string,
}

// A change of the boot image of one volume, for a test of a failure or of
// the measure. The zero value changes nothing.
Image_Change :: struct {
	// One byte of this module changes after the description is made: the
	// boot program must refuse the volume.
	module_changed_after_description:  string,
	// One byte of this module changes before the description is made: it is
	// another system, signed, whose measure must differ.
	module_changed_before_description: string,
	// One bit of the description signature changes: the boot program must
	// refuse the volume.
	signature_changed:                 bool,
}

// signed_image_path gives the boot image of one boot volume.
signed_image_path :: proc(volume_path: string) -> string {
	return strings.concatenate({strings.trim_suffix(volume_path, ".img"), ".image"}, context.temp_allocator)
}

// signing_key_said: the build prints once which key signs.
signing_key_said := false

// signing_key_read reads the signing key of the build.
signing_key_read :: proc() -> (key: Signing_Key, ok: bool) {
	path := os.get_env(SIGNING_KEY_VARIABLE, context.temp_allocator)
	if path == "" {
		path = TEST_SIGNING_KEY_FILE
	} else if path_inside_repository(path) {
		fmt.eprintfln("kerneltool: %s names %s, inside the repository: the private key of the person who owns the machine stays outside it", SIGNING_KEY_VARIABLE, path)
		return
	}
	key.path = path
	seed := signing_key_file_read(path) or_return
	if !ed25519.private_key_set_bytes(&key.private_key, seed[:]) {
		fmt.eprintfln("kerneltool: %s is not an Ed25519 private key", path)
		return
	}
	ed25519.private_key_public_bytes(&key.private_key, key.public_key[:])
	key.is_test = key.public_key == system_description.TEST_PUBLIC_KEY
	if path == TEST_SIGNING_KEY_FILE && !key.is_test {
		fmt.eprintfln("kerneltool: %s does not give the public key of the test signing key (contract/system_description)", path)
		return
	}
	if !signing_key_said {
		signing_key_said = true
		digits := system_description.hexadecimal(key.public_key)
		if key.is_test {
			fmt.printfln("kerneltool: the system is signed with the TEST signing key (%s): its private key is published, and the machine says that it is not trusted. Set %s to the private key of the person who owns the machine (`kerneltool key new <folder>`).", path, SIGNING_KEY_VARIABLE)
		} else {
			fmt.printfln("kerneltool: the system is signed with the key of %s, public key %s", path, string(digits[:]))
		}
	}
	return key, true
}

// signing_key_file_read reads a key file: 64 hexadecimal digits, then an
// end of line.
signing_key_file_read :: proc(path: string) -> (bytes: [SIGNING_KEY_SIZE]u8, ok: bool) {
	data := read_file(path) or_return
	text := strings.trim_space(string(data))
	if len(text) != 2 * SIGNING_KEY_SIZE {
		fmt.eprintfln("kerneltool: %s must hold 64 hexadecimal digits; it holds %d characters", path, len(text))
		return
	}
	for index in 0 ..< SIGNING_KEY_SIZE {
		high, high_valid := signing_key_digit(text[2 * index])
		low, low_valid := signing_key_digit(text[2 * index + 1])
		if !high_valid || !low_valid {
			fmt.eprintfln("kerneltool: %s must hold hexadecimal digits only", path)
			return
		}
		bytes[index] = high << 4 | low
	}
	return bytes, true
}

signing_key_digit :: proc(character: u8) -> (value: u8, valid: bool) {
	switch character {
	case '0' ..= '9':
		return character - '0', true
	case 'a' ..= 'f':
		return character - 'a' + 10, true
	case 'A' ..= 'F':
		return character - 'A' + 10, true
	}
	return 0, false
}

// path_inside_repository says if a path is in the folder of the repository,
// where a commit or a build can take it. The path can name a file or a
// folder that does not exist yet: its nearest folder that exists decides.
path_inside_repository :: proc(path: string) -> bool {
	repository, repository_error := os.get_working_directory(context.temp_allocator)
	if repository_error != nil {
		return true // Not known: refused.
	}
	existing := path
	for !os.exists(existing) {
		slash := strings.last_index_byte(existing, '/')
		if slash < 0 {
			existing = "." // A relative name: in the working directory.
			break
		}
		if slash == 0 {
			existing = "/"
			break
		}
		existing = existing[:slash]
	}
	absolute, absolute_error := os.get_absolute_path(existing, context.temp_allocator)
	if absolute_error != nil {
		return true // Not known: refused.
	}
	return absolute == repository || strings.has_prefix(absolute, strings.concatenate({repository, "/"}, context.temp_allocator))
}

// boot_image_signed_write writes the boot image of one boot volume: the
// image of the build at base_path with, as its two last resources, the
// system description of kernel_name and of each file of the image, and its
// description signature. The tool checks the result with the code of the
// boot program before it writes it.
boot_image_signed_write :: proc(base_path, kernel_name, output_path: string, change: Image_Change) -> bool {
	base := read_file(base_path) or_return
	modules, resources, valid := info.image_tables(base)
	if !valid {
		fmt.eprintfln("kerneltool: %s is not a boot image", base_path)
		return false
	}
	files := make([dynamic]Image_File, context.temp_allocator)
	for &entry in modules {
		bytes, inside := info.image_entry_bytes(base, &entry)
		if !inside {
			fmt.eprintfln("kerneltool: an entry of %s points outside it", base_path)
			return false
		}
		append(&files, Image_File{name = strings.clone(system_description.name_of(&entry.name), context.temp_allocator), file = bytes})
	}
	module_count := len(files)
	for &entry in resources {
		bytes, inside := info.image_entry_bytes(base, &entry)
		if !inside {
			fmt.eprintfln("kerneltool: an entry of %s points outside it", base_path)
			return false
		}
		append(&files, Image_File{name = strings.clone(system_description.name_of(&entry.name), context.temp_allocator), file = bytes})
	}
	if change.module_changed_before_description != "" {
		image_file_change(files[:module_count], change.module_changed_before_description) or_return
	}
	kernel := read_file(module_path(kernel_name)) or_return

	description := make([dynamic]u8, context.temp_allocator)
	header := system_description.Header{magic = system_description.MAGIC, version = system_description.VERSION, entry_count = u32(1 + len(files))}
	append(&description, ..mem.ptr_to_bytes(&header))
	kernel_entry := description_entry(kernel_name, .Kernel, kernel)
	append(&description, ..mem.ptr_to_bytes(&kernel_entry))
	for item, index in files {
		kind := index < module_count ? system_description.Entry_Kind.Module : system_description.Entry_Kind.Resource
		entry := description_entry(item.name, kind, item.file)
		append(&description, ..mem.ptr_to_bytes(&entry))
	}
	if _, description_valid := system_description.entries(description[:]); !description_valid {
		fmt.eprintfln("kerneltool: the system description of %s does not follow its format", output_path)
		return false
	}

	key := signing_key_read() or_return
	message := system_description.signed_message(description[:])
	signature: [system_description.SIGNATURE_SIZE]u8
	ed25519.sign(&key.private_key, message[:], signature[:])
	public_key: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&public_key, key.public_key[:]) || !ed25519.verify(&public_key, message[:], signature[:]) {
		fmt.eprintfln("kerneltool: the signature of the system description of %s does not verify", output_path)
		return false
	}
	if change.signature_changed {
		signature[17] ~= 0x04
	}
	if change.module_changed_after_description != "" {
		image_file_change(files[:module_count], change.module_changed_after_description) or_return
	}
	append(&files, Image_File{name = system_description.RESOURCE_DESCRIPTION, file = description[:]}, Image_File{name = system_description.RESOURCE_SIGNATURE, file = signature[:]})
	image := boot_image_encode(files[:], module_count)

	// The checks of the boot program, on the host: a fault of the format is
	// found here, and a test volume fails for the reason that it is made for.
	expected := change.module_changed_after_description != "" ? system_description.Check_Fault.Hash_Differs : system_description.Check_Fault.None
	written_description, _, found := system_description.trust_resources(image)
	if !found || system_description.kernel_check(written_description, kernel).fault != .None || system_description.image_check(written_description, image).fault != expected {
		fmt.eprintfln("kerneltool: the boot image %s does not pass the checks of the boot program as it must", output_path)
		return false
	}
	if err := os.write_entire_file(output_path, image); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", output_path, err)
		return false
	}
	if err := os.write_entire_file(SYSTEM_PUBLIC_KEY_FILE, key.public_key[:]); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", SYSTEM_PUBLIC_KEY_FILE, err)
		return false
	}
	return true
}

// description_entry gives the entry of one file in the system description.
description_entry :: proc(name: string, kind: system_description.Entry_Kind, file: []u8) -> (entry: system_description.Entry) {
	copy(entry.name[:system_description.NAME_SIZE - 1], name)
	entry.kind = kind
	entry.size = u64(len(file))
	entry.hash = blake3.hash(file)
	return
}

// image_file_change changes the last byte of the module with this name, in
// a copy of its bytes.
image_file_change :: proc(files: []Image_File, name: string) -> bool {
	for &item in files {
		if item.name == name && len(item.file) > 0 {
			changed := make([]u8, len(item.file), context.temp_allocator)
			copy(changed, item.file)
			changed[len(changed) - 1] ~= 0x01
			item.file = changed
			return true
		}
	}
	fmt.eprintfln("kerneltool: the boot image has no module %s to change", name)
	return false
}

// image_description_read gives the system description of the boot image
// of a boot volume.
image_description_read :: proc(volume_path: string) -> (description: []u8, ok: bool) {
	image := read_file(signed_image_path(volume_path)) or_return
	found: bool
	description, _, found = system_description.trust_resources(image)
	if !found {
		fmt.eprintfln("kerneltool: %s has no system description", signed_image_path(volume_path))
		return nil, false
	}
	return description, true
}

// measure_expected gives the value that the measure register must hold
// after the measure, in the SHA-256 bank: the register starts at 32 zero
// bytes, and one extension makes it SHA-256(register || SHA-256(data)). No
// other part of the boot of the first machine extends this register.
measure_expected :: proc(description: []u8) -> (value: [32]u8) {
	digest: [32]u8
	hash_state: sha2.Context_256
	sha2.init_256(&hash_state)
	sha2.update(&hash_state, description)
	sha2.final(&hash_state, digest[:])
	start: [32]u8
	sha2.init_256(&hash_state)
	sha2.update(&hash_state, start[:])
	sha2.update(&hash_state, digest[:])
	sha2.final(&hash_state, value[:])
	return
}

// run_key: `key new <folder>` writes a new signing key: <folder>/signing_key
// (the private key, readable by its owner only, in a folder that only its
// owner can open) and <folder>/signing_key.public. `key show` prints the
// public key that the build uses.
run_key :: proc(args: []string) -> int {
	if len(args) == 1 && args[0] == "show" {
		key, ok := signing_key_read()
		if !ok {
			return EXIT_FAILURE
		}
		digits := system_description.hexadecimal(key.public_key)
		fmt.printfln("%s%s", string(digits[:]), key.is_test ? " (the test signing key: not trusted)" : "")
		return 0
	}
	if len(args) != 2 || args[0] != "new" {
		fmt.eprintln("kerneltool: key new <folder outside the repository> | key show")
		return EXIT_USAGE
	}
	folder := args[1]
	if path_inside_repository(folder) {
		fmt.eprintfln("kerneltool: %s is inside the repository: a private key stays outside it", folder)
		return EXIT_USAGE
	}
	private_path := strings.concatenate({folder, "/", SIGNING_KEY_FILE_NAME}, context.temp_allocator)
	public_path := strings.concatenate({private_path, SIGNING_KEY_PUBLIC_SUFFIX}, context.temp_allocator)
	if os.exists(private_path) || os.exists(public_path) {
		fmt.eprintfln("kerneltool: %s already holds a signing key: a new key does not replace one", folder)
		return EXIT_FAILURE
	}
	if !os.exists(folder) {
		if err := os.make_directory(folder, os.perm(0o700)); err != nil {
			fmt.eprintfln("kerneltool: cannot create %s: %v", folder, err)
			return EXIT_FAILURE
		}
	}
	if err := os.change_mode(folder, os.perm(0o700)); err != nil {
		fmt.eprintfln("kerneltool: cannot make %s private: %v", folder, err)
		return EXIT_FAILURE
	}
	// The seed of the key comes from the generator of the host. The
	// cryptography of the system has no source of its own: in the system the
	// root service seeds each program.
	seed: [SIGNING_KEY_SIZE]u8
	defer crypto.zero_explicit(&seed, size_of(seed))
	random_file, open_error := os.open("/dev/urandom")
	if open_error != nil {
		fmt.eprintfln("kerneltool: this host gives no random bytes: %v", open_error)
		return EXIT_FAILURE
	}
	read_count, read_error := os.read(random_file, seed[:])
	os.close(random_file)
	if read_error != nil || read_count != len(seed) {
		fmt.eprintln("kerneltool: this host gives no random bytes")
		return EXIT_FAILURE
	}
	private_key: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&private_key, seed[:]) {
		fmt.eprintln("kerneltool: cannot make a key")
		return EXIT_FAILURE
	}
	defer ed25519.private_key_clear(&private_key)
	public: [system_description.PUBLIC_KEY_SIZE]u8
	ed25519.private_key_public_bytes(&private_key, public[:])
	seed_digits := system_description.hexadecimal(seed)
	defer crypto.zero_explicit(&seed_digits, size_of(seed_digits))
	public_digits := system_description.hexadecimal(public)
	private_text := strings.concatenate({string(seed_digits[:]), "\n"}, context.temp_allocator)
	defer crypto.zero_explicit(raw_data(private_text), len(private_text))
	if err := os.write_entire_file(private_path, private_text, os.perm(0o600)); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", private_path, err)
		return EXIT_FAILURE
	}
	if err := os.change_mode(private_path, os.perm(0o600)); err != nil {
		fmt.eprintfln("kerneltool: cannot make %s private: %v", private_path, err)
		return EXIT_FAILURE
	}
	if err := os.write_entire_file(public_path, strings.concatenate({string(public_digits[:]), "\n"}, context.temp_allocator)); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", public_path, err)
		return EXIT_FAILURE
	}
	fmt.printfln("kerneltool: wrote %s and %s; public key %s", private_path, public_path, string(public_digits[:]))
	fmt.printfln("kerneltool: keep a copy of %s on a second medium, offline; then set %s=%s for each build (docs/TRUSTED_BOOT.md, \"The signing key\")", private_path, SIGNING_KEY_VARIABLE, private_path)
	return 0
}
