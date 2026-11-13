// Virtio over PCI, the "modern" interface (virtio 1.x): what each device
// service of a virtio device does the same way. The block service
// (programs/block) and the frame service (programs/frame) use it.
//
// A device service has one device (support/pci): the memory of its BARs,
// one message interrupt, memory for its queues, and a copy of its
// configuration. This package reads the virtio capabilities in the copy,
// agrees on the features with the device, and drives split virtqueues in
// the memory of the queues. The kernel has no code for a device: the code
// that knows a device is a program or a library.
//
// A queue takes three pages of the memory of the queues: the descriptors,
// what the driver gives (avail), what the device used. A queue has at most
// QUEUE_SIZE_LIMIT descriptors: its descriptors fill one page.
//
// The order of a start: `find` finds the registers in the copy of the
// configuration; `start` resets the device and agrees on the features;
// `queue_start` gives each queue; `ready` tells the device that the driver
// is ready. The names and the offsets are those of the specification
// "Virtual I/O Device (VIRTIO) Version 1.2", section 4.1.
//
// See [virtio](term:virtio) and [device service](term:device-service).
package virtio

import "base:intrinsics"
import "support:pci"
import "support:system"

// The capabilities of a virtio device in its configuration (kind 9).
CAPABILITY_VIRTIO :: 0x09
CAPABILITY_COMMON :: 1 // The type of the capability of the common configuration.
CAPABILITY_NOTIFY :: 2 // The type of the capability of the notifications.
CAPABILITY_DEVICE :: 4 // The type of the capability of the configuration of the device class.

// The common configuration of a virtio device: offsets in its registers.
COMMON_DEVICE_FEATURE_SELECT :: 0x00 // u32: which word of 32 bits of the device features to read.
COMMON_DEVICE_FEATURE :: 0x04 // u32: that word of the device features.
COMMON_DRIVER_FEATURE_SELECT :: 0x08 // u32: which word of the driver features to write.
COMMON_DRIVER_FEATURE :: 0x0C // u32: that word of the driver features.
COMMON_CONFIG_VECTOR :: 0x10 // u16: the message interrupt of a change of the configuration.
COMMON_STATUS :: 0x14 // u8: the device status.
COMMON_QUEUE_SELECT :: 0x16 // u16: the queue that the next fields name.
COMMON_QUEUE_SIZE :: 0x18 // u16: the descriptors of the queue.
COMMON_QUEUE_VECTOR :: 0x1A // u16: the message interrupt of the queue.
COMMON_QUEUE_ENABLE :: 0x1C // u16: 1 enables the queue.
COMMON_QUEUE_NOTIFY_OFF :: 0x1E // u16: the place of the notify register of the queue, in multipliers.
COMMON_QUEUE_DESCRIPTORS :: 0x20 // u64: the physical address of the descriptors.
COMMON_QUEUE_DRIVER :: 0x28 // u64: the physical address of what the driver gives.
COMMON_QUEUE_DEVICE :: 0x30 // u64: the physical address of what the device used.

// The bits of the device status, set in this order at a start.
STATUS_ACKNOWLEDGE :: 1 // The driver saw the device.
STATUS_DRIVER :: 2 // The driver knows how to drive it.
STATUS_DRIVER_OK :: 4 // The driver is ready: the device can use the queues.
STATUS_FEATURES_OK :: 8 // The driver chose the features; the device keeps the bit when it accepts them.
NO_VECTOR :: 0xFFFF // No message interrupt.

FEATURE_VERSION_1 :: 32 // The bit of the virtio 1 interface, in the second word of the features.

DESCRIPTOR_NEXT :: 1 // The flag of a descriptor that continues in `next`.
DESCRIPTOR_DEVICE_WRITES :: 2 // The flag of a descriptor whose buffer the device writes.

QUEUE_SIZE_LIMIT :: 256 // 256 descriptors of 16 bytes: one page.
QUEUE_PAGES :: 3 // The pages of one queue: descriptors, driver ring, device ring.

// One descriptor of a split virtqueue: one buffer in physical memory.
Descriptor :: struct {
	address: u64, // The physical address of the buffer.
	length:  u32, // Its bytes.
	flags:   u16, // DESCRIPTOR_NEXT, DESCRIPTOR_DEVICE_WRITES.
	next:    u16, // With DESCRIPTOR_NEXT: the next descriptor of the chain.
}
#assert(size_of(Descriptor) == 16)
#assert(QUEUE_SIZE_LIMIT * size_of(Descriptor) == system.PAGE_SIZE)

// One entry of the ring of the device: a chain that the device used.
Used :: struct {
	id:     u32, // The first descriptor of the chain.
	length: u32, // The bytes that the device wrote in its buffers.
}

// The registers of one device, found in its capabilities.
Device :: struct {
	common:        uintptr, // The common configuration, mapped.
	device_config: uintptr, // The configuration of the device class.
	notify_base:   uintptr, // The first notify register.
	multiplier:    u32, // The bytes between the notify registers of two queues, per unit of COMMON_QUEUE_NOTIFY_OFF.
}

// One split virtqueue, as the driver sees it.
Queue :: struct {
	index:        u16, // The number of the queue in its device.
	size:         u32, // The descriptors of the queue, at most QUEUE_SIZE_LIMIT.
	descriptors:  [^]Descriptor, // The table of the descriptors.
	driver_index: ^u16, // The count of chains that the driver gave.
	driver_ring:  [^]u16, // The chains that the driver gave.
	device_flags: ^u16, // The flags of the ring of the device.
	device_index: ^u16, // The count of chains that the device used.
	device_ring:  [^]Used, // The chains that the device used.
	notify:       uintptr, // The register that tells the device that the queue has new requests.
	physical:     u64, // The physical address of the descriptors.
	used_seen:    u16, // The count of used chains that the driver read.
	given:        u16, // The count of chains that the driver gave.
	added:        u16, // Given since the last notice.
}

// The reads and the writes of the registers of a device: volatile, so that
// the compiler keeps each one and its order.
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

load_8 :: #force_inline proc "contextless" (address: uintptr) -> u8 {
	return intrinsics.volatile_load((^u8)(address))
}

store_64 :: #force_inline proc "contextless" (address: uintptr, value: u64) {
	store_32(address, u32(value))
	store_32(address + 4, u32(value >> 32))
}

// find reads the virtio capabilities in the copy of the configuration, and
// maps the BARs that they name (the roles pci.GRANT_BAR + n of the context).
// false: the device has no virtio registers in the memory that it received.
find :: proc "contextless" (ctx: ^system.Context, configuration: []u8) -> (device: Device, ok: bool) {
	if len(configuration) < pci.CONFIGURATION_SIZE {
		return {}, false
	}
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
				case CAPABILITY_COMMON:
					device.common = base + uintptr(place)
				case CAPABILITY_NOTIFY:
					device.notify_base = base + uintptr(place)
					device.multiplier = intrinsics.unaligned_load((^u32)(&configuration[offset + 16]))
				case CAPABILITY_DEVICE:
					device.device_config = base + uintptr(place)
				}
			}
		}
		offset = u32(configuration[offset + 1]) &~ 3
	}
	return device, device.common != 0 && device.notify_base != 0 && device.device_config != 0
}

// status_write writes the device status.
status_write :: proc "contextless" (device: ^Device, value: u8) {
	intrinsics.volatile_store((^u8)(device.common + COMMON_STATUS), value)
}

// status_read reads the device status.
status_read :: proc "contextless" (device: ^Device) -> u8 {
	return intrinsics.volatile_load((^u8)(device.common + COMMON_STATUS))
}

// Why `start` failed.
Start_Error :: enum {
	None, // The device accepted the features.
	No_Version_1, // The device has no virtio 1 interface.
	Features_Refused, // The device did not accept the features.
}

// start resets the device and agrees on the features: the driver takes the
// bits of `wanted` (the first word of the features) that the device offers,
// and always the virtio 1 interface. offered is the first word of the
// features of the device. The queues come next (queue_start), then ready.
start :: proc "contextless" (device: ^Device, wanted: u32) -> (offered: u32, error: Start_Error) {
	status_write(device, 0)
	for status_read(device) != 0 {
		intrinsics.cpu_relax()
	}
	status_write(device, STATUS_ACKNOWLEDGE)
	status_write(device, STATUS_ACKNOWLEDGE | STATUS_DRIVER)
	store_32(device.common + COMMON_DEVICE_FEATURE_SELECT, 0)
	offered = load_32(device.common + COMMON_DEVICE_FEATURE)
	store_32(device.common + COMMON_DEVICE_FEATURE_SELECT, 1)
	high := load_32(device.common + COMMON_DEVICE_FEATURE)
	if high & (1 << (FEATURE_VERSION_1 - 32)) == 0 {
		return offered, .No_Version_1
	}
	store_32(device.common + COMMON_DRIVER_FEATURE_SELECT, 0)
	store_32(device.common + COMMON_DRIVER_FEATURE, offered & wanted)
	store_32(device.common + COMMON_DRIVER_FEATURE_SELECT, 1)
	store_32(device.common + COMMON_DRIVER_FEATURE, 1 << (FEATURE_VERSION_1 - 32))
	status_write(device, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK)
	if status_read(device) & STATUS_FEATURES_OK == 0 {
		return offered, .Features_Refused
	}
	store_16(device.common + COMMON_CONFIG_VECTOR, NO_VECTOR)
	return offered, .None
}

// Why `queue_start` failed.
Queue_Error :: enum {
	None, // The queue runs.
	Too_Small, // The queue of the device has fewer than `least` descriptors.
	No_Vector, // The device has no message interrupt for the queue.
}

// queue_start gives the device the queue `index`, in three pages of the
// memory of the queues: base is their address in this program, physical
// their physical address. The queue sends the message interrupt `vector`.
queue_start :: proc "contextless" (device: ^Device, index: u16, base: uintptr, physical: u64, least: u32, vector: u16) -> (queue: Queue, error: Queue_Error) {
	store_16(device.common + COMMON_QUEUE_SELECT, index)
	queue.size = min(u32(load_16(device.common + COMMON_QUEUE_SIZE)), QUEUE_SIZE_LIMIT)
	if queue.size < least {
		return {}, .Too_Small
	}
	store_16(device.common + COMMON_QUEUE_SIZE, u16(queue.size))
	store_16(device.common + COMMON_QUEUE_VECTOR, vector)
	if load_16(device.common + COMMON_QUEUE_VECTOR) != vector {
		return {}, .No_Vector
	}
	queue.notify = device.notify_base + uintptr(u32(load_16(device.common + COMMON_QUEUE_NOTIFY_OFF)) * device.multiplier)
	queue.descriptors = ([^]Descriptor)(base)
	queue.driver_index = (^u16)(base + system.PAGE_SIZE + 2)
	queue.driver_ring = ([^]u16)(base + system.PAGE_SIZE + 4)
	queue.device_flags = (^u16)(base + 2 * system.PAGE_SIZE)
	queue.device_index = (^u16)(base + 2 * system.PAGE_SIZE + 2)
	queue.device_ring = ([^]Used)(base + 2 * system.PAGE_SIZE + 4)
	queue.physical = physical
	queue.index = index
	store_64(device.common + COMMON_QUEUE_DESCRIPTORS, physical)
	store_64(device.common + COMMON_QUEUE_DRIVER, physical + system.PAGE_SIZE)
	store_64(device.common + COMMON_QUEUE_DEVICE, physical + 2 * system.PAGE_SIZE)
	store_16(device.common + COMMON_QUEUE_ENABLE, 1)
	return queue, .None
}

// ready tells the device that the driver is ready: the device starts.
ready :: proc "contextless" (device: ^Device) {
	status_write(device, STATUS_ACKNOWLEDGE | STATUS_DRIVER | STATUS_FEATURES_OK | STATUS_DRIVER_OK)
}

// give puts the chain of descriptors that starts at head in what the driver
// gives. The device sees it after notify.
give :: proc "contextless" (queue: ^Queue, head: u16) {
	queue.driver_ring[queue.given % u16(queue.size)] = head
	queue.given += 1
	queue.added += 1
}

// notify makes the chains that give added visible to the device, and tells
// the device unless it asked for no notice.
notify :: proc "contextless" (queue: ^Queue) {
	if queue.added == 0 {
		return
	}
	queue.added = 0
	// The device reads the descriptors and the requests before the index.
	intrinsics.atomic_store_explicit(queue.driver_index, queue.given, .Release)
	intrinsics.atomic_thread_fence(.Seq_Cst)
	if intrinsics.volatile_load(queue.device_flags) & 1 == 0 { // The device asks for no notice when this bit is set.
		store_16(queue.notify, queue.index) // The notice is the number of the queue (virtio 1.x, 4.1.5.2).
	}
}

// used gives the next chain that the device used, if one.
used :: proc "contextless" (queue: ^Queue) -> (item: Used, ok: bool) {
	index := intrinsics.atomic_load_explicit(queue.device_index, .Acquire)
	if index == queue.used_seen {
		return {}, false
	}
	item = queue.device_ring[queue.used_seen % u16(queue.size)]
	queue.used_seen += 1
	return item, true
}

// used_ready says if the device used a chain that `used` did not give yet.
used_ready :: proc "contextless" (queue: ^Queue) -> bool {
	return intrinsics.atomic_load_explicit(queue.device_index, .Acquire) != queue.used_seen
}
