package kerneltool

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"

// When the tool takes a picture of the screen
// (docs/TOOLS.md, "When the tool takes a picture").
//
// A picture is right when the screen shows the last picture of each
// window. That is two facts: each program sent the picture of its last
// change, and the compositor drew each picture that it received. The tool
// reads the two through the remote service when it can call the compositor
// (machine.confirm): the state of the programs from the monitor, the state
// of the screen from the compositor. Else it takes pictures until two in a
// row are the same.
//
// A window that draws with no end has no last picture: its part of the
// screen is whatever frame is there, and no condition reads it.

// The programs whose window changes with no input: each one draws a new
// picture at each frame, or has threads that compute with no end. Such a
// program is never in a wait for long, and its window never stays the
// same, so the condition of a picture leaves its window out.
@(rodata)
programs_that_draw_without_end := [?]string{"life", "plasma", "temple", "threads", "workers", "rings", "processors", "limits", "flood"}

// draws_without_end says if a window with this title is left out of the
// condition of a picture.
draws_without_end :: proc(title: string) -> bool {
	for name in programs_that_draw_without_end {
		if name == title {
			return true
		}
	}
	return false
}

// The programs that carry the reads of the condition: the remote service
// takes each call, and the monitor answers the read of the programs. Each
// one runs because of the read itself, and its window counts the calls, so
// the condition by calls leaves its window out too.
@(rodata)
programs_that_serve_the_reads := [?]string{"remote", "monitor"}

// left_out_of_calls says if the condition by calls leaves out a window
// with this title.
left_out_of_calls :: proc(title: string) -> bool {
	for name in programs_that_serve_the_reads {
		if name == title {
			return true
		}
	}
	return draws_without_end(title)
}

// One row of monitor.programs(), for the condition of a picture.
Settle_Program :: struct {
	slot:    i64,
	name:    string,
	state:   string, // created, ready, waiting or stopped.
	entries: i64, // Kernel entries since its start.
}

// One row of compositor.windows(), for the condition of a picture.
Settle_Window :: struct {
	title:    string,
	presents: i64,
	waits:    bool, // A Present that no frame drew yet.
}

// screen_settle_problem says why the screen is not settled, or "". The
// three reads are in this order: the programs, then the windows and the
// desktop of the compositor, then the programs again.
//
// A program that is in a wait in the two reads, with the same count of
// kernel entries, did not run between them: to run and to wait again, it
// enters the kernel. So each picture that it sent, it sent before the first
// read, and the compositor counted it before it answered. With no Present
// that waits for a frame, the screen shows the last picture of the window.
screen_settle_problem :: proc(before: []Settle_Program, windows: []Settle_Window, desktop_waits: bool, after: []Settle_Program) -> string {
	if desktop_waits {
		return "the desktop has a change that no frame drew yet"
	}
	for window in windows {
		if left_out_of_calls(window.title) {
			continue
		}
		if window.waits {
			return fmt.tprintf("the window %s has a picture that no frame drew yet", window.title)
		}
		alive := false
		for program in after {
			if program.name != window.title || program.state == "stopped" {
				continue
			}
			alive = true
			if program.state != "waiting" {
				return fmt.tprintf("the program of the window %s is %s, not in a wait: it can still draw", window.title, program.state)
			}
			paired := false
			for earlier in before {
				if earlier.slot != program.slot || earlier.name != program.name {
					continue
				}
				paired = true
				if earlier.state != "waiting" {
					return fmt.tprintf("the program of the window %s was %s, not in a wait: it can still draw", window.title, earlier.state)
				}
				if earlier.entries != program.entries {
					return fmt.tprintf("the program of the window %s entered the kernel %d times between two reads: it ran", window.title, program.entries - earlier.entries)
				}
			}
			if !paired {
				return fmt.tprintf("the program of the window %s started between two reads", window.title)
			}
		}
		// A window whose program stopped gets no picture more.
		if alive && window.presents == 0 {
			return fmt.tprintf("the window %s has no picture of its program yet", window.title)
		}
	}
	return ""
}

@(private = "file")
settle_programs_read :: proc(machine: ^Machine) -> (programs: []Settle_Program, ok: bool) {
	table := table_call(&machine.client, "monitor.programs()") or_return
	count := len(table.rows) / table.size
	if i64(count) < table.total {
		return nil, false
	}
	programs = make([]Settle_Program, count, context.temp_allocator)
	for &program, row in programs {
		program.slot = strconv.parse_i64(table_value(&table, row, "slot")) or_return
		program.entries = strconv.parse_i64(table_value(&table, row, "entries")) or_return
		program.name = table_value(&table, row, "name")
		program.state = table_value(&table, row, "state")
	}
	return programs, true
}

@(private = "file")
settle_windows_read :: proc(machine: ^Machine) -> (windows: []Settle_Window, ok: bool) {
	table := table_call(&machine.client, "compositor.windows()") or_return
	count := len(table.rows) / table.size
	if i64(count) < table.total {
		return nil, false
	}
	windows = make([]Settle_Window, count, context.temp_allocator)
	for &window, row in windows {
		window.title = table_value(&table, row, "title")
		window.presents = strconv.parse_i64(table_value(&table, row, "presents")) or_return
		waits := strconv.parse_i64(table_value(&table, row, "waits")) or_return
		window.waits = waits != 0
	}
	return windows, true
}

// Screen_Settle_Result: how a wait for a settled screen ended.
Screen_Settle_Result :: enum {
	Settled,
	Not_Readable, // The tool cannot call the monitor or the compositor: the other condition.
	Hang, // The screen did not settle within the hang bound.
}

// screen_settle_wait_by_calls waits until the programs and the compositor
// say that the screen shows the last picture of each window that does not
// draw with no end. what names the picture in a message of failure.
screen_settle_wait_by_calls :: proc(machine: ^Machine, what: string) -> Screen_Settle_Result {
	problem := ""
	for start := time.tick_now(); time.tick_since(start) < HANG_BOUND; {
		before, before_read := settle_programs_read(machine)
		if !before_read {
			return .Not_Readable
		}
		windows, windows_read := settle_windows_read(machine)
		screen, screen_read := record_fields(&machine.client, "compositor.screen()", {"desktop"})
		after, after_read := settle_programs_read(machine)
		if !windows_read || !screen_read || !after_read {
			return .Not_Readable
		}
		problem = screen_settle_problem(before, windows, screen[0] != 0, after)
		if problem == "" {
			machine.pictures_settled_by_calls += 1
			return .Settled
		}
		time.sleep(CONDITION_POLL_PERIOD)
	}
	fmt.eprintfln("kerneltool: test failed: the screen did not settle within %v before the picture %s: %s", HANG_BOUND, what, problem)
	return .Hang
}

// A rectangle of a picture of the screen. right and bottom are not in it.
Picture_Rectangle :: struct {
	left, top, right, bottom: int,
}

// log_window_rectangle gives the rectangle of the last window with a title,
// with its frame and its title bar, from the lines of the compositor in the
// log: "compositor: surface title 480x320 at 276,232" and "compositor:
// window title moved to 60,742".
log_window_rectangle :: proc(log: string, title: string) -> (rectangle: Picture_Rectangle, ok: bool) {
	made_mark := strings.concatenate({"compositor: surface ", title, " "}, context.temp_allocator)
	made := strings.last_index(log, made_mark)
	if made < 0 {
		return {}, false
	}
	line := log[made + len(made_mark):]
	if end := strings.index_byte(line, '\n'); end >= 0 {
		line = line[:end]
	}
	// "480x320 at 276,232"
	by := strings.index_byte(line, 'x')
	at := strings.index(line, " at ")
	if by < 0 || at < by {
		return {}, false
	}
	width := strconv.parse_int(line[:by]) or_return
	height := strconv.parse_int(line[by + 1:at]) or_return
	place := strings.trim_space(line[at + len(" at "):])
	moved_mark := strings.concatenate({"compositor: window ", title, " moved to "}, context.temp_allocator)
	if moved := strings.last_index(log, moved_mark); moved > made {
		place = log[moved + len(moved_mark):]
		if end := strings.index_byte(place, '\n'); end >= 0 {
			place = place[:end]
		}
		place = strings.trim_space(place)
	}
	comma := strings.index_byte(place, ',')
	if comma < 0 {
		return {}, false
	}
	x := strconv.parse_int(place[:comma]) or_return
	y := strconv.parse_int(place[comma + 1:]) or_return
	return {x, y, x + width + 2 * WINDOW_BORDER, y + WINDOW_TITLE_HEIGHT + height + WINDOW_BORDER}, true
}

// pictures_differ_outside gives the first pixel where two pictures of the
// same size differ, outside the rectangles of left_out. The pixels are 3
// bytes each, line after line.
pictures_differ_outside :: proc(first, second: []u8, width, height: int, left_out: []Picture_Rectangle) -> (x, y: int, differ: bool) {
	for line in 0 ..< height {
		row := line * width * 3
		if string(first[row:][:width * 3]) == string(second[row:][:width * 3]) {
			continue
		}
		column: for at in 0 ..< width {
			pixel := row + at * 3
			if first[pixel] == second[pixel] && first[pixel + 1] == second[pixel + 1] && first[pixel + 2] == second[pixel + 2] {
				continue
			}
			for rectangle in left_out {
				if at >= rectangle.left && at < rectangle.right && line >= rectangle.top && line < rectangle.bottom {
					continue column
				}
			}
			return at, line, true
		}
	}
	return 0, 0, false
}

// windows_left_out gives the rectangle of each window of the log that
// draws with no end.
windows_left_out :: proc(machine: ^Machine) -> []Picture_Rectangle {
	log := log_read(machine)
	rectangles := make([dynamic]Picture_Rectangle, context.temp_allocator)
	for title in programs_that_draw_without_end {
		if rectangle, found := log_window_rectangle(log, title); found {
			append(&rectangles, rectangle)
		}
	}
	return rectangles[:]
}
