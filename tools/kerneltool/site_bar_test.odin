package kerneltool

import "core:fmt"
import "core:strings"
import "core:testing"
import "support:mark"

// A site with a page for the home and for each section that the test names.
@(private = "file")
bar_test_site :: proc(sections: []Site_Section) -> Site {
	site: Site
	site.pages = make([dynamic]Site_Page, context.temp_allocator)
	append(&site.pages, Site_Page{path = site_section_page(.Home), title = "Home", section = .Home})
	for section in sections {
		append(&site.pages, Site_Page{path = site_section_page(section), title = site_section_titles[section], section = section})
	}
	return site
}

@(private = "file")
bar_test_page :: proc(section: Site_Section) -> Site_Page {
	return Site_Page{path = site_section_page(section), title = site_section_titles[section], section = section}
}

@(private = "file")
bar_test_all_sections := [?]Site_Section{.Docs, .Guides, .Reference, .Status, .News, .Releases, .Roadmap, .Gallery}

// Each section under the home is in the bar one time: as a button, or as a
// line of the menu. The other sections are in neither. The count of the
// buttons is what the width of the bar was computed with.
@(test)
site_bar_names_each_section_under_the_home_one_time :: proc(t: ^testing.T) {
	for section in Site_Section {
		is_button := site_section_is_bar_button(section)
		in_group := site_section_in_project_menu(section)
		testing.expectf(t, !(is_button && in_group), "%v is a button and a line of the menu", section)
		testing.expectf(t, (is_button || in_group) == site_section_under_home(section), "%v: under the home %v, a button %v, in the menu %v", section, site_section_under_home(section), is_button, in_group)
		testing.expect_value(t, site_section_in_bar(section), is_button || in_group)
	}
	testing.expect_value(t, len(site_bar_buttons), 3)
	testing.expect_value(t, len(site_project_menu_sections), 3)
	// The pictures are one click away, and the roadmap is in the menu
	// beside the releases.
	testing.expect(t, site_section_is_bar_button(.Docs) && site_section_is_bar_button(.Gallery) && site_section_is_bar_button(.News))
	testing.expect(t, site_section_in_project_menu(.Status) && site_section_in_project_menu(.Releases) && site_section_in_project_menu(.Roadmap))
}

// The navigation of the bar on a page of a section that is a button: the
// whole text, so that each part of its form is stated one time.
@(test)
site_bar_on_a_page_of_a_button :: proc(t: ^testing.T) {
	site := bar_test_site(bar_test_all_sections[:])
	html := site_bar_sections_html(&site, bar_test_page(.Gallery))
	expected := "<nav class=\"bar-sections\" aria-label=\"Sections\">\n<ul>\n" +
		"<li><a href=\"../docs/index.html\">Docs</a></li>\n" +
		"<li><a href=\"../gallery/index.html\" aria-current=\"page\">Gallery</a></li>\n" +
		"<li><a href=\"../news/index.html\">News</a></li>\n" +
		"<li><details class=\"project-menu\">\n<summary class=\"project-menu-button\">Project</summary>\n<div class=\"project-menu-panel\">\n" +
		"<a href=\"../status/index.html\">Status</a>\n" +
		"<a href=\"../releases/index.html\">Releases</a>\n" +
		"<a href=\"../roadmap/index.html\">Roadmap</a>\n" +
		"</div>\n</details></li>\n</ul>\n</nav>\n"
	testing.expect_value(t, html, expected)
}

// The current mark on a page of each section: one link is marked, the
// link of the section of the bar that holds the page; the button of the
// menu is marked when that section is a line of the menu, and only then.
@(test)
site_bar_marks_the_current_section :: proc(t: ^testing.T) {
	site := bar_test_site(bar_test_all_sections[:])
	for section in Site_Section {
		html := site_bar_sections_html(&site, bar_test_page(section))
		bar_section := site_bar_section(section)
		// The menu works with no script: a details element, closed in
		// the file, and its summary is its button.
		testing.expect_value(t, strings.count(html, "<details"), 1)
		testing.expect_value(t, strings.count(html, "<summary class=\"project-menu-button\">" + SITE_PROJECT_MENU_NAME + "</summary>"), 1)
		testing.expectf(t, !strings.contains(html, "<details open") && !strings.contains(html, " open>"), "%v: the menu is open in the file", section)
		// One list: the panel of the menu is not a list under an item.
		testing.expect_value(t, strings.count(html, "<ul"), 1)
		// Each section under the home one time: this list is also the
		// list of the site menu under 720 pixels, which names them all.
		for named in Site_Section {
			wanted := strings.concatenate({">", site_section_titles[named], "</a>"}, context.temp_allocator)
			testing.expectf(t, strings.count(html, wanted) == (site_section_under_home(named) ? 1 : 0), "on a page of %v: %v is in the bar %d times", section, named, strings.count(html, wanted))
		}
		if section == .Home {
			testing.expect_value(t, strings.count(html, "aria-current"), 0)
			testing.expect(t, !strings.contains(html, "project-menu-current"))
			continue
		}
		testing.expect_value(t, strings.count(html, "aria-current=\"page\""), 1)
		marked := strings.concatenate({" aria-current=\"page\">", site_section_titles[bar_section], "</a>"}, context.temp_allocator)
		testing.expectf(t, strings.contains(html, marked), "on a page of %v: the link of %v is not marked", section, bar_section)
		testing.expectf(t, strings.contains(html, SITE_PROJECT_MENU_OPEN_CURRENT) == site_section_in_project_menu(bar_section), "on a page of %v: the mark of the button of the menu", section)
		if site_section_in_project_menu(bar_section) {
			// The marked link is in the panel, after the button.
			testing.expect(t, strings.index(html, marked) > strings.index(html, "<div class=\"project-menu-panel\">"))
		}
	}
	// A guide is a page of the docs: the button Docs is marked.
	guide := site_bar_sections_html(&site, bar_test_page(.Guides))
	testing.expect(t, strings.contains(guide, " aria-current=\"page\">Docs</a>"))
}

// A section appears when its page exists; the menu appears when one of
// its sections does.
@(test)
site_bar_names_only_the_pages_that_exist :: proc(t: ^testing.T) {
	buttons_only := bar_test_site({.Docs, .News})
	html := site_bar_sections_html(&buttons_only, bar_test_page(.Docs))
	testing.expect(t, !strings.contains(html, "<details") && !strings.contains(html, SITE_PROJECT_MENU_NAME))
	testing.expect(t, strings.contains(html, ">Docs</a>") && strings.contains(html, ">News</a>") && !strings.contains(html, ">Gallery</a>"))
	one_line := bar_test_site({.Docs, .Releases})
	html = site_bar_sections_html(&one_line, bar_test_page(.Releases))
	testing.expect_value(t, strings.count(html, SITE_PROJECT_MENU_OPEN_CURRENT), 1)
	panel := html[strings.index(html, "<div class=\"project-menu-panel\">"):]
	testing.expect_value(t, strings.count(panel, "<a "), 1)
	testing.expect(t, strings.contains(panel, " aria-current=\"page\">Releases</a>"))
}

// The rules of the menu: a panel of a definite width that lies over the
// page, under nothing of the page and under the bar only in the order of
// the file; shown with no click under 720 pixels; and a script that only
// adds the ways to close it.
@(test)
site_bar_menu_rules :: proc(t: ^testing.T) {
	style := site_style_sheet("")
	panel := strings.concatenate({".project-menu-panel { position: absolute; left: 0; top: calc(100% + 8px); z-index: 20; width: ", fmt.tprintf("%d", SITE_PROJECT_MENU_PANEL_WIDTH), "px;"}, context.temp_allocator)
	testing.expectf(t, strings.contains(style, panel), "the style sheet has no rule that starts with %q", panel)
	testing.expect(t, !strings.contains(style, "%dpx"), "the width of the panel is not written")
	// The bar is over the page, and the panel is in the bar, over the
	// list of the search (z-index 10), which the same bar holds.
	testing.expect(t, strings.contains(style, ".bar { position: sticky; top: 0; z-index: 30; }"))
	testing.expect(t, strings.contains(style, ".search-panel { position: absolute; right: 0; top: 32px; z-index: 10;"))
	// Under 720 pixels the panel is in the flow of the site menu, and a
	// browser that can shows it with no click and no script.
	testing.expect(t, strings.contains(style, ".project-menu-panel { position: static; width: auto;"))
	testing.expect(t, strings.contains(style, ".project-menu::details-content { content-visibility: visible; }"))
	// The current mark of the button, as a button of a section has it.
	testing.expect(t, strings.contains(style, ".project-menu-current > .project-menu-button { border-bottom-color: var(--line); }"))
	testing.expect(t, strings.contains(style, ".bar-sections a[aria-current=\"page\"] { border-bottom-color: var(--line); }"))
	script := site_search_script()
	testing.expect(t, strings.contains(script, "document.querySelector(\"details.project-menu\")"))
	testing.expect(t, strings.contains(script, "function fitProjectMenu() { projectMenu.open = !wide.matches; }"))
}

// The bar fits one line on a window of 720 pixels, with the search field,
// and the panel of the menu does not pass the right edge of the window.
// The widths are those of the style sheet; the width of a text is taken
// at 9 pixels a character, wider than the fonts of the systems give at 16
// pixels (about 8.3), and the window loses 16 pixels to a scroll bar.
@(test)
site_bar_fits_one_line_at_720_pixels :: proc(t: ^testing.T) {
	WINDOW :: 720
	SCROLL_BAR :: 16
	PADDING :: 16 // .bar-inner, at the left and at the right.
	GAP :: 24 // .bar-inner and .bar-menu-content, between two parts.
	BUTTON_GAP :: 8 // .bar-sections ul.
	BUTTON_PADDING :: 16 // .bar-sections a and .project-menu-button, 8 at each side.
	MENU_MARK :: 12 // .project-menu-button::after, 6 and its margin of 6.
	SEARCH_FIELD :: 224 // .search input.
	CHARACTER :: 9
	style := site_style_sheet("")
	testing.expect(t, strings.contains(style, ".bar-inner { max-width: 1152px; margin: 0 auto; padding: 4px 16px; display: flex; flex-wrap: wrap; align-items: center; gap: 8px 24px; }"))
	testing.expect(t, strings.contains(style, ".bar-sections ul { list-style: none; margin: 0; padding: 0; display: flex; flex-wrap: wrap; gap: 8px; }"))
	testing.expect(t, strings.contains(style, ".bar-sections a { display: inline-block; padding: 0 8px;"))
	testing.expect(t, strings.contains(style, ".search input { width: 224px;"))
	name_width, _ := mark.name_size(SITE_MARK_NAME_CELL_SIZE)
	home := 24 + 8 + name_width // The heron, the gap of .bar-home, the name.
	sections := 0
	for section in site_bar_buttons {
		sections += len(site_section_titles[section]) * CHARACTER + BUTTON_PADDING + BUTTON_GAP
	}
	menu_left := PADDING + home + GAP + sections
	sections += len(SITE_PROJECT_MENU_NAME) * CHARACTER + BUTTON_PADDING + MENU_MARK
	needed := PADDING + home + GAP + sections + GAP + SEARCH_FIELD + PADDING
	testing.expectf(t, needed <= WINDOW - SCROLL_BAR, "the bar needs %d pixels; a window of %d pixels with a scroll bar has %d", needed, WINDOW, WINDOW - SCROLL_BAR)
	// The panel starts at the left edge of the button of the menu.
	testing.expectf(t, menu_left + SITE_PROJECT_MENU_PANEL_WIDTH <= WINDOW - SCROLL_BAR, "the panel ends at %d pixels; the window has %d", menu_left + SITE_PROJECT_MENU_PANEL_WIDTH, WINDOW - SCROLL_BAR)
	// The longest line of the panel has room, at twice the usual width of
	// a character: no text of the panel is cut.
	longest := 0
	for section in site_project_menu_sections {
		longest = max(longest, len(site_section_titles[section]))
	}
	// Beside the text: the border and the padding of the panel, the
	// padding and the left border of a line.
	testing.expect(t, longest * CHARACTER * 2 + 2 + 8 + 16 + 2 <= SITE_PROJECT_MENU_PANEL_WIDTH)
	// With a button for each of the six sections the bar does not fit:
	// the reason for the menu.
	all_buttons := 0
	for section in Site_Section {
		if site_section_under_home(section) {
			all_buttons += len(site_section_titles[section]) * CHARACTER + BUTTON_PADDING + BUTTON_GAP
		}
	}
	testing.expect(t, PADDING + home + GAP + all_buttons - BUTTON_GAP + GAP + SEARCH_FIELD + PADDING > WINDOW - SCROLL_BAR)
}
