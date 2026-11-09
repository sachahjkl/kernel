package console

import "../../blake3"
import op "../../kernel/operation"
import "../../ring"
import "../../system"

// A command: a function with typed parameters and a typed result.
Command :: struct {
	name:            string,
	parameters:      [ARGUMENT_CAPACITY]Kind,
	parameter_count: int,
	result:          Kind,
	about:           string,
	run:             proc "contextless" (arguments: []Value) -> Value,
}

COMMAND_CAPACITY :: 32

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
	if address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {}); status == .Ok {
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
		for writer.count < 31 {
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
