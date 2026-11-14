package kerneltool

import "core:fmt"
import "core:os"
import "core:strings"

// The film of a document (docs/TOOLS.md, "The film of a document").
//
// The command `film` writes its files in the build folder. A film that a
// news entry names is also a file of the repository, as a screen picture
// is: the site copies it and needs no encoder. That file is WebM with AV1,
// the smallest of the formats that were measured for a film of the screen.
// This file holds the checks of such a file, from its bytes only, and the
// copy from the build folder to the repository.

FILM_DOCUMENT_FOLDER :: "docs/films"
FILM_DOCUMENT_SUFFIX :: ".webm"
// The most bytes of a film of the repository. Each version of the file
// stays in the history of the repository for ever, and a reader of the
// site on a phone loads it over a slow link. The film of the palette, 37
// seconds of the whole screen, has 1.5 MiB: the bound holds a film of more
// than twice that length, and refuses a file that was encoded with the
// settings of another format.
FILM_DOCUMENT_SIZE_LIMIT :: 4 * 1024 * 1024

// The identifiers of the elements of a WebM file that the tool reads, with
// their marker bits, as the file holds them.
@(private = "file")
EBML_HEADER :: 0x1A45DFA3
@(private = "file")
EBML_DOCUMENT_TYPE :: 0x4282
@(private = "file")
WEBM_SEGMENT :: 0x18538067
@(private = "file")
WEBM_TRACKS :: 0x1654AE6B
@(private = "file")
WEBM_TRACK_ENTRY :: 0xAE
@(private = "file")
WEBM_VIDEO :: 0xE0
@(private = "file")
WEBM_PIXEL_WIDTH :: 0xB0
@(private = "file")
WEBM_PIXEL_HEIGHT :: 0xBA
@(private = "file")
WEBM_DOCUMENT_TYPE_NAME :: "webm"
// The longest identifier and the longest size of an element, in bytes.
@(private = "file")
EBML_IDENTIFIER_LENGTH_LIMIT :: 4
@(private = "file")
EBML_SIZE_LENGTH_LIMIT :: 8

// ebml_number reads a number of variable length at the start of data: the
// count of the zero bits before the first one bit of the first byte is the
// count of the bytes that follow. An identifier keeps that one bit; a size
// does not.
@(private = "file")
ebml_number :: proc(data: []u8, length_limit: int, keeps_marker: bool) -> (value: u64, length: int, ok: bool) {
	if len(data) == 0 || data[0] == 0 {
		return 0, 0, false
	}
	marker := u8(0x80)
	length = 1
	for (data[0] & marker) == 0 {
		marker >>= 1
		length += 1
	}
	if length > length_limit || length > len(data) {
		return 0, 0, false
	}
	value = u64(data[0])
	if !keeps_marker {
		value &= u64(marker - 1)
	}
	for index in 1 ..< length {
		value = value << 8 | u64(data[index])
	}
	return value, length, true
}

// ebml_element_next reads the element at the start of data: its
// identifier, its content, and the bytes after it. A size of only one bits
// says that the size is not known: the element then goes to the end of the
// data. An element that is longer than the data is refused: the file is
// cut.
@(private = "file")
ebml_element_next :: proc(data: []u8) -> (identifier: u64, content: []u8, rest: []u8, ok: bool) {
	identifier_value, identifier_length, identifier_ok := ebml_number(data, EBML_IDENTIFIER_LENGTH_LIMIT, true)
	if !identifier_ok {
		return 0, nil, nil, false
	}
	size, size_length, size_ok := ebml_number(data[identifier_length:], EBML_SIZE_LENGTH_LIMIT, false)
	if !size_ok {
		return 0, nil, nil, false
	}
	after_head := data[identifier_length + size_length:]
	size_not_known := (u64(1) << uint(7 * size_length)) - 1
	if size == size_not_known {
		return identifier_value, after_head, nil, true
	}
	if size > u64(len(after_head)) {
		return 0, nil, nil, false
	}
	return identifier_value, after_head[:int(size)], after_head[int(size):], true
}

// ebml_element_find gives the content of the first element with an
// identifier among the elements of data, and the bytes after that element.
@(private = "file")
ebml_element_find :: proc(data: []u8, identifier: u64) -> (content: []u8, rest: []u8, found: bool) {
	remaining := data
	for len(remaining) > 0 {
		element_identifier, element_content, element_rest, element_ok := ebml_element_next(remaining)
		if !element_ok {
			return nil, nil, false
		}
		if element_identifier == identifier {
			return element_content, element_rest, true
		}
		remaining = element_rest
	}
	return nil, nil, false
}

// ebml_unsigned reads the content of an element that is an unsigned
// integer: 1 to 8 bytes, the most significant first.
@(private = "file")
ebml_unsigned :: proc(content: []u8) -> (value: int, ok: bool) {
	if len(content) == 0 || len(content) > 8 {
		return 0, false
	}
	wide: u64
	for part in content {
		wide = wide << 8 | u64(part)
	}
	if wide > u64(max(i32)) {
		return 0, false
	}
	return int(wide), true
}

// film_document_is_webm says whether the bytes start as a WebM file: the
// EBML header, with the document type "webm".
film_document_is_webm :: proc(data: []u8) -> bool {
	identifier, header, _, header_ok := ebml_element_next(data)
	if !header_ok || identifier != EBML_HEADER {
		return false
	}
	document_type, _, has_document_type := ebml_element_find(header, EBML_DOCUMENT_TYPE)
	return has_document_type && string(document_type) == WEBM_DOCUMENT_TYPE_NAME
}

// film_document_picture_size reads the width and the height of the
// pictures of a WebM file, in pixels, from its first track that has
// pictures. The site states them on the video element, so that the page
// keeps the room of the film before a browser read the file.
film_document_picture_size :: proc(data: []u8) -> (width, height: int, ok: bool) {
	_, _, after_header, header_ok := ebml_element_next(data)
	if !header_ok {
		return 0, 0, false
	}
	segment, _, has_segment := ebml_element_find(after_header, WEBM_SEGMENT)
	if !has_segment {
		return 0, 0, false
	}
	tracks, _, has_tracks := ebml_element_find(segment, WEBM_TRACKS)
	if !has_tracks {
		return 0, 0, false
	}
	entries := tracks
	for {
		entry, after_entry, has_entry := ebml_element_find(entries, WEBM_TRACK_ENTRY)
		if !has_entry {
			return 0, 0, false
		}
		entries = after_entry
		video, _, has_video := ebml_element_find(entry, WEBM_VIDEO)
		if !has_video {
			continue
		}
		width_content, _, has_width := ebml_element_find(video, WEBM_PIXEL_WIDTH)
		height_content, _, has_height := ebml_element_find(video, WEBM_PIXEL_HEIGHT)
		if !has_width || !has_height {
			continue
		}
		track_width, width_ok := ebml_unsigned(width_content)
		track_height, height_ok := ebml_unsigned(height_content)
		if width_ok && height_ok && track_width > 0 && track_height > 0 {
			return track_width, track_height, true
		}
	}
}

// film_document_problem gives the fault of the bytes of a film of the
// repository, or "": the size bound, the format, and a picture size that
// the site can state.
film_document_problem :: proc(data: []u8) -> string {
	if len(data) > FILM_DOCUMENT_SIZE_LIMIT {
		return fmt.tprintf("has %d bytes; a film of the repository has at most %d", len(data), FILM_DOCUMENT_SIZE_LIMIT)
	}
	if !film_document_is_webm(data) {
		return "is not a WebM file: it does not start with an EBML header of the document type \"webm\""
	}
	if _, _, sized := film_document_picture_size(data); !sized {
		return "is a WebM file with no track that states the width and the height of its pictures, or a file that is cut"
	}
	return ""
}

// film_document_path gives the path of the film with a name in the
// repository.
film_document_path :: proc(name: string) -> string {
	return strings.concatenate({FILM_DOCUMENT_FOLDER, "/", name, FILM_DOCUMENT_SUFFIX}, context.temp_allocator)
}

// film_is_named_by_a_news_entry says whether an entry of the news names
// the film with this name. The faults of the entries are not printed here:
// `news check` prints them, and the entry that names a film is faulty
// until the first run of the command writes the file.
film_is_named_by_a_news_entry :: proc(name: string) -> bool {
	problems := make([dynamic]string, context.temp_allocator)
	path := film_document_path(name)
	for entry in news_read(NEWS_FOLDER, &problems) {
		if entry.film == path {
			return true
		}
	}
	return false
}

// film_document_write copies the WebM file of a film from the build
// folder to the repository, after the checks that `news check` makes on
// it: the command never leaves a file there that the check refuses.
film_document_write :: proc(name, source: string) -> bool {
	data := read_file(source) or_return
	if problem := film_document_problem(data); problem != "" {
		fmt.eprintfln("kerneltool: the film: %s %s; the repository keeps the film that it has", source, problem)
		return false
	}
	make_folder(FILM_DOCUMENT_FOLDER) or_return
	target := film_document_path(name)
	if write_error := os.write_entire_file(target, data); write_error != nil {
		fmt.eprintfln("kerneltool: cannot write %s: %v", target, write_error)
		return false
	}
	fmt.printfln("kerneltool: wrote %s (%d bytes): a news entry names this film, and the repository holds it", target, len(data))
	return true
}
