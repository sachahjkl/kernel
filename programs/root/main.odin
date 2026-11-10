// The root service: the first program (docs/ARCHITECTURE.md, U2).
//
// The kernel gives it every handle that exists at boot. It starts the other
// programs, and it gives each one only the handles of its role. It is the
// only program that creates access from nothing.
package root

import "../../display"
import op "../../kernel/operation"
import "../../ring"
import "../../system"

ROOT_MARK :: "root: ok"

// What a program receives, by name. A program that is not here receives a
// ring to the compositor and nothing else.
Grant :: enum {
	Root_Ring, // Start and stop programs.
	Machine, // Inspect the system; stop the machine.
	Image, // Read the boot image.
}

grants_of :: proc "contextless" (name: string) -> bit_set[Grant] {
	switch name {
	case "console":
		return {.Root_Ring, .Machine, .Image}
	case "monitor":
		return {.Machine}
	case "rings":
		return {.Image} // It starts its nodes from the boot image.
	}
	return {}
}

// A program that this service started.
Started :: struct {
	program:         system.Handle, // 0: the slot is free.
	client:          system.Handle, // The ring of the program, as the compositor names it.
	requests:        ^ring.Ring, // The ring from the program to this service, if it has one.
	requests_memory: system.Handle,
	name:            system.Name,
}

STARTED_CAPACITY :: 32

machine: system.Handle
image: []u8
image_memory: system.Handle
started: [STARTED_CAPACITY]Started
compositor: system.Handle
control: ^ring.Ring
control_memory: system.Handle

fail :: proc "contextless" (text: string, status: system.Status) -> ! {
	system.log("root: ", text, ": status ", u64(status))
	system.call(.Machine_Stop, u64(machine), 1)
	system.stop(1)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	machine = ctx.handles[op.ROOT_MACHINE]
	image_memory = ctx.handles[op.ROOT_BOOT_IMAGE]
	address, status := system.memory_map(image_memory, {})
	if status != .Ok {
		fail("cannot map the boot image", status)
	}
	image = ([^]u8)(address)[:ctx.values[op.ROOT_VALUE_BOOT_IMAGE_SIZE]]
	system.log(ROOT_MARK, ", ", u64(len(system.image_entries(image))), " modules in the boot image")

	// The input service: the ports and the interrupts of the PS/2 controller.
	input_memory: system.Handle
	input_memory, _, status = system.ring_create()
	if status != .Ok {
		fail("cannot create a ring", status)
	}
	{
		device :: proc "contextless" (kind: op.Device_Kind, a, b: u64) -> system.Handle {
			results, status := system.call(.Device_Create, u64(machine), u64(kind), a, b)
			if status != .Ok {
				fail("cannot create a device handle", status)
			}
			return system.Handle(results[0])
		}
		handles: [op.CONTEXT_HANDLES]system.Handle
		handles[0] = input_memory
		handles[1] = device(.Ports, 0x60, 5)
		handles[2] = device(.Interrupt, 1, 0)
		handles[3] = device(.Interrupt, 12, 0)
		_, status = system.program_start(system.image_find(image, "input"), "input", handles, {})
		if status != .Ok {
			fail("cannot start input", status)
		}
		for handle in handles[1:4] {
			system.close(handle)
		}
	}

	// The compositor: the framebuffer, the input ring, and a ring to this service.
	control_memory, control, status = system.ring_create()
	if status != .Ok {
		fail("cannot create a ring", status)
	}
	{
		handles: [op.CONTEXT_HANDLES]system.Handle
		handles[0] = ctx.handles[op.ROOT_FRAMEBUFFER]
		handles[1] = input_memory
		handles[2] = control_memory
		values: [op.CONTEXT_VALUES]u64
		values[0] = ctx.values[op.ROOT_VALUE_WIDTH]
		values[1] = ctx.values[op.ROOT_VALUE_HEIGHT]
		values[2] = ctx.values[op.ROOT_VALUE_PIXELS_PER_LINE]
		values[3] = ctx.values[op.ROOT_VALUE_FORMAT]
		compositor, status = system.program_start(system.image_find(image, "compositor"), "compositor", handles, values)
		if status != .Ok {
			fail("cannot start the compositor", status)
		}
	}

	if status = start("console"); status != .Ok {
		fail("cannot start the console", status)
	}

	for {
		// The stop of a program is an event.
		wait := system.wait_begin()
		for record in system.receive(&control.completions) {
			#partial switch display.Control(record.kind) {
			case .Start:
				name := system.name_unpack({record.values[0], record.values[1], record.values[2], record.values[3]})
				start(system.name_of(name[:]))
			case .Stop:
				for &item in started {
					if item.program != 0 && item.client == system.Handle(record.values[0]) {
						system.call(.Program_Stop, u64(item.program), 0)
					}
				}
			}
		}
		for &item in started {
			if item.program == 0 || item.requests == nil {
				continue
			}
			for record in system.receive(&item.requests.commands) {
				name := system.name_unpack({record.values[0], record.values[1], record.values[2], record.values[3]})
				result := system.Status.Bad_Operation
				#partial switch system.Root_Command(record.kind) {
				case .Start:
					result = start(system.name_of(name[:]))
				case .Stop:
					result = .Bad_Handle
					for &other in started {
						if other.program != 0 && system.name_of(other.name[:]) == system.name_of(name[:]) {
							system.call(.Program_Stop, u64(other.program), 0)
							result = .Ok
							break
						}
					}
				}
				system.send(&item.requests.completions, ring.Record{kind = u32(result), tag = record.tag})
			}
		}
		reap()
		system.wait_records(&wait, &control.completions)
		for &item in started {
			if item.program != 0 && item.requests != nil {
				system.wait_records(&wait, &item.requests.commands)
			}
		}
		system.wait_end(&wait)
	}
}

// start starts a program that shows a surface.
start :: proc "contextless" (name: string) -> system.Status {
	file := system.image_find(image, name)
	if len(file) == 0 || name == "root" || name == "input" || name == "compositor" {
		return .Bad_Operation
	}
	slot: ^Started
	for &item in started {
		if item.program == 0 {
			slot = &item
			break
		}
	}
	if slot == nil {
		return .No_Slot
	}
	slot^ = {}

	// The ring between the program and the compositor. This service does not keep it.
	display_memory := system.memory_create(ring.PAGE_COUNT) or_return
	defer system.close(display_memory)
	slot.client = system.give(compositor, display_memory) or_return
	system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Add), values = {0 = u64(slot.client)}})

	handles: [op.CONTEXT_HANDLES]system.Handle
	values: [op.CONTEXT_VALUES]u64
	handles[system.GRANT_DISPLAY] = display_memory
	grants := grants_of(name)
	status := system.Status.Ok
	if .Root_Ring in grants {
		slot.requests_memory, slot.requests, status = system.ring_create()
		handles[system.GRANT_ROOT] = slot.requests_memory
	}
	if .Machine in grants {
		handles[system.GRANT_MACHINE] = machine
	}
	if .Image in grants {
		handles[system.GRANT_IMAGE] = image_memory
		values[system.GRANT_VALUE_IMAGE_SIZE] = u64(len(image))
	}
	if status == .Ok {
		slot.program, status = system.program_start(file, name, handles, values)
	}
	if status != .Ok {
		release(slot)
		return status
	}
	copy(slot.name[:len(slot.name) - 1], name)
	system.log("root: started ", name)
	return .Ok
}

// release frees what this service holds for a program, and tells the compositor.
release :: proc "contextless" (item: ^Started) {
	system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Remove), values = {0 = u64(item.client)}})
	if item.requests != nil {
		system.memory_unmap(item.requests)
		system.close(item.requests_memory)
	}
	if item.program != 0 {
		system.close(item.program)
	}
	item^ = {}
}

// reap finds the programs that stopped.
reap :: proc "contextless" () {
	for &item in started {
		if item.program == 0 {
			continue
		}
		state, code := system.program_state(item.program)
		if state == .Stopped {
			system.log("root: ", system.name_of(item.name[:]), " stopped with code ", u64(code))
			release(&item)
		}
	}
}
