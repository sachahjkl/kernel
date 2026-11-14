package console

import op "contract:operation"
import "contract:palette_table"
import "contract:ring"
import "contract:settings"
import "support:console_results"
import "support:line_editor"
import "support:system"
import "base:intrinsics"

// The palette provider (docs/CONSOLE.md, "8. The palette provider"): the
// console gives the palette of the desktop one entry for each of its
// commands, and runs the entry that the input chose there.
//
// The console writes the entry table (contract:palette_table), a memory
// object that the compositor maps read-only, after each line: a line can
// load a module or connect to a service, and the command table then has
// new commands. The compositor names a chosen entry on a ring, by the
// generation of the table that it showed, the index of the entry and the
// hash of its name. The console checks the three, builds the line from its
// own command table, and runs it as a line that the input typed: the line
// is echoed, it goes in the line history, the log records show under it,
// and the drawers draw its result. The console then answers with a short
// result, as runs of text with what each run is, or says that its window
// has the result.
//
// Nothing of the compositor is trusted: an index past the table, a hash
// that names another entry and an entry with parameters are refused.

// The built-in commands that destroy something: the palette asks for a
// second Enter before it sends one of them.
@(rodata)
palette_destroying_commands := [?]string{"shutdown", "stop", "revoke", "lock", "history_clear", "unload", "replace"}

#assert(u8(console_results.Part.Operation) == u8(palette_table.Run_Part.Operation))
#assert(u8(console_results.Part.Plain) == u8(palette_table.Run_Part.Plain) && u8(console_results.Part.Failure) == u8(palette_table.Run_Part.Failure) && u8(console_results.Part.Number) == u8(palette_table.Run_Part.Number))

palette_ring: ring.Ring // The ring from the compositor: its choices, and the answers of the console.
palette_table_handle, palette_ring_handle: system.Handle
palette_memory: []u8 // The mapping of the entry table.
// 1: the console is the palette provider. The two threads read it; it goes
// to 0 once, before the grant ends.
palette_provided: u32
// The thread that runs the lines asks the first thread to stop its use of
// the ring before a revocation of the grant: 1 is the request, and the
// first thread answers with 1 in palette_stopped.
palette_stop_request, palette_stopped: u32
// The entries as the console wrote them last, and their count: a choice is
// checked against this copy, never against the shared memory. The lock is
// held for one copy in memory.
palette_entries: [palette_table.ENTRY_CAPACITY]palette_table.Entry
palette_entry_count: int
palette_table_lock: system.Lock
palette_send_lock: system.Lock // The ring has two writers: the two threads.
palette_tag: u32 // Not 0: the line that runs is a choice of the palette with this tag.
line_value: Value // The value of the line that ran last, for the answer to the palette.

// palette_provider_start asks the root service for the entry table and the
// ring, and writes the first table. The first thread calls it once, before
// a line runs. Without the grant the console has no provider part, and the
// palette lists the programs and the windows only.
palette_provider_start :: proc "contextless" () {
	// The root service answers when it reaches its loop, after its boot
	// passes: the bound only ends a hang.
	completion, answered := request_record(.Palette_Provide, "console", 0, 60_000)
	if !answered || system.Status(completion.kind) != .Ok {
		system.log("console: the console is not the palette provider: the root service refused")
		return
	}
	palette_table_handle, palette_ring_handle = system.Handle(completion.values[0]), system.Handle(completion.values[1])
	table_kind, _, _ := system.handle_state(palette_table_handle)
	if table_kind != .Memory || system.memory_size(palette_table_handle) < palette_table.TABLE_PAGES {
		system.log("console: the console is not the palette provider: no entry table")
		return
	}
	address, status := system.memory_map(palette_table_handle)
	if status != .Ok {
		system.log("console: the console is not the palette provider: the entry table cannot be mapped")
		return
	}
	opened, ring_status := system.ring_open(palette_ring_handle)
	if ring_status != .Ok {
		system.memory_unmap(address)
		system.log("console: the console is not the palette provider: no ring")
		return
	}
	palette_commands_add()
	palette_ring = opened
	palette_memory = ([^]u8)(address)[:palette_table.TABLE_BYTES]
	header := (^palette_table.Header)(address)
	header.magic = palette_table.MAGIC
	header.version = palette_table.VERSION
	intrinsics.atomic_store(&palette_provided, 1)
	palette_table_write()
}

// palette_active says if the console is the palette provider now.
palette_active :: proc "contextless" () -> bool {
	return intrinsics.atomic_load_explicit(&palette_provided, .Relaxed) != 0
}

// palette_entry_make makes the entry of one command. ok is false for a
// command that the palette does not list: a command that makes a record
// from its fields, a name that does not fit or that the font does not
// draw, and a command that a later command with the same name hides.
palette_entry_make :: proc "contextless" (number: int) -> (entry: palette_table.Entry, ok: bool) {
	item := &commands[number]
	if item.record != 0 || len(item.name) == 0 || len(item.name) > palette_table.NAME_CAPACITY || !palette_table.printable(transmute([]u8)item.name) {
		return {}, false
	}
	for &later in commands[number + 1:command_count] {
		if later.name == item.name {
			return {}, false
		}
	}
	entry.kind = .Export
	if item.run != nil {
		entry.kind = .Command
		for name in palette_destroying_commands {
			if name == item.name {
				entry.flags += {.Destroys}
			}
		}
	}
	entry.parameter_count = u8(clamp(item.parameter_count, 0, palette_table.PARAMETER_CAPACITY))
	for kind, index in item.parameters[:entry.parameter_count] {
		entry.parameters[index] = palette_table.Value_Kind(u8(kind))
	}
	// The name of each parameter, whole or absent: the form of the palette
	// names its fields with them.
	for name, index in item.parameter_names[:entry.parameter_count] {
		if len(name) <= palette_table.PARAMETER_NAME_CAPACITY && palette_table.printable(transmute([]u8)name) {
			entry.parameter_name_lengths[index] = u8(copy(entry.parameter_names[index][:], name))
		}
	}
	entry.result = palette_table.Value_Kind(u8(item.result))
	entry.name_length = u8(copy(entry.name[:], item.name))
	// The signature, whole; one that does not fit shows no parameter.
	buffer: [512]u8
	writer := system.Writer {
		buffer = buffer[:],
	}
	_, _ = signature_write(&writer, item, -1, true)
	signature := string(buffer[:writer.count])
	if writer.dropped != 0 || len(signature) > palette_table.SIGNATURE_CAPACITY || !palette_table.printable(transmute([]u8)signature) {
		short := system.Writer {
			buffer = buffer[:],
		}
		system.write_part(&short, item.name)
		system.write_part(&short, item.parameter_count > 0 ? "(...)" : "()")
		signature = string(buffer[:short.count])
	}
	entry.signature_length = u8(copy(entry.signature[:], signature))
	// The help sentence: its start, when it is longer than its field.
	entry.about_length = u8(copy(entry.about[:], item.about))
	for &value in entry.about[:entry.about_length] {
		if value < 32 || value > 126 {
			value = '?'
		}
	}
	return entry, true
}

#assert(palette_table.PARAMETER_CAPACITY == ARGUMENT_CAPACITY)
#assert(u8(Kind.Bytes) == u8(palette_table.Value_Kind.Bytes))

// The entries that the next table holds: made here, then compared with
// the entries of the table before, so that a line that changes no command
// changes no table. Only the thread that writes the table uses it.
palette_next_entries: [palette_table.ENTRY_CAPACITY]palette_table.Entry

// palette_table_write writes the entry table from the command table of
// now, when it differs from the table before. The writer adds 1 to the
// change count before the change and 1 after it, and wakes the reader.
// The first thread calls it at the start; after that, only the thread
// that runs the lines, after each line.
palette_table_write :: proc "contextless" () {
	if !palette_active() {
		return
	}
	count := 0
	for number in 0 ..< command_count {
		if count == palette_table.ENTRY_CAPACITY {
			break
		}
		if entry, ok := palette_entry_make(number); ok {
			palette_next_entries[count] = entry
			count += 1
		}
	}
	// One entry for each value of each setting of the machine: "set font
	// to spleen". Its help is the line that the console runs for it.
	for setting in settings.Setting {
		description := settings.descriptions[setting]
		for value in 0 ..< description.value_count {
			if count == palette_table.ENTRY_CAPACITY {
				break
			}
			entry := palette_table.Entry{kind = .Setting, setting = u8(setting), setting_value = u8(value), result = .Integer}
			name := system.Writer{buffer = entry.name[:]}
			system.write_part(&name, "set ")
			system.write_part(&name, description.title)
			system.write_part(&name, " to ")
			system.write_part(&name, description.value_names[value])
			about := system.Writer{buffer = entry.about[:]}
			palette_setting_line(&about, description.name, description.value_names[value])
			if name.dropped != 0 || about.dropped != 0 {
				continue
			}
			entry.name_length = u8(name.count)
			entry.signature_length = u8(copy(entry.signature[:], entry.name[:name.count]))
			entry.about_length = u8(about.count)
			palette_next_entries[count] = entry
			count += 1
		}
	}
	header := (^palette_table.Header)(raw_data(palette_memory))
	size := count * size_of(palette_table.Entry)
	system.lock(&palette_table_lock)
	defer system.unlock(&palette_table_lock)
	written_before := header.change_count != 0
	next_bytes := ([^]u8)(&palette_next_entries[0])[:size]
	kept_bytes := ([^]u8)(&palette_entries[0])[:size]
	if written_before && count == palette_entry_count && string(next_bytes) == string(kept_bytes) {
		return
	}
	copy(kept_bytes, next_bytes)
	palette_entry_count = count
	// The grant can end while a line runs: the table is used only while
	// the console is the provider.
	if !palette_active() {
		return
	}
	intrinsics.atomic_add(&header.change_count, 1)
	copy(palette_memory[palette_table.ENTRIES_OFFSET:], kept_bytes)
	header.entry_count = u32(count)
	generation := intrinsics.atomic_add(&header.change_count, 1) + 1
	system.word_wake(&header.change_count, 64)
	system.log("console: the palette table has ", u64(count), " entries, generation ", u64(generation))
}

// palette_answer sends the answer to a choice.
palette_answer :: proc "contextless" (tag: u32, outcome: palette_table.Outcome, kind: Kind, length: int) {
	if !palette_active() {
		return
	}
	system.lock(&palette_send_lock)
	system.send(&palette_ring.completions, ring.Record{tag = tag, values = {0 = u64(outcome), 1 = u64(kind), 2 = u64(length)}})
	system.unlock(&palette_send_lock)
}

// palette_result_write copies the runs of a result into the result area of
// the table. It gives the count of its bytes.
palette_result_write :: proc "contextless" (runs: []u8) -> int {
	system.lock(&palette_table_lock)
	defer system.unlock(&palette_table_lock)
	if !palette_active() || len(runs) > palette_table.RESULT_CAPACITY {
		return 0
	}
	copy(palette_memory[palette_table.RESULT_OFFSET:][:palette_table.RESULT_CAPACITY], runs)
	return len(runs)
}

// palette_refuse answers a choice that the console does not run, with the
// sentence that the panel shows.
palette_refuse :: proc "contextless" (tag: u32, sentence: string) {
	area: [256]u8
	writer := palette_table.Result_Writer{buffer = area[:], fits = true}
	palette_table.result_run(&writer, .Failure, sentence)
	palette_table.result_line_end(&writer)
	system.log("console: the palette choice is refused: ", sentence)
	palette_answer(tag, .Refused, .None, palette_result_write(area[:writer.count]))
}

// palette_turn is the part of the palette in the loop of the first
// thread. It answers a request to stop the use of the ring; and, when no
// line runs, it takes one choice of the compositor: the next one waits in
// the ring for the end of the line, as a key does.
palette_turn :: proc "contextless" () {
	if intrinsics.atomic_load_explicit(&palette_stop_request, .Relaxed) != 0 && intrinsics.atomic_load_explicit(&palette_stopped, .Relaxed) == 0 {
		intrinsics.atomic_store(&palette_provided, 0)
		intrinsics.atomic_store(&palette_stopped, 1)
		system.word_wake(&palette_stopped)
	}
	if !palette_active() || running {
		return
	}
	// The keys first: a key that waits for the end of a line, or that is
	// still in the terminal ring, was typed before the choice, and acts
	// before it. The loop reads the terminal ring at its next turn, which
	// comes at once: the ring is in its wait while no line runs.
	if pending_count > 0 || ring.count(&output.ring.completions) > 0 {
		return
	}
	// The typed values of a choice come before it, with its tag: they are
	// taken with it.
	for {
		record, received := system.receive(&palette_ring.commands)
		if !received {
			return
		}
		#partial switch palette_table.Command(record.kind) {
		case .Argument:
			if parameter, argument, ok := palette_table.argument_unpack(record.values); ok {
				if palette_arguments_tag != record.tag {
					palette_arguments_tag = record.tag
					palette_arguments_given = {}
				}
				palette_arguments[parameter] = argument
				palette_arguments_given += {parameter}
			} else {
				// A value that is none: the choice of this tag is refused.
				palette_arguments_tag = record.tag
				palette_arguments_given = {}
				palette_arguments_bad = record.tag
			}
			continue
		case .Candidates:
			palette_candidates_give(record)
			continue
		case .Manual:
			palette_manual_page(record)
		case .Choose:
			palette_choice(record)
		}
		return
	}
}

// The typed values of the choice that comes next on the ring.
palette_arguments: [palette_table.PARAMETER_CAPACITY]palette_table.Argument_Value
palette_arguments_given: bit_set[0 ..< palette_table.PARAMETER_CAPACITY]
palette_arguments_tag: u32 // The tag of the choice that the values are for.
palette_arguments_bad: u32 // The tag of a choice with a value that failed its check.
palette_manual: bool // The line that runs shows a page of the manual.

// palette_setting_line writes the line that sets a setting.
palette_setting_line :: proc "contextless" (writer: ^system.Writer, name: string, value: string) {
	system.write_part(writer, "setting(\"")
	system.write_part(writer, name)
	system.write_part(writer, "\", \"")
	system.write_part(writer, value)
	system.write_part(writer, "\")")
}

// palette_entry_named gives the copy of the entry that a record of the
// compositor names, when the index is inside the table of the console and
// the hash is the hash of the name of that entry: an index that names
// another entry, after the table changed, is not the entry that the panel
// showed. Each number is the number of another program.
palette_entry_named :: proc "contextless" (record: ring.Record) -> (entry: palette_table.Entry, ok: bool) {
	index, hash := record.values[1], record.values[2]
	system.lock(&palette_table_lock)
	if index < u64(palette_entry_count) {
		entry = palette_entries[index]
		ok = true
	}
	system.unlock(&palette_table_lock)
	return entry, ok && palette_table.name_hash(string(entry.name[:entry.name_length])) == hash
}

// palette_command_named gives the command of the command table that a
// call of a name runs: the last one with the name.
palette_command_named :: proc "contextless" (name: string) -> (found: ^Command) {
	for &item in commands[:command_count] {
		if item.name == name {
			found = &item
		}
	}
	return found
}

// palette_line_run runs a line that the console built for the palette, as
// a line that the input typed. What the input typed in the edit line and
// did not enter yet is kept: it is in the edit line again after the line
// of the palette is entered, so no typed key is lost.
palette_line_run :: proc "contextless" (tag: u32, text: string) {
	completion_close()
	history_place = 0
	typed_before := line
	line_editor.line_set(&line, text)
	system.log("console: the palette runs ", text)
	palette_tag = tag
	line_enter()
	line = typed_before
}

// palette_choice takes one choice of the compositor.
palette_choice :: proc "contextless" (record: ring.Record) {
	mode := record.values[3]
	entry, named := palette_entry_named(record)
	if !named || mode > u64(palette_table.Choose_Mode.Run_With_Arguments) {
		palette_refuse(record.tag, "the commands changed: choose again")
		return
	}
	name := string(entry.name[:entry.name_length])
	palette_manual = false
	if entry.kind == .Setting {
		// The line of a setting is the help of its entry, which the
		// console wrote itself.
		palette_line_run(record.tag, string(entry.about[:entry.about_length]))
		return
	}
	found := palette_command_named(name)
	if found == nil {
		palette_refuse(record.tag, "the commands changed: choose again")
		return
	}
	text: [LINE_CAPACITY]u8
	writer := system.Writer{buffer = text[:]}
	system.write_part(&writer, name)
	system.write_part(&writer, "(")
	if palette_table.Choose_Mode(mode) == .Run_With_Arguments {
		// Each value has the kind of its parameter, and each parameter
		// has a value: the console checks them as it checks a line.
		count := clamp(found.parameter_count, 0, ARGUMENT_CAPACITY)
		fits := palette_arguments_tag == record.tag && palette_arguments_bad != record.tag && record.values[4] == u64(count) && count > 0
		for index in 0 ..< count {
			if !fits || index not_in palette_arguments_given {
				fits = false
				break
			}
			argument := &palette_arguments[index]
			system.write_part(&writer, index > 0 ? ", " : "")
			switch {
			case found.parameters[index] == .Integer && argument.kind == .Integer:
				system.write_part(&writer, argument.integer)
			case found.parameters[index] == .Text && argument.kind == .Text:
				system.write_part(&writer, "\"")
				system.write_part(&writer, string(argument.text[:argument.length]))
				system.write_part(&writer, "\"")
			case:
				fits = false
			}
		}
		palette_arguments_given = {}
		system.write_part(&writer, ")")
		if !fits || writer.dropped != 0 {
			palette_refuse(record.tag, "the arguments do not fit the command: type the line in the console")
			return
		}
		palette_line_run(record.tag, string(text[:writer.count]))
		return
	}
	system.write_part(&writer, ")")
	if palette_table.Choose_Mode(mode) == .Edit || found.parameter_count > 0 {
		// The input writes the arguments: the caret is between the
		// parentheses.
		completion_close()
		history_place = 0
		line_editor.line_set(&line, string(text[:writer.count]))
		line_editor.line_key(&line, .Left)
		system.log("console: the palette opens ", string(text[:writer.count]), " in the edit line")
		palette_answer(record.tag, .Edit_Opened, .None, 0)
		return
	}
	palette_line_run(record.tag, string(text[:writer.count]))
}

// palette_manual_page runs the line that shows the page of the manual of
// a module: the compositor gave its name as a typed value.
palette_manual_page :: proc "contextless" (record: ring.Record) {
	packed := system.name_unpack({record.values[0], record.values[1], record.values[2], record.values[3]})
	name := system.name_of(packed[:])
	valid := len(name) > 0
	for index in 0 ..< len(name) {
		if name[index] < 32 || name[index] > 126 || name[index] == '"' {
			valid = false
		}
	}
	if !valid {
		palette_refuse(record.tag, "the name of the module is no name")
		return
	}
	text: [LINE_CAPACITY]u8
	writer := system.Writer{buffer = text[:]}
	system.write_part(&writer, "manual_page(\"")
	system.write_part(&writer, name)
	system.write_part(&writer, "\")")
	// The mark first: the thread that runs the lines reads it at the end
	// of the line.
	palette_manual = true
	palette_line_run(record.tag, string(text[:writer.count]))
}

// What the values of a parameter of a command are, for the candidates of
// a field of the palette.
palette_candidate_kind :: proc "contextless" (command_name: string, parameter: u64) -> palette_table.Candidate_Kind {
	switch command_name {
	case "stop", "grants", "connect", "debug":
		if parameter == 0 {
			return .Program
		}
	case "revoke":
		if parameter == 0 {
			return .Program
		}
		if parameter == 1 {
			return .Grant
		}
	case "start", "load", "isolate", "manual_page":
		if parameter == 0 {
			return .Module
		}
	case "replace":
		if parameter <= 1 {
			return .Module
		}
	}
	return .None
}

// palette_candidates_give answers a request for the candidates of one
// parameter of one entry: it writes their names in the candidate area of
// the table, then their kind and their count on the ring. A name that
// does not fit a candidate is left out. With no candidate the count is 0.
palette_candidates_give :: proc "contextless" (record: ring.Record) {
	entry, named := palette_entry_named(record)
	kind := palette_table.Candidate_Kind.None
	if named {
		kind = palette_candidate_kind(string(entry.name[:entry.name_length]), record.values[3])
	}
	candidates: [palette_table.CANDIDATE_CAPACITY]palette_table.Candidate
	count := 0
	add :: proc "contextless" (into: ^[palette_table.CANDIDATE_CAPACITY]palette_table.Candidate, used: ^int, added: string) {
		if used^ < palette_table.CANDIDATE_CAPACITY && len(added) > 0 && len(added) <= palette_table.CANDIDATE_NAME_CAPACITY && palette_table.printable(transmute([]u8)added) {
			into[used^].length = u8(copy(into[used^].name[:], added))
			used^ += 1
		}
	}
	switch kind {
	case .None:
	case .Grant:
		for grant in system.Root_Grant {
			add(&candidates, &count, system.root_grant_names[grant])
		}
	case .Module:
		entries := system.image_entries(image)
		for &image_entry in entries {
			add(&candidates, &count, system.name_of(image_entry.name[:]))
		}
	case .Program:
		// The programs that run, from the reports of the machine, as the
		// completion of the edit line reads them.
		report: op.System_Report
		if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report)); status == .Ok {
			for slot in 1 ..< report.program_slots {
				program: op.Program_Report
				if _, program_status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program), slot, u64(uintptr(&program)), size_of(program)); program_status != .Ok {
					continue
				}
				if program.state == .None || program.state == .Stopped {
					continue
				}
				// One row for each name: two programs can have one.
				name := system.name_of(program.name[:])
				known := false
				for &candidate in candidates[:count] {
					if string(candidate.name[:candidate.length]) == name {
						known = true
					}
				}
				if !known {
					add(&candidates, &count, name)
				}
			}
		}
	}
	system.lock(&palette_table_lock)
	if palette_active() {
		bytes := ([^]u8)(&candidates[0])[:count * size_of(palette_table.Candidate)]
		copy(palette_memory[palette_table.CANDIDATES_OFFSET:], bytes)
	}
	system.unlock(&palette_table_lock)
	if !palette_active() {
		return
	}
	system.log("console: the palette gets ", u64(count), " candidates for the parameter ", record.values[3], " of ", string(entry.name[:named ? int(entry.name_length) : 0]))
	system.lock(&palette_send_lock)
	system.send(&palette_ring.completions, ring.Record{tag = record.tag, values = {0 = u64(palette_table.Outcome.Candidates_Ready), 1 = u64(kind), 2 = u64(count)}})
	system.unlock(&palette_send_lock)
}

// palette_commands_add adds the two commands that the palette runs under
// a short name: each one is an export of a service.
palette_commands_add :: proc "contextless" () {
	// Sets one setting of the machine: the export `set` of the service
	// `settings`, under a short name.
	//
	// - `name`: the name of a setting: `font`, `subpixel_order`,
	//   `pointer_theme`, `grid_fit`.
	// - `value`: the name of one of its values.
	//
	// The command connects to `settings` when the console has no
	// connection to it yet. The palette of the desktop runs it for an
	// entry such as "set font to spleen".
	//
	// Errors: those of `connect("settings")`, and those of the export.
	command("setting", {.Text, .Text}, .Integer, "set a setting of the machine: settings.set()", proc "contextless" (arguments: []Value) -> Value {
		return bound_call("settings", "set", arguments)
	})
	// Shows the page of a module in the window of the manual: the export
	// `show` of the service `manual`, under a short name. It gives the
	// count of the exports of the module.
	//
	// - `name`: the name of a module of the boot image.
	//
	// The program `manual` must run: the command starts no program.
	//
	// Errors: those of `connect("manual")`, and those of the export.
	command("manual_page", {.Text}, .Integer, "show the page of a module in the manual: manual.show()", proc "contextless" (arguments: []Value) -> Value {
		return bound_call("manual", "show", arguments)
	})
	// The names of the parameters of the built-in commands that the form
	// of the palette asks for: a field says what it takes. help() and
	// describe() show them too.
	Named :: struct {
		command: string,
		names:   [2]string,
	}
	named := [?]Named {
		{"start", {"name", ""}},
		{"stop", {"name", ""}},
		{"grants", {"name", ""}},
		{"revoke", {"name", "grant"}},
		{"connect", {"name", ""}},
		{"load", {"name", ""}},
		{"isolate", {"name", ""}},
		{"unload", {"name", ""}},
		{"replace", {"module", "by"}},
		{"debug", {"program", ""}},
		{"describe", {"name", ""}},
		{"setting", {"name", "value"}},
		{"manual_page", {"name", ""}},
	}
	for item in named {
		if found := palette_command_named(item.command); found != nil && found.run != nil {
			for name, index in item.names {
				if index < found.parameter_count {
					found.parameter_names[index] = name
				}
			}
		}
	}
}

// palette_line_ended answers the choice of the palette that the line was,
// after the console drew its result in its own window. The thread that
// runs the lines calls it after each line. A short result goes to the
// panel as the runs that its drawer writes: an Integer, a Text of one
// line, a Record of few fields, an error. Each other result is in the
// window of the console only, and the answer says so.
palette_line_ended :: proc "contextless" () {
	tag := palette_tag
	if tag == 0 {
		return
	}
	palette_tag = 0
	area: [palette_table.RESULT_CAPACITY]u8
	writer := palette_table.Result_Writer{buffer = area[:], fits = true}
	sink := console_results.Sink {
		data = &writer,
		write = proc "contextless" (sink: ^console_results.Sink, text: string, part: console_results.Part) {
			palette_table.result_run((^palette_table.Result_Writer)(sink.data), palette_table.Run_Part(u8(part)), text)
		},
		end_line = proc "contextless" (sink: ^console_results.Sink) {
			palette_table.result_line_end((^palette_table.Result_Writer)(sink.data))
		},
	}
	outcome := palette_table.Outcome.Shown_In_Panel
	value := line_value
	manual := palette_manual
	palette_manual = false
	if manual && !failed {
		// The window of the manual shows the page: the panel has nothing
		// to draw.
		system.log("console: the manual shows the page that the palette asked for")
		palette_answer(tag, .Manual_Opened, .Integer, 0)
		return
	}
	if failed {
		outcome = .Failed
		value = {}
		drawn := console_results.Failure {
			sentence       = string(failure.sentence[:failure.sentence_count]),
			operation      = string(failure.operation[:failure.operation_count]),
			argument_names = failure.argument_names[:failure.argument_count],
		}
		if failure.has_record {
			drawn.record = &failure.record
		}
		console_results.draw_failure(&sink, drawn)
		if !writer.fits {
			// The whole error is in the window of the console; the panel
			// has the start of its sentence.
			writer = {buffer = area[:], fits = true}
			palette_table.result_run(&writer, .Failure, console_results.FAILURE_START)
			palette_table.result_run(&writer, .Failure, drawn.sentence[:min(len(drawn.sentence), palette_table.RESULT_COLUMN_CAPACITY - len(console_results.FAILURE_START))])
			palette_table.result_line_end(&writer)
		}
	} else {
		#partial switch value.kind {
		case .None:
			palette_table.result_run(&writer, .Note, "done")
			palette_table.result_line_end(&writer)
		case .Integer:
			console_results.draw_integer(&sink, value.integer)
		case .Text:
			one_line := true
			for index in 0 ..< len(value.text) {
				if value.text[index] == '\n' {
					one_line = false
				}
			}
			if one_line {
				console_results.draw_text(&sink, value.text)
			} else {
				writer.fits = false
			}
		case .Record:
			console_results.draw_record(&sink, value.file, value.detail, value.record)
		case:
			writer.fits = false
		}
		if !writer.fits {
			outcome = .Shown_In_Console
			writer = {buffer = area[:]} // No run goes to the panel.
		}
	}
	if outcome == .Shown_In_Console {
		system.log("console: the result of the palette choice is in the console: ", kind_names[value.kind])
	} else {
		system.log("console: the palette gets ", failed ? "an error" : kind_names[value.kind], ", ", u64(writer.lines), " lines")
	}
	palette_answer(tag, outcome, value.kind, palette_result_write(area[:writer.count]))
}

// palette_stop_before_revoke ends the use of the table and of the ring by
// the two threads, before the console asks the root service to end its own
// grant: after the revocation the two mappings are gone. The thread that
// runs the lines calls it; it waits for the first thread, which can be in
// a wait on the ring, with the bound of a hang of a call to the root
// service.
palette_stop_before_revoke :: proc "contextless" () {
	if !palette_active() {
		return
	}
	intrinsics.atomic_store(&palette_stop_request, 1)
	change()
	limit := system.time() + 3000
	for intrinsics.atomic_load_explicit(&palette_stopped, .Relaxed) == 0 && system.time() < limit {
		system.word_wait(&palette_stopped, 0, limit)
	}
	intrinsics.atomic_store(&palette_provided, 0)
	system.log("console: the console is no more the palette provider")
}
