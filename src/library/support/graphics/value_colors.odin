package graphics

import "contract:value_kinds"

// The colors of the value kinds (docs/DESIGN.md, section 4, "The colors of
// values"): the one table that the site of the system and the programs
// read, so that a number, a size or a module has one color wherever a value
// is shown. Each kind is an accent of the rules: the kernel blue for what
// the kernel names, the program green for what runs, the memory teal for
// numbers, the machine pink for what the root service gives, the color of
// the boot program for time and versions, the red of a failure for a
// status, the dim color for a place in the repository and for "no". On the
// light page of the site the accent moves toward black, so that it keeps a
// contrast of 4.5 to 1 there (the tests of the site and of this package
// compute it).
Value_Kind_Color :: struct {
	accent:        Color, // A color of the concepts, the text color or the dim color.
	dark_percent:  u32, // shade of the accent on a dark surface: 100 is the accent itself.
	light_percent: u32, // shade of the accent on the light page of the site.
}

// The color of each kind of value of the log: a number and a size in the
// color of memory, and so on. `value_kind_color` reads it: the program `log`
// draws each value with it, and the site takes the color of each kind from
// it.
@(rodata)
value_kind_colors := [value_kinds.Value_Kind]Value_Kind_Color {
	.None      = {},
	.Number    = {accent = COLOR_MEMORY, dark_percent = 100, light_percent = 65},
	.Size      = {accent = COLOR_MEMORY, dark_percent = 100, light_percent = 65},
	.Time      = {accent = COLOR_BOOT_PROGRAM, dark_percent = 100, light_percent = 65},
	.Handle    = {accent = COLOR_KERNEL, dark_percent = 100, light_percent = 73},
	.Value     = {accent = COLOR_MEMORY, dark_percent = 100, light_percent = 65},
	.Grant     = {accent = COLOR_MACHINE, dark_percent = 100, light_percent = 78},
	.Status    = {accent = COLOR_FAILED, dark_percent = 100, light_percent = 78},
	// The firmware violet at 100 % is at the bound on the band of a row.
	.Type      = {accent = COLOR_FIRMWARE, dark_percent = 115, light_percent = 83},
	.Operation = {accent = COLOR_KERNEL, dark_percent = 100, light_percent = 73},
	.Command   = {accent = COLOR_PROGRAM, dark_percent = 100, light_percent = 58},
	.Module    = {accent = COLOR_PROGRAM, dark_percent = 100, light_percent = 58},
	.File      = {accent = COLOR_DIM, dark_percent = 100, light_percent = 82},
	// A document is text to read: the color of the text.
	.Guide     = {accent = COLOR_TEXT, dark_percent = 100, light_percent = 20},
	.Term      = {accent = COLOR_MEMORY, dark_percent = 100, light_percent = 65},
	.Version   = {accent = COLOR_BOOT_PROGRAM, dark_percent = 100, light_percent = 65},
	.Yes       = {accent = COLOR_PROGRAM, dark_percent = 100, light_percent = 58},
	.No        = {accent = COLOR_DIM, dark_percent = 100, light_percent = 82},
	.Procedure = {accent = COLOR_KERNEL, dark_percent = 100, light_percent = 73},
	.Constant  = {accent = COLOR_MEMORY, dark_percent = 100, light_percent = 65},
	.Variable  = {accent = COLOR_BOOT_PROGRAM, dark_percent = 100, light_percent = 65},
}

// value_kind_color gives the color of a kind on a dark surface, or on the
// light page when light. The kind None has no color: plain, the color of
// the text around it.
value_kind_color :: proc "contextless" (kind: value_kinds.Value_Kind, light: bool, plain: Color = COLOR_TEXT) -> Color {
	if kind == .None || u8(kind) > u8(max(value_kinds.Value_Kind)) {
		return plain
	}
	description := value_kind_colors[kind]
	return shade(description.accent, light ? description.light_percent : description.dark_percent)
}
