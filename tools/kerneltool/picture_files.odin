package kerneltool

import "core:fmt"
import "core:image/png"
import "core:os"
import "core:slice"
import "core:strings"

// The PNG files of the tool: the pictures of the screen, the picture of the
// font candidates and the files of the mark. One encoder writes them all: the
// one of the Odin standard library (core:image/png), which filters each row
// and compresses with core:compress/deflate. A picture of the screen with no
// compression is 2.3 MB, and each step commits the pictures again.
//
// The encoder gives the same bytes for the same pixels: it reads no clock, no
// random number and no map, so a picture with no change of pixels is not a
// change of the repository.

// png_encode gives a compressed PNG file of pixels of 8 bits for each channel.
// Each pixel is `channels` bytes: 3 for red, green, blue (a screen has no
// alpha, and a file with no alpha is smaller), 4 with alpha.
png_encode :: proc(width, height, channels: int, pixels: []u8) -> (file: []u8, encode_error: png.Error) {
	picture := png.Image {
		width    = width,
		height   = height,
		channels = channels,
		depth    = 8,
	}
	picture.pixels = make([dynamic]u8, len(pixels), len(pixels), context.temp_allocator)
	copy(picture.pixels[:], pixels)
	output := make([dynamic]u8, context.temp_allocator)
	if save_error := png.save_to_buffer(&output, &picture, allocator = context.temp_allocator); save_error != nil {
		return nil, save_error
	}
	return output[:], nil
}

// png_has_pixels decodes a PNG file and tells whether it has exactly these
// pixels: the same width, height and channels, 8 bits for each channel, and
// each byte.
png_has_pixels :: proc(file: []u8, width, height, channels: int, pixels: []u8) -> bool {
	picture, load_error := png.load_from_bytes(file, allocator = context.temp_allocator)
	if load_error != nil {
		return false
	}
	return picture.width == width && picture.height == height && picture.channels == channels && picture.depth == 8 && slice.equal(picture.pixels[:], pixels)
}

PNG_SIGNATURE :: "\x89PNG\r\n\x1a\n"

// png_data_is_stored tells whether the compressed data of a PNG file starts
// with a stored block: a block of deflate that holds its bytes as they are.
// The earlier writer of the tool gave only stored blocks; the encoder of the
// standard library chooses a stored block only for data that it cannot
// compress. `readable` is false when the file is not a PNG file with data
// that the tool can read. The file is input from the disk: each length is
// checked against the size of the file before its use.
png_data_is_stored :: proc(file: []u8) -> (stored: bool, readable: bool) {
	if len(file) < len(PNG_SIGNATURE) || string(file[:len(PNG_SIGNATURE)]) != PNG_SIGNATURE {
		return false, false
	}
	// Each chunk: its length (4 bytes, big endian), its kind (4 bytes), its
	// data, its CRC (4 bytes).
	position := len(PNG_SIGNATURE)
	for len(file) - position >= 12 {
		length := int(file[position]) << 24 | int(file[position + 1]) << 16 | int(file[position + 2]) << 8 | int(file[position + 3])
		if length > len(file) - position - 12 {
			return false, false
		}
		kind := string(file[position + 4:][:4])
		if kind == "IDAT" {
			// A zlib header of 2 bytes (the method 8 is deflate), then the
			// first block: bit 0 is the last block, bits 1 and 2 its type
			// (0: stored).
			if length < 3 || file[position + 8] & 0x0F != 8 {
				return false, false
			}
			return (file[position + 10] >> 1) & 3 == 0, true
		}
		position += 12 + length
	}
	return false, false
}

// The count of a run of `screenshots compress`.
Picture_Compression_Count :: struct {
	picture_count:    int, // Every PNG file in the folders.
	compressed_count: int, // The files that had stored data and are now compressed.
	bytes_before:     int, // The size of the compressed files before.
	bytes_after:      int, // The size of the compressed files after.
}

// png_files_under adds the path of each PNG file in a folder and in its
// folders to `paths`. Each path is in context.allocator: the caller frees
// them.
png_files_under :: proc(folder: string, paths: ^[dynamic]string) -> bool {
	entries, list_error := os.read_all_directory_by_path(folder, context.temp_allocator)
	if list_error != nil {
		fmt.eprintfln("kerneltool: cannot list %s: %v", folder, list_error)
		return false
	}
	for entry in entries {
		path := strings.concatenate({folder, "/", entry.name})
		if entry.type == .Directory {
			found := png_files_under(path, paths)
			delete(path)
			if !found {
				return false
			}
		} else if strings.has_suffix(entry.name, ".png") {
			append(paths, path)
		} else {
			delete(path)
		}
	}
	return true
}

// pictures_compress compresses each PNG file of the folders whose data is
// stored. It decodes the file, encodes the same pixels with png_encode,
// decodes the result and compares each pixel, and only then writes the file.
// A file that is compressed already keeps its bytes. The first file that
// fails stops the run, with its name. It frees the temporary allocator after
// each file: a picture of the screen takes about 10 MB to convert.
pictures_compress :: proc(folders: []string) -> (count: Picture_Compression_Count, ok: bool) {
	paths := make([dynamic]string)
	defer {
		for path in paths {
			delete(path)
		}
		delete(paths)
	}
	for folder in folders {
		if !png_files_under(folder, &paths) {
			return count, false
		}
	}
	slice.sort(paths[:])
	for path in paths {
		free_all(context.temp_allocator)
		if !picture_compress(path, &count) {
			free_all(context.temp_allocator)
			return count, false
		}
	}
	free_all(context.temp_allocator)
	return count, true
}

// picture_compress compresses one file when its data is stored.
picture_compress :: proc(path: string, count: ^Picture_Compression_Count) -> bool {
	count.picture_count += 1
	before, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("kerneltool: cannot read %s: %v", path, read_error)
		return false
	}
	stored, readable := png_data_is_stored(before)
	if !readable {
		fmt.eprintfln("kerneltool: %s is not a PNG file that the tool can read", path)
		return false
	}
	if !stored {
		return true
	}
	picture, load_error := png.load_from_bytes(before, allocator = context.temp_allocator)
	if load_error != nil {
		fmt.eprintfln("kerneltool: cannot decode %s: %v", path, load_error)
		return false
	}
	if picture.depth != 8 {
		fmt.eprintfln("kerneltool: %s has %d bits for each channel; the tool writes 8", path, picture.depth)
		return false
	}
	after, encode_error := png_encode(picture.width, picture.height, picture.channels, picture.pixels[:])
	if encode_error != nil {
		fmt.eprintfln("kerneltool: cannot encode %s: %v", path, encode_error)
		return false
	}
	if !png_has_pixels(after, picture.width, picture.height, picture.channels, picture.pixels[:]) {
		fmt.eprintfln("kerneltool: the compressed file of %s does not have its pixels; the file is not changed", path)
		return false
	}
	if write_error := os.write_entire_file(path, after); write_error != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", path, write_error)
		return false
	}
	count.compressed_count += 1
	count.bytes_before += len(before)
	count.bytes_after += len(after)
	fmt.printfln("kerneltool: compressed %s: %d bytes before, %d bytes after", path, len(before), len(after))
	return true
}
