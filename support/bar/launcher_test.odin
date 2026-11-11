#+build !freestanding
package bar

import "core:testing"

@(private = "file")
listed :: proc(typed: string) -> []string {
	matches: [len(names)]int
	count := filter(typed, matches[:])
	result := make([]string, count, context.temp_allocator)
	for index in 0 ..< count {
		result[index] = names[matches[index]]
	}
	return result
}

@(private = "file")
position :: proc(list: []string, name: string) -> int {
	for item, index in list {
		if item == name {
			return index
		}
	}
	return -1
}

@(test)
filter_empty_lists_each_name :: proc(t: ^testing.T) {
	list := listed("")
	testing.expect_value(t, len(list), len(names))
	for name, index in names {
		testing.expect_value(t, list[index], name)
	}
}

@(test)
filter_starts_first :: proc(t: ^testing.T) {
	// "lo" starts "log", "locks" and is inside "clock" and "flood": the
	// names that start with it come first, each group in the order of names.
	list := listed("lo")
	for name in ([]string{"log", "locks", "clock", "flood"}) {
		testing.expectf(t, position(list, name) >= 0, "%s is not listed for \"lo\": %v", name, list)
	}
	testing.expect(t, position(list, "log") < position(list, "clock"))
	testing.expect(t, position(list, "locks") < position(list, "clock"))
	for name in list {
		testing.expectf(t, find(name, "lo") >= 0, "%s does not contain \"lo\"", name)
	}
	testing.expect_value(t, position(list, "plasma"), -1)
}

@(test)
filter_ignores_case :: proc(t: ^testing.T) {
	testing.expect_value(t, len(listed("PLA")), len(listed("pla")))
	testing.expect_value(t, listed("PLAS")[0], "plasma")
}

@(test)
filter_no_match :: proc(t: ^testing.T) {
	testing.expect_value(t, len(listed("xyz")), 0)
	testing.expect_value(t, len(listed("processorsx")), 0)
}

@(test)
filter_limit :: proc(t: ^testing.T) {
	matches: [2]int
	testing.expect_value(t, filter("", matches[:]), 2)
}
