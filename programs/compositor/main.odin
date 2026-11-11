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
LAUNCHER_HINT :: "launcher: super" // In the bar, at the left of the time.

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
// The launcher: the panel that the key super opens (docs/DESIGN.md, section 9).
launcher_open: bool
typed: [bar.TYPED_CAPACITY]u8 // The part of a name that the person typed.
typed_count: int
matches: [len(bar.names)]int // Indexes in bar.names: the names that contain the typed part.
match_count: int
choice: int // The chosen line: an index in matches.
kept_key: u32 // A key that the launcher took when it was pressed: its release goes to no program.
// The colors of one line of a title bar, and of its lighter top line.
title_row, title_light: [display.SURFACE_LIMIT + 2 * BORDER]graphics.Color

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
	memory_measure()
	title_measure()
	damage_add(0, 0, width, height)
	full_measure = true
	system.log("compositor: ok ", u64(width), "x", u64(height))
	service_start(ctx) // exports.odin

	next_frame: u64
	shown_second: u64
	for {
		wait: system.Wait
		system.wait_records(&wait, &control.commands)
		system.wait_records(&wait, &input.commands)
		system.service_wait(&wait, &service)
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
				if !launcher_key(u32(record.values[0]), u8(record.values[1]), record.values[2] != 0) && order_count > 0 {
					send(&clients[order[order_count - 1]], ring.Record{kind = u32(display.Event_Kind.Key), values = record.values})
				}
			case .Pointer:
				pointer_moved(int(i64(record.values[0])), int(i64(record.values[1])), u32(record.values[2]))
				pointer_moves += 1
			}
		}
		// The calls read the place of the pointer after the input records.
		system.service_run(&service)
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

	if launcher_open {
		// Any press closes the launcher. The pointer does nothing else
		// while the launcher is open.
		if pressed {
			launcher_close("a press of the pointer")
		}
		return
	}
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
		hint_x := frame.width - CLOCK_WIDTH - 32 - graphics.text_width(LAUNCHER_HINT) + origin_x
		graphics.text(canvas, graphics.text(canvas, hint_x, y, "launcher: ", graphics.COLOR_DIM), y, "super", graphics.COLOR_TEXT)
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

	if launcher_open {
		launcher_draw(canvas, origin_x, origin_y)
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
// surface. The title bar of the window that has the focus goes from the blue
// of the title, at the left, to a darker blue, at the right; the title bar
// of another window is quiet. The colors of one line of the title bar are
// computed once, for the columns that the canvas shows, then copied to each
// line.
window_draw :: proc "contextless" (canvas: graphics.Canvas, client: ^Client, x, y: int, focus: bool) {
	outer_width := client.surface.width + 2 * BORDER
	outer_height := client.surface.height + TITLE_HEIGHT + BORDER
	start := graphics.Color(focus ? graphics.COLOR_TITLE : graphics.COLOR_TITLE_QUIET)
	end := graphics.Color(focus ? graphics.COLOR_TITLE_END : graphics.COLOR_TITLE_QUIET_END)
	first := max(-x, 0)
	last := min(outer_width, canvas.width - x)
	if first < last {
		row := title_row[first:last]
		graphics.gradient(row, start, end, outer_width, first)
		// The line at the top is lighter: the sign of depth of the rules.
		graphics.gradient(title_light[first:last], graphics.shade(start, 125), graphics.shade(end, 125), outer_width, first)
		graphics.copy(canvas, x + first, y, {pixels = raw_data(title_light[first:]), width = last - first, height = 1})
		lines := graphics.Canvas{pixels = raw_data(row), width = last - first, height = TITLE_HEIGHT - 1} // Stride 0: each line is the row.
		graphics.copy(canvas, x + first, y + 1, lines)
		lines.height = BORDER
		graphics.copy(canvas, x + first, y + outer_height - BORDER, lines)
	}
	graphics.fill(canvas, x, y + TITLE_HEIGHT, BORDER, outer_height - TITLE_HEIGHT - BORDER, start)
	graphics.fill(canvas, x + outer_width - BORDER, y + TITLE_HEIGHT, BORDER, outer_height - TITLE_HEIGHT - BORDER, end)
	title_draw(canvas, client, x, y, focus, end)
	graphics.copy(canvas, x + BORDER, y + TITLE_HEIGHT, client.surface)
}

// title_measure measures three forms of the title bar of the widest window
// on the frame, before the first frame: one color, as before the gradient;
// the gradient with a mix for each pixel; the gradient as one row of colors
// that each line copies. The log has the time of each.
title_measure :: proc "contextless" () {
	ROUNDS :: 64
	width := min(screen.width, len(title_row))
	times: [3]u64
	for form in 0 ..< 3 {
		start := system.nanoseconds()
		for _ in 0 ..< ROUNDS {
			switch form {
			case 0:
				graphics.fill(frame, 0, 0, width, TITLE_HEIGHT, graphics.COLOR_TITLE)
			case 1:
				for line in 0 ..< TITLE_HEIGHT {
					for column in 0 ..< width {
						frame.pixels[line * frame.stride + column] = graphics.mix(graphics.COLOR_TITLE, graphics.COLOR_TITLE_END, u32(column * 255 / (width - 1)))
					}
				}
			case 2:
				graphics.gradient(title_row[:width], graphics.COLOR_TITLE, graphics.COLOR_TITLE_END, width, 0)
				graphics.copy(frame, 0, 0, {pixels = raw_data(title_row[:]), width = width, height = TITLE_HEIGHT})
			}
		}
		times[form] = (system.nanoseconds() - start) / ROUNDS
	}
	system.log_in("surfaces", .Info, "compositor: a title bar of ", u64(width), " pixels: one color ", times[0] / 1000, ".", times[0] / 100 % 10, " us, a mix for each pixel ", times[1] / 1000, ".", times[1] / 100 % 10, " us, one row of colors then copies ", times[2] / 1000, ".", times[2] / 100 % 10, " us")
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
// title, the caption and the count of its lines. With a total, the count
// reads "count of total".
card_draw :: proc "contextless" (canvas: graphics.Canvas, x, y, width, height: int, title, caption: string, count: u64, total: u64 = 0) {
	accent :: graphics.COLOR_KERNEL
	graphics.block(canvas, x, y, width, height, graphics.shade(accent, 28), graphics.shade(accent, 14))
	graphics.block(canvas, x + 1, y + 1, width - 2, height - 2, graphics.COLOR_CARD_TOP, graphics.COLOR_CARD_BOTTOM)
	graphics.block(canvas, x + graphics.CARD_MARGIN, y + 12, 4, 16, graphics.shade(accent, 130), accent)
	after := graphics.text(canvas, x + graphics.CARD_MARGIN + 12, y + 12, title, accent)
	graphics.text(canvas, after + 16, y + 12, caption, graphics.COLOR_DIM)
	digits :: proc "contextless" (value: u64) -> int {
		count := 1
		for rest := value / 10; rest != 0; rest /= 10 {
			count += 1
		}
		return count
	}
	right := x + width - graphics.CARD_MARGIN
	if total != 0 {
		right -= graphics.text_width(" of ") + digits(total) * graphics.CELL_WIDTH
		graphics.unsigned(canvas, graphics.text(canvas, right, y + 12, " of ", graphics.COLOR_DIM), y + 12, total, graphics.COLOR_TEXT)
	}
	graphics.unsigned(canvas, right - digits(count) * graphics.CELL_WIDTH, y + 12, count, graphics.COLOR_TEXT)
}

// The panel of the launcher, in the middle of the screen, on the grid.
LAUNCHER_WIDTH :: 384
LAUNCHER_ROWS :: 10 // The lines of the list that the panel shows.
LAUNCHER_INPUT :: graphics.CARD_TITLE // The top of the input line, in the panel.
LAUNCHER_LIST :: LAUNCHER_INPUT + 24 + 8 // The top of the list.
LAUNCHER_HEIGHT :: LAUNCHER_LIST + LAUNCHER_ROWS * bar.LINE_HEIGHT + 8 + graphics.LINE_HEIGHT + graphics.CARD_MARGIN

launcher_place :: proc "contextless" () -> (x, y: int) {
	return (screen.width - LAUNCHER_WIDTH) / 2 / graphics.GRID * graphics.GRID, (screen.height - LAUNCHER_HEIGHT) / 2 / graphics.GRID * graphics.GRID
}

damage_launcher :: proc "contextless" () {
	x, y := launcher_place()
	damage_add(x, y, LAUNCHER_WIDTH, LAUNCHER_HEIGHT)
}

// launcher_key takes a key for the launcher. It gives true if the key is
// for the launcher, and false if it goes to the window that has the focus.
// The key super opens and closes the launcher. While the launcher is open,
// it takes each key: a character adds to the typed part, backspace removes
// the last one, up and down move the choice, enter starts the chosen
// program, escape closes the launcher.
launcher_key :: proc "contextless" (code: u32, character: u8, pressed: bool) -> bool {
	if !pressed {
		if code == kept_key {
			kept_key = 0
			return true
		}
		return launcher_open || code == display.KEY_SUPER
	}
	if code == display.KEY_SUPER {
		if launcher_open {
			launcher_close("the key super")
		} else {
			launcher_open = true
			typed_count = 0
			if menu_open != .None {
				menu_open = .None
				menu_line = -1
				damage_menu()
			}
			launcher_filter()
			system.log_in("surfaces", .Info, "compositor: the launcher is open")
		}
		return true
	}
	if !launcher_open {
		return false
	}
	kept_key = code
	switch {
	case code == display.KEY_ESCAPE:
		launcher_close("the key escape")
	case code == display.KEY_ENTER:
		if match_count == 0 {
			system.log_in("surfaces", .Info, "compositor: the launcher has no program to start")
			return true
		}
		name := bar.names[matches[choice]]
		packed := system.name_pack(name)
		system.send(&control.completions, ring.Record{kind = u32(display.Control.Start), values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}})
		system.log_in("surfaces", .Info, "compositor: the launcher starts ", name)
		launcher_close("")
	case code == display.KEY_UP || code == display.KEY_DOWN:
		if match_count > 0 {
			choice = (choice + (code == display.KEY_UP ? match_count - 1 : 1)) % match_count
			system.log_in("surfaces", .Info, "compositor: the launcher chooses ", bar.names[matches[choice]])
			damage_launcher()
		}
	case code == display.KEY_BACKSPACE:
		if typed_count > 0 {
			typed_count -= 1
			launcher_filter()
		}
	case character > ' ' && character <= '~':
		if typed_count < len(typed) {
			typed[typed_count] = character
			typed_count += 1
			launcher_filter()
		}
	}
	return true
}

// launcher_filter makes the list again from the typed part, and writes it
// on the log: "compositor: the launcher lists 2 of 31 for "lo": log, locks".
launcher_filter :: proc "contextless" () {
	match_count = bar.filter(string(typed[:typed_count]), matches[:])
	choice = 0
	buffer: [len(bar.names) * 16]u8
	count := 0
	for index in matches[:match_count] {
		if count > 0 {
			count += copy(buffer[count:], ", ")
		}
		count += copy(buffer[count:], bar.names[index])
	}
	system.log_in("surfaces", .Info, "compositor: the launcher lists ", u64(match_count), " of ", u64(len(bar.names)), " for \"", string(typed[:typed_count]), "\": ", string(buffer[:count]))
	damage_launcher()
}

launcher_close :: proc "contextless" (cause: string) {
	launcher_open = false
	damage_launcher()
	if cause != "" {
		system.log_in("surfaces", .Info, "compositor: the launcher is closed by ", cause)
	}
}

// launcher_draw draws the panel of the launcher: a card with the count of
// the names that match, the input line with the typed part and a caret, the
// list with the chosen line in blue, and the keys of the launcher.
launcher_draw :: proc "contextless" (canvas: graphics.Canvas, origin_x, origin_y: int) {
	left, top := launcher_place()
	x, y := left + origin_x, top + origin_y
	card_draw(canvas, x, y, LAUNCHER_WIDTH, LAUNCHER_HEIGHT, "LAUNCHER", "bar.names", u64(match_count), len(bar.names))
	inner_x := x + graphics.CARD_MARGIN
	inner_width := LAUNCHER_WIDTH - 2 * graphics.CARD_MARGIN

	// The input line: the typed part, then the caret.
	input_y := y + LAUNCHER_INPUT
	graphics.fill(canvas, inner_x, input_y, inner_width, 24, graphics.COLOR_TRACK)
	graphics.fill(canvas, inner_x, input_y + 22, inner_width, 2, graphics.COLOR_TITLE)
	after := graphics.text(canvas, inner_x + 8, input_y + 4, string(typed[:typed_count]), graphics.COLOR_WHITE)
	graphics.fill(canvas, after + 1, input_y + 4, 2, graphics.CELL_HEIGHT, graphics.COLOR_TITLE)
	if typed_count == 0 {
		graphics.text(canvas, after + 8, input_y + 4, "type a part of a name", graphics.COLOR_DIM)
	}

	// The list. The first line shown keeps the choice on the panel.
	list_y := y + LAUNCHER_LIST
	if match_count == 0 {
		end := graphics.text(canvas, inner_x + 8, list_y + 4, "no program has \"", graphics.COLOR_DIM)
		end = graphics.text(canvas, end, list_y + 4, string(typed[:typed_count]), graphics.COLOR_TEXT)
		graphics.text(canvas, end, list_y + 4, "\" in its name", graphics.COLOR_DIM)
	}
	first := max(choice - LAUNCHER_ROWS + 1, 0)
	for row in 0 ..< min(match_count - first, LAUNCHER_ROWS) {
		index := first + row
		name := bar.names[matches[index]]
		line_y := list_y + row * bar.LINE_HEIGHT
		chosen := index == choice
		if chosen {
			graphics.fill(canvas, inner_x, line_y, inner_width, bar.LINE_HEIGHT, graphics.COLOR_TITLE)
			graphics.text(canvas, inner_x + inner_width - 8 - graphics.text_width("enter: start"), line_y + 4, "enter: start", graphics.COLOR_TEXT)
		}
		graphics.text(canvas, inner_x + 8, line_y + 4, name, chosen ? graphics.COLOR_WHITE : graphics.COLOR_TEXT)
		// The typed part in the name: a line of 2 pixels under it.
		if at := bar.find(name, string(typed[:typed_count])); typed_count > 0 && at >= 0 {
			graphics.fill(canvas, inner_x + 8 + at * graphics.CELL_WIDTH, line_y + 20, typed_count * graphics.CELL_WIDTH, 2, chosen ? graphics.COLOR_WHITE : graphics.COLOR_KERNEL)
		}
	}
	if match_count > LAUNCHER_ROWS {
		// More names than lines: a bar at the right says which part the list shows.
		track_height := LAUNCHER_ROWS * bar.LINE_HEIGHT
		graphics.fill(canvas, inner_x + inner_width + 6, list_y, 2, track_height, graphics.COLOR_TRACK)
		graphics.fill(canvas, inner_x + inner_width + 6, list_y + first * track_height / match_count, 2, LAUNCHER_ROWS * track_height / match_count, graphics.COLOR_DIM)
	}
	graphics.text(canvas, inner_x, list_y + LAUNCHER_ROWS * bar.LINE_HEIGHT + 8, "up down: choose   enter: start   esc: close", graphics.COLOR_DIM)
}

// memory_measure measures copy_bytes_without_overlap and fill_bytes_with_value
// (runtime/memory.asm; the compiler calls them as memcpy and memset) on the two
// canvases of the screen, before the first frame, for the sizes where the
// forms change, aligned and 3 bytes after an alignment of 64; and a loop of
// 16 bytes written in Odin, the form that graphics.copy had before. The log
// has the time of one call in nanoseconds, and what the processor says of
// its string instructions (CPUID leaf 7: ERMS, FSRM).
memory_measure :: proc "contextless" () {
	SIZES :: [?]int{8, 64, 512, 4096, 65536, 3 << 20 - 128} // The last one: a frame, less the offsets of the measure.
	to := ([^]u8)(frame.pixels)
	from := ([^]u8)(background.pixels)
	limit := min(frame.width * frame.height, background.width * background.height) * size_of(graphics.Color)
	intrinsics.mem_zero(to, limit) // The first use of each page, before the measure.
	Form :: enum {
		Copy,
		Copy_Unaligned,
		Loop,
		Loop_Unaligned,
		Fill,
		Fill_Unaligned,
	}
	tenths: [Form][len(SIZES)]u64 // Tenths of a nanosecond for one call.
	for form in Form {
		for size, index in SIZES {
			offset := form == .Copy_Unaligned || form == .Loop_Unaligned || form == .Fill_Unaligned ? 3 : 0
			count := min(size, limit - 128)
			rounds := clamp(64 << 20 / max(count, 64), 8, 100_000)
			start := system.nanoseconds()
			for _ in 0 ..< rounds {
				switch form {
				case .Copy, .Copy_Unaligned:
					intrinsics.mem_copy_non_overlapping(&to[offset], &from[64 + offset], count)
				case .Loop, .Loop_Unaligned:
					loop_copy(&to[offset], &from[64 + offset], count)
				case .Fill, .Fill_Unaligned:
					intrinsics.mem_zero(&to[offset], count) // A call of memset with 0.
				}
			}
			tenths[form][index] = (system.nanoseconds() - start) * 10 / u64(rounds)
		}
	}
	names := [Form]string {
		.Copy           = "compositor: copy_bytes_without_overlap, ns for 8 64 512 4096 65536 3145600 bytes, aligned:",
		.Copy_Unaligned = "compositor: copy_bytes_without_overlap, not aligned:",
		.Loop           = "compositor: a loop of 16 bytes, aligned:",
		.Loop_Unaligned = "compositor: a loop of 16 bytes, not aligned:",
		.Fill           = "compositor: fill_bytes_with_value, aligned:",
		.Fill_Unaligned = "compositor: fill_bytes_with_value, not aligned:",
	}
	for form in Form {
		line: [256]u8
		count := copy(line[:], names[form])
		for value in tenths[form] {
			count += len(system.format(line[count:], " ", value / 10, ".", value % 10))
		}
		system.log_in("surfaces", .Info, string(line[:count]))
	}
	_, ebx, _, edx := intrinsics.x86_cpuid(7, 0)
	system.log_in("surfaces", .Info, "compositor: the processor: ERMS ", ebx >> 9 & 1 != 0 ? "yes" : "no", ", FSRM ", edx >> 4 & 1 != 0 ? "yes" : "no")
}

// loop_copy copies count bytes 16 at a time, with no call of memcpy: the
// form of graphics.copy before runtime/memory.asm, kept for the measure.
// The store is volatile, so that the compiler does not make the loop a
// call of memcpy.
loop_copy :: proc "contextless" (to, from: [^]u8, count: int) {
	Block :: #simd[16]u8
	index := 0
	for ; index + 16 <= count; index += 16 {
		intrinsics.volatile_store((^[16]u8)(&to[index]), transmute([16]u8)intrinsics.unaligned_load((^Block)(&from[index])))
	}
	for ; index < count; index += 1 {
		to[index] = from[index]
	}
}
