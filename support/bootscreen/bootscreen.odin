// The boot display: how the machine started, as a picture.
//
// It draws one record, Data. Each part of Data is a record of the kernel:
// the boot record (the stages and their times, the memory that the firmware
// gave, the firmware, the framebuffer), the state of the memory, the
// processors, the programs, and the modules of the boot image.
//
// Three programs draw it. The boot program draws what it knows before the
// kernel exists. The root service draws it while it starts the first
// programs: if the start fails, the display stays, with the failure. The
// program `boot` draws it in a window at any time.
//
// A record that is all zero is valid: its panel shows that the fact is
// not known yet. This package uses no kernel operation: package collect
// fills Data.
package bootscreen

import info "contract:boot_info"
import "support:graphics"
import op "contract:operation"
import "base:intrinsics"

WIDTH :: 976 // The size that the display needs.
HEIGHT :: 700
PROCESSOR_ROWS :: 16
PROGRAM_ROWS :: 12

State :: enum {
	Running, // The machine starts.
	Ready, // The desktop runs.
	Failed,
}

Program :: struct {
	slot:   u64,
	report: op.Program_Report,
}

Data :: struct {
	boot:            op.Boot_Report,
	machine:         op.System_Report,
	processors:      [PROCESSOR_ROWS]op.Processor_Report,
	programs:        [PROGRAM_ROWS]Program, // By slot.
	program_count:   int,
	program_total:   int, // All the programs: programs has the first ones.
	image:           []u8, // The boot image.
	processor_name:  [48]u8,
	message:         string, // What the machine does now.
	state:           State,
	red_first:       bool, // The pixels of the canvas have red in the low byte.
}

COLOR_BACKGROUND :: 0x0B1018
COLOR_PANEL :: 0x131B26
COLOR_TRACK :: 0x1C2633
COLOR_TEXT :: 0xDCE4EC
COLOR_DIM :: 0x7C8A99
COLOR_FIRMWARE :: 0x8E7CC3
COLOR_BOOT_PROGRAM :: 0xE0A040
COLOR_KERNEL :: 0x4A9CF0
COLOR_PROGRAM :: 0x58D878
COLOR_MEMORY :: 0x38C0B0
COLOR_MACHINE :: 0xD070B0
COLOR_FAILED :: 0xF06060
COLOR_RESERVED :: 0x4A5563

LINE :: 16
MARGIN :: 8
TITLE :: 44 // The height of the title and the caption of a panel.

@(private)
red_first: bool

@(private)
tone :: #force_inline proc "contextless" (color: graphics.Color) -> graphics.Color {
	return red_first ? color >> 16 & 0xFF | color & 0xFF00 | color << 16 & 0xFF0000 : color
}

@(private)
fill :: proc "contextless" (canvas: graphics.Canvas, x, y, width, height: int, color: graphics.Color) {
	graphics.fill(canvas, x, y, width, height, tone(color))
}

// A short text that the display builds from parts.
Text :: struct {
	bytes: [120]u8,
	count: int,
}

put :: proc "contextless" (text: ^Text, part: string) {
	for index in 0 ..< len(part) {
		if text.count < len(text.bytes) {
			text.bytes[text.count] = part[index]
			text.count += 1
		}
	}
}

// put_name adds the bytes of a name before its first zero byte.
put_name :: proc "contextless" (text: ^Text, name: []u8) {
	for character in name {
		if character == 0 {
			break
		}
		put(text, string([]u8{character}))
	}
}

put_number :: proc "contextless" (text: ^Text, value: u64, minimum_digits := 1) {
	digits: [20]u8
	count := 0
	for rest := value; rest != 0 || count < minimum_digits; rest /= 10 {
		digits[count] = '0' + u8(rest % 10)
		count += 1
	}
	for count > 0 {
		count -= 1
		put(text, string(digits[count:][:1]))
	}
}

put_hex :: proc "contextless" (text: ^Text, value: u64, digits: int) {
	characters := "0123456789abcdef"
	for index := digits - 1; index >= 0; index -= 1 {
		put(text, characters[value >> (uint(index) * 4) & 15:][:1])
	}
}

// put_duration adds a time of microseconds with its unit.
put_duration :: proc "contextless" (text: ^Text, microseconds: u64) {
	switch {
	case microseconds < 1000:
		put_number(text, microseconds)
		put(text, " us")
	case microseconds < 1_000_000:
		put_number(text, microseconds / 1000)
		put(text, ".")
		put_number(text, microseconds % 1000 / 100)
		put(text, " ms")
	case:
		put_number(text, microseconds / 1_000_000)
		put(text, ".")
		put_number(text, microseconds % 1_000_000 / 10_000, 2)
		put(text, " s")
	}
}

// put_size adds a size of bytes with its unit.
put_size :: proc "contextless" (text: ^Text, bytes: u64) {
	switch {
	case bytes < 1 << 10:
		put_number(text, bytes)
		put(text, " B")
	case bytes < 1 << 20:
		put_number(text, bytes >> 10)
		put(text, ".")
		put_number(text, (bytes & (1 << 10 - 1)) * 10 >> 10)
		put(text, " KiB")
	case:
		put_number(text, bytes >> 20)
		put(text, ".")
		put_number(text, (bytes & (1 << 20 - 1)) * 10 >> 20)
		put(text, " MiB")
	}
}

@(private)
show :: proc "contextless" (canvas: graphics.Canvas, x, y: int, text: ^Text, color: graphics.Color) -> int {
	after := graphics.text(canvas, x, y, string(text.bytes[:text.count]), tone(color))
	text.count = 0
	return after
}

@(private)
write :: proc "contextless" (canvas: graphics.Canvas, x, y: int, characters: string, color: graphics.Color) -> int {
	return graphics.text(canvas, x, y, characters, tone(color))
}

// show_right draws a text that ends at x.
@(private)
show_right :: proc "contextless" (canvas: graphics.Canvas, x, y: int, text: ^Text, color: graphics.Color) {
	show(canvas, x - text.count * 8, y, text, color)
}

// panel draws the frame of one part of the display, and gives the place
// of its content. The caption says which record the panel shows.
@(private)
panel :: proc "contextless" (canvas: graphics.Canvas, x, y, width, height: int, title, caption: string, accent: graphics.Color) -> graphics.Canvas {
	fill(canvas, x, y, width, height, COLOR_PANEL)
	fill(canvas, x, y, width, 2, accent)
	write(canvas, x + MARGIN, y + 8, title, accent)
	write(canvas, x + MARGIN, y + 8 + LINE, caption, COLOR_DIM)
	return graphics.view(canvas, x + MARGIN, y + TITLE + 4, width - 2 * MARGIN, height - TITLE - 4 - MARGIN)
}

// fact draws one line "name value".
@(private)
fact :: proc "contextless" (canvas: graphics.Canvas, line: int, name: string, value: ^Text, color: graphics.Color = COLOR_TEXT) {
	write(canvas, 0, line * LINE, name, COLOR_DIM)
	if value.count == 0 {
		put(value, "not known yet")
		show(canvas, 136, line * LINE, value, COLOR_DIM)
		return
	}
	show(canvas, 136, line * LINE, value, color)
}

// processor_name reads the name that the processor gives of itself.
processor_name :: proc "contextless" () -> (name: [48]u8) {
	highest, _, _, _ := intrinsics.x86_cpuid(0x8000_0000, 0)
	if highest < 0x8000_0004 {
		return
	}
	for leaf in u32(0) ..< 3 {
		a, b, c, d := intrinsics.x86_cpuid(0x8000_0002 + leaf, 0)
		for word, index in ([4]u32{a, b, c, d}) {
			for byte in u32(0) ..< 4 {
				name[int(leaf) * 16 + index * 4 + int(byte)] = u8(word >> (byte * 8))
			}
		}
	}
	name[len(name) - 1] = 0
	// The name can start with spaces.
	first := 0
	for first < len(name) && name[first] == ' ' {
		first += 1
	}
	intrinsics.mem_copy(&name[0], &name[first], len(name) - first)
	return
}

@(private)
stage_color :: proc "contextless" (name: []u8) -> graphics.Color {
	switch name[0] {
	case 'f':
		return COLOR_FIRMWARE
	case 'b':
		return COLOR_BOOT_PROGRAM
	}
	return COLOR_KERNEL
}

// draw draws the display in the top left of a canvas. The canvas must
// have WIDTH x HEIGHT pixels or more.
draw :: proc "contextless" (canvas: graphics.Canvas, data: ^Data) {
	red_first = data.red_first
	text: Text
	boot := &data.boot
	fill(canvas, 0, 40, canvas.width, canvas.height - 40, COLOR_BACKGROUND)

	// The title: the name of the system, what the machine does now, the time.
	for column in 0 ..< WIDTH {
		level := u32(column * 255 / WIDTH)
		fill(canvas, column, 0, 1, 40, graphics.rgb(0x1C - level * 0x10 / 255, 0x3C - level * 0x24 / 255, 0x70 - level * 0x48 / 255))
	}
	after := write(canvas, 16, 12, "kernel", 0xFFFFFF)
	state_color := graphics.Color(COLOR_BOOT_PROGRAM)
	switch data.state {
	case .Running:
	case .Ready:
		state_color = COLOR_PROGRAM
	case .Failed:
		state_color = COLOR_FAILED
	}
	write(canvas, after + 16, 12, data.message, state_color)
	if boot.time != 0 {
		put_duration(&text, boot.time)
		put(&text, " since the machine started")
	}
	show_right(canvas, WIDTH - 16, 12, &text, 0xA8C8F0)
	fill(canvas, 0, 40, WIDTH, 2, state_color)

	// The stages, on one line of time. The line starts with the boot
	// program: the firmware before it takes most of the time.
	{
		area := panel(canvas, MARGIN, 50, WIDTH - 2 * MARGIN, 252, "STAGES", "Boot_Report.stages and Program_Report.start_time, from the cycle counter of the processor.", COLOR_KERNEL)
		NAME_WIDTH :: 400
		TIME_WIDTH :: 104
		track_x := NAME_WIDTH
		track_width := area.width - NAME_WIDTH - TIME_WIDTH
		origin := boot.stage_count > 1 ? boot.stages[1].start : 0
		last := origin
		for stage in boot.stages[:boot.stage_count] {
			last = max(last, stage.start + stage.duration)
		}
		// The programs of the start: the ones that started in the second
		// after the kernel.
		kernel_end := last
		for program in data.programs[:data.program_count] {
			if program.report.start_time <= kernel_end + 1_000_000 {
				last = max(last, program.report.start_time)
			}
		}
		span := max(last - origin, 1)
		place :: proc "contextless" (time, origin, span: u64, width: int) -> int {
			return time <= origin ? 0 : int(min(time - origin, span) * u64(width) / span)
		}
		line := 0
		if boot.stage_count == 0 {
			write(area, 0, 0, "The kernel does not run yet: it measures the stages.", COLOR_DIM)
			line = 1
		}
		for &stage, index in boot.stages[:boot.stage_count] {
			y := line * LINE
			color := stage_color(stage.name[:])
			put_name(&text, stage.name[:])
			show(area, 0, y, &text, COLOR_TEXT)
			fill(area, track_x, y + 3, track_width, 10, COLOR_TRACK)
			if index == 0 {
				write(area, track_x + 8, y, "before the line of time", COLOR_DIM)
			} else {
				left := place(stage.start, origin, span, track_width)
				right := place(stage.start + stage.duration, origin, span, track_width)
				fill(area, track_x + left, y + 3, max(right - left, 2), 10, color)
			}
			put_duration(&text, stage.duration)
			show_right(area, area.width, y, &text, color)
			line += 1
		}
		for &program in data.programs[:data.program_count] {
			if program.report.start_time > kernel_end + 1_000_000 || line >= 11 {
				continue
			}
			y := line * LINE
			put(&text, "program ")
			put_name(&text, program.report.name[:])
			put(&text, ": created")
			show(area, 0, y, &text, COLOR_TEXT)
			fill(area, track_x, y + 3, track_width, 10, COLOR_TRACK)
			left := place(program.report.start_time, origin, span, track_width)
			fill(area, track_x + min(left, track_width - 3), y + 1, 3, 14, COLOR_PROGRAM)
			put(&text, "at ")
			put_duration(&text, program.report.start_time - min(origin, program.report.start_time))
			show_right(area, area.width, y, &text, COLOR_PROGRAM)
			line += 1
		}
		if boot.stage_count != 0 {
			y := 11 * LINE + 2
			fill(area, track_x, y, track_width, 1, COLOR_DIM)
			write(area, track_x, y + 4, "0", COLOR_DIM)
			put_duration(&text, span)
			show_right(area, track_x + track_width, y + 4, &text, COLOR_DIM)
			write(area, 0, y + 4, "time since the boot program started", COLOR_DIM)
		}
	}

	// The memory.
	LEFT_WIDTH :: 560
	{
		area := panel(canvas, MARGIN, 310, LEFT_WIDTH, 168, "MEMORY", "Boot_Report.ranges: what the firmware gave. System_Report: now.", COLOR_MEMORY)
		top: u64
		totals: [3]u64
		for range in boot.ranges[:boot.range_count] {
			if range.kind != u64(info.Memory_Kind.Reserved) {
				top = max(top, range.start + range.page_count * info.PAGE_SIZE)
			}
		}
		colors := [3]graphics.Color{COLOR_RESERVED, COLOR_MEMORY, COLOR_BOOT_PROGRAM}
		fill(area, 0, 0, area.width, 18, COLOR_TRACK)
		for range in boot.ranges[:boot.range_count] {
			if range.start >= top || range.kind > 2 {
				continue
			}
			totals[range.kind] += range.page_count * info.PAGE_SIZE
			left := int(range.start * u64(area.width) / top)
			right := int(min(range.start + range.page_count * info.PAGE_SIZE, top) * u64(area.width) / top)
			fill(area, left, 0, max(right - left, 1), 18, colors[range.kind])
		}
		write(area, 0, 22, "address 0", COLOR_DIM)
		put_hex(&text, top, 12)
		show_right(area, area.width, 22, &text, COLOR_DIM)
		names := [3]string{"not usable", "free", "boot program"}
		x := 0
		for kind in ([3]int{1, 2, 0}) {
			fill(area, x, 44 + 3, 10, 10, colors[kind])
			put(&text, names[kind])
			put(&text, " ")
			put_size(&text, totals[kind])
			x = show(area, x + 16, 44, &text, COLOR_TEXT) + 20
		}
		// Now: the page frames of the kernel.
		y := 64
		fill(area, 0, y, area.width, 10, COLOR_TRACK)
		if data.machine.page_count != 0 {
			used := data.machine.page_count - data.machine.free_pages
			fill(area, 0, y, int(used * u64(area.width) / data.machine.page_count), 10, COLOR_KERNEL)
			put(&text, "now: ")
			put_size(&text, used * info.PAGE_SIZE)
			put(&text, " of ")
			put_size(&text, data.machine.page_count * info.PAGE_SIZE)
			put(&text, " in use, ")
			put_number(&text, data.machine.region_count)
			put(&text, " objects, budgets ")
			put_number(&text, data.machine.budget_pages)
			put(&text, " pages")
			show(area, 0, y + 12, &text, COLOR_TEXT)
		} else {
			write(area, 0, y + 12, "now: not known yet", COLOR_DIM)
		}
		if boot.range_count != 0 {
			put_number(&text, boot.firmware_ranges)
			put(&text, " firmware ranges, ")
			put_number(&text, boot.range_count)
			put(&text, " after neighbours join")
			if boot.direct_map_size != 0 {
				put(&text, ", direct map ")
				put_size(&text, boot.direct_map_size)
			}
			show(area, 0, y + 12 + LINE, &text, COLOR_DIM)
		}
	}

	// The machine.
	{
		x := 2 * MARGIN + LEFT_WIDTH
		area := panel(canvas, x, 310, WIDTH - x - MARGIN, 168, "MACHINE", "Boot_Report, Processor_Report, cpuid.", COLOR_MACHINE)
		put_name(&text, boot.firmware_vendor[:])
		if text.count != 0 {
			put(&text, " ")
			put_number(&text, boot.firmware_revision >> 16)
			put(&text, ".")
			put_number(&text, boot.firmware_revision & 0xFFFF)
		}
		fact(area, 0, "firmware", &text)
		if boot.framebuffer_width != 0 {
			put_number(&text, boot.framebuffer_width)
			put(&text, "x")
			put_number(&text, boot.framebuffer_height)
			put(&text, boot.framebuffer_format == u64(info.Pixel_Format.Red_Green_Blue_X) ? " red first at " : " blue first at ")
			put_hex(&text, boot.framebuffer_address, 9)
		}
		fact(area, 1, "framebuffer", &text)
		put_name(&text, data.processor_name[:])
		text.count = min(text.count, 33)
		fact(area, 2, "processor", &text)
		if data.machine.processors != 0 {
			put_number(&text, data.machine.processors)
			put(&text, ", numbers")
			for processor in data.processors[:min(data.machine.processors, PROCESSOR_ROWS)] {
				put(&text, " ")
				put_number(&text, processor.apic_id)
			}
			text.count = min(text.count, 33)
		}
		fact(area, 3, "processors", &text)
		if boot.cycle_frequency != 0 {
			put_number(&text, boot.cycle_frequency / 1_000_000)
			put(&text, " MHz")
		}
		fact(area, 4, "cycle counter", &text)
		if boot.timer_frequency != 0 {
			put_number(&text, boot.timer_frequency / 1_000_000)
			put(&text, " MHz, 1000 ticks/s")
		}
		fact(area, 5, "timer", &text)
		if boot.kernel_size != 0 {
			put_size(&text, boot.kernel_size)
			put(&text, " (file ")
			put_size(&text, boot.kernel_file_size)
			put(&text, ")")
		}
		fact(area, 6, "kernel", &text)
	}

	// The modules of the boot image, in two columns.
	{
		area := panel(canvas, MARGIN, 486, LEFT_WIDTH, 206, "BOOT IMAGE", "Image_Entry: name, size, start of the hash of each module.", COLOR_BOOT_PROGRAM)
		entries: []info.Image_Entry
		if len(data.image) >= size_of(info.Image_Header) {
			header := (^info.Image_Header)(raw_data(data.image))
			if header.magic == info.IMAGE_MAGIC && size_of(info.Image_Header) + int(header.count) * size_of(info.Image_Entry) <= len(data.image) {
				entries = ([^]info.Image_Entry)(raw_data(data.image[size_of(info.Image_Header):]))[:header.count]
			}
		}
		if entries == nil {
			write(area, 0, 0, "not known yet", COLOR_DIM)
		}
		ROWS :: 9
		largest: u64 = 1
		for &entry in entries {
			largest = max(largest, entry.size)
		}
		column_width := area.width / 3
		for &entry, index in entries {
			if index >= 3 * ROWS {
				break
			}
			x := index / ROWS * column_width
			y := index % ROWS * LINE
			put_name(&text, entry.name[:])
			text.count = min(text.count, 10)
			show(area, x, y, &text, COLOR_TEXT)
			put_number(&text, (entry.size + 1023) >> 10)
			put(&text, " KiB")
			show_right(area, x + 140, y, &text, COLOR_DIM)
			fill(area, x + 84, y + 14, int(entry.size * 56 / largest), 1, COLOR_BOOT_PROGRAM)
			put_hex(&text, u64(entry.hash[0]) << 8 | u64(entry.hash[1]), 4)
			show(area, x + 144, y, &text, COLOR_BOOT_PROGRAM)
		}
		if len(entries) != 0 {
			put_number(&text, u64(len(entries)))
			put(&text, " modules, ")
			put_size(&text, u64(len(data.image)))
			show_right(canvas, LEFT_WIDTH, 486 + 8, &text, COLOR_TEXT)
		}
	}

	// The programs.
	{
		x := 2 * MARGIN + LEFT_WIDTH
		area := panel(canvas, x, 486, WIDTH - x - MARGIN, 206, "PROGRAMS", "Program_Report: slot, threads, pages, created.", COLOR_PROGRAM)
		if data.program_count == 0 {
			write(area, 0, 0, "No program runs yet.", COLOR_DIM)
		} else {
			put_number(&text, u64(data.program_total))
			put(&text, " programs")
			show_right(canvas, WIDTH - 2 * MARGIN, 486 + 8, &text, COLOR_TEXT)
		}
		for &program, index in data.programs[:data.program_count] {
			if index >= 9 {
				break
			}
			y := index * LINE
			put_number(&text, program.slot)
			show(area, 0, y, &text, COLOR_DIM)
			put_name(&text, program.report.name[:])
			text.count = min(text.count, 12)
			show(area, 28, y, &text, program.report.state == .Stopped ? COLOR_FAILED : COLOR_TEXT)
			put_number(&text, program.report.thread_count)
			show_right(area, 150, y, &text, COLOR_TEXT)
			put_number(&text, program.report.mapped_pages)
			show_right(area, 206, y, &text, COLOR_TEXT)
			put_duration(&text, program.report.start_time)
			show_right(area, area.width, y, &text, COLOR_PROGRAM)
		}
	}
}

// draw_screen draws the display in the middle of a screen.
draw_screen :: proc "contextless" (screen: graphics.Canvas, data: ^Data) {
	if screen.width < WIDTH || screen.height < HEIGHT {
		draw(screen, data)
		return
	}
	red_first = data.red_first
	x := (screen.width - WIDTH) / 2
	y := (screen.height - HEIGHT) / 2
	fill(screen, 0, 0, screen.width, y, COLOR_BACKGROUND)
	fill(screen, 0, y + HEIGHT, screen.width, screen.height - y - HEIGHT, COLOR_BACKGROUND)
	fill(screen, 0, y, x, HEIGHT, COLOR_BACKGROUND)
	fill(screen, x + WIDTH, y, screen.width - x - WIDTH, HEIGHT, COLOR_BACKGROUND)
	draw(graphics.view(screen, x, y, WIDTH, HEIGHT), data)
}
