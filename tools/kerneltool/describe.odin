package kerneltool

import module "../../module"
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
	for path in files_with_suffix(folder, ".odin") or_return {
		if strings.has_suffix(path, "_test.odin") {
			continue
		}
		source := read_file(path) or_return
		text: string
		describe_source(path, string(source), &list, &text) or_return
		if description.text == "" {
			description.text = text
		}
	}
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

// describe_source adds the descriptions of the exports of one source file.
// package_text receives the documentation text of the package, if the file has one.
describe_source :: proc(path, source: string, list: ^[dynamic]Export_Description, package_text: ^string = nil) -> bool {
	context.allocator = context.temp_allocator
	fail :: proc(path: string, node: ^ast.Node, format: string, args: ..any) -> bool {
		fmt.eprintf("kerneltool: describe %s(%d): ", path, node.pos.line)
		fmt.eprintfln(format, ..args)
		return false
	}
	type_text :: proc(source: string, type: ^ast.Expr) -> string {
		return source[type.pos.offset:type.end.offset]
	}

	file := ast.new_from_positions(ast.File, {}, {})
	file.src = source
	file.fullpath = path
	reader := parser.default_parser()
	if !parser.parse_file(&reader, file) {
		fmt.eprintfln("kerneltool: describe %s: the parser found errors", path)
		return false
	}

	if package_text != nil {
		package_text^ = text_of(file.docs)
	}

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
			return fail(path, declaration, "%s is not a function: the exports of a module are functions only", name)
		}
		function, is_function := declaration.values[0].derived.(^ast.Proc_Lit)
		if !is_function {
			return fail(path, declaration, "%s is not a function: the exports of a module are functions only", name)
		}
		type := function.type
		convention, _ := type.calling_convention.(string)
		if strings.trim(convention, "\"") != "c" || type.generic {
			return fail(path, declaration, "%s must have the calling convention \"c\" and no generic parameter", name)
		}
		fields: []^ast.Field
		if type.params != nil {
			fields = type.params.list
		}
		result_text := ""
		if type.results != nil {
			if len(type.results.list) != 1 || len(type.results.list[0].names) > 1 || type.results.list[0].type == nil {
				return fail(path, declaration, "%s has more than one result", name)
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
				return fail(path, declaration, "the entry has one parameter, an address, and no result or an i64 result")
			}
			append(list, Export_Description{name = name})
			continue
		}

		if type.diverging {
			return fail(path, declaration, "%s does not return: only the entry can have the result !", name)
		}
		description := Export_Description {
			name = name,
		}
		parameters := make([dynamic]module.Type, context.temp_allocator)
		names := make([dynamic]string, context.temp_allocator)
		for field, index in fields {
			if field.type == nil || len(field.names) == 0 {
				return fail(path, field, "%s: each parameter has a name and a type", name)
			}
			kind: module.Type
			switch text := type_text(source, field.type); text {
			case "i64":
				kind = .Integer
			case "^string":
				kind = .Text
			case "^[]u8":
				if index != len(fields) - 1 || len(field.names) != 1 {
					return fail(path, field, "%s: the buffer of a Text result (^[]u8) is the last parameter", name)
				}
				description.result = .Text
				continue
			case:
				return fail(
					path,
					field,
					"%s: the type %s has no description. Use i64 (Integer), ^string (Text), or a last parameter ^[]u8 (the buffer of a Text result)",
					name,
					text,
				)
			}
			for expression in field.names {
				parameter, is_identifier := expression.derived.(^ast.Ident)
				if !is_identifier || parameter.name == "_" || len(parameter.name) > 255 {
					return fail(path, field, "%s: each parameter has a name", name)
				}
				append(&parameters, kind)
				append(&names, parameter.name)
			}
		}
		switch {
		case result_text == "i64":
			if description.result != .Text {
				description.result = .Integer
			}
		case result_text != "":
			return fail(path, declaration, "%s: the result type %s has no description. Use i64", name, result_text)
		case description.result == .Text:
			return fail(path, declaration, "%s: a Text result gives its count of bytes: the result type is i64", name)
		}
		if len(parameters) + int(description.result == .Text) > module.PARAMETER_CAPACITY {
			return fail(path, declaration, "%s has more than %d parameters", name, module.PARAMETER_CAPACITY)
		}
		description.parameters = parameters[:]
		description.names = names[:]
		description.text = text_of(declaration.docs)
		description.about = about_of(description.text, name)
		if description.about == "" {
			return fail(path, declaration, "%s has no comment: the first sentence of the comment is the help of the export", name)
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
