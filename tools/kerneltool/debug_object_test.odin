package kerneltool

import debug_object "modus:contract/debug_object"
import "core:strings"
import "core:testing"

// The object of one procedure with one row of a source file.
@(private = "file")
object_with_path :: proc(path: string) -> []u8 {
	procedures := []Debug_Procedure{{start = 0x1000, size = 0x10, name = "fault::three"}}
	rows := []Debug_Row{{address = 0x1000, path = path, line = 15}, {address = 0x1010}}
	object, error := debug_object_encode(procedures, rows, 0x2000, {}, nil, {})
	return error == "" ? object : nil
}

// A path of a debug object never shows the folders of the build host: an
// absolute path, a part "..", and the folder of the build are refused,
// and the path of a file of the repository is kept.
@(test)
a_path_of_the_host_is_refused :: proc(t: ^testing.T) {
	kept := object_with_path("programs/fault/main.odin")
	testing.expect(t, kept != nil && debug_object.check(kept) == .None)
	testing.expect_value(t, debug_object_host_path(kept), "")
	for path in ([]string{"/home/someone/kernel/programs/fault/main.odin", "../outside/main.odin", "programs/../../main.odin", ".."}) {
		object := object_with_path(path)
		testing.expectf(t, object != nil && debug_object_host_path(object) != "", "the path %s is refused", path)
		testing.expectf(t, debug_object.check(object) == .File_Path || strings.has_prefix(path, "/"), "the check refuses the path %s", path)
	}
	// A relative path with the parts "." and "..." is a path of the repository.
	testing.expect_value(t, debug_path("programs/fault", "main.odin", "/build/source"), "programs/fault/main.odin")
	testing.expect_value(t, debug_path("/build/source/programs/fault", "main.odin", "/build/source"), "programs/fault/main.odin")
	testing.expect_value(t, debug_path("", "./support/system/text.odin", "/build/source"), "support/system/text.odin")
	testing.expect(t, !debug_object.path_has_parent_part("a/.../b"))
}
