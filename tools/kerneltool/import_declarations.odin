package kerneltool

import module "contract:module"
import "core:fmt"
import "core:odin/ast"
import "core:os"
import "core:slice"
import "core:strings"

// The check of the declarations of an importer (docs/MODULE_CONTRACT.md,
// "The declaration of an import is checked").
//
// A source names an export of an import in a `foreign` block: the
// compiler makes a call to a symbol with no definition, and trusts the
// types of the declaration. The linked file holds the name of the symbol
// and no type. So a declaration with one parameter too few, or with an
// integer where the export takes a table, builds with no error, and the
// call passes wrong registers.
//
// The conversion is the one step that reads both sides: the sources of the
// importer (the list that the compiler wrote) and the module file of each
// import, which holds the description of each export. This file reads each
// `foreign` procedure of those sources, also inside a `when`, with the
// rules that read the description of an export (describe.odin), and
// compares the two call forms: the count of the parameters, the type of
// each, the direction of each table, the rights of each handle, the layout
// of each record, the result, and the error record. The names of the
// parameters, of the records and of their fields are for a reader: they
// can differ. A `foreign` procedure that no import exports is a procedure
// of an assembly file of the module: it is not compared.
//
// The check is closed from the side of the linked file: each symbol that
// became a slot of the importer has a compared declaration
// (declared_symbols_problem). So a declaration that this file does not
// find stops the build, and does not pass unread.

// One parameter of a call form.
Call_Parameter :: struct {
	kind:      module.Type,
	direction: module.Direction, // A Table or Bytes.
	rights:    u32, // A Handle: the rights that the callee needs.
	record:    Record_Description, // A Record or a Table: the layout of its record.
}

// The call form of an export: what each register holds, as a declaration
// or a description states it.
Call_Form :: struct {
	parameters:    []Call_Parameter,
	result:        module.Type,
	result_record: Record_Description, // A Record or Table result.
	has_error:     bool, // The last argument is the address of an error record.
	error_record:  Record_Description,
}

// One procedure of a `foreign` block of a source.
Foreign_Declaration :: struct {
	link_name:          string, // The symbol: the attribute link_name, else the name after the link_prefix of its block. "": the source does not give it as a text.
	type:               ^ast.Proc_Type,
	line:               int,
	convention_problem: string, // "": the calling convention is "c". Else what the declaration has.
}

// attribute_text reads the value of an attribute `name = value` of a
// declaration or of a block. present: the attribute is there. is_text: its
// value is a text in the source, given with no quotes; a constant or
// another expression is not read.
@(private = "file")
attribute_text :: proc(attributes: []^ast.Attribute, name: string) -> (text: string, present: bool, is_text: bool) {
	for attribute in attributes {
		for element in attribute.elems {
			item, is_field_value := element.derived.(^ast.Field_Value)
			if !is_field_value {
				continue
			}
			field, is_field := item.field.derived.(^ast.Ident)
			if !is_field || field.name != name {
				continue
			}
			literal, is_literal := item.value.derived.(^ast.Basic_Lit)
			if !is_literal {
				return "", true, false
			}
			return strings.trim(literal.tok.text, "\"`"), true, true
		}
	}
	return "", false, false
}

// foreign_declarations_collect adds each procedure of each `foreign` block
// of a list of statements, also those of a block inside a `when`: a
// program can declare an import for one build setting only. A block in
// the body of a procedure is not read: the check of the slots
// (declared_symbols_problem) then finds a symbol with no declaration.
foreign_declarations_collect :: proc(statements: []^ast.Stmt, list: ^[dynamic]Foreign_Declaration) {
	for statement in statements {
		if statement == nil {
			continue
		}
		#partial switch node in statement.derived {
		case ^ast.When_Stmt:
			foreign_declarations_of_body(node.body, list)
			foreign_declarations_of_body(node.else_stmt, list)
		case ^ast.Foreign_Block_Decl:
			if node.body == nil {
				continue
			}
			block, is_block := node.body.derived.(^ast.Block_Stmt)
			if !is_block {
				continue
			}
			for inner in block.stmts {
				declaration, is_value := inner.derived.(^ast.Value_Decl)
				if !is_value || len(declaration.names) != 1 || len(declaration.values) != 1 {
					continue
				}
				identifier, has_name := declaration.names[0].derived.(^ast.Ident)
				if !has_name {
					continue
				}
				type: ^ast.Proc_Type
				#partial switch value in declaration.values[0].derived {
				case ^ast.Proc_Lit:
					type = value.type
				case ^ast.Proc_Type:
					type = value
				}
				if type == nil {
					continue
				}
				// The symbol: the text of link_name; else the name, after the
				// text of the link_prefix of the block. A name that is not a
				// text in the source (a constant) is not known here: the
				// declaration then matches no export, and the check of the
				// slots names the symbol that has no declaration.
				link_name := identifier.name
				if prefix, has_prefix, prefix_is_text := attribute_text(node.attributes[:], "link_prefix"); has_prefix {
					link_name = prefix_is_text ? strings.concatenate({prefix, identifier.name}, context.temp_allocator) : ""
				}
				if name, has_name_attribute, name_is_text := attribute_text(declaration.attributes[:], "link_name"); has_name_attribute {
					link_name = name_is_text ? name : ""
				}
				// The calling convention: a call form is the registers of the
				// convention "c". Another convention passes one more argument
				// (the context), with the same parameters in the source.
				convention := ""
				if written, is_written := type.calling_convention.(string); is_written {
					if strings.trim(written, "\"`") != "c" {
						convention = strings.concatenate({"it has the calling convention ", written}, context.temp_allocator)
					}
				} else if default_convention, has_default, default_is_text := attribute_text(node.attributes[:], "default_calling_convention"); has_default && (!default_is_text || default_convention != "c") {
					convention = "its block has a default calling convention that is not \"c\""
				}
				append(list, Foreign_Declaration{link_name = link_name, type = type, line = declaration.pos.line, convention_problem = convention})
			}
		}
	}
}

// foreign_declarations_of_body reads the body of a `when`: a block, or
// the `when` of an `else when`.
@(private = "file")
foreign_declarations_of_body :: proc(body: ^ast.Stmt, list: ^[dynamic]Foreign_Declaration) {
	if body == nil {
		return
	}
	#partial switch node in body.derived {
	case ^ast.Block_Stmt:
		foreign_declarations_collect(node.stmts, list)
	case ^ast.When_Stmt:
		one := [1]^ast.Stmt{body}
		foreign_declarations_collect(one[:], list)
	}
}

// call_form_of_declaration reads the call form of a declared procedure,
// with the rules of the description of an export (the comment at the top
// of describe.odin). state holds the structs of the package of the
// declaration. ok is false, with a sentence, for a type that has no
// description.
call_form_of_declaration :: proc(state: ^Describe_State, source: string, type: ^ast.Proc_Type) -> (form: Call_Form, problem: string, ok: bool) {
	context.allocator = context.temp_allocator
	fields: []^ast.Field
	if type.params != nil {
		fields = type.params.list
	}
	record_at :: proc(state: ^Describe_State, number: u32) -> Record_Description {
		if number == 0 || int(number) > len(state.records) {
			return {}
		}
		return state.records[number - 1]
	}
	// An error record: the last parameter, with the name `error`.
	if count := len(fields); count > 0 && len(fields[count - 1].names) == 1 && fields[count - 1].type != nil {
		last, _ := fields[count - 1].names[0].derived.(^ast.Ident)
		if last != nil && last.name == "error" {
			number, is_record, record_ok := record_of(state, fields[count - 1].type, true)
			if !is_record || !record_ok {
				return {}, "the parameter error is not the address of a record that the tool can read", false
			}
			form.has_error, form.error_record = true, record_at(state, number)
			fields = fields[:count - 1]
		}
	}
	parameters := make([dynamic]Call_Parameter, context.temp_allocator)
	for field, index in fields {
		if field.type == nil || len(field.names) == 0 {
			return {}, "a parameter has no name or no type", false
		}
		parameter: Call_Parameter
		last := index == len(fields) - 1 && len(field.names) == 1
		first_name, _ := field.names[0].derived.(^ast.Ident)
		is_result := last && first_name != nil && first_name.name == "result"
		text := source[field.type.pos.offset:field.type.end.offset]
		switch text {
		case "i64":
			parameter.kind = .Integer
		case "^string":
			parameter.kind = .Text
		case "^[]u8":
			if !last {
				return {}, "the buffer of a Text result (^[]u8) is not the last parameter", false
			}
			form.result = .Text
			continue
		case:
			if rights, is_lent, lent_ok := lent_rights(field.type); is_lent {
				if !lent_ok {
					return {}, "the rights of a handle are not written as Lent({.Read, .Write})", false
				}
				parameter.kind, parameter.rights = .Handle, transmute(u32)rights
				break
			}
			if table_kind, number, table_direction, is_parameter, parameter_ok := table_parameter(state, field.type); is_parameter {
				if !parameter_ok {
					return {}, fmt.tprintf("the tool cannot read the record of the table parameter %s", text), false
				}
				parameter.kind, parameter.direction, parameter.record = table_kind, table_direction, record_at(state, number)
				break
			}
			if number, is_table, table_ok := table_of(state, field.type); is_table {
				if !table_ok || !is_result {
					return {}, fmt.tprintf("the buffer of a Table result (%s) is the last parameter, with the name result, and a record that the tool can read", text), false
				}
				form.result, form.result_record = .Table, record_at(state, number)
				continue
			}
			if number, is_record, record_ok := record_of(state, field.type, is_result); is_record {
				if !record_ok {
					return {}, fmt.tprintf("the tool cannot read the record %s", text), false
				}
				if is_result {
					form.result, form.result_record = .Record, record_at(state, number)
					continue
				}
				parameter.kind, parameter.record = .Record, record_at(state, number)
				break
			}
			// The usual cause is a name for a type of the contract. The tool
			// follows no alias: that needs the constants of each package,
			// which is the work of the compiler. The declaration is where a
			// reader finds the call form, so the type is written there.
			return {}, fmt.tprintf("the type %s has no description. The tool does not read a type alias: write the type itself in the declaration, as ^system.Table_To_Append(Record), ^system.Bytes_To_Read, ^string or i64", text), false
		}
		for _ in field.names {
			append(&parameters, parameter)
		}
	}
	if type.results != nil && len(type.results.list) == 1 && type.results.list[0].type != nil {
		result_type := type.results.list[0].type
		result_text := source[result_type.pos.offset:result_type.end.offset]
		if result_text != "i64" {
			return {}, fmt.tprintf("the result type %s has no description", result_text), false
		}
		if form.result == .None {
			form.result = .Integer
		}
	} else if type.results != nil {
		return {}, "the declaration has more than one result", false
	}
	form.parameters = parameters[:]
	return form, "", true
}

// call_form_of_description gives the call form of an export as the tool
// described it from the source of its module.
call_form_of_description :: proc(description: Export_Description, records: []Record_Description) -> (form: Call_Form) {
	record_at :: proc(records: []Record_Description, number: u32) -> Record_Description {
		if number == 0 || int(number) > len(records) {
			return {}
		}
		return records[number - 1]
	}
	parameters := make([]Call_Parameter, len(description.parameters), context.temp_allocator)
	for kind, index in description.parameters {
		parameters[index] = {kind = kind, direction = description.directions[index]}
		#partial switch kind {
		case .Handle:
			parameters[index].rights = description.details[index]
		case .Record, .Table:
			parameters[index].record = record_at(records, description.details[index])
		}
	}
	form.parameters = parameters
	form.result = description.result
	if description.result == .Record || description.result == .Table {
		form.result_record = record_at(records, description.result_detail)
	}
	if description.error_record != 0 {
		form.has_error, form.error_record = true, record_at(records, description.error_record)
	}
	return form
}

// record_description_of_file reads the description of record `number` of
// a module file. ok is false for a number that the file does not have.
@(private = "file")
record_description_of_file :: proc(file: []u8, number: u32) -> (description: Record_Description, ok: bool) {
	record := module.record_type(file, number) or_return
	fields := make([]Field_Description, int(record.field_count), context.temp_allocator)
	for &item, index in fields {
		stored := module.field(file, record, u32(index)) or_return
		item = {name = module.string_at(file, stored.name_offset, stored.name_count), offset = stored.offset, type = stored.type, detail = stored.detail, unsigned = stored.unsigned}
	}
	return {name = module.string_at(file, record.name_offset, record.name_count), size = record.size, fields = fields}, true
}

// call_form_of_export reads the call form of export `export_index` of a
// module file: the description that the loader, the console and a call
// host read. ok is false for a file whose tables do not hold it.
call_form_of_export :: proc(file: []u8, export_index: u32) -> (form: Call_Form, ok: bool) {
	function := module.function(file, export_index) or_return
	if int(function.parameter_count) > len(function.parameters) {
		return {}, false
	}
	parameters := make([]Call_Parameter, int(function.parameter_count), context.temp_allocator)
	for &parameter, index in parameters {
		parameter = {kind = function.parameters[index], direction = function.parameter_directions[index]}
		#partial switch parameter.kind {
		case .Handle:
			parameter.rights = function.parameter_details[index]
		case .Record, .Table:
			parameter.record = record_description_of_file(file, function.parameter_details[index]) or_return
		}
	}
	form.parameters = parameters
	form.result = function.result
	if function.result == .Record || function.result == .Table {
		form.result_record = record_description_of_file(file, function.result_detail) or_return
	}
	if function.error_record != 0 {
		form.has_error = true
		form.error_record = record_description_of_file(file, function.error_record) or_return
	}
	return form, true
}

// record_layouts_difference says how two records differ in what a call
// depends on: the size, and the offset, the type and the size of each
// field. "" when they are the same. The names are not compared.
@(private = "file")
record_layouts_difference :: proc(declared, described: Record_Description) -> string {
	if declared.size != described.size {
		return fmt.tprintf("the record %s has %d bytes, the export has %s of %d bytes", declared.name, declared.size, described.name, described.size)
	}
	if len(declared.fields) != len(described.fields) {
		return fmt.tprintf("the record %s has %d fields, the export has %s of %d fields", declared.name, len(declared.fields), described.name, len(described.fields))
	}
	for field, index in declared.fields {
		other := described.fields[index]
		if field.offset != other.offset || field.type != other.type || field.detail != other.detail || field.unsigned != other.unsigned {
			return fmt.tprintf("the field %s of the record %s is not the field %s of %s: another offset, type, size or sign", field.name, declared.name, other.name, described.name)
		}
	}
	return ""
}

// call_forms_difference says how the call form of a declaration differs
// from the call form of the export that it names. "" when a call through
// the declaration passes what the export reads.
call_forms_difference :: proc(declared, described: Call_Form) -> string {
	type_names := [module.Type]string {
		.None    = "None",
		.Integer = "Integer",
		.Text    = "Text",
		.Record  = "Record",
		.Handle  = "Handle",
		.Table   = "Table",
		.Bytes   = "Bytes",
	}
	direction_names := [module.Direction]string {
		.Read   = "Read",
		.Change = "Change",
		.Append = "Append",
	}
	if len(declared.parameters) != len(described.parameters) {
		return fmt.tprintf("it has %d parameters, the export has %d", len(declared.parameters), len(described.parameters))
	}
	for parameter, index in declared.parameters {
		other := described.parameters[index]
		if parameter.kind != other.kind {
			return fmt.tprintf("its parameter %d is %s, the export has %s", index + 1, type_names[parameter.kind], type_names[other.kind])
		}
		if parameter.direction != other.direction {
			return fmt.tprintf("its parameter %d has the direction %s, the export has %s", index + 1, direction_names[parameter.direction], direction_names[other.direction])
		}
		if parameter.kind == .Handle && parameter.rights != other.rights {
			return fmt.tprintf("its parameter %d is a handle with other rights than the export needs", index + 1)
		}
		if parameter.kind == .Record || parameter.kind == .Table {
			if difference := record_layouts_difference(parameter.record, other.record); difference != "" {
				return fmt.tprintf("its parameter %d: %s", index + 1, difference)
			}
		}
	}
	if declared.result != described.result {
		return fmt.tprintf("its result is %s, the export has %s", type_names[declared.result], type_names[described.result])
	}
	if declared.result == .Record || declared.result == .Table {
		if difference := record_layouts_difference(declared.result_record, described.result_record); difference != "" {
			return fmt.tprintf("its result: %s", difference)
		}
	}
	if declared.has_error != described.has_error {
		return declared.has_error ? "it has an error record, the export has none" : "it has no error record, the export has one"
	}
	if declared.has_error {
		if difference := record_layouts_difference(declared.error_record, described.error_record); difference != "" {
			return fmt.tprintf("its error record: %s", difference)
		}
	}
	return ""
}

// package_state_of_file parses each source of the folder of a file, so
// that a declaration of the file can name a struct of another file of its
// package, and gives the parsed file. Test files are left out, as in the
// description of a module.
package_state_of_file :: proc(path: string, state: ^Describe_State) -> (target: ^ast.File, ok: bool) {
	state.records = make([dynamic]Record_Description, context.temp_allocator)
	state.structs = make(map[string]Struct_Source, context.temp_allocator)
	file_name := path[strings.last_index_byte(path, '/') + 1:]
	for other in files_with_suffix(folder_of_path(path), ".odin") or_return {
		if strings.has_suffix(other, "_test.odin") {
			continue
		}
		source := read_file(other) or_return
		parsed := parse_source(other, string(source), state) or_return
		if other[strings.last_index_byte(other, '/') + 1:] == file_name {
			target = parsed
		}
	}
	if target == nil {
		fmt.eprintfln("kerneltool: the source %s is not in its folder", path)
		return nil, false
	}
	return target, true
}

// A described export that a declaration can name: its name and its call
// form, and the module that exports it.
Importable_Export :: struct {
	module_name: string,
	name:        string,
	form:        Call_Form,
}

// import_declarations_of_file_agree compares each `foreign` procedure of
// one source with the export of that name, if one of `exports` has it. It
// prints each difference, and gives the count of the declarations that it
// compared. compared_names receives the symbol of each compared
// declaration, for the check of the slots (declared_symbols_problem).
import_declarations_of_file_agree :: proc(importer: string, path: string, exports: []Importable_Export, compared_names: ^[dynamic]string = nil) -> (compared: int, ok: bool) {
	state: Describe_State
	target := package_state_of_file(path, &state) or_return
	declarations := make([dynamic]Foreign_Declaration, context.temp_allocator)
	foreign_declarations_collect(target.decls[:], &declarations)
	ok = true
	for declaration in declarations {
		for export in exports {
			if declaration.link_name == "" || export.name != declaration.link_name {
				continue
			}
			compared += 1
			if compared_names != nil {
				append(compared_names, declaration.link_name)
			}
			form, problem, readable := call_form_of_declaration(&state, target.src, declaration.type)
			if declaration.convention_problem != "" {
				fmt.eprintfln("kerneltool: %s: %s(%d): the declaration of %s, an export of %s: %s. An export is called with the convention \"c\": write proc \"c\", and no default convention on the block", importer, path, declaration.line, declaration.link_name, export.module_name, declaration.convention_problem)
				ok = false
			} else if !readable {
				fmt.eprintfln("kerneltool: %s: %s(%d): the declaration of %s, an export of %s: %s", importer, path, declaration.line, declaration.link_name, export.module_name, problem)
				ok = false
			} else if difference := call_forms_difference(form, export.form); difference != "" {
				fmt.eprintfln("kerneltool: %s: %s(%d): the declaration of %s does not agree with the export of %s: %s", importer, path, declaration.line, declaration.link_name, export.module_name, difference)
				ok = false
			}
			// The first import that exports the name is the one that the
			// conversion binds (convert.odin).
			break
		}
	}
	return compared, ok
}

// source_of_the_repository gives the path of a source of the list of the
// compiler from the folder of the repository, where the tool runs. ok is
// false for a file of the libraries of the compiler. The compiler writes
// absolute paths: the path is cut at the last source folder of the
// repository in it, and the rest must be a file. No comparison with the
// path of the working folder: a link in that path would hide every source.
source_of_the_repository :: proc(path: string) -> (relative: string, ok: bool) {
	if !strings.has_prefix(path, "/") {
		return path, true
	}
	folders := INPUT_FOLDERS
	for folder in folders {
		place := strings.last_index(path, join("/", folder, "/"))
		if place < 0 {
			continue
		}
		candidate := path[place + 1:]
		if os.exists(candidate) {
			return candidate, true
		}
	}
	return "", false
}

// declared_symbols_problem says which symbol that became a slot of the
// importer has no compared declaration. "": each has one or more.
// slot_symbols can name a symbol several times (one slot for each place
// that holds its address); compared_names has one name for each compared
// declaration.
//
// This closes the check from the side of the linked file. A declaration
// that the tool did not find (a `foreign` block in the body of a
// procedure, a link_name or a link_prefix that is a constant and not a
// text) is not compared, and the comparison of the others says nothing of
// it. The call is still in the code, so its symbol is a slot: a slot with
// no compared declaration stops the build. Two declarations of one symbol
// are allowed: each one is compared with the same description, so each is
// the call form of the export. A program and a package that it compiles
// can both declare an export, one of them in a `when` that this build
// leaves out.
declared_symbols_problem :: proc(slot_symbols: []string, compared_names: []string) -> string {
	for symbol in slot_symbols {
		if !slice.contains(compared_names, symbol) {
			return fmt.tprintf("the import %s is called, and the tool found no declaration of it to compare: declare it in a `foreign` block at the level of the file (or of a `when` there), with its name or with link_name as a text", symbol)
		}
	}
	return ""
}

// import_declarations_check is the check of the conversion of a module:
// each `foreign` declaration of the sources that the compiler read for
// this module agrees with the description of the export that it names, in
// the module file of an import, and each symbol that became a slot of the
// module (slot_symbols, from convert) has such a declaration. A
// source is parsed only when it has the word `foreign` and the name of an
// export of an import.
import_declarations_check :: proc(build: Module_Build, imports: []Import_File, slot_symbols: []string) -> bool {
	if len(imports) == 0 {
		return true
	}
	exports := make([dynamic]Importable_Export, context.temp_allocator)
	for item in imports {
		for export_index in 1 ..< module.count(item.file, .Exports) {
			form, readable := call_form_of_export(item.file, export_index)
			if !readable {
				fmt.eprintfln("kerneltool: convert %s: the description of export %d of %s cannot be read", build.name, export_index, item.name)
				return false
			}
			append(&exports, Importable_Export{module_name = item.name, name = module_export_name(item.file, export_index), form = form})
		}
	}
	source_files, _, listed := dependency_list_read(module_dependency_file(build.name))
	if !listed {
		fmt.eprintfln("kerneltool: convert %s: the list of the sources of the compiler cannot be read: the declarations of its imports are not checked", build.name)
		return false
	}
	agree := true
	compared_names := make([dynamic]string, context.temp_allocator)
	for listed_path in source_files {
		// The sources of the compiler itself declare no import of a module.
		path, of_the_repository := source_of_the_repository(listed_path)
		if !of_the_repository || !strings.has_suffix(path, ".odin") {
			continue
		}
		source := read_file(path) or_return
		if !strings.contains(string(source), "foreign") {
			continue
		}
		names_an_export := false
		for export in exports {
			if strings.contains(string(source), export.name) {
				names_an_export = true
				break
			}
		}
		if !names_an_export {
			continue
		}
		_, file_agrees := import_declarations_of_file_agree(join("convert ", build.name), path, exports[:], &compared_names)
		agree &&= file_agrees
	}
	// Each call of an import went through a declaration that was compared.
	if problem := declared_symbols_problem(slot_symbols, compared_names[:]); problem != "" {
		fmt.eprintfln("kerneltool: convert %s: %s", build.name, problem)
		return false
	}
	return agree
}

// module_is_a_library_check refuses a library module with a segment that
// the loader writes and that is read-only after the load: a segment that
// holds a rebase (a table of addresses: of texts, of procedures) or a slot
// (an import). The loader writes it for one base, so a starter keeps one
// prepared part of it for each address where an importer has the module:
// with many importers, its table of prepared modules fills, and the next
// program does not start (src/library/support/system, load.odin).
//
// A segment of that range of the linker that the loader writes nowhere is
// not such a segment: the conversion gives it the flags of a constant
// segment (segment_flags_after_the_relocations), so the flag that this check
// reads is set only where a rebase or a slot is.
module_is_a_library_check :: proc(name: string, file: []u8) -> bool {
	for index in 1 ..< module.count(file, .Segments) {
		segment, _ := module.record(file, .Segments, index, module.Segment)
		if .Read_Only_After_Load in segment.flags {
			fmt.eprintfln("kerneltool: convert %s: a library module has a segment that the loader writes and that is read-only after the load (%d bytes at offset %x): it holds a rebase (a table of addresses: of texts, of procedures) or a slot (an import). Remove the table or the import: each importer would need its own prepared part of the module", name, segment.memory_size, segment.memory_offset)
			return false
		}
	}
	return true
}
