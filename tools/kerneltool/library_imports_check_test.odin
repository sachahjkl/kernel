package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// A small tree with a kernel, two contract packages and one support
// package, at the folders of the tool: the check reads them there. Each
// file is one import that the rule allows.
@(private = "file")
library_tree_make :: proc(t: ^testing.T) -> (root: string) {
	folder, error := os.make_directory_temp("", "library_imports_test_*", context.temp_allocator)
	testing.expect_value(t, error, nil)
	for name in ([]string{SOURCE_FOLDER_KERNEL, SOURCE_FOLDER_CONTRACT + "/ring", SOURCE_FOLDER_CONTRACT + "/record/inner", SOURCE_FOLDER_SUPPORT + "/sentence"}) {
		_ = os.make_directory_all(fmt.tprintf("%s/%s", folder, name))
	}
	library_tree_file_write(folder, SOURCE_FOLDER_KERNEL + "/enter.odin", "package kernel\n\nimport \"base:intrinsics\"\nimport ring \"" + CONTRACT_IMPORT_START + "ring\"\nimport \"" + CONTRACT_IMPORT_START + "record/inner\"\n")
	library_tree_file_write(folder, SOURCE_FOLDER_CONTRACT + "/ring/ring.odin", "package ring\n\nimport \"" + CONTRACT_IMPORT_START + "record/inner\"\n")
	library_tree_file_write(folder, SOURCE_FOLDER_CONTRACT + "/ring/ring_test.odin", "package ring\n\nimport \"core:testing\"\nimport \"core:math/rand\"\n")
	library_tree_file_write(folder, SOURCE_FOLDER_CONTRACT + "/record/inner/inner.odin", "package inner\n")
	// A support package imports what it needs: the check does not read it.
	library_tree_file_write(folder, SOURCE_FOLDER_SUPPORT + "/sentence/sentence.odin", "package sentence\n\nimport \"../other\"\nimport \"vendor:glfw\"\n")
	return folder
}

@(private = "file")
library_tree_file_write :: proc(root, name, text: string) {
	_ = os.write_entire_file(fmt.tprintf("%s/%s", root, name), text)
}

// The breach of one file of the tree, by the end of its path.
@(private = "file")
breach_of_file :: proc(breaches: []Library_Import_Breach, file_end: string) -> (breach: Library_Import_Breach, found: bool) {
	for item in breaches {
		if strings.has_suffix(item.file, file_end) {
			return item, true
		}
	}
	return {}, false
}

// Which import path the kernel and a contract package can write.
@(test)
library_import_paths_that_the_rule_allows :: proc(t: ^testing.T) {
	for path in ([]string{"base:intrinsics", "base:runtime", "core:testing", "core:math/rand", CONTRACT_IMPORT_START + "ring", CONTRACT_IMPORT_START + "record/inner"}) {
		testing.expectf(t, library_import_is_allowed(path), "%q is an import of the kernel", path)
	}
	for path in ([]string {
			SUPPORT_IMPORT_START + "sentence",
			SOURCE_LIBRARY_IMPORT_START + "contract",
			CONTRACT_IMPORT_START,
			CONTRACT_IMPORT_START + "../support/sentence",
			"../support/sentence",
			"../ring",
			"./beside",
			"beside",
			"vendor:glfw",
			"contract:ring",
			"support:sentence",
			"core:",
			"",
		}) {
		testing.expectf(t, !library_import_is_allowed(path), "%q is not an import of the kernel", path)
	}
}

// A tree where each import is allowed has no breach, and the check counts
// each file and each import of the two folders, and none of the support
// packages.
@(test)
library_imports_of_an_allowed_tree :: proc(t: ^testing.T) {
	root := library_tree_make(t)
	defer os.remove_all(root)
	breaches, file_count, import_count, read_ok := library_import_breaches_of_tree(root)
	testing.expect(t, read_ok)
	testing.expectf(t, len(breaches) == 0, "%v", breaches)
	testing.expect_value(t, file_count, 4)
	testing.expect_value(t, import_count, 6)
}

// The two imports that the compiler refused when the kernel had the
// contract library only: a source of the kernel that imports a support
// package, and a contract package that imports a support package by a
// relative path. Each is refused with its file, its line and its text.
@(test)
library_import_of_a_support_package_is_refused :: proc(t: ^testing.T) {
	root := library_tree_make(t)
	defer os.remove_all(root)
	library_tree_file_write(root, SOURCE_FOLDER_KERNEL + "/report.odin", "package kernel\n\nimport \"base:intrinsics\"\n// A comment.\nimport sentence \"" + SUPPORT_IMPORT_START + "sentence\"\n")
	library_tree_file_write(root, SOURCE_FOLDER_CONTRACT + "/ring/write.odin", "package ring\n\nimport \"../../support/sentence\"\n")
	breaches, _, _, read_ok := library_import_breaches_of_tree(root)
	testing.expect(t, read_ok)
	if !testing.expect_value(t, len(breaches), 2) {
		return
	}
	in_kernel, kernel_found := breach_of_file(breaches, SOURCE_FOLDER_KERNEL + "/report.odin")
	testing.expect(t, kernel_found, "the file of the kernel is not named")
	testing.expect_value(t, in_kernel.line, 5)
	testing.expect_value(t, in_kernel.text, "\"" + SUPPORT_IMPORT_START + "sentence\"")
	sentence := library_import_breach_sentence(in_kernel)
	testing.expect(t, strings.contains(sentence, SOURCE_FOLDER_KERNEL + "/report.odin:5: the import \"" + SUPPORT_IMPORT_START + "sentence\" is refused"), sentence)
	in_contract, contract_found := breach_of_file(breaches, SOURCE_FOLDER_CONTRACT + "/ring/write.odin")
	testing.expect(t, contract_found, "the file of the contract package is not named")
	testing.expect_value(t, in_contract.line, 3)
	testing.expect_value(t, in_contract.text, "\"../../support/sentence\"")
}

// The check reads what the compiler leaves out: an import inside a `when`
// whose condition is false, a file that a build tag leaves out, and a
// test.
@(test)
library_import_that_the_compiler_leaves_out_is_read :: proc(t: ^testing.T) {
	root := library_tree_make(t)
	defer os.remove_all(root)
	library_tree_file_write(root, SOURCE_FOLDER_KERNEL + "/inside_when.odin", "package kernel\n\nwhen false {\n\timport \"" + SUPPORT_IMPORT_START + "sentence\"\n} else {\n\timport \"../beside\"\n}\n")
	library_tree_file_write(root, SOURCE_FOLDER_KERNEL + "/other_system.odin", "#+build windows\npackage kernel\n\nimport \"" + SUPPORT_IMPORT_START + "sentence\"\n")
	library_tree_file_write(root, SOURCE_FOLDER_CONTRACT + "/ring/write_test.odin", "package ring\n\nimport \"core:testing\"\nimport \"" + SUPPORT_IMPORT_START + "sentence\"\n")
	breaches, _, _, read_ok := library_import_breaches_of_tree(root)
	testing.expect(t, read_ok)
	testing.expect_value(t, len(breaches), 4)
	inside_when := 0
	for breach in breaches {
		if strings.has_suffix(breach.file, "/inside_when.odin") {
			inside_when += 1
			testing.expect(t, breach.line == 4 || breach.line == 6, "the line of an import inside a `when`")
		}
	}
	testing.expect_value(t, inside_when, 2)
	other_system, other_found := breach_of_file(breaches, "/other_system.odin")
	testing.expect(t, other_found, "a file that a build tag leaves out is read")
	testing.expect_value(t, other_system.line, 4)
	in_test, test_found := breach_of_file(breaches, "/write_test.odin")
	testing.expect(t, test_found, "a test is read")
	testing.expect_value(t, in_test.line, 4)
}

// The other forms that leave the contract packages: a path that goes up
// from a contract package, a library of the compiler that the project has
// not, and one of the two names that the libraries had.
@(test)
library_import_of_another_form_is_refused :: proc(t: ^testing.T) {
	breaches, import_count := library_import_breaches_of_source("kernel/forms.odin", "package kernel\n\nimport \"" + CONTRACT_IMPORT_START + "../support/sentence\"\nimport \"vendor:glfw\"\nimport \"support:sentence\"\nimport \"core:testing\"\n")
	testing.expect_value(t, import_count, 4)
	if testing.expect_value(t, len(breaches), 3) {
		testing.expect_value(t, breaches[0].line, 3)
		testing.expect_value(t, breaches[1].text, "\"vendor:glfw\"")
		testing.expect_value(t, breaches[2].line, 5)
	}
}

// A file that the parser cannot read whole is refused as a file: an
// import after the error can be unread. An import inside a procedure is
// an error of syntax.
@(test)
library_import_file_that_the_parser_refuses :: proc(t: ^testing.T) {
	broken, _ := library_import_breaches_of_source("kernel/broken.odin", "package kernel\n\nbroken :: proc( {\n")
	if testing.expect_value(t, len(broken), 1) {
		testing.expect_value(t, broken[0].text, "")
		testing.expect_value(t, broken[0].line, 0)
		testing.expect(t, strings.contains(library_import_breach_sentence(broken[0]), "kernel/broken.odin: the parser cannot read the file whole"))
	}
	inside_procedure, _ := library_import_breaches_of_source("kernel/inside.odin", "package kernel\n\nwork :: proc() {\n\timport \"" + SUPPORT_IMPORT_START + "sentence\"\n}\n")
	testing.expect_value(t, len(inside_procedure), 1)
}

// The repository holds the rule: no source of the kernel and of the
// contract packages imports outside the allowed packages.
@(test)
library_imports_of_the_repository :: proc(t: ^testing.T) {
	breaches, file_count, import_count, read_ok := library_import_breaches_of_tree("")
	testing.expect(t, read_ok, "the sources cannot be read")
	for breach in breaches {
		testing.expect(t, false, library_import_breach_sentence(breach))
	}
	testing.expect(t, file_count > 0 && import_count > 0, "the check read no file or no import: a folder of the check is empty")
}

// The command of the example of a program outside the sources names a
// folder outside them, and gives the compiler the one flag of the library
// and no other.
@(test)
third_party_example_is_outside_the_sources :: proc(t: ^testing.T) {
	folders := SOURCE_FOLDERS
	for folder in folders {
		testing.expectf(t, !strings.has_prefix(THIRD_PARTY_EXAMPLE_FOLDER, folder), "%s is under %s", THIRD_PARTY_EXAMPLE_FOLDER, folder)
	}
	testing.expect(t, !strings.has_prefix(THIRD_PARTY_EXAMPLE_FOLDER, "src/"))
	testing.expect(t, os.is_dir(THIRD_PARTY_EXAMPLE_SOURCE), THIRD_PARTY_EXAMPLE_SOURCE)
	flags := 0
	for part in third_party_example_command() {
		if strings.has_prefix(part, "-collection:") {
			flags += 1
			testing.expect_value(t, part, "-collection:modus=src/library")
		}
	}
	testing.expect_value(t, flags, 1)
}
