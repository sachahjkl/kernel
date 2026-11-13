// The home of the docs (docs/SITE.md, "The docs home"): a door to the
// guides and to the reference. Its large search field is the search of the
// page, and the bar of the page has none. Under the field: the chart of
// what the search finds, then a card for each part of the docs.
// Every count comes from the data that the pages and the index of the
// search show; no count is typed.
package kerneltool

import "contract:value_kinds"
import "core:fmt"
import "core:strings"

// One row of a card of the docs home. The two cards (the guides and the
// reference) share one form: a lead (a number of a reading order or the
// icon of a kind), the name, then a description, and a count at the right
// in a column of one width.
Site_Docs_Row :: struct {
	number:    int, // The place in a reading order, from 1, or 0 for an icon.
	kind:      value_kinds.Value_Kind, // The icon of the lead when number is 0.
	name:      string,
	address:   string, // The link of the name, or "".
	about:     string, // Plain text, dim, after the name or under it; or "".
	count:     int,
	has_count: bool,
}

// site_docs_row_lead writes the lead of a row: its number, which the list
// already says to a screen reader, or the icon of its kind.
site_docs_row_lead :: proc(b: ^strings.Builder, number: int, kind: value_kinds.Value_Kind) {
	if number > 0 {
		fmt.sbprintf(b, "<span class=\"docs-row-lead docs-row-number\" aria-hidden=\"true\">%d</span>", number)
	} else {
		fmt.sbprintf(b, "<span class=\"docs-row-lead value-icon value-%s\" aria-hidden=\"true\"></span>", value_kinds.VALUE_KIND_NAMES[kind])
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

// The least share of a segment of the chart, in thousandths of its width:
// a kind with one entry among a thousand still shows a mark, about 9
// pixels wide at 1152 pixels and 3 at 360.
SITE_SEARCH_CHART_LEAST_SHARE :: 8

// One kind of the chart of the docs home: a kind of entry, its count in
// the index, and the page that lists every entry of the kind ("" for none).
Site_Search_Chart_Row :: struct {
	kind:  Site_Search_Kind,
	count: int,
	page:  string,
}

// site_search_chart_rows gives a row for each kind that has entries in the
// index, in the tie order of the kinds: the order of the segments of the
// bar and of the chips under it, which does not change while the reader
// types.
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
	return rows[:]
}

// One segment of the bar: its start and its width, in thousandths of the
// width of the bar.
Site_Search_Chart_Segment :: struct {
	start: int,
	width: int,
}

// site_search_chart_segments gives the segment of each count, side by side
// from the left: a count above zero takes the least share, and the rest of
// the bar is shared in proportion to the counts, rounded down; the last
// segment above zero takes what the rounding left, so that the segments
// fill the bar. A count of zero has no width. The script of the search
// computes the same segments, and its self test runs the cases of
// site_search_segment_cases.
site_search_chart_segments :: proc(counts: []int) -> []Site_Search_Chart_Segment {
	segments := make([]Site_Search_Chart_Segment, len(counts), context.temp_allocator)
	total, shown, last := 0, 0, -1
	for count, index in counts {
		if count > 0 {
			total += count
			shown += 1
			last = index
		}
	}
	if total == 0 {
		return segments
	}
	least := SITE_SEARCH_CHART_LEAST_SHARE
	if shown * least > 1000 {
		least = 1000 / shown
	}
	rest := 1000 - shown * least
	sum := 0
	for count, index in counts {
		if count > 0 {
			segments[index].width = least + rest * count / total
			sum += segments[index].width
		}
	}
	segments[last].width += 1000 - sum
	start := 0
	for &segment in segments {
		segment.start = start
		start += segment.width
	}
	return segments
}

// site_search_chart_percent gives a share in thousandths as the attribute
// of an SVG rectangle: "74.6%". The script writes the same form.
site_search_chart_percent :: proc(per_mille: int) -> string {
	return fmt.tprintf("%d.%d%%", per_mille / 10, per_mille % 10)
}

// site_search_chart writes the chart of what the search finds, in a compact
// form under the search field: one bar over the whole width, a segment for
// each kind in its color, and under it one row of chips, each kind with
// its icon, its name and its count. The names and the counts are text; the
// bar is a decoration that a screen reader skips. A segment is an SVG rect
// whose place and width are attributes, because a page holds no style
// attribute. A chip whose kind has a page is a link to it. The data
// attributes are what the script of the search reads to show the matches
// of a text of the field (docs/SITE.md, "The chart of what the search
// finds").
site_search_chart :: proc(b: ^strings.Builder, site: ^Site, path: string, rows: []Site_Search_Chart_Row) {
	total := 0
	counts := make([]int, len(rows), context.temp_allocator)
	for row, index in rows {
		total += row.count
		counts[index] = row.count
	}
	segments := site_search_chart_segments(counts)
	strings.write_string(b, "<section class=\"search-chart\" aria-labelledby=\"search-finds\">\n<h2 class=\"search-chart-heading\" id=\"search-finds\">What the search finds</h2>\n<div class=\"search-chart-line\">\n")
	strings.write_string(b, "<svg class=\"search-chart-bar\" id=\"search-chart-bar\" aria-hidden=\"true\" focusable=\"false\">")
	for row, index in rows {
		value_name := value_kinds.VALUE_KIND_NAMES[site_search_kinds[row.kind].value_kind]
		fmt.sbprintf(b, "<rect class=\"search-chart-segment value-%s\" data-kind=\"%d\" x=\"%s\" width=\"%s\" height=\"100%%\"/>", value_name, int(row.kind), site_search_chart_percent(segments[index].start), site_search_chart_percent(segments[index].width))
	}
	strings.write_string(b, "</svg>\n")
	fmt.sbprintf(b, "<p class=\"search-chart-total\"><span id=\"search-chart-matched\" hidden><code class=\"value value-number\" id=\"search-chart-matched-count\">0</code> of </span><code class=\"value value-number\">%d</code> <span id=\"search-chart-words\">entries</span></p>\n</div>\n", total)
	// The least share of a segment is in the rule of the script, which the
	// tool writes: the markup does not repeat it.
	strings.write_string(b, "<ul class=\"search-chart-rows\" id=\"search-chart\">\n")
	for row in rows {
		description := site_search_kinds[row.kind]
		value_name := value_kinds.VALUE_KIND_NAMES[description.value_kind]
		// The name of a chip is the name of its kind for many entries, at
		// every count: the width of a chip does not change while the reader
		// types, so the row of chips does not break at another place.
		plural := site_search_kind_words(row.kind, 2)
		fmt.sbprintf(b, "<li class=\"search-chart-row\" data-kind=\"%d\" data-count=\"%d\" data-plural=\"%s\">", int(row.kind), row.count, plural)
		// The whole chip is the target: a link, or a button while the field
		// holds a text.
		if row.page != "" {
			fmt.sbprintf(b, "<a class=\"search-chart-target\" href=\"%s\">", site_page_link(site, path, row.page))
		} else {
			strings.write_string(b, "<span class=\"search-chart-target\">")
		}
		fmt.sbprintf(b, "<span class=\"search-chart-icon value-icon value-%s\" aria-hidden=\"true\"></span><span class=\"search-chart-name\">%s</span>", value_name, plural)
		fmt.sbprintf(b, "<code class=\"value value-number search-chart-count\">%d</code>", row.count)
		strings.write_string(b, row.page != "" ? "</a></li>\n" : "</span></li>\n")
	}
	strings.write_string(b, "</ul>\n</section>\n")
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
// the search field of the page with the chart of what the search finds
// under it, then the card of the guides and the card of the reference.
site_docs_home_body :: proc(site: ^Site, path: string, entries: []Site_Search_Entry) -> string {
	b := strings.builder_make(context.temp_allocator)
	guides_page := site_section_page(.Guides)
	reference_page := site_section_page(.Reference)

	fmt.sbprintf(&b, "<div class=\"docs-head\">\n<h1>%s</h1>\n", site_section_titles[.Docs])
	fmt.sbprintf(&b, "<p class=\"lead\">How %s works. The guides explain how each part is designed, and why; the reference states what exists in this build, generated from the code.</p>\n</div>\n", SITE_SYSTEM_NAME)
	// The search field of this page, then the chart, which moves while the
	// reader types: both stay in view, and the list of results opens under
	// the chart, over the cards. With no script the field stays hidden, and
	// the chart and the cards carry the page.
	strings.write_string(&b, "<div class=\"docs-search\">\n")
	strings.write_string(&b, site_search_field_html(.Docs_Home))
	site_search_chart(&b, site, path, site_search_chart_rows(site, entries))
	strings.write_string(&b, "</div>\n")

	// The two cards list every guide and every table of the reference, one
	// row each; the heading of a card is the link to its index. The bar
	// gives the status, the news and the releases: the page has no row of
	// doors.
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
	if site_page_exists(site, reference_page) {
		strings.write_string(&b, "<section class=\"card accent-memory\" aria-labelledby=\"reference\">\n")
		fmt.sbprintf(&b, "<h2 id=\"reference\"><a href=\"%s\">%s</a></h2>\n", site_page_link(site, path, reference_page), site_section_titles[.Reference])
		strings.write_string(&b, "<p>What exists in this build, generated from the code.</p>\n<ul class=\"docs-rows docs-rows-one-line\">\n")
		for entry in site.reference_entries {
			site_docs_row(&b, Site_Docs_Row{kind = entry.kind, name = entry.title, address = site_page_link(site, path, entry.path), about = entry.what, count = entry.count, has_count = true})
		}
		strings.write_string(&b, "</ul>\n</section>\n")
	}
	strings.write_string(&b, "</div>\n")
	return strings.to_string(b)
}
