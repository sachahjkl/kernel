// The home of the docs (docs/SITE.md, "The docs home"): a door to the
// guides and to the reference. Its large search field is the search of the
// page, and the bar of the page has none. Under the field: a card for each
// part of the docs, then the chart of what the search finds.
// Every count comes from the data that the pages and the index of the
// search show; no count is typed.
package kerneltool

import "core:fmt"
import "core:strings"

// One row of a card of the docs home. The three cards (the guides, the
// reference and the chart) share one form: a lead (a number of a reading
// order or the icon of a kind), the name, then a description or a bar, and
// a count at the right in a column of one width.
Site_Docs_Row :: struct {
	number:    int, // The place in a reading order, from 1, or 0 for an icon.
	kind:      Site_Value_Kind, // The icon of the lead when number is 0.
	name:      string,
	address:   string, // The link of the name, or "".
	about:     string, // Plain text, dim, after the name or under it; or "".
	count:     int,
	has_count: bool,
}

// site_docs_row_lead writes the lead of a row: its number, which the list
// already says to a screen reader, or the icon of its kind.
site_docs_row_lead :: proc(b: ^strings.Builder, number: int, kind: Site_Value_Kind) {
	if number > 0 {
		fmt.sbprintf(b, "<span class=\"docs-row-lead docs-row-number\" aria-hidden=\"true\">%d</span>", number)
	} else {
		fmt.sbprintf(b, "<span class=\"docs-row-lead value-icon value-%s\" aria-hidden=\"true\"></span>", site_value_kinds[kind].name)
	}
}

// site_docs_row writes one row of a card of the guides or of the
// reference.
site_docs_row :: proc(b: ^strings.Builder, row: Site_Docs_Row) {
	strings.write_string(b, "<li class=\"docs-row\">")
	site_docs_row_lead(b, row.number, row.kind)
	strings.write_string(b, "<span class=\"docs-row-main\"><span class=\"docs-row-name\">")
	if row.address != "" {
		fmt.sbprintf(b, "<a href=\"%s\">", row.address)
		site_escape(b, row.name)
		strings.write_string(b, "</a>")
	} else {
		site_escape(b, row.name)
	}
	strings.write_string(b, "</span>")
	if row.about != "" {
		strings.write_string(b, "<span class=\"docs-row-about\">")
		site_escape(b, row.about)
		strings.write_string(b, "</span>")
	}
	strings.write_string(b, "</span>")
	if row.has_count {
		fmt.sbprintf(b, "<code class=\"value value-number docs-row-count\">%d</code>", row.count)
	}
	strings.write_string(b, "</li>\n")
}

// The least length of a bar of the chart, in pixels: a kind with one entry
// among a thousand still shows a mark.
SITE_SEARCH_CHART_LEAST_LENGTH :: 4

// One row of the chart of the docs home: a kind of entry, its count in the
// index, and the page that lists every entry of the kind ("" for none).
Site_Search_Chart_Row :: struct {
	kind:  Site_Search_Kind,
	count: int,
	page:  string,
}

// site_search_chart_rows gives a row for each kind that has entries in the
// index, the largest count first; of two equal counts, the tie order of
// the kinds.
site_search_chart_rows :: proc(site: ^Site, entries: []Site_Search_Entry) -> []Site_Search_Chart_Row {
	counts: [Site_Search_Kind]int
	for entry in entries {
		counts[entry.kind] += 1
	}
	rows := make([dynamic]Site_Search_Chart_Row, context.temp_allocator)
	for kind in Site_Search_Kind {
		if counts[kind] > 0 {
			append(&rows, Site_Search_Chart_Row{kind = kind, count = counts[kind], page = site_search_kind_page(site, kind)})
		}
	}
	// An insertion sort keeps the tie order of two equal counts, and the
	// table has fifteen kinds.
	for index in 1 ..< len(rows) {
		row := rows[index]
		place := index
		for place > 0 && rows[place - 1].count < row.count {
			rows[place] = rows[place - 1]
			place -= 1
		}
		rows[place] = row
	}
	return rows[:]
}

// site_search_chart_length gives the length of a bar: its count over the
// largest count, in tenths of a percent of the width of the chart. The
// script of the search writes the same form.
site_search_chart_length :: proc(count, largest: int) -> string {
	if largest <= 0 {
		return "0.0%"
	}
	per_mille := count * 1000 / largest
	return fmt.tprintf("%d.%d%%", per_mille / 10, per_mille % 10)
}

// site_search_chart writes the chart of what the search finds: a list with
// a row for each kind, its icon, its name, its count as a number value and
// its bar. The names and the counts are text; the bar is a decoration that
// a screen reader skips. A bar is an SVG rect whose width is an attribute,
// because a page holds no style attribute; the rect of the least length
// keeps a small count visible. A row whose kind has a page is a link to it.
// The data attributes are what the script of the search reads to show the
// matches of a text of the field (docs/SITE.md, "The docs home").
site_search_chart :: proc(b: ^strings.Builder, site: ^Site, path: string, rows: []Site_Search_Chart_Row) {
	total, largest := 0, 0
	for row in rows {
		total += row.count
		largest = max(largest, row.count)
	}
	strings.write_string(b, "<section class=\"card accent-program search-chart\" aria-labelledby=\"search-finds\">\n<h2 id=\"search-finds\">What the search finds</h2>\n")
	fmt.sbprintf(b, "<p class=\"search-chart-total\"><span id=\"search-chart-matched\" hidden><code class=\"value value-number\" id=\"search-chart-matched-count\">0</code> of </span><code class=\"value value-number\">%d</code> <span id=\"search-chart-words\">entries in the index</span></p>\n", total)
	fmt.sbprintf(b, "<ol class=\"docs-rows search-chart-rows\" id=\"search-chart\" data-least=\"%d\">\n", SITE_SEARCH_CHART_LEAST_LENGTH)
	for row in rows {
		description := site_search_kinds[row.kind]
		value_name := site_value_kinds[description.value_kind].name
		fmt.sbprintf(b, "<li class=\"search-chart-row\" data-kind=\"%d\" data-count=\"%d\" data-singular=\"%s\" data-plural=\"%s\">", int(row.kind), row.count, description.name, site_search_kind_words(row.kind, 2))
		// The whole row is the target: a link, or a button while the field
		// holds a text; so it carries the form of a row itself.
		if row.page != "" {
			fmt.sbprintf(b, "<a class=\"docs-row search-chart-target\" href=\"%s\">", site_page_link(site, path, row.page))
		} else {
			strings.write_string(b, "<span class=\"docs-row search-chart-target\">")
		}
		site_docs_row_lead(b, 0, description.value_kind)
		fmt.sbprintf(b, "<span class=\"docs-row-main\"><span class=\"docs-row-name search-chart-name\">%s</span>", site_search_kind_words(row.kind, row.count))
		fmt.sbprintf(b, "<svg class=\"docs-row-bar search-chart-bar value-%s\" aria-hidden=\"true\" focusable=\"false\"><rect class=\"search-chart-length\" width=\"%s\" height=\"100%%\"/><rect class=\"search-chart-least\" width=\"%d\" height=\"100%%\"/></svg></span>", value_name, site_search_chart_length(row.count, largest), SITE_SEARCH_CHART_LEAST_LENGTH)
		fmt.sbprintf(b, "<code class=\"value value-number docs-row-count search-chart-count\">%d</code>", row.count)
		strings.write_string(b, row.page != "" ? "</a></li>\n" : "</span></li>\n")
	}
	strings.write_string(b, "</ol>\n</section>\n")
}

// site_docs_home_add records the home of the docs, with no text yet: its
// text says what the index of the search holds, and the index is made from
// the pages (site_docs_home_fill). Its title and its description, which the
// index reads, are known now.
site_docs_home_add :: proc(site: ^Site) {
	description := site_description_cut(fmt.tprintf("The docs of %s: %d guides on how each part is designed and why, %d reference tables generated from the code, and one search over the whole site.", SITE_SYSTEM_NAME, len(site.guides), len(site.reference_entries)))
	site_page_add(site, Site_Page{path = site_section_page(.Docs), is_index = true, title = site_section_titles[.Docs], description = description, section = .Docs, crumbs = site_crumbs(.Home), sources = site_sources(SITE_README_FILE), search_in_page = true})
}

// site_docs_home_fill writes the text of the home of the docs, once the
// entries of the index of the search are known.
site_docs_home_fill :: proc(site: ^Site, entries: []Site_Search_Entry) {
	path := site_section_page(.Docs)
	for &page in site.pages {
		if page.path == path {
			page.body = site_docs_home_body(site, path, entries)
		}
	}
}

// site_docs_home_body gives the text of the home of the docs: the heading,
// the search field of the page, the card of the guides, the card of the
// reference, and the chart of what the search finds.
site_docs_home_body :: proc(site: ^Site, path: string, entries: []Site_Search_Entry) -> string {
	b := strings.builder_make(context.temp_allocator)
	guides_page := site_section_page(.Guides)
	reference_page := site_section_page(.Reference)

	fmt.sbprintf(&b, "<div class=\"docs-head\">\n<h1>%s</h1>\n", site_section_titles[.Docs])
	fmt.sbprintf(&b, "<p class=\"lead\">How %s works. The guides explain how each part is designed, and why; the reference states what exists in this build, generated from the code.</p>\n</div>\n", SITE_SYSTEM_NAME)
	// The search field of this page; with no script it stays hidden, and
	// the cards under it carry the page.
	strings.write_string(&b, site_search_field_html(.Docs_Home))

	// The two cards list every guide and every table of the reference, one
	// row each; the heading of a card is the link to its index.
	strings.write_string(&b, "<div class=\"docs-parts\">\n")
	if site_page_exists(site, guides_page) {
		strings.write_string(&b, "<section class=\"card accent-kernel\" aria-labelledby=\"guides\">\n")
		fmt.sbprintf(&b, "<h2 id=\"guides\"><a href=\"%s\">%s</a></h2>\n", site_page_link(site, path, guides_page), site_section_titles[.Guides])
		strings.write_string(&b, "<p>How each part is designed, and why, in reading order.</p>\n<ol class=\"docs-rows\">\n")
		for guide, index in site.guides {
			// The line of the guide in the table of documents of README.md
			// is its short description; a guide that has none shows its
			// title alone.
			site_docs_row(&b, Site_Docs_Row{number = index + 1, name = guide.title, address = site_page_link(site, path, guide.path), about = site_search_plain(guide.about)})
		}
		strings.write_string(&b, "</ol>\n</section>\n")
	}
	// The second column: the reference, then the chart. The guides are the
	// longer list, so the chart fills the column of the shorter one.
	strings.write_string(&b, "<div class=\"docs-parts-column\">\n")
	if site_page_exists(site, reference_page) {
		strings.write_string(&b, "<section class=\"card accent-memory\" aria-labelledby=\"reference\">\n")
		fmt.sbprintf(&b, "<h2 id=\"reference\"><a href=\"%s\">%s</a></h2>\n", site_page_link(site, path, reference_page), site_section_titles[.Reference])
		strings.write_string(&b, "<p>What exists in this build, generated from the code.</p>\n<ul class=\"docs-rows docs-rows-one-line\">\n")
		for entry in site.reference_entries {
			site_docs_row(&b, Site_Docs_Row{kind = entry.kind, name = entry.title, address = site_page_link(site, path, entry.path), about = entry.what, count = entry.count, has_count = true})
		}
		strings.write_string(&b, "</ul>\n</section>\n")
	}
	// The bar gives the status, the news and the releases, and the cards
	// every guide: the page has no row of doors.
	site_search_chart(&b, site, path, site_search_chart_rows(site, entries))
	strings.write_string(&b, "</div>\n</div>\n")
	return strings.to_string(b)
}
