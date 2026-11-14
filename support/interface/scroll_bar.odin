package interface

import "support:graphics"

// The scroll bar (docs/INTERFACE.md, "4.1 The scroll bar"): the one
// drawing of a scroll bar of the system. Its look is in the design rules
// (docs/DESIGN.md, "The scroll bar"). Its sizes and its colors are the
// table of support/graphics/scroll_bar.odin, which the site reads too. A program gives the range that it shows and
// takes the new first unit: the element holds the pointer on the arrow
// buttons, on the track and on the thumb.

SCROLL_BAR_THICKNESS :: graphics.SCROLL_BAR_THICKNESS // The width that a caller keeps for a vertical bar, and the height for a horizontal one.

// Which way a scroll bar goes.
Scroll_Bar_Direction :: enum u8 {
	Vertical, // From the top down. Its gradients go from the left to the right.
	Horizontal, // From the left to the right. Its gradients go from the top down.
}

// The parts of a scroll bar that the pointer can be on.
Scroll_Bar_Part :: enum u8 {
	None,
	Arrow_Back, // The arrow button at the start: up, or left.
	Arrow_Forward, // The arrow button at the end: down, or right.
	Track_Back, // The track before the thumb.
	Track_Forward, // The track after the thumb.
	Thumb,
}

// What a scroll bar shows, in units of the caller (lines, rows, pixels).
Scroll_Range :: struct {
	total:   int, // The units of the whole content.
	visible: int, // The units that the view shows.
	first:   int, // The first unit of the view: 0 to total - visible.
}

// How far a press moves the view.
Scroll_Bar_Steps :: struct {
	line: int, // A press on an arrow button. 0: one unit.
	page: int, // A press on the track. 0: the units that the view shows.
}

// The places of the parts of a scroll bar, in pixels along it from its start.
Scroll_Bar_Geometry :: struct {
	length:       int, // The bar, along.
	thickness:    int, // The bar, across.
	arrow_length: int, // Each arrow button, along. 0: the bar is too short for its buttons, and the track takes it whole.
	track_start:  int,
	track_length: int,
	thumb_start:  int,
	thumb_length: int,
	thumb_room:   int, // The pixels that the thumb can move: the track less the thumb.
	range:        int, // The units that the view can move: the total less the visible ones.
	first:        int, // The first unit, cut to 0 ..= range.
	grip:         bool, // The thumb is long enough for its grip.
}

// The state of a scroll bar that its drawing shows.
Scroll_Bar_Look :: struct {
	under_pointer: bool, // The pointer is over the bar.
	hot:           Scroll_Bar_Part, // The arrow button under the pointer, or None.
	pressed:       Scroll_Bar_Part, // The part that holds the press, or None.
}

// What the input did to a scroll bar in one frame.
Scroll_Bar_Result :: struct {
	first:         int, // The first unit of the view after the input.
	changed:       bool, // `first` is not the first unit that the caller gave.
	under_pointer: bool, // The pointer is over the bar.
	pressed_now:   Scroll_Bar_Part, // The part where the button went down in this frame, or None.
	held:          Scroll_Bar_Part, // The part that holds the press, or None.
	drag_ended:    bool, // The button went up in this frame after a drag of the thumb.
}

// The largest total of a range: past it, a product with a count of pixels
// could pass the integer.
SCROLL_RANGE_TOTAL_LIMIT :: 1 << 40

// The longest bar: a surface is far shorter.
SCROLL_BAR_LENGTH_LIMIT :: 1 << 20

// scroll_bar_geometry gives the places of the parts of a bar of a length
// and a thickness for a range. The thumb has the share of the track that
// the view has of the content, with a least length; a range that the view
// shows whole has a thumb as long as the track.
scroll_bar_geometry :: proc "contextless" (length, thickness: int, range: Scroll_Range) -> (geometry: Scroll_Bar_Geometry) {
	geometry.length = clamp(length, 0, SCROLL_BAR_LENGTH_LIMIT)
	geometry.thickness = clamp(thickness, 0, SCROLL_BAR_LENGTH_LIMIT)
	if geometry.length >= 2 * geometry.thickness + graphics.SCROLL_BAR_THUMB_LEAST {
		geometry.arrow_length = geometry.thickness
	}
	geometry.track_start = geometry.arrow_length
	geometry.track_length = geometry.length - 2 * geometry.arrow_length
	total := clamp(range.total, 1, SCROLL_RANGE_TOTAL_LIMIT)
	visible := clamp(range.visible, 0, total)
	track := geometry.track_length
	thumb := track * visible / total
	thumb = max(thumb, track * graphics.SCROLL_BAR_THUMB_LEAST_PERCENT / 100, graphics.SCROLL_BAR_THUMB_LEAST)
	thumb = min(thumb, track)
	geometry.thumb_length = thumb
	geometry.thumb_room = track - thumb
	geometry.range = total - visible
	geometry.first = clamp(range.first, 0, geometry.range)
	geometry.thumb_start = geometry.track_start
	if geometry.range > 0 {
		geometry.thumb_start += geometry.thumb_room * geometry.first / geometry.range
	}
	geometry.grip = thumb > graphics.SCROLL_BAR_GRIP_THUMB_LEAST
	return
}

// scroll_bar_part_at gives the part of a bar at a place along it.
scroll_bar_part_at :: proc "contextless" (geometry: Scroll_Bar_Geometry, along: int) -> Scroll_Bar_Part {
	switch {
	case along < 0 || along >= geometry.length:
		return .None
	case along < geometry.arrow_length:
		return .Arrow_Back
	case along >= geometry.length - geometry.arrow_length:
		return .Arrow_Forward
	case along < geometry.thumb_start:
		return .Track_Back
	case along >= geometry.thumb_start + geometry.thumb_length:
		return .Track_Forward
	}
	return .Thumb
}

// scroll_bar_first_at gives the first unit of the view for a thumb that
// starts at a place along the bar: the nearest unit, cut to the range.
scroll_bar_first_at :: proc "contextless" (geometry: Scroll_Bar_Geometry, thumb_start: int) -> int {
	if geometry.thumb_room <= 0 || geometry.range <= 0 {
		return 0
	}
	place := clamp(thumb_start - geometry.track_start, 0, geometry.thumb_room)
	return (place * geometry.range + geometry.thumb_room / 2) / geometry.thumb_room
}

// scroll_bar_along gives the place of a point along a bar, from its start.
@(private = "file")
scroll_bar_along :: proc "contextless" (area: Area, direction: Scroll_Bar_Direction, x, y: int) -> int {
	return direction == .Vertical ? y - area.y : x - area.x
}

// scroll_bar draws a scroll bar in an area and gives what the pointer did
// to it. A press on an arrow button moves the view by one line, and again
// while the button is held and the pointer stays on it, by the clock of the
// frame. A press on the track moves the view by one page toward the
// pointer. A press on the thumb holds it: the thumb follows the pointer
// until the button goes up, also when the pointer leaves the bar. The
// caller shows the range from result.first in its next frame.
//
// A scroll bar takes no key and is not in the order of Tab: the keys of
// the view belong to the element that owns the view.
scroll_bar :: proc "contextless" (frame: ^Frame, area: Area, element: Element_Identity, direction: Scroll_Bar_Direction, range: Scroll_Range, steps: Scroll_Bar_Steps = {}) -> (result: Scroll_Bar_Result) {
	state := frame.state
	input := frame.input
	vertical := direction == .Vertical
	length := vertical ? area.height : area.width
	thickness := vertical ? area.width : area.height
	geometry := scroll_bar_geometry(length, thickness, range)
	line_step := max(steps.line, 1)
	page_step := steps.page > 0 ? steps.page : max(range.visible, 1)
	first := geometry.first
	along := scroll_bar_along(area, direction, input.pointer_x, input.pointer_y)
	inside := input.pointer_known && area_contains(area, input.pointer_x, input.pointer_y)
	if inside {
		frame.under_pointer = element
	}
	// The press is at the place where the button went down: the pointer of
	// the frame can be past it already.
	if input.pressed && input.pointer_known && area_contains(area, input.press_x, input.press_y) {
		press_along := scroll_bar_along(area, direction, input.press_x, input.press_y)
		part := scroll_bar_part_at(geometry, press_along)
		state.pressed = element
		state.scroll_bar_part = part
		state.scroll_bar_grab = press_along - geometry.thumb_start
		state.scroll_bar_repeat_at = 0
		result.pressed_now = part
		#partial switch part {
		case .Arrow_Back:
			first -= line_step
		case .Arrow_Forward:
			first += line_step
		case .Track_Back:
			first -= page_step
		case .Track_Forward:
			first += page_step
		}
		if (part == .Arrow_Back || part == .Arrow_Forward) && frame.time != 0 {
			state.scroll_bar_repeat_at = frame.time + graphics.SCROLL_BAR_REPEAT_AFTER
		}
	}
	held := state.pressed == element ? state.scroll_bar_part : Scroll_Bar_Part.None
	if held != .None {
		frame.scroll_bar_held_drawn = true
		#partial switch held {
		case .Thumb:
			// A thumb that the pointer did not move keeps its unit: the
			// place of a thumb is coarser than the units of a long content.
			if wanted := along - state.scroll_bar_grab; wanted != geometry.thumb_start {
				first = scroll_bar_first_at(geometry, wanted)
			}
			result.drag_ended = input.released
		case .Arrow_Back, .Arrow_Forward:
			if result.pressed_now == .None && input.button_held {
				on_button := inside && scroll_bar_part_at(geometry, along) == held
				switch {
				case !on_button || frame.time == 0:
					state.scroll_bar_repeat_at = 0
				case state.scroll_bar_repeat_at == 0:
					// The pointer came back on the held button.
					state.scroll_bar_repeat_at = frame.time + graphics.SCROLL_BAR_REPEAT_EVERY
				case frame.time >= state.scroll_bar_repeat_at:
					first += held == .Arrow_Back ? -line_step : line_step
					state.scroll_bar_repeat_at = frame.time + graphics.SCROLL_BAR_REPEAT_EVERY
				}
			}
		}
	}
	first = clamp(first, 0, geometry.range)
	result.first = first
	result.changed = first != geometry.first
	result.under_pointer = inside
	result.held = held

	// The bar is drawn at the place that the input gave.
	shown := range
	shown.first = first
	drawn := scroll_bar_geometry(length, thickness, shown)
	look := Scroll_Bar_Look{under_pointer = inside, pressed = input.released ? Scroll_Bar_Part.None : held}
	if inside {
		under := scroll_bar_part_at(drawn, along)
		if (under == .Arrow_Back || under == .Arrow_Forward) && (look.pressed == .None || look.pressed == under) {
			look.hot = under
		}
	}
	if look.under_pointer || look.pressed == .Thumb {
		frame.scroll_bar_lit = element
	}
	scroll_bar_draw(frame.table, area, direction, drawn, look, nil, u32(element))
	return
}

// scroll_bar_wants_frame says if a program that draws only after a change
// must build a frame for the pointer: the pointer is over the bar, the
// button went down on it, the bar holds the press, or the last frame drew
// the bar lit and the pointer left it.
scroll_bar_wants_frame :: proc "contextless" (state: ^Interface_State, input: ^Input, area: Area, element: Element_Identity) -> bool {
	if state.pressed == element || state.scroll_bar_lit == element {
		return true
	}
	if !input.pointer_known {
		return false
	}
	return area_contains(area, input.pointer_x, input.pointer_y) || input.pressed && area_contains(area, input.press_x, input.press_y)
}

// scroll_bar_part_rectangle appends one rectangle of a bar, given along
// and across the bar.
@(private = "file")
scroll_bar_part_rectangle :: proc "contextless" (table: ^Draw_Table, area: Area, direction: Scroll_Bar_Direction, along, along_size, across, across_size: int, color: graphics.Color, element: u32) {
	if direction == .Vertical {
		draw_rectangle(table, area.x + across, area.y + along, across_size, along_size, color, element)
	} else {
		draw_rectangle(table, area.x + along, area.y + across, along_size, across_size, color, element)
	}
}

// scroll_bar_gradient_across appends a gradient of several stops across a
// box of a bar: one record for each pair of stops, from the place of the
// first to the place of the second. Two pairs share the pixels of their
// common stop, which both draw in its color.
@(private = "file")
scroll_bar_gradient_across :: proc "contextless" (table: ^Draw_Table, area: Area, direction: Scroll_Bar_Direction, along, along_size, across, across_size: int, colors: []graphics.Color, percents: []int, element: u32) {
	if along_size <= 0 || across_size <= 0 {
		return
	}
	for index in 0 ..< min(len(colors), len(percents)) - 1 {
		from := across + graphics.scroll_bar_stop_place(percents[index], across_size)
		to := across + graphics.scroll_bar_stop_place(percents[index + 1], across_size)
		size := to - from + 1
		if direction == .Vertical {
			draw_horizontal_gradient(table, area.x + from, area.y + along, size, along_size, colors[index], colors[index + 1], element)
		} else {
			draw_vertical_gradient(table, area.x + along, area.y + from, along_size, size, colors[index], colors[index + 1], element)
		}
	}
}

// scroll_bar_draw appends the records of a scroll bar: the track with its
// border, the two arrow buttons, the thumb with its border, its inner line
// and its grip. It takes no input: a bar that only shows a place (a list
// whose owner is another program) is drawn with an empty look. colors nil
// is the dark form, the form of each surface of the system.
scroll_bar_draw :: proc "contextless" (table: ^Draw_Table, area: Area, direction: Scroll_Bar_Direction, geometry: Scroll_Bar_Geometry, look: Scroll_Bar_Look = {}, colors: ^graphics.Scroll_Bar_Colors = nil, element: u32 = 0) {
	BORDER :: graphics.SCROLL_BAR_BORDER
	// A copy of the colors: the table is read-only data of the package.
	used := graphics.scroll_bar_colors_dark
	if colors != nil {
		used = colors^
	}
	inner := geometry.thickness - 2 * BORDER
	if geometry.length <= 2 * BORDER || inner <= 0 {
		return
	}
	lit := look.under_pointer || look.pressed == .Thumb

	// The track: its border, then its fill inside the border.
	scroll_bar_part_rectangle(table, area, direction, 0, geometry.length, 0, geometry.thickness, used.track_border, element)
	track_colors := used.track
	track_percents := graphics.SCROLL_BAR_TRACK_STOP_PERCENTS
	scroll_bar_gradient_across(table, area, direction, BORDER, geometry.length - 2 * BORDER, BORDER, inner, track_colors[:], track_percents[:], element)

	// The arrow buttons. At rest a button has no fill and no border: the
	// track shows under its triangle.
	if geometry.arrow_length > 0 {
		arrow_percents := [2]int{0, 100}
		for which in ([2]Scroll_Bar_Part{.Arrow_Back, .Arrow_Forward}) {
			start := which == .Arrow_Back ? 0 : geometry.length - geometry.arrow_length
			hot := look.hot == which
			pressed := look.pressed == which
			if pressed || hot || lit {
				fill_colors := used.arrow_lit
				border_color := used.lit_border
				switch {
				case pressed:
					fill_colors, border_color = used.arrow_pressed, used.hot_border
				case hot:
					fill_colors, border_color = used.arrow_hot, used.hot_border
				}
				scroll_bar_part_rectangle(table, area, direction, start, geometry.arrow_length, 0, geometry.thickness, border_color, element)
				scroll_bar_gradient_across(table, area, direction, start + BORDER, geometry.arrow_length - 2 * BORDER, BORDER, inner, fill_colors[:], arrow_percents[:], element)
			}
			// The triangle: its point toward the end of the bar that the
			// button scrolls to, on the middle line of the bar.
			triangle_color := pressed || hot ? used.triangle_hot : used.triangle
			top := start + (geometry.arrow_length - graphics.SCROLL_BAR_TRIANGLE_ROWS) / 2
			middle := geometry.thickness / 2
			for row in 0 ..< graphics.SCROLL_BAR_TRIANGLE_ROWS {
				half := which == .Arrow_Back ? row : graphics.SCROLL_BAR_TRIANGLE_ROWS - 1 - row
				scroll_bar_part_rectangle(table, area, direction, top + row, 1, middle - half, 2 * half + 1, triangle_color, element)
			}
		}
	}

	// The thumb: its border, its fill, the inner line, the grip.
	if geometry.thumb_length <= 2 * BORDER {
		return
	}
	stops := used.thumb_rest
	switch {
	case look.pressed == .Thumb:
		stops = used.thumb_pressed
	case look.under_pointer:
		stops = used.thumb_hot
	}
	thumb_percents := graphics.SCROLL_BAR_THUMB_STOP_PERCENTS
	scroll_bar_part_rectangle(table, area, direction, geometry.thumb_start, geometry.thumb_length, 0, geometry.thickness, lit ? used.hot_border : used.thumb_border, element)
	inner_start := geometry.thumb_start + BORDER
	inner_length := geometry.thumb_length - 2 * BORDER
	if inner_length >= 3 {
		// The inner line is the fill moved toward white, one pixel wide
		// inside the border: the whole inner box in the colors of the line,
		// then the fill over all of it but its first and last pixel along
		// the bar, then the two ends of the line across the bar.
		lined: [4]graphics.Color
		for &color, index in lined {
			color = graphics.scroll_bar_thumb_line_color(&used, stops[index])
		}
		scroll_bar_gradient_across(table, area, direction, inner_start, inner_length, BORDER, inner, lined[:], thumb_percents[:], element)
		scroll_bar_gradient_across(table, area, direction, inner_start + 1, inner_length - 2, BORDER, inner, stops[:], thumb_percents[:], element)
		scroll_bar_part_rectangle(table, area, direction, inner_start + 1, inner_length - 2, BORDER, 1, lined[0], element)
		scroll_bar_part_rectangle(table, area, direction, inner_start + 1, inner_length - 2, BORDER + inner - 1, 1, lined[3], element)
	} else {
		scroll_bar_gradient_across(table, area, direction, inner_start, inner_length, BORDER, inner, stops[:], thumb_percents[:], element)
	}
	if geometry.grip {
		grip_color := lit ? used.grip_lit : used.grip
		grip_start := geometry.thumb_start + (geometry.thumb_length - graphics.SCROLL_BAR_GRIP_LENGTH) / 2
		grip_across := (geometry.thickness - graphics.SCROLL_BAR_GRIP_LINE_LENGTH) / 2
		for grip_line in 0 ..< graphics.SCROLL_BAR_GRIP_LINES {
			scroll_bar_part_rectangle(table, area, direction, grip_start + grip_line * graphics.SCROLL_BAR_GRIP_LINE_STEP, 1, grip_across, graphics.SCROLL_BAR_GRIP_LINE_LENGTH, grip_color, element)
		}
	}
}
