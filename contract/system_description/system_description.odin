// The system description (docs/TRUSTED_BOOT.md): the one canonical list of
// what a boot volume starts. It names the kernel, then each module and each
// resource of the boot image, in the order of the boot image, each with its
// kind, its size and its BLAKE3 hash. The signing key of the person who
// owns the machine signs its hash; the boot program verifies the signature
// and each hash before it starts the kernel, and the root service checks
// the boot image against it again before it starts the first program.
//
// The file, all numbers little-endian:
//
//   Header                       16 bytes
//   Entry, header.entry_count times, 80 bytes each
//
// and no other byte. Entry 0 is the kernel. The modules follow, then the
// resources. The boot image holds the description and its signature as its
// last two resources, which the description does not list: a file cannot
// hold its own hash.
//
// The reader refuses every other form, so one system has one description
// and one hash: an unused field is zero, a name has zero bytes after it.
package system_description

import "contract:blake3"
import info "contract:boot_info"

MAGIC :: u64(0x5243534544535953) // The bytes "SYSDESCR".
VERSION :: 1
NAME_SIZE :: info.IMAGE_NAME_SIZE
// A bound for the reader: a boot image of today has about 90 entries.
ENTRY_CAPACITY :: 4096

PUBLIC_KEY_SIZE :: 32
SIGNATURE_SIZE :: 64
SIGNED_MESSAGE_SIZE :: 64
// The first 32 bytes of the signed message, with zero bytes after it. A
// signing key can sign other things later (grants, a newer format): the
// label keeps a signature of one of them from being taken for another.
SIGNATURE_LABEL :: "system description signature 1"
#assert(len(SIGNATURE_LABEL) < 32)

// The names of the two last resources of the boot image.
RESOURCE_DESCRIPTION :: "system_description"
RESOURCE_SIGNATURE :: "system_description_signature"
// The name of entry 0. It is fixed, whatever file the kernel was built
// from: a name that the builder chose would give one system two
// descriptions, and so two hashes.
KERNEL_ENTRY_NAME :: "kernel"

// The public key of the test signing key: RFC 8032, section 7.1, TEST 1.
// Its private key is in that document and in this repository: a system
// that it signs is not trusted, and the boot display says so.
TEST_PUBLIC_KEY :: [PUBLIC_KEY_SIZE]u8{0xd7, 0x5a, 0x98, 0x01, 0x82, 0xb1, 0x0a, 0xb7, 0xd5, 0x4b, 0xfe, 0xd3, 0xc9, 0x64, 0x07, 0x3a, 0x0e, 0xe1, 0x72, 0xf3, 0xda, 0xa6, 0x23, 0x25, 0xaf, 0x02, 0x1a, 0x68, 0xf7, 0x07, 0x51, 0x1a}

Entry_Kind :: enum u32 {
	None     = 0,
	Kernel   = 1,
	Module   = 2,
	Resource = 3,
}

Header :: struct {
	magic:       u64,
	version:     u32,
	entry_count: u32,
}
#assert(size_of(Header) == 16)

Entry :: struct {
	name:     [NAME_SIZE]u8, // The name of the entry of the boot image, or of the kernel module; zero bytes after it.
	kind:     Entry_Kind,
	reserved: u32, // Zero.
	size:     u64,
	hash:     blake3.Hash, // The BLAKE3 hash of the bytes of the file.
}
#assert(size_of(Entry) == 80)

// Why a check failed. Each fault names one entry of the description,
// except Not_Valid, Image_Not_Valid and Count_Differs.
Check_Fault :: enum u32 {
	None                = 0,
	Not_Valid           = 1, // The description does not follow its format.
	Image_Not_Valid     = 2, // The tables of the boot image do not fit in it, or its two last resources are not the description and its signature.
	Count_Differs       = 3, // The boot image has more or fewer entries than the description lists.
	Name_Differs        = 4,
	Kind_Differs        = 5, // A module of the description is a resource of the boot image, or the reverse.
	Size_Differs        = 6,
	Hash_Differs        = 7, // The bytes of the file have another hash.
	Stated_Hash_Differs = 8, // The entry of the boot image states another hash: the loader gives that hash to the program as its identity.
	Outside_Image       = 9, // The entry of the boot image points outside the image.
}

// The result of a check: zero when each entry agrees.
Check :: struct {
	fault:         Check_Fault,
	index:         u32, // The entry of the description, from 0 (the kernel).
	name:          [NAME_SIZE]u8, // The name in the description.
	expected_size: u64, // From the description; for Count_Differs, the count of the description.
	found_size:    u64, // From the boot image or the kernel file; for Count_Differs, the count of the image.
	expected_hash: blake3.Hash,
	found_hash:    blake3.Hash, // For Stated_Hash_Differs, the hash that the entry of the image states.
}

@(rodata)
fault_sentences := [Check_Fault]string {
	.None                = "each entry agrees with the system description",
	.Not_Valid           = "the system description does not follow its format",
	.Image_Not_Valid     = "the boot image has no whole tables, or its two last resources are not the system description and its signature",
	.Count_Differs       = "the boot image has another count of entries than the system description",
	.Name_Differs        = "the entry of the boot image at this place has another name",
	.Kind_Differs        = "the entry of the boot image at this place is of another kind",
	.Size_Differs        = "does not have the size of the system description",
	.Hash_Differs        = "does not have the hash of the system description",
	.Stated_Hash_Differs = "states in the boot image another hash than the system description",
	.Outside_Image       = "points outside the boot image",
}

// name_of gives the bytes of a name before its first zero byte.
name_of :: proc "contextless" (name: ^[NAME_SIZE]u8) -> string {
	count := 0
	for count < NAME_SIZE && name[count] != 0 {
		count += 1
	}
	return string(name^[:count])
}

// name_valid says if a name has one byte at least, then zero bytes only:
// one name has one form.
@(private)
name_valid :: proc "contextless" (name: ^[NAME_SIZE]u8) -> bool {
	ended := false
	for character in name^ {
		if character == 0 {
			ended = true
		} else if ended {
			return false
		}
	}
	return name[0] != 0 && ended
}

// entries gives the entries of a description, after it checked the whole
// format: the magic, the version, the exact size, the kernel first, the
// modules before the resources, the names and the zero fields.
entries :: proc "contextless" (description: []u8) -> (list: []Entry, valid: bool) {
	if len(description) < size_of(Header) {
		return nil, false
	}
	header := (^Header)(raw_data(description))^
	if header.magic != MAGIC || header.version != VERSION || header.entry_count == 0 || header.entry_count > ENTRY_CAPACITY {
		return nil, false
	}
	if len(description) != size_of(Header) + int(header.entry_count) * size_of(Entry) {
		return nil, false
	}
	list = ([^]Entry)(raw_data(description[size_of(Header):]))[:header.entry_count]
	resources_started := false
	for &entry, index in list {
		if entry.reserved != 0 || !name_valid(&entry.name) {
			return nil, false
		}
		if index == 0 {
			if entry.kind != .Kernel || name_of(&entry.name) != KERNEL_ENTRY_NAME {
				return nil, false
			}
			continue
		}
		if entry.kind == .Resource {
			resources_started = true
		} else if entry.kind != .Module || resources_started {
			return nil, false
		}
	}
	return list, true
}

// signed_message gives the bytes that the signing key signs for a
// description: the label, then the BLAKE3 hash of the description.
signed_message :: proc "contextless" (description: []u8) -> (message: [SIGNED_MESSAGE_SIZE]u8) {
	label := SIGNATURE_LABEL
	for index in 0 ..< len(label) {
		message[index] = label[index]
	}
	hash := blake3.hash(description)
	for index in 0 ..< blake3.HASH_SIZE {
		message[32 + index] = hash[index]
	}
	return
}

// trust_resources gives the bytes of the description and of its signature:
// the two last resources of the boot image, with their names.
trust_resources :: proc "contextless" (image: []u8) -> (description, signature: []u8, found: bool) {
	_, resources, valid := info.image_tables(image)
	if !valid || len(resources) < 2 {
		return
	}
	description_entry := &resources[len(resources) - 2]
	signature_entry := &resources[len(resources) - 1]
	if name_of(&description_entry.name) != RESOURCE_DESCRIPTION || name_of(&signature_entry.name) != RESOURCE_SIGNATURE {
		return
	}
	description_found, signature_found: bool
	description, description_found = info.image_entry_bytes(image, description_entry)
	signature, signature_found = info.image_entry_bytes(image, signature_entry)
	found = description_found && signature_found && len(signature) == SIGNATURE_SIZE
	return
}

// kernel_check compares the kernel module file with entry 0 of the
// description.
kernel_check :: proc "contextless" (description: []u8, kernel_file: []u8) -> (result: Check) {
	list, valid := entries(description)
	if !valid {
		result.fault = .Not_Valid
		return
	}
	entry := &list[0]
	result = {name = entry.name, expected_size = entry.size, expected_hash = entry.hash, found_size = u64(len(kernel_file))}
	if entry.size != u64(len(kernel_file)) {
		result.fault = .Size_Differs
		return
	}
	result.found_hash = blake3.hash(kernel_file)
	if result.found_hash != entry.hash {
		result.fault = .Hash_Differs
		return
	}
	return {}
}

// image_check compares each module and each resource of a boot image,
// except the two last resources, with the entries after the kernel, in
// order: the name, the kind, the size, the hash of the bytes, and the hash
// that the image states. It hashes every byte of every file, so its time
// grows with the size of the boot image.
image_check :: proc "contextless" (description: []u8, image: []u8) -> (result: Check) {
	list, valid := entries(description)
	if !valid {
		result.fault = .Not_Valid
		return
	}
	modules, resources, image_valid := info.image_tables(image)
	if !image_valid || len(resources) < 2 {
		result.fault = .Image_Not_Valid
		return
	}
	// The two last resources are the description and its signature, by
	// their names: no other resource escapes the list.
	if name_of(&resources[len(resources) - 2].name) != RESOURCE_DESCRIPTION || name_of(&resources[len(resources) - 1].name) != RESOURCE_SIGNATURE {
		result.fault = .Image_Not_Valid
		return
	}
	listed_resources := resources[:len(resources) - 2]
	if len(list) - 1 != len(modules) + len(listed_resources) {
		result.fault = .Count_Differs
		result.expected_size = u64(len(list) - 1)
		result.found_size = u64(len(modules) + len(listed_resources))
		return
	}
	for &entry, position in list[1:] {
		image_entry: ^info.Image_Entry
		kind: Entry_Kind
		if position < len(modules) {
			image_entry = &modules[position]
			kind = .Module
		} else {
			image_entry = &listed_resources[position - len(modules)]
			kind = .Resource
		}
		result = {index = u32(position + 1), name = entry.name, expected_size = entry.size, expected_hash = entry.hash, found_size = image_entry.size}
		switch {
		case image_entry.name != entry.name:
			result.fault = .Name_Differs
		case entry.kind != kind:
			result.fault = .Kind_Differs
		case image_entry.size != entry.size:
			result.fault = .Size_Differs
		}
		if result.fault != .None {
			return
		}
		bytes, inside := info.image_entry_bytes(image, image_entry)
		if !inside {
			result.fault = .Outside_Image
			return
		}
		// The bytes first: a changed file is reported as such, whatever its
		// entry states.
		result.found_hash = blake3.hash(bytes)
		if result.found_hash != entry.hash {
			result.fault = .Hash_Differs
			return
		}
		if image_entry.hash != entry.hash {
			result.fault = .Stated_Hash_Differs
			result.found_hash = image_entry.hash
			return
		}
	}
	return {}
}

// hexadecimal writes the 64 lowercase hexadecimal digits of a hash.
hexadecimal :: proc "contextless" (hash: blake3.Hash) -> (digits: [2 * blake3.HASH_SIZE]u8) {
	characters := "0123456789abcdef"
	for value, index in hash {
		digits[2 * index] = characters[value >> 4]
		digits[2 * index + 1] = characters[value & 15]
	}
	return
}
