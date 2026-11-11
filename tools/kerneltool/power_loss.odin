package kerneltool

import "contract:settings"
import format "contract:store"
import "core:fmt"
import "core:math/rand"
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

// One object of a store, as an image gives it.
Stored_Object :: struct {
	store:   string,
	name:    string,
	bytes:   []u8,
	damaged: bool,
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
disk_contents :: proc(image: []u8, state: ^storage_mount.State) -> (contents: Disk_Contents) {
	reader := Image_Reader{reader = {read = image_read}, image = image}
	contents.mount = storage_mount.mount(state, &reader, u64(len(image)) / format.BLOCK_SIZE)
	contents.objects = make([dynamic]Stored_Object, context.temp_allocator)
	if contents.mount.failed || contents.mount.needs_format {
		return contents
	}
	bytes := make([]u8, format.OBJECT_BLOCKS_LIMIT * format.BLOCK_SIZE, context.temp_allocator)
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
				store   = strings.clone(string(cstring(&store.name[0])), context.temp_allocator),
				name    = strings.clone(string(cstring(&object.name[0])), context.temp_allocator),
				damaged = !ok,
			}
			if ok {
				item.bytes = slice.clone(bytes[:size], context.temp_allocator)
			}
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
				found = !other.damaged && !item.damaged && slice.equal(other.bytes, item.bytes)
			}
		}
		if !found {
			return false
		}
	}
	return true
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
}

// crash_images_check builds the images that a loss of power can leave and
// checks each one.
crash_images_check :: proc(durable: []u8, pending: []Pending_Write, seed: u64) -> (search: Crash_Search) {
	start := time.tick_now()
	state := new(storage_mount.State)
	defer free(state)
	before := disk_contents(durable, state)
	image := slice.clone(durable)
	defer delete(image)
	undo := make([dynamic]Undo, context.temp_allocator)
	everything := make([dynamic]Image_Write, context.temp_allocator)
	for index in 0 ..< len(pending) {
		append(&everything, Image_Write{index = index})
	}
	image_apply(image, pending, everything[:], &undo)
	after := disk_contents(image, state)
	image_restore(image, &undo)

	check :: proc(search: ^Crash_Search, image: []u8, state: ^storage_mount.State, before, after: ^Disk_Contents, what: string) {
		search.images += 1
		contents := disk_contents(image, state)
		problem := ""
		switch {
		case contents.mount.failed:
			problem = "the disk does not open"
		case contents.mount.wrong != 0:
			problem = fmt.tprintf("%d blocks have a wrong check", contents.mount.wrong)
		case contents.mount.named_twice != 0:
			problem = fmt.tprintf("%d blocks are named two times", contents.mount.named_twice)
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
	check(&search, image, state, &before, &after, "the durable image")
	// 2. Each prefix of the pending writes, in their order.
	for count in 1 ..= len(pending) {
		image_apply(image, pending, everything[:count], &undo)
		check(&search, image, state, &before, &after, fmt.tprintf("the first %d pending writes", count))
		image_restore(image, &undo)
	}
	// 3. Each pending write alone.
	for index in 0 ..< len(pending) {
		image_apply(image, pending, everything[index:][:1], &undo)
		check(&search, image, state, &before, &after, fmt.tprintf("the pending write %d alone", index))
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
			check(&search, image, state, &before, &after, fmt.tprintf("the first %d pending writes, then %d sectors of write %d", index, torn, index))
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
		check(&search, image, state, &before, &after, fmt.tprintf("a random subset of %d of the %d pending writes", len(writes), len(pending)))
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

// The first machine: a new disk, a note, then a count of 1000 commits; the
// tool ends QEMU in the middle of the count.
scenario_power_loss_first := [?]Step {
	{kind = .Wait, text = "compositor: surface console", any_order = true},
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

// power_loss_run runs the two machines and the search.
power_loss_run :: proc() -> bool {
	fresh := make([]u8, DATA_DISK_SIZE)
	defer delete(fresh)
	server: Network_Block_Device
	if !disk_server_start(&server, fresh) {
		return false
	}
	defer disk_server_free(&server)
	address := fmt.tprintf("nbd://127.0.0.1:%d", server.port)
	ran := machine_test(scenario_power_loss_first[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_POWER_LOSS, 1), 0, address, disk_server = &server)
	disk_server_stop(&server)
	if !ran {
		return false
	}
	sync.mutex_lock(&server.lock)
	pending := server.pending[:]
	fmt.printfln("kerneltool: the loss of power (seed %d): the disk received %d writes, %d flushes and %d reads; %d writes came after the last flush", POWER_LOSS_SEED, server.writes, server.flushes, server.reads, len(pending))
	search := crash_images_check(server.durable, pending, POWER_LOSS_SEED)
	if search.wrong != 0 {
		fmt.eprintfln("kerneltool: test failed: %d of %d images of the disk after the loss of power are wrong; the first: %s", search.wrong, search.images, search.first_wrong)
		return false
	}
	fmt.printfln("kerneltool: test passed: %d images of the disk after the loss of power, %d of them with a torn write, each one checked with the code of the storage service on the host in %d ms: %d give the durable commit, %d the commit in flight, none a mix", search.images, search.torn_images, i64(search.elapsed / time.Millisecond), search.older_images, search.newer_images)
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
	fmt.printfln("kerneltool: the second machine starts on the durable image%s: generation %d", torn_root ? " with the write of a root torn" : "", durable_contents.mount.generation)
	second := make([dynamic]Step, context.temp_allocator)
	append(&second, Step{kind = .Wait, text = "compositor: surface console", any_order = true})
	append(&second, Step{kind = .Launch, text = "notes"})
	if torn_root {
		append(&second, Step{kind = .Wait, text = "has a wrong check: a write that a stop cut; the service uses the root before it", any_order = true})
	}
	append(&second, Step{kind = .Wait, text = fmt.aprintf("storage: ok, generation %d: ", durable_contents.mount.generation), any_order = true})
	append(&second, Step{kind = .Wait, text = "notes: restored the note \"kept through a loss of power\" and the count ", any_order = true})
	append(&second, Step{kind = .Wait, text = "compositor: surface notes"})
	append(&second, Step{kind = .Shot, text = "power_loss"})
	append(&second, Step{kind = .Quit})
	return machine_test(second[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_POWER_LOSS, 2), 0, TEST_POWER_LOSS_DISK)
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
	{kind = .Wait, text = "[console] settings: 3 commands of a service that runs"},
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
	fmt.printfln("kerneltool: test passed: the settings: %d images of the disk after the loss of power, %d with a torn write: %d give the durable record (%s, generation %d), %d the record in flight (%s, generation %d), none a mix", search.images, search.torn_images, search.older_images, durable_text, durable.mount.generation, search.newer_images, in_flight_text, in_flight.mount.generation)
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
