// The console: a program that has a terminal. The person
// types expressions of a small language. A command is a function with typed
// parameters and a typed result; it is not a separate program, and it does
// not parse text.
//
// The console has no surface. It writes records to its terminal, and reads
// the keys of the person from it (support/terminal). It owns the line that
// the person edits, with a caret inside it (support/line_editor), the
// history of the lines, and the completion list (completion.odin): the
// terminal draws them.
//
// The console has two threads. The first thread reads the keys. The second
// thread runs the lines. During a line, the first thread keeps the keys
// that the person types, shows the time of the line, and stops an isolated
// call when the person presses Escape.
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
	cancel:   u32, // 1: the person pressed Escape. An isolated call waits on this word.
}

work: Work
running: bool // For the first thread: a line runs.
pending: [PENDING_CAPACITY]Key // The keys that the person typed during a line.
pending_count: int
// The second thread adds 1 when it ends a line. The first thread waits on
// this word.
changes: u32
// The terminal ring has one writer: the two threads write with this lock.
output_lock: system.Lock

output: terminal.Terminal
line: line_editor.Line
// The lines entered so far. Up and Down walk them: history_place 0 is the
// line that the person types (kept in draft while an older line shows),
// n the line of age n - 1.
history: line_editor.History
history_place: int
draft: line_editor.Line
// The output line that goes to the log of the kernel when it ends: one Log
// call takes system.LOG_CALL_LIMIT bytes. A longer line goes to the log in
// parts of that size, each one a line of the log: nothing is cut.
log_line: [system.LOG_CALL_LIMIT]u8
log_count: int
line_tone: terminal.Tone // The tone of the output line that the console writes now.

ctx: ^system.Context

// The random generator of this program (support/random).
program_generator: random.Generator

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
// line that the person typed comes back after the newest line.
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
// line: the line of the person with a cursor; or, while a line runs, its
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
		// The line of the person is code: its runs go first, and the Edit
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

// print writes output: runs of text on the terminal, and each full line on
// the log of the kernel. A line that starts with "error" has the tone Bad.
// Each part goes whole, at any length: a Text part is written as it is,
// with no buffer between, and a number is formatted on its own.
print :: proc "contextless" (parts: ..system.Part) {
	system.lock(&output_lock)
	defer system.unlock(&output_lock)
	for part in parts {
		if text, is_text := part.(string); is_text {
			print_text(text)
			continue
		}
		number: [32]u8
		print_text(system.format(number[:], part))
	}
}

// print_text writes one text, in parts at each end of a line. The caller
// holds output_lock.
print_text :: proc "contextless" (given: string) {
	text := given
	for len(text) > 0 {
		end := 0
		for end < len(text) && text[end] != '\n' {
			end += 1
		}
		part := text[:end]
		ends := end < len(text)
		text = text[min(end + 1, len(text)):]
		if log_count == 0 && len(part) >= 5 && part[:5] == "error" {
			line_tone = .Bad
		}
		// The log: a line longer than one Log call goes in parts.
		rest := part
		for len(rest) > 0 {
			taken := copy(log_line[log_count:], rest)
			log_count += taken
			rest = rest[taken:]
			if log_count == len(log_line) {
				system.log_text(string(log_line[:log_count]))
				log_count = 0
			}
		}
		terminal.write(&output, terminal.Run{part, {tone = line_tone, flags = ends ? {.End_Line} : {}}})
		if ends {
			if log_count > 0 {
				system.log_text(string(log_line[:log_count]))
			}
			log_count, line_tone = 0, .Default
		}
	}
}

// screen_clear makes the terminal forget its lines.
screen_clear :: proc "contextless" () {
	system.lock(&output_lock)
	terminal.clear(&output)
	system.unlock(&output_lock)
}
