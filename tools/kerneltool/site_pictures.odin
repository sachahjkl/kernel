// The pictures of the repository that the site copies: the screen pictures
// are stored with no compression, and the site writes them compressed. The
// pictures of the mark are not here: the generator of the pictures of the
// mark draws and encodes each of them (mark_pictures.odin), and the site
// asks for the rows of its table of the uses.
package kerneltool

import "core:image/png"

// site_png_compress gives a PNG file with the same pixels as another, written
// by the encoder of the standard library (core:image/png: a row filter
// chosen for each row, then the deflate of core:compress/deflate at its
// default level). The screen pictures of the repository are stored with no
// compression, about 2.3 MB for 1024 by 768. The encoder reads no clock, no
// random number and no thread, so the same pixels give the same bytes at
// each build of the same compiler. Only 8 bits a channel: the pictures of
// the repository have no other depth.
site_png_compress :: proc(data: []u8) -> (compressed: []u8, ok: bool) {
	source, load_error := png.load_from_bytes(data, allocator = context.temp_allocator)
	if load_error != nil || source == nil || source.depth != 8 {
		return nil, false
	}
	output := make([dynamic]u8, context.temp_allocator)
	if save_error := png.save_to_buffer(&output, source, allocator = context.temp_allocator); save_error != nil {
		return nil, false
	}
	return output[:], true
}
