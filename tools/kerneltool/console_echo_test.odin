package kerneltool

import "core:strings"
import "core:testing"

@(private = "file")
ECHO_LOG :: "[compositor] compositor: window console in front\n" + "[console] > 41\n" + "[console] 41\n" + "[console] > 4\r\n" + "[console] > connect(\"server\")\n" + "[console] > typed with no end of line"

// The echo of a line is the whole line of the log after "[console] > ":
// "> 41" is not the echo of "4", a line with no end is not complete, and
// the search starts at the place that the tool gives.
@(test)
the_echo_of_a_line_is_a_whole_line_of_the_log :: proc(t: ^testing.T) {
	log: string = ECHO_LOG
	first := console_echo_end(log, 0, "41")
	testing.expect(t, first > 0)
	if first > 0 {
		testing.expect_value(t, log[:first], "[compositor] compositor: window console in front\n[console] > 41")
	}
	four := console_echo_end(log, 0, "4")
	testing.expect(t, four > first, "the echo of 4 is after the echo of 41")
	testing.expect_value(t, console_echo_end(log, max(four, 0), "4"), -1)
	testing.expect_value(t, console_echo_end(log, max(four, 0), "41"), -1)
	testing.expect(t, console_echo_end(log, max(four, 0), "connect(\"server\")") > four)
	testing.expect_value(t, console_echo_end(log, 0, "connect(\"serve"), -1)
	testing.expect_value(t, console_echo_end(log, 0, "typed with no end of line"), -1)
	testing.expect_value(t, console_echo_end(log, 0, "never typed"), -1)
	testing.expect_value(t, console_echo_end("", 0, "4"), -1)
	testing.expect_value(t, console_echo_end(log, len(log) + 100, "4"), -1)
}

// The tool waits for an echo only when the last step that changed the
// front window was the step Front of the console, and only when no line
// can still run.
@(test)
the_tool_knows_when_the_console_takes_a_line :: proc(t: ^testing.T) {
	echo: Console_Echo
	testing.expect(t, !console_echo_wanted(&echo, "memory()"), "the front window is not known at the start")
	console_echo_note_step(&echo, Step{kind = .Front, text = "console"})
	testing.expect(t, console_echo_wanted(&echo, "memory()"))
	testing.expect(t, !console_echo_wanted(&echo, ""), "the console echoes no empty line")
	testing.expect(t, !echo.line_can_run)

	// A line, then a line with no Wait between: the first one can still run.
	console_echo_note_step(&echo, Step{kind = .Type, text = "spin()"})
	testing.expect(t, echo.line_can_run)
	testing.expect(t, console_echo_wanted(&echo, "count()"))
	console_echo_note_step(&echo, Step{kind = .Type, text = "count()"})
	console_echo_note_step(&echo, Step{kind = .Shot, text = "running"})
	console_echo_note_step(&echo, Step{kind = .Key, text = "esc"})
	testing.expect(t, echo.line_can_run)
	console_echo_note_step(&echo, Step{kind = .Wait, text = "[console] 13"})
	testing.expect(t, !echo.line_can_run)
	testing.expect(t, echo.console_in_front)

	// Each step that can change the front window.
	changes := [?]Step {
		{kind = .Front, text = "notes"},
		{kind = .Launch, text = "rings"},
		{kind = .Move, text = "console"},
		{kind = .Close, text = "life"},
		{kind = .Click},
		{kind = .Drag},
		{kind = .Key, text = LAUNCHER_KEY},
		{kind = .Type, text = "start(\"life\")"},
	}
	for change in changes {
		console_echo_note_step(&echo, Step{kind = .Front, text = "console"})
		console_echo_note_step(&echo, Step{kind = .Wait})
		testing.expect(t, console_echo_wanted(&echo, "memory()"))
		console_echo_note_step(&echo, change)
		testing.expectf(t, !console_echo_wanted(&echo, "memory()"), "after the step %v %s the front window is not known", change.kind, change.text)
	}
	// A line typed into another window does not say that a line of the
	// console can run.
	console_echo_note_step(&echo, Step{kind = .Front, text = "notes"})
	console_echo_note_step(&echo, Step{kind = .Wait})
	console_echo_note_step(&echo, Step{kind = .Type, text = "a note"})
	testing.expect(t, !echo.line_can_run)
}

// The failure of an echo shows each line of the log that says that a queue
// of the path of a key refused a record or held its writer.
@(test)
the_lines_of_a_lost_record_are_found_in_the_log :: proc(t: ^testing.T) {
	LOG :: "[input] input: ok\n" + "[compositor] compositor: window console does not read its events: 256 records wait for it, and a new record is lost\r\n" + "[console] > memory()\n" + "[compositor] compositor: window console reads its events again: 3 key records, 0 pointer records and 0 other records were lost\n" + "[input] input: the input ring is full: the keyboard controller keeps its bytes\n"
	log: string = LOG
	lines := loss_lines_of_log(log, 0)
	testing.expect_value(t, len(lines), 3)
	if len(lines) == 3 {
		testing.expect_value(t, lines[0], "[compositor] compositor: window console does not read its events: 256 records wait for it, and a new record is lost")
		testing.expect_value(t, lines[2], "[input] input: the input ring is full: the keyboard controller keeps its bytes")
	}
	// From the line that the tool typed: the loss before it is not shown.
	testing.expect_value(t, len(loss_lines_of_log(log, strings.index(log, "[console] > memory()"))), 2)
	testing.expect_value(t, len(loss_lines_of_log("[console] > memory()\n", 0)), 0)
}
