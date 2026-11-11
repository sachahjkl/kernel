package kerneltool

import format "contract:store"
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

// The loss of power (property 9: a stop of the machine never shows a part
// of a commit). The tool serves the data disk itself (network_block_device.odin),
// so it knows each write that a flush made durable, and each write after the
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
//     count of blocks of each store equal to what its table names;
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

// One version of an object, as an image gives it.
Stored_Version :: struct {
	generation: u64,
	bytes:      []u8,
	damaged:    bool,
}

// One object of a store, as an image gives it: its current version and its
// versions, the oldest first.
Stored_Object :: struct {
	store:    string,
	name:     string,
	bytes:    []u8,
	damaged:  bool,
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

// The checks of the blocks of the durable image, kept for the search: an
// image of the search differs from it only in the blocks that a pending
// write touched, and those are computed each time.
Known_Checks :: struct {
	checks:  []u64, // 0: not computed yet.
	touched: []bool, // A pending write touched the block.
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

// disk_contents opens an image as the storage service does, and reads each
// object, checked. The strings and the bytes are in the temporary memory.
disk_contents :: proc(image: []u8, state: ^storage_mount.State, allocator := context.temp_allocator, known: ^Known_Checks = nil) -> (contents: Disk_Contents) {
	reader := Image_Reader{reader = {read = image_read, check = image_check}, image = image, known = known}
	contents.mount = storage_mount.mount(state, &reader, u64(len(image)) / format.BLOCK_SIZE)
	contents.objects = make([dynamic]Stored_Object, allocator)
	if contents.mount.failed || contents.mount.needs_format {
		return contents
	}
	bytes := make([]u8, format.OBJECT_BLOCKS_LIMIT * format.BLOCK_SIZE, allocator)
	for &store, store_index in state.root.stores {
		if store.name[0] == 0 || state.store_damaged[store_index] {
			continue
		}
		for &object, object_index in state.tables[store_index].objects {
			if object.name[0] == 0 {
				continue
			}
			size, ok := storage_mount.object_bytes(state, &reader, store_index, object_index, bytes)
			item := Stored_Object {
				store   = strings.clone(string(cstring(&store.name[0])), allocator),
				name    = strings.clone(string(cstring(&object.name[0])), allocator),
				damaged = !ok,
			}
			if ok {
				item.bytes = slice.clone(bytes[:size], allocator)
			}
			entries := make([]format.Version_Entry, format.VERSIONS_LIMIT, allocator)
			count, versions_ok := storage_mount.versions_read(state, &reader, object.versions, entries)
			item.versions_damaged = !versions_ok
			versions := make([]Stored_Version, min(count, len(entries)), allocator)
			for &version, index in versions {
				entry := entries[index]
				version.generation = entry.generation
				if storage_mount.list_bytes(state, &reader, entry.list, entry.size, bytes) {
					version.bytes = slice.clone(bytes[:entry.size], allocator)
				} else {
					version.damaged = true
				}
			}
			item.versions = versions
			append(&contents.objects, item)
		}
	}
	return contents
}

// same_contents says if two images give the same commit: the generation,
// and each object byte for byte.
same_contents :: proc(a, b: ^Disk_Contents) -> bool {
	if a.mount.generation != b.mount.generation || a.mount.needs_format != b.mount.needs_format || len(a.objects) != len(b.objects) {
		return false
	}
	for &item in a.objects {
		found := false
		for &other in b.objects {
			if other.store == item.store && other.name == item.name {
				found = !other.damaged && !item.damaged && slice.equal(other.bytes, item.bytes) && same_versions(item.versions, other.versions) && !item.versions_damaged && !other.versions_damaged
			}
		}
		if !found {
			return false
		}
	}
	return true
}

// same_versions says if two objects have the same versions, each one byte
// for byte.
same_versions :: proc(a, b: []Stored_Version) -> bool {
	if len(a) != len(b) {
		return false
	}
	for &version, index in a {
		other := &b[index]
		if version.generation != other.generation || version.damaged || other.damaged || !slice.equal(version.bytes, other.bytes) {
			return false
		}
	}
	return true
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
	known := Known_Checks{checks = make([]u64, blocks), touched = make([]bool, blocks)}
	defer delete(known.checks)
	defer delete(known.touched)
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
		case contents.mount.named_by_two_stores != 0:
			problem = fmt.tprintf("%d blocks are named from two stores", contents.mount.named_by_two_stores)
		case contents.mount.damaged_versions != 0:
			problem = fmt.tprintf("%d versions have a wrong block", contents.mount.damaged_versions)
		case contents.mount.stores_with_wrong_count != 0:
			problem = fmt.tprintf("%d stores have a wrong count of blocks", contents.mount.stores_with_wrong_count)
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
	{kind = .Wait, text = "compositor: surface console"},
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
	{kind = .Wait, text = "compositor: surface console"},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "storage: ok, a new disk: generation 1, 16384 blocks", any_order = true},
	{kind = .Wait, text = "notes: a new store: no note, the count 0", any_order = true},
	{kind = .Wait, text = "compositor: surface notes"},
	{kind = .Type, text = "kept through a loss of power"},
	{kind = .Wait, text = "notes: the note is \"kept through a loss of power\", generation "},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "notes: count 1000, stopped: 1000 commits in "},
	{kind = .Key, text = "tab"},
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
	fmt.printfln("kerneltool: test passed: %d images of the disk after the loss of power %s, %d of them with a torn write, each one checked with the code of the storage service on the host in %d ms: %d give the durable commit, %d the commit in flight, none a mix; each object and each of its versions byte for byte (%d versions durable, %d in flight, %d thinned by the commit in flight)", search.images, what, search.torn_images, i64(search.elapsed / time.Millisecond), search.older_images, search.newer_images, search.versions_durable, search.versions_in_flight, search.thinned_in_flight)
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
	fmt.printfln("kerneltool: test passed: %d durable commits, and %d flushes reached the disk: the block service passes each flush of the storage service to the device", commits, server.flushes)
	image, torn_root := hard_image(server.durable, pending)
	defer delete(image)
	sync.mutex_unlock(&server.lock)
	if err := os.write_entire_file(TEST_POWER_LOSS_DISK, image); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", TEST_POWER_LOSS_DISK, err)
		return false
	}
	fmt.printfln("kerneltool: the second machine starts on the durable image%s: generation %d, %d versions", torn_root ? " with the write of a root torn" : "", durable_contents.mount.generation, version_count(&durable_contents))
	second := make([dynamic]Step, context.temp_allocator)
	append(&second, Step{kind = .Wait, text = "compositor: surface console"})
	append(&second, Step{kind = .Launch, text = "notes"})
	if torn_root {
		append(&second, Step{kind = .Wait, text = "has a wrong check: a write that a stop cut; the service uses the root before it", any_order = true})
	}
	append(&second, Step{kind = .Wait, text = fmt.aprintf("storage: ok, generation %d: 1 stores, 2 objects, %d versions, ", durable_contents.mount.generation, version_count(&durable_contents)), any_order = true})
	append(&second, Step{kind = .Wait, text = "notes: restored the note \"kept through a loss of power\" and the count ", any_order = true})
	append(&second, Step{kind = .Wait, text = "compositor: surface notes"})
	if thinning {
		append(&second, Step{kind = .Shot, text = "power_loss"})
	}
	append(&second, Step{kind = .Quit})
	return machine_test(second[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_POWER_LOSS, output_number + 1), 0, TEST_POWER_LOSS_DISK)
}
