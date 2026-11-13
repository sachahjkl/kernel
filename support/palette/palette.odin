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
	Arguments = 5, // The input band is the form of the chosen entry: one field for each of its parameters.
}

// What an entry is. The list says it in words at the right of each row.
Entry_Kind :: enum u8 {
	Window       = 0, // A window: the choice brings it to the front.
	Program      = 1, // A program of the table of the programs: the choice starts it.
	Close_Window = 2, // The close of a window: the choice stops its program, after a second Enter.
	Command      = 3, // A command of the palette provider: the provider runs it.
	Export       = 4, // An export of a module or of a service, which the palette provider calls.
	Setting      = 5, // One value of one setting of the machine: the palette provider sets it.
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
	return entry.kind == .Command || entry.kind == .Export || entry.kind == .Setting
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
	query:         [TYPED_CAPACITY]u8, // The typed part that the rows answer.
	query_length:  int, // The bytes of `query` in use.
	// A hash of all that the panel shows of the list: the typed part, the
	// counts, the provider, and each row with its entry. Two lists with one
	// hash show the same rows: the panel adopts the second one with no
	// change of its choice and no new frame.
	content:       u64,
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
	// A list that came for the same typed part moved the choice to another
	// entry, and no frame showed it yet: Enter runs nothing until the owner
	// drew the panel (panel_drawn). The palette runs the row that is drawn.
	choice_undrawn: bool,
	// The typed part changed since the list that the panel shows (typed_edit
	// sets it): the list for the typed part of now is a list for a new typed
	// part, also when the text came back to what it was. Its first entry is
	// chosen, and the adoption of that list clears the bit.
	typed_since_list: bool,
	recents:       [RECENT_CAPACITY]Recent, // The chosen entries, the newest first.
	recent_count:  int, // The remembered choices in use.
	form:          Form, // Arguments: the fields of the chosen entry.
	settings_in_use: [palette_table.PARAMETER_CAPACITY]u8, // For the owner: the value in use of each setting of the machine, by its number: the mark of a Setting entry.
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
		kind := Entry_Kind.Export
		#partial switch given.kind {
		case .Command:
			kind = .Command
		case .Setting:
			kind = .Setting
		}
		entry_add(list, recents, {kind = kind, mark = destroys ? Entry_Mark.Destroys : Entry_Mark.None, flags = flags, number = u32(index)}, string(given.name[:given.name_length]), "")
	}
	return .None, 0
}

// entries_collect makes the entries of the list of a panel again from the
// two sources of the compositor, with no provider, then the list for the
// typed part: the form for an owner that ranks on its own thread.
//
// A panel that asked for a second Enter goes back to the search: the entry
// that it showed can be gone.
entries_collect :: proc "contextless" (panel: ^Panel, program_names: []string, windows: []Window) -> Adoption {
	// The list is made in its own memory: what the panel showed is kept
	// first.
	shown := panel_shown(panel)
	list_collect(panel.list, panel.recents[:clamp(panel.recent_count, 0, RECENT_CAPACITY)], program_names, windows, nil)
	list_rank(panel.list, typed_text(panel))
	return panel_adopt_after(panel, panel.list, shown)
}

// list_build makes the list of a panel again for its typed part, in its
// own memory, and adopts it (panel_adopt).
list_build :: proc "contextless" (panel: ^Panel) -> Adoption {
	shown := panel_shown(panel)
	list_rank(panel.list, typed_text(panel))
	return panel_adopt_after(panel, panel.list, shown)
}

// What the panel showed before a new list: the typed part and the content
// of its list, and the chosen entry by what it is, not by its row.
Shown :: struct {
	listed:        bool, // The panel had a list.
	query:         [TYPED_CAPACITY]u8, // The typed part of that list.
	query_length:  int,
	content:       u64, // List.content of that list.
	chosen:        bool, // The list had a chosen entry.
	kind:          Entry_Kind, // The kind of the chosen entry.
	name:          [NAME_CAPACITY]u8, // Its name.
	name_length:   int,
}

// panel_shown gives what the panel shows now.
panel_shown :: proc "contextless" (panel: ^Panel) -> (shown: Shown) {
	list := panel.list
	if list == nil {
		return shown
	}
	shown.listed = true
	shown.query_length = copy(shown.query[:], list.query[:clamp(list.query_length, 0, TYPED_CAPACITY)])
	shown.content = list.content
	if entry := chosen_entry(panel); entry != nil {
		shown.chosen = true
		shown.kind = entry.kind
		shown.name_length = copy(shown.name[:], entry_name(entry))
	}
	return shown
}

// What the adoption of a list did to the choice of a panel.
Adoption :: enum u8 {
	Same  = 0, // The list shows what the list before showed: nothing changed, and no frame is needed.
	Kept  = 1, // The rows changed. The chosen entry is still chosen, at the row that it has now; or the list answers a new typed part, or the panel is closed, and the first entry is chosen.
	Moved = 2, // The list answers the same typed part, and the chosen entry left it: the first entry is chosen now. Enter runs nothing before a frame shows it.
}

// panel_adopt gives a panel a list that its owner made.
//
// The choice is an entry, not a row. When the list answers the typed part
// that the list before answered, the chosen entry stays chosen, at
// whatever row it has now, and the rows that the panel shows follow it.
// Only when that entry left the list does the choice go to the first
// entry: the panel then waits for a frame before Enter runs anything
// (choice_undrawn), and a panel that asked for a second Enter goes back to
// the search. A list for a new typed part chooses its first entry: it is
// the answer to the keys of the input, and its best match is what Enter
// means. A list is for a new typed part when its text differs from the
// text of the list before, and also when a key changed the typed part
// since the list before (Panel.typed_since_list): a character and a
// Backspace in one batch leave the same text, and the list that answers
// them still chooses its first entry. A panel with a form keeps its
// question: the form holds its own copy of its entry.
panel_adopt :: proc "contextless" (panel: ^Panel, list: ^List) -> Adoption {
	return panel_adopt_after(panel, list, panel_shown(panel))
}

// panel_adopt_after is panel_adopt for a list that was made in the memory
// of the list before: shown is what the panel showed, taken before.
panel_adopt_after :: proc "contextless" (panel: ^Panel, list: ^List, shown_before: Shown) -> Adoption {
	// A copy that has an address: a parameter is not sliced.
	shown := shown_before
	panel.list = list
	panel.pressed_row = NO_ROW
	list_query := string(list.query[:clamp(list.query_length, 0, TYPED_CAPACITY)])
	// Keys changed the typed part since the list shown: this list answers
	// them, also when the text is again what that list answered (a
	// character, then Backspace). The choice of the list before was made
	// for other keys, so the first entry is chosen, as for each new typed
	// part. The bit ends with the list of the typed part of now: an older
	// list that arrives late does not end it.
	typed_since := panel.typed_since_list
	if list_query == typed_text(panel) {
		panel.typed_since_list = false
	}
	same_typed_part := !typed_since && panel.state != .Closed && shown.listed && string(shown.query[:shown.query_length]) == list_query
	if same_typed_part && shown.content == list.content {
		return .Same
	}
	if same_typed_part && shown.chosen {
		name := string(shown.name[:shown.name_length])
		for row, index in list.rows[:list.row_count] {
			if row.kind != .Entry || int(row.entry) >= list.entry_count {
				continue
			}
			entry := &list.entries[row.entry]
			if entry.kind == shown.kind && entry_name(entry) == name {
				panel.choice = index
				view_follow_choice(panel)
				return .Kept
			}
		}
	}
	if panel.state == .Confirm && !panel.form.active {
		panel.state = .Search
	}
	panel.first_row = 0
	panel.choice = NO_ROW
	for row, index in list.rows[:list.row_count] {
		if row.kind == .Entry {
			panel.choice = index
			break
		}
	}
	if same_typed_part && shown.chosen {
		panel.choice_undrawn = true
		return .Moved
	}
	return .Kept
}

// panel_drawn tells the panel that a frame showed it as it is now: Enter
// runs the chosen entry again.
panel_drawn :: proc "contextless" (panel: ^Panel) {
	panel.choice_undrawn = false
}

// action_runs says if an action runs, sends or opens an entry: such an
// action does nothing while the choice is not drawn (Panel.choice_undrawn).
action_runs :: proc "contextless" (action: Action) -> bool {
	#partial switch action {
	case .Run, .Confirm, .Submit, .Submit_All, .Open_In_Console:
		return true
	}
	return false
}

// kind_tie_order gives the place of a kind among entries of one score: a
// window first, because to reach a window is the most frequent act; then a
// program, a setting, a command, an export; the close of a window last.
@(private)
kind_tie_order :: proc "contextless" (kind: Entry_Kind) -> u32 {
	switch kind {
	case .Window:
		return 0
	case .Program:
		return 1
	case .Setting:
		return 2
	case .Command:
		return 3
	case .Export:
		return 4
	case .Close_Window:
		return 5
	}
	return 6
}

// tie_order gives the order of an entry among the entries with the same
// score: first the entries chosen lately, the newest first; then the kind;
// then the order of the table. A better match always comes before a recent
// one: the ranking reads this number only for equal scores.
tie_order :: proc "contextless" (entry: ^Entry, index: int) -> u32 {
	recent := entry.recent != 0 ? u32(entry.recent) - 1 : RECENT_CAPACITY
	return recent << 24 | kind_tie_order(entry.kind) << 16 | u32(index) & 0xFFFF
}

// A first character of the typed part that restricts the kinds of the
// list (docs/DESIGN.md, "Palette").
Prefix :: enum u8 {
	None     = 0, // Each kind.
	Commands = 1, // ">": the commands and the exports.
	Windows  = 2, // "@": the windows and their closes.
	Settings = 3, // ":": the values of the settings.
	Manual   = 4, // "?": the programs; the choice opens the page of the manual of the program.
}

// prefix_of gives the prefix of a typed part, and the part after it: the
// part that the names match.
prefix_of :: proc "contextless" (typed: string) -> (prefix: Prefix, rest: string) {
	if len(typed) == 0 {
		return .None, typed
	}
	switch typed[0] {
	case '>':
		return .Commands, typed[1:]
	case '@':
		return .Windows, typed[1:]
	case ':':
		return .Settings, typed[1:]
	case '?':
		return .Manual, typed[1:]
	}
	return .None, typed
}

// prefix_words gives the word of a prefix: the input band shows it.
prefix_words :: proc "contextless" (prefix: Prefix) -> string {
	switch prefix {
	case .None:
		return ""
	case .Commands:
		return "commands"
	case .Windows:
		return "windows"
	case .Settings:
		return "settings"
	case .Manual:
		return "manual"
	}
	return ""
}

// prefix_admits says if a prefix lists a kind.
prefix_admits :: proc "contextless" (prefix: Prefix, kind: Entry_Kind) -> bool {
	switch prefix {
	case .None:
		return true
	case .Commands:
		return kind == .Command || kind == .Export
	case .Windows:
		return kind == .Window || kind == .Close_Window
	case .Settings:
		return kind == .Setting
	case .Manual:
		return kind == .Program
	}
	return false
}

// list_rank makes the rows of a list for a typed part. A prefix restricts
// the kinds; with a prefix alone, the list has each entry of its kinds, in
// the order of their tables.
//
// With a typed part: one list, the best match first (the fuzzy match of
// support/line_editor), with no heading: the best match is the first row.
// With no typed part: three groups, each under its heading: the entries
// chosen lately, the windows with the front one first, the programs in the
// order of their table. A group with no entry is absent. The entries that
// destroy and the entries of a provider show only for a typed part.
list_rank :: proc "contextless" (list: ^List, query: string) {
	list.query_length = copy(list.query[:], query)
	rows_rank(list, query)
	list.content = list_content(list)
}

// list_content gives the hash of what a panel shows of a list (FNV-1a, 64
// bits): the typed part, the counts, the state and the generation of the
// provider, and each row with the entry that it shows.
@(private)
list_content :: proc "contextless" (list: ^List) -> u64 {
	mix :: proc "contextless" (hash: u64, bytes: []u8) -> u64 {
		mixed := hash
		for value in bytes {
			mixed = (mixed ~ u64(value)) * 0x0000_0100_0000_01B3
		}
		return mixed
	}
	number :: proc "contextless" (hash: u64, value: u64) -> u64 {
		bytes := transmute([8]u8)value
		return mix(hash, bytes[:])
	}
	hash: u64 = 0xCBF2_9CE4_8422_2325
	hash = mix(hash, list.query[:clamp(list.query_length, 0, TYPED_CAPACITY)])
	hash = number(hash, u64(list.entry_count))
	hash = number(hash, u64(list.matched_count))
	hash = number(hash, u64(list.provider))
	hash = number(hash, u64(list.snapshot.generation))
	for row in list.rows[:list.row_count] {
		hash = number(hash, u64(row.kind))
		places := transmute(u128)row.places
		hash = number(hash, u64(places & 0xFFFF_FFFF_FFFF_FFFF))
		hash = number(hash, u64(places >> 64))
		if row.kind == .Entry && int(row.entry) < list.entry_count {
			entry := &list.entries[row.entry]
			flags := transmute(u8)entry.flags
			hash = number(hash, u64(entry.kind) | u64(entry.mark) << 8 | u64(flags) << 16 | u64(entry.windows) << 24 | u64(entry.number) << 32)
			hash = mix(hash, entry.name[:entry.name_length])
		}
	}
	return hash
}

// rows_rank makes the rows of list_rank.
@(private)
rows_rank :: proc "contextless" (list: ^List, query: string) {
	list.row_count = 0
	list.matched_count = 0
	prefix, rest := prefix_of(query)
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
	admitted := 0
	for &entry, index in list.entries[:list.entry_count] {
		if prefix_admits(prefix, entry.kind) {
			list.candidates[admitted] = {name = entry_name(&entry), tie_order = tie_order(&entry, index), number = u32(index)}
			admitted += 1
		}
	}
	kept, matched := line_editor.rank_candidates(rest, list.candidates[:admitted], list.ranked[:])
	list.matched_count = matched
	for ranked in list.ranked[:kept] {
		row_add(list, {kind = .Entry, entry = u16(list.candidates[ranked.candidate].number), places = ranked.places})
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
