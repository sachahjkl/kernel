package kerneltool

import "core:log"
import "core:strings"
import "core:testing"
import "modus:support/graphics"

// A text with each kind of token: a file tag, a comment of each form, a
// string, a raw string, a rune, numbers, a directive, an attribute, a
// keyword, a declaration, an enum body, a member, a constant, a type in its
// place, operators, a tab, a carriage return.
@(private = "file")
SAMPLE :: "#+build amd64\npackage sample\n\nimport \"core:fmt\"\n\n// A comment < with > & marks.\n/* A block /* nested */ comment. */\nPAGE_SIZE :: 4096\nKind :: enum u8 {\n\tNone = 0, // none\n\tRead,\n}\nPair :: struct {\n\tfirst: u64,\n\tkind:  Kind,\n\tname:  [16]u8,\n\tnext:  ^Pair,\n}\n@(private = \"file\")\nsum :: proc \"contextless\" (a, b: int) -> int {\n\tx := 0x1F + 1.5e3 + 'a'\n\ts := `raw \\ text`\n\tif a < b && .Read in Kinds {\n\t\treturn a\n\t}\n\t#assert(size_of(Pair) == 32)\n\tp: Pair = ---\r\n\treturn a + b\n}\n"

// The text of colored code with its tags removed and its escapes undone.
@(private = "file")
plain_of :: proc(html: string) -> string {
	return site_html_unescape(site_tags_removed(html))
}

// The output holds every byte of the text, and each kind of token has its
// class.
@(test)
site_code_odin_of_each_token :: proc(t: ^testing.T) {
	site := test_site()
	b := strings.builder_make(context.temp_allocator)
	testing.expect(t, site_code_odin(&site, &b, SAMPLE, ""))
	html := strings.to_string(b)
	testing.expect_value(t, plain_of(html), SAMPLE)
	expect := [?]string {
		"<span class=\"c-d\">#+build amd64</span>",
		"<span class=\"c-k\">package</span>",
		// Two tokens of one class with only spaces between share one span.
		"<span class=\"c-c\">// A comment &lt; with &gt; &amp; marks.\n/* A block /* nested */ comment. */</span>",
		"<span class=\"c-n\">PAGE_SIZE</span>",
		"<span class=\"c-l\">4096</span>",
		"<span class=\"c-n\">Kind</span>",
		"<span class=\"c-k\">enum</span> <span class=\"c-t\">u8</span>",
		"<span class=\"c-l\">None</span>",
		"<span class=\"c-l\">Read</span>",
		"first<span class=\"c-p\">:</span> <span class=\"c-t\">u64</span>",
		// A name with a capital in the place of a type.
		"kind<span class=\"c-p\">:</span>  <span class=\"c-t\">Kind</span>",
		"<span class=\"c-p\">:  ^</span><span class=\"c-t\">Pair</span>",
		"<span class=\"c-d\">@</span>",
		"<span class=\"c-d\">private</span>",
		"<span class=\"c-n\">sum</span>",
		"<span class=\"c-l\">&quot;contextless&quot;</span>",
		"<span class=\"c-l\">0x1F</span>",
		"<span class=\"c-l\">1.5e3</span>",
		"<span class=\"c-l\">&#39;a&#39;</span>",
		"<span class=\"c-l\">`raw \\ text`</span>",
		"<span class=\"c-d\">#assert</span>",
		"<span class=\"c-k\">return</span>",
	}
	for part in expect {
		testing.expectf(t, strings.contains(html, part), "the colored code has no %q:\n%s", part, html)
	}
	// A name with a capital out of the place of a type is not guessed:
	// "size_of(Pair)" and "in Kinds" stay plain.
	testing.expect(t, strings.contains(html, "size_of<span class=\"c-p\">(</span>Pair<span class=\"c-p\">)"), html)
	testing.expect(t, strings.contains(html, "<span class=\"c-k\">in</span> Kinds"), html)
}

// A text that the tokenizer refuses is plain, counted, and its place named.
@(test)
site_code_block_not_colored :: proc(t: ^testing.T) {
	site := test_site()
	b := strings.builder_make(context.temp_allocator)
	testing.expect(t, !site_code_odin(&site, &b, "name := \"no end\n", ""))
	testing.expect_value(t, strings.builder_len(b), 0)
	plain := site_code_block_html(&site, "a → b < c", "", "docs/TEST.md:3")
	testing.expect_value(t, plain, "a → b &lt; c")
	testing.expect_value(t, site.code_blocks_not_colored, 1)
	testing.expect_value(t, site.first_code_block_not_colored, "docs/TEST.md:3")
	site_code_block_html(&site, "/* no end", "", "docs/TEST.md:9")
	testing.expect_value(t, site.code_blocks_not_colored, 2)
	testing.expect_value(t, site.first_code_block_not_colored, "docs/TEST.md:3")
	// A fragment that is not a declaration is still tokens: it is colored.
	colored := site_code_block_html(&site, "Memory_Map(memory) -> address ... more", "", "docs/TEST.md:12")
	testing.expect_value(t, plain_of(colored), "Memory_Map(memory) -> address ... more")
	testing.expect_value(t, site.code_blocks_not_colored, 2)
}

// Each declaration of the documented packages, and each of their files
// whole, comes back byte for byte; a type of the contract in a declaration
// is a reference to its card.
@(test)
site_code_odin_of_the_contract :: proc(t: ^testing.T) {
	site := test_site()
	if !site_reference_read(&site) {
		testing.expect(t, false, "the sources of the reference cannot be read")
		return
	}
	packages := SITE_TYPE_PACKAGES
	declarations := 0
	for folder in packages {
		package_name := folder[strings.last_index_byte(folder, '/') + 1:]
		found, ok := site_type_declarations_read(folder)
		testing.expect(t, ok)
		for declaration in found {
			b := strings.builder_make(context.temp_allocator)
			colored := site_code_odin(&site, &b, declaration.declaration, package_name)
			testing.expectf(t, colored, "%s, line %d: the tokenizer refuses the declaration of %s", declaration.file, declaration.line, declaration.name)
			testing.expectf(t, plain_of(strings.to_string(b)) == declaration.declaration, "%s, line %d: the colored declaration of %s is not its text", declaration.file, declaration.line, declaration.name)
			declarations += 1
		}
		paths, listed := files_with_suffix(folder, ".odin")
		testing.expect(t, listed)
		for path in paths {
			text, read := site_read_quiet(path)
			testing.expect(t, read)
			b := strings.builder_make(context.temp_allocator)
			testing.expectf(t, site_code_odin(&site, &b, text, package_name), "%s: the tokenizer refuses the file", path)
			testing.expectf(t, plain_of(strings.to_string(b)) == text, "%s: the colored file is not its text", path)
		}
	}
	testing.expect(t, declarations > 80)
	// A field whose type is a type of the contract, and an alias.
	for type in site.types {
		if type.key != "operation.Event_Rule" {
			continue
		}
		html := site_code_block_html(&site, type.declaration, "operation", "operation.Event_Rule")
		testing.expect(t, strings.contains(html, "popovertarget=\"card-type-operation-event-rule-flags\""), html)
	}
	// In a block of a guide the package is not known: only a qualified name
	// of a documented package is a reference.
	guide := site_code_block_html(&site, "error: ^errors.Error_Record, flags: Memory_Flags", "", "guide")
	testing.expect(t, strings.contains(guide, "popovertarget=\"card-type-errors-error-record\""), guide)
	testing.expect(t, !strings.contains(guide, "card-type-operation-memory-flags"), guide)
	testing.expect(t, strings.contains(guide, "<span class=\"c-t\">Memory_Flags</span>"), guide)
	testing.expect_value(t, site.code_blocks_not_colored, 0)
}

// Each class of the code keeps its contrast on the block of code (the track
// color) in both forms, and the selection and the placeholder keep theirs.
@(test)
site_code_colors_keep_their_contrast :: proc(t: ^testing.T) {
	for is_light in ([]bool{false, true}) {
		colors := is_light ? site_light_colors() : site_dark_colors()
		for class in Site_Code_Class {
			if site_code_classes[class].name == "" {
				continue
			}
			ratio := site_contrast_ratio(site_code_color(class, is_light), colors.track)
			testing.expectf(t, ratio >= SITE_VALUE_CONTRAST_LEAST, "the class c-%s on %06x (light form: %v): a contrast of %.2f; at least %.1f", site_code_classes[class].name, u32(colors.track), is_light, ratio, SITE_VALUE_CONTRAST_LEAST)
		}
		selection, selection_text, placeholder := site_polish_colors(is_light)
		testing.expectf(t, site_contrast_ratio(selection_text, selection) >= SITE_VALUE_CONTRAST_LEAST, "the selection (light form: %v): %.2f", is_light, site_contrast_ratio(selection_text, selection))
		testing.expectf(t, site_contrast_ratio(placeholder, colors.track) >= SITE_VALUE_CONTRAST_LEAST, "the placeholder (light form: %v): %.2f", is_light, site_contrast_ratio(placeholder, colors.track))
	}
	// The class names are short and each one is its own.
	names := make(map[string]bool, context.temp_allocator)
	for class in Site_Code_Class {
		name := site_code_classes[class].name
		if name == "" {
			continue
		}
		testing.expectf(t, len(name) == 1 && name not_in names, "the class %v has the name %q", class, name)
		names[name] = true
	}
	testing.expect(t, site_contrast_ratio(graphics.COLOR_WHITE, graphics.COLOR_BLACK) > 20.9)
}

// The style sheet holds the polish of the parts of the browser, removes no
// outline, and has no round corner.
@(test)
site_style_sheet_polish :: proc(t: ^testing.T) {
	sheet := site_style_sheet("")
	expect := [?]string {
		"color-scheme: dark light;",
		"scrollbar-gutter: stable;",
		"overscroll-behavior: contain;",
		"::selection { background: var(--selection); color: var(--selection-text); }",
		"--selection:",
		"--placeholder:",
		"accent-color: var(--line);",
		"caret-color: var(--line);",
		"::placeholder { color: var(--placeholder); opacity: 1; }",
		"button:focus-visible",
		"summary:focus-visible",
		"[tabindex]:focus-visible",
		"outline: 2px solid var(--line);",
		"li::marker, summary::marker { color: var(--dim); }",
		"text-wrap: balance;",
		"text-wrap: pretty;",
		"tab-size: 4;",
		"scroll-margin-top:",
		":target",
		"-webkit-tap-highlight-color:",
		"touch-action: manipulation;",
		"text-size-adjust: 100%;",
		"image-rendering: pixelated;",
		".type-card::backdrop, .declaration-card::backdrop",
		"@media (forced-colors: active)",
		".type-cards, .declaration-cards { display: none; }",
		".c-k { color:",
		".c-c { color:",
		"pre .type-reference { color:",
	}
	for part in expect {
		testing.expectf(t, strings.contains(sheet, part), "the style sheet has no %q", part)
	}
	testing.expect(t, !strings.contains(sheet, "outline: none"), "the style sheet removes an outline")
	testing.expect(t, !strings.contains(sheet, "outline: 0"), "the style sheet removes an outline")
	// Each border-radius is 0: no round corner (docs/DESIGN.md).
	rest := sheet
	for {
		start := strings.index(rest, "border-radius:")
		if start < 0 {
			break
		}
		rest = rest[start + len("border-radius:"):]
		value := strings.trim_space(rest[:strings.index_any(rest, ";}")])
		testing.expectf(t, value == "0", "a border-radius of %q", value)
	}
	// A jump to an anchor goes there at once: the page never scrolls by itself.
	testing.expect_value(t, strings.count(sheet, "scroll-behavior: smooth"), 0)
}

// The scroll bars: the parts of WebKit and Chromium with an arrow button
// at each end, a track, a thumb with its gradient, its inner line and its
// grip, and its colors with the pointer over it and while it is held; the
// two standard properties only for an engine with no such parts, because
// Chromium ignores the parts of an element that has them. Each size, each
// color and each gradient is a variable written from the table of the
// scroll bar of the system; each triangle and each grip is a data address
// in the colors of its form; the rules hold no size and no color of their
// own.
@(test)
site_style_sheet_scroll_bars :: proc(t: ^testing.T) {
	sheet := site_style_sheet("")
	expect := [?]string {
		"@supports selector(::-webkit-scrollbar) {",
		"@supports not selector(::-webkit-scrollbar) {",
		"::-webkit-scrollbar { width: var(--scroll-thickness); height: var(--scroll-thickness);",
		"::-webkit-scrollbar-track { border: var(--scroll-border) solid var(--scroll-track-border); }",
		"::-webkit-scrollbar-track:vertical { background: var(--scroll-track-vertical);",
		"::-webkit-scrollbar-track:horizontal { background: var(--scroll-track-horizontal);",
		"::-webkit-scrollbar-thumb { border: var(--scroll-border) solid var(--scroll-thumb-border); border-radius: 0;",
		"box-shadow: inset 0 0 0 var(--scroll-border) var(--scroll-thumb-line); }",
		"::-webkit-scrollbar-thumb:vertical { min-height: var(--scroll-thumb-least); background-image: var(--scroll-grip-vertical), var(--scroll-thumb-vertical); }",
		"::-webkit-scrollbar-thumb:horizontal { min-width: var(--scroll-thumb-least); background-image: var(--scroll-grip-horizontal), var(--scroll-thumb-horizontal); }",
		"::-webkit-scrollbar-thumb:hover { border-color: var(--scroll-hot-border); }",
		"::-webkit-scrollbar-thumb:vertical:hover { background-image: var(--scroll-grip-vertical-lit), var(--scroll-thumb-hot-vertical); }",
		"::-webkit-scrollbar-thumb:vertical:active { background-image: var(--scroll-grip-vertical-lit), var(--scroll-thumb-pressed-vertical); }",
		"::-webkit-scrollbar-button:single-button {",
		"::-webkit-scrollbar-button:single-button:vertical:decrement { background-image: var(--scroll-arrow-up), var(--scroll-track-vertical); }",
		"::-webkit-scrollbar-button:single-button:vertical:increment { background-image: var(--scroll-arrow-down), var(--scroll-track-vertical); }",
		"::-webkit-scrollbar-button:single-button:horizontal:decrement { background-image: var(--scroll-arrow-left), var(--scroll-track-horizontal); }",
		"::-webkit-scrollbar-button:single-button:horizontal:increment { background-image: var(--scroll-arrow-right), var(--scroll-track-horizontal); }",
		"::-webkit-scrollbar-button:single-button:vertical:increment:hover { background-image: var(--scroll-arrow-down-hot), var(--scroll-arrow-hot-vertical); }",
		"::-webkit-scrollbar-button:single-button:vertical:increment:active { background-image: var(--scroll-arrow-down-hot), var(--scroll-arrow-pressed-vertical); }",
		"::-webkit-scrollbar-corner {",
		"scrollbar-color: var(--scroll-thumb-border) var(--scroll-track-middle); scrollbar-width: auto;",
		// The variables of the dark form, each from the table of the scroll
		// bar of the system: the sizes, a color, the inner line, a gradient
		// of the track, of the thumb and of an arrow button.
		"--scroll-thickness: 17px;",
		"--scroll-border: 1px;",
		"--scroll-thumb-least: 21px;",
		"--scroll-track-middle: #2c3743;",
		"--scroll-thumb-line: rgb(255 255 255 / 12%);",
		"--scroll-track-vertical: linear-gradient(to right, #26303a 0%, #2c3743 50%, #26303a 100%);",
		"--scroll-thumb-vertical: linear-gradient(to right, #4a5967 0%, #43515e 45%, #3c4955 55%, #36424d 100%);",
		"--scroll-thumb-horizontal: linear-gradient(to bottom, #4a5967 0%, #43515e 45%, #3c4955 55%, #36424d 100%);",
		"--scroll-thumb-hot-vertical: linear-gradient(to right, #365b7d 0%, #305273 45%, #2a4968 55%, #25415d 100%);",
		"--scroll-arrow-pressed-vertical: linear-gradient(to right, #2d5578 0%, #244a6b 100%);",
		// And of the light form.
		"--scroll-track-middle: #f1f1f1;",
		"--scroll-thumb-line: rgb(255 255 255 / 40%);",
		"--scroll-thumb-vertical: linear-gradient(to right, #f3f3f3 0%, #e8e8e8 45%, #d9d9d9 55%, #cdcdcd 100%);",
	}
	for part in expect {
		testing.expectf(t, strings.contains(sheet, part), "the style sheet has no %q", part)
	}
	// The standard properties are only inside the test of the engines with
	// no parts of WebKit: written elsewhere, Chromium would drop the parts.
	standard := strings.index(sheet, "scrollbar-color:")
	no_parts := strings.index(sheet, "@supports not selector(::-webkit-scrollbar) {")
	testing.expect(t, standard > no_parts && no_parts >= 0, "scrollbar-color is outside the test of the engines with no parts of WebKit")
	testing.expect_value(t, strings.count(sheet, "scrollbar-color:"), 1)
	testing.expect_value(t, strings.count(sheet, "scrollbar-width:"), 1)
	// The rules of the scroll bars name no color and no size in pixels but
	// the 0 of an inset: both come from the variables, which the table of
	// the scroll bar of the system writes.
	testing.expect(t, !strings.contains(SITE_SCROLL_RULES, "#") && !strings.contains(SITE_SCROLL_RULES, "rgb") && !strings.contains(SITE_SCROLL_RULES, "data:") && !strings.contains(SITE_SCROLL_RULES, "gradient("), "the rules of the scroll bars hold a color of their own")
	testing.expect(t, !strings.contains(SITE_SCROLL_RULES, "px"), "the rules of the scroll bars hold a size of their own")
	// The variables of each form, and each data address well formed, in
	// the colors of its form only.
	for is_light in ([]bool{false, true}) {
		colors := site_scroll_colors(is_light)
		b := strings.builder_make(context.temp_allocator)
		site_scroll_variables(&b, is_light)
		variables := strings.to_string(b)
		testing.expectf(t, strings.contains(sheet, variables), "the style sheet has not the variables of the scroll bars (light form: %v)", is_light)
		allowed := []graphics.Color{colors.triangle, colors.triangle_hot, colors.grip, colors.grip_lit}
		addresses := 0
		rest := variables
		for {
			start := strings.index(rest, "url(\"")
			if start < 0 {
				break
			}
			rest = rest[start + len("url(\""):]
			end := strings.index(rest, "\")")
			testing.expect(t, end > 0, "a data address has no end")
			if end <= 0 {
				break
			}
			address := rest[:end]
			addresses += 1
			testing.expectf(t, strings.has_prefix(address, "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg'") && strings.has_suffix(address, "%3C/svg%3E"), "a data address of the scroll bars is not an SVG picture: %s", address)
			testing.expectf(t, !strings.contains_any(address, "<>\"#\n"), "a data address of the scroll bars holds a character that ends it: %s", address)
			// Each color inside the address is a color of the form.
			colors_inside := 0
			inner := address
			for {
				mark := strings.index(inner, "%23")
				if mark < 0 {
					break
				}
				inner = inner[mark + 3:]
				testing.expect(t, len(inner) >= 6)
				if len(inner) < 6 {
					break
				}
				found := false
				for color in allowed {
					found ||= site_color(color)[1:] == inner[:6]
				}
				testing.expectf(t, found, "the color %s of a data address is not a color of the scroll bars (light form: %v)", inner[:6], is_light)
				colors_inside += 1
			}
			testing.expectf(t, colors_inside == 1, "a data address of the scroll bars has %d colors", colors_inside)
			rest = rest[end:]
		}
		// Four triangles and two grips, each at rest and with the pointer.
		testing.expect_value(t, addresses, 12)
		// The parts that the pointer lights keep the contrast of a graphic:
		// the border of the thumb under the pointer on the track, a
		// triangle on the track and on the fill of its button, the grip on
		// the thumb under the pointer and while it is held.
		pairs := [?][2]graphics.Color {
			{colors.hot_border, colors.track[1]},
			{colors.triangle, colors.track[1]},
			{colors.triangle_hot, colors.arrow_hot[0]},
			{colors.triangle_hot, colors.arrow_pressed[0]},
			{colors.grip_lit, colors.thumb_hot[1]},
			{colors.grip_lit, colors.thumb_pressed[1]},
		}
		for pair in pairs {
			ratio := site_contrast_ratio(pair[0], pair[1])
			testing.expectf(t, ratio >= SITE_VALUE_GRAPHIC_CONTRAST_LEAST, "%06x on %06x (light form: %v): %.2f; at least %.1f", u32(pair[0]), u32(pair[1]), is_light, ratio, SITE_VALUE_GRAPHIC_CONTRAST_LEAST)
		}
		// At rest the standard is quiet: the border of the thumb and its
		// grip are under 3 to 1. The numbers are a measure, not a bound.
		log.infof("the scroll bar at rest (light form: %v): the border of the thumb on the track %.2f to 1, the grip on the thumb %.2f to 1", is_light, site_contrast_ratio(colors.thumb_border, colors.track[1]), site_contrast_ratio(colors.grip, colors.thumb_rest[1]))
	}
	// A triangle is four rows of 1, 3, 5 and 7 pixels in the middle of a
	// square of 17, its point on the middle line, toward its end of the bar.
	up := site_scroll_arrow_svg(.Up, graphics.COLOR_WHITE)
	testing.expect(t, strings.contains(up, "width=\"17\" height=\"17\""), up)
	testing.expect(t, strings.contains(up, "<rect x=\"8\" y=\"6\" width=\"1\" height=\"1\"/><rect x=\"7\" y=\"7\" width=\"3\" height=\"1\"/><rect x=\"6\" y=\"8\" width=\"5\" height=\"1\"/><rect x=\"5\" y=\"9\" width=\"7\" height=\"1\"/>"), up)
	down := site_scroll_arrow_svg(.Down, graphics.COLOR_WHITE)
	testing.expect(t, strings.contains(down, "<rect x=\"5\" y=\"6\" width=\"7\" height=\"1\"/>") && strings.contains(down, "<rect x=\"8\" y=\"9\" width=\"1\" height=\"1\"/>"), down)
	right := site_scroll_arrow_svg(.Right, graphics.COLOR_WHITE)
	testing.expect(t, strings.contains(right, "<rect x=\"6\" y=\"5\" width=\"1\" height=\"7\"/>") && strings.contains(right, "<rect x=\"9\" y=\"8\" width=\"1\" height=\"1\"/>"), right)
	// A grip is four lines of 7 pixels, 2 pixels from one to the next.
	grip := site_scroll_grip_svg(true, graphics.COLOR_WHITE)
	testing.expect(t, strings.contains(grip, "width=\"7\" height=\"7\"") && strings.contains(grip, "<rect x=\"0\" y=\"0\" width=\"7\" height=\"1\"/><rect x=\"0\" y=\"2\" width=\"7\" height=\"1\"/><rect x=\"0\" y=\"4\" width=\"7\" height=\"1\"/><rect x=\"0\" y=\"6\" width=\"7\" height=\"1\"/>"), grip)
	// Each size of the variables is a number of the table.
	testing.expect_value(t, SITE_SCROLL_THUMB_LEAST, graphics.SCROLL_BAR_GRIP_THUMB_LEAST + 1)
}
