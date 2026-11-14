package compositor

// The pointer (docs/POINTERS.md): the compositor maps the pointer theme file
// that the root service gives, validates it once, chooses the pointer shape
// from what is under the pointer, and draws its pointer picture with a blend
// of premultiplied alpha, at the place of the pointer less the hot spot.
//
// The place of the pointer (pointer_x, pointer_y, and compositor.pointer())
// is the point where a press acts; the hot spot of the picture is drawn
// there. An animated shape wakes the compositor at the time of its next
// frame, and only while it shows.

import op "contract:operation"
import "contract:pointer_pictures"
import "contract:ring"
import "contract:settings"
import "support:bar"
import "support:graphics"
import "support:palette"
import "support:system"

// The values of the context that give the theme file, mapped read-only.
VALUE_POINTER_THEME_ADDRESS :: 6
VALUE_POINTER_THEME_SIZE :: 7
// The places of the address and the size of each theme: the second one is
// at the values that contract:operation names for it.
POINTER_THEME_VALUES := [2][2]int{{VALUE_POINTER_THEME_ADDRESS, VALUE_POINTER_THEME_SIZE}, {op.CONTEXT_VALUE_SECOND_POINTER_THEME_ADDRESS, op.CONTEXT_VALUE_SECOND_POINTER_THEME_SIZE}}
// The nominal size that the compositor asks: the smallest size of the theme
// that is at least this one. 24 for the theme of the system, 32 for the
// theme of the owner (the smallest size that it has).
POINTER_NOMINAL_SIZE :: 24
// The frames of a pointer that the measure of its cost counts, before it
// writes the log line.
POINTER_MEASURE_FRAMES :: 256

// The arrow of squares of docs/DESIGN.md, for a compositor with no valid
// theme file: X is a black square of 2 pixels, . a white one, the point is
// the top left square.
@(rodata)
pointer_arrow_without_theme := [?]string {
	"X       ",
	"XX      ",
	"X.X     ",
	"X..X    ",
	"X...X   ",
	"X....X  ",
	"X.....X ",
	"X......X",
	"X..XXXXX",
	"X.X     ",
	"XX      ",
}
POINTER_ARROW_SQUARE :: 2

pointer_theme: []u8 // A theme file that pointer_pictures.validate accepted, or nil.
pointer_shape: pointer_pictures.Pointer_Shape // The shape that the screen shows.
pointer_chosen: pointer_pictures.Chosen // Its picture, which the next frame draws.
pointer_drawn: Rectangle // The rectangle of the picture on the screen.
pointer_drawn_valid: bool
// The measure of the cost of the pointer in a frame: the time of its blend
// in each damage rectangle that holds it, summed for a frame.
pointer_measure_frames, pointer_measure_time, pointer_measure_longest: u64
pointer_frame_time: u64

// The themes that the root service gives, in the order of
// pointer_pictures.RESOURCE_PREFERENCE: each one validated once, or nil.
// The setting "pointer_theme" chooses one (pointer_theme_choose).
pointer_themes: [len(pointer_pictures.RESOURCE_PREFERENCE)][]u8

// pointer_theme_open maps nothing: the root service mapped the files, the
// first one at the values 6 and 7, the second at the values that
// contract:operation names for it. It validates
// each file once; a file that is not valid is not used.
pointer_theme_open :: proc "contextless" (ctx: ^system.Context) {
	for &theme, index in pointer_themes {
		address := ctx.values[POINTER_THEME_VALUES[index][0]]
		size := ctx.values[POINTER_THEME_VALUES[index][1]]
		if address == 0 || size == 0 {
			continue
		}
		file := ([^]u8)(uintptr(address))[:size]
		start := system.nanoseconds()
		problem := pointer_pictures.validate(file)
		spent := system.nanoseconds() - start
		if problem.kind != .None {
			buffer: [256]u8
			system.log_in("surfaces", .Warning, "compositor: the pointer theme file ", pointer_pictures.RESOURCE_PREFERENCE[index], " is not valid, not used: ", pointer_pictures.sentence(problem, buffer[:]))
			continue
		}
		theme = file
		head := pointer_pictures.header(file)
		system.log_in("surfaces", .Info, "compositor: the pointer theme ", pointer_pictures.text_of(head.theme_name[:]), " (", pointer_pictures.text_of(head.license[:]), "): ", u64(head.shape_count), " shapes, ", u64(head.picture_count), " pictures, ", size, " bytes, validated in ", spent / 1000, " us")
	}
	pointer_theme_choose(.Of_The_Owner)
	if pointer_theme == nil {
		system.log_in("surfaces", .Warning, "compositor: no pointer theme: the arrow of squares")
		pointer_update(0)
		return
	}
	pointer_blend_measure()
}

// pointer_theme_choose takes the theme of the setting: the first theme of
// the list that the root service gave (the theme of the owner when the
// boot image has it), or the theme of the system. It draws the pointer
// again with it.
pointer_theme_choose :: proc "contextless" (setting: settings.Pointer_Theme) {
	chosen: []u8
	if setting == .Of_The_System {
		chosen = pointer_themes[len(pointer_themes) - 1]
	}
	for theme in pointer_themes {
		if chosen == nil {
			chosen = theme
		}
	}
	if raw_data(chosen) == raw_data(pointer_theme) && len(chosen) == len(pointer_theme) {
		return
	}
	pointer_theme = chosen
	pointer_drawn_valid = false // The next update chooses its picture in the new theme.
	pointer_update(0)
	if chosen != nil {
		system.log_in("surfaces", .Info, "compositor: the pointer theme in use: ", pointer_pictures.text_of(pointer_pictures.header(chosen).theme_name[:]))
	}
}

// pointer_shape_under gives the shape for what is under the pointer.
pointer_shape_under :: proc "contextless" () -> pointer_pictures.Pointer_Shape {
	if dragging >= 0 {
		return .Move
	}
	if palette_is_open() {
		// The input band is a text; an entry of the list can be pressed.
		left, top := palette_place()
		if palette.part_at(left, top, pointer_x, pointer_y) == .Input_Band {
			return .Text
		}
		if palette.row_is_entry(&palette_panel, palette.row_at(&palette_panel, left, top, pointer_x, pointer_y)) {
			return .Pointing_Hand
		}
		return .Arrow
	}
	if menu_open != .None && menu_line >= 0 {
		return .Pointing_Hand
	}
	if bar.button_at(bar_layout, pointer_x, pointer_y) != .None {
		return .Pointing_Hand
	}
	if pointer_y < BAR_HEIGHT {
		return .Arrow
	}
	for position := order_count - 1; position >= 0; position -= 1 {
		client := &clients[order[position]]
		outer_width := client.surface.width + 2 * BORDER
		if !inside(pointer_x, pointer_y, client.x, client.y, outer_width, client.surface.height + TITLE_HEIGHT + BORDER) {
			continue
		}
		switch {
		case inside(pointer_x, pointer_y, client.x + outer_width - BORDER - CLOSE_SIZE, client.y, CLOSE_SIZE, TITLE_HEIGHT):
			return .Pointing_Hand
		case pointer_y < client.y + TITLE_HEIGHT:
			return .Move
		case inside(pointer_x, pointer_y, client.x + BORDER, client.y + TITLE_HEIGHT, client.surface.width, client.surface.height):
			// The surface of the window in front at this place: the shape that
			// its program asked for, over its own surface only: a program must not
// change the pointer over the window of another program.
			return client.pointer_shape
		}
		return .Arrow // The border.
	}
	return .Arrow
}

// pointer_update chooses the shape and its picture for the place of the
// pointer and the time now, and damages the old and the new rectangle when
// the picture or its place changed.
pointer_update :: proc "contextless" (now: u64) {
	shape := pointer_shape_under()
	chosen := pointer_chosen
	if pointer_theme != nil && (shape != pointer_shape || !pointer_drawn_valid || (chosen.next_frame != 0 && now >= chosen.next_frame)) {
		chosen = pointer_pictures.choose(pointer_theme, shape, POINTER_NOMINAL_SIZE, now)
	}
	place := pointer_rectangle(chosen)
	if pointer_drawn_valid && place == pointer_drawn && shape == pointer_shape && chosen.picture == pointer_chosen.picture {
		return
	}
	if pointer_drawn_valid {
		damage_add(pointer_drawn.left, pointer_drawn.top, pointer_drawn.right - pointer_drawn.left, pointer_drawn.bottom - pointer_drawn.top)
	}
	damage_add(place.left, place.top, place.right - place.left, place.bottom - place.top)
	pointer_shape = shape
	pointer_chosen = chosen
	pointer_drawn = place
	pointer_drawn_valid = true
}

// pointer_rectangle gives the rectangle of a picture on the screen: its
// hot spot at the place of the pointer.
pointer_rectangle :: proc "contextless" (chosen: pointer_pictures.Chosen) -> Rectangle {
	if pointer_theme == nil {
		return {pointer_x, pointer_y, pointer_x + 8 * POINTER_ARROW_SQUARE, pointer_y + len(pointer_arrow_without_theme) * POINTER_ARROW_SQUARE}
	}
	left := pointer_x - int(chosen.picture.hot_spot_x)
	top := pointer_y - int(chosen.picture.hot_spot_y)
	return {left, top, left + int(chosen.picture.width), top + int(chosen.picture.height)}
}

// pointer_wake gives the time of the next frame of an animated shape on
// the screen, or 0: no wake for the pointer.
pointer_wake :: proc "contextless" () -> u64 {
	return pointer_chosen.next_frame
}

// pointer_shape_request takes the display command Pointer_Shape of a
// program: the shape of its surface. A number out of the enum is ignored.
pointer_shape_request :: proc "contextless" (client: ^Client, record: ring.Record) {
	if record.values[0] > u64(max(pointer_pictures.Pointer_Shape)) {
		return
	}
	client.pointer_shape = pointer_pictures.Pointer_Shape(record.values[0])
	system.log_in("surfaces", .Info, "compositor: ", system.name_of(client.title[:]), " asks for the pointer shape ", pointer_pictures.SHAPE_NAMES[client.pointer_shape], " over its surface")
}

// pointer_draw draws the pointer in one damage rectangle: the canvas is the
// part of the frame in it.
pointer_draw :: proc "contextless" (canvas: graphics.Canvas, origin_x, origin_y: int) {
	if pointer_theme == nil {
		for row, y in pointer_arrow_without_theme {
			for column in 0 ..< len(row) {
				color: graphics.Color
				switch row[column] {
				case 'X':
					color = graphics.COLOR_BLACK
				case '.':
					color = graphics.COLOR_WHITE
				case:
					continue
				}
				graphics.fill(canvas, pointer_x + column * POINTER_ARROW_SQUARE + origin_x, pointer_y + y * POINTER_ARROW_SQUARE + origin_y, POINTER_ARROW_SQUARE, POINTER_ARROW_SQUARE, color)
			}
		}
		return
	}
	place := pointer_drawn
	if place.right + origin_x <= 0 || place.bottom + origin_y <= 0 || place.left + origin_x >= canvas.width || place.top + origin_y >= canvas.height {
		return
	}
	start := system.nanoseconds()
	picture := graphics.Canvas{pixels = raw_data(pointer_chosen.pixels), width = int(pointer_chosen.picture.width), height = int(pointer_chosen.picture.height), stride = int(pointer_chosen.picture.width)}
	graphics.blend_premultiplied_alpha(canvas, place.left + origin_x, place.top + origin_y, picture)
	pointer_frame_time += system.nanoseconds() - start
}

// pointer_frame_end counts the time of the pointer in the frame that was
// drawn, and writes the measure on the log after POINTER_MEASURE_FRAMES
// frames that drew it.
pointer_frame_end :: proc "contextless" () {
	if pointer_frame_time == 0 {
		return
	}
	pointer_measure_frames += 1
	pointer_measure_time += pointer_frame_time
	pointer_measure_longest = max(pointer_measure_longest, pointer_frame_time)
	pointer_frame_time = 0
	if pointer_measure_frames == POINTER_MEASURE_FRAMES {
		system.log_in("surfaces", .Info, "compositor: the pointer picture in ", u64(POINTER_MEASURE_FRAMES), " frames: ", pointer_measure_time / POINTER_MEASURE_FRAMES, " ns for a frame in the mean, ", pointer_measure_longest, " ns the longest")
	}
}

// pointer_blend_measure measures the blend of the arrow of the theme, and
// of each picture size of the theme, on the frame, before the first frame:
// nanoseconds for one picture, and a copy of the same size with no alpha.
pointer_blend_measure :: proc "contextless" () {
	ROUNDS :: 2000
	chosen := pointer_pictures.choose(pointer_theme, .Arrow, POINTER_NOMINAL_SIZE, 0)
	picture := graphics.Canvas{pixels = raw_data(chosen.pixels), width = int(chosen.picture.width), height = int(chosen.picture.height), stride = int(chosen.picture.width)}
	start := system.nanoseconds()
	for round in 0 ..< ROUNDS {
		graphics.blend_premultiplied_alpha(frame, 100 + round % 7, 100, picture)
	}
	blend := (system.nanoseconds() - start) / ROUNDS
	opaque := graphics.Canvas{pixels = background.pixels, width = picture.width, height = picture.height, stride = background.stride}
	start = system.nanoseconds()
	for round in 0 ..< ROUNDS {
		graphics.copy(frame, 100 + round % 7, 100, opaque)
	}
	copied := (system.nanoseconds() - start) / ROUNDS
	transparent := 0
	for pixel in chosen.pixels {
		if pixel >> 24 == 0 {
			transparent += 1
		}
	}
	system.log_in("surfaces", .Info, "compositor: the blend of the arrow of ", u64(picture.width), "x", u64(picture.height), " (", u64(transparent), " of ", u64(len(chosen.pixels)), " pixels transparent): ", blend, " ns; a copy of the same size: ", copied, " ns")
}
