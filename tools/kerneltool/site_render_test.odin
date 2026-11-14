package kerneltool

import "core:os"
import "core:strings"
import "core:testing"
import "support:mark"

test_site :: proc() -> Site {
	site: Site
	site.documents = make(map[string]string, context.temp_allocator)
	site.not_rendered = make([dynamic]string, context.temp_allocator)
	site.copies = make(map[string]string, context.temp_allocator)
	site.files = make(map[string]int, context.temp_allocator)
	site.pages = make([dynamic]Site_Page, context.temp_allocator)
	site.documents["docs/NETWORK.md"] = "docs/guides/NETWORK/index.html"
	site.documents["NETWORK.md"] = "docs/guides/NETWORK/index.html"
	terms := make([]Site_Term, 2, context.temp_allocator)
	// The terms of the group Code of the glossary: a link names its page.
	terms[0] = {name = "Module metadata", id = "term-module-metadata", page = site_glossary_group_page("code")}
	terms[1] = {name = "Module", id = "term-module", page = site_glossary_group_page("code")}
	site.terms = terms
	return site
}

@(private = "file")
render :: proc(site: ^Site, markdown: string, glossary := false) -> (html: string, renderer: Site_Renderer) {
	renderer = site_renderer_make(site, "docs/guides/TEST/index.html", "docs/TEST.md")
	renderer.glossary = glossary
	site_render_markdown(&renderer, markdown)
	return strings.to_string(renderer.builder), renderer
}

@(test)
site_render_each_construct :: proc(t: ^testing.T) {
	site := test_site()
	markdown := "# The <title>\n\nA paragraph with `code`, **bold** & a [link](NETWORK.md#part).\nIts second line.\n\n## A part\n\n- one\n  continued\n  - nested\n- two\n\n1. first\n34b. second\n\n| A | B \\| C |\n|---|---|\n| `x` | y |\n\n> quoted <text>\n\n```odin\nx := 1 < 2\n```\n\n```mermaid\ngraph\n```\n"
	html, renderer := render(&site, markdown)
	expect := [?]string {
		"<h1 id=\"the-title\">The &lt;title&gt;</h1>",
		"<code>code</code>",
		"<strong>bold</strong> &amp; a <a href=\"../../../docs/guides/NETWORK/index.html\">link</a>",
		"Its second line.",
		"<h2 id=\"a-part\">A part</h2>",
		"<li>one continued<ul>\n<li>nested",
		"<li id=\"a-part-1\"><span class=\"label\">1.</span> first",
		"<li id=\"a-part-34b\"><span class=\"label\">34b.</span> second",
		"<th scope=\"col\" class=\"column-any\">B | C</th>",
		"<div class=\"table\" role=\"region\" tabindex=\"0\" aria-label=\"A part\">",
		"<blockquote>\n<p>quoted &lt;text&gt;</p>",
		// A block marked odin is colored by the tokenizer of the compiler.
		"<pre><code>x <span class=\"c-p\">:=</span> <span class=\"c-l\">1</span> <span class=\"c-p\">&lt;</span> <span class=\"c-l\">2</span>\n</code></pre>",
		// The mermaid block is plain: only a block marked odin is colored.
		"<pre><code>graph\n</code></pre>",
	}
	for part in expect {
		testing.expectf(t, strings.contains(html, part), "the HTML has no %q:\n%s", part, html)
	}
	testing.expect_value(t, len(renderer.items), 2)
	testing.expect_value(t, len(site.not_rendered), 1) // The mermaid diagram.
	testing.expect(t, !strings.contains(html, "<title>"))
}

@(test)
site_render_links_the_first_use_of_a_term :: proc(t: ^testing.T) {
	site := test_site()
	html, _ := render(&site, "The module metadata of a module. Modules, and `Module` in code.\n")
	testing.expect(t, strings.contains(html, "<a class=\"term\" href=\"../../../docs/reference/glossary/code/index.html#term-module-metadata\">module metadata</a>"))
	testing.expect(t, strings.contains(html, "of a <a class=\"term\" href=\"../../../docs/reference/glossary/code/index.html#term-module\">module</a>."))
	testing.expect_value(t, strings.count(html, "#term-module\""), 1)
}

@(test)
site_render_the_documents_of_the_repository :: proc(t: ^testing.T) {
	site := test_site()
	paths, ok := files_with_suffix("docs", ".md")
	testing.expect(t, ok)
	for path in paths {
		data, err := os.read_entire_file(path, context.temp_allocator)
		testing.expect(t, err == nil)
		renderer := site_renderer_make(&site, "docs/guides/X/index.html", path)
		site_render_markdown(&renderer, string(data))
		html := strings.to_string(renderer.builder)
		testing.expectf(t, strings.count(html, "<h1") == 1, "%s gives %d headings h1", path, strings.count(html, "<h1"))
		// No table, list or fence is left as text: a line that starts with
		// "|" or "```" outside <pre> means a construct was not read.
		testing.expectf(t, !strings.contains(html, "<p>| ") && !strings.contains(html, "<p>```"), "%s has a construct left as text", path)
	}
	// What the renderer may leave as text: the mermaid diagrams and the
	// links to a file that is not in the repository.
	for item in site.not_rendered {
		allowed := strings.contains(item, "mermaid") || strings.contains(item, "which is not a file of the repository")
		testing.expectf(t, allowed, "not rendered: %s", item)
	}
}

@(test)
site_relative_paths :: proc(t: ^testing.T) {
	testing.expect_value(t, site_relative("index.html", "style.css"), "style.css")
	testing.expect_value(t, site_relative("docs/guides/NETWORK/index.html", "style.css"), "../../../style.css")
	testing.expect_value(t, site_relative("docs/reference/modules/math/index.html", "index.html"), "../../../../index.html")
	testing.expect_value(t, site_relative("docs/guides/A/index.html", "#part"), "#part")
	testing.expect_value(t, site_path_join("docs/guides", "../../pictures/a.png"), "pictures/a.png")
	testing.expect_value(t, site_path_join("docs", "./NETWORK.md"), "docs/NETWORK.md")
	testing.expect_value(t, site_slug("The kernel: 32 operations!"), "the-kernel-32-operations")
	testing.expect_value(t, site_description_cut("`a` **b**"), "a b")
	long := strings.repeat("word ", 60, context.temp_allocator)
	testing.expect(t, len(site_description_cut(long)) <= SITE_DESCRIPTION_LIMIT)
}

@(test)
site_page_frame_escapes_its_texts :: proc(t: ^testing.T) {
	site := test_site()
	site.release = "0.1.0"
	page := Site_Page{path = "docs/guides/A/index.html", title = "<x-title>", description = "<x-description> & \"quote\"", section = .Guides, crumbs = site_crumbs(.Guides), body = "<h1>A</h1>"}
	html := site_page_html(&site, page)
	testing.expect(t, !strings.contains(html, "<x-title>"))
	testing.expect(t, !strings.contains(html, "<x-description>"))
	testing.expect(t, strings.contains(html, "&lt;x-description&gt; &amp; &quot;quote&quot;"))
	testing.expect(t, strings.contains(html, "href=\"../../../style.css\""))
}

@(test)
site_checks_of_the_pages :: proc(t: ^testing.T) {
	good := [?]Site_Page {
		{path = "index.html", title = "Home", description = "The home.", body = ""},
		{path = "docs/guides/A/index.html", title = "A", description = "The guide A.", body = ""},
	}
	files := make(map[string]int, context.temp_allocator)
	files["pictures/a.png"] = 1
	// With no site address, a link to a page names its index.html.
	written := make(map[string]string, context.temp_allocator)
	written["index.html"] = "<h1 id=\"top\">Home</h1><a href=\"docs/guides/A/index.html#part\">A</a><img src=\"pictures/a.png\" width=\"8\" height=\"8\" alt=\"\"><a href=\"https://example.org/\">x</a>"
	written["docs/guides/A/index.html"] = "<h1>A</h1><h2 id=\"part\">P</h2><a href=\"../../../index.html#top\">home</a><a href=\"#part\">here</a>"
	testing.expect_value(t, len(site_check_pages(good[:], written, files, false)), 0)
	// With a site address, it names the folder of the page.
	published := make(map[string]string, context.temp_allocator)
	published["index.html"] = "<h1 id=\"top\">Home</h1><a href=\"docs/guides/A/#part\">A</a><a href=\"./\">home</a><img src=\"pictures/a.png\" width=\"8\" height=\"8\" alt=\"\">"
	published["docs/guides/A/index.html"] = "<h1>A</h1><h2 id=\"part\">P</h2><a href=\"../../../#top\">home</a><a href=\"#part\">here</a>"
	testing.expect_value(t, len(site_check_pages(good[:], published, files, true)), 0)
	// The form of the other build fails.
	testing.expect(t, len(site_check_pages(good[:], written, files, true)) > 0)
	testing.expect(t, len(site_check_pages(good[:], published, files, false)) > 0)

	Damage :: struct {
		page, before, after: string,
	}
	damages := []Damage {
		{"index.html", "<h1 id=\"top\">Home</h1>", ""}, // No h1.
		{"docs/guides/A/index.html", "<h2 id=\"part\">P</h2>", "<h1 id=\"part\">P</h1>"}, // Two h1.
		{"index.html", " width=\"8\"", ""}, // A picture with no width.
		{"index.html", " alt=\"\"", ""}, // A picture with no alt.
		{"index.html", "docs/guides/A/index.html#part", "docs/guides/B/index.html"}, // A page that does not exist.
		{"index.html", "docs/guides/A/index.html#part", "docs/guides/A/index.html#absent"}, // An anchor that does not exist.
		{"index.html", "docs/guides/A/index.html#part", "guides/A.html"}, // The old path of the .html files.
		{"index.html", "docs/guides/A/index.html#part", "guides/A/index.html"}, // The old path of the folders before the docs.
		{"index.html", "docs/guides/A/index.html#part", "docs/guides/index.html"}, // A folder with no page.
		{"docs/guides/A/index.html", "href=\"#part\"", "href=\"#absent\""},
		{"index.html", "pictures/a.png", "pictures/b.png"},
	}
	for damage in damages {
		changed := make(map[string]string, context.temp_allocator)
		for path, html in written {
			changed[path] = html
		}
		replaced, did := strings.replace_all(written[damage.page], damage.before, damage.after, context.temp_allocator)
		testing.expectf(t, did, "the text %q is not in %s", damage.before, damage.page)
		changed[damage.page] = replaced
		testing.expectf(t, len(site_check_pages(good[:], changed, files, false)) > 0, "no problem found after %q became %q", damage.before, damage.after)
	}
	same_title := good
	same_title[1].title = "Home"
	testing.expect(t, len(site_check_pages(same_title[:], written, files, false)) > 0)
	same_description := good
	same_description[1].description = "The home."
	testing.expect(t, len(site_check_pages(same_description[:], written, files, false)) > 0)
}

// The file of a page, the link to a page in its two forms, the sections
// and their breadcrumbs, and the old paths of a page.
@(test)
site_page_files_and_links :: proc(t: ^testing.T) {
	testing.expect_value(t, site_page_file(""), "index.html")
	testing.expect_value(t, site_page_file("docs/reference/licenses"), "docs/reference/licenses/index.html")
	testing.expect_value(t, site_section_page(.Home), "index.html")
	testing.expect_value(t, site_section_page(.News), "news/index.html")
	testing.expect_value(t, site_section_page(.Status), "status/index.html")
	testing.expect_value(t, site_section_page(.Docs), "docs/index.html")
	testing.expect_value(t, site_section_page(.Guides), "docs/guides/index.html")
	testing.expect_value(t, site_section_page(.Reference), "docs/reference/index.html")
	testing.expect_value(t, site_page_file(SITE_LICENSES_FOLDER), "docs/reference/licenses/index.html")
	testing.expect_value(t, site_page_file(SITE_MODULES_FOLDER), "docs/reference/modules/index.html")

	// The bar names the sections under the home; a guide is in the docs.
	testing.expect(t, site_section_in_bar(.Docs) && site_section_in_bar(.Status) && site_section_in_bar(.News) && site_section_in_bar(.Releases))
	testing.expect(t, !site_section_in_bar(.Home) && !site_section_in_bar(.Guides) && !site_section_in_bar(.Reference))
	testing.expect_value(t, site_bar_section(.Guides), Site_Section.Docs)
	testing.expect_value(t, site_bar_section(.Reference), Site_Section.Docs)
	testing.expect_value(t, site_bar_section(.Status), Site_Section.Status)
	crumbs := site_crumbs(.Reference)
	testing.expect_value(t, len(crumbs), 3)
	if len(crumbs) == 3 {
		testing.expect_value(t, crumbs[0].title, "Home")
		testing.expect_value(t, crumbs[1].title, "Docs")
		testing.expect_value(t, crumbs[1].path, "docs/index.html")
		testing.expect_value(t, crumbs[2].title, "Reference")
		testing.expect_value(t, crumbs[2].path, "docs/reference/index.html")
	}
	testing.expect_value(t, len(site_crumbs(.Home)), 1)
	testing.expect_value(t, len(site_crumbs(.Docs)), 2)
	testing.expect_value(t, len(site_crumbs(.Status)), 2)

	on_disk := test_site()
	testing.expect_value(t, site_page_link(&on_disk, "docs/guides/A/index.html", "docs/reference/licenses/index.html"), "../../../docs/reference/licenses/index.html")
	testing.expect_value(t, site_page_link(&on_disk, "docs/guides/A/index.html", "index.html"), "../../../index.html")
	testing.expect_value(t, site_page_link(&on_disk, "index.html", "docs/reference/glossary/index.html#term-module"), "docs/reference/glossary/index.html#term-module")
	testing.expect_value(t, site_page_link(&on_disk, "docs/guides/A/index.html", "#part"), "#part")

	published := test_site()
	published.address = "https://example.org/modus"
	testing.expect_value(t, site_page_link(&published, "docs/guides/A/index.html", "docs/reference/licenses/index.html"), "../../../docs/reference/licenses/")
	testing.expect_value(t, site_page_link(&published, "docs/guides/A/index.html", "index.html"), "../../../")
	testing.expect_value(t, site_page_link(&published, "index.html", "index.html"), "./")
	testing.expect_value(t, site_page_link(&published, "index.html", "index.html#news"), "./#news")
	testing.expect_value(t, site_page_link(&published, "docs/guides/A/index.html", "docs/reference/glossary/index.html#term-module"), "../../../docs/reference/glossary/#term-module")

	// The old paths of a page, by rule: the folder before the docs, then
	// the .html file of that folder for a page that is not an index page.
	Old_Paths_Case :: struct {
		page:           Site_Page,
		html_file:      string, // "" for none.
		folder_before:  string, // "" for none.
	}
	cases := []Old_Paths_Case {
		{Site_Page{path = "docs/reference/licenses/index.html"}, "reference/licenses.html", "reference/licenses/index.html"},
		{Site_Page{path = "docs/reference/modules/math/index.html"}, "reference/modules/math.html", "reference/modules/math/index.html"},
		{Site_Page{path = "docs/guides/NETWORK/index.html"}, "guides/NETWORK.html", "guides/NETWORK/index.html"},
		{Site_Page{path = "docs/guides/index.html", is_index = true}, "", "guides/index.html"},
		{Site_Page{path = "docs/reference/modules/index.html", is_index = true}, "", "reference/modules/index.html"},
		{Site_Page{path = "news/index.html"}, "news.html", ""},
		{Site_Page{path = "status/index.html"}, "status.html", ""},
		{Site_Page{path = "docs/index.html", is_index = true}, "", ""},
		{Site_Page{path = "index.html", is_index = true}, "", ""},
	}
	for item in cases {
		html_file, folder_before := "", ""
		for old in site_old_page_paths(item.page) {
			switch old.generation {
			case .Html_Files:
				testing.expectf(t, html_file == "", "%s: two old paths of the .html files", item.page.path)
				html_file = old.path
			case .Folders_Before_Docs:
				testing.expectf(t, folder_before == "", "%s: two old paths of the folders", item.page.path)
				folder_before = old.path
			}
		}
		testing.expectf(t, html_file == item.html_file, "%s: the old path of the .html files is %q, expected %q", item.page.path, html_file, item.html_file)
		testing.expectf(t, folder_before == item.folder_before, "%s: the old path of the folders is %q, expected %q", item.page.path, folder_before, item.folder_before)
	}
}

@(test)
site_stages_of_the_start :: proc(t: ^testing.T) {
	log := "[root] root: ok\nkernel: boot: firmware: 2709675 us\nkernel: boot: boot program: load the kernel, the boot image: 23587 us\nkernel: boot: kernel: root service: 2309 us\nkernel: boot: bad: x us\n"
	stages := site_boot_stages(log)
	testing.expect_value(t, len(stages), 3)
	if len(stages) == 3 {
		testing.expect_value(t, stages[0].who, "firmware")
		testing.expect_value(t, stages[0].microseconds, 2709675)
		testing.expect_value(t, stages[1].who, "boot program")
		testing.expect_value(t, stages[1].what, "load the kernel, the boot image")
	}
}

@(test)
site_size_of_the_pictures_of_the_mark :: proc(t: ^testing.T) {
	for picture in mark_uses_pictures(.Site, .Picture) {
		width, height := mark_picture_size(picture)
		drawing_width, drawing_height := mark_picture_drawing_size(picture)
		testing.expectf(t, drawing_width <= width && drawing_height <= height, "%s: the drawing does not fit", picture.file_name)
		// The bar is a small icon: the cells variant, one pixel for a cell.
		// The head of the home is a picture: the smooth variant.
		if picture.file_name == SITE_MARK_BAR || picture.file_name == SITE_MARK_BAR_LIGHT {
			testing.expect_value(t, width, 24)
			testing.expect_value(t, height, 24)
			testing.expect_value(t, picture.variant, mark.Variant.Cells)
		}
		if picture.file_name == SITE_MARK_HOME || picture.file_name == SITE_MARK_HOME_LIGHT {
			testing.expect_value(t, width, 192)
			testing.expect_value(t, height, 192)
			testing.expect_value(t, picture.variant, mark.Variant.Smooth)
		}
		// A picture of a page is the heron alone: the name is text in the
		// font of the name of the mark. Only the picture for other sites
		// holds the name.
		testing.expectf(t, (picture.name_cell > 0) == (picture.file_name == SITE_MARK_CARD), "%s: the name is in the picture", picture.file_name)
		if picture.file_name == SITE_MARK_CARD {
			testing.expect_value(t, width, 1200)
			testing.expect_value(t, height, 630)
		}
	}
}

@(test)
site_licenses_readers :: proc(t: ^testing.T) {
	font := "Copyright 2025 The Paper Mono Project Authors (https://github.com/paper-design/paper-mono)\n\nThe subset carries the name \"Paper Mono ASCII\".\nLicense of the source: SIL OFL 1.1, no Reserved Font Name.\n"
	parsed, problem := site_font_license_parse("a.license", font)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, parsed.address, "https://github.com/paper-design/paper-mono")
	testing.expect_value(t, parsed.copyright, "Copyright 2025 The Paper Mono Project Authors")
	testing.expect_value(t, parsed.family, "Paper Mono ASCII")
	testing.expect_value(t, site_spdx(parsed.license), "OFL-1.1")
	no_name, _ := strings.replace_all(font, "carries the name", "has the name", context.temp_allocator)
	_, no_name_problem := site_font_license_parse("a.license", no_name)
	testing.expect(t, no_name_problem != "")
	no_license, _ := strings.replace_all(font, "License of the source: ", "Source: ", context.temp_allocator)
	_, no_license_problem := site_font_license_parse("a.license", no_license)
	testing.expect(t, no_license_problem != "")

	for name in ([]string{"paper_mono", "b612", "dejavu_sans_mono", "ibm_mono"}) {
		data, err := os.read_entire_file(strings.concatenate({SITE_FONT_FOLDER, "/", name, ".license"}, context.temp_allocator), context.temp_allocator)
		testing.expect(t, err == nil)
		_, real_problem := site_font_license_parse(name, string(data))
		testing.expect_value(t, real_problem, "")
	}

	flake_data, flake_error := os.read_entire_file(SITE_FLAKE_FILE, context.temp_allocator)
	testing.expect(t, flake_error == nil)
	flake, flake_problem := site_flake_parse(string(flake_data))
	testing.expect_value(t, flake_problem, "")
	testing.expect(t, flake.odin_release != "" && flake.odin_hash != "")
	testing.expect_value(t, flake.unfree_allowed, "posy-cursors")
	testing.expect_value(t, flake.firmware_package, "OVMF")
	testing.expect(t, "paper_mono" in flake.font_sources && "dejavu_sans_mono" in flake.font_sources)
	testing.expect(t, flake.font_sources["paper_mono"].hash != "" && flake.fetchers["paperMonoFile"].commit != "")
	testing.expect_value(t, flake.font_sources["dejavu_sans_mono"].nix_package, "dejavu_fonts")
	for damage in ([]string{"odinRelease = ", "buildTools = [", "OVMF_CODE = "}) {
		damaged, _ := strings.replace_all(string(flake_data), damage, "renamed = ", context.temp_allocator)
		_, damaged_problem := site_flake_parse(damaged)
		testing.expectf(t, damaged_problem != "", "no problem found without %q", damage)
	}

	lock_data, lock_error := os.read_entire_file(SITE_FLAKE_LOCK_FILE, context.temp_allocator)
	testing.expect(t, lock_error == nil)
	revision, lock_problem := site_flake_lock_revision(string(lock_data))
	testing.expect_value(t, lock_problem, "")
	testing.expect_value(t, len(revision), 40)
	_, empty_lock_problem := site_flake_lock_revision("{}")
	testing.expect(t, empty_lock_problem != "")

	manifest, manifest_problem := site_pointer_manifest_parse("m", "# x\ntheme System\nlicense MIT\nattribution A.\n")
	testing.expect_value(t, manifest_problem, "")
	testing.expect_value(t, manifest.license, "MIT")
	_, no_theme_problem := site_pointer_manifest_parse("m", "license MIT\n")
	testing.expect(t, no_theme_problem != "")
}

// The tables: the kind of each column of the measured numbers, the box (a
// region that the keyboard reaches, with a name), and the class of its
// column on each cell; a date in a time element; the kinds of the cells of
// a table of a document.
@(test)
site_tables_with_kinds :: proc(t: ^testing.T) {
	kinds := [?]Site_Column_Kind{.Prose, .Line, .Prose, .Date}
	testing.expect_value(t, len(site_numbers_columns), len(kinds))
	for column, index in site_numbers_columns {
		testing.expect_value(t, column.kind, kinds[index])
	}

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<p>before</p>\n")
	table := site_table_start(&b, "Measured <numbers>", site_numbers_columns[:])
	strings.write_string(&b, "<tr id=\"one\"><td>What</td><td class=\"code\"><code>line</code></td><td>log</td><td>")
	site_time(&b, "2026-11-12 02:09 UTC")
	strings.write_string(&b, "</td></tr>\n<tr><td>Second</td><td></td><td></td><td></td></tr>\n")
	site_table_end(&b, table)
	html := strings.to_string(b)
	expect := [?]string {
		"<p>before</p>\n<div class=\"table\" role=\"region\" tabindex=\"0\" aria-label=\"Measured &lt;numbers&gt;\"><table>",
		"<th scope=\"col\" class=\"column-prose\">What</th><th scope=\"col\" class=\"column-line\">The line of the log</th>",
		"<th scope=\"col\" class=\"column-date value-head value-icon value-time\">Written</th>",
		"<tr id=\"one\"><td class=\"column-prose\">What</td><td data-label=\"The line of the log\" class=\"column-line code\"><code>line</code></td><td data-label=\"Log, line, machine\" class=\"column-prose\">log</td><td data-label=\"Written\" class=\"column-date value value-time\"><time datetime=\"2026-11-12T02:09Z\">2026-11-12 02:09 UTC</time></td></tr>",
		"<tr><td class=\"column-prose\">Second</td><td data-label=\"The line of the log\" class=\"column-line\"></td><td data-label=\"Log, line, machine\" class=\"column-prose\"></td><td data-label=\"Written\" class=\"column-date value value-time\"></td></tr>",
		"</tbody></table></div>\n",
	}
	for part in expect {
		testing.expectf(t, strings.contains(html, part), "the table has no %q:\n%s", part, html)
	}
	testing.expect_value(t, strings.count(html, "role=\"region\""), 1)
	testing.expect_value(t, strings.count(html, "class=\"column-"), 4 + 8)

	testing.expect_value(t, site_cell_kind("42"), Site_Column_Kind.Number)
	testing.expect_value(t, site_cell_kind("1 024"), Site_Column_Kind.Number)
	testing.expect_value(t, site_cell_kind("2026-11-12"), Site_Column_Kind.Date)
	testing.expect_value(t, site_cell_kind("2026-11-12 02:09 UTC"), Site_Column_Kind.Date)
	testing.expect_value(t, site_cell_kind("2026-11-12 UTC"), Site_Column_Kind.Date)
	testing.expect_value(t, site_cell_kind("12 pages"), Site_Column_Kind.Any)
	testing.expect_value(t, site_cell_kind("v1"), Site_Column_Kind.Any)
	testing.expect_value(t, site_cell_kind(""), Site_Column_Kind.Any)
	plain := strings.builder_make(context.temp_allocator)
	site_time(&plain, "not <a> date")
	testing.expect_value(t, strings.to_string(plain), "not &lt;a&gt; date")
	day := strings.builder_make(context.temp_allocator)
	site_time(&day, "2026-11-12")
	testing.expect_value(t, strings.to_string(day), "<time datetime=\"2026-11-12\">2026-11-12</time>")

	// A table of a document: the general kind, and a cell of a number.
	site := test_site()
	rendered, _ := render(&site, "## Sizes\n\n| What | Bytes |\n|---|---|\n| The kernel | 1024 |\n")
	testing.expect(t, strings.contains(rendered, "aria-label=\"Sizes\""))
	testing.expect(t, strings.contains(rendered, "<td class=\"column-any\">The kernel</td><td data-label=\"Bytes\" class=\"column-number\">1024</td>"))
}
