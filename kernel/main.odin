// The kernel (docs/ARCHITECTURE.md, systems K1 to K5).
package kernel

import info "../boot_info"
import module "../module"
import op "operation"

KERNEL_MARK :: "kernel: ok"
ROOT_NAME :: "root"

@(export, link_name = "entry")
entry :: proc "c" (boot: ^info.Boot_Info) -> ! {
	serial_start()
	if boot.magic != info.MAGIC {
		log("kernel: the boot record is not valid")
		machine_stop(1)
	}
	processor_start()
	memory_start(boot)
	log("kernel: free memory ", free_frames * PAGE_SIZE >> 20, " MiB")
	log("kernel: framebuffer ", u64(boot.framebuffer.width), "x", u64(boot.framebuffer.height), " at ", Hex(boot.framebuffer.address))
	log(KERNEL_MARK)
	root_start(boot)
	schedule()
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
	entries := ([^]info.Image_Entry)(raw_data(image[size_of(info.Image_Header):]))[:(^info.Image_Header)(raw_data(image)).count]
	for &item in entries {
		name := ROOT_NAME
		if string(item.name[:len(name)]) == name && item.name[len(name)] == 0 {
			file = image[item.offset:][:item.size]
		}
	}
	if file == nil || module.validate(file) != .None {
		fail("the boot image has no valid module \"root\"")
	}
	head, _ := module.header(file)
	name := ROOT_NAME
	index := program_create(transmute([]u8)name)
	code := region_create(head.memory_size / PAGE_SIZE)
	stack := region_create(op.STACK_PAGES)
	ctx := region_create(1)
	if index == 0 || code == 0 || stack == 0 || ctx == 0 {
		fail("no memory")
	}
	program := &programs[index]
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
	record.handles[op.ROOT_MACHINE] = handle_insert(program, {kind = .Machine})
	framebuffer := boot.framebuffer
	if framebuffer.format != .None {
		pages := (u64(framebuffer.pixels_per_line) * u64(framebuffer.height) * 4 + PAGE_SIZE - 1) / PAGE_SIZE
		record.handles[op.ROOT_FRAMEBUFFER] = handle_insert(program, {kind = .Memory, object = region_device(framebuffer.address, pages)})
		record.values[op.ROOT_VALUE_WIDTH] = u64(framebuffer.width)
		record.values[op.ROOT_VALUE_HEIGHT] = u64(framebuffer.height)
		record.values[op.ROOT_VALUE_PIXELS_PER_LINE] = u64(framebuffer.pixels_per_line)
		record.values[op.ROOT_VALUE_FORMAT] = u64(framebuffer.format)
	}
	record.handles[op.ROOT_BOOT_IMAGE] = handle_insert(program, {kind = .Memory, object = region_device(boot.boot_image, (boot.boot_image_size + PAGE_SIZE - 1) / PAGE_SIZE)})
	record.values[op.ROOT_VALUE_BOOT_IMAGE_SIZE] = boot.boot_image_size

	if _, status := thread_create(index, u64(start), op.STACK_TOP, op.CONTEXT_ADDRESS); status != .Ok {
		fail("no memory for the first thread")
	}
	program.state = .Ready
}
