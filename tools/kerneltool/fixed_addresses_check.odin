package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"

// The fixed ranges have one source: the enumeration Fixed_Range of
// contract/fixed_addresses (its comment says why). A constant of another
// file written as BAND_START + n * SLOT would be a range with no member,
// which no check of the package sees. So no file of these folders, but the
// package itself, names BAND_START or SLOT of that package.
FIXED_ADDRESSES_FOLDER :: "contract/fixed_addresses"
FIXED_ADDRESSES_CHECKED_FOLDERS :: [?]string{"contract", "support", "programs", "modules"}
FIXED_ADDRESSES_PRIVATE_NAMES :: [?]string{"BAND_START", "SLOT"}

fixed_addresses_check :: proc() -> bool {
	files := make([dynamic]string, context.temp_allocator)
	folders := FIXED_ADDRESSES_CHECKED_FOLDERS
	names := FIXED_ADDRESSES_PRIVATE_NAMES
	for folder in folders {
		source_files_of_a_folder(folder, &files) or_return
	}
	found := 0
	for path in files {
		if strings.has_prefix(path, FIXED_ADDRESSES_FOLDER + "/") {
			continue
		}
		bytes, read_error := os.read_entire_file(path, context.temp_allocator)
		if read_error != nil {
			fmt.eprintfln("kerneltool: test failed: cannot read %s: %v", path, read_error)
			return false
		}
		text := string(bytes)
		alias, imports := fixed_addresses_import_name(text)
		if !imports {
			continue
		}
		for name in names {
			qualified := strings.concatenate({alias, ".", name}, context.temp_allocator)
			at := 0
			for {
				index := strings.index(text[at:], qualified)
				if index < 0 {
					break
				}
				end := at + index + len(qualified)
				// The name, not a longer name that starts with it.
				if end >= len(text) || !identifier_byte(text[end]) {
					line := strings.count(text[:at + index], "\n") + 1
					fmt.eprintfln("kerneltool: test failed: %s:%d names %s: an address of the band comes from a member of Fixed_Range only (%s)", path, line, qualified, FIXED_ADDRESSES_FOLDER)
					found += 1
				}
				at = end
			}
		}
	}
	if found > 0 {
		return false
	}
	test_passed_print("no file outside %s names BAND_START or SLOT (%d files read)", FIXED_ADDRESSES_FOLDER, len(files))
	return true
}

// fixed_addresses_import_name gives the name under which a source file
// imports contract:fixed_addresses: its alias, or the name of the package.
@(private = "file")
fixed_addresses_import_name :: proc(text: string) -> (name: string, imports: bool) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, "import ") || !strings.has_suffix(trimmed, "\"contract:fixed_addresses\"") {
			continue
		}
		middle := strings.trim_space(trimmed[len("import "):len(trimmed) - len("\"contract:fixed_addresses\"")])
		return middle == "" ? "fixed_addresses" : middle, true
	}
	return "", false
}

@(private = "file")
identifier_byte :: proc(byte: u8) -> bool {
	return byte == '_' || byte >= 'a' && byte <= 'z' || byte >= 'A' && byte <= 'Z' || byte >= '0' && byte <= '9'
}

// source_files_of_a_folder appends the .odin files of a folder and of its
// folders.
source_files_of_a_folder :: proc(folder: string, files: ^[dynamic]string) -> bool {
	entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("kerneltool: cannot list %s: %v", folder, err)
		return false
	}
	for entry in entries {
		path := join(folder, "/", entry.name)
		switch {
		case entry.type == .Directory:
			source_files_of_a_folder(path, files) or_return
		case strings.has_suffix(entry.name, ".odin"):
			append(files, path)
		}
	}
	return true
}
