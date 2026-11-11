// The random generator of a program (docs/RANDOMNESS.md): ChaCha20 with
// fast key erasure (D. J. Bernstein, "Fast-key-erasure random-number
// generators", 2017). Its state is a record of fixed size in the memory of
// the program (property 14); a draw makes no kernel entry and no call.
//
// Each refill runs ChaCha20 with the key and the nonce 0 for 13 blocks: the
// first 32 bytes are the next key, the next 800 bytes are served in order.
// The key that made them is erased at once, and each byte is erased when it
// is served: a copy of the state after a draw does not give the bytes
// before it (backtracking resistance).
//
// The ChaCha20 is the code of Odin's core:crypto that the system took
// (support/cryptography, docs/CRYPTOGRAPHY.md), checked against RFC 8439.
package random

import "base:runtime"
import op "contract:operation"
import "support:system"
import "support:cryptography/chacha20"
import crypto "support:cryptography/compatibility_crypto"

SEED_SIZE :: 32
REFILL_BLOCKS :: 13
REFILL_SIZE :: REFILL_BLOCKS * 64
BUFFER_SIZE :: REFILL_SIZE - SEED_SIZE

// A zero Generator is not seeded: a draw from it stops the program (a
// check), so that no program draws numbers from a known key.
Generator :: struct {
	key:       [SEED_SIZE]u8,
	buffer:    [BUFFER_SIZE]u8,
	available: int, // Bytes of the buffer not served: they are its last ones.
	seeded:    bool,
	refills:   u64,
	served:    u64, // Bytes served since the seed.
}

// generator_seed keys a generator with a seed of 32 bytes, and erases the
// seed of the caller. A seed of 32 zero bytes is refused: it is the value
// of "no seed" (a starter that did not give one).
generator_seed :: proc "contextless" (generator: ^Generator, seed: ^[SEED_SIZE]u8) -> bool {
	if crypto.is_zero_constant_time(seed[:]) == 1 {
		return false
	}
	generator^ = {}
	generator.key = seed^
	crypto.zero_explicit(seed, SEED_SIZE)
	generator.seeded = true
	return true
}

// refill makes the next 800 bytes and the next key.
@(private)
refill :: proc "contextless" (generator: ^Generator) {
	context = runtime.default_context()
	nonce: [12]u8
	block: [REFILL_SIZE]u8
	cipher: chacha20.Context
	chacha20.init(&cipher, generator.key[:], nonce[:])
	chacha20.keystream_bytes(&cipher, block[:])
	chacha20.reset(&cipher)
	copy(generator.key[:], block[:SEED_SIZE])
	copy(generator.buffer[:], block[SEED_SIZE:])
	crypto.zero_explicit(&block, size_of(block))
	generator.available = BUFFER_SIZE
	generator.refills += 1
}

// fill writes random bytes in output. A generator that is not seeded stops
// the program.
fill :: proc "contextless" (generator: ^Generator, output: []u8) {
	ensure_contextless(generator.seeded, "random: a draw from a generator with no seed")
	done := 0
	for done < len(output) {
		if generator.available == 0 {
			refill(generator)
		}
		start := BUFFER_SIZE - generator.available
		count := min(generator.available, len(output) - done)
		copy(output[done:][:count], generator.buffer[start:][:count])
		crypto.zero_explicit(&generator.buffer[start], count)
		generator.available -= count
		done += count
	}
	generator.served += u64(len(output))
}

// next_u64 gives a random number of 64 bits.
next_u64 :: proc "contextless" (generator: ^Generator) -> u64 {
	value: u64
	fill(generator, ([^]u8)(&value)[:8])
	return value
}

// seed_for_a_child gives the seed of a program that this program starts:
// 32 bytes of its own stream, which it never serves again. The starter
// knows the seed of its child: a child has no secret from the program that
// starts it, which already chooses its code and its grants.
seed_for_a_child :: proc "contextless" (generator: ^Generator) -> (seed: [SEED_SIZE]u8) {
	fill(generator, seed[:])
	return
}

// reseed mixes new bytes (of the processor, or of a device) into the key:
// the next key is BLAKE3 of the old key and the bytes (see entropy.odin),
// and the buffer is dropped.
reseed :: proc "contextless" (generator: ^Generator, fresh: []u8) {
	ensure_contextless(generator.seeded, "random: a reseed of a generator with no seed")
	generator.key = key_derive(DOMAIN_RESEED, generator.key[:], fresh)
	crypto.zero_explicit(&generator.buffer, size_of(generator.buffer))
	generator.available = 0
}

// generator_from_context seeds the generator of a program with the seed of
// its context (the values 9 to 12), and erases the seed there. false: the
// context has no seed (the root service).
generator_from_context :: proc "contextless" (generator: ^Generator, ctx: ^system.Context) -> bool {
	seed: [SEED_SIZE]u8
	for index in 0 ..< op.CONTEXT_VALUE_SEED_COUNT {
		value := ctx.values[op.CONTEXT_VALUE_SEED + index]
		for byte in 0 ..< 8 {
			seed[index * 8 + byte] = u8(value >> (8 * uint(byte)))
		}
	}
	crypto.zero_explicit(&ctx.values[op.CONTEXT_VALUE_SEED], op.CONTEXT_VALUE_SEED_COUNT * 8)
	return generator_seed(generator, &seed)
}

// values_with_seed gives the values of a program to start with a seed for
// it from the generator of this program (system.program_start refuses a
// start with no seed).
values_with_seed :: proc "contextless" (generator: ^Generator, values: [op.CONTEXT_VALUES]u64) -> (with_seed: [op.CONTEXT_VALUES]u64) {
	with_seed = values
	seed := seed_for_a_child(generator)
	for index in 0 ..< op.CONTEXT_VALUE_SEED_COUNT {
		value: u64
		for byte in 0 ..< 8 {
			value |= u64(seed[index * 8 + byte]) << (8 * uint(byte))
		}
		with_seed[op.CONTEXT_VALUE_SEED + index] = value
	}
	crypto.zero_explicit(&seed, SEED_SIZE)
	return
}
