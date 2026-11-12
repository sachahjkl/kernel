package kerneltool

import "base:runtime"
import "core:reflect"
import "core:strings"
import "core:testing"
import "contract:errors"
import module "contract:module"
import op "contract:operation"

// A struct whose layout has padding inside and at its end: a u8, three
// bytes, a u32, a u16, two bytes.
@(private = "file")
Test_Layout :: struct {
	first:  u8,
	second: u32,
	third:  u16,
}

@(private = "file")
contract_declarations :: proc(t: ^testing.T) -> []Site_Type_Declaration {
	list := make([dynamic]Site_Type_Declaration, context.temp_allocator)
	packages := SITE_TYPE_PACKAGES
	for folder in packages {
		found, ok := site_type_declarations_read(folder)
		testing.expectf(t, ok, "cannot read the declarations of %s", folder)
		append(&list, ..found)
	}
	return list[:]
}

// The keys of the rows of the table, so that a test finds the type
// information of a declaration.
@(private = "file")
contract_keys :: proc() -> map[typeid]string {
	return site_type_keys_make(site_basic_types(), site_contract_type_rows())
}

// Each declaration of a type of the documented packages has its row, and
// each row names a declaration: a new type of the contract cannot be
// forgotten.
@(test)
site_types_table_is_complete :: proc(t: ^testing.T) {
	declarations := contract_declarations(t)
	testing.expect(t, len(declarations) > 80, "the parser found fewer than 80 declarations of types in the contract")
	rows := site_contract_type_rows()
	problems := site_types_problems(declarations, rows)
	for problem in problems {
		testing.expectf(t, false, "%s", problem)
	}
	// A declaration with no row, and a row with no declaration, are faults.
	missing := []Site_Type_Declaration{{package_name = "operation", name = "Not_A_Type", file = "contract/operation/operation.odin", line = 1}}
	testing.expect(t, len(site_types_problems(missing, rows)) > 0)
	// Two rows of one type.
	twice := make([dynamic]Site_Type_Row, context.temp_allocator)
	append(&twice, ..rows)
	append(&twice, Site_Type_Row{"operation", "Fault_Record", type_info_of(op.Fault_Record)})
	testing.expect(t, len(site_types_problems(declarations, twice[:])) > 0)
	// A named type under a wrong name: the compiler names it Fault_Record.
	wrong := make([dynamic]Site_Type_Row, context.temp_allocator)
	for row in rows {
		if row.package_name == "operation" && row.name == "Fault_Record" {
			append(&wrong, Site_Type_Row{"operation", "Fault_Record", type_info_of(op.Event_Record)})
		} else {
			append(&wrong, row)
		}
	}
	wrong_problems := site_types_problems(declarations, wrong[:])
	testing.expect_value(t, len(wrong_problems), 1)
	if len(wrong_problems) == 1 {
		testing.expect(t, strings.contains(wrong_problems[0], "holds the type information of operation.Event_Record"), wrong_problems[0])
	}
	// Each row of a named type has the name that the compiler gives it; the
	// rows of an alias (the bit sets of the contract) have no name to check.
	aliases := 0
	for row in rows {
		if named, is_named := row.info.variant.(runtime.Type_Info_Named); is_named {
			testing.expectf(t, named.name == row.name && site_type_package_of(named) == row.package_name, "the row %s.%s holds %s.%s", row.package_name, row.name, site_type_package_of(named), named.name)
		} else {
			aliases += 1
		}
	}
	testing.expect(t, aliases > 0, "the contract has aliases (its bit sets); the table must accept them")
	// The parser gives the comment and the line of a declaration.
	for declaration in declarations {
		if declaration.package_name == "operation" && declaration.name == "Time_Record" {
			testing.expect(t, strings.has_prefix(declaration.description, "The record at TIME_ADDRESS"), declaration.description)
			testing.expect(t, strings.has_prefix(declaration.declaration, "Time_Record :: struct {"), declaration.declaration)
			testing.expect(t, declaration.line > 1)
		}
	}
}

// The sizes that the contract asserts with "#assert(size_of(<Name>) ==
// <decimal>)" are the sizes of the cards: the compiler checks the same
// numbers when it builds the system.
@(test)
site_types_sizes_agree_with_the_asserts :: proc(t: ^testing.T) {
	keys := contract_keys()
	sizes := make(map[string]int, context.temp_allocator)
	for row in site_contract_type_rows() {
		type := site_type_from_info(row.info, keys)
		sizes[site_type_row_key(row)] = type.size
	}
	checked := 0
	packages := SITE_TYPE_PACKAGES
	for folder in packages {
		package_name := folder[strings.last_index_byte(folder, '/') + 1:]
		paths, ok := files_with_suffix(folder, ".odin")
		testing.expect(t, ok)
		for path in paths {
			text, read := site_read_quiet(path)
			testing.expect(t, read)
			for line in site_lines(text) {
				if !strings.has_prefix(line, "#assert(size_of(") {
					continue
				}
				rest := line[len("#assert(size_of("):]
				close := strings.index_byte(rest, ')')
				if close < 0 || !strings.has_prefix(rest[close:], ") == ") {
					continue
				}
				name := rest[:close]
				value_text := rest[close + len(") == "):]
				end := strings.index_byte(value_text, ')')
				if end < 0 {
					continue
				}
				value := site_digits_value(value_text[:end])
				if value < 0 || !site_is_identifier(name) {
					continue // A size that is a constant, or a type of another form: the compiler checks it.
				}
				key := strings.concatenate({package_name, ".", name}, context.temp_allocator)
				size, found := sizes[key]
				testing.expectf(t, found, "%s asserts the size of %s, which has no row", path, key)
				testing.expectf(t, size == value, "%s: the contract asserts %d bytes for %s, the card says %d", path, value, key, size)
				checked += 1
			}
		}
	}
	testing.expect(t, checked >= 15, "fewer than 15 sizes asserted with a number in the contract")
	// Pinned: the records that the kernel and the programs share.
	testing.expect_value(t, sizes["operation.Fault_Record"], 64)
	testing.expect_value(t, sizes["operation.Event_Rule"], 64)
	testing.expect_value(t, sizes["operation.Event_Record"], 64)
	testing.expect_value(t, sizes["operation.Module_Record"], 80)
	testing.expect_value(t, sizes["errors.Error_Record"], 56)
	testing.expect_value(t, sizes["module.Table_Place"], 24)
	testing.expect_value(t, sizes["module.Function"], 104)
}

// The rows of a struct: each field at its offset, a row of padding for each
// run of unused bytes, and the sizes of the rows add up to the size.
@(test)
site_type_card_of_a_struct :: proc(t: ^testing.T) {
	keys := make(map[typeid]string, context.temp_allocator)
	keys[u32] = "basic.u32"
	type := site_type_from_info(type_info_of(Test_Layout), keys)
	testing.expect_value(t, type.kind, Site_Type_Kind.Struct)
	testing.expect_value(t, type.size, 12)
	testing.expect_value(t, type.alignment, 4)
	testing.expect_value(t, type.padding, 5)
	testing.expect_value(t, len(type.fields), 5)
	if len(type.fields) == 5 {
		testing.expect(t, type.fields[0].name == "first" && type.fields[0].offset == 0 && type.fields[0].size == 1)
		testing.expect(t, type.fields[1].is_padding && type.fields[1].offset == 1 && type.fields[1].size == 3)
		testing.expect(t, type.fields[2].name == "second" && type.fields[2].offset == 4 && type.fields[2].type_key == "basic.u32")
		testing.expect(t, type.fields[3].name == "third" && type.fields[3].offset == 8 && type.fields[3].size == 2)
		testing.expect(t, type.fields[4].is_padding && type.fields[4].offset == 10 && type.fields[4].size == 2)
	}
	// Each struct of the contract: the rows cover its bytes once.
	keys = contract_keys()
	for row in site_contract_type_rows() {
		contract_type := site_type_from_info(row.info, keys)
		if contract_type.kind != .Struct {
			continue
		}
		total := 0
		for field in contract_type.fields {
			total += field.size
		}
		testing.expectf(t, total == contract_type.size, "%s: its rows have %d bytes, its size is %d", contract_type.name, total, contract_type.size)
	}
	testing.expect_value(t, site_type_target_dependence(type_info_of(module.Bound_Import)), "[]u8")
	testing.expect_value(t, site_type_target_dependence(type_info_of(op.Fault_Record)), "")
}

// The members of an enum and the bits of a bit set, from the compiler.
@(test)
site_type_card_of_an_enum :: proc(t: ^testing.T) {
	keys := make(map[typeid]string, context.temp_allocator)
	keys[u8] = "basic.u8"
	kind := site_type_from_info(type_info_of(op.Object_Kind), keys)
	testing.expect_value(t, kind.kind, Site_Type_Kind.Enum)
	testing.expect_value(t, kind.base_text, "u8")
	testing.expect_value(t, kind.base_key, "basic.u8")
	found := false
	for member in kind.members {
		found ||= member.name == "Machine" && member.value == 5
	}
	testing.expect(t, found, "Object_Kind.Machine is 5")
	// Rights is an alias of a bit set: its kind is the kind of what it
	// names, and its card says that it is an alias. Its bits are those that
	// the compiler gives for Right: the contract adds rights.
	rights := site_type_from_info(type_info_of(op.Rights), keys)
	testing.expect_value(t, rights.kind, Site_Type_Kind.Bit_Set)
	testing.expect_value(t, rights.element_text, "Right")
	testing.expect_value(t, rights.size, size_of(op.Rights))
	testing.expect(t, strings.has_prefix(rights.alias_of, "bit_set[Right"), rights.alias_of)
	testing.expect(t, strings.contains(site_type_summary(nil, rights), "An alias of bit_set[Right"), site_type_summary(nil, rights))
	right_names := reflect.enum_field_names(op.Right)
	right_values := reflect.enum_field_values(op.Right)
	testing.expect_value(t, len(rights.members), len(right_names))
	for member, index in rights.members {
		if index >= len(right_names) {
			break
		}
		testing.expectf(t, member.name == right_names[index] && member.value == i64(right_values[index]), "bit %d of Rights: the card has %s at %d, the compiler %s at %d", index, member.name, member.value, right_names[index], i64(right_values[index]))
	}
	give_bit := false
	for member in rights.members {
		give_bit ||= member.name == "Give" && member.value == 0
	}
	testing.expect(t, give_bit, "Rights has the bit 0, Give")
	// A named type is not an alias.
	testing.expect_value(t, kind.alias_of, "")
	end := site_type_from_info(type_info_of(errors.End), keys)
	testing.expect_value(t, end.kind, Site_Type_Kind.Enum)
	testing.expect_value(t, site_type_hexadecimal(-1, 1), "0xFF")
	testing.expect_value(t, site_type_hexadecimal(12, 4), "0xC")
	handle := site_type_from_info(type_info_of(op.Handle), keys)
	testing.expect_value(t, handle.kind, Site_Type_Kind.Distinct)
	testing.expect_value(t, handle.base_text, "u32")
}

// A site with a few types: the wire forms Integer, Text and Table, a record
// of a module, an alias of a bit set and a struct of the package operation.
// Each slice that a type keeps is made in the temporary allocator: a slice
// literal of this procedure lives in its frame, which ends at its return.
@(private = "file")
site_with_types :: proc() -> Site {
	site := test_site()
	site.types = make([dynamic]Site_Type, context.temp_allocator)
	site.type_keys = make(map[string]int, context.temp_allocator)
	site.type_ids = make(map[string]int, context.temp_allocator)
	for key in ([]string{"wire.Integer", "wire.Text", "wire.Table"}) {
		site_type_add(&site, Site_Type{key = key, id = site_type_key_id(key), name = key[len("wire."):], kind = .Wire_Form, size = -1, alignment = -1, description = "A form. More."})
	}
	site_type_add(&site, Site_Type{key = "record.draw.Rectangle", id = site_type_key_id("record.draw.Rectangle"), name = "Rectangle", package_name = "draw", kind = .Module_Record, size = 16, alignment = 4})
	members := make([]Site_Type_Member, 2, context.temp_allocator)
	members[0] = {name = "Write", value = 0}
	members[1] = {name = "Execute", value = 1}
	site_type_add(&site, Site_Type{key = "operation.Memory_Flags", id = site_type_key_id("operation.Memory_Flags"), name = "Memory_Flags", package_name = "operation", kind = .Bit_Set, alias_of = "bit_set[Memory_Flag; u64]", element_text = "Memory_Flag", size = 8, alignment = 8, members = members})
	fields := make([]Site_Type_Field, 3, context.temp_allocator)
	fields[0] = {name = "first", type_text = "u64", offset = 0, size = 8}
	fields[1] = {name = "count", type_text = "u32", offset = 8, size = 4}
	fields[2] = {name = "padding", offset = 12, size = 4, is_padding = true}
	site_type_add(&site, Site_Type{key = "operation.Test_Pair", id = site_type_key_id("operation.Test_Pair"), name = "Test_Pair", package_name = "operation", kind = .Struct, size = 16, alignment = 8, padding = 4, fields = fields})
	return site
}

// A reference names the card of its type, and the page holds one card for
// each type, whatever the count of its references.
@(test)
site_type_references_and_cards :: proc(t: ^testing.T) {
	site := site_with_types()
	testing.expect_value(t, site_type_key_id("wire.Table"), "type-wire-table")
	reference := site_type_reference_html(&site, "wire.Table", "Table", false)
	testing.expect_value(t, reference, "<button type=\"button\" class=\"type-reference\" popovertarget=\"card-type-wire-table\" popovertargetaction=\"show\" aria-describedby=\"card-type-wire-table-summary\">Table</button>")
	// A type with no card: plain text of the kind Type, counted, with no
	// reference; also with no types at all.
	before := site.type_names_without_card
	testing.expect_value(t, site_type_reference_html(&site, "wire.Nothing", "Nothing", false), "<code class=\"value value-type\">Nothing</code>")
	testing.expect_value(t, site_type_reference_html(&site, "", "[16]u8", true), "<code class=\"value value-type\">[16]u8</code>")
	testing.expect_value(t, site.type_names_without_card, before + 2)
	empty: Site
	testing.expect_value(t, site_type_reference_html(&empty, "wire.Table", "Table", false), "<code class=\"value value-type\">Table</code>")
	testing.expect_value(t, site_type_cards_html(&empty, site_page_file(SITE_OPERATIONS_FOLDER), reference), "")

	page := site_page_file(SITE_OPERATIONS_FOLDER)
	body := strings.concatenate({"<h1>Page</h1>\n<p>", reference, " ", reference, " ", site_type_reference_html(&site, "operation.Memory_Flags", "Memory_Flags", true), " ", site_type_reference_html(&site, "operation.Test_Pair", "Test_Pair", true), "</p>\n"}, context.temp_allocator)
	cards := site_type_cards_html(&site, page, body)
	testing.expect_value(t, strings.count(cards, "<div class=\"type-card\""), 3)
	testing.expect_value(t, strings.count(cards, "id=\"card-type-wire-table\""), 1)
	testing.expect(t, strings.contains(cards, "id=\"card-type-wire-table-summary\">A wire form of the module contract: one register of a call. A form.</p>"), cards)
	testing.expect(t, strings.contains(cards, "<a href=\"../../reference/types/index.html#type-operation-memory-flags\"><code>Memory_Flags</code></a>"), cards)
	testing.expect(t, strings.contains(cards, "An alias of bit_set[Memory_Flag; u64]."), cards)
	testing.expect(t, strings.contains(cards, "<li><code>Execute</code><span>bit 1</span></li>"), cards)
	testing.expect(t, strings.contains(cards, "<li class=\"padding\">"), cards)
	html := strings.concatenate({body, cards}, context.temp_allocator)
	ids := make(map[string]bool, context.temp_allocator)
	for id in site_attribute_values(html, "id=\"") {
		ids[id] = true
	}
	testing.expect_value(t, site_type_cards_problem(html, ids), "")

	// A reference whose card the page does not hold, and two cards with one id.
	dangling := strings.concatenate({body, "<p><button type=\"button\" class=\"type-reference\" popovertarget=\"card-type-gone\">Gone</button></p>"}, context.temp_allocator)
	testing.expect(t, site_type_cards_problem(dangling, ids) != "")
	twice := strings.concatenate({html, cards}, context.temp_allocator)
	testing.expect(t, site_type_cards_problem(twice, ids) != "")
	// A page with no reference has no card.
	testing.expect_value(t, site_type_cards_html(&site, page, "<h1>Page</h1>"), "")
}

// The signatures: each type is a reference, and the text of the signature
// is the text that the console prints.
@(test)
site_signatures_with_type_references :: proc(t: ^testing.T) {
	site := site_with_types()
	description := Module_Description{records = []Record_Description{{name = "Rectangle", size = 16}}}
	export := Export_Description{name = "fill", parameters = []module.Type{.Table, .Text}, names = []string{"rows", "name"}, details = []u32{1, 0}, directions = []module.Direction{.Change, .Read}, result = .Integer}
	html := site_export_signature_html(&site, "draw", description, export)
	testing.expect(t, strings.contains(html, "popovertarget=\"card-type-wire-table\""), html)
	testing.expect(t, strings.contains(html, "popovertarget=\"card-type-record-draw-rectangle\""), html)
	testing.expect(t, strings.contains(html, "popovertarget=\"card-type-wire-integer\""), html)
	testing.expect_value(t, site_html_unescape(site_tags_removed(html)), site_export_signature(description, export))

	member := Site_Enumeration_Member{name = "Memory_Create", number = 2, comment = "(budget, page_count, Memory_Flags) -> memory handle. The memory is zero."}
	operation := site_operation_parts(member)
	operation_html := site_operation_signature_html(&site, operation)
	// The attributes of the button follow popovertarget: the name ends it.
	testing.expect(t, strings.contains(operation_html, "popovertarget=\"card-type-operation-memory-flags\""), operation_html)
	testing.expect(t, strings.contains(operation_html, "aria-describedby=\"card-type-operation-memory-flags-summary\">Memory_Flags</button>"), operation_html)
	// The words that name no type stay words: no count of a type with no card.
	testing.expect(t, !strings.contains(operation_html, "value-type"), operation_html)
	testing.expect_value(t, site_html_unescape(site_tags_removed(operation_html)), "Memory_Create(budget, page_count, Memory_Flags) -> memory handle")
	testing.expect_value(t, site_operation_signature_html(&site, site_operation_parts(Site_Enumeration_Member{name = "None", comment = "No form."})), "")

	command := Site_Console_Command{name = "repeat", parameters = []string{"Text", "Integer"}, result = "Text"}
	command_html := site_console_signature_html(&site, command)
	testing.expect_value(t, site_html_unescape(site_tags_removed(command_html)), site_console_signature(command))
	testing.expect(t, strings.contains(command_html, "popovertarget=\"card-type-wire-integer\""), command_html)

	// The symbol writes the signature with its references.
	b := strings.builder_make(context.temp_allocator)
	site_symbol_write(&site, &b, Site_Symbol{id = "export-fill", name = "fill", signature = site_export_signature(description, export), signature_html = html})
	testing.expect(t, strings.contains(strings.to_string(b), strings.concatenate({"<pre class=\"signature\"><code>", html, "</code></pre>"}, context.temp_allocator)))
}

// The types of the repository: each one has its own id, the page of the
// types holds each one as a symbol, and the cards of its page and of the
// page of the operations pass the check.
@(test)
site_types_of_the_repository :: proc(t: ^testing.T) {
	site := test_site()
	if !site_reference_read(&site) {
		testing.expect(t, false, "the sources of the reference cannot be read")
		return
	}
	ids := make(map[string]bool, context.temp_allocator)
	for type in site.types {
		testing.expectf(t, type.id not_in ids, "two types have the id %s", type.id)
		ids[type.id] = true
	}
	_, has_fault_record := site.type_keys["operation.Fault_Record"]
	_, has_table := site.type_keys["wire.Table"]
	_, has_u64 := site.type_keys["basic.u64"]
	testing.expect(t, has_fault_record && has_table && has_u64)
	entries := make([dynamic]Site_Reference_Entry, context.temp_allocator)
	site_generated_tables_add(&site, &entries)
	checked := 0
	for page in site.pages {
		if page.path != site_page_file(SITE_TYPES_FOLDER) && page.path != site_page_file(SITE_OPERATIONS_FOLDER) {
			continue
		}
		html := strings.concatenate({page.body, site_type_cards_html(&site, page.path, page.body)}, context.temp_allocator)
		page_ids := make(map[string]bool, context.temp_allocator)
		for id in site_attribute_values(html, "id=\"") {
			page_ids[id] = true
		}
		testing.expectf(t, site_type_cards_problem(html, page_ids) == "", "%s: %s", page.path, site_type_cards_problem(html, page_ids))
		testing.expectf(t, site_heading_value_problem(page.body) == "", "%s marks a value in a heading", page.path)
		checked += 1
		if page.path == site_page_file(SITE_TYPES_FOLDER) {
			testing.expect(t, strings.contains(page.body, "<h3 id=\"type-operation-fault-record\" data-outline=\"Fault_Record\">"))
			testing.expect(t, strings.contains(page.body, "aria-label=\"Fields of Fault_Record\""))
		} else {
			testing.expect(t, strings.contains(page.body, "class=\"type-reference\""), "the page of the operations shows no type as a reference")
		}
	}
	testing.expect_value(t, checked, 2)
}
