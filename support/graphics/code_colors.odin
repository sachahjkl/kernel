package graphics

// The colors of code (docs/DESIGN.md, section 4, "The colors of code"): the
// one table that the site of the system and the terminal read, so that a
// type, a literal or a name has one color wherever code is shown. Each
// class is an accent of the rules, moved toward white on a dark surface and
// toward black on the light page of the site, so that it keeps a contrast
// of 4.5 to 1 on the surfaces that show code (the tests of the site and of
// support/terminal compute it).
Code_Class :: enum u8 {
	None        = 0, // No color of its own: the color of the text around it.
	Keyword     = 1, // A word of the language.
	Type        = 2, // A type, or a name in the place of a type.
	Literal     = 3, // A number, a text, a constant, a member.
	Name        = 4, // The name of a function or a declaration.
	Directive   = 5, // A directive or an attribute.
	Comment     = 6, // A comment, or words that are not code: quiet.
	Punctuation = 7, // An operator or punctuation: the other quiet class.
}

// The color of one class of code: one accent of the design, and how much
// of it to show on each surface.
Code_Class_Color :: struct {
	accent:        Color, // A color of the concepts or the dim color.
	dark_percent:  u32, // shade of the accent on a dark surface: 100 is the accent itself.
	light_percent: u32, // shade of the accent on the light page of the site.
}

// The kernel blue for the words of the language, the violet of the
// firmware for types, the memory teal for values, the program green for
// the names of functions, the machine pink for directives, the dim color
// for comments and, a little lighter, for punctuation.
@(rodata)
code_class_colors := [Code_Class]Code_Class_Color {
	.None        = {},
	.Keyword     = {accent = COLOR_KERNEL, dark_percent = 115, light_percent = 55},
	.Type        = {accent = COLOR_FIRMWARE, dark_percent = 115, light_percent = 60},
	.Literal     = {accent = COLOR_MEMORY, dark_percent = 100, light_percent = 50},
	.Name        = {accent = COLOR_PROGRAM, dark_percent = 100, light_percent = 45},
	.Directive   = {accent = COLOR_MACHINE, dark_percent = 115, light_percent = 55},
	.Comment     = {accent = COLOR_DIM, dark_percent = 125, light_percent = 60},
	.Punctuation = {accent = COLOR_DIM, dark_percent = 140, light_percent = 50},
}

// code_class_color gives the color of a class on a dark surface, or on the
// light page when light. The class None has no color: the caller keeps the
// color of the text around it.
code_class_color :: proc "contextless" (class: Code_Class, light: bool) -> Color {
	description := code_class_colors[class]
	return shade(description.accent, light ? description.light_percent : description.dark_percent)
}
