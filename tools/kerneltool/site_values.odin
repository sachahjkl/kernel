// The kinds of the technical values that the site shows (docs/SITE.md,
// "The kinds of values"). The rule of the desktop holds on the site: a name
// in the reading font, a value in the monospace font (docs/DESIGN.md, "Two
// fonts"). Each value also has the accent and the icon of its kind, so that
// a person tells a handle from a number at a glance. The writer of a table
// or of a symbol states the kind of each value that it writes; no text is
// classified by its look, but a column of the kind Number or Date, whose
// writer already stated what it holds.
package kerneltool

import "core:fmt"
import "core:math"
import "core:strings"
import "support:graphics"

// The icons are pixel forms on a grid of 12 by 12 cells, as the heron of
// the mark is: each cell is one pixel at the size that the site shows.
SITE_VALUE_ICON_SIZE :: 12
SITE_VALUE_ICON_FOLDER :: "pictures/values"
// The least contrast of the text of a value on each surface of a table,
// in both color schemes (WCAG 2, the bound of normal text).
SITE_VALUE_CONTRAST_LEAST :: 4.5

Site_Value_Kind :: enum {
	None, // Not a value: the cell is a name or a text.
	Number,
	Size,
	Time,
	Handle,
	Value,
	Grant,
	Status,
	Type,
	Operation,
	Command,
	Module,
	File,
	Version,
	Yes,
	No,
}

Site_Value_Kind_Description :: struct {
	name:          string, // The class "value-<name>" and the file of the icon.
	title:         string, // In the legend.
	meaning:       string, // One line, in the legend.
	color:         graphics.Color, // An accent of the design rules.
	dark_percent:  u32, // graphics.shade of the accent in the dark form: 100 is the accent itself.
	light_percent: u32, // graphics.shade of the accent in the light form: darker, for its contrast on white.
	cells:         [SITE_VALUE_ICON_SIZE]string, // "#" is a cell of the icon, "." is empty.
}

// The one table of the kinds. The accents are those of the design rules,
// by what they mean on the desktop: the kernel blue for what the kernel
// names, the program green for what a person runs, the memory teal for
// numbers, the machine pink for what the root service gives, the color of
// the boot program for time and versions, the red of a failure for a
// status, the dim color for a place in the repository and for "no".
site_value_kinds := [Site_Value_Kind]Site_Value_Kind_Description {
	.None = {},
	.Number = {
		name = "number", title = "Number", meaning = "A count, a place, an index or an address.",
		color = graphics.COLOR_MEMORY, dark_percent = 100, light_percent = 65,
		cells = {"............", "...##..##...", "...##..##...", ".##########.", "...##..##...", "...##..##...", "...##..##...", ".##########.", "...##..##...", "...##..##...", "............", "............"},
	},
	.Size = {
		name = "size", title = "Size", meaning = "A size in bytes or in pages.",
		color = graphics.COLOR_MEMORY, dark_percent = 100, light_percent = 65,
		cells = {"............", "..########..", "..########..", "............", ".##########.", ".##########.", "............", "############", "############", "............", "............", "............"},
	},
	.Time = {
		name = "time", title = "Time", meaning = "A duration, a date or a time.",
		color = graphics.COLOR_BOOT_PROGRAM, dark_percent = 100, light_percent = 65,
		cells = {"............", ".##########.", ".#........#.", ".#...##...#.", ".#...##...#.", ".#...####.#.", ".#...####.#.", ".#........#.", ".#........#.", ".##########.", "............", "............"},
	},
	.Handle = {
		name = "handle", title = "Handle", meaning = "A handle of a kernel object, held by a program.",
		color = graphics.COLOR_KERNEL, dark_percent = 100, light_percent = 73,
		cells = {"............", "...######...", "...#....#...", "...#....#...", "...######...", ".....##.....", ".....##.....", ".....##.....", "....####....", "....####....", "............", "............"},
	},
	.Value = {
		name = "value", title = "Value", meaning = "A plain value of the context of a program: not a handle.",
		color = graphics.COLOR_MEMORY, dark_percent = 100, light_percent = 65,
		cells = {"............", "............", "............", "....####....", "....####....", "....####....", "....####....", "............", "............", "............", "............", "............"},
	},
	.Grant = {
		name = "grant", title = "Grant", meaning = "What the root service gives a program, or records and can revoke.",
		color = graphics.COLOR_MACHINE, dark_percent = 100, light_percent = 78,
		cells = {"............", "..........##", ".........##.", "........##..", ".......##...", "##....##....", ".##..##.....", "..####......", "...##.......", "............", "............", "............"},
	},
	.Status = {
		name = "status", title = "Status", meaning = "A status, an error kind or the state of a property.",
		color = graphics.COLOR_FAILED, dark_percent = 100, light_percent = 78,
		cells = {"............", ".##.........", ".#######....", ".########...", ".#######....", ".##.........", ".##.........", ".##.........", ".##.........", ".##.........", "............", "............"},
	},
	.Type = {
		name = "type", title = "Type", meaning = "A type of the module contract: Integer, Text, a record, Table, Bytes, Handle.",
		color = graphics.COLOR_FIRMWARE, dark_percent = 115, light_percent = 83,
		cells = {"............", "...##..##...", "..##....##..", ".##......##.", "##........##", ".##......##.", "..##....##..", "...##..##...", "............", "............", "............", "............"},
	},
	.Operation = {
		name = "operation", title = "Operation", meaning = "An operation that a program asks the kernel.",
		color = graphics.COLOR_KERNEL, dark_percent = 100, light_percent = 73,
		cells = {"............", "......######", "......#....#", "......#....#", "##########.#", "##########.#", "......#....#", "......#....#", "......######", "............", "............", "............"},
	},
	.Command = {
		name = "command", title = "Command", meaning = "A command of the console or of kerneltool.",
		color = graphics.COLOR_PROGRAM, dark_percent = 100, light_percent = 58,
		cells = {"............", ".##.........", "..##........", "...##.......", "....##......", "...##.......", "..##........", ".##...#####.", "......#####.", "............", "............", "............"},
	},
	.Module = {
		name = "module", title = "Module", meaning = "A module or a program of the boot image or of the build.",
		color = graphics.COLOR_PROGRAM, dark_percent = 100, light_percent = 58,
		cells = {"............", ".###....###.", ".###....###.", ".##########.", ".##########.", ".##########.", ".##########.", ".##########.", "............", "............", "............", "............"},
	},
	.File = {
		name = "file", title = "File", meaning = "A file or a folder of the repository.",
		color = graphics.COLOR_DIM, dark_percent = 100, light_percent = 82,
		cells = {".######.....", ".#....##....", ".#.....##...", ".#......##..", ".#.......#..", ".#.......#..", ".#.......#..", ".#.......#..", ".#.......#..", ".#########..", "............", "............"},
	},
	.Version = {
		name = "version", title = "Version", meaning = "A version, a release, a commit or a hash.",
		color = graphics.COLOR_BOOT_PROGRAM, dark_percent = 100, light_percent = 65,
		cells = {"............", "...#######..", "..##.....#..", ".##..##..#..", ".##..##..#..", "..##.....#..", "...#######..", "............", "............", "............", "............", "............"},
	},
	.Yes = {
		name = "yes", title = "Yes", meaning = "A state that holds: in the boot image, measured.",
		color = graphics.COLOR_PROGRAM, dark_percent = 100, light_percent = 58,
		cells = {"............", ".##########.", ".##########.", ".##########.", ".##########.", ".##########.", ".##########.", ".##########.", ".##########.", ".##########.", "............", "............"},
	},
	.No = {
		name = "no", title = "No", meaning = "A state that does not hold: not in the boot image, not built.",
		color = graphics.COLOR_DIM, dark_percent = 100, light_percent = 82,
		cells = {"............", ".##########.", ".#........#.", ".#........#.", ".#........#.", ".#........#.", ".#........#.", ".#........#.", ".#........#.", ".##########.", "............", "............"},
	},
}

// site_value_color gives the color of the text of a kind in one form.
site_value_color :: proc(kind: Site_Value_Kind, light: bool) -> graphics.Color {
	description := site_value_kinds[kind]
	return graphics.shade(description.color, light ? description.light_percent : description.dark_percent)
}

// site_value_icon_file gives the file of the icon of a kind in the site.
site_value_icon_file :: proc(kind: Site_Value_Kind) -> string {
	return strings.concatenate({SITE_VALUE_ICON_FOLDER, "/", site_value_kinds[kind].name, ".svg"}, context.temp_allocator)
}

// site_value writes a value of a kind: one code element in the monospace
// font, in the accent of the kind, with a thin rule at its left. With its
// icon only where the column head or the label does not say the kind: the
// icon is decoration, and the text says the value.
site_value :: proc(b: ^strings.Builder, kind: Site_Value_Kind, text: string, with_icon: bool) {
	icon_class: string = with_icon ? " value-icon" : ""
	fmt.sbprintf(b, "<code class=\"value value-%s%s\">", site_value_kinds[kind].name, icon_class)
	site_escape(b, text)
	strings.write_string(b, "</code>")
}

// site_value_html gives the markup of a value with no icon, for a fact of
// a symbol whose label carries the icon.
site_value_html :: proc(kind: Site_Value_Kind, text: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	site_value(&b, kind, text, false)
	return strings.to_string(b)
}

// site_value_link writes a value that is a link: the link holds the value.
site_value_link :: proc(b: ^strings.Builder, kind: Site_Value_Kind, address, text: string, with_icon: bool) {
	strings.write_string(b, "<a href=\"")
	site_escape(b, address)
	strings.write_string(b, "\">")
	site_value(b, kind, text, with_icon)
	strings.write_string(b, "</a>")
}

// site_value_icon_svg gives the icon of a kind as an SVG file: one rect for
// each run of cells of a row, in black: the style sheet uses the file as a
// mask, so the icon takes the color of its kind.
site_value_icon_svg :: proc(kind: Site_Value_Kind) -> string {
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

// site_value_icons_write writes the icon of each kind into the site.
site_value_icons_write :: proc(site: ^Site) -> bool {
	for kind in Site_Value_Kind {
		if kind == .None {
			continue
		}
		site_write_file(site, site_value_icon_file(kind), transmute([]u8)site_value_icon_svg(kind)) or_return
	}
	return true
}

// site_value_rules gives the rules of the style sheet for the kinds: the
// color and the icon of each kind, in one form. The address of an icon is
// relative to the style sheet, which is at the root of the site.
site_value_rules :: proc(light: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	for kind in Site_Value_Kind {
		if kind == .None {
			continue
		}
		fmt.sbprintf(&b, ".value-%s {{ --value-color: %s; --value-icon: url(\"%s\"); }}\n", site_value_kinds[kind].name, site_color(site_value_color(kind, light)), site_value_icon_file(kind))
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
	for kind in Site_Value_Kind {
		if kind == .None {
			continue
		}
		description := site_value_kinds[kind]
		fmt.sbprintf(b, "<tr id=\"value-kind-%s\"><td><span class=\"value-icon value-%s\" aria-hidden=\"true\"></span></td><td>", description.name, description.name)
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
