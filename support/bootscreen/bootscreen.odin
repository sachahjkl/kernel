// The boot display: how the machine started, as a picture. It is the model
// of the design rules (docs/DESIGN.md).
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
// A record that is all zero is valid: its card shows that the fact is
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

// The steps of the start, in their order. The program that draws says
// which step the machine does now: the steps before it are done.
Step :: enum {
	Firmware,
	Kernel_Module, // The boot program loads the kernel module.
	Boot_Image,
	Memory_Map,
	Kernel, // The boot program ends the firmware and jumps.
	Processors,
	Root,
	Input,
	Compositor,
	Desktop,
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
	step:            Step, // The step that the machine does now.
	red_first:       bool, // The pixels of the canvas have red in the low byte.
}

LINE :: graphics.LINE_HEIGHT
MARGIN :: graphics.CARD_GAP

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

// hue_color gives one color of the circle of colors, of middle strength.
@(private)
hue_color :: proc "contextless" (hue: u8) -> graphics.Color {
	LOW :: 64
	HIGH :: 208
	part := u32(hue) * 6 % 256
	rise := LOW + (HIGH - LOW) * part / 255
	fall := HIGH - (HIGH - LOW) * part / 255
	switch u32(hue) * 6 / 256 {
	case 0:
		return graphics.rgb(HIGH, rise, LOW)
	case 1:
		return graphics.rgb(fall, HIGH, LOW)
	case 2:
		return graphics.rgb(LOW, HIGH, rise)
	case 3:
		return graphics.rgb(LOW, fall, HIGH)
	case 4:
		return graphics.rgb(rise, LOW, HIGH)
	}
	return graphics.rgb(HIGH, LOW, fall)
}

// block draws a rectangle. Its color goes from top, on its first line, to
// bottom, on its last line.
@(private)
block :: proc "contextless" (canvas: graphics.Canvas, x, y, width, height: int, top, bottom: graphics.Color) {
	for row in 0 ..< height {
		fill(canvas, x, y + row, width, 1, graphics.mix(top, bottom, u32(row * 255 / max(height - 1, 1))))
	}
}

// write_large draws characters with each pixel of the font as a square of
// scale pixels. It gives the x after the last character.
@(private)
write_large :: proc "contextless" (canvas: graphics.Canvas, x, y: int, characters: string, scale: int, color: graphics.Color) -> int {
	at := x
	for index in 0 ..< len(characters) {
		value := characters[index]
		if value >= graphics.FONT_FIRST && value <= graphics.FONT_LAST {
			glyph := graphics.font[value - graphics.FONT_FIRST]
			for bits, row in glyph {
				for column in 0 ..< graphics.CELL_WIDTH {
					if bits << uint(column) & 0x80 != 0 {
						fill(canvas, at + column * scale, y + row * scale, scale, scale, color)
					}
				}
			}
		}
		at += graphics.CELL_WIDTH * scale
	}
	return at
}

CARD_TITLE :: graphics.CARD_TITLE
CARD_MARGIN :: graphics.CARD_MARGIN

// card draws the frame of one part of the display, and gives the place of
// its content. The caption says which record the card shows.
@(private)
card :: proc "contextless" (canvas: graphics.Canvas, x, y, width, height: int, title, caption: string, accent: graphics.Color) -> graphics.Canvas {
	block(canvas, x, y, width, height, graphics.shade(accent, 28), graphics.shade(accent, 14))
	block(canvas, x + 1, y + 1, width - 2, height - 2, graphics.COLOR_CARD_TOP, graphics.COLOR_CARD_BOTTOM)
	block(canvas, x + CARD_MARGIN, y + 13, 4, 16, graphics.shade(accent, 130), accent)
	after := write(canvas, x + CARD_MARGIN + 12, y + 13, title, accent)
	write(canvas, after + 16, y + 13, caption, graphics.COLOR_DIM)
	return graphics.view(canvas, x + CARD_MARGIN, y + CARD_TITLE, width - 2 * CARD_MARGIN, height - CARD_TITLE - 10)
}

// fact draws one line "name value".
@(private)
fact :: proc "contextless" (canvas: graphics.Canvas, y: int, name: string, value: ^Text, color: graphics.Color = graphics.COLOR_TEXT) {
	write(canvas, 0, y, name, graphics.COLOR_DIM)
	if value.count == 0 {
		put(value, "not known yet")
		show(canvas, FACT_VALUE, y, value, graphics.COLOR_DIM)
		return
	}
	show(canvas, FACT_VALUE, y, value, color)
}

FACT_VALUE :: 120

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

// stage_color gives the color of a stage: the color of the party that
// does it (the firmware, the boot program, the kernel), in one of four
// shades, so that two stages that touch do not have one color.
@(private)
stage_color :: proc "contextless" (name: []u8, index: int) -> graphics.Color {
	shades := [4]u32{118, 92, 136, 76}
	switch name[0] {
	case 'f':
		return graphics.COLOR_FIRMWARE
	case 'b':
		return graphics.shade(graphics.COLOR_BOOT_PROGRAM, shades[index & 3])
	}
	return graphics.shade(graphics.COLOR_KERNEL, shades[index & 3])
}

@(private, rodata)
step_names := [Step]string {
	.Firmware      = "the firmware",
	.Kernel_Module = "the kernel module",
	.Boot_Image    = "the boot image",
	.Memory_Map    = "the memory map",
	.Kernel        = "the kernel",
	.Processors    = "the processors",
	.Root          = "the root service",
	.Input         = "the input service",
	.Compositor    = "the compositor",
	.Desktop       = "the desktop",
}

// The boot image as tiles: one tile for each module. The width of a tile
// is the size of the module, with a least width for its name.
TILE_ROWS :: 5
TILE_HEIGHT :: 20
TILE_GAP :: 2
TILE_LEAST :: 36

@(private)
tile_width :: proc "contextless" (size, scale: u64) -> int {
	return max(int(size * scale >> 20), TILE_LEAST)
}

// tiles_fit says if the tiles, at this scale, fit in the rows.
@(private)
tiles_fit :: proc "contextless" (entries: []info.Image_Entry, scale: u64, width: int) -> bool {
	x, row := 0, 0
	for &entry in entries {
		tile := min(tile_width(entry.size, scale), width)
		if x + tile > width {
			x = 0
			row += 1
		}
		x += tile + TILE_GAP
	}
	return row < TILE_ROWS
}

// draw draws the display in the top left of a canvas. The canvas must
// have WIDTH x HEIGHT pixels or more.
draw :: proc "contextless" (canvas: graphics.Canvas, data: ^Data) {
	red_first = data.red_first
	text: Text
	boot := &data.boot
	HEADER :: 72
	fill(canvas, 0, HEADER, canvas.width, canvas.height - HEADER, graphics.COLOR_BACKGROUND)
	// A grid of points under the cards.
	for y := HEADER + 12; y < HEIGHT; y += 24 {
		for x := 12; x < WIDTH; x += 24 {
			fill(canvas, x, y, 2, 2, graphics.COLOR_POINT)
		}
	}

	// The head: the name of the system, what the machine does now, the time.
	for column in 0 ..< WIDTH {
		level := u32(column * 255 / WIDTH)
		top := graphics.mix(0x24509A, 0x0C1830, level)
		for row := 0; row < HEADER; row += 8 {
			fill(canvas, column, row, 1, 8, graphics.mix(top, graphics.shade(top, 62), u32(row * 255 / HEADER)))
		}
	}
	write_large(canvas, 20, 12, "kernel", 3, graphics.COLOR_WHITE)
	state_color := graphics.Color(graphics.COLOR_BOOT_PROGRAM)
	switch data.state {
	case .Running:
	case .Ready:
		state_color = graphics.COLOR_PROGRAM
	case .Failed:
		state_color = graphics.COLOR_FAILED
	}
	// The steps of the start as a path: a point for each step. A step that
	// is done is full, the step of now has a ring, a step to come is empty.
	{
		PATH_X :: 208
		PATH_Y :: 26
		PATH_STEP :: 52
		now := data.state == .Ready ? len(Step) : int(data.step)
		for step in 0 ..< len(Step) {
			x := PATH_X + step * PATH_STEP
			if step != 0 {
				fill(canvas, x - PATH_STEP + 8, PATH_Y - 1, PATH_STEP - 16, 2, step <= now ? graphics.shade(graphics.COLOR_PROGRAM, 80) : 0x33507C)
			}
			switch {
			case step < now:
				block(canvas, x - 5, PATH_Y - 5, 10, 10, graphics.shade(graphics.COLOR_PROGRAM, 130), graphics.COLOR_PROGRAM)
			case step == now:
				block(canvas, x - 8, PATH_Y - 8, 16, 16, graphics.shade(state_color, 140), state_color)
				block(canvas, x - 5, PATH_Y - 5, 10, 10, 0x10203C, 0x10203C)
				block(canvas, x - 2, PATH_Y - 2, 4, 4, graphics.shade(state_color, 140), state_color)
			case:
				block(canvas, x - 5, PATH_Y - 5, 10, 10, 0x33507C, 0x33507C)
				block(canvas, x - 3, PATH_Y - 3, 6, 6, 0x162C54, 0x162C54)
			}
		}
		put_number(&text, u64(min(now + 1, len(Step))))
		put(&text, "/")
		put_number(&text, len(Step))
		after_count := show(canvas, PATH_X - 8, 44, &text, 0x9CB8E0)
		write(canvas, after_count + 12, 44, data.message, graphics.shade(state_color, 135))
	}
	if boot.time != 0 {
		put_duration(&text, boot.time)
		write_large(canvas, WIDTH - 20 - text.count * 16, 8, string(text.bytes[:text.count]), 2, graphics.COLOR_WHITE)
		text.count = 0
		put(&text, "since the machine started")
		show_right(canvas, WIDTH - 20, 46, &text, 0x9CB8E0)
	}
	// A line of the color of the state, that fades to the right.
	for column := 0; column < WIDTH; column += 4 {
		fill(canvas, column, HEADER, 4, 2, graphics.mix(state_color, graphics.COLOR_BACKGROUND, u32(column * 255 / WIDTH)))
	}

	// The stages, on one line of time. The line starts with the boot
	// program: the firmware before it takes most of the time.
	{
		area := card(canvas, MARGIN, 84, WIDTH - 2 * MARGIN, 246, "THE LINE OF TIME", "Boot_Report.stages, Program_Report.start_time: the cycle counter", graphics.COLOR_KERNEL)
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
		// The time from the boot program to the last program, in large digits.
		if boot.stage_count != 0 {
			put_duration(&text, span)
			write_large(canvas, WIDTH - MARGIN - CARD_MARGIN - text.count * 16, 84 + 6, string(text.bytes[:text.count]), 2, graphics.COLOR_TEXT)
			text.count = 0
		}

		// The tube: the firmware as a short part with lines, then the line of time.
		TUBE_Y :: 14
		TUBE_HEIGHT :: 40
		FIRMWARE_WIDTH :: 72
		track_x := FIRMWARE_WIDTH + 8
		track_width := area.width - track_x
		inner := track_width - 8
		block(area, 0, TUBE_Y, FIRMWARE_WIDTH, TUBE_HEIGHT, graphics.shade(graphics.COLOR_FIRMWARE, 46), graphics.shade(graphics.COLOR_FIRMWARE, 30))
		for line := 8; line < FIRMWARE_WIDTH - 8; line += 8 {
			for step in 0 ..< TUBE_HEIGHT - 16 {
				fill(area, line + step / 4, TUBE_Y + 8 + step, 2, 1, graphics.shade(graphics.COLOR_FIRMWARE, 78))
			}
		}
		block(area, track_x, TUBE_Y, track_width, TUBE_HEIGHT, graphics.COLOR_TRACK, graphics.shade(graphics.COLOR_TRACK, 80))
		if boot.stage_count == 0 {
			write(area, track_x + 16, TUBE_Y + 12, "The kernel does not run yet: it measures the stages.", graphics.COLOR_DIM)
			// Until the stages have a time, the steps of the start, as a list.
			for name, step in step_names {
				x := int(step) / 5 * (area.width / 2)
				y := 92 + int(step) % 5 * LINE
				switch {
				case step < data.step:
					block(area, x, y + 3, 10, 10, graphics.shade(graphics.COLOR_PROGRAM, 130), graphics.COLOR_PROGRAM)
					write(area, x + 18, y, name, graphics.COLOR_TEXT)
					write(area, x + 200, y, "done", graphics.COLOR_PROGRAM)
				case step == data.step:
					block(area, x, y + 3, 10, 10, graphics.shade(state_color, 140), state_color)
					block(area, x + 3, y + 6, 4, 4, graphics.COLOR_CARD_BOTTOM, graphics.COLOR_CARD_BOTTOM)
					write(area, x + 18, y, name, graphics.shade(state_color, 135))
					write(area, x + 200, y, data.state == .Failed ? "failed" : "now", graphics.shade(state_color, 135))
				case:
					block(area, x, y + 3, 10, 10, graphics.COLOR_TRACK, graphics.COLOR_TRACK)
					write(area, x + 18, y, name, graphics.COLOR_DIM)
				}
			}
		}
		for &stage, index in boot.stages[:boot.stage_count] {
			if index == 0 {
				continue
			}
			color := stage_color(stage.name[:], index)
			left := place(stage.start, origin, span, inner)
			right := place(stage.start + stage.duration, origin, span, inner)
			width := max(right - left - 1, 2)
			block(area, track_x + 4 + left, TUBE_Y + 4, width, TUBE_HEIGHT - 8, graphics.shade(color, 125), graphics.shade(color, 78))
			put_duration(&text, stage.duration)
			if text.count * 8 + 8 <= width {
				show(area, track_x + 4 + left + (width - text.count * 8) / 2, TUBE_Y + 12, &text, graphics.COLOR_BACKGROUND)
			}
			text.count = 0
		}
		// Each program of the start: a mark on the line of time, at its creation.
		marks := 0
		for &program in data.programs[:data.program_count] {
			if program.report.start_time > kernel_end + 1_000_000 {
				continue
			}
			x := track_x + 4 + min(place(program.report.start_time, origin, span, inner), inner - 2)
			color := graphics.shade(graphics.COLOR_PROGRAM, u32(130 - 14 * (marks & 3)))
			fill(area, x, TUBE_Y - 4, 2, TUBE_HEIGHT + 8, color)
			block(area, x - 3, TUBE_Y - 12, 8, 8, color, color)
			marks += 1
		}
		// The scale of time, under the tube.
		if boot.stage_count != 0 {
			steps := [?]u64{100, 200, 500, 1000, 2000, 5000, 10_000, 20_000, 50_000, 100_000, 200_000, 500_000, 1_000_000, 2_000_000, 5_000_000}
			step := steps[len(steps) - 1]
			for candidate in steps {
				if span / candidate <= 9 {
					step = candidate
					break
				}
			}
			for time := u64(0); time <= span; time += step {
				x := track_x + 4 + int(time * u64(inner) / span)
				fill(area, x, TUBE_Y + TUBE_HEIGHT + 4, 1, 5, graphics.COLOR_DIM)
				if time == 0 {
					write(area, x - 3, TUBE_Y + TUBE_HEIGHT + 10, "0", graphics.COLOR_DIM)
				} else {
					put_duration(&text, time)
					if x + text.count * 4 <= area.width {
						show(area, x - text.count * 4, TUBE_Y + TUBE_HEIGHT + 10, &text, graphics.COLOR_DIM)
					}
					text.count = 0
				}
			}
			write(area, 0, TUBE_Y + TUBE_HEIGHT + 10, "firmware", graphics.COLOR_DIM)
		}

		// The names: each stage and each program of the start, with its
		// color and its time, in two columns.
		NAMES_Y :: 92
		NAME_ROWS :: 6
		column_width := area.width / 2
		entry := 0
		for &stage, index in boot.stages[:boot.stage_count] {
			if entry >= 2 * NAME_ROWS {
				break
			}
			x := entry / NAME_ROWS * column_width
			y := NAMES_Y + entry % NAME_ROWS * LINE
			color := stage_color(stage.name[:], index)
			block(area, x, y + 3, 10, 10, graphics.shade(color, 125), graphics.shade(color, 78))
			put_name(&text, stage.name[:])
			show(area, x + 18, y, &text, graphics.COLOR_TEXT)
			put_duration(&text, stage.duration)
			show_right(area, x + column_width - 24, y, &text, color)
			entry += 1
		}
		marks = 0
		for &program in data.programs[:data.program_count] {
			if program.report.start_time > kernel_end + 1_000_000 {
				continue
			}
			color := graphics.shade(graphics.COLOR_PROGRAM, u32(130 - 14 * (marks & 3)))
			marks += 1
			if entry >= 2 * NAME_ROWS {
				continue
			}
			x := entry / NAME_ROWS * column_width
			y := NAMES_Y + entry % NAME_ROWS * LINE
			block(area, x + 1, y + 4, 8, 8, color, color)
			put(&text, "program ")
			put_name(&text, program.report.name[:])
			put(&text, ": created")
			show(area, x + 18, y, &text, graphics.COLOR_TEXT)
			put(&text, "at ")
			put_duration(&text, program.report.start_time - min(origin, program.report.start_time))
			show_right(area, x + column_width - 24, y, &text, color)
			entry += 1
		}
	}

	// The memory.
	LEFT_WIDTH :: 568
	MIDDLE_Y :: 338
	MIDDLE_HEIGHT :: 178
	{
		area := card(canvas, MARGIN, MIDDLE_Y, LEFT_WIDTH, MIDDLE_HEIGHT, "MEMORY", "Boot_Report.ranges, System_Report", graphics.COLOR_MEMORY)
		top: u64
		totals: [3]u64
		for range in boot.ranges[:boot.range_count] {
			if range.kind != u64(info.Memory_Kind.Reserved) {
				top = max(top, range.start + range.page_count * info.PAGE_SIZE)
			}
		}
		colors := [3]graphics.Color{graphics.COLOR_NOT_USABLE, graphics.COLOR_MEMORY, graphics.COLOR_BOOT_PROGRAM}
		BAND :: 26
		block(area, 0, 0, area.width, BAND, graphics.COLOR_TRACK, graphics.shade(graphics.COLOR_TRACK, 80))
		inner := area.width - 8
		for range in boot.ranges[:boot.range_count] {
			if range.start >= top || range.kind > 2 {
				continue
			}
			totals[range.kind] += range.page_count * info.PAGE_SIZE
			left := int(range.start * u64(inner) / top)
			right := int(min(range.start + range.page_count * info.PAGE_SIZE, top) * u64(inner) / top)
			color := colors[range.kind]
			block(area, 4 + left, 4, max(right - left, 1), BAND - 8, graphics.shade(color, 120), graphics.shade(color, 78))
		}
		write(area, 0, BAND + 4, "address 0", graphics.COLOR_DIM)
		put_hex(&text, top, 12)
		show_right(area, area.width, BAND + 4, &text, graphics.COLOR_DIM)
		names := [3]string{"not usable", "free", "boot program"}
		x := 0
		if boot.range_count == 0 {
			write(area, 0, BAND + 28, "ranges: not known yet", graphics.COLOR_DIM)
		}
		for kind in ([3]int{1, 2, 0}) {
			if boot.range_count == 0 {
				break
			}
			block(area, x, BAND + 28 + 3, 10, 10, graphics.shade(colors[kind], 120), graphics.shade(colors[kind], 78))
			put(&text, names[kind])
			put(&text, " ")
			put_size(&text, totals[kind])
			x = show(area, x + 16, BAND + 28, &text, graphics.COLOR_TEXT) + 20
		}
		// Now: the page frames of the kernel.
		y := BAND + 52
		block(area, 0, y, area.width, 8, graphics.COLOR_TRACK, graphics.COLOR_TRACK)
		if data.machine.page_count != 0 {
			used := data.machine.page_count - data.machine.free_pages
			block(area, 0, y, max(int(used * u64(area.width) / data.machine.page_count), 8), 8, graphics.shade(graphics.COLOR_KERNEL, 125), graphics.COLOR_KERNEL)
			put(&text, "now: ")
			put_size(&text, used * info.PAGE_SIZE)
			put(&text, " of ")
			put_size(&text, data.machine.page_count * info.PAGE_SIZE)
			put(&text, " used, ")
			put_number(&text, data.machine.region_count)
			put(&text, " objects, budgets ")
			put_number(&text, data.machine.budget_pages)
			put(&text, " pages")
			show(area, 0, y + 12, &text, graphics.COLOR_TEXT)
		} else {
			write(area, 0, y + 12, "now: not known yet", graphics.COLOR_DIM)
		}
		if boot.range_count != 0 {
			put_number(&text, boot.firmware_ranges)
			put(&text, " firmware ranges, ")
			put_number(&text, boot.range_count)
			put(&text, " joined")
			if boot.direct_map_size != 0 {
				put(&text, ", direct map ")
				put_size(&text, boot.direct_map_size)
			}
			show(area, 0, y + 12 + LINE, &text, graphics.COLOR_DIM)
		}
	}

	// The machine.
	RIGHT_X :: 2 * MARGIN + LEFT_WIDTH
	{
		area := card(canvas, RIGHT_X, MIDDLE_Y, WIDTH - RIGHT_X - MARGIN, MIDDLE_HEIGHT, "MACHINE", "Boot_Report, cpuid", graphics.COLOR_MACHINE)
		// One square for each processor that runs, with its number.
		write(area, 0, 2, "processors", graphics.COLOR_DIM)
		if data.machine.processors == 0 {
			write(area, FACT_VALUE, 2, "not known yet", graphics.COLOR_DIM)
		}
		SQUARES :: 10
		for processor, index in data.processors[:min(data.machine.processors, PROCESSOR_ROWS)] {
			x := FACT_VALUE + index * 23
			if index >= SQUARES {
				put(&text, "+")
				put_number(&text, data.machine.processors - SQUARES)
				show(area, x, 2, &text, graphics.COLOR_MACHINE)
				break
			}
			block(area, x, 0, 20, 20, graphics.shade(graphics.COLOR_MACHINE, 112), graphics.shade(graphics.COLOR_MACHINE, 66))
			put_number(&text, processor.apic_id)
			show(area, x + 10 - text.count * 4, 2, &text, graphics.COLOR_BACKGROUND)
		}
		FACTS :: 28
		put_name(&text, boot.firmware_vendor[:])
		if text.count != 0 {
			put(&text, " ")
			put_number(&text, boot.firmware_revision >> 16)
			put(&text, ".")
			put_number(&text, boot.firmware_revision & 0xFFFF)
		}
		fact(area, FACTS, "firmware", &text)
		if boot.framebuffer_width != 0 {
			put_number(&text, boot.framebuffer_width)
			put(&text, "x")
			put_number(&text, boot.framebuffer_height)
			put(&text, boot.framebuffer_format == u64(info.Pixel_Format.Red_Green_Blue_X) ? " red first" : " blue first")
		}
		fact(area, FACTS + LINE, "framebuffer", &text)
		put_name(&text, data.processor_name[:])
		text.count = min(text.count, 29)
		fact(area, FACTS + 2 * LINE, "processor", &text)
		if boot.cycle_frequency != 0 {
			put_number(&text, boot.cycle_frequency / 1_000_000)
			put(&text, " MHz")
		}
		fact(area, FACTS + 3 * LINE, "cycle counter", &text)
		if boot.timer_frequency != 0 {
			put_number(&text, boot.timer_frequency / 1_000_000)
			put(&text, " MHz, 1000 ticks/s")
		}
		fact(area, FACTS + 4 * LINE, "timer", &text)
		if boot.kernel_size != 0 {
			put_size(&text, boot.kernel_size)
			put(&text, " (file ")
			put_size(&text, boot.kernel_file_size)
			put(&text, ")")
		}
		fact(area, FACTS + 5 * LINE, "kernel", &text)
	}

	// The modules of the boot image, as tiles. The color of a tile comes
	// from the hash of the module: a module that changes takes a new color.
	BOTTOM_Y :: MIDDLE_Y + MIDDLE_HEIGHT + MARGIN
	BOTTOM_HEIGHT :: HEIGHT - BOTTOM_Y - MARGIN
	{
		area := card(canvas, MARGIN, BOTTOM_Y, LEFT_WIDTH, BOTTOM_HEIGHT, "BOOT IMAGE", "Image_Entry: a tile is a module", graphics.COLOR_BOOT_PROGRAM)
		entries: []info.Image_Entry
		if len(data.image) >= size_of(info.Image_Header) {
			header := (^info.Image_Header)(raw_data(data.image))
			if header.magic == info.IMAGE_MAGIC && size_of(info.Image_Header) + int(header.count) * size_of(info.Image_Entry) <= len(data.image) {
				entries = ([^]info.Image_Entry)(raw_data(data.image[size_of(info.Image_Header):]))[:header.count]
			}
		}
		if entries == nil {
			write(area, 0, 0, "not known yet", graphics.COLOR_DIM)
		}
		total: u64 = 1
		for &entry in entries {
			total += entry.size
		}
		// The scale: pixels for each byte, with 20 bits after the point.
		// The largest scale at which the tiles fit in the rows.
		scale := u64(TILE_ROWS * area.width) << 20 / total
		for scale > 1 && !tiles_fit(entries, scale, area.width) {
			scale = scale * 15 / 16
		}
		x, row := 0, 0
		for &entry in entries {
			tile := min(tile_width(entry.size, scale), area.width)
			if x + tile > area.width {
				x = 0
				row += 1
			}
			if row >= TILE_ROWS {
				break
			}
			color := hue_color(entry.hash[0])
			y := row * (TILE_HEIGHT + TILE_GAP)
			block(area, x, y, tile, TILE_HEIGHT, graphics.shade(color, 70), graphics.shade(color, 40))
			fill(area, x + 3, y + TILE_HEIGHT - 3, tile - 6, 1, color)
			put_name(&text, entry.name[:])
			text.count = min(text.count, (tile - 6) / 8)
			show(area, x + 4, y + 1, &text, graphics.shade(color, 175))
			x += tile + TILE_GAP
		}
		if len(entries) != 0 {
			put_number(&text, u64(len(entries)))
			put(&text, " modules, ")
			put_size(&text, u64(len(data.image)))
			show_right(canvas, MARGIN + LEFT_WIDTH - CARD_MARGIN, BOTTOM_Y + 13, &text, graphics.COLOR_TEXT)
		}
	}

	// The programs.
	{
		area := card(canvas, RIGHT_X, BOTTOM_Y, WIDTH - RIGHT_X - MARGIN, BOTTOM_HEIGHT, "PROGRAMS", "threads, pages, created", graphics.COLOR_PROGRAM)
		if data.program_count == 0 {
			write(area, 0, 0, "No program runs yet.", graphics.COLOR_DIM)
		} else {
			put_number(&text, u64(data.program_total))
			show_right(canvas, WIDTH - MARGIN - CARD_MARGIN, BOTTOM_Y + 13, &text, graphics.COLOR_TEXT)
		}
		most: u64 = 1
		for &program in data.programs[:data.program_count] {
			most = max(most, program.report.mapped_pages)
		}
		for &program, index in data.programs[:data.program_count] {
			if (index + 1) * LINE > area.height {
				break
			}
			y := index * LINE
			put_number(&text, program.slot)
			show_right(area, 16, y, &text, graphics.COLOR_DIM)
			put_name(&text, program.report.name[:])
			text.count = min(text.count, 12)
			show(area, 28, y, &text, program.report.state == .Stopped ? graphics.COLOR_FAILED : graphics.COLOR_TEXT)
			put_number(&text, program.report.thread_count)
			show_right(area, 150, y, &text, graphics.COLOR_TEXT)
			// The pages of the program, as a bar against the largest program.
			block(area, 162, y + 5, 56, 6, graphics.COLOR_TRACK, graphics.COLOR_TRACK)
			block(area, 162, y + 5, max(int(program.report.mapped_pages * 56 / most), 4), 6, graphics.shade(graphics.COLOR_PROGRAM, 120), graphics.shade(graphics.COLOR_PROGRAM, 80))
			put_number(&text, program.report.mapped_pages)
			show_right(area, 264, y, &text, graphics.COLOR_TEXT)
			put_duration(&text, program.report.start_time)
			show_right(area, area.width, y, &text, graphics.COLOR_PROGRAM)
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
	fill(screen, 0, 0, screen.width, y, graphics.COLOR_BACKGROUND)
	fill(screen, 0, y + HEIGHT, screen.width, screen.height - y - HEIGHT, graphics.COLOR_BACKGROUND)
	fill(screen, 0, y, x, HEIGHT, graphics.COLOR_BACKGROUND)
	fill(screen, x + WIDTH, y, screen.width - x - WIDTH, HEIGHT, graphics.COLOR_BACKGROUND)
	draw(graphics.view(screen, x, y, WIDTH, HEIGHT), data)
}
