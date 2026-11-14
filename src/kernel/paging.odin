package kernel

import info "contract:boot_info"
import module "contract:module"
import "base:intrinsics"
import op "contract:operation"

// Paging as a tool of the kernel on itself: the kernel protects its own
// pages as it protects the pages of a program, so that a fault of the
// kernel cannot write its code or execute its data.
//
// The kernel half of the addresses has three parts:
//   the direct map: all physical memory, never executable. The pages of
//     the code and of the constants of the kernel are read-only there too;
//   the kernel module: each segment with its own protection;
//   the kernel stacks: each one between two guard pages with no memory.
// No page is both writable and executable. The kernel reads its own tables
// to prove it (mappings_report), at boot and for a program that asks.

PAGE_LARGE :: u64(1) << 7
// The bits of the error code of a page fault.
FAULT_PRESENT :: 1 << 0 // The entry was present: the access is not permitted.
FAULT_WRITE :: 1 << 1
FAULT_RESERVED_BIT :: 1 << 3 // An entry of a page table has a reserved bit set.
FAULT_EXECUTE :: 1 << 4
LARGE_PAGE_SIZE :: 2 << 20
DIRECT_MAP_INDEX :: (u64(info.DIRECT_MAP_BASE) >> 39) & 511

foreign _ {
	// 1: the processors refuse the memory of programs to the kernel (SMAP).
	// interrupt_common reads it too. user_copy is in instructions.odin.
	user_access_guard: u8
	stack_switch :: proc "c" (top: u64, entry: rawptr) -> ! ---
}

kernel_no_execute: bool // The processors refuse to execute the memory of programs in the kernel.

// kernel_entry gives the entry of the last level table for an address of
// the kernel half. With create, it makes the tables that are missing: only
// at boot, on one processor. nil: no memory, or no table.
kernel_entry :: proc "contextless" (address: u64, create := true) -> ^u64 {
	current := kernel_table
	for level := uint(3); level >= 1; level -= 1 {
		entry := &direct(current, [512]u64)[address >> (12 + 9 * level) & 511]
		if entry^ & PAGE_PRESENT == 0 {
			if !create {
				return nil
			}
			child := frames_allocate(1)
			if child == 0 {
				return nil
			}
			entry^ = child | PAGE_PRESENT | PAGE_WRITE
		}
		current = entry^ & PAGE_ADDRESS
	}
	return &direct(current, [512]u64)[address >> 12 & 511]
}

// paging_start gives the kernel half its protection. The boot program
// built the tables; memory_start copied their kernel half.
paging_start :: proc "contextless" (boot: ^info.Boot_Info) {
	top := direct(kernel_table, [512]u64)
	// The direct map is data: no address of it is executable.
	top[DIRECT_MAP_INDEX] |= PAGE_NO_EXECUTE

	// The direct map shows the kernel module a second time. The pages that
	// the kernel cannot write at its own addresses become read-only there
	// too. The direct map has large pages: the ones of the kernel module
	// become tables of small pages.
	file := info.physical_slice(boot.kernel_file, boot.kernel_file_size, u8)
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		if .Write in segment.flags && .Read_Only_After_Load not_in segment.flags {
			continue
		}
		for offset := segment.memory_offset; offset < segment.memory_offset + segment.memory_size; offset += PAGE_SIZE {
			physical := boot.kernel_address + offset
			level3 := direct(top[DIRECT_MAP_INDEX] & PAGE_ADDRESS, [512]u64)
			large := &direct(level3[physical >> 30 & 511] & PAGE_ADDRESS, [512]u64)[physical >> 21 & 511]
			if large^ & PAGE_LARGE != 0 {
				table := frames_allocate(1)
				if table == 0 {
					log("kernel: no memory for the page tables of the kernel")
					machine_stop(1)
				}
				first := large^ & PAGE_ADDRESS
				for &entry, page in direct(table, [512]u64) {
					entry = (first + u64(page) * PAGE_SIZE) | PAGE_PRESENT | PAGE_WRITE
				}
				large^ = table | PAGE_PRESENT | PAGE_WRITE
			}
			direct(large^ & PAGE_ADDRESS, [512]u64)[physical >> 12 & 511] &~= PAGE_WRITE
		}
	}

	// The table of the stacks exists before the first program: each
	// address space copies the top entries of the kernel half.
	if kernel_entry(op.KERNEL_STACK_BASE) == nil {
		log("kernel: no memory for the page tables of the kernel")
		machine_stop(1)
	}
	control_register_3_write(kernel_table)
}

// The tops of the stacks of one processor.
Kernel_Stack_Tops :: struct {
	kernel:       u64,
	double_fault: u64,
	// The interrupt stacks of the debug exception, the non-maskable
	// interrupt and the machine check, in that order.
	interrupts:   [op.KERNEL_INTERRUPT_STACK_COUNT]u64,
}

// stacks_create gives a processor its kernel stack, its stack of the
// double fault and its three other interrupt stacks, in the slot of the
// processor. The pages around them have no memory: a stack that is full
// stops the machine with a report, and never writes on other memory.
stacks_create :: proc "contextless" (index: u32) -> (tops: Kernel_Stack_Tops, ok: bool) {
	slot := u64(op.KERNEL_STACK_BASE) + u64(index) * op.KERNEL_STACK_SLOT_PAGES * PAGE_SIZE
	place :: proc "contextless" (address: u64, pages: u64) -> bool {
		physical := frames_allocate(pages)
		if physical == 0 {
			return false
		}
		for page in 0 ..< pages {
			entry := kernel_entry(address + page * PAGE_SIZE)
			if entry == nil {
				return false
			}
			entry^ = (physical + page * PAGE_SIZE) | PAGE_PRESENT | PAGE_WRITE | PAGE_NO_EXECUTE
		}
		return true
	}
	stack := slot + PAGE_SIZE
	fault := stack + (op.KERNEL_STACK_PAGES + 1) * PAGE_SIZE
	if !place(stack, op.KERNEL_STACK_PAGES) || !place(fault, op.KERNEL_FAULT_STACK_PAGES) {
		stacks_free(index)
		return {}, false
	}
	tops.kernel = stack + op.KERNEL_STACK_PAGES * PAGE_SIZE
	tops.double_fault = fault + op.KERNEL_FAULT_STACK_PAGES * PAGE_SIZE
	for &top, n in tops.interrupts {
		first := slot + op.kernel_interrupt_stack_first_page(u64(n)) * PAGE_SIZE
		if !place(first, op.KERNEL_INTERRUPT_STACK_PAGES) {
			stacks_free(index)
			return {}, false
		}
		top = first + op.KERNEL_INTERRUPT_STACK_PAGES * PAGE_SIZE
	}
	return tops, true
}

// stacks_free frees the stacks of a processor that did not start. No
// processor used them.
stacks_free :: proc "contextless" (index: u32) {
	slot := u64(op.KERNEL_STACK_BASE) + u64(index) * op.KERNEL_STACK_SLOT_PAGES * PAGE_SIZE
	for page in 0 ..< u64(op.KERNEL_STACK_SLOT_PAGES) {
		entry := kernel_entry(slot + page * PAGE_SIZE, false) // A free makes no table.
		if entry != nil && entry^ & PAGE_PRESENT != 0 {
			frames_free(entry^ & PAGE_ADDRESS, 1)
			entry^ = 0
			page_flush(slot + page * PAGE_SIZE)
		}
	}
}

// stack_guard says if an address is in a guard page of a kernel stack,
// and of which processor.
stack_guard :: proc "contextless" (address: u64) -> (processor: u64, guard: bool) {
	if address < op.KERNEL_STACK_BASE || address >= op.KERNEL_STACK_BASE + u64(PROCESSOR_CAPACITY) * op.KERNEL_STACK_SLOT_PAGES * PAGE_SIZE {
		return 0, false
	}
	page := (address - op.KERNEL_STACK_BASE) / PAGE_SIZE
	// A report reads the tables: it does not make one.
	entry := kernel_entry(address, false)
	return page / op.KERNEL_STACK_SLOT_PAGES, entry != nil && entry^ & PAGE_PRESENT == 0
}

// fault_reason says what a page fault or a double fault of the kernel means.
fault_reason :: proc "contextless" (frame: ^Frame, address: u64) -> string {
	if _, guard := stack_guard(address); guard && (frame.vector == 8 || frame.vector == VECTOR_PAGE_FAULT) {
		return "the kernel stack of the processor is full"
	}
	if frame.vector != VECTOR_PAGE_FAULT {
		return "no reason is known"
	}
	switch {
	case frame.error & FAULT_PRESENT == 0:
		return "the address has no page"
	case address < USER_END && frame.error & FAULT_EXECUTE != 0:
		return "the kernel executed memory of a program"
	case address < USER_END:
		return "the kernel used memory of a program outside a copy"
	case frame.error & FAULT_EXECUTE != 0:
		return "execute of a page that is not code"
	case frame.error & FAULT_WRITE != 0:
		return "write to a read-only page"
	}
	return "no reason is known"
}

// mappings_report reads one half of a page table: entries [first, last) of
// the top level table.
mappings_report :: proc "contextless" (report: ^op.Mapping_Report, table: u64, first, last: u64) {
	Flags :: bit_set[op.Mapping_Flag;u64]
	add :: proc "contextless" (report: ^op.Mapping_Report, start, pages: u64, flags: Flags) {
		report.pages += pages
		if .Write in flags {
			report.write_pages += pages
		}
		if .Execute in flags {
			report.execute_pages += pages
		}
		if .Write in flags && .Execute in flags {
			report.write_execute_pages += pages
		}
		if report.run_count != 0 && report.run_count <= op.MAPPING_RUN_CAPACITY {
			run := &report.runs[report.run_count - 1]
			if run.flags == flags && run.start + run.page_count * PAGE_SIZE == start {
				run.page_count += pages
				return
			}
		}
		if report.run_count < op.MAPPING_RUN_CAPACITY {
			report.runs[report.run_count] = {start = start, page_count = pages, flags = flags}
		}
		report.run_count += 1
	}
	// A page has a right when each level of the table gives it.
	walk :: proc "contextless" (report: ^op.Mapping_Report, table: u64, level: uint, base: u64, first, last: u64, inherited: Flags) {
		for index in first ..< last {
			entry := direct(table, [512]u64)[index]
			if entry & PAGE_PRESENT == 0 {
				continue
			}
			address := base | index << (12 + 9 * level)
			if level == 3 && index >= 256 {
				address |= 0xFFFF_0000_0000_0000
			}
			flags := inherited
			if entry & PAGE_WRITE == 0 {
				flags -= {.Write}
			}
			if entry & PAGE_NO_EXECUTE != 0 {
				flags -= {.Execute}
			}
			if entry & PAGE_USER == 0 {
				flags -= {.Program}
			}
			switch {
			case level == 0:
				add(report, address, 1, flags)
			case entry & PAGE_LARGE != 0:
				add(report, address, 1 << (9 * level), flags + {.Large})
			case:
				walk(report, entry & PAGE_ADDRESS, level - 1, address, 0, 512, flags)
			}
		}
	}
	report^ = {}
	walk(report, table, 3, 0, first, last, {.Write, .Execute, .Program})
	report.kernel_guard = u64(user_access_guard)
	report.kernel_no_execute = u64(kernel_no_execute)
	if first < 256 {
		return
	}
	// The guard pages: each page of the slot of a processor that is not a
	// page of one of its stacks.
	report.guards_expected = u64(processor_count) * (op.KERNEL_STACK_SLOT_PAGES - op.KERNEL_STACK_SLOT_STACK_PAGES)
	for index in 0 ..< u64(processor_count) {
		slot := u64(op.KERNEL_STACK_BASE) + index * op.KERNEL_STACK_SLOT_PAGES * PAGE_SIZE
		for page in 0 ..< u64(op.KERNEL_STACK_SLOT_PAGES) {
			if _, guard := stack_guard(slot + page * PAGE_SIZE); guard {
				report.guard_pages += 1
			}
		}
	}
}

audit: op.Mapping_Report

// paging_audit reads the kernel half and stops the machine if the half
// does not keep its rules.
paging_audit :: proc "contextless" () {
	mappings_report(&audit, kernel_table, 256, 512)
	log_in("paging", .Info, "kernel: paging: ", Size{audit.pages, .Pages}, " in ", audit.run_count, " runs, ", Size{audit.execute_pages, .Pages}, " of code, ", Size{audit.write_execute_pages, .Pages}, " write and execute, ", audit.guard_pages, " guard pages of ", audit.guards_expected)
	log_in("paging", .Info, "kernel: paging: the kernel ", kernel_no_execute ? "cannot" : "can", " execute memory of programs, and ", user_access_guard != 0 ? "cannot" : "can", " use it outside a copy")
	if audit.write_execute_pages != 0 || audit.guard_pages != audit.guards_expected {
		log("kernel: the page tables of the kernel do not keep their rules")
		machine_stop(1)
	}
}

test_code := [16]u8{0 = 0xC3} // The instruction "return", as data.

// self_test does one thing that the page tables must refuse
// (info.Self_Test). The machine stops with the report of the fault.
self_test :: proc "contextless" (test: info.Self_Test, boot: ^info.Boot_Info) {
	overflow :: proc "contextless" (depth: u64) -> u64 {
		block: [512]u8
		intrinsics.volatile_store(&block[depth % 512], u8(depth))
		return overflow(depth + 1) + u64(intrinsics.volatile_load(&block[0]))
	}
	code := u64(uintptr(rawptr(paging_audit)))
	switch test {
	case .None:
		return
	case .Stack_Overflow:
		log("kernel: self test: use more than the kernel stack")
		overflow(0)
	case .Write_Code:
		log("kernel: self test: write to the code of the kernel")
		intrinsics.volatile_store((^u8)(uintptr(code)), 0xC3)
	case .Write_Code_View:
		log("kernel: self test: write to the code of the kernel through the direct map")
		intrinsics.volatile_store(direct(boot.kernel_address + code - u64(info.KERNEL_BASE), u8), 0xC3)
	case .Execute_Data:
		log("kernel: self test: execute the data of the kernel")
		(cast(proc "c" ())rawptr(&test_code))()
	case .Read_Program:
		log("kernel: self test: read the memory of a program outside a copy")
		control_register_3_write(programs[1].table)
		_ = intrinsics.volatile_load((^u8)(uintptr(op.PROGRAM_BASE)))
	case .Execute_Program:
		log("kernel: self test: execute the code of a program")
		control_register_3_write(programs[1].table)
		(cast(proc "c" ())rawptr(uintptr(threads[1].frame.rip)))()
	}
	log("kernel: self test: the processor did not refuse")
	machine_stop(1)
}
