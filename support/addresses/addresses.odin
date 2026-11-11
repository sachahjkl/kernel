// The addresses of a program as a developer tool shows them (docs/TOOLS.md):
// the kind of each mapping, an address as "module + offset", the near
// export of an address, and the band of an address space with its gaps
// folded. Pure code: no kernel operation, no allocation, so the kernel tool
// tests it on the host.
package addresses

import module "contract:module"
import op "contract:operation"

// What a mapping is, from the facts of the kernel: its flags, and the
// module record that holds its address.
Kind :: enum u8 {
	Memory           = 0, // Memory of the program: its stacks, its tables, what it made.
	Module_Code      = 1,
	Module_Constants = 2,
	Module_Data      = 3,
	Thread_Area      = 4, // The thread record and the kernel ring of a thread.
	Device           = 5, // A framebuffer, boot data, the registers of a device.
	Shared           = 6, // Memory that another program or handle also names: a ring, a region.
}

@(rodata)
KIND_NAMES := [Kind]string {
	.Memory           = "memory",
	.Module_Code      = "module code",
	.Module_Constants = "module constants",
	.Module_Data      = "module data",
	.Thread_Area      = "thread area",
	.Device           = "device",
	.Shared           = "shared",
}

// module_of gives the module record that holds an address, and the offset
// of the address in it. index is -1 when no record holds it.
module_of :: proc "contextless" (address: u64, modules: []op.Module_Record) -> (index: int, offset: u64) {
	for &item, number in modules {
		if item.size != 0 && address >= item.base && address - item.base < item.size {
			return number, address - item.base
		}
	}
	return -1, 0
}

kind_of :: proc "contextless" (mapping: op.Program_Mapping, modules: []op.Module_Record) -> Kind {
	switch {
	case .Device in mapping.flags:
		return .Device
	case .Thread_Area in mapping.flags:
		return .Thread_Area
	}
	if index, _ := module_of(mapping.address, modules); index >= 0 {
		switch {
		case .Execute in mapping.flags:
			return .Module_Code
		case .Write in mapping.flags:
			return .Module_Data
		}
		return .Module_Constants
	}
	return .Shared in mapping.flags ? .Shared : .Memory
}

// near_export gives the export of a module file with the highest address
// at or below an address of the module at base: its name and the distance
// from it. ok is false when no export is at or below the address.
near_export :: proc "contextless" (file: []u8, base: u64, address: u64) -> (name: string, distance: u64, ok: bool) {
	best := u64(0)
	for index in 1 ..< module.count(file, .Exports) {
		at, has := module.export_address(file, uintptr(base), index)
		if !has || u64(at) > address {
			continue
		}
		function, described := module.function(file, index)
		if !described || (ok && u64(at) < best) {
			continue
		}
		name = module.string_at(file, function.name_offset, function.name_count)
		best = u64(at)
		ok = true
	}
	return name, address - best, ok
}

// One part of the band of an address space: a mapping, or a folded gap.
Segment :: struct {
	x:       int,
	width:   int,
	mapping: int, // The index of the mapping. -1: a folded gap.
}

// band gives the parts of a band of `width` pixels for mappings in the
// order of their addresses. A gap between two mappings is a folded gap of
// gap_width pixels; each mapping has least_width pixels and a part of the
// rest in proportion to its pages. It gives the count of segments.
band :: proc "contextless" (mappings: []op.Program_Mapping, width, gap_width, least_width: int, segments: []Segment) -> int {
	gaps := 0
	pages := u64(0)
	for &item, index in mappings {
		pages += item.page_count
		if index > 0 && mappings[index - 1].address + mappings[index - 1].page_count * 4096 != item.address {
			gaps += 1
		}
	}
	rest := max(width - gaps * gap_width - len(mappings) * least_width, 0)
	count := 0
	x := 0
	given := 0 // The pixels of the rest that the mappings before took.
	taken := u64(0) // Their pages.
	for &item, index in mappings {
		if count + 2 > len(segments) {
			break
		}
		if index > 0 && mappings[index - 1].address + mappings[index - 1].page_count * 4096 != item.address {
			segments[count] = {x = x, width = gap_width, mapping = -1}
			count += 1
			x += gap_width
		}
		// The share of the rest up to this mapping, so that the parts add to
		// the rest with no loss from the rounding.
		taken += item.page_count
		share := pages == 0 ? 0 : int(u64(rest) * taken / pages)
		part := least_width + share - given
		given = share
		segments[count] = {x = x, width = part, mapping = index}
		count += 1
		x += part
	}
	return count
}
