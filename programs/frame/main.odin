// The frame service: the device service of one virtio network device
// (virtio 1.x over PCI, the "modern" interface). It serves the frame
// contract (contract/frame) to one client, through the frame ring that the
// root service gives to both.
//
// It has one device and nothing else: the registers of the device, one
// message interrupt, memory for the queues, the machine with the right
// Physical only, and a copy of the configuration of the device. The root
// service found the device, enabled it and set its interrupt. The kernel has
// no code for this device (property 7); the code of virtio that the block
// service also uses is in support/virtio.
//
// The device reads and writes the frame region of the client: the kernel is
// not on the path of the data (property 5). This service does not read a
// frame: the client builds and checks each one.
package frame_service

import "contract:frame"
import "contract:ring"
import "support:pci"
import "support:system"
import "support:virtio"

// The features of a virtio network device that this service takes.
FEATURE_MAC :: 5 // The configuration has the hardware address.
FEATURE_STATUS :: 16 // The configuration has the state of the link.

// The header of each frame in a virtio network queue, with the virtio 1
// interface and no merged buffers: 12 bytes. This service sends no offload:
// the header of a sent frame is all zero.
HEADER_SIZE :: 12

// The memory of the queues (pci.QUEUE_PAGES): pages 0 to 2 the receive
// queue (virtqueue 0), pages 3 to 5 the send queue (virtqueue 1), page 6 the
// header of each Receive, and one header for each Send.
PAGE_RECEIVE :: 0
PAGE_SEND :: virtio.QUEUE_PAGES
PAGE_HEADERS :: 2 * virtio.QUEUE_PAGES
SEND_HEADER_PLACE :: 2048 // In the page of the headers.

SLOT_CAPACITY :: virtio.QUEUE_SIZE_LIMIT / 2 // Two descriptors for each request.

// A request in flight.
Slot :: struct {
	tag:  u32,
	busy: bool,
}

device: virtio.Device
receive_queue: virtio.Queue
send_queue: virtio.Queue
receive_slots: [SLOT_CAPACITY]Slot
send_slots: [SLOT_CAPACITY]Slot
receive_slot_count: u32
send_slot_count: u32
in_flight: u32 // Receive and Send.
headers_physical: u64

hardware_address: u64
has_status: bool
machine: system.Handle
interrupt: system.Handle
clients: ring.Ring
ring_memory: system.Handle
region_memory: system.Handle
region_physical: u64
region_size: u64

frames_sent: u64
frames_received: u64
bytes_sent: u64
bytes_received: u64
interrupts: u64

fail :: proc "contextless" (text: string) -> ! {
	system.log_in("frame", .Error, "frame: ", text)
	system.stop(1)
}

// start resets the device, agrees on the features, and gives it the queues.
start :: proc "contextless" (queues: system.Handle) {
	offered, start_error := virtio.start(&device, 1 << FEATURE_MAC | 1 << FEATURE_STATUS)
	switch start_error {
	case .None:
	case .No_Version_1:
		fail("the device has no virtio 1 interface")
	case .Features_Refused:
		fail("the device refused the features")
	}
	if offered & (1 << FEATURE_MAC) != 0 {
		for index in 0 ..< 6 {
			hardware_address |= u64(virtio.load_8(device.device_config + uintptr(index))) << (8 * uint(index))
		}
	}
	has_status = offered & (1 << FEATURE_STATUS) != 0

	if system.memory_size(queues) < pci.QUEUE_PAGES {
		fail("the memory of the queues is too small")
	}
	address, map_status := system.memory_map(queues, {.Write})
	physical, physical_status := system.memory_physical(machine, queues)
	if map_status != .Ok || physical_status != .Ok {
		fail("no physical address for the queues")
	}
	base := uintptr(address)
	errors: [2]virtio.Queue_Error
	receive_queue, errors[0] = virtio.queue_start(&device, 0, base + PAGE_RECEIVE * system.PAGE_SIZE, physical + PAGE_RECEIVE * system.PAGE_SIZE, 2, 0)
	send_queue, errors[1] = virtio.queue_start(&device, 1, base + PAGE_SEND * system.PAGE_SIZE, physical + PAGE_SEND * system.PAGE_SIZE, 2, 0)
	for error in errors {
		switch error {
		case .None:
		case .Too_Small:
			fail("a queue of the device is too small")
		case .No_Vector:
			fail("the device has no message interrupt for its queues")
		}
	}
	headers_physical = physical + PAGE_HEADERS * system.PAGE_SIZE
	virtio.ready(&device)

	// Each place of a request has its two descriptors: the header, the frame.
	receive_slot_count = min(receive_queue.size / 2, SLOT_CAPACITY)
	for slot in 0 ..< receive_slot_count {
		first := slot * 2
		receive_queue.descriptors[first] = {address = headers_physical + u64(slot) * HEADER_SIZE, length = HEADER_SIZE, flags = virtio.DESCRIPTOR_NEXT | virtio.DESCRIPTOR_DEVICE_WRITES, next = u16(first + 1)}
	}
	send_slot_count = min(send_queue.size / 2, SLOT_CAPACITY)
	for slot in 0 ..< send_slot_count {
		first := slot * 2
		send_queue.descriptors[first] = {address = headers_physical + SEND_HEADER_PLACE, length = HEADER_SIZE, flags = virtio.DESCRIPTOR_NEXT, next = u16(first + 1)}
	}
}

link_up :: proc "contextless" () -> bool {
	return !has_status || virtio.load_16(device.device_config + 6) & 1 != 0
}

complete :: proc "contextless" (tag: u32, status: frame.Status, values: [7]u64 = {}) {
	ring.push(&clients.completions, ring.Record{kind = u32(status), tag = tag, values = values})
}

// room says if the completion queue keeps a place for one more completion,
// with the places of the requests in flight.
room :: proc "contextless" () -> bool {
	return ring.count(&clients.completions) + in_flight < ring.capacity(&clients.completions)
}

// attach takes the frame region of the client. The handle must have come
// through the frame ring.
attach :: proc "contextless" (handle: system.Handle) -> frame.Status {
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
submit :: proc "contextless" (command: ring.Record) -> (status: frame.Status, outcome: Outcome) {
	kind := frame.Command(command.kind)
	place, count := command.values[0], command.values[1]
	if region_memory == 0 {
		return .No_Region, .Done
	}
	if place > region_size || count > region_size - place {
		return .Out_Of_Range, .Done
	}
	if kind == .Send {
		if count < 14 || count > frame.FRAME_LIMIT {
			return .Too_Large, .Done
		}
		slot: u32 = SLOT_CAPACITY
		for candidate in 0 ..< send_slot_count {
			if !send_slots[candidate].busy {
				slot = candidate
				break
			}
		}
		if slot == SLOT_CAPACITY {
			return .Ok, .Full
		}
		head := slot * 2
		send_queue.descriptors[head + 1] = {address = region_physical + place, length = u32(count)}
		send_slots[slot] = {tag = command.tag, busy = true}
		in_flight += 1
		bytes_sent += count
		virtio.give(&send_queue, u16(head))
		return .Ok, .Sent
	}
	// A Receive: room for a header of Ethernet at least.
	if count < 14 || count > 1 << 16 {
		return .Bad_Command, .Done
	}
	slot: u32 = SLOT_CAPACITY
	for candidate in 0 ..< receive_slot_count {
		if !receive_slots[candidate].busy {
			slot = candidate
			break
		}
	}
	if slot == SLOT_CAPACITY {
		return .Too_Many, .Done
	}
	head := slot * 2
	receive_queue.descriptors[head + 1] = {address = region_physical + place, length = u32(count), flags = virtio.DESCRIPTOR_DEVICE_WRITES}
	receive_slots[slot] = {tag = command.tag, busy = true}
	in_flight += 1
	virtio.give(&receive_queue, u16(head))
	return .Ok, .Sent
}

// harvest gives a completion to the client for each request that the device used.
harvest :: proc "contextless" () -> (count: int) {
	for used in virtio.used(&send_queue) {
		slot := used.id / 2
		if slot >= send_slot_count || !send_slots[slot].busy {
			continue
		}
		complete(send_slots[slot].tag, .Ok)
		frames_sent += 1
		send_slots[slot] = {}
		in_flight -= 1
		count += 1
	}
	for used in virtio.used(&receive_queue) {
		slot := used.id / 2
		if slot >= receive_slot_count || !receive_slots[slot].busy {
			continue
		}
		if used.length < HEADER_SIZE {
			complete(receive_slots[slot].tag, .Device_Error)
		} else {
			length := u64(used.length) - HEADER_SIZE
			complete(receive_slots[slot].tag, .Ok, {0 = length})
			frames_received += 1
			bytes_received += length
		}
		receive_slots[slot] = {}
		in_flight -= 1
		count += 1
	}
	return count
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	machine = ctx.handles[pci.GRANT_MACHINE]
	interrupt = ctx.handles[pci.GRANT_INTERRUPT]
	ring_memory = ctx.handles[frame.SERVICE_RING]
	status: system.Status
	if clients, status = system.ring_open(ring_memory); status != .Ok {
		fail("no frame ring")
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
	text: [24]u8
	system.log("frame: ok, the hardware address ", hardware_text(text[:]), ", the link is ", link_up() ? "up" : "down", ", queues of ", u64(receive_queue.size), " and ", u64(send_queue.size), ", ", u64(receive_slot_count), " places for frames that arrive")

	waiting: ring.Record
	has_waiting := false // A Send that waits for a place in the queue of the device.
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
			result := frame.Status.Ok
			values: [7]u64
			#partial switch frame.Command(command.kind) {
			case .Attach:
				result = attach(system.Handle(command.values[0]))
			case .Info:
				values = {0 = hardware_address, 1 = u64(link_up()), 2 = frame.FRAME_LIMIT, 3 = u64(receive_slot_count), 4 = u64(send_slot_count)}
			case .Statistics:
				results, _ := system.call(.Interrupt_Read, u64(interrupt))
				interrupts += results[0]
				values = {0 = frames_sent, 1 = frames_received, 2 = system.kernel_entries(), 3 = interrupts, 4 = bytes_sent, 5 = bytes_received}
			case .Send, .Receive:
				outcome: Outcome
				result, outcome = submit(command)
				if outcome == .Sent {
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
		virtio.notify(&receive_queue)
		virtio.notify(&send_queue)
		if changed != 0 {
			system.wake_reader(&clients.completions)
		}
		if virtio.used_ready(&send_queue) || virtio.used_ready(&receive_queue) {
			continue
		}
		if room() && !has_waiting {
			system.wait_records(&wait, &clients.commands)
		}
		system.wait_end(&wait)
	}
}

// hardware_text writes a hardware address as six hexadecimal pairs.
hardware_text :: proc "contextless" (buffer: []u8) -> string {
	digits := "0123456789abcdef"
	count := 0
	for index in 0 ..< 6 {
		byte := u8(hardware_address >> (8 * uint(index)))
		if index != 0 {
			buffer[count] = ':'
			count += 1
		}
		buffer[count] = digits[byte >> 4]
		buffer[count + 1] = digits[byte & 15]
		count += 2
	}
	return string(buffer[:count])
}

#assert(SLOT_CAPACITY * HEADER_SIZE <= SEND_HEADER_PLACE)
#assert(PAGE_HEADERS < pci.QUEUE_PAGES)
#assert(2 * SLOT_CAPACITY <= frame.RING_CAPACITY)
