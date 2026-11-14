// The name of the mark on the site (docs/SITE.md, "The name of the mark"):
// the pictures of the mark on a page show the heron alone, and the name is
// text in the font of the name of the mark (mark_font.odin), beside the
// heron. The text stays text: a reader selects it, and a screen reader says
// it. One class gives the font, and one procedure writes the markup.
//
// Also here, because it follows from the same choice: the description of
// the heron alone.
package kerneltool

import "core:fmt"
import "core:strings"
import "support:mark"

// The font in the site. Its address carries no version: the preload of a
// page and the rule of the style sheet must name the same address, and its
// bytes change only when a letter of the mark changes.
SITE_MARK_FONT :: "fonts/" + MARK_FONT_FILE_NAME

SITE_MARK_NAME_CLASS :: "mark-name"
// The name of the system as the mark: the one markup of the bar, of the
// foot and of the head of the home.
SITE_MARK_NAME_HTML :: "<span class=\"" + SITE_MARK_NAME_CLASS + "\">" + SITE_SYSTEM_NAME + "</span>"

// The pixels of a cell of the name: in the bar and in the foot, and in the
// head of the home (the cell of the name that the picture of the home had).
// A cell is a whole count of pixels of the page, so it is a whole count of
// pixels of the screen at each whole density, and at the density 1.5 for an
// even cell size.
SITE_MARK_NAME_CELL_SIZE :: 2
SITE_MARK_NAME_HOME_CELL_SIZE :: 6

// site_mark_name_font_size gives the font size, in pixels, at which a cell
// of the name is cell_size pixels: the em of the font is a whole count of
// cells.
site_mark_name_font_size :: proc(cell_size: int) -> int {
	return cell_size * MARK_FONT_CELLS_OF_THE_EM
}

// site_mark_name_rules gives the rules of the style sheet for the name of
// the mark: the font, and the class at its two sizes.
//
// The font answers to every weight, and the class asks for no made-up bold
// or slanted face: the name is in a bold link in the bar, and a browser
// that thickens the squares makes them blur.
//
// The box of the name has the size of the name in cells, whatever font
// draws the text: while the font loads the text is not shown (it never
// shows in another font first, then changes), and nothing beside it moves
// when the font arrives. A browser that cannot load the font shows the name
// in the monospace font, inside the same box. The box is one row of cells
// higher than the name, under the baseline, and is moved down by that row:
// the letters stand on the baseline of the text beside them.
site_mark_name_rules :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "/* The name of the mark: text in the font of its letters. */\n")
	strings.write_string(&b, "@font-face { font-family: \"" + MARK_FONT_FAMILY + "\"; src: url(\"" + SITE_MARK_FONT + "\") format(\"truetype\"); font-weight: 100 900; font-style: normal; font-display: block; }\n")
	strings.write_string(&b, "." + SITE_MARK_NAME_CLASS + " { display: inline-block; overflow: hidden; white-space: nowrap; font-family: \"" + MARK_FONT_FAMILY + "\", var(--mono); font-weight: 400; font-style: normal; font-synthesis: none; font-kerning: none; font-variant-ligatures: none; letter-spacing: 0; text-transform: none; ")
	site_mark_name_size_write(&b, SITE_MARK_NAME_CELL_SIZE)
	strings.write_string(&b, "}\n.foot ." + SITE_MARK_NAME_CLASS + " { color: var(--text); margin-right: 4px; }\n")
	strings.write_string(&b, ".home-head ." + SITE_MARK_NAME_CLASS + " { ")
	site_mark_name_size_write(&b, SITE_MARK_NAME_HOME_CELL_SIZE)
	strings.write_string(&b, "}\n")
	return strings.to_string(b)
}

// site_mark_name_size_write writes the sizes of the name at a cell size:
// the box of the name, the font size, and the move down by the row under
// the baseline.
@(private = "file")
site_mark_name_size_write :: proc(b: ^strings.Builder, cell_size: int) {
	width, _ := mark.name_size(cell_size)
	font_size := site_mark_name_font_size(cell_size)
	fmt.sbprintf(b, "width: %dpx; height: %dpx; font-size: %dpx; line-height: %dpx; vertical-align: -%dpx; ", width, font_size, font_size, font_size, font_size - mark.NAME_ROWS * cell_size)
}

// site_mark_font_preload writes the line of the head of a page that asks
// for the font before the style sheet is read: the bar of each page shows
// the name on the first screen. A font is fetched with the rules of another
// origin even from its own site, so the line says `crossorigin`: without
// it the browser fetches the font two times.
site_mark_font_preload :: proc(b: ^strings.Builder, page_path: string) {
	fmt.sbprintf(b, "<link rel=\"preload\" href=\"%s\" as=\"font\" type=\"font/ttf\" crossorigin>\n", site_relative(page_path, SITE_MARK_FONT))
}

// The words of the description of the mark in README.md that say where the
// name is in the picture of the README.
SITE_MARK_DESCRIPTION_NAME_PART :: ", above the name"

// site_heron_description gives the description of a picture of the heron
// alone: the description of the mark of README.md, up to the words about
// the name under the heron. A description with no such words is whole.
site_heron_description :: proc(mark_description: string) -> string {
	if cut := strings.last_index(mark_description, SITE_MARK_DESCRIPTION_NAME_PART); cut > 0 {
		return mark_description[:cut]
	}
	return mark_description
}
