#+build !freestanding
package pointer_pictures

import "core:testing"

// sample_file makes a valid file: the arrow at the sizes 4 and 8, one frame
// each; wait at the size 4, three frames of 100 ms. The wait frames share
// the pixels of the arrow at 4.
@(private = "file")
sample_file :: proc() -> []u8 {
	shapes := [?]Shape_Entry{{shape = u32(Pointer_Shape.Arrow), first_picture = 0, size_count = 2, frame_count = 1}, {shape = u32(Pointer_Shape.Wait), first_picture = 2, size_count = 1, frame_count = 3}}
	pictures := [?]Picture_Entry {
		{nominal_size = 4, width = 4, height = 4, hot_spot_x = 1, hot_spot_y = 2, pixel_offset = 0},
		{nominal_size = 8, width = 8, height = 6, hot_spot_x = 7, hot_spot_y = 5, pixel_offset = 64},
		{nominal_size = 4, width = 4, height = 4, delay_milliseconds = 100, pixel_offset = 0},
		{nominal_size = 4, width = 4, height = 4, delay_milliseconds = 100, pixel_offset = 0},
		{nominal_size = 4, width = 4, height = 4, delay_milliseconds = 100, pixel_offset = 0},
	}
	pixel_size := u64(16 * 4 + 48 * 4)
	offset := pixel_offset_for(len(shapes), len(pictures))
	file := make([]u8, offset + pixel_size)
	head := (^Header)(raw_data(file))
	head^ = {magic = MAGIC, version = VERSION, shape_count = len(shapes), picture_count = len(pictures), pixel_offset = offset, pixel_size = pixel_size, file_size = u64(len(file))}
	copy(head.theme_name[:], "sample")
	copy(head.license[:], "MIT")
	copy(head.attribution[:], "made by the test")
	copy(([^]Shape_Entry)(raw_data(file[HEADER_SIZE:]))[:len(shapes)], shapes[:])
	copy(([^]Picture_Entry)(raw_data(file[HEADER_SIZE + len(shapes) * SHAPE_ENTRY_SIZE:]))[:len(pictures)], pictures[:])
	pixels := ([^]u32)(raw_data(file[offset:]))[:pixel_size / 4]
	for &pixel, index in pixels {
		alpha := u32(index * 17 % 256)
		pixel = alpha << 24 | (alpha / 2) << 16 | (alpha / 3) << 8 | alpha
	}
	return file
}

@(test)
a_sample_file_is_valid :: proc(t: ^testing.T) {
	file := sample_file()
	defer delete(file)
	problem := validate(file)
	testing.expect_value(t, problem.kind, Problem_Kind.None)
	testing.expect_value(t, text_of(header(file).theme_name[:]), "sample")
	testing.expect_value(t, len(shape_entries(file)), 2)
}

@(test)
choose_gives_the_size_and_the_frame :: proc(t: ^testing.T) {
	file := sample_file()
	defer delete(file)
	chosen := choose(file, .Arrow, 6, 0)
	testing.expect_value(t, chosen.picture.nominal_size, 8)
	testing.expect_value(t, len(chosen.pixels), 48)
	testing.expect_value(t, chosen.next_frame, 0)
	chosen = choose(file, .Arrow, 100, 0) // Larger than each size: the largest.
	testing.expect_value(t, chosen.picture.nominal_size, 8)
	chosen = choose(file, .Arrow, 1, 0)
	testing.expect_value(t, chosen.picture.nominal_size, 4)
	chosen = choose(file, .Text, 4, 0) // Not in the theme: the arrow.
	testing.expect_value(t, chosen.shape, Pointer_Shape.Arrow)
	// Three frames of 100 ms: at 1250 ms the period started at 1200, frame 0;
	// at 1399 frame 1, next at 1400.
	chosen = choose(file, .Wait, 4, 1250)
	testing.expect_value(t, chosen.shape, Pointer_Shape.Wait)
	testing.expect_value(t, chosen.next_frame, 1300)
	chosen = choose(file, .Wait, 4, 1399)
	testing.expect_value(t, chosen.next_frame, 1400)
	chosen = choose(file, .Wait, 4, 1400)
	testing.expect_value(t, chosen.next_frame, 1500)
}

@(test)
names_of_the_shapes :: proc(t: ^testing.T) {
	for name, shape in SHAPE_NAMES {
		found, ok := shape_of_name(name)
		testing.expect(t, ok)
		testing.expect_value(t, found, shape)
		testing.expect_value(t, shape_name(u32(shape)), name)
	}
	_, ok := shape_of_name("cursor")
	testing.expect(t, !ok)
	testing.expect_value(t, shape_name(15), "")
}

// A damage: a change of the sample file, and the problem that it must give.
@(private = "file")
Damage :: struct {
	about:  string,
	change: proc(file: []u8),
	kind:   Problem_Kind,
	field:  Field,
}

@(private = "file")
head_of :: proc(file: []u8) -> ^Header {
	return (^Header)(raw_data(file))
}

@(private = "file")
shape_at :: proc(file: []u8, index: int) -> ^Shape_Entry {
	return &([^]Shape_Entry)(raw_data(file[HEADER_SIZE:]))[index]
}

@(private = "file")
picture_at :: proc(file: []u8, index: int) -> ^Picture_Entry {
	return &([^]Picture_Entry)(raw_data(file[HEADER_SIZE + 2 * SHAPE_ENTRY_SIZE:]))[index]
}

// Each field of each table, damaged one at a time: validate names the rule
// and the field.
@(test)
each_damaged_field_is_found :: proc(t: ^testing.T) {
	damages := [?]Damage {
		{"magic", proc(file: []u8) {head_of(file).magic += 1}, .Wrong_Magic, .Magic},
		{"version", proc(file: []u8) {head_of(file).version = 2}, .Wrong_Version, .Version},
		{"file_size", proc(file: []u8) {head_of(file).file_size -= 4}, .Wrong_Size, .File_Size},
		{"shape_count 0", proc(file: []u8) {head_of(file).shape_count = 0}, .Zero, .Shape_Count},
		{"shape_count too many", proc(file: []u8) {head_of(file).shape_count = 1000}, .Too_Many, .Shape_Count},
		{"shape_count changes the offset", proc(file: []u8) {head_of(file).shape_count = 3}, .Wrong_Offset, .Pixel_Offset},
		{"picture_count 0", proc(file: []u8) {head_of(file).picture_count = 0}, .Zero, .Picture_Count},
		{"picture_count too many", proc(file: []u8) {head_of(file).picture_count = 1 << 20}, .Too_Many, .Picture_Count},
		{"pixel_offset", proc(file: []u8) {head_of(file).pixel_offset += 64}, .Wrong_Offset, .Pixel_Offset},
		{"pixel_size", proc(file: []u8) {head_of(file).pixel_size += 4}, .Out_Of_Range, .Pixel_Size},
		{"theme_name empty", proc(file: []u8) {head_of(file).theme_name = {}}, .Empty_Text, .Theme_Name},
		{"theme_name control byte", proc(file: []u8) {head_of(file).theme_name[1] = 10}, .Wrong_Text, .Theme_Name},
		{"theme_name byte after the end", proc(file: []u8) {head_of(file).theme_name[20] = 'x'}, .Wrong_Text, .Theme_Name},
		{"license empty", proc(file: []u8) {head_of(file).license = {}}, .Empty_Text, .License},
		{"license byte 200", proc(file: []u8) {head_of(file).license[0] = 200}, .Wrong_Text, .License},
		{"attribution byte 127", proc(file: []u8) {head_of(file).attribution[3] = 127}, .Wrong_Text, .Attribution},
		{"shape out of the enum", proc(file: []u8) {shape_at(file, 1).shape = 99}, .Unknown_Shape, .Shape},
		{"shapes out of order", proc(file: []u8) {shape_at(file, 1).shape = 0}, .Out_Of_Order, .Shape},
		{"no arrow", proc(file: []u8) {shape_at(file, 0).shape = 1}, .No_Arrow, .Shape},
		{"size_count 0", proc(file: []u8) {shape_at(file, 0).size_count = 0}, .Zero, .Size_Count},
		{"size_count too many", proc(file: []u8) {shape_at(file, 0).size_count = 9}, .Too_Many, .Size_Count},
		{"frame_count 0", proc(file: []u8) {shape_at(file, 1).frame_count = 0}, .Zero, .Frame_Count},
		{"frame_count too many", proc(file: []u8) {shape_at(file, 1).frame_count = 300}, .Too_Many, .Frame_Count},
		{"first_picture past the table", proc(file: []u8) {shape_at(file, 1).first_picture = 3}, .Out_Of_Range, .First_Picture},
		{"first_picture far past the table", proc(file: []u8) {shape_at(file, 1).first_picture = 0xFFFF_FFFF}, .Out_Of_Range, .First_Picture},
		{"sizes not increasing", proc(file: []u8) {picture_at(file, 1).nominal_size = 4}, .Sizes_Not_Increasing, .Nominal_Size},
		{"frames of two sizes", proc(file: []u8) {picture_at(file, 3).nominal_size = 5}, .Frames_Differ, .Nominal_Size},
		{"a delay with one frame", proc(file: []u8) {picture_at(file, 0).delay_milliseconds = 10}, .Wrong_Delay, .Delay},
		{"a delay of 0 in an animation", proc(file: []u8) {picture_at(file, 3).delay_milliseconds = 0}, .Wrong_Delay, .Delay},
		{"a delay above the limit", proc(file: []u8) {picture_at(file, 4).delay_milliseconds = DELAY_LIMIT + 1}, .Wrong_Delay, .Delay},
		{"nominal_size 0", proc(file: []u8) {picture_at(file, 0).nominal_size = 0; picture_at(file, 1).nominal_size = 1; for i in 2 ..< 5 {picture_at(file, i).nominal_size = 0}}, .Zero, .Nominal_Size},
		{"nominal_size too large", proc(file: []u8) {picture_at(file, 1).nominal_size = 300}, .Too_Many, .Nominal_Size},
		{"width 0", proc(file: []u8) {picture_at(file, 0).width = 0}, .Zero, .Width},
		{"width too large", proc(file: []u8) {picture_at(file, 1).width = 257}, .Too_Many, .Width},
		{"height 0", proc(file: []u8) {picture_at(file, 1).height = 0}, .Zero, .Height},
		{"height too large", proc(file: []u8) {picture_at(file, 0).height = 1000}, .Too_Many, .Height},
		{"hot_spot_x outside", proc(file: []u8) {picture_at(file, 0).hot_spot_x = 4}, .Hot_Spot_Outside, .Hot_Spot_X},
		{"hot_spot_y outside", proc(file: []u8) {picture_at(file, 1).hot_spot_y = 6}, .Hot_Spot_Outside, .Hot_Spot_Y},
		{"pixels not aligned", proc(file: []u8) {picture_at(file, 1).pixel_offset = 66}, .Not_Aligned, .Picture_Pixels},
		{"pixels past the end", proc(file: []u8) {picture_at(file, 1).pixel_offset = 128}, .Out_Of_Range, .Picture_Pixels},
		{"pixels far past the end", proc(file: []u8) {picture_at(file, 1).pixel_offset = 0xFFFF_FFFF_FFFF_FFF0}, .Out_Of_Range, .Picture_Pixels},
		{"a picture larger than the pixels", proc(file: []u8) {picture_at(file, 1).height = 7}, .Out_Of_Range, .Picture_Pixels},
		{"a pixel not premultiplied", proc(file: []u8) {head := head_of(file); ([^]u32)(raw_data(file[head.pixel_offset:]))[5] = 0x10_20_00_00}, .Not_Premultiplied, .Pixel},
	}
	buffer: [256]u8
	for damage in damages {
		file := sample_file()
		damage.change(file)
		problem := validate(file)
		if !testing.expectf(t, problem.kind == damage.kind && problem.field == damage.field, "%s: got %v %v: %s", damage.about, problem.kind, problem.field, sentence(problem, buffer[:])) {
			delete(file)
			continue
		}
		delete(file)
	}
}

// A file cut at each length, and the file at an address that is not
// aligned: no read passes the end, and each gives a problem.
@(test)
a_cut_file_is_refused :: proc(t: ^testing.T) {
	file := sample_file()
	defer delete(file)
	for length in 0 ..< len(file) {
		problem := validate(file[:length])
		testing.expectf(t, problem.kind != .None, "a file of %d bytes was accepted", length)
	}
	moved := make([]u8, len(file) + 8)
	defer delete(moved)
	copy(moved[4:], file)
	testing.expect_value(t, validate(moved[4:][:len(file)]).kind, Problem_Kind.Not_Aligned)
}

@(test)
the_sentence_of_a_problem :: proc(t: ^testing.T) {
	buffer: [256]u8
	text := sentence({kind = .Hot_Spot_Outside, part = .Pictures, field = .Hot_Spot_X, index = 3, value = 40, limit = 31}, buffer[:])
	testing.expect_value(t, text, "the picture table, entry 3: hot_spot_x is not a pixel of the picture (value 40, limit 31)")
	text = sentence({kind = .Wrong_Magic, part = .Header, field = .Magic, value = 7, limit = u64(MAGIC)}, buffer[:])
	testing.expect_value(t, text, "the header: magic is not the magic \"POINTERS\" (value 7, limit 6003937481631289168)")
}
