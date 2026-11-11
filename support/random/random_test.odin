#+build !freestanding
package random

import "core:testing"
import "support:cryptography/chacha20"

seed_of :: proc(first: u8) -> (seed: [SEED_SIZE]u8) {
	for &byte, index in seed {
		byte = first + u8(index)
	}
	return
}

// The generator serves the ChaCha20 stream of its key after its first 32
// bytes, then the stream of the next key: fast key erasure, checked against
// the ChaCha20 that passes RFC 8439.
@(test)
generator_is_chacha20_with_fast_key_erasure :: proc(t: ^testing.T) {
	seed := seed_of(1)
	key := seed
	generator: Generator
	testing.expect(t, generator_seed(&generator, &seed))
	testing.expect(t, seed == [SEED_SIZE]u8{}) // The seed of the caller is erased.
	drawn: [2 * BUFFER_SIZE]u8
	fill(&generator, drawn[:])
	for round in 0 ..< 2 {
		nonce: [12]u8
		block: [REFILL_SIZE]u8
		cipher: chacha20.Context
		chacha20.init(&cipher, key[:], nonce[:])
		chacha20.keystream_bytes(&cipher, block[:])
		testing.expect(t, string(drawn[round * BUFFER_SIZE:][:BUFFER_SIZE]) == string(block[SEED_SIZE:]))
		copy(key[:], block[:SEED_SIZE])
	}
	// The key of the state is the third one: the first two are gone.
	testing.expect(t, generator.key == key)
	testing.expect_value(t, generator.refills, 2)
}

// Each byte is erased from the buffer when it is served.
@(test)
served_bytes_are_erased :: proc(t: ^testing.T) {
	seed := seed_of(7)
	generator: Generator
	generator_seed(&generator, &seed)
	drawn: [100]u8
	fill(&generator, drawn[:])
	for byte in generator.buffer[:100] {
		testing.expect_value(t, byte, 0)
	}
	testing.expect_value(t, generator.available, BUFFER_SIZE - 100)
}

// Two seeds give two streams; a zero seed is refused; a child seed is not
// a part of the stream that the starter serves after it.
@(test)
seeds_and_children :: proc(t: ^testing.T) {
	zero: [SEED_SIZE]u8
	generator, other: Generator
	testing.expect(t, !generator_seed(&generator, &zero))
	testing.expect(t, !generator.seeded)
	first, second := seed_of(1), seed_of(2)
	generator_seed(&generator, &first)
	generator_seed(&other, &second)
	testing.expect(t, next_u64(&generator) != next_u64(&other))
	child := seed_for_a_child(&generator)
	after: [SEED_SIZE]u8
	fill(&generator, after[:])
	testing.expect(t, child != after)
	child_generator: Generator
	testing.expect(t, generator_seed(&child_generator, &child))
	testing.expect(t, next_u64(&child_generator) != next_u64(&generator))
}

// A statistical smoke test of 1 MiB: the count of one bits and the counts
// of each byte value are in wide bounds. It finds a gross fault (a stuck
// buffer, a zero key); it proves nothing about the quality.
@(test)
statistical_smoke_test :: proc(t: ^testing.T) {
	seed := seed_of(42)
	generator: Generator
	generator_seed(&generator, &seed)
	SIZE :: 1 << 20
	bytes := make([]u8, SIZE, context.temp_allocator)
	fill(&generator, bytes)
	ones := 0
	counts: [256]int
	for byte in bytes {
		ones += int(byte & 1) + int(byte >> 1 & 1) + int(byte >> 2 & 1) + int(byte >> 3 & 1) + int(byte >> 4 & 1) + int(byte >> 5 & 1) + int(byte >> 6 & 1) + int(byte >> 7 & 1)
		counts[byte] += 1
	}
	// 8 Mi bits: the standard deviation is 1448; 6 of them.
	testing.expectf(t, abs(ones - SIZE * 4) < 6 * 1448, "%d ones", ones)
	chi_square: f64
	for count in counts {
		difference := f64(count) - f64(SIZE) / 256
		chi_square += difference * difference / (f64(SIZE) / 256)
	}
	// 255 degrees of freedom: the mean is 255; below 400 at a level far under 1e-6.
	testing.expectf(t, chi_square > 150 && chi_square < 400, "chi square %f", chi_square)
}

// The gathering with sources of a test: each case of the fallback.
@(test)
gathering_and_its_fallbacks :: proc(t: ^testing.T) {
	counter :: proc "contextless" () -> u64 {
		@(static) value: u64
		value += 1000 + value % 7
		return value
	}
	good_counter: u64
	good :: proc "contextless" () -> (u64, bool) {
		@(static) value: u64 = 0x1234_5678
		value = value * 6364136223846793005 + 1442695040888963407
		return value, true
	}
	all_ones :: proc "contextless" () -> (u64, bool) {return max(u64), true}
	empty :: proc "contextless" () -> (u64, bool) {return 0, false}
	same :: proc "contextless" () -> (u64, bool) {return 77, true}
	_ = good_counter
	report: Entropy_Report
	weak := entropy_gather({cycles = counter}, &report)
	testing.expect_value(t, report.strength, Seed_Strength.Weak)
	testing.expect(t, !report.rdrand_present && !report.rdseed_present)
	entropy_gather({rdrand = all_ones, rdseed = empty, cycles = counter}, &report)
	testing.expect_value(t, report.strength, Seed_Strength.Weak)
	testing.expect_value(t, report.rdrand_good, 0)
	testing.expect_value(t, report.rdrand_refused, PROCESSOR_VALUES * PROCESSOR_ATTEMPTS)
	entropy_gather({rdrand = same, cycles = counter}, &report)
	testing.expect_value(t, report.strength, Seed_Strength.Weak)
	testing.expect_value(t, report.rdrand_good, 1) // The first 77; each other one repeats it.
	processor := entropy_gather({rdrand = good, cycles = counter}, &report)
	testing.expect_value(t, report.strength, Seed_Strength.Processor)
	entropy := entropy_gather({rdrand = good, rdseed = good, cycles = counter}, &report)
	testing.expect_value(t, report.strength, Seed_Strength.Entropy)
	testing.expect_value(t, report.rdseed_good, PROCESSOR_VALUES)
	testing.expect_value(t, report.jitter_samples, JITTER_SAMPLES)
	testing.expect(t, weak != processor && processor != entropy)
	// The processor of this host.
	real := entropy_gather(sources_of_the_processor(), &report)
	again := entropy_gather(sources_of_the_processor(), &report)
	testing.expect(t, real != again)
}
