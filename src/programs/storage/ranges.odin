package storage_service

import "base:intrinsics"
import "modus:contract/errors"
import format "modus:contract/store"
import answers "modus:support/storage"
import block_tree "modus:support/storage_object"
import "modus:support/system"

// Ranges (docs/STORAGE.md, "Ranges"): a connection writes ranges of an
// object and changes its size as pending changes, then commits them in one
// commit. A pending change is a copy of a block of data in the service: it
// is not on the disk, and no hash is computed for it. The commit puts the
// pending blocks in the block tree of the object (src/library/support/storage_object),
// computes the values of those blocks and of the nodes above them, and the
// hash on the path of the last block: never at each write, and never over
// the whole object. A loss of power before the commit loses the pending
// changes, and nothing else: the disk has the last commit.

ERROR_PENDING :: answers.ERROR_PENDING

// The pending changes of the service: the objects, and their blocks. A
// connection has at most one pending object for each name; the blocks are
// shared by all the pending objects. 1024 blocks: 4 MiB, the blocks of
// data that one commit can write.
PENDING_OBJECT_CAPACITY :: 16
PENDING_BLOCK_CAPACITY :: 1024

// The pending changes of one object on one connection.
Pending_Object :: struct {
	holder:          system.Handle, // The call ring of the connection. 0: free.
	store:           system.Name,
	depth:           int,
	path:            [NESTING_LIMIT]Entry_Name,
	name:            Entry_Name,
	base_generation: u64, // The generation of the entry at the first change; 0: no entry.
	size:            u64, // The size with the pending changes.
	cut:             u64, // The least size since the first change: each byte of the state before at or past it reads as zero.
	blocks:          int, // Its pending blocks.
}
pending_objects: [PENDING_OBJECT_CAPACITY]Pending_Object

// A pending block: the 4096 bytes of the block `index` of an object after
// the pending changes.
Pending_Block :: struct {
	owner: int, // 1 + the pending object. 0: free.
	index: u64,
	bytes: Block,
}
pending_blocks: [PENDING_BLOCK_CAPACITY]Pending_Block
pending_change_list: [PENDING_BLOCK_CAPACITY]block_tree.Change
pending_blocks_used: int

// What one commit did on its object: the row of the export commit. The
// service writes it on the log too.
Commit_Measure :: struct {
	generation:     i64,
	object_blocks:  i64, // The blocks of the object after the commit, holes included: N.
	held_blocks:    i64, // The blocks that the object holds after the commit: its object nodes and its blocks of data.
	changed:        i64, // The blocks of data that the commit changed: K.
	hashed_blocks:  i64, // The blocks of data whose bytes the commit hashed: the changed blocks and the last block of the hash.
	hashed_nodes:   i64, // The object nodes whose value the commit computed.
	object_written: i64, // The blocks of the block tree that the commit wrote: data and object nodes.
	written:        i64, // Each block that the commit wrote: with the nodes of the trees, the versions, the store block and the root.
	milliseconds:   i64,
}

pending_index :: #force_inline proc "contextless" (pending: ^Pending_Object) -> int {
	return int(intrinsics.ptr_sub(pending, &pending_objects[0]))
}

// pending_find gives the pending object of a connection for an object
// under a path, or nil.
pending_find :: proc "contextless" (holder: system.Handle, path: ^Path, name: Entry_Name) -> ^Pending_Object {
	if holder == 0 {
		return nil
	}
	for &pending in pending_objects {
		if pending.holder != holder || pending.name != name || pending.depth != path.depth || system.name_of(pending.store[:]) != path.store.name {
			continue
		}
		same := true
		for step, depth in path.names[:path.depth] {
			same &&= pending.path[depth] == step
		}
		if same {
			return &pending
		}
	}
	return nil
}

// pending_drop frees a pending object and its blocks.
pending_drop :: proc "contextless" (pending: ^Pending_Object) {
	owner := pending_index(pending) + 1
	for &block in pending_blocks {
		if block.owner == owner {
			block.owner = 0
			pending_blocks_used -= 1
		}
	}
	pending^ = {}
}

// pending_sweep drops the pending changes of connections that ended.
pending_sweep :: proc "contextless" () {
	for &pending in pending_objects {
		if pending.holder == 0 {
			continue
		}
		if _, _, found := connection_store(pending.holder, 0); !found {
			pending_drop(&pending)
		}
	}
}

// pending_drop_of drops the pending changes of one connection.
pending_drop_of :: proc "contextless" (holder: system.Handle) {
	for &pending in pending_objects {
		if pending.holder != 0 && pending.holder == holder {
			pending_drop(&pending)
		}
	}
}

// pending_take gives a new pending object.
pending_take :: proc "contextless" (holder: system.Handle, path: ^Path, name: Entry_Name, base_generation: u64, size: u64) -> ^Pending_Object {
	for attempt in 0 ..< 2 {
		for &pending in pending_objects {
			if pending.holder != 0 {
				continue
			}
			pending = {holder = holder, depth = path.depth, name = name, base_generation = base_generation, size = size, cut = size}
			pending.store = system.name_unpack(system.name_pack(path.store.name))
			copy(pending.path[:], path.names[:path.depth])
			return &pending
		}
		if attempt == 0 {
			pending_sweep()
		}
	}
	return nil
}

// pending_block_find gives the pending block `index` of a pending object,
// or -1.
pending_block_find :: proc "contextless" (pending: ^Pending_Object, index: u64) -> int {
	if pending.blocks == 0 {
		return -1
	}
	owner := pending_index(pending) + 1
	for &block, place in pending_blocks {
		if block.owner == owner && block.index == index {
			return place
		}
	}
	return -1
}

// pending_changes gives the pending blocks of a pending object as the
// changes of a commit.
pending_changes :: proc "contextless" (pending: ^Pending_Object) -> []block_tree.Change {
	owner := pending_index(pending) + 1
	count := 0
	for &block in pending_blocks {
		if block.owner == owner {
			pending_change_list[count] = {index = block.index, bytes = &block.bytes}
			count += 1
		}
	}
	return pending_change_list[:count]
}

// The object of a call on ranges: its entry as the last commit gives it,
// and the pending changes of the caller.
Ranged :: struct {
	named:   Named,
	state:   State_Of_Object, // The state of the last commit: no root and size 0 for a name with no entry.
	exists:  bool,
	pending: ^Pending_Object,
}

// ranged_of finds the object of a call on ranges. A name with no entry is
// an object of no byte, when the caller has pending changes for it or makes
// a change.
ranged_of :: proc "contextless" (place: i64, name: string, error: ^errors.Error_Record, change: bool) -> (ranged: Ranged, result: i64) {
	ranged.named, result = named_of(place, name, error, 1, change)
	if result < 0 {
		return ranged, result
	}
	if ranged.named.caller.connection != nil {
		ranged.pending = pending_find(ranged.named.caller.connection.ring_memory, &ranged.named.path, ranged.named.name.key)
	}
	_, value, located := object_locate(ranged.named.path.store.name, path_names(&ranged.named.path), ranged.named.name, error, 2)
	if located >= 0 {
		ranged.state = current_state(&value)
		ranged.exists = true
		return ranged, 0
	}
	if located == ERROR_ABSENT && (change || ranged.pending != nil) {
		// A name that is a tree is refused: the lookup of the name as an
		// object gives Absent for it too, so look at its entry.
		if store_index := store_find(ranged.named.path.store.name); store_index >= 0 {
			if entry, outcome := entry_of(store_index, path_names(&ranged.named.path), ranged.named.name.key); outcome == .Found && entry.kind != .Object {
				return ranged, errors.fail(error, ERROR_ABSENT, .Absent, .Objects, 2)
			} else if outcome == .Wrong || outcome == .Device {
				return ranged, lookup_refusal(outcome, error, 2)
			} else if outcome == .Absent && len(path_names(&ranged.named.path)) != 0 {
				// The tree of the place: it must exist for a new object.
				if _, tree_outcome := tree_of(store_index, path_names(&ranged.named.path)); tree_outcome == .Absent {
					return ranged, errors.fail(error, ERROR_ABSENT, .Absent, .Places, 1)
				} else if tree_outcome != .Found {
					return ranged, lookup_refusal(tree_outcome, error, 1)
				}
			}
		}
		return ranged, 0
	}
	return ranged, located
}

// ranged_size gives the size of the object as the caller sees it.
ranged_size :: proc "contextless" (ranged: ^Ranged) -> u64 {
	return ranged.pending != nil ? ranged.pending.size : ranged.state.size
}

// ranged_read reads bytes from `offset` as the caller sees them: its
// pending blocks, the bytes of the last commit before the cut, and zero
// bytes. It gives the count of bytes, or a negative number.
ranged_read :: proc "contextless" (ranged: ^Ranged, offset: u64, result: []u8, error: ^errors.Error_Record) -> i64 {
	size := ranged_size(ranged)
	if offset >= size {
		return 0
	}
	count := min(u64(len(result)), size - offset)
	pending := ranged.pending
	if pending == nil {
		return state_read(ranged.state, offset, result[:count], error, 2)
	}
	for at := offset; at < offset + count; {
		index := at / BLOCK_SIZE
		inside := at % BLOCK_SIZE
		part := min(BLOCK_SIZE - inside, offset + count - at)
		into := result[at - offset:][:part]
		if place := pending_block_find(pending, index); place >= 0 {
			copy(into, pending_blocks[place].bytes[inside:][:part])
		} else {
			if read := base_read(ranged, at, into, error); read < 0 {
				return read
			}
		}
		at += part
	}
	return i64(count)
}

// base_read reads bytes of the last commit as the pending changes leave
// them: zero bytes at and past the cut.
base_read :: proc "contextless" (ranged: ^Ranged, at: u64, into: []u8, error: ^errors.Error_Record) -> i64 {
	cut := ranged.pending != nil ? ranged.pending.cut : ranged.state.size
	intrinsics.mem_zero(raw_data(into), len(into))
	if at >= cut || !ranged.exists {
		return 0
	}
	kept := min(u64(len(into)), cut - at)
	return state_read(ranged.state, at, into[:kept], error, 2)
}

// pending_block_take gives the pending block `index` of a pending object:
// at its first change, a copy of the block as the caller sees it.
pending_block_take :: proc "contextless" (ranged: ^Ranged, index: u64, error: ^errors.Error_Record) -> (place: int, result: i64) {
	pending := ranged.pending
	if place = pending_block_find(pending, index); place >= 0 {
		return place, 0
	}
	if pending_blocks_used >= PENDING_BLOCK_CAPACITY {
		// The pending blocks of connections that ended go first.
		pending_sweep()
	}
	if pending_blocks_used >= PENDING_BLOCK_CAPACITY {
		return -1, errors.fail(error, ERROR_FULL, .Full, .Pending, 0, 0, PENDING_BLOCK_CAPACITY)
	}
	for &block, free_place in pending_blocks {
		if block.owner != 0 {
			continue
		}
		if read := base_read(ranged, index * BLOCK_SIZE, block.bytes[:], error); read < 0 {
			return -1, read
		}
		block.owner = pending_index(pending) + 1
		block.index = index
		pending.blocks += 1
		pending_blocks_used += 1
		return free_place, 0
	}
	return -1, errors.fail(error, ERROR_FULL, .Full, .Pending, 0, 0, PENDING_BLOCK_CAPACITY)
}

// ranged_pending gives the pending object of the caller, and makes it at
// the first change.
ranged_pending :: proc "contextless" (ranged: ^Ranged, error: ^errors.Error_Record) -> i64 {
	if ranged.pending != nil {
		return 0
	}
	base: u64
	if ranged.exists {
		base = ranged.state.generation
	}
	ranged.pending = pending_take(ranged.named.caller.connection.ring_memory, &ranged.named.path, ranged.named.name.key, base, ranged.state.size)
	if ranged.pending == nil {
		return errors.fail(error, ERROR_FULL, .Full, .Pending, 0, 0, PENDING_OBJECT_CAPACITY)
	}
	return 0
}

// read_range copies the bytes of the object `name` under a place from `offset` into result, up to its end: as this connection sees it, with its pending changes. A hole reads as zero bytes. The result is the count of bytes (0 at the end), or a negative number with an error record.
//
// The error kinds: those of read; Out_Of_Range (-3, offset is past the end: limit the size).
@(export, link_name = "read_range")
read_range :: proc "c" (place: i64, name: ^string, offset: i64, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	ranged, refused := ranged_of(place, name^, error, false)
	if refused < 0 {
		return refused
	}
	size := ranged_size(&ranged)
	if offset < 0 || u64(offset) > size {
		return errors.fail(error, ERROR_NAME, .Out_Of_Range, .Bytes, 3, offset, i64(size))
	}
	return ranged_read(&ranged, u64(offset), result^, error)
}

// write_range writes the bytes of data at `offset` of the object `name` under a place, as a pending change of this connection: no commit, and no hash. A read of this connection sees it at once; another connection sees the object as its last commit gives it. The object grows when the range passes its end; a new name is a new object at the commit. A loss of power before commit loses the pending changes. The result is the size of the object with the pending changes, or a negative number with an error record.
//
// The error kinds: No_Grant (-1; -12, unit Changes: the connection reads only); Absent (-12, -7: the place; -7, unit Objects: the name is a tree); the errors of a name (-3); Bad_Value (-3: offset is negative); Too_Long (-4: the object would pass 4 TiB); Full (-5, unit Pending: the service holds no more pending blocks or objects: commit first); Damaged (-8: a block that the range changes in part has a wrong check); Device (-6).
@(export, link_name = "write_range")
write_range :: proc "c" (place: i64, name: ^string, offset: i64, data: ^string, error: ^errors.Error_Record) -> i64 {
	ranged, refused := ranged_of(place, name^, error, true)
	if refused < 0 {
		return refused
	}
	count := u64(len(data^))
	if offset < 0 {
		return errors.fail(error, ERROR_NAME, .Bad_Value, .Bytes, 3, offset)
	}
	if u64(offset) > format.OBJECT_SIZE_LIMIT || count > format.OBJECT_SIZE_LIMIT - u64(offset) {
		return errors.fail(error, ERROR_TOO_LARGE, .Too_Long, .Bytes, 3, offset + i64(count), i64(format.OBJECT_SIZE_LIMIT))
	}
	if pending_refused := ranged_pending(&ranged, error); pending_refused < 0 {
		return pending_refused
	}
	pending := ranged.pending
	bytes := transmute([]u8)data^
	end := u64(offset) + count
	for at := u64(offset); at < end; {
		index := at / BLOCK_SIZE
		inside := at % BLOCK_SIZE
		part := min(BLOCK_SIZE - inside, end - at)
		block_place, taken := pending_block_take(&ranged, index, error)
		if taken < 0 {
			return taken // The blocks of the range before it stay pending.
		}
		copy(pending_blocks[block_place].bytes[inside:][:part], bytes[at - u64(offset):][:part])
		at += part
		pending.size = max(pending.size, at)
	}
	return i64(pending.size)
}

// set_size makes the size of the object `name` under a place `size` bytes, as a pending change of this connection: a cut drops the bytes past it, an extension adds zero bytes, which hold no block. The result is the size, or a negative number with an error record.
//
// The error kinds: those of write_range.
@(export, link_name = "set_size")
set_size :: proc "c" (place: i64, name: ^string, size: i64, error: ^errors.Error_Record) -> i64 {
	ranged, refused := ranged_of(place, name^, error, true)
	if refused < 0 {
		return refused
	}
	if size < 0 {
		return errors.fail(error, ERROR_NAME, .Bad_Value, .Bytes, 3, size)
	}
	if u64(size) > format.OBJECT_SIZE_LIMIT {
		return errors.fail(error, ERROR_TOO_LARGE, .Too_Long, .Bytes, 3, size, i64(format.OBJECT_SIZE_LIMIT))
	}
	if pending_refused := ranged_pending(&ranged, error); pending_refused < 0 {
		return pending_refused
	}
	pending := ranged.pending
	new_size := u64(size)
	if new_size < pending.size {
		// The block that holds the new end keeps its bytes before it, and
		// zero bytes after it; the blocks after it are dropped.
		keep := blocks_of(new_size)
		owner := pending_index(pending) + 1
		for &block in pending_blocks {
			if block.owner == owner && block.index >= keep {
				block.owner = 0
				pending.blocks -= 1
				pending_blocks_used -= 1
			}
		}
		if inside := new_size % BLOCK_SIZE; inside != 0 {
			block_place, taken := pending_block_take(&ranged, new_size / BLOCK_SIZE, error)
			if taken < 0 {
				return taken
			}
			intrinsics.mem_zero(&pending_blocks[block_place].bytes[inside], BLOCK_SIZE - int(inside))
		}
		pending.cut = min(pending.cut, new_size)
	}
	pending.size = new_size
	return size
}

// commit puts the pending changes of this connection on the object `name` under a place in one commit, on the disk when the call returns. The state before becomes a version. The commit hashes the blocks that changed and the object nodes above them, and the path of the last block: never the whole object. The result is one row: the generation, and the measure of the commit (the blocks of the object, the blocks changed, hashed and written); or a negative number with an error record.
//
// The error kinds: those of write; Absent (-13, unit Pending: the object has no pending change on this connection; found 1: another change of the object came first since the first pending change, and the pending changes are dropped); Damaged (-8: the state before is damaged; the pending changes are dropped).
@(export, link_name = "commit")
commit :: proc "c" (place: i64, name: ^string, result: ^[]Commit_Measure, error: ^errors.Error_Record) -> i64 {
	ranged, refused := ranged_of(place, name^, error, true)
	if refused < 0 && refused != ERROR_ABSENT {
		return refused
	}
	pending := ranged.pending
	if pending == nil {
		return errors.fail(error, ERROR_PENDING, .Absent, .Pending, 2)
	}
	start := system.time()
	written_before := blocks_written
	measure: Commit_Measure
	generation := object_change(ranged.named.caller.store, path_names(&ranged.named.path), ranged.named.name, .Ranges, nil, {}, error, 2, pending, &measure)
	if generation < 0 {
		if generation == ERROR_PENDING || generation == ERROR_DAMAGED {
			pending_drop(pending)
		}
		return generation
	}
	pending_drop(pending)
	measure.generation = generation
	measure.written = i64(blocks_written - written_before)
	measure.milliseconds = i64(system.time() - start)
	system.log("storage: the commit of generation ", u64(generation), " of ", kept_text(&ranged.named.name), ": ", u64(measure.changed), " blocks changed of ", u64(measure.object_blocks), ", ", u64(measure.hashed_blocks), " blocks and ", u64(measure.hashed_nodes), " object nodes hashed, ", u64(measure.written), " blocks written; the object holds ", system.Size{u64(measure.held_blocks), .Blocks}, "; in ", system.Duration{u64(measure.milliseconds), .Milliseconds})
	if len(result) > 0 {
		result[0] = measure
	}
	return 1
}
