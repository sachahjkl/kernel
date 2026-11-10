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
	None          = 0,
	Segments      = 1,
	Imports       = 2,
	Slots         = 3,
	Exports       = 4,
	Rebases       = 5,
	Functions     = 6,
	Strings       = 7,
	Documentation = 8,
	Records       = 9,
	Fields        = 10,
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
	Text    = 2, // The address of a slice record {address, count} of UTF-8 bytes.
	// A Text result: the caller gives one more argument after the parameters,
	// the address of a buffer record {address, capacity}. The callee writes
	// the text in the buffer, and its integer result is the count of bytes of
	// the full text. A count larger than the capacity means "the text did
	// not fit": the caller owns all memory (property 14).
	Record  = 3, // The address of a record: bytes with a fixed size and described fields (Record).
	// A record holds values only, and no address: its bytes mean the same
	// in each program. The detail of the parameter is the index of the
	// description of the record, in the record table.
	// A Record result: the caller gives one more argument after the
	// parameters, the address of the memory of the record. The callee
	// writes the record there. The export has no integer result.
	Handle  = 4, // A handle that the caller lends for the time of the call, in a register.
	// The detail of the parameter is the rights that the callee needs: a
	// bit set of rights (the kernel operations name the bits). The caller
	// keeps its handle. In an isolated call, the receiver has a copy of the
	// handle with these rights only, and closes it when the export returns.
}

PARAMETER_CAPACITY :: 6 // The integer registers of the call form.

// The description of one export. It is sufficient to call the export: the
// console reads it. The loader does not.
Function :: struct {
	name_offset:           u32, // In the string table.
	name_count:            u32,
	about_offset:          u32, // One line of help, in the string table.
	about_count:           u32,
	parameter_names:       [PARAMETER_CAPACITY]u32, // The name of each parameter, in the string table.
	parameter_count:       u8,
	result:                Type,
	parameters:            [PARAMETER_CAPACITY]Type,
	parameter_name_counts: [PARAMETER_CAPACITY]u8,
	reserved:              [2]u8,
	text_offset:           u32, // The documentation text of the export, in the string table.
	text_count:            u32,
	parameter_details:     [PARAMETER_CAPACITY]u32, // What the type of each parameter needs: Type says what it is.
	result_detail:         u32, // A Record result: the index of the description of the record.
	reserved_details:      u32,
}
#assert(size_of(Function) == 96)

RECORD_SIZE_LIMIT :: 256 // The bytes of a record that a call carries.
HANDLE_CAPACITY :: 16 // The handles that one call lends: its Handle parameters, and the Handle fields of its Record parameters.

// The description of a record: a parameter or a result of the type Record.
// Record 0 of the record table is the empty record.
Record :: struct {
	name_offset: u32, // In the string table.
	name_count:  u32,
	size:        u32, // In bytes: at most RECORD_SIZE_LIMIT.
	first_field: u32, // An index in the field table. The fields of a record follow each other.
	field_count: u32,
	reserved:    u32,
}
#assert(size_of(Record) == 24)

// One field of a record. A field is an Integer (8 bytes) or a Handle (4
// bytes). The fields are in the order of their offsets, and no two fields
// share a byte.
Field :: struct {
	name_offset: u32, // In the string table.
	name_count:  u32,
	offset:      u32, // From the start of the record, in bytes.
	type:        Type,
	reserved:    [3]u8,
	detail:      u32, // A Handle: the rights that the callee needs.
	reserved2:   u32,
}
#assert(size_of(Field) == 24)

// The documentation of the module, for a person. Record 1 of the
// documentation table is the documentation of the module. No loader reads it.
//
// A documentation text is UTF-8 bytes. A line feed ends a line. A line is a
// paragraph: the reader breaks it at the width that it has. A line that
// starts with a space is not a paragraph: the reader keeps it as it is.
// An empty line separates two paragraphs.
Documentation :: struct {
	about_offset: u32, // One line, in the string table: what the module is.
	about_count:  u32,
	text_offset:  u32, // The documentation text, in the string table.
	text_count:   u32,
}
#assert(size_of(Documentation) == 16)

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
