package kerneltool

import "core:fmt"
import "core:strings"
import "core:time"

// The echo of a line of the console
// (docs/TOOLS.md, "How the tool sends input and waits").
//
// The keys of a step Type go through four queues before the console has
// them. "The system read each byte of the keyboard" says nothing of the
// last three. The console writes each line that it enters on the log, as
// "[console] > text", before it runs the line: that line of the log says
// that each key of the step, its Enter included, reached the console in
// order. So, after the keys of a step Type that goes to the console, the
// tool waits for that echo. A lost key then fails at the step that typed
// it, with the line in the message, not at a later step Wait.
//
// The tool waits only when it knows that the line goes to the console and
// can be entered now:
//
// - The console is in front: the last step that changed the front window
//   was the step Front of the console. A step Launch, Move, Close, Click
//   or Drag, the key of the launcher, and a line that starts a program
//   make the front window unknown, and the tool then waits for no echo.
// - No line can still run: a step Wait passed since the step Type before.
//   The console enters a line only after the line before it ended, so a
//   line typed with no Wait since the line before it is owed: the tool
//   waits for its echo, in order, at the next line that has a Wait before
//   it.

CONSOLE_TITLE :: "console"
CONSOLE_ECHO_START :: "[console] > "
LAUNCHER_KEY :: "meta_l"
// The texts of the log lines of a lost record, in the programs of the path
// of a key: the failure message of an echo shows each such line.
loss_line_marks := [?]string{" is lost", " are lost", " were lost", "input: the input ring is full"}

Console_Echo :: struct {
	console_in_front: bool, // The last step that changed the front window was the step Front of the console.
	line_can_run:     bool, // A step Type went to the console, and no step Wait passed since.
	owed:             [dynamic]string, // The lines typed into the console whose echo the tool did not see yet, the oldest first.
	from:             int, // The bytes of the log before the echo of the first owed line.
}

// console_echo_note_step keeps what the tool knows of the console after a
// step that passed.
console_echo_note_step :: proc(echo: ^Console_Echo, step: Step) {
	#partial switch step.kind {
	case .Front:
		echo.console_in_front = step.text == CONSOLE_TITLE
	case .Launch, .Move, .Close, .Click, .Drag:
		echo.console_in_front = false
	case .Key:
		if step.text == LAUNCHER_KEY {
			echo.console_in_front = false
		}
	case .Type:
		if echo.console_in_front {
			echo.line_can_run = true
		}
		// The window of a program that the line starts comes to the front.
		if strings.contains(step.text, "start(") {
			echo.console_in_front = false
		}
	case .Wait:
		echo.line_can_run = false
	}
}

// console_echo_wanted says if the console echoes the line of a step Type:
// the console is in front, and the line has text (the console writes no
// echo for an empty line).
console_echo_wanted :: proc(echo: ^Console_Echo, text: string) -> bool {
	return echo.console_in_front && len(text) > 0
}

// console_echo_end gives the place in the log after the echo of a line,
// searched from a place, or -1. The echo is the whole line of the log
// after its program: "> 4" is not the echo of "> 41".
console_echo_end :: proc(log: string, from: int, line: string) -> int {
	place := clamp(from, 0, len(log))
	for {
		at := strings.index(log[place:], CONSOLE_ECHO_START)
		if at < 0 {
			return -1
		}
		start := place + at + len(CONSOLE_ECHO_START)
		rest := log[start:]
		if strings.has_prefix(rest, line) {
			after := rest[len(line):]
			if strings.has_prefix(after, "\n") || strings.has_prefix(after, "\r\n") {
				return start + len(line)
			}
		}
		place = start
	}
}

// loss_lines_of_log gives the lines of the log, from a place, that say
// that a queue of the path of a key refused a record or held its writer.
loss_lines_of_log :: proc(log: string, from: int, allocator := context.temp_allocator) -> []string {
	lines := make([dynamic]string, allocator)
	rest := log[clamp(from, 0, len(log)):]
	for line in strings.split_lines_iterator(&rest) {
		for mark in loss_line_marks {
			if strings.contains(line, mark) {
				append(&lines, strings.trim_right(line, "\r"))
				break
			}
		}
	}
	return lines[:]
}

// console_echo_owe keeps a line that the tool types into the console now.
// Call it before the keys: the echo can be on the log before the tool
// knows that the system read the last key.
console_echo_owe :: proc(machine: ^Machine, text: string) {
	echo := &machine.echo
	if len(echo.owed) == 0 {
		echo.from = len(log_read(machine))
	}
	// The text of a step can be memory of one step: the tool keeps a copy.
	append(&echo.owed, strings.clone(text))
}

// console_echo_wait waits until the log has the echo of each owed line, in
// the order in which the tool typed them. A time here only ends a hang.
console_echo_wait :: proc(machine: ^Machine, step_number: int) -> bool {
	echo := &machine.echo
	typed_from := echo.from
	for start := time.tick_now(); time.tick_since(start) < HANG_BOUND; {
		log := log_read(machine)
		for len(echo.owed) > 0 {
			end := console_echo_end(log, echo.from, echo.owed[0])
			if end < 0 {
				break
			}
			echo.from = end
			delete(echo.owed[0])
			ordered_remove(&echo.owed, 0)
		}
		if len(echo.owed) == 0 {
			return true
		}
		if machine.qmp.ended {
			break // The machine ended: the echo will not come.
		}
		log_change_wait(machine)
	}
	fmt.eprintfln("kerneltool: test failed: step %d: the tool typed the line \"%s\" into the console, and the console did not write its echo \"%s%s\" on the log within %v: a key of the line did not reach the console, or the line before it did not end", step_number, echo.owed[0], CONSOLE_ECHO_START, echo.owed[0], HANG_BOUND)
	if machine.confirm {
		if values, read := record_fields(&machine.client, "compositor.pointer()", {"keys", "keys_waiting", "keys_refused"}); read {
			fmt.eprintfln("kerneltool: the compositor: %d key records from the input service since the start, %d wait for a window whose ring is full, %d refused (lost)", values[0], values[1], values[2])
		} else {
			fmt.eprintln("kerneltool: the tool could not read the counts of the key records of the compositor")
		}
	} else {
		fmt.eprintln("kerneltool: the tool does not call the compositor in this part of the scenario: it has no count of its key records")
	}
	lines := loss_lines_of_log(log_read(machine), typed_from)
	if len(lines) == 0 {
		fmt.eprintln("kerneltool: the log has no line of a lost record and no line of a full input ring since the line was typed")
	}
	for line in lines {
		fmt.eprintfln("kerneltool: the log says: %s", line)
	}
	return false
}
