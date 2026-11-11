#+build !freestanding
// The tests of runtime/memory.asm on the host. The kernel tool assembles
// the file with -DHOST into build/runtime_host.o before `odin test`: the
// file then has the long names only, so the host keeps its own memcpy.
package memory

import "core:testing"

foreign import memory "../build/runtime_host.o"

@(default_calling_convention = "c")
foreign memory {
	copy_bytes_without_overlap :: proc(destination, source: rawptr, count: int) -> rawptr ---
	copy_bytes_with_overlap :: proc(destination, source: rawptr, count: int) -> rawptr ---
	fill_bytes_with_value :: proc(destination: rawptr, value: i32, count: int) -> rawptr ---
}

AREA :: 4096

// pattern gives a byte that differs at each place and in each area.
@(private = "file")
pattern :: proc(area: []u8, seed: int) {
	for &value, index in area {
		value = u8((index * 31 + seed * 7 + index / 251) & 0xFF)
	}
}

// move_by_bytes is the meaning of memmove: the bytes of the source as they
// were before the call.
@(private = "file")
move_by_bytes :: proc(area: []u8, destination, source, count: int) {
	saved := make([]u8, count, context.temp_allocator)
	copy(saved, area[source:][:count])
	copy(area[destination:][:count], saved)
}

@(test)
copy_each_size_and_alignment :: proc(t: ^testing.T) {
	source := make([]u8, AREA)
	defer delete(source)
	result := make([]u8, AREA)
	defer delete(result)
	expected := make([]u8, AREA)
	defer delete(expected)
	pattern(source, 1)
	for count in 0 ..= 300 {
		for to in 0 ..< 16 {
			for from in 0 ..< 16 {
				pattern(result, 2)
				pattern(expected, 2)
				copy(expected[64 + to:][:count], source[64 + from:][:count])
				given := copy_bytes_without_overlap(&result[64 + to], &source[64 + from], count)
				if given != rawptr(&result[64 + to]) || string(result) != string(expected) {
					testing.expectf(t, false, "copy: count %d, destination %d, source %d", count, to, from)
					return
				}
			}
		}
	}
}

@(test)
move_each_size_alignment_and_overlap :: proc(t: ^testing.T) {
	area := make([]u8, AREA)
	defer delete(area)
	expected := make([]u8, AREA)
	defer delete(expected)
	for count in 0 ..= 300 {
		// The distances: none, small ones both ways, and the ones near the count.
		distances := [?]int{0, 1, -1, 2, -2, 3, -3, 7, -7, 8, -8, 15, -15, 16, -16, 17, -17, 31, -31, 63, -63, 64, -64, 65, -65, count / 2, -count / 2, count - 1, -(count - 1), count, -count, count + 1, -(count + 1)}
		for alignment in 0 ..< 16 {
			for distance in distances {
				source := 512 + alignment
				destination := source + distance
				pattern(area, count + alignment)
				pattern(expected, count + alignment)
				move_by_bytes(expected, destination, source, count)
				given := copy_bytes_with_overlap(&area[destination], &area[source], count)
				if given != rawptr(&area[destination]) || string(area) != string(expected) {
					testing.expectf(t, false, "move: count %d, alignment %d, distance %d", count, alignment, distance)
					return
				}
			}
		}
	}
}

@(test)
fill_each_size_and_alignment :: proc(t: ^testing.T) {
	area := make([]u8, AREA)
	defer delete(area)
	expected := make([]u8, AREA)
	defer delete(expected)
	for count in 0 ..= 300 {
		for to in 0 ..< 16 {
			for value in ([?]u8{0, 0xA5, 0xFF}) {
				pattern(area, 3)
				pattern(expected, 3)
				for &byte in expected[64 + to:][:count] {
					byte = value
				}
				given := fill_bytes_with_value(&area[64 + to], i32(value) | 0x7700, count) // Only the low byte counts.
				if given != rawptr(&area[64 + to]) || string(area) != string(expected) {
					testing.expectf(t, false, "fill: count %d, destination %d, value %d", count, to, value)
					return
				}
			}
		}
	}
}

// The sizes where the form changes (2048, 4096, 1 MiB), and around them.
@(test)
large_sizes :: proc(t: ^testing.T) {
	SIZE :: 4 << 20 // The source in the middle, and the destination one count and 64 bytes away.
	area := make([]u8, SIZE)
	defer delete(area)
	expected := make([]u8, SIZE)
	defer delete(expected)
	counts := [?]int{2047, 2048, 2049, 4095, 4096, 4097, 65536 + 5, (1 << 20) - 1, 1 << 20, (1 << 20) + 13}
	for count in counts {
		for distance in ([?]int{-4096, -17, -1, 1, 17, 4096, count + 64, -(count + 64)}) {
			source := SIZE / 2 - count / 2 + 3
			destination := source + distance
			pattern(area, count)
			pattern(expected, count)
			move_by_bytes(expected, destination, source, count)
			copy_bytes_with_overlap(&area[destination], &area[source], count)
			testing.expectf(t, string(area) == string(expected), "move: count %d, distance %d", count, distance)
			if distance == count + 64 || distance == -(count + 64) {
				pattern(area, count)
				copy_bytes_without_overlap(&area[destination], &area[source], count)
				testing.expectf(t, string(area) == string(expected), "copy: count %d, distance %d", count, distance)
			}
		}
		pattern(area, count)
		pattern(expected, count)
		for &byte in expected[5:][:count] {
			byte = 0x3C
		}
		fill_bytes_with_value(&area[5], 0x3C, count)
		testing.expectf(t, string(area) == string(expected), "fill: count %d", count)
	}
}
