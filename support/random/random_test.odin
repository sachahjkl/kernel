#+build !freestanding
package random

import "contract:errors"
import "core:testing"
import "support:system"
import op "contract:operation"
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
	testing.expect(t, generator_seed(&generator, &seed, .Entropy))
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
	generator_seed(&generator, &seed, .Entropy)
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
	testing.expect(t, !generator_seed(&generator, &zero, .Entropy))
	testing.expect(t, !generator.seeded)
	first, second := seed_of(1), seed_of(2)
	generator_seed(&generator, &first, .Entropy)
	generator_seed(&other, &second, .Entropy)
	testing.expect(t, next_u64(&generator) != next_u64(&other))
	child := seed_for_a_child(&generator)
	after: [SEED_SIZE]u8
	fill(&generator, after[:])
	testing.expect(t, child != after)
	child_generator: Generator
	testing.expect(t, generator_seed(&child_generator, &child, .Entropy))
	testing.expect(t, next_u64(&child_generator) != next_u64(&generator))
}

// A statistical smoke test of 1 MiB: the count of one bits and the counts
// of each byte value are in wide bounds. It finds a gross fault (a stuck
// buffer, a zero key); it proves nothing about the quality.
@(test)
statistical_smoke_test :: proc(t: ^testing.T) {
	seed := seed_of(42)
	generator: Generator
	generator_seed(&generator, &seed, .Entropy)
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

// The strength of the seed of the system goes with each seed: a child that a
// generator of strength weak seeds is weak too, and the context carries it in
// the value 16 (op.CONTEXT_VALUE_SEED_STRENGTH).
@(test)
seed_strength_goes_with_the_seed :: proc(t: ^testing.T) {
	seed := seed_of(3)
	starter: Generator
	testing.expect(t, generator_seed(&starter, &seed, .Weak))
	testing.expect_value(t, seed_strength(&starter), Seed_Strength.Weak)
	ctx: system.Context
	ctx.values = values_with_seed(&starter, ctx.values)
	testing.expect_value(t, ctx.values[op.CONTEXT_VALUE_SEED_STRENGTH], u64(Seed_Strength.Weak))
	child: Generator
	testing.expect(t, generator_from_context(&child, &ctx))
	testing.expect_value(t, seed_strength(&child), Seed_Strength.Weak)
	// The seed is erased from the context once it is read.
	for index in 0 ..< op.CONTEXT_VALUE_SEED_COUNT {
		testing.expect_value(t, ctx.values[op.CONTEXT_VALUE_SEED + index], 0)
	}
	// A value over the last strength reads as the last one, not as a
	// value out of the enumeration.
	ctx.values = values_with_seed(&starter, {})
	ctx.values[op.CONTEXT_VALUE_SEED_STRENGTH] = 200
	testing.expect(t, generator_from_context(&child, &ctx))
	testing.expect_value(t, seed_strength(&child), Seed_Strength.Entropy)
}

// A draw and a reseed leave the generator free for the next draw: the check
// of two draws at once refuses only a draw that overlaps another.
@(test)
a_draw_leaves_the_generator_free :: proc(t: ^testing.T) {
	seed := seed_of(5)
	generator: Generator
	generator_seed(&generator, &seed, .Processor)
	drawn: [2000]u8
	fill(&generator, drawn[:])
	testing.expect(t, !generator.in_use)
	fresh := [4]u8{1, 2, 3, 4}
	reseed(&generator, fresh[:])
	testing.expect(t, !generator.in_use)
	fill(&generator, drawn[:10])
	testing.expect(t, !generator.in_use)
}

// A key is drawn only when the seed has the strength that the caller asks:
// a weaker seed gives Seed_Too_Weak and no byte (the owner's rule: the
// program chooses what it accepts, and an unmet requirement is an error).
@(test)
a_key_asks_for_a_least_seed_strength :: proc(t: ^testing.T) {
	Case :: struct {
		seed:     Seed_Strength,
		asked:    Seed_Strength,
		accepted: bool,
	}
	cases := []Case {
		{.Weak, .Weak, true},
		{.Weak, .Processor, false},
		{.Weak, .Entropy, false},
		{.Processor, .Weak, true},
		{.Processor, .Processor, true},
		{.Processor, .Entropy, false},
		{.Entropy, .Processor, true},
		{.Entropy, .Entropy, true},
	}
	for item in cases {
		seed := seed_of(9)
		generator: Generator
		generator_seed(&generator, &seed, item.seed)
		key: [32]u8
		error: errors.Error_Record
		accepted := fill_for_a_key(&generator, key[:], item.asked, &error)
		testing.expectf(t, accepted == item.accepted, "a seed %v, a key that asks for %v", item.seed, item.asked)
		if accepted {
			testing.expect(t, key != [32]u8{})
		} else {
			testing.expect(t, key == [32]u8{})
			testing.expect_value(t, error.kind, i64(errors.Kind.Seed_Too_Weak))
			testing.expect_value(t, error.value, i64(item.seed))
			testing.expect_value(t, error.limit, i64(item.asked))
			testing.expect_value(t, generator.served, 0)
		}
	}
	// A generator with no seed gives the error, not a stop of the program.
	empty: Generator
	key: [32]u8
	error: errors.Error_Record
	testing.expect(t, !fill_for_a_key(&empty, key[:], .Weak, &error))
	testing.expect_value(t, error.kind, i64(errors.Kind.Seed_Too_Weak))
}
