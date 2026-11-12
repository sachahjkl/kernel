// The data of the site and the helpers that its pages share (docs/SITE.md):
// the pictures of the machine that the home shows, the measured numbers
// and the logs that they come from, and the escape of every text of a file.
// The pages are in site_frame.odin and site_pages.odin.
package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "support:graphics"

SITE_FOLDER :: BUILD_FOLDER + "/site"
SITE_PAGE :: "index.html"
SITE_STYLE_SHEET :: "style.css"
SITE_PICTURE_FOLDER :: "pictures"
// The address of the repository: the one place that names it, because its
// name can change with the name of the system.
SITE_REPOSITORY_ADDRESS :: "https://github.com/sachahjkl/kernel"
SITE_SYSTEM_NAME :: "modus"
SITE_RELEASE_COUNT :: 5
SITE_LICENSE_FILE :: "LICENSE"
SITE_NOT_MEASURED :: "Not measured in this build."
// `kerneltool check` writes here the line of its comparison of two builds.
REPRODUCIBLE_BUILD_RECORD :: BUILD_FOLDER + "/reproducible_build.txt"

// One picture of the section "What runs today". The pictures of one group
// follow each other. A picture of docs/screenshots takes its caption from
// README.md, a file of the mark from the table of docs/DESIGN.md.
Site_Picture :: struct {
	group: string,
	path:  string,
}

site_pictures := [?]Site_Picture {
	{"The desktop", "docs/screenshots/desktop.png"},
	{"The desktop", "docs/screenshots/launcher.png"},
	{"The desktop", "docs/screenshots/menu.png"},
	{"The console", "docs/screenshots/console_completion.png"},
	{"The console", "docs/screenshots/console.png"},
	{"The console", "docs/screenshots/tools.png"},
	{"The monitor and the developer tool", "docs/screenshots/remote.png"},
	{"The monitor and the developer tool", "docs/screenshots/inspect.png"},
	{"The monitor and the developer tool", "docs/screenshots/inspect_stopped.png"},
	{"Isolation, rights and budgets", "docs/screenshots/isolated.png"},
	{"Isolation, rights and budgets", "docs/screenshots/rights.png"},
	{"Isolation, rights and budgets", "docs/screenshots/budget.png"},
	{"The network", "docs/screenshots/network.png"},
	{"The network", "docs/screenshots/server.png"},
	{"The network", "docs/screenshots/server_real.png"},
	{"The storage", "docs/screenshots/storage.png"},
	{"The storage", "docs/screenshots/notes.png"},
	{"The storage", "docs/screenshots/power_loss.png"},
	{"The fonts", "docs/screenshots/font_vector.png"},
	{"The fonts", "docs/screenshots/font_candidates.png"},
}

// Which line a number takes when the log has several lines with its text.
Site_Line_Choice :: enum {
	First,
	Last,
}

// The section of the page that shows a number.
Site_Measure_Place :: enum {
	Numbers,
	Build,
}

// One measured number: its sentence for the reader, the logs where a
// program printed it, and a part of the text of that line. The first log
// that has the line gives it. The page quotes the whole line: the line
// gives its own conditions (the count, the size, the unit).
Site_Measure :: struct {
	sentence: string,
	files:    [2]string, // "" for no second log.
	pattern:  string,
	choice:   Site_Line_Choice,
	accent:   graphics.Color, // The color of the concept that the number measures.
	place:    Site_Measure_Place,
}

site_measures := [?]Site_Measure {
	{sentence = "Kernel entries in one second, with 1, 2 and 4 programs that each take the locks of their own objects", files = {TEST_OUTPUT_MEASURE, TEST_OUTPUT}, pattern = "locks: kernel entries in one second", choice = .First, accent = graphics.COLOR_KERNEL, place = .Numbers},
	{sentence = "Reads of the time in one second from the time page, with no kernel entry", files = {TEST_OUTPUT, ""}, pattern = "clock: the time page:", choice = .First, accent = graphics.COLOR_KERNEL, place = .Numbers},
	{sentence = "Wakes in one second of two threads that wake each other on a busy machine, under the strategy EEVDF", files = {TEST_OUTPUT, ""}, pattern = "scheduler: EEVDF: two threads that wake each other", choice = .First, accent = graphics.COLOR_KERNEL, place = .Numbers},
	{sentence = "One glyph of the vector font, from its outline and from the glyph cache", files = {TEST_OUTPUT, ""}, pattern = "vector_glyphs: one glyph from its outline", choice = .First, accent = graphics.COLOR_PROGRAM, place = .Numbers},
	{sentence = "A full frame of the compositor", files = {TEST_OUTPUT, ""}, pattern = "compositor: a full frame of", choice = .Last, accent = graphics.COLOR_PROGRAM, place = .Numbers},
	{sentence = "Blocks read in one second from a virtio disk, through the block service in user space", files = {TEST_OUTPUT, ""}, pattern = "disk: read, 1 block in each request, 32 in flight", choice = .First, accent = graphics.COLOR_MEMORY, place = .Numbers},
	{sentence = "1000 commits of a program to its private store, one commit for each step", files = {BUILD_FOLDER + "/test_output_persist_1.txt", ""}, pattern = "notes: count 1000, stopped", choice = .First, accent = graphics.COLOR_MEMORY, place = .Numbers},
	{sentence = "The headers and the checksum of one UDP datagram, in the network service", files = {TEST_OUTPUT_NETWORK, ""}, pattern = "network: the headers and the checksum of a datagram", choice = .First, accent = graphics.COLOR_MACHINE, place = .Numbers},
	{sentence = "The round trip of one UDP datagram", files = {TEST_OUTPUT_NETWORK, ""}, pattern = "net: the round trip of one datagram", choice = .First, accent = graphics.COLOR_MACHINE, place = .Numbers},
	{sentence = "UDP datagrams in one second, with 64 in flight", files = {TEST_OUTPUT_NETWORK, ""}, pattern = "net: a burst with 64 datagrams in flight", choice = .First, accent = graphics.COLOR_MACHINE, place = .Numbers},
	{sentence = "TCP: 1 MiB that the program `fetch` receives from a server of the host", files = {TEST_OUTPUT_TCP_REAL, ""}, pattern = "fetch: GET /large:", choice = .First, accent = graphics.COLOR_MACHINE, place = .Numbers},
	{sentence = "TCP: 1 MiB that the program `fetch` sends to a server of the host", files = {TEST_OUTPUT_TCP_REAL, ""}, pattern = "fetch: POST /sink, 1 MiB", choice = .First, accent = graphics.COLOR_MACHINE, place = .Numbers},
	{sentence = "ChaCha20-Poly1305: the seal of one QUIC datagram of 1200 bytes, through the module `cryptography`", files = {TEST_OUTPUT_CRYPTOGRAPHY, ""}, pattern = "cryptography_vectors: seal ChaCha20-Poly1305", choice = .First, accent = graphics.COLOR_PROGRAM, place = .Numbers},
	{sentence = "The same bytes after a second build", files = {REPRODUCIBLE_BUILD_RECORD, ""}, pattern = "the same bytes after a second build", choice = .Last, accent = graphics.COLOR_KERNEL, place = .Build},
}

// What each log is: the machine that wrote it and what else ran.
Site_Output_File :: struct {
	path:       string,
	conditions: string,
}

site_output_files := [?]Site_Output_File {
	{TEST_OUTPUT_MEASURE, "The machine of `kerneltool measure`: only the desktop and the program that measures run"},
	{TEST_OUTPUT, "The main machine of `kerneltool test`, while the other programs of the test run"},
	{TEST_OUTPUT_NETWORK, "The network machine of `kerneltool test`: the remote is the peer of the tool, on the loopback of the host"},
	{TEST_OUTPUT_TCP_REAL, "The machine of `kerneltool test` with QEMU user networking: the remote is the TCP of the host, through libslirp"},
	{TEST_OUTPUT_CRYPTOGRAPHY, "The machine of `kerneltool test crypto`"},
	{BUILD_FOLDER + "/test_output_persist_1.txt", "The first machine of the test of persistence of `kerneltool test`, on a new data disk"},
	{REPRODUCIBLE_BUILD_RECORD, "Written by `kerneltool check`, after it built every module and the boot program a second time and compared the bytes"},
}

// One number as the page shows it.
Site_Measured :: struct {
	measure:        Site_Measure,
	found:          bool,
	path:           string,
	conditions:     string,
	line_number:    int,
	matching_lines: int,
	text:           string, // The line, with no "[program] " label.
	written:        string, // The time of the log, in UTC.
	missing:        string, // Why the number is absent.
}

// One picture as the page shows it.
Site_Figure :: struct {
	group:     string,
	file_name: string, // In the picture folder of the site.
	caption:   string,
	width:     int,
	height:    int,
	pixelated: bool,
}

Site_Accent :: struct {
	class_name: string,
	color:      graphics.Color,
}

site_accents := [?]Site_Accent {
	{"accent-kernel", graphics.COLOR_KERNEL},
	{"accent-program", graphics.COLOR_PROGRAM},
	{"accent-memory", graphics.COLOR_MEMORY},
	{"accent-machine", graphics.COLOR_MACHINE},
	{"accent-boot", graphics.COLOR_BOOT_PROGRAM},
	{"accent-firmware", graphics.COLOR_FIRMWARE},
}

// site_read reads one text file of the repository.
site_read :: proc(path: string) -> (text: string, ok: bool) {
	data := read_file(path) or_return
	return string(data), true
}

// site_file_name gives the name of a file after the last "/" of its path.
site_file_name :: proc(path: string) -> string {
	return path[strings.last_index_byte(path, '/') + 1:]
}

// site_png_size reads the width and the height of a PNG file from its
// header chunk, which the format puts first.
site_png_size :: proc(data: []u8) -> (width, height: int, ok: bool) {
	signature := [8]u8{0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n'}
	if len(data) < 24 {
		return 0, 0, false
	}
	for index in 0 ..< len(signature) {
		if data[index] != signature[index] {
			return 0, 0, false
		}
	}
	if string(data[12:16]) != "IHDR" {
		return 0, 0, false
	}
	big_endian :: proc(bytes: []u8) -> int {
		return int(bytes[0]) << 24 | int(bytes[1]) << 16 | int(bytes[2]) << 8 | int(bytes[3])
	}
	return big_endian(data[16:20]), big_endian(data[20:24]), true
}

// site_without_program_label takes the label "[program] " or
// "[program:channel] " of the log off a line.
site_without_program_label :: proc(line: string) -> string {
	if strings.has_prefix(line, "[") {
		if end := strings.index(line, "] "); end > 0 {
			return line[end + 2:]
		}
	}
	return line
}

// site_line_choose finds the lines of a log that contain the pattern, and
// gives the first or the last one.
site_line_choose :: proc(content, pattern: string, choice: Site_Line_Choice) -> (text: string, line_number, matching_lines: int) {
	for line, index in site_lines(content) {
		if !strings.contains(line, pattern) {
			continue
		}
		matching_lines += 1
		if matching_lines == 1 || choice == .Last {
			text = site_without_program_label(line)
			line_number = index + 1
		}
	}
	return
}

// site_file_time gives the time of the last change of a file, in UTC.
site_file_time :: proc(path: string) -> string {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return ""
	}
	year, month, day := time.date(info.modification_time)
	hour, minute, _ := time.clock(info.modification_time)
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d UTC", year, int(month), day, hour, minute)
}

site_output_conditions :: proc(path: string) -> string {
	for output in site_output_files {
		if output.path == path {
			return output.conditions
		}
	}
	return ""
}

site_measure_read :: proc(measure: Site_Measure) -> (measured: Site_Measured) {
	measured.measure = measure
	reasons := make([dynamic]string, context.temp_allocator)
	for path in measure.files {
		if path == "" {
			continue
		}
		if !os.exists(path) {
			append(&reasons, fmt.tprintf("%s: no file", path))
			continue
		}
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			append(&reasons, fmt.tprintf("%s: cannot read: %v", path, err))
			continue
		}
		text, line_number, matching_lines := site_line_choose(string(data), measure.pattern, measure.choice)
		if matching_lines == 0 {
			append(&reasons, fmt.tprintf("%s: no line with \"%s\"", path, measure.pattern))
			continue
		}
		measured.found = true
		measured.path = path
		measured.conditions = site_output_conditions(path)
		measured.line_number = line_number
		measured.matching_lines = matching_lines
		measured.text = text
		measured.written = site_file_time(path)
		return
	}
	measured.missing = strings.join(reasons[:], "; ", context.temp_allocator)
	return
}

// site_escape writes a text of a file as HTML text: each character that
// HTML reads as markup becomes its reference.
site_escape :: proc(builder: ^strings.Builder, text: string) {
	for index in 0 ..< len(text) {
		switch text[index] {
		case '&':
			strings.write_string(builder, "&amp;")
		case '<':
			strings.write_string(builder, "&lt;")
		case '>':
			strings.write_string(builder, "&gt;")
		case '"':
			strings.write_string(builder, "&quot;")
		case '\'':
			strings.write_string(builder, "&#39;")
		case:
			strings.write_byte(builder, text[index])
		}
	}
}

// site_inline writes a line of Markdown as HTML: `code`, **bold**, and the
// text of a link [text](address) with no link, because the address names a
// file of the repository that the site does not have. Every other character
// is escaped.
site_inline :: proc(builder: ^strings.Builder, text: string) {
	bold_open := false
	index := 0
	for index < len(text) {
		character := text[index]
		if character == '`' {
			end := strings.index_byte(text[index + 1:], '`')
			if end >= 0 {
				strings.write_string(builder, "<code>")
				site_escape(builder, text[index + 1:index + 1 + end])
				strings.write_string(builder, "</code>")
				index += end + 2
				continue
			}
		}
		if character == '*' && index + 1 < len(text) && text[index + 1] == '*' {
			strings.write_string(builder, bold_open ? "</strong>" : "<strong>")
			bold_open = !bold_open
			index += 2
			continue
		}
		if character == '[' {
			closing := strings.index_byte(text[index + 1:], ']')
			if closing >= 0 {
				after := index + 1 + closing + 1
				if after < len(text) && text[after] == '(' {
					end := strings.index_byte(text[after + 1:], ')')
					if end >= 0 {
						site_inline(builder, text[index + 1:index + 1 + closing])
						index = after + 1 + end + 1
						continue
					}
				}
			}
		}
		site_escape(builder, text[index:index + 1])
		index += 1
	}
	if bold_open {
		strings.write_string(builder, "</strong>")
	}
}

// site_inline_text gives the HTML of a line of Markdown.
site_inline_text :: proc(text: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	site_inline(&builder, text)
	return strings.to_string(builder)
}

// site_plain writes a line of Markdown as escaped plain text, for an
// attribute: the marks of code and bold go away.
site_plain :: proc(builder: ^strings.Builder, text: string) {
	without_code, _ := strings.remove_all(text, "`", context.temp_allocator)
	without_bold, _ := strings.remove_all(without_code, "**", context.temp_allocator)
	site_escape(builder, without_bold)
}

site_accent_class :: proc(color: graphics.Color) -> string {
	for accent in site_accents {
		if accent.color == color {
			return accent.class_name
		}
	}
	return site_accents[0].class_name
}

