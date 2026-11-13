package kerneltool

import "core:encoding/json"
import "core:image/png"
import "core:strings"
import "core:testing"
import "support:mark"

@(private = "file")
TEST_ADDRESS :: "https://example.invalid/modus"
// The two guides of the small site, in the folder of the guides.
@(private = "file")
TEST_GUIDE_A :: SITE_GUIDE_FOLDER + "/A/" + SITE_PAGE
@(private = "file")
TEST_GUIDE_B :: SITE_GUIDE_FOLDER + "/B/" + SITE_PAGE

// A small site: a home with a picture, the index of the guides, two
// guides, the index of the glossary and the page of one group, the news, the index of the reference, the releases,
// the licenses and the home of the docs, with or without an address. Guide
// A uses a term of the glossary, so it links to an anchor of the page of
// its group.
@(private = "file")
metadata_test_site :: proc(address: string) -> Site {
	site := test_site()
	site.address = address
	site.release = "0.1.0"
	site.picture_sizes = make(map[string][2]int, context.temp_allocator)
	site.picture_sizes[SITE_PICTURE_FOLDER + "/" + SITE_MARK_CARD] = {SITE_CARD_WIDTH, SITE_CARD_HEIGHT}
	site.picture_sizes["pictures/a.png"] = {8, 8}
	site.readme.lead = "A small operating system."
	site.readme.mark_description = "The heron and the name"
	site.author = "Ada Example"
	releases := make([]Changelog_Release, 1, context.temp_allocator)
	entries := make([]Changelog_Entry, 1, context.temp_allocator)
	// Made with an allocator: a slice literal would live on the stack of
	// this procedure, and the site outlives it.
	lines := make([]string, 1, context.temp_allocator)
	lines[0] = "**A thing**: it works."
	entries[0] = Changelog_Entry{type_index = 0, lines = lines}
	releases[0] = Changelog_Release{number = Release_Number{0, 1, 0}, date = "2026-11-12", entries = entries}
	site.changelog.releases = releases
	news := make([]Site_News, 1, context.temp_allocator)
	news[0] = Site_News{entry = News_Entry{file_name = "2026-11-12-a.md", title = "A thing", date = "2026-11-12", kind = .Shown, text = "A thing works. More text."}, anchor = "news-2026-11-12-a"}
	site.news = news
	site.guides = make([dynamic]Site_Guide, context.temp_allocator)
	append(&site.guides, Site_Guide{source = "docs/A.md", path = TEST_GUIDE_A, title = "Guide A"})
	append(&site.guides, Site_Guide{source = "docs/B.md", path = TEST_GUIDE_B, title = "Guide B"})
	renderer := site_renderer_make(&site, TEST_GUIDE_A, "docs/A.md")
	site_render_markdown(&renderer, "A module of the system.\n")
	guide_body := strings.concatenate({"<h1>Guide A</h1>", strings.to_string(renderer.builder)}, context.temp_allocator)
	site_page_add(&site, Site_Page{path = SITE_PAGE, is_index = true, title = SITE_SYSTEM_NAME, description = "The home.", section = .Home, body = "<h1>modus</h1><img src=\"pictures/a.png\" width=\"8\" height=\"8\" alt=\"A &amp; B\">"})
	site_page_add(&site, Site_Page{path = site_section_page(.Guides), is_index = true, title = "Guides", description = "The guides.", section = .Guides, crumbs = site_crumbs(.Docs), body = "<h1>Guides</h1>"})
	site_page_add(&site, Site_Page{path = TEST_GUIDE_A, title = "Guide A", description = "The guide A.", section = .Guides, crumbs = site_crumbs(.Guides), body = guide_body})
	site_page_add(&site, Site_Page{path = TEST_GUIDE_B, title = "Guide B", description = "The guide B.", section = .Guides, crumbs = site_crumbs(.Guides), body = "<h1>Guide B</h1>"})
	site_page_add(&site, Site_Page{path = site_page_file(SITE_GLOSSARY_FOLDER), title = "Glossary", description = "The terms.", section = .Reference, crumbs = site_crumbs(.Reference), body = "<h1>Glossary</h1><dl><div id=\"term-module\"><dt>Module</dt></div><div id=\"term-module-metadata\"><dt>Module metadata</dt></div></dl>"})
	// The page of the group of the two terms: a link to a term names it.
	site_page_add(&site, Site_Page{path = site_glossary_group_page("code"), title = "Glossary: Code", description = "The terms of the group Code.", section = .Reference, crumbs = site_crumbs(.Reference), body = "<h1 id=\"code\">Code</h1><div class=\"term-entry\"><h2 id=\"term-module\">Module</h2></div><div class=\"term-entry\"><h2 id=\"term-module-metadata\">Module metadata</h2></div>"})
	site_page_add(&site, Site_Page{path = site_section_page(.News), title = "News", description = "The news.", section = .News, crumbs = site_crumbs(.Home), body = "<h1>News</h1><article id=\"news-2026-11-12-a\"></article>"})
	site_page_add(&site, Site_Page{path = site_section_page(.Reference), is_index = true, title = "Reference", description = "The reference.", section = .Reference, crumbs = site_crumbs(.Docs), body = "<h1>Reference</h1>"})
	site_page_add(&site, Site_Page{path = site_section_page(.Releases), title = "Releases", description = "The releases.", section = .Releases, crumbs = site_crumbs(.Home), body = strings.concatenate({"<h1>Releases</h1><h2 id=\"", site_release_id(site.release), "\">0.1.0</h2>"}, context.temp_allocator)})
	site_page_add(&site, Site_Page{path = site_page_file(SITE_LICENSES_FOLDER), title = "Licenses", description = "The licenses.", section = .Reference, crumbs = site_crumbs(.Reference), body = "<h1>Licenses</h1>"})
	// The home of the docs: its own search field, none in its bar.
	docs_body := strings.concatenate({"<h1>Docs</h1>", site_search_field_html(.Docs_Home)}, context.temp_allocator)
	site_page_add(&site, Site_Page{path = site_section_page(.Docs), is_index = true, title = "Docs", description = "The docs.", section = .Docs, crumbs = site_crumbs(.Home), body = docs_body, search_in_page = true})
	return site
}

@(private = "file")
metadata_test_written :: proc(site: ^Site) -> map[string]string {
	written := make(map[string]string, context.temp_allocator)
	for page in site.pages {
		written[page.path] = site_page_html(site, page)
	}
	return written
}

@(private = "file")
metadata_test_copy :: proc(written: map[string]string) -> map[string]string {
	changed := make(map[string]string, context.temp_allocator)
	for path, html in written {
		changed[path] = html
	}
	return changed
}

@(test)
site_addresses_of_pages :: proc(t: ^testing.T) {
	testing.expect_value(t, site_page_address(TEST_ADDRESS, "index.html"), TEST_ADDRESS + "/")
	testing.expect_value(t, site_page_address(TEST_ADDRESS, "docs/guides/index.html"), TEST_ADDRESS + "/docs/guides/")
	testing.expect_value(t, site_page_address(TEST_ADDRESS, "docs/guides/A/index.html"), TEST_ADDRESS + "/docs/guides/A/")
	testing.expect_value(t, site_file_address(TEST_ADDRESS, "pictures/a.png"), TEST_ADDRESS + "/pictures/a.png")
	testing.expect_value(t, site_headline("short"), "short")
	testing.expect(t, len(site_headline(strings.repeat("word ", 40, context.temp_allocator))) <= SITE_HEADLINE_LIMIT)
	testing.expect_value(t, site_html_unescape("A &amp; B &lt;c&gt; &quot;d&quot;"), "A & B <c> \"d\"")
}

@(test)
site_metadata_without_an_address :: proc(t: ^testing.T) {
	site := metadata_test_site("")
	written := metadata_test_written(&site)
	for path, html in written {
		testing.expectf(t, !strings.contains(html, "rel=\"canonical\""), "%s has a canonical address with no address", path)
		testing.expectf(t, !strings.contains(html, "property=\"og:"), "%s has Open Graph with no address", path)
		testing.expectf(t, !strings.contains(html, SITE_STRUCTURED_DATA_OPEN), "%s has JSON-LD with no address", path)
		testing.expectf(t, strings.contains(html, "rel=\"manifest\""), "%s names no manifest", path)
		testing.expectf(t, strings.contains(html, "<html lang=\"en\">"), "%s has no language", path)
		testing.expectf(t, strings.count(html, "name=\"theme-color\"") == 2, "%s has no theme color for each scheme", path)
		testing.expectf(t, site_inline_code_problem(html) == "", "%s has inline code", path)
	}
	// The guides name the guide before and after them.
	testing.expect(t, strings.contains(written[TEST_GUIDE_A], "<link rel=\"next\" href=\"../../../docs/guides/B/index.html\">"))
	testing.expect(t, strings.contains(written[TEST_GUIDE_B], "<link rel=\"prev\" href=\"../../../docs/guides/A/index.html\">"))
	testing.expect(t, !strings.contains(written[TEST_GUIDE_A], "rel=\"prev\""))
	testing.expect_value(t, len(site_check_metadata("", site.pages[:], written, "", site.picture_sizes)), 0)

	// A canonical address or a sitemap with no address is a fault.
	changed := metadata_test_copy(written)
	changed[TEST_GUIDE_A] = strings.concatenate({"<link rel=\"canonical\" href=\"x\">", written[TEST_GUIDE_A]}, context.temp_allocator)
	testing.expect(t, len(site_check_metadata("", site.pages[:], changed, "", site.picture_sizes)) > 0)
	testing.expect(t, len(site_check_metadata("", site.pages[:], written, "<urlset></urlset>", site.picture_sizes)) > 0)

	// The feeds have relative links and no link "self".
	feed := site_releases_feed(&site)
	testing.expect(t, !strings.contains(feed, "rel=\"self\""))
	testing.expect_value(t, strings.count(feed, "<entry>"), 1)
	testing.expect(t, strings.contains(feed, "href=\"releases/index.html#"))
	testing.expect(t, strings.contains(site_language_model_index(&site), "](docs/guides/A/index.html): The guide A."))
}

@(test)
site_metadata_with_an_address :: proc(t: ^testing.T) {
	site := metadata_test_site(TEST_ADDRESS)
	written := metadata_test_written(&site)
	sitemap := site_sitemap(&site)
	problems := site_check_metadata(TEST_ADDRESS, site.pages[:], written, sitemap, site.picture_sizes)
	for problem in problems {
		testing.expectf(t, false, "a good site has a problem: %s", problem)
	}
	for path, html in written {
		testing.expectf(t, site_inline_code_problem(html) == "", "%s: %s", path, site_inline_code_problem(html))
		testing.expectf(t, strings.contains(html, "<meta name=\"twitter:card\" content=\"summary_large_image\">"), "%s has no summary card", path)
	}
	home := written[SITE_PAGE]
	testing.expect(t, strings.contains(home, "<link rel=\"canonical\" href=\"" + TEST_ADDRESS + "/\">"))
	testing.expect(t, strings.contains(home, "<meta property=\"og:image\" content=\"" + TEST_ADDRESS + "/pictures/mark_card.png\">"))
	testing.expect(t, strings.contains(written[TEST_GUIDE_A], "<meta property=\"og:type\" content=\"article\">"))
	// The graph names the nodes of each kind of page.
	testing.expect(t, strings.contains(home, "\"@type\":\"WebSite\""))
	testing.expect(t, strings.contains(home, "\"@type\":\"SearchAction\""))
	// The search of the site is at the home of the docs, whose own field reads "?q=".
	testing.expect(t, strings.contains(home, "\"urlTemplate\":\"" + TEST_ADDRESS + "/docs/?q={search_term_string}\""))
	testing.expect(t, strings.contains(home, "\"@type\":\"SoftwareSourceCode\""))
	testing.expect(t, strings.contains(home, "\"@type\":\"SoftwareApplication\""))
	testing.expect(t, strings.contains(home, "\"contentUrl\":\"" + TEST_ADDRESS + "/pictures/a.png\""))
	testing.expect(t, strings.contains(home, "\"caption\":\"A \\u0026 B\""))
	testing.expect(t, !strings.contains(home, "\"@type\":\"BreadcrumbList\""))
	testing.expect(t, strings.contains(written[TEST_GUIDE_A], "\"@type\":\"TechArticle\""))
	testing.expect(t, strings.contains(written[TEST_GUIDE_A], "\"@type\":\"BreadcrumbList\""))
	// The breadcrumbs of a guide: the home, the docs, the guides, then the guide.
	testing.expect(t, strings.contains(written[TEST_GUIDE_A], "\"position\":2,\"name\":\"Docs\",\"item\":\"" + TEST_ADDRESS + "/docs/\""))
	testing.expect(t, strings.contains(written[TEST_GUIDE_A], "\"position\":3,\"name\":\"Guides\",\"item\":\"" + TEST_ADDRESS + "/docs/guides/\""))
	testing.expect(t, !strings.contains(written[TEST_GUIDE_A], "dateModified"))
	glossary_page := site_page_file(SITE_GLOSSARY_FOLDER)
	testing.expect(t, strings.contains(written[glossary_page], "\"@type\":\"DefinedTerm\""))
	// The index names each term by its entry on the page of its group.
	testing.expect(t, strings.contains(written[glossary_page], "\"@id\":\"" + TEST_ADDRESS + "/docs/reference/glossary/code/#term-module\""))
	testing.expect(t, !strings.contains(written[glossary_page], "\"@id\":\"" + TEST_ADDRESS + "/docs/reference/glossary/#term-module\""))
	testing.expect(t, strings.contains(written["news/index.html"], "\"@type\":\"BlogPosting\""))
	testing.expect(t, strings.contains(written["news/index.html"], "\"datePublished\":\"2026-11-12\""))
	testing.expect(t, strings.contains(written[site_section_page(.Guides)], "\"@type\":\"CollectionPage\""))
	testing.expect(t, strings.contains(written[site_section_page(.Docs)], "\"@type\":\"CollectionPage\""))
	// A page that is not an index page is a WebPage, though its file is an index.html.
	testing.expect(t, strings.contains(written["news/index.html"], "\"@type\":\"WebPage\""))
	// The sitemap, robots.txt and the feeds.
	testing.expect_value(t, strings.count(sitemap, "<url>"), len(site.pages))
	testing.expect(t, strings.contains(sitemap, "<loc>" + TEST_ADDRESS + "/news/</loc><lastmod>2026-11-12</lastmod>"))
	testing.expect(t, strings.contains(sitemap, "<loc>" + TEST_ADDRESS + "/docs/guides/A/</loc></url>"))
	testing.expect(t, strings.contains(site_robots(&site), "Sitemap: " + TEST_ADDRESS + "/sitemap.xml\n"))
	feed := site_releases_feed(&site)
	testing.expect(t, strings.contains(feed, "<link rel=\"self\" type=\"application/atom+xml\" href=\"" + TEST_ADDRESS + "/releases.xml\"/>"))
	testing.expect(t, strings.contains(feed, "<id>" + SITE_REPOSITORY_ADDRESS + "/blob/master/" + CHANGELOG_FILE + "#release-"))
	testing.expect(t, strings.contains(feed, "href=\"" + TEST_ADDRESS + "/releases/#release-"))
	testing.expect(t, strings.contains(site_language_model_index(&site), "](" + TEST_ADDRESS + "/docs/guides/A/): The guide A."))

	Damage :: struct {
		page, before, after: string,
	}
	damages := []Damage {
		{TEST_GUIDE_A, "<link rel=\"canonical\"", "<link rel=\"other\""}, // No canonical address.
		{TEST_GUIDE_A, "<link rel=\"canonical\" href=\"" + TEST_ADDRESS + "/docs/guides/A/\"", "<link rel=\"canonical\" href=\"" + TEST_ADDRESS + "/docs/guides/B/\""}, // The canonical address of another page.
		{TEST_GUIDE_A, "<link rel=\"canonical\" href=\"" + TEST_ADDRESS + "/docs/guides/A/\"", "<link rel=\"canonical\" href=\"" + TEST_ADDRESS + "/guides/A/\""}, // The old address of the folders before the docs.
		{TEST_GUIDE_A, "<link rel=\"canonical\" href=\"" + TEST_ADDRESS + "/docs/guides/A/\"", "<link rel=\"canonical\" href=\"" + TEST_ADDRESS + "/guides/A.html\""}, // The old address of the .html files.
		{TEST_GUIDE_A, "<meta property=\"og:image:width\" content=\"1200\">", "<meta property=\"og:image:width\" content=\"1201\">"}, // A wrong size.
		{TEST_GUIDE_A, "/pictures/mark_card.png\">", "/pictures/absent.png\">"}, // A picture that does not exist.
		{TEST_GUIDE_A, "<meta property=\"og:title\"", "<meta property=\"og:other\""}, // No title.
		{TEST_GUIDE_A, "\"@graph\":[", "\"@graph\":"}, // JSON that does not parse.
		{TEST_GUIDE_A, "\"breadcrumb\":{\"@id\":\"", "\"breadcrumb\":{\"@id\":\"https://elsewhere.invalid/"}, // An id that is not in the graph.
		{TEST_GUIDE_A, "\"@context\":\"https://schema.org\"", "\"@context\":\"https://example.org\""},
	}
	for damage in damages {
		changed := metadata_test_copy(written)
		replaced, did := strings.replace_all(written[damage.page], damage.before, damage.after, context.temp_allocator)
		testing.expectf(t, did, "the text %q is not in %s", damage.before, damage.page)
		changed[damage.page] = replaced
		testing.expectf(t, len(site_check_metadata(TEST_ADDRESS, site.pages[:], changed, sitemap, site.picture_sizes)) > 0, "no problem found after %q became %q", damage.before, damage.after)
	}
	// Two JSON-LD scripts on one page.
	with_two_graphs := metadata_test_copy(written)
	with_two_graphs[TEST_GUIDE_B] = strings.concatenate({written[TEST_GUIDE_B], SITE_STRUCTURED_DATA_OPEN, "{}", SITE_SCRIPT_CLOSE}, context.temp_allocator)
	testing.expect(t, len(site_check_metadata(TEST_ADDRESS, site.pages[:], with_two_graphs, sitemap, site.picture_sizes)) > 0)
	// A sitemap with a page less, or a page that the command does not write.
	short_sitemap, removed := strings.replace_all(sitemap, "<url><loc>" + TEST_ADDRESS + "/docs/guides/A/</loc></url>\n", "", context.temp_allocator)
	testing.expect(t, removed)
	testing.expect(t, len(site_check_metadata(TEST_ADDRESS, site.pages[:], written, short_sitemap, site.picture_sizes)) > 0)
	long_sitemap := strings.concatenate({sitemap, "<url><loc>" + TEST_ADDRESS + "/guides/A/</loc></url>\n"}, context.temp_allocator)
	testing.expect(t, len(site_check_metadata(TEST_ADDRESS, site.pages[:], written, long_sitemap, site.picture_sizes)) > 0)
	// A picture that the command did not write.
	without_card := make(map[string][2]int, context.temp_allocator)
	testing.expect(t, len(site_check_metadata(TEST_ADDRESS, site.pages[:], written, sitemap, without_card)) > 0)
}

@(test)
site_author_of_the_site :: proc(t: ^testing.T) {
	testing.expect_value(t, site_copyright_holder("Copyright (c) 2026 Ada Example"), "Ada Example")
	testing.expect_value(t, site_copyright_holder("Copyright © 2025-2026, 2027 Ada Example."), "Ada Example")
	testing.expect_value(t, site_copyright_holder("Copyright (c) 2026"), "")
	testing.expect_value(t, site_copyright_holder(""), "")
	// The line of LICENSE of the repository gives a name, not a year.
	if text, read := site_read_quiet(SITE_LICENSE_FILE); read {
		holder := site_copyright_holder(site_line_after(text, "Copyright "))
		testing.expect(t, holder != "")
		testing.expect(t, len(holder) > 0 && (holder[0] < '0' || holder[0] > '9') && holder[0] != '(')
	}
	testing.expect(t, strings.has_prefix(site_account_address(), "https://github.com/"))
	testing.expect(t, strings.has_prefix(SITE_REPOSITORY_ADDRESS, strings.concatenate({site_account_address(), "/"}, context.temp_allocator)))

	// With an address: the author, and the nodes that name it.
	site := metadata_test_site(TEST_ADDRESS)
	written := metadata_test_written(&site)
	author_reference :: "{\"@id\":\"" + TEST_ADDRESS + "/#author\"}"
	home := written[SITE_PAGE]
	testing.expect(t, strings.contains(home, "<meta name=\"author\" content=\"Ada Example\">"))
	testing.expect(t, strings.contains(home, "\"@type\":\"Person\",\"@id\":\"" + TEST_ADDRESS + "/#author\",\"name\":\"Ada Example\",\"url\":\"" ))
	testing.expect(t, strings.contains(home, "\"publisher\":" + author_reference))
	testing.expect_value(t, strings.count(home, "\"author\":" + author_reference), 2) // The program and its source code.
	testing.expect_value(t, strings.count(written[TEST_GUIDE_A], "\"author\":" + author_reference), 3)
	testing.expect_value(t, strings.count(written["news/index.html"], "\"author\":" + author_reference), 3)
	testing.expect_value(t, len(site_check_metadata(TEST_ADDRESS, site.pages[:], written, site_sitemap(&site), site.picture_sizes)), 0)
	testing.expect(t, strings.contains(site_releases_feed(&site), "<author><name>Ada Example</name><uri>"))

	// With no holder: no author, no field that names one, and the feed
	// names the system.
	site.author = ""
	without_author := metadata_test_written(&site)
	testing.expect(t, !strings.contains(without_author[SITE_PAGE], "\"Person\""))
	testing.expect(t, !strings.contains(without_author[SITE_PAGE], "#author"))
	testing.expect(t, !strings.contains(without_author[SITE_PAGE], "name=\"author\""))
	testing.expect_value(t, len(site_check_metadata(TEST_ADDRESS, site.pages[:], without_author, site_sitemap(&site), site.picture_sizes)), 0)
	testing.expect(t, strings.contains(site_releases_feed(&site), "<author><name>" + SITE_SYSTEM_NAME + "</name>"))
}

// The site menu: one list of the sections and the search inside one
// details element, whose summary is the button with its name.
@(test)
site_menu_of_the_bar :: proc(t: ^testing.T) {
	site := metadata_test_site("")
	html := site_page_html(&site, site.pages[2]) // The guide A.
	testing.expect_value(t, site.pages[2].path, TEST_GUIDE_A)
	testing.expect_value(t, strings.count(html, "<details"), 1)
	testing.expect_value(t, strings.count(html, "<summary"), 1)
	testing.expect_value(t, strings.count(html, "aria-label=\"Sections\""), 1)
	testing.expect(t, strings.contains(html, "<span class=\"bar-menu-name\">Menu</span></summary>"))
	details := strings.index(html, "<details class=\"bar-menu\">")
	sections := strings.index(html, "<nav class=\"bar-sections\" aria-label=\"Sections\">")
	search := strings.index(html, "id=\"site-search-box\"")
	details_end := strings.index(html, "</details>")
	testing.expect(t, details >= 0 && details < sections && sections < search && search < details_end)
	if sections < 0 || details_end < 0 || sections > details_end {
		return
	}
	navigation := html[sections:]
	navigation = navigation[:strings.index(navigation, "</nav>")]
	testing.expect_value(t, strings.count(navigation, "<ul>"), 1)
	// Each section once in the page; the current one marked: a guide is a
	// page of the docs. The guides and the reference are not in the bar.
	testing.expect_value(t, strings.count(html, ">News</a>"), 1)
	testing.expect(t, strings.contains(navigation, "aria-current=\"page\">Docs</a>"))
	testing.expect(t, !strings.contains(navigation, ">Guides</a>"))
	testing.expect(t, !strings.contains(navigation, ">Reference</a>"))
	testing.expect(t, strings.contains(navigation, ">Status</a>") == site_page_exists(&site, site_section_page(.Status)))
	testing.expect_value(t, site_inline_code_problem(html), "")

	// The style sheet draws the button and the alignment of the news cards,
	// each with its fallback; the script opens the menu on a wide screen.
	style := site_style_sheet("")
	testing.expect(t, strings.contains(style, ".bar-menu-button"))
	testing.expect(t, strings.contains(style, "@supports selector(::details-content)"))
	testing.expect(t, strings.contains(style, "grid-template-rows: subgrid"))
	testing.expect(t, strings.contains(style, "@supports not (grid-template-rows: subgrid)"))
	script := site_search_script()
	testing.expect(t, strings.contains(script, "document.querySelector(\"details.bar-menu\")"))
	testing.expect(t, strings.contains(script, "matchMedia(\"(min-width: 720px)\")"))
}

// One search field on a page: in the bar of every page, but on the home of
// the docs, whose field is in the page and whose bar has none. The script
// takes the field that the page has, and opens the menu only for a field
// inside it.
@(test)
site_one_search_field_on_each_page :: proc(t: ^testing.T) {
	site := metadata_test_site("")
	written := metadata_test_written(&site)
	for page in site.pages {
		testing.expectf(t, site_search_field_problem(page, written[page.path]) == "", "%s: %s", page.path, site_search_field_problem(page, written[page.path]))
	}
	field_mark :: "id=\"" + SITE_SEARCH_FIELD_ID + "\""
	docs_page := site_section_page(.Docs)
	docs := written[docs_page]
	testing.expect_value(t, strings.count(docs, field_mark), 1)
	testing.expect(t, strings.index(docs, field_mark) > strings.index(docs, "</header>"))
	testing.expect(t, strings.contains(docs, "class=\"search search-door\""))
	guide := written[TEST_GUIDE_A]
	testing.expect(t, strings.index(guide, field_mark) < strings.index(guide, "</header>"))
	testing.expect(t, !strings.contains(guide, "search-door"))

	// A bad page: a guide with a second field, a guide with none, the home
	// of the docs with a field in its bar too, and a page that says that it
	// holds its field but has it in the bar.
	docs_record: Site_Page
	for page in site.pages {
		if page.path == docs_page {
			docs_record = page
		}
	}
	guide_record := site.pages[2]
	two_fields := strings.concatenate({guide, site_search_field_html(.Docs_Home)}, context.temp_allocator)
	testing.expect(t, site_search_field_problem(guide_record, two_fields) != "")
	no_field, _ := strings.replace_all(guide, field_mark, "id=\"other\"", context.temp_allocator)
	testing.expect(t, site_search_field_problem(guide_record, no_field) != "")
	in_bar_too := docs_record
	in_bar_too.search_in_page = false
	docs_with_bar_field := site_page_html(&site, in_bar_too)
	testing.expect(t, site_search_field_problem(docs_record, docs_with_bar_field) != "")
	moved := guide_record
	moved.search_in_page = true
	testing.expect(t, site_search_field_problem(moved, guide) != "")

	// The script: one implementation for both fields.
	script := site_search_script()
	testing.expect(t, strings.contains(script, "document.getElementById(\"" + SITE_SEARCH_FIELD_ID + "\")"))
	testing.expect(t, strings.contains(script, "menu.contains(box)"))
	testing.expect_value(t, strings.count(script, "showMenu(); box"), 0)
}

// A title that tries to end the script element, open a comment or end a
// line of a script stays a text of the JSON, and the page stays whole.
@(test)
site_structured_data_of_a_hostile_title :: proc(t: ^testing.T) {
	site := metadata_test_site(TEST_ADDRESS)
	hostile := "</script><!-- \u2028 \u2029 \"quote\" \\ & <b>"
	page := Site_Page{path = SITE_GUIDE_FOLDER + "/C/" + SITE_PAGE, title = hostile, description = "The guide C.", section = .Guides, crumbs = site_crumbs(.Guides), body = "<h1>C</h1>"}
	site_page_add(&site, page)
	html := site_page_html(&site, page)
	testing.expect_value(t, site_inline_code_problem(html), "")
	testing.expect_value(t, strings.count(html, "</script>"), 2) // The search script and the graph.
	testing.expect(t, !strings.contains(html, "<!--"))
	texts := site_structured_data_texts(html)
	testing.expect_value(t, len(texts), 1)
	if len(texts) != 1 {
		return
	}
	// A line end of a script stays an escape in the graph.
	testing.expect(t, !strings.contains(texts[0], "\u2028") && !strings.contains(texts[0], "\u2029"))
	testing.expect(t, strings.contains(texts[0], "\\u2028"))
	value, err := json.parse_string(texts[0], .JSON, false, context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	root, _ := value.(json.Object)
	graph, _ := root["@graph"].(json.Array)
	found := false
	for node in graph {
		object, is_object := node.(json.Object)
		if !is_object {
			continue
		}
		if type_name, _ := object["@type"].(json.String); type_name == "WebPage" {
			name, _ := object["name"].(json.String)
			testing.expect_value(t, name, hostile)
			found = true
		}
	}
	testing.expect(t, found)
}

@(test)
site_inline_code_allows_only_the_graph :: proc(t: ^testing.T) {
	testing.expect_value(t, site_inline_code_problem(SITE_STRUCTURED_DATA_OPEN + "{\"a\":\"\\u003c\"}" + SITE_SCRIPT_CLOSE), "")
	testing.expect(t, site_inline_code_problem(SITE_STRUCTURED_DATA_OPEN + "{\"a\":\"<b>\"}" + SITE_SCRIPT_CLOSE) != "")
	testing.expect(t, site_inline_code_problem(SITE_STRUCTURED_DATA_OPEN + "{}") != "")
	testing.expect(t, site_inline_code_problem("<script type=\"application/ld+json\" id=\"x\">{}</script>") != "")
	testing.expect(t, site_inline_code_problem("<script type=\"module\">alert(1)</script>") != "")
}

@(test)
site_manifest_parses :: proc(t: ^testing.T) {
	site := metadata_test_site("")
	value, err := json.parse_string(site_manifest(&site), .JSON, false, context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	root, _ := value.(json.Object)
	icons, _ := root["icons"].(json.Array)
	testing.expect_value(t, len(icons), 3) // 192 and 512 for any use, 512 maskable.
	name, _ := root["name"].(json.String)
	testing.expect_value(t, name, SITE_SYSTEM_NAME)
	start, _ := root["start_url"].(json.String)
	scope, _ := root["scope"].(json.String)
	testing.expect_value(t, start, "./")
	testing.expect_value(t, scope, "./")
}

@(test)
site_icon_file_of_the_root :: proc(t: ^testing.T) {
	first := metadata_test_png(2, 2, 4, []u8{1, 2, 3, 255, 4, 5, 6, 0, 7, 8, 9, 128, 10, 11, 12, 255})
	second := metadata_test_png(3, 1, 3, []u8{1, 2, 3, 4, 5, 6, 7, 8, 9})
	pictures := [][]u8{first, second}
	file, ok := site_ico_encode(pictures)
	testing.expect(t, ok)
	entries, problem := site_ico_read(file)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(entries), 2)
	if len(entries) == 2 {
		testing.expect_value(t, entries[0].width, 2)
		testing.expect_value(t, entries[0].height, 2)
		testing.expect_value(t, entries[0].offset, SITE_ICO_HEADER_SIZE + 2 * SITE_ICO_ENTRY_SIZE)
		testing.expect_value(t, entries[0].bytes, len(first))
		testing.expect_value(t, entries[1].width, 3)
		testing.expect_value(t, entries[1].height, 1)
		testing.expect_value(t, entries[1].offset, entries[0].offset + len(first))
		testing.expect_value(t, entries[1].bytes, len(second))
		testing.expect_value(t, entries[1].offset + entries[1].bytes, len(file))
		testing.expect(t, string(file[entries[1].offset:][:entries[1].bytes]) == string(second))
	}
	// A damaged file: cut, another type, an entry outside the file.
	_, cut_problem := site_ico_read(file[:len(file) - 1])
	testing.expect(t, cut_problem != "")
	other_type := make([]u8, len(file), context.temp_allocator)
	copy(other_type, file)
	other_type[2] = 2
	_, type_problem := site_ico_read(other_type)
	testing.expect(t, type_problem != "")
	_, short_problem := site_ico_read(file[:SITE_ICO_HEADER_SIZE + 4])
	testing.expect(t, short_problem != "")
	_, empty_ok := site_ico_encode(nil)
	testing.expect(t, !empty_ok)
	_, not_png_ok := site_ico_encode([][]u8{[]u8{1, 2, 3}})
	testing.expect(t, !not_png_ok)
}

@(test)
site_icons_of_the_site :: proc(t: ^testing.T) {
	// Each raster icon is the heron at a whole cell size with an even
	// margin; the icon of a phone and the maskable one are opaque, the
	// others transparent; the maskable drawing is inside the circle of
	// 80 percent of the icon.
	for icon in site_icons {
		drawing := 24 * icon.heron_cell
		testing.expectf(t, drawing <= icon.size && (icon.size - drawing) % 2 == 0, "the icon of %d has a drawing of %d", icon.size, drawing)
		data, encoded := site_mark_encode(site_icon_picture(icon))
		testing.expect(t, encoded)
		width, height, _ := site_png_size(data)
		testing.expect_value(t, width, icon.size)
		testing.expect_value(t, height, icon.size)
		testing.expect_value(t, site_png_is_opaque(data), icon.opaque)
		if icon.file_name == SITE_ICON_MASKABLE {
			// The corners of the drawing: 2 * (drawing / 2)^2 <= (0.4 * size)^2.
			testing.expect(t, 200 * drawing * drawing <= 64 * icon.size * icon.size)
		}
	}
	// The ends of the gradient of support/mark: 0.7 * c + 76.5 and 0.7 * c.
	black_start, black_end := site_gradient_end_colors(0x000000)
	testing.expect_value(t, black_start, 0x4D4D4D)
	testing.expect_value(t, black_end, 0x000000)
	start, end := site_gradient_end_colors(0xFFFFFF)
	testing.expect_value(t, start, 0xFFFFFF)
	testing.expect_value(t, end, 0xB3B3B3)

	// The SVG icon: the cells of the heron as rectangles, one for each run.
	svg := site_icon_svg()
	testing.expect(t, strings.has_prefix(svg, "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\""))
	testing.expect(t, strings.contains(svg, "shape-rendering=\"crispEdges\""))
	testing.expect(t, strings.contains(svg, "@media (prefers-color-scheme: dark)"))
	covered := 0
	for row in 0 ..< 24 {
		for column in 0 ..< 24 {
			if _, found := mark.heron_cell_part(column, row); found {
				covered += 1
			}
		}
	}
	widths := 0
	rest := svg
	for {
		start_index := strings.index(rest, "<rect ")
		if start_index < 0 {
			break
		}
		end_index := strings.index_byte(rest[start_index:], '>')
		if end_index < 0 {
			break
		}
		width_value, _ := site_decimal(site_first_attribute_value(rest[start_index:start_index + end_index], "width=\""))
		widths += width_value
		rest = rest[start_index + end_index:]
	}
	testing.expect_value(t, widths, covered)

	// The files: favicon.ico at the root with 32 and 48, and the checks of a
	// good site and of damaged ones.
	files, files_ok := site_icon_files()
	testing.expect(t, files_ok)
	entries, favicon_problem := site_ico_read(files[SITE_FAVICON])
	testing.expect_value(t, favicon_problem, "")
	testing.expect_value(t, len(entries), 2)
	site := metadata_test_site("")
	written := metadata_test_written(&site)
	manifest := site_manifest(&site)
	for problem in site_icon_problems(site.pages[:], written, manifest, files) {
		testing.expectf(t, false, "a good site has a problem of its icons: %s", problem)
	}
	home := written[SITE_PAGE]
	favicon_link := strings.index(home, "<link rel=\"icon\" href=\"favicon.ico\" sizes=\"32x32\">")
	svg_link := strings.index(home, "<link rel=\"icon\" href=\"pictures/icon.svg\" type=\"image/svg+xml\">")
	touch_link := strings.index(home, "<link rel=\"apple-touch-icon\" href=\"pictures/icon_180.png\" sizes=\"180x180\">")
	testing.expect(t, favicon_link >= 0 && favicon_link < svg_link && svg_link < touch_link)
	testing.expect(t, strings.contains(written[TEST_GUIDE_A], "<link rel=\"icon\" href=\"../../../favicon.ico\" sizes=\"32x32\">"))

	without_favicon := make(map[string][]u8, context.temp_allocator)
	for path, data in files {
		if path != SITE_FAVICON {
			without_favicon[path] = data
		}
	}
	testing.expect(t, len(site_icon_problems(site.pages[:], written, manifest, without_favicon)) > 0)
	transparent_touch := make(map[string][]u8, context.temp_allocator)
	for path, data in files {
		transparent_touch[path] = data
	}
	transparent_touch[SITE_PICTURE_FOLDER + "/" + SITE_ICON_TOUCH] = files[SITE_PICTURE_FOLDER + "/" + SITE_ICON_192]
	testing.expect(t, len(site_icon_problems(site.pages[:], written, manifest, transparent_touch)) > 0)
	transparent_maskable := make(map[string][]u8, context.temp_allocator)
	for path, data in files {
		transparent_maskable[path] = data
	}
	transparent_maskable[SITE_PICTURE_FOLDER + "/" + SITE_ICON_MASKABLE] = files[SITE_PICTURE_FOLDER + "/" + SITE_ICON_512]
	testing.expect(t, len(site_icon_problems(site.pages[:], written, manifest, transparent_maskable)) > 0)
	wrong_size, replaced := strings.replace(manifest, "\"192x192\"", "\"190x190\"", 1, context.temp_allocator)
	testing.expect(t, replaced)
	testing.expect(t, len(site_icon_problems(site.pages[:], written, wrong_size, files)) > 0)
	no_maskable, removed := strings.replace(manifest, "\"maskable\"", "\"any\"", 1, context.temp_allocator)
	testing.expect(t, removed)
	testing.expect(t, len(site_icon_problems(site.pages[:], written, no_maskable, files)) > 0)
	changed := metadata_test_copy(written)
	replaced_home, _ := strings.replace(home, "sizes=\"180x180\"", "sizes=\"192x192\"", 1, context.temp_allocator)
	changed[SITE_PAGE] = replaced_home
	testing.expect(t, len(site_icon_problems(site.pages[:], changed, manifest, files)) > 0)
}

@(test)
site_srcset_candidates_are_checked :: proc(t: ^testing.T) {
	pages := [?]Site_Page{{path = "index.html", title = "Home", description = "The home.", body = ""}}
	files := make(map[string]int, context.temp_allocator)
	files["pictures/a.png"] = 1
	files["pictures/a_half.png"] = 1
	written := make(map[string]string, context.temp_allocator)
	written["index.html"] = "<h1>Home</h1><img src=\"pictures/a.png\" width=\"8\" height=\"8\" srcset=\"pictures/a_half.png 4w, pictures/a.png 8w\" alt=\"\">"
	testing.expect_value(t, len(site_check_pages(pages[:], written, files, false)), 0)
	written["index.html"] = "<h1>Home</h1><img src=\"pictures/a.png\" width=\"8\" height=\"8\" srcset=\"pictures/a_half.png 4w, pictures/b.png 8w\" alt=\"\">"
	testing.expect(t, len(site_check_pages(pages[:], written, files, false)) > 0)
}

@(private = "file")
metadata_test_png :: proc(width, height, channels: int, pixels: []u8) -> []u8 {
	image := png.Image {
		width    = width,
		height   = height,
		channels = channels,
		depth    = 8,
	}
	image.pixels = make([dynamic]u8, len(pixels), len(pixels), context.temp_allocator)
	copy(image.pixels[:], pixels)
	output := make([dynamic]u8, context.temp_allocator)
	_ = png.save_to_buffer(&output, &image, allocator = context.temp_allocator)
	return output[:]
}

@(test)
site_pictures_opaque_and_compressed :: proc(t: ^testing.T) {
	rgb := []u8 {
		0, 0, 0, 2, 0, 0, 100, 0, 0, 100, 0, 0,
		4, 0, 0, 6, 0, 0, 100, 0, 0, 100, 0, 0,
	}
	opaque := metadata_test_png(4, 2, 3, rgb)
	testing.expect(t, site_png_is_opaque(opaque))
	transparent := metadata_test_png(1, 1, 4, []u8{1, 2, 3, 0})
	testing.expect(t, !site_png_is_opaque(transparent))
	testing.expect(t, !site_png_is_opaque([]u8{1, 2, 3}))

	// A screen picture as the tool stores it, with no compression: bands
	// and a gradient, as a screen has. The compressed file has the same
	// pixels byte for byte, fewer bytes, and the same bytes a second time.
	width, height := 160, 120
	pixels := make([]u8, width * height * 3, context.temp_allocator)
	for y in 0 ..< height {
		for x in 0 ..< width {
			pixel := pixels[(y * width + x) * 3:][:3]
			pixel[0] = u8(x)
			pixel[1] = y < 16 ? 0x20 : 0x0B
			pixel[2] = u8((x / 8 + y / 8) % 2 * 200)
		}
	}
	stored := test_picture_with_stored_data(width, height, 3, pixels)
	stored_rgba := metadata_test_png(2, 2, 4, []u8{1, 2, 3, 255, 4, 5, 6, 0, 7, 8, 9, 128, 10, 11, 12, 255})
	for source in ([][]u8{stored, stored_rgba, opaque}) {
		compressed, compressed_ok := site_png_compress(source)
		testing.expect(t, compressed_ok)
		if !compressed_ok {
			continue
		}
		again, again_ok := site_png_compress(source)
		testing.expect(t, again_ok && string(again) == string(compressed))
		before, before_error := png.load_from_bytes(source, allocator = context.temp_allocator)
		after, after_error := png.load_from_bytes(compressed, allocator = context.temp_allocator)
		testing.expect(t, before_error == nil && after_error == nil && before != nil && after != nil)
		if before == nil || after == nil {
			continue
		}
		testing.expect_value(t, after.width, before.width)
		testing.expect_value(t, after.height, before.height)
		testing.expect_value(t, after.channels, before.channels)
		testing.expect_value(t, after.depth, before.depth)
		testing.expect(t, string(after.pixels[:]) == string(before.pixels[:]))
	}
	compressed_screen, _ := site_png_compress(stored)
	testing.expectf(t, len(compressed_screen) < len(stored) / 4, "the compressed picture has %d bytes, the stored one %d", len(compressed_screen), len(stored))
	_, damaged_ok := site_png_compress([]u8{1, 2, 3})
	testing.expect(t, !damaged_ok)

	// The picture for other sites that the tool draws.
	for picture in site_mark_pictures {
		if picture.file_name != SITE_MARK_CARD {
			continue
		}
		data, encoded := site_mark_encode(picture)
		testing.expect(t, encoded)
		card_width, card_height, _ := site_png_size(data)
		testing.expect_value(t, card_width, SITE_CARD_WIDTH)
		testing.expect_value(t, card_height, SITE_CARD_HEIGHT)
		testing.expect(t, site_png_is_opaque(data))
	}
}

// The files that the frame of each page names, as the command writes them.
@(private = "file")
metadata_test_files :: proc() -> map[string]int {
	files := make(map[string]int, context.temp_allocator)
	for path in ([]string{SITE_STYLE_SHEET, SITE_SEARCH_SCRIPT, SITE_MARK_ANIMATION_SCRIPT, SITE_MARK_FONT, SITE_FAVICON, SITE_NEWS_FEED, SITE_RELEASES_FEED, SITE_MANIFEST, "pictures/a.png"}) {
		files[path] = 1
	}
	for name in ([]string{SITE_ICON_SVG, SITE_ICON_TOUCH, SITE_MARK_BAR, SITE_MARK_BAR_LIGHT, SITE_MAKER_PICTURE}) {
		files[strings.concatenate({SITE_PICTURE_FOLDER, "/", name}, context.temp_allocator)] = 1
	}
	return files
}

// Each page is the index.html of its folder. With a site address and with
// none: every relative link of every page names a file that is written (a
// link to a folder names its index.html); the links have the form of the
// build; the canonical addresses are folders and all different; the
// sitemap, the search index and the guides before and after use the new
// addresses; a redirect page at each old path of both generations names
// its page straight, and nothing that other programs read names an old
// address.
@(test)
site_addresses_of_every_page :: proc(t: ^testing.T) {
	for address in ([]string{"", TEST_ADDRESS}) {
		site := metadata_test_site(address)
		written := metadata_test_written(&site)
		files := metadata_test_files()
		has_address := address != ""
		for path in written {
			testing.expectf(t, strings.has_suffix(path, "/" + SITE_PAGE) || path == SITE_PAGE, "the page %s is not the index.html of a folder", path)
		}
		for problem in site_check_pages(site.pages[:], written, files, has_address) {
			testing.expectf(t, false, "address %q: a good site has a problem: %s", address, problem)
		}
		guide := written[TEST_GUIDE_A]
		if has_address {
			testing.expect(t, strings.contains(guide, "<link rel=\"next\" href=\"../../../docs/guides/B/\">"))
			testing.expect(t, strings.contains(guide, "<a class=\"term\" href=\"../../../docs/reference/glossary/code/#term-module\">module</a>"))
			testing.expect(t, strings.contains(guide, "<a class=\"bar-home\" href=\"../../../\">"))
			testing.expect(t, strings.contains(guide, "href=\"../../../docs/reference/licenses/\">Licenses</a>"))
			testing.expect(t, strings.contains(written[TEST_GUIDE_B], "<link rel=\"prev\" href=\"../../../docs/guides/A/\">"))
			testing.expect(t, strings.contains(written[SITE_PAGE], "<a class=\"bar-home\" href=\"./\">"))
			testing.expect(t, !strings.contains(guide, "index.html\""))
		} else {
			testing.expect(t, strings.contains(guide, "<link rel=\"next\" href=\"../../../docs/guides/B/index.html\">"))
			testing.expect(t, strings.contains(guide, "<a class=\"term\" href=\"../../../docs/reference/glossary/code/index.html#term-module\">module</a>"))
			testing.expect(t, strings.contains(guide, "<a class=\"bar-home\" href=\"../../../index.html\">"))
		}
		// The style sheet, the script and the icons from a page three folders deep.
		testing.expect(t, strings.contains(guide, "<link rel=\"preload\" href=\"../../../" + SITE_MARK_FONT + "\" as=\"font\" type=\"font/ttf\" crossorigin>"))
		testing.expect(t, strings.contains(guide, "alt=\"\"></picture><span class=\"mark-name\">" + SITE_SYSTEM_NAME + "</span></a>"))
		testing.expect(t, strings.contains(guide, "<link rel=\"stylesheet\" href=\"../../../style.css\">"))
		testing.expect(t, strings.contains(guide, "<script src=\"../../../search.js\" data-index=\"search.json\" defer></script>"))

		// The canonical addresses: folders, all different.
		if has_address {
			canonical_addresses := make(map[string]string, context.temp_allocator)
			prefix :: "<link rel=\"canonical\" href=\""
			for path, html in written {
				start := strings.index(html, prefix)
				testing.expectf(t, start >= 0, "%s has no canonical address", path)
				if start < 0 {
					continue
				}
				rest := html[start + len(prefix):]
				canonical := rest[:strings.index_byte(rest, '"')]
				testing.expectf(t, strings.has_suffix(canonical, "/"), "%s: the canonical address %s is not a folder", path, canonical)
				other, taken := canonical_addresses[canonical]
				testing.expectf(t, !taken, "%s and %s share the canonical address %s", path, other, canonical)
				canonical_addresses[canonical] = path
			}
		}

		// The redirect pages: one at each old path of each page, which names
		// the page itself. The generation of the .html files: the guides A
		// and B, the glossary, the page of its group, the news, the releases
		// and the licenses. The generation of the folders before the docs:
		// the index of the guides, the guides A and B, the glossary, the
		// page of its group, the index of the reference and the licenses.
		// The home and the home of the docs have none.
		table_problems := site_redirects_make(&site)
		testing.expect_value(t, len(table_problems), 0)
		testing.expect_value(t, site.redirect_counts[.Html_Files], 7)
		testing.expect_value(t, site.redirect_counts[.Folders_Before_Docs], 7)
		testing.expect_value(t, len(site.redirects), 14)
		testing.expect(t, "reference/glossary.html" in site.redirects)
		testing.expect(t, "reference/glossary/code.html" in site.redirects)
		testing.expect(t, "guides/index.html" in site.redirects)
		testing.expect(t, "reference/index.html" in site.redirects)
		testing.expect(t, "docs.html" not_in site.redirects)
		for page in site.pages {
			for old in site_old_page_paths(page) {
				html, found := site.redirects[old.path]
				testing.expectf(t, found, "address %q: the old path %s of %s has no redirect page", address, old.path, page.path)
				// Straight to the page: the refresh names the page, never
				// another old path.
				refresh := strings.concatenate({SITE_REFRESH_OPEN, site_page_link(&site, old.path, page.path), "\">"}, context.temp_allocator)
				testing.expectf(t, strings.contains(html, refresh), "address %q: the redirect page %s does not name %s", address, old.path, page.path)
				_, is_page := written[old.path]
				testing.expectf(t, !is_page, "the old path %s is the path of a page", old.path)
			}
		}
		redirect, has_redirect := site.redirects["guides/A.html"]
		testing.expect(t, has_redirect)
		expected_link: string = has_address ? "../docs/guides/A/" : "../docs/guides/A/index.html"
		testing.expect(t, strings.contains(redirect, strings.concatenate({SITE_REFRESH_OPEN, expected_link, "\">"}, context.temp_allocator)))
		testing.expect(t, strings.contains(redirect, strings.concatenate({"<a href=\"", expected_link, "\">Guide A</a>"}, context.temp_allocator)))
		testing.expect(t, strings.contains(redirect, "<meta name=\"robots\" content=\"noindex\">"))
		testing.expect_value(t, strings.contains(redirect, "<link rel=\"canonical\" href=\"" + TEST_ADDRESS + "/docs/guides/A/\">"), has_address)
		testing.expect(t, !strings.contains(redirect, "<script"))
		testing.expect(t, !strings.contains(redirect, "<h1"))
		folder_redirect := site.redirects["guides/A/index.html"]
		folder_link: string = has_address ? "../../docs/guides/A/" : "../../docs/guides/A/index.html"
		testing.expect(t, strings.contains(folder_redirect, strings.concatenate({SITE_REFRESH_OPEN, folder_link, "\">"}, context.temp_allocator)))
		news_link: string = has_address ? "news/" : "news/index.html"
		testing.expect(t, strings.contains(site.redirects["news.html"], strings.concatenate({SITE_REFRESH_OPEN, news_link, "\">"}, context.temp_allocator)))
		for problem in site_check_redirects(site.redirects, written, files, has_address) {
			testing.expectf(t, false, "address %q: a good redirect has a problem: %s", address, problem)
		}
		// A redirect to a page that is not written, to another redirect, or
		// that takes the path of a file or of a page.
		absent_link: string = has_address ? "../docs/guides/C/" : "../docs/guides/C/index.html"
		broken_redirect, _ := strings.replace_all(redirect, expected_link, absent_link, context.temp_allocator)
		broken := make(map[string]string, context.temp_allocator)
		broken["guides/A.html"] = broken_redirect
		testing.expect(t, len(site_check_redirects(broken, written, files, has_address)) > 0)
		chained_link: string = has_address ? "A/" : "A/index.html"
		chained_redirect, _ := strings.replace_all(redirect, expected_link, chained_link, context.temp_allocator)
		chained := make(map[string]string, context.temp_allocator)
		for old_path, html in site.redirects {
			chained[old_path] = html
		}
		chained["guides/A.html"] = chained_redirect
		testing.expect(t, len(site_check_redirects(chained, written, files, has_address)) > 0)
		on_a_file := make(map[string]string, context.temp_allocator)
		on_a_file[SITE_STYLE_SHEET] = redirect
		testing.expect(t, len(site_check_redirects(on_a_file, written, files, has_address)) > 0)
		on_a_page := make(map[string]string, context.temp_allocator)
		on_a_page[TEST_GUIDE_B] = redirect
		testing.expect(t, len(site_check_redirects(on_a_page, written, files, has_address)) > 0)
		// Two pages with one old path: the table refuses it.
		twice := metadata_test_site(address)
		site_page_add(&twice, Site_Page{path = "guides/A/index.html", title = "Old A", description = "Not a page of today."})
		testing.expect(t, len(site_redirects_make(&twice)) > 0)

		// The sitemap: each page once by its folder, no old address.
		sitemap := site_sitemap(&site)
		if has_address {
			testing.expect_value(t, strings.count(sitemap, "<url>"), len(site.pages))
			testing.expect_value(t, strings.count(sitemap, "<loc>" + TEST_ADDRESS + "/docs/guides/A/</loc>"), 1)
			testing.expect(t, !strings.contains(sitemap, ".html</loc>"))
			testing.expect_value(t, len(site_check_metadata(TEST_ADDRESS, site.pages[:], written, sitemap, site.picture_sizes)), 0)
		}

		// The search index: the link of each page from the root, as the
		// script joins it to its folder.
		index := site_search_index_json(&site, site_search_entries(&site), site.pages[:])
		if has_address {
			testing.expect(t, strings.contains(index, "[\"docs/guides/A/\",\"Guide A\"]"))
			testing.expect(t, strings.contains(index, "[\"docs/\",\"Docs\"]"))
			testing.expect(t, strings.contains(index, "[\"./\",\"modus\"]"))
			testing.expect(t, !strings.contains(index, "index.html"))
		} else {
			testing.expect(t, strings.contains(index, "[\"docs/guides/A/index.html\",\"Guide A\"]"))
			testing.expect(t, strings.contains(index, "[\"index.html\",\"modus\"]"))
		}
		// No old address in the index, the sitemap, llms.txt or the feeds:
		// each is the address of a redirect page, in the form that each file
		// writes.
		llms := site_language_model_index(&site)
		news_feed := site_news_feed(&site)
		releases_feed := site_releases_feed(&site)
		for old_path in site.redirects {
			link := site_page_link(&site, SITE_PAGE, old_path)
			old_address := site_feed_page_address(&site, old_path)
			testing.expectf(t, !strings.contains(index, strings.concatenate({"[\"", link, "\""}, context.temp_allocator)), "the search index names the old path %s", old_path)
			testing.expectf(t, !strings.contains(llms, strings.concatenate({"](", old_address}, context.temp_allocator)), "llms.txt names the old path %s", old_path)
			testing.expectf(t, !strings.contains(news_feed, strings.concatenate({"href=\"", old_address}, context.temp_allocator)), "the news feed names the old path %s", old_path)
			testing.expectf(t, !strings.contains(releases_feed, strings.concatenate({"href=\"", old_address}, context.temp_allocator)), "the releases feed names the old path %s", old_path)
			if has_address {
				testing.expectf(t, !strings.contains(sitemap, strings.concatenate({"<loc>", site_page_address(TEST_ADDRESS, old_path), "</loc>"}, context.temp_allocator)), "the sitemap names the old path %s", old_path)
			}
		}
	}
}

// The documentation layout on the small site, with a site address and with
// none: each guide and reference page has one tree, inside the menu of the
// bar, with the current page marked, and one list "On this page"; the home
// has neither; every page passes the checks.
@(test)
site_documentation_layout_of_the_pages :: proc(t: ^testing.T) {
	for address in ([]string{"", TEST_ADDRESS}) {
		site := metadata_test_site(address)
		for &page in site.pages {
			if page.section == .Guides || page.section == .Reference {
				page.layout = .Documentation
			}
		}
		entries := make([]Site_Reference_Entry, 2, context.temp_allocator)
		entries[0] = Site_Reference_Entry{path = site_page_file(SITE_GLOSSARY_FOLDER), title = "Glossary"}
		entries[1] = Site_Reference_Entry{path = site_page_file(SITE_LICENSES_FOLDER), title = "Licenses"}
		site.reference_entries = entries
		written := metadata_test_written(&site)
		files := metadata_test_files()
		for problem in site_check_pages(site.pages[:], written, files, address != "") {
			testing.expectf(t, false, "address %q: a good site has a problem: %s", address, problem)
		}
		guide := written[TEST_GUIDE_A]
		testing.expect_value(t, strings.count(guide, SITE_TREE_OPEN), 1)
		testing.expect_value(t, strings.count(guide, SITE_OUTLINE_OPEN), 1)
		testing.expect(t, strings.contains(guide, "<body class=\"section-guides layout-documentation\">"))
		menu := strings.index(guide, "<details class=\"bar-menu\">")
		tree := strings.index(guide, SITE_TREE_OPEN)
		header_end := strings.index(guide, "</header>")
		testing.expect(t, menu >= 0 && menu < tree && tree < header_end)
		if tree >= 0 {
			tree_html := guide[tree:]
			tree_html = tree_html[:strings.index(tree_html, "</nav>")]
			testing.expect_value(t, strings.count(tree_html, "aria-current=\"page\""), 1)
			testing.expect(t, strings.contains(tree_html, "aria-current=\"page\">Guide A</a>"))
			testing.expect(t, strings.contains(tree_html, ">Guide B</a>"))
			// The tree starts with the way back to the home of the docs.
			docs_link := strings.index(tree_html, ">Docs</a>")
			testing.expect(t, docs_link >= 0 && docs_link < strings.index(tree_html, ">Guide A</a>"))
			// The tree of a guide holds the guides only; the reference has its own.
			testing.expect(t, !strings.contains(tree_html, ">Licenses</a>"))
		}
		licenses := written[site_page_file(SITE_LICENSES_FOLDER)]
		if licenses_tree := strings.index(licenses, SITE_TREE_OPEN); licenses_tree >= 0 {
			licenses_tree_html := licenses[licenses_tree:]
			licenses_tree_html = licenses_tree_html[:strings.index(licenses_tree_html, "</nav>")]
			testing.expect(t, strings.contains(licenses_tree_html, "aria-current=\"page\">Licenses</a>"))
			testing.expect(t, !strings.contains(licenses_tree_html, ">Guide B</a>"))
			testing.expect(t, !strings.contains(licenses_tree_html, "<details"))
		}
		home := written[SITE_PAGE]
		testing.expect(t, !strings.contains(home, SITE_TREE_OPEN))
		testing.expect(t, !strings.contains(home, SITE_OUTLINE_OPEN))
		testing.expect(t, strings.contains(home, "layout-presentation"))
	}
}
