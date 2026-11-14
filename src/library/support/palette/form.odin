package palette

import "contract:palette_table"
import "support:line_editor"

// The form of an entry with parameters (docs/DESIGN.md, "Palette"): the
// input band shows the call, with one field for each parameter. A field has
// the kind of its parameter and takes only what that kind can be. The
// values go to the provider as typed values: the panel builds no line.

FIELD_CAPACITY :: palette_table.PARAMETER_CAPACITY
INTEGER_FIELD_CAPACITY :: 20 // The characters of an Integer field: a sign and 19 digits.
MESSAGE_CAPACITY :: 96 // The bytes of the sentence that says why a key or a field is refused.

// The form. It holds a copy of the entry and of the record that the
// provider gave: the list of the panel can change while the form is open.
Form :: struct {
	active:           bool, // The panel has a form: it is in the state Arguments, or it asks or waits after it.
	entry:            Entry, // The entry of the form.
	given:            palette_table.Entry, // The record of the provider: the names and the kinds of the parameters.
	generation:       u32, // The generation of the table that had the entry.
	field_count:      int, // The fields: the parameters of the entry.
	current:          int, // The field that has the caret.
	fields:           [FIELD_CAPACITY]line_editor.Line, // The text of each field, and the caret in it.
	candidates:       [palette_table.CANDIDATE_CAPACITY]palette_table.Candidate, // What the provider gave for the current field: a checked copy.
	candidate_count:  int, // The candidates in use.
	candidate_kind:   palette_table.Candidate_Kind, // What they are.
	shown:            [palette_table.CANDIDATE_CAPACITY]u8, // The candidates that the text of the field matches, in their order.
	shown_count:      int, // The shown candidates in use.
	candidate_choice: int, // The chosen one, as an index in `shown`; NO_ROW with none.
	// The owner asked the provider for the candidates of the current field,
	// and no answer came yet. Tab then waits: it never goes to the next
	// field while a candidate that it can take is on its way.
	candidates_pending: bool,
	message:          [MESSAGE_CAPACITY]u8, // Why the last key or a field was refused.
	message_length:   int, // 0: no message.
}

// form_can_open says if the panel has a field for each parameter of an
// entry: an Integer and a Text can be typed. An entry with a parameter of
// another kind (a Table, a Record, a Handle, Bytes, any value) opens in
// the window of the provider, where a line can compose such a value.
form_can_open :: proc "contextless" (given: ^palette_table.Entry) -> bool {
	if given == nil || given.parameter_count == 0 {
		return false
	}
	for kind in given.parameters[:min(int(given.parameter_count), FIELD_CAPACITY)] {
		if kind != .Integer && kind != .Text {
			return false
		}
	}
	return true
}

// form_open makes the form of an entry of the list, with empty fields and
// the caret in the first one, and gives the panel the state Arguments.
form_open :: proc "contextless" (panel: ^Panel, entry: ^Entry) {
	given := given_of(panel.list, entry)
	if !form_can_open(given) {
		return
	}
	form := &panel.form
	form.active = true
	form.entry = entry^
	form.given = given^
	form.generation = panel.list.snapshot.generation
	form.field_count = min(int(given.parameter_count), FIELD_CAPACITY)
	form.current = 0
	for &field in form.fields {
		line_editor.line_clear(&field)
	}
	form_candidates_clear(form)
	form.message_length = 0
	panel.state = .Arguments
}

// form_close ends the form.
form_close :: proc "contextless" (panel: ^Panel) {
	panel.form.active = false
	panel.form.message_length = 0
	form_candidates_clear(&panel.form)
}

// field_name gives the name of the parameter of a field, or "" when the
// provider gave none.
field_name :: proc "contextless" (form: ^Form, field: int) -> string {
	if field < 0 || field >= form.field_count {
		return ""
	}
	return string(form.given.parameter_names[field][:min(int(form.given.parameter_name_lengths[field]), palette_table.PARAMETER_NAME_CAPACITY)])
}

// field_text gives the text of a field.
field_text :: proc "contextless" (form: ^Form, field: int) -> string {
	if field < 0 || field >= form.field_count {
		return ""
	}
	return line_editor.line_text(&form.fields[field])
}

@(private)
message_set :: proc "contextless" (form: ^Form, field: int, sentence: string) {
	form.message_length = 0
	name := field_name(form, field)
	if name != "" {
		form.message_length += copy(form.message[form.message_length:], name)
		form.message_length += copy(form.message[form.message_length:], ": ")
	}
	form.message_length += copy(form.message[form.message_length:], sentence)
}

// form_message gives the sentence that says why the last key or a field
// was refused, or "".
form_message :: proc "contextless" (form: ^Form) -> string {
	return string(form.message[:clamp(form.message_length, 0, MESSAGE_CAPACITY)])
}

// form_field_edit gives one key to the field that has the caret. A field
// takes only what its kind can be: an Integer field takes digits, and one
// "-" at its start; a Text field takes each character but a quote, which a
// line of the provider has no way to hold. A refused key changes nothing
// and leaves a sentence for the detail line. drawn: the panel shows
// something new. leave: Backspace in the first field, empty: the input
// goes back to the search.
form_field_edit :: proc "contextless" (panel: ^Panel, key: Key, character: u8) -> (drawn: bool, leave: bool) {
	form := &panel.form
	if form.current < 0 || form.current >= form.field_count {
		return false, false
	}
	field := &form.fields[form.current]
	kind := form.given.parameters[form.current]
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
		if field.count == 0 && form.current == 0 {
			return false, true
		}
		edit_key = .Backspace
	case .Delete:
		edit_key = .Delete
	case .Character:
		edit_key = .Character
		if kind == .Integer {
			digit := character >= '0' && character <= '9'
			sign := character == '-' && field.caret == 0 && (field.count == 0 || field.bytes[0] != '-')
			if !digit && !sign {
				message_set(form, form.current, "an Integer takes digits, and one - at its start")
				return true, false
			}
			if field.count >= INTEGER_FIELD_CAPACITY {
				message_set(form, form.current, "an Integer has 19 digits at most")
				return true, false
			}
		} else {
			if character == '"' {
				message_set(form, form.current, "a text holds no quote")
				return true, false
			}
			if field.count >= palette_table.ARGUMENT_TEXT_CAPACITY {
				message_set(form, form.current, "a text of the palette has 48 characters at most; the console takes a longer one")
				return true, false
			}
		}
	}
	had_message := form.message_length != 0
	form.message_length = 0
	if !line_editor.line_key(field, edit_key, character) {
		return had_message, false
	}
	if edit_key == .Backspace || edit_key == .Delete || edit_key == .Character {
		form_candidates_filter(form)
	}
	return true, false
}

// form_field_move moves the caret to the next field (step 1) or to the
// field before (step -1), from the last to the first and back. The
// candidates of the field before leave: the owner asks the provider for
// those of the new field. It gives true when the field changed.
form_field_move :: proc "contextless" (panel: ^Panel, step: int) -> bool {
	form := &panel.form
	if form.field_count < 2 {
		return false
	}
	form.current = (form.current + step + form.field_count) % form.field_count
	form.message_length = 0
	form_candidates_clear(form)
	return true
}

@(private)
form_candidates_clear :: proc "contextless" (form: ^Form) {
	form.candidates_pending = false
	form.candidate_count = 0
	form.shown_count = 0
	form.candidate_choice = NO_ROW
	form.candidate_kind = .None
}

// form_candidates_set gives the form the candidates of its current field,
// as the provider wrote them in the candidate area of its table: memory is
// the mapping of the table, count and kind the numbers of the answer. The
// form copies the area and checks the copy; an area that fails, and a kind
// out of its range, give no candidate.
form_candidates_set :: proc "contextless" (form: ^Form, memory: []u8, count: u64, kind: u64) {
	form_candidates_clear(form)
	if kind == 0 || kind > u64(max(palette_table.Candidate_Kind)) {
		return
	}
	copied, ok := palette_table.candidates_copy(memory, count, &form.candidates)
	if !ok {
		return
	}
	form.candidate_count = copied
	form.candidate_kind = palette_table.Candidate_Kind(kind)
	form_candidates_filter(form)
}

// candidate_name gives the name of a shown candidate.
candidate_name :: proc "contextless" (form: ^Form, shown: int) -> string {
	if shown < 0 || shown >= form.shown_count {
		return ""
	}
	candidate := &form.candidates[form.shown[shown]]
	return string(candidate.name[:min(int(candidate.length), palette_table.CANDIDATE_NAME_CAPACITY)])
}

// form_candidates_filter keeps the candidates that the text of the current
// field matches, by the fuzzy match of the list, in the order that the
// provider gave. The chosen candidate stays chosen when it is still shown,
// at the place that it has now; else the first one is chosen. The work is
// one match for each of at most 96 short names.
form_candidates_filter :: proc "contextless" (form: ^Form) {
	chosen_before := -1
	if form.candidate_choice >= 0 && form.candidate_choice < form.shown_count {
		chosen_before = int(form.shown[form.candidate_choice])
	}
	form.shown_count = 0
	typed := field_text(form, form.current)
	for &candidate, index in form.candidates[:clamp(form.candidate_count, 0, palette_table.CANDIDATE_CAPACITY)] {
		name := string(candidate.name[:min(int(candidate.length), palette_table.CANDIDATE_NAME_CAPACITY)])
		if _, _, matched := line_editor.fuzzy_match(typed, name); matched {
			form.shown[form.shown_count] = u8(index)
			form.shown_count += 1
		}
	}
	form.candidate_choice = form.shown_count > 0 ? 0 : NO_ROW
	for shown, place in form.shown[:form.shown_count] {
		if int(shown) == chosen_before {
			form.candidate_choice = place
		}
	}
}

// form_tab says what Tab does in a form: it waits while the candidates of
// the field are on their way; it takes the chosen candidate when the field
// does not hold it yet; else it goes to the next field.
Tab_Effect :: enum u8 {
	Waits = 0, // The candidates of the field did not come yet: the owner applies Tab when they come.
	Takes = 1, // The chosen candidate goes in the field.
	Moves = 2, // The caret goes to the next field.
}

form_tab :: proc "contextless" (form: ^Form) -> Tab_Effect {
	if form.candidates_pending {
		return .Waits
	}
	name := candidate_name(form, form.candidate_choice)
	if name != "" && name != field_text(form, form.current) {
		return .Takes
	}
	return .Moves
}

// form_candidate_move moves the choice in the shown candidates, from the
// last to the first and back. It gives true when the choice changed.
form_candidate_move :: proc "contextless" (form: ^Form, step: int) -> bool {
	if form.shown_count < 2 || form.candidate_choice < 0 {
		return false
	}
	form.candidate_choice = (form.candidate_choice + step + form.shown_count) % form.shown_count
	return true
}

// form_candidate_take writes the chosen candidate in the current field. It
// gives false when the field holds it already, or with no candidate.
form_candidate_take :: proc "contextless" (form: ^Form) -> bool {
	name := candidate_name(form, form.candidate_choice)
	if name == "" || name == field_text(form, form.current) {
		return false
	}
	line_editor.line_set(&form.fields[form.current], name)
	form.message_length = 0
	form_candidates_filter(form)
	return true
}

// integer_of gives the Integer that a text of digits is. ok is false for
// an empty text, a sign alone, a byte that is no digit, and a number that
// does not fit in 64 bits with a sign.
integer_of :: proc "contextless" (text: string) -> (value: i64, ok: bool) {
	negative := len(text) > 0 && text[0] == '-'
	digits := negative ? text[1:] : text
	if len(digits) == 0 {
		return 0, false
	}
	limit := negative ? u64(1) << 63 : u64(max(i64))
	total: u64
	for index in 0 ..< len(digits) {
		if digits[index] < '0' || digits[index] > '9' {
			return 0, false
		}
		digit := u64(digits[index] - '0')
		if total > (limit - digit) / 10 {
			return 0, false
		}
		total = total * 10 + digit
	}
	if negative {
		return i64(-total), true
	}
	return i64(total), true
}

// form_check says if each field holds a value of its kind. If one does
// not, the caret goes to the first such field, and the detail line says
// why: "grant: empty".
form_check :: proc "contextless" (panel: ^Panel) -> bool {
	form := &panel.form
	for field in 0 ..< form.field_count {
		text := field_text(form, field)
		sentence := ""
		if len(text) == 0 {
			sentence = "empty"
		} else if form.given.parameters[field] == .Integer {
			if _, ok := integer_of(text); !ok {
				sentence = "not an Integer of 64 bits"
			}
		}
		if sentence != "" {
			if form.current != field {
				form.current = field
				form_candidates_clear(form)
			}
			message_set(form, field, sentence)
			return false
		}
	}
	form.message_length = 0
	return true
}

// form_argument gives the values of the Argument command of one field: a
// typed value, an Integer as a number and a Text as its bytes.
form_argument :: proc "contextless" (form: ^Form, field: int) -> [7]u64 {
	text := field_text(form, field)
	if form.given.parameters[field] == .Integer {
		value, _ := integer_of(text)
		return palette_table.argument_pack(field, .Integer, value, "")
	}
	return palette_table.argument_pack(field, .Text, 0, text)
}

// form_submit is Enter in a form. With all false, Enter in a field that is
// not the last one moves to the next field; in the last field, and with
// all true (Control with Enter), the form is checked. ready: each field
// holds a value, and the owner sends the entry or asks for a second Enter.
// moved: the caret went to another field, and the owner asks for its
// candidates.
form_submit :: proc "contextless" (panel: ^Panel, all: bool) -> (ready: bool, moved: bool) {
	form := &panel.form
	if !all && form.current < form.field_count - 1 {
		return false, form_field_move(panel, 1)
	}
	before := form.current
	ready = form_check(panel)
	return ready, form.current != before
}
