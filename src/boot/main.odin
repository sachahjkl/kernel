// The boot program: a UEFI program (docs/PROPERTIES.md, "Trusted boot").
//
// It contains the kernel module, the boot image and the public key of the
// signing key. It does this:
//   1. reads the framebuffer of the firmware;
//   2. verifies the system description and the hash of the kernel and of
//      each file of the boot image, and asks the firmware to measure the
//      description into the TPM (trust.odin);
//   3. loads the kernel module with the loader of package module;
//   4. builds page tables: all physical memory at DIRECT_MAP_BASE, the kernel
//      at KERNEL_BASE, and the same physical memory at its own addresses for
//      the moment of the jump;
//   5. reads the memory map and leaves the firmware services;
//   6. starts the entry of the kernel with a Boot_Info record.
package boot

import info "modus:contract/boot_info"
import "modus:support/bootscreen"
import "modus:support/graphics"
import op "modus:contract/operation"
import module "modus:contract/module"
import "base:intrinsics"

kernel_file := #load(#config(KERNEL_MODULE, "../../build/modules/kernel.module"))
// The tool can give another boot image, for the test of a start that fails.
boot_image := #load(#config(BOOT_IMAGE, "../../build/boot.image"))
display_data: bootscreen.Data

foreign _ {
	boot_jump :: proc "win64" (page_table: u64, entry: u64, boot: u64, stack: u64) -> ! ---
}

PAGE_SIZE :: info.PAGE_SIZE
PAGE_PRESENT :: u64(1) << 0
PAGE_WRITE :: u64(1) << 1
PAGE_LARGE :: u64(1) << 7
PAGE_NO_EXECUTE :: u64(1) << 63
LARGE_PAGE_SIZE :: 2 << 20
TABLE_SPAN :: 1 << 30 // The memory that one table of large pages maps.
MINIMUM_DIRECT_MAP :: 4 << 30 // Device memory, such as the framebuffer, is below this.
MEMORY_RANGE_CAPACITY :: 1024
FIRMWARE_MAP_PAGES :: 16

PREFERRED_WIDTH :: 1024
PREFERRED_HEIGHT :: 768

system: ^Efi_System_Table
image_handle: rawptr

@(export, link_name = "efi_main")
efi_main :: proc "win64" (image: rawptr, system_table: ^Efi_System_Table) -> Efi_Status {
	cycles_start := u64(intrinsics.read_cycle_counter())
	system = system_table
	image_handle = image
	services := system.boot_services
	print("boot program: started\r\n")

	boot := (^info.Boot_Info)(allocate(1))
	boot.magic = info.MAGIC
	boot.cycles_start = cycles_start
	boot.self_test = info.Self_Test(#config(SELF_TEST, 0))
	boot.framebuffer = framebuffer()
	for &character, index in boot.firmware_vendor[:len(boot.firmware_vendor) - 1] {
		unit := system.firmware_vendor[index]
		if unit == 0 {
			break
		}
		character = unit < 0x7F ? u8(unit) : '?'
	}
	boot.firmware_revision = u64(system.firmware_revision)
	// The kernel reads the list of the processors in the ACPI tables.
	for entry in system.tables[:system.table_count] {
		if entry.guid == EFI_ACPI_GUID {
			boot.acpi_root = u64(uintptr(entry.table))
		}
	}

	// The boot image goes to its own pages: the kernel gives it to the root
	// service as memory. The checks read this copy, the one that the kernel
	// receives.
	image_copy := allocate((u64(len(boot_image)) + PAGE_SIZE - 1) / PAGE_SIZE)
	intrinsics.mem_copy_non_overlapping(image_copy, raw_data(boot_image), len(boot_image))
	image_bytes := ([^]u8)(image_copy)[:len(boot_image)]
	description := trust_check(boot, image_bytes)
	measure(boot, description)

	// The kernel module.
	if module.validate(kernel_file) != .None {
		stop("boot program: the kernel module is not valid\r\n")
	}
	head, _ := module.header(kernel_file)
	kernel := ([^]u8)(allocate(head.memory_size / PAGE_SIZE))[:head.memory_size]
	module.copy_segments(kernel_file, kernel)
	if module.rebase(kernel_file, kernel, info.KERNEL_BASE) != .None || module.count(kernel_file, .Imports) > 1 {
		stop("boot program: the kernel module cannot be loaded\r\n")
	}
	entry, has_entry := module.export_address(kernel_file, info.KERNEL_BASE, head.entry_export)
	if !has_entry {
		stop("boot program: the kernel module has no entry\r\n")
	}
	boot.kernel_address = u64(uintptr(raw_data(kernel)))
	boot.kernel_size = head.memory_size
	boot.kernel_file = u64(uintptr(raw_data(kernel_file)))
	boot.kernel_file_size = u64(len(kernel_file))
	boot.boot_image = u64(uintptr(image_copy))
	boot.boot_image_size = u64(len(boot_image))
	boot.cycles_loaded = u64(intrinsics.read_cycle_counter())

	stack := u64(uintptr(allocate(info.BOOT_STACK_PAGES))) + info.BOOT_STACK_PAGES * PAGE_SIZE
	ranges := ([^]info.Memory_Range)(allocate((MEMORY_RANGE_CAPACITY * size_of(info.Memory_Range) + PAGE_SIZE - 1) / PAGE_SIZE))
	firmware_map := allocate(FIRMWARE_MAP_PAGES)

	// The page tables need the size of physical memory, so the memory map is
	// read once now, and once more after the last allocation.
	top := u64(MINIMUM_DIRECT_MAP)
	{
		count, _ := read_memory_map(firmware_map, ranges)
		for range in ranges[:count] {
			op.boot_range_add(&display_data.boot, range.start, range.page_count, u64(range.kind))
			if range.kind != .Reserved {
				top = max(top, range.start + range.page_count * PAGE_SIZE)
			}
		}
	}
	display(boot, "the boot program starts the kernel")
	top = (top + TABLE_SPAN - 1) / TABLE_SPAN * TABLE_SPAN
	boot.direct_map_size = top
	boot.page_table = build_page_tables(top, kernel, head.memory_size)
	boot.memory_ranges = u64(uintptr(ranges))

	// After the last allocation that stops the machine when it fails, so a
	// debug image never takes the memory that the start needs; before the
	// last read of the memory map, which gives its pages the kind Boot. The
	// page tables map all memory, its pages too.
	boot.debug_image, boot.debug_image_size = debug_image_read()
	print("boot program: ok\r\n")
	for attempt in 0 ..< 2 {
		count, key := read_memory_map(firmware_map, ranges)
		boot.memory_range_count = u64(count)
		if services.exit_boot_services(image_handle, key) == 0 {
			boot_jump(boot.page_table, u64(entry), u64(info.DIRECT_MAP_BASE) + u64(uintptr(boot)), u64(info.DIRECT_MAP_BASE) + stack)
		}
		_ = attempt
	}
	stop("boot program: the firmware refused to end its services\r\n")
}

// build_page_tables gives the address of the top level table.
build_page_tables :: proc "contextless" (top: u64, kernel: []u8, kernel_size: u64) -> u64 {
	table :: proc "contextless" () -> ^[512]u64 {
		return (^[512]u64)(allocate(1))
	}
	// child gives the table that entry `index` of `parent` points to. It makes the table if needed.
	child :: proc "contextless" (parent: ^[512]u64, index: u64) -> ^[512]u64 {
		if parent[index] & PAGE_PRESENT == 0 {
			parent[index] = u64(uintptr(table())) | PAGE_PRESENT | PAGE_WRITE
		}
		return (^[512]u64)(uintptr(parent[index] &~ 0xFFF))
	}

	root := table()

	// Physical memory, in large pages: one set of tables, reached from entry 0
	// (the addresses that the boot program runs at) and from the direct map.
	physical := table()
	for span in 0 ..< top / TABLE_SPAN {
		large := child(physical, span)
		for i in 0 ..< u64(512) {
			large[i] = (span * TABLE_SPAN + i * LARGE_PAGE_SIZE) | PAGE_PRESENT | PAGE_WRITE | PAGE_LARGE
		}
	}
	root[0] = u64(uintptr(physical)) | PAGE_PRESENT | PAGE_WRITE
	root[(u64(info.DIRECT_MAP_BASE) >> 39) & 511] = u64(uintptr(physical)) | PAGE_PRESENT | PAGE_WRITE

	// The kernel, in small pages, with the protection of each segment.
	for index in 1 ..< module.count(kernel_file, .Segments) {
		segment, _ := module.record(kernel_file, .Segments, index, module.Segment)
		flags := PAGE_PRESENT
		if .Write in segment.flags && .Read_Only_After_Load not_in segment.flags {
			flags |= PAGE_WRITE
		}
		if .Execute not_in segment.flags {
			flags |= PAGE_NO_EXECUTE
		}
		for offset := segment.memory_offset; offset < segment.memory_offset + segment.memory_size; offset += PAGE_SIZE {
			address := u64(info.KERNEL_BASE) + offset
			level3 := child(root, (address >> 39) & 511)
			level2 := child(level3, (address >> 30) & 511)
			level1 := child(level2, (address >> 21) & 511)
			level1[(address >> 12) & 511] = (u64(uintptr(raw_data(kernel))) + offset) | flags
		}
	}
	_ = kernel_size
	return u64(uintptr(root))
}

// read_memory_map reads the memory map of the firmware into ranges.
read_memory_map :: proc "contextless" (firmware_map: rawptr, ranges: [^]info.Memory_Range) -> (count: int, key: uint) {
	size := uint(FIRMWARE_MAP_PAGES * PAGE_SIZE)
	descriptor_size: uint
	version: u32
	if system.boot_services.get_memory_map(&size, firmware_map, &key, &descriptor_size, &version) != 0 {
		stop("boot program: cannot read the memory map\r\n")
	}
	for offset := uint(0); offset < size && count < MEMORY_RANGE_CAPACITY; offset += descriptor_size {
		descriptor := (^Efi_Memory_Descriptor)(uintptr(firmware_map) + uintptr(offset))
		kind := info.Memory_Kind.Reserved
		switch descriptor.type {
		case .Conventional:
			kind = .Free
		case .Loader_Code, .Loader_Data:
			kind = .Boot
		case .Reserved, .Boot_Services_Code, .Boot_Services_Data, .Runtime_Services_Code, .Runtime_Services_Data, .Unusable, .Acpi_Reclaim, .Acpi_Storage, .Device, .Device_Ports, .Processor_Code, .Persistent:
		}
		ranges[count] = {start = descriptor.physical_start, page_count = descriptor.page_count, kind = kind}
		count += 1
	}
	return
}

// framebuffer chooses a graphics mode and gives its description.
framebuffer :: proc "contextless" () -> (result: info.Framebuffer) {
	guid := EFI_GRAPHICS_OUTPUT_GUID
	graphics: ^Efi_Graphics_Output
	if system.boot_services.locate_protocol(&guid, nil, (^rawptr)(&graphics)) != 0 || graphics == nil {
		print("boot program: no graphics output\r\n")
		return
	}
	for mode in 0 ..< graphics.mode.mode_count {
		size: uint
		mode_info: ^Efi_Graphics_Mode_Info
		if graphics.query_mode(graphics, mode, &size, &mode_info) != 0 {
			continue
		}
		if mode_info.width == PREFERRED_WIDTH && mode_info.height == PREFERRED_HEIGHT && mode_info.format <= .Blue_Green_Red {
			graphics.set_mode(graphics, mode)
			break
		}
	}
	mode_info := graphics.mode.info
	result = {
		address         = graphics.mode.framebuffer_base,
		width           = mode_info.width,
		height          = mode_info.height,
		pixels_per_line = mode_info.pixels_per_line,
	}
	#partial switch mode_info.format {
	case .Red_Green_Blue:
		result.format = .Red_Green_Blue_X
	case .Blue_Green_Red:
		result.format = .Blue_Green_Red_X
	case:
		result = {}
	}
	return
}

// allocate gives zero pages that stay in use after the boot program.
allocate :: proc "contextless" (page_count: u64) -> rawptr {
	address: u64
	if system.boot_services.allocate_pages(.Any, .Loader_Data, uint(page_count), &address) != 0 {
		stop("boot program: no memory\r\n")
	}
	intrinsics.mem_zero(rawptr(uintptr(address)), int(page_count * PAGE_SIZE))
	return rawptr(uintptr(address))
}

stop :: proc "contextless" (text: string) -> ! {
	print(text)
	system.runtime_services.reset_system(.Shutdown, 1, 0, nil)
	for {}
}

// Set when the boot display is on the screen. The console of the firmware
// writes on the screen as well as on the serial port: after the first draw
// of the display, each line goes to the serial port only, so that no text
// lies over the display.
display_on_screen := false

// print writes ASCII text on the firmware console, which takes UTF-16; after
// the first draw of the boot display, on the serial port only.
print :: proc "contextless" (text: string) {
	if display_on_screen {
		serial_port_print(text)
		return
	}
	buffer: [128]u16
	count := 0
	for i in 0 ..< len(text) {
		if count == len(buffer) - 1 {
			buffer[count] = 0
			system.console_out.output_string(system.console_out, raw_data(buffer[:]))
			count = 0
		}
		buffer[count] = u16(text[i])
		count += 1
	}
	buffer[count] = 0
	system.console_out.output_string(system.console_out, raw_data(buffer[:]))
}

// The Odin runtime refers to these two symbols on a Windows object target.
// The C runtime normally defines them; this program has none.

@(export, link_name = "_fltused")
_fltused: i32 = 0x9875

@(export, link_name = "_tls_index")
_tls_index: u32

// display draws the boot display (package bootscreen) with what the boot
// program knows. The kernel does not draw: the root service draws the
// display again with the records of the kernel.
display :: proc "contextless" (boot: ^info.Boot_Info, message: string, state := bootscreen.State.Running, step := bootscreen.Step.Kernel) {
	screen := boot.framebuffer
	if screen.address == 0 || screen.format == .None {
		return
	}
	display_on_screen = true
	data := &display_data
	data.boot.firmware_vendor = boot.firmware_vendor
	data.boot.firmware_revision = boot.firmware_revision
	data.boot.framebuffer_address = screen.address
	data.boot.framebuffer_width = u64(screen.width)
	data.boot.framebuffer_height = u64(screen.height)
	data.boot.framebuffer_line = u64(screen.pixels_per_line)
	data.boot.framebuffer_format = u64(screen.format)
	data.boot.kernel_size = boot.kernel_size
	data.boot.kernel_file_size = boot.kernel_file_size
	data.boot.boot_image_size = boot.boot_image_size
	data.boot.acpi_root = boot.acpi_root
	data.boot.trust = boot.trust
	data.image = boot_image
	data.processor_name = bootscreen.processor_name()
	data.message = message
	data.state = state
	data.step = step
	data.red_first = screen.format == .Red_Green_Blue_X
	bootscreen.draw_screen({pixels = ([^]graphics.Color)(uintptr(screen.address)), width = int(screen.width), height = int(screen.height), stride = int(screen.pixels_per_line)}, data)
}
