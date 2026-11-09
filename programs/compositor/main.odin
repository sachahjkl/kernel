// The compositor (docs/ARCHITECTURE.md, U8): the service that owns the
// display. It combines the surfaces of programs into the framebuffer, and it
// sends input to the program that has focus. It is also the desktop shell of
// this first version: a bar with a launcher, and windows that the person moves.
package compositor

import "../../display"
import "../../graphics"
import "../../ring"
import "../../system"
import "base:intrinsics"

// The context of this service.
GRANT_FRAMEBUFFER :: 0
GRANT_INPUT :: 1
GRANT_CONTROL :: 2
VALUE_WIDTH :: 0
VALUE_HEIGHT :: 1
VALUE_PIXELS_PER_LINE :: 2
VALUE_FORMAT :: 3
FORMAT_RED_FIRST :: 2 // boot_info.Pixel_Format.Red_Green_Blue_X

FRAME_INTERVAL :: 16 // Milliseconds.
BAR_HEIGHT :: 28
TITLE_HEIGHT :: 24
BORDER :: 2
CLOSE_SIZE :: 16
CLIENT_CAPACITY :: 16
SHADOW :: 4
DAMAGE_CAPACITY :: 8
POINTER_WIDTH :: 11
POINTER_HEIGHT :: 17

COLOR_BAR :: 0x1B2430
COLOR_BAR_TEXT :: 0xE8EEF4
COLOR_BUTTON :: 0x2F4156
COLOR_FOCUS :: 0x3F7CC4
COLOR_NO_FOCUS :: 0x5A6470
COLOR_CLOSE :: 0xD05050
COLOR_EMPTY :: 0x10141A

Client :: struct {
	ring_memory: system.Handle, // 0: the slot is free.
	ring:        ^ring.Ring,
	surface:     graphics.Canvas, // pixels is nil until the program creates its surface.
	x, y:        int,
	title:       system.Name,
}

// A rectangle of the screen. right and bottom are not in the rectangle.
Rectangle :: struct {
	left, top, right, bottom: int,
}

@(rodata)
launcher := [?]string{"console", "monitor", "plasma", "life", "paint", "fault", "temple"}

@(rodata)
pointer_shape := [?]string {
	"X          ",
	"XX         ",
	"X.X        ",
	"X..X       ",
	"X...X      ",
	"X....X     ",
	"X.....X    ",
	"X......X   ",
	"X.......X  ",
	"X........X ",
	"X.....XXXXX",
	"X..X..X    ",
	"X.X X..X   ",
	"XX  X..X   ",
	"X    X..X  ",
	"     X..X  ",
	"      XX   ",
}

screen: graphics.Canvas // The framebuffer of the machine.
red_first: bool
frame: graphics.Canvas // The picture that the compositor builds, then copies to the screen.
background: graphics.Canvas
clients: [CLIENT_CAPACITY]Client
order: [CLIENT_CAPACITY]int // The clients that have a surface, from back to front. The last one has focus.
order_count: int
placed: int
input: ^ring.Ring
control: ^ring.Ring
control_memory: system.Handle
pointer_x, pointer_y: int
buttons: u32
dragging := -1
drag_x, drag_y: int
damage: [DAMAGE_CAPACITY]Rectangle // The parts of the screen that the next frame draws again.
damage_count: int
frames: u64

// damage_add records that a rectangle of the screen changed. Rectangles that
// touch become one rectangle. If there is no room, the new rectangle joins
// the first one.
damage_add :: proc "contextless" (x, y, width, height: int) {
	area := Rectangle{max(x, 0), max(y, 0), min(x + width, screen.width), min(y + height, screen.height)}
	if area.left >= area.right || area.top >= area.bottom {
		return
	}
	index := 0
	for index < damage_count {
		other := damage[index]
		apart := area.left > other.right || other.left > area.right || area.top > other.bottom || other.top > area.bottom
		if apart && damage_count < DAMAGE_CAPACITY {
			index += 1
			continue
		}
		area = {min(area.left, other.left), min(area.top, other.top), max(area.right, other.right), max(area.bottom, other.bottom)}
		damage_count -= 1
		damage[index] = damage[damage_count]
		index = 0 // The larger rectangle can touch one that it did not touch before.
	}
	damage[damage_count] = area
	damage_count += 1
}

// damage_window records the rectangle of a window, with its shadow.
damage_window :: proc "contextless" (client: ^Client) {
	if client.surface.pixels != nil {
		damage_add(client.x, client.y, client.surface.width + 2 * BORDER + SHADOW, client.surface.height + TITLE_HEIGHT + BORDER + SHADOW)
	}
}

// damage_focus records the window that has focus: its title changes color
// when the focus changes.
damage_focus :: proc "contextless" () {
	if order_count > 0 {
		damage_window(&clients[order[order_count - 1]])
	}
}

damage_clock :: proc "contextless" () {
	width := graphics.text_width("00:00:00")
	damage_add(screen.width - width - 10, 6, width, graphics.CELL_HEIGHT)
}

canvas_create :: proc "contextless" (width, height: int) -> graphics.Canvas {
	memory, status := system.memory_create((u64(width * height * 4) + system.PAGE_SIZE - 1) / system.PAGE_SIZE)
	address: rawptr
	if status == .Ok {
		address, status = system.memory_map(memory)
	}
	if status != .Ok {
		system.log("compositor: no memory")
		system.stop(1)
	}
	return {pixels = ([^]graphics.Color)(address), width = width, height = height, stride = width}
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	width := int(ctx.values[VALUE_WIDTH])
	height := int(ctx.values[VALUE_HEIGHT])
	address, status := system.memory_map(ctx.handles[GRANT_FRAMEBUFFER])
	input_address, input_status := system.memory_map(ctx.handles[GRANT_INPUT])
	control_address, control_status := system.memory_map(ctx.handles[GRANT_CONTROL])
	if status != .Ok || input_status != .Ok || control_status != .Ok || width == 0 {
		system.log("compositor: no framebuffer")
		system.stop(1)
	}
	screen = {pixels = ([^]graphics.Color)(address), width = width, height = height, stride = int(ctx.values[VALUE_PIXELS_PER_LINE])}
	red_first = ctx.values[VALUE_FORMAT] == FORMAT_RED_FIRST
	input = (^ring.Ring)(input_address)
	control = (^ring.Ring)(control_address)
	control_memory = ctx.handles[GRANT_CONTROL]
	frame = canvas_create(width, height)
	background = canvas_create(width, height)
	for y in 0 ..< height {
		// From dark blue at the top to green-blue at the bottom.
		level := u32(y * 255 / height)
		color := graphics.rgb(18 + level * 14 / 255, 40 + level * 70 / 255, 78 + level * 50 / 255)
		graphics.fill(background, 0, y, width, 1, color)
	}
	pointer_x, pointer_y = width / 2, height / 2
	damage_add(0, 0, width, height)
	system.log("compositor: ok ", u64(width), "x", u64(height))

	next_frame: u64
	shown_second: u64
	for {
		now := system.wait(damage_count > 0 ? max(next_frame, 1) : (shown_second + 1) * 1000)
		for record in ring.pop(&control.commands) {
			#partial switch display.Control(record.kind) {
			case .Client_Add:
				client_add(system.Handle(record.values[0]))
			case .Client_Remove:
				client_remove(system.Handle(record.values[0]))
			}
		}
		for record in ring.pop(&input.commands) {
			#partial switch display.Input(record.kind) {
			case .Key:
				if order_count > 0 {
					send(&clients[order[order_count - 1]], ring.Record{kind = u32(display.Event_Kind.Key), values = record.values})
				}
			case .Pointer:
				pointer_moved(int(i64(record.values[0])), int(i64(record.values[1])), u32(record.values[2]))
			}
		}
		for &client, index in clients {
			if client.ring == nil {
				continue
			}
			for record in ring.pop(&client.ring.commands) {
				#partial switch display.Command(record.kind) {
				case .Surface_Create:
					surface_create(index, record)
				case .Present:
					if client.surface.pixels != nil {
						damage_add(client.x + BORDER, client.y + TITLE_HEIGHT, client.surface.width, client.surface.height)
					}
				}
			}
		}
		if now / 1000 != shown_second {
			shown_second = now / 1000
			damage_clock()
		}
		if damage_count > 0 && now >= next_frame {
			draw(now)
			next_frame = now + FRAME_INTERVAL
			frames += 1
			if frames == 1 {
				system.log("compositor: first frame")
			}
		}
	}
}

send :: proc "contextless" (client: ^Client, record: ring.Record) {
	if ring.push(&client.ring.completions, record) {
		system.wake(client.ring_memory)
	}
}

client_add :: proc "contextless" (memory: system.Handle) {
	for &client in clients {
		if client.ring_memory != 0 {
			continue
		}
		address, status := system.memory_map(memory)
		if status != .Ok {
			break
		}
		client = {ring_memory = memory, ring = (^ring.Ring)(address)}
		return
	}
	system.close(memory)
}

client_remove :: proc "contextless" (memory: system.Handle) {
	for &client, index in clients {
		if client.ring_memory != memory {
			continue
		}
		for position in 0 ..< order_count {
			if order[position] == index {
				intrinsics.mem_copy(&order[position], &order[position + 1], (order_count - position - 1) * size_of(int))
				order_count -= 1
				break
			}
		}
		if dragging == index {
			dragging = -1
		}
		damage_window(&client)
		damage_focus()
		if client.surface.pixels != nil {
			system.memory_unmap(client.surface.pixels)
		}
		system.memory_unmap(client.ring)
		system.close(client.ring_memory)
		client = {}
		return
	}
}

surface_create :: proc "contextless" (index: int, record: ring.Record) {
	client := &clients[index]
	memory := system.Handle(record.values[0])
	width, height := record.values[1], record.values[2]
	// The program chose these numbers: check them against the memory itself.
	if client.surface.pixels != nil || width == 0 || height == 0 || width > display.SURFACE_LIMIT || height > display.SURFACE_LIMIT {
		return
	}
	if system.memory_size(memory) * system.PAGE_SIZE < width * height * size_of(graphics.Color) {
		system.close(memory)
		return
	}
	address, status := system.memory_map(memory, {}) // Read only.
	system.close(memory)
	if status != .Ok {
		return
	}
	client.surface = {pixels = ([^]graphics.Color)(address), width = int(width), height = int(height), stride = int(width)}
	client.title = system.name_unpack({record.values[3], record.values[4], record.values[5], record.values[6]})
	client.x = 60 + placed % 8 * 36
	client.y = BAR_HEIGHT + 24 + placed % 8 * 30
	placed += 1
	damage_focus()
	order[order_count] = index
	order_count += 1
	damage_window(client)
	system.log("compositor: surface ", system.name_of(client.title[:]), " ", width, "x", height)
}

raise :: proc "contextless" (position: int) {
	index := order[position]
	if position == order_count - 1 {
		return
	}
	damage_focus()
	damage_window(&clients[index])
	intrinsics.mem_copy(&order[position], &order[position + 1], (order_count - position - 1) * size_of(int))
	order[order_count - 1] = index
}

inside :: proc "contextless" (x, y, left, top, width, height: int) -> bool {
	return x >= left && y >= top && x < left + width && y < top + height
}

pointer_moved :: proc "contextless" (motion_x, motion_y: int, new_buttons: u32) {
	damage_add(pointer_x, pointer_y, POINTER_WIDTH, POINTER_HEIGHT)
	pointer_x = clamp(pointer_x + motion_x, 0, screen.width - 1)
	pointer_y = clamp(pointer_y + motion_y, 0, screen.height - 1)
	damage_add(pointer_x, pointer_y, POINTER_WIDTH, POINTER_HEIGHT)
	pressed := new_buttons & display.BUTTON_LEFT != 0 && buttons & display.BUTTON_LEFT == 0
	held := buttons != 0 || new_buttons != 0
	buttons = new_buttons

	if dragging >= 0 {
		if buttons & display.BUTTON_LEFT != 0 {
			damage_window(&clients[dragging])
			clients[dragging].x = pointer_x - drag_x
			clients[dragging].y = max(pointer_y - drag_y, BAR_HEIGHT)
			damage_window(&clients[dragging])
		} else {
			dragging = -1
		}
		return
	}
	if pressed {
		if pointer_y < BAR_HEIGHT {
			x := launcher_start()
			for name in launcher {
				width := graphics.text_width(name) + 16
				if inside(pointer_x, pointer_y, x, 3, width, BAR_HEIGHT - 6) {
					packed := system.name_pack(name)
					ring.push(&control.completions, ring.Record{kind = u32(display.Control.Start), values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}})
					system.wake(control_memory)
				}
				x += width + 6
			}
			return
		}
		for position := order_count - 1; position >= 0; position -= 1 {
			client := &clients[order[position]]
			outer_width := client.surface.width + 2 * BORDER
			if !inside(pointer_x, pointer_y, client.x, client.y, outer_width, client.surface.height + TITLE_HEIGHT + BORDER) {
				continue
			}
			raise(position)
			if inside(pointer_x, pointer_y, client.x + outer_width - CLOSE_SIZE - 6, client.y + 4, CLOSE_SIZE, CLOSE_SIZE) {
				ring.push(&control.completions, ring.Record{kind = u32(display.Control.Stop), values = {0 = u64(client.ring_memory)}})
				system.wake(control_memory)
				return
			}
			if pointer_y < client.y + TITLE_HEIGHT {
				dragging = order[order_count - 1]
				drag_x, drag_y = pointer_x - client.x, pointer_y - client.y
				return
			}
			break
		}
	}
	// The program with focus receives the pointer when it is over its surface,
	// and while a button is down.
	if order_count > 0 {
		client := &clients[order[order_count - 1]]
		x := pointer_x - client.x - BORDER
		y := pointer_y - client.y - TITLE_HEIGHT
		if held || inside(x, y, 0, 0, client.surface.width, client.surface.height) {
			send(client, ring.Record{kind = u32(display.Event_Kind.Pointer), values = {0 = u64(i64(x)), 1 = u64(i64(y)), 2 = u64(buttons)}})
		}
	}
}

launcher_start :: proc "contextless" () -> int {
	return graphics.text_width("kernel") + 28
}

// draw draws again each damage rectangle, then copies it to the screen.
draw :: proc "contextless" (now: u64) {
	for area in damage[:damage_count] {
		draw_area(area, now)
	}
	damage_count = 0
}

// draw_area draws all that is in one rectangle of the screen. The canvas is
// the part of the frame in the rectangle: it clips each drawing operation.
draw_area :: proc "contextless" (area: Rectangle, now: u64) {
	width, height := area.right - area.left, area.bottom - area.top
	canvas := graphics.view(frame, area.left, area.top, width, height)
	origin_x, origin_y := -area.left, -area.top // The corner of the screen, in the canvas.
	graphics.copy(canvas, origin_x, origin_y, background)

	for position in 0 ..< order_count {
		client := &clients[order[position]]
		focus := position == order_count - 1
		outer_width := client.surface.width + 2 * BORDER
		outer_height := client.surface.height + TITLE_HEIGHT + BORDER
		if client.x >= area.right || client.y >= area.bottom || client.x + outer_width + SHADOW <= area.left || client.y + outer_height + SHADOW <= area.top {
			continue
		}
		x, y := client.x + origin_x, client.y + origin_y
		graphics.fill(canvas, x + SHADOW, y + SHADOW, outer_width, outer_height, 0x0A1018)
		graphics.fill(canvas, x, y, outer_width, outer_height, focus ? COLOR_FOCUS : COLOR_NO_FOCUS)
		graphics.text(canvas, x + 8, y + 4, system.name_of(client.title[:]), 0xFFFFFF)
		close_x := x + outer_width - CLOSE_SIZE - 6
		graphics.fill(canvas, close_x, y + 4, CLOSE_SIZE, CLOSE_SIZE, COLOR_CLOSE)
		graphics.line(canvas, close_x + 4, y + 8, close_x + CLOSE_SIZE - 5, y + CLOSE_SIZE - 1, 2, 0xFFFFFF)
		graphics.line(canvas, close_x + CLOSE_SIZE - 5, y + 8, close_x + 4, y + CLOSE_SIZE - 1, 2, 0xFFFFFF)
		graphics.copy(canvas, x + BORDER, y + TITLE_HEIGHT, client.surface)
	}

	// The bar: the name of the system, the launcher, the time since boot.
	if area.top < BAR_HEIGHT {
		y := 6 + origin_y
		graphics.fill(canvas, origin_x, origin_y, frame.width, BAR_HEIGHT, COLOR_BAR)
		graphics.text(canvas, 10 + origin_x, y, "kernel", 0x7FC8FF)
		x := launcher_start() + origin_x
		for name in launcher {
			button_width := graphics.text_width(name) + 16
			graphics.fill(canvas, x, 3 + origin_y, button_width, BAR_HEIGHT - 6, COLOR_BUTTON)
			graphics.text(canvas, x + 8, y, name, COLOR_BAR_TEXT)
			x += button_width + 6
		}
		seconds := now / 1000
		x = frame.width - graphics.text_width("00:00:00") - 10 + origin_x
		x = graphics.unsigned(canvas, x, y, seconds / 3600, COLOR_BAR_TEXT, 2)
		x = graphics.text(canvas, x, y, ":", COLOR_BAR_TEXT)
		x = graphics.unsigned(canvas, x, y, seconds / 60 % 60, COLOR_BAR_TEXT, 2)
		x = graphics.text(canvas, x, y, ":", COLOR_BAR_TEXT)
		graphics.unsigned(canvas, x, y, seconds % 60, COLOR_BAR_TEXT, 2)
	}

	for row, y in pointer_shape {
		for column in 0 ..< len(row) {
			switch row[column] {
			case 'X':
				graphics.pixel(canvas, pointer_x + column + origin_x, pointer_y + y + origin_y, 0x000000)
			case '.':
				graphics.pixel(canvas, pointer_x + column + origin_x, pointer_y + y + origin_y, 0xFFFFFF)
			}
		}
	}

	target := graphics.view(screen, area.left, area.top, width, height)
	if !red_first {
		graphics.copy(target, 0, 0, canvas)
		return
	}
	for y in 0 ..< height {
		for column in 0 ..< width {
			color := canvas.pixels[y * canvas.stride + column]
			target.pixels[y * target.stride + column] = color >> 16 & 0xFF | color & 0xFF00 | (color & 0xFF) << 16
		}
	}
}
