package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "modus:support/graphics"
import "modus:support/mark"

// The stages of the start as a run of the main machine test logged them.
@(private = "file")
HOME_TEST_BOOT_LOG :: "kernel: boot: firmware: 1516608 us\nkernel: boot: boot program: load the kernel, the boot image: 72641 us\nkernel: boot: boot program: page tables, memory map, jump: 17400 us\nkernel: boot: kernel: page frames, kernel page table: 598 us\nkernel: boot: kernel: first processor, timer: 18457 us\nkernel: boot: kernel: other processors: 33593 us\nkernel: boot: kernel: root service: 2787 us\n"

// The three widths of a window that the labels are counted for.
@(private = "file")
home_test_window_widths := [?]int{360, 720, 1200}

@(private = "file")
home_test_site :: proc() -> Site {
	site := test_site()
	site.boot_stages = site_boot_stages(HOME_TEST_BOOT_LOG)
	site.release = "0.91.0"
	site.step_count = 91
	append(&site.pages, Site_Page{path = site_section_page(.Home), title = "Home", section = .Home})
	append(&site.pages, Site_Page{path = site_section_page(.Releases), title = "Releases", section = .Releases})
	append(&site.pages, Site_Page{path = site_page_file(SITE_NUMBERS_FOLDER), title = "Measured numbers", section = .Reference})
	return site
}

// The segments of the two bars of the line of time fill their bar, in the
// order of the stages; the first bar has one scale, and each stage of the
// second bar has its least share. The name and the time of each stage fit
// their boxes at 360, 720 and 1200 pixels.
@(test)
site_home_timeline_segments_and_labels :: proc(t: ^testing.T) {
	stages := site_boot_stages(HOME_TEST_BOOT_LOG)
	testing.expect_value(t, len(stages), 7)
	if len(stages) != 7 {
		return
	}
	total := 0
	for stage in stages {
		total += stage.microseconds
	}
	whole := site_boot_whole_segments(stages)
	place := 0
	for segment, index in whole {
		testing.expect_value(t, segment.start, place)
		place += segment.width
		// One scale: the width is the time, within one part of the rounding
		// (the last segment takes what the rounding left).
		exact := stages[index].microseconds * SITE_BOOT_WHOLE_PARTS / total
		testing.expectf(t, segment.width >= exact && segment.width <= exact + len(stages), "the stage %d is %d parts wide; its time gives %d", index, segment.width, exact)
	}
	testing.expect_value(t, place, SITE_BOOT_WHOLE_PARTS)
	// The firmware takes most of the first bar.
	testing.expect(t, whole[0].width > 9000)
	testing.expect_value(t, site_boot_parts_percent(whole[0].width), "91.24%")
	testing.expect_value(t, site_boot_parts_percent(5), "0.05%")

	system := site_boot_system_segments(stages)
	testing.expect_value(t, len(system), len(stages) - 1)
	place = 0
	for segment, index in system {
		testing.expect_value(t, segment.start, place)
		place += segment.width
		testing.expectf(t, segment.width >= SITE_BOOT_SYSTEM_LEAST_SHARE, "the stage %d has %d thousandths of the second bar", index + 1, segment.width)
	}
	testing.expect_value(t, place, 1000)
	// A longer stage is never narrower than a shorter one.
	for first, first_index in stages[1:] {
		for second, second_index in stages[1:] {
			if first.microseconds > second.microseconds {
				testing.expect(t, system[first_index].width >= system[second_index].width)
			}
		}
	}
	testing.expect_value(t, len(site_boot_system_segments(stages[:1])), 0)
	testing.expect_value(t, len(site_boot_whole_segments(nil)), 0)

	// The labels: a name wraps between its words, so its longest word must
	// fit the box of the name; the time is one line.
	widths := home_test_window_widths
	for window_width in widths {
		box := site_boot_name_box_width(window_width)
		testing.expectf(t, box >= 120, "at %d pixels the box of a name has %d pixels", window_width, box)
		for stage in stages {
			for word in strings.fields(site_boot_stage_name(stage), context.temp_allocator) {
				testing.expectf(t, len(word) * SITE_BOOT_CHARACTER_WIDTH <= box, "at %d pixels the word %q is wider than the %d pixels of its box", window_width, word, box)
			}
			testing.expectf(t, len(site_milliseconds_text(stage.microseconds)) <= SITE_BOOT_TIME_CHARACTERS, "the time %q is longer than its box", site_milliseconds_text(stage.microseconds))
		}
	}
	testing.expect_value(t, site_boot_name_box_width(360), 169)
	testing.expect_value(t, site_milliseconds_text(72641), "72.6 ms")
}

// The markup of the line of time: two bars, a row and a card for each
// stage, the scale of each bar in words, and no sentence stuck under the
// bars. Each stage that the kernel logs has its text, and each text names
// a heading that its guide has.
@(test)
site_home_timeline_markup :: proc(t: ^testing.T) {
	site := home_test_site()
	site.documents["docs/ARCHITECTURE.md"] = "docs/guides/ARCHITECTURE/index.html"
	headings := make([]Site_Heading, 1, context.temp_allocator)
	headings[0] = {level = 3, text = "U2. Root service", id = "u2-root-service"}
	site.guides = make([dynamic]Site_Guide, context.temp_allocator)
	append(&site.guides, Site_Guide{source = "docs/ARCHITECTURE.md", path = "docs/guides/ARCHITECTURE/index.html", title = "Architecture", headings = headings})
	b := strings.builder_make(context.temp_allocator)
	site_boot_timeline_write(&site, &b, site_section_page(.Home))
	html := strings.to_string(b)
	testing.expect(t, strings.has_prefix(html, "<section class=\"card accent-kernel boot-timeline\" aria-labelledby=\"start\">\n<h2 id=\"start\">The start of the machine</h2>\n"))
	testing.expect_value(t, strings.count(html, "<svg class=\"boot-bar "), 2)
	testing.expect_value(t, strings.count(html, "<rect class=\"boot-segment "), 7 + 6)
	testing.expect_value(t, strings.count(html, "<li class=\"boot-stage "), 7)
	testing.expect_value(t, strings.count(html, "<div class=\"boot-card boot-card-"), 7 + 1)
	testing.expect(t, strings.contains(html, "<rect class=\"boot-segment boot-segment-0 accent-firmware\" x=\"0.00%\" width=\"91.24%\" height=\"100%\"/>"), html)
	testing.expect(t, strings.contains(html, "<line x1=\"91.24%\" y1=\"0\" x2=\"0\" y2=\"100%\"/>"))
	// The scale of each bar is said in words.
	testing.expect(t, strings.contains(html, "<code class=\"value value-time\">1662.0 ms</code>. One scale: a width is a time.</p>"), html)
	testing.expect(t, strings.contains(html, "<code class=\"value value-time\">145.4 ms</code> after the firmware, 11.4 times wider. A stage is at least 2 % of this bar wide"), html)
	// A row: the name and the time, with no pointer; the keyboard reaches
	// it, and it names its card.
	testing.expect(t, strings.contains(html, "<li class=\"boot-stage boot-stage-6 accent-kernel\"><div class=\"boot-stage-row\" tabindex=\"0\" aria-describedby=\"boot-card-6\"><span class=\"boot-stage-square\" aria-hidden=\"true\"></span><span class=\"boot-stage-name\"><span class=\"boot-stage-who\">kernel</span> root service</span><code class=\"value value-time boot-stage-time\">2.7 ms</code></div></li>"), html)
	// A card: what the stage does, who runs it, its line, its guide.
	testing.expect(t, strings.contains(html, "<dt>Measured from</dt><dd><code>kernel: boot: kernel: root service: 2787 us</code></dd>"))
	testing.expect(t, strings.contains(html, "<dt>Guide</dt><dd><a href=\"docs/guides/ARCHITECTURE/index.html#u2-root-service\">Architecture: U2. Root service</a></dd>"), html)
	testing.expect(t, strings.contains(html, "<dt>Runs it</dt><dd>The kernel, then the root service.</dd>"))
	// The source of the times is in the card of the hint, not under the bars.
	testing.expect(t, strings.contains(html, "<div class=\"boot-card boot-card-hint\">"))
	testing.expect(t, !strings.contains(html, "<ol class=\"stages\">") && !strings.contains(html, "</ol>\n<p class=\"source\">"))
	testing.expect(t, strings.contains(html, "The run of the measures</a>"))

	// No stage: the section says so, with no bar.
	site.boot_stages = nil
	empty := strings.builder_make(context.temp_allocator)
	site_boot_timeline_write(&site, &empty, site_section_page(.Home))
	testing.expect(t, strings.contains(strings.to_string(empty), SITE_NOT_MEASURED) && !strings.contains(strings.to_string(empty), "<svg"))

	// Each stage of the log has its text; each text names a guide of the
	// repository and a heading that the guide has; the count of the stages
	// is under the count of the rules of the style sheet.
	stages := site_boot_stages(HOME_TEST_BOOT_LOG)
	testing.expect(t, len(stages) <= SITE_BOOT_STAGE_RULE_COUNT)
	for stage in stages {
		text, found := site_boot_stage_text(site_boot_stage_name(stage))
		testing.expectf(t, found, "the stage %q has no text", site_boot_stage_name(stage))
		if !found {
			continue
		}
		testing.expect(t, text.does != "" && text.runs != "" && strings.has_suffix(text.does, "."))
		data, read_error := os.read_entire_file(text.guide, context.temp_allocator)
		testing.expectf(t, read_error == nil, "cannot read %s", text.guide)
		has_heading := false
		for line in site_lines(string(data)) {
			if strings.has_prefix(line, "#") && strings.trim_left(line, "# ") == text.heading {
				has_heading = true
			}
		}
		testing.expectf(t, has_heading, "%s has no heading %q", text.guide, text.heading)
	}
}

// A chart shows numbers of one unit, all of them or none: a line that
// lacks a number, or whose number has another unit, gives no chart; with
// no chart the home has no section of measures.
@(test)
site_home_charts_hold_one_unit :: proc(t: ^testing.T) {
	locks_line := "locks: kernel entries in one second, each locker on its own objects: 1 locker 4487253, 2 lockers 9639893, 4 lockers 11207253"
	glyph_line := "vector_glyphs: one glyph from its outline, in fixed point, with the stripes (the least of batches): scale 1 5044 ns, scale 2 12984 ns, scale 3 23506 ns; from the glyph cache: 289 ns; Spleen 8x16: 46 ns"
	charts := site_measure_charts
	lines := [?]string{locks_line, glyph_line}
	testing.expect_value(t, len(charts), len(lines))
	for chart, index in charts {
		// One unit for a chart, and its measure is in the table.
		testing.expect(t, chart.unit != "" && chart.title != "" && chart.kind != .None)
		in_table := false
		for measure in site_measures {
			in_table ||= measure.pattern == chart.pattern
		}
		testing.expectf(t, in_table, "the chart %q names no measure of the table", chart.title)
		bar_count := 0
		for bar in chart.bars {
			bar_count += bar.label != "" ? 1 : 0
		}
		values, count, ok := site_chart_values(chart, lines[index])
		testing.expectf(t, ok && count == bar_count && count >= 2, "the chart %q reads %d of %d numbers", chart.title, count, bar_count)
		for value in values[:count] {
			testing.expect(t, value > 0)
		}
	}
	locks_values, _, _ := site_chart_values(charts[0], locks_line)
	testing.expect_value(t, locks_values[0], 4487253)
	testing.expect_value(t, locks_values[2], 11207253)
	glyph_values, _, _ := site_chart_values(charts[1], glyph_line)
	testing.expect_value(t, glyph_values[3], 289)
	// A number in another unit, and a line with a number less: no chart.
	other_unit, _ := strings.replace_all(glyph_line, "289 ns", "289 us", context.temp_allocator)
	_, _, other_ok := site_chart_values(charts[1], other_unit)
	testing.expect(t, !other_ok, "a chart took a number of another unit")
	fewer, _ := strings.replace_all(locks_line, ", 4 lockers 11207253", "", context.temp_allocator)
	_, _, fewer_ok := site_chart_values(charts[0], fewer)
	testing.expect(t, !fewer_ok, "a chart took a line that lacks a number")

	// The widths: from zero, in proportion to the longest bar.
	testing.expect_value(t, site_chart_bar_width(11207253, 11207253), 1000)
	testing.expect_value(t, site_chart_bar_width(4487253, 11207253), 400)
	testing.expect_value(t, site_chart_bar_width(1, 11207253), SITE_CHART_BAR_LEAST)
	testing.expect_value(t, site_chart_bar_width(0, 11207253), 0)
	testing.expect_value(t, site_grouped_number(4487253), "4 487 253")
	testing.expect_value(t, site_grouped_number(289), "289")
	testing.expect_value(t, site_grouped_number(1000), "1 000")

	// The markup.
	site := home_test_site()
	measured := make([]Site_Measured, 2, context.temp_allocator)
	measured[0] = {measure = site_measures[0], found = true, text = locks_line}
	measured[1] = {measure = site_measures[4], found = true, text = "compositor: a full frame of 1024x768 with 17 windows in 1747 us"}
	site.measured = measured
	b := strings.builder_make(context.temp_allocator)
	site_measure_charts_write(&site, &b, site_section_page(.Home))
	html := strings.to_string(b)
	testing.expect_value(t, strings.count(html, "<article class=\"card measure-chart "), 1)
	testing.expect_value(t, strings.count(html, "<li class=\"measure-row\">"), 3)
	testing.expect(t, strings.contains(html, "<li class=\"measure-row\"><span class=\"measure-label\">1 program</span><svg class=\"measure-bar\" aria-hidden=\"true\"><rect class=\"measure-bar-fill\" width=\"40.0%\" height=\"100%\"/></svg><code class=\"value value-number measure-value\">4 487 253</code></li>"), html)
	testing.expect(t, strings.contains(html, "<p class=\"measure-unit\">In kernel entries in one second. Each bar starts at zero.</p>"))
	testing.expect(t, strings.contains(html, "#number-kernel-entries-in-one-second"))
	// The measure that is not a chart is not on the home.
	testing.expect(t, !strings.contains(html, "compositor") && !strings.contains(html, "<p class=\"line\">"))
	// With no chart, no section and no heading.
	site.measured = measured[1:]
	none := strings.builder_make(context.temp_allocator)
	site_measure_charts_write(&site, &none, site_section_page(.Home))
	testing.expect_value(t, strings.to_string(none), "")
}

// The band of the newest release: the number as its one large value, the
// date and the counts, the first changes by their summaries, each a link
// to the change on the page of the releases.
@(test)
site_home_release_band :: proc(t: ^testing.T) {
	site := home_test_site()
	entries := make([]Changelog_Entry, 6, context.temp_allocator)
	for &entry, index in entries {
		lines := make([]string, 1, context.temp_allocator)
		lines[0] = fmt.tprintf("**The change %d**: what it gives.", index + 1)
		entry = Changelog_Entry{type_index = index < 5 ? 0 : 1, lines = lines}
	}
	releases := make([]Changelog_Release, 1, context.temp_allocator)
	releases[0] = {date = "2026-11-12", entries = entries}
	site.changelog.releases = releases
	b := strings.builder_make(context.temp_allocator)
	site_release_band_write(&site, &b, site_section_page(.Home))
	html := strings.to_string(b)
	testing.expect(t, strings.contains(html, "<span class=\"value value-version release-number\">0.91.0</span>"), html)
	testing.expect(t, strings.contains(html, "<time datetime=\"2026-11-12\">2026-11-12</time>, <strong>6</strong> changes, <strong>91</strong> steps so far"))
	testing.expect_value(t, strings.count(html, "<li><span class=\"release-change-type\">"), SITE_RELEASE_BAND_CHANGE_COUNT)
	types := CHANGE_TYPES
	first := fmt.tprintf("<li><span class=\"release-change-type\">%s</span> <a href=\"releases/index.html#release-0-91-0-change-1\">The change 1</a></li>", types[0])
	testing.expect(t, strings.contains(html, first), html)
	testing.expect(t, strings.contains(html, "And <strong>2</strong> more changes in this release. <a href=\"releases/index.html\">All 1 releases</a>"), html)
	testing.expect_value(t, site_change_id("0.91.0", 3), "release-0-91-0-change-3")
	// A change with no bold summary gives its first sentence.
	plain := Changelog_Entry{lines = []string{"A plain change. More words."}}
	testing.expect_value(t, site_change_summary(plain), "A plain change.")
	testing.expect_value(t, site_change_summary(entries[0]), "The change 1")
}

// The content of a card starts at its top: a card of the news with no
// picture has its text right under its line of the kind, and no rule of a
// card pushes a part to the bottom of the card.
@(test)
site_card_content_starts_at_the_top :: proc(t: ^testing.T) {
	sheet := site_style_sheet("")
	testing.expect(t, strings.contains(sheet, ".news-card > p:last-child { grid-row: 4; align-self: start; }"))
	testing.expect(t, strings.contains(sheet, ".news-card-without-picture > p:last-child { grid-row: 3 / span 2; }"))
	for refused in ([]string{"margin-top: auto", "align-self: end", "align-content: end", "align-content: space-between", "align-items: end"}) {
		testing.expectf(t, !strings.contains(sheet, refused), "the style sheet holds %q: a part of a card would sit at its bottom", refused)
	}
	// Each grid of cards whose cards have their own height says so.
	for rule in ([]string{".docs-parts { display: grid; grid-template-columns: minmax(0, 1fr); align-items: start;", ".roadmap-columns { display: grid; grid-template-columns: minmax(0, 1fr); gap: 0 16px; align-items: start; }", ".measure-charts { display: grid; grid-template-columns: minmax(0, 1fr); gap: 8px; align-items: start;"}) {
		testing.expectf(t, strings.contains(sheet, rule), "the style sheet has no %q", rule)
	}
	site: Site
	with_picture := Site_News{entry = News_Entry{title = "With", date = "2026-11-11"}, anchor = "news-with", picture = "pictures/console.png", picture_width = 1024, picture_height = 768, picture_alt = "A picture"}
	without_picture := Site_News{entry = News_Entry{title = "Without", date = "2026-11-12"}, anchor = "news-without"}
	site.news = []Site_News{with_picture, without_picture}
	b := strings.builder_make(context.temp_allocator)
	site_news_home(&site, &b)
	html := strings.to_string(b)
	testing.expect_value(t, strings.count(html, "news-card-without-picture"), 1)
	without_place := strings.index(html, "news-card-without-picture")
	testing.expect(t, without_place > strings.index(html, "news-with") && without_place < strings.index(html, "news-without"), html)
}

// Each control of the table has its four states in the style sheet: at
// rest, with the pointer over it, with the focus, and pressed; and its
// current state when it has one. A state changes no size, and nothing
// changes over time. The text of each state has a contrast of 4.5 to 1.
@(test)
site_controls_have_their_states :: proc(t: ^testing.T) {
	sheet := site_style_sheet("")
	rules := site_control_rules()
	controls := site_controls
	testing.expect(t, len(controls) >= 10)
	for control in controls {
		rest := strings.concatenate({site_control_rest_selector(control), " {"}, context.temp_allocator)
		testing.expectf(t, strings.contains(sheet, rest), "%s: the style sheet has no rule of its look at rest, %q", control.name, rest)
		for state in ([]string{":hover", ":focus-visible", ":active"}) {
			wanted := strings.concatenate({control.selector, state}, context.temp_allocator)
			testing.expectf(t, strings.contains(rules, wanted), "%s: no rule of the state %s", control.name, state)
		}
		if control.current != "" {
			current := strings.concatenate({control.current, " {"}, context.temp_allocator)
			current_in_list := strings.concatenate({control.current, ","}, context.temp_allocator)
			testing.expectf(t, strings.contains(sheet, current) || strings.contains(sheet, current_in_list) || strings.contains(sheet, control.current), "%s: no rule of its current state", control.name)
		}
	}
	// A state changes a color only: no size, no border that appears, and
	// no change over time.
	for refused in ([]string{"transition", "animation", "padding", "margin", "font", "border:", "border-left:", "border-bottom:", "outline: none", "outline: 0", "transform"}) {
		testing.expectf(t, !strings.contains(rules, refused), "the rules of the states hold %q", refused)
	}
	home_rules := site_home_rules()
	for refused in ([]string{"transition", "animation", "border-radius", "outline: none", "outline: 0", "text-overflow", "overflow: hidden"}) {
		testing.expectf(t, !strings.contains(home_rules, refused), "the rules of the home hold %q", refused)
	}
	// The one transition of the site is the segment of the chart of the search.
	testing.expect_value(t, strings.count(sheet, "transition:"), 2)
	// The focus is the outline of the site, which no state removes.
	testing.expect(t, strings.contains(sheet, "a:focus-visible, button:focus-visible, summary:focus-visible, input:focus-visible, [tabindex]:focus-visible { outline: 2px solid var(--line); outline-offset: 2px; }"))
	// The states come after the rules of every control.
	testing.expect(t, strings.has_suffix(sheet, rules))
	// The variables are in both forms.
	testing.expect_value(t, strings.count(sheet, "--control-hover:"), 2)
	testing.expect_value(t, strings.count(sheet, "--control-active-text:"), 2)

	// The contrast of the text of each state, in both forms.
	for light in ([]bool{false, true}) {
		colors := site_control_colors(light)
		form := light ? site_light_colors() : site_dark_colors()
		Pair :: struct {
			what:        string,
			text, under: graphics.Color,
		}
		pairs := []Pair {
			{"a button at rest", form.text, form.track},
			{"a button under the pointer or with the focus", colors.hover_text, colors.hover},
			{"a button that is pressed or open, and a line of a menu under the pointer", colors.active_text, colors.active},
			{"a row under the pointer or pressed", form.text, form.track},
			{"a button of a current section", form.text, form.track},
		}
		for pair in pairs {
			ratio := site_contrast_ratio(pair.text, pair.under)
			testing.expectf(t, ratio >= 4.5, "%s (light form: %v): a contrast of %.2f", pair.what, light, ratio)
		}
	}
	testing.expect_value(t, u32(site_control_colors(false).hover) & 0xFFFFFF, 0x254A75)
}

// The cards of the stages: one card shows at a time, by rules with no
// weight whose order decides; a browser with no :has() shows every card.
// A form in an accent has the contrast of a graphic on each surface that
// holds it, in both forms.
@(test)
site_home_card_rules_and_graphic_colors :: proc(t: ^testing.T) {
	rules := site_boot_card_rules()
	testing.expect(t, strings.contains(rules, "@supports selector(:has(a)) {"))
	testing.expect(t, strings.contains(rules, "@supports not selector(:has(a)) {"))
	// One rule for each stage, and the rule that hides the hint.
	testing.expect_value(t, strings.count(rules, ":focus-within) .boot-card-"), SITE_BOOT_STAGE_RULE_COUNT + 1)
	testing.expect_value(t, strings.count(rules, ":hover) .boot-card-"), SITE_BOOT_STAGE_RULE_COUNT)
	// The order: the hint, the focus, the pointer on a row or a segment,
	// the pointer on a card.
	hint := strings.index(rules, ":where(.boot-card-hint) { visibility: visible; }")
	focus := strings.index(rules, ":where(.boot-timeline:has(.boot-stage-0:focus-within) .boot-card-0)")
	pointer := strings.index(rules, ":where(.boot-timeline:has(.boot-stage-row:hover, .boot-segment:hover) .boot-card) { visibility: hidden; }")
	card := strings.index(rules, ":where(.boot-cards:has(.boot-card:hover) .boot-card) { visibility: hidden; }")
	last := strings.index(rules, ":where(.boot-card:hover) { visibility: visible; }")
	testing.expectf(t, hint >= 0 && hint < focus && focus < pointer && pointer < card && card < last, "the order of the rules of the cards: %d %d %d %d %d", hint, focus, pointer, card, last)
	// A card is hidden, never removed: it keeps its room, so nothing moves.
	testing.expect(t, !strings.contains(rules, "display: none; }\n  :where"))
	testing.expect(t, strings.contains(rules, ".boot-card { grid-area: 1 / 1; margin-bottom: 0; }"))

	sheet := site_style_sheet("")
	testing.expect_value(t, strings.count(sheet, "--accent-graphic:"), 2 * len(site_accents))
	for light in ([]bool{false, true}) {
		form := light ? site_light_colors() : site_dark_colors()
		for accent in site_accents {
			color := site_accent_graphic_color(accent, light)
			for under in ([]graphics.Color{form.card_top, form.card_bottom, form.track}) {
				ratio := site_contrast_ratio(color, under)
				testing.expectf(t, ratio >= 3, "%s on %06x (light form: %v): a contrast of %.2f; a graphic needs 3", accent.class_name, u32(under) & 0xFFFFFF, light, ratio)
			}
		}
	}
}

// A press on the heron of the home: the page holds the box, the table of
// the script names the animation of the first press from src/library/support/mark,
// and the script makes the box a control only where it can play.
@(test)
site_home_heron_press :: proc(t: ^testing.T) {
	tile_maps, tile_maps_ok := site_mark_tile_maps()
	testing.expect(t, tile_maps_ok)
	if !tile_maps_ok {
		return
	}
	addresses := [SITE_MARK_SHEET_COUNT]string{"pictures/dark.png?v=1", "pictures/light.png?v=2", "pictures/icon.png?v=3"}
	script := site_mark_animation_script(&tile_maps, addresses)
	press_table := strings.concatenate({"\"press\":{\"first\":", fmt.tprintf("%d", int(mark.Animation.Dash)), "}"}, context.temp_allocator)
	testing.expect(t, strings.contains(script, press_table), "the table of the script does not name the animation of the first press")
	testing.expect_value(t, mark.animation_names[SITE_MARK_FIRST_PRESS_ANIMATION], "dash")
	parts := [?]string {
		"function pressAnimation(memory, below, first) {",
		"const wanted = TABLE.press.first;",
		"if (reduce.matches) return;",
		"if (current >= 0) return;",
		"box.setAttribute(\"role\", \"button\");",
		"box.setAttribute(\"tabindex\", \"0\");",
		"box.setAttribute(\"aria-label\", \"Play an animation of the heron\");",
		"box.removeAttribute(\"role\");",
		"box.addEventListener(\"click\", press);",
		"if (event.key !== \"Enter\" && event.key !== \" \") return;",
		"reduce.addEventListener(\"change\", fitControl);",
		"\"the first press plays the animation of the table\"",
		"\"no press plays the animation that was played before it\"",
	}
	for part in parts {
		testing.expectf(t, strings.contains(script, part), "the script of the mark has no %q", part)
	}
	for class in ([]string{SITE_MARK_BOX_CLASS, SITE_MARK_CONTROL_CLASS}) {
		testing.expectf(t, strings.contains(script, strings.concatenate({"\"", class, "\""}, context.temp_allocator)), "the script does not name the class %s", class)
	}
	// No number of the mark is typed in the script: the animation of the
	// first press is read from the table.
	testing.expect(t, !strings.contains(SITE_MARK_ANIMATION_SCRIPT_SOURCE, "\"dash\""))
	testing.expect(t, strings.contains(site_mark_animation_rules(), "." + SITE_MARK_CONTROL_CLASS + " { cursor: pointer; }"))

	site := test_site()
	head := strings.builder_make(context.temp_allocator)
	site_home_head(&site, &head)
	testing.expect(t, strings.contains(strings.to_string(head), "<header class=\"home-head\">\n<div class=\"" + SITE_MARK_BOX_CLASS + "\"><picture>"))
	testing.expect(t, strings.contains(strings.to_string(head), "\"></picture></div>\n<div>\n<h1>"))
}
