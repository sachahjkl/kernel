// A module of commands (property 19). It is not a program: it has no entry.
// The console loads it and calls its exports with the call form
// (docs/MODULE_CONTRACT.md, section 4). The tool makes the description of each
// export from this source: the name, the parameters, the result, and the
// first sentence of the comment (tools/kerneltool/describe.odin).
package math

// gcd gives the greatest common divisor.
@(export, link_name = "gcd")
gcd :: proc "c" (first, second: i64) -> i64 {
	a, b := abs(first), abs(second)
	for b != 0 {
		a, b = b, a % b
	}
	return a
}

// power gives an integer to a power.
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

// A Text result: the caller gives a buffer record {address, capacity} after
// the parameters. The export writes what fits, and gives the count of bytes
// of the full text.
ROMAN_LIMIT :: 3999
@(rodata)
roman_values := [?]i64{1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1}
@(rodata)
roman_symbols := [?]string{"M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"}

// roman gives an integer in Roman numerals.
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
@(export, link_name = "reverse")
reverse :: proc "c" (text: ^string, result: ^[]u8) -> i64 {
	for i in 0 ..< min(len(text), len(result)) {
		result[i] = text[len(text) - 1 - i]
	}
	return i64(len(text))
}
