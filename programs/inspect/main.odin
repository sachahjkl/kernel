// A developer tool: the memory and the execution of one program, live
// (docs/TOOLS.md).
//
// The person chooses a program in the list at the left: up and down, a
// click, or letters that filter the list. The window shows the address
// space of the program as one band and a table, its modules, its threads
// with the state of the scheduler, and the stop report of a program that
// stopped on a fault, each address as "module + offset". A sample of the
// reports of the kernel comes each 250 ms; a value that changed is drawn in
// the color of the boot program for one sample. Space freezes the sample.
// Tab shows the bytes of the memory of this program itself (hex.odin).
//
// The program holds the machine with the right Inspect and the boot image
// (the names of the modules and their exports), and nothing more: it reads
// reports, it changes nothing, and it reads no byte of another program.
// It also serves the same facts as tables (exports.odin).
package inspect

import op "contract:operation"
import "support:addresses"
import "support:display"
import "support:system"

SAMPLE_INTERVAL :: 250 // Milliseconds.
KEY_TAB :: 0x0F
FILTER_CAPACITY :: 24
PROGRAM_SLOTS :: 64 // The program slots of the kernel (System_Report.program_slots).

Entry :: struct {
	slot:  u64,
	name:  [32]u8,
	state: op.Program_State,
}

// One sample: the reports of the kernel at one time.
Sample :: struct {
	slot:         u64, // The program of the sample. 0: none.
	program:      op.Program_Report,
	mappings:     op.Program_Mapping_Report,
	modules:      op.Module_Report,
	threads:      op.Thread_Table_Report,
	stop:         op.Stop_Report,
	nanoseconds:  u64, // The time of the sample.
	entries:      u64, // Its kernel entries.
	time:         u64, // When it was taken, in milliseconds.
}

machine: system.Handle
image: []u8
entries: [PROGRAM_SLOTS]Entry
entry_count: int
shown: [PROGRAM_SLOTS]int // The indexes in entries that the filter keeps.
shown_count: int
filter: [FILTER_CAPACITY]u8
filter_count: int
selected: [32]u8 // The name of the chosen program: it stays chosen when its slot changes.
current, previous: Sample
frozen: bool
hex_view: bool
samples: u64
logged_slot: u64 // The program whose counts the log has.

inspect_call :: proc "contextless" (kind: op.Inspect_Kind, index: u64, record: rawptr, size: int) -> bool {
	_, status := system.call(.Inspect, u64(machine), u64(kind), index, u64(uintptr(record)), u64(size))
	return status == .Ok
}

// slot_of gives the slot of the program with a name, or 0.
slot_of :: proc "contextless" (name: string) -> u64 {
	for slot in 1 ..< u64(PROGRAM_SLOTS) {
		report: op.Program_Report
		if inspect_call(.Program, slot, &report, size_of(report)) && report.state != .None && system.name_of(report.name[:]) == name {
			return slot
		}
	}
	return 0
}

// list_read reads the programs of the machine, and keeps the ones that the
// filter keeps.
list_read :: proc "contextless" () {
	entry_count = 0
	for slot in 1 ..< u64(PROGRAM_SLOTS) {
		report: op.Program_Report
		if !inspect_call(.Program, slot, &report, size_of(report)) || report.state == .None {
			continue
		}
		entries[entry_count] = {slot = slot, name = report.name, state = report.state}
		entry_count += 1
	}
	shown_count = 0
	typed := string(filter[:filter_count])
	for &entry, index in entries[:entry_count] {
		if contains(system.name_of(entry.name[:]), typed) {
			shown[shown_count] = index
			shown_count += 1
		}
	}
}

contains :: proc "contextless" (text, part: string) -> bool {
	if len(part) == 0 {
		return true
	}
	for start in 0 ..= len(text) - min(len(part), len(text)) {
		if len(text) - start >= len(part) && text[start:][:len(part)] == part {
			return true
		}
	}
	return false
}

// sample_take reads each report of the chosen program.
sample_take :: proc "contextless" () {
	start := system.nanoseconds()
	before := system.kernel_entries()
	previous = current
	list_read()
	slot := u64(0)
	for &entry in entries[:entry_count] {
		if entry.name == selected {
			slot = entry.slot
		}
	}
	current.slot = slot
	if slot != 0 {
		inspect_call(.Program, slot, &current.program, size_of(current.program))
		inspect_call(.Program_Mappings, slot, &current.mappings, size_of(current.mappings))
		inspect_call(.Modules, slot, &current.modules, size_of(current.modules))
		inspect_call(.Threads, slot, &current.threads, size_of(current.threads))
		inspect_call(.Stop, slot, &current.stop, size_of(current.stop))
	}
	current.nanoseconds = system.nanoseconds() - start
	current.entries = system.kernel_entries() - before
	current.time = system.time()
	samples += 1
	if slot != 0 && slot != logged_slot {
		logged_slot = slot
		sample_log()
	}
}

// sample_log writes the counts of the chosen program on the log, one time
// for each choice: the test compares them with the reports of monitor.
sample_log :: proc "contextless" () {
	name := system.name_of(current.program.name[:])
	present: u64
	pages: u64
	for &mapping in current.mappings.mappings[:current.mappings.count] {
		pages += mapping.page_count
		present += mapping.present
	}
	system.log("inspect: ", name, ": ", current.mappings.count, " mappings, ", pages, " mapped pages, ", present, " with a frame, ", current.threads.count, " threads, ", current.modules.count, " modules; the kernel says ", current.program.mapped_pages, " mapped pages and ", current.program.thread_count, " threads")
	system.log("inspect: one sample of ", name, " took ", current.nanoseconds / 1000, " us and ", current.entries, " kernel entries")
	if current.stop.code != 0 {
		buffer: [512]u8
		writer := system.Writer{buffer = buffer[:]}
		stop_write(&writer, &current.stop)
		system.log("inspect: ", name, " stopped: ", system.written(&writer))
	}
}

// address_write writes an address as "module + offset" when a module record
// of the chosen program holds it, else as a number.
address_write :: proc "contextless" (writer: ^system.Writer, address: u64, near := false) {
	modules := current.modules.modules[:min(current.modules.count, op.PROGRAM_MODULE_CAPACITY)]
	index, offset := addresses.module_of(address, modules)
	if index < 0 {
		system.write_number(writer, address)
		return
	}
	record := &modules[index]
	file := module_file(record.hash)
	if entry := system.image_entry_of(image, record.hash); entry != nil {
		system.write_part(writer, system.name_of(entry.name[:]))
	} else {
		system.write_hash(writer, record.hash)
	}
	system.write_part(writer, " + ")
	system.write_number(writer, offset)
	if near && file != nil {
		if name, distance, ok := addresses.near_export(file, record.base, address); ok {
			system.write_part(writer, ", near ")
			system.write_part(writer, name)
			if distance != 0 {
				system.write_part(writer, " + ")
				system.write_number(writer, distance)
			}
		}
	}
}

// module_file gives the file of a module of the boot image, by its hash.
module_file :: proc "contextless" (hash: [32]u8) -> []u8 {
	entry := system.image_entry_of(image, hash)
	if entry == nil || entry.offset > u64(len(image)) || entry.size > u64(len(image)) - entry.offset {
		return nil
	}
	return image[entry.offset:][:entry.size]
}

// stop_write writes a stop report: the vector, the address, and each frame.
stop_write :: proc "contextless" (writer: ^system.Writer, stop: ^op.Stop_Report) {
	system.write_part(writer, stop.vector == 14 ? "page fault at " : "fault ")
	system.write_number(writer, stop.address)
	system.write_part(writer, "; stack: ")
	for &frame, number in stop.frames[:min(stop.frame_count, op.STOP_FRAME_CAPACITY)] {
		system.write_part(writer, number == 0 ? "" : ", ")
		address_write(writer, frame.address, true)
	}
}

choose :: proc "contextless" (position: int) {
	if position < 0 || position >= shown_count {
		return
	}
	selected = entries[shown[position]].name
	frozen = false
	sample_take()
}

position_of_selected :: proc "contextless" () -> int {
	for position in 0 ..< shown_count {
		if entries[shown[position]].name == selected {
			return position
		}
	}
	return -1
}

key :: proc "contextless" (event: display.Event) {
	switch {
	case event.code == display.KEY_UP:
		choose(max(position_of_selected() - 1, 0))
	case event.code == display.KEY_DOWN:
		choose(min(position_of_selected() + 1, shown_count - 1))
	case event.code == KEY_TAB:
		hex_view = !hex_view
		system.log("inspect: ", hex_view ? "the bytes of the memory of inspect" : "the reports of ", hex_view ? "" : system.name_of(selected[:]))
	case event.character == ' ':
		frozen = !frozen
		system.log("inspect: the sample is ", frozen ? "frozen" : "live")
	case event.code == display.KEY_BACKSPACE:
		filter_count = max(filter_count - 1, 0)
		list_read()
	case event.code == display.KEY_ENTER:
		choose(0)
	case event.character >= 'a' && event.character <= 'z' || event.character == '_' || event.character >= '0' && event.character <= '9':
		if filter_count < FILTER_CAPACITY {
			filter[filter_count] = event.character
			filter_count += 1
		}
		list_read()
		if position_of_selected() < 0 {
			choose(0)
		}
	}
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "inspect")
	if !ok {
		system.stop(1)
	}
	machine = ctx.handles[system.GRANT_MACHINE]
	if address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {}); status == .Ok {
		image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	}
	service, _ = system.service_open(ctx)
	hex_start()
	// The first program: this one, until the person chooses.
	copy(selected[:], "inspect")
	sample_take()
	system.log("inspect: ok, ", u64(entry_count), " programs; up, down, letters: choose; space: freeze; tab: the bytes of its own memory")
	for {
		draw(&window)
		next := current.time + SAMPLE_INTERVAL
		for {
			wait: system.Wait
			display.wait_events(&wait, &window)
			system.service_wait(&wait, &service)
			now := system.wait_end(&wait, next)
			system.service_run(&service)
			changed := false
			for event in display.next_event(&window) {
				if event.kind == .Key && event.pressed {
					key(event)
					changed = true
				} else if event.kind == .Pointer && event.buttons & display.BUTTON_LEFT != 0 {
					if position, inside := list_place(event.x, event.y); inside {
						choose(position)
						changed = true
					}
				}
			}
			if changed {
				draw(&window)
			}
			if now >= next {
				break
			}
		}
		if !frozen {
			sample_take()
		} else {
			list_read()
			current.time = system.time()
		}
	}
}
