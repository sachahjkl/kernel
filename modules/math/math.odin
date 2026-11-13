// A module of commands: each command is a function with typed parameters,
// not a program that parses text. It is not a program: it has no entry.
// The console loads it and calls its exports with the call form
// (docs/MODULE_CONTRACT.md, section 4). The tool makes the description of each
// export from this source: the name, the parameters, the result, and the
// first sentence of the comment (tools/kerneltool/describe.odin).
//
// **What it is for.** It is the first module that a reader loads to see
// the call form at work: integers in, an integer or a text out, an error
// record for a refusal. Each export is a pure function: it reads its
// parameters only and keeps no state, so a direct call and an isolated call
// give the same answer.
//
// **Example**, in the console:
//
// ```
// load("math")
// gcd(84, 36) + power(2, 10)      1036
// roman(2026)                     "MMXXVI"
// square_root(-4)                 an error record: Too_Small
// ```
//
// `isolate("math")` gives the same answers through a sandboxed program.
//
// **What it does not do**: no export checks an overflow of 64 bits, except
// fibonacci, which stops at the last number that fits. power(10, 19), for
// example, wraps.
package math

import "contract:errors"

// gcd gives the greatest common divisor.
//
// It uses the absolute values, so the result is never negative; gcd(0, n) is the absolute value of n, and
// gcd(0, 0) is 0. It never fails.
//
// Example: `gcd(84, 36)` gives 12.
@(export, link_name = "gcd")
gcd :: proc "c" (first, second: i64) -> i64 {
	a, b := abs(first), abs(second)
	for b != 0 {
		a, b = b, a % b
	}
	return a
}

// power gives an integer to a power.
//
// It squares and multiplies, so a large exponent costs about 63 steps at most. An exponent of 0 or less gives 1.
// The result wraps when it passes 64 bits: no error says so.
//
// Example: `power(2, 10)` gives 1024.
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

// fibonacci gives the Fibonacci number of an index.
//
// fibonacci(0) is 0 and fibonacci(1) is 1. An index above 92 gives the number of 92, the last that fits in 64
// bits; an index of 0 or less gives 0.
@(export, link_name = "fibonacci")
fibonacci :: proc "c" (index: i64) -> i64 {
	a, b: i64 = 0, 1
	for _ in 0 ..< min(index, FIBONACCI_LAST) {
		a, b = b, a + b
	}
	return a
}

NEXT_PRIME_LIMIT :: 1 << 40 // Above this, the search is too slow: the result is 0.

// next_prime gives the first prime from an integer.
//
// The integer itself counts: next_prime(7) is 7. Below 2 the result is 2. Above 2^40 the result is 0, because the
// search by trial division takes too long for a call.
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

// number gives the integer that a text holds. A Text parameter is the
// address of a slice record: {address, count}.
//
// It reads an optional "-", then decimal digits, and stops at the first other byte: number("12ab") is 12, and a
// text with no digit gives 0. It never fails; a number of more than 19 digits wraps.
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

// square_root gives the largest integer whose square is not above a value, or -1 with an error record: the error kind Too_Small, when the value is negative.
//
// It is the export of this module that shows an error record: the record names the first argument, its value,
// and the limit 0.
//
// Example: `square_root(99)` gives 9.
@(export, link_name = "square_root")
square_root :: proc "c" (value: i64, error: ^errors.Error_Record) -> i64 {
	if value < 0 {
		return errors.fail(error, -1, .Too_Small, .None, 1, value, 0)
	}
	root := i64(0)
	for bit := i64(1) << 31; bit != 0; bit >>= 1 {
		if candidate := root | bit; candidate * candidate <= value {
			root = candidate
		}
	}
	return root
}

// A Text result: the caller gives a buffer record {address, capacity} after
// the parameters. The export writes what fits, and gives the count of bytes
// of the full text.
ROMAN_LIMIT :: 3999
@(rodata)
roman_values := [?]i64{1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1}
@(rodata)
roman_symbols := [?]string{"M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"}

// roman gives an integer in Roman numerals.
//
// The integer is taken from 0 to 3999: a larger one gives MMMCMXCIX, and 0 or less gives an empty text. The
// result is the count of bytes of the whole text; a buffer that is too short gets its first bytes.
//
// Example: `roman(2026)` gives "MMXXVI".
@(export, link_name = "roman")
roman :: proc "c" (number: i64, result: ^[]u8) -> i64 {
	rest := clamp(number, 0, ROMAN_LIMIT)
	count := 0
	for value, index in roman_values {
		for rest >= value {
			rest -= value
			for i in 0 ..< len(roman_symbols[index]) {
				if count < len(result) {
					result[count] = roman_symbols[index][i]
				}
				count += 1
			}
		}
	}
	return i64(count)
}

// reverse gives the bytes of a text, last first.
//
// It reverses bytes, not characters: a character of several bytes of UTF-8 comes out broken. The result is the
// count of bytes of the text.
@(export, link_name = "reverse")
reverse :: proc "c" (text: ^string, result: ^[]u8) -> i64 {
	for i in 0 ..< min(len(text), len(result)) {
		result[i] = text[len(text) - 1 - i]
	}
	return i64(len(text))
}
