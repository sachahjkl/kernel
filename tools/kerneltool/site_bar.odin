// The sections of the bar of the site (docs/SITE.md, "The buttons and the
// menu of the bar"). The bar is one line of a fixed height, and the parts
// under it are placed by that height. Six sections stand under the home,
// and six buttons with the search field do not fit one line on a window of
// 720 pixels. So three sections are buttons, and three are the lines of
// one menu that opens under its button, as a menu of the bar of the
// desktop does.
package kerneltool

import "core:fmt"
import "core:strings"

// The sections that are buttons of the bar, in their order. They are what
// a first reader looks for: what the system is and how it works, what it
// looks like, what is new.
site_bar_buttons := [?]Site_Section{.Docs, .Gallery, .News}

// The sections that are the lines of the menu of the bar, in their order.
// They report how the project goes: what is built and what is missing,
// what each release brought, what is planned.
site_project_menu_sections := [?]Site_Section{.Status, .Releases, .Roadmap}

// The word of the button of the menu: the name of the group of the
// glossary that holds the words of these three pages.
SITE_PROJECT_MENU_NAME :: "Project"

// The width of the panel of the menu, in pixels: a definite width, so that
// the place of its right edge is known for each window. Its longest line,
// "Releases", has room at twice the width of a usual character.
SITE_PROJECT_MENU_PANEL_WIDTH :: 176

// The start of the menu of the grouped sections: a details element, closed
// in the file, whose summary is its button. With no script the button
// opens and closes the panel.
SITE_PROJECT_MENU_OPEN :: "<details class=\"project-menu\">"
SITE_PROJECT_MENU_OPEN_CURRENT :: "<details class=\"project-menu project-menu-current\">"

// The rules of the menu. From 720 pixels the panel lies over the page
// under the bar, at the left edge of its button: it never moves the page.
// Under 720 pixels the sections are already one under the other in the
// site menu; the panel is in that list, under the word of its group, and
// it is shown with no click: by the content of the details element where
// a browser has ::details-content, else by search.js, which opens it.
// The button of an open menu has the colors of a pressed control, as the
// button of an open menu of the bar of the desktop; the states of the
// button and of the lines of the panel under the pointer are in
// site_controls.odin, with the states of every other control.
SITE_PROJECT_MENU_RULES :: `
.project-menu { position: relative; }
.project-menu-button { list-style: none; display: block; padding: 0 8px; line-height: 24px; white-space: nowrap; background: var(--track); border-bottom: 2px solid transparent; cursor: pointer; }
.project-menu-button::-webkit-details-marker { display: none; }
.project-menu-button::after { content: ""; display: inline-block; width: 6px; height: 6px; margin-left: 6px; vertical-align: 1px; background: var(--dim); }
.project-menu[open] > .project-menu-button { background: var(--control-active); color: var(--control-active-text); }
.project-menu[open] > .project-menu-button::after { background: var(--control-active-text); }
.project-menu-current > .project-menu-button { border-bottom-color: var(--line); }
.project-menu-panel { position: absolute; left: 0; top: calc(100% + 8px); z-index: 20; width: %dpx; padding: 4px; background: var(--card-bottom); border: 1px solid var(--line); }
.bar-sections .project-menu-panel a { display: block; padding: 0 8px; line-height: 32px; white-space: nowrap; background: none; border-bottom: 0; border-left: 2px solid transparent; }
.bar-sections .project-menu-panel a[aria-current="page"] { border-left-color: var(--line); }
@media (max-width: 719px) {
  .project-menu-button { display: block; padding: 4px 8px 0; background: none; border-bottom: 0; color: var(--dim); font-size: 14px; cursor: default; }
  .project-menu[open] > .project-menu-button { background: none; color: var(--dim); }
  .project-menu-button::after { display: none; }
  .project-menu-panel { position: static; width: auto; padding: 0; background: none; border: 0; }
  .bar-sections .project-menu-panel a { padding: 4px 8px 4px 16px; line-height: 24px; }
}
@supports selector(::details-content) {
  @media (max-width: 719px) {
    .project-menu::details-content { content-visibility: visible; }
    .project-menu-button { pointer-events: none; }
  }
}
`

// site_project_menu_rules gives the rules of the menu, with the width of its
// panel.
site_project_menu_rules :: proc() -> string {
	rules, _ := strings.replace_all(SITE_PROJECT_MENU_RULES, "%dpx", fmt.tprintf("%dpx", SITE_PROJECT_MENU_PANEL_WIDTH), context.temp_allocator)
	return rules
}

// site_section_is_bar_button tells whether a section is a button of the bar.
site_section_is_bar_button :: proc(section: Site_Section) -> bool {
	buttons := site_bar_buttons
	for button in buttons {
		if button == section {
			return true
		}
	}
	return false
}

// site_section_in_project_menu tells whether a section is a line of the menu
// of the bar.
site_section_in_project_menu :: proc(section: Site_Section) -> bool {
	grouped := site_project_menu_sections
	for member in grouped {
		if member == section {
			return true
		}
	}
	return false
}

// site_bar_link writes the link of one section of the bar; the section
// that holds the page is marked.
site_bar_link :: proc(site: ^Site, b: ^strings.Builder, from_page: string, section, current_section: Site_Section) {
	current: string = section == current_section ? " aria-current=\"page\"" : ""
	fmt.sbprintf(b, "<a href=\"%s\"%s>%s</a>", site_page_link(site, from_page, site_section_page(section)), current, site_section_titles[section])
}

// site_bar_sections_html gives the navigation of the bar of a page: one
// list, with a link for each button, then the menu as its last item. The
// menu is a details element; its panel holds a link for each of its
// sections. A section appears when its page exists, and the menu when one
// of its sections does. When the page is in a section of the menu, the
// button of the menu is marked as a button of the current section is, and
// the link of the section in the panel too. The panel is not a list
// inside the list: each list under an item of a navigation is a list of
// tree lines, and these three lines are not a tree.
site_bar_sections_html :: proc(site: ^Site, page: Site_Page) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<nav class=\"bar-sections\" aria-label=\"Sections\">\n<ul>\n")
	current_section := site_bar_section(page.section)
	buttons := site_bar_buttons
	for section in buttons {
		if !site_page_exists(site, site_section_page(section)) {
			continue
		}
		strings.write_string(&b, "<li>")
		site_bar_link(site, &b, page.path, section, current_section)
		strings.write_string(&b, "</li>\n")
	}
	grouped := site_project_menu_sections
	group_count := 0
	for section in grouped {
		group_count += site_page_exists(site, site_section_page(section)) ? 1 : 0
	}
	if group_count > 0 {
		strings.write_string(&b, "<li>")
		strings.write_string(&b, site_section_in_project_menu(current_section) ? SITE_PROJECT_MENU_OPEN_CURRENT : SITE_PROJECT_MENU_OPEN)
		strings.write_string(&b, "\n<summary class=\"project-menu-button\">" + SITE_PROJECT_MENU_NAME + "</summary>\n<div class=\"project-menu-panel\">\n")
		for section in grouped {
			if !site_page_exists(site, site_section_page(section)) {
				continue
			}
			site_bar_link(site, &b, page.path, section, current_section)
			strings.write_string(&b, "\n")
		}
		strings.write_string(&b, "</div>\n</details></li>\n")
	}
	strings.write_string(&b, "</ul>\n</nav>\n")
	return strings.to_string(b)
}
