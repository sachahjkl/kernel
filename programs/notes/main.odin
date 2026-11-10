// A program that keeps its state when it stops and when the machine stops: a note and a count, in its private store.
//
// Each change goes to the storage service when it happens: the program has no save action. The note is the object "note". The count is the object "count": three blocks that each hold the count in each of their 512 numbers, so that a part of one commit with a part of another would show.
//
// Keys: a character adds to the note, Backspace removes the last one, Enter writes the note on the log. Tab counts 1000 more, one commit for each step.
package notes

import "contract:errors"
import "support:display"
import "support:graphics"
import "support:storage"
import "support:system"

WIDTH :: 560
HEIGHT :: 238
NOTE_CAPACITY :: 60
COUNT_BLOCKS :: 3
COUNT_WORDS :: COUNT_BLOCKS * 512
RUN_STEPS :: 1000

COLOR_PAPER :: 0x141A20
COLOR_TEXT :: 0xD8E0E8
COLOR_DIM :: 0x7A8794
COLOR_GOOD :: 0x58D878
COLOR_BAD :: 0xF06060
COLOR_CELL :: 0x232C38
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

// keep writes one object. It gives false when the store is gone or refuses.
keep :: proc "contextless" (name: string, data: []u8) -> bool {
	error: errors.Error_Record
	result, status := storage.write(&client, name, data, &error)
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
	canvas := window.canvas
	graphics.clear(canvas, COLOR_PAPER)
	buffer: [32]u8
	x := graphics.text(canvas, 12, 12, "note  ", COLOR_DIM)
	x = graphics.text(canvas, x, 12, string(note[:note_count]), COLOR_TEXT)
	graphics.fill(canvas, x + 1, 12, 2, 16, COLOR_LIT)
	x = graphics.text(canvas, 12, 40, "count ", COLOR_DIM)
	x = graphics.text(canvas, x, 40, system.format(buffer[:], count), COLOR_LIT)
	if generation > 0 { // The generation of the last commit of this program, after its first change.
		x = graphics.text(canvas, x + 24, 40, "generation ", COLOR_DIM)
		graphics.text(canvas, x, 40, system.format(buffer[:], generation), COLOR_TEXT)
	}
	// The drawing: one cell for each step of the count, 400 cells.
	for cell in 0 ..< 400 {
		cell_x := 12 + cell % 50 * 10
		cell_y := 68 + cell / 50 * 10
		graphics.fill(canvas, cell_x, cell_y, 8, 8, u64(cell) < count % 400 ? COLOR_LIT : COLOR_CELL)
	}
	graphics.text(canvas, 12, 156, restored, restored_good ? COLOR_GOOD : COLOR_BAD)
	if gone {
		graphics.text(canvas, 12, 180, "the grant of the store ended: the program keeps nothing", COLOR_BAD)
	}
	graphics.text(canvas, 12, HEIGHT - 26, "keys: a note; tab: count 1000, one commit each", COLOR_DIM)
	display.present(window)
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
					} else if step % 100 == 0 {
						system.log("notes: count ", count)
						draw(&window)
					}
				}
			case '\n':
				system.log("notes: the note is \"", string(note[:note_count]), "\", generation ", generation)
			case 8:
				if note_count > 0 {
					note_count -= 1
					keep("note", note[:note_count])
				}
			case ' ' ..= '~':
				if note_count < NOTE_CAPACITY {
					note[note_count] = event.character
					note_count += 1
					keep("note", note[:note_count])
				}
			}
		}
	}
}
