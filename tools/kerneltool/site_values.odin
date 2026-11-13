// The kinds of the technical values that the site shows (docs/SITE.md,
// "The kinds of values"). The rule of the desktop holds on the site: a name
// in the reading font, a value in the monospace font (docs/DESIGN.md, "Two
// fonts"). Each value also has the accent and the icon of its kind, so that
// a person tells a handle from a number at a glance. The writer of a table
// or of a symbol states the kind of each value that it writes; no text is
// classified by its look, but a column of the kind Number or Date, whose
// writer already stated what it holds.
package kerneltool

import "contract:value_kinds"
import "core:fmt"
import "core:math"
import "core:strings"
import "support:graphics"

// The icons are pixel forms on a grid of 12 by 12 cells, as the heron of
// the mark is: each cell is one pixel at the size that the site shows.
SITE_VALUE_ICON_SIZE :: 12
// The least contrast of the text of a value on each surface of a table,
// in both color schemes (WCAG 2, the bound of normal text).
SITE_VALUE_CONTRAST_LEAST :: 4.5
// The least contrast of a graphic: an icon of a kind or a bar of the chart
// of the docs home on each surface where it is drawn (WCAG 2.1, 1.4.11).
SITE_VALUE_GRAPHIC_CONTRAST_LEAST :: 3.0

// The kinds are value_kinds.Value_Kind, the one enumeration of the system
// (contract/value_kinds): a log record of the system keeps the same kinds.

Site_Value_Kind_Description :: struct {
	title:         string, // In the legend.
	meaning:       string, // One line, in the legend.
	cells:         [SITE_VALUE_ICON_SIZE]string, // "#" is a cell of the icon, "." is empty.
}

// The one table of the names, the meanings and the icons of the kinds. The
// color of each kind is in the table of the system, which the programs
// read too (support/graphics/value_colors.odin).
site_value_kinds := [value_kinds.Value_Kind]Site_Value_Kind_Description {
	.None = {},
	.Number = {
		title = "Number", meaning = "A count, a place, an index or an address.",
		cells = {"............", "...##..##...", "...##..##...", ".##########.", "...##..##...", "...##..##...", "...##..##...", ".##########.", "...##..##...", "...##..##...", "............", "............"},
	},
	.Size = {
		title = "Size", meaning = "A size in bytes or in pages.",
		cells = {"............", "..########..", "..########..", "............", ".##########.", ".##########.", "............", "############", "############", "............", "............", "............"},
	},
	.Time = {
		title = "Time", meaning = "A duration, a date or a time.",
		cells = {"............", ".##########.", ".#........#.", ".#...##...#.", ".#...##...#.", ".#...####.#.", ".#...####.#.", ".#........#.", ".#........#.", ".##########.", "............", "............"},
	},
	.Handle = {
		title = "Handle", meaning = "A handle of a kernel object, held by a program.",
		cells = {"............", "...######...", "...#....#...", "...#....#...", "...######...", ".....##.....", ".....##.....", ".....##.....", "....####....", "....####....", "............", "............"},
	},
	.Value = {
		title = "Value", meaning = "A plain value of the context of a program: not a handle.",
		cells = {"............", "............", "............", "....####....", "....####....", "....####....", "....####....", "............", "............", "............", "............", "............"},
	},
	.Grant = {
		title = "Grant", meaning = "What the root service gives a program, or records and can revoke.",
		cells = {"............", "..........##", ".........##.", "........##..", ".......##...", "##....##....", ".##..##.....", "..####......", "...##.......", "............", "............", "............"},
	},
	.Status = {
		title = "Status", meaning = "A status, an error kind or the state of a property.",
		cells = {"............", ".##.........", ".#######....", ".########...", ".#######....", ".##.........", ".##.........", ".##.........", ".##.........", ".##.........", "............", "............"},
	},
	.Type = {
		title = "Type", meaning = "A type: of the contract, a wire form of the module contract, a record of a module, or a basic type.",
		cells = {"............", "...##..##...", "..##....##..", ".##......##.", "##........##", ".##......##.", "..##....##..", "...##..##...", "............", "............", "............", "............"},
	},
	.Operation = {
		title = "Operation", meaning = "An operation that a program asks the kernel.",
		cells = {"............", "......######", "......#....#", "......#....#", "##########.#", "##########.#", "......#....#", "......#....#", "......######", "............", "............", "............"},
	},
	.Command = {
		title = "Command", meaning = "A command of the console or of kerneltool.",
		cells = {"............", ".##.........", "..##........", "...##.......", "....##......", "...##.......", "..##........", ".##...#####.", "......#####.", "............", "............", "............"},
	},
	.Module = {
		title = "Module", meaning = "A module or a program of the boot image or of the build.",
		cells = {"............", ".###....###.", ".###....###.", ".##########.", ".##########.", ".##########.", ".##########.", ".##########.", "............", "............", "............", "............"},
	},
	.File = {
		title = "File", meaning = "A file or a folder of the repository.",
		cells = {".######.....", ".#....##....", ".#.....##...", ".#......##..", ".#.......#..", ".#.......#..", ".#.......#..", ".#.......#..", ".#.......#..", ".#########..", "............", "............"},
	},
	// A document is text to read: the color of the text. Its reference is
	// a name in the reading font, not a value: the kind gives its color and
	// its icon (docs/SITE.md, "The references to documents").
	.Guide = {
		title = "Guide", meaning = "A document of the site, a guide or the glossary, and the heading that a reference names; a working record is a file of the repository.",
		cells = {"............", ".##########.", ".#........#.", ".#.######.#.", ".#........#.", ".#.######.#.", ".#........#.", ".#.####...#.", ".#........#.", ".##########.", "............", "............"},
	},
	// A term of the glossary is a name, not a value, as a document is: the
	// kind gives the glossary and the terms of the search their icon and
	// their color, so that a term does not look like a guide section.
	.Term = {
		title = "Term", meaning = "A term of the glossary: one name for one concept.",
		cells = {"............", ".##########.", ".##########.", ".....##.....", ".....##.....", ".....##.....", ".....##.....", ".....##.....", ".....##.....", "....####....", "............", "............"},
	},
	.Version = {
		title = "Version", meaning = "A version, a release, a commit or a hash.",
		cells = {"............", "...#######..", "..##.....#..", ".##..##..#..", ".##..##..#..", "..##.....#..", "...#######..", "............", "............", "............", "............", "............"},
	},
	.Yes = {
		title = "Yes", meaning = "A state that holds: in the boot image, measured.",
		cells = {"............", ".##########.", ".##########.", ".##########.", ".##########.", ".##########.", ".##########.", ".##########.", ".##########.", ".##########.", "............", "............"},
	},
	.No = {
		title = "No", meaning = "A state that does not hold: not in the boot image, not built.",
		cells = {"............", ".##########.", ".#........#.", ".#........#.", ".#........#.", ".#........#.", ".#........#.", ".#........#.", ".#........#.", ".##########.", "............", "............"},
	},
	// The three kinds of a declaration of the sources that are not a type
	// (docs/SITE.md, "The declarations of the sources"). A procedure is
	// called as an operation is: the kernel blue. A constant is a literal
	// of the code: the color of a literal, with a lock. A global variable
	// changes over the run, as a time does: the color of the boot program.
	.Procedure = {
		title = "Procedure", meaning = "A procedure that the sources of the system declare.",
		cells = {"............", "...#....#...", "..##....##..", "..#......#..", ".##......##.", ".##......##.", ".##......##.", "..#......#..", "..##....##..", "...#....#...", "............", "............"},
	},
	.Constant = {
		title = "Constant", meaning = "A constant that the sources of the system declare.",
		cells = {"............", "....####....", "...#....#...", "...#....#...", "..########..", "..########..", "..###..###..", "..###..###..", "..########..", "..########..", "............", "............"},
	},
	.Variable = {
		title = "Global variable", meaning = "A variable that the sources of the system declare at the top of a package.",
		cells = {"............", ".##......##.", "..##....##..", "...##..##...", "....####....", ".....##.....", "....####....", "...##..##...", "..##....##..", ".##......##.", "............", "............"},
	},
}

// site_value_color gives the color of the text of a kind in one form.
site_value_color :: proc(kind: value_kinds.Value_Kind, light: bool) -> graphics.Color {
	return graphics.value_kind_color(kind, light)
}

// site_value writes a value of a kind: one code element in the monospace
// font, in the accent of the kind, with a thin rule at its left. With its
// icon only where the column head or the label does not say the kind: the
// icon is decoration, and the text says the value.
site_value :: proc(b: ^strings.Builder, kind: value_kinds.Value_Kind, text: string, with_icon: bool) {
	icon_class: string = with_icon ? " value-icon" : ""
	fmt.sbprintf(b, "<code class=\"value value-%s%s\">", value_kinds.VALUE_KIND_NAMES[kind], icon_class)
	site_escape(b, text)
	strings.write_string(b, "</code>")
}

// site_value_html gives the markup of a value with no icon, for a fact of
// a symbol whose label carries the icon.
site_value_html :: proc(kind: value_kinds.Value_Kind, text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	site_value(&b, kind, text, false)
	return strings.to_string(b)
}

// site_value_html_with_icon gives the markup of a value with its icon, for
// a cell of values of several kinds.
site_value_html_with_icon :: proc(kind: value_kinds.Value_Kind, text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	site_value(&b, kind, text, true)
	return strings.to_string(b)
}

// site_value_link writes a value that is a link: the link holds the value.
site_value_link :: proc(b: ^strings.Builder, kind: value_kinds.Value_Kind, address, text: string, with_icon: bool) {
	strings.write_string(b, "<a href=\"")
	site_escape(b, address)
	strings.write_string(b, "\">")
	site_value(b, kind, text, with_icon)
	strings.write_string(b, "</a>")
}

// site_value_list writes several values as one list, each item the markup
// of one value. A name never breaks inside; the list breaks between its
// names, so a cell of many names takes several lines and no comma starts a
// line (docs/SITE.md, "The tables"). A screen reader reads the count.
site_value_list :: proc(b: ^strings.Builder, items: []string) {
	strings.write_string(b, "<ul class=\"value-list\">")
	for item in items {
		strings.write_string(b, "<li>")
		strings.write_string(b, item)
		strings.write_string(b, "</li>")
	}
	strings.write_string(b, "</ul>")
}

// site_value_list_html gives the markup of site_value_list, for a fact of a
// symbol.
site_value_list_html :: proc(items: []string) -> string {
	b := strings.builder_make(context.temp_allocator)
	site_value_list(&b, items)
	return strings.to_string(b)
}

// site_value_link_html gives the markup of site_value_link.
site_value_link_html :: proc(kind: value_kinds.Value_Kind, address, text: string, with_icon: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	site_value_link(&b, kind, address, text, with_icon)
	return strings.to_string(b)
}

// site_value_icon_svg gives the icon of a kind as an SVG picture: one rect
// for each run of cells of a row, in black: the style sheet uses it as a
// mask, so the icon takes the color of its kind.
site_value_icon_svg :: proc(kind: value_kinds.Value_Kind) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" shape-rendering=\"crispEdges\">", SITE_VALUE_ICON_SIZE, SITE_VALUE_ICON_SIZE, SITE_VALUE_ICON_SIZE, SITE_VALUE_ICON_SIZE)
	for row, y in site_value_kinds[kind].cells {
		x := 0
		for x < len(row) {
			if row[x] != '#' {
				x += 1
				continue
			}
			start := x
			for x < len(row) && row[x] == '#' {
				x += 1
			}
			fmt.sbprintf(&b, "<rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"1\"/>", start, y, x - start)
		}
	}
	strings.write_string(&b, "</svg>\n")
	return strings.to_string(b)
}

// site_value_icon_address gives the icon of a kind as a data address of the
// style sheet. Its source stays the cells of the table; only its delivery
// is inside the style sheet: a file for each icon was one more request for
// each, which the browser learns of only after the style sheet, so the
// icons came after the first paint (docs/SITE.md, "The kinds of values").
site_value_icon_address :: proc(kind: value_kinds.Value_Kind) -> string {
	return site_svg_data_address(site_value_icon_svg(kind))
}

// site_value_rules gives the rules of the style sheet for the kinds, in one
// form: the color of each kind, and in the dark form, which comes first and
// holds for both, its icon. The icon is the same in both forms, so the
// style sheet holds it once.
site_value_rules :: proc(light: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	for kind in value_kinds.Value_Kind {
		if kind == .None {
			continue
		}
		fmt.sbprintf(&b, ".value-%s {{ --value-color: %s;", value_kinds.VALUE_KIND_NAMES[kind], site_color(site_value_color(kind, light)))
		if !light {
			fmt.sbprintf(&b, " --value-icon: url(\"%s\");", site_value_icon_address(kind))
		}
		strings.write_string(&b, " }\n")
	}
	return strings.to_string(b)
}

// site_relative_luminance gives the relative luminance of a color (WCAG 2).
site_relative_luminance :: proc(color: graphics.Color) -> f64 {
	channel :: proc(value: u32) -> f64 {
		part := f64(value) / 255
		return part <= 0.03928 ? part / 12.92 : math.pow((part + 0.055) / 1.055, 2.4)
	}
	value := u32(color)
	return 0.2126 * channel((value >> 16) & 0xFF) + 0.7152 * channel((value >> 8) & 0xFF) + 0.0722 * channel(value & 0xFF)
}

// site_contrast_ratio gives the contrast ratio of two colors (WCAG 2).
site_contrast_ratio :: proc(first, second: graphics.Color) -> f64 {
	lighter := site_relative_luminance(first)
	darker := site_relative_luminance(second)
	if lighter < darker {
		lighter, darker = darker, lighter
	}
	return (lighter + 0.05) / (darker + 0.05)
}

// site_value_legend writes the table of the kinds: the icon, the kind and
// what it holds. It is generated from the same table as the style sheet.
site_value_legend :: proc(b: ^strings.Builder) {
	strings.write_string(b, "<h2 id=\"kinds-of-values\">The kinds of values</h2>\n<p>A value is in the monospace font and in the color of its kind. The icon of a kind is in the head of a column of that kind, before the label of a fact, or before a value whose kind its column does not say.</p>\n")
	legend := site_table_start(b, "The kinds of values", {{"Icon", .Short}, {"Kind", .Name}, {"What it holds", .Prose}})
	for kind in value_kinds.Value_Kind {
		if kind == .None {
			continue
		}
		description := site_value_kinds[kind]
		fmt.sbprintf(b, "<tr id=\"value-kind-%s\"><td><span class=\"value-icon value-%s\" aria-hidden=\"true\"></span></td><td>", value_kinds.VALUE_KIND_NAMES[kind], value_kinds.VALUE_KIND_NAMES[kind])
		site_value(b, kind, description.title, false)
		strings.write_string(b, "</td>")
		site_text_cell(b, description.meaning)
		strings.write_string(b, "</tr>\n")
	}
	site_table_end(b, legend)
}

// site_heading_value_problem gives the fault of a page that marks a value
// inside a heading, or "": a heading holds no icon and no colored value.
site_heading_value_problem :: proc(html: string) -> string {
	for level in ([]string{"1", "2", "3", "4"}) {
		open := strings.concatenate({"<h", level}, context.temp_allocator)
		close := strings.concatenate({"</h", level, ">"}, context.temp_allocator)
		rest := html
		for {
			start := strings.index(rest, open)
			if start < 0 {
				break
			}
			rest = rest[start:]
			end := strings.index(rest, close)
			if end < 0 {
				break
			}
			if strings.contains(rest[:end], "class=\"value") {
				return "a heading holds a value of a kind; a heading holds no icon and no colored value"
			}
			rest = rest[end:]
		}
	}
	return ""
}
