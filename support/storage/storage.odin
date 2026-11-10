// The client of the storage service: what a program compiles in to keep its
// data in its private store.
//
// The root service makes the connection when it starts the program, and
// gives it in the context (GRANT_ roles below): a call ring, a call region,
// a handle that reads the state of the storage service, and the file of the
// storage service, mapped read-only at FILE_ADDRESS. The calls are isolated
// calls (contract/isolated): this package finds each export by its name in
// that file, and encodes the arguments with its description.
//
//   client, ok := storage.open(ctx)
//   storage.write(&client, "note", bytes)   // One commit, on the disk at the return.
//   storage.read(&client, "note", buffer[:])
//
// When the root service revokes the grant, the handles of the connection
// end: a call gives Gone, and the program continues.
package storage

import "contract:isolated"
import module "contract:module"
import "contract:ring"
import "support:system"

GRANT_RING :: 7 // Memory: the call ring.
GRANT_REGION :: 8 // Memory: the call region.
GRANT_SERVICE :: 9 // The storage service, with the right Read: its state.
VALUE_FILE_SIZE :: 3 // The size of the file of the storage service.
FILE_ADDRESS :: 0x0000_3100_0000_0000 // Where the root service maps that file.

// The answer of an export of the storage service that is not a generation
// or a size: one of these numbers.
ERROR_NO_STORE :: -1 // The caller has no grant of a store.
ERROR_NO_BUDGET :: -2 // The store would have more blocks than its limit.
ERROR_NAME :: -3 // The name of the object is empty, too long, or has a zero byte.
ERROR_TOO_LARGE :: -4 // The object would have more than 32 blocks.
ERROR_FULL :: -5 // No place for one more object or store, or no free block on the disk.
ERROR_DISK :: -6 // The block service reported an error.
ERROR_ABSENT :: -7 // The store has no object with this name.
ERROR_DAMAGED :: -8 // A block of the object, or the table of the store, has a wrong check.

Client :: struct {
	ring_memory:   system.Handle,
	region_memory: system.Handle,
	service:       system.Handle,
	calls:         ring.Ring,
	region:        []u8,
	file:          []u8,
	tag:           u32,
	gone:          bool,
}

Status :: enum {
	Ok,
	Gone, // The connection ended: the grant was revoked, or the storage service stopped.
	Refused, // The storage service refused the call: see isolated.Status.
	Damaged, // The storage service has the object and cannot give its bytes: a block has a wrong check, or the disk gave an error.
}

open :: proc "contextless" (ctx: ^system.Context) -> (client: Client, ok: bool) {
	client.ring_memory = ctx.handles[GRANT_RING]
	client.region_memory = ctx.handles[GRANT_REGION]
	client.service = ctx.handles[GRANT_SERVICE]
	if client.ring_memory == 0 || client.region_memory == 0 {
		return {}, false
	}
	status: system.Status
	if client.calls, status = system.ring_open(client.ring_memory); status != .Ok {
		return {}, false
	}
	address, map_status := system.memory_map(client.region_memory)
	if map_status != .Ok {
		return {}, false
	}
	client.region = ([^]u8)(address)[:system.memory_size(client.region_memory) * system.PAGE_SIZE]
	file_address := uintptr(FILE_ADDRESS)
	client.file = ([^]u8)(file_address)[:ctx.values[VALUE_FILE_SIZE]]
	if module.validate(client.file) != .None {
		return {}, false
	}
	return client, true
}

// connected says if the connection is still there. The kernel ends the
// handles of the connection at a revocation: the program learns it here,
// before it uses the memory.
connected :: proc "contextless" (client: ^Client) -> bool {
	if client.gone {
		return false
	}
	kind, _, _ := system.handle_state(client.ring_memory)
	region_kind, _, _ := system.handle_state(client.region_memory)
	state, _ := system.program_state(client.service)
	if kind != .Memory || region_kind != .Memory || state == .Stopped || state == .None {
		client.gone = true
	}
	return !client.gone
}

// call makes one isolated call of the export with a name. For a Text result,
// text has the bytes in the call region: copy them before the next call.
call :: proc "contextless" (client: ^Client, name: string, arguments: []isolated.Argument) -> (value: i64, text: []u8, status: Status) {
	if !connected(client) {
		return 0, nil, .Gone
	}
	head, _ := module.header(client.file)
	export: u32
	function: module.Function
	for index in 1 ..< module.count(client.file, .Exports) {
		candidate, described := module.function(client.file, index)
		if described && index != head.entry_export && module.string_at(client.file, candidate.name_offset, candidate.name_count) == name {
			export, function = index, candidate
			break
		}
	}
	if export == 0 {
		return 0, nil, .Refused
	}
	offset, size, buffer, ok := isolated.encode(client.file, function, arguments, client.region)
	if !ok {
		return 0, nil, .Refused
	}
	client.tag += 1
	if !system.send(&client.calls.commands, ring.Record{kind = export, tag = client.tag, values = {0 = offset, 1 = size}}) {
		return 0, nil, .Refused
	}
	for {
		// A revocation and the stop of the service are events.
		wait := system.wait_begin()
		for _ in 0 ..< ring.CAPACITY {
			completion, has := system.receive(&client.calls.completions)
			if !has {
				break
			}
			if completion.tag != client.tag {
				continue
			}
			if isolated.Status(completion.kind) != .Ok {
				return 0, nil, .Refused
			}
			if function.result == .Text {
				result, complete := isolated.result_text(client.region, buffer, completion.values[0])
				if !complete {
					return i64(completion.values[0]), nil, .Refused
				}
				return i64(completion.values[0]), result, .Ok
			}
			return i64(completion.values[0]), nil, .Ok
		}
		if !connected(client) {
			return 0, nil, .Gone
		}
		system.wait_records(&wait, &client.calls.completions)
		system.wait_end(&wait)
	}
}

// write replaces an object of the store with bytes, in one commit. The
// result is the generation of the commit, or a negative number (see the
// export write of the storage service).
write :: proc "contextless" (client: ^Client, name: string, data: []u8) -> (generation: i64, status: Status) {
	arguments := [2]isolated.Argument{{text = transmute([]u8)name}, {text = data}}
	generation, _, status = call(client, "write", arguments[:])
	return generation, status
}

// read copies the bytes of an object of the store into result. found is
// false when the store has no such object. The status Damaged says that
// the store has the object and that its bytes did not come: the caller
// must not take it for an empty object.
read :: proc "contextless" (client: ^Client, name: string, result: []u8) -> (bytes: []u8, found: bool, status: Status) {
	arguments := [1]isolated.Argument{{text = transmute([]u8)name}}
	size: i64
	size, _, status = call(client, "size", arguments[:])
	if status == .Ok && size == ERROR_DAMAGED {
		return nil, false, .Damaged
	}
	if status != .Ok || size < 0 {
		return nil, false, status
	}
	text: []u8
	_, text, status = call(client, "read", arguments[:])
	if status != .Ok {
		return nil, false, status
	}
	if i64(len(text)) != size {
		return nil, false, .Damaged
	}
	count := copy(result, text)
	return result[:count], true, .Ok
}
