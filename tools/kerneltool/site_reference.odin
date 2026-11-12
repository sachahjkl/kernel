// The reference tables that the site generates from the code (docs/SITE.md,
// "The reference tables"): the kernel operations, the context, the errors,
// the grants, the fixed ranges, the commands of the console, and one page
// for each module. Each table is read from the file that defines the thing;
// no text of a table is typed here. Under each table, the page names the
// file that it was read from, at the commit of the build.
package kerneltool

import "core:fmt"
import "core:strings"
import "contract:fixed_addresses"
import module "contract:module"
import op "contract:operation"

SITE_OPERATION_FILE :: "contract/operation/operation.odin"
SITE_ERRORS_FILE :: "contract/errors/errors.odin"
SITE_FIXED_ADDRESSES_FILE :: "contract/fixed_addresses/fixed_addresses.odin"
SITE_SYSTEM_GRANTS_FILE :: "support/system/grants.odin"
SITE_ROOT_FILE :: "programs/root/main.odin"
SITE_MODULES_FILE :: "tools/kerneltool/modules.odin"
SITE_CONSOLE_COMMAND_FILES :: [?]string{"programs/console/commands.odin", "programs/console/tables.odin"}

SITE_OPERATIONS_PAGE :: "reference/operations.html"
SITE_CONTEXT_PAGE :: "reference/context.html"
SITE_ERRORS_PAGE :: "reference/errors.html"
SITE_GRANTS_PAGE :: "reference/grants.html"
SITE_FIXED_RANGES_PAGE :: "reference/fixed-ranges.html"
SITE_CONSOLE_PAGE :: "reference/console.html"
SITE_MODULES_FOLDER :: "reference/modules"
SITE_MODULES_PAGE :: "reference/modules/index.html"

// The constants of the context that are its sizes, not roles: the table of
// the roles leaves them out.
SITE_CONTEXT_SIZES :: [?]string{"CONTEXT_HANDLES", "CONTEXT_VALUES"}

// One module of module_builds, with what its source says of it.
Site_Module :: struct {
	build:       Module_Build,
	kind:        string, // "program" for a source in programs/, else "module".
	page:        string,
	description: Module_Description,
}

// What the reference tables show, read once before any page is written:
// the guides link their code spans to the rows.
Site_Reference :: struct {
	operations:       []Site_Operation,
	statuses:         []Site_Enumeration_Member,
	context_roles:    []Site_Constant,
	grant_roles:      []Site_Constant,
	error_kinds:      []Site_Enumeration_Member,
	error_units:      []Site_Enumeration_Member,
	unit_names:       map[string]string,
	start_grants:     []Site_Enumeration_Member, // Grant of programs/root: what a program receives at its start.
	root_grants:      []Site_Enumeration_Member, // Root_Grant of support/system: what the root service records and can revoke.
	root_grant_names: map[string]string,
	program_grants:   []Site_Name_Case,
	grants_otherwise: Site_Name_Case,
	program_budgets:  []Site_Name_Case,
	budget_otherwise: Site_Name_Case,
	fixed_ranges:     []Site_Enumeration_Member,
	console_commands: []Site_Console_Command,
	modules:          []Site_Module,
}

site_module_page :: proc(name: string) -> string {
	return strings.concatenate({SITE_MODULES_FOLDER, "/", name, ".html"}, context.temp_allocator)
}

// site_line_address gives the address of one line of a file of the
// repository at the commit of the build.
site_line_address :: proc(site: ^Site, path: string, line: int) -> string {
	return fmt.tprintf("%s#L%d", site_repository_file(site, path), line)
}

// site_folder_address gives the address of a folder of the repository.
site_folder_address :: proc(site: ^Site, path: string) -> string {
	at := site.commit != "" ? site.commit : "master"
	return strings.concatenate({SITE_REPOSITORY_ADDRESS, "/tree/", at, "/", path}, context.temp_allocator)
}

// site_reference_read reads every source of the reference tables. A file
// that lost its form stops the command, with the file and the line.
site_reference_read :: proc(site: ^Site) -> bool {
	reference := &site.reference
	problems := make([dynamic]string, context.temp_allocator)
	note :: proc(problems: ^[dynamic]string, problem: string) {
		if problem != "" {
			append(problems, problem)
		}
	}
	operation_text := site_read(SITE_OPERATION_FILE) or_return
	errors_text := site_read(SITE_ERRORS_FILE) or_return
	fixed_text := site_read(SITE_FIXED_ADDRESSES_FILE) or_return
	grants_text := site_read(SITE_SYSTEM_GRANTS_FILE) or_return
	root_text := site_read(SITE_ROOT_FILE) or_return
	problem: string

	members: []Site_Enumeration_Member
	members, problem = site_enumeration_read(operation_text, SITE_OPERATION_FILE, "Operation")
	note(&problems, problem)
	operations := make([dynamic]Site_Operation, context.temp_allocator)
	for member in members {
		append(&operations, site_operation_parts(member))
	}
	reference.operations = operations[:]
	reference.statuses, problem = site_enumeration_read(operation_text, SITE_OPERATION_FILE, "Status")
	note(&problems, problem)
	reference.context_roles, problem = site_constants_read(operation_text, SITE_OPERATION_FILE, "CONTEXT_HANDLES ::", {"CONTEXT_", "ROOT_"})
	note(&problems, problem)
	reference.grant_roles, problem = site_constants_read(grants_text, SITE_SYSTEM_GRANTS_FILE, "", {"GRANT_"})
	note(&problems, problem)
	reference.error_kinds, problem = site_enumeration_read(errors_text, SITE_ERRORS_FILE, "Kind")
	note(&problems, problem)
	reference.error_units, problem = site_enumeration_read(errors_text, SITE_ERRORS_FILE, "Unit")
	note(&problems, problem)
	reference.unit_names, problem = site_names_read(errors_text, SITE_ERRORS_FILE, "UNIT_NAMES")
	note(&problems, problem)
	reference.start_grants, problem = site_enumeration_read(root_text, SITE_ROOT_FILE, "Grant")
	note(&problems, problem)
	reference.root_grants, problem = site_enumeration_read(grants_text, SITE_SYSTEM_GRANTS_FILE, "Root_Grant")
	note(&problems, problem)
	reference.root_grant_names, problem = site_names_read(grants_text, SITE_SYSTEM_GRANTS_FILE, "root_grant_names")
	note(&problems, problem)
	reference.program_grants, reference.grants_otherwise, problem = site_name_switch_read(root_text, SITE_ROOT_FILE, "grants_of")
	note(&problems, problem)
	reference.program_budgets, reference.budget_otherwise, problem = site_name_switch_read(root_text, SITE_ROOT_FILE, "things_of")
	note(&problems, problem)
	reference.fixed_ranges, problem = site_enumeration_read(fixed_text, SITE_FIXED_ADDRESSES_FILE, "Fixed_Range")
	note(&problems, problem)
	commands := make([dynamic]Site_Console_Command, context.temp_allocator)
	console_files := SITE_CONSOLE_COMMAND_FILES
	for file in console_files {
		text := site_read(file) or_return
		found: []Site_Console_Command
		found, problem = site_console_commands_read(text, file)
		note(&problems, problem)
		append(&commands, ..found)
	}
	reference.console_commands = commands[:]

	// The modules: each one of module_builds, with the description that the
	// build writes into the module, read from the same source.
	modules := make([dynamic]Site_Module, context.temp_allocator)
	for build in module_builds {
		description := describe_package(build.source) or_return
		kind := strings.has_prefix(build.source, "programs/") ? "program" : "module"
		append(&modules, Site_Module{build = build, kind = kind, page = site_module_page(build.name), description = description})
	}
	reference.modules = modules[:]

	if len(problems) > 0 {
		for item in problems {
			fmt.eprintfln("kerneltool: site: %s", item)
		}
		return false
	}
	site_code_links_make(site)
	return true
}

// site_code_link_add records the target of a code span, or marks the name
// as ambiguous when another table has it too.
site_code_link_add :: proc(links: ^map[string]string, ambiguous: ^map[string]bool, name, target: string) {
	if existing, found := links^[name]; found && existing != target {
		ambiguous^[name] = true
	}
	links^[name] = target
}

// site_code_links_make gives the rows that a code span of a guide links to.
// The rule: the whole text of the span, with its case, is the name of one
// kernel operation, one error kind or one module; or the span is
// "<command>(...)" for a built-in command of the console. A name that two
// tables have links nowhere.
site_code_links_make :: proc(site: ^Site) {
	links := make(map[string]string, context.temp_allocator)
	ambiguous := make(map[string]bool, context.temp_allocator)
	for operation in site.reference.operations {
		if operation.member.number != 0 {
			site_code_link_add(&links, &ambiguous, operation.member.name, strings.concatenate({SITE_OPERATIONS_PAGE, "#operation-", site_slug(operation.member.name)}, context.temp_allocator))
		}
	}
	for status in site.reference.statuses {
		// A status is not linked, but a name that is also a status is
		// ambiguous: Bad_Address is a status and an error kind.
		site_code_link_add(&links, &ambiguous, status.name, strings.concatenate({SITE_OPERATIONS_PAGE, "#status-", site_slug(status.name)}, context.temp_allocator))
		ambiguous[status.name] = true
	}
	for kind in site.reference.error_kinds {
		if kind.number != 0 {
			site_code_link_add(&links, &ambiguous, kind.name, strings.concatenate({SITE_ERRORS_PAGE, "#kind-", site_slug(kind.name)}, context.temp_allocator))
		}
	}
	for item in site.reference.modules {
		site_code_link_add(&links, &ambiguous, item.build.name, item.page)
	}
	for command in site.reference.console_commands {
		site_code_link_add(&links, &ambiguous, strings.concatenate({command.name, "()"}, context.temp_allocator), strings.concatenate({SITE_CONSOLE_PAGE, "#command-", site_slug(command.name)}, context.temp_allocator))
	}
	for name in ambiguous {
		delete_key(&links, name)
	}
	site.code_links = links
}

// site_code_link gives the row that a code span names, by the rule of
// site_code_links_make.
site_code_link :: proc(site: ^Site, code: string) -> (target: string, found: bool) {
	key := code
	if paren := strings.index_byte(code, '('); paren > 0 && strings.has_suffix(code, ")") {
		key = strings.concatenate({code[:paren], "()"}, context.temp_allocator)
	} else if strings.contains_any(code, "() ") {
		return "", false
	}
	target, found = site.code_links[key]
	return
}

// site_type_text gives a type as the console prints it
// (support/sentence, write_type and write_parameter_type).
site_type_text :: proc(description: Module_Description, type: module.Type, detail: u32, direction: module.Direction, parameter: bool) -> string {
	record_name := "Record"
	if detail >= 1 && int(detail) <= len(description.records) {
		record_name = description.records[detail - 1].name
	}
	direction_name := fmt.tprintf("%v", direction)
	switch type {
	case .None:
		return "None"
	case .Integer:
		return "Integer"
	case .Text:
		return detail != 0 ? fmt.tprintf("Text(%d)", detail) : "Text"
	case .Record:
		return record_name
	case .Handle:
		rights := transmute(op.Rights)detail
		if rights == {} {
			return "Handle"
		}
		names := make([dynamic]string, context.temp_allocator)
		for right in op.Right {
			if right in rights {
				append(&names, fmt.tprintf("%v", right))
			}
		}
		return fmt.tprintf("Handle(%s)", strings.join(names[:], ", ", context.temp_allocator))
	case .Table:
		return parameter ? fmt.tprintf("Table(%s, %s)", record_name, direction_name) : fmt.tprintf("Table(%s)", record_name)
	case .Bytes:
		return parameter ? fmt.tprintf("Bytes(%s)", direction_name) : "Bytes"
	}
	return "?"
}

// site_export_signature gives an export as the console prints it:
// "write(name: Text, data: Text) -> Integer".
site_export_signature :: proc(description: Module_Description, export: Export_Description) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, export.name)
	strings.write_byte(&builder, '(')
	for type, index in export.parameters {
		if index > 0 {
			strings.write_string(&builder, ", ")
		}
		if index < len(export.names) && export.names[index] != "" {
			strings.write_string(&builder, export.names[index])
			strings.write_string(&builder, ": ")
		}
		detail: u32 = index < len(export.details) ? export.details[index] : 0
		direction: module.Direction = index < len(export.directions) ? export.directions[index] : .Read
		strings.write_string(&builder, site_type_text(description, type, detail, direction, true))
	}
	strings.write_byte(&builder, ')')
	if export.result != .None {
		strings.write_string(&builder, " -> ")
		strings.write_string(&builder, site_type_text(description, export.result, export.result_detail, .Read, false))
	}
	return strings.to_string(builder)
}

// site_name_cell writes the cell of a name that links to its line in the
// source file.
site_name_cell :: proc(site: ^Site, b: ^strings.Builder, name, file: string, line: int) {
	strings.write_string(b, "<td class=\"code name\"><a href=\"")
	site_escape(b, site_line_address(site, file, line))
	strings.write_string(b, "\"><code>")
	site_escape(b, name)
	strings.write_string(b, "</code></a></td>")
}

// site_text_cell writes a cell of text of a source file: escaped, with no
// Markdown.
site_text_cell :: proc(b: ^strings.Builder, text: string, class: string = "") {
	if class != "" {
		fmt.sbprintf(b, "<td class=\"%s\">", class)
	} else {
		strings.write_string(b, "<td>")
	}
	site_escape(b, text)
	strings.write_string(b, "</td>")
}

// site_enumeration_table writes the members of an enumeration: the
// number, the name (a link to its line), and its comment.
site_enumeration_table :: proc(site: ^Site, b: ^strings.Builder, members: []Site_Enumeration_Member, file, id_prefix: string, headers: []string) {
	site_table_start(b, headers)
	for member in members {
		fmt.sbprintf(b, "<tr id=\"%s-%s\">", id_prefix, site_slug(member.name))
		fmt.sbprintf(b, "<td class=\"code\">%d</td>", member.number)
		site_name_cell(site, b, member.name, file, member.line)
		site_text_cell(b, member.comment)
		strings.write_string(b, "</tr>\n")
	}
	site_table_end(b)
}

// site_generated_tables_add adds the pages of the tables generated from the
// code, and their lines in the index of the reference.
site_generated_tables_add :: proc(site: ^Site, entries: ^[dynamic]Site_Reference_Entry) {
	reference := &site.reference
	add :: proc(site: ^Site, entries: ^[dynamic]Site_Reference_Entry, path, title, description, what, source: string, b: ^strings.Builder, sources: ..string) {
		site_page_add(site, Site_Page{path = path, title = title, description = site_description_cut(description), section = .Reference, crumbs = site_crumbs(.Reference), body = strings.to_string(b^), sources = site_sources(..sources)})
		append(entries, Site_Reference_Entry{path = path, title = title, what = what, source = source})
	}

	// The kernel operations.
	{
		b := strings.builder_make(context.temp_allocator)
		count := len(reference.operations) - 1 // The member None is not an operation.
		fmt.sbprintf(&b, "<h1>Kernel operations</h1>\n<p>What a program can ask the kernel: %d operations. The parameters and the result of each are the words of the comment of the contract: \"(parameters) -&gt; result\", then its text; the contract has no other form of them.</p>\n", count)
		site_table_start(&b, {"Number", "Operation", "Parameters", "Result", "What the contract says"})
		for operation in reference.operations {
			fmt.sbprintf(&b, "<tr id=\"operation-%s\">", site_slug(operation.member.name))
			fmt.sbprintf(&b, "<td class=\"code\">%d</td>", operation.member.number)
			site_name_cell(site, &b, operation.member.name, SITE_OPERATION_FILE, operation.member.line)
			site_text_cell(&b, operation.parameters, "code")
			site_text_cell(&b, operation.result, "code")
			site_text_cell(&b, operation.text)
			strings.write_string(&b, "</tr>\n")
		}
		site_table_end(&b)
		site_source_line(site, &b, SITE_OPERATION_FILE)
		strings.write_string(&b, "<h2 id=\"status\">The status of a completion</h2>\n")
		site_enumeration_table(site, &b, reference.statuses, SITE_OPERATION_FILE, "status", {"Number", "Status", "What the contract says"})
		site_source_line(site, &b, SITE_OPERATION_FILE)
		add(site, entries, SITE_OPERATIONS_PAGE, "Kernel operations", fmt.tprintf("The %d kernel operations of %s, with their numbers, their parameters and their results, read from the contract.", count, SITE_SYSTEM_NAME), "Each operation that a program asks the kernel, with its number, its parameters and its result; the status of a completion.", SITE_OPERATION_FILE, &b, SITE_OPERATION_FILE)
	}

	// The context: the roles of its handles and of its values.
	{
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "<h1>The context of a program</h1>\n")
		fmt.sbprintf(&b, "<p>The one record that a program receives when it starts: %d handles and %d values. A role is a place of the record with a meaning.</p>\n", op.CONTEXT_HANDLES, op.CONTEXT_VALUES)
		groups := [?]struct {
			id, title, file: string,
			roles:           []Site_Constant,
		} {
			{"every-program", "The roles that the system fixes for each program", SITE_OPERATION_FILE, reference.context_roles},
			{"started-by-root", "The roles of a program that the root service starts", SITE_SYSTEM_GRANTS_FILE, reference.grant_roles},
		}
		for group in groups {
			fmt.sbprintf(&b, "<h2 id=\"%s\">%s</h2>\n", group.id, group.title)
			site_table_start(&b, {"Constant", "Place", "Handle or value", "What the file says"})
			for role in group.roles {
				size := false
				sizes := SITE_CONTEXT_SIZES
				for name in sizes {
					size ||= role.name == name
				}
				if size || strings.has_suffix(role.name, "_COUNT") {
					continue
				}
				what: string = strings.contains(role.name, "_VALUE_") ? "value" : "handle"
				fmt.sbprintf(&b, "<tr id=\"role-%s\">", site_slug(role.name))
				site_name_cell(site, &b, role.name, group.file, role.line)
				fmt.sbprintf(&b, "<td class=\"code\">%d</td><td>%s</td>", role.value, what)
				site_text_cell(&b, role.comment)
				strings.write_string(&b, "</tr>\n")
			}
			site_table_end(&b)
			site_source_line(site, &b, group.file)
		}
		add(site, entries, SITE_CONTEXT_PAGE, "The context of a program", fmt.tprintf("The roles of the %d handles and %d values of the context, the record that each program of %s receives at its start.", op.CONTEXT_HANDLES, op.CONTEXT_VALUES, SITE_SYSTEM_NAME), "The place of each handle and each value in the context that a program receives.", SITE_OPERATION_FILE, &b, SITE_OPERATION_FILE, SITE_SYSTEM_GRANTS_FILE)
	}

	// The errors.
	{
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, "<h1>Error kinds and units</h1>\n<p>The error record of a call that failed holds a kind, a unit, and values. %d kinds and %d units.</p>\n<h2 id=\"kinds\">Kinds</h2>\n", len(reference.error_kinds) - 1, len(reference.error_units) - 1)
		site_enumeration_table(site, &b, reference.error_kinds, SITE_ERRORS_FILE, "kind", {"Number", "Kind", "What value, limit and found hold"})
		site_source_line(site, &b, SITE_ERRORS_FILE)
		strings.write_string(&b, "<h2 id=\"units\">Units</h2>\n")
		site_table_start(&b, {"Number", "Unit", "In a sentence", "What the contract says"})
		for unit in reference.error_units {
			fmt.sbprintf(&b, "<tr id=\"unit-%s\">", site_slug(unit.name))
			fmt.sbprintf(&b, "<td class=\"code\">%d</td>", unit.number)
			site_name_cell(site, &b, unit.name, SITE_ERRORS_FILE, unit.line)
			site_text_cell(&b, reference.unit_names[unit.name])
			site_text_cell(&b, unit.comment)
			strings.write_string(&b, "</tr>\n")
		}
		site_table_end(&b)
		site_source_line(site, &b, SITE_ERRORS_FILE)
		add(site, entries, SITE_ERRORS_PAGE, "Error kinds and units", fmt.tprintf("The %d kinds and %d units of the error record of %s, with what each kind puts in its values.", len(reference.error_kinds) - 1, len(reference.error_units) - 1, SITE_SYSTEM_NAME), "Each kind and each unit of the error record, with the meaning of its values.", SITE_ERRORS_FILE, &b, SITE_ERRORS_FILE)
	}

	// The grants.
	{
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "<h1>Grants of the root service</h1>\n<p>The root service starts the programs and gives each one only the handles of its role.</p>\n<h2 id=\"at-start\">What a program receives at its start</h2>\n")
		site_enumeration_table(site, &b, reference.start_grants, SITE_ROOT_FILE, "start-grant", {"Place", "Grant", "What the root service gives"})
		site_source_line(site, &b, SITE_ROOT_FILE)
		strings.write_string(&b, "<h2 id=\"recorded\">What the root service records and can revoke</h2>\n")
		site_table_start(&b, {"Bit", "Grant", "Name in the console", "What it gives"})
		for grant in reference.root_grants {
			fmt.sbprintf(&b, "<tr id=\"root-grant-%s\"><td class=\"code\">%d</td>", site_slug(grant.name), grant.number)
			site_name_cell(site, &b, grant.name, SITE_SYSTEM_GRANTS_FILE, grant.line)
			site_text_cell(&b, reference.root_grant_names[grant.name], "code name")
			site_text_cell(&b, grant.comment)
			strings.write_string(&b, "</tr>\n")
		}
		site_table_end(&b)
		site_source_line(site, &b, SITE_SYSTEM_GRANTS_FILE)
		strings.write_string(&b, "<h2 id=\"programs\">The grants of each program</h2>\n")
		site_table_start(&b, {"Programs", "Grants", "Why, as the root service says"})
		for item in reference.program_grants {
			strings.write_string(&b, "<tr>")
			site_program_names_cell(site, &b, item.names)
			site_name_cell(site, &b, item.value, SITE_ROOT_FILE, item.line)
			site_text_cell(&b, item.comment)
			strings.write_string(&b, "</tr>\n")
		}
		strings.write_string(&b, "<tr><td>Each other program</td>")
		site_name_cell(site, &b, reference.grants_otherwise.value, SITE_ROOT_FILE, reference.grants_otherwise.line)
		site_text_cell(&b, reference.grants_otherwise.comment)
		strings.write_string(&b, "</tr>\n")
		site_table_end(&b)
		site_source_line(site, &b, SITE_ROOT_FILE)
		add(site, entries, SITE_GRANTS_PAGE, "Grants of the root service", fmt.tprintf("The %d grants that the root service of %s gives at the start of a program, the %d that it records, and the grants of each program.", len(reference.start_grants), len(reference.root_grants), SITE_SYSTEM_NAME), "What the root service gives each program at its start, and what it records and can revoke.", SITE_ROOT_FILE, &b, SITE_ROOT_FILE, SITE_SYSTEM_GRANTS_FILE)
	}

	// The fixed ranges.
	{
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "<h1>Fixed ranges</h1>\n<p>The addresses of the mappings that the system gives a program: one slot of the band for each range, so that no two ranges overlap.</p>\n")
		site_table_start(&b, {"Slot", "Range", "Address", "What is mapped there"})
		for fixed_range in reference.fixed_ranges {
			fmt.sbprintf(&b, "<tr id=\"range-%s\"><td class=\"code\">%d</td>", site_slug(fixed_range.name), fixed_range.number)
			site_name_cell(site, &b, fixed_range.name, SITE_FIXED_ADDRESSES_FILE, fixed_range.line)
			// The address comes from the contract itself, not from a copy of its constants.
			fmt.sbprintf(&b, "<td class=\"code name\">0x%016X</td>", fixed_addresses.range_of(fixed_addresses.Fixed_Range(fixed_range.number)).address)
			site_text_cell(&b, fixed_range.comment)
			strings.write_string(&b, "</tr>\n")
		}
		site_table_end(&b)
		site_source_line(site, &b, SITE_FIXED_ADDRESSES_FILE)
		add(site, entries, SITE_FIXED_RANGES_PAGE, "Fixed ranges", fmt.tprintf("The %d fixed ranges of the addresses of a program of %s: the mappings that the system gives, each in its own slot.", len(reference.fixed_ranges), SITE_SYSTEM_NAME), "Each range of addresses that the system gives a program, with its address.", SITE_FIXED_ADDRESSES_FILE, &b, SITE_FIXED_ADDRESSES_FILE)
	}

	// The commands of the console.
	{
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, "<h1>Commands of the console</h1>\n<p>The %d commands that the console has before any module is loaded, as <code>help()</code> prints them. A module that the console loads adds its exports: see the <a href=\"modules/index.html\">modules</a>.</p>\n", len(reference.console_commands))
		site_table_start(&b, {"Command", "What it does"})
		for command in reference.console_commands {
			fmt.sbprintf(&b, "<tr id=\"command-%s\">", site_slug(command.name))
			site_name_cell(site, &b, site_console_signature(command), command.file, command.line)
			site_text_cell(&b, command.about)
			strings.write_string(&b, "</tr>\n")
		}
		site_table_end(&b)
		files := SITE_CONSOLE_COMMAND_FILES
		site_source_line(site, &b, ..files[:])
		add(site, entries, SITE_CONSOLE_PAGE, "Commands of the console", fmt.tprintf("The %d built-in commands of the console of %s, with their parameters, their results and their help.", len(reference.console_commands), SITE_SYSTEM_NAME), "Each built-in command of the console, as help() prints it.", files[0], &b, ..files[:])
	}

	site_module_pages_add(site, entries)
}
