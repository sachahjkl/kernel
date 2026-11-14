package kerneltool

import "modus:contract/blake3"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// A small folder of modules: three files with the suffix of a module.
@(private = "file")
module_folder_make :: proc(t: ^testing.T) -> (folder: string) {
	made, error := os.make_directory_temp("", "module_hashes_test_*", context.temp_allocator)
	testing.expect_value(t, error, nil)
	module_file_write(made, "first", "the bytes of the first module")
	module_file_write(made, "second", "the bytes of the second module")
	module_file_write(made, "third", "the bytes of the third module")
	return made
}

@(private = "file")
module_file_write :: proc(folder, name, text: string) {
	_ = os.write_entire_file(fmt.tprintf("%s/%s%s", folder, name, MODULE_FILE_SUFFIX), text)
}

// The record of a folder reads back as the hashes of its files, and a
// build with the same files has no difference.
@(test)
module_hashes_record_reads_back :: proc(t: ^testing.T) {
	folder := module_folder_make(t)
	defer os.remove_all(folder)
	names := []string{"first", "second", "third"}
	hashes, hashed := module_hashes_of_folder(folder, names)
	if !testing.expect(t, hashed, "each module of the folder is read") {
		return
	}
	testing.expect_value(t, len(hashes), 3)
	second_text: string = "the bytes of the second module"
	testing.expect_value(t, hashes[1].name, "second")
	testing.expect(t, hashes[1].hash == blake3.hash(transmute([]u8)second_text), "the hash of a module is the BLAKE3 hash of its file")

	text := module_hashes_record_text(hashes)
	testing.expect(t, strings.has_prefix(text, MODULE_HASHES_FIRST_LINE + "\n"), text)
	testing.expect(t, strings.contains(text, fmt.tprintf("%s second\n", hash_as_hexadecimal(hashes[1].hash))), text)
	read_back, problem := module_hashes_record_parse(text)
	testing.expect_value(t, problem, "")
	if !testing.expect_value(t, len(read_back), 3) {
		return
	}
	for item, index in read_back {
		testing.expect_value(t, item.name, hashes[index].name)
		testing.expect(t, item.hash == hashes[index].hash, item.name)
	}
	comparison := module_hashes_compare(read_back, hashes)
	testing.expect_value(t, comparison.equal_count, 3)
	testing.expect(t, module_hashes_comparison_is_equal(comparison), "the same files have the same hashes")
}

// One byte of one module gives one difference, with its name and its two
// hashes; the other modules are counted as equal.
@(test)
module_hashes_name_the_module_that_changed :: proc(t: ^testing.T) {
	folder := module_folder_make(t)
	defer os.remove_all(folder)
	names := []string{"first", "second", "third"}
	before, hashed_before := module_hashes_of_folder(folder, names)
	module_file_write(folder, "second", "the bytes of the second module, changed")
	now, hashed_now := module_hashes_of_folder(folder, names)
	if !testing.expect(t, hashed_before && hashed_now, "each module of the folder is read") {
		return
	}
	comparison := module_hashes_compare(before, now)
	testing.expect_value(t, comparison.equal_count, 2)
	testing.expect(t, !module_hashes_comparison_is_equal(comparison), "a changed module is a difference")
	if testing.expect_value(t, len(comparison.different), 1) {
		testing.expect_value(t, comparison.different[0].name, "second")
		testing.expect(t, comparison.different[0].before == before[1].hash && comparison.different[0].now == now[1].hash, "the difference holds the two hashes")
	}
	testing.expect_value(t, len(comparison.only_before), 0)
	testing.expect_value(t, len(comparison.only_now), 0)
}

// A module that only the record has, and one that only the build has, are
// named; the comparison is not equal, also when each common hash is.
@(test)
module_hashes_name_the_module_of_one_build_only :: proc(t: ^testing.T) {
	folder := module_folder_make(t)
	defer os.remove_all(folder)
	before, hashed_before := module_hashes_of_folder(folder, []string{"first", "second"})
	now, hashed_now := module_hashes_of_folder(folder, []string{"second", "third"})
	if !testing.expect(t, hashed_before && hashed_now, "each module of the folder is read") {
		return
	}
	comparison := module_hashes_compare(before, now)
	testing.expect_value(t, comparison.equal_count, 1)
	testing.expect_value(t, len(comparison.different), 0)
	testing.expect(t, !module_hashes_comparison_is_equal(comparison), "a module of one build only is a difference")
	if testing.expect_value(t, len(comparison.only_before), 1) && testing.expect_value(t, len(comparison.only_now), 1) {
		testing.expect_value(t, comparison.only_before[0], "first")
		testing.expect_value(t, comparison.only_now[0], "third")
	}
	// A module of the list with no file is not hashed.
	_, hashed_absent := module_hashes_of_folder(folder, []string{"first", "absent"})
	testing.expect(t, !hashed_absent, "a module with no file stops the list")
}

// A text that is not a record gives a sentence.
@(test)
module_hashes_record_with_a_fault_is_refused :: proc(t: ^testing.T) {
	// A text of the digits of a hash: one byte, as many times as a hash has digits.
	digits_of :: proc(digit: u8) -> string {
		digits := make([]u8, MODULE_HASH_DIGITS, context.temp_allocator)
		for &character in digits {
			character = digit
		}
		return string(digits)
	}
	good_hash := digits_of('a')
	good := fmt.tprintf("%s\n%s first\n", MODULE_HASHES_FIRST_LINE, good_hash)
	_, good_problem := module_hashes_record_parse(good)
	testing.expect_value(t, good_problem, "")
	Case :: struct {
		text:  string,
		words: string,
	}
	cases := [?]Case {
		{"", "line 1 is not"},
		{fmt.tprintf("another file\n%s first\n", good_hash), "line 1 is not"},
		{fmt.tprintf("%s\n%s first\n", MODULE_HASHES_FIRST_LINE, good_hash[1:]), "line 2"},
		{fmt.tprintf("%s\n%sfirst\n", MODULE_HASHES_FIRST_LINE, good_hash), "line 2 is not a hash"},
		{fmt.tprintf("%s\n%s first\n", MODULE_HASHES_FIRST_LINE, digits_of('G')), "line 2 does not start with"},
		{fmt.tprintf("%s\n%s first\n%s first\n", MODULE_HASHES_FIRST_LINE, good_hash, good_hash), "line 3 names the module first a second time"},
	}
	for item in cases {
		_, problem := module_hashes_record_parse(item.text)
		testing.expectf(t, strings.contains(problem, item.words), "%q gives %q, not %q", item.text, problem, item.words)
	}
}
