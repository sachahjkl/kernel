package kernel

import info "contract:boot_info"
import op "contract:operation"
import "base:intrinsics"

// The record of how the machine started (op.Boot_Report). The kernel reads
// the cycle counter of the processor at the end of each stage. The counter
// is 0 when the machine starts, so the first stage is the firmware.

Stage :: enum {
	Firmware,
	Boot_Program_Load,
	Boot_Program_Tables,
	Kernel_Memory,
	Kernel_Processor,
	Kernel_Processors,
	Kernel_Root,
}

@(rodata)
STAGE_NAMES := [Stage]string {
	.Firmware            = "firmware",
	.Boot_Program_Load   = "boot program: load the kernel, the boot image",
	.Boot_Program_Tables = "boot program: page tables, memory map, jump",
	.Kernel_Memory       = "kernel: page frames, kernel page table",
	.Kernel_Processor    = "kernel: first processor, timer",
	.Kernel_Processors   = "kernel: other processors",
	.Kernel_Root         = "kernel: root service",
}

stage_cycles: [Stage]u64 // The cycle counter at the end of each stage.
cycle_frequency: u64
boot_record: info.Boot_Info

cycles_now :: #force_inline proc "contextless" () -> u64 {
	return u64(intrinsics.read_cycle_counter())
}

// milliseconds_now gives the milliseconds since the time 0, from the cycle
// counter. The seconds and the rest are divided apart: no product overflows.
milliseconds_now :: proc "contextless" () -> u64 {
	if cycle_frequency == 0 {
		return 0
	}
	cycles := cycles_now() - cycle_start
	return cycles / cycle_frequency * 1000 + cycles % cycle_frequency * 1000 / cycle_frequency
}

// microseconds gives the time of a number of cycles. It is 0 before the
// kernel measured the cycle counter.
microseconds :: proc "contextless" (cycles: u64) -> u64 {
	per_microsecond := cycle_frequency / 1_000_000
	return per_microsecond == 0 ? 0 : cycles / per_microsecond
}

stage_end :: proc "contextless" (stage: Stage) {
	stage_cycles[stage] = cycles_now()
}

boot_report :: proc "contextless" (report: ^op.Boot_Report) {
	boot := &boot_record
	report^ = {
		time                = microseconds(cycles_now()),
		stage_count         = len(Stage),
		firmware_vendor     = boot.firmware_vendor,
		firmware_revision   = boot.firmware_revision,
		framebuffer_address = boot.framebuffer.address,
		framebuffer_width   = u64(boot.framebuffer.width),
		framebuffer_height  = u64(boot.framebuffer.height),
		framebuffer_line    = u64(boot.framebuffer.pixels_per_line),
		framebuffer_format  = u64(boot.framebuffer.format),
		kernel_size         = boot.kernel_size,
		kernel_file_size    = boot.kernel_file_size,
		boot_image_size     = boot.boot_image_size,
		direct_map_size     = boot.direct_map_size,
		acpi_root           = boot.acpi_root,
		cycle_frequency     = cycle_frequency,
		timer_frequency     = u64(timer_count) * 16 * TICKS_PER_SECOND,
	}
	start: u64
	for stage in Stage {
		item := &report.stages[stage]
		name := STAGE_NAMES[stage]
		intrinsics.mem_copy_non_overlapping(&item.name, raw_data(name), min(len(name), len(item.name) - 1))
		item.start = microseconds(start)
		item.duration = microseconds(stage_cycles[stage] - start)
		start = stage_cycles[stage]
	}
	for range in info.physical_slice(boot.memory_ranges, boot.memory_range_count, info.Memory_Range) {
		op.boot_range_add(report, range.start, range.page_count, u64(range.kind))
	}
}

// The reports of a developer tool (docs/TOOLS.md): what one program has, for
// a holder of the machine with the right Inspect. They give counts, places
// and states, never a byte of the memory of the program (property 20).

// program_mappings_report writes the mappings of program slot `index`, in
// the order of their addresses. The caller holds the control lock; this
// procedure takes the program lock of the program. The present pages are
// the count that each mapping keeps (Mapping.present_page_count): one read
// for each mapping, no walk of the page table.
program_mappings_report :: proc "contextless" (report: ^op.Program_Mapping_Report, index: u32) {
	report^ = {}
	if index == 0 || index >= PROGRAM_CAPACITY {
		return
	}
	about := &programs[index]
	taken := program_lock(index)
	defer program_unlock(index, taken)
	if about.state == .None {
		return
	}
	// The serial also for a stopped program, which has no page table and no
	// mapping now.
	report.program_serial = u64(about.serial)
	if about.table == 0 {
		return
	}
	for &mapping in about.mappings {
		if mapping.page_count == 0 || report.count == op.MAPPING_REPORT_CAPACITY {
			continue
		}
		item := op.Program_Mapping {
			address    = mapping.address,
			page_count = mapping.page_count,
			first      = mapping.first,
			present    = mapping.present_page_count,
		}
		// The protection of the mapping now; a part can have another one
		// (Protected: the slots of its pages say it).
		if mapping.bits & PAGE_PRESENT == 0 {
			item.flags += {.No_Access}
		} else {
			if mapping.bits & PAGE_WRITE != 0 {
				item.flags += {.Write}
			}
			if mapping.bits & PAGE_NO_EXECUTE == 0 {
				item.flags += {.Execute}
			}
		}
		if mapping.large {
			item.flags += {.Large}
		}
		if mapping.protected {
			item.flags += {.Protected}
		}
		if mapping.address >= op.THREAD_AREA_BASE {
			item.flags += {.Thread_Area}
		}
		if mapping.region < REGION_CAPACITY {
			region := &regions[mapping.region]
			item.region_pages = region.page_count
			item.region_serial = region.serial
			item.references = intrinsics.atomic_load(&region.references)
			// Under the program lock: the committed pages change under the
			// region lock and the frame lock; one word, read whole.
			item.committed = region.uncommitted ? intrinsics.volatile_load(&region.committed) : region.page_count
			if region.uncommitted {
				item.flags += {.Uncommitted}
			}
			if region.uncached {
				item.flags += {.Uncached}
			}
			if region.device {
				item.flags += {.Device}
			}
			if region.contiguous {
				item.flags += {.Contiguous}
			}
			if item.references > 1 {
				item.flags += {.Shared}
			}
		}
		// In the order of the addresses.
		place := report.count
		for place > 0 && report.mappings[place - 1].address > item.address {
			report.mappings[place] = report.mappings[place - 1]
			place -= 1
		}
		report.mappings[place] = item
		report.count += 1
	}
}

// stop_report_for_inspect writes the stop report of program slot `index`
// for a holder of the machine with Inspect (op.Inspect_Kind.Stop): only the
// frames that a module record of the program holds, and the address of the
// fault only in the first page or in such a record. The other values can be
// words of the memory of the program. The caller holds the control lock.
stop_report_for_inspect :: proc "contextless" (report: ^op.Stop_Report, index: u32) {
	report^ = {}
	if index == 0 || index >= PROGRAM_CAPACITY {
		return
	}
	about := &programs[index]
	taken := program_lock(index)
	defer program_unlock(index, taken)
	if about.state == .None {
		return // A free slot keeps the stop of its old program: not given.
	}
	report^ = about.stop
	report.program_serial = u64(about.serial)
	in_module :: proc "contextless" (about: ^Program, address: u64) -> bool {
		for record in about.modules {
			if record.size != 0 && address >= record.base && address - record.base < record.size {
				return true
			}
		}
		return false
	}
	if report.address >= PAGE_SIZE && !in_module(about, report.address) {
		report.address = 0
		report.hidden_value_count += 1
	}
	if report.instruction != 0 && !in_module(about, report.instruction) {
		report.instruction = 0
		report.hidden_value_count += 1
	}
	for &frame in report.frames[:min(report.frame_count, op.STOP_FRAME_CAPACITY)] {
		if frame.base == 0 || !in_module(about, frame.address) {
			if frame.address != 0 {
				report.hidden_value_count += 1
			}
			frame = {}
		}
	}
}

// threads_report writes the threads of program slot `index`. The caller
// holds the control lock: no thread of the program starts or ends. The
// fields of the scheduler are read with no run lock, each one whole.
threads_report :: proc "contextless" (report: ^op.Thread_Table_Report, index: u32) {
	report^ = {}
	if index == 0 || index >= PROGRAM_CAPACITY || programs[index].state == .None {
		return
	}
	report.program_serial = u64(programs[index].serial)
	for &thread in threads[1:] {
		state := intrinsics.atomic_load(&thread.state)
		if state == .None || thread.program != index || report.count == op.THREAD_REPORT_CAPACITY {
			continue
		}
		report.threads[report.count] = {
			number           = thread.number,
			state            = state,
			processor        = intrinsics.atomic_load(&thread.processor),
			home             = intrinsics.atomic_load(&thread.home),
			weight           = thread.weight,
			request          = thread.request,
			words            = intrinsics.atomic_load(&thread.word_count),
			queued           = u32(intrinsics.atomic_load(&thread.queued)),
			virtual          = intrinsics.atomic_load(&thread.virtual),
			virtual_deadline = intrinsics.atomic_load(&thread.virtual_deadline),
			lag              = intrinsics.atomic_load(&thread.lag),
			run_time         = intrinsics.atomic_load(&thread.run_time),
			deadline         = intrinsics.atomic_load(&thread.deadline),
		}
		report.count += 1
	}
}

// pages_report writes which of 64 pages of the program that asks have a
// frame, from its page table: it gives no frame to a page. The caller holds
// the program lock of that program (execute_locked), and checked the
// address: aligned, and its 64 pages in the user half.
pages_report :: proc "contextless" (report: ^op.Page_Report, about: ^Program) {
	report.present, report.mapped = 0, 0
	if about.state == .None || about.table == 0 {
		return
	}
	for page in u64(0) ..< op.PAGE_REPORT_CAPACITY {
		address := report.address + page * PAGE_SIZE
		for &mapping in about.mappings {
			if mapping.page_count != 0 && address >= mapping.address && address - mapping.address < mapping.page_count * PAGE_SIZE {
				report.mapped |= 1 << page
				if entry := page_entry(about.table, address, false); entry != nil && entry^ & PAGE_PRESENT != 0 {
					report.present |= 1 << page
				}
				break
			}
		}
	}
}
