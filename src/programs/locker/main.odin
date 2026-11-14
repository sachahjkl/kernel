// A program that the program `locks` starts several times, to load the
// kernel from several programs at one time (package support:lockers). It
// works only on its own objects: another program never waits for it, unless
// the kernel makes it wait.
//
//
// **What it is for.** The program `locks` needs load on the kernel from
// several programs whose kernel entries touch no common object: then a
// locker waits for another one only when a lock of the kernel makes it
// wait, and the waits that `locks` counts are the cost of the
// [locks of the kernel](term:lock-of-the-kernel). This program is that
// load.
//
// **What a reader sees.** Nothing of its own: no window, no menu line. It
// runs while `locks` measures, and `locks` writes its counts.
//
// **How it works.** `locks` starts it from the boot image with a
// [locker](term:locker) slot of a shared board (`lockers.Board`). The
// locker waits on the word `command` of its slot, then runs the mode that
// the slot names until the time `end` of the command, or until the count
// `limit` of the command: `Entries` (one cheap kernel
// operation on its own object, as often as it can), `Faults` (pages on
// first use: create, map, write one byte in each page, unmap, close), or
// `Large` (create and close a memory object of 600 pages). It counts its
// operations and its kernel entries in its slot. In the stress case
// (`lockers.ROLE_CHURN`) it starts and stops programs with a peer instead.
//
// **Its grants**: none of the root service. The board and its role come
// from `locks`.
package locker

import "base:intrinsics"
import "support:lockers"
import "support:system"

// entries enters the kernel with one cheap operation on an own object,
// until the time is end or the count is limit (0: no limit).
entries :: proc "contextless" (memory: system.Handle, end, limit: u64) -> (count: u64) {
	for system.time() < end && (limit == 0 || count < limit) {
		for _ in 0 ..< 64 {
			system.call(.Memory_Size, u64(memory))
		}
		count += 64
	}
	return count
}

// fault_round creates a memory object, maps it, writes one byte in each
// page, unmaps it and closes it. Each first write is a page fault on first
// use. It gives the pages written.
fault_round :: proc "contextless" () -> u64 {
	memory, status := system.memory_create(lockers.FAULT_PAGES)
	if status != .Ok {
		return 0
	}
	defer system.close(memory)
	address, map_status := system.memory_map(memory, {.Write}, 0, lockers.FAULT_ADDRESS)
	if map_status != .Ok {
		return 0
	}
	for &page in ([^][system.PAGE_SIZE]u8)(address)[:lockers.FAULT_PAGES] {
		intrinsics.volatile_store(&page[0], 1)
	}
	system.memory_unmap(address)
	return lockers.FAULT_PAGES
}

// faults repeats fault_round until the time is end or the pages are limit
// (0: no limit).
faults :: proc "contextless" (end, limit: u64) -> (count: u64) {
	for system.time() < end && (limit == 0 || count < limit) {
		count += fault_round()
	}
	return count
}

spin :: proc "c" (parameter: rawptr) -> ! {
	for {
		intrinsics.cpu_relax()
	}
}

brief :: proc "c" (parameter: rawptr) -> ! {
	system.thread_stop()
}

// churn is the role of a locker in the stress case (lockers.ROLE_CHURN).
churn :: proc "contextless" (stop_after: u64, peer: system.Handle) -> ! {
	start := system.time()
	stop_after := stop_after
	spinners: [2]system.Thread
	for &spinner in spinners {
		spinner, _ = system.thread_start(spin, nil)
	}
	for round := 0; ; round += 1 {
		if stop_after != 0 && system.time() >= start + stop_after {
			if peer == 0 {
				system.stop(0)
			}
			// Two programs stop each other: `locks` stops this one now too.
			system.call(.Program_Stop, u64(peer), 5)
			stop_after = 0
		}
		if thread, status := system.thread_start(brief, nil); status == .Ok {
			system.thread_wait(thread)
		}
		spinner := &spinners[round % len(spinners)]
		if spinner.handle != 0 {
			system.thread_end(spinner^)
		}
		spinner^, _ = system.thread_start(spin, nil)
	}
}

// entry runs the role that `locks` wrote in the context: the stress case
// (`churn`), or a locker slot of the board. A locker prepares the page
// tables of its range, tells `locks` that it is ready, then waits for each
// command and runs its mode until the next one. With no board or a slot
// number past the board, it stops with the code 1.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	if ctx.values[lockers.VALUE_ROLE] == lockers.ROLE_CHURN {
		churn(ctx.values[lockers.VALUE_STOP_AFTER], ctx.handles[lockers.GRANT_PEER])
	}
	address, status := system.memory_map(ctx.handles[lockers.GRANT_BOARD])
	index := ctx.values[lockers.VALUE_INDEX]
	if status != .Ok || index >= lockers.LOCKER_CAPACITY {
		system.stop(1)
	}
	slot := &(^lockers.Board)(address).slots[index]
	own, _ := system.memory_create(1)
	// The page tables of the range of the measure: the budget pays for
	// them now, and each later page returns to the budget.
	fault_round()
	// Ready: `locks` waits for this before the first command.
	intrinsics.atomic_add(&slot.done, 1)
	system.word_wake(&slot.done, system.WAKE_ALL)
	seen: u32
	for {
		command := intrinsics.atomic_load(&slot.command)
		if command == seen {
			system.word_wait(&slot.command, command)
			continue
		}
		seen = command
		mode := slot.mode
		start := slot.start
		end := slot.end
		limit := slot.limit
		before, _ := system.budget_read()
		entered := system.kernel_entries()
		for system.time() < start {
			intrinsics.cpu_relax()
		}
		count: u64
		#partial switch mode {
		case .Entries:
			count = entries(own, end, limit)
		case .Faults:
			count = faults(end, limit)
		case .Large:
			for system.time() < end && (limit == 0 || count < limit) {
				if memory, made := system.memory_create(lockers.LARGE_PAGES); made == .Ok {
					system.close(memory)
					count += 1
				}
			}
		}
		after, _ := system.budget_read()
		slot.count = count
		slot.entries = system.kernel_entries() - entered
		slot.budget_before = before.pages
		slot.budget_after = after.pages
		intrinsics.atomic_add(&slot.done, 1)
		system.word_wake(&slot.done, system.WAKE_ALL)
	}
}
