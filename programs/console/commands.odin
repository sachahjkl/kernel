package console

import "../../blake3"
import "../../isolated"
import op "../../kernel/operation"
import module "../../module"
import "../../ring"
import "../../system"

// A command: a function with typed parameters and a typed result.
Command :: struct {
	name:            string,
	parameters:      [ARGUMENT_CAPACITY]Kind,
	parameter_count: int,
	result:          Kind,
	about:           string,
	run:             proc "contextless" (arguments: []Value) -> Value, // A command of the console itself.
	address:         uintptr, // Not 0: an export of a module in this program. The call is direct.
	sandbox:         int, // Not 0: an export of sandboxes[sandbox - 1]. The call is isolated.
	export:          u32, // The index of the export in its module.
	function:        module.Function, // The description of the export.
}

// A module that the console calls in a call host: a sandboxed program.
Sandbox :: struct {
	name:          string,
	first_page:    u64, // The file of the module, in the boot image.
	page_count:    u64,
	file_size:     u64,
	program:       system.Handle, // 0: no call host runs. The next call starts one.
	ring_memory:   system.Handle,
	ring:          ^ring.Ring,
	region_memory: system.Handle,
	region:        []u8,
	calls:         u32, // The tag of the last call.
}

SANDBOX_CAPACITY :: 4
CALL_LIMIT :: 2000 // Milliseconds. The console stops a call host that takes more time for one call.

sandboxes: [SANDBOX_CAPACITY]Sandbox
sandbox_count: int
image_memory: system.Handle

COMMAND_CAPACITY :: 48
LOADED_CAPACITY :: 8

// The modules that the console loaded, by hash.
loaded: [LOADED_CAPACITY][32]u8
loaded_count: int
module_base: u64 = op.MODULE_BASE // Where the next module goes.

commands: [COMMAND_CAPACITY]Command
command_count: int

machine: system.Handle
image: []u8
requests: ^ring.Ring
requests_memory: system.Handle

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
	if address, status := system.memory_map(requests_memory); status == .Ok {
		requests = (^ring.Ring)(address)
	}

	command("help", {}, .None, "list the commands", help)
	command("programs", {}, .None, "list the programs that run", list_programs)
	command("memory", {}, .None, "memory and kernel counters", show_memory)
	command("modules", {}, .None, "list the modules of the boot image", list_modules)
	command("load", {.Text}, .None, "load a module here: direct calls", load_module)
	command("isolate", {.Text}, .None, "load a module in a sandboxed program", isolate_module)
	command("start", {.Text}, .None, "start a program, by module name", start_program)
	command("stop", {.Text}, .None, "stop a program, by name", stop_program)
	command("time", {}, .Integer, "milliseconds since boot", time)
	command("hash", {.Text}, .Text, "the BLAKE3 hash of a text", hash)
	command("length", {.Text}, .Integer, "the number of bytes of a text", length)
	command("text", {.Integer}, .Text, "the decimal text of an integer", text)
	command("repeat", {.Text, .Integer}, .Text, "a text, several times", repeat)
	command("variables", {}, .None, "list the variables", list_variables)
	command("clear", {}, .None, "clear the console", clear)
	command("shutdown", {}, .None, "stop the machine", shutdown)
}

help :: proc "contextless" (arguments: []Value) -> Value {
	for &item in commands[:command_count] {
		buffer: [64]u8
		writer := system.Writer {
			buffer = buffer[:],
		}
		system.write_part(&writer, item.name)
		system.write_part(&writer, "(")
		for kind, index in item.parameters[:item.parameter_count] {
			system.write_part(&writer, index > 0 ? ", " : "")
			system.write_part(&writer, kind_names[kind])
		}
		system.write_part(&writer, ")")
		if item.result != .None {
			system.write_part(&writer, " -> ")
			system.write_part(&writer, kind_names[item.result])
		}
		system.write_part(&writer, " ")
		for writer.count < 36 {
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
	print("slot name        state    pages handles  cpu ms  entries\n")
	for slot in 1 ..< report.program_slots {
		program: op.Program_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program), slot, u64(uintptr(&program)), size_of(program))
		if program.state == .None {
			continue
		}
		print(number(slot, 5), padded(system.name_of(program.name[:]), 12), padded(state_names[program.state], 9))
		print(number(program.mapped_pages, 6), number(program.handle_count, 9), number(program.run_time, 8), number(program.entries, 0), "\n")
	}
	return {}
}

show_memory :: proc "contextless" (arguments: []Value) -> Value {
	report, ok := system_report()
	if !ok {
		return {}
	}
	print("memory          ", report.page_count * system.PAGE_SIZE >> 20, " MiB\n")
	print("free            ", report.free_pages * system.PAGE_SIZE >> 20, " MiB\n")
	print("memory objects  ", report.region_count, "\n")
	print("kernel entries  ", report.entries, "\n")
	print("interrupts      ", report.interrupts, "\n")
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
		for &hash in loaded[:loaded_count] {
			if hash == entry.hash {
				return fail("the module ", name, " is loaded")
			}
		}
		head, _ := module.header(file)
		export_count := module.count(file, .Exports)
		callable := 0
		for index in 1 ..< export_count {
			if function, ok := module.function(file, index); ok && index != head.entry_export && callable_by_console(function) {
				callable += 1
			}
		}
		if callable == 0 {
			return fail("the module ", name, " exports no command; start(\"", name, "\") starts a program")
		}
		if loaded_count == LOADED_CAPACITY || command_count + callable > COMMAND_CAPACITY {
			return fail("no room for the commands of ", name)
		}
		base := module_base
		if isolate {
			if sandbox_count == SANDBOX_CAPACITY || entry.offset % system.PAGE_SIZE != 0 {
				return fail("no room for a sandboxed program")
			}
			sandbox := &sandboxes[sandbox_count]
			sandbox^ = {
				name       = system.name_of(entry.name[:]),
				first_page = entry.offset / system.PAGE_SIZE,
				page_count = (entry.size + system.PAGE_SIZE - 1) / system.PAGE_SIZE,
				file_size  = entry.size,
			}
			if !sandbox_create(sandbox) {
				return fail("cannot start a sandboxed program for ", name)
			}
			sandbox_count += 1
		} else {
			size, status := system.module_load(file, base)
			if status != .Ok {
				return fail("cannot load the module ", name)
			}
			module_base += size + system.PAGE_SIZE
		}
		loaded[loaded_count] = entry.hash
		loaded_count += 1
		for index in 1 ..< export_count {
			function, ok := module.function(file, index)
			address, has_address := module.export_address(file, uintptr(base), index)
			if !ok || !has_address || index == head.entry_export || !callable_by_console(function) {
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
			}
			if isolate {
				item.sandbox = sandbox_count
			} else {
				item.address = address
			}
			for type, parameter in function.parameters[:function.parameter_count] {
				item.parameters[parameter] = Kind(type)
			}
			command_count += 1
		}
		print(name, ": ", i64(callable), isolate ? " commands in a sandboxed program, hash " : " commands, hash ", hex_text(entry.hash[:8]), "...\n")
		return {}
	}
	return fail("no module has the name ", name)
}

// callable_by_console says if the console has a value for each parameter and
// for the result of an export.
callable_by_console :: proc "contextless" (function: module.Function) -> bool {
	function := function
	if function.name_count == 0 || function.parameter_count > ARGUMENT_CAPACITY || function.result > .Text {
		return false
	}
	for type in function.parameters[:function.parameter_count] {
		if type != .Integer && type != .Text {
			return false
		}
	}
	return true
}

// call_export calls an export of a loaded module with the call form: each
// argument in one integer register, in order. An Integer is the value; a Text
// is the address of its slice record.
call_export :: proc "contextless" (item: ^Command, arguments: []Value) -> Value {
	integers: [system.CALL_INTEGERS]u64
	for &argument, index in arguments {
		integers[index] = argument.kind == .Text ? u64(uintptr(&argument.text)) : u64(argument.integer)
	}
	// A Text result: the buffer is the free part of the memory of the line.
	buffer := scratch[scratch_count:]
	if item.result == .Text {
		integers[len(arguments)] = u64(uintptr(&buffer))
	}
	floats: [system.CALL_FLOATS]u64
	results: [system.CALL_RESULTS]u64
	system.export_call(item.address, &integers, &floats, &results)
	#partial switch item.result {
	case .Integer:
		return {kind = .Integer, integer = i64(results[0])}
	case .Text:
		if results[0] > u64(len(buffer)) {
			return fail("the result of ", item.name, " has ", results[0], " bytes: it does not fit")
		}
		scratch_count += int(results[0])
		return {kind = .Text, text = string(buffer[:results[0]])}
	}
	return {}
}

// sandbox_create makes the call ring and the call region of a sandbox, and
// starts its call host.
sandbox_create :: proc "contextless" (sandbox: ^Sandbox) -> bool {
	status: system.Status
	sandbox.ring_memory, sandbox.ring, status = system.ring_create()
	if status != .Ok {
		return false
	}
	address: rawptr
	if sandbox.region_memory, status = system.memory_create(isolated.REGION_PAGES); status == .Ok {
		address, status = system.memory_map(sandbox.region_memory)
	}
	if status != .Ok {
		system.memory_unmap(sandbox.ring)
		system.close(sandbox.ring_memory)
		system.close(sandbox.region_memory)
		return false
	}
	sandbox.region = ([^]u8)(address)[:isolated.REGION_PAGES * system.PAGE_SIZE]
	if sandbox_start(sandbox) != .Ok {
		system.memory_unmap(sandbox.ring)
		system.memory_unmap(address)
		system.close(sandbox.ring_memory)
		system.close(sandbox.region_memory)
		return false
	}
	return true
}

// sandbox_start starts the call host of a sandbox. The program receives the
// call ring and the call region, and no other handle. The console maps the
// file of the module in it, read-only: the program has no handle to the
// boot image.
sandbox_start :: proc "contextless" (sandbox: ^Sandbox) -> system.Status {
	sandbox.ring^ = {}
	handles: [op.CONTEXT_HANDLES]system.Handle
	values: [op.CONTEXT_VALUES]u64
	handles[isolated.GRANT_RING] = sandbox.ring_memory
	handles[isolated.GRANT_REGION] = sandbox.region_memory
	values[isolated.VALUE_FILE_ADDRESS] = isolated.FILE_ADDRESS
	values[isolated.VALUE_FILE_SIZE] = sandbox.file_size
	mappings := [1]system.Mapping{{memory = image_memory, address = isolated.FILE_ADDRESS, first = sandbox.first_page, page_count = sandbox.page_count}}
	status: system.Status
	sandbox.program, status = system.program_start(system.image_find(image, "host"), sandbox.name, handles, values, mappings[:])
	return status
}

// sandbox_end closes the handle of the call host. The kernel stops a program
// that no handle names.
sandbox_end :: proc "contextless" (sandbox: ^Sandbox) {
	system.close(sandbox.program)
	sandbox.program = 0
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
// A module that faults or that does not answer stops alone: the console
// reports an error and continues. The next call starts a new call host.
call_isolated :: proc "contextless" (item: ^Command, arguments: []Value) -> Value {
	sandbox := &sandboxes[item.sandbox - 1]
	if sandbox.program != 0 {
		if state, _ := system.program_state(sandbox.program); state == .Stopped {
			sandbox_end(sandbox)
		}
	}
	if sandbox.program == 0 && sandbox_start(sandbox) != .Ok {
		return fail("cannot start a sandboxed program for ", sandbox.name)
	}
	encoded: [ARGUMENT_CAPACITY]isolated.Argument
	for argument, index in arguments {
		encoded[index] = {integer = u64(argument.integer), text = transmute([]u8)argument.text}
	}
	offset, size, buffer, ok := isolated.encode(item.function, encoded[:len(arguments)], sandbox.region)
	if !ok {
		return fail("the arguments of ", item.name, " do not fit in the call region")
	}
	sandbox.calls += 1
	if !ring.push(&sandbox.ring.commands, ring.Record{kind = item.export, tag = sandbox.calls, values = {0 = offset, 1 = size}}) {
		sandbox_end(sandbox)
		return fail("the call ring of ", sandbox.name, " is full: the console stopped the program")
	}
	system.wake(sandbox.ring_memory)
	limit := system.time() + CALL_LIMIT
	for {
		// The other side writes this queue: read a bounded number of records,
		// and ignore each one that does not answer this call.
		for _ in 0 ..< ring.CAPACITY {
			completion, has_completion := ring.pop(&sandbox.ring.completions)
			if !has_completion {
				break
			}
			if completion.tag != sandbox.calls {
				continue
			}
			switch isolated.Status(completion.kind) {
			case .Ok:
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
				}
				return {}
			case .Bad_Export:
				return fail("the program ", sandbox.name, " has no export ", item.name)
			case .Bad_Arguments:
				return fail("the program ", sandbox.name, " refused the arguments of ", item.name)
			case:
				return fail("the program ", sandbox.name, " gave an unknown status")
			}
		}
		if state, code := system.program_state(sandbox.program); state == .Stopped {
			sandbox_end(sandbox)
			return fail("the program ", sandbox.name, " stopped: ", stop_reason(code))
		}
		if system.wait(limit) >= limit {
			sandbox_end(sandbox)
			return fail("the program ", sandbox.name, " did not answer in ", u64(CALL_LIMIT), " ms: the console stopped it")
		}
	}
}

// request sends one command to the root service and waits for its completion.
request :: proc "contextless" (kind: system.Root_Command, name: string) -> Value {
	if requests == nil {
		return fail("the console has no ring to the root service")
	}
	packed := system.name_pack(name)
	ring.push(&requests.commands, ring.Record{kind = u32(kind), values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}})
	system.wake(requests_memory)
	limit := system.time() + 3000
	for {
		if completion, ok := ring.pop(&requests.completions); ok {
			if system.Status(completion.kind) != .Ok {
				return fail("the root service refused: ", kind == .Start ? "no module has the name " : "no program has the name ", name)
			}
			return {}
		}
		if system.wait(system.time() + 20) > limit {
			return fail("the root service did not answer")
		}
	}
}

start_program :: proc "contextless" (arguments: []Value) -> Value {
	return request(.Start, arguments[0].text)
}

stop_program :: proc "contextless" (arguments: []Value) -> Value {
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

list_variables :: proc "contextless" (arguments: []Value) -> Value {
	for &variable in variables {
		if variable.name_count == 0 {
			continue
		}
		print(string(variable.name[:variable.name_count]), ": ", kind_names[variable.value.kind], " = ")
		if variable.value.kind == .Integer {
			print(variable.value.integer, "\n")
		} else {
			print("\"", variable.value.text, "\"\n")
		}
	}
	return {}
}

clear :: proc "contextless" (arguments: []Value) -> Value {
	clear_grid()
	return {}
}

shutdown :: proc "contextless" (arguments: []Value) -> Value {
	_, status := system.call(.Machine_Stop, u64(machine), 0)
	if status != .Ok {
		return fail("the console has no grant to stop the machine")
	}
	return {}
}
