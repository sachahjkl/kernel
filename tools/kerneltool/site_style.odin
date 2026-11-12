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
	on_light:    bool,
}

site_dark_colors :: proc() -> Site_Colors {
	return Site_Colors{background = graphics.COLOR_BACKGROUND, card_top = graphics.COLOR_CARD_TOP, card_bottom = graphics.COLOR_CARD_BOTTOM, track = graphics.COLOR_TRACK, text = graphics.COLOR_TEXT, dim = graphics.COLOR_DIM, line = graphics.COLOR_TITLE}
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
.bar nav ul { list-style: none; margin: 0; padding: 0; display: flex; flex-wrap: wrap; gap: 8px; }
.bar nav li { margin: 0; }
.bar nav a { display: inline-block; padding: 0 8px; line-height: 24px; background: var(--track); text-decoration: none; border-bottom: 2px solid transparent; }
.bar nav a[aria-current="page"] { border-bottom-color: var(--line); }
.crumbs ol { list-style: none; margin: 16px auto 0; padding: 0; display: flex; flex-wrap: wrap; gap: 4px; color: var(--dim); }
.crumbs li { margin: 0; }
.crumbs li + li::before { content: "/"; margin-right: 4px; color: var(--dim); }
.foot { margin-top: 64px; padding: 16px 0 32px; border-top: 1px solid var(--track); color: var(--dim); font-size: 14px; }
.foot a, .foot code { color: var(--dim); }
.source, .missing, .date, .status, figcaption, .contents-title { color: var(--dim); }
.source { font-size: 14px; }

/* Prose: a guide. The contents beside it on a wide screen. */
.prose { max-width: 72ch; }
.prose.wide { max-width: none; }
.guide { display: grid; grid-template-columns: minmax(0, 1fr); gap: 16px 32px; }
.contents { font-size: 14px; }
.contents ul { list-style: none; padding: 0; margin: 0; }
.contents li { margin: 0; }
.contents .level-3 { padding-left: 16px; }
.contents a { text-decoration: none; }
@media (min-width: 1100px) {
  .guide { grid-template-columns: 224px minmax(0, 1fr); }
  .contents { grid-column: 1; grid-row: 1; position: sticky; top: 16px; align-self: start; max-height: calc(100vh - 32px); overflow-y: auto; }
}
ol.labelled { list-style: none; padding-left: 0; }
ol.labelled > li { padding-left: 48px; text-indent: -48px; }
ol.labelled > li > * { text-indent: 0; }
.label { display: inline-block; min-width: 40px; color: var(--dim); }
.neighbours { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 8px; margin-top: 32px; }

/* Tables: the look of the tables of the system: the titles of the columns in
   the dim color, rows of 24 pixels, every second row on a band. */
.table { overflow-x: auto; margin: 0 0 16px; }
table { border-collapse: collapse; min-width: 100%; }
th { color: var(--dim); font-weight: 400; text-align: left; padding: 4px 8px; border-bottom: 1px solid var(--track); white-space: nowrap; }
td { padding: 4px 8px; vertical-align: top; }
tbody tr:nth-child(odd) { background: var(--card-top); }
td.code { white-space: nowrap; }

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
.home-head { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 32px; align-items: center; padding-top: 32px; }
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
@media (max-width: 719px) {
  .home-head { grid-template-columns: minmax(0, 1fr); }
  .measures, .pictures { grid-template-columns: minmax(0, 1fr); }
  figure.wide { grid-column: auto; }
  h1 { font-size: 28px; line-height: 32px; }
}
@media print {
  .bar, .crumbs, .contents, .neighbours, .skip { display: none; }
  html, body { background: #fff; color: #000; }
  a { color: #000; }
  .prose { max-width: none; }
  pre, code { background: none; }
}
`

// site_style_sheet gives the whole style sheet: the variables of the dark
// form, the rules, the grid of points of the background, then the light form
// for a reader whose system asks for it.
site_style_sheet :: proc() -> string {
	builder := strings.builder_make(context.temp_allocator)
	site_colors_write(&builder, site_dark_colors())
	strings.write_string(&builder, SITE_STYLE_RULES)
	// The grid of points of the background (docs/DESIGN.md, section 3): a
	// square of 2 pixels each 24 pixels, at 12 + 24 n. A picture in the style
	// sheet itself, so that the page asks for no other file.
	point := site_color(graphics.COLOR_POINT)
	strings.write_string(&builder, ".section-home {\n  background-image: url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='24' height='24'%3E%3Crect width='2' height='2' fill='%23")
	strings.write_string(&builder, point[1:])
	strings.write_string(&builder, "'/%3E%3C/svg%3E\");\n  background-position: 12px 12px;\n}\n")
	strings.write_string(&builder, "@media (prefers-color-scheme: light) {\n")
	site_colors_write(&builder, site_light_colors())
	// The grid of points is a decoration of the dark background only.
	strings.write_string(&builder, ".section-home { background-image: none; }\n}\n")
	return strings.to_string(builder)
}
