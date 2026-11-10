// The root service: the first program (docs/ARCHITECTURE.md, U2).
//
// The kernel gives it every handle that exists at boot. It starts the other
// programs, and it gives each one only the handles of its role. It is the
// only program that creates access from nothing.
package root

import "support:bootscreen"
import "support:bootscreen/collect"
import "support:display"
import "support:graphics"
import info "contract:boot_info"
import "contract:isolated"
import op "contract:operation"
import "contract:ring"
import "support:system"
import "support:terminal"
import "contract:block"
import "support:pci"

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
	Terminal, // The program has no surface: it writes records to a terminal, and reads keys from it.
	Data_Disk, // A block service of the data disk, and its block ring.
	Scratch_Disk, // A block service of the disk of the measures, and its block ring.
}

grants_of :: proc "contextless" (name: string) -> bit_set[Grant] {
	switch name {
	case "console":
		return {.Root_Ring, .Inspect, .Stop, .Image, .Terminal}
	case "flood":
		return {.Terminal}
	case "monitor", "processors", "pages", "flow", "crowd", "clock":
		return {.Inspect}
	case "rights":
		return {.Inspect, .Image} // It shows what the kernel refuses.
	case "log":
		return {.Log_Records}
	case "boot":
		return {.Inspect, .Image} // It shows the modules of the boot image.
	case "rings":
		return {.Image} // It starts its nodes from the boot image.
	case "frames":
		return {.Inspect, .Image} // It reads its own page table, and starts its twins from the boot image.
	case "paint", "life", "tally":
		return {.Serve}
	case "manual":
		return {.Serve, .Image} // It reads the documentation of each module of the boot image.
	case "disk":
		return {.Scratch_Disk}
	}
	return {}
}

// The budget of each program, by name: pages of memory, programs, threads.
// It comes from the budget of this service, and it returns when the program
// stops.
// The limits: the processor time of one processor for each thread, and 1000
// log records in each second.
budget_of :: proc "contextless" (name: string) -> system.Budget_Amounts {
	amounts := things_of(name)
	own, _ := system.budget_read()
	amounts.processor = min(name == "limits" ? 1_500_000 : amounts.threads * 1_000_000, own.processor)
	amounts.log_records = name == "limits" ? 40 : 1000
	return amounts
}

things_of :: proc "contextless" (name: string) -> system.Budget_Amounts {
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
	case "limits":
		return {pages = 2048, programs = 1, threads = 5}
	case "origin":
		return {pages = 2048, programs = 2, threads = 1} // One program that only receives.
	case "frames":
		return {pages = 12288, programs = 6, threads = 6} // 8192 pages at a time, and 5 twins.
	case "budget":
		return {pages = 1024, programs = 1, threads = 4}
	case "processors":
		return {pages = 2048, programs = 1, threads = 9}
	case "flow":
		return {pages = 2048, programs = 1, threads = 3}
	case "crowd":
		return {pages = 2048, programs = 1, threads = 5}
	case "terminal":
		return {pages = 8192, programs = 1, threads = 2} // The lines that it keeps.
	case "flood":
		return {pages = 256, programs = 1, threads = 1}
	case "block":
		return {pages = 256, programs = 1, threads = 1}
	case "disk":
		return {pages = 2048, programs = 1, threads = 1}
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
	granted:         system.Root_Grants, // What the program has from this service, of the grants that this service can revoke.
	revoked:         system.Root_Grants,
	writer:          ^Started, // A terminal: the program that writes in it. nil after that program stopped.
	is_terminal:     bool,
	driver:          ^Started, // The block service that serves this program. nil: none, or it stopped.
	is_driver:       bool, // A block service: it has the device at `device`.
	device:          pci.Place,
	queues:          system.Handle, // A block service: the memory of the queue of its device.
}

// The size of the terminal of each program, and what it shows.
terminal_of :: proc "contextless" (name: string) -> (columns, rows: u64, measure: bool) {
	if name == "flood" {
		return terminal.COLUMNS_LIMIT, terminal.ROWS_LIMIT, true // It shows the rates of the program.
	}
	return 96, 26, false
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
// The shared code of the modules of the programs that this service starts.
prepared: system.Prepared_Modules
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
		_, status = system.program_start(system.image_find(image, "input"), "input", grants, {}, budget_of("input"), nil, &prepared)
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
		compositor, status = system.program_start(system.image_find(image, "compositor"), "compositor", grants, values, budget_of("compositor"), nil, &prepared)
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
				case .Grants:
					result = .Bad_Handle
					if other := find(system.name_of(name[:])); other != nil {
						completion.values[0] = transmute(u64)other.granted
						completion.values[1] = transmute(u64)other.revoked
						result = .Ok
					}
				case .Revoke:
					result = revoke(system.name_of(name[:]), record.values[4], &completion.values)
				case .Stop:
					result = .Bad_Handle
					for &other in started {
						if other.program != 0 && !other.is_terminal && system.name_of(other.name[:]) == system.name_of(name[:]) {
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
	if len(file) == 0 || name == "root" || name == "input" || name == "compositor" || name == "terminal" || name == "block" {
		return .Bad_Operation
	}
	role := grants_of(name)
	// A client of a block service: the service of its disk starts first.
	driver: ^Started
	block_ring: system.Handle
	if .Data_Disk in role || .Scratch_Disk in role {
		status: system.Status
		driver, block_ring, status = driver_start(.Data_Disk in role ? pci.DATA_DISK_DEVICE : pci.SCRATCH_DISK_DEVICE)
		if status != .Ok {
			return status
		}
	}
	defer if block_ring != 0 {
		system.close(block_ring)
	}
	slot: ^Started
	for &item in started {
		if item.program == 0 {
			slot = &item
			break
		}
	}
	if slot == nil {
		if driver != nil {
			system.call(.Program_Stop, u64(driver.program), 0)
		}
		return .No_Slot
	}
	slot^ = {}
	grants: [op.CONTEXT_HANDLES]system.Grant
	if block_ring != 0 {
		grants[block.GRANT_RING] = {block_ring, {.Read, .Write}}
	}
	values: [op.CONTEXT_VALUES]u64
	grants[op.CONTEXT_LOG] = log_grant(name)

	// A program has a surface, or it has a terminal. This service does not
	// keep the memory objects that it creates here.
	view: ^Started
	shared: [2]system.Handle // The ring to the compositor; or the terminal ring and the text region.
	defer for memory in shared {
		if memory != 0 {
			system.close(memory)
		}
	}
	if .Terminal in role {
		for &item in started {
			if item.program == 0 && &item != slot {
				view = &item
				break
			}
		}
		if view == nil {
			return .No_Slot
		}
		shared[0] = system.memory_create(ring.pages(terminal.RING_CAPACITY)) or_return
		shared[1] = system.memory_create(terminal.TEXT_PAGES) or_return
		grants[terminal.GRANT_RING] = {shared[0], {.Read, .Write}}
		grants[terminal.GRANT_TEXT] = {shared[1], {.Read, .Write}}
	} else {
		shared[0] = system.memory_create(ring.PAGE_COUNT) or_return
		slot.client = system.give(compositor, shared[0], {.Read, .Write}) or_return
		system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Add), values = {0 = u64(slot.client)}})
		grants[system.GRANT_DISPLAY] = {shared[0], {.Read, .Write}}
	}
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
		slot.program, status = system.program_start(file, name, grants, values, budget_of(name), mappings[:mapping_count], &prepared)
	}
	if status != .Ok {
		release(slot)
		if driver != nil {
			system.call(.Program_Stop, u64(driver.program), 0)
		}
		return status
	}
	slot.driver = driver
	slot.hash = entry.hash
	slot.granted = {.Log}
	if machine_rights != {} {
		slot.granted += {.Machine}
	}
	if .Image in role {
		slot.granted += {.Image}
	}
	if .Log_Records in role {
		slot.granted += {.Log_Records}
	}
	copy(slot.name[:len(slot.name) - 1], name)
	if view != nil {
		if status = terminal_start(view, slot, shared[0], shared[1]); status != .Ok {
			system.call(.Program_Stop, u64(slot.program), 0)
			return status
		}
		system.log_in("programs", .Info, "root: started ", name, ", with a terminal")
		return .Ok
	}
	system.log_in("programs", .Info, "root: started ", name)
	return .Ok
}

// find gives the program with a name that this service started. A terminal
// has the name of no program.
find :: proc "contextless" (name: string) -> ^Started {
	for &item in started {
		if item.program != 0 && !item.is_terminal && system.name_of(item.name[:]) == name {
			return &item
		}
	}
	return nil
}

// revoke ends one grant of a program that runs (property 13). Each grant
// here is a handle that this service keeps: the handle of the program came
// from it, and the kernel ends what came from it in that program
// (Handle_Revoke). What the program gave to other programs ends too.
// values is the completion of Root_Command.Revoke.
revoke :: proc "contextless" (name: string, grant: u64, values: ^[7]u64) -> system.Status {
	item := find(name)
	if item == nil {
		return .Bad_Handle
	}
	if grant > u64(max(system.Root_Grant)) {
		return .Bad_Operation
	}
	which := system.Root_Grant(grant)
	if which not_in item.granted {
		return .Bad_State
	}
	handle: system.Handle
	switch which {
	case .Log:
		handle = system.context_record().handles[op.CONTEXT_LOG]
	case .Machine:
		handle = machine
	case .Image:
		handle = image_memory
	case .Log_Records:
		handle = system.context_record().handles[op.ROOT_LOG_RECORDS]
	}
	count := system.handle_revoke(handle, item.program) or_return
	item.granted -= {which}
	item.revoked += {which}
	values[0] = count
	system.log_in("programs", .Info, "root: revoked the grant ", system.root_grant_names[which], " of ", name, ", holdings ended: ", count)
	return .Ok
}

// terminal_start starts the terminal of a program that runs. The terminal
// receives a surface, the terminal ring, the text region with the right
// Read, and a handle that reads the state of the program. It receives
// nothing of the role of the program.
terminal_start :: proc "contextless" (view: ^Started, writer: ^Started, ring_memory, text_memory: system.Handle) -> system.Status {
	view^ = {}
	display_memory := system.memory_create(ring.PAGE_COUNT) or_return
	defer system.close(display_memory)
	client := system.give(compositor, display_memory, {.Read, .Write}) or_return
	system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Add), values = {0 = u64(client)}})

	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	grants[system.GRANT_DISPLAY] = {display_memory, {.Read, .Write}}
	grants[terminal.GRANT_RING] = {ring_memory, {.Read, .Write}}
	grants[terminal.GRANT_TEXT] = {text_memory, {.Read}}
	grants[terminal.GRANT_PROGRAM] = {writer.program, {.Read}}
	grants[op.CONTEXT_LOG] = log_grant("terminal")
	name := system.name_pack(system.name_of(writer.name[:]))
	copy(values[terminal.VALUE_NAME:], name[:])
	measure: bool
	values[terminal.VALUE_COLUMNS], values[terminal.VALUE_ROWS], measure = terminal_of(system.name_of(writer.name[:]))
	values[terminal.VALUE_MEASURE] = u64(measure)
	program, status := system.program_start(system.image_find(image, "terminal"), "terminal", grants, values, budget_of("terminal"), nil, &prepared)
	if status != .Ok {
		system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Remove), values = {0 = u64(client)}})
		return status
	}
	view.program, view.client, view.writer, view.is_terminal = program, client, writer, true
	copy(view.name[:len(view.name) - 1], "terminal")
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
	// A terminal that stops: its program stops. A program that stops: its
	// terminal stays, and shows what the program wrote.
	if item.writer != nil && item.writer.program != 0 {
		system.call(.Program_Stop, u64(item.writer.program), 0)
	}
	for &other in started {
		if other.writer == item {
			other.writer = nil
		}
		if other.driver == item {
			other.driver = nil
		}
	}
	// A client that stops: its block service stops. A block service that
	// stops: the device stops using memory.
	if item.driver != nil && item.driver.program != 0 {
		system.call(.Program_Stop, u64(item.driver.program), 0)
	}
	if item.is_driver {
		driver_end(item)
	}
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
	if item.client != 0 {
		system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Remove), values = {0 = u64(item.client)}})
	}
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
