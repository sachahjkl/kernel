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
	Drop      = 2, // No room, and the program reads on to find an Escape (`running_key_can_be_taken`): the key is lost, and the program counts it.
}

// running_key_can_be_taken says if the program takes the next key from its
// queue while a line runs. With a place for the key, yes. With no place,
// only while the line waits in a call that Escape can stop: the program
// must read each key to find that Escape, and a key that is not Escape is
// then lost (`Drop`). In each other case the key stays in the queue of the
// program, in order, and nothing is lost: the full queue then stops its
// writer or is the stated bound of the keys typed ahead.
running_key_can_be_taken :: proc "contextless" (call_stoppable: bool, waiting: int, capacity: int) -> bool {
	return waiting < capacity || call_stoppable
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
