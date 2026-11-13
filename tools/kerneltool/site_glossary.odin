// The page of the glossary (docs/SITE.md, "The glossary"), written from the
// terms that glossary_read gives.
package kerneltool

import "core:fmt"
import "core:strings"

// site_glossary_write writes the page of the glossary: each group a
// section, each term an entry with its anchor, its short definition set
// apart, its explanation, and the words that it replaces. The list "On this
// page" reads the headings, so it is the index of the terms.
site_glossary_write :: proc(renderer: ^Site_Renderer, glossary: Glossary) {
	b := &renderer.builder
	if glossary.introduction != "" {
		site_render_markdown(renderer, glossary.introduction, glossary.introduction_line)
	}
	for group in glossary.groups {
		group_id := site_unique_id(renderer, group.id)
		renderer.section = group_id
		append(&renderer.headings, Site_Heading{level = 2, text = group.name, id = group_id})
		fmt.sbprintf(b, "<section class=\"glossary-group\" aria-labelledby=\"%s\">\n<h2 id=\"%s\">", group_id, group_id)
		site_escape(b, group.name)
		strings.write_string(b, "</h2>\n")
		if group.introduction != "" {
			site_render_markdown(renderer, group.introduction, group.introduction_line)
		}
		for term in group.terms {
			renderer.ids[term.id] = true
			// An entry links the first use of each other term in it: a
			// reader who opens one entry finds its neighbours there. It
			// never links its own term.
			clear(&renderer.linked_terms)
			renderer.linked_terms[term.id] = true
			append(&renderer.headings, Site_Heading{level = 3, text = term.name, id = term.id, first_paragraph = term.definition})
			fmt.sbprintf(b, "<div class=\"term-entry\">\n<h3 id=\"%s\">", term.id)
			site_escape(b, term.name)
			strings.write_string(b, "</h3>\n<p class=\"term-definition\">")
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
		strings.write_string(b, "</section>\n")
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
