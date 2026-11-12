// The references from a page to a document of docs/ (docs/SITE.md, "The
// references to documents"). A comment of the source names a document for
// a person who reads the code: "(docs/ARCHITECTURE.md, "Kernel systems")".
// On a page, that pointer is a link with the title of the document and the
// text of the heading that it names, in a style of its own: a path and a
// label such as "U3" or "section 8" mean nothing to a reader of the site.
// One procedure writes the text of each source comment that a page shows;
// the renderer of the guides writes a code span that names a document with
// the same markup, so a reference to a document has one look on every page.
package kerneltool

import "core:fmt"
import "core:slice"
import "core:strings"

SITE_GLOSSARY_FILE :: "docs/GLOSSARY.md"

// The words that start a label of a place in a document: "section 8",
// "sections 4 and 5", "property <n>". The last three name a numbered item
// of a list, not a heading (site_item_find).
SITE_POINTER_LABEL_WORDS :: [?]string{"sections ", "section ", "property ", "decision ", "choice ", "item "}

// The start of the markup of a reference to a document: the check of a
// test and the style sheet know it by its class.
SITE_DOCUMENT_REFERENCE_OPEN :: "<a class=\"document-reference value-guide value-icon\" href=\""

// A pointer of a text to a document of docs/.
Site_Document_Pointer :: struct {
	start:    int, // The first byte of what the pointer takes from the text.
	end:      int, // The byte after it.
	path:     string, // "docs/ARCHITECTURE.md".
	labels:   []string, // Each part after the path that names a place, in its order: "\"Kernel systems\"", "section 8", "U3".
	// An aside (a parenthesis, or "see ..."): its text leaves the sentence
	// and its reference goes after the text. Else the path is a word of the
	// sentence ("the rules of docs/DESIGN.md"), and its reference takes its
	// place.
	detached: bool,
}

// A heading of a document, as the site knows it.
Site_Document_Heading :: struct {
	level: int,
	text:  string, // As the document writes it, with its label: "K1. Handle table".
	id:    string, // Its id on the page of the document; "" for a file that is not a page.
	line:  int, // Its line in the file; 0 when the site knows the page only.
}

// A top-level item of an ordered list of a document: "12. **The words in
// bold** ...". A choice or an item that a pointer names by its number.
Site_Document_Item :: struct {
	label:   string, // "12", "34b".
	title:   string, // The words that a reference shows: its title in bold, else its first sentence (site_item_words).
	heading: int, // The index of the heading above it, or -1.
	id:      string, // Its id on the page of the document; "" for a file that is not a page.
	line:    int, // Its line in the file.
}

// The title and the headings of a document.
Site_Document_Outline :: struct {
	title:    string,
	headings: []Site_Document_Heading,
	items:    []Site_Document_Item,
	bold_titles: []Site_Document_Item, // Each line that starts with words in bold: a place that a quoted label can name when no heading has its words.
	page:     string, // The page of the site, or "" for a working record.
	found:    bool, // The document exists.
}

// The place that a pointer names, and the text of its reference.
Site_Document_Target :: struct {
	path:     string, // "docs/ARCHITECTURE.md".
	title:    string, // The title of the document.
	heading:  string, // The text of the heading with no label, or "" for the document alone.
	link:     string, // A page of the site with its anchor, or the address of the file in the repository.
	outside:  bool, // A working record: it is not a page of the site; the link names the file in the repository.
	resolved: bool, // Each label of the pointer found its heading.
}

// The form of the text of a source comment on a page.
Site_Comment_Form :: enum {
	Paragraphs, // One paragraph for each line of the text, then one paragraph "See:" with the references.
	Line, // One line, in a cell of a table: the text, then "See:" and the references.
}

// site_document_path_end tells whether a path "docs/<NAME>.md" starts at an
// index of a text, and gives the byte after it. A part of a longer path
// ("tools/docs/X.md") or of a word is not a pointer.
site_document_path_end :: proc(text: string, start: int) -> (end: int, found: bool) {
	if start < 0 || start >= len(text) || !strings.has_prefix(text[start:], "docs/") {
		return 0, false
	}
	if start > 0 {
		before := text[start - 1]
		if site_is_word_byte(before) || before == '/' || before == '.' || before == '-' {
			return 0, false
		}
	}
	end = start + len("docs/")
	name_start := end
	for end < len(text) && ((text[end] >= 'A' && text[end] <= 'Z') || (text[end] >= '0' && text[end] <= '9') || text[end] == '_') {
		end += 1
	}
	if end == name_start || !strings.has_prefix(text[end:], ".md") {
		return 0, false
	}
	end += len(".md")
	if end < len(text) && (site_is_word_byte(text[end]) || text[end] == '/') {
		return 0, false
	}
	return end, true
}

// site_enclosing_parenthesis gives the parenthesis around an index of a
// text: its "(" and its ")", or the end of the text when the text stops
// before the ")". The open is -1 when no parenthesis holds the index.
site_enclosing_parenthesis :: proc(text: string, at: int) -> (open: int, close: int) {
	open = -1
	depth := 0
	for index := at - 1; index >= 0 && open < 0; index -= 1 {
		if text[index] == ')' {
			depth += 1
		} else if text[index] == '(' {
			if depth == 0 {
				open = index
			} else {
				depth -= 1
			}
		}
	}
	if open < 0 {
		return -1, -1
	}
	close = len(text)
	depth = 0
	for index in at ..< len(text) {
		if text[index] == '(' {
			depth += 1
		} else if text[index] == ')' {
			if depth == 0 {
				close = index
				break
			}
			depth -= 1
		}
	}
	return open, close
}

// site_parenthesis_part gives the bounds of the part of a parenthesis that
// holds the bytes from at to after. The parts are separated by "; ", outside
// quotes and inner parentheses: "(the call form; docs/MODULE_CONTRACT.md)".
site_parenthesis_part :: proc(text: string, open, close, at, after: int) -> (start: int, end: int) {
	start, end = open + 1, close
	quoted := false
	depth := 0
	for index in open + 1 ..< close {
		character := text[index]
		if character == '"' {
			quoted = !quoted
		} else if !quoted && character == '(' {
			depth += 1
		} else if !quoted && character == ')' {
			depth -= 1
		} else if !quoted && depth == 0 && character == ';' && index + 1 < close && text[index + 1] == ' ' {
			if index < at {
				start = index + 2
			} else if index >= after {
				end = index
				break
			}
		}
	}
	return start, end
}

// site_parts_outside_quotes splits a text at each ", " that is not inside
// quotes: a quoted heading can hold a comma ("Did not fit, across calls").
site_parts_outside_quotes :: proc(text: string) -> []string {
	parts := make([dynamic]string, context.temp_allocator)
	quoted := false
	start := 0
	for index in 0 ..< len(text) {
		if text[index] == '"' {
			quoted = !quoted
		} else if !quoted && text[index] == ',' && index + 1 < len(text) && text[index + 1] == ' ' {
			append(&parts, strings.trim_space(text[start:index]))
			start = index + 2
		}
	}
	append(&parts, strings.trim_space(text[start:]))
	return parts[:]
}

// site_label_token_end reads a label of a section at an index: "8", "12.4",
// "5a", "U2b", "K1". With capital_required, the label starts with a capital
// letter: a bare number after a comma is a word of the sentence.
site_label_token_end :: proc(text: string, at: int, capital_required: bool) -> (end: int, found: bool) {
	decimal_digit :: proc(character: u8) -> bool {
		return character >= '0' && character <= '9'
	}
	index := at
	if index < len(text) && text[index] >= 'A' && text[index] <= 'Z' {
		index += 1
	} else if capital_required {
		return 0, false
	}
	digits_start := index
	for index < len(text) && decimal_digit(text[index]) {
		index += 1
	}
	if index == digits_start {
		return 0, false
	}
	if index < len(text) && text[index] >= 'a' && text[index] <= 'z' {
		index += 1
	}
	for index + 1 < len(text) && text[index] == '.' && decimal_digit(text[index + 1]) {
		index += 1
		for index < len(text) && decimal_digit(text[index]) {
			index += 1
		}
		if index < len(text) && text[index] >= 'a' && text[index] <= 'z' {
			index += 1
		}
	}
	if index < len(text) && site_is_word_byte(text[index]) {
		return 0, false
	}
	return index, true
}

// site_pointer_label_end reads one label of a place at an index: a heading
// in quotes, a word of SITE_POINTER_LABEL_WORDS and its number or its
// quoted heading, or a label that starts with a capital letter ("U3").
site_pointer_label_end :: proc(text: string, at: int) -> (end: int, found: bool) {
	if at >= len(text) {
		return 0, false
	}
	if text[at] == '"' {
		closing := strings.index_byte(text[at + 1:], '"')
		if closing <= 0 {
			return 0, false
		}
		return at + 1 + closing + 1, true
	}
	words := SITE_POINTER_LABEL_WORDS
	for word in words {
		if !strings.has_prefix(text[at:], word) {
			continue
		}
		after := at + len(word)
		if after < len(text) && text[after] == '"' {
			return site_pointer_label_end(text, after)
		}
		end, found = site_label_token_end(text, after, false)
		if found && word == "sections " && strings.has_prefix(text[end:], " and ") {
			if second, has_second := site_label_token_end(text, end + len(" and "), false); has_second {
				end = second
			}
		}
		return end, found
	}
	return site_label_token_end(text, at, true)
}

// site_pointer_labels reads the labels after a path in running text, each
// after ", ": `docs/FONTS.md, section 12.4` or `ARCHITECTURE.md`, "The fault
// ring". It stops at the first part that is not a label, and gives the
// byte after the last label.
site_pointer_labels :: proc(text: string, at: int) -> (labels: []string, end: int) {
	list := make([dynamic]string, context.temp_allocator)
	end = at
	for end < len(text) {
		separator := 0
		if strings.has_prefix(text[end:], ", ") {
			separator = 2
		} else if strings.has_prefix(text[end:], " section ") || strings.has_prefix(text[end:], " sections ") {
			separator = 1
		} else {
			break
		}
		label_end, found := site_pointer_label_end(text, end + separator)
		if !found {
			break
		}
		append(&list, text[end + separator:label_end])
		end = label_end
	}
	return list[:], end
}

// site_document_pointer_at reads the pointer whose path is at path_start:
// its labels, the bytes that it takes from the text, and whether it is an
// aside.
site_document_pointer_at :: proc(text: string, path_start, path_end: int) -> Site_Document_Pointer {
	pointer := Site_Document_Pointer{start = path_start, end = path_end, path = text[path_start:path_end]}
	if open, close := site_enclosing_parenthesis(text, path_start); open >= 0 {
		part_start, part_end := site_parenthesis_part(text, open, close, path_start, path_end)
		before := text[part_start:path_start]
		after := text[path_end:part_end]
		labels_text := ""
		labelled := true
		if strings.has_prefix(after, ", ") {
			labels_text = after[2:]
		} else if strings.has_prefix(after, " section") {
			labels_text = after[1:]
		} else if strings.trim_space(after) != "" {
			labelled = false // Words after the path: the path is a word of the parenthesis.
		}
		// The bytes of the part that stay before the pointer, or -1 when
		// the path is a word of the parenthesis.
		kept := -1
		if before == "" || before == "see " || before == "See " {
			kept = 0
		} else if strings.has_suffix(before, ", see ") || strings.has_suffix(before, ", See ") {
			kept = len(before) - len(", see ")
		} else if strings.has_suffix(before, ", ") {
			kept = len(before) - len(", ")
		}
		if labelled && kept >= 0 {
			aside_labels := make([dynamic]string, context.temp_allocator)
			if labels_text != "" {
				for part in site_parts_outside_quotes(labels_text) {
					if part != "" {
						append(&aside_labels, part)
					}
				}
			}
			pointer.labels = aside_labels[:]
			pointer.detached = true
			pointer.start = part_start + kept
			pointer.end = part_end
			if kept == 0 {
				if part_start == open + 1 && part_end == close {
					// The whole parenthesis, and the space before it.
					pointer.start = open
					if open > 0 && text[open - 1] == ' ' {
						pointer.start = open - 1
					}
					pointer.end = min(close + 1, len(text))
				} else if part_start > open + 1 {
					pointer.start = part_start - len("; ")
				} else {
					pointer.end = part_end + len("; ")
				}
			}
			return pointer
		}
	}
	if path_start >= 4 {
		see := text[path_start - 4:path_start]
		if see == "see " || see == "See " {
			see_labels, see_end := site_pointer_labels(text, path_end)
			pointer.labels = see_labels
			pointer.detached = true
			pointer.start = path_start - 4
			pointer.end = see_end
			if pointer.start >= 2 && (text[pointer.start - 2:pointer.start] == ", " || text[pointer.start - 2:pointer.start] == "; ") {
				pointer.start -= 2
			} else if see == "See " && see_end < len(text) && text[see_end] == '.' {
				pointer.end = see_end + 1 // "See docs/X.md." is a whole sentence.
			}
			return pointer
		}
	}
	// A path in code marks ("`docs/X.md`") takes its marks with it.
	labels_start := path_end
	if path_start > 0 && text[path_start - 1] == '`' && path_end < len(text) && text[path_end] == '`' {
		pointer.start = path_start - 1
		labels_start = path_end + 1
	}
	word_labels, word_end := site_pointer_labels(text, labels_start)
	pointer.labels = word_labels
	pointer.end = word_end
	return pointer
}

// site_document_pointers gives each pointer of a text to a document of
// docs/, in the order of the text. A text with no pointer gives none.
site_document_pointers :: proc(text: string) -> []Site_Document_Pointer {
	pointers := make([dynamic]Site_Document_Pointer, context.temp_allocator)
	position := 0
	for position < len(text) {
		found := strings.index(text[position:], "docs/")
		if found < 0 {
			break
		}
		path_start := position + found
		path_end, is_path := site_document_path_end(text, path_start)
		if !is_path {
			position = path_start + len("docs/")
			continue
		}
		pointer := site_document_pointer_at(text, path_start, path_end)
		append(&pointers, pointer)
		position = max(path_end, pointer.end)
	}
	return pointers[:]
}

// site_is_working_record tells whether a document of docs/ is a working
// record, which the site does not publish.
site_is_working_record :: proc(path: string) -> bool {
	records := SITE_WORKING_RECORDS
	name := site_file_name(path)
	for record in records {
		if name == record {
			return true
		}
	}
	return false
}

// site_item_title gives the words in bold at the start of the text of an
// item, with no period at their end, or "".
site_item_title :: proc(text: string) -> string {
	if !strings.has_prefix(text, "**") {
		return ""
	}
	end := strings.index(text[2:], "**")
	if end <= 0 {
		return ""
	}
	return strings.trim_right(strings.trim_space(text[2:2 + end]), ".:")
}

// SITE_ITEM_WORDS_LIMIT is the most bytes of the words of an item that a
// reference shows: a reference is a name, not a paragraph.
SITE_ITEM_WORDS_LIMIT :: 80

// site_item_words gives the words of an item that a reference shows: its
// title in bold, else its first sentence, cut at a space.
site_item_words :: proc(text: string) -> string {
	if title := site_item_title(text); title != "" {
		return title
	}
	words := site_heading_plain(site_first_sentence(text))
	words = strings.trim_right(words, ".")
	if len(words) > SITE_ITEM_WORDS_LIMIT {
		if cut := strings.last_index_byte(words[:SITE_ITEM_WORDS_LIMIT], ' '); cut > 0 {
			words = strings.concatenate({words[:cut], " ..."}, context.temp_allocator)
		}
	}
	return words
}

// site_markdown_outline reads a Markdown file, outside the fences of code:
// its title, its headings, its top-level ordered items, and its bold
// titles (a line, a list item or an ordered item that starts with words in
// bold), each with its line and the index of the heading above it. The
// headings are those of the renderer, in its order.
site_markdown_outline :: proc(content: string) -> Site_Document_Outline {
	outline: Site_Document_Outline
	heading_list := make([dynamic]Site_Document_Heading, context.temp_allocator)
	item_list := make([dynamic]Site_Document_Item, context.temp_allocator)
	bold_list := make([dynamic]Site_Document_Item, context.temp_allocator)
	fenced := false
	for line, index in site_lines(content) {
		if strings.has_prefix(strings.trim_space(line), "```") {
			fenced = !fenced
			continue
		}
		if fenced {
			continue
		}
		if level, heading_text := site_heading_level(line); level > 0 {
			if level == 1 && outline.title == "" {
				outline.title = heading_text
			}
			append(&heading_list, Site_Document_Heading{level = level, text = heading_text, line = index + 1})
			continue
		}
		start := strings.trim_space(line)
		if marker, is_marker := site_list_marker(line); is_marker {
			start = marker.text
			if marker.ordered && marker.indent == 0 {
				append(&item_list, Site_Document_Item{label = marker.label, title = site_item_words(marker.text), heading = len(heading_list) - 1, line = index + 1})
			}
		}
		if bold := site_item_title(start); bold != "" {
			append(&bold_list, Site_Document_Item{title = bold, heading = len(heading_list) - 1, line = index + 1})
		}
	}
	outline.headings = heading_list[:]
	outline.items = item_list[:]
	outline.bold_titles = bold_list[:]
	return outline
}

// site_document_file_outline gives the outline of a document of docs/ from
// its file, read once: a page of the site that the command renders adds
// its ids to it.
site_document_file_outline :: proc(site: ^Site, path: string) -> Site_Document_Outline {
	if site.document_outlines == nil {
		site.document_outlines = make(map[string]Site_Document_Outline, context.temp_allocator)
	}
	if known, is_known := site.document_outlines[path]; is_known {
		return known
	}
	read: Site_Document_Outline
	if content, read_ok := site_read_quiet(path); read_ok {
		read = site_markdown_outline(content)
		read.found = true
		if read.title == "" {
			read.title = site_file_name(path)
		}
	}
	site.document_outlines[path] = read
	return read
}

// site_document_outline gives the title, the headings and the items of a
// document. A guide has the ids of its rendered page; a heading of a guide
// that is not rendered yet has no id, and a label of it does not resolve.
// The glossary is rendered after the guides: the id of one of its headings
// is its slug, as the renderer gives it, when no other heading has that
// slug. A working record is a file of the repository: its places are
// lines.
site_document_outline :: proc(site: ^Site, path: string) -> Site_Document_Outline {
	if site == nil {
		return {}
	}
	page, is_page := site.documents[path]
	if !is_page && !site_is_working_record(path) {
		return {}
	}
	file := site_document_file_outline(site, path)
	if !file.found || !is_page {
		return file
	}
	outline := Site_Document_Outline{title = file.title, page = page, found = true}
	if path == SITE_GLOSSARY_FILE {
		slugs := make(map[string]int, context.temp_allocator)
		for heading in file.headings {
			slugs[site_slug(heading.text)] += 1
		}
		headings := make([]Site_Document_Heading, len(file.headings), context.temp_allocator)
		for heading, index in file.headings {
			headings[index] = heading
			if slugs[site_slug(heading.text)] == 1 {
				headings[index].id = site_slug(heading.text)
			}
		}
		outline.headings = headings
		return outline
	}
	for guide in site.guides {
		if guide.source != path {
			continue
		}
		headings := make([]Site_Document_Heading, len(guide.headings), context.temp_allocator)
		for heading, index in guide.headings {
			headings[index] = Site_Document_Heading{level = heading.level, text = heading.text, id = heading.id}
		}
		items := make([]Site_Document_Item, len(guide.items), context.temp_allocator)
		for item, index in guide.items {
			items[index] = Site_Document_Item{label = item.label, title = site_item_words(item.text), heading = item.heading, id = item.id, line = item.line}
		}
		outline.title = guide.title
		outline.headings = headings
		outline.items = items
		// The bold titles of the file point at the headings of the page
		// only when the file and the page have the same headings.
		if len(file.headings) == len(headings) {
			outline.bold_titles = file.bold_titles
		}
		return outline
	}
	return outline
}

// site_label_key gives what a label names: the number of a section ("section
// 8" gives "8"; "property <n>" gives "<n>"), the text of a heading in quotes,
// or the label itself ("U3").
site_label_key :: proc(label: string) -> (key: string, quoted: bool) {
	key = strings.trim_prefix(label, "section ")
	key = strings.trim_prefix(key, "property ")
	if len(key) >= 2 && key[0] == '"' && key[len(key) - 1] == '"' {
		return key[1:len(key) - 1], true
	}
	return key, false
}

// site_label_alternatives gives the labels of one label that names several
// sections: "sections 4 and 5" gives "section 4" and "section 5".
site_label_alternatives :: proc(label: string) -> []string {
	list := make([dynamic]string, context.temp_allocator)
	if strings.has_prefix(label, "sections ") {
		for part in strings.split(label[len("sections "):], " and ", context.temp_allocator) {
			append(&list, strings.concatenate({"section ", part}, context.temp_allocator))
		}
	} else {
		append(&list, label)
	}
	return list[:]
}

// site_heading_plain gives the text of a heading with no Markdown marks.
site_heading_plain :: proc(text: string) -> string {
	plain, _ := strings.remove_all(text, "`", context.temp_allocator)
	plain, _ = strings.remove_all(plain, "**", context.temp_allocator)
	return strings.trim_space(plain)
}

// site_heading_without_label gives the text of a heading without the label
// of its section: "K1. Handle table" gives "Handle table", "12.4 The glyph
// cache" gives "The glyph cache". A label means nothing on another page.
site_heading_without_label :: proc(text: string) -> string {
	end, found := site_label_token_end(text, 0, false)
	if !found {
		return text
	}
	rest := text[end:]
	if strings.has_prefix(rest, ". ") {
		return rest[2:]
	}
	if strings.has_prefix(rest, " ") {
		return rest[1:]
	}
	return text
}

// site_heading_has_label tells whether a heading starts with the label of
// a section: "12. The interface font" has "12", "12.4 The glyph cache" has
// "12.4" and not "12".
site_heading_has_label :: proc(text, key: string) -> bool {
	if key == "" || !strings.has_prefix(text, key) {
		return false
	}
	rest := text[len(key):]
	return rest == "" || rest[0] == ' ' || (rest[0] == '.' && (len(rest) == 1 || rest[1] == ' '))
}

// site_heading_find gives the first heading between low and high that a
// label names, or -1. A quoted label matches the text of a heading by the
// rule that gives the ids (site_slug), with or without the label of its
// section; else, when one heading only starts with those words, that one.
site_heading_find :: proc(headings: []Site_Document_Heading, low, high: int, label: string) -> int {
	key, quoted := site_label_key(label)
	if !quoted {
		for index in low ..< high {
			if site_heading_has_label(site_heading_plain(headings[index].text), key) {
				return index
			}
		}
		return -1
	}
	wanted := site_slug(key)
	for index in low ..< high {
		plain := site_heading_plain(headings[index].text)
		if site_slug(plain) == wanted || site_slug(site_heading_without_label(plain)) == wanted {
			return index
		}
	}
	start := strings.concatenate({wanted, "-"}, context.temp_allocator)
	found := -1
	for index in low ..< high {
		if strings.has_prefix(site_slug(site_heading_without_label(site_heading_plain(headings[index].text))), start) {
			if found >= 0 {
				return -1
			}
			found = index
		}
	}
	return found
}

// site_heading_part_end gives the end of the part of a heading: the next
// heading of its level or of a higher one.
site_heading_part_end :: proc(headings: []Site_Document_Heading, index, high: int) -> int {
	end := index + 1
	for end < high && headings[end].level > headings[index].level {
		end += 1
	}
	return end
}

// site_document_targets gives the places that a pointer names: one, or one
// for each section of "sections 4 and 5". Each label after the first looks
// inside the part of the heading of the label before it ("Kernel events",
// section 5a). A pointer whose labels do not all find a heading names the
// document alone, and is not resolved. A path that is not a document gives
// none.
site_document_targets :: proc(site: ^Site, path: string, labels: []string) -> []Site_Document_Target {
	targets := make([dynamic]Site_Document_Target, context.temp_allocator)
	outline := site_document_outline(site, path)
	if !outline.found {
		return targets[:]
	}
	whole := Site_Document_Target{path = path, title = outline.title, link = outline.page, outside = outline.page == "", resolved = true}
	if whole.outside {
		whole.link = site_repository_file(site, path)
	}
	if len(labels) == 0 {
		append(&targets, whole)
		return targets[:]
	}
	unresolved := whole
	unresolved.resolved = false
	// A quoted label of the glossary is first a term: its row has the
	// anchor of the term. Else it is a heading of the glossary.
	if path == SITE_GLOSSARY_FILE && len(labels) == 1 {
		key, quoted := site_label_key(labels[0])
		for term in site.terms {
			if quoted && site_slug(term.name) == site_slug(key) {
				term_target := whole
				term_target.heading = term.name
				term_target.link = strings.concatenate({outline.page, "#", term.id}, context.temp_allocator)
				append(&targets, term_target)
				return targets[:]
			}
		}
	}
	low, high := 0, len(outline.headings)
	for label, label_index in labels {
		alternatives := site_label_alternatives(label)
		last := label_index == len(labels) - 1
		if !last && len(alternatives) != 1 {
			append(&targets, unresolved)
			return targets[:]
		}
		chosen := make([dynamic]Site_Document_Target, context.temp_allocator)
		for alternative in alternatives {
			// A numbered item ("choice <n>", "item <n>") is the last label.
			if item_index, is_item := site_item_find(outline, low, high, alternative); is_item {
				if !last || item_index < 0 {
					append(&targets, unresolved)
					return targets[:]
				}
				item := outline.items[item_index]
				if item.title == "" || (!whole.outside && item.id == "") {
					append(&targets, unresolved)
					return targets[:]
				}
				item_target := whole
				item_target.heading = item.title
				if whole.outside {
					item_target.link = site_line_address(site, path, item.line)
				} else {
					item_target.link = strings.concatenate({outline.page, "#", item.id}, context.temp_allocator)
				}
				append(&chosen, item_target)
				continue
			}
			index := site_heading_find(outline.headings, low, high, alternative)
			if index < 0 && last {
				// Words in bold at the start of a line of the part: the
				// reference shows them and links to the heading above them.
				if bold_index := site_bold_title_find(outline, low, high, alternative); bold_index >= 0 {
					bold := outline.bold_titles[bold_index]
					bold_target := whole
					bold_target.heading = bold.title
					if whole.outside {
						bold_target.link = site_line_address(site, path, bold.line)
					} else if bold.heading >= 0 && outline.headings[bold.heading].id != "" {
						bold_target.link = strings.concatenate({outline.page, "#", outline.headings[bold.heading].id}, context.temp_allocator)
					}
					append(&chosen, bold_target)
					continue
				}
			}
			if index < 0 {
				append(&targets, unresolved)
				return targets[:]
			}
			heading := outline.headings[index]
			if !last {
				low, high = index + 1, site_heading_part_end(outline.headings, index, high)
				continue
			}
			if !whole.outside && heading.id == "" {
				append(&targets, unresolved)
				return targets[:]
			}
			target := whole
			target.heading = site_heading_without_label(site_heading_plain(heading.text))
			if whole.outside {
				target.link = site_line_address(site, path, heading.line)
			} else {
				target.link = strings.concatenate({outline.page, "#", heading.id}, context.temp_allocator)
			}
			append(&chosen, target)
		}
		if last {
			append(&targets, ..chosen[:])
		}
	}
	return targets[:]
}

// site_bold_title_find gives the bold title of the part from low to high
// that a quoted label names, or -1: the same words by the rule of the ids,
// or the one title that starts with them ("The zero of Paper Mono: the
// slashed zero").
site_bold_title_find :: proc(outline: Site_Document_Outline, low, high: int, label: string) -> int {
	key, quoted := site_label_key(label)
	if !quoted {
		return -1
	}
	wanted := site_slug(key)
	start := strings.concatenate({wanted, "-"}, context.temp_allocator)
	found := -1
	for bold, index in outline.bold_titles {
		if bold.heading < low - 1 || bold.heading >= high {
			continue
		}
		slug := site_slug(bold.title)
		if slug == wanted {
			return index
		}
		if strings.has_prefix(slug, start) {
			if found >= 0 {
				found = -2 // Two titles start with the words: none is sure.
			} else if found == -1 {
				found = index
			}
		}
	}
	return max(found, -1)
}

// site_item_find tells whether a label names a numbered item ("choice <n>",
// "item <n>"), and gives the index of the one item of that number inside the
// part from low to high, or -1 when none or several have it. "choice" and
// "decision" look first inside the part of the heading that starts with
// "Choices" or "Decisions".
site_item_find :: proc(outline: Site_Document_Outline, low, high: int, label: string) -> (index: int, is_item: bool) {
	// The words of a label that names a numbered item, and the slug of the
	// heading whose part holds the items of that word ("" for any part).
	words := [3][2]string{{"choice ", "choices"}, {"decision ", "decisions"}, {"item ", ""}}
	number := ""
	part_heading := ""
	for word in words {
		if strings.has_prefix(label, word[0]) {
			number = label[len(word[0]):]
			part_heading = word[1]
		}
	}
	if number == "" {
		return -1, false
	}
	part_low, part_high := low, high
	if part_heading != "" {
		for heading_index in low ..< high {
			slug := site_slug(site_heading_without_label(site_heading_plain(outline.headings[heading_index].text)))
			if slug == part_heading || strings.has_prefix(slug, strings.concatenate({part_heading, "-"}, context.temp_allocator)) {
				part_low, part_high = heading_index + 1, site_heading_part_end(outline.headings, heading_index, high)
				break
			}
		}
	}
	index = -1
	for item, item_index in outline.items {
		// An item belongs to the part when the heading above it is the
		// heading of the part or a heading inside it.
		if item.label != number || item.heading < part_low - 1 || item.heading >= part_high {
			continue
		}
		if index >= 0 {
			return -1, true
		}
		index = item_index
	}
	return index, true
}

// site_document_references_count records a pointer that a page shows, by
// its document and its labels: the command prints the count, and each
// pointer whose labels found no heading, a stale pointer of a comment.
site_document_references_count :: proc(site: ^Site, path: string, labels: []string, targets: []Site_Document_Target) {
	if site == nil || site.document_headings_pending || len(targets) == 0 {
		return
	}
	if site.document_references == nil {
		site.document_references = make(map[string]bool, context.temp_allocator)
	}
	key := path
	if len(labels) > 0 {
		key = strings.concatenate({path, ", ", strings.join(labels, ", ", context.temp_allocator)}, context.temp_allocator)
	}
	resolved := true
	for target in targets {
		resolved = resolved && target.resolved
	}
	site.document_references[key] = resolved
}

// site_document_references_summary gives the count of the pointers that the
// pages show, and those whose labels found no heading, in order.
site_document_references_summary :: proc(site: ^Site) -> (count: int, unresolved: []string) {
	list := make([dynamic]string, context.temp_allocator)
	for key, resolved in site.document_references {
		if !resolved {
			append(&list, key)
		}
	}
	slice.sort(list[:])
	return len(site.document_references), list[:]
}

// site_document_target_text gives the text of a reference: the title of
// the document, and the text of the heading after it.
site_document_target_text :: proc(target: Site_Document_Target) -> string {
	if target.heading == "" {
		return target.title
	}
	return strings.concatenate({target.title, ": ", target.heading}, context.temp_allocator)
}

// site_document_reference_write writes one reference: a link in the style
// of the kind Guide, with the title of the document and its heading. A
// working record is a file of the repository, and the reference says so.
site_document_reference_write :: proc(site: ^Site, b: ^strings.Builder, from_page: string, target: Site_Document_Target) {
	strings.write_string(b, SITE_DOCUMENT_REFERENCE_OPEN)
	if target.outside {
		site_escape(b, target.link)
	} else {
		site_escape(b, site_page_link(site, from_page, target.link))
	}
	strings.write_string(b, "\">")
	site_escape(b, site_document_target_text(target))
	if target.outside {
		strings.write_string(b, "<span class=\"document-outside\"> in the repository</span>")
	}
	strings.write_string(b, "</a>")
}

// site_document_references_write writes references, with a separator
// between two of them.
site_document_references_write :: proc(site: ^Site, b: ^strings.Builder, from_page: string, targets: []Site_Document_Target, separator: string) {
	for target, index in targets {
		if index > 0 {
			strings.write_string(b, separator)
		}
		site_document_reference_write(site, b, from_page, target)
	}
}

// site_document_target_listed tells whether a list holds a reference to the
// same place already.
site_document_target_listed :: proc(targets: []Site_Document_Target, target: Site_Document_Target) -> bool {
	for other in targets {
		if other.link == target.link && other.heading == target.heading {
			return true
		}
	}
	return false
}

// site_comment_parts takes the pointers out of a line of a comment. It
// gives the text, where each pointer that is a word of its sentence is a
// mark (a zero byte, its number, a zero byte), the references of those
// marks, and it adds the references of the asides to after. The text on the
// two sides of an aside joins as one sentence: "interrupts (docs/X.md)."
// gives "interrupts.".
site_comment_parts :: proc(site: ^Site, text: string, count: bool, after: ^[dynamic]Site_Document_Target) -> (marked: string, in_place: [][]Site_Document_Target) {
	builder := strings.builder_make(context.temp_allocator)
	places := make([dynamic][]Site_Document_Target, context.temp_allocator)
	cursor := 0
	for pointer in site_document_pointers(text) {
		targets := site_document_targets(site, pointer.path, pointer.labels)
		if len(targets) == 0 {
			continue // Not a document of the repository: its text stays.
		}
		if count {
			site_document_references_count(site, pointer.path, pointer.labels, targets)
		}
		start := max(pointer.start, cursor)
		strings.write_string(&builder, text[cursor:start])
		cursor = max(pointer.end, cursor)
		if !pointer.detached {
			strings.write_byte(&builder, 0)
			fmt.sbprintf(&builder, "%d", len(places))
			strings.write_byte(&builder, 0)
			append(&places, targets)
			continue
		}
		for target in targets {
			if !site_document_target_listed(after^[:], target) {
				append(after, target)
			}
		}
		next: u8 = cursor < len(text) ? text[cursor] : 0
		// Two asides that filled one parenthesis leave "()".
		if strings.has_suffix(strings.to_string(builder), "(") && next == ')' {
			strings.pop_byte(&builder)
			cursor += 1
			next = cursor < len(text) ? text[cursor] : 0
		}
		if strings.has_suffix(strings.to_string(builder), " ") && (next == 0 || next == ' ' || next == '.' || next == ',' || next == ';' || next == ':' || next == ')') {
			strings.pop_byte(&builder)
		}
		if strings.builder_len(builder) == 0 && next == ' ' {
			cursor += 1
		}
	}
	strings.write_string(&builder, text[cursor:])
	return strings.to_string(builder), places[:]
}

// site_comment_text_write writes a text that site_comment_parts marked: as
// HTML, each mark is the reference of its pointer; as plain text, the text
// of the reference.
site_comment_text_write :: proc(site: ^Site, b: ^strings.Builder, from_page, marked: string, in_place: [][]Site_Document_Target, html: bool) {
	rest := marked
	for {
		mark := strings.index_byte(rest, 0)
		if mark < 0 {
			break
		}
		closing := strings.index_byte(rest[mark + 1:], 0)
		if closing < 0 {
			break
		}
		if html {
			site_escape(b, rest[:mark])
		} else {
			strings.write_string(b, rest[:mark])
		}
		number := site_digits_value(rest[mark + 1:mark + 1 + closing])
		if number >= 0 && number < len(in_place) {
			if html {
				site_document_references_write(site, b, from_page, in_place[number], " and ")
			} else {
				for target, index in in_place[number] {
					if index > 0 {
						strings.write_string(b, " and ")
					}
					strings.write_string(b, site_document_target_text(target))
				}
			}
		}
		rest = rest[mark + 1 + closing + 1:]
	}
	if html {
		site_escape(b, rest)
	} else {
		strings.write_string(b, rest)
	}
}

// site_source_comment writes the text of a source comment on a page: each
// pointer to a document becomes a reference. A pointer that is an aside
// leaves its sentence, and its reference goes into one line "See:" after
// the text: the sentence reads with no break, and the reader finds the
// documents in one place. A path that is a word of its sentence ("the rules
// of docs/DESIGN.md") is the reference in its place. Each place is counted.
site_source_comment :: proc(site: ^Site, b: ^strings.Builder, from_page, text: string, form: Site_Comment_Form) {
	after := make([dynamic]Site_Document_Target, context.temp_allocator)
	if form == .Line {
		line_text, line_places := site_comment_parts(site, text, true, &after)
		site_comment_text_write(site, b, from_page, strings.trim_space(line_text), line_places, true)
		if len(after) > 0 {
			strings.write_string(b, " <span class=\"document-references\">See: ")
			site_document_references_write(site, b, from_page, after[:], ", ")
			strings.write_string(b, "</span>")
		}
		return
	}
	for paragraph in strings.split(text, "\n", context.temp_allocator) {
		paragraph_text, paragraph_places := site_comment_parts(site, strings.trim_space(paragraph), true, &after)
		paragraph_text = strings.trim_space(paragraph_text)
		if paragraph_text == "" {
			continue
		}
		strings.write_string(b, "<p>")
		site_comment_text_write(site, b, from_page, paragraph_text, paragraph_places, true)
		strings.write_string(b, "</p>\n")
	}
	if len(after) > 0 {
		strings.write_string(b, "<p class=\"document-references\">See: ")
		site_document_references_write(site, b, from_page, after[:], ", ")
		strings.write_string(b, "</p>\n")
	}
}

// site_source_comment_html gives the markup of site_source_comment.
site_source_comment_html :: proc(site: ^Site, from_page, text: string, form: Site_Comment_Form) -> string {
	b := strings.builder_make(context.temp_allocator)
	site_source_comment(site, &b, from_page, text, form)
	return strings.to_string(b)
}

// site_source_comment_plain gives the text of a source comment with no
// pointer, for a summary: the purpose in a table, the description of a
// page, the search, the first line of a type card. An aside leaves the
// text; a path that is a word of its sentence becomes the title of its
// document. A summary is not counted: the page of the thing shows the
// whole text with its references.
site_source_comment_plain :: proc(site: ^Site, text: string) -> string {
	after := make([dynamic]Site_Document_Target, context.temp_allocator)
	marked, in_place := site_comment_parts(site, text, false, &after)
	b := strings.builder_make(context.temp_allocator)
	site_comment_text_write(site, &b, "", marked, in_place, false)
	return strings.trim_space(strings.to_string(b))
}

// site_comment_cell writes a cell of a table that holds a source comment.
site_comment_cell :: proc(site: ^Site, b: ^strings.Builder, from_page, text: string) {
	strings.write_string(b, "<td>")
	site_source_comment(site, b, from_page, text, .Line)
	strings.write_string(b, "</td>")
}

// site_document_of_code_span gives the document that a code span of a guide
// names: "ARCHITECTURE.md", "docs/FONTS.md", "FIRST_MILESTONE.md".
site_document_of_code_span :: proc(site: ^Site, code: string) -> (path: string, found: bool) {
	base := code[strings.last_index_byte(code, '/') + 1:]
	if site == nil || !strings.has_suffix(base, ".md") {
		return "", false
	}
	if _, is_page := site.documents[base]; is_page || site_is_working_record(base) {
		return strings.concatenate({"docs/", base}, context.temp_allocator), true
	}
	return "", false
}
