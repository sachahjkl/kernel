// The block service: the device service of one virtio block device (virtio
// 1.x over PCI, the "modern" interface). It serves the block contract
// (src/library/contract/block) to one client, through the block ring that the root
// service gives to both.
//
// It has one device and nothing else: the registers of the device, one
// message interrupt, memory for the queue, the machine with the right
// Physical only, and a copy of the configuration of the device. The root
// service found the device, enabled it and set its interrupt
// (src/library/support/pci). The kernel has no code for this device: the code that
// knows a device is a program or a library. The code that each virtio
// device service shares is in src/library/support/virtio.
//
// The device reads and writes the data region of the client: the kernel is
// not on the path of the data, so data moves with no kernel entry. The
// service enters the kernel
// to wait, and to wake its client; one entry serves many requests.
//
// **What it is for.** It shows two things: a disk driver is a program
// with no right beyond its one device, and the data of a disk moves with
// no copy and no kernel entry for each block. The program that uses the
// disk (its client) holds a [data region](term:data-region); the client
// lends it once with `Attach`, and the device then reads and writes it
// directly.
//
// **Who uses it.** The root service starts a block service when it starts
// a program with a grant of a disk, for the device at the place of that
// disk on the bus. It gives the [block ring](term:block-ring) to that one
// client, and takes the device back when the block service stops:
//
// - the [data disk](term:data-disk), to the storage service (the grant
//   **Data_Disk**);
// - the [disk of the measures](term:disk-of-the-measures), to the program
//   `disk` (the grant **Scratch_Disk**).
//
// No other program can name the device or the ring.
//
// **The commands of the block ring** (`src/library/contract/block`), each answered by
// one completion with the same tag:
//
// - `Attach`: take the data region of the client.
// - `Info`: the count of [blocks](term:block) of 4096 bytes, the most
//   blocks of one request (64), and 1 if the disk has a cache for writes.
// - `Read`, `Write`: a run of blocks, between the disk and a place of the
//   data region.
// - `Flush`: the writes before it are on the disk when it completes.
// - `Statistics`: the requests done, the blocks moved, the kernel entries
//   and the interrupts of the service, for a measure.
//
// A refusal gives a status and the values of an
// [error record](term:error-record).
//
// **What a reader sees.** No window: the line `block: ok, <count> blocks of
// 4096 bytes, a queue of <size>, <count> requests in flight at most, flush:
// yes` on the log. A failure at the start writes a line at the level error
// on the channel `block` and stops the service.
//
// **What it does not prove.** It drives virtio under QEMU only, with no
// IOMMU: the device can reach memory beyond the data region, and only the
// code of this service keeps it inside
// (docs/ARCHITECTURE.md, "K5. Device grant and interrupts"). The design of the storage above it is in
// docs/STORAGE.md.
package block_service

import "contract:block"
import "contract:errors"
import op "contract:operation"
import "contract:ring"
import "support:pci"
import "support:system"
import "support:virtio"

FEATURE_FLUSH :: 9 // The device has a cache for writes, and the request Flush.

// A request of the device: a header that the device reads, the data, and a
// status byte that the device writes.
REQUEST_READ :: 0
REQUEST_WRITE :: 1
REQUEST_FLUSH :: 4
SECTOR_SIZE :: 512

Header :: struct {
	kind:     u32,
	reserved: u32,
	sector:   u64,
}

// The memory of the queue (pci.QUEUE_PAGES): pages 0 to 2 the virtqueue,
// page 3 the header and the status of each request.
PAGE_REQUESTS :: virtio.QUEUE_PAGES
STATUS_PLACE :: 2048 // In the page of the requests: the status bytes.
REQUEST_BLOCKS_LIMIT :: 64 // The most blocks of one request: 256 KiB.

// A request in flight: one place, with three descriptors.
Slot :: struct {
	tag:    u32,
	blocks: u64,
	busy:   bool,
	command: block.Command, // For the error record of a refusal of the device.
}

SLOT_CAPACITY :: virtio.QUEUE_SIZE_LIMIT / 3

device: virtio.Device
queue: virtio.Queue
headers: [^]Header
statuses: [^]u8
slots: [SLOT_CAPACITY]Slot
slot_count: u32
in_flight: u32

disk_blocks: u64
has_flush: bool
machine: system.Handle
interrupt: system.Handle
clients: ring.Ring
ring_memory: system.Handle
region_memory: system.Handle
region_physical: u64
region_size: u64

requests_done: u64
blocks_moved: u64
interrupts: u64

fail :: proc "contextless" (text: string) -> ! {
	system.log_in("block", .Error, "block: ", text)
	system.stop(1)
}

// start resets the device, agrees on the features, and gives it the queue.
start :: proc "contextless" (queues: system.Handle) {
	offered, start_error := virtio.start(&device, 1 << FEATURE_FLUSH)
	switch start_error {
	case .None:
	case .No_Version_1:
		fail("the device has no virtio 1 interface")
	case .Features_Refused:
		fail("the device refused the features")
	case .Reset_Not_Done:
		fail("the device did not finish its reset")
	}
	has_flush = offered & (1 << FEATURE_FLUSH) != 0

	// The size of the disk, in sectors of 512 bytes.
	sectors := u64(virtio.load_32(device.device_config)) | u64(virtio.load_32(device.device_config + 4)) << 32
	disk_blocks = sectors / (block.BLOCK_SIZE / SECTOR_SIZE)

	if system.memory_size(queues) < pci.QUEUE_PAGES {
		fail("the memory of the queue is too small")
	}
	address, map_status := system.memory_map(queues, {.Write})
	physical, physical_status := system.memory_physical(machine, queues)
	if map_status != .Ok || physical_status != .Ok {
		fail("no physical address for the queue")
	}
	base := uintptr(address)
	queue_error: virtio.Queue_Error
	queue, queue_error = virtio.queue_start(&device, 0, base, physical, 3, 0)
	switch queue_error {
	case .None:
	case .Too_Small:
		fail("the queue of the device is too small")
	case .No_Vector:
		fail("the device has no message interrupt for its queue")
	}
	headers = ([^]Header)(base + PAGE_REQUESTS * system.PAGE_SIZE)
	statuses = ([^]u8)(base + PAGE_REQUESTS * system.PAGE_SIZE + STATUS_PLACE)
	virtio.ready(&device)

	// Each place of a request has its three descriptors: the header, the
	// data, the status.
	requests := physical + PAGE_REQUESTS * system.PAGE_SIZE
	slot_count = min(queue.size / 3, SLOT_CAPACITY)
	for slot in 0 ..< slot_count {
		first := slot * 3
		queue.descriptors[first] = {address = requests + u64(slot) * size_of(Header), length = size_of(Header), flags = virtio.DESCRIPTOR_NEXT, next = u16(first + 1)}
		queue.descriptors[first + 2] = {address = requests + STATUS_PLACE + u64(slot), length = 1, flags = virtio.DESCRIPTOR_DEVICE_WRITES}
	}
}

complete :: proc "contextless" (tag: u32, status: block.Status, values: [7]u64 = {}) {
	ring.push(&clients.completions, ring.Record{kind = u32(status), tag = tag, values = values})
}

// room says if the completion queue keeps a place for one more completion,
// with the places of the requests in flight.
room :: proc "contextless" () -> bool {
	return ring.count(&clients.completions) + in_flight < ring.capacity(&clients.completions)
}

// attach takes the data region of the client. The handle must have come
// through the block ring. A refusal gives the values of its error record.
attach :: proc "contextless" (handle: system.Handle) -> (block.Status, [7]u64) {
	ATTACH :: u32(block.Command.Attach)
	if in_flight != 0 {
		return .Bad_Command, errors.ring_fail(ATTACH, .Busy, .Requests, 0, i64(in_flight), 0)
	}
	if values, refused := system.region_refusal(handle, ring_memory, ATTACH); refused {
		return .No_Region, values
	}
	physical, status := system.memory_physical(machine, handle)
	if status != .Ok {
		return .No_Region, errors.ring_fail(ATTACH, .Refused, .None, 1, i64(handle), 0, i64(status))
	}
	if region_memory != 0 {
		system.close(region_memory)
	}
	region_memory = handle
	region_physical = physical
	region_size = system.memory_size(handle) * system.PAGE_SIZE
	return .Ok, {}
}

Outcome :: enum {
	Done, // The command has its status: no request goes to the device.
	Sent, // The device has the request.
	Full, // No place is free: the command waits for a completion.
}

// submit gives one request to the device. A refusal gives the values of
// its error record.
submit :: proc "contextless" (command: ring.Record) -> (status: block.Status, outcome: Outcome, values: [7]u64) {
	kind := block.Command(command.kind)
	first, count, offset := command.values[0], command.values[1], command.values[2]
	if kind != .Flush {
		if region_memory == 0 {
			return .No_Region, .Done, errors.ring_fail(command.kind, .Absent, .Region)
		}
		if count == 0 {
			return .Bad_Command, .Done, errors.ring_fail(command.kind, .Too_Small, .Blocks, 2, 0, 1)
		}
		if count > REQUEST_BLOCKS_LIMIT {
			return .Bad_Command, .Done, errors.ring_fail(command.kind, .Too_Long, .Blocks, 2, i64(count), REQUEST_BLOCKS_LIMIT)
		}
		if offset % block.BLOCK_SIZE != 0 {
			return .Bad_Command, .Done, errors.ring_fail(command.kind, .Bad_Value, .Bytes, 3, i64(offset))
		}
		if first >= disk_blocks || count > disk_blocks - first {
			return .Out_Of_Range, .Done, errors.ring_fail(command.kind, .Out_Of_Range, .Blocks, 1, i64(min(first, 1 << 62) + count), i64(disk_blocks))
		}
		if offset > region_size || count * block.BLOCK_SIZE > region_size - offset {
			return .Out_Of_Range, .Done, errors.ring_fail(command.kind, .Out_Of_Range, .Bytes, 3, i64(min(offset, 1 << 62) + count * block.BLOCK_SIZE), i64(region_size))
		}
	} else if !has_flush {
		return .Ok, .Done, {} // The device keeps no write in a cache.
	}
	slot: u32 = SLOT_CAPACITY
	for candidate in 0 ..< slot_count {
		if !slots[candidate].busy {
			slot = candidate
			break
		}
	}
	if slot == SLOT_CAPACITY {
		return .Ok, .Full, {}
	}
	head := slot * 3
	descriptors := queue.descriptors
	switch kind {
	case .Read, .Write:
		headers[slot] = {kind = kind == .Read ? REQUEST_READ : REQUEST_WRITE, sector = first * (block.BLOCK_SIZE / SECTOR_SIZE)}
		descriptors[head].next = u16(head + 1)
		descriptors[head + 1] = {address = region_physical + offset, length = u32(count * block.BLOCK_SIZE), flags = virtio.DESCRIPTOR_NEXT | (kind == .Read ? virtio.DESCRIPTOR_DEVICE_WRITES : 0), next = u16(head + 2)}
	case .Flush:
		headers[slot] = {kind = REQUEST_FLUSH}
		descriptors[head].next = u16(head + 2)
		count = 0
	case .None, .Attach, .Info, .Statistics:
		return .Bad_Command, .Done, errors.ring_fail(command.kind, .Unsupported, .None, 0, i64(command.kind))
	}
	statuses[slot] = 0xFF
	slots[slot] = {tag = command.tag, blocks = count, busy = true, command = kind}
	in_flight += 1
	virtio.give(&queue, u16(head))
	return .Ok, .Sent, {}
}

// harvest gives a completion to the client for each request that the device used.
harvest :: proc "contextless" () -> (count: int) {
	for used in virtio.used(&queue) {
		slot := used.id / 3
		if slot >= slot_count || !slots[slot].busy {
			continue
		}
		status := block.Status.Ok
		values: [7]u64
		switch statuses[slot] {
		case 0:
		case 2:
			status = .Unsupported
			values = errors.ring_fail(u32(slots[slot].command), .Unsupported, .None, 0, i64(slots[slot].command))
		case:
			status = .Device_Error
			values = errors.ring_fail(u32(slots[slot].command), .Device, .None, 0, 0, 0, i64(statuses[slot]))
		}
		complete(slots[slot].tag, status, values)
		requests_done += 1
		blocks_moved += slots[slot].blocks
		slots[slot] = {}
		in_flight -= 1
		count += 1
	}
	return count
}

// entry starts the device and then serves the block ring, until the
// machine stops.
//
// **What it sets up**: the machine handle with the right Physical, the
// message interrupt, the block ring, and the configuration of the device
// that the root service copied. It finds the virtio registers, resets the
// device, agrees on the features (Flush when the device has a cache), and
// gives it the queue (`start`). It then writes `block: ok, ...`.
//
// **The loop.** After each wake:
//
// 1. It gives a completion for each request that the device finished
//    (`harvest`).
// 2. While the completion side of the ring keeps a place, it takes the next
//    command: a command that waited for a place in the queue of the device
//    goes first. `Read`, `Write` and `Flush` go to the device (`submit`);
//    the other commands complete at once. A full queue keeps the command
//    for the next turn.
// 3. It tells the device of the new requests, and wakes the client when a
//    completion came.
// 4. It waits for the interrupt of the device, and for a new command when
//    it has room for one.
//
// **The stop**: with no ring, no configuration, or no virtio registers, it
// writes the reason (`block: no block ring`) at the level error and stops
// with the code 1. Else it never returns.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	machine = ctx.handles[pci.GRANT_MACHINE]
	interrupt = ctx.handles[pci.GRANT_INTERRUPT]
	ring_memory = ctx.handles[block.SERVICE_RING]
	status: system.Status
	if clients, status = system.ring_open(ring_memory); status != .Ok {
		fail("no block ring")
	}
	configuration_address, configuration_status := system.memory_map(ctx.handles[pci.GRANT_CONFIGURATION], {})
	if configuration_status != .Ok {
		fail("no configuration of the device")
	}
	found: bool
	if device, found = virtio.find(ctx, ([^]u8)(configuration_address)[:pci.CONFIGURATION_SIZE]); !found {
		fail("the device has no virtio registers in the memory that it received")
	}
	start(ctx.handles[pci.GRANT_QUEUES])
	system.log("block: ok, ", disk_blocks, " blocks of 4096 bytes, a queue of ", u64(queue.size), ", ", u64(slot_count), " requests in flight at most, flush: ", has_flush ? "yes" : "no")

	waiting: ring.Record
	has_waiting := false // A command that waits for a place in the queue of the device.
	for {
		wait := system.wait_begin() // An interrupt of the device is an event.
		changed := harvest()
		for room() {
			command: ring.Record
			if has_waiting {
				command, has_waiting = waiting, false
			} else {
				ok: bool
				if command, ok = system.receive(&clients.commands); !ok {
					break
				}
			}
			result := block.Status.Ok
			values: [7]u64
			#partial switch block.Command(command.kind) {
			case .Attach:
				result, values = attach(system.Handle(command.values[0]))
			case .Info:
				values = {0 = disk_blocks, 1 = REQUEST_BLOCKS_LIMIT, 2 = u64(has_flush)}
			case .Statistics:
				results, _ := system.call(.Interrupt_Read, u64(interrupt))
				interrupts += results[0]
				values = {0 = requests_done, 1 = blocks_moved, 2 = system.kernel_entries(), 3 = interrupts}
			case .Read, .Write, .Flush:
				outcome: Outcome
				result, outcome, values = submit(command)
				if outcome == .Sent {
					continue
				}
				if outcome == .Full {
					waiting, has_waiting = command, true
				}
			case:
				result = .Bad_Command
				values = errors.ring_fail(command.kind, .Unsupported, .None, 0, i64(command.kind))
			}
			if has_waiting {
				break
			}
			complete(command.tag, result, values)
			changed += 1
		}
		virtio.notify(&queue)
		if changed != 0 {
			system.wake_reader(&clients.completions)
		}
		if virtio.used_ready(&queue) {
			continue
		}
		if room() && !has_waiting {
			system.wait_records(&wait, &clients.commands)
		}
		system.wait_end(&wait)
	}
}

#assert(size_of(Header) == 16)
#assert(SLOT_CAPACITY <= block.RING_CAPACITY)
#assert(op.PAGE_SIZE == block.BLOCK_SIZE)
#assert(PAGE_REQUESTS < pci.QUEUE_PAGES)
