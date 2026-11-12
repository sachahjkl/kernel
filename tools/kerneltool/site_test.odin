package kerneltool

import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
SMALL_README :: "<p align=\"center\"><img src=\"resources/logo/modus_transparent.png\" width=\"256\" alt=\"The mark\"></p>\n\n# Title\n\nThe lead.\nIts second line.\n\n![A <b>bold</b> & \"quoted\" caption](docs/screenshots/x.png)\n\n| | |\n|---|---|\n| ![Left](docs/screenshots/left.png) | ![Right](docs/screenshots/right.png) |\n\n## Use\n\nThe flake.\n\n## Licences\n\nMIT.\n"

@(private = "file")
SMALL_PROPERTIES :: `# Properties

## Objective

Build a thing.

Three rules:

1. **One.** First rule.
2. **Two.** Second rule.

## Summary

| # | Property | Status |
|---|---|---|
| 1 | One | Decided |
| 2 | Two | Proposed |

## 1. One

Status: Decided.

- **Why**: A reason.
- **Rule**: The first rule. More text.

## 2. Two

Status: Proposed.

| A | B |
|---|---|
| x | y |
| z | w |

### A part

- **Rule** (a note): The rule of the part.

## Tensions

- Not a property.
`

@(test)
site_escapes_a_caption :: proc(t: ^testing.T) {
	readme, problem := site_readme_parse(SMALL_README)
	testing.expect_value(t, problem, "")
	caption := readme.captions["docs/screenshots/x.png"]
	testing.expect_value(t, caption, "A <b>bold</b> & \"quoted\" caption")
	testing.expect_value(t, site_inline_text(caption), "A &lt;b&gt;bold&lt;/b&gt; &amp; &quot;quoted&quot; caption")
	builder := strings.builder_make(context.temp_allocator)
	site_plain(&builder, "`a<b` **c&d** 'e'")
	testing.expect_value(t, strings.to_string(builder), "a&lt;b c&amp;d &#39;e&#39;")
	testing.expect_value(t, site_inline_text("x `<y>` **z** [w](v.md) [Blow §2] `open"), "x <code>&lt;y&gt;</code> <strong>z</strong> w [Blow §2] `open")
	testing.expect_value(t, site_inline_text("**not closed"), "<strong>not closed</strong>")
}

@(test)
site_properties_of_the_repository :: proc(t: ^testing.T) {
	data, err := os.read_entire_file(SITE_PROPERTIES_FILE, context.temp_allocator)
	testing.expect(t, err == nil, "cannot read docs/PROPERTIES.md")
	principles, problem := site_properties_parse(string(data))
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(principles.properties), 21)
	testing.expect_value(t, len(principles.rules), 3)
	testing.expect(t, strings.has_prefix(principles.objective, "Build a kernel"))
	for property, index in principles.properties {
		testing.expect_value(t, property.number, index + 1)
		testing.expectf(t, property.title != "" && property.status != "", "the property %d has no title or no status", property.number)
		testing.expectf(t, strings.has_suffix(property.sentence, "."), "the sentence of the property %d does not end with a period: %s", property.number, property.sentence)
	}
	if len(principles.properties) != 21 {
		return
	}
	testing.expect(t, strings.has_prefix(principles.properties[0].sentence, "The kernel does four things"))
	testing.expect_value(t, principles.properties[0].status, "Decided")
	testing.expect(t, len(principles.properties[8].parts) == 1 && strings.has_prefix(principles.properties[8].parts[0].title, "Persistence"))
	testing.expect(t, len(principles.properties[12].parts) == 1 && strings.has_prefix(principles.properties[12].parts[0].sentence, "A record that is all zero bytes"))
	testing.expect(t, strings.has_prefix(principles.properties[14].sentence, "A process can contain several protection domains"))
	testing.expect(t, strings.contains(principles.properties[15].sentence, "Signals"))
	testing.expect(t, strings.has_prefix(principles.properties[19].sentence, "Ambient access is access"))
}

@(test)
site_properties_of_a_small_file :: proc(t: ^testing.T) {
	principles, problem := site_properties_parse(SMALL_PROPERTIES)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, principles.objective, "Build a thing.")
	testing.expect_value(t, len(principles.rules), 2)
	testing.expect_value(t, len(principles.properties), 2)
	if len(principles.properties) != 2 {
		return
	}
	testing.expect_value(t, principles.properties[0].sentence, "The first rule.")
	testing.expect_value(t, principles.properties[1].status, "Proposed")
	testing.expect_value(t, principles.properties[1].sentence, "x, z.")
	testing.expect_value(t, len(principles.properties[1].parts), 1)
	if len(principles.properties[1].parts) == 1 {
		testing.expect_value(t, principles.properties[1].parts[0].title, "A part")
		testing.expect_value(t, principles.properties[1].parts[0].sentence, "The rule of the part.")
	}
}

@(test)
site_properties_of_a_damaged_file :: proc(t: ^testing.T) {
	Damage :: struct {
		before, after: string,
	}
	damages := []Damage {
		{"## Objective", "## Goal"},
		{"1. **One.** First rule.\n2. **Two.** Second rule.", "No rule."},
		{"| # | Property | Status |", "| Number | Property | Status |"},
		{"| 2 | Two | Proposed |\n", ""},
		{"| 2 | Two | Proposed |", "| 3 | Two | Proposed |"},
		{"## 2. Two", "## 3. Two"},
		{"- **Why**: A reason.\n- **Rule**: The first rule. More text.", ""},
		{"- **Rule** (a note): The rule of the part.", ""},
		{"## 1. One", "## 1. "},
	}
	for damage in damages {
		damaged, changed := strings.replace_all(SMALL_PROPERTIES, damage.before, damage.after, context.temp_allocator)
		testing.expectf(t, changed, "the text %q is not in the small file", damage.before)
		_, problem := site_properties_parse(damaged)
		testing.expectf(t, problem != "", "no problem found after %q became %q", damage.before, damage.after)
	}
	_, empty_problem := site_properties_parse("")
	testing.expect(t, empty_problem != "")
}

@(test)
site_readme_of_the_repository :: proc(t: ^testing.T) {
	data, err := os.read_entire_file(SITE_README_FILE, context.temp_allocator)
	testing.expect(t, err == nil, "cannot read README.md")
	readme, problem := site_readme_parse(string(data))
	testing.expect_value(t, problem, "")
	testing.expect(t, strings.has_prefix(readme.lead, "A new kernel and operating system"))
	testing.expect(t, readme.mark_description != "")
	testing.expect(t, readme.use_paragraph != "")
	testing.expect(t, len(readme.licence_paragraphs) > 0)
	for picture in site_pictures {
		testing.expectf(t, picture.path in readme.captions, "README.md has no caption for %s", picture.path)
	}
	reviews, reviews_error := os.read_entire_file(SITE_REVIEWS_FILE, context.temp_allocator)
	testing.expect(t, reviews_error == nil, "cannot read docs/REVIEWS.md")
	step_count, reviews_problem := site_reviews_step_count(string(reviews))
	testing.expect_value(t, reviews_problem, "")
	testing.expect(t, step_count > 0)
}

@(test)
site_readme_of_a_small_file :: proc(t: ^testing.T) {
	readme, problem := site_readme_parse(SMALL_README)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, readme.lead, "The lead. Its second line.")
	testing.expect_value(t, readme.mark_description, "The mark")
	testing.expect_value(t, readme.captions["docs/screenshots/left.png"], "Left")
	testing.expect_value(t, readme.captions["docs/screenshots/right.png"], "Right")
	testing.expect_value(t, readme.use_paragraph, "The flake.")
	Damage :: struct {
		before, after: string,
	}
	damages := []Damage {
		{"# Title", "Title"},
		{"(docs/screenshots/right.png)", "(docs/screenshots/right.png"},
		{"![Left](", "![Left]"},
		{"![Left]", "![]"},
		{"alt=\"The mark\"", "title=\"The mark\""},
		{"## Use", "## Using"},
		{"## Licences", "## Licenses"},
	}
	for damage in damages {
		damaged, changed := strings.replace_all(SMALL_README, damage.before, damage.after, context.temp_allocator)
		testing.expectf(t, changed, "the text %q is not in the small file", damage.before)
		_, damaged_problem := site_readme_parse(damaged)
		testing.expectf(t, damaged_problem != "", "no problem found after %q became %q", damage.before, damage.after)
	}
}

@(test)
site_steps_of_the_reviews :: proc(t: ^testing.T) {
	good := "# Reviews\n\n| Step | Commit | Capability |\n|---|---|---|\n| 1 | `a` | One |\n| 2 | `b` | Two |\n\n## Review 1\n\n| 9 | after the table |\n"
	count, problem := site_reviews_step_count(good)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, count, 2)
	with_gap, _ := strings.replace_all(good, "| 2 |", "| 3 |", context.temp_allocator)
	_, gap_problem := site_reviews_step_count(with_gap)
	testing.expect(t, gap_problem != "")
	_, empty_problem := site_reviews_step_count("# Reviews\n")
	testing.expect(t, empty_problem != "")
}

@(test)
site_first_sentences :: proc(t: ^testing.T) {
	testing.expect_value(t, site_first_sentence("  One. Two."), "One.")
	testing.expect_value(t, site_first_sentence("The concept of \"who executes\". The answer."), "The concept of \"who executes\".")
	testing.expect_value(t, site_first_sentence("Version 0.5 is here"), "Version 0.5 is here")
	testing.expect_value(t, site_first_sentence(""), "")
}

@(test)
site_lines_of_a_log :: proc(t: ^testing.T) {
	log := "[a] a: one 1\r\n[b:channel] b: frame 2 us\n[b] b: frame 3 us\nplain frame 4 us\n"
	text, line_number, count := site_line_choose(log, "frame", .Last)
	testing.expect_value(t, text, "plain frame 4 us")
	testing.expect_value(t, line_number, 4)
	testing.expect_value(t, count, 3)
	text, line_number, count = site_line_choose(log, "frame", .First)
	testing.expect_value(t, text, "b: frame 2 us")
	testing.expect_value(t, line_number, 2)
	testing.expect_value(t, count, 3)
	_, _, count = site_line_choose(log, "absent", .First)
	testing.expect_value(t, count, 0)
	absent := site_measure_read(Site_Measure{sentence = "absent", files = {BUILD_FOLDER + "/no_log_of_the_site_test.txt", ""}, pattern = "x"})
	testing.expect(t, !absent.found)
	testing.expect(t, strings.contains(absent.missing, "no file"))
}

@(test)
site_size_of_a_png_file :: proc(t: ^testing.T) {
	header := []u8{0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n', 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 4, 0, 0, 0, 3, 0}
	width, height, ok := site_png_size(header)
	testing.expect(t, ok)
	testing.expect_value(t, width, 1024)
	testing.expect_value(t, height, 768)
	_, _, short_ok := site_png_size(header[:20])
	testing.expect(t, !short_ok)
	not_png := make([]u8, len(header), context.temp_allocator)
	copy(not_png, header)
	not_png[1] = 'X'
	_, _, not_png_ok := site_png_size(not_png)
	testing.expect(t, !not_png_ok)
}
