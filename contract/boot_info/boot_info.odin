// The record that the boot program gives to the kernel (property 17).
//
// All addresses in it are physical addresses. The boot program maps all
// physical memory at DIRECT_MAP_BASE, and the kernel module at KERNEL_BASE,
// before it starts the kernel.
package boot_info

MAGIC :: u64(0x4F464E49544F4F42) // The bytes "BOOTINFO".

DIRECT_MAP_BASE :: uintptr(0xFFFF_8000_0000_0000)
KERNEL_BASE :: uintptr(0xFFFF_FFFF_8000_0000)
PAGE_SIZE :: 4096
BOOT_STACK_PAGES :: 16

Memory_Kind :: enum u32 {
	Reserved = 0, // Not usable: firmware, devices, holes.
	Free     = 1,
	Boot     = 2, // In use by what the boot program loaded: this record, the kernel, the boot image, page tables.
}

Memory_Range :: struct {
	start:      u64,
	page_count: u64,
	kind:       Memory_Kind,
	reserved:   u32,
}

Pixel_Format :: enum u32 {
	None             = 0,
	Blue_Green_Red_X = 1, // 4 bytes per pixel, blue first.
	Red_Green_Blue_X = 2,
}

Framebuffer :: struct {
	address:         u64,
	width:           u32,
	height:          u32,
	pixels_per_line: u32, // The distance between two lines, in pixels.
	format:          Pixel_Format,
}

Boot_Info :: struct {
	magic:              u64,
	memory_ranges:      u64, // Address of an array of Memory_Range.
	memory_range_count: u64,
	direct_map_size:    u64, // Bytes of physical memory that are mapped at DIRECT_MAP_BASE.
	page_table:         u64, // Address of the top level page table that the boot program built.
	kernel_address:     u64, // Where the kernel module is in physical memory.
	kernel_size:        u64,
	kernel_file:        u64, // The kernel module file.
	kernel_file_size:   u64,
	boot_image:         u64, // The boot image: the modules of the first programs.
	boot_image_size:    u64,
	framebuffer:        Framebuffer,
	acpi_root:          u64, // The root record of the ACPI tables of the firmware ("RSD PTR "). 0: none.
	// The cycle counter of the processor at two moments of the boot program.
	// The counter is 0 when the machine starts.
	cycles_start:       u64, // The boot program starts.
	cycles_loaded:      u64, // The kernel and the boot image are in memory.
	firmware_vendor:    [32]u8, // Zero bytes after the name.
	firmware_revision:  u64,
	self_test:          Self_Test,
}

// A test of the kernel on itself. The kernel does one thing that its page
// tables must refuse, and the machine stops with the report of the fault.
// The kernel tool builds one boot program for each test.
Self_Test :: enum u64 {
	None            = 0,
	Stack_Overflow  = 1, // Use more than the kernel stack.
	Write_Code      = 2, // Write to the code of the kernel.
	Write_Code_View = 3, // Write to the code of the kernel through the direct map.
	Execute_Data    = 4, // Execute the data of the kernel.
	Read_Program    = 5, // Read the memory of a program, outside a copy.
	Execute_Program = 6, // Execute the code of a program.
}

// physical gives a pointer to physical memory, through the direct map.
physical :: #force_inline proc "contextless" (address: u64, $T: typeid) -> ^T {
	return (^T)(DIRECT_MAP_BASE + uintptr(address))
}

// physical_slice gives count records of physical memory, through the direct map.
physical_slice :: #force_inline proc "contextless" (address: u64, count: u64, $T: typeid) -> []T {
	return ([^]T)(DIRECT_MAP_BASE + uintptr(address))[:count]
}

// The boot image: the module files that the first program needs, and the
// resources (files that are not modules: the pointer theme files), in one
// block.
//
//   Image_Header
//   Image_Entry, header.count times: the modules
//   Image_Entry, header.resource_count times: the resources
//   the files; each one starts on a page boundary of the image
//
// A reader of modules reads the first table only: a resource is never
// taken for a module.
IMAGE_MAGIC :: u64(0x4547414D49544F42) // The bytes "BOTIMAGE".
IMAGE_NAME_SIZE :: 32

Image_Header :: struct {
	magic:          u64,
	count:          u32, // The modules.
	resource_count: u32, // The resources, after the modules. 0: none.
}

Image_Entry :: struct {
	name:   [IMAGE_NAME_SIZE]u8, // Zero bytes after the name. A name is for people; the hash is the identity.
	hash:   [32]u8,
	offset: u64, // From the start of the image.
	size:   u64,
}
