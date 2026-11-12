// The cut mark: the one form in which the system shows that a text did not
// fit in a place of a fixed size (docs/ARCHITECTURE.md, "A text is never
// cut in silence"). The place holds the start of the text, then the mark
// "... and N bytes more", where N is each byte of the text that the place
// does not hold. The kernel and the programs share this package, so one
// mark reads the same in each log line and each record.
package cut_mark

MARK_START :: "... and "
MARK_END :: " bytes more"

// decimal_digits gives the count of digits of a number in decimal.
decimal_digits :: proc "contextless" (value: u64) -> int {
	digits := 1
	rest := value / 10
	for rest != 0 {
		digits += 1
		rest /= 10
	}
	return digits
}

// mark_size gives the bytes of the mark for a count of missing bytes.
mark_size :: proc "contextless" (missing: u64) -> int {
	return len(MARK_START) + decimal_digits(missing) + len(MARK_END)
}

// complete_characters gives the length of the longest start of bytes that
// ends after a whole UTF-8 character: a character whose first byte is in
// bytes and whose last byte is not is left out. A byte that starts no
// character of UTF-8 counts as one character: the text is kept as it is.
complete_characters :: proc "contextless" (bytes: []u8) -> int {
	count := len(bytes)
	if count == 0 {
		return 0
	}
	start := count - 1
	for start > 0 && count - start < 4 && bytes[start] & 0xC0 == 0x80 {
		start -= 1
	}
	lead := bytes[start]
	length := 1
	switch {
	case lead & 0xE0 == 0xC0:
		length = 2
	case lead & 0xF0 == 0xE0:
		length = 3
	case lead & 0xF8 == 0xF0:
		length = 4
	}
	if start + length > count {
		return start
	}
	return count
}

// apply ends the text of buffer[:count] with the mark, when dropped bytes
// after it did not fit (dropped 0: no change). It takes back the bytes of
// the end of the text that the mark needs, never half of a character, and
// counts them in the mark with the dropped bytes. It gives the count of
// bytes of the text with its mark, the bytes of the text before the mark
// (kept), and the count that the mark says (missing). A buffer smaller
// than the mark alone holds as much of the mark as fits: still not a text
// that looks whole.
apply :: proc "contextless" (buffer: []u8, count_given: int, dropped: int) -> (count: int, kept: int, missing: u64) {
	count = clamp(count_given, 0, len(buffer))
	if dropped <= 0 {
		return count, count, 0
	}
	keep := count
	for {
		keep = complete_characters(buffer[:keep])
		missing = u64(dropped) + u64(count - keep)
		if keep + mark_size(missing) <= len(buffer) || keep == 0 {
			break
		}
		keep -= 1
	}
	digits: [20]u8
	digit_count := decimal_digits(missing)
	rest := missing
	for index := digit_count - 1; index >= 0; index -= 1 {
		digits[index] = u8('0' + rest % 10)
		rest /= 10
	}
	place := keep
	place += copy(buffer[place:], MARK_START)
	place += copy(buffer[place:], digits[:digit_count])
	place += copy(buffer[place:], MARK_END)
	return place, keep, missing
}
