// The line that a person edits in a text program: the bytes, the caret
// inside them, and the keys that change them. The package also finds the
// name at the caret that a completion can replace, and the call that the
// caret is in (line_context.odin), keeps the history of the lines
// (history.odin), and orders the names that match what the person typed
// (fuzzy_match.odin).
//
// The package has no state of its own and makes no kernel call: each
// procedure takes a record in the memory of the caller. So the host tests
// run each key, and a program can keep several lines.
//
// The caller can write in each record: each procedure first brings the
// counts back inside their arrays, and never writes past an array.
package line_editor

// The bytes of one line. A text program can show a line of this length
// after a prompt of a few characters, in one terminal record.
LINE_CAPACITY :: 200

Line :: struct {
	bytes:  [LINE_CAPACITY]u8,
	count:  int, // The bytes of the line.
	caret: int, // The place of the caret: 0 is before the first byte, count after the last.
}

// The keys that edit a line. The caller translates the codes of its keys:
// the package does not depend on a keyboard.
Edit_Key :: enum u8 {
	None      = 0,
	Left      = 1, // The caret goes one byte to the left.
	Right     = 2,
	Home      = 3, // The caret goes before the first byte.
	End       = 4, // The caret goes after the last byte.
	Backspace = 5, // The byte before the caret goes.
	Delete    = 6, // The byte after the caret goes.
	Character = 7, // A printable character goes in at the caret.
}

// line_repair brings the count and the caret of a line inside its bytes.
line_repair :: proc "contextless" (line: ^Line) {
	line.count = clamp(line.count, 0, LINE_CAPACITY)
	line.caret = clamp(line.caret, 0, line.count)
}

// line_text gives the bytes of the line. The text changes with the line.
line_text :: proc "contextless" (line: ^Line) -> string {
	line_repair(line)
	return string(line.bytes[:line.count])
}

// printable says if a byte is a character that a line holds: the font of
// the system draws the bytes 32 to 126, and no other.
printable :: proc "contextless" (character: u8) -> bool {
	return character >= ' ' && character <= '~'
}

// line_key applies one key to a line. changed is false when the key
// changes nothing: a caret at an end, a full line, a byte that is not
// printable.
line_key :: proc "contextless" (line: ^Line, key: Edit_Key, character: u8 = 0) -> (changed: bool) {
	line_repair(line)
	switch key {
	case .None:
		return false
	case .Left:
		if line.caret == 0 {
			return false
		}
		line.caret -= 1
	case .Right:
		if line.caret == line.count {
			return false
		}
		line.caret += 1
	case .Home:
		if line.caret == 0 {
			return false
		}
		line.caret = 0
	case .End:
		if line.caret == line.count {
			return false
		}
		line.caret = line.count
	case .Backspace:
		if line.caret == 0 {
			return false
		}
		copy(line.bytes[line.caret - 1:line.count], line.bytes[line.caret:line.count])
		line.caret -= 1
		line.count -= 1
	case .Delete:
		if line.caret == line.count {
			return false
		}
		copy(line.bytes[line.caret:line.count], line.bytes[line.caret + 1:line.count])
		line.count -= 1
	case .Character:
		if !printable(character) || line.count == LINE_CAPACITY {
			return false
		}
		// The bytes after the caret move one place to the right; copy
		// moves bytes that overlap correctly.
		copy(line.bytes[line.caret + 1:line.count + 1], line.bytes[line.caret:line.count])
		line.bytes[line.caret] = character
		line.caret += 1
		line.count += 1
	}
	return true
}

// line_set gives the line a new text, and puts the caret after it. A text
// longer than the line is cut; a byte that is not printable becomes '?'.
line_set :: proc "contextless" (line: ^Line, text: string) {
	line.count = min(len(text), LINE_CAPACITY)
	for index in 0 ..< line.count {
		line.bytes[index] = printable(text[index]) ? text[index] : '?'
	}
	line.caret = line.count
}

// line_clear empties the line.
line_clear :: proc "contextless" (line: ^Line) {
	line.count = 0
	line.caret = 0
}

// line_replace puts text in the place of the bytes from start to end, and
// the caret after it. ok is false, and the line does not change, when the
// result does not fit or a byte of text is not printable.
line_replace :: proc "contextless" (line: ^Line, start, end: int, text: string) -> (ok: bool) {
	line_repair(line)
	first := clamp(start, 0, line.count)
	last := clamp(end, first, line.count)
	if line.count - (last - first) + len(text) > LINE_CAPACITY {
		return false
	}
	for character in transmute([]u8)text {
		if !printable(character) {
			return false
		}
	}
	rest := line.count - last
	new_end := first + len(text)
	copy(line.bytes[new_end:new_end + rest], line.bytes[last:line.count])
	copy(line.bytes[first:new_end], text)
	line.count = new_end + rest
	line.caret = new_end
	return true
}
