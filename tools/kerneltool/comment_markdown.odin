// The Markdown of the source comments (docs/SITE.md, "The Markdown of a
// source comment"). A comment of the sources is written in a small part of
// Markdown: paragraphs, bold, italics, code, lists, examples and links. The
// site renders it with the renderer of the guides. A module carries the
// same text with its marks removed, because the programs that show it in
// the system (`manual`, the help of the console) draw plain lines with the
// cell font: this file makes that text, and the plain text of a summary.
package kerneltool

import "core:strings"

// markdown_link_at reads a link "[label](target)" that starts at an index
// of a text: its label, its target and the byte after it. A "[" with no
// "](" after its "]", or with no ")", is not a link.
markdown_link_at :: proc(text: string, at: int) -> (label: string, target: string, end: int, found: bool) {
	if at >= len(text) || text[at] != '[' {
		return "", "", 0, false
	}
	closing := strings.index_byte(text[at + 1:], ']')
	if closing < 0 {
		return "", "", 0, false
	}
	label_end := at + 1 + closing
	if label_end + 1 >= len(text) || text[label_end + 1] != '(' {
		return "", "", 0, false
	}
	target_end := strings.index_byte(text[label_end + 2:], ')')
	if target_end < 0 {
		return "", "", 0, false
	}
	label = text[at + 1:label_end]
	target = text[label_end + 2:label_end + 2 + target_end]
	if label == "" || target == "" || strings.contains_any(target, " \n") {
		return "", "", 0, false
	}
	return label, target, label_end + 2 + target_end + 1, true
}

// markdown_italic_opens tells whether the "*" at an index of a text opens
// italics: it is not a part of "**", no letter is before it, no space is
// after it, and a "*" that closes it comes before the next code span. A "*"
// between numbers ("2*3") or alone ("a * b") is text.
markdown_italic_opens :: proc(text: string, at: int) -> bool {
	if at + 1 >= len(text) || text[at] != '*' || text[at + 1] == '*' || text[at + 1] == ' ' || text[at + 1] == '\n' {
		return false
	}
	if at > 0 && (site_is_word_byte(text[at - 1]) || text[at - 1] == '*') {
		return false
	}
	return markdown_italic_close(text, at + 1) >= 0
}

// markdown_italic_close gives the index of the "*" that closes italics
// opened before an index, or -1: a "*" with no space before it, no letter
// after it, and not a part of "**". A code span ends the search: its "*" is
// code.
markdown_italic_close :: proc(text: string, from: int) -> int {
	for index in from ..< len(text) {
		character := text[index]
		if character == '`' {
			return -1
		}
		if character != '*' {
			continue
		}
		if index + 1 < len(text) && text[index + 1] == '*' {
			return -1
		}
		if text[index - 1] == ' ' || text[index - 1] == '*' || text[index - 1] == '\n' {
			continue
		}
		if index + 1 < len(text) && site_is_word_byte(text[index + 1]) {
			continue
		}
		return index
	}
	return -1
}

// markdown_inline_plain gives the text of a line of Markdown with its marks
// removed: bold and italics lose their stars, a link becomes its label, a
// line feed becomes a space. A code span keeps its backticks when
// keep_code_marks is true: in a text that a program draws with one font,
// the backticks are the only sign of code.
markdown_inline_plain :: proc(text: string, keep_code_marks: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	italic_close := -1
	index := 0
	for index < len(text) {
		character := text[index]
		switch {
		case character == '`':
			end := strings.index_byte(text[index + 1:], '`')
			if end < 0 {
				strings.write_byte(&b, character)
				index += 1
				continue
			}
			if keep_code_marks {
				strings.write_string(&b, text[index:index + end + 2])
			} else {
				strings.write_string(&b, text[index + 1:index + 1 + end])
			}
			index += end + 2
			continue
		case character == '*' && index + 1 < len(text) && text[index + 1] == '*':
			index += 2
			continue
		case character == '*' && index == italic_close:
			italic_close = -1
			index += 1
			continue
		case character == '*' && italic_close < 0 && markdown_italic_opens(text, index):
			italic_close = markdown_italic_close(text, index + 1)
			index += 1
			continue
		case character == '[':
			if label, _, end, found := markdown_link_at(text, index); found {
				strings.write_string(&b, markdown_inline_plain(label, keep_code_marks))
				index = end
				continue
			}
		case character == '\n':
			strings.write_byte(&b, ' ')
			index += 1
			continue
		}
		strings.write_byte(&b, character)
		index += 1
	}
	return strings.to_string(b)
}

// One block of a comment while documentation_text_of_markdown reads it.
@(private = "file")
Documentation_Block :: struct {
	prefix:    string, // "- ", "  - ", "12. ": the marker of a list item, with its indentation; "" for a paragraph.
	text:      string, // The Markdown of the block, its lines joined with a space.
	kept:      bool, // A line of an example: the module keeps it as it is.
	continues: bool, // The next line can continue it.
}

// documentation_text_of_markdown gives the documentation text that a module
// carries from the Markdown of a comment (contract/module/format.odin,
// Documentation): a paragraph is one line; a list item is one line that
// starts with its marker ("- ", "1. "), its nested items with their
// indentation; a line of an example keeps its form, behind four spaces,
// so that it starts with a space; an empty line separates two blocks. The
// marks of bold, italics and links go; a code span keeps its backticks. The
// first sentence of the text is the first sentence of the comment with no
// mark: the help of an export.
documentation_text_of_markdown :: proc(markdown: string) -> string {
	blocks := make([dynamic]Documentation_Block, context.temp_allocator)
	fenced := false
	empty_before := false
	add :: proc(blocks: ^[dynamic]Documentation_Block, empty_before: ^bool, block: Documentation_Block) {
		if empty_before^ && len(blocks) > 0 {
			append(blocks, Documentation_Block{})
		}
		empty_before^ = false
		append(blocks, block)
	}
	for line in site_lines(markdown) {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "```") {
			fenced = !fenced
			if len(blocks) > 0 {
				blocks[len(blocks) - 1].continues = false
			}
			continue
		}
		if fenced {
			add(&blocks, &empty_before, Documentation_Block{text = strings.concatenate({"    ", line}, context.temp_allocator), kept = true})
			continue
		}
		if trimmed == "" {
			empty_before = true
			if len(blocks) > 0 {
				blocks[len(blocks) - 1].continues = false
			}
			continue
		}
		last: ^Documentation_Block
		if len(blocks) > 0 && !empty_before {
			last = &blocks[len(blocks) - 1]
		}
		if marker, is_marker := site_list_marker(line); is_marker {
			prefix := marker.ordered ? strings.concatenate({marker.label, ". "}, context.temp_allocator) : "- "
			prefix = strings.concatenate({line[:marker.indent], prefix}, context.temp_allocator)
			add(&blocks, &empty_before, Documentation_Block{prefix = prefix, text = marker.text, continues = true})
			continue
		}
		if line[0] == ' ' {
			// An indented line continues a list item; else it is a line of an
			// example.
			if last != nil && last.continues && last.prefix != "" {
				last.text = strings.concatenate({last.text, " ", trimmed}, context.temp_allocator)
				continue
			}
			add(&blocks, &empty_before, Documentation_Block{text = line, kept = true})
			continue
		}
		if last != nil && last.continues {
			last.text = strings.concatenate({last.text, " ", trimmed}, context.temp_allocator)
			continue
		}
		add(&blocks, &empty_before, Documentation_Block{text = trimmed, continues = true})
	}
	lines := make([dynamic]string, context.temp_allocator)
	for block in blocks {
		switch {
		case block.kept:
			append(&lines, strings.trim_right_space(block.text))
		case block.text == "" && block.prefix == "":
			append(&lines, "")
		case:
			append(&lines, strings.concatenate({block.prefix, markdown_inline_plain(block.text, true)}, context.temp_allocator))
		}
	}
	return strings.join(lines[:], "\n", context.temp_allocator)
}

// markdown_first_sentence gives the first sentence of the Markdown of a
// comment, with no mark and no period at its end: the first sentence of
// the text that a module carries.
markdown_first_sentence :: proc(markdown: string) -> string {
	return about_of(documentation_text_of_markdown(markdown), "")
}

// markdown_comment_line splits a line of an Odin source into its code and
// its comment, as a part of the Markdown of the comment: the marker "//"
// and one space go, the indentation after them stays, so that a nested list
// item and a line of an example keep their form. is_comment is true for a
// line "//" with no text: an empty line of the comment.
markdown_comment_line :: proc(line: string) -> (code: string, comment: string, is_comment: bool) {
	syntax, _ := comment_syntax_of(".odin")
	quote: u8 = 0
	for index := 0; index < len(line); index += 1 {
		character := line[index]
		switch {
		case quote != 0:
			if character == '\\' && strings.index_byte(syntax.escaped_quotes, quote) >= 0 {
				index += 1
			} else if character == quote {
				quote = 0
			}
		case strings.index_byte(syntax.escaped_quotes, character) >= 0 || strings.index_byte(syntax.raw_quotes, character) >= 0:
			quote = character
		case strings.has_prefix(line[index:], syntax.marker):
			text := strings.trim_right_space(line[index + len(syntax.marker):])
			text = strings.trim_prefix(text, " ")
			text, _ = strings.replace_all(text, "\t", "    ", context.temp_allocator)
			return strings.trim_space(line[:index]), text, true
		}
	}
	return strings.trim_space(line), "", false
}

// markdown_comment_add adds a line to the Markdown of a comment. An empty
// line stays: it separates two paragraphs.
markdown_comment_add :: proc(comment, line: string) -> string {
	if comment == "" && strings.trim_space(line) == "" {
		return ""
	}
	if comment == "" {
		return line
	}
	return strings.concatenate({comment, "\n", line}, context.temp_allocator)
}

// markdown_comment_end gives the Markdown of a comment with no empty line
// at its end.
markdown_comment_end :: proc(comment: string) -> string {
	return strings.trim_right(comment, " \n")
}
