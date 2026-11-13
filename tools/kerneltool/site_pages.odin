// The pages of the site (docs/SITE.md, "The pages"). Each page is generated
// from files of the repository or from the logs of the last machine tests.
// The home is the front door and shows the system; every other page is
// documentation: a guide (a document of docs/) or a reference table.
package kerneltool

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

SITE_BOOT_STAGE_PREFIX :: "kernel: boot: "
// The file of the table of the commands of the tool.
SITE_TOOL_MAIN_FILE :: "tools/kerneltool/main.odin"

// A table that the reference shows: its file and its title, for its
// line in the index of the reference.
Site_Reference_Entry :: struct {
	path:   string,
	title:  string,
	what:   string,
	source: string,
	count:  int, // The rows of its tables: the docs home shows it.
	kind:   Site_Value_Kind, // The kind of what its rows name: the docs home shows its icon.
}

// The kind of a column of a table (docs/SITE.md, "The tables"): it gives the
// least width of the column, and whether its cells may wrap. The writer of
// each table knows what each column holds, so it states the kind.
Site_Column_Kind :: enum {
	Name, // An identifier, a path, a signature: one line.
	Short, // A few words: a kind, a status, a version.
	Prose, // Sentences: at least about 28 characters wide.
	Line, // A quoted line of a log or of code: at least about 60 characters of the monospace font.
	Date, // A date and a time: never broken.
	Number, // A number: never broken, aligned right.
	List, // Several names, one value each (site_value_list): broken between the names, never inside one.
	Any, // A column of a table of a document, whose kind the tool does not know.
}

site_column_classes := [Site_Column_Kind]string {
	.Name   = "column-name",
	.Short  = "column-short",
	.Prose  = "column-prose",
	.Line   = "column-line",
	.Date   = "column-date",
	.Number = "column-number",
	.List   = "column-list",
	.Any    = "column-any",
}

Site_Column :: struct {
	header: string,
	kind:   Site_Column_Kind,
}

// The columns of the table of the measured numbers: the sentence, the line
// of the log as it is quoted, where it comes from, and when the log was
// written.
site_numbers_columns := [?]Site_Column {
	{"What", .Prose},
	{"The line of the log", .Line},
	{"Log, line, machine", .Prose},
	{"Written", .Date},
}

// A table that is being written: where it starts in the builder, and the
// kind of each column.
Site_Table :: struct {
	start:   int,
	kinds:   []Site_Column_Kind,
	classes: []string, // The class of the cells of each column: its kind, and the kind of its values.
}

// site_column_value_kind gives the kind of the values of a column: the one
// that its writer states, else the number kind for a column of numbers and
// the time kind for a column of dates. A column of names or of prose holds
// no value of one kind.
site_column_value_kind :: proc(column_kind: Site_Column_Kind, stated: Site_Value_Kind) -> Site_Value_Kind {
	if stated != .None {
		return stated
	}
	#partial switch column_kind {
	case .Number:
		return .Number
	case .Date:
		return .Time
	}
	return .None
}

// site_table_start writes the start of a table: its box, which scrolls
// sideways when the table is wider than the page and which the keyboard
// reaches (a region named by the name of the table), and its header cells,
// each with the class of the kind of its column. A column whose values
// are all of one kind (values, by the place of the column; .None for a
// column of another sort) shows the icon of that kind once, in its head,
// and its cells keep the font and the color of the kind: no row repeats
// the icon (docs/SITE.md, "The kinds of values").
site_table_start :: proc(b: ^strings.Builder, name: string, columns: []Site_Column, values: []Site_Value_Kind = nil) -> Site_Table {
	table := Site_Table{start = strings.builder_len(b^), kinds = make([]Site_Column_Kind, len(columns), context.temp_allocator), classes = make([]string, len(columns), context.temp_allocator)}
	strings.write_string(b, "<div class=\"table\" role=\"region\" tabindex=\"0\" aria-label=\"")
	site_escape(b, name)
	strings.write_string(b, "\"><table>\n<thead><tr>")
	for column, index in columns {
		table.kinds[index] = column.kind
		stated: Site_Value_Kind = index < len(values) ? values[index] : .None
		value_kind := site_column_value_kind(column.kind, stated)
		table.classes[index] = site_column_classes[column.kind]
		head_class := site_column_classes[column.kind]
		if value_kind != .None {
			value_name := site_value_kinds[value_kind].name
			table.classes[index] = strings.concatenate({site_column_classes[column.kind], " value value-", value_name}, context.temp_allocator)
			head_class = strings.concatenate({site_column_classes[column.kind], " value-head value-icon value-", value_name}, context.temp_allocator)
		}
		fmt.sbprintf(b, "<th scope=\"col\" class=\"%s\">", head_class)
		site_escape(b, column.header)
		strings.write_string(b, "</th>")
	}
	strings.write_string(b, "</tr></thead>\n<tbody>\n")
	return table
}

// site_table_end ends a table, and gives each cell of its body the class
// of the kind of its column: the writers of the rows need not repeat it.
site_table_end :: proc(b: ^strings.Builder, table: Site_Table) {
	strings.write_string(b, "</tbody></table></div>\n")
	written := strings.to_string(b^)
	body_start := strings.index(written[table.start:], "<tbody>")
	if body_start < 0 {
		return
	}
	body_start += table.start
	body := strings.clone(written[body_start:], context.temp_allocator)
	resize(&b.buf, body_start)
	strings.write_string(b, site_table_cells_with_classes(body, table.classes))
}

// site_table_cells_with_classes gives the body of a table with the class
// of its column on each cell, by the place of the cell in its row.
site_table_cells_with_classes :: proc(body: string, classes: []string) -> string {
	out := strings.builder_make(context.temp_allocator)
	column := 0
	index := 0
	for index < len(body) {
		rest := body[index:]
		if strings.has_prefix(rest, "<tr") && len(rest) > 3 && (rest[3] == '>' || rest[3] == ' ') {
			column = 0
		} else if (strings.has_prefix(rest, "<td") || strings.has_prefix(rest, "<th")) && len(rest) > 3 && (rest[3] == '>' || rest[3] == ' ') {
			class := column < len(classes) ? classes[column] : ""
			column += 1
			if class != "" {
				strings.write_string(&out, rest[:3])
				after := rest[3:]
				switch {
				case strings.has_prefix(after, " class=\""):
					strings.write_string(&out, " class=\"")
					strings.write_string(&out, class)
					strings.write_byte(&out, ' ')
					index += 3 + len(" class=\"")
				case:
					strings.write_string(&out, " class=\"")
					strings.write_string(&out, class)
					strings.write_byte(&out, '"')
					index += 3
				}
				continue
			}
		}
		strings.write_byte(&out, body[index])
		index += 1
	}
	return strings.to_string(out)
}

// site_cell_kind gives the kind of a cell of a table of a document that
// holds only a number or a date ("2026-11-12", "2026-11-12 02:09 UTC"),
// else Any: such a cell is never broken.
site_cell_kind :: proc(text: string) -> Site_Column_Kind {
	trimmed := strings.trim_space(text)
	if trimmed == "" {
		return .Any
	}
	is_number := true
	for character in transmute([]u8)trimmed {
		if !((character >= '0' && character <= '9') || character == '.' || character == ',' || character == '_' || character == ' ' || character == '%') {
			is_number = false
		}
	}
	if is_number && trimmed[0] >= '0' && trimmed[0] <= '9' {
		return .Number
	}
	if len(trimmed) >= 10 && site_is_date(trimmed[:10]) {
		after := trimmed[10:]
		if after == "" || after == " UTC" || (len(after) == 10 && after[0] == ' ' && after[3] == ':' && strings.has_suffix(after, " UTC")) {
			return .Date
		}
	}
	return .Any
}

// site_is_date tells whether a text is a date "yyyy-mm-dd" by its form.
site_is_date :: proc(text: string) -> bool {
	if len(text) != 10 || text[4] != '-' || text[7] != '-' {
		return false
	}
	for character, index in transmute([]u8)text {
		if index != 4 && index != 7 && (character < '0' || character > '9') {
			return false
		}
	}
	return true
}

// site_time writes a date and a time of the form "2026-11-12 02:09 UTC" as
// a time element whose machine form is "2026-11-12T02:09Z"; another text is
// written as it is.
site_time :: proc(b: ^strings.Builder, text: string) {
	if site_cell_kind(text) != .Date || len(text) < 10 {
		site_escape(b, text)
		return
	}
	machine := text[:10]
	if len(text) == 20 {
		machine = strings.concatenate({text[:10], "T", text[11:16], "Z"}, context.temp_allocator)
	}
	fmt.sbprintf(b, "<time datetime=\"%s\">", machine)
	site_escape(b, text)
	strings.write_string(b, "</time>")
}

// site_cell writes one cell of inline Markdown.
site_cell :: proc(b: ^strings.Builder, text: string, class: string = "") {
	if class != "" {
		fmt.sbprintf(b, "<td class=\"%s\">", class)
	} else {
		strings.write_string(b, "<td>")
	}
	site_inline(b, text)
	strings.write_string(b, "</td>")
}

// site_source_line names the files that a table is read from, as links to
// the repository at the commit of the build.
site_source_line :: proc(site: ^Site, b: ^strings.Builder, sources: ..string) {
	strings.write_string(b, "<p class=\"source\">Read from ")
	for source, index in sources {
		if index > 0 {
			strings.write_string(b, index == len(sources) - 1 ? " and " : ", ")
		}
		strings.write_string(b, "<a href=\"")
		site_escape(b, site_repository_file(site, source))
		strings.write_string(b, "\"><code>")
		site_escape(b, source)
		strings.write_string(b, "</code></a>")
	}
	strings.write_string(b, ".</p>\n")
}

// site_document_title gives the text of the first heading "# " of a file.
site_document_title :: proc(content: string) -> string {
	for line in site_lines(content) {
		if strings.has_prefix(line, "# ") {
			return strings.trim_space(line[2:])
		}
	}
	return ""
}

// site_document_description gives the first sentence of the first
// paragraph of a document that is not its line "Status: ...".
site_document_description :: proc(content: string) -> string {
	for paragraph in site_paragraphs(site_lines(content)) {
		if !strings.has_prefix(paragraph, "Status:") {
			return site_description_cut(site_first_sentence(paragraph))
		}
	}
	return ""
}

// site_readme_documents reads the table of the section "## Documents" of
// README.md: "| `docs/<name>.md` | <what it holds> |".
site_readme_documents :: proc(content: string) -> map[string]string {
	about := make(map[string]string, context.temp_allocator)
	section, _ := site_section_lines(site_lines(content), "## Documents")
	for line in section {
		if !strings.has_prefix(line, "| `docs/") {
			continue
		}
		cells := site_table_row_cells(line)
		if len(cells) >= 2 {
			about[strings.trim(cells[0], "`")] = cells[1]
		}
	}
	return about
}

site_guides_add :: proc(site: ^Site) -> bool {
	readme_text := site_read(SITE_README_FILE) or_return
	about := site_readme_documents(readme_text)
	sources := make([dynamic]string, context.temp_allocator)
	// First the documents in the order of the table of README.md, then the others.
	section, _ := site_section_lines(site_lines(readme_text), "## Documents")
	for line in section {
		cells := site_table_row_cells(line)
		if len(cells) >= 2 && strings.has_prefix(cells[0], "`docs/") {
			path := strings.trim(cells[0], "`")
			if page, found := site.documents[path]; found && page != site_page_file(SITE_GLOSSARY_FOLDER) && strings.has_suffix(path, ".md") {
				append(&sources, path)
			}
		}
	}
	others := make([dynamic]string, context.temp_allocator)
	for path, page in site.documents {
		if !strings.has_prefix(path, "docs/") || page == site_page_file(SITE_GLOSSARY_FOLDER) {
			continue
		}
		listed := false
		for source in sources {
			listed ||= source == path
		}
		if !listed {
			append(&others, path)
		}
	}
	// The order of a map is not stable: the order of the names is.
	slice.sort(others[:])
	append(&sources, ..others[:])
	for source in sources {
		content := site_read(source) or_return
		title := site_document_title(content)
		if title == "" {
			fmt.eprintfln("kerneltool: site: %s has no title \"# <title>\"", source)
			return false
		}
		// The docs home shows each guide with one line that says what it holds.
		if about[source] == "" {
			fmt.eprintfln("kerneltool: site: %s has no row in the table \"## Documents\" of %s: a guide needs its one line of description", source, SITE_README_FILE)
			return false
		}
		append(&site.guides, Site_Guide{source = source, path = site.documents[source], title = title, about = about[source]})
	}
	// The headings of every guide before any guide is written: a guide
	// refers to a heading of a guide that comes after it, and the id of a
	// heading is the one that the renderer gives. This first pass keeps the
	// headings only, and takes back what it recorded.
	not_rendered_count := len(site.not_rendered)
	names_without_card := site.type_names_without_card
	blocks_not_colored, first_block_not_colored := site.code_blocks_not_colored, site.first_code_block_not_colored
	declaration_spans := site.declaration_spans
	site.document_headings_pending = true
	for guide, index in site.guides {
		content := site_read(guide.source) or_return
		heading_renderer := site_renderer_make(site, guide.path, guide.source)
		site_render_markdown(&heading_renderer, content)
		site.guides[index].headings = heading_renderer.headings[:]
		site.guides[index].items = heading_renderer.items[:]
	}
	site.document_headings_pending = false
	for len(site.not_rendered) > not_rendered_count {
		pop(&site.not_rendered)
	}
	site.type_names_without_card = names_without_card
	site.code_blocks_not_colored, site.first_code_block_not_colored = blocks_not_colored, first_block_not_colored
	site.declaration_spans = declaration_spans
	for guide, index in site.guides {
		content := site_read(guide.source) or_return
		renderer := site_renderer_make(site, guide.path, guide.source)
		site_render_markdown(&renderer, content)
		site.guides[index].headings = renderer.headings[:]
		site.guides[index].items = renderer.items[:]
		b := strings.builder_make(context.temp_allocator)
		// The headings of the guide are in the list "On this page" of the frame.
		strings.write_string(&b, "<article class=\"prose\">\n")
		strings.write_string(&b, strings.to_string(renderer.builder))
		strings.write_string(&b, "</article>\n<nav class=\"neighbours\" aria-label=\"Other guides\">\n")
		if index > 0 {
			previous := site.guides[index - 1]
			fmt.sbprintf(&b, "<a rel=\"prev\" href=\"%s\">Previous: ", site_page_link(site, guide.path, previous.path))
			site_escape(&b, previous.title)
			strings.write_string(&b, "</a>\n")
		}
		if index + 1 < len(site.guides) {
			next := site.guides[index + 1]
			fmt.sbprintf(&b, "<a rel=\"next\" href=\"%s\">Next: ", site_page_link(site, guide.path, next.path))
			site_escape(&b, next.title)
			strings.write_string(&b, "</a>\n")
		}
		strings.write_string(&b, "</nav>\n")
		description := site_document_description(content)
		if description == "" {
			description = site_description_cut(strings.concatenate({"The guide \"", guide.title, "\" of ", SITE_SYSTEM_NAME, "."}, context.temp_allocator))
		}
		site_page_add(site, Site_Page{path = guide.path, title = guide.title, description = description, section = .Guides, crumbs = site_crumbs(.Guides), body = strings.to_string(b), sources = site_sources(guide.source), layout = .Documentation})
	}

	// The index of the guides.
	guides_page := site_section_page(.Guides)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "<h1>Guides</h1>\n<p>The documents of the repository: how each part of the system is designed, and why. The tables of what exists are in the <a href=\"%s\">reference</a>.</p>\n", site_page_link(site, guides_page, site_section_page(.Reference)))
	guides_table := site_table_start(&b, "Guides", {{"Guide", .Prose}, {"What it holds", .Prose}, {"File", .Name}}, {.None, .None, .File})
	for guide in site.guides {
		fmt.sbprintf(&b, "<tr><td><a href=\"%s\">", site_page_link(site, guides_page, guide.path))
		site_escape(&b, guide.title)
		strings.write_string(&b, "</a></td>")
		site_cell(&b, guide.about)
		site_cell(&b, strings.concatenate({"`", guide.source, "`"}, context.temp_allocator), "code")
		strings.write_string(&b, "</tr>\n")
	}
	site_table_end(&b, guides_table)
	site_source_line(site, &b, SITE_README_FILE)
	site_page_add(site, Site_Page{path = guides_page, is_index = true, title = "Guides", description = site_description_cut(fmt.tprintf("The %d documents of %s: how each part of the system is designed, and why.", len(site.guides), SITE_SYSTEM_NAME)), section = .Guides, crumbs = site_crumbs(.Docs), body = strings.to_string(b), sources = site_sources(SITE_README_FILE), layout = .Documentation})
	return true
}

// site_crumbs gives the breadcrumbs of a page below a section: the home,
// then each section above it down to the section itself (Home / Docs /
// Guides for a guide).
site_crumbs :: proc(section: Site_Section) -> []Site_Crumb {
	chain := make([dynamic]Site_Section, context.temp_allocator)
	for current := section; current != .Home; current = site_section_parents[current] {
		append(&chain, current)
	}
	crumbs := make([dynamic]Site_Crumb, context.temp_allocator)
	append(&crumbs, Site_Crumb{title = site_section_titles[.Home], path = site_section_page(.Home)})
	for index := len(chain) - 1; index >= 0; index -= 1 {
		append(&crumbs, Site_Crumb{title = site_section_titles[chain[index]], path = site_section_page(chain[index])})
	}
	return crumbs[:]
}

site_sources :: proc(sources: ..string) -> []string {
	list := make([]string, len(sources), context.temp_allocator)
	copy(list, sources)
	return list
}

site_reference_add :: proc(site: ^Site) -> bool {
	entries := make([dynamic]Site_Reference_Entry, context.temp_allocator)

	// The glossary.
	{
		glossary_page := site_page_file(SITE_GLOSSARY_FOLDER)
		renderer := site_renderer_make(site, glossary_page, SITE_GLOSSARY_FILE)
		renderer.glossary = true
		site_glossary_write(&renderer, site.glossary)
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "<article class=\"prose\">\n")
		fmt.sbprintf(&b, "<h1 id=\"%s\">", site_slug(site.glossary.title))
		site_escape(&b, site.glossary.title)
		strings.write_string(&b, "</h1>\n")
		strings.write_string(&b, strings.to_string(renderer.builder))
		strings.write_string(&b, "</article>\n")
		title := site.glossary.title
		term_count := len(glossary_terms_in_order(site.glossary))
		site_page_add(site, Site_Page{path = glossary_page, title = title, description = site_description_cut(fmt.tprintf("The %d terms of %s: one term for each concept, with its definition, what it is for, how it differs from the word of other systems, and the words that it replaces.", term_count, SITE_SYSTEM_NAME)), section = .Reference, crumbs = site_crumbs(.Reference), body = strings.to_string(b), sources = site_sources(SITE_GLOSSARY_FILE), layout = .Documentation})
		append(&entries, Site_Reference_Entry{path = glossary_page, title = title, what = "Each term of the project: its definition, what it is for, and how it works. A term on another page links here.", source = SITE_GLOSSARY_FILE, count = term_count, kind = .Term})
	}

	// The commands of the tool.
	{
		path := site_page_file(SITE_COMMANDS_FOLDER)
		b := strings.builder_make(context.temp_allocator)
		commands := COMMANDS
		main_text, _ := site_read_quiet(SITE_TOOL_MAIN_FILE)
		main_lines := site_lines(main_text)
		fmt.sbprintf(&b, "<h1>Commands of kerneltool</h1>\n<p>All the automation of the project is one program, <code>kerneltool</code>. Run a command with <code>nix develop -c kerneltool &lt;command&gt;</code>. %d commands.</p>\n<p>The table names each command; under it, each command has its text, as <code>COMMANDS</code> writes it, and a link to its line.</p>\n", len(commands))
		site_source_line(site, &b, SITE_TOOL_MAIN_FILE)
		commands_table := site_table_start(&b, "Commands of kerneltool", {{"Command", .Name}, {"What it does", .Prose}}, {.Command, .None})
		for command in commands {
			fmt.sbprintf(&b, "<tr><td class=\"code name\"><a href=\"#tool-command-%s\"><code>", site_slug(command.name))
			site_escape(&b, command.name)
			strings.write_string(&b, "</code></a></td>")
			site_cell(&b, command.about)
			strings.write_string(&b, "</tr>\n")
		}
		site_table_end(&b, commands_table)
		strings.write_string(&b, "<h2 id=\"each-command\">Each command</h2>\n")
		for command in commands {
			// The line of the command in the table COMMANDS: the link to its source.
			wanted := strings.concatenate({"{name = \"", command.name, "\","}, context.temp_allocator)
			line := 0
			for text, index in main_lines {
				if strings.has_prefix(strings.trim_space(text), wanted) {
					line = index + 1
					break
				}
			}
			site_symbol_write(site, &b, Site_Symbol{id = strings.concatenate({"tool-command-", site_slug(command.name)}, context.temp_allocator), name = command.name, signature = strings.concatenate({"nix develop -c kerneltool ", command.name}, context.temp_allocator), description = command.about, page = path, source = SITE_TOOL_MAIN_FILE, line = line})
		}
		site_page_add(site, Site_Page{path = path, title = "Commands of kerneltool", description = site_description_cut(fmt.tprintf("The %d commands of kerneltool, the one tool of the project: the build, the machine tests, the pictures, the changelog and the site.", len(commands))), section = .Reference, crumbs = site_crumbs(.Reference), body = strings.to_string(b), sources = site_sources(SITE_TOOL_MAIN_FILE), layout = .Documentation})
		append(&entries, Site_Reference_Entry{path = path, title = "Commands of kerneltool", what = "Each command of the tool of the project, with what it does.", source = SITE_TOOL_MAIN_FILE, count = len(commands), kind = .Command})
	}

	// The measured numbers.
	{
		path := site_page_file(SITE_NUMBERS_FOLDER)
		site_page_add(site, Site_Page{path = path, title = "Measured numbers", description = site_description_cut(fmt.tprintf("%d numbers that the machine tests of %s printed, each quoted whole from its log with its conditions.", len(site.measured), SITE_SYSTEM_NAME)), section = .Reference, crumbs = site_crumbs(.Reference), body = site_numbers_body(site), sources = site_sources("tools/kerneltool/site.odin"), layout = .Documentation})
		append(&entries, Site_Reference_Entry{path = path, title = "Measured numbers", what = "Each number that the machine tests print, with its log and its conditions.", source = MEASURE_RECORD_FILE, count = len(site.measured), kind = .Number})
	}

	// The licenses.
	{
		path := site_page_file(SITE_LICENSES_FOLDER)
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "<h1>Licenses</h1>\n<p>The license of the system, and of each part that it holds or uses. A cell with no source in the repository says \"" + SITE_NOT_RECORDED + "\".</p>\n<h2 id=\"system\">What the system holds</h2>\n")
		system_ids, build_ids := site_license_row_ids(site.licenses)
		site_license_table(site, &b, "What the system holds", site.licenses.system_rows, system_ids)
		strings.write_string(&b, "<h2 id=\"build\">Used to build and test, not a part of the system</h2>\n")
		site_license_table(site, &b, "What builds and tests it", site.licenses.build_rows, build_ids)
		site_source_line(site, &b, SITE_LICENSE_FILE, SITE_FONT_FOLDER, SITE_SPLEEN_LICENSE_FILE, SITE_POSY_MANIFEST, SITE_SYSTEM_POINTER_MANIFEST, SITE_ODIN_LICENSE_FILE, SITE_FIAT_LICENSE_FILE, CRYPTOGRAPHY_MANIFEST, SITE_PORTRAIT_LICENSE_FILE, SITE_FLAKE_FILE, SITE_FLAKE_LOCK_FILE)
		site_page_add(site, Site_Page{path = path, title = "Licenses", description = site_description_cut(fmt.tprintf("The license of %s and of each part that it holds or uses: %d rows, and %d tools that build and test it.", SITE_SYSTEM_NAME, len(site.licenses.system_rows), len(site.licenses.build_rows))), section = .Reference, crumbs = site_crumbs(.Reference), body = strings.to_string(b), sources = site_sources(SITE_LICENSE_FILE, SITE_FLAKE_FILE), layout = .Documentation})
		append(&entries, Site_Reference_Entry{path = path, title = "Licenses", what = "The license, the author, the version and the place of each part of the system and of each tool of its build.", source = SITE_FLAKE_FILE, count = len(site.licenses.system_rows) + len(site.licenses.build_rows), kind = .Grant})
	}

	// The tables generated from the code, and the pages of the modules.
	site_generated_tables_add(site, &entries)

	// The index of the reference.
	reference_page := site_section_page(.Reference)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<h1>Reference</h1>\n<p>Tables that the tool generates from the code and the files that define each thing. The guides explain why; these tables say what exists in this build.</p>\n")
	reference_table := site_table_start(&b, "Reference tables", {{"Table", .Prose}, {"What it holds", .Prose}, {"Generated from", .Name}}, {.None, .None, .File})
	for entry in entries {
		fmt.sbprintf(&b, "<tr><td><a href=\"%s\">", site_page_link(site, reference_page, entry.path))
		site_escape(&b, entry.title)
		strings.write_string(&b, "</a></td>")
		site_cell(&b, entry.what)
		site_cell(&b, strings.concatenate({"`", entry.source, "`"}, context.temp_allocator), "code")
		strings.write_string(&b, "</tr>\n")
	}
	site_table_end(&b, reference_table)
	// The legend of the kinds of values that the reference shows.
	site_value_legend(&b)
	site_page_add(site, Site_Page{path = reference_page, is_index = true, title = "Reference", description = site_description_cut(fmt.tprintf("The reference of %s: %d tables that the tool generates from the code and the files of the repository.", SITE_SYSTEM_NAME, len(entries))), section = .Reference, crumbs = site_crumbs(.Docs), body = strings.to_string(b), layout = .Documentation})
	// The tree of the documentation lists the reference pages in this order.
	site.reference_entries = entries[:]
	return true
}

// site_numbers_run writes the first paragraphs of the page of the numbers:
// the run of the measure record (its time, its commit, its host), a release
// of the site that is newer than the record, and the numbers that come
// from build/.
site_numbers_run :: proc(site: ^Site, b: ^strings.Builder) {
	from_build := 0
	for number in site.measured {
		from_build += number.source == .Build ? 1 : 0
	}
	if !site.measure_record.present {
		fmt.sbprintf(b, "<p class=\"missing\">The repository holds no measure record (<code>%s</code>): only the logs in <code>%s/</code> of this work tree give numbers.</p>\n", MEASURE_RECORD_FILE, BUILD_FOLDER)
	} else {
		record := site.measure_record.record
		strings.write_string(b, "<p>The full check of ")
		site_time(b, record.time)
		strings.write_string(b, ", on the tree of ")
		if record.commit != "" {
			fmt.sbprintf(b, "<a href=\"%s/commit/%s\"><code>", SITE_REPOSITORY_ADDRESS, record.commit)
			site_escape(b, site_short_commit(record.commit))
			strings.write_string(b, "</code></a>")
		} else {
			site_escape(b, site_short_commit(record.commit))
		}
		strings.write_string(b, " ")
		site_escape(b, site_tree_words(record.tree))
		strings.write_string(b, ", the release ")
		site_escape(b, record.release)
		strings.write_string(b, ". The host: ")
		site_escape(b, record.host)
		fmt.sbprintf(b, ". %d checks passed. The record is <code>%s</code>.</p>\n", record.checks_passed, MEASURE_RECORD_FILE)
		if record.release != site.release {
			strings.write_string(b, "<p class=\"missing\">The measure record is of the release ")
			site_escape(b, record.release)
			strings.write_string(b, ". This site shows the release ")
			site_escape(b, site.release)
			strings.write_string(b, ": the numbers were measured before this release.</p>\n")
		}
	}
	if from_build > 0 {
		fmt.sbprintf(b, "<p>%d numbers come from the logs in <code>%s/</code> of this work tree, which are newer than the measure record.</p>\n", from_build, BUILD_FOLDER)
	}
}

// site_numbers_body writes the page of the measured numbers.
site_numbers_body :: proc(site: ^Site) -> string {
	b := strings.builder_make(context.temp_allocator)
	measured_count := 0
	for number in site.measured {
		measured_count += number.found ? 1 : 0
	}
	strings.write_string(&b, "<h1>Measured numbers</h1>\n")
	site_numbers_run(site, &b)
	fmt.sbprintf(&b, "<p>Each row is a line that a program of the system printed in the log of a machine test, quoted whole: the line gives its own conditions. A machine runs under QEMU on the host that ran the test: each number is one run on that host. %d of %d numbers are measured.</p>\n", measured_count, len(site.measured))
	numbers_table := site_table_start(&b, "Measured numbers", site_numbers_columns[:])
	number_ids := make(map[string]bool, context.temp_allocator)
	for number in site.measured {
		// Each row is a link target, and a symbol of "On this page".
		wanted := strings.concatenate({"number-", site_slug(number.measure.sentence)}, context.temp_allocator)
		id := wanted
		for suffix := 2; (id in number_ids); suffix += 1 {
			id = fmt.tprintf("%s-%d", wanted, suffix)
		}
		number_ids[id] = true
		fmt.sbprintf(&b, "<tr id=\"%s\" data-outline=\"", id)
		site_plain(&b, number.measure.sentence)
		strings.write_string(&b, "\">")
		site_cell(&b, number.measure.sentence)
		if !number.found {
			strings.write_string(&b, "<td class=\"missing\">" + SITE_NOT_MEASURED + "</td><td class=\"missing\">")
			site_escape(&b, number.missing)
			strings.write_string(&b, "</td><td></td></tr>\n")
			continue
		}
		strings.write_string(&b, "<td class=\"code\"><code>")
		site_escape(&b, number.text)
		strings.write_string(&b, "</code></td><td><code>")
		site_escape(&b, number.path)
		fmt.sbprintf(&b, "</code>, line %d", number.line_number)
		if number.matching_lines > 1 {
			which: string = number.measure.choice == .Last ? "last" : "first"
			fmt.sbprintf(&b, " (the %s of %d lines with this text)", which, number.matching_lines)
		}
		strings.write_string(&b, ". ")
		if number.conditions != "" {
			site_inline(&b, number.conditions)
			strings.write_string(&b, ". ")
		}
		site_inline(&b, site_origin_words(number.source, site.measure_record))
		strings.write_string(&b, ".</td><td class=\"code\">")
		site_time(&b, number.written)
		strings.write_string(&b, "</td></tr>\n")
	}
	site_table_end(&b, numbers_table)
	fmt.sbprintf(&b, "<p class=\"source\">The lines come from the measure record <code>%s</code>, which <code>kerneltool screenshots</code> writes after a full check that passed, or from the logs in <code>%s/</code> that a later <code>kerneltool test</code> or <code>kerneltool measure</code> wrote; the list of the numbers is <code>site_measures</code> in ", MEASURE_RECORD_FILE, BUILD_FOLDER)
	strings.write_string(&b, "<a href=\"")
	site_escape(&b, site_repository_file(site, "tools/kerneltool/site.odin"))
	strings.write_string(&b, "\"><code>tools/kerneltool/site.odin</code></a>.</p>\n")
	return strings.to_string(b)
}

// site_license_row_ids gives the id of each row of the two tables of
// licenses: "license-" and the slug of what the row is, with "-2", "-3"
// for a slug that an earlier row has. The page and the search index take
// the ids from here.
site_license_row_ids :: proc(licenses: Site_Licenses) -> (system_ids: []string, build_ids: []string) {
	taken := make(map[string]bool, context.temp_allocator)
	ids_of :: proc(rows: []Site_License_Row, used: ^map[string]bool) -> []string {
		ids := make([]string, len(rows), context.temp_allocator)
		for row, index in rows {
			wanted := strings.concatenate({"license-", site_slug(row.what)}, context.temp_allocator)
			id := wanted
			for number := 2; (id in used^); number += 1 {
				id = fmt.tprintf("%s-%d", wanted, number)
			}
			used^[id] = true
			ids[index] = id
		}
		return ids
	}
	return ids_of(licenses.system_rows, &taken), ids_of(licenses.build_rows, &taken)
}

// site_license_table writes the rows of one table of licenses.
site_license_table :: proc(site: ^Site, b: ^strings.Builder, name: string, rows: []Site_License_Row, ids: []string) {
	licenses_table := site_table_start(b, name, {{"What", .Prose}, {"Where", .Name}, {"License", .Short}, {"Author or origin", .Prose}, {"Version or pin", .Short}, {"In the boot image", .Short}}, {.None, .File, .None, .None, .Version, .None})
	for row, index in rows {
		fmt.sbprintf(b, "<tr id=\"%s\" data-outline=\"", ids[index])
		site_plain(b, row.what)
		strings.write_string(b, "\">")
		site_cell(b, row.what)
		if row.place != "" {
			strings.write_string(b, "<td class=\"code name\"><a href=\"")
			site_escape(b, site_repository_file(site, row.place))
			strings.write_string(b, "\"><code>")
			site_escape(b, row.place)
			strings.write_string(b, "</code></a></td>")
		} else {
			strings.write_string(b, "<td></td>")
		}
		site_cell(b, row.license, row.license == SITE_NOT_RECORDED ? "missing" : "code")
		strings.write_string(b, "<td>")
		site_escape(b, row.author)
		if row.author_address != "" {
			strings.write_string(b, " <a href=\"")
			site_escape(b, row.author_address)
			strings.write_string(b, "\">")
			site_escape(b, row.author_address)
			strings.write_string(b, "</a>")
		}
		strings.write_string(b, "</td>")
		site_cell(b, row.version, row.version == SITE_NOT_RECORDED ? "missing" : "code")
		site_cell(b, row.in_boot_image, row.in_boot_image == SITE_NOT_RECORDED ? "missing" : "")
		strings.write_string(b, "</tr>\n")
	}
	site_table_end(b, licenses_table)
}

site_releases_add :: proc(site: ^Site) {
	path := site_section_page(.Releases)
	b := strings.builder_make(context.temp_allocator)
	types := CHANGE_TYPES
	releases := site.changelog.releases
	oldest := release_number_text(releases[len(releases) - 1].number)
	fmt.sbprintf(&b, "<h1>Releases</h1>\n<p>Every release of the system, newest first: %d releases, from %s to %s. The merge of step N on <code>master</code> is the release 0.N.0.</p>\n", len(releases), oldest, site.release)
	site_source_line(site, &b, CHANGELOG_FILE)
	for changelog_release in releases {
		number := release_number_text(changelog_release.number)
		fmt.sbprintf(&b, "<section class=\"release\">\n<h2 id=\"%s\">%s <span class=\"date\">%s</span></h2>\n", site_release_id(number), number, changelog_release.date)
		site_news_of_release(site, &b, path, number)
		type_index := -1
		for entry in changelog_release.entries {
			if entry.type_index != type_index {
				if type_index >= 0 {
					strings.write_string(&b, "</ul>\n")
				}
				type_index = entry.type_index
				fmt.sbprintf(&b, "<h3>%s</h3>\n<ul>\n", types[type_index])
			}
			strings.write_string(&b, "<li>")
			site_inline(&b, entry_joined(entry.lines))
			strings.write_string(&b, "</li>\n")
		}
		if type_index >= 0 {
			strings.write_string(&b, "</ul>\n")
		}
		strings.write_string(&b, "</section>\n")
	}
	site_page_add(site, Site_Page{path = path, title = "Releases", description = site_description_cut(fmt.tprintf("Every release of %s, newest first: %d releases, from %s to %s, with what each one brings.", SITE_SYSTEM_NAME, len(releases), oldest, site.release)), section = .Releases, crumbs = site_crumbs(.Home), body = strings.to_string(b), sources = site_sources(CHANGELOG_FILE)})
}

// One stage of the start of the machine, as the kernel logs it:
// "kernel: boot: <who>: <what>: <microseconds> us".
Site_Boot_Stage :: struct {
	who:          string,
	what:         string,
	microseconds: int,
}

// site_boot_stages reads the stages of the start from the log of the main
// machine test. The form: lines "kernel: boot: <who>: <what>: <n> us", or
// "kernel: boot: firmware: <n> us" for the firmware.
site_boot_stages :: proc(content: string) -> []Site_Boot_Stage {
	stages := make([dynamic]Site_Boot_Stage, context.temp_allocator)
	for line in site_lines(content) {
		if !strings.has_prefix(line, SITE_BOOT_STAGE_PREFIX) || !strings.has_suffix(line, " us") {
			continue
		}
		rest := line[len(SITE_BOOT_STAGE_PREFIX):len(line) - len(" us")]
		last := strings.last_index(rest, ": ")
		if last < 0 {
			continue
		}
		value := site_digits_value(rest[last + 2:])
		if value < 0 {
			continue
		}
		stage := Site_Boot_Stage{microseconds = value}
		head := rest[:last]
		if first := strings.index(head, ": "); first >= 0 {
			stage.who = head[:first]
			stage.what = head[first + 2:]
		} else {
			stage.who = head
		}
		append(&stages, stage)
	}
	return stages[:]
}

// site_who_class gives the class of the color of the concept of a stage:
// the colors of the boot display.
site_who_class :: proc(who: string) -> string {
	switch who {
	case "firmware":
		return "accent-firmware"
	case "boot program":
		return "accent-boot"
	}
	return "accent-kernel"
}

// site_home_head writes the head of the home: the mark with the name, the
// tagline (one line: the first sentence of the lead of README.md) and the
// links to the sections. The rest of the lead is not in the head.
site_home_head :: proc(site: ^Site, b: ^strings.Builder) {
	home_picture: Site_Mark_Picture
	for picture in site_mark_pictures {
		if picture.file_name == SITE_MARK_HOME {
			home_picture = picture
		}
	}
	width, height := site_mark_size(home_picture)
	strings.write_string(b, "<header class=\"home-head\">\n<picture>")
	fmt.sbprintf(b, "<source media=\"(prefers-color-scheme: light)\" srcset=\"%s/%s\">", SITE_PICTURE_FOLDER, SITE_MARK_HOME_LIGHT)
	fmt.sbprintf(b, "<img class=\"mark\" src=\"%s/%s\" width=\"%d\" height=\"%d\" alt=\"", SITE_PICTURE_FOLDER, SITE_MARK_HOME, width, height)
	site_plain(b, site.readme.mark_description)
	strings.write_string(b, "\"></picture>\n<div>\n<h1>" + SITE_SYSTEM_NAME + "</h1>\n<p class=\"lead\">")
	site_inline(b, site.readme.tagline)
	strings.write_string(b, "</p>\n<ul class=\"doors\">\n")
	for section in Site_Section {
		if !site_section_in_bar(section) || !site_page_exists(site, site_section_page(section)) {
			continue
		}
		fmt.sbprintf(b, "<li><a href=\"%s\">%s</a></li>\n", site_page_link(site, site_section_page(.Home), site_section_page(section)), site_section_titles[section])
	}
	fmt.sbprintf(b, "<li><a href=\"%s\">The repository</a></li>\n", SITE_REPOSITORY_ADDRESS)
	strings.write_string(b, "</ul>\n</div>\n</header>\n")
}

// site_home_explanation writes the rest of the lead of README.md, after the
// tagline, as a short section of its own: lower than the head, so that the
// first screen of a phone holds the mark, the name, the tagline and the
// links only.
site_home_explanation :: proc(site: ^Site, b: ^strings.Builder) {
	if site.readme.explanation == "" {
		return
	}
	strings.write_string(b, "<section aria-labelledby=\"about\">\n<h2 id=\"about\">What it is</h2>\n<p>")
	site_inline(b, site.readme.explanation)
	strings.write_string(b, "</p>\n</section>\n")
}

site_home_add :: proc(site: ^Site) {
	home := site_section_page(.Home)
	b := strings.builder_make(context.temp_allocator)
	site_home_head(site, &b)

	// What runs: the newest news, the start, the tiles of the boot image and
	// the numbers. Each part comes from a file or a log; the home adds no
	// sentence of its own about the state of the system. The explanation of
	// the lead comes after the news.
	site_news_home(site, &b)
	site_home_explanation(site, &b)

	// The path from power to the desktop: the stages that the kernel logged.
	stages := site.boot_stages
	strings.write_string(&b, "<section class=\"card accent-kernel\" aria-labelledby=\"start\">\n<h2 id=\"start\">The start of the machine</h2>\n")
	if len(stages) == 0 {
		strings.write_string(&b, "<p class=\"missing\">" + SITE_NOT_MEASURED + "</p>\n")
	} else {
		strings.write_string(&b, "<ol class=\"stages\">\n")
		for stage in stages {
			fmt.sbprintf(&b, "<li class=\"%s\"><span class=\"who\">", site_who_class(stage.who))
			site_escape(&b, stage.who)
			strings.write_string(&b, "</span> <span class=\"what\">")
			site_escape(&b, stage.what)
			fmt.sbprintf(&b, "</span> <span class=\"time\">%d.%d ms</span></li>\n", stage.microseconds / 1000, stage.microseconds % 1000 / 100)
		}
		strings.write_string(&b, "</ol>\n")
		fmt.sbprintf(&b, "<p class=\"source\">The lines \"kernel: boot: ...\" of <code>%s</code>, one run of the main machine test under QEMU. ", TEST_OUTPUT)
		site_inline(&b, site_origin_words(site.boot_source, site.measure_record))
		strings.write_string(&b, ".</p>\n")
	}
	strings.write_string(&b, "</section>\n")

	// The modules of the boot image, as tiles: each a link to its page.
	site_tiles_write(site, &b, home)

	// A few numbers: the first three that this build measured.
	strings.write_string(&b, "<h2 id=\"numbers\">Measured</h2>\n<div class=\"measures\">\n")
	shown := 0
	for number in site.measured {
		if !number.found || shown == 3 {
			continue
		}
		shown += 1
		fmt.sbprintf(&b, "<article class=\"card measure %s\">\n<h3>", site_accent_class(number.measure.accent))
		site_inline(&b, number.measure.sentence)
		strings.write_string(&b, "</h3>\n<p class=\"line\"><code>")
		site_escape(&b, number.text)
		strings.write_string(&b, "</code></p>\n</article>\n")
	}
	fmt.sbprintf(&b, "</div>\n<p><a href=\"%s\">Every measured number, with its log and its conditions</a></p>\n", site_page_link(site, home, site_page_file(SITE_NUMBERS_FOLDER)))

	// The pictures of the machine, in their groups.
	strings.write_string(&b, "<h2 id=\"pictures\">The machine</h2>\n<p class=\"source\">Pictures of the screen that the machine test takes under QEMU; the captions are those of <code>README.md</code>. A picture opens at full size.</p>\n")
	group_start := 0
	for group_start < len(site.figures) {
		group_end := group_start + 1
		for group_end < len(site.figures) && site.figures[group_end].group == site.figures[group_start].group {
			group_end += 1
		}
		group := site.figures[group_start:group_end]
		strings.write_string(&b, "<h3>")
		site_escape(&b, group[0].group)
		strings.write_string(&b, "</h3>\n<div class=\"pictures\">\n")
		for figure, index in group {
			wide := index == 0 && len(group) % 2 == 1
			site_path := strings.concatenate({SITE_PICTURE_FOLDER, "/", figure.file_name}, context.temp_allocator)
			strings.write_string(&b, wide ? "<figure class=\"wide\">" : "<figure>")
			fmt.sbprintf(&b, "<a href=\"%s\"><img src=\"%s\" width=\"%d\" height=\"%d\" loading=\"lazy\" decoding=\"async\" alt=\"", site_path, site_path, figure.width, figure.height)
			site_plain(&b, figure.caption)
			// The caption is the alt text: a screen reader reads it there once.
			strings.write_string(&b, "\"></a>\n<figcaption aria-hidden=\"true\">")
			site_inline(&b, figure.caption)
			strings.write_string(&b, "</figcaption></figure>\n")
		}
		strings.write_string(&b, "</div>\n")
		group_start = group_end
	}

	// The newest release.
	newest := site.changelog.releases[0]
	fmt.sbprintf(&b, "<h2 id=\"release\">The newest release</h2>\n<p><a href=\"%s#%s\">%s</a>, %s: %d changes. ", site_page_link(site, home, site_section_page(.Releases)), site_release_id(site.release), site.release, newest.date, len(newest.entries))
	fmt.sbprintf(&b, "%d steps so far; each step is one tested commit on <code>master</code>.</p>\n", site.step_count)
	site_page_add(site, Site_Page{path = home, is_index = true, title = SITE_SYSTEM_NAME, description = site_description_cut(site.readme.lead), section = .Home, body = strings.to_string(b), sources = site_sources(SITE_README_FILE, CHANGELOG_FILE)})
}

// site_read_quiet reads a file that can be absent, with no message.
site_read_quiet :: proc(path: string) -> (text: string, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return string(data), err == nil
}
