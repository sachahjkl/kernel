package interface

import "support:display"
import "support:graphics"
import "support:system"

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
	return frame_begin(&drawing.now, &drawing.state, &drawing.input)
}

// window_frame_end ends the frame: it finds the damage by difference with
// the frame on the surface, draws the records again in the damage
// rectangles, and presents only that part. A surface with two pictures
// compares with the table of the picture that the program draws now, and
// is drawn whole when the caller gave no memory for that second table. It
// gives the count of damage rectangles.
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
	// present: with two pictures, the screen shows the other one; its
	// difference with now must reach the screen too.
	present: Damage
	if !whole {
		if window.two {
			shown := second ? &drawing.before : &drawing.before_second
			shown_drawn := second ? drawing.drawn : drawing.drawn_second
			damage_of_two_pictures(before, shown, shown_drawn && !shown.full, &drawing.now, {0, 0, window.canvas.width, window.canvas.height}, &drawing.damage, &present)
		} else {
			damage_by_difference(before, &drawing.now, &drawing.damage)
			present = drawing.damage
		}
	}
	measured := system.nanoseconds()
	drawing.difference_time = measured - start
	// sent: the compositor has the present. When the command ring is full,
	// the present is lost: with one picture the screen keeps the old pixels
	// of that rectangle, and the next difference would see no change. So a
	// lost present makes the next frame of this picture whole.
	sent := true
	switch {
	case whole:
		graphics.clear(window.canvas, graphics.COLOR_BACKGROUND)
		execute(&drawing.now, window.canvas)
		sent = display.present(window)
		drawing.damage.rectangles[0] = {0, 0, window.canvas.width, window.canvas.height}
		drawing.damage.count = 1
	case present.count > 0:
		draw_damage_on_surface(&drawing.now, window.canvas, drawing.damage.rectangles[:drawing.damage.count])
		bounds := intersection(damage_bounds(&present), {0, 0, window.canvas.width, window.canvas.height})
		sent = display.present_rectangle(window, bounds.left, bounds.top, max(bounds.right - bounds.left, 0), max(bounds.bottom - bounds.top, 0))
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
