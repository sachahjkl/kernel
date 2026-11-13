// The glossary of the project (docs/SITE.md, "The glossary"): the one reader
// of docs/GLOSSARY.md. The page of the site, the links to a term, the search,
// the page graph, the references to a term and the check of the tool all
// read the terms that glossary_read gives.
package kerneltool

import "core:fmt"
import "core:strings"

// The start of the last paragraph of an entry: the words that the term
// replaces.
GLOSSARY_AVOIDED_PREFIX :: "Do not use: "

// One term: a heading of level 3 under the heading of its group, its short
// definition (the first paragraph), its explanation, and the line of the
// words that it replaces.
Glossary_Term :: struct {
	name:             string, // The text of its heading, with no code marks.
	id:               string, // Its anchor on the page: "term-" and the slug of the name, "-2" for a second term of that slug.
	group:            string, // The name of its group.
	line:             int, // The line of its heading in the file, from 1.
	definition:       string, // The first paragraph under the heading, as one line of Markdown: the text of a tooltip, a search result and the page graph.
	explanation:      string, // The Markdown between the short definition and the words to avoid, or "".
	explanation_line: int, // The line in the file of the first line of the explanation.
	avoided:          string, // The words after "Do not use: ", with no period at the end, or "".
}

// One group: a heading of level 2, a text before its first term, its terms.
Glossary_Group :: struct {
	name:              string,
	id:                string,
	introduction:      string, // The Markdown between the heading and the first term, or "".
	introduction_line: int,
	terms:             []Glossary_Term,
}

Glossary :: struct {
	title:             string,
	introduction:      string, // The Markdown between the title and the first group.
	introduction_line: int,
	groups:            []Glossary_Group,
}

// glossary_term_id gives the anchor of a term. A second term with the same
// slug gets "-2", as a second heading of a page does.
glossary_term_id :: proc(name: string, seen: ^map[string]int) -> string {
	id := strings.concatenate({"term-", site_slug(name)}, context.temp_allocator)
	seen^[id] += 1
	count := seen^[id]
	if count == 1 {
		return id
	}
	return fmt.tprintf("%s-%d", id, count)
}

// glossary_markdown gives the lines of a part as one Markdown text, with no
// empty line at its ends, and the line in the file of its first line.
glossary_markdown :: proc(lines: []string, first_line: int) -> (text: string, line: int) {
	start, end := 0, len(lines)
	for start < end && strings.trim_space(lines[start]) == "" {
		start += 1
	}
	for end > start && strings.trim_space(lines[end - 1]) == "" {
		end -= 1
	}
	if start == end {
		return "", 0
	}
	return strings.join(lines[start:end], "\n", context.temp_allocator), first_line + start
}

// glossary_read reads docs/GLOSSARY.md. Each problem is a part that does
// not have the form of the glossary; the reader gives the terms that it
// could read all the same.
glossary_read :: proc(content: string) -> (glossary: Glossary, problems: []string) {
	found := make([dynamic]string, context.temp_allocator)
	groups := make([dynamic]Glossary_Group, context.temp_allocator)
	group_terms := make([dynamic]Glossary_Term, context.temp_allocator)
	seen_ids := make(map[string]int, context.temp_allocator)
	lines := site_lines(content)

	// The headings outside the fences of code, by their index in lines.
	heading_indices := make([dynamic]int, context.temp_allocator)
	fenced := false
	for line, index in lines {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "```") {
			fenced = !fenced
			continue
		}
		if fenced {
			continue
		}
		if level, _ := site_heading_level(line); level > 0 {
			append(&heading_indices, index)
		}
		// The form before this one: a table of terms.
		if strings.has_prefix(trimmed, "| Term |") {
			append(&found, fmt.tprintf("line %d: a table of terms: each term is a heading of level 3 in its group", index + 1))
		}
	}
	append(&heading_indices, len(lines))

	for position in 0 ..< len(heading_indices) - 1 {
		index := heading_indices[position]
		body := lines[index + 1:heading_indices[position + 1]]
		level, text := site_heading_level(lines[index])
		switch level {
		case 1:
			glossary.title = text
			glossary.introduction, glossary.introduction_line = glossary_markdown(body, index + 2)
		case 2:
			if len(groups) > 0 {
				groups[len(groups) - 1].terms = group_terms[:]
				group_terms = make([dynamic]Glossary_Term, context.temp_allocator)
			}
			group := Glossary_Group{name = text, id = site_slug(text)}
			group.introduction, group.introduction_line = glossary_markdown(body, index + 2)
			append(&groups, group)
		case 3:
			if len(groups) == 0 {
				append(&found, fmt.tprintf("line %d: the term %q comes before the heading of a group", index + 1, text))
				continue
			}
			term := glossary_term_read(text, index + 1, body, &seen_ids, &found)
			term.group = groups[len(groups) - 1].name
			append(&group_terms, term)
		case:
			append(&found, fmt.tprintf("line %d: a heading of level %d: an entry has no heading inside it", index + 1, level))
		}
	}
	if len(groups) > 0 {
		groups[len(groups) - 1].terms = group_terms[:]
	}
	if glossary.title == "" {
		append(&found, "the file has no title (a heading of level 1)")
	}
	glossary.groups = groups[:]
	return glossary, found[:]
}

// glossary_term_read reads the entry of one term: the lines under its
// heading, in paragraphs (blocks of lines that an empty line outside a
// fence ends).
glossary_term_read :: proc(heading: string, heading_line: int, body: []string, seen_ids: ^map[string]int, problems: ^[dynamic]string) -> Glossary_Term {
	term := Glossary_Term{name = site_term_name(heading), line = heading_line}
	term.id = glossary_term_id(term.name, seen_ids)

	blocks := make([dynamic][2]int, context.temp_allocator)
	fenced := false
	start := -1
	for line, index in body {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "```") {
			fenced = !fenced
		}
		if trimmed == "" && !fenced {
			if start >= 0 {
				append(&blocks, [2]int{start, index})
				start = -1
			}
			continue
		}
		if start < 0 {
			start = index
		}
	}
	if start >= 0 {
		append(&blocks, [2]int{start, len(body)})
	}

	if len(blocks) == 0 {
		append(problems, fmt.tprintf("line %d: the term %q has no short definition", heading_line, term.name))
		return term
	}
	first_line := strings.trim_space(body[blocks[0][0]])
	_, is_list := site_list_marker(body[blocks[0][0]])
	if is_list || strings.has_prefix(first_line, "|") || strings.has_prefix(first_line, "```") || strings.has_prefix(first_line, ">") || strings.has_prefix(first_line, GLOSSARY_AVOIDED_PREFIX) {
		append(problems, fmt.tprintf("line %d: the term %q starts with no short definition: its first paragraph is the definition, one paragraph of text", heading_line, term.name))
		return term
	}
	parts := make([dynamic]string, context.temp_allocator)
	for line in body[blocks[0][0]:blocks[0][1]] {
		append(&parts, strings.trim_space(line))
	}
	term.definition = strings.join(parts[:], " ", context.temp_allocator)

	explained_end := len(blocks)
	last := blocks[len(blocks) - 1]
	if len(blocks) > 1 && strings.has_prefix(strings.trim_space(body[last[0]]), GLOSSARY_AVOIDED_PREFIX) {
		words := make([dynamic]string, context.temp_allocator)
		for line in body[last[0]:last[1]] {
			append(&words, strings.trim_space(line))
		}
		avoided := strings.join(words[:], " ", context.temp_allocator)
		avoided = strings.trim_space(avoided[len(GLOSSARY_AVOIDED_PREFIX):])
		term.avoided = strings.trim_suffix(avoided, ".")
		explained_end = len(blocks) - 1
	}
	for block in blocks[1:explained_end] {
		if strings.has_prefix(strings.trim_space(body[block[0]]), GLOSSARY_AVOIDED_PREFIX) {
			append(problems, fmt.tprintf("line %d: the words that the term %q replaces are not the last paragraph of its entry", heading_line + 1 + block[0], term.name))
		}
	}
	if explained_end > 1 {
		explanation_start := blocks[1][0]
		explanation_end := blocks[explained_end - 1][1]
		term.explanation = strings.join(body[explanation_start:explanation_end], "\n", context.temp_allocator)
		term.explanation_line = heading_line + 1 + explanation_start
	}
	return term
}

// glossary_terms_in_order gives the terms of each group, in the order of the
// file.
glossary_terms_in_order :: proc(glossary: Glossary) -> []Glossary_Term {
	terms := make([dynamic]Glossary_Term, context.temp_allocator)
	for group in glossary.groups {
		append(&terms, ..group.terms)
	}
	return terms[:]
}

// glossary_check refuses a glossary that does not have its form, and
// prints the terms that have a short definition and no explanation: a
// warning, until each group has its explanations (docs/SITE.md, "The
// glossary").
glossary_check :: proc() -> bool {
	content, read_ok := site_read_quiet(SITE_GLOSSARY_FILE)
	if !read_ok {
		fmt.eprintfln("kerneltool: test failed: cannot read %s", SITE_GLOSSARY_FILE)
		return false
	}
	glossary, problems := glossary_read(content)
	for problem in problems {
		fmt.eprintfln("kerneltool: test failed: %s, %s", SITE_GLOSSARY_FILE, problem)
	}
	if len(problems) > 0 {
		return false
	}
	terms := glossary_terms_in_order(glossary)
	unexplained := 0
	for term in terms {
		unexplained += term.explanation == "" ? 1 : 0
	}
	if unexplained > 0 {
		fmt.printfln("kerneltool: warning: %d of the %d terms of %s have a short definition and no explanation:", unexplained, len(terms), SITE_GLOSSARY_FILE)
		for group in glossary.groups {
			names := make([dynamic]string, context.temp_allocator)
			for term in group.terms {
				if term.explanation == "" {
					append(&names, term.name)
				}
			}
			if len(names) > 0 {
				fmt.printfln("kerneltool: warning:   %s (%d): %s", group.name, len(names), strings.join(names[:], ", ", context.temp_allocator))
			}
		}
	}
	test_passed_print("each of the %d terms of %s has its heading, its short definition and the form of its entry", len(terms), SITE_GLOSSARY_FILE)
	return true
}
