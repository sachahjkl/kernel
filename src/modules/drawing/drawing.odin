// The drawing module: the damage of a frame and the draw of its records,
// for each program that imports it (docs/INTERFACE.md, section 7). It holds
// the code that finds what changed between two draw tables and the code
// that draws the records of a draw table into pixels: the fills, the
// gradients, the lines, the text of the cells and the text of the
// interface font, with their blends. A program that imports it holds none
// of that code: the system has one copy.
//
// **What it is for.** It is the first [library module](term:library-module):
// code that each program with a window compiled into its own file. The
// [interface package](term:interface-package) keeps, in the program, what a
// program calls many times for each frame: the elements, the layout, the
// input. The [drawing module](term:drawing-module) takes what a program
// calls two times for each frame: `damage_of_draw_table_7`, then
// `execute_draw_table_7`.
//
// **No copy.** Each parameter is memory of the caller, and a direct call
// passes its address: the [draw table](term:draw-table) of the frame, the
// draw table of the frame before, the rectangles, and the pixels of the
// surface, which the module writes in place.
//
// **What it keeps.** It allocates nothing, and it keeps no address of the
// caller after a call. Its own data is a cache, one copy for each program
// that imports it: the text settings of the program (the choice of the
// font, and the glyph caches that the starter of the program mapped,
// validated at the first draw), and the tables of the blend of a text. It
// reads the choice of the settings again at each draw, so a program sends
// it nothing when a setting changes.
//
// **What it does not draw.** A Picture record and a Text_Grid record name
// pixels and cells by an address, which the description of an export
// cannot carry: the module draws nothing for them. A program with such a
// record keeps the interface package compiled in.
//
// **The version in the names.** The 7 in the name of each export is the
// version of the [draw record](term:draw-record). A draw record of another
// version has exports with other names, so a module that reads the records
// in another way cannot take the place of this one.
package drawing

import "base:intrinsics"
import "contract:errors"
import "contract:glyph_cache"
import "contract:settings"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:system"

// The names of the exports say which draw record they read.
#assert(interface.DRAW_RECORD_VERSION == 7)

// A rectangle of the surface, in pixels: right and bottom are not in it.
Damage_Rectangle :: struct {
	left:   i64,
	top:    i64,
	right:  i64,
	bottom: i64,
}

// The shape of the pixels of a canvas, 4 bytes for each pixel, and what
// the draw does in each rectangle before the records.
Canvas_Shape :: struct {
	width:           i64, // Pixels of a line that belong to the canvas.
	height:          i64, // Lines.
	stride:          i64, // Pixels from one line to the next: at least `width`.
	fill_background: i64, // Not 0: each rectangle is painted with `background` first, so a record that the frame no longer has leaves no pixel.
	background:      i64, // The color of that fill, 0x00RRGGBB.
}

// The most records or bytes of a table of a caller: no count times a size
// wraps, and a count holds in an int.
@(private)
TABLE_LIMIT :: u64(1) << 40

// The numbers of the parameters in an error record, from 1.
@(private)
ARGUMENT_BEFORE :: 1
@(private)
ARGUMENT_BEFORE_TEXT :: 2
@(private)
ARGUMENT_DAMAGE_NOW :: 3
@(private)
ARGUMENT_DAMAGE_NOW_TEXT :: 4
@(private)
ARGUMENT_NOW :: 1
@(private)
ARGUMENT_NOW_TEXT :: 2
@(private)
ARGUMENT_RECTANGLES :: 3
@(private)
ARGUMENT_PIXELS :: 4
@(private)
ARGUMENT_SHAPE :: 5

// The text of the program that runs this copy of the module: what the
// module loads one time, at the first draw. It is data of the module, and
// the loader gives each program its own copy.
//
// The rule of the callers: one thread of a program at a time calls
// execute_draw_table_7. It is the rule of the text state of the graphics
// package, which changes "between two frames" (src/library/support/graphics,
// text.odin), and each window of the system has one loop that draws. The
// module takes no lock for it and waits for no other thread: the load
// below, the choice of the settings that each draw applies, the square
// root table and the blend tables are all written with no guard.
//
// What a second thread gets when a program breaks the rule: the two
// threads can both load (they write the same values), and one can draw
// while the other writes the choice of the font or a blend table. That
// draw can show a text in the wrong font or with wrong colors, and when
// the choice of the settings changes at that moment it can read a glyph
// cache record that is half of one cache and half of the other, and
// fault. All of it is inside the program that broke the rule: the module
// runs in its address space, with its own copy of this data.
// damage_of_draw_table_7 reads no text state: any thread can call it.
@(private)
Program_Text :: struct {
	loaded:               bool, // The text settings and the interface font were looked for.
	interface_font:       display.Interface_Font, // The two glyph caches of the interface font, validated.
	interface_font_given: bool, // The starter mapped both, and both are of a proportional font.
}

@(private)
program_text: Program_Text

// A context with no bit set: what a host test reads, as it has no context
// of a program. No fixed range is mapped in it, so nothing is loaded.
@(private)
no_context: system.Context

// program_text_load loads the text settings and the interface font of the
// program, one time, then gives the choice of the settings page to the
// text code of this module: a change of a setting reaches the next draw
// with no message from the program. It writes no line on the log: the
// program validated the same caches when it opened its window, and wrote
// the lines. One thread of a program at a time runs it (Program_Text).
@(private)
program_text_load :: proc "contextless" () {
	if !program_text.loaded {
		context_record := &no_context
		when ODIN_OS == .Freestanding {
			context_record = system.context_record()
		}
		_, _ = display.text_settings_load(context_record)
		weights := [2]settings.Glyph_Cache{.Interface, .Interface_Bold}
		caches: [2]glyph_cache.Cache
		given := true
		for weight, index in weights {
			problem: glyph_cache.Problem
			caches[index], problem = settings.glyph_cache_open(&context_record.values, weight)
			if problem.kind != .None || caches[index].header.flags & glyph_cache.FLAG_PROPORTIONAL == 0 {
				given = false
			}
		}
		if given {
			program_text.interface_font = {regular = caches[0], bold = caches[1]}
			program_text.interface_font_given = true
		}
		program_text.loaded = true
	}
	display.text_settings_apply()
}

// draw_table_of makes a draw table of the package over a Read table and
// its text: the same memory, no copy. Each count is read one time. ok is
// false, with the error record, when a count passes TABLE_LIMIT.
//
// The module does not check the text range of each record here: the
// package checks each range where it uses the record
// (src/library/support/interface, difference.odin and execute.odin), so one place
// holds the rule. These checks protect a correct caller from a wrong count
// or a wrong record: no fault, and no write outside the pixels. They are
// not a defence against a caller that changes its tables during the call.
// The shape, the counts and the rectangles are read one time
// (volatile_load); a draw record is a plain read, which the compiler can
// make again after a check. A direct call is not a border of trust: the
// module runs in the address space of its caller, with the rights of that
// program and its own copy of the data of the module, so a caller that
// cheats reaches only its own memory. In an isolated call the receiver
// gives the export its own copy of the arguments.
@(private)
draw_table_of :: proc "contextless" (records: ^system.Table_To_Read(interface.Draw_Record), text: ^system.Bytes_To_Read, records_argument, text_argument: i64, error: ^errors.Error_Record) -> (table: interface.Draw_Table, ok: bool) {
	record_count := intrinsics.volatile_load(&records.count)
	text_count := intrinsics.volatile_load(&text.count)
	if record_count > TABLE_LIMIT {
		errors.fail(error, -1, .Too_Long, .Records, records_argument, i64(min(record_count, u64(max(i64)))), i64(TABLE_LIMIT))
		return {}, false
	}
	if text_count > TABLE_LIMIT {
		errors.fail(error, -1, .Too_Long, .Bytes, text_argument, i64(min(text_count, u64(max(i64)))), i64(TABLE_LIMIT))
		return {}, false
	}
	return {records = records.records[:record_count], record_count = int(record_count), text = text.bytes[:text_count], text_count = int(text_count)}, true
}

// damage_of_draw_table_7 gives the rectangles of the surface that differ between the draw table before and the draw table now. The result is a Table of at most 8 rectangles, which no two of them touch. A text record that names bytes past its text table differs from each record: its rectangle is damaged. Nothing is copied in a direct call: the two tables are read where the caller has them, and the rectangles are written into the buffer of the caller. It fails with -1 and the error record Too_Long, with the argument, for a table over 2^40 records or bytes.
@(export, link_name = "damage_of_draw_table_7")
damage_of_draw_table_7 :: proc "c" (before: ^system.Table_To_Read(interface.Draw_Record), before_text: ^system.Bytes_To_Read, now: ^system.Table_To_Read(interface.Draw_Record), now_text: ^system.Bytes_To_Read, result: ^[]Damage_Rectangle, error: ^errors.Error_Record) -> i64 {
	before_table, before_ok := draw_table_of(before, before_text, ARGUMENT_BEFORE, ARGUMENT_BEFORE_TEXT, error)
	if !before_ok {
		return -1
	}
	now_table, now_ok := draw_table_of(now, now_text, ARGUMENT_DAMAGE_NOW, ARGUMENT_DAMAGE_NOW_TEXT, error)
	if !now_ok {
		return -1
	}
	damage: interface.Damage
	interface.damage_by_difference(&before_table, &now_table, &damage)
	buffer := result^
	for rectangle, index in damage.rectangles[:damage.count] {
		if index < len(buffer) {
			buffer[index] = {i64(rectangle.left), i64(rectangle.top), i64(rectangle.right), i64(rectangle.bottom)}
		}
	}
	return i64(damage.count)
}

// execute_draw_table_7 draws the records of a draw table into the pixels of a canvas, in each rectangle, cut to it. With `fill_background` of the shape not 0, each rectangle is painted with the color `background` first. The pixels are memory of the caller, written in place: no copy in a direct call. The text is drawn in the font that the settings of the program choose, from the glyph caches of the program. A text record that names bytes past its text table, a Picture record and a Text_Grid record draw nothing. The result is the count of rectangles. It fails with -1 and an error record: Bad_Value of `shape` for a width or a height below 1 or a stride below the width, Too_Small of `pixels` for bytes that do not hold `stride` times `height` pixels, Bad_Address of `pixels` for an address that is not a multiple of 4, Too_Long for a table over 2^40 records or bytes.
@(export, link_name = "execute_draw_table_7")
execute_draw_table_7 :: proc "c" (now: ^system.Table_To_Read(interface.Draw_Record), now_text: ^system.Bytes_To_Read, rectangles: ^system.Table_To_Read(Damage_Rectangle), pixels: ^system.Bytes_To_Change, shape: ^Canvas_Shape, error: ^errors.Error_Record) -> i64 {
	// One copy of the shape and of each count: the caller can change them
	// during the call, and a value that is checked is the value that is
	// used.
	canvas_shape := intrinsics.volatile_load(shape)
	pixel_bytes := intrinsics.volatile_load(&pixels.count)
	pixel_address := intrinsics.volatile_load(&pixels.bytes)
	rectangle_count := intrinsics.volatile_load(&rectangles.count)
	if canvas_shape.width <= 0 || canvas_shape.height <= 0 || canvas_shape.stride < canvas_shape.width {
		return errors.fail(error, -1, .Bad_Value, .None, ARGUMENT_SHAPE, canvas_shape.width <= 0 ? canvas_shape.width : canvas_shape.height <= 0 ? canvas_shape.height : canvas_shape.stride)
	}
	// No product wraps, also for a stride near 2^62 that a hostile caller
	// gives: the stride is compared with the pixels of one line that the
	// bytes hold.
	if u64(canvas_shape.stride) > pixel_bytes / 4 / u64(canvas_shape.height) {
		return errors.fail(error, -1, .Too_Small, .Bytes, ARGUMENT_PIXELS, i64(min(pixel_bytes, u64(max(i64)))))
	}
	if uintptr(pixel_address) % align_of(graphics.Color) != 0 {
		return errors.fail(error, -1, .Bad_Address, .Bytes, ARGUMENT_PIXELS, i64(uintptr(pixel_address)), i64(min(pixel_bytes, u64(max(i64)))), 1)
	}
	if rectangle_count > TABLE_LIMIT {
		return errors.fail(error, -1, .Too_Long, .Records, ARGUMENT_RECTANGLES, i64(min(rectangle_count, u64(max(i64)))), i64(TABLE_LIMIT))
	}
	table, table_ok := draw_table_of(now, now_text, ARGUMENT_NOW, ARGUMENT_NOW_TEXT, error)
	if !table_ok {
		return -1
	}
	program_text_load()
	if program_text.interface_font_given {
		table.interface_font = &program_text.interface_font
	}
	canvas := graphics.Canvas{pixels = ([^]graphics.Color)(pixel_address), width = int(canvas_shape.width), height = int(canvas_shape.height), stride = int(canvas_shape.stride)}
	surface := interface.Rectangle{0, 0, canvas.width, canvas.height}
	for index in 0 ..< rectangle_count {
		record := intrinsics.volatile_load(&rectangles.records[index])
		rectangle := interface.Rectangle{int(record.left), int(record.top), int(record.right), int(record.bottom)}
		if canvas_shape.fill_background != 0 {
			area := interface.intersection(rectangle, surface)
			if !interface.empty(area) {
				graphics.fill(canvas, area.left, area.top, area.right - area.left, area.bottom - area.top, graphics.Color(canvas_shape.background))
			}
		}
		interface.execute_in_rectangle(&table, canvas, rectangle)
	}
	return i64(rectangle_count)
}
