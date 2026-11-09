// The module format, version 1 (docs/MODULE_CONTRACT.md, sections 1 and 2).
//
// A module is one file:
//
//   Header
//   table directory   one Table_Entry per Table_Kind
//   tables            flat records
//   segment data      each segment starts on a page boundary of the file
//
// All numbers are little-endian. An all-zero record is valid (ZII).
// Record 0 of an indexed table is the empty record, so index 0 means "none".
// This package allocates no memory: the boot program, the kernel and the
// build tool use the same code.
package module

MAGIC :: u64(0x0000_454C_5544_4F4D) // The bytes "MODULE", then two zero bytes.
VERSION :: 1
PAGE_SIZE :: 4096
HASH_SIZE :: 32

// The feature bits that this code understands. A file that sets another bit
// in Header.must_understand is refused.
UNDERSTOOD_FEATURES :: u64(0)

Machine :: enum u32 {
	None   = 0,
	X86_64 = 1,
}

Header :: struct {
	magic:           u64,
	version:         u32,
	header_size:     u32, // The table directory starts at this offset.
	must_understand: u64,
	machine:         Machine,
	table_count:     u32, // The number of entries of the table directory.
	memory_size:     u64, // The size of the address range of the loaded module.
	entry_export:    u32, // An index in the export table. 0: the module has no entry.
	reserved:        u32,
}
#assert(size_of(Header) == 48)

// The number of a table is its index in the table directory.
Table_Kind :: enum u32 {
	None      = 0,
	Segments  = 1,
	Imports   = 2,
	Slots     = 3,
	Exports   = 4,
	Rebases   = 5,
	Functions = 6,
	Strings   = 7,
}
TABLE_COUNT :: len(Table_Kind)

// A table can gain fields at the end of its record: record_size says how
// large a record is in this file. A reader ignores the bytes that it does not
// know, and reads the bytes that the file does not have as zero.
Table_Entry :: struct {
	offset:      u64, // From the start of the file.
	count:       u32,
	record_size: u32,
}
#assert(size_of(Table_Entry) == 16)

Segment_Flag :: enum u32 {
	Read                 = 0,
	Write                = 1,
	Execute              = 2,
	Read_Only_After_Load = 3, // The loader writes it (rebases, slots), then removes Write.
}
Segment_Flags :: bit_set[Segment_Flag;u32]

// memory_offset and memory_size are multiples of PAGE_SIZE. The bytes of
// memory after file_size are zero.
Segment :: struct {
	file_offset:   u64,
	file_size:     u64,
	memory_offset: u64,
	memory_size:   u64,
	flags:         Segment_Flags,
	reserved:      u32,
}
#assert(size_of(Segment) == 40)

// One imported module, named by the BLAKE3 hash of its file.
Import :: struct {
	hash: [HASH_SIZE]u8,
}

// One import slot: 8 bytes of memory that receive the address of an export.
Slot :: struct {
	memory_offset: u64,
	import_index:  u32,
	export_index:  u32,
}
#assert(size_of(Slot) == 16)

Export :: struct {
	code_offset: u64, // The memory offset of the first instruction.
	function:    u32, // An index in the function table.
	reserved:    u32,
}
#assert(size_of(Export) == 16)

// The type of a parameter or of a result of an export, in the call form
// (docs/MODULE_CONTRACT.md, section 4).
Type :: enum u8 {
	None    = 0,
	Integer = 1, // A signed integer of 64 bits, in a register.
	Text    = 2, // The address of a slice record {address, count} of UTF-8 bytes. Parameters only.
}

PARAMETER_CAPACITY :: 6 // The integer registers of the call form.

// The description of one export. It is sufficient to call the export: the
// console reads it. The loader does not.
Function :: struct {
	name_offset:     u32, // In the string table.
	name_count:      u32,
	about_offset:    u32, // One line of help, in the string table.
	about_count:     u32,
	parameter_count: u8,
	result:          Type,
	parameters:      [PARAMETER_CAPACITY]Type,
}
#assert(size_of(Function) == 24)

// The rebase table is not indexed. It is a sequence of 64-bit words in the
// RELR form, and it names the 8-byte locations that hold a memory offset:
//   an even word   is a memory offset: rebase that location; the cursor is
//                  the next location.
//   an odd word    is a bitmap: bit n (1 to 63) set means "rebase the
//                  location at cursor + 8 * (n - 1)"; then the cursor
//                  advances by 63 locations.
REBASE_WORD_SIZE :: 8
REBASE_BITMAP_LOCATIONS :: 63

// The string table is bytes. Its byte 0 is zero, so that offset 0 is no name.
