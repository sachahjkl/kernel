// The roadmap on the site (docs/SITE.md, "The roadmap"): the page of the
// planned work, beside the page of the releases, which lists the work that
// is done. The entries are those of ROADMAP.md (tools/kerneltool/roadmap.odin);
// the site adds no sentence to them.
package kerneltool

import "core:fmt"
import "core:strings"

SITE_ROADMAP_FOLDER :: "roadmap"

// The class of the accent of a section: the mark of each of its cards.
// What is in work has the color of a program, the color of what runs;
// what comes next has the color of the kernel, the color of a decision;
// what comes later has no accent: the dim color (SITE_ROADMAP_RULES).
site_roadmap_section_classes := [Roadmap_Section]string {
	.Now   = "accent-program",
	.Next  = "accent-kernel",
	.Later = "roadmap-later",
}

// What a section holds, in a few words under its heading.
site_roadmap_section_words := [Roadmap_Section]string {
	.Now   = "In work.",
	.Next  = "Decided. It comes after the work of now.",
	.Later = "Wanted. It has no order.",
}

// The rules of the page. Three columns on a wide screen: the three
// sections are one line of time, read from the left to the right, and a
// reader sees the count of each one at once. One column under 960 pixels,
// in the same order: a column of a third of a narrower window holds too
// few words a line. A card is the card of the site; a card of the section
// "Later" takes the dim color in the place of an accent.
SITE_ROADMAP_RULES :: `
.roadmap-columns { display: grid; grid-template-columns: minmax(0, 1fr); gap: 0 16px; align-items: start; }
@media (min-width: 960px) {
  .roadmap-columns { grid-template-columns: repeat(3, minmax(0, 1fr)); }
}
.roadmap-column { min-width: 0; }
.roadmap-column h2 { margin: 24px 0 8px; }
.roadmap-column h2 .date { font-size: 14px; font-weight: 400; margin-left: 8px; }
.card.roadmap-entry h3 { text-transform: none; font-family: var(--reading); margin-bottom: 8px; overflow-wrap: anywhere; }
.card.roadmap-entry p { overflow-wrap: anywhere; }
.roadmap-later { --accent: var(--dim); --accent-text: var(--dim); --border-top: var(--track); --border-bottom: var(--track); }
`

// site_roadmap_section_id gives the id of the heading of a section on the page.
site_roadmap_section_id :: proc(section: Roadmap_Section) -> string {
	return strings.to_lower(roadmap_section_names[section], context.temp_allocator)
}

// site_roadmap_entry_id gives the id of an entry on the page: from its
// summary, which no other entry has (roadmap_parse refuses two entries
// with one key).
site_roadmap_entry_id :: proc(entry: Roadmap_Entry) -> string {
	return strings.concatenate({"roadmap-", roadmap_summary_key(entry.summary)}, context.temp_allocator)
}

// site_roadmap_entry_words gives the count of entries in words: "1 entry",
// "5 entries".
site_roadmap_entry_words :: proc(count: int) -> string {
	return count == 1 ? "1 entry" : fmt.tprintf("%d entries", count)
}

// site_roadmap_read reads and checks ROADMAP.md, before any page is
// written: a fault of its form stops the command with its line.
site_roadmap_read :: proc(site: ^Site) -> bool {
	problems := make([dynamic]string, context.temp_allocator)
	roadmap, read_ok := roadmap_read(&problems)
	if !read_ok || len(problems) > 0 {
		problems_print(problems[:])
		fmt.eprintfln("kerneltool: site: %s does not have its form; `kerneltool roadmap check` says the same", ROADMAP_FILE)
		return false
	}
	site.roadmap = roadmap
	return true
}

// site_roadmap_add writes the page of the roadmap: the three sections,
// each a column of cards.
site_roadmap_add :: proc(site: ^Site) {
	path := site_section_page(.Roadmap)
	roadmap := site.roadmap
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "<h1>Roadmap</h1>\n<p>The planned work of %s: %s. <strong>Now</strong> is the work that is in progress, <strong>Next</strong> the work that is decided and comes after, <strong>Later</strong> the work that is wanted and has no order. An entry says what the work gives a user of the system, or a developer who builds on it. It gives no date.</p>\n", SITE_SYSTEM_NAME, site_roadmap_entry_words(len(roadmap.entries)))
	fmt.sbprintf(&b, "<p>An entry leaves this page when its work is done: the work is then a change of a release, on the page <a href=\"%s\">Releases</a>. The state of each property of the system, and the gaps of what is built, are on the page <a href=\"%s\">Status</a>.</p>\n", site_page_link(site, path, site_section_page(.Releases)), site_page_link(site, path, site_section_page(.Status)))
	site_source_line(site, &b, ROADMAP_FILE)
	// One renderer for the page: the ids of the page stay unique, and each
	// term of the glossary links once.
	renderer := site_renderer_make(site, path, ROADMAP_FILE)
	// The ids of the sections and of the entries first: an id that the
	// text makes cannot take one.
	for section in Roadmap_Section {
		renderer.ids[site_roadmap_section_id(section)] = true
	}
	for entry in roadmap.entries {
		renderer.ids[site_roadmap_entry_id(entry)] = true
	}
	strings.write_string(&b, "<div class=\"roadmap-columns\">\n")
	for section in Roadmap_Section {
		section_id := site_roadmap_section_id(section)
		count := roadmap_section_count(roadmap, section)
		fmt.sbprintf(&b, "<section class=\"roadmap-column\" aria-labelledby=\"%s\">\n<h2 id=\"%s\">%s <span class=\"date\">%s</span></h2>\n<p class=\"source\">%s</p>\n", section_id, section_id, roadmap_section_names[section], site_roadmap_entry_words(count), site_roadmap_section_words[section])
		if count == 0 {
			strings.write_string(&b, "<p class=\"missing\">No entry.</p>\n")
		}
		for entry in roadmap.entries {
			if entry.section != section {
				continue
			}
			strings.builder_reset(&renderer.builder)
			site_render_markdown(&renderer, entry.text, entry.line)
			fmt.sbprintf(&b, "<article class=\"card roadmap-entry %s\" id=\"%s\">\n<h3>", site_roadmap_section_classes[section], site_roadmap_entry_id(entry))
			site_inline(&b, entry.summary)
			strings.write_string(&b, "</h3>\n")
			strings.write_string(&b, strings.to_string(renderer.builder))
			if entry.design != "" {
				strings.write_string(&b, "<p class=\"source\"><a href=\"")
				site_escape(&b, site_repository_file(site, entry.design))
				strings.write_string(&b, "\">Design</a></p>\n")
			}
			strings.write_string(&b, "</article>\n")
		}
		strings.write_string(&b, "</section>\n")
	}
	strings.write_string(&b, "</div>\n")
	description := fmt.tprintf("The planned work of %s: %d entries in work now, %d that come next and %d that come later, each with what it gives a user.", SITE_SYSTEM_NAME, roadmap_section_count(roadmap, .Now), roadmap_section_count(roadmap, .Next), roadmap_section_count(roadmap, .Later))
	site_page_add(site, Site_Page{path = path, title = "Roadmap", description = site_description_cut(description), section = .Roadmap, crumbs = site_crumbs(.Home), body = strings.to_string(b), sources = site_sources(ROADMAP_FILE)})
}

// site_roadmap_link_line writes one line that leads to the page of the
// roadmap, on a page that shows what is done (the releases, the home, the
// status).
site_roadmap_link_line :: proc(site: ^Site, b: ^strings.Builder, from_page: string) {
	roadmap := site.roadmap
	fmt.sbprintf(b, "<p>What is planned: the <a href=\"%s\">roadmap</a>, with %s in work now, %d next and %d later.</p>\n", site_page_link(site, from_page, site_section_page(.Roadmap)), site_roadmap_entry_words(roadmap_section_count(roadmap, .Now)), roadmap_section_count(roadmap, .Next), roadmap_section_count(roadmap, .Later))
}

// site_roadmap_search_add adds each entry of the roadmap to the index of
// the search: a reader finds a planned work by its summary.
site_roadmap_search_add :: proc(site: ^Site, entries: ^[dynamic]Site_Search_Entry) {
	page := site_section_page(.Roadmap)
	for entry in site.roadmap.entries {
		site_search_add(entries, entry.summary, page, site_roadmap_entry_id(entry), .Roadmap_Entry, strings.concatenate({roadmap_section_names[entry.section], ": ", entry.text}, context.temp_allocator))
	}
}
