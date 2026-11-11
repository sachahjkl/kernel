package graphics

// blend_premultiplied_alpha draws source over canvas at (x, y), cut to the
// canvas. Each pixel of source is 0xAARRGGBB with premultiplied alpha (the
// form of a pointer picture, docs/POINTERS.md); a pixel of canvas is
// 0x00RRGGBB. For each channel:
//
//   result = source + destination * (255 - alpha) / 255
//
// with a division by 255 that is exact for each 16-bit product:
// t = product + 128, then (t + t / 256) / 256. Red and blue are computed
// together in one 32-bit word (each in a lane of 16 bits), green alone. A
// pixel with alpha 0 is not read again; with alpha 255 it is copied. As the
// source is premultiplied, no channel of the result passes 255.
blend_premultiplied_alpha :: proc "contextless" (canvas: Canvas, x, y: int, source: Canvas) {
	x0 := max(x, 0)
	y0 := max(y, 0)
	x1 := min(x + source.width, canvas.width)
	y1 := min(y + source.height, canvas.height)
	if x0 >= x1 || y0 >= y1 {
		return
	}
	for line in y0 ..< y1 {
		to := canvas.pixels[line * canvas.stride:]
		from := source.pixels[(line - y) * source.stride + (x0 - x):]
		for column in x0 ..< x1 {
			value := from[column - x0]
			alpha := value >> 24
			if alpha == 0 {
				continue
			}
			if alpha == 255 {
				to[column] = value & 0xFFFFFF
				continue
			}
			inverse := 255 - alpha
			destination := to[column]
			red_blue := (destination & 0xFF00FF) * inverse + 0x800080
			red_blue = (red_blue + (red_blue >> 8 & 0xFF00FF)) >> 8 & 0xFF00FF
			green := (destination & 0x00FF00) * inverse + 0x008000
			green = (green + (green >> 8 & 0x00FF00)) >> 8 & 0x00FF00
			to[column] = red_blue + green + (value & 0xFFFFFF)
		}
	}
}
