// The pages of the glossary (docs/SITE.md, "The glossary"), written from the
// terms that glossary_read gives: one page for each group with its entries,
// and an index that lists every term from A to Z.
package kerneltool

import "core:fmt"
import "core:slice"
import "core:strings"

// The script of the index of the glossary: it sends an address of an entry
// at the index to the page of the group of the term. The index is whole
// with no script.
SITE_GLOSSARY_SCRIPT :: "glossary.js"

// The most bytes of one page of the glossary, before compression. The
// glossary was one page; when its explanations made it larger than this, it
// became one page for each group.
SITE_GLOSSARY_PAGE_BYTE_LIMIT :: 1_000_000

// The attribute of a row of the index that names the page of the group of
// its term, relative to the index: the script reads it.
SITE_GLOSSARY_GROUP_PAGE_ATTRIBUTE :: "data-group-page"

// site_glossary_group_page gives the page of a group: a folder under the
// glossary, named by the slug of the heading of the group.
site_glossary_group_page :: proc(group_id: string) -> string {
	return site_page_file(strings.concatenate({SITE_GLOSSARY_FOLDER, "/", group_id}, context.temp_allocator))
}

// site_glossary_page_paths gives the pages of the glossary: the index, then
// the page of each group in the order of the file.
site_glossary_page_paths :: proc(glossary: Glossary) -> []string {
	paths := make([dynamic]string, context.temp_allocator)
	append(&paths, site_page_file(SITE_GLOSSARY_FOLDER))
	for group in glossary.groups {
		append(&paths, site_glossary_group_page(group.id))
	}
	return paths[:]
}

// site_glossary_group_of_page gives the place of the group whose page is
// path in the groups of the glossary, or -1.
site_glossary_group_of_page :: proc(glossary: Glossary, path: string) -> int {
	for group, index in glossary.groups {
		if site_glossary_group_page(group.id) == path {
			return index
		}
	}
	return -1
}

// site_glossary_anchor_page gives the page that holds an id of the
// glossary: the page of the group for a term or a group, else the index.
site_glossary_anchor_page :: proc(site: ^Site, id: string) -> string {
	for group in site.glossary.groups {
		if group.id == id {
			return site_glossary_group_page(group.id)
		}
		for term in group.terms {
			if term.id == id {
				return site_glossary_group_page(group.id)
			}
		}
	}
	return site_page_file(SITE_GLOSSARY_FOLDER)
}

// site_glossary_term_count_words gives "1 term", "42 terms" or "no term".
site_glossary_term_count_words :: proc(count: int) -> string {
	switch count {
	case 0:
		return "no term"
	case 1:
		return "1 term"
	}
	return fmt.tprintf("%d terms", count)
}

// site_glossary_write writes the entries of one group: each term an entry
// with its anchor, its short definition set apart, its explanation, and the
// words that it replaces. The list "On this page" reads the headings, so it
// is the list of the terms of the group.
site_glossary_write :: proc(renderer: ^Site_Renderer, group: Glossary_Group) {
	b := &renderer.builder
	if group.introduction != "" {
		site_render_markdown(renderer, group.introduction, group.introduction_line)
	}
	for term in group.terms {
		renderer.ids[term.id] = true
		// An entry links the first use of each other term in it: a reader
		// who opens one entry finds its neighbours there. It never links
		// its own term.
		clear(&renderer.linked_terms)
		renderer.linked_terms[term.id] = true
		append(&renderer.headings, Site_Heading{level = 2, text = term.name, id = term.id, first_paragraph = term.definition})
		fmt.sbprintf(b, "<div class=\"term-entry\">\n<h2 id=\"%s\">", term.id)
		site_escape(b, term.name)
		strings.write_string(b, "</h2>\n<p class=\"term-definition\">")
		site_render_inline(renderer, term.definition)
		strings.write_string(b, "</p>\n")
		if term.explanation != "" {
			site_render_markdown(renderer, term.explanation, term.explanation_line)
		}
		if term.avoided != "" {
			strings.write_string(b, "<p class=\"term-avoided\"><span class=\"term-avoided-label\">Do not use</span> ")
			site_glossary_avoided_write(b, term.avoided)
			strings.write_string(b, "</p>\n")
		}
		strings.write_string(b, "</div>\n")
	}
}

// site_glossary_avoided_write writes the words that a term replaces. A word
// in code marks is code, the rest is text. No word links: these words name
// what the system does not call its concept.
site_glossary_avoided_write :: proc(b: ^strings.Builder, words: string) {
	rest := words
	for {
		open := strings.index_byte(rest, '`')
		if open < 0 {
			break
		}
		closing := strings.index_byte(rest[open + 1:], '`')
		if closing < 0 {
			break
		}
		site_escape(b, rest[:open])
		strings.write_string(b, "<code>")
		site_escape(b, rest[open + 1:open + 1 + closing])
		strings.write_string(b, "</code>")
		rest = rest[open + 1 + closing + 1:]
	}
	site_escape(b, rest)
}

// site_glossary_name_less orders two names of terms as a dictionary does:
// the letters with no regard to case.
site_glossary_name_less :: proc(a, b: string) -> bool {
	for index in 0 ..< min(len(a), len(b)) {
		left, right := site_lower(a[index]), site_lower(b[index])
		if left != right {
			return left < right
		}
	}
	return len(a) < len(b)
}

// site_glossary_letter gives the letter under which the index lists a
// name: its first letter in upper case, or "#" for a name that starts with
// a digit or a sign.
site_glossary_letter :: proc(name: string) -> string {
	if name == "" {
		return "#"
	}
	first := name[0]
	if first >= 'a' && first <= 'z' {
		first -= 'a' - 'A'
	}
	if first >= 'A' && first <= 'Z' {
		return fmt.tprintf("%c", rune(first))
	}
	return "#"
}

// site_glossary_letter_id gives the id of the heading of a letter of the
// index.
site_glossary_letter_id :: proc(letter: string) -> string {
	if letter == "#" {
		return "letter-signs"
	}
	return strings.concatenate({"letter-", site_slug(letter)}, context.temp_allocator)
}

// site_glossary_index_write writes the index of the glossary: the
// introduction of the file, how to find a term, the groups with their
// counts, then every term from A to Z with its short definition. A reader
// looks for a word, so the order is the order of the words; the group of
// each term is a dim label. Each row has the anchor of its term, as the
// entry on the page of the group has: an address of an entry that names the
// index, from before the split, finds the row with no script, and the
// script of the page goes on to the entry.
site_glossary_index_write :: proc(site: ^Site, index_page: string) -> string {
	glossary := site.glossary
	renderer := site_renderer_make(site, index_page, SITE_GLOSSARY_FILE)
	// The index links each term by its own row: no word of a definition
	// links a term, so that a link to a term never names the index.
	for term in site.terms {
		renderer.linked_terms[term.id] = true
	}
	terms := slice.clone(glossary_terms_in_order(glossary), context.temp_allocator)
	slice.stable_sort_by(terms, proc(a, b: Glossary_Term) -> bool {return site_glossary_name_less(a.name, b.name)})
	for term in terms {
		renderer.ids[term.id] = true
	}
	title_id := site_unique_id(&renderer, site_slug(glossary.title))
	groups_id := site_unique_id(&renderer, "groups")
	terms_id := site_unique_id(&renderer, "terms-from-a-to-z")

	b := &renderer.builder
	strings.write_string(b, "<article class=\"prose\">\n")
	fmt.sbprintf(b, "<h1 id=\"%s\">", title_id)
	site_escape(b, glossary.title)
	strings.write_string(b, "</h1>\n")
	if glossary.introduction != "" {
		site_render_markdown(&renderer, glossary.introduction, glossary.introduction_line)
	}
	fmt.sbprintf(b, "<p>To find a term, look for its word in the <a href=\"#%s\">list from A to Z</a>, or type it in the search. A term on any page of the site links to its entry at its first use. The entries are on %d pages, one for each <a href=\"#%s\">group</a> of concepts; each page lists its terms under \"On this page\".</p>\n", terms_id, len(glossary.groups), groups_id)

	// The groups, in the order of the file.
	fmt.sbprintf(b, "<h2 id=\"%s\">The groups</h2>\n<ul class=\"glossary-groups\">\n", groups_id)
	for group in glossary.groups {
		fmt.sbprintf(b, "<li><a href=\"%s\">", site_page_link(site, index_page, site_glossary_group_page(group.id)))
		site_escape(b, group.name)
		fmt.sbprintf(b, "</a> <span class=\"glossary-count\">%s</span></li>\n", site_glossary_term_count_words(len(group.terms)))
	}
	strings.write_string(b, "</ul>\n")

	// The letters, then the terms under each letter.
	letters := make([dynamic]string, context.temp_allocator)
	for term in terms {
		letter := site_glossary_letter(term.name)
		if len(letters) == 0 || letters[len(letters) - 1] != letter {
			append(&letters, letter)
		}
	}
	fmt.sbprintf(b, "<h2 id=\"%s\">The terms from A to Z</h2>\n<nav class=\"glossary-letters\" aria-label=\"Letters\">\n", terms_id)
	for letter in letters {
		fmt.sbprintf(b, "<a href=\"#%s\">%s</a>\n", site_glossary_letter_id(letter), letter)
	}
	strings.write_string(b, "</nav>\n")
	current_letter := ""
	for term in terms {
		letter := site_glossary_letter(term.name)
		if letter != current_letter {
			if current_letter != "" {
				strings.write_string(b, "</dl>\n")
			}
			letter_id := site_unique_id(&renderer, site_glossary_letter_id(letter))
			fmt.sbprintf(b, "<h3 id=\"%s\">%s</h3>\n<dl class=\"glossary-index\">\n", letter_id, letter)
			current_letter = letter
		}
		group_link := site_page_link(site, index_page, site_glossary_group_page(term.group_id))
		fmt.sbprintf(b, "<div id=\"%s\" %s=\"%s\">\n<dt><a href=\"%s#%s\">", term.id, SITE_GLOSSARY_GROUP_PAGE_ATTRIBUTE, group_link, group_link, term.id)
		site_escape(b, term.name)
		strings.write_string(b, "</a> <span class=\"glossary-index-group\">")
		site_escape(b, term.group)
		strings.write_string(b, "</span></dt>\n<dd>")
		site_render_inline(&renderer, term.definition)
		strings.write_string(b, "</dd>\n</div>\n")
	}
	if current_letter != "" {
		strings.write_string(b, "</dl>\n")
	}
	strings.write_string(b, "</article>\n")
	return strings.to_string(renderer.builder)
}

// site_glossary_pages_add adds the page of each group and the index of the
// glossary, and gives the entry of the index in the reference.
site_glossary_pages_add :: proc(site: ^Site) -> Site_Reference_Entry {
	glossary := site.glossary
	index_page := site_page_file(SITE_GLOSSARY_FOLDER)
	title := glossary.title
	term_count := len(glossary_terms_in_order(glossary))
	group_crumbs := make([dynamic]Site_Crumb, context.temp_allocator)
	append(&group_crumbs, ..site_crumbs(.Reference))
	append(&group_crumbs, Site_Crumb{title = title, path = index_page})

	for group, group_index in glossary.groups {
		path := site_glossary_group_page(group.id)
		renderer := site_renderer_make(site, path, SITE_GLOSSARY_FILE)
		renderer.glossary = true
		renderer.ids[group.id] = true
		site_glossary_write(&renderer, group)
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "<article class=\"prose\">\n")
		fmt.sbprintf(&b, "<h1 id=\"%s\">", group.id)
		site_escape(&b, group.name)
		fmt.sbprintf(&b, "</h1>\n<p class=\"glossary-group-place\">A group of the <a href=\"%s\">glossary</a>, with %s. The index of the glossary lists the terms of every group from A to Z.</p>\n", site_page_link(site, path, index_page), site_glossary_term_count_words(len(group.terms)))
		strings.write_string(&b, strings.to_string(renderer.builder))
		strings.write_string(&b, "</article>\n<nav class=\"neighbours\" aria-label=\"Other groups of the glossary\">\n")
		if group_index > 0 {
			previous := glossary.groups[group_index - 1]
			fmt.sbprintf(&b, "<a rel=\"prev\" href=\"%s\">Previous: ", site_page_link(site, path, site_glossary_group_page(previous.id)))
			site_escape(&b, previous.name)
			strings.write_string(&b, "</a>\n")
		}
		if group_index + 1 < len(glossary.groups) {
			next := glossary.groups[group_index + 1]
			fmt.sbprintf(&b, "<a rel=\"next\" href=\"%s\">Next: ", site_page_link(site, path, site_glossary_group_page(next.id)))
			site_escape(&b, next.name)
			strings.write_string(&b, "</a>\n")
		}
		strings.write_string(&b, "</nav>\n")
		description := site_description_cut(fmt.tprintf("The group %s of the glossary of %s: %s, each with its definition, what it is for, how it differs from the word of other systems, and the words that it replaces.", group.name, SITE_SYSTEM_NAME, site_glossary_term_count_words(len(group.terms))))
		site_page_add(site, Site_Page{path = path, title = fmt.tprintf("%s: %s", title, group.name), description = description, section = .Reference, crumbs = group_crumbs[:], body = strings.to_string(b), sources = site_sources(SITE_GLOSSARY_FILE), layout = .Documentation})
	}

	description := site_description_cut(fmt.tprintf("The %d terms of %s from A to Z: one term for each concept, with its short definition and a link to its entry in one of the %d groups.", term_count, SITE_SYSTEM_NAME, len(glossary.groups)))
	site_page_add(site, Site_Page{path = index_page, title = title, description = description, section = .Reference, crumbs = site_crumbs(.Reference), body = site_glossary_index_write(site, index_page), sources = site_sources(SITE_GLOSSARY_FILE), layout = .Documentation, script = SITE_GLOSSARY_SCRIPT})
	return Site_Reference_Entry{path = index_page, title = title, what = "Each term of the project: its definition, what it is for, and how it works. A term on another page links here.", source = SITE_GLOSSARY_FILE, count = term_count, kind = .Term}
}

// site_glossary_problems checks the pages of the glossary as the command
// writes them: each page is written and has at most
// SITE_GLOSSARY_PAGE_BYTE_LIMIT bytes; the index has one row for each term,
// with the anchor of the term and the page of its group; and the page of
// the group has the entry at the same anchor.
site_glossary_problems :: proc(site: ^Site, written: map[string]string) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	for path in site_glossary_page_paths(site.glossary) {
		html, found := written[path]
		if !found {
			append(&problems, fmt.tprintf("%s: a page of the glossary that the command does not write", path))
			continue
		}
		if len(html) > SITE_GLOSSARY_PAGE_BYTE_LIMIT {
			append(&problems, fmt.tprintf("%s: %d bytes; a page of the glossary has at most %d", path, len(html), SITE_GLOSSARY_PAGE_BYTE_LIMIT))
		}
	}
	index_page := site_page_file(SITE_GLOSSARY_FOLDER)
	index_html := written[index_page]
	for group in site.glossary.groups {
		group_page := site_glossary_group_page(group.id)
		group_html := written[group_page]
		group_link := site_page_link(site, index_page, group_page)
		for term in group.terms {
			id_attribute := fmt.tprintf(" id=\"%s\"", term.id)
			if count := strings.count(index_html, id_attribute); count != 1 {
				append(&problems, fmt.tprintf("%s: %d elements with the id %s; the index has one row for each term", index_page, count, term.id))
			}
			row := fmt.tprintf("<div id=\"%s\" %s=\"%s\">", term.id, SITE_GLOSSARY_GROUP_PAGE_ATTRIBUTE, group_link)
			if !strings.contains(index_html, row) {
				append(&problems, fmt.tprintf("%s: the row of the term %q does not name the page of its group, %s", index_page, term.name, group_link))
			}
			if count := strings.count(group_html, id_attribute); count != 1 {
				append(&problems, fmt.tprintf("%s: %d elements with the id %s; the page of the group %q has the entry of each of its terms once", group_page, count, term.id, group.name))
			}
		}
	}
	return problems[:]
}

// site_glossary_script gives the script of the index of the glossary. An
// address of an entry that names the index (a link of another site, a page
// in a cache, a search engine) finds the row of the term, whose attribute
// names the page of its group: the script goes there, with the same anchor,
// and replaces the address in the history, so that "back" does not come
// again to the index. A row is data in the page: the script needs no second
// file.
site_glossary_script :: proc() -> string {
	return `// The glossary is one page for each group. An address of an entry at
// the index goes to the entry on the page of its group.
(function () {
  "use strict";
  function follow() {
    var hash = window.location.hash;
    if (hash.indexOf("#term-") !== 0) {
      return;
    }
    var id;
    try {
      id = decodeURIComponent(hash.slice(1));
    } catch (error) {
      return;
    }
    var row = document.getElementById(id);
    if (!row) {
      return;
    }
    var page = row.getAttribute("` + SITE_GLOSSARY_GROUP_PAGE_ATTRIBUTE + `");
    if (page) {
      window.location.replace(page + hash);
    }
  }
  follow();
  window.addEventListener("hashchange", follow);
})();
`
}
