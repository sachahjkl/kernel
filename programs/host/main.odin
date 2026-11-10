// The call host: a program that loads one module and executes the isolated
// calls of its exports (property 19, package isolated).
//
// The caller starts one call host per module, with two grants: the call
// ring and the call region. The call host has no other handle, so the module
// can reach nothing else (property 2). A fault in the module stops this
// program only.
package host

import op "contract:operation"
import "contract:isolated"
import module "contract:module"
import "contract:ring"
import "support:system"

file: []u8
region: []u8

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

	// The caller mapped the file of the module. This program loads it: it
	// checks the file, then it maps the segments.
	file = ([^]u8)(uintptr(ctx.values[isolated.VALUE_FILE_ADDRESS]))[:ctx.values[isolated.VALUE_FILE_SIZE]]
	if _, status := system.module_load(file, op.MODULE_BASE); status != .Ok {
		system.log("host: cannot load the module")
		system.stop(1)
	}
	system.log("host: ready, ", u64(module.count(file, .Exports) - 1), " exports")

	for {
		for _ in 0 ..< ring.CAPACITY {
			command, ok := system.receive(&queue.commands)
			if !ok {
				break
			}
			system.send(&queue.completions, system.export_serve(file, op.MODULE_BASE, region, ring_memory, command))
		}
		wait: system.Wait
		system.wait_records(&wait, &queue.commands)
		system.wait_end(&wait)
	}
}
