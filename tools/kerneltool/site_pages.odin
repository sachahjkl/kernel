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

// A table that the reference shows: its file and its title, for its
// line in the index of the reference.
Site_Reference_Entry :: struct {
	path:   string,
	title:  string,
	what:   string,
	source: string,
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
	Any, // A column of a table of a document, whose kind the tool does not know.
}

site_column_classes := [Site_Column_Kind]string {
	.Name   = "column-name",
	.Short  = "column-short",
	.Prose  = "column-prose",
	.Line   = "column-line",
	.Date   = "column-date",
	.Number = "column-number",
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
	start: int,
	kinds: []Site_Column_Kind,
}

// site_table_start writes the start of a table: its box, which scrolls
// sideways when the table is wider than the page and which the keyboard
// reaches (a region named by the name of the table), and its header cells,
// each with the class of the kind of its column.
site_table_start :: proc(b: ^strings.Builder, name: string, columns: []Site_Column) -> Site_Table {
	table := Site_Table{start = strings.builder_len(b^), kinds = make([]Site_Column_Kind, len(columns), context.temp_allocator)}
	strings.write_string(b, "<div class=\"table\" role=\"region\" tabindex=\"0\" aria-label=\"")
	site_escape(b, name)
	strings.write_string(b, "\"><table>\n<thead><tr>")
	for column, index in columns {
		table.kinds[index] = column.kind
		fmt.sbprintf(b, "<th scope=\"col\" class=\"%s\">", site_column_classes[column.kind])
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
	strings.write_string(b, site_table_cells_classed(body, table.kinds))
}

// site_table_cells_classed gives the body of a table with the class of its
// column on each cell: the column of a cell is its place in its row. The
// text of a cell is escaped, so a "<td" is always a tag.
site_table_cells_classed :: proc(body: string, kinds: []Site_Column_Kind) -> string {
	out := strings.builder_make(context.temp_allocator)
	column := 0
	index := 0
	for index < len(body) {
		rest := body[index:]
		if strings.has_prefix(rest, "<tr") && len(rest) > 3 && (rest[3] == '>' || rest[3] == ' ') {
			column = 0
		} else if (strings.has_prefix(rest, "<td") || strings.has_prefix(rest, "<th")) && len(rest) > 3 && (rest[3] == '>' || rest[3] == ' ') {
			class := column < len(kinds) ? site_column_classes[kinds[column]] : ""
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
		append(&site.guides, Site_Guide{source = source, path = site.documents[source], title = title, about = about[source]})
	}
	for guide, index in site.guides {
		content := site_read(guide.source) or_return
		renderer := site_renderer_make(site, guide.path, guide.source)
		site_render_markdown(&renderer, content)
		site.guides[index].headings = renderer.headings[:]
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "<div class=\"guide\">\n")
		strings.write_string(&b, site_table_of_contents(&renderer))
		strings.write_string(&b, "<article class=\"prose\">\n")
		strings.write_string(&b, strings.to_string(renderer.builder))
		strings.write_string(&b, "</article>\n</div>\n<nav class=\"neighbours\" aria-label=\"Other guides\">\n")
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
		site_page_add(site, Site_Page{path = guide.path, title = guide.title, description = description, section = .Guides, crumbs = site_crumbs(.Guides), body = strings.to_string(b), sources = site_sources(guide.source)})
	}

	// The index of the guides.
	guides_page := site_section_page(.Guides)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "<h1>Guides</h1>\n<p>The documents of the repository: how each part of the system is designed, and why. The tables of what exists are in the <a href=\"%s\">reference</a>.</p>\n", site_page_link(site, guides_page, site_section_page(.Reference)))
	guides_table := site_table_start(&b, "Guides", {{"Guide", .Prose}, {"What it holds", .Prose}, {"File", .Name}})
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
	site_page_add(site, Site_Page{path = guides_page, is_index = true, title = "Guides", description = site_description_cut(fmt.tprintf("The %d documents of %s: how each part of the system is designed, and why.", len(site.guides), SITE_SYSTEM_NAME)), section = .Guides, crumbs = site_crumbs(.Home), body = strings.to_string(b), sources = site_sources(SITE_README_FILE)})
	return true
}

// site_crumbs gives the breadcrumbs of a page below a section: the home,
// then the page of the section when it is not the home.
site_crumbs :: proc(section: Site_Section) -> []Site_Crumb {
	crumbs := make([dynamic]Site_Crumb, context.temp_allocator)
	append(&crumbs, Site_Crumb{title = site_section_titles[.Home], path = site_section_page(.Home)})
	if section != .Home {
		append(&crumbs, Site_Crumb{title = site_section_titles[section], path = site_section_page(section)})
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
		content := site_read("docs/GLOSSARY.md") or_return
		glossary_page := site_page_file(SITE_GLOSSARY_FOLDER)
		renderer := site_renderer_make(site, glossary_page, "docs/GLOSSARY.md")
		renderer.glossary = true
		site_render_markdown(&renderer, content)
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "<div class=\"guide\">\n")
		strings.write_string(&b, site_table_of_contents(&renderer))
		strings.write_string(&b, "<article class=\"prose wide\">\n")
		strings.write_string(&b, strings.to_string(renderer.builder))
		strings.write_string(&b, "</article>\n</div>\n")
		title := site_document_title(content)
		site_page_add(site, Site_Page{path = glossary_page, title = title, description = site_description_cut(fmt.tprintf("The %d terms of %s: one term for each concept, with its definition and the words that it replaces.", len(site.terms), SITE_SYSTEM_NAME)), section = .Reference, crumbs = site_crumbs(.Reference), body = strings.to_string(b), sources = site_sources("docs/GLOSSARY.md")})
		append(&entries, Site_Reference_Entry{path = glossary_page, title = title, what = "Each term of the project, with its definition. A term on another page links here.", source = "docs/GLOSSARY.md"})
	}

	// The commands of the tool.
	{
		path := site_page_file(SITE_COMMANDS_FOLDER)
		b := strings.builder_make(context.temp_allocator)
		commands := COMMANDS
		fmt.sbprintf(&b, "<h1>Commands of kerneltool</h1>\n<p>All the automation of the project is one program, <code>kerneltool</code>. Run a command with <code>nix develop -c kerneltool &lt;command&gt;</code>. %d commands.</p>\n", len(commands))
		site_source_line(site, &b, "tools/kerneltool/main.odin")
		commands_table := site_table_start(&b, "Commands of kerneltool", {{"Command", .Name}, {"What it does", .Prose}})
		for command in commands {
			strings.write_string(&b, "<tr>")
			site_cell(&b, strings.concatenate({"`", command.name, "`"}, context.temp_allocator), "code")
			site_cell(&b, command.about)
			strings.write_string(&b, "</tr>\n")
		}
		site_table_end(&b, commands_table)
		site_page_add(site, Site_Page{path = path, title = "Commands of kerneltool", description = site_description_cut(fmt.tprintf("The %d commands of kerneltool, the one tool of the project: the build, the machine tests, the pictures, the changelog and the site.", len(commands))), section = .Reference, crumbs = site_crumbs(.Reference), body = strings.to_string(b), sources = site_sources("tools/kerneltool/main.odin")})
		append(&entries, Site_Reference_Entry{path = path, title = "Commands of kerneltool", what = "Each command of the tool of the project, with what it does.", source = "tools/kerneltool/main.odin"})
	}

	// The measured numbers.
	{
		path := site_page_file(SITE_NUMBERS_FOLDER)
		b := strings.builder_make(context.temp_allocator)
		measured_count := 0
		for number in site.measured {
			measured_count += number.found ? 1 : 0
		}
		fmt.sbprintf(&b, "<h1>Measured numbers</h1>\n<p>Each row is a line that a program of the system printed in the log of a machine test, quoted whole: the line gives its own conditions. A machine runs under QEMU on the host that ran the test: each number is one run on that host. %d of %d numbers are measured in this build.</p>\n", measured_count, len(site.measured))
		numbers_table := site_table_start(&b, "Measured numbers", site_numbers_columns[:])
		for number in site.measured {
			strings.write_string(&b, "<tr>")
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
			site_inline(&b, number.conditions)
			strings.write_string(&b, ".</td><td class=\"code\">")
			site_time(&b, number.written)
			strings.write_string(&b, "</td></tr>\n")
		}
		site_table_end(&b, numbers_table)
		strings.write_string(&b, "<p class=\"source\">The lines are read from the logs in <code>build/</code> that the last <code>kerneltool check</code> or <code>kerneltool measure</code> wrote; the list of the numbers is <code>site_measures</code> in ")
		strings.write_string(&b, "<a href=\"")
		site_escape(&b, site_repository_file(site, "tools/kerneltool/site.odin"))
		strings.write_string(&b, "\"><code>tools/kerneltool/site.odin</code></a>.</p>\n")
		site_page_add(site, Site_Page{path = path, title = "Measured numbers", description = site_description_cut(fmt.tprintf("%d numbers that the machine tests of %s printed, each quoted whole from its log with its conditions.", len(site.measured), SITE_SYSTEM_NAME)), section = .Reference, crumbs = site_crumbs(.Reference), body = strings.to_string(b), sources = site_sources("tools/kerneltool/site.odin")})
		append(&entries, Site_Reference_Entry{path = path, title = "Measured numbers", what = "Each number that the machine tests print, with its log and its conditions.", source = "build/test_output*.txt"})
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
		site_page_add(site, Site_Page{path = path, title = "Licenses", description = site_description_cut(fmt.tprintf("The license of %s and of each part that it holds or uses: %d rows, and %d tools that build and test it.", SITE_SYSTEM_NAME, len(site.licenses.system_rows), len(site.licenses.build_rows))), section = .Reference, crumbs = site_crumbs(.Reference), body = strings.to_string(b), sources = site_sources(SITE_LICENSE_FILE, SITE_FLAKE_FILE)})
		append(&entries, Site_Reference_Entry{path = path, title = "Licenses", what = "The license, the author, the version and the place of each part of the system and of each tool of its build.", source = SITE_FLAKE_FILE})
	}

	// The tables generated from the code, and the pages of the modules.
	site_generated_tables_add(site, &entries)

	// The index of the reference.
	reference_page := site_section_page(.Reference)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<h1>Reference</h1>\n<p>Tables that the tool generates from the code and the files that define each thing. The guides explain why; these tables say what exists in this build.</p>\n")
	reference_table := site_table_start(&b, "Reference tables", {{"Table", .Prose}, {"What it holds", .Prose}, {"Generated from", .Name}})
	for entry in entries {
		fmt.sbprintf(&b, "<tr><td><a href=\"%s\">", site_page_link(site, reference_page, entry.path))
		site_escape(&b, entry.title)
		strings.write_string(&b, "</a></td>")
		site_cell(&b, entry.what)
		site_cell(&b, strings.concatenate({"`", entry.source, "`"}, context.temp_allocator), "code")
		strings.write_string(&b, "</tr>\n")
	}
	site_table_end(&b, reference_table)
	site_page_add(site, Site_Page{path = reference_page, is_index = true, title = "Reference", description = site_description_cut(fmt.tprintf("The reference of %s: %d tables that the tool generates from the code and the files of the repository.", SITE_SYSTEM_NAME, len(entries))), section = .Reference, crumbs = site_crumbs(.Home), body = strings.to_string(b)})
	return true
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
	licenses_table := site_table_start(b, name, {{"What", .Prose}, {"Where", .Name}, {"License", .Short}, {"Author or origin", .Prose}, {"Version or pin", .Short}, {"In the boot image", .Short}})
	for row, index in rows {
		fmt.sbprintf(b, "<tr id=\"%s\">", ids[index])
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
		if section == .Home || !site_page_exists(site, site_section_page(section)) {
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
	stages: []Site_Boot_Stage
	if log, has_log := site_read_quiet(TEST_OUTPUT); has_log {
		stages = site_boot_stages(log)
	}
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
		fmt.sbprintf(&b, "<p class=\"source\">The lines \"kernel: boot: ...\" of <code>%s</code>, one run of the main machine test under QEMU.</p>\n", TEST_OUTPUT)
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
