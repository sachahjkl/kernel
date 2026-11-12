package kerneltool

import "core:os"
import "core:strings"
import "core:testing"

test_site :: proc() -> Site {
	site: Site
	site.documents = make(map[string]string, context.temp_allocator)
	site.not_rendered = make([dynamic]string, context.temp_allocator)
	site.copies = make(map[string]string, context.temp_allocator)
	site.files = make(map[string]int, context.temp_allocator)
	site.pages = make([dynamic]Site_Page, context.temp_allocator)
	site.documents["docs/NETWORK.md"] = "guides/NETWORK.html"
	site.documents["NETWORK.md"] = "guides/NETWORK.html"
	terms := make([]Site_Term, 2, context.temp_allocator)
	terms[0] = {name = "Module metadata", id = "term-module-metadata"}
	terms[1] = {name = "Module", id = "term-module"}
	site.terms = terms
	return site
}

@(private = "file")
render :: proc(site: ^Site, markdown: string, glossary := false) -> (html: string, renderer: Site_Renderer) {
	renderer = site_renderer_make(site, "guides/TEST.html", "docs/TEST.md")
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
		"<strong>bold</strong> &amp; a <a href=\"../guides/NETWORK.html\">link</a>",
		"Its second line.",
		"<h2 id=\"a-part\">A part</h2>",
		"<li>one continued<ul>\n<li>nested",
		"<li id=\"a-part-1\"><span class=\"label\">1.</span> first",
		"<li id=\"a-part-34b\"><span class=\"label\">34b.</span> second",
		"<th scope=\"col\">B | C</th>",
		"<blockquote>\n<p>quoted &lt;text&gt;</p>",
		"<pre><code>x := 1 &lt; 2\n</code></pre>",
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
	testing.expect(t, strings.contains(html, "<a class=\"term\" href=\"../reference/glossary.html#term-module-metadata\">module metadata</a>"))
	testing.expect(t, strings.contains(html, "of a <a class=\"term\" href=\"../reference/glossary.html#term-module\">module</a>."))
	testing.expect_value(t, strings.count(html, "#term-module\""), 1)
	glossary, _ := render(&site, "| Term | Definition |\n|---|---|\n| Module | A module |\n", glossary = true)
	testing.expect(t, strings.contains(glossary, "<tr id=\"term-module\">"))
	testing.expect(t, !strings.contains(glossary, "class=\"term\""))
}

@(test)
site_render_the_documents_of_the_repository :: proc(t: ^testing.T) {
	site := test_site()
	paths, ok := files_with_suffix("docs", ".md")
	testing.expect(t, ok)
	for path in paths {
		data, err := os.read_entire_file(path, context.temp_allocator)
		testing.expect(t, err == nil)
		renderer := site_renderer_make(&site, "guides/X.html", path)
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
	testing.expect_value(t, site_relative("guides/NETWORK.html", "style.css"), "../style.css")
	testing.expect_value(t, site_relative("reference/modules/math.html", "index.html"), "../../index.html")
	testing.expect_value(t, site_relative("guides/A.html", "#part"), "#part")
	testing.expect_value(t, site_path_join("guides", "../pictures/a.png"), "pictures/a.png")
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
	page := Site_Page{path = "guides/A.html", title = "<x-title>", description = "<x-description> & \"quote\"", section = .Guides, crumbs = site_crumbs(.Guides), body = "<h1>A</h1>"}
	html := site_page_html(&site, page)
	testing.expect(t, !strings.contains(html, "<x-title>"))
	testing.expect(t, !strings.contains(html, "<x-description>"))
	testing.expect(t, strings.contains(html, "&lt;x-description&gt; &amp; &quot;quote&quot;"))
	testing.expect(t, strings.contains(html, "href=\"../style.css\""))
}

@(test)
site_checks_of_the_pages :: proc(t: ^testing.T) {
	good := [?]Site_Page {
		{path = "index.html", title = "Home", description = "The home.", body = ""},
		{path = "guides/A.html", title = "A", description = "The guide A.", body = ""},
	}
	files := make(map[string]int, context.temp_allocator)
	files["pictures/a.png"] = 1
	written := make(map[string]string, context.temp_allocator)
	written["index.html"] = "<h1 id=\"top\">Home</h1><a href=\"guides/A.html#part\">A</a><img src=\"pictures/a.png\" width=\"8\" height=\"8\" alt=\"\"><a href=\"https://example.org/\">x</a>"
	written["guides/A.html"] = "<h1>A</h1><h2 id=\"part\">P</h2><a href=\"../index.html#top\">home</a><a href=\"#part\">here</a>"
	testing.expect_value(t, len(site_check_pages(good[:], written, files)), 0)

	Damage :: struct {
		page, before, after: string,
	}
	damages := []Damage {
		{"index.html", "<h1 id=\"top\">Home</h1>", ""}, // No h1.
		{"guides/A.html", "<h2 id=\"part\">P</h2>", "<h1 id=\"part\">P</h1>"}, // Two h1.
		{"index.html", " width=\"8\"", ""}, // A picture with no width.
		{"index.html", " alt=\"\"", ""}, // A picture with no alt.
		{"index.html", "guides/A.html#part", "guides/B.html"}, // A page that does not exist.
		{"index.html", "guides/A.html#part", "guides/A.html#absent"}, // An anchor that does not exist.
		{"guides/A.html", "href=\"#part\"", "href=\"#absent\""},
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
		testing.expectf(t, len(site_check_pages(good[:], changed, files)) > 0, "no problem found after %q became %q", damage.before, damage.after)
	}
	same_title := good
	same_title[1].title = "Home"
	testing.expect(t, len(site_check_pages(same_title[:], written, files)) > 0)
	same_description := good
	same_description[1].description = "The home."
	testing.expect(t, len(site_check_pages(same_description[:], written, files)) > 0)
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
	for picture in site_mark_pictures {
		width, height := site_mark_size(picture)
		drawing_width, drawing_height := site_mark_drawing_size(picture)
		testing.expectf(t, drawing_width <= width && drawing_height <= height, "%s: the drawing does not fit", picture.file_name)
		if picture.file_name == SITE_MARK_BAR {
			testing.expect_value(t, width, 24)
			testing.expect_value(t, height, 24)
		}
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
