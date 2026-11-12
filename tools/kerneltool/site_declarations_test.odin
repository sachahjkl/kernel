package kerneltool

import "core:fmt"
import "core:strings"
import "core:testing"

// A file of a package "graphics": a procedure with a comment, a constant, a
// type, a global variable, a procedure inside a "when", and a name that a
// second package declares too.
@(private = "file")
SOURCE_OF_GRAPHICS :: "package graphics\n\n// Blend a row of coverage in order. It is slow.\nblend_row :: proc(row: []u8, alpha: u8) -> int {\n\treturn 0\n}\n\n// The size of a page.\nPAGE_SIZE :: 4096\n\n// A point of the screen.\nPoint :: struct {\n\tx, y: i32, // Its place.\n}\n\ncounter: int\n\nwhen ODIN_ARCH == .amd64 {\n\t// The wide form.\n\tblend_row_wide :: proc() {}\n}\n\nshared_name :: proc() {}\n"

// A file of a package "console": the same name as in graphics, and a name
// that is a common word.
@(private = "file")
SOURCE_OF_CONSOLE :: "package console\n\nshared_name :: proc(x: int) {}\n\ncount :: proc() -> int {\n\treturn 0\n}\n"

@(private = "file")
GRAPHICS_FILE :: "support/graphics/blend_test_source.odin"
@(private = "file")
CONSOLE_FILE :: "programs/console/count_test_source.odin"

// The index of the two files above, in a site of the tests.
@(private = "file")
declaration_test_site :: proc() -> Site {
	site := test_site()
	site.declarations = site_declaration_index_make()
	for file in ([][2]string{{GRAPHICS_FILE, SOURCE_OF_GRAPHICS}, {CONSOLE_FILE, SOURCE_OF_CONSOLE}}) {
		found, parsed := site_declarations_of_file(file[0], file[1])
		if !parsed {
			continue
		}
		for declaration in found {
			site_declaration_add(&site.declarations, declaration)
		}
	}
	return site
}

// The place of a declaration in the index of the tests, by its name and
// its package, or -1.
@(private = "file")
place_of :: proc(site: ^Site, name, package_name: string) -> int {
	for declaration, place in site.declarations.declarations {
		if declaration.name == name && declaration.package_name == package_name {
			return place
		}
	}
	return -1
}

// The index: each kind of declaration with its package, its folder, its
// line, its one line and the first sentence of its comment; a declaration
// inside a "when"; a name that two packages declare.
@(test)
site_declaration_index_of_two_files :: proc(t: ^testing.T) {
	_, parsed := site_declarations_of_file(GRAPHICS_FILE, SOURCE_OF_GRAPHICS)
	testing.expect(t, parsed, "the parser refuses the file of the test")
	site := declaration_test_site()
	testing.expect_value(t, len(site.declarations.declarations), 8)
	Expected :: struct {
		name, package_name: string,
		kind:               Site_Declaration_Kind,
		line:               int,
		signature:          string,
		first_sentence:     string,
	}
	expected := [?]Expected {
		{"blend_row", "graphics", .Procedure, 4, "blend_row :: proc(row: []u8, alpha: u8) -> int", "Blend a row of coverage in order"},
		{"PAGE_SIZE", "graphics", .Constant, 9, "PAGE_SIZE :: 4096", "The size of a page"},
		{"Point", "graphics", .Type, 12, "Point :: struct {...}", "A point of the screen"},
		{"counter", "graphics", .Variable, 16, "counter: int", ""},
		{"blend_row_wide", "graphics", .Procedure, 20, "blend_row_wide :: proc()", "The wide form"},
		{"shared_name", "graphics", .Procedure, 23, "shared_name :: proc()", ""},
		{"shared_name", "console", .Procedure, 3, "shared_name :: proc(x: int)", ""},
		{"count", "console", .Procedure, 5, "count :: proc() -> int", ""},
	}
	for item in expected {
		place := place_of(&site, item.name, item.package_name)
		testing.expectf(t, place >= 0, "the index has no %s of %s", item.name, item.package_name)
		if place < 0 {
			continue
		}
		declaration := site.declarations.declarations[place]
		testing.expectf(t, declaration.kind == item.kind, "%s: the kind %v, not %v", item.name, declaration.kind, item.kind)
		testing.expectf(t, declaration.line == item.line, "%s: the line %d, not %d", item.name, declaration.line, item.line)
		testing.expectf(t, declaration.signature == item.signature, "%s: the line of Odin %q, not %q", item.name, declaration.signature, item.signature)
		testing.expectf(t, declaration.first_sentence == item.first_sentence, "%s: the first sentence %q, not %q", item.name, declaration.first_sentence, item.first_sentence)
	}
	graphics_place := place_of(&site, "blend_row", "graphics")
	if graphics_place >= 0 {
		testing.expect_value(t, site.declarations.declarations[graphics_place].folder, "support/graphics")
		testing.expect_value(t, site.declarations.declarations[graphics_place].file, GRAPHICS_FILE)
	}
	testing.expect_value(t, len(site.declarations.by_name["shared_name"]), 2)
	testing.expect(t, "graphics" in site.declarations.packages && "console" in site.declarations.packages)
	testing.expect(t, "support/graphics" in site.declarations.folders)
	// A file that the parser refuses gives no declaration.
	_, refused := site_declarations_of_file("support/x/broken.odin", "package x\n\nbroken :: proc( {\n")
	testing.expect(t, !refused, "the parser accepts a broken file")
	// One line: no comment, no space inside the brackets, no comma before
	// a closing bracket.
	long := site_declaration_one_line("name :: proc(a: int, // one\n\tb: int,\n)")
	testing.expect_value(t, long, "name :: proc(a: int, b: int)")
}

// The forms of a span: a name, "name()", "package.name", "package.name()";
// a file name, a keyword, a built-in type and two words are not names.
@(test)
site_declaration_span_forms :: proc(t: ^testing.T) {
	span, is_name := site_declaration_span_read("blend_row")
	testing.expect(t, is_name && span.name == "blend_row" && span.qualifier == "" && !span.called)
	span, is_name = site_declaration_span_read("blend_row()")
	testing.expect(t, is_name && span.name == "blend_row" && span.called)
	span, is_name = site_declaration_span_read("graphics.blend_row")
	testing.expect(t, is_name && span.qualifier == "graphics" && span.name == "blend_row")
	span, is_name = site_declaration_span_read("graphics.blend_row()")
	testing.expect(t, is_name && span.qualifier == "graphics" && span.called)
	for text in ([]string{"boot.image", "flake.nix", "u64", "proc", "bit_set", "a b", "f(x)", "", "3d", "a.b.c"}) {
		_, is_name = site_declaration_span_read(text)
		testing.expectf(t, !is_name, "%q is read as a name", text)
	}

	site := declaration_test_site()
	index := &site.declarations
	resolve :: proc(declarations_index: ^Site_Declaration_Index, code: string, context_folders: []string) -> (int, Site_Declaration_Resolution) {
		read, _ := site_declaration_span_read(code)
		return site_declaration_resolve(declarations_index, read, context_folders)
	}
	graphics_shared := place_of(&site, "shared_name", "graphics")
	console_shared := place_of(&site, "shared_name", "console")
	place, resolution := resolve(index, "blend_row", nil)
	testing.expect(t, resolution == .Linked && place == place_of(&site, "blend_row", "graphics"))
	// Two packages with one name: plain, unless the span or the text names
	// the package.
	_, resolution = resolve(index, "shared_name", nil)
	testing.expect_value(t, resolution, Site_Declaration_Resolution.Ambiguous)
	place, resolution = resolve(index, "graphics.shared_name", nil)
	testing.expect(t, resolution == .Linked && place == graphics_shared)
	place, resolution = resolve(index, "console.shared_name()", nil)
	testing.expect(t, resolution == .Linked && place == console_shared)
	place, resolution = resolve(index, "shared_name", []string{"programs/console"})
	testing.expect(t, resolution == .Linked && place == console_shared)
	place, resolution = resolve(index, "shared_name", []string{"programs"})
	testing.expect_value(t, resolution, Site_Declaration_Resolution.Linked)
	testing.expect_value(t, place, console_shared)
	// A common word: linked when the span calls it or the text places it.
	_, resolution = resolve(index, "count", nil)
	testing.expect_value(t, resolution, Site_Declaration_Resolution.Ambiguous)
	_, resolution = resolve(index, "count()", nil)
	testing.expect_value(t, resolution, Site_Declaration_Resolution.Linked)
	_, resolution = resolve(index, "count", []string{"programs/console"})
	testing.expect_value(t, resolution, Site_Declaration_Resolution.Linked)
	// A constant is not called; a name that no file declares is not found.
	_, resolution = resolve(index, "PAGE_SIZE()", nil)
	testing.expect_value(t, resolution, Site_Declaration_Resolution.Not_Found)
	_, resolution = resolve(index, "missing_name", nil)
	testing.expect_value(t, resolution, Site_Declaration_Resolution.Not_Found)
	_, resolution = resolve(index, "audio.blend_row", nil)
	testing.expect_value(t, resolution, Site_Declaration_Resolution.Not_Found)

	// The folders that a text names: a folder, and the folder of a file.
	folders := site_context_folders(index, "3. The blend of a glyph (`support/graphics`), in support/graphics/blend.odin:12, not in support/other.")
	testing.expect_value(t, len(folders), 2)
	for folder in folders {
		testing.expect_value(t, folder, "support/graphics")
	}

	// The spans that are fragments of Odin, and those that stay plain.
	for code in ([]string{"square_root[(d * d * (255 - a) + c * c * a) >> 12]", "x: int", "error: ^errors.Error_Record", "blend_row(row, 255) >> 4", "header.size", "for i in 0 ..< count", "PAGE_SIZE :: 4096"}) {
		testing.expectf(t, site_code_span_is_odin(code), "%q is not colored", code)
	}
	for code in ([]string{"support/graphics/blend.odin", "kerneltool site --address https://example.org", "nix develop -c kerneltool check", "kernel: boot: firmware: 1031293 us", "net: the round trip of one datagram", "test return_fault", "Ctrl+C", "a + b", "build.sh", "$HOME/x", "./run", "count", "Escape", "~/Projects", "a/b", "TEST_BUILD_SKIPS=true"}) {
		testing.expectf(t, !site_code_span_is_odin(code), "%q is colored as Odin", code)
	}
}

// The markup in a guide: a name of the index is a link with the icon and
// the color of its kind, and its card once at the end of the page; a name
// that two packages declare is resolved by the heading; a fragment of Odin
// is colored, its names of the index links with no card; a command, a
// common word and a name of no declaration stay code; the counts and the
// first spans of each kind.
@(test)
site_declaration_markup_in_a_guide :: proc(t: ^testing.T) {
	site := declaration_test_site()
	renderer := site_renderer_make(&site, "docs/guides/TEST/index.html", "docs/TEST.md")
	site_render_markdown(&renderer, "## 3. The blend (`support/graphics`)\n\nThe procedure `blend_row` calls `shared_name`; `blend_row(row, 255) >> 4` is the call; `kerneltool check` checks it; `count` and `missing_name` stay; `blend_row` again.\n")
	html := strings.to_string(renderer.builder)
	blend := place_of(&site, "blend_row", "graphics")
	shared := place_of(&site, "shared_name", "graphics")
	line_address :: proc(of_site: ^Site, file: string, line: int) -> string {
		return fmt.tprintf("%s#L%d", site_repository_file(of_site, file), line)
	}
	reference := strings.concatenate({"<a class=\"declaration-reference\" href=\"", line_address(&site, GRAPHICS_FILE, 4), "\" data-declaration-card=\"", site_declaration_card_id(blend), "\" aria-describedby=\"", site_declaration_card_id(blend), "-summary\"><code class=\"value value-procedure value-icon\">blend_row</code></a>"}, context.temp_allocator)
	testing.expectf(t, strings.count(html, reference) == 2, "the guide has not the link of blend_row twice:\n%s", html)
	testing.expectf(t, strings.contains(html, strings.concatenate({"data-declaration-card=\"", site_declaration_card_id(shared), "\""}, context.temp_allocator)), "the heading does not resolve shared_name:\n%s", html)
	// The heading keeps its code plain.
	testing.expect(t, strings.contains(html, "<h2 id=\"3-the-blend-support-graphics\">3. The blend (<code>support/graphics</code>)</h2>"), html)
	// A fragment of Odin: colored, its name a link with no card.
	testing.expect(t, strings.contains(html, strings.concatenate({"<code class=\"code-inline\"><a class=\"declaration-link\" href=\"", line_address(&site, GRAPHICS_FILE, 4), "\">blend_row</a><span class=\"c-p\">(</span>row<span class=\"c-p\">,</span> <span class=\"c-l\">255</span><span class=\"c-p\">) &gt;&gt;</span> <span class=\"c-l\">4</span></code>"}, context.temp_allocator)), html)
	testing.expect(t, strings.contains(html, "<code>kerneltool check</code>"), html)
	testing.expect(t, strings.contains(html, "<code>count</code>") && strings.contains(html, "<code>missing_name</code>"), html)
	// The counts: blend_row twice and shared_name linked; count ambiguous;
	// missing_name not found. The fragment and the command are not names.
	testing.expect_value(t, site.declaration_spans.linked, 3)
	testing.expect_value(t, site.declaration_spans.ambiguous, 1)
	testing.expect_value(t, site.declaration_spans.not_found, 1)
	testing.expect_value(t, site.declaration_spans.first_ambiguous[0], "docs/TEST.md: `count`")
	testing.expect_value(t, site.declaration_spans.first_not_found[0], "docs/TEST.md: `missing_name`")
	summary := site_declaration_summary(&site)
	testing.expect(t, len(summary) == 4, "the summary has not its four lines")
	if len(summary) == 4 {
		testing.expect_value(t, summary[1], "3 code spans name a declaration and link to it, 1 are ambiguous, 1 name no declaration")
		testing.expect_value(t, summary[3], "no declaration, the first: docs/TEST.md: `missing_name`")
	}

	// The cards: one for each declaration, at the end of the page, with
	// the colored line, the first sentence and the place.
	cards := site_declaration_cards_html(&site, "docs/guides/TEST/index.html", html)
	testing.expect_value(t, strings.count(cards, "<div class=\"declaration-card\" id="), 2)
	testing.expect(t, strings.contains(cards, strings.concatenate({"<div class=\"declaration-card\" id=\"", site_declaration_card_id(blend), "\" popover>"}, context.temp_allocator)), cards)
	testing.expect(t, strings.contains(cards, "<span class=\"c-n\">blend_row</span>"), cards)
	testing.expect(t, strings.contains(cards, strings.concatenate({"<p class=\"declaration-card-summary\" id=\"", site_declaration_card_id(blend), "-summary\">Blend a row of coverage in order.</p>"}, context.temp_allocator)), cards)
	testing.expect(t, strings.contains(cards, strings.concatenate({GRAPHICS_FILE, ":4</a>"}, context.temp_allocator)), cards)
	testing.expect(t, strings.contains(cards, "procedure of the package graphics"), cards)
	// The page with its cards passes the check of the cards.
	page := strings.concatenate({html, site_cards_html(&site, "docs/guides/TEST/index.html", html)}, context.temp_allocator)
	ids := make(map[string]bool, context.temp_allocator)
	for id in site_attribute_values(page, "id=\"") {
		ids[id] = true
	}
	testing.expect_value(t, site_type_cards_problem(page, ids), "")
	testing.expect(t, site_type_cards_problem(html, ids) == "" && site_type_cards_problem(strings.concatenate({html, "<a data-declaration-card=\"declaration-999\"></a>"}, context.temp_allocator), ids) != "", "a link to a card that the page has not is not found")
	testing.expect_value(t, site_inline_code_problem(page), "")
	testing.expect_value(t, site_heading_value_problem(page), "")
}

// A source comment: its spans take the same path, with no folder around
// them; the plain form of a comment has no link.
@(test)
site_declaration_markup_in_a_comment :: proc(t: ^testing.T) {
	site := declaration_test_site()
	html := site_source_comment_html(&site, "docs/reference/modules/graphics/index.html", "Calls `blend_row` and `shared_name` with `PAGE_SIZE * 2`.", .Paragraphs)
	testing.expect(t, strings.contains(html, "<code class=\"value value-procedure value-icon\">blend_row</code></a>"), html)
	testing.expect(t, strings.contains(html, "<code>shared_name</code>"), html)
	testing.expect(t, strings.contains(html, "<code class=\"code-inline\"><a class=\"declaration-link\""), html)
	testing.expect_value(t, site_source_comment_plain(&site, "Calls `blend_row`."), "Calls blend_row.")
	// A constant takes the icon of its kind.
	constant := strings.builder_make(context.temp_allocator)
	site_declaration_reference(&site, &constant, "docs/guides/TEST/index.html", "PAGE_SIZE", place_of(&site, "PAGE_SIZE", "graphics"))
	testing.expect(t, strings.contains(strings.to_string(constant), "<code class=\"value value-constant value-icon\">PAGE_SIZE</code>"), strings.to_string(constant))
}

// The declaration index of the repository: every folder of the sources is
// read, the parser refuses no file, and the index holds the procedures,
// the types and the constants that the site names elsewhere.
@(test)
site_declaration_index_of_the_repository :: proc(t: ^testing.T) {
	site := test_site()
	testing.expect(t, site_declarations_read(&site), "the sources cannot be read")
	testing.expectf(t, site.declarations.files_not_parsed == 0, "%d files not parsed, the first: %s", site.declarations.files_not_parsed, site.declarations.first_file_not_parsed)
	testing.expect(t, len(site.declarations.declarations) > 1000, "the index holds too few declarations")
	kinds: [Site_Declaration_Kind]int
	for declaration in site.declarations.declarations {
		kinds[declaration.kind] += 1
		testing.expectf(t, declaration.signature != "", "%s, line %d: the line of %s is %q", declaration.file, declaration.line, declaration.name, declaration.signature)
	}
	for kind in Site_Declaration_Kind {
		testing.expectf(t, kinds[kind] > 0, "the index has no %v", kind)
	}
	// A type of the contract is a type of its package.
	found := false
	for place in site.declarations.by_name["Fault_Record"] {
		declaration := site.declarations.declarations[place]
		found ||= declaration.package_name == "operation" && declaration.kind == .Type && declaration.folder == "contract/operation"
	}
	testing.expect(t, found, "the index has not the type Fault_Record of contract/operation")
}
