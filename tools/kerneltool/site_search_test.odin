package kerneltool

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
		{path = "guides/NETWORK/index.html", title = "Network", description = "The guide."},
		{path = "reference/glossary/index.html", title = "Glossary", description = "The terms."},
		{path = "news/index.html", title = "News", description = "The news."},
	}
	for page in pages {
		append(&site.pages, page)
	}
	headings := []Site_Heading{{level = 1, text = "Network", id = "network"}, {level = 2, text = "The `frames`", id = "the-frames", first_paragraph = "The **first** paragraph."}}
	site.guides = make([dynamic]Site_Guide, context.temp_allocator)
	append(&site.guides, Site_Guide{source = "docs/NETWORK.md", path = "guides/NETWORK/index.html", title = "Network", headings = headings})
	entry, _ := news_parse("2026-11-11-a-thing.md", "title: A \"thing\" </script>\ndate: 2026-11-11\nrelease: next\npicture: none\nkind: Shown\nguide: none\n\nIt runs. More.\n")
	site.news = []Site_News{{entry = entry, anchor = site_news_anchor(entry)}}
	site.gaps = []Site_Gap{}

	written := make(map[string]string, context.temp_allocator)
	written["index.html"] = "<h1>modus</h1>"
	written["guides/NETWORK/index.html"] = "<h1 id=\"network\">Network</h1><h2 id=\"the-frames\">The frames</h2>"
	written["reference/glossary/index.html"] = "<h1>Glossary</h1><tr id=\"term-module-metadata\"></tr><tr id=\"term-module\"></tr>"
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
	no_anchor["guides/NETWORK/index.html"] = "<h1 id=\"network\">Network</h1>"
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
	testing.expect(t, strings.has_prefix(index, "{\"kinds\":[\"page\",\"module\""))
	testing.expect(t, strings.contains(index, "\"A \\\"thing\\\" \\u003c/script\\u003e\""))
	testing.expect(t, !strings.contains(index, "</script"))
	// With no site address the link of a page names its index.html; with
	// one, its folder.
	testing.expect(t, strings.contains(index, "[\"news/index.html\",\"News\"]"))
	site.address = "https://example.org/modus"
	published := site_search_index_json(&site, entries, site.pages[:])
	testing.expect(t, strings.contains(published, "[\"news/\",\"News\"]"))
	testing.expect(t, strings.contains(published, "[\"./\",\"modus\"]"))
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
	html := site_page_html(&site, Site_Page{path = "guides/A/index.html", title = "A", description = "The guide A.", section = .Guides, body = "<h1>A</h1>"})
	testing.expect_value(t, site_inline_code_problem(html), "")
	testing.expect(t, strings.contains(html, "<script src=\"../../search.js\" data-index=\"search.json\" defer></script>"))
	testing.expect(t, strings.contains(html, "<div class=\"search\" role=\"search\" hidden>"))
}
