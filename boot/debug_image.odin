package boot

import "base:intrinsics"

// The debug image (docs/MODULE_CONTRACT.md, "Debug information"): the debug
// objects of the modules, one file of the boot volume beside the boot
// program, apart from the boot image. The boot program and the boot image
// are the same bytes with and without it, so a debug object changes no
// measure and no signature. It is data for a reader of names: no code
// comes from it, and each reader checks each debug object before it uses
// it. A volume with no such file starts as before.

DEBUG_IMAGE_PATH :: "\\DEBUG\\OBJECTS.IMG"
// A bound of the pages that the debug image takes: the debug image of the
// build of today is a few MiB.
DEBUG_IMAGE_LIMIT :: 256 << 20

// debug_image_read reads the debug image of the volume of the boot program
// into pages of its own. It gives 0 and 0 when the volume has no such file,
// when the file is empty or over the bound, or when the firmware refuses a
// step: a start never fails for the debug image.
debug_image_read :: proc "contextless" () -> (address: u64, size: u64) {
	services := system.boot_services
	loaded_guid := EFI_LOADED_IMAGE_GUID
	file_system_guid := EFI_SIMPLE_FILE_SYSTEM_GUID
	loaded: rawptr
	if services.handle_protocol(image_handle, &loaded_guid, &loaded) != 0 || loaded == nil {
		return 0, 0
	}
	file_system: rawptr
	if services.handle_protocol((^Efi_Loaded_Image)(loaded).device_handle, &file_system_guid, &file_system) != 0 || file_system == nil {
		return 0, 0
	}
	volume: ^Efi_File
	if (^Efi_Simple_File_System)(file_system).open_volume((^Efi_Simple_File_System)(file_system), &volume) != 0 || volume == nil {
		return 0, 0
	}
	defer volume.close(volume)
	// UTF-16, with a zero at the end. A constant string is not indexed with
	// a variable: the loop reads a string value.
	path_text := DEBUG_IMAGE_PATH
	path: [len(DEBUG_IMAGE_PATH) + 1]u16
	for index in 0 ..< len(path_text) {
		path[index] = u16(path_text[index])
	}
	file: ^Efi_File
	if volume.open(volume, &file, raw_data(path[:]), EFI_FILE_MODE_READ, 0) != 0 || file == nil {
		print("boot program: the volume has no debug image\r\n")
		return 0, 0
	}
	defer file.close(file)
	// The size: the position at the end of the file.
	if file.set_position(file, max(u64)) != 0 || file.get_position(file, &size) != 0 || file.set_position(file, 0) != 0 {
		return 0, 0
	}
	if size == 0 || size > DEBUG_IMAGE_LIMIT {
		print("boot program: the debug image is empty or over its bound: not read\r\n")
		return 0, 0
	}
	page_count := (size + PAGE_SIZE - 1) / PAGE_SIZE
	if services.allocate_pages(.Any, .Loader_Data, uint(page_count), &address) != 0 {
		print("boot program: no memory for the debug image: not read\r\n")
		return 0, 0
	}
	intrinsics.mem_zero(rawptr(uintptr(address)), int(page_count * PAGE_SIZE))
	done := u64(0)
	for done < size {
		count := uint(size - done)
		if file.read(file, &count, rawptr(uintptr(address + done))) != 0 || count == 0 || u64(count) > size - done {
			// The pages stay with the boot program: the kernel takes them
			// as memory of the boot, and nothing names them.
			print("boot program: the read of the debug image failed: not read\r\n")
			return 0, 0
		}
		done += u64(count)
	}
	print("boot program: the debug image is in memory\r\n")
	return address, size
}
