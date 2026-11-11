// The pointer themes of the boot image (docs/POINTERS.md), as a table that
// a person reads: each pointer shape of a theme at each of its sizes, its
// hot spot marked, its frames, and the theme with its license and its
// attribution.
//
// The program has the boot image, read-only. It finds the pointer theme
// files in the resource table, checks the hash of each one against its
// entry (property 11), validates it with the validation of the compositor,
// and shows one theme at a time: two buttons change the theme. The window
// is built with the interface package; the pointer pictures are drawn into
// the canvas directly, inside the area of each tile, because the package
// has no record of a picture of pixels. Over a tile, the program asks the
// compositor for the shape of the tile (display.pointer_shape_set): the
// pointer over this surface shows it.
package pointers

import "contract:blake3"
import "contract:pointer_pictures"
import "support:display"
import "support:graphics"
import "support:interface"
import "support:system"

WIDTH :: 976
HEIGHT :: 704
COLUMNS :: 5 // Tiles in a line.
TILE_WIDTH :: 184
TILE_HEIGHT :: 144
TILE_GAP :: 8
TILES_TOP :: 216 // The first line of tiles, in the window.
PICTURE_TOP :: 56 // The pictures, in a tile, under two lines of the name and a line of facts.
NAME_LIMIT :: (TILE_WIDTH - 16) / 8 // The characters of a line of a tile.
THEME_CAPACITY :: 4

// A theme file of the boot image that the program checked.
Theme :: struct {
	resource:   string,
	file:       []u8,
	hash:       [32]u8,
	valid:      bool,
	problem:    [256]u8, // The sentence of the problem when it is not valid.
	problem_count: int,
	check_time: u64, // Nanoseconds: the hash and the validation.
}

themes: [THEME_CAPACITY]Theme
theme_count: int
shown: int // The theme on the screen.
table_records: [1024]interface.Draw_Record
table_text: [16384]u8
table: interface.Draw_Table
state: interface.Interface_State
input: interface.Input
asked_shape := pointer_pictures.Pointer_Shape.Arrow // The last shape that this program asked for.
tile_under_pointer := -1

// The area of the tile of the shape at a place of the shape table.
tile_area :: proc "contextless" (index: int) -> interface.Area {
	column := index % COLUMNS
	line := index / COLUMNS
	return {16 + column * (TILE_WIDTH + TILE_GAP), TILES_TOP + line * (TILE_HEIGHT + TILE_GAP), TILE_WIDTH, TILE_HEIGHT}
}

hexadecimal :: proc "contextless" (builder: ^interface.Text_Builder, bytes: []u8) {
	digits := "0123456789abcdef"
	for byte in bytes {
		pair := [2]u8{digits[byte >> 4], digits[byte & 15]}
		interface.text_put(builder, string(pair[:]))
	}
}

// build describes the window for one frame. It gives the tile under the
// pointer, or -1.
build :: proc "contextless" (frame: ^interface.Frame) -> int {
	builder: interface.Text_Builder
	interface.background(frame, {0, 0, WIDTH, HEIGHT})
	theme := &themes[shown]
	head := pointer_pictures.header(theme.file)
	count: interface.Text_Builder
	interface.text_put_number(&count, u64(shown + 1))
	interface.text_put(&count, " of ")
	interface.text_put_number(&count, u64(theme_count))
	content := interface.card(frame, {8, 8, WIDTH - 16, TILES_TOP - 16}, "POINTER THEME", "resource table of the boot image", graphics.COLOR_MACHINE, interface.text_of(&count))
	column := interface.column_of(content, 0)

	// The buttons that choose the theme.
	buttons := interface.column_take(&column, 24)
	for index in 0 ..< theme_count {
		label := themes[index].resource
		area := interface.Area{buttons.x + index * 200, buttons.y, 192, 24}
		result := interface.button(frame, area, interface.identity_with(interface.identity("theme"), index), label, index == shown)
		if result.activated && index != shown {
			shown = index
			system.log("pointers: the theme ", label, " is shown")
		}
	}
	interface.column_take(&column, 8)
	if !theme.valid {
		interface.label_value_line(frame, interface.column_take(&column, 16), "not valid", string(theme.problem[:theme.problem_count]), graphics.COLOR_FAILED, 128)
		return -1
	}
	interface.label_value_line(frame, interface.column_take(&column, 16), "theme", pointer_pictures.text_of(head.theme_name[:]), graphics.COLOR_TEXT, 128)
	interface.text_put(&builder, pointer_pictures.text_of(head.license[:]))
	interface.label_value_line(frame, interface.column_take(&column, 16), "license", interface.text_of(&builder), graphics.COLOR_TEXT, 128)
	builder = {}
	interface.text_put_number(&builder, u64(head.shape_count))
	interface.text_put(&builder, " shapes, ")
	interface.text_put_number(&builder, u64(head.picture_count))
	interface.text_put(&builder, " pictures, ")
	interface.text_put_number(&builder, head.file_size)
	interface.text_put(&builder, " bytes; blake3 ")
	hexadecimal(&builder, theme.hash[:12])
	interface.text_put(&builder, "..., as its entry")
	interface.label_value_line(frame, interface.column_take(&column, 16), "file", interface.text_of(&builder), graphics.COLOR_TEXT, 128)
	// The attribution, in lines of at most 98 characters, cut at a space.
	attribution := pointer_pictures.text_of(head.attribution[:])
	first := true
	for len(attribution) > 0 {
		cut := len(attribution)
		if cut > 98 {
			cut = 98
			for cut > 0 && attribution[cut] != ' ' {
				cut -= 1
			}
			if cut == 0 {
				cut = 98
			}
		}
		interface.label_value_line(frame, interface.column_take(&column, 16), first ? "attribution" : "", attribution[:cut], graphics.COLOR_TEXT, 128)
		first = false
		attribution = attribution[min(cut + 1, len(attribution)):]
	}

	// The tiles: one for each shape of the theme.
	under := -1
	pictures := pointer_pictures.picture_entries(theme.file)
	for entry, index in pointer_pictures.shape_entries(theme.file) {
		area := tile_area(index)
		if input.pointer_known && interface.area_contains(area, input.pointer_x, input.pointer_y) {
			under = index
		}
		interface.draw_vertical_gradient(frame.table, area.x, area.y, area.width, area.height, under == index ? graphics.shade(graphics.COLOR_CARD_TOP, 140) : graphics.COLOR_CARD_TOP, graphics.COLOR_CARD_BOTTOM)
		interface.draw_rectangle(frame.table, area.x, area.y, area.width, 1, graphics.shade(graphics.COLOR_MACHINE, under == index ? 60 : 28))
		// The name, on two lines when it is longer than a line: cut after
		// an underscore.
		name := pointer_pictures.shape_name(entry.shape)
		name_color := graphics.Color(under == index ? graphics.COLOR_WHITE : graphics.COLOR_TEXT)
		if len(name) <= NAME_LIMIT {
			interface.draw_text(frame.table, area.x + 8, area.y + 4, name, name_color)
		} else {
			cut := NAME_LIMIT
			for cut > 0 && name[cut - 1] != '_' {
				cut -= 1
			}
			cut = cut == 0 ? NAME_LIMIT : cut
			interface.draw_text(frame.table, area.x + 8, area.y + 4, name[:cut], name_color)
			interface.draw_text(frame.table, area.x + 8, area.y + 20, name[cut:], name_color)
		}
		// The facts: the hot spot of the first size, and the frames.
		first_picture := pictures[entry.first_picture]
		builder = {}
		interface.text_put(&builder, "hot ")
		interface.text_put_number(&builder, u64(first_picture.hot_spot_x))
		interface.text_put(&builder, ",")
		interface.text_put_number(&builder, u64(first_picture.hot_spot_y))
		interface.draw_text(frame.table, area.x + 8, area.y + 36, interface.text_of(&builder), graphics.COLOR_BOOT_PROGRAM)
		if entry.frame_count > 1 {
			builder = {}
			interface.text_put_number(&builder, u64(entry.frame_count))
			interface.text_put(&builder, " x ")
			interface.text_put_number(&builder, u64(first_picture.delay_milliseconds))
			interface.text_put(&builder, " ms")
			interface.draw_text_right(frame.table, area.x + area.width - 8, area.y + 36, interface.text_of(&builder), graphics.COLOR_DIM)
		}
		// A track behind each size, with the lines of the hot spot.
		x := area.x + 8
		for size in 0 ..< entry.size_count {
			picture := pictures[entry.first_picture + size * entry.frame_count]
			side := int(picture.nominal_size)
			if x + side > area.x + area.width - 8 {
				break
			}
			interface.draw_rectangle(frame.table, x, area.y + PICTURE_TOP, side, side, graphics.COLOR_TRACK)
			interface.draw_rectangle(frame.table, x + int(picture.hot_spot_x), area.y + PICTURE_TOP, 1, side, graphics.COLOR_BOOT_PROGRAM)
			interface.draw_rectangle(frame.table, x, area.y + PICTURE_TOP + int(picture.hot_spot_y), side, 1, graphics.COLOR_BOOT_PROGRAM)
			builder = {}
			interface.text_put_number(&builder, u64(picture.nominal_size))
			interface.draw_text(frame.table, x, area.y + PICTURE_TOP + side + 4, interface.text_of(&builder), graphics.COLOR_DIM)
			x += side + 8
		}
	}
	builder = {}
	interface.text_put(&builder, "the lines in amber cross at the hot spot; over a tile, this program asks the compositor for its shape")
	interface.draw_text(frame.table, 16, HEIGHT - 24, interface.text_of(&builder), graphics.COLOR_DIM)
	return under
}

// pictures_draw draws the first frame of each picture of each tile, over
// its track: the pixels, which no draw record holds.
pictures_draw :: proc "contextless" (canvas: graphics.Canvas) {
	theme := &themes[shown]
	if !theme.valid {
		return
	}
	pictures := pointer_pictures.picture_entries(theme.file)
	for entry, index in pointer_pictures.shape_entries(theme.file) {
		area := tile_area(index)
		x := area.x + 8
		for size in 0 ..< entry.size_count {
			picture := pictures[entry.first_picture + size * entry.frame_count]
			side := int(picture.nominal_size)
			if x + side > area.x + area.width - 8 {
				break
			}
			pixels := pointer_pictures.pixels_of(theme.file, picture)
			// The picture in the square of its nominal size: a picture larger
			// than its size is cut to the square.
			square := graphics.view(canvas, x, area.y + PICTURE_TOP, side, side)
			graphics.blend_premultiplied_alpha(square, 0, 0, {pixels = raw_data(pixels), width = int(picture.width), height = int(picture.height), stride = int(picture.width)})
			x += side + 8
		}
	}
}

// frame_draw builds the window, draws it whole, then the pictures, and
// presents it. The window changes only with an event.
frame_draw :: proc "contextless" (window: ^display.Window) -> u64 {
	start := system.nanoseconds()
	frame := interface.frame_begin(&table, &state, &input)
	before := shown
	under := build(&frame)
	interface.frame_end(&frame)
	interface.input_clear(&input)
	if shown != before {
		// A button changed the theme: the frame shows the other theme.
		frame = interface.frame_begin(&table, &state, &input)
		under = build(&frame)
		interface.frame_end(&frame)
	}
	interface.execute(&table, window.canvas)
	pictures_draw(window.canvas)
	display.present(window)
	// Over a tile, the pointer takes the shape of the tile.
	shape := pointer_pictures.Pointer_Shape.Arrow
	if under >= 0 && themes[shown].valid {
		shape = pointer_pictures.Pointer_Shape(pointer_pictures.shape_entries(themes[shown].file)[under].shape)
	}
	if shape != asked_shape {
		asked_shape = shape
		display.pointer_shape_set(window, shape)
	}
	if under != tile_under_pointer {
		tile_under_pointer = under
		if under >= 0 {
			system.log("pointers: the pointer is over the tile ", pointer_pictures.SHAPE_NAMES[shape])
		}
	}
	return system.nanoseconds() - start
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	image_handle := ctx.handles[system.GRANT_IMAGE]
	image_size := ctx.values[system.GRANT_VALUE_IMAGE_SIZE]
	address, status := system.memory_map(image_handle, {}) // Read only.
	if status != .Ok || image_size == 0 {
		system.log("pointers: no boot image")
		system.stop(1)
	}
	image := ([^]u8)(address)[:image_size]
	// The themes, in the order in which the compositor prefers them.
	for name in pointer_pictures.RESOURCE_PREFERENCE {
		entry := system.image_resource_find(image, name)
		if entry == nil || theme_count == THEME_CAPACITY {
			continue
		}
		theme := &themes[theme_count]
		theme_count += 1
		theme.resource = name
		theme.file = image[entry.offset:][:entry.size]
		start := system.nanoseconds()
		theme.hash = blake3.hash(theme.file)
		problem := pointer_pictures.validate(theme.file)
		theme.check_time = system.nanoseconds() - start
		theme.valid = theme.hash == entry.hash && problem.kind == .None
		if theme.hash != entry.hash {
			theme.problem_count = copy(theme.problem[:], "the bytes do not have the hash of the entry of the resource")
		} else if problem.kind != .None {
			theme.problem_count = len(pointer_pictures.sentence(problem, theme.problem[:]))
		}
		if theme.valid {
			head := pointer_pictures.header(theme.file)
			system.log("pointers: ", name, ": ", pointer_pictures.text_of(head.theme_name[:]), ", ", pointer_pictures.text_of(head.license[:]), ", ", u64(head.shape_count), " shapes, ", u64(head.picture_count), " pictures, ", entry.size, " bytes; the hash and the validation in ", theme.check_time / 1000, " us")
		} else {
			system.log("pointers: ", name, " is not valid: ", string(theme.problem[:theme.problem_count]))
		}
	}
	if theme_count == 0 {
		system.log("pointers: the boot image has no pointer theme")
		system.stop(1)
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, "pointers")
	if !ok {
		system.stop(1)
	}
	table = {records = table_records[:], text = table_text[:]}
	spent := frame_draw(&window)
	system.log("pointers: ok, ", u64(theme_count), " themes; the window of ", themes[shown].resource, " drawn in ", spent / 1000, " us")
	for {
		display.wait(&window)
		came := false
		for event in display.next_event(&window) {
			came = interface.input_add(&input, event) || came
		}
		if came {
			frame_draw(&window)
		}
	}
}
