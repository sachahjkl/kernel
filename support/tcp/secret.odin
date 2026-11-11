package tcp

import "base:intrinsics"

// The secret of the initial sequence numbers (RFC 6528) must be a number
// that an attacker cannot guess. The system has no random service
// (docs/NETWORK.md, "Randomness"): the processor gives one with the
// instruction rdrand, which a program runs with no handle. A processor with
// no rdrand gives only the cycle counter, which an attacker can guess.

// processor_random gives a number of the random generator of the
// processor, or 0 when the processor has none or gave none.
processor_random :: proc "contextless" () -> u64 {
	_, _, features, _ := intrinsics.x86_cpuid(1, 0)
	if features >> 30 & 1 == 0 {
		return 0
	}
	for _ in 0 ..< 10 {
		// rdrand sets the carry flag when the number is good.
		value := asm() -> u64 {"rdrand $0\n\tjc 1f\n\txor $0, $0\n1:", "=r,~{cc}"}()
		if value != 0 {
			return value
		}
	}
	return 0
}

// secret_make gives a secret, and says if it came from the processor. The
// other source is the cycle counter.
secret_make :: proc "contextless" (cycles: u64) -> (secret: [32]u8, from_processor: bool) {
	from_processor = true
	for index in 0 ..< 4 {
		value := processor_random()
		if value == 0 {
			from_processor = false
			value = (cycles + u64(index)) * 0x9E37_79B9_7F4A_7C15
		}
		for byte in 0 ..< 8 {
			secret[index * 8 + byte] = u8(value >> (8 * uint(byte)))
		}
	}
	return secret, from_processor
}
