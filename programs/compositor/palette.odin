package compositor

import "contract:palette_table"
import "contract:ring"
import "support:bar"
import "support:display"
import "support:interface"
import "support:palette"
import "support:system"
import "base:intrinsics"

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

palette_panel: palette.Panel // The state of the panel. Its list is one of palette_lists.
kept_key: u32 // A key that the palette took when it was pressed: its release goes to no program.
// The measures of one open of the panel: the frames drawn while it is
// open and their time, in nanoseconds.
palette_frames, palette_time: u64
// The panel as draw records: the table of now, the table that the screen
// shows, the interface state.
palette_records_now, palette_records_before: [256]interface.Draw_Record
palette_text_now, palette_text_before: [4096]u8
palette_now, palette_before: interface.Draw_Table
palette_interface_state: interface.Interface_State

// The ranking thread. The loop of the compositor never makes a list: it
// writes a request (the typed part, the windows, the remembered choices)
// and wakes the second thread, which collects the entries, copies and
// checks the table of the palette provider, ranks, and publishes the
// list. The loop then adopts it: one address changes.
//
// The two lists take turns. The thread writes only the list that the loop
// does not read: it starts a list only after the loop adopted the one
// before, so the loop never reads a list that changes.
palette_lists: [2]palette.List

Ranking_Window :: struct {
	title:  system.Name,
	number: u32,
	focus:  bool,
}

Ranking :: struct {
	lock:           system.Lock, // Over the request, for one copy in memory.
	query:          [palette.TYPED_CAPACITY]u8, // The typed part of the request.
	query_length:   int,
	windows:        [CLIENT_CAPACITY]Ranking_Window, // The windows, the front one first.
	window_count:   int,
	recents:        [palette.RECENT_CAPACITY]palette.Recent, // The remembered choices.
	recent_count:   int,
	requested:      u32, // The number of the newest request. The thread waits on this word.
	published:      u32, // The lists that the thread published. The loop waits on this word.
	published_list: u32, // The index of the newest whole list.
	adopted:        u32, // The value of `published` that the loop adopted. The thread waits on this word.
	longest:        u64, // The longest making of a list since the last close of the panel, in nanoseconds.
	// The mapping of the table of the provider, or nil. The lock is held
	// by the thread for one copy of the table, and by the loop to end the
	// mapping: the thread never reads a table that is gone.
	table_lock:     system.Lock,
	table:          []u8,
}

palette_ranking: Ranking
palette_published_seen: u32 // The value of `published` that the loop saw last.
palette_enter_waits: bool // Enter came while the list of the typed part was not made yet: it runs when the list comes.

// The palette provider, as the root service gave it: its ring and its
// entry table, read-only (contract:palette_table). The table is hostile
// input: the ranking thread copies it and checks the copy.
palette_provider_ring: ring.Ring
palette_provider_ring_handle, palette_provider_table_handle: system.Handle
palette_generation_seen: u32 // The change count of the table that the loop saw last.
palette_tags: u32 // The tag of the last choice sent.
palette_answer_awaited: u32 // Not 0: the tag of the choice whose answer the desktop still acts on.

// palette_start gives the draw tables their memory and their font, starts
// the ranking thread and asks for the first list. The compositor calls it
// once, after the interface font is loaded.
palette_start :: proc "contextless" () {
	palette_now = {records = palette_records_now[:], text = palette_text_now[:], interface_font = display.interface_font_of()}
	palette_before = {records = palette_records_before[:], text = palette_text_before[:], interface_font = palette_now.interface_font}
	palette_panel.pressed_row = palette.NO_ROW
	palette_panel.list = &palette_lists[0]
	if _, status := system.thread_start(palette_ranking_thread, nil); status != .Ok {
		system.log("compositor: cannot start the ranking thread: the palette lists nothing")
	}
	palette_entries_refresh()
}

// palette_ranking_thread is the entry of the second thread: it makes one
// list for each request, the newest one when several came.
palette_ranking_thread :: proc "c" (parameter: rawptr) -> ! {
	ranking := &palette_ranking
	done: u32
	refused_before: palette_table.Problem
	for {
		system.word_wait(&ranking.requested, done)
		if intrinsics.atomic_load_explicit(&ranking.requested, .Relaxed) == done {
			continue
		}
		// The loop reads the list that it adopted: the other one is free
		// only when the loop adopted the newest published list.
		for {
			adopted := intrinsics.atomic_load_explicit(&ranking.adopted, .Relaxed)
			if adopted == intrinsics.atomic_load_explicit(&ranking.published, .Relaxed) {
				break
			}
			system.word_wait(&ranking.adopted, adopted)
		}
		// The request, copied under its lock: the list answers this one.
		query: [palette.TYPED_CAPACITY]u8
		titles: [CLIENT_CAPACITY]system.Name
		windows: [CLIENT_CAPACITY]palette.Window
		recents: [palette.RECENT_CAPACITY]palette.Recent
		system.lock(&ranking.lock)
		sequence := intrinsics.atomic_load_explicit(&ranking.requested, .Relaxed)
		query_length := copy(query[:], ranking.query[:clamp(ranking.query_length, 0, len(ranking.query))])
		window_count := clamp(ranking.window_count, 0, CLIENT_CAPACITY)
		for index in 0 ..< window_count {
			titles[index] = ranking.windows[index].title
			windows[index] = {title = system.name_of(titles[index][:]), number = ranking.windows[index].number, focus = ranking.windows[index].focus}
		}
		recent_count := copy(recents[:], ranking.recents[:clamp(ranking.recent_count, 0, len(ranking.recents))])
		system.unlock(&ranking.lock)

		target := 1 - intrinsics.atomic_load_explicit(&ranking.published_list, .Relaxed)
		list := &palette_lists[target]
		start := system.nanoseconds()
		system.lock(&ranking.table_lock)
		problem, problem_index := palette.list_collect(list, recents[:recent_count], bar.names[:], windows[:window_count], ranking.table)
		system.unlock(&ranking.table_lock)
		palette.list_rank(list, string(query[:query_length]))
		list.sequence = sequence
		spent := system.nanoseconds() - start
		if problem != refused_before {
			refused_before = problem
			if problem != .None {
				system.log_in("surfaces", .Warning, "compositor: the table of the palette provider is refused: ", palette_table.problem_names[problem], ", entry ", u64(problem_index), "; the palette lists the programs and the windows only")
			}
		}
		system.lock(&ranking.lock)
		ranking.longest = max(ranking.longest, spent)
		system.unlock(&ranking.lock)
		intrinsics.atomic_store(&ranking.published_list, target)
		intrinsics.atomic_add(&ranking.published, 1)
		system.word_wake(&ranking.published)
		done = sequence
	}
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

// palette_entries_refresh asks the ranking thread for a new list: the
// typed part of now, the windows of the client table with the front one
// first, the choices that the panel remembers. The compositor calls it
// when a window appears, leaves or comes to the front, after a choice, at
// each change of the typed part, and when the table of the provider
// changes: at a change of the data. The work here is one copy of at most
// 32 titles and 16 names.
palette_entries_refresh :: proc "contextless" () {
	ranking := &palette_ranking
	system.lock(&ranking.lock)
	ranking.query_length = copy(ranking.query[:], palette.typed_text(&palette_panel))
	ranking.window_count = 0
	for position := order_count - 1; position >= 0; position -= 1 {
		ranking.windows[ranking.window_count] = {title = clients[order[position]].title, number = u32(order[position]), focus = position == order_count - 1}
		ranking.window_count += 1
	}
	ranking.recent_count = copy(ranking.recents[:], palette_panel.recents[:clamp(palette_panel.recent_count, 0, palette.RECENT_CAPACITY)])
	intrinsics.atomic_add(&ranking.requested, 1)
	system.unlock(&ranking.lock)
	system.word_wake(&ranking.requested)
}

// palette_list_is_current says if the list of the panel answers the newest
// request: the typed part and the windows of now.
palette_list_is_current :: proc "contextless" () -> bool {
	return palette_panel.list.sequence == intrinsics.atomic_load_explicit(&palette_ranking.requested, .Relaxed)
}

// palette_wait adds the words of the palette to the wait of the loop: a
// list that the ranking thread published, an answer of the provider, a
// change of its table.
palette_wait :: proc "contextless" (wait: ^system.Wait) {
	system.wait_word(wait, &palette_ranking.published, palette_published_seen)
	if palette_provider_ring.head != nil {
		system.wait_records(wait, &palette_provider_ring.completions)
		header := (^palette_table.Header)(raw_data(palette_ranking.table))
		system.wait_word(wait, &header.change_count, palette_generation_seen)
	}
}

// palette_turn is the part of the palette in each turn of the loop, after
// the wait: a table of the provider that changed asks for a new list; a
// published list is adopted; an answer of the provider is shown.
palette_turn :: proc "contextless" () {
	if palette_provider_ring.head != nil {
		header := (^palette_table.Header)(raw_data(palette_ranking.table))
		if generation := intrinsics.volatile_load(&header.change_count); generation != palette_generation_seen {
			palette_generation_seen = generation
			palette_entries_refresh()
		}
		for record in system.receive(&palette_provider_ring.completions) {
			palette_answer(record)
		}
	}
	published := intrinsics.atomic_load_explicit(&palette_ranking.published, .Relaxed)
	if published == palette_published_seen {
		return
	}
	palette_published_seen = published
	asked := palette_panel.state == .Confirm
	palette.panel_adopt(&palette_panel, &palette_lists[intrinsics.atomic_load_explicit(&palette_ranking.published_list, .Relaxed) & 1])
	// The thread can now write the other list.
	intrinsics.atomic_store(&palette_ranking.adopted, published)
	system.word_wake(&palette_ranking.adopted)
	if !palette_is_open() {
		return
	}
	if asked {
		system.log_in("surfaces", .Info, "compositor: the palette goes back to the search: the entries changed")
	}
	if palette_list_is_current() {
		palette_list_log()
		if palette_enter_waits {
			palette_enter_waits = false
			if palette_panel.state == .Search {
				palette_act(.Run, .Enter, 0, "")
			}
		}
	}
	palette_refresh()
}

// palette_provider_add takes the ring and the entry table of the palette
// provider from the root service. The table is mapped read-only.
palette_provider_add :: proc "contextless" (ring_handle, table_handle: system.Handle) {
	if palette_provider_ring.head != nil {
		palette_provider_remove()
	}
	opened, status := system.ring_open(ring_handle)
	address: rawptr
	if status == .Ok && system.memory_size(table_handle) < palette_table.TABLE_PAGES {
		status = .Bad_Handle
	}
	if status == .Ok {
		address, status = system.memory_map(table_handle, {})
	}
	if status != .Ok {
		if opened.head != nil {
			system.ring_close(&opened)
		}
		system.close(ring_handle)
		system.close(table_handle)
		system.log_in("surfaces", .Warning, "compositor: the palette provider is refused: its ring or its table cannot be mapped")
		return
	}
	palette_provider_ring = opened
	palette_provider_ring_handle, palette_provider_table_handle = ring_handle, table_handle
	system.lock(&palette_ranking.table_lock)
	palette_ranking.table = ([^]u8)(address)[:palette_table.TABLE_BYTES]
	system.unlock(&palette_ranking.table_lock)
	palette_generation_seen = intrinsics.volatile_load(&(^palette_table.Header)(address).change_count)
	system.log_in("surfaces", .Info, "compositor: the palette has a provider")
	palette_entries_refresh()
}

// palette_provider_remove ends the palette provider: the program stopped,
// or its grant ended. The palette keeps the programs and the windows. A
// panel that waits for an answer shows that none comes.
palette_provider_remove :: proc "contextless" () {
	if palette_provider_ring.head == nil {
		return
	}
	system.lock(&palette_ranking.table_lock)
	address := raw_data(palette_ranking.table)
	palette_ranking.table = nil
	system.unlock(&palette_ranking.table_lock)
	system.memory_unmap(address)
	system.ring_close(&palette_provider_ring)
	palette_provider_ring = {}
	system.close(palette_provider_ring_handle)
	system.close(palette_provider_table_handle)
	palette_answer_awaited = 0
	system.log_in("surfaces", .Info, "compositor: the palette has no provider")
	if palette_panel.state == .Running {
		palette.result_sentence(&palette_panel, "the console stopped, or it is no more the palette provider")
		palette_refresh()
	}
	palette_entries_refresh()
}

// palette_choose sends the chosen entry of the provider on its ring: the
// generation of the table that the list shows, the index of the entry and
// the hash of its name. It gives false with no provider or a full ring.
palette_choose :: proc "contextless" (picked: ^palette.Entry, mode: palette_table.Choose_Mode) -> bool {
	if palette_provider_ring.head == nil {
		return false
	}
	palette_tags += 1
	if palette_tags == 0 {
		palette_tags = 1
	}
	palette_answer_awaited = palette_tags
	return system.send(&palette_provider_ring.commands, ring.Record{kind = u32(palette_table.Command.Choose), tag = palette_tags, values = {0 = u64(palette_panel.list.snapshot.generation), 1 = u64(picked.number), 2 = palette_table.name_hash(palette.entry_name(picked)), 3 = u64(mode)}})
}

// palette_console_to_front brings the window of the provider to the front:
// the line and its result are there.
palette_console_to_front :: proc "contextless" () {
	for position := order_count - 1; position >= 0; position -= 1 {
		if system.name_of(clients[order[position]].title[:]) == "console" {
			raise(position)
			system.log_in("surfaces", .Info, "compositor: window console in front")
			return
		}
	}
}

@(rodata)
palette_kind_words := [palette_table.Value_Kind]string {
	.None    = "no value",
	.Integer = "an Integer",
	.Text    = "a Text",
	.Record  = "a Record",
	.Handle  = "a Handle",
	.Table   = "a Table",
	.Bytes   = "Bytes",
}

// palette_answer takes one answer of the provider. Each value is the
// value of another program: the outcome and the kind are checked, and the
// result is copied and checked before the panel shows it
// (palette.result_set). An answer to a choice that the desktop no longer
// waits for is dropped.
palette_answer :: proc "contextless" (record: ring.Record) {
	if record.tag == 0 || record.tag != palette_answer_awaited {
		return
	}
	palette_answer_awaited = 0
	outcome := record.values[0]
	in_console := outcome == u64(palette_table.Outcome.Shown_In_Console) || outcome == u64(palette_table.Outcome.Edit_Opened)
	if in_console {
		where_text: string = "compositor: the result of the palette is in the console"
		if outcome == u64(palette_table.Outcome.Edit_Opened) {
			where_text = "compositor: the palette opened the entry in the console"
		}
		system.log_in("surfaces", .Info, where_text)
		palette_console_to_front()
	}
	if palette_panel.state != .Running {
		return
	}
	palette.result_set(&palette_panel, outcome, record.values[1], palette_ranking.table, record.values[2])
	if palette_panel.state == .Closed {
		palette_panel.state = .Running // palette_close closes an open panel.
		palette_close("")
		return
	}
	result := &palette_panel.result
	#partial switch result.outcome {
	case .Shown_In_Panel:
		system.log_in("surfaces", .Info, "compositor: the palette shows ", palette_kind_words[result.kind])
	case .Failed:
		system.log_in("surfaces", .Info, "compositor: the palette shows an error")
	case:
		system.log_in("surfaces", .Info, "compositor: the palette shows a refusal")
	}
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
		// The typed part shows at once; its list comes from the ranking
		// thread, and the panel shows the list before until then.
		drawn, text_changed := palette.typed_edit(panel, key, character)
		if text_changed {
			palette_enter_waits = false
			palette_entries_refresh()
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
		if !palette_list_is_current() {
			// The list of the typed part is not made yet: Enter waits for
			// it, and never runs an entry of the list before.
			palette_enter_waits = true
			break
		}
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
		if state_next == .Running {
			palette_entry_send(picked)
			break
		}
		palette_entry_run(picked)
	case .Confirm:
		confirmed := palette.chosen_entry(panel)
		switch {
		case confirmed == nil:
			palette_close("")
		case state_next == .Running:
			palette_entry_send(confirmed)
		case:
			palette_entry_run(confirmed)
		}
	case .Back:
		panel.state = state_next
		system.log_in("surfaces", .Info, "compositor: the palette goes back to the search")
		palette_refresh()
	}
}

// palette_entry_send sends a chosen entry with no parameter to the
// provider, and makes the panel wait for what it gives. The panel stays
// open and takes its keys: Escape closes it, and the line goes on in the
// window of the provider.
palette_entry_send :: proc "contextless" (picked: ^palette.Entry) {
	panel := &palette_panel
	palette.recent_note(panel, picked)
	palette.sent_set(panel, picked)
	panel.state = .Running
	if palette_choose(picked, .Run) {
		system.log_in("surfaces", .Info, "compositor: the palette sends ", palette.sent_text(panel), " to the console")
	} else {
		palette.result_sentence(panel, "the console takes no choice now")
		system.log_in("surfaces", .Info, "compositor: the palette shows a refusal")
	}
	palette_refresh()
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
	case .Command, .Export:
		// An entry with parameters: the provider writes it in its edit
		// line, and its window comes to the front when it answers.
		if palette_choose(picked, .Edit) {
			system.log_in("surfaces", .Info, "compositor: the palette opens ", name_text, " in the console")
		}
		palette_entries_refresh()
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
	list := panel.list
	for row in list.rows[:list.row_count] {
		if row.kind != .Entry {
			continue
		}
		if named == PALETTE_LOG_NAMES {
			system.write_part(&writer, ", ...")
			break
		}
		listed := &list.entries[row.entry]
		system.write_part(&writer, named > 0 ? ", " : "")
		system.write_part(&writer, palette.entry_name(listed))
		system.write_part(&writer, " (")
		system.write_part(&writer, palette.kind_words(listed.kind))
		system.write_part(&writer, ")")
		named += 1
	}
	system.log_in("surfaces", .Info, "compositor: the palette lists ", u64(list.matched_count), " of ", u64(list.entry_count), " for \"", palette.typed_text(panel), "\": ", system.written(&writer))
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
	if palette_panel.state == .Running {
		// The line goes on in the console; the desktop does nothing with
		// its answer.
		palette_answer_awaited = 0
	}
	palette.panel_close(&palette_panel)
	palette_enter_waits = false
	damage_palette()
	interface.draw_table_clear(&palette_before)
	per_frame := palette_time / max(palette_frames, 1)
	system.lock(&palette_ranking.lock)
	longest := palette_ranking.longest
	palette_ranking.longest = 0
	system.unlock(&palette_ranking.lock)
	system.log_in("surfaces", .Info, "compositor: the palette was open for ", palette_frames, " frames, ", per_frame / 1000, ".", per_frame / 100 % 10, " us per frame; the longest list of the ranking thread ", longest / 1000, ".", longest / 100 % 10, " us")
	palette_frames, palette_time = 0, 0
	// The list of an empty typed part, ready for the next open.
	palette_entries_refresh()
	if cause != "" {
		system.log_in("surfaces", .Info, "compositor: the palette is closed by ", cause)
	}
}
