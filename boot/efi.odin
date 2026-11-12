package boot

// The records of the UEFI specification that the boot program uses. A field
// that the boot program does not call has the type rawptr.

Efi_Status :: uint

Efi_Table_Header :: struct {
	signature:   u64,
	revision:    u32,
	header_size: u32,
	crc32:       u32,
	reserved:    u32,
}

Efi_Guid :: struct {
	a: u32,
	b: u16,
	c: u16,
	d: [8]u8,
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
	get_variable:                  proc "win64" (name: [^]u16, vendor: ^Efi_Guid, attributes: ^u32, data_size: ^uint, data: rawptr) -> Efi_Status,
	get_next_variable_name:        rawptr,
	set_variable:                  rawptr,
	get_next_high_monotonic_count: rawptr,
	reset_system:                  proc "win64" (type: Efi_Reset_Type, status: Efi_Status, data_size: uint, data: rawptr),
}

Efi_Allocate_Type :: enum u32 {
	Any = 0,
}

Efi_Memory_Type :: enum u32 {
	Reserved              = 0,
	Loader_Code           = 1,
	Loader_Data           = 2,
	Boot_Services_Code    = 3,
	Boot_Services_Data    = 4,
	Runtime_Services_Code = 5,
	Runtime_Services_Data = 6,
	Conventional          = 7,
	Unusable              = 8,
	Acpi_Reclaim          = 9,
	Acpi_Storage          = 10,
	Device                = 11,
	Device_Ports          = 12,
	Processor_Code        = 13,
	Persistent            = 14,
}

Efi_Memory_Descriptor :: struct {
	type:           Efi_Memory_Type,
	padding:        u32,
	physical_start: u64,
	virtual_start:  u64,
	page_count:     u64,
	attribute:      u64,
}

Efi_Boot_Services :: struct {
	header:                 Efi_Table_Header,
	raise_priority:         rawptr,
	restore_priority:       rawptr,
	allocate_pages:         proc "win64" (type: Efi_Allocate_Type, memory_type: Efi_Memory_Type, page_count: uint, address: ^u64) -> Efi_Status,
	free_pages:             rawptr,
	get_memory_map:         proc "win64" (size: ^uint, memory_map: rawptr, key: ^uint, descriptor_size: ^uint, descriptor_version: ^u32) -> Efi_Status,
	allocate_pool:          rawptr,
	free_pool:              rawptr,
	create_event:           rawptr,
	set_timer:              rawptr,
	wait_for_event:         rawptr,
	signal_event:           rawptr,
	close_event:            rawptr,
	check_event:            rawptr,
	install_protocol:       rawptr,
	reinstall_protocol:     rawptr,
	uninstall_protocol:     rawptr,
	handle_protocol:        rawptr,
	reserved:               rawptr,
	register_notify:        rawptr,
	locate_handle:          rawptr,
	locate_device_path:     rawptr,
	install_configuration:  rawptr,
	load_image:             rawptr,
	start_image:            rawptr,
	exit:                   rawptr,
	unload_image:           rawptr,
	exit_boot_services:     proc "win64" (image: rawptr, key: uint) -> Efi_Status,
	get_next_count:         rawptr,
	stall:                  proc "win64" (microseconds: uint) -> Efi_Status,
	set_watchdog_timer:     proc "win64" (timeout: uint, code: u64, data_size: uint, data: [^]u16) -> Efi_Status,
	connect_controller:     rawptr,
	disconnect_controller:  rawptr,
	open_protocol:          rawptr,
	close_protocol:         rawptr,
	open_protocol_info:     rawptr,
	protocols_per_handle:   rawptr,
	locate_handle_buffer:   rawptr,
	locate_protocol:        proc "win64" (guid: ^Efi_Guid, registration: rawptr, interface: ^rawptr) -> Efi_Status,
}

Efi_System_Table :: struct {
	header:                Efi_Table_Header,
	firmware_vendor:       [^]u16,
	firmware_revision:     u32,
	console_in_handle:     rawptr,
	console_in:            rawptr,
	console_out_handle:    rawptr,
	console_out:           ^Efi_Text_Output,
	standard_error_handle: rawptr,
	standard_error:        ^Efi_Text_Output,
	runtime_services:      ^Efi_Runtime_Services,
	boot_services:         ^Efi_Boot_Services,
	table_count:           uint,
	tables:                [^]Efi_Configuration_Table,
}

Efi_Configuration_Table :: struct {
	guid:  Efi_Guid,
	table: rawptr,
}

EFI_ACPI_GUID :: Efi_Guid{0x8868E871, 0xE4F1, 0x11D3, {0xBC, 0x22, 0x00, 0x80, 0xC7, 0x3C, 0x88, 0x81}}

EFI_GRAPHICS_OUTPUT_GUID :: Efi_Guid{0x9042A9DE, 0x23DC, 0x4A38, {0x96, 0xFB, 0x7A, 0xDE, 0xD0, 0x80, 0x51, 0x6A}}

Efi_Pixel_Format :: enum u32 {
	Red_Green_Blue = 0,
	Blue_Green_Red = 1,
	Bit_Mask       = 2,
	Blt_Only       = 3,
}

Efi_Graphics_Mode_Info :: struct {
	version:         u32,
	width:           u32,
	height:          u32,
	format:          Efi_Pixel_Format,
	masks:           [4]u32,
	pixels_per_line: u32,
}

Efi_Graphics_Mode :: struct {
	mode_count:       u32,
	mode:             u32,
	info:             ^Efi_Graphics_Mode_Info,
	info_size:        uint,
	framebuffer_base: u64,
	framebuffer_size: uint,
}

Efi_Graphics_Output :: struct {
	query_mode: proc "win64" (this: ^Efi_Graphics_Output, mode: u32, info_size: ^uint, info: ^^Efi_Graphics_Mode_Info) -> Efi_Status,
	set_mode:   proc "win64" (this: ^Efi_Graphics_Output, mode: u32) -> Efi_Status,
	blt:        rawptr,
	mode:       ^Efi_Graphics_Mode,
}

// The variables of the UEFI specification ("SecureBoot").
EFI_GLOBAL_VARIABLE_GUID :: Efi_Guid{0x8BE4DF61, 0x93CA, 0x11D2, {0xAA, 0x0D, 0x00, 0xE0, 0x98, 0x03, 0x2B, 0x8C}}

// The TPM through the firmware: EFI_TCG2_PROTOCOL of the TCG EFI Protocol
// Specification. The boot program talks to the TPM only through it: it has
// no TPM driver.
EFI_TCG2_GUID :: Efi_Guid{0x607F766C, 0x7455, 0x42BE, {0x93, 0x0B, 0xE4, 0xD7, 0x6D, 0xB2, 0x72, 0x0F}}

Efi_Tcg2_Protocol :: struct {
	get_capability:                     rawptr,
	get_event_log:                      rawptr,
	// The firmware hashes data with each active bank of the TPM, extends the
	// register of the event with each hash, and writes the event in its log.
	hash_log_extend_event:              proc "win64" (this: ^Efi_Tcg2_Protocol, flags: u64, data: u64, data_size: u64, event: rawptr) -> Efi_Status,
	// One command of the TPM, in its own byte format (big-endian).
	submit_command:                     proc "win64" (this: ^Efi_Tcg2_Protocol, input_size: u32, input: [^]u8, output_size: u32, output: [^]u8) -> Efi_Status,
	get_active_pcr_banks:               rawptr,
	set_active_pcr_banks:               rawptr,
	get_result_of_set_active_pcr_banks: rawptr,
}

// EFI_TCG2_EVENT is packed: Size (4 bytes), then the header: HeaderSize
// (4), HeaderVersion (2), PCRIndex (4), EventType (4), then the event data.
// The boot program writes it byte by byte.
EFI_TCG2_EVENT_HEADER_SIZE :: 14
EFI_TCG2_EVENT_DATA_OFFSET :: 4 + EFI_TCG2_EVENT_HEADER_SIZE
EFI_TCG2_EVENT_HEADER_VERSION :: 1
// The event type of a stage of the boot that the boot program measures
// (TCG PC Client Platform Firmware Profile).
TCG_EVENT_IPL :: 0x0000_000D
