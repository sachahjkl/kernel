package interface

import "contract:errors"
import "support:display"
import "support:graphics"
import "support:system"

// A program built with this setting draws its window through the drawing
// module (docs/INTERFACE.md, section 7): window_frame_end calls the two
// exports of the module in place of the difference and the execution of
// this package, so the program holds no copy of that code. The kernel tool
// sets it for each program that imports the module (the module table,
// tools/kerneltool/modules.odin).
//
// Such a program has no Picture record and no Text_Grid record: a picture
// and a grid are named by an address, and the description of an export
// carries values only. A frame with one is refused (frame_draw).
DRAWING_THROUGH_MODULE :: #config(DRAWING_THROUGH_MODULE, false)

// What a program keeps to draw its window with the package, in its own
// memory: the table of the frame that it builds, the table of the frame on
// its surface, the interface state and the input of the next frame.
Window_Drawing :: struct {
	now:    Draw_Table, // The table of the frame that the program builds.
	before: Draw_Table, // What the surface shows (its first picture). Empty before the first frame.
	// A surface with two pictures: the table of its second picture. The
	// program draws in one picture while the compositor shows the other, so
	// each picture shows its own older frame.
	before_second: Draw_Table,
	drawn_second:  bool, // The second picture shows `before_second`.
	state:  Interface_State, // The focus and the element under the pointer, from frame to frame.
	input:  Input, // The input of the next frame.
	drawn:  bool, // The surface shows the table before.
	// The measures of the last frame, in nanoseconds.
	build_time, difference_time, draw_time: u64,
	build_start: u64, // When the frame that is built now started.
	damage: Damage, // The damage of the last frame.
	// A program that draws through the drawing module: the calls of an
	// export of the module since the start (two for a frame with damage on
	// a surface with one picture), and the error record of the last call
	// that the module refused, which the one line of the log of a refusal
	// reads (module_refusal_log). A program with the package compiled in
	// keeps the three zero.
	module_calls: u64,
	module_error: errors.Error_Record,
	module_refusal_logged: bool, // The line of a refusal is on the log: a window writes it one time.
}

// A rectangle as the drawing module describes it: the fields of Rectangle,
// each an integer of 64 bits. The two have one layout, so the rectangles
// of a Damage are the records of the table, with no copy. The two records
// of the border are declared for each build, at the top of the file: the
// kernel tool reads them there when it compares the declarations below
// with the descriptions of the exports.
Module_Rectangle :: struct {
	left, top, right, bottom: i64,
}
#assert(size_of(Module_Rectangle) == size_of(Rectangle))

// The shape of the canvas and the fill of each rectangle, as the drawing
// module describes them.
Module_Canvas_Shape :: struct {
	width:           i64, // Pixels of a line that belong to the canvas.
	height:          i64, // Lines.
	stride:          i64, // Pixels from one line to the next.
	fill_background: i64, // Not 0: each rectangle is painted with `background` first.
	background:      i64, // The color of that fill.
}

when DRAWING_THROUGH_MODULE {
	// The names of the exports hold the version of the draw record: a
	// module with another version has other names, so the loader refuses
	// it in place of a draw of records that it reads wrong. A new version
	// stops the build here, until the names follow.
	#assert(DRAW_RECORD_VERSION == 7)

	foreign _ {
		@(link_name = "damage_of_draw_table_7")
		module_damage_of_draw_table :: proc "c" (before: ^system.Table_To_Read(Draw_Record), before_text: ^system.Bytes_To_Read, now: ^system.Table_To_Read(Draw_Record), now_text: ^system.Bytes_To_Read, result: ^[]Module_Rectangle, error: ^errors.Error_Record) -> i64 ---
		@(link_name = "execute_draw_table_7")
		module_execute_draw_table :: proc "c" (now: ^system.Table_To_Read(Draw_Record), now_text: ^system.Bytes_To_Read, rectangles: ^system.Table_To_Read(Module_Rectangle), pixels: ^system.Bytes_To_Change, shape: ^Module_Canvas_Shape, error: ^errors.Error_Record) -> i64 ---
	}

	// records_to_read and text_to_read give the table places of a draw
	// table: the address of the memory of the program, and its counts. The
	// module reads the records where they are.
	@(private = "file")
	records_to_read :: proc "contextless" (table: ^Draw_Table) -> system.Table_To_Read(Draw_Record) {
		return {records = raw_data(table.records), count = u64(table.record_count), capacity = u64(len(table.records))}
	}

	@(private = "file")
	text_to_read :: proc "contextless" (table: ^Draw_Table) -> system.Bytes_To_Read {
		return {bytes = raw_data(table.text), count = u64(table.text_count), capacity = u64(len(table.text))}
	}

	// frame_difference finds the damage from the table before to the table
	// now, with the export of the drawing module. The module writes the
	// rectangles into the memory of damage. It gives false when the module
	// refused the call: drawing.module_error has the record, and damage is
	// empty.
	@(private = "file")
	frame_difference :: proc "contextless" (drawing: ^Window_Drawing, before, now: ^Draw_Table, damage: ^Damage) -> bool {
		before_records, before_text := records_to_read(before), text_to_read(before)
		now_records, now_text := records_to_read(now), text_to_read(now)
		result := ([^]Module_Rectangle)(&damage.rectangles[0])[:DAMAGE_CAPACITY]
		drawing.module_calls += 1
		count := module_damage_of_draw_table(&before_records, &before_text, &now_records, &now_text, &result, &drawing.module_error)
		if count < 0 {
			damage.count = 0
			module_refusal_log(drawing, "damage_of_draw_table_7")
			return false
		}
		damage.count = int(min(count, DAMAGE_CAPACITY))
		return true
	}

	// frame_draw paints each rectangle with the background and draws the
	// records that touch it, with the export of the drawing module: the
	// pixels of the canvas are bytes of the program that the module writes
	// in place. It gives false when the module refused the call, or when
	// the table has a picture or a grid, which the module cannot draw:
	// drawing.module_error has the record.
	@(private = "file")
	frame_draw :: proc "contextless" (drawing: ^Window_Drawing, now: ^Draw_Table, canvas: graphics.Canvas, rectangles: []Rectangle) -> bool {
		if len(now.pictures) != 0 || len(now.grids) != 0 {
			drawing.module_error = errors.error_make(.Unsupported, .None, 1, i64(len(now.pictures)) + i64(len(now.grids)))
			module_refusal_log(drawing, "execute_draw_table_7")
			return false
		}
		now_records, now_text := records_to_read(now), text_to_read(now)
		places := system.Table_To_Read(Module_Rectangle){records = ([^]Module_Rectangle)(raw_data(rectangles)), count = u64(len(rectangles)), capacity = u64(len(rectangles))}
		size := u64(canvas.stride) * u64(canvas.height) * size_of(graphics.Color)
		pixels := system.Bytes_To_Change{bytes = ([^]u8)(canvas.pixels), count = size, capacity = size}
		shape := Module_Canvas_Shape{width = i64(canvas.width), height = i64(canvas.height), stride = i64(canvas.stride), fill_background = 1, background = i64(graphics.COLOR_BACKGROUND)}
		drawing.module_calls += 1
		if module_execute_draw_table(&now_records, &now_text, &places, &pixels, &shape, &drawing.module_error) < 0 {
			module_refusal_log(drawing, "execute_draw_table_7")
			return false
		}
		return true
	}

	// module_refusal_log writes the one line of a window whose draw or
	// difference the drawing module refused: the export, and the error
	// record in words. A refused draw presents nothing and makes the next
	// frame whole, which is refused again: with no line, the window stays
	// empty and the log says nothing. One line for the life of the window:
	// the cause is in the program (a table, a shape, a picture), and each
	// frame has the same one.
	@(private = "file")
	module_refusal_log :: proc "contextless" (drawing: ^Window_Drawing, export_name: string) {
		if drawing.module_refusal_logged {
			return
		}
		drawing.module_refusal_logged = true
		record := drawing.module_error
		cause := "the module gave an error kind that this line has no words for"
		#partial switch errors.Kind(record.kind) {
		case .Too_Long:
			cause = "a table has more records or bytes than the module takes"
		case .Bad_Value:
			cause = "the shape of the canvas has a width, a height or a stride that the module refuses"
		case .Too_Small:
			cause = "the pixels do not hold the shape of the canvas"
		case .Bad_Address:
			cause = "the address of the pixels is not a multiple of 4"
		case .Unsupported:
			cause = "the frame has a picture or a grid of text cells, which the module does not draw: this program must keep the interface package compiled in"
		}
		system.log_in("programs", .Warning, "interface: the drawing module refused ", export_name, ": ", cause, " (the error kind ", u64(max(record.kind, 0)), ", the argument ", u64(max(record.argument, 0)), "). A refused difference draws each frame whole; a refused draw leaves the window as it was. A window writes this line one time")
	}
} else {
	// frame_difference finds the damage from the table before to the table
	// now, with the package. It never fails.
	@(private = "file")
	frame_difference :: proc "contextless" (drawing: ^Window_Drawing, before, now: ^Draw_Table, damage: ^Damage) -> bool {
		damage_by_difference(before, now, damage)
		return true
	}

	// frame_draw paints each rectangle with the background and draws the
	// records that touch it, with the package. It never fails.
	@(private = "file")
	frame_draw :: proc "contextless" (drawing: ^Window_Drawing, now: ^Draw_Table, canvas: graphics.Canvas, rectangles: []Rectangle) -> bool {
		draw_damage_on_surface(now, canvas, rectangles)
		return true
	}
}

// window_drawing_of makes the drawing of a window with tables in the
// memory of the caller.
window_drawing_of :: proc "contextless" (records_now, records_before: []Draw_Record, text_now, text_before: []u8, records_second: []Draw_Record = nil, text_second: []u8 = nil) -> Window_Drawing {
	return {now = {records = records_now, text = text_now}, before = {records = records_before, text = text_before}, before_second = {records = records_second, text = text_second}}
}

// window_events takes the events of a window into the input of the next
// frame, until the input has KEY_CAPACITY keys. It gives true if an event
// came.
window_events :: proc "contextless" (drawing: ^Window_Drawing, window: ^display.Window) -> bool {
	came := false
	// A full input stops the reading: the other events wait in the ring.
	for input_has_room(&drawing.input) {
		event := display.next_event(window) or_break
		input_add(&drawing.input, event)
		came = true
		// A new font: each record is the same, each pixel of text is not.
		// The next frame of each picture draws the whole window.
		if event.kind == .Settings_Changed {
			draw_whole_window_next(drawing)
		}
	}
	return came
}

// draw_whole_window_next makes the next frame of each picture of the
// surface a whole frame: no table before is trusted. A program that reads
// its events with no window_events calls it on Settings_Changed.
draw_whole_window_next :: proc "contextless" (drawing: ^Window_Drawing) {
	drawing.drawn = false
	drawing.drawn_second = false
}

// window_frame_begin starts a frame of the window.
window_frame_begin :: proc "contextless" (drawing: ^Window_Drawing, window: ^display.Window = nil) -> Frame {
	drawing.build_start = system.nanoseconds()
	if window != nil {
		display.picture_begin(window)
	}
	// The elements of a window draw their names and titles in the
	// interface font of the program, when its starter gave it one.
	drawing.now.interface_font = display.interface_font_of()
	return frame_begin(&drawing.now, &drawing.state, &drawing.input, system.time())
}

// window_scroll_bar_wake gives the time, in milliseconds of the clock of
// the system, at which a held arrow button of a scroll bar of the window
// takes its next step: a program that sleeps while nothing changes wakes at
// that time and builds a frame. due is false when no step is due.
window_scroll_bar_wake :: proc "contextless" (drawing: ^Window_Drawing) -> (time: u64, due: bool) {
	return drawing.state.scroll_bar_repeat_at, drawing.state.scroll_bar_repeat_at != 0
}

// window_frame_end ends the frame: it finds the damage by difference with
// the frame on the surface, draws the records again in the damage
// rectangles, and presents only that part. A surface with two pictures
// compares with the table of the picture that the program draws now, and
// is drawn whole when the caller gave no memory for that second table. It
// gives the count of damage rectangles.
//
// The difference and the draw are the package compiled in, or the two
// exports of the drawing module (DRAWING_THROUGH_MODULE): the same code
// behind a border, crossed one time for the difference and one time for
// the draw of a frame, and one time more for the difference of a surface
// with two pictures. A whole frame and a frame with damage draw the same
// way: each rectangle is painted with the background, then the records
// that touch it are drawn.
window_frame_end :: proc "contextless" (drawing: ^Window_Drawing, frame: ^Frame, window: ^display.Window) -> int {
	frame_end(frame)
	input_clear(&drawing.input)
	start := system.nanoseconds()
	drawing.build_time = start - drawing.build_start
	drawing.damage = {}
	second := window.two && window.picture == 1
	before := second ? &drawing.before_second : &drawing.before
	drawn := second ? drawing.drawn_second : drawing.drawn
	whole := !drawn || before.full || window.two && drawing.before_second.records == nil
	surface := Rectangle{0, 0, window.canvas.width, window.canvas.height}
	// present: with two pictures, the screen shows the other one; its
	// difference with now must reach the screen too.
	present: Damage
	if !whole {
		// A difference that the drawing module refused: the frame is
		// drawn whole.
		whole = !frame_difference(drawing, before, &drawing.now, &drawing.damage)
		present = drawing.damage
		if !whole && window.two {
			shown := second ? &drawing.before : &drawing.before_second
			shown_drawn := (second ? drawing.drawn : drawing.drawn_second) && !shown.full
			shown_damage: Damage
			if shown_drawn {
				shown_drawn = frame_difference(drawing, shown, &drawing.now, &shown_damage)
			}
			damage_to_present(&drawing.damage, &shown_damage, shown_drawn, surface, &present)
		}
	}
	measured := system.nanoseconds()
	drawing.difference_time = measured - start
	// sent: the compositor has the present. When the command ring is full,
	// the present is lost: with one picture the screen keeps the old pixels
	// of that rectangle, and the next difference would see no change. So a
	// lost present makes the next frame of this picture whole. A draw that
	// the drawing module refused presents nothing, and does the same.
	sent := true
	switch {
	case whole:
		whole_surface := [1]Rectangle{surface}
		sent = frame_draw(drawing, &drawing.now, window.canvas, whole_surface[:])
		if sent {
			sent = display.present(window)
		} else {
			display.picture_end(window)
		}
		drawing.damage.rectangles[0] = surface
		drawing.damage.count = 1
	case present.count > 0:
		// With two pictures, the picture that the program draws can be
		// equal to the frame while the screen is not: nothing to draw.
		sent = drawing.damage.count == 0 || frame_draw(drawing, &drawing.now, window.canvas, drawing.damage.rectangles[:drawing.damage.count])
		if sent {
			bounds := intersection(damage_bounds(&present), surface)
			sent = display.present_rectangle(window, bounds.left, bounds.top, max(bounds.right - bounds.left, 0), max(bounds.bottom - bounds.top, 0))
		} else {
			display.picture_end(window)
		}
	case:
		display.picture_end(window) // A frame with nothing to draw is a picture of the measure too.
	}
	drawing.draw_time = system.nanoseconds() - measured
	copied := sent && draw_table_copy(before, &drawing.now)
	if second {
		drawing.drawn_second = copied
	} else {
		drawing.drawn = copied
	}
	return drawing.damage.count
}

// show_picture draws a frame of a window that is one picture of the program
// (drawing.now.pictures[0]): one Picture record at (0, 0). generation is a
// new number when the pixels of the picture changed: with the same number,
// the frame draws nothing.
show_picture :: proc "contextless" (drawing: ^Window_Drawing, window: ^display.Window, generation: u32) {
	frame := window_frame_begin(drawing, window)
	draw_picture(frame.table, 0, 0, 0, generation)
	window_frame_end(drawing, &frame, window)
}

// window_drawing_of_picture makes the drawing of a window that is one
// picture of the program, with tables in the memory of the caller.
window_drawing_of_picture :: proc "contextless" (records_now, records_before: []Draw_Record, pictures: []graphics.Canvas) -> Window_Drawing {
	drawing := Window_Drawing{now = {records = records_now}, before = {records = records_before}}
	drawing.now.pictures = pictures
	drawing.before.pictures = pictures
	return drawing
}
