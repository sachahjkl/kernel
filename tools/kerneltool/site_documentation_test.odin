package kerneltool

import "core:strings"
import "core:testing"

// The check of the layout: a documentation page has one tree and one list
// "On this page" whose links name ids of the page; a presentation page has
// neither.
@(test)
site_documentation_layout_checks :: proc(t: ^testing.T) {
	page := Site_Page{path = "docs/guides/A/index.html", title = "A", layout = .Documentation}
	ids := make(map[string]bool, context.temp_allocator)
	ids["content"] = true
	ids["part"] = true
	good := strings.concatenate({SITE_TREE_OPEN, "<a href=\"../../../docs/guides/index.html\">Guides</a></nav>", SITE_OUTLINE_OPEN, "<summary>On this page</summary><a href=\"#content\">A</a><a href=\"#part\">P</a></nav></details>"}, context.temp_allocator)
	testing.expect_value(t, site_layout_problem(page, good, ids), "")

	Damage :: struct {
		before, after: string,
	}
	damages := []Damage {
		{SITE_TREE_OPEN, ""}, // No tree.
		{SITE_TREE_OPEN, strings.concatenate({SITE_TREE_OPEN, "</nav>", SITE_TREE_OPEN}, context.temp_allocator)}, // Two trees.
		{SITE_OUTLINE_OPEN, ""}, // No list "On this page".
		{"href=\"#part\"", "href=\"#absent\""}, // An id that the page does not have.
		{"href=\"#part\"", "href=\"../B/index.html#part\""}, // A link to another page.
		{"href=\"#part\"", "href=\"#\""}, // An empty anchor.
	}
	for damage in damages {
		damaged, changed := strings.replace(good, damage.before, damage.after, 1, context.temp_allocator)
		testing.expectf(t, changed, "the text %q is not in the good page", damage.before)
		testing.expectf(t, site_layout_problem(page, damaged, ids) != "", "no problem found after %q became %q", damage.before, damage.after)
	}
	no_links, _ := strings.replace(good, "<a href=\"#content\">A</a><a href=\"#part\">P</a>", "", 1, context.temp_allocator)
	testing.expect(t, site_layout_problem(page, no_links, ids) != "")

	presentation := page
	presentation.layout = .Presentation
	testing.expect(t, site_layout_problem(presentation, good, ids) != "")
	testing.expect_value(t, site_layout_problem(presentation, "<h1>A</h1>", ids), "")
}

// The list "On this page" reads the headings h2 and h3 with an id and the
// elements that state a symbol, in the order of the page.
@(test)
site_documentation_outline_of_a_body :: proc(t: ^testing.T) {
	body := "<h1 id=\"top\">T</h1><h2 id=\"a\">A <code>x</code> &amp; y</h2><p>Text.</p><h3 id=\"b\">B</h3><table><tr id=\"r\" data-outline=\"Row_Name\"><td>1</td></tr><tr id=\"plain\"><td>2</td></tr></table><h4 id=\"c\">C</h4><h2>No id</h2>"
	entries := site_outline_entries(body)
	testing.expect_value(t, len(entries), 3)
	if len(entries) != 3 {
		return
	}
	testing.expect_value(t, entries[0].id, "a")
	testing.expect_value(t, entries[0].text, "A x &amp; y")
	testing.expect_value(t, entries[0].level, 2)
	testing.expect_value(t, entries[1].id, "b")
	testing.expect_value(t, entries[1].level, 3)
	testing.expect_value(t, entries[2].id, "r")
	testing.expect_value(t, entries[2].text, "Row_Name")
	testing.expect_value(t, entries[2].level, 0)

	page := Site_Page{title = "The <page>", body = body, layout = .Documentation}
	html := site_outline_html(page)
	testing.expect(t, strings.has_prefix(html, SITE_OUTLINE_OPEN))
	testing.expect(t, strings.contains(html, "<a href=\"#content\" aria-current=\"location\">The &lt;page&gt;</a>"))
	// The heading of level 3 and the symbol are the branches of the heading
	// of level 2 before them, in one list of tree lines.
	testing.expect(t, strings.contains(html, "<li class=\"outline-level-2\"><a href=\"#a\">A x &amp; y</a>\n" + SITE_TREE_LINES_LIST_OPEN + "\n<li class=\"outline-level-3\"><a href=\"#b\">B</a></li>\n<li class=\"outline-symbol\"><a href=\"#r\"><code>Row_Name</code></a></li>\n</ul>\n</li>\n</ul>\n</nav>\n</details>\n"))
	testing.expect_value(t, strings.count(html, SITE_TREE_LINES_LIST_OPEN), 1)
	testing.expect_value(t, site_tree_lines_problem(html), "")
}

// The count of the starts and of the ends of the lists and of the items
// of an HTML text is the same: each list and each item is closed.
@(private = "file")
expect_lists_closed :: proc(t: ^testing.T, html: string) {
	testing.expect_value(t, strings.count(html, "<ul"), strings.count(html, "</ul>"))
	testing.expect_value(t, strings.count(html, "<li"), strings.count(html, "</li>"))
}

// "On this page" as a tree: a symbol with no heading of level 2 before it
// is a branch of the title of the page; a heading of level 2 ends the
// branches of the item before it; a page with no heading has one list.
@(test)
site_documentation_outline_is_a_tree :: proc(t: ^testing.T) {
	symbols_first := Site_Page{title = "T", layout = .Documentation, body = "<h1 id=\"top\">T</h1><h3 id=\"s\" data-outline=\"S\">S</h3><h2 id=\"a\">A</h2><h2 id=\"b\">B</h2><h3 id=\"c\">C</h3>"}
	html := site_outline_html(symbols_first)
	testing.expect(t, strings.contains(html, "<li class=\"outline-top\"><a href=\"#content\" aria-current=\"location\">T</a>\n" + SITE_TREE_LINES_LIST_OPEN + "\n<li class=\"outline-symbol\"><a href=\"#s\"><code>S</code></a></li>\n</ul>\n</li>\n<li class=\"outline-level-2\"><a href=\"#a\">A</a></li>\n<li class=\"outline-level-2\"><a href=\"#b\">B</a>\n" + SITE_TREE_LINES_LIST_OPEN + "\n<li class=\"outline-level-3\"><a href=\"#c\">C</a></li>\n</ul>\n</li>\n</ul>\n"))
	testing.expect_value(t, strings.count(html, SITE_TREE_LINES_LIST_OPEN), 2)
	testing.expect_value(t, site_tree_lines_problem(html), "")
	expect_lists_closed(t, html)

	no_heading := site_outline_html(Site_Page{title = "T", layout = .Documentation, body = "<h1 id=\"top\">T</h1><p>Text.</p>"})
	testing.expect(t, strings.contains(no_heading, "<ul>\n<li class=\"outline-top\"><a href=\"#content\" aria-current=\"location\">T</a></li>\n</ul>\n</nav>\n</details>\n"))
	testing.expect_value(t, strings.count(no_heading, SITE_TREE_LINES_LIST_OPEN), 0)
	testing.expect_value(t, site_tree_lines_problem(no_heading), "")
	expect_lists_closed(t, no_heading)
}

// The check of the tree lines: a list under an item, inside a nav element,
// has the class of the tree lines; a list of the text of a page does not
// need it.
@(test)
site_documentation_tree_lines_check :: proc(t: ^testing.T) {
	testing.expect(t, site_tag_is("<li>", "li"))
	testing.expect(t, site_tag_is("<li class=\"a\">", "li"))
	testing.expect(t, !site_tag_is("<link rel=\"a\">", "li"))
	testing.expect(t, !site_tag_is("</li>", "li"))
	testing.expect(t, !site_tag_is("<l>", "li"))

	good := "<nav><ul><li><a href=\"a\">A</a>\n<ul class=\"other tree-lines\"><li>B<ol class=\"tree-lines\"><li>C</li></ol></li></ul></li><li>D</li></ul></nav><article><ul><li>E<ul><li>F</li></ul></li></ul></article>"
	testing.expect_value(t, site_tree_lines_problem(good), "")
	Damage :: struct {
		before, after: string,
	}
	damages := []Damage {
		{"<ul class=\"other tree-lines\">", "<ul>"}, // No class.
		{"<ul class=\"other tree-lines\">", "<ul class=\"other\">"}, // Another class.
		{"<ul class=\"other tree-lines\">", "<ul class=\"tree-lines-of-another-name\">"}, // A class that only starts with the name.
		{"<ol class=\"tree-lines\">", "<ol>"}, // The list of the third level.
		{"</nav><article>", "<article>"}, // The lists of the text are now inside the navigation.
	}
	for damage in damages {
		damaged, changed := strings.replace(good, damage.before, damage.after, 1, context.temp_allocator)
		testing.expectf(t, changed, "the text %q is not in the good page", damage.before)
		testing.expectf(t, site_tree_lines_problem(damaged) != "", "no problem found after %q became %q", damage.before, damage.after)
	}
	// A second navigation after a first one starts with no open item.
	testing.expect_value(t, site_tree_lines_problem("<nav><ul><li>A</nav><nav><ul><li>B</li></ul></nav>"), "")
}

// The documentation tree of each part: each list under an item is a list
// of tree lines, to the deepest level (a group of the glossary, a module
// of a group), and the check of the pages finds a page whose tree lost
// the class.
@(test)
site_documentation_tree_has_tree_lines :: proc(t: ^testing.T) {
	site := test_site()
	glossary_page := site_page_file(SITE_GLOSSARY_FOLDER)
	modules_page := site_page_file(SITE_MODULES_FOLDER)
	group_page := site_glossary_group_page("code")
	guide_page :: SITE_GUIDE_FOLDER + "/A/" + SITE_PAGE
	site.guides = make([dynamic]Site_Guide, context.temp_allocator)
	append(&site.guides, Site_Guide{source = "docs/A.md", path = guide_page, title = "Guide A"})
	terms := make([]Glossary_Term, 2, context.temp_allocator)
	groups := make([]Glossary_Group, 1, context.temp_allocator)
	groups[0] = Glossary_Group{name = "Code", id = "code", terms = terms}
	site.glossary.groups = groups
	entries := make([]Site_Reference_Entry, 2, context.temp_allocator)
	entries[0] = Site_Reference_Entry{path = glossary_page, title = "Glossary"}
	entries[1] = Site_Reference_Entry{path = modules_page, title = "Modules"}
	site.reference_entries = entries
	modules := make([]Site_Module, 2, context.temp_allocator)
	modules[0] = {build = {name = "kernel", source = "kernel", kernel = true}, kind = "module", page = site_module_page("kernel")}
	modules[1] = {build = {name = "math", source = "support/math"}, kind = "module", page = site_module_page("math")}
	site.reference.modules = modules
	paths := [?]string{site_section_page(.Docs), site_section_page(.Guides), guide_page, site_section_page(.Reference), glossary_page, group_page, modules_page, modules[0].page, modules[1].page, site_section_page(.Status)}
	for path in paths {
		site_page_add(&site, Site_Page{path = path, title = "A page", layout = .Documentation})
	}

	// A page of the reference: the reference pages, the groups of the
	// glossary under the glossary, the modules under their groups.
	reference_tree := site_tree_html(&site, Site_Page{path = group_page, section = .Reference, layout = .Documentation})
	testing.expect_value(t, site_tree_lines_problem(reference_tree), "")
	// The reference, the glossary, the modules, and the two groups of modules.
	testing.expect_value(t, strings.count(reference_tree, SITE_TREE_LINES_LIST_OPEN), 5)
	// The first list of the tree is the one list with no tree lines.
	testing.expect_value(t, strings.count(reference_tree, "<ul"), 6)
	testing.expect_value(t, strings.count(reference_tree, "<ul class=\"tree-sections\">"), 1)
	expect_lists_closed(t, reference_tree)
	testing.expect(t, strings.contains(reference_tree, "Glossary</a>\n" + SITE_TREE_LINES_LIST_OPEN + "\n<li><a href=\""))
	testing.expect(t, strings.contains(reference_tree, " aria-current=\"page\">Code <span class=\"tree-count\">2</span></a></li>"))
	testing.expect(t, strings.contains(reference_tree, "<li><span class=\"tree-group\">Kernel <span class=\"tree-count\">1</span></span>\n" + SITE_TREE_LINES_LIST_OPEN + "\n<li><a href=\""))

	// A guide: the guides under their index.
	guide_tree := site_tree_html(&site, Site_Page{path = guide_page, section = .Guides, layout = .Documentation})
	testing.expect_value(t, site_tree_lines_problem(guide_tree), "")
	testing.expect_value(t, strings.count(guide_tree, SITE_TREE_LINES_LIST_OPEN), 1)
	testing.expect_value(t, strings.count(guide_tree, "<ul"), 2)
	expect_lists_closed(t, guide_tree)

	// The check of the pages finds a navigation whose nested list is plain.
	pages := [?]Site_Page{{path = "index.html", title = "Home", description = "The home.", body = ""}}
	files := make(map[string]int, context.temp_allocator)
	written := make(map[string]string, context.temp_allocator)
	written["index.html"] = "<h1>Home</h1><nav aria-label=\"Parts\"><ul><li>A\n" + SITE_TREE_LINES_LIST_OPEN + "<li>B</li></ul></li></ul></nav>"
	with_lines := len(site_check_pages(pages[:], written, files, false))
	written["index.html"] = "<h1>Home</h1><nav aria-label=\"Parts\"><ul><li>A\n<ul><li>B</li></ul></li></ul></nav>"
	testing.expect_value(t, len(site_check_pages(pages[:], written, files, false)), with_lines + 1)
}

// The rules of the tree lines in the style sheet: one rule for each list
// of the class, lines of 1 pixel on the grid of 8 pixels, the last item
// with no line under its branch, the lines to the current item in the
// line color, and no rule that indents a level of one tree by itself.
@(test)
site_documentation_tree_lines_in_the_style_sheet :: proc(t: ^testing.T) {
	sheet := site_style_sheet("")
	expect := []string {
		"--tree-line: color-mix(in srgb, var(--dim) 40%, var(--track));",
		"ul.tree-lines { margin-left: 8px; }",
		"ul.tree-lines > li { position: relative; padding-left: 8px; }",
		"ul.tree-lines > li::before, ul.tree-lines > li::after { content: \"\"; position: absolute; left: 0; border: 0 solid var(--tree-line); pointer-events: none; }",
		"ul.tree-lines > li::before { top: 0; width: 8px; height: 13px; border-left-width: 1px; border-bottom-width: 1px; }",
		"ul.tree-lines > li::after { top: 13px; bottom: 0; border-left-width: 1px; }",
		"ul.tree-lines > li:last-child::after { display: none; }",
		"ul.tree-lines > li:has([aria-current])::before { border-color: var(--line); }",
		"ul.tree-lines > li:has(~ li [aria-current])::before, ul.tree-lines > li:has(~ li [aria-current])::after { border-left-color: var(--line); }",
		".tree a:focus-visible, .outline a:focus-visible { position: relative; z-index: 1; }",
	}
	for part in expect {
		testing.expectf(t, strings.contains(sheet, part), "the style sheet has no %q", part)
	}
	// The classes of before, each with its own indentation, are gone.
	for old in ([]string{"tree-glossary", "tree-groups", ".outline-level-3", ".tree-sections ul ul"}) {
		testing.expectf(t, !strings.contains(sheet, old), "the style sheet still has %q", old)
	}
}

// A documented symbol: its heading states it for "On this page", its
// source line is a link, and a symbol with no comment shows no text and is
// counted.
@(test)
site_documentation_symbol :: proc(t: ^testing.T) {
	site := test_site()
	b := strings.builder_make(context.temp_allocator)
	site_symbol_write(&site, &b, Site_Symbol{id = "operation-memory-map", name = "Memory_Map", signature = "Memory_Map(memory) -> address", description = "Maps <memory>.\n\nA second paragraph.", source = "contract/operation/operation.odin", line = 12})
	html := strings.to_string(b)
	testing.expect(t, strings.contains(html, "<h3 id=\"operation-memory-map\" data-outline=\"Memory_Map\"><code>Memory_Map</code></h3>"))
	testing.expect(t, strings.contains(html, "<pre class=\"signature\"><code>Memory_Map(memory) -&gt; address</code></pre>"))
	testing.expect(t, strings.contains(html, "<p>Maps &lt;memory&gt;.</p>\n<p>A second paragraph.</p>"))
	testing.expect(t, strings.contains(html, "/blob/master/contract/operation/operation.odin#L12\"><code class=\"value value-file\">contract/operation/operation.odin:12</code></a>"))
	testing.expect_value(t, site.symbol_count, 1)
	testing.expect_value(t, site.symbols_without_description, 0)

	empty := strings.builder_make(context.temp_allocator)
	site_symbol_write(&site, &empty, Site_Symbol{id = "export-entry", name = "entry"})
	testing.expect(t, !strings.contains(strings.to_string(empty), "<p>"))
	testing.expect_value(t, site.symbol_count, 2)
	testing.expect_value(t, site.symbols_without_description, 1)
	testing.expect_value(t, site_outline_entries(strings.to_string(empty))[0].text, "entry")

	testing.expect_value(t, len(site_names_in_text("Fails with No_Right; not No_Rights or A_No_Right.", []string{"No_Right", "No_Budget"})), 1)
}

// A file that changes between builds carries the version of its bytes: the
// same bytes give the same version; the check of a link ignores it.
@(test)
site_documentation_versions_of_files :: proc(t: ^testing.T) {
	one := site_bytes_version(transmute([]u8)string("body { margin: 0; }"))
	testing.expect_value(t, len(one), 2 * SITE_VERSION_BYTES)
	testing.expect_value(t, site_bytes_version(transmute([]u8)string("body { margin: 0; }")), one)
	testing.expect(t, site_bytes_version(transmute([]u8)string("body { margin: 1px; }")) != one)

	site := test_site()
	site.file_versions = make(map[string]string, context.temp_allocator)
	site.file_versions[SITE_STYLE_SHEET] = one
	testing.expect_value(t, site_file_link(&site, "docs/guides/A/index.html", SITE_STYLE_SHEET), strings.concatenate({"../../../style.css?v=", one}, context.temp_allocator))
	testing.expect_value(t, site_file_link(&site, "docs/guides/A/index.html", "favicon.ico"), "../../../favicon.ico")

	pages := [?]Site_Page{{path = "index.html", title = "Home", description = "The home.", body = ""}}
	files := make(map[string]int, context.temp_allocator)
	files[SITE_STYLE_SHEET] = 1
	written := make(map[string]string, context.temp_allocator)
	written["index.html"] = strings.concatenate({"<link rel=\"stylesheet\" href=\"style.css?v=", one, "\"><h1>Home</h1>"}, context.temp_allocator)
	testing.expect_value(t, len(site_check_pages(pages[:], written, files, false)), 0)
	written["index.html"] = "<link rel=\"stylesheet\" href=\"absent.css?v=1\"><h1>Home</h1>"
	testing.expect(t, len(site_check_pages(pages[:], written, files, false)) > 0)
}

// docs/FIRST_MILESTONE.md is a working record: not a page of the site. The
// status page links its items to their lines in the repository, and a
// guide links to the file in the repository: no link to a page that does
// not exist.
@(test)
site_documentation_working_record_links :: proc(t: ^testing.T) {
	records := SITE_WORKING_RECORDS
	found := false
	for record in records {
		found ||= record == "FIRST_MILESTONE.md"
	}
	testing.expect(t, found)

	site := test_site()
	items := []Site_List_Item{{section = "evidence", label = "3", id = "evidence-3", line = 42}}
	b := strings.builder_make(context.temp_allocator)
	site_item_links(&site, &b, "status/index.html", SITE_MILESTONE_FILE, items)
	testing.expect_value(t, strings.to_string(b), "<a href=\"" + SITE_REPOSITORY_ADDRESS + "/blob/master/docs/FIRST_MILESTONE.md#L42\">3</a>")
	guide := strings.builder_make(context.temp_allocator)
	site_item_links(&site, &guide, "status/index.html", "docs/NETWORK.md", items)
	testing.expect_value(t, strings.to_string(guide), "<a href=\"../docs/guides/NETWORK/index.html#evidence-3\">3</a>")

	renderer := site_renderer_make(&site, "docs/guides/TEST/index.html", "docs/TEST.md")
	site_render_markdown(&renderer, "See `docs/FIRST_MILESTONE.md` and [the record](FIRST_MILESTONE.md).\n")
	html := strings.to_string(renderer.builder)
	testing.expect_value(t, strings.count(html, "href=\"" + SITE_REPOSITORY_ADDRESS + "/blob/master/docs/FIRST_MILESTONE.md\""), 2)
	testing.expect(t, !strings.contains(html, "guides/FIRST_MILESTONE"))
}
