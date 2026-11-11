package system

import "contract:errors"
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
	caller:        Name, // The name of the caller, as the root service names it.
	grant:         u64, // What the root service grants to the caller here (isolated.CALLER_AMOUNT_MASK, isolated.CALLER_PERSON).
}

// The connection of the call that runs: see service_caller.
@(private)
serving: ^Connection

// service_caller gives the connection of the call that runs, in an export
// that a service serves: the name of the caller and its grant. It gives nil
// outside such a call. The caller cannot choose either: the root service
// writes them.
service_caller :: proc "contextless" () -> ^Connection {
	return serving
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
			if !connection_add(service, ring_memory, region_memory, name_unpack({command.values[2], command.values[3], command.values[4], command.values[5]}), command.values[6]) {
				close(ring_memory)
				close(region_memory)
			}
		case .Grant:
			for &connection in service.connections {
				if connection.calls.head != nil && connection.ring_memory == ring_memory {
					connection.grant = command.values[6]
				}
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
			serving = &connection
			send(&connection.calls.completions, export_serve(service.file, op.PROGRAM_BASE, connection.region, connection.ring_memory, command, false))
			serving = nil
			calls += 1
		}
	}
	service.calls += u64(calls)
	return calls
}

@(private)
connection_add :: proc "contextless" (service: ^Service, ring_memory, region_memory: Handle, caller: Name, grant: u64) -> bool {
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
			caller        = caller,
			grant         = grant,
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
// ring_memory is the memory of the call ring. The caller lends each handle
// through it; this code proves each handle before the call (handle_state),
// and closes each one after it. The caller also revokes what it lent
// (lend_end). An export never receives a handle that this program holds for
// itself.
// A refusal (Bad_Arguments, Bad_Handle) has an error record in the values
// of the completion: the argument and why (finding W8 of the hostile read).
// memory_objects_allowed: a table in a lent memory object is taken. A call
// host takes it; a service does not (finding W1): the caller can revoke the
// lent memory while the export runs, and the fault of the export would stop
// the service for each of its callers. A call host serves one caller.
export_serve :: proc "contextless" (file: []u8, base: u64, region: []u8, ring_memory: Handle, command: ring.Record, memory_objects_allowed: bool) -> (completion: ring.Record) {
	completion.tag = command.tag
	head, _ := module.header(file)
	function, described := module.function(file, command.kind)
	address, has_address := module.export_address(file, uintptr(base), command.kind)
	if !described || !has_address || command.kind == head.entry_export {
		completion.kind = u32(isolated.Status.Bad_Export)
		return completion
	}
	prepared: isolated.Call
	refusal: errors.Error_Record
	refused :: proc "contextless" (completion: ^ring.Record, status: isolated.Status, refusal: errors.Error_Record) -> ring.Record {
		completion.kind = u32(status)
		completion.values = transmute([7]u64)refusal
		return completion^
	}
	if !isolated.decode(file, function, command.values[0], command.values[1], region, &prepared, &refusal) {
		return refused(&completion, .Bad_Arguments, refusal)
	}
	// The proof of each handle, and the deferred close of each one that came
	// through the call ring, come first: each refusal after this point
	// closes them (note 1 of the second hostile read: the refusal of a
	// memory object to a service left them open).
	lent := prepared.lent[:prepared.lent_count]
	came: [module.HANDLE_CAPACITY]bool
	first_unproven := -1
	held_rights: Rights
	for item, index in lent {
		_, rights, through := handle_state(Handle(item.handle), ring_memory)
		came[index] = through
		if first_unproven < 0 && !(through && transmute(Rights)item.rights <= rights) {
			first_unproven, held_rights = index, rights
		}
	}
	// Close what the caller lent, after the call or in place of it.
	defer for item, index in lent {
		if came[index] {
			close(Handle(item.handle))
		}
	}
	if !memory_objects_allowed && prepared.mapping_count > 0 {
		item := prepared.mappings[0]
		return refused(&completion, .Bad_Arguments, errors.error_make(.Bad_Value, .None, i64(item.parameter + 1), i64(item.handle), 0))
	}
	// A handle that did not come through the call ring was not lent for
	// this call; one that came lacks a right of the description (note 4).
	if first_unproven >= 0 {
		item := lent[first_unproven]
		if !came[first_unproven] {
			return refused(&completion, .Bad_Handle, errors.error_make(.Handle_Absent, .Lent_Handles, 0, i64(item.handle)))
		}
		return refused(&completion, .Bad_Handle, errors.error_make(.Handle_Rights, .None, 0, i64(item.handle), i64(item.rights), i64(transmute(u32)held_rights)))
	}
	// A table names a memory object, not another kind of object (N3 of the
	// hostile read).
	for item in prepared.mappings[:prepared.mapping_count] {
		if kind, _, _ := handle_state(Handle(item.handle)); kind != .Memory {
			return refused(&completion, .Bad_Handle, errors.error_make(.Handle_Kind, .None, i64(item.parameter + 1), i64(item.handle), i64(op.Object_Kind.Memory), i64(kind)))
		}
	}
	// A table in a memory object (form iii): map it for the time of the
	// export, Write only for Change and Append, and check that the records
	// are inside it.
	mapped: [module.PARAMETER_CAPACITY]rawptr
	defer for address_of_mapping in mapped {
		if address_of_mapping != nil {
			memory_unmap(address_of_mapping)
		}
	}
	// Only the pages of the records, at the same address at each call.
	for item, index in prepared.mappings[:prepared.mapping_count] {
		memory := Handle(item.handle)
		object_size := memory_size(memory) * PAGE_SIZE
		if item.start > object_size || item.size > object_size - item.start {
			return refused(&completion, .Bad_Arguments, errors.error_make(.Out_Of_Range, .Bytes, i64(item.parameter + 1), i64(min(item.start, 1 << 62) + min(item.size, 1 << 62)), i64(object_size)))
		}
		// A work-around of a fault of the kernel (a mapping with no chosen
		// address never reuses its range of addresses, given to the agent of
		// work/scheduler): the same address at each call.
		mapping_address := isolated.TABLE_ADDRESS + u64(item.parameter) * isolated.TABLE_SPAN
		if item.size == 0 {
			prepared.places[item.parameter].address = mapping_address // An empty table: nothing to reach.
			continue
		}
		first := item.start / PAGE_SIZE
		pages := (item.start + item.size + PAGE_SIZE - 1) / PAGE_SIZE - first
		start, status := memory_map(memory, item.writable ? {.Write} : {}, 0, mapping_address, first, pages)
		if status != .Ok {
			return refused(&completion, .Bad_Arguments, errors.error_make(.Refused, .None, i64(item.parameter + 1), 0, 0, i64(status)))
		}
		mapped[index] = start
		prepared.places[item.parameter].address = u64(uintptr(start)) + item.start % PAGE_SIZE
	}
	floats: [CALL_FLOATS]u64
	out: [CALL_RESULTS]u64
	export_call(address, &prepared.registers, &floats, &out)
	isolated.result_store(function, &prepared, region)
	isolated.counts_store(function, &prepared, region)
	// A failure: the error record names the export. The export does not
	// know its own number.
	if prepared.error.count != 0 && i64(out[0]) < 0 {
		error := (^errors.Error_Record)(raw_data(region[prepared.error.start:]))
		error.operation = i64(command.kind)
	}
	// For a Text or Table result, this is the count; the bytes are in the
	// call region.
	if function.result == .Integer || function.result == .Text || function.result == .Table {
		completion.values[0] = out[0]
	}
	return completion
}

// The copies that a caller made for one isolated call: see lend.
Lending :: struct {
	copies: [module.HANDLE_CAPACITY]Handle,
	count:  int,
}

// lend prepares the handles of the arguments of an isolated call: the
// caller side of module.Type.Handle. For each Handle argument, for each
// Handle field of each Record argument, and for the memory object of each
// table argument that names one (Table_Argument.memory_handle), it makes a copy of the handle in
// this program with the rights of the description, and gives the receiver
// a handle that comes from the copy, through the call ring. It writes the
// handle of the receiver in place of the handle of the caller: give it
// copies of the records. Call it before isolated.encode.
//   file:        the module of the export: the descriptions.
//   ring_memory: the memory of the call ring.
// The handle of the caller needs the Give right and each right of the
// description. After the call, or in place of it, call lend_end: it
// revokes each copy. What the receiver has from the call ends then: its
// handle if it kept it, and each mapping that it made with it. The kernel
// does this; the receiver cannot refuse. If one handle fails, lend ends
// the copies itself.
lend :: proc "contextless" (file: []u8, function: module.Function, arguments: []isolated.Argument, ring_memory: Handle, lending: ^Lending) -> (status: Status) {
	function := function
	lending.count = 0
	lend_one_handle :: proc "contextless" (ring_memory: Handle, handle: Handle, wanted: Rights, lending: ^Lending) -> (result: Handle, status: Status) {
		if handle == 0 {
			return 0, .Ok
		}
		if lending.count == len(lending.copies) {
			return 0, .No_Slot
		}
		kind, held, _ := handle_state(handle)
		if kind == .None {
			return 0, .Bad_Handle
		}
		if !(wanted + {.Give} <= held) {
			return 0, .No_Right
		}
		copy := give(0, handle, wanted + {.Give}) or_return
		lending.copies[lending.count] = copy
		lending.count += 1
		return give(ring_memory, copy, wanted)
	}
	each: for type, index in function.parameters[:min(int(function.parameter_count), len(arguments))] {
		#partial switch type {
		case .Handle:
			result: Handle
			result, status = lend_one_handle(ring_memory, Handle(arguments[index].integer), transmute(Rights)function.parameter_details[index], lending)
			if status != .Ok {
				break each
			}
			arguments[index].integer = u64(result)
		case .Table, .Bytes:
			// A table in a memory object: the rights of the copy are the
			// direction (property 20).
			if arguments[index].table.memory_handle != 0 {
				result: Handle
				result, status = lend_one_handle(ring_memory, Handle(arguments[index].table.memory_handle), isolated.direction_rights(function.parameter_directions[index]), lending)
				if status != .Ok {
					break each
				}
				arguments[index].table.memory_handle = u64(result)
			}
		case .Record:
			described, ok := module.record_type(file, function.parameter_details[index])
			if !ok || len(arguments[index].record) != int(described.size) {
				status = .Bad_Operation
				break each
			}
			for number in 0 ..< described.field_count {
				item, _ := module.field(file, described, number)
				if item.type != .Handle {
					continue
				}
				place := (^Handle)(&arguments[index].record[item.offset])
				place^, status = lend_one_handle(ring_memory, place^, transmute(Rights)item.detail, lending)
				if status != .Ok {
					break each
				}
			}
		}
	}
	if status != .Ok {
		lend_end(lending)
	}
	return status
}

// lend_end takes back what lend gave: see lend.
lend_end :: proc "contextless" (lending: ^Lending) {
	for copy in lending.copies[:lending.count] {
		handle_revoke(copy)
		close(copy)
	}
	lending.count = 0
}
