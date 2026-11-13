// A demonstration, for fun: the temple of Jon. A portrait of Jonathan Blow
// turns about its vertical axis, with perspective, in front of rays of light.
// The processor draws all of it: the system has no GPU code yet, and
// programs draw on the processor first (docs/PROPERTIES.md, "One graphics
// interface").
//
// **What it is for.** It is a load of floating point work on the
// processor, with perspective, that a reader can judge by eye: a lost
// register or a late frame shows at once.
//
// **Start**: `start("temple")` in the console, or the bar of the desktop.
// It has no grant of `grants_of`: a window is all that it needs. The log has
// "temple: ok" after the first picture.
package temple

import "support:display"
import "support:graphics"
import "support:interface"
import "support:system"

WIDTH :: 440
HEIGHT :: 460
FRAME_INTERVAL :: 33
TURN_TIME :: 6000 // Milliseconds for one turn of the portrait.
RAY_TIME :: 40 // Milliseconds for one step of the rays.

PORTRAIT_WIDTH :: 180
PORTRAIT_HEIGHT :: 240
FRAME_BORDER :: 5
CENTER_X :: WIDTH / 2
CENTER_Y :: 248
LIGHT_Y :: 215 // The center of the rays.
EYE_DISTANCE :: 700.0 // From the eye to the axis of the portrait, in pixels.

COLOR_MARBLE :: 0xE2DCCE
COLOR_MARBLE_SHADE :: 0xB4AE9F
COLOR_MARBLE_DARK :: 0x8E887A
COLOR_INK :: 0x3A3428
COLOR_GOLD :: 0xD4A93C

texture: [PORTRAIT_WIDTH * PORTRAIT_HEIGHT]graphics.Color // The portrait in its frame.
angles: [WIDTH * HEIGHT]u8 // The direction of each pixel from the light, 256 per turn.
glows: [WIDTH * HEIGHT]u8 // The strength of the light at each pixel.
light_colors: [256]graphics.Color
strip: [PORTRAIT_HEIGHT][3]i32 // One column of the portrait, as red, green, blue.
// The window is one picture of this program, shown with the interface
// package (a Picture record): the scene draws into it.
picture_pixels: [WIDTH * HEIGHT]graphics.Color
pictures: [1]graphics.Canvas
records_now, records_before: [2]interface.Draw_Record
drawing: interface.Window_Drawing

// The entry of temple: it prepares the portrait, then draws the light, the
// temple and the turning portrait for ever.
//
// With no window it stops with the code 1. The angle of the portrait comes
// from the clock, not from a count of pictures, so a slow picture does not
// slow the turn. After a slow picture the program sleeps at least 5 ms, so
// it never takes the whole processor.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "temple")
	if !ok {
		system.stop(1)
	}
	prepare()
	pictures[0] = {pixels = raw_data(picture_pixels[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
	drawing = interface.window_drawing_of_picture(records_now[:], records_before[:], pictures[:])

	start := system.time()
	next := start
	frame: u64
	for {
		now := system.time()
		elapsed := now - start
		// The first frame shows the portrait a little before it faces the viewer.
		turn := f32((elapsed + TURN_TIME - TURN_TIME / 16) % TURN_TIME) / TURN_TIME
		draw_light(pictures[0], int(elapsed / RAY_TIME))
		draw_temple(pictures[0])
		draw_portrait(pictures[0], turn)
		interface.show_picture(&drawing, &window, u32(frame) + 1)
		if frame == 0 {
			system.log("temple: ok")
		}
		frame += 1
		for _ in display.next_event(&window) {}
		next = max(next + FRAME_INTERVAL, now + 5)
		system.sleep(next)
	}
}

// sine gives the sine of an angle in turns. The angle is not negative.
sine :: proc "contextless" (turn: f32) -> f32 {
	t := turn - f32(int(turn))
	sign: f32 = 1
	if t >= 0.5 {
		t -= 0.5
		sign = -1
	}
	if t > 0.25 {
		t = 0.5 - t
	}
	x := t * 6.2831853
	square := x * x
	return sign * x * (1 - square / 6 * (1 - square / 20 * (1 - square / 42)))
}

cosine :: proc "contextless" (turn: f32) -> f32 {
	return sine(turn + 0.25)
}

// direction gives the angle of the vector (x, y), in turns from 0 to 1.
direction :: proc "contextless" (x, y: f32) -> f32 {
	wide, tall := abs(x), abs(y)
	if wide == 0 && tall == 0 {
		return 0
	}
	ratio := min(wide, tall) / max(wide, tall)
	angle := ratio * (0.125 + 0.0434 * (1 - ratio))
	if tall > wide {
		angle = 0.25 - angle
	}
	if x < 0 {
		angle = 0.5 - angle
	}
	if y < 0 {
		angle = 1 - angle
	}
	return angle
}

prepare :: proc "contextless" () {
	// The portrait, with a frame of gold around it.
	source := #load("portrait.pixels", []u32)
	frame_shades := [FRAME_BORDER]graphics.Color{0x8A6418, 0xD4A93C, 0xF6DC84, 0xD4A93C, 0x8A6418}
	for y in 0 ..< PORTRAIT_HEIGHT {
		for x in 0 ..< PORTRAIT_WIDTH {
			edge := min(x, y, PORTRAIT_WIDTH - 1 - x, PORTRAIT_HEIGHT - 1 - y)
			index := y * PORTRAIT_WIDTH + x
			texture[index] = edge < FRAME_BORDER ? frame_shades[edge] : source[index]
		}
	}

	// The light: the direction and the strength for each pixel.
	REACH :: 340.0
	for y in 0 ..< HEIGHT {
		for x in 0 ..< WIDTH {
			dx, dy := f32(x - CENTER_X), f32(y - LIGHT_Y)
			index := y * WIDTH + x
			angles[index] = u8(int(direction(dx, dy) * 256) & 255)
			// The distance, with no square root: the larger side plus a part of the smaller one.
			distance := max(abs(dx), abs(dy)) + 0.4 * min(abs(dx), abs(dy))
			near := max(1 - distance / REACH, 0)
			glows[index] = u8(near * near * 255)
		}
	}
	for level in 0 ..< 256 {
		light_colors[level] = graphics.rgb(u32(16 + level * 225 / 255), u32(12 + level * 168 / 255), u32(34 + level * 44 / 255))
	}
}

// draw_light fills the canvas with rays that turn about the light.
draw_light :: proc "contextless" (canvas: graphics.Canvas, phase: int) {
	for index in 0 ..< WIDTH * HEIGHT {
		glow := int(glows[index])
		ray := abs((int(angles[index]) + phase) & 31 - 16) // 0 to 16, and back, 8 times per turn.
		canvas.pixels[index] = light_colors[(ray * glow >> 4 * 3 + glow) >> 2]
	}
}

draw_column :: proc "contextless" (canvas: graphics.Canvas, x: int) {
	TOP :: 90
	BOTTOM :: 396
	shades := [6]graphics.Color{0xA9A396, 0xCFC9BB, 0xE8E2D4, 0xDAD4C6, 0xBDB7A9, 0x979184}
	for shade, index in shades {
		graphics.fill(canvas, x + index * 5, TOP, 5, BOTTOM - TOP, shade)
	}
	graphics.fill(canvas, x - 5, TOP, 40, 8, COLOR_MARBLE)
	graphics.fill(canvas, x - 5, TOP + 8, 40, 2, COLOR_MARBLE_DARK)
	graphics.fill(canvas, x - 5, BOTTOM - 8, 40, 8, COLOR_MARBLE)
	graphics.fill(canvas, x - 5, BOTTOM - 10, 40, 2, COLOR_MARBLE_DARK)
}

draw_temple :: proc "contextless" (canvas: graphics.Canvas) {
	// The pediment: a triangle, with a darker triangle inside.
	for y in 12 ..< 64 {
		half := (y - 12) * 204 / 52
		graphics.fill(canvas, CENTER_X - half, y, 2 * half, 1, COLOR_MARBLE)
		inner := half - 22
		if inner > 0 && y < 58 {
			graphics.fill(canvas, CENTER_X - inner, y, 2 * inner, 1, COLOR_MARBLE_SHADE)
		}
	}
	graphics.fill(canvas, 16, 64, WIDTH - 32, 26, COLOR_MARBLE)
	graphics.fill(canvas, 16, 64, WIDTH - 32, 2, COLOR_MARBLE_DARK)
	graphics.fill(canvas, 16, 88, WIDTH - 32, 2, COLOR_MARBLE_DARK)
	title :: "T E M P L E   O F   J O N"
	graphics.text(canvas, CENTER_X - graphics.text_width(title) / 2, 69, title, COLOR_INK)

	draw_column(canvas, 26)
	draw_column(canvas, 66)
	draw_column(canvas, WIDTH - 66 - 30)
	draw_column(canvas, WIDTH - 26 - 30)

	// The steps.
	graphics.fill(canvas, 16, 396, WIDTH - 32, 14, COLOR_MARBLE)
	graphics.fill(canvas, 16, 408, WIDTH - 32, 2, COLOR_MARBLE_DARK)
	graphics.fill(canvas, 8, 410, WIDTH - 16, 16, COLOR_MARBLE)
	graphics.fill(canvas, 8, 424, WIDTH - 16, 2, COLOR_MARBLE_DARK)
	graphics.fill(canvas, 0, 426, WIDTH, HEIGHT - 426, COLOR_MARBLE)
	caption :: "no garbage collector beyond this point"
	graphics.text(canvas, CENTER_X - graphics.text_width(caption) / 2, 435, caption, COLOR_INK)
}

// draw_portrait draws the portrait as a flat card that turns about its
// vertical axis. For each column of the screen it finds the columns of the
// portrait that this column covers, with the perspective, and takes their mean.
draw_portrait :: proc "contextless" (canvas: graphics.Canvas, turn: f32) {
	HALF :: f32(PORTRAIT_WIDTH) / 2
	facing, side := cosine(turn), sine(turn)

	// The two vertical edges: their place on the screen and their distance.
	depth_left, depth_right := EYE_DISTANCE + HALF * side, EYE_DISTANCE - HALF * side
	left := CENTER_X - HALF * facing * EYE_DISTANCE / depth_left
	right := CENTER_X + HALF * facing * EYE_DISTANCE / depth_right
	flipped := left > right // The person sees the back: the portrait is mirrored.
	if flipped {
		left, right = right, left
		depth_left, depth_right = depth_right, depth_left
	}
	if right - left < 1 {
		// The card is seen from its side.
		graphics.fill(canvas, CENTER_X - 1, CENTER_Y - PORTRAIT_HEIGHT / 2, 2, PORTRAIT_HEIGHT, COLOR_GOLD)
		return
	}
	light := i32(256 * (0.4 + 0.6 * abs(facing)))

	// across gives the place in the portrait (0 to 1) of a place on the screen (0 to 1).
	across :: proc "contextless" (place, depth_left, depth_right: f32) -> f32 {
		far := place / depth_right
		return far / ((1 - place) / depth_left + far)
	}

	for x in int(left) ..= int(right) {
		place_start := clamp((f32(x) - left) / (right - left), 0, 1)
		place_end := clamp((f32(x + 1) - left) / (right - left), 0, 1)
		if place_end <= place_start {
			continue
		}
		from := across(place_start, depth_left, depth_right)
		to := across(place_end, depth_left, depth_right)
		if flipped {
			from, to = 1 - to, 1 - from
		}
		first := clamp(int(from * PORTRAIT_WIDTH), 0, PORTRAIT_WIDTH - 1)
		last := clamp(int(to * PORTRAIT_WIDTH + 0.999), first + 1, PORTRAIT_WIDTH)
		count := i32(last - first)
		for row in 0 ..< PORTRAIT_HEIGHT {
			red, green, blue: i32
			for texel in texture[row * PORTRAIT_WIDTH + first:][:count] {
				red += i32(texel >> 16 & 0xFF)
				green += i32(texel >> 8 & 0xFF)
				blue += i32(texel & 0xFF)
			}
			strip[row] = {red * light / count, green * light / count, blue * light / count}
		}

		// The height of this column: a near column is taller.
		middle := (place_start + place_end) / 2
		scale := EYE_DISTANCE * ((1 - middle) / depth_left + middle / depth_right)
		top := CENTER_Y - f32(PORTRAIT_HEIGHT) / 2 * scale
		y_first := int(top + 0.5)
		y_last := int(top + f32(PORTRAIT_HEIGHT) * scale + 0.5)
		step := i32(256 / scale)
		position := i32(((f32(y_first) + 0.5 - top) / scale - 0.5) * 256)
		for y in y_first ..< y_last {
			row := clamp(int(position >> 8), 0, PORTRAIT_HEIGHT - 1)
			below := min(row + 1, PORTRAIT_HEIGHT - 1)
			part := position < 0 ? 0 : position & 255
			a, b := strip[row], strip[below]
			red := (a[0] * (256 - part) + b[0] * part) >> 16
			green := (a[1] * (256 - part) + b[1] * part) >> 16
			blue := (a[2] * (256 - part) + b[2] * part) >> 16
			graphics.pixel(canvas, x, y, graphics.rgb(u32(red), u32(green), u32(blue)))
			position += step
		}
	}
}
