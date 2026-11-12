package console

import "contract:blake3"
import "contract:errors"
import info "contract:boot_info"
import "contract:isolated"
import op "contract:operation"
import module "contract:module"
import "contract:ring"
import "support:random"
import "support:system"
import "base:intrinsics"

// A command: a function with typed parameters and a typed result.
Command :: struct {
	name:            string,
	parameters:      [ARGUMENT_CAPACITY]Kind,
	parameter_names: [ARGUMENT_CAPACITY]string, // From the description of an export. "": no name.
	parameter_count: int,
	result:          Kind,
	about:           string,
	run:             proc "contextless" (arguments: []Value) -> Value, // A command of the console itself.
	address:         uintptr, // Not 0: an export of a module in this program. The call is direct.
	sandbox:         int, // Not 0: an export of sandboxes[sandbox - 1]. The call is isolated.
	export:          u32, // The index of the export in its module.
	function:        module.Function, // The description of the export: the details of its types.
	file:            []u8, // The module of the description.
	record:          u32, // Not 0: the command makes a record with this description of file, from its fields.
	// Not 0: the number, from 1, of the parameter of the export that is its
	// table of error details. The console gives the table; the person does
	// not write it, so parameter_count does not count it.
	details_parameter: int,
}

// The places of the table of error details that the console gives to an
// export (docs/MODULE_CONTRACT.md, section 8, "The table of error details").
ERROR_DETAILS_CAPACITY :: 16

// A program that executes the isolated calls of the console. It is a call
// host with a module (a sandboxed program that the console starts), or a
// service that runs and serves its own exports (the console has a
// connection to it).
Sandbox :: struct {
	name:          string,
	service:       bool, // A service that runs: the console does not start it and does not stop it.
	hash:          [32]u8, // A service: the hash of the file of the program.
	// A call host: the files that it loads, in the boot image: the module,
	// its imports, and the modules of the replacements. files_memory has the
	// list of the files and the replacements (isolated.VALUE_FILE_ADDRESS).
	files:              [FILE_CAPACITY]^info.Image_Entry,
	file_count:         int,
	file_offsets:       [FILE_CAPACITY]u64, // Where each file is, from isolated.FILE_ADDRESS.
	files_memory:       system.Handle,
	files_size:         u64,
	replacement_offset: u64,
	replacement_count:  u64,
	program:       system.Handle, // 0: no call host runs, or no connection exists. The next call makes one.
	ring_memory:   system.Handle,
	ring:          ring.Ring,
	region_memory: system.Handle,
	region:        []u8,
	calls:         u32, // The tag of the last call.
}

SANDBOX_CAPACITY :: 8
FILE_CAPACITY :: system.MODULE_SPACE_CAPACITY + system.IMPORT_CAPACITY

// A sandbox with no name is free.
sandboxes: [SANDBOX_CAPACITY]Sandbox
prepared: system.Prepared_Modules // The shared code of the call hosts.

// sandbox_free gives a free sandbox, and its number. 0: all have a user.
sandbox_free :: proc "contextless" () -> (sandbox: ^Sandbox, number: int) {
	for &item, index in sandboxes {
		if item.name == "" {
			return &item, index + 1
		}
	}
	return nil, 0
}
image_memory: system.Handle

COMMAND_CAPACITY :: 128
LOADED_CAPACITY :: 8

// A module that the console loaded.
Loaded :: struct {
	hash:    [32]u8,
	name:    string, // In the boot image.
	file:    []u8, // In the boot image.
	place:   int, // A direct load: the place of the module in `space`.
	sandbox: int, // Not 0: the module is in sandboxes[sandbox - 1].
}

loaded: [LOADED_CAPACITY]Loaded
loaded_count: int

// The modules that load put in the console, with their imports. The load
// source is the boot image: what the root service granted.
space: system.Module_Space

// The replacement table of the machine: the root service writes it, the
// console reads it before each load.
replacement_table: ^system.Replacement_Table
replacement_records: [system.REPLACEMENT_CAPACITY]module.Replacement

// source_now gives the source of a load: the boot image, and the replacements
// of the machine at this time.
source_now :: proc "contextless" () -> system.Load_Source {
	return {image = image, replacements = system.replacements_read(replacement_table, &replacement_records)}
}

commands: [COMMAND_CAPACITY]Command
command_count: int

machine: system.Handle
image: []u8
requests: ring.Ring
requests_memory: system.Handle
request_count: u32 // The tag of the last command to the root service.

// The names of the commands of services: "program.export".
names: [2048]u8
names_count: int

command :: proc "contextless" (name: string, parameters: []Kind, result: Kind, about: string, run: proc "contextless" (arguments: []Value) -> Value) {
	item := &commands[command_count]
	item^ = {name = name, parameter_count = len(parameters), result = result, about = about, run = run}
	copy(item.parameters[:], parameters)
	command_count += 1
}

// commands_start maps what the root service granted, and lists the commands.
commands_start :: proc "contextless" () {
	machine = ctx.handles[system.GRANT_MACHINE]
	image_memory = ctx.handles[system.GRANT_IMAGE]
	if address, status := system.memory_map(image_memory, {}); status == .Ok {
		image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	}
	requests_memory = ctx.handles[system.GRANT_ROOT]
	requests, _ = system.ring_open(requests_memory)
	if address, status := system.memory_map(ctx.handles[system.GRANT_REPLACEMENTS], {}); status == .Ok {
		replacement_table = (^system.Replacement_Table)(address)
	}
	space.next = op.MODULE_BASE

	command("help", {}, .None, "list the commands", help)
	command("programs", {}, .None, "list the programs that run", list_programs)
	command("memory", {}, .None, "memory and kernel counters", show_memory)
	command("modules", {}, .None, "list the modules of the boot image", list_modules)
	command("load", {.Text}, .None, "load a module here: direct calls", load_module)
	command("isolate", {.Text}, .None, "load a module in a sandboxed program", isolate_module)
	command("unload", {.Text}, .None, "remove a module that load or isolate added", unload_module)
	command("connect", {.Text}, .None, "call the exports of a service that runs", connect_service)
	command("start", {.Text}, .None, "start a program, by module name", start_program)
	command("stop", {.Text}, .None, "stop a program, by name", stop_program)
	command("grants", {.Text}, .None, "what a program has from the root service", grants)
	command("revoke", {.Text, .Text}, .None, "end a grant of a program that runs", revoke)
	command("replace", {.Text, .Text}, .None, "give the second module where a module imports the first", replace)
	command("replacements", {}, .None, "list the replacement table of the machine", list_replacements)
	command("time", {}, .Integer, "milliseconds since boot", time)
	command("hash", {.Text}, .Text, "the BLAKE3 hash of a text", hash)
	command("length", {.Text}, .Integer, "the number of bytes of a text", length)
	command("text", {.Integer}, .Text, "the decimal text of an integer", text)
	command("repeat", {.Text, .Integer}, .Text, "a text, several times", repeat)
	command("buffer", {.Integer}, .Handle, "a new memory object, in pages", buffer_create)
	command("byte", {.Handle, .Integer}, .Integer, "one byte of a memory object", buffer_byte)
	command("release", {.Handle}, .None, "close a handle", release)
	command("variables", {}, .None, "list the variables", list_variables)
	command("clear", {}, .None, "clear the console", clear)
	command("shutdown", {}, .None, "stop the machine", shutdown)
	command("history_clear", {}, .None, "forget the line history, in memory and in its store", history_clear)
	command("measure_completion", {}, .None, "measure one key of the completion list", measure_completion)
	tables_start()
}

help :: proc "contextless" (arguments: []Value) -> Value {
	for &item in commands[:command_count] {
		buffer: [160]u8
		writer := system.Writer {
			buffer = buffer[:],
		}
		system.write_part(&writer, item.name)
		system.write_part(&writer, "(")
		for kind, index in item.parameters[:item.parameter_count] {
			system.write_part(&writer, index > 0 ? ", " : "")
			if item.parameter_names[index] != "" {
				system.write_part(&writer, item.parameter_names[index])
				system.write_part(&writer, ": ")
			}
			if kind == .None {
				system.write_part(&writer, "Value") // Any kind: the command checks it.
			}
			system.write_parameter_type(&writer, item.file, module.Type(kind), item.function.parameter_details[index], item.function.parameter_directions[index])
		}
		system.write_part(&writer, ")")
		if item.result != .None {
			system.write_part(&writer, " -> ")
			system.write_type(&writer, item.file, module.Type(item.result), item.function.result_detail)
		}
		system.write_part(&writer, " ")
		for writer.count < 53 {
			system.write_part(&writer, " ")
		}
		print(system.written(&writer), item.about, "\n")
	}
	return {}
}

// padded gives text in a field of width characters.
padded :: proc "contextless" (text: string, width: int) -> string {
	start := scratch_count
	scratch_text(text)
	for scratch_count - start < width {
		scratch_text(" ")
	}
	return string(scratch[start:scratch_count])
}

number :: proc "contextless" (value: u64, width: int) -> string {
	buffer: [20]u8
	return padded(system.format(buffer[:], value), width)
}

@(rodata)
state_names := [op.Program_State]string {
	.None    = "",
	.Created = "created",
	.Ready   = "ready",
	.Waiting = "waiting",
	.Stopped = "stopped",
}

system_report :: proc "contextless" () -> (report: op.System_Report, ok: bool) {
	_, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
	if status != .Ok {
		fail("the console has no grant to inspect the machine")
	}
	return report, status == .Ok
}

list_programs :: proc "contextless" (arguments: []Value) -> Value {
	report, ok := system_report()
	if !ok {
		return {}
	}
	print("slot name        state    threads pages present handles  cpu ms  budget  entries\n")
	for slot in 1 ..< report.program_slots {
		program: op.Program_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program), slot, u64(uintptr(&program)), size_of(program))
		if program.state == .None {
			continue
		}
		print(number(slot, 5), padded(system.name_of(program.name[:]), 12), padded(state_names[program.state], 9))
		print(number(program.thread_count, 8), number(program.mapped_pages, 6), number(program.present_pages, 8), number(program.handle_count, 8), number(program.run_time, 8), number(program.budget.pages, 8), "  ", number(program.entries, 0), "\n")
		modules_print(slot)
	}
	return {}
}

// modules_print shows the identity of a program that has more than its
// module: each module that a loader put in it, and the replacements that
// the loader applied (the module records of the kernel).
modules_print :: proc "contextless" (slot: u64) {
	report := &module_report
	system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Modules), slot, u64(uintptr(report)), size_of(report^))
	replaced := false
	for item in report.modules[:report.count] {
		replaced ||= item.replaces != {}
	}
	if report.count < 2 && !replaced {
		return
	}
	for item, index in report.modules[:report.count] {
		print(index == 0 ? "      modules " : "              ", module_text(item.hash))
		if item.replaces != {} {
			print(" in place of ", module_text(item.replaces))
		}
		print("\n")
	}
}

module_report: op.Module_Report

// module_text gives the name of a module in the boot image, and the start of its hash.
module_text :: proc "contextless" (value: [32]u8) -> string {
	hash := value
	start := scratch_count
	if entry := system.image_entry_of(image, hash); entry != nil {
		scratch_text(system.name_of(entry.name[:]), " ")
	}
	hex_text(hash[:8]) // It writes in the scratch memory, after the name.
	scratch_text("...")
	return string(scratch[start:scratch_count])
}

// imports_print shows the imports of a module that load put in the
// console: the module that each import names, and the module that the
// loader gave in its place.
imports_print :: proc "contextless" (place: int) {
	item := &space.modules[place]
	for number in 0 ..< int(item.import_count) {
		record, _ := module.record(item.file, .Imports, u32(number + 1), module.Import)
		used := &space.modules[item.import_places[number]]
		print("  imports ", module_text(record.hash))
		if used.hash != record.hash {
			print(": the loader gave ", module_text(used.hash), " in its place")
		}
		print("\n")
	}
}

show_memory :: proc "contextless" (arguments: []Value) -> Value {
	report, ok := system_report()
	if !ok {
		return {}
	}
	print("memory          ", report.page_count * system.PAGE_SIZE >> 20, " MiB\n")
	print("free            ", report.free_pages * system.PAGE_SIZE >> 20, " MiB\n")
	print("used            ", report.page_count - report.free_pages, " pages\n")
	print("reserved        ", report.reserved_pages, " pages paid, with no page frame yet\n")
	// Each page is free or paid: the budgets and the reserved pages hold all
	// the free pages.
	if report.budget_pages + report.reserved_pages == report.free_pages {
		print("budgets         ", report.budget_pages, " pages: all the free pages\n")
	} else {
		print("budgets         ", report.budget_pages, " pages, but ", report.free_pages - report.reserved_pages, " free pages are not reserved\n")
	}
	print("memory objects  ", report.region_count, "\n")
	print("kernel entries  ", report.entries, "\n")
	print("interrupts      ", report.interrupts, "\n")
	print("processors      ", report.processors, "\n")
	for kind in op.Lock_Kind {
		count := report.locks[kind]
		print("lock ", padded(op.LOCK_KIND_NAMES[kind], 11), count.waits, " waits of ", count.takes, "\n")
	}
	return {}
}

hex_text :: proc "contextless" (bytes: []u8) -> string {
	start := scratch_count
	alphabet := system.HEX_DIGITS
	for b in bytes {
		scratch_text(string([]u8{alphabet[b >> 4], alphabet[b & 0xF]}))
	}
	return string(scratch[start:scratch_count])
}

list_modules :: proc "contextless" (arguments: []Value) -> Value {
	print("name        bytes    hash (BLAKE3)\n")
	for &entry in system.image_entries(image) {
		print(padded(system.name_of(entry.name[:]), 12), number(entry.size, 9), hex_text(entry.hash[:12]), "...\n")
	}
	return {}
}

// load_module loads a module in the console: a call of its exports is a
// direct call. The module has the memory and the handles of the console.
load_module :: proc "contextless" (arguments: []Value) -> Value {
	return add_module(arguments[0].text, false)
}

// isolate_module loads a module in a call host: a call of its exports is an
// isolated call. The module has no handle and no memory of the console.
isolate_module :: proc "contextless" (arguments: []Value) -> Value {
	return add_module(arguments[0].text, true)
}

// add_module makes each export of a module of the boot image a command: the
// description of the export in the module gives its name, its types and its
// help. The description is the same for a direct call and an isolated call.
add_module :: proc "contextless" (name: string, isolate: bool) -> Value {
	for &entry in system.image_entries(image) {
		if system.name_of(entry.name[:]) != name || entry.offset > u64(len(image)) || entry.size > u64(len(image)) - entry.offset {
			continue
		}
		file := image[entry.offset:][:entry.size]
		if blake3.hash(file) != entry.hash || module.validate(file) != .None {
			return fail("the module ", name, " does not have the hash that the boot image names")
		}
		for &item in loaded[:loaded_count] {
			if item.hash == entry.hash {
				return fail("the module ", name, " is loaded; unload(\"", name, "\") removes it")
			}
		}
		callable := callable_count(file)
		if callable == 0 {
			return fail("the module ", name, " exports no command; start(\"", name, "\") starts a program")
		}
		if loaded_count == LOADED_CAPACITY || command_count + callable + int(module.count(file, .Records)) > COMMAND_CAPACITY {
			return fail("no room for the commands of ", name)
		}
		base: u64
		number := 0
		place := -1
		if isolate {
			sandbox: ^Sandbox
			sandbox, number = sandbox_free()
			if sandbox == nil {
				return fail("no room for a sandboxed program")
			}
			sandbox^ = {
				name = system.name_of(entry.name[:]),
			}
			if !sandbox_create(sandbox, file) {
				sandbox^ = {}
				if load_error.stage != .None {
					load_details.count = 0 // A call host gives no details of its load.
					return fail_load("cannot isolate ", name)
				}
				return fail("cannot start a sandboxed program for ", name)
			}
		} else {
			// The loader reads the replacement table of this time: the
			// console cannot choose it.
			space.source = source_now()
			ok: bool
			load_details = {records = &load_detail_records[0], count = 0, capacity = ERROR_DETAILS_CAPACITY}
			if place, ok = system.module_space_load(&space, file, &load_error, &load_details); !ok {
				return fail_load("cannot load ", name)
			}
			base = space.modules[place].base
		}
		loaded[loaded_count] = {hash = entry.hash, name = system.name_of(entry.name[:]), file = file, place = place, sandbox = number}
		loaded_count += 1
		commands_add(file, "", number, base)
		print(name, ": ", i64(callable), isolate ? " commands in a sandboxed program, hash " : " commands, hash ", hex_text(entry.hash[:8]), "...\n")
		if place >= 0 {
			imports_print(place)
		} else {
			sandbox := &sandboxes[number - 1]
			for item in sandbox.files[1:sandbox.file_count] {
				print("  with ", system.name_of(item.name[:]), " ", hex_text(item.hash[:8]), "...\n")
			}
		}
		return {}
	}
	return fail("no module has the name ", name)
}

// unload_module removes a module that load or isolate added: its commands
// leave the console. A direct load leaves the memory of the console. A call
// host stops: the kernel stops a program that no handle names.
unload_module :: proc "contextless" (arguments: []Value) -> Value {
	name := arguments[0].text
	for &item, index in loaded[:loaded_count] {
		if item.name != name {
			continue
		}
		kept, removed := 0, 0
		for &entry in commands[:command_count] {
			module_command := entry.run == nil && raw_data(entry.file) == raw_data(item.file) && entry.sandbox == item.sandbox
			if !module_command {
				commands[kept] = entry
				kept += 1
			} else if entry.record != 0 {
				removed -= 1 // The count that the console prints is the count of exports.
			}
		}
		removed += command_count - kept
		command_count = kept
		if item.sandbox != 0 {
			sandbox := &sandboxes[item.sandbox - 1]
			sandbox_end(sandbox)
			system.ring_close(&sandbox.ring)
			system.memory_unmap(raw_data(sandbox.region))
			system.close(sandbox.ring_memory)
			system.close(sandbox.region_memory)
			system.close(sandbox.files_memory)
			sandbox^ = {}
			print(item.name, ": ", i64(removed), " commands removed, its sandboxed program stops\n")
		} else {
			// A module that another module imports stays: one copy for all.
			// An import that no other module uses leaves with the module.
			if !system.module_space_release(&space, item.place, &load_error) {
				print(item.name, ": ", i64(removed), " commands removed\n")
				return fail_load("cannot remove ", item.name)
			}
			if space.modules[item.place].users != 0 {
				print(item.name, ": ", i64(removed), " commands removed, the module stays: a module of the console imports it\n")
			} else {
				print(item.name, ": ", i64(removed), " commands removed, the module left the memory of the console\n")
			}
		}
		loaded[index] = loaded[loaded_count - 1]
		loaded_count -= 1
		return {}
	}
	return fail("load and isolate added no module with the name ", name)
}

// callable_count gives the count of exports of a module that the console
// can call.
callable_count :: proc "contextless" (file: []u8) -> (callable: int) {
	head, _ := module.header(file)
	for index in 1 ..< module.count(file, .Exports) {
		if function, ok := module.function(file, index); ok && index != head.entry_export && callable_by_console(file, function) {
			callable += 1
		}
	}
	return callable
}

// commands_add makes each callable export of a module a command. The
// description of the export gives its name, its types and its help.
// Each record of the module is a command too, with the name of the record:
// it makes a Record value from one argument for each field.
//   prefix:  "", or the name of a service: the command is "service.export".
//   sandbox: 0 for a direct call at base, or the number of the sandbox.
commands_add :: proc "contextless" (file: []u8, prefix: string, sandbox: int, base: u64) {
	head, _ := module.header(file)
	for index in 1 ..< module.count(file, .Records) {
		described, ok := module.record_type(file, index)
		if !ok || described.field_count > ARGUMENT_CAPACITY {
			continue
		}
		item := &commands[command_count]
		item^ = {
			name            = module.string_at(file, described.name_offset, described.name_count),
			about           = "make a record from its fields",
			parameter_count = int(described.field_count),
			result          = .Record,
			file            = file,
			record          = index,
			sandbox         = sandbox, // The owner of the command. A record has no call.
		}
		item.function.result_detail = index
		for number in 0 ..< described.field_count {
			field, _ := module.field(file, described, number)
			item.parameters[number] = Kind(field.type)
			item.parameter_names[number] = module.string_at(file, field.name_offset, field.name_count)
			item.function.parameter_details[number] = field.detail
		}
		command_count += 1
	}
	for index in 1 ..< module.count(file, .Exports) {
		function, ok := module.function(file, index)
		address, has_address := module.export_address(file, uintptr(base), index)
		if !ok || !has_address || index == head.entry_export || !callable_by_console(file, function) {
			continue
		}
		item := &commands[command_count]
		item^ = {
			name            = module.string_at(file, function.name_offset, function.name_count),
			about           = module.string_at(file, function.about_offset, function.about_count),
			parameter_count = int(function.parameter_count),
			result          = Kind(function.result),
			export          = index,
			function        = function,
			file            = file,
		}
		if prefix != "" {
			item.name = system.format(names[names_count:], prefix, ".", item.name)
			names_count += len(item.name)
		}
		if sandbox != 0 {
			item.sandbox = sandbox
		} else {
			item.address = address
		}
		for type, parameter in function.parameters[:function.parameter_count] {
			item.parameters[parameter] = Kind(type)
			item.parameter_names[parameter] = module.string_at(file, function.parameter_names[parameter], u32(function.parameter_name_counts[parameter]))
		}
		// The table of error details is the last parameter: the console
		// gives it, and the command shows the parameters before it.
		if details_index, has_details := module.error_details_parameter(file, function); has_details {
			item.details_parameter = details_index + 1
			item.parameter_count = details_index
		}
		command_count += 1
	}
}

// connect_service makes a connection to a service that runs, and makes each
// export of the service a command: "service.export". The root service
// decides if the console can call the service. It names the file of the
// program by its hash: the console reads the descriptions there.
connect_service :: proc "contextless" (arguments: []Value) -> Value {
	name := arguments[0].text
	for &sandbox in sandboxes {
		if sandbox.service && sandbox.name == name {
			return fail("the console has the commands of the service ", name)
		}
	}
	sandbox, number := sandbox_free()
	if sandbox == nil {
		return fail("no room for the service ", name)
	}
	sandbox^ = {
		name    = name,
		service = true,
	}
	refused: ring.Record
	if status := service_connect(sandbox, &refused); status != .Ok {
		sandbox^ = {}
		if refused.kind == 0 {
			return fail("cannot connect to ", name, ": ", status == .Bad_State ? "the root service did not answer" : "the call ring or the call region does not map")
		}
		text: [240]u8
		return fail("cannot connect to ", name, ": ", root_refusal_text(text[:], refused))
	}
	for &entry in system.image_entries(image) {
		if entry.hash != sandbox.hash || entry.offset > u64(len(image)) || entry.size > u64(len(image)) - entry.offset {
			continue
		}
		file := image[entry.offset:][:entry.size]
		if blake3.hash(file) != entry.hash || module.validate(file) != .None {
			break
		}
		callable := callable_count(file)
		if callable == 0 || command_count + callable + int(module.count(file, .Records)) > COMMAND_CAPACITY || len(names) - names_count < callable * 64 {
			service_disconnect(sandbox)
			sandbox^ = {}
			return fail("the service ", name, callable == 0 ? " exports no command" : ": no room for its commands")
		}
		sandbox.name = system.name_of(entry.name[:]) // The text of the line does not stay.
		commands_add(file, sandbox.name, number, 0)
		print(sandbox.name, ": ", i64(callable), " commands of a service that runs, hash ", hex_text(entry.hash[:8]), "...\n")
		return {}
	}
	service_disconnect(sandbox)
	sandbox^ = {}
	return fail("the boot image has no file with the hash of the program ", name)
}

// root_refusal_text gives the sentence of the error record of a completion
// of the root ring that failed.
root_refusal_text :: proc "contextless" (buffer: []u8, completion: ring.Record) -> string {
	error := errors.completion_record(completion.values)
	writer := system.Writer{buffer = buffer}
	system.ring_error_text(&writer, &error, "root", system.root_command_name(error.operation), system.root_argument_name(error.operation, error.argument))
	return system.written(&writer)
}

// service_connect asks the root service for a connection to the service of
// a sandbox, and maps the call ring and the call region that it gives.
// refused: the completion of a refusal of the root service, if the caller
// asks for it.
service_connect :: proc "contextless" (sandbox: ^Sandbox, refused: ^ring.Record = nil) -> system.Status {
	completion, answered := request_record(.Connect, sandbox.name)
	if !answered {
		return .Bad_State
	}
	if status := system.Status(completion.kind); status != .Ok {
		if refused != nil {
			refused^ = completion
		}
		return status
	}
	sandbox.program = system.Handle(completion.values[0])
	sandbox.ring_memory = system.Handle(completion.values[1])
	sandbox.region_memory = system.Handle(completion.values[2])
	hash := transmute([32]u8)[4]u64{completion.values[3], completion.values[4], completion.values[5], completion.values[6]}
	calls, ring_status := system.ring_open(sandbox.ring_memory)
	bytes, region_status := system.memory_map(sandbox.region_memory)
	sandbox.ring = calls
	sandbox.region = ([^]u8)(bytes)[:region_status == .Ok ? system.memory_size(sandbox.region_memory) * system.PAGE_SIZE : 0]
	// After the first connection, the commands are those of one file.
	if ring_status != .Ok || region_status != .Ok || sandbox.hash != {} && sandbox.hash != hash {
		service_disconnect(sandbox)
		return .Bad_Operation
	}
	sandbox.hash = hash
	return .Ok
}

// service_disconnect ends the connection of a sandbox. The service
// continues.
service_disconnect :: proc "contextless" (sandbox: ^Sandbox) {
	request_record(.Disconnect, sandbox.name)
	if sandbox.ring.head != nil {
		system.ring_close(&sandbox.ring)
	}
	if len(sandbox.region) != 0 {
		system.memory_unmap(raw_data(sandbox.region))
	}
	system.close(sandbox.ring_memory)
	system.close(sandbox.region_memory)
	system.close(sandbox.program)
	sandbox.program, sandbox.ring_memory, sandbox.region_memory, sandbox.ring, sandbox.region = 0, 0, 0, {}, nil
}

// services_check ends the connection to each service that stopped: the
// handle of the console does not keep a stopped program.
services_check :: proc "contextless" () {
	for &sandbox in sandboxes {
		if sandbox.service && sandbox.program != 0 {
			if state, _ := system.program_state(sandbox.program); state == .Stopped {
				service_disconnect(&sandbox)
			}
		}
	}
}

// callable_by_console says if the console has a value for each parameter and
// for the result of an export.
callable_by_console :: proc "contextless" (file: []u8, function: module.Function) -> bool {
	function := function
	if function.name_count == 0 || function.parameter_count > ARGUMENT_CAPACITY || function.result > .Table || function.result == .Handle {
		return false
	}
	if function.result == .Record || function.result == .Table {
		if _, ok := module.record_type(file, function.result_detail); !ok || function.parameter_count == ARGUMENT_CAPACITY {
			return false
		}
	}
	details_index, has_details := module.error_details_parameter(file, function)
	for type, index in function.parameters[:function.parameter_count] {
		direction := function.parameter_directions[index]
		#partial switch type {
		case .Integer, .Text, .Handle:
		case .Record:
			if _, ok := module.record_type(file, function.parameter_details[index]); !ok {
				return false
			}
		case .Table:
			// A Read or Change table is a Table value. An Append table is a
			// second result, which the language does not have; the table of
			// error details is the one Append table: the console gives it.
			if _, _, ok := isolated.table_record(file, type, function.parameter_details[index]); !ok || (direction == .Append && !(has_details && index == details_index)) {
				return false
			}
		case .Bytes:
			// A Text value: read only.
			if direction != .Read {
				return false
			}
		case:
			return false
		}
	}
	return isolated.directions_valid(function)
}

// type_text_of_field gives the type of a field: "Unsigned(1)", "Integer(4)".
type_text_of_field :: proc "contextless" (file: []u8, field: module.Field) -> string {
	writer := system.Writer {
		buffer = scratch[scratch_count:],
	}
	system.write_field_type(&writer, file, field)
	scratch_count += writer.count
	return system.written(&writer)
}

// record_build makes a Record value: one argument for each field, in the
// order of the description.
record_build :: proc "contextless" (item: ^Command, arguments: []Value) -> Value {
	described, _ := module.record_type(item.file, item.record)
	bytes := scratch_bytes(int(described.size))
	if bytes == nil {
		return fail("the line has too many records")
	}
	for argument, number in arguments {
		field, _ := module.field(item.file, described, u32(number))
		if field.type == .Text {
			copy(bytes[field.offset:][:field.detail], argument.text)
		} else if field.type == .Handle {
			(^u32)(&bytes[field.offset])^ = u32(argument.integer)
		} else {
			if !module.field_integer_fits(field, argument.integer) {
				return fail(item.name, ": the field ", module.string_at(item.file, field.name_offset, field.name_count), " is ", type_text_of_field(item.file, field), ", it does not hold ", argument.integer)
			}
			module.field_integer_set(bytes, field, argument.integer)
		}
	}
	return {kind = .Record, record = bytes, file = item.file, detail = item.record}
}

// call_export calls an export of a loaded module with the call form: each
// argument in one integer register, in order. An Integer is the value; a Text
// is the address of its slice record; a Record is the address of its bytes;
// a Handle is the handle. The module is in this program: it has each handle
// of the console, and the rights of a description limit nothing here.
call_export :: proc "contextless" (item: ^Command, arguments: []Value) -> Value {
	integers: [system.CALL_INTEGERS]u64
	// A Table or Bytes parameter: the address of a table place over the
	// memory of the value. A Change table changes it in place: a variable
	// holds the changed rows after the call.
	places: [ARGUMENT_CAPACITY]module.Table_Place
	for &argument, index in arguments {
		if index < int(item.parameter_count) && (item.parameters[index] == .Table || item.parameters[index] == .Bytes) {
			bytes := argument.kind == .Text ? transmute([]u8)argument.text : argument.record
			size, _, _ := isolated.table_record(item.file, module.Type(item.parameters[index]), item.function.parameter_details[index])
			count := u64(len(bytes)) / max(size, 1)
			places[index] = {address = u64(uintptr(raw_data(bytes))), count = count, capacity = count}
			integers[index] = u64(uintptr(&places[index]))
			continue
		}
		#partial switch argument.kind {
		case .Text:
			integers[index] = u64(uintptr(&argument.text))
		case .Record:
			integers[index] = u64(uintptr(raw_data(argument.record)))
		case:
			integers[index] = u64(argument.integer)
		}
	}
	// The table of error details: the last parameter, after those of the
	// person. The export appends to it only when it fails.
	parameter_total := len(arguments)
	details: [ERROR_DETAILS_CAPACITY]errors.Error_Record
	details_place: module.Table_Place
	if item.details_parameter != 0 {
		details_place = {address = u64(uintptr(&details[0])), count = 0, capacity = ERROR_DETAILS_CAPACITY}
		integers[parameter_total] = u64(uintptr(&details_place))
		parameter_total += 1
	}
	// A Record result: the export writes it in the memory of the line.
	record: []u8
	if item.result == .Record {
		described, _ := module.record_type(item.file, item.function.result_detail)
		record = scratch_bytes(int(described.size))
		if record == nil {
			return fail("the line has too many records")
		}
		integers[parameter_total] = u64(uintptr(raw_data(record)))
	}
	// A Text result: the buffer is the free part of the memory of the line.
	buffer := scratch[scratch_count:]
	if item.result == .Text {
		integers[parameter_total] = u64(uintptr(&buffer))
	}
	// A Table result: the buffer is the free part of the memory of the
	// tables of the line, with a capacity in records.
	table: Table_Buffer
	if item.result == .Table {
		table = table_buffer(item.file, item.function.result_detail)
		integers[parameter_total] = u64(uintptr(&table.slice))
	}
	// An error record: one more argument, after the buffer of a result. The
	// export writes it when it fails.
	error: errors.Error_Record
	if item.function.error_record != 0 {
		integers[parameter_total + int(item.result == .Text || item.result == .Table)] = u64(uintptr(&error))
	}
	floats: [system.CALL_FLOATS]u64
	results: [system.CALL_RESULTS]u64
	system.export_call(item.address, &integers, &floats, &results)
	if item.function.error_record != 0 && i64(results[0]) < 0 {
		error.operation = i64(item.export)
		failure := export_failure(item, &error, i64(results[0]))
		error_details_print(item, details[:], details_place.count)
		return failure
	}
	#partial switch item.result {
	case .Integer:
		return {kind = .Integer, integer = i64(results[0])}
	case .Text:
		if results[0] > u64(len(buffer)) {
			return fail("the result of ", item.name, " has ", results[0], " bytes: it does not fit")
		}
		scratch_count += int(results[0])
		return {kind = .Text, text = string(buffer[:results[0]])}
	case .Record:
		return {kind = .Record, record = record, file = item.file, detail = item.function.result_detail}
	case .Table:
		return table_take(item, &table, results[0])
	}
	return {}
}

// sandbox_create makes the call ring and the call region of a sandbox, and
// the list of the files that its call host loads, then starts the call host.
sandbox_create :: proc "contextless" (sandbox: ^Sandbox, file: []u8) -> bool {
	if !sandbox_files(sandbox, file) {
		return false
	}
	status: system.Status
	sandbox.ring_memory, sandbox.ring, status = system.ring_create()
	if status != .Ok {
		system.close(sandbox.files_memory)
		return false
	}
	address: rawptr
	if sandbox.region_memory, status = system.memory_create(isolated.REGION_PAGES); status == .Ok {
		address, status = system.memory_map(sandbox.region_memory)
	}
	if status != .Ok {
		system.ring_close(&sandbox.ring)
		system.close(sandbox.ring_memory)
		system.close(sandbox.region_memory)
		system.close(sandbox.files_memory)
		return false
	}
	sandbox.region = ([^]u8)(address)[:isolated.REGION_PAGES * system.PAGE_SIZE]
	if sandbox_start(sandbox) != .Ok {
		system.ring_close(&sandbox.ring)
		system.memory_unmap(address)
		system.close(sandbox.ring_memory)
		system.close(sandbox.region_memory)
		system.close(sandbox.files_memory)
		return false
	}
	return true
}

// sandbox_files chooses the files of a call host: the module, and what its
// load reads with the replacement table of this time (system.source_closure).
// It writes their list, in the form of the boot image, and the replacements
// in one page: the call host receives that page and these files, and no
// other file.
sandbox_files :: proc "contextless" (sandbox: ^Sandbox, file: []u8) -> bool {
	source := source_now()
	sandbox.file_count = system.source_closure(source, file, &sandbox.files)
	list_size := size_of(info.Image_Header) + sandbox.file_count * size_of(info.Image_Entry)
	if sandbox.file_count == 0 || list_size + len(source.replacements) * size_of(module.Replacement) > system.PAGE_SIZE {
		return false
	}
	status: system.Status
	if sandbox.files_memory, status = system.memory_create(1); status != .Ok {
		return false
	}
	address, map_status := system.memory_map(sandbox.files_memory)
	if map_status != .Ok {
		system.close(sandbox.files_memory)
		return false
	}
	defer system.memory_unmap(address)
	page := ([^]u8)(address)[:system.PAGE_SIZE]
	(^info.Image_Header)(address)^ = {magic = info.IMAGE_MAGIC, count = u32(sandbox.file_count)}
	entries := ([^]info.Image_Entry)(raw_data(page[size_of(info.Image_Header):]))[:sandbox.file_count]
	offset := u64(system.PAGE_SIZE)
	for item, index in sandbox.files[:sandbox.file_count] {
		if item.offset % system.PAGE_SIZE != 0 {
			system.close(sandbox.files_memory)
			return false
		}
		entries[index] = item^
		entries[index].offset = offset
		sandbox.file_offsets[index] = offset
		offset += (item.size + system.PAGE_SIZE - 1) / system.PAGE_SIZE * system.PAGE_SIZE
	}
	sandbox.files_size = offset
	sandbox.replacement_offset = u64(list_size + 7) &~ 7
	sandbox.replacement_count = u64(len(source.replacements))
	copy(([^]module.Replacement)(raw_data(page[sandbox.replacement_offset:]))[:len(source.replacements)], source.replacements)
	return true
}

// sandbox_start starts the call host of a sandbox. The program receives the
// call ring and the call region, and no other handle. The console maps the
// file of the module in it, read-only: the program has no handle to the
// boot image.
sandbox_start :: proc "contextless" (sandbox: ^Sandbox) -> system.Status {
	if sandbox.service {
		return service_connect(sandbox)
	}
	sandbox.ring.head^ = {}
	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	grants[isolated.GRANT_RING] = {sandbox.ring_memory, {.Read, .Write}}
	grants[isolated.GRANT_REGION] = {sandbox.region_memory, {.Read, .Write}}
	grants[op.CONTEXT_LOG] = {system.context_record().handles[op.CONTEXT_LOG], {.Write}}
	values[isolated.VALUE_FILE_ADDRESS] = isolated.FILE_ADDRESS
	values[isolated.VALUE_FILE_SIZE] = sandbox.files_size
	values[isolated.VALUE_REPLACEMENT_OFFSET] = sandbox.replacement_offset
	values[isolated.VALUE_REPLACEMENT_COUNT] = sandbox.replacement_count
	mappings: [FILE_CAPACITY + 1]system.Mapping
	mappings[0] = {memory = sandbox.files_memory, address = isolated.FILE_ADDRESS}
	for item, index in sandbox.files[:sandbox.file_count] {
		mappings[index + 1] = {memory = image_memory, address = isolated.FILE_ADDRESS + sandbox.file_offsets[index], first = item.offset / system.PAGE_SIZE, page_count = (item.size + system.PAGE_SIZE - 1) / system.PAGE_SIZE}
	}
	status: system.Status
	load_error = {}
	sandbox.program, status = system.program_start(system.image_find(image, "host"), sandbox.name, grants, random.values_with_seed(&program_generator, values), {pages = 512, programs = 1, threads = 1, processor = 500_000, log_records = 100}, mappings[:sandbox.file_count + 1], &prepared)
	if status != .Ok {
		return status
	}
	// The first completion of the call host says if it loaded the module.
	// With Load_Failed, the record of the failure is in the call region:
	// the console copies it, and reads it as values.
	limit := system.time() + 5000
	for {
		wait := system.wait_begin()
		// The state first: a call host that stopped wrote its completion before.
		state, _ := system.program_state(sandbox.program)
		for _ in 0 ..< ring.CAPACITY {
			completion, has_completion := system.receive(&sandbox.ring.completions)
			if !has_completion {
				break
			}
			if completion.tag != 0 {
				continue
			}
			if isolated.Status(completion.kind) == .Ok {
				return .Ok
			}
			intrinsics.mem_copy_non_overlapping(&load_error, raw_data(sandbox.region), size_of(load_error))
			sandbox_end(sandbox)
			return .Bad_State
		}
		if state == .Stopped {
			sandbox_end(sandbox)
			return .Bad_State
		}
		system.wait_records(&wait, &sandbox.ring.completions)
		if system.wait_end(&wait, limit) >= limit {
			sandbox_end(sandbox)
			return .Bad_State
		}
	}
}

// load_error is the record of the last load that failed. The console owns
// it; the loader, or a call host through the call region, fills it.
load_error: module.Load_Error

// The error details of the last load in this program that failed: one load
// error for each import that is missing or has the wrong hash. A call host
// gives none: the count is 0.
load_detail_records: [ERROR_DETAILS_CAPACITY]module.Load_Error
load_details: system.Table_To_Append(module.Load_Error)

// fail_load writes a load error: the first line says what failed, and the
// lines of the record follow. Each line starts with "error". When the load
// gave more than one error detail, the lines of each one follow, after its
// number: the record is the first detail.
fail_load :: proc "contextless" (what: string, name: string) -> Value {
	result := fail(what, name)
	load_error_lines :: proc "contextless" (record: ^module.Load_Error, number: u64, count: u64) {
		buffer: [768]u8
		writer := system.Writer {
			buffer = buffer[:],
		}
		if number != 0 {
			system.error_detail_number_text(&writer, number, count)
		}
		system.load_error_text(&writer, record)
		text := system.written(&writer)
		for len(text) > 0 {
			end := 0
			for end < len(text) && text[end] != '\n' {
				end += 1
			}
			print("error: ", text[:end], "\n")
			text = text[min(end + 1, len(text)):]
		}
	}
	load_error_lines(&load_error, 0, 0)
	if load_details.count >= 2 {
		shown := min(load_details.count, load_details.capacity)
		for &detail, index in load_detail_records[:shown] {
			load_error_lines(&detail, u64(index + 1), load_details.count)
		}
		buffer: [128]u8
		writer := system.Writer{buffer = buffer[:]}
		system.error_details_rest_text(&writer, shown, load_details.count)
		if rest := system.written(&writer); rest != "" {
			print("error: ", rest, "\n")
		}
	}
	load_details.count = 0
	return result
}

// fault_print writes where a program stopped on a fault: the module that
// ran, as the loader of the program recorded it, and the module that it
// replaced.
fault_print :: proc "contextless" (report: ^op.Stop_Report) {
	if report.module.size != 0 {
		print("error: the instruction is at offset ", system.Hex(report.instruction - report.module.base), " of ", module_text(report.module.hash), "\n")
		if report.module.replaces != {} {
			print("error: ", module_text(report.module.hash), " runs in place of ", module_text(report.module.replaces), "\n")
		}
	}
	// The stack trace: the instruction, then the return address of each call.
	for &frame, number in report.frames[:min(report.frame_count, op.STOP_FRAME_CAPACITY)] {
		buffer: [96]u8
		writer := system.Writer{buffer = buffer[:]}
		system.frame_text(&writer, image, &frame)
		print("error: frame ", u64(number), ": ", system.written(&writer), number == 0 ? ", the instruction" : "", "\n")
	}
}

// sandbox_end closes the handle of the call host. The kernel stops a program
// that no handle names.
sandbox_end :: proc "contextless" (sandbox: ^Sandbox) {
	if sandbox.service {
		service_disconnect(sandbox)
		return
	}
	system.close(sandbox.program)
	sandbox.program = 0
}

// export_failure prints the sentence of the error record of an export that
// failed, after "error: ". The names come from the description.
export_failure :: proc "contextless" (item: ^Command, error: ^errors.Error_Record, answer: i64) -> Value {
	argument := ""
	if error.argument >= 1 && error.argument <= i64(item.parameter_count) {
		argument = item.parameter_names[error.argument - 1]
	}
	buffer: [240]u8
	writer := system.Writer{buffer = buffer[:]}
	system.error_text(&writer, error, item.name, argument)
	return fail(system.written(&writer), " (", answer, ")")
}

// error_details_print prints the error details of an export that failed,
// one line each, after the line of its error record. count is the count of
// the full answer; details holds the places of the table of the console.
// The error record is the first detail: with one detail, the line of the
// record says all of it.
error_details_print :: proc "contextless" (item: ^Command, details: []errors.Error_Record, count: u64) {
	if count < 2 {
		return
	}
	shown := min(u64(len(details)), count)
	for &detail, index in details[:shown] {
		argument := ""
		if detail.argument >= 1 && detail.argument <= i64(item.parameter_count) {
			argument = item.parameter_names[detail.argument - 1]
		}
		buffer: [240]u8
		writer := system.Writer{buffer = buffer[:]}
		system.error_detail_number_text(&writer, u64(index + 1), count)
		system.error_text(&writer, &detail, item.name, argument)
		print("error: ", system.written(&writer), "\n")
	}
	if count > shown {
		buffer: [128]u8
		writer := system.Writer{buffer = buffer[:]}
		system.error_details_rest_text(&writer, shown, count)
		print("error: ", system.written(&writer), "\n")
	}
}

// stop_reason gives the text of the code of a stopped program.
stop_reason :: proc "contextless" (code: u32) -> string {
	switch code {
	case op.STOP_CODE_FAULT + 0:
		return "division by zero"
	case op.STOP_CODE_FAULT + 6:
		return "invalid instruction"
	case op.STOP_CODE_FAULT + 13:
		return "protection fault"
	case op.STOP_CODE_FAULT + 14:
		return "page fault"
	}
	return code >= op.STOP_CODE_FAULT ? "fault" : "it stopped itself"
}

// call_isolated calls an export of a module in its call host. The arguments
// go in the call region as one argument record; one command record of the
// call ring names it; the completion record has the result.
// A module that faults stops alone: the console reports an error and
// continues. A call has no time limit: the person stops it with Escape,
// and the console then stops the call host. The next call starts a new
// call host.
call_isolated :: proc "contextless" (item: ^Command, arguments: []Value) -> Value {
	sandbox := &sandboxes[item.sandbox - 1]
	if sandbox.program != 0 {
		if state, _ := system.program_state(sandbox.program); state == .Stopped {
			sandbox_end(sandbox)
		}
	}
	if sandbox.program == 0 && sandbox_start(sandbox) != .Ok {
		if !sandbox.service && load_error.stage != .None {
			load_details.count = 0 // A call host gives no details of its load.
			return fail_load("cannot start a sandboxed program for ", sandbox.name)
		}
		return fail(sandbox.service ? "no service runs with the name " : "cannot start a sandboxed program for ", sandbox.name)
	}
	encoded: [ARGUMENT_CAPACITY]isolated.Argument
	for argument, index in arguments {
		encoded[index] = {integer = u64(argument.integer), text = transmute([]u8)argument.text, record = argument.record}
		// A Table or Bytes parameter: the records go into the call region,
		// and those of a Change table come back.
		if item.parameters[index] == .Table || item.parameters[index] == .Bytes {
			bytes := argument.kind == .Text ? transmute([]u8)argument.text : argument.record
			size, _, _ := isolated.table_record(item.file, module.Type(item.parameters[index]), item.function.parameter_details[index])
			encoded[index].table = {records = bytes, count = u64(len(bytes)) / max(size, 1)}
		}
	}
	// The table of error details: the last parameter, after those of the
	// person. Its places are reserved in the call region; the details come
	// back when the export fails.
	parameter_total := len(arguments)
	details: [ERROR_DETAILS_CAPACITY]errors.Error_Record
	if item.details_parameter != 0 {
		encoded[parameter_total] = {table = {records = ([^]u8)(&details[0])[:size_of(details)], count = 0}}
		parameter_total += 1
	}
	// The handles: the other program receives a copy of each one, with the
	// rights of the description, through the call ring.
	// At the end of the call the console revokes the copies: the kernel ends what the other program kept.
	lending: system.Lending
	defer system.lend_end(&lending)
	#partial switch system.lend(item.file, item.function, encoded[:parameter_total], sandbox.ring_memory, &lending) {
	case .Ok:
	case .Bad_Handle:
		return fail(item.name, ": an argument names no handle of the console")
	case .No_Right:
		return fail(item.name, ": a handle of the console lacks a right that the description asks, or the Give right")
	case:
		return fail(item.name, ": the program ", sandbox.name, " has no room for one more handle")
	}
	offset, size, buffer, error_place, ok := isolated.encode(item.file, item.function, encoded[:parameter_total], sandbox.region)
	if !ok {
		if missing := isolated.room_missing(item.file, item.function, encoded[:parameter_total], u64(len(sandbox.region))); missing.parameter != 0 {
			return fail("the table ", item.parameter_names[missing.parameter - 1], " of ", item.name, " has ", missing.needed, " bytes; the call region has ", missing.free, " bytes free for it")
		}
		return fail("the arguments of ", item.name, " do not fit in the call region")
	}
	sandbox.calls += 1
	if !system.send(&sandbox.ring.commands, ring.Record{kind = item.export, tag = sandbox.calls, values = {0 = offset, 1 = size}}) {
		sandbox_end(sandbox)
		return fail("the call ring of ", sandbox.name, " is full: the console ", sandbox.service ? "closed the connection" : "stopped the program")
	}
	for {
		// The stop of the call host is an event.
		wait := system.wait_begin()
		// The other side writes this queue: read a bounded number of records,
		// and ignore each one that does not answer this call.
		for _ in 0 ..< ring.CAPACITY {
			completion, has_completion := system.receive(&sandbox.ring.completions)
			if !has_completion {
				break
			}
			if completion.tag != sandbox.calls {
				continue
			}
			switch isolated.Status(completion.kind) {
			case .Ok:
				// A failure first: the other program wrote the error record,
				// values only, in the place that encode chose, and the error
				// details. Only the table of error details comes back: the
				// rows that a failed export wrote in a Change table stay out
				// of the values of the console (docs/MODULE_CONTRACT.md,
				// section 8, "The table of error details").
				if error_place.count != 0 && i64(completion.values[0]) < 0 {
					error := (^errors.Error_Record)(raw_data(sandbox.region[error_place.start:]))^
					failure := export_failure(item, &error, i64(completion.values[0]))
					if item.details_parameter != 0 {
						if problem, _ := isolated.error_details_return(item.file, item.function, encoded[:parameter_total], sandbox.region, offset); problem != .None {
							print("error: the program ", sandbox.name, " gave a wrong count for the table of error details: the details are missing\n")
						} else {
							error_details_print(item, details[:], encoded[item.details_parameter - 1].table.count)
						}
					}
					return failure
				}
				// The rows of a Change table come back into the memory of the value.
				if problem, parameter := isolated.tables_return(item.file, item.function, encoded[:parameter_total], sandbox.region, offset); problem != .None {
					name := parameter >= 1 && parameter <= item.parameter_count ? item.parameter_names[parameter - 1] : "of error details"
					return fail("the program ", sandbox.name, " gave a wrong count for the table ", name)
				}
				#partial switch item.result {
				case .Integer:
					return {kind = .Integer, integer = i64(completion.values[0])}
				case .Text:
					// The count comes from the other program: read no more
					// than the buffer, and copy the text out of the call region.
					text, complete := isolated.result_text(sandbox.region, buffer, completion.values[0])
					if !complete || len(text) > len(scratch) - scratch_count {
						return fail("the result of ", item.name, " has ", completion.values[0], " bytes: it does not fit")
					}
					return {kind = .Text, text = scratch_text(string(text))}
				case .Record:
					// The other program wrote these bytes: they are values, and
					// the console reads them with the description.
					record := scratch_bytes(int(buffer.count))
					if record == nil || !isolated.result_record(sandbox.region, buffer, record) {
						return fail("the result of ", item.name, " does not fit")
					}
					return {kind = .Record, record = record, file = item.file, detail = item.function.result_detail}
				case .Table:
					// The other program wrote the records and the count:
					// read no more than the buffer, and copy the records
					// out of the call region.
					if i64(completion.values[0]) < 0 {
						return table_error(item, i64(completion.values[0]))
					}
					described, _ := module.record_type(item.file, item.function.result_detail)
					rows, complete := isolated.result_table(sandbox.region, buffer, completion.values[0], u64(described.size))
					if !complete {
						return fail("the result of ", item.name, " has ", completion.values[0], " records; ", i64(len(rows) / int(max(described.size, 1))), " fit in the call region")
					}
					bytes := table_bytes(len(rows))
					if bytes == nil && len(rows) > 0 {
						return fail("the line has no room for the ", completion.values[0], " records of ", item.name)
					}
					copy(bytes, rows)
					return {kind = .Table, record = bytes, file = item.file, detail = item.function.result_detail}
				}
				return {}
			case .Bad_Export:
				return fail("the program ", sandbox.name, " has no export ", item.name)
			case .Bad_Arguments, .Bad_Handle:
				// The values of a refusal hold its error record: the argument and why.
				refusal := transmute(errors.Error_Record)completion.values
				if refusal.kind != 0 {
					refusal.operation = i64(item.export)
					return export_failure(item, &refusal, i64(completion.kind))
				}
				return fail("the program ", sandbox.name, " refused the arguments of ", item.name)
			case .Load_Failed:
				return fail("the program ", sandbox.name, " gave the status of a load for a call")
			case:
				return fail("the program ", sandbox.name, " gave an unknown status")
			}
		}
		if state, code := system.program_state(sandbox.program); state == .Stopped {
			report := system.program_stop_report(sandbox.program)
			sandbox_end(sandbox)
			result := fail("the program ", sandbox.name, " stopped: ", stop_reason(code))
			fault_print(&report)
			return result
		}
		if intrinsics.atomic_load_explicit(&work.cancel, .Relaxed) != 0 {
			sandbox_end(sandbox)
			return fail("the person stopped the call of ", item.name, sandbox.service ? ": the console closed the connection to " : ": the console stopped the program ", sandbox.name)
		}
		system.wait_records(&wait, &sandbox.ring.completions)
		system.wait_word(&wait, &work.cancel, 0)
		system.wait_end(&wait)
	}
}

// request_record sends one command to the root service and waits for its
// completion. answered is false when the root service gave none.
request_record :: proc "contextless" (kind: system.Root_Command, name: string, value: u64 = 0, time_limit: u64 = 3000) -> (completion: ring.Record, answered: bool) {
	if requests.head == nil {
		return {}, false
	}
	// The ring holds a name of 31 bytes: a longer name is refused here,
	// because a cut name can be the name of another program.
	if len(name) >= len(system.Name) {
		return {kind = u32(system.Status.Bad_Operation), values = errors.ring_fail(u32(kind), .Too_Long, .Bytes, 1, i64(len(name)), len(system.Name) - 1)}, true
	}
	packed := system.name_pack(name)
	request_count += 1
	system.send(&requests.commands, ring.Record{kind = u32(kind), tag = request_count, values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3], 4 = value}})
	limit := system.time() + time_limit
	for {
		// A completion with another tag answers a command that this
		// program waits for no more.
		for record in system.receive(&requests.completions) {
			if record.tag == request_count {
				return record, true
			}
		}
		wait: system.Wait
		system.wait_records(&wait, &requests.completions)
		if system.wait_end(&wait, limit) >= limit {
			return {}, false
		}
	}
}

// request asks the root service to start or to stop a program.
request :: proc "contextless" (kind: system.Root_Command, name: string) -> Value {
	completion, answered := request_record(kind, name)
	if !answered {
		return fail(requests.head == nil ? "the console has no ring to the root service" : "the root service did not answer")
	}
	if system.Status(completion.kind) != .Ok {
		text: [240]u8
		return fail(root_refusal_text(text[:], completion))
	}
	return {}
}

// grants shows what a program has from the root service, of the grants
// that the root service can revoke.
grants :: proc "contextless" (arguments: []Value) -> Value {
	name := arguments[0].text
	completion, answered := request_record(.Grants, name)
	if !answered {
		return fail(requests.head == nil ? "the console has no ring to the root service" : "the root service did not answer")
	}
	if system.Status(completion.kind) != .Ok {
		text: [240]u8
		return fail(root_refusal_text(text[:], completion))
	}
	for set, pass in ([2]system.Root_Grants{transmute(system.Root_Grants)completion.values[0], transmute(system.Root_Grants)completion.values[1]}) {
		if pass == 1 && set == {} {
			break
		}
		print(name, pass == 0 ? " has:" : " lost:")
		if set == {} {
			print(" no grant")
		}
		first := true
		for grant in system.Root_Grant {
			if grant in set {
				print(first ? " " : ", ", system.root_grant_names[grant])
				first = false
			}
		}
		print("\n")
	}
	return {}
}

// revoke asks the root service to end one grant of a program that runs.
revoke :: proc "contextless" (arguments: []Value) -> Value {
	name := arguments[0].text
	for grant in system.Root_Grant {
		if system.root_grant_names[grant] != arguments[1].text {
			continue
		}
		completion, answered := request_record(.Revoke, name, u64(grant))
		if !answered {
			return fail(requests.head == nil ? "the console has no ring to the root service" : "the root service did not answer")
		}
		if system.Status(completion.kind) == .Ok {
			print(name, " lost the grant ", arguments[1].text, ", holdings ended: ", completion.values[0], "\n")
			return {}
		}
		text: [240]u8
		return fail(root_refusal_text(text[:], completion))
	}
	return fail("no grant has the name ", arguments[1].text, ": the grants are log, machine, image, log_records, store, network, person, history")
}

// replace asks the root service to give a module where a module imports
// another one. An empty second text removes the replacement.
replace :: proc "contextless" (arguments: []Value) -> Value {
	name, by := arguments[0].text, arguments[1].text
	value: u64
	if by != "" {
		for &entry, index in system.image_entries(image) {
			if system.name_of(entry.name[:]) == by {
				value = u64(index + 1)
			}
		}
		if value == 0 {
			return fail("no module has the name ", by)
		}
	}
	completion, answered := request_record(.Replace, name, value)
	if !answered {
		return fail(requests.head == nil ? "the console has no ring to the root service" : "the root service did not answer")
	}
	#partial switch system.Status(completion.kind) {
	case .Ok:
		if by == "" {
			print(name, ": no replacement for the loads that follow\n")
		} else {
			print(by, " replaces ", name, " in the loads that follow\n")
		}
		return {}
	case .No_Right:
		return fail("the console has no grant to change the replacement table")
	case .Bad_State:
		return fail("a chain of replacements is refused: ", name, ", ", by)
	case .No_Slot:
		return fail("the replacement table is full")
	case .Bad_Operation:
		return fail("a module does not replace itself")
	}
	return fail(by == "" ? "no replacement of the module " : "no module has the name ", name)
}

// list_replacements shows the replacement table of the machine.
list_replacements :: proc "contextless" (arguments: []Value) -> Value {
	if replacement_table == nil {
		return fail("the console has no grant to read the replacement table")
	}
	records := system.replacements_read(replacement_table, &replacement_records)
	if len(records) == 0 {
		print("no replacement\n")
	}
	for item in records {
		print(module_text(item.from), ": replaced by ", module_text(item.to), "\n")
	}
	return {}
}

start_program :: proc "contextless" (arguments: []Value) -> Value {
	return request(.Start, arguments[0].text)
}

stop_program :: proc "contextless" (arguments: []Value) -> Value {
	// The console that stops itself keeps its line history first: the
	// save after the line never comes.
	if arguments[0].text == "console" {
		history_save()
	}
	return request(.Stop, arguments[0].text)
}

time :: proc "contextless" (arguments: []Value) -> Value {
	return {kind = .Integer, integer = i64(system.time())}
}

hash :: proc "contextless" (arguments: []Value) -> Value {
	result := blake3.hash(transmute([]u8)arguments[0].text)
	return {kind = .Text, text = hex_text(result[:])}
}

length :: proc "contextless" (arguments: []Value) -> Value {
	return {kind = .Integer, integer = i64(len(arguments[0].text))}
}

text :: proc "contextless" (arguments: []Value) -> Value {
	return {kind = .Text, text = scratch_text(arguments[0].integer)}
}

repeat :: proc "contextless" (arguments: []Value) -> Value {
	start := scratch_count
	for _ in 0 ..< arguments[1].integer {
		if len(arguments[0].text) > len(scratch) - scratch_count - 256 {
			return fail("the text is too long")
		}
		scratch_text(arguments[0].text)
	}
	return {kind = .Text, text = string(scratch[start:scratch_count])}
}

// buffer_create makes a memory object. The console holds the handle until
// release.
buffer_create :: proc "contextless" (arguments: []Value) -> Value {
	memory, status := system.memory_create(u64(arguments[0].integer))
	if status != .Ok {
		return fail("the budget of the console cannot pay for ", arguments[0].integer, " pages")
	}
	return {kind = .Handle, integer = i64(memory)}
}

// buffer_byte reads one byte of a memory object: the console maps the
// object for the time of the command.
buffer_byte :: proc "contextless" (arguments: []Value) -> Value {
	memory := system.Handle(arguments[0].integer)
	kind, _, _ := system.handle_state(memory)
	size := kind == .Memory ? system.memory_size(memory) * system.PAGE_SIZE : 0
	if arguments[1].integer < 0 || u64(arguments[1].integer) >= size {
		return fail(kind == .Memory ? "the memory object has no byte " : "the handle names no memory object: byte ", arguments[1].integer)
	}
	address, status := system.memory_map(memory, {})
	if status != .Ok {
		return fail("the console cannot map the memory object")
	}
	defer system.memory_unmap(address)
	return {kind = .Integer, integer = i64(([^]u8)(address)[arguments[1].integer])}
}

release :: proc "contextless" (arguments: []Value) -> Value {
	if kind, _, _ := system.handle_state(system.Handle(arguments[0].integer)); kind != .Memory {
		return fail("release closes a memory object that buffer made")
	}
	system.close(system.Handle(arguments[0].integer))
	return {}
}

list_variables :: proc "contextless" (arguments: []Value) -> Value {
	for &variable in variables {
		if variable.name_count == 0 {
			continue
		}
		print(string(variable.name[:variable.name_count]), ": ", type_text(variable.value.file, variable.value.kind, variable.value.detail), " = ")
		if variable.value.kind == .Text {
			print("\"", variable.value.text, "\"\n")
		} else {
			print_value(variable.value)
			print("\n")
		}
	}
	return {}
}

clear :: proc "contextless" (arguments: []Value) -> Value {
	screen_clear()
	return {}
}

shutdown :: proc "contextless" (arguments: []Value) -> Value {
	// The line history first: the machine stops in the call.
	history_save()
	_, status := system.call(.Machine_Stop, u64(machine), 0)
	if status != .Ok {
		return fail("the console has no grant to stop the machine")
	}
	return {}
}
