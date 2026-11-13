package kerneltool

import "core:strings"
import "core:testing"

// The whole test, each part and `trusted_boot tpm` are accepted.
@(test)
test_accepts_each_known_part :: proc(t: ^testing.T) {
	testing.expect_value(t, test_arguments_problem(nil), "")
	for part in test_parts {
		testing.expectf(t, test_arguments_problem([]string{part}) == "", "the part %s is accepted", part)
	}
	testing.expect_value(t, test_arguments_problem([]string{"trusted_boot", "tpm"}), "")
}

// A word that is not a part is refused, and the refusal lists the parts:
// the whole test in its place would pass and say nothing of the mistake.
@(test)
test_refuses_an_unknown_part :: proc(t: ^testing.T) {
	refused := [][]string{{"netwrok"}, {""}, {"main", "network"}, {"trusted_boot", "tmp"}, {"tcp", "tpm"}, {"trusted_boot", "tpm", "tpm"}}
	for arguments in refused {
		problem := test_arguments_problem(arguments)
		testing.expectf(t, problem != "", "%v is refused", arguments)
		for part in test_parts {
			testing.expectf(t, strings.contains(problem, part), "the refusal of %v names the part %s", arguments, part)
		}
	}
	testing.expect(t, strings.has_prefix(test_arguments_problem([]string{"netwrok"}), "test does not know the part `netwrok`; the parts: main, network, "))
}

// No part is in the list two times.
@(test)
test_parts_are_distinct :: proc(t: ^testing.T) {
	for part, index in test_parts {
		for other in test_parts[index + 1:] {
			testing.expectf(t, part != other, "the part %s is in the list one time", part)
		}
	}
}
