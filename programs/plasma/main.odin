// A demonstration: an animation that the processor computes for each frame.
package plasma

import "../../display"
import "../../graphics"
import "../../system"

WIDTH :: 320
HEIGHT :: 200
FRAME_INTERVAL :: 33

sine: [256]i32 // One period, from -127 to 127.
palette: [256]graphics.Color

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

	frame: u64
	next := system.time()
	for {
		t := int(frame)
		for y in 0 ..< HEIGHT {
			row := window.canvas.pixels[y * WIDTH:]
			a := sine[(y * 2 + t) & 255]
			for x in 0 ..< WIDTH {
				value := a + sine[(x + t * 2) & 255] + sine[(x + y + t) & 255] + sine[((x * x + y * y) >> 7 + t * 3) & 255]
				row[x] = palette[(int(value) >> 1 + t) & 255]
			}
		}
		display.present(&window)
		if frame == 0 {
			system.log("plasma: ok")
		}
		frame += 1
		for _ in display.next_event(&window) {}
		next += FRAME_INTERVAL
		system.wait(next)
	}
}
