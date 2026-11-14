package manual

import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import markdown "modus:support/source_comment_markdown"
import module "modus:contract/module"
import "modus:support/system"

// The text of a page: rows of parts. A part of a row is a run of text with
// one font and one color. The facts of a module (its sizes, its imports, the
// signatures of its exports) are values: they are in the font of the cells,
// one part for each row or two. A documentation text is Markdown
// (docs/SITE.md, "The Markdown of a source comment"): its words are in the
// interface font, its code in the font of the cells, and a row is broken
// between two words at the width of the text.

TEXT_WIDTH :: COLUMNS * CELL_WIDTH // The width of the text, in pixels.
LIST_INDENT :: 2 * CELL_WIDTH // The indentation of an item inside an item.
ROW_PART_CAPACITY :: 4096
COLOR_LINK :: 0x6CB4F0

Row_Part_Flag :: enum u8 {
	Row_Start, // The part starts a row. Without it, the part is on the row of the part before.
	Underlined, // A word in italics: the system has no italic face, so a thin line is under it.
	Code_Block, // A row of an example: a band is behind it.
	From_Markdown, // The part comes from a documentation text.
	Opens_A_Page, // A link to a module or to an export of the boot image: a click shows its page.
}
Row_Part_Flags :: bit_set[Row_Part_Flag;u8]

// One run of text of the page. The text is in the file of the module, or
// in built.
Row_Part :: struct {
	text:   string,
	x:      i32, // From the left of the text, in pixels.
	width:  i32, // In the font that draws it, in pixels.
	color:  graphics.Color,
	font:   interface.Font,
	flags:  Row_Part_Flags,
	target: string, // Opens_A_Page: the target of the link.
}

row_parts: [ROW_PART_CAPACITY]Row_Part
row_part_count: int
row_count: int // The rows of the page.

// The export that the next page shows first, and the row of its signature
// on that page, or -1.
wanted_export: string
wanted_row: int

// What the documentation texts of the page hold: the entry checks the page
// of the manual itself with these counts.
Page_Marks :: struct {
	bold, italic, code, items, examples, links, links_that_open: int,
}
page_marks: Page_Marks

// page_clear empties the page.
page_clear :: proc "contextless" () {
	row_part_count, row_count, built_count, first_line = 0, 0, 0, 0
	page_marks = {}
}

row_part_add :: proc "contextless" (part: Row_Part) {
	if row_part_count < ROW_PART_CAPACITY {
		row_parts[row_part_count] = part
		row_part_count += 1
		row_count += int(.Row_Start in part.flags)
	}
}

// put adds a row of one text in the font of the cells, at an indentation
// in cells.
put :: proc "contextless" (text: string, indent: int, color: graphics.Color) {
	cut := text[:min(len(text), max(COLUMNS - indent, 0))]
	row_part_add({text = cut, x = i32(indent * CELL_WIDTH), width = i32(len(cut) * CELL_WIDTH), color = color, flags = {.Row_Start}})
}

// line_join puts the last row on the row before it: a row with two colors.
line_join :: proc "contextless" () {
	if row_part_count >= 2 && .Row_Start in row_parts[row_part_count - 1].flags {
		row_parts[row_part_count - 1].flags -= {.Row_Start}
		row_count -= 1
	}
}

// rows gives the count of rows that the page takes in the window.
rows :: proc "contextless" () -> int {
	return row_count
}

// The font, the color and the signs of a word of a documentation text.
Text_Style :: struct {
	font:   interface.Font,
	color:  graphics.Color,
	flags:  Row_Part_Flags,
	target: string,
}

same_style :: proc "contextless" (first, second: Text_Style) -> bool {
	return first.font == second.font && first.color == second.color && first.flags == second.flags && raw_data(first.target) == raw_data(second.target) && len(first.target) == len(second.target)
}

// One word of the row that is being filled, or a part of a word where its
// style changes.
Piece :: struct {
	text:  string,
	style: Text_Style,
	x:     int,
	width: int,
	glued: bool, // No space is between it and the piece before: the two are one word, and a row is never broken between them.
}

PIECE_CAPACITY :: 128

// The state of the layout of one documentation text.
Flow :: struct {
	base_indent:  int, // The indentation of the text, in pixels.
	color:        graphics.Color, // The color of its plain words.
	left:         int, // Where a row of the block starts.
	space:        int, // The width of the space between two words.
	space_before: bool, // A space is before the next word.
	any_block:    bool, // The text has a block already.
	lines:        bool, // The block is an example: each span is one row, as it is.
	mark_on_row:  bool, // The mark of a list item is on the row that is being filled: the row has its start.
	pieces:       [PIECE_CAPACITY]Piece,
	piece_count:  int,
}
flow: Flow

// A table with no record: the measure of a text reads only its font.
measure_table: interface.Draw_Table

measure :: proc "contextless" (font: interface.Font, text: string) -> int {
	return interface.text_measured_width(&measure_table, font, text)
}

// put_markdown adds the rows of a documentation text, at an indentation in
// cells. No word is cut, unless it is longer than a row; no text is left
// out.
put_markdown :: proc "contextless" (text: string, indent: int, color: graphics.Color) {
	measure_table.interface_font = display.interface_font_of()
	flow.base_indent, flow.color = indent * CELL_WIDTH, color
	flow.left = flow.base_indent
	flow.space = max(measure(interface.FONT_INTERFACE, " "), 2)
	flow.space_before, flow.any_block, flow.lines, flow.mark_on_row = false, false, false, false
	flow.piece_count = 0
	markdown.read(text, {block = markdown_block, span = markdown_span})
	row_flush(flow.piece_count)
}

markdown_block :: proc "contextless" (data: rawptr, text: string, block: markdown.Block) {
	row_flush(flow.piece_count)
	if block.after_empty_line && flow.any_block {
		put("", 0, 0)
	}
	flow.any_block = true
	flow.space_before, flow.mark_on_row = false, false
	flow.lines = block.kind == .Fenced || block.kind == .Example
	indent := flow.base_indent + int(block.depth) * LIST_INDENT
	switch block.kind {
	case .List_Item:
		mark := "-"
		if block.ordered {
			// The label and the period after it.
			mark = text[block.mark_start:min(block.mark_end + 1, len(text))]
		}
		row_part_add({text = mark, x = i32(indent), width = i32(len(mark) * CELL_WIDTH), color = graphics.COLOR_DIM, flags = {.Row_Start, .From_Markdown}})
		flow.left = indent + (len(mark) + 1) * CELL_WIDTH
		flow.mark_on_row = true
		page_marks.items += 1
	case .Paragraph, .Fenced, .Example:
		flow.left = indent + (block.inside_item ? LIST_INDENT : 0)
		page_marks.examples += int(flow.lines)
	}
	// A deep item keeps room for words.
	flow.left = min(flow.left, TEXT_WIDTH - 16 * CELL_WIDTH)
}

markdown_span :: proc "contextless" (data: rawptr, text: string, span: markdown.Span) {
	part := text[span.start:span.end]
	if flow.lines {
		code_line(part)
		return
	}
	style := Text_Style {
		font  = interface.FONT_INTERFACE,
		color = flow.color,
		flags = {.From_Markdown},
	}
	bold := .Bold in span.styles
	switch {
	case .Code in span.styles:
		// Code is a text that a reader copies: the font of the cells.
		style.font = bold ? interface.FONT_BOLD : interface.Font{}
		style.color = COLOR_CODE
		page_marks.code += 1
	case bold:
		style.font = interface.FONT_INTERFACE_BOLD
	}
	page_marks.bold += int(bold)
	if .Italic in span.styles {
		style.flags += {.Underlined}
		page_marks.italic += 1
	}
	if .Link in span.styles {
		style.color = COLOR_LINK
		page_marks.links += 1
		target := text[span.target_start:span.target_end]
		if module_index, _ := link_place(target); module_index >= 0 {
			style.flags += {.Opens_A_Page}
			style.target = target
			page_marks.links_that_open += 1
		}
	}
	index := 0
	for index < len(part) {
		if is_space(part[index]) {
			flow.space_before = true
			index += 1
			continue
		}
		end := index
		for end < len(part) && !is_space(part[end]) {
			end += 1
		}
		word_place(part[index:end], style)
		index = end
	}
}

is_space :: proc "contextless" (character: u8) -> bool {
	return character == ' ' || character == '\n' || character == '\t' || character == '\r'
}

// code_line adds a line of an example as a row, as it is. A line that is
// longer than the row goes on the next rows, broken at a space when it has
// one.
code_line :: proc "contextless" (line: string) {
	columns := max((TEXT_WIDTH - flow.left) / CELL_WIDTH, 1)
	rest := line
	for first := true; first || len(rest) > 0; first = false {
		cut := len(rest)
		if cut > columns {
			cut = columns
			for cut > 0 && rest[cut] != ' ' {
				cut -= 1
			}
			if cut == 0 {
				cut = columns // A word longer than the row.
			}
		}
		row_part_add({text = rest[:cut], x = i32(flow.left), width = i32(cut * CELL_WIDTH), color = COLOR_CODE, flags = {.Row_Start, .Code_Block, .From_Markdown}})
		rest = rest[cut:]
		for len(rest) > 0 && len(rest) < len(line) && rest[0] == ' ' {
			rest = rest[1:]
		}
	}
}

// word_place puts a word on the row that is being filled, or on the next
// row when it does not fit. A word that follows another with no space (a
// bold word and the comma after it) moves to the next row with it. Only a
// word that is longer than a row is cut.
word_place :: proc "contextless" (word: string, style: Text_Style) {
	rest := word
	glued := !flow.space_before && flow.piece_count > 0
	flow.space_before = false
	for len(rest) > 0 {
		if flow.piece_count == PIECE_CAPACITY {
			row_flush(flow.piece_count)
			glued = false
		}
		// A text in the interface font has a limit of bytes: a longer one
		// is drawn in another font than the font that measured it.
		head := rest[:min(len(rest), interface.INTERFACE_TEXT_LIMIT)]
		x := flow.left
		if flow.piece_count > 0 {
			last := flow.pieces[flow.piece_count - 1]
			x = last.x + last.width + (glued ? 0 : flow.space)
		}
		width := measure(style.font, head)
		if x + width <= TEXT_WIDTH {
			flow.pieces[flow.piece_count] = {text = head, style = style, x = x, width = width, glued = glued}
			flow.piece_count += 1
			rest = rest[len(head):]
			glued = true
			continue
		}
		if flow.piece_count > 0 {
			// The first piece of the word that this piece is a part of.
			unit := flow.piece_count
			if glued {
				unit -= 1
				for unit > 0 && flow.pieces[unit].glued {
					unit -= 1
				}
			}
			if unit > 0 {
				row_flush(unit)
				continue
			}
		}
		// The word is longer than a row: it is cut where the row ends.
		fit := interface.text_fit(&measure_table, style.font, head, TEXT_WIDTH - x)
		if len(fit) == 0 {
			if flow.piece_count > 0 {
				row_flush(flow.piece_count)
				glued = false
				continue
			}
			fit = head[:1]
		}
		flow.pieces[flow.piece_count] = {text = fit, style = style, x = x, width = measure(style.font, fit), glued = glued}
		flow.piece_count += 1
		rest = rest[len(fit):]
		glued = true
		if len(rest) > 0 {
			row_flush(flow.piece_count)
			glued = false
		}
	}
}

// row_flush ends the row with the first `count` pieces, and starts the next
// row with the others. Pieces of one style that follow each other in the
// text with one space between them are one part of the row: one record of text for
// the frame, and the font spaces their letters as one text.
row_flush :: proc "contextless" (count: int) {
	if count <= 0 {
		return
	}
	x := flow.pieces[0].x
	index := 0
	for index < count {
		piece := flow.pieces[index]
		if index > 0 && !piece.glued {
			x += flow.space
		}
		merged := piece.text
		index += 1
		for index < count {
			next := flow.pieces[index]
			gap := next.glued ? 0 : 1
			if !same_style(next.style, piece.style) || len(merged) + gap + len(next.text) > interface.INTERFACE_TEXT_LIMIT {
				break
			}
			if uintptr(raw_data(next.text)) != uintptr(raw_data(merged)) + uintptr(len(merged) + gap) {
				break
			}
			// The byte between the two is in the text: the next piece is
			// after it.
			if gap == 1 && raw_data(merged)[len(merged)] != ' ' {
				break
			}
			merged = string(raw_data(merged)[:len(merged) + gap + len(next.text)])
			index += 1
		}
		width := measure(piece.style.font, merged)
		flags := piece.style.flags
		if !flow.mark_on_row {
			flags += {.Row_Start}
		}
		flow.mark_on_row = true // The row has its start: the next parts are on it.
		row_part_add({text = merged, x = i32(x), width = i32(width), color = piece.style.color, font = piece.style.font, flags = flags, target = piece.style.target})
		x += width
	}
	flow.mark_on_row = false
	kept := flow.piece_count - count
	if kept > 0 {
		shift := flow.pieces[count].x - flow.left
		for place in 0 ..< kept {
			flow.pieces[place] = flow.pieces[count + place]
			flow.pieces[place].x -= shift
		}
		flow.pieces[0].glued = false
	}
	flow.piece_count = kept
}

// link_place gives the module of the boot image that the target of a link
// names, and the export of it, or -1. A target is the name of a module
// ("math") or a module and its export ("manual.show"). A term, a guide, a
// declaration and a kernel operation have no page in the system.
link_place :: proc "contextless" (target: string) -> (index: int, export: string) {
	name := target
	for character, place in target {
		if character == '.' {
			name, export = target[:place], target[place + 1:]
			break
		}
	}
	if len(export) > 2 && export[len(export) - 2:] == "()" {
		export = export[:len(export) - 2]
	}
	index = find(name)
	if index < 0 {
		return -1, ""
	}
	file := file_of(&system.image_entries(image)[index])
	if file == nil {
		return -1, ""
	}
	if export == "" {
		return index, ""
	}
	head, _ := module.header(file)
	for export_index in 1 ..< module.count(file, .Exports) {
		function, ok := module.function(file, export_index)
		if ok && export_index != head.entry_export && function.name_count != 0 && module.string_at(file, function.name_offset, function.name_count) == export {
			return index, export
		}
	}
	return -1, ""
}

// link_at_place gives the target of the link that opens a page at a place
// of the window, or "".
link_at_place :: proc "contextless" (x, y: int) -> string {
	left := LIST_WIDTH + MARGIN
	if y < MARGIN || y >= MARGIN + ROWS * CELL_HEIGHT {
		return ""
	}
	wanted := first_line + (y - MARGIN) / CELL_HEIGHT
	row := -1
	for &part in row_parts[:row_part_count] {
		row += int(.Row_Start in part.flags)
		if row > wanted {
			break
		}
		if row == wanted && .Opens_A_Page in part.flags && x >= left + int(part.x) && x < left + int(part.x + part.width) {
			return part.target
		}
	}
	return ""
}

// link_open shows the page that the target of a link names: the page of
// the module, from the signature of the export when the link names one.
link_open :: proc "contextless" (target: string) {
	index, export := link_place(target)
	if index < 0 {
		return
	}
	// The bytes of the name are in the boot image: they stay when the page
	// changes.
	wanted_export = export
	select(index)
	wanted_export = ""
	if wanted_row >= 0 {
		first_line = clamp(wanted_row, 0, max(rows() - ROWS, 0))
	}
	page_log()
}

// markdown_check checks the documentation texts of the page that the
// window shows, and writes the result on the log. The entry runs it on the
// page of the manual itself, whose comments use each of these marks.
markdown_check :: proc "contextless" () {
	widest := 0
	marks_left := 0
	for &part in row_parts[:row_part_count] {
		if .From_Markdown not_in part.flags {
			continue
		}
		widest = max(widest, int(part.x + part.width))
		if part.font.kind != .Interface {
			continue // Code keeps its signs.
		}
		for character, place in part.text {
			if character == '`' || character == '*' && place + 1 < len(part.text) && part.text[place + 1] == '*' {
				marks_left += 1
			}
		}
	}
	marks := page_marks
	if marks.bold > 0 && marks.italic > 0 && marks.code > 0 && marks.items > 0 && marks.links_that_open > 0 && marks_left == 0 && widest <= TEXT_WIDTH {
		system.log("manual: the Markdown of its page: bold, italics, code, list items and links that open a page; no mark is left and no row passes the window: as it must")
		return
	}
	system.log("manual: the Markdown of its page: FAILED: ", u64(marks.bold), " bold, ", u64(marks.italic), " italics, ", u64(marks.code), " code, ", u64(marks.items), " list items, ", u64(marks.links_that_open), " links that open a page of ", u64(marks.links), ", ", u64(marks_left), " marks left, the widest row ", u64(widest), " of ", u64(TEXT_WIDTH), " pixels")
}
