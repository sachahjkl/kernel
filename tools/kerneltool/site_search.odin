// The search of the site (docs/SITE.md, "The search"): one index file,
// search.json, and one small script, search.js, that the tool writes. No
// server and no request to another host: the script reads the index of
// this site on the first key, and filters it with the fuzzy match and the
// order of the console of the system (support/line_editor/fuzzy_match.odin).
//
// The match of the script is a port of that file, rule for rule. Two things
// keep the two in step:
//   - the tool writes the scoring constants of support/line_editor into the
//     script, so a change of a constant reaches the script at the next site;
//   - site_search_match_names and site_search_match_orders below are one
//     table of queries, names and expected scores and orders. The host test
//     site_search_matcher_table runs the matcher of Odin over it, and the
//     tool writes the same table into the script, which runs it with
//     ?selftest=1 in the address of a page. A change of the rule in Odin
//     fails the host test until the table has the new scores; the new table
//     then fails the self test of the script until the script has the new rule.
package kerneltool

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "support:line_editor"

SITE_SEARCH_INDEX :: "search.json"
SITE_SEARCH_SCRIPT :: "search.js"
// The bytes of the text of an entry: the line under the list for the chosen row.
SITE_SEARCH_TEXT_LIMIT :: 120
// The bytes of a title: the match reads no more of a name.
SITE_SEARCH_TITLE_LIMIT :: line_editor.NAME_SCAN_LIMIT
// The entries of the index: a ranking of the console reads no more names, and
// the script reads all of them only under this count.
SITE_SEARCH_ENTRY_LIMIT :: line_editor.CANDIDATE_SCAN_LIMIT
// The bytes of the index: the script fetches it whole on the first key.
SITE_SEARCH_INDEX_BYTE_LIMIT :: 1024 * 1024
// The rows of the list, as the completion list of the console.
SITE_SEARCH_ROWS :: 8

// What an entry of the index is. The order is the tie order of the
// match: of two entries with one score, the kind that comes first here
// comes first in the list.
Site_Search_Kind :: enum u8 {
	Page,
	Module,
	Program,
	Export,
	Operation,
	Error_Kind,
	Console_Command,
	Term,
	Guide_Section,
	Property,
	News,
	Release,
	Gap,
	License_Row,
	Type,
}

// What the site shows of a kind of entry: its name for one entry (the list
// of results and the chart of the docs home give it), the value kind whose
// icon and color it takes, so that the list and the chart show one look for
// one kind, and the folder of the one page that lists every entry of the
// kind. No page lists every page or every export: their folder is "".
Site_Search_Kind_Description :: struct {
	name:       string,
	value_kind: Site_Value_Kind,
	folder:     string,
}

// The one table of the kinds of entries. The chart of the docs home tells
// the kinds apart by their icons and their colors, so the kinds with many
// entries have looks of their own: a page is a file of the site, a term
// has the kind of the glossary, an export (a procedure that a program
// calls in a module) the arrow into a box of a call, a license row the
// mark of what a license grants. A module and a program share the look of
// the one page that lists both.
site_search_kinds := [Site_Search_Kind]Site_Search_Kind_Description {
	.Page            = {name = "page", value_kind = .File, folder = ""},
	.Module          = {name = "module", value_kind = .Module, folder = SITE_MODULES_FOLDER},
	.Program         = {name = "program", value_kind = .Module, folder = SITE_MODULES_FOLDER},
	.Export          = {name = "export", value_kind = .Operation, folder = ""},
	.Operation       = {name = "operation", value_kind = .Operation, folder = SITE_OPERATIONS_FOLDER},
	.Error_Kind      = {name = "error kind", value_kind = .Status, folder = SITE_ERRORS_FOLDER},
	.Console_Command = {name = "console command", value_kind = .Command, folder = SITE_CONSOLE_FOLDER},
	.Term            = {name = "term", value_kind = .Term, folder = SITE_GLOSSARY_FOLDER},
	.Guide_Section   = {name = "guide section", value_kind = .Guide, folder = SITE_GUIDE_FOLDER},
	.Property        = {name = "property", value_kind = .Status, folder = SITE_STATUS_FOLDER},
	.News            = {name = "news entry", value_kind = .Time, folder = SITE_NEWS_FOLDER},
	.Release         = {name = "release", value_kind = .Version, folder = SITE_RELEASES_FOLDER},
	.Gap             = {name = "gap", value_kind = .No, folder = SITE_STATUS_FOLDER},
	.License_Row     = {name = "license row", value_kind = .Grant, folder = SITE_LICENSES_FOLDER},
	.Type            = {name = "type", value_kind = .Type, folder = SITE_TYPES_FOLDER},
}

// site_search_kind_words gives the name of a kind of entry for a count:
// "1 term", "3 terms", "2 properties", "1 news entry", "16 news entries".
site_search_kind_words :: proc(kind: Site_Search_Kind, count: int) -> string {
	name := site_search_kinds[kind].name
	if count == 1 {
		return name
	}
	if strings.has_suffix(name, "y") {
		return strings.concatenate({name[:len(name) - 1], "ies"}, context.temp_allocator)
	}
	return strings.concatenate({name, "s"}, context.temp_allocator)
}

// site_search_kind_page gives the page that lists every entry of a kind,
// when the site has it, or "".
site_search_kind_page :: proc(site: ^Site, kind: Site_Search_Kind) -> string {
	folder := site_search_kinds[kind].folder
	if folder == "" {
		return ""
	}
	page := site_page_file(folder)
	return site_page_exists(site, page) ? page : ""
}

Site_Search_Entry :: struct {
	title:  string, // What the match reads: plain text, at most SITE_SEARCH_TITLE_LIMIT bytes.
	page:   string, // The path of its page in the site.
	anchor: string, // An id of that page, or "" for the page itself.
	kind:   Site_Search_Kind,
	text:   string, // Plain text, at most SITE_SEARCH_TEXT_LIMIT bytes.
}

// The table of the matcher. A name belongs to a group; a case is a group
// and a query; its expected rows are the names that match, in the order of
// the ranking, each with its score. The group "system" holds real names of
// the system (the exports of monitor, storage, manual, compositor, settings
// and date); the scores are those of docs/CONSOLE.md, section 3. The group
// "tie" shows the tie order before the length.
Site_Search_Match_Name :: struct {
	group:     string,
	name:      string,
	tie_order: u32,
}

Site_Search_Match_Order :: struct {
	group: string,
	query: string,
	name:  string,
	score: int,
}

site_search_match_names := [?]Site_Search_Match_Name {
	{"system", "monitor.programs", 0},
	{"system", "monitor.counts", 0},
	{"system", "monitor.count", 0},
	{"system", "monitor.counts_named", 0},
	{"system", "monitor.served", 0},
	{"system", "storage.write", 0},
	{"system", "storage.read", 0},
	{"system", "storage.size", 0},
	{"system", "storage.remove", 0},
	{"system", "storage.objects", 0},
	{"system", "storage.stores", 0},
	{"system", "storage.versions", 0},
	{"system", "storage.version", 0},
	{"system", "storage.restore", 0},
	{"system", "storage.clone", 0},
	{"system", "storage.compare", 0},
	{"system", "manual.modules", 0},
	{"system", "manual.exports", 0},
	{"system", "manual.imports", 0},
	{"system", "manual.importers", 0},
	{"system", "manual.exporters", 0},
	{"system", "manual.described", 0},
	{"system", "manual.handles", 0},
	{"system", "manual.slots", 0},
	{"system", "manual.segments", 0},
	{"system", "manual.running", 0},
	{"system", "manual.replacements", 0},
	{"system", "manual.problem", 0},
	{"system", "manual.overview", 0},
	{"system", "manual.show", 0},
	{"system", "manual.about", 0},
	{"system", "manual.signature", 0},
	{"system", "compositor.pointer", 0},
	{"system", "compositor.windows", 0},
	{"system", "settings.set", 0},
	{"system", "settings.get", 0},
	{"system", "date.now", 0},
	{"tie", "beta.set", 2},
	{"tie", "gamma.set", 1},
	{"tie", "alpha.set", 1},
	{"tie", "set.long_name", 3},
}

site_search_match_orders := [?]Site_Search_Match_Order {
	{"system", "mcnt", "monitor.count", 123},
	{"system", "mcnt", "monitor.counts", 123},
	{"system", "mcnt", "monitor.counts_named", 123},
	{"system", "mcnt", "manual.replacements", 94},
	{"system", "MCNT", "monitor.count", 123},
	{"system", "MCNT", "monitor.counts", 123},
	{"system", "MCNT", "monitor.counts_named", 123},
	{"system", "MCNT", "manual.replacements", 94},
	{"system", "stwr", "storage.write", 144},
	{"system", "cnt", "monitor.count", 84},
	{"system", "cnt", "monitor.counts", 84},
	{"system", "cnt", "monitor.counts_named", 84},
	{"system", "cnt", "compositor.pointer", 81},
	{"system", "cnt", "manual.replacements", 59},
	{"system", "set", "settings.get", 112},
	{"system", "set", "settings.set", 112},
	{"system", "set", "storage.stores", 69},
	{"system", "set", "storage.write", 67},
	{"system", "set", "storage.restore", 67},
	{"system", "set", "storage.objects", 65},
	{"system", "set", "manual.segments", 64},
	{"system", "mod", "manual.modules", 104},
	{"system", "mod", "monitor.served", 65},
	{"system", "mod", "monitor.counts_named", 59},
	{"system", "mod", "compositor.windows", 34},
	{"system", "monitor.count", "monitor.count", 456},
	{"system", "monitor.count", "monitor.counts", 456},
	{"system", "monitor.count", "monitor.counts_named", 456},
	{"tie", "set", "set.long_name", 112},
	{"tie", "set", "alpha.set", 104},
	{"tie", "set", "gamma.set", 104},
	{"tie", "set", "beta.set", 104},
}

// The cases of the counts by kind, which the chart of the docs home shows
// and the restriction of the list to one kind uses. The tie order of a
// name stands for the kind of an entry of the index. A case is a query over
// the names of a group and the tie order that the list keeps (-1: every
// one); it expects the count of the names that match for each tie order,
// as "tie:count" in the order of the tie orders, the count of the matches
// that the list keeps, and the first name of the list ("" for none). The
// empty query is the field with no text: the counts of the whole group.
Site_Search_Kind_Case :: struct {
	group:  string,
	query:  string,
	only:   int,
	counts: string,
	listed: int,
	first:  string,
}

site_search_kind_cases := [?]Site_Search_Kind_Case {
	{"tie", "set", -1, "1:2 2:1 3:1", 4, "set.long_name"},
	{"tie", "set", 1, "1:2 2:1 3:1", 2, "alpha.set"},
	{"tie", "set", 2, "1:2 2:1 3:1", 1, "beta.set"},
	{"tie", "long", -1, "3:1", 1, "set.long_name"},
	{"tie", "long", 1, "3:1", 0, ""},
	{"tie", "", -1, "1:2 2:1 3:1", 4, "alpha.set"},
	{"system", "stwr", -1, "0:1", 1, "storage.write"},
}

// The cases of the segments of the bar of the chart of the docs home: the
// counts of the kinds, in their order, and the start and the width of each
// segment, in thousandths of the bar, as "start:width". The host test
// site_search_segment_cases_table runs them over site_search_chart_segments,
// and the self test of the script over its own segments. The least share is
// SITE_SEARCH_CHART_LEAST_SHARE.
Site_Search_Segment_Case :: struct {
	counts:   string,
	segments: string,
}

site_search_segment_cases := [?]Site_Search_Segment_Case {
	{"3 0 1", "0:746 746:0 746:254"},
	{"1 1000", "0:8 8:992"},
	{"2 3 5", "0:203 203:300 503:497"},
	{"5", "0:1000"},
	{"0 0", "0:0 0:0"},
	{"", ""},
}

// site_search_cut gives a text of at most limit bytes, cut at the start of
// a character, with "..." when it is cut.
site_search_cut :: proc(text: string, limit: int) -> string {
	if len(text) <= limit {
		return text
	}
	end := max(limit - len("..."), 0)
	for end > 0 && !utf8.rune_start(text[end]) {
		end -= 1
	}
	return strings.concatenate({strings.trim_right_space(text[:end]), "..."}, context.temp_allocator)
}

// site_search_plain gives the plain text of a line of Markdown: the text of
// code spans, bold and links with no marks, the spaces made single.
site_search_plain :: proc(text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	index := 0
	for index < len(text) {
		character := text[index]
		if character == '`' {
			if end := strings.index_byte(text[index + 1:], '`'); end >= 0 {
				strings.write_string(&b, text[index + 1:index + 1 + end])
				index += end + 2
				continue
			}
		}
		if character == '*' && index + 1 < len(text) && text[index + 1] == '*' {
			index += 2
			continue
		}
		is_picture := character == '!' && index + 1 < len(text) && text[index + 1] == '['
		if character == '[' || is_picture {
			open := is_picture ? index + 1 : index
			if closing := strings.index_byte(text[open + 1:], ']'); closing >= 0 {
				after := open + 1 + closing + 1
				if after < len(text) && text[after] == '(' {
					if end := strings.index_byte(text[after + 1:], ')'); end >= 0 {
						strings.write_string(&b, text[open + 1:open + 1 + closing])
						index = after + 1 + end + 1
						continue
					}
				}
			}
		}
		strings.write_byte(&b, character == '\t' || character == '\n' || character == '\r' ? ' ' : character)
		index += 1
	}
	words := strings.fields(strings.to_string(b), context.temp_allocator)
	return strings.join(words, " ", context.temp_allocator)
}

// site_search_add appends one entry, with its title and its text made plain
// and cut to their bounds.
site_search_add :: proc(entries: ^[dynamic]Site_Search_Entry, title, page, anchor: string, kind: Site_Search_Kind, text: string) {
	append(entries, Site_Search_Entry{title = site_search_cut(site_search_plain(title), SITE_SEARCH_TITLE_LIMIT), page = page, anchor = anchor, kind = kind, text = site_search_cut(site_search_plain(text), SITE_SEARCH_TEXT_LIMIT)})
}

// site_search_entries gives the entries of the index: each page, then the
// rows and the sections that have an id on their page. Each one is taken
// from the same data as its page, so its anchor is the id that the page
// writes; site_search_problems checks it against the written pages.
site_search_entries :: proc(site: ^Site) -> []Site_Search_Entry {
	entries := make([dynamic]Site_Search_Entry, context.temp_allocator)
	for page in site.pages {
		site_search_add(&entries, page.title, page.path, "", .Page, page.description)
	}
	for item in site.reference.modules {
		kind: Site_Search_Kind = item.kind == "program" ? .Program : .Module
		site_search_add(&entries, item.build.name, item.page, "", kind, site_source_comment_plain(site, item.description.about))
		for export in item.description.exports {
			site_search_add(&entries, strings.concatenate({item.build.name, ".", export.name}, context.temp_allocator), item.page, strings.concatenate({"export-", site_slug(export.name)}, context.temp_allocator), .Export, strings.concatenate({site_export_signature(item.description, export), ": ", site_source_comment_plain(site, export.about)}, context.temp_allocator))
		}
	}
	for operation in site.reference.operations {
		if operation.member.number != 0 {
			site_search_add(&entries, operation.member.name, site_page_file(SITE_OPERATIONS_FOLDER), strings.concatenate({"operation-", site_slug(operation.member.name)}, context.temp_allocator), .Operation, site_source_comment_plain(site, operation.text))
		}
	}
	for kind in site.reference.error_kinds {
		if kind.number != 0 {
			site_search_add(&entries, kind.name, site_page_file(SITE_ERRORS_FOLDER), strings.concatenate({"kind-", site_slug(kind.name)}, context.temp_allocator), .Error_Kind, site_source_comment_plain(site, kind.comment))
		}
	}
	// Each type of the contract, by its name and by its name with its
	// package: a reader looks for "Time_Record" as the code writes it.
	types_page := site_page_file(SITE_TYPES_FOLDER)
	for type in site.types {
		text := site_source_comment_plain(site, type.description)
		if text == "" {
			text = type.declaration
		}
		title := type.name
		if type.package_name != "" {
			title = strings.concatenate({type.package_name, ".", type.name}, context.temp_allocator)
		}
		site_search_add(&entries, title, types_page, type.id, .Type, text)
	}
	for command in site.reference.console_commands {
		site_search_add(&entries, command.name, site_page_file(SITE_CONSOLE_FOLDER), strings.concatenate({"command-", site_slug(command.name)}, context.temp_allocator), .Console_Command, strings.concatenate({site_console_signature(command), ": ", site_source_comment_plain(site, command.about)}, context.temp_allocator))
	}
	for term in site.terms {
		site_search_add(&entries, term.name, site_page_file(SITE_GLOSSARY_FOLDER), term.id, .Term, term.definition)
	}
	for guide in site.guides {
		for heading in guide.headings {
			if heading.level == 2 || heading.level == 3 {
				site_search_add(&entries, heading.text, guide.path, heading.id, .Guide_Section, heading.first_paragraph != "" ? heading.first_paragraph : guide.title)
			}
		}
	}
	status_page := site_section_page(.Status)
	for property in site.principles.properties {
		site_search_add(&entries, property.title, status_page, fmt.tprintf("property-%d", property.number), .Property, fmt.tprintf("%s. %s", property.status, property.sentence))
	}
	for item in site.news {
		site_search_add(&entries, item.entry.title, site_section_page(.News), item.anchor, .News, site_news_lead(item.entry))
	}
	for changelog_release in site.changelog.releases {
		number := release_number_text(changelog_release.number)
		first := len(changelog_release.entries) > 0 ? entry_joined(changelog_release.entries[0].lines) : ""
		site_search_add(&entries, number, site_section_page(.Releases), site_release_id(number), .Release, fmt.tprintf("%s: %s", changelog_release.date, first))
	}
	for gap in site.gaps {
		site_search_add(&entries, gap.text, status_page, fmt.tprintf("gap-%d", gap.number), .Gap, gap.group != "" ? gap.group : gap.text)
	}
	system_ids, build_ids := site_license_row_ids(site.licenses)
	license_page := site_page_file(SITE_LICENSES_FOLDER)
	for row, index in site.licenses.system_rows {
		site_search_add(&entries, row.what, license_page, system_ids[index], .License_Row, strings.concatenate({row.license, ", ", row.author}, context.temp_allocator))
	}
	for row, index in site.licenses.build_rows {
		site_search_add(&entries, row.what, license_page, build_ids[index], .License_Row, strings.concatenate({row.license, ", ", row.author}, context.temp_allocator))
	}
	return entries[:]
}

// site_search_problems checks the index against the pages that the command
// writes: the count and the bounds, each page of the site has at least one
// entry, and each entry names a page and an id of that page.
site_search_problems :: proc(entries: []Site_Search_Entry, written: map[string]string) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	if len(entries) > SITE_SEARCH_ENTRY_LIMIT {
		append(&problems, fmt.tprintf("%s: %d entries; at most %d, the names that one ranking of the console reads", SITE_SEARCH_INDEX, len(entries), SITE_SEARCH_ENTRY_LIMIT))
	}
	ids := make(map[string]map[string]bool, context.temp_allocator)
	for path, html in written {
		page_ids := make(map[string]bool, context.temp_allocator)
		for id in site_attribute_values(html, "id=\"") {
			page_ids[id] = true
		}
		ids[path] = page_ids
	}
	covered := make(map[string]bool, context.temp_allocator)
	for entry in entries {
		page_ids, is_page := ids[entry.page]
		if !is_page {
			append(&problems, fmt.tprintf("%s: the entry \"%s\" names %s, which is not a page of the site", SITE_SEARCH_INDEX, entry.title, entry.page))
			continue
		}
		covered[entry.page] = true
		if entry.anchor != "" && entry.anchor not_in page_ids {
			append(&problems, fmt.tprintf("%s: the entry \"%s\" names the id \"%s\", which %s does not have", SITE_SEARCH_INDEX, entry.title, entry.anchor, entry.page))
		}
		if entry.title == "" {
			append(&problems, fmt.tprintf("%s: an entry of %s#%s has no title", SITE_SEARCH_INDEX, entry.page, entry.anchor))
		}
	}
	for path in written {
		if path not_in covered {
			append(&problems, fmt.tprintf("%s: the page %s has no entry", SITE_SEARCH_INDEX, path))
		}
	}
	return problems[:]
}

// site_json_string writes a text as a JSON string. Each character that
// can end the string or a line of a script is escaped, also when the JSON
// is put inside a page or a script: the quote, the backslash, the control
// characters, < > & (no "</script>" in the text), U+2028 and U+2029 (line
// ends for a script). A byte that is not UTF-8 becomes U+FFFD.
site_json_string :: proc(b: ^strings.Builder, text: string) {
	strings.write_byte(b, '"')
	index := 0
	for index < len(text) {
		character, size := utf8.decode_rune_in_string(text[index:])
		switch {
		case character == utf8.RUNE_ERROR && size <= 1:
			strings.write_string(b, "\\ufffd")
			size = 1
		case character == '"':
			strings.write_string(b, "\\\"")
		case character == '\\':
			strings.write_string(b, "\\\\")
		case character == '\n':
			strings.write_string(b, "\\n")
		case character == '<':
			strings.write_string(b, "\\u003c")
		case character == '>':
			strings.write_string(b, "\\u003e")
		case character == '&':
			strings.write_string(b, "\\u0026")
		case character == 0x2028:
			strings.write_string(b, "\\u2028")
		case character == 0x2029:
			strings.write_string(b, "\\u2029")
		case character < 0x20 || character == 0x7F:
			fmt.sbprintf(b, "\\u%04x", int(character))
		case:
			strings.write_string(b, text[index:index + size])
		}
		index += size
	}
	strings.write_byte(b, '"')
}

// site_search_index_json gives search.json:
//   {"kinds": [[<name>, <value kind>], ...], "pages": [[<link>, <title>], ...],
//    "entries": [[<title>, <page index>, <anchor>, <kind index>, <text>], ...]}
// The kind index is also the tie order of the match. The value kind is the
// name of the class whose icon and color the list shows for the kind. The
// link of a page is the link from the root of the site, where the script
// is, as site_page_link writes it: the script only joins it to its folder.
site_search_index_json :: proc(site: ^Site, entries: []Site_Search_Entry, pages: []Site_Page) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\"kinds\":[")
	for kind in Site_Search_Kind {
		if kind != .Page {
			strings.write_byte(&b, ',')
		}
		strings.write_byte(&b, '[')
		site_json_string(&b, site_search_kinds[kind].name)
		strings.write_byte(&b, ',')
		site_json_string(&b, site_value_kinds[site_search_kinds[kind].value_kind].name)
		strings.write_byte(&b, ']')
	}
	strings.write_string(&b, "],\n\"pages\":[")
	page_numbers := make(map[string]int, context.temp_allocator)
	for page, index in pages {
		page_numbers[page.path] = index
		strings.write_string(&b, index > 0 ? ",\n[" : "\n[")
		site_json_string(&b, site_page_link(site, SITE_PAGE, page.path))
		strings.write_byte(&b, ',')
		site_json_string(&b, page.title)
		strings.write_byte(&b, ']')
	}
	strings.write_string(&b, "],\n\"entries\":[")
	for entry, index in entries {
		strings.write_string(&b, index > 0 ? ",\n[" : "\n[")
		site_json_string(&b, entry.title)
		fmt.sbprintf(&b, ",%d,", page_numbers[entry.page])
		site_json_string(&b, entry.anchor)
		fmt.sbprintf(&b, ",%d,", int(entry.kind))
		site_json_string(&b, entry.text)
		strings.write_byte(&b, ']')
	}
	strings.write_string(&b, "]}\n")
	return strings.to_string(b)
}

// site_search_rule_json gives the constants of the match of the console and
// the bounds of the list, as the script reads them.
site_search_rule_json :: proc() -> string {
	// The braces of the object are added around the format: the format
	// itself holds none.
	return strings.concatenate({"{", fmt.tprintf(
		"\"match\":%d,\"start\":%d,\"segment\":%d,\"sideBySide\":%d,\"gapOpen\":%d,\"gapByte\":%d,\"nameScanLimit\":%d,\"queryLimit\":%d,\"candidateScanLimit\":%d,\"rankedCapacity\":%d,\"rows\":%d,\"leastShare\":%d",
		line_editor.SCORE_MATCH,
		line_editor.SCORE_START,
		line_editor.SCORE_SEGMENT,
		line_editor.SCORE_SIDE_BY_SIDE,
		line_editor.SCORE_GAP_OPEN,
		line_editor.SCORE_GAP_BYTE,
		line_editor.NAME_SCAN_LIMIT,
		line_editor.QUERY_LIMIT,
		line_editor.CANDIDATE_SCAN_LIMIT,
		line_editor.RANKED_CAPACITY,
		SITE_SEARCH_ROWS,
		SITE_SEARCH_CHART_LEAST_SHARE,
	), "}"}, context.temp_allocator)
}

// site_search_cases_json gives the table of the matcher as the script reads
// it: {"names": [[group, name, tie order], ...], "orders": [[group, query,
// name, score], ...], "kinds": [[group, query, only, counts, listed, first], ...],
// "segments": [[counts, segments], ...]}.
site_search_cases_json :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\"names\":[")
	for name, index in site_search_match_names {
		strings.write_string(&b, index > 0 ? ",[" : "[")
		site_json_string(&b, name.group)
		strings.write_byte(&b, ',')
		site_json_string(&b, name.name)
		fmt.sbprintf(&b, ",%d]", name.tie_order)
	}
	strings.write_string(&b, "],\"orders\":[")
	for order, index in site_search_match_orders {
		strings.write_string(&b, index > 0 ? ",[" : "[")
		site_json_string(&b, order.group)
		strings.write_byte(&b, ',')
		site_json_string(&b, order.query)
		strings.write_byte(&b, ',')
		site_json_string(&b, order.name)
		fmt.sbprintf(&b, ",%d]", order.score)
	}
	strings.write_string(&b, "],\"kinds\":[")
	for kind_case, index in site_search_kind_cases {
		strings.write_string(&b, index > 0 ? ",[" : "[")
		site_json_string(&b, kind_case.group)
		strings.write_byte(&b, ',')
		site_json_string(&b, kind_case.query)
		fmt.sbprintf(&b, ",%d,", kind_case.only)
		site_json_string(&b, kind_case.counts)
		fmt.sbprintf(&b, ",%d,", kind_case.listed)
		site_json_string(&b, kind_case.first)
		strings.write_byte(&b, ']')
	}
	strings.write_string(&b, "],\"segments\":[")
	for segment_case, index in site_search_segment_cases {
		strings.write_string(&b, index > 0 ? ",[" : "[")
		site_json_string(&b, segment_case.counts)
		strings.write_byte(&b, ',')
		site_json_string(&b, segment_case.segments)
		strings.write_byte(&b, ']')
	}
	strings.write_string(&b, "],\"builds\":[")
	for build_case, index in site_build_notice_cases {
		strings.write_string(&b, index > 0 ? ",[" : "[")
		site_json_string(&b, build_case.page_commit)
		strings.write_byte(&b, ',')
		site_json_string(&b, build_case.served)
		strings.write_string(&b, build_case.older ? ",true]" : ",false]")
	}
	strings.write_string(&b, "]}")
	return strings.to_string(b)
}

// The file that names the commit and the time of the last build: the
// script asks for it to tell a page of an older build (docs/SITE.md, "A page
// of an older build").
SITE_VERSION_FILE :: "version.json"

// site_version_json gives version.json: the commit of the build ("" when
// the tool cannot read it) and its time.
site_version_json :: proc(commit, build_time: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\"commit\": ")
	site_json_string(&b, commit)
	strings.write_string(&b, ", \"built\": ")
	site_json_string(&b, build_time)
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

// One case of the line of an older build: the commit that a page names, the
// text of version.json ("" for a fetch that failed), and whether the page is
// of an older build. The self test of the script runs each one.
Site_Build_Notice_Case :: struct {
	page_commit: string,
	served:      string,
	older:       bool,
}

site_build_notice_cases := [?]Site_Build_Notice_Case {
	{"1111111111111111111111111111111111111111", `{"commit": "1111111111111111111111111111111111111111", "built": "2026-11-13 10:00 UTC"}`, false},
	{"1111111111111111111111111111111111111111", `{"commit": "2222222222222222222222222222222222222222", "built": "2026-11-13 10:10 UTC"}`, true},
	{"1111111111111111111111111111111111111111", "", false},
	{"1111111111111111111111111111111111111111", "<html>not found</html>", false},
	{"1111111111111111111111111111111111111111", `{"commit": "", "built": "2026-11-13 10:10 UTC"}`, false},
	{"1111111111111111111111111111111111111111", `{"built": "2026-11-13 10:10 UTC"}`, false},
	{"", `{"commit": "2222222222222222222222222222222222222222", "built": "2026-11-13 10:10 UTC"}`, false},
}

// site_search_script gives search.js: the source below with the rule and
// the table of the matcher in their places.
site_search_script :: proc() -> string {
	with_rule, _ := strings.replace_all(SITE_SEARCH_SCRIPT_SOURCE, "/*RULE*/null", site_search_rule_json(), context.temp_allocator)
	with_cases, _ := strings.replace_all(with_rule, "/*CASES*/null", site_search_cases_json(), context.temp_allocator)
	return with_cases
}

// The places of the search field of a page: the bar, in the place of the
// clock of the bar of the desktop, or the page itself, as a large field in
// the middle of the home of the docs. A page has one field, in one place.
Site_Search_Place :: enum {
	Bar,
	Docs_Home,
}

// The id of the search field: the script finds the field of a page by it,
// and the check of a page counts it.
SITE_SEARCH_FIELD_ID :: "site-search-box"

// The search field and its list, in one markup for both places: the class
// of its box and the words of its placeholder are the two parts that
// differ. It is hidden: the script shows it, so a page read with no script
// has no field that does nothing.
SITE_SEARCH_FIELD_FORMAT :: `<div class="%s" role="search" hidden>
<label class="search-label" for="` + SITE_SEARCH_FIELD_ID + `">Search the site</label>
<input id="` + SITE_SEARCH_FIELD_ID + `" type="text" role="combobox" aria-autocomplete="list" aria-expanded="false" aria-controls="site-search-list" aria-describedby="site-search-hint" autocomplete="off" spellcheck="false" placeholder="%s">
<div class="search-panel" id="site-search-panel" hidden>
<p class="search-hint" id="site-search-hint" aria-live="polite"></p>
<ul class="search-list" id="site-search-list" role="listbox" aria-label="Results"></ul>
<p class="search-detail" id="site-search-detail"></p>
</div>
</div>
`

// site_search_field_html gives the search field of a page in one place.
site_search_field_html :: proc(place: Site_Search_Place) -> string {
	class, placeholder: string
	switch place {
	case .Bar:
		class, placeholder = "search", "Search  /"
	case .Docs_Home:
		class, placeholder = "search search-door", "Search the whole site  /"
	}
	return fmt.tprintf(SITE_SEARCH_FIELD_FORMAT, class, placeholder)
}

// site_search_field_problem gives the fault of the search field of a
// written page, or "": a page has one search field; it is in the bar, but
// on a page that holds its own field, where it is after the bar.
site_search_field_problem :: proc(page: Site_Page, html: string) -> string {
	mark :: "id=\"" + SITE_SEARCH_FIELD_ID + "\""
	if count := strings.count(html, mark); count != 1 {
		return fmt.tprintf("%d search fields; a page has one", count)
	}
	bar_end := strings.index(html, "</header>")
	in_bar := bar_end >= 0 && strings.index(html, mark) < bar_end
	if page.search_in_page && in_bar {
		return "the search field is in the bar; this page holds its own field, and its bar has none"
	}
	if !page.search_in_page && !in_bar {
		return "the search field is not in the bar"
	}
	return ""
}

// The script. The match is support/line_editor/fuzzy_match.odin: lower, fuzzy_match,
// ranked_before and rank_candidates (with no skip of equal names), on the
// UTF-8 bytes of the query and of the name, as the console reads them.
SITE_SEARCH_SCRIPT_SOURCE :: `// The search of the site, written by kerneltool site (tools/kerneltool/site_search.odin).
// It reads search.json of this site on the first key; no other request.
// The match and the order are those of the console of the system:
// support/line_editor/fuzzy_match.odin (fuzzy_match, ranked_before,
// rank_candidates), ported rule for rule; docs/CONSOLE.md, section 3.
// The tool writes the constants of that file into RULE and its table of
// cases into CASES; ?selftest=1 in the address runs the cases.
"use strict";
(function () {
  const RULE = /*RULE*/null;
  const CASES = /*CASES*/null;
  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const script = document.currentScript;

  function lower(c) { return c >= 65 && c <= 90 ? c + 32 : c; }

  // fuzzy_match: the query and the name are arrays of bytes.
  function fuzzyMatch(query, name) {
    if (query.length > RULE.queryLimit) return null;
    if (query.length === 0) return { score: 0, places: [] };
    const scanned = name.subarray(0, Math.min(name.length, RULE.nameScanLimit));
    let next = 0, end = -1;
    for (let i = 0; i < scanned.length; i++) {
      if (lower(scanned[i]) === lower(query[next])) {
        next++;
        if (next === query.length) { end = i; break; }
      }
    }
    if (end < 0) return null;
    // Back from that place: the latest start, so the shortest window.
    const positions = new Array(query.length);
    let wanted = query.length - 1;
    for (let i = end; i >= 0 && wanted >= 0; i--) {
      if (lower(scanned[i]) === lower(query[wanted])) { positions[wanted] = i; wanted--; }
    }
    let score = 0;
    for (let n = 0; n < query.length; n++) {
      const place = positions[n];
      score += RULE.match;
      if (place === 0) score += RULE.start;
      else if (scanned[place - 1] === 46 || scanned[place - 1] === 95) score += RULE.segment;
      if (n > 0) {
        const gap = place - positions[n - 1] - 1;
        if (gap === 0) score += RULE.sideBySide;
        else score -= RULE.gapOpen + (gap - 1) * RULE.gapByte;
      }
    }
    return { score: score, places: positions };
  }

  // ranked_before: the score, then the tie order, then the shorter name,
  // then the order of the bytes.
  function rankedBefore(a, b) {
    if (a.score !== b.score) return a.score > b.score;
    if (a.tie !== b.tie) return a.tie < b.tie;
    if (a.bytes.length !== b.bytes.length) return a.bytes.length < b.bytes.length;
    for (let i = 0; i < a.bytes.length; i++) {
      if (a.bytes[i] !== b.bytes[i]) return a.bytes[i] < b.bytes[i];
    }
    return false;
  }

  // rank_candidates: candidates are {bytes, tie}; at most capacity kept.
  // byTie counts every match by its tie order, which is the kind of an
  // entry of the index. With only >= 0, the list keeps and counts the
  // matches of that tie order alone; byTie still counts all of them.
  function rank(query, candidates, capacity, only) {
    const read = Math.min(candidates.length, RULE.candidateScanLimit);
    const ranked = [];
    const byTie = new Map();
    const restricted = typeof only === "number" && only >= 0;
    let matched = 0;
    for (let index = 0; index < read; index++) {
      const candidate = candidates[index];
      const found = fuzzyMatch(query, candidate.bytes);
      if (!found) continue;
      byTie.set(candidate.tie, (byTie.get(candidate.tie) || 0) + 1);
      if (restricted && candidate.tie !== only) continue;
      matched++;
      const entry = { index: index, score: found.score, places: found.places, tie: candidate.tie, bytes: candidate.bytes };
      let place = ranked.length;
      while (place > 0 && rankedBefore(entry, ranked[place - 1])) place--;
      if (place >= capacity) continue;
      ranked.splice(place, 0, entry);
      if (ranked.length > capacity) ranked.pop();
    }
    return { ranked: ranked, matched: matched, byTie: byTie };
  }

  // The counts of the chart for the text of the field: with no text, the
  // count of each tie order over the whole index; with a text, the count of
  // the matches of each one, by the same match as the list.
  function countsFor(query, candidates) {
    if (query.length === 0) {
      const whole = new Map();
      const read = Math.min(candidates.length, RULE.candidateScanLimit);
      for (let index = 0; index < read; index++) {
        const tie = candidates[index].tie;
        whole.set(tie, (whole.get(tie) || 0) + 1);
      }
      return whole;
    }
    return rank(encoder.encode(query), candidates, 0, -1).byTie;
  }

  function countsText(counts) {
    return Array.from(counts.keys()).sort((a, b) => a - b).map(tie => tie + ":" + counts.get(tie)).join(" ");
  }

  // The segments of the bar of the chart, in thousandths of its width:
  // site_search_chart_segments of the tool, rule for rule.
  function segments(counts, leastShare) {
    const result = counts.map(() => ({ start: 0, width: 0 }));
    let total = 0, shown = 0, last = -1;
    counts.forEach((count, index) => { if (count > 0) { total += count; shown++; last = index; } });
    if (total === 0) return result;
    let least = leastShare;
    if (shown * least > 1000) least = Math.floor(1000 / shown);
    const rest = 1000 - shown * least;
    let sum = 0;
    counts.forEach((count, index) => {
      if (count > 0) { result[index].width = least + Math.floor(rest * count / total); sum += result[index].width; }
    });
    result[last].width += 1000 - sum;
    let start = 0;
    for (const segment of result) { segment.start = start; start += segment.width; }
    return result;
  }

  // A share in thousandths as the tool writes it: "74.6%".
  function percent(perMille) { return Math.floor(perMille / 10) + "." + (perMille % 10) + "%"; }

  // The text of version.json as an object, or null for a fetch that failed
  // (an empty text) or a text that is not JSON.
  function servedBuild(text) {
    if (text === "") return null;
    try { return JSON.parse(text); } catch (error) { return null; }
  }
  // A page is of an older build only when the page and version.json both
  // name a commit, and the two differ. A page with no commit, a fetch that
  // fails or a file with no commit is never older.
  function olderBuild(pageCommit, served) {
    return typeof pageCommit === "string" && pageCommit !== "" && served !== null && typeof served === "object" &&
      typeof served.commit === "string" && served.commit !== "" && served.commit !== pageCommit;
  }

  function selfTest() {
    const groups = {};
    for (const [group, name, tie] of CASES.names) {
      (groups[group] = groups[group] || []).push({ bytes: encoder.encode(name), tie: tie, name: name });
    }
    const cases = new Map();
    for (const [group, query, name, score] of CASES.orders) {
      const key = group + "\u0000" + query;
      if (!cases.has(key)) cases.set(key, { group: group, query: query, expected: [] });
      cases.get(key).expected.push({ name: name, score: score });
    }
    let passed = 0, first = "";
    for (const item of cases.values()) {
      const result = rank(encoder.encode(item.query), groups[item.group], RULE.rankedCapacity);
      const got = result.ranked.map(r => groups[item.group][r.index].name + " " + r.score).join(", ");
      const want = item.expected.map(e => e.name + " " + e.score).join(", ");
      if (got === want && result.matched === item.expected.length) passed++;
      else if (!first) first = item.group + " \"" + item.query + "\": " + got + "; expected " + want;
    }
    // The counts by kind, the restriction to one kind, and the field with
    // no text, which gives the counts of the whole group.
    for (const [group, query, only, counts, listed, firstName] of CASES.kinds) {
      const gotCounts = countsText(countsFor(query, groups[group]));
      const result = rank(encoder.encode(query), groups[group], RULE.rankedCapacity, only);
      const gotFirst = result.ranked.length > 0 ? groups[group][result.ranked[0].index].name : "";
      if (gotCounts === counts && result.matched === listed && gotFirst === firstName) passed++;
      else if (!first) first = group + " \"" + query + "\" in " + only + ": " + gotCounts + ", " + result.matched + " listed, first \"" + gotFirst + "\"; expected " + counts + ", " + listed + " listed, first \"" + firstName + "\"";
    }
    // The segments of the bar of the chart.
    for (const [countsLine, expected] of CASES.segments) {
      const counts = countsLine === "" ? [] : countsLine.split(" ").map(Number);
      const got = segments(counts, RULE.leastShare).map(segment => segment.start + ":" + segment.width).join(" ");
      if (got === expected) passed++;
      else if (!first) first = "the segments of \"" + countsLine + "\": " + got + "; expected " + expected;
    }
    // The rule of the line of an older build.
    for (const [pageCommit, servedText, older] of CASES.builds) {
      const got = olderBuild(pageCommit, servedBuild(servedText));
      if (got === older) passed++;
      else if (!first) first = "the build of a page \"" + pageCommit + "\" and version.json \"" + servedText + "\": " + got + "; expected " + older;
    }
    const count = cases.size + CASES.kinds.length + CASES.segments.length + CASES.builds.length;
    return first === "" ? "search self test: " + passed + " of " + count + " cases pass" :
      "search self test: FAIL, " + passed + " of " + count + " cases pass; the first that fails: " + first;
  }
  // The line of the self test is printed when the script runs, during the
  // load of the page, and again when the list opens: a capture of the
  // console that starts after the load still reads it. It is also the
  // attribute data-search-self-test of the root element, and the first
  // line under the box.
  const selfTestLine = new URLSearchParams(location.search).get("selftest") === "1" ? selfTest() : "";
  if (selfTestLine) {
    console.log(selfTestLine);
    document.documentElement.setAttribute("data-search-self-test", selfTestLine);
  }

  // A page of an older build (docs/SITE.md, "A page of an older build"): a
  // browser or the edge of the host can keep a page for minutes. Once in
  // each view of a page, the script asks for version.json, past every cache
  // (no-store, and an address that no cache holds), and compares its commit
  // with the commit of the page. When they differ, one quiet line under the
  // bar offers a reload; the page never reloads by itself.
  const pageBuild = document.querySelector("meta[name='build-commit']");
  if (pageBuild && script && typeof fetch === "function") {
    const versionAddress = new URL("` + SITE_VERSION_FILE + `", new URL(".", script.src));
    versionAddress.searchParams.set("at", String(Date.now()));
    fetch(versionAddress, { cache: "no-store" })
      .then(answer => answer.ok ? answer.text() : "")
      .catch(() => "")
      .then(text => {
        if (!olderBuild(pageBuild.content, servedBuild(text))) return;
        const notice = document.createElement("p");
        notice.className = "build-notice";
        notice.setAttribute("role", "status");
        const reload = document.createElement("button");
        reload.type = "button";
        reload.textContent = "reload";
        reload.addEventListener("click", () => location.reload());
        notice.append("This page is from an older build: ", reload);
        const bar = document.querySelector("header.bar");
        if (bar) bar.after(notice); else document.body.prepend(notice);
      });
  }

  // The site menu: open on a wide screen, where it is the bar of the
  // sections; on a narrow screen its button opens it, and Escape or a click
  // outside closes it. With no script the button still opens and closes it.
  const menu = document.querySelector("details.bar-menu");
  const wide = window.matchMedia("(min-width: 720px)");
  function fitMenu() { if (menu) menu.open = wide.matches; }
  function showMenu() { if (menu && !menu.open) menu.open = true; }
  if (menu) {
    fitMenu();
    wide.addEventListener("change", fitMenu);
    document.addEventListener("click", event => {
      if (!wide.matches && menu.open && !menu.contains(event.target)) menu.open = false;
    });
    menu.addEventListener("keydown", event => {
      if (event.key !== "Escape" || event.defaultPrevented || wide.matches || !menu.open) return;
      menu.open = false;
      menu.querySelector("summary").focus();
    });
  }

  // "On this page" of a documentation page: open beside the text on a wide
  // screen, closed above the text on a narrower one. The link of the part
  // of the page in view is marked as the page scrolls: an observer of the
  // targets of the links reports when one enters or leaves the top of the
  // window; nothing runs each frame. With no script it is a list of links.
  const outline = document.querySelector("details.outline");
  if (outline) {
    const besideText = window.matchMedia("(min-width: 1100px)");
    function fitOutline() { outline.open = besideText.matches; }
    fitOutline();
    besideText.addEventListener("change", fitOutline);
    const links = Array.from(outline.querySelectorAll("a[href^='#']"));
    const targets = links.map(link => document.getElementById(decodeURIComponent(link.hash.slice(1))));
    const inView = new Set();
    function markCurrent() {
      const current = targets.findIndex(target => target && inView.has(target));
      if (current < 0) return;
      links.forEach((link, number) => {
        if (number === current) link.setAttribute("aria-current", "location");
        else link.removeAttribute("aria-current");
      });
    }
    if ("IntersectionObserver" in window) {
      const observer = new IntersectionObserver(changes => {
        for (const change of changes) {
          if (change.isIntersecting) inView.add(change.target); else inView.delete(change.target);
        }
        markCurrent();
      }, { rootMargin: "0px 0px -60% 0px" });
      // The first link names the whole text: it stays marked until a
      // heading or a symbol enters the top of the window.
      for (const target of targets) if (target && target.tagName !== "MAIN") observer.observe(target);
    }
  }

  // The cards of the types and of the declarations. A reference to a type
  // is a button that opens the card of its type with a click, a tap or
  // Enter, with no script. A reference to a declaration is a link, and its
  // card opens with the script only. The script adds a pointer that rests on
  // the reference, and the focus of the keyboard: both open the card, which
  // closes when the pointer leaves the reference and the card, or when the
  // focus leaves them.
  if (HTMLElement.prototype.hasOwnProperty("popover")) {
    let openTimer = 0, closeTimer = 0;
    const isOpen = card => card.matches(":popover-open");
    function openCard(card, opener) {
      clearTimeout(closeTimer);
      if (!isOpen(card)) card.showPopover({ source: opener });
    }
    function closeCard(card) {
      clearTimeout(openTimer);
      clearTimeout(closeTimer);
      closeTimer = setTimeout(() => {
        if (isOpen(card) && !card.matches(":hover") && !card.contains(document.activeElement)) card.hidePopover();
      }, 300);
    }
    const openers = [];
    document.querySelectorAll("button.type-reference[popovertarget]").forEach(button => openers.push([button, button.getAttribute("popovertarget")]));
    document.querySelectorAll("a.declaration-reference[data-declaration-card]").forEach(link => openers.push([link, link.dataset.declarationCard]));
    for (const [opener, id] of openers) {
      const card = document.getElementById(id);
      if (!card) continue;
      opener.addEventListener("pointerenter", event => {
        if (event.pointerType !== "mouse") return;
        clearTimeout(openTimer);
        clearTimeout(closeTimer);
        openTimer = setTimeout(() => openCard(card, opener), 400);
      });
      opener.addEventListener("pointerleave", event => { if (event.pointerType === "mouse") closeCard(card); });
      opener.addEventListener("focus", () => { if (opener.matches(":focus-visible")) openCard(card, opener); });
      // A tap moves the focus to no element: the card stays, and a tap
      // outside it closes it. A key moves the focus to another element.
      opener.addEventListener("blur", event => { if (event.relatedTarget && !card.contains(event.relatedTarget)) closeCard(card); });
      card.addEventListener("pointerenter", () => clearTimeout(closeTimer));
      card.addEventListener("pointerleave", event => { if (event.pointerType === "mouse") closeCard(card); });
    }
  }

  // The search field of the page: in the menu of the bar, or in the page
  // itself on the home of the docs. A page has one; the menu opens for it
  // only when it holds it.
  const box = document.getElementById("` + SITE_SEARCH_FIELD_ID + `");
  if (!box || !script) return;
  const search = box.parentElement;
  const inMenu = menu !== null && menu.contains(box);
  function showField() { if (inMenu) showMenu(); }
  const panel = document.getElementById("site-search-panel");
  const list = document.getElementById("site-search-list");
  const hint = document.getElementById("site-search-hint");
  const detail = document.getElementById("site-search-detail");
  const root = new URL(".", script.src);
  let index = null, loading = null, shown = [], active = -1;
  search.hidden = false;

  function load() {
    if (!loading) {
      // The address of the index, with the version of its bytes, is an
      // attribute of the script element, relative to the folder of the script.
      loading = fetch(new URL(script.dataset.index || "search.json", root)).then(answer => {
        if (!answer.ok) throw new Error("status " + answer.status);
        return answer.json();
      }).then(data => {
        index = data.entries.map(e => ({ title: e[0], page: data.pages[e[1]], anchor: e[2], kind: data.kinds[e[3]][0], value: data.kinds[e[3]][1], text: e[4], bytes: encoder.encode(e[0]), tie: e[3] }));
      }).catch(() => {
        index = [];
        hint.textContent = "The index of the search cannot be read: a page opened from a file cannot read another file. Every page is reachable by its links.";
        open();
      });
    }
    return loading;
  }

  function address(item) {
    return new URL(item.page[0] + (item.anchor ? "#" + item.anchor : ""), root).href;
  }

  // The name with its matched characters marked: a character is marked
  // when one of its bytes is a place of the match.
  function marked(element, bytes, places) {
    const set = new Set(places);
    let start = 0;
    while (start < bytes.length) {
      let end = start + 1;
      while (end < bytes.length && (bytes[end] & 0xC0) === 0x80) end++;
      let lit = false;
      for (let i = start; i < end; i++) if (set.has(i)) lit = true;
      const text = decoder.decode(bytes.subarray(start, end));
      const last = element.lastChild;
      if (last && (last.nodeName === "MARK") === lit) last.textContent += text;
      else if (lit) { const mark = document.createElement("mark"); mark.textContent = text; element.append(mark); }
      else element.append(document.createTextNode(text));
      start = end;
    }
  }

  function open() {
    if (selfTestLine && panel.hidden) {
      console.log(selfTestLine);
      hint.textContent = selfTestLine + ". " + hint.textContent;
    }
    panel.hidden = false;
    box.setAttribute("aria-expanded", "true");
  }
  function close() {
    panel.hidden = true;
    box.setAttribute("aria-expanded", "false");
    box.removeAttribute("aria-activedescendant");
  }

  function choose(number) {
    active = number;
    const rows = list.children;
    for (let i = 0; i < rows.length; i++) rows[i].setAttribute("aria-selected", i === active ? "true" : "false");
    if (active >= 0) {
      box.setAttribute("aria-activedescendant", rows[active].id);
      detail.textContent = index[shown[active].index].text;
    } else {
      box.removeAttribute("aria-activedescendant");
      detail.textContent = "";
    }
  }

  // The chart of the docs home (docs/SITE.md, "The chart of what the search
  // finds"): one bar of segments under the field, and a row of chips. With
  // no script it shows the counts of the whole index, and a chip whose kind
  // has a page is a link to it. While the field holds a text, each chip
  // shows the count of the matches of its kind and each segment its share
  // of them, in the same place; a press on a chip or on a segment keeps the
  // list to its kind. With no text a chip is a link again.
  const chart = document.getElementById("search-chart");
  const chartBar = document.getElementById("search-chart-bar");
  const chartRows = chart ? Array.from(chart.querySelectorAll("li[data-kind]")).map(row => ({
    row: row,
    kind: Number(row.dataset.kind),
    plural: row.dataset.plural,
    target: row.querySelector(".search-chart-target"),
    count: row.querySelector(".search-chart-count"),
    segment: chartBar ? chartBar.querySelector("rect[data-kind='" + row.dataset.kind + "']") : null,
  })) : [];
  const chartMatched = document.getElementById("search-chart-matched");
  const chartMatchedCount = document.getElementById("search-chart-matched-count");
  const chartWords = document.getElementById("search-chart-words");
  // The kind that the list keeps, or -1 for every kind.
  let only = -1;
  let chartButtons = false;

  function kindPlural(kind) {
    const item = chartRows.find(row => row.kind === kind);
    return item ? item.plural : "";
  }

  // The chips are buttons while the field holds a text, links (or plain
  // chips, for a kind with no page) when it is empty.
  function chartAsButtons(on) {
    if (on !== chartButtons) {
      chartButtons = on;
      for (const item of chartRows) {
        if (on) {
          item.target.setAttribute("role", "button");
          item.target.setAttribute("tabindex", "0");
        } else {
          item.target.removeAttribute("role");
          item.target.removeAttribute("tabindex");
          item.target.removeAttribute("aria-pressed");
        }
      }
    }
    if (on) for (const item of chartRows) item.target.setAttribute("aria-pressed", item.kind === only ? "true" : "false");
  }

  // The places of the segments, as the tool computes them: the order of
  // the chips and of the segments does not change while the reader types.
  function drawChart(counts, querying) {
    if (!chart) return;
    let total = 0;
    for (const value of counts.values()) total += value;
    const shares = segments(chartRows.map(item => counts.get(item.kind) || 0), RULE.leastShare);
    chartRows.forEach((item, number) => {
      const value = counts.get(item.kind) || 0;
      item.count.textContent = String(value);
      item.row.classList.toggle("search-chart-none", value === 0);
      if (item.segment) {
        item.segment.setAttribute("x", percent(shares[number].start));
        item.segment.setAttribute("width", percent(shares[number].width));
      }
    });
    chartMatched.hidden = !querying;
    chartMatchedCount.textContent = String(total);
    chartWords.textContent = querying ? "match" : "entries";
    chartAsButtons(querying);
  }

  // One kind at a time: a second press on the same kind gives every kind
  // back. The focus returns to the field, whose list shows the result and
  // takes the keys.
  function keepKind(kind) {
    only = only === kind ? -1 : kind;
    chartAsButtons(chartButtons);
    box.focus();
    load().then(render);
  }

  if (chart) {
    // With no text in the field, a chip does what its markup does: a link
    // opens its page.
    const pressed = event => {
      const target = event.target.closest(".search-chart-target");
      if (!chartButtons || !target) return;
      event.preventDefault();
      keepKind(Number(target.parentElement.dataset.kind));
    };
    chart.addEventListener("click", pressed);
    chart.addEventListener("keydown", event => { if (event.key === "Enter" || event.key === " ") pressed(event); });
  }
  if (chartBar) {
    // A segment is a target for the pointer only: the chips are the same
    // targets for the keyboard and for a screen reader.
    chartBar.addEventListener("click", event => {
      const segment = event.target.closest("rect[data-kind]");
      if (!segment) return;
      const kind = Number(segment.dataset.kind);
      if (chartButtons) { keepKind(kind); return; }
      const item = chartRows.find(row => row.kind === kind);
      if (item && item.target.href) location.href = item.target.href;
    });
  }

  function render() {
    const query = box.value;
    list.textContent = "";
    shown = [];
    if (query === "") only = -1;
    // An index that cannot be read leaves the chart as the tool wrote it.
    if (index && index.length > 0 && query === "") drawChart(countsFor("", index), false);
    if (!index || query === "") { close(); return; }
    if (index.length === 0) { open(); return; }
    const result = rank(encoder.encode(query), index, RULE.rows, only);
    drawChart(result.byTie, true);
    shown = result.ranked;
    const rest = result.matched - shown.length;
    const kept = only >= 0 ? "Only " + kindPlural(only) + ". " : "";
    hint.textContent = kept + (result.matched === 0 ? "No entry matches. Escape: close" :
      result.matched + (result.matched === 1 ? " entry matches" : " entries match") + (rest > 0 ? ", " + rest + " more not shown" : "") + ". Up, Down: choose. Enter: open. Escape: close");
    shown.forEach((ranked, number) => {
      const item = index[ranked.index];
      const row = document.createElement("li");
      row.id = "site-search-row-" + number;
      row.setAttribute("role", "option");
      const link = document.createElement("a");
      link.href = address(item);
      link.tabIndex = -1;
      const name = document.createElement("span");
      name.className = "search-name";
      marked(name, ranked.bytes, ranked.places);
      // The kind with the icon and the color of its value kind, as the
      // chart of the docs home shows it; the words stay dim.
      const what = document.createElement("span");
      what.className = "search-what";
      const kind = document.createElement("span");
      kind.className = "search-kind value-icon value-" + item.value;
      kind.textContent = item.kind;
      what.append(kind, ", " + item.page[1]);
      link.append(name, what);
      row.append(link);
      list.append(row);
    });
    open();
    choose(shown.length > 0 ? 0 : -1);
  }

  function update() {
    const url = new URL(location.href);
    if (box.value) url.searchParams.set("q", box.value); else url.searchParams.delete("q");
    history.replaceState(history.state, "", url);
    load().then(render);
  }

  box.addEventListener("input", update);
  box.addEventListener("focus", () => { load(); if (box.value) load().then(render); });
  box.addEventListener("keydown", event => {
    if (event.key === "ArrowDown" && shown.length > 0) { choose((active + 1) % shown.length); event.preventDefault(); }
    else if (event.key === "ArrowUp" && shown.length > 0) { choose((active + shown.length - 1) % shown.length); event.preventDefault(); }
    else if (event.key === "Enter" && active >= 0) { location.href = address(index[shown[active].index]); event.preventDefault(); }
    else if (event.key === "Escape") { if (panel.hidden) box.blur(); else close(); event.preventDefault(); }
  });
  search.addEventListener("focusout", event => { if (!search.contains(event.relatedTarget)) close(); });
  document.addEventListener("keydown", event => {
    const target = event.target;
    const typing = target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement || (target && target.isContentEditable);
    if (event.key === "/" && !typing && !event.ctrlKey && !event.metaKey && !event.altKey) { showField(); box.focus(); event.preventDefault(); }
  });
  const asked = new URLSearchParams(location.search).get("q");
  if (asked) { showField(); box.value = asked; box.focus(); load().then(render); }
})();
`
