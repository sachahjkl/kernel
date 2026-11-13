package line_editor

// The keys that come while a line runs.
//
// The program that owns the edit line keeps each key that the input types
// while a line runs, in the order of the keys, and acts on them when the
// line ends: the keys then mean what they mean when typed slowly. One key
// can act at once: Escape, when the line waits in a call that Escape can
// stop. Escape with no such call is a key of the next line as each other
// key: it closes the list that the keys before it opened.

// What the program does with a key that comes while a line runs.
Running_Key_Action :: enum u8 {
	Wait      = 0, // The key waits for the end of the line, after the keys before it.
	Stop_Call = 1, // The key stops the call that the line waits in.
	Drop      = 2, // No room: the key is lost.
}

// running_key_action says what a key does while a line runs.
//   escape:        the key is Escape.
//   call_stoppable: the line waits in a call that Escape can stop.
//   waiting:       the keys that wait; capacity: the most that can wait.
running_key_action :: proc "contextless" (escape: bool, call_stoppable: bool, waiting: int, capacity: int) -> Running_Key_Action {
	if escape && call_stoppable {
		return .Stop_Call
	}
	return waiting < capacity ? .Wait : .Drop
}
