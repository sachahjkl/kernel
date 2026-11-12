// The display protocol, and the code that a program uses to show a surface.
//
// A program and the compositor share one ring. The program sends command
// records; the compositor sends input as completion records. The pixels of
// the surface are memory that the program creates and grants to the
// compositor. No pixel goes through the ring or through the kernel.
//
// The memory of a surface has one picture or two. With one picture, the
// compositor can read the picture while the program draws: the screen can
// show a part of the new picture with a part of the old one. With two
// pictures, the program draws one while the compositor reads the other,
// and Present names the picture that is complete.
package display

import "contract:errors"
import "support:graphics"
import "contract:ring"
import "contract:fixed_addresses"
import "contract:glyph_cache"
import "contract:pointer_pictures"
import "contract:settings"
import "support:system"

Command :: enum u32 {
	None           = 0,
	Surface_Create = 1, // values: memory handle (in the compositor), width, height, title (4 values)
	Present        = 2, // The pixels of the surface changed. values: the picture to show (0 or 1), then the rectangle that changed: x, y, width, height (width 0: the whole surface)
	Pointer_Shape  = 3, // The pointer shape over this surface (docs/POINTERS.md). values: a number of pointer_pictures.Pointer_Shape
}

Event_Kind :: enum u32 {
	None             = 0,
	Key              = 1, // values: code, character, 1 when pressed, modifiers
	Pointer          = 2, // values: x, y in the surface (signed), buttons
	// The settings of the person changed (contract:settings): next_event
	// already gave the new font to support/graphics; the program draws its
	// window again. values: the change count of the settings page.
	Settings_Changed = 3,
}

// The ring between the root service and the compositor.
Control :: enum u32 {
	None          = 0,
	Client_Add    = 1, // root to compositor. values: ring memory handle (in the compositor)
	Client_Remove = 2, // root to compositor. values: the same handle
	Start         = 3, // compositor to root. values: name (4 values)
	Stop          = 4, // compositor to root. values: the handle of the client
}

// The ring from the input service to the compositor.
Input :: enum u32 {
	None    = 0,
	Key     = 1, // values: code, character, 1 when pressed, modifiers
	Pointer = 2, // values: x motion, y motion (signed), buttons
}

KEY_EXTENDED :: 0x100
KEY_ESCAPE :: 0x01
KEY_BACKSPACE :: 0x0E
KEY_ENTER :: 0x1C
KEY_TAB :: 0x0F
KEY_DELETE :: KEY_EXTENDED | 0x53
KEY_UP :: KEY_EXTENDED | 0x48
KEY_DOWN :: KEY_EXTENDED | 0x50
KEY_LEFT :: KEY_EXTENDED | 0x4B
KEY_RIGHT :: KEY_EXTENDED | 0x4D
KEY_HOME :: KEY_EXTENDED | 0x47
KEY_END :: KEY_EXTENDED | 0x4F
KEY_PAGE_UP :: KEY_EXTENDED | 0x49
KEY_PAGE_DOWN :: KEY_EXTENDED | 0x51
KEY_SUPER :: KEY_EXTENDED | 0x5B // The left key with the logo. The compositor keeps it: it opens the launcher.

MODIFIER_SHIFT :: 1
MODIFIER_CONTROL :: 2

BUTTON_LEFT :: 1
BUTTON_RIGHT :: 2

SURFACE_LIMIT :: 2048 // The largest width and height.

Event :: struct {
	kind:      Event_Kind,
	code:      u32,
	character: u8,
	pressed:   bool,
	modifiers: u32,
	x, y:      int,
	buttons:   u32,
}

Window :: struct {
	ring_memory: system.Handle,
	ring:        ring.Ring,
	surface:     system.Handle,
	canvas:      graphics.Canvas, // Where the program draws now.
	pictures:    [2]graphics.Canvas,
	picture:     int, // The index of canvas in pictures.
	two:         bool, // The surface has two pictures.
	presented:   u32, // The count of commands after the last Present.
	// The measure of the time of a picture (docs/DESIGN.md, section 7):
	// picture_begin marks the start, present the end; in a measure run the
	// log has their mean after 1, 3 and 10 pictures.
	title:              [32]u8,
	title_count:        int,
	picture_started:    u64,
	picture_count:      u64,
	picture_time:       u64,
}

PICTURES_MEASURED :: 10
// A measure run: the log has the time of the pictures of each window, after
// 1, 3 and 10 pictures. A normal run writes none of these lines: the ring of
// the log keeps 1023 records, and the main scenario reads its oldest records
// (the channel boot) late in the run, with about 13 records of room.
MEASURE_RUN :: #config(MEASURE_RUN, false)

// picture_begin marks the start of a picture, for the measure of present.
picture_begin :: proc "contextless" (window: ^Window) {
	window.picture_started = system.nanoseconds()
}

// picture_end ends the measure of a picture: present calls it, and a
// program that draws nothing in a frame (no damage) calls it.
picture_end :: proc "contextless" (window: ^Window) {
	if window.picture_started != 0 && window.picture_count < PICTURES_MEASURED {
		window.picture_time += system.nanoseconds() - window.picture_started
		window.picture_count += 1
		if count := window.picture_count; MEASURE_RUN && (count == 1 || count == 3 || count == PICTURES_MEASURED) {
			mean := window.picture_time / count
			system.log("display: ", string(window.title[:window.title_count]), " drew one picture in ", mean / 1000, ".", mean / 100 % 10, " us, the mean of ", count)
		}
	}
	window.picture_started = 0
}

// open creates a surface and shows it. The program draws in window.canvas,
// then calls present.
// With two_pictures, present changes window.canvas to the other picture:
// the program draws each picture from nothing, and it calls canvas_free
// before it draws.
//
// error: the record of a failure, if the caller gives one. The record of a
// kernel operation that failed has its operation; a record of open itself
// has the operation 0 and the arguments of OPEN_ARGUMENTS (error_text).
open :: proc "contextless" (ctx: ^system.Context, width, height: int, title: string, two_pictures := false, error: ^errors.Error_Record = nil) -> (window: Window, ok: bool) {
	window.ring_memory = ctx.handles[system.GRANT_DISPLAY]
	switch {
	case window.ring_memory == 0:
		errors.fail(error, 0, .No_Grant, .Display)
		return {}, false
	case width < 1 || width > SURFACE_LIMIT:
		errors.fail(error, 0, .Bad_Value, .None, 2, i64(width), SURFACE_LIMIT)
		return {}, false
	case height < 1 || height > SURFACE_LIMIT:
		errors.fail(error, 0, .Bad_Value, .None, 3, i64(height), SURFACE_LIMIT)
		return {}, false
	case len(title) > len(system.Name) - 1:
		errors.fail(error, 0, .Too_Long, .Bytes, 4, i64(len(title)), len(system.Name) - 1)
		return {}, false
	}
	text_settings_open(ctx)
	interface_font_load(ctx)
	status: system.Status
	if window.ring, status = system.ring_open(window.ring_memory, error); status != .Ok {
		return {}, false
	}
	address: rawptr
	pages := (u64(width * height * size_of(graphics.Color) * (two_pictures ? 2 : 1)) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	window.surface, status = system.memory_create(pages, error = error)
	if status != .Ok {
		return {}, false
	}
	address, status = system.memory_map(window.surface, error = error)
	if status != .Ok {
		return {}, false
	}
	window.two = two_pictures
	window.title_count = copy(window.title[:], title)
	for &picture, index in window.pictures {
		picture = {pixels = ([^]graphics.Color)(address)[index * width * height:], width = width, height = height, stride = width}
	}
	window.canvas = window.pictures[0]

	// The compositor maps the ring when the root service tells it of this
	// program. Until then, the grant has no receiver.
	granted: system.Handle
	for attempt in 0 ..< 200 {
		granted, status = system.give(window.ring_memory, window.surface, {.Read}, attempt == 199 ? error : nil) // The compositor reads the surface.
		if status == .Ok {
			break
		}
		system.sleep(system.time() + 5)
	}
	if status != .Ok {
		return {}, false
	}
	name := system.name_pack(title)
	command := ring.Record {
		kind = u32(Command.Surface_Create),
		values = {u64(granted), u64(width), u64(height), name[0], name[1], name[2], name[3]},
	}
	system.send(&window.ring.commands, command)
	return window, true
}

// The names of the arguments of open, for the sentence of a record that
// open wrote: system.wrapper_error_text(writer, &error, "display.open", display.OPEN_ARGUMENTS[:]).
@(rodata)
OPEN_ARGUMENTS := [?]string{"ctx", "width", "height", "title", "two_pictures"}

// present tells the compositor that the picture in window.canvas is
// complete. It gives false when the command ring was full: the compositor
// did not get the present.
present :: proc "contextless" (window: ^Window) -> bool {
	return present_rectangle(window, 0, 0, 0, 0)
}

// present_rectangle tells the compositor that the picture in window.canvas
// is complete, and that only one rectangle of it changed: the compositor
// draws again only that part of the window. A width of 0 is the whole
// surface. It gives false when the command ring was full: the compositor
// did not get the present, and with two pictures the canvas stays the same.
present_rectangle :: proc "contextless" (window: ^Window, x, y, width, height: int) -> bool {
	picture_end(window)
	record := ring.Record{kind = u32(Command.Present), values = {0 = u64(window.picture), 1 = u64(max(x, 0)), 2 = u64(max(y, 0)), 3 = u64(max(width, 0)), 4 = u64(max(height, 0))}}
	if !system.send(&window.ring.commands, record) {
		return false
	}
	if window.two {
		window.presented = window.ring.commands.counters.write
		window.picture = 1 - window.picture
		window.canvas = window.pictures[window.picture]
	}
	return true
}

// pointer_shape_set asks the compositor for a pointer shape over the
// surface of the window. The compositor shows it while the pointer is over
// this surface and the surface is in front at that place, never over
// another surface, the bar or a frame: a program changes the pointer only
// over its own window. The shape stays until
// the next request; the shape of a new surface is the arrow.
pointer_shape_set :: proc "contextless" (window: ^Window, shape: pointer_pictures.Pointer_Shape) {
	system.send(&window.ring.commands, ring.Record{kind = u32(Command.Pointer_Shape), values = {0 = u64(shape)}})
}

// canvas_free says if the program can draw in window.canvas. With two
// pictures, the compositor reads the other picture only after it took the
// last Present: until then, it can still read this one.
canvas_free :: proc "contextless" (window: ^Window) -> bool {
	return !window.two || i32(window.ring.commands.counters.read - window.presented) >= 0
}

// wait stops the thread until the window has an input event, or until the
// time is deadline. It gives the time.
wait :: proc "contextless" (window: ^Window, deadline: u64 = system.WAIT_FOREVER) -> u64 {
	list: system.Wait
	wait_events(&list, window)
	return system.wait_end(&list, deadline)
}

// wait_events adds the input events of the window to a wait list.
wait_events :: proc "contextless" (list: ^system.Wait, window: ^Window) {
	system.wait_records(list, &window.ring.completions)
}

// next_event gives the next input event of the window, if there is one.
next_event :: proc "contextless" (window: ^Window) -> (event: Event, ok: bool) {
	record := system.receive(&window.ring.completions) or_return
	event.kind = Event_Kind(record.kind)
	#partial switch event.kind {
	case .Key:
		event.code = u32(record.values[0])
		event.character = u8(record.values[1])
		event.pressed = record.values[2] != 0
		event.modifiers = u32(record.values[3])
	case .Pointer:
		event.x = int(i64(record.values[0]))
		event.y = int(i64(record.values[1]))
		event.buttons = u32(record.values[2])
	case .Settings_Changed:
		text_settings_apply()
	}
	return event, true
}

// The settings page of this program (contract:settings), or nil.
settings_page: ^settings.Page

// The two glyph caches of this program, each validated once: with the grid fit
// and without it (the setting "grid_fit").
glyph_caches: [settings.Grid_Fit]glyph_cache.Cache
glyph_cache_valid: [settings.Grid_Fit]bool

// text_settings_open finds the settings page in the context, validates the
// glyph caches once (a font file and a cache are hostile input), and
// applies the choice of the person. With no page, or a cache that the
// validation refuses, the text of the program is Spleen 8x16, with a line
// on the log. The compositor calls it too.
//
// Why one validation is enough: the drawing code reads the counts and the
// offsets of a cache again at each glyph, so the bytes must not change
// after `validate`. A program trusts its starter, which already chooses
// its grants, its mappings and its budget: the starter states in the
// context which fixed ranges it mapped (contract:fixed_addresses) and maps
// the memory there; the cache states its own size in its header. So a
// starter that sets a bit with no mapping, or maps less than the header
// states, makes this program fault, and a starter that keeps that memory
// with Write could change it. The root service is the starter of each
// program with a surface. It maps each cache from the boot image with the
// right Read only, for every program, and the one handle of the boot image,
// its own, has no right Write. So under the root service no program can
// write the bytes of a cache, nor point this program at other bytes. The
// settings page, which the program `settings` writes, gives choices only.
text_settings_open :: proc "contextless" (ctx: ^system.Context) {
	if .Settings_Page not_in fixed_addresses.ranges_mapped(&ctx.values) || settings_page != nil {
		return
	}
	settings_page = (^settings.Page)(uintptr(settings.PAGE_ADDRESS))
	places := [settings.Grid_Fit]settings.Glyph_Cache {
		.On  = .With_Grid_Fit,
		.Off = .Without_Grid_Fit,
	}
	for cache, grid_fit in places {
		problem: glyph_cache.Problem
		glyph_caches[grid_fit], problem = settings.glyph_cache_open(&ctx.values, cache)
		if problem.kind == .Not_Mapped {
			system.log_in("programs", .Warning, "display: no glyph cache with the grid fit ", settings.descriptions[.Grid_Fit].value_names[grid_fit], ": that text is Spleen 8x16")
			continue
		}
		if problem.kind != .None {
			system.log_in("programs", .Warning, "display: the glyph cache is refused: ", glyph_cache.problem_sentences[problem.kind], ", value ", problem.value, ", limit ", problem.limit, ": that text is Spleen 8x16")
			continue
		}
		if refused := graphics.cell_cache_problem(&glyph_caches[grid_fit]); refused.kind != .None {
			system.log_in("programs", .Warning, "display: the glyph cache is refused: ", glyph_cache.problem_sentences[refused.kind], ": that text is Spleen 8x16")
			continue
		}
		glyph_cache_valid[grid_fit] = true
	}
	// The bold weight of the titles: a text in the regular weight when it
	// is absent or refused.
	if bold, problem := settings.glyph_cache_open(&ctx.values, .Bold); problem.kind != .Not_Mapped {
		if problem.kind == .None {
			problem = graphics.text_bold_cache_use(bold)
		}
		if problem.kind != .None {
			system.log_in("programs", .Warning, "display: the bold glyph cache is refused: ", glyph_cache.problem_sentences[problem.kind], ": the titles are the regular weight")
		}
	}
	text_settings_apply()
}

// Interface_Font: the two glyph caches of the interface font (docs/FONTS.md,
// section 12), each validated once.
Interface_Font :: struct {
	regular: glyph_cache.Cache,
	bold:    glyph_cache.Cache,
}

// interface_font_open validates the two glyph caches of the interface font
// that the starter mapped at their fixed ranges (settings.glyph_cache_open:
// the same rule as the caches of the text of cells). ok is false when one
// is absent or refused, with a line on the log: the program then draws its
// text with the font of the cells. Each cache must be of a proportional
// font: graphics.text_proportional draws it.
interface_font_open :: proc "contextless" (ctx: ^system.Context) -> (font: Interface_Font, ok: bool) {
	weights := [2]settings.Glyph_Cache{.Interface, .Interface_Bold}
	caches: [2]glyph_cache.Cache
	for weight, index in weights {
		problem: glyph_cache.Problem
		caches[index], problem = settings.glyph_cache_open(&ctx.values, weight)
		if problem.kind == .None && caches[index].header.flags & glyph_cache.FLAG_PROPORTIONAL == 0 {
			problem = {kind = .Bad_Flags, value = u64(caches[index].header.flags), limit = glyph_cache.FLAG_PROPORTIONAL}
		}
		if problem.kind == .Not_Mapped {
			// A program that its starter gave no interface font: its
			// elements draw in the font of the cells, with no line on the log.
			return {}, false
		}
		if problem.kind != .None {
			system.log_in("programs", .Warning, "display: the glyph cache of the interface font is refused: ", glyph_cache.problem_sentences[problem.kind], ", value ", problem.value)
			return {}, false
		}
	}
	return {regular = caches[0], bold = caches[1]}, true
}

// The interface font of this program, validated once by open: the elements
// of support/interface draw their names, titles and labels in it
// (docs/FONTS.md, section 12.6). Absent: they draw in the font of the
// cells.
program_interface_font: Interface_Font
program_interface_font_given: bool

// interface_font_load validates the interface font of this program once:
// open calls it, and the compositor, which draws with no window of its own.
interface_font_load :: proc "contextless" (ctx: ^system.Context) {
	if !program_interface_font_given {
		program_interface_font, program_interface_font_given = interface_font_open(ctx)
	}
}

// interface_font_of gives the interface font of this program, or nil.
interface_font_of :: proc "contextless" () -> ^Interface_Font {
	return program_interface_font_given ? &program_interface_font : nil
}

// text_settings_apply gives the choice of the settings page to
// support/graphics: the font, the order of the stripes, and the glyph cache
// of the grid fit.
text_settings_apply :: proc "contextless" () {
	if settings_page == nil {
		return
	}
	choice := settings.read(settings_page)
	grid_fit := settings.grid_fit_of(choice)
	font := settings.font_of(choice) == .Spleen ? graphics.Text_Font.Spleen : graphics.Text_Font.Vector
	if glyph_cache_valid[grid_fit] {
		graphics.text_cache_use(glyph_caches[grid_fit])
	} else {
		font = .Spleen
	}
	graphics.text_choice_set(font, graphics.Subpixel_Order(u8(settings.subpixel_order_of(choice))))
}
