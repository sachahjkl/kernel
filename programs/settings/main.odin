// The settings of the person (docs/FONTS.md, "The setting"): the font of
// the system (the vector font or Spleen 8x16) and the order of the color
// stripes of the screen. The window shows each choice as buttons and the
// text of the system at its three sizes; the exports set() and get() make
// the same changes from the console and from `kerneltool call`.
//
// This program is the one writer of the settings page (contract:settings).
// A change wakes the compositor, which gives the new font to each window:
// every program draws again, with no code of its own for it.
package settings_program

import "contract:errors"
import "contract:isolated"
import "contract:settings"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:system"

WIDTH :: 624
HEIGHT :: 472

page: ^settings.Page
service: system.Service

records_now, records_before: [256]interface.Draw_Record
text_now, text_before: [8192]u8
drawing: interface.Window_Drawing
drawn_change: u32 = 1 // The change count of the last frame; odd: none yet.

ERROR_PERSON :: -1
ERROR_NAME :: -2
ERROR_VALUE :: -3

// change writes a new choice on the page, wakes the compositor, and writes
// the change on the log.
change :: proc "contextless" (font: settings.Font, order: settings.Subpixel_Order) {
	choice := settings.read(page)
	if choice.font == font && choice.subpixel_order == order {
		return
	}
	settings.write(page, font, order)
	system.word_wake(&page.change_count, 64)
	system.log("settings: font ", settings.font_names[font], ", subpixel order ", settings.subpixel_order_names[order])
}

@(private = "file")
person :: proc "contextless" () -> bool {
	caller := system.service_caller()
	return caller == nil || caller.grant & isolated.CALLER_PERSON != 0
}

// copied copies a text argument: the caller can change the call region
// during the call.
@(private = "file")
copied :: proc "contextless" (text: string, buffer: []u8) -> (string, bool) {
	if len(text) > len(buffer) {
		return "", false
	}
	count := copy(buffer, text)
	return string(buffer[:count]), true
}

// set changes a setting of the person: set("font", "vector") or set("font", "spleen"); set("subpixel_order", "rgb"), "bgr" or "none" (grayscale). Every window draws again with the new text. The result is 1, or a negative number with an error record. The error kinds: No_Grant (-1, the caller does not act for the person); Absent (-2, no setting has this name); Bad_Value (-3, the setting has no such value).
@(export, link_name = "set")
set :: proc "c" (name: ^string, value: ^string, error: ^errors.Error_Record) -> i64 {
	if !person() {
		return errors.fail(error, ERROR_PERSON, .No_Grant, .Person)
	}
	name_buffer, value_buffer: [32]u8
	wanted, name_ok := copied(name^, name_buffer[:])
	given, value_ok := copied(value^, value_buffer[:])
	if !name_ok || !value_ok {
		return errors.fail(error, ERROR_VALUE, .Too_Long, .Bytes, name_ok ? 2 : 1, i64(max(len(name^), len(value^))), 32)
	}
	choice := settings.read(page)
	switch wanted {
	case "font":
		for text, font in settings.font_names {
			if text == given {
				change(font, choice.subpixel_order)
				return 1
			}
		}
	case "subpixel_order":
		for text, order in settings.subpixel_order_names {
			if text == given {
				change(choice.font, order)
				return 1
			}
		}
	case:
		return errors.fail(error, ERROR_NAME, .Absent, .None, 1)
	}
	return errors.fail(error, ERROR_VALUE, .Bad_Value, .None, 2)
}

// get gives the value of a setting of the person as a text: get("font") is "vector" or "spleen"; get("subpixel_order") is "rgb", "bgr" or "none". The text is empty for a name that no setting has.
@(export, link_name = "get")
get :: proc "c" (name: ^string, result: ^[]u8) -> i64 {
	name_buffer: [32]u8
	wanted, ok := copied(name^, name_buffer[:])
	if !ok {
		return 0
	}
	choice := settings.read(page)
	text := ""
	switch wanted {
	case "font":
		text = settings.font_names[choice.font]
	case "subpixel_order":
		text = settings.subpixel_order_names[choice.subpixel_order]
	}
	return i64(copy(result^, text))
}

// draw builds the window: the two settings as buttons, then the text of
// the system at its three sizes, then the facts of the glyph cache.
draw :: proc "contextless" (window: ^display.Window) {
	choice := settings.read(page)
	frame := interface.window_frame_begin(&drawing)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	count: interface.Text_Builder
	interface.text_put(&count, "change ")
	interface.text_put_number(&count, u64(choice.change_count / 2))
	content := interface.card(&frame, {8, 8, WIDTH - 16, 168}, "SETTINGS", "contract/settings: the page of the person", graphics.COLOR_KERNEL, interface.text_of(&count))
	interface.draw_text(frame.table, content.x, content.y + 4, "font", graphics.COLOR_DIM)
	for name, font in settings.font_names {
		area := interface.Area{content.x + 160 + int(font) * 104, content.y, 96, 24}
		if interface.button(&frame, area, interface.identity(name), name, choice.font == font).activated {
			change(font, choice.subpixel_order)
		}
	}
	interface.draw_text(frame.table, content.x, content.y + 40, "subpixel order", graphics.COLOR_DIM)
	for name, order in settings.subpixel_order_names {
		area := interface.Area{content.x + 160 + int(order) * 104, content.y + 36, 96, 24}
		if interface.button(&frame, area, interface.identity(name), name, choice.subpixel_order == order).activated {
			change(choice.font, order)
		}
	}
	interface.draw_text(frame.table, content.x, content.y + 80, "the console: settings.set(\"font\", \"spleen\")", graphics.COLOR_DIM)
	interface.draw_text(frame.table, content.x, content.y + 96, "keys: tab, then enter on a button", graphics.COLOR_DIM)

	sample := interface.card(&frame, {8, 184, WIDTH - 16, HEIGHT - 192}, "THE TEXT OF THE SYSTEM", choice.font == .Spleen ? "Spleen 8x16, the fallback" : "the vector font, from the glyph cache", graphics.COLOR_MACHINE)
	lines := [?]string {
		"> print(monitor.programs())   31 programs",
		"compositor   12.4 ms   2 418 pages   runs",
		"{fill} [rings] gi Rb 0O 1lI  ok: 0x4F3A",
	}
	for line, index in lines {
		interface.draw_text(frame.table, sample.x, sample.y + index * 16, line, graphics.COLOR_TEXT)
	}
	interface.draw_text(frame.table, sample.x, sample.y + 56, "EEVDF fair", graphics.COLOR_PROGRAM, interface.FONT_MEDIUM)
	after := interface.large_number(&frame, sample.x, sample.y + 96, "12 345", graphics.COLOR_TEXT)
	interface.draw_text(frame.table, after + 16, sample.y + 120, "wakes in one second", graphics.COLOR_DIM)
	facts: interface.Text_Builder
	if page.glyph_cache_size == 0 {
		interface.text_put(&facts, "no glyph cache: the text is Spleen 8x16")
	} else {
		interface.text_put(&facts, "glyph cache ")
		interface.text_put_number(&facts, page.glyph_cache_size)
		interface.text_put(&facts, " bytes, hash ")
		hex := "0123456789abcdef"
		for byte in page.glyph_cache_hash[:6] {
			interface.text_put(&facts, hex[byte >> 4:][:1])
			interface.text_put(&facts, hex[byte & 15:][:1])
		}
		interface.text_put(&facts, graphics.text_vector_drawn() ? ", valid" : ", not used")
	}
	interface.draw_text(frame.table, sample.x, sample.y + sample.height - 16, interface.text_of(&facts), graphics.COLOR_DIM)
	interface.window_frame_end(&drawing, &frame, window)
	if choice.change_count != drawn_change && drawn_change != 1 {
		system.log("settings: drawn with the font ", settings.font_names[choice.font], ", subpixel order ", settings.subpixel_order_names[choice.subpixel_order])
	}
	drawn_change = choice.change_count
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	page_handle := ctx.handles[settings.GRANT_PAGE]
	address, status := system.memory_map(page_handle)
	if status != .Ok {
		system.log("settings: no settings page: status ", u64(status))
		system.stop(1)
	}
	page = (^settings.Page)(address)
	window, ok := display.open(ctx, WIDTH, HEIGHT, "settings")
	if !ok {
		system.stop(1)
	}
	service, _ = system.service_open(ctx)
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	draw(&window)
	choice := settings.read(page)
	system.log("settings: ok, font ", settings.font_names[choice.font], ", subpixel order ", settings.subpixel_order_names[choice.subpixel_order])
	for {
		wait := system.wait_begin()
		display.wait_events(&wait, &window)
		system.service_wait(&wait, &service)
		system.wait_end(&wait)
		system.service_run(&service)
		if interface.window_events(&drawing, &window) {
			draw(&window)
		}
	}
}
