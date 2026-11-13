package kerneltool

import "core:reflect"
import "core:slice"
import "core:strings"
import "core:testing"
import "contract:errors"
import "contract:fixed_addresses"
import module "contract:module"
import op "contract:operation"
import "contract:start_grant"

@(private = "file")
read_text :: proc(t: ^testing.T, path: string) -> string {
	text, ok := site_read_quiet(path)
	testing.expectf(t, ok, "cannot read %s", path)
	return text
}

// The members that the reader finds are those that the compiler knows, with
// the same names and values, in the same order.
@(private = "file")
expect_members_of :: proc(t: ^testing.T, members: []Site_Enumeration_Member, type: typeid) {
	names := reflect.enum_field_names(type)
	values := reflect.enum_field_values(type)
	testing.expectf(t, len(members) == len(names), "the reader found %d members of %v, the compiler knows %d", len(members), type, len(names))
	for member, index in members {
		if index >= len(names) {
			break
		}
		testing.expectf(t, member.name == names[index] && i64(member.number) == i64(values[index]), "member %d of %v: the reader has %s = %d, the compiler %s = %d", index, type, member.name, member.number, names[index], i64(values[index]))
	}
}

@(test)
site_operations_of_the_repository :: proc(t: ^testing.T) {
	text := read_text(t, SITE_OPERATION_FILE)
	members, problem := site_enumeration_read(text, SITE_OPERATION_FILE, "Operation")
	testing.expect_value(t, problem, "")
	expect_members_of(t, members, op.Operation)
	for member in members {
		if member.name != "Memory_Map" {
			continue
		}
		operation := site_operation_parts(member)
		testing.expect(t, strings.has_prefix(operation.parameters, "memory, program, address"))
		testing.expect_value(t, operation.result, "address")
	}
	statuses, status_problem := site_enumeration_read(text, SITE_OPERATION_FILE, "Status")
	testing.expect_value(t, status_problem, "")
	expect_members_of(t, statuses, op.Status)
}

@(test)
site_errors_of_the_repository :: proc(t: ^testing.T) {
	text := read_text(t, SITE_ERRORS_FILE)
	kinds, kinds_problem := site_enumeration_read(text, SITE_ERRORS_FILE, "Kind")
	testing.expect_value(t, kinds_problem, "")
	expect_members_of(t, kinds, errors.Kind)
	units, units_problem := site_enumeration_read(text, SITE_ERRORS_FILE, "Unit")
	testing.expect_value(t, units_problem, "")
	expect_members_of(t, units, errors.Unit)
	names, names_problem := site_names_read(text, SITE_ERRORS_FILE, "UNIT_NAMES")
	testing.expect_value(t, names_problem, "")
	testing.expect_value(t, len(names), len(units))
	testing.expect_value(t, names["Pages"], "pages")
}

@(test)
site_fixed_ranges_of_the_repository :: proc(t: ^testing.T) {
	text := read_text(t, SITE_FIXED_ADDRESSES_FILE)
	ranges, problem := site_enumeration_read(text, SITE_FIXED_ADDRESSES_FILE, "Fixed_Range")
	testing.expect_value(t, problem, "")
	expect_members_of(t, ranges, fixed_addresses.Fixed_Range)
}

@(test)
site_context_of_the_repository :: proc(t: ^testing.T) {
	text := read_text(t, SITE_OPERATION_FILE)
	roles, problem := site_constants_read(text, SITE_OPERATION_FILE, "CONTEXT_HANDLES ::", {"CONTEXT_", "ROOT_"})
	testing.expect_value(t, problem, "")
	found_log, found_machine := false, false
	for role in roles {
		if role.name == "CONTEXT_LOG" {
			found_log = role.value == op.CONTEXT_LOG && strings.contains(role.comment, "The log of the kernel")
		}
		if role.name == "ROOT_MACHINE" {
			found_machine = role.value == op.ROOT_MACHINE
		}
		testing.expectf(t, role.name != "CONTEXT_ADDRESS", "CONTEXT_ADDRESS is an address, not a role")
	}
	testing.expect(t, found_log && found_machine, "CONTEXT_LOG or ROOT_MACHINE is absent, or has another value")
}

@(test)
site_grants_of_the_repository :: proc(t: ^testing.T) {
	grants_text := read_text(t, SITE_SYSTEM_GRANTS_FILE)
	recorded, recorded_problem := site_enumeration_read(grants_text, SITE_SYSTEM_GRANTS_FILE, "Root_Grant")
	testing.expect_value(t, recorded_problem, "")
	names, names_problem := site_names_read(grants_text, SITE_SYSTEM_GRANTS_FILE, "root_grant_names")
	testing.expect_value(t, names_problem, "")
	for grant in recorded {
		testing.expectf(t, names[grant.name] != "", "the grant %s has no name in root_grant_names", grant.name)
	}
	root_text := read_text(t, SITE_ROOT_FILE)
	start_grant_text := read_text(t, SITE_START_GRANT_FILE)
	at_start, start_problem := site_enumeration_read(start_grant_text, SITE_START_GRANT_FILE, "Grant")
	testing.expect_value(t, start_problem, "")
	testing.expect(t, len(at_start) > 0 && at_start[0].name == "Root_Ring")
	// The number of a start grant is in an error record: the site shows the
	// number that the contract writes, and the name that a sentence writes.
	for grant in at_start {
		name, known := start_grant.grant_name(i64(grant.number))
		testing.expectf(t, known && name == grant.name, "the start grant %s has the number %d, which grant_name names %q", grant.name, grant.number, name)
	}
	testing.expect_value(t, len(at_start), len(start_grant.Grant))
	cases, otherwise, cases_problem := site_name_switch_read(root_text, SITE_ROOT_FILE, "grants_of")
	testing.expect_value(t, cases_problem, "")
	testing.expect_value(t, otherwise.value, "{}")
	testing.expect_value(t, len(otherwise.members), 0)
	console, named := site_case_of(cases, otherwise, "console")
	testing.expect(t, named && strings.has_prefix(console.value, "{.Root_Ring"))
	testing.expect(t, len(console.members) > 1 && console.members[0] == "Root_Ring", "a set is read as its members, with no period")
	inspect, inspect_named := site_case_of(cases, otherwise, "inspect")
	testing.expect(t, inspect_named && strings.contains(inspect.comment, "A developer tool"), "the comment lines between a case and its return are its comment")
	// A case of several programs is one case with each name.
	pages, pages_named := site_case_of(cases, otherwise, "pages")
	processors, _ := site_case_of(cases, otherwise, "processors")
	testing.expect(t, pages_named && pages.line == processors.line && len(pages.names) > 1)
	testing.expect_value(t, site_name_cases_problem(cases, otherwise, SITE_ROOT_FILE, "grants_of", at_start, true), "")
	budgets, budget_otherwise, budgets_problem := site_name_switch_read(root_text, SITE_ROOT_FILE, "things_of")
	testing.expect_value(t, budgets_problem, "")
	testing.expect(t, len(budgets) > 0 && strings.has_prefix(budget_otherwise.value, "{pages = "))
	testing.expect(t, len(budget_otherwise.fields) == 3 && budget_otherwise.fields[0].name == "pages", "a record is read as its fields")
	testing.expect_value(t, site_name_cases_problem(budgets, budget_otherwise, SITE_ROOT_FILE, "things_of", nil, false), "")
}

// The reader of the cases of the root service reads the tree of the parser:
// each form that a page cannot show as values stops it, with the line.
@(test)
site_name_switch_refuses_another_form :: proc(t: ^testing.T) {
	head :: "package root\n\nGrant :: enum {A, B}\n\n"
	good := head + "grants_of :: proc(name: string) -> bit_set[Grant] {\n\tswitch name {\n\tcase \"one\", \"two\":\n\t\t// The first line,\n\t\t// and the second.\n\t\treturn {.A, .B} // Its own.\n\t}\n\treturn {}\n}\n"
	cases, otherwise, problem := site_name_switch_read(good, "file.odin", "grants_of")
	testing.expect_value(t, problem, "")
	if len(cases) == 1 {
		testing.expect_value(t, len(cases[0].names), 2)
		testing.expect_value(t, cases[0].value, "{.A, .B}")
		testing.expect_value(t, cases[0].line, 10)
		testing.expect_value(t, cases[0].comment, "The first line,\nand the second.\nIts own.")
	}
	testing.expect_value(t, otherwise.line, 12)
	// A set written on several lines is the same set.
	wrapped := head + "grants_of :: proc(name: string) -> bit_set[Grant] {\n\tswitch name {\n\tcase \"one\":\n\t\treturn {\n\t\t\t.A,\n\t\t\t.B,\n\t\t}\n\t}\n\treturn {}\n}\n"
	wrapped_cases, _, wrapped_problem := site_name_switch_read(wrapped, "file.odin", "grants_of")
	testing.expect_value(t, wrapped_problem, "")
	testing.expect(t, len(wrapped_cases) == 1 && len(wrapped_cases[0].members) == 2)
	forms := [?]string {
		// A set from a constant: the page cannot name its members.
		head + "SET :: bit_set[Grant]{.A}\ngrants_of :: proc(name: string) -> bit_set[Grant] {\n\tswitch name {\n\tcase \"one\":\n\t\treturn SET\n\t}\n\treturn {}\n}\n",
		// A literal with its type.
		head + "grants_of :: proc(name: string) -> bit_set[Grant] {\n\tswitch name {\n\tcase \"one\":\n\t\treturn bit_set[Grant]{.A}\n\t}\n\treturn {}\n}\n",
		// A union of two sets.
		head + "grants_of :: proc(name: string) -> bit_set[Grant] {\n\tswitch name {\n\tcase \"one\":\n\t\treturn {.A} + {.B}\n\t}\n\treturn {}\n}\n",
		// A case with no return of its own.
		head + "grants_of :: proc(name: string) -> bit_set[Grant] {\n\tswitch name {\n\tcase \"a\":\n\tcase \"b\":\n\t\treturn {}\n\t}\n\treturn {}\n}\n",
		// A default case in the switch.
		head + "grants_of :: proc(name: string) -> bit_set[Grant] {\n\tswitch name {\n\tcase \"a\":\n\t\treturn {.A}\n\tcase:\n\t\treturn {.B}\n\t}\n\treturn {}\n}\n",
		// No return after the switch.
		head + "grants_of :: proc(name: string) -> bit_set[Grant] {\n\tswitch name {\n\tcase \"a\":\n\t\treturn {.A}\n\t}\n\tpanic(\"\")\n}\n",
	}
	for form, index in forms {
		_, _, refused := site_name_switch_read(form, "file.odin", "grants_of")
		testing.expectf(t, strings.has_prefix(refused, "file.odin, line "), "form %d: the reader accepts it, or gives no line: %q", index, refused)
	}
	_, _, absent := site_name_switch_read(head, "file.odin", "grants_of")
	testing.expect(t, strings.contains(absent, "no procedure"), absent)
	// A member that the enumeration does not have, and a record where a set is.
	grant_members := []Site_Enumeration_Member{{name = "A"}, {name = "B"}}
	unknown := []Site_Name_Case{{names = {"one"}, value = "{.C}", members = {"C"}, line = 7}}
	testing.expect(t, strings.has_prefix(site_name_cases_problem(unknown, {value = "{}"}, "file.odin", "grants_of", grant_members, true), "file.odin, line 7:"))
	record := []Site_Name_Case{{names = {"one"}, value = "{pages = 1}", fields = {{name = "pages", value = "1"}}, line = 8}}
	testing.expect(t, strings.has_prefix(site_name_cases_problem(record, {value = "{}"}, "file.odin", "grants_of", grant_members, true), "file.odin, line 8:"))
}

// A set of grants is a list of values: each grant one link to its row in
// the first table of the page of the grants, with no brace, no period and
// no comma.
@(test)
site_grant_set_is_a_list_of_values :: proc(t: ^testing.T) {
	site := test_site()
	b := strings.builder_make(context.temp_allocator)
	site_grant_set_write(&site, &b, site_page_file(SITE_GRANTS_FOLDER), {"Root_Ring", "Debug_Image"}, false)
	html := strings.to_string(b)
	testing.expect_value(t, html, "<ul class=\"value-list\"><li><a href=\"#start-grant-root-ring\"><code class=\"value value-grant\">Root_Ring</code></a></li><li><a href=\"#start-grant-debug-image\"><code class=\"value value-grant\">Debug_Image</code></a></li></ul>")
	from_module := strings.builder_make(context.temp_allocator)
	site_grant_set_write(&site, &from_module, site_module_page("console"), {"Store"}, true)
	testing.expect(t, strings.contains(strings.to_string(from_module), "grants/index.html#start-grant-store\""), strings.to_string(from_module))
	none := strings.builder_make(context.temp_allocator)
	site_grant_set_write(&site, &none, site_page_file(SITE_GRANTS_FOLDER), {}, false)
	testing.expect_value(t, strings.to_string(none), "none")
}

@(test)
site_console_commands_of_the_repository :: proc(t: ^testing.T) {
	all := make([dynamic]Site_Console_Command, context.temp_allocator)
	files := SITE_CONSOLE_COMMAND_FILES
	for file in files {
		commands, problem := site_console_commands_read(read_text(t, file), file)
		testing.expect_value(t, problem, "")
		append(&all, ..commands)
	}
	signatures := make(map[string]string, context.temp_allocator)
	for command in all {
		testing.expectf(t, command.about != "", "the command %s has no help", command.name)
		signatures[command.name] = site_console_signature(command)
	}
	testing.expect_value(t, signatures["help"], "help() -> Table")
	testing.expect_value(t, signatures["repeat"], "repeat(Text, Integer) -> Text")
	testing.expect_value(t, signatures["where"], "where(Table, Text, Value) -> Table")
	// Each built-in command has its documentation above its line: the help
	// alone is one line, too short for a reader of the site.
	for command in all {
		testing.expectf(t, command.documentation != "", "the command %s has no comment above its line", command.name)
	}
}

@(test)
site_readers_refuse_a_damaged_file :: proc(t: ^testing.T) {
	_, no_end := site_enumeration_read("Thing :: enum u8 {\n\tA = 0,\n", "file.odin", "Thing")
	testing.expect(t, strings.contains(no_end, "no line \"}\""), no_end)
	_, hexadecimal := site_enumeration_read("Thing :: enum u8 {\n\tA = 0x10,\n}\n", "file.odin", "Thing")
	testing.expect(t, strings.has_prefix(hexadecimal, "file.odin, line 2:"), hexadecimal)
	_, absent := site_enumeration_read("Other :: enum u8 {\n\tA,\n}\n", "file.odin", "Thing")
	testing.expect(t, absent != "")
	_, constant := site_constants_read("ROLE_A :: 1\nROLE_B :: 1 << 3\n", "file.odin", "", {"ROLE_"})
	testing.expect(t, strings.has_prefix(constant, "file.odin, line 2:"), constant)
	_, name := site_names_read("NAMES := [Thing]string {\n\t.A = 7,\n}\n", "file.odin", "NAMES")
	testing.expect(t, strings.has_prefix(name, "file.odin, line 2:"), name)
	_, command := site_console_commands_read("\tcommand(\"help\", {}, .None, help)\n", "file.odin")
	testing.expect(t, strings.has_prefix(command, "file.odin, line 1:"), command)
	// The case "a" has no return of its own: the reader names its line.
	_, _, no_return := site_name_switch_read("package root\ngrants_of :: proc(name: string) {\n\tswitch name {\n\tcase \"a\":\n\tcase \"b\":\n\t\treturn {}\n\t}\n\treturn {}\n}\n", "file.odin", "grants_of")
	testing.expect(t, strings.has_prefix(no_return, "file.odin, line 4:"), no_return)
}

@(test)
site_readers_of_small_files :: proc(t: ^testing.T) {
	members, problem := site_enumeration_read("Thing :: enum u8 {\n\tA = 4, // The first\n\t// and its second line.\n\tB, // \"//\" in a comment.\n}\n", "file.odin", "Thing")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(members), 2)
	if len(members) == 2 {
		testing.expect_value(t, members[0].comment, "The first\nand its second line.")
		testing.expect_value(t, members[1].number, 1)
		testing.expect_value(t, members[1].line, 4)
	}
	constants, constants_problem := site_constants_read("// Above,\n// two lines.\nROLE_A :: 3 // Its own.\nOTHER :: 0x10\n", "file.odin", "", {"ROLE_"})
	testing.expect_value(t, constants_problem, "")
	testing.expect(t, len(constants) == 1 && constants[0].comment == "Above,\ntwo lines.\nIts own." && constants[0].value == 3)
	commands, commands_problem := site_console_commands_read("\tcommand(\"say\", {.Text, .None}, .Text, \"a \\\"quoted\\\" help\", say)\n\n\t// Its first line.\n\t//\n\t// - `item`: a list.\n\tcommand(\"hear\", {}, .None, \"help\", hear)\n", "file.odin")
	testing.expect_value(t, commands_problem, "")
	testing.expect_value(t, len(commands), 2)
	if len(commands) == 2 {
		testing.expect_value(t, commands[0].about, "a \"quoted\" help")
		testing.expect_value(t, site_console_signature(commands[0]), "say(Text, Value) -> Text")
		testing.expect_value(t, commands[0].documentation, "")
		testing.expect_value(t, commands[1].documentation, "Its first line.\n\n- `item`: a list.")
	}
	operation := site_operation_parts(Site_Enumeration_Member{name = "Do", comment = "(a, b (or 0)) -> the count. More text."})
	testing.expect_value(t, operation.parameters, "a, b (or 0)")
	testing.expect_value(t, operation.result, "the count")
	testing.expect_value(t, operation.text, "More text.")
	no_result := site_operation_parts(Site_Enumeration_Member{name = "Go", comment = "(program, entry): the first thread."})
	testing.expect_value(t, no_result.result, "")
	testing.expect_value(t, no_result.text, "the first thread.")
}

@(test)
site_property_names_in_a_text :: proc(t: ^testing.T) {
	testing.expect(t, slice.equal(site_property_numbers("Property 19 is not complete (P17); see property 9.", 21), []int{19, 17, 9}))
	testing.expect_value(t, len(site_property_numbers("properties 3 and 4, P256, HTTP2, property 30", 21)), 0)
	testing.expect_value(t, len(site_property_numbers("the property 12a", 21)), 0)
}

@(test)
site_gaps_of_the_repository :: proc(t: ^testing.T) {
	gaps, problem := site_gaps_read(read_text(t, SITE_MILESTONE_FILE))
	testing.expect_value(t, problem, "")
	testing.expect(t, len(gaps) > 10)
	groups := make(map[string]bool, context.temp_allocator)
	for gap, index in gaps {
		testing.expect_value(t, gap.number, index + 1)
		groups[gap.group] = true
	}
	testing.expect(t, groups["Performance"] && groups["Input"], "the groups of the gaps are the lines \"Performance:\" and \"Input:\"")
	_, damaged := site_gaps_read("# Title\n\n## Gaps\n\nNo item.\n\n## Next steps\n")
	testing.expect(t, damaged != "")
}

@(test)
site_type_text_as_the_console :: proc(t: ^testing.T) {
	description := Module_Description{records = []Record_Description{{name = "Rectangle"}}}
	testing.expect_value(t, site_type_text(description, .Handle, transmute(u32)op.Rights{.Read, .Write}, .Read, true), "Handle(Read, Write)")
	testing.expect_value(t, site_type_text(description, .Table, 1, .Change, true), "Table(Rectangle, Change)")
	testing.expect_value(t, site_type_text(description, .Table, 1, .Read, false), "Table(Rectangle)")
	testing.expect_value(t, site_type_text(description, .Record, 1, .Read, false), "Rectangle")
	export := Export_Description{name = "write", parameters = []module.Type{.Text, .Text}, names = []string{"name", "data"}, details = []u32{0, 0}, directions = []module.Direction{.Read, .Read}, result = .Integer}
	testing.expect_value(t, site_export_signature(description, export), "write(name: Text, data: Text) -> Integer")
}

// Each module of module_builds has a page, the code spans of the guides find
// their rows, and a name of two tables links nowhere.
@(test)
site_reference_of_the_repository :: proc(t: ^testing.T) {
	site: Site
	testing.expect(t, site_reference_read(&site))
	testing.expect_value(t, len(site.reference.modules), len(module_builds))
	pages := make(map[string]bool, context.temp_allocator)
	for item in site.reference.modules {
		testing.expectf(t, item.page == site_module_page(item.build.name) && item.page not_in pages, "the module %s has no page of its own", item.build.name)
		pages[item.page] = true
		testing.expectf(t, item.description.about != "", "the module %s has no purpose", item.build.name)
	}
	target, found := site_code_link(&site, "Memory_Map")
	testing.expect(t, found && target == "docs/reference/operations/index.html#operation-memory-map", target)
	_, ambiguous := site_code_link(&site, "Bad_Address")
	testing.expect(t, !ambiguous, "Bad_Address is a status and an error kind: it links nowhere")
	command, command_found := site_code_link(&site, "load(\"math\")")
	testing.expect(t, command_found && command == "docs/reference/console/index.html#command-load", command)
	_, spaced := site_code_link(&site, "Memory_Map and more")
	testing.expect(t, !spaced)
	math_page, math_found := site_code_link(&site, "math")
	testing.expect(t, math_found && math_page == site_module_page("math"), math_page)
	testing.expect_value(t, site_module_page("math"), "docs/reference/modules/math/index.html")
}

@(test)
site_demonstrations_of_the_repository :: proc(t: ^testing.T) {
	rows, removals, problem := site_demonstrations_read(read_text(t, SITE_DEMONSTRATIONS_FILE))
	testing.expect_value(t, problem, "")
	// One row for each property, in order, each with a state and a text.
	testing.expect_value(t, len(rows), 21)
	for row, index in rows {
		testing.expect_value(t, row.number, index + 1)
		testing.expectf(t, row.state != "" && row.shown != "" && row.missing != "", "the row of the property %d has an empty cell", row.number)
	}
	testing.expect(t, len(removals) > 0)
}

@(test)
site_demonstrations_of_a_small_file :: proc(t: ^testing.T) {
	text := "## The table\n\n| # | Property | State | Shows | Picture | Not shown |\n|---|---|---|---|---|---|\n| 1 | Small | Shown | It runs | `rights`, `errors` | — |\n\n## What removes each part\n\n1. Property 1: a check.\n"
	rows, removals, problem := site_demonstrations_read(text)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {
		testing.expect_value(t, rows[0].state, "Shown")
		testing.expect_value(t, len(rows[0].pictures), 2)
		testing.expect_value(t, rows[0].pictures[1], "errors")
		testing.expect_value(t, rows[0].line, 5)
	}
	testing.expect_value(t, len(removals), 1)
	_, _, short := site_demonstrations_read("## The table\n\n| 1 | Small | Shown |\n")
	testing.expect(t, strings.has_prefix(short, SITE_DEMONSTRATIONS_FILE + ", line 3:"), short)
}
