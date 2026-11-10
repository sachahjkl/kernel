package system

import "contract:isolated"
import op "contract:operation"
import module "contract:module"
import "contract:ring"

// A service that serves its own exports: other programs call the exports of
// this program with isolated calls (package isolated), while it runs.
//
// The exports of a program have descriptions, as the exports of a module
// have: the caller reads them in the file of the program. This program
// reads them too, in the same file, to decode each argument record.
//
// The root service decides who calls. For each caller it makes one
// connection: a call ring and a call region. It names them on the service
// ring of this program (isolated.Service_Command).
//
//   service, _ := system.service_open(ctx)
//   for {
//       wait: system.Wait
//       system.service_wait(&wait, &service)
//       ... add the other things that the program waits for ...
//       system.wait_end(&wait)
//       system.service_run(&service) // The calls execute here, in this thread.
//   }
//
// A program with no grant to serve has a Service that is all zero:
// service_wait and service_run do nothing.

Connection :: struct {
	ring_memory:   Handle, // 0: the place is free.
	region_memory: Handle,
	calls:         ring.Ring,
	region:        []u8,
}

Service :: struct {
	file:        []u8, // The file of this program: the descriptions of its exports.
	names:       ring.Ring, // The service ring.
	connections: [isolated.SERVICE_CONNECTION_CAPACITY]Connection,
	connected:   int,
	calls:       u64, // The calls that this program executed.
}

service_open :: proc "contextless" (ctx: ^Context) -> (service: Service, ok: bool) {
	memory := ctx.handles[GRANT_SERVICE]
	if memory == 0 {
		return {}, false
	}
	names, status := ring_open(memory)
	if status != .Ok {
		return {}, false
	}
	service.file = ([^]u8)(uintptr(ctx.values[GRANT_VALUE_FILE_ADDRESS]))[:ctx.values[GRANT_VALUE_FILE_SIZE]]
	if module.validate(service.file) != .None {
		ring_close(&names)
		return {}, false
	}
	service.names = names
	return service, true
}

// service_wait adds the service to a wait list: the thread waits while no
// connection has a call, and while the root service names no connection.
service_wait :: proc "contextless" (wait: ^Wait, service: ^Service) {
	if service.names.head == nil {
		return
	}
	wait_records(wait, &service.names.commands)
	for &connection in service.connections {
		if connection.calls.head != nil {
			wait_records(wait, &connection.calls.commands)
		}
	}
}

// service_run adds and removes the connections that the root service
// names, then executes the calls that wait. It gives the count of calls.
service_run :: proc "contextless" (service: ^Service) -> (calls: int) {
	if service.names.head == nil {
		return 0
	}
	for _ in 0 ..< ring.CAPACITY {
		command, has_command := receive(&service.names.commands)
		if !has_command {
			break
		}
		ring_memory, region_memory := Handle(command.values[0]), Handle(command.values[1])
		#partial switch isolated.Service_Command(command.kind) {
		case .Connect:
			if !connection_add(service, ring_memory, region_memory) {
				close(ring_memory)
				close(region_memory)
			}
		case .Disconnect:
			for &connection in service.connections {
				if connection.calls.head != nil && connection.ring_memory == ring_memory {
					ring_close(&connection.calls)
					memory_unmap(raw_data(connection.region))
					close(connection.ring_memory)
					close(connection.region_memory)
					connection = {}
					service.connected -= 1
				}
			}
		}
	}
	for &connection in service.connections {
		if connection.calls.head == nil {
			continue
		}
		for _ in 0 ..< ring.CAPACITY {
			command, has_command := receive(&connection.calls.commands)
			if !has_command {
				break
			}
			send(&connection.calls.completions, export_serve(service.file, op.PROGRAM_BASE, connection.region, command))
			calls += 1
		}
	}
	service.calls += u64(calls)
	return calls
}

@(private)
connection_add :: proc "contextless" (service: ^Service, ring_memory, region_memory: Handle) -> bool {
	for &connection in service.connections {
		if connection.calls.head != nil {
			continue
		}
		calls, ring_status := ring_open(ring_memory)
		if ring_status != .Ok {
			return false
		}
		bytes, region_status := memory_map(region_memory)
		if region_status != .Ok {
			ring_close(&calls)
			return false
		}
		connection = {
			ring_memory   = ring_memory,
			region_memory = region_memory,
			calls         = calls,
			region        = ([^]u8)(bytes)[:memory_size(region_memory) * PAGE_SIZE],
		}
		service.connected += 1
		return true
	}
	return false
}

// export_serve executes one isolated call: it calls the export that the
// command record names, in the module file at base, and gives the
// completion record. The description of the export says how to read the
// argument record; the caller does not send the types. The entry of a
// module is not callable.
export_serve :: proc "contextless" (file: []u8, base: u64, region: []u8, command: ring.Record) -> (completion: ring.Record) {
	completion.tag = command.tag
	head, _ := module.header(file)
	function, described := module.function(file, command.kind)
	address, has_address := module.export_address(file, uintptr(base), command.kind)
	if !described || !has_address || command.kind == head.entry_export {
		completion.kind = u32(isolated.Status.Bad_Export)
		return completion
	}
	integers: [CALL_INTEGERS]u64
	slices: [module.PARAMETER_CAPACITY]isolated.Slice
	if !isolated.decode(function, command.values[0], command.values[1], region, &integers, &slices) {
		completion.kind = u32(isolated.Status.Bad_Arguments)
		return completion
	}
	floats: [CALL_FLOATS]u64
	out: [CALL_RESULTS]u64
	export_call(address, &integers, &floats, &out)
	// For a Text result, this is the count; the text is in the call region.
	if function.result != .None {
		completion.values[0] = out[0]
	}
	return completion
}
