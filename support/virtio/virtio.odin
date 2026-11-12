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
package virtio

import "base:intrinsics"
import "support:pci"
import "support:system"

// The capabilities of a virtio device in its configuration (kind 9).
CAPABILITY_VIRTIO :: 0x09
CAPABILITY_COMMON :: 1
CAPABILITY_NOTIFY :: 2
CAPABILITY_DEVICE :: 4

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
NO_VECTOR :: 0xFFFF

FEATURE_VERSION_1 :: 32 // The bit of the virtio 1 interface, in the second word of the features.

DESCRIPTOR_NEXT :: 1
DESCRIPTOR_DEVICE_WRITES :: 2

QUEUE_SIZE_LIMIT :: 256 // 256 descriptors of 16 bytes: one page.
QUEUE_PAGES :: 3

Descriptor :: struct {
	address: u64,
	length:  u32,
	flags:   u16,
	next:    u16,
}
#assert(size_of(Descriptor) == 16)
#assert(QUEUE_SIZE_LIMIT * size_of(Descriptor) == system.PAGE_SIZE)

Used :: struct {
	id:     u32,
	length: u32,
}

// The registers of one device, found in its capabilities.
Device :: struct {
	common:        uintptr,
	device_config: uintptr, // The configuration of the device class.
	notify_base:   uintptr,
	multiplier:    u32,
}

// One split virtqueue, as the driver sees it.
Queue :: struct {
	index:        u16, // The number of the queue in its device.
	size:         u32,
	descriptors:  [^]Descriptor,
	driver_index: ^u16,
	driver_ring:  [^]u16,
	device_flags: ^u16,
	device_index: ^u16,
	device_ring:  [^]Used,
	notify:       uintptr, // The register that tells the device that the queue has new requests.
	physical:     u64, // The physical address of the descriptors.
	used_seen:    u16,
	given:        u16,
	added:        u16, // Given since the last notice.
}

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

status_write :: proc "contextless" (device: ^Device, value: u8) {
	intrinsics.volatile_store((^u8)(device.common + COMMON_STATUS), value)
}

status_read :: proc "contextless" (device: ^Device) -> u8 {
	return intrinsics.volatile_load((^u8)(device.common + COMMON_STATUS))
}

Start_Error :: enum {
	None,
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

Queue_Error :: enum {
	None,
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
