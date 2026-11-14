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
SOURCE_FOLDER_CONTRACT :: "src/library/contract" // The contract packages.
SOURCE_FOLDER_SUPPORT :: "src/library/support" // The support packages.

// Each folder of the sources of the system. A list of the tool that reads
// a part of them names its folders by their constants, in its own order:
// the order of a list can be the order of an output.
SOURCE_FOLDERS :: [?]string{SOURCE_FOLDER_KERNEL, SOURCE_FOLDER_BOOT, SOURCE_FOLDER_RUNTIME, SOURCE_FOLDER_PROGRAMS, SOURCE_FOLDER_MODULES, SOURCE_FOLDER_CONTRACT, SOURCE_FOLDER_SUPPORT}

// The names of the two source libraries: the word before the ":" of an
// import line (docs/GLOSSARY.md, "Source library"). A name is not a
// folder: the flag of the compiler joins the two.
CONTRACT_LIBRARY_NAME :: "contract"
SUPPORT_LIBRARY_NAME :: "support"

// A source library: its name in an import line, and its folder.
Source_Library :: struct {
	name:   string,
	folder: string,
}

SOURCE_LIBRARIES :: [?]Source_Library{{name = CONTRACT_LIBRARY_NAME, folder = SOURCE_FOLDER_CONTRACT}, {name = SUPPORT_LIBRARY_NAME, folder = SOURCE_FOLDER_SUPPORT}}

// source_library_package_folder gives the folder of the package that the
// path of an import line names in a source library: "contract:ring" is the
// folder ring of the contract packages. A path of another library
// ("core:fmt") and a relative path are not found.
source_library_package_folder :: proc(import_path: string, allocator := context.temp_allocator) -> (folder: string, found: bool) {
	libraries := SOURCE_LIBRARIES
	for library in libraries {
		if len(import_path) > len(library.name) + 1 && strings.has_prefix(import_path, library.name) && import_path[len(library.name)] == ':' {
			return strings.concatenate({library.folder, "/", import_path[len(library.name) + 1:]}, allocator), true
		}
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
