// PCI: the bus of the devices of the first machine. The root service reads
// and writes the configuration of each device through two ports; it holds
// them, and no other program does. It gives a device service exactly one
// device (GRANT_ roles below): the memory of its registers, one message
// interrupt, memory for its queues, and a copy of its configuration.
//
// The device service does not write the configuration: the root service
// enables the device, gives it the right to use memory (bus master), and
// sets its message interrupt (MSI-X) before the start of the service.
package pci

import "support:system"

// The roles of the context of a device service of a PCI device.
GRANT_INTERRUPT :: 1 // A message interrupt (operation.Device_Kind.Message).
GRANT_QUEUES :: 2 // Memory for the queues of the device: the device reads and writes it.
GRANT_MACHINE :: 3 // The machine, with the right Physical only.
GRANT_CONFIGURATION :: 4 // Memory, with Read: one page, the first 256 bytes of the configuration.
GRANT_BAR :: 5 // GRANT_BAR + n: memory, the registers in BAR n. 0: not given.
BAR_COUNT :: 6

CONFIGURATION_SIZE :: 256
QUEUE_PAGES :: 8

PORT_ADDRESS :: 0xCF8
PORT_DATA :: 0xCFC
PORT_COUNT :: 8

// A place on the bus.
Place :: struct {
	bus, device, function: u32,
}

read_32 :: proc "contextless" (place: Place, offset: u32) -> u32 {
	system.port_write_32(PORT_ADDRESS, 1 << 31 | place.bus << 16 | place.device << 11 | place.function << 8 | offset &~ 3)
	return system.port_read_32(PORT_DATA)
}

write_32 :: proc "contextless" (place: Place, offset: u32, value: u32) {
	system.port_write_32(PORT_ADDRESS, 1 << 31 | place.bus << 16 | place.device << 11 | place.function << 8 | offset &~ 3)
	system.port_write_32(PORT_DATA, value)
}

read_16 :: proc "contextless" (place: Place, offset: u32) -> u16 {
	return u16(read_32(place, offset) >> (8 * (offset & 2)))
}

write_16 :: proc "contextless" (place: Place, offset: u32, value: u16) {
	word := read_32(place, offset)
	shift := 8 * (offset & 2)
	write_32(place, offset, word &~ (0xFFFF << shift) | u32(value) << shift)
}

OFFSET_COMMAND :: 0x04
OFFSET_BAR :: 0x10
OFFSET_CAPABILITIES :: 0x34
COMMAND_MEMORY :: 1 << 1
COMMAND_BUS_MASTER :: 1 << 2
COMMAND_NO_LINE_INTERRUPT :: 1 << 10
CAPABILITY_MSI_X :: 0x11

// Bar: the memory of one base address register.
Bar :: struct {
	address: u64,
	size:    u64, // 0: no memory.
}

// bars reads the memory of the six base address registers. A register of
// ports gives no memory. The size comes from the bits that the device keeps
// at 0; the memory of the device is off during the read.
bars :: proc "contextless" (place: Place) -> (result: [BAR_COUNT]Bar) {
	command := read_16(place, OFFSET_COMMAND)
	write_16(place, OFFSET_COMMAND, command &~ COMMAND_MEMORY)
	defer write_16(place, OFFSET_COMMAND, command)
	for index := 0; index < BAR_COUNT; index += 1 {
		offset := u32(OFFSET_BAR + 4 * index)
		low := read_32(place, offset)
		if low & 1 != 0 {
			continue // Ports.
		}
		wide := low >> 1 & 3 == 2
		write_32(place, offset, max(u32))
		mask := u64(read_32(place, offset) &~ 0xF)
		write_32(place, offset, low)
		address := u64(low &~ 0xF)
		if wide && index + 1 < BAR_COUNT {
			high := read_32(place, offset + 4)
			write_32(place, offset + 4, max(u32))
			mask |= u64(read_32(place, offset + 4)) << 32
			write_32(place, offset + 4, high)
			address |= u64(high) << 32
		} else {
			mask |= 0xFFFF_FFFF_0000_0000
		}
		if mask != 0xFFFF_FFFF_0000_0000 && address != 0 {
			result[index] = {address = address, size = ~mask + 1}
		}
		if wide {
			index += 1
		}
	}
	return result
}

// capability gives the offset of the first capability of a kind in a copy
// of the configuration, or 0.
capability :: proc "contextless" (configuration: []u8, kind: u8) -> u32 {
	if len(configuration) < CONFIGURATION_SIZE {
		return 0
	}
	offset := u32(configuration[OFFSET_CAPABILITIES]) &~ 3
	for _ in 0 ..< 48 {
		if offset < 0x40 || offset > CONFIGURATION_SIZE - 4 {
			return 0
		}
		if configuration[offset] == kind {
			return offset
		}
		offset = u32(configuration[offset + 1]) &~ 3
	}
	return 0
}

// The fixed machine (property 7): the tool puts each disk at a place on bus
// 0. The boot volume is at another place: no service receives it.
DATA_DISK_DEVICE :: 0x10 // The disk of the storage service.
SCRATCH_DISK_DEVICE :: 0x11 // A disk for the measures of the block service.
VENDOR_VIRTIO :: 0x1AF4
DEVICE_VIRTIO_BLOCK :: 0x1042 // A virtio 1 block device with no older interface.
