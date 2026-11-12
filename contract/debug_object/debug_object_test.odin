#+build !freestanding
package debug_object

import "core:testing"

// The object of a small module: two procedures, one export with no
// package, two files, and rows with a gap between the procedures.
//   strings: "fault::three" (0, 12), "entry" (12, 5),
//            "programs/fault/main.odin" (17, 24), "base:runtime/print.odin" (41, 23)
@(private = "file")
STRINGS :: "fault::threeentryprograms/fault/main.odinbase:runtime/print.odin"

@(private = "file")
object_of :: proc(procedures: []Procedure, files: []File, lines: []Line) -> []u8 {
	parts := Encode_Parts {
		module_hash = {0 = 0xAB, 31 = 0xCD},
		procedures  = procedures,
		files       = files,
		lines       = lines,
		strings     = transmute([]u8)string(STRINGS),
	}
	bytes := make([]u8, encoded_size(parts), context.temp_allocator)
	if !encode(parts, bytes) {
		return nil
	}
	return bytes
}

@(private = "file")
sample_object :: proc() -> []u8 {
	procedures := make([]Procedure, 2, context.temp_allocator)
	procedures[0] = {start = 0x1470, size = 0x18, name_offset = 0, name_count = 12, package_count = 5}
	procedures[1] = {start = 0x14d0, size = 0x73, name_offset = 12, name_count = 5}
	files := make([]File, 3, context.temp_allocator)
	files[1] = {path_offset = 17, path_count = 24}
	files[2] = {path_offset = 41, path_count = 23}
	lines := make([]Line, 5, context.temp_allocator)
	lines[0] = {offset = 0x1470, place = row_place(1, 14)}
	lines[1] = {offset = 0x1478, place = row_place(1, 15)}
	lines[2] = {offset = 0x1488}
	lines[3] = {offset = 0x14d0, place = row_place(2, 30)}
	lines[4] = {offset = 0x1543}
	return object_of(procedures, files, lines)
}

@(test)
a_procedure_and_its_line_are_found_by_offset :: proc(t: ^testing.T) {
	object := sample_object()
	testing.expect_value(t, check(object), Fault.None)
	place := place_of(object, 0x147B)
	testing.expect_value(t, place.procedure, "fault::three")
	testing.expect_value(t, place.procedure[:place.package_count], "fault")
	testing.expect_value(t, place.offset_in_procedure, u64(0xB))
	testing.expect_value(t, place.file, "programs/fault/main.odin")
	testing.expect_value(t, place.line, u32(15))
	// The first byte and the last byte of a procedure.
	testing.expect_value(t, place_of(object, 0x1470).line, u32(14))
	testing.expect_value(t, place_of(object, 0x1487).procedure, "fault::three")
	export := place_of(object, 0x1500)
	testing.expect_value(t, export.procedure, "entry")
	testing.expect_value(t, export.package_count, 0)
	testing.expect_value(t, export.file, "base:runtime/print.odin")
	hash, valid := module_hash_of(object)
	testing.expect(t, valid && hash[0] == 0xAB && hash[31] == 0xCD, "the object names its module")
}

@(test)
an_offset_outside_each_procedure_has_no_name :: proc(t: ^testing.T) {
	object := sample_object()
	for offset in ([]u64{0, 0x146F, 0x1488, 0x14CF, 0x1543, 0xFFFF_FFFF, 1 << 40}) {
		place := place_of(object, offset)
		testing.expectf(t, place.procedure == "" && place.file == "", "the offset %x has no procedure and no line, not %v", offset, place)
	}
}

@(test)
a_hostile_object_is_refused :: proc(t: ^testing.T) {
	object := sample_object()
	changed :: proc(source: []u8, offset: int, value: u32) -> []u8 {
		copy_of := make([]u8, len(source), context.temp_allocator)
		copy(copy_of, source)
		(^u32)(rawptr(raw_data(copy_of[offset:])))^ = value
		return copy_of
	}
	procedures_at := size_of(Header)
	files_at := procedures_at + 2 * size_of(Procedure)
	lines_at := files_at + 3 * size_of(File)
	cases := []struct {
		object: []u8,
		fault:  Fault,
	} {
		{object[:size_of(Header) - 1], .Too_Small},
		{object[:len(object) - 1], .Size_Differs},
		{changed(object, 0, 0x12345678), .Not_A_Debug_Object},
		{changed(object, 8, 2), .Version},
		{changed(object, 12, PROCEDURE_CAPACITY + 1), .Too_Many},
		{changed(object, 12, 3), .Size_Differs}, // One more procedure than the bytes hold.
		{changed(object, 60, 1), .Reserved},
		{changed(object, procedures_at + size_of(Procedure), 0x1480), .Procedure_Order}, // Starts inside the procedure before it.
		{changed(object, procedures_at + 4, 0), .Procedure_Order}, // No byte.
		{changed(object, procedures_at + 8, 60), .Procedure_Name}, // A name past the strings.
		{changed(object, procedures_at + 12, 12 | 4 << 16), .Procedure_Package}, // "faul" then "t:".
		{changed(object, files_at, 1), .File_Zero},
		{changed(object, files_at + size_of(File) + 4, 200), .File_Path},
		{changed(object, lines_at + size_of(Line), 0x1470), .Line_Order},
		{changed(object, lines_at + 4, row_place(3, 14)), .Line_File}, // A file that the table does not have.
		{changed(object, lines_at + size_of(Line) * 2 + 4, 7), .Line_File}, // A line with the file 0.
		{changed(object, lines_at + size_of(Line) * 4 + 4, row_place(1, 0)), .Line_File}, // The last row with a file and the line 0.
	}
	for item, index in cases {
		testing.expectf(t, check(item.object) == item.fault, "case %d: %v, not %v", index, check(item.object), item.fault)
		// A reader that did not check reads inside the object: no fault.
		_ = place_of(item.object, 0x1478)
	}
	// The last row names a file, with a line: the line table has no end.
	last := changed(object, lines_at + size_of(Line) * 4 + 4, row_place(1, 9))
	testing.expect_value(t, check(last), Fault.Line_End)
}

@(test)
an_empty_object_is_valid :: proc(t: ^testing.T) {
	files := make([]File, 1, context.temp_allocator)
	object := object_of(nil, files, nil)
	testing.expect_value(t, check(object), Fault.None)
	testing.expect_value(t, place_of(object, 0x1000), Place{})
}
