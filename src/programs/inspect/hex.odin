package inspect

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/system"

// The bytes of the memory of this program itself (docs/TOOLS.md): the
// reports of the kernel give no byte of another program, and this tool has
// no right to read one. 16 bytes in each row, the address as "module +
// offset" in a module, the ASCII at the right, the boundary of each page
// marked. A page with no page frame is shown as such: the tool asks the
// kernel which pages have a frame (Inspect_Kind.Pages), so its read gives no
// frame to a page.

HEX_PAGES :: 4

hex_memory: [^]u8 // HEX_PAGES pages of a memory object: pages on first use.

// hex_start makes the memory of the demonstration: two of its four pages
// get a frame by a write, two stay with no frame.
hex_start :: proc "contextless" () {
	memory, status := system.memory_create(HEX_PAGES)
	if status != .Ok {
		return
	}
	address, map_status := system.memory_map(memory)
	if map_status != .Ok {
		return
	}
	hex_memory = ([^]u8)(address)
	copy(hex_memory[0:system.PAGE_SIZE], "inspect: page 0 of its own memory, written: it has a page frame.")
	copy(hex_memory[2 * system.PAGE_SIZE:][:system.PAGE_SIZE], "inspect: page 2, written too. Pages 1 and 3 were never written.")
}

// hex_present gives which pages from an address have a frame, from the
// page table of this program.
hex_present :: proc "contextless" (address: u64) -> (present, mapped: u64) {
	report := op.Page_Report{address = address &~ (system.PAGE_SIZE - 1)}
	if !inspect_call(.Pages, 0, &report, size_of(report)) {
		return 0, 0
	}
	return report.present, report.mapped
}

// hex_row draws 16 bytes: the address, the bytes, the ASCII. Bytes next to
// each other with one color are one run of text: "41 42 43 " keeps 24
// pixels for each byte.
hex_row :: proc "contextless" (area: interface.Area, y: int, address: u64, bytes: []u8, own: []op.Module_Record) {
	buffer: [64]u8
	writer := system.Writer{buffer = buffer[:]}
	if own != nil && address >= own[0].base && address - own[0].base < own[0].size {
		system.write_part(&writer, "inspect + ")
		system.write_number(&writer, address - own[0].base)
	} else {
		system.write_number(&writer, address)
	}
	write(area, 0, y, system.written(&writer), graphics.COLOR_DIM)
	digits := system.HEX_DIGITS
	HEX_X :: 200
	ASCII_X :: HEX_X + 16 * 24 + 24
	// The pairs, in runs of one color, the two halves of 8 apart.
	for half in 0 ..< 2 {
		start := half * 8
		for start < half * 8 + 8 && start < len(bytes) {
			zero := bytes[start] == 0
			run: [24]u8
			count := 0
			index := start
			for index < half * 8 + 8 && index < len(bytes) && (bytes[index] == 0) == zero {
				run[count], run[count + 1], run[count + 2] = digits[bytes[index] >> 4], digits[bytes[index] & 15], ' '
				count += 3
				index += 1
			}
			write(area, HEX_X + start * 24 + half * 8, y, string(run[:count - 1]), zero ? graphics.COLOR_NOT_USABLE : graphics.COLOR_TEXT)
			start = index
		}
	}
	// The characters, in runs of one color.
	for start := 0; start < len(bytes); {
		printable := bytes[start] >= 32 && bytes[start] < 127
		run: [16]u8
		count := 0
		index := start
		for index < len(bytes) && (bytes[index] >= 32 && bytes[index] < 127) == printable {
			run[count] = printable ? bytes[index] : '.'
			count += 1
			index += 1
		}
		write(area, ASCII_X + start * 8, y, string(run[:count]), printable ? graphics.COLOR_MEMORY : graphics.COLOR_NOT_USABLE)
		start = index
	}
}

draw_hex :: proc "contextless" (frame: ^interface.Frame) {
	inside := card(frame, RIGHT_X, LOW_Y, RIGHT_WIDTH, LOW_HEIGHT, "BYTES OF INSPECT", "its own memory; Inspect_Kind.Pages: which pages have a frame", graphics.COLOR_MEMORY)
	own: op.Module_Report
	own_slot := slot_of("inspect")
	inspect_call(.Modules, own_slot, &own, size_of(own))
	modules := own.modules[:min(own.count, op.PROGRAM_MODULE_CAPACITY)]
	y := 0
	// The first bytes of the code of the export entry of this program.
	code := u64(0)
	if len(modules) > 0 {
		if file := module_file(modules[0].hash); file != nil {
			head, _ := module.header(file)
			if address, ok := module.export_address(file, uintptr(modules[0].base), head.entry_export); ok {
				code = u64(address) &~ 15
			}
		}
	}
	if code != 0 {
		base := code
		present, _ := hex_present(base)
		fill(inside, 0, y + 7, inside.width, 1, graphics.COLOR_TRACK)
		text(inside, 0, y, graphics.COLOR_PROGRAM, "the code of the export entry of inspect: ", present & 1 != 0 ? "it has a page frame" : "no page frame: not read")
		y += LINE
		if present & 1 != 0 {
			for row in 0 ..< 3 {
				address := base + u64(row) * 16
				hex_row(inside, y, address, ([^]u8)(uintptr(address))[:16], modules)
				y += LINE
			}
		}
		y += 8
	}
	if hex_memory == nil {
		write(inside, 0, y, "no memory of the demonstration: Memory_Create failed", graphics.COLOR_FAILED)
		return
	}
	start := u64(uintptr(hex_memory))
	present, _ := hex_present(start)
	for page in 0 ..< u64(HEX_PAGES) {
		address := start + page * system.PAGE_SIZE
		has := present >> page & 1 != 0
		// The boundary of a page: a line and its state.
		fill(inside, 0, y + 7, inside.width, 1, has ? graphics.COLOR_MEMORY : graphics.COLOR_NOT_USABLE)
		buffer: [96]u8
		writer := system.Writer{buffer = buffer[:]}
		system.write_part(&writer, "page ")
		system.write_number(&writer, address)
		system.write_part(&writer, has ? ": it has a page frame " : ": no page frame: the tool does not read it ")
		label := system.written(&writer)
		fill(inside, 0, y, interface.text_width({}, label), LINE, graphics.COLOR_CARD_BOTTOM)
		write(inside, 0, y, label, has ? graphics.COLOR_MEMORY : graphics.COLOR_DIM)
		y += LINE
		if has {
			for row in 0 ..< 3 {
				row_address := address + u64(row) * 16
				hex_row(inside, y, row_address, hex_memory[page * system.PAGE_SIZE + u64(row) * 16:][:16], nil)
				y += LINE
			}
		}
		y += 8
		if y + LINE > inside.height {
			break
		}
	}
}
