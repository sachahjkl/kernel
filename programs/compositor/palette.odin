package compositor

import "contract:ring"
import "support:bar"
import "support:display"
import "support:interface"
import "support:palette"
import "support:system"

// The palette of the desktop (docs/DESIGN.md, "Palette"): the panel that
// the key super opens. This file is its part in the compositor: the keys
// and the pointer that reach it, its two sources of entries (the names of
// the programs and the client table), what a chosen entry does, its draw
// table and its lines in the log. The state, the ranking and the draw
// records are in support/palette, where the host tests run them.
//
// The panel holds no right. A program starts through the root service as
// the menu of the programs starts it; a window comes to the front as a
// press brings it; a close stops a program as the close button does.

palette_panel: palette.Panel // The state of the panel, its entries and its list.
kept_key: u32 // A key that the palette took when it was pressed: its release goes to no program.
// The measures of one open of the panel: the frames drawn while it is
// open and their time, and the longest ranking, in nanoseconds.
palette_frames, palette_time, palette_longest_ranking: u64
// The panel as draw records: the table of now, the table that the screen
// shows, the interface state.
palette_records_now, palette_records_before: [256]interface.Draw_Record
palette_text_now, palette_text_before: [4096]u8
palette_now, palette_before: interface.Draw_Table
palette_interface_state: interface.Interface_State

// palette_start gives the draw tables their memory and their font, and
// makes the first entries. The compositor calls it once, after the
// interface font is loaded.
palette_start :: proc "contextless" () {
	palette_now = {records = palette_records_now[:], text = palette_text_now[:], interface_font = display.interface_font_of()}
	palette_before = {records = palette_records_before[:], text = palette_text_before[:], interface_font = palette_now.interface_font}
	palette_panel.pressed_row = palette.NO_ROW
	palette_entries_refresh()
}

// palette_is_open says if the panel is on the screen and takes the keys.
palette_is_open :: proc "contextless" () -> bool {
	return palette_panel.state != .Closed
}

palette_place :: proc "contextless" () -> (x, y: int) {
	return palette.panel_place(screen.width)
}

damage_palette :: proc "contextless" () {
	x, y := palette_place()
	damage_add(x, y, palette.PANEL_WIDTH, palette.PANEL_HEIGHT)
}

// palette_entries_refresh makes the entries of the panel again from the
// table of the programs and from the client table, the front window first.
// The compositor calls it when a window appears, leaves or comes to the
// front, and after a choice: at a change of the data, not at a key, so
// the open of the panel only draws. An open panel shows the new list.
palette_entries_refresh :: proc "contextless" () {
	window_facts: [CLIENT_CAPACITY]palette.Window
	window_count := 0
	for position := order_count - 1; position >= 0; position -= 1 {
		client := &clients[order[position]]
		window_facts[window_count] = {title = system.name_of(client.title[:]), number = u32(order[position]), focus = position == order_count - 1}
		window_count += 1
	}
	asked := palette_panel.state == .Confirm
	start := system.nanoseconds()
	palette.entries_collect(&palette_panel, bar.names[:], window_facts[:window_count])
	palette_longest_ranking = max(palette_longest_ranking, system.nanoseconds() - start)
	if !palette_is_open() {
		return
	}
	if asked {
		system.log_in("surfaces", .Info, "compositor: the palette goes back to the search: the windows changed")
	}
	palette_list_log()
	palette_refresh()
}

// palette_key_of translates a key of the keyboard into a key of the panel.
palette_key_of :: proc "contextless" (code: u32, character: u8) -> palette.Key {
	switch code {
	case display.KEY_SUPER:
		return .Super
	case display.KEY_ESCAPE:
		return .Escape
	case display.KEY_ENTER:
		return .Enter
	case display.KEY_UP:
		return .Up
	case display.KEY_DOWN:
		return .Down
	case display.KEY_PAGE_UP:
		return .Page_Up
	case display.KEY_PAGE_DOWN:
		return .Page_Down
	case display.KEY_LEFT:
		return .Left
	case display.KEY_RIGHT:
		return .Right
	case display.KEY_HOME:
		return .Home
	case display.KEY_END:
		return .End
	case display.KEY_BACKSPACE:
		return .Backspace
	case display.KEY_DELETE:
		return .Delete
	case display.KEY_TAB:
		return .Tab
	}
	return character >= ' ' && character <= '~' ? palette.Key.Character : palette.Key.Other
}

// palette_key takes a key for the palette. It gives true if the key is for
// the palette, and false if it goes to the window that has the focus. The
// key super opens and closes the panel. While the panel is open, it takes
// each key: what a key does in each state is palette.key_action.
palette_key :: proc "contextless" (code: u32, character: u8, pressed: bool) -> bool {
	if !pressed {
		if code == kept_key {
			kept_key = 0
			return true
		}
		return palette_is_open() || code == display.KEY_SUPER
	}
	key := palette_key_of(code, character)
	was_open := palette_is_open()
	action := palette.key_action(palette_panel.state, key)
	if !was_open && action == .None {
		return false
	}
	if key != .Super {
		kept_key = code
	}
	palette_act(action, key, character, key == .Super ? "the key super" : "the key escape")
	return true
}

// palette_act does one action of the panel: from a key, or from the
// pointer (a press and a release on a row is Run or Confirm; a press
// outside the panel is Close). cause: what closes the panel, for the log.
palette_act :: proc "contextless" (action: palette.Action, key: palette.Key, character: u8, cause: string) {
	panel := &palette_panel
	chosen := palette.chosen_of(panel)
	state_next := palette.state_after(panel.state, action, chosen)
	switch action {
	case .None:
		// A key that the panel does not use: it goes to no program.
	case .Open:
		if menu_open != .None {
			menu_open = .None
			menu_line = -1
			damage_menu()
		}
		palette.panel_open(panel)
		system.log_in("surfaces", .Info, "compositor: the palette is open")
		palette_refresh()
	case .Close:
		palette_close(cause)
	case .Edit:
		start := system.nanoseconds()
		drawn, text_changed := palette.typed_edit(panel, key, character)
		if text_changed {
			palette_longest_ranking = max(palette_longest_ranking, system.nanoseconds() - start)
			palette_list_log()
		}
		if drawn {
			palette_refresh()
		}
	case .Choose_Previous, .Choose_Next, .Choose_Page_Before, .Choose_Page_After:
		step := palette.Choice_Step.Previous
		#partial switch action {
		case .Choose_Next:
			step = .Next
		case .Choose_Page_Before:
			step = .Page_Before
		case .Choose_Page_After:
			step = .Page_After
		}
		if palette.choice_move(panel, step) {
			palette_choice_log()
			palette_refresh()
		}
	case .Run:
		picked := palette.chosen_entry(panel)
		if picked == nil {
			system.log_in("surfaces", .Info, "compositor: the palette has no entry to run")
			break
		}
		if state_next == .Confirm {
			panel.state = .Confirm
			system.log_in("surfaces", .Info, "compositor: the palette asks to confirm: ", palette.entry_name(picked))
			palette_refresh()
			break
		}
		palette_entry_run(picked)
	case .Confirm:
		if confirmed := palette.chosen_entry(panel); confirmed != nil {
			palette_entry_run(confirmed)
		} else {
			palette_close("")
		}
	case .Back:
		panel.state = state_next
		system.log_in("surfaces", .Info, "compositor: the palette goes back to the search")
		palette_refresh()
	}
}

// palette_entry_run does what a chosen entry is, then closes the panel:
// what the entry started shows on the desktop. The number of an entry of a
// window is an index in the client table; the entries are made again at
// each change of that table, and the number is checked here once more.
palette_entry_run :: proc "contextless" (picked: ^palette.Entry) {
	name: [palette.NAME_CAPACITY]u8
	name_text := string(name[:copy(name[:], palette.entry_name(picked))])
	kind, number := picked.kind, int(picked.number)
	palette.recent_note(&palette_panel, picked)
	// The close first: the entries are made again below, and the panel
	// that is closed then draws nothing.
	palette_close("")
	switch kind {
	case .Program:
		if number < len(bar.names) {
			packed := system.name_pack(bar.names[number])
			system.send(&control.completions, ring.Record{kind = u32(display.Control.Start), values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}})
			system.log_in("surfaces", .Info, "compositor: the palette starts ", name_text)
		}
		palette_entries_refresh() // The choice is the newest recent one.
	case .Window:
		system.log_in("surfaces", .Info, "compositor: the palette brings ", name_text, " to the front")
		for position in 0 ..< order_count {
			if order[position] == number {
				raise(position)
				system.log_in("surfaces", .Info, "compositor: window ", system.name_of(clients[number].title[:]), " in front")
				break
			}
		}
		palette_entries_refresh() // The choice is the newest recent one, also when the window was in front.
	case .Close_Window:
		if number < CLIENT_CAPACITY && clients[number].surface.pixels != nil {
			system.send(&control.completions, ring.Record{kind = u32(display.Control.Stop), values = {0 = u64(clients[number].ring_memory)}})
			system.log_in("surfaces", .Info, "compositor: the palette closes the window ", system.name_of(clients[number].title[:]))
		}
	}
}

// palette_pointer takes the pointer while the panel is open: no window
// and no menu receives it. A move over an entry chooses it (only a move: a
// list that changes under a still pointer keeps its choice). A press and a
// release on one row run it. A press outside the panel closes it; a press
// inside the panel that is on no row does nothing.
palette_pointer :: proc "contextless" (moved, pressed, released: bool) {
	panel := &palette_panel
	left, top := palette_place()
	row := palette.row_at(panel, left, top, pointer_x, pointer_y)
	if moved && panel.state == .Search && palette.choice_set(panel, row) {
		palette_choice_log()
		palette_refresh()
	}
	if pressed {
		if palette.part_at(left, top, pointer_x, pointer_y) == .Outside {
			palette_close("a press of the pointer outside it")
			return
		}
		panel.pressed_row = palette.row_is_entry(panel, row) ? row : palette.NO_ROW
	}
	if released {
		pressed_row := panel.pressed_row
		panel.pressed_row = palette.NO_ROW
		if pressed_row == palette.NO_ROW || pressed_row != row {
			return
		}
		#partial switch panel.state {
		case .Search:
			palette.choice_set(panel, row)
			palette_act(.Run, .Other, 0, "")
		case .Confirm:
			// The row that asks: the second Enter. Another row: back.
			palette_act(row == panel.choice ? palette.Action.Confirm : palette.Action.Back, .Other, 0, "")
		}
	}
}

// palette_refresh builds the panel again and damages the difference with
// the panel on the screen.
palette_refresh :: proc "contextless" () {
	if !palette_is_open() {
		return
	}
	nothing: interface.Input
	built := interface.frame_begin(&palette_now, &palette_interface_state, &nothing)
	left, top := palette_place()
	palette.panel_draw(&built, &palette_panel, left, top)
	interface.frame_end(&built)
	if palette_now.full {
		system.log_in("surfaces", .Warning, "compositor: the draw table of the palette is full: records are missing")
	}
	changed: interface.Damage
	interface.damage_by_difference(&palette_before, &palette_now, &changed)
	for rectangle in changed.rectangles[:changed.count] {
		damage_add(rectangle.left, rectangle.top, rectangle.right - rectangle.left, rectangle.bottom - rectangle.top)
	}
	interface.draw_table_copy(&palette_before, &palette_now)
}

PALETTE_LOG_NAMES :: 4 // The first rows that the log names: the line stays one line of the log.

// palette_list_log writes the list on the log: "compositor: the palette
// lists 3 of 61 for "mon": monitor (window), monitor (program), close
// monitor (close a window)". It names the first rows only.
palette_list_log :: proc "contextless" () {
	panel := &palette_panel
	buffer: [PALETTE_LOG_NAMES * (palette.NAME_CAPACITY + 24)]u8
	writer := system.Writer {
		buffer = buffer[:],
	}
	named := 0
	for row in panel.rows[:panel.row_count] {
		if row.kind != .Entry {
			continue
		}
		if named == PALETTE_LOG_NAMES {
			system.write_part(&writer, ", ...")
			break
		}
		listed := &panel.entries[row.entry]
		system.write_part(&writer, named > 0 ? ", " : "")
		system.write_part(&writer, palette.entry_name(listed))
		system.write_part(&writer, " (")
		system.write_part(&writer, palette.kind_words(listed.kind))
		system.write_part(&writer, ")")
		named += 1
	}
	system.log_in("surfaces", .Info, "compositor: the palette lists ", u64(panel.matched_count), " of ", u64(panel.entry_count), " for \"", palette.typed_text(panel), "\": ", system.written(&writer))
}

// palette_choice_log writes the chosen entry on the log: "compositor: the
// palette chooses plasma (window)".
palette_choice_log :: proc "contextless" () {
	if picked := palette.chosen_entry(&palette_panel); picked != nil {
		system.log_in("surfaces", .Info, "compositor: the palette chooses ", palette.entry_name(picked), " (", palette.kind_words(picked.kind), ")")
	}
}

// palette_close closes the panel, and writes on the log the measures of
// this open: the frames and their mean time, and the longest ranking. With
// a cause, a second line says what closed the panel.
palette_close :: proc "contextless" (cause: string) {
	if !palette_is_open() {
		return
	}
	palette.panel_close(&palette_panel)
	damage_palette()
	interface.draw_table_clear(&palette_before)
	per_frame := palette_time / max(palette_frames, 1)
	system.log_in("surfaces", .Info, "compositor: the palette was open for ", palette_frames, " frames, ", per_frame / 1000, ".", per_frame / 100 % 10, " us per frame; the longest ranking ", palette_longest_ranking / 1000, ".", palette_longest_ranking / 100 % 10, " us")
	palette_frames, palette_time, palette_longest_ranking = 0, 0, 0
	if cause != "" {
		system.log_in("surfaces", .Info, "compositor: the palette is closed by ", cause)
	}
}
