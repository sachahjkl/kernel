// The compositor (docs/ARCHITECTURE.md, U8): the service that owns the
// display. It combines the surfaces of programs into the framebuffer, and it
// sends input to the program that has focus. It is also the desktop shell of
// this first version: a bar with the menu of the programs and the menu of
// the windows, and windows that the person moves. It follows the design
// rules (docs/DESIGN.md): rectangles only, the grid of 8 pixels, the colors
// of support/graphics.
package compositor

import "support:display"
import "support:graphics"
import "support:bar"
import "contract:ring"
import "support:system"
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
BAR_HEIGHT :: bar.HEIGHT
// The frame of a window: a title bar over the surface, and a border of
// BORDER pixels at the left, the right and the bottom. The machine test
// reads these numbers (tools/kerneltool/machine.odin, WINDOW_*).
TITLE_HEIGHT :: 24
BORDER :: 2
CLOSE_SIZE :: 24 // The close button: a square at the right end of the title bar.
// A new window: the first one at (PLACE_X, PLACE_Y), each next one lower
// and to the right, by PLACE_STEP_X and PLACE_STEP_Y.
PLACE_X :: 60
PLACE_Y :: 52
PLACE_STEP_X :: 36
PLACE_STEP_Y :: 30
CLIENT_CAPACITY :: 32 // The root service starts 32 programs at most.
DAMAGE_CAPACITY :: 8
POINTER_CELL :: 2 // The pointer is drawn with squares of 2 pixels.
POINTER_WIDTH :: 8 * POINTER_CELL
POINTER_HEIGHT :: 11 * POINTER_CELL
CLOCK_WIDTH :: 8 * 8 // "00:00:00"

Client :: struct {
	ring_memory: system.Handle, // 0: the slot is free.
	ring:        ring.Ring,
	surface:     graphics.Canvas, // pixels is nil until the program creates its surface.
	pictures:    [^]graphics.Color, // The memory of the surface: one picture or two. surface is one of them.
	picture_count: u64,
	x, y:        int,
	title:       system.Name,
}

// A rectangle of the screen. right and bottom are not in the rectangle.
Rectangle :: struct {
	left, top, right, bottom: int,
}

// The pointer: X is a black square, . a white one. The point of the
// pointer is the top left square.
@(rodata)
pointer_shape := [?]string {
	"X       ",
	"XX      ",
	"X.X     ",
	"X..X    ",
	"X...X   ",
	"X....X  ",
	"X.....X ",
	"X......X",
	"X..XXXXX",
	"X.X     ",
	"XX      ",
}

screen: graphics.Canvas // The framebuffer of the machine.
red_first: bool
frame: graphics.Canvas // The picture that the compositor builds, then copies to the screen.
background: graphics.Canvas
clients: [CLIENT_CAPACITY]Client
order: [CLIENT_CAPACITY]int // The clients that have a surface, from back to front. The last one has focus.
order_count: int
placed: int
input: ring.Ring
control: ring.Ring
pointer_x, pointer_y: int
buttons: u32
dragging := -1
// A menu of the bar.
Menu :: enum {
	None,
	Programs, // The menu of the programs: a press on a line starts the program.
	Windows, // One line for each window, in the order of the client table: a press brings the window to the front.
}

menu_open: Menu // The menu that is on the screen.
menu_line := -1 // The line of the menu under the pointer.
drag_x, drag_y: int
damage: [DAMAGE_CAPACITY]Rectangle // The parts of the screen that the next frame draws again.
damage_count: int
frames: u64
// The measures of the time of a frame (docs/DESIGN.md, section 7). A full
// frame draws the whole screen: the first frame, and the frame after a
// person puts a window down. The frames of a move are the frames while a
// person drags a window.
full_measure: bool // The next frame draws the whole screen, and the log has its time.
move_frames, move_time, move_longest: u64 // Nanoseconds.

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

// damage_window records the rectangle of a window.
damage_window :: proc "contextless" (client: ^Client) {
	if client.surface.pixels != nil {
		damage_add(client.x, client.y, client.surface.width + 2 * BORDER, client.surface.height + TITLE_HEIGHT + BORDER)
	}
}

// damage_focus records the window that has focus: its title changes color
// when the focus changes.
damage_focus :: proc "contextless" () {
	if order_count > 0 {
		damage_window(&clients[order[order_count - 1]])
	}
}

// damage_menu records the buttons of the bar and their menus.
damage_menu :: proc "contextless" () {
	x, y, width, height := bar.button()
	damage_add(x, y, width, height)
	x, y, width, height = bar.menu()
	damage_add(x, y, width, height)
	x, y, width, height = bar.windows_button()
	damage_add(x, y, width, height)
	x, y, width, height = bar.windows_menu(CLIENT_CAPACITY) // A window can leave while the menu is open.
	damage_add(x, y, width, height)
}

// window_of_line gives the client of a line of the menu of the windows, or -1.
window_of_line :: proc "contextless" (line: int) -> int {
	count := 0
	for &client, index in clients {
		if client.surface.pixels == nil {
			continue
		}
		if count == line {
			return index
		}
		count += 1
	}
	return -1
}

// windows_log writes the lines of the menu of the windows on the log, in
// their order: "compositor: windows: console, life, monitor".
windows_log :: proc "contextless" () {
	buffer: [CLIENT_CAPACITY * (size_of(system.Name) + 2)]u8
	count := 0
	for &client in clients {
		if client.surface.pixels == nil {
			continue
		}
		if count > 0 {
			count += copy(buffer[count:], ", ")
		}
		count += copy(buffer[count:], system.name_of(client.title[:]))
	}
	system.log_in("surfaces", .Info, "compositor: windows: ", string(buffer[:count]))
}

damage_clock :: proc "contextless" () {
	damage_add(screen.width - CLOCK_WIDTH - 16, 8, CLOCK_WIDTH, graphics.CELL_HEIGHT)
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
	input_status, control_status: system.Status
	input, input_status = system.ring_open(ctx.handles[GRANT_INPUT])
	control, control_status = system.ring_open(ctx.handles[GRANT_CONTROL])
	if status != .Ok || input_status != .Ok || control_status != .Ok || width == 0 {
		system.log("compositor: no framebuffer")
		system.stop(1)
	}
	screen = {pixels = ([^]graphics.Color)(address), width = width, height = height, stride = int(ctx.values[VALUE_PIXELS_PER_LINE])}
	red_first = ctx.values[VALUE_FORMAT] == FORMAT_RED_FIRST
	frame = canvas_create(width, height)
	background = canvas_create(width, height)
	// The background of the rules: one color, and a grid of points.
	graphics.clear(background, graphics.COLOR_BACKGROUND)
	for y := graphics.POINT_STEP / 2; y < height; y += graphics.POINT_STEP {
		for x := graphics.POINT_STEP / 2; x < width; x += graphics.POINT_STEP {
			graphics.fill(background, x, y, graphics.POINT_SIZE, graphics.POINT_SIZE, graphics.COLOR_POINT)
		}
	}
	pointer_x, pointer_y = width / 2, height / 2
	damage_add(0, 0, width, height)
	full_measure = true
	system.log("compositor: ok ", u64(width), "x", u64(height))

	next_frame: u64
	shown_second: u64
	for {
		wait: system.Wait
		system.wait_records(&wait, &control.commands)
		system.wait_records(&wait, &input.commands)
		for &client in clients {
			if client.ring.head != nil {
				system.wait_records(&wait, &client.ring.commands)
			}
		}
		now := system.wait_end(&wait, damage_count > 0 ? max(next_frame, 1) : (shown_second + 1) * 1000)
		for record in system.receive(&control.commands) {
			#partial switch display.Control(record.kind) {
			case .Client_Add:
				client_add(system.Handle(record.values[0]))
			case .Client_Remove:
				client_remove(system.Handle(record.values[0]))
			}
		}
		for record in system.receive(&input.commands) {
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
			if client.ring.head == nil {
				continue
			}
			for record in system.receive(&client.ring.commands) {
				#partial switch display.Command(record.kind) {
				case .Surface_Create:
					surface_create(index, record)
				case .Present:
					if client.surface.pixels != nil {
						// The program names the picture that is complete.
						if record.values[0] < client.picture_count {
							client.surface.pixels = client.pictures[int(record.values[0]) * client.surface.width * client.surface.height:]
						}
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
	system.send(&client.ring.completions, record)
}

client_add :: proc "contextless" (memory: system.Handle) {
	for &client in clients {
		if client.ring_memory != 0 {
			continue
		}
		opened, status := system.ring_open(memory)
		if status != .Ok {
			break
		}
		client = {ring_memory = memory, ring = opened}
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
				copy(order[position:order_count - 1], order[position + 1:order_count]) // The last place has no next one.
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
			system.memory_unmap(client.pictures)
		}
		system.ring_close(&client.ring)
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
	size := system.memory_size(memory) * system.PAGE_SIZE
	if size < width * height * size_of(graphics.Color) {
		system.close(memory)
		return
	}
	address, status := system.memory_map(memory, {}) // Read only.
	system.close(memory)
	if status != .Ok {
		return
	}
	client.pictures = ([^]graphics.Color)(address)
	client.picture_count = size >= 2 * width * height * size_of(graphics.Color) ? 2 : 1
	client.surface = {pixels = client.pictures, width = int(width), height = int(height), stride = int(width)}
	client.title = system.name_unpack({record.values[3], record.values[4], record.values[5], record.values[6]})
	client.x = PLACE_X + placed % 8 * PLACE_STEP_X
	client.y = PLACE_Y + placed % 8 * PLACE_STEP_Y
	// A large window moves up and left until the screen shows all of it.
	client.x = max(min(client.x, screen.width - int(width) - 2 * BORDER), 0)
	client.y = max(min(client.y, screen.height - int(height) - TITLE_HEIGHT - BORDER), BAR_HEIGHT)
	placed += 1
	damage_focus()
	order[order_count] = index
	order_count += 1
	damage_window(client)
	system.log_in("surfaces", .Info, "compositor: surface ", system.name_of(client.title[:]), " ", width, "x", height, " at ", u64(client.x), ",", u64(client.y))
}

raise :: proc "contextless" (position: int) {
	index := order[position]
	if position == order_count - 1 {
		return
	}
	damage_focus()
	damage_window(&clients[index])
	copy(order[position:order_count - 1], order[position + 1:order_count]) // The last place has no next one.
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
			// The person put the window down: the log has its new place.
			client := &clients[dragging]
			system.log_in("surfaces", .Info, "compositor: window ", system.name_of(client.title[:]), " moved to ", u64(max(client.x, 0)), ",", u64(client.y))
			system.log_in("surfaces", .Info, "compositor: the move of ", system.name_of(client.title[:]), ": ", move_frames, " frames, ", move_time / max(move_frames, 1) / 1000, " us per frame, ", move_longest / 1000, " us the longest")
			move_frames, move_time, move_longest = 0, 0, 0
			dragging = -1
			damage_add(0, 0, screen.width, screen.height)
			full_measure = true
		}
		return
	}
	// The menu of the programs: its button opens it. A press on a line
	// starts the program. Any press closes the menu.
	// The menu of the windows: its button opens it, and a press on a line
	// brings the window to the front.
	if menu_open != .None {
		over := menu_open == .Programs ? bar.line_at(pointer_x, pointer_y) : bar.windows_line_at(order_count, pointer_x, pointer_y)
		if over != menu_line {
			menu_line = over
			damage_menu()
		}
	}
	if pressed {
		was_open := menu_open
		if menu_open != .None {
			if menu_open == .Programs && menu_line >= 0 {
				packed := system.name_pack(bar.names[menu_line])
				system.send(&control.completions, ring.Record{kind = u32(display.Control.Start), values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}})
			}
			if index := window_of_line(menu_line); menu_open == .Windows && menu_line >= 0 && index >= 0 {
				for position in 0 ..< order_count {
					if order[position] == index {
						raise(position)
						break
					}
				}
				system.log_in("surfaces", .Info, "compositor: window ", system.name_of(clients[index].title[:]), " in front")
			}
			menu_open = .None
			menu_line = -1
			damage_menu()
		}
		if x, y, width, height := bar.button(); inside(pointer_x, pointer_y, x, y, width, height) && was_open != .Programs {
			menu_open = .Programs
			system.log_in("surfaces", .Info, "compositor: the menu of the programs is open")
			damage_menu()
		}
		if x, y, width, height := bar.windows_button(); inside(pointer_x, pointer_y, x, y, width, height) && was_open != .Windows {
			menu_open = .Windows
			windows_log()
			damage_menu()
		}
		if was_open != .None || pointer_y < BAR_HEIGHT {
			return
		}
		for position := order_count - 1; position >= 0; position -= 1 {
			client := &clients[order[position]]
			outer_width := client.surface.width + 2 * BORDER
			if !inside(pointer_x, pointer_y, client.x, client.y, outer_width, client.surface.height + TITLE_HEIGHT + BORDER) {
				continue
			}
			raise(position)
			if inside(pointer_x, pointer_y, client.x + outer_width - BORDER - CLOSE_SIZE, client.y, CLOSE_SIZE, TITLE_HEIGHT) {
				system.send(&control.completions, ring.Record{kind = u32(display.Control.Stop), values = {0 = u64(client.ring_memory)}})
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

// draw draws again each damage rectangle, then copies it to the screen.
draw :: proc "contextless" (now: u64) {
	start := system.nanoseconds()
	for area in damage[:damage_count] {
		draw_area(area, now)
	}
	damage_count = 0
	spent := system.nanoseconds() - start
	if dragging >= 0 {
		move_frames += 1
		move_time += spent
		move_longest = max(move_longest, spent)
	}
	if full_measure {
		full_measure = false
		system.log_in("surfaces", .Info, "compositor: a full frame of ", u64(screen.width), "x", u64(screen.height), " with ", u64(order_count), " windows in ", spent / 1000, " us")
	}
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
		outer_width := client.surface.width + 2 * BORDER
		outer_height := client.surface.height + TITLE_HEIGHT + BORDER
		if client.x >= area.right || client.y >= area.bottom || client.x + outer_width <= area.left || client.y + outer_height <= area.top {
			continue
		}
		window_draw(canvas, client, client.x + origin_x, client.y + origin_y, position == order_count - 1)
	}

	// The bar: the name of the system, the two buttons, the time since boot.
	if area.top < BAR_HEIGHT {
		y := 8 + origin_y
		graphics.block(canvas, origin_x, origin_y, frame.width, BAR_HEIGHT - 1, graphics.COLOR_CARD_TOP, graphics.COLOR_CARD_BOTTOM)
		graphics.fill(canvas, origin_x, origin_y + BAR_HEIGHT - 1, frame.width, 1, graphics.COLOR_TRACK)
		graphics.text(canvas, 16 + origin_x, y, "kernel", graphics.COLOR_TEXT)
		left, top, button_width, button_height := bar.button()
		button_draw(canvas, left + origin_x, top + origin_y, button_width, button_height, bar.LABEL, menu_open == .Programs)
		left, top, button_width, button_height = bar.windows_button()
		button_draw(canvas, left + origin_x, top + origin_y, button_width, button_height, bar.WINDOWS_LABEL, menu_open == .Windows)
		seconds := now / 1000
		x := frame.width - CLOCK_WIDTH - 16 + origin_x
		x = graphics.unsigned(canvas, x, y, seconds / 3600, graphics.COLOR_TEXT, 2)
		x = graphics.text(canvas, x, y, ":", graphics.COLOR_DIM)
		x = graphics.unsigned(canvas, x, y, seconds / 60 % 60, graphics.COLOR_TEXT, 2)
		x = graphics.text(canvas, x, y, ":", graphics.COLOR_DIM)
		graphics.unsigned(canvas, x, y, seconds % 60, graphics.COLOR_TEXT, 2)
	}

	// The menus of the bar, over the windows.
	if menu_open == .Windows && order_count > 0 {
		left, top, menu_width, menu_height := bar.windows_menu(order_count)
		card_draw(canvas, left + origin_x, top + origin_y, menu_width, menu_height, "WINDOWS", "the client table", u64(order_count))
		for line in 0 ..< order_count {
			index := window_of_line(line)
			if index < 0 {
				break
			}
			x, y, line_width, line_height := bar.windows_line(line)
			x, y = x + origin_x, y + origin_y
			focus := index == order[order_count - 1]
			if line == menu_line {
				graphics.fill(canvas, x, y, line_width, line_height, graphics.COLOR_TITLE)
			}
			if focus {
				// The window that has the focus: a square, and its title in white.
				graphics.fill(canvas, x + 8, y + 8, 8, 8, line == menu_line ? graphics.COLOR_WHITE : graphics.COLOR_TITLE)
			}
			graphics.text(canvas, x + 24, y + 4, system.name_of(clients[index].title[:]), focus || line == menu_line ? graphics.COLOR_WHITE : graphics.COLOR_TEXT)
		}
	}
	if menu_open == .Programs {
		left, top, menu_width, menu_height := bar.menu()
		card_draw(canvas, left + origin_x, top + origin_y, menu_width, menu_height, "PROGRAMS", "bar.names", len(bar.names))
		for name, index in bar.names {
			x, y, line_width, line_height := bar.line(index)
			x, y = x + origin_x, y + origin_y
			if index == menu_line {
				graphics.fill(canvas, x, y, line_width, line_height, graphics.COLOR_TITLE)
			}
			graphics.text(canvas, x + bar.PADDING, y + 4, name, index == menu_line ? graphics.COLOR_WHITE : graphics.COLOR_TEXT)
		}
	}

	for row, y in pointer_shape {
		for column in 0 ..< len(row) {
			color: graphics.Color
			switch row[column] {
			case 'X':
				color = graphics.COLOR_BLACK
			case '.':
				color = graphics.COLOR_WHITE
			case:
				continue
			}
			graphics.fill(canvas, pointer_x + column * POINTER_CELL + origin_x, pointer_y + y * POINTER_CELL + origin_y, POINTER_CELL, POINTER_CELL, color)
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

// window_draw draws a window at (x, y) of the canvas: its frame, then its
// surface. The title bar of the window that has the focus is blue; the
// title bar of another window is quiet.
window_draw :: proc "contextless" (canvas: graphics.Canvas, client: ^Client, x, y: int, focus: bool) {
	outer_width := client.surface.width + 2 * BORDER
	outer_height := client.surface.height + TITLE_HEIGHT + BORDER
	start := graphics.Color(focus ? graphics.COLOR_TITLE : graphics.COLOR_TITLE_QUIET)
	end := graphics.Color(focus ? graphics.COLOR_TITLE_END : graphics.COLOR_TITLE_QUIET_END)
	graphics.fill(canvas, x, y, outer_width, TITLE_HEIGHT, start)
	graphics.fill(canvas, x, y + TITLE_HEIGHT, BORDER, outer_height - TITLE_HEIGHT, start)
	graphics.fill(canvas, x + outer_width - BORDER, y + TITLE_HEIGHT, BORDER, outer_height - TITLE_HEIGHT, end)
	graphics.fill(canvas, x, y + outer_height - BORDER, outer_width, BORDER, start)
	title_draw(canvas, client, x, y, focus, end)
	graphics.copy(canvas, x + BORDER, y + TITLE_HEIGHT, client.surface)
}

// title_draw draws the title and the close button on a title bar.
title_draw :: proc "contextless" (canvas: graphics.Canvas, client: ^Client, x, y: int, focus: bool, end: graphics.Color) {
	outer_width := client.surface.width + 2 * BORDER
	title := system.name_of(client.title[:])
	shown := clamp((outer_width - CLOSE_SIZE - 16) / graphics.CELL_WIDTH, 0, len(title))
	graphics.text(canvas, x + 8, y + 4, title[:shown], focus ? graphics.COLOR_WHITE : graphics.COLOR_DIM)
	close_x := x + outer_width - BORDER - CLOSE_SIZE
	graphics.fill(canvas, close_x, y, CLOSE_SIZE, TITLE_HEIGHT, graphics.shade(end, 70))
	graphics.character(canvas, close_x + (CLOSE_SIZE - graphics.CELL_WIDTH) / 2, y + (TITLE_HEIGHT - graphics.CELL_HEIGHT) / 2, 'x', focus ? graphics.COLOR_WHITE : graphics.COLOR_DIM)
}

// button_draw draws a button of the bar. The button of an open menu is blue.
button_draw :: proc "contextless" (canvas: graphics.Canvas, x, y, width, height: int, label: string, open: bool) {
	graphics.fill(canvas, x, y, width, height, open ? graphics.COLOR_TITLE : graphics.COLOR_TRACK)
	graphics.text(canvas, x + bar.PADDING, y + (height - graphics.CELL_HEIGHT) / 2, label, open ? graphics.COLOR_WHITE : graphics.COLOR_TEXT)
}

// card_draw draws a card of the rules (docs/DESIGN.md, section 3): a border
// of 1 pixel in the color of the kernel, the surface of a card, and the
// title, the caption and the count of its lines.
card_draw :: proc "contextless" (canvas: graphics.Canvas, x, y, width, height: int, title, caption: string, count: u64) {
	accent :: graphics.COLOR_KERNEL
	graphics.block(canvas, x, y, width, height, graphics.shade(accent, 28), graphics.shade(accent, 14))
	graphics.block(canvas, x + 1, y + 1, width - 2, height - 2, graphics.COLOR_CARD_TOP, graphics.COLOR_CARD_BOTTOM)
	graphics.block(canvas, x + graphics.CARD_MARGIN, y + 12, 4, 16, graphics.shade(accent, 130), accent)
	after := graphics.text(canvas, x + graphics.CARD_MARGIN + 12, y + 12, title, accent)
	graphics.text(canvas, after + 16, y + 12, caption, graphics.COLOR_DIM)
	digits := 1
	for rest := count / 10; rest != 0; rest /= 10 {
		digits += 1
	}
	graphics.unsigned(canvas, x + width - graphics.CARD_MARGIN - digits * graphics.CELL_WIDTH, y + 12, count, graphics.COLOR_TEXT)
}
