// The boot program: a UEFI program (PROPERTIES.md, property 17).
//
// First version: it proves that the tool chain produces a UEFI program that
// starts. It prints BOOT_MARK on the firmware console, then it stops the
// machine. `kerneltool test` looks for BOOT_MARK.
package boot

import "base:runtime"

// The records of the UEFI specification that this program reads. Only the
// fields up to the last one that is used have a type; the others are rawptr.

Efi_Status :: uint

Efi_Table_Header :: struct {
	signature:   u64,
	revision:    u32,
	header_size: u32,
	crc32:       u32,
	reserved:    u32,
}

Efi_Text_Output :: struct {
	reset:         rawptr,
	output_string: proc "win64" (this: ^Efi_Text_Output, text: [^]u16) -> Efi_Status,
}

Efi_Reset_Type :: enum u32 {
	Cold     = 0,
	Warm     = 1,
	Shutdown = 2,
}

Efi_Runtime_Services :: struct {
	header:                        Efi_Table_Header,
	get_time:                      rawptr,
	set_time:                      rawptr,
	get_wakeup_time:               rawptr,
	set_wakeup_time:               rawptr,
	set_virtual_address_map:       rawptr,
	convert_pointer:               rawptr,
	get_variable:                  rawptr,
	get_next_variable_name:        rawptr,
	set_variable:                  rawptr,
	get_next_high_monotonic_count: rawptr,
	reset_system:                  proc "win64" (type: Efi_Reset_Type, status: Efi_Status, data_size: uint, data: rawptr),
}

Efi_System_Table :: struct {
	header:               Efi_Table_Header,
	firmware_vendor:      [^]u16,
	firmware_revision:    u32,
	console_in_handle:    rawptr,
	console_in:           rawptr,
	console_out_handle:   rawptr,
	console_out:          ^Efi_Text_Output,
	standard_error_handle: rawptr,
	standard_error:       ^Efi_Text_Output,
	runtime_services:     ^Efi_Runtime_Services,
}

// BOOT_MARK is the text that `kerneltool test` waits for. Keep the two equal.
BOOT_MARK :: "boot program: ok"

@(export, link_name = "efi_main")
efi_main :: proc "win64" (image: rawptr, system_table: ^Efi_System_Table) -> Efi_Status {
	context = runtime.default_context()
	print(system_table.console_out, BOOT_MARK + "\r\n")
	system_table.runtime_services.reset_system(.Shutdown, 0, 0, nil)
	for {}
}

// print writes ASCII text on a UEFI text output, which takes UTF-16.
print :: proc(output: ^Efi_Text_Output, text: string) {
	buffer: [128]u16
	count := 0
	for i in 0 ..< len(text) {
		if count == len(buffer) - 1 {
			buffer[count] = 0
			output.output_string(output, raw_data(buffer[:]))
			count = 0
		}
		buffer[count] = u16(text[i])
		count += 1
	}
	buffer[count] = 0
	output.output_string(output, raw_data(buffer[:]))
}

// The Odin runtime refers to these two symbols on a Windows object target.
// The C runtime normally defines them; this program has none.

@(export, link_name = "_fltused")
_fltused: i32 = 0x9875

@(export, link_name = "_tls_index")
_tls_index: u32
