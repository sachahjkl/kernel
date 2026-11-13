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
// A panel holds texts of its own entries, and its ranking points at them:
// a panel is never copied.
package palette

import "support:line_editor"

// The state of the panel. One value says all of it: no state is a pair of
// flags.
State :: enum u8 {
	Closed  = 0, // The panel is not on the screen. The keys go to the window that has the focus.
	Search  = 1, // The panel is open: the input types a part of a name and moves the choice.
	Confirm = 2, // The chosen entry destroys something: the panel asks for a second Enter.
}

// What an entry is. The list says it in words at the right of each row.
Entry_Kind :: enum u8 {
	Window       = 0, // A window: the choice brings it to the front.
	Program      = 1, // A program of the table of the programs: the choice starts it.
	Close_Window = 2, // The close of a window: the choice stops its program, after a second Enter.
}

// The one fact that the mark of an entry says (docs/DESIGN.md, "Palette").
Entry_Mark :: enum u8 {
	None       = 0, // No mark.
	Has_Window = 1, // A program that has a window now.
	No_Window  = 2, // A program that has no window now.
	Has_Focus  = 3, // The window that has the focus.
	Destroys   = 4, // The entry destroys something.
}

NAME_CAPACITY :: 64 // The bytes of the name of an entry. A longer name is not listed: a name is whole or absent.
ENTRY_CAPACITY :: 256 // The entries of a panel.
ROW_CAPACITY :: 128 // The rows of the list: the entries that match and the headings of the groups.
RECENT_CAPACITY :: 16 // The chosen entries that the panel remembers, the newest first.
RECENT_ROWS :: 5 // The rows of the group "recent" when no letter is typed.
LIST_ROWS :: 12 // The rows that the panel shows at once.
PAGE_ROWS :: LIST_ROWS - 1 // The rows that Page Up and Page Down move the choice by: one row stays as the landmark.
TYPED_CAPACITY :: line_editor.QUERY_LIMIT // The bytes of the typed part: a longer one matches no name.
NO_ROW :: -1 // No row: an empty list has no choice, and a pointer over no row is on no row.

#assert(TYPED_CAPACITY <= line_editor.LINE_CAPACITY)
#assert(ROW_CAPACITY >= line_editor.RANKED_CAPACITY)

// One entry of the palette: a thing that the input can choose.
Entry :: struct {
	kind:        Entry_Kind, // What the entry is.
	mark:        Entry_Mark, // The fact of its mark.
	recent:      u8, // 0: not chosen lately. Else its age among the remembered choices: 1 is the newest.
	name_length: u8, // The bytes of `name` in use.
	number:      u32, // For the owner of the source: the index of the thing in its own table.
	name:        [NAME_CAPACITY]u8, // The name that the list shows and that the typed part matches.
}

// entry_name gives the name of an entry. It is valid while the entry is.
entry_name :: proc "contextless" (entry: ^Entry) -> string {
	return string(entry.name[:min(int(entry.name_length), NAME_CAPACITY)])
}

// entry_destroys says if an entry destroys something: the panel asks for a
// second Enter before it runs.
entry_destroys :: proc "contextless" (entry: ^Entry) -> bool {
	return entry.kind == .Close_Window
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

// The panel: all that the palette keeps, in the memory of its owner.
Panel :: struct {
	state:         State, // Closed, or what the panel asks of the input.
	line:          line_editor.Line, // The typed part and its caret.
	entries:       [ENTRY_CAPACITY]Entry, // The entries of each source.
	entry_count:   int, // The entries in use.
	rows:          [ROW_CAPACITY]Row, // The list for the typed part, the best match first.
	row_count:     int, // The rows in use.
	matched_count: int, // The entries that match the typed part, shown or not.
	choice:        int, // The chosen row, or NO_ROW.
	first_row:     int, // The first row that the panel shows.
	pressed_row:   int, // The row where the left button of the pointer went down, until it goes up; or NO_ROW.
	recents:       [RECENT_CAPACITY]Recent, // The chosen entries, the newest first.
	recent_count:  int, // The remembered choices in use.
	// The memory of one ranking. It is here and not on the stack of the
	// caller: the loop of a program with a small stack runs the ranking.
	candidates:    [ENTRY_CAPACITY]line_editor.Candidate,
	ranked:        [line_editor.RANKED_CAPACITY]line_editor.Ranked,
}

// typed_text gives the typed part.
typed_text :: proc "contextless" (panel: ^Panel) -> string {
	return line_editor.line_text(&panel.line)
}

// entry_add appends one entry. A name that is empty or longer than
// NAME_CAPACITY is not listed, and a full table takes no more entry.
@(private)
entry_add :: proc "contextless" (panel: ^Panel, kind: Entry_Kind, mark: Entry_Mark, number: u32, name_start, name_end: string) {
	length := len(name_start) + len(name_end)
	if length == 0 || length > NAME_CAPACITY || panel.entry_count >= ENTRY_CAPACITY {
		return
	}
	entry := &panel.entries[panel.entry_count]
	entry^ = {kind = kind, mark = mark, number = number, name_length = u8(length)}
	copy(entry.name[:], name_start)
	copy(entry.name[len(name_start):], name_end)
	entry.recent = recent_age(panel, kind, entry_name(entry))
	panel.entry_count += 1
}

CLOSE_NAME_START :: "close " // The start of the name of the close of a window: "close plasma".

// entries_collect makes the entries again from the two sources of the
// owner: the windows, the front one first, and the names of the programs,
// in the order of their table. Each window also gives the entry of its
// close. Then it makes the list again for the typed part. The owner calls
// it when a source changes, not at a key: the open of the panel then finds
// the list ready.
//
// A panel that asked for a second Enter goes back to the search: the entry
// that it showed can be gone.
entries_collect :: proc "contextless" (panel: ^Panel, program_names: []string, windows: []Window) {
	panel.entry_count = 0
	for window in windows {
		entry_add(panel, .Window, window.focus ? Entry_Mark.Has_Focus : Entry_Mark.None, window.number, window.title, "")
	}
	for name, index in program_names {
		mark := Entry_Mark.No_Window
		for window in windows {
			if window.title == name {
				mark = .Has_Window
				break
			}
		}
		entry_add(panel, .Program, mark, u32(index), name, "")
	}
	for window in windows {
		entry_add(panel, .Close_Window, .Destroys, window.number, CLOSE_NAME_START, window.title)
	}
	if panel.state == .Confirm {
		panel.state = .Search
	}
	list_build(panel)
}

// kind_tie_order gives the place of a kind among entries of one score: a
// window first, because to reach a window is the most frequent act; the
// entry that destroys last.
@(private)
kind_tie_order :: proc "contextless" (kind: Entry_Kind) -> u32 {
	switch kind {
	case .Window:
		return 0
	case .Program:
		return 1
	case .Close_Window:
		return 2
	}
	return 3
}

// tie_order gives the order of an entry among the entries with the same
// score: first the entries chosen lately, the newest first; then the kind;
// then the order of the table. A better match always comes before a recent
// one: the ranking reads this number only for equal scores.
tie_order :: proc "contextless" (entry: ^Entry, index: int) -> u32 {
	recent := entry.recent != 0 ? u32(entry.recent) - 1 : RECENT_CAPACITY
	return recent << 24 | kind_tie_order(entry.kind) << 16 | u32(index) & 0xFFFF
}

// list_build makes the list for the typed part, and chooses its first
// entry.
//
// With a typed part: one list, the best match first (the fuzzy match of
// support/line_editor), with no heading: the best match is the first row.
// With no typed part: three groups, each under its heading: the entries
// chosen lately, the windows with the front one first, the programs in the
// order of their table. A group with no entry is absent. The entries that
// destroy show only for a typed part.
list_build :: proc "contextless" (panel: ^Panel) {
	panel.row_count = 0
	panel.matched_count = 0
	panel.first_row = 0
	panel.pressed_row = NO_ROW
	query := typed_text(panel)
	if len(query) == 0 {
		// The entries chosen lately, by their age.
		heading_shown := false
		for age in 1 ..= RECENT_ROWS {
			for &entry, index in panel.entries[:panel.entry_count] {
				if int(entry.recent) != age || entry_destroys(&entry) {
					continue
				}
				if !heading_shown {
					row_add(panel, {kind = .Heading_Recent})
					heading_shown = true
				}
				row_add(panel, {kind = .Entry, entry = u16(index)})
			}
		}
		for kind in ([2]Entry_Kind{.Window, .Program}) {
			heading_shown = false
			for &entry, index in panel.entries[:panel.entry_count] {
				if entry.kind != kind {
					continue
				}
				if !heading_shown {
					row_add(panel, {kind = kind == .Window ? Row_Kind.Heading_Windows : Row_Kind.Heading_Programs})
					heading_shown = true
				}
				row_add(panel, {kind = .Entry, entry = u16(index)})
				panel.matched_count += 1
			}
		}
	} else {
		for &entry, index in panel.entries[:panel.entry_count] {
			panel.candidates[index] = {name = entry_name(&entry), tie_order = tie_order(&entry, index), number = u32(index)}
		}
		kept, matched := line_editor.rank_candidates(query, panel.candidates[:panel.entry_count], panel.ranked[:])
		panel.matched_count = matched
		for ranked in panel.ranked[:kept] {
			row_add(panel, {kind = .Entry, entry = u16(ranked.candidate), places = ranked.places})
		}
	}
	panel.choice = NO_ROW
	for row, index in panel.rows[:panel.row_count] {
		if row.kind == .Entry {
			panel.choice = index
			break
		}
	}
}

@(private)
row_add :: proc "contextless" (panel: ^Panel, row: Row) {
	if panel.row_count < ROW_CAPACITY {
		panel.rows[panel.row_count] = row
		panel.row_count += 1
	}
}

// row_is_entry says if a row of the list is an entry: a row that the input
// can choose.
row_is_entry :: proc "contextless" (panel: ^Panel, row: int) -> bool {
	return row >= 0 && row < panel.row_count && panel.rows[row].kind == .Entry
}

// chosen_entry gives the entry of the chosen row, or nil when the list has
// no entry.
chosen_entry :: proc "contextless" (panel: ^Panel) -> ^Entry {
	if !row_is_entry(panel, panel.choice) {
		return nil
	}
	index := int(panel.rows[panel.choice].entry)
	if index >= panel.entry_count {
		return nil
	}
	return &panel.entries[index]
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
	count := panel.row_count
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
	if panel.first_row == panel.choice && panel.choice > 0 && panel.rows[panel.choice - 1].kind != .Entry {
		panel.first_row = panel.choice - 1
	}
	panel.first_row = clamp(panel.first_row, 0, max(panel.row_count - 1, 0))
}

// recent_age gives the age of a choice among the remembered ones: 1 is the
// newest; 0: the panel does not remember it.
recent_age :: proc "contextless" (panel: ^Panel, kind: Entry_Kind, name: string) -> u8 {
	for &recent, index in panel.recents[:min(panel.recent_count, RECENT_CAPACITY)] {
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
