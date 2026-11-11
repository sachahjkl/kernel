package inspect

import op "contract:operation"
import "support:addresses"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:system"

// The window follows docs/DESIGN.md: cards with a title in the accent of
// their concept and a caption that names their record, rectangles only, the
// grid of 8 pixels, names in the dim color and values in the text color. A
// value that changed since the sample before is in the color of the boot
// program for one sample; a word says the same fact where a color does.

WIDTH :: 1000
HEIGHT :: 704

LINE :: graphics.LINE_HEIGHT
LIST_X :: 8
LIST_Y :: 8
LIST_WIDTH :: 200
LIST_ROWS_Y :: LIST_Y + graphics.CARD_TITLE + 24 // The first row of the list, in the window.
RIGHT_X :: LIST_X + LIST_WIDTH + 8
RIGHT_WIDTH :: WIDTH - RIGHT_X - 8
MAP_HEIGHT :: 336
LOW_Y :: 8 + MAP_HEIGHT + 8
LOW_HEIGHT :: HEIGHT - LOW_Y - 8
MODULES_WIDTH :: 296
BAND_HEIGHT :: 40
FLASH :: graphics.COLOR_BOOT_PROGRAM

// The window is built with the interface package (docs/INTERFACE.md): its
// draw table holds the records of a frame, and a sample that changes few
// values damages only their places.
records_now, records_before: [2048]interface.Draw_Record
text_now, text_before: [32768]u8
drawing: interface.Window_Drawing
frame_table: ^interface.Draw_Table // The table of the frame that draw builds.

kind_color :: proc "contextless" (kind: addresses.Kind) -> graphics.Color {
	switch kind {
	case .Module_Code:
		return graphics.COLOR_PROGRAM
	case .Module_Constants:
		return graphics.shade(graphics.COLOR_PROGRAM, 72)
	case .Module_Data:
		return graphics.shade(graphics.COLOR_PROGRAM, 50)
	case .Thread_Area:
		return graphics.COLOR_KERNEL
	case .Device:
		return graphics.COLOR_MACHINE
	case .Shared:
		return graphics.shade(graphics.COLOR_MEMORY, 140)
	case .Memory:
		return graphics.COLOR_MEMORY
	}
	return graphics.COLOR_NOT_USABLE
}

state_color :: proc "contextless" (state: op.Program_State) -> graphics.Color {
	#partial switch state {
	case .Stopped:
		return graphics.COLOR_FAILED
	case .Created:
		return graphics.COLOR_BOOT_PROGRAM
	}
	return graphics.COLOR_PROGRAM
}

// hash_color gives the color of a module from its hash.
hash_color :: proc "contextless" (hash: [32]u8) -> graphics.Color {
	return graphics.mix(graphics.rgb(u32(hash[0]) | 0x40, u32(hash[1]) | 0x40, u32(hash[2]) | 0x40), graphics.COLOR_TEXT, 64)
}

// text draws parts at (x, y) of an area, and gives the x after them.
text :: proc "contextless" (area: interface.Area, x, y: int, color: graphics.Color, parts: ..system.Part) -> int {
	buffer: [160]u8
	return interface.draw_text(frame_table, area.x + x, area.y + y, system.format(buffer[:], ..parts), color) - area.x
}

// right draws parts that end at x of an area.
right :: proc "contextless" (area: interface.Area, x, y: int, color: graphics.Color, parts: ..system.Part) {
	buffer: [64]u8
	interface.draw_text_right(frame_table, area.x + x, area.y + y, system.format(buffer[:], ..parts), color)
}

// fill draws a rectangle at (x, y) of an area.
fill :: proc "contextless" (area: interface.Area, x, y, width, height: int, color: graphics.Color) {
	interface.draw_rectangle(frame_table, area.x + x, area.y + y, width, height, color)
}

// write draws a text at (x, y) of an area, and gives the x after it.
write :: proc "contextless" (area: interface.Area, x, y: int, characters: string, color: graphics.Color) -> int {
	return interface.draw_text(frame_table, area.x + x, area.y + y, characters, color) - area.x
}

card :: proc "contextless" (frame: ^interface.Frame, x, y, width, height: int, title, caption: string, accent: graphics.Color) -> interface.Area {
	return interface.card(frame, {x, y, width, height}, title, caption, accent)
}

// changed says if a sample of the same program had another value.
changed :: proc "contextless" (now, before: u64) -> bool {
	return previous.slot == current.slot && now != before
}

list_place :: proc "contextless" (x, y: int) -> (position: int, inside: bool) {
	if x < LIST_X || x >= LIST_X + LIST_WIDTH || y < LIST_ROWS_Y {
		return 0, false
	}
	position = (y - LIST_ROWS_Y) / LINE
	return position, position < shown_count
}

draw :: proc "contextless" (window: ^display.Window) {
	if drawing.now.records == nil {
		drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	}
	frame := interface.window_frame_begin(&drawing, window)
	frame_table = frame.table
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	draw_list(&frame)
	if current.slot == 0 {
		inside := card(&frame, RIGHT_X, 8, RIGHT_WIDTH, MAP_HEIGHT, "ADDRESS SPACE", "op.Program_Mapping_Report", graphics.COLOR_MEMORY)
		write(inside, 0, 0, "not known yet: choose a program in the list", graphics.COLOR_DIM)
	} else {
		draw_map(&frame)
	}
	if hex_view {
		draw_hex(&frame)
	} else {
		draw_modules(&frame)
		if current.stop.code != 0 {
			draw_stop(&frame)
		} else {
			draw_threads(&frame)
		}
	}
	damage := interface.window_frame_end(&drawing, &frame, window)
	samples_drawn += 1
	damage_total += u64(damage)
	if display.MEASURE_RUN && samples_drawn == 20 {
		system.log("inspect: the interface: ", u64(drawing.now.record_count), " records; 20 frames with ", damage_total, " damage rectangles in all; the last frame: build ", drawing.build_time / 1000, " us, difference ", drawing.difference_time / 1000, " us, draw ", drawing.draw_time / 1000, " us")
	}
}

samples_drawn, damage_total: u64 // The measure of the damage of the first 20 frames.

draw_list :: proc "contextless" (frame: ^interface.Frame) {
	inside := card(frame, LIST_X, LIST_Y, LIST_WIDTH, HEIGHT - 16, "SLOTS", "Program_Report", graphics.COLOR_PROGRAM)
	x := write(inside, 0, 0, "filter ", graphics.COLOR_DIM)
	x = write(inside, x, 0, string(filter[:filter_count]), graphics.COLOR_TEXT)
	fill(inside, x, 0, 8, 16, graphics.COLOR_TRACK)
	for position in 0 ..< shown_count {
		item := &entries[shown[position]]
		y := 24 + position * LINE
		if y + LINE > inside.height - 80 {
			break
		}
		chosen := item.slot == selected_slot && item.program_serial == selected_program_serial
		if chosen {
			fill(inside, -8, y, inside.width + 8, LINE, graphics.COLOR_TRACK)
			fill(inside, -8, y, 4, LINE, graphics.COLOR_PROGRAM)
		}
		write(inside, 0, y, system.name_of(item.name[:]), chosen ? graphics.COLOR_WHITE : graphics.COLOR_TEXT)
		fill(inside, inside.width - 32, y + 5, 6, 6, state_color(item.state))
		right(inside, inside.width, y, graphics.COLOR_DIM, item.slot)
	}
	// The cost of one sample: measured, not estimated.
	y := inside.height - 64
	text(inside, 0, y, graphics.COLOR_DIM, "one sample")
	right(inside, inside.width, y, graphics.COLOR_TEXT, current.nanoseconds / 1000, " us")
	text(inside, 0, y + LINE, graphics.COLOR_DIM, "kernel entries")
	right(inside, inside.width, y + LINE, graphics.COLOR_TEXT, current.entries)
	text(inside, 0, y + 2 * LINE, graphics.COLOR_DIM, frozen ? "frozen: space" : "4 samples in 1 s", "")
	right(inside, inside.width, y + 2 * LINE, frozen ? FLASH : graphics.COLOR_PROGRAM, frozen ? "frozen" : "live")
	text(inside, 0, y + 3 * LINE, graphics.COLOR_DIM, "tab: bytes")
}

draw_map :: proc "contextless" (frame: ^interface.Frame) {
	name := system.name_of(current.program.name[:])
	buffer: [64]u8
	inside := card(frame, RIGHT_X, 8, RIGHT_WIDTH, MAP_HEIGHT, "ADDRESS SPACE", system.format(buffer[:], "op.Program_Mapping_Report of ", name), graphics.COLOR_MEMORY)
	mappings := current.mappings.mappings[:min(current.mappings.count, op.MAPPING_REPORT_CAPACITY)]
	modules := current.modules.modules[:min(current.modules.count, op.PROGRAM_MODULE_CAPACITY)]
	pages, present, before_present: u64
	for &item in mappings {
		pages += item.page_count
		present += item.present
	}
	for &item in previous.mappings.mappings[:min(previous.mappings.count, op.MAPPING_REPORT_CAPACITY)] {
		before_present += item.present
	}
	x := text(inside, 0, 0, graphics.COLOR_TEXT, u64(len(mappings)))
	x = text(inside, x, 0, graphics.COLOR_DIM, " mappings  ")
	x = text(inside, x, 0, graphics.COLOR_TEXT, pages)
	x = text(inside, x, 0, graphics.COLOR_DIM, " pages mapped  ")
	x = text(inside, x, 0, changed(present, before_present) ? FLASH : graphics.COLOR_MEMORY, present)
	x = text(inside, x, 0, graphics.COLOR_DIM, " with a frame  ")
	x = text(inside, x, 0, state_color(current.program.state), current.program.state == .Stopped ? "stopped" : "runs")
	// The band: each mapping scaled by its pages, each gap folded.
	segments: [2 * op.MAPPING_REPORT_CAPACITY]addresses.Segment
	count := addresses.band(mappings, inside.width, 16, 4, segments[:])
	BAND_Y :: 24
	if len(mappings) == 0 {
		write(inside, 0, BAND_Y + 12, "no mapping: the kernel ended each mapping when the program stopped", graphics.COLOR_DIM)
	}
	for &segment in segments[:count] {
		if segment.mapping < 0 {
			// A folded gap: a part with no measure on this scale.
			interface.draw_folded_gap(frame.table, inside.x + segment.x, inside.y + BAND_Y, segment.width, BAND_HEIGHT)
			continue
		}
		item := mappings[segment.mapping]
		color := kind_color(addresses.kind_of(item, modules))
		width := max(segment.width - 1, 1)
		interface.draw_vertical_gradient(frame.table, inside.x + segment.x, inside.y + BAND_Y, width, BAND_HEIGHT - 6, graphics.shade(color, 125), graphics.shade(color, 78))
		// Under each block: the part of its pages that have a frame.
		fill(inside, segment.x, BAND_Y + BAND_HEIGHT - 4, width, 4, graphics.COLOR_TRACK)
		fill(inside, segment.x, BAND_Y + BAND_HEIGHT - 4, int(u64(width) * item.present / max(item.page_count, 1)), 4, graphics.COLOR_TEXT)
	}
	// The kinds, as a legend.
	x = 0
	for kind in addresses.Kind {
		fill(inside, x, 76, 8, 8, kind_color(kind))
		x = write(inside, x + 12, 72, addresses.KIND_NAMES[kind], graphics.COLOR_DIM) + 8
	}
	// The table: one row for each mapping.
	TABLE_Y :: 96
	write(inside, 0, TABLE_Y, "address", graphics.COLOR_DIM)
	right(inside, 336, TABLE_Y, graphics.COLOR_DIM, "pages")
	write(inside, 352, TABLE_Y, "with a frame", graphics.COLOR_DIM)
	write(inside, 512, TABLE_Y, "kind", graphics.COLOR_DIM)
	write(inside, 656, TABLE_Y, "rights", graphics.COLOR_DIM)
	rows := (inside.height - TABLE_Y - LINE) / LINE
	for &item, number in mappings {
		y := TABLE_Y + LINE + number * LINE
		if number == rows - 1 && len(mappings) > rows {
			text(inside, 0, y, graphics.COLOR_DIM, "and ", u64(len(mappings) - number), " mappings more: inspect.mappings() gives each one")
			break
		}
		writer := system.Writer{buffer = buffer[:]}
		address_write(&writer, item.address)
		kind := addresses.kind_of(item, modules)
		fill(inside, 0, y + 4, 8, 8, kind_color(kind))
		write(inside, 16, y, system.written(&writer), graphics.COLOR_TEXT)
		right(inside, 336, y, graphics.COLOR_TEXT, item.page_count)
		before := u64(0)
		if number < int(previous.mappings.count) && previous.mappings.mappings[number].address == item.address {
			before = previous.mappings.mappings[number].present
		} else {
			before = item.present
		}
		fill(inside, 352, y + 4, 96, 8, graphics.COLOR_TRACK)
		fill(inside, 352, y + 4, int(96 * item.present / max(item.page_count, 1)), 8, graphics.COLOR_MEMORY)
		right(inside, 496, y, changed(item.present, before) ? FLASH : graphics.COLOR_TEXT, item.present)
		write(inside, 512, y, addresses.KIND_NAMES[kind], kind_color(kind))
		rights := [3]u8{'r', .Write in item.flags ? 'w' : '-', .Execute in item.flags ? 'x' : '-'}
		write(inside, 656, y, string(rights[:]), graphics.COLOR_TEXT)
		if .Shared in item.flags {
			write(inside, 696, y, "shared", graphics.COLOR_DIM)
		}
	}
}

draw_modules :: proc "contextless" (frame: ^interface.Frame) {
	inside := card(frame, RIGHT_X, LOW_Y, MODULES_WIDTH, LOW_HEIGHT, "MODULES", "op.Module_Report", graphics.COLOR_PROGRAM)
	if current.slot == 0 {
		return
	}
	for &item, number in current.modules.modules[:min(current.modules.count, op.PROGRAM_MODULE_CAPACITY)] {
		y := number * 2 * LINE
		if y + 2 * LINE > inside.height {
			break
		}
		fill(inside, 0, y + 4, 8, 8, hash_color(item.hash))
		name := "a module with no name"
		if entry := system.image_entry_of(image, item.hash); entry != nil {
			name = system.name_of(entry.name[:])
		}
		write(inside, 16, y, name, graphics.COLOR_TEXT)
		right(inside, inside.width, y, graphics.COLOR_TEXT, item.size / 1024, " KiB")
		writer_buffer: [48]u8
		writer := system.Writer{buffer = writer_buffer[:]}
		system.write_number(&writer, item.base)
		system.write_part(&writer, "  ")
		system.write_hash(&writer, item.hash)
		write(inside, 16, y + LINE, system.written(&writer)[:min(writer.count, (inside.width - 16) / 8)], hash_color(item.hash))
	}
}

draw_threads :: proc "contextless" (frame: ^interface.Frame) {
	x := RIGHT_X + MODULES_WIDTH + 8
	inside := card(frame, x, LOW_Y, WIDTH - 8 - x, LOW_HEIGHT, "THREADS", "op.Thread_Table_Report", graphics.COLOR_KERNEL)
	if current.slot == 0 {
		return
	}
	write(inside, 0, 0, "#", graphics.COLOR_DIM)
	write(inside, 24, 0, "state", graphics.COLOR_DIM)
	write(inside, 96, 0, "runs", graphics.COLOR_DIM)
	right(inside, 200, 0, graphics.COLOR_DIM, "weight")
	right(inside, 272, 0, graphics.COLOR_DIM, "req us")
	right(inside, 360, 0, graphics.COLOR_DIM, "lag")
	right(inside, inside.width, 0, graphics.COLOR_DIM, "time ms")
	for &item, number in current.threads.threads[:min(current.threads.count, op.THREAD_REPORT_CAPACITY)] {
		y := LINE + number * 2 * LINE
		if y + 2 * LINE > inside.height {
			break
		}
		before: op.Thread_Report
		for &other in previous.threads.threads[:min(previous.threads.count, op.THREAD_REPORT_CAPACITY)] {
			if other.number == item.number {
				before = other
			}
		}
		text(inside, 0, y, graphics.COLOR_TEXT, u64(item.number))
		fill(inside, 24, y + 4, 8, 8, item.processor != 0 ? graphics.COLOR_PROGRAM : graphics.COLOR_NOT_USABLE)
		write(inside, 40, y, item.processor != 0 ? "runs" : item.state == .Waiting ? "waits" : "ready", changed(u64(item.state) << 8 | u64(item.processor), u64(before.state) << 8 | u64(before.processor)) ? FLASH : graphics.COLOR_TEXT)
		if item.processor != 0 {
			text(inside, 96, y, graphics.COLOR_TEXT, "cpu ", u64(item.processor - 1))
		} else {
			text(inside, 96, y, graphics.COLOR_DIM, "home ", u64(item.home))
		}
		right(inside, 200, y, graphics.COLOR_TEXT, u64(item.weight))
		right(inside, 272, y, graphics.COLOR_TEXT, u64(item.request))
		right(inside, 360, y, graphics.COLOR_TEXT, item.lag)
		right(inside, inside.width, y, changed(item.run_time, before.run_time) ? FLASH : graphics.COLOR_TEXT, item.run_time)
		// The second line: what the thread waits for, and its virtual time.
		wait := "no wait"
		if item.words != 0 {
			wait = item.deadline != 0 && item.deadline != op.WAIT_FOREVER ? "a word wait, with a deadline" : "a word wait"
		} else if item.queued != 0 {
			wait = "in the run queue"
		}
		x2 := text(inside, 24, y + LINE, graphics.COLOR_DIM, wait, "  virtual ")
		text(inside, x2, y + LINE, graphics.COLOR_DIM, item.virtual)
	}
	if current.threads.count == 0 {
		write(inside, 0, LINE, "no thread: the program ended", graphics.COLOR_DIM)
	}
}

draw_stop :: proc "contextless" (frame: ^interface.Frame) {
	x := RIGHT_X + MODULES_WIDTH + 8
	inside := card(frame, x, LOW_Y, WIDTH - 8 - x, LOW_HEIGHT, "STOP REPORT", "op.Stop_Report: where it stopped", graphics.COLOR_FAILED)
	stop := &current.stop
	buffer: [96]u8
	writer := system.Writer{buffer = buffer[:]}
	system.write_part(&writer, stop.vector == 14 ? "page fault: the address " : "fault: the address ")
	system.write_number(&writer, stop.address)
	if stop.hidden_value_count != 0 {
		system.write_part(&writer, "; values hidden: ")
		system.write_part(&writer, stop.hidden_value_count)
	}
	write(inside, 0, 0, system.written(&writer), graphics.COLOR_FAILED)
	write(inside, 0, LINE + 8, "the stack trace, from the frame pointers:", graphics.COLOR_DIM)
	for &frame, number in stop.frames[:min(stop.frame_count, op.STOP_FRAME_CAPACITY)] {
		y := 2 * LINE + 16 + number * LINE
		if y + LINE > inside.height {
			break
		}
		text(inside, 0, y, graphics.COLOR_DIM, u64(number))
		line := system.Writer{buffer = buffer[:]}
		if frame.address == 0 {
			system.write_part(&line, "not code: the kernel gives no value of this frame")
		} else {
			address_write(&line, frame.address, true)
		}
		fill(inside, 24, y + 4, 8, 8, frame.base != 0 ? hash_color(frame.hash) : graphics.COLOR_NOT_USABLE)
		write(inside, 40, y, system.written(&line), number == 0 ? graphics.COLOR_FAILED : graphics.COLOR_TEXT)
	}
}
