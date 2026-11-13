package kerneltool

import "core:strings"
import "core:testing"

// A site with the guide of the architecture, whose page has a few headings
// of known ids. The file of the guide is read for its title only when the
// site has no guide for it: here the guide gives the title.
@(private = "file")
reference_test_site :: proc() -> Site {
	site := test_site()
	site.documents["docs/ARCHITECTURE.md"] = "docs/guides/ARCHITECTURE/index.html"
	site.documents["ARCHITECTURE.md"] = "docs/guides/ARCHITECTURE/index.html"
	// Made with an allocator: a slice literal would live on the stack of
	// this procedure, and the site outlives it.
	headings := make([]Site_Heading, 8, context.temp_allocator)
	headings[0] = {level = 1, text = "Architecture", id = "architecture"}
	headings[1] = {level = 2, text = "Kernel systems", id = "kernel-systems"}
	headings[2] = {level = 3, text = "K1. Handle table", id = "k1-handle-table"}
	headings[3] = {level = 2, text = "Kernel events", id = "kernel-events"}
	headings[4] = {level = 3, text = "5. The grant", id = "5-the-grant"}
	headings[5] = {level = 3, text = "5a. What a record shows", id = "5a-what-a-record-shows"}
	headings[6] = {level = 2, text = "12. The interface font", id = "12-the-interface-font"}
	headings[7] = {level = 3, text = "12.4 The glyph cache", id = "12-4-the-glyph-cache"}
	site.guides = make([dynamic]Site_Guide, context.temp_allocator)
	append(&site.guides, Site_Guide{source = "docs/ARCHITECTURE.md", path = "docs/guides/ARCHITECTURE/index.html", title = "Architecture", headings = headings})
	return site
}

// The bytes that a pointer takes from its text.
@(private = "file")
taken :: proc(text: string, pointer: Site_Document_Pointer) -> string {
	return text[pointer.start:pointer.end]
}

// Each form of a pointer of a source comment: a whole parenthesis, with a
// quoted heading, a section, two labels, a comma inside quotes; a part of a
// parenthesis after other words or after "; "; a path that is a word of its
// sentence; "see"; two pointers in one parenthesis; a pointer at the end
// of a text with no period.
@(test)
site_document_pointers_of_each_form :: proc(t: ^testing.T) {
	Case :: struct {
		text:     string,
		path:     string,
		labels:   []string,
		detached: bool,
		taken:    string,
	}
	cases := []Case {
		{"The kernel (docs/ARCHITECTURE.md, \"Kernel systems\").", "docs/ARCHITECTURE.md", {"\"Kernel systems\""}, true, " (docs/ARCHITECTURE.md, \"Kernel systems\")"},
		{"A table (docs/INTERFACE.md) of rows.", "docs/INTERFACE.md", {}, true, " (docs/INTERFACE.md)"},
		{"The record (docs/MODULE_CONTRACT.md, section 8).", "docs/MODULE_CONTRACT.md", {"section 8"}, true, " (docs/MODULE_CONTRACT.md, section 8)"},
		{"A record (docs/ARCHITECTURE.md, \"Kernel events\", section 5a).", "docs/ARCHITECTURE.md", {"\"Kernel events\"", "section 5a"}, true, " (docs/ARCHITECTURE.md, \"Kernel events\", section 5a)"},
		{"A count (docs/MODULE_CONTRACT.md, \"Did not fit, across calls\").", "docs/MODULE_CONTRACT.md", {"\"Did not fit, across calls\""}, true, " (docs/MODULE_CONTRACT.md, \"Did not fit, across calls\")"},
		{"Only its imports changed (support/cryptography/origin.manifest, docs/CRYPTOGRAPHY.md).", "docs/CRYPTOGRAPHY.md", {}, true, ", docs/CRYPTOGRAPHY.md"},
		{"Another program (property 19; docs/MODULE_CONTRACT.md, sections 4 and 5).", "docs/MODULE_CONTRACT.md", {"sections 4 and 5"}, true, "; docs/MODULE_CONTRACT.md, sections 4 and 5"},
		{"The colors of docs/DESIGN.md: a name is dim.", "docs/DESIGN.md", {}, false, "docs/DESIGN.md"},
		{"The speeds of docs/CRYPTOGRAPHY.md, section 6, with the cost.", "docs/CRYPTOGRAPHY.md", {"section 6"}, false, "docs/CRYPTOGRAPHY.md, section 6"},
		{"The versions: docs/ARCHITECTURE.md, U5, \"Versions\".", "docs/ARCHITECTURE.md", {"U5", "\"Versions\""}, false, "docs/ARCHITECTURE.md, U5, \"Versions\""},
		{"A rule, see docs/DESIGN.md, section 3.", "docs/DESIGN.md", {"section 3"}, true, ", see docs/DESIGN.md, section 3"},
		{"A gap (a gap of docs/FIRST_MILESTONE.md) stays.", "docs/FIRST_MILESTONE.md", {}, false, "docs/FIRST_MILESTONE.md"},
		{"The kernel: the interrupts (docs/ARCHITECTURE.md, U3)", "docs/ARCHITECTURE.md", {"U3"}, true, " (docs/ARCHITECTURE.md, U3)"},
	}
	for item in cases {
		pointers := site_document_pointers(item.text)
		testing.expectf(t, len(pointers) == 1, "%q: %d pointers", item.text, len(pointers))
		if len(pointers) != 1 {
			continue
		}
		pointer := pointers[0]
		testing.expectf(t, pointer.path == item.path, "%q: the path %q", item.text, pointer.path)
		testing.expectf(t, pointer.detached == item.detached, "%q: detached is %v", item.text, pointer.detached)
		testing.expectf(t, taken(item.text, pointer) == item.taken, "%q: it takes %q", item.text, taken(item.text, pointer))
		testing.expectf(t, len(pointer.labels) == len(item.labels), "%q: the labels %v", item.text, pointer.labels)
		for label, index in item.labels {
			if index < len(pointer.labels) {
				testing.expectf(t, pointer.labels[index] == label, "%q: label %d is %q", item.text, index, pointer.labels[index])
			}
		}
	}

	// Two pointers in one parenthesis: each takes its part and one "; ".
	two := "The bar (docs/DESIGN.md, section 5; docs/FONTS.md, section 12.6) is drawn."
	pointers := site_document_pointers(two)
	testing.expect_value(t, len(pointers), 2)
	if len(pointers) == 2 {
		testing.expect_value(t, taken(two, pointers[0]), "docs/DESIGN.md, section 5; ")
		testing.expect_value(t, taken(two, pointers[1]), "; docs/FONTS.md, section 12.6")
		testing.expect(t, pointers[0].detached && pointers[1].detached)
	}

	// A path that is not a document of docs/, and a text with no pointer.
	for text in ([]string{"tools/docs/ARCHITECTURE.md", "docs/notes.txt", "docs/lower.md", "the docs/ folder", "docs/A.mdx", "The record of a call.", ""}) {
		testing.expectf(t, len(site_document_pointers(text)) == 0, "%q has a pointer", text)
	}
}

// A label finds its heading: by a quoted text, by the label of a section
// (12 is not 12.4), inside the part of the label before it, and two
// sections give two places. A label that finds nothing names the guide
// alone, and is not resolved; a path that is not a document gives nothing.
@(test)
site_document_pointers_find_their_headings :: proc(t: ^testing.T) {
	site := reference_test_site()
	Case :: struct {
		labels:   []string,
		heading:  string,
		link:     string,
		resolved: bool,
	}
	page := "docs/guides/ARCHITECTURE/index.html"
	cases := []Case {
		{{}, "", page, true},
		{{"\"Kernel systems\""}, "Kernel systems", "docs/guides/ARCHITECTURE/index.html#kernel-systems", true},
		{{"\"kernel  SYSTEMS\""}, "Kernel systems", "docs/guides/ARCHITECTURE/index.html#kernel-systems", true},
		{{"K1"}, "Handle table", "docs/guides/ARCHITECTURE/index.html#k1-handle-table", true},
		{{"\"Kernel events\"", "section 5a"}, "What a record shows", "docs/guides/ARCHITECTURE/index.html#5a-what-a-record-shows", true},
		{{"section 12"}, "The interface font", "docs/guides/ARCHITECTURE/index.html#12-the-interface-font", true},
		{{"section 12.4"}, "The glyph cache", "docs/guides/ARCHITECTURE/index.html#12-4-the-glyph-cache", true},
		{{"\"The grant\""}, "The grant", "docs/guides/ARCHITECTURE/index.html#5-the-grant", true},
		{{"\"No such heading\""}, "", page, false},
		{{"section 99"}, "", page, false},
		{{"decision 6"}, "", page, false},
		{{"\"Kernel systems\"", "section 5a"}, "", page, false},
	}
	for item in cases {
		targets := site_document_targets(&site, "docs/ARCHITECTURE.md", item.labels)
		testing.expectf(t, len(targets) == 1, "%v: %d places", item.labels, len(targets))
		if len(targets) != 1 {
			continue
		}
		testing.expectf(t, targets[0].heading == item.heading, "%v: the heading %q", item.labels, targets[0].heading)
		testing.expectf(t, targets[0].link == item.link, "%v: the link %q", item.labels, targets[0].link)
		testing.expectf(t, targets[0].resolved == item.resolved, "%v: resolved is %v", item.labels, targets[0].resolved)
		testing.expectf(t, targets[0].title == "Architecture" && !targets[0].outside, "%v: the title %q", item.labels, targets[0].title)
	}
	two := site_document_targets(&site, "docs/ARCHITECTURE.md", []string{"sections 12 and 12.4"})
	testing.expect_value(t, len(two), 2)
	if len(two) == 2 {
		testing.expect_value(t, two[0].heading, "The interface font")
		testing.expect_value(t, two[1].heading, "The glyph cache")
	}
	testing.expect_value(t, len(site_document_targets(&site, "docs/NOPE.md", nil)), 0)
}

// A working record is a file of the repository: its reference links to the
// line of its heading at the commit, and says that it is outside the site.
@(test)
site_document_pointers_to_a_working_record :: proc(t: ^testing.T) {
	site := reference_test_site()
	content, ok := site_read_quiet(SITE_MILESTONE_FILE)
	testing.expect(t, ok)
	gaps_line := 0
	for line, index in site_lines(content) {
		if line == "## Gaps" {
			gaps_line = index + 1
			break
		}
	}
	testing.expect(t, gaps_line > 0, "the file has no heading \"## Gaps\"")
	targets := site_document_targets(&site, SITE_MILESTONE_FILE, []string{"\"Gaps\""})
	testing.expect_value(t, len(targets), 1)
	if len(targets) == 1 {
		testing.expect(t, targets[0].outside && targets[0].resolved)
		testing.expect_value(t, targets[0].title, "First milestone")
		testing.expect_value(t, targets[0].heading, "Gaps")
		testing.expect_value(t, targets[0].link, site_line_address(&site, SITE_MILESTONE_FILE, gaps_line))
		b := strings.builder_make(context.temp_allocator)
		site_document_reference_write(&site, &b, "docs/reference/modules/kernel/index.html", targets[0])
		html := strings.to_string(b)
		testing.expect(t, strings.has_prefix(html, SITE_DOCUMENT_REFERENCE_OPEN + SITE_REPOSITORY_ADDRESS + "/blob/master/docs/FIRST_MILESTONE.md#L"), html)
		testing.expect(t, strings.has_suffix(html, ">First milestone: Gaps<span class=\"document-outside\"> in the repository</span></a>"), html)
	}
	whole := site_document_targets(&site, SITE_MILESTONE_FILE, nil)
	testing.expect(t, len(whole) == 1 && whole[0].link == site_repository_file(&site, SITE_MILESTONE_FILE))
}

// The markup of a reference: a link in the style of the kind Guide, the
// title of the guide and the text of the heading, relative to its page.
@(test)
site_document_reference_markup :: proc(t: ^testing.T) {
	site := reference_test_site()
	targets := site_document_targets(&site, "docs/ARCHITECTURE.md", []string{"\"Kernel systems\""})
	testing.expect_value(t, len(targets), 1)
	if len(targets) != 1 {
		return
	}
	b := strings.builder_make(context.temp_allocator)
	site_document_reference_write(&site, &b, "docs/reference/modules/kernel/index.html", targets[0])
	testing.expect_value(t, strings.to_string(b), "<a class=\"document-reference value-guide value-icon\" href=\"../../../../docs/guides/ARCHITECTURE/index.html#kernel-systems\">Architecture: Kernel systems</a>")
	published := reference_test_site()
	published.address = "https://example.org"
	link := strings.builder_make(context.temp_allocator)
	site_document_reference_write(&published, &link, "docs/reference/modules/kernel/index.html", targets[0])
	testing.expect(t, strings.contains(strings.to_string(link), "href=\"../../../../docs/guides/ARCHITECTURE/#kernel-systems\""), strings.to_string(link))
}

// The text of a source comment: an aside leaves its sentence, which ends
// cleanly, and its reference goes into the line "See:" after the text; a
// path that is a word of its sentence is the reference in its place; a
// text with no pointer is as before; the summary has no pointer; each
// pointer is counted, and one with no heading is named.
@(test)
site_source_comment_text :: proc(t: ^testing.T) {
	site := reference_test_site()
	page := "docs/reference/modules/kernel/index.html"
	reference := "<a class=\"document-reference value-guide value-icon\" href=\"../../../../docs/guides/ARCHITECTURE/index.html#kernel-systems\">Architecture: Kernel systems</a>"

	html := site_source_comment_html(&site, page, "The kernel: the interrupts (docs/ARCHITECTURE.md, \"Kernel systems\").\n\nA second <line>.", .Paragraphs)
	testing.expect_value(t, html, strings.concatenate({"<p>The kernel: the interrupts.</p>\n<p>A second &lt;line&gt;.</p>\n<p class=\"document-references\">See: ", reference, "</p>\n"}, context.temp_allocator))

	in_place := site_source_comment_html(&site, page, "The rules of docs/ARCHITECTURE.md, \"Kernel systems\", hold.", .Paragraphs)
	testing.expect_value(t, in_place, strings.concatenate({"<p>The rules of ", reference, ", hold.</p>\n"}, context.temp_allocator))

	two := site_source_comment_html(&site, page, "Text (docs/ARCHITECTURE.md, \"Kernel systems\"; docs/ARCHITECTURE.md, section 12).", .Paragraphs)
	testing.expect(t, strings.has_prefix(two, "<p>Text.</p>\n<p class=\"document-references\">See: "), two)
	testing.expect_value(t, strings.count(two, SITE_DOCUMENT_REFERENCE_OPEN), 2)

	kept := site_source_comment_html(&site, page, "A queue (strategy.odin, docs/ARCHITECTURE.md): ready.", .Line)
	testing.expect(t, strings.has_prefix(kept, "A queue (strategy.odin): ready. <span class=\"document-references\">See: <a class=\"document-reference"), kept)

	// The same reference twice is listed once.
	once := site_source_comment_html(&site, page, "A (docs/ARCHITECTURE.md, \"Kernel systems\"). B (docs/ARCHITECTURE.md, \"kernel systems\").", .Paragraphs)
	testing.expect_value(t, strings.count(once, SITE_DOCUMENT_REFERENCE_OPEN), 1)

	plain := "Maps <memory>.\n\nA second paragraph."
	testing.expect_value(t, site_source_comment_html(&site, page, plain, .Paragraphs), "<p>Maps &lt;memory&gt;.</p>\n<p>A second paragraph.</p>\n")
	testing.expect_value(t, site_source_comment_html(&site, page, "No pointer.", .Line), "No pointer.")
	testing.expect_value(t, site_source_comment_html(&site, page, "docs/NOPE.md stays.", .Line), "docs/NOPE.md stays.")

	testing.expect_value(t, site_source_comment_plain(&site, "The kernel (docs/ARCHITECTURE.md, \"Kernel systems\")"), "The kernel")
	testing.expect_value(t, site_source_comment_plain(&site, "The rules of docs/ARCHITECTURE.md, \"Kernel systems\", hold."), "The rules of Architecture: Kernel systems, hold.")
	testing.expect_value(t, site_source_comment_plain(nil, "The kernel (docs/ARCHITECTURE.md)."), "The kernel (docs/ARCHITECTURE.md).")

	// A label with no heading: the guide alone, counted and named.
	stale := site_source_comment_html(&site, page, "A thread (docs/ARCHITECTURE.md, decision 6).", .Paragraphs)
	testing.expect(t, strings.contains(stale, ">Architecture</a>") && !strings.contains(stale, "decision"), stale)
	count, unresolved := site_document_references_summary(&site)
	testing.expect(t, count >= 4, "too few references counted")
	testing.expect_value(t, len(unresolved), 1)
	if len(unresolved) == 1 {
		testing.expect_value(t, unresolved[0], "docs/ARCHITECTURE.md, decision 6")
	}
}

// A code span of a guide that names a document, with the labels after it,
// is a reference in the same markup; in a heading it stays code.
@(test)
site_render_document_references :: proc(t: ^testing.T) {
	site := reference_test_site()
	renderer := site_renderer_make(&site, "docs/guides/TEST/index.html", "docs/TEST.md")
	site_render_markdown(&renderer, "## `ARCHITECTURE.md` here\n\nAs `ARCHITECTURE.md`, \"Kernel systems\" says, and `docs/ARCHITECTURE.md`, section 12.4.\n")
	html := strings.to_string(renderer.builder)
	testing.expect(t, strings.contains(html, "As <a class=\"document-reference value-guide value-icon\" href=\"../../../docs/guides/ARCHITECTURE/index.html#kernel-systems\">Architecture: Kernel systems</a> says, and "), html)
	testing.expect(t, strings.contains(html, "#12-4-the-glyph-cache\">Architecture: The glyph cache</a>."), html)
	testing.expect(t, strings.contains(html, "<h2 id=\"architecture-md-here\"><code>ARCHITECTURE.md</code> here</h2>"), html)
}

// The page of the kernel module: its description, then its references,
// then its facts with its build settings. The kernel built with a test
// setting says so first, and names the setting.
@(test)
site_module_page_of_the_kernel :: proc(t: ^testing.T) {
	site := test_site()
	site.documents["docs/ARCHITECTURE.md"] = "docs/guides/ARCHITECTURE/index.html"
	site.documents["ARCHITECTURE.md"] = "docs/guides/ARCHITECTURE/index.html"
	content, ok := site_read_quiet("docs/ARCHITECTURE.md")
	testing.expect(t, ok)
	renderer := site_renderer_make(&site, "docs/guides/ARCHITECTURE/index.html", "docs/ARCHITECTURE.md")
	site_render_markdown(&renderer, content)
	site.guides = make([dynamic]Site_Guide, context.temp_allocator)
	append(&site.guides, Site_Guide{source = "docs/ARCHITECTURE.md", path = "docs/guides/ARCHITECTURE/index.html", title = "Architecture", headings = renderer.headings[:], items = renderer.items[:]})
	if !site_reference_read(&site) {
		testing.expect(t, false, "the sources of the reference cannot be read")
		return
	}
	entries := make([dynamic]Site_Reference_Entry, context.temp_allocator)
	site_module_pages_add(&site, &entries)
	kernel, test_kernel := "", ""
	kernel_description := ""
	for page in site.pages {
		if page.path == site_module_page("kernel") {
			kernel = page.body
			kernel_description = page.description
		}
		if page.path == site_module_page("kernel_without_return_check") {
			test_kernel = page.body
		}
	}
	testing.expect(t, kernel != "" && test_kernel != "", "no page of the kernel")
	description := strings.index(kernel, "<p>The kernel")
	references := strings.index(kernel, "<p class=\"document-references\">See: <a class=\"document-reference value-guide value-icon\" href=\"../../../../docs/guides/ARCHITECTURE/index.html#kernel-systems\">Architecture: Kernel systems</a>")
	// The kernel has no build setting, so its facts start with its kind.
	facts := strings.index(kernel, ">Kind</td>")
	testing.expectf(t, description >= 0 && references > description && facts > references, "the order of the page: %d, %d, %d", description, references, facts)
	testing.expect(t, !strings.contains(kernel[:max(facts, 0)], "docs/ARCHITECTURE.md"), "the path of the guide stays in the text")
	testing.expect(t, !strings.contains(kernel_description, "docs/"), kernel_description)
	testing.expect(t, strings.contains(kernel, "none: the defaults of the source"))
	setting := "<code>TEST_BUILD_SKIPS_THE_INSTRUCTION_ADDRESS_CHECK=true</code>"
	testing.expect(t, strings.contains(test_kernel, strings.concatenate({"<p>The module <a href=\"../../../../docs/reference/modules/kernel/index.html\"><code>kernel</code></a> built with the setting ", setting}, context.temp_allocator)), test_kernel)
	testing.expect(t, strings.index(test_kernel, "built with the setting") < strings.index(test_kernel, "<p>The kernel"), "the setting is not said first")
	testing.expect_value(t, strings.count(test_kernel, setting), 2) // The first paragraph and the fact.
}

// A comment holds code in backticks: on a page each pair is a code
// element, and the summary has no backticks. The identifier of a decision
// (a capital D, a hyphen and a number) is a label.
@(test)
site_source_comment_code_and_decisions :: proc(t: ^testing.T) {
	site := reference_test_site()
	page := "docs/reference/modules/kernel/index.html"
	testing.expect_value(t, site_source_comment_html(&site, page, "For one machine of `test return_fault` only, `a<b`.", .Line), "For one machine of <code>test return_fault</code> only, <code>a&lt;b</code>.")
	testing.expect_value(t, site_source_comment_html(&site, page, "One ` alone.", .Line), "One ` alone.")
	testing.expect_value(t, site_source_comment_plain(&site, "For `test return_fault` only."), "For test return_fault only.")

	targets := site_document_targets(&site, "docs/DECISIONS.md", []string{"D-163"})
	testing.expect_value(t, len(targets), 1)
	if len(targets) == 1 {
		testing.expect(t, targets[0].resolved && targets[0].outside, "D-163 is not found")
		testing.expect_value(t, targets[0].heading, "A technical site")
	}
}

// The check of the pointers names the file and the line of a stale one,
// in a comment of the source (the line where the pointer starts, in a
// comment of several lines) and in a guide; a pointer that resolves gives
// no fault.
@(test)
site_document_pointer_check :: proc(t: ^testing.T) {
	site := reference_test_site()
	source := "x :: 1\n// A thing (docs/ARCHITECTURE.md,\n// \"No such heading\").\n// Fine (docs/ARCHITECTURE.md, \"Kernel systems\").\ny :: 2 // docs/ARCHITECTURE.md, section 99.\n"
	problems := site_comment_pointer_problems(&site, "a.odin", source)
	testing.expectf(t, len(problems) == 2, "%v", problems)
	if len(problems) == 2 {
		testing.expect(t, strings.has_prefix(problems[0], "a.odin, line 2: "), problems[0])
		testing.expect(t, strings.has_prefix(problems[1], "a.odin, line 5: "), problems[1])
	}
	guide := "# A\n\nAs `ARCHITECTURE.md`, \"Kernel systems\" says.\n\n```\n`ARCHITECTURE.md`, \"In a fence\"\n```\n\nAnd `ARCHITECTURE.md`, \"Nothing\".\n"
	guide_problems := site_guide_pointer_problems(&site, "docs/A.md", guide)
	testing.expectf(t, len(guide_problems) == 1, "%v", guide_problems)
	if len(guide_problems) == 1 {
		testing.expect(t, strings.has_prefix(guide_problems[0], "docs/A.md, line 9: "), guide_problems[0])
	}
}

// Every pointer of the repository resolves: the source comments of the
// system, the guides, the glossary, the news and the working record that
// the status page reads. Every link of a source comment names a place.
@(test)
site_document_pointers_of_the_repository :: proc(t: ^testing.T) {
	site := test_site()
	paths, ok := files_with_suffix("docs", ".md")
	testing.expect(t, ok)
	for path in paths {
		name := site_file_name(path)
		if site_is_working_record(name) {
			continue
		}
		page := site_page_file(name == "GLOSSARY.md" ? SITE_GLOSSARY_FOLDER : strings.concatenate({SITE_GUIDE_FOLDER, "/", name[:len(name) - len(".md")]}, context.temp_allocator))
		site.documents[path] = page
		site.documents[name] = page
	}
	glossary, glossary_ok := site_read_quiet(SITE_GLOSSARY_FILE)
	testing.expect(t, glossary_ok)
	site.terms = site_glossary_terms(glossary)
	site.guides = make([dynamic]Site_Guide, context.temp_allocator)
	// The links of the comments name rows, exports and declarations.
	testing.expect(t, site_reference_read(&site))
	testing.expect(t, site_declarations_read(&site))
	testing.expect(t, site_guides_add(&site))
	problems := site_document_pointer_problems(&site)
	testing.expectf(t, len(problems) == 0, "%d stale pointers: %v", len(problems), problems)
}
