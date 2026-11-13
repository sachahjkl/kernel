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
	testing.expect(t, strings.contains(html, "<li class=\"outline-level-2\"><a href=\"#a\">A x &amp; y</a></li>"))
	testing.expect(t, strings.contains(html, "<li class=\"outline-symbol\"><a href=\"#r\"><code>Row_Name</code></a></li>"))
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
