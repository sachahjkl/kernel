package kerneltool

import "core:os"
import "core:strings"
import "core:testing"

// One picture of a test, with a guide that the site of the tests has.
@(private = "file")
gallery_test_picture :: proc(name: string, group: Site_Gallery_Group, home: bool) -> Site_Gallery_Picture {
	file := strings.concatenate({name, ".png"}, context.temp_allocator)
	caption := strings.concatenate({"What the picture ", name, " shows: a <window> & its text."}, context.temp_allocator)
	return Site_Gallery_Picture {
		row = {file = file, group = group, caption = caption, guide = "docs/NETWORK.md", home = home},
		site_path = strings.concatenate({SITE_PICTURE_FOLDER, "/", file}, context.temp_allocator),
		thumbnail_path = strings.concatenate({SITE_THUMBNAIL_FOLDER, "/", file}, context.temp_allocator),
		width = SITE_SCREEN_PICTURE_WIDTH,
		height = SITE_SCREEN_PICTURE_HEIGHT,
	}
}

// The site of the tests with three pictures: two of the desktop, which the
// home shows, and one of the network.
@(private = "file")
gallery_test_site :: proc() -> Site {
	site := test_site()
	pictures := make([]Site_Gallery_Picture, 3, context.temp_allocator)
	pictures[0] = gallery_test_picture("desktop", .Desktop, true)
	pictures[1] = gallery_test_picture("heron_free", .Desktop, true)
	pictures[2] = gallery_test_picture("network", .Network, false)
	site.gallery = pictures
	return site
}

// The checks of the pages on one page of a test: each picture has its alt
// text, its width and its height, and each link names a file or a page.
@(private = "file")
gallery_test_page_problems :: proc(page: Site_Page, other_pages: []string, files: []string) -> []string {
	pages := make([dynamic]Site_Page, context.temp_allocator)
	append(&pages, page)
	written := make(map[string]string, context.temp_allocator)
	written[page.path] = strings.concatenate({"<h1>A page</h1>\n", page.body}, context.temp_allocator)
	for other in other_pages {
		written[other] = "<h1>Another page</h1>\n"
	}
	file_bytes := make(map[string]int, context.temp_allocator)
	for file in files {
		file_bytes[file] = 1
	}
	return site_check_pages(pages[:], written, file_bytes, false)
}

// Each picture of docs/screenshots is in one row of the table or in the
// excluded files: a new picture cannot be forgotten.
@(test)
site_gallery_table_names_every_picture :: proc(t: ^testing.T) {
	folder_files, listed := site_gallery_folder_files()
	testing.expect(t, listed, "cannot list docs/screenshots")
	testing.expect(t, len(folder_files) > 0, "docs/screenshots has no PNG file")
	problems := site_gallery_table_problems(site_gallery_rows[:], site_gallery_excluded[:], folder_files)
	for problem in problems {
		testing.expectf(t, false, "%s", problem)
	}
	testing.expect_value(t, len(site_gallery_rows) + len(site_gallery_excluded), len(folder_files))

	// A new picture of the folder that no row names is a problem.
	with_new := make([dynamic]string, context.temp_allocator)
	append(&with_new, ..folder_files)
	append(&with_new, "a_new_picture.png")
	new_problems := site_gallery_table_problems(site_gallery_rows[:], site_gallery_excluded[:], with_new[:])
	testing.expect_value(t, len(new_problems), 1)
	if len(new_problems) == 1 {
		testing.expect(t, strings.contains(new_problems[0], "docs/screenshots/a_new_picture.png"))
		testing.expect(t, strings.contains(new_problems[0], "in no row of the table of the gallery"))
	}

	// A row and an excluded line whose file is gone are problems.
	without_first := folder_files[1:]
	testing.expect(t, len(site_gallery_table_problems(site_gallery_rows[:], site_gallery_excluded[:], without_first)) == 1)
}

// The faults of a table: each one is found.
@(test)
site_gallery_table_of_a_damaged_table :: proc(t: ^testing.T) {
	files := []string{"one.png", "two.png", "three.png"}
	good := []Site_Gallery_Row {
		{file = "one.png", group = .Desktop, caption = "The first picture.", guide = "docs/NETWORK.md", home = true},
		{file = "two.png", group = .Console, caption = "The second picture.", guide = "docs/NETWORK.md"},
	}
	excluded := []Site_Gallery_Excluded{{"three.png", "It shows a text that is cut."}}
	testing.expect_value(t, len(site_gallery_table_problems(good, excluded, files)), 0)

	damaged := make([]Site_Gallery_Row, len(good), context.temp_allocator)
	// Two rows of one file.
	copy(damaged, good)
	damaged[1].file = "one.png"
	testing.expect(t, len(site_gallery_table_problems(damaged, excluded, files)) > 0)
	// A file that is not in the folder.
	copy(damaged, good)
	damaged[1].file = "absent.png"
	testing.expect(t, len(site_gallery_table_problems(damaged, excluded, files)) > 0)
	// A guide that is not a document of docs/.
	copy(damaged, good)
	damaged[1].guide = "README.md"
	testing.expect(t, len(site_gallery_table_problems(damaged, excluded, files)) > 0)
	// A film that is not a WebM file of docs/films.
	copy(damaged, good)
	damaged[1].film = "build/films/two.mp4"
	testing.expect(t, len(site_gallery_table_problems(damaged, excluded, files)) > 0)
	// No picture for the home.
	copy(damaged, good)
	damaged[0].home = false
	testing.expect(t, len(site_gallery_table_problems(damaged, excluded, files)) > 0)
	// A file in the table and in the excluded files.
	both := []Site_Gallery_Excluded{{"three.png", "It shows a text that is cut."}, {"two.png", "Twice."}}
	testing.expect(t, len(site_gallery_table_problems(good, both, files)) > 0)
	// An excluded file with no reason.
	no_reason := []Site_Gallery_Excluded{{"three.png", ""}}
	testing.expect(t, len(site_gallery_table_problems(good, no_reason, files)) > 0)
	// A picture that nothing names.
	testing.expect(t, len(site_gallery_table_problems(good, nil, files)) > 0)

	// More pictures for the home than its bound.
	many_files := make([dynamic]string, context.temp_allocator)
	many_rows := make([dynamic]Site_Gallery_Row, context.temp_allocator)
	for index in 0 ..= SITE_HOME_PICTURE_LIMIT {
		file := strings.concatenate({"picture", strings.repeat("x", index + 1, context.temp_allocator), ".png"}, context.temp_allocator)
		append(&many_files, file)
		append(&many_rows, Site_Gallery_Row{file = file, group = .Desktop, caption = "One picture.", guide = "docs/NETWORK.md", home = true})
	}
	testing.expect_value(t, len(site_gallery_table_problems(many_rows[:], nil, many_files[:])), 1)
	testing.expect_value(t, len(site_gallery_table_problems(many_rows[:SITE_HOME_PICTURE_LIMIT], nil, many_files[:SITE_HOME_PICTURE_LIMIT])), 0)
}

// The home shows at most SITE_HOME_PICTURE_LIMIT pictures, 8, each a row of
// the table, and the program heron is one of them.
@(test)
site_gallery_home_pictures_are_few :: proc(t: ^testing.T) {
	testing.expect_value(t, SITE_HOME_PICTURE_LIMIT, 8)
	home_count := 0
	heron_shown := false
	for row in site_gallery_rows {
		if row.home {
			home_count += 1
			heron_shown ||= row.file == "heron.png"
		}
	}
	testing.expect(t, home_count >= 1 && home_count <= SITE_HOME_PICTURE_LIMIT, "the home shows no picture, or more than its bound")
	testing.expect(t, heron_shown, "the home does not show the picture of the program heron")
}

// A caption is one sentence of plain text, at most
// SITE_GALLERY_CAPTION_LIMIT bytes, 160.
@(test)
site_gallery_captions_are_one_sentence :: proc(t: ^testing.T) {
	testing.expect_value(t, SITE_GALLERY_CAPTION_LIMIT, 160)
	for row in site_gallery_rows {
		testing.expectf(t, site_gallery_caption_problem(row.caption) == "", "%s: %s", row.file, site_gallery_caption_problem(row.caption))
	}
	testing.expect_value(t, site_gallery_caption_problem("The desktop: four windows, under the bar."), "")
	testing.expect(t, site_gallery_caption_problem("") != "")
	testing.expect(t, site_gallery_caption_problem("The desktop") != "")
	testing.expect(t, site_gallery_caption_problem("The desktop. Four windows.") != "")
	testing.expect(t, site_gallery_caption_problem("The `desktop` of the system.") != "")
	testing.expect(t, site_gallery_caption_problem("The **desktop** of the system.") != "")
	testing.expect(t, site_gallery_caption_problem(strings.concatenate({strings.repeat("a", SITE_GALLERY_CAPTION_LIMIT, context.temp_allocator), "."}, context.temp_allocator)) != "")
	testing.expect_value(t, site_gallery_caption_problem(strings.concatenate({strings.repeat("a", SITE_GALLERY_CAPTION_LIMIT - 1, context.temp_allocator), "."}, context.temp_allocator)), "")
	// Each group has a title and its one sentence.
	for group in Site_Gallery_Group {
		text := site_gallery_groups[group]
		testing.expectf(t, text.title != "" && strings.has_suffix(text.about, ".") && site_first_sentence(text.about) == text.about, "the group %v has no title or not one sentence", group)
	}
}

// The guide of each row is a document of the repository that the site
// shows as a page, and its film is a file of the repository.
@(test)
site_gallery_guides_are_pages :: proc(t: ^testing.T) {
	working_records := SITE_WORKING_RECORDS
	for row in site_gallery_rows {
		testing.expectf(t, os.exists(row.guide), "%s: the guide %s is not a file", row.file, row.guide)
		for record in working_records {
			testing.expectf(t, site_file_name(row.guide) != record, "%s: the guide %s is a working record, not a page of the site", row.file, row.guide)
		}
		if row.film != "" {
			testing.expectf(t, os.exists(row.film), "%s: the film %s is not a file", row.file, row.film)
		}
	}
}

// A thumbnail has the mean of each square of two by two pixels, and a
// picture with an odd side has none.
@(test)
site_gallery_thumbnail_is_the_mean :: proc(t: ^testing.T) {
	testing.expect_value(t, SITE_THUMBNAIL_DIVISOR, 2)
	// Four by two pixels of three channels: two squares.
	pixels := []u8 {
		0, 0, 0, 255, 255, 255, 10, 20, 30, 10, 20, 30,
		255, 255, 255, 0, 0, 0, 10, 20, 30, 13, 20, 33,
	}
	thumbnail, width, height, ok := site_thumbnail_pixels(pixels, 4, 2, 3)
	testing.expect(t, ok)
	testing.expect_value(t, width, 2)
	testing.expect_value(t, height, 1)
	testing.expect_value(t, len(thumbnail), 6)
	if len(thumbnail) == 6 {
		// 510 / 4 is 127.5, rounded to 128; (10 + 10 + 10 + 13) / 4 is 10.75, rounded to 11.
		expected := [6]u8{128, 128, 128, 11, 20, 31}
		for value, index in expected {
			testing.expect_value(t, thumbnail[index], value)
		}
	}
	_, _, _, odd_ok := site_thumbnail_pixels(pixels[:18], 3, 2, 3)
	testing.expect(t, !odd_ok, "a picture with an odd width has a thumbnail")
	_, _, _, short_ok := site_thumbnail_pixels(pixels[:12], 4, 2, 3)
	testing.expect(t, !short_ok, "a picture with too few bytes has a thumbnail")

	// Through the files: the thumbnail of a PNG file is a PNG file of half
	// its width and its height, with those pixels, and the same bytes at
	// each call.
	file, encode_error := png_encode(4, 2, 3, pixels)
	testing.expect(t, encode_error == nil)
	first, first_ok := site_thumbnail_encode(file)
	second, second_ok := site_thumbnail_encode(file)
	testing.expect(t, first_ok && second_ok)
	testing.expect(t, png_has_pixels(first, 2, 1, 3, thumbnail))
	testing.expect_value(t, string(first), string(second))
	_, not_png_ok := site_thumbnail_encode(transmute([]u8)string("not a PNG file"))
	testing.expect(t, !not_png_ok)
}

// The carousel of the home: each picture of the home is in the page with
// its link, its size and its caption, and nothing plays by itself.
@(test)
site_carousel_of_the_home :: proc(t: ^testing.T) {
	site := gallery_test_site()
	home := site_section_page(.Home)
	b := strings.builder_make(context.temp_allocator)
	site_carousel_write(&site, &b, home)
	html := strings.to_string(b)

	// Two pictures of the three: the rows that the home shows, in the order
	// of the table.
	testing.expect_value(t, strings.count(html, "<figure class=\"carousel-slide\""), 2)
	testing.expect_value(t, strings.count(html, "<li><a href=\"#picture-"), 2)
	testing.expect(t, !strings.contains(html, "network.png"))
	testing.expect(t, strings.index(html, "id=\"picture-desktop\"") < strings.index(html, "id=\"picture-heron-free\""))
	// A numbered link to each picture, above the row; the row is a region
	// that the keyboard reaches.
	testing.expect(t, strings.contains(html, "<li><a href=\"#picture-desktop\" data-slide=\"0\" aria-label=\"Picture 1 of 2: What the picture desktop shows: a &lt;window&gt; &amp; its text.\">1</a></li>"))
	testing.expect(t, strings.contains(html, "<li><a href=\"#picture-heron-free\" data-slide=\"1\""))
	testing.expect(t, strings.contains(html, "<div class=\"carousel-track\" role=\"region\" aria-label=\"Pictures of the machine, one in view\" tabindex=\"0\">"))
	testing.expect(t, strings.index(html, "<nav class=\"carousel-controls\"") < strings.index(html, "<div class=\"carousel-track\""))
	// A picture at its full size, with its width and its height, as a link
	// to its file; its caption with its place and the link to its guide.
	testing.expect(t, strings.contains(html, "<figure class=\"carousel-slide\" id=\"picture-desktop\"><a href=\"pictures/desktop.png\"><img src=\"pictures/desktop.png\" width=\"1024\" height=\"768\" loading=\"lazy\" decoding=\"async\" alt=\"What the picture desktop shows: a &lt;window&gt; &amp; its text.\"></a>"))
	testing.expect(t, strings.contains(html, "<figcaption><span class=\"carousel-place\">1 of 2</span> <span aria-hidden=\"true\">What the picture desktop shows: a &lt;window&gt; &amp; its text.</span> <a class=\"gallery-guide\" href=\"docs/guides/NETWORK/index.html\">Guide: NETWORK</a></figcaption>"))
	testing.expect(t, strings.contains(html, "<span class=\"carousel-place\">2 of 2</span>"))
	// Nothing plays by itself, and no page holds a style or a script of its own.
	testing.expect(t, !strings.contains(html, "autoplay"))
	testing.expect_value(t, site_inline_code_problem(html), "")
	// With no page of the gallery, no link to it; with one, the link.
	testing.expect(t, !strings.contains(html, "in the gallery"))
	site_page_add(&site, Site_Page{path = site_section_page(.Gallery), title = "Gallery", description = "The pictures.", section = .Gallery})
	with_gallery := strings.builder_make(context.temp_allocator)
	site_carousel_write(&site, &with_gallery, home)
	with_gallery_html := strings.to_string(with_gallery)
	testing.expect(t, strings.contains(with_gallery_html, "<p><a href=\"gallery/index.html\">All 3 pictures, in the gallery</a></p>"))

	// The checks of the pages: each picture has an alt text, a width and a
	// height, and each link names a file or a page of the site.
	page := Site_Page{path = home, title = "Home", description = "The home.", section = .Home, body = with_gallery_html}
	problems := gallery_test_page_problems(page, {site_section_page(.Gallery), "docs/guides/NETWORK/index.html"}, {"pictures/desktop.png", "pictures/heron_free.png"})
	for problem in problems {
		testing.expectf(t, false, "%s", problem)
	}

	// A site with no picture for the home writes nothing.
	empty_site := test_site()
	empty := strings.builder_make(context.temp_allocator)
	site_carousel_write(&empty_site, &empty, home)
	testing.expect_value(t, strings.to_string(empty), "")
}

// A group of the gallery: its heading, its count, and each picture as a
// thumbnail that links to the picture at its full size.
@(test)
site_gallery_group_of_pictures :: proc(t: ^testing.T) {
	site := gallery_test_site()
	path := site_section_page(.Gallery)
	testing.expect_value(t, path, "gallery/index.html")
	b := strings.builder_make(context.temp_allocator)
	site_gallery_group_html(&site, &b, path, .Desktop)
	html := strings.to_string(b)
	testing.expect(t, strings.has_prefix(html, "<section aria-labelledby=\"group-the-desktop-and-the-palette\">\n<h2 id=\"group-the-desktop-and-the-palette\">The desktop and the palette</h2>\n<p>"))
	testing.expect(t, strings.contains(html, " 2 pictures.</p>\n<div class=\"pictures gallery-pictures\">\n"))
	testing.expect_value(t, strings.count(html, "<figure id=\"picture-"), 2)
	testing.expect(t, strings.contains(html, "<figure id=\"picture-heron-free\"><a href=\"../pictures/heron_free.png\"><img src=\"../pictures/thumbnails/heron_free.png\" width=\"512\" height=\"384\" loading=\"lazy\" decoding=\"async\" alt=\"What the picture heron_free shows: a &lt;window&gt; &amp; its text.\"></a><figcaption><span aria-hidden=\"true\">What the picture heron_free shows: a &lt;window&gt; &amp; its text.</span> <a class=\"gallery-guide\" href=\"../docs/guides/NETWORK/index.html\">Guide: NETWORK</a></figcaption></figure>"))
	testing.expect(t, strings.has_suffix(html, "</div>\n</section>\n"))

	// A group of one picture says "1 picture"; a group with none is not written.
	one := strings.builder_make(context.temp_allocator)
	site_gallery_group_html(&site, &one, path, .Network)
	testing.expect(t, strings.contains(strings.to_string(one), " 1 picture.</p>"))
	none := strings.builder_make(context.temp_allocator)
	site_gallery_group_html(&site, &none, path, .Boot)
	testing.expect_value(t, strings.to_string(none), "")

	// A row with a film shows the film, with its controls and no autoplay,
	// and its caption as text.
	site.gallery[2].thumbnail_path = ""
	site.gallery[2].film = Site_News{picture = site.gallery[2].site_path, picture_width = 1024, picture_height = 768, picture_alt = site.gallery[2].row.caption, film = "films/network.webm", film_width = 2048, film_height = 1536, film_bytes = 1572784}
	film := strings.builder_make(context.temp_allocator)
	site_gallery_group_html(&site, &film, path, .Network)
	film_html := strings.to_string(film)
	testing.expect(t, strings.contains(film_html, "<div class=\"gallery-film\" id=\"picture-network\">\n<figure class=\"news-film\"><video controls preload=\"metadata\" playsinline muted loop poster=\"../pictures/network.png\" width=\"2048\" height=\"1536\">"))
	testing.expect(t, strings.contains(film_html, "<p class=\"gallery-caption\">What the picture network shows: a &lt;window&gt; &amp; its text. <a class=\"gallery-guide\""))
	testing.expect(t, !strings.contains(film_html, "autoplay"))
	testing.expect(t, !strings.contains(film_html, "thumbnails/network.png"))
}

// The page of the gallery: one page under the home, which the bar does not
// name, with each group that has a picture, and with pictures that pass
// the checks of the pages.
@(test)
site_gallery_page :: proc(t: ^testing.T) {
	testing.expect(t, site_section_under_home(.Gallery))
	testing.expect(t, !site_section_in_bar(.Gallery), "the bar names the gallery: its sections pass one line at 720 pixels")
	testing.expect(t, site_section_in_bar(.Docs) && site_section_in_bar(.Status) && site_section_in_bar(.News) && site_section_in_bar(.Releases))
	testing.expect(t, !site_section_under_home(.Home) && !site_section_under_home(.Guides))

	site := gallery_test_site()
	site_gallery_add(&site)
	testing.expect_value(t, len(site.pages), 1)
	if len(site.pages) != 1 {
		return
	}
	page := site.pages[0]
	testing.expect_value(t, page.path, "gallery/index.html")
	testing.expect_value(t, page.title, "Gallery")
	testing.expect_value(t, page.section, Site_Section.Gallery)
	testing.expect_value(t, page.layout, Site_Layout.Presentation)
	testing.expect(t, !page.is_index)
	testing.expect(t, len(page.description) <= SITE_DESCRIPTION_LIMIT && page.description != "")
	testing.expect_value(t, strings.count(page.body, "<h1"), 1)
	testing.expect(t, strings.contains(page.body, "<p class=\"lead\">3 pictures of the screen of " + SITE_SYSTEM_NAME + ", in 2 groups.</p>"))
	// The links to the groups, in the order of the page, and no group with
	// no picture.
	testing.expect(t, strings.contains(page.body, "<li><a href=\"#group-the-desktop-and-the-palette\">The desktop and the palette</a></li>"))
	testing.expect(t, strings.contains(page.body, "<li><a href=\"#group-the-network-the-cryptography-and-the-randomness\">"))
	testing.expect(t, !strings.contains(page.body, "#group-the-storage"))
	testing.expect_value(t, strings.count(page.body, "<section aria-labelledby=\"group-"), 2)
	testing.expect_value(t, strings.count(page.body, "<img "), 3)
	testing.expect(t, !strings.contains(page.body, "autoplay"))
	testing.expect_value(t, site_inline_code_problem(page.body), "")
	testing.expect_value(t, site_heading_value_problem(page.body), "")

	problems := gallery_test_page_problems(Site_Page{path = page.path, title = page.title, description = page.description, section = page.section, body = page.body[strings.index(page.body, "</h1>") + len("</h1>"):]}, {"docs/guides/NETWORK/index.html"}, {"pictures/desktop.png", "pictures/heron_free.png", "pictures/network.png", "pictures/thumbnails/desktop.png", "pictures/thumbnails/heron_free.png", "pictures/thumbnails/network.png"})
	for problem in problems {
		testing.expectf(t, false, "%s", problem)
	}
	// A thumbnail that the command did not write fails the checks.
	missing := gallery_test_page_problems(Site_Page{path = page.path, title = page.title, description = page.description, section = page.section, body = page.body[strings.index(page.body, "</h1>") + len("</h1>"):]}, {"docs/guides/NETWORK/index.html"}, {"pictures/desktop.png", "pictures/heron_free.png", "pictures/network.png"})
	testing.expect_value(t, len(missing), 3)

	// A site with no picture has no page of the gallery.
	empty_site := test_site()
	site_gallery_add(&empty_site)
	testing.expect_value(t, len(empty_site.pages), 0)
}

// The gallery of the repository: its ids are unique, the home has its
// pictures, and each group of the table has a picture.
@(test)
site_gallery_of_the_repository :: proc(t: ^testing.T) {
	ids := make(map[string]string, context.temp_allocator)
	for row in site_gallery_rows {
		id := site_gallery_picture_id(row.file)
		other, taken := ids[id]
		testing.expectf(t, !taken, "%s and %s have the id %s", row.file, other, id)
		ids[id] = row.file
	}
	group_ids := make(map[string]bool, context.temp_allocator)
	for group in Site_Gallery_Group {
		id := site_gallery_group_id(group)
		testing.expectf(t, id not_in group_ids, "two groups have the id %s", id)
		group_ids[id] = true
		count := 0
		for row in site_gallery_rows {
			count += row.group == group ? 1 : 0
		}
		testing.expectf(t, count > 0, "the group %v has no picture", group)
	}
}

// The rules and the script of the carousel: a picture is never wider than
// its pixels, a caption wraps, nothing plays by itself, and the script
// sets no style and starts no timer.
@(test)
site_carousel_rules_and_script :: proc(t: ^testing.T) {
	sheet := site_style_sheet("")
	rules := [?]string {
		".carousel-track { display: flex; overflow-x: auto; scroll-snap-type: x mandatory;",
		".carousel-slide { flex: 0 0 100%; scroll-snap-align: start;",
		".carousel-controls a { display: block; width: 32px; height: 32px;",
		".carousel-controls a[aria-current=\"true\"] {",
		".carousel-slide img { max-width: 1024px; }",
		".gallery-pictures figure img { max-width: 512px; }",
		".gallery-film { grid-column: 1 / -1;",
	}
	for rule in rules {
		testing.expectf(t, strings.contains(sheet, rule), "the style sheet has no %q", rule)
	}
	gallery_rules := site_gallery_rules()
	// No color of their own, no round corner, no movement, and no rule
	// that cuts a caption.
	for refused in ([]string{"#", "rgb", "border-radius", "animation", "transition", " scroll-behavior", "text-overflow", "white-space: nowrap", "overflow: hidden", "outline: none", "outline: 0"}) {
		testing.expectf(t, !strings.contains(gallery_rules, refused), "the rules of the gallery hold %q", refused)
	}
	// The numbered links of the home fit one line at 360 pixels: a column
	// of 328 pixels, links of 32 pixels and gaps of 4.
	testing.expect(t, SITE_HOME_PICTURE_LIMIT * 32 + (SITE_HOME_PICTURE_LIMIT - 1) * 4 <= 328)

	script := site_carousel_script()
	for part in ([]string{"\"use strict\";", ".carousel-track", ".carousel-controls a", "\"ArrowLeft\"", "\"ArrowRight\"", "\"Home\"", "\"End\"", "\"aria-current\"", "event.preventDefault();"}) {
		testing.expectf(t, strings.contains(script, part), "the script of the carousel has no %q", part)
	}
	for refused in ([]string{"setInterval", "setTimeout", "requestAnimationFrame", "autoplay", "smooth", ".style", "innerHTML", "fetch(", "XMLHttpRequest", "localStorage", "sessionStorage"}) {
		testing.expectf(t, !strings.contains(script, refused), "the script of the carousel holds %q", refused)
	}
	// The script is a file of the site whose address carries its version.
	versioned := SITE_VERSIONED_FILES
	listed := false
	for file in versioned {
		listed ||= file == SITE_CAROUSEL_SCRIPT
	}
	testing.expect(t, listed, "the script of the carousel has no file version")
}
