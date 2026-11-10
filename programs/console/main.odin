// The console (property 19): a program that has a terminal. The person
// types expressions of a small language. A command is a function with typed
// parameters and a typed result; it is not a separate program, and it does
// not parse text.
//
// The console has no surface. It writes records to its terminal, and reads
// the keys of the person from it (support/terminal). It owns the line that
// the person edits, and the lines before: the terminal draws them.
//
// The console has two threads. The first thread reads the keys. The second
// thread runs the lines. During a line, the first thread keeps the keys
// that the person types, shows the time of the line, and stops an isolated
// call when the person presses Escape.
package console

import "support:display"
import "support:system"
import "support:terminal"
import "base:intrinsics"

CONSOLE_MARK :: "console: ready"

LINE_CAPACITY :: 120
HISTORY_CAPACITY :: 8
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
line: [LINE_CAPACITY]u8
line_count: int
history: [HISTORY_CAPACITY][LINE_CAPACITY]u8
history_counts: [HISTORY_CAPACITY]int
history_next: int // Lines entered so far.
history_shown: int
log_line: [192]u8 // The output line that goes to the log of the kernel when it ends.
log_count: int
line_tone: terminal.Tone // The tone of the output line that the console writes now.

ctx: ^system.Context

@(export, link_name = "entry")
entry :: proc "c" (start_context: ^system.Context) -> ! {
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

	for {
		seen := intrinsics.volatile_load(&changes)
		for {
			pressed := terminal.key(&output) or_break
			if !running {
				key(pressed)
			} else if pressed.code == display.KEY_ESCAPE {
				system.log("console: Escape stops the line after ", system.time() - work.since, " ms; keys that wait: ", u64(pending_count))
				intrinsics.atomic_store(&work.cancel, 1)
				system.word_wake(&work.cancel)
			} else if pending_count < PENDING_CAPACITY && (pressed.code == display.KEY_ENTER || pressed.code == display.KEY_BACKSPACE || pressed.character >= ' ' && pressed.character <= '~') {
				pending[pending_count] = pressed
				pending_count += 1
			}
		}
		if running && intrinsics.volatile_load(&work.finished) == work.started {
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
		if intrinsics.volatile_load(&work.started) == done {
			continue
		}
		done += 1
		services_check()
		run_line(string(work.text[:work.count]))
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
	switch {
	case pressed.code == display.KEY_ENTER:
		// The line becomes a line of the terminal.
		system.lock(&output_lock)
		terminal.line(&output, {PROMPT, {tone = .Accent}}, {string(line[:line_count]), {tone = .Strong}})
		system.unlock(&output_lock)
		if line_count > 0 {
			slot := history_next % HISTORY_CAPACITY
			history[slot] = line
			history_counts[slot] = line_count
			history_next += 1
			system.log(PROMPT, string(line[:line_count]))
			work.text, work.count = line, line_count
			work.since = system.time()
			intrinsics.atomic_store(&work.cancel, 0)
			running = true
			intrinsics.atomic_add(&work.started, 1)
			system.word_wake(&work.started)
		}
		history_shown = history_next
		line_count = 0
	case pressed.code == display.KEY_BACKSPACE:
		line_count = max(line_count - 1, 0)
	case pressed.code == display.KEY_UP || pressed.code == display.KEY_DOWN:
		shown := history_shown + (pressed.code == display.KEY_UP ? -1 : 1)
		if shown < 0 || shown < history_next - HISTORY_CAPACITY || shown > history_next {
			return
		}
		history_shown = shown
		line_count = 0
		if shown < history_next {
			line = history[shown % HISTORY_CAPACITY]
			line_count = history_counts[shown % HISTORY_CAPACITY]
		}
	case pressed.character >= ' ' && pressed.character <= '~':
		if line_count < LINE_CAPACITY {
			line[line_count] = pressed.character
			line_count += 1
		}
	}
}

// edit_show gives to the terminal the line that it shows after the last
// line: the line of the person with a cursor; or, while a line runs, its
// time and the keys that wait. The terminal gets a record only when the
// text changes.
shown: [terminal.RUN_LIMIT]u8
shown_count := -1

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
			character := [1]u8{waiting.code == display.KEY_ENTER ? '|' : waiting.code == display.KEY_BACKSPACE ? '<' : waiting.character}
			system.write_part(&writer, string(character[:]))
		}
		style.tone = .Warning
	} else {
		system.write_part(&writer, PROMPT)
		system.write_part(&writer, string(line[:line_count]))
		cursor = u64(writer.count)
	}
	text := system.written(&writer)
	if shown_count == len(text) && string(shown[:max(shown_count, 0)]) == text {
		return
	}
	shown_count = copy(shown[:], text)
	system.lock(&output_lock)
	terminal.edit(&output, text, cursor, style)
	system.unlock(&output_lock)
}

// print writes output: runs of text on the terminal, and each full line on
// the log of the kernel. A line that starts with "error" has the tone Bad.
print :: proc "contextless" (parts: ..system.Part) {
	buffer: [256]u8
	text := system.format(buffer[:], ..parts)
	system.lock(&output_lock)
	defer system.unlock(&output_lock)
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
		log_count += copy(log_line[log_count:], part)
		terminal.write(&output, terminal.Run{part, {tone = line_tone, flags = ends ? {.End_Line} : {}}})
		if ends {
			if log_count > 0 {
				system.log(string(log_line[:log_count]))
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
