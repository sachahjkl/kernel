package line_editor

// Where the caret is, for a completion: what the names must match, and
// which bytes a chosen name replaces. The language of the line is the one
// of the console: names of letters, digits, '_' and '.', texts in double
// quotes, calls as name(argument, argument).
Completion_Place :: enum u8 {
	None   = 0, // No name ends at the caret.
	Name   = 1, // A name that has no dot: query is the whole name.
	Member = 2, // A name with a dot: owner is the part before the last dot, query the part after it.
	Quoted = 3, // Inside the quotes of the first argument of a call: owner is the name of the call.
}

// What the caret is in, for a completion: `completion_context` gives it.
Completion_Context :: struct {
	place:          Completion_Place, // Where the caret is.
	query:          string, // The bytes before the caret that a name must match.
	owner:          string, // Member: the name before the last dot. Quoted: the name of the call.
	word_start:     int, // The first byte of the whole name (Name and Member), or of the text (Quoted).
	replace_start:  int, // The bytes that a chosen name replaces: from replace_start ...
	replace_end:    int, // ... to replace_end. The name continues after the caret up to replace_end.
	call_follows:   bool, // A '(' follows replace_end: a chosen command needs no '('.
	quote_follows:  bool, // Quoted: a '"' follows replace_end: a chosen name needs no closing quote.
}

// name_character says if a byte can be in a name: a letter, a digit or
// '_'.
name_character :: proc "contextless" (character: u8) -> bool {
	return character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character >= '0' && character <= '9' || character == '_'
}

// digit says if a byte is a decimal digit.
digit :: proc "contextless" (character: u8) -> bool {
	return character >= '0' && character <= '9'
}

// completion_context reads the line before the caret. allow_empty: an
// empty name at the caret is a Name with an empty query (the input asks
// for all the names with Tab); with false, it is None.
completion_context :: proc "contextless" (text: string, caret_asked: int, allow_empty := false) -> (found: Completion_Context) {
	caret := clamp(caret_asked, 0, len(text))
	// The quotes before the caret: an odd count puts the caret in a text.
	quote_count := 0
	last_quote := -1
	for index in 0 ..< caret {
		if text[index] == '"' {
			quote_count += 1
			last_quote = index
		}
	}
	if quote_count % 2 == 1 {
		// Only the first argument of a call: `name("`, with spaces allowed
		// between the '(' and the quote.
		before := last_quote
		for before > 0 && text[before - 1] == ' ' {
			before -= 1
		}
		if before == 0 || text[before - 1] != '(' {
			return {}
		}
		name_end := before - 1
		for name_end > 0 && text[name_end - 1] == ' ' {
			name_end -= 1
		}
		name_start := name_end
		for name_start > 0 && (name_character(text[name_start - 1]) || text[name_start - 1] == '.') {
			name_start -= 1
		}
		if name_start == name_end || digit(text[name_start]) {
			return {}
		}
		end := caret
		for end < len(text) && text[end] != '"' {
			end += 1
		}
		return {
			place = .Quoted,
			query = text[last_quote + 1:caret],
			owner = text[name_start:name_end],
			word_start = last_quote + 1,
			replace_start = last_quote + 1,
			replace_end = end,
			quote_follows = end < len(text),
		}
	}
	start := caret
	for start > 0 && (name_character(text[start - 1]) || text[start - 1] == '.') {
		start -= 1
	}
	// The name continues after the caret up to its next dot.
	end := caret
	for end < len(text) && name_character(text[end]) {
		end += 1
	}
	word := text[start:caret]
	if len(word) > 0 && (digit(word[0]) || word[0] == '.') {
		return {}
	}
	if len(word) == 0 && !allow_empty {
		return {}
	}
	found = {
		place         = .Name,
		query         = word,
		word_start    = start,
		replace_start = start,
		replace_end   = end,
		call_follows  = end < len(text) && text[end] == '(',
	}
	for index := len(word) - 1; index >= 0; index -= 1 {
		if word[index] == '.' {
			found.place = .Member
			found.owner = word[:index]
			found.query = word[index + 1:]
			found.replace_start = start + index + 1
			break
		}
	}
	return found
}

// The depth of calls that call_at_caret follows: a deeper call is not
// found. A line of LINE_CAPACITY bytes cannot hold more open calls than
// this in any useful expression.
CALL_DEPTH_LIMIT :: 16

// call_at_caret finds the call that the caret is in: the name before the
// innermost '(' that is open at the caret, outside the quotes, and the
// number of the argument at the caret, from 0 (the commas of that call).
call_at_caret :: proc "contextless" (text: string, caret_asked: int) -> (name: string, argument: int, found: bool) {
	caret := clamp(caret_asked, 0, len(text))
	opens: [CALL_DEPTH_LIMIT]int
	commas: [CALL_DEPTH_LIMIT]int
	depth := 0
	too_deep := 0 // The open calls past the limit.
	quoted := false
	for index in 0 ..< caret {
		character := text[index]
		if character == '"' {
			quoted = !quoted
			continue
		}
		if quoted {
			continue
		}
		switch character {
		case '(':
			if depth == CALL_DEPTH_LIMIT {
				too_deep += 1
			} else {
				opens[depth] = index
				commas[depth] = 0
				depth += 1
			}
		case ')':
			if too_deep > 0 {
				too_deep -= 1
			} else if depth > 0 {
				depth -= 1
			}
		case ',':
			if too_deep == 0 && depth > 0 {
				commas[depth - 1] += 1
			}
		}
	}
	if depth == 0 || too_deep > 0 {
		return "", 0, false
	}
	name_end := opens[depth - 1]
	for name_end > 0 && text[name_end - 1] == ' ' {
		name_end -= 1
	}
	name_start := name_end
	for name_start > 0 && (name_character(text[name_start - 1]) || text[name_start - 1] == '.') {
		name_start -= 1
	}
	if name_start == name_end || digit(text[name_start]) {
		return "", 0, false
	}
	return text[name_start:name_end], commas[depth - 1], true
}
