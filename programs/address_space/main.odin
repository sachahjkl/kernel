// A program drives its own virtual memory (docs/ARCHITECTURE.md, "The
// virtual memory of a program").
//
// At its start the program runs its cases, with their numbers:
//   an arena: a range of 1 GiB of addresses with no memory behind it, whose
//     pages are committed as the arena grows, with tables of 1, 16 and 256
//     ranges for each kernel entry;
//   a sparse table: a fixed base of 1 GiB, 1024 pages committed at random;
//   decommit: the frames and the pages return to the budget at once, and a
//     page committed again is zero;
//   protection: a part of a mapping becomes read only, with the time of the
//     shoot-down when 1, 2 or 4 processors run threads of the program;
//   a guard page: a child program writes down its stack into a page with no
//     access, and the kernel stops it there;
//   large pages: random reads over 64 MiB of one object, through a mapping
//     of large pages and through a mapping of pages of 4 KiB;
//   the refusals, each with its error record.
// The window shows the numbers. The log has one line for each case and a
// line "address_space: ok, ..." when each check holds. The checks do not
// depend on the load of the host.
//
// The program needs the machine with the right Inspect (its own mappings)
// and the boot image (its child).
package address_space

import "base:intrinsics"
import "contract:errors"
import op "contract:operation"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:system"

WIDTH :: 960
HEIGHT :: 640
GIGABYTE_PAGES :: 262144 // 1 GiB of pages of 4 KiB.
ARENA_PAGES :: 4096 // The pages that the arena commits for each size of batch.
SPARSE_PAGES :: 1024
PROTECT_PAGES :: 256
PROTECT_CALLS :: 200
LARGE_OBJECT_PAGES :: 16384 // 64 MiB.
LARGE_ADDRESS :: 0x0000_4000_0000_0000 // Aligned on 2 MiB: the mapping of large pages.
SMALL_ADDRESS :: 0x0000_4100_0000_1000 // Not aligned: the same object with pages of 4 KiB.
GUARD_ADDRESS :: 0x0000_4200_0000_0000 // The stack of the child: the guard page, then 63 pages.
GUARD_STACK_PAGES :: 64
RANDOM_READS :: 4_000_000
VALUE_ROLE :: 0 // The context of the child: 1.

machine: system.Handle
self_index: u64 // The slot of this program, for its report of mappings.

// The results of the cases, for the log and the window.
batch_sizes := [3]u64{1, 16, 256}
arena_pages_per_second: [3]u64
arena_entries_per_thousand_pages: [3]u64 // Kernel entries for 1000 pages committed and used.
arena_map_microseconds: u64
arena_list_pages: u64
sparse_committed, sparse_present: u64
decommit_returned, decommit_expected: u64
decommit_microseconds: u64
recommit_zero: bool
shootdown_nanoseconds: [3]u64 // The middle of PROTECT_CALLS, with 1, 2 and 4 processors running the program.
guard_address, guard_vector: u64
guard_right: bool
large_nanoseconds, small_nanoseconds: u64 // One random read.
large_flags_right: bool
refusals: [4]Refusal
right := true
problem: string
done: bool

Refusal :: struct {
	name:     string,
	status:   system.Status,
	expected: system.Status,
	record:   errors.Error_Record,
	sentence: [160]u8,
	count:    int,
}

fail :: proc "contextless" (what: string) {
	if right {
		problem = what
	}
	right = false
}

own_mappings :: proc "contextless" () -> (report: op.Program_Mapping_Report) {
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program_Mappings), self_index, u64(uintptr(&report)), size_of(report))
	return report
}

mapping_at :: proc "contextless" (report: ^op.Program_Mapping_Report, address: u64) -> ^op.Program_Mapping {
	for &mapping in report.mappings[:report.count] {
		if mapping.address == address {
			return &mapping
		}
	}
	return nil
}

// find_self finds the slot of this program by its name in the reports.
find_self :: proc "contextless" () {
	for index in u64(1) ..< 64 {
		report: op.Program_Report
		if _, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program), index, u64(uintptr(&report)), size_of(report)); status != .Ok {
			continue
		}
		if system.name_of(report.name[:]) == "address_space" && report.state != .Stopped && report.state != .None {
			self_index = index
			return
		}
	}
}

// The arena: one range of 1 GiB, pages committed as it grows.
arena :: proc "contextless" () {
	before, _ := system.budget_read()
	memory, status := system.memory_create(GIGABYTE_PAGES, flags = {.Uncommitted})
	if status != .Ok {
		fail("the arena: no object")
		return
	}
	defer system.close(memory)
	after_create, _ := system.budget_read()
	arena_list_pages = before.pages - after_create.pages
	start := system.nanoseconds()
	address, map_status := system.memory_map(memory)
	arena_map_microseconds = (system.nanoseconds() - start) / 1000
	if map_status != .Ok {
		fail("the arena: no mapping")
		return
	}
	defer system.memory_unmap(address)
	bytes := ([^]u8)(address)
	ranges: [256]op.Page_Range
	for batch, row in batch_sizes {
		first := u64(row) * ARENA_PAGES
		entries := system.kernel_entries()
		start = system.nanoseconds()
		for page := first; page < first + ARENA_PAGES; page += batch {
			for index in 0 ..< batch {
				ranges[index] = {first = page + index, page_count = 1}
			}
			if _, commit := system.memory_commit(memory, ranges[:batch]); commit != .Ok {
				fail("the arena: a commit was refused")
				return
			}
			for index in 0 ..< batch {
				intrinsics.volatile_store(&bytes[(page + index) * system.PAGE_SIZE], 1)
			}
		}
		elapsed := max(system.nanoseconds() - start, 1)
		arena_pages_per_second[row] = ARENA_PAGES * 1_000_000_000 / elapsed
		arena_entries_per_thousand_pages[row] = (system.kernel_entries() - entries) * 1000 / ARENA_PAGES
	}
	// The pages return.
	everything := [1]op.Page_Range{{first = 0, page_count = 3 * ARENA_PAGES}}
	if returned, decommit := system.memory_decommit(memory, everything[:]); decommit != .Ok || returned != 3 * ARENA_PAGES {
		fail("the arena: the decommit")
	}
}

// The sparse table: a fixed base, pages committed at random, then the
// decommit and a page committed again.
sparse :: proc "contextless" () {
	memory, status := system.memory_create(GIGABYTE_PAGES, flags = {.Uncommitted})
	if status != .Ok {
		fail("the sparse table: no object")
		return
	}
	defer system.close(memory)
	address, map_status := system.memory_map(memory)
	if map_status != .Ok {
		fail("the sparse table: no mapping")
		return
	}
	defer system.memory_unmap(address)
	words := ([^]u64)(address)
	pages: [SPARSE_PAGES]u64
	random := u64(0x9E37_79B9_7F4A_7C15)
	page: u64
	for &chosen in pages {
		random ~= random << 13
		random ~= random >> 7
		random ~= random << 17
		page += 1 + random % 255
		chosen = page
	}
	ranges: [256]op.Page_Range
	for part in 0 ..< SPARSE_PAGES / 256 {
		for index in 0 ..< 256 {
			ranges[index] = {first = pages[part * 256 + index], page_count = 1}
		}
		if _, commit := system.memory_commit(memory, ranges[:]); commit != .Ok {
			fail("the sparse table: a commit was refused")
			return
		}
	}
	for chosen in pages {
		words[chosen * 512] = chosen
	}
	report := own_mappings()
	if mapping := mapping_at(&report, u64(uintptr(address))); mapping != nil {
		sparse_committed, sparse_present = mapping.committed, mapping.present
		if .Uncommitted not_in mapping.flags {
			fail("the sparse table: the report does not say Uncommitted")
		}
	}
	if sparse_committed != SPARSE_PAGES || sparse_present != SPARSE_PAGES {
		fail("the sparse table: the committed pages")
	}
	// Decommit: the budget gets each page back at once.
	before, _ := system.budget_read()
	everything := [1]op.Page_Range{{first = 0, page_count = GIGABYTE_PAGES}}
	start := system.nanoseconds()
	returned, decommit := system.memory_decommit(memory, everything[:])
	decommit_microseconds = (system.nanoseconds() - start) / 1000
	after, _ := system.budget_read()
	decommit_returned, decommit_expected = after.pages - before.pages, SPARSE_PAGES
	if decommit != .Ok || returned != SPARSE_PAGES || decommit_returned != SPARSE_PAGES {
		fail("the decommit: the budget did not get each page back")
	}
	// A page committed again is zero.
	again := [1]op.Page_Range{{first = pages[7], page_count = 1}}
	system.memory_commit(memory, again[:])
	recommit_zero = words[pages[7] * 512] == 0
	if !recommit_zero {
		fail("a page committed again is not zero")
	}
}

// Threads that run the program on other processors: they hold its page
// table, so each protection change waits for them (the shoot-down).
Runner :: struct #align (64) {
	stop: u32,
	count: u64,
}
runners: [3]Runner

run :: proc "c" (parameter: rawptr) -> ! {
	runner := (^Runner)(parameter)
	for intrinsics.atomic_load(&runner.stop) == 0 {
		intrinsics.volatile_store(&runner.count, runner.count + 1)
	}
	system.thread_stop()
}

protection :: proc "contextless" () {
	memory, status := system.memory_create(PROTECT_PAGES)
	if status != .Ok {
		fail("the protection: no object")
		return
	}
	defer system.close(memory)
	address, map_status := system.memory_map(memory)
	if map_status != .Ok {
		fail("the protection: no mapping")
		return
	}
	defer system.memory_unmap(address)
	bytes := ([^]u8)(address)
	for page in 0 ..< PROTECT_PAGES {
		bytes[page * system.PAGE_SIZE] = 1
	}
	part := [1]op.Address_Range{{address = u64(uintptr(address)) + 64 * system.PAGE_SIZE, page_count = 64}}
	threads: [3]system.Thread
	started := 0
	for running, row in ([3]int{0, 1, 3}) {
		for started < running {
			runners[started] = {}
			threads[started], _ = system.thread_start(run, &runners[started])
			started += 1
		}
		system.sleep(system.time() + 20)
		times: [PROTECT_CALLS]u64
		for &time, call in times {
			start := system.nanoseconds()
			_, protect := system.memory_protect(part[:], call % 2 == 0 ? {} : {.Write})
			time = system.nanoseconds() - start
			if protect != .Ok {
				fail("the protection: a change was refused")
				return
			}
		}
		for at in 1 ..< len(times) {
			for back := at; back > 0 && times[back - 1] > times[back]; back -= 1 {
				times[back - 1], times[back] = times[back], times[back - 1]
			}
		}
		shootdown_nanoseconds[row] = times[PROTECT_CALLS / 2]
	}
	for index in 0 ..< started {
		intrinsics.atomic_store(&runners[index].stop, 1)
		system.thread_wait(threads[index])
	}
	report := own_mappings()
	if mapping := mapping_at(&report, u64(uintptr(address))); mapping == nil || .Protected not_in mapping.flags {
		fail("the protection: the report does not say Protected")
	}
}

// The child: its stack is under a page with no access; it writes down
// until it reaches it.
child :: proc "contextless" () -> ! {
	memory, _ := system.memory_create(GUARD_STACK_PAGES)
	address, _ := system.memory_map(memory, {.Write}, 0, GUARD_ADDRESS)
	guard := [1]op.Address_Range{{address = GUARD_ADDRESS, page_count = 1}}
	system.memory_protect(guard[:], {.No_Access})
	bytes := ([^]u8)(address)
	for offset := u64(GUARD_STACK_PAGES * system.PAGE_SIZE) - 8; ; offset -= 8 {
		intrinsics.volatile_store(&bytes[offset], 1)
	}
}

guard_page :: proc "contextless" (ctx: ^system.Context) {
	image_size := ctx.values[system.GRANT_VALUE_IMAGE_SIZE]
	address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {})
	if status != .Ok {
		fail("the guard page: no boot image")
		return
	}
	image := ([^]u8)(address)[:image_size]
	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_ROLE] = 1
	program, start := system.program_start(system.image_find(image, "address_space"), "address_space child", grants, values, {pages = 2048, programs = 1, threads = 1, processor = 100_000, log_records = 10})
	if start != .Ok {
		fail("the guard page: the child did not start")
		return
	}
	defer system.close(program)
	for deadline := system.time() + 5000; system.time() < deadline; {
		state, _ := system.program_state(program)
		if state == .Stopped {
			break
		}
		system.sleep(system.time() + 10)
	}
	report := system.program_stop_report(program)
	guard_address, guard_vector = report.address, u64(report.vector)
	guard_right = guard_vector == 14 && guard_address >= GUARD_ADDRESS && guard_address < GUARD_ADDRESS + system.PAGE_SIZE
	if !guard_right {
		fail("the guard page: the child did not stop in its guard page")
	}
}

// Random reads over one object of 64 MiB: through large pages, then
// through pages of 4 KiB.
reads :: proc "contextless" (base: [^]u64) -> u64 {
	random := u64(0x2545_F491_4F6C_DD1D)
	sum: u64
	start := system.nanoseconds()
	for _ in 0 ..< RANDOM_READS {
		random ~= random << 13
		random ~= random >> 7
		random ~= random << 17
		sum += intrinsics.volatile_load(&base[random % (LARGE_OBJECT_PAGES * 512)])
	}
	elapsed := system.nanoseconds() - start
	intrinsics.volatile_store(&base[0], sum)
	return elapsed * 10 / RANDOM_READS // Tenths of a nanosecond.
}

large_pages :: proc "contextless" () {
	memory, status := system.memory_create(LARGE_OBJECT_PAGES, flags = {.Large_Pages})
	if status != .Ok {
		fail("the large pages: no object")
		return
	}
	defer system.close(memory)
	large, large_status := system.memory_map(memory, {.Write}, 0, LARGE_ADDRESS)
	small, small_status := system.memory_map(memory, {.Write}, 0, SMALL_ADDRESS)
	if large_status != .Ok || small_status != .Ok {
		fail("the large pages: no mapping")
		return
	}
	defer system.memory_unmap(large)
	defer system.memory_unmap(small)
	report := own_mappings()
	large_mapping, small_mapping := mapping_at(&report, LARGE_ADDRESS), mapping_at(&report, SMALL_ADDRESS)
	large_flags_right = large_mapping != nil && small_mapping != nil && .Large in large_mapping.flags && .Large not_in small_mapping.flags && large_mapping.present == LARGE_OBJECT_PAGES
	if !large_flags_right {
		fail("the large pages: the report")
	}
	reads(([^]u64)(large)) // Each line in the cache of the host once.
	large_nanoseconds = reads(([^]u64)(large))
	small_nanoseconds = reads(([^]u64)(small))
}

refusal :: proc "contextless" (item: ^Refusal, name: string, expected: system.Status, status: system.Status, record: errors.Error_Record) {
	item.name, item.expected, item.status, item.record = name, expected, status, record
	writer := system.Writer{buffer = item.sentence[:]}
	system.kernel_error_text(&writer, &item.record)
	item.count = len(system.written(&writer))
	if status != expected || record.kind == i64(errors.Kind.Refused) {
		fail("a refusal has another status or no error record")
	}
}

refuse :: proc "contextless" () {
	record: errors.Error_Record
	memory, _ := system.memory_create(64, flags = {.Uncommitted})
	defer system.close(memory)
	outside := [1]op.Page_Range{{first = 60, page_count = 10}}
	_, status := system.memory_commit(memory, outside[:], &record)
	refusal(&refusals[0], "a range outside the object", .Bad_Address, status, record)
	big, _ := system.memory_create(GIGABYTE_PAGES, flags = {.Uncommitted})
	defer system.close(big)
	record = {}
	over := [1]op.Page_Range{{first = 0, page_count = 200_000}}
	_, status = system.memory_commit(big, over[:], &record)
	refusal(&refusals[1], "a commit over the budget", .No_Budget, status, record)
	plain, _ := system.memory_create(4)
	defer system.close(plain)
	address, _ := system.memory_map(plain)
	defer system.memory_unmap(address)
	record = {}
	both := [1]op.Address_Range{{address = u64(uintptr(address)), page_count = 4}}
	_, status = system.memory_protect(both[:], {.Write, .Execute}, &record)
	refusal(&refusals[2], "write and execute", .Bad_Operation, status, record)
	record = {}
	_, status = system.memory_create(100, flags = {.Large_Pages}, error = &record)
	refusal(&refusals[3], "large pages of 100 pages", .Bad_Operation, status, record)
}

// The window: one card for each case, with the numbers.
records_now, records_before: [1024]interface.Draw_Record
text_now, text_before: [16384]u8
drawing: interface.Window_Drawing

line :: proc "contextless" (frame: ^interface.Frame, column: ^interface.Column, label: string, parts: ..system.Part) {
	buffer: [96]u8
	interface.label_value_line(frame, interface.column_take(column, 16), label, system.format(buffer[:], ..parts), graphics.COLOR_TEXT, 184)
}

build :: proc "contextless" (frame: ^interface.Frame) {
	interface.background(frame, {0, 0, WIDTH, HEIGHT})
	left := interface.card(frame, {8, 8, WIDTH / 2 - 12, HEIGHT - 16}, "RESERVE AND COMMIT", "Memory_Commit", graphics.COLOR_MEMORY)
	column := interface.column_of(left, 4)
	line(frame, &column, "arena: addresses", u64(GIGABYTE_PAGES / 256), " MiB, one mapping")
	interface.cell_text(frame, interface.column_take(&column, 16), "  pages committed and used; entries for 1000 pages:", graphics.COLOR_DIM)
	line(frame, &column, "  paid for its frame list", arena_list_pages, " pages")
	line(frame, &column, "  mapped in", arena_map_microseconds, " us")
	for batch, row in batch_sizes {
		buffer: [48]u8
		label := system.format(buffer[:], "  ", batch, batch == 1 ? " range" : " ranges", " / entry")
		line(frame, &column, label, arena_pages_per_second[row], " pages/s, ", arena_entries_per_thousand_pages[row], " entries")
	}
	interface.column_take(&column, 8)
	line(frame, &column, "sparse table: committed", sparse_committed, " of ", u64(GIGABYTE_PAGES))
	line(frame, &column, "  with a frame", sparse_present, " pages")
	line(frame, &column, "decommit: returned", decommit_returned, " of ", decommit_expected, " pages")
	line(frame, &column, "  in", decommit_microseconds, " us")
	line(frame, &column, "  a page committed again", recommit_zero ? "is zero" : "is not zero")
	interface.column_take(&column, 8)
	interface.cell_text(frame, interface.column_take(&column, 16), "refusals, each with its error record", graphics.COLOR_DIM)
	for &item in refusals {
		color: graphics.Color = item.status == item.expected ? graphics.COLOR_PROGRAM : graphics.COLOR_FAILED
		interface.cell_text(frame, interface.column_take(&column, 16), item.name, graphics.COLOR_TEXT)
		first := min(item.count, 52)
		interface.cell_text(frame, interface.column_take(&column, 16), string(item.sentence[:first]), color)
		interface.cell_text(frame, interface.column_take(&column, 16), string(item.sentence[first:min(item.count, 104)]), color)
	}
	right_card := interface.card(frame, {WIDTH / 2 + 4, 8, WIDTH / 2 - 12, HEIGHT - 16}, "PROTECT, GUARD, LARGE PAGES", "Memory_Protect", graphics.COLOR_KERNEL)
	column = interface.column_of(right_card, 4)
	interface.cell_text(frame, interface.column_take(&column, 16), "a part of a mapping read only, then writable:", graphics.COLOR_DIM)
	interface.cell_text(frame, interface.column_take(&column, 16), "one call with its shoot-down, in the middle of 200", graphics.COLOR_DIM)
	most := max(shootdown_nanoseconds[0], shootdown_nanoseconds[1], shootdown_nanoseconds[2], 1)
	for processors, row in ([3]u64{1, 2, 4}) {
		buffer: [48]u8
		line(frame, &column, system.format(buffer[:], processors, processors == 1 ? " processor" : " processors"), shootdown_nanoseconds[row], " ns")
		interface.bar(frame, interface.column_take(&column, 8), shootdown_nanoseconds[row], most, graphics.COLOR_KERNEL)
	}
	interface.column_take(&column, 8)
	interface.cell_text(frame, interface.column_take(&column, 16), "a child writes down its stack into a guard page:", graphics.COLOR_DIM)
	if guard_right {
		buffer: [48]u8
		interface.cell_text(frame, interface.column_take(&column, 16), system.format(buffer[:], "stopped: page fault at ", system.Hex(guard_address)), graphics.COLOR_PROGRAM)
	} else {
		interface.cell_text(frame, interface.column_take(&column, 16), done ? "not stopped in its guard page" : "not measured yet", done ? graphics.COLOR_FAILED : graphics.COLOR_DIM)
	}
	interface.column_take(&column, 8)
	interface.cell_text(frame, interface.column_take(&column, 16), "one random read over 64 MiB:", graphics.COLOR_DIM)
	slowest := max(large_nanoseconds, small_nanoseconds, 1)
	line(frame, &column, "large pages of 2 MiB", large_nanoseconds / 10, ".", large_nanoseconds % 10, " ns")
	interface.bar(frame, interface.column_take(&column, 8), large_nanoseconds, slowest, graphics.COLOR_MEMORY)
	line(frame, &column, "pages of 4 KiB", small_nanoseconds / 10, ".", small_nanoseconds % 10, " ns")
	interface.bar(frame, interface.column_take(&column, 8), small_nanoseconds, slowest, graphics.COLOR_MEMORY)
	interface.cell_text(frame, interface.column_take(&column, 16), "(the processor of the host, under KVM)", graphics.COLOR_DIM)
	interface.column_take(&column, 8)
	status_text := done ? (right ? "ok: each check holds" : problem) : "the cases run"
	interface.cell_text(frame, interface.column_take(&column, 16), status_text, done ? (right ? graphics.COLOR_PROGRAM : graphics.COLOR_FAILED) : graphics.COLOR_BOOT_PROGRAM)
}

frame_draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_begin(&drawing)
	build(&frame)
	interface.window_frame_end(&drawing, &frame, window)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	if ctx.values[VALUE_ROLE] == 1 {
		child()
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, "address_space")
	if !ok {
		system.stop(1)
	}
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	frame_draw(&window)
	machine = ctx.handles[system.GRANT_MACHINE]
	find_self()
	start_budget, _ := system.budget_read()

	arena()
	system.log("address_space: arena: 1 GiB of addresses in one mapping, ", arena_list_pages, " pages paid for its frame list, mapped in ", arena_map_microseconds, " us; pages committed and used in one second with 1, 16, 256 ranges for each kernel entry: ", arena_pages_per_second[0], ", ", arena_pages_per_second[1], ", ", arena_pages_per_second[2], "; kernel entries for 1000 pages: ", arena_entries_per_thousand_pages[0], ", ", arena_entries_per_thousand_pages[1], ", ", arena_entries_per_thousand_pages[2])
	sparse()
	system.log("address_space: sparse table: ", sparse_committed, " pages committed of ", u64(GIGABYTE_PAGES), ", ", sparse_present, " with a frame; decommit: ", decommit_returned, " pages back in the budget at once, in ", decommit_microseconds, " us; a page committed again is zero: ", u64(recommit_zero))
	protection()
	system.log("address_space: protection of 64 pages, one call with its shoot-down, in the middle of 200: ", shootdown_nanoseconds[0], " ns with 1 processor running the program, ", shootdown_nanoseconds[1], " ns with 2, ", shootdown_nanoseconds[2], " ns with 4")
	guard_page(ctx)
	system.log("address_space: guard page: the child stopped with vector ", guard_vector, " at ", system.Hex(guard_address), ", in its guard page: ", u64(guard_right))
	large_pages()
	system.log("address_space: large pages: one random read over 64 MiB: ", large_nanoseconds / 10, ".", large_nanoseconds % 10, " ns through large pages of 2 MiB, ", small_nanoseconds / 10, ".", small_nanoseconds % 10, " ns through pages of 4 KiB of the same object; the report says Large: ", u64(large_flags_right))
	refuse()
	for &item in refusals {
		system.log("address_space: refused: ", item.name, ": ", string(item.sentence[:item.count]))
	}
	// Each page returned, except the page tables that Memory_Unmap keeps.
	end_budget, _ := system.budget_read()
	tables := start_budget.pages - end_budget.pages
	if tables > 2048 {
		fail("the budget did not get its pages back")
	}
	done = true
	if right {
		system.log("address_space: ok, the arena and the sparse table paid only what they used, the decommit gave each page back, the protection changed with its shoot-down, the guard page stopped the child, the large pages are in the report, each refusal has its error record")
	} else {
		system.log("address_space: wrong: ", problem)
	}
	frame_draw(&window)
	deadline := system.time()
	for {
		deadline += 500
		display.wait(&window, deadline)
		interface.window_events(&drawing, &window)
		frame_draw(&window)
	}
}
