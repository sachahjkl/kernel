// The elements of the interface package, live (docs/INTERFACE.md).
//
// The window shows each element of the package: a button, a list with a
// choice, a text input, bars, lines of a label and a value, a table, the
// large number of a card. A second card shows the draw table of the last
// frame: its records, its bytes of text, its damage rectangles and the time
// of each part. A button shows the damage rectangles of each frame over the
// window, as records of the next frame.
//
// At its start the program measures the damage by difference on its own
// window: a frame where nothing changed, a frame where one number changed,
// a frame where everything moved, and the whole frame drawn with no
// comparison. The log has the numbers.
package interface_elements

import "support:display"
import "support:graphics"
import "support:interface"
import "support:system"

WIDTH :: 816
HEIGHT :: 560
TICK :: 100 // Milliseconds between two frames.

records_now, records_before: [512]interface.Draw_Record
text_now, text_before: [8192]u8
drawing: interface.Window_Drawing

// What the window shows: the state of the program.
presses: u64
names := [?]string{"boot", "clock", "remote", "scheduler", "launcher", "compositor"}
choice: int
typed: [32]u8
typed_count: int
show_damage: bool
frames: u64
moved: bool // The measure of a frame where everything moved.
last_damage: interface.Damage

Part :: struct {
	text:  string,
	color: graphics.Color,
}

// build describes the whole window for one frame.
build :: proc "contextless" (frame: ^interface.Frame, number: u64) {
	builder: interface.Text_Builder
	offset := moved ? 8 : 0
	interface.background(frame, {0, 0, WIDTH, HEIGHT})

	// The elements.
	content := interface.card(frame, {8 + offset, 8, 456, HEIGHT - 16}, "ELEMENTS", "support/interface", graphics.COLOR_KERNEL, "Tab, Enter, arrows")
	column := interface.column_of(content, 8)
	pressed := interface.button(frame, interface.column_take(&column, 24), interface.identity("press"), "press this button")
	if pressed.activated {
		presses += 1
		system.log("interface_elements: the button was pressed ", presses, " times")
	}
	interface.label_value_line(frame, interface.column_take(&column, 16), "presses", interface.number_text(&builder, presses))
	interface.cell_text(frame, interface.column_take(&column, 16), "a list with a choice", graphics.COLOR_DIM)
	listed := interface.list_with_choice(frame, interface.column_take(&column, 3 * interface.TABLE_LINE), interface.identity("list"), names[:], &choice, {chosen_hint = "enter: start"})
	if listed.changed {
		system.log("interface_elements: the list chooses ", names[choice])
	}
	interface.cell_text(frame, interface.column_take(&column, 16), "a text input", graphics.COLOR_DIM)
	typed_result := interface.text_input(frame, interface.column_take(&column, 24), interface.identity("text"), typed[:], &typed_count, "type a text")
	if typed_result.changed {
		system.log("interface_elements: the text is \"", string(typed[:typed_count]), "\"")
	}
	interface.cell_text(frame, interface.column_take(&column, 16), "bars: a value against a maximum, parts of one total", graphics.COLOR_DIM)
	interface.bar(frame, interface.column_take(&column, 8), number % 100, 100, graphics.COLOR_PROGRAM)
	parts := [3]u64{number % 50 + 10, 20, 15}
	colors := [3]graphics.Color{graphics.COLOR_KERNEL, graphics.COLOR_MEMORY, graphics.COLOR_FAILED}
	interface.bar_parts(frame, interface.column_take(&column, 8), parts[:], colors[:], 100)
	interface.cell_text(frame, interface.column_take(&column, 16), "a table", graphics.COLOR_DIM)
	cells: [3]interface.Area
	sizes := [3]interface.Size{interface.share(), interface.characters(10), interface.characters(10)}
	interface.row_split(interface.column_take(&column, 24), sizes[:], cells[:], 16)
	interface.table_header(frame, cells[:], {"element", "records", "bytes"}, {.Left, .Right, .Right})
	Line :: struct {
		name:          string,
		records, size: u64,
	}
	lines := [?]Line{{"card", 5, 0}, {"bar", 2, 0}, {"button", 2, 0}}
	for line, index in lines {
		area := interface.column_take(&column, 24)
		interface.table_band(frame, area, index)
		interface.row_split({area.x + 8, area.y, area.width - 16, area.height}, sizes[:], cells[:], 16)
		interface.cell_text(frame, cells[0], line.name, graphics.COLOR_TEXT)
		interface.cell_text(frame, cells[1], interface.number_text(&builder, line.records), graphics.COLOR_TEXT, .Right)
		interface.cell_text(frame, cells[2], interface.number_text(&builder, line.records * size_of(interface.Draw_Record)), graphics.COLOR_TEXT, .Right)
	}

	// The draw table of the last frame.
	content = interface.card(frame, {472 + offset, 8, WIDTH - 480, HEIGHT - 16}, "THE FRAME", "Draw_Table, Damage", graphics.COLOR_MACHINE)
	column = interface.column_of(content, 8)
	interface.large_number(frame, content.x, interface.column_take(&column, 48).y, interface.number_text(&builder, number), graphics.COLOR_MACHINE)
	interface.cell_text(frame, interface.column_take(&column, 16), "frames", graphics.COLOR_DIM)
	facts := [?]struct {
		name:  string,
		value: u64,
		unit:  string,
	} {
		{"records", u64(drawing.before.record_count), ""},
		{"bytes of text", u64(drawing.before.text_count), " B"},
		{"damage rectangles", u64(last_damage.count), ""},
		{"build", drawing.build_time / 1000, " us"},
		{"difference", drawing.difference_time / 1000, " us"},
		{"draw", drawing.draw_time / 1000, " us"},
	}
	for fact in facts {
		value: interface.Text_Builder
		interface.text_put_number(&value, fact.value)
		interface.text_put(&value, fact.unit)
		interface.label_value_line(frame, interface.column_take(&column, 16), fact.name, interface.text_of(&value))
	}
	interface.column_take(&column, 8)
	overlay := interface.button(frame, interface.column_take(&column, 24), interface.identity("damage"), show_damage ? "hide the damage" : "show the damage", show_damage)
	if overlay.activated {
		show_damage = !show_damage
		system.log("interface_elements: the damage is ", show_damage ? "shown" : "hidden")
	}
	interface.cell_text(frame, interface.column_take(&column, 16), "a frame draws only its damage", graphics.COLOR_DIM)
	// The damage of the last frame, as outlines of 2 pixels over the window.
	// They are records: when the damage stays the same, they do not damage.
	if show_damage {
		for rectangle in last_damage.rectangles[:last_damage.count] {
			width, height := rectangle.right - rectangle.left, rectangle.bottom - rectangle.top
			interface.draw_rectangle(frame.table, rectangle.left, rectangle.top, width, 2, graphics.COLOR_MACHINE)
			interface.draw_rectangle(frame.table, rectangle.left, rectangle.bottom - 2, width, 2, graphics.COLOR_MACHINE)
			interface.draw_rectangle(frame.table, rectangle.left, rectangle.top, 2, height, graphics.COLOR_MACHINE)
			interface.draw_rectangle(frame.table, rectangle.right - 2, rectangle.top, 2, height, graphics.COLOR_MACHINE)
		}
	}
}

// frame_draw builds and draws one frame.
frame_draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_begin(&drawing)
	build(&frame, frames)
	interface.window_frame_end(&drawing, &frame, window)
	last_damage = drawing.damage
	frames += 1
}

// measure builds the window and compares it with the frame before, in one
// case: nothing changed, one number changed, or everything moved.
measure :: proc "contextless" (name: string, number_before, number_now: u64, move: bool) {
	ROUNDS :: 100
	before := interface.Draw_Table{records = records_before[:], text = text_before[:]}
	now := interface.Draw_Table{records = records_now[:], text = text_now[:]}
	state: interface.Interface_State
	input: interface.Input
	difference, rectangles: u64
	damage: interface.Damage
	for _ in 0 ..< ROUNDS {
		moved = false
		frame := interface.frame_begin(&before, &state, &input)
		build(&frame, number_before)
		interface.frame_end(&frame)
		moved = move
		frame = interface.frame_begin(&now, &state, &input)
		build(&frame, number_now)
		interface.frame_end(&frame)
		damage = {}
		start := system.nanoseconds()
		interface.damage_by_difference(&before, &now, &damage)
		difference += system.nanoseconds() - start
		rectangles = u64(damage.count)
	}
	moved = false
	bounds := interface.damage_bounds(&damage)
	area := u64(max(bounds.right - bounds.left, 0) * max(bounds.bottom - bounds.top, 0))
	system.log("interface_elements: ", name, ": ", u64(now.record_count), " records, ", rectangles, " damage rectangles, ", area * 100 / (WIDTH * HEIGHT), " % of the window, the difference in ", difference / ROUNDS / 100 / 10, ".", difference / ROUNDS / 100 % 10, " us")
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "interface_elements")
	if !ok {
		system.stop(1)
	}
	measure("nothing changed", 7, 7, false)
	measure("one number changed", 7, 8, false)
	measure("everything moved", 7, 7, true)
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	// The whole frame, drawn with no comparison, then a frame where only
	// the counters changed, drawn in its damage.
	frame_draw(&window)
	whole := drawing.draw_time
	frame_draw(&window)
	system.log("interface_elements: ok, the whole frame drawn in ", whole / 1000, " us; the next frame drawn in its ", u64(drawing.damage.count), " damage rectangles in ", drawing.draw_time / 1000, " us")
	deadline := system.time()
	for {
		deadline += TICK
		display.wait(&window, deadline)
		interface.window_events(&drawing, &window)
		frame_draw(&window)
	}
}
