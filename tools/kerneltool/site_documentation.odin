// The layout of a documentation page (docs/SITE.md, "The two layouts"): the
// tree of the documentation at the left, the text in the middle, and the
// list "On this page" at the right. Also the documented symbols of the
// reference pages, the versions of the files that change between builds,
// and the check of the layout of a page.
package kerneltool

import "core:fmt"
import "core:strings"
import "contract:blake3"

// The starts of the tree and of the list "On this page": the check of a
// page counts them, so each one is written by this file only.
SITE_TREE_OPEN :: "<nav class=\"tree\" aria-label=\"Documentation\">"
SITE_OUTLINE_OPEN :: "<details class=\"outline\">"
SITE_OUTLINE_LIST_OPEN :: "<nav class=\"outline-list\" aria-label=\"On this page\">"

// The files of the site whose bytes change between builds. A proxy keeps a
// file for hours, so each link to one of them carries a version of its
// bytes: the same bytes give the same address, new bytes a new address.
SITE_VERSIONED_FILES :: [?]string{SITE_STYLE_SHEET, SITE_SEARCH_SCRIPT, SITE_MARK_ANIMATION_SCRIPT, SITE_SEARCH_INDEX}
// The bytes of the hash in a version: 8 bytes, 16 hexadecimal digits.
SITE_VERSION_BYTES :: 8

// The two layouts of a page. The writer of a page states its layout.
Site_Layout :: enum {
	Presentation, // The home, the news, the releases: one centred column.
	Documentation, // A guide, a reference page, a module page, the status and their index pages: the tree, the text, "On this page".
}

// The groups of the modules, in the tree and on the index of the modules.
Site_Module_Group :: enum {
	Kernel,
	Program,
	Module,
}

site_module_group_titles := [Site_Module_Group]string {
	.Kernel  = "Kernel",
	.Program = "Programs",
	.Module  = "Modules",
}

site_module_group_ids := [Site_Module_Group]string {
	.Kernel  = "kernel",
	.Program = "programs",
	.Module  = "modules",
}

// site_module_group gives the group of a module: a kernel runs in kernel
// mode, a program has its source in programs/, each other one is a module.
site_module_group :: proc(item: Site_Module) -> Site_Module_Group {
	if item.build.kernel {
		return .Kernel
	}
	if item.kind == "program" {
		return .Program
	}
	return .Module
}

// site_bytes_version gives the version of the bytes of a file: the first
// bytes of their BLAKE3 hash, in hexadecimal.
site_bytes_version :: proc(data: []u8) -> string {
	hash := blake3.hash(data)
	builder := strings.builder_make(context.temp_allocator)
	for index in 0 ..< SITE_VERSION_BYTES {
		fmt.sbprintf(&builder, "%02x", hash[index])
	}
	return strings.to_string(builder)
}

// site_file_link gives the link from a page to a file of the site that is
// not a page, with the version of its bytes when it is a versioned file.
// The check of the links ignores the query.
site_file_link :: proc(site: ^Site, from_page, file: string) -> string {
	link := site_relative(from_page, file)
	if version, found := site.file_versions[file]; found {
		return strings.concatenate({link, "?v=", version}, context.temp_allocator)
	}
	return link
}

// site_tree_link writes one link of the tree, marked when it names the
// page that holds the tree.
site_tree_link :: proc(site: ^Site, b: ^strings.Builder, from_page, target, title: string, is_code: bool) {
	strings.write_string(b, "<a href=\"")
	strings.write_string(b, site_page_link(site, from_page, target))
	strings.write_byte(b, '"')
	if from_page == target {
		strings.write_string(b, " aria-current=\"page\"")
	}
	strings.write_byte(b, '>')
	if is_code {
		strings.write_string(b, "<code>")
		site_escape(b, title)
		strings.write_string(b, "</code>")
	} else {
		site_plain(b, title)
	}
	strings.write_string(b, "</a>")
}

// site_tree_html writes the tree of the documentation: the guides in their
// reading order, the reference pages, the modules in their groups, and the
// status. It is generated from the pages that exist, so it is the same on
// each documentation page but for the mark of the current page and the
// group of modules that is open.
site_tree_html :: proc(site: ^Site, page: Site_Page) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, SITE_TREE_OPEN)
	strings.write_string(&b, "\n<ul class=\"tree-sections\">\n")

	guides_page := site_section_page(.Guides)
	if site_page_exists(site, guides_page) {
		strings.write_string(&b, "<li>")
		site_tree_link(site, &b, page.path, guides_page, site_section_titles[.Guides], false)
		strings.write_string(&b, "\n<ul>\n")
		for guide in site.guides {
			strings.write_string(&b, "<li>")
			site_tree_link(site, &b, page.path, guide.path, guide.title, false)
			strings.write_string(&b, "</li>\n")
		}
		strings.write_string(&b, "</ul>\n</li>\n")
	}

	modules_page := site_page_file(SITE_MODULES_FOLDER)
	reference_page := site_section_page(.Reference)
	if site_page_exists(site, reference_page) {
		strings.write_string(&b, "<li>")
		site_tree_link(site, &b, page.path, reference_page, site_section_titles[.Reference], false)
		strings.write_string(&b, "\n<ul>\n")
		for entry in site.reference_entries {
			if entry.path == modules_page {
				continue // The modules have their own part of the tree.
			}
			strings.write_string(&b, "<li>")
			site_tree_link(site, &b, page.path, entry.path, entry.title, false)
			strings.write_string(&b, "</li>\n")
		}
		strings.write_string(&b, "</ul>\n</li>\n")
	}

	if len(site.reference.modules) > 0 && site_page_exists(site, modules_page) {
		strings.write_string(&b, "<li>")
		site_tree_link(site, &b, page.path, modules_page, "Modules", false)
		strings.write_string(&b, "\n<ul class=\"tree-groups\">\n")
		for group in Site_Module_Group {
			count := 0
			holds_current := false
			for item in site.reference.modules {
				if site_module_group(item) == group {
					count += 1
					holds_current ||= item.page == page.path
				}
			}
			if count == 0 {
				continue
			}
			// A group is closed unless it holds the current page: the tree
			// stays short, and the page that the reader is on is in view.
			open_attribute: string = holds_current ? " open" : ""
			fmt.sbprintf(&b, "<li><details class=\"tree-group\"%s><summary>%s <span class=\"tree-count\">%d</span></summary>\n<ul>\n", open_attribute, site_module_group_titles[group], count)
			for item in site.reference.modules {
				if site_module_group(item) != group {
					continue
				}
				strings.write_string(&b, "<li>")
				site_tree_link(site, &b, page.path, item.page, item.build.name, true)
				strings.write_string(&b, "</li>\n")
			}
			strings.write_string(&b, "</ul>\n</details></li>\n")
		}
		strings.write_string(&b, "</ul>\n</li>\n")
	}

	status_page := site_section_page(.Status)
	if site_page_exists(site, status_page) {
		strings.write_string(&b, "<li>")
		site_tree_link(site, &b, page.path, status_page, site_section_titles[.Status], false)
		strings.write_string(&b, "</li>\n")
	}
	strings.write_string(&b, "</ul>\n</nav>\n")
	return strings.to_string(b)
}

// One entry of the list "On this page".
Site_Outline_Entry :: struct {
	id:    string,
	text:  string, // HTML: the escaped text, with no tag.
	level: int, // 2 or 3 for a heading; 0 for a symbol.
}

// site_tag_attribute gives the value of an attribute of one tag, as the
// pages write it (` name="value"`), or "".
site_tag_attribute :: proc(tag, name: string) -> string {
	key := strings.concatenate({" ", name, "=\""}, context.temp_allocator)
	start := strings.index(tag, key)
	if start < 0 {
		return ""
	}
	rest := tag[start + len(key):]
	end := strings.index_byte(rest, '"')
	if end < 0 {
		return ""
	}
	return rest[:end]
}

// site_tags_removed gives an HTML text with no tag. The text of a page is
// escaped, so each "<" and ">" is a part of a tag.
site_tags_removed :: proc(html: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	inside := false
	for index in 0 ..< len(html) {
		character := html[index]
		switch {
		case character == '<':
			inside = true
		case character == '>':
			inside = false
		case !inside:
			strings.write_byte(&b, character)
		}
	}
	return strings.to_string(b)
}

// site_outline_entries reads the list "On this page" from the content of a
// page, in its order: each heading h2 and h3 with an id, and each element
// with an id and a data-outline attribute, a symbol: a documented operation,
// command or export, or a row of a reference table. The writer of a page
// states its symbols with that attribute; nothing is guessed.
site_outline_entries :: proc(body: string) -> []Site_Outline_Entry {
	entries := make([dynamic]Site_Outline_Entry, context.temp_allocator)
	position := 0
	for position < len(body) {
		start := strings.index_byte(body[position:], '<')
		if start < 0 {
			break
		}
		start += position
		end := strings.index_byte(body[start:], '>')
		if end < 0 {
			break
		}
		end += start
		tag := body[start:end + 1]
		position = end + 1
		id := site_tag_attribute(tag, "id")
		if id == "" {
			continue
		}
		if symbol := site_tag_attribute(tag, "data-outline"); symbol != "" {
			append(&entries, Site_Outline_Entry{id = id, text = symbol, level = 0})
			continue
		}
		level := 0
		if len(tag) > 3 && tag[0] == '<' && tag[1] == 'h' && (tag[2] == '2' || tag[2] == '3') && (tag[3] == ' ' || tag[3] == '>') {
			level = int(tag[2] - '0')
		}
		if level == 0 {
			continue
		}
		closing: string = level == 2 ? "</h2>" : "</h3>"
		closing_index := strings.index(body[position:], closing)
		if closing_index < 0 {
			continue
		}
		text := strings.trim_space(site_tags_removed(body[position:position + closing_index]))
		append(&entries, Site_Outline_Entry{id = id, text = text, level = level})
	}
	return entries[:]
}

// site_outline_html writes the list "On this page": the top of the text,
// then the headings and the symbols of the page. It is a details element:
// beside the text on a wide screen, where the style sheet and the script
// show it open, and closed above the text on a narrower screen. With no
// script it is a list of links that its summary opens.
site_outline_html :: proc(page: Site_Page) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, SITE_OUTLINE_OPEN)
	strings.write_string(&b, "\n<summary>On this page</summary>\n")
	strings.write_string(&b, SITE_OUTLINE_LIST_OPEN)
	strings.write_string(&b, "\n<ul>\n<li class=\"outline-top\"><a href=\"#content\" aria-current=\"location\">")
	site_plain(&b, page.title)
	strings.write_string(&b, "</a></li>\n")
	for entry in site_outline_entries(page.body) {
		class: string
		switch entry.level {
		case 2:
			class = "outline-level-2"
		case 3:
			class = "outline-level-3"
		case:
			class = "outline-symbol"
		}
		fmt.sbprintf(&b, "<li class=\"%s\"><a href=\"#%s\">", class, entry.id)
		if entry.level == 0 {
			strings.write_string(&b, "<code>")
			strings.write_string(&b, entry.text)
			strings.write_string(&b, "</code>")
		} else {
			strings.write_string(&b, entry.text)
		}
		strings.write_string(&b, "</a></li>\n")
	}
	strings.write_string(&b, "</ul>\n</nav>\n</details>\n")
	return strings.to_string(b)
}

// site_layout_problem gives the fault of the layout of a written page, or
// "": a documentation page has one tree and one list "On this page", and
// each link of the list names an id of the page; a presentation page has
// neither.
site_layout_problem :: proc(page: Site_Page, html: string, page_ids: map[string]bool) -> string {
	trees := strings.count(html, SITE_TREE_OPEN)
	outlines := strings.count(html, SITE_OUTLINE_OPEN)
	if page.layout == .Presentation {
		if trees != 0 || outlines != 0 {
			return "a presentation page has the tree of the documentation or the list \"On this page\""
		}
		return ""
	}
	if trees != 1 {
		return fmt.tprintf("%d trees of the documentation; a documentation page has one", trees)
	}
	if outlines != 1 {
		return fmt.tprintf("%d lists \"On this page\"; a documentation page has one", outlines)
	}
	start := strings.index(html, SITE_OUTLINE_OPEN)
	end := strings.index(html[start:], "</details>")
	if end < 0 {
		return "the list \"On this page\" has no end"
	}
	links := site_attribute_values(html[start:start + end], "href=\"")
	if len(links) == 0 {
		return "the list \"On this page\" has no link"
	}
	for value in links {
		if len(value) < 2 || value[0] != '#' {
			return fmt.tprintf("the list \"On this page\" has the link \"%s\"; each of its links names an id of the page", value)
		}
		if value[1:] not_in page_ids {
			return fmt.tprintf("the list \"On this page\" names the id \"%s\", which the page does not have", value[1:])
		}
	}
	return ""
}

// One fact of a documented symbol: a label and its HTML, which the writer
// of the fact escaped.
Site_Symbol_Fact :: struct {
	label: string,
	html:  string,
	kind:  Site_Value_Kind, // The kind of its values: the icon of the kind is before the label, once.
}

// A documented symbol: an operation of the kernel, a command, or an export
// of a module, as a package page of a programming language shows one.
Site_Symbol :: struct {
	id:          string, // The id of its heading: the target of the links to it.
	name:        string,
	signature:   string, // "" when the source states none.
	description: string, // The text of its source comment, one paragraph a line; "" when the source has none.
	facts:       []Site_Symbol_Fact,
	source:      string, // Its file in the repository, or "".
	line:        int,
}

// site_symbol_write writes a documented symbol: its name as a heading that
// "On this page" lists, its signature, the text of its source comment, its
// facts and the link to its line in the source. A symbol whose source has
// no comment shows no text: the command counts it.
site_symbol_write :: proc(site: ^Site, b: ^strings.Builder, symbol: Site_Symbol) {
	site.symbol_count += 1
	fmt.sbprintf(b, "<section class=\"symbol\">\n<h3 id=\"%s\" data-outline=\"", symbol.id)
	site_escape(b, symbol.name)
	strings.write_string(b, "\"><code>")
	site_escape(b, symbol.name)
	strings.write_string(b, "</code></h3>\n")
	if symbol.signature != "" {
		strings.write_string(b, "<pre class=\"signature\"><code>")
		site_escape(b, symbol.signature)
		strings.write_string(b, "</code></pre>\n")
	}
	if strings.trim_space(symbol.description) == "" {
		site.symbols_without_description += 1
	}
	for paragraph in strings.split(symbol.description, "\n", context.temp_allocator) {
		if strings.trim_space(paragraph) == "" {
			continue
		}
		strings.write_string(b, "<p>")
		site_escape(b, strings.trim_space(paragraph))
		strings.write_string(b, "</p>\n")
	}
	if len(symbol.facts) > 0 || symbol.source != "" {
		strings.write_string(b, "<dl class=\"symbol-facts\">\n")
		for fact in symbol.facts {
			if fact.kind != .None {
				fmt.sbprintf(b, "<dt class=\"value-head value-icon value-%s\">", site_value_kinds[fact.kind].name)
			} else {
				strings.write_string(b, "<dt>")
			}
			site_escape(b, fact.label)
			strings.write_string(b, "</dt><dd>")
			strings.write_string(b, fact.html)
			strings.write_string(b, "</dd>\n")
		}
		if symbol.source != "" {
			strings.write_string(b, "<dt class=\"value-head value-icon value-file\">Source</dt><dd>")
			if symbol.line > 0 {
				site_value_link(b, .File, site_line_address(site, symbol.source, symbol.line), fmt.tprintf("%s:%d", symbol.source, symbol.line), false)
			} else {
				site_value_link(b, .File, site_repository_file(site, symbol.source), symbol.source, false)
			}
			strings.write_string(b, "</dd>\n")
		}
		strings.write_string(b, "</dl>\n")
	}
	strings.write_string(b, "</section>\n")
}

// site_text_html gives a text as escaped HTML, for a fact of a symbol.
site_text_html :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	site_escape(&b, text)
	return strings.to_string(b)
}

// site_whole_word_at tells whether a name stands at an index of a text as
// a whole word of an identifier: no letter, digit or "_" on either side.
site_whole_word_at :: proc(text: string, index: int, name: string) -> bool {
	if index + len(name) > len(text) || text[index:index + len(name)] != name {
		return false
	}
	if index > 0 && site_is_word_byte(text[index - 1]) {
		return false
	}
	after := index + len(name)
	return after >= len(text) || !site_is_word_byte(text[after])
}

// site_names_in_text gives the names of a list that a text holds as whole
// words, in the order of the list.
site_names_in_text :: proc(text: string, names: []string) -> []string {
	found := make([dynamic]string, context.temp_allocator)
	for name in names {
		for index in 0 ..< len(text) {
			if site_whole_word_at(text, index, name) {
				append(&found, name)
				break
			}
		}
	}
	return found[:]
}
