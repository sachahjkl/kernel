package palette

import "support:line_editor"

// What each key does in each state of the panel. Two pure procedures hold
// the whole state machine: key_action says what a key asks, state_after
// says the state that follows. The owner of the panel translates the codes
// of its keyboard into `Key`, so the package does not depend on a keyboard
// and a host test runs each state with each key.

// A key, as the panel reads it.
Key :: enum u8 {
	Other     = 0, // A key that the panel does not use. It still goes to no program while the panel is open.
	Super     = 1, // The key that opens and closes the panel.
	Escape    = 2,
	Enter     = 3,
	Up        = 4,
	Down      = 5,
	Page_Up   = 6,
	Page_Down = 7,
	Left      = 8,
	Right     = 9,
	Home      = 10,
	End       = 11,
	Backspace = 12,
	Delete    = 13,
	Character = 14, // A printable character.
	Tab       = 15, // No entry of the panel has parameters: Tab does nothing.
}

// What a key asks of the panel.
Action :: enum u8 {
	None               = 0, // Nothing. In the state Closed: the key is not for the panel.
	Open               = 1, // Open the panel.
	Close              = 2, // Close the panel.
	Edit               = 3, // Give the key to the typed part: a character, or a key that moves the caret or removes a byte.
	Choose_Previous    = 4, // Move the choice one entry up, from the first to the last.
	Choose_Next        = 5, // Move the choice one entry down, from the last to the first.
	Choose_Page_Before = 6, // Move the choice a page up, with no wrap.
	Choose_Page_After  = 7, // Move the choice a page down, with no wrap.
	Run                = 8, // Run the chosen entry, or ask for a second Enter when it destroys.
	Confirm            = 9, // The second Enter: run the entry that destroys.
	Back               = 10, // Leave the question and go back to the search, with the typed part kept.
}

// key_action says what a key asks in a state.
//
// - Closed: only the key super acts: it opens the panel.
// - Search: the key super and Escape close; a character and the keys of
//   the line edit the typed part; the arrows and the page keys move the
//   choice; Enter runs the chosen entry.
// - Confirm: Enter runs the entry; the key super closes the panel; each
//   other key goes back to the search and does nothing else, so a key
//   typed too early never destroys and never edits.
key_action :: proc "contextless" (state: State, key: Key) -> Action {
	switch state {
	case .Closed:
		return key == .Super ? Action.Open : Action.None
	case .Search:
		switch key {
		case .Super, .Escape:
			return .Close
		case .Enter:
			return .Run
		case .Up:
			return .Choose_Previous
		case .Down:
			return .Choose_Next
		case .Page_Up:
			return .Choose_Page_Before
		case .Page_Down:
			return .Choose_Page_After
		case .Left, .Right, .Home, .End, .Backspace, .Delete, .Character:
			return .Edit
		case .Tab, .Other:
			return .None
		}
	case .Confirm:
		switch key {
		case .Super:
			return .Close
		case .Enter:
			return .Confirm
		case .Escape, .Up, .Down, .Page_Up, .Page_Down, .Left, .Right, .Home, .End, .Backspace, .Delete, .Character, .Tab, .Other:
			return .Back
		}
	}
	return .None
}

// What the chosen entry is, for the state that follows a key.
Chosen :: enum u8 {
	Nothing  = 0, // The list has no entry.
	Runs     = 1, // An entry that runs at the first Enter.
	Destroys = 2, // An entry that destroys something: it asks for a second Enter.
}

// chosen_of says what the chosen entry of a panel is.
chosen_of :: proc "contextless" (panel: ^Panel) -> Chosen {
	entry := chosen_entry(panel)
	if entry == nil {
		return .Nothing
	}
	return entry_destroys(entry) ? Chosen.Destroys : Chosen.Runs
}

// state_after gives the state that follows an action in a state.
//
// An entry that runs closes the panel at once: what it started shows on
// the desktop. An entry that destroys goes to Confirm. Enter on an empty
// list keeps the search.
state_after :: proc "contextless" (state: State, action: Action, chosen: Chosen) -> State {
	switch action {
	case .Open:
		return .Search
	case .Close:
		return .Closed
	case .Run:
		if state != .Search {
			return state
		}
		switch chosen {
		case .Nothing:
			return .Search
		case .Runs:
			return .Closed
		case .Destroys:
			return .Confirm
		}
	case .Confirm:
		return state == .Confirm ? State.Closed : state
	case .Back:
		return state == .Confirm ? State.Search : state
	case .None, .Edit, .Choose_Previous, .Choose_Next, .Choose_Page_Before, .Choose_Page_After:
		return state
	}
	return state
}

// typed_edit gives one key of the action Edit to the typed part. drawn:
// the panel shows something new (the text or the place of the caret).
// text_changed: the typed part changed, and the list is made again for
// it. A character past TYPED_CAPACITY is refused: a longer part matches no
// name.
typed_edit :: proc "contextless" (panel: ^Panel, key: Key, character: u8) -> (drawn: bool, text_changed: bool) {
	edit_key := line_editor.Edit_Key.None
	#partial switch key {
	case .Left:
		edit_key = .Left
	case .Right:
		edit_key = .Right
	case .Home:
		edit_key = .Home
	case .End:
		edit_key = .End
	case .Backspace:
		edit_key = .Backspace
	case .Delete:
		edit_key = .Delete
	case .Character:
		if panel.line.count >= TYPED_CAPACITY {
			return false, false
		}
		edit_key = .Character
	}
	if !line_editor.line_key(&panel.line, edit_key, character) {
		return false, false
	}
	text_changed = edit_key == .Backspace || edit_key == .Delete || edit_key == .Character
	if text_changed {
		list_build(panel)
	}
	return true, text_changed
}

// panel_open opens a closed panel: an empty typed part, and the list that
// entries_collect made for it. It does no work on the entries: the open
// draws in the next frame.
panel_open :: proc "contextless" (panel: ^Panel) {
	panel.state = .Search
	panel.pressed_row = NO_ROW
}

// panel_close closes the panel and makes it ready for its next open: no
// typed part, and the list of an empty typed part.
panel_close :: proc "contextless" (panel: ^Panel) {
	panel.state = .Closed
	line_editor.line_clear(&panel.line)
	// The choice and the rows shown go back to the top of the list.
	list_build(panel)
}
