package kerneltool

import "contract:blake3"
import "core:strings"
import "core:testing"

// The line of a source place: the text only from a file with the hash of
// the build.
@(test)
call_source_line_is_shown_only_from_a_file_with_the_hash :: proc(t: ^testing.T) {
	content := "package one\n\nfirst :: 1\r\nsecond :: 2"
	bytes := transmute([]u8)content
	hash := blake3.hash(bytes)
	good := hex_of(hash[:])
	testing.expect_value(t, source_line_sentence("programs/one/main.odin", 3, good, bytes, true), "source: programs/one/main.odin:3: first :: 1")
	// The last line has no end of line.
	testing.expect_value(t, source_line_sentence("programs/one/main.odin", 4, good, bytes, true), "source: programs/one/main.odin:4: second :: 2")
	testing.expect_value(t, source_line_sentence("programs/one/main.odin", 2, good, bytes, true), "source: programs/one/main.odin:2: ")
	testing.expect(t, strings.contains(source_line_sentence("programs/one/main.odin", 5, good, bytes, true), "the file has no such line"))
	// Another content: the line of that number is not the line of the code.
	changed := transmute([]u8)string("package one\n\nfirst :: 3\n")
	shown := source_line_sentence("programs/one/main.odin", 3, good, changed, true)
	testing.expect(t, strings.contains(shown, "the file changed since the build of the module") && !strings.contains(shown, "first"), shown)
	testing.expect(t, strings.contains(source_line_sentence("programs/one/main.odin", 3, good, nil, false), "the repository has no such file"))
	testing.expect(t, strings.contains(source_line_sentence("programs/one/main.odin", 3, "", bytes, true), "the build did not hash the file"))
}

// A path that a machine gave stays under the root of the repository.
@(test)
call_source_path_stays_in_the_repository :: proc(t: ^testing.T) {
	testing.expect(t, source_path_is_of_the_repository("programs/debug_target/main.odin"))
	for path in ([]string{"", "/etc/passwd", "../outside.odin", "programs/../../outside.odin", "base:runtime/print.odin"}) {
		testing.expectf(t, !source_path_is_of_the_repository(path), "%q is refused", path)
		testing.expect(t, strings.contains(source_line_sentence(path, 1, "", nil, false), "not a file of the repository"))
	}
	// A path with a control byte is not printed: it would forge a line of
	// the terminal of the host.
	forged := source_line_sentence("programs/a\x1b[2J.odin", 1, "", nil, false)
	testing.expect(t, !strings.contains(forged, "\x1b") && strings.contains(forged, "not a visible character"), forged)
}

@(test)
call_source_line_of_content :: proc(t: ^testing.T) {
	text, found := source_line_of_content("a\nb\n", 2)
	testing.expect(t, found && text == "b")
	_, found = source_line_of_content("a\nb\n", 3)
	testing.expect(t, !found)
	_, found = source_line_of_content("a\nb\n", 0)
	testing.expect(t, !found)
	_, found = source_line_of_content("", 1)
	testing.expect(t, !found)
}

// The line of add_step that the scenario of the debugger names is the
// line of the store in the file.
@(test)
debugger_scenario_names_the_line_of_debug_target :: proc(t: ^testing.T) {
	content, read := read_file("programs/debug_target/main.odin")
	if !testing.expect(t, read, "programs/debug_target/main.odin is read") {
		return
	}
	testing.expect_value(t, DEBUG_TARGET_LINE_OF_THE_STORE, "79")
	store, store_found := source_line_of_content(string(content), 79)
	testing.expect(t, store_found && store == DEBUG_TARGET_TEXT_OF_THE_STORE, store)
}
