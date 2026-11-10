// The call host: a program that loads one module and executes the isolated
// calls of its exports (property 19, package isolated).
//
// The caller starts one call host per module, with two grants: the call
// ring and the call region. The call host has no other handle, so the module
// can reach nothing else (property 2). A fault in the module stops this
// program only.
package host

import op "../../kernel/operation"
import "../../isolated"
import module "../../module"
import "../../ring"
import "../../system"

file: []u8
entry_export: u32
region: []u8

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	ring_memory := ctx.handles[isolated.GRANT_RING]
	region_memory := ctx.handles[isolated.GRANT_REGION]
	calls, ring_status := system.memory_map(ring_memory)
	bytes, region_status := system.memory_map(region_memory)
	if ring_status != .Ok || region_status != .Ok || system.memory_size(ring_memory) != ring.PAGE_COUNT {
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
	head, _ := module.header(file)
	entry_export = head.entry_export
	system.log("host: ready, ", u64(module.count(file, .Exports) - 1), " exports")

	queue := (^ring.Ring)(calls)
	for {
		served := false
		for _ in 0 ..< ring.CAPACITY {
			command, ok := ring.pop(&queue.commands)
			if !ok {
				break
			}
			completion := ring.Record {
				tag = command.tag,
			}
			completion.kind = u32(serve(command, &completion.values))
			ring.push(&queue.completions, completion)
			served = true
		}
		if served {
			system.wake(ring_memory)
		}
		system.wait()
	}
}

// serve executes one call. The description of the export says how to read
// the argument record; the caller does not send the types.
serve :: proc "contextless" (command: ring.Record, results: ^[7]u64) -> isolated.Status {
	function, described := module.function(file, command.kind)
	address, has_address := module.export_address(file, uintptr(op.MODULE_BASE), command.kind)
	if !described || !has_address || command.kind == entry_export {
		return .Bad_Export
	}
	integers: [system.CALL_INTEGERS]u64
	slices: [module.PARAMETER_CAPACITY]isolated.Slice
	if !isolated.decode(function, command.values[0], command.values[1], region, &integers, &slices) {
		return .Bad_Arguments
	}
	floats: [system.CALL_FLOATS]u64
	out: [system.CALL_RESULTS]u64
	system.export_call(address, &integers, &floats, &out)
	// For a Text result, this is the count; the text is in the call region.
	if function.result != .None {
		results[0] = out[0]
	}
	return .Ok
}
