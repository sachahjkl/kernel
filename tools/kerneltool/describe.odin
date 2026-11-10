package kerneltool

import module "contract:module"
import op "contract:operation"
import "core:reflect"
import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:strings"

// The descriptions of the exports of a module come from its source
// (property 19, docs/MODULE_CONTRACT.md section 4). This file reads an Odin
// package. An export is a procedure with the attribute @(export).
//
// The rules, which the tool checks:
//   - An export is a function, with the calling convention "c".
//   - A parameter of type i64 is an Integer. A parameter of type ^string is
//     a Text.
//   - A result of type i64 is an Integer. If the last parameter has the type
//     ^[]u8, it is the buffer of a Text result, and the result type is i64.
//   - A parameter of type ^Name is a Record, if Name is a struct of the
//     package. A field of the struct has the type i64 (Integer) or
//     Lent({...}) (Handle). The struct has the layout of the C language:
//     no #packed, no #align, no `using`. Its size is at most
//     module.RECORD_SIZE_LIMIT bytes.
//   - If the last parameter has a type ^Name and the name `result`, it is
//     the memory of a Record result. The export has no result type, and
//     the record has no Handle.
//   - A parameter of type Lent({.Read, .Write}) is a Handle that the caller
//     lends, with the rights that the callee needs (support/system).
//   - Each parameter has a name.
//   - The comment before the export gives the line of help: its first
//     sentence, without the name of the export.
//   - The export "entry" has one parameter, an address. Its form is fixed by
//     the contract, and its description has no parameter.
// Another type is an error: the tool does not guess a description.

ENTRY_NAME :: "entry"

// describe_package gives the description of the Odin package in a folder:
// the documentation of the module, and the descriptions of its exports. The
// files are in the order of their names, the exports of a file in the order
// of the source. Export n + 1 of the module is exports[n].
// The documentation of the module is the comment before the word `package`,
// in the first file that has one.
describe_package :: proc(folder: string) -> (description: Module_Description, ok: bool) {
	list := make([dynamic]Export_Description, context.temp_allocator)
	state: Describe_State
	state.records = make([dynamic]Record_Description, context.temp_allocator)
	state.structs = make(map[string]Struct_Source, context.temp_allocator)
	files := make([dynamic]^ast.File, context.temp_allocator)
	// The structs of all the files first: an export of one file can use a
	// struct of another file.
	for path in files_with_suffix(folder, ".odin") or_return {
		if strings.has_suffix(path, "_test.odin") {
			continue
		}
		source := read_file(path) or_return
		file := parse_source(path, string(source), &state) or_return
		append(&files, file)
		if text := text_of(file.docs); description.text == "" {
			description.text = text
		}
	}
	for file in files {
		describe_file(file, &list, &state) or_return
	}
	description.records = state.records[:]
	for item, index in list {
		for other in list[:index] {
			if other.name == item.name {
				fmt.eprintfln("kerneltool: describe %s: two exports have the name %s", folder, item.name)
				return {}, false
			}
		}
	}
	description.about = about_of(description.text, "")
	if description.about == "" {
		fmt.eprintfln("kerneltool: describe %s: no file has a comment before `package`: this comment is the documentation of the module", folder)
		return {}, false
	}
	description.exports = list[:]
	return description, true
}

// A struct of the package, as the source declares it.
Struct_Source :: struct {
	type:   ^ast.Struct_Type,
	path:   string,
	source: string,
}

// What the tool keeps while it reads a package.
Describe_State :: struct {
	structs: map[string]Struct_Source,
	records: [dynamic]Record_Description, // The records that an export uses, each one time.
}

@(private = "file")
describe_fail :: proc(path: string, node: ^ast.Node, format: string, args: ..any) -> bool {
	fmt.eprintf("kerneltool: describe %s(%d): ", path, node.pos.line)
	fmt.eprintfln(format, ..args)
	return false
}

@(private = "file")
type_text :: proc(source: string, type: ^ast.Expr) -> string {
	return source[type.pos.offset:type.end.offset]
}

// parse_source reads one source file, and keeps its structs.
parse_source :: proc(path, source: string, state: ^Describe_State) -> (file: ^ast.File, ok: bool) {
	context.allocator = context.temp_allocator
	file = ast.new_from_positions(ast.File, {}, {})
	file.src = source
	file.fullpath = path
	reader := parser.default_parser()
	if !parser.parse_file(&reader, file) {
		fmt.eprintfln("kerneltool: describe %s: the parser found errors", path)
		return nil, false
	}
	for statement in file.decls {
		declaration, is_value := statement.derived.(^ast.Value_Decl)
		if !is_value || len(declaration.names) != 1 || len(declaration.values) != 1 {
			continue
		}
		identifier, has_name := declaration.names[0].derived.(^ast.Ident)
		type, is_struct := declaration.values[0].derived.(^ast.Struct_Type)
		if has_name && is_struct {
			state.structs[identifier.name] = {type, path, source}
		}
	}
	return file, true
}

// lent_rights reads a type Lent({.Read, .Write}): the rights that the
// callee needs of a handle. is_lent is false for another type.
lent_rights :: proc(type: ^ast.Expr) -> (rights: op.Rights, is_lent, ok: bool) {
	call, is_call := type.derived.(^ast.Call_Expr)
	if !is_call {
		return {}, false, false
	}
	name: string
	#partial switch callee in call.expr.derived {
	case ^ast.Ident:
		name = callee.name
	case ^ast.Selector_Expr:
		name = callee.field.name
	}
	if name != "Lent" {
		return {}, false, false
	}
	if len(call.args) != 1 {
		return {}, true, false
	}
	literal, is_literal := call.args[0].derived.(^ast.Comp_Lit)
	if !is_literal {
		return {}, true, false
	}
	for element in literal.elems {
		selector, is_selector := element.derived.(^ast.Implicit_Selector_Expr)
		if !is_selector {
			return {}, true, false
		}
		right, known := reflect.enum_from_name(op.Right, selector.field.name)
		if !known {
			return {}, true, false
		}
		rights += {right}
	}
	return rights, true, true
}

// record_of gives the number of the description of a struct, from 1. The
// description is made at the first use of the struct. 0: the type is not
// a pointer to a struct of the package.
record_of :: proc(state: ^Describe_State, type: ^ast.Expr, result: bool) -> (number: u32, is_record, ok: bool) {
	pointer, is_pointer := type.derived.(^ast.Pointer_Type)
	if !is_pointer {
		return 0, false, false
	}
	identifier, is_name := pointer.elem.derived.(^ast.Ident)
	if !is_name {
		return 0, false, false
	}
	found, has_struct := state.structs[identifier.name]
	if !has_struct {
		return 0, false, false
	}
	declared := found.type
	if declared.is_packed || declared.is_raw_union || declared.align != nil || declared.poly_params != nil || declared.fields == nil || len(declared.fields.list) == 0 {
		return 0, true, describe_fail(found.path, declared, "the record %s must have fields, and the layout of the C language: no #packed, no #align, no parameter", identifier.name)
	}
	fields := make([dynamic]Field_Description, context.temp_allocator)
	size, alignment: u32 = 0, 1
	has_handle := false
	for field in declared.fields.list {
		if field.type == nil || .Using in field.flags {
			return 0, true, describe_fail(found.path, field, "the record %s: each field has a type, and no `using`", identifier.name)
		}
		item: Field_Description
		field_size: u32
		if rights, is_lent, lent_ok := lent_rights(field.type); is_lent {
			if !lent_ok {
				return 0, true, describe_fail(found.path, field, "the record %s: write the rights of a handle as Lent({{.Read, .Write}})", identifier.name)
			}
			item, field_size, has_handle = {type = .Handle, detail = transmute(u32)rights}, 4, true
		} else if type_text(found.source, field.type) == "i64" {
			item, field_size = {type = .Integer}, 8
		} else {
			return 0, true, describe_fail(found.path, field, "the record %s: the type %s has no description. A field is an i64 (Integer) or a Lent({{...}}) (Handle)", identifier.name, type_text(found.source, field.type))
		}
		alignment = max(alignment, field_size)
		for expression in field.names {
			name, is_identifier := expression.derived.(^ast.Ident)
			if !is_identifier || name.name == "_" {
				return 0, true, describe_fail(found.path, field, "the record %s: each field has a name", identifier.name)
			}
			size = (size + field_size - 1) / field_size * field_size
			item.name, item.offset = name.name, size
			append(&fields, item)
			size += field_size
		}
	}
	size = (size + alignment - 1) / alignment * alignment
	if size > module.RECORD_SIZE_LIMIT {
		return 0, true, describe_fail(found.path, declared, "the record %s has %d bytes: the limit is %d", identifier.name, size, module.RECORD_SIZE_LIMIT)
	}
	if result && has_handle {
		return 0, true, describe_fail(found.path, declared, "the record %s is a result: a result has no handle", identifier.name)
	}
	for item, index in state.records {
		if item.name == identifier.name {
			return u32(index + 1), true, true
		}
	}
	append(&state.records, Record_Description{name = identifier.name, size = size, fields = fields[:]})
	return u32(len(state.records)), true, true
}

// describe_source adds the descriptions of the exports of one source file.
// package_text receives the documentation text of the package, if the file
// has one. records receives the records that the exports use.
describe_source :: proc(path, source: string, list: ^[dynamic]Export_Description, package_text: ^string = nil, records: ^[]Record_Description = nil) -> bool {
	context.allocator = context.temp_allocator
	state: Describe_State
	state.records = make([dynamic]Record_Description, context.temp_allocator)
	state.structs = make(map[string]Struct_Source, context.temp_allocator)
	file := parse_source(path, source, &state) or_return
	if package_text != nil {
		package_text^ = text_of(file.docs)
	}
	describe_file(file, list, &state) or_return
	if records != nil {
		records^ = state.records[:]
	}
	return true
}

// describe_file adds the descriptions of the exports of one parsed file.
describe_file :: proc(file: ^ast.File, list: ^[dynamic]Export_Description, state: ^Describe_State) -> bool {
	context.allocator = context.temp_allocator
	path, source := file.fullpath, file.src

	for statement in file.decls {
		declaration, is_value := statement.derived.(^ast.Value_Decl)
		if !is_value || len(declaration.names) != 1 {
			continue
		}
		identifier, has_name := declaration.names[0].derived.(^ast.Ident)
		if !has_name {
			continue
		}
		name := identifier.name
		exported := false
		for attribute in declaration.attributes {
			for element in attribute.elems {
				#partial switch item in element.derived {
				case ^ast.Ident:
					exported |= item.name == "export"
				case ^ast.Field_Value:
					field, is_field := item.field.derived.(^ast.Ident)
					literal, is_literal := item.value.derived.(^ast.Basic_Lit)
					if is_field && is_literal && field.name == "link_name" {
						name = strings.trim(literal.tok.text, "\"`")
					}
				}
			}
		}
		if !exported {
			continue
		}
		if len(declaration.values) != 1 {
			return describe_fail(path, declaration, "%s is not a function: the exports of a module are functions only", name)
		}
		function, is_function := declaration.values[0].derived.(^ast.Proc_Lit)
		if !is_function {
			return describe_fail(path, declaration, "%s is not a function: the exports of a module are functions only", name)
		}
		type := function.type
		convention, _ := type.calling_convention.(string)
		if strings.trim(convention, "\"") != "c" || type.generic {
			return describe_fail(path, declaration, "%s must have the calling convention \"c\" and no generic parameter", name)
		}
		fields: []^ast.Field
		if type.params != nil {
			fields = type.params.list
		}
		result_text := ""
		if type.results != nil {
			if len(type.results.list) != 1 || len(type.results.list[0].names) > 1 || type.results.list[0].type == nil {
				return describe_fail(path, declaration, "%s has more than one result", name)
			}
			result_text = type_text(source, type.results.list[0].type)
		}

		if name == ENTRY_NAME {
			address := len(fields) == 1 && len(fields[0].names) == 1 && fields[0].type != nil
			if address {
				text := type_text(source, fields[0].type)
				address = text == "rawptr" || strings.has_prefix(text, "^")
			}
			if !address || result_text != "" && result_text != "i64" {
				return describe_fail(path, declaration, "the entry has one parameter, an address, and no result or an i64 result")
			}
			append(list, Export_Description{name = name})
			continue
		}

		if type.diverging {
			return describe_fail(path, declaration, "%s does not return: only the entry can have the result !", name)
		}
		description := Export_Description {
			name = name,
		}
		parameters := make([dynamic]module.Type, context.temp_allocator)
		names := make([dynamic]string, context.temp_allocator)
		details := make([dynamic]u32, context.temp_allocator)
		for field, index in fields {
			if field.type == nil || len(field.names) == 0 {
				return describe_fail(path, field, "%s: each parameter has a name and a type", name)
			}
			kind: module.Type
			detail: u32
			last := index == len(fields) - 1 && len(field.names) == 1
			first_name, _ := field.names[0].derived.(^ast.Ident)
			is_result := last && first_name != nil && first_name.name == "result"
			switch text := type_text(source, field.type); text {
			case "i64":
				kind = .Integer
			case "^string":
				kind = .Text
			case "^[]u8":
				if !last {
					return describe_fail(path, field, "%s: the buffer of a Text result (^[]u8) is the last parameter", name)
				}
				description.result = .Text
				continue
			case:
				if rights, is_lent, lent_ok := lent_rights(field.type); is_lent {
					if !lent_ok {
						return describe_fail(path, field, "%s: write the rights of a handle as Lent({{.Read, .Write}})", name)
					}
					kind, detail = .Handle, transmute(u32)rights
					break
				}
				if number, is_record, record_ok := record_of(state, field.type, is_result); is_record {
					if !record_ok {
						return false
					}
					if is_result {
						description.result, description.result_detail = .Record, number
						continue
					}
					kind, detail = .Record, number
					break
				}
				return describe_fail(
					path,
					field,
					"%s: the type %s has no description. Use i64 (Integer), ^string (Text), Lent({{...}}) (Handle), the address of a struct of the package (Record), or a last parameter ^[]u8 (the buffer of a Text result)",
					name,
					text,
				)
			}
			for expression in field.names {
				parameter, is_identifier := expression.derived.(^ast.Ident)
				if !is_identifier || parameter.name == "_" || len(parameter.name) > 255 {
					return describe_fail(path, field, "%s: each parameter has a name", name)
				}
				append(&parameters, kind)
				append(&names, parameter.name)
				append(&details, detail)
			}
		}
		switch {
		case description.result == .Record:
			if result_text != "" {
				return describe_fail(path, declaration, "%s: the callee writes a Record result in the memory of the caller: the export has no result type", name)
			}
		case result_text == "i64":
			if description.result != .Text {
				description.result = .Integer
			}
		case result_text != "":
			return describe_fail(path, declaration, "%s: the result type %s has no description. Use i64", name, result_text)
		case description.result == .Text:
			return describe_fail(path, declaration, "%s: a Text result gives its count of bytes: the result type is i64", name)
		}
		if len(parameters) + int(description.result == .Text || description.result == .Record) > module.PARAMETER_CAPACITY {
			return describe_fail(path, declaration, "%s has more than %d parameters", name, module.PARAMETER_CAPACITY)
		}
		description.parameters = parameters[:]
		description.names = names[:]
		description.details = details[:]
		handles := 0
		for kind, index in parameters {
			#partial switch kind {
			case .Handle:
				handles += 1
			case .Record:
				for item in state.records[details[index] - 1].fields {
					handles += int(item.type == .Handle)
				}
			}
		}
		if handles > module.HANDLE_CAPACITY {
			return describe_fail(path, declaration, "%s: a call lends at most %d handles; this export takes %d", name, module.HANDLE_CAPACITY, handles)
		}
		description.text = text_of(declaration.docs)
		description.about = about_of(description.text, name)
		if description.about == "" {
			return describe_fail(path, declaration, "%s has no comment: the first sentence of the comment is the help of the export", name)
		}
		append(list, description)
	}
	return true
}

// text_of gives the documentation text of a comment (module.Documentation
// says the form). Lines of the source that follow each other are one
// paragraph: one line of the text. A line of the source that starts with
// more than one space stays as it is. A line that starts with "- " starts a
// new paragraph.
text_of :: proc(docs: ^ast.Comment_Group) -> string {
	if docs == nil {
		return ""
	}
	lines := make([dynamic]string, context.temp_allocator)
	open := false // The last line is a paragraph that the next line can continue.
	for token in docs.list {
		if !strings.has_prefix(token.text, "//") {
			continue
		}
		line := strings.trim_right_space(token.text[2:])
		line = strings.trim_prefix(line, " ")
		line, _ = strings.replace_all(line, "\t", "    ", context.temp_allocator)
		switch {
		case line == "":
			if len(lines) > 0 && lines[len(lines) - 1] != "" {
				append(&lines, "")
			}
			open = false
		case line[0] == ' ':
			append(&lines, line)
			open = false
		case open && !strings.has_prefix(line, "- "):
			lines[len(lines) - 1] = strings.concatenate({lines[len(lines) - 1], " ", line}, context.temp_allocator)
		case:
			append(&lines, line)
			open = true
		}
	}
	for len(lines) > 0 && lines[len(lines) - 1] == "" {
		pop(&lines)
	}
	return strings.join(lines[:], "\n", context.temp_allocator)
}

// about_of gives the first sentence of a documentation text, without the
// name of the export at its start and without the period at its end.
about_of :: proc(documentation: string, name: string) -> string {
	text := documentation
	if end := strings.index_byte(text, '\n'); end >= 0 {
		text = text[:end]
	}
	if end := strings.index(text, ". "); end >= 0 {
		text = text[:end]
	}
	text = strings.trim_suffix(text, ".")
	if name != "" && strings.has_prefix(text, name) && len(text) > len(name) && text[len(name)] == ' ' {
		text = text[len(name) + 1:]
	}
	return strings.trim_space(text)
}
