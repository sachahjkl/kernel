package palette

import "contract:palette_table"
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
	Tab       = 15, // In a form: the next field, or the chosen candidate.
	Shift_Tab = 16, // In a form: the field before.
	Control_Enter = 17, // In a form: run with the fields as they are. In the search: open the entry in the window of its provider.
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
	Back               = 10, // Leave the question, the result or the form, and go back one state.
	Field_Edit         = 11, // Give the key to the field of the form that has the caret.
	Field_Next         = 12, // Take the chosen candidate, or move the caret to the next field.
	Field_Previous     = 13, // Move the caret to the field before.
	Candidate_Previous = 14, // Move the choice one candidate up.
	Candidate_Next     = 15, // Move the choice one candidate down.
	Submit             = 16, // Enter in a form: the next field, or run from the last one.
	Submit_All         = 17, // Run the form from any field.
	Open_In_Console    = 18, // Write the chosen entry of a provider in the edit line of its window.
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
// - Arguments: the key super closes; Escape goes back to the search; a
//   character and the keys of the line edit the field; Tab takes the
//   chosen candidate or goes to the next field, Shift with Tab to the
//   field before; up and down move in the candidates; Enter goes to the
//   next field and runs from the last one; Control with Enter runs.
// - Running: the key super and Escape close the panel, and the line goes
//   on in the provider; each other key waits for nothing and does nothing.
// - Result: the key super and Escape close the panel; each other key goes
//   back to the search, with the typed part kept.
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
		case .Control_Enter:
			return .Open_In_Console
		case .Tab, .Shift_Tab, .Other:
			return .None
		}
	case .Confirm:
		switch key {
		case .Super:
			return .Close
		case .Enter:
			return .Confirm
		case .Escape, .Up, .Down, .Page_Up, .Page_Down, .Left, .Right, .Home, .End, .Backspace, .Delete, .Character, .Tab, .Shift_Tab, .Control_Enter, .Other:
			return .Back
		}
	case .Arguments:
		switch key {
		case .Super:
			return .Close
		case .Escape:
			return .Back
		case .Enter:
			return .Submit
		case .Control_Enter:
			return .Submit_All
		case .Tab:
			return .Field_Next
		case .Shift_Tab:
			return .Field_Previous
		case .Up:
			return .Candidate_Previous
		case .Down:
			return .Candidate_Next
		case .Left, .Right, .Home, .End, .Backspace, .Delete, .Character:
			return .Field_Edit
		case .Page_Up, .Page_Down, .Other:
			return .None
		}
	case .Running:
		return key == .Super || key == .Escape ? Action.Close : Action.None
	case .Result:
		return key == .Super || key == .Escape ? Action.Close : Action.Back
	}
	return .None
}

// What the chosen entry is, for the state that follows a key.
Chosen :: enum u8 {
	Nothing  = 0, // The list has no entry.
	Runs     = 1, // An entry that runs at the first Enter.
	Destroys = 2, // An entry that destroys something: it asks for a second Enter.
	Sends    = 3, // An entry of a provider with no parameter: the panel sends it and waits for what it gives.
	Destroys_Then_Sends = 4, // An entry of a provider that destroys something: a second Enter, then the panel sends it.
	Opens_Form    = 5, // An entry whose parameters the panel can type: Enter opens its form.
	Form_Sends    = 6, // The panel has a form: its entry is sent with the typed values.
	Form_Destroys = 7, // The panel has a form of an entry that destroys: a second Enter, then it is sent.
}

// chosen_of says what the chosen entry of a panel is.
chosen_of :: proc "contextless" (panel: ^Panel) -> Chosen {
	if panel.form.active {
		return .Destroys in panel.form.entry.flags ? Chosen.Form_Destroys : Chosen.Form_Sends
	}
	entry := chosen_entry(panel)
	if entry == nil {
		return .Nothing
	}
	// With the prefix of the manual, the choice of a program asks the
	// provider for its page.
	if prefix, _ := prefix_of(typed_text(panel)); prefix == .Manual && entry.kind == .Program {
		return .Sends
	}
	if .Needs_Arguments in entry.flags && form_can_open(given_of(panel.list, entry)) {
		return .Opens_Form
	}
	// An entry with parameters opens in the window of its provider: the
	// panel closes at once, as for an entry that runs.
	if entry_of_provider(entry) && .Needs_Arguments not_in entry.flags {
		return entry_destroys(entry) ? Chosen.Destroys_Then_Sends : Chosen.Sends
	}
	return entry_destroys(entry) ? Chosen.Destroys : Chosen.Runs
}

// state_after gives the state that follows an action in a state.
//
// An entry that runs closes the panel at once: what it started shows on
// the desktop. An entry that destroys goes to Confirm. An entry that the
// panel sends to its provider goes to Running; the answer of the provider,
// which is no key, then gives Result or closes the panel (result_set).
// Enter on an empty list keeps the search.
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
		case .Destroys, .Destroys_Then_Sends:
			return .Confirm
		case .Sends:
			return .Running
		case .Opens_Form:
			return .Arguments
		case .Form_Sends, .Form_Destroys:
			return state
		}
	case .Confirm:
		if state != .Confirm {
			return state
		}
		return chosen == .Destroys_Then_Sends || chosen == .Form_Destroys ? State.Running : State.Closed
	case .Back:
		#partial switch state {
		case .Confirm:
			// The question of a form goes back to the form, with its fields.
			return chosen == .Form_Destroys ? State.Arguments : State.Search
		case .Result, .Arguments:
			return .Search
		}
		return state
	case .Submit, .Submit_All:
		// The form is whole (form_submit): a second Enter first for an
		// entry that destroys.
		if state != .Arguments {
			return state
		}
		return chosen == .Form_Destroys ? State.Confirm : State.Running
	case .Open_In_Console:
		return state == .Search && chosen != .Nothing ? State.Closed : state
	case .None, .Edit, .Choose_Previous, .Choose_Next, .Choose_Page_Before, .Choose_Page_After, .Field_Edit, .Field_Next, .Field_Previous, .Candidate_Previous, .Candidate_Next:
		return state
	}
	return state
}

// typed_edit gives one key of the action Edit to the typed part. drawn:
// the panel shows something new (the text or the place of the caret).
// text_changed: the typed part changed, and the owner makes the list
// again for it (list_build, or a list of its own thread). A character past
// TYPED_CAPACITY is refused: a longer part matches no name.
//
// A change of the text ends the wait for a frame (choice_undrawn): the
// choice that no frame showed was of the list before, and the typed part
// asks for a new list. The owner makes Enter wait for that list, and its
// adoption chooses the first entry (Panel.typed_since_list).
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
		panel.choice_undrawn = false
		panel.typed_since_list = true
	}
	return true, text_changed
}

// panel_open opens a closed panel: an empty typed part, and the list that
// its owner made for it. It does no work on the entries: the open draws in
// the next frame.
panel_open :: proc "contextless" (panel: ^Panel) {
	panel.state = .Search
	panel.pressed_row = NO_ROW
}

// panel_close closes the panel and empties its typed part. The owner then
// makes the list of an empty typed part, for the next open.
panel_close :: proc "contextless" (panel: ^Panel) {
	panel.state = .Closed
	panel.pressed_row = NO_ROW
	form_close(panel)
	line_editor.line_clear(&panel.line)
}

// sent_set keeps the name of the entry that the panel sent to its
// provider: the panel shows it while it waits and over the result.
sent_set :: proc "contextless" (panel: ^Panel, entry: ^Entry) {
	panel.sent_length = copy(panel.sent_name[:], entry_name(entry))
}

// sent_text gives the name of the entry that the panel sent.
sent_text :: proc "contextless" (panel: ^Panel) -> string {
	return string(panel.sent_name[:clamp(panel.sent_length, 0, NAME_CAPACITY)])
}

// result_set gives a panel in the state Running what the provider
// answered, and the state that follows: Result when the panel has
// something to show; Closed when the window of the provider has the
// result, and the owner brings it to the front. memory is the mapping of
// the table of the provider and length the count that the provider gave:
// the panel copies the result area and checks the copy, and a result that
// fails is shown as a refusal with a sentence of the panel itself. A panel
// that is not in the state Running changes nothing: it waits for no
// answer.
result_set :: proc "contextless" (panel: ^Panel, outcome: u64, kind: u64, memory: []u8, length: u64) {
	if panel.state != .Running {
		return
	}
	result := &panel.result
	result.count = 0
	result.kind = kind <= u64(max(palette_table.Value_Kind)) ? palette_table.Value_Kind(kind) : .None
	switch palette_table.Outcome(outcome) {
	case .Shown_In_Console, .Edit_Opened, .Manual_Opened:
		panel.state = .Closed
		return
	case .Shown_In_Panel, .Failed, .Refused:
		result.outcome = palette_table.Outcome(outcome)
		count, ok := palette_table.result_copy(memory, length, &result.runs)
		if ok && count > 0 {
			result.count = count
			panel.state = .Result
			return
		}
	case .None, .Candidates_Ready:
	}
	result_sentence(panel, "the provider gave an answer that the panel refuses")
}

// result_sentence makes a panel show one sentence of its own as a refusal:
// the provider left, or its answer failed a check.
result_sentence :: proc "contextless" (panel: ^Panel, sentence: string) {
	result := &panel.result
	result.outcome = .Refused
	result.kind = .None
	writer := palette_table.Result_Writer{buffer = result.runs[:], fits = true}
	palette_table.result_run(&writer, .Failure, sentence)
	palette_table.result_line_end(&writer)
	result.count = writer.count
	panel.state = .Result
}
