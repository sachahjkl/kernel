// The folders of the sources of the system: the one place of the tool that
// writes where each is (src/md/infrastructure/repository_layout.md). Each
// other path of a source in the tool is made from these constants, so the
// move of a folder is a change of one line of this file. A path that is
// written as text in another file is a folder that a check no longer reads
// after a move, with no error.
package kerneltool

import "core:strings"

SOURCE_FOLDER_KERNEL :: "src/kernel" // The kernel.
SOURCE_FOLDER_BOOT :: "src/boot" // The boot program.
SOURCE_FOLDER_RUNTIME :: "src/runtime" // The memory procedures in assembly.
SOURCE_FOLDER_PROGRAMS :: "src/programs" // The programs of the system: one folder for each.
SOURCE_FOLDER_MODULES :: "src/modules" // The modules that are not programs: one folder for each.
SOURCE_FOLDER_LIBRARY :: "src/library" // The source library of the system: the two folders below, and nothing else.
SOURCE_FOLDER_CONTRACT :: SOURCE_FOLDER_LIBRARY + "/" + LIBRARY_PART_CONTRACT // The contract packages.
SOURCE_FOLDER_SUPPORT :: SOURCE_FOLDER_LIBRARY + "/" + LIBRARY_PART_SUPPORT // The support packages.

// Each folder of the sources of the system. A list of the tool that reads
// a part of them names its folders by their constants, in its own order:
// the order of a list can be the order of an output.
SOURCE_FOLDERS :: [?]string{SOURCE_FOLDER_KERNEL, SOURCE_FOLDER_BOOT, SOURCE_FOLDER_RUNTIME, SOURCE_FOLDER_PROGRAMS, SOURCE_FOLDER_MODULES, SOURCE_FOLDER_CONTRACT, SOURCE_FOLDER_SUPPORT}

// The name of the one source library of the system: the word before the
// ":" of an import line (docs/GLOSSARY.md, "Source library"). The name is
// not the folder: the flag of the compiler joins the two.
SOURCE_LIBRARY_NAME :: "modus"

// The two parts of the library: the first folder of the path of a
// package, after the ":" of an import line.
LIBRARY_PART_CONTRACT :: "contract" // What two parties agree on.
LIBRARY_PART_SUPPORT :: "support" // What a program compiles in to use the contracts.

// The start of the path of an import of each part: "modus:contract/ring",
// "modus:support/system".
SOURCE_LIBRARY_IMPORT_START :: SOURCE_LIBRARY_NAME + ":"
CONTRACT_IMPORT_START :: SOURCE_LIBRARY_IMPORT_START + LIBRARY_PART_CONTRACT + "/"
SUPPORT_IMPORT_START :: SOURCE_LIBRARY_IMPORT_START + LIBRARY_PART_SUPPORT + "/"

// The one flag of the compiler for the library. Each command of the tool
// that runs the compiler gives it, the compile of the kernel too: flake.nix
// gives the same flag when it builds this tool, and a program outside the
// repository gives it with the path of this folder. With one library the
// compiler accepts an import of a support package in the kernel, so the
// tool refuses it before the first compiler starts
// (library_imports_check.odin).
SOURCE_LIBRARY_FLAG :: "-collection:" + SOURCE_LIBRARY_NAME + "=" + SOURCE_FOLDER_LIBRARY

// source_library_package_folder gives the folder of the package that the
// path of an import line names in the source library:
// "modus:contract/ring" is the folder ring of the contract packages. A
// path of another library ("core:fmt") and a relative path are not found.
source_library_package_folder :: proc(import_path: string, allocator := context.temp_allocator) -> (folder: string, found: bool) {
	if len(import_path) > len(SOURCE_LIBRARY_IMPORT_START) && strings.has_prefix(import_path, SOURCE_LIBRARY_IMPORT_START) {
		return strings.concatenate({SOURCE_FOLDER_LIBRARY, "/", import_path[len(SOURCE_LIBRARY_IMPORT_START):]}, allocator), true
	}
	return "", false
}

// path_from_folder_to_root gives the relative path from a folder of the
// repository to its root: "../" for each part of the path of the folder.
// The compiler reads the path of a `#load` from the folder of the source
// that holds it, and the tool names a file from the root.
path_from_folder_to_root :: proc(folder: string) -> string {
	parts := strings.count(strings.trim_suffix(folder, "/"), "/") + 1
	path := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< parts {
		strings.write_string(&path, "../")
	}
	return strings.to_string(path)
}
