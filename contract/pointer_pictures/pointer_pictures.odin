// The format of a pointer theme file (docs/POINTERS.md, section 3): the
// pointer pictures of a whole theme in one file, which the kernel tool
// writes and the compositor maps read-only and reads in place. All numbers
// are little-endian; each header has a fixed size; no field depends on a
// language.
//
//   Header         512 bytes, at 0
//   Shape_Entry    16 bytes, shape_count times, at 512
//   Picture_Entry  32 bytes, picture_count times, after the shapes
//   zero bytes to a multiple of 64
//   pixels         4 bytes each (0xAARRGGBB, premultiplied alpha), at pixel_offset
//
// A reader does not trust the file: validate checks each offset, count and
// pixel once, and the reads after it need no check.
//
// See [pointer theme file](term:pointer-theme-file),
// [pointer picture](term:pointer-picture) and [hot spot](term:hot-spot).
package pointer_pictures

MAGIC :: u64(0x535245544E494F50) // The bytes "POINTERS".
VERSION :: 1 // The version of the format. A reader refuses another.
HEADER_SIZE :: 512 // The bytes of `Header`.
SHAPE_ENTRY_SIZE :: 16 // The bytes of `Shape_Entry`.
PICTURE_ENTRY_SIZE :: 32 // The bytes of `Picture_Entry`.
PIXEL_ALIGNMENT :: 64 // The pixels start on a multiple of 64 bytes.
NAME_CAPACITY :: 32 // The bytes of the name of a theme.
LICENSE_CAPACITY :: 32 // The bytes of the SPDX identifier of the license.
ATTRIBUTION_CAPACITY :: 400 // The bytes of the attribution.
SIZE_COUNT_LIMIT :: 8 // The nominal sizes of one shape.
FRAME_COUNT_LIMIT :: 256 // The frames of the animation of one shape.
PICTURE_SIDE_LIMIT :: 256 // The largest width, height and nominal size.
DELAY_LIMIT :: 60_000 // Milliseconds: the longest frame of an animation.
SHAPE_COUNT_LIMIT :: 256 // The shapes of one file.
PICTURE_COUNT_LIMIT :: 1 << 16 // The pictures of one file.

// The names of the pointer theme files in the resource table of the boot
// image (kerneltool pointers). The compositor takes the first one that the
// boot image has: the theme of the owner when the build had its input.
RESOURCE_OF_THE_OWNER :: "pointers_posy" // The theme of the owner.
RESOURCE_OF_THE_SYSTEM :: "pointers_system" // The theme of the system.
// The order in which the compositor looks for a theme.
@(rodata)
RESOURCE_PREFERENCE := [?]string{RESOURCE_OF_THE_OWNER, RESOURCE_OF_THE_SYSTEM}

// The pointer shapes of the system. Zero is the arrow: a zero record asks
// for the default. A new shape is a new number at the end.
Pointer_Shape :: enum u32 {
	Arrow                        = 0, // The default: point at a thing.
	Text                         = 1, // Over a text that the input can choose or edit.
	Pointing_Hand                = 2, // Over a link or a button.
	Move                         = 3, // Over a thing that moves when dragged.
	Grab                         = 4, // Over a thing that the input can take.
	Grabbing                     = 5, // While the input holds a thing.
	Wait                         = 6, // The program cannot take input now.
	Busy_With_Arrow              = 7, // The program works, and takes input.
	Forbidden                    = 8, // The action under the pointer is not allowed.
	Help                         = 9, // Over a thing that has help.
	Crosshair                    = 10, // A precise place: a picker of pixels.
	Resize_Left_Right            = 11, // Over a border that resizes left and right.
	Resize_Up_Down               = 12, // Over a border that resizes up and down.
	Resize_Top_Left_Bottom_Right = 13, // Over a corner that resizes on that diagonal.
	Resize_Top_Right_Bottom_Left = 14, // Over a corner that resizes on that diagonal.
}

// The name of each shape, as the manifest, the log and the compositor
// export write it.
@(rodata)
SHAPE_NAMES := [Pointer_Shape]string {
	.Arrow                        = "arrow",
	.Text                         = "text",
	.Pointing_Hand                = "pointing_hand",
	.Move                         = "move",
	.Grab                         = "grab",
	.Grabbing                     = "grabbing",
	.Wait                         = "wait",
	.Busy_With_Arrow              = "busy_with_arrow",
	.Forbidden                    = "forbidden",
	.Help                         = "help",
	.Crosshair                    = "crosshair",
	.Resize_Left_Right            = "resize_left_right",
	.Resize_Up_Down               = "resize_up_down",
	.Resize_Top_Left_Bottom_Right = "resize_top_left_bottom_right",
	.Resize_Top_Right_Bottom_Left = "resize_top_right_bottom_left",
}

// shape_of_name gives the shape with this name.
shape_of_name :: proc "contextless" (name: string) -> (shape: Pointer_Shape, found: bool) {
	for candidate, value in SHAPE_NAMES {
		if candidate == name {
			return value, true
		}
	}
	return .Arrow, false
}

// shape_name gives the name of a shape number, or "" for a number out of
// the enum.
shape_name :: proc "contextless" (number: u32) -> string {
	if number > u32(max(Pointer_Shape)) {
		return ""
	}
	return SHAPE_NAMES[Pointer_Shape(number)]
}

// The first 512 bytes of a pointer theme file.
Header :: struct {
	magic:         u64, // MAGIC.
	version:       u32, // VERSION.
	shape_count:   u32, // The shape entries.
	picture_count: u32, // The picture entries.
	reserved:      u32, // 0.
	pixel_offset:  u64, // From the start of the file: the first multiple of 64 after the tables.
	pixel_size:    u64, // Bytes of pixels, to the end of the file.
	file_size:     u64, // The bytes of the file.
	theme_name:    [NAME_CAPACITY]u8, // ASCII 32 to 126, then zero bytes.
	license:       [LICENSE_CAPACITY]u8, // An SPDX identifier.
	attribution:   [ATTRIBUTION_CAPACITY]u8, // Who made the pictures, the source, and what the tool changed.
}

// The pictures of one shape: size_count * frame_count entries of the
// picture table from first_picture, the frames of the smallest size first.
Shape_Entry :: struct {
	shape:         u32, // A number of Pointer_Shape.
	first_picture: u32, // The first picture entry of the shape.
	size_count:    u32, // The nominal sizes, 1 to SIZE_COUNT_LIMIT.
	frame_count:   u32, // The frames of each size, 1 to FRAME_COUNT_LIMIT.
}

// One picture: one frame of one shape at one nominal size.
Picture_Entry :: struct {
	nominal_size:       u32, // The size that the theme names: 24, 32, 48.
	width:              u32, // Pixels, at most PICTURE_SIDE_LIMIT.
	height:             u32, // Pixels, at most PICTURE_SIDE_LIMIT.
	hot_spot_x:         u32, // The pixel that points, from the left: below width.
	hot_spot_y:         u32, // The pixel that points, from the top: below height.
	delay_milliseconds: u32, // To the next frame. 0 for a shape with one frame.
	pixel_offset:       u64, // From pixel_offset of the header.
}

#assert(size_of(Header) == HEADER_SIZE)
#assert(size_of(Shape_Entry) == SHAPE_ENTRY_SIZE)
#assert(size_of(Picture_Entry) == PICTURE_ENTRY_SIZE)

// pixel_offset_for gives where the pixels start for these counts.
pixel_offset_for :: proc "contextless" (shape_count, picture_count: u64) -> u64 {
	tables := u64(HEADER_SIZE) + shape_count * SHAPE_ENTRY_SIZE + picture_count * PICTURE_ENTRY_SIZE
	return (tables + PIXEL_ALIGNMENT - 1) / PIXEL_ALIGNMENT * PIXEL_ALIGNMENT
}

// The part of the file where a validation found a problem.
Part :: enum u32 {
	None,
	File,
	Header,
	Shapes,
	Pictures,
	Pixels,
}

// The rule that the file breaks.
Problem_Kind :: enum u32 {
	None,
	Too_Short, // The file is smaller than what the field needs.
	Not_Aligned, // The file does not start on a multiple of 8.
	Wrong_Magic,
	Wrong_Version,
	Wrong_Size, // file_size is not the size of the file.
	Too_Many, // A count above its limit.
	Wrong_Offset, // pixel_offset is not the first multiple of 64 after the tables.
	Wrong_Text, // A character out of ASCII 32 to 126, or a character after a zero byte.
	Empty_Text, // The theme name or the license is empty.
	Out_Of_Order, // The shape numbers do not increase.
	Unknown_Shape, // A shape number out of the enum.
	No_Arrow, // The theme has no arrow: the shape that the reader shows by default.
	Out_Of_Range, // A range that passes the end of its table or area.
	Zero, // A count or a size that must not be 0.
	Hot_Spot_Outside, // The hot spot is not a pixel of the picture.
	Sizes_Not_Increasing, // A size is not larger than the size before it.
	Frames_Differ, // Two frames of one size have two nominal sizes.
	Wrong_Delay, // A delay of 0 in an animation, or above the limit, or a delay with one frame.
	Not_Premultiplied, // A channel of a pixel is above its alpha.
}

// The field that holds the bad value.
Field :: enum u32 {
	None,
	Size,
	Address,
	Magic,
	Version,
	File_Size,
	Shape_Count,
	Picture_Count,
	Pixel_Offset,
	Pixel_Size,
	Theme_Name,
	License,
	Attribution,
	Shape,
	First_Picture,
	Size_Count,
	Frame_Count,
	Nominal_Size,
	Width,
	Height,
	Hot_Spot_X,
	Hot_Spot_Y,
	Delay,
	Picture_Pixels,
	Pixel,
}

// Problem: what validate found. Zero is no problem. index is the entry of
// the table (or the pixel of a picture); value is the bad value and limit
// the value that the rule allows.
Problem :: struct {
	kind:  Problem_Kind,
	part:  Part,
	field: Field,
	index: u64,
	value: u64,
	limit: u64,
}

@(private)
problem_of :: proc "contextless" (kind: Problem_Kind, part: Part, field: Field, index, value, limit: u64) -> Problem {
	return {kind = kind, part = part, field = field, index = index, value = value, limit = limit}
}

// text_check checks a text field: ASCII 32 to 126, then zero bytes only.
@(private)
text_check :: proc "contextless" (bytes: []u8, field: Field, may_be_empty: bool) -> Problem {
	end := len(bytes)
	for byte, index in bytes {
		if byte == 0 {
			end = index
			break
		}
		if byte < 32 || byte > 126 {
			return problem_of(.Wrong_Text, .Header, field, u64(index), u64(byte), 126)
		}
	}
	for index in end ..< len(bytes) {
		if bytes[index] != 0 {
			return problem_of(.Wrong_Text, .Header, field, u64(index), u64(bytes[index]), 0)
		}
	}
	if end == 0 && !may_be_empty {
		return problem_of(.Empty_Text, .Header, field, 0, 0, 1)
	}
	return {}
}

// validate checks the whole file once. After it gives no problem, the
// functions below read the file with no check.
validate :: proc "contextless" (file: []u8) -> Problem {
	if len(file) < HEADER_SIZE {
		return problem_of(.Too_Short, .File, .Size, 0, u64(len(file)), HEADER_SIZE)
	}
	if uintptr(raw_data(file)) % 8 != 0 {
		return problem_of(.Not_Aligned, .File, .Address, 0, u64(uintptr(raw_data(file)) % 8), 0)
	}
	head := (^Header)(raw_data(file))^ // A copy: the checks and the reads after them see one value.
	if head.magic != MAGIC {
		return problem_of(.Wrong_Magic, .Header, .Magic, 0, head.magic, MAGIC)
	}
	if head.version != VERSION {
		return problem_of(.Wrong_Version, .Header, .Version, 0, u64(head.version), VERSION)
	}
	if head.file_size != u64(len(file)) {
		return problem_of(.Wrong_Size, .Header, .File_Size, 0, head.file_size, u64(len(file)))
	}
	if head.shape_count == 0 {
		return problem_of(.Zero, .Header, .Shape_Count, 0, 0, 1)
	}
	if head.shape_count > SHAPE_COUNT_LIMIT {
		return problem_of(.Too_Many, .Header, .Shape_Count, 0, u64(head.shape_count), SHAPE_COUNT_LIMIT)
	}
	if head.picture_count == 0 {
		return problem_of(.Zero, .Header, .Picture_Count, 0, 0, 1)
	}
	if head.picture_count > PICTURE_COUNT_LIMIT {
		return problem_of(.Too_Many, .Header, .Picture_Count, 0, u64(head.picture_count), PICTURE_COUNT_LIMIT)
	}
	expected_offset := pixel_offset_for(u64(head.shape_count), u64(head.picture_count))
	if head.pixel_offset != expected_offset {
		return problem_of(.Wrong_Offset, .Header, .Pixel_Offset, 0, head.pixel_offset, expected_offset)
	}
	if head.pixel_offset > head.file_size || head.pixel_size != head.file_size - head.pixel_offset {
		return problem_of(.Out_Of_Range, .Header, .Pixel_Size, 0, head.pixel_size, head.file_size - min(head.pixel_offset, head.file_size))
	}
	if head.pixel_size % 4 != 0 {
		return problem_of(.Wrong_Size, .Header, .Pixel_Size, 0, head.pixel_size, head.pixel_size / 4 * 4)
	}
	if problem := text_check(head.theme_name[:], .Theme_Name, false); problem.kind != .None {
		return problem
	}
	if problem := text_check(head.license[:], .License, false); problem.kind != .None {
		return problem
	}
	if problem := text_check(head.attribution[:], .Attribution, true); problem.kind != .None {
		return problem
	}

	shapes := ([^]Shape_Entry)(raw_data(file[HEADER_SIZE:]))[:head.shape_count]
	pictures := ([^]Picture_Entry)(raw_data(file[HEADER_SIZE + int(head.shape_count) * SHAPE_ENTRY_SIZE:]))[:head.picture_count]
	pixels := ([^]u32)(raw_data(file[head.pixel_offset:]))[:head.pixel_size / 4]
	has_arrow := false
	for index in 0 ..< len(shapes) {
		entry := shapes[index]
		at := u64(index)
		if entry.shape > u32(max(Pointer_Shape)) {
			return problem_of(.Unknown_Shape, .Shapes, .Shape, at, u64(entry.shape), u64(max(Pointer_Shape)))
		}
		if index > 0 && entry.shape <= shapes[index - 1].shape {
			return problem_of(.Out_Of_Order, .Shapes, .Shape, at, u64(entry.shape), u64(shapes[index - 1].shape) + 1)
		}
		has_arrow ||= entry.shape == u32(Pointer_Shape.Arrow)
		if entry.size_count == 0 {
			return problem_of(.Zero, .Shapes, .Size_Count, at, 0, 1)
		}
		if entry.size_count > SIZE_COUNT_LIMIT {
			return problem_of(.Too_Many, .Shapes, .Size_Count, at, u64(entry.size_count), SIZE_COUNT_LIMIT)
		}
		if entry.frame_count == 0 {
			return problem_of(.Zero, .Shapes, .Frame_Count, at, 0, 1)
		}
		if entry.frame_count > FRAME_COUNT_LIMIT {
			return problem_of(.Too_Many, .Shapes, .Frame_Count, at, u64(entry.frame_count), FRAME_COUNT_LIMIT)
		}
		count := u64(entry.size_count) * u64(entry.frame_count)
		if u64(entry.first_picture) > u64(head.picture_count) || count > u64(head.picture_count) - u64(entry.first_picture) {
			return problem_of(.Out_Of_Range, .Shapes, .First_Picture, at, u64(entry.first_picture), u64(head.picture_count) - min(count, u64(head.picture_count)))
		}
		// The sizes increase, and the frames of one size have its size.
		for size in 0 ..< entry.size_count {
			first := pictures[entry.first_picture + size * entry.frame_count]
			if size > 0 && first.nominal_size <= pictures[entry.first_picture + (size - 1) * entry.frame_count].nominal_size {
				return problem_of(.Sizes_Not_Increasing, .Pictures, .Nominal_Size, u64(entry.first_picture + size * entry.frame_count), u64(first.nominal_size), u64(pictures[entry.first_picture + (size - 1) * entry.frame_count].nominal_size) + 1)
			}
			for frame in 1 ..< entry.frame_count {
				number := entry.first_picture + size * entry.frame_count + frame
				if pictures[number].nominal_size != first.nominal_size {
					return problem_of(.Frames_Differ, .Pictures, .Nominal_Size, u64(number), u64(pictures[number].nominal_size), u64(first.nominal_size))
				}
			}
			for frame in 0 ..< entry.frame_count {
				number := entry.first_picture + size * entry.frame_count + frame
				delay := pictures[number].delay_milliseconds
				if entry.frame_count == 1 && delay != 0 {
					return problem_of(.Wrong_Delay, .Pictures, .Delay, u64(number), u64(delay), 0)
				}
				if entry.frame_count > 1 && (delay == 0 || delay > DELAY_LIMIT) {
					return problem_of(.Wrong_Delay, .Pictures, .Delay, u64(number), u64(delay), delay == 0 ? 1 : DELAY_LIMIT)
				}
			}
		}
	}
	if !has_arrow {
		return problem_of(.No_Arrow, .Shapes, .Shape, 0, u64(shapes[0].shape), 0)
	}
	for index in 0 ..< len(pictures) {
		picture := pictures[index]
		at := u64(index)
		if picture.nominal_size == 0 || picture.nominal_size > PICTURE_SIDE_LIMIT {
			return problem_of(picture.nominal_size == 0 ? .Zero : .Too_Many, .Pictures, .Nominal_Size, at, u64(picture.nominal_size), PICTURE_SIDE_LIMIT)
		}
		if picture.width == 0 || picture.width > PICTURE_SIDE_LIMIT {
			return problem_of(picture.width == 0 ? .Zero : .Too_Many, .Pictures, .Width, at, u64(picture.width), PICTURE_SIDE_LIMIT)
		}
		if picture.height == 0 || picture.height > PICTURE_SIDE_LIMIT {
			return problem_of(picture.height == 0 ? .Zero : .Too_Many, .Pictures, .Height, at, u64(picture.height), PICTURE_SIDE_LIMIT)
		}
		if picture.hot_spot_x >= picture.width {
			return problem_of(.Hot_Spot_Outside, .Pictures, .Hot_Spot_X, at, u64(picture.hot_spot_x), u64(picture.width) - 1)
		}
		if picture.hot_spot_y >= picture.height {
			return problem_of(.Hot_Spot_Outside, .Pictures, .Hot_Spot_Y, at, u64(picture.hot_spot_y), u64(picture.height) - 1)
		}
		if picture.delay_milliseconds > DELAY_LIMIT {
			return problem_of(.Wrong_Delay, .Pictures, .Delay, at, u64(picture.delay_milliseconds), DELAY_LIMIT)
		}
		bytes := u64(picture.width) * u64(picture.height) * 4
		if picture.pixel_offset % 4 != 0 {
			return problem_of(.Not_Aligned, .Pictures, .Picture_Pixels, at, picture.pixel_offset, picture.pixel_offset / 4 * 4)
		}
		if picture.pixel_offset > head.pixel_size || bytes > head.pixel_size - picture.pixel_offset {
			return problem_of(.Out_Of_Range, .Pictures, .Picture_Pixels, at, picture.pixel_offset, head.pixel_size - min(bytes, head.pixel_size))
		}
	}
	// Each pixel of the area, once: a channel above its alpha would make the
	// blend pass 255. The pictures cover the area, or share parts of it.
	for value, index in pixels {
		alpha := value >> 24
		if value >> 16 & 0xFF > alpha || value >> 8 & 0xFF > alpha || value & 0xFF > alpha {
			return problem_of(.Not_Premultiplied, .Pixels, .Pixel, u64(index), u64(value), u64(alpha))
		}
	}
	return {}
}

// The functions below read a file that validate accepted.

header :: proc "contextless" (file: []u8) -> ^Header {
	return (^Header)(raw_data(file))
}

shape_entries :: proc "contextless" (file: []u8) -> []Shape_Entry {
	return ([^]Shape_Entry)(raw_data(file[HEADER_SIZE:]))[:header(file).shape_count]
}

picture_entries :: proc "contextless" (file: []u8) -> []Picture_Entry {
	head := header(file)
	return ([^]Picture_Entry)(raw_data(file[HEADER_SIZE + int(head.shape_count) * SHAPE_ENTRY_SIZE:]))[:head.picture_count]
}

// pixels_of gives the pixels of a picture, line after line.
pixels_of :: proc "contextless" (file: []u8, picture: Picture_Entry) -> []u32 {
	return ([^]u32)(raw_data(file[header(file).pixel_offset + picture.pixel_offset:]))[:picture.width * picture.height]
}

// text_of gives a text field without its zero bytes.
text_of :: proc "contextless" (bytes: []u8) -> string {
	for byte, index in bytes {
		if byte == 0 {
			return string(bytes[:index])
		}
	}
	return string(bytes)
}

// shape_entry_of gives the entry of a shape, if the theme has it.
shape_entry_of :: proc "contextless" (file: []u8, shape: Pointer_Shape) -> (entry: Shape_Entry, found: bool) {
	for candidate in shape_entries(file) {
		if candidate.shape == u32(shape) {
			return candidate, true
		}
	}
	return {}, false
}

// What choose gives: the picture to draw, its pixels, the shape that the
// theme gave (the arrow if it has not the shape asked), and the time in
// milliseconds when the next frame starts (0: the shape has one frame).
Chosen :: struct {
	picture:    Picture_Entry,
	pixels:     []u32,
	shape:      Pointer_Shape,
	next_frame: u64,
}

// choose gives the picture of a shape for a nominal size, at a time in
// milliseconds: the smallest size of the shape that is at least the size
// asked, else its largest size; the frame of an animation from the time.
choose :: proc "contextless" (file: []u8, shape: Pointer_Shape, nominal_size: u32, time_milliseconds: u64) -> Chosen {
	chosen: Chosen
	entry, found := shape_entry_of(file, shape)
	chosen.shape = shape
	if !found {
		entry, _ = shape_entry_of(file, .Arrow)
		chosen.shape = .Arrow
	}
	pictures := picture_entries(file)
	size := entry.size_count - 1
	for candidate in 0 ..< entry.size_count {
		if pictures[entry.first_picture + candidate * entry.frame_count].nominal_size >= nominal_size {
			size = candidate
			break
		}
	}
	first := entry.first_picture + size * entry.frame_count
	frame: u32 = 0
	if entry.frame_count > 1 {
		period: u64 = 0
		for index in 0 ..< entry.frame_count {
			period += u64(pictures[first + index].delay_milliseconds)
		}
		place := time_milliseconds % period
		start := time_milliseconds - place // The time when this period started.
		for place >= u64(pictures[first + frame].delay_milliseconds) {
			place -= u64(pictures[first + frame].delay_milliseconds)
			start += u64(pictures[first + frame].delay_milliseconds)
			frame += 1
		}
		chosen.next_frame = start + u64(pictures[first + frame].delay_milliseconds)
	}
	chosen.picture = pictures[first + frame]
	chosen.pixels = pixels_of(file, chosen.picture)
	return chosen
}

@(rodata)
PART_NAMES := [Part]string {
	.None     = "",
	.File     = "the file",
	.Header   = "the header",
	.Shapes   = "the shape table",
	.Pictures = "the picture table",
	.Pixels   = "the pixels",
}

@(rodata)
FIELD_NAMES := [Field]string {
	.None           = "",
	.Size           = "size",
	.Address        = "address",
	.Magic          = "magic",
	.Version        = "version",
	.File_Size      = "file_size",
	.Shape_Count    = "shape_count",
	.Picture_Count  = "picture_count",
	.Pixel_Offset   = "pixel_offset",
	.Pixel_Size     = "pixel_size",
	.Theme_Name     = "theme_name",
	.License        = "license",
	.Attribution    = "attribution",
	.Shape          = "shape",
	.First_Picture  = "first_picture",
	.Size_Count     = "size_count",
	.Frame_Count    = "frame_count",
	.Nominal_Size   = "nominal_size",
	.Width          = "width",
	.Height         = "height",
	.Hot_Spot_X     = "hot_spot_x",
	.Hot_Spot_Y     = "hot_spot_y",
	.Delay          = "delay_milliseconds",
	.Picture_Pixels = "pixel_offset of the picture",
	.Pixel          = "pixel",
}

@(rodata)
KIND_SENTENCES := [Problem_Kind]string {
	.None                 = "no problem",
	.Too_Short            = "is shorter than the header",
	.Not_Aligned          = "is not aligned",
	.Wrong_Magic          = "is not the magic \"POINTERS\"",
	.Wrong_Version        = "is not the version of this reader",
	.Wrong_Size           = "is not the size of the file",
	.Too_Many             = "is above its limit",
	.Wrong_Offset         = "is not the first multiple of 64 after the tables",
	.Wrong_Text           = "has a byte that is not ASCII 32 to 126 before its zero bytes",
	.Empty_Text           = "is empty",
	.Out_Of_Order         = "does not increase from the entry before",
	.Unknown_Shape        = "is not a pointer shape of the system",
	.No_Arrow             = "has no arrow, the shape that a reader shows by default",
	.Out_Of_Range         = "passes the end of its table or area",
	.Zero                 = "is 0",
	.Hot_Spot_Outside     = "is not a pixel of the picture",
	.Sizes_Not_Increasing = "is not larger than the size before it",
	.Frames_Differ        = "differs from the first frame of its size",
	.Wrong_Delay          = "is not a delay of this picture",
	.Not_Premultiplied    = "has a channel above its alpha",
}

// sentence writes a problem as one line for a reader, for example
// "the picture table, entry 3: hot_spot_x is not a pixel of the picture
// (value 40, limit 31)". It gives the part of buffer that it wrote.
sentence :: proc "contextless" (problem: Problem, buffer: []u8) -> string {
	count := 0
	write :: proc "contextless" (buffer: []u8, count: ^int, text: string) {
		for index in 0 ..< len(text) {
			if count^ < len(buffer) {
				buffer[count^] = text[index]
				count^ += 1
			}
		}
	}
	number :: proc "contextless" (buffer: []u8, count: ^int, value: u64) {
		digits: [20]u8
		used := 0
		rest := value
		for {
			digits[len(digits) - 1 - used] = u8('0' + rest % 10)
			used += 1
			rest /= 10
			if rest == 0 {
				break
			}
		}
		write(buffer, count, string(digits[len(digits) - used:]))
	}
	if problem.kind == .None {
		write(buffer, &count, KIND_SENTENCES[.None])
		return string(buffer[:count])
	}
	write(buffer, &count, PART_NAMES[problem.part])
	if problem.part == .Shapes || problem.part == .Pictures || problem.part == .Pixels {
		write(buffer, &count, problem.part == .Pixels ? ", pixel " : ", entry ")
		number(buffer, &count, problem.index)
	}
	write(buffer, &count, ": ")
	write(buffer, &count, FIELD_NAMES[problem.field])
	write(buffer, &count, " ")
	write(buffer, &count, KIND_SENTENCES[problem.kind])
	write(buffer, &count, " (value ")
	number(buffer, &count, problem.value)
	write(buffer, &count, ", limit ")
	number(buffer, &count, problem.limit)
	write(buffer, &count, ")")
	return string(buffer[:count])
}
