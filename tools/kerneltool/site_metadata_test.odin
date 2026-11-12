package kerneltool

import "core:encoding/json"
import "core:image/png"
import "core:strings"
import "core:testing"

@(private = "file")
TEST_ADDRESS :: "https://example.invalid/modus"

// A small site: a home with a picture, the index of the guides, two
// guides, the glossary and the news, with or without an address.
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
	append(&site.guides, Site_Guide{source = "docs/A.md", path = "guides/A.html", title = "Guide A"})
	append(&site.guides, Site_Guide{source = "docs/B.md", path = "guides/B.html", title = "Guide B"})
	site_page_add(&site, Site_Page{path = SITE_PAGE, title = SITE_SYSTEM_NAME, description = "The home.", section = .Home, body = "<h1>modus</h1><img src=\"pictures/a.png\" width=\"8\" height=\"8\" alt=\"A &amp; B\">"})
	site_page_add(&site, Site_Page{path = "guides/index.html", title = "Guides", description = "The guides.", section = .Guides, crumbs = site_crumbs(.Home), body = "<h1>Guides</h1>"})
	site_page_add(&site, Site_Page{path = "guides/A.html", title = "Guide A", description = "The guide A.", section = .Guides, crumbs = site_crumbs(.Guides), body = "<h1>Guide A</h1>"})
	site_page_add(&site, Site_Page{path = "guides/B.html", title = "Guide B", description = "The guide B.", section = .Guides, crumbs = site_crumbs(.Guides), body = "<h1>Guide B</h1>"})
	site_page_add(&site, Site_Page{path = SITE_GLOSSARY_PAGE, title = "Glossary", description = "The terms.", section = .Reference, crumbs = site_crumbs(.Reference), body = "<h1>Glossary</h1>"})
	site_page_add(&site, Site_Page{path = site_section_pages[.News], title = "News", description = "The news.", section = .News, crumbs = site_crumbs(.Home), body = "<h1>News</h1>"})
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
	testing.expect_value(t, site_page_address(TEST_ADDRESS, "guides/index.html"), TEST_ADDRESS + "/guides/")
	testing.expect_value(t, site_page_address(TEST_ADDRESS, "guides/A.html"), TEST_ADDRESS + "/guides/A.html")
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
	testing.expect(t, strings.contains(written["guides/A.html"], "<link rel=\"next\" href=\"../guides/B.html\">"))
	testing.expect(t, strings.contains(written["guides/B.html"], "<link rel=\"prev\" href=\"../guides/A.html\">"))
	testing.expect(t, !strings.contains(written["guides/A.html"], "rel=\"prev\""))
	testing.expect_value(t, len(site_check_metadata("", site.pages[:], written, "", site.picture_sizes)), 0)

	// A canonical address or a sitemap with no address is a fault.
	changed := metadata_test_copy(written)
	changed["guides/A.html"] = strings.concatenate({"<link rel=\"canonical\" href=\"x\">", written["guides/A.html"]}, context.temp_allocator)
	testing.expect(t, len(site_check_metadata("", site.pages[:], changed, "", site.picture_sizes)) > 0)
	testing.expect(t, len(site_check_metadata("", site.pages[:], written, "<urlset></urlset>", site.picture_sizes)) > 0)

	// The feeds have relative links and no link "self".
	feed := site_releases_feed(&site)
	testing.expect(t, !strings.contains(feed, "rel=\"self\""))
	testing.expect_value(t, strings.count(feed, "<entry>"), 1)
	testing.expect(t, strings.contains(feed, "href=\"releases.html#"))
	testing.expect(t, strings.contains(site_language_model_index(&site), "](guides/A.html): The guide A."))
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
	testing.expect(t, strings.contains(written["guides/A.html"], "<meta property=\"og:type\" content=\"article\">"))
	// The graph names the nodes of each kind of page.
	testing.expect(t, strings.contains(home, "\"@type\":\"WebSite\""))
	testing.expect(t, strings.contains(home, "\"@type\":\"SearchAction\""))
	testing.expect(t, strings.contains(home, "\"@type\":\"SoftwareSourceCode\""))
	testing.expect(t, strings.contains(home, "\"@type\":\"SoftwareApplication\""))
	testing.expect(t, strings.contains(home, "\"contentUrl\":\"" + TEST_ADDRESS + "/pictures/a.png\""))
	testing.expect(t, strings.contains(home, "\"caption\":\"A \\u0026 B\""))
	testing.expect(t, !strings.contains(home, "\"@type\":\"BreadcrumbList\""))
	testing.expect(t, strings.contains(written["guides/A.html"], "\"@type\":\"TechArticle\""))
	testing.expect(t, strings.contains(written["guides/A.html"], "\"@type\":\"BreadcrumbList\""))
	testing.expect(t, !strings.contains(written["guides/A.html"], "dateModified"))
	testing.expect(t, strings.contains(written[SITE_GLOSSARY_PAGE], "\"@type\":\"DefinedTerm\""))
	testing.expect(t, strings.contains(written[SITE_GLOSSARY_PAGE], "\"@id\":\"" + TEST_ADDRESS + "/reference/glossary.html#term-module\""))
	testing.expect(t, strings.contains(written["news.html"], "\"@type\":\"BlogPosting\""))
	testing.expect(t, strings.contains(written["news.html"], "\"datePublished\":\"2026-11-12\""))
	testing.expect(t, strings.contains(written["guides/index.html"], "\"@type\":\"CollectionPage\""))
	// The sitemap, robots.txt and the feeds.
	testing.expect_value(t, strings.count(sitemap, "<url>"), len(site.pages))
	testing.expect(t, strings.contains(sitemap, "<loc>" + TEST_ADDRESS + "/news.html</loc><lastmod>2026-11-12</lastmod>"))
	testing.expect(t, strings.contains(sitemap, "<loc>" + TEST_ADDRESS + "/guides/A.html</loc></url>"))
	testing.expect(t, strings.contains(site_robots(&site), "Sitemap: " + TEST_ADDRESS + "/sitemap.xml\n"))
	feed := site_releases_feed(&site)
	testing.expect(t, strings.contains(feed, "<link rel=\"self\" type=\"application/atom+xml\" href=\"" + TEST_ADDRESS + "/releases.xml\"/>"))
	testing.expect(t, strings.contains(feed, "<id>" + SITE_REPOSITORY_ADDRESS + "/blob/master/" + CHANGELOG_FILE + "#release-"))
	testing.expect(t, strings.contains(site_language_model_index(&site), "](" + TEST_ADDRESS + "/guides/A.html): The guide A."))

	Damage :: struct {
		page, before, after: string,
	}
	damages := []Damage {
		{"guides/A.html", "<link rel=\"canonical\"", "<link rel=\"other\""}, // No canonical address.
		{"guides/A.html", "<link rel=\"canonical\" href=\"" + TEST_ADDRESS + "/guides/A.html\"", "<link rel=\"canonical\" href=\"" + TEST_ADDRESS + "/guides/B.html\""}, // The canonical address of another page.
		{"guides/A.html", "<meta property=\"og:image:width\" content=\"1200\">", "<meta property=\"og:image:width\" content=\"1201\">"}, // A wrong size.
		{"guides/A.html", "/pictures/mark_card.png\">", "/pictures/absent.png\">"}, // A picture that does not exist.
		{"guides/A.html", "<meta property=\"og:title\"", "<meta property=\"og:other\""}, // No title.
		{"guides/A.html", "\"@graph\":[", "\"@graph\":"}, // JSON that does not parse.
		{"guides/A.html", "\"breadcrumb\":{\"@id\":\"", "\"breadcrumb\":{\"@id\":\"https://elsewhere.invalid/"}, // An id that is not in the graph.
		{"guides/A.html", "\"@context\":\"https://schema.org\"", "\"@context\":\"https://example.org\""},
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
	with_two_graphs["guides/B.html"] = strings.concatenate({written["guides/B.html"], SITE_STRUCTURED_DATA_OPEN, "{}", SITE_SCRIPT_CLOSE}, context.temp_allocator)
	testing.expect(t, len(site_check_metadata(TEST_ADDRESS, site.pages[:], with_two_graphs, sitemap, site.picture_sizes)) > 0)
	// A sitemap with a page less, or a page that the command does not write.
	short_sitemap, removed := strings.replace_all(sitemap, "<url><loc>" + TEST_ADDRESS + "/guides/A.html</loc></url>\n", "", context.temp_allocator)
	testing.expect(t, removed)
	testing.expect(t, len(site_check_metadata(TEST_ADDRESS, site.pages[:], written, short_sitemap, site.picture_sizes)) > 0)
	long_sitemap := strings.concatenate({sitemap, "<url><loc>" + TEST_ADDRESS + "/absent.html</loc></url>\n"}, context.temp_allocator)
	testing.expect(t, len(site_check_metadata(TEST_ADDRESS, site.pages[:], written, long_sitemap, site.picture_sizes)) > 0)
	// A picture that the command did not write.
	without_card := make(map[string][2]int, context.temp_allocator)
	testing.expect(t, len(site_check_metadata(TEST_ADDRESS, site.pages[:], written, sitemap, without_card)) > 0)
}

// A title that tries to end the script element, open a comment or end a
// line of a script stays a text of the JSON, and the page stays whole.
@(test)
site_structured_data_of_a_hostile_title :: proc(t: ^testing.T) {
	site := metadata_test_site(TEST_ADDRESS)
	hostile := "</script><!-- \u2028 \u2029 \"quote\" \\ & <b>"
	page := Site_Page{path = "guides/C.html", title = hostile, description = "The guide C.", section = .Guides, crumbs = site_crumbs(.Guides), body = "<h1>C</h1>"}
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
	sizes := SITE_ICON_SIZES
	testing.expect_value(t, len(icons), len(sizes))
	name, _ := root["name"].(json.String)
	testing.expect_value(t, name, SITE_SYSTEM_NAME)
}

@(test)
site_srcset_candidates_are_checked :: proc(t: ^testing.T) {
	pages := [?]Site_Page{{path = "index.html", title = "Home", description = "The home.", body = ""}}
	files := make(map[string]int, context.temp_allocator)
	files["pictures/a.png"] = 1
	files["pictures/a_half.png"] = 1
	written := make(map[string]string, context.temp_allocator)
	written["index.html"] = "<h1>Home</h1><img src=\"pictures/a.png\" width=\"8\" height=\"8\" srcset=\"pictures/a_half.png 4w, pictures/a.png 8w\" alt=\"\">"
	testing.expect_value(t, len(site_check_pages(pages[:], written, files)), 0)
	written["index.html"] = "<h1>Home</h1><img src=\"pictures/a.png\" width=\"8\" height=\"8\" srcset=\"pictures/a_half.png 4w, pictures/b.png 8w\" alt=\"\">"
	testing.expect(t, len(site_check_pages(pages[:], written, files)) > 0)
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
site_pictures_opaque_and_half :: proc(t: ^testing.T) {
	// 4 by 2, RGB: the left square is 0, 2, 4, 6 in red; the right one 100.
	rgb := []u8 {
		0, 0, 0, 2, 0, 0, 100, 0, 0, 100, 0, 0,
		4, 0, 0, 6, 0, 0, 100, 0, 0, 100, 0, 0,
	}
	opaque := metadata_test_png(4, 2, 3, rgb)
	testing.expect(t, site_png_is_opaque(opaque))
	transparent := metadata_test_png(1, 1, 4, []u8{1, 2, 3, 0})
	testing.expect(t, !site_png_is_opaque(transparent))
	testing.expect(t, !site_png_is_opaque([]u8{1, 2, 3}))

	half, width, height, ok := site_png_half(opaque)
	testing.expect(t, ok)
	testing.expect_value(t, width, 2)
	testing.expect_value(t, height, 1)
	decoded, err := png.load_from_bytes(half, allocator = context.temp_allocator)
	testing.expect(t, err == nil && decoded != nil)
	if err == nil && decoded != nil && len(decoded.pixels) >= 6 {
		testing.expect_value(t, decoded.pixels[0], 3) // (0 + 2 + 4 + 6 + 2) / 4
		testing.expect_value(t, decoded.pixels[3], 100)
	}

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
