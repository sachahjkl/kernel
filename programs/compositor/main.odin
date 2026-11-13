// The compositor (docs/ARCHITECTURE.md, "U8. Graphics: WebGPU library and compositor"): the service that owns the
// display. It combines the surfaces of programs into the framebuffer, and it
// sends input to the program that has focus. It is also the desktop shell of
// this first version: a bar with the menu of the programs and the menu of
// the windows, and windows that the input moves. It follows the design
// rules (docs/DESIGN.md): rectangles only, the grid of 8 pixels, the colors
// of support/graphics.
//
// **What it is for.** No program writes to the screen. A program asks the
// compositor for a [surface](term:surface): memory that the program and the
// compositor share. The program draws into it and sends `Present`; the
// compositor copies the changed rectangle into its frame, then the frame to
// the framebuffer. The compositor is the only holder of the framebuffer and
// of the ring of the [input service](term:input-service), so no program
// reads the keys of another window or draws over it.
//
// **What a reader sees.** The whole screen: the background with its grid
// of points, the [bar](term:bar) at the top (the
// [menu of the programs](term:menu-of-the-programs), the
// [menu of the windows](term:menu-of-the-windows), the hint of the
// [palette](term:palette), the date and the time), the windows with their
// [title bar](term:title-bar) and their close button, and the
// [pointer](term:pointer). The input can:
//
// - press a line of the menu of the programs: the compositor asks the root
//   service to start that program;
// - press the key super: the palette opens; typed letters narrow one list
//   of the programs and of the windows, and Enter starts the chosen
//   program or brings the chosen window to the front (palette.odin);
// - drag a title bar: the window moves; a press on a window brings it to the
//   front and gives it the [focus](term:focus);
// - press the close button: the root service stops the program.
//
// The keys go to the window in front, unless the palette is open.
//
// **Its lines in the log**: `compositor: ok <width>x<height>` at the start,
// `compositor: first frame`, then, on the channel `surfaces`, one line for
// each new surface, each move and each window brought to the front, the
// time of a full frame, and the events of the palette.
//
// **How it starts.** The root service starts it at each boot, after the
// input service and before the console. Its context is not the context of
// the other programs: the handles 0 to 2 are the framebuffer, the ring of
// the input service, and a control ring to the root service; the values 0
// to 3 are the width, the height, the pixels of a line and the pixel format
// of the screen. The root service also maps its own file (for its exports),
// two [pointer themes](term:pointer-theme), the
// [settings page](term:settings-page), the glyph caches and the
// [date page](term:date-page). It has no grant of `grants_of`: the root
// service gives these handles by name.
//
// **Its exports**: `pointer` and `windows`, to a caller that
// [acts for the principal](term:acts-for-the-principal) (`exports.odin`).
// The machine test reads them through the remote service before each press,
// so that a press lands where the scenario wants it.
//
// **What it does not prove.** The compositor draws with the processor,
// into memory: it is not the graphics interface of the system, which is
// WebGPU with WGSL and is not built. A full frame of the screen takes a few
// milliseconds of one processor; the log gives the measure.
//
// The design of the desktop is in docs/DESIGN.md, "9. The desktop"; the
// pointer is in docs/POINTERS.md.
package compositor

import "support:display"
import "contract:settings"
import "contract:date"
import "support:calendar"
import "support:graphics"
import "support:interface"
import "support:bar"
import "support:mark"
import "contract:ring"
import "support:system"
import "contract:pointer_pictures"
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
// The places of new windows. Each corner of a window is on the grid of 8
// pixels (docs/DESIGN.md, section 6).
PLACE_X :: 64
PLACE_Y :: 56
PLACE_STEP_X :: 40
PLACE_STEP_Y :: 32
CLIENT_CAPACITY :: 32 // The root service starts 32 programs at most.
DAMAGE_CAPACITY :: 8
CLOCK_WIDTH :: 19 * 8 // "2026-11-11 16:30:05", or the time since boot "00:00:00" when the system has no date.
// The hint of the palette in the bar, at the left of the time: "palette: super".
PALETTE_HINT_NAME :: "palette: "
PALETTE_HINT_KEY :: "super"

Client :: struct {
	ring_memory: system.Handle, // 0: the slot is free.
	ring:        ring.Ring,
	surface:     graphics.Canvas, // pixels is nil until the program creates its surface.
	pictures:    [^]graphics.Color, // The memory of the surface: one picture or two. surface is one of them.
	picture_count: u64,
	x, y:        int,
	title:       system.Name,
	pointer_shape: pointer_pictures.Pointer_Shape, // The shape that the program asked for over its surface (pointer_picture.odin).
	presents:    u64, // The Present records that the program sent since it created its surface.
	present_waits: bool, // A Present changed a part of the screen, and no frame drew it yet.
}

// A rectangle of the screen. right and bottom are not in the rectangle.
Rectangle :: struct {
	left, top, right, bottom: int,
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
presents: u64 // The Present records of all the programs since the start.
// A change of the desktop itself (the pointer, the bar, a menu, the
// palette, a window that appeared, moved or closed) is damage that no
// frame drew yet. The damage of a Present is counted for its window, not
// here: a caller tells a window that draws with no end from the rest.
desktop_change_waits: bool
// The measures of the time of a frame (docs/DESIGN.md, section 7). A full
// frame draws the whole screen: the first frame, and the frame after the
// input puts a window down. The frames of a move are the frames while the
// input drags a window.
full_measure: bool // The next frame draws the whole screen, and the log has its time.
move_frames, move_time, move_longest: u64 // Nanoseconds.
// The colors of one line of a title bar, and of its lighter top line.
title_row, title_light: [display.SURFACE_LIMIT + 2 * BORDER]graphics.Color

// damage_add records that the desktop itself changed a rectangle of the
// screen: each change but the Present of a program.
damage_add :: proc "contextless" (x, y, width, height: int) {
	if damage_rectangle_add(x, y, width, height) {
		desktop_change_waits = true
	}
}

// damage_rectangle_add records that a rectangle of the screen changed.
// Rectangles that touch become one rectangle. If there is no room, the new
// rectangle joins the first one. false: the rectangle is not on the screen,
// and nothing waits for a frame.
damage_rectangle_add :: proc "contextless" (x, y, width, height: int) -> bool {
	area := Rectangle{max(x, 0), max(y, 0), min(x + width, screen.width), min(y + height, screen.height)}
	if area.left >= area.right || area.top >= area.bottom {
		return false
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
	return true
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
	damage_menu_of(bar_layout)
}

// damage_menu_of records the buttons and the menus of one layout of the
// bar: a change of the font damages the places of the old layout and of
// the new one.
damage_menu_of :: proc "contextless" (layout: bar.Layout) {
	x, y, width, height := bar.button(layout)
	damage_add(x, y, width, height)
	x, y, width, height = bar.menu(layout)
	damage_add(x, y, width, height)
	x, y, width, height = bar.windows_button(layout)
	damage_add(x, y, width, height)
	x, y, width, height = bar.windows_menu(layout, CLIENT_CAPACITY) // A window can leave while the menu is open.
	damage_add(x, y, width, height)
}

// The texts that the compositor draws itself follow the rule of the two
// fonts (docs/DESIGN.md, section 5): the names (the buttons of the bar, the
// lines of the menus, the titles of the windows, the names of the
// palette, a hint) in the interface font; the values (the clock, the date,
// the text that the input types, a count) in the font of the cells. The
// interface font is the one of support/display (interface_font_load); with
// none, or with the setting Spleen 8x16, each text is in the font of the
// cells with the same layout rules.
bar_layout: bar.Layout
bar_layout_known: bool
bar_in_interface_font: bool

// bar_measure writes once in the log the time of one whole frame of the
// bar with the menu of the programs open, built and drawn, in the font of
// the cells and in the interface font: the least of 20 rounds, so that a
// round that the host stops in its middle does not count. It runs before
// the first frame, which draws the whole screen after it.
bar_measure :: proc "contextless" () {
	ROUNDS :: 20
	font := display.interface_font_of()
	saved_layout, saved_menu := bar_layout, menu_open
	menu_open = .Programs
	fonts := [2]^display.Interface_Font{nil, font}
	least := [2]u64{max(u64), max(u64)}
	measured := 0
	for measured_font in fonts {
		if measured == 1 && (font == nil || graphics.text_state.font != .Vector) {
			break
		}
		bar_layout = bar.layout_of(measured_font != nil ? &measured_font.regular : nil)
		_, menu_top, _, menu_height := bar.menu(bar_layout)
		area := interface.Rectangle{0, 0, frame.width, max(BAR_HEIGHT, menu_top + menu_height)}
		for _ in 0 ..< ROUNDS {
			start := system.nanoseconds()
			screen_build(0, measured_font)
			interface.execute_in_rectangle(&screen_table, frame, area)
			least[measured] = min(least[measured], system.nanoseconds() - start)
		}
		measured += 1
	}
	bar_layout, menu_open = saved_layout, saved_menu
	if measured < 2 {
		system.log("compositor: the bar and the menu of the programs, built and drawn (the least of 20): the font of the cells ", least[0] / 1000, ".", least[0] / 100 % 10, " us; no interface font")
		return
	}
	system.log("compositor: the bar and the menu of the programs, built and drawn (the least of 20): the font of the cells ", least[0] / 1000, ".", least[0] / 100 % 10, " us, the interface font ", least[1] / 1000, ".", least[1] / 100 % 10, " us")
}

// bar_layout_update measures the bar in the font that draws it now, and
// writes in the log which font it is when it changes: the kernel tool reads
// that line to find the places of the bar. The places of the old and of
// the new layout are damaged.
bar_layout_update :: proc "contextless" () {
	font := display.interface_font_of()
	in_interface_font := font != nil && graphics.text_state.font == .Vector
	layout := bar.layout_of(in_interface_font ? &font.regular : nil)
	if bar_layout_known && layout == bar_layout && in_interface_font == bar_in_interface_font {
		return
	}
	if bar_layout_known {
		damage_menu_of(bar_layout)
	}
	bar_layout, bar_layout_known, bar_in_interface_font = layout, true, in_interface_font
	damage_add(0, 0, screen.width, BAR_HEIGHT)
	damage_menu_of(bar_layout)
	if in_interface_font {
		system.log("compositor: the bar is in the interface font: programs ", u64(layout.label_width), " pixels, windows ", u64(layout.windows_label_width), ", the widest name ", u64(layout.longest_name_width))
	} else {
		system.log("compositor: the bar is in the font of the cells")
	}
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

// The bar shows the date and the time of day in UTC (contract/date), or
// the time since boot when the system has no date. second_of_bar gives the
// second that it shows at the time `now` of the system, and
// next_second_of_bar the time of the system when it changes after `now`:
// always later than `now`, and at most one second later, also when the date
// first appears between two frames (the second shown then jumps from the
// time since boot to the date, and the next frame shows it).
date_page: ^date.Page

second_of_bar :: proc "contextless" (now: u64) -> u64 {
	if milliseconds, known := date.milliseconds_now(date_page, now); known {
		return u64(milliseconds / 1000)
	}
	return now / 1000
}

next_second_of_bar :: proc "contextless" (now: u64) -> u64 {
	if milliseconds, known := date.milliseconds_now(date_page, now); known {
		return now + u64(1000 - milliseconds % 1000) // milliseconds_now gives a date after 1970 only: positive.
	}
	return (now / 1000 + 1) * 1000
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

// entry starts the compositor and runs its one loop: it draws the screen
// until the machine stops.
//
// **What it sets up**: the framebuffer, the ring of the input service and
// the control ring of the root service; the frame and the background,
// each the size of the screen; the mark of the bar; the pointer theme; the
// service ring of its exports; the text settings and the interface font.
// It writes `compositor: ok <width>x<height>` and the measures of the bar
// and of a title bar.
//
// **The loop.** One wait covers the control ring, the input ring, the
// service ring, the ring of each window and the change count of the
// settings page. The deadline is the next frame when the screen has
// damage, else the next second of the clock in the bar, or the next frame
// of an animated pointer. After the wait, in this order:
//
// 1. A change of the settings: the new font, the new pointer theme, and an
//    event to each window, which draws again.
// 2. The control ring: a window to add or to remove.
// 3. The input ring: a key goes to the palette, or to the window in
//    front; a move or a button of the pointer moves the pointer, drags a
//    window, opens a menu or starts a program.
// 4. The ring of each window: `Surface_Create`, `Present` (the changed
//    rectangle becomes damage), and `Pointer_Shape`.
// 5. The calls of `pointer`, `windows` and `screen`, after the input and
//    after the rings of the windows, so that they give the place of now
//    and count each `Present` that a program sent before the call.
// 6. A frame, at most one each 16 ms, when the screen has damage.
//
// **The stop.** With no framebuffer or no ring, the compositor writes
// `compositor: no framebuffer` and stops with the code 1. Without the
// memory of its frame, it writes `compositor: no memory` and stops. Else it
// never returns.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	width := int(ctx.values[VALUE_WIDTH])
	height := int(ctx.values[VALUE_HEIGHT])
	date_page = date.page_of(ctx)
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
	bar_mark_build()
	memory_measure()
	title_measure()
	pointer_theme_open(ctx) // pointer_picture.odin
	damage_add(0, 0, width, height)
	full_measure = true
	system.log("compositor: ok ", u64(width), "x", u64(height))
	service_start(ctx) // exports.odin
	// The text of the desktop: the settings of the principal and the glyph cache
	// (contract:settings); a change of the settings wakes this loop.
	display.text_settings_open(ctx)
	display.interface_font_load(ctx)
	palette_start() // palette.odin
	bar_layout_update()
	bar_measure()
	settings_seen: u32
	// settings_seen starts at 0: when the boot pass of settings wrote the page
	// before this read, the first turn of the loop sees a change and tells
	// each window, also the ones that read the page before the boot pass.
	// After that first time, a new count tells the windows only when the
	// values differ from the values that they were told last: `settings`
	// can change the count with no end and the same values, and each told
	// window gets one record in the ring that also carries its keys.
	settings_told: settings.Choice
	settings_told_once: bool
	if display.settings_page != nil {
		pointer_theme_choose(settings.pointer_theme_of(settings.read(display.settings_page)))
	}

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
		deadline := damage_count > 0 ? max(next_frame, 1) : next_second_of_bar(system.time())
		if wake := pointer_wake(); wake != 0 {
			deadline = min(deadline, wake) // An animated pointer shape shows.
		}
		if display.settings_page != nil {
			system.wait_word(&wait, &display.settings_page.change_count, settings_seen)
		}
		now := system.wait_end(&wait, deadline)
		if display.settings_page != nil {
			if choice := settings.read(display.settings_page); choice.change_count != settings_seen {
				settings_seen = choice.change_count
				if !settings_told_once || settings.values_differ(choice, settings_told) {
					settings_told = choice
					settings_told_once = true
					settings_changed(choice)
				}
			}
		}
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
				key_records += 1
				if !palette_key(u32(record.values[0]), u8(record.values[1]), record.values[2] != 0) && order_count > 0 {
					send(&clients[order[order_count - 1]], ring.Record{kind = u32(display.Event_Kind.Key), values = record.values})
				}
			case .Pointer:
				pointer_moved(int(i64(record.values[0])), int(i64(record.values[1])), u32(record.values[2]))
				pointer_moves += 1
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
						// The program can name the rectangle that changed; the
						// numbers are its own: they are cut to the surface.
						left, top := int(min(record.values[1], u64(client.surface.width))), int(min(record.values[2], u64(client.surface.height)))
						// Width 0: from (left, top) to the end of the surface.
						changed_width, changed_height := client.surface.width - left, client.surface.height - top
						if record.values[3] != 0 {
							changed_width = int(min(record.values[3], u64(client.surface.width - left)))
							changed_height = int(min(record.values[4], u64(client.surface.height - top)))
						}
						client.presents += 1
						presents += 1
						if damage_rectangle_add(client.x + BORDER + left, client.y + TITLE_HEIGHT + top, changed_width, changed_height) {
							client.present_waits = true
						}
					}
				case .Pointer_Shape:
					pointer_shape_request(&client, record) // pointer_picture.odin
				}
			}
		}
		// The calls read the place of the pointer after the input records,
		// and the state of the screen after each Present that a program
		// sent before the call: a caller that reads "nothing waits" then
		// knows that the screen shows what the programs sent.
		system.service_run(&service)
		pointer_update(now) // After each change of what is under the pointer.
		if second_of_bar(now) != shown_second {
			shown_second = second_of_bar(now)
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

// settings_changed gives the new font to the text of the desktop, draws the
// whole screen again, and tells each window: its program draws again
// (support/display gives it the new font before the event).
settings_changed :: proc "contextless" (choice: settings.Choice) {
	display.text_settings_apply()
	bar_layout_update()
	pointer_theme_choose(settings.pointer_theme_of(choice)) // pointer_picture.odin
	told := 0
	for &client in clients {
		if client.ring.head != nil {
			send(&client, ring.Record{kind = u32(display.Event_Kind.Settings_Changed), values = {0 = u64(choice.change_count)}})
			told += 1
		}
	}
	damage_add(0, 0, screen.width, screen.height)
	palette_refresh() // An open panel is measured again in the new font.
	buffer: [256]u8
	writer := system.Writer{buffer = buffer[:]}
	for setting in settings.Setting {
		description := settings.descriptions[setting]
		system.write_part(&writer, setting == .Font ? "" : ", ")
		system.write_part(&writer, description.title)
		system.write_part(&writer, " ")
		system.write_part(&writer, description.value_names[choice.values[setting]])
	}
	system.log("compositor: the settings changed: ", system.written(&writer), "; ", u64(told), " windows draw again")
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
		palette_entries_refresh() // A window left.
		return
	}
}

surface_create :: proc "contextless" (index: int, record: ring.Record) {
	client := &clients[index]
	// The program wrote the number of the handle: it can name any handle of
	// the compositor, among them the surface or the ring of another client.
	// The kernel proves that this program gave the handle through its own
	// ring (support/system, handle_state). A number with no proof is not a
	// gift of this program: the compositor neither uses it nor closes it.
	memory := system.Handle(record.values[0])
	kind, rights, through := system.handle_state(memory, client.ring_memory)
	// No log line: a program could send this command without end.
	if !through {
		return
	}
	// The handle is a gift of this program: each return below closes it.
	defer system.close(memory)
	width, height := record.values[1], record.values[2]
	// The program chose these numbers: check them against the memory itself.
	if kind != .Memory || .Read not_in rights || client.surface.pixels != nil || width == 0 || height == 0 || width > display.SURFACE_LIMIT || height > display.SURFACE_LIMIT {
		return
	}
	size := system.memory_size(memory) * system.PAGE_SIZE
	if size < width * height * size_of(graphics.Color) {
		return
	}
	address, status := system.memory_map(memory, {}) // Read only.
	if status != .Ok {
		return
	}
	client.pictures = ([^]graphics.Color)(address)
	client.picture_count = size >= 2 * width * height * size_of(graphics.Color) ? 2 : 1
	client.surface = {pixels = client.pictures, width = int(width), height = int(height), stride = int(width)}
	client.title = system.name_unpack({record.values[3], record.values[4], record.values[5], record.values[6]})
	client.x = PLACE_X + placed % 8 * PLACE_STEP_X
	client.y = PLACE_Y + placed % 8 * PLACE_STEP_Y
	// A large window moves up and left until the screen shows all of it; a
	// window wider than the screen keeps its close button on the screen.
	client.x, client.y = bar.new_window_place(client.x, client.y, window_frame_of(client), int(height), screen.width, screen.height)
	placed += 1
	damage_focus()
	order[order_count] = index
	order_count += 1
	damage_window(client)
	system.log_in("surfaces", .Info, "compositor: surface ", system.name_of(client.title[:]), " ", width, "x", height, " at ", u64(client.x), ",", u64(client.y))
	palette_entries_refresh() // A window appeared.
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
	palette_entries_refresh() // Another window is in front.
}

inside :: proc "contextless" (x, y, left, top, width, height: int) -> bool {
	return x >= left && y >= top && x < left + width && y < top + height
}

pointer_moved :: proc "contextless" (motion_x, motion_y: int, new_buttons: u32) {
	close_before := close_button_under_pointer()
	pointer_x = clamp(pointer_x + motion_x, 0, screen.width - 1)
	pointer_y = clamp(pointer_y + motion_y, 0, screen.height - 1)
	// The close button under the pointer is brighter: draw again the
	// button that the pointer leaves and the one that it reaches.
	if close_after := close_button_under_pointer(); close_after != close_before {
		for client in ([2]^Client{close_before, close_after}) {
			if client != nil {
				damage_add(client.x + client.surface.width + BORDER - CLOSE_SIZE, client.y, CLOSE_SIZE, TITLE_HEIGHT)
			}
		}
	}
	pressed := new_buttons & display.BUTTON_LEFT != 0 && buttons & display.BUTTON_LEFT == 0
	released := new_buttons & display.BUTTON_LEFT == 0 && buttons & display.BUTTON_LEFT != 0
	held := buttons != 0 || new_buttons != 0
	buttons = new_buttons

	if palette_is_open() {
		// The panel takes the pointer: no menu and no window receives it.
		palette_pointer(motion_x != 0 || motion_y != 0, pressed, released)
		return
	}
	if dragging >= 0 {
		if buttons & display.BUTTON_LEFT != 0 {
			damage_window(&clients[dragging])
			// The window follows the pointer on the grid of 8, and a part
			// of its title stays on the screen at each edge.
			clients[dragging].x, clients[dragging].y = bar.dragged_window_place(pointer_x, pointer_y, drag_x, drag_y, window_frame_of(&clients[dragging]), screen.width, screen.height)
			damage_window(&clients[dragging])
		} else {
			// The input put the window down: the log has its new place.
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
		over := menu_open == .Programs ? bar.line_at(bar_layout, pointer_x, pointer_y) : bar.windows_line_at(bar_layout, order_count, pointer_x, pointer_y)
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
		under := bar.button_at(bar_layout, pointer_x, pointer_y)
		if under == .Programs && was_open != .Programs {
			menu_open = .Programs
			system.log_in("surfaces", .Info, "compositor: the menu of the programs is open")
			damage_menu()
		}
		if under == .Windows && was_open != .Windows {
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
	screen_build(now, display.interface_font_of())
	for area in damage[:damage_count] {
		draw_area(area, now)
	}
	damage_count = 0
	// The screen shows each change that the compositor received.
	desktop_change_waits = false
	for &client in clients {
		client.present_waits = false
	}
	spent := system.nanoseconds() - start
	if palette_is_open() {
		palette_frames += 1
		palette_time += spent
	}
	if dragging >= 0 {
		move_frames += 1
		move_time += spent
		move_longest = max(move_longest, spent)
	}
	pointer_frame_end()
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

	// The windows, the bar and the menus: one draw table for the frame
	// (screen_build), each record cut to this area.
	interface.execute_in_rectangle(&screen_table, canvas, {area.left, area.top, area.right, area.bottom}, origin_x, origin_y)

	if palette_is_open() {
		interface.execute_in_rectangle(&palette_now, canvas, {area.left, area.top, area.right, area.bottom}, origin_x, origin_y)
	}

	pointer_draw(canvas, origin_x, origin_y) // pointer_picture.odin

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

// frame_records appends the frame of a window as draw records of the
// interface package: the title bar with its gradient and its lighter top
// line, the borders, the title, the close button (docs/DESIGN.md, section
// 9). By hand the same frame of 800 x 600 took 8.5 us, as 9 records 8.9 us
// (one measure run, docs/INTERFACE.md, section 12).
frame_records :: proc "contextless" (table: ^interface.Draw_Table, client: ^Client, x, y: int, focus, pointer_over: bool) {
	outer_width := client.surface.width + 2 * BORDER
	outer_height := client.surface.height + TITLE_HEIGHT + BORDER
	start := graphics.Color(focus ? graphics.COLOR_TITLE : graphics.COLOR_TITLE_QUIET)
	end := graphics.Color(focus ? graphics.COLOR_TITLE_END : graphics.COLOR_TITLE_QUIET_END)
	interface.draw_horizontal_gradient(table, x, y, outer_width, 1, graphics.shade(start, 125), graphics.shade(end, 125))
	interface.draw_horizontal_gradient(table, x, y + 1, outer_width, TITLE_HEIGHT - 1, start, end)
	interface.draw_horizontal_gradient(table, x, y + outer_height - BORDER, outer_width, BORDER, start, end)
	interface.draw_rectangle(table, x, y + TITLE_HEIGHT, BORDER, outer_height - TITLE_HEIGHT - BORDER, start)
	interface.draw_rectangle(table, x + outer_width - BORDER, y + TITLE_HEIGHT, BORDER, outer_height - TITLE_HEIGHT - BORDER, end)
	// The title: a name, cut in its font to the room before the close button.
	title := interface.text_fit(table, interface.FONT_INTERFACE, system.name_of(client.title[:]), outer_width - CLOSE_SIZE - 16)
	interface.draw_text(table, x + 8, y + 4, title, focus ? graphics.COLOR_WHITE : graphics.COLOR_DIM, interface.FONT_INTERFACE)
	base := graphics.Color(graphics.COLOR_STOP_PROGRAM_QUIET)
	cross_color := graphics.Color(graphics.COLOR_STOP_PROGRAM_QUIET_MARK)
	if focus || pointer_over {
		base = pointer_over ? graphics.COLOR_STOP_PROGRAM_POINTER_OVER : graphics.COLOR_STOP_PROGRAM
		cross_color = graphics.COLOR_WHITE
	}
	close_x := x + outer_width - BORDER - CLOSE_SIZE
	interface.draw_vertical_gradient(table, close_x, y, CLOSE_SIZE, TITLE_HEIGHT, graphics.shade(base, 118), graphics.shade(base, 82))
	interface.draw_rectangle(table, close_x, y, CLOSE_SIZE, 1, graphics.shade(base, 150))
	interface.draw_character(table, close_x + (CLOSE_SIZE - graphics.CELL_WIDTH) / 2, y + (TITLE_HEIGHT - graphics.CELL_HEIGHT) / 2, 'x', cross_color)
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

// close_button_under_pointer gives the client whose close button is under
// the pointer, or nil: the button of the window in front at that place.
close_button_under_pointer :: proc "contextless" () -> ^Client {
	for position := order_count - 1; position >= 0; position -= 1 {
		client := &clients[order[position]]
		outer_width := client.surface.width + 2 * BORDER
		if !inside(pointer_x, pointer_y, client.x, client.y, outer_width, client.surface.height + TITLE_HEIGHT + BORDER) {
			continue
		}
		if inside(pointer_x, pointer_y, client.x + outer_width - BORDER - CLOSE_SIZE, client.y, CLOSE_SIZE, TITLE_HEIGHT) {
			return client
		}
		return nil
	}
	return nil
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

// The draw table of the screen: for each window, from the back to the front,
// its frame and its surface (a Picture record), then the bar and the menus.
// The compositor builds it once for each frame and draws it in each damage
// area. The palette has its own table; the pointer is drawn after both.
screen_records: [512]interface.Draw_Record
screen_text: [8192]u8
screen_pictures: [CLIENT_CAPACITY + 1]graphics.Canvas // The surfaces, then the heron of the bar.
screen_table := interface.Draw_Table{}

// The heron of the bar (docs/DESIGN.md, "The mark"). Its gradients are
// computed once, at the start, into this picture; each frame shows it with
// a Picture record, a copy of 24 rows. Its generation never changes, so the
// difference of two frames never finds it changed.
BAR_MARK_PICTURE :: CLIENT_CAPACITY // Its index in screen_pictures.
BAR_MARK_GENERATION :: 1
bar_mark_pixels: [bar.MARK_SIZE * bar.MARK_SIZE]graphics.Color
bar_mark_picture: graphics.Canvas

// bar_background_records appends the surface of the bar: its gradient and
// the line under it.
bar_background_records :: proc "contextless" (table: ^interface.Draw_Table, width: int) {
	interface.draw_vertical_gradient(table, 0, 0, width, BAR_HEIGHT - 1, graphics.COLOR_CARD_TOP, graphics.COLOR_CARD_BOTTOM)
	interface.draw_rectangle(table, 0, BAR_HEIGHT - 1, width, 1, graphics.COLOR_TRACK)
}

// bar_mark_build draws the heron of the bar into its picture. A picture has
// no transparency, so the picture first gets the pixels of the bar under the
// heron, from the same records and the same code that draw the bar: an empty
// cell of the heron then shows exactly the bar around it.
bar_mark_build :: proc "contextless" () {
	bar_mark_picture = {pixels = raw_data(bar_mark_pixels[:]), width = bar.MARK_SIZE, height = bar.MARK_SIZE, stride = bar.MARK_SIZE}
	records: [4]interface.Draw_Record
	table := interface.Draw_Table{records = records[:]}
	bar_background_records(&table, bar.MARK_X + bar.MARK_SIZE)
	interface.execute(&table, bar_mark_picture, -bar.MARK_X, -bar.MARK_Y)
	mark.mark_draw(bar_mark_picture, 0, 0, bar.MARK_CELL_SIZE, false)
}

// screen_build builds the draw table of the screen. interface_font: the
// interface font of the names, or nil for the font of the cells (the
// measure of bar_measure compares the two).
screen_build :: proc "contextless" (now: u64, interface_font: ^display.Interface_Font) {
	screen_table = {records = screen_records[:], text = screen_text[:], pictures = screen_pictures[:], interface_font = interface_font}
	table := &screen_table
	pointer_close := close_button_under_pointer()
	for position in 0 ..< order_count {
		client := &clients[order[position]]
		focus := position == order_count - 1
		frame_records(table, client, client.x, client.y, focus, client == pointer_close)
		screen_pictures[position] = client.surface
		interface.draw_picture(table, client.x + BORDER, client.y + TITLE_HEIGHT, position, 0)
	}

	// The bar: the mark of the system, the two buttons, the date and the time
	// of day (the time since boot when the system has no date).
	width := frame.width
	bar_background_records(table, width)
	screen_pictures[BAR_MARK_PICTURE] = bar_mark_picture
	interface.draw_picture(table, bar.MARK_X, bar.MARK_Y, BAR_MARK_PICTURE, BAR_MARK_GENERATION)
	bar_button_records :: proc "contextless" (table: ^interface.Draw_Table, x, y, width, height: int, label: string, open: bool) {
		interface.draw_rectangle(table, x, y, width, height, open ? graphics.COLOR_CHOSEN : graphics.COLOR_TRACK)
		interface.draw_text(table, x + bar.PADDING, y + (height - graphics.CELL_HEIGHT) / 2, label, open ? graphics.COLOR_WHITE : graphics.COLOR_TEXT, interface.FONT_INTERFACE)
	}
	left, top, button_width, button_height := bar.button(bar_layout)
	bar_button_records(table, left, top, button_width, button_height, bar.LABEL, menu_open == .Programs)
	left, top, button_width, button_height = bar.windows_button(bar_layout)
	bar_button_records(table, left, top, button_width, button_height, bar.WINDOWS_LABEL, menu_open == .Windows)
	// The hint of the palette: a name, in the interface font, measured in
	// its two parts as they are drawn.
	hint_width := interface.text_measured_width(table, interface.FONT_INTERFACE, PALETTE_HINT_NAME) + interface.text_measured_width(table, interface.FONT_INTERFACE, PALETTE_HINT_KEY)
	hint_x := width - CLOCK_WIDTH - 32 - hint_width
	interface.draw_text(table, interface.draw_text(table, hint_x, 8, PALETTE_HINT_NAME, graphics.COLOR_DIM, interface.FONT_INTERFACE), 8, PALETTE_HINT_KEY, graphics.COLOR_TEXT, interface.FONT_INTERFACE)
	seconds := now / 1000
	x := width - CLOCK_WIDTH - 16
	if milliseconds, known := date.milliseconds_now(date_page, now); known {
		date_text: [24]u8
		interface.draw_text(table, x, 8, calendar.iso_text(date_text[:], milliseconds / 1000), graphics.COLOR_TEXT)
	} else {
		x += CLOCK_WIDTH - 8 * 8
		x = interface.draw_unsigned(table, x, 8, seconds / 3600, graphics.COLOR_TEXT, 2)
		x = interface.draw_text(table, x, 8, ":", graphics.COLOR_DIM)
		x = interface.draw_unsigned(table, x, 8, seconds / 60 % 60, graphics.COLOR_TEXT, 2)
		x = interface.draw_text(table, x, 8, ":", graphics.COLOR_DIM)
		interface.draw_unsigned(table, x, 8, seconds % 60, graphics.COLOR_TEXT, 2)
	}

	// The menus of the bar, as cards of the package.
	card_frame := interface.Frame{table = table}
	count: interface.Text_Builder
	if menu_open == .Windows && order_count > 0 {
		menu_left, menu_top, menu_width, menu_height := bar.windows_menu(bar_layout, order_count)
		interface.card(&card_frame, {menu_left, menu_top, menu_width, menu_height}, "WINDOWS", "the client table", graphics.COLOR_KERNEL, interface.number_text(&count, u64(order_count)))
		for line in 0 ..< order_count {
			index := window_of_line(line)
			if index < 0 {
				break
			}
			line_x, line_y, line_width, line_height := bar.windows_line(bar_layout, line)
			focus := index == order[order_count - 1]
			if line == menu_line {
				interface.draw_rectangle(table, line_x, line_y, line_width, line_height, graphics.COLOR_CHOSEN)
			}
			if focus {
				// The window that has the focus: a square, and its title in white.
				interface.draw_rectangle(table, line_x + 8, line_y + 8, 8, 8, line == menu_line ? graphics.COLOR_WHITE : graphics.COLOR_TITLE)
			}
			title := interface.text_fit(table, interface.FONT_INTERFACE, system.name_of(clients[index].title[:]), line_width - bar.WINDOWS_TITLE_X - bar.PADDING)
			interface.draw_text(table, line_x + bar.WINDOWS_TITLE_X, line_y + 4, title, focus || line == menu_line ? graphics.COLOR_WHITE : graphics.COLOR_TEXT, interface.FONT_INTERFACE)
		}
	}
	if menu_open == .Programs {
		menu_left, menu_top, menu_width, menu_height := bar.menu(bar_layout)
		interface.card(&card_frame, {menu_left, menu_top, menu_width, menu_height}, "PROGRAMS", "bar.names", graphics.COLOR_KERNEL, interface.number_text(&count, len(bar.names)))
		for name, index in bar.names {
			line_x, line_y, line_width, line_height := bar.line(bar_layout, index)
			if index == menu_line {
				interface.draw_rectangle(table, line_x, line_y, line_width, line_height, graphics.COLOR_CHOSEN)
			}
			interface.draw_text(table, line_x + bar.PADDING, line_y + 4, name, index == menu_line ? graphics.COLOR_WHITE : graphics.COLOR_TEXT, interface.FONT_INTERFACE)
		}
	}
	if table.full {
		system.log_in("surfaces", .Warning, "compositor: the draw table of the screen is full: records are missing")
	}
}

// window_frame_of gives the frame that the compositor draws around the
// surface of a client, for the places of support/bar.
window_frame_of :: proc "contextless" (client: ^Client) -> bar.Window_Frame {
	return {outer_width = client.surface.width + 2 * BORDER, border = BORDER, close_size = CLOSE_SIZE, title_height = TITLE_HEIGHT}
}
