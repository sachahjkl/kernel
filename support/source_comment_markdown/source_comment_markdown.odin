// The reader of the Markdown of a source comment, for a program of the
// system (docs/SITE.md, "The Markdown of a source comment").
//
// A module carries the comments of its source as its documentation, in a
// small part of Markdown: paragraphs, bold, italics, code spans, lists,
// examples and links. This package reads that part and nothing more. A
// heading, a table, a quote, a line of HTML and a picture are words of a
// paragraph, as on the site.
//
// The reader allocates nothing and copies nothing. It gives the text as
// blocks and spans, in the order of the text, to two procedures of the
// caller (`read`) or into two tables of the caller (`read_into_table`).
// Each block and each span is a range of bytes of the text that the caller
// gave.
//
// The text can come from a file that another party wrote. Each index is
// checked against the length of the text, and the work is in proportion to
// the length of the text: no search runs twice over the same bytes for
// marks that have no end.
package source_comment_markdown

// What a block is.
Block_Kind :: enum u8 {
	Paragraph, // Lines that follow each other: its spans are its words with their styles.
	List_Item, // One item of a list: its mark, then its spans as a paragraph has them.
	Fenced, // The lines between two fences of three backticks: each span is one line, as it is.
	Example, // Lines that start with a space, outside a list: each span is one line, as it is, with no shared indentation.
}

// One style of a span. A span can have several: a bold word of a link.
Style :: enum u8 {
	Bold, // Between two marks of two stars.
	Italic, // Between two stars.
	Code, // Between two backticks, or a line of a fenced block or of an example.
	Link, // The text of a link: the span names the target.
}
// The styles of one span.
Styles :: bit_set[Style;u8]

// One block of the text. Its spans follow it.
Block :: struct {
	kind:             Block_Kind,
	depth:            u8, // A list item: 0 for an item of the list, 1 for an item inside it, at most LIST_DEPTH_LIMIT - 1. A block inside an item: the depth of that item.
	inside_item:      bool, // A fenced block inside a list item, or the paragraph of that item after it.
	ordered:          bool, // A list item: its mark is a number, "1." or "34b.".
	after_empty_line: bool, // An empty line is before the block.
	start, end:       int, // The bytes of the block in the text: its words, or its lines of code.
	mark_start:       int, // A list item: the bytes of its mark, "-" or the label "34b" with no period.
	mark_end:         int,
	language_start:   int, // A fenced block: the bytes of the word after its opening fence. An empty range: no word.
	language_end:     int,
	first_span:       int, // In a table (`read_into_table`): the index of its first span. Its spans end where those of the next block start.
}

// One run of bytes of a block with one set of styles.
//
// In a paragraph and in a list item, a span can hold a line feed and the
// spaces after it: the reader shows them as one space. In a fenced block and
// in an example, a span is one line, and it can be empty.
Span :: struct {
	start, end:   int, // The bytes of the span in the text, with no mark.
	styles:       Styles,
	target_start: int, // A link: the bytes of its target.
	target_end:   int,
}

// The two procedures of a caller. Either can be nil.
Visitor :: struct {
	data:  rawptr, // Given back to each procedure.
	block: proc "contextless" (data: rawptr, text: string, block: Block), // A block starts.
	span:  proc "contextless" (data: rawptr, text: string, span: Span), // A span of the last block.
}

// A deeper item has the depth LIST_DEPTH_LIMIT - 1.
LIST_DEPTH_LIMIT :: 16
// The most bytes of the target of a link. A longer "(...)" after a "]" is
// text: the search for the end of a target stays short.
TARGET_BYTE_LIMIT :: 256

// What a search for one byte found: the next search from a place that the
// last one covered does not read the bytes again.
@(private)
Byte_Search :: struct {
	from:  int, // The search started here.
	found: int, // The index of the byte, or -1: none up to the end of the block.
	known: bool,
}

@(private)
Reader :: struct {
	text:                string,
	visitor:             Visitor,
	limit:               int, // The end of the block whose spans are read.
	backtick:            Byte_Search, // For the spans.
	backtick_ahead:      Byte_Search, // For the search of the end of bold.
	bracket:             Byte_Search,
	bold_absent:         bool, // No end of bold is between bold_absent_from and bold_absent_end.
	bold_absent_from:    int,
	bold_absent_end:     int,
	italic_absent:       bool, // No end of italics is between italic_absent_from and italic_absent_stop.
	italic_absent_from:  int,
	italic_absent_stop:  int,
}

// One line of the text.
@(private)
Line :: struct {
	start: int,
	end:   int, // After its last byte: the line feed, and a carriage return before it, are not in it.
	next:  int, // The start of the next line, or the length of the text.
}

@(private)
line_at :: proc "contextless" (text: string, from: int) -> Line {
	end := from
	for end < len(text) && text[end] != '\n' {
		end += 1
	}
	next := min(end + 1, len(text))
	if end > from && text[end - 1] == '\r' {
		end -= 1
	}
	return {start = from, end = end, next = next}
}

@(private)
is_space :: proc "contextless" (character: u8) -> bool {
	return character == ' ' || character == '\n' || character == '\t' || character == '\r'
}

// is_word_byte tells whether a byte is a part of a word: a letter, a digit,
// "_", or a byte of a character outside ASCII.
@(private)
is_word_byte :: proc "contextless" (character: u8) -> bool {
	return (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9') || character == '_' || character >= 0x80
}

// content_of gives the bytes of a line with no space at its two ends. An
// empty range: the line is empty.
@(private)
content_of :: proc "contextless" (text: string, line: Line) -> (start, end: int) {
	start, end = line.start, line.end
	for start < end && is_space(text[start]) {
		start += 1
	}
	for end > start && is_space(text[end - 1]) {
		end -= 1
	}
	return start, end
}

@(private)
fence_at :: proc "contextless" (text: string, start, end: int) -> bool {
	return end - start >= 3 && text[start] == '`' && text[start + 1] == '`' && text[start + 2] == '`'
}

// The mark of a list item, at the start of a line.
@(private)
Marker :: struct {
	indent:     int, // The spaces before the mark.
	ordered:    bool,
	mark_start: int,
	mark_end:   int,
	text_start: int, // The first byte after the mark and its space.
}

// list_marker reads "- text", "* text", "12. text" or "34b. text" after
// spaces: the forms of the renderer of the site.
@(private)
list_marker :: proc "contextless" (text: string, line: Line) -> (marker: Marker, found: bool) {
	at := line.start
	for at < line.end && text[at] == ' ' {
		at += 1
	}
	marker.indent = at - line.start
	if at + 1 < line.end && (text[at] == '-' || text[at] == '*') && text[at + 1] == ' ' {
		marker.mark_start, marker.mark_end, marker.text_start = at, at + 1, at + 2
		return marker, true
	}
	digits := at
	for digits < line.end && text[digits] >= '0' && text[digits] <= '9' {
		digits += 1
	}
	if digits == at || digits - at > 4 {
		return {}, false
	}
	label_end := digits
	if label_end < line.end && text[label_end] >= 'a' && text[label_end] <= 'z' {
		label_end += 1
	}
	if label_end + 1 < line.end && text[label_end] == '.' && text[label_end + 1] == ' ' {
		marker.ordered = true
		marker.mark_start, marker.mark_end, marker.text_start = at, label_end, label_end + 2
		return marker, true
	}
	return {}, false
}

@(private)
block_give :: proc "contextless" (reader: ^Reader, block: Block) {
	if reader.visitor.block != nil {
		reader.visitor.block(reader.visitor.data, reader.text, block)
	}
}

@(private)
span_give :: proc "contextless" (reader: ^Reader, start, end: int, styles: Styles, target_start, target_end: int, even_empty := false) {
	if (end > start || even_empty) && reader.visitor.span != nil {
		reader.visitor.span(reader.visitor.data, reader.text, {start = start, end = max(end, start), styles = styles, target_start = target_start, target_end = target_end})
	}
}

// read reads the Markdown of a source comment and gives each block, then
// each span of that block, to the visitor, in the order of the text.
//
// The blocks:
//
// - a **paragraph**: lines that follow each other, up to an empty line, a
//   fence, a list item, or a line that starts with a space;
// - a **list item**: a line that starts with `- `, `* `, or a number and a
//   period. A line right after it continues it. An item with more spaces
//   before its mark is inside the item before it;
// - a **fenced block**: the lines between two lines of three backticks. A
//   fence with no end runs to the end of the text;
// - an **example**: lines that start with a space, outside a list.
//
// The spans of a paragraph and of a list item: a code span between two
// backticks; bold between two marks of two stars; italics between two stars,
// where the first star has no letter before it and no space after it; a link
// `[text](target)`, whose target has no space and can hold pairs of
// parentheses. A mark with no end is text.
read :: proc "contextless" (text: string, visitor: Visitor) {
	reader := Reader {
		text    = text,
		visitor = visitor,
	}
	at := 0
	empty_before := false
	for at < len(text) {
		line := line_at(text, at)
		start, end := content_of(text, line)
		if start >= end {
			empty_before = true
			at = line.next
			continue
		}
		next: int
		if fence_at(text, start, end) {
			next = fenced_block(&reader, line, 0, false, empty_before)
		} else if _, is_marker := list_marker(text, line); is_marker {
			next = list(&reader, at, empty_before)
		} else if text[line.start] == ' ' {
			next = example(&reader, at, empty_before)
		} else {
			next = paragraph(&reader, at, empty_before)
		}
		empty_before = false
		// Each block takes one line or more: the loop ends.
		at = max(next, line.next)
	}
}

// fenced_block gives the block that the fence of a line opens, and the
// start of the line after its closing fence.
@(private)
fenced_block :: proc "contextless" (reader: ^Reader, opening: Line, depth: u8, inside_item: bool, after_empty_line: bool) -> int {
	text := reader.text
	start, end := content_of(text, opening)
	language_start, language_end := start + 3, end
	for language_start < language_end && is_space(text[language_start]) {
		language_start += 1
	}
	// The code of a fence inside a list item has the indentation of the item.
	indent := start - opening.start
	code_end := len(text)
	next := len(text)
	for at := opening.next; at < len(text); {
		line := line_at(text, at)
		line_start, line_end := content_of(text, line)
		if line_end - line_start == 3 && fence_at(text, line_start, line_end) {
			code_end, next = line.start, line.next
			break
		}
		at = line.next
	}
	// A fence on the last line, with no line after it, has no code.
	code_start := min(max(opening.next, opening.end), code_end)
	block_give(reader, {kind = .Fenced, depth = depth, inside_item = inside_item, after_empty_line = after_empty_line, start = code_start, end = code_end, language_start = language_start, language_end = max(language_end, language_start)})
	if opening.next <= opening.end {
		return next
	}
	for at := opening.next; at < code_end; {
		line := line_at(text, at)
		line_start := line.start
		if indent > 0 && line.end - line.start >= indent {
			spaces := 0
			for spaces < indent && is_space(text[line.start + spaces]) {
				spaces += 1
			}
			if spaces == indent {
				line_start += indent
			}
		}
		span_give(reader, line_start, line.end, {.Code}, 0, 0, true)
		at = line.next
	}
	return next
}

// example gives the lines from a place that start with a space, as one
// block, with the indentation that they share taken away.
@(private)
example :: proc "contextless" (reader: ^Reader, from: int, after_empty_line: bool) -> int {
	text := reader.text
	shared := -1
	last_end := from
	at := from
	for at < len(text) {
		line := line_at(text, at)
		if line.end == line.start || text[line.start] != ' ' {
			break
		}
		if _, is_marker := list_marker(text, line); is_marker {
			break
		}
		if start, end := content_of(text, line); start < end {
			indent := start - line.start
			shared = shared < 0 ? indent : min(shared, indent)
		}
		last_end = line.end
		at = line.next
	}
	block_give(reader, {kind = .Example, after_empty_line = after_empty_line, start = from, end = last_end})
	for line_start := from; line_start < at; {
		line := line_at(text, line_start)
		span_give(reader, min(line.start + max(shared, 0), line.end), line.end, {.Code}, 0, 0, true)
		line_start = line.next
	}
	return at
}

// paragraph gives the lines from a place up to an empty line or the start
// of another block.
@(private)
paragraph :: proc "contextless" (reader: ^Reader, from: int, after_empty_line: bool) -> int {
	text := reader.text
	first := line_at(text, from)
	block_start, block_end := content_of(text, first)
	at := first.next
	for at < len(text) {
		line := line_at(text, at)
		start, end := content_of(text, line)
		if start >= end || fence_at(text, start, end) || text[line.start] == ' ' {
			break
		}
		if _, is_marker := list_marker(text, line); is_marker {
			break
		}
		block_end = end
		at = line.next
	}
	block_give(reader, {kind = .Paragraph, after_empty_line = after_empty_line, start = block_start, end = block_end})
	spans(reader, block_start, block_end)
	return at
}

// list gives the items of the list that starts at a place. It gives the
// start of the first line that is not of the list: an empty line, when one
// ends the list.
@(private)
list :: proc "contextless" (reader: ^Reader, from: int, after_empty_line: bool) -> int {
	text := reader.text
	indents: [LIST_DEPTH_LIMIT]int
	indent_count := 0
	depth: u8
	any_item := false
	// The block whose lines are read: an item, or the paragraph of an item
	// after a fenced block of it.
	pending: Block
	has_pending := false
	empty_before := after_empty_line
	at := from
	for at < len(text) {
		line := line_at(text, at)
		start, end := content_of(text, line)
		if start >= end {
			// The list goes on after an empty line only with an item or an
			// indented line.
			next := line.next
			after: Line
			found := false
			for next < len(text) {
				after = line_at(text, next)
				if after_start, after_end := content_of(text, after); after_start < after_end {
					found = true
					break
				}
				next = after.next
			}
			if !found {
				break
			}
			_, is_marker := list_marker(text, after)
			if !is_marker && !(after.end - after.start >= 2 && text[after.start] == ' ' && text[after.start + 1] == ' ') {
				break
			}
			empty_before = true
			at = next
			continue
		}
		if marker, is_marker := list_marker(text, line); is_marker {
			if has_pending {
				block_give(reader, pending)
				spans(reader, pending.start, pending.end)
			}
			for indent_count > 0 && indents[indent_count - 1] >= marker.indent {
				indent_count -= 1
			}
			depth = u8(min(indent_count, LIST_DEPTH_LIMIT - 1))
			if indent_count < LIST_DEPTH_LIMIT {
				indents[indent_count] = marker.indent
				indent_count += 1
			}
			text_start := marker.text_start
			for text_start < end && is_space(text[text_start]) {
				text_start += 1
			}
			pending = {kind = .List_Item, depth = depth, ordered = marker.ordered, after_empty_line = empty_before, start = text_start, end = max(end, text_start), mark_start = marker.mark_start, mark_end = marker.mark_end}
			has_pending = true
			any_item = true
			empty_before = false
			at = line.next
			continue
		}
		if !any_item {
			break
		}
		if fence_at(text, start, end) {
			if has_pending {
				block_give(reader, pending)
				spans(reader, pending.start, pending.end)
				has_pending = false
			}
			at = max(fenced_block(reader, line, depth, true, empty_before), line.next)
			empty_before = false
			continue
		}
		// A line right after an item continues it: a comment wraps its lines
		// where its width ends, with no indentation.
		if has_pending {
			pending.end = end
		} else {
			pending = {kind = .Paragraph, depth = depth, inside_item = true, after_empty_line = empty_before, start = start, end = end}
			has_pending = true
		}
		empty_before = false
		at = line.next
	}
	if has_pending {
		block_give(reader, pending)
		spans(reader, pending.start, pending.end)
	}
	return at
}

// spans gives the spans of a paragraph or of a list item.
@(private)
spans :: proc "contextless" (reader: ^Reader, start, end: int) {
	reader.limit = end
	reader.backtick, reader.backtick_ahead, reader.bracket = {}, {}, {}
	reader.bold_absent, reader.italic_absent = false, false
	spans_of_range(reader, start, end, {}, 0, 0)
}

// find_byte gives the index of the next byte of one value from a place and
// before an end, or -1.
@(private)
find_byte :: proc "contextless" (reader: ^Reader, search: ^Byte_Search, character: u8, from, end: int) -> int {
	if !search.known || from < search.from || (search.found >= 0 && from > search.found) {
		found := -1
		for index in from ..< reader.limit {
			if reader.text[index] == character {
				found = index
				break
			}
		}
		search^ = {from = from, found = found, known = true}
	}
	return search.found >= 0 && search.found < end ? search.found : -1
}

// bold_closes tells whether a mark of two stars is between a place and an
// end, outside a code span.
@(private)
bold_closes :: proc "contextless" (reader: ^Reader, from, end: int) -> bool {
	if reader.bold_absent && from >= reader.bold_absent_from && end <= reader.bold_absent_end {
		return false
	}
	text := reader.text
	index := from
	for index + 1 < end {
		if text[index] == '`' {
			if close := find_byte(reader, &reader.backtick_ahead, '`', index + 1, end); close >= 0 {
				index = close + 1
				continue
			}
		} else if text[index] == '*' && text[index + 1] == '*' {
			return true
		}
		index += 1
	}
	reader.bold_absent, reader.bold_absent_from, reader.bold_absent_end = true, from, end
	return false
}

// italic_close gives the index of the star that closes italics opened
// before a place, or -1: a star with no space before it, no letter after it,
// and not a part of a mark of two stars. A code span ends the search: its
// star is code.
@(private)
italic_close :: proc "contextless" (reader: ^Reader, from, end: int) -> int {
	if reader.italic_absent && from >= reader.italic_absent_from && from <= reader.italic_absent_stop && end >= reader.italic_absent_stop {
		return -1
	}
	text := reader.text
	stop := end
	for index in from ..< end {
		character := text[index]
		if character == '`' {
			stop = index
			break
		}
		if character != '*' {
			continue
		}
		if index + 1 < end && text[index + 1] == '*' {
			stop = index
			break
		}
		if index == from || is_space(text[index - 1]) || text[index - 1] == '*' {
			continue
		}
		if index + 1 < end && is_word_byte(text[index + 1]) {
			continue
		}
		return index
	}
	reader.italic_absent, reader.italic_absent_from, reader.italic_absent_stop = true, from, stop
	return -1
}

// italic_opens tells whether the star at an index opens italics, in a range
// that starts at start: it is not a part of a mark of two stars, no letter
// is before it, no space is after it, and a star closes it. It gives that
// star. A star between numbers ("2*3") or alone ("a * b") is text.
@(private)
italic_opens :: proc "contextless" (reader: ^Reader, at, start, end: int) -> (close: int, opens: bool) {
	text := reader.text
	if at + 1 >= end || text[at + 1] == '*' || is_space(text[at + 1]) {
		return -1, false
	}
	if at > start && (is_word_byte(text[at - 1]) || text[at - 1] == '*') {
		return -1, false
	}
	close = italic_close(reader, at + 1, end)
	return close, close >= 0
}

// link_at reads a link `[label](target)` whose "[" is at an index: the end
// of its label, its target and the byte after it. A "[" with no "](" after
// its "]", with no ")", with an empty label or target, or with a space in
// its target, is text. A target can hold pairs of parentheses: "load()".
@(private)
link_at :: proc "contextless" (reader: ^Reader, at, end: int) -> (label_end, target_start, target_end, after: int, found: bool) {
	text := reader.text
	closing := find_byte(reader, &reader.bracket, ']', at + 1, end)
	if closing < 0 || closing == at + 1 || closing + 1 >= end || text[closing + 1] != '(' {
		return 0, 0, 0, 0, false
	}
	target_start = closing + 2
	open := 0
	for index in target_start ..< min(end, target_start + TARGET_BYTE_LIMIT + 1) {
		character := text[index]
		switch {
		case is_space(character):
			return 0, 0, 0, 0, false
		case character == '(':
			open += 1
		case character == ')':
			if open == 0 {
				if index == target_start {
					return 0, 0, 0, 0, false
				}
				return closing, target_start, index, index + 1, true
			}
			open -= 1
		}
	}
	return 0, 0, 0, 0, false
}

// spans_of_range gives the spans of a range of a block: the block itself,
// or the label of a link, which has the styles of its place and the style
// Link.
@(private)
spans_of_range :: proc "contextless" (reader: ^Reader, start, end: int, base: Styles, target_start, target_end: int) {
	text := reader.text
	bold := false
	italic_end := -1
	plain_start := start
	index := start
	for index < end {
		styles := base
		if bold {
			styles += {.Bold}
		}
		if italic_end >= 0 {
			styles += {.Italic}
		}
		character := text[index]
		if character == '`' {
			if close := find_byte(reader, &reader.backtick, '`', index + 1, end); close >= 0 {
				span_give(reader, plain_start, index, styles, target_start, target_end)
				span_give(reader, index + 1, close, styles + {.Code}, target_start, target_end)
				index = close + 1
				plain_start = index
				continue
			}
		}
		if character == '*' && index + 1 < end && text[index + 1] == '*' {
			// The stars of a mark of bold with no end are text.
			if bold || bold_closes(reader, index + 2, end) {
				span_give(reader, plain_start, index, styles, target_start, target_end)
				bold = !bold
				plain_start = index + 2
			}
			index += 2
			continue
		}
		if character == '*' {
			if index == italic_end {
				span_give(reader, plain_start, index, styles, target_start, target_end)
				italic_end = -1
				index += 1
				plain_start = index
				continue
			}
			if italic_end < 0 {
				if close, opens := italic_opens(reader, index, start, end); opens {
					span_give(reader, plain_start, index, styles, target_start, target_end)
					italic_end = close
					index += 1
					plain_start = index
					continue
				}
			}
		}
		// A link has no link inside it.
		if character == '[' && .Link not_in base {
			if label_end, link_target_start, link_target_end, after, found := link_at(reader, index, end); found {
				span_give(reader, plain_start, index, styles, target_start, target_end)
				spans_of_range(reader, index + 1, label_end, styles + {.Link}, link_target_start, link_target_end)
				index = after
				plain_start = index
				continue
			}
		}
		index += 1
	}
	last_styles := base
	if bold {
		last_styles += {.Bold}
	}
	if italic_end >= 0 {
		last_styles += {.Italic}
	}
	span_give(reader, plain_start, end, last_styles, target_start, target_end)
}

// The two tables of a caller, for `read_into_table`.
Table :: struct {
	blocks:      []Block, // The memory of the caller.
	spans:       []Span, // The memory of the caller.
	block_count: int, // The blocks of the text: more than len(blocks) when the table is too small.
	span_count:  int, // The spans of the text: more than len(spans) when the table is too small.
}

@(private)
table_block :: proc "contextless" (data: rawptr, text: string, block: Block) {
	table := (^Table)(data)
	if table.block_count < len(table.blocks) {
		kept := block
		kept.first_span = table.span_count
		table.blocks[table.block_count] = kept
	}
	table.block_count += 1
}

@(private)
table_span :: proc "contextless" (data: rawptr, text: string, span: Span) {
	table := (^Table)(data)
	if table.span_count < len(table.spans) {
		table.spans[table.span_count] = span
	}
	table.span_count += 1
}

// read_into_table reads the Markdown of a source comment into the two
// tables of the caller. It gives true when each block and each span is in
// the tables. Else the tables hold the first ones, and the two counts say
// how many the text has.
//
// ```odin
// blocks: [64]markdown.Block
// spans: [256]markdown.Span
// table := markdown.Table{blocks = blocks[:], spans = spans[:]}
// complete := markdown.read_into_table(text, &table)
// ```
read_into_table :: proc "contextless" (text: string, table: ^Table) -> (complete: bool) {
	table.block_count, table.span_count = 0, 0
	read(text, {data = table, block = table_block, span = table_span})
	return table.block_count <= len(table.blocks) && table.span_count <= len(table.spans)
}
