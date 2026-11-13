package console

// The commands of the debugger (docs/TOOLS.md, "The debugger"): each one
// is an export of the service `debugger`, under a short name. The console
// holds no state of the debugging and draws nothing here: the command
// connects to the service when the console has no connection to it yet,
// calls the export through the connection (`bound_call`), and the drawers
// of the console draw the table that the export gives.
//
// Four exports have a short name that is not their own, because the
// console has a command with that name already:
//
//   attach    debug         the word of the design: `debug("clock")`
//   release   resume        `release` closes a handle of the console
//   memory    debug_memory  `memory` gives the memory of the machine
//
// and `hold` is the name of the service too: `stop` stops a whole program.

debug_attach :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "attach", arguments)
}

debug_detach :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "detach", arguments)
}

debug_threads :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "threads", arguments)
}

debug_hold :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "hold", arguments)
}

debug_resume :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "release", arguments)
}

debug_continue_all :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "continue_all", arguments)
}

debug_registers :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "registers", arguments)
}

debug_stack :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "stack", arguments)
}

debug_locals :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "locals", arguments)
}

debug_value :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "value", arguments)
}

debug_source :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "source", arguments)
}

debug_break_at :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "break_at", arguments)
}

debug_breaks :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "breaks", arguments)
}

debug_break_remove :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "break_remove", arguments)
}

debug_watch :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "watch", arguments)
}

debug_step :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "step", arguments)
}

debug_step_line :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "step_line", arguments)
}

debug_memory :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "memory", arguments)
}

debug_events :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "events", arguments)
}

debug_wait_stop :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("debugger", "wait_stop", arguments)
}

// debugger_commands_start lists the commands of the debugger. The comment
// above each command is its documentation on the site.
debugger_commands_start :: proc "contextless" () {
	// Makes the service `debugger` the debugger of a program for the
	// console, and gives one row: the program, its slot, its threads, its
	// modules and how many of them have a debug object. It is the export
	// `attach` of the service.
	//
	// - `program`: the name of a program that runs.
	//
	// The root service gives the debug access when the console acts for
	// the principal whose session runs the program, and when each grant of
	// the program is a grant that the console holds itself. A service is
	// refused. The grant is `debug` in `grants("console")`, and
	// `revoke("console", "debug")` ends it.
	//
	// ```
	// > debug("clock")
	// ```
	//
	// Errors: those of `connect("debugger")`, and those of the export.
	command("debug", {.Text}, .Table, "debug a program: debugger.attach()", debug_attach)
	// Ends the debugging: the program gets back each thread that the
	// debugger held, with no breakpoint. It gives one row: the program, the
	// breakpoints that the debugger had and the threads that it held.
	command("detach", {}, .Table, "end the debugging: debugger.detach()", debug_detach)
	// Gives one row for each thread of the debugged program: its number,
	// its state, and the instruction of a thread that is held or stopped,
	// with its procedure, its file and its line.
	command("threads", {}, .Table, "the threads of the debugged program: debugger.threads()", debug_threads)
	// Stops one thread of the debugged program, and gives its row. The
	// command `stop` stops a whole program by its name: this one holds one
	// thread, which runs again with `resume` or `continue_all`.
	//
	// - `thread`: the number of a thread, as `threads()` gives it.
	command("hold", {.Integer}, .Table, "hold one thread of the debugged program: debugger.hold()", debug_hold)
	// Lets one thread run again, and gives its row: a thread that `hold`
	// stopped, or that a breakpoint, a watch or a step stopped. It is the
	// export `release` of the service; `release` in the console closes a
	// handle.
	//
	// - `thread`: the number of a thread that is held or stopped.
	command("resume", {.Integer}, .Table, "let one thread of the debugged program run: debugger.release()", debug_resume)
	// Lets each thread of the debugged program run again, and gives one row
	// for each thread.
	command("continue_all", {}, .Table, "let each thread of the debugged program run: debugger.continue_all()", debug_continue_all)
	// Gives one row for each register of a held thread: the 16 general
	// registers, `rip` with its procedure and its line, and `rflags` with
	// the flags that are set.
	//
	// - `thread`: the number of a thread that is held or stopped.
	command("registers", {.Integer}, .Table, "the registers of a held thread: debugger.registers()", debug_registers)
	// Gives one row for each frame of the stack of a held thread: the
	// procedure, the file and the line of the instruction, then of each
	// call, with the frame pointer and the return address.
	//
	// - `thread`: the number of a thread that is held or stopped.
	command("stack", {.Integer}, .Table, "the frames of the stack of a held thread: debugger.stack()", debug_stack)
	// Gives one row for each parameter and each local variable that is
	// visible at the instruction of a frame: its name, its role, its type,
	// its value or "not readable", and its location.
	//
	// - `thread`: the number of a thread that is held or stopped.
	// - `frame`: the number of a frame, as `stack` gives it.
	command("locals", {.Integer, .Integer}, .Table, "the variables of a frame: debugger.locals()", debug_locals)
	// Gives one variable or one global by a path, as one row for each of
	// its fields or of its elements.
	//
	// - `thread`, `frame`: as for `locals`. A global with its package
	//   (`debug_target::rounds`) needs no held thread.
	// - `path`: a name, then steps: `.field`, `[number]`, `^`.
	//
	// ```
	// > value(0, 0, "pair.next^.first")
	// ```
	command("value", {.Integer, .Integer, .Text}, .Table, "a variable or a global, by a path: debugger.value()", debug_value)
	// Gives the source line of the instruction of a frame: its number, the
	// path of its file and the hash of that file at the build. The system
	// holds no source text; `kerneltool call` shows the line on the host
	// when the file of the repository has that hash.
	//
	// - `thread`, `frame`: as for `locals`.
	command("source", {.Integer, .Integer}, .Table, "the source line of a frame: debugger.source()", debug_source)
	// Sets an execute breakpoint, and gives one row for each breakpoint of
	// the debugger.
	//
	// - `place`: the full name of a procedure (`fault::three`), or a file
	//   and a line (`programs/fault/main.odin:15`).
	//
	// The debugger has four breakpoints, for breakpoints and watches
	// together.
	command("break_at", {.Text}, .Table, "a breakpoint at a procedure or at a line: debugger.break_at()", debug_break_at)
	// Gives one row for each breakpoint of the debugger.
	command("breaks", {}, .Table, "the breakpoints of the debugger: debugger.breaks()", debug_breaks)
	// Removes one breakpoint, and gives one row for each one that stays.
	//
	// - `number`: the number of a breakpoint, as `breaks()` gives it.
	command("break_remove", {.Integer}, .Table, "remove a breakpoint: debugger.break_remove()", debug_break_remove)
	// Sets a data breakpoint on bytes that the program writes, and gives
	// one row for each breakpoint of the debugger.
	//
	// - `place`: an address (`0x403010`), or the path of a global with its
	//   package.
	// - `length`: 1, 2, 4 or 8 bytes.
	command("watch", {.Text, .Integer}, .Table, "stop at a write of some bytes: debugger.watch()", debug_watch)
	// Runs one instruction of a thread that is held or stopped, and gives
	// its row at its new instruction.
	//
	// - `thread`: the number of a thread that is held or stopped.
	command("step", {.Integer}, .Table, "one instruction of a held thread: debugger.step()", debug_step)
	// Runs a thread that is held or stopped until the source line of its
	// instruction changes, and gives its row there.
	//
	// - `thread`: the number of a thread that is held or stopped.
	command("step_line", {.Integer}, .Table, "a held thread, to its next source line: debugger.step_line()", debug_step_line)
	// Gives the bytes of the debugged program from an address, sixteen in
	// each row. It is the export `memory` of the service; `memory` in the
	// console gives the memory of the machine.
	//
	// - `place`: an address (`0x403010`), or the path of a global with its
	//   package.
	// - `count`: 1 to 4096 bytes.
	command("debug_memory", {.Text, .Integer}, .Table, "the bytes of the debugged program: debugger.memory()", debug_memory)
	// Gives one row for each stop of a thread since the last call: the
	// thread, the kind (`breakpoint N`, `watch N`, `step`), and the
	// instruction with its procedure and its line.
	command("events", {}, .Table, "the stops of the debugged program: debugger.events()", debug_events)
	// Waits until a thread of the debugged program stops, at most the
	// given milliseconds (3000 at most), and gives the rows of
	// `events`.
	//
	// - `milliseconds`: the longest wait.
	command("wait_stop", {.Integer}, .Table, "wait for a stop of the debugged program: debugger.wait_stop()", debug_wait_stop)
}
