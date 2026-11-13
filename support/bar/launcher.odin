// The launcher: the panel in the middle of the screen that a key opens. The
// input types a part of a name, and the list has the names of `names` that
// contain it. The compositor draws the panel and starts the chosen program
// as the menu of the programs does.
package bar

TYPED_CAPACITY :: 16 // The longest part that the input types.

// filter puts in matches the indexes in `names` of the names that contain
// typed: first the names that start with typed, then the others, each group
// in the order of `names`. The letters of typed match without their case.
// An empty typed matches each name. It gives the count of matches.
filter :: proc "contextless" (typed: string, matches: []int) -> int {
	count := 0
	for starts in ([2]bool{true, false}) {
		for name, index in names {
			at := find(name, typed)
			if at < 0 || (at == 0) != starts || count >= len(matches) {
				continue
			}
			matches[count] = index
			count += 1
		}
	}
	return count
}

// find gives the first place of part in name, or -1. The letters match
// without their case.
find :: proc "contextless" (name, part: string) -> int {
	lower :: proc "contextless" (character: u8) -> u8 {
		return character >= 'A' && character <= 'Z' ? character + 32 : character
	}
	for at in 0 ..= len(name) - len(part) {
		same := true
		for index in 0 ..< len(part) {
			if lower(name[at + index]) != lower(part[index]) {
				same = false
				break
			}
		}
		if same {
			return at
		}
	}
	return -1
}
