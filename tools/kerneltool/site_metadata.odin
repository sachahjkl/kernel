// What search engines, feed readers and other sites read of the site
// (docs/SITE.md, "What other sites read"): the head of each page beyond its
// title (the canonical address, Open Graph, the summary card, the icons,
// the manifest, the links between guides), one JSON-LD graph for each page,
// the sitemap, robots.txt, the feed of the releases, llms.txt, and the
// checks of all of them.
//
// Each part that needs an absolute address is written only when the site
// has an address (`kerneltool site --address https://...`): a canonical
// address, an Open Graph address or a JSON-LD id that is relative is wrong
// for the reader that receives it, so the site writes none rather than a
// wrong one.
package kerneltool

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"

SITE_SITEMAP :: "sitemap.xml"
SITE_ROBOTS :: "robots.txt"
SITE_RELEASES_FEED :: "releases.xml"
SITE_LANGUAGE_MODEL_INDEX :: "llms.txt"
SITE_MANIFEST :: "site.webmanifest"
SITE_LANGUAGE :: "en"
// The picture for other sites: its size is the one that Open Graph and the
// summary card with a large picture show whole.
SITE_CARD_WIDTH :: 1200
SITE_CARD_HEIGHT :: 630
SITE_STRUCTURED_DATA_OPEN :: "<script type=\"application/ld+json\">"
SITE_SCRIPT_CLOSE :: "</script>"
// A headline longer than this is cut by the readers of articles.
SITE_HEADLINE_LIMIT :: 110

// site_page_address gives the absolute address of a page. An index page
// is named by its folder, the form that a host serves and that a person
// shares: "https://host/path/guides/", not ".../guides/index.html".
site_page_address :: proc(address, path: string) -> string {
	if path == SITE_PAGE {
		return strings.concatenate({address, "/"}, context.temp_allocator)
	}
	if strings.has_suffix(path, "/" + SITE_PAGE) {
		return strings.concatenate({address, "/", path[:len(path) - len(SITE_PAGE)]}, context.temp_allocator)
	}
	return strings.concatenate({address, "/", path}, context.temp_allocator)
}

// site_file_address gives the absolute address of a file of the site that
// is not a page.
site_file_address :: proc(address, path: string) -> string {
	return strings.concatenate({address, "/", path}, context.temp_allocator)
}

// site_plain_text gives a line of Markdown as text with no marks of code
// and bold, not escaped: the JSON writer escapes it.
site_plain_text :: proc(text: string) -> string {
	without_code, _ := strings.remove_all(text, "`", context.temp_allocator)
	without_bold, _ := strings.remove_all(without_code, "**", context.temp_allocator)
	return strings.trim_space(without_bold)
}

// site_headline gives a title of at most SITE_HEADLINE_LIMIT bytes, cut at
// a space.
site_headline :: proc(title: string) -> string {
	if len(title) <= SITE_HEADLINE_LIMIT {
		return title
	}
	cut := strings.last_index_byte(title[:SITE_HEADLINE_LIMIT - 4], ' ')
	if cut <= 0 {
		cut = SITE_HEADLINE_LIMIT - 4
	}
	return strings.concatenate({title[:cut], " ..."}, context.temp_allocator)
}

// site_html_unescape gives the text of an attribute that site_escape wrote.
site_html_unescape :: proc(text: string) -> string {
	result := text
	for pair in ([][2]string{{"&lt;", "<"}, {"&gt;", ">"}, {"&quot;", "\""}, {"&#39;", "'"}, {"&amp;", "&"}}) {
		result, _ = strings.replace_all(result, pair[0], pair[1], context.temp_allocator)
	}
	return result
}

// site_license_address gives the SPDX address of the license of the
// system, or "" when its file names no SPDX identifier.
site_license_address :: proc(site: ^Site) -> string {
	if len(site.licenses.system_rows) == 0 {
		return ""
	}
	identifier := site.licenses.system_rows[0].license
	if identifier == "" || strings.contains_any(identifier, " /\"") {
		return ""
	}
	return strings.concatenate({"https://spdx.org/licenses/", identifier, ".html"}, context.temp_allocator)
}

// site_copyright_holder gives the holder of a line "Copyright (c) <years>
// <holder>": the words after the mark and the years, with no final period.
// It gives "" when no word is left.
site_copyright_holder :: proc(line: string) -> string {
	rest := strings.trim_space(line)
	rest = strings.trim_prefix(rest, "Copyright")
	rest = strings.trim_space(rest)
	for copyright_mark in ([]string{"(c)", "(C)", "©"}) {
		rest = strings.trim_space(strings.trim_prefix(rest, copyright_mark))
	}
	// The years: digits, "-", "," and spaces, as "2025-2026, 2027".
	index := 0
	for index < len(rest) && ((rest[index] >= '0' && rest[index] <= '9') || rest[index] == '-' || rest[index] == ',' || rest[index] == ' ') {
		index += 1
	}
	return strings.trim_right(strings.trim_space(rest[index:]), ".")
}

// site_account_address gives the address of the account that owns the
// repository: the repository address without its last part.
site_account_address :: proc() -> string {
	// A constant string cannot be sliced by a variable: a copy can.
	repository: string = SITE_REPOSITORY_ADDRESS
	slash := strings.last_index_byte(repository, '/')
	return repository[:slash]
}

// site_feed_author writes the author of a feed: the holder of the line
// "Copyright" of LICENSE and the account that owns the repository, or the
// system and its repository when LICENSE names no holder.
site_feed_author :: proc(site: ^Site, b: ^strings.Builder) {
	name := site.author != "" ? site.author : SITE_SYSTEM_NAME
	address := site.author != "" ? site_account_address() : SITE_REPOSITORY_ADDRESS
	strings.write_string(b, "<author><name>")
	site_xml_escape(b, name)
	strings.write_string(b, "</name><uri>")
	site_xml_escape(b, address)
	strings.write_string(b, "</uri></author>\n")
}

// site_json_optional_reference names another node only when its id is
// known: a field that names no node is not written.
site_json_optional_reference :: proc(object: ^Site_Json_Object, key, id: string) {
	if id != "" {
		site_json_reference(object, key, id)
	}
}

// site_guide_index gives the place of a guide in the reading order, or -1.
site_guide_index :: proc(site: ^Site, path: string) -> int {
	for guide, index in site.guides {
		if guide.path == path {
			return index
		}
	}
	return -1
}

// site_head_metadata writes the part of the head of a page that other
// programs read: the feeds, the manifest, the guides before and after, and,
// with an address, the canonical address, Open Graph, the summary card and
// the JSON-LD graph.
site_head_metadata :: proc(site: ^Site, page: Site_Page, b: ^strings.Builder) {
	fmt.sbprintf(b, "<link rel=\"alternate\" type=\"application/atom+xml\" title=\"Releases of %s\" href=\"%s\">\n", SITE_SYSTEM_NAME, site_relative(page.path, SITE_RELEASES_FEED))
	fmt.sbprintf(b, "<link rel=\"manifest\" href=\"%s\">\n", site_relative(page.path, SITE_MANIFEST))
	if index := site_guide_index(site, page.path); index >= 0 {
		if index > 0 {
			fmt.sbprintf(b, "<link rel=\"prev\" href=\"%s\">\n", site_page_link(site, page.path, site.guides[index - 1].path))
		}
		if index + 1 < len(site.guides) {
			fmt.sbprintf(b, "<link rel=\"next\" href=\"%s\">\n", site_page_link(site, page.path, site.guides[index + 1].path))
		}
	}
	if site.author != "" {
		strings.write_string(b, "<meta name=\"author\" content=\"")
		site_escape(b, site.author)
		strings.write_string(b, "\">\n")
	}
	if site.address == "" {
		return
	}
	page_address := site_page_address(site.address, page.path)
	card_address := site_file_address(site.address, SITE_PICTURE_FOLDER + "/" + SITE_MARK_CARD)
	meta :: proc(b: ^strings.Builder, property, value: string) {
		fmt.sbprintf(b, "<meta property=\"%s\" content=\"", property)
		site_escape(b, value)
		strings.write_string(b, "\">\n")
	}
	strings.write_string(b, "<link rel=\"canonical\" href=\"")
	site_escape(b, page_address)
	strings.write_string(b, "\">\n")
	meta(b, "og:type", site_guide_index(site, page.path) >= 0 ? "article" : "website")
	meta(b, "og:site_name", SITE_SYSTEM_NAME)
	meta(b, "og:title", page.title)
	meta(b, "og:description", page.description)
	meta(b, "og:url", page_address)
	meta(b, "og:image", card_address)
	meta(b, "og:image:type", "image/png")
	meta(b, "og:image:width", fmt.tprintf("%d", SITE_CARD_WIDTH))
	meta(b, "og:image:height", fmt.tprintf("%d", SITE_CARD_HEIGHT))
	meta(b, "og:image:alt", site.readme.mark_description)
	// The summary card reads the title, the description and the picture of
	// Open Graph when it has none of its own.
	strings.write_string(b, "<meta name=\"twitter:card\" content=\"summary_large_image\">\n")
	strings.write_string(b, SITE_STRUCTURED_DATA_OPEN)
	strings.write_string(b, site_structured_data(site, page))
	strings.write_string(b, SITE_SCRIPT_CLOSE + "\n")
}

// The writer of JSON objects: each field is written after a comma, but the
// first. The text goes through site_json_string, which escapes each
// character that can end a script element or a line of a script.
Site_Json_Object :: struct {
	builder: ^strings.Builder,
	first:   bool,
}

site_json_open :: proc(builder: ^strings.Builder, type_name: string, id: string = "") -> Site_Json_Object {
	strings.write_byte(builder, '{')
	object := Site_Json_Object{builder = builder, first = true}
	if type_name != "" {
		site_json_text(&object, "@type", type_name)
	}
	if id != "" {
		site_json_text(&object, "@id", id)
	}
	return object
}

site_json_close :: proc(object: ^Site_Json_Object) {
	strings.write_byte(object.builder, '}')
}

site_json_key :: proc(object: ^Site_Json_Object, key: string) {
	if !object.first {
		strings.write_byte(object.builder, ',')
	}
	object.first = false
	site_json_string(object.builder, key)
	strings.write_byte(object.builder, ':')
}

// site_json_text writes a text field; an empty text writes no field.
site_json_text :: proc(object: ^Site_Json_Object, key, value: string) {
	if value == "" {
		return
	}
	site_json_key(object, key)
	site_json_string(object.builder, value)
}

site_json_number :: proc(object: ^Site_Json_Object, key: string, value: int) {
	site_json_key(object, key)
	fmt.sbprintf(object.builder, "%d", value)
}

// site_json_reference writes a field that names another node by its id.
site_json_reference :: proc(object: ^Site_Json_Object, key, id: string) {
	site_json_key(object, key)
	strings.write_string(object.builder, "{\"@id\":")
	site_json_string(object.builder, id)
	strings.write_byte(object.builder, '}')
}

// One picture that a page shows, read from its img element.
Site_Shown_Picture :: struct {
	path:    string, // In the site.
	width:   int,
	height:  int,
	caption: string,
}

// site_shown_pictures reads the pictures of the content of a page: the
// same elements that the reader sees, so the graph cannot name another
// picture.
site_shown_pictures :: proc(page: Site_Page) -> []Site_Shown_Picture {
	pictures := make([dynamic]Site_Shown_Picture, context.temp_allocator)
	folder := page.path[:max(strings.last_index_byte(page.path, '/'), 0)]
	rest := page.body
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
		rest = rest[start + end:]
		source := site_first_attribute_value(tag, "src=\"")
		if source == "" || source == "\x00" || strings.has_prefix(source, "https://") || strings.has_prefix(source, "http://") {
			continue
		}
		picture := Site_Shown_Picture {
			path    = site_path_join(folder, source),
			caption = site_html_unescape(site_first_attribute_value(tag, "alt=\"")),
		}
		width_ok, height_ok: bool
		picture.width, width_ok = site_decimal(site_first_attribute_value(tag, "width=\""))
		picture.height, height_ok = site_decimal(site_first_attribute_value(tag, "height=\""))
		if !width_ok || !height_ok {
			continue
		}
		known := false
		for other in pictures {
			known ||= other.path == picture.path
		}
		if !known {
			append(&pictures, picture)
		}
	}
	return pictures[:]
}

// site_first_attribute_value gives the first value of an attribute in an
// element, or "".
site_first_attribute_value :: proc(tag, attribute: string) -> string {
	values := site_attribute_values(tag, attribute)
	return len(values) > 0 ? values[0] : ""
}

// site_decimal reads a whole number of decimal digits.
site_decimal :: proc(text: string) -> (value: int, ok: bool) {
	if text == "" || len(text) > 9 {
		return 0, false
	}
	for character in transmute([]u8)text {
		if character < '0' || character > '9' {
			return 0, false
		}
		value = value * 10 + int(character - '0')
	}
	return value, true
}

// site_structured_data gives the JSON-LD graph of a page (docs/SITE.md,
// "The graph of each page"). Each node is built from the data that the
// page shows; nodes name each other by their ids.
site_structured_data :: proc(site: ^Site, page: Site_Page) -> string {
	address := site.address
	website_id := strings.concatenate({site_page_address(address, SITE_PAGE), "#website"}, context.temp_allocator)
	system_id := strings.concatenate({site_page_address(address, SITE_PAGE), "#system"}, context.temp_allocator)
	source_id := strings.concatenate({site_page_address(address, SITE_PAGE), "#source"}, context.temp_allocator)
	card_id := strings.concatenate({site_page_address(address, SITE_PAGE), "#card"}, context.temp_allocator)
	author_id := site.author != "" ? strings.concatenate({site_page_address(address, SITE_PAGE), "#author"}, context.temp_allocator) : ""
	page_address := site_page_address(address, page.path)
	page_id := strings.concatenate({page_address, "#page"}, context.temp_allocator)
	breadcrumb_id := strings.concatenate({page_address, "#breadcrumb"}, context.temp_allocator)
	license := site_license_address(site)
	home_description := site_description_cut(site.readme.lead)
	is_guide := site_guide_index(site, page.path) >= 0
	pictures := site_shown_pictures(page)

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\"@context\":\"https://schema.org\",\"@graph\":[")

	// The site, with the search that the script reads from "?q=".
	{
		node := site_json_open(&b, "WebSite", website_id)
		site_json_text(&node, "name", SITE_SYSTEM_NAME)
		site_json_text(&node, "url", site_page_address(address, SITE_PAGE))
		site_json_text(&node, "description", home_description)
		site_json_text(&node, "inLanguage", SITE_LANGUAGE)
		site_json_reference(&node, "about", system_id)
		site_json_optional_reference(&node, "publisher", author_id)
		site_json_key(&node, "potentialAction")
		action := site_json_open(&b, "SearchAction")
		site_json_key(&action, "target")
		target := site_json_open(&b, "EntryPoint")
		site_json_text(&target, "urlTemplate", strings.concatenate({site_page_address(address, SITE_PAGE), "?q={search_term_string}"}, context.temp_allocator))
		site_json_close(&target)
		site_json_text(&action, "query-input", "required name=search_term_string")
		site_json_close(&action)
		site_json_close(&node)
	}
	// The system as a program: an operating system, so it needs no other.
	// The machine is the one that docs/PROPERTIES.md names.
	{
		strings.write_byte(&b, ',')
		node := site_json_open(&b, "SoftwareApplication", system_id)
		site_json_text(&node, "name", SITE_SYSTEM_NAME)
		site_json_text(&node, "url", site_page_address(address, SITE_PAGE))
		site_json_text(&node, "description", home_description)
		site_json_text(&node, "applicationCategory", "Operating system")
		site_json_text(&node, "operatingSystem", "None: it is the operating system of the machine")
		site_json_text(&node, "processorRequirements", "x86-64")
		site_json_text(&node, "availableOnDevice", "QEMU on x86-64, with UEFI firmware and virtio devices")
		site_json_text(&node, "softwareVersion", site.release)
		site_json_text(&node, "license", license)
		site_json_reference(&node, "image", card_id)
		site_json_optional_reference(&node, "author", author_id)
		site_json_close(&node)
	}
	// The author: the name of the line "Copyright" of LICENSE, and the
	// account that owns the repository.
	if author_id != "" {
		strings.write_byte(&b, ',')
		node := site_json_open(&b, "Person", author_id)
		site_json_text(&node, "name", site.author)
		site_json_text(&node, "url", site_account_address())
		site_json_close(&node)
	}
	// The source code of the system.
	{
		strings.write_byte(&b, ',')
		node := site_json_open(&b, "SoftwareSourceCode", source_id)
		site_json_text(&node, "name", SITE_SYSTEM_NAME)
		site_json_text(&node, "codeRepository", SITE_REPOSITORY_ADDRESS)
		site_json_key(&node, "programmingLanguage")
		language := site_json_open(&b, "ComputerLanguage")
		site_json_text(&language, "name", "Odin")
		site_json_text(&language, "url", "https://odin-lang.org/")
		site_json_close(&language)
		site_json_text(&node, "license", license)
		site_json_text(&node, "version", site.release)
		site_json_reference(&node, "targetProduct", system_id)
		site_json_optional_reference(&node, "author", author_id)
		site_json_close(&node)
	}
	// The picture for other sites, which Open Graph also names.
	{
		strings.write_byte(&b, ',')
		node := site_json_open(&b, "ImageObject", card_id)
		card := site_file_address(address, SITE_PICTURE_FOLDER + "/" + SITE_MARK_CARD)
		site_json_text(&node, "url", card)
		site_json_text(&node, "contentUrl", card)
		site_json_number(&node, "width", SITE_CARD_WIDTH)
		site_json_number(&node, "height", SITE_CARD_HEIGHT)
		site_json_text(&node, "caption", site.readme.mark_description)
		site_json_close(&node)
	}
	// The pictures that the page shows.
	for picture in pictures {
		strings.write_byte(&b, ',')
		picture_address := site_file_address(address, picture.path)
		node := site_json_open(&b, "ImageObject", picture_address)
		site_json_text(&node, "contentUrl", picture_address)
		site_json_number(&node, "width", picture.width)
		site_json_number(&node, "height", picture.height)
		site_json_text(&node, "caption", picture.caption)
		site_json_close(&node)
	}

	// The page.
	main_entity := ""
	switch {
	case page.path == SITE_PAGE:
		main_entity = system_id
	case is_guide:
		main_entity = strings.concatenate({page_address, "#article"}, context.temp_allocator)
	case page.path == site_page_file(SITE_GLOSSARY_FOLDER):
		main_entity = strings.concatenate({page_address, "#terms"}, context.temp_allocator)
	case page.path == site_page_file(SITE_MODULES_FOLDER):
		main_entity = strings.concatenate({page_address, "#modules"}, context.temp_allocator)
	case page.path == site_section_page(.News) && len(site.news) > 0:
		main_entity = strings.concatenate({page_address, "#blog"}, context.temp_allocator)
	}
	{
		strings.write_byte(&b, ',')
		is_collection := page.is_index && page.path != SITE_PAGE
		node := site_json_open(&b, is_collection ? "CollectionPage" : "WebPage", page_id)
		site_json_text(&node, "url", page_address)
		site_json_text(&node, "name", page.title)
		site_json_text(&node, "description", page.description)
		site_json_text(&node, "inLanguage", SITE_LANGUAGE)
		site_json_reference(&node, "isPartOf", website_id)
		site_json_reference(&node, "primaryImageOfPage", card_id)
		if len(page.crumbs) > 0 {
			site_json_reference(&node, "breadcrumb", breadcrumb_id)
		}
		if main_entity != "" {
			site_json_reference(&node, "mainEntity", main_entity)
		}
		if len(pictures) > 0 {
			site_json_key(&node, "image")
			strings.write_byte(&b, '[')
			for picture, index in pictures {
				if index > 0 {
					strings.write_byte(&b, ',')
				}
				reference := site_json_open(&b, "")
				site_json_text(&reference, "@id", site_file_address(address, picture.path))
				site_json_close(&reference)
			}
			strings.write_byte(&b, ']')
		}
		site_json_close(&node)
	}
	// The breadcrumbs: the same as the line above the content.
	if len(page.crumbs) > 0 {
		strings.write_byte(&b, ',')
		node := site_json_open(&b, "BreadcrumbList", breadcrumb_id)
		site_json_key(&node, "itemListElement")
		strings.write_byte(&b, '[')
		for crumb, index in page.crumbs {
			item := site_json_open(&b, "ListItem")
			site_json_number(&item, "position", index + 1)
			site_json_text(&item, "name", crumb.title)
			site_json_text(&item, "item", site_page_address(address, crumb.path))
			site_json_close(&item)
			strings.write_byte(&b, ',')
		}
		last_item := site_json_open(&b, "ListItem")
		site_json_number(&last_item, "position", len(page.crumbs) + 1)
		site_json_text(&last_item, "name", page.title)
		site_json_text(&last_item, "item", page_address)
		site_json_close(&last_item)
		strings.write_byte(&b, ']')
		site_json_close(&node)
	}

	// The thing that the page is about.
	switch {
	case is_guide:
		// No date: the tool does not read the history of a document, and a
		// date that is not true is worse than none.
		strings.write_byte(&b, ',')
		node := site_json_open(&b, "TechArticle", main_entity)
		site_json_text(&node, "headline", site_headline(page.title))
		site_json_text(&node, "description", page.description)
		site_json_text(&node, "inLanguage", SITE_LANGUAGE)
		site_json_text(&node, "url", page_address)
		site_json_reference(&node, "mainEntityOfPage", page_id)
		site_json_reference(&node, "isPartOf", website_id)
		site_json_reference(&node, "about", system_id)
		site_json_optional_reference(&node, "author", author_id)
		site_json_reference(&node, "image", card_id)
		site_json_close(&node)
	case page.path == site_page_file(SITE_GLOSSARY_FOLDER):
		strings.write_byte(&b, ',')
		node := site_json_open(&b, "DefinedTermSet", main_entity)
		site_json_text(&node, "name", page.title)
		site_json_text(&node, "url", page_address)
		site_json_key(&node, "hasDefinedTerm")
		strings.write_byte(&b, '[')
		for term, index in site.terms {
			if index > 0 {
				strings.write_byte(&b, ',')
			}
			term_node := site_json_open(&b, "DefinedTerm", strings.concatenate({page_address, "#", term.id}, context.temp_allocator))
			site_json_text(&term_node, "name", term.name)
			site_json_text(&term_node, "description", site_plain_text(term.definition))
			site_json_text(&term_node, "url", strings.concatenate({page_address, "#", term.id}, context.temp_allocator))
			site_json_reference(&term_node, "inDefinedTermSet", main_entity)
			site_json_close(&term_node)
		}
		strings.write_byte(&b, ']')
		site_json_close(&node)
	case page.path == site_page_file(SITE_MODULES_FOLDER):
		strings.write_byte(&b, ',')
		node := site_json_open(&b, "ItemList", main_entity)
		site_json_text(&node, "name", page.title)
		modules := site.reference.modules
		count := 0
		for item in modules {
			count += site_page_exists(site, item.page) ? 1 : 0
		}
		site_json_number(&node, "numberOfItems", count)
		site_json_key(&node, "itemListElement")
		strings.write_byte(&b, '[')
		position := 0
		for item in modules {
			if !site_page_exists(site, item.page) {
				continue
			}
			if position > 0 {
				strings.write_byte(&b, ',')
			}
			position += 1
			list_item := site_json_open(&b, "ListItem")
			site_json_number(&list_item, "position", position)
			site_json_text(&list_item, "name", item.build.name)
			site_json_text(&list_item, "url", site_page_address(address, item.page))
			site_json_close(&list_item)
		}
		strings.write_byte(&b, ']')
		site_json_close(&node)
	case page.path == site_section_page(.News) && len(site.news) > 0:
		// A news entry is a dated report of the project, not journalism:
		// a post of a blog, not a news article.
		strings.write_byte(&b, ',')
		node := site_json_open(&b, "Blog", main_entity)
		site_json_text(&node, "name", fmt.tprintf("News of %s", SITE_SYSTEM_NAME))
		site_json_text(&node, "description", page.description)
		site_json_text(&node, "url", page_address)
		site_json_text(&node, "inLanguage", SITE_LANGUAGE)
		site_json_reference(&node, "isPartOf", website_id)
		site_json_reference(&node, "about", system_id)
		site_json_key(&node, "blogPost")
		strings.write_byte(&b, '[')
		for item, index in site.news {
			if index > 0 {
				strings.write_byte(&b, ',')
			}
			entry_address := strings.concatenate({page_address, "#", item.anchor}, context.temp_allocator)
			post := site_json_open(&b, "BlogPosting", entry_address)
			site_json_text(&post, "headline", site_headline(item.entry.title))
			site_json_text(&post, "description", site_plain_text(site_news_lead(item.entry)))
			site_json_text(&post, "url", entry_address)
			site_json_text(&post, "inLanguage", SITE_LANGUAGE)
			// An entry is written once and never updated: its one date is
			// the date of its head.
			site_json_text(&post, "datePublished", item.entry.date)
			site_json_text(&post, "dateModified", item.entry.date)
			site_json_text(&post, "articleSection", news_kind_names[item.entry.kind])
			site_json_reference(&post, "isPartOf", main_entity)
			site_json_reference(&post, "mainEntityOfPage", page_id)
			site_json_reference(&post, "about", system_id)
			site_json_optional_reference(&post, "author", author_id)
			if item.picture != "" {
				site_json_reference(&post, "image", site_file_address(address, item.picture))
			} else {
				site_json_reference(&post, "image", card_id)
			}
			site_json_close(&post)
		}
		strings.write_byte(&b, ']')
		site_json_close(&node)
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// site_sitemap gives sitemap.xml: the address of each page. A page has a
// date of its last change only when the tool knows it: the news page
// changes with its newest entry and the page of the releases with its
// newest release. The other pages have no date: each build changes their
// foot, and the tool does not read the history of their sources.
site_sitemap :: proc(site: ^Site) -> string {
	paths := make([dynamic]string, context.temp_allocator)
	for page in site.pages {
		append(&paths, page.path)
	}
	slice.sort(paths[:])
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n")
	for path in paths {
		strings.write_string(&b, "<url><loc>")
		site_xml_escape(&b, site_page_address(site.address, path))
		strings.write_string(&b, "</loc>")
		last_change := ""
		if path == site_section_page(.News) && len(site.news) > 0 {
			last_change = site.news[0].entry.date
		} else if path == site_section_page(.Releases) && len(site.changelog.releases) > 0 {
			last_change = site.changelog.releases[0].date
		}
		if last_change != "" {
			fmt.sbprintf(&b, "<lastmod>%s</lastmod>", last_change)
		}
		strings.write_string(&b, "</url>\n")
	}
	strings.write_string(&b, "</urlset>\n")
	return strings.to_string(b)
}

// site_robots gives robots.txt: every page may be read, and the address of
// the sitemap. A crawler reads robots.txt only at the root of a host: a
// site in a folder of a host needs the line of its sitemap in the
// robots.txt of the root (the command says so).
site_robots :: proc(site: ^Site) -> string {
	return fmt.tprintf("User-agent: *\nDisallow:\n\nSitemap: %s\n", site_file_address(site.address, SITE_SITEMAP))
}

// site_releases_feed gives the Atom feed of the releases (RFC 4287): one
// entry for each release of CHANGELOG.md, newest first. The id of an entry
// is the address of its release in the changelog of the repository on
// master: a release is never renamed, so the id never changes, also when
// the site gets an address.
site_releases_feed :: proc(site: ^Site) -> string {
	types := CHANGE_TYPES
	releases := site.changelog.releases
	changelog_address := strings.concatenate({SITE_REPOSITORY_ADDRESS, "/blob/master/", CHANGELOG_FILE}, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<feed xmlns=\"http://www.w3.org/2005/Atom\">\n")
	fmt.sbprintf(&b, "<title>Releases of %s</title>\n<subtitle>Every release of %s, newest first, with the changes of each one.</subtitle>\n", SITE_SYSTEM_NAME, SITE_SYSTEM_NAME)
	fmt.sbprintf(&b, "<id>%s</id>\n", changelog_address)
	if len(releases) > 0 {
		fmt.sbprintf(&b, "<updated>%sT00:00:00Z</updated>\n", releases[0].date)
	}
	site_feed_author(site, &b)
	strings.write_string(&b, "<link rel=\"alternate\" type=\"text/html\" href=\"")
	site_xml_escape(&b, site_feed_page_address(site, site_section_page(.Releases)))
	strings.write_string(&b, "\"/>\n")
	if site.address != "" {
		strings.write_string(&b, "<link rel=\"self\" type=\"application/atom+xml\" href=\"")
		site_xml_escape(&b, site_feed_address(site, SITE_RELEASES_FEED))
		strings.write_string(&b, "\"/>\n")
	}
	fmt.sbprintf(&b, "<icon>%s</icon>\n", site_feed_address(site, SITE_PICTURE_FOLDER + "/" + SITE_ICON_192))
	for changelog_release in releases {
		number := release_number_text(changelog_release.number)
		anchor := site_release_id(number)
		fmt.sbprintf(&b, "<entry>\n<title>%s %s</title>\n<id>%s#%s</id>\n", SITE_SYSTEM_NAME, number, changelog_address, anchor)
		strings.write_string(&b, "<link rel=\"alternate\" type=\"text/html\" href=\"")
		site_xml_escape(&b, site_feed_page_address(site, strings.concatenate({site_section_page(.Releases), "#", anchor}, context.temp_allocator)))
		fmt.sbprintf(&b, "\"/>\n<published>%sT00:00:00Z</published>\n<updated>%sT00:00:00Z</updated>\n", changelog_release.date, changelog_release.date)
		if len(changelog_release.entries) > 0 {
			strings.write_string(&b, "<summary>")
			site_plain(&b, entry_joined(changelog_release.entries[0].lines))
			strings.write_string(&b, "</summary>\n")
		}
		// The content is the HTML of the page of the releases for this
		// release, as a text: its markup is escaped once more.
		html := strings.builder_make(context.temp_allocator)
		type_index := -1
		for entry in changelog_release.entries {
			if entry.type_index != type_index {
				if type_index >= 0 {
					strings.write_string(&html, "</ul>")
				}
				type_index = entry.type_index
				fmt.sbprintf(&html, "<h3>%s</h3><ul>", types[type_index])
			}
			strings.write_string(&html, "<li>")
			site_inline(&html, entry_joined(entry.lines))
			strings.write_string(&html, "</li>")
		}
		if type_index >= 0 {
			strings.write_string(&html, "</ul>")
		}
		strings.write_string(&b, "<content type=\"html\">")
		site_xml_escape(&b, strings.to_string(html))
		strings.write_string(&b, "</content>\n</entry>\n")
	}
	strings.write_string(&b, "</feed>\n")
	return strings.to_string(b)
}

// site_manifest gives site.webmanifest: the name, the colors and the icons
// of the site for a browser that installs it or shows it in a list. Its
// addresses are relative to the manifest, so it needs no address.
site_manifest :: proc(site: ^Site) -> string {
	b := strings.builder_make(context.temp_allocator)
	node := site_json_open(&b, "")
	site_json_text(&node, "name", SITE_SYSTEM_NAME)
	site_json_text(&node, "short_name", SITE_SYSTEM_NAME)
	site_json_text(&node, "description", site_description_cut(site.readme.lead))
	site_json_text(&node, "lang", SITE_LANGUAGE)
	// The manifest is at the root: "./" is the root of the site, the
	// address of the home.
	site_json_text(&node, "start_url", "./")
	site_json_text(&node, "scope", "./")
	site_json_text(&node, "display", "browser")
	site_json_text(&node, "background_color", site_color(site_dark_colors().background))
	site_json_text(&node, "theme_color", site_color(site_dark_colors().background))
	site_json_key(&node, "icons")
	strings.write_byte(&b, '[')
	written_icons := 0
	for icon in site_icons {
		if icon.in_favicon || icon.size < 192 {
			continue // favicon.ico and the icon of a phone are named by the head.
		}
		if written_icons > 0 {
			strings.write_byte(&b, ',')
		}
		written_icons += 1
		entry := site_json_open(&b, "")
		site_json_text(&entry, "src", strings.concatenate({SITE_PICTURE_FOLDER, "/", icon.file_name}, context.temp_allocator))
		site_json_text(&entry, "sizes", fmt.tprintf("%dx%d", icon.size, icon.size))
		site_json_text(&entry, "type", "image/png")
		site_json_text(&entry, "purpose", icon.opaque ? "maskable" : "any")
		site_json_close(&entry)
	}
	strings.write_byte(&b, ']')
	site_json_close(&node)
	strings.write_byte(&b, '\n')
	return strings.to_string(b)
}

// site_language_model_index gives llms.txt (https://llmstxt.org): what the
// site is and its pages, in Markdown, for programs that read a site to
// answer a question. Each line is the title and the description of a page;
// the module pages are in the part "Optional", which a reader can skip.
site_language_model_index :: proc(site: ^Site) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "# %s\n\n> %s\n\n", SITE_SYSTEM_NAME, site_plain_text(site.readme.lead))
	fmt.sbprintf(&b, "The documentation of %s, generated from the repository %s at the release %s.\n", SITE_SYSTEM_NAME, SITE_REPOSITORY_ADDRESS, site.release)
	line :: proc(site: ^Site, b: ^strings.Builder, page: Site_Page) {
		address := site_feed_page_address(site, page.path)
		fmt.sbprintf(b, "- [%s](%s): %s\n", page.title, address, page.description)
	}
	for section in Site_Section {
		heading_written := false
		for page in site.pages {
			is_module_page := strings.has_prefix(page.path, SITE_MODULES_FOLDER + "/") && page.path != site_page_file(SITE_MODULES_FOLDER)
			if page.section != section || is_module_page {
				continue
			}
			if !heading_written {
				fmt.sbprintf(&b, "\n## %s\n\n", site_section_titles[section])
				heading_written = true
			}
			line(site, &b, page)
		}
	}
	optional_written := false
	for page in site.pages {
		if !strings.has_prefix(page.path, SITE_MODULES_FOLDER + "/") || page.path == site_page_file(SITE_MODULES_FOLDER) {
			continue
		}
		if !optional_written {
			strings.write_string(&b, "\n## Optional\n\n")
			optional_written = true
		}
		line(site, &b, page)
	}
	return strings.to_string(b)
}

// site_png_is_opaque tells whether a PNG file has no transparency: a color
// type with no alpha channel (gray or RGB) and no tRNS chunk. Other sites
// show the card on any background, so it must cover its rectangle.
site_png_is_opaque :: proc(data: []u8) -> bool {
	if _, _, is_png := site_png_size(data); !is_png || len(data) < 26 {
		return false
	}
	color_type := data[25]
	if color_type != 0 && color_type != 2 {
		return false
	}
	offset := 8
	for offset + 8 <= len(data) {
		length := int(data[offset]) << 24 | int(data[offset + 1]) << 16 | int(data[offset + 2]) << 8 | int(data[offset + 3])
		chunk_type := string(data[offset + 4:offset + 8])
		if chunk_type == "tRNS" {
			return false
		}
		if chunk_type == "IEND" || length < 0 || length > len(data) {
			break
		}
		offset += 12 + length
	}
	return true
}

// site_meta_content gives the value of the first "<meta property=...>" of
// a page with this property, as the head writes it.
site_meta_content :: proc(html, property: string) -> (value: string, found: bool) {
	prefix := strings.concatenate({"<meta property=\"", property, "\" content=\""}, context.temp_allocator)
	start := strings.index(html, prefix)
	if start < 0 {
		return "", false
	}
	rest := html[start + len(prefix):]
	end := strings.index_byte(rest, '"')
	if end < 0 {
		return "", false
	}
	return site_html_unescape(rest[:end]), true
}

// site_structured_data_texts gives the text inside each JSON-LD script of a
// page.
site_structured_data_texts :: proc(html: string) -> []string {
	texts := make([dynamic]string, context.temp_allocator)
	rest := html
	for {
		start := strings.index(rest, SITE_STRUCTURED_DATA_OPEN)
		if start < 0 {
			break
		}
		rest = rest[start + len(SITE_STRUCTURED_DATA_OPEN):]
		end := strings.index(rest, SITE_SCRIPT_CLOSE)
		if end < 0 {
			append(&texts, "")
			break
		}
		append(&texts, rest[:end])
		rest = rest[end:]
	}
	return texts[:]
}

// site_structured_data_walk records each id that a node defines (an object
// with an "@id" and other fields) and each id that a field names (an object
// with only an "@id").
site_structured_data_walk :: proc(value: json.Value, defined: ^map[string]bool, referenced: ^[dynamic]string) {
	#partial switch item in value {
	case json.Object:
		if id, has_id := item["@id"]; has_id {
			if text, is_text := id.(json.String); is_text {
				if len(item) == 1 {
					append(referenced, string(text))
				} else {
					defined^[string(text)] = true
				}
			}
		}
		for _, child in item {
			site_structured_data_walk(child, defined, referenced)
		}
	case json.Array:
		for child in item {
			site_structured_data_walk(child, defined, referenced)
		}
	}
}

// site_structured_data_problems checks the JSON-LD of one page: it parses
// as JSON, it is one graph of schema.org, and each id that a node names is
// a node of the graph or the address of a page of the site.
site_structured_data_problems :: proc(text: string, page_addresses: map[string]bool) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	value, err := json.parse_string(text, .JSON, false, context.temp_allocator)
	if err != nil {
		append(&problems, fmt.tprintf("the JSON-LD does not parse: %v", err))
		return problems[:]
	}
	root, is_object := value.(json.Object)
	if !is_object {
		append(&problems, "the JSON-LD is not an object")
		return problems[:]
	}
	context_text := ""
	if graph_context, has_context := root["@context"]; has_context {
		if context_value, is_text := graph_context.(json.String); is_text {
			context_text = context_value
		}
	}
	if context_text != "https://schema.org" {
		append(&problems, "the JSON-LD has no @context https://schema.org")
	}
	if graph, has_graph := root["@graph"]; !has_graph || !site_is_json_array(graph) {
		append(&problems, "the JSON-LD has no @graph")
	}
	defined := make(map[string]bool, context.temp_allocator)
	referenced := make([dynamic]string, context.temp_allocator)
	site_structured_data_walk(value, &defined, &referenced)
	for id in referenced {
		if id not_in defined && id not_in page_addresses {
			append(&problems, fmt.tprintf("the JSON-LD names the id %s, which is not a node of the graph or a page of the site", id))
		}
	}
	return problems[:]
}

site_is_json_array :: proc(value: json.Value) -> bool {
	_, is_array := value.(json.Array)
	return is_array
}

// site_check_metadata checks what other programs read of the pages:
//   with an address, each page has one canonical address, its own, and no
//   two pages share one; it has Open Graph, and its picture is a picture
//   that the command wrote with the size that the page states; it has one
//   JSON-LD graph that parses and whose ids exist; the sitemap lists each
//   written page once and nothing else;
//   with no address, no page has a canonical address, Open Graph or
//   JSON-LD, and there is no sitemap.
// The picture sizes are those of the PNG files that the command wrote.
site_check_metadata :: proc(address: string, pages: []Site_Page, written: map[string]string, sitemap: string, picture_sizes: map[string][2]int) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	if address == "" {
		for page in pages {
			html := written[page.path]
			if strings.contains(html, "rel=\"canonical\"") || strings.contains(html, "property=\"og:") || strings.contains(html, SITE_STRUCTURED_DATA_OPEN) {
				append(&problems, fmt.tprintf("%s: an absolute address (canonical, Open Graph or JSON-LD) with no address of the site", page.path))
			}
		}
		if sitemap != "" {
			append(&problems, "a sitemap with no address of the site")
		}
		return problems[:]
	}
	page_addresses := make(map[string]bool, context.temp_allocator)
	for page in pages {
		page_addresses[site_page_address(address, page.path)] = true
	}
	canonical_pages := make(map[string]string, context.temp_allocator)
	prefix :: "<link rel=\"canonical\" href=\""
	for page in pages {
		html := written[page.path]
		expected := site_page_address(address, page.path)
		if count := strings.count(html, "<link rel=\"canonical\""); count != 1 {
			append(&problems, fmt.tprintf("%s: %d canonical addresses; a page has one", page.path, count))
		} else {
			canonical := ""
			if start := strings.index(html, prefix); start >= 0 {
				rest := html[start + len(prefix):]
				if end := strings.index_byte(rest, '"'); end >= 0 {
					canonical = site_html_unescape(rest[:end])
				}
			}
			if canonical != expected {
				append(&problems, fmt.tprintf("%s: the canonical address is %s, not %s", page.path, canonical, expected))
			}
			if other, found := canonical_pages[canonical]; found {
				append(&problems, fmt.tprintf("%s: the canonical address is also that of %s", page.path, other))
			}
			canonical_pages[canonical] = page.path
		}
		// Open Graph: its address and its picture.
		if url, has_url := site_meta_content(html, "og:url"); !has_url || url != expected {
			append(&problems, fmt.tprintf("%s: og:url is not the address of the page", page.path))
		}
		for property in ([]string{"og:type", "og:title", "og:description", "og:site_name", "og:image:alt"}) {
			if value, found := site_meta_content(html, property); !found || value == "" {
				append(&problems, fmt.tprintf("%s: no %s", page.path, property))
			}
		}
		image, has_image := site_meta_content(html, "og:image")
		width_text, _ := site_meta_content(html, "og:image:width")
		height_text, _ := site_meta_content(html, "og:image:height")
		width, width_ok := site_decimal(width_text)
		height, height_ok := site_decimal(height_text)
		site_prefix := strings.concatenate({address, "/"}, context.temp_allocator)
		if !has_image || !strings.has_prefix(image, site_prefix) {
			append(&problems, fmt.tprintf("%s: og:image is not a picture of the site", page.path))
		} else if size, is_picture := picture_sizes[image[len(site_prefix):]]; !is_picture {
			append(&problems, fmt.tprintf("%s: og:image names %s, which the command did not write", page.path, image))
		} else if !width_ok || !height_ok || size[0] != width || size[1] != height {
			append(&problems, fmt.tprintf("%s: og:image is %d by %d, and the page states %s by %s", page.path, size[0], size[1], width_text, height_text))
		}
		// The JSON-LD graph.
		texts := site_structured_data_texts(html)
		if len(texts) != 1 {
			append(&problems, fmt.tprintf("%s: %d JSON-LD scripts; a page has one", page.path, len(texts)))
		}
		for text in texts {
			for problem in site_structured_data_problems(text, page_addresses) {
				append(&problems, fmt.tprintf("%s: %s", page.path, problem))
			}
		}
	}
	// The sitemap: each written page once, and nothing else.
	listed := make(map[string]int, context.temp_allocator)
	rest := sitemap
	for {
		start := strings.index(rest, "<loc>")
		if start < 0 {
			break
		}
		rest = rest[start + len("<loc>"):]
		end := strings.index(rest, "</loc>")
		if end < 0 {
			append(&problems, "the sitemap has a <loc> with no end")
			break
		}
		listed[site_html_unescape(rest[:end])] += 1
		rest = rest[end:]
	}
	for listed_address, count in listed {
		if listed_address not_in page_addresses {
			append(&problems, fmt.tprintf("the sitemap lists %s, which is not a page that the command writes", listed_address))
		}
		if count > 1 {
			append(&problems, fmt.tprintf("the sitemap lists %s %d times", listed_address, count))
		}
	}
	for page_address in page_addresses {
		if page_address not_in listed {
			append(&problems, fmt.tprintf("the sitemap does not list %s", page_address))
		}
	}
	return problems[:]
}
