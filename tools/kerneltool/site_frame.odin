// kerneltool site: the site of the system, as static files in build/site
// (docs/SITE.md). The site is the documentation of the system: the home is
// its front door, the guides are the documents of docs/, the reference is
// tables that the tool generates from the code. Each page is generated
// from files of the repository and from the logs of the last machine tests;
// no page holds a text that a person must remember to update.
//
// This file holds the record of the site, the command, the frame of every
// page (the bar, the breadcrumbs, the foot) and the checks of the pages.
package kerneltool

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

// The address of the site: the pages get canonical addresses, Open Graph,
// a JSON-LD graph and a sitemap from it. An empty address gives a site of
// relative links only. `kerneltool site --address https://...` sets
// another one for one run.
SITE_ADDRESS :: "https://modus.froment.software"
SITE_GLOSSARY_PAGE :: "reference/glossary.html"
SITE_GUIDE_FOLDER :: "guides"
SITE_REFERENCE_FOLDER :: "reference"
// The documents of docs/ that are working records of the project, not
// guides: the site leaves them out.
SITE_WORKING_RECORDS :: [?]string{"HANDOFF.md", "REVIEWS.md"}
SITE_DESCRIPTION_LIMIT :: 160
// The start of the menu of the bar: a details element, closed in the file,
// whose summary is the square button. Its name is a word, hidden by the
// style sheet; with no style sheet the word shows.
SITE_MENU_OPEN :: "<details class=\"bar-menu\">\n<summary class=\"bar-menu-button\"><span class=\"bar-menu-lines\" aria-hidden=\"true\"></span><span class=\"bar-menu-name\">Menu</span></summary>\n<div class=\"bar-menu-content\">\n"

Site_Section :: enum {
	Home,
	Guides,
	Reference,
	Status,
	News,
	Releases,
}

site_section_titles := [Site_Section]string {
	.Home      = "Home",
	.Guides    = "Guides",
	.Reference = "Reference",
	.Status    = "Status",
	.News      = "News",
	.Releases  = "Releases",
}

site_section_pages := [Site_Section]string {
	.Home      = "index.html",
	.Guides    = "guides/index.html",
	.Reference = "reference/index.html",
	.Status    = "status.html",
	.News      = "news.html",
	.Releases  = "releases.html",
}

Site_Crumb :: struct {
	title: string,
	path:  string,
}

Site_Page :: struct {
	path:        string, // From the root of the site: "guides/NETWORK.html".
	title:       string, // The title of the page; the <title> adds the name of the system.
	description: string, // One or two sentences, at most SITE_DESCRIPTION_LIMIT bytes.
	section:     Site_Section,
	crumbs:      []Site_Crumb, // The pages above it, from the home.
	body:        string, // The HTML of the content, from its h1.
	sources:     []string, // The files of the repository that the page comes from.
}

// A guide: a document of docs/ as a page.
Site_Guide :: struct {
	source:   string, // "docs/NETWORK.md"
	path:     string, // "guides/NETWORK.html"
	title:    string,
	about:    string, // Its line in the table of documents of README.md, or "".
	headings: []Site_Heading, // Each heading of its page, with its id: the guide sections of the search index.
}

Site :: struct {
	address:      string,
	author:       string, // The holder of the line "Copyright" of LICENSE, or "".
	commit:       string, // "" when the tool cannot read it.
	release:      string,
	build_time:   string,
	documents:    map[string]string, // A Markdown file ("docs/NETWORK.md" and "NETWORK.md") to its page.
	terms:        []Site_Term,
	not_rendered: [dynamic]string,
	copies:       map[string]string, // A path in the site to the file of the repository that it copies.
	files:        map[string]int, // Each file of the site that is not a page, with its bytes.
	picture_sizes: map[string][2]int, // Each PNG file of the site, with its width and its height.
	pages:        [dynamic]Site_Page,
	guides:       [dynamic]Site_Guide,
	principles:   Site_Principles,
	readme:       Site_Readme,
	step_count:   int,
	changelog:    Changelog,
	measured:     []Site_Measured,
	figures:      []Site_Figure,
	boot_image:   []Site_Image_Entry,
	licenses:     Site_Licenses,
	reference:    Site_Reference,
	code_links:   map[string]string, // The text of a code span to the row of a reference table that it names.
	tile_rules:   string, // The rules of the style sheet for the tiles of the boot image on the home.
	news:         []Site_News, // Newest first.
	gaps:         []Site_Gap, // The gaps of docs/FIRST_MILESTONE.md, as the status page shows them.
}

run_site :: proc(args: []string) -> int {
	address := SITE_ADDRESS
	switch {
	case len(args) == 0:
	case len(args) == 2 && args[0] == "--address" && (strings.has_prefix(args[1], "https://") || strings.has_prefix(args[1], "http://")):
		address = strings.trim_suffix(args[1], "/")
	case:
		fmt.eprintln("kerneltool: site [--address https://<host>/<path>]")
		return EXIT_USAGE
	}
	return site_build(address) ? 0 : EXIT_FAILURE
}

// site_relative gives the link from one page to a path of the site: as many
// "../" as the page has folders, so that the site works from a file, from a
// folder of a host and from the root of a domain.
site_relative :: proc(from_page, target: string) -> string {
	if strings.has_prefix(target, "#") {
		return target
	}
	depth := strings.count(from_page, "/")
	builder := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< depth {
		strings.write_string(&builder, "../")
	}
	strings.write_string(&builder, target)
	return strings.to_string(builder)
}

// site_repository_file gives the address of a file of the repository at the
// commit of the build, or on master when the commit is not known.
site_repository_file :: proc(site: ^Site, path: string) -> string {
	at := site.commit != "" ? site.commit : "master"
	return strings.concatenate({SITE_REPOSITORY_ADDRESS, "/blob/", at, "/", path}, context.temp_allocator)
}

// site_description_cut gives a text of at most SITE_DESCRIPTION_LIMIT bytes,
// cut at a space, with no Markdown marks.
site_description_cut :: proc(text: string) -> string {
	plain, _ := strings.remove_all(text, "`", context.temp_allocator)
	plain, _ = strings.remove_all(plain, "**", context.temp_allocator)
	plain = strings.trim_space(plain)
	if len(plain) <= SITE_DESCRIPTION_LIMIT {
		return plain
	}
	cut := strings.last_index_byte(plain[:SITE_DESCRIPTION_LIMIT - 4], ' ')
	if cut <= 0 {
		cut = SITE_DESCRIPTION_LIMIT - 4
	}
	return strings.concatenate({strings.trim_right(plain[:cut], ",;:"), " ..."}, context.temp_allocator)
}

// site_git_commit reads the commit of the work tree from the files of git,
// with no program: .git is a folder, or a file "gitdir: <folder>" in a
// work tree; HEAD names a reference, which is a file or a line of
// packed-refs in the common folder.
site_git_commit :: proc() -> string {
	read_trimmed :: proc(path: string) -> string {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			return ""
		}
		return strings.trim_space(string(data))
	}
	git_folder := ".git"
	if !os.is_dir(git_folder) {
		pointer := read_trimmed(".git")
		if !strings.has_prefix(pointer, "gitdir: ") {
			return ""
		}
		git_folder = pointer[len("gitdir: "):]
	}
	head := read_trimmed(strings.concatenate({git_folder, "/HEAD"}, context.temp_allocator))
	if !strings.has_prefix(head, "ref: ") {
		return len(head) == 40 ? head : ""
	}
	reference := head[len("ref: "):]
	common := git_folder
	if relative := read_trimmed(strings.concatenate({git_folder, "/commondir"}, context.temp_allocator)); relative != "" {
		common = os.is_absolute_path(relative) ? relative : strings.concatenate({git_folder, "/", relative}, context.temp_allocator)
	}
	for folder in ([]string{git_folder, common}) {
		if commit := read_trimmed(strings.concatenate({folder, "/", reference}, context.temp_allocator)); len(commit) == 40 {
			return commit
		}
	}
	for line in site_lines(read_trimmed(strings.concatenate({common, "/packed-refs"}, context.temp_allocator))) {
		if strings.has_suffix(line, strings.concatenate({" ", reference}, context.temp_allocator)) && len(line) > 40 {
			return line[:40]
		}
	}
	return ""
}

// site_glossary_terms reads the terms of docs/GLOSSARY.md: the first cell
// of each row of each table whose header starts with "| Term |". The
// longest come first, so that "Module metadata" is found before "Module".
site_glossary_terms :: proc(content: string) -> []Site_Term {
	terms := make([dynamic]Site_Term, context.temp_allocator)
	in_terms := false
	row := 0
	for line in site_lines(content) {
		if !strings.has_prefix(line, "|") {
			in_terms = false
			continue
		}
		cells := site_table_row_cells(line)
		if !in_terms {
			in_terms = len(cells) > 0 && cells[0] == "Term"
			row = 0
			continue
		}
		row += 1
		if row == 1 || len(cells) == 0 {
			continue // The line of dashes.
		}
		name := site_term_name(cells[0])
		if len(name) >= 3 {
			definition := len(cells) > 1 ? cells[1] : ""
			append(&terms, Site_Term{name = name, id = strings.concatenate({"term-", site_slug(name)}, context.temp_allocator), definition = definition})
		}
	}
	slice.sort_by(terms[:], proc(a, b: Site_Term) -> bool {return len(a.name) > len(b.name)})
	return terms[:]
}

// site_write_file writes one file of the site, and records it.
site_write_file :: proc(site: ^Site, path: string, data: []u8) -> bool {
	target := strings.concatenate({SITE_FOLDER, "/", path}, context.temp_allocator)
	if folder := strings.last_index_byte(target, '/'); folder > 0 {
		make_folder(target[:folder]) or_return
	}
	if err := os.write_entire_file(target, data); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", target, err)
		return false
	}
	site.files[path] = len(data)
	if width, height, is_png := site_png_size(data); is_png {
		site.picture_sizes[path] = {width, height}
	}
	return true
}

site_build :: proc(address: string) -> bool {
	site: Site
	site.address = address
	site.documents = make(map[string]string, context.temp_allocator)
	site.not_rendered = make([dynamic]string, context.temp_allocator)
	site.copies = make(map[string]string, context.temp_allocator)
	site.files = make(map[string]int, context.temp_allocator)
	site.picture_sizes = make(map[string][2]int, context.temp_allocator)
	site.pages = make([dynamic]Site_Page, context.temp_allocator)
	site.guides = make([dynamic]Site_Guide, context.temp_allocator)

	properties_text := site_read(SITE_PROPERTIES_FILE) or_return
	readme_text := site_read(SITE_README_FILE) or_return
	reviews_text := site_read(SITE_REVIEWS_FILE) or_return
	glossary_text := site_read("docs/GLOSSARY.md") or_return
	properties_problem, readme_problem, reviews_problem: string
	site.principles, properties_problem = site_properties_parse(properties_text)
	site.readme, readme_problem = site_readme_parse(readme_text)
	site.step_count, reviews_problem = site_reviews_step_count(reviews_text)
	for problem in ([]string{properties_problem, readme_problem, reviews_problem}) {
		if problem != "" {
			fmt.eprintfln("kerneltool: site: %s", problem)
			return false
		}
	}
	changelog_problems := make([dynamic]string, context.temp_allocator)
	changelog_ok: bool
	site.changelog, changelog_ok = changelog_read(&changelog_problems)
	if !changelog_ok || len(changelog_problems) > 0 || len(site.changelog.releases) == 0 {
		problems_print(changelog_problems[:])
		fmt.eprintfln("kerneltool: site: %s does not have its form; `kerneltool changelog check` says the same", CHANGELOG_FILE)
		return false
	}
	site.release = release_number_text(site.changelog.releases[0].number)
	// The news names releases of the changelog, pictures and guides.
	site_news_read(&site) or_return
	site.commit = site_git_commit()
	now := time.now()
	year, month, day := time.date(now)
	hour, minute, _ := time.clock(now)
	site.build_time = fmt.tprintf("%04d-%02d-%02d %02d:%02d UTC", year, int(month), day, hour, minute)

	// The guides: each document of docs/ but the working records. The
	// glossary is a page of the reference.
	document_paths := files_with_suffix("docs", ".md") or_return
	for path in document_paths {
		name := site_file_name(path)
		working := false
		records := SITE_WORKING_RECORDS
		for record in records {
			working ||= name == record
		}
		if working {
			continue
		}
		page := name == "GLOSSARY.md" ? SITE_GLOSSARY_PAGE : strings.concatenate({SITE_GUIDE_FOLDER, "/", name[:len(name) - len(".md")], ".html"}, context.temp_allocator)
		site.documents[path] = page
		site.documents[name] = page
	}
	site.terms = site_glossary_terms(glossary_text)
	// The sources of the reference tables are read before any guide is
	// rendered: a code span of a guide links to their rows.
	site_reference_read(&site) or_return

	if !reset_folder(SITE_FOLDER) {
		return false
	}
	// The pictures of the mark, and the icons: the heron alone of resources/logo.
	for picture in site_mark_pictures {
		data := site_mark_encode(picture) or_return
		if picture.file_name == SITE_MARK_CARD {
			// Other sites show the card on any background and at this size.
			width, height, _ := site_png_size(data)
			if width != SITE_CARD_WIDTH || height != SITE_CARD_HEIGHT || !site_png_is_opaque(data) {
				fmt.eprintfln("kerneltool: site: %s is %d by %d or not opaque; the picture for other sites is opaque, %d by %d", picture.file_name, width, height, SITE_CARD_WIDTH, SITE_CARD_HEIGHT)
				return false
			}
		}
		site_write_file(&site, strings.concatenate({SITE_PICTURE_FOLDER, "/", picture.file_name}, context.temp_allocator), data) or_return
	}
	// The icons, drawn from the table of the heron (site_icons.odin):
	// favicon.ico at the root, where a browser asks for it by default, and
	// the others in the picture folder. The check of the icons reads them.
	icon_files, icons_ok := site_icon_files()
	if !icons_ok {
		fmt.eprintfln("kerneltool: site: cannot draw the icons or write %s", SITE_FAVICON)
		return false
	}
	for icon_path, icon_data in icon_files {
		site_write_file(&site, icon_path, icon_data) or_return
	}

	// The pictures of the machine, with the captions of README.md.
	figures := make([dynamic]Site_Figure, context.temp_allocator)
	for picture in site_pictures {
		caption, has_caption := site.readme.captions[picture.path]
		if !has_caption || caption == "" {
			fmt.eprintfln("kerneltool: site: the picture %s has no caption in %s (a line \"![<caption>](<path>)\")", picture.path, SITE_README_FILE)
			return false
		}
		data := read_file(picture.path) or_return
		width, height, is_png := site_png_size(data)
		if !is_png {
			fmt.eprintfln("kerneltool: site: %s is not a PNG file", picture.path)
			return false
		}
		file_name := site_file_name(picture.path)
		site.copies[strings.concatenate({SITE_PICTURE_FOLDER, "/", file_name}, context.temp_allocator)] = picture.path
		append(&figures, Site_Figure{group = picture.group, file_name = file_name, caption = caption, width = width, height = height})
	}
	site.figures = figures[:]

	measured := make([dynamic]Site_Measured, context.temp_allocator)
	for measure in site_measures {
		append(&measured, site_measure_read(measure))
	}
	site.measured = measured[:]
	image_problem: string
	site.boot_image, image_problem = site_boot_image_read(BOOT_IMAGE)
	if image_problem != "" {
		fmt.eprintfln("kerneltool: site: %s", image_problem)
		return false
	}
	licenses_ok: bool
	site.licenses, licenses_ok = site_licenses_read(site.boot_image, site.release)
	if !licenses_ok {
		return false
	}
	// The author: the holder of the line "Copyright" of LICENSE, the one
	// fact of an author that the repository holds.
	if len(site.licenses.system_rows) > 0 {
		site.author = site_copyright_holder(site.licenses.system_rows[0].author)
	}

	// The pages.
	site_guides_add(&site) or_return
	site_reference_add(&site) or_return
	site_status_add(&site) or_return
	site_news_add(&site)
	site_releases_add(&site)
	site_home_add(&site)
	if len(site.news) > 0 {
		// The feed is written before the checks: each page links to it.
		site_write_file(&site, SITE_NEWS_FEED, transmute([]u8)site_news_feed(&site)) or_return
	}
	// The files that each page names in its head, or that other programs
	// read with no address: written before the checks of the links.
	site_write_file(&site, SITE_RELEASES_FEED, transmute([]u8)site_releases_feed(&site)) or_return
	manifest := site_manifest(&site)
	site_write_file(&site, SITE_MANIFEST, transmute([]u8)manifest) or_return
	site_write_file(&site, SITE_LANGUAGE_MODEL_INDEX, transmute([]u8)site_language_model_index(&site)) or_return

	// The copies: the pictures of the machine and of the guides, the icons.
	// A picture of the repository can be stored with no compression (the
	// screen pictures of docs/screenshots are): each PNG file is written
	// again with the same pixels through the compressing encoder.
	source_picture_bytes, written_picture_bytes, picture_count := 0, 0, 0
	for target, source in site.copies {
		data := read_file(source) or_return
		if strings.has_suffix(target, ".png") {
			compressed, compressed_ok := site_png_compress(data)
			if !compressed_ok {
				fmt.eprintfln("kerneltool: site: %s is not a PNG file of 8 bits a channel that the encoder can write again", source)
				return false
			}
			source_picture_bytes += len(data)
			written_picture_bytes += len(compressed)
			picture_count += 1
			data = compressed
		}
		site_write_file(&site, target, data) or_return
	}
	site_write_file(&site, SITE_STYLE_SHEET, transmute([]u8)site_style_sheet(site.tile_rules)) or_return
	site_write_file(&site, SITE_SEARCH_SCRIPT, transmute([]u8)site_search_script()) or_return

	written := make(map[string]string, context.temp_allocator)
	for page in site.pages {
		written[page.path] = site_page_html(&site, page)
	}
	problems := site_check_pages(site.pages[:], written, site.files)
	if len(problems) > 0 {
		for problem in problems {
			fmt.eprintfln("kerneltool: site: %s", problem)
		}
		fmt.eprintfln("kerneltool: site: %d problems; no page is written", len(problems))
		return false
	}
	// What other programs read: with an address, the canonical addresses,
	// Open Graph, the JSON-LD graphs and the sitemap; with none, their
	// absence.
	sitemap := site.address != "" ? site_sitemap(&site) : ""
	metadata_problems := make([dynamic]string, context.temp_allocator)
	append(&metadata_problems, ..site_check_metadata(site.address, site.pages[:], written, sitemap, site.picture_sizes))
	// The icons: favicon.ico at the root, each icon of the heads and of the
	// manifest with its stated size, the icons of a phone opaque.
	append(&metadata_problems, ..site_icon_problems(site.pages[:], written, manifest, icon_files))
	if len(metadata_problems) > 0 {
		for problem in metadata_problems {
			fmt.eprintfln("kerneltool: site: %s", problem)
		}
		fmt.eprintfln("kerneltool: site: %d problems of what other sites read; no page is written", len(metadata_problems))
		return false
	}
	// The index of the search, from the same data as the pages, checked
	// against the pages that the command writes.
	search_entries := site_search_entries(&site)
	search_index := site_search_index_json(search_entries, site.pages[:])
	search_problems := site_search_problems(search_entries, written)
	if len(search_index) > SITE_SEARCH_INDEX_BYTE_LIMIT {
		fmt.eprintfln("kerneltool: site: %s has %d bytes; at most %d", SITE_SEARCH_INDEX, len(search_index), SITE_SEARCH_INDEX_BYTE_LIMIT)
		return false
	}
	if len(search_problems) > 0 {
		for problem in search_problems {
			fmt.eprintfln("kerneltool: site: %s", problem)
		}
		fmt.eprintfln("kerneltool: site: %d problems of the search index; no page is written", len(search_problems))
		return false
	}
	site_write_file(&site, SITE_SEARCH_INDEX, transmute([]u8)search_index) or_return
	if site.address != "" {
		site_write_file(&site, SITE_SITEMAP, transmute([]u8)sitemap) or_return
		site_write_file(&site, SITE_ROBOTS, transmute([]u8)site_robots(&site)) or_return
	}
	page_bytes := 0
	for path, html in written {
		site_write_file(&site, path, transmute([]u8)html) or_return
		page_bytes += len(html)
	}

	fmt.printfln("kerneltool: site: wrote %s: %d pages (%d bytes), %d other files", SITE_FOLDER, len(site.pages), page_bytes, len(site.files) - len(site.pages))
	fmt.printfln("kerneltool: site: %s: %d entries of at most %d, %d bytes of at most %d; %s: %d bytes", SITE_SEARCH_INDEX, len(search_entries), SITE_SEARCH_ENTRY_LIMIT, len(search_index), SITE_SEARCH_INDEX_BYTE_LIMIT, SITE_SEARCH_SCRIPT, site.files[SITE_SEARCH_SCRIPT])
	commit_text: string = site.commit != "" ? site.commit : "not readable (links to files go to master)"
	fmt.printfln("kerneltool: site: %d guides, %d terms of the glossary, %d news entries, the commit %s, the release %s", len(site.guides), len(site.terms), len(site.news), commit_text, site.release)
	if site.address == "" {
		fmt.println("kerneltool: site: no address (SITE_ADDRESS is empty): the pages have relative links only. Not written: the canonical addresses, Open Graph and the summary card, the JSON-LD graphs, " + SITE_SITEMAP + ", " + SITE_ROBOTS + ", and the link \"self\" of the feeds")
		fmt.printfln("kerneltool: site: %s, %s and %s have relative links: a reader resolves them against the address that it fetched the file from", SITE_NEWS_FEED, SITE_RELEASES_FEED, SITE_LANGUAGE_MODEL_INDEX)
	} else {
		fmt.printfln("kerneltool: site: the address %s: a canonical address, Open Graph and a JSON-LD graph on each page; %s with %d pages; %s; the link \"self\" of %s and %s", site.address, SITE_SITEMAP, len(site.pages), SITE_ROBOTS, SITE_NEWS_FEED, SITE_RELEASES_FEED)
		// A crawler reads robots.txt only at the root of a host.
		after_scheme := site.address[strings.index(site.address, "://") + 3:]
		if strings.contains(after_scheme, "/") {
			fmt.printfln("kerneltool: site: the site is in a folder of its host: a crawler does not read %s there; the %s of the root of the host must have the line \"Sitemap: %s/%s\"", SITE_ROBOTS, SITE_ROBOTS, site.address, SITE_SITEMAP)
		}
	}
	fmt.printfln("kerneltool: site: %d pictures of the repository, compressed: %d bytes, from %d bytes of their files", picture_count, written_picture_bytes, source_picture_bytes)
	missing := 0
	for number in site.measured {
		if !number.found {
			missing += 1
			fmt.printfln("kerneltool: site: not measured in this build: %s (%s)", number.measure.sentence, number.missing)
		}
	}
	fmt.printfln("kerneltool: site: %d of %d numbers measured", len(site.measured) - missing, len(site.measured))
	for cell in site.licenses.gaps {
		fmt.printfln("kerneltool: site: a cell of the licenses is not recorded: %s", cell)
	}
	for item in site.not_rendered {
		fmt.printfln("kerneltool: site: not rendered as Markdown: %s", item)
	}
	return true
}

// site_page_add records a page.
site_page_add :: proc(site: ^Site, page: Site_Page) {
	append(&site.pages, page)
}

site_page_exists :: proc(site: ^Site, path: string) -> bool {
	for page in site.pages {
		if page.path == path {
			return true
		}
	}
	return false
}

// site_page_html writes a whole page: the head, the bar, the breadcrumbs,
// the content and the foot.
site_page_html :: proc(site: ^Site, page: Site_Page) -> string {
	b := strings.builder_make(context.temp_allocator)
	write :: proc(builder: ^strings.Builder, text: string) {
		strings.write_string(builder, text)
	}
	link :: proc(page: Site_Page, target: string) -> string {
		return site_relative(page.path, target)
	}
	write(&b, "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>")
	site_escape(&b, page.title)
	if page.section != .Home {
		write(&b, " - " + SITE_SYSTEM_NAME)
	}
	write(&b, "</title>\n<meta name=\"description\" content=\"")
	site_escape(&b, page.description)
	write(&b, "\">\n<meta name=\"color-scheme\" content=\"dark light\">\n")
	fmt.sbprintf(&b, "<meta name=\"theme-color\" media=\"(prefers-color-scheme: dark)\" content=\"%s\">\n", site_color(site_dark_colors().background))
	fmt.sbprintf(&b, "<meta name=\"theme-color\" media=\"(prefers-color-scheme: light)\" content=\"%s\">\n", site_color(site_light_colors().background))
	// The icons, in the order that lets an old browser take the ICO and a
	// new one the SVG; all links are relative, as every link of the site.
	fmt.sbprintf(&b, "<link rel=\"icon\" href=\"%s\" sizes=\"32x32\">\n", link(page, SITE_FAVICON))
	fmt.sbprintf(&b, "<link rel=\"icon\" href=\"%s\" type=\"image/svg+xml\">\n", link(page, SITE_PICTURE_FOLDER + "/" + SITE_ICON_SVG))
	fmt.sbprintf(&b, "<link rel=\"apple-touch-icon\" href=\"%s\" sizes=\"180x180\">\n", link(page, SITE_PICTURE_FOLDER + "/" + SITE_ICON_TOUCH))
	if site_page_exists(site, site_section_pages[.News]) {
		fmt.sbprintf(&b, "<link rel=\"alternate\" type=\"application/atom+xml\" title=\"News of %s\" href=\"%s\">\n", SITE_SYSTEM_NAME, link(page, SITE_NEWS_FEED))
	}
	// The feed of the releases, the manifest, the guides before and after;
	// with an address, the canonical address, Open Graph and JSON-LD.
	site_head_metadata(site, page, &b)
	section_name := strings.to_lower(site_section_titles[page.section], context.temp_allocator)
	fmt.sbprintf(&b, "<link rel=\"stylesheet\" href=\"%s\">\n", link(page, SITE_STYLE_SHEET))
	// The one script of the site: the search. Each page is whole with no script.
	fmt.sbprintf(&b, "<script src=\"%s\" defer></script>\n</head>\n<body class=\"section-%s\">\n", link(page, SITE_SEARCH_SCRIPT), section_name)
	write(&b, "<a class=\"skip\" href=\"#content\">Skip to the content</a>\n")

	// The bar: the heron and the name at the left, the sections as buttons.
	write(&b, "<header class=\"bar\">\n<div class=\"bar-inner\">\n")
	fmt.sbprintf(&b, "<a class=\"bar-home\" href=\"%s\"><picture><source media=\"(prefers-color-scheme: light)\" srcset=\"%s\">", link(page, "index.html"), link(page, SITE_PICTURE_FOLDER + "/" + SITE_MARK_BAR_LIGHT))
	fmt.sbprintf(&b, "<img src=\"%s\" width=\"24\" height=\"24\" alt=\"\"></picture><span>%s</span></a>\n", link(page, SITE_PICTURE_FOLDER + "/" + SITE_MARK_BAR), SITE_SYSTEM_NAME)
	// The sections and the search are in one menu: one list of links for
	// every width. Under 720 pixels the menu is a square button; on a wide
	// screen the style sheet and the script show it open, as a bar
	// (docs/SITE.md, "The site menu").
	write(&b, SITE_MENU_OPEN)
	write(&b, "<nav aria-label=\"Sections\">\n<ul>\n")
	for section in Site_Section {
		if section == .Home || !site_page_exists(site, site_section_pages[section]) {
			continue
		}
		current: string = section == page.section ? " aria-current=\"page\"" : ""
		fmt.sbprintf(&b, "<li><a href=\"%s\"%s>%s</a></li>\n", link(page, site_section_pages[section]), current, site_section_titles[section])
	}
	write(&b, "</ul>\n</nav>\n")
	write(&b, SITE_SEARCH_BOX)
	write(&b, "</div>\n</details>\n</div>\n</header>\n")

	if len(page.crumbs) > 0 {
		write(&b, "<nav class=\"crumbs page\" aria-label=\"Breadcrumbs\">\n<ol>\n")
		for crumb in page.crumbs {
			fmt.sbprintf(&b, "<li><a href=\"%s\">", link(page, crumb.path))
			site_escape(&b, crumb.title)
			write(&b, "</a></li>\n")
		}
		write(&b, "<li aria-current=\"page\">")
		site_escape(&b, page.title)
		write(&b, "</li>\n</ol>\n</nav>\n")
	}
	fmt.sbprintf(&b, "<main id=\"content\" class=\"page page-%s\">\n", section_name)
	write(&b, page.body)
	write(&b, "</main>\n")

	// The foot: the build that the page comes from, and its sources.
	write(&b, "<footer class=\"foot\">\n<div class=\"page\">\n<p>Generated by <code>kerneltool site</code> from ")
	if site.commit != "" {
		fmt.sbprintf(&b, "the commit <a href=\"%s/commit/%s\"><code>%s</code></a>", SITE_REPOSITORY_ADDRESS, site.commit, site.commit[:12])
	} else {
		write(&b, "a work tree whose commit the tool cannot read")
	}
	fmt.sbprintf(&b, ", at the release <a href=\"%s#%s\">%s</a>, on %s.</p>\n", link(page, site_section_pages[.Releases]), site_release_id(site.release), site.release, site.build_time)
	if len(page.sources) > 0 {
		write(&b, "<p>Generated from: ")
		for source, index in page.sources {
			if index > 0 {
				write(&b, ", ")
			}
			write(&b, "<a href=\"")
			site_escape(&b, site_repository_file(site, source))
			write(&b, "\"><code>")
			site_escape(&b, source)
			write(&b, "</code></a>")
		}
		write(&b, ".</p>\n")
	}
	fmt.sbprintf(&b, "<p><a href=\"%s\">The repository</a> - <a href=\"%s\">Licenses</a></p>\n</div>\n</footer>\n</body>\n</html>\n", SITE_REPOSITORY_ADDRESS, link(page, "reference/licenses.html"))
	return strings.to_string(b)
}

// site_release_id gives the anchor of a release on the page of the releases.
site_release_id :: proc(release_number: string) -> string {
	return strings.concatenate({"release-", site_slug(release_number)}, context.temp_allocator)
}

// site_attribute_values gives each value of an attribute in the HTML of a
// page ("href=\"" gives each address).
site_attribute_values :: proc(html, attribute: string) -> []string {
	values := make([dynamic]string, context.temp_allocator)
	rest := html
	for {
		start := strings.index(rest, attribute)
		if start < 0 {
			break
		}
		// Not the end of another attribute name: "data-href" is not "href".
		before := len(html) - len(rest) + start - 1
		rest = rest[start + len(attribute):]
		end := strings.index_byte(rest, '"')
		if end < 0 {
			append(&values, "\x00") // An attribute with no closing quote.
			break
		}
		if before < 0 || html[before] == ' ' || html[before] == '\n' {
			append(&values, rest[:end])
		}
		rest = rest[end + 1:]
	}
	return values[:]
}

// site_check_pages checks the pages before any is written:
//   each page has one h1, a title and a description, and no two pages share
//   a title or a description;
//   each img has an alt attribute (empty for a picture that only decorates
//   a text beside it), a width and a height;
//   each href, src and srcset that is not an address of another host names
//   a page or a file of the site, and its anchor is an id of that page.
site_check_pages :: proc(pages: []Site_Page, written: map[string]string, files: map[string]int) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	ids := make(map[string]map[string]bool, context.temp_allocator)
	for path, html in written {
		page_ids := make(map[string]bool, context.temp_allocator)
		for id in site_attribute_values(html, "id=\"") {
			page_ids[id] = true
		}
		ids[path] = page_ids
	}
	titles := make(map[string]string, context.temp_allocator)
	descriptions := make(map[string]string, context.temp_allocator)
	for page in pages {
		html := written[page.path]
		if count := strings.count(html, "<h1"); count != 1 {
			append(&problems, fmt.tprintf("%s: %d headings h1; a page has one", page.path, count))
		}
		if page.title == "" || page.description == "" {
			append(&problems, fmt.tprintf("%s: no title or no description", page.path))
		}
		if len(page.description) > SITE_DESCRIPTION_LIMIT {
			append(&problems, fmt.tprintf("%s: the description has %d bytes; at most %d", page.path, len(page.description), SITE_DESCRIPTION_LIMIT))
		}
		if other, found := titles[page.title]; found {
			append(&problems, fmt.tprintf("%s: the title \"%s\" is also the title of %s", page.path, page.title, other))
		}
		titles[page.title] = page.path
		if other, found := descriptions[page.description]; found {
			append(&problems, fmt.tprintf("%s: the description is also the description of %s", page.path, other))
		}
		descriptions[page.description] = page.path
		rest := html
		for {
			start := strings.index(rest, "<img ")
			if start < 0 {
				break
			}
			end := strings.index_byte(rest[start:], '>')
			if end < 0 {
				break
			}
			tag := rest[start:start + end]
			if !strings.contains(tag, " alt=\"") || !strings.contains(tag, " width=\"") || !strings.contains(tag, " height=\"") {
				append(&problems, fmt.tprintf("%s: a picture has no alt, no width or no height: %s", page.path, tag))
			}
			rest = rest[start + end:]
		}
		if problem := site_inline_code_problem(html); problem != "" {
			append(&problems, fmt.tprintf("%s: %s", page.path, problem))
		}
		folder := page.path[:max(strings.last_index_byte(page.path, '/'), 0)]
		for attribute in ([]string{"href=\"", "src=\"", "srcset=\""}) {
			for value in site_attribute_values(html, attribute) {
				// A srcset has several candidates: "<file> <width>w, ...".
				candidates := []string{value}
				if attribute == "srcset=\"" {
					candidates = strings.split(value, ",", context.temp_allocator)
				}
				for candidate in candidates {
					problem := site_link_problem(page.path, folder, strings.trim_space(candidate), written, files, ids)
					if problem != "" {
						append(&problems, fmt.tprintf("%s: %s%s\": %s", page.path, attribute, value, problem))
					}
				}
			}
		}
	}
	return problems[:]
}

// site_inline_code_problem gives the fault of a page that holds code or
// style of its own, or "": each script is a file (<script src="..."></script>
// with nothing inside), and no style element or style attribute exists.
// A policy of the host can then forbid inline code (docs/SITE.md, "What the
// owner must decide"). The text of a page is escaped, so its words never
// read as these tags.
site_inline_code_problem :: proc(html: string) -> string {
	if strings.contains(html, "<style") {
		return "a style element; the rules are in the style sheet"
	}
	if len(site_attribute_values(html, "style=\"")) > 0 {
		return "a style attribute; the rules are in the style sheet"
	}
	rest := html
	for {
		start := strings.index(rest, "<script")
		if start < 0 {
			break
		}
		rest = rest[start:]
		end := strings.index_byte(rest, '>')
		if end < 0 {
			return "a script with code in the page; a script is a file of the site"
		}
		// The one script element with text inside: the JSON-LD graph, data
		// that a browser does not run. Its text has no "<", so it cannot end
		// the element or open another one.
		if rest[:end + 1] == SITE_STRUCTURED_DATA_OPEN {
			inside := rest[end + 1:]
			close_index := strings.index(inside, SITE_SCRIPT_CLOSE)
			if close_index < 0 || strings.contains(inside[:close_index], "<") {
				return "a JSON-LD script with markup inside or with no end"
			}
			rest = inside[close_index + len(SITE_SCRIPT_CLOSE):]
			continue
		}
		if !strings.contains(rest[:end], " src=\"") || !strings.has_prefix(rest[end + 1:], SITE_SCRIPT_CLOSE) {
			return "a script with code in the page; a script is a file of the site"
		}
		rest = rest[end + 1:]
	}
	return ""
}

// site_link_problem checks one link of a page, or gives "".
site_link_problem :: proc(page_path, folder, value: string, written: map[string]string, files: map[string]int, ids: map[string]map[string]bool) -> string {
	if value == "\x00" {
		return "no closing quote"
	}
	if value == "" {
		return "empty"
	}
	if strings.has_prefix(value, "https://") || strings.has_prefix(value, "http://") {
		return "" // The address of another host: not a file of the site.
	}
	address := value
	if space := strings.index_byte(address, ' '); space >= 0 {
		address = address[:space] // A srcset: "<file> <width>w".
	}
	anchor := ""
	if hash := strings.index_byte(address, '#'); hash >= 0 {
		anchor = address[hash + 1:]
		address = address[:hash]
	}
	target := page_path
	if address != "" {
		target = site_path_join(folder, address)
	}
	_, is_page := written[target]
	_, is_file := files[target]
	if !is_page && !is_file {
		return fmt.tprintf("names %s, which the command did not write", target)
	}
	if anchor != "" {
		if !is_page {
			return "an anchor in a file that is not a page"
		}
		if anchor not_in ids[target] {
			return fmt.tprintf("%s has no id \"%s\"", target, anchor)
		}
	}
	return ""
}
