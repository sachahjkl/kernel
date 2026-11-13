#+build !freestanding
package source_comment_markdown

import "core:fmt"
import "core:strings"
import "core:testing"

// shown gives the blocks and the spans of a text as one line, so that a
// test compares the whole reading with one text.
//
// A block is "[P]" (a paragraph), "[I0 -]" (a list item: its depth and its
// mark), "[F odin]" (a fenced block and its language) or "[E]" (an
// example). "+" before it: an empty line is before the block. "^0" in it:
// the block is inside a list item of that depth. A span is "{styles:text}",
// with the letters b (bold), i (italic), c (code) and l (link), and "->"
// with the target of a link.
@(private = "file")
shown :: proc(text: string) -> string {
	blocks: [64]Block
	spans: [256]Span
	table := Table {
		blocks = blocks[:],
		spans  = spans[:],
	}
	if !read_into_table(text, &table) {
		return "the table is too small"
	}
	b := strings.builder_make(context.temp_allocator)
	for block, index in blocks[:table.block_count] {
		if block.after_empty_line {
			strings.write_string(&b, "+")
		}
		switch block.kind {
		case .Paragraph:
			strings.write_string(&b, "[P")
		case .List_Item:
			fmt.sbprintf(&b, "[I%d %s", block.depth, text[block.mark_start:block.mark_end])
		case .Fenced:
			strings.write_string(&b, "[F")
			if block.language_end > block.language_start {
				fmt.sbprintf(&b, " %s", text[block.language_start:block.language_end])
			}
		case .Example:
			strings.write_string(&b, "[E")
		}
		if block.inside_item {
			fmt.sbprintf(&b, "^%d", block.depth)
		}
		strings.write_string(&b, "]")
		last := index + 1 < table.block_count ? blocks[index + 1].first_span : table.span_count
		for span in spans[block.first_span:last] {
			strings.write_string(&b, "{")
			for letter, style in ([Style]string{.Bold = "b", .Italic = "i", .Code = "c", .Link = "l"}) {
				if style in span.styles {
					strings.write_string(&b, letter)
				}
			}
			fmt.sbprintf(&b, ":%s", text[span.start:span.end])
			if .Link in span.styles {
				fmt.sbprintf(&b, "->%s", text[span.target_start:span.target_end])
			}
			strings.write_string(&b, "}")
		}
	}
	return strings.to_string(b)
}

// The comment of the tests of the tool that uses each construct of the
// subset (tools/kerneltool/comment_markdown_test.odin).
@(private = "file")
COMMENT_WITH_EACH_CONSTRUCT :: "Seals a **text** with a *key*, as [the seal](system.word_wait) says. The second sentence.\nIt continues the paragraph.\n\n- `key`: 32 bytes;\n- `nonce`: 12 bytes, which\nnever repeat;\n  - a nested item.\n\n1. the first result;\n2. the second result.\n\n```odin\nx := seal(&key)\n```\n\n  a line   kept as it is"

@(test)
reads_each_construct :: proc(t: ^testing.T) {
	expected :=
		"[P]{:Seals a }{b:text}{: with a }{i:key}{:, as }{l:the seal->system.word_wait}{: says. The second sentence.\nIt continues the paragraph.}" +
		"+[I0 -]{c:key}{:: 32 bytes;}" +
		"[I0 -]{c:nonce}{:: 12 bytes, which\nnever repeat;}" +
		"[I1 -]{:a nested item.}" +
		"+[I0 1]{:the first result;}" +
		"[I0 2]{:the second result.}" +
		"+[F odin]{c:x := seal(&key)}" +
		"+[E]{c:a line   kept as it is}"
	testing.expect_value(t, shown(COMMENT_WITH_EACH_CONSTRUCT), expected)
}

// The inputs of the tests of the renderer of the site in its mode for
// comments: the same marks give the same reading.
@(test)
reads_the_inputs_of_the_site :: proc(t: ^testing.T) {
	testing.expect_value(t, shown("A **bold** and an *italic* word, with `code`."), "[P]{:A }{b:bold}{: and an }{i:italic}{: word, with }{c:code}{:.}")
	// A star of an expression is a star.
	testing.expect_value(t, shown("a * b and 2*3"), "[P]{:a * b and 2*3}")
	testing.expect_value(t, shown("a * b and 2*3*4"), "[P]{:a * b and 2*3*4}")
	testing.expect_value(t, shown("- a\n- b, which\ncontinues\n  - nested"), "[I0 -]{:a}[I0 -]{:b, which\ncontinues}[I1 -]{:nested}")
	testing.expect_value(t, shown("1. one\n2. two"), "[I0 1]{:one}[I0 2]{:two}")
	testing.expect_value(t, shown("```\nx := 1\n```"), "[F]{c:x := 1}")
	testing.expect_value(t, shown("```sh\nls -l\n```"), "[F sh]{c:ls -l}")
	testing.expect_value(t, shown("A table:\n  up     the module before\n  down   the module after"), "[P]{:A table:}[E]{c:up     the module before}{c:down   the module after}")
	// A heading, a table, a quote, a line of HTML and a picture are words
	// of a paragraph.
	refused := "# Not a heading\n\n| a | b |\n|---|---|\n\n> no quote\n\n<b>no HTML</b> and ![no picture](picture.png)"
	testing.expect_value(t, shown(refused), "[P]{:# Not a heading}+[P]{:| a | b |\n|---|---|}+[P]{:> no quote}+[P]{:<b>no HTML</b> and !}{l:no picture->picture.png}")
	// A code span holds its marks, and brackets with no target are text.
	testing.expect_value(t, shown("`*x*` and [a link](term:handle)"), "[P]{c:*x*}{: and }{l:a link->term:handle}")
	testing.expect_value(t, shown("[n % CAPACITY] and [x]"), "[P]{:[n % CAPACITY] and [x]}")
	// The label of a link has its own bold and code.
	testing.expect_value(t, shown("[a **wait**](system.word_wait) and [`Module`](information.Module)"), "[P]{l:a ->system.word_wait}{bl:wait->system.word_wait}{: and }{cl:Module->information.Module}")
}

@(test)
reads_lists :: proc(t: ^testing.T) {
	// Bold and code inside an item, and an item inside it.
	testing.expect_value(t, shown("- an item with **bold and `code` inside**\n  - **deep** *nested*"), "[I0 -]{:an item with }{b:bold and }{bc:code}{b: inside}[I1 -]{b:deep}{: }{i:nested}")
	// The marks: a star, a label with a letter; a number of five digits is
	// not a mark, so its line continues the item.
	testing.expect_value(t, shown("* star\n34b. label\n12345. not"), "[I0 *]{:star}[I0 34b]{:label\n12345. not}")
	// A fenced block inside an item, and the text of the item after it.
	testing.expect_value(t, shown("- an item:\n  ```\n  x := 1\n  ```\n  after the code\n- next"), "[I0 -]{:an item:}[F^0]{c:x := 1}[P^0]{:after the code}[I0 -]{:next}")
	// After an empty line, a list goes on with an item or an indented line.
	testing.expect_value(t, shown("- a\n\nA paragraph."), "[I0 -]{:a}+[P]{:A paragraph.}")
	testing.expect_value(t, shown("- a\n\n  still a"), "[I0 -]{:a\n\n  still a}")
	testing.expect_value(t, shown("- a\n\n- b"), "[I0 -]{:a}+[I0 -]{:b}")
	// The depth comes back.
	testing.expect_value(t, shown("- a\n  - b\n    - c\n  - d\n- e"), "[I0 -]{:a}[I1 -]{:b}[I2 -]{:c}[I1 -]{:d}[I0 -]{:e}")

	blocks: [4]Block
	spans: [4]Span
	table := Table {
		blocks = blocks[:],
		spans  = spans[:],
	}
	testing.expect(t, read_into_table("1. one\n- two", &table))
	testing.expect(t, table.block_count == 2 && blocks[0].ordered && !blocks[1].ordered)
}

// A mark with no end is text, with its signs.
@(test)
a_mark_with_no_end_is_text :: proc(t: ^testing.T) {
	testing.expect_value(t, shown("a **bold with no end"), "[P]{:a **bold with no end}")
	testing.expect_value(t, shown("a `code with no end"), "[P]{:a `code with no end}")
	testing.expect_value(t, shown("an *italic with no end"), "[P]{:an *italic with no end}")
	testing.expect_value(t, shown("a [link](with no end"), "[P]{:a [link](with no end}")
	testing.expect_value(t, shown("a [link](target"), "[P]{:a [link](target}")
	testing.expect_value(t, shown("[label] (x) and [](x) and [x]()"), "[P]{:[label] (x) and [](x) and [x]()}")
	// A code span ends the search for the end of italics: its star is code.
	testing.expect_value(t, shown("**two\nlines** and *a `b*` c"), "[P]{b:two\nlines}{: and *a }{c:b*}{: c}")
	// A fence with no end runs to the end of the text.
	testing.expect_value(t, shown("```\ncode\nmore"), "[F]{c:code}{c:more}")
}

// The target of a link can hold pairs of parentheses: the name of a command
// of the console.
@(test)
a_target_with_parentheses :: proc(t: ^testing.T) {
	testing.expect_value(t, shown("See [the command](load()) and [x](a(b(c))d)."), "[P]{:See }{l:the command->load()}{: and }{l:x->a(b(c))d}{:.}")
	testing.expect_value(t, shown("([in parentheses](manual.show))"), "[P]{:(}{l:in parentheses->manual.show}{:)}")
}

@(test)
an_empty_text_has_no_block :: proc(t: ^testing.T) {
	testing.expect_value(t, shown(""), "")
	testing.expect_value(t, shown("\n\n  \n"), "")
	// With no procedure, the reader reads and gives nothing.
	read("A **text**.", {})
}

// A very long word is one span: the reader of the blocks does not cut a
// text. A long run of marks with no end is read once.
@(test)
a_very_long_word :: proc(t: ^testing.T) {
	word := strings.repeat("x", 5000, context.temp_allocator)
	blocks: [2]Block
	spans: [2]Span
	table := Table {
		blocks = blocks[:],
		spans  = spans[:],
	}
	testing.expect(t, read_into_table(word, &table))
	testing.expect(t, table.block_count == 1 && table.span_count == 1 && spans[0].start == 0 && spans[0].end == 5000 && spans[0].styles == Styles{})
	for marks in ([]string{"*a ", "**", "[", "[a](", "`a` *b ", "](("}) {
		hostile := strings.repeat(marks, 20000, context.temp_allocator)
		read_into_table(hostile, &table)
		testing.expectf(t, table.block_count >= 1, "%q repeated gives no block", marks)
	}
}

// A table that is too small holds the first blocks and spans, and the
// counts say how many the text has.
@(test)
a_table_that_is_too_small :: proc(t: ^testing.T) {
	blocks: [1]Block
	spans: [1]Span
	table := Table {
		blocks = blocks[:],
		spans  = spans[:],
	}
	testing.expect(t, !read_into_table("A **bold** and an *italic* word, with `code`.", &table))
	testing.expect_value(t, table.block_count, 1)
	testing.expect_value(t, table.span_count, 7)
	testing.expect(t, spans[0].start == 0 && spans[0].end == 2)
	testing.expect(t, !read_into_table("- a\n- b", &table))
	testing.expect_value(t, table.block_count, 2)
}
