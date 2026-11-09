package kerneltool

import "core:fmt"
import "core:image/jpeg"
import "core:os"
import "core:slice"

// The program "temple" shows a portrait. The command "portrait" converts the
// JPEG file to the pixels that the program holds: PORTRAIT_WIDTH x
// PORTRAIT_HEIGHT colors of 32 bits (0x00RRGGBB), line after line.
// The result is in the repository, so that a build does not decode a JPEG file.

PORTRAIT_SOURCE :: "programs/temple/portrait.jpg"
PORTRAIT_OUTPUT :: "programs/temple/portrait.pixels"
PORTRAIT_WIDTH :: 180
PORTRAIT_HEIGHT :: 240
PORTRAIT_SAMPLES :: 4 // Each pixel is the mean of SAMPLES x SAMPLES points of the source.

run_portrait :: proc(args: []string) -> int {
	source, ok := read_file(PORTRAIT_SOURCE)
	if !ok {
		return EXIT_FAILURE
	}
	picture, err := jpeg.load_from_bytes(source, {}, context.temp_allocator)
	if err != nil || picture.channels < 3 || picture.depth != 8 {
		fmt.eprintfln("kerneltool: cannot decode %s: %v", PORTRAIT_SOURCE, err)
		return EXIT_FAILURE
	}
	bytes := picture.pixels.buf[:]
	pixels := make([]u32, PORTRAIT_WIDTH * PORTRAIT_HEIGHT, context.temp_allocator)
	for y in 0 ..< PORTRAIT_HEIGHT {
		for x in 0 ..< PORTRAIT_WIDTH {
			sums: [3]int
			for j in 0 ..< PORTRAIT_SAMPLES {
				for i in 0 ..< PORTRAIT_SAMPLES {
					source_x := min(((x * PORTRAIT_SAMPLES + i) * 2 + 1) * picture.width / (2 * PORTRAIT_WIDTH * PORTRAIT_SAMPLES), picture.width - 1)
					source_y := min(((y * PORTRAIT_SAMPLES + j) * 2 + 1) * picture.height / (2 * PORTRAIT_HEIGHT * PORTRAIT_SAMPLES), picture.height - 1)
					texel := bytes[(source_y * picture.width + source_x) * picture.channels:]
					sums[0] += int(texel[0])
					sums[1] += int(texel[1])
					sums[2] += int(texel[2])
				}
			}
			count :: PORTRAIT_SAMPLES * PORTRAIT_SAMPLES
			pixels[y * PORTRAIT_WIDTH + x] = u32(sums[0] / count) << 16 | u32(sums[1] / count) << 8 | u32(sums[2] / count)
		}
	}
	if write_err := os.write_entire_file(PORTRAIT_OUTPUT, slice.to_bytes(pixels)); write_err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", PORTRAIT_OUTPUT, write_err)
		return EXIT_FAILURE
	}
	fmt.printfln("kerneltool: wrote %s: %dx%d pixels from %dx%d", PORTRAIT_OUTPUT, PORTRAIT_WIDTH, PORTRAIT_HEIGHT, picture.width, picture.height)
	return 0
}
