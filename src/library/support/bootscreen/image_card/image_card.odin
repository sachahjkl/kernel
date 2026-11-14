// The layout of the card "BOOT IMAGE" of the boot display (docs/DESIGN.md,
// section 12): which files the boot image holds, by kind, with their
// sizes, and which file failed its check.
//
// The card has two parts. The size strip gives each file a part whose
// width is its size, so that the bytes of each kind show at a glance; most
// files are too small there to carry a name. Under it, the rows of names
// give each kind its count and its bytes, then the names of its largest
// files as tiles, and the count of its files with no tile. A name is whole
// or absent: a tile is as wide as its name.
//
// The boot program, the root service and the program `boot` compute the
// card with this package. It uses integers only and allocates nothing,
// because the boot program has no allocator.
package image_card

import info "modus:contract/boot_info"
import module "modus:contract/module"

// What a file of the boot image is: the kind sets its color and its row.
File_Kind :: enum u8 {
	Program, // A module with an entry export: a program starts from it.
	No_Entry, // A module with no entry export: other modules import it.
	Resource, // A file of the resource table of the image.
}

// The files that the layout places. The files of a larger image after
// this count stay in the count and the bytes of their kind, with no part
// and no tile.
FILE_CAPACITY :: 512
TILE_CAPACITY :: 128 // The names that get a tile; the other files are counted after the last tile of their kind.

// The rows of names under the strip. Each kind needs one row at least.
NAME_ROW_COUNT :: 4
#assert(NAME_ROW_COUNT >= len(File_Kind))

STRIP_LEAST_WIDTH :: 2 // The fewest pixels of the part of a file in the strip, so that each file is seen.
// The part of the failed file is wider than the others can be at their
// least, so that its color is seen.
FAILED_LEAST_WIDTH :: 4

// A name is drawn in the font of the cells: each character is one cell.
CELL_WIDTH :: 8
TILE_PADDING :: 4 // On each side of the name, inside its tile.
TILE_GAP :: 4 // Pixels between two tiles.

// One file of the image, as the layout places it.
File :: struct {
	name:        string, // Points into the image: valid while the image is.
	size:        u64, // Its bytes.
	kind:        File_Kind, // What it is.
	failed:      bool, // The file has the name of the file that failed its check.
	strip_x:     int, // The x of its part in the strip.
	strip_width: int, // 0: the file has no part in the strip.
}

// One kind of file: its counts and where its rows are.
Kind_Summary :: struct {
	count:     int, // Every file of the kind, also the ones after FILE_CAPACITY.
	bytes:     u64, // The bytes of every file of the kind.
	first:     int, // The files of the kind are Layout.files[first:end].
	end:       int, // See first.
	first_row: int, // Its first row of names.
	row_count: int, // 0 when the kind has no file.
	named:     int, // The files of the kind that have a tile.
	more_row:  int, // The place of the count of the files with no tile.
	more_x:    int, // Its x.
}

// The tile of one name in the rows of names.
Name_Tile :: struct {
	file:  int, // An index in Layout.files.
	row:   int, // The row of names.
	x:     int, // From the left of the names.
	width: int, // Pixels.
}

// The places of the card of the boot image: the strip, the rows of names
// and their tiles. `layout_place` computes them; the boot display draws
// them.
Layout :: struct {
	// By kind, then by size with the largest first, then in the order of
	// the image.
	files:      [FILE_CAPACITY]File,
	file_count: int, // The entries of `files` in use.
	kinds:      [File_Kind]Kind_Summary, // The summary of each kind.
	tiles:      [TILE_CAPACITY]Name_Tile, // The tiles of the names.
	tile_count: int, // The entries of `tiles` in use.
	valid:      bool, // The tables of the image are valid.
}

// layout_reset empties a layout.
layout_reset :: proc "contextless" (layout: ^Layout) {
	layout.file_count = 0
	layout.kinds = {}
	layout.tile_count = 0
	layout.valid = false
}

// layout_compute reads the files of an image and places them: the strip
// in strip_width pixels, the tiles in names_width pixels.
layout_compute :: proc "contextless" (layout: ^Layout, image: []u8, failed_name: string, strip_width, names_width: int) {
	files_read(layout, image, failed_name)
	layout_place(layout, strip_width, names_width)
}

// files_read adds each module and each resource of an image. An entry that
// points outside the image counts with no bytes; a module whose header is
// not valid counts as a module with no entry.
files_read :: proc "contextless" (layout: ^Layout, image: []u8, failed_name: string) {
	layout_reset(layout)
	modules, resources, valid := info.image_tables(image)
	if !valid {
		return
	}
	layout.valid = true
	for &entry in modules {
		file, inside := info.image_entry_bytes(image, &entry)
		kind := File_Kind.No_Entry
		if head, error := module.header(file); error == .None && head.entry_export != 0 {
			kind = .Program
		}
		file_add(layout, entry_name(&entry), inside ? entry.size : 0, kind, failed_name)
	}
	for &entry in resources {
		_, inside := info.image_entry_bytes(image, &entry)
		file_add(layout, entry_name(&entry), inside ? entry.size : 0, .Resource, failed_name)
	}
}

// file_add puts a file at its place in the order of the card.
file_add :: proc "contextless" (layout: ^Layout, name: string, size: u64, kind: File_Kind, failed_name: string) {
	summary := &layout.kinds[kind]
	summary.count += 1
	summary.bytes += size
	if layout.file_count == FILE_CAPACITY {
		return
	}
	place := layout.file_count
	for place > 0 && file_goes_before(kind, size, &layout.files[place - 1]) {
		layout.files[place] = layout.files[place - 1]
		place -= 1
	}
	layout.files[place] = File {
		name   = name,
		size   = size,
		kind   = kind,
		failed = len(failed_name) != 0 && name == failed_name,
	}
	layout.file_count += 1
}

// A new file goes before a file of a later kind, and before a file of its
// kind with fewer bytes. It goes after a file with as many bytes, so that
// the order of the image stays among equal sizes.
@(private)
file_goes_before :: proc "contextless" (kind: File_Kind, size: u64, other: ^File) -> bool {
	return kind < other.kind || (kind == other.kind && size > other.size)
}

@(private)
// entry_name gives the name of an entry of the image: its bytes before the
// first zero.
entry_name :: proc "contextless" (entry: ^info.Image_Entry) -> string {
	count := 0
	for count < len(entry.name) && entry.name[count] != 0 {
		count += 1
	}
	return string(entry.name[:count])
}

// layout_place places the files that the layout holds.
layout_place :: proc "contextless" (layout: ^Layout, strip_width, names_width: int) {
	kind_ranges(layout)
	strip_place(layout, strip_width)
	names_place(layout, names_width)
}

// kind_ranges finds the files of each kind: they follow each other.
@(private)
kind_ranges :: proc "contextless" (layout: ^Layout) {
	index := 0
	for kind in File_Kind {
		summary := &layout.kinds[kind]
		summary.first = index
		for index < layout.file_count && layout.files[index].kind == kind {
			index += 1
		}
		summary.end = index
	}
}

@(private)
// least_width gives the fewest pixels of the part of a file in the strip:
// FAILED_LEAST_WIDTH for the failed file, else STRIP_LEAST_WIDTH, at most
// `width`.
least_width :: proc "contextless" (file: ^File, width: int) -> int {
	return min(file.failed ? FAILED_LEAST_WIDTH : STRIP_LEAST_WIDTH, width)
}

// strip_place gives each file a part of the strip: its width is its share
// of the bytes, with a least width, and the parts fill the width exactly.
strip_place :: proc "contextless" (layout: ^Layout, width: int) {
	files := layout.files[:layout.file_count]
	for &file in files {
		file.strip_x = 0
		file.strip_width = 0
	}
	if width <= 0 || len(files) == 0 {
		return
	}
	// When the least widths of all the files pass the width, the smallest
	// files have no part. The failed file always has one.
	kept: [FILE_CAPACITY]bool
	least_total := 0
	for &file, index in files {
		kept[index] = true
		least_total += least_width(&file, width)
	}
	// The files of a kind go from the largest to the smallest: the smallest
	// kept file of a kind is the last kept one of its range.
	last: [File_Kind]int
	for kind in File_Kind {
		last[kind] = layout.kinds[kind].end - 1
	}
	for least_total > width {
		smallest := -1
		for kind in File_Kind {
			first := layout.kinds[kind].first
			for last[kind] >= first && (!kept[last[kind]] || files[last[kind]].failed) {
				last[kind] -= 1
			}
			candidate := last[kind]
			if candidate >= first && (smallest < 0 || files[candidate].size <= files[smallest].size) {
				smallest = candidate
			}
		}
		if smallest < 0 {
			break // Only the failed file is left, at no more than the width.
		}
		kept[smallest] = false
		least_total -= least_width(&files[smallest], width)
	}

	// A file whose share is under its least width takes its least width,
	// and leaves the share of the others smaller: the check runs again
	// until no file changes.
	fixed: [FILE_CAPACITY]bool
	room := width
	bytes: u64
	for &file, index in files {
		if kept[index] {
			bytes += file.size
		}
	}
	changed := true
	for changed {
		changed = false
		for &file, index in files {
			if !kept[index] || fixed[index] {
				continue
			}
			least := least_width(&file, width)
			if bytes == 0 || file.size * u64(room) < u64(least) * bytes {
				fixed[index] = true
				file.strip_width = least
				room -= least
				bytes -= file.size
				changed = true
			}
		}
	}
	// The other files share the room by their bytes. A file that is left
	// here has bytes, so bytes is not zero. The pixels that the division
	// loses go one each to the first of these files.
	given := 0
	for &file, index in files {
		if kept[index] && !fixed[index] {
			file.strip_width = int(file.size * u64(room) / bytes)
			given += file.strip_width
		}
	}
	left := room - given
	for &file, index in files {
		if left == 0 {
			break
		}
		if kept[index] && !fixed[index] {
			file.strip_width += 1
			left -= 1
		}
	}
	// When every part has its least width, the first part takes the rest.
	if left > 0 {
		for &file, index in files {
			if kept[index] {
				file.strip_width += left
				break
			}
		}
	}
	x := 0
	for &file, index in files {
		if kept[index] {
			file.strip_x = x
			x += file.strip_width
		}
	}
}

// more_width gives the width of the text "+count".
more_width :: proc "contextless" (count: int) -> int {
	digits := 1
	for rest := count; rest >= 10; rest /= 10 {
		digits += 1
	}
	return (1 + digits) * CELL_WIDTH
}

// names_place gives each kind one row of names, and the other rows, one
// at a time, to the kind with the most files with no tile. Then it places
// the tiles of each kind in its rows.
names_place :: proc "contextless" (layout: ^Layout, width: int) {
	layout.tile_count = 0
	present := 0
	for kind in File_Kind {
		summary := &layout.kinds[kind]
		summary.row_count = summary.count > 0 ? 1 : 0
		summary.first_row = 0
		present += summary.row_count
	}
	for _ in present ..< NAME_ROW_COUNT {
		most := -1
		most_hidden := 0
		for kind in File_Kind {
			if layout.kinds[kind].row_count == 0 {
				continue
			}
			hidden := layout.kinds[kind].count - kind_place(layout, kind, width, false)
			if hidden > most_hidden {
				most = int(kind)
				most_hidden = hidden
			}
		}
		if most < 0 {
			break
		}
		layout.kinds[File_Kind(most)].row_count += 1
	}
	row := 0
	for kind in File_Kind {
		summary := &layout.kinds[kind]
		summary.first_row = row
		summary.named = kind_place(layout, kind, width, true)
		row += summary.row_count
	}
}

// kind_place places the tiles of one kind, from its largest file, in the
// rows of the kind, and gives the count of the files with a tile. The
// first name that does not fit ends the kind: a smaller file never takes
// the place of a larger one. The last row keeps room for the count of the
// files with no tile. With write false, it only counts.
@(private)
kind_place :: proc "contextless" (layout: ^Layout, kind: File_Kind, width: int, write: bool) -> (named: int) {
	summary := &layout.kinds[kind]
	if summary.row_count == 0 {
		return 0
	}
	row, x := 0, 0
	for index in summary.first ..< summary.end {
		tile_width := len(layout.files[index].name) * CELL_WIDTH + 2 * TILE_PADDING
		after := summary.count - named - 1 // The files after this one.
		placed := false
		for {
			last_row := row == summary.row_count - 1
			reserve := last_row && after > 0 ? TILE_GAP + more_width(after) : 0
			if x + tile_width + reserve <= width && (!write || layout.tile_count < TILE_CAPACITY) {
				placed = true
				break
			}
			if last_row || x == 0 {
				break
			}
			row += 1
			x = 0
		}
		if !placed {
			break
		}
		if write {
			layout.tiles[layout.tile_count] = {file = index, row = summary.first_row + row, x = x, width = tile_width}
			layout.tile_count += 1
		}
		x += tile_width + TILE_GAP
		named += 1
	}
	if write {
		summary.more_row = summary.first_row + row
		summary.more_x = x
	}
	return
}

// file_total gives the count of all the files of the image.
file_total :: proc "contextless" (layout: ^Layout) -> (total: int) {
	for summary in layout.kinds {
		total += summary.count
	}
	return
}

// byte_total gives the bytes of all the files of the image.
byte_total :: proc "contextless" (layout: ^Layout) -> (total: u64) {
	for summary in layout.kinds {
		total += summary.bytes
	}
	return
}
