package line_editor

import "contract:blake3"

// The line history as bytes, to keep it in a store across a stop of the
// program (docs/CONSOLE.md, section 6). The bytes come back from a disk:
// they are data that this run did not write, and the read checks each
// field before it uses it. A file that fails a check gives an empty
// history and the name of the check: the program says it once, and runs
// nothing of it.
//
// The form, version 1, numbers in little-endian order:
//   0   4 bytes   "LHST"
//   4   u32       the version: 1
//   8   u32       the count of lines
//   12  u32       the count of bytes of the lines
//   16  the lines, the oldest first: for each one a byte with its length
//       (1 to LINE_CAPACITY), then its bytes (32 to 126 each)
//   the end: the BLAKE3 hash of each byte before it (32 bytes)

HISTORY_FILE_MAGIC :: "LHST" // The first 4 bytes of the file.
HISTORY_FILE_VERSION :: 1 // The version of the file. A file of another version is refused.
HISTORY_FILE_HEADER_SIZE :: 16 // The bytes before the lines.
HISTORY_FILE_HASH_SIZE :: blake3.HASH_SIZE // The bytes of the hash at the end.
// One block of the storage service. The newest lines that fit in it are
// kept: about 120 lines of 30 bytes.
HISTORY_FILE_SIZE_LIMIT :: 4096

// Why a history file is refused. The program then starts with an empty
// history, and says so.
History_File_Problem :: enum u8 {
	None           = 0, // The file is valid.
	Too_Short      = 1, // Fewer bytes than a header and a hash.
	Wrong_Magic    = 2, // It does not start with HISTORY_FILE_MAGIC.
	Wrong_Version  = 3, // Another version.
	Wrong_Hash     = 4, // A byte changed after the write.
	Too_Many_Lines = 5, // More lines than the history holds.
	Wrong_Size     = 6, // The count of bytes of the lines is not the bytes between the header and the hash.
	Wrong_Line     = 7, // A line of 0 bytes, longer than a line, or past the end of the lines.
	Not_Printable  = 8, // A byte of a line under 32 or over 126.
	Wrong_Count    = 9, // The lines end before or after the count of lines.
}

// The words of each problem, for the line that the program writes.
@(rodata)
history_file_problem_texts := [History_File_Problem]string {
	.None           = "no problem",
	.Too_Short      = "it has fewer bytes than a header and a hash",
	.Wrong_Magic    = "it does not start with LHST",
	.Wrong_Version  = "its version is not 1",
	.Wrong_Hash     = "its hash is wrong",
	.Too_Many_Lines = "it has more lines than the history holds",
	.Wrong_Size     = "its count of bytes is wrong",
	.Wrong_Line     = "a line has a wrong length",
	.Not_Printable  = "a line has a byte that is not a character",
	.Wrong_Count    = "its count of lines is wrong",
}

// u32_write writes a number of 32 bits, little-endian.
@(private)
u32_write :: proc "contextless" (bytes: []u8, value: u32) {
	bytes[0], bytes[1], bytes[2], bytes[3] = u8(value), u8(value >> 8), u8(value >> 16), u8(value >> 24)
}

// u32_read reads a number of 32 bits, little-endian.
@(private)
u32_read :: proc "contextless" (bytes: []u8) -> u32 {
	return u32(bytes[0]) | u32(bytes[1]) << 8 | u32(bytes[2]) << 16 | u32(bytes[3]) << 24
}

// history_file_write writes the history in buffer, in the form above: the
// newest lines that fit, and the oldest of them first. bytes is the part
// of buffer that holds the file, or nil when buffer cannot hold a header
// and a hash.
history_file_write :: proc "contextless" (history: ^History, buffer: []u8) -> (bytes: []u8) {
	if len(buffer) < HISTORY_FILE_HEADER_SIZE + HISTORY_FILE_HASH_SIZE {
		return nil
	}
	room := len(buffer) - HISTORY_FILE_HEADER_SIZE - HISTORY_FILE_HASH_SIZE
	// The newest lines first, while they fit.
	line_count, line_bytes := 0, 0
	for {
		text, ok := history_line(history, line_count)
		if !ok || line_bytes + 1 + len(text) > room {
			break
		}
		line_bytes += 1 + len(text)
		line_count += 1
	}
	copy(buffer[0:4], HISTORY_FILE_MAGIC)
	u32_write(buffer[4:8], HISTORY_FILE_VERSION)
	u32_write(buffer[8:12], u32(line_count))
	u32_write(buffer[12:16], u32(line_bytes))
	place := HISTORY_FILE_HEADER_SIZE
	for age := line_count - 1; age >= 0; age -= 1 {
		text, _ := history_line(history, age)
		buffer[place] = u8(len(text))
		copy(buffer[place + 1:], text)
		place += 1 + len(text)
	}
	hash := blake3.hash(buffer[:place])
	copy(buffer[place:], hash[:])
	return buffer[:place + HISTORY_FILE_HASH_SIZE]
}

// history_file_read makes the history from the bytes of a file. The
// history is emptied first; with a problem, it stays empty.
history_file_read :: proc "contextless" (bytes: []u8, history: ^History) -> (problem: History_File_Problem) {
	history^ = {}
	if len(bytes) < HISTORY_FILE_HEADER_SIZE + HISTORY_FILE_HASH_SIZE {
		return .Too_Short
	}
	if string(bytes[0:4]) != HISTORY_FILE_MAGIC {
		return .Wrong_Magic
	}
	if u32_read(bytes[4:8]) != HISTORY_FILE_VERSION {
		return .Wrong_Version
	}
	end := len(bytes) - HISTORY_FILE_HASH_SIZE
	hash := blake3.hash(bytes[:end])
	if string(hash[:]) != string(bytes[end:]) {
		return .Wrong_Hash
	}
	line_count := u64(u32_read(bytes[8:12]))
	if line_count > HISTORY_LINE_CAPACITY {
		return .Too_Many_Lines
	}
	if u64(u32_read(bytes[12:16])) != u64(end - HISTORY_FILE_HEADER_SIZE) {
		return .Wrong_Size
	}
	// Each line is checked before any line goes into the history.
	place := HISTORY_FILE_HEADER_SIZE
	for _ in 0 ..< line_count {
		if place >= end {
			return .Wrong_Count
		}
		length := int(bytes[place])
		if length == 0 || length > LINE_CAPACITY || length > end - place - 1 {
			return .Wrong_Line
		}
		for character in bytes[place + 1:][:length] {
			if !printable(character) {
				return .Not_Printable
			}
		}
		place += 1 + length
	}
	if place != end {
		return .Wrong_Count
	}
	place = HISTORY_FILE_HEADER_SIZE
	for _ in 0 ..< line_count {
		length := int(bytes[place])
		history_add(history, string(bytes[place + 1:][:length]))
		place += 1 + length
	}
	return .None
}
