// The call host: a program that loads one module and executes the isolated
// calls of its exports (package isolated): the arguments travel as records,
// not as text.
//
// The caller starts one call host per module, with two grants: the call
// ring and the call region. The call host has no other handle, so the module
// can reach nothing else: a program holds only the handles that it was
// given. A fault in the module stops this
// program only.
package host

import op "contract:operation"
import "contract:isolated"
import module "contract:module"
import "contract:ring"
import "support:system"

file: []u8
region: []u8
space: system.Module_Space // The module and its imports, in this program.

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	ring_memory := ctx.handles[isolated.GRANT_RING]
	region_memory := ctx.handles[isolated.GRANT_REGION]
	queue, ring_status := system.ring_open(ring_memory)
	bytes, region_status := system.memory_map(region_memory)
	if ring_status != .Ok || region_status != .Ok {
		system.log("host: no call ring or no call region")
		system.stop(1)
	}
	region = ([^]u8)(bytes)[:system.memory_size(region_memory) * system.PAGE_SIZE]

	// The caller mapped the files of the module and of its imports, and the
	// replacements that apply. This program loads the module: the loader
	// checks the hash of each file, then maps the segments. The caller
	// waits for the first completion.
	files := ([^]u8)(uintptr(ctx.values[isolated.VALUE_FILE_ADDRESS]))[:ctx.values[isolated.VALUE_FILE_SIZE]]
	replacements: []module.Replacement
	if offset, count := ctx.values[isolated.VALUE_REPLACEMENT_OFFSET], ctx.values[isolated.VALUE_REPLACEMENT_COUNT]; count <= system.REPLACEMENT_CAPACITY && offset <= system.PAGE_SIZE - count * size_of(module.Replacement) && offset + count * size_of(module.Replacement) <= u64(len(files)) {
		replacements = ([^]module.Replacement)(raw_data(files[offset:]))[:count]
	}
	entries := system.image_entries(files)
	if len(entries) > 0 && entries[0].offset <= u64(len(files)) && entries[0].size <= u64(len(files)) - entries[0].offset {
		file = files[entries[0].offset:][:entries[0].size]
	}
	space.source = {image = files, replacements = replacements}
	space.next = op.MODULE_BASE
	// The caller learns the end of the load in the first completion: the
	// record of a failure is data, in the call region.
	error := (^module.Load_Error)(raw_data(region))
	index, loaded := system.module_space_load(&space, file, error)
	if !loaded {
		buffer: [512]u8
		writer := system.Writer{buffer = buffer[:]}
		system.load_error_text(&writer, error)
		system.log("host: cannot load the module: ", system.written(&writer))
		system.send(&queue.completions, ring.Record{kind = u32(isolated.Status.Load_Failed)})
		system.stop(1)
	}
	base := space.modules[index].base
	system.log("host: ready, ", u64(module.count(file, .Exports) - 1), " exports")
	system.send(&queue.completions, ring.Record{kind = u32(isolated.Status.Ok)})

	for {
		for _ in 0 ..< ring.CAPACITY {
			command, ok := system.receive(&queue.commands)
			if !ok {
				break
			}
			system.send(&queue.completions, system.export_serve(file, base, region, ring_memory, command, true))
		}
		wait: system.Wait
		system.wait_records(&wait, &queue.commands)
		system.wait_end(&wait)
	}
}
