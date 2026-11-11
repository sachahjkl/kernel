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

import "contract:errors"
import "contract:fixed_addresses"
import "contract:isolated"
import module "contract:module"
import "contract:ring"
import "support:system"

GRANT_RING :: 7 // Memory: the call ring.
GRANT_REGION :: 8 // Memory: the call region.
GRANT_SERVICE :: 9 // The storage service, with the right Read: its state.
VALUE_FILE_SIZE :: 3 // The size of the file of the storage service.
FILE_ADDRESS :: fixed_addresses.STORAGE_FILE_ADDRESS // Where the root service maps that file.

// The answer of an export of the storage service that is not a generation
// or a size: one of these numbers. The error record of the call says more
// (contract/errors): the client gives it to its program.
ERROR_NO_STORE :: -1 // The caller has no grant of a store.
ERROR_NO_BUDGET :: -2 // The store would have more blocks than its limit.
ERROR_NAME :: -3 // The name of the object is empty, too long, or has a zero byte.
ERROR_TOO_LARGE :: -4 // The object would have more than 32 blocks.
ERROR_FULL :: -5 // No place for one more object or store, or no free block on the disk.
ERROR_DISK :: -6 // The block service reported an error.
ERROR_ABSENT :: -7 // The store has no object with this name.
ERROR_DAMAGED :: -8 // A block of the object, or the table of the store, has a wrong check.
ERROR_NO_VERSION :: -9 // The object has no version of this generation.
ERROR_PERSON :: -10 // The call names another store, and the caller does not act for the person.

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
	Failed, // The export answered a negative number: the error record says why.
	Too_Small, // The bytes do not fit in the buffer of the caller: the count of the bytes is the result.
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
// When the export answers a negative number, the status is Failed and error
// has its error record, as the storage service wrote it.
call :: proc "contextless" (client: ^Client, name: string, arguments: []isolated.Argument, error: ^errors.Error_Record = nil) -> (value: i64, text: []u8, status: Status) {
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
	offset, size, buffer, error_place, ok := isolated.encode(client.file, function, arguments, client.region)
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
			if i64(completion.values[0]) < 0 && error_place.count != 0 {
				// The service wrote it: values only, read as values.
				if error != nil {
					error^ = (^errors.Error_Record)(raw_data(client.region[error_place.start:]))^
				}
				return i64(completion.values[0]), nil, .Failed
			}
			if function.result == .Text {
				result, complete := isolated.result_text(client.region, buffer, completion.values[0])
				if !complete {
					return i64(completion.values[0]), nil, .Refused
				}
				return i64(completion.values[0]), result, .Ok
			}
			if function.result == .Table {
				// The records as bytes: the caller reads them with the record of
				// the export. A table that did not fit gives the rows that did.
				described, described_ok := module.record_type(client.file, function.result_detail)
				if !described_ok {
					return 0, nil, .Refused
				}
				records, _ := isolated.result_table(client.region, buffer, completion.values[0], u64(described.size))
				return i64(completion.values[0]), records, .Ok
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
// result is the generation of the commit, or a negative number with the
// status Failed and the error record (see the export write of the storage
// service).
write :: proc "contextless" (client: ^Client, name: string, data: []u8, error: ^errors.Error_Record = nil) -> (generation: i64, status: Status) {
	arguments := [2]isolated.Argument{{text = transmute([]u8)name}, {text = data}}
	generation, _, status = call(client, "write", arguments[:], error)
	return generation, status
}

// read copies the bytes of an object of the store into result. found is
// false when the store has no such object. The status Damaged says that
// the store has the object and that its bytes did not come: the caller
// must not take it for an empty object.
read :: proc "contextless" (client: ^Client, name: string, result: []u8, error: ^errors.Error_Record = nil) -> (bytes: []u8, found: bool, status: Status) {
	arguments := [1]isolated.Argument{{text = transmute([]u8)name}}
	size: i64
	size, _, status = call(client, "size", arguments[:], error)
	if status == .Failed && size == ERROR_DAMAGED {
		return nil, false, .Damaged
	}
	if status == .Failed && size == ERROR_ABSENT {
		return nil, false, .Ok // No such object: found is false.
	}
	if status != .Ok {
		return nil, false, status
	}
	text: []u8
	answer: i64
	answer, text, status = call(client, "read", arguments[:], error)
	if status == .Failed && answer == ERROR_DAMAGED {
		return nil, false, .Damaged
	}
	if status != .Ok {
		return nil, false, status
	}
	if i64(len(text)) != size {
		return nil, false, .Damaged
	}
	count := copy(result, text)
	return result[:count], true, .Ok
}

// error_text writes the sentence of an error record that the storage service
// gave: the names come from the description of the export in its file.
error_text :: proc "contextless" (writer: ^system.Writer, client: ^Client, error: ^errors.Error_Record) {
	system.export_error_text(writer, client.file, u32(clamp(error.operation, 0, i64(max(u32)))), "storage", error)
}

// One state of an object, as the export versions gives it: its row.
Version :: struct {
	generation: i64,
	time:       i64, // Milliseconds since the format of the disk.
	date:       i64, // Seconds since 1970 (UTC). 0: not known.
	bytes:      i64,
	own_blocks: i64, // The blocks that only this state holds.
	current:    i64, // 1: the current version.
}

// versions copies the states of an object of the store of the program into
// `into`, the oldest first, the current version last. total is the count of
// all the states: more than len(rows) when they did not fit.
versions :: proc "contextless" (client: ^Client, name: string, into: []Version, error: ^errors.Error_Record = nil) -> (rows: []Version, total: i64, status: Status) {
	arguments := [2]isolated.Argument{{text = nil}, {text = transmute([]u8)name}}
	bytes: []u8
	total, bytes, status = call(client, "versions", arguments[:], error)
	if status != .Ok {
		return nil, total, status
	}
	count := min(len(bytes) / size_of(Version), len(into))
	for index in 0 ..< count {
		into[index] = (^Version)(raw_data(bytes[index * size_of(Version):]))^
	}
	return into[:count], total, .Ok
}

// version copies the bytes of an object at a generation (a version, or the
// current version) into result. Too_Small: result is smaller than the bytes.
version :: proc "contextless" (client: ^Client, name: string, generation: i64, result: []u8, error: ^errors.Error_Record = nil) -> (bytes: []u8, status: Status) {
	arguments := [3]isolated.Argument{{text = nil}, {text = transmute([]u8)name}, {integer = u64(generation)}}
	size: i64
	text: []u8
	size, text, status = call(client, "version", arguments[:], error)
	if status == .Refused && size > i64(len(result)) {
		return nil, .Too_Small // The service gave the size, and no bytes that fit the call region.
	}
	if status != .Ok {
		return nil, status
	}
	if size > i64(len(result)) {
		return nil, .Too_Small
	}
	if i64(len(text)) != size {
		return nil, .Damaged
	}
	count := copy(result, text)
	return result[:count], .Ok
}

// restore makes a version of an object its current version again, in one
// commit. The result is the generation of the commit.
restore :: proc "contextless" (client: ^Client, name: string, generation: i64, error: ^errors.Error_Record = nil) -> (commit: i64, status: Status) {
	arguments := [3]isolated.Argument{{text = nil}, {text = transmute([]u8)name}, {integer = u64(generation)}}
	commit, _, status = call(client, "restore", arguments[:], error)
	return commit, status
}
