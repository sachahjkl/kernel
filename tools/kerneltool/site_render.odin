// The Markdown renderer of the site (docs/SITE.md, "The Markdown that the
// site renders"). It knows the Markdown that the documents of the repository
// use, and no more: headings, paragraphs, lists and nested lists, ordered
// items with their own labels ("34b."), tables, block quotes, fenced code,
// code spans, bold, links and pictures. Anything else is shown as text, and
// the renderer records it, so that the command lists what it did not
// understand. Every text of a file is escaped.
package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"

Site_Heading :: struct {
	level:           int,
	text:            string,
	id:              string,
	first_paragraph: string, // The Markdown of the first paragraph under it, or "": its text in the search index.
}

// A top-level item of an ordered list: its section (the id of the heading
// of level 2 above it), its label ("40", "34b"), its id, and its text.
Site_List_Item :: struct {
	section: string,
	label:   string,
	id:      string,
	text:    string,
	line:    int, // The line of its label in the file: the link to it when the file is not a page of the site.
	heading: int, // The index of the heading above it in the headings of the renderer, or -1: a reference finds it inside the part of a heading.
}

// A term of the glossary: the page links its first use in each other page.
Site_Term :: struct {
	name:           string,
	id:             string,
	definition:     string, // Its short definition: its text in the search index and in the page graph.
	second_of_name: bool, // The glossary has a term of this name before it: a page links the name to that one.
}

Site_Renderer :: struct {
	site:         ^Site,
	page:         string, // The site path of the page.
	source:       string, // The repository path of the Markdown file.
	builder:      strings.Builder,
	ids:          map[string]bool,
	headings:     [dynamic]Site_Heading,
	items:        [dynamic]Site_List_Item,
	section:      string,
	linked_terms: map[string]bool,
	glossary:     bool, // The page of the glossary: a term links to its entry on the same page.
	in_heading:   bool,
	// A source comment, not a document (docs/SITE.md, "The Markdown of a
	// source comment"): a heading, a table, a quote, a line of HTML and a
	// picture are text; a line that starts with a space is a line of an
	// example; a fence with no language is Odin; a link names a place of
	// the site (site_comment_link_target); no term of the glossary links by
	// itself, because each comment of a page is rendered alone.
	comment:            bool,
	// The references of the pointers to documents that are words of their
	// sentence: site_comment_parts put a mark (a zero byte, its number, a
	// zero byte) in the text in their place.
	comment_references: [][]Site_Document_Target,
	// The folders of the sources that the heading of level 2, the heading
	// of level 3 and the paragraph name: a name that several packages
	// declare is resolved by them (site_declaration_resolve).
	section_folders:    []string,
	subsection_folders: []string,
	paragraph_folders:  []string,
}

// site_renderer_context_folders gives the folders that the text around a
// code span names: its headings and its paragraph.
site_renderer_context_folders :: proc(renderer: ^Site_Renderer) -> []string {
	folders := make([dynamic]string, context.temp_allocator)
	append(&folders, ..renderer.section_folders)
	append(&folders, ..renderer.subsection_folders)
	append(&folders, ..renderer.paragraph_folders)
	return folders[:]
}

// site_renderer_place gives the place that the command names for a part of
// the text: the Markdown file, or the page for a source comment, which has
// no file of its own here.
site_renderer_place :: proc(renderer: ^Site_Renderer) -> string {
	return renderer.source != "" ? renderer.source : renderer.page
}

site_renderer_make :: proc(site: ^Site, page, source: string) -> Site_Renderer {
	return Site_Renderer {
		site = site,
		page = page,
		source = source,
		builder = strings.builder_make(context.temp_allocator),
		ids = make(map[string]bool, context.temp_allocator),
		headings = make([dynamic]Site_Heading, context.temp_allocator),
		items = make([dynamic]Site_List_Item, context.temp_allocator),
		linked_terms = make(map[string]bool, context.temp_allocator),
	}
}

// site_slug gives an id from a text: the lowercase letters and the digits,
// one "-" for each run of other characters, none at the ends.
site_slug :: proc(text: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	dash := false
	for index in 0 ..< len(text) {
		character := text[index]
		if character >= 'A' && character <= 'Z' {
			character += 'a' - 'A'
		}
		if (character >= 'a' && character <= 'z') || (character >= '0' && character <= '9') {
			if dash && strings.builder_len(builder) > 0 {
				strings.write_byte(&builder, '-')
			}
			strings.write_byte(&builder, character)
			dash = false
		} else {
			dash = true
		}
	}
	if strings.builder_len(builder) == 0 {
		return "part"
	}
	return strings.to_string(builder)
}

// site_unique_id gives the slug, or the slug with "-2", "-3"... when the page
// has it already.
site_unique_id :: proc(renderer: ^Site_Renderer, wanted: string) -> string {
	id := wanted
	for number := 2; (id in renderer.ids); number += 1 {
		id = fmt.tprintf("%s-%d", wanted, number)
	}
	renderer.ids[id] = true
	return id
}

site_not_rendered :: proc(renderer: ^Site_Renderer, line: int, what: string) {
	append(&renderer.site.not_rendered, fmt.tprintf("%s, line %d: %s", renderer.source, line, what))
}

// The start of a list item: its indentation, its marker and its text.
Site_Marker :: struct {
	indent:  int,
	ordered: bool,
	label:   string,
	text:    string,
}

// site_list_marker reads "- text", "* text", "12. text" or "34b. text" after
// spaces.
site_list_marker :: proc(line: string) -> (marker: Site_Marker, found: bool) {
	indent := 0
	for indent < len(line) && line[indent] == ' ' {
		indent += 1
	}
	rest := line[indent:]
	if strings.has_prefix(rest, "- ") || strings.has_prefix(rest, "* ") {
		return {indent = indent, text = rest[2:]}, true
	}
	digits := 0
	for digits < len(rest) && rest[digits] >= '0' && rest[digits] <= '9' {
		digits += 1
	}
	if digits == 0 || digits > 4 {
		return {}, false
	}
	end := digits
	if end < len(rest) && rest[end] >= 'a' && rest[end] <= 'z' {
		end += 1
	}
	if end + 1 < len(rest) && rest[end] == '.' && rest[end + 1] == ' ' {
		return {indent = indent, ordered = true, label = rest[:end], text = rest[end + 2:]}, true
	}
	return {}, false
}

site_heading_level :: proc(line: string) -> (level: int, text: string) {
	for level < len(line) && line[level] == '#' {
		level += 1
	}
	if level == 0 || level > 6 || level >= len(line) || line[level] != ' ' {
		return 0, ""
	}
	return level, strings.trim_space(line[level + 1:])
}

// site_table_row_cells splits a row of a table; "\|" is a "|" of the text.
site_table_row_cells :: proc(line: string) -> []string {
	cells := make([dynamic]string, context.temp_allocator)
	inner := strings.trim_space(line)
	inner = strings.trim_prefix(inner, "|")
	if strings.has_suffix(inner, "|") && !strings.has_suffix(inner, "\\|") {
		inner = inner[:len(inner) - 1]
	}
	cell := strings.builder_make(context.temp_allocator)
	for index := 0; index < len(inner); index += 1 {
		if inner[index] == '\\' && index + 1 < len(inner) && inner[index + 1] == '|' {
			strings.write_byte(&cell, '|')
			index += 1
			continue
		}
		if inner[index] == '|' {
			append(&cells, strings.trim_space(strings.clone(strings.to_string(cell), context.temp_allocator)))
			strings.builder_reset(&cell)
			continue
		}
		strings.write_byte(&cell, inner[index])
	}
	append(&cells, strings.trim_space(strings.clone(strings.to_string(cell), context.temp_allocator)))
	return cells[:]
}

site_is_table_separator :: proc(line: string) -> bool {
	trimmed := strings.trim_space(line)
	if !strings.has_prefix(trimmed, "|") {
		return false
	}
	for character in transmute([]u8)trimmed {
		if character != '|' && character != '-' && character != ':' && character != ' ' {
			return false
		}
	}
	return strings.contains(trimmed, "-")
}

// site_render_markdown renders a whole Markdown text into the renderer.
// first_heading_level: the level that the first heading of the file takes
// (1 for a guide, whose title is the h1 of its page).
site_render_markdown :: proc(renderer: ^Site_Renderer, content: string, first_line_number: int = 1) {
	lines := site_lines(content)
	b := &renderer.builder
	index := 0
	for index < len(lines) {
		line := lines[index]
		trimmed := strings.trim_space(line)
		number := index + first_line_number
		if trimmed == "" {
			index += 1
			continue
		}
		// A fenced block of code.
		if strings.has_prefix(trimmed, "```") {
			index = site_render_fence(renderer, lines, index, first_line_number)
			continue
		}
		if renderer.comment {
			// A comment sits under the heading of its symbol, in a page or
			// in a cell: it has paragraphs, lists and examples only.
			if _, is_marker := site_list_marker(line); is_marker {
				index = site_render_list(renderer, lines, index, first_line_number)
			} else if line[0] == ' ' {
				index = site_render_example(renderer, lines, index)
			} else {
				index = site_render_paragraph(renderer, lines, index)
			}
			continue
		}
		if level, text := site_heading_level(line); level > 0 {
			id := site_unique_id(renderer, site_slug(text))
			if level == 2 {
				renderer.section = id
			}
			if renderer.site != nil {
				switch {
				case level <= 2:
					renderer.section_folders = site_context_folders(&renderer.site.declarations, text)
					renderer.subsection_folders = nil
				case level == 3:
					renderer.subsection_folders = site_context_folders(&renderer.site.declarations, text)
				}
			}
			append(&renderer.headings, Site_Heading{level = level, text = text, id = id})
			fmt.sbprintf(b, "<h%d id=\"%s\">", level, id)
			renderer.in_heading = true
			site_render_inline(renderer, text)
			renderer.in_heading = false
			fmt.sbprintf(b, "</h%d>\n", level)
			index += 1
			continue
		}
		if strings.has_prefix(trimmed, "|") {
			index = site_render_table(renderer, lines, index, first_line_number)
			continue
		}
		if strings.has_prefix(trimmed, ">") {
			strings.write_string(b, "<blockquote>\n")
			quoted := make([dynamic]string, context.temp_allocator)
			for index < len(lines) && strings.has_prefix(strings.trim_space(lines[index]), ">") {
				append(&quoted, strings.trim_space(strings.trim_prefix(strings.trim_space(lines[index]), ">")))
				index += 1
			}
			strings.write_string(b, "<p>")
			site_render_inline(renderer, strings.join(quoted[:], " ", context.temp_allocator))
			strings.write_string(b, "</p>\n</blockquote>\n")
			continue
		}
		if _, is_marker := site_list_marker(line); is_marker {
			index = site_render_list(renderer, lines, index, first_line_number)
			continue
		}
		if strings.has_prefix(trimmed, "<") {
			site_not_rendered(renderer, number, "a line of HTML, shown as text")
		}
		index = site_render_paragraph(renderer, lines, index)
	}
}

// site_render_paragraph writes a paragraph: the lines from start up to an
// empty line or the start of a block. In a comment, a line that starts with
// a space starts an example, and a heading, a table and a quote are words.
// It gives the line after the paragraph.
site_render_paragraph :: proc(renderer: ^Site_Renderer, lines: []string, start: int) -> int {
	parts := make([dynamic]string, context.temp_allocator)
	index := start
	for index < len(lines) {
		line := lines[index]
		next := strings.trim_space(line)
		if next == "" || strings.has_prefix(next, "```") {
			break
		}
		if _, is_marker := site_list_marker(line); is_marker && len(parts) > 0 {
			break
		}
		if renderer.comment {
			if line[0] == ' ' && len(parts) > 0 {
				break
			}
		} else {
			if strings.has_prefix(next, "|") || strings.has_prefix(next, ">") {
				break
			}
			if level, _ := site_heading_level(line); level > 0 {
				break
			}
		}
		append(&parts, next)
		index += 1
	}
	paragraph := strings.join(parts[:], " ", context.temp_allocator)
	if len(renderer.headings) > 0 && renderer.headings[len(renderer.headings) - 1].first_paragraph == "" {
		renderer.headings[len(renderer.headings) - 1].first_paragraph = paragraph
	}
	strings.write_string(&renderer.builder, "<p>")
	site_render_inline(renderer, paragraph)
	strings.write_string(&renderer.builder, "</p>\n")
	return index
}

// site_render_example writes the lines of a comment that start with a space
// as one block of code, as they are, with the indentation that they share
// taken away: the form that the documentation of a module keeps
// (contract/module/format.odin, Documentation). Its language is not known,
// so it is not colored: these lines are often words aligned in columns. It
// gives the line after the block.
site_render_example :: proc(renderer: ^Site_Renderer, lines: []string, start: int) -> int {
	end := start
	shared := -1
	for end < len(lines) {
		line := lines[end]
		if line == "" || line[0] != ' ' {
			break
		}
		if _, is_marker := site_list_marker(line); is_marker {
			break
		}
		if strings.trim_space(line) != "" {
			indent := len(line) - len(strings.trim_left(line, " "))
			shared = shared < 0 ? indent : min(shared, indent)
		}
		end += 1
	}
	b := &renderer.builder
	strings.write_string(b, "<pre><code>")
	for line in lines[start:end] {
		site_escape(b, line[min(max(shared, 0), len(line)):])
		strings.write_byte(b, '\n')
	}
	strings.write_string(b, "</code></pre>\n")
	return max(end, start + 1)
}

site_render_fence :: proc(renderer: ^Site_Renderer, lines: []string, start: int, first_line_number: int) -> int {
	b := &renderer.builder
	opening := strings.trim_space(lines[start])
	language := strings.trim_space(opening[3:])
	if language == "mermaid" {
		site_not_rendered(renderer, start + first_line_number, "a mermaid diagram, shown as its text")
	}
	indent := strings.index(lines[start], "```")
	index := start + 1
	code_text := strings.builder_make(context.temp_allocator)
	for index < len(lines) && strings.trim_space(lines[index]) != "```" {
		code := lines[index]
		// The code of a fence inside a list item has the indentation of the item.
		if indent > 0 && len(code) >= indent && strings.trim_space(code[:indent]) == "" {
			code = code[indent:]
		}
		strings.write_string(&code_text, code)
		strings.write_byte(&code_text, '\n')
		index += 1
	}
	strings.write_string(b, "<pre><code>")
	// Only a block that its document marks as Odin is colored: the language
	// of a block with no mark is not guessed. A fence of a comment is in an
	// Odin source, so its block is Odin unless it names another language.
	if (language == "odin" || renderer.comment && language == "") && renderer.site != nil {
		place := fmt.tprintf("%s:%d", site_renderer_place(renderer), start + first_line_number)
		strings.write_string(b, site_code_block_html(renderer.site, strings.to_string(code_text), "", place))
	} else {
		site_escape(b, strings.to_string(code_text))
	}
	strings.write_string(b, "</code></pre>\n")
	if index >= len(lines) {
		site_not_rendered(renderer, start + first_line_number, "a fence with no end, shown to the end of the file")
	}
	return index + 1
}

site_render_table :: proc(renderer: ^Site_Renderer, lines: []string, start: int, first_line_number: int) -> int {
	b := &renderer.builder
	end := start
	for end < len(lines) && strings.has_prefix(strings.trim_space(lines[end]), "|") {
		end += 1
	}
	if end - start < 2 || !site_is_table_separator(lines[start + 1]) {
		site_not_rendered(renderer, start + first_line_number, "a table with no line of dashes, shown as text")
		strings.write_string(b, "<p>")
		site_render_inline(renderer, strings.join(lines[start:end], " ", context.temp_allocator))
		strings.write_string(b, "</p>\n")
		return end
	}
	header := site_table_row_cells(lines[start])
	// The box of the table: a region that the keyboard reaches, named by the
	// heading above the table. A column of a document has no known kind: it
	// gets the general least width, and a cell that holds only a number or
	// a date is never broken.
	region_name := len(renderer.headings) > 0 ? renderer.headings[len(renderer.headings) - 1].text : "Table"
	strings.write_string(b, "<div class=\"table\" role=\"region\" tabindex=\"0\" aria-label=\"")
	site_plain(b, region_name)
	strings.write_string(b, "\"><table>\n<thead><tr>")
	for cell in header {
		strings.write_string(b, "<th scope=\"col\" class=\"" + "column-any" + "\">")
		site_render_inline(renderer, cell)
		strings.write_string(b, "</th>")
	}
	strings.write_string(b, "</tr></thead>\n<tbody>\n")
	for row in lines[start + 2:end] {
		cells := site_table_row_cells(row)
		strings.write_string(b, "<tr>")
		for cell_index in 0 ..< len(header) {
			kind := cell_index < len(cells) ? site_cell_kind(cells[cell_index]) : Site_Column_Kind.Any
			fmt.sbprintf(b, "<td class=\"%s\">", site_column_classes[kind])
			if cell_index < len(cells) {
				site_render_inline(renderer, cells[cell_index])
			}
			strings.write_string(b, "</td>")
		}
		strings.write_string(b, "</tr>\n")
	}
	strings.write_string(b, "</tbody></table></div>\n")
	return end
}

// A list item before it is written: its marker, its text with the lines
// that continue it, and the blocks of code inside it.
Site_Pending_Item :: struct {
	marker: Site_Marker,
	text:   [dynamic]string,
	code:   [dynamic]string, // The HTML of each fenced block of the item.
	line:   int, // The line of its marker in the file.
}

site_render_list :: proc(renderer: ^Site_Renderer, lines: []string, start: int, first_line_number: int) -> int {
	items := make([dynamic]Site_Pending_Item, context.temp_allocator)
	index := start
	for index < len(lines) {
		line := lines[index]
		trimmed := strings.trim_space(line)
		if trimmed == "" {
			// The list goes on after an empty line only with an item or an
			// indented line.
			next := index + 1
			for next < len(lines) && strings.trim_space(lines[next]) == "" {
				next += 1
			}
			if next >= len(lines) {
				index = next
				break
			}
			if _, is_marker := site_list_marker(lines[next]); is_marker || strings.has_prefix(lines[next], "  ") {
				index = next
				continue
			}
			index = next
			break
		}
		if marker, is_marker := site_list_marker(line); is_marker {
			item := Site_Pending_Item {
				marker = marker,
				text   = make([dynamic]string, context.temp_allocator),
				code   = make([dynamic]string, context.temp_allocator),
				line   = first_line_number + index,
			}
			append(&item.text, marker.text)
			append(&items, item)
			index += 1
			continue
		}
		// In a comment, a line right after an item continues it, as in the
		// text that a module carries: a comment wraps its lines where its
		// width ends, with no indentation.
		if len(items) > 0 && (line[0] == ' ' || renderer.comment) {
			if strings.has_prefix(trimmed, "```") {
				// A block of code inside the item.
				saved := renderer.builder
				renderer.builder = strings.builder_make(context.temp_allocator)
				index = site_render_fence(renderer, lines, index, first_line_number)
				append(&items[len(items) - 1].code, strings.to_string(renderer.builder))
				renderer.builder = saved
				continue
			}
			append(&items[len(items) - 1].text, trimmed)
			index += 1
			continue
		}
		break
	}
	position := 0
	for position < len(items) {
		site_write_list(renderer, items[:], &position, items[position].marker.indent, 0)
	}
	return index
}

// site_write_list writes the items from position that have the indentation
// of the first one, and the deeper items inside them.
site_write_list :: proc(renderer: ^Site_Renderer, items: []Site_Pending_Item, position: ^int, indent: int, depth: int) {
	b := &renderer.builder
	ordered := items[position^].marker.ordered
	strings.write_string(b, ordered ? "<ol class=\"labelled\">\n" : "<ul>\n")
	for position^ < len(items) && items[position^].marker.indent >= indent && items[position^].marker.ordered == ordered {
		item := items[position^]
		position^ += 1
		text := strings.join(item.text[:], " ", context.temp_allocator)
		if ordered {
			id := ""
			// An item of a comment has no id: a page holds many comments,
			// and a pointer names the items of a document only.
			if depth == 0 && !renderer.comment {
				id = site_unique_id(renderer, strings.concatenate({renderer.section != "" ? renderer.section : "item", "-", item.marker.label}, context.temp_allocator))
				append(&renderer.items, Site_List_Item{section = renderer.section, label = item.marker.label, id = id, text = text, line = item.line, heading = len(renderer.headings) - 1})
				fmt.sbprintf(b, "<li id=\"%s\">", id)
			} else {
				strings.write_string(b, "<li>")
			}
			fmt.sbprintf(b, "<span class=\"label\">%s.</span> ", item.marker.label)
		} else {
			strings.write_string(b, "<li>")
		}
		site_render_inline(renderer, text)
		for code in item.code {
			strings.write_string(b, code)
		}
		for position^ < len(items) && items[position^].marker.indent > indent {
			site_write_list(renderer, items, position, items[position^].marker.indent, depth + 1)
		}
		strings.write_string(b, "</li>\n")
	}
	strings.write_string(b, ordered ? "</ol>\n" : "</ul>\n")
}

// site_term_name gives the name of a term from the heading of its entry in
// the glossary: its text with no code marks.
site_term_name :: proc(cell: string) -> string {
	name, _ := strings.remove_all(cell, "`", context.temp_allocator)
	return strings.trim_space(name)
}

// site_repository_path says if a code span names a file or a folder of the
// repository, from the root or from the folder of the Markdown file, and
// gives its path. The folder of the build is not in the repository.
site_repository_path :: proc(source, text: string) -> (path: string, found: bool) {
	candidate := text
	// "file.odin:34": a line of a file.
	if colon := strings.last_index_byte(candidate, ':'); colon > 0 && site_digits_value(candidate[colon + 1:]) >= 0 {
		candidate = candidate[:colon]
	}
	// A path from the root of the host ("/dev/kvm") is not a file of the
	// repository, even when the host has it.
	if candidate == "" || strings.contains_any(candidate, " *?<>\"'(){}$`") || !strings.contains_any(candidate, "/.") || strings.has_prefix(candidate, "-") || strings.has_prefix(candidate, ".") || strings.has_prefix(candidate, "/") {
		return "", false
	}
	folder := source[:max(strings.last_index_byte(source, '/'), 0)]
	for option in ([]string{candidate, strings.concatenate({folder, "/", candidate}, context.temp_allocator)}) {
		cleaned := strings.trim_suffix(option, "/")
		// A text with no folder (a source comment) has no folder option: "/"
		// and the candidate would be a path of the host.
		if strings.has_prefix(cleaned, BUILD_FOLDER) || cleaned == "" || strings.has_prefix(cleaned, "/") {
			continue
		}
		if os.exists(cleaned) {
			return cleaned, true
		}
	}
	return "", false
}

// site_render_inline writes a line of Markdown: code spans (a link when they
// name a guide or a file of the repository), bold, links, pictures, and the
// first use of each term of the glossary on the page.
site_render_inline :: proc(renderer: ^Site_Renderer, text: string) {
	b := &renderer.builder
	bold_open := false
	italic_close := -1
	plain_start := 0
	index := 0
	// A source comment names no folder around its spans.
	if renderer.site != nil && !renderer.in_heading && !renderer.comment {
		renderer.paragraph_folders = site_context_folders(&renderer.site.declarations, text)
	}
	flush :: proc(renderer: ^Site_Renderer, text: string) {
		site_write_with_terms(renderer, text)
	}
	for index < len(text) {
		character := text[index]
		if character == '`' {
			end := strings.index_byte(text[index + 1:], '`')
			if end >= 0 {
				flush(renderer, text[plain_start:index])
				code := text[index + 1:index + 1 + end]
				index += end + 2
				// A code span that names a document, with the labels of a
				// place after it (`ARCHITECTURE.md`, "The fault ring"), is a
				// reference to that place, as a pointer of a source comment.
				if path, names_document := site_document_of_code_span(renderer.site, code); names_document && !renderer.in_heading {
					labels, labels_end := site_pointer_labels(text, index)
					targets := site_document_targets(renderer.site, path, labels)
					if len(targets) > 0 {
						site_document_references_count(renderer.site, path, labels, targets)
						site_document_references_write(renderer.site, &renderer.builder, renderer.page, targets, " and ")
						index = labels_end
						plain_start = index
						continue
					}
				}
				site_write_code_span(renderer, code)
				plain_start = index
				continue
			}
		}
		if character == '*' && index + 1 < len(text) && text[index + 1] == '*' {
			flush(renderer, text[plain_start:index])
			strings.write_string(b, bold_open ? "</strong>" : "<strong>")
			bold_open = !bold_open
			index += 2
			plain_start = index
			continue
		}
		// Italics: "*words*", and only when the closing star exists, so a
		// star of an expression ("a * b", "2*3") stays a star.
		if character == '*' && (index == italic_close || italic_close < 0 && markdown_italic_opens(text, index)) {
			flush(renderer, text[plain_start:index])
			if index == italic_close {
				strings.write_string(b, "</em>")
				italic_close = -1
			} else {
				strings.write_string(b, "<em>")
				italic_close = markdown_italic_close(text, index + 1)
			}
			index += 1
			plain_start = index
			continue
		}
		// The place of a pointer to a document that is a word of its
		// sentence: its reference (site_comment_parts).
		if character == 0 && renderer.comment {
			closing := strings.index_byte(text[index + 1:], 0)
			if closing >= 0 {
				flush(renderer, text[plain_start:index])
				number := site_digits_value(text[index + 1:index + 1 + closing])
				if number >= 0 && number < len(renderer.comment_references) {
					site_document_references_write(renderer.site, b, renderer.page, renderer.comment_references[number], " and ")
				}
				index += closing + 2
				plain_start = index
				continue
			}
		}
		// A comment links to the places of the site, not to files, and has
		// no picture: "![" is text there.
		if renderer.comment && character == '[' {
			if label, target, end, found := markdown_link_at(text, index); found {
				flush(renderer, text[plain_start:index])
				site_comment_link_write(renderer, label, target)
				index = end
				plain_start = index
				continue
			}
			index += 1
			continue
		}
		is_picture := !renderer.comment && character == '!' && index + 1 < len(text) && text[index + 1] == '['
		if (character == '[' && !renderer.comment) || is_picture {
			open := is_picture ? index + 1 : index
			closing := strings.index_byte(text[open + 1:], ']')
			if closing >= 0 {
				after := open + 1 + closing + 1
				if after < len(text) && text[after] == '(' {
					end := strings.index_byte(text[after + 1:], ')')
					if end >= 0 {
						flush(renderer, text[plain_start:index])
						label := text[open + 1:open + 1 + closing]
						target := text[after + 1:after + 1 + end]
						if is_picture {
							site_write_picture(renderer, label, target)
						} else {
							site_write_link(renderer, label, target)
						}
						index = after + 1 + end + 1
						plain_start = index
						continue
					}
				}
			}
		}
		index += 1
	}
	flush(renderer, text[plain_start:])
	if italic_close >= 0 {
		strings.write_string(b, "</em>")
	}
	if bold_open {
		strings.write_string(b, "</strong>")
	}
}

// site_write_code_span writes a code span that names no document (those are
// references: site_render_inline): a link to a row of a reference table or
// to a file of the repository, or code.
site_write_code_span :: proc(renderer: ^Site_Renderer, code: string) {
	b := &renderer.builder
	if renderer.site == nil {
		strings.write_string(b, "<code>")
		site_escape(b, code)
		strings.write_string(b, "</code>")
		return
	}
	if target, named := site_code_link(renderer.site, code); named && !renderer.in_heading {
		fmt.sbprintf(b, "<a class=\"reference\" href=\"%s\"><code>", site_page_link(renderer.site, renderer.page, target))
		site_escape(b, code)
		strings.write_string(b, "</code></a>")
		return
	}
	if path, found := site_repository_path(renderer.source, code); found && !renderer.in_heading {
		strings.write_string(b, "<a href=\"")
		site_escape(b, site_repository_file(renderer.site, path))
		strings.write_string(b, "\"><code>")
		site_escape(b, code)
		strings.write_string(b, "</code></a>")
		return
	}
	// A name of a declaration of the sources, or a fragment of Odin
	// (docs/SITE.md, "The declarations of the sources").
	if !renderer.in_heading && site_declaration_code_span(renderer.site, b, renderer.page, site_renderer_place(renderer), code, site_renderer_context_folders(renderer)) {
		return
	}
	strings.write_string(b, "<code>")
	site_escape(b, code)
	strings.write_string(b, "</code>")
}

site_write_link :: proc(renderer: ^Site_Renderer, label, target: string) {
	b := &renderer.builder
	address := target
	if hash := strings.index_byte(address, '#'); hash >= 0 {
		// The anchor of another file is dropped: the ids of a page of the
		// site are not the anchors of the host of the repository.
		address = address[:hash]
	}
	if address == "" {
		site_render_inline_plain(renderer, label)
		return
	}
	if strings.has_prefix(address, "https://") || strings.has_prefix(address, "http://") {
		strings.write_string(b, "<a href=\"")
		site_escape(b, address)
		strings.write_string(b, "\">")
		site_render_inline_plain(renderer, label)
		strings.write_string(b, "</a>")
		return
	}
	folder := renderer.source[:max(strings.last_index_byte(renderer.source, '/'), 0)]
	resolved := site_path_join(folder, address)
	if page, is_guide := renderer.site.documents[resolved]; is_guide {
		fmt.sbprintf(b, "<a href=\"%s\">", site_page_link(renderer.site, renderer.page, page))
		site_render_inline_plain(renderer, label)
		strings.write_string(b, "</a>")
		return
	}
	if os.exists(resolved) {
		strings.write_string(b, "<a href=\"")
		site_escape(b, site_repository_file(renderer.site, resolved))
		strings.write_string(b, "\">")
		site_render_inline_plain(renderer, label)
		strings.write_string(b, "</a>")
		return
	}
	site_not_rendered(renderer, 0, fmt.tprintf("a link to %s, which is not a file of the repository: its text only", target))
	site_render_inline_plain(renderer, label)
}

// site_write_picture writes a picture of the repository: the command copies
// it into the site (site.copies).
site_write_picture :: proc(renderer: ^Site_Renderer, alt, target: string) {
	folder := renderer.source[:max(strings.last_index_byte(renderer.source, '/'), 0)]
	resolved := site_path_join(folder, target)
	data, err := os.read_entire_file(resolved, context.temp_allocator)
	width, height, is_png := site_png_size(data)
	if err != nil || !is_png {
		site_not_rendered(renderer, 0, fmt.tprintf("a picture %s that is not a PNG file of the repository: its text only", target))
		site_escape(&renderer.builder, alt)
		return
	}
	site_path := strings.concatenate({SITE_PICTURE_FOLDER, "/", site_file_name(resolved)}, context.temp_allocator)
	renderer.site.copies[site_path] = resolved
	fmt.sbprintf(&renderer.builder, "<img src=\"%s\" width=\"%d\" height=\"%d\" loading=\"lazy\" decoding=\"async\" alt=\"", site_relative(renderer.page, site_path), width, height)
	site_plain(&renderer.builder, alt)
	strings.write_string(&renderer.builder, "\">")
}

// site_render_inline_plain writes the text of a link: code and bold, no
// link inside a link, no term.
site_render_inline_plain :: proc(renderer: ^Site_Renderer, text: string) {
	site_inline(&renderer.builder, text)
}

// site_path_join joins a folder and a relative path, with "." and "..".
site_path_join :: proc(folder, relative: string) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	if folder != "" && !strings.has_prefix(relative, "/") {
		for part in strings.split(folder, "/", context.temp_allocator) {
			append(&parts, part)
		}
	}
	for part in strings.split(strings.trim_prefix(relative, "/"), "/", context.temp_allocator) {
		switch part {
		case "", ".":
		case "..":
			if len(parts) > 0 {
				pop(&parts)
			}
		case:
			append(&parts, part)
		}
	}
	return strings.join(parts[:], "/", context.temp_allocator)
}

site_is_word_byte :: proc(character: u8) -> bool {
	return (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9') || character == '_' || character >= 0x80
}

site_lower :: proc(character: u8) -> u8 {
	return character >= 'A' && character <= 'Z' ? character + ('a' - 'A') : character
}

// site_term_at says if a term of the glossary starts at index of text: the
// same letters with no regard to case, a whole word, or the word with "s".
site_term_at :: proc(text: string, index: int, name: string) -> (length: int, found: bool) {
	if index + len(name) > len(text) || (index > 0 && site_is_word_byte(text[index - 1])) {
		return 0, false
	}
	for offset in 0 ..< len(name) {
		if site_lower(text[index + offset]) != site_lower(name[offset]) {
			return 0, false
		}
	}
	end := index + len(name)
	if end < len(text) && text[end] == 's' && (end + 1 >= len(text) || !site_is_word_byte(text[end + 1])) {
		end += 1
	}
	if end < len(text) && site_is_word_byte(text[end]) {
		return 0, false
	}
	return end - index, true
}

// site_write_with_terms writes plain text, escaped, with a link on the first
// use of each term of the glossary on the page. Not in a heading. On the page
// of the glossary, the link names the entry on the same page, and each entry
// links each other term once (site_glossary_write).
site_write_with_terms :: proc(renderer: ^Site_Renderer, text: string) {
	b := &renderer.builder
	if renderer.in_heading || renderer.comment || renderer.site == nil || len(renderer.site.terms) == 0 {
		site_escape(b, text)
		return
	}
	written := 0
	index := 0
	for index < len(text) {
		if index > 0 && site_is_word_byte(text[index - 1]) {
			index += 1
			continue
		}
		matched := false
		// The terms are sorted from the longest: "Module metadata" before "Module".
		for term in renderer.site.terms {
			if term.second_of_name || term.id in renderer.linked_terms {
				continue
			}
			length, found := site_term_at(text, index, term.name)
			if !found {
				continue
			}
			site_escape(b, text[written:index])
			if renderer.glossary {
				fmt.sbprintf(b, "<a class=\"term\" href=\"#%s\">", term.id)
			} else {
				// The short definition is the tooltip of the link: a reader
				// learns the term without leaving the page.
				fmt.sbprintf(b, "<a class=\"term\" href=\"%s#%s\"", site_page_link(renderer.site, renderer.page, site_page_file(SITE_GLOSSARY_FOLDER)), term.id)
				if term.definition != "" {
					strings.write_string(b, " title=\"")
					site_plain(b, term.definition)
					strings.write_string(b, "\"")
				}
				strings.write_string(b, ">")
			}
			site_escape(b, text[index:index + length])
			strings.write_string(b, "</a>")
			renderer.linked_terms[term.id] = true
			index += length
			written = index
			matched = true
			break
		}
		if !matched {
			index += 1
		}
	}
	site_escape(b, text[written:])
}
