// The types on the site (docs/SITE.md, "The types"): the page of the
// types, the card of each type, and the reference that shows a type
// wherever a page names one. The size, the alignment and the layout of a
// type come from the compiler (type_info_of), never from a number typed
// here: the tool imports the contract packages, so their type information
// is true by construction for the machine that runs the tool. The text of a
// type (its declaration, its comment, its line) comes from the parser of
// Odin, as the descriptions of the modules do.
package kerneltool

import "base:runtime"
import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:reflect"
import "core:strings"
import "contract:errors"
import "contract:fixed_addresses"
import module "contract:module"
import op "contract:operation"

SITE_TYPES_FOLDER :: SITE_REFERENCE_FOLDER + "/types"
SITE_TYPES_FILE :: "tools/kerneltool/site_types.odin"
SITE_MODULE_CONTRACT_DOCUMENT :: "docs/MODULE_CONTRACT.md"
// The packages whose types the site documents: the packages whose files the
// reference tables read, and the module contract, whose types the
// descriptions of the exports use.
SITE_TYPE_PACKAGES :: [?]string{"contract/operation", "contract/errors", "contract/fixed_addresses", "contract/module"}
// A short card shows at most this many fields, members or bits; the page of
// the types shows them all.
SITE_TYPE_CARD_ROWS :: 8
// The id of the card of a type on a page is this prefix and the id of the
// type; its first line, which a screen reader reads with the reference, has
// the suffix too.
SITE_TYPE_CARD_PREFIX :: "card-"
SITE_TYPE_CARD_SUMMARY_SUFFIX :: "-summary"

Site_Type_Kind :: enum {
	Struct,
	Enum,
	Bit_Set,
	Distinct,
	Union,
	Array,
	Basic,
	Wire_Form, // A type of the module contract as a call carries it: module.Type.
	Module_Record, // A record that the exports of one module use, as the build describes it.
}

site_type_kind_names := [Site_Type_Kind]string {
	.Struct        = "struct",
	.Enum          = "enum",
	.Bit_Set       = "bit set",
	.Distinct      = "distinct",
	.Union         = "union",
	.Array         = "array",
	.Basic         = "basic",
	.Wire_Form     = "wire form",
	.Module_Record = "record of a module",
}

// One row of the layout of a struct or of a record: a field, or bytes that
// no field uses.
Site_Type_Field :: struct {
	name:       string,
	type_text:  string,
	type_key:   string, // The key of the type of the field, or "" when the page has no card for it.
	offset:     int,
	size:       int,
	is_padding: bool,
}

// One member of an enum, or one bit of a bit set.
Site_Type_Member :: struct {
	name:  string,
	value: i64, // The value of a member; the place of a bit.
}

// One place that names a type: another type, an operation, the exports of
// a module, a command of the console.
Site_Type_Use :: struct {
	text: string,
	page: string, // The file of the page, with "#" and the anchor.
}

// A type that a page can show, with its card.
Site_Type :: struct {
	key:               string, // "operation.Fault_Record", "basic.u64", "wire.Table", "record.math.Rectangle".
	id:                string, // The anchor on the page of the types: "type-operation-fault-record".
	name:              string,
	package_name:      string, // The package, or the module of a record of a module; "" for a basic type or a wire form.
	kind:              Site_Type_Kind,
	alias_of:          string, // The type that an alias names, as the compiler writes it ("bit_set[Right; u32]"), or "".
	size:              int, // -1 for a wire form: it has a size only as what it points to.
	alignment:         int,
	base_text:         string, // The base of a distinct type or of an enum, the underlying type of a bit set, the element of an array.
	base_key:          string,
	element_text:      string, // The enum of a bit set.
	element_key:       string,
	fields:            []Site_Type_Field, // With a row for each run of padding.
	padding:           int, // The bytes that no field uses.
	members:           []Site_Type_Member,
	variants:          []string, // A union.
	depends_on_target: string, // The part of the type whose size follows the target, or "".
	description:       string,
	declaration:       string, // The source text of the declaration, as the parser has it.
	source:            string,
	line:              int,
	names:             []string, // The keys of the types that the text of a wire form names.
	uses:              [dynamic]Site_Type_Use,
}

// One declaration of a type in a package of SITE_TYPE_PACKAGES, as the
// parser reads it.
Site_Type_Declaration :: struct {
	package_name: string,
	name:         string,
	file:         string,
	line:         int,
	description:  string,
	declaration:  string,
}

// One row of the table of the types of the contract: the package and the
// name of the declaration, and its type information. The name is stated:
// a declaration "Rights :: bit_set[Right; u32]" is an alias, and the type
// information of an alias has no name.
Site_Type_Row :: struct {
	package_name: string,
	name:         string,
	info:         ^runtime.Type_Info,
}

// site_contract_type_rows gives one row for each type that the contract
// packages declare. site_types_problems checks that the rows and the
// declarations of the sources are the same set, so a new type of the
// contract stops `kerneltool site` until it has its row, and that a row
// whose type is named has the name that the compiler gives it.
site_contract_type_rows :: proc() -> []Site_Type_Row {
	rows := [?]Site_Type_Row {
		// contract/operation
		{"operation", "Form", type_info_of(op.Form)},
		{"operation", "Parameter_Form", type_info_of(op.Parameter_Form)},
		{"operation", "Operation_Form", type_info_of(op.Operation_Form)},
		{"operation", "Time_Record", type_info_of(op.Time_Record)},
		{"operation", "Handle", type_info_of(op.Handle)},
		{"operation", "Right", type_info_of(op.Right)},
		{"operation", "Rights", type_info_of(op.Rights)},
		{"operation", "Object_Kind", type_info_of(op.Object_Kind)},
		{"operation", "Operation", type_info_of(op.Operation)},
		{"operation", "Strategy", type_info_of(op.Strategy)},
		{"operation", "Module_Record", type_info_of(op.Module_Record)},
		{"operation", "Stop_Report", type_info_of(op.Stop_Report)},
		{"operation", "Stop_Frame", type_info_of(op.Stop_Frame)},
		{"operation", "Module_Report", type_info_of(op.Module_Report)},
		{"operation", "Budget_Amounts", type_info_of(op.Budget_Amounts)},
		{"operation", "Word", type_info_of(op.Word)},
		{"operation", "Thread_Record", type_info_of(op.Thread_Record)},
		{"operation", "Fault_Record", type_info_of(op.Fault_Record)},
		{"operation", "Fault_Access_Bit", type_info_of(op.Fault_Access_Bit)},
		{"operation", "Fault_Access", type_info_of(op.Fault_Access)},
		{"operation", "Fault_Kind", type_info_of(op.Fault_Kind)},
		{"operation", "Fault_Kinds", type_info_of(op.Fault_Kinds)},
		{"operation", "Fault_Class", type_info_of(op.Fault_Class)},
		{"operation", "Fault_Answer_Kind", type_info_of(op.Fault_Answer_Kind)},
		{"operation", "Thread_Control_Command", type_info_of(op.Thread_Control_Command)},
		{"operation", "Thread_Registers", type_info_of(op.Thread_Registers)},
		{"operation", "Thread_Write_Refusal", type_info_of(op.Thread_Write_Refusal)},
		{"operation", "Event_Kind", type_info_of(op.Event_Kind)},
		{"operation", "Event_Fault_Outcome", type_info_of(op.Event_Fault_Outcome)},
		{"operation", "Event_Rule_Flag", type_info_of(op.Event_Rule_Flag)},
		{"operation", "Event_Rule_Flags", type_info_of(op.Event_Rule_Flags)},
		{"operation", "Event_Rule", type_info_of(op.Event_Rule)},
		{"operation", "Event_Record", type_info_of(op.Event_Record)},
		{"operation", "Event_Ring", type_info_of(op.Event_Ring)},
		{"operation", "Status", type_info_of(op.Status)},
		{"operation", "Memory_Flag", type_info_of(op.Memory_Flag)},
		{"operation", "Memory_Flags", type_info_of(op.Memory_Flags)},
		{"operation", "Page_Range", type_info_of(op.Page_Range)},
		{"operation", "Address_Range", type_info_of(op.Address_Range)},
		{"operation", "Commit_Flag", type_info_of(op.Commit_Flag)},
		{"operation", "Commit_Flags", type_info_of(op.Commit_Flags)},
		{"operation", "Map_Flag", type_info_of(op.Map_Flag)},
		{"operation", "Map_Flags", type_info_of(op.Map_Flags)},
		{"operation", "Program_State", type_info_of(op.Program_State)},
		{"operation", "Device_Kind", type_info_of(op.Device_Kind)},
		{"operation", "Inspect_Kind", type_info_of(op.Inspect_Kind)},
		{"operation", "Program_Mapping_Flag", type_info_of(op.Program_Mapping_Flag)},
		{"operation", "Program_Mapping", type_info_of(op.Program_Mapping)},
		{"operation", "Program_Mapping_Report", type_info_of(op.Program_Mapping_Report)},
		{"operation", "Thread_Report", type_info_of(op.Thread_Report)},
		{"operation", "Thread_Table_Report", type_info_of(op.Thread_Table_Report)},
		{"operation", "Page_Report", type_info_of(op.Page_Report)},
		{"operation", "System_Report", type_info_of(op.System_Report)},
		{"operation", "Lock_Kind", type_info_of(op.Lock_Kind)},
		{"operation", "Lock_Count", type_info_of(op.Lock_Count)},
		{"operation", "Processor_Report", type_info_of(op.Processor_Report)},
		{"operation", "Log_Level", type_info_of(op.Log_Level)},
		{"operation", "Log_Head", type_info_of(op.Log_Head)},
		{"operation", "Log_Record", type_info_of(op.Log_Record)},
		{"operation", "Mapping_Flag", type_info_of(op.Mapping_Flag)},
		{"operation", "Mapping_Run", type_info_of(op.Mapping_Run)},
		{"operation", "Mapping_Report", type_info_of(op.Mapping_Report)},
		{"operation", "Boot_Stage", type_info_of(op.Boot_Stage)},
		{"operation", "Boot_Range", type_info_of(op.Boot_Range)},
		{"operation", "Boot_Report", type_info_of(op.Boot_Report)},
		{"operation", "Program_Report", type_info_of(op.Program_Report)},
		{"operation", "Context", type_info_of(op.Context)},
		// contract/errors
		{"errors", "Error_Record", type_info_of(errors.Error_Record)},
		{"errors", "Kind", type_info_of(errors.Kind)},
		{"errors", "Unit", type_info_of(errors.Unit)},
		{"errors", "End", type_info_of(errors.End)},
		// contract/fixed_addresses
		{"fixed_addresses", "Fixed_Range", type_info_of(fixed_addresses.Fixed_Range)},
		{"fixed_addresses", "Fixed_Ranges", type_info_of(fixed_addresses.Fixed_Ranges)},
		{"fixed_addresses", "Address_Range", type_info_of(fixed_addresses.Address_Range)},
		// contract/module
		{"module", "Load_Stage", type_info_of(module.Load_Stage)},
		{"module", "Difference", type_info_of(module.Difference)},
		{"module", "Described", type_info_of(module.Described)},
		{"module", "Named", type_info_of(module.Named)},
		{"module", "Load_Error", type_info_of(module.Load_Error)},
		{"module", "Machine", type_info_of(module.Machine)},
		{"module", "Header", type_info_of(module.Header)},
		{"module", "Table_Kind", type_info_of(module.Table_Kind)},
		{"module", "Table_Entry", type_info_of(module.Table_Entry)},
		{"module", "Segment_Flag", type_info_of(module.Segment_Flag)},
		{"module", "Segment_Flags", type_info_of(module.Segment_Flags)},
		{"module", "Segment", type_info_of(module.Segment)},
		{"module", "Import", type_info_of(module.Import)},
		{"module", "Slot", type_info_of(module.Slot)},
		{"module", "Export", type_info_of(module.Export)},
		{"module", "Type", type_info_of(module.Type)},
		{"module", "Direction", type_info_of(module.Direction)},
		{"module", "Table_Place", type_info_of(module.Table_Place)},
		{"module", "Function", type_info_of(module.Function)},
		{"module", "Record", type_info_of(module.Record)},
		{"module", "Field", type_info_of(module.Field)},
		{"module", "Documentation", type_info_of(module.Documentation)},
		{"module", "Error", type_info_of(module.Error)},
		{"module", "Bound_Import", type_info_of(module.Bound_Import)},
		{"module", "Replacement", type_info_of(module.Replacement)},
	}
	list := make([]Site_Type_Row, len(rows), context.temp_allocator)
	copy(list, rows[:])
	return list
}

// site_type_row_key gives the key of a row: "operation.Rights".
site_type_row_key :: proc(row: Site_Type_Row) -> string {
	return strings.concatenate({row.package_name, ".", row.name}, context.temp_allocator)
}

// A basic type of Odin that a field or a parameter of the contract uses.
Site_Basic_Type :: struct {
	name: string, // As the compiler writes it.
	slug: string, // The part of its key and of its id: "[]u8" has no letter of its own.
	info: ^runtime.Type_Info,
	what: string, // One line: what it is.
}

site_basic_types :: proc() -> []Site_Basic_Type {
	rows := [?]Site_Basic_Type {
		{"u8", "u8", type_info_of(u8), "An unsigned integer of 8 bits."},
		{"u16", "u16", type_info_of(u16), "An unsigned integer of 16 bits, little-endian."},
		{"u32", "u32", type_info_of(u32), "An unsigned integer of 32 bits, little-endian."},
		{"u64", "u64", type_info_of(u64), "An unsigned integer of 64 bits, little-endian."},
		{"i8", "i8", type_info_of(i8), "A signed integer of 8 bits, in two's complement."},
		{"i16", "i16", type_info_of(i16), "A signed integer of 16 bits, in two's complement, little-endian."},
		{"i32", "i32", type_info_of(i32), "A signed integer of 32 bits, in two's complement, little-endian."},
		{"i64", "i64", type_info_of(i64), "A signed integer of 64 bits, in two's complement, little-endian."},
		{"int", "int", type_info_of(int), "A signed integer of the size of an address of the target."},
		{"bool", "bool", type_info_of(bool), "A boolean of one byte: 0 is false, 1 is true."},
		{"rawptr", "rawptr", type_info_of(rawptr), "An address with no type."},
		{"uintptr", "uintptr", type_info_of(uintptr), "An unsigned integer of the size of an address of the target."},
		{"string", "string", type_info_of(string), "UTF-8 bytes that the program does not own: their address, then their count."},
		{"[]u8", "slice-of-u8", type_info_of([]u8), "Bytes that the program does not own: their address, then their count."},
	}
	list := make([]Site_Basic_Type, len(rows), context.temp_allocator)
	copy(list, rows[:])
	return list
}

// site_type_info_text gives a type as the compiler writes it.
site_type_info_text :: proc(info: ^runtime.Type_Info) -> string {
	if info == nil {
		return ""
	}
	b := strings.builder_make(context.temp_allocator)
	reflect.write_type(&b, info)
	return strings.to_string(b)
}

// site_type_package_of gives the package of a named type: the last part of
// the path that the compiler records.
site_type_package_of :: proc(named: runtime.Type_Info_Named) -> string {
	name := named.pkg
	if slash := strings.last_index_byte(name, '/'); slash >= 0 {
		name = name[slash + 1:]
	}
	if colon := strings.last_index_byte(name, ':'); colon >= 0 {
		name = name[colon + 1:]
	}
	return name
}

// site_type_key_id gives the id of a type on the page of the types.
site_type_key_id :: proc(key: string) -> string {
	return strings.concatenate({"type-", site_slug(key)}, context.temp_allocator)
}

// site_type_target_dependence gives the part of a type whose size is the
// size of an address of the target (an address, a slice, a string, int or
// uintptr), or "": such a type has the layout of the machine that the
// compiler builds for, and the tool and the system are built for two
// machines.
site_type_target_dependence :: proc(info: ^runtime.Type_Info, depth: int = 0) -> string {
	if info == nil || depth > 16 {
		return ""
	}
	if info.id == int || info.id == uint || info.id == uintptr {
		return site_type_info_text(info)
	}
	#partial switch variant in info.variant {
	case runtime.Type_Info_Named:
		return site_type_target_dependence(variant.base, depth + 1)
	case runtime.Type_Info_Pointer, runtime.Type_Info_Multi_Pointer, runtime.Type_Info_Slice, runtime.Type_Info_String, runtime.Type_Info_Dynamic_Array, runtime.Type_Info_Map, runtime.Type_Info_Any, runtime.Type_Info_Procedure, runtime.Type_Info_Soa_Pointer:
		return site_type_info_text(info)
	case runtime.Type_Info_Struct:
		for index in 0 ..< int(variant.field_count) {
			if part := site_type_target_dependence(variant.types[index], depth + 1); part != "" {
				return part
			}
		}
	case runtime.Type_Info_Array:
		return site_type_target_dependence(variant.elem, depth + 1)
	case runtime.Type_Info_Enumerated_Array:
		return site_type_target_dependence(variant.elem, depth + 1)
	case runtime.Type_Info_Union:
		for part_info in variant.variants {
			if part := site_type_target_dependence(part_info, depth + 1); part != "" {
				return part
			}
		}
	}
	return ""
}

// site_type_layout gives the rows of the layout of a struct: each field at
// its offset, and a row of padding for each run of bytes that no field
// uses, also at its end. The fields of a raw union overlap: no padding is
// counted between them.
site_type_layout :: proc(fields: []Site_Type_Field, size: int) -> (rows: []Site_Type_Field, padding: int) {
	list := make([dynamic]Site_Type_Field, context.temp_allocator)
	position := 0
	for field in fields {
		if field.offset > position {
			append(&list, Site_Type_Field{name = "padding", offset = position, size = field.offset - position, is_padding = true})
			padding += field.offset - position
		}
		append(&list, field)
		position = max(position, field.offset + field.size)
	}
	if size > position {
		append(&list, Site_Type_Field{name = "padding", offset = position, size = size - position, is_padding = true})
		padding += size - position
	}
	return list[:], padding
}

// site_type_from_info gives a type from its type information. keys gives
// the key of each type that has a card, so that a field links to the card
// of its type. A named type gives its name and its package; the type of an
// alias has neither, so its kind is the kind of what it names, and the
// writer of its row gives its name. No type information is nil here: the
// caller has none to give for a wire form or a record of a module.
site_type_from_info :: proc(info: ^runtime.Type_Info, keys: map[typeid]string) -> Site_Type {
	type := Site_Type{uses = make([dynamic]Site_Type_Use, context.temp_allocator)}
	if info == nil {
		type.kind = .Basic
		return type
	}
	type.size = info.size
	type.alignment = info.align
	type.depends_on_target = site_type_target_dependence(info)
	key_of :: proc(keys: map[typeid]string, part: ^runtime.Type_Info) -> string {
		if part == nil {
			return ""
		}
		return keys[part.id]
	}
	base := info
	named, is_named := info.variant.(runtime.Type_Info_Named)
	if is_named {
		type.name = named.name
		type.package_name = site_type_package_of(named)
		base = named.base
	} else {
		type.name = site_type_info_text(info)
		type.alias_of = type.name
	}
	if base == nil {
		type.kind = .Basic
		return type
	}
	#partial switch variant in base.variant {
	case runtime.Type_Info_Struct:
		type.kind = .Struct
		fields := make([dynamic]Site_Type_Field, context.temp_allocator)
		for index in 0 ..< int(variant.field_count) {
			field_info := variant.types[index]
			append(&fields, Site_Type_Field{name = variant.names[index], type_text = site_type_info_text(field_info), type_key = key_of(keys, field_info), offset = int(variant.offsets[index]), size = field_info.size})
		}
		type.fields, type.padding = site_type_layout(fields[:], info.size)
	case runtime.Type_Info_Enum:
		type.kind = .Enum
		type.base_text = site_type_info_text(variant.base)
		type.base_key = key_of(keys, variant.base)
		members := make([dynamic]Site_Type_Member, context.temp_allocator)
		for name, index in variant.names {
			append(&members, Site_Type_Member{name = name, value = i64(variant.values[index])})
		}
		type.members = members[:]
	case runtime.Type_Info_Bit_Set:
		type.kind = .Bit_Set
		type.element_text = site_type_info_text(variant.elem)
		type.element_key = key_of(keys, variant.elem)
		if variant.underlying != nil {
			type.base_text = site_type_info_text(variant.underlying)
			type.base_key = key_of(keys, variant.underlying)
		}
		members := make([dynamic]Site_Type_Member, context.temp_allocator)
		element: ^runtime.Type_Info
		if variant.elem != nil {
			element = runtime.type_info_base(variant.elem)
		}
		if element != nil {
			if enumeration, is_enum := element.variant.(runtime.Type_Info_Enum); is_enum {
				for name, index in enumeration.names {
					append(&members, Site_Type_Member{name = name, value = i64(enumeration.values[index]) - variant.lower})
				}
			}
		}
		type.members = members[:]
	case runtime.Type_Info_Union:
		type.kind = .Union
		variants := make([dynamic]string, context.temp_allocator)
		for part in variant.variants {
			append(&variants, site_type_info_text(part))
		}
		type.variants = variants[:]
	case runtime.Type_Info_Array:
		// A named array is distinct; an alias of an array is an array.
		if is_named {
			type.kind = .Distinct
			type.base_text = site_type_info_text(base)
		} else {
			type.kind = .Array
			type.base_text = site_type_info_text(variant.elem)
			type.base_key = key_of(keys, variant.elem)
		}
	case:
		if is_named {
			type.kind = .Distinct
			type.base_text = site_type_info_text(base)
			type.base_key = key_of(keys, base)
		} else {
			// A basic type itself (u64, string): no base, and not an alias.
			type.kind = .Basic
			type.alias_of = ""
		}
	}
	return type
}

// site_type_declarations_read reads the declarations of types of a package
// folder with the parser of Odin: each declaration "Name :: struct",
// "enum", "bit_set", "union", "distinct", "bit_field", or an array type (an
// alias, which the type information cannot name). The test files are not
// a part of the contract.
site_type_declarations_read :: proc(folder: string) -> (declarations: []Site_Type_Declaration, ok: bool) {
	context.allocator = context.temp_allocator
	package_name := folder[strings.last_index_byte(folder, '/') + 1:]
	paths := files_with_suffix(folder, ".odin") or_return
	list := make([dynamic]Site_Type_Declaration)
	for path in paths {
		if strings.has_suffix(path, "_test.odin") {
			continue
		}
		source := site_read(path) or_return
		file := ast.new_from_positions(ast.File, {}, {})
		file.src = source
		file.fullpath = path
		reader := parser.default_parser()
		if !parser.parse_file(&reader, file) {
			fmt.eprintfln("kerneltool: site: %s: the parser found errors", path)
			return nil, false
		}
		for statement in file.decls {
			declaration, is_value := statement.derived.(^ast.Value_Decl)
			if !is_value || declaration.is_mutable || len(declaration.names) != 1 || len(declaration.values) != 1 {
				continue
			}
			identifier, has_name := declaration.names[0].derived.(^ast.Ident)
			if !has_name {
				continue
			}
			is_type := false
			#partial switch _ in declaration.values[0].derived {
			case ^ast.Struct_Type, ^ast.Enum_Type, ^ast.Bit_Set_Type, ^ast.Union_Type, ^ast.Distinct_Type, ^ast.Bit_Field_Type, ^ast.Array_Type:
				is_type = true
			}
			if !is_type {
				continue
			}
			description := markdown_of(declaration.docs)
			if description == "" {
				description = markdown_of(declaration.comment)
			}
			append(&list, Site_Type_Declaration{package_name = package_name, name = identifier.name, file = path, line = declaration.pos.line, description = description, declaration = source[declaration.pos.offset:declaration.end.offset]})
		}
	}
	return list[:], true
}

// site_types_problems gives the faults of the table of the types: each
// declaration of a type of the documented packages has a row of
// site_contract_type_rows, each row names a declaration, no row is there
// twice, and each row has type information. A row whose type is named
// has the name and the package that the compiler gives it, so a wrong name
// is caught; the type of an alias has no name, and its row is checked
// against the declarations only.
site_types_problems :: proc(declarations: []Site_Type_Declaration, type_rows: []Site_Type_Row) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	rows := make(map[string]bool, context.temp_allocator)
	for row in type_rows {
		key := site_type_row_key(row)
		if row.info == nil {
			append(&problems, fmt.tprintf("the row %s of the table of the types (%s, site_contract_type_rows) has no type information", key, SITE_TYPES_FILE))
			continue
		}
		if named, is_named := row.info.variant.(runtime.Type_Info_Named); is_named {
			compiler_key := strings.concatenate({site_type_package_of(named), ".", named.name}, context.temp_allocator)
			if compiler_key != key {
				append(&problems, fmt.tprintf("the row %s of the table of the types (%s, site_contract_type_rows) holds the type information of %s", key, SITE_TYPES_FILE, compiler_key))
			}
		}
		if key in rows {
			append(&problems, fmt.tprintf("the type %s has two rows in the table of the types (%s, site_contract_type_rows)", key, SITE_TYPES_FILE))
		}
		rows[key] = true
	}
	declared := make(map[string]bool, context.temp_allocator)
	for declaration in declarations {
		key := strings.concatenate({declaration.package_name, ".", declaration.name}, context.temp_allocator)
		declared[key] = true
		if key not_in rows {
			append(&problems, fmt.tprintf("%s, line %d: the type %s has no row in the table of the types (%s, site_contract_type_rows)", declaration.file, declaration.line, key, SITE_TYPES_FILE))
		}
	}
	packages := SITE_TYPE_PACKAGES
	for key in rows {
		if key not_in declared {
			append(&problems, fmt.tprintf("the row %s of the table of the types (%s, site_contract_type_rows) names no declaration of the packages %v", key, SITE_TYPES_FILE, packages))
		}
	}
	return problems[:]
}

// site_type_keys_make gives the key of each type that the compiler knows
// and that has a card: the basic types, then each row of the contract, so
// that a field finds the card of its type. The type of an alias is the
// type that it names: a field of the type bit_set[Right; u32] finds the
// card of Rights. A basic type keeps its own card.
site_type_keys_make :: proc(basics: []Site_Basic_Type, type_rows: []Site_Type_Row) -> map[typeid]string {
	keys := make(map[typeid]string, context.temp_allocator)
	for basic in basics {
		keys[basic.info.id] = strings.concatenate({"basic.", basic.slug}, context.temp_allocator)
	}
	for row in type_rows {
		if row.info == nil || row.info.id in keys {
			continue
		}
		keys[row.info.id] = site_type_row_key(row)
	}
	return keys
}

// site_type_add adds a type to the types of the site.
site_type_add :: proc(site: ^Site, type: Site_Type) {
	append(&site.types, type)
	site.type_keys[type.key] = len(site.types) - 1
	site.type_ids[type.id] = len(site.types) - 1
}

// site_type_use_add records that a place names a type, once.
site_type_use_add :: proc(site: ^Site, key, text, page: string) {
	index, found := site_type_index(site, key)
	if !found {
		return
	}
	for use in site.types[index].uses {
		if use.page == page && use.text == text {
			return
		}
	}
	append(&site.types[index].uses, Site_Type_Use{text = text, page = page})
}

// site_module_record_key gives the key of a record that the exports of a
// module use.
site_module_record_key :: proc(module_name, record_name: string) -> string {
	return strings.concatenate({"record.", module_name, ".", record_name}, context.temp_allocator)
}

// site_wire_form_key gives the key of a wire form.
site_wire_form_key :: proc(form: module.Type) -> string {
	return strings.concatenate({"wire.", fmt.tprintf("%v", form)}, context.temp_allocator)
}

// site_types_read makes the types of the site: the basic types, each type
// of the contract packages with its declaration, the wire forms of the
// module contract and the records of each module; then where each one is
// named. A declaration with no row, or a row with no declaration, stops
// the command.
site_types_read :: proc(site: ^Site) -> bool {
	site.types = make([dynamic]Site_Type, context.temp_allocator)
	site.type_keys = make(map[string]int, context.temp_allocator)
	site.type_ids = make(map[string]int, context.temp_allocator)

	basics := site_basic_types()
	type_rows := site_contract_type_rows()
	keys := site_type_keys_make(basics, type_rows)

	declarations := make([dynamic]Site_Type_Declaration, context.temp_allocator)
	packages := SITE_TYPE_PACKAGES
	for folder in packages {
		found := site_type_declarations_read(folder) or_return
		append(&declarations, ..found)
	}
	if problems := site_types_problems(declarations[:], type_rows); len(problems) > 0 {
		for problem in problems {
			fmt.eprintfln("kerneltool: site: %s", problem)
		}
		return false
	}
	by_key := make(map[string]Site_Type_Declaration, context.temp_allocator)
	for declaration in declarations {
		by_key[strings.concatenate({declaration.package_name, ".", declaration.name}, context.temp_allocator)] = declaration
	}

	for basic in basics {
		type := site_type_from_info(basic.info, keys)
		type.key = keys[basic.info.id]
		type.id = site_type_key_id(type.key)
		type.name = basic.name
		type.kind = .Basic
		type.description = basic.what
		site_type_add(site, type)
	}
	for row in type_rows {
		type := site_type_from_info(row.info, keys)
		// The name of the row: the type of an alias has none of its own.
		type.key = site_type_row_key(row)
		type.id = site_type_key_id(type.key)
		type.name = row.name
		type.package_name = row.package_name
		declaration := by_key[type.key]
		type.description = declaration.description
		type.declaration = declaration.declaration
		type.source = declaration.file
		type.line = declaration.line
		site_type_add(site, type)
	}

	// The wire forms: the members of module.Type that the compiler knows,
	// with the comment of each member in the source of the contract.
	format_file :: "contract/module/format.odin"
	format_text := site_read(format_file) or_return
	members, problem := site_enumeration_read(format_text, format_file, "Type")
	if problem != "" {
		fmt.eprintfln("kerneltool: site: %s", problem)
		return false
	}
	for form in module.Type {
		if form == .None {
			continue
		}
		key := site_wire_form_key(form)
		type := Site_Type{key = key, id = site_type_key_id(key), name = fmt.tprintf("%v", form), kind = .Wire_Form, size = -1, alignment = -1, source = format_file, uses = make([dynamic]Site_Type_Use, context.temp_allocator)}
		for member in members {
			if member.name == type.name {
				type.description = member.comment
				type.line = member.line
			}
		}
		// The types of the module contract that the text of the form names:
		// what the register of a parameter points to.
		named := make([dynamic]string, context.temp_allocator)
		for row in type_rows {
			if row.package_name != "module" {
				continue
			}
			for index in 0 ..< len(type.description) {
				if site_whole_word_at(type.description, index, row.name) {
					append(&named, site_type_row_key(row))
					break
				}
			}
		}
		type.names = named[:]
		site_type_add(site, type)
	}

	// The records of the modules, as the build describes them: the size and
	// the offsets of the description, the size of each field from its type.
	for item in site.reference.modules {
		for record in item.description.records {
			key := site_module_record_key(item.build.name, record.name)
			if key in site.type_keys {
				continue
			}
			type := Site_Type{key = key, id = site_type_key_id(key), name = record.name, package_name = item.build.name, kind = .Module_Record, size = int(record.size), alignment = 1, uses = make([dynamic]Site_Type_Use, context.temp_allocator)}
			fields := make([dynamic]Site_Type_Field, context.temp_allocator)
			for field in record.fields {
				size, alignment := site_record_field_size(field)
				type.alignment = max(type.alignment, alignment)
				text := fmt.tprintf("%v", field.type)
				#partial switch field.type {
				case .Integer:
					text = fmt.tprintf("%s%d", field.unsigned ? "u" : "i", size * 8)
				case .Text:
					text = fmt.tprintf("Text(%d)", field.detail)
				}
				append(&fields, Site_Type_Field{name = field.name, type_text = text, type_key = site_wire_form_key(field.type), offset = int(field.offset), size = size})
			}
			type.fields, type.padding = site_type_layout(fields[:], type.size)
			site_type_add(site, type)
		}
	}

	site_type_uses_make(site)
	return true
}

// site_record_field_size gives the size and the alignment of a field of a
// record of a module (contract/module, Field): an Integer of its size, 8
// when the detail is 0; a Handle of the size of a handle; a Text of its
// detail bytes, which hold no number.
site_record_field_size :: proc(field: Field_Description) -> (size: int, alignment: int) {
	#partial switch field.type {
	case .Integer:
		size = field.detail == 0 ? 8 : int(field.detail)
		return size, size
	case .Handle:
		return size_of(op.Handle), align_of(op.Handle)
	case .Text:
		return int(field.detail), 1
	}
	return 0, 1
}

// site_type_uses_make records where each type is named: the types whose
// fields, base or element it is, the kernel operations whose words name
// it, the exports that take or give it, and the commands of the console.
site_type_uses_make :: proc(site: ^Site) {
	types_page := site_page_file(SITE_TYPES_FOLDER)
	for index in 0 ..< len(site.types) {
		type := site.types[index]
		page := strings.concatenate({types_page, "#", type.id}, context.temp_allocator)
		for field in type.fields {
			if field.type_key != "" {
				site_type_use_add(site, field.type_key, type.name, page)
			}
		}
		if type.base_key != "" {
			site_type_use_add(site, type.base_key, type.name, page)
		}
		if type.element_key != "" {
			site_type_use_add(site, type.element_key, type.name, page)
		}
	}
	operations_page := site_page_file(SITE_OPERATIONS_FOLDER)
	for operation in site.reference.operations {
		if operation.member.number == 0 {
			continue
		}
		page := strings.concatenate({operations_page, "#operation-", site_slug(operation.member.name)}, context.temp_allocator)
		for text in ([]string{operation.parameters, operation.result}) {
			for word in site_identifiers_of(text) {
				site_type_use_add(site, strings.concatenate({"operation.", word}, context.temp_allocator), operation.member.name, page)
			}
		}
	}
	for item in site.reference.modules {
		page := strings.concatenate({item.page, "#exports"}, context.temp_allocator)
		for export in item.description.exports {
			forms := make([dynamic]module.Type, context.temp_allocator)
			details := make([dynamic]u32, context.temp_allocator)
			append(&forms, ..export.parameters)
			for type_index in 0 ..< len(export.parameters) {
				append(&details, type_index < len(export.details) ? export.details[type_index] : 0)
			}
			append(&forms, export.result)
			append(&details, export.result_detail)
			for form, form_index in forms {
				if form == .None {
					continue
				}
				site_type_use_add(site, site_wire_form_key(form), item.build.name, page)
				detail := details[form_index]
				if (form == .Record || form == .Table) && detail >= 1 && int(detail) <= len(item.description.records) {
					site_type_use_add(site, site_module_record_key(item.build.name, item.description.records[detail - 1].name), item.build.name, page)
				}
			}
			if export.error_record >= 1 && int(export.error_record) <= len(item.description.records) {
				site_type_use_add(site, site_module_record_key(item.build.name, item.description.records[export.error_record - 1].name), item.build.name, page)
			}
		}
	}
	console_page := site_page_file(SITE_CONSOLE_FOLDER)
	for command in site.reference.console_commands {
		page := strings.concatenate({console_page, "#command-", site_slug(command.name)}, context.temp_allocator)
		for name in command.parameters {
			site_type_use_add(site, strings.concatenate({"wire.", name}, context.temp_allocator), command.name, page)
		}
		site_type_use_add(site, strings.concatenate({"wire.", command.result}, context.temp_allocator), command.name, page)
	}
}

// site_identifiers_of gives each identifier of a text, in its order.
site_identifiers_of :: proc(text: string) -> []string {
	list := make([dynamic]string, context.temp_allocator)
	index := 0
	for index < len(text) {
		if !site_is_word_byte(text[index]) {
			index += 1
			continue
		}
		end := index
		for end < len(text) && site_is_word_byte(text[end]) {
			end += 1
		}
		append(&list, text[index:end])
		index = end
	}
	return list[:]
}

// site_type_reference writes a type where a page shows it: a button that
// opens the card of the type, a popover that the page holds once at the end
// of its text. The popover is in the top layer, so the box of a table that
// scrolls does not cut it, and it opens with a click, a tap or the keyboard
// with no script. A screen reader reads the first line of the card with the
// button. marked: the reference has the look of a value of the kind Type
// (a fact, a prose cell); a reference inside a signature or a cell of a
// column of types takes the look of its place. A text that names no type of
// the site is written as text.
site_type_reference :: proc(site: ^Site, b: ^strings.Builder, key, text: string, marked: bool) {
	index, found := site_type_index(site, key)
	if !found {
		// A type with no card: its name as a value of the kind Type, with no
		// reference. The command prints the count.
		site.type_names_without_card += 1
		site_value(b, .Type, text, false)
		return
	}
	id := site.types[index].id
	class: string = marked ? "type-reference value value-type" : "type-reference"
	fmt.sbprintf(b, "<button type=\"button\" class=\"%s\" popovertarget=\"%s%s\" popovertargetaction=\"show\" aria-describedby=\"%s%s%s\">", class, SITE_TYPE_CARD_PREFIX, id, SITE_TYPE_CARD_PREFIX, id, SITE_TYPE_CARD_SUMMARY_SUFFIX)
	site_escape(b, text)
	strings.write_string(b, "</button>")
}

// site_type_index gives the place of a type in the types of the site by its
// key, or false: also when the site has no types, or when the place is not
// one of its types.
site_type_index :: proc(site: ^Site, key: string) -> (index: int, found: bool) {
	if key == "" || site.type_keys == nil {
		return 0, false
	}
	index, found = site.type_keys[key]
	if !found || index < 0 || index >= len(site.types) {
		return 0, false
	}
	return index, true
}

// site_type_reference_html gives the markup of a reference.
site_type_reference_html :: proc(site: ^Site, key, text: string, marked: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	site_type_reference(site, &b, key, text, marked)
	return strings.to_string(b)
}

// site_text_with_type_references writes a text with each identifier that
// names a type of a package as a reference: the words of the comment of a
// kernel operation, which are its only form of the parameters.
site_text_with_type_references :: proc(site: ^Site, b: ^strings.Builder, text, package_name: string) {
	index := 0
	for index < len(text) {
		if !site_is_word_byte(text[index]) {
			site_escape(b, text[index:index + 1])
			index += 1
			continue
		}
		end := index
		for end < len(text) && site_is_word_byte(text[end]) {
			end += 1
		}
		// A word of the comment that names no type is a word, not a type
		// with no card.
		word := text[index:end]
		key := strings.concatenate({package_name, ".", word}, context.temp_allocator)
		if _, is_type := site_type_index(site, key); is_type {
			site_type_reference(site, b, key, word, false)
		} else {
			site_escape(b, word)
		}
		index = end
	}
}

// site_type_summary gives the first line of the card of a type: its kind,
// its size and its alignment, then the first sentence of its description.
site_type_summary :: proc(site: ^Site, type: Site_Type) -> string {
	b := strings.builder_make(context.temp_allocator)
	switch type.kind {
	case .Wire_Form:
		strings.write_string(&b, "A wire form of the module contract: one register of a call.")
	case .Module_Record:
		fmt.sbprintf(&b, "A record of the module %s: %d bytes, aligned on %d bytes, %d bytes of padding.", type.package_name, type.size, type.alignment, type.padding)
	case .Struct:
		fmt.sbprintf(&b, "A struct of the package %s: %d bytes, aligned on %d bytes, %d bytes of padding.", type.package_name, type.size, type.alignment, type.padding)
	case .Enum:
		fmt.sbprintf(&b, "An enum of the package %s on %s: %d bytes, %d members.", type.package_name, type.base_text, type.size, len(type.members))
	case .Bit_Set:
		fmt.sbprintf(&b, "A bit set of the package %s of %s: %d bytes, %d bits.", type.package_name, type.element_text, type.size, len(type.members))
	case .Distinct:
		fmt.sbprintf(&b, "A distinct type of the package %s on %s: %d bytes, aligned on %d bytes.", type.package_name, type.base_text, type.size, type.alignment)
	case .Union:
		fmt.sbprintf(&b, "A union of the package %s: %d bytes, aligned on %d bytes.", type.package_name, type.size, type.alignment)
	case .Array:
		fmt.sbprintf(&b, "An array of the package %s: %d bytes, aligned on %d bytes.", type.package_name, type.size, type.alignment)
	case .Basic:
		fmt.sbprintf(&b, "A basic type: %d bytes, aligned on %d bytes.", type.size, type.alignment)
	}
	if type.alias_of != "" {
		fmt.sbprintf(&b, " An alias of %s.", type.alias_of)
	}
	if first := site_source_comment_plain(site, markdown_first_sentence(type.description)); first != "" {
		strings.write_byte(&b, ' ')
		strings.write_string(&b, first)
		strings.write_byte(&b, '.')
	}
	return strings.to_string(b)
}

// site_type_card_write writes the card of a type that a page shows: its
// name as a link to the page of the types, its first line, its first
// fields or members, and the size that follows the target.
site_type_card_write :: proc(site: ^Site, b: ^strings.Builder, from_page: string, type: Site_Type) {
	fmt.sbprintf(b, "<div class=\"type-card\" id=\"%s%s\" popover>\n<p class=\"type-card-title\"><a href=\"", SITE_TYPE_CARD_PREFIX, type.id)
	site_escape(b, site_page_link(site, from_page, strings.concatenate({site_page_file(SITE_TYPES_FOLDER), "#", type.id}, context.temp_allocator)))
	strings.write_string(b, "\"><code>")
	site_escape(b, type.name)
	fmt.sbprintf(b, "</code></a> <span class=\"type-card-kind\">%s</span></p>\n<p class=\"type-card-summary\" id=\"%s%s%s\">", site_type_kind_names[type.kind], SITE_TYPE_CARD_PREFIX, type.id, SITE_TYPE_CARD_SUMMARY_SUFFIX)
	site_escape(b, site_type_summary(site, type))
	strings.write_string(b, "</p>\n")
	shown, total := 0, 0
	if len(type.fields) > 0 {
		strings.write_string(b, "<ul class=\"type-card-rows\">\n")
		for field in type.fields {
			if !field.is_padding {
				total += 1
			}
			if shown >= SITE_TYPE_CARD_ROWS {
				continue
			}
			if field.is_padding {
				fmt.sbprintf(b, "<li class=\"padding\"><span>padding</span><span></span><span>%d</span><span>%d bytes</span></li>\n", field.offset, field.size)
				continue
			}
			shown += 1
			strings.write_string(b, "<li><code>")
			site_escape(b, field.name)
			strings.write_string(b, "</code><code>")
			site_escape(b, field.type_text)
			fmt.sbprintf(b, "</code><span>%d</span><span>%d bytes</span></li>\n", field.offset, field.size)
		}
		strings.write_string(b, "</ul>\n")
	} else if len(type.members) > 0 {
		total = len(type.members)
		strings.write_string(b, "<ul class=\"type-card-rows\">\n")
		for member in type.members[:min(len(type.members), SITE_TYPE_CARD_ROWS)] {
			strings.write_string(b, "<li><code>")
			site_escape(b, member.name)
			if type.kind == .Bit_Set {
				fmt.sbprintf(b, "</code><span>bit %d</span></li>\n", member.value)
			} else {
				fmt.sbprintf(b, "</code><span>%d</span></li>\n", member.value)
			}
			shown += 1
		}
		strings.write_string(b, "</ul>\n")
	}
	if total > shown {
		fmt.sbprintf(b, "<p class=\"type-card-more\">and %d more</p>\n", total - shown)
	}
	if type.depends_on_target != "" {
		strings.write_string(b, "<p class=\"type-card-target\">Holds <code>")
		site_escape(b, type.depends_on_target)
		strings.write_string(b, "</code>: its size follows the size of an address of the target.</p>\n")
	}
	strings.write_string(b, "</div>\n")
}

// site_type_cards_html gives the cards of the types that the text of a page
// names: one for each type, in the order of the first reference to it, at
// the end of the text. With no support of popover in the browser, the
// cards are a list at the end of the text, and each one is still read.
site_type_cards_html :: proc(site: ^Site, from_page, body: string) -> string {
	seen := make(map[string]bool, context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	for target in site_attribute_values(body, "popovertarget=\"") {
		if !strings.has_prefix(target, SITE_TYPE_CARD_PREFIX) || target in seen {
			continue
		}
		seen[target] = true
		index, found := site.type_ids[target[len(SITE_TYPE_CARD_PREFIX):]]
		if !found || index < 0 || index >= len(site.types) {
			continue // The check of the page names it.
		}
		if strings.builder_len(b) == 0 {
			strings.write_string(&b, "<div class=\"type-cards\">\n")
		}
		site_type_card_write(site, &b, from_page, site.types[index])
	}
	if strings.builder_len(b) > 0 {
		strings.write_string(&b, "</div>\n")
	}
	return strings.to_string(b)
}

// site_type_cards_problem gives the fault of the cards of a written page,
// or "": each popovertarget, each card of a declaration and each
// aria-describedby names an id of the page, and no two cards have one id.
site_type_cards_problem :: proc(html: string, page_ids: map[string]bool) -> string {
	for attribute in ([]string{"popovertarget", "data-declaration-card", "aria-describedby"}) {
		for value in site_attribute_values(html, strings.concatenate({attribute, "=\""}, context.temp_allocator)) {
			if value not_in page_ids {
				return fmt.tprintf("the attribute %s names \"%s\", which is not an id of the page", attribute, value)
			}
		}
	}
	cards := make(map[string]bool, context.temp_allocator)
	for id in site_attribute_values(html, "id=\"") {
		if !strings.has_prefix(id, SITE_TYPE_CARD_PREFIX) && !strings.has_prefix(id, SITE_DECLARATION_CARD_PREFIX) {
			continue
		}
		if id in cards {
			return fmt.tprintf("two elements have the id \"%s\"; a page has one card for each type and each declaration", id)
		}
		cards[id] = true
	}
	return ""
}

// site_type_size_text gives a count of bytes.
site_type_size_text :: proc(bytes: int) -> string {
	return bytes == 1 ? "1 byte" : fmt.tprintf("%d bytes", bytes)
}

// site_type_hexadecimal gives a value of an enum in hexadecimal, as the
// bytes of its base hold it: a negative value in two's complement.
site_type_hexadecimal :: proc(value: i64, size: int) -> string {
	bits := u64(value)
	if size > 0 && size < 8 {
		bits &= (u64(1) << uint(size * 8)) - 1
	}
	return fmt.tprintf("0x%X", bits)
}

// site_type_symbol_write writes one type on the page of the types, as a
// documented symbol: its declaration, its description, its facts, and the
// table of its fields, members or bits.
site_type_symbol_write :: proc(site: ^Site, b: ^strings.Builder, type: Site_Type) {
	page := site_page_file(SITE_TYPES_FOLDER)
	facts := make([dynamic]Site_Symbol_Fact, context.temp_allocator)
	append(&facts, Site_Symbol_Fact{label = "Kind", html = site_text_html(site_type_kind_names[type.kind])})
	if type.alias_of != "" {
		append(&facts, Site_Symbol_Fact{label = "An alias of", kind = .Type, html = site_value_html(.Type, type.alias_of)})
	}
	if type.package_name != "" {
		label: string = type.kind == .Module_Record ? "Module" : "Package"
		if type.kind == .Module_Record {
			append(&facts, Site_Symbol_Fact{label = label, kind = .Module, html = strings.concatenate({"<a href=\"", site_page_link(site, page, site_module_page(type.package_name)), "\">", site_value_html(.Module, type.package_name), "</a>"}, context.temp_allocator)})
		} else {
			folder := strings.concatenate({"contract/", type.package_name}, context.temp_allocator)
			link := strings.builder_make(context.temp_allocator)
			site_value_link(&link, .File, site_folder_address(site, folder), folder, false)
			append(&facts, Site_Symbol_Fact{label = label, kind = .File, html = strings.to_string(link)})
		}
	}
	if type.kind == .Wire_Form {
		append(&facts, Site_Symbol_Fact{label = "In a call", html = strings.concatenate({site_text_html(fmt.tprintf("one integer register of a parameter: an export has at most %d (", module.PARAMETER_CAPACITY)), "<code>module.PARAMETER_CAPACITY</code>)"}, context.temp_allocator)})
		if len(type.names) > 0 {
			names := make([dynamic]string, context.temp_allocator)
			for key in type.names {
				append(&names, site_type_reference_html(site, key, key[len("module."):], true))
			}
			append(&facts, Site_Symbol_Fact{label = "Types that its text names", kind = .Type, html = site_value_list_html(names[:])})
		}
		if type.name == "Handle" {
			append(&facts, Site_Symbol_Fact{label = "In a record", kind = .Type, html = strings.concatenate({site_type_reference_html(site, "operation.Handle", "Handle", true), site_text_html(fmt.tprintf(": %d bytes", size_of(op.Handle)))}, context.temp_allocator)})
		}
		// A reference to the heading of the call form, with its title: "section
		// 4" alone means nothing on a page.
		if _, found := site.documents[SITE_MODULE_CONTRACT_DOCUMENT]; found {
			append(&facts, Site_Symbol_Fact{label = "The contract", html = site_source_comment_html(site, page, SITE_MODULE_CONTRACT_DOCUMENT + ", section 4", .Line)})
		}
	} else {
		append(&facts, Site_Symbol_Fact{label = "Size", kind = .Size, html = site_value_html(.Size, site_type_size_text(type.size))})
		append(&facts, Site_Symbol_Fact{label = "Alignment", kind = .Size, html = site_value_html(.Size, site_type_size_text(type.alignment))})
	}
	if type.kind == .Struct || type.kind == .Module_Record {
		append(&facts, Site_Symbol_Fact{label = "Padding", kind = .Size, html = site_value_html(.Size, site_type_size_text(type.padding))})
	}
	if type.base_text != "" {
		label: string
		#partial switch type.kind {
		case .Bit_Set:
			label = "Underlying type"
		case .Enum:
			label = "Base type"
		case:
			label = "Base"
		}
		append(&facts, Site_Symbol_Fact{label = label, kind = .Type, html = site_type_reference_html(site, type.base_key, type.base_text, true)})
	}
	if type.element_text != "" {
		append(&facts, Site_Symbol_Fact{label = "Element", kind = .Type, html = site_type_reference_html(site, type.element_key, type.element_text, true)})
	}
	if len(type.variants) > 0 {
		variants := make([dynamic]string, context.temp_allocator)
		for variant in type.variants {
			append(&variants, site_value_html(.Type, variant))
		}
		append(&facts, Site_Symbol_Fact{label = "Variants", kind = .Type, html = site_value_list_html(variants[:])})
	}
	if type.depends_on_target != "" {
		append(&facts, Site_Symbol_Fact{label = "On the target", html = strings.concatenate({"<code>", site_text_html(type.depends_on_target), "</code>", site_text_html(fmt.tprintf(" has the size of an address of the target: the sizes here are those of %s %s, where the page was made", ODIN_OS_STRING, ODIN_ARCH_STRING))}, context.temp_allocator)})
	}
	if len(type.uses) > 0 {
		uses := make([dynamic]string, context.temp_allocator)
		for use in type.uses {
			use_link := strings.builder_make(context.temp_allocator)
			strings.write_string(&use_link, "<a href=\"")
			site_escape(&use_link, site_page_link(site, page, use.page))
			strings.write_string(&use_link, "\"><code>")
			site_escape(&use_link, use.text)
			strings.write_string(&use_link, "</code></a>")
			append(&uses, strings.to_string(use_link))
		}
		append(&facts, Site_Symbol_Fact{label = "Named by", html = site_value_list_html(uses[:])})
	}

	after := strings.builder_make(context.temp_allocator)
	if len(type.fields) > 0 {
		fields_table := site_table_start(&after, strings.concatenate({"Fields of ", type.name}, context.temp_allocator), {{"Field", .Name}, {"Type", .Name}, {"Offset", .Number}, {"Size", .Number}}, {.None, .Type, .Size, .Size})
		field_bytes := 0
		for field in type.fields {
			if field.is_padding {
				fmt.sbprintf(&after, "<tr class=\"padding\"><td>padding</td><td></td><td>%d</td><td>%d</td></tr>\n", field.offset, field.size)
				continue
			}
			field_bytes += field.size
			strings.write_string(&after, "<tr><td class=\"code name\"><code>")
			site_escape(&after, field.name)
			strings.write_string(&after, "</code></td><td>")
			site_type_reference(site, &after, field.type_key, field.type_text, false)
			fmt.sbprintf(&after, "</td><td>%d</td><td>%d</td></tr>\n", field.offset, field.size)
		}
		site_table_end(&after, fields_table)
		fmt.sbprintf(&after, "<p class=\"type-layout\">%s of fields and %s of padding: %s.</p>\n", site_type_size_text(field_bytes), site_type_size_text(type.padding), site_type_size_text(type.size))
	} else if len(type.members) > 0 && type.kind == .Bit_Set {
		bits_table := site_table_start(&after, strings.concatenate({"Bits of ", type.name}, context.temp_allocator), {{"Bit", .Number}, {"Member", .Name}, {"Mask", .Number}})
		for member in type.members {
			fmt.sbprintf(&after, "<tr><td>%d</td><td class=\"code name\"><code>", member.value)
			site_escape(&after, member.name)
			mask := "-" // A bit outside 0 to 63 has no mask of 64 bits.
			if member.value >= 0 && member.value < 64 {
				mask = site_type_hexadecimal(i64(u64(1) << uint(member.value)), type.size)
			}
			fmt.sbprintf(&after, "</code></td><td>%s</td></tr>\n", mask)
		}
		site_table_end(&after, bits_table)
	} else if len(type.members) > 0 {
		members_table := site_table_start(&after, strings.concatenate({"Members of ", type.name}, context.temp_allocator), {{"Member", .Name}, {"Value", .Number}, {"Hexadecimal", .Number}})
		for member in type.members {
			strings.write_string(&after, "<tr><td class=\"code name\"><code>")
			site_escape(&after, member.name)
			fmt.sbprintf(&after, "</code></td><td>%d</td><td>%s</td></tr>\n", member.value, site_type_hexadecimal(member.value, type.size))
		}
		site_table_end(&after, members_table)
	}

	// The declaration in the colors of the code, each type of the contract
	// inside it a reference to its card.
	declaration_html := ""
	if type.declaration != "" {
		declaration_html = site_code_block_html(site, type.declaration, type.package_name, fmt.tprintf("%s:%d", type.source, type.line))
	}
	site_symbol_write(site, b, Site_Symbol{id = type.id, name = type.name, signature = type.declaration, signature_html = declaration_html, description = type.description, page = site_page_file(SITE_TYPES_FOLDER), facts = facts[:], source = type.source, line = type.line, after_facts_html = strings.to_string(after)})
}

// site_types_page_add adds the page of the types and its line in the index
// of the reference.
site_types_page_add :: proc(site: ^Site, entries: ^[dynamic]Site_Reference_Entry) {
	path := site_page_file(SITE_TYPES_FOLDER)
	counts: [Site_Type_Kind]int
	for type in site.types {
		counts[type.kind] += 1
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "<h1>Types</h1>\n<p>Each type that the pages of the reference show: %d types. The size, the alignment, the offsets and the values come from the compiler, which builds this tool with the contract; the declaration, the text and the line come from the source.</p>\n<p>", len(site.types))
	first := true
	for kind in Site_Type_Kind {
		if counts[kind] == 0 {
			continue
		}
		if !first {
			strings.write_string(&b, ", ")
		}
		first = false
		fmt.sbprintf(&b, "%s: %d", site_type_kind_names[kind], counts[kind])
	}
	strings.write_string(&b, ".</p>\n<p>Wherever a page shows a type, the name of the type opens its card: a click, a tap, or Enter; a pointer that rests on it opens the card too.</p>\n")
	fmt.sbprintf(&b, "<h2 id=\"host-and-target\">The machine of this page and the target</h2>\n<p>The tool runs on %s %s, and its sizes are those of that machine. The system is built for x86-64 with no operating system. A size that the contract asserts with <code>#assert</code> is checked twice: when the tool is built, and when the system is built. A type that holds an address, a slice, a string, <code>int</code> or <code>uintptr</code> says so on its card: its size follows the size of an address of the target, 8 bytes on x86-64.</p>\n", ODIN_OS_STRING, ODIN_ARCH_STRING)

	packages := SITE_TYPE_PACKAGES
	for folder in packages {
		package_name := folder[strings.last_index_byte(folder, '/') + 1:]
		fmt.sbprintf(&b, "<h2 id=\"package-%s\">The package %s</h2>\n", site_slug(package_name), package_name)
		for type in site.types {
			if type.package_name == package_name && type.kind != .Basic && type.kind != .Wire_Form && type.kind != .Module_Record {
				site_type_symbol_write(site, &b, type)
			}
		}
	}
	strings.write_string(&b, "<h2 id=\"wire-forms\">The wire forms of the module contract</h2>\n<p>How a call between modules carries a parameter or a result: the members of <code>Type</code> of the package module. The text of each one is its comment in the contract.</p>\n")
	for type in site.types {
		if type.kind == .Wire_Form {
			site_type_symbol_write(site, &b, type)
		}
	}
	strings.write_string(&b, "<h2 id=\"module-records\">The records of the modules</h2>\n<p>The records that the exports of each module take or give, as the build describes them in the module: the size and the offsets of the description, the size of each field from its wire form.</p>\n")
	for type in site.types {
		if type.kind == .Module_Record {
			site_type_symbol_write(site, &b, type)
		}
	}
	strings.write_string(&b, "<h2 id=\"basic-types\">The basic types</h2>\n")
	for type in site.types {
		if type.kind == .Basic {
			site_type_symbol_write(site, &b, type)
		}
	}
	sources := make([dynamic]string, context.temp_allocator)
	append(&sources, SITE_TYPES_FILE)
	for folder in packages {
		append(&sources, folder)
	}
	site_page_add(site, Site_Page{path = path, title = "Types", description = site_description_cut(fmt.tprintf("The %d types of the contract of %s and of its modules: the size, the alignment, the fields and the members of each, from the compiler.", len(site.types), SITE_SYSTEM_NAME)), section = .Reference, crumbs = site_crumbs(.Reference), body = strings.to_string(b), sources = sources[:], layout = .Documentation})
	append(entries, Site_Reference_Entry{path = path, title = "Types", what = "Each type of the contract and of the modules, with its size, its alignment and its layout.", source = SITE_TYPES_FILE, count = len(site.types), kind = .Type})
}
