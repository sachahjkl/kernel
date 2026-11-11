#+build !freestanding
package blake3

import "core:fmt"
import "core:testing"
import "core:time"

// The SSE2 form of BLAKE3 (four chunks side by side) against the scalar
// form (docs/SIMD.md): the same hash for each input. The scalar form meets
// the official test vectors (blake3_test.odin), so the SSE2 form meets them
// too. The inputs come from a generator with a fixed seed.

@(private = "file")
Test_Random :: struct {
	state: u64,
}

@(private = "file")
next_random :: proc(random: ^Test_Random) -> u64 {
	random.state ~= random.state >> 12
	random.state ~= random.state << 25
	random.state ~= random.state >> 27
	return random.state * 0x2545F4914F6CDD1D
}

// Every length from 0 to 67, the lengths at the edges of a chunk and of a
// subtree of four chunks, the lengths of the official vectors, and random
// lengths; each at every place of the input against a boundary of
// 16 bytes, from 0 to 15.
@(test)
sse2_form_gives_the_hash_of_the_scalar_form :: proc(t: ^testing.T) {
	random := Test_Random{state = 0x9E3779B97F4A7C15}
	LONGEST :: 102400 + 16
	buffer := make([]u8, LONGEST + 16)
	defer delete(buffer)
	for &byte_value in buffer {
		byte_value = u8(next_random(&random))
	}
	lengths := make([dynamic]int)
	defer delete(lengths)
	for length in 0 ..= 67 {
		append(&lengths, length)
	}
	for chunks in ([?]int{1, 2, 3, 4, 5, 7, 8, 9, 12, 16, 17, 31, 32, 33, 64}) {
		append(&lengths, chunks * CHUNK_SIZE - 1, chunks * CHUNK_SIZE, chunks * CHUNK_SIZE + 1)
	}
	append(&lengths, 1023, 3072, 3073, 5120, 5121, 6144, 6145, 7168, 7169, 31744, 102400)
	for _ in 0 ..< 24 {
		append(&lengths, int(next_random(&random) % 70000))
	}
	wrong := 0
	for length in lengths {
		places := length <= 20000 ? 16 : 2
		for place in 0 ..< places {
			input := buffer[place:][:length]
			if hash_in_form(input, true) != hash_in_form(input, false) {
				wrong += 1
				if wrong <= 5 {
					testing.expectf(t, false, "length %d, place %d: the hash of the SSE2 form differs from the scalar form", length, place)
				}
			}
		}
	}
	testing.expect_value(t, wrong, 0)
}

// The subtrees of four chunks at chunk counters where the low word of the
// counter passes 2^32 from one lane to the next, and at the largest
// counters.
@(test)
subtrees_side_by_side_at_each_counter :: proc(t: ^testing.T) {
	random := Test_Random{state = 0x2545F4914F6CDD1D}
	input := make([]u8, 4 * CHUNK_SIZE)
	defer delete(input)
	counters := [?]u64{0, 1, 0xFFFF_FFFC, 0xFFFF_FFFD, 0xFFFF_FFFE, 0xFFFF_FFFF, 0x1_0000_0000, 0x1_FFFF_FFFB, 1 << 40 + 3, max(u64) - 4}
	wrong := 0
	for counter in counters {
		for &byte_value in input {
			byte_value = u8(next_random(&random))
		}
		if subtree_value_of_four_chunks_sse2(input, counter) != subtree_value(input, counter, false) {
			wrong += 1
			testing.expectf(t, false, "counter %x: the value of the SSE2 form differs from the scalar form", counter)
		}
	}
	testing.expect_value(t, wrong, 0)
}

// The time of the hash of 390624 bytes (the size of the glyph cache, whose
// hash the root service checks at its start) in each form, on the host:
// the least of 20 runs.
@(test)
hash_cost_of_each_form :: proc(t: ^testing.T) {
	SIZE :: 390624
	input := make([]u8, SIZE)
	defer delete(input)
	random := Test_Random{state = 7}
	for &byte_value in input {
		byte_value = u8(next_random(&random))
	}
	reference := hash_in_form(input, false)
	names := [2]string{"scalar", "SSE2"}
	for side_by_side, index in ([2]bool{false, true}) {
		least := max(i64)
		result: Hash
		for _ in 0 ..< 20 {
			start := time.tick_now()
			result = hash_in_form(input, side_by_side)
			least = min(least, time.duration_nanoseconds(time.tick_since(start)))
		}
		testing.expectf(t, result == reference, "the %s form: the hash differs from the scalar form", names[index])
		fmt.printfln("blake3: %d bytes on the host, the %s form: %d us", SIZE, names[index], least / 1000)
	}
}
