package console

// The completion of the console: a list of names that opens under the
// line while the person types, and the search of the history.
//
// The console knows the names: its commands, the exports of the modules
// and services that it loaded or connected (from their descriptions), its
// variables, the modules of the boot image, the programs that run. It
// ranks them with the fuzzy match of support/line_editor, and gives the
// rows to show to its terminal (support/terminal, List_Row and List). The
// terminal owns the cells and draws the list over its text. The rows go
// through the text region of this console and its terminal, which no third
// program reads: the terminal already shows each name that help() prints.
//
// Only the first thread uses this file, and only while no line runs: the
// second thread changes the tables of names during a line, never between
// two lines.

import module "contract:module"
import op "contract:operation"
import "support:display"
import "support:line_editor"
import "support:system"
import terminal "support:terminal"

List_Mode :: enum u8 {
	Closed  = 0,
	Names   = 1, // The names that complete the name at the caret.
	History = 2, // The lines of the history that match a search.
}

// The names that one list reads. Today the console has at most 128
// commands, 8 services, 16 variables, the modules of the boot image and 64
// programs; a name past this count is not read.
CANDIDATE_CAPACITY :: 512
SEARCH_CAPACITY :: 64 // The bytes of a search of the history.
PROGRAM_NAME_CAPACITY :: 64

Completion :: struct {
	mode:           List_Mode,
	escaped:        bool, // Escape closed the list: the next character opens it again.
	list_changed:   bool, // The terminal does not show the list of this record yet.
	place:          line_editor.Completion_Context, // Names: where the caret was when the list was made.
	names:          Candidate_Table,
	ranked:         [line_editor.RANKED_CAPACITY]line_editor.Ranked,
	ranked_count:   int,
	matched_count:  int, // All the names that matched, kept in ranked or not.
	chosen:         int, // In ranked.
	first_shown:    int, // The first row of ranked that the terminal shows.
	search:         [SEARCH_CAPACITY]u8,
	search_count:   int,
	program_names:  [PROGRAM_NAME_CAPACITY]system.Name, // The programs that run, for a list in quotes.
	program_count:  int,
	// The names of the programs are kept for one quote: where it starts,
	// and the count of the lines that ran when they were read.
	programs_kept:  bool,
	programs_quote: int,
	programs_lines: u32,
	// The measure of the cost of one key: the longest ranking so far, and
	// the count of rankings.
	longest_ranking: u64, // Nanoseconds.
	rankings:       u64,
	// What the terminal shows under the line now, to send only a change.
	hint_shown:      [2 * terminal.RUN_LIMIT]u8, // The long form, then the short form.
	hint_count:      int,
	hint_long_count: int,
	hint_marked:     [terminal.Hint_Form][2]int,
}

completion: Completion

// A table of candidates in memory of the console: the list of the first
// thread has one, the measure of the second thread has its own.
Candidate_Table :: struct {
	items:   [CANDIDATE_CAPACITY]line_editor.Candidate,
	count:   int,
	dropped: int, // The names that had no room: the list cannot offer them.
}

// edit_key_of gives the key of the line editor of a key of the terminal.
edit_key_of :: proc "contextless" (pressed: Key) -> line_editor.Edit_Key {
	switch pressed.code {
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
	}
	return line_editor.printable(pressed.character) ? .Character : .None
}

// completion_key gives a key to the list that is open, and Control-R and
// Control-S to the search of the history. taken is false when the key is
// for the line.
completion_key :: proc "contextless" (pressed: Key) -> (taken: bool) {
	control := pressed.modifiers & display.MODIFIER_CONTROL != 0
	older := control && pressed.character == 'r'
	newer := control && pressed.character == 's'
	switch completion.mode {
	case .Closed:
		if older {
			history_search_open()
			return true
		}
		// No line is newer than the line that the person types.
		return newer
	case .Names:
		switch {
		case older || pressed.code == display.KEY_DOWN:
			list_move(1)
		case newer || pressed.code == display.KEY_UP:
			list_move(-1)
		case pressed.code == display.KEY_TAB:
			list_take()
		case pressed.code == display.KEY_ENTER:
			// A name that is already the name at the caret: Enter runs the line.
			return list_take()
		case pressed.code == display.KEY_ESCAPE:
			completion_close()
			completion.escaped = true
		case:
			return false
		}
		return true
	case .History:
		switch {
		case older || pressed.code == display.KEY_DOWN:
			list_move(1)
		case newer || pressed.code == display.KEY_UP:
			list_move(-1)
		case pressed.code == display.KEY_ENTER || pressed.code == display.KEY_TAB:
			history_take()
		case pressed.code == display.KEY_ESCAPE:
			// The line that the person typed stays as it was.
			completion_close()
		case pressed.code == display.KEY_BACKSPACE:
			if completion.search_count > 0 {
				completion.search_count -= 1
				history_rank()
			}
		case control:
		case line_editor.printable(pressed.character):
			if completion.search_count < SEARCH_CAPACITY {
				completion.search[completion.search_count] = pressed.character
				completion.search_count += 1
				history_rank()
			}
		}
		// While the search is open, each key is for the search.
		return true
	}
	return false
}

// completion_after_edit makes the list again after a key changed the line:
// a typed character opens it; a key that moves the caret changes a list
// that is open.
completion_after_edit :: proc "contextless" (edit_key: line_editor.Edit_Key) {
	if edit_key == .Character {
		completion.escaped = false
	}
	typed := edit_key == .Character || edit_key == .Backspace || edit_key == .Delete
	if completion.mode == .Names || typed && !completion.escaped {
		names_rank(false)
	}
}

// completion_tab: Tab with no list. One name: it goes in the line. More
// names: the list opens.
completion_tab :: proc "contextless" () {
	names_rank(true)
	if completion.mode != .Names {
		return
	}
	if completion.ranked_count == 1 {
		list_take()
		return
	}
	candidate := &completion.names.items[completion.ranked[0].candidate]
	system.log("console: the completion list opens by Tab: ", u64(completion.matched_count), " names of ", u64(completion.names.count), " match \"", completion.place.query, "\", the first is ", candidate.name, "; one ranking takes ", completion.longest_ranking / 1000, " us at most, over ", completion.rankings, " keys")
}

completion_close :: proc "contextless" () {
	if completion.mode != .Closed {
		completion.list_changed = true
	}
	completion.mode = .Closed
	completion.ranked_count = 0
	completion.escaped = false
}

// list_move moves the choice; the rows shown follow it.
list_move :: proc "contextless" (step: int) {
	if completion.ranked_count == 0 {
		return
	}
	completion.chosen = clamp(completion.chosen + step, 0, completion.ranked_count - 1)
	if completion.chosen < completion.first_shown {
		completion.first_shown = completion.chosen
	}
	if completion.chosen >= completion.first_shown + terminal.LIST_ROWS {
		completion.first_shown = completion.chosen - terminal.LIST_ROWS + 1
	}
	completion.list_changed = true
}

// ---- The names.

candidate_add :: proc "contextless" (table: ^Candidate_Table, name: string, kind: line_editor.Candidate_Kind, number: int) {
	if name == "" {
		return
	}
	if table.count >= CANDIDATE_CAPACITY {
		table.dropped += 1
		return
	}
	table.items[table.count] = {name = name, kind = kind, number = u32(number)}
	table.count += 1
}

command_kind :: proc "contextless" (item: ^Command) -> line_editor.Candidate_Kind {
	if item.run != nil {
		return .Command
	}
	return item.record != 0 ? .Record : .Export
}

// names_collect fills a table of candidates for a place of the caret.
names_collect :: proc "contextless" (table: ^Candidate_Table, place: line_editor.Completion_Context) {
	table.count, table.dropped = 0, 0
	switch place.place {
	case .None:
	case .Name:
		for &item, index in commands[:command_count] {
			candidate_add(table, item.name, command_kind(&item), index)
		}
		for &sandbox, index in sandboxes {
			if sandbox.service {
				candidate_add(table, sandbox.name, .Service, index)
			}
		}
		for &variable, index in variables {
			candidate_add(table, string(variable.name[:clamp(variable.name_count, 0, VARIABLE_NAME_SIZE)]), .Variable, index)
		}
	case .Member:
		// The exports of a service: the commands "owner.name".
		owner := place.owner
		for &item, index in commands[:command_count] {
			if len(item.name) > len(owner) + 1 && item.name[:len(owner)] == owner && item.name[len(owner)] == '.' {
				candidate_add(table, item.name[len(owner) + 1:], command_kind(&item), index)
			}
		}
	case .Quoted:
		switch place.owner {
		case "load", "isolate", "start", "replace":
			for &entry, index in system.image_entries(image) {
				candidate_add(table, system.name_of(entry.name[:]), .Module, index)
			}
		case "connect", "stop", "grants", "revoke":
			programs_collect(place.word_start)
			for &name, index in completion.program_names[:completion.program_count] {
				candidate_add(table, system.name_of(name[:]), .Program, index)
			}
		case "unload":
			for &item, index in loaded[:loaded_count] {
				candidate_add(table, item.name, .Module, index)
			}
		}
	}
}

// programs_collect reads the names of the programs that run, with the
// grant to inspect the machine that the console holds. With no grant, the
// list names the services that the console is connected to: the root
// service has no list of its services to give. It reads them once for the
// quote that starts at quote_place: the names stay until the caret leaves
// the quote or a line runs, so a key in the quote makes no kernel call.
programs_collect :: proc "contextless" (quote_place: int) {
	if completion.programs_kept && completion.programs_quote == quote_place && completion.programs_lines == work.started {
		return
	}
	completion.programs_kept, completion.programs_quote, completion.programs_lines = true, quote_place, work.started
	completion.program_count = 0
	report: op.System_Report
	if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report)); status != .Ok {
		for &sandbox in sandboxes {
			if sandbox.service && completion.program_count < PROGRAM_NAME_CAPACITY {
				completion.program_names[completion.program_count] = {}
				copy(completion.program_names[completion.program_count][:], sandbox.name)
				completion.program_count += 1
			}
		}
		return
	}
	for slot in 1 ..< report.program_slots {
		if completion.program_count == PROGRAM_NAME_CAPACITY {
			break
		}
		program: op.Program_Report
		if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program), slot, u64(uintptr(&program)), size_of(program)); status != .Ok {
			continue
		}
		if program.state == .None || program.state == .Stopped {
			continue
		}
		completion.program_names[completion.program_count] = program.name
		completion.program_count += 1
	}
}

// names_rank makes the list of the names for the place of the caret.
// by_tab: the person asked with Tab: an empty name lists all the names, and
// a name that is already whole stays in the list.
names_rank :: proc "contextless" (by_tab: bool) {
	text := line_editor.line_text(&line)
	place := line_editor.completion_context(text, line.caret, by_tab)
	opens := by_tab || place.place == .Member || place.place == .Quoted || place.place == .Name && len(place.query) > 0
	if !opens {
		completion_close()
		return
	}
	started := system.nanoseconds()
	if place.place != .Quoted {
		completion.programs_kept = false
	}
	names_collect(&completion.names, place)
	// A name with a dot whose owner is no service: the whole name is the
	// query, against all the names.
	if place.place == .Member && completion.names.count == 0 {
		place.place = .Name
		place.query = text[place.word_start:line.caret]
		place.replace_start = place.word_start
		names_collect(&completion.names, place)
	}
	completion.ranked_count, completion.matched_count = line_editor.rank_candidates(place.query, completion.names.items[:completion.names.count], completion.ranked[:])
	ranking_measured(started)
	completion.place = place
	only_name_is_typed := completion.ranked_count == 1 && completion.names.items[completion.ranked[0].candidate].name == place.query
	if completion.ranked_count == 0 || only_name_is_typed && !by_tab {
		completion_close()
		return
	}
	completion.mode = .Names
	completion.escaped = false
	completion.chosen, completion.first_shown = 0, 0
	completion.list_changed = true
}

ranking_measured :: proc "contextless" (started: u64) {
	took := system.nanoseconds() - started
	completion.longest_ranking = max(completion.longest_ranking, took)
	completion.rankings += 1
}

// callable_kind says if a name of this kind is called: a chosen one gets
// its '('.
callable_kind :: proc "contextless" (kind: line_editor.Candidate_Kind) -> bool {
	return kind == .Command || kind == .Export || kind == .Record
}

// list_take puts the chosen name in the line, in the place of the name at
// the caret, with a '(' after a command or a closing quote after a name
// in quotes. changed is false when the line stays the same: the name is
// already there.
list_take :: proc "contextless" () -> (changed: bool) {
	if completion.mode != .Names || completion.ranked_count == 0 {
		completion_close()
		return false
	}
	candidate := completion.names.items[completion.ranked[completion.chosen].candidate]
	place := completion.place
	completion_close()
	buffer: [line_editor.LINE_CAPACITY]u8
	writer := system.Writer {
		buffer = buffer[:],
	}
	system.write_part(&writer, candidate.name)
	if place.place == .Quoted && !place.quote_follows {
		system.write_part(&writer, "\"")
	}
	if place.place != .Quoted && callable_kind(candidate.kind) && !place.call_follows {
		system.write_part(&writer, "(")
	}
	text := line_editor.line_text(&line)
	start := clamp(place.replace_start, 0, len(text))
	end := clamp(place.replace_end, start, len(text))
	if system.written(&writer) == text[start:end] {
		return false
	}
	if !line_editor.line_replace(&line, start, end, system.written(&writer)) {
		return false
	}
	system.log("console: the completion gave the line ", line_editor.line_text(&line))
	return true
}

// ---- The search of the history.

history_search_open :: proc "contextless" () {
	completion.mode = .History
	completion.search_count = 0
	history_rank()
}

history_rank :: proc "contextless" () {
	started := system.nanoseconds()
	completion.names.count = line_editor.history_candidates(&history, completion.names.items[:])
	completion.names.dropped = 0
	completion.ranked_count, completion.matched_count = line_editor.rank_candidates(string(completion.search[:completion.search_count]), completion.names.items[:completion.names.count], completion.ranked[:], skip_equal_names = true)
	ranking_measured(started)
	completion.chosen, completion.first_shown = 0, 0
	completion.list_changed = true
}

// history_take puts the chosen line of the history in the line; the person
// can change it, then Enter runs it.
history_take :: proc "contextless" () {
	if completion.ranked_count > 0 {
		line_editor.line_set(&line, completion.names.items[completion.ranked[completion.chosen].candidate].name)
		history_place = 0
		system.log("console: the history search gave the line ", line_editor.line_text(&line))
	}
	completion_close()
}

// ---- What the terminal shows.

// signature_write writes the parameters and the result of a command, after
// its name if with_name: "write(name: Text, data: Text) -> Integer". The
// parameter number marked (from 0) is between marked_start and marked_end.
signature_write :: proc "contextless" (writer: ^system.Writer, item: ^Command, marked: int, with_name: bool) -> (marked_start, marked_end: int) {
	if with_name {
		system.write_part(writer, item.name)
	}
	system.write_part(writer, "(")
	for kind, index in item.parameters[:clamp(item.parameter_count, 0, ARGUMENT_CAPACITY)] {
		if index > 0 {
			system.write_part(writer, ", ")
		}
		if index == marked {
			marked_start = writer.count
		}
		if item.parameter_names[index] != "" {
			system.write_part(writer, item.parameter_names[index])
			system.write_part(writer, ": ")
		}
		if kind == .None {
			system.write_part(writer, "Value") // Any kind: the command checks it.
		} else {
			system.write_parameter_type(writer, item.file, module.Type(kind), item.function.parameter_details[index], item.function.parameter_directions[index])
		}
		if index == marked {
			marked_end = writer.count
		}
	}
	system.write_part(writer, ")")
	if item.result != .None {
		system.write_part(writer, " -> ")
		system.write_type(writer, item.file, module.Type(item.result), item.function.result_detail)
	}
	return marked_start, marked_end
}

// owner_name gives the name of the module or of the service of an export.
owner_name :: proc "contextless" (item: ^Command) -> string {
	if item.sandbox >= 1 && item.sandbox <= SANDBOX_CAPACITY {
		return sandboxes[item.sandbox - 1].name
	}
	for &module_loaded in loaded[:loaded_count] {
		if raw_data(module_loaded.file) == raw_data(item.file) {
			return module_loaded.name
		}
	}
	return "a module"
}

// candidate_about writes what a name is: the text at the right of its row.
candidate_about :: proc "contextless" (writer: ^system.Writer, candidate: line_editor.Candidate) {
	switch candidate.kind {
	case .Command, .Export, .Record:
		if int(candidate.number) >= command_count {
			return
		}
		item := &commands[candidate.number]
		switch candidate.kind {
		case .Command:
			system.write_part(writer, "command ")
		case .Record:
			system.write_part(writer, "record ")
		case .Export, .Service, .Module, .Program, .Variable, .History_Line:
			system.write_part(writer, "export of ")
			system.write_part(writer, owner_name(item))
			system.write_part(writer, " ")
		}
		signature_write(writer, item, -1, false)
	case .Service:
		system.write_part(writer, "service")
	case .Module:
		system.write_part(writer, "module")
	case .Program:
		system.write_part(writer, "program that runs")
	case .Variable:
		if int(candidate.number) < VARIABLE_CAPACITY {
			value := variables[candidate.number].value
			system.write_part(writer, "variable: ")
			if value.kind == .None {
				system.write_part(writer, "None")
			} else {
				system.write_type(writer, value.file, module.Type(value.kind), value.detail)
			}
		}
	case .History_Line:
		if candidate.number == 0 {
			system.write_part(writer, "the last line")
		} else {
			system.write_part(writer, u64(candidate.number) + 1)
			system.write_part(writer, " lines ago")
		}
	}
}

// completion_show gives the terminal the list and the line under the edit
// line, when they changed. The caller holds output_lock.
completion_show :: proc "contextless" () {
	if completion.list_changed {
		completion.list_changed = false
		list_send()
	}
	long_buffer, short_buffer: [terminal.RUN_LIMIT]u8
	long := system.Writer {
		buffer = long_buffer[:],
	}
	short := system.Writer {
		buffer = short_buffer[:],
	}
	marked: [terminal.Hint_Form][2]int
	if !running {
		marked = hint_write(&long, &short)
	}
	both: [2 * terminal.RUN_LIMIT]u8
	both_count := copy(both[:], system.written(&long))
	both_count += copy(both[both_count:], system.written(&short))
	if string(both[:both_count]) == string(completion.hint_shown[:completion.hint_count]) && long.count == completion.hint_long_count && marked == completion.hint_marked {
		return
	}
	completion.hint_count = copy(completion.hint_shown[:], both[:both_count])
	completion.hint_long_count = long.count
	completion.hint_marked = marked
	terminal.hint(&output, {system.written(&long), marked[.Long][0], marked[.Long][1] - marked[.Long][0]}, {system.written(&short), marked[.Short][0], marked[.Short][1] - marked[.Short][0]}, {tone = .Dim})
}

list_send :: proc "contextless" () {
	if completion.mode == .Closed || running {
		terminal.list_show(&output, 0, terminal.NO_CHOICE, 0, 0, 0)
		return
	}
	shown := min(completion.ranked_count - completion.first_shown, terminal.LIST_ROWS)
	for row in 0 ..< shown {
		item := completion.ranked[completion.first_shown + row]
		candidate := completion.names.items[item.candidate]
		about: [160]u8
		writer := system.Writer {
			buffer = about[:],
		}
		candidate_about(&writer, candidate)
		terminal.list_row(&output, row, candidate.name, system.written(&writer), transmute([2]u64)item.places)
	}
	anchor := len(PROMPT)
	if completion.mode == .Names {
		anchor += completion.place.replace_start
	}
	terminal.list_show(&output, shown, u64(completion.chosen - completion.first_shown), completion.first_shown, completion.ranked_count, anchor)
}

// hint_write writes the line under the edit line, in its long form and in
// its short form: how to use the list that is open, or the signature of
// the call at the caret (one form: the terminal cuts it). It gives the
// part of each form to mark, as a first and an end byte.
hint_write :: proc "contextless" (long, short: ^system.Writer) -> (marked: [terminal.Hint_Form][2]int) {
	switch completion.mode {
	case .Names:
		system.write_part(long, u64(completion.matched_count))
		system.write_part(long, completion.matched_count == 1 ? string(" name matches") : string(" names match"))
		if completion.matched_count > completion.ranked_count {
			system.write_part(long, ", the best ")
			system.write_part(long, u64(completion.ranked_count))
			system.write_part(long, " in the list")
		}
		if completion.names.dropped > 0 {
			system.write_part(long, ", and more names than the list reads: type more characters")
		}
		system.write_part(long, ". Up, Down: choose. Tab, Enter: take. Escape: close")
		system.write_part(short, u64(completion.matched_count))
		system.write_part(short, completion.names.dropped > 0 ? string(" names and more. Tab: take. Esc: close") : string(" names. Tab: take. Esc: close"))
	case .History:
		system.write_part(long, "search the history: ")
		marked[.Long][0] = long.count
		system.write_part(long, string(completion.search[:completion.search_count]))
		marked[.Long][1] = long.count
		system.write_part(long, "  ")
		system.write_part(long, u64(completion.matched_count))
		system.write_part(long, " lines. Control-R: older, Control-S: newer, Enter: take, Escape: back to the line")
		system.write_part(short, "search: ")
		marked[.Short][0] = short.count
		system.write_part(short, string(completion.search[:completion.search_count]))
		marked[.Short][1] = short.count
		system.write_part(short, "  ")
		system.write_part(short, u64(completion.matched_count))
		system.write_part(short, " lines. ^R ^S Enter Esc")
	case .Closed:
		name, argument, found := line_editor.call_at_caret(line_editor.line_text(&line), line.caret)
		if !found {
			return {}
		}
		for &item in commands[:command_count] {
			if item.name == name && item.record == 0 {
				start, end := signature_write(long, &item, argument, true)
				marked[.Long] = {start, end}
				return marked
			}
		}
	}
	return marked
}
