package console

import "contract:palette_table"
import "contract:ring"
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
	record, received := system.receive(&palette_ring.commands)
	if !received || palette_table.Command(record.kind) != .Choose {
		return
	}
	// The numbers are those of another program: each one is checked
	// against the copy of the table that the console keeps.
	index, hash, mode := record.values[1], record.values[2], record.values[3]
	name_bytes: [palette_table.NAME_CAPACITY]u8
	name_count := 0
	system.lock(&palette_table_lock)
	if index < u64(palette_entry_count) {
		entry := &palette_entries[index]
		name_count = copy(name_bytes[:], entry.name[:entry.name_length])
	}
	system.unlock(&palette_table_lock)
	name := string(name_bytes[:name_count])
	// The hash of the name: an index that names another entry, after the
	// table changed, is not the entry that the panel showed.
	if name_count == 0 || palette_table.name_hash(name) != hash {
		palette_refuse(record.tag, "the commands changed: choose again")
		return
	}
	found: ^Command
	for &item in commands[:command_count] {
		if item.name == name {
			found = &item
		}
	}
	if found == nil || mode > u64(palette_table.Choose_Mode.Edit) {
		palette_refuse(record.tag, "the commands changed: choose again")
		return
	}
	call: [palette_table.NAME_CAPACITY + 2]u8
	call_count := copy(call[:], name)
	call_count += copy(call[call_count:], "()")
	completion_close()
	history_place = 0
	line_editor.line_set(&line, string(call[:call_count]))
	if palette_table.Choose_Mode(mode) == .Edit || found.parameter_count > 0 {
		// The input writes the arguments: the caret is between the
		// parentheses.
		line_editor.line_key(&line, .Left)
		system.log("console: the palette opens ", string(call[:call_count]), " in the edit line")
		palette_answer(record.tag, .Edit_Opened, .None, 0)
		return
	}
	system.log("console: the palette runs ", string(call[:call_count]))
	palette_tag = record.tag
	line_enter()
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
			writer.count = 0
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
