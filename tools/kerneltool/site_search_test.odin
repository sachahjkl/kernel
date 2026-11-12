package kerneltool

import "core:fmt"
import "core:strings"
import "core:testing"
import "support:line_editor"

// The matcher of the console over the table that the script also carries:
// a change of the score or of the order in support/line_editor fails here
// first. Then the table gets the new scores, and the self test of the
// script (?selftest=1) fails until the script has the new rule.
@(test)
site_search_matcher_table :: proc(t: ^testing.T) {
	Case :: struct {
		group, query: string,
	}
	cases := make([dynamic]Case, context.temp_allocator)
	for order in site_search_match_orders {
		seen := false
		for item in cases {
			seen ||= item.group == order.group && item.query == order.query
		}
		if !seen {
			append(&cases, Case{order.group, order.query})
		}
	}
	testing.expect(t, len(cases) >= 7, "the table has fewer cases than the console tests")
	for item in cases {
		candidates := make([dynamic]line_editor.Candidate, context.temp_allocator)
		for name in site_search_match_names {
			if name.group == item.group {
				append(&candidates, line_editor.Candidate{name = name.name, tie_order = name.tie_order})
			}
		}
		expected := make([dynamic]Site_Search_Match_Order, context.temp_allocator)
		for order in site_search_match_orders {
			if order.group == item.group && order.query == item.query {
				append(&expected, order)
			}
		}
		ranked: [line_editor.RANKED_CAPACITY]line_editor.Ranked
		kept, matched := line_editor.rank_candidates(item.query, candidates[:], ranked[:])
		testing.expectf(t, kept == len(expected) && matched == len(expected), "%s %q: %d kept, %d matched, not %d", item.group, item.query, kept, matched, len(expected))
		for row, place in ranked[:min(kept, len(expected))] {
			name := candidates[row.candidate].name
			testing.expectf(t, name == expected[place].name && row.score == expected[place].score, "%s %q: place %d is %q with %d, not %q with %d", item.group, item.query, place, name, row.score, expected[place].name, expected[place].score)
		}
	}
}

@(test)
site_search_script_carries_the_rule_and_the_table :: proc(t: ^testing.T) {
	script := site_search_script()
	testing.expect(t, !strings.contains(script, "/*RULE*/null"), "the rule is not in the script")
	testing.expect(t, !strings.contains(script, "/*CASES*/null"), "the table is not in the script")
	testing.expect(t, strings.contains(script, site_search_cases_json()))
	testing.expect(t, strings.contains(script, "\"match\":16,\"start\":32,\"segment\":24,\"sideBySide\":16,\"gapOpen\":3,\"gapByte\":1"))
	testing.expect(t, strings.contains(script, "\"rows\":8"))
	testing.expect(t, strings.contains(script, "support/line_editor/fuzzy_match.odin"))
	testing.expect(t, strings.contains(script, " cases pass\""), "the self test does not print its count of cases")
	// The script is a file of the site, never a part of a page.
	testing.expect(t, !strings.contains(script, "</script"))
}

@(test)
site_search_json_escapes :: proc(t: ^testing.T) {
	escaped :: proc(text: string) -> string {
		b := strings.builder_make(context.temp_allocator)
		site_json_string(&b, text)
		return strings.to_string(b)
	}
	testing.expect_value(t, escaped("plain"), "\"plain\"")
	testing.expect_value(t, escaped("a \"quote\""), "\"a \\\"quote\\\"\"")
	testing.expect_value(t, escaped("a \\ b"), "\"a \\\\ b\"")
	testing.expect_value(t, escaped("</script><!--"), "\"\\u003c/script\\u003e\\u003c!--\"")
	testing.expect_value(t, escaped("a & b"), "\"a \\u0026 b\"")
	testing.expect_value(t, escaped("one\u2028two\u2029"), "\"one\\u2028two\\u2029\"")
	testing.expect_value(t, escaped("a\nb\x01\x7f"), "\"a\\nb\\u0001\\u007f\"")
	testing.expect_value(t, escaped("é ü"), "\"é ü\"")
	testing.expect_value(t, escaped("a\xffb"), "\"a\\ufffdb\"")
	testing.expect_value(t, escaped(""), "\"\"")
}

@(test)
site_search_plain_and_cut :: proc(t: ^testing.T) {
	testing.expect_value(t, site_search_plain("**A** `b` [c](d.md)  x\ty"), "A b c x y")
	testing.expect_value(t, site_search_plain("![alt](p.png) end"), "alt end")
	testing.expect_value(t, site_search_cut("short", 10), "short")
	cut := site_search_cut("ééééééééé", 10)
	testing.expect(t, len(cut) <= 10, "the cut text is longer than its bound")
	testing.expect_value(t, cut, "ééé...")
	testing.expect_value(t, site_search_cut("a word that is long", 12), "a word th...")
}

@(test)
site_search_index_of_a_small_site :: proc(t: ^testing.T) {
	site := test_site()
	pages := [?]Site_Page {
		{path = "index.html", title = "modus", description = "The home."},
		{path = SITE_GUIDE_FOLDER + "/NETWORK/" + SITE_PAGE, title = "Network", description = "The guide."},
		{path = SITE_GLOSSARY_FOLDER + "/" + SITE_PAGE, title = "Glossary", description = "The terms."},
		{path = "news/index.html", title = "News", description = "The news."},
	}
	for page in pages {
		append(&site.pages, page)
	}
	headings := []Site_Heading{{level = 1, text = "Network", id = "network"}, {level = 2, text = "The `frames`", id = "the-frames", first_paragraph = "The **first** paragraph."}}
	site.guides = make([dynamic]Site_Guide, context.temp_allocator)
	append(&site.guides, Site_Guide{source = "docs/NETWORK.md", path = SITE_GUIDE_FOLDER + "/NETWORK/" + SITE_PAGE, title = "Network", headings = headings})
	entry, _ := news_parse("2026-11-11-a-thing.md", "title: A \"thing\" </script>\ndate: 2026-11-11\nrelease: next\npicture: none\nkind: Shown\nguide: none\n\nIt runs. More.\n")
	site.news = []Site_News{{entry = entry, anchor = site_news_anchor(entry)}}
	site.gaps = []Site_Gap{}

	written := make(map[string]string, context.temp_allocator)
	written["index.html"] = "<h1>modus</h1>"
	written[SITE_GUIDE_FOLDER + "/NETWORK/" + SITE_PAGE] = "<h1 id=\"network\">Network</h1><h2 id=\"the-frames\">The frames</h2>"
	written[SITE_GLOSSARY_FOLDER + "/" + SITE_PAGE] = "<h1>Glossary</h1><tr id=\"term-module-metadata\"></tr><tr id=\"term-module\"></tr>"
	written["news/index.html"] = "<h1>News</h1><article id=\"news-2026-11-11-a-thing\"></article>"

	entries := site_search_entries(&site)
	problems := site_search_problems(entries, written)
	testing.expectf(t, len(problems) == 0, "problems: %v", problems)
	counts: [Site_Search_Kind]int
	for item in entries {
		counts[item.kind] += 1
	}
	testing.expect_value(t, counts[.Page], 4)
	testing.expect_value(t, counts[.Guide_Section], 1)
	testing.expect_value(t, counts[.Term], 2)
	testing.expect_value(t, counts[.News], 1)
	for item in entries {
		if item.kind == .Guide_Section {
			testing.expect_value(t, item.title, "The frames")
			testing.expect_value(t, item.text, "The first paragraph.")
		}
	}

	// An entry that names an id that the page does not have.
	no_anchor := make(map[string]string, context.temp_allocator)
	for path, html in written {
		no_anchor[path] = html
	}
	no_anchor[SITE_GUIDE_FOLDER + "/NETWORK/" + SITE_PAGE] = "<h1 id=\"network\">Network</h1>"
	testing.expect(t, len(site_search_problems(entries, no_anchor)) > 0, "an absent anchor is not found")
	// A page with no entry.
	no_entry := make(map[string]string, context.temp_allocator)
	for path, html in written {
		no_entry[path] = html
	}
	no_entry["status/index.html"] = "<h1>Status</h1>"
	testing.expect(t, len(site_search_problems(entries, no_entry)) > 0, "a page with no entry is not found")

	// The JSON of the index: the title of the news entry is escaped.
	index := site_search_index_json(&site, entries, site.pages[:])
	testing.expect(t, strings.has_prefix(index, "{\"kinds\":[[\"page\",\"guide\"],[\"module\",\"module\"],[\"program\",\"module\"]"), index[:min(len(index), 120)])
	testing.expect(t, strings.contains(index, "[\"news entry\",\"time\"]"))
	testing.expect(t, strings.contains(index, "\"A \\\"thing\\\" \\u003c/script\\u003e\""))
	testing.expect(t, !strings.contains(index, "</script"))
	// With no site address the link of a page names its index.html; with
	// one, its folder.
	testing.expect(t, strings.contains(index, "[\"news/index.html\",\"News\"]"))
	site.address = "https://example.org/modus"
	published := site_search_index_json(&site, entries, site.pages[:])
	testing.expect(t, strings.contains(published, "[\"news/\",\"News\"]"))
	testing.expect(t, strings.contains(published, "[\"./\",\"modus\"]"))
	testing.expect(t, strings.contains(published, "[\"docs/guides/NETWORK/\",\"Network\"]"))

	// The name of a kind for a count reads right for one and for more.
	testing.expect_value(t, site_search_kind_words(.Property, 2), "properties")
	testing.expect_value(t, site_search_kind_words(.Property, 1), "property")
	testing.expect_value(t, site_search_kind_words(.Error_Kind, 3), "error kinds")
	testing.expect_value(t, site_search_kind_words(.News, 1), "news entry")
	testing.expect_value(t, site_search_kind_words(.News, 16), "news entries")
	testing.expect_value(t, site_search_kind_words(.License_Row, 25), "license rows")
}

// The entries of a small index for the chart of the docs home: three
// terms, two pages, one export, one news entry and one release; no
// property. The glossary and the news have their page; the releases have
// none in this site.
@(private = "file")
chart_test_site :: proc() -> (site: Site, entries: []Site_Search_Entry) {
	site = test_site()
	append(&site.pages, Site_Page{path = site_section_page(.Docs), title = "Docs", description = "The docs."})
	append(&site.pages, Site_Page{path = site_page_file(SITE_GLOSSARY_FOLDER), title = "Glossary", description = "The terms."})
	append(&site.pages, Site_Page{path = site_section_page(.News), title = "News", description = "The news."})
	list := make([dynamic]Site_Search_Entry, context.temp_allocator)
	append(&list, Site_Search_Entry{title = "a release", kind = .Release})
	append(&list, Site_Search_Entry{title = "a term", kind = .Term})
	append(&list, Site_Search_Entry{title = "a page", kind = .Page})
	append(&list, Site_Search_Entry{title = "an entry", kind = .News})
	append(&list, Site_Search_Entry{title = "a second term", kind = .Term})
	append(&list, Site_Search_Entry{title = "an export", kind = .Export})
	append(&list, Site_Search_Entry{title = "a second page", kind = .Page})
	append(&list, Site_Search_Entry{title = "a third term", kind = .Term})
	return site, list[:]
}

// The chart of what the search finds: one row for each kind with entries,
// the largest count first and the tie order for two equal counts; the
// largest bar at its whole length, the others in proportion, each with the
// least length; a link for a kind whose page exists, none for the others;
// the name for one entry and for more; the total, the sum of the rows; the
// data attributes that the script reads; no style attribute.
@(test)
site_search_chart_of_a_small_index :: proc(t: ^testing.T) {
	site, entries := chart_test_site()
	rows := site_search_chart_rows(&site, entries)
	expected_kinds := [?]Site_Search_Kind{.Term, .Page, .Export, .News, .Release}
	testing.expect_value(t, len(rows), len(expected_kinds))
	sum := 0
	for row, place in rows {
		sum += row.count
		if place < len(expected_kinds) {
			testing.expectf(t, row.kind == expected_kinds[place], "place %d holds %v, not %v", place, row.kind, expected_kinds[place])
		}
	}
	testing.expect_value(t, sum, len(entries))
	if len(rows) != len(expected_kinds) {
		return
	}
	testing.expect_value(t, rows[0].count, 3)
	testing.expect_value(t, rows[0].page, site_page_file(SITE_GLOSSARY_FOLDER))
	testing.expect_value(t, rows[1].page, "")
	testing.expect_value(t, rows[2].page, "")
	testing.expect_value(t, rows[3].page, site_section_page(.News))
	testing.expect_value(t, rows[4].page, "")

	testing.expect_value(t, site_search_chart_length(3, 3), "100.0%")
	testing.expect_value(t, site_search_chart_length(2, 3), "66.6%")
	testing.expect_value(t, site_search_chart_length(1, 3), "33.3%")
	testing.expect_value(t, site_search_chart_length(1, 1000), "0.1%")
	testing.expect_value(t, site_search_chart_length(0, 0), "0.0%")

	path := site_section_page(.Docs)
	b := strings.builder_make(context.temp_allocator)
	site_search_chart(&b, &site, path, rows)
	html := strings.to_string(b)
	row_start :: proc(kind: Site_Search_Kind, count: int) -> string {
		return fmt.tprintf("<li class=\"search-chart-row\" data-kind=\"%d\" data-count=\"%d\" data-singular=\"%s\" data-plural=\"%s\">", int(kind), count, site_search_kinds[kind].name, site_search_kind_words(kind, 2))
	}
	glossary_link := site_page_link(&site, path, site_page_file(SITE_GLOSSARY_FOLDER))
	news_link := site_page_link(&site, path, site_section_page(.News))
	expected_rows := [?]string {
		strings.concatenate({row_start(.Term, 3), "<a class=\"search-chart-target\" href=\"", glossary_link, "\"><span class=\"value-icon value-guide\" aria-hidden=\"true\"></span><span class=\"search-chart-name\">terms</span><svg class=\"search-chart-bar value-guide\" aria-hidden=\"true\" focusable=\"false\"><rect class=\"search-chart-length\" width=\"100.0%\" height=\"100%\"/><rect class=\"search-chart-least\" width=\"4\" height=\"100%\"/></svg><code class=\"value value-number search-chart-count\">3</code></a></li>"}, context.temp_allocator),
		strings.concatenate({row_start(.Page, 2), "<span class=\"search-chart-target\"><span class=\"value-icon value-guide\" aria-hidden=\"true\"></span><span class=\"search-chart-name\">pages</span><svg class=\"search-chart-bar value-guide\" aria-hidden=\"true\" focusable=\"false\"><rect class=\"search-chart-length\" width=\"66.6%\""}, context.temp_allocator),
		strings.concatenate({row_start(.Export, 1), "<span class=\"search-chart-target\"><span class=\"value-icon value-command\" aria-hidden=\"true\"></span><span class=\"search-chart-name\">export</span>"}, context.temp_allocator),
		strings.concatenate({row_start(.News, 1), "<a class=\"search-chart-target\" href=\"", news_link, "\"><span class=\"value-icon value-time\" aria-hidden=\"true\"></span><span class=\"search-chart-name\">news entry</span><svg class=\"search-chart-bar value-time\" aria-hidden=\"true\" focusable=\"false\"><rect class=\"search-chart-length\" width=\"33.3%\""}, context.temp_allocator),
		strings.concatenate({row_start(.Release, 1), "<span class=\"search-chart-target\">"}, context.temp_allocator),
	}
	last_place := -1
	for expected in expected_rows {
		place := strings.index(html, expected)
		testing.expectf(t, place > last_place, "the chart has not this row after the row before it: %s\n%s", expected, html)
		last_place = max(last_place, place)
	}
	testing.expectf(t, !strings.contains(html, fmt.tprintf("data-kind=\"%d\"", int(Site_Search_Kind.Property))), "a kind with no entry has a row")
	testing.expect_value(t, strings.count(html, "<li "), len(rows))
	testing.expect_value(t, strings.count(html, "<rect class=\"search-chart-least\" width=\"4\""), len(rows))
	testing.expect_value(t, strings.count(html, "width=\"100.0%\""), 1)
	// The total: a number value, the sum of the rows.
	testing.expect(t, strings.contains(html, fmt.tprintf("<code class=\"value value-number\">%d</code> <span id=\"search-chart-words\">entries in the index</span>", sum)), html)
	testing.expect(t, strings.contains(html, "<span id=\"search-chart-matched\" hidden><code class=\"value value-number\" id=\"search-chart-matched-count\">0</code> of </span>"))
	testing.expect(t, strings.contains(html, fmt.tprintf("<ol class=\"search-chart-rows\" id=\"search-chart\" data-least=\"%d\">", SITE_SEARCH_CHART_LEAST_LENGTH)))
	testing.expect(t, strings.contains(html, "<h2 id=\"search-finds\">What the search finds</h2>"))
	testing.expect_value(t, site_heading_value_problem(html), "")
	testing.expect(t, !strings.contains(html, "style="), "the chart holds a style attribute")
	testing.expect_value(t, site_inline_code_problem(html), "")

	// The script reads what the markup holds: the id of the chart, the
	// attributes of a row and the classes of its parts.
	script := site_search_script()
	for name in ([]string{"\"search-chart\"", "li[data-kind]", "dataset.kind", "dataset.singular", "dataset.plural", "dataset.least", ".search-chart-target", ".search-chart-name", ".search-chart-count", ".search-chart-length", ".search-chart-least", "\"search-chart-matched\"", "\"search-chart-matched-count\"", "\"search-chart-words\"", "search-chart-none", "aria-pressed"}) {
		testing.expectf(t, strings.contains(script, name), "the script does not read %s", name)
	}
}

// The docs home: no paragraph of counts under the search field; the chart
// after the cards; no style attribute on the page.
@(test)
site_docs_home_holds_the_chart :: proc(t: ^testing.T) {
	site, entries := chart_test_site()
	path := site_section_page(.Docs)
	body := site_docs_home_body(&site, path, entries)
	testing.expect(t, !strings.contains(body, "docs-knows"), "the docs home has the paragraph of the counts")
	testing.expect(t, !strings.contains(body, "The search knows"), "the docs home has the paragraph of the counts")
	field := strings.index(body, "id=\"" + SITE_SEARCH_FIELD_ID + "\"")
	parts := strings.index(body, "<div class=\"docs-parts\">")
	chart := strings.index(body, "id=\"search-chart\"")
	testing.expectf(t, field >= 0 && parts > field && chart > parts, "the order of the docs home: the field at %d, the cards at %d, the chart at %d", field, parts, chart)
	html := site_page_html(&site, Site_Page{path = path, is_index = true, title = "Docs", description = "The docs.", section = .Docs, search_in_page = true, body = body})
	testing.expect(t, !strings.contains(html, "style="), "the docs home holds a style attribute")
	testing.expect_value(t, site_inline_code_problem(html), "")
}

// The cases of the counts by kind that the script runs in its self test,
// run here over the matcher of the console: the counts of each tie order,
// the restriction of the list to one tie order, and the empty field.
@(test)
site_search_kind_cases_table :: proc(t: ^testing.T) {
	testing.expect(t, len(site_search_kind_cases) >= 5, "the table has too few cases of the counts by kind")
	for kind_case in site_search_kind_cases {
		counts: [8]int
		kept_candidates := make([dynamic]line_editor.Candidate, context.temp_allocator)
		for name in site_search_match_names {
			if name.group != kind_case.group {
				continue
			}
			if _, _, is_match := line_editor.fuzzy_match(kind_case.query, name.name); is_match {
				counts[name.tie_order] += 1
			}
			if kind_case.only < 0 || int(name.tie_order) == kind_case.only {
				append(&kept_candidates, line_editor.Candidate{name = name.name, tie_order = name.tie_order})
			}
		}
		parts := make([dynamic]string, context.temp_allocator)
		for count, tie in counts {
			if count > 0 {
				append(&parts, fmt.tprintf("%d:%d", tie, count))
			}
		}
		counts_text := strings.join(parts[:], " ", context.temp_allocator)
		testing.expectf(t, counts_text == kind_case.counts, "%s %q: the counts %s, not %s", kind_case.group, kind_case.query, counts_text, kind_case.counts)
		ranked: [line_editor.RANKED_CAPACITY]line_editor.Ranked
		kept, matched := line_editor.rank_candidates(kind_case.query, kept_candidates[:], ranked[:])
		testing.expectf(t, matched == kind_case.listed, "%s %q in %d: %d listed, not %d", kind_case.group, kind_case.query, kind_case.only, matched, kind_case.listed)
		first := kept > 0 ? kept_candidates[ranked[0].candidate].name : ""
		testing.expectf(t, first == kind_case.first, "%s %q in %d: the first is %q, not %q", kind_case.group, kind_case.query, kind_case.only, first, kind_case.first)
	}
	testing.expect(t, strings.contains(site_search_cases_json(), "\"kinds\":[[\"tie\",\"set\",-1,\"1:2 2:1 3:1\",4,\"set.long_name\"]"))
}

@(test)
site_pages_hold_no_inline_code :: proc(t: ^testing.T) {
	testing.expect_value(t, site_inline_code_problem("<head><script src=\"search.js\" defer></script></head><p>&lt;script&gt; is text</p>"), "")
	testing.expect(t, site_inline_code_problem("<script>alert(1)</script>") != "")
	testing.expect(t, site_inline_code_problem("<script src=\"a.js\">alert(1)</script>") != "")
	testing.expect(t, site_inline_code_problem("<style>p {}</style>") != "")
	testing.expect(t, site_inline_code_problem("<p style=\"color: red\">x</p>") != "")
	// The frame of a page: its one script is a file.
	site := test_site()
	site.release = "0.1.0"
	html := site_page_html(&site, Site_Page{path = SITE_GUIDE_FOLDER + "/A/" + SITE_PAGE, title = "A", description = "The guide A.", section = .Guides, body = "<h1>A</h1>"})
	testing.expect_value(t, site_inline_code_problem(html), "")
	testing.expect(t, strings.contains(html, "<script src=\"../../../search.js\" data-index=\"search.json\" defer></script>"))
	testing.expect(t, strings.contains(html, "<div class=\"search\" role=\"search\" hidden>"))
}
