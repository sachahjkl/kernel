package storage_service

import "base:intrinsics"
import "contract:blake3"
import "contract:errors"
import "contract:isolated"
import format "contract:store"
import "support:storage_mount"
import block_tree "support:storage_object"
import tree "support:storage_tree"
import "support:system"

// The trees of a store (docs/STORAGE.md): each tree is its own B+ tree
// (support/storage_tree), and an entry of kind Tree holds the root node of
// the tree inside it. A commit opens the trees on the paths that it
// changes, changes their entries, then writes them from the deepest up:
// the new root of a tree goes into its entry in the tree above it, up to
// the tree of the store and the store block.

NESTING_LIMIT :: format.NESTING_LIMIT
REMOVAL_STEP_LIMIT :: 64 // The entries that one step of a removal frees: about 200 nodes in the pool, inside the 1024 writes of a commit.
ADD_LIMIT :: 256 // The entries that one call of add makes, in one commit.
PLAN_TREE_CAPACITY :: 2 * (NESTING_LIMIT + 1) + 4 // Two paths (a rename), the removal queue, and the tree that a removal step frees.
PLAN_ENTRY_CAPACITY :: REMOVAL_STEP_LIMIT + 16 // The objects whose versions one commit changes.

Tree_Role :: enum {
	Store_Tree, // The tree of the store: its root is in the store block.
	Removal_Queue, // The removal queue: its root is in the store block.
	Inside, // A tree inside another one: its root is in an entry of its parent.
}

// One tree that a commit opened.
Tree_Open :: struct {
	work:         tree.Work,
	role:         Tree_Role,
	parent:       int, // The tree that holds its entry (role Inside).
	name:         Entry_Name, // Its name in its parent.
	depth:        int, // 0 for a root; else the depth of its parent plus 1.
	count_change: i64, // The change of the count of its entries.
	changed:      bool, // Its entries changed: its entry in its parent changes.
}

// An object whose entry a commit changes, with the work of its versions in
// plan.index_work at the same place.
Plan_Entry :: struct {
	tree:   int,
	name:   Entry_Name,
	entry:  Entry, // Its value after the commit.
	before: Entry, // Its value as the commit found it. Kind None: a new entry.
	gone:   bool, // The commit removes it.
}

entry_bytes :: #force_inline proc "contextless" (entry: ^Entry) -> []u8 {
	return ([^]u8)(entry)[:size_of(Entry)]
}

// The nodes come through the cache of the service, checked.
node_source := tree.Source {
	read = node_read,
}

node_read :: proc "contextless" (_: ^tree.Source, pointer: Pointer, into: ^tree.Block) -> tree.Read {
	if pointer.block < 2 || pointer.block >= disk_size {
		return .Wrong
	}
	switch read_single(pointer, into) {
	case .Good:
		return .Good
	case .Wrong:
		storage_mount.wrong_block_set(&opened, pointer.block)
		return .Wrong
	case .Device:
	}
	return .Device
}

// The nodes that a commit writes go through the plan, and to the cache
// after the commit.
node_writer := tree.Writer {
	write = node_write,
}

node_write :: proc "contextless" (_: ^tree.Writer, bytes: ^tree.Block) -> Pointer {
	pointer := plan_write(bytes)
	if pointer.block != 0 {
		cache_later(pointer, bytes)
	}
	return pointer
}

plan_trees_reset :: proc "contextless" () {
	tree.pool_reset(&plan.pool)
	plan.trees[0] = {work = {pool = &plan.pool, source = &node_source, shape = tree.TREE_SHAPE, root = plan.store_block.tree}, role = .Store_Tree}
	plan.trees[1] = {work = {pool = &plan.pool, source = &node_source, shape = tree.TREE_SHAPE, root = plan.store_block.removals}, role = .Removal_Queue}
	plan.tree_count = 2
}

// plan_trees_failure_take gives the failure of the trees to the plan: a
// commit with one is refused.
plan_trees_failure_take :: proc "contextless" () {
	switch plan.pool.failure {
	case .None:
	case .Device:
		plan.device = true
	case .Wrong, .Damaged:
		plan.tree_damaged = true
		if plan.pool.failed_block != 0 {
			storage_mount.wrong_block_set(&opened, plan.pool.failed_block)
		}
	case .Full:
		capacity_reached(tree.POOL_CAPACITY)
	case .Write:
		// plan_write gave no block: it set the cause (a full disk, or the
		// capacity of a commit).
		if !plan.full && !plan.capacity_reached {
			plan.full = true
		}
	}
}

// Why a tree of a path cannot be opened.
Open_Refusal :: enum {
	None,
	Absent, // A name of the path names no entry, or an object.
	Failed, // The trees failed: plan_refused says why.
}

// plan_tree_open gives the tree at a path from the tree of the store, and
// opens each tree of the path that the commit has not opened.
plan_tree_open :: proc "contextless" (path: []Entry_Name) -> (index: int, refusal: Open_Refusal) {
	current := 0
	for depth in 0 ..< len(path) {
		found := -1
		for candidate in 2 ..< plan.tree_count {
			item := &plan.trees[candidate]
			if item.role == .Inside && item.parent == current && item.name == path[depth] {
				found = candidate
				break
			}
		}
		if found < 0 {
			key := path[depth]
			value: Entry
			if !tree.get(&plan.trees[current].work, key[:], entry_bytes(&value)) {
				return -1, tree.failed(&plan.trees[current].work) ? .Failed : .Absent
			}
			if value.kind != .Tree {
				return -1, .Absent
			}
			if plan.tree_count >= PLAN_TREE_CAPACITY {
				capacity_reached(PLAN_TREE_CAPACITY)
				return -1, .Failed
			}
			found = plan.tree_count
			plan.tree_count += 1
			plan.trees[found] = {
				work   = {pool = &plan.pool, source = &node_source, shape = tree.TREE_SHAPE, root = value.pointer},
				role   = .Inside,
				parent = current,
				name   = key,
				depth  = depth + 1,
			}
		}
		current = found
	}
	return current, .None
}

// plan_entry_load gives the plan entry of a name of a tree. found is false
// when the tree has no such entry (or the trees failed: see plan_refused).
plan_entry_load :: proc "contextless" (tree_index: int, name: Entry_Name) -> (index: int, found: bool) {
	for &item, candidate in plan.entries[:plan.entry_count] {
		if item.tree == tree_index && item.name == name {
			return candidate, !item.gone
		}
	}
	value: Entry
	key := name
	if !tree.get(&plan.trees[tree_index].work, key[:], entry_bytes(&value)) {
		return -1, false
	}
	index = plan_entry_new(tree_index, name)
	if index < 0 {
		return -1, false
	}
	plan.entries[index].entry = value
	plan.entries[index].before = value
	return index, true
}

// plan_entry_new gives a new plan entry, with no value.
plan_entry_new :: proc "contextless" (tree_index: int, name: Entry_Name) -> int {
	if plan.entry_count >= PLAN_ENTRY_CAPACITY {
		capacity_reached(PLAN_ENTRY_CAPACITY)
		return -1
	}
	index := plan.entry_count
	plan.entry_count += 1
	plan.entries[index] = {tree = tree_index, name = name}
	plan.index_work[index].loaded = false
	plan.index_work[index].touched = false
	return index
}

// plan_entry_remove takes an entry out of its tree.
plan_entry_remove :: proc "contextless" (index: int) {
	item := &plan.entries[index]
	opened_tree := &plan.trees[item.tree]
	key := item.name
	if item.before.kind != .None {
		tree.remove(&opened_tree.work, key[:])
		opened_tree.count_change -= 1
		opened_tree.changed = true
	}
	item.gone = true
}

// plan_entries_put puts the value of each plan entry in its tree.
plan_entries_put :: proc "contextless" () {
	for &item in plan.entries[:plan.entry_count] {
		if item.gone || item.entry == item.before {
			continue
		}
		opened_tree := &plan.trees[item.tree]
		key := item.name
		tree.put(&opened_tree.work, key[:], entry_bytes(&item.entry), true)
		if item.before.kind == .None {
			opened_tree.count_change += 1
		}
		opened_tree.changed = true
	}
}

// plan_trees_finish writes the trees that changed, from the deepest up,
// and puts their roots in the store block. An empty tree of the removal
// queue leaves the queue: its removal is finished.
plan_trees_finish :: proc "contextless" () {
	generation := root.generation + 1
	now := time_now()
	date := date_now()
	for depth := NESTING_LIMIT + 1; depth >= 1; depth -= 1 {
		for index in 2 ..< plan.tree_count {
			item := &plan.trees[index]
			if item.depth != depth || !item.changed {
				continue
			}
			new_root := tree.finish(&item.work, &node_writer)
			parent := &plan.trees[item.parent]
			key := item.name
			value: Entry
			if !tree.get(&parent.work, key[:], entry_bytes(&value)) {
				// The entry of an open tree left its parent in the same commit:
				// the engine never does that.
				plan.tree_damaged = true
				continue
			}
			value.pointer = new_root
			value.size = u64(max(i64(value.size) + item.count_change, 0))
			if parent.role == .Removal_Queue && tree.is_empty(new_root) {
				tree.remove(&parent.work, key[:])
				parent.changed = true
				plan.store_block.removing -= 1
				plan.store_block.trees -= 1
				continue
			}
			value.generation, value.time, value.date = generation, now, date
			tree.put(&parent.work, key[:], entry_bytes(&value), true)
			parent.changed = true
		}
	}
	plan.store_block.tree = tree.finish(&plan.trees[0].work, &node_writer)
	plan.store_block.removals = tree.finish(&plan.trees[1].work, &node_writer)
	for pointer in plan.pool.released[:plan.pool.released_count] {
		delta_add(pointer.block, -1)
	}
	plan.store_block.node_blocks = u64(i64(plan.store_block.node_blocks) + i64(plan.pool.written) - i64(plan.pool.released_count))
	plan_trees_failure_take()
}

// plan_trees_node_change gives the change of the count of nodes that the
// trees will make: the dirty nodes, less the nodes that they replace, and
// for each tree inside a tree that changed, the path of its entry in the
// tree above it, which finish makes dirty (three levels: a tree of 40000
// entries).
plan_trees_node_change :: proc "contextless" () -> i64 {
	dirty: i64
	for &slot in plan.pool.slots {
		if slot.state == .Dirty {
			dirty += 1
		}
	}
	for index in 2 ..< plan.tree_count {
		if plan.trees[index].changed {
			dirty += 3
		}
	}
	return dirty - i64(plan.pool.released_count)
}

// state_blocks_of gives the blocks that a state of an object holds: its
// object nodes and its blocks of data, from its root node. A root that is
// wrong gives 0, as the open counts it.
state_blocks_of :: proc "contextless" (root: Pointer, size: u64) -> u64 {
	if root.block == 0 || size > format.OBJECT_SIZE_LIMIT || storage_mount.wrong_block(&opened, root.block) {
		return 0
	}
	blocks, outcome := block_tree.state_blocks(&object_source, {root = root, size = size}, &object_node)
	switch outcome {
	case .Device:
		plan.device = true
		return 0
	case .Wrong:
		return 0
	case .Good:
	}
	return blocks
}

// current_blocks_change changes the count of the blocks of the current
// objects of the store of the plan; a count that would go below 0 is a
// fault of the engine.
current_blocks_change :: proc "contextless" (added: u64, removed: u64) {
	total := plan.store_block.current_blocks + added
	if removed > total {
		plan.count_fault = true
		plan.store_block.current_blocks = 0
		return
	}
	plan.store_block.current_blocks = total - removed
}

// ---------------------------------------------------------------------
// Names.

// The name of an entry, as the service keeps it for one call. The bytes of
// a name that a caller gives are in the call region, and the caller can
// change them at any time: the service copies them one time, then checks
// and uses the copy only.
Kept_Name :: struct {
	key:   Entry_Name,
	count: int,
}

kept_text :: proc "contextless" (kept: ^Kept_Name) -> string {
	return string(kept.key[:kept.count])
}

// name_keep copies a name and refuses a name that cannot be the name of an
// entry (format.name_refusal): it writes the error record; argument is the
// number of the argument of the name in the export.
name_keep :: proc "contextless" (given: string, error: ^errors.Error_Record, argument: i64) -> (kept: Kept_Name, ok: bool) {
	copied: [format.ENTRY_NAME_CAPACITY + 1]u8
	count := copy(copied[:], given)
	if len(given) > format.ENTRY_NAME_CAPACITY {
		errors.fail(error, ERROR_NAME, .Too_Long, .Bytes, argument, i64(len(given)), format.ENTRY_NAME_CAPACITY)
		return {}, false
	}
	name := string(copied[:count])
	switch refusal, offset, byte := format.name_refusal(name); refusal {
	case .None:
	case .Empty:
		errors.fail(error, ERROR_NAME, .Empty, .Bytes, argument, 0, format.ENTRY_NAME_CAPACITY)
		return {}, false
	case .Too_Long:
		errors.fail(error, ERROR_NAME, .Too_Long, .Bytes, argument, i64(count), format.ENTRY_NAME_CAPACITY)
		return {}, false
	case .Bad_Byte:
		errors.fail(error, ERROR_NAME, .Bad_Byte, .Bytes, argument, i64(offset), 0, i64(byte))
		return {}, false
	}
	copy(kept.key[:], name)
	kept.count = count
	return kept, true
}

// ---------------------------------------------------------------------
// The store of a change.

// The store of a call: its name and its limit (the last grant).
Store_Of :: struct {
	name:  string,
	limit: u64,
}

// store_prepare starts the plan of a change of a store: it refuses a store
// that the service cannot change, and makes a new store for a first change
// when `create`. It gives the index of the store, or an ERROR_ number.
store_prepare :: proc "contextless" (store: Store_Of, create: bool, error: ^errors.Error_Record) -> (store_index: int, result: i64) {
	if len(store.name) == 0 || store.limit == 0 {
		return -1, errors.fail(error, ERROR_NO_STORE, .No_Grant, .Store)
	}
	if broken {
		return -1, errors.fail(error, ERROR_DISK, .Device, .None, 0, 0, 0, 1)
	}
	store_index = store_find(store.name)
	if store_index >= 0 && store_damaged[store_index] {
		return -1, errors.fail(error, ERROR_DAMAGED, .Damaged, .Stores)
	}
	if store_index >= 0 && store_faulty[store_index] {
		return -1, errors.fail(error, ERROR_DAMAGED, .Damaged, .Counts)
	}
	if store_index >= 0 {
		plan_reset(store_index)
		plan.next.stores[store_index].limit = store.limit
		removal_stalled[store_index] = false // A change of the store tries a stopped removal again.
		return store_index, 0
	}
	if !create {
		return -1, errors.fail(error, ERROR_ABSENT, .Absent, .Objects, 2)
	}
	for &entry, index in root.stores {
		if entry.name[0] == 0 {
			store_index = index
			break
		}
	}
	if store_index < 0 {
		return -1, errors.fail(error, ERROR_FULL, .Full) // The disk: a fact of all the stores, so no number.
	}
	plan_reset(store_index)
	plan.next.stores[store_index] = {limit = store.limit}
	copy(plan.next.stores[store_index].name[:NAME_CAPACITY - 1], store.name)
	return store_index, 0
}

// path_refusal gives the error of a path of a place that the commit cannot
// open: a tree of the path was removed or renamed since the place was
// opened (Absent, unit Places), or the trees failed.
path_refusal :: proc "contextless" (refusal: Open_Refusal, error: ^errors.Error_Record) -> i64 {
	if refusal == .Absent {
		return errors.fail(error, ERROR_ABSENT, .Absent, .Places, 1)
	}
	return plan_refusal(error)
}

// plan_refusal gives the error of a plan that plan_refused refuses.
plan_refusal :: proc "contextless" (error: ^errors.Error_Record) -> i64 {
	result := plan_commit_refused(error)
	plan_drop()
	return result
}

// plan_commit_refused writes the error of a refused plan, as plan_commit
// does, with no write.
plan_commit_refused :: proc "contextless" (error: ^errors.Error_Record) -> i64 {
	plan_trees_failure_take()
	switch {
	case plan.tree_damaged:
		store_damaged[plan.store_index] = true
		return errors.fail(error, ERROR_DAMAGED, .Damaged, .Stores)
	case plan.device:
		return errors.fail(error, ERROR_DISK, .Device)
	case plan.capacity_reached:
		return errors.fail(error, ERROR_FULL, .Full, .Commit_Blocks, 0, 0, i64(plan.capacity_limit))
	case plan.count_overflow:
		return errors.fail(error, ERROR_FULL, .Over_Limit, .References, 0, i64(REFERENCE_LIMIT) + 1, i64(REFERENCE_LIMIT))
	case plan.full:
		return errors.fail(error, ERROR_FULL, .Full)
	}
	return errors.fail(error, ERROR_DAMAGED, .Damaged, .Counts)
}

// commit_at_limit thins the oldest versions of the store until the plan
// fits in the limit, writes the plan, checks the limit with the nodes
// that the trees wrote, and commits.
commit_at_limit :: proc "contextless" (store: Store_Of, error: ^errors.Error_Record, limit_argument: i64) -> i64 {
	thinned_before := plan.thinned
	for !plan_refused() && projected() > i64(store.limit) {
		item, found := oldest_version_entry()
		if !found {
			break
		}
		version_remove_first(item)
	}
	at_limit := plan.thinned - thinned_before
	plan_finish()
	entry := &plan.next.stores[plan.store_index]
	if !plan_refused() && i64(entry.used) + plan.used_change > i64(store.limit) {
		plan_drop()
		return errors.fail(error, ERROR_NO_BUDGET, .Over_Limit, .Blocks, limit_argument, i64(entry.used) + plan.used_change, i64(store.limit))
	}
	generation := plan_commit(error)
	if generation > 0 && at_limit != 0 && !limit_reached[plan.store_index] {
		// One line for each store and each start of the service: the later
		// commits at the limit thin the same way.
		limit_reached[plan.store_index] = true
		system.log("storage: the store ", store.name, " is at its limit of ", store.limit, " blocks: the commit of generation ", generation, " thinned ", at_limit, at_limit == 1 ? string(" version") : string(" versions"), ", the oldest of the store first")
	}
	return generation
}

limit_reached: [STORE_CAPACITY]bool

// minimum_refusal refuses a change whose current objects alone do not fit
// in the limit: no version is thinned for it.
minimum_refusal :: proc "contextless" (store: Store_Of, error: ^errors.Error_Record, argument: i64) -> (refused: bool, result: i64) {
	needed := 1 + plan.store_block.node_blocks + plan.store_block.current_blocks
	if needed > store.limit {
		plan_drop()
		return true, errors.fail(error, ERROR_NO_BUDGET, .Over_Limit, .Blocks, argument, i64(needed), i64(store.limit))
	}
	return false, 0
}

// ---------------------------------------------------------------------
// The changes.

Change_Kind :: enum {
	Write, // New bytes: the whole object.
	Restore, // The state of a version.
	Clone, // The state of another object.
	Ranges, // The pending changes of a connection (ranges.odin).
}

// State_Of_Object is one state of an object: its current version or a
// version.
State_Of_Object :: struct {
	generation: u64,
	size:       u64,
	time:       u64,
	date:       u64,
	root:       Pointer, // The root of its block tree.
	hash:       [32]u8,
	has_hash:   bool, // A version keeps no hash: a restore computes it from the values of its block tree.
	current:    bool,
}

current_state :: proc "contextless" (entry: ^Entry) -> State_Of_Object {
	return {generation = entry.generation, size = entry.size, time = entry.time, date = entry.date, root = entry.pointer, hash = entry.hash, has_hash = true, current = true}
}

tree_state :: proc "contextless" (state: State_Of_Object) -> block_tree.State {
	return {root = state.root, size = state.size}
}

// The work of a commit on one object (support/storage_object): the copies
// of its object nodes.
object_work: block_tree.Work
object_node: Object_Node // The room of a read of one block tree.
object_nodes: [OBJECT_LEVEL_LIMIT]Object_Node // The room of a walk of one block tree.
object_hash_room: block_tree.State_Room

// The blocks of data of a write of a whole object: the data comes in the
// call region, so it has at most the blocks of the call region.
WHOLE_WRITE_BLOCKS :: isolated.REGION_PAGES * system.PAGE_SIZE / BLOCK_SIZE
whole_blocks: [WHOLE_WRITE_BLOCKS]Block
whole_changes: [WHOLE_WRITE_BLOCKS]block_tree.Change

// work_failure_take gives the failure of the work on an object to the plan:
// a commit with one is refused. A wrong block of the state before gives
// damaged: true.
work_failure_take :: proc "contextless" () -> (damaged: bool) {
	switch object_work.failure {
	case .None:
	case .Device:
		plan.device = true
	case .Wrong:
		return true
	case .Full:
		capacity_reached(block_tree.NODE_SLOT_CAPACITY)
	case .Write:
		// plan_write gave no block: it set the cause.
		if !plan.full && !plan.capacity_reached {
			plan.full = true
		}
	}
	return false
}

// object_change makes one commit that changes one object of a tree: new
// bytes, the state of one of its versions, the state of another object (a
// clone), or the pending changes of a connection. Each one goes through
// the block tree of the object: a write of the whole object is a cut, a
// size and a change of each of its blocks; a block that keeps its bytes
// keeps its block. The state before becomes a version. It gives the
// generation of the commit, or an ERROR_ number with the error record.
// `name_argument` is the argument of the name in the export.
object_change :: proc "contextless" (store: Store_Of, path: []Entry_Name, name: Kept_Name, kind: Change_Kind, data: []u8, given_source: State_Of_Object, error: ^errors.Error_Record, name_argument: i64, pending: ^Pending_Object = nil, measure: ^Commit_Measure = nil) -> i64 {
	count := blocks_of(u64(len(data)))
	if kind == .Write && count > WHOLE_WRITE_BLOCKS {
		return errors.fail(error, ERROR_TOO_LARGE, .Too_Long, .Bytes, name_argument + 1, i64(len(data)), WHOLE_WRITE_BLOCKS * BLOCK_SIZE)
	}
	source := given_source
	if (kind == .Restore || kind == .Clone) && !source.has_hash {
		// A version keeps no hash: its block tree gives it, from the values
		// on the path of its last block.
		hash, outcome := block_tree.state_hash(&object_source, tree_state(source), &object_hash_room)
		switch outcome {
		case .Device:
			return errors.fail(error, ERROR_DISK, .Device)
		case .Wrong:
			return errors.fail(error, ERROR_DAMAGED, .Damaged, .Objects, name_argument)
		case .Good:
		}
		source.hash = hash
	}
	creates := kind == .Write || kind == .Ranges
	store_index, refused := store_prepare(store, creates && len(path) == 0, error)
	if store_index < 0 {
		return refused
	}
	tree_index, open_refusal := plan_tree_open(path)
	if tree_index < 0 {
		return path_refusal(open_refusal, error)
	}
	index, found := plan_entry_load(tree_index, name.key)
	if plan_refused() {
		return plan_refusal(error)
	}
	if found && plan.entries[index].before.kind != .Object {
		plan_drop()
		return errors.fail(error, ERROR_ABSENT, .Absent, .Objects, name_argument) // The name is a tree.
	}
	if kind == .Ranges {
		// The pending changes start from the state that the first of them
		// saw: another change of the object since then comes first.
		base := found ? plan.entries[index].before.generation : 0
		if base != pending.base_generation {
			plan_drop()
			return errors.fail(error, ERROR_PENDING, .Absent, .Pending, name_argument, 0, 0, 1)
		}
	}
	if !found {
		if kind == .Restore {
			plan_drop()
			return errors.fail(error, ERROR_ABSENT, .Absent, .Objects, name_argument)
		}
		index = plan_entry_new(tree_index, name.key)
		if index < 0 {
			return plan_refusal(error)
		}
	}
	item := &plan.entries[index]
	old := item.before
	existed := old.kind == .Object
	now := time_now()
	next := Entry{kind = .Object, generation = root.generation + 1, time = now, date = date_now(), versions = old.versions}
	damaged_before := existed && state_damaged(old.pointer)
	old_blocks: u64
	if existed {
		old_blocks = state_blocks_of(old.pointer, old.size)
	}
	new_blocks: u64
	switch kind {
	case .Write, .Ranges:
		if kind == .Ranges && damaged_before {
			// The pending changes read the state before: it is damaged.
			plan_drop()
			return errors.fail(error, ERROR_DAMAGED, .Damaged, .Objects, name_argument)
		}
		changes: []block_tree.Change
		cut, size: u64
		if kind == .Write {
			for block_index in 0 ..< count {
				bytes := &whole_blocks[block_index]
				part := data[block_index * BLOCK_SIZE:]
				copy(bytes[:], part[:min(len(part), BLOCK_SIZE)])
				if len(part) < BLOCK_SIZE {
					intrinsics.mem_zero(raw_data(bytes[len(part):]), BLOCK_SIZE - len(part))
				}
				whole_changes[block_index] = {index = block_index, bytes = bytes}
			}
			changes = whole_changes[:count]
			size, cut = u64(len(data)), u64(len(data))
		} else {
			changes = pending_changes(pending)
			size, cut = pending.size, pending.cut
		}
		// A damaged state is not kept: the change replaces it whole.
		before := block_tree.State{}
		if existed && !damaged_before {
			before = {root = old.pointer, size = old.size}
		}
		block_tree.work_begin(&object_work, &object_source, &object_counter, before, changes)
		block_tree.work_cut(&object_work, cut)
		block_tree.work_resize(&object_work, size)
		for change_index in 0 ..< len(changes) {
			block_tree.work_change(&object_work, change_index)
		}
		finished := block_tree.work_finish(&object_work)
		if work_failure_take() {
			plan_drop()
			if existed {
				storage_mount.damaged_under_set(&opened, old.pointer.block)
			}
			return errors.fail(error, ERROR_DAMAGED, .Damaged, .Objects, name_argument)
		}
		if plan_refused() {
			return plan_refusal(error)
		}
		next.size = size
		next.pointer = finished.root
		next.hash = finished.hash
		new_blocks = finished.blocks
		if !finished.root_new {
			state_name(finished.root) // The new entry names a root of the state before.
		}
		if measure != nil {
			work_measure := object_work.measure
			measure^ = {object_blocks = i64(blocks_of(size)), held_blocks = i64(new_blocks), changed = i64(work_measure.changed), hashed_blocks = i64(work_measure.hashed_blocks), hashed_nodes = i64(work_measure.hashed_nodes), object_written = i64(work_measure.written)}
		}
	case .Restore, .Clone:
		next.size = source.size
		next.pointer = source.root
		next.hash = source.hash
		state_name(next.pointer)
		new_blocks = state_blocks_of(source.root, source.size)
	}
	current_blocks_change(new_blocks, old_blocks)
	if !existed {
		plan.store_block.objects += 1
	}
	if too_large, result := minimum_refusal(store, error, name_argument + 1); too_large {
		return result
	}
	item.entry = next
	// The state before becomes a version. A damaged state (a block with a
	// wrong check) is not kept: the change replaces it, and its root loses
	// this name.
	if existed && damaged_before {
		state_release(old.pointer, old.size)
	} else if existed {
		version_add(index, {generation = old.generation, size = old.size, time = old.time, date = old.date, root = old.pointer})
		retention(index, now)
	}
	return commit_at_limit(store, error, name_argument + 1)
}

// entry_remove removes an entry in one commit. An object goes with its
// versions. An empty tree goes. A tree with entries leaves its tree and
// goes into the removal queue: its blocks are freed by the steps of the
// removal (removal_step), each one a commit.
entry_remove :: proc "contextless" (store: Store_Of, path: []Entry_Name, name: Kept_Name, error: ^errors.Error_Record) -> i64 {
	store_index, refused := store_prepare(store, false, error)
	if store_index < 0 {
		return refused
	}
	tree_index, open_refusal := plan_tree_open(path)
	if tree_index < 0 {
		return path_refusal(open_refusal, error)
	}
	index, found := plan_entry_load(tree_index, name.key)
	if plan_refused() {
		return plan_refusal(error)
	}
	if !found {
		plan_drop()
		return errors.fail(error, ERROR_ABSENT, .Absent, .Objects, 2)
	}
	entry_free(index)
	plan_finish()
	return plan_commit(error)
}

// entry_free takes a plan entry out of its tree, and frees what it names:
// an object and its versions, or an empty tree; a tree with entries goes
// into the removal queue.
entry_free :: proc "contextless" (index: int) {
	item := &plan.entries[index]
	old := item.before
	plan_entry_remove(index)
	switch old.kind {
	case .Object:
		current_blocks_change(0, state_blocks_of(old.pointer, old.size))
		state_release(old.pointer, old.size)
		versions_release(index)
		plan.store_block.objects -= 1
	case .Tree:
		if old.pointer.block == 0 {
			plan.store_block.trees -= 1
			return
		}
		number := plan.store_block.next_removal + 1
		plan.store_block.next_removal = number
		key := format.removal_name(number)
		queued := old
		tree.put(&plan.trees[1].work, key[:], entry_bytes(&queued), false)
		plan.trees[1].changed = true
		plan.store_block.removing += 1
	case .None:
	}
}

// Add_Row is one entry that add makes: its name, at an offset of the
// bytes of the names, and its kind.
Add_Row :: struct {
	name_offset: i64,
	name_count:  i64,
	kind:        i64, // 1: an empty object; 2: an empty tree.
}

added_rows: [ADD_LIMIT]Add_Row
added_names: [ADD_LIMIT]Kept_Name

// entries_add adds empty objects and empty trees to one tree, in one
// commit: all of them or none. The rows and the names are in the call
// region: they are copied first, then checked.
entries_add :: proc "contextless" (store: Store_Of, path: []Entry_Name, rows: []Add_Row, names: []u8, error: ^errors.Error_Record) -> i64 {
	if len(rows) > ADD_LIMIT {
		return errors.fail(error, ERROR_FULL, .Too_Long, .Records, 2, i64(len(rows)), ADD_LIMIT)
	}
	count := copy(added_rows[:], rows)
	for &row, number in added_rows[:count] {
		if row.kind != i64(format.Entry_Kind.Object) && row.kind != i64(format.Entry_Kind.Tree) {
			return errors.fail(error, ERROR_NAME, .Bad_Value, .Records, 2, row.kind, i64(format.Entry_Kind.Tree), i64(number + 1))
		}
		if row.name_offset < 0 || row.name_count < 0 || row.name_offset > i64(len(names)) || row.name_count > i64(len(names)) - row.name_offset {
			return errors.fail(error, ERROR_NAME, .Out_Of_Range, .Bytes, 3, row.name_offset + row.name_count, i64(len(names)), i64(number + 1))
		}
		kept, ok := name_keep(string(names[row.name_offset:][:row.name_count]), error, 3)
		if !ok {
			if error != nil {
				error.found = i64(number + 1) // The row of the name.
			}
			return ERROR_NAME
		}
		for earlier in added_names[:number] {
			if earlier.key == kept.key {
				return errors.fail(error, ERROR_EXISTS, .Exists, .Objects, 3, 0, 0, i64(number + 1))
			}
		}
		added_names[number] = kept
	}
	store_index, refused := store_prepare(store, len(path) == 0, error)
	if store_index < 0 {
		return refused
	}
	tree_index, open_refusal := plan_tree_open(path)
	if tree_index < 0 {
		return path_refusal(open_refusal, error)
	}
	opened_tree := &plan.trees[tree_index]
	generation := root.generation + 1
	now := time_now()
	date := date_now()
	for &row, number in added_rows[:count] {
		value := Entry{kind = format.Entry_Kind(row.kind), generation = generation, time = now, date = date}
		if value.kind == .Object {
			value.hash = blake3.hash(nil) // The hash of an object of no byte.
		}
		key := added_names[number].key
		if tree.put(&opened_tree.work, key[:], entry_bytes(&value), false) {
			plan_drop()
			return errors.fail(error, ERROR_EXISTS, .Exists, .Objects, 3, 0, 0, i64(number + 1))
		}
		if plan_refused() {
			return plan_refusal(error)
		}
		if value.kind == .Object {
			plan.store_block.objects += 1
		} else {
			plan.store_block.trees += 1
		}
	}
	opened_tree.count_change += i64(count)
	opened_tree.changed = true
	plan_finish()
	entry := &plan.next.stores[plan.store_index]
	if !plan_refused() && i64(entry.used) + plan.used_change > i64(store.limit) {
		plan_drop()
		return errors.fail(error, ERROR_NO_BUDGET, .Over_Limit, .Blocks, 2, i64(entry.used) + plan.used_change, i64(store.limit))
	}
	return plan_commit(error)
}

// path_under says if `path` is `tree_path` and `name`, or a path inside it.
path_under :: proc "contextless" (path: []Entry_Name, tree_path: []Entry_Name, name: Entry_Name) -> bool {
	if len(path) <= len(tree_path) {
		return false
	}
	for step, index in tree_path {
		if path[index] != step {
			return false
		}
	}
	return path[len(tree_path)] == name
}

// entry_rename moves an entry inside one store, in one commit: from the
// tree at `from_path` to the tree at `to_path`, with a new name. A tree
// moves with all under it: its entry moves, nothing else is written.
entry_rename :: proc "contextless" (store: Store_Of, from_path: []Entry_Name, from: Kept_Name, to_path: []Entry_Name, to: Kept_Name, error: ^errors.Error_Record) -> i64 {
	if path_under(to_path, from_path, from.key) {
		return errors.fail(error, ERROR_NAME, .Bad_Value, .Trees, 3, 0, 0)
	}
	store_index, refused := store_prepare(store, false, error)
	if store_index < 0 {
		return refused
	}
	from_tree, from_refusal := plan_tree_open(from_path)
	if from_tree < 0 {
		return path_refusal(from_refusal, error)
	}
	to_tree, to_refusal := plan_tree_open(to_path)
	if to_tree < 0 {
		if to_refusal == .Absent {
			plan_drop()
			return errors.fail(error, ERROR_ABSENT, .Absent, .Places, 3)
		}
		return plan_refusal(error)
	}
	value: Entry
	from_key := from.key
	to_key := to.key
	if !tree.get(&plan.trees[from_tree].work, from_key[:], entry_bytes(&value)) {
		if plan_refused() {
			return plan_refusal(error)
		}
		plan_drop()
		return errors.fail(error, ERROR_ABSENT, .Absent, .Objects, 2)
	}
	existing: Entry
	if tree.get(&plan.trees[to_tree].work, to_key[:], entry_bytes(&existing)) {
		plan_drop()
		return errors.fail(error, ERROR_EXISTS, .Exists, .Objects, 4)
	}
	if plan_refused() {
		return plan_refusal(error)
	}
	tree.remove(&plan.trees[from_tree].work, from_key[:])
	plan.trees[from_tree].count_change -= 1
	plan.trees[from_tree].changed = true
	tree.put(&plan.trees[to_tree].work, to_key[:], entry_bytes(&value), false)
	plan.trees[to_tree].count_change += 1
	plan.trees[to_tree].changed = true
	plan_finish()
	entry := &plan.next.stores[plan.store_index]
	if !plan_refused() && i64(entry.used) + plan.used_change > i64(store.limit) {
		plan_drop()
		return errors.fail(error, ERROR_NO_BUDGET, .Over_Limit, .Blocks, 0, i64(entry.used) + plan.used_change, i64(store.limit))
	}
	return plan_commit(error)
}

// ---------------------------------------------------------------------
// The removal of a tree, in steps.

removal_stalled: [STORE_CAPACITY]bool // A step failed: no other step until the next change of the store.
removal_names: [REMOVAL_STEP_LIMIT]Entry_Name
removal_values: [REMOVAL_STEP_LIMIT]Entry

// removal_waits says if a store has a removal to continue.
removal_waits :: proc "contextless" () -> bool {
	for &entry, index in root.stores {
		if entry.name[0] != 0 && store_blocks[index].removing != 0 && !removal_stalled[index] && !store_damaged[index] && !store_faulty[index] {
			return true
		}
	}
	return false
}

// removal_step frees up to REMOVAL_STEP_LIMIT entries of the first tree of
// the removal queue of one store, in one commit. A tree with entries among
// them goes into the queue in its turn. It gives false when no store has a
// removal to continue.
removal_step :: proc "contextless" () -> bool {
	if broken {
		return false
	}
	store_index := -1
	for &entry, index in root.stores {
		if entry.name[0] != 0 && store_blocks[index].removing != 0 && !removal_stalled[index] && !store_damaged[index] && !store_faulty[index] {
			store_index = index
			break
		}
	}
	if store_index < 0 {
		return false
	}
	plan_reset(store_index)
	error: errors.Error_Record
	queue := &plan.trees[1]
	first: Entry_Name
	queued_name: Entry_Name
	queued: Entry
	if !tree.first_from(&queue.work, first[:], false, queued_name[:], entry_bytes(&queued)) {
		removal_failed(store_index, "the removal queue gives no first tree")
		return true
	}
	if queued.kind != .Tree || queued.pointer.block == 0 {
		// An empty tree in the queue: it leaves the queue.
		tree.remove(&queue.work, queued_name[:])
		queue.changed = true
		plan.store_block.removing -= 1
		plan.store_block.trees -= 1
	} else {
		if plan.tree_count >= PLAN_TREE_CAPACITY {
			return false
		}
		freed := plan.tree_count
		plan.tree_count += 1
		plan.trees[freed] = {work = {pool = &plan.pool, source = &node_source, shape = tree.TREE_SHAPE, root = queued.pointer}, role = .Inside, parent = 1, name = queued_name, depth = 1}
		// The first entries of the tree: their names and values are kept
		// before the changes, which move the nodes.
		count := 0
		cursor: Entry_Name
		after := false
		for count < REMOVAL_STEP_LIMIT {
			if !tree.first_from(&plan.trees[freed].work, cursor[:], after, removal_names[count][:], entry_bytes(&removal_values[count])) {
				break
			}
			cursor = removal_names[count]
			after = true
			count += 1
		}
		for number in 0 ..< count {
			// The leaves of the versions of the objects of one step stay inside
			// the leaf work of a commit: the step ends before an object whose
			// versions would pass it; that object starts the next step.
			if versions := removal_values[number].versions; removal_values[number].kind == .Object && versions.block != 0 {
				index_block: Version_Index
				if read_single(versions, (^Block)(&index_block)) == .Good && number > 0 && plan.leaf_count + int(min(index_block.leaf_count, format.VERSION_INDEX_CAPACITY)) > LEAF_WORK_CAPACITY {
					break
				}
			}
			index := plan_entry_new(freed, removal_names[number])
			if index < 0 {
				break
			}
			plan.entries[index].entry = removal_values[number]
			plan.entries[index].before = removal_values[number]
			entry_free(index)
		}
	}
	if plan_refused() {
		removal_failed(store_index, "a step was refused")
		plan_drop()
		return true
	}
	plan_finish()
	if plan_commit(&error) < 0 {
		removal_failed(store_index, "its commit failed")
	}
	return true
}

removal_failed :: proc "contextless" (store_index: int, why: string) {
	removal_stalled[store_index] = true
	system.log_in("storage", .Warning, "storage: the removal of a tree of the store ", system.name_of(root.stores[store_index].name[:]), " stops: ", why, "; the next change of the store tries again")
}

// ---------------------------------------------------------------------
// The thinning at the limit: the object of the store with the oldest
// version. It walks the trees of the store (the cost of a commit at the
// limit is one read of each node and of each version index of the store:
// docs/STORAGE.md), and the objects whose versions the commit changes.

Oldest :: struct {
	generation: u64,
	path:       [NESTING_LIMIT]Entry_Name,
	depth:      int,
	name:       Entry_Name,
	found:      bool,
	stack:      [NESTING_LIMIT]Entry_Name,
	nesting:    int,
	failed:     bool,
}

oldest: Oldest
oldest_walks: [NESTING_LIMIT + 1]tree.Walk

oldest_version_entry :: proc "contextless" () -> (index: int, found: bool) {
	best := max(u64)
	for &item, candidate in plan.entries[:plan.entry_count] {
		if item.gone || item.entry.kind != .Object || item.entry.versions.block == 0 && !plan.index_work[candidate].touched {
			continue
		}
		leaf, has := version_first(candidate)
		if has && leaf.leaf.entries[0].generation < best {
			best = leaf.leaf.entries[0].generation
			index, found = candidate, true
		}
	}
	oldest = {generation = best}
	oldest_walk(store_blocks[plan.store_index].tree, 0)
	if oldest.failed || !oldest.found {
		return index, found
	}
	tree_index, refusal := plan_tree_open(oldest.path[:oldest.depth])
	if refusal != .None {
		return index, found
	}
	entry_index, has := plan_entry_load(tree_index, oldest.name)
	if !has || plan.entries[entry_index].gone {
		return index, found
	}
	return entry_index, true
}

oldest_walk :: proc "contextless" (pointer: Pointer, nesting: int) {
	if nesting > NESTING_LIMIT || pointer.block == 0 {
		return
	}
	one := &oldest_walks[nesting]
	one.source = &node_source
	one.shape = tree.TREE_SHAPE
	one.visit_node = nil
	one.visit_record = oldest_visit
	one.nodes, one.records = 0, 0
	before := oldest.nesting
	oldest.nesting = nesting
	if tree.walk_tree(one, pointer) != .None {
		oldest.failed = true
	}
	oldest.nesting = before
}

oldest_visit :: proc "contextless" (_: ^tree.Walk, key: []u8, value: []u8) {
	entry := (^Entry)(raw_data(value))^
	name := (^Entry_Name)(raw_data(key))^
	nesting := oldest.nesting
	switch entry.kind {
	case .Tree:
		if nesting < NESTING_LIMIT {
			oldest.stack[nesting] = name
			oldest_walk(entry.pointer, nesting + 1)
		}
	case .Object:
		if entry.versions.block == 0 || plan_holds(oldest.stack[:nesting], name) {
			return
		}
		index: Version_Index
		if read_single(entry.versions, (^Block)(&index)) != .Good || index.leaf_count == 0 || index.leaf_count > format.VERSION_INDEX_CAPACITY {
			return
		}
		leaf: Version_Leaf
		if read_single(index.leaves[0], (^Block)(&leaf)) != .Good || leaf.count == 0 || leaf.count > format.VERSION_LEAF_CAPACITY {
			return
		}
		if leaf.entries[0].generation < oldest.generation {
			oldest.generation = leaf.entries[0].generation
			oldest.path = oldest.stack
			oldest.depth = nesting
			oldest.name = name
			oldest.found = true
		}
	case .None:
	}
}

// plan_holds says if the plan has the entry of an object at a path: the
// walk reads the disk, and the plan has the versions of its entries.
plan_holds :: proc "contextless" (path: []Entry_Name, name: Entry_Name) -> bool {
	for &item in plan.entries[:plan.entry_count] {
		if item.name != name {
			continue
		}
		// The path of the tree of the entry, from the deepest up.
		depth := len(path)
		index := item.tree
		same := true
		for index >= 2 && same {
			opened_tree := &plan.trees[index]
			depth -= 1
			same = opened_tree.role == .Inside && depth >= 0 && path[depth] == opened_tree.name
			index = opened_tree.parent
		}
		if same && depth == 0 && index == 0 {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------
// Reads: no plan. The trees are read through their own pool.

reading_pool: tree.Pool

Lookup :: enum {
	Found,
	Absent,
	Wrong, // A node of a tree of the path is wrong: the store is damaged.
	Device,
}

reading_outcome :: proc "contextless" (store_index: int) -> Lookup {
	switch reading_pool.failure {
	case .Device:
		return .Device
	case .Wrong, .Damaged:
		if reading_pool.failed_block != 0 {
			storage_mount.wrong_block_set(&opened, reading_pool.failed_block)
		}
		store_damaged[store_index] = true
		return .Wrong
	case .None, .Full, .Write:
	}
	return .Absent
}

// tree_of gives the root of the tree at a path of a store.
tree_of :: proc "contextless" (store_index: int, path: []Entry_Name) -> (root_node: Pointer, outcome: Lookup) {
	tree.pool_reset(&reading_pool)
	root_node = store_blocks[store_index].tree
	for step in path {
		work := tree.Work{pool = &reading_pool, source = &node_source, shape = tree.TREE_SHAPE, root = root_node}
		value: Entry
		key := step
		if !tree.get(&work, key[:], entry_bytes(&value)) {
			return {}, reading_outcome(store_index)
		}
		if value.kind != .Tree {
			return {}, .Absent
		}
		root_node = value.pointer
	}
	return root_node, .Found
}

// entry_of gives the entry of a name in the tree at a path of a store.
entry_of :: proc "contextless" (store_index: int, path: []Entry_Name, name: Entry_Name) -> (value: Entry, outcome: Lookup) {
	root_node, found := tree_of(store_index, path)
	if found != .Found {
		return {}, found
	}
	work := tree.Work{pool = &reading_pool, source = &node_source, shape = tree.TREE_SHAPE, root = root_node}
	key := name
	if !tree.get(&work, key[:], entry_bytes(&value)) {
		return {}, reading_outcome(store_index)
	}
	return value, .Found
}

// lookup_refusal gives the error of a read that found no entry.
lookup_refusal :: proc "contextless" (outcome: Lookup, error: ^errors.Error_Record, argument: i64) -> i64 {
	switch outcome {
	case .Device:
		return errors.fail(error, ERROR_DISK, .Device)
	case .Wrong:
		return errors.fail(error, ERROR_DAMAGED, .Damaged, .Stores)
	case .Absent, .Found:
	}
	return errors.fail(error, ERROR_ABSENT, .Absent, .Objects, argument)
}

// object_locate finds the entry of an object for a read. It refuses a
// store that the service does not know or cannot read, and a name that is
// a tree.
object_locate :: proc "contextless" (store_name: string, path: []Entry_Name, name: Kept_Name, error: ^errors.Error_Record, argument: i64) -> (store_index: int, value: Entry, result: i64) {
	store_index = store_find(store_name)
	if store_index < 0 {
		return -1, {}, errors.fail(error, ERROR_ABSENT, .Absent, .Objects, argument)
	}
	if store_damaged[store_index] {
		return -1, {}, errors.fail(error, ERROR_DAMAGED, .Damaged, .Stores)
	}
	outcome: Lookup
	value, outcome = entry_of(store_index, path, name.key)
	if outcome != .Found {
		return -1, {}, lookup_refusal(outcome, error, argument)
	}
	if value.kind != .Object {
		return -1, {}, errors.fail(error, ERROR_ABSENT, .Absent, .Objects, argument)
	}
	return store_index, value, 0
}

// state_read reads the bytes from `offset` of one state of an object,
// checked, into result, up to its size. It gives the count of bytes, or
// ERROR_DISK, ERROR_DAMAGED. A wrong block stays known: the state is
// damaged, and a write of the object does not keep it as a version.
state_read :: proc "contextless" (state: State_Of_Object, offset: u64, result: []u8, error: ^errors.Error_Record, argument: i64) -> i64 {
	if state_damaged(state.root) {
		return errors.fail(error, ERROR_DAMAGED, .Damaged, .Objects, argument)
	}
	count, outcome := block_tree.range_read(&object_source, tree_state(state), offset, result, &read_room, &object_node)
	switch outcome {
	case .Device:
		return errors.fail(error, ERROR_DISK, .Device)
	case .Wrong:
		storage_mount.damaged_under_set(&opened, state.root.block)
		return errors.fail(error, ERROR_DAMAGED, .Damaged, .Objects, argument)
	case .Good:
	}
	return i64(count)
}

read_room: Block // One block of data of a read.

// The versions of one object, read for one call, the oldest first.
listed: [format.VERSIONS_LIMIT]Version_Entry
listed_count: int

// versions_list reads the versions of an object into `listed`.
versions_list :: proc "contextless" (object: ^Entry, error: ^errors.Error_Record) -> i64 {
	listed_count = 0
	if object.versions.block == 0 {
		return 0
	}
	index: Version_Index
	switch read_single(object.versions, (^Block)(&index)) {
	case .Device:
		return errors.fail(error, ERROR_DISK, .Device)
	case .Wrong:
		return errors.fail(error, ERROR_DAMAGED, .Damaged, .Objects, 2)
	case .Good:
	}
	if index.leaf_count > format.VERSION_INDEX_CAPACITY {
		return errors.fail(error, ERROR_DAMAGED, .Damaged, .Objects, 2)
	}
	leaf: Version_Leaf
	leaves := index.leaves[:index.leaf_count]
	// The leaves, REGION_BLOCKS at a time.
	for first := 0; first < len(leaves); first += REGION_BLOCKS {
		part := leaves[first:min(first + REGION_BLOCKS, len(leaves))]
		_, outcome := read_checked(part, 0)
		switch outcome {
		case .Device:
			return errors.fail(error, ERROR_DISK, .Device)
		case .Wrong:
			return errors.fail(error, ERROR_DAMAGED, .Damaged, .Objects, 2)
		case .Good:
		}
		for place in 0 ..< len(part) {
			intrinsics.mem_copy_non_overlapping(&leaf, raw_data(slot(u64(place))), BLOCK_SIZE)
			if leaf.count == 0 || leaf.count > format.VERSION_LEAF_CAPACITY {
				return errors.fail(error, ERROR_DAMAGED, .Damaged, .Objects, 2)
			}
			for entry in leaf.entries[:leaf.count] {
				if listed_count < len(listed) {
					listed[listed_count] = entry
					listed_count += 1
				}
			}
		}
	}
	return i64(listed_count)
}

// state_at gives the state of an object at a generation: its current
// version, or the version with that generation.
state_at :: proc "contextless" (object: ^Entry, generation: i64, argument: i64, error: ^errors.Error_Record) -> (state: State_Of_Object, result: i64) {
	if generation == i64(object.generation) {
		return current_state(object), 0
	}
	if count := versions_list(object, error); count < 0 {
		return {}, count
	}
	for entry in listed[:listed_count] {
		if i64(entry.generation) == generation {
			return {generation = entry.generation, size = entry.size, time = entry.time, date = entry.date, root = entry.root}, 0
		}
	}
	return {}, errors.fail(error, ERROR_NO_VERSION, .Absent, .Versions, argument, generation)
}

// own_blocks gives the blocks that only one state holds: its root, when no
// other state names it, and under it each block that no other node names.
own_blocks :: proc "contextless" (root: Pointer, size: u64) -> u64 {
	if root.block == 0 || root.block >= DISK_BLOCKS_LIMIT || opened.references[root.block] != 1 || size > format.OBJECT_SIZE_LIMIT || state_damaged(root) {
		return 0
	}
	return own_under({block = root.block, check = root.check}, format.object_levels(size))
}

own_under :: proc "contextless" (child: Object_Child, level: int) -> u64 {
	if level == 0 {
		return 1
	}
	node := &object_nodes[level - 1]
	if read_single({block = child.block, check = child.check}, (^Block)(node)) != .Good {
		return 1
	}
	count: u64 = 1
	for item in node.children {
		// The level below reads into its own node: this one stays.
		if item.block != 0 && item.block < DISK_BLOCKS_LIMIT && opened.references[item.block] == 1 {
			count += own_under(item, level - 1)
		}
	}
	return count
}
