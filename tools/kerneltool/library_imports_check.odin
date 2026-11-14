// The check of the imports of the kernel and of the contract packages
// (docs/TOOLS.md, "The imports of the kernel and of the contract packages").
//
// The system has one source library, so the compiler accepts each of its
// packages in each source: an import of a support package compiles in the
// kernel. The rule that the kernel imports the contract packages only, and
// that a contract package imports no support package, is held here. The
// tool reads each import of each source file of the two folders. If no file
// of the two folders imports outside the allowed packages, no chain of
// imports from the kernel reaches a support package.
//
// The reader is the parser of the library of the compiler. It reads each
// file of the two folders, a test and a file that a build tag leaves out
// too, and an import inside a `when` whatever its condition: the check is
// stricter than the compiler, never looser.
package kerneltool

import "core:fmt"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:slice"
import "core:strings"

// The folders whose imports the check reads, with each folder under them.
LIBRARY_IMPORT_CHECKED_FOLDERS :: [?]string{SOURCE_FOLDER_KERNEL, SOURCE_FOLDER_CONTRACT}

// What the path of an allowed import starts with: the base library and the
// core library of the compiler, and the contract packages. A test of a
// contract package runs on the host and imports the test package of the
// core library. The vendor library of the compiler is not allowed: the
// compiler of the project has none.
LIBRARY_IMPORT_ALLOWED_STARTS :: [?]string{"base:", "core:", CONTRACT_IMPORT_START}

// One refused import, or one file that the parser cannot read whole.
Library_Import_Breach :: struct {
	file: string,
	line: int, // 0: the parser refuses the file.
	text: string, // The import as the source writes it, with its quotes. "": the parser refuses the file.
}

// library_import_is_allowed tells whether the path of an import, with no
// quotes, names a package that the kernel and a contract package can
// import. A path with ".." is refused: "modus:contract/../support/system"
// starts as a contract package and names a support package.
library_import_is_allowed :: proc(path: string) -> bool {
	if strings.contains(path, "..") {
		return false
	}
	starts := LIBRARY_IMPORT_ALLOWED_STARTS
	for start in starts {
		if len(path) > len(start) && strings.has_prefix(path, start) {
			return true
		}
	}
	return false
}

// library_import_breaches_of_source gives each refused import of one
// source file. A file with an error of syntax is one breach: the parser
// does not read it whole, so an import of it can be unread. An import
// inside a procedure is such an error.
library_import_breaches_of_source :: proc(file, source: string) -> (breaches: []Library_Import_Breach, import_count: int) {
	list := make([dynamic]Library_Import_Breach, context.temp_allocator)
	// The tree of the parser lives in an arena of its own, freed before
	// the next file: a breach keeps only copies of its texts.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		append(&list, Library_Import_Breach{file = file})
		return list[:], 0
	}
	defer virtual.arena_destroy(&arena)
	{
		context.allocator = virtual.arena_allocator(&arena)
		tree := ast.new_from_positions(ast.File, {}, {})
		tree.src = source
		tree.fullpath = file
		reader := parser.default_parser()
		// The check reports a file that the parser refuses in its own words.
		reader.err = site_code_quiet_error
		reader.warn = site_code_quiet_error
		if !parser.parse_file(&reader, tree) || tree.syntax_error_count > 0 {
			append(&list, Library_Import_Breach{file = file})
			return list[:], 0
		}
		import_count = len(tree.imports)
		for declaration in tree.imports {
			text := declaration.relpath.text
			if library_import_is_allowed(strings.trim(text, "\"`")) {
				continue
			}
			append(&list, Library_Import_Breach{file = file, line = declaration.relpath.pos.line, text = strings.clone(text, context.temp_allocator)})
		}
	}
	return list[:], import_count
}

// library_import_breaches_of_tree reads each source file of the checked
// folders of a tree. root is the folder of the tree: "" is the folder
// where the tool runs, the root of the repository.
library_import_breaches_of_tree :: proc(root: string) -> (breaches: []Library_Import_Breach, file_count: int, import_count: int, ok: bool) {
	files := make([dynamic]string, context.temp_allocator)
	folders := LIBRARY_IMPORT_CHECKED_FOLDERS
	for folder in folders {
		source_files_of_a_folder(root == "" ? folder : join(root, "/", folder), &files) or_return
	}
	slice.sort(files[:])
	list := make([dynamic]Library_Import_Breach, context.temp_allocator)
	for file in files {
		source, read_ok := site_read_quiet(file)
		if !read_ok {
			fmt.eprintfln("kerneltool: cannot read %s", file)
			return nil, 0, 0, false
		}
		file_breaches, file_imports := library_import_breaches_of_source(file, source)
		append(&list, ..file_breaches)
		import_count += file_imports
	}
	return list[:], len(files), import_count, true
}

// library_import_breach_sentence gives the line of the output for one
// breach: the file and the line first, as the compiler writes an error.
library_import_breach_sentence :: proc(breach: Library_Import_Breach) -> string {
	if breach.text == "" {
		return fmt.tprintf("%s: the parser cannot read the file whole, so its imports are not checked: a source of %s and of %s has no error of syntax, and no import inside a procedure", breach.file, SOURCE_FOLDER_KERNEL, SOURCE_FOLDER_CONTRACT)
	}
	return fmt.tprintf("%s:%d: the import %s is refused: a source of %s and of %s imports a package of base:, of core: or under %s only, by a path with no \"..\"; the kernel and a contract package import no support package", breach.file, breach.line, breach.text, SOURCE_FOLDER_KERNEL, SOURCE_FOLDER_CONTRACT, CONTRACT_IMPORT_START)
}

// library_imports_hold reads the repository and prints each breach. Each
// build calls it before its first compiler starts: the build stops with
// the file and the line, as it stopped when the compiler refused the
// import.
library_imports_hold :: proc() -> (file_count: int, import_count: int, hold: bool) {
	breaches, files, imports, read_ok := library_import_breaches_of_tree("")
	if !read_ok {
		return 0, 0, false
	}
	for breach in breaches {
		fmt.eprintfln("kerneltool: %s", library_import_breach_sentence(breach))
	}
	return files, imports, len(breaches) == 0
}

// library_imports_check is the check of `kerneltool check` and of the
// command `library-imports`.
library_imports_check :: proc() -> bool {
	file_count, import_count, hold := library_imports_hold()
	if !hold {
		fmt.eprintln("kerneltool: test failed: an import of the kernel or of a contract package is refused")
		return false
	}
	test_passed_print("each of the %d imports of the %d source files of %s and of %s names a package of base:, of core: or under %s", import_count, file_count, SOURCE_FOLDER_KERNEL, SOURCE_FOLDER_CONTRACT, CONTRACT_IMPORT_START)
	return true
}

run_library_imports :: proc(args: []string) -> int {
	return library_imports_check() ? 0 : EXIT_FAILURE
}

// The example of a program outside the sources of the system
// (docs/TOOLS.md, "A program outside the sources"). The tool copies the
// sources of one small program of the system to a folder outside the
// sources, with no change, and runs the check of the compiler on the copy
// with the one flag of the library. It proves two things: a program
// imports the library with the same lines inside the sources and outside
// them, and no source of the program needs a relative path to the library.
// It does not build a module from the copy: the build of a module whose
// source is outside the repository has no design.
THIRD_PARTY_EXAMPLE_PROGRAM :: "tally"
THIRD_PARTY_EXAMPLE_SOURCE :: SOURCE_FOLDER_PROGRAMS + "/" + THIRD_PARTY_EXAMPLE_PROGRAM
THIRD_PARTY_EXAMPLE_FOLDER :: BUILD_FOLDER + "/third_party_example/" + THIRD_PARTY_EXAMPLE_PROGRAM

// third_party_example_command gives the command of the compiler for the
// copy: the target and the allocator of a module (module_compile_command),
// and the one flag of the library.
third_party_example_command :: proc() -> []string {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, "odin", "check", THIRD_PARTY_EXAMPLE_FOLDER, "-target:freestanding_amd64_sysv", "-no-entry-point", "-default-to-nil-allocator", "-vet", SOURCE_LIBRARY_FLAG)
	return command[:]
}

third_party_example_check :: proc() -> bool {
	reset_folder(THIRD_PARTY_EXAMPLE_FOLDER) or_return
	sources := files_with_suffix(THIRD_PARTY_EXAMPLE_SOURCE, ".odin") or_return
	if len(sources) == 0 {
		fmt.eprintfln("kerneltool: test failed: %s has no source file", THIRD_PARTY_EXAMPLE_SOURCE)
		return false
	}
	for source in sources {
		copied_file := join(THIRD_PARTY_EXAMPLE_FOLDER, source[strings.last_index_byte(source, '/'):])
		if copy_error := os.copy_file(copied_file, source); copy_error != nil {
			fmt.eprintfln("kerneltool: test failed: cannot copy %s to %s: %v", source, copied_file, copy_error)
			return false
		}
	}
	if !run(third_party_example_command()) {
		fmt.eprintfln("kerneltool: test failed: the copy of %s in %s does not pass the check of the compiler with the one flag %s", THIRD_PARTY_EXAMPLE_SOURCE, THIRD_PARTY_EXAMPLE_FOLDER, SOURCE_LIBRARY_FLAG)
		return false
	}
	test_passed_print("the %d source files of %s, copied with no change to %s, pass the check of the compiler with the one flag %s", len(sources), THIRD_PARTY_EXAMPLE_SOURCE, THIRD_PARTY_EXAMPLE_FOLDER, SOURCE_LIBRARY_FLAG)
	return true
}
