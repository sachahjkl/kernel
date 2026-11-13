// BLAKE3: the content hash of the system (docs/MODULE_CONTRACT.md).
//
// This is the plain hash mode only, for an input that is whole in memory.
// It is written from the BLAKE3 specification. It allocates no memory, so the
// boot program and the kernel can use it.
//
// On amd64 the chunks of a subtree of four whole chunks are compressed side
// by side, one chunk in each lane of an SSE2 register
// (chunks_side_by_side_amd64.odin, docs/SIMD.md). The scalar form here is the
// reference, and the code of every other part of the tree.
//
// Who uses it: the boot program and the root service (the system
// description), the loaders (the name of a module is the hash of its file),
// the storage service (the hash of an object, `subtree_chaining_value`), the
// glyph caches and the debug objects.
//
// Example: `blake3.hash(file)` is the name of a module in the boot image.
package blake3

import "base:intrinsics"

HASH_SIZE :: 32 // The bytes of a hash.
BLOCK_SIZE :: 64 // The bytes of one block of the compression.
CHUNK_SIZE :: 1024 // The bytes of one chunk: 16 blocks, a leaf of the tree.

// A hash of 32 bytes.
Hash :: [HASH_SIZE]u8

// The domain flags of a compression (the BLAKE3 specification, section 2.1).
@(private)
Flag :: enum u32 {
	Chunk_Start = 0, // The first block of a chunk.
	Chunk_End   = 1, // The last block of a chunk.
	Parent      = 2, // A parent node of the tree.
	Root        = 3, // The root: its output is the hash.
}

// The flags of one compression.
@(private)
Flags :: bit_set[Flag;u32]

// The initial value: the one of SHA-256.
@(private)
INITIAL_VALUE :: [8]u32{0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19}

// The permutation of the words of the message between two rounds.
@(private)
MESSAGE_PERMUTATION :: [16]int{2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8}

// The rounds of one compression.
@(private)
ROUND_COUNT :: 7

// hash gives the BLAKE3 hash of input.
hash :: proc "contextless" (input: []u8) -> Hash {
	return hash_in_form(input, ODIN_ARCH == .amd64)
}

// hash_in_form gives the hash with the chunks of each subtree of four chunks
// compressed side by side, or with the scalar form only: the host tests
// compare the two.
@(private)
hash_in_form :: proc "contextless" (input: []u8, side_by_side: bool) -> (result: Hash) {
	words: [8]u32
	if len(input) <= CHUNK_SIZE {
		words = chunk_value(input, 0, {.Root})
	} else {
		left := left_size(len(input))
		block := parent_block(subtree_value(input[:left], 0, side_by_side), subtree_value(input[left:], u64(left / CHUNK_SIZE), side_by_side))
		words = first_half(compress(INITIAL_VALUE, block, 0, BLOCK_SIZE, {.Parent, .Root}))
	}
	for word, i in words {
		result[i * 4 + 0] = u8(word)
		result[i * 4 + 1] = u8(word >> 8)
		result[i * 4 + 2] = u8(word >> 16)
		result[i * 4 + 3] = u8(word >> 24)
	}
	return
}

// A chaining value: the 8 words that a part of the tree gives to its
// parent. The storage service keeps the chaining value of each block of an
// object, so that a change of a few blocks hashes those blocks and their
// parents only (docs/STORAGE.md, "The hash of an object").
Chaining_Value :: [8]u32

// subtree_chaining_value gives the chaining value of a part of an input that
// is not its root: the chunks from the chunk `chunk_counter`, as the tree of
// the whole input cuts it (a power of two of whole chunks, or the part at
// the end).
subtree_chaining_value :: proc "contextless" (input: []u8, chunk_counter: u64) -> Chaining_Value {
	return subtree_value(input, chunk_counter, ODIN_ARCH == .amd64)
}

// parent_chaining_value gives the chaining value of a parent that is not
// the root, from the chaining values of its two children.
parent_chaining_value :: proc "contextless" (left, right: Chaining_Value) -> Chaining_Value {
	return first_half(compress(INITIAL_VALUE, parent_block(left, right), 0, BLOCK_SIZE, {.Parent}))
}

// root_of_children gives the hash of an input of more than one chunk, from
// the chaining values of the two children of its root.
root_of_children :: proc "contextless" (left, right: Chaining_Value) -> (result: Hash) {
	words := first_half(compress(INITIAL_VALUE, parent_block(left, right), 0, BLOCK_SIZE, {.Parent, .Root}))
	for word, i in words {
		result[i * 4 + 0] = u8(word)
		result[i * 4 + 1] = u8(word >> 8)
		result[i * 4 + 2] = u8(word >> 16)
		result[i * 4 + 3] = u8(word >> 24)
	}
	return
}

// left_size gives the size of the left subtree of an input of more than one
// chunk: the largest power of two of chunks that is less than the input.
@(private)
left_size :: proc "contextless" (size: int) -> int {
	chunks := (size - 1) / CHUNK_SIZE
	power := 1
	for power * 2 <= chunks {
		power *= 2
	}
	return power * CHUNK_SIZE
}

// subtree_value gives the chaining value of a subtree that is not the root.
// With side_by_side, a subtree of exactly four chunks (the left part of a
// tree is always a power of two of whole chunks) has its chunks compressed
// side by side in the SSE2 form.
@(private)
subtree_value :: proc "contextless" (input: []u8, chunk_counter: u64, side_by_side: bool) -> [8]u32 {
	if len(input) <= CHUNK_SIZE {
		return chunk_value(input, chunk_counter, {})
	}
	when ODIN_ARCH == .amd64 {
		if side_by_side && len(input) == 4 * CHUNK_SIZE {
			return subtree_value_of_four_chunks_sse2(input, chunk_counter)
		}
	}
	left := left_size(len(input))
	block := parent_block(
		subtree_value(input[:left], chunk_counter, side_by_side),
		subtree_value(input[left:], chunk_counter + u64(left / CHUNK_SIZE), side_by_side),
	)
	return first_half(compress(INITIAL_VALUE, block, 0, BLOCK_SIZE, {.Parent}))
}

// subtree_value_of_chunk_values joins the chaining values of a power of two
// of whole chunks, two by two, as subtree_value does: the parent of each
// pair, then the parent of each pair of parents. values is changed.
@(private)
subtree_value_of_chunk_values :: #force_inline proc "contextless" (values: [][8]u32) -> [8]u32 {
	count := len(values)
	for count > 1 {
		for index in 0 ..< count / 2 {
			values[index] = first_half(compress(INITIAL_VALUE, parent_block(values[2 * index], values[2 * index + 1]), 0, BLOCK_SIZE, {.Parent}))
		}
		count /= 2
	}
	return values[0]
}

// parent_block gives the message of a parent node: the two chaining
// values of its children.
@(private)
parent_block :: proc "contextless" (left, right: [8]u32) -> (block: [16]u32) {
	for i in 0 ..< 8 {
		block[i] = left[i]
		block[i + 8] = right[i]
	}
	return
}

// first_half gives the first 8 words of a state: the chaining value.
@(private)
first_half :: proc "contextless" (state: [16]u32) -> (half: [8]u32) {
	for i in 0 ..< 8 {
		half[i] = state[i]
	}
	return
}

// chunk_value gives the chaining value of one chunk of at most CHUNK_SIZE bytes.
@(private)
chunk_value :: proc "contextless" (chunk: []u8, chunk_counter: u64, last_flags: Flags) -> [8]u32 {
	value := INITIAL_VALUE
	rest := chunk
	flags := Flags{.Chunk_Start}
	for {
		size := min(len(rest), BLOCK_SIZE)
		bytes: [BLOCK_SIZE]u8
		intrinsics.mem_copy_non_overlapping(&bytes, raw_data(rest), size)
		block: [16]u32
		for i in 0 ..< 16 {
			block[i] = u32(bytes[i * 4]) | u32(bytes[i * 4 + 1]) << 8 | u32(bytes[i * 4 + 2]) << 16 | u32(bytes[i * 4 + 3]) << 24
		}
		rest = rest[size:]
		if len(rest) == 0 {
			flags += {.Chunk_End} + last_flags
		}
		value = first_half(compress(value, block, chunk_counter, u32(size), flags))
		if len(rest) == 0 {
			return value
		}
		flags = {}
	}
}

// compress is the compression function of BLAKE3: 7 rounds over a block,
// with the chaining value, the counter, the bytes of the block and the
// flags. It gives the whole state; the chaining value is its first half.
@(private)
compress :: proc "contextless" (value: [8]u32, block: [16]u32, counter: u64, block_size: u32, flags: Flags) -> [16]u32 {
	initial := INITIAL_VALUE
	state := [16]u32 {
		value[0],
		value[1],
		value[2],
		value[3],
		value[4],
		value[5],
		value[6],
		value[7],
		initial[0],
		initial[1],
		initial[2],
		initial[3],
		u32(counter),
		u32(counter >> 32),
		block_size,
		transmute(u32)flags,
	}
	message := block
	permutation := MESSAGE_PERMUTATION
	for round in 0 ..< ROUND_COUNT {
		mix(&state, 0, 4, 8, 12, message[0], message[1])
		mix(&state, 1, 5, 9, 13, message[2], message[3])
		mix(&state, 2, 6, 10, 14, message[4], message[5])
		mix(&state, 3, 7, 11, 15, message[6], message[7])
		mix(&state, 0, 5, 10, 15, message[8], message[9])
		mix(&state, 1, 6, 11, 12, message[10], message[11])
		mix(&state, 2, 7, 8, 13, message[12], message[13])
		mix(&state, 3, 4, 9, 14, message[14], message[15])
		if round < ROUND_COUNT - 1 {
			permuted: [16]u32
			for i in 0 ..< 16 {
				permuted[i] = message[permutation[i]]
			}
			message = permuted
		}
	}
	for i in 0 ..< 8 {
		state[i] ~= state[i + 8]
		state[i + 8] ~= value[i]
	}
	return state
}

// mix is the quarter-round G of the specification, on four words of the
// state and two words of the message.
@(private)
mix :: #force_inline proc "contextless" (state: ^[16]u32, a, b, c, d: int, x, y: u32) {
	state[a] = state[a] + state[b] + x
	state[d] = rotate_right(state[d] ~ state[a], 16)
	state[c] = state[c] + state[d]
	state[b] = rotate_right(state[b] ~ state[c], 12)
	state[a] = state[a] + state[b] + y
	state[d] = rotate_right(state[d] ~ state[a], 8)
	state[c] = state[c] + state[d]
	state[b] = rotate_right(state[b] ~ state[c], 7)
}

// rotate_right rotates the bits of a word to the right.
@(private)
rotate_right :: #force_inline proc "contextless" (value: u32, count: u32) -> u32 {
	return value >> count | value << (32 - count)
}
