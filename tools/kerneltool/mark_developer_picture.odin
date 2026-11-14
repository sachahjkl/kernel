// The picture of every frame of the animations of the mark for a developer,
// a part of the generator of the pictures of the mark (mark_pictures.odin;
// docs/TOOLS.md, "The pictures of the mark"). The row of the drawn forms of
// an animation that moves is in mark_tile_map.odin.
package kerneltool

import "core:fmt"
import "core:os"
import "support:graphics"
import "support:mark"

// The picture of every frame for a developer, written by `kerneltool logo`
// and by `kerneltool mark developer` into the build folder: one row for
// each animation, its frames from the still heron at cells of 8 pixels,
// each with its duration. It is not a file of the site or of the
// repository.
MARK_ANIMATIONS_PICTURE :: BUILD_FOLDER + "/mark_animations.png"
MARK_ANIMATIONS_CELL_SIZE :: 8
MARK_ANIMATIONS_MARGIN :: 32
MARK_ANIMATIONS_GAP :: 16
MARK_ANIMATIONS_LINE :: 24 // A line of text of the font of 8 by 16.

mark_animations_picture_write :: proc() -> bool {
	heron := mark.heron_size(MARK_ANIMATIONS_CELL_SIZE)
	most_frames := 0
	for animation in mark.Animation {
		most_frames = max(most_frames, mark.animation_frame_count(animation))
	}
	// The still heron, then each frame.
	column_width := heron + MARK_ANIMATIONS_GAP
	row_height := MARK_ANIMATIONS_LINE + heron + MARK_ANIMATIONS_LINE + MARK_ANIMATIONS_GAP
	width := 2 * MARK_ANIMATIONS_MARGIN + (most_frames + 1) * column_width
	height := 2 * MARK_ANIMATIONS_MARGIN + MARK_ANIMATIONS_LINE + len(mark.Animation) * row_height + MARK_ANIMATIONS_LINE
	// Under the frames of an animation that moves, the forms of its move.
	sprites := site_mark_sprites() or_return
	forms := site_mark_forms(&sprites) or_return
	width = max(width, 2 * MARK_ANIMATIONS_MARGIN + mark_animation_forms_width(&forms))
	for animation in mark.Animation {
		height += mark_animation_forms_height(animation)
	}
	colors := make([]graphics.Color, width * height, context.temp_allocator)
	canvas := graphics.Canvas{pixels = raw_data(colors), width = width, height = height, stride = width}
	graphics.clear(canvas, graphics.COLOR_BACKGROUND)
	saved := graphics.text_state
	defer graphics.text_state = saved
	graphics.text_choice_set(.Spleen, .Red_Green_Blue)

	y := MARK_ANIMATIONS_MARGIN
	graphics.text(canvas, MARK_ANIMATIONS_MARGIN, y, "The animations of the mark (support/mark): frame 0 is the still heron; cells of 8 pixels", graphics.COLOR_TEXT)
	y += MARK_ANIMATIONS_LINE
	for animation in mark.Animation {
		moves := "" if !mark.animation_moves(animation) else "; the home of the site and the program heron move the heron"
		heading := fmt.tprintf("%s: %d frames, %d ms%s", mark.animation_names[animation], mark.animation_frame_count(animation), mark.animation_duration(animation), moves)
		graphics.text(canvas, MARK_ANIMATIONS_MARGIN, y, heading, graphics.COLOR_KERNEL)
		count := mark.animation_frame_count(animation)
		for frame in 0 ..= count {
			x := MARK_ANIMATIONS_MARGIN + frame * column_width
			cells, _ := mark.animation_frame_cells(animation, frame)
			graphics.fill(canvas, x, y + MARK_ANIMATIONS_LINE, heron, heron, graphics.COLOR_CARD_TOP)
			mark.cells_draw(canvas, &cells, x, y + MARK_ANIMATIONS_LINE, MARK_ANIMATIONS_CELL_SIZE, .Smooth, false)
			caption := "still"
			if frame > 0 {
				row, _ := mark.animation_frame(animation, frame)
				still := mark.still_cells()
				caption = fmt.tprintf("%d: %d ms, %d cells", frame, row.duration_milliseconds, mark.cells_differ_count(&cells, &still))
			}
			fmt.assertf(len(caption) * MARK_ANIMATIONS_CHARACTER_WIDTH <= heron, "the text %q under a frame is wider than its box", caption)
			graphics.text(canvas, x, y + MARK_ANIMATIONS_LINE + heron + 4, caption, graphics.COLOR_DIM)
		}
		y += row_height
		if mark.animation_moves(animation) {
			mark_animation_forms_draw(canvas, MARK_ANIMATIONS_MARGIN, y, animation, &sprites, &forms)
			y += mark_animation_forms_height(animation)
		}
	}
	still_least, still_most := mark.still_bounds()
	graphics.text(canvas, MARK_ANIMATIONS_MARGIN, y, fmt.tprintf("On the home of the site: each animation once in a round, in an order of chance; still for %d to %d ms between two", still_least, still_most), graphics.COLOR_TEXT)

	rgb := make([]u8, 3 * len(colors), context.temp_allocator)
	for color, index in colors {
		rgb[3 * index] = u8(color >> 16)
		rgb[3 * index + 1] = u8(color >> 8)
		rgb[3 * index + 2] = u8(color)
	}
	data := mark_pixels_png_quick(MARK_ANIMATIONS_PICTURE, width, height, 3, rgb) or_return
	if !make_folder(BUILD_FOLDER) {
		return false
	}
	if err := os.write_entire_file(MARK_ANIMATIONS_PICTURE, data); err != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", MARK_ANIMATIONS_PICTURE, err)
		return false
	}
	fmt.printfln("kerneltool: wrote %s (%d by %d pixels, %d bytes): every frame of the animations of the mark", MARK_ANIMATIONS_PICTURE, width, height, len(data))
	return true
}
