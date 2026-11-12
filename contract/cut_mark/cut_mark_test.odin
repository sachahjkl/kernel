#+build !freestanding
package cut_mark

import "core:testing"

// fill writes a text in a buffer as a writer does: the bytes that fit, and
// the count of the others.
@(private = "file")
fill :: proc(buffer: []u8, text: string) -> (count: int, dropped: int) {
	count = copy(buffer, text)
	return count, len(text) - count
}

@(test)
a_text_that_fits_is_not_marked :: proc(t: ^testing.T) {
	buffer: [32]u8
	count, dropped := fill(buffer[:], "exactly thirty-two bytes long ok")
	testing.expect_value(t, dropped, 0)
	marked, kept, missing := apply(buffer[:], count, dropped)
	testing.expect(t, marked == 32 && kept == 32 && missing == 0)
	testing.expect_value(t, string(buffer[:32]), "exactly thirty-two bytes long ok")
}

@(test)
one_byte_over :: proc(t: ^testing.T) {
	buffer: [32]u8
	count, dropped := fill(buffer[:], "exactly thirty-two bytes long ok!")
	testing.expect_value(t, dropped, 1)
	marked, _, _ := apply(buffer[:], count, dropped)
	// The mark of a 2-digit count takes 21 bytes: 11 bytes of the text stay,
	// and 22 are missing.
	testing.expect_value(t, string(buffer[:marked]), "exactly thi... and 22 bytes more")
	testing.expect_value(t, marked, 32)
	_, kept, missing := apply(buffer[:], 11, 22) // The same text again, from its start: the same mark.
	testing.expect(t, kept == 11 && missing == 22)
}

@(test)
far_over :: proc(t: ^testing.T) {
	buffer: [40]u8
	text: [10_000]u8
	for &b, index in text {
		b = u8('a' + index % 26)
	}
	count, dropped := fill(buffer[:], string(text[:]))
	marked, _, _ := apply(buffer[:], count, dropped)
	// The mark of a 4-digit count takes 23 bytes: 17 bytes of the text stay.
	testing.expect_value(t, string(buffer[:marked]), "abcdefghijklmnopq... and 9983 bytes more")
	testing.expect_value(t, marked, 40)
}

@(test)
the_count_and_the_mark_depend_on_each_other :: proc(t: ^testing.T) {
	// Each byte that the mark takes back is one more missing byte: the
	// procedure finds the longest start with which the mark fits.
	buffer: [24]u8
	count, dropped := fill(buffer[:], "abcdefghijklmnopqrstuvwxyz")
	marked, _, _ := apply(buffer[:], count, dropped)
	testing.expect_value(t, string(buffer[:marked]), "abc... and 23 bytes more")
}

@(test)
no_half_character_before_the_mark :: proc(t: ^testing.T) {
	// "é" is 2 bytes, "€" 3 bytes: the cuts fall inside them.
	buffer: [30]u8
	text := "a\u00e9\u00e9\u00e9\u00e9\u00e9\u00e9\u20ac\u20ac\u20ac\u20ac\u20ac\u20ac\u20ac\u20ac and more text after it"
	count, dropped := fill(buffer[:], text)
	marked, _, _ := apply(buffer[:], count, dropped)
	// 9 bytes and a mark of 21: a and four characters of 2 bytes; 51 missing.
	testing.expect_value(t, string(buffer[:marked]), "a\u00e9\u00e9\u00e9\u00e9... and 51 bytes more")
	testing.expect_value(t, complete_characters(buffer[:9]), 9)
}

@(test)
a_buffer_smaller_than_the_mark :: proc(t: ^testing.T) {
	buffer: [6]u8
	count, dropped := fill(buffer[:], "a text longer than the buffer")
	marked, _, _ := apply(buffer[:], count, dropped)
	testing.expect_value(t, string(buffer[:marked]), "... an")
}

@(test)
characters_at_the_end :: proc(t: ^testing.T) {
	testing.expect_value(t, complete_characters(transmute([]u8)string("abc")), 3)
	testing.expect_value(t, complete_characters(transmute([]u8)string("ab\xc3")), 2) // The first byte of é only.
	testing.expect_value(t, complete_characters(transmute([]u8)string("ab\xe2\x82")), 2) // Two bytes of €.
	testing.expect_value(t, complete_characters(transmute([]u8)string("ab\xe2\x82\xac")), 5)
	testing.expect_value(t, complete_characters(transmute([]u8)string("\x80\x80\x80\x80")), 4) // Not UTF-8: kept as it is.
	testing.expect_value(t, complete_characters(nil), 0)
}
