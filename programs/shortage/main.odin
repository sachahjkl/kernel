// The real shortage of page frames (docs/ARCHITECTURE.md, "The frame
// caches"). This program runs alone, on a machine of the test whose boot
// image has no desktop: the root service gives it nearly all of its pages.
//
// The frame table becomes empty only when the unspent pages of all the
// budgets and the reserved pages are fewer than the frames in the stacks of
// the processors. Here the budget of this program holds nearly all of them.
// Four threads make memory objects until the budget pays no more, and write
// one byte in each page: each first use is a take that cannot fail. Near the
// end the frame table is empty while the stacks of the other processors
// hold frames: the take drains the stacks and succeeds. Then the program
// checks, with the exact difference of System_Report, that no frame is free
// anywhere that a budget can pay, that a Memory_Create fails with its error
// record, frees everything, and checks that the sums are those of the start.
// It stops the machine with the code 0.
package shortage

import "base:intrinsics"
import "contract:errors"
import op "contract:operation"
import "support:system"

THREAD_COUNT :: 4
OBJECT_PAGES :: 4096 // The first size of the objects; it halves when the budget cannot pay it.
OBJECT_CAPACITY :: 24 // The objects of one thread: the mappings of the program are 128.

Filler :: struct #align (64) {
	objects:  [OBJECT_CAPACITY]system.Handle,
	addresses: [OBJECT_CAPACITY]rawptr, // Where each object is mapped; nil: not mapped.
	count:    int,
	pages:    u64, // Pages written for the first time.
	ended:    u32,
}

fillers: [THREAD_COUNT]Filler
machine: system.Handle

system_report :: proc "contextless" () -> (report: op.System_Report) {
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
	return report
}

drains :: proc "contextless" (processors: u64) -> (sum: u64) {
	for index in 0 ..< processors {
		report: op.Processor_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Processor), index, u64(uintptr(&report)), size_of(report))
		sum += report.cache_drains
	}
	return sum
}

// fill makes objects until the budget pays no more, and writes each page.
fill :: proc "c" (parameter: rawptr) -> ! {
	filler := (^Filler)(parameter)
	size := u64(OBJECT_PAGES)
	for size != 0 && filler.count < OBJECT_CAPACITY {
		memory, status := system.memory_create(size)
		if status != .Ok {
			size /= 2
			continue
		}
		filler.objects[filler.count] = memory
		filler.count += 1
		address, map_status := system.memory_map(memory)
		if map_status != .Ok {
			// The budget paid the object and cannot pay the page tables of
			// a mapping: the object returns, and a smaller one comes.
			system.close(memory)
			filler.count -= 1
			size /= 2
			continue
		}
		filler.addresses[filler.count - 1] = address
		bytes := ([^]u8)(address)
		for page in 0 ..< size {
			intrinsics.volatile_store(&bytes[page * system.PAGE_SIZE], 1)
		}
		filler.pages += size
	}
	intrinsics.atomic_store(&filler.ended, 1)
	system.word_wake(&filler.ended)
	system.thread_stop()
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	machine = ctx.handles[system.GRANT_MACHINE]
	start := system_report()
	own, _ := system.budget_read()
	processors := start.processors
	drains_before := drains(processors)
	system.log("shortage: start: ", start.free_pages - start.reserved_pages, " free pages that budgets can pay, ", own.pages, " of them in the budget of this program, ", processors, " processors")

	began := system.nanoseconds()
	threads: [THREAD_COUNT]system.Thread
	for &thread, index in threads {
		thread, _ = system.thread_start(fill, &fillers[index])
	}
	for &filler in fillers {
		for intrinsics.atomic_load(&filler.ended) == 0 {
			system.word_wait(&filler.ended, 0, system.time() + 1000)
		}
	}
	filled := system.nanoseconds() - began
	for thread in threads {
		system.thread_wait(thread)
	}
	// The last pages of the budget: one object that the budget can pay
	// exactly, not used (its pages stay reserved).
	rest: system.Handle
	if remaining, _ := system.budget_read(); remaining.pages != 0 {
		size := remaining.pages
		for size > 0 && op.memory_cost(size) > remaining.pages {
			size -= 1
		}
		if size > 0 {
			rest, _ = system.memory_create(size)
		}
	}
	full := system_report()
	empty, _ := system.budget_read()
	pages, objects: u64
	for filler in fillers {
		pages += filler.pages
		objects += u64(filler.count)
	}
	drains_full := drains(processors)
	// No frame is free that a budget can pay: the difference of the report
	// is exact while other processors take (it is the pages of the budgets).
	payable := full.free_pages - full.reserved_pages
	// A take that can fail fails now, with its error record.
	refusal: errors.Error_Record
	_, refused := system.memory_create(1, error = &refusal)
	system.log("shortage: full: ", pages, " pages written in ", objects, " objects by ", u64(THREAD_COUNT), " threads in ", filled / 1_000_000, " ms; the budget of this program holds ", empty.pages, " pages; the free pages that budgets can pay: ", payable, " (the pages that the root service kept), and the reserved pages: ", full.reserved_pages, "; drains of the stacks: ", drains_full - drains_before, "; a new memory object of 1 page: status ", u64(refused), ", error kind ", u64(refusal.kind), refusal.kind == i64(errors.Kind.Budget) ? " (Budget: the budget cannot pay)" : " (another kind)")

	began = system.nanoseconds()
	for &filler in fillers {
		for object, index in filler.objects[:filler.count] {
			if filler.addresses[index] != nil {
				system.memory_unmap(filler.addresses[index])
			}
			system.close(object)
		}
		filler.count = 0
	}
	if rest != 0 {
		system.close(rest)
	}
	freed := system.nanoseconds() - began
	after := system_report()
	back, _ := system.budget_read()
	// Memory_Unmap does not give back a page table that became empty
	// (a gap of docs/FIRST_MILESTONE.md): the budget pays for them until
	// the program stops.
	tables := own.pages - back.pages
	right := tables < 1024 && drains_full > drains_before && refused == .No_Budget && (refusal.kind == i64(errors.Kind.Budget) || refusal.kind == i64(errors.Kind.Budget_Hidden)) && empty.pages == 0 && payable == full.budget_pages && after.free_pages - after.reserved_pages + tables == start.free_pages - start.reserved_pages && after.budget_pages + after.reserved_pages == after.free_pages
	system.log("shortage: freed in ", freed / 1_000_000, " ms; the budget holds ", back.pages, " pages of ", own.pages, " (", tables, " pages of page tables stay until the program stops); the free pages that budgets can pay: ", after.free_pages - after.reserved_pages, " of ", start.free_pages - start.reserved_pages)
	if right {
		system.log("shortage: ok, the stacks were drained for takes that cannot fail, a new object failed only when its budget could pay no page, and each frame returned")
	} else {
		system.log("shortage: wrong")
	}
	system.call(.Machine_Stop, u64(machine), 0)
	for {}
}
