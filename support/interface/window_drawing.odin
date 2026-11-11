package interface

import "support:display"
import "support:system"

// What a program keeps to draw its window with the package, in its own
// memory: the table of the frame that it builds, the table of the frame on
// its surface, the interface state and the input of the next frame.
Window_Drawing :: struct {
	now:    Draw_Table,
	before: Draw_Table, // What the surface shows. Empty before the first frame.
	state:  Interface_State,
	input:  Input,
	drawn:  bool, // The surface shows the table before.
	// The measures of the last frame, in nanoseconds.
	build_time, difference_time, draw_time: u64,
	damage: Damage,
}

// window_drawing_of makes the drawing of a window with tables in the
// memory of the caller.
window_drawing_of :: proc "contextless" (records_now, records_before: []Draw_Record, text_now, text_before: []u8) -> Window_Drawing {
	return {now = {records = records_now, text = text_now}, before = {records = records_before, text = text_before}}
}

// window_events takes the events of a window into the input of the next
// frame. It gives true if an event came.
window_events :: proc "contextless" (drawing: ^Window_Drawing, window: ^display.Window) -> bool {
	came := false
	for event in display.next_event(window) {
		input_add(&drawing.input, event)
		came = true
	}
	return came
}

// window_frame_begin starts a frame of the window.
window_frame_begin :: proc "contextless" (drawing: ^Window_Drawing) -> Frame {
	drawing.build_time = system.nanoseconds()
	return frame_begin(&drawing.now, &drawing.state, &drawing.input)
}

// window_frame_end ends the frame: it finds the damage by difference with
// the frame on the surface, draws the records again in the damage
// rectangles, and presents only that part. A surface with two pictures is
// drawn whole: its other picture shows an older frame. It gives the count
// of damage rectangles.
window_frame_end :: proc "contextless" (drawing: ^Window_Drawing, frame: ^Frame, window: ^display.Window) -> int {
	frame_end(frame)
	input_clear(&drawing.input)
	start := system.nanoseconds()
	drawing.build_time = start - drawing.build_time
	drawing.damage = {}
	whole := !drawing.drawn || window.two || drawing.before.full
	if !whole {
		damage_by_difference(&drawing.before, &drawing.now, &drawing.damage)
	}
	measured := system.nanoseconds()
	drawing.difference_time = measured - start
	switch {
	case whole:
		execute(&drawing.now, window.canvas)
		display.present(window)
		drawing.damage.rectangles[0] = {0, 0, window.canvas.width, window.canvas.height}
		drawing.damage.count = 1
	case drawing.damage.count > 0:
		execute_in_rectangles(&drawing.now, window.canvas, drawing.damage.rectangles[:drawing.damage.count])
		bounds := damage_bounds(&drawing.damage)
		display.present_rectangle(window, bounds.left, bounds.top, bounds.right - bounds.left, bounds.bottom - bounds.top)
	}
	drawing.draw_time = system.nanoseconds() - measured
	drawing.drawn = draw_table_copy(&drawing.before, &drawing.now)
	return drawing.damage.count
}
