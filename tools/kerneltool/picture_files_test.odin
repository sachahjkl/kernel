package kerneltool

import "core:image/png"
import "core:os"
import "core:testing"

// A picture of squares of two colors with a gradient line: a few distinct
// rows, as on a screen. In context.allocator: the caller deletes it.
test_picture_pixels :: proc(width, height, channels: int) -> []u8 {
	pixels := make([]u8, width * height * channels)
	for y in 0 ..< height {
		for x in 0 ..< width {
			for channel in 0 ..< channels {
				value := ((x / 8 + y / 8) % 2 == 0) ? 20 + channel : 200 - channel
				if y == 5 {
					value = (x * 7 + channel * 50) % 256
				}
				pixels[(y * width + x) * channels + channel] = u8(value)
			}
		}
	}
	return pixels
}

// test_picture_with_stored_data gives a PNG file whose data is stored, as the earlier
// writer of the tool gave it.
test_picture_with_stored_data :: proc(width, height, channels: int, pixels: []u8) -> []u8 {
	picture := png.Image {
		width    = width,
		height   = height,
		channels = channels,
		depth    = 8,
	}
	picture.pixels = make([dynamic]u8, len(pixels), len(pixels), context.temp_allocator)
	copy(picture.pixels[:], pixels)
	output := make([dynamic]u8, context.temp_allocator)
	if save_error := png.save_to_buffer(&output, &picture, level = .Stored, filter = .None, allocator = context.temp_allocator); save_error != nil {
		return nil
	}
	return output[:]
}

// The encoder gives the same bytes for the same pixels, compressed, and the
// decoder gives each pixel back.
@(test)
png_encode_gives_the_same_bytes_and_the_same_pixels :: proc(t: ^testing.T) {
	for channels in 3 ..= 4 {
		pixels := test_picture_pixels(97, 61, channels)
		defer delete(pixels)
		first, first_error := png_encode(97, 61, channels, pixels)
		second, second_error := png_encode(97, 61, channels, pixels)
		testing.expect(t, first_error == nil && second_error == nil)
		testing.expect_value(t, string(second), string(first))
		testing.expect(t, png_has_pixels(first, 97, 61, channels, pixels))
		stored, readable := png_data_is_stored(first)
		testing.expect(t, readable && !stored)
		testing.expectf(t, len(first) < len(pixels) / 4, "%d channels: %d bytes for %d bytes of pixels", channels, len(first), len(pixels))
		// One pixel changed: the file does not have the pixels any more.
		pixels[(30 * 97 + 40) * channels] ~= 1
		testing.expect(t, !png_has_pixels(first, 97, 61, channels, pixels))
	}
}

// The test of stored data reads the first block, and refuses a file that is
// not a PNG file or whose chunk is longer than the file.
@(test)
png_data_is_stored_reads_the_first_block :: proc(t: ^testing.T) {
	pixels := test_picture_pixels(16, 16, 3)
	defer delete(pixels)
	stored_file := test_picture_with_stored_data(16, 16, 3, pixels)
	testing.expect(t, stored_file != nil)
	stored, readable := png_data_is_stored(stored_file)
	testing.expect(t, readable && stored)
	compressed_file, encode_error := png_encode(16, 16, 3, pixels)
	testing.expect(t, encode_error == nil)
	compressed_stored, compressed_readable := png_data_is_stored(compressed_file)
	testing.expect(t, compressed_readable && !compressed_stored)
	_, text_readable := png_data_is_stored(transmute([]u8)string("not a picture"))
	testing.expect(t, !text_readable)
	// The signature and the header chunk only: no data.
	_, cut_readable := png_data_is_stored(stored_file[:8 + 25])
	testing.expect(t, !cut_readable)
	// The length of the header chunk is larger than the file.
	longer := make([]u8, len(stored_file), context.temp_allocator)
	copy(longer, stored_file)
	longer[8] = 0x7F
	_, longer_readable := png_data_is_stored(longer)
	testing.expect(t, !longer_readable)
}

// `screenshots compress` on a small folder: the stored file in a folder
// inside is compressed with the same pixels, the compressed file keeps its
// bytes, another file is not read, and a second run changes nothing. A file
// that is not a PNG file stops the run.
@(test)
pictures_compress_converts_only_stored_files :: proc(t: ^testing.T) {
	folder :: BUILD_FOLDER + "/test_picture_compression"
	_ = os.remove_all(folder)
	testing.expect(t, make_folder(folder + "/inner"))
	defer os.remove_all(folder)
	pixels := test_picture_pixels(64, 48, 3)
	defer delete(pixels)
	stored_file := test_picture_with_stored_data(64, 48, 3, pixels)
	compressed_file, encode_error := png_encode(64, 48, 3, pixels)
	testing.expect(t, stored_file != nil && encode_error == nil)
	testing.expect(t, os.write_entire_file(folder + "/inner/stored.png", stored_file) == nil)
	testing.expect(t, os.write_entire_file(folder + "/compressed.png", compressed_file) == nil)
	testing.expect(t, os.write_entire_file(folder + "/notes.txt", transmute([]u8)string("not a picture")) == nil)
	stored_size := len(stored_file)
	compressed_before := make([]u8, len(compressed_file))
	defer delete(compressed_before)
	copy(compressed_before, compressed_file)

	count, ok := pictures_compress([]string{folder})
	testing.expect(t, ok)
	testing.expect_value(t, count.picture_count, 2)
	testing.expect_value(t, count.compressed_count, 1)
	testing.expect_value(t, count.bytes_before, stored_size)
	converted, converted_error := os.read_entire_file(folder + "/inner/stored.png", context.temp_allocator)
	testing.expect(t, converted_error == nil)
	testing.expect_value(t, count.bytes_after, len(converted))
	testing.expect(t, len(converted) < stored_size)
	testing.expect(t, png_has_pixels(converted, 64, 48, 3, pixels))
	converted_stored, converted_readable := png_data_is_stored(converted)
	testing.expect(t, converted_readable && !converted_stored)
	kept, kept_error := os.read_entire_file(folder + "/compressed.png", context.temp_allocator)
	testing.expect(t, kept_error == nil)
	testing.expect_value(t, string(kept), string(compressed_before))

	again, again_ok := pictures_compress([]string{folder})
	testing.expect(t, again_ok)
	testing.expect_value(t, again.picture_count, 2)
	testing.expect_value(t, again.compressed_count, 0)

	testing.expect(t, os.write_entire_file(folder + "/broken.png", transmute([]u8)string("not a picture")) == nil)
	_, broken_ok := pictures_compress([]string{folder})
	testing.expect(t, !broken_ok)
}
