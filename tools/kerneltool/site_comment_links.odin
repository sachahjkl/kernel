// The links of the source comments (docs/SITE.md, "The links of a
// comment"). A comment writes "[text](target)" when the text of the link is
// not the name of what it names; a code span that is a name already links
// by itself. The target is a place of the site, or an address of another
// host. A link is a claim of its author: a target that names nothing stops
// `kerneltool site` with its file and its line, where a code span that
// names nothing stays code.
package kerneltool

import "core:fmt"
import "core:strings"

// The prefix of a target that names a term of the glossary: "term:handle".
SITE_TERM_TARGET_PREFIX :: "term:"

// What the target of a link of a comment names.
Site_Comment_Link_Kind :: enum {
	Address, // An address of another host.
	Page, // A page of the site, with an anchor or none.
	Term, // A term of the glossary: its entry, with its short definition.
	Declaration, // A declaration of the sources: its link and its card.
	Type, // A type of the contract: its type card.
}

Site_Comment_Link :: struct {
	kind:     Site_Comment_Link_Kind,
	address:    string, // Address: the address; Page, Term: the file of the page from the root, with its anchor.
	place:      int, // Declaration: its place in the declaration index.
	type_key:   string, // Type: the key of its card.
	definition: string, // Term: its short definition, as the reader of the glossary gives it.
}

// site_comment_link_target finds what the target of a link of a comment
// names, or gives why it names nothing. The forms:
//   "https://..." or "http://...": an address of another host;
//   "term:<term>": a term of the glossary, by its name with no regard to case;
//   "docs/<NAME>.md" or "docs/<NAME>.md#<id>": a guide, or a heading of it by
//   the id of the heading on its page;
//   a name: a kernel operation, an error kind, a module or a command of the
//   console ("load()"), as a code span names a row; "<module>.<export>", an
//   export of a module; else a declaration of the sources ("fault_deliver",
//   "operation.Fault_Record", "system.word_wait"), resolved as a code span
//   of a comment is, with no folder around it.
site_comment_link_target :: proc(site: ^Site, target: string) -> (link: Site_Comment_Link, problem: string) {
	if site == nil {
		return {}, "the site is not read"
	}
	if strings.has_prefix(target, "https://") || strings.has_prefix(target, "http://") {
		return {kind = .Address, address = target}, ""
	}
	if strings.has_prefix(target, SITE_TERM_TARGET_PREFIX) {
		name := target[len(SITE_TERM_TARGET_PREFIX):]
		for term in site.terms {
			if site_slug(term.name) == site_slug(name) {
				return {kind = .Term, address = strings.concatenate({term.page, "#", term.id}, context.temp_allocator), definition = term.definition}, ""
			}
		}
		return {}, fmt.tprintf("no term of the glossary is \"%s\"", name)
	}
	if strings.has_prefix(target, "docs/") {
		path, anchor := target, ""
		if hash := strings.index_byte(target, '#'); hash >= 0 {
			path, anchor = target[:hash], target[hash + 1:]
		}
		page, is_page := site.documents[path]
		if !is_page {
			if site_is_working_record(path) {
				return {}, fmt.tprintf("%s is a working record, not a page of the site", path)
			}
			return {}, fmt.tprintf("%s is not a document of the site", path)
		}
		if anchor == "" {
			return {kind = .Page, address = page}, ""
		}
		if !site_document_has_id(site, path, anchor) {
			return {}, fmt.tprintf("%s has no heading with the id \"%s\"", path, anchor)
		}
		if path == SITE_GLOSSARY_FILE {
			// A term and a group are on the page of their group.
			page = site_glossary_anchor_page(site, anchor)
		}
		return {kind = .Page, address = strings.concatenate({page, "#", anchor}, context.temp_allocator)}, ""
	}
	if row, is_row := site_code_link(site, target); is_row {
		return {kind = .Page, address = row}, ""
	}
	if period := strings.index_byte(target, '.'); period > 0 {
		module_name, export_name := target[:period], target[period + 1:]
		for item in site.reference.modules {
			if item.build.name != module_name {
				continue
			}
			for export in item.description.exports {
				if export.name == export_name {
					return {kind = .Page, address = strings.concatenate({item.page, "#export-", site_slug(export.name)}, context.temp_allocator)}, ""
				}
			}
			// A name of a module and a package (`system`) can still name a
			// declaration of the package.
		}
	}
	span, is_name := site_declaration_span_read(target)
	if !is_name {
		return {}, "the target is not an address, a term (term:<name>), a guide (docs/<NAME>.md#<id>) or a name"
	}
	place, resolution := site_declaration_resolve(&site.declarations, span, nil)
	switch resolution {
	case .Linked:
		if key := site_declaration_type_key(site, site.declarations.declarations[place]); key != "" {
			return {kind = .Type, type_key = key}, ""
		}
		return {kind = .Declaration, place = place}, ""
	case .Ambiguous:
		return {}, fmt.tprintf("\"%s\" names several declarations, or is a common word: name its package (package.name) or call it (name())", target)
	case .Not_Found:
	}
	return {}, fmt.tprintf("\"%s\" names no kernel operation, error kind, module, export, command of the console or declaration", target)
}

// site_document_has_id tells whether the page of a document has an element
// with an id: a heading of a guide, or a heading or a term of the glossary.
site_document_has_id :: proc(site: ^Site, path, id: string) -> bool {
	if path == SITE_GLOSSARY_FILE {
		for term in site.terms {
			if term.id == id {
				return true
			}
		}
	}
	for heading in site_document_outline(site, path).headings {
		if heading.id == id {
			return true
		}
	}
	return false
}

// site_comment_link_write writes a link of a source comment: its label as
// the text of a link to what its target names. A link to a declaration has
// its card, and a link to a type of the contract is its type card, as a
// code span that names them. A target that names nothing writes the label
// alone: the check of the comments has stopped the command before.
site_comment_link_write :: proc(renderer: ^Site_Renderer, label, target: string) {
	b := &renderer.builder
	link, problem := site_comment_link_target(renderer.site, target)
	if problem != "" {
		site_render_inline_plain(renderer, label)
		return
	}
	site := renderer.site
	switch link.kind {
	case .Address:
		strings.write_string(b, "<a href=\"")
		site_escape(b, link.address)
		strings.write_string(b, "\">")
		site_render_inline_plain(renderer, label)
		strings.write_string(b, "</a>")
	case .Page:
		strings.write_string(b, "<a href=\"")
		site_escape(b, site_page_link(site, renderer.page, link.address))
		strings.write_string(b, "\">")
		site_render_inline_plain(renderer, label)
		strings.write_string(b, "</a>")
	case .Term:
		// The same markup as a term that a guide links: its short definition
		// is the tooltip of the link.
		strings.write_string(b, "<a class=\"term\" href=\"")
		site_escape(b, site_page_link(site, renderer.page, link.address))
		strings.write_string(b, "\"")
		if link.definition != "" {
			strings.write_string(b, " title=\"")
			site_plain(b, link.definition)
			strings.write_string(b, "\"")
		}
		strings.write_string(b, ">")
		site_render_inline_plain(renderer, label)
		strings.write_string(b, "</a>")
	case .Declaration:
		declaration := site.declarations.declarations[link.place]
		id := site_declaration_card_id(link.place)
		strings.write_string(b, "<a class=\"declaration-reference\" href=\"")
		site_escape(b, site_declaration_address(site, renderer.page, declaration))
		fmt.sbprintf(b, "\" data-declaration-card=\"%s\" aria-describedby=\"%s%s\">", id, id, SITE_TYPE_CARD_SUMMARY_SUFFIX)
		site_render_inline_plain(renderer, label)
		strings.write_string(b, "</a>")
	case .Type:
		site_type_reference(site, b, link.type_key, markdown_inline_plain(label, false), true)
	}
}

// site_comment_links gives each link "[label](target)" of the text of a
// comment, outside its code spans, with the byte where it starts.
site_comment_links :: proc(text: string) -> (targets: []string, starts: []int) {
	target_list := make([dynamic]string, context.temp_allocator)
	start_list := make([dynamic]int, context.temp_allocator)
	index := 0
	for index < len(text) {
		switch text[index] {
		case '`':
			end := strings.index_byte(text[index + 1:], '`')
			if end < 0 {
				index = len(text)
				continue
			}
			index += end + 2
			continue
		case '[':
			if _, target, end, found := markdown_link_at(text, index); found {
				append(&target_list, target)
				append(&start_list, index)
				index = end
				continue
			}
		}
		index += 1
	}
	return target_list[:], start_list[:]
}

// site_comment_link_problems reads the comments of one source file: each
// link whose target names nothing is a problem, with the line where the
// link starts. The lines of comment that follow each other are one text,
// as the site joins them.
site_comment_link_problems :: proc(site: ^Site, file, content: string) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	syntax, known := comment_syntax_of(file)
	if !known {
		return problems[:]
	}
	for block in comment_blocks(content, syntax) {
		targets, starts := site_comment_links(block.text)
		for target, index in targets {
			if _, problem := site_comment_link_target(site, target); problem != "" {
				append(&problems, fmt.tprintf("%s, line %d: the link to %s names nothing: %s", file, comment_block_line(block, starts[index]), target, problem))
			}
		}
	}
	return problems[:]
}
