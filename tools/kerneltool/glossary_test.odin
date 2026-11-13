package kerneltool

import "core:strings"
import "core:testing"

@(private = "file")
TEST_GLOSSARY :: `# Glossary

The terms.

## Code

### Module

The one format of compiled code.

A module metadata describes it.
A second line of the paragraph.

- a list of the explanation

Do not use: library, ` + "`DLL`" + `.

### Module metadata

The description of a module.

## Running code

### Run

Pages with one protection.

### Run

Bytes of text with one style.

Do not use: span.
`

@(test)
glossary_read_gives_each_part_of_an_entry :: proc(t: ^testing.T) {
	glossary, problems := glossary_read(TEST_GLOSSARY)
	testing.expectf(t, len(problems) == 0, "%v", problems)
	testing.expect_value(t, glossary.title, "Glossary")
	testing.expect_value(t, glossary.introduction, "The terms.")
	testing.expect_value(t, len(glossary.groups), 2)
	code := glossary.groups[0]
	testing.expect_value(t, code.name, "Code")
	testing.expect_value(t, code.id, "code")
	testing.expect_value(t, len(code.terms), 2)
	module_term := code.terms[0]
	testing.expect_value(t, module_term.id, "term-module")
	testing.expect_value(t, module_term.group, "Code")
	testing.expect_value(t, module_term.line, 7)
	testing.expect_value(t, module_term.definition, "The one format of compiled code.")
	testing.expect_value(t, module_term.explanation, "A module metadata describes it.\nA second line of the paragraph.\n\n- a list of the explanation")
	testing.expect_value(t, module_term.explanation_line, 11)
	testing.expect_value(t, module_term.avoided, "library, `DLL`")
	// A term with no explanation and no words to avoid.
	testing.expect_value(t, code.terms[1].explanation, "")
	testing.expect_value(t, code.terms[1].avoided, "")
	// A second term of one name has its own anchor.
	running := glossary.groups[1]
	testing.expect_value(t, running.terms[0].id, "term-run")
	testing.expect_value(t, running.terms[1].id, "term-run-2")
	testing.expect_value(t, running.terms[1].avoided, "span")
	testing.expect_value(t, len(glossary_terms_in_order(glossary)), 4)
	// A page links a name of two entries to its first one.
	terms := site_glossary_terms(glossary)
	testing.expect_value(t, len(terms), 4)
	testing.expect_value(t, terms[0].name, "Module metadata")
	testing.expect_value(t, terms[2].id, "term-run")
	testing.expect(t, !terms[2].second_of_name && terms[3].second_of_name)
}

@(test)
glossary_read_refuses_what_has_not_the_form :: proc(t: ^testing.T) {
	cases := [?]struct {
		text, problem: string,
	} {
		{"# Glossary\n\n## Code\n\n| Term | Definition | Do not use |\n|---|---|---|\n| Module | A module | unit |\n", "line 5: a table of terms"},
		{"# Glossary\n\n## Code\n\n### Module\n\n### Export\n\nA function.\n", "line 5: the term \"Module\" has no short definition"},
		{"# Glossary\n\n## Code\n\n### Module\n\n- a list\n", "starts with no short definition"},
		{"# Glossary\n\n## Code\n\n### Module\n\nA module.\n\nDo not use: unit.\n\nMore text.\n", "line 9: the words that the term \"Module\" replaces are not the last paragraph"},
		{"# Glossary\n\n### Module\n\nA module.\n", "comes before the heading of a group"},
		{"# Glossary\n\n## Code\n\n### Module\n\nA module.\n\n#### Inside\n\nText.\n", "a heading of level 4"},
	}
	for test_case in cases {
		_, problems := glossary_read(test_case.text)
		testing.expectf(t, len(problems) == 1 && strings.contains(problems[0], test_case.problem), "%q gave %v", test_case.text, problems)
	}
}

@(test)
site_glossary_write_sets_the_definition_apart :: proc(t: ^testing.T) {
	site := test_site()
	glossary, _ := glossary_read(TEST_GLOSSARY)
	site.glossary = glossary
	site.terms = site_glossary_terms(glossary)
	renderer := site_renderer_make(&site, site_page_file(SITE_GLOSSARY_FOLDER), SITE_GLOSSARY_FILE)
	renderer.glossary = true
	site_glossary_write(&renderer, glossary)
	html := strings.to_string(renderer.builder)
	expect := [?]string {
		"<section class=\"glossary-group\" aria-labelledby=\"code\">\n<h2 id=\"code\">Code</h2>",
		"<div class=\"term-entry\">\n<h3 id=\"term-module\">Module</h3>\n<p class=\"term-definition\">The one format of compiled code.</p>",
		// The explanation links another term to its entry on the same page.
		"<p>A <a class=\"term\" href=\"#term-module-metadata\">module metadata</a> describes it. A second line of the paragraph.</p>",
		"<ul>\n<li>a list of the explanation</li>\n</ul>",
		"<p class=\"term-avoided\"><span class=\"term-avoided-label\">Do not use</span> library, <code>DLL</code></p>",
		"<h3 id=\"term-run-2\">Run</h3>",
	}
	for part in expect {
		testing.expectf(t, strings.contains(html, part), "%q is not in %s", part, html)
	}
	// On another page, a link to a term has its short definition as its tooltip.
	guide := site_renderer_make(&site, "docs/guides/TEST/index.html", "docs/TEST.md")
	site_render_markdown(&guide, "A module here.\n")
	testing.expect(t, strings.contains(strings.to_string(guide.builder), "<a class=\"term\" href=\"../../../docs/reference/glossary/index.html#term-module\" title=\"The one format of compiled code.\">module</a>"), strings.to_string(guide.builder))
	// An entry never links its own term; the next entry links it.
	module_start := strings.index(html, "<h3 id=\"term-module\">")
	metadata_start := strings.index(html, "<h3 id=\"term-module-metadata\">")
	if !testing.expect(t, module_start >= 0 && metadata_start > module_start) {
		return
	}
	testing.expect(t, !strings.contains(html[module_start:metadata_start], "href=\"#term-module\""), html)
	testing.expect(t, strings.contains(html[metadata_start:], "of a <a class=\"term\" href=\"#term-module\">module</a>."), html)
}

@(test)
glossary_of_the_repository_has_its_form :: proc(t: ^testing.T) {
	content, read_ok := site_read_quiet(SITE_GLOSSARY_FILE)
	testing.expect(t, read_ok)
	glossary, problems := glossary_read(content)
	testing.expectf(t, len(problems) == 0, "%v", problems)
	testing.expect(t, len(glossary_terms_in_order(glossary)) > 400)
}
