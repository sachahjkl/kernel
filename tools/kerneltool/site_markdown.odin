// The readers of the Markdown files that the site takes its text from
// (docs/SITE.md). Each reader knows exactly one form: the form
// that its file has now. When the form changes, the reader says which line
// does not have the expected form, and the command `site` stops, so that the
// site never shows a part of a file that it did not understand.
package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"

SITE_PROPERTIES_FILE :: "docs/PROPERTIES.md"
SITE_README_FILE :: "README.md"
SITE_REVIEWS_FILE :: "docs/REVIEWS.md"
SITE_DESIGN_FILE :: "docs/DESIGN.md"

// One part of a section of a property that has its own heading of level 3,
// such as "Persistence: no save action" under the storage engine.
Site_Property_Part :: struct {
	title:    string,
	sentence: string,
}

Site_Property :: struct {
	number:   int,
	title:    string, // The heading of its section, after "## <number>. ".
	status:   string, // The column "Status" of the summary table.
	sentence: string, // The first sentence of its first rule.
	parts:    []Site_Property_Part,
}

Site_Principles :: struct {
	objective:  string, // The first paragraph of the section "Objective".
	rules:      []string, // The numbered rules of the section "Objective".
	properties: []Site_Property,
}

// What the site takes from README.md.
Site_Readme :: struct {
	lead:               string, // The first paragraph under the title.
	mark_description:   string, // The alt text of the picture of the mark.
	captions:           map[string]string, // The caption of each picture, by its path.
	use_paragraph:      string, // The first paragraph of the section "Use".
	licence_paragraphs: []string, // The paragraphs of the section "Licences".
}

// site_lines splits a file into lines with no carriage return.
site_lines :: proc(content: string) -> []string {
	lines := strings.split(content, "\n", context.temp_allocator)
	for &line in lines {
		line = strings.trim_right(line, "\r")
	}
	return lines
}

// site_first_sentence gives the text up to the first period that a space
// follows, or the whole text when it has no such period.
site_first_sentence :: proc(text: string) -> string {
	trimmed := strings.trim_space(text)
	for index in 0 ..< len(trimmed) - 1 {
		if trimmed[index] == '.' && trimmed[index + 1] == ' ' {
			return trimmed[:index + 1]
		}
	}
	return trimmed
}

// site_digits_value gives the value of a text of decimal digits, or -1.
site_digits_value :: proc(text: string) -> int {
	if len(text) == 0 || len(text) > 6 {
		return -1
	}
	value := 0
	for character in transmute([]u8)text {
		if character < '0' || character > '9' {
			return -1
		}
		value = value * 10 + int(character - '0')
	}
	return value
}

// site_table_cells gives the cells of a line "| a | b | c |", trimmed.
site_table_cells :: proc(line: string) -> []string {
	inner := strings.trim_space(line)
	inner = strings.trim_prefix(inner, "|")
	inner = strings.trim_suffix(inner, "|")
	cells := strings.split(inner, "|", context.temp_allocator)
	for &cell in cells {
		cell = strings.trim_space(cell)
	}
	return cells
}

// site_section_lines gives the lines under the heading `heading` (a whole
// line, such as "## Objective") up to the next heading of level 1 or 2.
site_section_lines :: proc(lines: []string, heading: string) -> (section: []string, found: bool) {
	for line, index in lines {
		if line != heading {
			continue
		}
		end := index + 1
		for end < len(lines) && !strings.has_prefix(lines[end], "## ") && !strings.has_prefix(lines[end], "# ") {
			end += 1
		}
		return lines[index + 1:end], true
	}
	return nil, false
}

// site_paragraphs gives the paragraphs of lines of plain text: each group of
// lines with no empty line, joined by a space. A list, a table, a heading,
// a picture and a block of code are not paragraphs.
site_paragraphs :: proc(lines: []string) -> []string {
	paragraphs := make([dynamic]string, context.temp_allocator)
	current := make([dynamic]string, context.temp_allocator)
	in_code := false
	finish :: proc(paragraphs: ^[dynamic]string, current: ^[dynamic]string) {
		if len(current) > 0 {
			append(paragraphs, strings.join(current[:], " ", context.temp_allocator))
			clear(current)
		}
	}
	for line in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "```") {
			finish(&paragraphs, &current)
			in_code = !in_code
			continue
		}
		plain := !in_code && trimmed != "" && !strings.has_prefix(trimmed, "- ") && !strings.has_prefix(trimmed, "|") && !strings.has_prefix(trimmed, "#") && !strings.has_prefix(trimmed, "![") && !strings.has_prefix(trimmed, "<")
		if !plain {
			finish(&paragraphs, &current)
			continue
		}
		append(&current, trimmed)
	}
	finish(&paragraphs, &current)
	return paragraphs[:]
}

// site_labelled_bullet gives the text of the first line "- **<label>**: text"
// or "- **<label>** (a note): text".
site_labelled_bullet :: proc(lines: []string, label: string) -> (text: string, found: bool) {
	start := strings.concatenate({"- **", label, "**"}, context.temp_allocator)
	for line in lines {
		if !strings.has_prefix(line, start) {
			continue
		}
		colon := strings.index(line[len(start):], ": ")
		if colon < 0 {
			continue
		}
		return strings.trim_space(line[len(start) + colon + 2:]), true
	}
	return "", false
}

// site_part_sentence gives the first sentence that stands for one part of
// docs/PROPERTIES.md, in this order of preference: its first "- **Rule**:",
// its first "- **Proposal**:", its first paragraph that is not the line
// "Status: ...", the first column of its table.
site_part_sentence :: proc(lines: []string) -> (sentence: string, found: bool) {
	if text, has_rule := site_labelled_bullet(lines, "Rule"); has_rule {
		return site_first_sentence(text), true
	}
	if text, has_proposal := site_labelled_bullet(lines, "Proposal"); has_proposal {
		return site_first_sentence(text), true
	}
	for paragraph in site_paragraphs(lines) {
		if !strings.has_prefix(paragraph, "Status:") {
			return site_first_sentence(paragraph), true
		}
	}
	// A table: the first column of each row after the header and the line
	// of dashes.
	names := make([dynamic]string, context.temp_allocator)
	row := 0
	for line in lines {
		if !strings.has_prefix(line, "|") {
			continue
		}
		row += 1
		if row <= 2 {
			continue
		}
		cells := site_table_cells(line)
		if len(cells) > 0 && cells[0] != "" {
			append(&names, cells[0])
		}
	}
	if len(names) > 0 {
		return strings.concatenate({strings.join(names[:], ", ", context.temp_allocator), "."}, context.temp_allocator), true
	}
	return "", false
}

// site_properties_parse reads docs/PROPERTIES.md. The form it relies on:
//   a section "## Objective": its first paragraph, and its rules as lines "<n>. <text>";
//   a section "## Summary": a table "| # | Property | Status |", its line of
//   dashes, then one row "| <n> | <title> | <status> |" for each property;
//   one section "## <n>. <title>" for each property, numbered from 1 with no
//   gap, as many as the rows of the summary; in a section, the part before its
//   first "### " heading stands for the property, and each "### <title>" is a
//   part of it (see site_part_sentence for the sentence of each);
//   the properties end at the first "## " heading that is not "## <n>. ".
site_properties_parse :: proc(content: string) -> (principles: Site_Principles, problem: string) {
	lines := site_lines(content)
	file :: SITE_PROPERTIES_FILE

	objective_lines, has_objective := site_section_lines(lines, "## Objective")
	if !has_objective {
		return {}, file + ": no line \"## Objective\"; the site takes the objective and its rules from that section"
	}
	objective_paragraphs := site_paragraphs(objective_lines)
	if len(objective_paragraphs) == 0 {
		return {}, file + ": the section \"## Objective\" has no paragraph"
	}
	principles.objective = objective_paragraphs[0]
	rules := make([dynamic]string, context.temp_allocator)
	for line in objective_lines {
		dot := strings.index(line, ". ")
		if dot > 0 && site_digits_value(line[:dot]) == len(rules) + 1 {
			append(&rules, strings.trim_space(line[dot + 2:]))
		}
	}
	if len(rules) == 0 {
		return {}, file + ": the section \"## Objective\" has no rule \"1. <text>\""
	}
	principles.rules = rules[:]

	summary_lines, has_summary := site_section_lines(lines, "## Summary")
	if !has_summary {
		return {}, file + ": no line \"## Summary\"; the site takes the status of each property from its table"
	}
	statuses := make([dynamic]string, context.temp_allocator)
	table_row := 0
	for line in summary_lines {
		if !strings.has_prefix(line, "|") {
			continue
		}
		table_row += 1
		cells := site_table_cells(line)
		if table_row == 1 {
			if len(cells) != 3 || cells[0] != "#" || cells[1] != "Property" || cells[2] != "Status" {
				return {}, file + ": the summary table must start with \"| # | Property | Status |\""
			}
			continue
		}
		if table_row == 2 {
			continue // The line of dashes.
		}
		if len(cells) != 3 || site_digits_value(cells[0]) != len(statuses) + 1 || cells[2] == "" {
			return {}, fmt.tprintf("%s: the row %d of the summary table must be \"| %d | <title> | <status> |\"", file, len(statuses) + 1, len(statuses) + 1)
		}
		append(&statuses, cells[2])
	}
	if len(statuses) == 0 {
		return {}, file + ": the summary table has no row"
	}

	properties := make([dynamic]Site_Property, context.temp_allocator)
	index := 0
	for index < len(lines) {
		line := lines[index]
		index += 1
		if !strings.has_prefix(line, "## ") {
			continue
		}
		heading := line[len("## "):]
		dot := strings.index(heading, ". ")
		number := dot > 0 ? site_digits_value(heading[:dot]) : -1
		if number < 0 {
			if len(properties) > 0 {
				break // The first section after the properties.
			}
			continue
		}
		if number != len(properties) + 1 {
			return {}, fmt.tprintf("%s: the section \"## %d. <title>\" is expected, \"%s\" comes", file, len(properties) + 1, line)
		}
		end := index
		for end < len(lines) && !strings.has_prefix(lines[end], "## ") && !strings.has_prefix(lines[end], "# ") {
			end += 1
		}
		section := lines[index:end]
		index = end
		own_end := 0
		for own_end < len(section) && !strings.has_prefix(section[own_end], "### ") {
			own_end += 1
		}
		property := Site_Property {
			number = number,
			title  = strings.trim_space(heading[dot + 2:]),
		}
		if property.title == "" {
			return {}, fmt.tprintf("%s: the section of the property %d has no title", file, number)
		}
		sentence, found := site_part_sentence(section[:own_end])
		if !found || sentence == "" {
			return {}, fmt.tprintf("%s: the section of the property %d has no line \"- **Rule**: <text>\", no \"- **Proposal**: <text>\", no paragraph and no table before its first \"### \" heading", file, number)
		}
		property.sentence = sentence
		parts := make([dynamic]Site_Property_Part, context.temp_allocator)
		part_start := own_end
		for part_start < len(section) {
			part_end := part_start + 1
			for part_end < len(section) && !strings.has_prefix(section[part_end], "### ") {
				part_end += 1
			}
			part_title := strings.trim_space(section[part_start][len("### "):])
			part_sentence, part_found := site_part_sentence(section[part_start + 1:part_end])
			if part_title == "" || !part_found || part_sentence == "" {
				return {}, fmt.tprintf("%s: the part \"%s\" of the property %d has no title, or no rule, paragraph or table", file, section[part_start], number)
			}
			append(&parts, Site_Property_Part{title = part_title, sentence = part_sentence})
			part_start = part_end
		}
		property.parts = parts[:]
		append(&properties, property)
	}
	if len(properties) == 0 {
		return {}, file + ": no section \"## 1. <title>\""
	}
	if len(properties) != len(statuses) {
		return {}, fmt.tprintf("%s: the summary table has %d rows and the file has %d sections of properties", file, len(statuses), len(properties))
	}
	for &property, property_index in properties {
		property.status = statuses[property_index]
	}
	principles.properties = properties[:]
	return principles, ""
}

// site_readme_parse reads README.md. The form it relies on:
//   a line "# <title>", then the first paragraph: the lead;
//   a line with `src="resources/logo/modus.png"` and `alt="<text>"`;
//   pictures as "![<caption>](<path>)", anywhere in a line (also in a cell of a table);
//   a section "## Use" whose first paragraph says what supplies the tools;
//   a section "## Licences" of paragraphs.
site_readme_parse :: proc(content: string) -> (readme: Site_Readme, problem: string) {
	lines := site_lines(content)
	file :: SITE_README_FILE
	title_line := -1
	for line, index in lines {
		if strings.has_prefix(line, "# ") {
			title_line = index
			break
		}
	}
	if title_line < 0 {
		return {}, file + ": no title \"# <title>\"; the site takes the paragraph under it"
	}
	// The first paragraph under the title, not one of a later section.
	first_heading := title_line + 1
	for first_heading < len(lines) && !strings.has_prefix(lines[first_heading], "#") {
		first_heading += 1
	}
	in_first_section := site_paragraphs(lines[title_line + 1:first_heading])
	if len(in_first_section) == 0 {
		return {}, file + ": no paragraph between the title and the next heading"
	}
	readme.lead = in_first_section[0]

	MARK_SOURCE :: "src=\"resources/logo/modus_transparent.png\""
	for line in lines {
		if !strings.contains(line, MARK_SOURCE) {
			continue
		}
		start := strings.index(line, "alt=\"")
		if start < 0 {
			break
		}
		rest := line[start + len("alt=\""):]
		end := strings.index_byte(rest, '"')
		if end <= 0 {
			break
		}
		readme.mark_description = rest[:end]
	}
	if readme.mark_description == "" {
		return {}, file + ": no line with " + MARK_SOURCE + " and alt=\"<text>\"; the site takes the description of the mark from it"
	}

	readme.captions = make(map[string]string, context.temp_allocator)
	for line, index in lines {
		rest := line
		for {
			start := strings.index(rest, "![")
			if start < 0 {
				break
			}
			rest = rest[start + 2:]
			middle := strings.index(rest, "](")
			if middle < 0 {
				return {}, fmt.tprintf("%s, line %d: a picture \"![<caption>](<path>)\" has no \"](\"", file, index + 1)
			}
			caption := rest[:middle]
			rest = rest[middle + 2:]
			end := strings.index_byte(rest, ')')
			if end <= 0 {
				return {}, fmt.tprintf("%s, line %d: a picture \"![<caption>](<path>)\" has no path or no \")\"", file, index + 1)
			}
			path := rest[:end]
			rest = rest[end + 1:]
			if caption == "" {
				return {}, fmt.tprintf("%s, line %d: the picture %s has no caption", file, index + 1, path)
			}
			// A "]" in a caption is the end of a picture whose "(" is lost.
			if strings.contains(caption, "]") {
				return {}, fmt.tprintf("%s, line %d: the caption of the picture %s has a \"]\"; a picture is \"![<caption>](<path>)\"", file, index + 1, path)
			}
			if path not_in readme.captions {
				readme.captions[path] = caption
			}
		}
	}

	use_lines, has_use := site_section_lines(lines, "## Use")
	use_paragraphs := site_paragraphs(use_lines)
	if !has_use || len(use_paragraphs) == 0 {
		return {}, file + ": no section \"## Use\" with a paragraph"
	}
	readme.use_paragraph = use_paragraphs[0]
	licence_lines, has_licences := site_section_lines(lines, "## Licences")
	readme.licence_paragraphs = site_paragraphs(licence_lines)
	if !has_licences || len(readme.licence_paragraphs) == 0 {
		return {}, file + ": no section \"## Licences\" with a paragraph"
	}
	return readme, ""
}

// site_reviews_step_count reads the table of the steps at the start of
// docs/REVIEWS.md, before its first "## " heading. The form it relies on:
// one row "| <step> | <commit> | <capability> |" for each step, numbered
// from 1 with no gap. It gives the number of the last step.
site_reviews_step_count :: proc(content: string) -> (count: int, problem: string) {
	for line in site_lines(content) {
		if strings.has_prefix(line, "## ") {
			break
		}
		if !strings.has_prefix(line, "| ") {
			continue
		}
		cells := site_table_cells(line)
		if len(cells) == 0 {
			continue
		}
		number := site_digits_value(cells[0])
		if number < 0 {
			continue // The header, or the line of dashes.
		}
		if number != count + 1 {
			return 0, fmt.tprintf("%s: the row of the step %d is expected, the step %d comes", SITE_REVIEWS_FILE, count + 1, number)
		}
		count = number
	}
	if count == 0 {
		return 0, SITE_REVIEWS_FILE + ": no row \"| 1 | <commit> | <capability> |\" before the first \"## \" heading"
	}
	return count, ""
}

// site_mark_captions reads the table of the files of the mark in
// docs/DESIGN.md. The form it relies on: a row
// "| `resources/logo/<name>.png` | <size> | <what it shows> |" for each file
// that has a row of its own. It gives "what it shows" by path.
site_mark_captions :: proc(content: string) -> map[string]string {
	captions := make(map[string]string, context.temp_allocator)
	for line in site_lines(content) {
		if !strings.has_prefix(line, "| `resources/logo/") {
			continue
		}
		cells := site_table_cells(line)
		if len(cells) != 3 || strings.count(cells[0], "`") != 2 {
			continue // A row of several files.
		}
		captions[strings.trim(cells[0], "`")] = cells[2]
	}
	return captions
}

// readme_pictures_check checks that each picture that README.md names is a
// file of the repository: a picture that a step renamed or removed would
// leave a broken picture in the README and on the site.
readme_pictures_check :: proc() -> bool {
	text := site_read(SITE_README_FILE) or_return
	readme, problem := site_readme_parse(text)
	if problem != "" {
		fmt.eprintfln("kerneltool: test failed: %s", problem)
		return false
	}
	for path in readme.captions {
		if !os.exists(path) {
			fmt.eprintfln("kerneltool: test failed: %s names the picture %s, which is not a file of the repository", SITE_README_FILE, path)
			return false
		}
	}
	fmt.printfln("kerneltool: test passed: the %d pictures that %s names are files of the repository", len(readme.captions), SITE_README_FILE)
	return true
}
