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
//   page tables: each table that a mapping made returns to the budget with
//     its unmap, also while another thread uses a page of the same table;
//   the refusals, each with its error record.
// The window shows the numbers. The log has one line for each case and a
// line "address_space: ok, ..." when each check holds. The checks do not
// depend on the load of the host.
//
// The program needs the machine with the right Inspect (its own mappings)
// and the boot image (its child).
package address_space

import "contract:fixed_addresses"
import "base:intrinsics"
import "contract:errors"
import op "contract:operation"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:random"
import "support:system"

WIDTH :: 960
HEIGHT :: 640
GIGABYTE_PAGES :: 262144 // 1 GiB of pages of 4 KiB.
ARENA_PAGES :: 4096 // The pages that the arena commits for each size of batch.
SPARSE_PAGES :: 1024
PROTECT_PAGES :: 256
PROTECT_CALLS :: 40 // One batch.
PROTECT_BATCHES :: 5
LARGE_OBJECT_PAGES :: 16384 // 64 MiB.
LARGE_ADDRESS :: 0x0000_4000_0000_0000 // Aligned on 2 MiB: the mapping of large pages.
SMALL_ADDRESS :: 0x0000_4100_0000_1000 // Not aligned: the same object with pages of 4 KiB.
GUARD_ADDRESS :: 0x0000_4200_0000_0000 // The stack of the child: the guard page, then 63 pages.
// Places of this program's own choice: outside the band of the fixed
// ranges of the system, which grows by its end.
#assert(LARGE_ADDRESS >= fixed_addresses.OWN_CHOICE_START && SMALL_ADDRESS >= fixed_addresses.OWN_CHOICE_START && GUARD_ADDRESS >= fixed_addresses.OWN_CHOICE_START)
GUARD_STACK_PAGES :: 64
RANDOM_READS :: 4_000_000
VALUE_ROLE :: 0 // The context of the child: 1.

machine: system.Handle
program_generator: random.Generator // The seeds of the children (docs/RANDOMNESS.md).
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
// The middle of one batch of PROTECT_CALLS, with 1, 2 and 4 processors
// running the program: the least and the most of PROTECT_BATCHES batches.
// The program cannot know the load of the host: it shows the spread.
shootdown_least, shootdown_most: [3]u64
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
	// At most RANGE_TABLE_PAGE_LIMIT pages in one call: four calls for 1 GiB;
	// the longest is the longest section of the kernel with interrupts off
	// that a call of this kind makes.
	returned: u64
	decommit := system.Status.Ok
	for part in u64(0) ..< GIGABYTE_PAGES / op.RANGE_TABLE_PAGE_LIMIT {
		quarter := [1]op.Page_Range{{first = part * op.RANGE_TABLE_PAGE_LIMIT, page_count = op.RANGE_TABLE_PAGE_LIMIT}}
		start := system.nanoseconds()
		changed, part_status := system.memory_decommit(memory, quarter[:])
		decommit_microseconds = max(decommit_microseconds, (system.nanoseconds() - start) / 1000)
		returned += changed
		if part_status != .Ok {
			decommit = part_status
		}
	}
	record: errors.Error_Record
	everything := [1]op.Page_Range{{first = 0, page_count = GIGABYTE_PAGES}}
	_, too_many := system.memory_decommit(memory, everything[:], &record)
	if too_many != .Bad_Operation || record.kind != i64(errors.Kind.Too_Long) {
		fail("a decommit of more than the page limit of one call was not refused with its record")
	}
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
		shootdown_least[row] = max(u64)
		for _ in 0 ..< PROTECT_BATCHES {
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
			middle := times[PROTECT_CALLS / 2]
			shootdown_least[row] = min(shootdown_least[row], middle)
			shootdown_most[row] = max(shootdown_most[row], middle)
		}
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
	program, start := system.program_start(system.image_find(image, "address_space"), "address_space child", grants, random.values_with_seed(&program_generator, values), {pages = 2048, programs = 1, threads = 1, processor = 100_000, log_records = 10})
	if start != .Ok {
		fail("the guard page: the child did not start")
		return
	}
	defer system.close(program)
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; system.time() < deadline; {
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
	_, status := system.memory_commit(memory, outside[:], error = &record)
	refusal(&refusals[0], "a range outside the object", .Bad_Address, status, record)
	big, _ := system.memory_create(GIGABYTE_PAGES, flags = {.Uncommitted})
	defer system.close(big)
	record = {}
	over := [1]op.Page_Range{{first = 0, page_count = 60_000}} // Under the page limit of one call, over the budget.
	_, status = system.memory_commit(big, over[:], error = &record)
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

// The edge cases of the virtual memory: each one is a case where the
// kernel did something wrong once, and that must stay right. Each one logs
// a line and sets its result.
EDGE_CASES :: 13
edge_case_names := [EDGE_CASES]string{"a small object with no frame keeps the sums of the frames", "an unmap ends the protection of parts: the object is mapped again", "large pages at an address that the kernel chooses", "a table that names one mapping whole and in part is refused", "a decommit wakes a thread that waits on a word of the page", "a word in the second 4 KiB of a large page is its own word", "an object with parts of their own protection is not mapped again", "a small uncommitted object costs a page", "a part cannot get more than its mapping", "a page that is not committed stops with its own code", "a revocation of a large uncommitted mapping wakes its waiter", "an uncommitted object of 1 GiB ends with few pages walked", "a thread whose first instruction is not an address of a program is refused"}
edge_case_results: [EDGE_CASES]bool

Waiter :: struct #align (64) {
	word:     ^u32,
	value:    u32,
	ended:    u32,
	woke_at:  u64,
	deadline: u64, // The end of the wait: the bound of a hang. A wake before it came from a wake, not from the deadline.
}
waiter: Waiter

wait_run :: proc "c" (parameter: rawptr) -> ! {
	deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS
	waiter.deadline = deadline
	system.word_wait(waiter.word, waiter.value, deadline)
	waiter.woke_at = system.time()
	intrinsics.atomic_store(&waiter.ended, 1)
	system.thread_stop()
}

// waiter_start starts a thread that waits on a word, and waits until it
// waits (its state is Waiting). The bound only ends a hang.
waiter_start :: proc "contextless" (word: ^u32) -> system.Thread {
	waiter = {word = word, value = intrinsics.atomic_load(word)}
	thread, _ := system.thread_start(wait_run, nil)
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; system.time() < deadline; {
		results, _ := system.call(.Thread_State, u64(thread.handle))
		if op.Program_State(results[0]) == .Waiting {
			break
		}
		system.sleep(system.time() + 1)
	}
	return thread
}

edge_cases :: proc "contextless" (ctx: ^system.Context) {
	// A thread waits on a word of a committed page; the page is
	// decommitted: the waiter must wake by the decommit, before its
	// deadline.
	{
		memory, _ := system.memory_create(16, flags = {.Uncommitted})
		address, _ := system.memory_map(memory)
		ranges := [1]op.Page_Range{{first = 3, page_count = 1}}
		system.memory_commit(memory, ranges[:])
		word := (^u32)(uintptr(address) + 3 * system.PAGE_SIZE + 64)
		word^ = 7
		thread := waiter_start(word)
		system.memory_decommit(memory, ranges[:])
		for intrinsics.atomic_load(&waiter.ended) == 0 {
			system.sleep(system.time() + 1)
		}
		system.thread_wait(thread)
		edge_case_results[4] = waiter.woke_at < waiter.deadline
		system.memory_unmap(address)
		system.close(memory)
	}
	// One thread waits on a word in the second 4 KiB of a large page; a
	// wake of the word at the same offset of the first 4 KiB wakes nobody,
	// a wake of its own word wakes it.
	{
		memory, _ := system.memory_create(op.LARGE_PAGE_PAGES, flags = {.Large_Pages})
		address, _ := system.memory_map(memory, {.Write}, 0, LARGE_ADDRESS)
		first := (^u32)(uintptr(address) + 128)
		second := (^u32)(uintptr(address) + system.PAGE_SIZE + 128)
		thread := waiter_start(second)
		wrong := system.word_wake(first)
		intrinsics.atomic_add(second, 1)
		woken := system.word_wake(second)
		system.thread_wait(thread)
		edge_case_results[5] = wrong == 0 && woken == 1
		system.memory_unmap(address)
		system.close(memory)
	}
	// A part of a mapping is made No_Access; the object cannot be
	// mapped a second time while it has marks; after the part has the
	// protection of its mapping again, it can.
	{
		memory, _ := system.memory_create(8)
		address, _ := system.memory_map(memory)
		part := [1]op.Address_Range{{address = u64(uintptr(address)) + system.PAGE_SIZE, page_count = 2}}
		system.memory_protect(part[:], {.No_Access})
		record: errors.Error_Record
		second, refused := system.memory_map(memory, error = &record)
		if refused == .Ok {
			system.memory_unmap(second)
		}
		system.memory_protect(part[:], {.Write})
		third, allowed := system.memory_map(memory)
		if allowed == .Ok {
			system.memory_unmap(third)
		}
		edge_case_results[6] = refused == .Bad_State && record.kind != i64(errors.Kind.Refused) && allowed == .Ok
		system.memory_unmap(address)
		system.close(memory)
	}
	// A budget with no page cannot hold a slot of the table of memory
	// objects with an uncommitted object of 4 pages.
	{
		empty, _ := system.budget_create({pages = 0})
		memory, status := system.memory_create(4, empty, {.Uncommitted})
		if status == .Ok {
			system.close(memory)
		}
		system.close(empty)
		edge_case_results[7] = status == .No_Budget
	}
	// The whole mapping becomes read only; a part of it cannot become
	// writable alone: refused, not a success that changes nothing.
	{
		memory, _ := system.memory_create(8)
		address, _ := system.memory_map(memory)
		whole := [1]op.Address_Range{{address = u64(uintptr(address)), page_count = 8}}
		part := [1]op.Address_Range{{address = u64(uintptr(address)), page_count = 2}}
		system.memory_protect(whole[:], {})
		record: errors.Error_Record
		_, status := system.memory_protect(part[:], {.Write}, &record)
		edge_case_results[8] = status == .Bad_Operation && record.kind != i64(errors.Kind.Refused)
		system.memory_unmap(address)
		system.close(memory)
	}
	// A child touches a page of an uncommitted object that is not committed:
	// it stops with the code of a page that is not committed.
	edge_case_results[9] = child_stop_code(ctx, 3) == op.STOP_CODE_NOT_COMMITTED
	// An Uncommitted object of 1 page, then a report: the test build
	// checks the sums of the frames at each report (a page that such an
	// object pays and that no count names stops the machine), and the free
	// pages less the reserved pages
	// are the pages of the budgets.
	{
		memory, _ := system.memory_create(1, flags = {.Uncommitted})
		report: op.System_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
		system.close(memory)
		after: op.System_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&after)), size_of(after))
		edge_case_results[0] = report.free_pages - report.reserved_pages == report.budget_pages && after.free_pages - after.reserved_pages == after.budget_pages
	}
	// A part of the only mapping gets No_Access, the mapping ends, and
	// the object is mapped again.
	{
		memory, _ := system.memory_create(8)
		address, _ := system.memory_map(memory)
		part := [1]op.Address_Range{{address = u64(uintptr(address)), page_count = 2}}
		system.memory_protect(part[:], {.No_Access})
		system.memory_unmap(address)
		again, status := system.memory_map(memory)
		if status == .Ok {
			bytes := ([^]u8)(again)
			bytes[0] = 1 // The page has no mark: no fault.
			system.memory_unmap(again)
		}
		edge_case_results[1] = status == .Ok
		system.close(memory)
	}
	// An object of large pages at an address that the kernel chooses.
	{
		memory, _ := system.memory_create(op.LARGE_PAGE_PAGES, flags = {.Large_Pages})
		address, status := system.memory_map(memory)
		report := own_mappings()
		mapping := mapping_at(&report, u64(uintptr(address)))
		edge_case_results[2] = status == .Ok && mapping != nil && .Large in mapping.flags
		system.memory_unmap(address)
		system.close(memory)
	}
	// One table: the whole mapping read only, and a part of it writable.
	{
		memory, _ := system.memory_create(8)
		address, _ := system.memory_map(memory)
		ranges := [2]op.Address_Range{{address = u64(uintptr(address)), page_count = 8}, {address = u64(uintptr(address)), page_count = 2}}
		_, status := system.memory_protect(ranges[:], {.Write})
		edge_case_results[3] = status == .Bad_Operation
		system.memory_unmap(address)
		system.close(memory)
	}
	edge_case_results[10] = revocation_wakes_waiter(ctx)
	edge_case_results[11] = large_object_ends_quickly()
	{
		// An address that is not canonical, then one in the half of the
		// kernel: the kernel refuses each, and the machine goes on.
		_, not_canonical := system.call_with_error(nil, .Thread_Create, u64(system.own_budget()), 0x0000_8000_0000_0000, op.USER_END, 0)
		_, of_the_kernel := system.call_with_error(nil, .Thread_Create, u64(system.own_budget()), 0xFFFF_FFFF_8000_0000, op.USER_END, 0)
		_, stack_past_the_end := system.call_with_error(nil, .Thread_Create, u64(system.own_budget()), op.USER_END - 4096, 0x0000_9000_0000_0000, 0)
		edge_case_results[12] = not_canonical == .Bad_Address && of_the_kernel == .Bad_Address && stack_past_the_end == .Bad_Address
	}
	for name, index in edge_case_names {
		system.log("address_space: edge case: ", name, ": ", edge_case_results[index] ? "right" : "WRONG")
		if !edge_case_results[index] {
			fail("an edge case")
		}
	}
}

// A child waits on a word of a mapping of 1 GiB of an Uncommitted object of
// this program; this program revokes the object in the child. The kernel
// wakes the waiter before the frames of the object leave the child: the
// revocation looks for the frames of the words with one sorted search over
// the frames of the object, not with one walk of the object for each word,
// so it ends quickly with an object of 1 GiB. The time of the revocation is
// logged; the check is only that the waiter woke: it waits with no deadline,
// so only the revocation can wake it.
REVOCATION_WORD_PAGE :: 100
GRANT_REVOCATION_OBJECT :: 0
GRANT_REVOCATION_BOARD :: 1

Revocation_Board :: struct {
	ready: u32, // The child maps the object and is about to wait.
	woken: u32, // The child woke.
}

// child_waits_on_object is the child of the role 4.
child_waits_on_object :: proc "contextless" (ctx: ^system.Context) -> ! {
	board_address, _ := system.memory_map(ctx.handles[GRANT_REVOCATION_BOARD])
	board := (^Revocation_Board)(board_address)
	object, _ := system.memory_map(ctx.handles[GRANT_REVOCATION_OBJECT])
	word := (^u32)(uintptr(object) + REVOCATION_WORD_PAGE * system.PAGE_SIZE)
	value := intrinsics.atomic_load(word)
	intrinsics.atomic_store(&board.ready, 1)
	system.word_wake(&board.ready)
	system.word_wait(word, value)
	intrinsics.atomic_store(&board.woken, 1)
	system.word_wake(&board.woken)
	for {
		system.sleep(system.time() + 1000)
	}
}

revocation_wakes_waiter :: proc "contextless" (ctx: ^system.Context) -> bool {
	object, created := system.memory_create(GIGABYTE_PAGES, flags = {.Uncommitted})
	if created != .Ok {
		return false
	}
	defer system.close(object)
	one := [1]op.Page_Range{{first = REVOCATION_WORD_PAGE, page_count = 1}}
	system.memory_commit(object, one[:])
	board_memory, _ := system.memory_create(1)
	defer system.close(board_memory)
	board_address, _ := system.memory_map(board_memory)
	defer system.memory_unmap(board_address)
	board := (^Revocation_Board)(board_address)
	image_address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {})
	if status != .Ok {
		return false
	}
	image := ([^]u8)(image_address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	grants: [op.CONTEXT_HANDLES]system.Grant
	grants[GRANT_REVOCATION_OBJECT] = {object, {.Read, .Write}}
	grants[GRANT_REVOCATION_BOARD] = {board_memory, {.Read, .Write}}
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_ROLE] = 4
	program, start := system.program_start(system.image_find(image, "address_space"), "address_space waiter", grants, random.values_with_seed(&program_generator, values), {pages = 2048, programs = 1, threads = 1, processor = 100_000, log_records = 10})
	if start != .Ok {
		return false
	}
	defer system.close(program)
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; intrinsics.atomic_load(&board.ready) == 0 && system.time() < deadline; {
		system.word_wait(&board.ready, 0, system.time() + 100)
	}
	// The revocation must find the child in its wait: its one thread is
	// not Ready.
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; system.time() < deadline; {
		states, _ := system.call(.Program_State, u64(program))
		if op.Program_State(states[0]) == .Waiting {
			break
		}
		system.sleep(system.time() + 1)
	}
	revoke_start := system.nanoseconds()
	system.handle_revoke(object, program)
	revoke_time := system.nanoseconds() - revoke_start
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; intrinsics.atomic_load(&board.woken) == 0 && system.time() < deadline; {
		system.word_wait(&board.woken, 0, system.time() + 100)
	}
	woke := intrinsics.atomic_load(&board.woken) != 0
	system.log("address_space: a revocation of a mapping of 1 GiB with a thread that waits on a word of it: ", revoke_time / 1000, " us; the waiter ", woke ? "woke" : "did not wake")
	system.call(.Program_Stop, u64(program), 0)
	return woke
}

// An Uncommitted object of 1 GiB with 4 pages that have a frame ends: the
// unmap clears the present entries and stops after the last of them; the
// release gives the frames back and stops after the last frame. The time
// is logged; the check is that each page returned to the budget.
large_object_ends_quickly :: proc "contextless" () -> bool {
	before, _ := system.budget_read()
	object, created := system.memory_create(GIGABYTE_PAGES, flags = {.Uncommitted})
	if created != .Ok {
		return false
	}
	first := [1]op.Page_Range{{first = 0, page_count = 4}}
	system.memory_commit(object, first[:])
	address, status := system.memory_map(object)
	if status != .Ok {
		system.close(object)
		return false
	}
	bytes := ([^]u8)(address)
	for page in 0 ..< 4 {
		bytes[page * system.PAGE_SIZE] = 1
	}
	start := system.nanoseconds()
	system.memory_unmap(address)
	system.close(object)
	ended := system.nanoseconds() - start
	after, _ := system.budget_read()
	// The 513 page tables of the mapping return with the unmap.
	kept := before.pages - after.pages
	system.log("address_space: an Uncommitted object of 1 GiB with 4 frames: unmap and close in ", ended / 1000, " us; pages kept: ", kept)
	return kept == 0
}

// child_stop_code starts the child with a role and gives its stop code.
child_stop_code :: proc "contextless" (ctx: ^system.Context, role: u64) -> u32 {
	address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {})
	if status != .Ok {
		return 0
	}
	image := ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_ROLE] = role
	program, start := system.program_start(system.image_find(image, "address_space"), "address_space child", grants, random.values_with_seed(&program_generator, values), {pages = 2048, programs = 1, threads = 1, processor = 100_000, log_records = 10})
	if start != .Ok {
		return 0
	}
	defer system.close(program)
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; system.time() < deadline; {
		if state, _ := system.program_state(program); state == .Stopped {
			break
		}
		system.sleep(system.time() + 10)
	}
	_, code := system.program_state(program)
	return code
}

// The child of the role 3: it touches a page that is not committed.
child_not_committed :: proc "contextless" () -> ! {
	memory, _ := system.memory_create(16, flags = {.Uncommitted})
	address, _ := system.memory_map(memory)
	intrinsics.volatile_store(&([^]u8)(address)[5 * system.PAGE_SIZE], 1)
	system.stop(0)
}

// The delegation of a commit (docs/ARCHITECTURE.md, "Who pays a commit"): this
// program A makes a child budget and an uncommitted object on it, and gives
// a second program B the object (Read, Write) and the child budget with the
// right Commit only. B runs the cases of the amendment of the read, one at
// a time on a board that the two map; A acts between them (revocations, a
// decommit, the end of the child budget). Each case logs its line with the
// sentence of its error record.
DELEGATION_OBJECT_PAGES :: 64
DELEGATION_BUDGET_PAGES :: 33 // 1 page of the frame list, then 32 pages that B can commit.
DELEGATION_CASES :: 10
GRANT_DELEGATION_BOARD :: 0
GRANT_DELEGATION_OBJECT :: 1
GRANT_DELEGATION_BUDGET :: 2 // The child budget, with Commit only.
GRANT_DELEGATION_SPEND :: 3 // A second child budget with Spend: does a revocation end what B made with it?

Delegation_Result :: struct {
	status:   system.Status,
	record:   errors.Error_Record,
	value:    u64,
}

Delegation_Board :: struct {
	step:    u32, // A writes the case that B runs now.
	done:    u32, // B writes the case that it ran.
	results: [DELEGATION_CASES + 1]Delegation_Result,
}

delegation_names := [DELEGATION_CASES + 1]string {
	"",
	"1 B commits 32 pages, then one more",
	"2 B commits with no budget handle; it reads and writes the committed pages",
	"3 B makes an object with the handle that has Commit only",
	"4 B commits with a budget that does not pay for the object",
	"5 A revokes the budget handle of B: B commits no more",
	"6 A takes the pages back: it revokes the object of B, then decommits",
	"7 B decommits pages of an object that A holds too",
	"8 the child budget ends: the object moves to the budget of A",
	"9 B gives its Commit handle on: it has no right Give",
	"10 an object that B made with a Spend handle, after the revocation",
}
delegation_right: [DELEGATION_CASES + 1]bool
delegation_lines: [DELEGATION_CASES + 1][200]u8
delegation_line_counts: [DELEGATION_CASES + 1]int

// child_delegate is B: it runs case n when A writes n, and writes its result.
child_delegate :: proc "contextless" (ctx: ^system.Context) -> ! {
	address, _ := system.memory_map(ctx.handles[GRANT_DELEGATION_BOARD])
	board := (^Delegation_Board)(address)
	memory := ctx.handles[GRANT_DELEGATION_OBJECT]
	budget := ctx.handles[GRANT_DELEGATION_BUDGET]
	spend := ctx.handles[GRANT_DELEGATION_SPEND]
	object, _ := system.memory_map(memory)
	bytes := ([^]u8)(object)
	made: system.Handle
	seen: u32
	for {
		step := intrinsics.atomic_load(&board.step)
		if step == seen {
			system.word_wait(&board.step, step, system.time() + 1000)
			continue
		}
		seen = step
		result := &board.results[step]
		switch step {
		case 1:
			first := [1]op.Page_Range{{first = 0, page_count = 32}}
			if _, status := system.memory_commit(memory, first[:], budget); status == .Ok {
				one := [1]op.Page_Range{{first = 32, page_count = 1}}
				_, result.status = system.memory_commit(memory, one[:], budget, &result.record)
			}
		case 2:
			ranges := [1]op.Page_Range{{first = 40, page_count = 1}}
			_, result.status = system.call_with_error(&result.record, .Memory_Commit, u64(memory), 0, u64(uintptr(&ranges[0])), 1, 0)
			bytes[5 * system.PAGE_SIZE] = 55
			result.value = u64(bytes[5 * system.PAGE_SIZE])
		case 3:
			_, result.status = system.memory_create(1, budget, error = &result.record)
		case 4:
			ranges := [1]op.Page_Range{{first = 33, page_count = 1}}
			_, result.status = system.memory_commit(memory, ranges[:], system.own_budget(), &result.record)
		case 5:
			ranges := [1]op.Page_Range{{first = 34, page_count = 1}}
			_, result.status = system.memory_commit(memory, ranges[:], budget, &result.record)
			// The object that B made with the Spend handle before the revocation.
			result.value = system.memory_size(made)
		case 7:
			ranges := [1]op.Page_Range{{first = 0, page_count = 32}}
			_, result.status = system.memory_decommit(memory, ranges[:], &result.record)
		case 9:
			_, result.status = system.give(ctx.handles[GRANT_DELEGATION_BOARD], budget, {.Commit}, &result.record)
		case 10:
			made, result.status = system.memory_create(1, spend, error = &result.record)
		}
		intrinsics.atomic_store(&board.done, step)
		system.word_wake(&board.done)
	}
}

delegation_run :: proc "contextless" (board: ^Delegation_Board, step: u32) -> ^Delegation_Result {
	intrinsics.atomic_store(&board.step, step)
	system.word_wake(&board.step)
	for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; intrinsics.atomic_load(&board.done) != step && system.time() < deadline; {
		system.word_wait(&board.done, intrinsics.atomic_load(&board.done), system.time() + 100)
	}
	return &board.results[step]
}

delegation_note :: proc "contextless" (step: int, right: bool, result: ^Delegation_Result, parts: ..system.Part) {
	delegation_right[step] = right
	writer := system.Writer{buffer = delegation_lines[step][:]}
	for part in parts {
		system.write_part(&writer, part)
	}
	if result != nil && result.status != .Ok {
		system.kernel_error_text(&writer, &result.record)
	}
	delegation_line_counts[step] = len(system.written(&writer))
	system.log("address_space: delegation: ", delegation_names[step], ": ", right ? "as expected: " : "WRONG: ", string(delegation_lines[step][:delegation_line_counts[step]]))
	if !right {
		fail("a case of the delegation")
	}
}

delegation :: proc "contextless" (ctx: ^system.Context) {
	address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {})
	if status != .Ok {
		fail("the delegation: no boot image")
		return
	}
	image := ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	child_budget, _ := system.budget_create({pages = DELEGATION_BUDGET_PAGES})
	spend_budget, _ := system.budget_create({pages = 8})
	object, _ := system.memory_create(DELEGATION_OBJECT_PAGES, child_budget, {.Uncommitted})
	board_memory, _ := system.memory_create(1)
	board_address, _ := system.memory_map(board_memory)
	board := (^Delegation_Board)(board_address)
	grants: [op.CONTEXT_HANDLES]system.Grant
	grants[GRANT_DELEGATION_BOARD] = {board_memory, {.Read, .Write}}
	grants[GRANT_DELEGATION_OBJECT] = {object, {.Read, .Write}}
	grants[GRANT_DELEGATION_BUDGET] = {child_budget, {.Commit}}
	grants[GRANT_DELEGATION_SPEND] = {spend_budget, {.Spend}}
	values: [op.CONTEXT_VALUES]u64
	values[VALUE_ROLE] = 2
	program, start := system.program_start(system.image_find(image, "address_space"), "address_space delegate", grants, random.values_with_seed(&program_generator, values), {pages = 512, programs = 1, threads = 1, processor = 100_000, log_records = 50})
	if start != .Ok {
		fail("the delegation: B did not start")
		return
	}
	defer system.close(program)

	result := delegation_run(board, 1)
	delegation_note(1, result.status == .No_Budget && result.record.kind == i64(errors.Kind.Budget_Hidden), result, "32 pages committed; the 33rd: ")
	result = delegation_run(board, 2)
	delegation_note(2, result.status == .Bad_Handle && result.value == 55, result, "B wrote and read 55 in a committed page; a commit: ")
	result = delegation_run(board, 3)
	delegation_note(3, result.status == .No_Right, result, "")
	result = delegation_run(board, 4)
	delegation_note(4, result.status == .Bad_Handle && result.record.kind == i64(errors.Kind.Not_Payer), result, "")
	result = delegation_run(board, 7)
	delegation_note(7, result.status == .Bad_State && result.record.kind == i64(errors.Kind.Object_Shared), result, "")
	result = delegation_run(board, 9)
	delegation_note(9, result.status == .No_Right, result, "")
	result = delegation_run(board, 10)
	made := result.status == .Ok
	// 5: A revokes the two budget handles of B.
	system.handle_revoke(child_budget, program)
	system.handle_revoke(spend_budget, program)
	held, _ := system.budget_read(child_budget)
	result = delegation_run(board, 5)
	delegation_note(5, result.status == .Bad_Handle && result.record.kind == i64(errors.Kind.Handle_Ended) && held.pages == 0, result, "the 32 pages stay committed and paid (the child budget holds 0); a commit: ")
	// 10: the object that B made with the Spend handle stays: a revocation
	// ends the holdings that came from the handle (handles and mappings),
	// not the objects that were made with it.
	delegation_note(10, made && result.value == 1, nil, made && result.value == 1 ? "the object of 1 page that B made with it lives on after the revocation, paid by the child budget, and A cannot end it: the narrow right Commit makes no object" : "the object did not stay")
	// 6: A revokes the object of B (B is unmapped), then decommits.
	system.handle_revoke(object, program)
	before, _ := system.budget_read(child_budget)
	everything := [1]op.Page_Range{{first = 0, page_count = DELEGATION_OBJECT_PAGES}}
	returned, decommit := system.memory_decommit(object, everything[:])
	after, _ := system.budget_read(child_budget)
	delegation_note(6, decommit == .Ok && returned == 32 && after.pages - before.pages == 32, nil, decommit == .Ok ? "32 pages back in the child budget; A held the object with no mapping" : "the decommit was refused")
	// 8: A closes the child budget: the object moves to the budget of A,
	// and a commit needs the budget of A now; the old handle names nothing.
	system.close(child_budget)
	record: errors.Error_Record
	one := [1]op.Page_Range{{first = 0, page_count = 1}}
	_, old := system.memory_commit(object, one[:], child_budget, &record)
	committed, now := system.memory_commit(object, one[:])
	delegation_note(8, old == .Bad_Handle && now == .Ok && committed == 1, nil, now == .Ok ? "a commit with the budget of A: 1 page; with the old handle: refused" : "the commit with the budget of A was refused")
	system.close(object)
	system.close(spend_budget)
	system.call(.Program_Stop, u64(program), 0)
	system.memory_unmap(board_address)
	system.close(board_memory)
}

// The addresses that the kernel chooses are used again: one object mapped
// and unmapped 100 000 times costs the budget the same as one time.
reuse_right: bool
reuse_pages_first, reuse_pages_last: u64

addresses_reused :: proc "contextless" () {
	memory, _ := system.memory_create(4)
	defer system.close(memory)
	for round in 0 ..< 100_000 {
		address, status := system.memory_map(memory)
		if status != .Ok {
			fail("the reuse of addresses: a map was refused")
			return
		}
		system.memory_unmap(address)
		if round == 0 {
			first, _ := system.budget_read()
			reuse_pages_first = first.pages
		}
	}
	last, _ := system.budget_read()
	reuse_pages_last = last.pages
	reuse_right = reuse_pages_first == reuse_pages_last
	if !reuse_right {
		fail("the reuse of addresses: the budget paid for more page tables")
	}
}

// The page tables that a mapping made return to the budget with its unmap
// (docs/ARCHITECTURE.md, "The page tables of a program"). The addresses are
// SPREAD_STRIDE apart: 512 GiB, 1 GiB and 2 MiB, so each one has its own
// entry of the top table, of the third level and of the second level, and a
// mapping there needs three new tables. No other mapping of this program is
// in that band.
SPREAD_ADDRESS :: 0x0000_4400_0000_0000
SPREAD_STRIDE :: 0x0000_0080_4020_0000
SPREAD_COUNT :: 64
#assert(SPREAD_ADDRESS >= fixed_addresses.OWN_CHOICE_START && SPREAD_ADDRESS > GUARD_ADDRESS)
#assert(SPREAD_ADDRESS + (SPREAD_COUNT + 4) * SPREAD_STRIDE < op.THREAD_AREA_BASE &~ (512 << 30 - 1))
#assert(SPREAD_STRIDE % (2 << 20) == 0) // Each address can hold a large page.
NEIGHBOUR_ROUNDS :: 1000
RESERVATION_PAGES :: 1024 // 4 MiB from an address on 2 MiB: two tables of the last level.

Neighbour :: struct #align (64) {
	word:    ^u64,
	stop:    u32,
	wrong:   u32,
	touches: u64,
}
neighbour: Neighbour

// neighbour_touch writes and reads a word of a page in the same table of the
// last level as the pages that the other thread maps and unmaps. A fault
// here stops this program: the line "ok" never comes.
neighbour_touch :: proc "c" (parameter: rawptr) -> ! {
	for intrinsics.atomic_load(&neighbour.stop) == 0 {
		value := intrinsics.atomic_load(&neighbour.touches) + 1
		intrinsics.volatile_store(neighbour.word, value)
		if intrinsics.volatile_load(neighbour.word) != value {
			intrinsics.atomic_store(&neighbour.wrong, 1)
		}
		intrinsics.atomic_store(&neighbour.touches, value)
	}
	system.thread_stop()
}

page_tables_line :: proc "contextless" (right_case: bool, parts: ..system.Part) {
	buffer: [320]u8
	system.log("address_space: page tables: ", system.format(buffer[:], ..parts), right_case ? string(": as it must") : string(": WRONG"))
	if !right_case {
		fail("a page table did not return to the budget")
	}
}

page_tables_return :: proc "contextless" () {
	// 1. One page at 64 addresses: three tables while it is mapped, none
	// after.
	{
		memory, _ := system.memory_create(1)
		before, _ := system.budget_read()
		least_paid, most_paid, kept: u64 = max(u64), 0, 0
		mapped_all := true
		for index in u64(0) ..< SPREAD_COUNT {
			address, status := system.memory_map(memory, {.Write}, 0, SPREAD_ADDRESS + index * SPREAD_STRIDE)
			if status != .Ok {
				mapped_all = false
				break
			}
			intrinsics.volatile_store((^u64)(address), index)
			during, _ := system.budget_read()
			least_paid = min(least_paid, before.pages - during.pages)
			most_paid = max(most_paid, before.pages - during.pages)
			system.memory_unmap(address)
			after, _ := system.budget_read()
			kept = max(kept, before.pages - after.pages)
		}
		system.close(memory)
		page_tables_line(mapped_all && least_paid == 3 && most_paid == 3 && kept == 0, u64(SPREAD_COUNT), " mappings of one page, each at its own entry of three levels: ", least_paid, " to ", most_paid, " pages of tables while mapped, ", kept, " pages kept after the unmap")
	}
	// 2. A reservation of 4 MiB: its four tables stay through a commit and a
	// decommit (the mapping still holds its range, so a fault never needs a
	// table), and return with the unmap.
	{
		memory, _ := system.memory_create(RESERVATION_PAGES, flags = {.Uncommitted})
		before, _ := system.budget_read()
		address, status := system.memory_map(memory, {.Write}, 0, SPREAD_ADDRESS)
		mapped, _ := system.budget_read()
		returned: u64
		decommitted := mapped
		if status == .Ok {
			some := [1]op.Page_Range{{first = 500, page_count = 16}}
			system.memory_commit(memory, some[:])
			bytes := ([^]u8)(address)
			for page in u64(500) ..< 516 {
				intrinsics.volatile_store(&bytes[page * system.PAGE_SIZE], 1)
			}
			returned, _ = system.memory_decommit(memory, some[:])
			decommitted, _ = system.budget_read()
			system.memory_unmap(address)
		}
		after, _ := system.budget_read()
		system.close(memory)
		tables := before.pages - mapped.pages
		page_tables_line(status == .Ok && returned == 16 && tables == 4 && decommitted.pages == mapped.pages && after.pages == before.pages, "a reservation of ", u64(RESERVATION_PAGES), " pages: ", tables, " pages of tables, ", decommitted.pages == mapped.pages ? string("the same") : string("not the same"), " after a commit and a decommit of 16 pages, ", before.pages - after.pages, " pages kept after the unmap")
	}
	// 3. A large page: two tables above it, both return.
	{
		memory, created := system.memory_create(op.LARGE_PAGE_PAGES, flags = {.Large_Pages})
		before, _ := system.budget_read()
		address, status := system.memory_map(memory, {.Write}, 0, SPREAD_ADDRESS + 2 * SPREAD_STRIDE)
		mapped, _ := system.budget_read()
		report := own_mappings()
		mapping := mapping_at(&report, SPREAD_ADDRESS + 2 * SPREAD_STRIDE)
		large := mapping != nil && .Large in mapping.flags
		if status == .Ok {
			intrinsics.volatile_store((^u64)(address), 1)
			system.memory_unmap(address)
		}
		after, _ := system.budget_read()
		system.close(memory)
		tables := before.pages - mapped.pages
		page_tables_line(created == .Ok && status == .Ok && large && tables == 2 && after.pages == before.pages, "a large page: ", tables, " pages of tables above it while mapped, ", before.pages - after.pages, " pages kept after the unmap")
	}
	// 4. Two threads: this one maps and unmaps a page in the table of the
	// page of the other thread (the table stays: the other page holds it),
	// and a page at its own entry of three levels (three tables leave at each
	// unmap, while the other thread runs on the same page table).
	{
		near, _ := system.memory_create(1)
		far, _ := system.memory_create(1)
		watched, _ := system.memory_create(1)
		word_address, watched_status := system.memory_map(watched, {.Write}, 0, SPREAD_ADDRESS + 3 * SPREAD_STRIDE)
		if watched_status != .Ok {
			system.close(near)
			system.close(far)
			system.close(watched)
			page_tables_line(false, "the page of the other thread: no mapping")
			return
		}
		neighbour = {word = (^u64)(word_address)}
		thread, thread_status := system.thread_start(neighbour_touch, nil)
		// The other thread runs before the rounds start. The bound only ends
		// a hang.
		for deadline := system.time() + system.TEST_HANG_BOUND_MILLISECONDS; intrinsics.atomic_load(&neighbour.touches) == 0 && system.time() < deadline; {
			system.sleep(system.time() + 1)
		}
		touches_before := intrinsics.atomic_load(&neighbour.touches)
		before, _ := system.budget_read()
		rounds_right: u64
		for round in u64(0) ..< NEIGHBOUR_ROUNDS {
			near_address, near_status := system.memory_map(near, {.Write}, 0, SPREAD_ADDRESS + 3 * SPREAD_STRIDE + system.PAGE_SIZE)
			far_address, far_status := system.memory_map(far, {.Write}, 0, SPREAD_ADDRESS + 4 * SPREAD_STRIDE)
			if near_status != .Ok || far_status != .Ok {
				break
			}
			intrinsics.volatile_store((^u64)(near_address), round)
			intrinsics.volatile_store((^u64)(far_address), round + 1)
			if intrinsics.volatile_load((^u64)(near_address)) == round && intrinsics.volatile_load((^u64)(far_address)) == round + 1 {
				rounds_right += 1
			}
			system.memory_unmap(near_address)
			system.memory_unmap(far_address)
		}
		after, _ := system.budget_read()
		touches_after := intrinsics.atomic_load(&neighbour.touches)
		intrinsics.atomic_store(&neighbour.stop, 1)
		if thread_status == .Ok {
			system.thread_wait(thread)
		}
		value_right := intrinsics.atomic_load(&neighbour.wrong) == 0 && intrinsics.volatile_load(neighbour.word) == intrinsics.atomic_load(&neighbour.touches)
		system.memory_unmap(word_address)
		system.close(near)
		system.close(far)
		system.close(watched)
		system.log("address_space: page tables: the other thread wrote and read its page ", touches_after - touches_before, " times during the rounds")
		page_tables_line(thread_status == .Ok && rounds_right == NEIGHBOUR_ROUNDS && touches_before != 0 && touches_after > touches_before && value_right && after.pages == before.pages, u64(NEIGHBOUR_ROUNDS), " rounds of a map and an unmap beside a page that another thread writes and reads: ", rounds_right, " rounds right, the page of the other thread ", value_right ? string("stayed right") : string("changed"), ", ", before.pages - after.pages, " pages kept")
	}
}

// The window: one card for each case, with the numbers.
records_now, records_before: [1024]interface.Draw_Record
text_now, text_before: [16384]u8
drawing: interface.Window_Drawing

line :: proc "contextless" (frame: ^interface.Frame, column: ^interface.Column, label: string, parts: ..system.Part) {
	buffer: [96]u8
	interface.label_value_line(frame, interface.column_take(column, 16), label, system.format(buffer[:], ..parts), graphics.COLOR_TEXT, 208)
}

build :: proc "contextless" (frame: ^interface.Frame) {
	interface.background(frame, {0, 0, WIDTH, HEIGHT})
	left := interface.card(frame, {8, 8, WIDTH / 2 - 12, HEIGHT - 16}, "RESERVE AND COMMIT", "Memory_Commit", graphics.COLOR_MEMORY)
	column := interface.column_of(left, 4)
	line(frame, &column, "arena: addresses", "1 GiB, one mapping")
	line(frame, &column, "  frame list paid", arena_list_pages, " pages")
	line(frame, &column, "  mapped in", arena_map_microseconds, " us")
	interface.cell_text(frame, interface.column_take(&column, 16), "  pages committed and used in one second,", graphics.COLOR_DIM)
	interface.cell_text(frame, interface.column_take(&column, 16), "  and kernel entries for 1000 pages:", graphics.COLOR_DIM)
	for batch, row in batch_sizes {
		buffer: [48]u8
		label := system.format(buffer[:], "  ", batch, batch == 1 ? " range" : " ranges", " / entry")
		line(frame, &column, label, arena_pages_per_second[row], " pages/s, ", arena_entries_per_thousand_pages[row], " entries")
	}
	interface.column_take(&column, 8)
	line(frame, &column, "sparse: committed", sparse_committed, " of ", u64(GIGABYTE_PAGES), " pages")
	line(frame, &column, "  with a frame", sparse_present, " pages")
	line(frame, &column, "decommit: returned", decommit_returned, " of ", decommit_expected, " pages")
	line(frame, &column, "  longest call", decommit_microseconds, " us")
	line(frame, &column, "  committed again", recommit_zero ? "zero" : "not zero")
	line(frame, &column, "map and unmap 100000", reuse_right ? "no page table more" : "page tables grew")
	interface.column_take(&column, 8)
	interface.cell_text(frame, interface.column_take(&column, 16), "refusals, each with its error record", graphics.COLOR_DIM)
	for &item in refusals {
		color: graphics.Color = item.status == item.expected ? graphics.COLOR_PROGRAM : graphics.COLOR_FAILED
		interface.cell_text(frame, interface.column_take(&column, 16), item.name, graphics.COLOR_TEXT)
		// Two lines, cut at a space.
		first := min(item.count, 52)
		for first < item.count && first > 0 && item.sentence[first] != ' ' {
			first -= 1
		}
		interface.cell_text(frame, interface.column_take(&column, 16), string(item.sentence[:first]), color)
		interface.cell_text(frame, interface.column_take(&column, 16), string(item.sentence[min(first + 1, item.count):min(item.count, first + 53)]), color)
	}
	right_card := interface.card(frame, {WIDTH / 2 + 4, 8, WIDTH / 2 - 12, HEIGHT - 16}, "PROTECT, GUARD, LARGE PAGES", "Memory_Protect", graphics.COLOR_KERNEL)
	column = interface.column_of(right_card, 4)
	interface.cell_text(frame, interface.column_take(&column, 16), "64 pages read only, then writable: the middle", graphics.COLOR_DIM)
	interface.cell_text(frame, interface.column_take(&column, 16), "of 40 calls, least and most of 5 batches:", graphics.COLOR_DIM)
	most := max(shootdown_most[0], shootdown_most[1], shootdown_most[2], 1)
	for processors, row in ([3]u64{1, 2, 4}) {
		buffer: [48]u8
		line(frame, &column, system.format(buffer[:], processors, processors == 1 ? " processor" : " processors"), shootdown_least[row] == max(u64) ? u64(0) : shootdown_least[row], " to ", shootdown_most[row], " ns")
		// The track, the spread from the least to the most, and the least.
		area := interface.column_take(&column, 8)
		interface.bar(frame, area, shootdown_most[row], most, graphics.shade(graphics.COLOR_KERNEL, 50))
		least := shootdown_least[row] == max(u64) ? 0 : shootdown_least[row]
		interface.bar(frame, {area.x, area.y, int(least * u64(area.width) / most), area.height}, 1, 1, graphics.COLOR_KERNEL)
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
	interface.cell_text(frame, interface.column_take(&column, 16), "delegation: B commits for A with the right Commit", graphics.COLOR_DIM)
	cases_line: [64]u8
	cases_right: u64
	for step in 1 ..= DELEGATION_CASES {
		cases_right += delegation_right[step] ? 1 : 0
	}
	marks := interface.column_take(&column, 16)
	for step in 1 ..= DELEGATION_CASES {
		color: graphics.Color = delegation_line_counts[step] == 0 ? graphics.COLOR_TRACK : delegation_right[step] ? graphics.COLOR_PROGRAM : graphics.COLOR_FAILED
		interface.mark(frame, marks.x + (step - 1) * 16, marks.y + 4, 8, color)
	}
	interface.cell_text(frame, {marks.x + 168, marks.y, marks.width - 168, 16}, system.format(cases_line[:], cases_right, " of 10 as expected"), graphics.COLOR_TEXT)
	edge_count: u64
	for result in edge_case_results {
		edge_count += result ? 1 : 0
	}
	line(frame, &column, "edge cases", edge_count, " of ", u64(EDGE_CASES), " right")
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
	if ctx.values[VALUE_ROLE] == 4 {
		child_waits_on_object(ctx)
	}
	if ctx.values[VALUE_ROLE] == 3 {
		child_not_committed()
	}
	if ctx.values[VALUE_ROLE] == 2 {
		child_delegate(ctx)
	}
	random.generator_from_context(&program_generator, ctx)
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
	system.log("address_space: protection of 64 pages, one call with its shoot-down, the middle of 40 calls, least and most of 5 batches: ", shootdown_least[0], " to ", shootdown_most[0], " ns with 1 processor running the program, ", shootdown_least[1], " to ", shootdown_most[1], " ns with 2, ", shootdown_least[2], " to ", shootdown_most[2], " ns with 4")
	guard_page(ctx)
	system.log("address_space: guard page: the child stopped with vector ", guard_vector, " at ", system.Hex(guard_address), ", in its guard page: ", u64(guard_right))
	large_pages()
	system.log("address_space: large pages: one random read over 64 MiB: ", large_nanoseconds / 10, ".", large_nanoseconds % 10, " ns through large pages of 2 MiB, ", small_nanoseconds / 10, ".", small_nanoseconds % 10, " ns through pages of 4 KiB of the same object; the report says Large: ", u64(large_flags_right))
	refuse()
	edge_cases(ctx)
	delegation(ctx)
	addresses_reused()
	system.log("address_space: addresses: one object mapped and unmapped 100000 times: the budget holds ", reuse_pages_last, " pages after, ", reuse_pages_first, " after the first time")
	page_tables_return()
	for &item in refusals {
		system.log("address_space: refused: ", item.name, ": ", string(item.sentence[:item.count]))
	}
	// Each page returned, except what this program still maps: the boot
	// image, which each case that starts a child maps, and its page tables.
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
