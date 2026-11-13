package debugger

import debug_object "contract:debug_object"
import "contract:errors"
import "contract:isolated"
import op "contract:operation"
import "support:debugging"
import "support:system"

// The exports of the debugger service: each one gives a table of records.
// A caller that does not act for the principal gets a refusal; each export
// but `attach` needs a program that the same caller attached to.

// The program that the service debugs now: attach().
Attached :: struct {
	program:   [32]u8,
	slot:      i64, // The place of the program in the kernel.
	threads:   i64, // Its threads.
	modules:   i64, // Its module records.
	described: i64, // The modules that have a debug object: the others show addresses only.
}

// What a detach gave back to the program: detach().
Detached :: struct {
	program:     [32]u8,
	breakpoints: i64, // The breakpoints that the debugger had.
	threads:     i64, // The threads that the debugger held.
}

// One thread of the program: threads(), hold(), release(), continue_all(),
// step(), step_line().
Thread_Row :: struct {
	thread:      i64, // The number of the thread in its program.
	state:       [12]u8, // ready or waiting: it runs. held: the debugger stopped it. stopped: a breakpoint, a watch or a step stopped it.
	instruction: [20]u8, // The address of its next instruction, when its registers can be read.
	module:      [32]u8, // The module of the instruction.
	procedure:   [64]u8, // The procedure of the instruction, from the debug object.
	offset:      i64, // The offset of the instruction in the procedure, or in the module with no procedure.
	file:        [64]u8,
	line:        i64, // 0: no source line.
	pending:     i64, // `step` and `step_line`: 1 when the export reached its bound before the step ended or the line changed: call again, or wait for the stop of the thread. 0 else.
}

// One register of a held thread: registers().
Register_Row :: struct {
	name:  [8]u8,
	value: [20]u8, // In hexadecimal.
	about: [128]u8, // rip: its procedure and its line. rflags: the flags that are set.
}

// One frame of the stack of a held thread: stack().
Frame_Row :: struct {
	frame:          i64, // 0: the instruction of the thread. Each next one: a caller.
	module:         [32]u8,
	procedure:      [64]u8,
	offset:         i64, // The offset in the procedure of the instruction (frame 0) or of the return address.
	file:           [64]u8,
	line:           i64, // The line of the instruction, or of the call.
	frame_pointer:  [20]u8,
	return_address: [20]u8,
}

// One variable of a frame: locals().
Variable_Row :: struct {
	name:     [48]u8,
	role:     [12]u8, // parameter or local.
	type:     [48]u8,
	value:    [96]u8, // The value by its type, or "not readable".
	location: [28]u8, // Where the variable is at this instruction: "rbp - 16", "register rdi".
}

// One part of a value: value().
Value_Row :: struct {
	name:    [48]u8, // The field, "[n]" for an element, or the path for a value with no part.
	type:    [48]u8,
	value:   [96]u8,
	address: [20]u8, // Where the part is in the memory of the program; empty for a value in a register.
}

// The source line of a frame: source().
Source_Row :: struct {
	line: i64,
	mark: [4]u8, // "=>" on the line of the instruction.
	text: [80]u8, // The text of the line, or why the service does not have it.
	path: [64]u8, // The path of the file, from the root of the repository.
	hash: [68]u8, // The BLAKE3 hash of the file at the build, in hexadecimal: a reader shows the line only from a file with this hash.
}

// One breakpoint of the debugger: break_at(), watch(), breaks(), break_remove().
Break_Row :: struct {
	number:  i64, // Its place in the debug registers, from 0.
	kind:    [12]u8, // execute or write.
	address: [20]u8,
	length:  i64, // A watch: the bytes that it watches.
	place:   [96]u8, // The text that named it.
}

// Sixteen bytes of the memory of the program: memory().
Memory_Row :: struct {
	address: [20]u8,
	bytes:   [48]u8, // In hexadecimal, a space between two bytes.
	text:    [20]u8, // The printable characters, "." for each other byte.
}

// One stop of a thread: events(), wait_stop().
Event_Row :: struct {
	thread:      i64,
	kind:        [28]u8, // "breakpoint N", "watch N", "step", "int3" or "int1".
	instruction: [20]u8, // Where the thread goes on.
	module:      [32]u8,
	procedure:   [64]u8,
	offset:      i64,
	file:        [64]u8,
	line:        i64,
}

@(rodata)
thread_states := [op.Program_State]string {
	.None    = "",
	.Created = "created",
	.Ready   = "ready",
	.Waiting = "waiting",
	.Stopped = "ended",
}

@(rodata)
register_names := [18]string{"rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "rip", "rflags"}

// The flags of rflags that a row names, by their bit.
Flag_Name :: struct {
	bit:  uint,
	name: string,
}

@(rodata)
flag_names := [9]Flag_Name{{0, "carry"}, {2, "parity"}, {4, "adjust"}, {6, "zero"}, {7, "sign"}, {8, "trap"}, {9, "interrupt"}, {10, "direction"}, {11, "overflow"}}

PROGRAM_NAME_LIMIT :: 31 // The bytes of the name of a program in a command of the root ring.

// The bytes of one `memory`: memory of this program, not of its stack.
memory_bytes: [MEMORY_COUNT_LIMIT]u8

// thread_row_fill writes the row of one thread: its state, and its
// instruction with its place when its registers can be read.
thread_row_fill :: proc "contextless" (row: ^Thread_Row, item: ^op.Thread_Report) {
	row^ = {thread = i64(item.number)}
	number := u64(item.number)
	state := item.state <= max(op.Program_State) ? thread_states[item.state] : ""
	if number < THREAD_CAPACITY {
		if session.threads[number].waits {
			state = "stopped"
		} else if session.threads[number].held {
			state = "held"
		}
	}
	system.format(row.state[:], state)
	if !thread_stopped(number) {
		return
	}
	registers, status := system.thread_registers_read(session.program, number)
	if status != .Ok {
		return
	}
	hex_column(row.instruction[:], registers.rip)
	place_columns(place_of_address(registers.rip), row.module[:], row.procedure[:], &row.offset, row.file[:], &row.line)
}

// thread_rows writes the rows of the threads of the program: each one, or
// the one with the number `only`. It gives the count of rows.
thread_rows :: proc "contextless" (result: ^[]Thread_Row, only: i64 = -1, pending: i64 = 0) -> i64 {
	total := 0
	for &item in report_threads.threads[:min(report_threads.count, op.THREAD_REPORT_CAPACITY)] {
		if only >= 0 && i64(item.number) != only {
			continue
		}
		if total < len(result^) {
			thread_row_fill(&result[total], &item)
			result[total].pending = pending
		}
		total += 1
	}
	return i64(total)
}

// attach makes the service the debugger of the program with this name, for the caller, and gives one row: the program, its slot, its threads, its module records and how many of them have a debug object.
//
// The service asks the root service for the handle of the program with the
// right Debug, on behalf of the caller. The root service gives it when the
// caller acts for the principal whose session runs the program, and when
// each grant of the program is a grant that the caller holds itself; a
// service is refused for each caller (docs/TOOLS.md, "Who can debug which
// program").
//
// - **program**: the name of a program that runs, at most 31 bytes.
//
// **Errors**:
//
// - `No_Grant`, `Acts_For_Principal` (-1): the caller does not act for the
//   principal.
// - `Full`, `Debugged_Programs` (-3): the service debugs a program
//   already; `detach()` first.
// - (-4) the record of the root service: `No_Grant`, `Debug_Access` when a
//   grant of the program refuses, with 1 + the grant in `found`; `Absent`,
//   `Programs` when no program has the name; `No_Answer` when the root
//   service did not answer; `Refused` with the status of the kernel.
// - `Absent`, `Programs` (-13): the program stopped during the attach.
// - `Bad_Value`, `Programs` (-14): two programs that run have this name
//   and this module.
// - `Too_Long`, `Bytes` (-15): the name has no byte or more than 31.
//
// ```
// connect("debugger")
// debugger.attach("clock")
// ```
@(export, link_name = "attach")
attach :: proc "c" (program: ^string, result: ^[]Attached, error: ^errors.Error_Record) -> i64 {
	caller := system.service_caller()
	if caller == nil || caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL == 0 {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	buffer: [PROGRAM_NAME_LIMIT]u8
	name, fits := text_copy(buffer[:], program)
	if !fits || name == "" {
		return errors.fail(error, ERROR_TEXT, .Too_Long, .Bytes, 1, i64(len(program^)), PROGRAM_NAME_LIMIT)
	}
	// A session whose debug access ended holds nothing.
	if session.attached {
		if kind, _, _ := system.handle_state(session.program); kind != .Program {
			session_end("the debug access was revoked")
		}
	}
	if session.attached {
		return errors.fail(error, ERROR_BUSY, .Full, .Debugged_Programs, 0, 0, 1)
	}
	completion, answered := root_debug(name, caller.ring_memory)
	if !answered {
		// The request stays: when its completion comes, the handle is
		// closed and the root service is told (root_completion_take).
		return errors.fail(error, ERROR_REFUSED, .No_Answer, .Milliseconds, 0, 0, ROOT_ANSWER_MILLISECONDS)
	}
	if system.Status(completion.kind) != .Ok {
		if error != nil {
			error^ = errors.completion_record(completion.values)
		}
		return ERROR_REFUSED
	}
	// The handle is a number from another program: it must be a program
	// handle with Debug that came through the ring to the root service.
	handle := system.Handle(completion.values[0])
	if kind, rights, through := system.handle_state(handle, requests_memory); kind != .Program || .Debug not_in rights || !through {
		root_debug_end(name, caller.ring_memory)
		return refused(error, .Bad_Handle)
	}
	hash := transmute([32]u8)[4]u64{completion.values[1], completion.values[2], completion.values[3], completion.values[4]}
	slot, program_serial, matches := slot_find(name, hash)
	if matches != 1 {
		system.close(handle)
		root_debug_end(name, caller.ring_memory)
		if matches == 0 {
			return errors.fail(error, ERROR_ENDED, .Absent, .Programs, 1)
		}
		system.log("debugger: ", u64(matches), " programs have the name ", system.Module_Name{name}, " and the same module: the service cannot tell which one its handle names")
		return errors.fail(error, ERROR_AMBIGUOUS, .Bad_Value, .Programs, 1, i64(matches), 1)
	}
	// The records of an earlier debugging are of no thread of this program.
	for {
		if _, more := record_next_ready(); !more {
			break
		}
	}
	if status := system.debug_attach(handle); status != .Ok {
		system.close(handle)
		root_debug_end(name, caller.ring_memory)
		return refused(error, status)
	}
	session = {
		attached       = true,
		program        = handle,
		caller_ring    = caller.ring_memory,
		slot           = slot,
		program_serial = program_serial,
	}
	session.name_count = copy(session.name[:], name)
	reports_read()
	described := 0
	module_count := int(min(report_modules.count, op.PROGRAM_MODULE_CAPACITY))
	for &record in report_modules.modules[:module_count] {
		if system.debug_object_of(&debug_names, record.hash) != nil {
			described += 1
		}
	}
	thread_count := min(report_threads.count, op.THREAD_REPORT_CAPACITY)
	system.log("debugger: attached to ", system.Module_Name{name}, " for ", system.Module_Name{system.name_of(caller.caller[:])}, ": ", thread_count, " threads, ", u64(module_count), " modules, ", u64(described), " with a debug object")
	if len(result^) > 0 {
		row := &result[0]
		row^ = {slot = i64(slot), threads = i64(thread_count), modules = i64(module_count), described = i64(described)}
		system.format(row.program[:], name)
	}
	return 1
}

// detach ends the debugging of the program, and gives one row: the program, the breakpoints that the debugger had and the threads that it held.
//
// The kernel removes the breakpoints of each thread, clears the trap flag
// that the debugger wrote, takes back the stops that the debugger made, and
// resumes each thread that waited for its answer: the program runs again.
// The root service forgets the debug access.
//
// **Errors**: `No_Grant`, `Acts_For_Principal` (-1); `Absent`,
// `Debugged_Programs` (-2), the caller attached to no program; `Absent`,
// `Programs` (-13), the program stopped: the debugging ended with it.
//
// ```
// debugger.detach()
// ```
@(export, link_name = "detach")
detach :: proc "c" (result: ^[]Detached, error: ^errors.Error_Record) -> i64 {
	if failure := session_of_caller(error, false); failure != 0 {
		return failure
	}
	breakpoints, held := 0, 0
	for item in session.breaks {
		if item.kind != .None {
			breakpoints += 1
		}
	}
	for hold in session.threads {
		if hold.held || hold.waits {
			held += 1
		}
	}
	status := system.debug_detach(session.program)
	if len(result^) > 0 {
		row := &result[0]
		row^ = {breakpoints = i64(breakpoints), threads = i64(held)}
		system.format(row.program[:], session_name())
	}
	session_end("the caller detached")
	if status != .Ok {
		return refused(error, status)
	}
	return 1
}

// threads gives one row for each thread of the program: its number, its state, and for a thread that the debugger holds or that stopped, its instruction with its module, its procedure, its file and its line.
//
// The state is `ready` or `waiting` for a thread that runs, `held` for a
// thread that `hold` stopped, and `stopped` for a thread that a
// breakpoint, a watch or a step stopped. The registers of a thread that
// runs cannot be read: its row has no instruction.
//
// **Errors**: `No_Grant`, `Acts_For_Principal` (-1); `Absent`,
// `Debugged_Programs` (-2); `Absent`, `Programs` (-13).
//
// ```
// debugger.threads()
// ```
@(export, link_name = "threads")
threads :: proc "c" (result: ^[]Thread_Row, error: ^errors.Error_Record) -> i64 {
	if failure := session_of_caller(error); failure != 0 {
		return failure
	}
	return thread_rows(result)
}

// hold stops one thread of the program, and gives its row: the thread runs no instruction until `release` or `continue_all`.
//
// - **thread**: the number of a thread, as `threads()` gives it.
//
// **Errors**: `No_Grant`, `Acts_For_Principal` (-1); `Absent`,
// `Debugged_Programs` (-2); `Refused` (-4), with the status of the
// kernel; `Absent`, `Threads` (-5), the program has no thread with this
// number; `Absent`, `Programs` (-13).
//
// ```
// debugger.hold(0)
// ```
@(export, link_name = "hold")
hold :: proc "c" (thread: i64, result: ^[]Thread_Row, error: ^errors.Error_Record) -> i64 {
	if failure := session_of_caller(error); failure != 0 {
		return failure
	}
	number, failure := thread_of_argument(thread, false, error)
	if failure != 0 {
		return failure
	}
	if !session.threads[number].held {
		if _, status := system.thread_control_stop(session.program, number); status != .Ok {
			return refused(error, status)
		}
		session.threads[number].held = true
	}
	return thread_rows(result, thread)
}

// release lets one thread run again, and gives its row: a thread that `hold` stopped, or that a breakpoint, a watch or a step stopped.
//
// A thread that stopped at an execute breakpoint runs the instruction of
// the breakpoint once, and the breakpoint stays.
//
// - **thread**: the number of a thread that is held or stopped.
//
// **Errors**: `No_Grant`, `Acts_For_Principal` (-1); `Absent`,
// `Debugged_Programs` (-2); `Refused` (-4); `Absent`, `Threads` (-5), no
// thread has this number; `Absent`, `Held_Threads` (-5), the thread runs;
// `Absent`, `Programs` (-13).
//
// ```
// debugger.release(0)
// ```
@(export, link_name = "release")
release :: proc "c" (thread: i64, result: ^[]Thread_Row, error: ^errors.Error_Record) -> i64 {
	if failure := session_of_caller(error); failure != 0 {
		return failure
	}
	number, failure := thread_of_argument(thread, true, error)
	if failure != 0 {
		return failure
	}
	if status := thread_release(number); status != .Ok {
		return refused(error, status)
	}
	return thread_rows(result, thread)
}

// continue_all lets each thread of the program run again, and gives one row for each thread.
//
// It first writes the breakpoints of the debugger in each thread: a
// thread that the program made after the last breakpoint was set has none
// until then.
//
// **Errors**: `No_Grant`, `Acts_For_Principal` (-1); `Absent`,
// `Debugged_Programs` (-2); `Refused` (-4); `Absent`, `Programs` (-13).
//
// ```
// debugger.continue_all()
// ```
@(export, link_name = "continue_all")
continue_all :: proc "c" (result: ^[]Thread_Row, error: ^errors.Error_Record) -> i64 {
	if failure := session_of_caller(error); failure != 0 {
		return failure
	}
	breaks_apply()
	first_failure := system.Status.Ok
	for number in 0 ..< u64(THREAD_CAPACITY) {
		if !thread_stopped(number) {
			continue
		}
		if status := thread_release(number); status != .Ok && first_failure == .Ok {
			first_failure = status
		}
	}
	if first_failure != .Ok {
		return refused(error, first_failure)
	}
	return thread_rows(result)
}

// registers gives one row for each register of a held thread: the 16 general registers, `rip` with its procedure and its line, and `rflags` with the flags that are set.
//
// - **thread**: the number of a thread that is held or stopped.
//
// **Errors**: `No_Grant`, `Acts_For_Principal` (-1); `Absent`,
// `Debugged_Programs` (-2); `Refused` (-4); `Absent`, `Threads` or
// `Held_Threads` (-5); `Absent`, `Programs` (-13).
//
// ```
// debugger.registers(0)
// ```
@(export, link_name = "registers")
registers :: proc "c" (thread: i64, result: ^[]Register_Row, error: ^errors.Error_Record) -> i64 {
	if failure := session_of_caller(error); failure != 0 {
		return failure
	}
	number, failure := thread_of_argument(thread, true, error)
	if failure != 0 {
		return failure
	}
	image_of_thread, status := system.thread_registers_read(session.program, number)
	if status != .Ok {
		return refused(error, status)
	}
	words := (^[18]u64)(&image_of_thread)^
	for name, index in register_names {
		if index >= len(result^) {
			break
		}
		row := &result[index]
		row^ = {}
		system.format(row.name[:], name)
		hex_column(row.value[:], words[index])
		writer := system.Writer{buffer = row.about[:]}
		switch name {
		case "rip":
			found := place_of_address(words[index])
			if !system.place_write(&writer, found.object, found.offset, found.module, false) && found.has_module {
				system.write_part(&writer, found.module)
				system.write_part(&writer, " + 0x")
				system.write_hex(&writer, found.offset, 8)
			}
		case "rflags":
			for flag in flag_names {
				if words[index] & (u64(1) << flag.bit) == 0 {
					continue
				}
				if writer.count > 0 {
					system.write_part(&writer, " ")
				}
				system.write_part(&writer, flag.name)
			}
		}
		system.written(&writer)
	}
	return i64(len(register_names))
}

// stack gives one row for each frame of the stack of a held thread: the frame number, the module, the procedure and its offset, the file and the line, the frame pointer and the return address.
//
// The frame 0 is the instruction of the thread. Each next frame is a
// caller: its line is the line of the call. The walk follows the frame
// pointers: the word at the frame pointer is the frame pointer of the
// caller, and the next word is the return address. It ends at a frame
// pointer that is 0, that is not a multiple of 8, that the program does
// not map, or that is not above the one before it, at a return address 0,
// and after 32 frames. At the first instruction of a procedure, the return
// address is read at the stack pointer: the procedure has no frame yet.
//
// - **thread**: the number of a thread that is held or stopped.
//
// **Errors**: `No_Grant`, `Acts_For_Principal` (-1); `Absent`,
// `Debugged_Programs` (-2); `Refused` (-4); `Absent`, `Threads` or
// `Held_Threads` (-5); `Absent`, `Programs` (-13).
//
// ```
// debugger.stack(0)
// ```
@(export, link_name = "stack")
stack :: proc "c" (thread: i64, result: ^[]Frame_Row, error: ^errors.Error_Record) -> i64 {
	if failure := session_of_caller(error); failure != 0 {
		return failure
	}
	number, failure := thread_of_argument(thread, true, error)
	if failure != 0 {
		return failure
	}
	walked, status := stack_read(number)
	if status != .Ok {
		return refused(error, status)
	}
	for index in 0 ..< walked.count {
		if index >= len(result^) {
			break
		}
		frame := walked.frames[index]
		row := &result[index]
		row^ = {frame = i64(index)}
		place_columns(place_of_address(debugging.frame_lookup_address(frame, index)), row.module[:], row.procedure[:], &row.offset, row.file[:], &row.line)
		if index > 0 {
			row.offset += 1 // The offset of the return address, not of the byte before it.
		}
		hex_column(row.frame_pointer[:], frame.frame_pointer)
		hex_column(row.return_address[:], frame.return_address)
	}
	return i64(walked.count)
}

// The frame of a held thread that a caller named, with its place.
Frame_Place :: struct {
	walked: ^Stack,
	frame:  int,
	found:  Address_Place,
}

// frame_of_arguments checks the thread and the frame that a caller gave,
// walks the stack, and names the instruction of the frame. With
// `needs_object`, a frame in a module with no debug object is a failure.
frame_of_arguments :: proc "contextless" (thread: i64, frame: i64, needs_object: bool, error: ^errors.Error_Record) -> (place: Frame_Place, failure: i64) {
	number: u64
	number, failure = thread_of_argument(thread, true, error)
	if failure != 0 {
		return {}, failure
	}
	walked, status := stack_read(number)
	if status != .Ok {
		return {}, refused(error, status)
	}
	if frame < 0 || frame >= i64(walked.count) {
		return {}, errors.fail(error, ERROR_FRAME, .Absent, .Stack_Frames, 2)
	}
	place = {walked = walked, frame = int(frame)}
	place.found = place_of_address(debugging.frame_lookup_address(walked.frames[frame], int(frame)))
	if needs_object && place.found.object == nil {
		return {}, errors.fail(error, ERROR_NO_DEBUG_OBJECT, .Absent, .Debug_Objects, 2)
	}
	return place, 0
}

@(rodata)
location_register_names := [debug_object.REGISTER_COUNT]string{"rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "rip"}

// location_write writes a variable location: "rbp - 16", "rsp + 8",
// "register rdi", "not readable".
location_write :: proc "contextless" (writer: ^system.Writer, variable: debug_object.Variable_Description) {
	register: string = variable.register < debug_object.REGISTER_COUNT ? location_register_names[variable.register] : "?"
	switch variable.location {
	case .Not_Readable:
		system.write_part(writer, "not readable")
	case .Register:
		system.write_part(writer, "register ")
		system.write_part(writer, register)
	case .Frame_Pointer_Offset, .Stack_Pointer_Offset, .Register_Offset:
		system.write_part(writer, register)
		if variable.offset < 0 {
			system.write_part(writer, " - ")
			system.write_part(writer, u64(-i64(variable.offset)))
		} else {
			system.write_part(writer, " + ")
			system.write_part(writer, u64(variable.offset))
		}
	}
}

// variable_locate_in_frame gives where a variable of a frame is, and "" or
// why its value cannot be read there.
variable_locate_in_frame :: proc "contextless" (place: Frame_Place, variable: debug_object.Variable_Description) -> (located: debugging.Located, why: string) {
	// Before a procedure set its frame pointer, a location from the frame
	// pointer names the frame of the caller.
	if variable.location != .Not_Readable && variable.register == debug_object.FRAME_POINTER_REGISTER && !frame_has_its_pointer(place.walked, place.frame) {
		return {}, "not readable: the procedure did not set its frame pointer yet"
	}
	verdict: debugging.Location_Verdict
	located, verdict = debugging.variable_locate(variable, frame_registers(place.walked, place.frame))
	switch verdict {
	case .Readable:
		return located, ""
	case .Not_Readable:
		return {}, "not readable"
	case .Not_Readable_In_This_Frame:
		return {}, "not readable in this frame"
	}
	return {}, "not readable"
}

// locals gives one row for each parameter and each local variable that is visible at the instruction of a frame: its name, its role, its type, its value by its type or "not readable", and its location.
//
// The variables are those of the procedure that holds the instruction of
// the frame, from the debug object of its module. A variable whose
// location the debug object does not give at this instruction is "not
// readable". In the frame of a caller only the frame pointer is known: a
// variable in another register is "not readable in this frame". The
// debugger computes no location that the debug object does not give.
//
// - **thread**: the number of a thread that is held or stopped.
// - **frame**: the number of a frame, as `stack` gives it.
//
// **Errors**: `No_Grant`, `Acts_For_Principal` (-1); `Absent`,
// `Debugged_Programs` (-2); `Refused` (-4); `Absent`, `Threads` or
// `Held_Threads` (-5); `Absent`, `Debug_Objects` (-6), the module of the
// frame has no debug object; `Absent`, `Stack_Frames` (-7); `Absent`,
// `Programs` (-13).
//
// ```
// debugger.locals(0, 0)
// ```
@(export, link_name = "locals")
locals :: proc "c" (thread: i64, frame: i64, result: ^[]Variable_Row, error: ^errors.Error_Record) -> i64 {
	if failure := session_of_caller(error); failure != 0 {
		return failure
	}
	place, failure := frame_of_arguments(thread, frame, true, error)
	if failure != 0 {
		return failure
	}
	object := place.found.object
	values := value_context(object)
	first, count := debug_object.variable_range_of_offset(object, place.found.offset)
	total := 0
	for index in first ..< first + count {
		variable, valid, visible := debug_object.variable_at(object, index, place.found.offset)
		if !valid || !visible {
			continue
		}
		if total < len(result^) {
			row := &result[total]
			row^ = {}
			system.format(row.name[:], variable.name)
			role: string = variable.role == .Parameter ? "parameter" : "local"
			system.format(row.role[:], role)
			type_writer := system.Writer{buffer = row.type[:]}
			debugging.type_name_write(&type_writer, object, variable.type)
			system.written(&type_writer)
			location_writer := system.Writer{buffer = row.location[:]}
			location_write(&location_writer, variable)
			system.written(&location_writer)
			value_writer := system.Writer{buffer = row.value[:]}
			if located, why := variable_locate_in_frame(place, variable); why != "" {
				system.write_part(&value_writer, why)
			} else {
				debugging.value_write(&value_writer, &values, located)
			}
			system.written(&value_writer)
		}
		total += 1
	}
	return i64(total)
}

// name_has_package says if a name has "::": the name of a global with its
// package.
name_has_package :: proc "contextless" (name: string) -> bool {
	for index in 0 ..< len(name) - 1 {
		if name[index] == ':' && name[index + 1] == ':' {
			return true
		}
	}
	return false
}

// A value that a path names, with the debug object of its type.
Named_Value :: struct {
	located: debugging.Located,
	object:  []u8,
}

// global_find gives the global with a name, in the first module of the
// program whose debug object has it.
global_find :: proc "contextless" (name: string) -> (value: Named_Value, found: bool) {
	for &record in report_modules.modules[:min(report_modules.count, op.PROGRAM_MODULE_CAPACITY)] {
		object := system.debug_object_of(&debug_names, record.hash)
		if object == nil {
			continue
		}
		if global, has := debug_object.global_by_name(object, name); has {
			return {located = {type = global.type, in_memory = true, address = record.base + global.address}, object = object}, true
		}
	}
	return {}, false
}

// path_value gives the value that a path names: a variable of the frame,
// then a global; a name with a package is a global, and needs no thread.
// `argument` is the number of the path among the parameters of the export.
// A failure gives the result of the export.
path_value :: proc "contextless" (thread: i64, frame: i64, text: string, argument: i64, error: ^errors.Error_Record) -> (value: Named_Value, failure: i64) {
	path, problem, at := debugging.path_parse(text)
	if problem != .None {
		return {}, errors.fail(error, ERROR_PATH, .Bad_Byte, .None, argument, i64(at), 0, at < len(text) ? i64(text[at]) : 0)
	}
	start: Named_Value
	found := false
	if !name_has_package(path.name) {
		place: Frame_Place
		place, failure = frame_of_arguments(thread, frame, false, error)
		if failure != 0 {
			return {}, failure
		}
		if place.found.object != nil {
			if variable, has := debug_object.variable_by_name_at(place.found.object, place.found.offset, path.name); has {
				located, why := variable_locate_in_frame(place, variable)
				if why != "" {
					return {}, errors.fail(error, ERROR_VARIABLE, .Absent, .Readable_Variables, argument)
				}
				start = Named_Value{located = located, object = place.found.object}
				found = true
			}
		}
	}
	if !found {
		start, found = global_find(path.name)
	}
	if !found {
		return {}, errors.fail(error, ERROR_VARIABLE, .Absent, .Readable_Variables, argument)
	}
	values := value_context(start.object)
	located, resolve_problem, step := debugging.path_resolve(&values, start.located, &path)
	if resolve_problem != .None {
		// value: the step of the path, from 1; found: why (debugging.Resolve_Problem).
		return {}, errors.fail(error, ERROR_PATH, .Bad_Value, .None, argument, i64(step) + 1, i64(path.step_count), i64(resolve_problem))
	}
	return {located = located, object = start.object}, 0
}

// value gives one variable or one global by a path, as one row for each of its parts: the fields of a record, the elements of an array or of a slice, or one row for a value with no part; each row has the name, the type, the value by its type and the address.
//
// The path is a name, then steps: `.field`, `[number]` and `^`
// (`pair.next^.first`, `table[3]`, `debug_target::rounds`). The name is a
// variable that is visible at the instruction of the frame, else a global.
// A global is named with its package; a name with `::` needs no held
// thread, and `thread` and `frame` are not read. The field of a pointer to
// a record is the field of the record; `^` follows a pointer.
//
// A value by its type: an integer in decimal; a boolean; a float as its
// bits in hexadecimal, because the system has no code that writes a float
// in decimal; a pointer as an address, with the procedure or the global
// that holds it, and not followed; an enumeration by the name of its
// value; a record and an array in one line, bounded; a string by a second
// read of memory, at most 64 bytes; a slice as its count and its address.
// The table has at most 64 rows.
//
// - **thread**, **frame**: as for `locals`.
// - **path**: at most 160 bytes, and 8 steps.
//
// **Errors**: `No_Grant`, `Acts_For_Principal` (-1); `Absent`,
// `Debugged_Programs` (-2); `Refused` (-4); `Absent`, `Threads` or
// `Held_Threads` (-5); `Absent`, `Stack_Frames` (-7); `Absent`,
// `Readable_Variables` (-8), no variable and no global has the name, or
// the variable is not readable at this instruction; `Bad_Byte` (-9), the
// text is not a path, with the offset of the byte; `Bad_Value` (-9), a
// step names nothing: `value` is the step from 1 and `found` says why (1
// no such field, 2 not a record, 3 not an array, 4 an index past the end,
// 5 not a pointer, 6 a pointer of 0, 7 memory that the program does not
// map); `Absent`, `Programs` (-13); `Too_Long`, `Bytes` (-15).
//
// ```
// debugger.value(0, 0, "pair.next^.first")
// ```
@(export, link_name = "value")
value :: proc "c" (thread: i64, frame: i64, path: ^string, result: ^[]Value_Row, error: ^errors.Error_Record) -> i64 {
	if failure := session_of_caller(error); failure != 0 {
		return failure
	}
	buffer: [TEXT_ARGUMENT_LIMIT]u8
	text, fits := text_copy(buffer[:], path)
	if !fits {
		return errors.fail(error, ERROR_TEXT, .Too_Long, .Bytes, 3, i64(len(path^)), TEXT_ARGUMENT_LIMIT)
	}
	named, failure := path_value(thread, frame, text, 3, error)
	if failure != 0 {
		return failure
	}
	values := value_context(named.object)
	total := 0
	for number in 0 ..< u32(debugging.VALUE_PART_LIMIT) {
		name_buffer: [16]u8
		part, name, has := debugging.value_part(&values, named.located, number, name_buffer[:])
		if !has {
			break
		}
		if total < len(result^) {
			row := &result[total]
			row^ = {}
			system.format(row.name[:], name == "" ? text : name)
			type_writer := system.Writer{buffer = row.type[:]}
			debugging.type_name_write(&type_writer, named.object, part.type)
			system.written(&type_writer)
			value_writer := system.Writer{buffer = row.value[:]}
			debugging.value_write(&value_writer, &values, part)
			system.written(&value_writer)
			if part.in_memory {
				hex_column(row.address[:], part.address)
			}
		}
		total += 1
	}
	return i64(total)
}

// source gives the source line of the instruction of a frame, as one row: the line number, the mark `=>`, the path of the file and the hash of its content at the build.
//
// The system holds no source text: the row says so in `text`. A reader
// that has the sources shows the line only from a file whose BLAKE3 hash
// is `hash`; the command `kerneltool call` does so on the host, from the
// repository.
//
// - **thread**, **frame**: as for `locals`.
//
// **Errors**: `No_Grant`, `Acts_For_Principal` (-1); `Absent`,
// `Debugged_Programs` (-2); `Refused` (-4); `Absent`, `Threads` or
// `Held_Threads` (-5); `Absent`, `Debug_Objects` (-6); `Absent`,
// `Stack_Frames` (-7); `Absent`, `Source_Places` (-10), the instruction has
// no source line; `Absent`, `Programs` (-13).
//
// ```
// debugger.source(0, 0)
// ```
@(export, link_name = "source")
source :: proc "c" (thread: i64, frame: i64, result: ^[]Source_Row, error: ^errors.Error_Record) -> i64 {
	if failure := session_of_caller(error); failure != 0 {
		return failure
	}
	place, failure := frame_of_arguments(thread, frame, true, error)
	if failure != 0 {
		return failure
	}
	line, has := debug_object.source_line_of(place.found.object, place.found.offset)
	if !has {
		return errors.fail(error, ERROR_PLACE, .Absent, .Source_Places, 2)
	}
	if len(result^) > 0 {
		row := &result[0]
		row^ = {line = i64(line.line)}
		system.format(row.mark[:], "=>")
		system.format(row.text[:], "the source text is not on this machine")
		system.format(row.path[:], line.path)
		if line.content_hash_known {
			content_hash := line.content_hash
			system.format(row.hash[:], system.Hash{content_hash[:]})
		}
	}
	return 1
}

// break_rows writes one row for each breakpoint of the debugger.
break_rows :: proc "contextless" (result: ^[]Break_Row) -> i64 {
	total := 0
	for &item, number in session.breaks {
		if item.kind == .None {
			continue
		}
		if total < len(result^) {
			row := &result[total]
			row^ = {number = i64(number), length = i64(item.length)}
			kind: string = item.kind == .Execute ? "execute" : "write"
			system.format(row.kind[:], kind)
			hex_column(row.address[:], item.address)
			system.format(row.place[:], string(item.place[:item.place_count]))
		}
		total += 1
	}
	return i64(total)
}

// break_set takes a free breakpoint, writes the breakpoints in each thread
// of the program, and gives the rows. A failure gives the result of the
// export.
break_set :: proc "contextless" (kind: op.Thread_Breakpoint_Kind, address: u64, length: u32, place: string, result: ^[]Break_Row, error: ^errors.Error_Record) -> i64 {
	free := -1
	for item, number in session.breaks {
		if item.kind == .None {
			free = number
			break
		}
	}
	if free < 0 {
		return errors.fail(error, ERROR_BREAKPOINTS, .Full, .Breakpoints, 0, 0, BREAK_CAPACITY)
	}
	item := &session.breaks[free]
	item^ = {kind = kind, address = address, length = length}
	item.place_count = len(system.format(item.place[:], place))
	if status := breaks_apply(); status != .Ok {
		item^ = {}
		breaks_apply()
		return refused(error, status)
	}
	return break_rows(result)
}

// break_at sets an execute breakpoint at a procedure or at a source line, and gives one row for each breakpoint of the debugger.
//
// The place is the full name of a procedure (`fault::three`): the
// breakpoint is at its first instruction. Or it is a file and a line
// (`programs/fault/main.odin:15`): the breakpoint is at the lowest
// instruction of the first row of the line table with that file and that
// line. The debug objects of the modules of the program give both. A
// breakpoint is a debug register of each thread of the program, not a
// byte in the code: the debugger has four, for breakpoints and watches
// together.
//
// - **place**: at most 160 bytes.
//
// **Errors**: `No_Grant`, `Acts_For_Principal` (-1); `Absent`,
// `Debugged_Programs` (-2); `Refused` (-4), the kernel refused the
// breakpoints; `Absent`, `Debug_Objects` (-6), no module of the program
// has a debug object; `Absent`, `Source_Places` (-10), no procedure and no
// line has this place; `Full`, `Breakpoints` (-11), the four breakpoints
// are in use; `Absent`, `Programs` (-13); `Too_Long`, `Bytes` (-15).
//
// ```
// debugger.break_at("fault::three")
// debugger.break_at("programs/fault/main.odin:15")
// ```
@(export, link_name = "break_at")
break_at :: proc "c" (place: ^string, result: ^[]Break_Row, error: ^errors.Error_Record) -> i64 {
	if failure := session_of_caller(error); failure != 0 {
		return failure
	}
	buffer: [TEXT_ARGUMENT_LIMIT]u8
	text, fits := text_copy(buffer[:], place)
	if !fits {
		return errors.fail(error, ERROR_TEXT, .Too_Long, .Bytes, 1, i64(len(place^)), TEXT_ARGUMENT_LIMIT)
	}
	kind, name, line, parsed := debugging.place_parse(text)
	if !parsed {
		return errors.fail(error, ERROR_PLACE, .Absent, .Source_Places, 1)
	}
	described := 0
	for &record in report_modules.modules[:min(report_modules.count, op.PROGRAM_MODULE_CAPACITY)] {
		object := system.debug_object_of(&debug_names, record.hash)
		if object == nil {
			continue
		}
		described += 1
		offset: u64
		has: bool
		if kind == .Procedure {
			offset, has = debugging.procedure_start_by_name(object, name)
		} else {
			offset, has = debugging.line_first_offset(object, name, line)
		}
		if has {
			return break_set(.Execute, record.base + offset, 0, text, result, error)
		}
	}
	if described == 0 {
		return errors.fail(error, ERROR_NO_DEBUG_OBJECT, .Absent, .Debug_Objects, 1)
	}
	return errors.fail(error, ERROR_PLACE, .Absent, .Source_Places, 1)
}

// address_of_text gives the address that a text names: an address in
// hexadecimal ("0x403010") or in decimal, or the path of a global with
// its package. A failure gives the result of the export.
address_of_text :: proc "contextless" (text: string, argument: i64, error: ^errors.Error_Record) -> (address: u64, failure: i64) {
	if parsed, is_address := debugging.address_parse(text); is_address {
		return parsed, 0
	}
	named: Named_Value
	// A variable of a frame has no thread here: -1 names none.
	named, failure = path_value(-1, 0, text, argument, error)
	if failure != 0 {
		return 0, failure
	}
	if !named.located.in_memory {
		return 0, errors.fail(error, ERROR_ADDRESS, .Bad_Value, .None, argument)
	}
	return named.located.address, 0
}

// watch sets a data breakpoint on the bytes that the program writes, and gives one row for each breakpoint of the debugger.
//
// A thread that writes one of the bytes stops after the instruction of
// the write. An access that the kernel makes for the program is not seen.
//
// - **place**: an address in hexadecimal (`0x403010`) or in decimal, or
//   the path of a global with its package (`debug_target::rounds`).
// - **length**: 1, 2, 4 or 8 bytes; the address is a multiple of it.
//
// **Errors**: `No_Grant`, `Acts_For_Principal` (-1); `Absent`,
// `Debugged_Programs` (-2); `Refused` (-4); `Absent`, `Readable_Variables`
// (-8), no global has the name; `Bad_Byte` or `Bad_Value` (-9), the path;
// `Full`, `Breakpoints` (-11); `Bad_Value` (-12), a length that is not 1,
// 2, 4 or 8; `Not_Multiple` (-12), the address is not a multiple of the
// length; `Absent`, `Programs` (-13); `Too_Long`, `Bytes` (-15).
//
// ```
// debugger.watch("debug_target::rounds", 8)
// ```
@(export, link_name = "watch")
watch :: proc "c" (place: ^string, length: i64, result: ^[]Break_Row, error: ^errors.Error_Record) -> i64 {
	if failure := session_of_caller(error); failure != 0 {
		return failure
	}
	buffer: [TEXT_ARGUMENT_LIMIT]u8
	text, fits := text_copy(buffer[:], place)
	if !fits {
		return errors.fail(error, ERROR_TEXT, .Too_Long, .Bytes, 1, i64(len(place^)), TEXT_ARGUMENT_LIMIT)
	}
	if length != 1 && length != 2 && length != 4 && length != 8 {
		return errors.fail(error, ERROR_ADDRESS, .Bad_Value, .None, 2, length, 8)
	}
	address, failure := address_of_text(text, 1, error)
	if failure != 0 {
		return failure
	}
	if address % u64(length) != 0 {
		return errors.fail(error, ERROR_ADDRESS, .Not_Multiple, .None, 1, i64(address), length, i64(address % u64(length)))
	}
	return break_set(.Write, address, u32(length), text, result, error)
}

// breaks gives one row for each breakpoint of the debugger: its number, its kind (`execute` or `write`), its address, the bytes of a watch, and the text that named it.
//
// **Errors**: `No_Grant`, `Acts_For_Principal` (-1); `Absent`,
// `Debugged_Programs` (-2); `Absent`, `Programs` (-13).
//
// ```
// debugger.breaks()
// ```
@(export, link_name = "breaks")
breaks :: proc "c" (result: ^[]Break_Row, error: ^errors.Error_Record) -> i64 {
	if failure := session_of_caller(error); failure != 0 {
		return failure
	}
	return break_rows(result)
}

// break_remove removes one breakpoint of the debugger from each thread of the program, and gives one row for each breakpoint that stays.
//
// - **number**: the number of a breakpoint, as `breaks()` gives it.
//
// **Errors**: `No_Grant`, `Acts_For_Principal` (-1); `Absent`,
// `Debugged_Programs` (-2); `Refused` (-4); `Absent`, `Breakpoints` (-11),
// the number names no breakpoint; `Absent`, `Programs` (-13).
//
// ```
// debugger.break_remove(0)
// ```
@(export, link_name = "break_remove")
break_remove :: proc "c" (number: i64, result: ^[]Break_Row, error: ^errors.Error_Record) -> i64 {
	if failure := session_of_caller(error); failure != 0 {
		return failure
	}
	if number < 0 || number >= BREAK_CAPACITY || session.breaks[number].kind == .None {
		return errors.fail(error, ERROR_BREAKPOINTS, .Absent, .Breakpoints, 1)
	}
	session.breaks[number] = {}
	if status := breaks_apply(); status != .Ok {
		return refused(error, status)
	}
	return break_rows(result)
}

// step_one runs one instruction of a thread that is held or stopped: it
// writes the trap flag in its registers, lets it run, and waits for its
// next stop until a deadline. `stepped` is false when the thread did not
// stop in time: a thread in a wait of the kernel runs its next instruction
// only when its wait ends; its stop then comes as an event.
step_one :: proc "contextless" (number: u64, deadline: u64) -> (stepped: bool, at_breakpoint: bool, status: system.Status) {
	image_of_thread: op.Thread_Registers
	image_of_thread, status = system.thread_registers_read(session.program, number)
	if status != .Ok {
		return false, false, status
	}
	image_of_thread.rflags |= FLAG_TRAP
	status = system.thread_registers_write(session.program, number, image_of_thread)
	if status != .Ok {
		return false, false, status
	}
	session.threads[number].stepping = true
	status = thread_release(number)
	if status != .Ok {
		return false, false, status
	}
	for {
		record, came := system.fault_record_next(deadline)
		if !came {
			return false, false, .Ok
		}
		record_keep(record, record.thread == number)
		if record.thread == number {
			return true, record.kind == .Debug && record.error_code & op.DEBUG_STATUS_BREAKPOINTS != 0, .Ok
		}
	}
}

// step runs one instruction of a thread that is held or stopped, and gives its row at its new instruction.
//
// The debugger writes the trap flag in the registers of the thread and
// lets it run: the processor stops it after one instruction. A thread
// that waits in the kernel runs its next instruction only when its wait
// ends: the export waits 1000 ms at most, then gives the row of a thread
// that runs, with `pending` 1, and the stop comes later as an event. The
// end of a step that the export waited for is its result, and no event.
//
// - **thread**: the number of a thread that is held or stopped.
//
// **Errors**: `No_Grant`, `Acts_For_Principal` (-1); `Absent`,
// `Debugged_Programs` (-2); `Refused` (-4); `Absent`, `Threads` or
// `Held_Threads` (-5); `Absent`, `Programs` (-13).
//
// ```
// debugger.step(0)
// ```
@(export, link_name = "step")
step :: proc "c" (thread: i64, result: ^[]Thread_Row, error: ^errors.Error_Record) -> i64 {
	if failure := session_of_caller(error); failure != 0 {
		return failure
	}
	number, failure := thread_of_argument(thread, true, error)
	if failure != 0 {
		return failure
	}
	stepped, _, status := step_one(number, system.time() + STEP_WAIT_MILLISECONDS)
	if status != .Ok {
		return refused(error, status)
	}
	return thread_rows(result, thread, i64(stepped ? 0 : 1))
}

// step_line runs a thread that is held or stopped until the source line of its instruction changes, and gives its row there.
//
// It runs one instruction at a time, until the instruction has a source
// line that is not the line of the start, in the same file or in another:
// it enters a procedure that the line calls. A breakpoint or a watch that
// the thread reaches before the line changes ends the export there: the
// row is the row of the thread at the breakpoint, with `pending` 0, and
// the stop is also an event. The whole export has two
// bounds: 4096 instructions, and 2000 ms, because the debugged program
// chooses how long one of its instructions takes and the service serves
// each caller with one thread. At a bound the row has `pending` 1: the
// line did not change yet. When its state is `stopped`, call `step_line`
// again; when the thread runs (it waits in the kernel), its stop comes as
// an event.
//
// - **thread**: the number of a thread that is held or stopped.
//
// **Errors**: as for `step`.
//
// ```
// debugger.step_line(0)
// ```
@(export, link_name = "step_line")
step_line :: proc "c" (thread: i64, result: ^[]Thread_Row, error: ^errors.Error_Record) -> i64 {
	if failure := session_of_caller(error); failure != 0 {
		return failure
	}
	number, failure := thread_of_argument(thread, true, error)
	if failure != 0 {
		return failure
	}
	image_of_thread, status := system.thread_registers_read(session.program, number)
	if status != .Ok {
		return refused(error, status)
	}
	start := place_of_address(image_of_thread.rip).place
	deadline := system.time() + STEP_LINE_WAIT_MILLISECONDS
	pending: i64 = 1
	for _ in 0 ..< STEP_LINE_INSTRUCTION_LIMIT {
		if system.time() >= deadline {
			break
		}
		stepped, at_breakpoint: bool
		stepped, at_breakpoint, status = step_one(number, deadline)
		if status != .Ok {
			return refused(error, status)
		}
		if !stepped {
			break
		}
		// A breakpoint or a watch that the thread reached: it stops
		// there, as it does with no step, and the stop is an event.
		if at_breakpoint {
			pending = 0
			break
		}
		image_of_thread, status = system.thread_registers_read(session.program, number)
		if status != .Ok {
			return refused(error, status)
		}
		now := place_of_address(image_of_thread.rip).place
		if now.line != 0 && (now.line != start.line || now.file != start.file) {
			pending = 0
			break
		}
	}
	return thread_rows(result, thread, pending)
}

// memory gives the bytes of the program from an address, sixteen in each row: the address, the bytes in hexadecimal, and their printable characters.
//
// The kernel reads only the pages that the program maps, can read and
// that have a frame: the table ends before the first page that is not so.
// The read changes nothing of the program.
//
// - **place**: an address in hexadecimal (`0x403010`) or in decimal, or
//   the path of a global with its package.
// - **count**: 1 to 4096 bytes.
//
// **Errors**: `No_Grant`, `Acts_For_Principal` (-1); `Absent`,
// `Debugged_Programs` (-2); `Absent`, `Readable_Variables` (-8); `Bad_Byte`
// or `Bad_Value` (-9), the path; `Bad_Value` (-12), a count that is not 1
// to 4096; `Bad_Address` (-12), the program does not map the first byte;
// `Absent`, `Programs` (-13); `Too_Long`, `Bytes` (-15).
//
// ```
// debugger.memory("debug_target::table", 64)
// ```
@(export, link_name = "memory")
memory :: proc "c" (place: ^string, count: i64, result: ^[]Memory_Row, error: ^errors.Error_Record) -> i64 {
	if failure := session_of_caller(error); failure != 0 {
		return failure
	}
	buffer: [TEXT_ARGUMENT_LIMIT]u8
	text, fits := text_copy(buffer[:], place)
	if !fits {
		return errors.fail(error, ERROR_TEXT, .Too_Long, .Bytes, 1, i64(len(place^)), TEXT_ARGUMENT_LIMIT)
	}
	if count < 1 || count > MEMORY_COUNT_LIMIT {
		return errors.fail(error, ERROR_ADDRESS, .Bad_Value, .None, 2, count, MEMORY_COUNT_LIMIT)
	}
	address, failure := address_of_text(text, 1, error)
	if failure != 0 {
		return failure
	}
	thread, has_thread := any_thread()
	copied: u64
	status := system.Status.Bad_State
	if has_thread {
		copied, status = system.thread_memory_read(session.program, thread, address, memory_bytes[:count])
	}
	if status != .Ok || copied == 0 {
		return errors.fail(error, ERROR_ADDRESS, .Bad_Address, .None, 1, i64(address), count)
	}
	digits := system.HEX_DIGITS
	total := 0
	for start := 0; start < int(copied); start += 16 {
		if total < len(result^) {
			row := &result[total]
			row^ = {}
			hex_column(row.address[:], address + u64(start))
			for index in 0 ..< min(16, int(copied) - start) {
				b := memory_bytes[start + index]
				row.bytes[index * 3] = digits[b >> 4]
				row.bytes[index * 3 + 1] = digits[b & 15]
				if index < 15 && start + index + 1 < int(copied) {
					row.bytes[index * 3 + 2] = ' '
				}
				row.text[index] = b >= 0x20 && b <= 0x7E ? b : '.'
			}
		}
		total += 1
	}
	return i64(total)
}

// event_rows writes one row for each stop that the service kept, and
// forgets the stops that it gave.
event_rows :: proc "contextless" (result: ^[]Event_Row) -> i64 {
	given := min(session.event_count, len(result^))
	for index in 0 ..< given {
		event := &session.events[index]
		row := &result[index]
		row^ = {thread = i64(event.thread)}
		system.format(row.kind[:], string(event.kind[:event.kind_count]))
		hex_column(row.instruction[:], event.instruction)
		place_columns(place_of_address(event.instruction), row.module[:], row.procedure[:], &row.offset, row.file[:], &row.line)
	}
	total := session.event_count
	// The stops that the table had no room for stay for the next call.
	for index in given ..< session.event_count {
		session.events[index - given] = session.events[index]
	}
	session.event_count -= given
	if session.events_lost != 0 {
		system.log("debugger: ", session.events_lost, " stops of ", system.Module_Name{session_name()}, " found the table of the events full, and have no row")
		session.events_lost = 0
	}
	return i64(total)
}

// events gives one row for each stop of a thread since the last call: the thread, the kind (`breakpoint N`, `watch N`, `step`, `int3` or `int1`), and the instruction where the thread goes on, with its module, its procedure, its file and its line.
//
// The end of a step that `step` or `step_line` waited for is the result of
// that export, and not an event; a step that ended after its export
// stopped waiting is an event of the kind `step`.
//
// A thread that stopped waits for the debugger: `release`, `step` or
// `continue_all` lets it run. After an execute breakpoint the instruction
// is the one of the breakpoint, which did not run; after a watch and after
// a step it is the next one. The service keeps 32 stops.
//
// **Errors**: `No_Grant`, `Acts_For_Principal` (-1); `Absent`,
// `Debugged_Programs` (-2); `Absent`, `Programs` (-13).
//
// ```
// debugger.events()
// ```
@(export, link_name = "events")
events :: proc "c" (result: ^[]Event_Row, error: ^errors.Error_Record) -> i64 {
	if failure := session_of_caller(error); failure != 0 {
		return failure
	}
	return event_rows(result)
}

// wait_stop waits until a thread of the program stops, at most the given milliseconds and 3000, and gives the rows of `events`.
//
// A caller learns of a stop with this export, with no loop of `events()`:
// the call returns at once when a stop waits already, at the next stop,
// or with no row when the time ends. The service serves no other call
// while it waits, and the service `remote` ends a call and its connection
// after 5000 ms: so the wait is 3000 ms at most, whatever the caller
// gives. A caller that waits longer calls again, or reads `events()` after
// the line of the stop in the log.
//
// - **milliseconds**: the longest wait; 0 or less does not wait; more than
//   3000 is 3000.
//
// **Errors**: as for `events`.
//
// ```
// debugger.wait_stop(3000)
// ```
@(export, link_name = "wait_stop")
wait_stop :: proc "c" (milliseconds: i64, result: ^[]Event_Row, error: ^errors.Error_Record) -> i64 {
	if failure := session_of_caller(error); failure != 0 {
		return failure
	}
	if session.event_count == 0 && milliseconds > 0 {
		deadline := system.time() + u64(min(milliseconds, WAIT_STOP_LIMIT_MILLISECONDS))
		if record, came := system.fault_record_next(deadline); came {
			record_keep(record)
			records_take()
		}
	}
	return event_rows(result)
}
