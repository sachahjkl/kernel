package random

import "base:intrinsics"
import "contract:blake3"
import op "contract:operation"
import crypto "support:cryptography/compatibility_crypto"

// The sources of entropy of the root service (docs/RANDOMNESS.md). The
// claim is no more than the sources: the processor's rdseed (an entropy
// source by its specification), else rdrand (a generator that the
// processor reseeds), else the jitter of the cycle counter, whose entropy
// this system does not measure and counts as 0 bits: a seed from it alone
// is "weak", and the window and the log say so.

DOMAIN_SEED :: "kernel random: the seed of the root service, version 1"
DOMAIN_RESEED :: "kernel random: a reseed, version 1"
PROCESSOR_VALUES :: 8 // Values of 64 bits of rdseed or rdrand in a seed: 512 bits.
PROCESSOR_ATTEMPTS :: 32 // Tries for one value: rdseed can be empty for a while.
JITTER_SAMPLES :: 2048
FRESH_LIMIT :: 10 * 1024 // Bytes that key_derive hashes at most: a gathering has 8320.

Seed_Strength :: enum u8 {
	None      = 0, // No gathering yet.
	Weak      = 1, // The cycle counter only: no claim of entropy.
	Processor = 2, // rdrand: the generator of the processor.
	Entropy   = 3, // rdseed: the entropy source of the processor.
}

@(rodata)
seed_strength_names := [Seed_Strength]string {
	.None      = "none",
	.Weak      = "weak (the cycle counter only)",
	.Processor = "processor (rdrand)",
	.Entropy   = "entropy (rdseed)",
}

// What a gathering found: the window and the log show it.
Entropy_Report :: struct {
	rdseed_present:   bool,
	rdrand_present:   bool,
	rdseed_good:      u32,
	rdseed_refused:   u32, // Carry clear (empty), all ones, or a value that came before.
	rdrand_good:      u32,
	rdrand_refused:   u32,
	jitter_samples:   u32,
	jitter_distinct:  u32, // Distinct low bytes of the deltas: a sign of life of the counter, not a measure of entropy.
	device_bytes:     u32, // Bytes of an entropy device (virtio-rng) mixed in later.
	strength:         Seed_Strength,
}

// Cycles_Read reads the cycle counter.
Cycles_Read :: #type proc "contextless" () -> u64

// Processor_Read is a read of rdseed or rdrand: false when the processor
// gave none. The tests give their own.
Processor_Read :: #type proc "contextless" () -> (value: u64, ok: bool)

// One instruction of the processor as a template: the value, and the carry
// flag of the processor, which says if the value is good. Volatile: each
// use runs the instruction again. An inline instruction that the compiler
// took as a pure function kept one value for a loop (a machine test found
// rdrand with 1 good value and 255 "repeated" ones).
processor_seed_value :: asm() -> (value: u64, good: bool) [
	good = %flags.c,
	#volatile,
] {
	rdseed value
}

processor_random_value :: asm() -> (value: u64, good: bool) [
	good = %flags.c,
	#volatile,
] {
	rdrand value
}

rdseed_read :: proc "contextless" () -> (value: u64, ok: bool) {
	value, ok = processor_seed_value()
	return value, ok && value != 0
}

rdrand_read :: proc "contextless" () -> (value: u64, ok: bool) {
	value, ok = processor_random_value()
	return value, ok && value != 0
}

// processor_features says if the processor has rdrand (CPUID 1, ECX bit
// 30) and rdseed (CPUID 7, EBX bit 18). An instruction that the processor
// does not have stops the program: it is run only when present.
processor_features :: proc "contextless" () -> (rdrand, rdseed: bool) {
	highest, _, _, _ := intrinsics.x86_cpuid(0, 0)
	_, _, features, _ := intrinsics.x86_cpuid(1, 0)
	rdrand = features >> 30 & 1 == 1
	if highest >= 7 {
		_, extended, _, _ := intrinsics.x86_cpuid(7, 0)
		rdseed = extended >> 18 & 1 == 1
	}
	return
}

// processor_values reads PROCESSOR_VALUES good values. A value that is 0
// (carry clear), all ones (a known fault of some processors of AMD), or
// equal to one before it is refused and read again.
processor_values :: proc "contextless" (read: Processor_Read, values: ^[PROCESSOR_VALUES]u64, good, refused: ^u32) -> bool {
	count := 0
	for _ in 0 ..< PROCESSOR_VALUES * PROCESSOR_ATTEMPTS {
		if count == PROCESSOR_VALUES {
			break
		}
		value, ok := read()
		repeated := false
		for earlier in values[:count] {
			repeated ||= earlier == value
		}
		if !ok || value == max(u64) || repeated {
			refused^ += 1
			continue
		}
		values[count] = value
		count += 1
		good^ += 1
	}
	return count == PROCESSOR_VALUES
}

// jitter_values reads the cycle counter around a short loop, JITTER_SAMPLES
// times: the deltas depend on interrupts, caches and, under QEMU, the exits
// of the virtual machine.
jitter_values :: proc "contextless" (deltas: ^[JITTER_SAMPLES]u32, cycles: Cycles_Read) -> (distinct_low_bytes: u32) {
	seen: [256]bool
	last := cycles()
	for &delta in deltas {
		spin: u64
		for step in 0 ..< 64 {
			spin += u64(step) * last
		}
		intrinsics.volatile_store(&spin, spin)
		now := cycles()
		delta = u32(now - last)
		last = now
		if !seen[delta & 0xFF] {
			seen[delta & 0xFF] = true
			distinct_low_bytes += 1
		}
	}
	return
}

// key_derive gives the BLAKE3 hash of a domain text, a key and the fresh
// bytes, each with its length before it: no two inputs give the same bytes
// to hash.
// Its frames and those of BLAKE3 under it hold the key and the chaining
// values: its callers erase the stack below them after it returns.
key_derive :: #force_no_inline proc "contextless" (domain: string, key: []u8, fresh: []u8) -> [SEED_SIZE]u8 {
	input: [128 + 64 + 3 * 8 + FRESH_LIMIT]u8
	count := 0
	put :: proc "contextless" (input: []u8, count: ^int, bytes: []u8) {
		length := u64(len(bytes))
		for index in 0 ..< 8 {
			input[count^ + index] = u8(length >> (8 * uint(index)))
		}
		count^ += 8
		copy(input[count^:], bytes)
		count^ += len(bytes)
	}
	ensure_contextless(len(domain) <= 128 && len(key) <= 64 && len(fresh) <= FRESH_LIMIT, "random: key_derive takes FRESH_LIMIT fresh bytes at most")
	put(input[:], &count, transmute([]u8)domain)
	put(input[:], &count, key)
	put(input[:], &count, fresh)
	hash := blake3.hash(input[:count])
	crypto.zero_explicit(&input, size_of(input))
	return hash
}

// Entropy_Sources are the reads of a gathering: the processor and the cycle
// counter of the machine, or those of a test.
Entropy_Sources :: struct {
	rdseed: Processor_Read, // nil: the processor has no rdseed.
	rdrand: Processor_Read, // nil: the processor has no rdrand.
	cycles: Cycles_Read,
}

// sources_of_the_processor gives the reads that the processor has.
sources_of_the_processor :: proc "contextless" () -> Entropy_Sources {
	rdrand, rdseed := processor_features()
	cycles :: proc "contextless" () -> u64 {
		return u64(intrinsics.read_cycle_counter())
	}
	return {rdseed = rdseed ? rdseed_read : nil, rdrand = rdrand ? rdrand_read : nil, cycles = cycles}
}

// entropy_gather makes the seed of the root service: BLAKE3 of the values
// of rdseed, of rdrand and of the jitter of the cycle counter, all of them.
// The report says which sources gave good values; the strength is the
// strongest source that gave all its values.
entropy_gather :: proc "contextless" (sources: Entropy_Sources, report: ^Entropy_Report) -> (seed: [SEED_SIZE]u8) {
	Gathered :: struct {
		rdseed: [PROCESSOR_VALUES]u64,
		rdrand: [PROCESSOR_VALUES]u64,
		jitter: [JITTER_SAMPLES]u32,
	}
	gathered: Gathered
	report^ = {strength = .Weak, rdseed_present = sources.rdseed != nil, rdrand_present = sources.rdrand != nil}
	if sources.rdrand != nil && processor_values(sources.rdrand, &gathered.rdrand, &report.rdrand_good, &report.rdrand_refused) {
		report.strength = .Processor
	}
	if sources.rdseed != nil && processor_values(sources.rdseed, &gathered.rdseed, &report.rdseed_good, &report.rdseed_refused) {
		report.strength = .Entropy
	}
	report.jitter_distinct = jitter_values(&gathered.jitter, sources.cycles)
	report.jitter_samples = JITTER_SAMPLES
	seed = key_derive(DOMAIN_SEED, nil, ([^]u8)(&gathered)[:size_of(gathered)])
	crypto.erase_stack_below_the_caller()
	crypto.zero_explicit(&gathered, size_of(gathered))
	return seed
}

// The values of the context of a program that shows the seed of the system
// (`randomness`): the root service writes its report in the values 0 to 7
// (the values 9 to 12 are the seed of the program).
REPORT_VALUES :: 8

report_values_write :: proc "contextless" (report: ^Entropy_Report, values: ^[op.CONTEXT_VALUES]u64) {
	values[0] = u64(report.strength) | u64(report.rdseed_present) << 8 | u64(report.rdrand_present) << 9
	values[1] = u64(report.rdseed_good)
	values[2] = u64(report.rdseed_refused)
	values[3] = u64(report.rdrand_good)
	values[4] = u64(report.rdrand_refused)
	values[5] = u64(report.jitter_samples)
	values[6] = u64(report.jitter_distinct)
	values[7] = u64(report.device_bytes)
}

report_values_read :: proc "contextless" (values: ^[op.CONTEXT_VALUES]u64) -> (report: Entropy_Report) {
	report.strength = Seed_Strength(min(values[0] & 0xFF, u64(max(Seed_Strength))))
	report.rdseed_present = values[0] >> 8 & 1 != 0
	report.rdrand_present = values[0] >> 9 & 1 != 0
	report.rdseed_good = u32(values[1])
	report.rdseed_refused = u32(values[2])
	report.rdrand_good = u32(values[3])
	report.rdrand_refused = u32(values[4])
	report.jitter_samples = u32(values[5])
	report.jitter_distinct = u32(values[6])
	report.device_bytes = u32(values[7])
	return
}
