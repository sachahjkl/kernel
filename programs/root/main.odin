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
import module "contract:module"
import op "contract:operation"
import "contract:ring"
import "support:random"
import "support:system"
import terminal "support:terminal"
import "contract:block"
import "contract:datagram"
import "contract:date"
import "contract:errors"
import "contract:fixed_addresses"
import "contract:frame"
import "support:pci"
import "support:storage"
import "contract:settings"

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
	Store, // A private store in the storage service: a connection to it names the program, with a limit of blocks.
	Person, // The program acts for the person: a service shows it what it holds for all callers.
	Data_Disk, // A block service of the data disk, and its block ring.
	Scratch_Disk, // A block service of the disk of the measures, and its block ring.
	Replacements, // Read the replacement table of the machine.
	Replace, // Change the replacement table of the machine (Root_Command.Replace).
	Network, // An endpoint in the network service, with the grant of endpoint_of: datagrams, or segments of TCP.
	Network_Device, // The frame service of the network device and its frame ring, and a control ring from this service.
	Connect, // A ring to this service that serves Connect and Disconnect only, to the services of callable_of.
	Schedule, // The machine, with the right Schedule: change the scheduling strategy of the machine.
	Settings, // The settings page with Write (contract:settings): the one writer of the settings of the person.
	Clock, // The date page with Write and the two ports of the real-time clock (contract:date): the one writer of the date.
}

grants_of :: proc "contextless" (name: string) -> bit_set[Grant] {
	switch name {
	case "console":
		return {.Root_Ring, .Inspect, .Stop, .Image, .Terminal, .Store, .Person, .Replacements, .Replace}
	case "flood":
		return {.Terminal}
	case "inspect":
		// A developer tool: it reads the reports of the machine and the names
		// of the modules, and serves the same facts (docs/TOOLS.md).
		return {.Inspect, .Image, .Serve}
	case "monitor":
		return {.Inspect, .Serve} // It serves programs() and counts() to a caller that acts for the person.
	case "processors", "pages", "flow", "crowd", "clock":
		return {.Inspect}
	case "rights":
		return {.Inspect, .Image} // It shows what the kernel refuses.
	case "pointers":
		return {.Image} // It reads the pointer themes in the resource table of the boot image.
	case "log":
		return {.Log_Records, .Serve} // It serves records() to a caller that acts for the person.
	case "boot":
		return {.Inspect, .Image} // It shows the modules of the boot image.
	case "rings":
		return {.Image} // It starts its nodes from the boot image.
	case "frames":
		return {.Inspect, .Image} // It reads its own page table, and starts its twins from the boot image.
	case "locks":
		return {.Inspect, .Image} // It reads the counts of the locks, and starts its lockers from the boot image.
	case "address_space":
		return {.Inspect, .Image} // It reads its own mappings, and starts its child from the boot image.
	case "return_fault":
		return {.Image} // It starts its children from the boot image.
	case "fault_ring":
		return {.Image} // It starts its children from the boot image.
	case "scheduler":
		return {.Inspect, .Schedule} // It reads the counts of the scheduler, and changes the strategy.
	case "paint", "life", "tally", "sample":
		return {.Serve} // sample: the module of the tables, started as a program when a caller connects.
	case "settings":
		return {.Settings, .Serve, .Store} // It writes the settings of the person, keeps them in its private store, and serves set() and get().
	case "date":
		return {.Clock, .Serve} // It reads the real-time clock, writes the date page, and serves now().
	case "manual":
		return {.Serve, .Image, .Replacements, .Inspect} // It reads the documentation of each module of the boot image, and the module records of each program.
	case "disk":
		return {.Scratch_Disk}
	case "storage":
		return {.Serve, .Data_Disk}
	case "notes":
		return {.Store}
	case "errors":
		return {.Store, .Image, .Inspect, .Connect} // It makes errors in its store, loads modules and starts fault from the boot image, counts the locks, and asks for connections that the root service refuses (callable_of gives it none).
	case "imports":
		return {.Inspect, .Image} // It loads modules of the boot image, and measures with the cycle counter.
	case "cryptography_vectors":
		return {.Image} // It reads the hash of the module cryptography in the boot image.
	case "net":
		return {.Inspect, .Network} // It measures with the cycle counter.
	case "server":
		return {.Network, .Serve, .Store} // A listen grant, its exports for the console, and its pages in its private store.
	case "fetch":
		return {.Network}
	case "quic_echo":
		return {.Network} // A listen grant of UDP: QUIC in the program, the module cryptography through its imports.
	case "network":
		return {.Network_Device}
	case "remote":
		// The calls of the host: an endpoint whose grant names the host,
		// connections to the services of callable_of, and the grant to act
		// for the person (docs/MODULE_CONTRACT.md, "A call from the host").
		return {.Connect, .Network, .Person}
	case "interface_through_module":
		return {.Image} // It reads the size of the code of interface_module.
	case "tables":
		// It loads sample, starts a call host of it from the boot image,
		// and connects to the service sample (docs/MODULE_CONTRACT.md,
		// "Tables and bytes as parameters").
		return {.Image, .Connect}
	}
	return {}
}

// callable_of gives the services that a program with the grant Connect can
// connect to. A program with the grant Root_Ring connects to each service.
callable_of :: proc "contextless" (name: string) -> []string {
	switch name {
	case "remote":
		return remote_callable[:]
	case "tables":
		return tables_callable[:]
	}
	return nil
}

@(rodata)
remote_callable := [?]string{"compositor", "date", "inspect", "log", "manual", "monitor", "settings", "storage"}
@(rodata)
tables_callable := [?]string{"sample"}

// The values of the context of the compositor that name its own file: 0 to
// 3 are the screen.
COMPOSITOR_VALUE_FILE_ADDRESS :: 4
COMPOSITOR_VALUE_FILE_SIZE :: 5
// The pointer theme file of the compositor (docs/POINTERS.md): a resource
// of the boot image, mapped read-only (resources.odin).
COMPOSITOR_VALUE_POINTER_THEME_ADDRESS :: 6
COMPOSITOR_VALUE_POINTER_THEME_SIZE :: 7
POINTER_THEME_ADDRESS :: fixed_addresses.POINTER_THEMES_ADDRESS
// The values of the context of the compositor for each pointer theme: the
// second at the values that contract:operation names for it.
COMPOSITOR_POINTER_THEME_VALUES := [2][2]int{{COMPOSITOR_VALUE_POINTER_THEME_ADDRESS, COMPOSITOR_VALUE_POINTER_THEME_SIZE}, {op.CONTEXT_VALUE_SECOND_POINTER_THEME_ADDRESS, op.CONTEXT_VALUE_SECOND_POINTER_THEME_SIZE}}
POINTER_THEME_SPACING :: fixed_addresses.RANGE_SPAN / 2 // The second theme is this far after the first.

// may_connect says if a program can ask the root service for a connection
// to the service with a name.
may_connect :: proc "contextless" (caller: string, service: string) -> bool {
	role := grants_of(caller)
	if .Root_Ring in role {
		return true
	}
	if .Connect not_in role {
		return false
	}
	for name in callable_of(caller) {
		if name == service {
			return true
		}
	}
	return false
}

// store_limit_of gives the blocks of the private store of a program with
// the grant Store.
store_limit_of :: proc "contextless" (name: string) -> u64 {
	switch name {
	case "console":
		return 4 // A small limit: the test reaches it.
	case "errors":
		return 2 // One object is over the limit.
	case "notes":
		return 4500 // The versions of a run of 1000 commits of the count (4 blocks each), then thinning at the limit.
	}
	return 64
}

// A service that starts when a program asks for a connection to it.
on_demand :: proc "contextless" (name: string) -> bool {
	return name == "storage" || name == "sample"
}

// grant_for gives what a caller receives in a service (isolated.Service_Command).
// The storage service: the private store of the caller, by its name, with a
// limit of blocks. Each service: the flag that the caller acts for the
// person (the manual gives what runs only to such a caller).
grant_for :: proc "contextless" (caller: ^Started, service: ^Started) -> (grant: u64) {
	name := system.name_of(caller.name[:])
	role := grants_of(name)
	if .Store in role && .Store not_in caller.revoked && system.name_of(service.name[:]) == "storage" {
		grant = store_limit_of(name)
	}
	if .Person in role && .Person not_in caller.revoked {
		grant |= isolated.CALLER_PERSON
	}
	return grant
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
	case "locks":
		return {pages = 9216, programs = 8, threads = 20} // 4 lockers of 1024 pages, then 3 at a time of the stress case.
	case "return_fault":
		return {pages = 2048, programs = 2, threads = 2} // One child at a time, with one thread.
	case "fault_ring":
		return {pages = 4096, programs = 2, threads = 21} // One child at a time: 512 pages and 20 threads (17 that fault in a full ring, its main thread and its handler).
	case "extended_state":
		return {pages = 2048, programs = 1, threads = 32} // The main thread and up to 31 threads that hold their registers.
	case "address_space":
		return {pages = 40960, programs = 2, threads = 6} // 64 MiB of large pages, two ranges of 1 GiB with their page tables, a child.
	case "scheduler":
		return {pages = 2048, programs = 1, threads = 24} // 12 spinners, two threads that wake each other, one that sleeps, a changer, a thread that starts threads.
	case "flow":
		return {pages = 2048, programs = 1, threads = 3}
	case "crowd":
		return {pages = 2048, programs = 1, threads = 5}
	case "terminal":
		return {pages = 8192, programs = 1, threads = 2} // The lines that it keeps.
	case "flood":
		return {pages = 256, programs = 1, threads = 1}
	case "block", "frame":
		return {pages = 256, programs = 1, threads = 1}
	case "storage":
		// About 9 MB of tables: the count of names of each block of the disk,
		// the changes of one commit, the leaves of one version index, and the
		// versions of one object for versions().
		return {pages = 4096, programs = 1, threads = 1}
	case "disk":
		return {pages = 2048, programs = 1, threads = 1}
	case "imports":
		return {pages = 2048, programs = 3, threads = 3} // Two programs that import calendar.
	case "errors":
		return {pages = 2048, programs = 3, threads = 4} // It starts fault and its child, and 3 threads under contention.
	case "server":
		return {pages = 4096, programs = 1, threads = 1} // A table of 32 connections with their buffers, and a large window.
	case "quic_echo":
		// 16 QUIC connections of about 85 KiB each, 4 streams of about
		// 130 KiB for each, and an echo buffer of 16 KiB for each stream:
		// about 2770 pages, in one mapping of the program (docs/QUIC.md,
		// section 6).
		return {pages = 4096, programs = 1, threads = 1}
	case "tables":
		return {pages = 4096, programs = 3, threads = 3} // A table of 65536 readings in a memory object (640 pages), and two call hosts (sample, hostile_exports) with their threads.
	}
	return {pages = 2048, programs = 1, threads = 1}
}

// log_grant gives the grant of the log: each program that this service
// starts can write on the log. A program that starts programs can also give
// the log to them.
log_grant :: proc "contextless" (name: string) -> system.Grant {
	rights := system.Rights{.Write}
	if name == "console" || name == "rings" || name == "errors" || name == "fault_ring" { // errors gives it to its child, which measures a refused Log; the child of fault_ring that repairs logs its own cases.
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
	network:         ring.Ring, // The network service: the control ring from this service.
	network_memory:  system.Handle,
	endpoint:        system.Handle, // A program with an endpoint: its datagram ring, as the network service names it.
	network_service: ^Started,
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

// The replacement table of the machine: this service writes it. Each
// program that this service starts receives its records (property 20: a
// program cannot ask for a replacement and cannot refuse one).
replacement_memory: system.Handle
replacement_table: ^system.Replacement_Table
replacement_records: [system.REPLACEMENT_CAPACITY]module.Replacement

// load_source gives what the loader of a program that this service starts can
// read: the boot image, and the replacements of this time.
load_source :: proc "contextless" () -> system.Load_Source {
	return {image = image, replacements = system.replacements_read(replacement_table, &replacement_records)}
}

// The boot display (package bootscreen), on the screen of the machine.
// This service draws it until the compositor has the screen.
screen: graphics.Canvas
screen_data: bootscreen.Data
message: bootscreen.Text

show :: proc "contextless" (text: string, state: bootscreen.State, step: bootscreen.Step) {
	if screen.pixels == nil {
		return
	}
	screen_data.message = text
	screen_data.state = state
	screen_data.step = step
	collect.data(&screen_data, machine)
	bootscreen.draw_screen(screen, &screen_data)
}

// shortage_start gives the program shortage nearly all the pages of this
// service, and the machine; the program stops the machine at its end. This
// service keeps SHORTAGE_KEEP pages: the module of the program is copied in
// memory that it pays.
SHORTAGE_KEEP :: 24

shortage_start :: proc "contextless" (ctx: ^system.Context) -> ! {
	own, _ := system.budget_read()
	grants: [op.CONTEXT_HANDLES]system.Grant
	grants[system.GRANT_MACHINE] = {machine, {.Inspect, .Stop}}
	grants[op.CONTEXT_LOG] = log_grant("shortage")
	amounts := system.Budget_Amounts {
		pages       = own.pages - SHORTAGE_KEEP,
		programs    = 1,
		threads     = 8,
		processor   = own.processor,
		log_records = 1000,
	}
	if _, status := system.program_start(system.image_find(image, "shortage"), "shortage", grants, random.values_with_seed(&program_generator, {}), amounts, nil, &prepared); status != .Ok {
		system.log("root: cannot start shortage: status ", u64(status))
		system.call(.Machine_Stop, u64(machine), 1)
	}
	system.log("root: started shortage with ", amounts.pages, " pages")
	for {
		system.sleep(max(u64))
	}
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
	show(string(message.bytes[:message.count]), .Failed, screen_data.step)
	system.log("root: the boot display shows the failure")
	for {
		system.sleep(max(u64))
	}
}

// The random generator of the root service: its seed comes from the
// sources of the processor (support/random/entropy.odin), not from a
// starter. It gives the seed of each program that root starts.
program_generator: random.Generator
entropy_report: random.Entropy_Report

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
	// The random seed of the system: before the first program starts.
	{
		seed := random.entropy_gather(random.sources_of_the_processor(), &entropy_report)
		if !random.generator_seed(&program_generator, &seed, entropy_report.strength) {
			// BLAKE3 does not give 32 zero bytes in practice; if it does, root
			// says why it cannot start a program, instead of a stop at its
			// first draw.
			fail("the random seed of the system is 32 zero bytes: no program can get a seed", .Bad_Operation)
		}
		report := &entropy_report
		system.log("root: the random seed of the system, strength ", random.seed_strength_names[report.strength], ": rdseed ", report.rdseed_present ? "present" : "absent", ", ", u64(report.rdseed_good), " good values, ", u64(report.rdseed_refused), " refused; rdrand ", report.rdrand_present ? "present" : "absent", ", ", u64(report.rdrand_good), " good, ", u64(report.rdrand_refused), " refused; the cycle counter, ", u64(report.jitter_samples), " samples, ", u64(report.jitter_distinct), " distinct low bytes")
	}
	// The machine of the test of the shortage of frames: its boot image has
	// the program shortage and no input service, so no desktop.
	if len(system.image_find(image, "input")) == 0 && len(system.image_find(image, "shortage")) != 0 {
		shortage_start(ctx)
	}
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
	// The settings page and the glyph cache, before the first boot display.
	text_settings_create()
	date_page_create()
	show("the root service starts input", .Running, .Input)
	{
		table: rawptr
		replacement_memory, status = system.memory_create(1)
		if status == .Ok {
			table, status = system.memory_map(replacement_memory)
		}
		if status != .Ok {
			fail("cannot create the replacement table", status)
		}
		replacement_table = (^system.Replacement_Table)(table)
	}

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
		_, status = system.program_start(system.image_find(image, "input"), "input", grants, random.values_with_seed(&program_generator, {}), budget_of("input"), nil, &prepared)
		if status != .Ok {
			fail("cannot start input", status)
		}
		for grant in grants[1:4] {
			system.close(grant.handle)
		}
	}

	show("the root service starts the compositor", .Running, .Compositor)
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
		// The compositor is also a service (programs/compositor/exports.odin):
		// a service ring and its own file, as start() gives to a service.
		// Its values 0 to 3 are the screen, so the file is at values 4 and 5.
		// The file, two pointer themes, the settings page, five glyph caches, the date page.
		mappings: [12]system.Mapping
		mapping_count := 0
		served := &started[0]
		served^ = {}
		for &item in system.image_entries(image) {
			if system.name_of(item.name[:]) == "compositor" && item.offset % system.PAGE_SIZE == 0 && item.offset <= u64(len(image)) && item.size <= u64(len(image)) - item.offset {
				served.service_memory, served.service, status = system.ring_create()
				if status != .Ok {
					fail("cannot create a ring", status)
				}
				grants[system.GRANT_SERVICE] = {served.service_memory, {.Read, .Write}}
				values[COMPOSITOR_VALUE_FILE_ADDRESS] = isolated.FILE_ADDRESS
				values[COMPOSITOR_VALUE_FILE_SIZE] = item.size
				mappings[0] = {memory = image_memory, address = isolated.FILE_ADDRESS, first = item.offset / system.PAGE_SIZE, page_count = (item.size + system.PAGE_SIZE - 1) / system.PAGE_SIZE}
				mapping_count = 1
				served.hash = item.hash
			}
		}
		// The pointer themes: resources of the boot image, read-only, each
		// at its place in the list of pointer_theme_choice (the values 6 and
		// 7, then the two values of contract:operation). The setting "pointer_theme" of the person
		// chooses one in the compositor.
		for name, index in pointer_theme_choice() {
			address := POINTER_THEME_ADDRESS + u64(index) * POINTER_THEME_SPACING
			if mapping, size, given := resource_mapping(name, address, "compositor"); given {
				places := COMPOSITOR_POINTER_THEME_VALUES[index]
				values[places[0]] = address
				values[places[1]] = size
				mappings[mapping_count] = mapping
				mapping_count += 1
			}
		}
		text_settings_give(mappings[:], &mapping_count, &values)
		date_page_give(mappings[:], &mapping_count, &values)
		compositor, status = system.program_start(system.image_find(image, "compositor"), "compositor", grants, random.values_with_seed(&program_generator, values), budget_of("compositor"), mappings[:mapping_count], &prepared)
		if status != .Ok {
			fail("cannot start the compositor", status)
		}
		// Its place in the table of the programs that this service started: a
		// connection to it finds it there by its name.
		served.program = compositor
		copy(served.name[:len(served.name) - 1], "compositor")
	}

	// The date: the program `date` reads the real-time clock. The programs
	// that start before it writes the page read no date until then.
	if status = start("date"); status != .Ok {
		system.log_in("programs", .Warning, "root: cannot start date: the system has no date")
	}
	if status = start("console"); status != .Ok {
		fail("cannot start the console", status)
	}
	// The settings that the person kept (text_settings.odin).
	settings_boot_pass_start()

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
				// A program with the grant Connect only: Connect to the
				// services of callable_of, and Disconnect.
				command := system.Root_Command(record.kind)
				if .Root_Ring not_in grants_of(system.name_of(item.name[:])) && command != .Disconnect && (command != .Connect || !may_connect(system.name_of(item.name[:]), system.name_of(name[:]))) {
					command = .None
					result = .No_Right
				}
				#partial switch command {
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
				case .Replace:
					result = replace(&item, system.name_of(name[:]), record.values[4])
				case .Stop:
					result = .Bad_Handle
					for &other in started {
						// The compositor is not a program that a person stops.
						if other.program != 0 && other.program != compositor && !other.is_terminal && system.name_of(other.name[:]) == system.name_of(name[:]) {
							system.call(.Program_Stop, u64(other.program), 0)
							result = .Ok
							break
						}
					}
				}
				if result != .Ok {
					completion.values = refusal(system.Root_Command(record.kind), system.name_of(name[:]), record.values[4], result)
				}
				completion.kind = u32(result)
				system.send(&item.requests.completions, completion)
			}
		}
		reap()
		network_answers(&wait)
		system.wait_records(&wait, &control.completions)
		for &item in started {
			if item.program != 0 && item.requests.head != nil {
				system.wait_records(&wait, &item.requests.commands)
			}
		}
		system.wait_end(&wait)
	}
}

// refusal gives the error record of a command of the root ring that this
// service refused, in the values of its completion. As the kernel does
// (kernel/diagnose.odin), it reads the state again after the refusal, and
// names a cause only when the state shows it now: else the record is
// Refused, with the status. The record names the argument of the caller,
// and no fact of another program that the status does not give.
refusal :: proc "contextless" (command: system.Root_Command, name: string, value: u64, status: system.Status) -> [7]u64 {
	kind := u32(command)
	if command == .None || command > max(system.Root_Command) {
		return errors.ring_fail(kind, .Unsupported, .None, 0, i64(kind))
	}
	if status == .No_Right {
		if command == .Connect {
			return errors.ring_fail(kind, .No_Grant, .Connection, 1)
		}
		return errors.ring_fail(kind, .No_Grant, .Root_Commands)
	}
	of_the_system := name == "root" || name == "input" || name == "compositor" || name == "terminal" || name == "block" || name == "frame"
	#partial switch command {
	case .Start:
		if status == .Bad_Operation && of_the_system {
			return errors.ring_fail(kind, .Reserved, .None, 1)
		}
		if status == .Bad_Operation && len(system.image_find(image, name)) == 0 {
			return errors.ring_fail(kind, .Absent, .Modules, 1)
		}
	case .Stop:
		if status == .Bad_Handle && (name == "compositor" || name == "terminal") {
			return errors.ring_fail(kind, .Reserved, .None, 1)
		}
		if status == .Bad_Handle && find(name) == nil {
			return errors.ring_fail(kind, .Absent, .Programs, 1)
		}
	case .Connect:
		if status == .Bad_Handle {
			return errors.ring_fail(kind, .Absent, .Services, 1)
		}
		if status == .No_Slot {
			return errors.ring_fail(kind, .Full, .Connections, 0, 0, isolated.SERVICE_CONNECTION_CAPACITY)
		}
	case .Disconnect:
		if status == .Bad_Handle {
			return errors.ring_fail(kind, .Absent, .Connections, 1)
		}
	case .Grants:
		if status == .Bad_Handle && find(name) == nil {
			return errors.ring_fail(kind, .Absent, .Programs, 1)
		}
	case .Revoke:
		switch {
		case status == .Bad_Handle && find(name) == nil:
			return errors.ring_fail(kind, .Absent, .Programs, 1)
		case status == .Bad_Operation:
			return errors.ring_fail(kind, .Bad_Value, .None, 2, i64(min(value, 1 << 62)), i64(max(system.Root_Grant)))
		case status == .Bad_State:
			return errors.ring_fail(kind, .Absent, .Grants, 2)
		}
	case .Replace:
		entries := system.image_entries(image)
		switch {
		case status == .Bad_Handle && value > u64(len(entries)):
			return errors.ring_fail(kind, .Bad_Value, .None, 2, i64(min(value, 1 << 62)), i64(len(entries)))
		case status == .Bad_Handle && len(system.image_find(image, name)) == 0:
			return errors.ring_fail(kind, .Absent, .Modules, 1)
		case status == .Bad_Operation:
			return errors.ring_fail(kind, .Bad_Value, .None, 2, i64(value)) // A module does not replace itself.
		case status == .No_Slot:
			return errors.ring_fail(kind, .Full, .Records, 0, 0, system.REPLACEMENT_CAPACITY)
		}
	}
	return errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(status))
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
	if len(file) == 0 || name == "root" || name == "input" || name == "compositor" || name == "terminal" || name == "block" || name == "frame" {
		return .Bad_Operation
	}
	role := grants_of(name)
	// A program with an endpoint: the network service starts first.
	if .Network in role {
		network_service() or_return
	}
	// A program with a store: the storage service starts first.
	if .Store in role && .Person not_in role {
		running := false
		for &item in started {
			if item.program != 0 && item.service.head != nil && system.name_of(item.name[:]) == "storage" {
				running = true
			}
		}
		if !running {
			start("storage") or_return
		}
	}
	// A client of a block service: the service of its disk starts first.
	driver: ^Started
	block_ring: system.Handle
	if .Data_Disk in role || .Scratch_Disk in role {
		status: system.Status
		driver, block_ring, status = driver_start(.Data_Disk in role ? pci.DATA_DISK_DEVICE : pci.SCRATCH_DISK_DEVICE)
		if status != .Ok {
			return status
		}
	} else if .Network_Device in role {
		status: system.Status
		driver, block_ring, status = driver_start(pci.NETWORK_DEVICE, DRIVER_FRAME)
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
		grants[.Network_Device in role ? frame.GRANT_RING : block.GRANT_RING] = {block_ring, {.Read, .Write}}
	}
	values: [op.CONTEXT_VALUES]u64
	if name == "randomness" {
		// The facts of the seed of the system, that only this service has:
		// the program shows them (docs/RANDOMNESS.md). Facts, not the seed.
		random.report_values_write(&entropy_report, &values)
	}
	grants[op.CONTEXT_LOG] = log_grant(name)
	copy(slot.name[:len(slot.name) - 1], name) // The connection to the storage service names the program.
	// The connection to the private store, in the context: the call ring, the
	// call region, the storage service with the right Read, and its file.
	// The storage file, the date page, the settings page, five glyph caches, the file of a service.
	mappings: [12]system.Mapping
	mapping_count := 0
	// This service closes its handles of the connection after the start.
	store_ring, store_region: system.Handle
	defer if store_ring != 0 {
		system.close(store_ring)
		system.close(store_region)
	}
	if .Store in role && .Person not_in role {
		storage_service: ^Started
		store_status: system.Status
		_, storage_service, store_ring, store_region, store_status = connection_open(slot, "storage")
		if store_status != .Ok {
			if driver != nil {
				system.call(.Program_Stop, u64(driver.program), 0)
			}
			slot^ = {}
			return store_status
		}
		grants[storage.GRANT_RING] = {store_ring, {.Read, .Write}}
		grants[storage.GRANT_REGION] = {store_region, {.Read, .Write}}
		grants[storage.GRANT_SERVICE] = {storage_service.program, {.Read}}
		for &item in system.image_entries(image) {
			if system.name_of(item.name[:]) == "storage" && item.offset % system.PAGE_SIZE == 0 && item.offset <= u64(len(image)) && item.size <= u64(len(image)) - item.offset {
				values[storage.VALUE_FILE_SIZE] = item.size
				mappings[mapping_count] = {memory = image_memory, address = storage.FILE_ADDRESS, first = item.offset / system.PAGE_SIZE, page_count = (item.size + system.PAGE_SIZE - 1) / system.PAGE_SIZE}
				mapping_count += 1
			}
		}
	}

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
	if .Root_Ring in role || .Connect in role {
		slot.requests_memory, slot.requests, status = system.ring_create()
		grants[system.GRANT_ROOT] = {slot.requests_memory, {.Read, .Write}}
	}
	if .Network_Device in role && status == .Ok {
		slot.network_memory, slot.network, status = system.ring_create()
		grants[datagram.SERVICE_CONTROL] = {slot.network_memory, {.Read, .Write}}
	}
	// This service closes its handles of the endpoint after the start.
	endpoint_ring, endpoint_region: system.Handle
	defer if endpoint_ring != 0 {
		system.close(endpoint_ring)
		system.close(endpoint_region)
	}
	if .Network in role && status == .Ok {
		endpoint_ring, endpoint_region, status = endpoint_open(slot, name)
		grants[datagram.GRANT_RING] = {endpoint_ring, {.Read, .Write}}
		grants[datagram.GRANT_REGION] = {endpoint_region, {.Read, .Write}}
	}
	// One Machine handle; each role receives a part of its rights.
	machine_rights: system.Rights
	if .Inspect in role {
		machine_rights += {.Inspect}
	}
	if .Stop in role {
		machine_rights += {.Stop}
	}
	if .Schedule in role {
		machine_rights += {.Schedule}
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
	if .Replacements in role {
		grants[system.GRANT_REPLACEMENTS] = {replacement_memory, {.Read}}
	}
	if .Settings in role {
		grants[settings.GRANT_PAGE] = {settings_memory, {.Read, .Write}}
		values[settings.VALUE_BOOT_PASS] = u64(settings_boot_pass)
	}
	clock_ports: system.Handle
	defer if clock_ports != 0 {
		system.close(clock_ports)
	}
	if .Clock in role {
		grants[date.GRANT_PAGE] = {date_memory, {.Read, .Write}}
		results, ports_status := system.call(.Device_Create, u64(machine), u64(op.Device_Kind.Ports), 0x70, 2)
		if ports_status == .Ok {
			clock_ports = system.Handle(results[0])
			grants[date.GRANT_PORTS] = {clock_ports, {}}
		}
	}
	// Each program: the date page, read-only.
	date_page_give(mappings[:], &mapping_count, &values)
	// A program with a surface: the settings page and the glyph cache, read-only.
	if .Terminal not_in role {
		text_settings_give(mappings[:], &mapping_count, &values)
	}
	// A service: the service ring, and its own file, to read the
	// descriptions of its exports.
	if .Serve in role && status == .Ok && entry.offset % system.PAGE_SIZE == 0 {
		slot.service_memory, slot.service, status = system.ring_create()
		grants[system.GRANT_SERVICE] = {slot.service_memory, {.Read, .Write}}
		values[system.GRANT_VALUE_FILE_ADDRESS] = isolated.FILE_ADDRESS
		values[system.GRANT_VALUE_FILE_SIZE] = entry.size
		mappings[mapping_count] = {memory = image_memory, address = isolated.FILE_ADDRESS, first = entry.offset / system.PAGE_SIZE, page_count = (entry.size + system.PAGE_SIZE - 1) / system.PAGE_SIZE}
		mapping_count += 1
	}
	load_error: module.Load_Error
	if status == .Ok {
		slot.program, status = system.program_start(file, name, grants, random.values_with_seed(&program_generator, values), budget_of(name), mappings[:mapping_count], &prepared, load_source(), &load_error)
	}
	if status != .Ok {
		if load_error.stage != .None {
			buffer: [512]u8
			writer := system.Writer{buffer = buffer[:]}
			system.load_error_text(&writer, &load_error)
			system.log_in("programs", .Warning, "root: cannot start ", name, ": ", system.written(&writer))
		} else {
			system.log_in("programs", .Warning, "root: cannot start ", name, ": status ", u64(status))
		}
		release(slot)
		if driver != nil {
			system.call(.Program_Stop, u64(driver.program), 0)
		}
		return status
	}
	slot.driver = driver
	slot.hash = entry.hash
	slot.granted += {.Log}
	if machine_rights != {} {
		slot.granted += {.Machine}
	}
	if .Image in role {
		slot.granted += {.Image}
	}
	if .Log_Records in role {
		slot.granted += {.Log_Records}
	}
	if .Network in role {
		slot.granted += {.Network}
	}
	if .Person in role {
		slot.granted += {.Person}
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
	case .Store:
		// The store is data of the storage service: the root service tells it
		// on its service ring that the grant of each connection changed.
		count: u64
		for &connection in connections {
			if connection.caller != item || system.name_of(connection.service.name[:]) != "storage" {
				continue
			}
			person := grant_for(item, connection.service) & isolated.CALLER_PERSON
			if !system.send(&connection.service.service.commands, ring.Record{kind = u32(isolated.Service_Command.Grant), values = {0 = u64(connection.ring), 6 = person}}) {
				return .No_Slot
			}
			count += 1
		}
		item.granted -= {which}
		item.revoked += {which}
		values[0] = count
		system.log_in("programs", .Info, "root: revoked the grant store of ", name, ", connections changed: ", count)
		return .Ok
	case .Person:
		// The grant is data of each service that the program is connected
		// to: the root service tells each one that the grant of the
		// connection changed. A new connection has no grant to act for the
		// person either (grant_for).
		item.granted -= {which}
		item.revoked += {which}
		count: u64
		for &connection in connections {
			if connection.caller != item {
				continue
			}
			if system.send(&connection.service.service.commands, ring.Record{kind = u32(isolated.Service_Command.Grant), values = {0 = u64(connection.ring), 6 = grant_for(item, connection.service)}}) {
				count += 1
			}
		}
		values[0] = count
		system.log_in("programs", .Info, "root: revoked the grant person of ", name, ", connections changed: ", count)
		return .Ok
	case .Network:
		// The endpoint is data of the network service, as a store is data of
		// the storage service: the network service ends the grant.
		count := endpoint_revoke(item)
		item.granted -= {which}
		item.revoked += {which}
		values[0] = count
		system.log_in("programs", .Info, "root: revoked the grant network of ", name, ", endpoints changed: ", count)
		return .Ok
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

// replace changes the replacement table of the machine, for a program with
// the role Replace: where a module imports the module `name`, the loaders
// give the module of entry `by` of the boot image (from 1). 0 removes the
// record. It refuses a chain: one replacement for one import, so a loader
// never follows two records.
replace :: proc "contextless" (asker: ^Started, name: string, by: u64) -> system.Status {
	if .Replace not_in grants_of(system.name_of(asker.name[:])) {
		return .No_Right
	}
	entries := system.image_entries(image)
	from, to: [32]u8
	from_name := ""
	for &entry in entries {
		if system.name_of(entry.name[:]) == name {
			from = entry.hash
			from_name = system.name_of(entry.name[:])
		}
	}
	if from == {} || by > u64(len(entries)) {
		return .Bad_Handle
	}
	if by != 0 {
		to = entries[by - 1].hash
		if to == from {
			return .Bad_Operation
		}
		for item in system.replacements_read(replacement_table, &replacement_records) {
			if item.from == to || item.to == from {
				return .Bad_State
			}
		}
	}
	system.replacements_write(replacement_table, from, to) or_return
	if by == 0 {
		system.log_in("programs", .Info, "root: no replacement of ", from_name)
	} else {
		system.log_in("programs", .Info, "root: ", system.name_of(entries[by - 1].name[:]), " replaces ", from_name, " in each load that follows")
	}
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
	// The settings page and five glyph caches.
	mappings: [8]system.Mapping
	mapping_count := 0
	text_settings_give(mappings[:], &mapping_count, &values)
	program, status := system.program_start(system.image_find(image, "terminal"), "terminal", grants, random.values_with_seed(&program_generator, values), budget_of("terminal"), mappings[:mapping_count], &prepared)
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
	free, service, ring_memory, region_memory := connection_open(caller, name) or_return
	defer system.close(ring_memory)
	defer system.close(region_memory)
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

// connection_open makes the service side of a connection from a caller to
// the service with a name, and starts the service if it starts on demand.
// It gives the call ring and the call region: give them to the caller,
// then close them.
connection_open :: proc "contextless" (caller: ^Started, name: string) -> (free: ^Connection, service: ^Started, ring_memory, region_memory: system.Handle, status: system.Status) {
	for pass in 0 ..< 2 {
		for &item in started {
			if item.program != 0 && item.service.head != nil && system.name_of(item.name[:]) == name {
				service = &item
			}
		}
		if service != nil || pass == 1 || !on_demand(name) {
			break
		}
		if status = start(name); status != .Ok {
			return nil, nil, 0, 0, status
		}
	}
	if service == nil || service == caller {
		return nil, nil, 0, 0, .Bad_Handle
	}
	count := 0
	for &connection in connections {
		if connection.caller == nil {
			free = &connection
		} else if connection.service == service {
			count += 1
			if connection.caller == caller {
				return nil, nil, 0, 0, .Bad_State
			}
		}
	}
	if free == nil || count == isolated.SERVICE_CONNECTION_CAPACITY {
		return nil, nil, 0, 0, .No_Slot
	}
	// The service ring keeps room for one Disconnect for each connection:
	// this service never waits for a service that does not read its ring.
	names := &service.service.commands
	if ring.capacity(names) - ring.count(names) < u32(count) + 2 {
		return nil, nil, 0, 0, .No_Slot
	}
	ring_memory = system.memory_create(ring.PAGE_COUNT) or_return
	region_memory, status = system.memory_create(isolated.REGION_PAGES)
	in_service_ring, in_service_region: system.Handle
	if status == .Ok {
		in_service_ring, status = system.give(service.service_memory, ring_memory, {.Read, .Write})
	}
	if status == .Ok {
		in_service_region, status = system.give(service.service_memory, region_memory, {.Read, .Write})
	}
	if status != .Ok {
		system.close(ring_memory)
		if region_memory != 0 {
			system.close(region_memory)
		}
		return nil, nil, 0, 0, status
	}
	caller_name := system.name_pack(system.name_of(caller.name[:]))
	grant := grant_for(caller, service)
	if !system.send(&service.service.commands, ring.Record{kind = u32(isolated.Service_Command.Connect), values = {0 = u64(in_service_ring), 1 = u64(in_service_region), 2 = caller_name[0], 3 = caller_name[1], 4 = caller_name[2], 5 = caller_name[3], 6 = grant}}) {
		system.close(ring_memory)
		system.close(region_memory)
		return nil, nil, 0, 0, .No_Slot
	}
	if grant & isolated.CALLER_AMOUNT_MASK != 0 {
		caller.granted += {.Store}
	}
	free^ = {
		caller  = caller,
		service = service,
		ring    = in_service_ring,
		region  = in_service_region,
	}
	return free, service, ring_memory, region_memory, .Ok
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
	endpoint_close(item)
	if item.network.head != nil {
		network_end(item)
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
