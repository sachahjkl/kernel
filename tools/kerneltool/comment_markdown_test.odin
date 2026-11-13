package kerneltool

import "core:strings"
import "core:testing"

// A comment that uses each construct of the subset.
@(private = "file")
COMMENT_WITH_EACH_CONSTRUCT :: "Seals a **text** with a *key*, as [the seal](system.word_wait) says. The second sentence.\nIt continues the paragraph.\n\n- `key`: 32 bytes;\n- `nonce`: 12 bytes, which\nnever repeat;\n  - a nested item.\n\n1. the first result;\n2. the second result.\n\n```odin\nx := seal(&key)\n```\n\n  a line   kept as it is"

// The text that a module carries: the marks go, the structure stays as
// plain lines, a code span keeps its backticks, and the first sentence is
// the first sentence with no mark.
@(test)
comment_markdown_text_that_a_module_carries :: proc(t: ^testing.T) {
	text := documentation_text_of_markdown(COMMENT_WITH_EACH_CONSTRUCT)
	expected := "Seals a text with a key, as the seal says. The second sentence. It continues the paragraph.\n\n- `key`: 32 bytes;\n- `nonce`: 12 bytes, which never repeat;\n  - a nested item.\n\n1. the first result;\n2. the second result.\n\n    x := seal(&key)\n\n  a line   kept as it is"
	testing.expect_value(t, text, expected)
	testing.expect_value(t, about_of(text, ""), "Seals a text with a key, as the seal says")
	testing.expect_value(t, markdown_first_sentence(COMMENT_WITH_EACH_CONSTRUCT), "Seals a text with a key, as the seal says")
	// A help line: the name of the export at its start goes, after the marks.
	testing.expect_value(t, about_of(documentation_text_of_markdown("**seal** gives a *sealed* text. More."), "seal"), "gives a sealed text")
	// A comment with no mark: its lines join, as before.
	testing.expect_value(t, documentation_text_of_markdown("A plain comment\non two lines.\n\nA second paragraph."), "A plain comment on two lines.\n\nA second paragraph.")
}

// The plain text of a line: a star of an expression stays; italics, bold
// and links go; code keeps its backticks or not.
@(test)
comment_markdown_inline_plain_text :: proc(t: ^testing.T) {
	testing.expect_value(t, markdown_inline_plain("a * b and 2*3*4", true), "a * b and 2*3*4")
	testing.expect_value(t, markdown_inline_plain("an *italic* and a **bold** word", true), "an italic and a bold word")
	testing.expect_value(t, markdown_inline_plain("`*x*` and [a link](term:handle)", true), "`*x*` and a link")
	testing.expect_value(t, markdown_inline_plain("`*x*` and [a link](term:handle)", false), "*x* and a link")
	testing.expect_value(t, markdown_inline_plain("[n % CAPACITY] and [x]", true), "[n % CAPACITY] and [x]")
	testing.expect_value(t, markdown_inline_plain("two\nlines", true), "two lines")
}

// A line of an Odin source as a line of the Markdown of its comment: the
// marker and one space go, the indentation after them stays.
@(test)
comment_markdown_line_of_a_source :: proc(t: ^testing.T) {
	code, comment, is_comment := markdown_comment_line("\tName = 3, // (a, b) -> c.")
	testing.expect(t, code == "Name = 3," && comment == "(a, b) -> c." && is_comment)
	_, nested, _ := markdown_comment_line("\t//   - a nested item")
	testing.expect_value(t, nested, "  - a nested item")
	_, empty, empty_is_comment := markdown_comment_line("\t//")
	testing.expect(t, empty == "" && empty_is_comment)
	_, _, not_comment := markdown_comment_line("x := \"// not a comment\"")
	testing.expect(t, !not_comment)
}

@(private = "file")
render_comment :: proc(site: ^Site, markdown: string, form: Site_Comment_Form = .Paragraphs) -> string {
	return site_source_comment_html(site, "docs/reference/operations/index.html", markdown, form)
}

// The renderer in its mode for comments: each construct of the subset,
// and the constructs that a comment does not have, which stay text.
@(test)
comment_markdown_renders_each_construct :: proc(t: ^testing.T) {
	site := test_site()
	emphasis := render_comment(&site, "A **bold** and an *italic* word, with `code`.")
	testing.expect_value(t, emphasis, "<p>A <strong>bold</strong> and an <em>italic</em> word, with <code>code</code>.</p>\n")
	testing.expect_value(t, render_comment(&site, "a * b and 2*3"), "<p>a * b and 2*3</p>\n")
	list := render_comment(&site, "- a\n- b, which\ncontinues\n  - nested")
	testing.expect(t, strings.contains(list, "<ul>\n<li>a</li>\n<li>b, which continues<ul>\n<li>nested</li>\n</ul>\n</li>\n</ul>\n"), list)
	ordered := render_comment(&site, "1. one\n2. two")
	testing.expect(t, strings.contains(ordered, "<ol class=\"labelled\">") && strings.contains(ordered, "<span class=\"label\">2.</span> two"), ordered)
	testing.expect(t, !strings.contains(ordered, " id=\""), "an item of a comment has an id")
	fence := render_comment(&site, "```\nx := 1\n```")
	testing.expect(t, strings.contains(fence, "<pre><code>") && strings.contains(fence, "<span class=\"c-"), fence)
	other_language := render_comment(&site, "```sh\nls -l\n```")
	testing.expect(t, strings.contains(other_language, "<pre><code>ls -l\n</code></pre>"), other_language)
	example := render_comment(&site, "A table:\n  up     the module before\n  down   the module after")
	testing.expect_value(t, example, "<p>A table:</p>\n<pre><code>up     the module before\ndown   the module after\n</code></pre>\n")
	// Not in a comment: a heading, a table, a quote, a line of HTML and a
	// picture are words of a paragraph.
	refused := render_comment(&site, "# Not a heading\n\n| a | b |\n|---|---|\n\n> no quote\n\n<b>no HTML</b> and ![no picture](picture.png)")
	testing.expect(t, strings.contains(refused, "<p># Not a heading</p>"), refused)
	testing.expect(t, strings.contains(refused, "<p>| a | b | |---|---|</p>"), refused)
	testing.expect(t, strings.contains(refused, "<p>&gt; no quote</p>"), refused)
	testing.expect(t, strings.contains(refused, "&lt;b&gt;no HTML&lt;/b&gt; and !"), refused)
	testing.expect(t, !strings.contains(refused, "<h1") && !strings.contains(refused, "<table") && !strings.contains(refused, "<blockquote") && !strings.contains(refused, "<img"), refused)
	// No term of the glossary links by itself in a comment.
	testing.expect(t, !strings.contains(render_comment(&site, "A Module here."), "class=\"term\""), "a term links in a comment")
	// A comment with no mark renders as before: a line in a cell, paragraphs
	// on a page.
	testing.expect_value(t, render_comment(&site, "Maps <memory>\nof a program.", .Line), "Maps &lt;memory&gt; of a program.")
	testing.expect_value(t, render_comment(&site, "One.\n\nTwo.", .Paragraphs), "<p>One.</p>\n<p>Two.</p>\n")
	// A cell with a list holds blocks.
	testing.expect(t, strings.has_prefix(render_comment(&site, "Kinds:\n\n- a\n- b", .Line), "<p>Kinds:</p>\n<ul>"), "a list in a cell is not a list")
}

// The site of the tests of the links: a guide with headings, a term, a row
// of a reference table, a module with an export, and declarations of two
// packages.
@(private = "file")
link_test_site :: proc() -> Site {
	site := reference_test_site()
	site.code_links = make(map[string]string, context.temp_allocator)
	site.code_links["Memory_Map"] = "docs/reference/operations/index.html#operation-memory-map"
	exports := make([]Export_Description, 1, context.temp_allocator)
	exports[0] = {name = "edges"}
	modules := make([]Site_Module, 1, context.temp_allocator)
	modules[0] = {build = {name = "manual", source = "programs/manual"}, kind = "program", page = site_module_page("manual"), description = {exports = exports}}
	site.reference.modules = modules
	site.declarations = site_declaration_index_make()
	sources := [2][2]string {
		{"support/system/link_test_source.odin", "package system\n\n// Waits on a word.\nword_wait :: proc() {}\n\ncount :: proc() {}\n"},
		{"kernel/link_test_source.odin", "package kernel\n\nfault_deliver :: proc() {}\n\ncount :: proc() {}\n"},
	}
	for source in sources {
		found, parsed := site_declarations_of_file(source[0], source[1])
		if !parsed {
			continue
		}
		for declaration in found {
			site_declaration_add(&site.declarations, declaration)
		}
	}
	return site
}

// Each form of a target of a link, and each target that names nothing.
@(test)
comment_markdown_link_targets :: proc(t: ^testing.T) {
	site := link_test_site()
	expect_page :: proc(t: ^testing.T, of_site: ^Site, target, page: string) {
		link, problem := site_comment_link_target(of_site, target)
		testing.expectf(t, problem == "" && link.kind == .Page && link.address == page, "%s: %v, %q", target, link, problem)
	}
	address, address_problem := site_comment_link_target(&site, "https://example.org/x")
	testing.expect(t, address_problem == "" && address.kind == .Address, address_problem)
	term, term_problem := site_comment_link_target(&site, "term:module")
	testing.expect(t, term_problem == "" && term.kind == .Term && term.address == "docs/reference/glossary/index.html#term-module", term_problem)
	expect_page(t, &site, "docs/ARCHITECTURE.md", "docs/guides/ARCHITECTURE/index.html")
	expect_page(t, &site, "docs/ARCHITECTURE.md#kernel-systems", "docs/guides/ARCHITECTURE/index.html#kernel-systems")
	expect_page(t, &site, "Memory_Map", "docs/reference/operations/index.html#operation-memory-map")
	expect_page(t, &site, "manual.edges", "docs/reference/modules/manual/index.html#export-edges")
	declaration, declaration_problem := site_comment_link_target(&site, "system.word_wait")
	testing.expect(t, declaration_problem == "" && declaration.kind == .Declaration, declaration_problem)
	unqualified, unqualified_problem := site_comment_link_target(&site, "fault_deliver")
	testing.expect(t, unqualified_problem == "" && unqualified.kind == .Declaration, unqualified_problem)
	for target in ([]string{"term:nothing", "docs/ARCHITECTURE.md#no-such-heading", "docs/NOPE.md", "docs/HANDOFF.md", "manual.nothing", "count", "nothing_at_all", "a b"}) {
		_, problem := site_comment_link_target(&site, target)
		testing.expectf(t, problem != "", "the target %s names something", target)
	}
	// The markup: a link with its own text; a declaration has its card.
	html := render_comment(&site, "See [the ring](docs/ARCHITECTURE.md#kernel-systems), [a **wait**](system.word_wait), [a module](term:module) and [the site](https://example.org).")
	testing.expect(t, strings.contains(html, "<a class=\"term\" href=\"../../../docs/reference/glossary/index.html#term-module\">a module</a>"), html)
	testing.expect(t, strings.contains(html, "<a href=\"../../../docs/guides/ARCHITECTURE/index.html#kernel-systems\">the ring</a>"), html)
	testing.expect(t, strings.contains(html, "data-declaration-card=\"declaration-") && strings.contains(html, "<strong>wait</strong></a>"), html)
	testing.expect(t, strings.contains(html, "<a href=\"https://example.org\">the site</a>"), html)
	// The target of a link is not a pointer to a document.
	testing.expect_value(t, len(site_document_pointers("[the ring](docs/ARCHITECTURE.md#kernel-systems)")), 0)
}

// The check of the links names the file and the line of a link that names
// nothing; a link in a code span is code, and a link that resolves gives no
// fault.
@(test)
comment_markdown_link_check :: proc(t: ^testing.T) {
	site := link_test_site()
	source := "x :: 1\n// Fine: [the export](manual.edges), and `[code](not_a_link)`.\n// Wrong: [a word](nothing_at_all).\ny :: 2 // [a guide](docs/ARCHITECTURE.md#nope)\n"
	problems := site_comment_link_problems(&site, "a.odin", source)
	testing.expectf(t, len(problems) == 2, "%v", problems)
	if len(problems) == 2 {
		testing.expect(t, strings.has_prefix(problems[0], "a.odin, line 3: the link to nothing_at_all names nothing"), problems[0])
		testing.expect(t, strings.has_prefix(problems[1], "a.odin, line 4: "), problems[1])
	}
}

// The marks of Markdown do not trip the check of the comments, and a
// breach in bold or in a list item is still a breach.
@(test)
comment_markdown_and_the_comment_rules :: proc(t: ^testing.T) {
	exempt := make(map[string]string, context.temp_allocator)
	marked := "// **Bold**, *italic*, [the fault ring](docs/ARCHITECTURE.md#the-fault-ring), `code`.\n//\n// - an item\n//   - a nested item\n// 1. a first result\n//\n// ```odin\n// x := 1\n// ```\n"
	testing.expect_value(t, len(comment_rule_breaches_of_source("a.odin", marked, exempt)), 0)
	testing.expect_value(t, len(comment_rule_breaches_of_source("a.odin", "// **the caller owns it (property 14)**\n", exempt)), 1)
	testing.expect_value(t, len(comment_rule_breaches_of_source("a.odin", "// - a choice (choice 186)\n", exempt)), 1)
}

// The form of an operation can run over two lines of its comment, and its
// text is Markdown after it.
@(test)
comment_markdown_operation_over_lines :: proc(t: ^testing.T) {
	operation := site_operation_parts(Site_Enumeration_Member{name = "Do", comment = "(a,\nb) -> the\ncount.\n**More** text.\n\n- an item"})
	testing.expect_value(t, operation.parameters, "a, b")
	testing.expect_value(t, operation.result, "the count")
	testing.expect_value(t, operation.text, "**More** text.\n\n- an item")
	members, problem := site_enumeration_read("Thing :: enum u8 {\n\tA = 4, // The first.\n\t//\n\t// - an item\n\t//   that continues\n}\n", "file.odin", "Thing")
	testing.expect_value(t, problem, "")
	if len(members) == 1 {
		testing.expect_value(t, members[0].comment, "The first.\n\n- an item\n  that continues")
	}
}
