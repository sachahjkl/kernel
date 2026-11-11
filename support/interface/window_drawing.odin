package interface

import "support:display"
import "support:graphics"
import "support:system"

// What a program keeps to draw its window with the package, in its own
// memory: the table of the frame that it builds, the table of the frame on
// its surface, the interface state and the input of the next frame.
Window_Drawing :: struct {
	now:    Draw_Table,
	before: Draw_Table, // What the surface shows (its first picture). Empty before the first frame.
	// A surface with two pictures: the table of its second picture. The
	// program draws in one picture while the compositor shows the other, so
	// each picture shows its own older frame.
	before_second: Draw_Table,
	drawn_second:  bool,
	state:  Interface_State,
	input:  Input,
	drawn:  bool, // The surface shows the table before.
	// The measures of the last frame, in nanoseconds.
	build_time, difference_time, draw_time: u64,
	build_start: u64, // When the frame that is built now started.
	damage: Damage,
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
		// The next frame draws the whole window.
		if event.kind == .Settings_Changed {
			drawing.drawn = false
		}
	}
	return came
}

// window_frame_begin starts a frame of the window.
window_frame_begin :: proc "contextless" (drawing: ^Window_Drawing, window: ^display.Window = nil) -> Frame {
	drawing.build_start = system.nanoseconds()
	if window != nil {
		display.picture_begin(window)
	}
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
	if !whole {
		damage_by_difference(before, &drawing.now, &drawing.damage)
	}
	measured := system.nanoseconds()
	drawing.difference_time = measured - start
	switch {
	case whole:
		graphics.clear(window.canvas, graphics.COLOR_BACKGROUND)
		execute(&drawing.now, window.canvas)
		display.present(window)
		drawing.damage.rectangles[0] = {0, 0, window.canvas.width, window.canvas.height}
		drawing.damage.count = 1
	case drawing.damage.count > 0:
		draw_damage_on_surface(&drawing.now, window.canvas, drawing.damage.rectangles[:drawing.damage.count])
		bounds := damage_bounds(&drawing.damage)
		display.present_rectangle(window, bounds.left, bounds.top, bounds.right - bounds.left, bounds.bottom - bounds.top)
	case:
		display.picture_end(window) // A frame with nothing to draw is a picture of the measure too.
	}
	drawing.draw_time = system.nanoseconds() - measured
	copied := draw_table_copy(before, &drawing.now)
	if second {
		drawing.drawn_second = copied
	} else {
		drawing.drawn = copied
	}
	return drawing.damage.count
}
