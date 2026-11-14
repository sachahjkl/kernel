// The debugger service: the commands of a debugger, as exports.
//
// A debugger stops a program where its author asks, shows its threads,
// its registers, its stack and its variables, and runs it one instruction
// at a time. This program is the one debugger of the system: the console,
// a window, and a developer on another machine through the service
// `remote` call the same exports, and each export gives a table of
// records, never text to parse.
//
// **What it is for.** `attach("clock")` asks the root service for the
// handle of the program with the right Debug, on behalf of the caller. The
// root service decides: the caller must act for the principal whose
// session runs the program, and each grant of the program must be a grant
// that the caller holds itself. Then `threads()`, `hold(1)`, `stack(1)`,
// `locals(1, 0)`, `value(1, 0, "pair.next^.first")`, `break_at("fault::three")`,
// `step(1)`, `continue_all()` and `detach()` act on that program.
//
// **How it works.** The service is the debugger of the program for the
// kernel: its main thread is the debug handler, so the breakpoints and the
// single steps of the program become fault records of this thread
// (docs/ARCHITECTURE.md, "The debugger of a program"). It reads the threads
// and the module records of the program with `Inspect`, the registers and
// the memory with `Thread_Control`, and the names, the lines, the types
// and the variables in the debug object of each module, which it takes
// from the debug image by the hash of the module. It writes no byte in the
// program: a breakpoint is a debug register of a thread.
//
// **One program at a time.** The service debugs one program, for one
// caller. A second `attach` while it does is refused with `Full`
// (`Debugged_Programs`). The debugging ends at `detach()`, when the
// caller disconnects or stops, when the grant `debug` of the caller is
// revoked, and when the program stops: the kernel then gives the program
// back each thread that the debugger held.
//
// **Start**: the root service starts it when a caller connects to
// `debugger` (`connect("debugger")` in the console, or the first command of
// the debugger there). It has no window.
//
// **Grants**, as the root service gives them:
//
// - **Serve**: its exports.
// - **Debugger**: the command `Debug` of the root ring, and no other.
// - **Inspect**: the thread report and the module report of a program.
// - **Debug_Image**: the debug objects.
// - **Image**: the name of each module, from its hash.
//
// **What a reader sees**: the log has "debugger: serves its exports", then
// one line for each attach, each stop of a thread at a breakpoint or a
// watch, and each end of a debugging.
//
// The design: (docs/TOOLS.md, "The debugger").
package debugger

import "base:intrinsics"
import debug_object "modus:contract/debug_object"
import "modus:contract/errors"
import "modus:contract/isolated"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:support/debugging"
import "modus:support/system"

// The results of an export that fails: a negative number, with an error
// record.
ERROR_ACTS_FOR_PRINCIPAL :: -1 // No_Grant, Acts_For_Principal: the caller does not act for the principal.
ERROR_NOT_ATTACHED :: -2 // Absent, Debugged_Programs: the caller attached to no program.
ERROR_BUSY :: -3 // Full, Debugged_Programs: the service debugs a program already.
ERROR_REFUSED :: -4 // The root service or the kernel refused: the record is theirs, or Refused with the status.
ERROR_THREAD :: -5 // Absent, Threads or Held_Threads: no such thread, or the thread is not held.
ERROR_NO_DEBUG_OBJECT :: -6 // Absent, Debug_Objects: no debug object describes the module of the address.
ERROR_FRAME :: -7 // Absent, Stack_Frames: the stack has no frame with this number.
ERROR_VARIABLE :: -8 // Absent, Readable_Variables: no variable or global has the name, or it is not readable there.
ERROR_PATH :: -9 // Bad_Byte or Bad_Value: the text is not a path, or a step of the path names nothing.
ERROR_PLACE :: -10 // Absent, Source_Places: no procedure and no line has the place of the breakpoint.
ERROR_BREAKPOINTS :: -11 // Full or Absent, Breakpoints: no breakpoint is free, or the number names none.
ERROR_ADDRESS :: -12 // Bad_Address or Bad_Value: the program does not map the address, or the text is no address.
ERROR_ENDED :: -13 // Absent, Programs: the program stopped, or the debug access ended.
ERROR_AMBIGUOUS :: -14 // Bad_Value, Programs: two programs have the name and the module; the service cannot tell which one the handle names.
ERROR_TEXT :: -15 // Too_Long, Bytes: a text argument is longer than the service takes.

PROGRAM_SLOTS_SEARCHED :: 256 // The program slots that an attach searches for the name.
THREAD_CAPACITY :: op.THREAD_REPORT_CAPACITY // The threads of one program.
BREAK_CAPACITY :: op.THREAD_BREAKPOINT_CAPACITY // The breakpoints of the debugger: the debug address registers of a thread.
EVENT_CAPACITY :: 32 // The stops that the service keeps until `events()` gives them.
PLACE_TEXT_SIZE :: 96 // The bytes of the place of a breakpoint.
TEXT_ARGUMENT_LIMIT :: 160 // The bytes of a text argument: a path, a place.
// The bounds of the exports that wait. The service has one thread and
// serves each caller, and the debugged program chooses how long one of its
// instructions takes: so no export waits longer than a stated bound. Each
// bound is under the 5000 ms after which the service `remote` ends a call
// and its connection (CALL_LIMIT in src/programs/remote), with room for the
// work around the wait.
ROOT_ANSWER_MILLISECONDS :: 2000 // `attach`: the wait for the answer of the root service. A later answer is taken when it comes (root_completion_take).
STEP_WAIT_MILLISECONDS :: 1000 // `step`: the wait for the record of one step. A thread in a wait of the kernel steps only when its wait ends: its stop then comes as an event.
STEP_LINE_WAIT_MILLISECONDS :: 2000 // `step_line`: the whole export, for each of its steps together.
WAIT_STOP_LIMIT_MILLISECONDS :: 3000 // `wait_stop`: the longest wait, whatever the caller asks.
ROOT_REQUEST_CAPACITY :: 8 // The commands to the root service whose completion did not come yet.
STEP_LINE_INSTRUCTION_LIMIT :: 4096 // The instructions of one `step_line`.
MEMORY_COUNT_LIMIT :: op.THREAD_MEMORY_READ_LIMIT // The bytes of one `memory`.

FLAG_TRAP :: u64(1) << 8 // The trap flag: one instruction, then a Debug trap.
PUSH_FRAME_POINTER :: 0x55 // The first byte of a procedure that keeps the frame pointer: push rbp.

// One breakpoint of the debugger: the place `number` of the debug address
// registers of each thread of the program.
Break :: struct {
	kind:        op.Thread_Breakpoint_Kind, // None: the place is free.
	address:     u64,
	length:      u32, // A data breakpoint: 1, 2, 4 or 8.
	place:       [PLACE_TEXT_SIZE]u8, // The text that named it.
	place_count: int,
}

// What the service holds of one thread of the program.
Thread_Hold :: struct {
	held:     bool, // The service stopped it (`hold`): its stop count has one stop of the debugger.
	waits:    bool, // It waits for the answer of `record`: a breakpoint or a step stopped it.
	stepping: bool, // The service wrote the trap flag in its registers, for one step.
	record:   op.Fault_Record, // The record to answer.
}

// One stop of a thread, until `events()` gives it.
Event :: struct {
	thread:      u64,
	instruction: u64,
	kind:        [28]u8,
	kind_count:  int,
}

// The program that the service debugs, and for whom.
Session :: struct {
	attached:       bool,
	program:        system.Handle, // The handle with the right Debug, from the root service.
	caller_ring:    system.Handle, // The call ring of the connection of the caller: only this caller acts on the program.
	name:           [32]u8,
	name_count:     int,
	slot:           u64, // The program slot, for the reports of Inspect.
	program_serial: u64, // The serial of the program of the slot: another serial is another program.
	breaks:         [BREAK_CAPACITY]Break,
	threads:        [THREAD_CAPACITY]Thread_Hold, // By the number of the thread.
	events:         [EVENT_CAPACITY]Event,
	event_count:    int,
	events_lost:    u64, // The stops that found `events` full.
}

machine: system.Handle
requests_memory: system.Handle // The memory of the ring to the root service: a handle that the root service gives comes through it.
image: []u8
debug_names: system.Debug_Names
service: system.Service
requests: ring.Ring
request_count: u32

// One command Debug that this service sent to the root service, until its
// completion comes: the wait for a completion is state, so a completion
// that comes after the export stopped waiting is still taken.
Root_Request :: struct {
	tag:        u32, // The tag of the command. 0: the place is free.
	name:       [32]u8, // The program.
	name_count: int,
	ring:       system.Handle, // The call ring of the caller.
	end:        bool, // The command ends a debug access; else it asks for one.
	abandoned:  bool, // No export waits for the completion.
	unsent:     bool, // The root ring was full: the loop of the entry sends it again.
}

root_requests: [ROOT_REQUEST_CAPACITY]Root_Request
session: Session
// The reports of the program of the session, read again at each export.
report_modules: op.Module_Report
report_threads: op.Thread_Table_Report

inspect_call :: proc "contextless" (kind: op.Inspect_Kind, index: u64, record: rawptr, size: int) -> bool {
	_, status := system.call(.Inspect, u64(machine), u64(kind), index, u64(uintptr(record)), u64(size))
	return status == .Ok
}

session_name :: proc "contextless" () -> string {
	return string(session.name[:session.name_count])
}

// text_copy copies a text argument out of the call region: the caller can
// change the call region during the call. False: the text is longer than
// the buffer.
text_copy :: proc "contextless" (buffer: []u8, text: ^string) -> (copied: string, ok: bool) {
	source := text^
	if len(source) > len(buffer) {
		return "", false
	}
	count := copy(buffer, source)
	return string(buffer[:count]), true
}

// refused gives the result of an export that the kernel refused.
refused :: proc "contextless" (error: ^errors.Error_Record, status: system.Status) -> i64 {
	return errors.fail(error, ERROR_REFUSED, .Refused, .None, 0, 0, 0, i64(status))
}

// root_request_send sends one command Debug to the root service and keeps
// it until its completion comes. With `end`, the command tells the root
// service that the debugging of the program ended for the caller: no
// export waits for its completion, and a command that the ring has no room
// for is sent again later. tag is 0 when the table of the requests is
// full, or when a command that asks for an access was not sent.
root_request_send :: proc "contextless" (name: string, connection_ring: system.Handle, end: bool) -> (tag: u32) {
	if requests.head == nil {
		return 0
	}
	free: ^Root_Request
	for &item in root_requests {
		if item.tag == 0 {
			free = &item
			break
		}
	}
	if free == nil {
		system.log("debugger: ", u64(ROOT_REQUEST_CAPACITY), " commands wait for the root service: no room for one more")
		return 0
	}
	request_count += 1
	free^ = {tag = request_count, ring = connection_ring, end = end, abandoned = end}
	free.name_count = copy(free.name[:], name)
	if !root_request_put(free) {
		if !end {
			free^ = {}
			return 0
		}
		free.unsent = true
	}
	return free.tag
}

// root_request_put writes the command of a request in the root ring.
root_request_put :: proc "contextless" (request: ^Root_Request) -> bool {
	packed := system.name_pack(string(request.name[:request.name_count]))
	return system.send(&requests.commands, ring.Record{kind = u32(system.Root_Command.Debug), tag = request.tag, values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3], 4 = u64(request.ring), 5 = u64(request.end)}})
}

// root_completion_take takes a completion that no export waits for. The
// completion of an end needs nothing. A completion that gives a debug
// access after its export stopped waiting: the handle is closed, and the
// root service is told that the access ended, so that no handle and no
// record of the root service stays; it is not told when a newer debugging
// or a newer request of the same caller for the same program exists.
root_completion_take :: proc "contextless" (record: ring.Record) {
	for &item in root_requests {
		if item.tag == 0 || item.tag != record.tag {
			continue
		}
		request := item
		item = {}
		if request.end || system.Status(record.kind) != .Ok {
			return
		}
		handle := system.Handle(record.values[0])
		if kind, _, through := system.handle_state(handle, requests_memory); kind == .Program && through {
			system.close(handle)
		}
		name := string(request.name[:request.name_count])
		// The same caller can have asked again for the same program since:
		// the root service keeps one record for the two handles, and an
		// end command ends each handle of the program in this service.
		// So, with a session or another request for that program and that
		// ring, only the late handle is closed: the kernel ends a
		// debugging at the close of the last handle with Debug, and the
		// session holds another one.
		in_use := session.attached && session.caller_ring == request.ring && session_name() == name
		for &other in root_requests {
			if other.tag != 0 && !other.end && other.ring == request.ring && string(other.name[:other.name_count]) == name {
				in_use = true
			}
		}
		if in_use {
			system.log("debugger: the root service answered an earlier attach to ", system.Module_Name{name}, " after the export stopped waiting: its handle is closed, and the debugging that runs stays")
			return
		}
		system.log("debugger: the root service answered the attach to ", system.Module_Name{name}, " after the export stopped waiting: the debug access is given back")
		root_request_send(name, request.ring, true)
		return
	}
}

// root_completions_take reads each completion of the root ring. It gives
// the completion with the tag `wanted`, when it is there; each other one
// goes to root_completion_take.
root_completions_take :: proc "contextless" (wanted: u32) -> (completion: ring.Record, found: bool) {
	for _ in 0 ..< ring.CAPACITY {
		record, has_record := system.receive(&requests.completions)
		if !has_record {
			break
		}
		if wanted != 0 && record.tag == wanted {
			for &item in root_requests {
				if item.tag == wanted {
					item = {}
				}
			}
			return record, true
		}
		root_completion_take(record)
	}
	return {}, false
}

// root_requests_send_again sends each end that the root ring had no room
// for.
root_requests_send_again :: proc "contextless" () {
	for &item in root_requests {
		if item.tag != 0 && item.unsent && root_request_put(&item) {
			item.unsent = false
		}
	}
}

// root_debug asks the root service for the handle of a program with the
// right Debug, on behalf of the caller of the connection with a call ring,
// and waits for the answer at most ROOT_ANSWER_MILLISECONDS. answered is
// false when no completion came in that time: the request stays, and its
// completion is taken when it comes.
root_debug :: proc "contextless" (name: string, connection_ring: system.Handle) -> (completion: ring.Record, answered: bool) {
	tag := root_request_send(name, connection_ring, false)
	if tag == 0 {
		return {}, false
	}
	limit := system.time() + ROOT_ANSWER_MILLISECONDS
	for {
		if record, found := root_completions_take(tag); found {
			return record, true
		}
		wait: system.Wait
		system.wait_records(&wait, &requests.completions)
		if system.wait_end(&wait, limit) >= limit {
			for &item in root_requests {
				if item.tag == tag {
					item.abandoned = true
				}
			}
			return {}, false
		}
	}
}

// root_debug_end tells the root service that the debugging of a program
// ended for a caller. It does not wait for the answer.
root_debug_end :: proc "contextless" (name: string, connection_ring: system.Handle) {
	root_request_send(name, connection_ring, true)
}

// slot_find gives the slot of the program with a name whose module records
// hold the module with a hash: the program that the root service named.
// `matches` is the count of such programs: the service acts only on one.
slot_find :: proc "contextless" (name: string, hash: [32]u8) -> (slot: u64, program_serial: u64, matches: int) {
	system_report: op.System_Report
	if !inspect_call(.System, 0, &system_report, size_of(system_report)) {
		return 0, 0, 0
	}
	for candidate in 1 ..< min(system_report.program_slots, PROGRAM_SLOTS_SEARCHED) {
		program: op.Program_Report
		if !inspect_call(.Program, candidate, &program, size_of(program)) || program.state == .None || program.state == .Stopped || system.name_of(program.name[:]) != name {
			continue
		}
		if !inspect_call(.Modules, candidate, &report_modules, size_of(report_modules)) || report_modules.program_serial != program.program_serial {
			continue
		}
		for &record in report_modules.modules[:min(report_modules.count, op.PROGRAM_MODULE_CAPACITY)] {
			if record.hash == hash {
				matches += 1
				if matches == 1 {
					slot, program_serial = candidate, program.program_serial
				}
				break
			}
		}
	}
	return slot, program_serial, matches
}

// session_end forgets the program of the session, after the debugging
// ended. The records of the fault ring that nobody read are dropped: their
// threads run again, by the end of the debugging in the kernel.
session_end :: proc "contextless" (why: string) {
	if !session.attached {
		return
	}
	system.log("debugger: the debugging of ", system.Module_Name{session_name()}, " ended: ", why)
	system.close(session.program)
	// The root service forgets the debug access: another caller can then
	// ask for this program.
	root_debug_end(session_name(), session.caller_ring)
	session = {}
	for {
		if _, more := record_next_ready(); !more {
			break
		}
	}
}

// session_of_caller checks that the caller of the export that runs is the
// caller that attached, and that the program and the debug access are
// still there; it reads the reports of the program again, and takes the
// records of the fault ring. A failure gives the result of the export.
// `needs_the_grant` is false for the detach: a caller that lost the grant
// to act for the principal can still end its debugging, so that no thread
// of the program stays stopped.
session_of_caller :: proc "contextless" (error: ^errors.Error_Record, needs_the_grant := true) -> (failure: i64) {
	if session.attached {
		// The root service revokes the handle when the grant `debug` of
		// the caller is revoked, when another revocation takes the debug
		// access away, and when the caller disconnects or stops.
		if kind, _, _ := system.handle_state(session.program); kind != .Program {
			session_end("the debug access was revoked")
		}
	}
	caller := system.service_caller()
	if caller == nil || needs_the_grant && caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL == 0 {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	if !session.attached || session.caller_ring != caller.ring_memory {
		return errors.fail(error, ERROR_NOT_ATTACHED, .Absent, .Debugged_Programs)
	}
	program: op.Program_Report
	if !inspect_call(.Program, session.slot, &program, size_of(program)) || program.program_serial != session.program_serial || program.state == .None || program.state == .Stopped {
		session_end("the program stopped")
		return errors.fail(error, ERROR_ENDED, .Absent, .Programs)
	}
	reports_read()
	records_take()
	return 0
}

// reports_read reads the module records and the threads of the program of
// the session. A report of another program in the slot is dropped.
reports_read :: proc "contextless" () {
	if !inspect_call(.Modules, session.slot, &report_modules, size_of(report_modules)) || report_modules.program_serial != session.program_serial {
		report_modules = {}
	}
	if !inspect_call(.Threads, session.slot, &report_threads, size_of(report_threads)) || report_threads.program_serial != session.program_serial {
		report_threads = {}
	}
	// A thread that ended holds nothing.
	for &hold, number in session.threads {
		if (hold.held || hold.waits) && thread_report(u64(number)) == nil {
			hold = {}
		}
	}
}

// thread_report gives the report of the thread with a number, or nil.
thread_report :: proc "contextless" (number: u64) -> ^op.Thread_Report {
	for &item in report_threads.threads[:min(report_threads.count, op.THREAD_REPORT_CAPACITY)] {
		if u64(item.number) == number {
			return &item
		}
	}
	return nil
}

// any_thread gives the number of a live thread of the program: the read of
// its memory names the program through one of its threads.
any_thread :: proc "contextless" () -> (number: u64, ok: bool) {
	if report_threads.count == 0 {
		return 0, false
	}
	return u64(report_threads.threads[0].number), true
}

// record_next_ready gives the next record of the fault ring of this
// thread, the debug handler, with no wait.
record_next_ready :: proc "contextless" () -> (record: op.Fault_Record, ok: bool) {
	own := system.thread_record()
	written := intrinsics.atomic_load(&own.fault_written)
	read := intrinsics.atomic_load(&own.fault_read)
	if written == read {
		return {}, false
	}
	record = own.fault_records[read % op.FAULT_RECORD_CAPACITY]
	// The place is free again for the kernel after this store.
	intrinsics.atomic_store(&own.fault_read, read + 1)
	return record, true
}

// records_take takes each record that waits in the fault ring: its thread
// waits for the answer of the debugger, and the stop is an event.
records_take :: proc "contextless" () {
	for _ in 0 ..< op.FAULT_RECORD_CAPACITY {
		record, ok := record_next_ready()
		if !ok {
			break
		}
		record_keep(record)
	}
}

// record_keep notes that the thread of a record waits for its answer, and
// keeps the stop as an event, with one line of the log. `awaited_step`:
// the export `step` or `step_line` waits for this record; the end of its
// step is its result, not an event. The trap flag that the service wrote for a
// step leaves the thread at its next stop, of any kind: the thread goes on
// freely at its next answer.
record_keep :: proc "contextless" (record: op.Fault_Record, awaited_step := false) {
	if record.thread >= THREAD_CAPACITY {
		return
	}
	hold := &session.threads[record.thread]
	hold.waits = true
	hold.record = record
	if hold.stepping {
		hold.stepping = false
		if registers, status := system.thread_registers_read(session.program, record.thread); status == .Ok {
			registers.rflags &~= FLAG_TRAP
			system.thread_registers_write(session.program, record.thread, registers)
		}
	}
	if awaited_step && record.kind == .Debug && record.error_code & op.DEBUG_STATUS_BREAKPOINTS == 0 {
		return
	}
	if session.event_count == EVENT_CAPACITY {
		session.events_lost += 1
		return
	}
	event := &session.events[session.event_count]
	session.event_count += 1
	event^ = {thread = record.thread, instruction = record.instruction}
	writer := system.Writer{buffer = event.kind[:]}
	switch {
	case record.kind == .Breakpoint:
		system.write_part(&writer, "int3")
	case record.error_code & op.DEBUG_STATUS_STEP != 0:
		system.write_part(&writer, "step")
	case record.error_code & op.DEBUG_STATUS_BREAKPOINTS != 0:
		for number in 0 ..< u64(BREAK_CAPACITY) {
			if record.error_code & (u64(1) << number) == 0 {
				continue
			}
			if writer.count > 0 {
				system.write_part(&writer, ", ")
			}
			what: string = session.breaks[number].kind == .Execute ? "breakpoint " : "watch "
			system.write_part(&writer, what)
			system.write_part(&writer, number)
		}
	case:
		system.write_part(&writer, "int1")
	}
	event.kind_count = len(system.written(&writer))
	// One line of the log for each event: a reader of the log, and a
	// caller that waits with no call, see it.
	system.log("debugger: the thread ", record.thread, " of ", system.Module_Name{session_name()}, " stopped: ", string(event.kind[:event.kind_count]))
}

// thread_stopped says if the registers of a thread can be read: the
// service holds it, or it waits for an answer.
thread_stopped :: proc "contextless" (number: u64) -> bool {
	return number < THREAD_CAPACITY && (session.threads[number].held || session.threads[number].waits)
}

// thread_of_argument checks the number of a thread that a caller gave: a
// live thread of the program. With `stopped`, also a thread whose
// registers can be read. A failure gives the result of the export.
thread_of_argument :: proc "contextless" (thread: i64, stopped: bool, error: ^errors.Error_Record) -> (number: u64, failure: i64) {
	if thread < 0 || thread >= THREAD_CAPACITY || thread_report(u64(thread)) == nil {
		return 0, errors.fail(error, ERROR_THREAD, .Absent, .Threads, 1)
	}
	if stopped && !thread_stopped(u64(thread)) {
		return 0, errors.fail(error, ERROR_THREAD, .Absent, .Held_Threads, 1)
	}
	return u64(thread), 0
}

// thread_release lets a thread run: the answer of its record, and the end
// of the stop of the debugger. It gives the first status that is not Ok.
thread_release :: proc "contextless" (number: u64) -> (status: system.Status) {
	hold := &session.threads[number]
	status = .Ok
	if hold.waits {
		status = system.debug_fault_answer(session.program, hold.record)
		hold.waits = false
	}
	if hold.held {
		_, resumed := system.thread_control_resume(session.program, number)
		hold.held = false
		if status == .Ok {
			status = resumed
		}
	}
	return status
}

// breaks_apply writes the breakpoints of the debugger in each thread of
// the program: the debug registers belong to a thread, and a thread that
// the program made later has none until this write. A thread that runs is
// held for the write, then released.
breaks_apply :: proc "contextless" () -> (status: system.Status) {
	written: op.Thread_Breakpoints
	for item, number in session.breaks {
		if item.kind != .None {
			written.breakpoints[number] = {address = item.address, kind = item.kind, length = item.length}
		}
	}
	status = .Ok
	for &item in report_threads.threads[:min(report_threads.count, op.THREAD_REPORT_CAPACITY)] {
		number := u64(item.number)
		if number >= THREAD_CAPACITY {
			continue
		}
		stopped := thread_stopped(number)
		if !stopped {
			if _, held := system.thread_control_stop(session.program, number); held != .Ok {
				status = held
				continue
			}
		}
		if wrote := system.thread_breakpoints_write(session.program, number, written); wrote != .Ok {
			status = wrote
		}
		if !stopped {
			system.thread_control_resume(session.program, number)
		}
	}
	return status
}

// A place of the program: the module that holds an address, and what the
// debug object of that module says of it.
Address_Place :: struct {
	has_module: bool, // A module record holds the address.
	module:     string, // The name of the module in the boot image, or "".
	base:       u64, // Where the module is mapped.
	offset:     u64, // The address less the base.
	object:     []u8, // The debug object of the module, or nil.
	place:      debug_object.Place, // The procedure and the line. Empty with no debug object.
}

// module_of_address gives the module record that holds an address.
module_of_address :: proc "contextless" (address: u64) -> ^op.Module_Record {
	for &record in report_modules.modules[:min(report_modules.count, op.PROGRAM_MODULE_CAPACITY)] {
		if record.size != 0 && address >= record.base && address - record.base < record.size {
			return &record
		}
	}
	return nil
}

module_name :: proc "contextless" (hash: [32]u8) -> string {
	if entry := system.image_entry_of(image, hash); entry != nil {
		return system.name_of(entry.name[:])
	}
	return ""
}

// place_of_address names an address of the program. `looked` is the
// address whose procedure and line are taken: the byte before a return
// address.
place_of_address :: proc "contextless" (looked: u64) -> (found: Address_Place) {
	record := module_of_address(looked)
	if record == nil {
		return
	}
	found.has_module = true
	found.module = module_name(record.hash)
	found.base = record.base
	found.offset = looked - record.base
	found.object = system.debug_object_of(&debug_names, record.hash)
	if found.object != nil {
		found.place = debug_object.place_of(found.object, found.offset)
	}
	return
}

// place_columns writes the columns of a place in a row: the module, the
// procedure, the offset in the procedure (or in the module when no
// procedure holds the address), the file and the line.
place_columns :: proc "contextless" (found: Address_Place, module, procedure: []u8, offset: ^i64, file: []u8, line: ^i64) {
	system.format(module, found.module)
	if found.place.procedure != "" {
		system.format(procedure, found.place.procedure)
		offset^ = i64(found.place.offset_in_procedure)
	} else {
		offset^ = i64(found.offset)
	}
	system.format(file, found.place.file)
	line^ = i64(found.place.line)
}

// hex_column writes an address in a column: "0x" and 16 digits.
hex_column :: proc "contextless" (column: []u8, address: u64) {
	system.format(column, "0x", system.Hex(address))
}

// The memory of the program, for the package debugging.
program_memory_read :: proc "contextless" (state: rawptr, address: u64, into: []u8) -> bool {
	thread, has_thread := any_thread()
	if !has_thread {
		return false
	}
	done := 0
	for done < len(into) {
		part := into[done:][:min(len(into) - done, op.THREAD_MEMORY_READ_LIMIT)]
		count, status := system.thread_memory_read(session.program, thread, address + u64(done), part)
		if status != .Ok || count != u64(len(part)) {
			return false
		}
		done += len(part)
	}
	return true
}

memory_reader :: proc "contextless" () -> debugging.Memory_Reader {
	return {read = program_memory_read}
}

// global_at gives the global of a debug object that holds an offset of its
// module. The cost is one pass over the global table.
global_at :: proc "contextless" (object: []u8, offset: u64) -> (global: debug_object.Global_Description, found: bool) {
	for index in 0 ..< debug_object.global_count(object) {
		candidate, has := debug_object.global_by_index(object, index)
		if !has || candidate.address > offset {
			break
		}
		type, has_type := debug_object.type_by_index(object, candidate.type)
		if has_type && offset - candidate.address < u64(max(type.size, 1)) {
			return candidate, true
		}
	}
	return {}, false
}

// address_name_write names an address for the text of a pointer: the
// procedure that holds it, or the global, with the offset in it.
address_name_write :: proc "contextless" (state: rawptr, writer: ^system.Writer, address: u64) {
	found := place_of_address(address)
	if found.object == nil {
		if found.has_module && found.module != "" {
			system.write_part(writer, found.module)
			system.write_part(writer, " + 0x")
			system.write_hex(writer, found.offset, 8)
		}
		return
	}
	name := found.place.procedure
	inside := found.place.offset_in_procedure
	if name == "" {
		global, has := global_at(found.object, found.offset)
		if !has {
			return
		}
		name, inside = global.name, found.offset - global.address
	}
	system.write_part(writer, name)
	if inside != 0 {
		system.write_part(writer, " + ")
		system.write_part(writer, inside)
	}
}

value_context :: proc "contextless" (object: []u8) -> debugging.Value_Context {
	return {object = object, reader = memory_reader(), namer = {write = address_name_write}}
}

// The frames of the stack of one held thread, with its registers.
Stack :: struct {
	registers: op.Thread_Registers,
	frames:    [debugging.FRAME_CAPACITY]debugging.Frame,
	count:     int,
	entry:     debugging.Entry_Place, // Where the instruction of the frame 0 is in its procedure.
}

thread_stack: Stack

// stack_read reads the registers of a held thread and walks its frames.
stack_read :: proc "contextless" (thread: u64) -> (walked: ^Stack, status: system.Status) {
	walked = &thread_stack
	walked^ = {}
	walked.registers, status = system.thread_registers_read(session.program, thread)
	if status != .Ok {
		return nil, status
	}
	// Before the two first instructions of a procedure, the frame pointer
	// is still the one of the caller.
	found := place_of_address(walked.registers.rip)
	if found.place.procedure != "" {
		switch found.place.offset_in_procedure {
		case 0:
			walked.entry = .At_First_Instruction
		case 1:
			first: [1]u8
			if program_memory_read(nil, walked.registers.rip - 1, first[:]) && first[0] == PUSH_FRAME_POINTER {
				walked.entry = .After_Frame_Pointer_Push
			}
		}
	}
	walked.count = debugging.frames_walk(memory_reader(), walked.registers.rip, walked.registers.rbp, walked.registers.rsp, walked.entry, walked.frames[:])
	return walked, .Ok
}

// frame_registers gives the registers of one frame of a stack, for the
// variable locations.
frame_registers :: proc "contextless" (walked: ^Stack, frame: int) -> (registers: debugging.Frame_Registers) {
	registers.registers = (^[debug_object.REGISTER_COUNT]u64)(&walked.registers)^
	registers.innermost = frame == 0
	registers.frame_pointer = walked.frames[frame].frame_pointer
	return registers
}

// frame_has_its_pointer says if the frame pointer of a frame is the one of
// its procedure: not in the frame 0 before the procedure set it.
frame_has_its_pointer :: proc "contextless" (walked: ^Stack, frame: int) -> bool {
	return frame != 0 || walked.entry == .In_Body
}

// The entry of the debugger service. It takes the machine handle, maps the
// boot image, takes the debug image, and opens its ring to the root
// service and its service ring; with no service ring it writes "debugger:
// no service ring" and stops with the code 1. Then it writes "debugger:
// serves its exports", and waits for calls and runs them for ever, in this
// thread, which is also the debug handler of the program that it debugs.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	machine = ctx.handles[system.GRANT_MACHINE]
	if address, status := system.memory_map(ctx.handles[system.GRANT_IMAGE], {}); status == .Ok {
		image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	}
	debug_names = system.debug_names_of(ctx)
	requests_memory = ctx.handles[system.GRANT_ROOT]
	requests, _ = system.ring_open(requests_memory)
	opened: bool
	service, opened = system.service_open(ctx)
	if !opened {
		system.log("debugger: no service ring")
		system.stop(1)
	}
	system.log("debugger: serves its exports")
	own := system.thread_record()
	for {
		// The stops of the debugged program wake this thread as the calls
		// do: a stop is taken, and written on the log, when it comes.
		wait: system.Wait
		system.service_wait(&wait, &service)
		if requests.head != nil {
			system.wait_records(&wait, &requests.completions)
		}
		written := intrinsics.atomic_load(&own.fault_written)
		if written == intrinsics.atomic_load(&own.fault_read) {
			system.wait_word(&wait, &own.fault_written, written)
			system.wait_end(&wait)
		}
		// The completions that no export waited for, and the ends that
		// the root ring had no room for.
		if requests.head != nil {
			root_completions_take(0)
			root_requests_send_again()
		}
		if session.attached {
			records_take()
		} else {
			// No program is debugged: a record is of a debugging that ended.
			for _ in 0 ..< op.FAULT_RECORD_CAPACITY {
				if _, more := record_next_ready(); !more {
					break
				}
			}
		}
		system.service_run(&service)
	}
}
