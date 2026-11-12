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
code, pre, kbd, .code, .time, .line, .label, .who { font-family: var(--mono); font-size: 14px; }
code { color: var(--text); background: var(--track); padding: 0 4px; overflow-wrap: anywhere; }
pre { background: var(--track); padding: 8px 16px; overflow-x: auto; line-height: 20px; }
pre code { padding: 0; background: none; overflow-wrap: normal; }
a { color: var(--text); text-decoration: underline; text-decoration-color: var(--line); text-decoration-thickness: 2px; text-underline-offset: 4px; }
a:hover { background: var(--track); }
a.term { text-decoration-style: dotted; text-decoration-thickness: 1px; }
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
.bar { position: relative; }
.bar-menu { flex: 1 1 auto; min-width: 0; }
.bar-menu-content { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 24px; }
.bar-menu-button { list-style: none; display: block; position: relative; width: 32px; height: 32px; margin-left: auto; cursor: pointer; background: var(--track); border: 1px solid var(--track); }
.bar-menu-button::-webkit-details-marker { display: none; }
.bar-menu-name { position: absolute; left: -9999px; }
.bar-menu-lines, .bar-menu-lines::before, .bar-menu-lines::after { position: absolute; left: 7px; width: 16px; height: 2px; background: var(--text); }
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
.crumbs ol { list-style: none; margin: 16px auto 0; padding: 0; display: flex; flex-wrap: wrap; gap: 4px; color: var(--dim); }
.crumbs li { margin: 0; }
.crumbs li + li::before { content: "/"; margin-right: 4px; color: var(--dim); }
.foot { margin-top: 64px; padding: 16px 0 32px; border-top: 1px solid var(--track); color: var(--dim); font-size: 14px; }
.foot a, .foot code { color: var(--dim); }
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
.tree-sections ul ul a, .tree-groups ul a { padding-left: 24px; }
.tree-group { display: block; padding: 6px 8px 2px; color: var(--dim); }
.tree-count { font-family: var(--mono); font-size: 12px; }
.outline { font-size: 14px; line-height: 20px; margin: 16px 0; }
.outline > summary { cursor: pointer; color: var(--dim); }
.outline ul { list-style: none; margin: 0; padding: 0; }
.outline li { margin: 0; }
.outline a { display: block; padding: 2px 8px; text-decoration: none; border-left: 2px solid var(--track); overflow-wrap: anywhere; }
.outline a[aria-current="location"] { border-left-color: var(--line); }
.outline .outline-level-3, .outline .outline-symbol { padding-left: 16px; }
.outline .outline-symbol code { background: none; padding: 0; }
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
  .documentation > .outline { grid-column: 2; grid-row: 1; position: sticky; top: 0; align-self: start; max-height: 100vh; overflow-y: auto; margin: 0; padding: 16px 0; }
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
   wider than the page; the keyboard reaches it. A column of names, numbers
   or dates takes only the width of its content (a width of 1% asks for the
   least), so the spare room of a wide table goes to the columns of prose
   and of log lines, which have a least width and no upper bound. */
.table { margin: 0 0 16px; overflow-x: auto; border-left: 2px solid transparent; border-right: 2px solid transparent; }
.table:focus-visible { outline: 2px solid var(--line); outline-offset: 2px; }
table { border-collapse: collapse; min-width: 100%; }
th.column-name, th.column-number, th.column-date { width: 1%; }
th.column-short { width: 1%; min-width: 6em; }
th.column-prose { min-width: 13em; }
th.column-line { min-width: 30em; }
th.column-any { min-width: 6em; }
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
  .type-card:popover-open { inset: auto; margin: 4px 0 0; position-area: block-end span-inline-end; position-try-fallbacks: flip-block, flip-inline; }
}

/* Cards: a border of 1 pixel in the accent, the bar of 4 by 16 pixels
   before the title. */
.card { min-width: 0; padding: 16px; margin-bottom: 8px; background: linear-gradient(var(--card-top), var(--card-bottom)); border: 1px solid var(--border-top); border-image: linear-gradient(var(--border-top), var(--border-bottom)) 1; }
.card h2, .card h3 { margin: 0 0 16px; font-size: 16px; line-height: 24px; text-transform: uppercase; font-family: var(--mono); }
.card h2::before, .card h3::before { content: ""; display: inline-block; width: 4px; height: 16px; margin-right: 8px; vertical-align: -2px; background: var(--accent); }
.card.measure h3 { text-transform: none; font-family: var(--reading); }
.card p:last-child { margin-bottom: 0; }
.measures, .pictures { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; margin-bottom: 16px; }
.line code { display: block; padding: 8px; white-space: pre-wrap; }

/* The home. */
/* The head takes the height of its picture: the name under the heron is in
   the picture, and the card below starts after it. */
.home-head { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 32px; align-items: start; padding: 32px 0; margin-bottom: 16px; }
.home-head picture { display: block; }
.tiles { list-style: none; padding: 0; margin: 0 0 16px; display: flex; flex-wrap: wrap; gap: 2px; }
.tiles li { margin: 0; flex: 1 1 96px; min-width: 48px; height: 24px; line-height: 20px; padding: 0 4px; overflow: hidden; white-space: nowrap; font-family: var(--mono); font-size: 12px; background: var(--track); border-bottom: 1px solid var(--dim); }
.tiles a { display: block; color: inherit; text-decoration: none; }
.tiles a:hover { background: none; text-decoration: underline; }
.mark { display: block; image-rendering: pixelated; }
.lead { font-size: 18px; line-height: 28px; max-width: 60ch; }
.doors { list-style: none; padding: 0; display: flex; flex-wrap: wrap; gap: 8px; }
.doors a { display: inline-block; padding: 4px 16px; background: var(--track); text-decoration: none; border-bottom: 2px solid var(--line); }
.stages { list-style: none; padding: 0; margin: 0; display: grid; grid-template-columns: repeat(auto-fill, minmax(176px, 1fr)); gap: 8px; }
.stages li { margin: 0; padding: 4px 8px; background: var(--track); border-top: 2px solid var(--accent); }
.stages .who { display: block; color: var(--dim); }
.stages .time { display: block; }
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
/* The cards of the news on the home: in a row of cards, the title, the
   line of the kind and the date, the picture and the text of each card
   start at the same height, whatever the length of a title. Each card
   takes four rows of the grid of the cards and shares them (subgrid); each
   part has its row, so a card with no picture keeps its text in line. The
   picture boxes of a row have one ratio, that of the screen pictures; a
   picture of another ratio is shown whole inside the box, not cut. */
.news-card { display: grid; grid-row: span 4; grid-template-rows: subgrid; row-gap: 0; }
.news-card > h3 { grid-row: 1; }
.news-card > .news-meta { grid-row: 2; }
.news-card > figure { grid-row: 3; align-self: start; }
.news-card > p:last-child { grid-row: 4; }
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
  /* The open menu scrolls on its own: on a documentation page it holds
     the tree under the sections and the search. */
  .bar-menu-content { max-height: calc(100vh - 48px); overflow-y: auto; }
  .tree { padding-top: 8px; border-top: 1px solid var(--track); }
  /* No line wider than the screen: a long word, an address or a path
     breaks; a table and a block of code scroll in their own box. */
  h1, h2, h3, p, li, figcaption, .crumbs { overflow-wrap: anywhere; }
  .news-body.with-picture, .news-cards { grid-template-columns: minmax(0, 1fr); }

  .home-head { grid-template-columns: minmax(0, 1fr); }
  .measures, .pictures { grid-template-columns: minmax(0, 1fr); }
  figure.wide { grid-column: auto; }
  h1 { font-size: 28px; line-height: 32px; }
}
@media print {
  /* Print shows the middle column only. */
  .bar, .crumbs, .tree, .outline, .neighbours, .skip { display: none; }
  .layout-documentation { padding-left: 0; }
  .documentation { display: block; padding: 0; }
  html, body { background: #fff; color: #000; }
  a { color: #000; }
  .prose { max-width: none; }
  pre, code { background: none; }
}
`

// The polish of the parts of the browser (docs/SITE.md, "The polish of the
// browser's parts"): the scroll bars, the selection, the focus, the marks
// of the lists, the jump to an anchor, the forced colors. In the design of
// the system: square, the colors of the palette, both forms. The variables
// --selection, --selection-text and --placeholder are written for each
// form by site_polish_variables.
SITE_POLISH_RULES :: `
:root {
  color-scheme: dark light;
  accent-color: var(--line);
  scroll-padding-top: 16px;
  -webkit-tap-highlight-color: color-mix(in srgb, var(--line) 30%, transparent);
}
/* A page with and without a scroll bar has the same width. */
html { scrollbar-gutter: stable; }
/* The scroll bars: thin, a thumb in the dim color on the track color. The
   standard properties first; the parts of WebKit only for a browser with no
   standard one, because a browser that has both ignores the standard one
   when the parts are styled. */
html, .tree, .outline, .table, pre, .bar-menu-content, .search-panel, .type-card { scrollbar-color: var(--dim) var(--track); scrollbar-width: thin; }
@supports not (scrollbar-color: auto) {
  ::-webkit-scrollbar { width: 8px; height: 8px; background: var(--track); }
  ::-webkit-scrollbar-thumb { background: var(--dim); border: 0; }
  ::-webkit-scrollbar-thumb:hover { background: var(--line); }
  ::-webkit-scrollbar-corner { background: var(--track); }
}
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
@media (prefers-reduced-motion: no-preference) {
  html { scroll-behavior: smooth; }
}
/* A jump to an anchor: the bar of the site does not stay at the top, so the
   target keeps only a little room above it, and a line at its left marks
   where the link landed. */
[id] { scroll-margin-top: 16px; }
h2:target, h3:target, li:target, p:target { box-sizing: border-box; border-left: 2px solid var(--line); padding-left: 8px; }
.table tr:target > td { background: var(--track); }
/* A card of a type is not a modal: no veil over the page. */
.type-card::backdrop { background: transparent; }
@media (forced-colors: active) {
  /* The system colors: the icons, the marks of the values and the focus stay. */
  .value-icon::before { forced-color-adjust: none; background-color: CanvasText; }
  code.value, button.type-reference.value { border-left-color: CanvasText; }
  a:focus-visible, button:focus-visible, summary:focus-visible, input:focus-visible, [tabindex]:focus-visible { outline-color: Highlight; }
  .type-card { border-color: CanvasText; }
}
@media print {
  /* Plain black text: no color of code or of a value, no card of a type. */
  .type-cards { display: none; }
  pre, code, .value, pre .type-reference, button.type-reference.value, [class^="c-"] { color: #000; }
  pre { white-space: pre-wrap; }
}
`

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

// site_style_sheet gives the whole style sheet: the variables of the dark
// form, the rules, the grid of points of the background, then the light form
// for a reader whose system asks for it.
site_style_sheet :: proc(tile_rules: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	site_colors_write(&builder, site_dark_colors())
	strings.write_string(&builder, SITE_STYLE_RULES)
	// The color and the icon of each kind of value, in the dark form.
	strings.write_string(&builder, site_value_rules(false))
	// The colors of the code and of the parts of the browser, in the dark
	// form; the polish comes after the colors, so that print and the forced
	// colors win over them.
	strings.write_string(&builder, site_code_rules(false))
	site_polish_variables(&builder, false)
	strings.write_string(&builder, SITE_POLISH_RULES)
	// The colors and the widths of the tiles of the boot image: they come
	// from the image of the build, so they are not fixed rules.
	strings.write_string(&builder, tile_rules)
	// The grid of points of the background (docs/DESIGN.md, section 3): a
	// square of 2 pixels each 24 pixels, at 12 + 24 n. A picture in the style
	// sheet itself, so that the page asks for no other file.
	point := site_color(graphics.COLOR_POINT)
	strings.write_string(&builder, ".section-home {\n  background-image: url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24'%3E%3Crect width='2' height='2' fill='%23")
	strings.write_string(&builder, point[1:])
	strings.write_string(&builder, "'/%3E%3C/svg%3E\");\n  background-position: 12px 12px;\n}\n")
	strings.write_string(&builder, "@media (prefers-color-scheme: light) {\n")
	site_colors_write(&builder, site_light_colors())
	strings.write_string(&builder, site_value_rules(true))
	strings.write_string(&builder, site_code_rules(true))
	site_polish_variables(&builder, true)
	// The grid of points is a decoration of the dark background only.
	strings.write_string(&builder, ".section-home { background-image: none; }\n}\n")
	// Print is plain black text, also in the light form, whose colors of code
	// come after the polish.
	strings.write_string(&builder, "@media print {\n  pre, code, .value, pre .type-reference, button.type-reference.value, [class^=\"c-\"] { color: #000; }\n}\n")
	return strings.to_string(builder)
}
