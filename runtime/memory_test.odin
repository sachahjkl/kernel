#+build !freestanding
// The tests of runtime/memory.asm on the host. The compiler assembles
// memory_for_host_tests.asm, which includes the file with HOST defined: the
// object then has the long names only, so the host keeps its own memcpy.
// Run from the root of the repository (the include names runtime/memory.asm).
package memory

import "base:intrinsics"
import "core:testing"

foreign import memory "memory_for_host_tests.asm"

@(default_calling_convention = "c")
foreign memory {
	copy_bytes_without_overlap :: proc(destination, source: rawptr, count: int) -> rawptr ---
	copy_bytes_with_overlap :: proc(destination, source: rawptr, count: int) -> rawptr ---
	fill_bytes_with_value :: proc(destination: rawptr, value: i32, count: int) -> rawptr ---
	erase_secret_bytes :: proc(destination: rawptr, count: int) -> rawptr ---
	erase_stack_below_the_caller :: proc() ---
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

// erase_secret_bytes writes 0 in each byte of the range, and no byte
// around it.
@(test)
erase_each_size :: proc(t: ^testing.T) {
	area: [300]u8
	for count in 0 ..< 256 {
		for &value in area {
			value = 0xA5
		}
		result := erase_secret_bytes(&area[16], count)
		testing.expect(t, result == &area[16])
		for value, index in area {
			wanted: u8 = index >= 16 && index < 16 + count ? 0 : 0xA5
			if value != wanted {
				testing.expectf(t, false, "count %d: the byte %d is %x", count, index, value)
				return
			}
		}
	}
}

// fill_a_frame_with_a_pattern writes a pattern in a local area of 4 KiB and
// gives its address: after the return, the area is below the stack pointer
// of the caller, where a secret of a callee stays.
@(private = "file")
fill_a_frame_with_a_pattern :: #force_no_inline proc "contextless" () -> uintptr {
	area: [4096]u8
	for &value in area {
		value = 0xA5
	}
	intrinsics.volatile_store(&area[0], 0xA5)
	return uintptr(&area[0])
}

// erase_stack_below_the_caller writes 0 in the frames below the stack
// pointer of its caller: the frame of a procedure that returned is zero
// after it. The bytes are read by a loop with no call, so that no frame
// takes the area again before the count.
@(test)
erase_the_stack_below_the_caller :: proc(t: ^testing.T) {
	address := fill_a_frame_with_a_pattern()
	pattern_before := 0
	for index in 0 ..< 4096 {
		if intrinsics.volatile_load((^u8)(address + uintptr(index))) == 0xA5 {
			pattern_before += 1
		}
	}
	address = fill_a_frame_with_a_pattern()
	erase_stack_below_the_caller()
	nonzero_after := 0
	for index in 0 ..< 4096 {
		if intrinsics.volatile_load((^u8)(address + uintptr(index))) != 0 {
			nonzero_after += 1
		}
	}
	// The pattern was there before (the test proves itself), and no byte
	// of it is left after the erasure.
	testing.expect(t, pattern_before > 3000)
	testing.expect_value(t, nonzero_after, 0)
}
