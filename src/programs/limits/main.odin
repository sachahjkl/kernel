// A demonstration of the limits of a budget: processor time and log
// records. A program cannot take all the processor time or fill the log:
// each resource has a limit.
//
// The program makes three budgets with a limit of processor time, and one
// thread on each budget. Each thread computes with no end. A fourth thread
// is on the budget of the program. The window shows the processor time
// that each budget used in the last second, against its limit. The budget
// of the program has a limit too, and what the three budgets use counts in
// it. Then the program writes 100 records on the log at once: its budget
// has 40 records for each second.
//
// **What it is for.** It shows that a [limit](term:limit) of a budget holds
// against a program that tries to take more: a thread that never waits
// gets no more than the processor time of its budget in each
// [period](term:period), and a burst of log records past the limit is
// refused with `No_Budget`, so no program fills the log of the others.
//
// **What a reader sees.** Start it from the menu of the programs, or with
// `start("limits")` in the console. The window has one bar for each of the
// four budgets: the processor time that it used in the last second,
// against its limit. The log gets a line of the times used, then
// `limits: ok, 4 budgets within their processor time, <count> log records
// written and <count> refused with <limit> for each second`, or
// `limits: wrong: ...`. The burst writes its records on the channel
// `burst`, at the level debug.
//
// **Its grants**: none. Its budget from the root service holds 2048 pages,
// 1 program and 5 threads, with a limit of processor time and of log
// records.
//
// **What it does not prove.** The bars are measures: a loaded host gives a
// thread less time than its limit, and the check reads only that no budget
// used more than its limit.
package limits

import "base:intrinsics"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import op "modus:contract/operation"
import "modus:support/system"

// The window is built with the interface package (docs/INTERFACE.md).
records_now, records_before: [512]interface.Draw_Record
text_now, text_before: [8192]u8
drawing: interface.Window_Drawing

LINE :: 22
WIDTH :: 640
BAR_X :: 232
BAR_WIDTH :: 380 // Two processors.
BAR_FULL :: 2_000_000
ROW_COUNT :: 4
HEIGHT :: 12 + 3 * LINE + ROW_COUNT * 2 * LINE + 4 * LINE + 12
INTERVAL :: 1000
BURST :: 100

COLOR_WRONG :: 0xE0B040
COLOR_LIMIT :: 0xF06060
COLORS := [ROW_COUNT]graphics.Color{0x4898F0, 0xF09040, 0x58D878, 0xC070E0}

// One budget: its limit, and what it used in the last interval, for one second.
Row :: struct {
	name:   string,
	budget: system.Handle, // 0: the budget of the program.
	limit:  u64, // Microseconds of processor time in each second.
	before: u64,
	used:   u64,
}

rows := [ROW_COUNT]Row {
	{name = "a thread, 5 %", limit = 50_000},
	{name = "a thread, 20 %", limit = 200_000},
	{name = "a thread, 60 %", limit = 600_000},
	{name = "the program: all"},
}

sink: [ROW_COUNT]u64

compute :: proc "c" (parameter: rawptr) -> ! {
	place := (^u64)(parameter)
	for {
		intrinsics.volatile_store(place, intrinsics.volatile_load(place) + 1)
	}
}

// within says if a budget used no more than its limit. The interval is not
// a whole number of periods of the kernel: one more part of a period can be
// in it.
within :: proc "contextless" (row: Row) -> bool {
	return row.used <= row.limit + row.limit / 5 + 3000
}

// entry writes the burst of 100 log records first and counts the accepted
// and the refused ones; it then makes the three budgets with a limit of
// processor time, starts one thread that computes with no end on each, and
// one on its own budget. Each second it reads the processor time of each
// budget, draws the bars, and writes the summary on the log once. It never
// returns; with no window, it stops with the code 1.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "limits")
	if !ok {
		system.stop(1)
	}
	own, _ := system.budget_read()
	rows[ROW_COUNT - 1].limit = own.processor
	log_limit := own.log_records

	// The log: 100 records at once.
	accepted, refused: u64
	text := "limits: one record of the 100"
	channel: [op.LOG_CHANNEL_CAPACITY]u8
	copy(channel[:], "burst")
	packed := transmute([2]u64)channel
	for _ in 0 ..< BURST {
		_, status := system.call(.Log, u64(ctx.handles[op.CONTEXT_LOG]), u64(uintptr(raw_data(text))), u64(len(text)), u64(op.Log_Level.Debug), packed[0], packed[1])
		if status == .Ok {
			accepted += 1
		} else if status == .No_Budget {
			refused += 1
		}
	}
	_, counted := system.budget_used()
	// The 100 records can be in two seconds of the kernel.
	log_right := accepted + refused == BURST && accepted >= 1 && accepted <= 2 * log_limit && counted == refused

	started := true
	for &row, index in rows {
		if index < ROW_COUNT - 1 {
			status: system.Status
			row.budget, status = system.budget_create({pages = 64, threads = 1, processor = row.limit})
			started &&= status == .Ok
		}
		_, status := system.thread_start(compute, &sink[index], budget = row.budget)
		started &&= status == .Ok
	}
	// A budget cannot have more than the budget that it came from.
	_, above := system.budget_create({processor = own.processor + 1})
	_, zero := system.budget_create({log_records = log_limit + 1})
	rule_right := above == .No_Budget && zero == .No_Budget

	sample := 0
	reported := false
	// The kernel counts processor time with the cycle counter, so the
	// interval is measured with it too. The milliseconds of the time page
	// count ticks, and a tick can come late: the two do not compare.
	per_millisecond := max(system.cycle_frequency() / 1000, 1)
	last := system.cycles()
	for {
		now := system.cycles()
		elapsed := max((now - last) / per_millisecond, 1)
		last = now
		for &row in rows {
			used, _ := system.budget_used(row.budget)
			row.used = (used - row.before) * 1000 / elapsed
			row.before = used
		}
		sample += 1
		// The first sample has no interval. The first interval has the start
		// of the threads: the check, which is an upper limit, counts it, or
		// the first later one where each thread ran. A measure run waits for
		// the next interval, where each thread computes from its start: its
		// line is the time that a budget uses. A loaded host can give a
		// thread no time in one interval; the samples only end a hang.
		each_ran := true
		for row in rows {
			each_ran &&= row.used > 0
		}
		first_counted := system.measure_run() ? 3 : 2
		if !reported && sample >= first_counted && (each_ran || sample >= first_counted + system.TEST_HANG_BOUND_MILLISECONDS / INTERVAL) {
			reported = true
			right := started && log_right && rule_right && each_ran
			for row in rows {
				right &&= within(row)
			}
			system.log("limits: processor time of one second, used of limit: ", rows[0].used, " of ", rows[0].limit, ", ", rows[1].used, " of ", rows[1].limit, ", ", rows[2].used, " of ", rows[2].limit, ", the program ", rows[3].used, " of ", rows[3].limit)
			if right {
				system.log("limits: ok, 4 budgets within their processor time, ", accepted, " log records written and ", refused, " refused with ", log_limit, " for each second")
			} else {
				system.log("limits: wrong: threads ", u64(started), " log ", u64(log_right), " rule ", u64(rule_right))
			}
		}

		if drawing.now.records == nil {
			drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
		}
		frame := interface.window_frame_begin(&drawing, &window)
		table := frame.table
		interface.draw_rectangle(table, 0, 0, WIDTH, HEIGHT, graphics.COLOR_BACKGROUND)
		y := 12
		interface.draw_text(table, 12, y, "a budget has a limit of processor time for each second.", graphics.COLOR_DIM)
		y += LINE
		interface.draw_text(table, 12, y, "each thread computes with no end: the kernel stops it at the limit.", graphics.COLOR_DIM)
		y += LINE + LINE / 2
		for row, index in rows {
			interface.draw_rectangle(table, 6, y - 4, WIDTH - 12, 2 * LINE - 2, graphics.COLOR_CARD_TOP)
			interface.draw_text(table, 12, y, row.name, graphics.COLOR_TEXT)
			x := interface.draw_unsigned(table, BAR_X, y, row.used / 1000, sample > 1 && !within(row) ? COLOR_WRONG : graphics.COLOR_TEXT)
			x = interface.draw_text(table, x, y, " ms used of ", graphics.COLOR_DIM)
			x = interface.draw_unsigned(table, x, y, row.limit / 1000, graphics.COLOR_TEXT)
			interface.draw_text(table, x, y, " ms in one second", graphics.COLOR_DIM)
			y += LINE
			interface.draw_rectangle(table, BAR_X, y, BAR_WIDTH, 10, graphics.COLOR_BACKGROUND)
			interface.draw_rectangle(table, BAR_X, y, int(min(row.used, BAR_FULL) * BAR_WIDTH / BAR_FULL), 10, COLORS[index])
			interface.draw_rectangle(table, BAR_X + int(min(row.limit, BAR_FULL) * BAR_WIDTH / BAR_FULL), y - 3, 2, 16, COLOR_LIMIT)
			y += LINE
		}
		y += LINE / 2
		interface.draw_text(table, 12, y, "what the three budgets use counts in the budget of the program.", graphics.COLOR_DIM)
		y += LINE
		interface.draw_text(table, 12, y, "a new budget with a higher limit than the program:", graphics.COLOR_DIM)
		interface.draw_text(table, 424, y, rule_right ? "refused: no budget" : "another answer", rule_right ? graphics.COLOR_PROGRAM : COLOR_WRONG)
		y += LINE
		line: [96]u8
		interface.draw_text(table, 12, y, system.format(line[:], "100 log records at once, ", log_limit, " for each second:"), graphics.COLOR_DIM)
		interface.draw_text(table, 424, y, system.format(line[:], accepted, " written, ", refused, " refused"), log_right ? graphics.COLOR_PROGRAM : COLOR_WRONG)
		interface.window_frame_end(&drawing, &frame, &window)
		for _ in display.next_event(&window) {}
		system.sleep(system.time() + INTERVAL)
	}
}
