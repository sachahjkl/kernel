// The root service: the first program (docs/ARCHITECTURE.md, U2).
//
// The kernel gives it every handle that exists at boot. It starts the other
// programs, and it gives each one only the handles of its role. It is the
// only program that creates access from nothing.
package root

import "../../bootscreen"
import "../../bootscreen/collect"
import "../../display"
import "../../graphics"
import info "../../boot_info"
import "../../isolated"
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
	Log_Records, // Read the records of the log.
	Serve, // A service: other programs call its exports through connections.
}

grants_of :: proc "contextless" (name: string) -> bit_set[Grant] {
	switch name {
	case "console":
		return {.Root_Ring, .Inspect, .Stop, .Image}
	case "monitor", "processors", "pages", "flow":
		return {.Inspect}
	case "rights":
		return {.Inspect, .Image} // It shows what the kernel refuses.
	case "log":
		return {.Log_Records}
	case "boot":
		return {.Inspect, .Image} // It shows the modules of the boot image.
	case "rings":
		return {.Image} // It starts its nodes from the boot image.
	case "paint", "life":
		return {.Serve}
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
	case "processors":
		return {pages = 2048, programs = 1, threads = 9}
	case "flow":
		return {pages = 2048, programs = 1, threads = 3}
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
	requests:        ring.Ring, // The ring from the program to this service, if it has one.
	requests_memory: system.Handle,
	service:         ring.Ring, // The service ring of the program, if it is a service.
	service_memory:  system.Handle,
	hash:            [32]u8, // The hash of the file of the program.
	name:            system.Name,
}

// A connection: one caller can call the exports of one service.
Connection :: struct {
	caller:  ^Started, // nil: the place is free.
	service: ^Started,
	ring:    system.Handle, // The call ring, as the service names it.
	region:  system.Handle, // The call region, as the service names it.
}

CONNECTION_CAPACITY :: 32

connections: [CONNECTION_CAPACITY]Connection

STARTED_CAPACITY :: 32

machine: system.Handle
image: []u8
image_memory: system.Handle
started: [STARTED_CAPACITY]Started
compositor: system.Handle
control: ring.Ring
control_memory: system.Handle

// The boot display (package bootscreen), on the screen of the machine.
// This service draws it until the compositor has the screen.
screen: graphics.Canvas
screen_data: bootscreen.Data
message: bootscreen.Text

show :: proc "contextless" (text: string, state: bootscreen.State) {
	if screen.pixels == nil {
		return
	}
	screen_data.message = text
	screen_data.state = state
	collect.data(&screen_data, machine)
	bootscreen.draw_screen(screen, &screen_data)
}

// fail ends the start of the machine. The machine does not stop: the boot
// display stays, with the failure, until a person stops the machine.
fail :: proc "contextless" (text: string, status: system.Status) -> ! {
	system.log_in("programs", .Error, "root: ", text, ": status ", u64(status))
	if compositor != 0 {
		system.call(.Program_Stop, u64(compositor), 0) // The screen returns to this service.
	}
	message.count = 0
	bootscreen.put(&message, "the start failed: ")
	bootscreen.put(&message, text)
	bootscreen.put(&message, ": status ")
	bootscreen.put_number(&message, u64(status))
	show(string(message.bytes[:message.count]), .Failed)
	system.log("root: the boot display shows the failure")
	for {
		system.sleep(max(u64))
	}
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
	if pixels, map_status := system.memory_map(ctx.handles[op.ROOT_FRAMEBUFFER], {.Write}); map_status == .Ok {
		screen = {
			pixels = ([^]graphics.Color)(pixels),
			width  = int(ctx.values[op.ROOT_VALUE_WIDTH]),
			height = int(ctx.values[op.ROOT_VALUE_HEIGHT]),
			stride = int(ctx.values[op.ROOT_VALUE_PIXELS_PER_LINE]),
		}
		screen_data.image = image
		screen_data.red_first = ctx.values[op.ROOT_VALUE_FORMAT] == u64(info.Pixel_Format.Red_Green_Blue_X)
	}
	show("the root service starts input", .Running)

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

	show("the root service starts the compositor", .Running)
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
			if item.program == 0 || item.requests.head == nil {
				continue
			}
			for record in system.receive(&item.requests.commands) {
				name := system.name_unpack({record.values[0], record.values[1], record.values[2], record.values[3]})
				result := system.Status.Bad_Operation
				completion := ring.Record {
					tag = record.tag,
				}
				#partial switch system.Root_Command(record.kind) {
				case .Connect:
					result = connect(&item, system.name_of(name[:]), &completion.values)
				case .Disconnect:
					result = .Bad_Handle
					for &connection in connections {
						if connection.caller == &item && system.name_of(connection.service.name[:]) == system.name_of(name[:]) {
							disconnect(&connection)
							result = .Ok
						}
					}
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
				completion.kind = u32(result)
				system.send(&item.requests.completions, completion)
			}
		}
		reap()
		system.wait_records(&wait, &control.completions)
		for &item in started {
			if item.program != 0 && item.requests.head != nil {
				system.wait_records(&wait, &item.requests.commands)
			}
		}
		system.wait_end(&wait)
	}
}

// start starts a program that shows a surface.
start :: proc "contextless" (name: string) -> system.Status {
	file: []u8
	entry: ^info.Image_Entry
	for &item in system.image_entries(image) {
		if system.name_of(item.name[:]) == name && item.offset <= u64(len(image)) && item.size <= u64(len(image)) - item.offset {
			file = image[item.offset:][:item.size]
			entry = &item
			break
		}
	}
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
	if .Log_Records in role {
		grants[system.GRANT_LOG_RECORDS] = {system.context_record().handles[op.ROOT_LOG_RECORDS], {.Read}}
	}
	if .Image in role {
		grants[system.GRANT_IMAGE] = {image_memory, {.Read}}
		values[system.GRANT_VALUE_IMAGE_SIZE] = u64(len(image))
	}
	// A service: the service ring, and its own file, to read the
	// descriptions of its exports.
	mappings: [1]system.Mapping
	mapping_count := 0
	if .Serve in role && status == .Ok && entry.offset % system.PAGE_SIZE == 0 {
		slot.service_memory, slot.service, status = system.ring_create()
		grants[system.GRANT_SERVICE] = {slot.service_memory, {.Read, .Write}}
		values[system.GRANT_VALUE_FILE_ADDRESS] = isolated.FILE_ADDRESS
		values[system.GRANT_VALUE_FILE_SIZE] = entry.size
		mappings[0] = {memory = image_memory, address = isolated.FILE_ADDRESS, first = entry.offset / system.PAGE_SIZE, page_count = (entry.size + system.PAGE_SIZE - 1) / system.PAGE_SIZE}
		mapping_count = 1
	}
	if status == .Ok {
		slot.program, status = system.program_start(file, name, grants, values, budget_of(name), mappings[:mapping_count])
	}
	if status != .Ok {
		release(slot)
		return status
	}
	slot.hash = entry.hash
	copy(slot.name[:len(slot.name) - 1], name)
	system.log_in("programs", .Info, "root: started ", name)
	return .Ok
}

// connect makes a connection from a caller to the service with a name: a
// new call ring and a new call region, that the two programs receive. This
// service pays for the two memory objects and does not keep them. values is
// the completion of Root_Command.Connect.
connect :: proc "contextless" (caller: ^Started, name: string, values: ^[7]u64) -> system.Status {
	service: ^Started
	for &item in started {
		if item.program != 0 && item.service.head != nil && system.name_of(item.name[:]) == name {
			service = &item
		}
	}
	if service == nil || service == caller {
		return .Bad_Handle
	}
	free: ^Connection
	count := 0
	for &connection in connections {
		if connection.caller == nil {
			free = &connection
		} else if connection.service == service {
			count += 1
			if connection.caller == caller {
				return .Bad_State
			}
		}
	}
	if free == nil || count == isolated.SERVICE_CONNECTION_CAPACITY {
		return .No_Slot
	}
	// The service ring keeps room for one Disconnect for each connection:
	// this service never waits for a service that does not read its ring.
	names := &service.service.commands
	if ring.capacity(names) - ring.count(names) < u32(count) + 2 {
		return .No_Slot
	}
	ring_memory := system.memory_create(ring.PAGE_COUNT) or_return
	defer system.close(ring_memory)
	region_memory := system.memory_create(isolated.REGION_PAGES) or_return
	defer system.close(region_memory)
	// The service first. It receives its handles through its service ring.
	in_service_ring := system.give(service.service_memory, ring_memory, {.Read, .Write}) or_return
	in_service_region := system.give(service.service_memory, region_memory, {.Read, .Write}) or_return
	if !system.send(&service.service.commands, ring.Record{kind = u32(isolated.Service_Command.Connect), values = {0 = u64(in_service_ring), 1 = u64(in_service_region)}}) {
		return .No_Slot
	}
	free^ = {
		caller  = caller,
		service = service,
		ring    = in_service_ring,
		region  = in_service_region,
	}
	// The caller receives its handles through its ring to this service.
	status: system.Status
	given: [3]system.Handle
	given[0], status = system.give(caller.requests_memory, service.program, {.Read})
	if status == .Ok {
		given[1], status = system.give(caller.requests_memory, ring_memory, {.Read, .Write})
	}
	if status == .Ok {
		given[2], status = system.give(caller.requests_memory, region_memory, {.Read, .Write})
	}
	if status != .Ok {
		disconnect(free)
		return status
	}
	hash := transmute([4]u64)service.hash
	values^ = {u64(given[0]), u64(given[1]), u64(given[2]), hash[0], hash[1], hash[2], hash[3]}
	system.log_in("calls", .Info, "root: connected ", system.name_of(caller.name[:]), " to the service ", name)
	return .Ok
}

// disconnect ends a connection: the service unmaps the call ring and the
// call region. The service ring has room for the record (see connect); a
// service that gives a false count of records read keeps its own mappings.
disconnect :: proc "contextless" (connection: ^Connection) {
	if connection.service.program != 0 {
		system.send(&connection.service.service.commands, ring.Record{kind = u32(isolated.Service_Command.Disconnect), values = {0 = u64(connection.ring), 1 = u64(connection.region)}})
	}
	system.log_in("calls", .Info, "root: disconnected ", system.name_of(connection.caller.name[:]), " from the service ", system.name_of(connection.service.name[:]))
	connection^ = {}
}

// release frees what this service holds for a program, and tells the compositor.
release :: proc "contextless" (item: ^Started) {
	// The connections of the program end: those that it made, and those
	// that it served.
	served := item.service.head != nil
	if item.program != 0 {
		system.close(item.program)
		item.program = 0
	}
	for &connection in connections {
		if connection.caller == item || connection.service == item {
			disconnect(&connection)
		}
	}
	if served {
		system.ring_close(&item.service)
		system.close(item.service_memory)
	}
	system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Remove), values = {0 = u64(item.client)}})
	if item.requests.head != nil {
		system.ring_close(&item.requests)
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
			system.log_in("programs", code == 0 ? .Info : .Warning, "root: ", system.name_of(item.name[:]), " stopped with code ", u64(code))
			release(&item)
		}
	}
}
