package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"
import "contract:blake3"

// The cryptography of the system is code of Odin's `core:crypto`, taken
// into support/cryptography and changed in a listed way only
// (docs/CRYPTOGRAPHY.md). This check proves it for each file of the
// manifest: the origin file in the compiler that the flake pins has the
// BLAKE3 hash of the manifest, and the origin with the changes below gives
// the file of the repository, byte for byte. A reader audits the changes
// here, not in a diff of each file.

CRYPTOGRAPHY_MANIFEST :: "support/cryptography/origin.manifest"
CRYPTOGRAPHY_ORIGIN_RELEASE :: "dev-2026-05" // The tag of Odin in nixpkgs: https://github.com/odin-lang/Odin/archive/refs/tags/dev-2026-05.tar.gz

// The only changes of a file that is taken: its imports go to the copies in
// support/cryptography, and to the compatibility layer for the helpers of
// the origin. Order matters: the base package first, with its quote.
// The packages of the compatibility layer have their own names
// (compatibility_crypto, ...), so that a test that also imports a package of
// Odin with the name of the origin compiles; the import keeps the name of
// the origin as its alias.
@(rodata)
cryptography_import_changes := [?][2]string {
	{"\"core:crypto\"", "crypto \"support:cryptography/compatibility_crypto\""},
	{"\"core:crypto/", "\"support:cryptography/"},
	{"\"core:encoding/endian\"", "endian \"support:cryptography/compatibility_endian\""},
	{"\"core:math/bits\"", "bits \"support:cryptography/compatibility_bits\""},
	{"\"core:bytes\"", "bytes \"support:cryptography/compatibility_bytes\""},
}

// cryptography_marking is the first line of each file that is taken: the
// zlib license of Odin asks that an altered source says so.
cryptography_marking :: proc(origin_path: string) -> string {
	return fmt.tprintf("// Altered source: Odin %s, %s; only its imports changed (support/cryptography/origin.manifest, docs/CRYPTOGRAPHY.md).\n", CRYPTOGRAPHY_ORIGIN_RELEASE, origin_path)
}

// cryptography_file_from_origin gives the bytes that the file of the
// repository must have: the marking, then the origin with each import
// change.
cryptography_file_from_origin :: proc(origin: string, origin_path: string) -> string {
	text := origin
	for change in cryptography_import_changes {
		text, _ = strings.replace_all(text, change[0], change[1], context.temp_allocator)
	}
	return strings.concatenate({cryptography_marking(origin_path), text}, context.temp_allocator)
}

hex_text :: proc(bytes: []u8) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for byte in bytes {
		fmt.sbprintf(&builder, "%02x", byte)
	}
	return strings.to_string(builder)
}

// cryptography_origin_check reads the manifest: one file on each line, as
// "<file of the repository> <file under the root of Odin> <BLAKE3 of the
// origin>"; a line that starts with # is a comment. It gives false at the
// first file that does not agree.
cryptography_origin_check :: proc() -> bool {
	manifest, err := os.read_entire_file(CRYPTOGRAPHY_MANIFEST, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("kerneltool: cannot read %s: %v", CRYPTOGRAPHY_MANIFEST, err)
		return false
	}
	files := 0
	for line in strings.split_lines(string(manifest), context.temp_allocator) {
		if len(line) == 0 || line[0] == '#' {
			continue
		}
		parts := strings.fields(line, context.temp_allocator)
		if len(parts) != 3 {
			fmt.eprintfln("kerneltool: test failed: a line of %s does not have 3 parts: %q", CRYPTOGRAPHY_MANIFEST, line)
			return false
		}
		origin_path := strings.concatenate({ODIN_ROOT, parts[1]}, context.temp_allocator)
		origin, origin_error := os.read_entire_file(origin_path, context.temp_allocator)
		if origin_error != nil {
			fmt.eprintfln("kerneltool: test failed: no origin %s: %v", origin_path, origin_error)
			return false
		}
		hash := blake3.hash(origin)
		if hex_text(hash[:]) != parts[2] {
			fmt.eprintfln("kerneltool: test failed: the origin %s has the hash %s, not %s: the compiler of the flake changed", parts[1], hex_text(hash[:]), parts[2])
			return false
		}
		taken, taken_error := os.read_entire_file(parts[0], context.temp_allocator)
		if taken_error != nil {
			fmt.eprintfln("kerneltool: test failed: no file %s: %v", parts[0], taken_error)
			return false
		}
		wanted := cryptography_file_from_origin(string(origin), parts[1])
		if string(taken) != wanted {
			at := 0
			for at < min(len(taken), len(wanted)) && taken[at] == wanted[at] {
				at += 1
			}
			fmt.eprintfln("kerneltool: test failed: %s is not its origin %s with the listed changes: the first other byte is at %d", parts[0], parts[1], at)
			return false
		}
		files += 1
	}
	fmt.printfln("kerneltool: test passed: %d files of support/cryptography are their origin in Odin %s (each with the BLAKE3 hash of the manifest) with the %d listed import changes and nothing else", files, CRYPTOGRAPHY_ORIGIN_RELEASE, len(cryptography_import_changes))
	return true
}

// run_cryptography_take writes a file of the repository from its origin,
// with the listed changes, and prints the line of the manifest for it:
// `cryptography-take <file under the root of Odin> <file of the repository>`.
run_cryptography_take :: proc(args: []string) -> int {
	if len(args) != 2 {
		fmt.eprintln("kerneltool: cryptography-take <file under the root of Odin> <file of the repository>")
		return EXIT_USAGE
	}
	origin, err := os.read_entire_file(strings.concatenate({ODIN_ROOT, args[0]}, context.temp_allocator), context.temp_allocator)
	if err != nil {
		fmt.eprintfln("kerneltool: cannot read the origin %s: %v", args[0], err)
		return EXIT_FAILURE
	}
	if write_error := os.write_entire_file(args[1], transmute([]u8)cryptography_file_from_origin(string(origin), args[0])); write_error != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", args[1], write_error)
		return EXIT_FAILURE
	}
	hash := blake3.hash(origin)
	fmt.printfln("%s %s %s", args[1], args[0], hex_text(hash[:]))
	return 0
}

run_cryptography_origin :: proc(args: []string) -> int {
	return cryptography_origin_check() ? 0 : EXIT_FAILURE
}
