// A module of commands (property 19). It is not a program: it has no entry.
// The console loads it and calls its exports with the call form
// (docs/MODULE_CONTRACT.md, section 4). The description of each export is in
// the module table of tools/kerneltool/modules.odin.
package math

@(export, link_name = "gcd")
gcd :: proc "c" (first, second: i64) -> i64 {
	a, b := abs(first), abs(second)
	for b != 0 {
		a, b = b, a % b
	}
	return a
}

@(export, link_name = "power")
power :: proc "c" (base, exponent: i64) -> i64 {
	result: i64 = 1
	factor, rest := base, exponent
	for rest > 0 {
		if rest & 1 != 0 {
			result *= factor
		}
		factor *= factor
		rest >>= 1
	}
	return result
}

FIBONACCI_LAST :: 92 // The last index whose number fits in 64 bits.

@(export, link_name = "fibonacci")
fibonacci :: proc "c" (index: i64) -> i64 {
	a, b: i64 = 0, 1
	for _ in 0 ..< min(index, FIBONACCI_LAST) {
		a, b = b, a + b
	}
	return a
}

NEXT_PRIME_LIMIT :: 1 << 40 // Above this, the search is too slow: the result is 0.

@(export, link_name = "next_prime")
next_prime :: proc "c" (from: i64) -> i64 {
	if from > NEXT_PRIME_LIMIT {
		return 0
	}
	search: for candidate := max(from, 2);; candidate += 1 {
		for divisor: i64 = 2; divisor * divisor <= candidate; divisor += 1 {
			if candidate % divisor == 0 {
				continue search
			}
		}
		return candidate
	}
}

// A Text parameter is the address of a slice record: {address, count}.
@(export, link_name = "number")
number :: proc "c" (text: ^string) -> i64 {
	digits := text^
	negative := len(digits) > 0 && digits[0] == '-'
	if negative {
		digits = digits[1:]
	}
	value: i64
	for i in 0 ..< len(digits) {
		if digits[i] < '0' || digits[i] > '9' {
			break
		}
		value = value * 10 + i64(digits[i] - '0')
	}
	return negative ? -value : value
}
