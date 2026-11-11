package inspect

import op "contract:operation"
import "support:graphics"
import "support:system"

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

// hex_row draws 16 bytes: the address, the bytes, the ASCII.
hex_row :: proc "contextless" (canvas: graphics.Canvas, y: int, address: u64, bytes: []u8, own: []op.Module_Record) {
	buffer: [64]u8
	writer := system.Writer{buffer = buffer[:]}
	if own != nil && address >= own[0].base && address - own[0].base < own[0].size {
		system.write_part(&writer, "inspect + ")
		system.write_number(&writer, address - own[0].base)
	} else {
		system.write_number(&writer, address)
	}
	graphics.text(canvas, 0, y, system.written(&writer), graphics.COLOR_DIM)
	digits := system.HEX_DIGITS
	x := 200
	for byte, index in bytes {
		pair := [2]u8{digits[byte >> 4], digits[byte & 15]}
		graphics.text(canvas, x + index * 24 + (index >= 8 ? 8 : 0), y, string(pair[:]), byte == 0 ? graphics.COLOR_NOT_USABLE : graphics.COLOR_TEXT)
		character := byte >= 32 && byte < 127 ? byte : '.'
		graphics.character(canvas, x + 16 * 24 + 24 + index * 8, y, character, byte >= 32 && byte < 127 ? graphics.COLOR_MEMORY : graphics.COLOR_NOT_USABLE)
	}
}

draw_hex :: proc "contextless" (canvas: graphics.Canvas) {
	inside := card(canvas, RIGHT_X, LOW_Y, RIGHT_WIDTH, LOW_HEIGHT, "BYTES OF INSPECT", "its own memory; Inspect_Kind.Pages: which pages have a frame", graphics.COLOR_MEMORY)
	own: op.Module_Report
	own_slot := slot_of("inspect")
	inspect_call(.Modules, own_slot, &own, size_of(own))
	modules := own.modules[:min(own.count, op.PROGRAM_MODULE_CAPACITY)]
	y := 0
	// The first bytes of the module of this program.
	if len(modules) > 0 {
		base := modules[0].base
		present, _ := hex_present(base)
		graphics.fill(inside, 0, y + 7, inside.width, 1, graphics.COLOR_TRACK)
		text(inside, 0, y, graphics.COLOR_PROGRAM, "module inspect, page 0: ", present & 1 != 0 ? "it has a frame" : "no frame: not read")
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
		graphics.text(inside, 0, y, "no memory of the demonstration: Memory_Create failed", graphics.COLOR_FAILED)
		return
	}
	start := u64(uintptr(hex_memory))
	present, _ := hex_present(start)
	for page in 0 ..< u64(HEX_PAGES) {
		address := start + page * system.PAGE_SIZE
		has := present >> page & 1 != 0
		// The boundary of a page: a line and its state.
		graphics.fill(inside, 0, y + 7, inside.width, 1, has ? graphics.COLOR_MEMORY : graphics.COLOR_NOT_USABLE)
		buffer: [96]u8
		writer := system.Writer{buffer = buffer[:]}
		system.write_part(&writer, "page ")
		system.write_number(&writer, address)
		system.write_part(&writer, has ? ": it has a page frame " : ": no page frame: the tool does not read it ")
		label := system.written(&writer)
		graphics.fill(inside, 0, y, graphics.text_width(label), LINE, graphics.COLOR_CARD_BOTTOM)
		graphics.text(inside, 0, y, label, has ? graphics.COLOR_MEMORY : graphics.COLOR_DIM)
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
