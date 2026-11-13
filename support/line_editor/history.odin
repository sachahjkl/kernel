package line_editor

// The history: the last lines that the input entered, in a ring of bytes.
// A line takes its own length, not LINE_CAPACITY: short lines leave room
// for more of them. A line never wraps at the end of the ring: when it
// does not fit before the end, it starts at the first byte, and the bytes
// at the end stay unused. So each line is one slice of the ring.
//
// The ring keeps at most HISTORY_LINE_CAPACITY lines, and fewer when the
// lines are long: 16384 bytes hold 256 lines of 64 bytes, or 81 lines of
// 200 bytes. The oldest lines go first.
HISTORY_LINE_CAPACITY :: 256
HISTORY_BYTE_CAPACITY :: 16384 // The bytes of the ring of the history.

// The history of one line, in the memory of the caller.
History :: struct {
	bytes:         [HISTORY_BYTE_CAPACITY]u8, // The ring of the bytes of the lines.
	starts:        [HISTORY_LINE_CAPACITY]u64, // The count of bytes written before each line.
	lengths:       [HISTORY_LINE_CAPACITY]u16, // The bytes of each line.
	bytes_written: u64, // Since the start, with the bytes that a line left unused at the end.
	lines_written: u64, // Since the start.
}

// history_add adds a line as the newest one. added is false for an empty
// line, and for a line equal to the newest one: the history does not hold
// one line two times in a row. A line longer than LINE_CAPACITY is cut.
history_add :: proc "contextless" (history: ^History, text_given: string) -> (added: bool) {
	text := text_given[:min(len(text_given), LINE_CAPACITY)]
	if len(text) == 0 {
		return false
	}
	if newest, ok := history_line(history, 0); ok && newest == text {
		return false
	}
	place := history.bytes_written % HISTORY_BYTE_CAPACITY
	if place + u64(len(text)) > HISTORY_BYTE_CAPACITY {
		history.bytes_written += HISTORY_BYTE_CAPACITY - place
		place = 0
	}
	slot := history.lines_written % HISTORY_LINE_CAPACITY
	history.starts[slot] = history.bytes_written
	history.lengths[slot] = u16(len(text))
	copy(history.bytes[place:], text)
	history.bytes_written += u64(len(text))
	history.lines_written += 1
	return true
}

// history_line gives a line by its age: 0 is the newest. ok is false when
// the history does not hold that line: it is older than the oldest kept
// line, or the ring wrote over its bytes. The text is in the ring: it
// stays valid until the next history_add.
history_line :: proc "contextless" (history: ^History, age: int) -> (text: string, ok: bool) {
	if age < 0 || u64(age) >= history.lines_written || age >= HISTORY_LINE_CAPACITY {
		return "", false
	}
	slot := (history.lines_written - 1 - u64(age)) % HISTORY_LINE_CAPACITY
	start := history.starts[slot]
	length := u64(history.lengths[slot])
	// The bytes since the start of the line: more than the ring, and the
	// ring wrote over it. The fields come from the memory of the caller:
	// each one is checked before a byte is read.
	if start > history.bytes_written || history.bytes_written - start > HISTORY_BYTE_CAPACITY || length > LINE_CAPACITY {
		return "", false
	}
	place := start % HISTORY_BYTE_CAPACITY
	if place + length > HISTORY_BYTE_CAPACITY {
		return "", false
	}
	return string(history.bytes[place:][:length]), true
}

// history_count gives the count of the lines that the history holds.
history_count :: proc "contextless" (history: ^History) -> (count: int) {
	for count < HISTORY_LINE_CAPACITY {
		if _, ok := history_line(history, count); !ok {
			break
		}
		count += 1
	}
	return count
}

// history_candidates fills a table of candidates with the lines of the
// history, the newest first: the tie order of a line is its age, so that
// equal scores give the newest line first. count: the candidates written.
history_candidates :: proc "contextless" (history: ^History, candidates: []Candidate) -> (count: int) {
	for count < len(candidates) {
		text, ok := history_line(history, count)
		if !ok {
			break
		}
		candidates[count] = {name = text, kind = .History_Line, tie_order = u32(count), number = u32(count)}
		count += 1
	}
	return count
}
