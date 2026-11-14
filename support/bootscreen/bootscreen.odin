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
//
// ```odin
// data: bootscreen.Data
// collect.data(&data, machine) // Fills it from the reports of the kernel.
// bootscreen.draw(canvas, &data)
// ```
//
// See [boot display](term:boot-display).
package bootscreen

import info "contract:boot_info"
import "support:bootscreen/image_card"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:mark"
import op "contract:operation"
import "base:intrinsics"

WIDTH :: 976 // The size that the display needs.
HEIGHT :: 700 // Pixels.
PROCESSOR_ROWS :: 16 // The processors that the card of the processors shows.
PROGRAM_ROWS :: 12 // The programs that the card of the programs shows.

// The state of the start, which the title of the display says.
State :: enum {
	Running, // The machine starts.
	Ready, // The desktop runs.
	Failed, // The start stopped: `Data.message` says why.
}

// The steps of the start, in their order. The program that draws says
// which step the machine does now: the steps before it are done.
Step :: enum {
	Firmware, // The firmware runs the boot program.
	Kernel_Module, // The boot program loads the kernel module.
	Boot_Image, // The boot program loads the boot image and checks it.
	Memory_Map, // The boot program reads the memory map.
	Kernel, // The boot program ends the firmware and jumps.
	Processors, // The kernel starts the other processors.
	Root, // The root service starts.
	Input, // The root service starts the input service.
	Compositor, // The root service starts the compositor.
	Desktop, // The root service starts the desktop.
}

// One row of the card of the programs.
Program :: struct {
	slot:   u64, // The program slot.
	report: op.Program_Report, // Its report.
}

// What the display shows: the reports of the kernel, the boot image and the
// state of the start. The zero value is valid.
Data :: struct {
	boot:            op.Boot_Report, // The boot record.
	machine:         op.System_Report, // The memory and the counts.
	processors:      [PROCESSOR_ROWS]op.Processor_Report, // The first processors.
	programs:        [PROGRAM_ROWS]Program, // By slot.
	program_count:   int, // The entries of `programs` in use.
	program_total:   int, // All the programs: programs has the first ones.
	image:           []u8, // The boot image.
	processor_name:  [48]u8, // The name that the processor gives of itself.
	message:         string, // What the machine does now.
	failed_name:     string, // The file that failed the check of its hash: the card of the boot image names it.
	state:           State,
	step:            Step, // The step that the machine does now.
	red_first:       bool, // The pixels of the canvas have red in the low byte.
}

LINE :: graphics.LINE_HEIGHT // One line of text.
MARGIN :: graphics.CARD_GAP // The gap around the cards.

// The order of the channels of the canvas of the draw that runs: the boot
// program draws on a framebuffer that can have red in the low byte.
@(private)
red_first: bool

// tone gives a color in the order of the channels of the canvas.
@(private)
tone :: #force_inline proc "contextless" (color: graphics.Color) -> graphics.Color {
	return red_first ? color >> 16 & 0xFF | color & 0xFF00 | color << 16 & 0xFF0000 : color
}

// fill paints a rectangle in a color, in the order of the canvas.
@(private)
fill :: proc "contextless" (canvas: graphics.Canvas, x, y, width, height: int, color: graphics.Color) {
	graphics.fill(canvas, x, y, width, height, tone(color))
}

// A short text that the display builds from parts.
Text :: struct {
	bytes: [120]u8, // The text; the bytes that do not fit are dropped.
	count: int, // The bytes in use.
}

// put adds a text.
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

// put_number adds a number in decimal, with at least minimum_digits digits.
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

// put_hex adds the low `digits` hexadecimal digits of a number.
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

// show draws a text and empties it. It gives the x after the text.
@(private)
show :: proc "contextless" (canvas: graphics.Canvas, x, y: int, text: ^Text, color: graphics.Color) -> int {
	after := write(canvas, x, y, string(text.bytes[:text.count]), color)
	text.count = 0
	return after
}

// write draws a text in the font of the cells, in the order of the canvas.
// It gives the x after the text.
@(private)
write :: proc "contextless" (canvas: graphics.Canvas, x, y: int, characters: string, color: graphics.Color) -> int {
	order := graphics.text_state.order
	graphics.text_state.order = stripes_of_screen(order)
	defer graphics.text_state.order = order
	return graphics.text(canvas, x, y, characters, tone(color))
}

// show_right draws a text that ends at x.
@(private)
show_right :: proc "contextless" (canvas: graphics.Canvas, x, y: int, text: ^Text, color: graphics.Color) {
	show(canvas, x - text.count * 8, y, text, color)
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
	order := graphics.text_state.order
	graphics.text_state.order = stripes_of_screen(order)
	defer graphics.text_state.order = order
	return graphics.text_scaled(canvas, x, y, characters, tone(color), scale)
}

// stripes_of_screen gives the order of the stripes of the vector font for
// the words of the screen: a screen with red in the low byte has the
// channels of a color in the other order.
@(private)
stripes_of_screen :: proc "contextless" (order: graphics.Subpixel_Order) -> graphics.Subpixel_Order {
	if !red_first {
		return order
	}
	#partial switch order {
	case .Red_Green_Blue:
		return .Blue_Green_Red
	case .Blue_Green_Red:
		return .Red_Green_Blue
	}
	return order
}

CARD_TITLE :: graphics.CARD_TITLE // The height of the title of a card.
CARD_MARGIN :: graphics.CARD_MARGIN // The margin inside a card.

// The interface font of the boot display (docs/DESIGN.md, section 5): the
// root service gives it after it validated the caches of the boot image
// (interface_font_use), so its titles and the names of its facts are in
// B612 and its values in the font of the cells. The boot program holds no
// glyph cache: its first screen is in Spleen 8x16, the one font of its
// binary.
boot_interface_font: ^display.Interface_Font

// interface_font_use gives the display the interface font that the root
// service validated. nil: the font of the cells for each text.
interface_font_use :: proc "contextless" (font: ^display.Interface_Font) {
	boot_interface_font = font
}

// write_name draws a name in the interface font when the display has it,
// cut to room, else in the font of the cells, and gives the x after it.
@(private)
write_name :: proc "contextless" (canvas: graphics.Canvas, x, y: int, name: string, room: int, color: graphics.Color) -> int {
	records: [1]interface.Draw_Record
	text: [64]u8
	table := interface.Draw_Table{records = records[:], text = text[:], interface_font = boot_interface_font}
	shown := interface.text_fit(&table, interface.FONT_INTERFACE, name, room)
	if interface.font_in_use(&table, interface.FONT_INTERFACE, len(shown)).kind != .Interface || len(shown) > len(text) {
		return write(canvas, x, y, shown, color)
	}
	order := graphics.text_state.order
	graphics.text_state.order = stripes_of_screen(order)
	defer graphics.text_state.order = order
	after := interface.draw_text(&table, x, y, shown, tone(color), interface.FONT_INTERFACE)
	interface.execute(&table, canvas)
	return after
}

// card draws the frame of one part of the display with the card of the
// interface package (the same card as in each window), and gives the place
// of its content. The caption says which record the card shows.
@(private)
card :: proc "contextless" (canvas: graphics.Canvas, x, y, width, height: int, title, caption: string, accent: graphics.Color) -> graphics.Canvas {
	records: [8]interface.Draw_Record
	text: [128]u8
	table := interface.Draw_Table{records = records[:], text = text[:], interface_font = boot_interface_font}
	frame := interface.Frame{table = &table}
	content := interface.card(&frame, {x, y, width, height}, title, caption, accent)
	interface.execute(&table, canvas)
	return graphics.view(canvas, content.x, content.y, content.width, content.height)
}

// fact draws one line "name value".
@(private)
fact :: proc "contextless" (canvas: graphics.Canvas, y: int, name: string, value: ^Text, color: graphics.Color = graphics.COLOR_TEXT) {
	write_name(canvas, 0, y, name, FACT_VALUE - 8, graphics.COLOR_DIM)
	if value.count == 0 {
		put(value, "not known yet")
		show(canvas, FACT_VALUE, y, value, graphics.COLOR_DIM)
		return
	}
	// A value longer than the card is cut after its last whole word.
	room := max(canvas.width - FACT_VALUE, 0) / graphics.CELL_WIDTH
	if value.count > room {
		value.count = room
		for value.count > 0 && value.bytes[value.count] != ' ' {
			value.count -= 1
		}
		for value.count > 0 && value.bytes[value.count - 1] == ' ' {
			value.count -= 1
		}
	}
	show(canvas, FACT_VALUE, y, value, color)
}

FACT_VALUE :: 120 // The x of the value of a fact, in its card.

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

// The words of each step, for the message of the display.
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

// The card of the boot image (docs/DESIGN.md, section 12): the size
// strip, the rows of names by kind, the line of the check and the line of
// the trust. Package image_card computes the places.
IMAGE_STRIP_HEIGHT :: 12
IMAGE_ROWS_Y :: 20 // The y of the first row of names, in the card.
IMAGE_ROW_PITCH :: 18 // The distance between two rows of names.
IMAGE_LABEL_ROOM :: 80 // The name of a kind: "resources" takes 9 cells.
IMAGE_COUNT_RIGHT :: 128 // The count of a kind ends here: 4 digits after the name.
IMAGE_BYTES_RIGHT :: 208 // The bytes of a kind end here.
IMAGE_NAMES_X :: 216 // The tiles of the names start here.
IMAGE_CHECK_Y :: 96 // The y of the line of the check.
IMAGE_TRUST_Y :: 114 // The y of the line of the trust.

// The layout is large for a stack: one copy serves each draw of the program.
@(private)
image_layout: image_card.Layout

// The name of each kind of file of the boot image.
@(private, rodata)
image_kind_names := [image_card.File_Kind]string {
	.Program  = "programs",
	.No_Entry = "no entry",
	.Resource = "resources",
}

// The color of each kind of file of the boot image.
@(private, rodata)
image_kind_colors := [image_card.File_Kind]graphics.Color {
	.Program  = graphics.COLOR_PROGRAM,
	.No_Entry = graphics.COLOR_NO_ENTRY,
	.Resource = graphics.COLOR_RESOURCE,
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
	// The mark of the system where the name of the system was: the heron
	// with cells of 2 pixels (48 by 48, the height of the large text that was
	// there), and the name of the mark with cells of 3 pixels, at the right
	// of the heron, its bottom on the bottom of the heron. Both end before
	// the path of the steps.
	{
		MARK_LEFT :: 20
		MARK_TOP :: 12
		MARK_CELL_SIZE :: 2
		NAME_GAP :: 12
		NAME_CELL_SIZE :: 3
		channel_order := mark.Channel_Order.Red_In_Low_Byte if red_first else mark.Channel_Order.Red_In_High_Byte
		// Two pixels for a cell: the smooth variant.
		mark.mark_draw(canvas, MARK_LEFT, MARK_TOP, MARK_CELL_SIZE, .Smooth, false, channel_order)
		heron_side := mark.heron_size(MARK_CELL_SIZE)
		_, name_height := mark.name_size(NAME_CELL_SIZE)
		mark.name_draw(canvas, MARK_LEFT + heron_side + NAME_GAP, MARK_TOP + heron_side - name_height, NAME_CELL_SIZE, false, channel_order)
	}
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
		// 236: the six rows of names end at the bottom of its content; the
		// card of the boot image takes the rest for the line of the trust.
		area := card(canvas, MARGIN, 84, WIDTH - 2 * MARGIN, 236, "THE LINE OF TIME", "Boot_Report.stages, Program_Report.start_time: the cycle counter", graphics.COLOR_KERNEL)
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
	MIDDLE_Y :: 328
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

	// The files of the boot image: the size strip, then the kinds with
	// their largest files by name, the check and the trust.
	BOTTOM_Y :: MIDDLE_Y + MIDDLE_HEIGHT + MARGIN
	BOTTOM_HEIGHT :: HEIGHT - BOTTOM_Y - MARGIN
	{
		area := card(canvas, MARGIN, BOTTOM_Y, LEFT_WIDTH, BOTTOM_HEIGHT, "BOOT IMAGE", "Image_Entry, Boot_Report.trust", graphics.COLOR_BOOT_PROGRAM)
		layout := &image_layout
		image_card.layout_compute(layout, data.image, data.failed_name, area.width, area.width - IMAGE_NAMES_X)
		if layout.valid {
			image_card_draw(area, layout)
			put_number(&text, u64(image_card.file_total(layout)))
			put(&text, " files, ")
			put_size(&text, u64(len(data.image)))
			show_right(canvas, MARGIN + LEFT_WIDTH - CARD_MARGIN, BOTTOM_Y + 13, &text, graphics.COLOR_TEXT)
		} else {
			write(area, 0, 0, "not known yet", graphics.COLOR_DIM)
		}
		check_line(area, IMAGE_CHECK_Y, data)
		trust_line(area, IMAGE_TRUST_Y, data)
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

// put_hex_bytes adds two hexadecimal digits for each byte.
put_hex_bytes :: proc "contextless" (text: ^Text, bytes: []u8) {
	characters := "0123456789abcdef"
	for value in bytes {
		put(text, characters[value >> 4:][:1])
		put(text, characters[value & 15:][:1])
	}
}

// image_card_draw draws the size strip and the rows of names of the card
// of the boot image. Two parts that touch take two shades of their kind;
// the failed file is in the color of a failure, in the strip and on its
// tile.
@(private)
image_card_draw :: proc "contextless" (area: graphics.Canvas, layout: ^image_card.Layout) {
	text: Text
	block(area, 0, 0, area.width, IMAGE_STRIP_HEIGHT, graphics.COLOR_TRACK, graphics.COLOR_TRACK)
	for &file, index in layout.files[:layout.file_count] {
		if file.strip_width == 0 {
			continue
		}
		color := file.failed ? graphics.COLOR_FAILED : image_kind_colors[file.kind]
		top := u32((index & 1) == 0 ? 120 : 96)
		block(area, file.strip_x, 0, file.strip_width, IMAGE_STRIP_HEIGHT, graphics.shade(color, top), graphics.shade(color, top - 42))
	}
	names_width := area.width - IMAGE_NAMES_X
	for kind in image_card.File_Kind {
		summary := &layout.kinds[kind]
		if summary.row_count == 0 {
			continue
		}
		color := image_kind_colors[kind]
		y := IMAGE_ROWS_Y + summary.first_row * IMAGE_ROW_PITCH
		block(area, 0, y + 3, 10, 10, graphics.shade(color, 125), graphics.shade(color, 78))
		write_name(area, 16, y, image_kind_names[kind], IMAGE_LABEL_ROOM, graphics.COLOR_DIM)
		put_number(&text, u64(summary.count))
		show_right(area, IMAGE_COUNT_RIGHT, y, &text, graphics.COLOR_TEXT)
		put_size(&text, summary.bytes)
		show_right(area, IMAGE_BYTES_RIGHT, y, &text, color)
		// The count of the files of the kind with no tile, after its tiles.
		hidden := summary.count - summary.named
		if hidden > 0 && summary.more_x + image_card.more_width(hidden) <= names_width {
			put(&text, "+")
			put_number(&text, u64(hidden))
			show(area, IMAGE_NAMES_X + summary.more_x, IMAGE_ROWS_Y + summary.more_row * IMAGE_ROW_PITCH, &text, graphics.COLOR_DIM)
		}
	}
	for &tile in layout.tiles[:layout.tile_count] {
		file := &layout.files[tile.file]
		color := file.failed ? graphics.COLOR_FAILED : image_kind_colors[file.kind]
		x := IMAGE_NAMES_X + tile.x
		y := IMAGE_ROWS_Y + tile.row * IMAGE_ROW_PITCH
		block(area, x, y, tile.width, LINE, graphics.shade(color, u32(file.failed ? 70 : 46)), graphics.shade(color, u32(file.failed ? 48 : 30)))
		write(area, x + image_card.TILE_PADDING, y, file.name, graphics.shade(color, 175))
	}
}

// check_line draws what the check of the hashes found: the count of the
// files that have the hash of the system description, or the whole name of
// the file that failed, in the color of a failure.
@(private)
check_line :: proc "contextless" (area: graphics.Canvas, y: int, data: ^Data) {
	text: Text
	x := write_name(area, 0, y, "check", FACT_VALUE - 8, graphics.COLOR_DIM)
	x = max(x + 8, 56)
	trust := &data.boot.trust
	switch {
	case len(data.failed_name) != 0:
		put(&text, "failed: ")
		put(&text, data.failed_name)
		show(area, x, y, &text, graphics.COLOR_FAILED)
	case trust.verifier != .None:
		put_number(&text, trust.entry_count)
		put(&text, " verified, the kernel included")
		show(area, x, y, &text, graphics.COLOR_PROGRAM)
	case data.state == .Failed && trust.key_kind != .None:
		write(area, x, y, "no file verified", graphics.COLOR_FAILED)
	case:
		write(area, x, y, "not verified yet", graphics.COLOR_DIM)
	}
}

// trust_part draws one part of the line of the trust, with a comma after
// it unless it is the last, and gives the x of the next part.
@(private)
trust_part :: proc "contextless" (canvas: graphics.Canvas, x, y: int, text: ^Text, color: graphics.Color, last: bool) -> int {
	if !last {
		put(text, ",")
	}
	return show(canvas, x, y, text, color) + (last ? 0 : 8)
}

// trust_line draws the trust record in one line (docs/TRUSTED_BOOT.md,
// "What a failure shows"): which key signed the system description, what
// verified it, and the measure, each in short words and in its own color.
// The long forms are on the log. A test key, a boot program that nothing
// verified and a refused measure are said in plain words: a reader must not
// take such a system for a trusted one.
@(private)
trust_line :: proc "contextless" (area: graphics.Canvas, y: int, data: ^Data) {
	trust := &data.boot.trust
	text: Text
	x := write_name(area, 0, y, "trust", FACT_VALUE - 8, graphics.COLOR_DIM)
	x = max(x + 8, 56)
	color := graphics.Color(graphics.COLOR_DIM)
	switch trust.key_kind {
	case .None:
		put(&text, "not signed")
	case .Test:
		put(&text, "TEST key")
		color = graphics.COLOR_FAILED
	case .Person:
		put(&text, "key ")
		put_hex_bytes(&text, trust.public_key[:4])
		color = graphics.COLOR_TEXT
	}
	x = trust_part(area, x, y, &text, color, false)
	color = graphics.COLOR_DIM
	switch trust.verifier {
	case .None:
		if data.state == .Failed && trust.key_kind != .None {
			put(&text, "check failed")
			color = graphics.COLOR_FAILED
		} else {
			put(&text, "not verified yet")
		}
	case .Boot_Program:
		put(&text, "boot program only")
		color = graphics.COLOR_BOOT_PROGRAM
	case .Firmware_And_Boot_Program:
		put(&text, "Secure Boot")
		color = graphics.COLOR_PROGRAM
	}
	x = trust_part(area, x, y, &text, color, false)
	color = graphics.COLOR_DIM
	switch trust.measure {
	case .None:
		put(&text, "not measured yet")
	case .Measured:
		put(&text, "PCR ")
		put_number(&text, trust.measure_register)
		put(&text, " ")
		put_hex_bytes(&text, trust.measure_value[:4])
		color = graphics.COLOR_PROGRAM
	case .No_Tpm:
		put(&text, "no TPM")
		color = graphics.COLOR_BOOT_PROGRAM
	case .Refused:
		put(&text, "TPM refused the measure")
		color = graphics.COLOR_FAILED
	case .Not_Read:
		put(&text, "PCR not read")
		color = graphics.COLOR_FAILED
	}
	_ = trust_part(area, x, y, &text, color, true)
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
