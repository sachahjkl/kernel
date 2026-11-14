// The roadmap of the system (docs/GLOSSARY.md, "Roadmap", "Roadmap entry").
// ROADMAP.md holds the planned work, in three sections: what is in work
// now, what comes next, what comes later. It is plain Markdown that a
// reader understands with no tool, and the one place of the plans: when a
// work is done, its entry leaves the file in the commit of its changelog
// fragment.
//
//   kerneltool roadmap check     ROADMAP.md well formed, and no entry whose work has a changelog entry
//
// The structure of ROADMAP.md is strict, as the structure of CHANGELOG.md
// is, because the page of the site is made from it: `check` refuses each
// line that is not in its place (docs/TOOLS.md, "The roadmap").
package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"

ROADMAP_FILE :: "ROADMAP.md"
ROADMAP_TITLE :: "# Roadmap"
// The longest summary of an entry, with no period: one line of a card of
// the site at each width, and a title of the search index.
ROADMAP_SUMMARY_MOST :: 80
// The folder of the intent files: the design link of an entry names a file
// of it.
ROADMAP_INTENT_FOLDER :: "src/md/"
// The start of the design link of an entry, after its sentences.
ROADMAP_DESIGN_LINK_START :: " [Design]("

// The sections of the file, in their order.
Roadmap_Section :: enum {
	Now, // The work that is in progress.
	Next, // The work that is decided and comes after.
	Later, // The work that is wanted and has no order.
}

roadmap_section_names := [Roadmap_Section]string {
	.Now   = "Now",
	.Next  = "Next",
	.Later = "Later",
}

// One entry: "- **<summary>.** <one or two sentences> [Design](src/md/<file>.md)",
// the design link only when an intent file exists.
Roadmap_Entry :: struct {
	section: Roadmap_Section,
	summary: string, // With no "**" and no period at its end.
	text:    string, // The one or two sentences, on one line.
	design:  string, // The path of its intent file, or "".
	line:    int, // The line of its "- ", from 1.
}

Roadmap :: struct {
	entries: []Roadmap_Entry, // In the order of the file.
}

run_roadmap :: proc(args: []string) -> int {
	usage_text :: "kerneltool roadmap check"
	if len(args) == 1 && args[0] == "check" {
		return roadmap_check() ? 0 : EXIT_FAILURE
	}
	if len(args) > 0 {
		fmt.eprintfln("kerneltool: roadmap has no command %s", args[0])
	}
	fmt.eprintln(usage_text)
	return EXIT_USAGE
}

// The parts of the text, the same for the tool and its tests.

// roadmap_is_letter tells whether a byte is a letter of ASCII.
roadmap_is_letter :: proc(character: u8) -> bool {
	return (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z')
}

// roadmap_is_digit tells whether a byte is a decimal digit.
roadmap_is_digit :: proc(character: u8) -> bool {
	return character >= '0' && character <= '9'
}

// roadmap_date_in_text gives the first date of a text, or "": a text of the
// form yyyy-mm-dd, or the name of a month with a year after it ("November
// 2026", "november, 2026"). A year alone is not looked for: "2048 pixels"
// is a count. The roadmap gives no date, because a planned date that passed
// is a false sentence that nothing corrects.
roadmap_date_in_text :: proc(text: string) -> string {
	for index := 0; index + 10 <= len(text); index += 1 {
		window := text[index:index + 10]
		if window[4] != '-' || window[7] != '-' {
			continue
		}
		digits := true
		for character, place in transmute([]u8)window {
			if place != 4 && place != 7 && !roadmap_is_digit(character) {
				digits = false
			}
		}
		before_is_digit := index > 0 && roadmap_is_digit(text[index - 1])
		after_is_digit := index + 10 < len(text) && roadmap_is_digit(text[index + 10])
		if digits && !before_is_digit && !after_is_digit {
			return window
		}
	}
	months := [12]string{"january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"}
	lower := strings.to_lower(text, context.temp_allocator)
	for month in months {
		search := 0
		for search < len(lower) {
			found := strings.index(lower[search:], month)
			if found < 0 {
				break
			}
			start := search + found
			end := start + len(month)
			search = end
			if start > 0 && roadmap_is_letter(lower[start - 1]) {
				continue
			}
			// After the name: a comma or none, spaces, then a year of four digits.
			year := end
			if year < len(lower) && lower[year] == ',' {
				year += 1
			}
			spaces := 0
			for year < len(lower) && lower[year] == ' ' {
				year += 1
				spaces += 1
			}
			if spaces == 0 || year + 4 > len(lower) {
				continue
			}
			century := lower[year:year + 2]
			if century != "19" && century != "20" {
				continue
			}
			if !roadmap_is_digit(lower[year + 2]) || !roadmap_is_digit(lower[year + 3]) {
				continue
			}
			if year + 4 < len(lower) && roadmap_is_digit(lower[year + 4]) {
				continue
			}
			return text[start:year + 4]
		}
	}
	return ""
}

// roadmap_html_in_text tells whether a text holds a tag of HTML outside a
// code span: a "<" with a letter, a "/" or a "!" after it.
roadmap_html_in_text :: proc(text: string) -> bool {
	in_code := false
	for index in 0 ..< len(text) {
		character := text[index]
		if character == '`' {
			in_code = !in_code
			continue
		}
		if in_code || character != '<' || index + 1 >= len(text) {
			continue
		}
		after := text[index + 1]
		if roadmap_is_letter(after) || after == '/' || after == '!' {
			return true
		}
	}
	return false
}

// roadmap_decision_in_text gives the first identifier of a decision in a
// text (a capital D, a "-", then digits), or "". The roadmap says what a
// work gives; the record of the decisions is another document.
roadmap_decision_in_text :: proc(text: string) -> string {
	for index := 0; index + 3 <= len(text); index += 1 {
		if text[index] != 'D' || text[index + 1] != '-' || !roadmap_is_digit(text[index + 2]) {
			continue
		}
		if index > 0 && (roadmap_is_letter(text[index - 1]) || roadmap_is_digit(text[index - 1])) {
			continue
		}
		end := index + 2
		for end < len(text) && roadmap_is_digit(text[end]) {
			end += 1
		}
		return text[index:end]
	}
	return ""
}

// roadmap_word_in_text tells whether a text holds a word of lowercase
// letters as a whole word, with no regard to case.
roadmap_word_in_text :: proc(text, word: string) -> bool {
	lower := strings.to_lower(text, context.temp_allocator)
	search := 0
	for search < len(lower) {
		found := strings.index(lower[search:], word)
		if found < 0 {
			return false
		}
		start := search + found
		end := start + len(word)
		search = end
		if start > 0 && roadmap_is_letter(lower[start - 1]) {
			continue
		}
		if end < len(lower) && roadmap_is_letter(lower[end]) {
			continue
		}
		return true
	}
	return false
}

// roadmap_sentence_count counts the sentences of a text: a sentence ends at
// a ".", a "?" or a "!" that is outside a code span and that a space or
// the end of the text follows. "0.5" and "`a.b`" end no sentence.
// ends_whole tells whether the text ends with the end of a sentence.
roadmap_sentence_count :: proc(text: string) -> (count: int, ends_whole: bool) {
	in_code := false
	for index in 0 ..< len(text) {
		character := text[index]
		if character == '`' {
			in_code = !in_code
			continue
		}
		if in_code || (character != '.' && character != '?' && character != '!') {
			continue
		}
		if index + 1 == len(text) {
			count += 1
			ends_whole = true
		} else if text[index + 1] == ' ' {
			count += 1
		}
	}
	return
}

// roadmap_summary_key gives the form in which two summaries are compared:
// the lowercase letters and the digits, one "-" for each run of other
// characters. It is also what gives an entry its address on the page of the
// site, so two entries with one key are one entry for a reader.
roadmap_summary_key :: proc(summary: string) -> string {
	return site_slug(summary)
}

// roadmap_entry_parse reads the text of one entry, on one line. Each
// problem is one sentence that names the line.
roadmap_entry_parse :: proc(text: string, section: Roadmap_Section, line: int, problems: ^[dynamic]string) -> (entry: Roadmap_Entry) {
	entry.section = section
	entry.line = line
	form :: "the form of an entry is \"- **<summary>.** <one or two sentences>\""
	if !strings.has_prefix(text, "**") {
		append(problems, fmt.tprintf("%s, line %d: the entry does not start with a bold summary; %s", ROADMAP_FILE, line, form))
		return
	}
	bold_end := strings.index(text[2:], "**")
	if bold_end < 0 {
		append(problems, fmt.tprintf("%s, line %d: the bold summary has no end; %s", ROADMAP_FILE, line, form))
		return
	}
	bold := text[2:2 + bold_end]
	rest := text[2 + bold_end + 2:]
	if !strings.has_suffix(bold, ".") {
		append(problems, fmt.tprintf("%s, line %d: the summary does not end with a period inside the bold; %s", ROADMAP_FILE, line, form))
	}
	entry.summary = strings.trim_suffix(bold, ".")
	switch {
	case entry.summary == "":
		append(problems, fmt.tprintf("%s, line %d: the summary is empty", ROADMAP_FILE, line))
	case len(entry.summary) > ROADMAP_SUMMARY_MOST:
		append(problems, fmt.tprintf("%s, line %d: the summary has %d bytes; it can have at most %d", ROADMAP_FILE, line, len(entry.summary), ROADMAP_SUMMARY_MOST))
	case strings.trim_space(entry.summary) != entry.summary:
		append(problems, fmt.tprintf("%s, line %d: the summary starts or ends with a space", ROADMAP_FILE, line))
	case strings.contains_any(entry.summary, "*[]<>"):
		append(problems, fmt.tprintf("%s, line %d: the summary has one of the characters * [ ] < >; it is plain text, with code spans", ROADMAP_FILE, line))
	}
	if !strings.has_prefix(rest, " ") || strings.trim_space(rest) == "" {
		append(problems, fmt.tprintf("%s, line %d: one or two sentences are expected after the summary, after one space; %s", ROADMAP_FILE, line, form))
		return
	}
	rest = rest[1:]
	// The design link, when the entry has one, is its last part.
	if link_start := strings.last_index(rest, ROADMAP_DESIGN_LINK_START); link_start >= 0 {
		if !strings.has_suffix(rest, ")") {
			append(problems, fmt.tprintf("%s, line %d: the design link is the last part of an entry: \"[Design](%s<file>.md)\", with nothing after it", ROADMAP_FILE, line, ROADMAP_INTENT_FOLDER))
		} else {
			entry.design = rest[link_start + len(ROADMAP_DESIGN_LINK_START):len(rest) - 1]
			if !strings.has_prefix(entry.design, ROADMAP_INTENT_FOLDER) || !strings.has_suffix(entry.design, ".md") || strings.contains(entry.design, "..") || strings.contains_any(entry.design, " ()") {
				append(problems, fmt.tprintf("%s, line %d: the design link names %q; it names an intent file, \"%s<file>.md\"", ROADMAP_FILE, line, entry.design, ROADMAP_INTENT_FOLDER))
			}
		}
		rest = rest[:link_start]
	}
	entry.text = rest
	if strings.contains(rest, "](") {
		append(problems, fmt.tprintf("%s, line %d: a link in the sentences; an entry has one link, its design, as its last part: \"[Design](%s<file>.md)\"", ROADMAP_FILE, line, ROADMAP_INTENT_FOLDER))
	}
	count, ends_whole := roadmap_sentence_count(rest)
	if !ends_whole {
		append(problems, fmt.tprintf("%s, line %d: the text after the summary does not end with the end of a sentence", ROADMAP_FILE, line))
	} else if count > 2 {
		append(problems, fmt.tprintf("%s, line %d: %d sentences after the summary; an entry has one or two: what the work gives the user", ROADMAP_FILE, line, count))
	}
	return
}

// roadmap_text_problem gives the fault of a line of text of the file that
// each part of it can have, or "": a date, a tag of HTML, the identifier of
// a decision, the role of a person of the project.
roadmap_text_problem :: proc(text: string) -> string {
	if date := roadmap_date_in_text(text); date != "" {
		return fmt.tprintf("the date %q; the roadmap gives no date", date)
	}
	if roadmap_html_in_text(text) {
		return "a tag of HTML; the roadmap is plain Markdown"
	}
	if decision := roadmap_decision_in_text(text); decision != "" {
		return fmt.tprintf("the decision %s; the roadmap names no decision: the record of the decisions is docs/DECISIONS.md", decision)
	}
	if roadmap_word_in_text(text, "owner") {
		return "the word \"owner\"; the roadmap names no person and no role of the project"
	}
	return ""
}

// roadmap_metadata_line tells whether a line of the preamble is a field of
// metadata, "key: value": a word of lowercase letters, digits, "_" and "-",
// then ": ".
roadmap_metadata_line :: proc(line: string) -> bool {
	colon := strings.index(line, ": ")
	if colon <= 0 {
		return false
	}
	key := line[:colon]
	for character in transmute([]u8)key {
		if !((character >= 'a' && character <= 'z') || roadmap_is_digit(character) || character == '_' || character == '-') {
			return false
		}
	}
	return true
}

// roadmap_entry_finish ends the entry whose lines are gathered, if one is open.
roadmap_entry_finish :: proc(entries: ^[dynamic]Roadmap_Entry, entry_lines: ^[dynamic]string, section: Roadmap_Section, entry_line: int, problems: ^[dynamic]string) {
	if len(entry_lines) == 0 {
		return
	}
	text := strings.clone(entry_joined(entry_lines[:]), context.temp_allocator)
	clear(entry_lines)
	if problem := roadmap_text_problem(text); problem != "" {
		append(problems, fmt.tprintf("%s, line %d: the entry has %s", ROADMAP_FILE, entry_line, problem))
	}
	append(entries, roadmap_entry_parse(text, section, entry_line, problems))
}

// roadmap_parse reads ROADMAP.md and checks its structure:
//   line 1: "# Roadmap"; then a preamble of text with no heading, no list,
//   no front matter and no field "key: value";
//   then "## Now", "## Next" and "## Later", in this order, each one time,
//   and no other heading of any level;
//   a section is a list, which can be empty: each entry is "- <text>", and
//   the next lines of its text start with two spaces;
//   one empty line before and after each heading, no two empty lines, one
//   line feed at the end, no tab and no space at the end of a line;
//   no date, no tag of HTML, no decision and no person in any line;
//   no two entries with the same summary.
roadmap_parse :: proc(content: string) -> (roadmap: Roadmap, problems: [dynamic]string) {
	problems = make([dynamic]string, context.temp_allocator)
	at :: proc(problems: ^[dynamic]string, line: int, sentence: string) {
		append(problems, fmt.tprintf("%s, line %d: %s", ROADMAP_FILE, line, sentence))
	}
	if !strings.has_suffix(content, "\n") || strings.has_suffix(content, "\n\n") {
		append(&problems, fmt.tprintf("%s: the file must end with one line feed", ROADMAP_FILE))
	}
	lines := strings.split(strings.trim_right(content, "\n"), "\n", context.temp_allocator)
	if len(lines) == 0 || lines[0] != ROADMAP_TITLE {
		at(&problems, 1, "the title \"" + ROADMAP_TITLE + "\" is expected on the first line, with no front matter before it")
		return
	}
	sections_expected :: "the sections are \"## Now\", \"## Next\" and \"## Later\", in this order, each one time, and the file has no other heading"
	entries := make([dynamic]Roadmap_Entry, context.temp_allocator)
	entry_lines := make([dynamic]string, context.temp_allocator)
	// What the line before was.
	Previous :: enum {
		Title,
		Preamble,
		Empty,
		Heading,
		Entry,
	}
	previous := Previous.Title
	// The count of the section headings that came, in their order: it is
	// also the place of the next one.
	sections_seen := 0
	section := Roadmap_Section.Now
	entry_line := 0
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
				roadmap_entry_finish(&entries, &entry_lines, section, entry_line, &problems)
			}
			previous = .Empty
			continue
		}
		if strings.has_prefix(line, "#") {
			if previous == .Entry {
				roadmap_entry_finish(&entries, &entry_lines, section, entry_line, &problems)
			}
			if previous != .Empty {
				at(&problems, number, "an empty line is expected before a heading")
			}
			expected := ""
			if sections_seen < len(Roadmap_Section) {
				expected = strings.concatenate({"## ", roadmap_section_names[Roadmap_Section(sections_seen)]}, context.temp_allocator)
			}
			if expected != "" && line == expected {
				section = Roadmap_Section(sections_seen)
				sections_seen += 1
			} else {
				at(&problems, number, fmt.tprintf("the heading %q is not expected here; %s", line, sections_expected))
				// The entries under a heading that is out of its place are
				// still read, so that each of their faults is reported.
				sections_seen = max(sections_seen, 1)
			}
			previous = .Heading
			continue
		}
		if sections_seen == 0 {
			// The preamble: text with no heading and no list.
			switch {
			case line == "---" || line == "+++":
				at(&problems, number, "front matter; the roadmap is plain Markdown that a reader understands with no tool")
			case roadmap_metadata_line(line):
				at(&problems, number, "a field \"key: value\"; the roadmap has no metadata field")
			case strings.has_prefix(line, "- ") || strings.has_prefix(line, "* "):
				at(&problems, number, "an entry before the heading of its section (\"## Now\", \"## Next\" or \"## Later\")")
			}
			if problem := roadmap_text_problem(line); problem != "" {
				at(&problems, number, fmt.tprintf("the line has %s", problem))
			}
			previous = .Preamble
			continue
		}
		if previous == .Heading {
			at(&problems, number, "an empty line is expected after a heading")
		}
		if strings.has_prefix(line, "- ") {
			if previous == .Entry {
				roadmap_entry_finish(&entries, &entry_lines, section, entry_line, &problems)
			}
			if strings.has_prefix(line[2:], " ") {
				at(&problems, number, "two spaces after the \"-\" of an entry")
			}
			append(&entry_lines, line[2:])
			entry_line = number
			previous = .Entry
			continue
		}
		if strings.has_prefix(line, "  ") && previous == .Entry && len(entry_lines) > 0 {
			append(&entry_lines, line[2:])
			continue
		}
		at(&problems, number, "an entry \"- **<summary>.** <one or two sentences>\", or a line of its text that starts with two spaces, is expected: a section is a list")
		if previous == .Entry {
			roadmap_entry_finish(&entries, &entry_lines, section, entry_line, &problems)
		}
		previous = .Preamble
	}
	if previous == .Entry {
		roadmap_entry_finish(&entries, &entry_lines, section, entry_line, &problems)
	}
	if sections_seen < len(Roadmap_Section) {
		at(&problems, len(lines), fmt.tprintf("the section \"## %s\" is not in the file; %s", roadmap_section_names[Roadmap_Section(sections_seen)], sections_expected))
	}
	// No entry twice: two entries with one summary are one work.
	first_lines := make(map[string]int, context.temp_allocator)
	for entry in entries {
		if entry.summary == "" {
			continue
		}
		key := roadmap_summary_key(entry.summary)
		if first_line, found := first_lines[key]; found {
			at(&problems, entry.line, fmt.tprintf("the summary %q is the summary of the entry of line %d; an entry is in the file one time", entry.summary, first_line))
		} else {
			first_lines[key] = entry.line
		}
	}
	roadmap.entries = entries[:]
	return
}

// roadmap_design_problems checks the design link of each entry: it names a
// file that exists. The caller gives the test of a file, so that the tests
// of this rule need no disk.
roadmap_design_problems :: proc(roadmap: Roadmap, file_exists: proc(path: string) -> bool, problems: ^[dynamic]string) {
	for entry in roadmap.entries {
		if entry.design != "" && !file_exists(entry.design) {
			append(problems, fmt.tprintf("%s, line %d: the design link names %s, which is not a file of the repository", ROADMAP_FILE, entry.line, entry.design))
		}
	}
}

// changelog_entry_lead gives the bold summary at the start of the text of
// an entry of the changelog ("**The thing**: ..."), or "" when it has none.
changelog_entry_lead :: proc(text: string) -> string {
	if !strings.has_prefix(text, "**") {
		return ""
	}
	end := strings.index(text[2:], "**")
	if end < 0 {
		return ""
	}
	return text[2:2 + end]
}

// roadmap_changelog_problems refuses an entry whose summary is the bold
// summary of an entry of the changelog, in a fragment or in a release.
// The rule that it serves: when a work is done, its entry leaves the
// roadmap in the commit of its changelog fragment. The tool cannot know
// that a work is done; it knows that a fragment has the summary of an
// entry. So the fragment that ends a planned work takes the summary of its
// entry, and this check then refuses the entry until it is removed. Two
// summaries that are equal by chance name two works with one name: the
// entry of the roadmap takes a more exact summary.
roadmap_changelog_problems :: proc(roadmap: Roadmap, changelog: Changelog, fragments: []Fragment, problems: ^[dynamic]string) {
	places := make(map[string]string, context.temp_allocator)
	// The oldest release first, so that the place of a summary is its
	// newest one; a fragment is newer than each release.
	for index := len(changelog.releases) - 1; index >= 0; index -= 1 {
		changelog_release := changelog.releases[index]
		for entry in changelog_release.entries {
			if lead := changelog_entry_lead(entry_joined(entry.lines)); lead != "" {
				places[roadmap_summary_key(lead)] = fmt.tprintf("an entry of the release %s of %s", release_number_text(changelog_release.number), CHANGELOG_FILE)
			}
		}
	}
	for fragment in fragments {
		if lead := changelog_entry_lead(entry_joined(fragment.lines)); lead != "" {
			places[roadmap_summary_key(lead)] = fmt.tprintf("the fragment %s/%s", FRAGMENT_FOLDER, fragment.file_name)
		}
	}
	for entry in roadmap.entries {
		if entry.summary == "" {
			continue
		}
		if place, found := places[roadmap_summary_key(entry.summary)]; found {
			append(problems, fmt.tprintf("%s, line %d: the summary %q is the summary of %s: this work has a changelog entry. If the work is done, remove its roadmap entry; if a part is left, give the entry a summary that names that part", ROADMAP_FILE, entry.line, entry.summary, place))
		}
	}
}

// The parts that read the files of the repository.

// roadmap_file_exists tells whether a path names a file of the work tree.
roadmap_file_exists :: proc(path: string) -> bool {
	return os.exists(path)
}

// roadmap_read reads ROADMAP.md, and checks its form and its design links.
roadmap_read :: proc(problems: ^[dynamic]string) -> (roadmap: Roadmap, ok: bool) {
	content, err := os.read_entire_file(ROADMAP_FILE, context.temp_allocator)
	if err != nil {
		append(problems, fmt.tprintf("%s: cannot read: %v", ROADMAP_FILE, err))
		return {}, false
	}
	parse_problems: [dynamic]string
	roadmap, parse_problems = roadmap_parse(string(content))
	append(problems, ..parse_problems[:])
	roadmap_design_problems(roadmap, roadmap_file_exists, problems)
	return roadmap, true
}

// roadmap_section_count gives the count of the entries of one section.
roadmap_section_count :: proc(roadmap: Roadmap, section: Roadmap_Section) -> int {
	count := 0
	for entry in roadmap.entries {
		count += entry.section == section ? 1 : 0
	}
	return count
}

roadmap_check :: proc() -> bool {
	problems := make([dynamic]string, context.temp_allocator)
	roadmap, read_ok := roadmap_read(&problems)
	if read_ok {
		// The faults of the changelog itself are those of `changelog check`:
		// this check reads the summaries only.
		changelog_problems := make([dynamic]string, context.temp_allocator)
		changelog, changelog_ok := changelog_read(&changelog_problems)
		fragments := fragments_read(FRAGMENT_FOLDER, &changelog_problems)
		if changelog_ok {
			roadmap_changelog_problems(roadmap, changelog, fragments, &problems)
		}
	}
	if len(problems) > 0 {
		problems_print(problems[:])
		fmt.eprintfln("kerneltool: test failed: the roadmap has %d problems", len(problems))
		return false
	}
	test_passed_print("%s has %d entries (%d now, %d next, %d later), all well formed, and none has the summary of an entry of the changelog", ROADMAP_FILE, len(roadmap.entries), roadmap_section_count(roadmap, .Now), roadmap_section_count(roadmap, .Next), roadmap_section_count(roadmap, .Later))
	return true
}
