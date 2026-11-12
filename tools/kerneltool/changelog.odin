// The changelog of the system (docs/GLOSSARY.md, "Changelog", "Release",
// "Fragment"). CHANGELOG.md holds the releases, newest first, in the format
// of Keep a Changelog 1.1.0. A branch never edits it: it adds fragments in
// changelog.d/, one file for each change that a reader notices, so two
// branches never change the same lines. `kerneltool changelog release`
// moves the fragments into a new release.
//
//   kerneltool changelog new <type> <subject> "<text>"   write one fragment
//   kerneltool changelog new <type> <subject> -          the same, with the text from the standard input
//   kerneltool changelog check                           every fragment and CHANGELOG.md well formed
//   kerneltool changelog assemble                        print what the next release brings
//   kerneltool changelog release <release number>        write the release, set RELEASE_NUMBER, delete the fragments
//   kerneltool changelog notes <release number>          print one release
//
// The structure of CHANGELOG.md is strict, so that a later page of a site
// can be made from it: `check` refuses each line that is not in its place.
package kerneltool

import "contract:release"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"

CHANGELOG_FILE :: "CHANGELOG.md"
FRAGMENT_FOLDER :: "changelog.d"
// The one file of the fragment folder that is not a fragment.
FRAGMENT_FOLDER_GUIDE :: "README.md"
RELEASE_NUMBER_SOURCE :: "contract/release/release.odin"
RELEASE_NUMBER_LINE_START :: "RELEASE_NUMBER :: "
CHANGELOG_TITLE :: "# Changelog"
// The longest subject of a fragment name.
FRAGMENT_SUBJECT_MOST :: 48
// "yyyymmdd-hhmmss-": the time at the start of a fragment name.
FRAGMENT_TIME_LENGTH :: 16

// The types of change of Keep a Changelog, in the order of the parts of a release.
CHANGE_TYPES :: [6]string{"Added", "Changed", "Deprecated", "Removed", "Fixed", "Security"}

Release_Number :: struct {
	major, minor, patch: int,
}

// One fragment: one change, as one entry of a release.
Fragment :: struct {
	file_name:  string,
	type_index: int, // An index of CHANGE_TYPES.
	// The lines of the entry, with no "- " and no indentation.
	lines:      []string,
}

// One entry of a release of CHANGELOG.md.
Changelog_Entry :: struct {
	type_index: int,
	lines:      []string,
	line:       int, // The line of its "- ", from 1.
}

Changelog_Release :: struct {
	number:  Release_Number,
	date:    string, // yyyy-mm-dd
	line:    int, // The line of its heading, from 1.
	entries: []Changelog_Entry,
}

Changelog :: struct {
	lines:              []string,
	// The index in lines of the heading of the newest release, or len(lines).
	first_release_line: int,
	releases:           []Changelog_Release, // Newest first.
}

run_changelog :: proc(args: []string) -> int {
	usage_text :: "kerneltool changelog new <type> <subject> \"<text>\" | check | assemble | release <release number> | notes <release number>"
	if len(args) == 0 {
		fmt.eprintln(usage_text)
		return EXIT_USAGE
	}
	switch args[0] {
	case "new":
		if len(args) != 4 {
			fmt.eprintln("kerneltool: changelog new <type> <subject> \"<text>\": three arguments are expected")
			return EXIT_USAGE
		}
		text := args[3]
		// "-": the text comes from the standard input. `odin run` gives
		// the arguments to a shell, which runs the `...` of a text.
		if text == "-" {
			input, err := os.read_entire_file(os.stdin, context.temp_allocator)
			if err != nil {
				fmt.eprintfln("kerneltool: cannot read the standard input: %v", err)
				return EXIT_FAILURE
			}
			text = string(input)
		}
		return changelog_new(args[1], args[2], text) ? 0 : EXIT_FAILURE
	case "check":
		return changelog_check() ? 0 : EXIT_FAILURE
	case "assemble":
		return changelog_assemble() ? 0 : EXIT_FAILURE
	case "release":
		if len(args) != 2 {
			fmt.eprintln("kerneltool: changelog release <release number>: one argument is expected, such as 0.59.0")
			return EXIT_USAGE
		}
		return changelog_release(args[1]) ? 0 : EXIT_FAILURE
	case "notes":
		if len(args) != 2 {
			fmt.eprintln("kerneltool: changelog notes <release number>: one argument is expected, such as 0.58.0")
			return EXIT_USAGE
		}
		return changelog_notes(args[1]) ? 0 : EXIT_FAILURE
	}
	fmt.eprintfln("kerneltool: changelog has no command %s", args[0])
	fmt.eprintln(usage_text)
	return EXIT_USAGE
}

run_release_number :: proc(args: []string) -> int {
	fmt.println(release.RELEASE_NUMBER)
	return 0
}

// The parts of the text, the same for the tool and its tests.

release_number_parse :: proc(text: string) -> (number: Release_Number, ok: bool) {
	parts := strings.split(text, ".", context.temp_allocator)
	if len(parts) != 3 {
		return {}, false
	}
	values: [3]int
	for part, index in parts {
		if len(part) == 0 || len(part) > 6 || (len(part) > 1 && part[0] == '0') {
			return {}, false
		}
		for character in transmute([]u8)part {
			if character < '0' || character > '9' {
				return {}, false
			}
		}
		values[index], _ = strconv.parse_int(part, 10)
	}
	return {values[0], values[1], values[2]}, true
}

release_number_text :: proc(number: Release_Number) -> string {
	return fmt.tprintf("%d.%d.%d", number.major, number.minor, number.patch)
}

release_number_less :: proc(a, b: Release_Number) -> bool {
	if a.major != b.major {
		return a.major < b.major
	}
	if a.minor != b.minor {
		return a.minor < b.minor
	}
	return a.patch < b.patch
}

change_type_index :: proc(name: string) -> int {
	types := CHANGE_TYPES
	for type_name, index in types {
		if type_name == name {
			return index
		}
	}
	return -1
}

// digits_value reads a field of digits only; -1 if one byte is not a digit.
digits_value :: proc(text: string) -> int {
	value := 0
	for character in transmute([]u8)text {
		if character < '0' || character > '9' {
			return -1
		}
		value = value * 10 + int(character - '0')
	}
	return value
}

// date_valid checks a date of the calendar, in the years 2000 to 2999.
date_valid :: proc(year, month, day: int) -> bool {
	if year < 2000 || year > 2999 || month < 1 || month > 12 || day < 1 {
		return false
	}
	days := [12]int{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
	if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) {
		days[1] = 29
	}
	return day <= days[month - 1]
}

// date_text_valid checks "yyyy-mm-dd".
date_text_valid :: proc(text: string) -> bool {
	if len(text) != 10 || text[4] != '-' || text[7] != '-' {
		return false
	}
	return date_valid(digits_value(text[0:4]), digits_value(text[5:7]), digits_value(text[8:10]))
}

// subject_problem gives the fault of a subject of a fragment name, or "".
subject_problem :: proc(subject: string) -> string {
	if len(subject) == 0 {
		return "the subject is empty"
	}
	if len(subject) > FRAGMENT_SUBJECT_MOST {
		return fmt.tprintf("the subject has %d bytes; it can have at most %d", len(subject), FRAGMENT_SUBJECT_MOST)
	}
	for character in transmute([]u8)subject {
		if !((character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') || character == '-') {
			return fmt.tprintf("the subject has the byte %q; it can have only the lowercase letters a to z, the digits and -", rune(character))
		}
	}
	if subject[0] == '-' || subject[len(subject) - 1] == '-' || strings.contains(subject, "--") {
		return "the subject starts or ends with -, or has -- in it"
	}
	return ""
}

// fragment_name_problem gives the fault of the name of a fragment file, or "".
fragment_name_problem :: proc(file_name: string) -> string {
	expected :: "the name of a fragment is <yyyymmdd-hhmmss>-<subject>.md"
	if !strings.has_suffix(file_name, ".md") || len(file_name) <= FRAGMENT_TIME_LENGTH + len(".md") {
		return expected
	}
	stamp := file_name[:FRAGMENT_TIME_LENGTH]
	if stamp[8] != '-' || stamp[15] != '-' {
		return expected
	}
	if !date_valid(digits_value(stamp[0:4]), digits_value(stamp[4:6]), digits_value(stamp[6:8])) {
		return fmt.tprintf("%s: %s is not a date of the calendar", expected, stamp[0:8])
	}
	hour, minute, second := digits_value(stamp[9:11]), digits_value(stamp[11:13]), digits_value(stamp[13:15])
	if hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59 {
		return fmt.tprintf("%s: %s is not a time of the day", expected, stamp[9:15])
	}
	if problem := subject_problem(file_name[FRAGMENT_TIME_LENGTH:len(file_name) - len(".md")]); problem != "" {
		return fmt.tprintf("%s: %s", expected, problem)
	}
	return ""
}

// entry_line_problem gives the fault of one line of the text of an entry, or "".
entry_line_problem :: proc(line: string) -> string {
	switch {
	case strings.contains_any(line, "\t\r"):
		return "the line has a tab or a carriage return"
	case strings.has_prefix(line, "#"):
		return "the line is a heading; the type of the fragment gives the part of the release"
	case strings.has_prefix(line, "- ") || strings.has_prefix(line, "* "):
		return "the line starts with \"- \": a fragment is one entry, and the tool writes its \"- \""
	case strings.has_prefix(line, " "):
		return "the line starts with a space; the tool indents the lines of an entry"
	case strings.has_suffix(line, " "):
		return "the line ends with a space"
	}
	return ""
}

// fragment_parse reads a fragment. Each problem is one sentence that names
// the file and the line.
fragment_parse :: proc(file_name: string, content: string) -> (fragment: Fragment, problems: [dynamic]string) {
	problems = make([dynamic]string, context.temp_allocator)
	fragment.file_name = file_name
	fragment.type_index = -1
	place := strings.concatenate({FRAGMENT_FOLDER, "/", file_name}, context.temp_allocator)
	if problem := fragment_name_problem(file_name); problem != "" {
		append(&problems, fmt.tprintf("%s: %s", place, problem))
	}
	lines := strings.split(content, "\n", context.temp_allocator)
	if len(lines) > 0 && lines[len(lines) - 1] == "" {
		lines = lines[:len(lines) - 1]
	}
	if len(lines) == 0 || !strings.has_prefix(lines[0], "type: ") {
		append(&problems, fmt.tprintf("%s, line 1: the line \"type: <type>\" is expected, with a type of Added, Changed, Deprecated, Removed, Fixed, Security", place))
		return
	}
	type_name := lines[0][len("type: "):]
	fragment.type_index = change_type_index(type_name)
	if fragment.type_index < 0 {
		append(&problems, fmt.tprintf("%s, line 1: the type %q is not known; the types are Added, Changed, Deprecated, Removed, Fixed, Security", place, type_name))
	}
	if len(lines) < 2 || lines[1] != "" {
		append(&problems, fmt.tprintf("%s, line 2: an empty line is expected after the type", place))
		return
	}
	text := lines[2:]
	if len(text) == 0 || strings.trim_space(text[0]) == "" {
		append(&problems, fmt.tprintf("%s, line 3: the text of the change is expected; it is empty", place))
		return
	}
	for line, index in text {
		if line == "" {
			append(&problems, fmt.tprintf("%s, line %d: an empty line inside the text; the text of a change is one paragraph", place, index + 3))
			continue
		}
		if problem := entry_line_problem(line); problem != "" {
			append(&problems, fmt.tprintf("%s, line %d: %s", place, index + 3, problem))
		}
	}
	fragment.lines = text
	return
}

// fragment_text gives the text of a fragment file.
fragment_text :: proc(type_name: string, text: string) -> string {
	return fmt.tprintf("type: %s\n\n%s\n", type_name, strings.trim_space(text))
}

// entry_joined gives the text of an entry in one line: the form that two
// entries are compared in.
entry_joined :: proc(lines: []string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for line, index in lines {
		if index > 0 {
			strings.write_byte(&builder, ' ')
		}
		strings.write_string(&builder, strings.trim_space(line))
	}
	return strings.to_string(builder)
}

// changelog_parse reads CHANGELOG.md and checks its structure:
//   line 1: "# Changelog"; then a preamble with no heading;
//   each release: "## [<major>.<minor>.<patch>] - <yyyy-mm-dd>", an empty line;
//   then for each type, in the order of CHANGE_TYPES, at most once:
//   "### <type>", an empty line, the entries; each entry is "- <text>",
//   and the next lines of its text start with two spaces;
//   one empty line before each heading, no two empty lines, one line feed at the end;
//   the release numbers descend and the dates do not rise.
changelog_parse :: proc(content: string) -> (changelog: Changelog, problems: [dynamic]string) {
	problems = make([dynamic]string, context.temp_allocator)
	if !strings.has_suffix(content, "\n") || strings.has_suffix(content, "\n\n") {
		append(&problems, fmt.tprintf("%s: the file must end with one line feed", CHANGELOG_FILE))
	}
	lines := strings.split(strings.trim_right(content, "\n"), "\n", context.temp_allocator)
	changelog.lines = lines
	changelog.first_release_line = len(lines)
	at :: proc(problems: ^[dynamic]string, line: int, sentence: string) {
		append(problems, fmt.tprintf("%s, line %d: %s", CHANGELOG_FILE, line, sentence))
	}
	if len(lines) == 0 || lines[0] != CHANGELOG_TITLE {
		at(&problems, 1, "the title \"" + CHANGELOG_TITLE + "\" is expected")
		return
	}
	releases := make([dynamic]Changelog_Release, context.temp_allocator)
	entries := make([dynamic]Changelog_Entry, context.temp_allocator)
	entry_lines := make([dynamic]string, context.temp_allocator)
	// What the line before was.
	Previous :: enum {
		Title,
		Preamble,
		Empty,
		Release_Heading,
		Type_Heading,
		Entry,
	}
	previous := Previous.Title
	type_index := -1
	entry_line := 0
	finish_entry :: proc(entries: ^[dynamic]Changelog_Entry, entry_lines: ^[dynamic]string, type_index, entry_line: int) {
		if len(entry_lines) > 0 {
			append(entries, Changelog_Entry{type_index = type_index, lines = slice.clone(entry_lines[:], context.temp_allocator), line = entry_line})
			clear(entry_lines)
		}
	}
	finish_release :: proc(releases: ^[dynamic]Changelog_Release, entries: ^[dynamic]Changelog_Entry, problems: ^[dynamic]string) {
		if len(releases) == 0 {
			return
		}
		last := &releases[len(releases) - 1]
		last.entries = slice.clone(entries[:], context.temp_allocator)
		clear(entries)
		if len(last.entries) == 0 {
			append(problems, fmt.tprintf("%s, line %d: the release %s has no entry", CHANGELOG_FILE, last.line, release_number_text(last.number)))
		}
	}
	type_has_entry := true
	type_heading_line := 0
	for line, index in lines {
		number := index + 1
		if line != "" && (strings.contains_any(line, "\t\r") || strings.has_suffix(line, " ")) {
			at(&problems, number, "the line has a tab, a carriage return or a space at its end")
		}
		if index == 0 {
			continue
		}
		if line == "" {
			if previous == .Empty {
				at(&problems, number, "a second empty line; one empty line separates two parts")
			}
			if previous == .Entry {
				finish_entry(&entries, &entry_lines, type_index, entry_line)
			}
			previous = .Empty
			continue
		}
		if strings.has_prefix(line, "#") {
			if previous != .Empty {
				at(&problems, number, "an empty line is expected before a heading")
			}
			if strings.has_prefix(line, "## ") {
				if !type_has_entry {
					at(&problems, type_heading_line, "the part has no entry")
				}
				finish_release(&releases, &entries, &problems)
				if len(releases) == 0 {
					changelog.first_release_line = index
				}
				release_number, date, heading_ok := release_heading_parse(line)
				if !heading_ok {
					at(&problems, number, "the heading \"## [<major>.<minor>.<patch>] - <yyyy-mm-dd>\" of a release is expected, with a date of the calendar")
				} else if len(releases) > 0 {
					newer := releases[len(releases) - 1]
					if !release_number_less(release_number, newer.number) {
						at(&problems, number, fmt.tprintf("the release %s is not older than the release %s above it; the newest release is first", release_number_text(release_number), release_number_text(newer.number)))
					}
					if date > newer.date {
						at(&problems, number, fmt.tprintf("the date %s is after the date %s of the newer release above it", date, newer.date))
					}
				}
				append(&releases, Changelog_Release{number = release_number, date = date, line = number})
				type_index = -1
				type_has_entry = true
				previous = .Release_Heading
				continue
			}
			if strings.has_prefix(line, "### ") {
				if len(releases) == 0 {
					at(&problems, number, "a part of a release before the first release heading")
				}
				if !type_has_entry {
					at(&problems, type_heading_line, "the part has no entry")
				}
				new_type := change_type_index(line[len("### "):])
				if new_type < 0 {
					at(&problems, number, fmt.tprintf("the type %q is not known; the types are Added, Changed, Deprecated, Removed, Fixed, Security", line[len("### "):]))
				} else if new_type <= type_index {
					at(&problems, number, "the parts of a release are in the order Added, Changed, Deprecated, Removed, Fixed, Security, each one at most once")
				}
				type_index = max(type_index, new_type)
				type_has_entry = false
				type_heading_line = number
				previous = .Type_Heading
				continue
			}
			at(&problems, number, "a heading of the level 2 (a release) or 3 (a type of change) is expected")
			previous = .Empty
			continue
		}
		if len(releases) == 0 {
			// The preamble: text with no heading.
			previous = .Preamble
			continue
		}
		if previous == .Release_Heading || previous == .Type_Heading {
			at(&problems, number, "an empty line is expected after a heading")
		}
		if strings.has_prefix(line, "- ") {
			if type_index < 0 {
				at(&problems, number, "an entry before the heading of its type (### Added, ...)")
			}
			if previous == .Entry {
				finish_entry(&entries, &entry_lines, type_index, entry_line)
			}
			if problem := entry_line_problem(line[2:]); problem != "" {
				at(&problems, number, problem)
			}
			append(&entry_lines, line[2:])
			entry_line = number
			type_has_entry = true
			previous = .Entry
			continue
		}
		if strings.has_prefix(line, "  ") && previous == .Entry {
			if problem := entry_line_problem(line[2:]); problem != "" {
				at(&problems, number, problem)
			}
			append(&entry_lines, line[2:])
			continue
		}
		at(&problems, number, "an entry \"- <text>\", or a line of its text that starts with two spaces, is expected")
		previous = .Entry
	}
	if previous == .Entry {
		finish_entry(&entries, &entry_lines, type_index, entry_line)
	}
	if !type_has_entry {
		at(&problems, type_heading_line, "the part has no entry")
	}
	finish_release(&releases, &entries, &problems)
	changelog.releases = releases[:]
	return
}

// release_heading_parse reads "## [0.58.0] - 2026-11-11".
release_heading_parse :: proc(line: string) -> (number: Release_Number, date: string, ok: bool) {
	if !strings.has_prefix(line, "## [") {
		return
	}
	rest := line[len("## ["):]
	end := strings.index(rest, "] - ")
	if end < 0 {
		return
	}
	number = release_number_parse(rest[:end]) or_return
	date = rest[end + len("] - "):]
	return number, date, date_text_valid(date)
}

// fragments_in_release_order sorts the fragments as a release lists them:
// by type in the order of CHANGE_TYPES, then by the time in the name; two
// fragments of the same second by their subject.
fragments_in_release_order :: proc(fragments: []Fragment) {
	slice.sort_by(fragments, proc(a, b: Fragment) -> bool {
		if a.type_index != b.type_index {
			return a.type_index < b.type_index
		}
		return a.file_name < b.file_name
	})
}

// release_parts_text gives the parts of a release ("### Added", ...) from
// fragments in release order.
release_parts_text :: proc(fragments: []Fragment) -> string {
	builder := strings.builder_make(context.temp_allocator)
	types := CHANGE_TYPES
	type_index := -1
	for fragment in fragments {
		if fragment.type_index != type_index {
			type_index = fragment.type_index
			if strings.builder_len(builder) > 0 {
				strings.write_string(&builder, "\n")
			}
			fmt.sbprintf(&builder, "### %s\n\n", types[type_index])
		}
		for line, index in fragment.lines {
			strings.write_string(&builder, index == 0 ? "- " : "  ")
			strings.write_string(&builder, line)
			strings.write_string(&builder, "\n")
		}
	}
	return strings.to_string(builder)
}

// release_section_text gives a whole release, with its heading.
release_section_text :: proc(number: Release_Number, date: string, fragments: []Fragment) -> string {
	return fmt.tprintf("## [%s] - %s\n\n%s", release_number_text(number), date, release_parts_text(fragments))
}

// changelog_with_release gives CHANGELOG.md with a new release before the newest one.
changelog_with_release :: proc(changelog: Changelog, section: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for line in changelog.lines[:changelog.first_release_line] {
		strings.write_string(&builder, line)
		strings.write_string(&builder, "\n")
	}
	if changelog.first_release_line == len(changelog.lines) && len(changelog.lines) > 0 && changelog.lines[len(changelog.lines) - 1] != "" {
		strings.write_string(&builder, "\n")
	}
	strings.write_string(&builder, section)
	if changelog.first_release_line < len(changelog.lines) {
		strings.write_string(&builder, "\n")
		for line in changelog.lines[changelog.first_release_line:] {
			strings.write_string(&builder, line)
			strings.write_string(&builder, "\n")
		}
	}
	return strings.to_string(builder)
}

// released_fragment_problems checks the fragments against CHANGELOG.md: no fragment
// whose text is already an entry of a release.
released_fragment_problems :: proc(changelog: Changelog, fragments: []Fragment, problems: ^[dynamic]string) {
	released := make(map[string]string, context.temp_allocator)
	for released_release in changelog.releases {
		for entry in released_release.entries {
			released[entry_joined(entry.lines)] = release_number_text(released_release.number)
		}
	}
	for fragment in fragments {
		if number, found := released[entry_joined(fragment.lines)]; found {
			append(problems, fmt.tprintf("%s/%s: its text is already an entry of the release %s; delete the fragment", FRAGMENT_FOLDER, fragment.file_name, number))
		}
	}
}

// The parts that read and write the files of the repository.

// fragments_read reads each fragment of a folder, in the order of the names.
fragments_read :: proc(folder: string, problems: ^[dynamic]string) -> []Fragment {
	fragments := make([dynamic]Fragment, context.temp_allocator)
	entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
	if err != nil {
		append(problems, fmt.tprintf("%s: cannot list the folder: %v", folder, err))
		return nil
	}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	for entry in entries {
		if entry.name == FRAGMENT_FOLDER_GUIDE {
			continue
		}
		if entry.type == .Directory {
			append(problems, fmt.tprintf("%s/%s: a folder; the fragment folder holds only fragment files", FRAGMENT_FOLDER, entry.name))
			continue
		}
		content, read_err := os.read_entire_file(strings.concatenate({folder, "/", entry.name}, context.temp_allocator), context.temp_allocator)
		if read_err != nil {
			append(problems, fmt.tprintf("%s/%s: cannot read: %v", FRAGMENT_FOLDER, entry.name, read_err))
			continue
		}
		fragment, fragment_problems := fragment_parse(entry.name, string(content))
		append(problems, ..fragment_problems[:])
		append(&fragments, fragment)
	}
	return fragments[:]
}

changelog_read :: proc(problems: ^[dynamic]string) -> (changelog: Changelog, ok: bool) {
	content, err := os.read_entire_file(CHANGELOG_FILE, context.temp_allocator)
	if err != nil {
		append(problems, fmt.tprintf("%s: cannot read: %v", CHANGELOG_FILE, err))
		return {}, false
	}
	parse_problems: [dynamic]string
	changelog, parse_problems = changelog_parse(string(content))
	append(problems, ..parse_problems[:])
	return changelog, true
}

// release_number_source_problem compares RELEASE_NUMBER in its source with
// the newest release of CHANGELOG.md.
release_number_source_problem :: proc(changelog: Changelog) -> string {
	content, err := os.read_entire_file(RELEASE_NUMBER_SOURCE, context.temp_allocator)
	if err != nil {
		return fmt.tprintf("%s: cannot read: %v", RELEASE_NUMBER_SOURCE, err)
	}
	for line, index in strings.split(string(content), "\n", context.temp_allocator) {
		if !strings.has_prefix(line, RELEASE_NUMBER_LINE_START) {
			continue
		}
		written := strings.trim(line[len(RELEASE_NUMBER_LINE_START):], "\"")
		if len(changelog.releases) == 0 {
			return ""
		}
		newest := release_number_text(changelog.releases[0].number)
		if written != newest {
			return fmt.tprintf("%s, line %d: RELEASE_NUMBER is %s; the newest release of %s is %s", RELEASE_NUMBER_SOURCE, index + 1, written, CHANGELOG_FILE, newest)
		}
		return ""
	}
	return fmt.tprintf("%s: no line starts with %q", RELEASE_NUMBER_SOURCE, RELEASE_NUMBER_LINE_START)
}

problems_print :: proc(problems: []string) {
	for problem in problems {
		fmt.eprintfln("kerneltool: %s", problem)
	}
}

// local_date_and_time gives the date and the time of the clock of the host,
// in the time zone of the host (UTC if the tool cannot read it).
local_date_and_time :: proc() -> datetime.DateTime {
	moment, _ := time.time_to_datetime(time.now())
	region, region_ok := timezone.region_load("local", context.temp_allocator)
	if !region_ok {
		return moment
	}
	local, local_ok := timezone.datetime_to_tz(moment, region)
	return local_ok ? local : moment
}

changelog_new :: proc(type_name, subject, text: string) -> bool {
	if change_type_index(type_name) < 0 {
		fmt.eprintfln("kerneltool: the type %q is not known; the types are Added, Changed, Deprecated, Removed, Fixed, Security", type_name)
		return false
	}
	if problem := subject_problem(subject); problem != "" {
		fmt.eprintfln("kerneltool: %s", problem)
		return false
	}
	now := local_date_and_time()
	file_name := fmt.tprintf("%04d%02d%02d-%02d%02d%02d-%s.md", now.year, now.month, now.day, now.hour, now.minute, now.second, subject)
	content := fragment_text(type_name, text)
	_, problems := fragment_parse(file_name, content)
	if len(problems) > 0 {
		problems_print(problems[:])
		return false
	}
	path := strings.concatenate({FRAGMENT_FOLDER, "/", file_name}, context.temp_allocator)
	if os.exists(path) {
		fmt.eprintfln("kerneltool: %s exists; wait one second, or choose another subject", path)
		return false
	}
	if err := os.write_entire_file(path, transmute([]u8)content); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", path, err)
		return false
	}
	fmt.printfln("kerneltool: wrote %s", path)
	return true
}

// changelog_all_read reads CHANGELOG.md and the fragments, and checks all.
changelog_all_read :: proc() -> (changelog: Changelog, fragments: []Fragment, problems: [dynamic]string) {
	problems = make([dynamic]string, context.temp_allocator)
	read_ok: bool
	changelog, read_ok = changelog_read(&problems)
	fragments = fragments_read(FRAGMENT_FOLDER, &problems)
	if read_ok {
		released_fragment_problems(changelog, fragments, &problems)
		if problem := release_number_source_problem(changelog); problem != "" {
			append(&problems, problem)
		}
	}
	return
}

changelog_check :: proc() -> bool {
	changelog, fragments, problems := changelog_all_read()
	if len(problems) > 0 {
		problems_print(problems[:])
		fmt.eprintfln("kerneltool: test failed: the changelog has %d problems", len(problems))
		return false
	}
	entry_count := 0
	for checked_release in changelog.releases {
		entry_count += len(checked_release.entries)
	}
	test_passed_print("%s has %d releases and %d entries, %s has %d fragments, all well formed", CHANGELOG_FILE, len(changelog.releases), entry_count, FRAGMENT_FOLDER, len(fragments))
	return true
}

changelog_assemble :: proc() -> bool {
	changelog, fragments, problems := changelog_all_read()
	if len(problems) > 0 {
		problems_print(problems[:])
		return false
	}
	newest := len(changelog.releases) > 0 ? release_number_text(changelog.releases[0].number) : "none"
	if len(fragments) == 0 {
		fmt.printfln("kerneltool: no fragment in %s: the next release after %s brings nothing yet", FRAGMENT_FOLDER, newest)
		return true
	}
	fragments_in_release_order(fragments)
	fmt.printfln("kerneltool: %d fragments; the release after %s brings:\n", len(fragments), newest)
	fmt.print(release_parts_text(fragments))
	return true
}

changelog_release :: proc(number_text: string) -> bool {
	number, number_ok := release_number_parse(number_text)
	if !number_ok {
		fmt.eprintfln("kerneltool: %q is not a release number <major>.<minor>.<patch>, such as 0.59.0", number_text)
		return false
	}
	changelog, fragments, problems := changelog_all_read()
	if len(problems) > 0 {
		problems_print(problems[:])
		return false
	}
	if len(changelog.releases) > 0 && !release_number_less(changelog.releases[0].number, number) {
		fmt.eprintfln("kerneltool: the release %s is not after the newest release %s", number_text, release_number_text(changelog.releases[0].number))
		return false
	}
	if len(fragments) == 0 {
		fmt.eprintfln("kerneltool: %s has no fragment: a release lists at least one change", FRAGMENT_FOLDER)
		return false
	}
	fragments_in_release_order(fragments)
	now := local_date_and_time()
	date := fmt.tprintf("%04d-%02d-%02d", now.year, now.month, now.day)
	if len(changelog.releases) > 0 && date < changelog.releases[0].date {
		fmt.eprintfln("kerneltool: the date of the host, %s, is before the date %s of the newest release", date, changelog.releases[0].date)
		return false
	}
	content := changelog_with_release(changelog, release_section_text(number, date, fragments))
	// Check the result before a file changes.
	if _, after_problems := changelog_parse(content); len(after_problems) > 0 {
		problems_print(after_problems[:])
		return false
	}
	source, source_err := os.read_entire_file(RELEASE_NUMBER_SOURCE, context.temp_allocator)
	if source_err != nil {
		fmt.eprintfln("kerneltool: cannot read %s: %v", RELEASE_NUMBER_SOURCE, source_err)
		return false
	}
	source_lines := strings.split(string(source), "\n", context.temp_allocator)
	for &line in source_lines {
		if strings.has_prefix(line, RELEASE_NUMBER_LINE_START) {
			line = fmt.tprintf("%s\"%s\"", RELEASE_NUMBER_LINE_START, number_text)
		}
	}
	new_source := strings.join(source_lines, "\n", context.temp_allocator)
	if err := os.write_entire_file(CHANGELOG_FILE, transmute([]u8)content); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", CHANGELOG_FILE, err)
		return false
	}
	if err := os.write_entire_file(RELEASE_NUMBER_SOURCE, transmute([]u8)new_source); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", RELEASE_NUMBER_SOURCE, err)
		return false
	}
	for fragment in fragments {
		path := strings.concatenate({FRAGMENT_FOLDER, "/", fragment.file_name}, context.temp_allocator)
		if err := os.remove(path); err != nil {
			fmt.eprintfln("kerneltool: cannot delete %s: %v", path, err)
			return false
		}
	}
	fmt.printfln("kerneltool: wrote the release %s - %s with %d entries in %s, set RELEASE_NUMBER in %s, deleted %d fragments", number_text, date, len(fragments), CHANGELOG_FILE, RELEASE_NUMBER_SOURCE, len(fragments))
	return true
}

changelog_notes :: proc(number_text: string) -> bool {
	number, number_ok := release_number_parse(number_text)
	if !number_ok {
		fmt.eprintfln("kerneltool: %q is not a release number <major>.<minor>.<patch>, such as 0.58.0", number_text)
		return false
	}
	problems := make([dynamic]string, context.temp_allocator)
	changelog, read_ok := changelog_read(&problems)
	if !read_ok || len(problems) > 0 {
		problems_print(problems[:])
		return false
	}
	for found, index in changelog.releases {
		if found.number != number {
			continue
		}
		end := len(changelog.lines)
		if index + 1 < len(changelog.releases) {
			end = changelog.releases[index + 1].line - 1
		}
		fmt.println(strings.trim_right_space(strings.join(changelog.lines[found.line - 1:end], "\n", context.temp_allocator)))
		return true
	}
	fmt.eprintfln("kerneltool: %s has no release %s", CHANGELOG_FILE, number_text)
	return false
}
