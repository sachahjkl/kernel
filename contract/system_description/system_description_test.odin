#+build !freestanding
package system_description

import "contract:blake3"
import info "contract:boot_info"
import "core:testing"

@(private = "file")
Named_File :: struct {
	name: string,
	file: []u8,
}

@(private = "file")
entry_of :: proc(name: string, kind: Entry_Kind, file: []u8) -> (entry: Entry) {
	copy(entry.name[:NAME_SIZE - 1], name)
	entry.kind = kind
	entry.size = u64(len(file))
	entry.hash = blake3.hash(file)
	return
}

@(private = "file")
description_of :: proc(list: []Entry) -> []u8 {
	bytes := make([]u8, size_of(Header) + len(list) * size_of(Entry), context.temp_allocator)
	header := Header{magic = MAGIC, version = VERSION, entry_count = u32(len(list))}
	copy(bytes, (cast([^]u8)&header)[:size_of(Header)])
	if len(list) > 0 {
		copy(bytes[size_of(Header):], (cast([^]u8)raw_data(list))[:len(list) * size_of(Entry)])
	}
	return bytes
}

// image_of writes a boot image as the tool does: the header, the two
// tables, then each file.
@(private = "file")
image_of :: proc(files: []Named_File, module_count: int) -> []u8 {
	table := make([]info.Image_Entry, len(files), context.temp_allocator)
	image := make([dynamic]u8, size_of(info.Image_Header) + len(files) * size_of(info.Image_Entry), context.temp_allocator)
	for item, index in files {
		copy(table[index].name[:info.IMAGE_NAME_SIZE - 1], item.name)
		table[index].hash = blake3.hash(item.file)
		table[index].offset = u64(len(image))
		table[index].size = u64(len(item.file))
		append(&image, ..item.file)
	}
	header := info.Image_Header{magic = info.IMAGE_MAGIC, count = u32(module_count), resource_count = u32(len(files) - module_count)}
	copy(image[:], (cast([^]u8)&header)[:size_of(header)])
	copy(image[size_of(info.Image_Header):], (cast([^]u8)raw_data(table))[:len(table) * size_of(info.Image_Entry)])
	return image[:]
}

// A small system: a kernel, two modules, one resource, and the boot image
// with the description and a signature of 64 bytes as its last resources.
@(private = "file")
System :: struct {
	kernel:      []u8,
	description: []u8,
	image:       []u8,
}

@(private = "file")
system_make :: proc() -> (system: System) {
	kernel := []u8{1, 2, 3, 4, 5, 6, 7, 8}
	alpha := make([]u8, 3000, context.temp_allocator)
	for &value, index in alpha {
		value = u8(index % 251)
	}
	beta := []u8{9, 9, 9}
	gamma := []u8{42}
	list := []Entry{entry_of("kernel", .Kernel, kernel), entry_of("alpha", .Module, alpha), entry_of("beta", .Module, beta), entry_of("gamma", .Resource, gamma)}
	description := description_of(list)
	signature := make([]u8, SIGNATURE_SIZE, context.temp_allocator)
	files := []Named_File{{"alpha", alpha}, {"beta", beta}, {"gamma", gamma}, {RESOURCE_DESCRIPTION, description}, {RESOURCE_SIGNATURE, signature}}
	return {kernel = kernel, description = description, image = image_of(files, 2)}
}

@(private = "file")
copy_of :: proc(bytes: []u8) -> []u8 {
	result := make([]u8, len(bytes), context.temp_allocator)
	copy(result, bytes)
	return result
}

@(test)
a_system_that_agrees_passes :: proc(t: ^testing.T) {
	system := system_make()
	list, valid := entries(system.description)
	testing.expect(t, valid)
	testing.expect_value(t, len(list), 4)
	description, signature, found := trust_resources(system.image)
	testing.expect(t, found)
	testing.expect_value(t, len(description), len(system.description))
	testing.expect_value(t, len(signature), SIGNATURE_SIZE)
	testing.expect_value(t, kernel_check(description, system.kernel).fault, Check_Fault.None)
	testing.expect_value(t, image_check(description, system.image).fault, Check_Fault.None)
}

@(test)
one_changed_byte_names_its_entry :: proc(t: ^testing.T) {
	system := system_make()
	modules, _, _ := info.image_tables(system.image)
	image := copy_of(system.image)
	// The last byte of alpha, in the second half of its third chunk.
	image[modules[0].offset + modules[0].size - 1] ~= 1
	result := image_check(system.description, image)
	testing.expect_value(t, result.fault, Check_Fault.Hash_Differs)
	testing.expect_value(t, result.index, 1)
	testing.expect_value(t, name_of(&result.name), "alpha")
	testing.expect(t, result.expected_hash != result.found_hash)
	kernel := copy_of(system.kernel)
	kernel[0] ~= 0x80
	kernel_result := kernel_check(system.description, kernel)
	testing.expect_value(t, kernel_result.fault, Check_Fault.Hash_Differs)
	testing.expect_value(t, kernel_result.index, 0)
}

@(test)
the_image_entries_must_agree :: proc(t: ^testing.T) {
	system := system_make()
	// The entry of beta states another hash: the bytes are the same.
	{
		image := copy_of(system.image)
		modules, _, _ := info.image_tables(image)
		modules[1].hash[0] ~= 1
		result := image_check(system.description, image)
		testing.expect_value(t, result.fault, Check_Fault.Stated_Hash_Differs)
		testing.expect_value(t, name_of(&result.name), "beta")
	}
	// An entry that points outside the image.
	{
		image := copy_of(system.image)
		_, resources, _ := info.image_tables(image)
		resources[0].offset = u64(len(image))
		testing.expect_value(t, image_check(system.description, image).fault, Check_Fault.Outside_Image)
	}
	// One more resource than the description lists.
	{
		description, signature, _ := trust_resources(system.image)
		files := []Named_File{{"alpha", system.image[size_of(info.Image_Header) + 5 * size_of(info.Image_Entry):][:3000]}, {"beta", {9, 9, 9}}, {"gamma", {42}}, {"delta", {7}}, {RESOURCE_DESCRIPTION, description}, {RESOURCE_SIGNATURE, signature}}
		image := image_of(files, 2)
		result := image_check(system.description, image)
		testing.expect_value(t, result.fault, Check_Fault.Count_Differs)
		testing.expect_value(t, result.expected_size, 3)
		testing.expect_value(t, result.found_size, 4)
	}
	// The description is not one of the two last resources.
	{
		description, signature, _ := trust_resources(system.image)
		files := []Named_File{{"beta", {9, 9, 9}}, {RESOURCE_DESCRIPTION, description}, {RESOURCE_SIGNATURE, signature}, {"gamma", {42}}}
		_, _, found := trust_resources(image_of(files, 1))
		testing.expect(t, !found)
	}
}

@(private = "file")
refused :: proc(t: ^testing.T, description: []u8, why: string) {
	_, valid := entries(description)
	testing.expectf(t, !valid, "a description with %s is valid", why)
	testing.expect_value(t, image_check(description, {}).fault, Check_Fault.Not_Valid)
}

@(private = "file")
at :: proc(description: []u8, index: int) -> ^Entry {
	return (^Entry)(raw_data(description[size_of(Header) + index * size_of(Entry):]))
}

@(test)
one_description_has_one_form :: proc(t: ^testing.T) {
	system := system_make()
	{
		description := copy_of(system.description)
		description[0] ~= 1
		refused(t, description, "another magic")
	}
	{
		description := make([]u8, len(system.description) + 1, context.temp_allocator)
		copy(description, system.description)
		refused(t, description, "one more byte")
	}
	{
		description := copy_of(system.description)
		at(description, 0).kind = .Module
		refused(t, description, "a module first")
	}
	{
		description := copy_of(system.description)
		at(description, 1).kind = .Resource
		refused(t, description, "a module after a resource")
	}
	{
		description := copy_of(system.description)
		at(description, 2).reserved = 1
		refused(t, description, "a reserved field that is not zero")
	}
	{
		description := copy_of(system.description)
		at(description, 3).name[10] = 'x'
		refused(t, description, "a byte after the end of a name")
	}
	refused(t, description_of(nil), "no entry")
}

@(test)
the_signed_message_is_the_label_and_the_hash :: proc(t: ^testing.T) {
	system := system_make()
	message := signed_message(system.description)
	testing.expect_value(t, string(message[:len(SIGNATURE_LABEL)]), SIGNATURE_LABEL)
	for value in message[len(SIGNATURE_LABEL):32] {
		testing.expect_value(t, value, 0)
	}
	hash := blake3.hash(system.description)
	testing.expect(t, string(message[32:]) == string(hash[:]))
	digits := hexadecimal(hash)
	testing.expect_value(t, len(digits), 64)
}
