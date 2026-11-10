package console

import module "contract:module"
import "support:system"

// The language of the console.
//
//   line       = name "=" expression | expression
//   expression = term { ("+" | "-") term }
//   term       = factor { ("*" | "/" | "%") factor }
//   factor     = "-" factor | integer | "text" | name | name "(" arguments ")" | "(" expression ")"
//
// A value is an Integer, a Text, a Record or a Handle. "+" joins two Texts.
// A Record has the description of a record of a module: the command with
// the name of the record makes one from its fields, and `variable.field`
// reads one field. A Handle names an object of the kernel that the console
// holds.

// The values are those of module.Type: the kind of a parameter is its type.
Kind :: enum u8 {
	None    = 0,
	Integer = 1,
	Text    = 2,
	Record  = 3,
	Handle  = 4,
}

Value :: struct {
	kind:    Kind,
	integer: i64, // An Integer. A Handle: the handle.
	text:    string,
	record:  []u8, // A Record: its bytes.
	file:    []u8, // A Record: the module that has its description.
	detail:  u32, // A Record: the index of its description in the module.
}

@(rodata)
kind_names := [Kind]string {
	.None    = "None",
	.Integer = "Integer",
	.Text    = "Text",
	.Record  = "Record",
	.Handle  = "Handle",
}

// type_text gives the name of a type: "Integer", the name of a record, or
// "Handle(Read)". The text lasts for one line.
type_text :: proc "contextless" (file: []u8, kind: Kind, detail: u32) -> string {
	if kind == .None {
		return "None"
	}
	writer := system.Writer {
		buffer = scratch[scratch_count:],
	}
	system.write_type(&writer, file, module.Type(kind), detail)
	scratch_count += writer.count
	return system.written(&writer)
}

// scratch_bytes gives zero bytes for a record, for one line.
scratch_bytes :: proc "contextless" (size: int) -> []u8 {
	start := (scratch_count + 7) &~ 7
	if size > len(scratch) - start {
		return nil
	}
	scratch_count = start + size
	bytes := scratch[start:scratch_count]
	for &b in bytes {
		b = 0
	}
	return bytes
}

// field_value gives one field of a Record value, by name.
field_value :: proc "contextless" (value: Value, name: string) -> (result: Value, ok: bool) {
	described := module.record_type(value.file, value.detail) or_return
	for number in 0 ..< described.field_count {
		item := module.field(value.file, described, number) or_return
		if module.string_at(value.file, item.name_offset, item.name_count) != name {
			continue
		}
		#partial switch item.type {
		case .Integer:
			return {kind = .Integer, integer = (^i64)(&value.record[item.offset])^}, true
		case .Handle:
			return {kind = .Handle, integer = i64((^u32)(&value.record[item.offset])^)}, true
		}
	}
	return {}, false
}

// print_value writes a value, without the end of the line.
//   Rectangle{x = 1, y = 2}        Handle 65541: Memory (Give, Read, Write)
print_value :: proc "contextless" (value: Value, nested := false) {
	switch value.kind {
	case .Integer:
		print(value.integer)
	case .Text:
		print(value.text)
	case .Record:
		described, ok := module.record_type(value.file, value.detail)
		if !ok {
			return
		}
		print(module.string_at(value.file, described.name_offset, described.name_count), "{")
		for number in 0 ..< described.field_count {
			item, _ := module.field(value.file, described, number)
			name := module.string_at(value.file, item.name_offset, item.name_count)
			print(number > 0 ? ", " : "", name, " = ")
			field, _ := field_value(value, name)
			print_value(field, true)
		}
		print("}")
	case .Handle:
		print("Handle ", u64(value.integer))
		if !nested {
			kind, rights, _ := system.handle_state(system.Handle(value.integer))
			buffer: [96]u8
			writer := system.Writer {
				buffer = buffer[:],
			}
			system.write_rights(&writer, rights, ", ")
			print(": ", system.object_names[kind])
			if kind != .None {
				print(" (", system.written(&writer), ")")
			}
		}
	case .None:
	}
}

VARIABLE_CAPACITY :: 16
VARIABLE_NAME_SIZE :: 16
VARIABLE_TEXT_SIZE :: 96
ARGUMENT_CAPACITY :: 6 // The parameters of an export: module.PARAMETER_CAPACITY.

Variable :: struct {
	name:       [VARIABLE_NAME_SIZE]u8,
	name_count: int, // 0: the slot is free.
	value:      Value,
	text:       [VARIABLE_TEXT_SIZE]u8,
	record:     [module.RECORD_SIZE_LIMIT / 8]u64,
}

variables: [VARIABLE_CAPACITY]Variable

// The memory of the Text values of one line.
scratch: [4096]u8
scratch_count: int

source: string
position: int
failed: bool

scratch_text :: proc "contextless" (parts: ..system.Part) -> string {
	text := system.format(scratch[scratch_count:], ..parts)
	scratch_count += len(text)
	return text
}

fail :: proc "contextless" (parts: ..system.Part) -> Value {
	if !failed {
		failed = true
		print("error: ")
		print(..parts)
		print("\n")
	}
	return {}
}

skip_spaces :: proc "contextless" () {
	for position < len(source) && source[position] == ' ' {
		position += 1
	}
}

peek :: proc "contextless" () -> u8 {
	skip_spaces()
	return position < len(source) ? source[position] : 0
}

accept :: proc "contextless" (character: u8) -> bool {
	if peek() == character {
		position += 1
		return true
	}
	return false
}

is_letter :: proc "contextless" (c: u8) -> bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_'
}

is_digit :: proc "contextless" (c: u8) -> bool {
	return c >= '0' && c <= '9'
}

read_name :: proc "contextless" () -> string {
	skip_spaces()
	start := position
	for position < len(source) && (is_letter(source[position]) || (is_digit(source[position]) || source[position] == '.') && position > start) {
		position += 1
	}
	return source[start:position]
}

run_line :: proc "contextless" (text: string) {
	source, position, failed, scratch_count = text, 0, false, 0

	// An assignment starts with a name and "=".
	name := read_name()
	if len(name) > 0 && accept('=') {
		value := expression()
		if !failed && peek() != 0 {
			fail("unexpected \"", source[position:], "\"")
		}
		if !failed {
			assign(name, value)
		}
		return
	}
	position = 0
	value := expression()
	if !failed && peek() != 0 {
		fail("unexpected \"", source[position:], "\"")
	}
	if failed {
		return
	}
	if value.kind != .None {
		print_value(value)
		print("\n")
	}
}

assign :: proc "contextless" (name: string, value: Value) {
	if value.kind == .None {
		fail("the expression has no value")
		return
	}
	if len(name) > VARIABLE_NAME_SIZE || len(value.text) > VARIABLE_TEXT_SIZE {
		fail("the name or the text is too long")
		return
	}
	slot: ^Variable
	for &variable in variables {
		if string(variable.name[:variable.name_count]) == name {
			slot = &variable
			break
		}
		if variable.name_count == 0 && slot == nil {
			slot = &variable
		}
	}
	if slot == nil {
		fail("no room for a variable")
		return
	}
	slot.name_count = copy(slot.name[:], name)
	slot.value = value
	#partial switch value.kind {
	case .Text:
		count := copy(slot.text[:], value.text)
		slot.value.text = string(slot.text[:count])
	case .Record:
		bytes := ([^]u8)(&slot.record)[:len(value.record)]
		copy(bytes, value.record)
		slot.value.record = bytes
	}
}

expression :: proc "contextless" () -> Value {
	left := term()
	for !failed {
		operator := peek()
		if operator != '+' && operator != '-' {
			break
		}
		position += 1
		right := term()
		if failed {
			break
		}
		switch {
		case left.kind == .Integer && right.kind == .Integer:
			left.integer = operator == '+' ? left.integer + right.integer : left.integer - right.integer
		case left.kind == .Text && right.kind == .Text && operator == '+':
			left.text = scratch_text(left.text, right.text)
		case:
			return fail("\"", string([]u8{operator}), "\" does not take ", kind_names[left.kind], " and ", kind_names[right.kind])
		}
	}
	return left
}

term :: proc "contextless" () -> Value {
	left := factor()
	for !failed {
		operator := peek()
		if operator != '*' && operator != '/' && operator != '%' {
			break
		}
		position += 1
		right := factor()
		if failed {
			break
		}
		if left.kind != .Integer || right.kind != .Integer {
			return fail("\"", string([]u8{operator}), "\" does not take ", kind_names[left.kind], " and ", kind_names[right.kind])
		}
		switch operator {
		case '*':
			left.integer *= right.integer
		case '/', '%':
			if right.integer == 0 {
				return fail("division by zero")
			}
			if operator == '/' {
				left.integer /= right.integer
			} else {
				left.integer %= right.integer
			}
		}
	}
	return left
}

factor :: proc "contextless" () -> Value {
	c := peek()
	switch {
	case c == '-':
		position += 1
		value := factor()
		if !failed && value.kind != .Integer {
			return fail("\"-\" does not take ", kind_names[value.kind])
		}
		value.integer = -value.integer
		return value
	case c == '(':
		position += 1
		value := expression()
		if !failed && !accept(')') {
			return fail("\")\" is missing")
		}
		return value
	case is_digit(c):
		value: i64
		for position < len(source) && is_digit(source[position]) {
			value = value * 10 + i64(source[position] - '0')
			position += 1
		}
		return {kind = .Integer, integer = value}
	case c == '"':
		position += 1
		start := position
		for position < len(source) && source[position] != '"' {
			position += 1
		}
		if position == len(source) {
			return fail("the text has no end quote")
		}
		position += 1
		return {kind = .Text, text = source[start:position - 1]}
	case is_letter(c):
		name := read_name()
		if accept('(') {
			return call(name)
		}
		for &variable in variables {
			if string(variable.name[:variable.name_count]) == name {
				return variable.value
			}
		}
		for &command in commands[:command_count] {
			if command.name == name {
				return fail(name, " is a command: write ", name, "(...)")
			}
		}
		// variable.field: one field of a Record.
		for split := len(name) - 1; split > 0; split -= 1 {
			if name[split] != '.' {
				continue
			}
			for &variable in variables {
				if string(variable.name[:variable.name_count]) == name[:split] && variable.value.kind == .Record {
					if value, found := field_value(variable.value, name[split + 1:]); found {
						return value
					}
					return fail(type_text(variable.value.file, .Record, variable.value.detail), " has no field ", name[split + 1:])
				}
			}
			break
		}
		return fail("no variable has the name ", name)
	case c == 0:
		return fail("the line ends too soon")
	}
	return fail("unexpected \"", source[position:], "\"")
}

// call reads the arguments of a command, checks their types against the
// parameters, and calls the function.
call :: proc "contextless" (name: string) -> Value {
	found: ^Command
	for &command in commands[:command_count] {
		if command.name == name {
			found = &command
		}
	}
	if found == nil {
		return fail("no command has the name ", name, "; try help()")
	}
	arguments: [ARGUMENT_CAPACITY]Value
	count := 0
	if !accept(')') {
		for {
			value := expression()
			if failed {
				return {}
			}
			if count == ARGUMENT_CAPACITY {
				return fail("too many arguments")
			}
			arguments[count] = value
			count += 1
			if accept(')') {
				break
			}
			if !accept(',') {
				return fail("\",\" or \")\" is missing")
			}
		}
	}
	if count != found.parameter_count {
		return fail(name, " takes ", i64(found.parameter_count), " arguments, not ", i64(count))
	}
	for kind, index in found.parameters[:count] {
		argument := &arguments[index]
		detail := found.function.parameter_details[index]
		// A Record agrees when the two descriptions are equal: a record of
		// one module is a record of another module with the same fields.
		if argument.kind != kind || kind == .Record && !module.records_equal(found.file, detail, argument.file, argument.detail) {
			return fail(name, ": argument ", i64(index + 1), " is ", type_text(found.file, kind, detail), ", not ", type_text(argument.file, argument.kind, argument.detail))
		}
		if kind == .Record {
			// A copy: the export can write in its record, and a call
			// writes the handles of the receiver in it.
			bytes := scratch_bytes(len(argument.record))
			if bytes == nil && len(argument.record) != 0 {
				return fail("the line has too many records")
			}
			copy(bytes, argument.record)
			argument.record = bytes
		}
	}
	if found.record != 0 {
		return record_build(found, arguments[:count])
	}
	if found.sandbox != 0 {
		return call_isolated(found, arguments[:count])
	}
	if found.address != 0 {
		return call_export(found, arguments[:count])
	}
	return found.run(arguments[:count])
}
