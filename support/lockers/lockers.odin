// What the program `locks` and its program `locker` agree on (the lock
// split of the kernel). `locks` starts LOCKER_CAPACITY lockers. Each one
// waits for a command on the board, works on its own objects from the time
// `start` to the time `end`, writes what it counted, and waits again.
package lockers

// The roles of the context of a locker.
GRANT_BOARD :: 0 // Memory, with Read and Write: the board, one page that `locks` also maps.
GRANT_PEER :: 1 // ROLE_CHURN: a program, with the right Control, that this one stops. 0: none.
VALUE_INDEX :: 0 // The place of the locker on the board.
VALUE_ROLE :: 1 // ROLE_MEASURE or ROLE_CHURN.
VALUE_STOP_AFTER :: 2 // ROLE_CHURN: the milliseconds after which the program stops its peer, or itself with no peer. 0: never.

// A locker of the measures: it works on the board.
ROLE_MEASURE :: 0
// A locker of the stress case: it has no board. Two threads compute with no
// end, and the first thread makes threads that end at once, and stops one
// of the two and makes it again, with no end, until a stop: `locks` stops
// the program while its threads run, closes its last handle at once, and
// the program can stop itself or its peer at the same time.
ROLE_CHURN :: 1
CHURN_THREADS :: 4 // The threads that a churn locker can have at one time.

LOCKER_CAPACITY :: 4
FAULT_PAGES :: 256 // The pages of one memory object in the measure of the pages on first use.
// The locker maps each such object at this address: the page tables of the
// range exist after the first one, and the budget pays for them one time.
FAULT_ADDRESS :: 0x0000_3000_0000_0000

Mode :: enum u32 {
	Wait    = 0, // Do nothing until the next command.
	Entries = 1, // Enter the kernel with one cheap operation on an own object, as often as possible.
	Faults  = 2, // Create a memory object, map it, write one byte in each page, unmap it, close it; again.
}

// One place of the board. `locks` writes the command, then adds 1 to
// `command`; the locker writes the result, then adds 1 to `done`.
Slot :: struct #align (64) {
	command:       u32, // The locker waits on this word.
	mode:          Mode,
	start:         u64, // Milliseconds since boot (the time page).
	end:           u64,
	done:          u32, // `locks` waits on this word. The locker adds 1 when it is ready, then for each command.
	_:             u32,
	count:         u64, // Entries: the operations. Faults: the pages written for the first time.
	entries:       u64, // The kernel entries of the locker during the command, as its library counted them.
	budget_before: u64, // The pages of the budget of the locker before the command.
	budget_after:  u64, // The same, after the command: each page returned.
}

Board :: struct {
	slots: [LOCKER_CAPACITY]Slot,
}

#assert(size_of(Board) <= 4096)
