#+feature dynamic-literals
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

Each run is in a module.

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
	code_page := site_glossary_group_page("code")
	renderer := site_renderer_make(&site, code_page, SITE_GLOSSARY_FILE)
	renderer.glossary = true
	site_glossary_write(&renderer, glossary.groups[0])
	html := strings.to_string(renderer.builder)
	expect := [?]string {
		"<div class=\"term-entry\">\n<h2 id=\"term-module\">Module</h2>\n<p class=\"term-definition\">The one format of compiled code.</p>",
		// The explanation links another term of the group to its entry on the same page.
		"<p>A <a class=\"term\" href=\"#term-module-metadata\">module metadata</a> describes it. A second line of the paragraph.</p>",
		"<ul>\n<li>a list of the explanation</li>\n</ul>",
		"<p class=\"term-avoided\"><span class=\"term-avoided-label\">Do not use</span> library, <code>DLL</code></p>",
	}
	for part in expect {
		testing.expectf(t, strings.contains(html, part), "%q is not in %s", part, html)
	}
	// An entry links a term of another group to its entry on the page of
	// that group, never to the index.
	running := site_renderer_make(&site, site_glossary_group_page("running-code"), SITE_GLOSSARY_FILE)
	running.glossary = true
	site_glossary_write(&running, glossary.groups[1])
	running_html := strings.to_string(running.builder)
	testing.expect(t, strings.contains(running_html, "<h2 id=\"term-run-2\">Run</h2>"), running_html)
	testing.expect(t, strings.contains(running_html, "in a <a class=\"term\" href=\"../../../../docs/reference/glossary/code/index.html#term-module\">module</a>."), running_html)
	// On another page, a link to a term names the page of its group and
	// has its short definition as its tooltip.
	guide := site_renderer_make(&site, "docs/guides/TEST/index.html", "docs/TEST.md")
	site_render_markdown(&guide, "A module here.\n")
	testing.expect(t, strings.contains(strings.to_string(guide.builder), "<a class=\"term\" href=\"../../../docs/reference/glossary/code/index.html#term-module\" title=\"The one format of compiled code.\">module</a>"), strings.to_string(guide.builder))
	// An entry never links its own term; the next entry links it.
	module_start := strings.index(html, "<h2 id=\"term-module\">")
	metadata_start := strings.index(html, "<h2 id=\"term-module-metadata\">")
	if !testing.expect(t, module_start >= 0 && metadata_start > module_start) {
		return
	}
	testing.expect(t, !strings.contains(html[module_start:metadata_start], "href=\"#term-module\""), html)
	testing.expect(t, strings.contains(html[metadata_start:], "of a <a class=\"term\" href=\"#term-module\">module</a>."), html)
}

// A glossary of three groups, with a name that two groups have and a name
// of two letters, which no page links but the index lists.
@(private = "file")
TEST_GLOSSARY_OF_THREE_GROUPS :: `# Glossary

The terms.

## Network

### Frame

The bytes that a device sends at once.

### IP

The protocol of the addresses.

## Desktop

### Frame

One picture of a surface, made whole.

### Window

A surface that the desktop shows. Each window draws a frame.

## Terms that the system does not have

These words name concepts that the system removed.
`

// The pages of the glossary: one page for each group with its entries, and
// an index with every term once, from A to Z, at the anchor of its entry.
@(test)
site_glossary_pages_split_by_group :: proc(t: ^testing.T) {
	site := test_site()
	glossary, problems := glossary_read(TEST_GLOSSARY_OF_THREE_GROUPS)
	testing.expectf(t, len(problems) == 0, "%v", problems)
	site.glossary = glossary
	site.terms = site_glossary_terms(glossary)
	entry := site_glossary_pages_add(&site)
	index_page := site_page_file(SITE_GLOSSARY_FOLDER)
	testing.expect_value(t, entry.path, index_page)
	testing.expect_value(t, entry.count, 4)
	written := make(map[string]string, context.temp_allocator)
	for page in site.pages {
		written[page.path] = page.body
	}
	// The index and one page for each group, a group with no term too.
	paths := site_glossary_page_paths(glossary)
	testing.expect_value(t, len(paths), 4)
	for path in paths {
		testing.expectf(t, path in written, "the page %s is not written", path)
	}
	testing.expect_value(t, paths[1], "docs/reference/glossary/network/index.html")
	testing.expect_value(t, paths[3], "docs/reference/glossary/terms-that-the-system-does-not-have/index.html")
	testing.expectf(t, len(site_glossary_problems(&site, written)) == 0, "%v", site_glossary_problems(&site, written))

	// Each term resolves to the page of its group: a link of a page, a link
	// of a comment, a result of the search and a reference to a document.
	network_page := site_glossary_group_page("network")
	desktop_page := site_glossary_group_page("desktop")
	expected_pages := map[string]string {
		"term-frame"   = network_page,
		"term-ip"      = network_page,
		"term-frame-2" = desktop_page,
		"term-window"  = desktop_page,
	}
	defer delete(expected_pages)
	for term in glossary_terms_in_order(glossary) {
		testing.expectf(t, site_glossary_anchor_page(&site, term.id) == expected_pages[term.id], "%s is on %s", term.id, site_glossary_anchor_page(&site, term.id))
	}
	for term in site.terms {
		testing.expectf(t, term.page == expected_pages[term.id], "the term %s names the page %s", term.id, term.page)
	}
	link, link_problem := site_comment_link_target(&site, "term:window")
	testing.expect(t, link_problem == "" && link.address == strings.concatenate({desktop_page, "#term-window"}, context.temp_allocator), link_problem)
	for entry_of_search in site_search_entries(&site) {
		if entry_of_search.kind == .Term {
			testing.expectf(t, entry_of_search.page != index_page, "the search sends %s to the index", entry_of_search.title)
		}
	}

	// The two terms of one name keep their two anchors, each on the page
	// of its group, and both are rows of the index.
	index_html := written[index_page]
	testing.expect_value(t, strings.count(written[network_page], " id=\"term-frame\""), 1)
	testing.expect_value(t, strings.count(written[desktop_page], " id=\"term-frame-2\""), 1)
	testing.expect_value(t, strings.count(written[desktop_page], " id=\"term-frame\""), 0)
	testing.expect(t, strings.contains(index_html, "<div id=\"term-frame\" data-group-page=\"../../../docs/reference/glossary/network/index.html\">"), index_html)
	testing.expect(t, strings.contains(index_html, "<div id=\"term-frame-2\" data-group-page=\"../../../docs/reference/glossary/desktop/index.html\">"), index_html)
	// The index lists every term once, the short names too, from A to Z,
	// each with its group as a label.
	testing.expect_value(t, strings.count(index_html, "<div id=\"term-"), 4)
	frame := strings.index(index_html, "<div id=\"term-frame\"")
	ip := strings.index(index_html, "<div id=\"term-ip\"")
	window := strings.index(index_html, "<div id=\"term-window\"")
	testing.expect(t, frame >= 0 && frame < ip && ip < window, index_html)
	testing.expect(t, strings.contains(index_html, "<h3 id=\"letter-f\">F</h3>"), index_html)
	testing.expect(t, strings.contains(index_html, "<span class=\"glossary-index-group\">Desktop</span>"), index_html)
	// No definition of the index links a term: a link to a term never
	// names the index.
	testing.expect(t, !strings.contains(index_html, "class=\"term\""), index_html)
	// The groups with their counts.
	testing.expect(t, strings.contains(index_html, "<a href=\"../../../docs/reference/glossary/network/index.html\">Network</a> <span class=\"glossary-count\">2 terms</span>"), index_html)
	testing.expect(t, strings.contains(index_html, "<span class=\"glossary-count\">no term</span>"), index_html)
	// An entry of a group links the term of another group on its page.
	testing.expect(t, strings.contains(written[desktop_page], "draws a <a class=\"term\" href=\"../../../../docs/reference/glossary/network/index.html#term-frame\">frame</a>."), written[desktop_page])
	// The index has its script; a page of a group has none.
	for page in site.pages {
		testing.expect_value(t, page.script, page.path == index_page ? SITE_GLOSSARY_SCRIPT : "")
	}

	// The check finds an index row that is missing, a row twice, a row
	// that names another page and an entry that is missing.
	missing_row, _ := strings.replace_all(index_html, " id=\"term-window\"", "", context.temp_allocator)
	twice := strings.concatenate({index_html, "<div id=\"term-ip\"></div>"}, context.temp_allocator)
	wrong_page, _ := strings.replace_all(index_html, "<div id=\"term-window\" data-group-page=\"../../../docs/reference/glossary/desktop/index.html\">", "<div id=\"term-window\" data-group-page=\"../../../docs/reference/glossary/network/index.html\">", context.temp_allocator)
	for broken_index in ([]string{missing_row, twice, wrong_page}) {
		broken := make(map[string]string, context.temp_allocator)
		for path, html in written {
			broken[path] = html
		}
		broken[index_page] = broken_index
		testing.expect(t, len(site_glossary_problems(&site, broken)) > 0)
	}
	no_entry := make(map[string]string, context.temp_allocator)
	for path, html in written {
		no_entry[path] = html
	}
	desktop_without_entry, _ := strings.replace_all(written[desktop_page], " id=\"term-window\"", "", context.temp_allocator)
	no_entry[desktop_page] = desktop_without_entry
	testing.expect(t, len(site_glossary_problems(&site, no_entry)) > 0)
	// A page above the bound fails the check.
	too_large := make(map[string]string, context.temp_allocator)
	for path, html in written {
		too_large[path] = html
	}
	filler := strings.repeat("x", SITE_GLOSSARY_PAGE_BYTE_LIMIT, context.temp_allocator)
	too_large[network_page] = strings.concatenate({written[network_page], filler}, context.temp_allocator)
	testing.expect(t, len(site_glossary_problems(&site, too_large)) > 0)

	// Two groups of one slug would be one page: the reader refuses them.
	_, slug_problems := glossary_read("# Glossary\n\n## The code\n\n### Module\n\nA module.\n\n## The Code\n\n### Export\n\nA function.\n")
	testing.expectf(t, len(slug_problems) == 1 && strings.contains(slug_problems[0], "each group is a page"), "%v", slug_problems)
}

// The script of the index: it reads the anchor of a term, finds its row and
// goes to the page that the row names, with the same anchor.
@(test)
site_glossary_script_follows_the_row :: proc(t: ^testing.T) {
	script := site_glossary_script()
	testing.expect(t, strings.contains(script, "getAttribute(\"" + SITE_GLOSSARY_GROUP_PAGE_ATTRIBUTE + "\")"))
	testing.expect(t, strings.contains(script, "\"#term-\""))
	testing.expect(t, strings.contains(script, "location.replace(page + hash)"))
	testing.expect(t, strings.contains(script, "hashchange"))
}

// Every page of the glossary of the repository, with its frame, has at
// most SITE_GLOSSARY_PAGE_BYTE_LIMIT bytes, and each term has its row at
// the index and its entry on the page of its group.
@(test)
site_glossary_pages_of_the_repository :: proc(t: ^testing.T) {
	site := test_site()
	content, read_ok := site_read_quiet(SITE_GLOSSARY_FILE)
	testing.expect(t, read_ok)
	glossary, problems := glossary_read(content)
	testing.expectf(t, len(problems) == 0, "%v", problems)
	site.glossary = glossary
	site.terms = site_glossary_terms(glossary)
	site.documents[SITE_GLOSSARY_FILE] = site_page_file(SITE_GLOSSARY_FOLDER)
	site.documents["GLOSSARY.md"] = site_page_file(SITE_GLOSSARY_FOLDER)
	testing.expect(t, site_reference_read(&site))
	testing.expect(t, site_declarations_read(&site))
	site_glossary_pages_add(&site)
	written := make(map[string]string, context.temp_allocator)
	for page in site.pages {
		written[page.path] = site_page_html(&site, page)
	}
	glossary_problems := site_glossary_problems(&site, written)
	testing.expectf(t, len(glossary_problems) == 0, "%d problems: %v", len(glossary_problems), glossary_problems)
	for path in site_glossary_page_paths(glossary) {
		testing.expectf(t, len(written[path]) <= SITE_GLOSSARY_PAGE_BYTE_LIMIT, "%s has %d bytes", path, len(written[path]))
	}
	// A term of each group resolves to the page of its group.
	for group in glossary.groups {
		if len(group.terms) == 0 {
			continue
		}
		term := group.terms[0]
		testing.expect_value(t, site_glossary_anchor_page(&site, term.id), site_glossary_group_page(group.id))
	}
}

@(test)
glossary_of_the_repository_has_its_form :: proc(t: ^testing.T) {
	content, read_ok := site_read_quiet(SITE_GLOSSARY_FILE)
	testing.expect(t, read_ok)
	glossary, problems := glossary_read(content)
	testing.expectf(t, len(problems) == 0, "%v", problems)
	testing.expect(t, len(glossary_terms_in_order(glossary)) > 400)
}
