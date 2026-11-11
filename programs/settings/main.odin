// The settings of the person (docs/FONTS.md, "The setting"): the font of
// the system, the order of the color stripes of the screen, the pointer
// theme and the grid fit of the vector font. The window shows each setting
// as a row of buttons and the text of the system at its three sizes; the
// exports set() and get() make the same changes from the console and from
// `kerneltool call`.
//
// This program is the one writer of the settings page (contract:settings).
// A change is written first to its private store, as one record in one
// object (one commit), then to the page; the page wakes the compositor,
// which gives the new font and pointer theme to each window: every program
// draws again, with no code of its own for it.
//
// At boot the root service starts this program for one pass with no window
// (the context value VALUE_BOOT_PASS): it reads the record of its store,
// writes the page, and stops.
package settings_program

import "contract:errors"
import "contract:isolated"
import "contract:settings"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:storage"
import "support:system"

WIDTH :: 560
HEIGHT :: 520

page: ^settings.Page
service: system.Service
store: storage.Client
has_store: bool

records_now, records_before: [320]interface.Draw_Record
text_now, text_before: [8192]u8
drawing: interface.Window_Drawing
drawn_change: u32 = 1 // The change count of the last frame; odd: none yet.

ERROR_PERSON :: -1
ERROR_NAME :: -2
ERROR_VALUE :: -3
ERROR_STORE :: -4

// values_text writes the values of a choice: "font vector, subpixel order
// rgb, pointer theme owner, grid fit on".
values_text :: proc "contextless" (writer: ^system.Writer, values: [settings.Setting]u32) -> string {
	for setting in settings.Setting {
		description := settings.descriptions[setting]
		system.write_part(writer, setting == .Font ? "" : ", ")
		system.write_part(writer, description.title)
		system.write_part(writer, " ")
		system.write_part(writer, description.value_names[settings.valid(setting, values[setting])])
	}
	return system.written(writer)
}

// keep writes the record of the values to the private store: one object,
// one commit. It gives false, with a log line, when the store refuses.
keep :: proc "contextless" (values: [settings.Setting]u32) -> bool {
	if !has_store {
		return false
	}
	kept := settings.kept_of(values)
	error: errors.Error_Record
	_, status := storage.write(&store, settings.KEPT_OBJECT_NAME, ([^]u8)(&kept)[:size_of(kept)], &error)
	if status != .Ok {
		buffer: [256]u8
		writer := system.Writer{buffer = buffer[:]}
		storage.error_text(&writer, &store, &error)
		system.log_in("programs", .Warning, "settings: the store did not keep the settings: ", system.written(&writer))
		return false
	}
	return true
}

// change keeps the values, then writes them on the page and wakes the
// compositor.
change :: proc "contextless" (values: [settings.Setting]u32) -> bool {
	choice := settings.read(page)
	if choice.values == values {
		return true
	}
	kept := keep(values)
	settings.write(page, values)
	system.word_wake(&page.change_count, 64)
	buffer: [256]u8
	writer := system.Writer{buffer = buffer[:]}
	system.log("settings: ", values_text(&writer, values), kept ? "; kept in the store" : "; NOT kept: the store refused")
	return kept
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

// setting_of finds a setting by its name.
@(private = "file")
setting_of :: proc "contextless" (name: string) -> (setting: settings.Setting, found: bool) {
	for description, each in settings.descriptions {
		if description.name == name {
			return each, true
		}
	}
	return {}, false
}

// set changes a setting of the person, and keeps it in the store: set("font", "vector" or "spleen"); set("subpixel_order", "rgb", "bgr" or "none"); set("pointer_theme", "owner" or "system"); set("grid_fit", "on" or "off"). Every window draws again. The result is 1, or a negative number with an error record. The error kinds: No_Grant (-1, the caller does not act for the person); Absent (-2, no setting has this name); Bad_Value (-3, the setting has no such value); Refused (-4, the page changed but the store did not keep it).
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
	setting, found := setting_of(wanted)
	if !found {
		return errors.fail(error, ERROR_NAME, .Absent, .None, 1)
	}
	description := &settings.descriptions[setting]
	for value_name, index in description.value_names[:description.value_count] {
		if value_name == given {
			values := settings.read(page).values
			values[setting] = u32(index)
			if !change(values) {
				return errors.fail(error, ERROR_STORE, .Refused, .None, 2)
			}
			return 1
		}
	}
	return errors.fail(error, ERROR_VALUE, .Bad_Value, .None, 2)
}

// get gives the value of a setting of the person as a text: get("font"), get("subpixel_order"), get("pointer_theme"), get("grid_fit"). The text is empty for a name that no setting has.
@(export, link_name = "get")
get :: proc "c" (name: ^string, result: ^[]u8) -> i64 {
	name_buffer: [32]u8
	wanted, ok := copied(name^, name_buffer[:])
	if !ok {
		return 0
	}
	setting, found := setting_of(wanted)
	if !found {
		return 0
	}
	values := settings.read(page).values
	return i64(copy(result^, settings.descriptions[setting].value_names[values[setting]]))
}

// repeat keeps count records in the store, one commit each, with the font and the subpixel order of each record from its number: the case of the loss of power of the machine test (a loss in the middle gives the record before or the record in flight, never a mix). The page takes the last record. The result is the count of records kept, or a negative number with an error record: No_Grant (-1); Bad_Value (-3, a count outside 1 to 1000); Refused (-4, the store refused a record).
@(export, link_name = "repeat")
repeat :: proc "c" (count: i64, error: ^errors.Error_Record) -> i64 {
	if !person() {
		return errors.fail(error, ERROR_PERSON, .No_Grant, .Person)
	}
	if count < 1 || count > 1000 {
		return errors.fail(error, ERROR_VALUE, .Bad_Value, .None, 1, count, 1000)
	}
	values := settings.read(page).values
	for number in 0 ..< count {
		values[.Font] = u32(number % 2)
		values[.Subpixel_Order] = u32(number % 3)
		if !keep(values) {
			return errors.fail(error, ERROR_STORE, .Refused, .None, 1, number)
		}
	}
	settings.write(page, values)
	system.word_wake(&page.change_count, 64)
	system.log("settings: kept ", u64(count), " records, one commit each")
	return count
}

// boot_pass reads the record of the store and writes the page: the pass of
// the boot, with no window.
boot_pass :: proc "contextless" () -> ! {
	start := system.nanoseconds()
	buffer: [64]u8
	values: [settings.Setting]u32
	what := "no settings kept: the defaults"
	if has_store {
		bytes, found, status := storage.read(&store, settings.KEPT_OBJECT_NAME, buffer[:])
		switch {
		case status != .Ok:
			what = "the store gives no record (status not Ok): the defaults"
		case !found:
		case:
			read, valid := settings.kept_read(bytes)
			if valid {
				values = read
				what = "the settings kept in the store"
			} else {
				what = "the record of the store is not a record of this version: the defaults"
			}
		}
	} else {
		what = "no private store: the defaults"
	}
	settings.write(page, values)
	system.word_wake(&page.change_count, 64)
	text: [256]u8
	writer := system.Writer{buffer = text[:]}
	system.log("settings: the boot pass: ", what, ": ", values_text(&writer, values), "; in ", (system.nanoseconds() - start) / 1000, " us")
	system.stop(0)
}

// draw builds the window: a row of buttons for each setting, then the text
// of the system at its three sizes, then the facts of the glyph caches.
draw :: proc "contextless" (window: ^display.Window) {
	choice := settings.read(page)
	frame := interface.window_frame_begin(&drawing)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	count: interface.Text_Builder
	interface.text_put(&count, "change ")
	interface.text_put_number(&count, u64(choice.change_count / 2))
	ROW :: 36
	rows_height := len(settings.Setting) * ROW
	content := interface.card(&frame, {8, 8, WIDTH - 16, 40 + rows_height + 48}, "SETTINGS", has_store ? "kept in the store of settings" : "NOT kept: no store", graphics.COLOR_KERNEL, interface.text_of(&count))
	for &description, setting in settings.descriptions {
		y := content.y + int(setting) * ROW
		interface.draw_text(frame.table, content.x, y + 4, description.title, graphics.COLOR_DIM)
		for value_name, index in description.value_names[:description.value_count] {
			area := interface.Area{content.x + 144 + index * 104, y, 96, 24}
			builder: interface.Text_Builder
			interface.text_put(&builder, description.name)
			interface.text_put(&builder, value_name)
			if interface.button(&frame, area, interface.identity(interface.text_of(&builder)), value_name, choice.values[setting] == u32(index)).activated {
				values := choice.values
				values[setting] = u32(index)
				change(values)
			}
		}
	}
	interface.draw_text(frame.table, content.x, content.y + rows_height + 8, "the console: settings.set(\"font\", \"spleen\")", graphics.COLOR_DIM)
	interface.draw_text(frame.table, content.x, content.y + rows_height + 24, "keys: tab, then enter on a button", graphics.COLOR_DIM)

	top := 8 + 40 + rows_height + 48 + 8
	vector := settings.font_of(choice) == .Vector && graphics.text_vector_drawn()
	sample := interface.card(&frame, {8, top, WIDTH - 16, HEIGHT - top - 8}, "THE TEXT OF THE SYSTEM", vector ? "the vector font, from the glyph cache" : "Spleen 8x16, the fallback", graphics.COLOR_MACHINE)
	lines := [?]string {
		"> print(monitor.programs())   31 programs",
		"compositor   12.4 ms   2 418 pages   runs",
		"{fill} [rings] gi Rb 0O 1lI  ok: 0x4F3A",
	}
	for line, index in lines {
		interface.draw_text(frame.table, sample.x, sample.y + index * 16, line, graphics.COLOR_TEXT)
	}
	interface.draw_text(frame.table, sample.x, sample.y + 56, "EEVDF fair", graphics.COLOR_PROGRAM, interface.FONT_MEDIUM)
	after := interface.large_number(&frame, sample.x, sample.y + 88, "12 345", graphics.COLOR_TEXT)
	interface.draw_text(frame.table, after + 16, sample.y + 112, "wakes in one second", graphics.COLOR_DIM)
	facts: interface.Text_Builder
	if page.glyph_cache_size == 0 {
		interface.text_put(&facts, "no glyph cache: the text is Spleen 8x16")
	} else {
		interface.text_put(&facts, "glyph caches ")
		interface.text_put_number(&facts, page.glyph_cache_size)
		interface.text_put(&facts, " and ")
		interface.text_put_number(&facts, page.glyph_cache_without_grid_fit_size)
		interface.text_put(&facts, " bytes, hash ")
		hex := "0123456789abcdef"
		for byte in page.glyph_cache_hash[:4] {
			interface.text_put(&facts, hex[byte >> 4:][:1])
			interface.text_put(&facts, hex[byte & 15:][:1])
		}
	}
	interface.draw_text(frame.table, sample.x, sample.y + sample.height - 16, interface.text_of(&facts), graphics.COLOR_DIM)
	interface.window_frame_end(&drawing, &frame, window)
	if choice.change_count != drawn_change && drawn_change != 1 {
		buffer: [256]u8
		writer := system.Writer{buffer = buffer[:]}
		system.log("settings: drawn with ", values_text(&writer, choice.values))
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
	store, has_store = storage.open(ctx)
	if ctx.values[settings.VALUE_BOOT_PASS] != 0 {
		boot_pass()
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, "settings")
	if !ok {
		system.stop(1)
	}
	service, _ = system.service_open(ctx)
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	draw(&window)
	buffer: [256]u8
	writer := system.Writer{buffer = buffer[:]}
	system.log("settings: ok, ", values_text(&writer, settings.read(page).values))
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
