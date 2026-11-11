// A program that keeps its state when it stops and when the machine stops: a note and a count, in its private store.
//
// Each change goes to the storage service when it happens: the program has no save action. The note is the object "note". The count is the object "count": three blocks that each hold the count in each of their 512 numbers, so that a part of one commit with a part of another would show.
//
// Keys: a character adds to the note, Backspace removes the last one, Enter writes the note on the log. Tab counts 1000 more, one commit for each step.
//
// Versions: each key is one commit, and the storage service keeps the state before it as a version, so the program has undo to any earlier version with no code of its own to keep them. Up shows the version before the one shown, Down the one after; Enter restores the version shown (a new commit: nothing is lost); Escape goes back to the current note. The bar under the note has one mark for each version.
package notes

import "contract:errors"
import "support:calendar"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:storage"
import "support:system"

// The window is built with the interface package (docs/INTERFACE.md).
records_now, records_before: [512]interface.Draw_Record
text_now, text_before: [8192]u8
drawing: interface.Window_Drawing

WIDTH :: 560
HEIGHT :: 300
HISTORY_CAPACITY :: 512 // The versions of the note that the window shows.
NOTE_CAPACITY :: 60
COUNT_BLOCKS :: 3
COUNT_WORDS :: COUNT_BLOCKS * 512
RUN_STEPS :: 1000

COLOR_LIT :: 0xE0A040

client: storage.Client
note: [NOTE_CAPACITY]u8
note_count: int
count: u64
generation: i64
words: [COUNT_WORDS]u64 // The object "count".
restored: string // What the start found in the store.
restored_good: bool
gone: bool // The grant of the store ended.

// The versions of the note, the oldest first, the current version last.
history: [HISTORY_CAPACITY]storage.Version
history_total: i64 // All the states: more than history can hold when the note has more versions.
shown: int = -1 // The place in history of the version that the window shows; -1: the current note.
shown_text: [NOTE_CAPACITY]u8
shown_count: int

// The measures: the commits of the note (one key each) and the restores.
commit_time_total, commit_count: u64 // In microseconds.
restore_time_last: u64

history_read :: proc "contextless" () {
	rows, total, status := storage.versions(&client, "note", history[:])
	if status == .Ok {
		history_total = total
		shown_count = 0
		_ = rows
	}
}

history_count :: proc "contextless" () -> int {
	return int(min(history_total, HISTORY_CAPACITY))
}

// show reads the version at a place of history.
show :: proc "contextless" (place: int) {
	if place < 0 || place >= history_count() - 1 {
		shown = -1
		return
	}
	shown = place
	bytes, status := storage.version(&client, "note", history[place].generation, shown_text[:])
	shown_count = status == .Ok ? len(bytes) : 0
	date_text: [24]u8
	system.log("notes: the version ", u64(place + 1), " of ", u64(history_count()), ", generation ", history[place].generation, history[place].date != 0 ? ", " : "", history[place].date != 0 ? calendar.iso_text(date_text[:], history[place].date) : "", ": \"", string(shown_text[:shown_count]), "\"")
}

// keep writes one object. It gives false when the store is gone or refuses.
keep :: proc "contextless" (name: string, data: []u8) -> bool {
	error: errors.Error_Record
	started := system.nanoseconds()
	result, status := storage.write(&client, name, data, &error)
	if name == "note" {
		commit_time_total += (system.nanoseconds() - started) / 1000
		commit_count += 1
	}
	if status != .Ok || result < 0 {
		gone = status == .Gone || result == -1
		if !gone {
			buffer: [256]u8
			writer := system.Writer{buffer = buffer[:]}
			storage.error_text(&writer, &client, &error)
			system.log("notes: the storage service refused the object ", name, ": ", system.written(&writer))
		}
		return false
	}
	generation = result
	return true
}

keep_count :: proc "contextless" () -> bool {
	for &word in words {
		word = count
	}
	return keep("count", ([^]u8)(&words)[:size_of(words)])
}

count_versions: [1200]storage.Version // The measure of a list of versions of the count.

// restore reads the note and the count, and checks that the three blocks
// of the count hold one count. An object that the storage service has and
// cannot give is not an empty object: the window says it.
restore :: proc "contextless" () {
	text, found, status := storage.read(&client, "note", note[:])
	note_damaged := status == .Damaged
	if status != .Ok && !note_damaged {
		restored, gone = "no store: the program keeps nothing", true
		system.log("notes: no store")
		return
	}
	if found {
		note_count = len(text)
	}
	bytes, has_count, count_status := storage.read(&client, "count", ([^]u8)(&words)[:size_of(words)])
	if !found && !has_count && !note_damaged && count_status == .Ok {
		restored, restored_good = "a new store: no note, the count 0", true
		system.log("notes: a new store: no note, the count 0")
		return
	}
	agree := has_count && len(bytes) == size_of(words)
	if agree {
		count = words[0]
		for word in words {
			if word != count {
				agree = false
			}
		}
	}
	restored_good = agree && !note_damaged
	switch {
	case count_status == .Damaged:
		restored = "WRONG: the count is damaged on the disk: tab writes a new count"
		system.log("notes: WRONG: the storage service cannot give the count: the object is damaged")
	case !agree:
		restored = "WRONG: the 3 blocks of the count do not agree"
		system.log("notes: WRONG: the 3 blocks of the count do not agree")
	case note_damaged:
		restored = "WRONG: the note is damaged on the disk: a key writes a new note"
		system.log("notes: WRONG: the storage service cannot give the note: the object is damaged; restored the count ", count, ", its 3 blocks agree")
	case:
		restored = "restored at the start: the note and the count, 3 blocks agree"
		system.log("notes: restored the note \"", string(note[:note_count]), "\" and the count ", count, ", its 3 blocks agree", count % RUN_STEPS != 0 ? ", the last run stopped before its end" : "")
	}
}

draw :: proc "contextless" (window: ^display.Window) {
	if drawing.now.records == nil {
		drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	}
	frame := interface.window_frame_begin(&drawing, window)
	table := frame.table
	interface.draw_rectangle(table, 0, 0, WIDTH, HEIGHT, graphics.COLOR_BACKGROUND)
	buffer: [32]u8
	x := interface.draw_text(table, 12, 12, "note  ", graphics.COLOR_DIM)
	x = interface.draw_text(table, x, 12, string(note[:note_count]), graphics.COLOR_TEXT)
	interface.draw_rectangle(table, x + 1, 12, 2, 16, COLOR_LIT)
	x = interface.draw_text(table, 12, 40, "count ", graphics.COLOR_DIM)
	x = interface.draw_text(table, x, 40, system.format(buffer[:], count), COLOR_LIT)
	if generation > 0 { // The generation of the last commit of this program, after its first change.
		x = interface.draw_text(table, x + 24, 40, "generation ", graphics.COLOR_DIM)
		interface.draw_text(table, x, 40, system.format(buffer[:], generation), graphics.COLOR_TEXT)
	}
	// The drawing: one cell for each step of the count, 400 cells.
	for cell in 0 ..< 400 {
		cell_x := 12 + cell % 50 * 10
		cell_y := 68 + cell / 50 * 10
		interface.draw_rectangle(table, cell_x, cell_y, 8, 8, u64(cell) < count % 400 ? COLOR_LIT : graphics.COLOR_TRACK)
	}
	interface.draw_text(table, 12, 156, restored, restored_good ? graphics.COLOR_PROGRAM : graphics.COLOR_FAILED)
	// The last line follows the status line with no empty band. When the
	// store is gone, the keys write nothing that stays: the line says that
	// in their place.
	if gone {
		interface.draw_text(table, 12, 172, "the grant of the store ended: the program keeps nothing", graphics.COLOR_FAILED)
	}
	// The versions of the note: one mark for each state, the shown one lit.
	count := history_count()
	x = interface.draw_text(table, 12, 196, "versions of the note ", graphics.COLOR_DIM)
	x = interface.draw_text(table, x, 196, system.format(buffer[:], max(history_total - 1, 0)), graphics.COLOR_TEXT)
	if shown >= 0 {
		x = interface.draw_text(table, x + 16, 196, "showing generation ", graphics.COLOR_DIM)
		x = interface.draw_text(table, x, 196, system.format(buffer[:], history[shown].generation), COLOR_LIT)
		if history[shown].date != 0 {
			interface.draw_text(table, x + 16, 196, calendar.iso_text(buffer[:], history[shown].date), graphics.COLOR_TEXT)
		}
	}
	track := WIDTH - 24
	interface.draw_rectangle(table, 12, 218, track, 4, graphics.COLOR_TRACK)
	if count > 0 {
		for place in 0 ..< count {
			mark_x := 12 + (count == 1 ? track - 4 : place * (track - 4) / (count - 1))
			lit := place == shown || shown < 0 && place == count - 1
			interface.draw_rectangle(table, mark_x, lit ? 212 : 214, lit ? 4 : 2, lit ? 16 : 12, lit ? COLOR_LIT : graphics.COLOR_DIM)
		}
	}
	if shown >= 0 {
		x = interface.draw_text(table, 12, 236, "version  ", graphics.COLOR_DIM)
		interface.draw_text(table, x, 236, string(shown_text[:shown_count]), graphics.COLOR_TEXT)
	}
	interface.draw_text(table, 12, HEIGHT - 26, "keys: a note; up, down: its versions; enter: restore the version shown; tab: count 1000", graphics.COLOR_DIM)
	interface.window_frame_end(&drawing, &frame, window)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "notes")
	if !ok {
		system.stop(1)
	}
	if client, ok = storage.open(ctx); !ok {
		restored, gone = "no store: the program keeps nothing", true
		system.log("notes: no store")
	} else {
		restore()
		history_read()
	}
	for {
		draw(&window)
		wait: system.Wait
		display.wait_events(&wait, &window)
		system.wait_end(&wait)
		for event in display.next_event(&window) {
			if event.kind != .Key || !event.pressed {
				continue
			}
			switch event.code {
			case display.KEY_UP:
				if shown < 0 {
					history_read()
					show(history_count() - 2)
				} else if shown > 0 {
					show(shown - 1)
				}
				continue
			case display.KEY_DOWN:
				if shown >= 0 {
					show(shown + 1)
				}
				continue
			case display.KEY_ESCAPE:
				shown = -1
				continue
			}
			if shown >= 0 && event.character == '\n' {
				// Restore the version shown: one commit, and the note before it
				// becomes a version.
				generation_shown := history[shown].generation
				started := system.nanoseconds()
				commit, status := storage.restore(&client, "note", generation_shown)
				restore_time_last = (system.nanoseconds() - started) / 1000
				if status == .Ok && commit > 0 {
					generation = commit
					note_count = copy(note[:], shown_text[:shown_count])
					system.log("notes: restored the version of generation ", generation_shown, ": \"", string(note[:note_count]), "\", in the commit of generation ", commit, " in ", restore_time_last, " us; the note before it is a version")
				}
				shown = -1
				history_read()
				continue
			}
			shown = -1
			switch event.character {
			case '\t':
				started := system.time()
				for step in 1 ..= RUN_STEPS {
					count += 1
					if !keep_count() {
						break
					}
					if step == RUN_STEPS {
						system.log("notes: count ", count, ", stopped: ", u64(RUN_STEPS), " commits in ", system.time() - started, " ms")
						measure_started := system.nanoseconds()
						_, total, status := storage.versions(&client, "count", count_versions[:])
						if status == .Ok {
							system.log("notes: the versions of the count: ", total, " rows in ", (system.nanoseconds() - measure_started) / 1000, " us")
						}
					} else if step % 100 == 0 {
						system.log("notes: count ", count)
						draw(&window)
					}
				}
			case '\n':
				history_read()
				system.log("notes: the note is \"", string(note[:note_count]), "\", generation ", generation, ", ", u64(max(history_total - 1, 0)), " versions; one commit of the note: ", commit_time_total / max(commit_count, 1), " us in the mean of ", commit_count)
			case 8:
				if note_count > 0 {
					note_count -= 1
					keep("note", note[:note_count])
					history_read()
				}
			case ' ' ..= '~':
				if note_count < NOTE_CAPACITY {
					note[note_count] = event.character
					note_count += 1
					keep("note", note[:note_count])
					history_read()
				}
			}
		}
	}
}
