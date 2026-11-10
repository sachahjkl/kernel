package root

import "contract:block"
import "contract:frame"
import op "contract:operation"
import "contract:ring"
import "support:pci"
import "support:system"

// The devices of the bus. This service holds the two ports of the
// configuration of all devices: no other program has them. It gives a
// device service one device, and it takes the device back when the service
// stops.

configuration_ports: system.Handle

device_handle :: proc "contextless" (kind: op.Device_Kind, a, b: u64) -> (handle: system.Handle, values: [7]u64, status: system.Status) {
	values, status = system.call(.Device_Create, u64(machine), u64(kind), a, b)
	return system.Handle(values[0]), values, status
}

// A device service, by the class of its device: the program, and the ring
// that it serves to its one client.
Driver :: struct {
	name:          string,
	device:        u32, // The device number of the class on the bus (support/pci).
	ring_capacity: u32,
	ring_role:     int, // The role of the ring in the context of the device service.
}

DRIVER_BLOCK :: Driver{"block", pci.DEVICE_VIRTIO_BLOCK, block.RING_CAPACITY, block.SERVICE_RING}
DRIVER_FRAME :: Driver{"frame", pci.DEVICE_VIRTIO_NETWORK, frame.RING_CAPACITY, frame.SERVICE_RING}

// driver_start starts the device service of the device at a place of bus 0.
// It gives the ring of the device service: this service gives it to the
// client.
driver_start :: proc "contextless" (device_number: u32, kind: Driver = DRIVER_BLOCK) -> (driver: ^Started, ring_memory: system.Handle, status: system.Status) {
	if configuration_ports == 0 {
		configuration_ports, _, status = device_handle(.Ports, pci.PORT_ADDRESS, pci.PORT_COUNT)
		if status != .Ok {
			return nil, 0, status
		}
	}
	place := pci.Place{bus = 0, device = device_number}
	identity := pci.read_32(place, 0)
	if identity & 0xFFFF != pci.VENDOR_VIRTIO || identity >> 16 != kind.device {
		system.log_in("devices", .Error, "root: no virtio device for ", kind.name, " at the place ", u64(device_number), " of the bus")
		return nil, 0, .Bad_Handle
	}
	for &item in started {
		if item.program != 0 && item.is_driver && item.device == place {
			return nil, 0, .Bad_State // One service for one device.
		}
	}
	for &item in started {
		if item.program == 0 {
			driver = &item
			break
		}
	}
	if driver == nil {
		return nil, 0, .No_Slot
	}
	driver^ = {}

	// What this service creates here and does not keep.
	made: [2 + pci.BAR_COUNT]system.Handle
	defer for handle in made {
		if handle != 0 {
			system.close(handle)
		}
	}
	grants: [op.CONTEXT_HANDLES]system.Grant
	grants[op.CONTEXT_LOG] = log_grant(kind.name)
	grants[pci.GRANT_MACHINE] = {machine, {.Physical}}

	// The device: no line interrupt, its memory, and its message interrupt.
	command := pci.read_16(place, pci.OFFSET_COMMAND)
	pci.write_16(place, pci.OFFSET_COMMAND, command &~ pci.COMMAND_BUS_MASTER | pci.COMMAND_MEMORY | pci.COMMAND_NO_LINE_INTERRUPT)
	bars := pci.bars(place)
	configuration: [pci.CONFIGURATION_SIZE / 4]u32
	for &word, index in configuration {
		word = pci.read_32(place, u32(index * 4))
	}
	bytes := transmute([pci.CONFIGURATION_SIZE]u8)configuration
	table := pci.capability(bytes[:], pci.CAPABILITY_MSI_X)
	if table == 0 {
		return nil, 0, .Bad_Operation
	}
	table_place := configuration[(table + 4) / 4]
	pending_place := configuration[(table + 8) / 4]
	table_bar := table_place & 7
	if table_bar >= pci.BAR_COUNT || bars[table_bar].size == 0 {
		return nil, 0, .Bad_Operation
	}
	interrupt: system.Handle
	message: [7]u64
	interrupt, message, status = device_handle(.Message, 0, 0)
	if status != .Ok {
		return nil, 0, status
	}
	made[0] = interrupt
	grants[pci.GRANT_INTERRUPT] = {interrupt, {.Read}}
	{
		// Entry 0 of the table of the device: the address, the value, not masked.
		page := (bars[table_bar].address + u64(table_place &~ 7)) &~ (system.PAGE_SIZE - 1)
		registers, _ := device_handle(.Memory, page, 1) or_return
		defer system.close(registers)
		address := system.memory_map(registers, {.Write}) or_return
		entry := ([^]u32)(uintptr(address) + uintptr((u64(table_place &~ 7)) & (system.PAGE_SIZE - 1)))
		entry[0] = u32(message[1])
		entry[1] = u32(message[1] >> 32)
		entry[2] = u32(message[2])
		entry[3] = 0
		system.memory_unmap(address)
	}
	control := pci.read_16(place, table + 2)
	pci.write_16(place, table + 2, control &~ (1 << 14) | 1 << 15) // Enabled, not masked.
	pci.write_16(place, pci.OFFSET_COMMAND, command | pci.COMMAND_MEMORY | pci.COMMAND_BUS_MASTER | pci.COMMAND_NO_LINE_INTERRUPT)

	// The memory of each BAR, except the BARs of the table of the
	// interrupts: the device service does not change its interrupt.
	for bar, index in bars {
		if bar.size == 0 || u32(index) == table_bar || u32(index) == pending_place & 7 {
			continue
		}
		memory: system.Handle
		memory, _, status = device_handle(.Memory, bar.address, (bar.size + system.PAGE_SIZE - 1) / system.PAGE_SIZE)
		if status != .Ok {
			return nil, 0, status
		}
		made[2 + index] = memory
		grants[pci.GRANT_BAR + index] = {memory, {.Read, .Write}}
	}
	copied := system.memory_create(1) or_return
	made[1] = copied
	{
		address := system.memory_map(copied, {.Write}) or_return
		([^][pci.CONFIGURATION_SIZE]u8)(address)[0] = bytes
		system.memory_unmap(address)
	}
	grants[pci.GRANT_CONFIGURATION] = {copied, {.Read}}
	// The queues: this service keeps the memory until the device stops
	// using it (driver_end).
	driver.queues = system.memory_create(pci.QUEUE_PAGES, 0, {.Contiguous}) or_return // The device reads and writes it.
	grants[pci.GRANT_QUEUES] = {driver.queues, {.Read, .Write}}
	ring_memory, status = system.memory_create(ring.pages(kind.ring_capacity))
	if status == .Ok {
		grants[kind.ring_role] = {ring_memory, {.Read, .Write}}
		driver.program, status = system.program_start(system.image_find(image, kind.name), kind.name, grants, {}, budget_of(kind.name))
	}
	if status != .Ok {
		pci.write_16(place, pci.OFFSET_COMMAND, command &~ pci.COMMAND_BUS_MASTER)
		system.close(driver.queues)
		if ring_memory != 0 {
			system.close(ring_memory)
		}
		driver^ = {}
		return nil, 0, status
	}
	driver.is_driver = true
	driver.device = place
	driver.granted = {.Log}
	copy(driver.name[:len(driver.name) - 1], kind.name)
	system.log_in("devices", .Info, "root: started ", kind.name, " for the device at the place ", u64(device_number), " of the bus")
	return driver, ring_memory, .Ok
}

// driver_end takes the device back from a block service that stopped: the
// device does not use memory after this, and the memory of its queue can
// return to the budget.
driver_end :: proc "contextless" (driver: ^Started) {
	command := pci.read_16(driver.device, pci.OFFSET_COMMAND)
	pci.write_16(driver.device, pci.OFFSET_COMMAND, command &~ pci.COMMAND_BUS_MASTER)
	system.close(driver.queues)
}
