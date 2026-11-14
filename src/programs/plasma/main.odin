// A demonstration: an animation that the processor computes for each frame.
//
// **What it is for.** It is a load that never ends and never waits for an
// input: one thread computes each pixel of a picture of 320 by 200, about
// 30 times in one second, with integers only. It shows the share of the
// processor of a busy program in `monitor`, and the cost of a full picture
// for the compositor.
//
// **Start**: `start("plasma")` in the console, or the bar of the desktop.
// The log has "plasma: ok" after the first picture. It has no grant of
// `grants_of`: a window is all that it needs.
//
// **How it computes**: a table of the sine in 256 steps, from the
// approximation of Bhaskara in integers, and a palette of 256 colors from
// three sines a third of a turn apart. Each pixel is the sum of four sines
// of its place and of the frame number.
package plasma

import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/system"

WIDTH :: 320
HEIGHT :: 200
FRAME_INTERVAL :: 33

sine: [256]i32 // One period, from -127 to 127.
palette: [256]graphics.Color
// The window is one picture of this program, shown with the interface
// package (a Picture record): the animation draws into it.
picture_pixels: [WIDTH * HEIGHT]graphics.Color
pictures: [1]graphics.Canvas
records_now, records_before: [2]interface.Draw_Record
drawing: interface.Window_Drawing

// The entry of plasma: it builds the sine table and the palette, then
// computes and shows one picture every 33 ms for ever.
//
// With no window it stops with the code 1. The time of each picture is
// fixed from the first one: after a slow picture, the next pictures follow
// with no sleep until the program is on time again.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "plasma")
	if !ok {
		system.stop(1)
	}
	// Bhaskara's approximation of the sine, in integers.
	for i in 0 ..< 128 {
		product := i32(i * (128 - i))
		value := 127 * 16 * product / (5 * 128 * 128 - 4 * product)
		sine[i] = value
		sine[i + 128] = -value
	}
	for i in 0 ..< 256 {
		red := u32(128 + sine[i])
		green := u32(128 + sine[(i + 85) & 255])
		blue := u32(128 + sine[(i + 170) & 255])
		palette[i] = graphics.rgb(red, green, blue)
	}

	pictures[0] = {pixels = raw_data(picture_pixels[:]), width = WIDTH, height = HEIGHT, stride = WIDTH}
	drawing = interface.window_drawing_of_picture(records_now[:], records_before[:], pictures[:])
	frame: u64
	next := system.time()
	for {
		t := int(frame)
		for y in 0 ..< HEIGHT {
			row := picture_pixels[y * WIDTH:]
			a := sine[(y * 2 + t) & 255]
			for x in 0 ..< WIDTH {
				value := a + sine[(x + t * 2) & 255] + sine[(x + y + t) & 255] + sine[((x * x + y * y) >> 7 + t * 3) & 255]
				row[x] = palette[(int(value) >> 1 + t) & 255]
			}
		}
		interface.show_picture(&drawing, &window, u32(frame) + 1)
		if frame == 0 {
			system.log("plasma: ok")
		}
		frame += 1
		for _ in display.next_event(&window) {}
		next += FRAME_INTERVAL
		system.sleep(next)
	}
}
