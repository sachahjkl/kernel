// The status page of the site (docs/SITE.md, "The status page"): the state
// of each property in the words of docs/PROPERTIES.md, the evidence items
// and the gaps of docs/FIRST_MILESTONE.md that name it, then the gaps and
// the next steps as tables. What is not done is shown as plainly as what is
// done. No sentence of the page is a summary that a person writes: each
// cell is a part of one of the two documents.
package kerneltool

import "core:fmt"
import "core:slice"
import "core:strings"

SITE_MILESTONE_FILE :: "docs/FIRST_MILESTONE.md"

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
// whole word; n from 1 to the count of the properties. "properties 3 and 4"
// names none: the documents write one property at a time.
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

// site_document_render renders a document of docs/ again, only for its ids
// and its labelled items: the page of the guide has the same ids, because the
// renderer gives the same ids to the same text. What the renderer lists as
// not rendered is listed once, by the guide.
site_document_render :: proc(site: ^Site, source: string) -> (renderer: Site_Renderer, ok: bool) {
	content := site_read(source) or_return
	page, is_guide := site.documents[source]
	if !is_guide {
		fmt.eprintfln("kerneltool: site: %s is not a guide of the site", source)
		return {}, false
	}
	listed := len(site.not_rendered)
	renderer = site_renderer_make(site, page, source)
	site_render_markdown(&renderer, content)
	resize(&site.not_rendered, listed)
	return renderer, true
}

// site_item_links writes the labels of items as links to their ids in a guide.
site_item_links :: proc(b: ^strings.Builder, from_page, guide_page: string, items: []Site_List_Item) {
	for item, index in items {
		if index > 0 {
			strings.write_string(b, ", ")
		}
		fmt.sbprintf(b, "<a href=\"%s#%s\">", site_relative(from_page, guide_page), item.id)
		site_escape(b, item.label)
		strings.write_string(b, "</a>")
	}
}

site_status_add :: proc(site: ^Site) -> bool {
	path := site_section_pages[.Status]
	properties := site.principles.properties
	milestone_text := site_read(SITE_MILESTONE_FILE) or_return
	milestone := site_document_render(site, SITE_MILESTONE_FILE) or_return
	principles := site_document_render(site, SITE_PROPERTIES_FILE) or_return
	milestone_page := site.documents[SITE_MILESTONE_FILE]
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

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "<h1>Status</h1>\n<p>The state of the system in this build: each of the %d properties in the words of its document, with the evidence items and the gaps that name it; then all %d gaps and the next steps. A gap is a part of the design that the code does not do yet.</p>\n", len(properties), len(gaps))

	// The properties.
	strings.write_string(&b, "<h2 id=\"properties\">Properties</h2>\n")
	properties_table := site_table_start(&b, "Properties", {{"Property", .Prose}, {"Status", .Short}, {"Evidence items", .Prose}, {"Gaps", .Prose}})
	for property in properties {
		heading_id := ""
		prefix := fmt.tprintf("%d. ", property.number)
		for heading in principles.headings {
			if heading.level == 2 && strings.has_prefix(heading.text, prefix) {
				heading_id = heading.id
				break
			}
		}
		fmt.sbprintf(&b, "<tr id=\"property-%d\"><td>", property.number)
		if heading_id != "" {
			fmt.sbprintf(&b, "<a href=\"%s#%s\">", site_relative(path, properties_page), heading_id)
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
		if len(naming) == 0 {
			strings.write_string(&b, "<td class=\"missing\">none names it</td>")
		} else {
			strings.write_string(&b, "<td class=\"code\">")
			site_item_links(&b, path, milestone_page, naming[:])
			strings.write_string(&b, "</td>")
		}
		named_gaps := 0
		for gap in gaps {
			if !slice.contains(site_property_numbers(gap.text, len(properties)), property.number) {
				continue
			}
			strings.write_string(&b, named_gaps == 0 ? "<td class=\"code\">" : ", ")
			fmt.sbprintf(&b, "<a href=\"#gap-%d\">%d</a>", gap.number, gap.number)
			named_gaps += 1
		}
		strings.write_string(&b, named_gaps == 0 ? "<td class=\"missing\">none names it</td>" : "</td>")
		strings.write_string(&b, "</tr>\n")
	}
	site_table_end(&b, properties_table)
	strings.write_string(&b, "<p class=\"source\">The status is the column \"Status\" of the summary of the properties. An evidence item or a gap names a property when its text says \"property &lt;n&gt;\" or \"P&lt;n&gt;\".</p>\n")
	site_source_line(site, &b, SITE_PROPERTIES_FILE, SITE_MILESTONE_FILE)

	// The gaps.
	strings.write_string(&b, "<h2 id=\"gaps\">Gaps</h2>\n")
	gaps_table := site_table_start(&b, "Gaps", {{"Gap", .Number}, {"Group", .Short}, {"What the code does not do", .Prose}})
	for gap in gaps {
		fmt.sbprintf(&b, "<tr id=\"gap-%d\"><td class=\"code\"><a href=\"", gap.number)
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
	steps_table := site_table_start(&b, "Next steps", {{"Step", .Short}, {"What and its state", .Prose}})
	for item in next_steps {
		strings.write_string(&b, "<tr><td class=\"code\">")
		site_item_links(&b, path, milestone_page, []Site_List_Item{item})
		strings.write_string(&b, "</td>")
		site_cell(&b, item.text)
		strings.write_string(&b, "</tr>\n")
	}
	site_table_end(&b, steps_table)
	site_source_line(site, &b, SITE_MILESTONE_FILE)

	site_page_add(site, Site_Page{path = path, title = "Status", description = site_description_cut(fmt.tprintf("The state of each of the %d properties of %s, with its evidence and its gaps; the %d gaps and the next steps.", len(properties), SITE_SYSTEM_NAME, len(gaps))), section = .Status, crumbs = site_crumbs(.Home), body = strings.to_string(b), sources = site_sources(SITE_PROPERTIES_FILE, SITE_MILESTONE_FILE)})
	return true
}
