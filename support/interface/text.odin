package interface

import "support:graphics"

// The fonts that the package can measure. The kind is the grid of the
// font: cells of 8 x 16 pixels at scale 1. The vector font of the system and
// Spleen 8x16 both draw on it (docs/FONTS.md); the setting of the person
// chooses which one draws, and the measure does not change. A proportional
// font later is a new kind: the callers measure with text_width and append
// text records, so they do not change (docs/INTERFACE.md, section 5).
Font_Kind :: enum u8 {
	Cells_8x16,
}

// A font and a size. scale: 1, 2 or 3 times the native size (docs/DESIGN.md,
// section 5); 0 means 1.
Font :: struct {
	kind:  Font_Kind,
	scale: u8,
}

FONT_LARGE :: Font{scale = 3} // The one number of a card.
FONT_MEDIUM :: Font{scale = 2}

font_scale :: proc "contextless" (font: Font) -> int {
	return clamp(int(font.scale), 1, 3)
}

// text_width gives the width of a text in pixels.
text_width :: proc "contextless" (font: Font, text: string) -> int {
	switch font.kind {
	case .Cells_8x16:
	}
	return len(text) * graphics.CELL_WIDTH * font_scale(font)
}

// line_height gives the height of a line of a font, in pixels.
line_height :: proc "contextless" (font: Font) -> int {
	return graphics.CELL_HEIGHT * font_scale(font)
}

// A short text that a caller builds from parts, in its own memory.
Text_Builder :: struct {
	bytes: [128]u8,
	count: int,
}

text_put :: proc "contextless" (builder: ^Text_Builder, part: string) {
	count := min(len(part), len(builder.bytes) - builder.count)
	copy(builder.bytes[builder.count:], part[:count])
	builder.count += count
}

// text_put_number adds a number in decimal, with at least minimum_digits digits.
text_put_number :: proc "contextless" (builder: ^Text_Builder, value: u64, minimum_digits := 1) {
	digits: [20]u8
	count := 0
	least := min(minimum_digits, len(digits)) // A u64 has 20 digits at most.
	for rest := value; rest != 0 || count < least; rest /= 10 {
		digits[len(digits) - 1 - count] = u8('0' + rest % 10)
		count += 1
	}
	text_put(builder, string(digits[len(digits) - count:]))
}

text_of :: proc "contextless" (builder: ^Text_Builder) -> string {
	return string(builder.bytes[:builder.count])
}

// number_text writes a number into a builder that the caller gives, and
// gives the text.
number_text :: proc "contextless" (builder: ^Text_Builder, value: u64, minimum_digits := 1) -> string {
	builder.count = 0
	text_put_number(builder, value, minimum_digits)
	return text_of(builder)
}
