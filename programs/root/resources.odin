package root

import "contract:blake3"
import "contract:pointer_pictures"
import "support:system"

// The resources of the boot image (docs/ARCHITECTURE.md, U2b): files that
// are not modules, each with its name and the hash of its bytes. This
// service gives one to a program as a read-only mapping, after it checked
// the hash.

// resource_mapping finds the resource with this name, checks the hash of
// its bytes against its entry, and gives the read-only mapping of its pages
// at an address of the program, with its size. It gives false, with a line
// on the log, for a resource that the image does not have or whose hash is
// wrong.
resource_mapping :: proc "contextless" (name: string, address: u64) -> (mapping: system.Mapping, size: u64, ok: bool) {
	entry := system.image_resource_find(image, name)
	if entry == nil {
		return {}, 0, false
	}
	start := system.nanoseconds()
	if blake3.hash(image[entry.offset:][:entry.size]) != entry.hash {
		system.log_in("programs", .Warning, "root: the resource ", name, " does not have the hash of its entry: not given")
		return {}, 0, false
	}
	spent := system.nanoseconds() - start
	system.log("root: the resource ", name, ", ", entry.size, " bytes, its hash checked in ", spent / 1000, " us")
	// No flag: the mapping has the right Read only.
	return {memory = image_memory, address = address, first = entry.offset / system.PAGE_SIZE, page_count = (entry.size + system.PAGE_SIZE - 1) / system.PAGE_SIZE}, entry.size, true
}

// pointer_theme_choice gives the names of the pointer theme files, in the
// order in which the compositor takes the first one that the image has:
// the theme of the owner when the build had its input, else the theme of
// the system (decision of the owner, 2026-11-11). A setting of the person
// can change this order later: it is the one place of the choice.
pointer_theme_choice :: proc "contextless" () -> []string {
	return pointer_pictures.RESOURCE_PREFERENCE[:]
}
