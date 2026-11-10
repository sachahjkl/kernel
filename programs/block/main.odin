// The block service: the device service of one virtio block device (virtio
// 1.x over PCI, the "modern" interface). It serves the block contract
// (contract/block) to one client, through the block ring that the root
// service gives to both.
//
// It has one device and nothing else: the registers of the device, one
// message interrupt, memory for the queue, the machine with the right
// Physical only, and a copy of the configuration of the device. The root
// service found the device, enabled it and set its interrupt
// (support/pci). The kernel has no code for this device (property 7).
//
// The device reads and writes the data region of the client: the kernel is
// not on the path of the data (property 5). The service enters the kernel
// to wait, and to wake its client; one entry serves many requests.
package block_service

import "base:intrinsics"
import "contract:block"
import op "contract:operation"
import "contract:ring"
import "support:pci"
import "support:system"

// The capabilities of a virtio device in its configuration (kind 9).
CAPABILITY_VIRTIO :: 0x09
VIRTIO_COMMON :: 1
VIRTIO_NOTIFY :: 2
VIRTIO_DEVICE :: 4

// The common configuration of a virtio device: offsets in its registers.
COMMON_DEVICE_FEATURE_SELECT :: 0x00
COMMON_DEVICE_FEATURE :: 0x04
COMMON_DRIVER_FEATURE_SELECT :: 0x08
COMMON_DRIVER_FEATURE :: 0x0C
COMMON_CONFIG_VECTOR :: 0x10
COMMON_STATUS :: 0x14
COMMON_QUEUE_SELECT :: 0x16
COMMON_QUEUE_SIZE :: 0x18
COMMON_QUEUE_VECTOR :: 0x1A
COMMON_QUEUE_ENABLE :: 0x1C
COMMON_QUEUE_NOTIFY_OFF :: 0x1E
COMMON_QUEUE_DESCRIPTORS :: 0x20
COMMON_QUEUE_DRIVER :: 0x28
COMMON_QUEUE_DEVICE :: 0x30

STATUS_ACKNOWLEDGE :: 1
STATUS_DRIVER :: 2
STATUS_DRIVER_OK :: 4
STATUS_FEATURES_OK :: 8
STATUS_FAILED :: 128
NO_VECTOR :: 0xFFFF

FEATURE_FLUSH :: 9 // The device has a cache for writes, and the request Flush.
FEATURE_VERSION_1 :: 32

// A request of the device: a header that the device reads, the data, and a
// status byte that the device writes.
REQUEST_READ :: 0
REQUEST_WRITE :: 1
REQUEST_FLUSH :: 4
SECTOR_SIZE :: 512

DESCRIPTOR_NEXT :: 1
DESCRIPTOR_DEVICE_WRITES :: 2

Descriptor :: struct {
	address: u64,
	length:  u32,
	flags:   u16,
	next:    u16,
}

Used :: struct {
	id:     u32,
	length: u32,
}

Header :: struct {
	kind:     u32,
	reserved: u32,
	sector:   u64,
}

QUEUE_SIZE_LIMIT :: 256
// The memory of the queue (pci.QUEUE_PAGES): page 0 the descriptors, page 1
// what the driver gives (avail), page 2 what the device used, page 3 the
// header and the status of each request.
PAGE_DESCRIPTORS :: 0
PAGE_DRIVER :: 1
PAGE_DEVICE :: 2
PAGE_REQUESTS :: 3
STATUS_PLACE :: 2048 // In the page of the requests: the status bytes.
REQUEST_BLOCKS_LIMIT :: 64 // The most blocks of one request: 256 KiB.

// A request in flight: one place, with three descriptors.
Slot :: struct {
	tag:    u32,
	blocks: u64,
	busy:   bool,
}

SLOT_CAPACITY :: QUEUE_SIZE_LIMIT / 3

common: uintptr
device_config: uintptr
notify: uintptr // The register that tells the device that the queue has new requests.
queue_size: u32
descriptors: [^]Descriptor
driver_index: ^u16
driver_ring: [^]u16
device_flags: ^u16
device_index: ^u16
device_ring: [^]Used
headers: [^]Header
statuses: [^]u8
queue_physical: u64
slots: [SLOT_CAPACITY]Slot
slot_count: u32
in_flight: u32
used_seen: u16
given: u16

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

load_32 :: #force_inline proc "contextless" (address: uintptr) -> u32 {
	return intrinsics.volatile_load((^u32)(address))
}

store_32 :: #force_inline proc "contextless" (address: uintptr, value: u32) {
	intrinsics.volatile_store((^u32)(address), value)
}

load_16 :: #force_inline proc "contextless" (address: uintptr) -> u16 {
	return intrinsics.volatile_load((^u16)(address))
}

store_16 :: #force_inline proc "contextless" (address: uintptr, value: u16) {
	intrinsics.volatile_store((^u16)(address), value)
}

store_64 :: #force_inline proc "contextless" (address: uintptr, value: u64) {
	store_32(address, u32(value))
	store_32(address + 4, u32(value >> 32))
}

fail :: proc "contextless" (text: string) -> ! {
	system.log_in("block", .Error, "block: ", text)
	system.stop(1)
}

// find_registers reads the virtio capabilities in the copy of the
// configuration, and maps the BARs that they name.
find_registers :: proc "contextless" (ctx: ^system.Context, configuration: []u8) {
	mapped: [pci.BAR_COUNT]uintptr
	bar_address :: proc "contextless" (ctx: ^system.Context, mapped: ^[pci.BAR_COUNT]uintptr, bar: u8) -> uintptr {
		if bar >= pci.BAR_COUNT {
			return 0
		}
		if mapped[bar] == 0 {
			memory := ctx.handles[pci.GRANT_BAR + int(bar)]
			if memory == 0 {
				return 0
			}
			address, status := system.memory_map(memory, {.Write})
			if status != .Ok {
				return 0
			}
			mapped[bar] = uintptr(address)
		}
		return mapped[bar]
	}
	multiplier: u32
	notify_base: uintptr
	offset := u32(configuration[pci.OFFSET_CAPABILITIES]) &~ 3
	for _ in 0 ..< 48 {
		if offset < 0x40 || offset > pci.CONFIGURATION_SIZE - 20 {
			break
		}
		if configuration[offset] == CAPABILITY_VIRTIO {
			kind := configuration[offset + 3]
			bar := configuration[offset + 4]
			place := intrinsics.unaligned_load((^u32)(&configuration[offset + 8]))
			base := bar_address(ctx, &mapped, bar)
			if base != 0 {
				switch kind {
				case VIRTIO_COMMON:
					common = base + uintptr(place)
				case VIRTIO_NOTIFY:
					notify_base = base + uintptr(place)
					multiplier = intrinsics.unaligned_load((^u32)(&configuration[offset + 16]))
				case VIRTIO_DEVICE:
					device_config = base + uintptr(place)
				}
			}
		}
		offset = u32(configuration[offset + 1]) &~ 3
	}
	if common == 0 || notify_base == 0 || device_config == 0 {
		fail("the device has no virtio registers in the memory that it received")
	}
	store_16(common + COMMON_QUEUE_SELECT, 0)
	notify = notify_base + uintptr(u32(load_16(common + COMMON_QUEUE_NOTIFY_OFF)) * multiplier)
}

// start resets the device, agrees on the features, and gives it the queue.
start :: proc "contextless" (queues: system.Handle) {
	status_write :: proc "contextless" (value: u8) {
		intrinsics.volatile_store((^u8)(common + COMMON_STATUS), value)
	}
	status_read :: proc "contextless" () -> u8 {
		return intrinsics.volatile_load((^u8)(common + COMMON_STATUS))
	}
	status_write(0)
	for status_read() != 0 {
		intrinsics.cpu_relax()
	}
	status_write(STATUS_ACKNOWLEDGE)
	status_write(STATUS_ACKNOWLEDGE | STATUS_DRIVER)
	store_32(common + COMMON_DEVICE_FEATURE_SELECT, 0)
	low := load_32(common + COMMON_DEVICE_FEATURE)
	store_32(common + COMMON_DEVICE_FEATURE_SELECT, 1)
	high := load_32(common + COMMON_DEVICE_FEATURE)
	if high & (1 << (FEATURE_VERSION_1 - 32)) == 0 {
		fail("the device has no virtio 1 interface")
	}
	has_flush = low & (1 << FEATURE_FLUSH) != 0
	store_32(common + COMMON_DRIVER_FEATURE_SELECT, 0)
	store_32(common + COMMON_DRIVER_FEATURE, has_flush ? 1 << FEATURE_FLUSH : 0)
	store_32(common + COMMON_DRIVER_FEATURE_SELECT, 1)
	store_32(common + COMMON_DRIVER_FEATURE, 1 << (FEATURE_VERSION_1 - 32))
	status_write(STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK)
	if status_read() & STATUS_FEATURES_OK == 0 {
		fail("the device refused the features")
	}

	// The size of the disk, in sectors of 512 bytes.
	sectors := u64(load_32(device_config)) | u64(load_32(device_config + 4)) << 32
	disk_blocks = sectors / (block.BLOCK_SIZE / SECTOR_SIZE)

	store_16(common + COMMON_CONFIG_VECTOR, NO_VECTOR)
	store_16(common + COMMON_QUEUE_SELECT, 0)
	queue_size = min(u32(load_16(common + COMMON_QUEUE_SIZE)), QUEUE_SIZE_LIMIT)
	if queue_size < 3 {
		fail("the queue of the device is too small")
	}
	store_16(common + COMMON_QUEUE_SIZE, u16(queue_size))
	store_16(common + COMMON_QUEUE_VECTOR, 0)
	if load_16(common + COMMON_QUEUE_VECTOR) != 0 {
		fail("the device has no message interrupt for its queue")
	}
	if system.memory_size(queues) < pci.QUEUE_PAGES {
		fail("the memory of the queue is too small")
	}
	address, map_status := system.memory_map(queues, {.Write})
	physical, physical_status := system.memory_physical(machine, queues)
	if map_status != .Ok || physical_status != .Ok {
		fail("no physical address for the queue")
	}
	queue_physical = physical
	base := uintptr(address)
	descriptors = ([^]Descriptor)(base + PAGE_DESCRIPTORS * system.PAGE_SIZE)
	driver_index = (^u16)(base + PAGE_DRIVER * system.PAGE_SIZE + 2)
	driver_ring = ([^]u16)(base + PAGE_DRIVER * system.PAGE_SIZE + 4)
	device_flags = (^u16)(base + PAGE_DEVICE * system.PAGE_SIZE)
	device_index = (^u16)(base + PAGE_DEVICE * system.PAGE_SIZE + 2)
	device_ring = ([^]Used)(base + PAGE_DEVICE * system.PAGE_SIZE + 4)
	headers = ([^]Header)(base + PAGE_REQUESTS * system.PAGE_SIZE)
	statuses = ([^]u8)(base + PAGE_REQUESTS * system.PAGE_SIZE + STATUS_PLACE)
	store_64(common + COMMON_QUEUE_DESCRIPTORS, physical + PAGE_DESCRIPTORS * system.PAGE_SIZE)
	store_64(common + COMMON_QUEUE_DRIVER, physical + PAGE_DRIVER * system.PAGE_SIZE)
	store_64(common + COMMON_QUEUE_DEVICE, physical + PAGE_DEVICE * system.PAGE_SIZE)
	store_16(common + COMMON_QUEUE_ENABLE, 1)
	status_write(STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK)

	// Each place of a request has its three descriptors: the header, the
	// data, the status.
	slot_count = min(queue_size / 3, SLOT_CAPACITY)
	for slot in 0 ..< slot_count {
		first := slot * 3
		descriptors[first] = {address = physical + PAGE_REQUESTS * system.PAGE_SIZE + u64(slot) * size_of(Header), length = size_of(Header), flags = DESCRIPTOR_NEXT, next = u16(first + 1)}
		descriptors[first + 2] = {address = physical + PAGE_REQUESTS * system.PAGE_SIZE + STATUS_PLACE + u64(slot), length = 1, flags = DESCRIPTOR_DEVICE_WRITES}
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
// through the block ring.
attach :: proc "contextless" (handle: system.Handle) -> block.Status {
	if in_flight != 0 {
		return .Bad_Command
	}
	kind, rights, through := system.handle_state(handle, ring_memory)
	if kind != .Memory || !through || !(system.Rights{.Read, .Write} <= rights) {
		return .No_Region
	}
	physical, status := system.memory_physical(machine, handle)
	if status != .Ok {
		return .No_Region
	}
	if region_memory != 0 {
		system.close(region_memory)
	}
	region_memory = handle
	region_physical = physical
	region_size = system.memory_size(handle) * system.PAGE_SIZE
	return .Ok
}

Outcome :: enum {
	Done, // The command has its status: no request goes to the device.
	Sent, // The device has the request.
	Full, // No place is free: the command waits for a completion.
}

// submit gives one request to the device.
submit :: proc "contextless" (command: ring.Record) -> (status: block.Status, outcome: Outcome) {
	kind := block.Command(command.kind)
	first, count, offset := command.values[0], command.values[1], command.values[2]
	if kind != .Flush {
		if region_memory == 0 {
			return .No_Region, .Done
		}
		if count == 0 || count > REQUEST_BLOCKS_LIMIT || offset % block.BLOCK_SIZE != 0 {
			return .Bad_Command, .Done
		}
		if first >= disk_blocks || count > disk_blocks - first || offset > region_size || count * block.BLOCK_SIZE > region_size - offset {
			return .Out_Of_Range, .Done
		}
	} else if !has_flush {
		return .Ok, .Done // The device keeps no write in a cache.
	}
	slot: u32 = SLOT_CAPACITY
	for candidate in 0 ..< slot_count {
		if !slots[candidate].busy {
			slot = candidate
			break
		}
	}
	if slot == SLOT_CAPACITY {
		return .Ok, .Full
	}
	head := slot * 3
	switch kind {
	case .Read, .Write:
		headers[slot] = {kind = kind == .Read ? REQUEST_READ : REQUEST_WRITE, sector = first * (block.BLOCK_SIZE / SECTOR_SIZE)}
		descriptors[head].next = u16(head + 1)
		descriptors[head + 1] = {address = region_physical + offset, length = u32(count * block.BLOCK_SIZE), flags = DESCRIPTOR_NEXT | (kind == .Read ? DESCRIPTOR_DEVICE_WRITES : 0), next = u16(head + 2)}
	case .Flush:
		headers[slot] = {kind = REQUEST_FLUSH}
		descriptors[head].next = u16(head + 2)
		count = 0
	case .None, .Attach, .Info, .Statistics:
		return .Bad_Command, .Done
	}
	statuses[slot] = 0xFF
	slots[slot] = {tag = command.tag, blocks = count, busy = true}
	in_flight += 1
	driver_ring[given % u16(queue_size)] = u16(head)
	given += 1
	return .Ok, .Sent
}

// harvest gives a completion to the client for each request that the device used.
harvest :: proc "contextless" () -> (count: int) {
	for {
		index := intrinsics.atomic_load_explicit(device_index, .Acquire)
		if index == used_seen {
			return count
		}
		used := device_ring[used_seen % u16(queue_size)]
		used_seen += 1
		slot := used.id / 3
		if slot >= slot_count || !slots[slot].busy {
			continue
		}
		status := block.Status.Ok
		switch statuses[slot] {
		case 0:
		case 2:
			status = .Unsupported
		case:
			status = .Device_Error
		}
		complete(slots[slot].tag, status)
		requests_done += 1
		blocks_moved += slots[slot].blocks
		slots[slot] = {}
		in_flight -= 1
		count += 1
	}
}

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
	find_registers(ctx, ([^]u8)(configuration_address)[:pci.CONFIGURATION_SIZE])
	start(ctx.handles[pci.GRANT_QUEUES])
	system.log("block: ok, ", disk_blocks, " blocks of 4096 bytes, a queue of ", u64(queue_size), ", ", u64(slot_count), " requests in flight at most, flush: ", has_flush ? "yes" : "no")

	waiting: ring.Record
	has_waiting := false // A command that waits for a place in the queue of the device.
	for {
		wait := system.wait_begin() // An interrupt of the device is an event.
		changed := harvest()
		sent := 0
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
				result = attach(system.Handle(command.values[0]))
			case .Info:
				values = {0 = disk_blocks, 1 = REQUEST_BLOCKS_LIMIT, 2 = u64(has_flush)}
			case .Statistics:
				results, _ := system.call(.Interrupt_Read, u64(interrupt))
				interrupts += results[0]
				values = {0 = requests_done, 1 = blocks_moved, 2 = system.kernel_entries(), 3 = interrupts}
			case .Read, .Write, .Flush:
				outcome: Outcome
				result, outcome = submit(command)
				if outcome == .Sent {
					sent += 1
					continue
				}
				if outcome == .Full {
					waiting, has_waiting = command, true
				}
			case:
				result = .Bad_Command
			}
			if has_waiting {
				break
			}
			complete(command.tag, result, values)
			changed += 1
		}
		if sent != 0 {
			// The device reads the descriptors and the requests before the index.
			intrinsics.atomic_store_explicit(driver_index, given, .Release)
			intrinsics.atomic_thread_fence(.Seq_Cst)
			if intrinsics.volatile_load(device_flags) & 1 == 0 { // The device asks for no notice when this bit is set.
				store_16(notify, 0)
			}
		}
		if changed != 0 {
			system.wake_reader(&clients.completions)
		}
		if harvest_ready() {
			continue
		}
		if room() && !has_waiting {
			system.wait_records(&wait, &clients.commands)
		}
		system.wait_end(&wait)
	}
}

// harvest_ready says if the device used a request since the last harvest:
// then the service does not wait.
harvest_ready :: proc "contextless" () -> bool {
	return intrinsics.atomic_load_explicit(device_index, .Acquire) != used_seen
}

#assert(size_of(Descriptor) == 16)
#assert(size_of(Header) == 16)
#assert(SLOT_CAPACITY <= block.RING_CAPACITY)
#assert(op.PAGE_SIZE == block.BLOCK_SIZE)
