// The palette table: what a palette provider shares with the palette of the
// desktop (docs/DESIGN.md, "Palette"), and
// (docs/CONSOLE.md, "8. The palette provider").
//
// **What it is for.** The palette is a panel of the compositor. A palette
// provider, the console, gives it entries of its own: one for each of its
// commands. The provider writes them in one memory object, the entry
// table, which the compositor maps read-only. One ring goes between the two
// programs: the compositor names the entry that the input chose (`Choose`),
// and the provider answers what the entry gave (`Result`). No text of a
// line goes from one program to the other: an entry is a record, a choice
// is a number, and a result is runs of text with what each run is.
//
// **The memory object**: `TABLE_PAGES` pages. A `Header` at byte 0, the
// result area at `RESULT_OFFSET`, then `ENTRY_CAPACITY` records `Entry` at
// `ENTRIES_OFFSET`.
//
// **The reader trusts nothing.** The provider is another program: the
// reader copies the table (`snapshot_take`), then checks each count, each
// length, each kind and each byte of the copy. It never reads the shared
// memory again for a value that it checked. A table that fails is no
// table.
//
// **The writer** changes the table between two additions to
// `Header.change_count`: an odd count says that the table changes now.
package palette_table

import "base:intrinsics"

MAGIC :: 0x544C4150 // "PALT", little-endian.
VERSION :: 1 // A new field or a new meaning of a field is a new version.

ENTRY_CAPACITY :: 256 // The entries of a table: the commands of a console at most.
NAME_CAPACITY :: 64 // The bytes of the name of an entry.
SIGNATURE_CAPACITY :: 128 // The bytes of the signature of an entry: its name, its parameters, its result.
ABOUT_CAPACITY :: 128 // The bytes of the help sentence of an entry.
PARAMETER_CAPACITY :: 6 // The parameters of an entry: the parameters of an export at most.
RESULT_CAPACITY :: 2048 // The bytes of the result area.
RESULT_LINE_CAPACITY :: 12 // The lines of a result that the panel shows.
RESULT_COLUMN_CAPACITY :: 76 // The cells of one line of a result that the panel shows.
SNAPSHOT_TRIES :: 4 // The times that a reader copies a table that changes while it reads.

// What an entry is.
Entry_Kind :: enum u8 {
	Command = 0, // A command of the provider itself.
	Export  = 1, // An export of a module or of a service, which the provider calls.
}

// The facts of an entry that are true or false.
Entry_Flag :: enum u8 {
	Destroys = 0, // The entry destroys something: the panel asks for a second Enter before it sends the choice.
}
Entry_Flags :: bit_set[Entry_Flag;u8]

// The kind of a value: the numbers of the types of the module contract.
Value_Kind :: enum u8 {
	None    = 0, // No value. A parameter: a value of any kind.
	Integer = 1,
	Text    = 2,
	Record  = 3,
	Handle  = 4,
	Table   = 5,
	Bytes   = 6,
}

// One entry: 336 bytes.
Entry :: struct {
	kind:             Entry_Kind, // What the entry is.
	flags:            Entry_Flags, // Its facts.
	parameter_count:  u8, // Its parameters: 0 to PARAMETER_CAPACITY. More than 0: the panel cannot run it, and opens it in the provider.
	result:           Value_Kind, // The kind of its result.
	name_length:      u8, // The bytes of `name` in use: 1 to NAME_CAPACITY.
	signature_length: u8, // The bytes of `signature` in use. It starts with the name.
	about_length:     u8, // The bytes of `about` in use.
	reserved:         u8, // 0.
	parameters:       [PARAMETER_CAPACITY]Value_Kind, // The kind of each parameter.
	reserved_more:    [2]u8, // 0.
	name:             [NAME_CAPACITY]u8, // The name: bytes 32 to 126.
	signature:        [SIGNATURE_CAPACITY]u8, // "revoke(name: Text, grant: Text) -> Integer": bytes 32 to 126.
	about:            [ABOUT_CAPACITY]u8, // What the entry does, in one sentence: bytes 32 to 126.
}
#assert(size_of(Entry) == 336)

// The start of the memory object.
Header :: struct {
	magic:        u32, // MAGIC.
	version:      u32, // VERSION.
	change_count: u32, // The provider adds 1 before a change and 1 after it: odd while it writes. It is the generation of the table.
	entry_count:  u32, // The entries in use: 0 to ENTRY_CAPACITY.
}

RESULT_OFFSET :: 64 // The first byte of the result area.
ENTRIES_OFFSET :: RESULT_OFFSET + RESULT_CAPACITY // The first byte of the entries.
TABLE_BYTES :: ENTRIES_OFFSET + ENTRY_CAPACITY * size_of(Entry)
TABLE_PAGES :: (TABLE_BYTES + 4095) / 4096
#assert(size_of(Header) <= RESULT_OFFSET)

// The ring between the two programs. A command goes from the panel to the
// provider; a completion comes back with the tag of its command.
Command :: enum u32 {
	None   = 0, // Not a command.
	// Choose names the entry that the input chose. values[0]: the
	// change_count of the table that the panel showed. values[1]: the
	// index of the entry in that table. values[2]: name_hash of its name.
	// values[3]: a Choose_Mode.
	Choose = 1,
}

// What the provider does with a chosen entry.
Choose_Mode :: enum u64 {
	Run  = 0, // Run the entry as a line. Only an entry with no parameter.
	Edit = 1, // Write the entry in the edit line of the provider, with the caret between its parentheses.
}

// What a choice gave: the kind of a completion is always 0, and values[0]
// is one of these. values[1]: the Value_Kind of the result. values[2]: the
// bytes of the result area in use.
Outcome :: enum u64 {
	None             = 0, // Not an outcome.
	Shown_In_Panel   = 1, // The result area holds the result: the panel draws it.
	Shown_In_Console = 2, // The result is too large for the panel, or has no value to show: the window of the provider has it.
	Failed           = 3, // The line failed: the result area holds its error.
	Refused          = 4, // The provider did not run the entry: the table changed, or the choice names no entry that it can run. The result area holds the sentence.
	Edit_Opened      = 5, // The edit line of the provider holds the entry.
}

// The result area holds lines of runs. One run: a byte Run_Part, a byte
// length, then that many bytes 32 to 126. A run with the part End_Line and
// the length 0 ends a line.
Run_Part :: enum u8 {
	Plain     = 0, // A text value.
	Label     = 1, // The name of a field.
	Note      = 2, // What the drawer says about the result.
	Failure   = 3, // The sentence of an error.
	Number    = 4, // An Integer.
	Handle    = 5, // A handle.
	Type      = 6, // The name of a record.
	Status    = 7, // An error kind.
	Operation = 8, // The operation of an error.
	End_Line  = 255, // The line ends.
}

// name_hash gives the 64-bit FNV-1a hash of a name: a choice carries it, so
// that the provider never runs an entry that the panel did not show.
name_hash :: proc "contextless" (name: string) -> u64 {
	hash: u64 = 0xCBF2_9CE4_8422_2325
	for index in 0 ..< len(name) {
		hash = (hash ~ u64(name[index])) * 0x0000_0100_0000_01B3
	}
	return hash
}

// A copy of a table that passed each check.
Snapshot :: struct {
	generation:  u32, // The change_count of the copy: even.
	entry_count: int, // The entries in use.
	entries:     [ENTRY_CAPACITY]Entry, // The entries.
}

// Why a table is refused.
Problem :: enum u8 {
	None             = 0, // The table is good.
	Too_Small        = 1, // The memory is smaller than a table.
	Never_Stable     = 2, // The change count stayed odd, or changed during each copy.
	Bad_Magic        = 3,
	Bad_Version      = 4,
	Too_Many_Entries = 5,
	Bad_Kind         = 6, // An entry: a kind, a flag, a kind of a parameter or of the result out of its range, or a reserved byte that is not 0.
	Bad_Length       = 7, // An entry: a length or a count past its field, or an empty name.
	Bad_Byte         = 8, // An entry: a byte of a text under 32 or over 126.
	Bad_Signature    = 9, // An entry: the signature does not start with the name.
}

// The name of each problem, as a log writes it.
@(rodata)
problem_names := [Problem]string {
	.None             = "no problem",
	.Too_Small        = "the memory is smaller than a table",
	.Never_Stable     = "the change count never stayed even",
	.Bad_Magic        = "a wrong magic number",
	.Bad_Version      = "a version that the reader does not know",
	.Too_Many_Entries = "more entries than a table holds",
	.Bad_Kind         = "a kind or a flag out of its range",
	.Bad_Length       = "a length past its field, or an empty name",
	.Bad_Byte         = "a byte that the font does not draw",
	.Bad_Signature    = "a signature that does not start with the name",
}

// printable says if each byte of a text is a character that the font draws.
printable :: proc "contextless" (bytes: []u8) -> bool {
	for value in bytes {
		if value < 32 || value > 126 {
			return false
		}
	}
	return true
}

// entry_problem checks one entry of a copy.
entry_problem :: proc "contextless" (entry: ^Entry) -> Problem {
	if entry.kind > max(Entry_Kind) || transmute(u8)entry.flags &~ transmute(u8)Entry_Flags{.Destroys} != 0 || entry.result > max(Value_Kind) || entry.reserved != 0 || entry.reserved_more != {} {
		return .Bad_Kind
	}
	if entry.name_length == 0 || int(entry.name_length) > NAME_CAPACITY || int(entry.signature_length) > SIGNATURE_CAPACITY || int(entry.about_length) > ABOUT_CAPACITY || int(entry.parameter_count) > PARAMETER_CAPACITY {
		return .Bad_Length
	}
	for kind in entry.parameters {
		if kind > max(Value_Kind) {
			return .Bad_Kind
		}
	}
	if !printable(entry.name[:entry.name_length]) || !printable(entry.signature[:entry.signature_length]) || !printable(entry.about[:entry.about_length]) {
		return .Bad_Byte
	}
	if entry.signature_length < entry.name_length || string(entry.signature[:entry.name_length]) != string(entry.name[:entry.name_length]) {
		return .Bad_Signature
	}
	return .None
}

// snapshot_take copies a table and checks the copy. memory is the mapping
// of the reader. The copy is whole only when the change count is even and
// the same before and after it; the reader tries SNAPSHOT_TRIES times. On a
// problem the snapshot has no entry; index is the entry that failed.
snapshot_take :: proc "contextless" (memory: []u8, snapshot: ^Snapshot) -> (problem: Problem, index: int) {
	snapshot.entry_count = 0
	snapshot.generation = 0
	if len(memory) < TABLE_BYTES {
		return .Too_Small, 0
	}
	header := (^Header)(raw_data(memory))
	copied := false
	count: u32
	for _ in 0 ..< SNAPSHOT_TRIES {
		before := intrinsics.volatile_load(&header.change_count)
		if before & 1 != 0 {
			continue
		}
		// The count is read once: the copy uses this value and no later one.
		count = intrinsics.volatile_load(&header.entry_count)
		if intrinsics.volatile_load(&header.magic) != MAGIC {
			return .Bad_Magic, 0
		}
		if intrinsics.volatile_load(&header.version) != VERSION {
			return .Bad_Version, 0
		}
		if count > ENTRY_CAPACITY {
			return .Too_Many_Entries, 0
		}
		intrinsics.mem_copy_non_overlapping(&snapshot.entries[0], &memory[ENTRIES_OFFSET], int(count) * size_of(Entry))
		if intrinsics.volatile_load(&header.change_count) == before {
			snapshot.generation = before
			copied = true
			break
		}
	}
	if !copied {
		return .Never_Stable, 0
	}
	for &entry, number in snapshot.entries[:count] {
		if found := entry_problem(&entry); found != .None {
			return found, number
		}
	}
	snapshot.entry_count = int(count)
	return .None, 0
}

// result_copy copies the result area of a table and checks the copy: runs
// that end inside the copy, parts in their range, bytes 32 to 126, at most
// RESULT_LINE_CAPACITY lines. length is the count that the provider gave.
// It gives the count of the bytes of the copy, or ok false.
result_copy :: proc "contextless" (memory: []u8, length: u64, result: ^[RESULT_CAPACITY]u8) -> (count: int, ok: bool) {
	if len(memory) < TABLE_BYTES || length > RESULT_CAPACITY {
		return 0, false
	}
	count = int(length)
	if count > 0 {
		intrinsics.mem_copy_non_overlapping(&result[0], &memory[RESULT_OFFSET], count)
	}
	return count, result_valid(result[:count])
}

// result_valid checks the runs of a copy of a result area.
result_valid :: proc "contextless" (runs: []u8) -> bool {
	place, lines := 0, 0
	for place < len(runs) {
		if len(runs) - place < 2 {
			return false
		}
		part, length := runs[place], int(runs[place + 1])
		place += 2
		if part == u8(Run_Part.End_Line) {
			if length != 0 {
				return false
			}
			lines += 1
			continue
		}
		if part > u8(Run_Part.Operation) || length > len(runs) - place || !printable(runs[place:][:length]) {
			return false
		}
		place += length
	}
	return lines <= RESULT_LINE_CAPACITY
}

// Result_Writer writes runs into a result area, or into a buffer before
// it. fits is false when a run or a line did not fit the panel: the result
// then shows in the window of the provider only.
Result_Writer :: struct {
	buffer: []u8, // RESULT_CAPACITY bytes at most.
	count:  int, // The bytes written.
	column: int, // The cells of the line that is written now.
	lines:  int, // The lines ended.
	fits:   bool, // Each run and each line fit so far. The caller sets it true first.
}

// result_run adds one run of a line. A byte that the font does not draw
// becomes "?".
result_run :: proc "contextless" (writer: ^Result_Writer, part: Run_Part, text: string) {
	rest := text
	for len(rest) > 0 && writer.fits {
		taken := min(len(rest), 255)
		writer.column += taken
		if writer.count + 2 + taken > len(writer.buffer) || writer.column > RESULT_COLUMN_CAPACITY || writer.lines >= RESULT_LINE_CAPACITY {
			writer.fits = false
			return
		}
		writer.buffer[writer.count] = u8(part)
		writer.buffer[writer.count + 1] = u8(taken)
		for index in 0 ..< taken {
			value := rest[index]
			writer.buffer[writer.count + 2 + index] = value >= 32 && value <= 126 ? value : '?'
		}
		writer.count += 2 + taken
		rest = rest[taken:]
	}
}

// result_line_end ends the line.
result_line_end :: proc "contextless" (writer: ^Result_Writer) {
	if !writer.fits || writer.count + 2 > len(writer.buffer) || writer.lines >= RESULT_LINE_CAPACITY {
		writer.fits = false
		return
	}
	writer.buffer[writer.count] = u8(Run_Part.End_Line)
	writer.buffer[writer.count + 1] = 0
	writer.count += 2
	writer.lines += 1
	writer.column = 0
}
