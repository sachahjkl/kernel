package kerneltool

import "core:fmt"
import "core:strings"
import "core:testing"
import "support:graphics"

// The table of the kinds is complete: each kind has a name of its own, a
// title, a meaning, an icon of 12 by 12 cells that no other kind has, and
// a color in each form whose contrast on each surface of a table is at
// least the bound.
@(test)
site_value_kinds_are_complete :: proc(t: ^testing.T) {
	names := make(map[string]Site_Value_Kind, context.temp_allocator)
	icons := make(map[string]Site_Value_Kind, context.temp_allocator)
	dark, light := site_dark_colors(), site_light_colors()
	for kind in Site_Value_Kind {
		if kind == .None {
			continue
		}
		description := site_value_kinds[kind]
		testing.expectf(t, description.name != "" && description.title != "" && description.meaning != "", "the kind %v has no name, no title or no meaning", kind)
		if other, found := names[description.name]; found {
			testing.expectf(t, false, "the kinds %v and %v have the name %s", kind, other, description.name)
		}
		names[description.name] = kind
		filled := 0
		for row in description.cells {
			testing.expectf(t, len(row) == SITE_VALUE_ICON_SIZE, "a row of the icon of %v has %d cells", kind, len(row))
			for cell in transmute([]u8)row {
				testing.expectf(t, cell == '#' || cell == '.', "the icon of %v has the cell %c", kind, cell)
				filled += cell == '#' ? 1 : 0
			}
		}
		testing.expectf(t, filled > 0, "the icon of %v is empty", kind)
		joined := strings.join(description.cells[:], "", context.temp_allocator)
		if other, found := icons[joined]; found {
			testing.expectf(t, false, "the kinds %v and %v have the same icon", kind, other)
		}
		icons[joined] = kind
		// The surfaces of a table, in each form: the background and the
		// band of every second row.
		for is_light in ([]bool{false, true}) {
			colors := is_light ? light : dark
			color := site_value_color(kind, is_light)
			for under in ([]graphics.Color{colors.background, colors.card_top}) {
				ratio := site_contrast_ratio(color, under)
				testing.expectf(t, ratio >= SITE_VALUE_CONTRAST_LEAST, "the kind %v on %06x (light form: %v): a contrast of %.2f; at least %.1f", kind, u32(under), is_light, ratio, SITE_VALUE_CONTRAST_LEAST)
			}
		}
	}
	// The contrast itself: white on black is 21, and a color on itself is 1.
	testing.expect(t, site_contrast_ratio(0xFFFFFF, 0x000000) > 20.9)
	testing.expect(t, site_contrast_ratio(0x4A9CF0, 0x4A9CF0) < 1.01)
}

// The icon of each kind is an SVG file: one rect for each run of cells of
// a row, inside the grid; the style sheet names each file.
@(test)
site_value_icon_files :: proc(t: ^testing.T) {
	sheet := site_style_sheet("")
	for kind in Site_Value_Kind {
		if kind == .None {
			continue
		}
		svg := site_value_icon_svg(kind)
		testing.expect(t, strings.has_prefix(svg, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"12\" height=\"12\" viewBox=\"0 0 12 12\""))
		testing.expect(t, strings.has_suffix(svg, "</svg>\n"))
		runs := 0
		for row in site_value_kinds[kind].cells {
			for index in 0 ..< len(row) {
				if row[index] == '#' && (index == 0 || row[index - 1] != '#') {
					runs += 1
				}
			}
		}
		testing.expectf(t, strings.count(svg, "<rect ") == runs, "the icon of %v has %d rects for %d runs", kind, strings.count(svg, "<rect "), runs)
		testing.expect(t, !strings.contains(svg, "x=\"12\"") && !strings.contains(svg, "y=\"12\""))
		testing.expectf(t, strings.contains(sheet, fmt.tprintf("url(\"%s\")", site_value_icon_file(kind))), "the style sheet does not name the icon of %v", kind)
	}
}

// The markup of a value: one code element with the class of its kind,
// its text escaped, and the icon only when asked.
@(test)
site_value_markup :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	site_value(&b, .Handle, "a<b", true)
	testing.expect_value(t, strings.to_string(b), "<code class=\"value value-handle value-icon\">a&lt;b</code>")
	testing.expect_value(t, site_value_html(.Number, "3"), "<code class=\"value value-number\">3</code>")

	// A column of numbers shows the icon once, in its head; a column of a
	// stated kind too; a column of prose has none.
	table_builder := strings.builder_make(context.temp_allocator)
	table := site_table_start(&table_builder, "T", {{"Place", .Number}, {"Grant", .Name}, {"What", .Prose}}, {.None, .Grant, .None})
	strings.write_string(&table_builder, "<tr><td>1</td><td>x</td><td>y</td></tr>\n")
	site_table_end(&table_builder, table)
	html := strings.to_string(table_builder)
	testing.expect(t, strings.contains(html, "<th scope=\"col\" class=\"column-number value-head value-icon value-number\">Place</th>"))
	testing.expect(t, strings.contains(html, "<th scope=\"col\" class=\"column-name value-head value-icon value-grant\">Grant</th>"))
	testing.expect(t, strings.contains(html, "<th scope=\"col\" class=\"column-prose\">What</th>"))
	testing.expect(t, strings.contains(html, "<td class=\"column-number value value-number\">1</td><td class=\"column-name value value-grant\">x</td><td class=\"column-prose\">y</td>"))
	testing.expect_value(t, strings.count(html, "value-icon"), 2)

	// No value in a heading.
	testing.expect(t, site_heading_value_problem("<h2 id=\"x\"><code class=\"value value-number\">1</code></h2>") != "")
	testing.expect_value(t, site_heading_value_problem("<h2 id=\"x\">X</h2><p><code class=\"value value-number\">1</code></p>"), "")
}

// The legend lists every kind, with its icon.
@(test)
site_value_legend_lists_every_kind :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	site_value_legend(&b)
	html := strings.to_string(b)
	for kind in Site_Value_Kind {
		if kind == .None {
			continue
		}
		name := site_value_kinds[kind].name
		testing.expectf(t, strings.contains(html, fmt.tprintf("<tr id=\"value-kind-%s\"><td class=\"column-short\"><span class=\"value-icon value-%s\" aria-hidden=\"true\"></span></td>", name, name)), "the legend has no row for %v", kind)
	}
	testing.expect_value(t, site_heading_value_problem(html), "")
}

// The table of the context roles, from the files of the repository: the
// column "Handle or value" gives each cell its kind with its icon, and the
// place is a number, its icon in the head.
@(test)
site_value_kinds_of_the_context_roles :: proc(t: ^testing.T) {
	site := test_site()
	if !site_reference_read(&site) {
		testing.expect(t, false, "the sources of the reference cannot be read")
		return
	}
	entries := make([dynamic]Site_Reference_Entry, context.temp_allocator)
	site_generated_tables_add(&site, &entries)
	body := ""
	for page in site.pages {
		if page.path == site_page_file(SITE_CONTEXT_FOLDER) {
			body = page.body
		}
		testing.expectf(t, site_heading_value_problem(page.body) == "", "%s marks a value in a heading", page.path)
	}
	testing.expect(t, strings.contains(body, "<code class=\"value value-handle value-icon\">handle</code>"))
	testing.expect(t, strings.contains(body, "<code class=\"value value-value value-icon\">value</code>"))
	testing.expect(t, strings.contains(body, "<th scope=\"col\" class=\"column-number value-head value-icon value-number\">Place</th>"))
	testing.expect(t, strings.contains(body, "<td class=\"column-number value value-number\">"))
}
