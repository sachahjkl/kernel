package kerneltool

import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
GOOD_CHANGELOG :: `# Changelog

All notable changes. The format is Keep a Changelog.

## [0.2.0] - 2026-11-11

### Added

- **Two**: a thing
  on two lines.

### Fixed

- A fault.

## [0.1.0] - 2026-11-10

### Added

- One.
`

@(private = "file")
has_problem :: proc(problems: [dynamic]string, part: string) -> bool {
	for problem in problems {
		if strings.contains(problem, part) {
			return true
		}
	}
	return false
}

@(test)
changelog_well_formed_is_read :: proc(t: ^testing.T) {
	changelog, problems := changelog_parse(GOOD_CHANGELOG)
	testing.expect_value(t, len(problems), 0)
	testing.expect_value(t, len(changelog.releases), 2)
	testing.expect_value(t, changelog.releases[0].number, Release_Number{0, 2, 0})
	testing.expect_value(t, changelog.releases[0].date, "2026-11-11")
	testing.expect_value(t, len(changelog.releases[0].entries), 2)
	testing.expect_value(t, entry_joined(changelog.releases[0].entries[0].lines), "**Two**: a thing on two lines.")
	testing.expect_value(t, changelog.releases[0].entries[1].type_index, 4)
	testing.expect_value(t, changelog.releases[1].line, 16)
	testing.expect_value(t, changelog.first_release_line, 4)
}

@(test)
changelog_faults_are_named_with_their_line :: proc(t: ^testing.T) {
	Case :: struct {
		content, expected: string,
	}
	cases := []Case {
		{"# Change log\n", "line 1: the title"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n### Added\n\n- One.", "end with one line feed"},
		{"# Changelog\n\n## [0.1] - 2026-11-10\n\n### Added\n\n- One.\n", "line 3: the heading"},
		{"# Changelog\n\n## [0.1.0] - 2026-02-30\n\n### Added\n\n- One.\n", "line 3: the heading"},
		{"# Changelog\n\n## [0.01.0] - 2026-11-10\n\n### Added\n\n- One.\n", "line 3: the heading"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n### Added\n\n- One.\n\n## [0.2.0] - 2026-11-10\n\n### Added\n\n- Two.\n", "line 9: the release 0.2.0 is not older"},
		{"# Changelog\n\n## [0.2.0] - 2026-11-10\n\n### Added\n\n- One.\n\n## [0.1.0] - 2026-11-11\n\n### Added\n\n- Two.\n", "line 9: the date 2026-11-11 is after"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n### Fixed\n\n- One.\n\n### Added\n\n- Two.\n", "line 9: the parts of a release are in the order"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n### Added\n\n- One.\n\n### Added\n\n- Two.\n", "line 9: the parts of a release are in the order"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n### Improved\n\n- One.\n", "line 5: the type \"Improved\" is not known"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n### Added\n\n### Fixed\n\n- One.\n", "line 5: the part has no entry"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n## [0.0.1] - 2026-11-10\n\n### Added\n\n- One.\n", "line 3: the release 0.1.0 has no entry"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n### Added\n\n- One.\n", "line 4: an empty line is expected before a heading"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n### Added\n- One.\n", "line 6: an empty line is expected after a heading"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n### Added\n\n- One.\n\n\n- Two.\n", "line 9: a second empty line"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n### Added\n\n- One.\nnot indented\n", "line 8: an entry \"- <text>\""},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n### Added\n\n- One. \n", "line 7: the line has a tab"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n#### Added\n\n- One.\n", "line 5: a heading of the level 2"},
		{"# Changelog\n\n## [0.1.0] - 2026-11-10\n\n- One.\n", "line 5: an entry before the heading of its type"},
	}
	for test_case in cases {
		_, problems := changelog_parse(test_case.content)
		testing.expectf(t, has_problem(problems, test_case.expected), "%q: the problem %q is expected, the problems are %v", test_case.content, test_case.expected, problems)
	}
}

@(test)
fragment_well_formed_is_read :: proc(t: ^testing.T) {
	fragment, problems := fragment_parse("20261111-120000-thing.md", "type: Fixed\n\n**A thing**: it works\nnow.\n")
	testing.expect_value(t, len(problems), 0)
	testing.expect_value(t, fragment.type_index, 4)
	testing.expect_value(t, len(fragment.lines), 2)
	written, written_problems := fragment_parse("20261111-120000-thing.md", fragment_text("Added", "  one line  "))
	testing.expect_value(t, len(written_problems), 0)
	testing.expect_value(t, written.lines[0], "one line")
}

@(test)
fragment_hostile_is_refused :: proc(t: ^testing.T) {
	Case :: struct {
		file_name, content, expected: string,
	}
	good :: "type: Added\n\nText.\n"
	cases := []Case {
		{"thing.md", good, "the name of a fragment is"},
		{"20261111-120000-thing.txt", good, "the name of a fragment is"},
		{"20261311-120000-thing.md", good, "is not a date of the calendar"},
		{"20261111-250000-thing.md", good, "is not a time of the day"},
		{"20261111-120000-Thing.md", good, "only the lowercase letters"},
		{"20261111-120000-a/b.md", good, "only the lowercase letters"},
		{"20261111-120000--thing.md", good, "starts or ends with -"},
		{"20261111-120000-a--b.md", good, "starts or ends with -"},
		{"20261111-120000-.md", good, "the name of a fragment is"},
		{"20261111-120000-thing.md", "", "line 1: the line \"type: <type>\""},
		{"20261111-120000-thing.md", "Added\n\nText.\n", "line 1: the line \"type: <type>\""},
		{"20261111-120000-thing.md", "type: added\n\nText.\n", "the type \"added\" is not known"},
		{"20261111-120000-thing.md", "type: Improved\n\nText.\n", "the type \"Improved\" is not known"},
		{"20261111-120000-thing.md", "type: Added\nText.\n", "line 2: an empty line is expected"},
		{"20261111-120000-thing.md", "type: Added\n\n", "line 3: the text of the change is expected"},
		{"20261111-120000-thing.md", "type: Added\n\n   \n", "line 3: the text of the change is expected"},
		{"20261111-120000-thing.md", "type: Added\n", "line 2: an empty line is expected"},
		{"20261111-120000-thing.md", "type: Added\n\nOne.\n\nTwo.\n", "line 4: an empty line inside the text"},
		{"20261111-120000-thing.md", "type: Added\n\nOne.\n- Two.\n", "line 4: the line starts with \"- \""},
		{"20261111-120000-thing.md", "type: Added\n\n## Heading\n", "line 3: the line is a heading"},
		{"20261111-120000-thing.md", "type: Added\n\nOne.\r\n", "line 3: the line has a tab or a carriage return"},
		{"20261111-120000-thing.md", "type: Added\n\nOne\tTwo.\n", "line 3: the line has a tab"},
		{"20261111-120000-thing.md", "type: Added\n\n  One.\n", "line 3: the line starts with a space"},
	}
	for test_case in cases {
		_, problems := fragment_parse(test_case.file_name, test_case.content)
		testing.expectf(t, has_problem(problems, test_case.expected), "%s %q: the problem %q is expected, the problems are %v", test_case.file_name, test_case.content, test_case.expected, problems)
	}
}

@(test)
release_is_assembled_in_the_fixed_order :: proc(t: ^testing.T) {
	fragments := []Fragment {
		{file_name = "20261112-090000-later-fix.md", type_index = 4, lines = {"A later fix."}},
		{file_name = "20261112-080000-security.md", type_index = 5, lines = {"A closed fault."}},
		// Two fragments of the same second: the subject decides.
		{file_name = "20261112-080000-zeta.md", type_index = 0, lines = {"Zeta.", "On two lines."}},
		{file_name = "20261112-080000-alpha.md", type_index = 0, lines = {"Alpha."}},
		{file_name = "20261112-070000-early-fix.md", type_index = 4, lines = {"An early fix."}},
		{file_name = "20261112-100000-change.md", type_index = 1, lines = {"A change."}},
	}
	fragments_in_release_order(fragments)
	section := release_section_text({0, 3, 0}, "2026-11-12", fragments)
	expected :: `## [0.3.0] - 2026-11-12

### Added

- Alpha.
- Zeta.
  On two lines.

### Changed

- A change.

### Fixed

- An early fix.
- A later fix.

### Security

- A closed fault.
`
	testing.expect_value(t, section, expected)
	old, _ := changelog_parse(GOOD_CHANGELOG)
	content := changelog_with_release(old, section)
	changelog, problems := changelog_parse(content)
	testing.expect_value(t, len(problems), 0)
	testing.expect_value(t, len(changelog.releases), 3)
	testing.expect_value(t, changelog.releases[0].number, Release_Number{0, 3, 0})
	testing.expect_value(t, len(changelog.releases[0].entries), 6)
	good_changelog := GOOD_CHANGELOG
	testing.expect(t, strings.has_suffix(content, good_changelog[strings.index(good_changelog, "## [0.2.0]"):]))
	// A first release in a changelog with no release.
	empty, empty_problems := changelog_parse("# Changelog\n\nThe preamble.\n")
	testing.expect_value(t, len(empty_problems), 0)
	first, first_problems := changelog_parse(changelog_with_release(empty, section))
	testing.expect_value(t, len(first_problems), 0)
	testing.expect_value(t, len(first.releases), 1)
}

@(test)
released_fragment_is_refused :: proc(t: ^testing.T) {
	changelog, _ := changelog_parse(GOOD_CHANGELOG)
	fragments := []Fragment {
		{file_name = "20261112-080000-again.md", type_index = 0, lines = {"**Two**: a thing on", "two lines."}},
		{file_name = "20261112-080000-new.md", type_index = 0, lines = {"New."}},
	}
	problems := make([dynamic]string, context.temp_allocator)
	released_fragment_problems(changelog, fragments, &problems)
	testing.expect_value(t, len(problems), 1)
	testing.expect(t, has_problem(problems, "changelog.d/20261112-080000-again.md: its text is already an entry of the release 0.2.0"))
}

@(test)
fragment_folder_is_read :: proc(t: ^testing.T) {
	folder :: BUILD_FOLDER + "/test_changelog_fragments"
	_ = os.remove_all(folder)
	testing.expect(t, make_folder(folder))
	defer os.remove_all(folder)
	problems := make([dynamic]string, context.temp_allocator)
	// An empty folder: no fragment, no problem.
	testing.expect_value(t, len(fragments_read(folder, &problems)), 0)
	testing.expect_value(t, len(problems), 0)
	_ = os.write_entire_file(folder + "/" + FRAGMENT_FOLDER_GUIDE, transmute([]u8)string("# changelog.d\n"))
	_ = os.write_entire_file(folder + "/20261112-080000-b.md", transmute([]u8)string("type: Fixed\n\nB.\n"))
	_ = os.write_entire_file(folder + "/20261112-080000-a.md", transmute([]u8)string("type: Added\n\nA.\n"))
	_ = os.write_entire_file(folder + "/notes.txt", transmute([]u8)string("type: Added\n\nA.\n"))
	_ = os.make_directory(folder + "/inner")
	fragments := fragments_read(folder, &problems)
	testing.expect_value(t, len(fragments), 3)
	testing.expect_value(t, fragments[0].file_name, "20261112-080000-a.md")
	testing.expect_value(t, len(problems), 2)
	testing.expect(t, has_problem(problems, "inner: a folder"))
	testing.expect(t, has_problem(problems, "notes.txt: the name of a fragment is"))
}

@(test)
release_number_is_read :: proc(t: ^testing.T) {
	number, ok := release_number_parse("0.58.0")
	testing.expect(t, ok)
	testing.expect_value(t, number, Release_Number{0, 58, 0})
	for bad in ([]string{"", "0.58", "0.58.0.1", "0.058.0", "a.b.c", "0..1", "-1.0.0", "0.58.0-rc"}) {
		_, bad_ok := release_number_parse(bad)
		testing.expectf(t, !bad_ok, "%q is not a release number", bad)
	}
	testing.expect(t, release_number_less({0, 58, 0}, {0, 58, 1}))
	testing.expect(t, release_number_less({0, 58, 1}, {0, 59, 0}))
	testing.expect(t, !release_number_less({0, 59, 0}, {0, 59, 0}))
}
