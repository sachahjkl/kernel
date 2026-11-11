package system

import "base:intrinsics"
import info "contract:boot_info"
import "contract:errors"
import "contract:isolated"
import module "contract:module"
import op "contract:operation"
import "contract:ring"

// The caller side of one description, three ways to call
// (docs/MODULE_CONTRACT.md, "Tables and bytes as parameters"):
//
//   call_direct      a module in this program (a module space): the
//                    registers of the call form, no copy.
//   call_isolated    a call host or a service: the same arguments go into
//                    the call region or into a lent memory object, and
//                    the answer comes back into the memory of the caller.
//
// The arguments are the same isolated.Argument records in each way: the
// export does not know which way ran.

// A way to the exports of a module in another program: a call host that
// this program started, or a connection to a service.
Call_Connection :: struct {
	program:       Handle, // The call host or the service: its state says if it stopped.
	ring_memory:   Handle,
	region_memory: Handle,
	files_memory:  Handle, // A call host: the page of the list of its files.
	calls:         ring.Ring,
	region:        []u8,
	tag:           u32,
}

// What an isolated call gives besides its integer result.
Call_Status :: enum u32 {
	Ok           = 0,
	Lend_Failed  = 1, // A handle of the arguments could not be lent: `lend` says why.
	No_Room      = 2, // The arguments do not fit in the call region: isolated.room_missing says which table.
	Ring_Full    = 3,
	Stopped      = 4, // The other program stopped during the call.
	Refused      = 5, // The other program gave a status that is not Ok: Bad_Export, Bad_Arguments, Bad_Handle.
	Wrong_Answer = 6, // The other program gave a count of a table that is smaller than the count on entry.
	Failed       = 7, // The export failed: its integer result is negative, and the error record is filled.
}

// call_direct calls an export of a module that is in this program, with
// the call form: an Integer and a Handle in a register, a Text as the
// address of its slice, a Record as its address, a Table or Bytes as the
// address of a table place over the memory of the argument. The export
// works in that memory: a Change table and an Append table are changed in
// place, and the count of an Append table is its new count. An export with
// an error record writes it at `error`.
call_direct :: proc "contextless" (file: []u8, address: uintptr, function: module.Function, arguments: []isolated.Argument, error: ^errors.Error_Record = nil) -> (result: i64) {
	function := function
	integers: [CALL_INTEGERS]u64
	places: [module.PARAMETER_CAPACITY]module.Table_Place
	slices: [module.PARAMETER_CAPACITY]isolated.Slice
	for type, index in function.parameters[:min(int(function.parameter_count), len(arguments))] {
		argument := &arguments[index]
		#partial switch type {
		case .Text:
			slices[index] = {u64(uintptr(raw_data(argument.text))), u64(len(argument.text))}
			integers[index] = u64(uintptr(&slices[index]))
		case .Record:
			integers[index] = u64(uintptr(raw_data(argument.record)))
		case .Table, .Bytes:
			size, _, _ := isolated.table_record(file, type, function.parameter_details[index])
			places[index] = {address = u64(uintptr(raw_data(argument.table.records))), count = argument.table.count, capacity = u64(len(argument.table.records)) / max(size, 1)}
			integers[index] = u64(uintptr(&places[index]))
		case:
			integers[index] = argument.integer
		}
	}
	local_error: errors.Error_Record
	if function.error_record != 0 {
		integers[function.parameter_count] = u64(uintptr(error != nil ? error : &local_error))
	}
	floats: [CALL_FLOATS]u64
	out: [CALL_RESULTS]u64
	export_call(address, &integers, &floats, &out)
	for type, index in function.parameters[:min(int(function.parameter_count), len(arguments))] {
		if isolated.is_table(type) && function.parameter_directions[index] == .Append {
			arguments[index].table.count = places[index].count
		}
	}
	return i64(out[0])
}

// call_isolated calls an export of a module in another program, through a
// connection. It lends the handles and the memory objects of the
// arguments, writes the argument record, waits for the answer, and copies
// the answer of each Change and Append table back into the memory of the
// caller. An export that fails gives a negative result and its error
// record at `error`.
call_isolated :: proc "contextless" (connection: ^Call_Connection, file: []u8, export: u32, arguments: []isolated.Argument, error: ^errors.Error_Record = nil) -> (result: i64, status: Call_Status) {
	function, described := module.function(file, export)
	if !described {
		return 0, .Refused
	}
	// lend writes the handles of the receiver in the arguments: the caller
	// keeps its own for the next call. (A Handle field of a Record is
	// written in the bytes of the record: give a copy of the record.)
	kept_integers: [module.PARAMETER_CAPACITY]u64
	kept_memories: [module.PARAMETER_CAPACITY]u64
	for argument, index in arguments[:min(len(arguments), module.PARAMETER_CAPACITY)] {
		kept_integers[index], kept_memories[index] = argument.integer, argument.table.memory
	}
	defer for &argument, index in arguments[:min(len(arguments), module.PARAMETER_CAPACITY)] {
		argument.integer, argument.table.memory = kept_integers[index], kept_memories[index]
	}
	lending: Lending
	defer lend_end(&lending)
	if lend(file, function, arguments, connection.ring_memory, &lending) != .Ok {
		return 0, .Lend_Failed
	}
	offset, size, _, error_place, encoded := isolated.encode(file, function, arguments, connection.region)
	if !encoded {
		return 0, .No_Room
	}
	connection.tag += 1
	if !send(&connection.calls.commands, ring.Record{kind = export, tag = connection.tag, values = {0 = offset, 1 = size}}) {
		return 0, .Ring_Full
	}
	for {
		wait := wait_begin()
		for _ in 0 ..< ring.CAPACITY {
			completion, has := receive(&connection.calls.completions)
			if !has {
				break
			}
			if completion.tag != connection.tag {
				continue
			}
			if isolated.Status(completion.kind) != .Ok {
				return 0, .Refused
			}
			result = i64(completion.values[0])
			if error_place.count != 0 && result < 0 {
				if error != nil {
					intrinsics.mem_copy_non_overlapping(error, raw_data(connection.region[error_place.start:]), size_of(errors.Error_Record))
				}
				return result, .Failed
			}
			if problem, _ := isolated.tables_return(file, function, arguments, connection.region, offset); problem != .None {
				return result, .Wrong_Answer
			}
			return result, .Ok
		}
		if state, _ := program_state(connection.program); state == .Stopped || state == .None {
			return 0, .Stopped
		}
		wait_records(&wait, &connection.calls.completions)
		if wait_spin(&wait) {
			continue
		}
		wait_end(&wait)
	}
}

// call_host_start starts a call host (the program "host" of the boot
// image) for one module, and maps the file of the module and of its
// imports in it, read-only: the call host has the call ring and the call
// region, and no other handle. image_memory is the handle of the boot
// image. On a failure of the load, load_error has the record that the call
// host wrote.
call_host_start :: proc "contextless" (image: []u8, image_memory: Handle, file: []u8, name: string, load_error: ^module.Load_Error) -> (connection: Call_Connection, status: Status) {
	files: [MODULE_SPACE_CAPACITY + IMPORT_CAPACITY]^info.Image_Entry
	source := Load_Source {
		image = image,
	}
	count := source_closure(source, file, &files)
	list_size := size_of(info.Image_Header) + count * size_of(info.Image_Entry)
	if count == 0 || list_size > PAGE_SIZE {
		return {}, .Bad_Operation
	}
	defer if status != .Ok {
		call_connection_end(&connection)
	}
	connection.files_memory = memory_create(1) or_return
	page_address := memory_map(connection.files_memory) or_return
	page := ([^]u8)(page_address)[:PAGE_SIZE]
	(^info.Image_Header)(page_address)^ = {magic = info.IMAGE_MAGIC, count = u32(count)}
	entries := ([^]info.Image_Entry)(raw_data(page[size_of(info.Image_Header):]))[:count]
	mappings: [MODULE_SPACE_CAPACITY + IMPORT_CAPACITY + 1]Mapping
	mappings[0] = {memory = connection.files_memory, address = isolated.FILE_ADDRESS}
	offset := u64(PAGE_SIZE)
	for item, index in files[:count] {
		if item.offset % PAGE_SIZE != 0 {
			memory_unmap(page_address)
			return connection, .Bad_Operation
		}
		entries[index] = item^
		entries[index].offset = offset
		pages := (item.size + PAGE_SIZE - 1) / PAGE_SIZE
		mappings[index + 1] = {memory = image_memory, address = isolated.FILE_ADDRESS + offset, first = item.offset / PAGE_SIZE, page_count = pages}
		offset += pages * PAGE_SIZE
	}
	memory_unmap(page_address)
	connection.ring_memory, connection.calls = ring_create() or_return
	connection.region_memory = memory_create(isolated.REGION_PAGES) or_return
	region_address := memory_map(connection.region_memory) or_return
	connection.region = ([^]u8)(region_address)[:isolated.REGION_PAGES * PAGE_SIZE]
	grants: [op.CONTEXT_HANDLES]Grant
	values: [op.CONTEXT_VALUES]u64
	grants[isolated.GRANT_RING] = {connection.ring_memory, {.Read, .Write}}
	grants[isolated.GRANT_REGION] = {connection.region_memory, {.Read, .Write}}
	values[isolated.VALUE_FILE_ADDRESS] = isolated.FILE_ADDRESS
	values[isolated.VALUE_FILE_SIZE] = offset
	connection.program = program_start(image_find(image, "host"), name, grants, values, {pages = 512, programs = 1, threads = 1, processor = 500_000, log_records = 100}, mappings[:count + 1]) or_return
	// The first completion says if the call host loaded the module.
	limit := time() + 5000
	for {
		wait := wait_begin()
		state, _ := program_state(connection.program)
		for _ in 0 ..< ring.CAPACITY {
			completion, has := receive(&connection.calls.completions)
			if !has {
				break
			}
			if completion.tag != 0 {
				continue
			}
			if isolated.Status(completion.kind) == .Ok {
				return connection, .Ok
			}
			if load_error != nil {
				intrinsics.mem_copy_non_overlapping(load_error, raw_data(connection.region), size_of(module.Load_Error))
			}
			return connection, .Bad_State
		}
		if state == .Stopped {
			return connection, .Bad_State
		}
		wait_records(&wait, &connection.calls.completions)
		if wait_end(&wait, limit) >= limit {
			return connection, .Bad_State
		}
	}
}

// service_connection asks the root service for a connection to the
// service with a name, through a ring to the root service (GRANT_ROOT): a
// ring of the grant Root_Ring or of the grant Connect.
service_connection :: proc "contextless" (requests: ^ring.Ring, tag: u32, name: string) -> (connection: Call_Connection, status: Status) {
	packed := name_pack(name)
	if !send(&requests.commands, ring.Record{kind = u32(Root_Command.Connect), tag = tag, values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}}) {
		return {}, .No_Slot
	}
	limit := time() + 5000
	for {
		for record in receive(&requests.completions) {
			if record.tag != tag {
				continue
			}
			if Status(record.kind) != .Ok {
				return {}, Status(record.kind)
			}
			connection = {program = Handle(record.values[0]), ring_memory = Handle(record.values[1]), region_memory = Handle(record.values[2])}
			defer if status != .Ok {
				call_connection_end(&connection)
			}
			connection.calls = ring_open(connection.ring_memory) or_return
			address := memory_map(connection.region_memory) or_return
			connection.region = ([^]u8)(address)[:memory_size(connection.region_memory) * PAGE_SIZE]
			return connection, .Ok
		}
		wait: Wait
		wait_records(&wait, &requests.completions)
		if wait_end(&wait, limit) >= limit {
			return {}, .Bad_State
		}
	}
}

// call_connection_end closes what this program holds of a connection. A
// call host stops: no handle names it. A service continues.
call_connection_end :: proc "contextless" (connection: ^Call_Connection) {
	if connection.calls.head != nil {
		ring_close(&connection.calls)
	}
	if connection.region != nil {
		memory_unmap(raw_data(connection.region))
	}
	for handle in ([4]Handle{connection.program, connection.ring_memory, connection.region_memory, connection.files_memory}) {
		if handle != 0 {
			close(handle)
		}
	}
	connection^ = {}
}
