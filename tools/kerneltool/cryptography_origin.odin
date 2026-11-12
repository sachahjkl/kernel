package kerneltool

import "core:fmt"
import "core:os"
import "core:slice"
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
// The files of support/cryptography that the system wrote itself (the
// compatibility layer, the files in the place of a hardware dispatch, the
// tests), each with its BLAKE3 hash: a change of one of them shows in the
// check and in review, as a change of a taken file does.
CRYPTOGRAPHY_SYSTEM_FILES :: "support/cryptography/system_files.manifest"
CRYPTOGRAPHY_FOLDER :: "support/cryptography"
CRYPTOGRAPHY_ORIGIN_PREFIX :: "core/crypto/"
// The word in place of a hash that the coordinator has to compute with
// `kerneltool cryptography-system-hashes`.
HASH_TO_COMPUTE :: "TO_COMPUTE"
CRYPTOGRAPHY_ORIGIN_RELEASE :: "dev-2026-11a" // The release of Odin that flake.nix pins.

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
	{"\"core:crypto/hash\"", "hash \"support:cryptography/compatibility_hash\""},
	{"\"core:crypto/", "\"support:cryptography/"},
	{"\"core:encoding/endian\"", "endian \"support:cryptography/compatibility_endian\""},
	{"\"core:math/bits\"", "bits \"support:cryptography/compatibility_bits\""},
	{"\"core:bytes\"", "bytes \"support:cryptography/compatibility_bytes\""},
}

// One listed adjustment of a taken file: lines of the origin, and the lines
// in their place. The lines of the origin must be in the origin exactly one
// time: when the origin changes them, the check fails, and a person looks
// at the adjustment again.
Cryptography_Adjustment :: struct {
	origin_path:  string,
	origin_lines: string,
	lines:        string,
}

// The listed adjustments (docs/CRYPTOGRAPHY.md, section 4, "Listed
// adjustments"). There are two groups.
//
// The adjustments of _chacha20/chacha20.odin are one correction of the
// origin, offered to Odin as its pull request 8329: the counter check of
// ChaCha20 refused the block with the last counter, which RFC 8439 allows,
// and the peer of a QUIC connection chooses that counter (the sample of the
// header protection). The check now allows a call that ends on the last
// block, refuses a call that goes past it, and refuses each call after it
// until `seek` or `init`. When the release of Odin that the flake pins has
// the correction, these lines go.
//
// The adjustments of argon2id/argon2id.odin take its allocator away: the
// caller supplies the blocks, because the code of a program or of a module
// has no allocator. A supply that is smaller than the parameters ask, or
// not aligned on 8 bytes, is the result Out_Of_Memory before any work. The
// helpers of core:mem come from the compatibility layer.
cryptography_adjustments := [?]Cryptography_Adjustment {
	{
		"core/crypto/argon2id/argon2id.odin",
		"import \"core:mem\"\n",
		"import mem \"support:cryptography/compatibility_memory\"\n",
	},
	{
		"core/crypto/argon2id/argon2id.odin",
		"\tallocator := context.allocator, // Not temp as this can be large.\n",
		"\twork_memory: []byte = nil, // The caller supplies the blocks: memory_size KiB, aligned on 8 bytes.\n",
	},
	{
		"core/crypto/argon2id/argon2id.odin",
		"\tb := mem.alloc_bytes_non_zeroed(\n\t\tint(m_) * BLOCK_SIZE_BYTES,\n\t\talignment = mem.PAGE_SIZE,\n\t\tallocator = allocator,\n\t) or_return\n\tdefer delete(b, allocator)\n",
		"\tif u64(len(work_memory)) < m_ * BLOCK_SIZE_BYTES || uintptr(raw_data(work_memory)) % 8 != 0 {\n\t\treturn .Out_Of_Memory\n\t}\n\tb := work_memory[:int(m_) * BLOCK_SIZE_BYTES]\n",
	},
	{
		"core/crypto/_chacha20/chacha20.odin",
		"import \"base:intrinsics\"\n",
		"",
	},
	{
		"core/crypto/_chacha20/chacha20.odin",
		"\t_is_initialized: bool,\n}\n",
		"\t_is_initialized: bool,\n\t_is_exhausted:   bool,\n}\n",
	},
	{
		"core/crypto/_chacha20/chacha20.odin",
		"\tctx._is_initialized = true\n}\n",
		"\tctx._is_initialized = true\n\tctx._is_exhausted = false\n}\n",
	},
	{
		"core/crypto/_chacha20/chacha20.odin",
		"\tctx._s[12] = u32(block_nr)\n\tctx._off = BLOCK_SIZE\n}\n",
		"\tctx._s[12] = u32(block_nr)\n\tctx._off = BLOCK_SIZE\n\tctx._is_exhausted = false\n}\n",
	},
	{
		"core/crypto/_chacha20/chacha20.odin",
		"\tctr_ok: bool\n\tif ctx._is_ietf_flavor {\n\t\tif intrinsics.unlikely(ctx._s[12] == MAX_CTR_IETF && nr_blocks > 1) {\n\t\t\t// Allow the final block.\n\t\t\tctr_ok = false\n\t\t} else {\n\t\t\tctr_ok = u64(ctx._s[12]) + u64(nr_blocks) <= MAX_CTR_IETF\n\t\t}\n\t} else {\n\t\tctr := (u64(ctx._s[13]) << 32) | u64(ctx._s[12])\n\t\tnew_ctr, carry := bits.add_u64(ctr, u64(nr_blocks), 0)\n\t\tctr_ok = carry == 0 || new_ctr != 0 // Allow the final block.\n\t}\n\n\tensure(ctr_ok, \"crypto/chacha20: maximum (X)ChaCha20 keystream per IV reached\")\n",
		"\t// The final block is the one with the maximum counter value.\n\t// The counter wraps around after it, so once it is consumed,\n\t// refuse to generate more keystream until `seek` or `init`.\n\tctr_ok, is_final: bool\n\tif ctx._is_ietf_flavor {\n\t\tnew_ctr := u64(ctx._s[12]) + u64(nr_blocks)\n\t\tctr_ok = new_ctr <= MAX_CTR_IETF + 1\n\t\tis_final = new_ctr == MAX_CTR_IETF + 1\n\t} else {\n\t\tctr := (u64(ctx._s[13]) << 32) | u64(ctx._s[12])\n\t\tnew_ctr, carry := bits.add_u64(ctr, u64(nr_blocks), 0)\n\t\tctr_ok = carry == 0 || new_ctr == 0\n\t\tis_final = carry != 0\n\t}\n\n\tensure(ctr_ok && !ctx._is_exhausted, ERR_CTR_EXHAUSTED)\n\tctx._is_exhausted = is_final\n",
	},
}

// cryptography_adjusted says if a taken file has a listed adjustment.
cryptography_adjusted :: proc(origin_path: string) -> bool {
	for adjustment in cryptography_adjustments {
		if adjustment.origin_path == origin_path {
			return true
		}
	}
	return false
}

// cryptography_marking is the first line of each file that is taken: the
// zlib license of Odin asks that an altered source says so.
cryptography_marking :: proc(origin_path: string) -> string {
	what := cryptography_adjusted(origin_path) ? "its imports changed, and the adjustments that tools/kerneltool/cryptography_origin.odin lists" : "only its imports changed"
	return fmt.tprintf("// Altered source: Odin %s, %s; %s (support/cryptography/origin.manifest, docs/CRYPTOGRAPHY.md).\n", CRYPTOGRAPHY_ORIGIN_RELEASE, origin_path, what)
}

// cryptography_file_from_origin gives the bytes that the file of the
// repository must have: the marking, then the origin with each import
// change and each listed adjustment of that file. ok is false when the
// lines of an adjustment are not in the origin exactly one time.
cryptography_file_from_origin :: proc(origin: string, origin_path: string) -> (file: string, ok: bool) {
	text := origin
	for adjustment in cryptography_adjustments {
		if adjustment.origin_path != origin_path {
			continue
		}
		if strings.count(text, adjustment.origin_lines) != 1 {
			fmt.eprintfln("kerneltool: an adjustment of %s names lines that the origin has %d times, not 1: the origin changed; read the adjustment again", origin_path, strings.count(text, adjustment.origin_lines))
			return "", false
		}
		text, _ = strings.replace(text, adjustment.origin_lines, adjustment.lines, 1, context.temp_allocator)
	}
	for change in cryptography_import_changes {
		text, _ = strings.replace_all(text, change[0], change[1], context.temp_allocator)
	}
	return strings.concatenate({cryptography_marking(origin_path), text}, context.temp_allocator), true
}

hex_text :: proc(bytes: []u8) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for byte in bytes {
		fmt.sbprintf(&builder, "%02x", byte)
	}
	return strings.to_string(builder)
}

// odin_files_of_a_folder gives each .odin file under a folder and its
// subfolders: Odin compiles each .odin file of a package folder, so each one
// must be in a list. A symbolic link is refused (a folder of a copy that
// points elsewhere would bring files that no list names), and so is a file
// that is not a .odin file, a license or one of the two manifests (a #load
// or a foreign import could read it, and its bytes have no hash). The lists
// are a tripwire, not a proof of review: whoever changes a file of the
// system also writes its new hash; the review reads the change.
odin_files_of_a_folder :: proc(folder: string, files: ^[dynamic]string) -> bool {
	entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("kerneltool: cannot list %s: %v", folder, err)
		return false
	}
	for entry in entries {
		path := join(folder, "/", entry.name)
		switch {
		case entry.type == .Symlink:
			fmt.eprintfln("kerneltool: test failed: %s is a symbolic link: the files of support/cryptography are in its folders", path)
			return false
		case entry.type == .Directory:
			odin_files_of_a_folder(path, files) or_return
		case strings.has_suffix(entry.name, ".odin"):
			append(files, path)
		case strings.has_prefix(entry.name, "LICENSE.") && folder == CRYPTOGRAPHY_FOLDER, path == CRYPTOGRAPHY_MANIFEST, path == CRYPTOGRAPHY_SYSTEM_FILES:
		case:
			fmt.eprintfln("kerneltool: test failed: %s is not a .odin file, a license or a manifest: no list can name it", path)
			return false
		}
	}
	return true
}

// manifest_lines gives the lines of a manifest that are not comments, each
// as its fields.
manifest_lines :: proc(path: string) -> (lines: [][]string, ok: bool) {
	text, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("kerneltool: cannot read %s: %v", path, err)
		return nil, false
	}
	list := make([dynamic][]string, context.temp_allocator)
	for line in strings.split_lines(string(text), context.temp_allocator) {
		if len(line) == 0 || line[0] == '#' {
			continue
		}
		append(&list, strings.fields(line, context.temp_allocator))
	}
	return list[:], true
}

// cryptography_system_files_check reads the list of the files that the
// system wrote: "<file of the repository> <BLAKE3 of the file>". Each file
// must have that hash.
cryptography_system_files_check :: proc(listed: ^map[string]string) -> bool {
	lines := manifest_lines(CRYPTOGRAPHY_SYSTEM_FILES) or_return
	for parts in lines {
		if len(parts) != 2 {
			fmt.eprintfln("kerneltool: test failed: a line of %s does not have 2 parts: %v", CRYPTOGRAPHY_SYSTEM_FILES, parts)
			return false
		}
		if parts[0] in listed {
			fmt.eprintfln("kerneltool: test failed: %s is in two lists", parts[0])
			return false
		}
		listed[parts[0]] = CRYPTOGRAPHY_SYSTEM_FILES
		bytes, err := os.read_entire_file(parts[0], context.temp_allocator)
		if err != nil {
			fmt.eprintfln("kerneltool: test failed: no file %s: %v", parts[0], err)
			return false
		}
		hash := blake3.hash(bytes)
		if parts[1] == HASH_TO_COMPUTE {
			fmt.eprintfln("kerneltool: test failed: %s has no hash in %s yet: `kerneltool cryptography-system-hashes` prints the lines", parts[0], CRYPTOGRAPHY_SYSTEM_FILES)
			return false
		}
		if hex_text(hash[:]) != parts[1] {
			fmt.eprintfln("kerneltool: test failed: %s has the hash %s, not %s: a file of the system changed; review it, then write its new hash", parts[0], hex_text(hash[:]), parts[1])
			return false
		}
	}
	return true
}

// run_cryptography_system_hashes prints the line of the list of the files of
// the system for each .odin file of support/cryptography that the manifest of
// the origin does not name: the coordinator checks the files, then puts the
// lines in support/cryptography/system_files.manifest.
run_cryptography_system_hashes :: proc(args: []string) -> int {
	taken := make(map[string]bool, context.temp_allocator)
	lines, ok := manifest_lines(CRYPTOGRAPHY_MANIFEST)
	if !ok {
		return EXIT_FAILURE
	}
	for parts in lines {
		if len(parts) > 0 {
			taken[parts[0]] = true
		}
	}
	files := make([dynamic]string, context.temp_allocator)
	if !odin_files_of_a_folder(CRYPTOGRAPHY_FOLDER, &files) {
		return EXIT_FAILURE
	}
	slice.sort(files[:])
	for file in files {
		if file in taken {
			continue
		}
		bytes, err := os.read_entire_file(file, context.temp_allocator)
		if err != nil {
			fmt.eprintfln("kerneltool: cannot read %s: %v", file, err)
			return EXIT_FAILURE
		}
		hash := blake3.hash(bytes)
		fmt.printfln("%s %s", file, hex_text(hash[:]))
	}
	return 0
}

// cryptography_origin_check reads the manifest: one file on each line, as
// "<file of the repository> <file under the root of Odin> <BLAKE3 of the
// origin>"; a line that starts with # is a comment. Then it reads the list
// of the files of the system, and walks the folders of support/cryptography:
// each .odin file must be in one list. It gives false at the first file that
// does not agree.
cryptography_origin_check :: proc() -> bool {
	listed := make(map[string]string, context.temp_allocator)
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
		// An origin is a file of core:crypto, by a path with no "..": a line
		// cannot take a file of another part of Odin, or of the host.
		if !strings.has_prefix(parts[1], CRYPTOGRAPHY_ORIGIN_PREFIX) || strings.contains(parts[1], "..") || !strings.has_prefix(parts[0], CRYPTOGRAPHY_FOLDER + "/") || strings.contains(parts[0], "..") {
			fmt.eprintfln("kerneltool: test failed: a line of %s names %s from %s: an origin starts with %s, a file with %s/, and neither has \"..\"", CRYPTOGRAPHY_MANIFEST, parts[0], parts[1], CRYPTOGRAPHY_ORIGIN_PREFIX, CRYPTOGRAPHY_FOLDER)
			return false
		}
		if parts[0] in listed {
			fmt.eprintfln("kerneltool: test failed: %s is in %s two times", parts[0], CRYPTOGRAPHY_MANIFEST)
			return false
		}
		listed[parts[0]] = CRYPTOGRAPHY_MANIFEST
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
		wanted, adjusted := cryptography_file_from_origin(string(origin), parts[1])
		if !adjusted {
			return false
		}
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
	if !cryptography_system_files_check(&listed) {
		return false
	}
	found := make([dynamic]string, context.temp_allocator)
	if !odin_files_of_a_folder(CRYPTOGRAPHY_FOLDER, &found) {
		return false
	}
	for file in found {
		if file not_in listed {
			fmt.eprintfln("kerneltool: test failed: %s is in no list: a file of the origin goes in %s, a file of the system in %s", file, CRYPTOGRAPHY_MANIFEST, CRYPTOGRAPHY_SYSTEM_FILES)
			return false
		}
	}
	for file in listed {
		found_it := false
		for other in found {
			found_it ||= other == file
		}
		if !found_it {
			fmt.eprintfln("kerneltool: test failed: %s is in a list, and is not in %s", file, CRYPTOGRAPHY_FOLDER)
			return false
		}
	}
	test_passed_print("each of the %d .odin files of %s is in a list; %d files of the system have the hash of their list", len(found), CRYPTOGRAPHY_FOLDER, len(listed) - files)
	test_passed_print("%d files of support/cryptography are their origin in Odin %s (each with the BLAKE3 hash of the manifest) with the %d listed import changes, the %d listed adjustments, and nothing else", files, CRYPTOGRAPHY_ORIGIN_RELEASE, len(cryptography_import_changes), len(cryptography_adjustments))
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
	file, adjusted := cryptography_file_from_origin(string(origin), args[0])
	if !adjusted {
		return EXIT_FAILURE
	}
	if write_error := os.write_entire_file(args[1], transmute([]u8)file); write_error != nil {
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
