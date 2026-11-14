#+build !freestanding
package system

import "modus:contract/blake3"
import info "modus:contract/boot_info"
import module "modus:contract/module"
import "core:testing"

// The details of a load (docs/MODULE_CONTRACT.md, section 8, "The table of
// error details"): each import that is missing or has the wrong hash, not
// only the first, in the order of the load.

// A module with no code: a header and a table of imports.
@(private = "file")
module_with_imports :: proc(storage: []u8, imports: [][32]u8) -> []u8 {
	Directory :: [module.TABLE_COUNT]module.Table_Entry
	directory: Directory
	offset := u64(size_of(module.Header) + size_of(Directory))
	directory[module.Table_Kind.Imports] = {offset = offset, count = u32(len(imports) + 1), record_size = size_of(module.Import)}
	offset += size_of(module.Import) // Index 0 is the empty entry.
	for hash in imports {
		(^module.Import)(&storage[offset])^ = {hash = hash}
		offset += size_of(module.Import)
	}
	(^module.Header)(&storage[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	(^Directory)(&storage[size_of(module.Header)])^ = directory
	return storage[:offset]
}

// An image of the form of the boot image: each entry names a hash, and holds
// the bytes of a file.
@(private = "file")
Image_Item :: struct {
	name: string,
	hash: [32]u8,
	file: []u8,
}

@(private = "file")
image_of :: proc(storage: []u8, items: []Image_Item) -> []u8 {
	(^info.Image_Header)(&storage[0])^ = {magic = info.IMAGE_MAGIC, count = u32(len(items))}
	entries := ([^]info.Image_Entry)(&storage[size_of(info.Image_Header)])[:len(items)]
	offset := u64(size_of(info.Image_Header) + len(items) * size_of(info.Image_Entry))
	for item, index in items {
		entries[index] = {hash = item.hash, offset = offset, size = u64(len(item.file))}
		copy(entries[index].name[:], item.name)
		copy(storage[offset:], item.file)
		offset += u64(len(item.file))
	}
	return storage[:offset]
}

// agenda imports planner, a module that no file has (missing), and
// calendar; planner imports a module that no file has (absent); the file
// of the entry of calendar is another file (wrong hash). The load meets
// absent first (in planner), then missing, then calendar.
@(test)
load_details_name_each_import_that_is_wrong :: proc(t: ^testing.T) {
	missing := [32]u8{0 = 0x11}
	absent := [32]u8{0 = 0x22}
	other_storage, planner_storage, calendar_storage, agenda_storage: [1024]u8
	other := module_with_imports(other_storage[:], nil)
	planner := module_with_imports(planner_storage[:], [][32]u8{absent})
	calendar_hash := blake3.hash(module_with_imports(calendar_storage[:], [][32]u8{missing})) // A file that the image does not hold.
	agenda := module_with_imports(agenda_storage[:], [][32]u8{blake3.hash(planner), missing, calendar_hash})
	image_storage: [4096]u8
	image := image_of(image_storage[:], []Image_Item{{"agenda", blake3.hash(agenda), agenda}, {"planner", blake3.hash(planner), planner}, {"calendar", calendar_hash, other}})
	source := Load_Source{image = image}

	records: [2]module.Load_Error
	details := Table_To_Append(module.Load_Error){records = &records[0], count = 0, capacity = 2}
	load_source_problems(source, agenda, &details)
	testing.expect_value(t, details.count, 3) // Three problems; the table of 2 places says that one did not fit.
	testing.expect_value(t, records[0].stage, module.Load_Stage.Find)
	testing.expect_value(t, module.name_get(&records[0].module.name), "planner")
	testing.expect(t, records[0].imported.hash == absent, "the first: the import of planner that no file has")
	testing.expect_value(t, records[1].stage, module.Load_Stage.Find)
	testing.expect_value(t, module.name_get(&records[1].module.name), "agenda")
	testing.expect(t, records[1].imported.hash == missing, "the second: the import of agenda that no file has")

	all: [4]module.Load_Error
	every := Table_To_Append(module.Load_Error){records = &all[0], count = 0, capacity = 4}
	load_source_problems(source, agenda, &every)
	testing.expect_value(t, every.count, 3)
	testing.expect_value(t, all[2].stage, module.Load_Stage.Read)
	testing.expect_value(t, all[2].file_error, module.Error.None) // The file is valid: its hash differs.
	testing.expect_value(t, module.name_get(&all[2].imported.name), "calendar")
	testing.expect_value(t, all[3].stage, module.Load_Stage.None)
}

// A module that two modules import, and a sound graph: no detail.
@(test)
load_details_of_a_sound_graph :: proc(t: ^testing.T) {
	leaf_storage, middle_storage, top_storage: [1024]u8
	leaf := module_with_imports(leaf_storage[:], nil)
	middle := module_with_imports(middle_storage[:], [][32]u8{blake3.hash(leaf)})
	top := module_with_imports(top_storage[:], [][32]u8{blake3.hash(middle), blake3.hash(leaf)})
	image_storage: [4096]u8
	image := image_of(image_storage[:], []Image_Item{{"top", blake3.hash(top), top}, {"middle", blake3.hash(middle), middle}, {"leaf", blake3.hash(leaf), leaf}})
	records: [2]module.Load_Error
	details := Table_To_Append(module.Load_Error){records = &records[0], count = 0, capacity = 2}
	load_source_problems(Load_Source{image = image}, top, &details)
	testing.expect_value(t, details.count, 0)
}
