package root

import "modus:contract/blake3"
import "modus:contract/pointer_pictures"
import "modus:support/system"

// The resources of the boot image (docs/ARCHITECTURE.md, U2b): files that
// are not modules, each with its name and the hash of its bytes. This
// service gives one to a program as a read-only mapping, after it checked
// the hash.

// resource_mapping finds the resource with this name, checks the hash of
// its bytes against its entry, and gives the read-only mapping of its pages
// at an address of the program that receives it, with its size. It gives
// false for a resource that the image does not have, and false with a line
// on the log for a resource whose hash is wrong.
resource_mapping :: proc "contextless" (name: string, address: u64, receiver: string) -> (mapping: system.Mapping, size: u64, ok: bool) {
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
	system.log("root: the resource ", name, " (", system.Size{entry.size, .Bytes}, ", its hash checked in ", system.Duration{spent / 1000, .Microseconds}, ") is given to ", system.Module_Name{receiver}, ", read-only")
	// No flag: the mapping has the right Read only.
	return {memory = image_memory, address = address, first = entry.offset / system.PAGE_SIZE, page_count = (entry.size + system.PAGE_SIZE - 1) / system.PAGE_SIZE}, entry.size, true
}

// pointer_theme_choice gives the names of the pointer theme files that the
// compositor receives, in order: the theme of the owner when the build had
// its input, then the theme of the system (docs/POINTERS.md, section 5).
// The setting "pointer_theme" of the system (modus:contract/settings)
// chooses between them while the compositor runs: "owner" is the first one
// that the image has, "system" the last.
pointer_theme_choice :: proc "contextless" () -> []string {
	return pointer_pictures.RESOURCE_PREFERENCE[:]
}
