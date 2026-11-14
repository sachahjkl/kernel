// The sections of the home that show measures (docs/SITE.md, "The home";
// src/md/features/site_home.md): the line of time of the start of the
// machine, the charts of the measures, and the band of the newest release.
// Each one is drawn from a record of the repository, with no script: a
// width is a number of the record, and each number is also text.
package kerneltool

import "contract:value_kinds"
import "core:fmt"
import "core:strings"

// What the card of a stage of the start says: what the stage does, which
// code runs it, and the guide that explains it. The key is the name of the
// stage as the kernel logs it. Each sentence states a fact of the guide
// that the entry names, or of the source of the boot program and of the
// kernel; a stage with no entry has a card with its time and its line only.
Site_Boot_Stage_Text :: struct {
	stage:   string, // "boot program: load the kernel, the boot image"
	does:    string, // Two or three sentences. Markdown.
	runs:    string, // The code that runs the stage.
	guide:   string, // A document of docs/ that is a page of the site.
	heading: string, // A heading of that guide, or "".
}

site_boot_stage_texts := [?]Site_Boot_Stage_Text {
	{
		stage = "firmware",
		does = "The UEFI firmware of the machine runs before any code of the system. With Secure Boot on, it verifies the signature of the boot program before it starts it. The time is from the start of the machine to the first instruction of the boot program: the system does not decide it.",
		runs = "The UEFI firmware of the machine. It is not a part of the system.",
		guide = "docs/TRUSTED_BOOT.md",
		heading = "7. Secure Boot",
	},
	{
		stage = "boot program: load the kernel, the boot image",
		does = "The boot program verifies the signature of the system description, then compares the kernel module and each module and resource of the boot image with it. It asks the firmware to measure the description into the TPM, then loads the kernel module. A failed check stops the start here, with the file and the two hashes on the screen.",
		runs = "The boot program, a UEFI program.",
		guide = "docs/ARCHITECTURE.md",
		heading = "U1. Boot program",
	},
	{
		stage = "boot program: page tables, memory map, jump",
		does = "The boot program builds the page tables that the kernel starts on, reads the memory map of the firmware and leaves the firmware services. Then it starts the entry of the kernel, with one record that holds the memory map, the framebuffer, the boot image and the trust record.",
		runs = "The boot program, a UEFI program.",
		guide = "docs/ARCHITECTURE.md",
		heading = "U1. Boot program",
	},
	{
		stage = "kernel: page frames, kernel page table",
		does = "The kernel takes the free page frames of the memory map and builds its own page table. From here the memory of the boot program is not kept.",
		runs = "The kernel, on the first processor.",
		guide = "docs/ARCHITECTURE.md",
		heading = "K2. Memory",
	},
	{
		stage = "kernel: first processor, timer",
		does = "The kernel starts the processor that it runs on: it writes its own control registers and keeps no bit that the firmware set. It measures the timer of the processor, which gives the frequency of the cycle counter that times each stage.",
		runs = "The kernel, on the first processor.",
		guide = "docs/ARCHITECTURE.md",
		heading = "The control registers of a processor",
	},
	{
		stage = "kernel: other processors",
		does = "The kernel chooses the strategy of each run queue, then starts each other processor of the machine. Each one writes the same control registers as the first.",
		runs = "The kernel, on each processor.",
		guide = "docs/ARCHITECTURE.md",
		heading = "K3. Scheduler",
	},
	{
		stage = "kernel: root service",
		does = "The kernel builds the root service from the module `root` of the boot image and gives it every handle that exists at the start. The root service is the first program: it starts each other program with the grants of its role.",
		runs = "The kernel, then the root service.",
		guide = "docs/ARCHITECTURE.md",
		heading = "U2. Root service",
	},
}

// The stages that the style sheet has rules for: a rule shows the card of
// a stage by the place of the stage. The kernel logs seven stages; a
// stage after this count has its row and its card in a browser that shows
// every card, and no card under the pointer.
SITE_BOOT_STAGE_RULE_COUNT :: 12
// The first bar of the line of time is cut in this many parts: a width is
// written in hundredths of a percent, so a stage of one part in ten
// thousand of the start still has a width.
SITE_BOOT_WHOLE_PARTS :: 10000
// The least share of a stage in the second bar, in thousandths of the bar:
// 2 percent, about 6 pixels on a phone. The page says so under the bar.
SITE_BOOT_SYSTEM_LEAST_SHARE :: 20
// The width of a character of a label, in pixels, for the count of the
// room of a label: wider than the mean character of the common fonts.
SITE_BOOT_CHARACTER_WIDTH :: 9
// The most characters of the time of a stage, as "1516.6 ms".
SITE_BOOT_TIME_CHARACTERS :: 9

// site_boot_stage_name gives the name of a stage as the kernel logs it.
site_boot_stage_name :: proc(stage: Site_Boot_Stage) -> string {
	if stage.what == "" {
		return stage.who
	}
	return strings.concatenate({stage.who, ": ", stage.what}, context.temp_allocator)
}

// site_boot_stage_text gives the text of the card of a stage, by its name.
site_boot_stage_text :: proc(name: string) -> (text: Site_Boot_Stage_Text, found: bool) {
	texts := site_boot_stage_texts
	for candidate in texts {
		if candidate.stage == name {
			return candidate, true
		}
	}
	return {}, false
}

// site_milliseconds_text gives a time in microseconds as milliseconds with
// one digit after the point: "72.6 ms".
site_milliseconds_text :: proc(microseconds: int) -> string {
	return fmt.tprintf("%d.%d ms", microseconds / 1000, microseconds % 1000 / 100)
}

// site_boot_whole_segments gives the segment of each stage in the first
// bar, in parts of SITE_BOOT_WHOLE_PARTS: one scale from the start of the
// machine to the end of the last stage, with no least width. The last
// segment takes what the rounding left, so the segments fill the bar.
site_boot_whole_segments :: proc(stages: []Site_Boot_Stage) -> []Site_Search_Chart_Segment {
	segments := make([]Site_Search_Chart_Segment, len(stages), context.temp_allocator)
	total := 0
	for stage in stages {
		total += stage.microseconds
	}
	if total == 0 {
		return segments
	}
	start := 0
	for stage, index in stages {
		segments[index].start = start
		segments[index].width = stage.microseconds * SITE_BOOT_WHOLE_PARTS / total
		start += segments[index].width
	}
	segments[len(segments) - 1].width += SITE_BOOT_WHOLE_PARTS - start
	return segments
}

// site_boot_system_segments gives the segment of each stage after the
// first one in the second bar, in thousandths of the bar: the same times
// on a larger scale, each stage with a least share.
site_boot_system_segments :: proc(stages: []Site_Boot_Stage) -> []Site_Search_Chart_Segment {
	if len(stages) < 2 {
		return nil
	}
	counts := make([]int, len(stages) - 1, context.temp_allocator)
	for stage, index in stages[1:] {
		counts[index] = stage.microseconds
	}
	return site_share_segments(counts, SITE_BOOT_SYSTEM_LEAST_SHARE)
}

// site_boot_parts_percent gives a count of parts of SITE_BOOT_WHOLE_PARTS
// as the attribute of an SVG rectangle: "91.27%".
site_boot_parts_percent :: proc(parts: int) -> string {
	return fmt.tprintf("%d.%02d%%", parts / 100, parts % 100)
}

// site_boot_name_box_width gives the room of the name of a stage in its
// row, in pixels, for a width of the window: the column of the page, less
// the padding and the border of the card, the half of it from 900 pixels
// (the cards of the stages take the other half), less the padding of the
// row, its square, its gaps and its time.
site_boot_name_box_width :: proc(window_width: int) -> int {
	page := min(window_width, 1152) - 32
	inside_card := page - 34
	column := window_width >= 900 ? (inside_card - 16) / 2 : inside_card
	return column - 16 - 12 - 16 - SITE_BOOT_TIME_CHARACTERS * SITE_BOOT_CHARACTER_WIDTH
}

// site_home_guide_link writes a link to a heading of a guide, with the
// title of the guide and the words of the heading as its text. It writes
// nothing when the guide is not a page of the site.
site_home_guide_link :: proc(site: ^Site, b: ^strings.Builder, from_page, document, heading: string) -> bool {
	page, is_page := site.documents[document]
	if !is_page {
		return false
	}
	title := ""
	anchor := ""
	for guide in site.guides {
		if guide.source != document {
			continue
		}
		title = guide.title
		for candidate in guide.headings {
			if heading != "" && candidate.text == heading {
				anchor = candidate.id
			}
		}
	}
	if title == "" {
		return false
	}
	strings.write_string(b, "<a href=\"")
	site_escape(b, site_page_link(site, from_page, page))
	if anchor != "" {
		strings.write_string(b, "#")
		site_escape(b, anchor)
	}
	strings.write_string(b, "\">")
	site_escape(b, title)
	if anchor != "" {
		strings.write_string(b, ": ")
		site_escape(b, heading)
	}
	strings.write_string(b, "</a>")
	return true
}

// site_boot_timeline_write writes the line of time of the start: two bars,
// then one row for each stage with its name and its time, then the card of
// each stage. The first bar is the whole start on one scale. The second is
// the stages after the first one on a larger scale: the firmware takes most
// of the start, so on one scale the stages of the system are too thin to
// see. Two lines at an angle say which part of the first bar the second
// one enlarges, and a sentence under each bar states its scale.
site_boot_timeline_write :: proc(site: ^Site, b: ^strings.Builder, from_page: string) {
	stages := site.boot_stages
	strings.write_string(b, "<section class=\"card accent-kernel boot-timeline\" aria-labelledby=\"start\">\n<h2 id=\"start\">The start of the machine</h2>\n")
	total := 0
	for stage in stages {
		total += stage.microseconds
	}
	if len(stages) == 0 || total == 0 {
		strings.write_string(b, "<p class=\"missing\">" + SITE_NOT_MEASURED + "</p>\n</section>\n")
		return
	}
	strings.write_string(b, "<p class=\"boot-scale\">From the start of the machine to the first program: ")
	site_value(b, .Time, site_milliseconds_text(total), false)
	strings.write_string(b, ". One scale: a width is a time.</p>\n<svg class=\"boot-bar boot-bar-whole\" aria-hidden=\"true\">")
	whole := site_boot_whole_segments(stages)
	for stage, index in stages {
		fmt.sbprintf(b, "<rect class=\"boot-segment boot-segment-%d %s\" x=\"%s\" width=\"%s\" height=\"100%%\"/>", index, site_who_class(stage.who), site_boot_parts_percent(whole[index].start), site_boot_parts_percent(whole[index].width))
	}
	strings.write_string(b, "</svg>\n")
	system := site_boot_system_segments(stages)
	after_first := total - stages[0].microseconds
	if len(system) > 0 && after_first > 0 {
		// Where the second bar starts in the first one.
		fmt.sbprintf(b, "<svg class=\"boot-enlarged\" aria-hidden=\"true\"><line x1=\"%s\" y1=\"0\" x2=\"0\" y2=\"100%%\"/><line x1=\"100%%\" y1=\"0\" x2=\"100%%\" y2=\"100%%\"/></svg>\n", site_boot_parts_percent(whole[0].width))
		strings.write_string(b, "<svg class=\"boot-bar boot-bar-system\" aria-hidden=\"true\">")
		for stage, index in stages[1:] {
			fmt.sbprintf(b, "<rect class=\"boot-segment boot-segment-%d %s\" x=\"%s\" width=\"%s\" height=\"100%%\"/>", index + 1, site_who_class(stage.who), site_search_chart_percent(system[index].start), site_search_chart_percent(system[index].width))
		}
		strings.write_string(b, "</svg>\n<p class=\"boot-scale\">The ")
		site_value(b, .Time, site_milliseconds_text(after_first), false)
		strings.write_string(b, " after the ")
		site_escape(b, stages[0].who)
		enlarged := total * 10 / after_first
		fmt.sbprintf(b, ", %d.%d times wider. A stage is at least %d %% of this bar wide, so that each one shows.</p>\n", enlarged / 10, enlarged % 10, SITE_BOOT_SYSTEM_LEAST_SHARE / 10)
	}

	// The rows: the name and the time of each stage, readable with no
	// pointer.
	strings.write_string(b, "<div class=\"boot-parts\">\n<ol class=\"boot-stages\">\n")
	for stage, index in stages {
		fmt.sbprintf(b, "<li class=\"boot-stage boot-stage-%d %s\"><div class=\"boot-stage-row\" tabindex=\"0\" aria-describedby=\"boot-card-%d\"><span class=\"boot-stage-square\" aria-hidden=\"true\"></span><span class=\"boot-stage-name\"><span class=\"boot-stage-who\">", index, site_who_class(stage.who), index)
		site_escape(b, stage.who)
		strings.write_string(b, "</span>")
		if stage.what != "" {
			strings.write_string(b, " ")
			site_escape(b, stage.what)
		}
		strings.write_string(b, "</span>")
		fmt.sbprintf(b, "<code class=\"value value-%s boot-stage-time\">", value_kinds.VALUE_KIND_NAMES[value_kinds.Value_Kind.Time])
		site_escape(b, site_milliseconds_text(stage.microseconds))
		strings.write_string(b, "</code></div></li>\n")
	}
	strings.write_string(b, "</ol>\n<div class=\"boot-cards\">\n")

	// The card that shows while no stage is chosen: how to choose one, and
	// where the times come from.
	strings.write_string(b, "<div class=\"boot-card boot-card-hint\">\n<p class=\"boot-hint-words\">Point at a stage, or give it the focus, to read what it does.</p>\n<p class=\"source\">Each time is one line <code>kernel: boot: ...</code> of the log of the main machine test: one run, under QEMU. ")
	site_inline(b, site_origin_words(site.boot_source, site.measure_record))
	numbers_page := site_page_file(SITE_NUMBERS_FOLDER)
	if site_page_exists(site, numbers_page) {
		fmt.sbprintf(b, ". <a href=\"%s\">The run of the measures</a>", site_page_link(site, from_page, numbers_page))
	}
	strings.write_string(b, ".</p>\n</div>\n")
	for stage, index in stages {
		name := site_boot_stage_name(stage)
		fmt.sbprintf(b, "<div class=\"boot-card boot-card-%d %s\" id=\"boot-card-%d\">\n<p class=\"boot-card-title\"><strong>", index, site_who_class(stage.who), index)
		site_escape(b, name)
		strings.write_string(b, "</strong> ")
		site_value(b, .Time, site_milliseconds_text(stage.microseconds), false)
		strings.write_string(b, "</p>\n")
		text, has_text := site_boot_stage_text(name)
		if has_text {
			strings.write_string(b, "<p>")
			site_inline(b, text.does)
			strings.write_string(b, "</p>\n")
		}
		strings.write_string(b, "<dl class=\"symbol-facts\">\n")
		if has_text {
			strings.write_string(b, "<dt>Runs it</dt><dd>")
			site_inline(b, text.runs)
			strings.write_string(b, "</dd>\n")
		}
		strings.write_string(b, "<dt>Measured from</dt><dd><code>" + SITE_BOOT_STAGE_PREFIX)
		site_escape(b, name)
		fmt.sbprintf(b, ": %d us</code></dd>\n", stage.microseconds)
		if has_text {
			link := strings.builder_make(context.temp_allocator)
			if site_home_guide_link(site, &link, from_page, text.guide, text.heading) {
				strings.write_string(b, "<dt>Guide</dt><dd>")
				strings.write_string(b, strings.to_string(link))
				strings.write_string(b, "</dd>\n")
			}
		}
		strings.write_string(b, "</dl>\n</div>\n")
	}
	strings.write_string(b, "</div>\n</div>\n</section>\n")
}

// One bar of a chart of a measure: its label, and the words of the line of
// the log that come just before its number.
Site_Chart_Bar :: struct {
	label:  string,
	before: string,
}

SITE_CHART_BAR_LIMIT :: 5

// One chart of the home: the numbers of one line of the log that have one
// unit, as bars on one scale from zero. A chart is drawn only when the
// line holds each of its numbers; the home shows no measure in another
// form (the rule "a chart or nothing"). Each other measure is a row of the
// page of the measured numbers.
Site_Measure_Chart :: struct {
	pattern:    string, // The pattern of its measure in site_measures.
	title:      string,
	unit:       string, // The one unit of its bars, in words.
	unit_after: string, // The text that follows each number in the line, or "": the unit as the log writes it.
	kind:       value_kinds.Value_Kind, // The value kind of its numbers.
	about:      string, // One or two sentences. Markdown.
	bars:       [SITE_CHART_BAR_LIMIT]Site_Chart_Bar, // A bar with no label is no bar.
}

site_measure_charts := [?]Site_Measure_Chart {
	{
		pattern = "locks: kernel entries in one second",
		title = "Kernel entries in one second, by the count of programs",
		unit = "kernel entries in one second",
		kind = .Number,
		about = "Each program enters the kernel again and again and takes only the locks of its own objects. A count that grows with the programs shows that the kernel serves several processors at once.",
		bars = {{"1 program", "1 locker "}, {"2 programs", "2 lockers "}, {"4 programs", "4 lockers "}, {}, {}},
	},
	{
		pattern = "vector_glyphs: one glyph from its outline",
		title = "The time to draw one glyph",
		unit = "nanoseconds",
		unit_after = " ns",
		kind = .Time,
		about = "A glyph of the vector font drawn from its outline at three scales, the same glyph copied from the glyph cache, and a glyph of the bitmap font. The difference is the work that the glyph cache saves each program.",
		bars = {{"Outline, scale 1", "scale 1 "}, {"Outline, scale 2", "scale 2 "}, {"Outline, scale 3", "scale 3 "}, {"Glyph cache", "from the glyph cache: "}, {"Bitmap font", "Spleen 8x16: "}},
	},
}

// site_chart_values reads the number of each bar of a chart from the line
// of the log. It fails when a number is absent or is not followed by the
// unit of the chart: a chart never shows a part of its bars, and never a
// number of another unit.
site_chart_values :: proc(chart: Site_Measure_Chart, line: string) -> (values: [SITE_CHART_BAR_LIMIT]int, count: int, ok: bool) {
	for bar in chart.bars {
		if bar.label == "" {
			continue
		}
		place := strings.index(line, bar.before)
		if place < 0 {
			return values, 0, false
		}
		rest := line[place + len(bar.before):]
		digits := 0
		for digits < len(rest) && rest[digits] >= '0' && rest[digits] <= '9' {
			digits += 1
		}
		value := site_digits_value(rest[:digits])
		if value < 0 || !strings.has_prefix(rest[digits:], chart.unit_after) {
			return values, 0, false
		}
		values[count] = value
		count += 1
	}
	return values, count, count > 0
}

// site_grouped_number gives a whole number with a space between each
// group of three digits: "4 487 253".
site_grouped_number :: proc(value: int) -> string {
	digits := fmt.tprintf("%d", value)
	b := strings.builder_make(context.temp_allocator)
	for index in 0 ..< len(digits) {
		if index > 0 && (len(digits) - index) % 3 == 0 {
			strings.write_byte(&b, ' ')
		}
		strings.write_byte(&b, digits[index])
	}
	return strings.to_string(b)
}

// The least width of a bar of a number above zero, in thousandths of the
// longest bar: a small number still shows a mark.
SITE_CHART_BAR_LEAST :: 4

// site_chart_bar_width gives the width of a bar in thousandths of the
// longest bar of its chart: from zero, in proportion.
site_chart_bar_width :: proc(value, most: int) -> int {
	if value <= 0 || most <= 0 {
		return 0
	}
	return max(SITE_CHART_BAR_LEAST, value * 1000 / most)
}

// site_measure_charts_write writes the charts of the measures that the
// build has. It writes nothing, not a heading, when no chart can be drawn.
site_measure_charts_write :: proc(site: ^Site, b: ^strings.Builder, from_page: string) {
	charts := site_measure_charts
	drawn := 0
	numbers_page := site_page_file(SITE_NUMBERS_FOLDER)
	for chart in charts {
		for number in site.measured {
			if !number.found || number.measure.pattern != chart.pattern {
				continue
			}
			values, count, ok := site_chart_values(chart, number.text)
			if !ok {
				continue
			}
			if drawn == 0 {
				strings.write_string(b, "<section aria-labelledby=\"numbers\">\n<h2 id=\"numbers\">Measured</h2>\n<div class=\"measure-charts\">\n")
			}
			drawn += 1
			most := 0
			for value in values[:count] {
				most = max(most, value)
			}
			fmt.sbprintf(b, "<article class=\"card measure-chart %s\">\n<h3>", site_accent_class(number.measure.accent))
			site_escape(b, chart.title)
			strings.write_string(b, "</h3>\n<ul class=\"measure-bars\">\n")
			shown := 0
			for bar in chart.bars {
				if bar.label == "" {
					continue
				}
				strings.write_string(b, "<li class=\"measure-row\"><span class=\"measure-label\">")
				site_escape(b, bar.label)
				fmt.sbprintf(b, "</span><svg class=\"measure-bar\" aria-hidden=\"true\"><rect class=\"measure-bar-fill\" width=\"%s\" height=\"100%%\"/></svg>", site_search_chart_percent(site_chart_bar_width(values[shown], most)))
				fmt.sbprintf(b, "<code class=\"value value-%s measure-value\">", value_kinds.VALUE_KIND_NAMES[chart.kind])
				site_escape(b, site_grouped_number(values[shown]))
				strings.write_string(b, "</code></li>\n")
				shown += 1
			}
			strings.write_string(b, "</ul>\n<p class=\"measure-unit\">In ")
			site_escape(b, chart.unit)
			strings.write_string(b, ". Each bar starts at zero.</p>\n<p>")
			site_inline(b, chart.about)
			if site_page_exists(site, numbers_page) {
				fmt.sbprintf(b, " <a href=\"%s#number-%s\">The line of the log, and how to read it</a>", site_page_link(site, from_page, numbers_page), site_slug(number.measure.sentence))
			}
			strings.write_string(b, "</p>\n</article>\n")
			break
		}
	}
	if drawn == 0 {
		return
	}
	strings.write_string(b, "</div>\n")
	if site_page_exists(site, numbers_page) {
		fmt.sbprintf(b, "<p><a href=\"%s\">Every measured number, with its log and its conditions</a></p>\n", site_page_link(site, from_page, numbers_page))
	}
	strings.write_string(b, "</section>\n")
}

// The count of the changes that the band of the newest release names.
SITE_RELEASE_BAND_CHANGE_COUNT :: 4

// site_change_summary gives the bold summary at the start of a change of
// the changelog, with no mark; a change with none gives its first sentence.
site_change_summary :: proc(entry: Changelog_Entry) -> string {
	text := strings.trim_space(entry_joined(entry.lines))
	if strings.has_prefix(text, "**") {
		if end := strings.index(text[2:], "**"); end > 0 {
			return strings.trim_right(text[2:2 + end], ".:")
		}
	}
	return site_first_sentence(text)
}

// site_change_id gives the id of a change on the page of the releases: the
// id of its release, and its place in the release, from 1.
site_change_id :: proc(release_number: string, place: int) -> string {
	return fmt.tprintf("%s-change-%d", site_release_id(release_number), place)
}

// site_release_band_write writes the band of the newest release: its
// number as the one large value of the band, its date, the count of its
// changes and of the steps, then its first changes by their summaries,
// each a link to the change on the page of the releases.
site_release_band_write :: proc(site: ^Site, b: ^strings.Builder, from_page: string) {
	if len(site.changelog.releases) == 0 {
		return
	}
	newest := site.changelog.releases[0]
	releases_link := site_page_link(site, from_page, site_section_page(.Releases))
	types := CHANGE_TYPES
	strings.write_string(b, "<section class=\"card accent-boot release-band\" aria-labelledby=\"release\">\n<h2 id=\"release\">The newest release</h2>\n<p class=\"release-head\">")
	fmt.sbprintf(b, "<span class=\"value value-%s release-number\">", value_kinds.VALUE_KIND_NAMES[value_kinds.Value_Kind.Version])
	site_escape(b, site.release)
	fmt.sbprintf(b, "</span> <span class=\"release-facts\"><time datetime=\"%s\">%s</time>, <strong>%d</strong> changes, <strong>%d</strong> steps so far: each step is one tested commit on <code>master</code></span></p>\n", newest.date, newest.date, len(newest.entries), site.step_count)
	shown := min(len(newest.entries), SITE_RELEASE_BAND_CHANGE_COUNT)
	if shown > 0 {
		strings.write_string(b, "<ul class=\"release-changes\">\n")
		for entry, index in newest.entries[:shown] {
			fmt.sbprintf(b, "<li><span class=\"release-change-type\">%s</span> <a href=\"%s#%s\">", types[entry.type_index], releases_link, site_change_id(site.release, index + 1))
			site_inline(b, site_change_summary(entry))
			strings.write_string(b, "</a></li>\n")
		}
		strings.write_string(b, "</ul>\n")
	}
	strings.write_string(b, "<p class=\"release-more\">")
	if len(newest.entries) > shown {
		fmt.sbprintf(b, "And <strong>%d</strong> more changes in this release. ", len(newest.entries) - shown)
	}
	fmt.sbprintf(b, "<a href=\"%s\">All %d releases</a></p>\n", releases_link, len(site.changelog.releases))
	// One line, not a section: the home shows what runs.
	site_roadmap_link_line(site, b, from_page)
	strings.write_string(b, "</section>\n")
}

// The rules of the sections of this file. A bar and a segment are SVG
// rectangles: their places and their widths are attributes, because a page
// holds no style attribute. A form in an accent takes the color of the
// accent for a form (--accent-graphic), which is darker on the light page.
SITE_HOME_RULES :: `
/* The line of time of the start: two bars, the rows of the stages, the
   cards of the stages. */
.boot-scale { margin: 0 0 8px; color: var(--dim); font-size: 14px; line-height: 20px; }
.boot-scale .value { padding: 0; border-left: 0; }
.boot-bar { display: block; width: 100%; height: 24px; background: var(--track); }
.boot-segment { fill: var(--accent-graphic); }
.boot-bar-system { margin-bottom: 8px; }
.boot-bar-system .boot-segment { stroke: var(--card-top); stroke-width: 1px; }
.boot-enlarged { display: block; width: 100%; height: 16px; }
.boot-enlarged line { stroke: var(--dim); stroke-width: 1px; }
.boot-parts { display: grid; grid-template-columns: minmax(0, 1fr); gap: 16px; align-items: start; margin-top: 16px; }
@media (min-width: 900px) {
  .boot-parts { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}
.boot-stages { list-style: none; margin: 0; padding: 0; }
.boot-stage { margin: 0; }
.boot-stage-row { display: grid; grid-template-columns: 12px minmax(0, 1fr) max-content; gap: 0 8px; align-items: start; padding: 2px 8px 2px 6px; border-left: 2px solid transparent; line-height: 24px; }
.boot-stage-square { width: 12px; height: 12px; margin-top: 6px; background: var(--accent-graphic); }
.boot-stage-name { min-width: 0; overflow-wrap: anywhere; }
.boot-stage-who { color: var(--dim); }
.boot-stage-row .boot-stage-time { padding: 0; border-left: 0; white-space: nowrap; text-align: right; font-variant-numeric: tabular-nums; }
.boot-cards { min-width: 0; }
.boot-card { min-width: 0; margin-bottom: 8px; padding: 8px 16px; border: 1px solid var(--track); border-left: 2px solid var(--accent-graphic); font-size: 14px; line-height: 20px; overflow-wrap: anywhere; }
.boot-card p { margin: 0 0 8px; }
.boot-card-title { font-size: 16px; line-height: 24px; }
.boot-card-title .value { padding: 0; border-left: 0; margin-left: 8px; }
.boot-card .symbol-facts { margin: 0; }
/* The charts of the measures: one card for each chart, a row for each
   bar: its label, its bar from zero, its number. */
.measure-charts { display: grid; grid-template-columns: minmax(0, 1fr); gap: 8px; align-items: start; margin-bottom: 16px; }
@media (min-width: 900px) {
  .measure-charts { grid-template-columns: repeat(2, minmax(0, 1fr)); }
}
.card.measure-chart { margin-bottom: 0; }
.card.measure-chart h3 { text-transform: none; font-family: var(--reading); }
.measure-bars { list-style: none; margin: 0 0 8px; padding: 0; }
.measure-row { display: grid; grid-template-columns: minmax(0, 9em) minmax(0, 1fr) max-content; gap: 0 12px; align-items: center; margin: 0; padding: 2px 0; font-size: 14px; line-height: 20px; }
.measure-label { min-width: 0; overflow-wrap: anywhere; }
.measure-bar { display: block; width: 100%; height: 12px; background: var(--track); }
.measure-bar-fill { fill: var(--accent-graphic); }
.measure-row .measure-value { min-width: 9ch; padding: 0; border-left: 0; white-space: nowrap; text-align: right; font-variant-numeric: tabular-nums; }
.measure-unit { color: var(--dim); font-size: 14px; line-height: 20px; }
@media (max-width: 719px) {
  .measure-row { grid-template-columns: minmax(0, 1fr) max-content; }
  .measure-bar { grid-column: 1 / -1; grid-row: 2; }
}
/* The band of the newest release: its number is the one large value. */
.release-head { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 16px; margin: 0 0 8px; }
.release-number { font-size: 32px; line-height: 40px; font-weight: 700; }
.release-facts { color: var(--dim); }
.release-facts strong, .release-facts time, .release-more strong { color: var(--text); font-family: var(--mono); font-size: 14px; }
.release-changes { list-style: none; margin: 0 0 8px; padding: 0; }
.release-changes li { margin: 0; padding: 2px 0; overflow-wrap: anywhere; }
.release-changes a { font-weight: 700; }
.release-change-type { display: inline-block; min-width: 9ch; color: var(--dim); font-family: var(--mono); font-size: 12px; text-transform: uppercase; }
.release-more { color: var(--dim); }
`

// site_boot_card_rules gives the rules that show one card of a stage at a
// time, in the place of the cards, with no script. Every card is in one
// cell of a grid, so the cell has the height of the tallest card and
// nothing under it moves when the card changes. A card is hidden, not
// removed: it keeps its room. Each rule is inside :where(), which has no
// weight: the order of the rules alone decides, so exactly one card shows.
// The order: the card of the hint; the stage that has the focus; the stage
// or the segment under the pointer; a card under the pointer, so that the
// pointer can go from a row to the link of its card. A browser with no
// :has() shows every card, one under the other.
site_boot_card_rules :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	write :: proc(b: ^strings.Builder, parts: ..string) {
		for part in parts {
			strings.write_string(b, part)
		}
	}
	write(&b, "@supports not selector(:has(a)) {\n  .boot-hint-words { display: none; }\n}\n")
	write(&b, "@supports selector(:has(a)) {\n")
	write(&b, "  .boot-cards { display: grid; }\n")
	write(&b, "  .boot-card { grid-area: 1 / 1; margin-bottom: 0; }\n")
	write(&b, "  :where(.boot-card) { visibility: hidden; }\n")
	write(&b, "  :where(.boot-card-hint) { visibility: visible; }\n")
	write(&b, "  :where(.boot-timeline:has(.boot-stage:focus-within) .boot-card-hint) { visibility: hidden; }\n")
	for index in 0 ..< SITE_BOOT_STAGE_RULE_COUNT {
		number := fmt.tprintf("%d", index)
		write(&b, "  :where(.boot-timeline:has(.boot-stage-", number, ":focus-within) .boot-card-", number, ") { visibility: visible; }\n")
	}
	write(&b, "  :where(.boot-timeline:has(.boot-stage-row:hover, .boot-segment:hover) .boot-card) { visibility: hidden; }\n")
	for index in 0 ..< SITE_BOOT_STAGE_RULE_COUNT {
		number := fmt.tprintf("%d", index)
		write(&b, "  :where(.boot-timeline:has(.boot-stage-", number, " > .boot-stage-row:hover, .boot-segment-", number, ":hover) .boot-card-", number, ") { visibility: visible; }\n")
	}
	write(&b, "  :where(.boot-cards:has(.boot-card:hover) .boot-card) { visibility: hidden; }\n")
	write(&b, "  :where(.boot-card:hover) { visibility: visible; }\n")
	// The segment of the stage that a row names, and the row of the stage
	// that a segment names: a line around the segment, the band of a row.
	for index in 0 ..< SITE_BOOT_STAGE_RULE_COUNT {
		number := fmt.tprintf("%d", index)
		write(&b, "  .boot-timeline:has(.boot-stage-", number, ":hover, .boot-stage-", number, ":focus-within) .boot-segment-", number, ", .boot-segment-", number, ":hover { stroke: var(--text); stroke-width: 2px; }\n")
		write(&b, "  .boot-timeline:has(.boot-segment-", number, ":hover) .boot-stage-", number, " > .boot-stage-row { background: var(--track); border-left-color: var(--line); }\n")
	}
	write(&b, "}\n")
	return strings.to_string(b)
}

// site_home_rules gives the rules of the sections of the home.
site_home_rules :: proc() -> string {
	return strings.concatenate({SITE_HOME_RULES, site_boot_card_rules()}, context.temp_allocator)
}
