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
// The folder of the docs: its home, and its two parts, the guides and the
// reference. Every path of a page of the docs starts here, so that one
// change of these lines moves the whole docs (docs/SITE.md, "The
// addresses of the pages").
SITE_DOCS_FOLDER :: "docs"
SITE_GUIDE_FOLDER :: SITE_DOCS_FOLDER + "/guides"
SITE_REFERENCE_FOLDER :: SITE_DOCS_FOLDER + "/reference"
// The folders of the pages of the reference that the tool writes by
// itself; the pages of the generated tables are in site_reference.odin.
SITE_GLOSSARY_FOLDER :: SITE_REFERENCE_FOLDER + "/glossary"
SITE_COMMANDS_FOLDER :: SITE_REFERENCE_FOLDER + "/commands"
SITE_NUMBERS_FOLDER :: SITE_REFERENCE_FOLDER + "/numbers"
SITE_LICENSES_FOLDER :: SITE_REFERENCE_FOLDER + "/licenses"
// The folders of the sections that are not docs: the table of the search
// kinds names them too.
SITE_STATUS_FOLDER :: "status"
SITE_NEWS_FOLDER :: "news"
SITE_RELEASES_FOLDER :: "releases"
// The documents of docs/ that are working records of the project, not
// guides: the site leaves them out. A link of a page to one of them names
// the file in the repository.
SITE_WORKING_RECORDS :: [?]string{"HANDOFF.md", "REVIEWS.md", "SITE.md", "FIRST_MILESTONE.md", "DECISIONS.md"}
SITE_DESCRIPTION_LIMIT :: 160
// The start of the refresh of a redirect page; the link to the new address
// follows it.
SITE_REFRESH_OPEN :: "<meta http-equiv=\"refresh\" content=\"0; url="
// The start of the menu of the bar: a details element, closed in the file,
// whose summary is the square button. Its name is a word, hidden by the
// style sheet; with no style sheet the word shows.
SITE_MENU_OPEN :: "<details class=\"bar-menu\">\n<summary class=\"bar-menu-button\"><span class=\"bar-menu-lines\" aria-hidden=\"true\"></span><span class=\"bar-menu-name\">Menu</span></summary>\n<div class=\"bar-menu-content\">\n"

// The sections of the site. The guides and the reference are the two parts
// of the docs: the bar names the docs, and their pages are under its folder.
Site_Section :: enum {
	Home,
	Docs,
	Guides,
	Reference,
	Status,
	News,
	Releases,
}

site_section_titles := [Site_Section]string {
	.Home      = "Home",
	.Docs      = "Docs",
	.Guides    = "Guides",
	.Reference = "Reference",
	.Status    = "Status",
	.News      = "News",
	.Releases  = "Releases",
}

// The folder of the page of each section; "" is the root of the site.
site_section_folders := [Site_Section]string {
	.Home      = "",
	.Docs      = SITE_DOCS_FOLDER,
	.Guides    = SITE_GUIDE_FOLDER,
	.Reference = SITE_REFERENCE_FOLDER,
	.Status    = SITE_STATUS_FOLDER,
	.News      = SITE_NEWS_FOLDER,
	.Releases  = SITE_RELEASES_FOLDER,
}

// The section above each section: the breadcrumbs follow it, and the bar
// shows only the sections whose parent is the home. The status stays a
// section of its own: it reports the state of the properties, not how the
// system works.
site_section_parents := [Site_Section]Site_Section {
	.Home      = .Home,
	.Docs      = .Home,
	.Guides    = .Docs,
	.Reference = .Docs,
	.Status    = .Home,
	.News      = .Home,
	.Releases  = .Home,
}

// site_section_page gives the file of the page of a section.
site_section_page :: proc(section: Site_Section) -> string {
	return site_page_file(site_section_folders[section])
}

// site_section_in_bar tells whether the bar and the doors of the home name
// a section: a section right under the home.
site_section_in_bar :: proc(section: Site_Section) -> bool {
	return section != .Home && site_section_parents[section] == .Home
}

// site_bar_section gives the section of the bar that holds a section: the
// docs for a guide or a page of the reference.
site_bar_section :: proc(section: Site_Section) -> Site_Section {
	current := section
	for current != .Home && site_section_parents[current] != .Home {
		current = site_section_parents[current]
	}
	return current
}

Site_Crumb :: struct {
	title: string,
	path:  string,
}

Site_Page :: struct {
	path:        string, // The file, from the root of the site: "docs/guides/NETWORK/index.html" (site_page_file).
	title:       string, // The title of the page; the <title> adds the name of the system.
	description: string, // One or two sentences, at most SITE_DESCRIPTION_LIMIT bytes.
	section:     Site_Section,
	crumbs:      []Site_Crumb, // The pages above it, from the home.
	body:        string, // The HTML of the content, from its h1.
	sources:     []string, // The files of the repository that the page comes from.
	is_index:    bool, // An index page: it lists the pages of its folder (the home, the docs, the guides, the reference, the modules).
	layout:      Site_Layout, // Stated by the writer of the page: one centred column, or the three columns of the documentation.
	// The page holds its own search field (the home of the docs), so the
	// bar has none: a page has one search field.
	search_in_page: bool,
	// A script of this page alone, a file of the site, or "". The page is
	// whole without it.
	script: string,
}

// A guide: a document of docs/ as a page.
Site_Guide :: struct {
	source:   string, // "docs/NETWORK.md"
	path:     string, // "docs/guides/NETWORK/index.html"
	title:    string,
	about:    string, // Its line in the table of documents of README.md, or "".
	headings: []Site_Heading, // Each heading of its page, with its id: the guide sections of the search index.
	items:    []Site_List_Item, // Each top-level item of an ordered list of its page, with its id: a reference to "choice <n>" finds it.
}

Site :: struct {
	address:      string,
	author:       string, // The holder of the line "Copyright" of LICENSE, or "".
	commit:       string, // "" when the tool cannot read it.
	release:      string,
	build_time:   string,
	documents:    map[string]string, // A Markdown file ("docs/NETWORK.md" and "NETWORK.md") to its page.
	glossary:     Glossary, // docs/GLOSSARY.md, as glossary_read gives it.
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
	measure_record: Site_Measure_Record, // The measure record of the work tree.
	boot_stages:  []Site_Boot_Stage, // The stages of the start that the home shows.
	boot_source:  Site_Measure_Source,
	figures:      []Site_Figure,
	boot_image:   []Site_Image_Entry,
	licenses:     Site_Licenses,
	reference:    Site_Reference,
	code_links:   map[string]string, // The text of a code span to the row of a reference table that it names.
	tile_rules:   string, // The rules of the style sheet for the tiles of the boot image on the home.
	news:         []Site_News, // Newest first.
	gaps:         []Site_Gap, // The gaps of docs/FIRST_MILESTONE.md, as the status page shows them.
	redirects:    map[string]string, // The HTML of each redirect page, by its old path.
	redirect_counts: [Site_Address_Generation]int, // The redirect pages of each generation of old addresses.
	reference_entries: []Site_Reference_Entry, // The pages of the reference, in the order of its index: the tree lists them.
	file_versions: map[string]string, // The version of the bytes of each file of SITE_VERSIONED_FILES that the command wrote.
	symbol_count: int, // The documented symbols of the pages.
	symbols_without_description: int, // The symbols whose source has no comment.
	types:        [dynamic]Site_Type, // Each type that a page can show (docs/SITE.md, "The types").
	type_keys:    map[string]int, // The key of each type ("operation.Fault_Record") to its place in types.
	type_ids:     map[string]int, // The id of each type on the page of the types to its place in types.
	type_names_without_card: int, // The places where a page shows a type that has no card: its name is plain.
	code_blocks_not_colored: int, // The blocks of Odin that the tokenizer refused: written plain.
	first_code_block_not_colored: string, // The place of the first of them, or "".
	// Each pointer to a document that a page shows, by its document and its
	// labels: whether each label found its heading (docs/SITE.md, "The
	// references to documents").
	document_references: map[string]bool,
	document_outlines: map[string]Site_Document_Outline, // The title and the headings of each document that the site reads from its file.
	document_headings_pending: bool, // While the guides are read for their headings only: no reference is counted.
	declarations: Site_Declaration_Index, // Each declaration of the sources of the system (docs/SITE.md, "The declarations of the sources").
	declaration_spans: Site_Declaration_Span_Counts, // What became of the code spans that have the form of a name.
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
// folder of a host and from the root of a domain. A link to a page goes
// through site_page_link, which gives it the form of a link to a page.
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

// site_page_file gives the file of a page: each page is the index.html of
// its own folder, so that its address is the folder ("docs/reference/licenses"
// gives "docs/reference/licenses/index.html"). The folder "" is the root of the
// site, the home. docs/SITE.md, "The addresses of the pages".
site_page_file :: proc(folder: string) -> string {
	if folder == "" {
		return SITE_PAGE
	}
	return strings.concatenate({folder, "/", SITE_PAGE}, context.temp_allocator)
}

// site_page_link gives the link from one page to another page (its file,
// as site_page_file gives it, with an anchor or none). With a site address
// the link names the folder of the page with a final slash: the host
// serves the index.html of a folder, and that is the address that a person
// sees and shares. With no address the link names the index.html: a
// browser that opens the site from a disk shows a folder as a list of its
// files, not as its index.html.
site_page_link :: proc(site: ^Site, from_page, target: string) -> string {
	page_path, anchor := target, ""
	if hash := strings.index_byte(target, '#'); hash >= 0 {
		page_path, anchor = target[:hash], target[hash:]
	}
	if page_path == "" {
		return target // An anchor of the same page.
	}
	link := site_relative(from_page, page_path)
	if site.address != "" {
		if link == SITE_PAGE {
			link = "./"
		} else if strings.has_suffix(link, "/" + SITE_PAGE) {
			link = link[:len(link) - len(SITE_PAGE)]
		}
	}
	return strings.concatenate({link, anchor}, context.temp_allocator)
}

// The generations of the old addresses of the site: each was public, so
// each old address of a page keeps a redirect page to its address of today
// (docs/SITE.md, "The redirect pages").
Site_Address_Generation :: enum {
	// "guides/NETWORK.html": before each page was the index.html of its
	// folder. An index page had the index.html of its folder already.
	Html_Files,
	// "guides/NETWORK/": before the guides and the reference moved under
	// the folder of the docs.
	Folders_Before_Docs,
}

site_address_generation_names := [Site_Address_Generation]string {
	.Html_Files          = "of the .html files",
	.Folders_Before_Docs = "of the folders before " + SITE_DOCS_FOLDER + "/",
}

// One old address of a page, with its generation.
Site_Old_Path :: struct {
	path:       string,
	generation: Site_Address_Generation,
}

// site_old_page_paths gives every old path of a page, by rule from its path
// of today: the folder that it had before the docs (its folder without the
// folder of the docs in front), then the .html file of that folder for a
// page that is not an index page. The home was always the index.html of the
// root, and the home of the docs is new: neither has an old path.
site_old_page_paths :: proc(page: Site_Page) -> []Site_Old_Path {
	paths := make([dynamic]Site_Old_Path, context.temp_allocator)
	if !strings.has_suffix(page.path, "/" + SITE_PAGE) {
		return paths[:]
	}
	folder := page.path[:len(page.path) - len("/" + SITE_PAGE)]
	if folder == SITE_DOCS_FOLDER {
		return paths[:]
	}
	folder_before_docs := folder
	if strings.has_prefix(folder, SITE_DOCS_FOLDER + "/") {
		folder_before_docs = folder[len(SITE_DOCS_FOLDER + "/"):]
		append(&paths, Site_Old_Path{path = site_page_file(folder_before_docs), generation = .Folders_Before_Docs})
	}
	if !page.is_index {
		append(&paths, Site_Old_Path{path = strings.concatenate({folder_before_docs, ".html"}, context.temp_allocator), generation = .Html_Files})
	}
	return paths[:]
}

// site_redirect_html gives the redirect page at the old path of a page: a
// refresh to the new address and one visible link, with no script. With a
// site address it names the new address as its canonical address, so that
// a search engine moves what it knows to it. It is not indexed.
site_redirect_html :: proc(site: ^Site, old_path: string, page: Site_Page) -> string {
	link := site_page_link(site, old_path, page.path)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>")
	site_escape(&b, page.title)
	strings.write_string(&b, " - " + SITE_SYSTEM_NAME + "</title>\n<meta name=\"robots\" content=\"noindex\">\n")
	if site.address != "" {
		strings.write_string(&b, "<link rel=\"canonical\" href=\"")
		site_escape(&b, site_page_address(site.address, page.path))
		strings.write_string(&b, "\">\n")
	}
	strings.write_string(&b, SITE_REFRESH_OPEN)
	site_escape(&b, link)
	strings.write_string(&b, "\">\n</head>\n<body>\n<p>This page is now at <a href=\"")
	site_escape(&b, link)
	strings.write_string(&b, "\">")
	site_escape(&b, page.title)
	strings.write_string(&b, "</a>.</p>\n</body>\n</html>\n")
	return strings.to_string(b)
}

// site_redirects_make writes a redirect page at each old path of each page,
// straight to the page of today: a redirect never names another redirect.
// It gives the problems of the table: two pages with one old path.
site_redirects_make :: proc(site: ^Site) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	site.redirects = make(map[string]string, context.temp_allocator)
	site.redirect_counts = {}
	owners := make(map[string]string, context.temp_allocator)
	for page in site.pages {
		for old in site_old_page_paths(page) {
			if owner, taken := owners[old.path]; taken {
				append(&problems, fmt.tprintf("%s: the old path of two pages, %s and %s", old.path, owner, page.path))
				continue
			}
			owners[old.path] = page.path
			site.redirects[old.path] = site_redirect_html(site, old.path, page)
			site.redirect_counts[old.generation] += 1
		}
	}
	return problems[:]
}

// site_check_redirects checks the redirect pages: no redirect page takes
// the path of a page or of a file of the site, and each one names, in its
// refresh and in each link, a page that the command writes, never another
// redirect page.
site_check_redirects :: proc(redirects: map[string]string, written: map[string]string, files: map[string]int, has_address: bool) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	ids := make(map[string]map[string]bool, context.temp_allocator)
	for path, html in written {
		page_ids := make(map[string]bool, context.temp_allocator)
		for id in site_attribute_values(html, "id=\"") {
			page_ids[id] = true
		}
		ids[path] = page_ids
	}
	for old_path, html in redirects {
		_, is_page := written[old_path]
		_, is_file := files[old_path]
		if is_page || is_file {
			append(&problems, fmt.tprintf("%s: a redirect page has the path of a page or a file of the site", old_path))
			continue
		}
		folder := old_path[:max(strings.last_index_byte(old_path, '/'), 0)]
		start := strings.index(html, SITE_REFRESH_OPEN)
		if start < 0 {
			append(&problems, fmt.tprintf("%s: a redirect page with no refresh", old_path))
			continue
		}
		rest := html[start + len(SITE_REFRESH_OPEN):]
		end := strings.index_byte(rest, '"')
		refresh := end >= 0 ? site_html_unescape(rest[:end]) : "\x00"
		links := make([dynamic]string, context.temp_allocator)
		append(&links, refresh)
		for value in site_attribute_values(html, "href=\"") {
			if strings.has_prefix(value, "https://") || strings.has_prefix(value, "http://") {
				continue // The canonical address: site_page_address of the same page as the refresh.
			}
			append(&links, site_html_unescape(value))
		}
		if len(links) < 2 {
			append(&problems, fmt.tprintf("%s: a redirect page with no visible link", old_path))
		}
		for value in links {
			target, problem := site_link_target(old_path, folder, value, written, files, ids, has_address)
			if problem == "" {
				if _, names_page := written[target]; !names_page {
					problem = fmt.tprintf("names %s, which is not a page", target)
				} else if _, names_redirect := redirects[target]; names_redirect {
					problem = fmt.tprintf("names %s, which is a redirect page", target)
				}
			}
			if problem != "" {
				append(&problems, fmt.tprintf("%s: the redirect to \"%s\": %s", old_path, value, problem))
			}
		}
	}
	return problems[:]
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

// site_glossary_terms gives the terms of the glossary as the pages, the
// search and the page graph use them, with their short definition. The
// longest come first, so that "Module metadata" is found before "Module";
// the sort keeps the order of the file among names of one length. A name of
// two letters is too short to link. A name that the glossary has twice links
// to its first entry. Each term names the page of its group.
site_glossary_terms :: proc(glossary: Glossary) -> []Site_Term {
	terms := make([dynamic]Site_Term, context.temp_allocator)
	names := make(map[string]bool, context.temp_allocator)
	for term in glossary_terms_in_order(glossary) {
		if len(term.name) < 3 {
			continue
		}
		append(&terms, Site_Term{name = term.name, id = term.id, definition = term.definition, page = site_glossary_group_page(term.group_id), second_of_name = term.name in names})
		names[term.name] = true
	}
	slice.stable_sort_by(terms[:], proc(a, b: Site_Term) -> bool {return len(a.name) > len(b.name)})
	return terms[:]
}

// The maker of the system, named in the foot of each page: the name, the
// address of its site, and its mark (a file of the repository, copied).
SITE_MAKER_NAME :: "Froment Software"
SITE_MAKER_ADDRESS :: "https://froment.software"
SITE_MAKER_PICTURE_SOURCE :: "resources/site/froment_software.png"
SITE_MAKER_PICTURE :: "froment_software.png"

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
	versioned := SITE_VERSIONED_FILES
	for file in versioned {
		if file == path {
			if site.file_versions == nil {
				site.file_versions = make(map[string]string, context.temp_allocator)
			}
			site.file_versions[path] = site_bytes_version(data)
		}
	}
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
		page := site_page_file(name == "GLOSSARY.md" ? SITE_GLOSSARY_FOLDER : strings.concatenate({SITE_GUIDE_FOLDER, "/", name[:len(name) - len(".md")]}, context.temp_allocator))
		site.documents[path] = page
		site.documents[name] = page
	}
	glossary_problems: []string
	site.glossary, glossary_problems = glossary_read(glossary_text)
	if len(glossary_problems) > 0 {
		for problem in glossary_problems {
			fmt.eprintfln("kerneltool: site: %s, %s", SITE_GLOSSARY_FILE, problem)
		}
		return false
	}
	site.terms = site_glossary_terms(site.glossary)
	// The sources of the reference tables are read before any guide is
	// rendered: a code span of a guide links to their rows.
	site_reference_read(&site) or_return
	// The declarations of the sources, before any guide is rendered: a code
	// span of a guide links to them.
	site_declarations_read(&site) or_return

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
	// The mark of the maker, for the foot of each page.
	maker_picture, maker_error := os.read_entire_file(SITE_MAKER_PICTURE_SOURCE, context.temp_allocator)
	if maker_error != nil {
		fmt.eprintfln("kerneltool: site: cannot read %s", SITE_MAKER_PICTURE_SOURCE)
		return false
	}
	site_write_file(&site, SITE_PICTURE_FOLDER + "/" + SITE_MAKER_PICTURE, maker_picture) or_return

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

	// The measured numbers and the stages of the start: from the logs of
	// build/ when they are newer than the measure record, else from the
	// record. A clean checkout has the record only.
	measure_record_found, measure_record_problem := site_measure_record_read(MEASURE_RECORD_FILE)
	if measure_record_problem != "" {
		fmt.eprintfln("kerneltool: site: %s", measure_record_problem)
		return false
	}
	site.measure_record = measure_record_found
	measured := make([dynamic]Site_Measured, context.temp_allocator)
	for measure in site_measures {
		append(&measured, site_measure_resolve(site_measure_read(measure), site.measure_record))
	}
	site.measured = measured[:]
	boot_log: string
	boot_log, site.boot_source = site_boot_log_choose(site.measure_record)
	site.boot_stages = site_boot_stages(boot_log)
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
	// The home of the docs before the home: the doors of the home name the
	// sections that exist. Its text needs the index of the search, so it is
	// written after the index (site_docs_home_fill).
	site_docs_home_add(&site)
	site_home_add(&site)
	// A pointer to a document whose label finds no place is stale, and a
	// link of a comment whose target names nothing is false: the command
	// stops with its file and its line, so that none comes back.
	pointer_problems := site_document_pointer_problems(&site)
	if len(pointer_problems) > 0 {
		for problem in pointer_problems {
			fmt.eprintfln("kerneltool: site: %s", problem)
		}
		fmt.eprintfln("kerneltool: site: %d pointers to documents and links of comments name no place; no page is written", len(pointer_problems))
		return false
	}
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
	// The style sheet holds the icons of the kinds of values: a page asks
	// for no file to draw them.
	style_sheet := site_style_sheet(site.tile_rules)
	site_write_file(&site, SITE_STYLE_SHEET, transmute([]u8)style_sheet) or_return
	site_write_file(&site, SITE_SEARCH_SCRIPT, transmute([]u8)site_search_script()) or_return
	site_write_file(&site, SITE_MODULE_GRAPH_SCRIPT, transmute([]u8)site_module_graph_script()) or_return
	site_write_file(&site, SITE_GLOSSARY_SCRIPT, transmute([]u8)site_glossary_script()) or_return
	// The commit and the time of this build: a page that a cache kept from
	// an older build finds that it is older.
	site_write_file(&site, SITE_VERSION_FILE, transmute([]u8)site_version_json(site.commit, site.build_time)) or_return
	site_mark_animation_write(&site) or_return
	// The index of the search, from the same data as the pages. It is
	// written before the pages, because each page names the version of its
	// bytes; it is checked against the pages after them.
	search_entries := site_search_entries(&site)
	search_index := site_search_index_json(&site, search_entries, site.pages[:])
	if len(search_index) > SITE_SEARCH_INDEX_BYTE_LIMIT {
		fmt.eprintfln("kerneltool: site: %s has %d bytes; at most %d", SITE_SEARCH_INDEX, len(search_index), SITE_SEARCH_INDEX_BYTE_LIMIT)
		return false
	}
	site_write_file(&site, SITE_SEARCH_INDEX, transmute([]u8)search_index) or_return
	// The home of the docs says what the search knows: the counts of the
	// entries that the index holds.
	site_docs_home_fill(&site, search_entries)

	written := make(map[string]string, context.temp_allocator)
	for page in site.pages {
		written[page.path] = site_page_html(&site, page)
	}
	problems := make([dynamic]string, context.temp_allocator)
	append(&problems, ..site_check_pages(site.pages[:], written, site.files, site.address != ""))
	// One search field on each page: in the bar, or in the page itself on
	// the home of the docs.
	for page in site.pages {
		if problem := site_search_field_problem(page, written[page.path]); problem != "" {
			append(&problems, fmt.tprintf("%s: %s", page.path, problem))
		}
	}
	// The name of a document is a reference or a link on a page, never a
	// bare path that the reader cannot open.
	document_names := site_document_names(&site)
	for page in site.pages {
		if problem := site_document_name_problem(written[page.path], document_names); problem != "" {
			append(&problems, fmt.tprintf("%s: %s", page.path, problem))
		}
	}
	// The pages of the glossary: none too large to open on a slow line, and
	// each term at its anchor on the index and on the page of its group.
	append(&problems, ..site_glossary_problems(&site, written))
	// Each old address of each page: a redirect page, which is not a page
	// of the site (no bar, no sitemap, no index of the search).
	append(&problems, ..site_redirects_make(&site))
	append(&problems, ..site_check_redirects(site.redirects, written, site.files, site.address != ""))
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
	// The index of the search, checked against the pages that the command
	// writes.
	search_problems := site_search_problems(search_entries, written)
	if len(search_problems) > 0 {
		for problem in search_problems {
			fmt.eprintfln("kerneltool: site: %s", problem)
		}
		fmt.eprintfln("kerneltool: site: %d problems of the search index; no page is written", len(search_problems))
		return false
	}
	if site.address != "" {
		site_write_file(&site, SITE_SITEMAP, transmute([]u8)sitemap) or_return
		site_write_file(&site, SITE_ROBOTS, transmute([]u8)site_robots(&site)) or_return
	}
	page_bytes := 0
	for path, html in written {
		site_write_file(&site, path, transmute([]u8)html) or_return
		page_bytes += len(html)
	}
	for old_path, html in site.redirects {
		site_write_file(&site, old_path, transmute([]u8)html) or_return
	}

	fmt.printfln("kerneltool: site: wrote %s: %d pages (%d bytes), %d redirect pages at the old addresses, %d other files", SITE_FOLDER, len(site.pages), page_bytes, len(site.redirects), len(site.files) - len(site.pages) - len(site.redirects))
	for generation in Site_Address_Generation {
		fmt.printfln("kerneltool: site: %d redirect pages at the old addresses %s", site.redirect_counts[generation], site_address_generation_names[generation])
	}
	// The bytes of each page of the glossary: the bound is what split it.
	for path in site_glossary_page_paths(site.glossary) {
		fmt.printfln("kerneltool: site: %s: %d bytes of at most %d", path, len(written[path]), SITE_GLOSSARY_PAGE_BYTE_LIMIT)
	}
	fmt.printfln("kerneltool: site: %s: %d bytes, with %d icons of the kinds of values inside", SITE_STYLE_SHEET, len(style_sheet), site_style_sheet_icon_count(style_sheet))
	fmt.printfln("kerneltool: site: %s: %d entries of at most %d, %d bytes of at most %d; %s: %d bytes", SITE_SEARCH_INDEX, len(search_entries), SITE_SEARCH_ENTRY_LIMIT, len(search_index), SITE_SEARCH_INDEX_BYTE_LIMIT, SITE_SEARCH_SCRIPT, site.files[SITE_SEARCH_SCRIPT])
	commit_text: string = site.commit != "" ? site.commit : "not readable (links to files go to master)"
	fmt.printfln("kerneltool: site: %d guides, %d terms of the glossary, %d news entries, the commit %s, the release %s", len(site.guides), len(site.terms), len(site.news), commit_text, site.release)
	// A symbol with no comment in its source shows no text on its page: the
	// count makes the gap visible.
	fmt.printfln("kerneltool: site: %d documented symbols, %d symbols with no description in their source", site.symbol_count, site.symbols_without_description)
	// A type that a page shows with no card is plain text: the count makes
	// the gap visible.
	fmt.printfln("kerneltool: site: %d types, %d type names with no card", len(site.types), site.type_names_without_card)
	// A pointer of a comment or a guide whose label finds no heading is a
	// stale pointer: the count and the first ones make it seen.
	reference_count, unresolved_references := site_document_references_summary(&site)
	if len(unresolved_references) > 0 {
		fmt.printfln("kerneltool: site: %d document references, %d with no heading found: %s", reference_count, len(unresolved_references), strings.join(unresolved_references[:min(3, len(unresolved_references))], "; ", context.temp_allocator))
	} else {
		fmt.printfln("kerneltool: site: %d document references, 0 with no heading found", reference_count)
	}
	// A block of Odin that the tokenizer refused is plain: the count and the
	// first one make it seen.
	if site.code_blocks_not_colored > 0 {
		fmt.printfln("kerneltool: site: %d code blocks not colored, the first: %s", site.code_blocks_not_colored, site.first_code_block_not_colored)
	} else {
		fmt.println("kerneltool: site: 0 code blocks not colored")
	}
	// The code spans that have the form of a name: a stale name in a guide
	// is a span that names no declaration, and the first ones are named.
	for line in site_declaration_summary(&site) {
		fmt.printfln("kerneltool: site: %s", line)
	}
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
	missing, from_record, from_build := 0, 0, 0
	for number in site.measured {
		switch number.source {
		case .None:
			missing += 1
			fmt.printfln("kerneltool: site: not measured: %s (%s)", number.measure.sentence, number.missing)
		case .Record:
			from_record += 1
		case .Build:
			from_build += 1
		}
	}
	fmt.printfln("kerneltool: site: %d of %d numbers measured: %d from %s, %d from the logs in %s/ that are newer", len(site.measured) - missing, len(site.measured), from_record, MEASURE_RECORD_FILE, from_build, BUILD_FOLDER)
	if site.measure_record.present {
		record := site.measure_record.record
		fmt.printfln("kerneltool: site: %s: the full check of %s, on the tree of %s (%s), the release %s, %d checks passed", MEASURE_RECORD_FILE, record.time, site_short_commit(record.commit), measure_tree_state_names[record.tree], record.release, record.checks_passed)
		if record.release != site.release {
			fmt.printfln("kerneltool: site: %s is of the release %s, older than the release %s of the site", MEASURE_RECORD_FILE, record.release, site.release)
		}
	} else {
		fmt.printfln("kerneltool: site: no %s", MEASURE_RECORD_FILE)
	}
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
	if site_page_exists(site, site_section_page(.News)) {
		fmt.sbprintf(&b, "<link rel=\"alternate\" type=\"application/atom+xml\" title=\"News of %s\" href=\"%s\">\n", SITE_SYSTEM_NAME, link(page, SITE_NEWS_FEED))
	}
	// The feed of the releases, the manifest, the guides before and after;
	// with an address, the canonical address, Open Graph and JSON-LD.
	site_head_metadata(site, page, &b)
	section_name := strings.to_lower(site_section_titles[page.section], context.temp_allocator)
	is_documentation := page.layout == .Documentation
	layout_name: string = is_documentation ? "documentation" : "presentation"
	// The files that change between builds carry the version of their
	// bytes, so that a proxy that keeps a file for hours never serves an
	// old one with a new page.
	fmt.sbprintf(&b, "<link rel=\"stylesheet\" href=\"%s\">\n", site_file_link(site, page.path, SITE_STYLE_SHEET))
	// The commit of this build, which the script compares with the commit
	// of version.json: a page that a cache kept from an older build says so.
	if site.commit != "" {
		fmt.sbprintf(&b, "<meta name=\"build-commit\" content=\"%s\">\n", site.commit)
	}
	// The script of the site: the search, the menu and "On this page". Each
	// page is whole with no script. The animations of the mark play on the
	// large heron of the home only. The script reads the address of the
	// index of the search, with its version, from its own element: the
	// address is relative to the folder of the script.
	if page.section == .Home {
		fmt.sbprintf(&b, "<script src=\"%s\" defer></script>\n", site_file_link(site, page.path, SITE_MARK_ANIMATION_SCRIPT))
	}
	if page.script != "" {
		fmt.sbprintf(&b, "<script src=\"%s\" defer></script>\n", site_file_link(site, page.path, page.script))
	}
	fmt.sbprintf(&b, "<script src=\"%s\" data-index=\"%s\" defer></script>\n</head>\n<body class=\"section-%s layout-%s\">\n", site_file_link(site, page.path, SITE_SEARCH_SCRIPT), site_file_link(site, SITE_PAGE, SITE_SEARCH_INDEX), section_name, layout_name)
	write(&b, "<a class=\"skip\" href=\"#content\">Skip to the content</a>\n")

	// The bar: the heron and the name at the left, the sections as buttons.
	write(&b, "<header class=\"bar\">\n<div class=\"bar-inner\">\n")
	fmt.sbprintf(&b, "<a class=\"bar-home\" href=\"%s\"><picture><source media=\"(prefers-color-scheme: light)\" srcset=\"%s\">", site_page_link(site, page.path, site_section_page(.Home)), link(page, SITE_PICTURE_FOLDER + "/" + SITE_MARK_BAR_LIGHT))
	fmt.sbprintf(&b, "<img src=\"%s\" width=\"24\" height=\"24\" alt=\"\"></picture><span>%s</span></a>\n", link(page, SITE_PICTURE_FOLDER + "/" + SITE_MARK_BAR), SITE_SYSTEM_NAME)
	// The sections and the search are in one menu: one list of links for
	// every width. Under 720 pixels the menu is a square button; on a wide
	// screen the style sheet and the script show it open, as a bar
	// (docs/SITE.md, "The site menu").
	write(&b, SITE_MENU_OPEN)
	write(&b, "<nav class=\"bar-sections\" aria-label=\"Sections\">\n<ul>\n")
	bar_section := site_bar_section(page.section)
	for section in Site_Section {
		if !site_section_in_bar(section) || !site_page_exists(site, site_section_page(section)) {
			continue
		}
		current: string = section == bar_section ? " aria-current=\"page\"" : ""
		fmt.sbprintf(&b, "<li><a href=\"%s\"%s>%s</a></li>\n", site_page_link(site, page.path, site_section_page(section)), current, site_section_titles[section])
	}
	write(&b, "</ul>\n</nav>\n")
	// One search field on a page: the home of the docs has its own large
	// field, so its bar has none (docs/SITE.md, "The search").
	if !page.search_in_page {
		write(&b, site_search_field_html(.Bar))
	}
	// The tree of the documentation is in the menu, once in the page: on a
	// wide screen the style sheet puts it at the left of the page, and
	// under 720 pixels it is under the sections in the open menu
	// (docs/SITE.md, "The two layouts").
	if is_documentation {
		write(&b, site_tree_html(site, page))
	}
	write(&b, "</div>\n</details>\n</div>\n</header>\n")

	crumbs := strings.builder_make(context.temp_allocator)
	if len(page.crumbs) > 0 {
		write(&crumbs, is_documentation ? "<nav class=\"crumbs\" aria-label=\"Breadcrumbs\">\n<ol>\n" : "<nav class=\"crumbs page\" aria-label=\"Breadcrumbs\">\n<ol>\n")
		for crumb in page.crumbs {
			fmt.sbprintf(&crumbs, "<li><a href=\"%s\">", site_page_link(site, page.path, crumb.path))
			site_escape(&crumbs, crumb.title)
			write(&crumbs, "</a></li>\n")
		}
		write(&crumbs, "<li aria-current=\"page\">")
		site_escape(&crumbs, page.title)
		write(&crumbs, "</li>\n</ol>\n</nav>\n")
	}
	if is_documentation {
		// The list "On this page" comes first: beside the text on a wide
		// screen, above it on a narrower one.
		fmt.sbprintf(&b, "<main id=\"content\" class=\"documentation page-%s\">\n", section_name)
		write(&b, site_outline_html(page))
		write(&b, "<div class=\"text\">\n")
		write(&b, strings.to_string(crumbs))
		write(&b, page.body)
		// The card of each type and of each declaration that the text
		// names, once for the page.
		write(&b, site_cards_html(site, page.path, page.body))
		write(&b, "</div>\n</main>\n")
	} else {
		write(&b, strings.to_string(crumbs))
		fmt.sbprintf(&b, "<main id=\"content\" class=\"page page-%s\">\n", section_name)
		write(&b, page.body)
		write(&b, site_cards_html(site, page.path, page.body))
		write(&b, "</main>\n")
	}

	// The foot: the build that the page comes from, and its sources.
	write(&b, "<footer class=\"foot\">\n<div class=\"page\">\n")
	fmt.sbprintf(&b, "<p class=\"foot-maker\">%s · by <span class=\"maker\"><img src=\"%s\" width=\"16\" height=\"16\" alt=\"\"><a href=\"%s\">%s</a></span></p>\n", SITE_SYSTEM_NAME, link(page, SITE_PICTURE_FOLDER + "/" + SITE_MAKER_PICTURE), SITE_MAKER_ADDRESS, SITE_MAKER_NAME)
	write(&b, "<p>Generated by <code>kerneltool site</code> from ")
	if site.commit != "" {
		fmt.sbprintf(&b, "the commit <a href=\"%s/commit/%s\"><code>%s</code></a>", SITE_REPOSITORY_ADDRESS, site.commit, site.commit[:12])
	} else {
		write(&b, "a work tree whose commit the tool cannot read")
	}
	fmt.sbprintf(&b, ", at the release <a href=\"%s#%s\">%s</a>, on %s.</p>\n", site_page_link(site, page.path, site_section_page(.Releases)), site_release_id(site.release), site.release, site.build_time)
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
	fmt.sbprintf(&b, "<p><a href=\"%s\">The repository</a> - <a href=\"%s\">Licenses</a></p>\n</div>\n</footer>\n</body>\n</html>\n", SITE_REPOSITORY_ADDRESS, site_page_link(site, page.path, site_page_file(SITE_LICENSES_FOLDER)))
	return strings.to_string(b)
}

// site_cards_html gives the cards that the text of a page opens: the card of
// each declaration that it links to, and the card of each type that the
// text or those cards name. The one line of a declaration can name a type of
// the contract, so the types are collected after the declarations.
site_cards_html :: proc(site: ^Site, from_page, body: string) -> string {
	declaration_cards := site_declaration_cards_html(site, from_page, body)
	type_cards := site_type_cards_html(site, from_page, strings.concatenate({body, declaration_cards}, context.temp_allocator))
	return strings.concatenate({type_cards, declaration_cards}, context.temp_allocator)
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
//   a page or a file of the site, and its anchor is an id of that page;
//   a link to a page has the form of site_page_link: its folder with a
//   site address, its index.html with none.
site_check_pages :: proc(pages: []Site_Page, written: map[string]string, files: map[string]int, has_address: bool) -> []string {
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
		if problem := site_heading_value_problem(html); problem != "" {
			append(&problems, fmt.tprintf("%s: %s", page.path, problem))
		}
		if problem := site_layout_problem(page, html, ids[page.path]); problem != "" {
			append(&problems, fmt.tprintf("%s: %s", page.path, problem))
		}
		if problem := site_type_cards_problem(html, ids[page.path]); problem != "" {
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
					_, problem := site_link_target(page.path, folder, strings.trim_space(candidate), written, files, ids, has_address)
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

// site_link_target checks one link of a page: it gives the page or the
// file of the site that the link names, and the problem of the link or "".
// A link that ends with "/" names the index.html of a folder. An address
// of another host gives no target and no problem.
site_link_target :: proc(page_path, folder, value: string, written: map[string]string, files: map[string]int, ids: map[string]map[string]bool, has_address: bool) -> (target: string, problem: string) {
	if value == "\x00" {
		return "", "no closing quote"
	}
	if value == "" {
		return "", "empty"
	}
	if strings.has_prefix(value, "https://") || strings.has_prefix(value, "http://") {
		return "", "" // The address of another host: not a file of the site.
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
	// The version of a file ("style.css?v=..."): the file is the same.
	if query := strings.index_byte(address, '?'); query >= 0 {
		address = address[:query]
	}
	names_folder := strings.has_suffix(address, "/")
	names_index := address == SITE_PAGE || strings.has_suffix(address, "/" + SITE_PAGE)
	if has_address && names_index {
		return "", "a link to a page names its index.html; with a site address it names the folder of the page"
	}
	if !has_address && names_folder {
		return "", "a link names a folder; with no site address it names the index.html of the folder, because a browser shows a folder of a disk as a list of files"
	}
	target = page_path
	if address != "" {
		target = site_path_join(folder, address)
		if names_folder {
			target = site_page_file(target)
		}
	}
	_, is_page := written[target]
	_, is_file := files[target]
	if !is_page && !is_file {
		return target, fmt.tprintf("names %s, which the command did not write", target)
	}
	if anchor != "" {
		if !is_page {
			return target, "an anchor in a file that is not a page"
		}
		if anchor not_in ids[target] {
			return target, fmt.tprintf("%s has no id \"%s\"", target, anchor)
		}
	}
	return target, ""
}
