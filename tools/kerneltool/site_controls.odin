// The states of a control of the site (docs/SITE.md, "The states of a
// control"; src/md/features/site_bar.md). A control is a part of a page
// that a reader presses: a button of the bar, a door of the home, a
// numbered link of the carousel, a line of a menu or of a list. Each one
// has five states: at rest, with the pointer over it, with the focus of the
// keyboard, pressed, and current. One table names every control, and one
// procedure writes the rules of its states: no control has states of its
// own, and a new control gets them when it gets its line in the table.
//
// The colors are those of the desktop of the system (docs/DESIGN.md, "10.
// Elements" and "Menus"): a button is a rectangle of the track; it is the
// blue of the title bar at 60 % with the pointer over it or with the focus;
// it is the blue of a chosen row, with a white label, while it is pressed
// or open. A line of a menu under the pointer is a chosen row. A row of a
// list takes the band of the track, and the line at its left when it is
// pressed or chosen.
//
// No state changes a size: a state changes a background, a color of a text
// or the color of a border that the control has at rest. So nothing beside
// a control moves. No state has a transition: a state shows at once.
package kerneltool

import "core:strings"
import "modus:support/graphics"

// The three forms of a control: each has its own colors for its states.
Site_Control_Form :: enum {
	Button, // A rectangle of the track: a button of the bar, a door.
	Menu_Line, // A line of a menu under its button: the line under the pointer is a chosen row.
	Row, // A row of a list or of a tree: the band of the track.
}

// One control: its selector in the style sheet, its form, and the selector
// of its current state when it has one.
Site_Control :: struct {
	name:      string, // What the control is, for the message of a test.
	selector:  string,
	form:      Site_Control_Form,
	rest:      string, // The selector of the rule of its look at rest, when it is not the selector itself.
	current:   string, // The selector of its current, open or chosen state, or "".
	wide_only: bool, // A control only from 720 pixels: under it, it is a line of the site menu.
}

site_controls := [?]Site_Control {
	{name = "a button of a section of the bar", selector = ".bar-sections a", form = .Button, current = ".bar-sections a[aria-current=\"page\"]"},
	{name = "the button of the project menu", selector = ".project-menu-button", form = .Button, current = ".project-menu-current > .project-menu-button", wide_only = true},
	{name = "a line of the panel of the project menu", selector = ".bar-sections .project-menu-panel a", form = .Menu_Line, current = ".bar-sections .project-menu-panel a[aria-current=\"page\"]", wide_only = true},
	{name = "the button of the site menu", selector = ".bar-menu-button", form = .Button, current = ".bar-menu[open] > .bar-menu-button"},
	{name = "a door of the home, and a link to a group of the gallery", selector = ".doors a", form = .Button},
	{name = "a numbered link of the carousel", selector = ".carousel-controls a", form = .Button, current = ".carousel-controls a[aria-current=\"true\"]"},
	{name = "a letter of the index of the glossary", selector = ".glossary-letters a", form = .Button},
	{name = "the button of the line of an older build", selector = ".build-notice button", form = .Button},
	{name = "a chip of the chart of the search that is a link", selector = "a.search-chart-target", form = .Row, rest = ".search-chart-target"},
	{name = "a chip of the chart of the search that is a button", selector = ".search-chart-target[role=\"button\"]", form = .Row, current = ".search-chart-target[aria-pressed=\"true\"]"},
	{name = "a row of the list of the search", selector = ".search-list a", form = .Row, current = ".search-list [aria-selected=\"true\"] a"},
	{name = "a line of the documentation tree", selector = ".tree a", form = .Row, current = ".tree a[aria-current=\"page\"]"},
	{name = "a line of the list of the headings of a page", selector = ".outline a", form = .Row, current = ".outline a[aria-current=\"location\"]"},
	{name = "a stage of the line of time of the start", selector = ".boot-stage-row", form = .Row},
}

// The colors of the states of a button in one form of the page.
Site_Control_Colors :: struct {
	hover:       graphics.Color, // The pointer over it, or the focus.
	hover_text:  graphics.Color,
	active:      graphics.Color, // Pressed, or open.
	active_text: graphics.Color,
}

// site_control_colors gives the colors of the states in one form. The blue
// at 60 % is dark in both forms: on the light page its label is white, on
// the dark page it keeps the text color, as on the desktop.
site_control_colors :: proc(light: bool) -> Site_Control_Colors {
	return Site_Control_Colors {
		hover = graphics.shade(graphics.COLOR_TITLE, 60),
		hover_text = light ? graphics.COLOR_WHITE : site_dark_colors().text,
		active = graphics.COLOR_CHOSEN,
		active_text = graphics.COLOR_WHITE,
	}
}

// site_control_variables writes the variables of the states for one form.
site_control_variables :: proc(builder: ^strings.Builder, light: bool) {
	colors := site_control_colors(light)
	strings.write_string(builder, ":root {\n")
	site_variable(builder, "control-hover", colors.hover)
	site_variable(builder, "control-hover-text", colors.hover_text)
	site_variable(builder, "control-active", colors.active)
	site_variable(builder, "control-active-text", colors.active_text)
	strings.write_string(builder, "}\n")
}

// The rules that are not of one control of the table: a link of a text
// shows a press, as it shows the pointer; and the mark of the button of
// the project menu takes the color of its label in each state, because the
// dim color has too little contrast on the blue.
SITE_CONTROL_SHARED_RULES :: `
a:active { background: var(--track); }
@media (min-width: 720px) {
  .project-menu-button:hover::after, .project-menu-button:focus-visible::after, .project-menu-button:active::after { background: currentColor; }
}
`

// site_control_state_rules writes the rules of the states of one control.
site_control_state_rules :: proc(builder: ^strings.Builder, control: Site_Control) {
	indent: string = control.wide_only ? "  " : ""
	selector := control.selector
	if control.wide_only {
		strings.write_string(builder, "@media (min-width: 720px) {\n")
	}
	switch control.form {
	case .Button:
		strings.write_string(builder, strings.concatenate({indent, selector, ":hover, ", selector, ":focus-visible { background: var(--control-hover); color: var(--control-hover-text); }\n"}, context.temp_allocator))
		strings.write_string(builder, strings.concatenate({indent, selector, ":active { background: var(--control-active); color: var(--control-active-text); }\n"}, context.temp_allocator))
	case .Menu_Line:
		strings.write_string(builder, strings.concatenate({indent, selector, ":hover, ", selector, ":focus-visible { background: var(--control-active); color: var(--control-active-text); }\n"}, context.temp_allocator))
		strings.write_string(builder, strings.concatenate({indent, selector, ":active { background: var(--control-active); color: var(--control-active-text); }\n"}, context.temp_allocator))
	case .Row:
		strings.write_string(builder, strings.concatenate({indent, selector, ":hover, ", selector, ":focus-visible { background: var(--track); }\n"}, context.temp_allocator))
		strings.write_string(builder, strings.concatenate({indent, selector, ":active { background: var(--track); border-left-color: var(--line); }\n"}, context.temp_allocator))
	}
	if control.wide_only {
		strings.write_string(builder, "}\n")
	}
}

// site_control_rules gives the rules of the states of every control of the
// table, then the shared rules.
site_control_rules :: proc() -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "\n/* The states of a control: the pointer over it, the focus, a press. */\n")
	controls := site_controls
	for control in controls {
		site_control_state_rules(&builder, control)
	}
	strings.write_string(&builder, SITE_CONTROL_SHARED_RULES)
	return strings.to_string(builder)
}

// site_control_rest_selector gives the selector of the rule of the look at
// rest of a control.
site_control_rest_selector :: proc(control: Site_Control) -> string {
	return control.rest != "" ? control.rest : control.selector
}
