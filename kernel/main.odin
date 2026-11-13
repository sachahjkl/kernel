// The kernel: the handle table, memory, the scheduler, the rings and the waits, the device grants and the interrupts (docs/ARCHITECTURE.md, "Kernel systems").
package kernel

import info "contract:boot_info"
import module "contract:module"
import op "contract:operation"
import "base:intrinsics"

KERNEL_MARK :: "kernel: ok"
ROOT_NAME :: "root"

@(export, link_name = "entry")
entry :: proc "c" (boot: ^info.Boot_Info) -> ! {
	stage_end(.Boot_Program_Tables)
	serial_start()
	if boot.magic != info.MAGIC {
		log("kernel: the boot record is not valid")
		machine_stop(1)
	}
	boot_record = boot^
	stage_cycles[.Firmware] = boot.cycles_start
	stage_cycles[.Boot_Program_Load] = boot.cycles_loaded
	memory_start(boot)
	stage_end(.Kernel_Memory)
	processor_start()
	stage_end(.Kernel_Processor)
	// The strategy of each run queue, and the lengths in cycles, before
	// another processor reads them (timer_calibrate measured the frequency).
	strategy_start()
	processors_start(boot)
	stage_end(.Kernel_Processors)
	log("kernel: ", u64(processor_count), " processors")
	log("kernel: free memory ", free_frames * PAGE_SIZE >> 20, " MiB")
	log("kernel: framebuffer ", u64(boot.framebuffer.width), "x", u64(boot.framebuffer.height), " at ", Hex(boot.framebuffer.address))
	log(KERNEL_MARK)
	control_take()
	root_start(boot)
	control_free()
	intrinsics.atomic_store(&root_started, true)
	stage_end(.Kernel_Root)
	paging_audit()
	for stage in Stage {
		log_in("boot", .Info, "kernel: boot: ", STAGE_NAMES[stage], ": ", microseconds(stage_cycles[stage] - (stage == .Firmware ? 0 : stage_cycles[Stage(int(stage) - 1)])), " us")
	}
	// The stack of the boot program has no guard pages: the processor
	// continues on its own kernel stack.
	stack_switch(processors[0].stack_top, rawptr(first_run))
}

first_run :: proc "c" () -> ! {
	self_test(boot_record.self_test, &boot_record)
	schedule()
}

// debug_image_pages checks the range of the debug image that the boot
// program gives: on a page, inside the bound, and inside one range of the
// memory of the boot, which the kernel never gives as a free frame. A
// memory object over other memory would let the root service read and
// give pages that the kernel uses.
debug_image_pages :: proc "contextless" (boot: ^info.Boot_Info) -> (pages: u64, accepted: bool) {
	start, size := boot.debug_image, boot.debug_image_size
	if start == 0 || start % PAGE_SIZE != 0 || size == 0 || size > info.DEBUG_IMAGE_LIMIT || start > max(u64) - info.DEBUG_IMAGE_LIMIT - PAGE_SIZE {
		return 0, false
	}
	pages = (size + PAGE_SIZE - 1) / PAGE_SIZE
	end := start + pages * PAGE_SIZE
	for range in info.physical_slice(boot.memory_ranges, boot.memory_range_count, info.Memory_Range) {
		if range.kind != .Boot || range.page_count > (max(u64) - range.start) / PAGE_SIZE {
			continue
		}
		if start >= range.start && end <= range.start + range.page_count * PAGE_SIZE {
			return pages, true
		}
	}
	return 0, false
}

// root_start builds the first program from the module "root" of the boot
// image. Every other program is built by a program, with kernel operations.
root_start :: proc "contextless" (boot: ^info.Boot_Info) {
	fail :: proc "contextless" (text: string) -> ! {
		log("kernel: cannot start the root service: ", text)
		machine_stop(1)
	}
	image := info.physical_slice(boot.boot_image, boot.boot_image_size, u8)
	if len(image) < size_of(info.Image_Header) || (^info.Image_Header)(raw_data(image)).magic != info.IMAGE_MAGIC {
		fail("the boot image is not valid")
	}
	file: []u8
	hash: [32]u8 // As the boot image names it.
	entries := ([^]info.Image_Entry)(raw_data(image[size_of(info.Image_Header):]))[:(^info.Image_Header)(raw_data(image)).count]
	for &item in entries {
		name := ROOT_NAME
		if string(item.name[:len(name)]) == name && item.name[len(name)] == 0 {
			file = image[item.offset:][:item.size]
			hash = item.hash
		}
	}
	if file == nil || module.validate(file) != .None {
		fail("the boot image has no valid module \"root\"")
	}
	head, _ := module.header(file)
	name := ROOT_NAME
	// The time page is memory of the kernel: no budget has it.
	if !time_page_create() {
		fail("no memory for the time page")
	}
	// The one budget that comes from nothing: all the free memory, all the slots.
	ROOT_BUDGET :: 1
	budgets[ROOT_BUDGET] = {
		live = true,
		amounts = {pages = free_frames, programs = PROGRAM_CAPACITY - 1, threads = THREAD_TABLE_CAPACITY - 1, processor = u64(processor_count) * 1_000_000, log_records = op.LOG_RECORD_CAPACITY},
	}
	index, _ := program_create(ROOT_BUDGET, transmute([]u8)name)
	// The kernel writes the module and the context through the direct map:
	// these two are contiguous. The stack has its pages on first use.
	code, _ := region_create(ROOT_BUDGET, head.memory_size / PAGE_SIZE, contiguous = true)
	stack, _ := region_create(ROOT_BUDGET, op.STACK_PAGES)
	ctx, _ := region_create(ROOT_BUDGET, 1, contiguous = true)
	if index == 0 || code == 0 || stack == 0 || ctx == 0 {
		fail("no memory")
	}
	program := &programs[index]
	taken := program_lock(index)
	defer program_unlock(index, taken)
	program_module(program, {base = op.PROGRAM_BASE, size = head.memory_size, hash = hash})
	memory := info.physical_slice(regions[code].physical, head.memory_size, u8)
	module.copy_segments(file, memory)
	if module.rebase(file, memory, op.PROGRAM_BASE) != .None || module.count(file, .Imports) > 1 {
		fail("the module cannot be loaded")
	}
	for segment_index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, segment_index, module.Segment)
		flags: op.Map_Flags
		if .Write in segment.flags && .Read_Only_After_Load not_in segment.flags {
			flags += {.Write}
		}
		if .Execute in segment.flags {
			flags += {.Execute}
		}
		if _, status := map_region(program, code, op.PROGRAM_BASE + segment.memory_offset, flags, segment.memory_offset / PAGE_SIZE, segment.memory_size / PAGE_SIZE); status != .Ok {
			fail("a segment cannot be mapped")
		}
	}
	_, stack_status := map_region(program, stack, op.STACK_TOP - op.STACK_PAGES * PAGE_SIZE, {.Write}, 0, 0)
	_, context_status := map_region(program, ctx, op.CONTEXT_ADDRESS, {.Write}, 0, 0)
	start, has_entry := module.export_address(file, op.PROGRAM_BASE, head.entry_export)
	if stack_status != .Ok || context_status != .Ok || !has_entry {
		fail("the module has no entry")
	}

	// The root service receives every handle that exists at boot.
	record := direct(regions[ctx].physical, op.Context)
	record.handles[op.CONTEXT_BUDGET] = handle_insert(program, {kind = .Budget, rights = RIGHTS_BUDGET, object = ROOT_BUDGET})
	record.handles[op.CONTEXT_LOG] = handle_insert(program, {kind = .Log, rights = RIGHTS_LOG})
	if log_head != nil {
		record.handles[op.ROOT_LOG_RECORDS] = handle_insert(program, {kind = .Memory, rights = {.Give, .Read}, object = region_device(physical_of(log_head), op.LOG_PAGES)})
	}
	record.handles[op.ROOT_MACHINE] = handle_insert(program, {kind = .Machine, rights = RIGHTS_MACHINE})
	framebuffer := boot.framebuffer
	if framebuffer.format != .None {
		pages := (u64(framebuffer.pixels_per_line) * u64(framebuffer.height) * 4 + PAGE_SIZE - 1) / PAGE_SIZE
		record.handles[op.ROOT_FRAMEBUFFER] = handle_insert(program, {kind = .Memory, rights = {.Give, .Read, .Write}, object = region_device(framebuffer.address, pages)})
		record.values[op.ROOT_VALUE_WIDTH] = u64(framebuffer.width)
		record.values[op.ROOT_VALUE_HEIGHT] = u64(framebuffer.height)
		record.values[op.ROOT_VALUE_PIXELS_PER_LINE] = u64(framebuffer.pixels_per_line)
		record.values[op.ROOT_VALUE_FORMAT] = u64(framebuffer.format)
	}
	record.handles[op.ROOT_BOOT_IMAGE] = handle_insert(program, {kind = .Memory, rights = {.Give, .Read}, object = region_device(boot.boot_image, (boot.boot_image_size + PAGE_SIZE - 1) / PAGE_SIZE)})
	record.values[op.ROOT_VALUE_BOOT_IMAGE_SIZE] = boot.boot_image_size
	// The debug image: the kernel gives its pages and reads none of them
	// (docs/MODULE_CONTRACT.md, "Debug information").
	if boot.debug_image_size != 0 {
		if pages, accepted := debug_image_pages(boot); accepted {
			record.handles[op.ROOT_DEBUG_IMAGE] = handle_insert(program, {kind = .Memory, rights = {.Give, .Read}, object = region_device(boot.debug_image, pages)})
			record.values[op.ROOT_VALUE_DEBUG_IMAGE_SIZE] = boot.debug_image_size
		} else {
			log("kernel: the debug image of the boot program is refused: its range is not on a page, is over its bound, or is not memory of the boot; a stop report names no procedure")
		}
	}

	if _, status := thread_create(index, ROOT_BUDGET, u64(start), op.STACK_TOP, op.CONTEXT_ADDRESS); status != .Ok {
		fail("no memory for the first thread")
	}
	program.state = .Ready
}
