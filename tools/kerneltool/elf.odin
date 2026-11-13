package kerneltool

// The records of the ELF format that the converter reads. ELF is a build-time
// intermediate format only (docs/MODULE_CONTRACT.md, section 7).

ELF_MAGIC :: u32(0x464C457F)
ELF_CLASS_64 :: 2
ELF_DATA_LITTLE_ENDIAN :: 1
ELF_TYPE_SHARED :: 3
ELF_MACHINE_X86_64 :: 62

Elf_Header :: struct {
	magic:                       u32,
	class:                       u8,
	data:                        u8,
	identification_version:      u8,
	padding:                     [9]u8,
	type:                        u16,
	machine:                     u16,
	version:                     u32,
	entry:                       u64,
	program_header_offset:       u64,
	section_header_offset:       u64,
	flags:                       u32,
	header_size:                 u16,
	program_header_size:         u16,
	program_header_count:        u16,
	section_header_size:         u16,
	section_header_count:        u16,
	section_name_section_index:  u16,
}
#assert(size_of(Elf_Header) == 64)

ELF_PROGRAM_LOAD :: 1
ELF_PROGRAM_TLS :: 7
ELF_PROGRAM_RELRO :: 0x6474E552
ELF_PROGRAM_EXECUTE :: 1
ELF_PROGRAM_WRITE :: 2
ELF_PROGRAM_READ :: 4

Elf_Program_Header :: struct {
	type:           u32,
	flags:          u32,
	offset:         u64,
	address:        u64,
	physical:       u64,
	file_size:      u64,
	memory_size:    u64,
	alignment:      u64,
}
#assert(size_of(Elf_Program_Header) == 56)

ELF_SECTION_PROGRAM_DATA :: 1
ELF_SECTION_SYMBOLS :: 2
ELF_SECTION_NO_BITS :: 8 // A section with no bytes in the file (.bss).
ELF_SECTION_RELA :: 4
ELF_SECTION_DYNAMIC_SYMBOLS :: 11
ELF_SECTION_INIT_ARRAY :: 14
ELF_SECTION_FINI_ARRAY :: 15
ELF_SECTION_PREINIT_ARRAY :: 16
ELF_SECTION_FLAG_ALLOCATED :: 2

Elf_Section_Header :: struct {
	name:       u32,
	type:       u32,
	flags:      u64,
	address:    u64,
	offset:     u64,
	size:       u64,
	link:       u32,
	info:       u32,
	alignment:  u64,
	entry_size: u64,
}
#assert(size_of(Elf_Section_Header) == 64)

ELF_SYMBOL_FUNCTION :: 2

Elf_Symbol :: struct {
	name:          u32,
	info:          u8,
	other:         u8,
	section_index: u16,
	value:         u64,
	size:          u64,
}
#assert(size_of(Elf_Symbol) == 24)

ELF_RELOCATION_64 :: 1
ELF_RELOCATION_GLOBAL_DATA :: 6
ELF_RELOCATION_JUMP_SLOT :: 7
ELF_RELOCATION_RELATIVE :: 8

Elf_Rela :: struct {
	offset: u64,
	info:   u64,
	addend: i64,
}
#assert(size_of(Elf_Rela) == 24)
