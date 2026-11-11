// A demonstration: an animation that the processor computes for each frame.
package plasma

import "support:display"
import "support:graphics"
import "support:interface"
import "support:system"

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
