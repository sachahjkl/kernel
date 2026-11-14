#+build amd64
package blake3

import "base:intrinsics"

// The chunks of a subtree compressed side by side (docs/SIMD.md): one chunk
// in each lane of an SSE2 register of four words of 32 bits, so one
// instruction does the same step of the compression of four chunks. Each of
// the 16 words of the state is one vector: lane i is the word of chunk i.
// The steps of a round are the steps of the scalar form, lane by lane, so
// the chaining value of each chunk is the one of chunk_value.
//
// The words of a block are read from the four chunks and turned so that
// word k of each chunk is in one vector: a transpose of a square of 4 x 4
// words, with shuffles. The chaining values of the chunks are then joined
// by the parents of the scalar form. The words are read as little endian:
// this file is for amd64 only.

// Four words of 32 bits: one word of each of four chunks.
@(private)
Four_Words :: #simd[4]u32

@(private)
subtree_value_of_four_chunks_sse2 :: proc "contextless" (input: []u8, chunk_counter: u64) -> [8]u32 {
	values := four_chunk_values_side_by_side(input, chunk_counter)
	return subtree_value_of_chunk_values(values[:])
}

// four_chunk_values_side_by_side gives the chaining values of the four whole
// chunks of input, the first with chunk_counter: the values of chunk_value
// for each one. input has exactly four chunks.
@(private)
four_chunk_values_side_by_side :: proc "contextless" (input: []u8, chunk_counter: u64) -> (values: [4][8]u32) #no_bounds_check {
	initial := INITIAL_VALUE
	chaining: [8]Four_Words
	for index in 0 ..< 8 {
		chaining[index] = four_copies_of(initial[index])
	}
	// The counter of each chunk, in two words: the low word can pass 2^32
	// from one lane to the next, so each lane is computed whole.
	counter_low, counter_high: [4]u32
	for lane in 0 ..< 4 {
		counter := chunk_counter + u64(lane)
		counter_low[lane] = u32(counter)
		counter_high[lane] = u32(counter >> 32)
	}
	permutation := MESSAGE_PERMUTATION
	BLOCK_COUNT :: CHUNK_SIZE / BLOCK_SIZE
	for block in 0 ..< BLOCK_COUNT {
		message := message_words_side_by_side(input, block)
		flags: Flags
		if block == 0 {
			flags += {.Chunk_Start}
		}
		if block == BLOCK_COUNT - 1 {
			flags += {.Chunk_End}
		}
		state: [16]Four_Words
		for index in 0 ..< 8 {
			state[index] = chaining[index]
		}
		for index in 0 ..< 4 {
			state[8 + index] = four_copies_of(initial[index])
		}
		state[12] = transmute(Four_Words)counter_low
		state[13] = transmute(Four_Words)counter_high
		state[14] = four_copies_of(BLOCK_SIZE)
		state[15] = four_copies_of(transmute(u32)flags)
		for round in 0 ..< ROUND_COUNT {
			mix_lanes(&state, 0, 4, 8, 12, message[0], message[1])
			mix_lanes(&state, 1, 5, 9, 13, message[2], message[3])
			mix_lanes(&state, 2, 6, 10, 14, message[4], message[5])
			mix_lanes(&state, 3, 7, 11, 15, message[6], message[7])
			mix_lanes(&state, 0, 5, 10, 15, message[8], message[9])
			mix_lanes(&state, 1, 6, 11, 12, message[10], message[11])
			mix_lanes(&state, 2, 7, 8, 13, message[12], message[13])
			mix_lanes(&state, 3, 4, 9, 14, message[14], message[15])
			if round < ROUND_COUNT - 1 {
				permuted: [16]Four_Words
				for index in 0 ..< 16 {
					permuted[index] = message[permutation[index]]
				}
				message = permuted
			}
		}
		for index in 0 ..< 8 {
			chaining[index] = intrinsics.simd_bit_xor(state[index], state[index + 8])
		}
	}
	for index in 0 ..< 8 {
		words := transmute([4]u32)chaining[index]
		for lane in 0 ..< 4 {
			values[lane][index] = words[lane]
		}
	}
	return
}

@(private)
four_copies_of :: #force_inline proc "contextless" (value: u32) -> Four_Words {
	return Four_Words{value, value, value, value}
}

// message_words_side_by_side reads block number block of each chunk, and
// gives word k of the block of chunk i in lane i of vector k.
@(private)
message_words_side_by_side :: #force_inline proc "contextless" (input: []u8, block: int) -> (message: [16]Four_Words) #no_bounds_check {
	// Four rows of four words (words 4q to 4q + 3 of each chunk), turned
	// into four columns.
	for quarter in 0 ..< 4 {
		rows: [4]Four_Words
		for lane in 0 ..< 4 {
			rows[lane] = intrinsics.unaligned_load((^Four_Words)(&input[lane * CHUNK_SIZE + block * BLOCK_SIZE + quarter * 16]))
		}
		first_pairs := intrinsics.simd_shuffle(rows[0], rows[1], 0, 4, 1, 5) // 0 of chunk 0, 0 of 1, 1 of 0, 1 of 1
		second_pairs := intrinsics.simd_shuffle(rows[0], rows[1], 2, 6, 3, 7)
		third_pairs := intrinsics.simd_shuffle(rows[2], rows[3], 0, 4, 1, 5)
		fourth_pairs := intrinsics.simd_shuffle(rows[2], rows[3], 2, 6, 3, 7)
		message[quarter * 4 + 0] = intrinsics.simd_shuffle(first_pairs, third_pairs, 0, 1, 4, 5)
		message[quarter * 4 + 1] = intrinsics.simd_shuffle(first_pairs, third_pairs, 2, 3, 6, 7)
		message[quarter * 4 + 2] = intrinsics.simd_shuffle(second_pairs, fourth_pairs, 0, 1, 4, 5)
		message[quarter * 4 + 3] = intrinsics.simd_shuffle(second_pairs, fourth_pairs, 2, 3, 6, 7)
	}
	return
}

// mix_lanes is mix of the scalar form, in each lane.
@(private)
mix_lanes :: #force_inline proc "contextless" (state: ^[16]Four_Words, a, b, c, d: int, x, y: Four_Words) {
	state[a] = state[a] + state[b] + x
	state[d] = rotate_lanes_right(intrinsics.simd_bit_xor(state[d], state[a]), 16)
	state[c] = state[c] + state[d]
	state[b] = rotate_lanes_right(intrinsics.simd_bit_xor(state[b], state[c]), 12)
	state[a] = state[a] + state[b] + y
	state[d] = rotate_lanes_right(intrinsics.simd_bit_xor(state[d], state[a]), 8)
	state[c] = state[c] + state[d]
	state[b] = rotate_lanes_right(intrinsics.simd_bit_xor(state[b], state[c]), 7)
}

@(private)
rotate_lanes_right :: #force_inline proc "contextless" (value: Four_Words, $COUNT: u32) -> Four_Words {
	return intrinsics.simd_bit_or(intrinsics.simd_shr(value, Four_Words(COUNT)), intrinsics.simd_shl(value, Four_Words(32 - COUNT)))
}
