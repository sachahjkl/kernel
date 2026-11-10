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
	Inspect, // The machine, with the right Inspect.
	Stop, // The machine, with the right Stop.
	Image, // Read the boot image.
}

grants_of :: proc "contextless" (name: string) -> bit_set[Grant] {
	switch name {
	case "console":
		return {.Root_Ring, .Inspect, .Stop, .Image}
	case "monitor":
		return {.Inspect}
	case "rights":
		return {.Inspect, .Image} // It shows what the kernel refuses.
	case "rings":
		return {.Image} // It starts its nodes from the boot image.
	}
	return {}
}

// The budget of each program, by name: pages of memory, programs, threads.
// It comes from the budget of this service, and it returns when the program
// stops.
budget_of :: proc "contextless" (name: string) -> system.Budget_Amounts {
	switch name {
	case "input":
		return {pages = 256, programs = 1, threads = 1}
	case "compositor":
		return {pages = 4096, programs = 1, threads = 1}
	case "console":
		return {pages = 8192, programs = 5, threads = 6} // 4 sandboxes.
	case "rings":
		return {pages = 4096, programs = 7, threads = 7} // 6 nodes.
	case "threads":
		return {pages = 2048, programs = 1, threads = 6}
	case "workers":
		return {pages = 2048, programs = 1, threads = 9}
	case "rights":
		return {pages = 2048, programs = 1, threads = 2}
	case "budget":
		return {pages = 1024, programs = 1, threads = 4}
	}
	return {pages = 2048, programs = 1, threads = 1}
}

// log_grant gives the grant of the log: each program that this service
// starts can write on the log. A program that starts programs can also give
// the log to them.
log_grant :: proc "contextless" (name: string) -> system.Grant {
	rights := system.Rights{.Write}
	if name == "console" || name == "rings" {
		rights += {.Give}
	}
	return {system.context_record().handles[op.CONTEXT_LOG], rights}
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
		grants: [op.CONTEXT_HANDLES]system.Grant
		grants[0] = {input_memory, {.Read, .Write}}
		grants[1] = {device(.Ports, 0x60, 5), {}}
		grants[2] = {device(.Interrupt, 1, 0), {.Read}}
		grants[3] = {device(.Interrupt, 12, 0), {.Read}}
		grants[op.CONTEXT_LOG] = log_grant("input")
		_, status = system.program_start(system.image_find(image, "input"), "input", grants, {}, budget_of("input"))
		if status != .Ok {
			fail("cannot start input", status)
		}
		for grant in grants[1:4] {
			system.close(grant.handle)
		}
	}

	// The compositor: the framebuffer, the input ring, and a ring to this service.
	control_memory, control, status = system.ring_create()
	if status != .Ok {
		fail("cannot create a ring", status)
	}
	{
		grants: [op.CONTEXT_HANDLES]system.Grant
		grants[0] = {ctx.handles[op.ROOT_FRAMEBUFFER], {.Read, .Write}}
		grants[1] = {input_memory, {.Read, .Write}}
		grants[2] = {control_memory, {.Read, .Write}}
		grants[op.CONTEXT_LOG] = log_grant("compositor")
		values: [op.CONTEXT_VALUES]u64
		values[0] = ctx.values[op.ROOT_VALUE_WIDTH]
		values[1] = ctx.values[op.ROOT_VALUE_HEIGHT]
		values[2] = ctx.values[op.ROOT_VALUE_PIXELS_PER_LINE]
		values[3] = ctx.values[op.ROOT_VALUE_FORMAT]
		compositor, status = system.program_start(system.image_find(image, "compositor"), "compositor", grants, values, budget_of("compositor"))
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
	slot.client = system.give(compositor, display_memory, {.Read, .Write}) or_return
	system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Add), values = {0 = u64(slot.client)}})

	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	grants[system.GRANT_DISPLAY] = {display_memory, {.Read, .Write}}
	grants[op.CONTEXT_LOG] = log_grant(name)
	role := grants_of(name)
	status := system.Status.Ok
	if .Root_Ring in role {
		slot.requests_memory, slot.requests, status = system.ring_create()
		grants[system.GRANT_ROOT] = {slot.requests_memory, {.Read, .Write}}
	}
	// One Machine handle; each role receives a part of its rights.
	machine_rights: system.Rights
	if .Inspect in role {
		machine_rights += {.Inspect}
	}
	if .Stop in role {
		machine_rights += {.Stop}
	}
	if machine_rights != {} {
		grants[system.GRANT_MACHINE] = {machine, machine_rights}
	}
	if .Image in role {
		grants[system.GRANT_IMAGE] = {image_memory, {.Read}}
		values[system.GRANT_VALUE_IMAGE_SIZE] = u64(len(image))
	}
	if status == .Ok {
		slot.program, status = system.program_start(file, name, grants, values, budget_of(name))
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
