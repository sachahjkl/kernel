// The words of the language of the console, and what each part of a line
// is (docs/CONSOLE.md, section 7). The parser of the console reads its
// names, numbers and texts with token_next and the procedures under it, so
// the colors of a line and the parser agree on where a token starts and
// ends: there is one scanner.
//
// The package has no state, calls no allocator and makes no kernel call:
// each procedure reads a text and writes into memory of the caller. It
// reads a line that is not finished: a text with no end quote, a name the
// input still types, any byte. It never stops at a fault: a byte that the
// language does not take is one token of the kind Unknown.
package console_language

import terminal "support:terminal"

// The kinds of tokens. The parser reads the operators one byte at a time;
// the arrow '->' is a token of the signatures, not of an expression.
Token_Kind :: enum u8 {
	None            = 0, // The end of the text.
	Name            = 1, // A letter or '_', then letters, digits, '_' and '.': monitor.count, r.x.
	Number          = 2, // Digits.
	Text            = 3, // A text in double quotes, with its two quotes.
	Text_Unfinished = 4, // A quote and the rest of the line: no end quote yet.
	Operator        = 5, // One byte of OPERATOR_BYTES.
	Arrow           = 6, // '->'.
	Unknown         = 7, // One byte of no other token.
}

// A token: its kind and its bytes, text[start:end].
Token :: struct {
	kind:  Token_Kind, // What the bytes are.
	start: int, // The first byte.
	end:   int, // The byte after the last.
}

OPERATOR_BYTES :: "+-*/%=(),:.{}" // The bytes that are an operator alone.

// A line that is finished: no name is still being typed.
NO_CARET :: -1

// name_first says if a byte can start a name: a letter or '_'.
name_first :: proc "contextless" (character: u8) -> bool {
	return character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character == '_'
}

// digit says if a byte is a decimal digit.
digit :: proc "contextless" (character: u8) -> bool {
	return character >= '0' && character <= '9'
}

// operator_byte says if a byte is one of OPERATOR_BYTES.
operator_byte :: proc "contextless" (character: u8) -> bool {
	operators := OPERATOR_BYTES
	for index in 0 ..< len(operators) {
		if operators[index] == character {
			return true
		}
	}
	return false
}

// space_end gives the first byte at or after position that is not a space.
space_end :: proc "contextless" (text: string, position: int) -> int {
	place := clamp(position, 0, len(text))
	for place < len(text) && text[place] == ' ' {
		place += 1
	}
	return place
}

// name_end gives the end of the name that starts at start, or start when no
// name starts there.
name_end :: proc "contextless" (text: string, start: int) -> int {
	place := clamp(start, 0, len(text))
	if place == len(text) || !name_first(text[place]) {
		return place
	}
	place += 1
	for place < len(text) && (name_first(text[place]) || digit(text[place]) || text[place] == '.') {
		place += 1
	}
	return place
}

// number_end gives the end of the digits that start at start.
number_end :: proc "contextless" (text: string, start: int) -> int {
	place := clamp(start, 0, len(text))
	for place < len(text) && digit(text[place]) {
		place += 1
	}
	return place
}

// text_end gives the end of the text whose quote is at start: after its end
// quote, or the end of the line with finished false.
text_end :: proc "contextless" (text: string, start: int) -> (end: int, finished: bool) {
	place := clamp(start, 0, len(text)) + 1
	for place < len(text) {
		if text[place] == '"' {
			return place + 1, true
		}
		place += 1
	}
	return len(text), false
}

// token_next gives the token at or after position, after its spaces. At
// the end of the text: the kind None, with start and end at the end.
token_next :: proc "contextless" (text: string, position: int) -> Token {
	start := space_end(text, position)
	if start >= len(text) {
		return {kind = .None, start = len(text), end = len(text)}
	}
	character := text[start]
	switch {
	case name_first(character):
		return {kind = .Name, start = start, end = name_end(text, start)}
	case digit(character):
		return {kind = .Number, start = start, end = number_end(text, start)}
	case character == '"':
		end, finished := text_end(text, start)
		return {kind = finished ? .Text : .Text_Unfinished, start = start, end = end}
	case character == '-' && start + 1 < len(text) && text[start + 1] == '>':
		return {kind = .Arrow, start = start, end = start + 2}
	case operator_byte(character):
		return {kind = .Operator, start = start, end = start + 1}
	}
	return {kind = .Unknown, start = start, end = start + 1}
}

// ---- What each part of a line is.

// What a name is for the console that shows the line.
Name_Role :: enum u8 {
	Unknown  = 0, // The console knows no such name.
	Function = 1, // A command, or an export of a module or of a service.
	Record   = 2, // A command that makes a record: its name is a type.
	Module   = 3, // A module or a service.
	Variable = 4, // A variable of the console.
}

// The console gives the roles of its names. The package keeps no table of
// names: the names change with each module that the console loads.
Name_Lookup :: struct {
	data:    rawptr, // The state of the console.
	role_of: proc "contextless" (data: rawptr, name: string) -> Name_Role, // Gives the role of a name.
}

// role_of gives the role of a name through a lookup. A lookup with no
// procedure knows no name.
role_of :: proc "contextless" (lookup: Name_Lookup, name: string) -> Name_Role {
	return lookup.role_of == nil ? .Unknown : lookup.role_of(lookup.data, name)
}

// run_add writes the run text[start:end] of a kind after count runs. A
// part longer than 255 bytes is several runs; a run cannot start after the
// byte 255 (a row has RUN_LIMIT bytes); the kind None is no run. It gives
// the new count; runs that do not fit are not written.
run_add :: proc "contextless" (runs: []terminal.Code_Run, count: int, start, end: int, kind: terminal.Code_Kind) -> int {
	if kind == .None {
		return count
	}
	written := count
	place := start
	for place < end && written < len(runs) && place <= 255 {
		length := min(end - place, 255)
		runs[written] = {start = u8(place), length = u8(length), kind = kind}
		written += 1
		place += length
	}
	return written
}

// line_runs writes the runs of an expression of the console: text[first:]
// is the expression (text[:first] is a prompt, with no run). caret is the
// place of the caret in text, or NO_CARET for a line that is finished. It
// gives the count of runs written; when runs is full, the rest of the line
// has no run, and its text is whole.
//
// A name that is a command or a module has its color at once, while the
// input types it. A name that is nothing that the console knows is marked
// Unknown only after the input typed a byte after it: a name that ends at
// the caret or at the end of the line is still being typed, and has no
// run. A text with no end quote is Text_Unfinished, not an error.
line_runs :: proc "contextless" (text: string, first: int, caret: int, lookup: Name_Lookup, runs: []terminal.Code_Run) -> int {
	count := 0
	position := clamp(first, 0, len(text))
	first_token := true
	for count < len(runs) {
		token := token_next(text, position)
		if token.kind == .None {
			break
		}
		position = token.end
		switch token.kind {
		case .None:
		case .Name:
			being_typed := caret != NO_CARET && (token.end == caret || token.end == len(text))
			assigned := false
			if first_token {
				next := token_next(text, token.end)
				assigned = next.kind == .Operator && text[next.start] == '='
			}
			count = name_runs(text, token, being_typed, assigned, lookup, runs, count)
		case .Number:
			count = run_add(runs, count, token.start, token.end, .Number)
		case .Text:
			count = run_add(runs, count, token.start, token.end, .Text)
		case .Text_Unfinished:
			count = run_add(runs, count, token.start, token.end, .Text_Unfinished)
		case .Operator:
			count = run_add(runs, count, token.start, token.end, .Operator)
		case .Arrow:
			count = run_add(runs, count, token.start, token.end, .Arrow)
		case .Unknown:
			count = run_add(runs, count, token.start, token.end, .Unknown)
		}
		first_token = false
	}
	return count
}

// name_runs writes the runs of one name of a line. assigned: the name is
// the first of the line and '=' follows it: it names a variable.
name_runs :: proc "contextless" (text: string, token: Token, being_typed, assigned: bool, lookup: Name_Lookup, runs: []terminal.Code_Run, count: int) -> int {
	name := text[token.start:token.end]
	written := count
	last_dot := -1
	first_dot := -1
	for index in 0 ..< len(name) {
		if name[index] == '.' {
			last_dot = index
			if first_dot < 0 {
				first_dot = index
			}
		}
	}
	role := role_of(lookup, name)
	switch role {
	case .Function, .Record:
		kind := terminal.Code_Kind.Function
		if role == .Record {
			kind = .Type
		}
		if last_dot < 0 {
			return run_add(runs, written, token.start, token.end, kind)
		}
		// monitor.count: the module, the dot, the export.
		written = run_add(runs, written, token.start, token.start + last_dot, .Module)
		written = run_add(runs, written, token.start + last_dot, token.start + last_dot + 1, .Operator)
		return run_add(runs, written, token.start + last_dot + 1, token.end, kind)
	case .Module:
		return run_add(runs, written, token.start, token.end, .Module)
	case .Variable:
		return run_add(runs, written, token.start, token.end, .Variable)
	case .Unknown:
	}
	if assigned {
		return run_add(runs, written, token.start, token.end, .Variable)
	}
	if first_dot > 0 {
		owner := name[:first_dot]
		#partial switch role_of(lookup, owner) {
		case .Variable:
			// variable.field: the console checks the field when the line runs.
			return run_add(runs, written, token.start, token.end, .Variable)
		case .Module:
			// A module and a name that is not one of its exports, or not yet.
			written = run_add(runs, written, token.start, token.start + first_dot, .Module)
			written = run_add(runs, written, token.start + first_dot, token.start + first_dot + 1, .Operator)
			if being_typed {
				return written
			}
			return run_add(runs, written, token.start + first_dot + 1, token.end, .Unknown)
		}
	}
	if being_typed {
		return written
	}
	return run_add(runs, written, token.start, token.end, .Unknown)
}

// The parts of a signature, for signature_runs.
Signature_Place :: enum u8 {
	Words      = 0, // Before the parameters: "export of monitor", "command", "3 lines ago".
	Parameters = 1, // In the parentheses of the parameters, before a ':'.
	Type       = 2, // After ':' or '->': a type, with what its parentheses hold.
}

// signature_runs writes the runs of what a row of the completion list says
// about its name, text[first:]: words, then a signature as the console
// writes it: "export of monitor (names: Table(Count_Name, Read)) ->
// Table(Count)". The words before the parameters are Words, and the word
// after "of" is the Module. In the parentheses, a name before ':' is a
// Parameter; after ':' or '->', each name is a Type, also in the
// parentheses of the type. It gives the count of runs written.
signature_runs :: proc "contextless" (text: string, first: int, runs: []terminal.Code_Run) -> int {
	count := 0
	position := clamp(first, 0, len(text))
	place := Signature_Place.Words
	in_parameters := false
	type_parentheses := 0 // The parentheses that the type at this place opened.
	after_of := false
	for count < len(runs) {
		token := token_next(text, position)
		if token.kind == .None {
			break
		}
		position = token.end
		bytes := text[token.start:token.end]
		kind := terminal.Code_Kind.Unknown
		switch token.kind {
		case .None:
		case .Name:
			switch place {
			case .Words:
				kind = .Words
				if after_of {
					kind = .Module
				}
			case .Parameters:
				next := token_next(text, token.end)
				if next.kind == .Operator && text[next.start] == ':' {
					kind = .Parameter
				} else {
					// A parameter with no name: its type.
					kind = .Type
					place = .Type
				}
			case .Type:
				kind = .Type
			}
		case .Number:
			kind = .Number
			if place == .Words {
				kind = .Words
			}
		case .Text:
			kind = .Text
		case .Text_Unfinished:
			kind = .Text_Unfinished
		case .Arrow:
			kind = .Arrow
			place = .Type
			type_parentheses = 0
		case .Operator:
			kind = .Operator
			switch bytes {
			case "(":
				if place == .Words && !in_parameters {
					in_parameters = true
					place = .Parameters
				} else {
					type_parentheses += 1
					place = .Type
				}
			case ")":
				if type_parentheses > 0 {
					type_parentheses -= 1
				} else if in_parameters {
					in_parameters = false
					place = .Words
				}
			case ",":
				if type_parentheses == 0 && in_parameters {
					place = .Parameters
				}
			case ":":
				place = .Type
				type_parentheses = 0
			case:
				if place == .Words {
					kind = .Words
				}
			}
		case .Unknown:
			if place == .Words {
				kind = .Words
			}
		}
		after_of = token.kind == .Name && bytes == "of" && place == .Words
		count = run_add(runs, count, token.start, token.end, kind)
	}
	return count
}

// ---- The integers of a line.
//
// An Integer of the console has 64 bits with a sign. An operation whose
// result does not fit gives ok false, and the console ends the line with an
// error: a result that wrapped is a wrong number that looks right.

INTEGER_LEAST :: min(i64) // The least Integer of a line.
INTEGER_MOST :: max(i64) // The largest Integer of a line.

// number_value gives the value of the decimal digits text[start:end]. ok is
// false when the number is larger than INTEGER_MOST, or when a byte is not a
// digit.
number_value :: proc "contextless" (text: string, start, end: int) -> (value: i64, ok: bool) {
	first := clamp(start, 0, len(text))
	last := clamp(end, first, len(text))
	for place in first ..< last {
		if !digit(text[place]) {
			return 0, false
		}
		digit_value := i64(text[place] - '0')
		if value > (INTEGER_MOST - digit_value) / 10 {
			return 0, false
		}
		value = value * 10 + digit_value
	}
	return value, true
}

// integer_add gives a + b. ok is false when the sum does not fit.
integer_add :: proc "contextless" (a, b: i64) -> (sum: i64, ok: bool) {
	if b > 0 && a > INTEGER_MOST - b || b < 0 && a < INTEGER_LEAST - b {
		return 0, false
	}
	return a + b, true
}

// integer_subtract gives a - b. ok is false when the difference does not fit.
integer_subtract :: proc "contextless" (a, b: i64) -> (difference: i64, ok: bool) {
	if b > 0 && a < INTEGER_LEAST + b || b < 0 && a > INTEGER_MOST + b {
		return 0, false
	}
	return a - b, true
}

// integer_multiply gives a * b. ok is false when the product does not fit.
integer_multiply :: proc "contextless" (a, b: i64) -> (product: i64, ok: bool) {
	if a == 0 || b == 0 {
		return 0, true
	}
	// The one product with -1 that does not fit; the division below
	// cannot take it.
	if a == -1 || b == -1 {
		other := a == -1 ? b : a
		if other == INTEGER_LEAST {
			return 0, false
		}
		return -other, true
	}
	if a > 0 {
		if b > 0 && a > INTEGER_MOST / b || b < 0 && b < INTEGER_LEAST / a {
			return 0, false
		}
	} else {
		if b > 0 && a < INTEGER_LEAST / b || b < 0 && a < INTEGER_MOST / b {
			return 0, false
		}
	}
	return a * b, true
}

// integer_negate gives -a. ok is false for INTEGER_LEAST: its opposite does
// not fit.
integer_negate :: proc "contextless" (a: i64) -> (opposite: i64, ok: bool) {
	if a == INTEGER_LEAST {
		return 0, false
	}
	return -a, true
}

// integer_divide gives a / b and a % b. ok is false when b is 0, and when
// the quotient does not fit (INTEGER_LEAST / -1). The caller tells the two
// apart with b.
integer_divide :: proc "contextless" (a, b: i64) -> (quotient, rest: i64, ok: bool) {
	if b == 0 {
		return 0, 0, false
	}
	// The processor refuses INTEGER_LEAST / -1: no division runs with -1.
	if b == -1 {
		opposite, fits := integer_negate(a)
		return opposite, 0, fits
	}
	return a / b, a % b, true
}
