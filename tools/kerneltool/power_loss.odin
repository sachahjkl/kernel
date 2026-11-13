package kerneltool

import "contract:settings"
import format "contract:store"
import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "support:storage_mount"
import block_tree "support:storage_object"
import tree "support:storage_tree"

// The loss of power: a stop of the machine never shows a part of a commit.
// The tool serves the data disk itself (network_block_device.odin), so it
// knows each write that a flush made durable, and each write after the
// last flush. A machine runs `notes`, which makes one commit for each step
// of its count; the tool ends QEMU at a seeded moment, with no warning.
//
// A real disk then holds the durable image plus any subset of the later
// writes, and the last of them can be torn (some of its sectors new, the
// others old). The tool builds many such images and checks each one on the
// host with the code that the storage service runs at its start
// (support/storage_mount): no machine for each image.
//
// What each image must give:
//   - the disk opens, with no wrong block, no block named two times, and the
//     counts of each store equal to what its trees name;
//   - the objects are those of the durable image, or those of the image with
//     every write (the commit in flight at the loss, if its root was among
//     the writes): each object byte for byte, never a mix of the two.
// Then one machine starts on a hard image (the writes after the last flush
// lost, and the write of the root torn) and `notes` finds its note.

POWER_LOSS_SEED :: 20261111 // The moment of the loss and the random subsets: one seed, printed.
POWER_LOSS_RANDOM_SUBSETS :: 300
SECTOR_SIZE :: 512
TEST_POWER_LOSS_DISK :: BUILD_FOLDER + "/test_power_loss_disk.img"
TEST_OUTPUT_POWER_LOSS :: BUILD_FOLDER + "/test_output_power_loss_%d.txt"

// The bytes of an object that the search keeps whole. A larger object is
// compared by the values of its blocks, and a version of it by its root:
// the open checked each block under the root.
CONTENTS_BYTES_LIMIT :: 1 << 20

// One block of data of an object, as an image gives it: its place, its
// check and its value (zero for the block of an object of one block).
Stored_Block :: struct {
	index: u64,
	check: u64,
	value: format.Block_Value,
}

// One version of an object, as an image gives it.
Stored_Version :: struct {
	generation: u64,
	size:       u64,
	root:       format.Pointer,
	bytes:      []u8, // Its bytes, when it has at most CONTENTS_BYTES_LIMIT.
	damaged:    bool,
}

// One entry of a store, as an image gives it: an object with its current
// version and its versions, the oldest first, or a tree. The name is the
// names of its path from the root of the store, joined with "/" for the
// tool only.
Stored_Object :: struct {
	store:    string,
	name:     string,
	tree:     bool,
	size:     u64,
	bytes:    []u8, // Its bytes, when it has at most CONTENTS_BYTES_LIMIT.
	blocks:   []Stored_Block, // Its blocks of data, in their order: a hole is no block.
	damaged:  bool,
	hash_wrong: bool, // The hash of its entry is not the hash that its block tree gives.
	versions: []Stored_Version,
	versions_damaged: bool,
}

// What one image of the disk gives when it is opened.
Disk_Contents :: struct {
	mount:   storage_mount.Mount,
	objects: [dynamic]Stored_Object,
}

// Image_Reader reads blocks of an image in memory for storage_mount.
Image_Reader :: struct {
	using reader: storage_mount.Block_Reader,
	image:        []u8,
	known:        ^Known_Checks,
}

// The checks and the values of the blocks of the durable image, kept for
// the search: an image of the search differs from it only in the blocks
// that a pending write touched, and those are computed each time.
Known_Checks :: struct {
	checks:  []u64, // 0: not computed yet.
	touched: []bool, // A pending write touched the block.
	values:  []format.Block_Value, // The value of a block of data at the place value_places gives.
	value_places: []u64, // 1 + the place of the block in its object; 0: not computed yet.
}

image_check :: proc "contextless" (reader: ^storage_mount.Block_Reader, number: u64, bytes: []u8) -> u64 {
	known := (^Image_Reader)(reader).known
	if known == nil || number >= u64(len(known.checks)) || known.touched[number] {
		return format.check(bytes)
	}
	if known.checks[number] == 0 {
		known.checks[number] = format.check(bytes)
	}
	return known.checks[number]
}

image_value :: proc "contextless" (reader: ^storage_mount.Block_Reader, number: u64, index: u64, bytes: ^block_tree.Block) -> format.Block_Value {
	known := (^Image_Reader)(reader).known
	if known == nil || number >= u64(len(known.checks)) || known.touched[number] {
		return block_tree.block_value(bytes, index)
	}
	if known.value_places[number] != index + 1 {
		known.values[number] = block_tree.block_value(bytes, index)
		known.value_places[number] = index + 1
	}
	return known.values[number]
}

image_read :: proc "contextless" (reader: ^storage_mount.Block_Reader, numbers: []u64, into: []u8) -> bool {
	from := (^Image_Reader)(reader)
	for number, index in numbers {
		offset := number * format.BLOCK_SIZE
		if offset >= u64(len(from.image)) || u64(len(from.image)) - offset < format.BLOCK_SIZE {
			return false
		}
		copy(into[index * format.BLOCK_SIZE:][:format.BLOCK_SIZE], from.image[offset:][:format.BLOCK_SIZE])
	}
	return true
}

// The walk of the trees of one store of an image. The walks of the trees
// and the state of the open keep its address: it lives in the heap, not on
// the stack.
Contents_Walk :: struct {
	state:     ^storage_mount.State,
	reader:    Image_Reader,
	source:    storage_mount.Reader_Source,
	objects_source: storage_mount.Object_Source,
	objects:   [dynamic]Stored_Object,
	store:     string,
	allocator: runtime.Allocator,
	saved:     runtime.Context,
	walks:     [format.NESTING_LIMIT + 1]tree.Walk,
	path:      [format.NESTING_LIMIT]string,
	nesting:   int,
	bytes:     []u8,
	collected: [dynamic]Stored_Block,
	block:     block_tree.Block,
	node:      format.Object_Node,
	nodes:     [format.OBJECT_LEVEL_LIMIT]format.Object_Node,
	hash_room: block_tree.State_Room,
	failed:    bool,
}

// disk_contents opens an image as the storage service does, and reads each
// entry of each tree of each store, checked. The strings and the bytes are
// in the allocator.
disk_contents :: proc(image: []u8, state: ^storage_mount.State, allocator := context.temp_allocator, known: ^Known_Checks = nil) -> (contents: Disk_Contents) {
	walking := new(Contents_Walk)
	defer free(walking)
	walking.reader = Image_Reader{reader = {read = image_read, check = image_check, value = image_value}, image = image, known = known}
	contents.mount = storage_mount.mount(state, &walking.reader, u64(len(image)) / format.BLOCK_SIZE)
	contents.objects = make([dynamic]Stored_Object, allocator)
	if contents.mount.failed || contents.mount.needs_format {
		return contents
	}
	walking.state = state
	walking.source = storage_mount.reader_source(&walking.reader, state.disk_size)
	walking.objects_source = storage_mount.object_source(&walking.reader, state.disk_size)
	walking.objects = contents.objects
	walking.allocator = allocator
	walking.saved = context
	walking.bytes = make([]u8, CONTENTS_BYTES_LIMIT, allocator)
	walking.collected = make([dynamic]Stored_Block, context.temp_allocator)
	for &store, store_index in state.root.stores {
		if store.name[0] == 0 || state.store_damaged[store_index] {
			continue
		}
		walking.store = strings.clone(string(cstring(&store.name[0])), allocator)
		contents_walk_tree(walking, state.store_blocks[store_index].tree, 0)
	}
	contents.objects = walking.objects
	if walking.failed {
		contents.mount.wrong += 1 // A tree that the open walked whole and this walk cannot: never with a disk that the open accepted.
	}
	return contents
}

contents_walk_tree :: proc(walking: ^Contents_Walk, root: format.Pointer, nesting: int) {
	if nesting > format.NESTING_LIMIT || root.block == 0 {
		return
	}
	one := &walking.walks[nesting]
	one.source = &walking.source.source
	one.shape = tree.TREE_SHAPE
	one.visit_node = nil
	one.visit_record = contents_visit
	one.data = walking
	before := walking.nesting
	walking.nesting = nesting
	if tree.walk_tree(one, root) != .None {
		walking.failed = true
	}
	walking.nesting = before
}

contents_collect :: proc "contextless" (data: rawptr, index: u64, pointer: format.Pointer, value: format.Block_Value) {
	walking := (^Contents_Walk)(data)
	context = walking.saved
	append(&walking.collected, Stored_Block{index = index, check = pointer.check, value = value})
}

// contents_state_bytes reads the bytes of one state of an object, when it has at
// most CONTENTS_BYTES_LIMIT: ok is false when a block is wrong.
contents_state_bytes :: proc(walking: ^Contents_Walk, state: block_tree.State) -> (bytes: []u8, ok: bool) {
	if state.size > CONTENTS_BYTES_LIMIT {
		return nil, true
	}
	count, outcome := block_tree.range_read(&walking.objects_source.source, state, 0, walking.bytes[:state.size], &walking.block, &walking.node)
	if outcome != .Good || count != state.size {
		return nil, false
	}
	return slice.clone(walking.bytes[:state.size], walking.allocator), true
}

contents_visit :: proc "contextless" (one: ^tree.Walk, key: []u8, value: []u8) {
	walking := (^Contents_Walk)(one.data)
	context = walking.saved
	name_key := (^format.Entry_Name)(raw_data(key))^
	entry := (^format.Entry)(raw_data(value))^
	name := strings.clone(format.name_of(&name_key), walking.allocator)
	nesting := walking.nesting
	parts := make([dynamic]string, context.temp_allocator)
	append(&parts, ..walking.path[:nesting])
	append(&parts, name)
	item := Stored_Object {
		store = walking.store,
		name  = strings.join(parts[:], "/", walking.allocator),
		tree  = entry.kind == .Tree,
	}
	if entry.kind == .Tree {
		append(&walking.objects, item)
		if nesting < format.NESTING_LIMIT {
			walking.path[nesting] = name
			contents_walk_tree(walking, entry.pointer, nesting + 1)
		}
		return
	}
	state := walking.state
	reader := &walking.reader
	current := block_tree.State{root = entry.pointer, size = entry.size}
	item.size = entry.size
	bytes_ok: bool
	item.bytes, bytes_ok = contents_state_bytes(walking, current)
	clear(&walking.collected)
	blocks_outcome := block_tree.walk_blocks(&walking.objects_source.source, current, contents_collect, walking, &walking.nodes)
	item.blocks = slice.clone(walking.collected[:], walking.allocator)
	item.damaged = !bytes_ok || blocks_outcome != .Good
	// The hash of the entry: the hash that the block tree gives, from the
	// path of its last block.
	hash, hash_outcome := block_tree.state_hash(&walking.objects_source.source, current, &walking.hash_room)
	item.hash_wrong = hash_outcome != .Good || hash != entry.hash
	entries := make([]format.Version_Entry, format.VERSIONS_LIMIT, context.temp_allocator)
	count, versions_ok := storage_mount.versions_read(state, reader, entry.versions, entries)
	item.versions_damaged = !versions_ok
	versions := make([]Stored_Version, min(count, len(entries)), walking.allocator)
	for &version, index in versions {
		version_entry := entries[index]
		version.generation = version_entry.generation
		version.size = version_entry.size
		version.root = version_entry.root
		version_ok: bool
		version.bytes, version_ok = contents_state_bytes(walking, {root = version_entry.root, size = version_entry.size})
		version.damaged = !version_ok
	}
	item.versions = versions
	append(&walking.objects, item)
}

// same_contents says if two images give the same commit: the generation,
// and each object byte for byte, or block for block by their values.
same_contents :: proc(a, b: ^Disk_Contents) -> bool {
	if a.mount.generation != b.mount.generation || a.mount.needs_format != b.mount.needs_format || len(a.objects) != len(b.objects) {
		return false
	}
	for &item in a.objects {
		found := false
		for &other in b.objects {
			if other.store == item.store && other.name == item.name {
				found = same_object(&item, &other)
			}
		}
		if !found {
			return false
		}
	}
	return true
}

// same_object says if two images give one object the same bytes and the
// same versions.
same_object :: proc(item, other: ^Stored_Object) -> bool {
	if other.tree != item.tree || other.size != item.size || other.damaged || item.damaged || other.hash_wrong || item.hash_wrong {
		return false
	}
	if !slice.equal(other.bytes, item.bytes) || !slice.equal(other.blocks, item.blocks) {
		return false
	}
	return same_versions(item.versions, other.versions) && !item.versions_damaged && !other.versions_damaged
}

// same_versions says if two objects have the same versions: each one byte
// for byte, or a large one by its root, under which the open checked each
// block.
same_versions :: proc(a, b: []Stored_Version) -> bool {
	if len(a) != len(b) {
		return false
	}
	for &version, index in a {
		other := &b[index]
		if version.generation != other.generation || version.size != other.size || version.root != other.root || version.damaged || other.damaged || !slice.equal(version.bytes, other.bytes) {
			return false
		}
	}
	return true
}

// hashes_wrong counts the objects whose entry has another hash than the hash
// that their block tree gives.
hashes_wrong :: proc(contents: ^Disk_Contents) -> (count: int) {
	for &item in contents.objects {
		if !item.tree && item.hash_wrong {
			count += 1
		}
	}
	return count
}

// versions_thinned counts the versions of `before` that `after` no longer
// has: the versions that a commit thinned.
versions_thinned :: proc(before, after: ^Disk_Contents) -> (count: int) {
	for &item in before.objects {
		for &other in after.objects {
			if other.store != item.store || other.name != item.name {
				continue
			}
			for version in item.versions {
				kept := false
				for candidate in other.versions {
					kept ||= candidate.generation == version.generation
				}
				if !kept {
					count += 1
				}
			}
		}
	}
	return count
}

// version_count counts the versions of all the objects.
version_count :: proc(contents: ^Disk_Contents) -> (count: int) {
	for &item in contents.objects {
		count += len(item.versions)
	}
	return count
}

// One write of a crash image: a pending write, whole or torn.
Image_Write :: struct {
	index:         int, // In the pending writes.
	torn_sectors:  int, // 0: whole. Else only its first torn_sectors sectors are new.
}

// image_apply writes some pending writes on an image, and keeps the bytes
// that they replace in `undo`, so that image_restore gives the image back
// with no copy of the whole disk.
Undo :: struct {
	offset: u64,
	bytes:  []u8,
}

image_apply :: proc(image: []u8, pending: []Pending_Write, writes: []Image_Write, undo: ^[dynamic]Undo) {
	for write in writes {
		item := pending[write.index]
		count := len(item.bytes)
		if write.torn_sectors > 0 {
			count = min(write.torn_sectors * SECTOR_SIZE, count)
		}
		append(undo, Undo{offset = item.offset, bytes = slice.clone(image[item.offset:][:count], context.temp_allocator)})
		copy(image[item.offset:][:count], item.bytes[:count])
	}
}

image_restore :: proc(image: []u8, undo: ^[dynamic]Undo) {
	for index := len(undo) - 1; index >= 0; index -= 1 {
		copy(image[undo[index].offset:][:len(undo[index].bytes)], undo[index].bytes)
	}
	clear(undo)
}

Crash_Search :: struct {
	images:        int,
	wrong:         int,
	first_wrong:   string,
	older_images:  int, // Images that give the durable commit.
	newer_images:  int, // Images that give the commit in flight.
	torn_images:   int,
	elapsed:       time.Duration,
	versions_durable:   int, // The versions of the durable image.
	versions_in_flight: int, // The versions of the image with every write.
	thinned_in_flight:  int, // Versions of the durable image that the commit in flight thinned.
}

// crash_images_check builds the images that a loss of power can leave and
// checks each one.
crash_images_check :: proc(durable: []u8, pending: []Pending_Write, seed: u64) -> (search: Crash_Search) {
	start := time.tick_now()
	state := new(storage_mount.State)
	defer free(state)
	blocks := len(durable) / format.BLOCK_SIZE
	known := Known_Checks{checks = make([]u64, blocks), touched = make([]bool, blocks), values = make([]format.Block_Value, blocks), value_places = make([]u64, blocks)}
	defer delete(known.checks)
	defer delete(known.touched)
	defer delete(known.values)
	defer delete(known.value_places)
	for write in pending {
		for number := write.offset / format.BLOCK_SIZE; number * format.BLOCK_SIZE < write.offset + u64(len(write.bytes)) && number < u64(blocks); number += 1 {
			known.touched[number] = true
		}
	}
	before := disk_contents(durable, state, context.temp_allocator, &known)
	image := slice.clone(durable)
	defer delete(image)
	undo := make([dynamic]Undo, context.temp_allocator)
	everything := make([dynamic]Image_Write, context.temp_allocator)
	for index in 0 ..< len(pending) {
		append(&everything, Image_Write{index = index})
	}
	image_apply(image, pending, everything[:], &undo)
	after := disk_contents(image, state, context.temp_allocator, &known)
	image_restore(image, &undo)

	// The contents of one image live in an arena that the next image empties:
	// an image of a disk with 1000 versions gives megabytes of bytes.
	image_arena: virtual.Arena
	if virtual.arena_init_growing(&image_arena) != nil {
		search.wrong, search.first_wrong = 1, "no memory for the search"
		return search
	}
	defer virtual.arena_destroy(&image_arena)
	image_allocator := virtual.arena_allocator(&image_arena)
	search.versions_durable = version_count(&before)
	search.versions_in_flight = version_count(&after)
	search.thinned_in_flight = versions_thinned(&before, &after)

	check :: proc(search: ^Crash_Search, image: []u8, state: ^storage_mount.State, before, after: ^Disk_Contents, what: string, allocator: mem.Allocator, known: ^Known_Checks) {
		search.images += 1
		free_all(allocator)
		contents := disk_contents(image, state, allocator, known)
		problem := ""
		switch {
		case contents.mount.failed:
			problem = "the disk does not open"
		case contents.mount.wrong != 0:
			problem = fmt.tprintf("%d blocks have a wrong check", contents.mount.wrong)
		case contents.mount.named_twice != 0:
			problem = fmt.tprintf("%d blocks are named two times", contents.mount.named_twice)
		case contents.mount.reference_overflow != 0:
			problem = fmt.tprintf("%d blocks have more names than a count holds", contents.mount.reference_overflow)
		case contents.mount.named_by_two_stores != 0:
			problem = fmt.tprintf("%d blocks are named from two stores", contents.mount.named_by_two_stores)
		case contents.mount.damaged_versions != 0:
			problem = fmt.tprintf("%d versions have a wrong block", contents.mount.damaged_versions)
		case contents.mount.stores_with_wrong_count != 0:
			problem = fmt.tprintf("%d stores have a wrong count of blocks", contents.mount.stores_with_wrong_count)
		case hashes_wrong(&contents) != 0:
			problem = fmt.tprintf("%d objects have another hash than the hash that their block tree gives", hashes_wrong(&contents))
		case same_contents(&contents, before):
			search.older_images += 1
		case same_contents(&contents, after):
			search.newer_images += 1
		case:
			problem = fmt.tprintf("the objects are those of no commit (generation %d; durable %d, in flight %d)", contents.mount.generation, before.mount.generation, after.mount.generation)
		}
		if problem != "" {
			search.wrong += 1
			if search.first_wrong == "" {
				search.first_wrong = fmt.aprintf("%s: %s", what, problem)
			}
		}
	}

	writes := make([dynamic]Image_Write, context.temp_allocator)
	// 1. The durable image: each write after the last flush lost.
	check(&search, image, state, &before, &after, "the durable image", image_allocator, &known)
	// 2. Each prefix of the pending writes, in their order.
	for count in 1 ..= len(pending) {
		image_apply(image, pending, everything[:count], &undo)
		check(&search, image, state, &before, &after, fmt.tprintf("the first %d pending writes", count), image_allocator, &known)
		image_restore(image, &undo)
	}
	// 3. Each pending write alone.
	for index in 0 ..< len(pending) {
		image_apply(image, pending, everything[index:][:1], &undo)
		check(&search, image, state, &before, &after, fmt.tprintf("the pending write %d alone", index), image_allocator, &known)
		image_restore(image, &undo)
	}
	// 4. Each prefix with its next write torn: its first sector, its half,
	// all but its last sector.
	for index in 0 ..< len(pending) {
		sectors := len(pending[index].bytes) / SECTOR_SIZE
		if sectors < 2 {
			continue
		}
		for torn in ([]int{1, sectors / 2, sectors - 1}) {
			clear(&writes)
			append(&writes, ..everything[:index])
			append(&writes, Image_Write{index = index, torn_sectors = torn})
			image_apply(image, pending, writes[:], &undo)
			check(&search, image, state, &before, &after, fmt.tprintf("the first %d pending writes, then %d sectors of write %d", index, torn, index), image_allocator, &known)
			image_restore(image, &undo)
			search.torn_images += 1
		}
	}
	// 5. Random subsets, in the order of the writes, one write of each torn
	// one time in two.
	generator := rand.create(seed)
	random := rand.default_random_generator(&generator)
	for _ in 0 ..< POWER_LOSS_RANDOM_SUBSETS {
		clear(&writes)
		for index in 0 ..< len(pending) {
			if rand.int_max(2, random) == 1 {
				append(&writes, Image_Write{index = index})
			}
		}
		if len(writes) > 0 && rand.int_max(2, random) == 1 {
			chosen := rand.int_max(len(writes), random)
			sectors := len(pending[writes[chosen].index].bytes) / SECTOR_SIZE
			if sectors >= 2 {
				writes[chosen].torn_sectors = 1 + rand.int_max(sectors - 1, random)
				search.torn_images += 1
			}
		}
		image_apply(image, pending, writes[:], &undo)
		check(&search, image, state, &before, &after, fmt.tprintf("a random subset of %d of the %d pending writes", len(writes), len(pending)), image_allocator, &known)
		image_restore(image, &undo)
	}
	search.elapsed = time.tick_since(start)
	return search
}

// hard_image gives the image that the second machine starts on: the
// durable image with each later write lost, but a torn write of a root
// (block 0 or 1) when one was pending: the hardest image that a real disk
// can give the service at its start.
hard_image :: proc(durable: []u8, pending: []Pending_Write) -> (image: []u8, torn_root: bool) {
	image = slice.clone(durable)
	for index := len(pending) - 1; index >= 0; index -= 1 {
		item := pending[index]
		if item.offset < 2 * format.BLOCK_SIZE && len(item.bytes) >= 2 * SECTOR_SIZE {
			count := len(item.bytes) / 2
			copy(image[item.offset:][:count], item.bytes[:count])
			return image, true
		}
	}
	return image, false
}

// The first machine of each loss: a new disk, a note, then the count. The
// tool ends QEMU in the middle of the count: at the count 300, the store
// keeps each version (4500 blocks of limit); at the count 1200, the store is
// at its limit, and each commit thins the oldest versions of the store.
scenario_power_loss_early := [?]Step {
	{kind = .Wait, text = "compositor: surface console", any_order = true}, // The storage service can start first, for the boot pass of settings.
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "storage: ok, a new disk: generation 1, 16384 blocks", any_order = true},
	{kind = .Wait, text = "notes: a new store: no note, the count 0", any_order = true},
	{kind = .Wait, text = "compositor: surface notes"},
	{kind = .Type, text = "kept through a loss of power"},
	{kind = .Wait, text = "notes: the note is \"kept through a loss of power\", generation "},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "notes: count 300"},
	{kind = .Power_Loss},
}

scenario_power_loss_thinning := [?]Step {
	{kind = .Wait, text = "compositor: surface console", any_order = true}, // The storage service can start first, for the boot pass of settings.
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "storage: ok, a new disk: generation 1, 16384 blocks", any_order = true},
	{kind = .Wait, text = "notes: a new store: no note, the count 0", any_order = true},
	{kind = .Wait, text = "compositor: surface notes"},
	{kind = .Type, text = "kept through a loss of power"},
	{kind = .Wait, text = "notes: the note is \"kept through a loss of power\", generation "},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "notes: count 1000, stopped: 1000 commits in "},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "storage: the store notes is at its limit of 4500 blocks: the commit of generation ", any_order = true},
	{kind = .Wait, text = "notes: count 1200"},
	{kind = .Power_Loss},
}

// power_loss_run runs the two losses of power, each with its search, and a
// start on the hard image of the second one.
power_loss_run :: proc() -> bool {
	power_loss_sequence("before the limit", scenario_power_loss_early[:], 1, false) or_return
	return power_loss_sequence("during a thinning at the limit", scenario_power_loss_thinning[:], 3, true)
}

// power_loss_sequence runs one machine on a disk that the tool serves until
// the loss of power, checks each image that the loss can leave, then starts
// a machine on the hard image. `thinning`: the commit in flight must thin
// versions.
power_loss_sequence :: proc(what: string, steps: []Step, output_number: int, thinning: bool) -> bool {
	fresh := make([]u8, DATA_DISK_SIZE)
	defer delete(fresh)
	server: Network_Block_Device
	if !disk_server_start(&server, fresh) {
		return false
	}
	defer disk_server_free(&server)
	address := fmt.tprintf("nbd://127.0.0.1:%d", server.port)
	ran := machine_test(steps, BOOT_VOLUME, self_test_file(TEST_OUTPUT_POWER_LOSS, output_number), 0, address, disk_server = &server)
	disk_server_stop(&server)
	if !ran {
		return false
	}
	sync.mutex_lock(&server.lock)
	pending := server.pending[:]
	fmt.printfln("kerneltool: the loss of power %s (seed %d): the disk received %d writes, %d flushes and %d reads; %d writes came after the last flush", what, POWER_LOSS_SEED, server.writes, server.flushes, server.reads, len(pending))
	search := crash_images_check(server.durable, pending, POWER_LOSS_SEED)
	if search.wrong != 0 {
		fmt.eprintfln("kerneltool: test failed: %d of %d images of the disk after the loss of power are wrong; the first: %s", search.wrong, search.images, search.first_wrong)
		return false
	}
	test_passed_print("%d images of the disk after the loss of power %s, %d of them with a torn write, each one checked with the code of the storage service on the host in %d ms: %d give the durable commit, %d the commit in flight, none a mix; each object and each of its versions byte for byte (%d versions durable, %d in flight, %d thinned by the commit in flight)", search.images, what, search.torn_images, i64(search.elapsed / time.Millisecond), search.older_images, search.newer_images, search.versions_durable, search.versions_in_flight, search.thinned_in_flight)
	if thinning && search.thinned_in_flight == 0 {
		fmt.eprintfln("kerneltool: test failed: the commit in flight at the loss of power thinned no version: the store was not at its limit")
		return false
	}
	if !thinning && search.thinned_in_flight != 0 {
		fmt.eprintfln("kerneltool: test failed: the commit in flight thinned %d versions before the limit", search.thinned_in_flight)
		return false
	}
	// The flushes: two for each durable commit (its blocks, then its root),
	// one for the format of the new disk.
	state := new(storage_mount.State)
	defer free(state)
	durable_contents := disk_contents(server.durable, state)
	commits := int(durable_contents.mount.generation) - 1
	if server.flushes < 2 * commits + 1 {
		fmt.eprintfln("kerneltool: test failed: %d durable commits and %d flushes reached the disk: a commit needs two", commits, server.flushes)
		return false
	}
	test_passed_print("%d durable commits, and %d flushes reached the disk: the block service passes each flush of the storage service to the device", commits, server.flushes)
	image, torn_root := hard_image(server.durable, pending)
	defer delete(image)
	sync.mutex_unlock(&server.lock)
	if err := os.write_entire_file(TEST_POWER_LOSS_DISK, image); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", TEST_POWER_LOSS_DISK, err)
		return false
	}
	fmt.printfln("kerneltool: the second machine starts on the durable image%s: generation %d, %d versions", torn_root ? " with the write of a root torn" : "", durable_contents.mount.generation, version_count(&durable_contents))
	// The steps live in memory of their own: the run of a scenario frees the
	// temporary memory after each step.
	second := make([dynamic]Step)
	defer delete(second)
	append(&second, Step{kind = .Wait, text = "compositor: surface console", any_order = true})
	append(&second, Step{kind = .Launch, text = "notes"})
	if torn_root {
		append(&second, Step{kind = .Wait, text = "has a wrong check: a write that a stop cut; the service uses the root before it", any_order = true})
	}
	append(&second, Step{kind = .Wait, text = fmt.aprintf("storage: ok, generation %d: 1 stores, 2 objects, 0 trees, %d versions, ", durable_contents.mount.generation, version_count(&durable_contents)), any_order = true})
	append(&second, Step{kind = .Wait, text = "notes: restored the note \"kept through a loss of power\" and the count ", any_order = true})
	append(&second, Step{kind = .Wait, text = "compositor: surface notes"})
	if thinning {
		append(&second, Step{kind = .Shot, text = "power_loss"})
	}
	append(&second, Step{kind = .Quit})
	return machine_test(second[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_POWER_LOSS, output_number + 1), 0, TEST_POWER_LOSS_DISK)
}

// The settings through a loss of power (docs/FONTS.md, "The setting"): the
// program settings keeps 1000 records, one commit each, and the disk loses
// its power in the middle. Each image that a loss can leave gives the
// record of the durable commit or the record in flight, never a mix (the
// search above, on each object); the record of each image is a valid
// record. The second machine starts on the hard image, and the boot pass of
// settings writes the record of the durable commit on the page.
scenario_power_loss_settings_first := [?]Step {
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "settings: the boot pass: no settings kept: the defaults", any_order = true},
	{kind = .Wait, text = "root: settings stopped with code 0"},
	{kind = .Launch, text = "settings"},
	{kind = .Wait, text = "compositor: surface settings", any_order = true},
	{kind = .Wait, text = "settings: ok, "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"settings\")"},
	{kind = .Wait, text = "[console]   module     settings"},
	{kind = .Wait, text = "[console]   commands   3"},
	{kind = .Wait, text = "[console]   call       service"},
	{kind = .Type, text = "settings.repeat(1000)"},
	{kind = .Power_Loss},
}

// kept_settings_of gives the record of settings in the objects of an image,
// as the text of the boot pass, or "" when the image has none.
@(private = "file")
kept_settings_of :: proc(contents: ^Disk_Contents) -> (text: string, found: bool, valid: bool) {
	for &item in contents.objects {
		if item.store != "settings" || item.name != settings.KEPT_OBJECT_NAME {
			continue
		}
		values, ok := settings.kept_read(item.bytes)
		if !ok {
			return "", true, false
		}
		builder := strings.builder_make(context.temp_allocator)
		for setting in settings.Setting {
			description := settings.descriptions[setting]
			fmt.sbprintf(&builder, "%s%s %s", setting == .Font ? "" : ", ", description.title, description.value_names[values[setting]])
		}
		return strings.to_string(builder), true, true
	}
	return "", false, true
}

power_loss_settings_run :: proc() -> bool {
	fresh := make([]u8, DATA_DISK_SIZE)
	defer delete(fresh)
	server: Network_Block_Device
	if !disk_server_start(&server, fresh) {
		return false
	}
	defer disk_server_free(&server)
	address := fmt.tprintf("nbd://127.0.0.1:%d", server.port)
	ran := machine_test(scenario_power_loss_settings_first[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_POWER_LOSS, 3), 0, address, disk_server = &server)
	disk_server_stop(&server)
	if !ran {
		return false
	}
	sync.mutex_lock(&server.lock)
	pending := server.pending[:]
	search := crash_images_check(server.durable, pending, POWER_LOSS_SEED)
	if search.wrong != 0 {
		fmt.eprintfln("kerneltool: test failed: the settings: %d of %d images of the disk after the loss of power are wrong; the first: %s", search.wrong, search.images, search.first_wrong)
		return false
	}
	// The record of the durable commit, and of the commit in flight.
	state := new(storage_mount.State)
	defer free(state)
	durable := disk_contents(server.durable, state)
	durable_text, durable_found, durable_valid := kept_settings_of(&durable)
	image := slice.clone(server.durable)
	defer delete(image)
	undo := make([dynamic]Undo, context.temp_allocator)
	everything := make([dynamic]Image_Write, context.temp_allocator)
	for index in 0 ..< len(pending) {
		append(&everything, Image_Write{index = index})
	}
	image_apply(image, pending, everything[:], &undo)
	in_flight := disk_contents(image, state)
	in_flight_text, _, in_flight_valid := kept_settings_of(&in_flight)
	if !durable_found || !durable_valid || !in_flight_valid {
		fmt.eprintfln("kerneltool: test failed: the settings: the durable image has %s record of settings (valid: %v); the image with each write, valid: %v", durable_found ? "a" : "no", durable_valid, in_flight_valid)
		return false
	}
	test_passed_print("the settings: %d images of the disk after the loss of power, %d with a torn write: %d give the durable record (%s, generation %d), %d the record in flight (%s, generation %d), none a mix", search.images, search.torn_images, search.older_images, durable_text, durable.mount.generation, search.newer_images, in_flight_text, in_flight.mount.generation)
	hard, _ := hard_image(server.durable, pending)
	defer delete(hard)
	sync.mutex_unlock(&server.lock)
	if err := os.write_entire_file(TEST_POWER_LOSS_DISK, hard); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", TEST_POWER_LOSS_DISK, err)
		return false
	}
	second := [?]Step {
		{kind = .Wait, text = "compositor: surface console", any_order = true},
		{kind = .Wait, text = fmt.aprintf("settings: the boot pass: the settings kept in the store: %s; in ", durable_text), any_order = true},
		{kind = .Wait, text = "root: settings stopped with code 0"},
		{kind = .Quit},
	}
	return machine_test(second[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_POWER_LOSS, 4), 0, TEST_POWER_LOSS_DISK)
}

// The range writes through a loss of power (docs/STORAGE.md, "Ranges"):
// the program ranges makes its cases, then a loop of commits of 4 range
// writes each, and the disk loses its power in the loop. The loss comes at
// the write of a root, so the commit in flight is a commit of range writes:
// each image that a loss can leave gives the durable commit or that commit,
// never a mix, each object byte for byte or block for block. The second
// machine starts on the hard image, and ranges reads back what its cases
// left.
scenario_power_loss_ranges := [?]Step {
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "storage: ok, a new disk: generation 1, 16384 blocks", any_order = true},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"ranges\")"},
	{kind = .Wait, text = "ranges: a new store: the first run", any_order = true},
	{kind = .Wait, text = "ranges: loop, 100 commits of 4 range writes, in "},
	{kind = .Power_Loss},
}

// stored_object_of gives an object of the contents of an image, or nil.
stored_object_of :: proc(contents: ^Disk_Contents, store: string, name: string) -> ^Stored_Object {
	for &item in contents.objects {
		if item.store == store && item.name == name {
			return &item
		}
	}
	return nil
}

power_loss_ranges_run :: proc() -> bool {
	fresh := make([]u8, DATA_DISK_SIZE)
	defer delete(fresh)
	server: Network_Block_Device
	if !disk_server_start(&server, fresh) {
		return false
	}
	defer disk_server_free(&server)
	address := fmt.tprintf("nbd://127.0.0.1:%d", server.port)
	ran := machine_test(scenario_power_loss_ranges[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_POWER_LOSS, 5), 0, address, disk_server = &server)
	disk_server_stop(&server)
	if !ran {
		return false
	}
	sync.mutex_lock(&server.lock)
	pending := server.pending[:]
	fmt.printfln("kerneltool: the loss of power during range commits (seed %d): the disk received %d writes, %d flushes and %d reads; %d writes came after the last flush", POWER_LOSS_SEED, server.writes, server.flushes, server.reads, len(pending))
	search := crash_images_check(server.durable, pending, POWER_LOSS_SEED)
	if search.wrong != 0 {
		fmt.eprintfln("kerneltool: test failed: the range writes: %d of %d images of the disk after the loss of power are wrong; the first: %s", search.wrong, search.images, search.first_wrong)
		sync.mutex_unlock(&server.lock)
		return false
	}
	// The commit in flight changes the object of the loop: range writes were
	// in flight.
	state := new(storage_mount.State)
	defer free(state)
	durable := disk_contents(server.durable, state)
	image := slice.clone(server.durable)
	defer delete(image)
	undo := make([dynamic]Undo, context.temp_allocator)
	everything := make([dynamic]Image_Write, context.temp_allocator)
	for index in 0 ..< len(pending) {
		append(&everything, Image_Write{index = index})
	}
	image_apply(image, pending, everything[:], &undo)
	in_flight := disk_contents(image, state)
	loop_durable := stored_object_of(&durable, "ranges", "loop")
	loop_in_flight := stored_object_of(&in_flight, "ranges", "loop")
	if loop_durable == nil || loop_in_flight == nil || in_flight.mount.generation <= durable.mount.generation || same_object(loop_durable, loop_in_flight) {
		fmt.eprintfln("kerneltool: test failed: the commit in flight at the loss of power is not a commit of range writes on the object loop (durable generation %d, in flight %d)", durable.mount.generation, in_flight.mount.generation)
		sync.mutex_unlock(&server.lock)
		return false
	}
	test_passed_print("the range writes: %d images of the disk after the loss of power in a loop of range commits, %d of them with a torn write: %d give the durable commit (generation %d), %d the commit of range writes in flight (generation %d, the object loop with %d blocks of data), none a mix", search.images, search.torn_images, search.older_images, durable.mount.generation, search.newer_images, in_flight.mount.generation, len(loop_in_flight.blocks))
	hard, torn_root := hard_image(server.durable, pending)
	defer delete(hard)
	sync.mutex_unlock(&server.lock)
	if err := os.write_entire_file(TEST_POWER_LOSS_DISK, hard); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", TEST_POWER_LOSS_DISK, err)
		return false
	}
	// The steps live in memory of their own: the run of a scenario frees the
	// temporary memory after each step.
	second := make([dynamic]Step)
	defer delete(second)
	append(&second, Step{kind = .Wait, text = "compositor: surface console", any_order = true})
	if torn_root {
		append(&second, Step{kind = .Wait, text = "has a wrong check: a write that a stop cut; the service uses the root before it", any_order = true})
	}
	append(&second, Step{kind = .Wait, text = fmt.aprintf("storage: ok, generation %d: ", durable.mount.generation), any_order = true})
	append(&second, Step{kind = .Front, text = "console"})
	append(&second, Step{kind = .Type, text = "start(\"ranges\")"})
	append(&second, Step{kind = .Wait, text = "ranges: a store with 4 objects: the run after the remount"})
	append(&second, Step{kind = .Wait, text = "ranges: after the remount: the sparse object of 8589934592 bytes reads its 3 blocks and its 1000 writes, byte for byte: as it must"})
	append(&second, Step{kind = .Wait, text = "ranges: after the remount: the small object, the object of the cut and the object of the loop: as it must"})
	append(&second, Step{kind = .Wait, text = "ranges: done, 0 wrong"})
	append(&second, Step{kind = .Quit})
	return machine_test(second[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_POWER_LOSS, 6), 0, TEST_POWER_LOSS_DISK)
}
