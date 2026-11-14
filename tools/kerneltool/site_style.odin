// The style sheet of the site. Its colors come from the table of the design
// rules (support/graphics/rules.odin, docs/DESIGN.md) and from the mark
// (support/mark): the site repeats no color of the rules as its own number.
package kerneltool

import "core:fmt"
import "core:strings"
import "support:graphics"
import "support:mark"

// The level of graphics.mix for a percent.
site_percent :: proc(percent: u32) -> u32 {
	return percent * 255 / 100
}

site_color :: proc(color: graphics.Color) -> string {
	return fmt.tprintf("#%06x", u32(color) & 0xFFFFFF)
}

// site_svg_data_address gives an SVG picture as a data address for the
// style sheet, so that a page asks for no other file to draw it. The
// characters that end the address or start a fragment or an escape are
// percent-encoded, a double quote becomes a single one (the address is
// inside url("...")), and a line feed is dropped.
site_svg_data_address :: proc(svg: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "data:image/svg+xml,")
	for index in 0 ..< len(svg) {
		switch svg[index] {
		case '%':
			strings.write_string(&b, "%25")
		case '<':
			strings.write_string(&b, "%3C")
		case '>':
			strings.write_string(&b, "%3E")
		case '#':
			strings.write_string(&b, "%23")
		case '"':
			strings.write_byte(&b, '\'')
		case '\n', '\r':
		case:
			strings.write_byte(&b, svg[index])
		}
	}
	return strings.to_string(b)
}

site_variable :: proc(builder: ^strings.Builder, name: string, color: graphics.Color) {
	strings.write_string(builder, "  --")
	strings.write_string(builder, name)
	strings.write_string(builder, ": ")
	strings.write_string(builder, site_color(color))
	strings.write_string(builder, ";\n")
}

// The colors of one form of the page: dark or light.
Site_Colors :: struct {
	background:  graphics.Color,
	card_top:    graphics.Color,
	card_bottom: graphics.Color,
	track:       graphics.Color,
	text:        graphics.Color,
	dim:         graphics.Color,
	line:        graphics.Color, // The line under a link, and the outline of the focus.
	match:       graphics.Color, // The characters that the search matched.
	on_light:    bool,
}

site_dark_colors :: proc() -> Site_Colors {
	return Site_Colors{background = graphics.COLOR_BACKGROUND, card_top = graphics.COLOR_CARD_TOP, card_bottom = graphics.COLOR_CARD_BOTTOM, track = graphics.COLOR_TRACK, text = graphics.COLOR_TEXT, dim = graphics.COLOR_DIM, line = graphics.COLOR_TITLE, match = graphics.COLOR_BOOT_PROGRAM}
}

// The light form: the light background of the mark, white cards, the text
// in the color of the dark background (as the name of the light mark), and
// the dim color at 60 % so that it keeps its contrast on white.
site_light_colors :: proc() -> Site_Colors {
	background := graphics.Color(mark.BACKGROUND_LIGHT)
	return Site_Colors {
		background = background,
		card_top = graphics.COLOR_WHITE,
		card_bottom = graphics.mix(graphics.COLOR_WHITE, background, site_percent(50)),
		track = graphics.mix(background, graphics.COLOR_DIM, site_percent(25)),
		text = graphics.Color(mark.name_color(true)),
		dim = graphics.shade(graphics.COLOR_DIM, 60),
		line = graphics.COLOR_TITLE,
		// The accent at half its light keeps its contrast on white.
		match = graphics.shade(graphics.COLOR_BOOT_PROGRAM, 50),
		on_light = true,
	}
}

// site_colors_write writes the variables of one form: the surfaces, the
// text, and for each accent its color, the color of a title in it, and the
// border of a card in it (28 % of the accent at the top, 14 % at the bottom).
site_colors_write :: proc(builder: ^strings.Builder, colors: Site_Colors) {
	strings.write_string(builder, ":root {\n")
	site_variable(builder, "background", colors.background)
	site_variable(builder, "card-top", colors.card_top)
	site_variable(builder, "card-bottom", colors.card_bottom)
	site_variable(builder, "track", colors.track)
	site_variable(builder, "text", colors.text)
	site_variable(builder, "dim", colors.dim)
	site_variable(builder, "line", colors.line)
	site_variable(builder, "match", colors.match)
	strings.write_string(builder, "}\n")
	for accent in site_accents {
		strings.write_string(builder, ".")
		strings.write_string(builder, accent.class_name)
		strings.write_string(builder, " {\n")
		site_variable(builder, "accent", accent.color)
		// On the light background an accent as text has too little
		// contrast: the titles take the text color there.
		site_variable(builder, "accent-text", colors.on_light ? colors.text : accent.color)
		// A form that carries a fact in the accent: a segment, a bar.
		site_variable(builder, "accent-graphic", site_accent_graphic_color(accent, colors.on_light))
		site_variable(builder, "border-top", graphics.mix(colors.card_top, accent.color, site_percent(28)))
		site_variable(builder, "border-bottom", graphics.mix(colors.card_bottom, accent.color, site_percent(14)))
		strings.write_string(builder, "}\n")
	}
}

// The rules of the pages that hold no color. The grid of the design rules:
// each size is a multiple of 8 pixels (4 inside a form). Prose is in the
// reading font of the reader's system, at most 72 characters a line; code,
// signatures, numbers and identifiers are in its monospace font. No
// animation, no shadow, no round corner.
SITE_STYLE_RULES :: `*, *::before, *::after { box-sizing: border-box; }
:root {
  --reading: system-ui, -apple-system, "Segoe UI", Roboto, "Noto Sans", "Helvetica Neue", Arial, sans-serif;
  --mono: ui-monospace, "SF Mono", "Cascadia Mono", "JetBrains Mono", "DejaVu Sans Mono", "Liberation Mono", Menlo, Consolas, monospace;
  /* A tree line: the track alone is too near the surface of the tree to
     show a line of 1 pixel, and the dim color alone is the color of a text. */
  --tree-line: color-mix(in srgb, var(--dim) 40%, var(--track));
}
html {
  background: var(--background);
  color: var(--text);
  font-family: var(--reading);
  font-size: 16px;
  line-height: 24px;
  -webkit-text-size-adjust: 100%;
  text-size-adjust: 100%;
}
body { margin: 0; }
.page { max-width: 1152px; margin: 0 auto; padding: 0 16px; }
code, pre, kbd, .code, .label { font-family: var(--mono); font-size: 14px; }
code { color: var(--text); background: var(--track); padding: 0 4px; overflow-wrap: anywhere; }
pre { background: var(--track); padding: 8px 16px; overflow-x: auto; line-height: 20px; }
pre code { padding: 0; background: none; overflow-wrap: normal; }
a { color: var(--text); text-decoration: underline; text-decoration-color: var(--line); text-decoration-thickness: 2px; text-underline-offset: 4px; }
a:hover { background: var(--track); }
a.term { text-decoration-style: dotted; text-decoration-thickness: 1px; }
/* The glossary: on the page of a group, each entry is a term, its short
   definition set apart by a rule at its left, its explanation, then the
   words that it replaces, dim. The heading of an entry has the size of a
   heading of level 3: the page has no level between the group and its
   terms. */
.term-entry { border-top: 1px solid var(--track); margin-top: 24px; padding-top: 8px; }
.term-entry h2 { margin-top: 0; font-size: 18px; line-height: 24px; }
.glossary-group-place, .glossary-count, .glossary-index-group { color: var(--dim); }
.glossary-count, .glossary-index-group { font-family: var(--mono); font-size: 12px; }
/* The index: the letters as one line of square buttons, then each term
   with its group as a dim label and its short definition under it. */
.glossary-groups { columns: 2 240px; }
.glossary-letters { display: flex; flex-wrap: wrap; gap: 4px; margin: 0 0 16px; }
.glossary-letters a { display: inline-block; min-width: 24px; line-height: 24px; text-align: center; background: var(--track); text-decoration: none; font-family: var(--mono); }
.glossary-index { margin: 0 0 16px; }
.glossary-index > div { padding: 4px 0; border-top: 1px solid var(--track); }
.glossary-index > div:target { background: var(--track); }
.glossary-index dt { font-weight: 700; }
.glossary-index-group { font-weight: 400; margin-left: 8px; }
.glossary-index dd { margin: 0 0 0 16px; }
.term-definition { border-left: 2px solid var(--line); padding-left: 16px; font-weight: 600; }
.term-avoided { color: var(--dim); }
.term-avoided-label { font-weight: 700; margin-right: 8px; }
:focus-visible { outline: 2px solid var(--line); outline-offset: 2px; }
h1 { font-size: 32px; line-height: 40px; margin: 32px 0 16px; font-weight: 700; }
h2 { font-size: 24px; line-height: 32px; margin: 40px 0 16px; font-weight: 700; }
h3 { font-size: 18px; line-height: 24px; margin: 32px 0 8px; font-weight: 700; }
h4 { font-size: 16px; line-height: 24px; margin: 24px 0 8px; font-weight: 700; color: var(--dim); }
p, ul, ol, blockquote { margin: 0 0 16px; }
ul, ol { padding-left: 24px; }
li { margin-bottom: 4px; }
blockquote { margin-left: 0; padding-left: 16px; border-left: 2px solid var(--line); }
.skip { position: absolute; left: -9999px; }
.skip:focus { left: 16px; top: 8px; background: var(--card-top); padding: 4px 8px; }

/* The bar: the heron and the name, then the sections as buttons. */
.bar { background: linear-gradient(var(--card-top), var(--card-bottom)); border-bottom: 1px solid var(--track); }
.bar-inner { max-width: 1152px; margin: 0 auto; padding: 4px 16px; display: flex; flex-wrap: wrap; align-items: center; gap: 8px 24px; }
.bar-home { display: inline-flex; align-items: center; gap: 8px; text-decoration: none; font-family: var(--mono); font-weight: 700; }
.bar-home img { display: block; image-rendering: pixelated; }
.bar-sections ul { list-style: none; margin: 0; padding: 0; display: flex; flex-wrap: wrap; gap: 8px; }
.bar-sections li { margin: 0; }
.bar-sections a { display: inline-block; padding: 0 8px; line-height: 24px; background: var(--track); text-decoration: none; border-bottom: 2px solid transparent; }
.bar-sections a[aria-current="page"] { border-bottom-color: var(--line); }
/* The menu: one list of sections and the search, in a details element. On
   a wide screen it is open and its button is hidden, so it is the bar of
   the sections. A browser that has ::details-content shows the content of
   a closed menu on a wide screen with no script; another one shows the
   button until search.js opens the menu. The button: a square with three
   lines, its word hidden. */
/* The bar stays at the top of the window while the page scrolls, on every
   page. Its height is fixed, so that the parts under it (the column "On
   this page", the target of a link) know where the bar ends. */
:root { --bar-height: 41px; }
.bar { position: sticky; top: 0; z-index: 30; }
.bar-inner { min-height: 40px; }
.bar-menu { flex: 1 1 auto; min-width: 0; }
.bar-menu-content { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 24px; }
.bar-menu-button { list-style: none; display: block; position: relative; width: 32px; height: 32px; margin-left: auto; cursor: pointer; background: var(--track); border: 1px solid var(--track); }
.bar-menu-button::-webkit-details-marker { display: none; }
.bar-menu-name { position: absolute; left: -9999px; }
.bar-menu-lines, .bar-menu-lines::before, .bar-menu-lines::after { position: absolute; left: 7px; width: 16px; height: 2px; background: currentColor; }
.bar-menu-lines { top: 14px; }
.bar-menu-lines::before, .bar-menu-lines::after { content: ""; left: 0; }
.bar-menu-lines::before { top: -6px; }
.bar-menu-lines::after { top: 6px; }
.bar-menu[open] > .bar-menu-button { border-color: var(--line); background: var(--card-top); }
.bar-menu[open] > .bar-menu-button .bar-menu-lines, .bar-menu[open] > .bar-menu-button .bar-menu-lines::before, .bar-menu[open] > .bar-menu-button .bar-menu-lines::after { background: var(--line); }
@media (min-width: 720px) {
  .bar-menu[open] > .bar-menu-button { display: none; }
}
@supports selector(::details-content) {
  @media (min-width: 720px) {
    .bar-menu > .bar-menu-button { display: none; }
    .bar-menu::details-content { content-visibility: visible; }
  }
}
/* The search: a box at the right of the bar, in the place of the clock of
   the desktop, and a list as the completion list of the console: the
   matched characters in the accent, what each row is at its right, dim. */
.search { margin-left: auto; position: relative; }
.search[hidden], .search-panel[hidden] { display: none; }
.search-label { position: absolute; left: -9999px; }
.search input { width: 224px; height: 24px; padding: 0 8px; font-family: var(--mono); font-size: 14px; color: var(--text); background: var(--track); border: 1px solid var(--track); border-radius: 0; }
.search input::placeholder { color: var(--placeholder); opacity: 1; }
.search input:focus-visible { outline: 2px solid var(--line); outline-offset: 0; }
.search-panel { position: absolute; right: 0; top: 32px; z-index: 10; width: 640px; max-width: calc(100vw - 32px); padding: 4px; background: var(--card-bottom); border: 1px solid var(--line); }
.search-hint, .search-detail { margin: 0; padding: 0 4px; font-family: var(--mono); font-size: 12px; line-height: 20px; color: var(--dim); }
.search-detail:empty { display: none; }
.search-list { list-style: none; margin: 0; padding: 0; }
.search-list li { margin: 0; }
.search-list a { display: flex; justify-content: space-between; gap: 16px; padding: 0 4px; line-height: 24px; font-family: var(--mono); font-size: 14px; text-decoration: none; border-left: 2px solid transparent; }
.search-list [aria-selected="true"] a { background: var(--track); border-left-color: var(--line); }
.search-name, .search-what { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.search-name { flex: 0 1 auto; }
.search-what { flex: 0 1 auto; color: var(--dim); }
.search-name mark { background: none; color: var(--match); font-weight: 700; }
/* The home of the docs: a door. Its search field is large, in the middle
   of the page; the bar of that page has no field. Under the field, the
   chart of what the search finds over the whole width of the page; the
   list of results opens under the chart, over the cards, so that the
   field, the chart and the list stay in view while the reader types. Two
   cards under them, the guides and the reference. */
.docs-head { padding: 32px 0 8px; text-align: center; }
.docs-head .lead { margin: 0 auto 16px; }
.docs-search { position: relative; margin-bottom: 24px; }
.docs-search .search.search-door { position: static; max-width: 720px; margin: 0 auto 16px; }
.search-door input { box-sizing: border-box; width: 100%; height: 48px; padding: 0 16px; font-size: 18px; border-color: var(--line); }
.docs-search .search-door .search-panel { position: absolute; top: 100%; left: 0; right: 0; width: auto; max-width: 720px; margin: 4px auto 0; }
/* The two cards of the guides and of the reference: two columns from 900
   pixels, one under it. A card takes the height of its own rows, so no
   card shows an empty part beside a longer one. */
.docs-parts { display: grid; grid-template-columns: minmax(0, 1fr); align-items: start; gap: 8px; margin-bottom: 8px; }
@media (min-width: 900px) {
  .docs-parts { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}
/* The kind of a row of the list: its icon in the color of its kind, its
   words dim, as the rest of the line. */
span.search-kind.value-icon::before { margin-right: 4px; }
/* One row form for the two cards of the docs home: the lead (a number
   of a reading order, or the icon of a kind at the size of the icon of a
   table cell), the name, then a description or a bar, and a count at the
   right. The name and the description share one line when the width
   allows; else the description goes under the name. The count has one
   width, that of five figures (the index holds at most 4096 entries), its
   figures at the right and of one width; it has no rule at its left, so
   that the counts of the rows align. */
.docs-rows { list-style: none; margin: 0; padding: 0; }
.docs-rows li { margin: 0; }
.docs-row { display: grid; grid-template-columns: auto minmax(0, 1fr) auto; align-items: start; gap: 0 8px; padding: 2px 0; line-height: 24px; }
.docs-row-lead.value-icon::before { display: block; width: 12px; height: 12px; margin: 6px 0; }
.docs-row-number { width: 2ch; text-align: right; font-family: var(--mono); font-size: 14px; color: var(--dim); }
.docs-row-main { display: flex; flex-wrap: wrap; align-items: center; gap: 0 12px; min-width: 0; }
.docs-row-name { overflow-wrap: anywhere; }
.docs-rows-one-line .docs-row-name { white-space: nowrap; overflow-wrap: normal; }
/* The description is always under the name: beside it, the rows of a card
   would each break at a different place. */
.docs-row-about { flex: 1 1 100%; min-width: 0; color: var(--dim); font-size: 14px; line-height: 20px; }
.docs-row .docs-row-count { width: 5ch; padding: 0; border-left: 0; text-align: right; font-variant-numeric: tabular-nums; }
/* The chart of what the search finds: one bar of 12 pixels over the whole
   width, a segment for each kind in the color of its kind, square, and the
   total at its right; under it one row of chips that wraps on a narrow
   screen, each chip the icon, the name and the count of a kind. A segment
   is an SVG rect: its place and its width are attributes. A chip keeps one
   width while the reader types: its name does not change and its count has
   the width of four figures. While the field holds a text, a chip is a
   button: the kind that the list keeps has the band and the line of the
   chosen row of the list. */
.search-chart { margin: 0; }
.search-chart-heading { position: absolute; left: -9999px; }
.search-chart-line { display: flex; align-items: center; gap: 12px; margin-bottom: 4px; }
.search-chart-bar { display: block; flex: 1 1 auto; min-width: 8em; height: 12px; background: var(--track); }
.search-chart-segment { fill: var(--value-color); stroke: var(--background); stroke-width: 1px; cursor: pointer; transition: x 150ms ease-out, width 150ms ease-out; }
.search-chart-total { flex: 0 0 auto; margin: 0; color: var(--dim); font-size: 14px; line-height: 24px; white-space: nowrap; }
.search-chart-total .value { padding: 0; border-left: 0; }
.search-chart-rows { list-style: none; margin: 0; padding: 0; display: flex; flex-wrap: wrap; gap: 0 4px; }
.search-chart-rows li { margin: 0; }
.search-chart-target { display: inline-flex; align-items: center; gap: 6px; padding: 0 4px; font-size: 13px; line-height: 24px; color: var(--text); text-decoration: none; white-space: nowrap; border-left: 2px solid transparent; }
.search-chart-icon.value-icon::before { display: block; margin: 0; }
.search-chart-target .search-chart-count { width: 4ch; padding: 0; border-left: 0; text-align: right; font-size: 13px; font-variant-numeric: tabular-nums; }
/* A count keeps the color of a number also in a chip that is a link. */
.search-chart-target .value { color: var(--value-color); }
.search-chart-target[role="button"] { cursor: pointer; }
.search-chart-target[aria-pressed="true"] { background: var(--track); border-left-color: var(--line); }
.search-chart-none .search-chart-target, .search-chart-none .search-chart-target .value { color: var(--dim); }
@media (prefers-reduced-motion: reduce) {
  .search-chart-segment { transition: none; }
}
.crumbs ol { list-style: none; margin: 16px auto 0; padding: 0; display: flex; flex-wrap: wrap; gap: 4px; color: var(--dim); }
.crumbs li { margin: 0; }
.crumbs li + li::before { content: "/"; margin-right: 4px; color: var(--dim); }
.foot { margin-top: 64px; padding: 16px 0 32px; border-top: 1px solid var(--track); color: var(--dim); font-size: 14px; }
.foot a, .foot code { color: var(--dim); }
/* The maker: its mark and its name stay on one line. */
.maker { white-space: nowrap; }
.maker img { display: inline-block; width: 16px; height: 16px; margin: 0 6px 0 2px; vertical-align: -3px; }
.foot .maker a { color: var(--text); font-weight: 700; }
.source, .missing, .date, .status, figcaption, .contents-title { color: var(--dim); }
.source { font-size: 14px; }

/* Prose on a presentation page: one centred column. */
.prose { max-width: 72ch; }

/* The documentation layout (docs/SITE.md, "The two layouts"): the tree at
   the left, the text in the middle, "On this page" at the right.
   Under 720 pixels: one column; the tree is in the open menu, under the
   sections; "On this page" is a closed details above the text.
   From 720 pixels: the tree is a column of 256 pixels at the left of the
   window, fixed, with its own scroll; the text takes the rest.
   From 1100 pixels: "On this page" is a column of 240 pixels at the right,
   sticky, with its own scroll.
   The text keeps a measure of 80 characters for prose; a table, a block of
   code and a figure take the whole middle column. */
.layout-documentation .bar-inner { max-width: none; }
.documentation { display: grid; grid-template-columns: minmax(0, 1fr); gap: 0 32px; padding: 0 16px; }
.documentation > .text { min-width: 0; }
.text .prose { max-width: none; }
.text :is(p, li, dt, dd, blockquote, h1, h2, h3, h4) { max-width: 80ch; }
.text :is(td, th) :is(p, li) { max-width: none; }
.tree { font-size: 14px; line-height: 20px; }
.tree ul { list-style: none; margin: 0; padding: 0; }
.tree li { margin: 0; }
.tree a { display: block; padding: 2px 8px; text-decoration: none; border-left: 2px solid transparent; overflow-wrap: anywhere; }
.tree a[aria-current="page"] { border-left-color: var(--line); background: var(--track); }
.tree-sections > li { margin-bottom: 16px; }
.tree-sections > li > a { font-weight: 700; }
.tree-group { display: block; padding: 2px 8px; border-left: 2px solid transparent; color: var(--dim); overflow-wrap: anywhere; }
.tree-count { font-family: var(--mono); font-size: 12px; line-height: 1; }
.outline { font-size: 14px; line-height: 20px; margin: 16px 0; }
.outline > summary { cursor: pointer; color: var(--dim); }
.outline ul { list-style: none; margin: 0; padding: 0; }
.outline li { margin: 0; }
.outline a { display: block; padding: 2px 8px; text-decoration: none; border-left: 2px solid transparent; overflow-wrap: anywhere; }
.outline a[aria-current="location"] { border-left-color: var(--line); }
.outline .outline-symbol code { background: none; padding: 0; }
/* The tree lines (docs/SITE.md, "The tree lines"): one rule for each list
   of a navigation that is under an item of another list. A row is 24
   pixels high. A level is 16 pixels: the vertical line is 8 pixels from
   the left edge of the row of the parent, and the branch of an item is 8
   pixels long, at the middle of its first line. Each item draws two parts
   with borders of 1 pixel: its corner (the line from its top to its
   branch, and the branch), and the line from its branch to its bottom,
   which the last item does not have. So the vertical line stops at the
   branch of the last item, and an item that wraps keeps its branch on its
   first line. The parts have no text: a screen reader reads the list as
   before. */
ul.tree-lines { margin-left: 8px; }
ul.tree-lines > li { position: relative; padding-left: 8px; }
ul.tree-lines > li::before, ul.tree-lines > li::after { content: ""; position: absolute; left: 0; border: 0 solid var(--tree-line); pointer-events: none; }
ul.tree-lines > li::before { top: 0; width: 8px; height: 13px; border-left-width: 1px; border-bottom-width: 1px; }
ul.tree-lines > li::after { top: 13px; bottom: 0; border-left-width: 1px; }
ul.tree-lines > li:last-child::after { display: none; }
/* The lines from the first list to the current item are in the line color:
   the corner of each item that holds it, and the vertical line beside each
   item before one that holds it. A browser with no :has() draws every line
   in the color of a tree line. */
ul.tree-lines > li:has([aria-current])::before { border-color: var(--line); }
ul.tree-lines > li:has(~ li [aria-current])::before, ul.tree-lines > li:has(~ li [aria-current])::after { border-left-color: var(--line); }
/* The outline of the focus is over the lines beside it, never under them. */
.tree a:focus-visible, .outline a:focus-visible { position: relative; z-index: 1; }
.symbol { margin: 0 0 32px; padding-top: 8px; border-top: 1px solid var(--track); }
.symbol h3 { margin: 0 0 8px; }
.symbol h3 code { background: none; padding: 0; font-size: 18px; }
.symbol .signature { margin: 0 0 8px; }
.symbol-facts { display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: 4px 16px; margin: 0 0 16px; font-size: 14px; }
.symbol-facts dt { color: var(--dim); }
.symbol-facts dd { margin: 0; min-width: 0; }
.source-comment p { max-width: 80ch; }
@media (min-width: 720px) {
  .layout-documentation { padding-left: 256px; }
  .layout-documentation .tree { position: fixed; top: 0; bottom: 0; left: 0; width: 256px; overflow-y: auto; padding: 16px 8px; background: var(--card-bottom); border-right: 1px solid var(--track); }
}
@media (min-width: 1100px) {
  .documentation { grid-template-columns: minmax(0, 1fr) 240px; }
  .documentation > .text { grid-column: 1; grid-row: 1; }
  .documentation > .outline { grid-column: 2; grid-row: 1; position: sticky; top: var(--bar-height); align-self: start; max-height: calc(100vh - var(--bar-height)); overflow-y: auto; margin: 0; padding: 16px 0; }
  .outline[open] > summary { display: none; }
}
/* A browser that has ::details-content shows "On this page" beside the
   text with no script; another one shows its summary until search.js
   opens it. */
@supports selector(::details-content) {
  @media (min-width: 1100px) {
    .outline > summary { display: none; }
    .outline::details-content { content-visibility: visible; }
  }
}
ol.labelled { list-style: none; padding-left: 0; }
ol.labelled > li { padding-left: 48px; text-indent: -48px; }
ol.labelled > li > * { text-indent: 0; }
.label { display: inline-block; min-width: 40px; color: var(--dim); }
.neighbours { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 8px; margin-top: 32px; }

/* Tables: the look of the tables of the system: the titles of the columns in
   the dim color, rows of 24 pixels, every second row on a band.
   The cells wrap; a name (an identifier, a path, a signature) stays on one
   line. A table scrolls sideways only on a narrow screen. */
/* The box of a table scrolls sideways at every width when the table is
   wider than the page; the keyboard reaches it. A table has its natural
   width: each column is as wide as its content, and the table is not
   stretched to the width of the page, so no column holds empty room. A
   column of names, numbers or dates never wraps. When the natural width
   passes the page, the browser wraps the columns of prose first; they
   keep a small least width. */
.table { margin: 0 0 16px; overflow-x: auto; border-left: 2px solid transparent; border-right: 2px solid transparent; }
.table:focus-visible { outline: 2px solid var(--line); outline-offset: 2px; }
table { border-collapse: collapse; }
th.column-prose, th.column-line { min-width: 12em; }
.column-name, .column-name code { white-space: nowrap; overflow-wrap: normal; }
.column-date, .column-number { white-space: nowrap; }
.column-number { text-align: right; font-variant-numeric: tabular-nums; }
td.column-line code { overflow-wrap: break-word; }
/* The first column, the name of the row, stays in view while the table
   scrolls sideways: an opaque background, the color of its row. */
.table tr > :first-child { position: sticky; left: 0; z-index: 1; background: var(--background); }
.table tbody tr:nth-child(odd) > :first-child { background: var(--card-top); }
/* A line at each edge of the box where more of the table is: tied to the
   place of the scroll of the box, not to the time. A box that does not
   scroll has no line. A browser with no scroll timeline shows its scroll
   bar only. */
@supports (animation-timeline: scroll()) {
  .table { animation: table-edges linear both; animation-timeline: scroll(self inline); }
}
@keyframes table-edges {
  0% { border-left-color: transparent; border-right-color: var(--line); }
  1%, 99% { border-left-color: var(--line); border-right-color: var(--line); }
  100% { border-left-color: var(--line); border-right-color: transparent; }
}
th { color: var(--dim); font-weight: 400; text-align: left; padding: 4px 8px; border-bottom: 1px solid var(--track); white-space: nowrap; }
td { padding: 4px 8px; vertical-align: top; overflow-wrap: break-word; }
tbody tr:nth-child(odd) { background: var(--card-top); }
td.name, td.name code { white-space: nowrap; overflow-wrap: normal; }
/* A list of values (docs/SITE.md, "The tables"): several names in one cell
   or one fact. Each name stays whole on its line; the list breaks between
   its names, with no comma and no brace. Its least width is its longest
   name, so a column of lists never pushes the column of prose out. */
.value-list { display: flex; flex-wrap: wrap; gap: 2px 12px; margin: 0; padding: 0; list-style: none; }
.value-list li { margin: 0; white-space: nowrap; overflow-wrap: normal; }
th.column-list { min-width: 8em; }
/* The line that says that the page is from an older build than the site
   serves now: written by the script only, under the bar, quiet. */
.build-notice { margin: 0; padding: 4px 16px; border-bottom: 1px solid var(--line); background: var(--card-top); color: var(--dim); font-size: 14px; line-height: 24px; }
.build-notice button { font: inherit; color: var(--text); background: var(--track); border: 1px solid var(--line); margin-left: 4px; padding: 0 8px; cursor: pointer; }
a.reference { text-decoration-style: dashed; }

/* The kinds of values (docs/SITE.md, "The kinds of values"): a value is in
   the monospace font and in the color of its kind; a code element of a
   value has a thin rule at its left, no filled background. The icon is a
   mask of the file of its kind, in the color of the kind: a column head,
   the label of a fact, or a value whose column does not say its kind. */
.value { font-family: var(--mono); font-size: 14px; color: var(--value-color); }
code.value { background: none; padding: 0 0 0 4px; border-left: 2px solid var(--value-color); }
.value code, .value a, a .value { color: inherit; background: none; }
td.value code { padding: 0; }
.value.missing { color: var(--dim); }
.value-head { color: var(--dim); }
.value-icon::before { content: ""; display: inline-block; width: 12px; height: 12px; margin-right: 4px; vertical-align: -1px; background-color: var(--value-color); -webkit-mask: var(--value-icon) no-repeat center / 12px 12px; mask: var(--value-icon) no-repeat center / 12px 12px; }
span.value-icon::before { margin-right: 0; }
/* A reference to a document (docs/SITE.md, "The references to documents"):
   a name in the reading font, in the color and with the icon of the kind
   Guide. A working record says that it is a file of the repository. The
   line "See:" after a text holds the references of its asides. */
a.document-reference { color: var(--value-color); text-decoration-color: var(--line); }
.document-outside { color: var(--dim); }
.document-references { color: var(--dim); }

/* The types (docs/SITE.md, "The types"): a reference is a button that opens
   the card of its type, a popover in the top layer, so the box of a table
   that scrolls does not cut it. With anchor positioning the card is under
   the reference; else the browser puts it in the middle of the window. */
button.type-reference { font: inherit; color: inherit; background: none; border: 0; margin: 0; padding: 0; cursor: help; text-decoration: underline dotted; text-underline-offset: 3px; }
button.type-reference.value { font-family: var(--mono); font-size: 14px; color: var(--value-color); padding: 0 0 0 4px; border-left: 2px solid var(--value-color); }
button.type-reference:hover { text-decoration-style: solid; }
button.type-reference:focus-visible { outline: 2px solid var(--line); outline-offset: 2px; }
.type-card { width: min(28rem, calc(100vw - 32px)); max-height: min(70vh, 32rem); overflow: auto; margin: auto; padding: 12px 16px; color: var(--text); background: var(--card-top); border: 1px solid var(--line); font-family: var(--reading); font-size: 14px; line-height: 20px; text-align: left; white-space: normal; }
.type-card p { margin: 0 0 8px; max-width: none; }
.type-card-title code { font-size: 16px; }
.type-card-kind, .type-card-more, .type-card-target { color: var(--dim); }
.type-card-rows { list-style: none; margin: 0 0 8px; padding: 0; font-family: var(--mono); font-size: 13px; }
.type-card-rows li { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr) auto auto; gap: 0 12px; padding: 2px 0; border-top: 1px solid var(--track); }
.type-card-rows li:has(> :nth-child(2):last-child) { grid-template-columns: minmax(0, 1fr) auto; }
.type-card-rows li span { color: var(--dim); font-variant-numeric: tabular-nums; text-align: right; }
.type-card-rows li.padding { color: var(--dim); }
.type-card-rows code { background: none; padding: 0; overflow-wrap: anywhere; }
/* A browser with no popover shows the cards as a list at the end of the text. */
@supports not selector(:popover-open) {
  .type-cards { margin-top: 32px; }
  .type-card { margin: 0 0 8px; }
}
tr.padding td { color: var(--dim); }
.type-layout { color: var(--dim); }
@supports (position-area: block-end) {
  .type-card:popover-open, .declaration-card:popover-open { inset: auto; margin: 4px 0 0; position-area: block-end span-inline-end; position-try-fallbacks: flip-block, flip-inline; }
}
/* The declarations of the sources (docs/SITE.md, "The declarations of the
   sources"): a code span that names one is a link that holds a value of
   its kind, with its icon; its card is a popover in the form of a type
   card, which the script opens. A fragment of Odin in a text is colored as
   a block of code, each name of a declaration in it a link. */
a.declaration-reference { text-decoration-style: dotted; text-decoration-thickness: 1px; text-underline-offset: 3px; }
a.declaration-reference:hover { background: none; text-decoration-style: solid; }
/* A value inside a link takes the color of the link elsewhere; a
   declaration keeps the color of its kind. */
a.declaration-reference .value, .declaration-card-title .value { color: var(--value-color); }
code.code-inline { padding: 0 4px; }
a.declaration-link { color: inherit; text-decoration-thickness: 1px; text-underline-offset: 3px; }
.declaration-card { width: min(36rem, calc(100vw - 32px)); max-height: min(70vh, 32rem); overflow: auto; margin: auto; padding: 12px 16px; color: var(--text); background: var(--card-top); border: 1px solid var(--line); font-family: var(--reading); font-size: 14px; line-height: 20px; text-align: left; white-space: normal; }
.declaration-card p { margin: 0 0 8px; max-width: none; }
.declaration-card p:last-child { margin-bottom: 0; }
.declaration-card-kind, .declaration-card-place, .declaration-card-place a { color: var(--dim); }
.declaration-card-signature { margin: 0 0 8px; padding: 4px 8px; white-space: pre-wrap; overflow-wrap: anywhere; }
@supports not selector(:popover-open) {
  .declaration-cards { margin-top: 32px; }
  .declaration-card { margin: 0 0 8px; }
}

/* Cards: a border of 1 pixel in the accent, the bar of 4 by 16 pixels
   before the title. */
.card { min-width: 0; padding: 16px; margin-bottom: 8px; background: linear-gradient(var(--card-top), var(--card-bottom)); border: 1px solid var(--border-top); border-image: linear-gradient(var(--border-top), var(--border-bottom)) 1; }
.card h2, .card h3 { margin: 0 0 16px; font-size: 16px; line-height: 24px; text-transform: uppercase; font-family: var(--mono); }
.card h2::before, .card h3::before { content: ""; display: inline-block; width: 4px; height: 16px; margin-right: 8px; vertical-align: -2px; background: var(--accent); }
.card p:last-child { margin-bottom: 0; }
.pictures { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; margin-bottom: 16px; }

/* The home. */
/* The head takes the height of its picture, the heron alone: the name is
   the title beside it, and the card below starts after the picture. */
.home-head { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 32px; align-items: start; padding: 32px 0; margin-bottom: 16px; }
.home-head picture { display: block; }
.tiles { list-style: none; padding: 0; margin: 0 0 16px; display: flex; flex-wrap: wrap; gap: 2px; }
/* A tile is never narrower than its name: a small module takes the width
   of its name, and the others share the rest of the row by their sizes. */
.tiles li { margin: 0; flex: 1 1 96px; min-width: max-content; height: 24px; line-height: 20px; padding: 0 4px; overflow: hidden; white-space: nowrap; font-family: var(--mono); font-size: 12px; background: var(--track); border-bottom: 1px solid var(--dim); }
.tiles a { display: block; color: inherit; text-decoration: none; }
.tiles a:hover { background: none; text-decoration: underline; }
.mark { display: block; image-rendering: pixelated; }
.lead { font-size: 18px; line-height: 28px; max-width: 60ch; }
.doors { list-style: none; padding: 0; display: flex; flex-wrap: wrap; gap: 8px; }
.doors a { display: inline-block; padding: 4px 16px; background: var(--track); text-decoration: none; border-bottom: 2px solid var(--line); }
figure { min-width: 0; margin: 0; padding: 8px; background: var(--card-bottom); border: 1px solid var(--track); }
figure.wide { grid-column: 1 / -1; }
figure a { display: block; }
figure a:hover { background: none; }
figure img { display: block; width: 100%; height: auto; }
figcaption { padding-top: 8px; font-size: 14px; }

/* The news: a card for each entry; its kind is the colored mark of the card. */
.card.news-entry { margin-bottom: 16px; }
.card.news-entry h2, .card.news-card h3 { text-transform: none; font-family: var(--reading); margin-bottom: 8px; }
.card.news-entry h2 { font-size: 20px; line-height: 28px; }
.news-meta, .news-links { color: var(--dim); font-size: 14px; }
.news-kind { font-family: var(--mono); font-size: 12px; text-transform: uppercase; color: var(--accent-text); border-left: 4px solid var(--accent); padding-left: 4px; }
.news-body.with-picture { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 384px); gap: 16px; align-items: start; }
.news-cards { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px; margin-bottom: 8px; }
.news-card figure { margin-bottom: 8px; padding: 4px; }
/* The film of an entry: under the text, over the width of the card, and
   at most 1024 pixels wide, the width of the screen of the system: one
   pixel of the screen is never wider than one pixel of the page. Its width
   and its height in the page give its ratio, so the page keeps its room.
   On a narrow screen it takes the width of the column. */
.news-film { margin-top: 16px; max-width: 1024px; }
.news-film video { display: block; width: 100%; height: auto; background: var(--track); }
/* The link of the caption is a word of its line, not a block as the link
   around a picture is. */
.news-film figcaption a { display: inline; }
.news-film figcaption a:hover { background: var(--track); }
/* The mark of a film on a card of the home: a rectangle with one word, in
   the lower left corner of the picture, on the surface of a card. */
.film-link { position: relative; text-decoration: none; }
.film-mark { position: absolute; left: 0; bottom: 0; padding: 0 8px; font-family: var(--mono); font-size: 12px; line-height: 24px; text-transform: uppercase; color: var(--text); background: var(--card-bottom); border-top: 1px solid var(--line); border-right: 1px solid var(--line); }
/* The cards of the news on the home: in a row of cards, the title, the
   line of the kind and the date, and the picture of each card start at the
   same height, whatever the length of a title. Each card takes four rows
   of the grid of the cards and shares them (subgrid): the title, the line
   of the kind, the picture, the text. The content of a card starts at its
   top and leaves no empty room between two of its parts: a card with no
   picture has its text in the row of the pictures, right under its line of
   the kind, and that text takes the two last rows. The picture boxes of a
   row have one ratio, that of the screen pictures; a picture of another
   ratio is shown whole inside the box, not cut. */
.news-card { display: grid; grid-row: span 4; grid-template-rows: subgrid; row-gap: 0; }
.news-card > h3 { grid-row: 1; }
.news-card > .news-meta { grid-row: 2; }
.news-card > figure { grid-row: 3; align-self: start; }
.news-card > p:last-child { grid-row: 4; align-self: start; }
.news-card-without-picture > p:last-child { grid-row: 3 / span 2; }
@media (min-width: 720px) {
  .news-card figure img { aspect-ratio: 4 / 3; object-fit: contain; }
}
/* A browser with no subgrid: the cards are blocks, and on a wide screen a
   title keeps the room of two lines, so that the common case aligns. */
@supports not (grid-template-rows: subgrid) {
  .news-card { display: block; }
  @media (min-width: 720px) {
    .news-card > h3 { min-height: 48px; }
  }
}
@media (max-width: 719px) {
  /* A table on a narrow screen: a row is a block. Its first cell is its
     title; each other cell is under it, with the head of its column before
     it. So no table scrolls sideways, and no column is squeezed to a few
     words a line. The head row is kept for a screen reader, not shown. */
  .table { overflow-x: visible; border-left: 0; border-right: 0; animation: none; }
  .table table, .table tbody, .table tr, .table td { display: block; width: auto; min-width: 0; }
  .table thead { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); }
  .table tr { padding: 8px 0; border-bottom: 1px solid var(--track); }
  .table tbody tr:nth-child(odd) { background: none; }
  .table tr > :first-child, .table tbody tr:nth-child(odd) > :first-child { position: static; background: none; font-weight: 600; }
  .table td { padding: 2px 0; white-space: normal; overflow-wrap: anywhere; text-align: left; }
  .table td:empty { display: none; }
  .table td[data-label]::before { content: attr(data-label); display: block; color: var(--dim); font-size: 12px; line-height: 16px; font-weight: 400; font-family: var(--reading); }
  /* The bar: the mark at the left, the button at the right; the open menu
     lies over the page under the bar, the sections one under the other,
     then the search over the whole width. */
  .bar-inner { flex-wrap: nowrap; justify-content: space-between; }
  .bar-menu { flex: 0 0 auto; }
  .bar-menu-content { position: absolute; left: 0; right: 0; top: 100%; z-index: 20; flex-direction: column; align-items: stretch; gap: 8px; padding: 8px 16px 16px; background: var(--card-bottom); border-bottom: 1px solid var(--line); }
  .bar-sections ul { flex-direction: column; gap: 4px; }
  .bar-sections a { display: block; padding: 4px 8px; line-height: 24px; border-bottom: 0; border-left: 2px solid transparent; }
  .bar-sections a[aria-current="page"] { border-left-color: var(--line); }
  .search { margin-left: 0; }
  .search input { width: 100%; height: 32px; }
  .search-panel { position: static; width: auto; max-width: none; margin-top: 4px; }
  /* The field of the home of the docs stays in the page, not in the menu;
     its list still opens under the chart. */
  .search-door input { height: 40px; }
  .docs-search .search-door .search-panel { position: absolute; }
  /* The open menu scrolls on its own: on a documentation page it holds
     the tree under the sections and the search. */
  .bar-menu-content { max-height: calc(100vh - 48px); overflow-y: auto; }
  .tree { padding-top: 8px; border-top: 1px solid var(--track); }
  /* No line wider than the screen: a long word, an address or a path
     breaks; a table and a block of code scroll in their own box. */
  h1, h2, h3, p, li, figcaption, .crumbs { overflow-wrap: anywhere; }
  .news-body.with-picture, .news-cards { grid-template-columns: minmax(0, 1fr); }

  .home-head { grid-template-columns: minmax(0, 1fr); }
  .pictures { grid-template-columns: minmax(0, 1fr); }
  figure.wide { grid-column: auto; }
  h1 { font-size: 28px; line-height: 32px; }
}
@media print {
  /* Print shows the middle column only. */
  .bar, .crumbs, .tree, .outline, .neighbours, .skip, .build-notice { display: none; }
  .layout-documentation { padding-left: 0; }
  .documentation { display: block; padding: 0; }
  html, body { background: #fff; color: #000; }
  a { color: #000; }
  .prose { max-width: none; }
  pre, code { background: none; }
}
`

// The polish of the parts of the browser (docs/SITE.md, "The polish of the
// browser's parts"): the gutter of the scroll bar, the selection, the
// focus, the marks of the lists, the jump to an anchor, the forced colors;
// the scroll bars themselves are SITE_SCROLL_RULES. In the design of
// the system: square, the colors of the palette, both forms. The variables
// --selection, --selection-text and --placeholder are written for each
// form by site_polish_variables.
SITE_POLISH_RULES :: `
:root {
  color-scheme: dark light;
  accent-color: var(--line);
  -webkit-tap-highlight-color: color-mix(in srgb, var(--line) 30%, transparent);
}
/* A page with and without a scroll bar has the same width. */
html { scrollbar-gutter: stable; }
/* The scroll of the tree and of "On this page" stops at their end: it does
   not move the page. */
.tree, .outline, .bar-menu-content { overscroll-behavior: contain; }
::selection { background: var(--selection); color: var(--selection-text); }
.search input { caret-color: var(--line); }
/* The focus: a square outline of 2 pixels in the line color, on each part
   that the keyboard reaches. No rule removes an outline. */
a:focus-visible, button:focus-visible, summary:focus-visible, input:focus-visible, [tabindex]:focus-visible { outline: 2px solid var(--line); outline-offset: 2px; }
.search input:focus-visible { outline-offset: 0; }
button, summary, a { touch-action: manipulation; }
/* The marks of the lists: a square in the dim color; a number in the dim color. */
ul { list-style-type: square; }
li::marker, summary::marker { color: var(--dim); }
h1, h2, h3, h4 { text-wrap: balance; }
p, li, dd, blockquote { text-wrap: pretty; }
pre, code { tab-size: 4; }
/* A jump to an anchor: the bar of the site stays at the top, so the target
   keeps the height of the bar and a little room above it, and a line at
   its left marks where the link landed. */
/* The room is a margin of each target, not a padding of the scroll of the
   page: with a padding, the browser takes the search field of the bar as
   hidden under it and scrolls the page at each key. */
[id] { scroll-margin-top: calc(var(--bar-height) + 16px); }
h2:target, h3:target, li:target, p:target { box-sizing: border-box; border-left: 2px solid var(--line); padding-left: 8px; }
.table tr:target > td { background: var(--track); }
/* A card of a type or of a declaration is not a modal: no veil over the page. */
.type-card::backdrop, .declaration-card::backdrop { background: transparent; }
@media (forced-colors: active) {
  /* The system colors: the icons, the marks of the values and the focus stay. */
  .value-icon::before { forced-color-adjust: none; background-color: CanvasText; }
  .search-chart-bar rect { fill: CanvasText; }
  code.value, button.type-reference.value { border-left-color: CanvasText; }
  a:focus-visible, button:focus-visible, summary:focus-visible, input:focus-visible, [tabindex]:focus-visible { outline-color: Highlight; }
  .type-card, .declaration-card { border-color: CanvasText; }
}
@media print {
  /* Plain black text: no color of code or of a value, no card of a type
     or of a declaration. */
  .type-cards, .declaration-cards { display: none; }
  pre, code, .value, pre .type-reference, button.type-reference.value, [class^="c-"] { color: #000; }
  pre { white-space: pre-wrap; }
}
`

// The scroll bars (docs/SITE.md, "The scroll bars"): the scroll bar of the
// system, from the same table (support/graphics/scroll_bar.odin). An arrow
// button with a triangle at each end; a track with a gradient across it
// and a border; a thumb with a border, a gradient across it, an inner line
// and a grip of four lines. With the pointer over it, the thumb and an
// arrow button take the blue tones of the table; held, the pressed ones.
// Everything is rectangular. These rules hold no size and no color: each
// one is a variable that site_scroll_variables writes from the table, for
// each form.
//
// The parts ::-webkit-scrollbar are for Chromium and WebKit; Chromium
// ignores them on an element that has scrollbar-color or scrollbar-width,
// so those two are written only for an engine with no such parts
// (Firefox), which shows two flat colors: the border of the thumb on the
// middle of the track. A data address cannot read a variable of the style
// sheet: the tool writes each triangle and each grip in the colors of each
// form.
SITE_SCROLL_RULES :: `
@supports selector(::-webkit-scrollbar) {
  ::-webkit-scrollbar { width: var(--scroll-thickness); height: var(--scroll-thickness); background: var(--scroll-track-middle); }
  ::-webkit-scrollbar-track { border: var(--scroll-border) solid var(--scroll-track-border); }
  ::-webkit-scrollbar-track:vertical { background: var(--scroll-track-vertical); border-top: 0; border-bottom: 0; }
  ::-webkit-scrollbar-track:horizontal { background: var(--scroll-track-horizontal); border-left: 0; border-right: 0; }
  ::-webkit-scrollbar-thumb { border: var(--scroll-border) solid var(--scroll-thumb-border); border-radius: 0; background-clip: padding-box; background-repeat: no-repeat; background-position: center; box-shadow: inset 0 0 0 var(--scroll-border) var(--scroll-thumb-line); }
  ::-webkit-scrollbar-thumb:vertical { min-height: var(--scroll-thumb-least); background-image: var(--scroll-grip-vertical), var(--scroll-thumb-vertical); }
  ::-webkit-scrollbar-thumb:horizontal { min-width: var(--scroll-thumb-least); background-image: var(--scroll-grip-horizontal), var(--scroll-thumb-horizontal); }
  ::-webkit-scrollbar-thumb:hover { border-color: var(--scroll-hot-border); }
  ::-webkit-scrollbar-thumb:vertical:hover { background-image: var(--scroll-grip-vertical-lit), var(--scroll-thumb-hot-vertical); }
  ::-webkit-scrollbar-thumb:horizontal:hover { background-image: var(--scroll-grip-horizontal-lit), var(--scroll-thumb-hot-horizontal); }
  ::-webkit-scrollbar-thumb:vertical:active { background-image: var(--scroll-grip-vertical-lit), var(--scroll-thumb-pressed-vertical); }
  ::-webkit-scrollbar-thumb:horizontal:active { background-image: var(--scroll-grip-horizontal-lit), var(--scroll-thumb-pressed-horizontal); }
  ::-webkit-scrollbar-button:single-button { display: block; width: var(--scroll-thickness); height: var(--scroll-thickness); border: var(--scroll-border) solid var(--scroll-track-border); border-radius: 0; background-repeat: no-repeat; background-position: center; }
  ::-webkit-scrollbar-button:single-button:vertical:decrement { background-image: var(--scroll-arrow-up), var(--scroll-track-vertical); }
  ::-webkit-scrollbar-button:single-button:vertical:increment { background-image: var(--scroll-arrow-down), var(--scroll-track-vertical); }
  ::-webkit-scrollbar-button:single-button:horizontal:decrement { background-image: var(--scroll-arrow-left), var(--scroll-track-horizontal); }
  ::-webkit-scrollbar-button:single-button:horizontal:increment { background-image: var(--scroll-arrow-right), var(--scroll-track-horizontal); }
  ::-webkit-scrollbar-button:single-button:hover { border-color: var(--scroll-hot-border); }
  ::-webkit-scrollbar-button:single-button:vertical:decrement:hover { background-image: var(--scroll-arrow-up-hot), var(--scroll-arrow-hot-vertical); }
  ::-webkit-scrollbar-button:single-button:vertical:increment:hover { background-image: var(--scroll-arrow-down-hot), var(--scroll-arrow-hot-vertical); }
  ::-webkit-scrollbar-button:single-button:horizontal:decrement:hover { background-image: var(--scroll-arrow-left-hot), var(--scroll-arrow-hot-horizontal); }
  ::-webkit-scrollbar-button:single-button:horizontal:increment:hover { background-image: var(--scroll-arrow-right-hot), var(--scroll-arrow-hot-horizontal); }
  ::-webkit-scrollbar-button:single-button:vertical:decrement:active { background-image: var(--scroll-arrow-up-hot), var(--scroll-arrow-pressed-vertical); }
  ::-webkit-scrollbar-button:single-button:vertical:increment:active { background-image: var(--scroll-arrow-down-hot), var(--scroll-arrow-pressed-vertical); }
  ::-webkit-scrollbar-button:single-button:horizontal:decrement:active { background-image: var(--scroll-arrow-left-hot), var(--scroll-arrow-pressed-horizontal); }
  ::-webkit-scrollbar-button:single-button:horizontal:increment:active { background-image: var(--scroll-arrow-right-hot), var(--scroll-arrow-pressed-horizontal); }
  ::-webkit-scrollbar-corner { background: var(--scroll-track-middle); }
}
@supports not selector(::-webkit-scrollbar) {
  html, .tree, .outline, .table, pre, .bar-menu-content, .search-panel, .type-card, .declaration-card, .carousel-track { scrollbar-color: var(--scroll-thumb-border) var(--scroll-track-middle); scrollbar-width: auto; }
}
`

// site_scroll_colors gives the colors of the scroll bars of one form: the
// table of the scroll bar of the system (support/graphics/scroll_bar.odin).
site_scroll_colors :: proc(light: bool) -> graphics.Scroll_Bar_Colors {
	return light ? graphics.scroll_bar_colors_light : graphics.scroll_bar_colors_dark
}

// The least length of a thumb of the site: a style sheet cannot remove the
// grip of a short thumb, so each thumb is long enough for its grip.
SITE_SCROLL_THUMB_LEAST :: graphics.SCROLL_BAR_GRIP_THUMB_LEAST + 1

// site_scroll_gradient writes one variable whose value is a gradient
// across a scroll bar, with a stop at each percent: "to right" for a
// vertical bar, "to bottom" for a horizontal one.
site_scroll_gradient :: proc(builder: ^strings.Builder, name: string, vertical: bool, colors: []graphics.Color, percents: []int) {
	strings.write_string(builder, "  --")
	strings.write_string(builder, name)
	strings.write_string(builder, vertical ? "-vertical: linear-gradient(to right" : "-horizontal: linear-gradient(to bottom")
	for color, index in colors {
		strings.write_string(builder, ", ")
		strings.write_string(builder, site_color(color))
		strings.write_string(builder, " ")
		strings.write_int(builder, percents[index])
		strings.write_string(builder, "%")
	}
	strings.write_string(builder, ");\n")
}

// site_scroll_size writes one variable whose value is a count of pixels.
site_scroll_size :: proc(builder: ^strings.Builder, name: string, size_in_pixels: int) {
	strings.write_string(builder, "  --")
	strings.write_string(builder, name)
	strings.write_string(builder, ": ")
	strings.write_int(builder, size_in_pixels)
	strings.write_string(builder, "px;\n")
}

// The four directions of the triangle of a button of a scroll bar.
Site_Scroll_Direction :: enum {
	Up,
	Down,
	Left,
	Right,
}

site_scroll_direction_names := [Site_Scroll_Direction]string {
	.Up    = "up",
	.Down  = "down",
	.Left  = "left",
	.Right = "right",
}

// site_scroll_arrow_svg gives the triangle of an arrow button, as the
// system draws it: a square of the thickness of the bar, and in its middle
// a solid triangle of four rows of 1, 3, 5 and 7 pixels, its point on the
// middle line. One rect for each row, as the icons of the values are drawn.
site_scroll_arrow_svg :: proc(direction: Site_Scroll_Direction, color: graphics.Color) -> string {
	SIDE :: graphics.SCROLL_BAR_THICKNESS
	ROWS :: graphics.SCROLL_BAR_TRIANGLE_ROWS
	first := (SIDE - ROWS) / 2
	middle := SIDE / 2
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" shape-rendering=\"crispEdges\" fill=\"%s\">", SIDE, SIDE, SIDE, SIDE, site_color(color))
	for row in 0 ..< ROWS {
		// The point is toward the end that the button scrolls to.
		half := direction == .Up || direction == .Left ? row : ROWS - 1 - row
		switch direction {
		case .Up, .Down:
			fmt.sbprintf(&b, "<rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"1\"/>", middle - half, first + row, 2 * half + 1)
		case .Left, .Right:
			fmt.sbprintf(&b, "<rect x=\"%d\" y=\"%d\" width=\"1\" height=\"%d\"/>", first + row, middle - half, 2 * half + 1)
		}
	}
	strings.write_string(&b, "</svg>")
	return strings.to_string(b)
}

// site_scroll_grip_svg gives the grip of a thumb, as the system draws it:
// four lines of 7 pixels, each 1 pixel thick with 1 pixel between two,
// across the thumb (horizontal lines on a vertical thumb).
site_scroll_grip_svg :: proc(vertical: bool, color: graphics.Color) -> string {
	ACROSS :: graphics.SCROLL_BAR_GRIP_LINE_LENGTH
	ALONG :: graphics.SCROLL_BAR_GRIP_LENGTH
	b := strings.builder_make(context.temp_allocator)
	if vertical {
		fmt.sbprintf(&b, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" shape-rendering=\"crispEdges\" fill=\"%s\">", ACROSS, ALONG, ACROSS, ALONG, site_color(color))
		for line in 0 ..< graphics.SCROLL_BAR_GRIP_LINES {
			fmt.sbprintf(&b, "<rect x=\"0\" y=\"%d\" width=\"%d\" height=\"1\"/>", line * graphics.SCROLL_BAR_GRIP_LINE_STEP, ACROSS)
		}
	} else {
		fmt.sbprintf(&b, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" shape-rendering=\"crispEdges\" fill=\"%s\">", ALONG, ACROSS, ALONG, ACROSS, site_color(color))
		for line in 0 ..< graphics.SCROLL_BAR_GRIP_LINES {
			fmt.sbprintf(&b, "<rect x=\"%d\" y=\"0\" width=\"1\" height=\"%d\"/>", line * graphics.SCROLL_BAR_GRIP_LINE_STEP, ACROSS)
		}
	}
	strings.write_string(&b, "</svg>")
	return strings.to_string(b)
}

// site_scroll_variables writes the variables of the scroll bars of one
// form, each from the table of the scroll bar of the system: the sizes,
// the flat colors, the inner line of the thumb, each gradient in both
// directions, then each triangle and each grip as a data address, at rest
// and with the pointer over it.
site_scroll_variables :: proc(builder: ^strings.Builder, light: bool) {
	colors := site_scroll_colors(light)
	strings.write_string(builder, ":root {\n")
	site_scroll_size(builder, "scroll-thickness", graphics.SCROLL_BAR_THICKNESS)
	site_scroll_size(builder, "scroll-border", graphics.SCROLL_BAR_BORDER)
	site_scroll_size(builder, "scroll-thumb-least", SITE_SCROLL_THUMB_LEAST)
	site_variable(builder, "scroll-track-middle", colors.track[1])
	site_variable(builder, "scroll-track-border", colors.track_border)
	site_variable(builder, "scroll-thumb-border", colors.thumb_border)
	site_variable(builder, "scroll-hot-border", colors.hot_border)
	// The inner line of the thumb: white over the fill, at the level of
	// the table. A browser blends it; the system draws the blended color.
	strings.write_string(builder, "  --scroll-thumb-line: rgb(255 255 255 / ")
	strings.write_int(builder, int(colors.thumb_line_level * 100 / 255))
	strings.write_string(builder, "%);\n")
	track_percents := graphics.SCROLL_BAR_TRACK_STOP_PERCENTS
	thumb_percents := graphics.SCROLL_BAR_THUMB_STOP_PERCENTS
	arrow_percents := [2]int{0, 100}
	for vertical in ([2]bool{true, false}) {
		site_scroll_gradient(builder, "scroll-track", vertical, colors.track[:], track_percents[:])
		site_scroll_gradient(builder, "scroll-thumb", vertical, colors.thumb_rest[:], thumb_percents[:])
		site_scroll_gradient(builder, "scroll-thumb-hot", vertical, colors.thumb_hot[:], thumb_percents[:])
		site_scroll_gradient(builder, "scroll-thumb-pressed", vertical, colors.thumb_pressed[:], thumb_percents[:])
		site_scroll_gradient(builder, "scroll-arrow-hot", vertical, colors.arrow_hot[:], arrow_percents[:])
		site_scroll_gradient(builder, "scroll-arrow-pressed", vertical, colors.arrow_pressed[:], arrow_percents[:])
	}
	address :: proc(target: ^strings.Builder, variable_name, svg: string) {
		fmt.sbprintf(target, "  --%s: url(\"%s\");\n", variable_name, site_svg_data_address(svg))
	}
	for direction in Site_Scroll_Direction {
		name := site_scroll_direction_names[direction]
		address(builder, strings.concatenate({"scroll-arrow-", name}, context.temp_allocator), site_scroll_arrow_svg(direction, colors.triangle))
		address(builder, strings.concatenate({"scroll-arrow-", name, "-hot"}, context.temp_allocator), site_scroll_arrow_svg(direction, colors.triangle_hot))
	}
	address(builder, "scroll-grip-vertical", site_scroll_grip_svg(true, colors.grip))
	address(builder, "scroll-grip-vertical-lit", site_scroll_grip_svg(true, colors.grip_lit))
	address(builder, "scroll-grip-horizontal", site_scroll_grip_svg(false, colors.grip))
	address(builder, "scroll-grip-horizontal-lit", site_scroll_grip_svg(false, colors.grip_lit))
	strings.write_string(builder, "}\n")
}

// The colors of the parts of the browser in one form: the selection (the
// line color, darker, under white text: the same in both forms), and the
// placeholder of the search field, on the track color.
site_polish_colors :: proc(light: bool) -> (selection, selection_text, placeholder: graphics.Color) {
	selection = graphics.shade(graphics.COLOR_TITLE, 70)
	selection_text = graphics.COLOR_WHITE
	placeholder = light ? site_light_colors().dim : graphics.shade(graphics.COLOR_DIM, 115)
	return
}

// site_polish_variables writes the variables of the polish of one form.
site_polish_variables :: proc(builder: ^strings.Builder, light: bool) {
	selection, selection_text, placeholder := site_polish_colors(light)
	strings.write_string(builder, ":root {\n")
	site_variable(builder, "selection", selection)
	site_variable(builder, "selection-text", selection_text)
	site_variable(builder, "placeholder", placeholder)
	strings.write_string(builder, "}\n")
}

// site_style_sheet_icon_count gives the count of the icons of the kinds of
// values that a style sheet holds as data addresses.
site_style_sheet_icon_count :: proc(sheet: string) -> int {
	return strings.count(sheet, "--value-icon: url(\"data:image/svg+xml,")
}

// site_style_sheet gives the whole style sheet: the variables of the dark
// form, the rules, the grid of points of the background, then the light form
// for a reader whose system asks for it.
site_style_sheet :: proc(tile_rules: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	site_colors_write(&builder, site_dark_colors())
	strings.write_string(&builder, SITE_STYLE_RULES)
	// The font and the class of the name of the mark: after the rules, so
	// that the class wins over the font of the place that holds the name.
	strings.write_string(&builder, site_mark_name_rules())
	// The stage of the heron of the home, which its script puts in the
	// place of the still picture.
	strings.write_string(&builder, site_mark_animation_rules())
	// The color and the icon of each kind of value, in the dark form.
	strings.write_string(&builder, site_value_rules(false))
	// The colors of the code and of the parts of the browser, in the dark
	// form; the polish comes after the colors, so that print and the forced
	// colors win over them.
	strings.write_string(&builder, site_code_rules(false))
	site_polish_variables(&builder, false)
	strings.write_string(&builder, SITE_POLISH_RULES)
	// The scroll bars, in the colors of the dark form.
	site_scroll_variables(&builder, false)
	strings.write_string(&builder, SITE_SCROLL_RULES)
	// The colors of the kinds of the module graph, then its rules.
	site_module_graph_variables(&builder, false)
	strings.write_string(&builder, SITE_MODULE_GRAPH_RULES)
	// The columns and the cards of the page of the roadmap.
	strings.write_string(&builder, SITE_ROADMAP_RULES)
	// The menu of the bar that holds the sections that are not buttons.
	strings.write_string(&builder, site_project_menu_rules())
	// The sections of the home: the line of time of the start, the charts
	// of the measures, the band of the newest release.
	strings.write_string(&builder, site_home_rules())
	// The colors of the states of a control, in the dark form.
	site_control_variables(&builder, false)
	// The colors and the widths of the tiles of the boot image: they come
	// from the image of the build, so they are not fixed rules.
	strings.write_string(&builder, tile_rules)
	// The grid of points of the background (docs/DESIGN.md, section 3): a
	// square of 2 pixels each 24 pixels, at 12 + 24 n. A picture in the style
	// sheet itself, so that the page asks for no other file.
	point := fmt.tprintf("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\"><rect width=\"2\" height=\"2\" fill=\"%s\"/></svg>", site_color(graphics.COLOR_POINT))
	strings.write_string(&builder, ".section-home {\n  background-image: url(\"")
	strings.write_string(&builder, site_svg_data_address(point))
	strings.write_string(&builder, "\");\n  background-position: 12px 12px;\n}\n")
	strings.write_string(&builder, "@media (prefers-color-scheme: light) {\n")
	site_colors_write(&builder, site_light_colors())
	strings.write_string(&builder, site_value_rules(true))
	strings.write_string(&builder, site_code_rules(true))
	site_polish_variables(&builder, true)
	site_scroll_variables(&builder, true)
	site_module_graph_variables(&builder, true)
	site_control_variables(&builder, true)
	// The grid of points is a decoration of the dark background only.
	strings.write_string(&builder, ".section-home { background-image: none; }\n}\n")
	// Print is plain black text, also in the light form, whose colors of code
	// come after the polish.
	strings.write_string(&builder, "@media print {\n  pre, code, .value, pre .type-reference, button.type-reference.value, [class^=\"c-\"] { color: #000; }\n}\n")
	// The gallery and the carousel of the home: rules with no color of
	// their own, so they are the same in both forms. They come last: the
	// room above a picture of the carousel that a link shows is larger than
	// the room of another target of a link.
	strings.write_string(&builder, site_gallery_rules())
	// The states of a control (the pointer over it, the focus, a press):
	// after the rules of every control, so that a state wins over the look
	// at rest and over the current mark of a control of the same weight.
	strings.write_string(&builder, site_control_rules())
	return strings.to_string(builder)
}
