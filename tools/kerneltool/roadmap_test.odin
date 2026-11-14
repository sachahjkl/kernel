package kerneltool

import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
GOOD_ROADMAP :: `# Roadmap

A preamble of one line, with **bold** and ` + "`code`" + `.

## Now

- **A window for the debugger.** The debugger gets a window. A step over a call stops after the call.
- **The sources in one folder.** The sources move into ` + "`src`" + `, as 0.5 of them did.
  A second line of the same entry. [Design](src/md/infrastructure/repository_layout.md)

## Next

- **A guest.** A program runs another system in a guest.

## Later
`

@(private = "file")
roadmap_test_file_exists :: proc(path: string) -> bool {
	return path == "src/md/infrastructure/repository_layout.md"
}

@(test)
roadmap_of_a_good_file :: proc(t: ^testing.T) {
	roadmap, problems := roadmap_parse(GOOD_ROADMAP)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	testing.expect_value(t, len(roadmap.entries), 3)
	if len(roadmap.entries) != 3 {
		return
	}
	first, second, third := roadmap.entries[0], roadmap.entries[1], roadmap.entries[2]
	testing.expect_value(t, first.section, Roadmap_Section.Now)
	testing.expect_value(t, first.summary, "A window for the debugger")
	testing.expect_value(t, first.text, "The debugger gets a window. A step over a call stops after the call.")
	testing.expect_value(t, first.design, "")
	testing.expect_value(t, first.line, 7)
	testing.expect_value(t, second.section, Roadmap_Section.Now)
	testing.expect_value(t, second.summary, "The sources in one folder")
	// The lines of an entry are one line, and the design link is not a
	// part of its sentences.
	testing.expect_value(t, second.text, "The sources move into `src`, as 0.5 of them did. A second line of the same entry.")
	testing.expect_value(t, second.design, "src/md/infrastructure/repository_layout.md")
	testing.expect_value(t, second.line, 8)
	testing.expect_value(t, third.section, Roadmap_Section.Next)
	testing.expect_value(t, third.summary, "A guest")
	testing.expect_value(t, third.line, 13)
	// A section with no entry is a list with no item.
	testing.expect_value(t, roadmap_section_count(roadmap, .Now), 2)
	testing.expect_value(t, roadmap_section_count(roadmap, .Next), 1)
	testing.expect_value(t, roadmap_section_count(roadmap, .Later), 0)
	design_problems := make([dynamic]string, context.temp_allocator)
	roadmap_design_problems(roadmap, roadmap_test_file_exists, &design_problems)
	testing.expectf(t, len(design_problems) == 0, "problems: %v", design_problems)
}

@(test)
roadmap_of_a_damaged_file :: proc(t: ^testing.T) {
	Damage :: struct {
		before, after: string,
		// A part of the sentence of the problem that the damage must give.
		problem:       string,
	}
	first_entry :: "- **A window for the debugger.** The debugger gets a window. A step over a call stops after the call."
	damages := []Damage {
		// The title, the front matter and the metadata.
		{"# Roadmap\n", "# The roadmap\n", "the title"},
		{"# Roadmap\n", "---\ntitle: Roadmap\n---\n\n# Roadmap\n", "the title"},
		{"A preamble of one line", "status: draft", "a field \"key: value\""},
		{"A preamble of one line", "- **An entry.** Too early.\n\nA preamble of one line", "before the heading of its section"},
		// The sections: their names, their order, their count, no other heading.
		{"## Now", "## Today", "is not expected here"},
		{"## Next", "## Later", "is not expected here"},
		{"## Next\n\n- **A guest.** A program runs another system in a guest.\n\n", "", "is not expected here"},
		{"\n## Later\n", "", "the section \"## Later\" is not in the file"},
		{"## Later\n", "## Later\n\n## Done\n", "is not expected here"},
		{"## Next", "### Soon\n\n## Next", "is not expected here"},
		{"## Now\n\n", "## Now\n", "an empty line is expected after a heading"},
		{"\n\n## Next", "\n## Next", "an empty line is expected before a heading"},
		{"\n\n## Next", "\n\n\n## Next", "a second empty line"},
		// A section is a list.
		{first_entry, "The debugger gets a window.", "a section is a list"},
		{first_entry, "-  **Two spaces.** A sentence.", "two spaces after the \"-\""},
		// The form of an entry.
		{first_entry, "- A window for the debugger. The debugger gets a window.", "does not start with a bold summary"},
		{first_entry, "- **A window for the debugger. The debugger gets a window.", "the bold summary has no end"},
		{first_entry, "- **A window for the debugger** The debugger gets a window.", "does not end with a period inside the bold"},
		{first_entry, "- **.** The debugger gets a window.", "the summary is empty"},
		{first_entry, strings.concatenate({"- **", strings.repeat("a", ROADMAP_SUMMARY_MOST + 1, context.temp_allocator), ".** A sentence."}, context.temp_allocator), "at most"},
		{first_entry, "- **A [window] for the debugger.** The debugger gets a window.", "one of the characters"},
		{first_entry, "- **A window for the debugger.**", "one or two sentences are expected"},
		{first_entry, "- **A window for the debugger.**The debugger gets a window.", "one or two sentences are expected"},
		{first_entry, "- **A window for the debugger.** The debugger gets a window", "does not end with the end of a sentence"},
		{first_entry, "- **A window for the debugger.** One. Two. Three.", "3 sentences"},
		// No date, no HTML, no decision, no person.
		{first_entry, "- **A window for the debugger.** The debugger gets a window on 2026-12-01.", "the date \"2026-12-01\""},
		{first_entry, "- **A window for the debugger.** The debugger gets a window in December 2026.", "the date \"December 2026\""},
		{first_entry, "- **A window for the debugger.** The debugger gets a <b>window</b>.", "a tag of HTML"},
		{first_entry, "- **A window for the debugger.** The debugger gets a window, as D-234 says.", "the decision D-234"},
		{first_entry, "- **A window for the debugger.** The owner asked for a window.", "the word \"owner\""},
		{"A preamble of one line", "A preamble of November 2026", "the date \"November 2026\""},
		// The links.
		{first_entry, "- **A window for the debugger.** The debugger gets [a window](docs/TOOLS.md).", "a link in the sentences"},
		{"[Design](src/md/infrastructure/repository_layout.md)", "[Design](docs/TOOLS.md)", "it names an intent file"},
		{"[Design](src/md/infrastructure/repository_layout.md)", "[Design](src/md/../../secret.md)", "it names an intent file"},
		{"[Design](src/md/infrastructure/repository_layout.md)", "[Design](src/md/infrastructure/repository_layout.md) and more.", "the last part of an entry"},
		// No entry twice, with no regard to case and to marks.
		{"- **A guest.**", "- **a window, for the Debugger.**", "an entry is in the file one time"},
		// The form of the lines.
		{"The debugger gets a window. ", "The debugger gets a window.\t", "a tab"},
		{"## Later\n", "## Later", "one line feed"},
		{"## Later\n", "## Later\n\n", "one line feed"},
	}
	for damage in damages {
		testing.expectf(t, strings.contains(GOOD_ROADMAP, damage.before), "the good file does not hold %q", damage.before)
		damaged, _ := strings.replace(GOOD_ROADMAP, damage.before, damage.after, 1, context.temp_allocator)
		_, problems := roadmap_parse(damaged)
		found := false
		for problem in problems {
			found ||= strings.contains(problem, damage.problem)
		}
		testing.expectf(t, found, "%q in place of %q: no problem holds %q; the problems: %v", damage.after, damage.before, damage.problem, problems)
	}
}

// Each problem names the file and the line of its fault.
@(test)
roadmap_problem_names_its_line :: proc(t: ^testing.T) {
	damaged, _ := strings.replace(GOOD_ROADMAP, "- **A guest.** A program runs another system in a guest.", "- **A guest.** One. Two. Three.", 1, context.temp_allocator)
	_, problems := roadmap_parse(damaged)
	testing.expect_value(t, len(problems), 1)
	if len(problems) == 1 {
		testing.expect_value(t, problems[0], "ROADMAP.md, line 13: 3 sentences after the summary; an entry has one or two: what the work gives the user")
	}
}

@(test)
roadmap_design_link_names_a_file :: proc(t: ^testing.T) {
	damaged, _ := strings.replace(GOOD_ROADMAP, "repository_layout.md", "no_such_file.md", 1, context.temp_allocator)
	roadmap, problems := roadmap_parse(damaged)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	design_problems := make([dynamic]string, context.temp_allocator)
	roadmap_design_problems(roadmap, roadmap_test_file_exists, &design_problems)
	testing.expect_value(t, len(design_problems), 1)
	if len(design_problems) == 1 {
		testing.expect_value(t, design_problems[0], "ROADMAP.md, line 8: the design link names src/md/infrastructure/no_such_file.md, which is not a file of the repository")
	}
}

@(test)
roadmap_sentences_are_counted :: proc(t: ^testing.T) {
	Case :: struct {
		text:       string,
		count:      int,
		ends_whole: bool,
	}
	cases := []Case {
		{"One sentence.", 1, true},
		{"One. Two.", 2, true},
		{"Is it one? It is two!", 2, true},
		{"The number 0.5 ends no sentence.", 1, true},
		{"The span `a.b. c` ends no sentence.", 1, true},
		{"No end", 0, false},
		{"One. Then no end", 1, false},
		{"", 0, false},
	}
	for item in cases {
		count, ends_whole := roadmap_sentence_count(item.text)
		testing.expectf(t, count == item.count && ends_whole == item.ends_whole, "%q: %d sentences, ends whole %v; expected %d and %v", item.text, count, ends_whole, item.count, item.ends_whole)
	}
}

@(test)
roadmap_dates_are_found :: proc(t: ^testing.T) {
	testing.expect_value(t, roadmap_date_in_text("on 2026-11-14, then"), "2026-11-14")
	testing.expect_value(t, roadmap_date_in_text("in November 2026"), "November 2026")
	testing.expect_value(t, roadmap_date_in_text("in may, 1999."), "may, 1999")
	// A count, a release number, a month with no year and a word that holds
	// the name of a month are not dates.
	testing.expect_value(t, roadmap_date_in_text("a picture of 2048 pixels"), "")
	testing.expect_value(t, roadmap_date_in_text("the release 0.91.0"), "")
	testing.expect_value(t, roadmap_date_in_text("the march of 2000 threads"), "")
	testing.expect_value(t, roadmap_date_in_text("a dismay 2026"), "")
	testing.expect_value(t, roadmap_date_in_text("the number 12026-11-14"), "")
	testing.expect_value(t, roadmap_date_in_text("November 20264"), "")
}

@(test)
roadmap_other_refused_texts_are_found :: proc(t: ^testing.T) {
	testing.expect(t, roadmap_html_in_text("a <b>word</b>"))
	testing.expect(t, roadmap_html_in_text("a <!-- comment -->"))
	testing.expect(t, !roadmap_html_in_text("a < b, and `<b>` in code"))
	testing.expect_value(t, roadmap_decision_in_text("as D-047 says"), "D-047")
	testing.expect_value(t, roadmap_decision_in_text("the card D-shaped, and ID-12"), "")
	testing.expect(t, roadmap_word_in_text("The Owner asked", "owner"))
	testing.expect(t, !roadmap_word_in_text("the owners of a store", "owner"))
}

// An entry whose summary is the bold summary of a fragment, or of an entry
// of a release, is refused: its work has a changelog entry.
@(test)
roadmap_entry_with_a_changelog_entry_is_refused :: proc(t: ^testing.T) {
	roadmap, problems := roadmap_parse(GOOD_ROADMAP)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	released_lines := []string{"**A guest**: a program runs another system."}
	other_lines := []string{"**The console**: it draws results."}
	changelog := Changelog {
		releases = []Changelog_Release{{number = {0, 9, 0}, date = "2026-11-10", line = 5, entries = []Changelog_Entry{{type_index = 0, lines = released_lines, line = 9}, {type_index = 0, lines = other_lines, line = 10}}}},
	}
	fragment_lines := []string{"**a window for the `debugger`**: the debugger", "has a window."}
	plain_lines := []string{"A fragment with no bold summary names no entry."}
	fragments := []Fragment {
		{file_name = "20261114-120000-debugger-window.md", type_index = 0, lines = fragment_lines},
		{file_name = "20261114-120100-plain.md", type_index = 0, lines = plain_lines},
	}
	found := make([dynamic]string, context.temp_allocator)
	roadmap_changelog_problems(roadmap, changelog, fragments, &found)
	testing.expect_value(t, len(found), 2)
	if len(found) == 2 {
		testing.expect(t, strings.has_prefix(found[0], "ROADMAP.md, line 7: the summary \"A window for the debugger\" is the summary of the fragment changelog.d/20261114-120000-debugger-window.md: this work has a changelog entry."))
		testing.expect(t, strings.has_prefix(found[1], "ROADMAP.md, line 13: the summary \"A guest\" is the summary of an entry of the release 0.9.0 of CHANGELOG.md: this work has a changelog entry."))
	}
	none := make([dynamic]string, context.temp_allocator)
	roadmap_changelog_problems(roadmap, Changelog{}, nil, &none)
	testing.expect_value(t, len(none), 0)
	testing.expect_value(t, changelog_entry_lead("**The thing**: what it does."), "The thing")
	testing.expect_value(t, changelog_entry_lead("No bold summary."), "")
	testing.expect_value(t, changelog_entry_lead("**No end"), "")
}

// The file of the repository is well formed: the site and `kerneltool
// check` read it.
@(test)
roadmap_of_the_repository :: proc(t: ^testing.T) {
	if !os.exists(ROADMAP_FILE) {
		// The test runner starts in another folder than the root.
		return
	}
	problems := make([dynamic]string, context.temp_allocator)
	roadmap, read_ok := roadmap_read(&problems)
	testing.expect(t, read_ok)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	testing.expect(t, len(roadmap.entries) > 0)
}
