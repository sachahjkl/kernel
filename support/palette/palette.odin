// The palette (docs/DESIGN.md, "Palette"): the panel that the key super
// opens, where the input types a part of a name and chooses an entry. This
// package is the part of the panel that needs no screen and no kernel: its
// state, its entries, the ranking of the entries against the typed part,
// the choice, what each key does (keys.odin), and the draw records of the
// panel (panel.odin).
//
// The compositor owns one `Panel` and the two sources of entries that it
// has itself: the names of the programs and the windows. It gives them to
// `entries_collect` when one of them changes, sends each key through
// `key_action`, and draws with `panel_draw`.
//
// The package keeps no state of its own, makes no kernel call and never
// allocates: each procedure takes the panel in the memory of the caller.
// So the host tests run each key and draw the panel on a canvas.
//
// The entries and the list of a panel are a `List`, apart from the panel:
// the compositor makes a list on a second thread and gives the panel the
// address of the newest one (`panel_adopt`), so its loop never ranks. A
// list holds the texts of its own entries, and its ranking points at them:
// a list is never copied.
package palette

import "contract:palette_table"
import "support:line_editor"

// The state of the panel. One value says all of it: no state is a pair of
// flags.
State :: enum u8 {
	Closed  = 0, // The panel is not on the screen. The keys go to the window that has the focus.
	Search  = 1, // The panel is open: the input types a part of a name and moves the choice.
	Confirm = 2, // The chosen entry destroys something: the panel asks for a second Enter.
	Running = 3, // The panel sent the chosen entry to its provider, and waits for what it gives.
	Result  = 4, // The panel shows what the entry gave: a short result, or an error.
}

// What an entry is. The list says it in words at the right of each row.
Entry_Kind :: enum u8 {
	Window       = 0, // A window: the choice brings it to the front.
	Program      = 1, // A program of the table of the programs: the choice starts it.
	Close_Window = 2, // The close of a window: the choice stops its program, after a second Enter.
	Command      = 3, // A command of the palette provider: the provider runs it.
	Export       = 4, // An export of a module or of a service, which the palette provider calls.
}

// The facts of an entry that are true or false.
Entry_Flag :: enum u8 {
	Destroys        = 0, // The entry destroys something.
	Needs_Arguments = 1, // The entry has parameters: the panel cannot run it, and opens it in the window of its provider.
}
Entry_Flags :: bit_set[Entry_Flag;u8]

// The one fact that the mark of an entry says (docs/DESIGN.md, "Palette").
Entry_Mark :: enum u8 {
	None       = 0, // No mark.
	Has_Window = 1, // A program that has a window now.
	No_Window  = 2, // A program that has no window now.
	Has_Focus  = 3, // The window that has the focus.
	Destroys   = 4, // The entry destroys something.
	Window     = 5, // A window that has not the focus.
}

NAME_CAPACITY :: 64 // The bytes of the name of an entry. A longer name is not listed: a name is whole or absent.
ENTRY_CAPACITY :: 512 // The entries of a list: the programs, the windows with their closes, and the entries of a provider.
ROW_CAPACITY :: 128 // The rows of the list: the entries that match and the headings of the groups.
RECENT_CAPACITY :: 16 // The chosen entries that the panel remembers, the newest first.
RECENT_ROWS :: 5 // The rows of the group "recent" when no letter is typed.
LIST_ROWS :: 12 // The rows that the panel shows at once.
PAGE_ROWS :: LIST_ROWS - 1 // The rows that Page Up and Page Down move the choice by: one row stays as the landmark.
TYPED_CAPACITY :: line_editor.QUERY_LIMIT // The bytes of the typed part: a longer one matches no name.
NO_ROW :: -1 // No row: an empty list has no choice, and a pointer over no row is on no row.

#assert(TYPED_CAPACITY <= line_editor.LINE_CAPACITY)
#assert(ROW_CAPACITY >= line_editor.RANKED_CAPACITY)
#assert(ENTRY_CAPACITY >= palette_table.ENTRY_CAPACITY + 128)
#assert(NAME_CAPACITY == palette_table.NAME_CAPACITY)

// One entry of the palette: a thing that the input can choose.
Entry :: struct {
	kind:        Entry_Kind, // What the entry is.
	mark:        Entry_Mark, // The fact of its mark.
	recent:      u8, // 0: not chosen lately. Else its age among the remembered choices: 1 is the newest.
	name_length: u8, // The bytes of `name` in use.
	flags:       Entry_Flags, // Its facts.
	windows:     u8, // A program: the windows that it has now.
	number:      u32, // For the owner of the source: the index of the thing in its own table. An entry of a provider: its index in the snapshot of the list.
	name:        [NAME_CAPACITY]u8, // The name that the list shows and that the typed part matches.
}

// entry_name gives the name of an entry. It is valid while the entry is.
entry_name :: proc "contextless" (entry: ^Entry) -> string {
	return string(entry.name[:min(int(entry.name_length), NAME_CAPACITY)])
}

// entry_destroys says if an entry destroys something: the panel asks for a
// second Enter before it runs.
entry_destroys :: proc "contextless" (entry: ^Entry) -> bool {
	return entry.kind == .Close_Window || .Destroys in entry.flags && .Needs_Arguments not_in entry.flags
}

// entry_of_provider says if a palette provider gave the entry.
entry_of_provider :: proc "contextless" (entry: ^Entry) -> bool {
	return entry.kind == .Command || entry.kind == .Export
}

// A window, as the owner of the client table gives it to entries_collect.
Window :: struct {
	title:  string, // The title of the window.
	number: u32, // The index of the window in the table of its owner.
	focus:  bool, // The window has the focus.
}

// What a row of the list is.
Row_Kind :: enum u8 {
	Entry            = 0, // An entry: the input can choose it.
	Heading_Recent   = 1, // The heading of the entries that the input chose lately.
	Heading_Windows  = 2, // The heading of the windows.
	Heading_Programs = 3, // The heading of the programs.
}

// One row of the list, in the order of the screen.
Row :: struct {
	kind:   Row_Kind, // An entry or a heading.
	entry:  u16, // An entry row: its index in the entries.
	places: line_editor.Match_Places, // An entry row: the bytes of its name that the typed part matched.
}

// A choice that the panel remembers.
Recent :: struct {
	kind:        Entry_Kind, // The kind of the chosen entry.
	name_length: u8, // The bytes of `name` in use.
	name:        [NAME_CAPACITY]u8, // Its name.
}

// What the list knows of the palette provider.
Provider_State :: enum u8 {
	Absent  = 0, // No program gives entries: the list has the programs and the windows only.
	Ready   = 1, // The snapshot of the list holds the entries of the provider.
	Refused = 2, // The table of the provider failed a check: the list has the programs and the windows only.
}

// The entries of each source and their list for one typed part. The owner
// of a panel makes it, on any thread, and gives it to the panel.
List :: struct {
	entries:       [ENTRY_CAPACITY]Entry, // The entries of each source.
	entry_count:   int, // The entries in use.
	rows:          [ROW_CAPACITY]Row, // The list for the typed part, the best match first.
	row_count:     int, // The rows in use.
	matched_count: int, // The entries that match the typed part, shown or not.
	provider:      Provider_State, // What the list has of a provider.
	sequence:      u32, // For the owner: the number of the request that this list answers.
	snapshot:      palette_table.Snapshot, // The checked copy of the table of the provider.
	// The memory of one ranking. It is here and not on a stack: a thread
	// with a small stack runs the ranking.
	candidates:    [ENTRY_CAPACITY]line_editor.Candidate,
	ranked:        [line_editor.RANKED_CAPACITY]line_editor.Ranked,
}

// What a provider gave for the chosen entry, as the panel shows it: a
// checked copy of the result area of the table.
Result :: struct {
	outcome:     palette_table.Outcome, // Shown_In_Panel, Failed or Refused.
	kind:        palette_table.Value_Kind, // The kind of the value.
	count:       int, // The bytes of `runs` in use.
	runs:        [palette_table.RESULT_CAPACITY]u8, // The lines of the result, as runs.
}

// The panel: all that the palette keeps, in the memory of its owner.
Panel :: struct {
	state:         State, // Closed, or what the panel asks of the input.
	line:          line_editor.Line, // The typed part and its caret.
	list:          ^List, // The entries and their list. The owner sets it before each other call.
	choice:        int, // The chosen row, or NO_ROW.
	first_row:     int, // The first row that the panel shows.
	pressed_row:   int, // The row where the left button of the pointer went down, until it goes up; or NO_ROW.
	recents:       [RECENT_CAPACITY]Recent, // The chosen entries, the newest first.
	recent_count:  int, // The remembered choices in use.
	sent_name:     [NAME_CAPACITY]u8, // Running and Result: the name of the entry that the panel sent.
	sent_length:   int, // The bytes of `sent_name` in use.
	result:        Result, // Result: what the entry gave.
}

// typed_text gives the typed part.
typed_text :: proc "contextless" (panel: ^Panel) -> string {
	return line_editor.line_text(&panel.line)
}

// entry_add appends one entry. A name that is empty or longer than
// NAME_CAPACITY is not listed, and a full table takes no more entry.
@(private)
entry_add :: proc "contextless" (list: ^List, recents: []Recent, added: Entry, name_start, name_end: string) {
	length := len(name_start) + len(name_end)
	if length == 0 || length > NAME_CAPACITY || list.entry_count >= ENTRY_CAPACITY {
		return
	}
	entry := &list.entries[list.entry_count]
	entry^ = added
	entry.name_length = u8(length)
	copy(entry.name[:], name_start)
	copy(entry.name[len(name_start):], name_end)
	entry.recent = recent_age_in(recents, entry.kind, entry_name(entry))
	list.entry_count += 1
}

CLOSE_NAME_START :: "close " // The start of the name of the close of a window: "close plasma".

// list_collect makes the entries of a list again from the sources: the
// windows, the front one first; the names of the programs, in the order of
// their table; the close of each window; then the entries of the palette
// provider. table is the mapping of the table of the provider, or nil with
// no provider: the list copies it and checks the copy
// (palette_table.snapshot_take), and reads only the copy after that. A
// table that fails gives a list with no entry of a provider, and its
// problem. recents: the choices that the panel remembers.
list_collect :: proc "contextless" (list: ^List, recents: []Recent, program_names: []string, windows: []Window, table: []u8) -> (problem: palette_table.Problem, problem_index: int) {
	list.entry_count = 0
	list.provider = .Absent
	for window in windows {
		entry_add(list, recents, {kind = .Window, mark = window.focus ? Entry_Mark.Has_Focus : Entry_Mark.Window, number = window.number}, window.title, "")
	}
	for name, index in program_names {
		count := 0
		for window in windows {
			if window.title == name {
				count += 1
			}
		}
		entry_add(list, recents, {kind = .Program, mark = count > 0 ? Entry_Mark.Has_Window : Entry_Mark.No_Window, windows = u8(min(count, 255)), number = u32(index)}, name, "")
	}
	for window in windows {
		entry_add(list, recents, {kind = .Close_Window, mark = .Destroys, flags = {.Destroys}, number = window.number}, CLOSE_NAME_START, window.title)
	}
	if table == nil {
		list.snapshot.entry_count = 0
		return .None, 0
	}
	problem, problem_index = palette_table.snapshot_take(table, &list.snapshot)
	if problem != .None {
		list.provider = .Refused
		return
	}
	list.provider = .Ready
	for &given, index in list.snapshot.entries[:list.snapshot.entry_count] {
		flags: Entry_Flags
		if .Destroys in given.flags {
			flags += {.Destroys}
		}
		if given.parameter_count > 0 {
			flags += {.Needs_Arguments}
		}
		destroys := .Destroys in flags && .Needs_Arguments not_in flags
		entry_add(list, recents, {kind = given.kind == .Command ? Entry_Kind.Command : Entry_Kind.Export, mark = destroys ? Entry_Mark.Destroys : Entry_Mark.None, flags = flags, number = u32(index)}, string(given.name[:given.name_length]), "")
	}
	return .None, 0
}

// entries_collect makes the entries of the list of a panel again from the
// two sources of the compositor, with no provider, then the list for the
// typed part: the form for an owner that ranks on its own thread.
//
// A panel that asked for a second Enter goes back to the search: the entry
// that it showed can be gone.
entries_collect :: proc "contextless" (panel: ^Panel, program_names: []string, windows: []Window) {
	list_collect(panel.list, panel.recents[:clamp(panel.recent_count, 0, RECENT_CAPACITY)], program_names, windows, nil)
	list_build(panel)
}

// list_build makes the list of a panel again for its typed part, and
// chooses its first entry.
list_build :: proc "contextless" (panel: ^Panel) {
	list_rank(panel.list, typed_text(panel))
	panel_adopt(panel, panel.list)
}

// panel_adopt gives a panel a list that its owner made, and chooses its
// first entry. A panel that asked for a second Enter goes back to the
// search: the entry that it showed can be gone.
panel_adopt :: proc "contextless" (panel: ^Panel, list: ^List) {
	panel.list = list
	if panel.state == .Confirm {
		panel.state = .Search
	}
	panel.first_row = 0
	panel.pressed_row = NO_ROW
	panel.choice = NO_ROW
	for row, index in list.rows[:list.row_count] {
		if row.kind == .Entry {
			panel.choice = index
			break
		}
	}
}

// kind_tie_order gives the place of a kind among entries of one score: a
// window first, because to reach a window is the most frequent act; then a
// program, a command, an export; the close of a window last.
@(private)
kind_tie_order :: proc "contextless" (kind: Entry_Kind) -> u32 {
	switch kind {
	case .Window:
		return 0
	case .Program:
		return 1
	case .Command:
		return 2
	case .Export:
		return 3
	case .Close_Window:
		return 4
	}
	return 5
}

// tie_order gives the order of an entry among the entries with the same
// score: first the entries chosen lately, the newest first; then the kind;
// then the order of the table. A better match always comes before a recent
// one: the ranking reads this number only for equal scores.
tie_order :: proc "contextless" (entry: ^Entry, index: int) -> u32 {
	recent := entry.recent != 0 ? u32(entry.recent) - 1 : RECENT_CAPACITY
	return recent << 24 | kind_tie_order(entry.kind) << 16 | u32(index) & 0xFFFF
}

// list_rank makes the rows of a list for a typed part.
//
// With a typed part: one list, the best match first (the fuzzy match of
// support/line_editor), with no heading: the best match is the first row.
// With no typed part: three groups, each under its heading: the entries
// chosen lately, the windows with the front one first, the programs in the
// order of their table. A group with no entry is absent. The entries that
// destroy and the entries of a provider show only for a typed part.
list_rank :: proc "contextless" (list: ^List, query: string) {
	list.row_count = 0
	list.matched_count = 0
	if len(query) == 0 {
		// The entries chosen lately, by their age.
		heading_shown := false
		for age in 1 ..= RECENT_ROWS {
			for &entry, index in list.entries[:list.entry_count] {
				if int(entry.recent) != age || entry_destroys(&entry) {
					continue
				}
				if !heading_shown {
					row_add(list, {kind = .Heading_Recent})
					heading_shown = true
				}
				row_add(list, {kind = .Entry, entry = u16(index)})
			}
		}
		for kind in ([2]Entry_Kind{.Window, .Program}) {
			heading_shown = false
			for &entry, index in list.entries[:list.entry_count] {
				if entry.kind != kind {
					continue
				}
				if !heading_shown {
					row_add(list, {kind = kind == .Window ? Row_Kind.Heading_Windows : Row_Kind.Heading_Programs})
					heading_shown = true
				}
				row_add(list, {kind = .Entry, entry = u16(index)})
				list.matched_count += 1
			}
		}
		return
	}
	for &entry, index in list.entries[:list.entry_count] {
		list.candidates[index] = {name = entry_name(&entry), tie_order = tie_order(&entry, index), number = u32(index)}
	}
	kept, matched := line_editor.rank_candidates(query, list.candidates[:list.entry_count], list.ranked[:])
	list.matched_count = matched
	for ranked in list.ranked[:kept] {
		row_add(list, {kind = .Entry, entry = u16(ranked.candidate), places = ranked.places})
	}
}

@(private)
row_add :: proc "contextless" (list: ^List, row: Row) {
	if list.row_count < ROW_CAPACITY {
		list.rows[list.row_count] = row
		list.row_count += 1
	}
}

// row_is_entry says if a row of the list is an entry: a row that the input
// can choose.
row_is_entry :: proc "contextless" (panel: ^Panel, row: int) -> bool {
	return panel.list != nil && row >= 0 && row < panel.list.row_count && panel.list.rows[row].kind == .Entry
}

// chosen_entry gives the entry of the chosen row, or nil when the list has
// no entry.
chosen_entry :: proc "contextless" (panel: ^Panel) -> ^Entry {
	if !row_is_entry(panel, panel.choice) {
		return nil
	}
	index := int(panel.list.rows[panel.choice].entry)
	if index >= panel.list.entry_count {
		return nil
	}
	return &panel.list.entries[index]
}

// A move of the choice.
Choice_Step :: enum u8 {
	Previous, // The entry before; from the first one, the last one.
	Next, // The entry after; from the last one, the first one.
	Page_Before, // PAGE_ROWS rows up, and no farther than the first entry.
	Page_After, // PAGE_ROWS rows down, and no farther than the last entry.
}

// choice_move moves the choice over the entries of the list: a heading is
// never chosen. It gives true when the choice changed. The rows that the
// panel shows then hold the choice.
choice_move :: proc "contextless" (panel: ^Panel, step: Choice_Step) -> bool {
	if !row_is_entry(panel, panel.choice) {
		return false
	}
	before := panel.choice
	count := panel.list.row_count
	switch step {
	case .Previous, .Next:
		// At most one turn of the list: it has an entry, the chosen one.
		direction := step == .Next ? 1 : count - 1
		row := (before + direction) % count
		for row != before && !row_is_entry(panel, row) {
			row = (row + direction) % count
		}
		panel.choice = row
	case .Page_Before, .Page_After:
		direction := step == .Page_After ? 1 : -1
		row := clamp(before + direction * PAGE_ROWS, 0, count - 1)
		// A heading at the place: the entry nearest to it, first farther
		// in the direction of the move, then back toward the start.
		for row >= 0 && row < count && !row_is_entry(panel, row) {
			row += direction
		}
		for (row < 0 || row >= count || !row_is_entry(panel, row)) && row != before {
			row = clamp(row, 0, count - 1) - direction
		}
		panel.choice = row
	}
	view_follow_choice(panel)
	return panel.choice != before
}

// choice_set chooses a row that the pointer is over. It gives true when
// the choice changed.
choice_set :: proc "contextless" (panel: ^Panel, row: int) -> bool {
	if !row_is_entry(panel, row) || row == panel.choice {
		return false
	}
	panel.choice = row
	view_follow_choice(panel)
	return true
}

// view_follow_choice moves the rows that the panel shows so that they hold
// the chosen row, and the heading right over it when the choice is the
// first row shown: a group keeps its name on the screen.
view_follow_choice :: proc "contextless" (panel: ^Panel) {
	if panel.choice < 0 {
		panel.first_row = 0
		return
	}
	if panel.choice < panel.first_row {
		panel.first_row = panel.choice
	}
	if panel.choice >= panel.first_row + LIST_ROWS {
		panel.first_row = panel.choice - LIST_ROWS + 1
	}
	if panel.first_row == panel.choice && panel.choice > 0 && panel.list.rows[panel.choice - 1].kind != .Entry {
		panel.first_row = panel.choice - 1
	}
	panel.first_row = clamp(panel.first_row, 0, max(panel.list.row_count - 1, 0))
}

// recent_age gives the age of a choice among the remembered ones: 1 is the
// newest; 0: the panel does not remember it.
recent_age :: proc "contextless" (panel: ^Panel, kind: Entry_Kind, name: string) -> u8 {
	return recent_age_in(panel.recents[:clamp(panel.recent_count, 0, RECENT_CAPACITY)], kind, name)
}

// recent_age_in is recent_age over a copy of the remembered choices.
recent_age_in :: proc "contextless" (recents: []Recent, kind: Entry_Kind, name: string) -> u8 {
	for &recent, index in recents {
		if recent.kind == kind && string(recent.name[:min(int(recent.name_length), NAME_CAPACITY)]) == name {
			return u8(index + 1)
		}
	}
	return 0
}

// recent_note remembers that the input chose an entry: it becomes the
// newest choice, and the oldest one leaves when the table is full. An
// entry that destroys is not remembered: its thing is gone after it. The
// memory is the memory of the panel only: a restart of the machine loses it.
recent_note :: proc "contextless" (panel: ^Panel, entry: ^Entry) {
	if entry_destroys(entry) {
		return
	}
	noted := Recent{kind = entry.kind, name_length = entry.name_length, name = entry.name}
	count := min(panel.recent_count, RECENT_CAPACITY)
	// The place that the choice had, or the last place of a full table.
	place := count
	if age := recent_age(panel, entry.kind, entry_name(entry)); age != 0 {
		place = int(age) - 1
	} else if count == RECENT_CAPACITY {
		place = RECENT_CAPACITY - 1
	} else {
		panel.recent_count = count + 1
	}
	for index := place; index > 0; index -= 1 {
		panel.recents[index] = panel.recents[index - 1]
	}
	panel.recents[0] = noted
}
