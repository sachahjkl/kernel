#+build !freestanding
package system

import "core:testing"

// A text for the log loses its control bytes of ASCII, and keeps every
// other byte, UTF-8 included.
@(test)
a_text_of_the_log_has_no_control_byte :: proc(t: ^testing.T) {
	bytes := []u8{'a', '\r', 0x1B, '[', '2', 'J', '\n', '\t', 0x7F, 0x00, 'z', 0xC3, 0xA9, ' '}
	log_control_bytes_replace(bytes)
	testing.expect_value(t, string(bytes), "a??[2J????z\u00e9 ")
}
