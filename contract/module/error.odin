package module

// The error of a load: a record that the caller of a loader owns. Zero is
// "no error". It is data, not text: a program in any language reads it,
// and a call host gives it to its caller in the call region. A loader fills
// it when a load fails; the caller writes it for a person.

NAME_SIZE :: 32 // The bytes of a name of a module or of an export. Zero bytes after the name.

// The stage of the load that failed.
Load_Stage :: enum u32 {
	None  = 0,
	Find  = 1, // Find the file of a module: the load source has no file with its hash.
	Read  = 2, // Read the file: it does not have the hash that names it, or its tables are not valid (`file_error`).
	Cycle = 3, // A module imports itself through its imports. Only a replacement can make a cycle: an import names a hash.
	Check = 4, // Check a replacement: an export that a slot uses is missing in the module of the replacement, or its description differs (`difference`).
	Bind  = 5, // Bind a slot: the slot names no import or no export, or it is not in writable data.
	Map   = 6, // Map the memory of a module: a kernel operation failed (`status`).
	Room  = 7, // The module space, the imports of one module, or the table of prepared modules of the loader have no room for one more.
	Unmap = 8, // Remove a module: a kernel operation failed (`status`).
}

// What differs between the description of an export in the module that an
// import names (expected) and in the module of its replacement (found).
Difference :: enum u32 {
	None            = 0,
	Missing_Export  = 1, // The module of the replacement has no export with the name.
	Parameter_Count = 2, // expected.detail and found.detail are the counts.
	Parameter_Type  = 3, // Parameter `parameter` has another type.
	Parameter_Detail = 4, // Parameter `parameter`: a Handle with other rights, or another Record.
	Result_Type     = 5,
	Result_Detail   = 6, // A Record result with another record.
}

// One side of a difference: a type, its detail (the rights of a Handle, or a
// count), and the name of a Record.
Described :: struct {
	type:   Type,
	_:      [3]u8,
	detail: u32,
	record: [NAME_SIZE]u8,
}

// A module, as the load source names it.
Named :: struct {
	hash: [HASH_SIZE]u8, // Zero: no module.
	name: [NAME_SIZE]u8, // Zero: the load source gives no name to the hash.
}

Load_Error :: struct {
	stage:       Load_Stage,
	status:      u32, // Map, Unmap: the status of the kernel operation.
	file_error:  Error, // Read: what is not valid in the file; None when the hash differs.
	difference:  Difference, // Check.
	module:      Named, // The module that was being loaded: the importer, when the stage concerns one of its imports.
	imported:    Named, // The import of `module` that the stage concerns, as the file of `module` names it. Zero: the stage concerns `module` itself.
	// A replacement on the path of the load: where a module imported
	// `replaced`, the loader gave `replacement` in its place. It says who
	// decided: the party that gave the replacements.
	replaced:    Named,
	replacement: Named,
	export:      [NAME_SIZE]u8, // Check, Bind: the name of the export, in the module that the import names.
	slot:        u32, // Bind: the number of the slot.
	parameter:   u32, // Parameter_Type, Parameter_Detail: the number of the parameter, from 1.
	expected:    Described, // Check: in the module that the import names.
	found:       Described, // Check: in the module of the replacement.
}

// name_set copies a name into a field of a record.
name_set :: proc "contextless" (field: ^[NAME_SIZE]u8, name: string) {
	field^ = {}
	for index in 0 ..< min(len(name), NAME_SIZE - 1) {
		field[index] = name[index]
	}
}

// name_get gives the name of a field: the bytes before the first zero.
name_get :: proc "contextless" (field: ^[NAME_SIZE]u8) -> string {
	count := 0
	for count < NAME_SIZE && field[count] != 0 {
		count += 1
	}
	return string(field[:count])
}

// functions_compare compares the description of two exports in two
// modules: the same parameters with the same types, the same result, equal
// records, and the same rights for each handle. The names of the
// parameters and the help are for a person: they can differ. It gives the
// first difference, and its two sides.
functions_compare :: proc "contextless" (file: []u8, index: u32, other_file: []u8, other_index: u32) -> (difference: Difference, parameter: u32, expected, found: Described) {
	a, has_a := function(file, index)
	b, has_b := function(other_file, other_index)
	if !has_a || !has_b {
		return .Missing_Export, 0, {}, {}
	}
	side :: proc "contextless" (file: []u8, type: Type, detail: u32) -> (value: Described) {
		value.type, value.detail = type, detail
		if type == .Record {
			if described, ok := record_type(file, detail); ok {
				name_set(&value.record, string_at(file, described.name_offset, described.name_count))
			}
		}
		return value
	}
	if a.parameter_count != b.parameter_count || a.parameter_count > PARAMETER_CAPACITY {
		return .Parameter_Count, 0, {detail = u32(a.parameter_count)}, {detail = u32(b.parameter_count)}
	}
	for number in 0 ..< u32(a.parameter_count) {
		expected = side(file, a.parameters[number], a.parameter_details[number])
		found = side(other_file, b.parameters[number], b.parameter_details[number])
		if expected.type != found.type {
			return .Parameter_Type, number + 1, expected, found
		}
		if !details_equal(file, other_file, expected, found) {
			return .Parameter_Detail, number + 1, expected, found
		}
	}
	expected = side(file, a.result, a.result_detail)
	found = side(other_file, b.result, b.result_detail)
	if expected.type != found.type {
		return .Result_Type, 0, expected, found
	}
	if !details_equal(file, other_file, expected, found) {
		return .Result_Detail, 0, expected, found
	}
	return .None, 0, {}, {}
}

// details_equal: two Records with equal descriptions, or two equal details.
@(private)
details_equal :: proc "contextless" (file, other_file: []u8, expected, found: Described) -> bool {
	if expected.type == .Record {
		return records_equal(file, expected.detail, other_file, found.detail)
	}
	return expected.detail == found.detail
}
