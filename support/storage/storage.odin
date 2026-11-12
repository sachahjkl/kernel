// The client of the storage service: what a program compiles in to keep its
// data in its private store: a tree of entries, each an object or a tree
// (docs/STORAGE.md).
//
// The root service makes the connection when it starts the program, and
// gives it in the context (GRANT_ roles below): a call ring, a call region,
// a handle that reads the state of the storage service, and the file of the
// storage service, mapped read-only at FILE_ADDRESS. The calls are isolated
// calls (contract/isolated): this package finds each export by its name in
// that file, and encodes the arguments with its description.
//
//   client, ok := storage.open(ctx)
//   storage.write(&client, storage.ROOT, "note", bytes)   // One commit, on the disk at the return.
//   storage.read(&client, storage.ROOT, "note", buffer[:])
//   drafts, _ := storage.open_tree(&client, storage.ROOT, "drafts")
//   storage.write(&client, drafts, "first", bytes)
//
// A place is a number of this connection that names a tree of the store:
// ROOT is the root of the connection; open_tree gives the place of a tree
// under a place. A name is one step under a place.
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

// A place of the connection (docs/STORAGE.md, "Places").
Place :: i64
ROOT :: Place(0) // The root of the connection: the tree of the store, or the tree of a share.
FILE_ADDRESS :: fixed_addresses.STORAGE_FILE_ADDRESS // Where the root service maps that file.

// The answer of an export of the storage service that is not a generation
// or a size: one of these numbers. The error record of the call says more
// (contract/errors): the client gives it to its program.
ERROR_NO_STORE :: -1 // The caller has no grant of a store.
ERROR_NO_BUDGET :: -2 // The store would have more blocks than its limit.
ERROR_NAME :: -3 // A name is empty, too long, has a zero byte or a byte '/', or is "." or "..".
ERROR_TOO_LARGE :: -4 // The object would have more than 32 blocks.
ERROR_FULL :: -5 // No place for one more object or store, or no free block on the disk.
ERROR_DISK :: -6 // The block service reported an error.
ERROR_ABSENT :: -7 // The tree has no object with this name, or the place names no tree any more.
ERROR_DAMAGED :: -8 // A block of the object, or a node of a tree of the store, has a wrong check.
ERROR_NO_VERSION :: -9 // The object has no version of this generation.
ERROR_PERSON :: -10 // The call names another store, and the caller does not act for the person.
ERROR_EXISTS :: -11 // The tree has an entry with this name already.
ERROR_PLACE :: -12 // The place is not a place of this connection, or the connection reads only.

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
			if problem, _ := isolated.tables_return(client.file, function, arguments, client.region, offset); problem != .None {
				return i64(completion.values[0]), nil, .Refused
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

// write makes the object `name` under a place the bytes of data, in one
// commit. The result is the generation of the commit, or a negative number
// with the status Failed and the error record (see the export write of the
// storage service).
write :: proc "contextless" (client: ^Client, place: Place, name: string, data: []u8, error: ^errors.Error_Record = nil) -> (generation: i64, status: Status) {
	arguments := [3]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}, {text = data}}
	generation, _, status = call(client, "write", arguments[:], error)
	return generation, status
}

// remove removes the entry `name` under a place, in one commit: an object
// and its versions, or a tree and all under it. The result is the
// generation of the commit, or a negative number with the status Failed and
// the error record (ERROR_ABSENT: no entry with this name).
remove :: proc "contextless" (client: ^Client, place: Place, name: string, error: ^errors.Error_Record = nil) -> (generation: i64, status: Status) {
	arguments := [2]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}}
	generation, _, status = call(client, "remove", arguments[:], error)
	return generation, status
}

// read copies the bytes of the object `name` under a place into result.
// found is false when the tree has no such object. The status Damaged says
// that the store has the object and that its bytes did not come: the
// caller must not take it for an empty object.
read :: proc "contextless" (client: ^Client, place: Place, name: string, result: []u8, error: ^errors.Error_Record = nil) -> (bytes: []u8, found: bool, status: Status) {
	arguments := [2]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}}
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

// open_tree gives the place of the tree `name` under a place.
open_tree :: proc "contextless" (client: ^Client, place: Place, name: string, error: ^errors.Error_Record = nil) -> (opened: Place, status: Status) {
	arguments := [2]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}}
	result: i64
	result, _, status = call(client, "open", arguments[:], error)
	return Place(result), status
}

// open_store gives a place on the root of another store, for a caller
// that may name it (the export open_store).
open_store :: proc "contextless" (client: ^Client, store: string, error: ^errors.Error_Record = nil) -> (opened: Place, status: Status) {
	arguments := [1]isolated.Argument{{text = transmute([]u8)store}}
	result: i64
	result, _, status = call(client, "open_store", arguments[:], error)
	return Place(result), status
}

// close_tree frees a place.
close_tree :: proc "contextless" (client: ^Client, place: Place, error: ^errors.Error_Record = nil) -> Status {
	arguments := [1]isolated.Argument{{integer = u64(place)}}
	_, _, status := call(client, "close", arguments[:], error)
	return status
}

ENTRY_OBJECT :: 1
ENTRY_TREE :: 2

// One entry that add makes: its name, at an offset of the bytes of the
// names, and its kind (ENTRY_OBJECT: an empty object; ENTRY_TREE: an empty
// tree). The layout of the record of the export add.
Add_Row :: struct {
	name_offset: i64,
	name_count:  i64,
	kind:        i64,
}

// add makes up to 256 entries under a place in one commit: all or none.
add :: proc "contextless" (client: ^Client, place: Place, rows: []Add_Row, names: []u8, error: ^errors.Error_Record = nil) -> (generation: i64, status: Status) {
	arguments: [3]isolated.Argument
	arguments[0].integer = u64(place)
	arguments[1].table = {records = ([^]u8)(raw_data(rows))[:len(rows) * size_of(Add_Row)], count = u64(len(rows))}
	arguments[2].table = {records = names, count = u64(len(names))}
	generation, _, status = call(client, "add", arguments[:], error)
	return generation, status
}

// One entry of a page of list. Its name is names[name_offset:][:name_count].
Listed :: struct {
	name_offset: i64,
	name_count:  i64,
	kind:        i64, // ENTRY_OBJECT or ENTRY_TREE.
	size:        i64, // The bytes of an object, the entries of a tree.
	generation:  i64,
}

// list gives a page of the entries of the tree of a place, after the name
// `after` ("" from the start), as many as `rows` and `names` hold. An
// empty page: no more entries.
list :: proc "contextless" (client: ^Client, place: Place, after: string, rows: []Listed, names: []u8, error: ^errors.Error_Record = nil) -> (page: []Listed, status: Status) {
	arguments: [4]isolated.Argument
	arguments[0].integer = u64(place)
	arguments[1].text = transmute([]u8)after
	arguments[2].table = {records = ([^]u8)(raw_data(rows))[:len(rows) * size_of(Listed)], count = 0}
	arguments[3].table = {records = names, count = 0}
	count: i64
	count, _, status = call(client, "list", arguments[:], error)
	if status != .Ok {
		return nil, status
	}
	return rows[:clamp(int(count), 0, len(rows))], .Ok
}

// rename moves the entry `name` under a place to `to_name` under
// `to_place`, in one commit.
rename :: proc "contextless" (client: ^Client, place: Place, name: string, to_place: Place, to_name: string, error: ^errors.Error_Record = nil) -> (generation: i64, status: Status) {
	arguments := [4]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}, {integer = u64(to_place)}, {text = transmute([]u8)to_name}}
	generation, _, status = call(client, "rename", arguments[:], error)
	return generation, status
}

// The answer of the export share: the number of the share and its two
// handles, as this program names them.
Shared :: struct {
	share:  i64,
	ring:   i64,
	region: i64,
}

// share makes a new connection whose root is the tree of a place, and
// gives a Client of it: its two handles can go to another program, which
// opens it with open_handles. number is for unshare.
share :: proc "contextless" (client: ^Client, place: Place, read_only: bool, error: ^errors.Error_Record = nil) -> (shared: Client, number: i64, status: Status) {
	arguments := [2]isolated.Argument{{integer = u64(place)}, {integer = read_only ? 1 : 0}}
	bytes: []u8
	_, bytes, status = call(client, "share", arguments[:], error)
	if status != .Ok {
		return {}, 0, status
	}
	if len(bytes) < size_of(Shared) {
		return {}, 0, .Refused
	}
	row := (^Shared)(raw_data(bytes))^
	ok: bool
	shared, ok = open_handles(system.Handle(row.ring), system.Handle(row.region), client.service, client.file)
	if !ok {
		return {}, row.share, .Refused
	}
	return shared, row.share, .Ok
}

// open_handles opens a connection from its call ring and its call region,
// with the file of the storage service that describes its exports.
open_handles :: proc "contextless" (ring_memory, region_memory: system.Handle, service: system.Handle, file: []u8) -> (client: Client, ok: bool) {
	client.ring_memory = ring_memory
	client.region_memory = region_memory
	client.service = service
	client.file = file
	status: system.Status
	if client.calls, status = system.ring_open(ring_memory); status != .Ok {
		return {}, false
	}
	address, map_status := system.memory_map(region_memory)
	if map_status != .Ok {
		return {}, false
	}
	client.region = ([^]u8)(address)[:system.memory_size(region_memory) * system.PAGE_SIZE]
	return client, true
}

// unshare ends a share that this connection made.
unshare :: proc "contextless" (client: ^Client, number: i64, error: ^errors.Error_Record = nil) -> Status {
	arguments := [1]isolated.Argument{{integer = u64(number)}}
	_, _, status := call(client, "unshare", arguments[:], error)
	return status
}

// The counts of the store of a connection: the row of the export usage.
Usage :: struct {
	objects:  i64,
	trees:    i64,
	versions: i64,
	blocks:   i64,
	limit:    i64,
	removing: i64,
}

usage :: proc "contextless" (client: ^Client) -> (counts: Usage, status: Status) {
	bytes: []u8
	_, bytes, status = call(client, "usage", nil)
	if status == .Ok && len(bytes) >= size_of(Usage) {
		counts = (^Usage)(raw_data(bytes))^
	}
	return counts, status
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
versions :: proc "contextless" (client: ^Client, place: Place, name: string, into: []Version, error: ^errors.Error_Record = nil) -> (rows: []Version, total: i64, status: Status) {
	arguments := [2]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}}
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
version :: proc "contextless" (client: ^Client, place: Place, name: string, generation: i64, result: []u8, error: ^errors.Error_Record = nil) -> (bytes: []u8, status: Status) {
	arguments := [3]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}, {integer = u64(generation)}}
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
restore :: proc "contextless" (client: ^Client, place: Place, name: string, generation: i64, error: ^errors.Error_Record = nil) -> (commit: i64, status: Status) {
	arguments := [3]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}, {integer = u64(generation)}}
	commit, _, status = call(client, "restore", arguments[:], error)
	return commit, status
}
