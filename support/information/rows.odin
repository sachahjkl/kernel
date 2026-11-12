// The information of the modules: functions, and no query language, that read the flat tables of module files and fill tables of rows in memory of the caller.
//
// A function takes the catalog (the modules that the program can see) and a slice of rows. It writes the rows that fit, and gives the count of rows of the full answer: a count larger than the slice means "give more memory". It allocates nothing and keeps no state. It copies no truth: a row holds numbers and short texts that it reads from the tables, and the module file stays the one source.
//
// The tables of a module are input that nobody checked. Each read is checked against the size of the file and of its tables. A function never faults on a malformed module: it gives a Problem, with the table, the record and the byte of the file that break a rule.
//
// The rows are records of the module contract: fixed size, an Integer field is an i64, a Text field is [N]u8 with zero bytes after the text. A service that serves these functions has the same records in its description, and the console combines them (where, sort, join).
package information

// One row for each module of the catalog: modules().
Module :: struct {
	name:      [32]u8, // The name of the module in the catalog.
	hash:      [64]u8, // The BLAKE3 hash of the file, in hexadecimal: the identity of the module.
	file:      i64, // The bytes of the file.
	code:      i64, // The bytes of memory of the segments that execute.
	constants: i64, // The bytes of memory of the segments that are read-only, from the start or after the load.
	data:      i64, // The bytes of the writable segments that the file gives.
	zero:      i64, // The bytes of the writable segments that start as zero: the file does not hold them.
	entry:     i64, // 1: the module has an entry, so it can run as a program. 0: no entry.
	exports:   i64, // The exports with a description: each export but the entry.
	imports:   i64, // The modules that it imports.
	records:   i64, // The record descriptions of its exports.
	problem:   [24]u8, // Empty: the module keeps each rule that this library checks. Else the name of a Problem_Kind.
	place:     [16]u8, // A problem: the table where it is (a Table_Kind name), or "header".
	index:     i64, // A problem: the record of that table, from 0.
	offset:    i64, // A problem: the byte of the file where the bad value is.
}

// One row for each export with a description: exports(), exporters(),
// described(), handles().
Export :: struct {
	module:    [32]u8, // The module that exports it.
	name:      [32]u8,
	number:    i64, // The index of the export in its module, from 1.
	parameters: i64,
	result:    [8]u8, // "Integer", "Text", "Record", "Table", or empty.
	rights:    [40]u8, // The rights that the export asks of the handles that it takes: in a Handle parameter or in a Handle field of a Record parameter.
	signature: [112]u8, // "name(parameter: Type, ...) -> Type". A longer signature ends with "...".
}

// One row for each import of a module: imports(), importers().
Import :: struct {
	module:      [32]u8, // The module that imports.
	number:      i64, // The index of the import in that module, from 1.
	hash:        [64]u8, // The hash of the imported module, as the file names it, in hexadecimal.
	name:        [32]u8, // The name of the imported module in the catalog. Empty: the catalog has no module with this hash.
	slots:       i64, // The slots of the module that use this import: one for each export that it calls.
	replacement: [32]u8, // The module that a loader gives in place of the import on this machine (the replacement table). Empty: none.
}

// One row for each slot of a module: slots(). A slot receives the address
// of one export of one import when the loader binds the module.
Slot :: struct {
	module:       [32]u8,
	number:       i64, // The index of the slot, from 1.
	import_index: i64, // The import, from 1.
	export_index: i64, // The export of that import, from 1.
	target:       [32]u8, // The name of the imported module in the catalog, or empty.
	name:         [32]u8, // The name of the export in the imported module, or empty.
}

// One row for each segment of a module: segments().
Segment :: struct {
	module:        [32]u8,
	number:        i64, // The index of the segment, from 1.
	kind:          [24]u8, // "code", "constants", "constants after load" or "data".
	memory_offset: i64,
	memory_size:   i64,
	file_offset:   i64,
	file_size:     i64,
}

// One row for each module that runs in a program, from the module records
// of the kernel (operation.Module_Record): running().
Running :: struct {
	program:  [32]u8, // The name of the program.
	slot:     i64, // The place of the program in the kernel: programs() of the console shows it.
	module:   [32]u8, // The name of the module in the catalog. Empty: the catalog has no module with this hash.
	hash:     [64]u8, // The hash of the module that runs, in hexadecimal.
	replaces: [64]u8, // The hash that an import names and that a replacement changed to `hash`. Empty: no replacement.
	base:     i64, // The address of the module in the program.
	size:     i64, // The bytes of addresses of the module.
}

// One row for each record of the replacement table of the machine:
// replacements().
Replacement :: struct {
	from:      [32]u8, // The name of the module that an import names, in the catalog.
	from_hash: [64]u8,
	to:        [32]u8, // The name of the module that a loader gives in its place.
	to_hash:   [64]u8,
}