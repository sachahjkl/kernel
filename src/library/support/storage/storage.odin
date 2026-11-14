// The client of the storage service: what a program compiles in to keep its
// data in its private store: a tree of entries, each an object or a tree
// (docs/STORAGE.md).
//
// The root service makes the connection when it starts the program, and
// gives it in the context (GRANT_ roles below): a call ring, a call region,
// a handle that reads the state of the storage service, and the file of the
// storage service, mapped read-only at FILE_ADDRESS. The calls are isolated
// calls (src/library/contract/isolated): this package finds each export by its name in
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
//
// Who uses it: each program with the grant `Store` (the console, the notes,
// the settings, the tests of the storage service). The parts:
//
// - `Client`, `open`, `connected`, `call`: the connection.
// - `read`, `write`, `remove` and the pending changes (`write_range`,
//   `set_size`, `commit`): the objects.
// - `open_tree`, `close_tree`, `add`, `list`, `rename`: the trees and the
//   places.
// - `versions`, `version`, `compare`, `restore`: the versions.
// - `share`, `unshare`, `open_handles`, `open_store`: the shares and the
//   other stores.
// - `usage`, `error_text`: the counts of the store and the sentence of an
//   error record.
//
// See [storage service](term:storage-service), [place](term:place) and
// [private store](term:private-store).
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
// (src/library/contract/errors): the client gives it to its program.
ERROR_NO_STORE :: -1 // The caller has no grant of a store.
ERROR_NO_BUDGET :: -2 // The store would have more blocks than its limit.
ERROR_NAME :: -3 // A name is empty, too long, has a zero byte or a byte '/', or is "." or "..".
ERROR_TOO_LARGE :: -4 // The data of a write of a whole object has more bytes than the call region; or an object would pass 4 TiB.
ERROR_FULL :: -5 // No place for one more object or store, or no free block on the disk.
ERROR_DISK :: -6 // The block service reported an error.
ERROR_ABSENT :: -7 // The tree has no object with this name, or the place names no tree any more.
ERROR_DAMAGED :: -8 // A block of the object, or a node of a tree of the store, has a wrong check.
ERROR_NO_VERSION :: -9 // The object has no version of this generation.
ERROR_ACTS_FOR_PRINCIPAL :: -10 // The call names another store, and the caller does not act for the principal.
ERROR_EXISTS :: -11 // The tree has an entry with this name already.
ERROR_PLACE :: -12 // The place is not a place of this connection, or the connection reads only.
ERROR_PENDING :: -13 // The object has no pending change on this connection, or another change of the object came first.

// One connection to the storage service, in the memory of the program. One
// thread uses it at a time: a call uses the call region whole.
Client :: struct {
	ring_memory:   system.Handle, // The memory of the call ring.
	region_memory: system.Handle, // The memory of the call region.
	service:       system.Handle, // The program of the storage service, with Read: its state.
	calls:         ring.Ring, // The call ring, mapped.
	region:        []u8, // The call region, mapped.
	file:          []u8, // The file of the storage service: the descriptions of its exports.
	tag:           u32, // The tag of the last call.
	gone:          bool, // The connection ended: each call gives Gone.
}

// The result of a call of this client, beside the result of the export.
Status :: enum {
	Ok, // The export ran and answered a number that is not negative.
	Gone, // The connection ended: the grant was revoked, or the storage service stopped.
	Refused, // The storage service refused the call: see isolated.Status.
	Damaged, // The storage service has the object and cannot give its bytes: a block has a wrong check, or the disk gave an error.
	Failed, // The export answered a negative number: the error record says why.
	Too_Small, // The bytes do not fit in the buffer of the caller: the count of the bytes is the result.
}

// open opens the connection that the root service gave in the context of
// this program. ok is false for a program with no grant of a store, or a
// file of the service that is not a valid module.
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

// size gives the count of bytes of the object `name` under a place, with
// the pending changes of this connection.
size :: proc "contextless" (client: ^Client, place: Place, name: string, error: ^errors.Error_Record = nil) -> (bytes: i64, status: Status) {
	arguments := [2]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}}
	bytes, _, status = call(client, "size", arguments[:], error)
	return bytes, status
}

// read_range copies the bytes of an object from `offset` into result, up
// to its end, as this connection sees it: with its pending changes. A hole
// reads as zero bytes. bytes is empty at the end.
read_range :: proc "contextless" (client: ^Client, place: Place, name: string, offset: u64, result: []u8, error: ^errors.Error_Record = nil) -> (bytes: []u8, status: Status) {
	arguments := [3]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}, {integer = offset}}
	count: i64
	text: []u8
	count, text, status = call(client, "read_range", arguments[:], error)
	if status == .Failed && count == ERROR_DAMAGED {
		return nil, .Damaged
	}
	if status != .Ok {
		return nil, status
	}
	if i64(len(text)) != count {
		return nil, .Damaged
	}
	copied := copy(result, text)
	return result[:copied], .Ok
}

// write_range writes data at `offset` of an object as a pending change of
// this connection: no commit, no hash. The result is the size of the object
// with the pending changes. commit makes the pending changes one commit.
write_range :: proc "contextless" (client: ^Client, place: Place, name: string, offset: u64, data: []u8, error: ^errors.Error_Record = nil) -> (size: i64, status: Status) {
	arguments := [4]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}, {integer = offset}, {text = data}}
	size, _, status = call(client, "write_range", arguments[:], error)
	return size, status
}

// set_size makes the size of an object `size` bytes, as a pending change of
// this connection: a cut, or an extension with zero bytes.
set_size :: proc "contextless" (client: ^Client, place: Place, name: string, size: u64, error: ^errors.Error_Record = nil) -> Status {
	arguments := [3]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}, {integer = size}}
	_, _, status := call(client, "set_size", arguments[:], error)
	return status
}

// What one commit of pending changes did: the row of the export commit.
Commit_Measure :: struct {
	generation:     i64,
	object_blocks:  i64, // The blocks of the object, holes included.
	held_blocks:    i64, // The blocks that the object holds: its object nodes and its blocks of data.
	changed:        i64, // The blocks of data that the commit changed.
	hashed_blocks:  i64, // The blocks of data whose bytes the commit hashed.
	hashed_nodes:   i64, // The object nodes whose value the commit computed.
	object_written: i64, // The blocks of the block tree that the commit wrote.
	written:        i64, // Each block that the commit wrote.
	milliseconds:   i64,
}

// commit makes the pending changes of this connection on an object one
// commit, on the disk at the return. The measure says what it hashed and
// wrote.
commit :: proc "contextless" (client: ^Client, place: Place, name: string, error: ^errors.Error_Record = nil) -> (measure: Commit_Measure, status: Status) {
	arguments := [2]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}}
	bytes: []u8
	_, bytes, status = call(client, "commit", arguments[:], error)
	if status == .Ok && len(bytes) >= size_of(Commit_Measure) {
		measure = (^Commit_Measure)(raw_data(bytes))^
	}
	return measure, status
}

// open_tree gives the place of the tree `name` under a place.
open_tree :: proc "contextless" (client: ^Client, place: Place, name: string, error: ^errors.Error_Record = nil) -> (opened: Place, status: Status) {
	arguments := [2]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}}
	result: i64
	result, _, status = call(client, "open", arguments[:], error)
	return Place(result), status
}

// open_store gives a place on the root of another store, for a caller
// that can name it (the export open_store): a caller that acts for the
// principal. Another caller gets Failed with ERROR_ACTS_FOR_PRINCIPAL.
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

ENTRY_OBJECT :: 1 // The kind of an entry that is an object: `store.Entry_Kind.Object`.
ENTRY_TREE :: 2 // The kind of an entry that is a tree: `store.Entry_Kind.Tree`.

// One entry that add makes: its name, at an offset of the bytes of the
// names, and its kind (ENTRY_OBJECT: an empty object; ENTRY_TREE: an empty
// tree). The layout of the record of the export add.
Add_Row :: struct {
	name_offset: i64,
	name_count:  i64,
	kind:        i64,
}

// add makes up to 256 entries under a place in one commit: all or none.
//
// ```odin
// names := "draftsnotes"
// rows := [2]storage.Add_Row{{0, 6, storage.ENTRY_TREE}, {6, 5, storage.ENTRY_OBJECT}}
// generation, status := storage.add(&client, storage.ROOT, rows[:], transmute([]u8)names)
// ```
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
	generation:  i64, // The commit of the last change of the entry.
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
	share:  i64, // The number of the share, for `unshare`.
	ring:   i64, // The handle of the call ring of the new connection.
	region: i64, // The handle of its call region.
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
	objects:  i64, // The objects of the store.
	trees:    i64, // The trees inside the tree of the store.
	versions: i64, // The versions of all the objects.
	blocks:   i64, // The blocks that the store holds.
	limit:    i64, // The most blocks of the store, as its grant gives it.
	removing: i64, // The trees that wait in the removal queue.
}

// usage gives the counts of the store of the connection.
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
	generation: i64, // The commit of the state: the name of the version.
	time:       i64, // Milliseconds since the format of the disk.
	date:       i64, // Seconds since 1970 (UTC). 0: not known.
	bytes:      i64, // The size of the object in that state.
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

// One range of bytes that differ between two states: the row of the export
// compare.
Byte_Range :: struct {
	first: i64, // The first byte that differs.
	count: i64, // The bytes of the range.
}

// compare copies into `into` the ranges of bytes that differ between two
// states of an object (two generations). The ranges that do not fit in
// `into` are not given.
compare :: proc "contextless" (client: ^Client, place: Place, name: string, first: i64, second: i64, into: []Byte_Range, error: ^errors.Error_Record = nil) -> (rows: []Byte_Range, status: Status) {
	arguments := [4]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}, {integer = u64(first)}, {integer = u64(second)}}
	bytes: []u8
	_, bytes, status = call(client, "compare", arguments[:], error)
	if status != .Ok {
		return nil, status
	}
	count := min(len(bytes) / size_of(Byte_Range), len(into))
	for index in 0 ..< count {
		into[index] = (^Byte_Range)(raw_data(bytes[index * size_of(Byte_Range):]))^
	}
	return into[:count], .Ok
}

// restore makes a version of an object its current version again, in one
// commit. The result is the generation of the commit.
restore :: proc "contextless" (client: ^Client, place: Place, name: string, generation: i64, error: ^errors.Error_Record = nil) -> (commit: i64, status: Status) {
	arguments := [3]isolated.Argument{{integer = u64(place)}, {text = transmute([]u8)name}, {integer = u64(generation)}}
	commit, _, status = call(client, "restore", arguments[:], error)
	return commit, status
}
