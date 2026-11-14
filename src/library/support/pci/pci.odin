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
BAR_COUNT :: 6 // The base address registers of a device of type 0.

CONFIGURATION_SIZE :: 256 // The bytes of the configuration of a device that the copy holds: the space of PCI before PCI Express.
QUEUE_PAGES :: 8 // The pages of the memory of the queues that the root service gives a device service.

PORT_ADDRESS :: 0xCF8 // The port of the address of the configuration (mechanism 1).
PORT_DATA :: 0xCFC // The port of the data of the configuration.
PORT_COUNT :: 8 // The ports from PORT_ADDRESS that the root service holds: 0xCF8 to 0xCFF.

// A place on the bus.
Place :: struct {
	bus, device, function: u32, // Bus 0 to 255, device 0 to 31, function 0 to 7.
}

// read_32 reads a word of the configuration of a device, through the two
// ports. The offset is aligned down on 4. Only the holder of the ports, the
// root service, calls it.
read_32 :: proc "contextless" (place: Place, offset: u32) -> u32 {
	system.port_write_32(PORT_ADDRESS, 1 << 31 | place.bus << 16 | place.device << 11 | place.function << 8 | offset &~ 3)
	return system.port_read_32(PORT_DATA)
}

// write_32 writes a word of the configuration of a device.
write_32 :: proc "contextless" (place: Place, offset: u32, value: u32) {
	system.port_write_32(PORT_ADDRESS, 1 << 31 | place.bus << 16 | place.device << 11 | place.function << 8 | offset &~ 3)
	system.port_write_32(PORT_DATA, value)
}

// read_16 reads 16 bits of the configuration, at an offset aligned on 2.
read_16 :: proc "contextless" (place: Place, offset: u32) -> u16 {
	return u16(read_32(place, offset) >> (8 * (offset & 2)))
}

// write_16 writes 16 bits of the configuration: it reads the word, changes
// its half, and writes it back.
write_16 :: proc "contextless" (place: Place, offset: u32, value: u16) {
	word := read_32(place, offset)
	shift := 8 * (offset & 2)
	write_32(place, offset, word &~ (0xFFFF << shift) | u32(value) << shift)
}

OFFSET_COMMAND :: 0x04 // The command register.
OFFSET_BAR :: 0x10 // The first base address register.
OFFSET_CAPABILITIES :: 0x34 // The pointer to the first capability.
COMMAND_MEMORY :: 1 << 1 // The device answers its memory.
COMMAND_BUS_MASTER :: 1 << 2 // The device can read and write memory: its queues.
COMMAND_NO_LINE_INTERRUPT :: 1 << 10 // The device sends no interrupt of a line: it uses message interrupts.
CAPABILITY_MSI_X :: 0x11 // The identifier of the capability MSI-X.

// Bar: the memory of one base address register.
Bar :: struct {
	address: u64, // The physical address of the registers.
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

// The fixed machine: the system targets one fixed machine at a time, so the
// places of its devices are constants. The tool puts each disk at a place on bus
// 0. The boot volume is at another place: no service receives it.
DATA_DISK_DEVICE :: 0x10 // The disk of the storage service.
SCRATCH_DISK_DEVICE :: 0x11 // A disk for the measures of the block service.
NETWORK_DEVICE :: 0x12 // The network device of the frame service.
VENDOR_VIRTIO :: 0x1AF4 // The vendor identifier of the virtio devices.
DEVICE_VIRTIO_BLOCK :: 0x1042 // A virtio 1 block device with no older interface.
DEVICE_VIRTIO_NETWORK :: 0x1041 // A virtio 1 network device with no older interface.
