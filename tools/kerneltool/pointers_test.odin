package kerneltool

import "contract:pointer_pictures"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// An image of an Xcursor file that the tests write.
@(private = "file")
Test_Image :: struct {
	nominal_size, width, height, hot_spot_x, hot_spot_y, delay: u32,
}

// xcursor_write writes an Xcursor file with a comment chunk first, then
// the images, each pixel 0xFF000000 + its index (opaque, premultiplied).
@(private = "file")
xcursor_write :: proc(images: []Test_Image) -> []u8 {
	bytes := make([dynamic]u8, context.temp_allocator)
	word :: proc(bytes: ^[dynamic]u8, value: u32) {
		append(bytes, u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24))
	}
	entries := u32(len(images) + 1)
	word(&bytes, XCURSOR_MAGIC)
	word(&bytes, XCURSOR_FILE_HEADER)
	word(&bytes, 0x10000)
	word(&bytes, entries)
	position := XCURSOR_FILE_HEADER + entries * 12
	comment := "made by a test"
	word(&bytes, 0xFFFE0001)
	word(&bytes, 3)
	word(&bytes, position)
	position += 20 + u32(len(comment))
	for image in images {
		word(&bytes, XCURSOR_IMAGE_TYPE)
		word(&bytes, image.nominal_size)
		word(&bytes, position)
		position += XCURSOR_IMAGE_HEADER + image.width * image.height * 4
	}
	word(&bytes, 20)
	word(&bytes, 0xFFFE0001)
	word(&bytes, 3)
	word(&bytes, 1)
	word(&bytes, u32(len(comment)))
	append(&bytes, ..transmute([]u8)comment)
	for image in images {
		for value in ([?]u32{XCURSOR_IMAGE_HEADER, XCURSOR_IMAGE_TYPE, image.nominal_size, 1, image.width, image.height, image.hot_spot_x, image.hot_spot_y, image.delay}) {
			word(&bytes, value)
		}
		for index in 0 ..< image.width * image.height {
			word(&bytes, 0xFF000000 + index)
		}
	}
	return bytes[:]
}

@(private = "file")
two_sizes := [?]Test_Image{{nominal_size = 4, width = 4, height = 3, hot_spot_x = 1, hot_spot_y = 2}, {nominal_size = 8, width = 8, height = 6, hot_spot_x = 2, hot_spot_y = 4}}

@(test)
xcursor_reader_reads_each_image :: proc(t: ^testing.T) {
	file := xcursor_write(two_sizes[:])
	images := make([dynamic]Xcursor_Image, context.temp_allocator)
	testing.expect_value(t, xcursor_read(file, &images), "")
	testing.expect_value(t, len(images), 2)
	testing.expect_value(t, images[1].nominal_size, 8)
	testing.expect_value(t, images[1].hot_spot_y, 4)
	testing.expect_value(t, len(images[1].pixels), 48)
	testing.expect_value(t, images[1].pixels[47], 0xFF000000 + 47)
	free_all(context.temp_allocator)
}

// Each field of an Xcursor file, damaged: the reader gives the sentence
// that names it, and reads no byte out of the file.
@(test)
xcursor_reader_refuses_each_damage :: proc(t: ^testing.T) {
	Damage :: struct {
		offset: int, // The byte of the word to change.
		value:  u32,
		says:   string, // A part of the sentence.
	}
	file := xcursor_write(two_sizes[:])
	first_image := XCURSOR_FILE_HEADER + 3 * 12 + 20 + len("made by a test")
	damages := [?]Damage {
		{0, 0x12345678, "not \"Xcur\""},
		{4, 8, "the header has 8 bytes"},
		{4, 100000, "the header has 100000 bytes"},
		{12, 1 << 20, "entries of the table of contents do not fit"},
		{12, 100, "entries of the table of contents do not fit"},
		{XCURSOR_FILE_HEADER + 12 + 8, 1 << 30, "past the end of the file"},
		{first_image, 40, "the image header has 40 bytes"},
		{first_image + 8, 5, "the table of contents says"},
		{XCURSOR_FILE_HEADER + 12 + 4, 5, "the table of contents says"},
		{first_image + 12, 2, "the version 2"},
		{first_image + 16, 0, "each side must be 1 to 32767"},
		{first_image + 20, 0x8000, "each side must be 1 to 32767"},
		{first_image + 24, 4, "is not a pixel of the image"},
		{first_image + 28, 3, "is not a pixel of the image"},
		{first_image + 20, 3000, "pass the end of the file"},
	}
	for damage in damages {
		changed := make([]u8, len(file), context.temp_allocator)
		copy(changed, file)
		for byte in 0 ..< 4 {
			changed[damage.offset + byte] = u8(damage.value >> uint(8 * byte))
		}
		images := make([dynamic]Xcursor_Image, context.temp_allocator)
		problem := xcursor_read(changed, &images)
		testing.expectf(t, strings.contains(problem, damage.says), "the word at %d set to %d: got \"%s\", not \"%s\"", damage.offset, damage.value, problem, damage.says)
	}
	// A file cut at each length.
	for length in 0 ..< len(file) {
		images := make([dynamic]Xcursor_Image, context.temp_allocator)
		testing.expectf(t, xcursor_read(file[:length], &images) != "", "a file of %d bytes was accepted", length)
	}
	images := make([dynamic]Xcursor_Image, context.temp_allocator)
	testing.expect_value(t, xcursor_read(xcursor_write(nil), &images), "the file has no image")
	free_all(context.temp_allocator)
}

@(private = "file")
GRID_MANIFEST :: `# a test
theme Test theme
license MIT
attribution first line,
attribution second line
sizes 12 24
shape arrow hot 1 0
|XX
|X.X
shape wait hot 0 0
frame 100
|X
frame 200
|.
`

@(test)
manifest_of_grids_makes_a_valid_file :: proc(t: ^testing.T) {
	manifest, problem := manifest_parse("test.manifest", GRID_MANIFEST)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, manifest.attribution, "first line, second line")
	file, rows, made_problem := pointer_theme_make(manifest, "")
	testing.expect_value(t, made_problem, "")
	testing.expect_value(t, len(rows), 2)
	testing.expect_value(t, pointer_pictures.validate(file).kind, pointer_pictures.Problem_Kind.None)
	head := pointer_pictures.header(file)
	testing.expect_value(t, pointer_pictures.text_of(head.theme_name[:]), "Test theme")
	testing.expect_value(t, head.picture_count, 6) // The arrow at 2 sizes, wait at 2 sizes with 2 frames.
	// The arrow at 24: squares of 2 pixels, 3 squares wide; the hot spot is
	// the middle of the square 1,0.
	chosen := pointer_pictures.choose(file, .Arrow, 24, 0)
	testing.expect_value(t, chosen.picture.width, 6)
	testing.expect_value(t, chosen.picture.height, 4)
	testing.expect_value(t, chosen.picture.hot_spot_x, 3)
	testing.expect_value(t, chosen.picture.hot_spot_y, 1)
	testing.expect_value(t, chosen.pixels[0], 0xFF000000) // X
	testing.expect_value(t, chosen.pixels[6 * 2 + 2], 0xFFFFFFFF) // . at the square 1,1
	testing.expect_value(t, chosen.pixels[5], 0) // Nothing at the right of the first line.
	chosen = pointer_pictures.choose(file, .Wait, 12, 150)
	testing.expect_value(t, chosen.picture.delay_milliseconds, 200)
	free_all(context.temp_allocator)
}

// An error of the manifest gives the line, the column and what was
// expected, word for word.
@(test)
manifest_errors_name_the_place :: proc(t: ^testing.T) {
	Case :: struct {
		text:     string,
		sentence: string,
	}
	head :: "theme T\nlicense MIT\nsizes 12\n"
	cases := [?]Case {
		{"license MIT\n", "m:1:1: expected the statement \"theme\" first; found \"license\""},
		{head + "shape arow hot 0 0\n|X\n", "m:4:7: expected a pointer shape name such as \"arrow\"; found \"arow\""},
		{head + "shape arrow hot 0 0\n|X\nshape arrow hot 0 0\n|X\n", "m:6:7: expected a shape that line 4 does not name; found \"arrow\""},
		{head + "shape arrow hot 0 0\n|XoX\n", "m:5:3: expected a square \"X\", \".\" or \" \"; found \"o\""},
		{head + "shape arrow hot 0 0\n|XXXXXXXXXXXXX\n", "m:5:14: expected at most 12 squares in a line; found \"X\""},
		{head + "shape arrow hot 0 0\n|X\té\n", "m:5:3: expected a character of ASCII 32 to 126; found the byte 9"},
		{"theme T\nlicense MIT\nsizes 24 12\n", "m:3:10: expected a size larger than 24; found \"12\""},
		{"theme T\nlicense MIT\nsizes\n", "m:3:6: expected a nominal size from 1 to 256; found the end of the line"},
		{"theme T\nlicense MIT\nsizes 300\n", "m:3:7: expected a nominal size from 1 to 256; found \"300\""},
		{head + "shape arrow\n|X\n", "m:4:1: expected the option \"hot\" for a grid; found the shape arrow with none"},
		{head + "shape arrow hot 0 0\n", "m:4:1: expected a source file or the lines of a grid; found the shape arrow with none"},
		{head + "shape arrow hot 0 0\nframe 100\n|X\n", "m:4:1: expected 2 statements \"frame\" at least for an animation; found the shape arrow with none"},
		{head + "shape arrow hot 3 0\n|X\n", "m:4:1: expected a hot spot inside the grid of 1 x 1 squares; found 3,0"},
		{"theme T\nlicense MIT\nsizes 10\nshape arrow hot 0 0\n|X\n", "m:4:1: expected sizes that are multiples of 12 for a grid; found 10"},
		{head + "shape text hot 0 0\n|X\n", "m:6:1: expected the shape \"arrow\": the shape that the compositor shows by default; found the end of the file"},
		{head + "shape arrow left_ptr hot 1\n", "m:4:26: expected two numbers after \"hot\"; found \"1\""},
		{head + "shape arrow hot 1 x\n|X\n", "m:4:19: expected a number from 0 to 255; found \"x\""},
		{head + "shape arrow left/ptr\n", "m:4:13: expected a file name of letters, digits, \"_\" and \"-\"; found \"left/ptr\""},
		{head + "shape arrow left_ptr hot 0 0 other\n", "m:4:30: expected an option \"hot\" or \"sizes\" after the options; found \"other\""},
		{head + "shape arrow left_ptr\n|X\n", "m:5:1: expected a grid only after a statement \"shape\" with no source; found \"|X\""},
		{head + "colour red\n", "m:4:1: expected a statement \"theme\", \"license\", \"attribution\", \"sizes\", \"shape\" or \"frame\", or a line of a grid; found \"colour\""},
		{"theme T\nlicense MIT\nshape arrow\n", "m:3:1: expected the statement \"sizes\" before the shapes; found \"shape\""},
		{"theme T\nsizes 12\nshape arrow hot 0 0\n|X\n", "m:5:1: expected the statement \"license\"; found the end of the file"},
	}
	for item in cases {
		_, problem := manifest_parse("m", item.text)
		testing.expectf(t, problem == item.sentence, "for %q:\n got      %s\n expected %s", item.text, problem, item.sentence)
	}
	free_all(context.temp_allocator)
}

// A manifest with sources: the first source that exists, through two
// links; two shapes of one file share their pictures; a hot spot override
// scales with the size; a link out of the folder is refused.
@(test)
manifest_of_sources_follows_the_links :: proc(t: ^testing.T) {
	folder, err := os.make_directory_temp("", "pointers_test_*", context.temp_allocator)
	testing.expect_value(t, err, nil)
	defer os.remove_all(folder)
	_ = os.write_entire_file(fmt.tprintf("%s/real", folder), xcursor_write(two_sizes[:]))
	_ = os.symlink("real", fmt.tprintf("%s/middle", folder))
	_ = os.symlink("middle", fmt.tprintf("%s/left_ptr", folder))
	_ = os.symlink("/etc/passwd", fmt.tprintf("%s/outside", folder))
	text := "theme T\nlicense MIT\nsizes 4 8\nshape arrow default left_ptr hot 2 1\nshape text real\nshape move left_ptr hot 2 1\n"
	manifest, problem := manifest_parse("m", text)
	testing.expect_value(t, problem, "")
	file, rows, made_problem := pointer_theme_make(manifest, folder)
	testing.expect_value(t, made_problem, "")
	testing.expect_value(t, rows[0].source, "real")
	testing.expect_value(t, rows[2].source, "real (shared)")
	testing.expect_value(t, pointer_pictures.header(file).picture_count, 4) // arrow 2, text 2; move shares the arrow.
	chosen := pointer_pictures.choose(file, .Move, 8, 0)
	testing.expect_value(t, chosen.picture.hot_spot_x, 4)
	testing.expect_value(t, chosen.picture.hot_spot_y, 2)
	chosen = pointer_pictures.choose(file, .Text, 8, 0)
	testing.expect_value(t, chosen.picture.hot_spot_x, 2) // The hot spot of the file.

	manifest, _ = manifest_parse("m", "theme T\nlicense MIT\nsizes 4\nshape arrow outside\n")
	_, _, made_problem = pointer_theme_make(manifest, folder)
	testing.expect(t, strings.contains(made_problem, "out of the folder"))
	manifest, _ = manifest_parse("m", "theme T\nlicense MIT\nsizes 16\nshape arrow real\n")
	_, _, made_problem = pointer_theme_make(manifest, folder)
	testing.expectf(t, strings.contains(made_problem, "has no picture of the size 16; it has [4, 8]"), "got %s", made_problem)
	free_all(context.temp_allocator)
}
