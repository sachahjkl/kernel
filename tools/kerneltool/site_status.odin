// The status page of the site (docs/SITE.md, "The status page"): the state
// of each property in the words of docs/PROPERTIES.md, the evidence items
// and the gaps of docs/FIRST_MILESTONE.md that name it, then the gaps and
// the next steps as tables, and for each property what it promises and what
// the machine test shows of it (docs/DEMONSTRATIONS.md). What is not done is
// shown as plainly as what is done. No sentence of the page but the one that
// says how to read a state is a summary that the tool writes: each cell is a
// part of one of the three documents.
package kerneltool

import "core:fmt"
import "core:slice"
import "core:strings"

SITE_MILESTONE_FILE :: "docs/FIRST_MILESTONE.md"
SITE_DEMONSTRATIONS_FILE :: "docs/DEMONSTRATIONS.md"

// One row of the table of the demonstrations: what the machine test shows
// of one property, its pictures, and what no test shows.
Site_Demonstration :: struct {
	number:   int,
	state:    string, // "Shown", "Shown in part" or "Not shown".
	shown:    string, // What the test shows, as Markdown.
	pictures: []string, // The names of the pictures of docs/screenshots, with no ".png".
	missing:  string, // What no test shows; "—" for nothing.
	line:     int,
}

// One item of the list "What removes each ...": the work that would end a
// part that is not shown.
Site_Demonstration_Removal :: struct {
	text: string,
	line: int,
}

// site_demonstrations_read reads the table of the section "## The table"
// and the numbered items of the section that starts "## What removes". The
// form: a row "| <n> | <property> | <state> | <what the test shows> |
// <pictures> | <what no test shows> |", the pictures as code spans
// separated by commas; an item "<n>. <text>" at the start of a line.
site_demonstrations_read :: proc(content: string) -> (rows: []Site_Demonstration, removals: []Site_Demonstration_Removal, problem: string) {
	list := make([dynamic]Site_Demonstration, context.temp_allocator)
	removal_list := make([dynamic]Site_Demonstration_Removal, context.temp_allocator)
	section := ""
	for line, index in site_lines(content) {
		if strings.has_prefix(line, "## ") {
			section = line[3:]
			continue
		}
		switch {
		case section == "The table" && strings.has_prefix(line, "| "):
			cells := site_table_cells(line)
			number := len(cells) > 0 ? site_digits_value(cells[0]) : -1
			if number < 1 {
				continue // The head of the table and its line of dashes.
			}
			if len(cells) != 6 {
				return nil, nil, fmt.tprintf("%s, line %d: a row of the table has 6 cells: number, property, state, what the test shows, pictures, what no test shows", SITE_DEMONSTRATIONS_FILE, index + 1)
			}
			pictures := make([dynamic]string, context.temp_allocator)
			for part in strings.split(cells[4], ",", context.temp_allocator) {
				name := strings.trim(strings.trim_space(part), "`")
				if name != "" {
					append(&pictures, name)
				}
			}
			append(&list, Site_Demonstration{number = number, state = cells[2], shown = cells[3], pictures = pictures[:], missing = cells[5], line = index + 1})
		case strings.has_prefix(section, "What removes"):
			dot := strings.index(line, ". ")
			if dot > 0 && site_digits_value(line[:dot]) > 0 {
				append(&removal_list, Site_Demonstration_Removal{text = strings.trim_space(line[dot + 2:]), line = index + 1})
			}
		}
	}
	if len(list) == 0 {
		return nil, nil, SITE_DEMONSTRATIONS_FILE + ": the section \"## The table\" has no row \"| <n> | ...\""
	}
	return list[:], removal_list[:], ""
}

// One item of the list of the section "## Gaps": a line "- <text>" and the
// lines that continue it, and the group above it: the last line of text
// before it that is not an item ("Performance:"), or "" for the first items.
Site_Gap :: struct {
	number: int, // From 1, in the order of the file: its id on the status page is gap-<number>.
	group:  string,
	text:   string,
	line:   int,
}

// site_gaps_read reads the list of the section "## Gaps". The form: items
// "- <text>" at the start of a line, the lines that continue an item start
// with a space; another line of text names the group of the items after it.
site_gaps_read :: proc(content: string) -> (gaps: []Site_Gap, problem: string) {
	lines := site_lines(content)
	first := -1
	for line, index in lines {
		if line == "## Gaps" {
			first = index + 1
			break
		}
	}
	if first < 0 {
		return nil, SITE_MILESTONE_FILE + ": no line \"## Gaps\""
	}
	list := make([dynamic]Site_Gap, context.temp_allocator)
	group := ""
	open := false
	for index in first ..< len(lines) {
		line := lines[index]
		if strings.has_prefix(line, "## ") || strings.has_prefix(line, "# ") {
			break
		}
		switch {
		case strings.trim_space(line) == "":
			open = false
		case strings.has_prefix(line, "- "):
			append(&list, Site_Gap{number = len(list) + 1, group = group, text = strings.trim_space(line[2:]), line = index + 1})
			open = true
		case line[0] == ' ' && open:
			last := &list[len(list) - 1]
			last.text = strings.concatenate({last.text, " ", strings.trim_space(line)}, context.temp_allocator)
		case:
			group = strings.trim_suffix(strings.trim_space(line), ":")
			open = false
		}
	}
	if len(list) == 0 {
		return nil, SITE_MILESTONE_FILE + ": the section \"## Gaps\" has no item \"- <text>\""
	}
	return list[:], ""
}

// site_property_numbers gives the properties that a text names. The rule:
// "property <n>" with no regard to case, or "P<n>" with a capital P, each a
// whole word; n from 1 to the count of the properties. "properties <n> and
// <m>" names none: the documents write one property at a time.
site_property_numbers :: proc(text: string, property_count: int) -> []int {
	numbers := make([dynamic]int, context.temp_allocator)
	lower := strings.to_lower(text, context.temp_allocator)
	for index in 0 ..< len(lower) {
		if index > 0 && site_is_word_byte(lower[index - 1]) {
			continue
		}
		start := -1
		if strings.has_prefix(lower[index:], "property ") {
			start = index + len("property ")
		} else if text[index] == 'P' {
			start = index + 1
		}
		if start < 0 {
			continue
		}
		end := start
		for end < len(lower) && lower[end] >= '0' && lower[end] <= '9' {
			end += 1
		}
		if end == start || (end < len(lower) && site_is_word_byte(lower[end])) {
			continue
		}
		number := site_digits_value(lower[start:end])
		if number >= 1 && number <= property_count && !slice.contains(numbers[:], number) {
			append(&numbers, number)
		}
	}
	return numbers[:]
}

// site_document_render renders a document of docs/ again, only for its ids,
// its headings and its labelled items: the page of a guide has the same ids,
// because the renderer gives the same ids to the same text. A working record
// is not a page of the site; it is rendered for its items and their lines
// only, and the HTML is dropped. What the renderer lists as not rendered is
// listed once, by the guide.
site_document_render :: proc(site: ^Site, source: string) -> (renderer: Site_Renderer, ok: bool) {
	content := site_read(source) or_return
	page, is_guide := site.documents[source]
	if !is_guide {
		page = SITE_PAGE
	}
	listed := len(site.not_rendered)
	// The spans of a document rendered again are counted by its own page.
	declaration_spans := site.declaration_spans
	renderer = site_renderer_make(site, page, source)
	site_render_markdown(&renderer, content)
	resize(&site.not_rendered, listed)
	site.declaration_spans = declaration_spans
	return renderer, true
}

// site_item_links writes the labels of items of a document as links: to
// their ids in the page of the document when it is a guide, else to their
// lines in the file of the repository (a working record is not a page of
// the site).
site_item_links :: proc(site: ^Site, b: ^strings.Builder, from_page, source: string, items: []Site_List_Item) {
	guide_page, is_guide := site.documents[source]
	for item, index in items {
		if index > 0 {
			strings.write_string(b, ", ")
		}
		strings.write_string(b, "<a href=\"")
		if is_guide {
			site_escape(b, strings.concatenate({site_page_link(site, from_page, guide_page), "#", item.id}, context.temp_allocator))
		} else {
			site_escape(b, site_line_address(site, source, item.line))
		}
		strings.write_string(b, "\">")
		site_escape(b, item.label)
		strings.write_string(b, "</a>")
	}
}

site_status_add :: proc(site: ^Site) -> bool {
	path := site_section_page(.Status)
	properties := site.principles.properties
	milestone_text := site_read(SITE_MILESTONE_FILE) or_return
	milestone := site_document_render(site, SITE_MILESTONE_FILE) or_return
	principles := site_document_render(site, SITE_PROPERTIES_FILE) or_return
	properties_page := site.documents[SITE_PROPERTIES_FILE]
	gaps, gaps_problem := site_gaps_read(milestone_text)
	if gaps_problem != "" {
		fmt.eprintfln("kerneltool: site: %s", gaps_problem)
		return false
	}
	site.gaps = gaps
	evidence := make([dynamic]Site_List_Item, context.temp_allocator)
	next_steps := make([dynamic]Site_List_Item, context.temp_allocator)
	for item in milestone.items {
		switch item.section {
		case "evidence":
			append(&evidence, item)
		case "next-steps":
			append(&next_steps, item)
		}
	}
	if len(evidence) == 0 || len(next_steps) == 0 {
		fmt.eprintfln("kerneltool: site: %s: no numbered item under \"## Evidence\" or under \"## Next steps\"", SITE_MILESTONE_FILE)
		return false
	}

	demonstrations_text := site_read(SITE_DEMONSTRATIONS_FILE) or_return
	demonstrations, removals, demonstrations_problem := site_demonstrations_read(demonstrations_text)
	if demonstrations_problem != "" {
		fmt.eprintfln("kerneltool: site: %s", demonstrations_problem)
		return false
	}

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "<h1>Status</h1>\n<p>The state of the system in this build: each of the %d properties in the words of its document, with the evidence items and the gaps that name it; then, for each property, what it promises, what the machine test shows today with its pictures, and what is not done; then all %d gaps and the next steps. A gap is a part of the design that the code does not do yet.</p>\n", len(properties), len(gaps))
	strings.write_string(&b, "<p>A <strong>property</strong> is one fundamental rule of the system: what it does, and what it must never contain. Its <strong>status</strong> says whether the rule is decided. Its <strong>state</strong> says what a machine test shows of it: <em>Shown</em> when the test does the thing for real and checks the result, <em>Shown in part</em> when a named part has no test, <em>Not shown</em> when the system does not have the thing.</p>\n")

	// The properties.
	strings.write_string(&b, "<h2 id=\"properties\">Properties</h2>\n")
	properties_table := site_table_start(&b, "Properties", {{"Property", .Prose}, {"Status", .Short}, {"Evidence items", .List}, {"Gaps", .List}}, {.None, .Status, .None, .None})
	for property in properties {
		heading_id := ""
		prefix := fmt.tprintf("%d. ", property.number)
		for heading in principles.headings {
			if heading.level == 2 && strings.has_prefix(heading.text, prefix) {
				heading_id = heading.id
				break
			}
		}
		fmt.sbprintf(&b, "<tr id=\"property-%d\" data-outline=\"%d. ", property.number, property.number)
		site_plain(&b, property.title)
		strings.write_string(&b, "\"><td>")
		if heading_id != "" {
			fmt.sbprintf(&b, "<a href=\"%s#%s\">", site_page_link(site, path, properties_page), heading_id)
		}
		fmt.sbprintf(&b, "%d. ", property.number)
		site_inline(&b, property.title)
		if heading_id != "" {
			strings.write_string(&b, "</a>")
		}
		strings.write_string(&b, "</td>")
		site_cell(&b, property.status)
		naming := make([dynamic]Site_List_Item, context.temp_allocator)
		for item in evidence {
			if slice.contains(site_property_numbers(item.text, len(properties)), property.number) {
				append(&naming, item)
			}
		}
		// The items and the gaps are lists of labels: they break between
		// the labels, never with a comma at the start of a line.
		if len(naming) == 0 {
			strings.write_string(&b, "<td class=\"missing\">none names it</td>")
		} else {
			labels := make([dynamic]string, context.temp_allocator)
			for item in naming {
				label := strings.builder_make(context.temp_allocator)
				site_item_links(site, &label, path, SITE_MILESTONE_FILE, []Site_List_Item{item})
				append(&labels, strings.to_string(label))
			}
			strings.write_string(&b, "<td class=\"code\">")
			site_value_list(&b, labels[:])
			strings.write_string(&b, "</td>")
		}
		gap_labels := make([dynamic]string, context.temp_allocator)
		for gap in gaps {
			if slice.contains(site_property_numbers(gap.text, len(properties)), property.number) {
				append(&gap_labels, fmt.tprintf("<a href=\"#gap-%d\">%d</a>", gap.number, gap.number))
			}
		}
		if len(gap_labels) == 0 {
			strings.write_string(&b, "<td class=\"missing\">none names it</td>")
		} else {
			strings.write_string(&b, "<td class=\"code\">")
			site_value_list(&b, gap_labels[:])
			strings.write_string(&b, "</td>")
		}
		strings.write_string(&b, "</tr>\n")
	}
	site_table_end(&b, properties_table)
	strings.write_string(&b, "<p class=\"source\">The status is the column \"Status\" of the summary of the properties. An evidence item or a gap names a property when its text says \"property &lt;n&gt;\" or \"P&lt;n&gt;\".</p>\n")
	site_source_line(site, &b, SITE_PROPERTIES_FILE, SITE_MILESTONE_FILE)

	// Each property in prose: the promise from its first rule, then the
	// demonstration. The page states what is not done as plainly as what is.
	strings.write_string(&b, "<h2 id=\"each-property\">What each property promises, and what runs today</h2>\n")
	for property in properties {
		fmt.sbprintf(&b, "<section class=\"symbol\">\n<h3 id=\"state-%d\">%d. ", property.number, property.number)
		site_inline(&b, property.title)
		strings.write_string(&b, "</h3>\n<p><strong>What it promises.</strong> ")
		site_inline(&b, property.sentence)
		strings.write_string(&b, "</p>\n")
		found := false
		for row in demonstrations {
			if row.number != property.number {
				continue
			}
			found = true
			strings.write_string(&b, "<p><strong>Today: ")
			site_inline(&b, row.state)
			strings.write_string(&b, ".</strong> ")
			site_inline(&b, row.shown)
			strings.write_string(&b, "</p>\n")
			if len(row.pictures) > 0 {
				strings.write_string(&b, "<p><strong>Pictures of the test:</strong> ")
				for picture, index in row.pictures {
					if index > 0 {
						strings.write_string(&b, ", ")
					}
					strings.write_string(&b, "<a href=\"")
					site_escape(&b, site_repository_file(site, strings.concatenate({"docs/screenshots/", picture, ".png"}, context.temp_allocator)))
					strings.write_string(&b, "\"><code>")
					site_escape(&b, picture)
					strings.write_string(&b, "</code></a>")
				}
				strings.write_string(&b, "</p>\n")
			}
			strings.write_string(&b, "<p><strong>Not done.</strong> ")
			if strings.trim_space(row.missing) == "—" {
				strings.write_string(&b, "The demonstration names no part that a test does not show.")
			} else {
				site_inline(&b, row.missing)
			}
			strings.write_string(&b, "</p>\n")
			for removal in removals {
				if slice.contains(site_property_numbers(removal.text, len(properties)), property.number) {
					strings.write_string(&b, "<p><strong>What would complete it.</strong> ")
					site_inline(&b, removal.text)
					strings.write_string(&b, "</p>\n")
				}
			}
			fmt.sbprintf(&b, "<p class=\"source\"><a href=\"%s\">The row of the property</a> in the table of the demonstrations.</p>\n", site_line_address(site, SITE_DEMONSTRATIONS_FILE, row.line))
		}
		if !found {
			strings.write_string(&b, "<p class=\"missing\">No demonstration is recorded for this property.</p>\n")
		}
		strings.write_string(&b, "</section>\n")
	}
	site_source_line(site, &b, SITE_PROPERTIES_FILE, SITE_DEMONSTRATIONS_FILE)

	// The gaps.
	strings.write_string(&b, "<h2 id=\"gaps\">Gaps</h2>\n")
	gaps_table := site_table_start(&b, "Gaps", {{"Gap", .Number}, {"Group", .Short}, {"What the code does not do", .Prose}})
	for gap in gaps {
		fmt.sbprintf(&b, "<tr id=\"gap-%d\" data-outline=\"Gap %d\"><td class=\"code\"><a href=\"", gap.number, gap.number)
		site_escape(&b, site_line_address(site, SITE_MILESTONE_FILE, gap.line))
		fmt.sbprintf(&b, "\">%d</a></td>", gap.number)
		site_cell(&b, gap.group)
		site_cell(&b, gap.text)
		strings.write_string(&b, "</tr>\n")
	}
	site_table_end(&b, gaps_table)
	site_source_line(site, &b, SITE_MILESTONE_FILE)

	// The next steps.
	strings.write_string(&b, "<h2 id=\"next-steps\">Next steps</h2>\n")
	steps_table := site_table_start(&b, "Next steps", {{"Step", .Short}, {"What and its state", .Prose}}, {.Number, .None})
	for item in next_steps {
		strings.write_string(&b, "<tr><td class=\"code\">")
		site_item_links(site, &b, path, SITE_MILESTONE_FILE, []Site_List_Item{item})
		strings.write_string(&b, "</td>")
		site_cell(&b, item.text)
		strings.write_string(&b, "</tr>\n")
	}
	site_table_end(&b, steps_table)
	site_source_line(site, &b, SITE_MILESTONE_FILE)

	site_page_add(site, Site_Page{path = path, title = "Status", description = site_description_cut(fmt.tprintf("The state of each of the %d properties of %s, with its evidence and its gaps; the %d gaps and the next steps.", len(properties), SITE_SYSTEM_NAME, len(gaps))), section = .Status, crumbs = site_crumbs(.Home), body = strings.to_string(b), sources = site_sources(SITE_PROPERTIES_FILE, SITE_MILESTONE_FILE, SITE_DEMONSTRATIONS_FILE), layout = .Documentation})
	return true
}
