// The storage service: it keeps the store of each program on the data disk, through a block service: a tree of entries, each an object or a tree inside it (docs/STORAGE.md). No program sees a shared tree of names.
//
// The root service decides who has a store: it names the store of each connection, and its limit of blocks. A connection reaches the tree of its store and what is under it: each export takes a place (0 is the root of the connection) and a name of one step under it, never a path, and never the name of a store. A connection that [share](storage.share) makes reaches a tree of the store of its maker only, and **can read only**; [unshare](storage.unshare) revokes it.
//
// **A change is one commit**, on the disk when the call returns: the system has no save action. The state of an object before a change is a version: a program reads, compares, restores and clones versions with no code of its own. The disk always has the state of the last commit, or of the one before: a stop of the machine during a commit never shows a part of it. The checks of the blocks show each change that the service did not make.
//
// A program that acts for a principal (the console, remote for the host) sees the stores of that principal with [stores](storage.stores), and opens a place on one of them with [open_store](storage.open_store).
//
// **Grants**, as the root service gives them:
//
// - **Serve**: each program with the grant **Store** reaches its private store through a connection.
// - **Data_Disk**: the block service of the data disk and its block ring. The storage service is the one client of
//   that disk: no other program reads its blocks.
//
// **Start**: no line starts it. The root service starts it when a program asks for a connection to `storage`, or
// before a program with a private store. From the console: `connect("storage")`, then for example
// `storage.write(0, "greeting", "kept on the disk")` and `storage.read(0, "greeting")`.
//
// **What it proves**: a program keeps its state across a stop of the machine with no file system, no path and no
// save action, and it reaches no store but its own. It does not prove secrecy against a reader of the disk: the
// blocks are not encrypted.
//
// The design: `docs/STORAGE.md`; the large objects: [read_range](storage.read_range) and the exports after it.
package storage_service

import "modus:contract/block"
import "modus:contract/date"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/ring"
import format "modus:contract/store"
import answers "modus:support/storage"
import "base:intrinsics"
import block_tree "modus:support/storage_object"
import tree "modus:support/storage_tree"
import "modus:support/principals"
import "modus:support/system"

ERROR_ACTS_FOR_PRINCIPAL :: answers.ERROR_ACTS_FOR_PRINCIPAL
ERROR_PLACE :: answers.ERROR_PLACE

// ---------------------------------------------------------------------
// Connections, places and shares.

PLACE_CAPACITY :: 512 // The places of all the connections.
SHARE_CAPACITY :: 16 // The connections that the service made with share.

// A place: a tree of a store, by the names of its path from the root of
// the store, held by one connection. The store is the store of the
// connection, or another store that open_store opened for a caller that may
// name it.
Place :: struct {
	holder:     system.Handle, // The call ring of the connection that holds it. 0: free.
	generation: u32, // Changes at each free: an old number of the place names nothing.
	store:      system.Name, // The name of its store.
	depth:      int,
	path:       [NESTING_LIMIT]Entry_Name,
}
places: [PLACE_CAPACITY]Place

// A connection that the service made for the caller of share: its root is
// a tree of the store of its maker.
Share :: struct {
	connection: system.Connection, // calls.head nil: the place is free.
	maker:      system.Handle, // The call ring of the connection that made it.
	read_only:  bool,
	depth:      int,
	path:       [NESTING_LIMIT]Entry_Name,
}
shares: [SHARE_CAPACITY]Share

// The caller of the export that runs.
Caller :: struct {
	connection: ^system.Connection,
	store:      Store_Of,
	acts_for_principal: bool, // The root service granted it to act for its principal.
	principal:  u64, // The principal of the session of the caller (isolated.caller_principal).
	read_only:  bool,
	depth:      int,
	path:       [NESTING_LIMIT]Entry_Name, // The root of the connection.
}

share_of :: proc "contextless" (connection: ^system.Connection) -> ^Share {
	for &item in shares {
		if item.connection.calls.head != nil && &item.connection == connection {
			return &item
		}
	}
	return nil
}

// connection_store gives the store and the limit that a connection
// reaches: the grant of the root service, or the store of the maker of a
// share, while the maker has its grant.
connection_store :: proc "contextless" (ring_memory: system.Handle, steps: int) -> (store: Store_Of, root_service: bool, found: bool) {
	if steps > SHARE_CAPACITY || ring_memory == 0 {
		return {}, false, false
	}
	for &connection in service.connections {
		if connection.calls.head != nil && connection.ring_memory == ring_memory {
			return {system.name_of(connection.caller[:]), connection.grant & isolated.CALLER_AMOUNT_MASK}, true, true
		}
	}
	for &item in shares {
		if item.connection.calls.head != nil && item.connection.ring_memory == ring_memory {
			store, _, found = connection_store(item.maker, steps + 1)
			return store, false, found
		}
	}
	return {}, false, false
}

// caller_of gives the caller of the export that runs. A share whose maker
// lost its grant, or left, ends here.
caller_of :: proc "contextless" () -> (caller: Caller) {
	connection := system.service_caller()
	if connection == nil {
		return {}
	}
	caller.connection = connection
	item := share_of(connection)
	if item == nil {
		caller.store = {system.name_of(connection.caller[:]), connection.grant & isolated.CALLER_AMOUNT_MASK}
		caller.acts_for_principal = connection.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0
		caller.principal = isolated.caller_principal(connection.grant)
		return caller
	}
	store, _, found := connection_store(item.maker, 0)
	if !found || store.limit == 0 {
		share_end(item)
		caller.connection = nil
		return caller
	}
	caller.store = store
	caller.read_only = item.read_only
	caller.depth = item.depth
	caller.path = item.path
	return caller
}

// A path of a call: the store and the root of a place, and one more name.
Path :: struct {
	store: Store_Of,
	own:   bool, // The store of the connection: the only store that write, add, remove, rename and share change.
	names: [NESTING_LIMIT + 1]Entry_Name,
	depth: int,
}

path_names :: proc "contextless" (path: ^Path) -> []Entry_Name {
	return path.names[:path.depth]
}

// place_path gives the path of a place of the caller. It refuses a number
// that is not a place of this connection.
place_path :: proc "contextless" (caller: ^Caller, place: i64, error: ^errors.Error_Record, argument: i64) -> (path: Path, ok: bool) {
	if place == 0 {
		path.store = caller.store
		path.own = true
		path.depth = caller.depth
		copy(path.names[:], caller.path[:caller.depth])
		return path, true
	}
	index := int(place & 0xFFFF_FFFF) - 1
	generation := u32(u64(place) >> 32)
	if place < 0 || index < 0 || index >= PLACE_CAPACITY || places[index].holder == 0 || places[index].holder != caller.connection.ring_memory || places[index].generation != generation {
		errors.fail(error, ERROR_PLACE, .Absent, .Places, argument, place)
		return {}, false
	}
	item := &places[index]
	name := system.name_of(item.store[:])
	path.own = name == caller.store.name
	if path.own {
		path.store = caller.store
	} else {
		// Another store: its limit is the one of its last grant.
		store_index := store_find(name)
		if store_index < 0 {
			errors.fail(error, ERROR_PLACE, .Absent, .Places, argument, place)
			return {}, false
		}
		path.store = {system.name_of(root.stores[store_index].name[:]), root.stores[store_index].limit}
	}
	path.depth = item.depth
	copy(path.names[:], item.path[:path.depth])
	return path, true
}

// may_name_store says if a caller may open a place on a store that is not
// the store of its connection, and if stores() shows it to the caller: the
// one rule of the service for it (docs/STORAGE.md, "No way up"). A caller
// that acts for principal N names the stores of principal N only: the
// principal of a store is in its name (principals.store_name_principal).
// Principal 0, the machine, names no store of a named principal. A caller
// that does not act for a principal, and a share, name their own store only.
may_name_store :: proc "contextless" (caller: ^Caller, store_name: string) -> bool {
	if store_name == caller.store.name {
		return true
	}
	if !caller.acts_for_principal || caller.connection == nil || share_of(caller.connection) != nil {
		return false
	}
	return principals.store_name_principal(store_name) == caller.principal
}

// places_sweep frees the places of connections that ended.
places_sweep :: proc "contextless" () {
	for &item in places {
		if item.holder == 0 {
			continue
		}
		_, _, found := connection_store(item.holder, 0)
		if !found {
			item.holder = 0
			item.generation += 1
		}
	}
}

place_new :: proc "contextless" (caller: ^Caller, path: ^Path) -> (place: i64, ok: bool) {
	for attempt in 0 ..< 2 {
		for &item, index in places {
			if item.holder != 0 {
				continue
			}
			item.holder = caller.connection.ring_memory
			item.store = system.name_unpack(system.name_pack(path.store.name))
			item.depth = path.depth
			copy(item.path[:], path.names[:path.depth])
			return i64(index + 1) | i64(item.generation) << 32, true
		}
		if attempt == 0 {
			places_sweep()
		}
	}
	return 0, false
}

// The refusals that each export of a change makes first.
change_refusal :: proc "contextless" (caller: ^Caller, error: ^errors.Error_Record) -> (refused: bool, result: i64) {
	if caller.connection == nil || caller.store.limit == 0 {
		return true, errors.fail(error, ERROR_NO_STORE, .No_Grant, .Store)
	}
	if caller.read_only {
		return true, errors.fail(error, ERROR_PLACE, .No_Grant, .Changes)
	}
	return false, 0
}

// The beginning of each export with a place and a name: the caller, the
// path of the place, the name kept.
Named :: struct {
	caller: Caller,
	path:   Path,
	name:   Kept_Name,
}

named_of :: proc "contextless" (place: i64, name: string, error: ^errors.Error_Record, place_argument: i64, change: bool) -> (named: Named, result: i64) {
	named.caller = caller_of()
	if change {
		if refused, refusal := change_refusal(&named.caller, error); refused {
			return named, refusal
		}
	} else if named.caller.connection == nil {
		return named, errors.fail(error, ERROR_NO_STORE, .No_Grant, .Store)
	}
	ok: bool
	if named.path, ok = place_path(&named.caller, place, error, place_argument); !ok {
		return named, ERROR_PLACE
	}
	if named.path.own && named.path.store.limit == 0 {
		return named, errors.fail(error, ERROR_NO_STORE, .No_Grant, .Store)
	}
	if change && !named.path.own {
		return named, errors.fail(error, ERROR_NO_STORE, .No_Grant, .Store, place_argument)
	}
	if named.name, ok = name_keep(name, error, place_argument + 1); !ok {
		return named, ERROR_NAME
	}
	return named, 0
}

// ---------------------------------------------------------------------
// The exports of objects.

// write makes the object `name` under a place the bytes of data, in one commit on the disk: a cut or an extension to the size of data, and a change of each of its blocks, as a commit of ranges does; a block that keeps its bytes keeps its block. A new name is a new object. The state before becomes a version. At the limit of the store, the oldest versions of the store are thinned in the same commit. The result is the generation of the commit, or a negative number with an error record.
//
// **Error kinds**
//
// - `No_Grant` (-1, the caller has no store; -12, unit Changes, the connection reads only);
// - `Absent` (-12, unit Places: the place is not a place of this connection; -7, unit Places: its tree was removed or renamed; -7, unit Objects: the name is a tree);
// - `Over_Limit` (-2, the current objects with the change need more blocks than the limit, with no earlier version kept);
// - `Empty`, `Too_Long` or `Bad_Byte` (-3, the name has 1 to 64 bytes, no zero byte, no byte '/', and is not "." or "..");
// - `Too_Long` (-4, the data has more bytes than the call region holds: write a larger object by ranges);
// - `Full` (-5, no place for one more store, or no free block; with the unit Commit_Blocks, the commit changes more blocks than one commit can);
// - `Device` (-6);
// - `Damaged` (-8, unit Stores: a node of a tree of the store has a wrong check; unit Counts: the counts of the store are not trusted after a fault of the service).
@(export, link_name = "write")
write :: proc "c" (place: i64, name: ^string, data: ^string, error: ^errors.Error_Record) -> i64 {
	named, refused := named_of(place, name^, error, 1, true)
	if refused < 0 {
		return refused
	}
	return object_change(named.caller.store, path_names(&named.path), named.name, .Write, transmute([]u8)data^, {}, error, 2)
}

// read gives the bytes of the object `name` under a place: the range from 0 to its end, as read_range gives it, with the pending changes of this connection. The result is the count of bytes; the size when they do not fit in the result; or a negative number with an error record.
//
// **Error kinds**
//
// - `No_Grant` (-1);
// - `Absent` (-12, -7: the place; -7: the tree has no such object);
// - `Empty`, `Too_Long` or `Bad_Byte` (-3, the name);
// - `Device` (-6);
// - `Damaged` (-8: a block of the object or a node of a tree of the store has a wrong check: the service does not give its bytes).
@(export, link_name = "read")
read_export :: proc "c" (place: i64, name: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	ranged, refused := ranged_of(place, name^, error, false)
	if refused < 0 {
		return refused
	}
	size := ranged_size(&ranged)
	if size > u64(len(result)) {
		return i64(size) // A text that does not fit: the caller sees it.
	}
	return ranged_read(&ranged, 0, result^[:size], error)
}

// size gives the count of bytes of the object `name` under a place, with the pending changes of this connection, or a negative number with an error record.
//
// **Error kinds**
//
// - those of [read](storage.read), but `Device` and `Damaged` for a block of the object: size reads the tree only.
@(export, link_name = "size")
size :: proc "c" (place: i64, name: ^string, error: ^errors.Error_Record) -> i64 {
	ranged, refused := ranged_of(place, name^, error, false)
	if refused < 0 {
		return refused
	}
	return i64(ranged_size(&ranged))
}

// remove removes the entry `name` under a place, in one commit: an object with all its versions, or a tree with all that is under it. The name is gone at the commit; the blocks of a tree are freed after it, in steps of 64 entries, one commit each, while no call waits (usage gives the trees that wait). The result is the generation of the commit, or a negative number with an error record.
//
// **Error kinds**
//
// - those of [write](storage.write), and `Absent` (-7, the tree has no entry with this name).
@(export, link_name = "remove")
remove :: proc "c" (place: i64, name: ^string, error: ^errors.Error_Record) -> i64 {
	named, refused := named_of(place, name^, error, 1, true)
	if refused < 0 {
		return refused
	}
	return entry_remove(named.caller.store, path_names(&named.path), named.name, error)
}

// One entry that add makes: its name, as an offset and a count of bytes in the argument names, and its kind (1: an empty object, 2: an empty tree).
Add_Row_Export :: struct {
	name_offset: i64,
	name_count:  i64,
	kind:        i64,
}
#assert(size_of(Add_Row_Export) == size_of(Add_Row))

// add makes up to 256 entries under a place in one commit, each an empty object or an empty tree: all of them, or none. The names are bytes of the argument names, each named by a row. The result is the generation of the commit, or a negative number with an error record.
//
// **Error kinds**
//
// - those of [write](storage.write);
// - `Too_Long` (-5, more than 256 rows);
// - `Bad_Value` (-3, a kind that is not 1 or 2);
// - `Out_Of_Range` (-3, a row names bytes past the names);
// - `Exists` (-11, a name exists, or two rows have one name: found is the row).
@(export, link_name = "add")
add :: proc "c" (place: i64, rows: ^system.Table_To_Read(Add_Row_Export), names: ^system.Bytes_To_Read, error: ^errors.Error_Record) -> i64 {
	caller := caller_of()
	if refused, result := change_refusal(&caller, error); refused {
		return result
	}
	path, ok := place_path(&caller, place, error, 1)
	if !ok {
		return ERROR_PLACE
	}
	if !path.own {
		return errors.fail(error, ERROR_NO_STORE, .No_Grant, .Store, 1)
	}
	records := system.table_records(rows)
	given := ([^]Add_Row)(raw_data(records))[:len(records)]
	return entries_add(path.store, path_names(&path), given, names.bytes[:names.count], error)
}

// open gives the place of the tree `name` under a place: a number for the calls of this connection only. The tree and what is under it are what the place reaches; no name under it reaches above it.
//
// **Error kinds**
//
// - `No_Grant` (-1);
// - `Absent` (-12, -7: the place; -7, unit Trees: no tree has this name);
// - the errors of a name (-3);
// - `Too_Long` (-3, unit Trees: the place would be more than 32 trees deep);
// - `Full` (-5, unit Places: no free place);
// - `Damaged` (-8);
// - `Device` (-6).
@(export, link_name = "open")
open :: proc "c" (place: i64, name: ^string, error: ^errors.Error_Record) -> i64 {
	named, refused := named_of(place, name^, error, 1, false)
	if refused < 0 {
		return refused
	}
	if named.path.depth >= NESTING_LIMIT {
		return errors.fail(error, ERROR_NAME, .Too_Long, .Trees, 1, NESTING_LIMIT + 1, NESTING_LIMIT)
	}
	store_index := store_find(named.path.store.name)
	if store_index < 0 {
		return errors.fail(error, ERROR_ABSENT, .Absent, .Trees, 2)
	}
	if store_damaged[store_index] {
		return errors.fail(error, ERROR_DAMAGED, .Damaged, .Stores)
	}
	value, outcome := entry_of(store_index, path_names(&named.path), named.name.key)
	if outcome == .Device || outcome == .Wrong {
		return lookup_refusal(outcome, error, 2)
	}
	if outcome != .Found || value.kind != .Tree {
		return errors.fail(error, ERROR_ABSENT, .Absent, .Trees, 2)
	}
	named.path.names[named.path.depth] = named.name.key
	named.path.depth += 1
	opened_place, ok := place_new(&named.caller, &named.path)
	if !ok {
		return errors.fail(error, ERROR_FULL, .Full, .Places, 0, 0, PLACE_CAPACITY)
	}
	return opened_place
}

// close frees a place of this connection. The result is 0, or a negative number with an error record.
//
// **Error kinds**
//
// - `Absent` (-12, unit Places).
@(export, link_name = "close")
close :: proc "c" (place: i64, error: ^errors.Error_Record) -> i64 {
	caller := caller_of()
	if caller.connection == nil || place == 0 {
		return errors.fail(error, ERROR_PLACE, .Absent, .Places, 1, place)
	}
	if _, ok := place_path(&caller, place, error, 1); !ok {
		return ERROR_PLACE
	}
	item := &places[int(place & 0xFFFF_FFFF) - 1]
	item.holder = 0
	item.generation += 1
	return 0
}

// One entry of list: its name, as an offset and a count of bytes in the argument names; its kind (1 an object, 2 a tree); its size (the bytes of an object, the entries of a tree); the generation of its last change.
Listed :: struct {
	name_offset: i64,
	name_count:  i64,
	kind:        i64,
	size:        i64,
	generation:  i64,
}

// list gives a page of the entries of the tree of a place, in the order of the bytes of their names, from the first name after `after` (from the first entry when it is empty): as many as the rows and the names hold. A tree of any size is read in pages; the next page starts after the last name of this one. The result is the count of the rows of the page (0: no more entries), or a negative number with an error record.
//
// **Error kinds**
//
// - `No_Grant` (-1);
// - `Absent` (-12, -7: the place);
// - `Too_Long` or `Bad_Byte` (-3, after);
// - `Damaged` (-8);
// - `Device` (-6).
@(export, link_name = "list")
list :: proc "c" (place: i64, after: ^string, rows: ^system.Table_To_Append(Listed), names: ^system.Bytes_To_Append, error: ^errors.Error_Record) -> i64 {
	caller := caller_of()
	if caller.connection == nil || caller.store.limit == 0 {
		return errors.fail(error, ERROR_NO_STORE, .No_Grant, .Store)
	}
	path, ok := place_path(&caller, place, error, 1)
	if !ok {
		return ERROR_PLACE
	}
	cursor: Entry_Name
	from_after := len(after^) != 0
	if from_after {
		kept, kept_ok := name_keep(after^, error, 2)
		if !kept_ok {
			return ERROR_NAME
		}
		cursor = kept.key
	}
	store_index := store_find(path.store.name)
	if store_index < 0 {
		return 0 // A store with no commit has no entry.
	}
	if store_damaged[store_index] {
		return errors.fail(error, ERROR_DAMAGED, .Damaged, .Stores)
	}
	root_node, outcome := tree_of(store_index, path_names(&path))
	if outcome != .Found {
		if outcome == .Absent {
			return errors.fail(error, ERROR_ABSENT, .Absent, .Places, 1)
		}
		return lookup_refusal(outcome, error, 1)
	}
	work := tree.Work{pool = &reading_pool, source = &node_source, shape = tree.TREE_SHAPE, root = root_node}
	written: i64
	for rows.count < rows.capacity {
		key: Entry_Name
		value: Entry
		if !tree.first_from(&work, cursor[:], from_after, key[:], entry_bytes(&value)) {
			if reading_pool.failure != .None {
				return lookup_refusal(reading_outcome(store_index), error, 1)
			}
			break
		}
		name := format.name_of(&key)
		if names.count + u64(len(name)) > names.capacity {
			break // The names hold no more: the next page starts here.
		}
		offset := system.bytes_append(names, transmute([]u8)name)
		system.table_append(rows, Listed{name_offset = i64(offset), name_count = i64(len(name)), kind = i64(value.kind), size = i64(value.size), generation = i64(value.generation)})
		written += 1
		cursor = key
		from_after = true
	}
	return written
}

// rename moves the entry `name` under a place to the name `to_name` under the place `to_place`, in one commit: an object with its versions, or a tree with all under it. Both places are of this connection, so of one store. The result is the generation of the commit, or a negative number with an error record.
//
// **Error kinds**
//
// - those of [write](storage.write);
// - `Absent` (-7, no entry `name`);
// - `Exists` (-11, `to_name` exists);
// - `Bad_Value` (-3, unit Trees: `to_place` is inside the tree that moves).
@(export, link_name = "rename")
rename :: proc "c" (place: i64, name: ^string, to_place: i64, to_name: ^string, error: ^errors.Error_Record) -> i64 {
	named, refused := named_of(place, name^, error, 1, true)
	if refused < 0 {
		return refused
	}
	to_path, ok := place_path(&named.caller, to_place, error, 3)
	if !ok {
		return ERROR_PLACE
	}
	if !to_path.own {
		return errors.fail(error, ERROR_NO_STORE, .No_Grant, .Store, 3)
	}
	to, to_ok := name_keep(to_name^, error, 4)
	if !to_ok {
		return ERROR_NAME
	}
	return entry_rename(named.caller.store, path_names(&named.path), named.name, path_names(&to_path), to, error)
}

// The two handles of a share, as the caller names them, and the number of the share for unshare.
Shared :: struct {
	share:  i64,
	ring:   i64, // Memory: the call ring.
	region: i64, // Memory: the call region.
}

// share makes a new connection to this service whose root is the tree of a place, and gives its call ring and its call region to the caller, which can give them to another program. With read_only 1 the connection changes nothing. A connection that reads only makes shares that read only. The share ends when the caller calls unshare, or when the connection that made it loses its store. The result is one row, or a negative number with an error record.
//
// **Error kinds**
//
// - `No_Grant` (-1);
// - `Absent` (-12, -7: the place);
// - `Full` (-5, unit Connections: no free share);
// - `Refused` (-6: the kernel refused a memory object or a give).
@(export, link_name = "share")
share :: proc "c" (place: i64, read_only: i64, result: ^[]Shared, error: ^errors.Error_Record) -> i64 {
	caller := caller_of()
	if caller.connection == nil || caller.store.limit == 0 {
		return errors.fail(error, ERROR_NO_STORE, .No_Grant, .Store)
	}
	path, ok := place_path(&caller, place, error, 1)
	if !ok {
		return ERROR_PLACE
	}
	if !path.own {
		return errors.fail(error, ERROR_NO_STORE, .No_Grant, .Store, 1)
	}
	free: ^Share
	for &item in shares {
		if item.connection.calls.head == nil {
			free = &item
			break
		}
	}
	if free == nil {
		return errors.fail(error, ERROR_FULL, .Full, .Connections, 0, 0, SHARE_CAPACITY)
	}
	ring_memory, ring_status := system.memory_create(ring.PAGE_COUNT)
	if ring_status != .Ok {
		return errors.fail(error, ERROR_DISK, .Refused, .None, 0, 0, 0, i64(ring_status))
	}
	region_memory, region_status := system.memory_create(isolated.REGION_PAGES)
	if region_status != .Ok {
		system.close(ring_memory)
		return errors.fail(error, ERROR_DISK, .Refused, .None, 0, 0, 0, i64(region_status))
	}
	connection, connection_ok := system.connection_make(ring_memory, region_memory, system.name_unpack(system.name_pack(caller.store.name)))
	if !connection_ok {
		system.close(ring_memory)
		system.close(region_memory)
		return errors.fail(error, ERROR_DISK, .Refused)
	}
	given_ring, give_status := system.give(caller.connection.ring_memory, ring_memory, {.Read, .Write})
	given_region: system.Handle
	if give_status == .Ok {
		given_region, give_status = system.give(caller.connection.ring_memory, region_memory, {.Read, .Write})
	}
	if give_status != .Ok {
		system.handle_revoke(ring_memory)
		system.connection_end(&connection)
		return errors.fail(error, ERROR_DISK, .Refused, .None, 0, 0, 0, i64(give_status))
	}
	free^ = {connection = connection, maker = caller.connection.ring_memory, read_only = read_only != 0 || caller.read_only, depth = path.depth}
	copy(free.path[:], path.names[:path.depth])
	number := i64(intrinsics.ptr_sub(free, &shares[0])) + 1
	if len(result) > 0 {
		result[0] = {share = number, ring = i64(given_ring), region = i64(given_region)}
	}
	system.log("storage: a share of the store ", caller.store.name, free.read_only ? string(", read only") : string(""), ", the share ", number)
	return 1
}

// share_end revokes the handles of a share in each program that has them,
// and frees it and its places.
share_end :: proc "contextless" (item: ^Share) {
	system.handle_revoke(item.connection.ring_memory)
	system.handle_revoke(item.connection.region_memory)
	holder := item.connection.ring_memory
	for &place in places {
		if place.holder == holder {
			place.holder = 0
			place.generation += 1
		}
	}
	pending_drop_of(holder)
	system.connection_end(&item.connection)
	item^ = {}
}

// unshare ends a share that this connection made: the kernel ends its handles in each program that has them, and its places end. The result is 0, or a negative number with an error record.
//
// **Error kinds**
//
// - `Absent` (-12, unit Connections: no share of this connection has this number).
@(export, link_name = "unshare")
unshare :: proc "c" (number: i64, error: ^errors.Error_Record) -> i64 {
	caller := caller_of()
	if caller.connection == nil || number < 1 || number > SHARE_CAPACITY {
		return errors.fail(error, ERROR_PLACE, .Absent, .Connections, 1, number)
	}
	item := &shares[number - 1]
	if item.connection.calls.head == nil || item.maker != caller.connection.ring_memory {
		return errors.fail(error, ERROR_PLACE, .Absent, .Connections, 1, number)
	}
	share_end(item)
	system.log("storage: the share ", number, " ended")
	return 0
}

// The counts of the store of a connection.
Usage :: struct {
	objects:  i64, // With the objects of the trees that wait to be freed.
	trees:    i64,
	versions: i64,
	blocks:   i64, // The distinct blocks of the store.
	limit:    i64,
	removing: i64, // The trees that a remove took out, and whose blocks are not free yet.
}

// usage gives the counts of the store of the caller, in one row.
@(export, link_name = "usage")
usage :: proc "c" (result: ^[]Usage) -> i64 {
	caller := caller_of()
	row: Usage
	if caller.connection != nil {
		row.limit = i64(caller.store.limit)
		if index := store_find(caller.store.name); index >= 0 {
			row.objects = i64(store_blocks[index].objects)
			row.trees = i64(store_blocks[index].trees)
			row.versions = i64(opened.store_versions[index])
			row.blocks = i64(root.stores[index].used)
			row.removing = i64(store_blocks[index].removing)
		}
	}
	if len(result) > 0 {
		result[0] = row
	}
	return 1
}

// stores gives the stores that the caller may name, one line for each, with its objects, its trees, its versions, its blocks (a shared block counted one time), the blocks that two names share, its limit, the count of connections that hold its grant now, and its damage. Only a caller that acts for a principal sees them: the stores of that principal.
@(export, link_name = "stores")
stores :: proc "c" (result: ^[]u8) -> i64 {
	caller := caller_of()
	writer := system.Writer{buffer = result^}
	if !caller.acts_for_principal {
		system.write_part(&writer, "no grant to see the stores")
		return i64(writer.count + writer.dropped)
	}
	parts := [?]system.Part{"generation ", root.generation, ", ", opened.in_use_count, " of ", root.disk_blocks, " blocks in use, ", commits, " commits and ", blocks_written, " blocks written since the start"}
	for part in parts {
		system.write_part(&writer, part)
	}
	for &store, index in root.stores {
		// The one rule of the stores that a caller may name: here, the
		// stores that it sees.
		if store.name[0] == 0 || !may_name_store(&caller, system.name_of(store.name[:])) {
			continue
		}
		holders: u64
		for &connection in service.connections {
			if connection.calls.head != nil && system.name_of(connection.caller[:]) == system.name_of(store.name[:]) && connection.grant & isolated.CALLER_AMOUNT_MASK != 0 {
				holders += 1
			}
		}
		counts := &store_blocks[index]
		line := [?]system.Part{"\n", system.name_of(store.name[:]), ": ", counts.objects, " objects, ", counts.trees, " trees, ", opened.store_versions[index], " versions, ", store.used, " of ", store.limit, " blocks, ", opened.store_shared[index], " shared, ", holders, holders == 1 ? string(" connection") : string(" connections")}
		for part in line {
			system.write_part(&writer, part)
		}
		if counts.removing != 0 {
			tail := [?]system.Part{", ", counts.removing, " trees to free"}
			for part in tail {
				system.write_part(&writer, part)
			}
		}
		if store_damaged[index] {
			system.write_part(&writer, ", a node of its trees has a wrong check")
		} else if opened.store_damaged_objects[index] != 0 {
			tail := [?]system.Part{", ", opened.store_damaged_objects[index], " damaged"}
			for part in tail {
				system.write_part(&writer, part)
			}
		}
	}
	return i64(writer.count + writer.dropped)
}

// ---------------------------------------------------------------------
// The exports of versions.

// open_store gives a place on the root of another store, for the exports that read it and for restore and clone: a caller that acts for principal N names the stores of principal N; another caller names its own store only (may_name_store). write, add, remove, rename and share refuse a place of another store. The result is the place, or a negative number with an error record.
//
// **Error kinds**
//
// - `No_Grant` (-10, unit Acts_For_Principal: the caller may not name this store);
// - `Absent` (-7, unit Stores: no such store);
// - `Full` (-5, unit Places: no free place).
@(export, link_name = "open_store")
open_store :: proc "c" (store: ^string, error: ^errors.Error_Record) -> i64 {
	caller := caller_of()
	if caller.connection == nil {
		return errors.fail(error, ERROR_NO_STORE, .No_Grant, .Store)
	}
	// The name is copied one time: the caller can change the call region.
	copied: system.Name
	count := copy(copied[:len(copied) - 1], store^)
	name := string(copied[:count])
	if !may_name_store(&caller, name) {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	index := store_find(name)
	if index < 0 || len(store^) >= len(copied) {
		return errors.fail(error, ERROR_ABSENT, .Absent, .Stores, 1)
	}
	path := Path{store = {system.name_of(root.stores[index].name[:]), root.stores[index].limit}}
	opened_place, ok := place_new(&caller, &path)
	if !ok {
		return errors.fail(error, ERROR_FULL, .Full, .Places, 0, 0, PLACE_CAPACITY)
	}
	return opened_place
}

// One row of versions(): one state of an object.
Version :: struct {
	generation: i64, // The commit that made this state.
	time:       i64, // Milliseconds since the format of the disk, at that commit (the time that a machine ran).
	date:       i64, // Seconds since 1970 (UTC) at that commit. 0: the system had no date.
	bytes:      i64,
	own_blocks: i64, // The blocks that only this state holds: what thinning it frees.
	current:    i64, // 1: the current version, the last row.
}

// One row of compare(): bytes that differ between two states.
Byte_Range :: struct {
	first: i64, // The offset of the first byte that differs.
	count: i64,
}

// versions gives the states of the object `name` under a place, the oldest first, and its current version last: the generation, the time since the format of the disk, the date, the bytes, and the blocks that only this state holds. The place can be a place of another store (open_store). The result is the count of the rows, or a negative number with an error record.
//
// **Error kinds**
//
// - `No_Grant` (-1, the caller has no store);
// - `Absent` (-12: the place);
// - `Empty`, `Too_Long` or `Bad_Byte` (-3, the name);
// - `Absent` (-7, no such object);
// - `Damaged` (-8, the version index of the object has a wrong check);
// - `Device` (-6).
@(export, link_name = "versions")
versions :: proc "c" (place: i64, name: ^string, result: ^[]Version, error: ^errors.Error_Record) -> i64 {
	named, refused := named_of(place, name^, error, 1, false)
	if refused < 0 {
		return refused
	}
	_, object, located := object_locate(named.path.store.name, path_names(&named.path), named.name, error, 2)
	if located < 0 {
		return located
	}
	if count := versions_list(&object, error); count < 0 {
		return count
	}
	rows := listed_count + 1
	// The blocks that only one state holds: the walk of each state goes
	// down the nodes that only it names.
	for row in 0 ..< min(rows, len(result)) {
		entry := row < listed_count ? listed[row] : Version_Entry{generation = object.generation, size = object.size, time = object.time, date = object.date, root = object.pointer}
		result[row] = {generation = i64(entry.generation), time = i64(entry.time), date = i64(entry.date), bytes = i64(entry.size), own_blocks = i64(own_blocks(entry.root, entry.size)), current = i64(row == listed_count)}
	}
	return i64(rows)
}

// version gives the bytes of the object `name` under a place at a generation: one of its versions, or its current version. The place: as for versions. The result is the count of bytes, or a negative number with an error record.
//
// **Error kinds**
//
// - those of versions;
// - `Absent` (-9, the object has no version of this generation);
// - `Damaged` (-8, a block of this version has a wrong check).
@(export, link_name = "version")
version :: proc "c" (place: i64, name: ^string, generation: i64, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	named, refused := named_of(place, name^, error, 1, false)
	if refused < 0 {
		return refused
	}
	_, object, located := object_locate(named.path.store.name, path_names(&named.path), named.name, error, 2)
	if located < 0 {
		return located
	}
	state, state_refused := state_at(&object, generation, 3, error)
	if state_refused < 0 {
		return state_refused
	}
	if state.size > u64(len(result)) {
		return i64(state.size) // The caller sees that it does not fit.
	}
	return state_read(state, 0, result^[:state.size], error, 2)
}

// restore makes a version of the object `name` under a place its current version again, in one commit: the current version before it becomes a version, so nothing is lost. No block of data is written: the object names the blocks of the version. The place: as for versions. The result is the generation of the commit, or a negative number with an error record.
//
// **Error kinds**
//
// - those of version, and those of write.
@(export, link_name = "restore")
restore :: proc "c" (place: i64, name: ^string, generation: i64, error: ^errors.Error_Record) -> i64 {
	named, refused := named_of(place, name^, error, 1, false)
	if refused < 0 {
		return refused
	}
	if named.caller.read_only {
		return errors.fail(error, ERROR_PLACE, .No_Grant, .Changes)
	}
	_, object, located := object_locate(named.path.store.name, path_names(&named.path), named.name, error, 2)
	if located < 0 {
		return located
	}
	if generation == i64(object.generation) && state_damaged(object.pointer) {
		// The current version is damaged: a restore of it would keep the
		// damage, and say that the object is whole.
		return errors.fail(error, ERROR_DAMAGED, .Damaged, .Objects, 2)
	}
	state, state_refused := state_at(&object, generation, 3, error)
	if state_refused < 0 {
		return state_refused
	}
	return object_change(named.path.store, path_names(&named.path), named.name, .Restore, nil, state, error, 2)
}

// clone makes the object `new_name` under a place a copy of the object `name` under the same place: the two name the same blocks until one of them changes. A state of new_name before becomes a version. The place: as for versions. The result is the generation of the commit, or a negative number with an error record.
//
// **Error kinds**
//
// - those of restore;
// - new_name is argument 3.
@(export, link_name = "clone")
clone :: proc "c" (place: i64, name: ^string, new_name: ^string, error: ^errors.Error_Record) -> i64 {
	named, refused := named_of(place, name^, error, 1, false)
	if refused < 0 {
		return refused
	}
	if named.caller.read_only {
		return errors.fail(error, ERROR_PLACE, .No_Grant, .Changes)
	}
	_, object, located := object_locate(named.path.store.name, path_names(&named.path), named.name, error, 2)
	if located < 0 {
		return located
	}
	if state_damaged(object.pointer) {
		return errors.fail(error, ERROR_DAMAGED, .Damaged, .Objects, 2)
	}
	target, target_ok := name_keep(new_name^, error, 3)
	if !target_ok {
		return ERROR_NAME
	}
	return object_change(named.path.store, path_names(&named.path), target, .Clone, nil, current_state(&object), error, 3)
}

// compare gives the ranges of bytes that differ between two states of the object `name` under a place (two generations: a version or the current version). Two blocks that the two states both name are equal bytes and are not read. The place: as for versions. The result is the count of the ranges, or a negative number with an error record.
//
// **Error kinds**
//
// - those of version;
// - first and second are arguments 3 and 4.
@(export, link_name = "compare")
compare :: proc "c" (place: i64, name: ^string, first: i64, second: i64, result: ^[]Byte_Range, error: ^errors.Error_Record) -> i64 {
	named, refused := named_of(place, name^, error, 1, false)
	if refused < 0 {
		return refused
	}
	_, object, located := object_locate(named.path.store.name, path_names(&named.path), named.name, error, 2)
	if located < 0 {
		return located
	}
	states: [2]State_Of_Object
	for generation, index in ([2]i64{first, second}) {
		state, state_refused := state_at(&object, generation, 3 + i64(index), error)
		if state_refused < 0 {
			return state_refused
		}
		states[index] = state
	}
	for state, index in states {
		if state.size > format.OBJECT_SIZE_LIMIT || state_damaged(state.root) {
			return errors.fail(error, ERROR_DAMAGED, .Damaged, .Objects, 3 + i64(index))
		}
	}
	ranges: i64
	open_first: i64 = -1
	sizes := [2]i64{i64(states[0].size), i64(states[1].size)}
	low, high := min(sizes[0], sizes[1]), max(sizes[0], sizes[1])
	trees := [2]block_tree.State{tree_state(states[0]), tree_state(states[1])}
	// The blocks that one of the two states holds, in their order: a hole in
	// both, and a block that both name, are equal bytes and are not read.
	end_blocks := max(blocks_of(states[0].size), blocks_of(states[1].size))
	for at: u64 = 0; at < end_blocks; {
		found_at: [2]u64
		found_pointer: [2]Pointer
		next := end_blocks
		for side in 0 ..< 2 {
			found_at[side] = end_blocks
			index, pointer, found, outcome := block_tree.next_block(&object_source, trees[side], at, &object_nodes)
			if outcome != .Good {
				return errors.fail(error, outcome == .Device ? ERROR_DISK : ERROR_DAMAGED, outcome == .Device ? .Device : .Damaged, .Objects, 3 + i64(side))
			}
			if found {
				found_at[side], found_pointer[side] = index, pointer
				next = min(next, index)
			}
		}
		compare_span(result^, &ranges, &open_first, i64(at * BLOCK_SIZE), i64(next * BLOCK_SIZE), low, high)
		if next >= end_blocks {
			break
		}
		here: [2]Pointer
		for side in 0 ..< 2 {
			if found_at[side] == next {
				here[side] = found_pointer[side]
			}
		}
		base := i64(next * BLOCK_SIZE)
		if here[0] == here[1] {
			compare_span(result^, &ranges, &open_first, base, base + BLOCK_SIZE, low, high)
		} else {
			for side in 0 ..< 2 {
				compare_blocks[side] = {}
				if here[side].block == 0 {
					continue
				}
				if _, outcome := block_tree.block_check(&object_source, here[side], next, &compare_blocks[side]); outcome != .Good {
					return errors.fail(error, outcome == .Device ? ERROR_DISK : ERROR_DAMAGED, outcome == .Device ? .Device : .Damaged, .Objects, 3 + i64(side))
				}
			}
			for offset in 0 ..< i64(BLOCK_SIZE) {
				at_byte := base + offset
				if at_byte >= high {
					break
				}
				inside := [2]bool{at_byte < sizes[0], at_byte < sizes[1]}
				differs := inside[0] != inside[1] || compare_blocks[0][offset] != compare_blocks[1][offset]
				if differs && open_first < 0 {
					open_first = at_byte
				} else if !differs {
					compare_close(result^, &ranges, &open_first, at_byte)
				}
			}
		}
		at = next + 1
	}
	compare_close(result^, &ranges, &open_first, high)
	return ranges
}

compare_blocks: [2]Block // The two blocks of data that compare reads.

// compare_close ends the range that differs, at `end`.
compare_close :: proc "contextless" (result: []Byte_Range, ranges: ^i64, open_first: ^i64, end: i64) {
	if open_first^ < 0 {
		return
	}
	if ranges^ < i64(len(result)) {
		result[ranges^] = {first = open_first^, count = end - open_first^}
	}
	ranges^ += 1
	open_first^ = -1
}

// compare_span takes the bytes [from, to) that are equal in the two states
// where both have them: they differ only between the two sizes (low and
// high).
compare_span :: proc "contextless" (result: []Byte_Range, ranges: ^i64, open_first: ^i64, from: i64, to: i64, low: i64, high: i64) {
	if from < min(to, low) {
		compare_close(result, ranges, open_first, from)
	}
	if max(from, low) < min(to, high) && open_first^ < 0 {
		open_first^ = max(from, low)
	}
}

// ---------------------------------------------------------------------
// The service.

service: system.Service

// shares_serve executes the calls that wait on the shares.
shares_serve :: proc "contextless" () -> (calls: int) {
	for &item in shares {
		if item.connection.calls.head != nil {
			calls += system.connection_serve(&service, &item.connection)
		}
	}
	return calls
}

// The entry of the storage service: it attaches to the block service of the data disk, opens the disk, then
// serves the calls of its connections for the life of the machine.
//
// The root service starts it on demand: at the first connection to `storage`, or before the first program with a
// private store. The entry, in order:
//
// 1. opens its service ring and the block ring; with no ring, it writes "storage: no service ring" or
//    "storage: no block ring" and stops with the code 1;
// 2. creates the data region, one contiguous memory object that the device reads and writes, and gives it to the
//    block service with the command `Attach`; a refusal stops it with the code 1;
// 3. opens the disk (`mount`): it reads the two roots, takes the newest one with a good check, and checks each
//    block that a store names.
//
// The open ends in one of three ways:
//
// - **no valid root**: "storage: no valid root on the disk"; the service keeps the disk as it is, serves nothing,
//   and stops with the code 1;
// - **a new disk**: it formats the disk and writes "storage: ok, a new disk: generation 1, N blocks";
// - **a disk with data**: "storage: ok, generation G: S stores, O objects, ...", with one warning line for each
//   kind of damage that it found. A damaged object gives `Damaged` to a read; the other objects are served.
//
// Then one loop runs for ever. It waits on the service ring and on each share, and runs the calls that wait. When
// no call waits, it frees one step of a tree that a removal left: a large removal never makes a caller wait.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	date_page = date.page_of(ctx)
	ok: bool
	if service, ok = system.service_open(ctx); !ok {
		system.log_in("storage", .Error, "storage: no service ring")
		system.stop(1)
	}
	ring_memory := ctx.handles[block.GRANT_RING]
	status: system.Status
	if blocks, status = system.ring_open(ring_memory); status != .Ok {
		system.log_in("storage", .Error, "storage: no block ring")
		system.stop(1)
	}
	memory, memory_status := system.memory_create(REGION_BLOCKS, 0, {.Contiguous}) // The device reads and writes it.
	address, map_status := system.memory_map(memory, {.Write})
	if memory_status != .Ok || map_status != .Ok {
		system.log_in("storage", .Error, "storage: no data region")
		system.stop(1)
	}
	region = ([^]u8)(address)
	// The block service maps the ring when it starts.
	given: system.Handle
	give_status := system.Status.Bad_Handle
	for attempt := 0; attempt < 2000 && give_status != .Ok; attempt += 1 {
		if given, give_status = system.give(ring_memory, memory, {.Read, .Write}); give_status != .Ok {
			system.sleep(system.time() + 1)
		}
	}
	if give_status != .Ok || block.Status(command(.Attach, {0 = u64(given)}).kind) != .Ok {
		system.log_in("storage", .Error, "storage: the block service refused the data region")
		system.stop(1)
	}
	info := command(.Info)
	start := system.time()
	mounted := mount(info.values[0])
	elapsed := system.time() - start
	switch {
	case mounted.failed:
		system.log_in("storage", .Error, "storage: no valid root on the disk: the service keeps the disk as it is, and serves nothing")
		system.stop(1)
	case mounted.needs_format:
		if mounted.first_cut {
			system.log_in("storage", .Warning, "storage: the first root of the disk has a wrong check and no commit followed it: a format that a stop cut; the service formats again")
		}
		system.log("storage: ok, a new disk: generation 1, ", system.Size{root.disk_blocks, .Blocks})
	case:
		if mounted.cut != 0 {
			system.log_in("storage", .Warning, "storage: the root of generation ", mounted.cut, " has a wrong check: a write that a stop cut; the service uses the root before it")
		}
		if mounted.older {
			system.log_in("storage", .Warning, "storage: the newest root names a block with a wrong check, and the root before it names none: the root before it is used")
		}
		if mounted.wrong != 0 {
			system.log_in("storage", .Warning, "storage: ", mounted.wrong, " blocks have a wrong check: ", mounted.damaged_objects, " objects and ", mounted.damaged_stores, " stores are damaged; the service serves the others, and a write or a remove replaces a damaged object")
		}
		if mounted.damaged_versions != 0 {
			system.log_in("storage", .Warning, "storage: ", mounted.damaged_versions, " versions have a wrong block: a read of them gives Damaged")
		}
		if mounted.named_twice != 0 || mounted.named_by_two_stores != 0 || mounted.reference_overflow != 0 {
			faulty: u64
			for flag in opened.store_faulty {
				faulty += u64(flag)
			}
			system.log_in("storage", .Error, "storage: a fault of the engine: ", mounted.named_twice, " blocks of one name named two times, ", mounted.named_by_two_stores, " blocks named from two stores, ", mounted.reference_overflow, " counts of names that pass their limit; the service makes no change in the ", faulty, faulty == 1 ? string(" store") : string(" stores"), " with such a block, and gives their objects")
		}
		if mounted.stores_recounted != 0 || mounted.stores_with_wrong_count != 0 {
			system.log_in("storage", .Warning, "storage: the disk gives ", mounted.stores_recounted, " stores another count of blocks than the open counted; the service takes the counts of the open (", mounted.stores_with_wrong_count, " stores with no damage have a wrong count: a fault of the engine that wrote it)")
		}
		system.log("storage: ok, generation ", mounted.generation, ": ", mounted.stores, " stores, ", mounted.objects, " objects, ", mounted.trees, " trees, ", mounted.versions, " versions, ", system.Size{opened.in_use_count, .Blocks}, " in use, ", mounted.shared, " shared, ", mounted.checked, " blocks checked, ", mounted.wrong, " wrong, in ", system.Duration{elapsed, .Milliseconds})
		if mounted.removing != 0 {
			system.log("storage: ", mounted.removing, " trees wait to be freed: the removal continues")
		}
	}
	for {
		// A removal that waits runs when no call waits: the service then
		// looks at its rings and does not sleep.
		if !removal_waits() {
			wait: system.Wait
			system.service_wait(&wait, &service)
			for &item in shares {
				if item.connection.calls.head != nil {
					system.wait_records(&wait, &item.connection.calls.commands)
				}
			}
			system.wait_end(&wait)
		}
		calls := system.service_run(&service)
		calls += shares_serve()
		if calls == 0 {
			removal_step()
		}
	}
}
