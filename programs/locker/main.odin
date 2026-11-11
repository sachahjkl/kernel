// A program that the program `locks` starts several times, to load the
// kernel from several programs at one time (package support:lockers). It
// works only on its own objects: another program never waits for it, unless
// the kernel makes it wait.
package locker

import "base:intrinsics"
import "support:lockers"
import "support:system"

// entries enters the kernel with one cheap operation on an own object,
// until the time is end.
entries :: proc "contextless" (memory: system.Handle, end: u64) -> (count: u64) {
	for system.time() < end {
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

// faults repeats fault_round until the time is end.
faults :: proc "contextless" (end: u64) -> (count: u64) {
	for system.time() < end {
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
		before, _ := system.budget_read()
		entered := system.kernel_entries()
		for system.time() < start {
			intrinsics.cpu_relax()
		}
		count: u64
		#partial switch mode {
		case .Entries:
			count = entries(own, end)
		case .Faults:
			count = faults(end)
		case .Large:
			for system.time() < end {
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
