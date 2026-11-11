// A measure of the block service (contract/block), on a disk of its own:
// the disk of the measures, that holds no data of a program.
//
// The program reads and writes blocks for one second in each measure: one
// block in each request, with one request in flight and then with 32. It
// counts the blocks and the kernel entries of the two programs for each
// request: its own entries (the system library counts them) and those of
// the block service (the command Statistics). Then it writes a pattern,
// flushes, reads it back and compares.
package disk

import "contract:block"
import "contract:ring"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:system"

// The window is built with the interface package (docs/INTERFACE.md).
records_now, records_before: [512]interface.Draw_Record
text_now, text_before: [8192]u8
drawing: interface.Window_Drawing

DURATION :: 1000 // Milliseconds of one measure.
REGION_PAGES :: 256 // The data region: 1 MiB.
MEASURE_BLOCKS :: 4096 // The blocks that the measures use, from block 0: 16 MiB.

LINE :: 24
BAR_WIDTH :: 200
RATE_X :: 300
ENTRIES_X :: RATE_X + BAR_WIDTH + 90
WIDTH :: ENTRIES_X + BAR_WIDTH + 70
HEIGHT :: 12 + 4 * LINE + len(measures) * LINE + 2 * LINE + 12

COLOR_RATE :: 0x58D878
COLOR_ENTRIES :: 0xE0A040

Measure :: struct {
	write:   bool,
	depth:   u32, // Requests in flight.
	blocks:  u64, // Blocks in each request.
	done:    bool,
	rate:    u64, // Blocks in one second.
	client:  u64, // Kernel entries of this program for 100 requests.
	service: u64, // Kernel entries of the block service for 100 requests.
	errors:  u64,
}

measures := [?]Measure {
	{write = false, depth = 1, blocks = 1},
	{write = false, depth = 32, blocks = 1},
	{write = true, depth = 1, blocks = 1},
	{write = true, depth = 32, blocks = 1},
	{write = false, depth = 8, blocks = 16},
}

blocks: ring.Ring
region: [^]u8
disk_blocks: u64
wrong: u64 // Blocks that did not read back as written.
statistics_tag: u32 = 1 << 31

// request sends one command, and waits for room if the queue is full.
request :: proc "contextless" (command: block.Command, tag: u32, values: [7]u64 = {}) {
	record := ring.Record{kind = u32(command), tag = tag, values = values}
	for !system.send(&blocks.commands, record) {
		wait: system.Wait
		system.wait_room(&wait, &blocks.commands)
		system.wait_end(&wait)
	}
}

// answer waits for the next completion.
answer :: proc "contextless" () -> ring.Record {
	for {
		if record, ok := system.receive(&blocks.completions); ok {
			return record
		}
		wait: system.Wait
		system.wait_records(&wait, &blocks.completions)
		if !system.wait_spin(&wait) {
			system.wait_end(&wait)
		}
	}
}

// call sends one command and waits for its completion.
call :: proc "contextless" (command: block.Command, values: [7]u64 = {}) -> ring.Record {
	statistics_tag += 1
	request(command, statistics_tag, values)
	for {
		record := answer()
		if record.tag == statistics_tag {
			return record
		}
	}
}

service_entries :: proc "contextless" () -> u64 {
	return call(.Statistics).values[2]
}

run :: proc "contextless" (measure: ^Measure) {
	command := measure.write ? block.Command.Write : block.Command.Read
	next: u64 // The number of the next request.
	issue :: proc "contextless" (command: block.Command, measure: ^Measure, next: ^u64) {
		place := next^ % u64(measure.depth)
		first := next^ * measure.blocks % (MEASURE_BLOCKS - measure.blocks)
		request(command, u32(place), {0 = first, 1 = measure.blocks, 2 = place * measure.blocks * block.BLOCK_SIZE})
		next^ += 1
	}
	service_before := service_entries()
	client_before := system.kernel_entries()
	start := system.time()
	for _ in 0 ..< measure.depth {
		issue(command, measure, &next)
	}
	done: u64
	for {
		record := answer()
		if block.Status(record.kind) != .Ok {
			measure.errors += 1
		}
		done += 1
		if system.time() - start >= DURATION {
			break
		}
		issue(command, measure, &next)
	}
	for done < next {
		if block.Status(answer().kind) != .Ok {
			measure.errors += 1
		}
		done += 1
	}
	elapsed := max(system.time() - start, 1)
	client := system.kernel_entries() - client_before
	service := service_entries() - service_before
	measure.rate = done * measure.blocks * 1000 / elapsed
	measure.client = client * 100 / max(done, 1)
	measure.service = service * 100 / max(done, 1)
	measure.done = true
	system.log("disk: ", measure.write ? "write" : "read", ", ", measure.blocks, measure.blocks == 1 ? " block" : " blocks", " in each request, ", u64(measure.depth), " in flight: ", measure.rate, " blocks in one second, kernel entries for 100 requests: ", measure.client, " of this program, ", measure.service, " of the block service, ", measure.errors, " errors")
}

// check writes a pattern in 256 blocks, flushes, reads the blocks back in
// another part of the region and compares.
check :: proc "contextless" () {
	COUNT :: 128
	for index in 0 ..< COUNT * block.BLOCK_SIZE {
		region[index] = u8(index / block.BLOCK_SIZE * 7 + index % 251)
	}
	for request_index in u64(0) ..< COUNT / 16 {
		request(.Write, u32(request_index), {0 = MEASURE_BLOCKS + request_index * 16, 1 = 16, 2 = request_index * 16 * block.BLOCK_SIZE})
	}
	for _ in 0 ..< COUNT / 16 {
		if block.Status(answer().kind) != .Ok {
			wrong += 1
		}
	}
	if block.Status(call(.Flush).kind) != .Ok {
		wrong += 1
	}
	base := u64(COUNT * block.BLOCK_SIZE)
	for request_index in u64(0) ..< COUNT / 16 {
		request(.Read, u32(request_index), {0 = MEASURE_BLOCKS + request_index * 16, 1 = 16, 2 = base + request_index * 16 * block.BLOCK_SIZE})
	}
	for _ in 0 ..< COUNT / 16 {
		if block.Status(answer().kind) != .Ok {
			wrong += 1
		}
	}
	for index in 0 ..< COUNT * block.BLOCK_SIZE {
		if region[base + u64(index)] != region[index] {
			wrong += 1
		}
	}
}

bar :: proc "contextless" (table: ^interface.Draw_Table, x, y: int, value, most: u64, color: graphics.Color) {
	interface.draw_rectangle(table, x, y + 3, BAR_WIDTH, 10, graphics.COLOR_TRACK)
	interface.draw_rectangle(table, x, y + 3, int(value * BAR_WIDTH / max(most, 1)), 10, color)
	interface.draw_unsigned(table, x + BAR_WIDTH + 8, y, value, graphics.COLOR_TEXT)
}

checked: bool

draw :: proc "contextless" (window: ^display.Window) {
	if drawing.now.records == nil {
		drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	}
	frame := interface.window_frame_begin(&drawing, window)
	table := frame.table
	interface.draw_rectangle(table, 0, 0, WIDTH, HEIGHT, graphics.COLOR_BACKGROUND)
	most_rate, most_entries: u64
	for measure in measures {
		most_rate, most_entries = max(most_rate, measure.rate), max(most_entries, measure.client + measure.service)
	}
	y := 12
	interface.draw_text(table, 12, y, "the block service: a virtio disk, a ring, the data in shared memory.", graphics.COLOR_DIM)
	y += LINE
	interface.draw_text(table, 12, y, "the device reads and writes the memory of this program: no copy.", graphics.COLOR_DIM)
	y += LINE
	interface.draw_text(table, 12, y, "disk:", graphics.COLOR_DIM)
	interface.draw_unsigned(table, 60, y, disk_blocks, graphics.COLOR_TEXT)
	digits := 1
	for value := disk_blocks; value >= 10; value /= 10 {
		digits += 1
	}
	interface.draw_text(table, 60 + 8 * (digits + 1), y, "blocks of 4096 bytes", graphics.COLOR_DIM)
	y += LINE + LINE / 2
	interface.draw_text(table, 12, y, "request         in flight", graphics.COLOR_DIM)
	interface.draw_text(table, RATE_X, y, "blocks in one second", graphics.COLOR_DIM)
	interface.draw_text(table, ENTRIES_X, y, "kernel entries, 100 requests", graphics.COLOR_DIM)
	y += LINE
	for measure, index in measures {
		if index % 2 == 0 {
			interface.draw_rectangle(table, 6, y - 4, WIDTH - 12, LINE, graphics.COLOR_CARD_TOP)
		}
		interface.draw_text(table, 12, y, measure.write ? "write" : "read", graphics.COLOR_TEXT)
		interface.draw_unsigned(table, 64, y, measure.blocks, graphics.COLOR_TEXT)
		interface.draw_text(table, 92, y, measure.blocks == 1 ? "block" : "blocks", graphics.COLOR_DIM)
		interface.draw_unsigned(table, 156, y, u64(measure.depth), graphics.COLOR_TEXT)
		if measure.done {
			bar(table, RATE_X, y, measure.rate, most_rate, measure.errors == 0 ? COLOR_RATE : graphics.COLOR_FAILED)
			bar(table, ENTRIES_X, y, measure.client + measure.service, most_entries, COLOR_ENTRIES)
		} else {
			interface.draw_text(table, RATE_X, y, "...", graphics.COLOR_DIM)
		}
		y += LINE
	}
	y += LINE / 2
	if checked {
		interface.draw_text(table, 12, y, wrong == 0 ? "write, flush, read back: 128 blocks, 0 wrong" : "write, flush, read back: WRONG", wrong == 0 ? COLOR_RATE : graphics.COLOR_FAILED)
	}
	interface.window_frame_end(&drawing, &frame, window)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "disk")
	if !ok {
		system.stop(1)
	}
	ring_memory := ctx.handles[block.GRANT_RING]
	status: system.Status
	if blocks, status = system.ring_open(ring_memory); status != .Ok {
		system.log("disk: no block ring")
		system.stop(1)
	}
	memory, memory_status := system.memory_create(REGION_PAGES, 0, {.Contiguous}) // The device reads and writes it.
	address, map_status := system.memory_map(memory, {.Write})
	if memory_status != .Ok || map_status != .Ok {
		system.log("disk: no data region")
		system.stop(1)
	}
	region = ([^]u8)(address)
	// The data region goes to the block service through the block ring.
	// The block service maps the ring when it starts: until then, the kernel
	// does not know the other side.
	given: system.Handle
	give_status := system.Status.Bad_Handle
	for attempt := 0; attempt < 2000 && give_status != .Ok; attempt += 1 {
		if given, give_status = system.give(ring_memory, memory, {.Read, .Write}); give_status != .Ok {
			system.sleep(system.time() + 1)
		}
	}
	if give_status != .Ok {
		system.log("disk: the block service does not map the block ring")
		system.stop(1)
	}
	if attached := call(.Attach, {0 = u64(given)}); block.Status(attached.kind) != .Ok {
		system.log("disk: the block service refused the data region: status ", u64(attached.kind))
		system.stop(1)
	}
	info := call(.Info)
	disk_blocks = info.values[0]
	system.log("disk: ok, the disk has ", disk_blocks, " blocks, ", info.values[1], " blocks in one request at most")
	draw(&window)
	errors: u64
	for &measure in measures {
		run(&measure)
		errors += measure.errors
		draw(&window)
	}
	check()
	checked = true
	if errors == 0 && wrong == 0 {
		system.log("disk: ok, ", u64(len(measures)), " measures, 0 errors, write then read back: 0 wrong")
	} else {
		system.log("disk: wrong: ", errors, " errors, ", wrong, " wrong bytes")
	}
	for {
		draw(&window)
		display.wait(&window)
		for _ in display.next_event(&window) {
		}
	}
}
