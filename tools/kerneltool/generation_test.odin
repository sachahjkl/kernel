package kerneltool

import "core:testing"

// The generations that a step names from the base of a step Generation.
@(test)
generation_marks :: proc(t: ^testing.T) {
	testing.expect_value(t, generation_expand("[console] {generation+4}", 158), "[console] 162")
	testing.expect_value(t, generation_expand("generation {generation+20}: \"versio\", in the commit of generation {generation+23} in ", 100), "generation 120: \"versio\", in the commit of generation 123 in ")
	testing.expect_value(t, generation_expand("{generation}", 7), "7")
	testing.expect_value(t, generation_expand("no mark", 7), "no mark")
	testing.expect_value(t, generation_expand("{generation+x} and {generation+1}", 7), "{generation+x} and 8") // Not a number: it stays.
	testing.expect_value(t, generation_expand("{generation", 7), "{generation") // No end: it stays.
	testing.expect_value(t, generation_expand("{generation-1}", 7), "{generation-1}") // Only a plus.
}
