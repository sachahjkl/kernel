// The console: a program that has a terminal. The input
// types expressions of a small language. A command is a function with typed
// parameters and a typed result; it is not a separate program, and it does
// not parse text.
//
// **What it is for.** The console is the place where the principal talks to
// the system. It shows that a [command](term:command) is a function: the
// console reads the [record description](term:record-description) of each
// [export](term:export) of a module, types each argument from it, calls the
// export, and draws the typed result by its kind: an Integer, a Text, a
// Record, a Table, a Handle, Bytes or an error. No command parses a line of
// text, and no command prints: a command gives a result, and the console
// draws it (docs/CONSOLE.md, "Results and their drawers"). The same description serves a [direct call](term:direct-call), an
// [isolated call](term:isolated-call) and a call to a [service](term:service).
//
// **What a reader sees.** The root service starts the console at each
// boot, after the compositor and `date`. The console has no surface: it
// writes records to its [terminal](term:terminal) and reads keys from it
// (support/terminal); the program `terminal` draws them in a window. The
// first line is `kernel console. A command is a typed function: try
// help()`, and the log gets `console: ready`. Each line that the input
// enters goes to the log too, after the prompt `> `.
//
// **The language** (`language.odin`): a line is an expression or
// `name = expression`. A value is an Integer, a Text, a Record, a Handle, a
// Table or Bytes. Examples of lines:
//
// ```
// help()
// x = 6 * 7
// load("math")
// connect("log")
// log.records(0)
// where(log.records(0), "level", "error")
// start("life")
// where(grants("remote"), "state", "held")
// sort(where(programs(), "state", "waiting"), "name")
// ```
//
// **The commands of the console itself** (`commands.odin`, `tables.odin`):
//
// - Modules: `modules()`, `load(name)` (a direct call: the module runs with
//   the memory and the handles of the console), `isolate(name)` (an
//   isolated call: the module runs in a [call host](term:call-host), with
//   nothing of the console), `unload(name)`, `loaded()`.
// - Services: `connect(name)` makes each export of a running service a
//   command `name.export`.
// - Programs: `programs()` (the export `monitor.programs`, under a short
//   name), `program_modules()`, `start(name)`, `stop(name)`,
//   `grants(name)`, `revoke(name, grant)`.
// - Principals: `principal_create(name)`, `lock()`, `principals()`.
// - Replacements: `replace(module, other)`, `replacements()`.
// - Tables: `where`, `sort`, `join`, `columns`, `first`, `skip`, `rows`,
//   `row`.
// - Others: `help()`, `describe(name)`, `memory()`, `locks()`, `time()`,
//   `hash(text)`, `buffer(pages)`, `bytes(memory, first, count)`,
//   `variables()`, `clear()`, `shutdown()`, `history_clear()`.
//
// **The log records of a line.** While a line calls an export, the console
// shows under the line the log records that the called program writes, by
// channel, with each value in the color of its value kind. It reads them
// as any caller does: from the service `log`
// (docs/CONSOLE.md, "The log records of a line").
//
// **The keys** (docs/CONSOLE.md, "1. The keys"): Enter runs the line; Tab
// and the typed name open the [completion list](term:completion-list); Up
// and Down walk the [line history](term:line-history); Escape stops an
// isolated call that does not return.
//
// **The two threads.** The first thread reads the keys and owns the
// [edit line](term:edit-line), the line history and the completion list.
// The second thread runs the lines. During a line, the first thread keeps
// the keys that the input types, shows the time of the line, and stops an
// isolated call when the input presses Escape. A slow command never
// freezes the edit line.
//
// **Its grants** (the root service, `grants_of`), each for one group of
// commands:
//
// - **Root_Ring**: start and stop programs, and connect to every service.
// - **Inspect**: `memory()`, `locks()` and `program_modules()` read the
//   reports of the machine.
// - **Stop**: `shutdown()` stops the machine.
// - **Image** and **Debug_Image**: `load` and `isolate` read modules of the
//   boot image; a stop report of an isolated call names its procedures.
// - **Terminal**: its terminal.
// - **Store**: a private store in the storage service.
// - **Acts_For_Principal**: a service shows it what it holds for all
//   callers (the log records, the programs of `monitor`).
// - **Replacements** and **Replace**: read and change the
//   [replacement table](term:replacement-table).
// - **History_Store**: the store of its line history, apart from its
//   private store (docs/CONSOLE.md, "6. The line history across a stop").
//
// Its budget has room for 5 programs and 6 threads: the console, its 4
// [sandboxes](term:sandbox) of isolated calls, and their threads.
//
// **What it does not prove.** The console acts for principal 0 only: the
// storage service refuses it the stores of a
// [named principal](term:named-principal) (docs/PRINCIPALS.md). It does not
// show that a program that is not the console cannot reach these commands:
// that is the work of the grants of the root service.
package console

import "support:display"
import "support:line_editor"
import "support:random"
import "support:system"
import terminal "support:terminal"
import "base:intrinsics"

CONSOLE_MARK :: "console: ready"

LINE_CAPACITY :: line_editor.LINE_CAPACITY
PROMPT :: "> "
PENDING_CAPACITY :: 128
STATUS_INTERVAL :: 100 // Milliseconds between two texts of the time of a line.

Key :: terminal.Key

// The line that the second thread runs. The two threads share this record.
Work :: struct {
	text:     [LINE_CAPACITY]u8,
	count:    int,
	since:    u64, // The time when the line started.
	started:  u32, // The lines that the first thread gave. The second thread waits on this word.
	finished: u32, // The lines that the second thread ran.
	cancel:   u32, // 1: the input pressed Escape. An isolated call waits on this word.
}

work: Work
running: bool // For the first thread: a line runs.
pending: [PENDING_CAPACITY]Key // The keys that the input typed during a line.
pending_count: int
// The second thread adds 1 when it ends a line. The first thread waits on
// this word.
changes: u32
// The terminal ring has one writer: the two threads write with this lock.
output_lock: system.Lock

output: terminal.Terminal
line: line_editor.Line
// The lines entered so far. Up and Down walk them: history_place 0 is the
// line that the input types (kept in draft while an older line shows),
// n the line of age n - 1.
history: line_editor.History
history_place: int
draft: line_editor.Line
// The output line that goes to the log of the kernel when it ends: one Log
// call takes system.LOG_CALL_LIMIT bytes. A longer line goes to the log in
// parts of that size, each one a line of the log: nothing is cut.
log_line: [system.LOG_CALL_LIMIT]u8
log_count: int

ctx: ^system.Context

// The random generator of this program (support/random).
program_generator: random.Generator

// entry starts the console and runs its first thread: it reads the keys
// until the machine stops.
//
// **What it sets up**, in order:
//
// 1. The random generator, from the seed that the root service wrote in the
//    context: it gives the seed of each program that the console starts.
// 2. The terminal (`terminal.open`).
// 3. The commands (`commands_start`): it maps the boot image, the debug
//    image, the root ring and the replacement table that the root service
//    granted, and lists the commands of the console.
// 4. The second thread, `run_lines`, which runs each line.
// 5. The first line on the terminal, the edit line, and the log record
//    `console: ready`.
// 6. The line history of the run before, from its store (`history_load`).
//
// **The loop.** The thread takes each key of the terminal ring. With no
// line running, the key edits the line, opens the completion list, walks
// the history, or runs the line (`key`). While a line runs, Escape asks the
// second thread to stop the isolated call, and each other key waits, in
// order, until the line ends (at most 128 keys). The thread then waits for
// a key, for a change of the second thread, or for 100 ms while a line
// runs, so that the time of the line on the screen moves.
//
// **The stop.** With no random seed, no terminal or no second thread, the
// console writes the reason on the log (`console: no terminal`) and stops
// with the code 1. Else it never returns: `stop("console")` or
// `shutdown()` ends it.
@(export, link_name = "entry")
entry :: proc "c" (start_context: ^system.Context) -> ! {
	// The random generator of this program, from the seed that its starter
	// gave: it gives the seed of each program that this one starts.
	if !random.generator_from_context(&program_generator, start_context) {
		system.log("console: no random seed in the context")
		system.stop(1)
	}
	ctx = start_context
	ok: bool
	if output, ok = terminal.open(ctx); !ok {
		system.log("console: no terminal")
		system.stop(1)
	}
	commands_start()
	if _, status := system.thread_start(run_lines, nil); status != .Ok {
		system.log("console: cannot start a thread")
		system.stop(1)
	}
	print("kernel console. A command is a typed function: try help()\n")
	edit_show()
	system.log(CONSOLE_MARK)
	// The line history of the run before. The second thread runs no line
	// yet: the history has one user. The keys that come meanwhile wait in
	// the terminal ring.
	history_load()

	for {
		seen := intrinsics.atomic_load_explicit(&changes, .Relaxed)
		for {
			pressed := terminal.key(&output) or_break
			if !running {
				key(pressed)
			} else if pressed.code == display.KEY_ESCAPE {
				system.log("console: Escape stops the line after ", system.time() - work.since, " ms; keys that wait: ", u64(pending_count))
				intrinsics.atomic_store(&work.cancel, 1)
				system.word_wake(&work.cancel)
			} else if pending_count < PENDING_CAPACITY {
				// Each key but Escape waits for the end of the line, in order.
				pending[pending_count] = pressed
				pending_count += 1
			}
		}
		if running && intrinsics.atomic_load_explicit(&work.finished, .Relaxed) == work.started {
			running = false
			// The keys that waited, until one of them starts a line.
			taken := 0
			for taken < pending_count && !running {
				key(pending[taken])
				taken += 1
			}
			copy(pending[:], pending[taken:pending_count])
			pending_count -= taken
		}
		edit_show()
		wait: system.Wait
		system.wait_records(&wait, &output.ring.completions)
		system.wait_word(&wait, &changes, seen)
		system.wait_end(&wait, running ? system.time() + STATUS_INTERVAL : system.WAIT_FOREVER)
	}
}

// run_lines is the entry of the second thread: it runs each line that the
// first thread gives.
run_lines :: proc "c" (parameter: rawptr) -> ! {
	done: u32
	for {
		system.word_wait(&work.started, done)
		if intrinsics.atomic_load_explicit(&work.started, .Relaxed) == done {
			continue
		}
		done += 1
		services_check()
		run_line(string(work.text[:work.count]))
		// The line history goes to its store while the line still counts
		// as running: the first thread adds no line to it meanwhile.
		history_save()
		intrinsics.atomic_store(&work.finished, done)
		change()
	}
}

// change tells the first thread that the second thread changed something.
change :: proc "contextless" () {
	intrinsics.atomic_add(&changes, 1)
	system.word_wake(&changes)
}

// key acts on one key while no line runs. The completion list takes the
// key first when it is open; else Enter runs the line, Tab completes, Up
// and Down walk the line history, and a printable key edits the line.
key :: proc "contextless" (pressed: Key) {
	if completion_key(pressed) {
		return
	}
	switch {
	case pressed.code == display.KEY_ENTER:
		line_enter()
	case pressed.code == display.KEY_TAB:
		completion_tab()
	case pressed.code == display.KEY_UP:
		history_walk(1)
	case pressed.code == display.KEY_DOWN:
		history_walk(-1)
	case pressed.modifiers & display.MODIFIER_CONTROL != 0:
		// Control with a key that no list takes: the character is not typed.
	case:
		edit_key := edit_key_of(pressed)
		if line_editor.line_key(&line, edit_key, pressed.character) {
			completion_after_edit(edit_key)
		}
	}
}

// line_enter makes the line a line of the terminal, and gives it to the
// second thread.
line_enter :: proc "contextless" () {
	text := line_editor.line_text(&line)
	system.lock(&output_lock)
	echo_write(text)
	system.unlock(&output_lock)
	if len(text) > 0 {
		line_editor.history_add(&history, text)
		system.log(PROMPT, text)
		work.count = copy(work.text[:], text)
		work.since = system.time()
		intrinsics.atomic_store(&work.cancel, 0)
		running = true
		intrinsics.atomic_add(&work.started, 1)
		system.word_wake(&work.started)
	}
	history_place = 0
	line_editor.line_clear(&line)
	completion_close()
}

// history_walk shows an older line (step 1) or a newer one (step -1). The
// line that the input typed comes back after the newest line.
history_walk :: proc "contextless" (step: int) {
	place := history_place + step
	if place < 0 {
		return
	}
	if place == 0 {
		line = draft
		history_place = 0
		return
	}
	text, ok := line_editor.history_line(&history, place - 1)
	if !ok {
		return
	}
	if history_place == 0 {
		draft = line
	}
	history_place = place
	line_editor.line_set(&line, text)
}

// edit_show gives to the terminal the line that it shows after the last
// line: the edit line with a cursor; or, while a line runs, its
// time and the keys that wait. The terminal gets a record only when the
// text changes.
shown: [terminal.RUN_LIMIT]u8
shown_count := -1
shown_cursor: u64

edit_show :: proc "contextless" () {
	buffer: [terminal.RUN_LIMIT]u8
	writer := system.Writer {
		buffer = buffer[:],
	}
	cursor := terminal.NO_CURSOR
	style: terminal.Style
	if running {
		elapsed := system.time() - work.since
		system.write_part(&writer, "runs ")
		system.write_part(&writer, elapsed / 1000)
		system.write_part(&writer, ".")
		system.write_part(&writer, elapsed / 100 % 10)
		system.write_part(&writer, " s. Escape stops an isolated call. Keys that wait: ")
		for waiting in pending[:pending_count] {
			shown_key: u8 = '^' // A key with no character: an arrow key, Control with a key.
			switch {
			case waiting.code == display.KEY_ENTER:
				shown_key = '|'
			case waiting.code == display.KEY_BACKSPACE:
				shown_key = '<'
			case waiting.code == display.KEY_TAB:
				shown_key = '>'
			case waiting.modifiers & display.MODIFIER_CONTROL == 0 && line_editor.printable(waiting.character):
				shown_key = waiting.character
			}
			character := [1]u8{shown_key}
			system.write_part(&writer, string(character[:]))
		}
		style.tone = .Warning
	} else {
		system.write_part(&writer, PROMPT)
		system.write_part(&writer, line_editor.line_text(&line))
		cursor = u64(len(PROMPT) + line.caret)
	}
	text := system.written(&writer)
	system.lock(&output_lock)
	defer system.unlock(&output_lock)
	if shown_count != len(text) || string(shown[:max(shown_count, 0)]) != text || cursor != shown_cursor {
		shown_count = copy(shown[:], text)
		shown_cursor = cursor
		// The edit line is code: its runs go first, and the Edit
		// that follows takes them. The time of a line that runs has none.
		if !running {
			runs: [terminal.CODE_RUN_LIMIT]terminal.Code_Run
			run_count := edit_runs(text, int(cursor), runs[:])
			terminal.code_runs_send(&output, .Edit, 0, runs[:run_count])
		}
		terminal.edit(&output, text, cursor, style)
	}
	completion_show()
}

// The columns of the window of the console: the root service gives its
// terminal 96 columns (programs/root, terminal_of). The terminal draws no
// byte past its last column, so the console starts a new row there: a long
// value goes on under its own start, and no byte of it is lost.
WINDOW_COLUMNS :: 96

output_column: int // The column after the last byte of the row that the console writes now.
output_continuation: int // The column where a line that is too long goes on.
output_logged := true // The lines also go to the log of the kernel.

// emit writes one part of an output line: on the terminal with its style,
// and in the line of the log of the kernel. A line longer than the window
// goes on in the next row, at output_continuation; the log has the line
// whole. The caller holds output_lock.
emit :: proc "contextless" (text: string, style: terminal.Style) {
	if output_logged {
		// The log: a line longer than one Log call goes in parts.
		logged := text
		for len(logged) > 0 {
			taken := copy(log_line[log_count:], logged)
			log_count += taken
			logged = logged[taken:]
			if log_count == len(log_line) {
				system.log_text(string(log_line[:log_count]))
				log_count = 0
			}
		}
	}
	rest := text
	for len(rest) > 0 {
		if output_column >= WINDOW_COLUMNS {
			terminal.write(&output, terminal.Run{"", {flags = {.End_Line}}})
			blank := "                                                "
			output_column = clamp(output_continuation, 0, len(blank))
			if output_column > 0 {
				terminal.write(&output, terminal.Run{blank[:output_column], {}})
			}
		}
		part := rest[:min(len(rest), WINDOW_COLUMNS - output_column)]
		terminal.write(&output, terminal.Run{part, style})
		output_column += len(part)
		rest = rest[len(part):]
	}
}

// emit_end ends the output line: on the terminal, and on the log when the
// line has bytes. The caller holds output_lock.
emit_end :: proc "contextless" () {
	terminal.write(&output, terminal.Run{"", {flags = {.End_Line}}})
	output_column = 0
	if output_logged && log_count > 0 {
		system.log_text(string(log_line[:log_count]))
		log_count = 0
	}
}

// print writes a text of the console itself, as its first line: plain
// lines on the terminal and on the log. No command prints: the result of a
// line goes through the drawers (results.odin).
print :: proc "contextless" (text: string) {
	system.lock(&output_lock)
	defer system.unlock(&output_lock)
	rest := text
	for len(rest) > 0 {
		end := 0
		for end < len(rest) && rest[end] != '\n' {
			end += 1
		}
		emit(rest[:end], {})
		if end < len(rest) {
			emit_end()
		}
		rest = rest[min(end + 1, len(rest)):]
	}
}

// screen_clear makes the terminal forget its lines.
screen_clear :: proc "contextless" () {
	system.lock(&output_lock)
	terminal.clear(&output)
	output_column = 0
	system.unlock(&output_lock)
}
