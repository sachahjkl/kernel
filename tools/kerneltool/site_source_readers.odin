// The readers of the Odin files that the reference tables of the site come
// from (docs/SITE.md, "The reference tables"). Each reader knows the form
// that its file has now, and no more. When a file loses that form, the
// reader gives the file and the line, and the command `site` stops: a table
// never shows a part of a file that the reader did not understand.
//
// The readers read the text of the files, not the compiled program: the
// comments of a contract are its documentation, and the compiler drops them.
package kerneltool

import "core:fmt"
import "core:strings"

// One member of an Odin enumeration, as its file writes it.
Site_Enumeration_Member :: struct {
	name:    string,
	number:  int, // Its value: "= <n>", or its place when the line gives no value.
	comment: string, // The comment of its line, then the comment lines after it, joined.
	line:    int,
}

// One constant "NAME :: <decimal>" of a file.
Site_Constant :: struct {
	name:    string,
	value:   int,
	comment: string, // The comment lines just above it, then the comment of its line, joined.
	line:    int,
}

// One case of a procedure that chooses by the name of a program:
// `case "a", "b":` then `return <value>`.
Site_Name_Case :: struct {
	names:   []string,
	value:   string,
	comment: string, // The comment lines between the case and its return, then the comment of the return.
	line:    int, // The line of the return.
}

// One built-in command of the console:
// `command("<name>", {.<Kind>, ...}, .<Kind>, "<help>", <procedure>)`.
Site_Console_Command :: struct {
	name:       string,
	parameters: []string,
	result:     string,
	about:      string,
	file:       string,
	line:       int,
}

// site_is_identifier says if a text is an Odin identifier.
site_is_identifier :: proc(text: string) -> bool {
	if text == "" || (text[0] >= '0' && text[0] <= '9') {
		return false
	}
	for character in transmute([]u8)text {
		if !((character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9') || character == '_') {
			return false
		}
	}
	return true
}

// site_code_and_comment splits a line of Odin into its code and the text of
// its comment "// ...". A "//" inside a string is not a comment.
site_code_and_comment :: proc(line: string) -> (code: string, comment: string) {
	in_string := false
	for index := 0; index < len(line); index += 1 {
		switch {
		case line[index] == '\\' && in_string:
			index += 1
		case line[index] == '"':
			in_string = !in_string
		case !in_string && line[index] == '/' && index + 1 < len(line) && line[index + 1] == '/':
			return strings.trim_space(line[:index]), strings.trim_space(line[index + 2:])
		}
	}
	return strings.trim_space(line), ""
}

// site_join_comment adds a part to a comment, with one space between.
site_join_comment :: proc(comment, part: string) -> string {
	if comment == "" {
		return part
	}
	if part == "" {
		return comment
	}
	return strings.concatenate({comment, " ", part}, context.temp_allocator)
}

// site_enumeration_read reads the members of an enumeration. The form:
//   a line "<enumeration> :: enum <type> {" at the start of a line;
//   one member on each line: "<Name> = <decimal>," or "<Name>,", with a
//   comment "// ..." or not;
//   a line that is only a comment continues the comment of the member above
//   it (the comments of the contracts run over several lines);
//   a line "}" at the start of a line ends it.
site_enumeration_read :: proc(content, file, enumeration: string) -> (members: []Site_Enumeration_Member, problem: string) {
	lines := site_lines(content)
	start := strings.concatenate({enumeration, " :: enum"}, context.temp_allocator)
	list := make([dynamic]Site_Enumeration_Member, context.temp_allocator)
	first := -1
	for line, index in lines {
		if strings.has_prefix(line, start) && strings.has_suffix(line, "{") {
			first = index + 1
			break
		}
	}
	if first < 0 {
		return nil, fmt.tprintf("%s: no line \"%s <type> {{\"", file, start)
	}
	for index in first ..< len(lines) {
		line := lines[index]
		if line == "}" {
			if len(list) == 0 {
				return nil, fmt.tprintf("%s, line %d: the enumeration %s has no member", file, index + 1, enumeration)
			}
			return list[:], ""
		}
		code, comment := site_code_and_comment(line)
		if code == "" {
			if comment != "" && len(list) > 0 {
				list[len(list) - 1].comment = site_join_comment(list[len(list) - 1].comment, comment)
			}
			continue
		}
		if !strings.has_suffix(code, ",") {
			return nil, fmt.tprintf("%s, line %d: a member of %s is \"<Name> = <number>,\" or \"<Name>,\"; the line is \"%s\"", file, index + 1, enumeration, strings.trim_space(line))
		}
		code = strings.trim_suffix(code, ",")
		member := Site_Enumeration_Member{number = len(list), comment = comment, line = index + 1}
		if equals := strings.index_byte(code, '='); equals >= 0 {
			member.name = strings.trim_space(code[:equals])
			member.number = site_digits_value(strings.trim_space(code[equals + 1:]))
		} else {
			member.name = code
		}
		if !site_is_identifier(member.name) || member.number < 0 {
			return nil, fmt.tprintf("%s, line %d: a member of %s is \"<Name> = <decimal>,\" or \"<Name>,\"; the line is \"%s\"", file, index + 1, enumeration, strings.trim_space(line))
		}
		append(&list, member)
	}
	return nil, fmt.tprintf("%s: the enumeration %s has no line \"}\" at its end", file, enumeration)
}

// site_names_read reads a table of texts of an enumeration. The form:
//   a line "<table> := [<Enumeration>]string {" at the start of a line;
//   one line ".<Name> = \"<text>\"," for each member;
//   a line "}" at the start of a line ends it.
site_names_read :: proc(content, file, table: string) -> (names: map[string]string, problem: string) {
	lines := site_lines(content)
	start := strings.concatenate({table, " := ["}, context.temp_allocator)
	names = make(map[string]string, context.temp_allocator)
	first := -1
	for line, index in lines {
		if strings.has_prefix(line, start) && strings.has_suffix(line, "{") {
			first = index + 1
			break
		}
	}
	if first < 0 {
		return nil, fmt.tprintf("%s: no line \"%s<Enumeration>]string {{\"", file, start)
	}
	for index in first ..< len(lines) {
		line := lines[index]
		if line == "}" {
			return names, ""
		}
		code, _ := site_code_and_comment(line)
		equals := strings.index(code, " = ")
		if !strings.has_prefix(code, ".") || equals < 0 {
			return nil, fmt.tprintf("%s, line %d: a line of %s is \".<Name> = \"<text>\",\"", file, index + 1, table)
		}
		text, _, found := site_quoted(code, equals)
		if !found {
			return nil, fmt.tprintf("%s, line %d: a line of %s is \".<Name> = \"<text>\",\"", file, index + 1, table)
		}
		names[strings.trim_space(code[1:equals])] = text
	}
	return nil, fmt.tprintf("%s: the table %s has no line \"}\" at its end", file, table)
}

// site_constants_read reads the constants of a file whose name starts with
// one of the prefixes, from the first line that starts with `first` (from
// the first line of the file when it is ""). The form: a line
// "<NAME> :: <decimal>" at the start of a line, with a comment or not; the
// comment lines just above it, up to a line that is not a comment, are its
// comment too. A constant with one of the prefixes and another value is a
// problem: the table would miss it.
site_constants_read :: proc(content, file, first: string, prefixes: []string) -> (constants: []Site_Constant, problem: string) {
	lines := site_lines(content)
	list := make([dynamic]Site_Constant, context.temp_allocator)
	start := 0
	if first != "" {
		start = -1
		for line, index in lines {
			if strings.has_prefix(line, first) {
				start = index
				break
			}
		}
		if start < 0 {
			return nil, fmt.tprintf("%s: no line that starts with \"%s\"", file, first)
		}
	}
	for index in start ..< len(lines) {
		line := lines[index]
		separator := strings.index(line, " :: ")
		if separator <= 0 || !site_is_identifier(line[:separator]) {
			continue
		}
		name := line[:separator]
		wanted := false
		for prefix in prefixes {
			wanted ||= strings.has_prefix(name, prefix)
		}
		if !wanted {
			continue
		}
		code, comment := site_code_and_comment(line[separator + len(" :: "):])
		value := site_digits_value(code)
		if value < 0 {
			return nil, fmt.tprintf("%s, line %d: the constant %s is \"%s :: <decimal>\"; its value is \"%s\"", file, index + 1, name, name, code)
		}
		above := index
		for above > 0 && strings.has_prefix(strings.trim_space(lines[above - 1]), "//") {
			above -= 1
		}
		comment_above := ""
		for comment_line in lines[above:index] {
			_, text := site_code_and_comment(comment_line)
			comment_above = site_join_comment(comment_above, text)
		}
		append(&list, Site_Constant{name = name, value = value, comment = site_join_comment(comment_above, comment), line = index + 1})
	}
	if len(list) == 0 {
		return nil, fmt.tprintf("%s: no constant \"<NAME> :: <decimal>\" whose name starts with %v", file, prefixes)
	}
	return list[:], ""
}

// site_comment_above gives the comment lines just above the first line that
// starts with a prefix ("Operation :: enum"), joined, or "" when there is
// none: the documentation of a declaration, which a reference page shows
// above its table.
site_comment_above :: proc(content, prefix: string) -> string {
	lines := site_lines(content)
	for line, index in lines {
		if !strings.has_prefix(line, prefix) {
			continue
		}
		above := index
		for above > 0 && strings.has_prefix(strings.trim_space(lines[above - 1]), "//") {
			above -= 1
		}
		comment := ""
		for comment_line in lines[above:index] {
			_, text := site_code_and_comment(comment_line)
			comment = site_join_comment(comment, text)
		}
		return comment
	}
	return ""
}

// site_quoted_list gives each text in quotes of a part of a line.
site_quoted_list :: proc(text: string) -> []string {
	list := make([dynamic]string, context.temp_allocator)
	position := 0
	for {
		quoted, end, found := site_quoted(text, position)
		if !found {
			break
		}
		append(&list, quoted)
		position = end
	}
	return list[:]
}

// site_name_switch_read reads a procedure that chooses by the name of a
// program. The form:
//   a line "<procedure> :: proc" at the start of a line, up to a line "}";
//   in it, lines "case \"<name>\", \"<name>\":", each followed by comment
//   lines or not, then a line "return <value>", with a comment or not;
//   after the switch, a line "\treturn <value>": the value for each other name.
site_name_switch_read :: proc(content, file, procedure: string) -> (cases: []Site_Name_Case, otherwise: Site_Name_Case, problem: string) {
	lines := site_lines(content)
	start := strings.concatenate({procedure, " :: proc"}, context.temp_allocator)
	list := make([dynamic]Site_Name_Case, context.temp_allocator)
	first := -1
	for line, index in lines {
		if strings.has_prefix(line, start) {
			first = index + 1
			break
		}
	}
	if first < 0 {
		return nil, {}, fmt.tprintf("%s: no line \"%s\"", file, start)
	}
	pending: Site_Name_Case
	has_pending := false
	for index in first ..< len(lines) {
		line := lines[index]
		if line == "}" {
			if len(list) == 0 || otherwise.value == "" {
				return nil, {}, fmt.tprintf("%s, line %d: %s has no \"case \\\"<name>\\\":\" with its return, or no last \"return <value>\"", file, index + 1, procedure)
			}
			return list[:], otherwise, ""
		}
		code, comment := site_code_and_comment(line)
		switch {
		case strings.has_prefix(code, "case \""):
			if has_pending {
				return nil, {}, fmt.tprintf("%s, line %d: a case of %s has no line \"return <value>\"", file, index + 1, procedure)
			}
			pending = Site_Name_Case{names = site_quoted_list(code), comment = comment}
			has_pending = true
		case code == "" && comment != "" && has_pending:
			pending.comment = site_join_comment(pending.comment, comment)
		case strings.has_prefix(code, "return "):
			value := strings.trim_space(code[len("return "):])
			if has_pending {
				pending.value = value
				pending.comment = site_join_comment(pending.comment, comment)
				pending.line = index + 1
				append(&list, pending)
				has_pending = false
			} else if strings.has_prefix(line, "\treturn ") {
				otherwise = Site_Name_Case{value = value, comment = comment, line = index + 1}
			}
		}
	}
	return nil, {}, fmt.tprintf("%s: %s has no line \"}\" at its end", file, procedure)
}

// site_unquote gives the text of an Odin string with its escapes \" and \\.
site_unquote :: proc(text: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for index := 0; index < len(text); index += 1 {
		if text[index] == '\\' && index + 1 < len(text) {
			index += 1
		}
		strings.write_byte(&builder, text[index])
	}
	return strings.to_string(builder)
}

// site_string_at reads an Odin string that starts at a quote: its text,
// with its escapes, and the index after its closing quote.
site_string_at :: proc(text: string, start: int) -> (value: string, end: int, found: bool) {
	if start >= len(text) || text[start] != '"' {
		return "", 0, false
	}
	for index := start + 1; index < len(text); index += 1 {
		switch text[index] {
		case '\\':
			index += 1
		case '"':
			return site_unquote(text[start + 1:index]), index + 1, true
		}
	}
	return "", 0, false
}

// site_console_commands_read reads the built-in commands of the console.
// The form: each line whose code starts with "command(\"" is
// `command("<name>", {.<Kind>, ...}, .<Kind>, "<help>", <procedure>)`.
// The kind None of a parameter is any value: the console prints "Value".
site_console_commands_read :: proc(content, file: string) -> (commands: []Site_Console_Command, problem: string) {
	list := make([dynamic]Site_Console_Command, context.temp_allocator)
	for line, index in site_lines(content) {
		code, _ := site_code_and_comment(line)
		if !strings.has_prefix(code, "command(\"") {
			continue
		}
		wrong := fmt.tprintf("%s, line %d: a command is `command(\"<name>\", {{.<Kind>, ...}}, .<Kind>, \"<help>\", <procedure>)`", file, index + 1)
		name, after_name, has_name := site_string_at(code, len("command("))
		if !has_name || !strings.has_prefix(code[after_name:], ", {") {
			return nil, wrong
		}
		list_start := after_name + len(", {")
		list_end := strings.index_byte(code[list_start:], '}')
		if list_end < 0 {
			return nil, wrong
		}
		parameters := make([dynamic]string, context.temp_allocator)
		for part in strings.split(code[list_start:list_start + list_end], ",", context.temp_allocator) {
			kind := strings.trim_space(part)
			if kind == "" {
				continue
			}
			if !strings.has_prefix(kind, ".") || !site_is_identifier(kind[1:]) {
				return nil, wrong
			}
			append(&parameters, kind[1:] == "None" ? "Value" : kind[1:])
		}
		rest := code[list_start + list_end + 1:]
		if !strings.has_prefix(rest, ", .") {
			return nil, wrong
		}
		rest = rest[len(", ."):]
		comma := strings.index(rest, ", ")
		if comma < 0 || !site_is_identifier(rest[:comma]) {
			return nil, wrong
		}
		result := rest[:comma]
		about, after_about, has_about := site_string_at(rest, comma + len(", "))
		if !has_about || !strings.has_prefix(rest[after_about:], ", ") || !strings.has_suffix(rest, ")") {
			return nil, wrong
		}
		append(&list, Site_Console_Command{name = name, parameters = parameters[:], result = result, about = about, file = file, line = index + 1})
	}
	if len(list) == 0 {
		return nil, fmt.tprintf("%s: no line `command(\"<name>\", ...)`", file)
	}
	return list[:], ""
}

// site_console_signature gives a command as `help()` of the console prints
// it: "repeat(Text, Integer) -> Text"; no arrow for the result None.
site_console_signature :: proc(command: Site_Console_Command) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, command.name)
	strings.write_byte(&builder, '(')
	for parameter, index in command.parameters {
		if index > 0 {
			strings.write_string(&builder, ", ")
		}
		strings.write_string(&builder, parameter)
	}
	strings.write_byte(&builder, ')')
	if command.result != "None" {
		strings.write_string(&builder, " -> ")
		strings.write_string(&builder, command.result)
	}
	return strings.to_string(builder)
}

// The parts of the comment of a kernel operation. The contract writes each
// operation as "<Name> = <n>, // (<parameters>) -> <result>. <text>", and
// the lines after it continue the text.
Site_Operation :: struct {
	member:     Site_Enumeration_Member,
	parameters: string, // The text between the parentheses, as the comment writes it.
	result:     string, // The text after "->" up to the end of its sentence, or "".
	text:       string, // The rest of the comment.
}

// site_operation_parts splits the comment of an operation. A comment that
// does not start with "(" has no parameters: all of it is the text.
site_operation_parts :: proc(member: Site_Enumeration_Member) -> Site_Operation {
	operation := Site_Operation{member = member, text = member.comment}
	comment := member.comment
	if !strings.has_prefix(comment, "(") {
		return operation
	}
	depth := 0
	closing := -1
	for index in 0 ..< len(comment) {
		if comment[index] == '(' {
			depth += 1
		} else if comment[index] == ')' {
			depth -= 1
			if depth == 0 {
				closing = index
				break
			}
		}
	}
	if closing < 0 {
		return operation
	}
	operation.parameters = comment[1:closing]
	rest := comment[closing + 1:]
	if strings.has_prefix(rest, " -> ") {
		rest = rest[len(" -> "):]
		end := strings.index(rest, ". ")
		if end < 0 {
			operation.result = strings.trim_suffix(strings.trim_space(rest), ".")
			rest = ""
		} else {
			operation.result = rest[:end]
			rest = rest[end + 2:]
		}
	}
	rest = strings.trim_prefix(rest, ":")
	rest = strings.trim_prefix(rest, ".")
	operation.text = strings.trim_space(rest)
	return operation
}
