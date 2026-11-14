package console

import "modus:contract/blake3"
import "modus:contract/errors"
import info "modus:contract/boot_info"
import "modus:contract/isolated"
import op "modus:contract/operation"
import module "modus:contract/module"
import "modus:contract/ring"
import "modus:support/random"
import "modus:support/system"
import "base:intrinsics"

// A command: a function with typed parameters and a typed result.
//
// The console is a program that reads one line at a time and runs it as an
// expression of a small language: `name = expression`, or an expression
// alone. A call is `name(argument, ...)`. Each argument is a number, a text
// in quotes, a variable, or the result of another call. The console checks
// the kind of each argument against the parameter before the call. A
// command gives a result and never prints: the console draws the result of
// the line by its kind. No program parses text: the text of the line stops
// at the console.
//
// A command comes from one of three places:
//
// - **The console itself**: the built-in commands that this page lists.
//   They exist before any module is loaded.
// - **A module of the boot image** that `load("sample")` or
//   `isolate("sample")` adds: each export of the module becomes a command
//   with the name of the export, and each record of its description becomes
//   a command that makes a record from its fields.
// - **A service that runs**, which `connect("monitor")` reaches: each export
//   becomes a command named `service.export`, as `monitor.programs()`.
//
// The name, the kinds and the help of a command of a module come from the
// description of its export: the console types nothing for it. When two
// commands have one name, the command added last is the one that runs: the
// module `probe` exports `count`, so the console names its own count of rows
// `rows`.
//
// **The kinds of a value.** A result is an `Integer`, a `Text`, a `Record`,
// a `Handle`, a `Table` or `Bytes`. A command whose result is `None` does
// something and gives nothing. A command that lists things gives a `Table`,
// so `where`, `sort` and `columns` take it as they take the table of an
// export: `where(grants("notes"), "state", "held")`. A parameter of the
// kind `Value` takes any kind, and the command checks it.
//
// **Tables compose.** A `Table` is the records of one description, one
// after the other. The console holds a table as one value and passes it to
// the next call with no parsing: `where`, `sort`, `join`, `columns`,
// `first`, `rows` and `row` read only the description of the records, so
// they work on each table of each service. Example:
//
// ```
// > columns(where(manual.running(), "module", "calendar_fixed"), "program slot module replaces")
// ```
//
// **A variable keeps a value** for the lines after it: `t = readings(4)`,
// then `sum_values(where(t, "sensor", 2))`. The console keeps 16 variables.
// `variables()` lists them.
//
// **Errors.** A command that fails gives no value, and the line has an
// error: the rest of the line does not run. The console draws the error as
// one line that starts with `error: `, then the values of its error record
// when a call gave one. A wrong argument is refused before the call, with
// the argument and the two kinds:
// "error: sum_values: argument 1 is Table(Reading, Read), not
// Table(Reading)".
//
// The keys of the line, the completion list and the line history: (docs/CONSOLE.md, "1. The keys").
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
	// table of error details. The console gives the table; the input does
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
	quiet:         bool, // A service that the console connected to for itself, to read the log records of a line: its exports are no commands yet.
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

SANDBOX_CAPACITY :: 12
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

COMMAND_CAPACITY :: 256
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
debug_names: system.Debug_Names // The debug image and the verdicts of its objects: the names of a stop report. Used by the thread that runs the lines only.
requests: ring.Ring
requests_memory: system.Handle
request_count: u32 // The tag of the last command to the root service.

// The names of the commands of services: "program.export".
names: [8192]u8
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
	debug_names = system.debug_names_of(ctx)
	requests_memory = ctx.handles[system.GRANT_ROOT]
	requests, _ = system.ring_open(requests_memory)
	if address, status := system.memory_map(ctx.handles[system.GRANT_REPLACEMENTS], {}); status == .Ok {
		replacement_table = (^system.Replacement_Table)(address)
	}
	space.next = op.MODULE_BASE

	// The comment above each command is its documentation on the site: the
	// help after the name is the text that help() gives in its row.

	// Gives one row for each command that the console can call now: its
	// name, its signature, and its help.
	//
	// The table grows with each `load`, `isolate` and `connect`, and
	// shrinks with each `unload`: it is the command table of this moment,
	// not a fixed list. In a signature, a parameter shows its name when the
	// description of the export gives one, and `Value` when it takes any
	// kind; the result follows `->`, and a command with no `->` gives
	// nothing. A help longer than its field ends with the cut mark:
	// `describe(name)` gives it whole.
	//
	// ```
	// > where(help(), "name", "repeat")
	// name    signature                      about
	// repeat  repeat(Text, Integer) -> Text  a text, several times
	// 1 row of Command
	// ```
	command("help", {}, .Table, "the commands, one row each", help)
	// Gives the signature and the whole help of one command, as a `Text`.
	//
	// - `name`: the name of a command, as `help()` gives it.
	//
	// Error: "no command has the name ...".
	command("describe", {.Text}, .Text, "the signature and the help of one command", describe)
	// Gives one row for each program that runs: the export `programs` of
	// the service `monitor`, under a short name.
	//
	// The list of the programs is a fact of a service, not of the console:
	// the command connects to `monitor` when the console has no connection
	// to it yet, and calls `monitor.programs()`. The rows are those of that
	// export: the slot, the name, the state, the pages, the handles, the
	// threads, the processor time and the kernel entries of each program.
	//
	// ```
	// > columns(where(programs(), "state", "waiting"), "slot name threads")
	// ```
	//
	// Errors: those of `connect("monitor")` when the service does not run,
	// and those of the export.
	command("programs", {}, .Table, "the programs that run: monitor.programs()", programs_of_monitor)
	// Gives one row for each module of each program that runs: the slot and
	// the name of the program, the module, the module that it replaces, and
	// the head of its hash.
	//
	// The rows are the module records of the kernel: what the loader of
	// each program recorded. `replaces` is empty when the module is in no
	// place but its own.
	//
	// It needs the grant **machine**: the console asks the kernel with
	// `Inspect` on the machine handle. Without it: "error: the console has
	// no grant to inspect the machine".
	command("program_modules", {}, .Table, "the modules of each program that runs", program_modules)
	// Gives the memory of the machine and the counters of the kernel, as
	// one `Record`.
	//
	// The fields: the memory and the free memory in MiB, the used pages,
	// the pages that a budget paid for and that have no page frame yet, the
	// pages of the budgets, the free pages that no budget holds (0 when
	// each page is free or paid), the count of memory objects, of kernel
	// entries, of interrupts and of processors.
	//
	// It needs the grant **machine**, as `program_modules()`.
	command("memory", {}, .Record, "memory and kernel counters", show_memory)
	// Gives one row for each kind of lock of the kernel: its name, the
	// count of its waits and the count of its takes.
	//
	// It needs the grant **machine**, as `memory()`.
	command("locks", {}, .Table, "the waits and the takes of each kind of kernel lock", list_locks)
	// Gives one row for each module of the boot image: its name, its bytes
	// and the head of its BLAKE3 hash, the first 8 bytes.
	//
	// These are the names that `load`, `isolate`, `start` and `replace`
	// take. The boot image is the one source of code of the console: it is
	// what the root service granted, with the grant **image**.
	command("modules", {}, .Table, "the modules of the boot image", list_modules)
	// Loads a module of the boot image into the memory of the console, and
	// makes each of its exports a command: a call is a direct call, with no
	// other program.
	//
	// - `name`: the name of a module of the boot image, as `modules()`
	//   gives it.
	//
	// The loader checks the hash of the file against the boot image, loads
	// its imports, and applies the replacement table of this time. The
	// result is a `Record`: the module, the count of its commands, how a
	// call runs (`direct`), and the head of its hash. `loaded()` then lists
	// its imports, with the module that the loader gave in the place of
	// each one. The module runs with the memory and every handle of the
	// console: load only a module that the console trusts, and `isolate`
	// the others.
	//
	// ```
	// > load("sample")
	// Loaded
	//   module     sample
	//   commands   11
	//   call       direct
	//   hash_head  <the first 8 bytes of its hash>
	// ```
	//
	// Errors: no module has the name; the module is loaded already; it
	// exports no command (`start` runs a program); no room for its commands
	// (256 commands, 8 modules); the hash differs from the boot image; the
	// loader refuses the file, with the stage and the reason.
	command("load", {.Text}, .Record, "load a module here: direct calls", load_module)
	// Loads a module of the boot image into a new sandboxed program, a call
	// host, and makes each of its exports a command: a call is an isolated
	// call through a call ring.
	//
	// - `name`: the name of a module of the boot image.
	//
	// The call host receives its call ring, its call region, the log, and
	// the files of the module and of its imports, read-only: no other
	// handle. A fault of the module stops the call host, not the console:
	// the error of the line has the stop report, with the instruction and
	// the frames. Escape during a call stops the call host. The arguments
	// and the results go through the call region, so a table result is
	// limited by its size. The result is the `Record` of `load`, with the
	// call `isolated`.
	//
	// Errors: as `load`; also "no room for a sandboxed program" when 8
	// sandboxes run, and "cannot start a sandboxed program" when the budget
	// of the console cannot pay for it.
	command("isolate", {.Text}, .Record, "load a module in a sandboxed program", isolate_module)
	// Removes a module that `load` or `isolate` added: its commands leave
	// the command table.
	//
	// - `name`: the name of the module, as `load` or `isolate` took it.
	//
	// After `isolate`, the call host stops: the console closes its handles,
	// and the kernel stops a program that no handle names. After `load`, the
	// module leaves the memory of the console, unless another loaded module
	// imports it: one copy serves both. The result is a `Record`: the
	// module, the count of the commands removed, and what became of its
	// memory.
	//
	// ```
	// > unload("sample")
	// Unloaded
	//   module    sample
	//   commands  11
	//   memory    left the console
	// ```
	//
	// Error: "load and isolate added no module with the name ...".
	command("unload", {.Text}, .Record, "remove a module that load or isolate added", unload_module)
	// Gives one row for each module and each service whose exports are
	// commands of the console, and one row for each import of such a
	// module.
	//
	// The fields: the module; how a call runs (`direct`, `isolated`,
	// `service`); for an import, the module that imports it and, when the
	// loader gave another module in its place, the module that the import
	// names; the head of its hash.
	//
	// ```
	// > where(loaded(), "in_place_of", "calendar")
	// ```
	command("loaded", {}, .Table, "the modules and the services whose exports are commands", list_loaded)
	// Asks the root service for a connection to a service that runs, and
	// makes each export of the service a command named `service.export`.
	//
	// - `name`: the name of the service, as `programs()` gives it.
	//
	// The root service decides: it refuses a service that the console may
	// not call, with its reason. It gives a call ring, a call region and the
	// hash of the file of the program; the console reads the descriptions of
	// the exports from that file in the boot image. A call then runs in the
	// service, with the rights of the service, and the service checks its
	// caller. When the service stops, the console ends the connection. The
	// result is the `Record` of `load`, with the call `service`; a service
	// that is connected already gives it again.
	//
	// ```
	// > connect("settings")
	// Loaded
	//   module     settings
	//   commands   3
	//   call       service
	//   hash_head  <the first 8 bytes of its hash>
	// ```
	//
	// Errors: the root service refused, with its error record; the service
	// exports no command; no room for its commands.
	command("connect", {.Text}, .Record, "call the exports of a service that runs", connect_service)
	// Asks the root service to start a program from a module of the boot
	// image. It gives nothing.
	//
	// - `name`: the name of the module, which becomes the name of the
	//   program.
	//
	// The root service gives the program the grants of its name, and only
	// those (the reference page of the grants lists them). `programs()`
	// then has its row.
	//
	// Errors: the error record of the root service when it refuses (no
	// module has the name, the program runs already, no slot is free), and
	// "the root service did not answer" after 3 seconds.
	command("start", {.Text}, .None, "start a program, by module name", start_program)
	// Asks the root service to stop a program that runs. It gives nothing.
	//
	// - `name`: the name of the program, as `programs()` gives it.
	//
	// `stop("console")` stops this console: it saves its line history
	// first, because the save after the line never comes.
	//
	// Errors: the error record of the root service when it refuses, and
	// "the root service did not answer".
	command("stop", {.Text}, .None, "stop a program, by name", stop_program)
	// Gives one row for each grant that a program has or lost, of the
	// grants that the root service records and can revoke.
	//
	// - `name`: the name of a program that runs.
	//
	// The fields: the program; the grant (log, machine, image, log_records,
	// store, network, acts_for_principal, history); its state, `held` or
	// `lost`; the number and the name of the principal that the program
	// runs for.
	//
	// ```
	// > grants("notes")
	// program  grant  state  principal  principal_name
	// notes    log    held           0  machine
	// notes    store  held           0  machine
	// 2 rows of Grant
	// ```
	//
	// Error: the error record of the root service when no program has the
	// name.
	command("grants", {.Text}, .Table, "what a program has from the root service", grants)
	// Asks the root service to end one grant of a program that runs, and
	// gives the count of the holdings that ended.
	//
	// - `name`: the name of the program.
	// - `grant`: the name of the grant, as `grants()` gives it.
	//
	// The root service closes each handle that came from the grant and
	// records the loss: `grants()` then gives it with the state `lost`. The
	// program continues, and an operation on a closed handle fails with an
	// error record that says "was revoked".
	//
	// Errors: "no grant has the name ...", with the list of the names; the
	// error record of the root service when it refuses.
	command("revoke", {.Text, .Text}, .Integer, "end a grant of a program that runs", revoke)
	// Asks the root service to create a named principal: a principal whose
	// session opens with a passphrase. It gives nothing.
	//
	// - `name`: the name of the principal.
	//
	// The passphrase is never a text of the console, because the console
	// keeps each line in its history: the window of unlock opens and asks
	// for it. `principals()` then has the row of the principal.
	command("principal_create", {.Text}, .None, "create a named principal: its passphrase is typed in the window of unlock", principal_create)
	// Asks the root service to lock the session of the named principal that
	// is unlocked, and gives the count of the programs of the session that
	// stopped.
	//
	// The window of unlock then asks for the passphrase again.
	command("lock", {}, .Integer, "end the session of the named principal: its programs stop", lock_session)
	// Gives one row for each principal of the machine: its number, its
	// name, its state, the head of its public key, and for principal 0 the
	// head of the measure of the system.
	//
	// Principal 0 is the machine: it has no unlock, and its state is
	// `machine`. The other states: `locked`, `unlocked` (its session runs),
	// and `creating` (created in the window of unlock). An empty measure:
	// the system was not measured.
	//
	// ```
	// > principals()
	// number  name     state    public_key_head  measure_head
	//      0  machine  machine
	// 1 row of Principal
	// ```
	command("principals", {}, .Table, "the principals of the machine", list_principals)
	// Asks the root service to give one module where a module imports
	// another, in each load that follows. It gives nothing.
	//
	// - `name`: the module that an import names.
	// - `by`: the module to give in its place; the text `""` removes the
	//   replacement of `name`.
	//
	// The replacement table belongs to the machine: the root service writes
	// it, and each loader reads it at each load. A program that runs keeps
	// the modules that it loaded. `replacements()` gives the table.
	//
	// Errors: no module has the name; the console has no grant to change
	// the table; a chain of replacements is refused; the table is full; a
	// module does not replace itself.
	command("replace", {.Text, .Text}, .None, "give the second module where a module imports the first", replace)
	// Gives the replacement table of the machine: one row for each module
	// that a load replaces, with the module that it gets in its place and
	// the heads of the two hashes. No replacement: no row.
	command("replacements", {}, .Table, "the replacement table of the machine", list_replacements)
	// Gives the milliseconds since the machine started, as an `Integer`.
	command("time", {}, .Integer, "milliseconds since boot", time)
	// Gives the BLAKE3 hash of the bytes of a text, as 64 hexadecimal
	// digits.
	//
	// The same hash names a module in the boot image and an object in a
	// store: `hash("")` gives `af1349b9...`.
	command("hash", {.Text}, .Text, "the BLAKE3 hash of a text", hash)
	// Gives the count of bytes of a text, as an `Integer`.
	//
	// `length("kept across a stop")` gives 18.
	command("length", {.Text}, .Integer, "the number of bytes of a text", length)
	// Gives the decimal text of an integer: `text(42) + " pages"` gives
	// `42 pages`.
	command("text", {.Integer}, .Text, "the decimal text of an integer", text)
	// Gives a text repeated a count of times: `repeat("ab", 3)` gives
	// `ababab`.
	//
	// The texts of one line share 4096 bytes: past them, "error: the text
	// is too long".
	command("repeat", {.Text, .Integer}, .Text, "a text, several times", repeat)
	// Makes a new memory object of a count of pages, paid by the budget of
	// the console, and gives its handle.
	//
	// The console holds the handle until `release`. The console draws a
	// handle with its kind and its rights: "Handle 65541: Memory (Give,
	// Read, Write)". `byte` and `bytes` read it.
	//
	// Error: "the budget of the console cannot pay for N pages".
	command("buffer", {.Integer}, .Handle, "a new memory object, in pages", buffer_create)
	// Gives one byte of a memory object, from 0: the console maps the object
	// for the time of the command.
	//
	// A new object holds zero bytes: `byte(buffer(1), 0)` gives 0. Errors: the
	// handle names no memory object, or the object has no byte at that
	// place.
	command("byte", {.Handle, .Integer}, .Integer, "one byte of a memory object", buffer_byte)
	// Gives a count of bytes of a memory object, from a first byte, as
	// `Bytes`: the console maps the object for the time of the command and
	// copies them.
	//
	// - `memory`: a handle of a memory object.
	// - `first`: the place of the first byte, from 0.
	// - `count`: the count of bytes, at most 4096.
	//
	// The console draws `Bytes` as rows of 16 bytes in hexadecimal, with
	// the place of each row and the characters; it draws the first 256
	// bytes and says how many it does not show.
	//
	// Errors: the handle names no memory object; the object does not have
	// these bytes; the count is not 0 to 4096.
	command("bytes", {.Handle, .Integer, .Integer}, .Bytes, "bytes of a memory object", buffer_bytes)
	// Closes a memory object that `buffer` made: the console gives its
	// handle back, and the kernel frees the pages when no handle names the
	// object. It gives nothing.
	//
	// Error: "release closes a memory object that buffer made", for each
	// other handle.
	command("release", {.Handle}, .None, "close a handle", release)
	// Gives one row for each variable: its name, its type and its value as
	// a text.
	//
	// A line `name = expression` makes or changes a variable. The console
	// keeps 16 variables; a table keeps at most 32 KiB of rows. The value
	// of a table is the count of its rows; the value of a record is its
	// fields in one line.
	command("variables", {}, .Table, "the variables", list_variables)
	// Clears the text of the terminal: the edit line becomes the first row
	// of the view. The line history stays. It gives nothing.
	command("clear", {}, .None, "clear the console", clear)
	// Stops the machine: the console saves its line history, then asks the
	// kernel to stop the machine. It gives nothing.
	//
	// It needs the grant **machine**. Without it: "error: the console has
	// no grant to stop the machine".
	command("shutdown", {}, .None, "stop the machine", shutdown)
	// Forgets the line history, in the memory of the console and in its
	// store, and gives the count of the lines that it forgot.
	//
	// Its object leaves the store with each of its versions. The line
	// `history_clear()` goes too.
	//
	// If the store refuses the removal, the history is still cleared in
	// memory, and the error gives the reason of the store. The design of the
	// history: (docs/CONSOLE.md, "6. The line history across a stop").
	command("history_clear", {}, .Integer, "forget the line history, in memory and in its store", history_clear)
	// Measures the work of one key with the completion list open, for the
	// query `mcnt`, and gives the measure as two rows.
	//
	// It times four parts: the collect of the names, their rank, the text
	// of the rows, and the colors of the code. Each number is the least of
	// 20 batches of 10 keys, in nanoseconds. The first row is for the names
	// of this console; the second for the worst case, 512 names of 128
	// bytes. It also writes each row as a line of the log, in microseconds.
	// It runs in the second thread, so the list on the screen stays. The
	// bounds that it measures: (docs/CONSOLE.md, "4. The bounds, and the cost of one key").
	command("measure_completion", {}, .Table, "measure one key of the completion list", measure_completion)
	debugger_commands_start()
	tables_start()
}

help :: proc "contextless" (arguments: []Value) -> Value {
	columns := [3]Column{text_column("name", 48), text_column("signature", 104), text_column("about", 104)}
	table, made := made_table("Command", columns[:])
	if !made {
		return fail("help: the line has no room for the description")
	}
	for &item in commands[:command_count] {
		row := made_row(&table)
		buffer: [240]u8
		writer := system.Writer {
			buffer = buffer[:],
		}
		_, _ = signature_write(&writer, &item, -1, true)
		made_text(&table, row, 0, item.name)
		made_text(&table, row, 1, system.written(&writer))
		made_text(&table, row, 2, item.about)
	}
	return made_value(&table, "help")
}

// describe gives the signature and the whole help of one command. When two
// commands have the name, it is the one that a call runs: the last one.
describe :: proc "contextless" (arguments: []Value) -> Value {
	found: ^Command
	for &item in commands[:command_count] {
		if item.name == arguments[0].text {
			found = &item
		}
	}
	if found == nil {
		return fail("no command has the name ", arguments[0].text, "; help() gives the commands")
	}
	writer := system.Writer {
		buffer = scratch[scratch_count:],
	}
	_, _ = signature_write(&writer, found, -1, true)
	system.write_part(&writer, "\n")
	system.write_part(&writer, found.about)
	described := system.written(&writer)
	scratch_count += len(described)
	return {kind = .Text, text = described}
}

// command_of_service gives the command of an export of a service that the
// console is connected to, or nil.
command_of_service :: proc "contextless" (service: string, export: string) -> ^Command {
	for &item in commands[:command_count] {
		if item.sandbox == 0 || item.record != 0 || len(item.name) != len(service) + 1 + len(export) {
			continue
		}
		sandbox := &sandboxes[item.sandbox - 1]
		if sandbox.service && sandbox.name == service && item.name[:len(service)] == service && item.name[len(service) + 1:] == export {
			return &item
		}
	}
	return nil
}

// bound_call calls an export of a service under a short name of the
// console: the fact is a fact of the service, and the console calls its
// export as it calls any export. It connects to the service first when the
// console has no connection to it.
bound_call :: proc "contextless" (service: string, export: string, arguments: []Value) -> Value {
	found := command_of_service(service, export)
	if found == nil {
		connect_arguments := [1]Value{{kind = .Text, text = service}}
		connect_service(connect_arguments[:])
		if failed {
			return {}
		}
		found = command_of_service(service, export)
	}
	if found == nil {
		return fail("the service ", service, " has no export ", export, " that the console can call")
	}
	return call_isolated(found, arguments)
}

programs_of_monitor :: proc "contextless" (arguments: []Value) -> Value {
	return bound_call("monitor", "programs", arguments)
}

system_report :: proc "contextless" () -> (report: op.System_Report, ok: bool) {
	_, status := system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.System), 0, u64(uintptr(&report)), size_of(report))
	if status != .Ok {
		fail("the console has no grant to inspect the machine")
	}
	return report, status == .Ok
}

module_report: op.Module_Report

// program_modules gives the identity of each program: each module that a
// loader put in it, and the module that it replaces (the module records of
// the kernel).
program_modules :: proc "contextless" (arguments: []Value) -> Value {
	report, ok := system_report()
	if !ok {
		return {}
	}
	columns := [5]Column{integer_column("slot"), text_column("program", 32), text_column("module", 32), text_column("replaces", 32), text_column("hash_head", 16)}
	table, made := made_table("Program_Module", columns[:])
	if !made {
		return fail("program_modules: the line has no room for the description")
	}
	for slot in 1 ..< report.program_slots {
		program: op.Program_Report
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Program), slot, u64(uintptr(&program)), size_of(program))
		if program.state == .None {
			continue
		}
		modules := &module_report
		modules^ = {}
		system.call(.Inspect, u64(machine), u64(op.Inspect_Kind.Modules), slot, u64(uintptr(modules)), size_of(modules^))
		for item in modules.modules[:min(int(modules.count), len(modules.modules))] {
			row := made_row(&table)
			head: [16]u8
			made_integer(&table, row, 0, i64(slot))
			made_text(&table, row, 1, system.name_of(program.name[:]))
			made_text(&table, row, 2, module_name_of(item.hash))
			if item.replaces != {} {
				made_text(&table, row, 3, module_name_of(item.replaces))
			}
			made_text(&table, row, 4, hash_head_text(&head, item.hash))
		}
	}
	return made_value(&table, "program_modules")
}

show_memory :: proc "contextless" (arguments: []Value) -> Value {
	report, ok := system_report()
	if !ok {
		return {}
	}
	columns := [10]Column {
		integer_column("memory_mebibytes"),
		integer_column("free_mebibytes"),
		integer_column("used_pages"),
		integer_column("reserved_pages"),
		integer_column("budget_pages"),
		// Each page is free or paid: the budgets and the reserved pages
		// hold all the free pages, and this count is 0.
		integer_column("free_pages_no_budget_holds"),
		integer_column("memory_objects"),
		integer_column("kernel_entries"),
		integer_column("interrupts"),
		integer_column("processors"),
	}
	table, made := made_table("Memory", columns[:])
	if !made {
		return fail("memory: the line has no room for the description")
	}
	values := [10]i64 {
		i64(report.page_count * system.PAGE_SIZE >> 20),
		i64(report.free_pages * system.PAGE_SIZE >> 20),
		i64(report.page_count - report.free_pages),
		i64(report.reserved_pages),
		i64(report.budget_pages),
		i64(report.free_pages) - i64(report.reserved_pages) - i64(report.budget_pages),
		i64(report.region_count),
		i64(report.entries),
		i64(report.interrupts),
		i64(report.processors),
	}
	row := made_row(&table)
	for value, index in values {
		made_integer(&table, row, index, value)
	}
	return made_record(&table, "memory")
}

list_locks :: proc "contextless" (arguments: []Value) -> Value {
	report, ok := system_report()
	if !ok {
		return {}
	}
	columns := [3]Column{text_column("lock", 16), integer_column("waits"), integer_column("takes")}
	table, made := made_table("Lock", columns[:])
	if !made {
		return fail("locks: the line has no room for the description")
	}
	for kind in op.Lock_Kind {
		row := made_row(&table)
		made_text(&table, row, 0, op.LOCK_KIND_NAMES[kind])
		made_integer(&table, row, 1, i64(report.locks[kind].waits))
		made_integer(&table, row, 2, i64(report.locks[kind].takes))
	}
	return made_value(&table, "locks")
}

hex_text :: proc "contextless" (bytes: []u8) -> string {
	start := scratch_count
	alphabet := system.HEX_DIGITS
	for b in bytes {
		scratch_text(string([]u8{alphabet[b >> 4], alphabet[b & 0xF]}))
	}
	return string(scratch[start:scratch_count])
}

// module_text gives the name of a module in the boot image, and the start
// of its hash, for a sentence.
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

list_modules :: proc "contextless" (arguments: []Value) -> Value {
	columns := [3]Column{text_column("name", 32), integer_column("bytes"), text_column("hash_head", 16)}
	table, made := made_table("Module", columns[:])
	if !made {
		return fail("modules: the line has no room for the description")
	}
	for &entry in system.image_entries(image) {
		row := made_row(&table)
		head: [16]u8
		made_text(&table, row, 0, system.name_of(entry.name[:]))
		made_integer(&table, row, 1, i64(entry.size))
		made_text(&table, row, 2, hash_head_text(&head, entry.hash))
	}
	return made_value(&table, "modules")
}

// loaded_record gives the result of load, isolate and connect: the module,
// the count of its commands, how a call runs, and the head of its hash.
loaded_record :: proc "contextless" (name: string, callable: int, how: string, hash: [32]u8) -> Value {
	columns := [4]Column{text_column("module", 32), integer_column("commands"), text_column("call", 8), text_column("hash_head", 16)}
	table, made := made_table("Loaded", columns[:])
	if !made {
		return fail(name, ": the line has no room for the description of its result")
	}
	row := made_row(&table)
	head: [16]u8
	made_text(&table, row, 0, name)
	made_integer(&table, row, 1, i64(callable))
	made_text(&table, row, 2, how)
	made_text(&table, row, 3, hash_head_text(&head, hash))
	return made_record(&table, name)
}

// list_loaded gives the modules and the services whose exports are
// commands, and the imports of the modules: the module that each import
// names, and the module that the loader gave in its place.
list_loaded :: proc "contextless" (arguments: []Value) -> Value {
	columns := [5]Column{text_column("module", 32), text_column("call", 8), text_column("imported_by", 32), text_column("in_place_of", 32), text_column("hash_head", 16)}
	table, made := made_table("Loaded_Module", columns[:])
	if !made {
		return fail("loaded: the line has no room for the description")
	}
	loaded_row :: proc "contextless" (table: ^Made_Table, name: string, how: string, imported_by: string, in_place_of: string, hash: [32]u8) {
		row := made_row(table)
		head: [16]u8
		made_text(table, row, 0, name)
		made_text(table, row, 1, how)
		made_text(table, row, 2, imported_by)
		made_text(table, row, 3, in_place_of)
		made_text(table, row, 4, hash_head_text(&head, hash))
	}
	for &item in loaded[:loaded_count] {
		if item.sandbox != 0 {
			loaded_row(&table, item.name, "isolated", "", "", item.hash)
			sandbox := &sandboxes[item.sandbox - 1]
			for file in sandbox.files[1:max(sandbox.file_count, 1)] {
				loaded_row(&table, system.name_of(file.name[:]), "isolated", item.name, "", file.hash)
			}
			continue
		}
		loaded_row(&table, item.name, "direct", "", "", item.hash)
		placed := &space.modules[item.place]
		for number in 0 ..< int(placed.import_count) {
			record, _ := module.record(placed.file, .Imports, u32(number + 1), module.Import)
			used := &space.modules[placed.import_places[number]]
			loaded_row(&table, module_name_of(used.hash), "direct", item.name, used.hash != record.hash ? module_name_of(record.hash) : "", used.hash)
		}
	}
	for &sandbox in sandboxes {
		if sandbox.service && !sandbox.quiet {
			loaded_row(&table, sandbox.name, "service", "", "", sandbox.hash)
		}
	}
	return made_value(&table, "loaded")
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
		return loaded_record(system.name_of(entry.name[:]), callable, isolate ? "isolated" : "direct", entry.hash)
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
		memory := "left the console"
		if item.sandbox != 0 {
			sandbox := &sandboxes[item.sandbox - 1]
			sandbox_end(sandbox)
			system.ring_close(&sandbox.ring)
			system.memory_unmap(raw_data(sandbox.region))
			system.close(sandbox.ring_memory)
			system.close(sandbox.region_memory)
			system.close(sandbox.files_memory)
			sandbox^ = {}
			memory = "its sandboxed program stopped"
		} else {
			// A module that another module imports stays: one copy for all.
			// An import that no other module uses leaves with the module.
			if !system.module_space_release(&space, item.place, &load_error) {
				return fail_load("cannot remove ", item.name)
			}
			if space.modules[item.place].users != 0 {
				memory = "stays: another module imports it"
			}
		}
		columns := [3]Column{text_column("module", 32), integer_column("commands"), text_column("memory", 40)}
		table, made := made_table("Unloaded", columns[:])
		row := made_row(&table)
		made_text(&table, row, 0, item.name)
		made_integer(&table, row, 1, i64(removed))
		made_text(&table, row, 2, memory)
		loaded[index] = loaded[loaded_count - 1]
		loaded_count -= 1
		if !made {
			return fail(name, ": the line has no room for the description of its result")
		}
		return made_record(&table, "unload")
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
	line_records_try_again()
	sandbox: ^Sandbox
	number := 0
	for &item, index in sandboxes {
		if !item.service || item.name != name {
			continue
		}
		// The commands of the service exist already: the answer is the
		// record of the connection, again.
		if !item.quiet {
			if entry := system.image_entry_of(image, item.hash); entry != nil {
				return loaded_record(item.name, callable_count(image[entry.offset:][:entry.size]), "service", item.hash)
			}
			return fail("the boot image has no file with the hash of the program ", name)
		}
		// The console connected for itself: the commands come now.
		sandbox, number = &item, index + 1
	}
	fresh := sandbox == nil
	if fresh {
		sandbox, number = sandbox_free()
		if sandbox == nil {
			return fail("no room for the service ", name)
		}
		sandbox^ = {
			name    = name,
			service = true,
		}
	}
	if fresh || sandbox.program == 0 {
		refused: ring.Record
		if status := service_connect(sandbox, &refused); status != .Ok {
			sandbox^ = {}
			if refused.kind == 0 {
				return fail("cannot connect to ", name, ": ", status == .Bad_State ? "the root service did not answer" : "the call ring or the call region does not map")
			}
			return fail_root(scratch_text("cannot connect to ", name, ": "), refused)
		}
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
		sandbox.quiet = false
		commands_add(file, sandbox.name, number, 0)
		return loaded_record(sandbox.name, callable, "service", entry.hash)
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
	// The module runs in this program: its log records are records of the
	// console.
	line_records_call_begins("console")
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
	// input. The export appends to it only when it fails.
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
		result := export_failure(item, &error, i64(results[0]))
		failure_details_set(details[:], details_place.count)
		return result
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

// fail_load makes the line fail with a load error: the sentence says what
// failed, and the lines of the record follow it in the error of the line.
// Each line is drawn after "error: ". When the load
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
			fail_note(text[:end])
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
			fail_note(rest)
		}
	}
	load_details.count = 0
	return result
}

// fault_print adds to the error of the line where a program stopped on a fault: the module that
// ran, as the loader of the program recorded it, and the module that it
// replaced. With the debug image, the instruction and each frame have the
// name of their procedure and their source line.
fault_print :: proc "contextless" (report: ^op.Stop_Report) {
	if report.module.size != 0 {
		buffer: [256]u8
		writer := system.Writer{buffer = buffer[:]}
		named := false
		if entry := system.image_entry_of(image, report.module.hash); entry != nil && debug_names.image != nil {
			named = system.place_write(&writer, system.debug_object_of(&debug_names, report.module.hash), report.instruction - report.module.base, system.name_of(entry.name[:]), false)
		}
		if named {
			fail_note("the instruction is at ", system.written(&writer))
		} else {
			fail_note("the instruction is at offset ", system.Hex(report.instruction - report.module.base), " of ", module_text(report.module.hash))
		}
		if report.module.replaces != {} {
			fail_note(module_text(report.module.hash), " runs in place of ", module_text(report.module.replaces))
		}
	}
	// The stack trace: the instruction, then the return address of each call.
	for &frame, number in report.frames[:min(report.frame_count, op.STOP_FRAME_CAPACITY)] {
		buffer: [256]u8
		writer := system.Writer{buffer = buffer[:]}
		system.frame_text(&writer, image, &debug_names, &frame, number)
		fail_note("frame ", u64(number), ": ", system.written(&writer), number == 0 ? ", the instruction" : "")
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

// export_failure makes the line fail with the error record of an export
// that failed: the sentence of the record, and the record itself with the
// names of the export and of its parameters, from the description.
export_failure :: proc "contextless" (item: ^Command, error: ^errors.Error_Record, answer: i64) -> Value {
	already := failed
	argument := ""
	if error.argument >= 1 && error.argument <= i64(item.parameter_count) {
		argument = item.parameter_names[error.argument - 1]
	}
	buffer: [240]u8
	writer := system.Writer{buffer = buffer[:]}
	system.error_text(&writer, error, item.name, argument)
	result := fail(system.written(&writer), " (", answer, ")")
	if !already {
		failure_record_set(error^, item.name, item.parameter_names[:item.parameter_count])
	}
	return result
}

// stop_reason gives the text of the code of a stopped program: each fault
// kind that the kernel delivers, and each stop code of the kernel.
stop_reason :: proc "contextless" (code: u32) -> string {
	switch code {
	case op.STOP_CODE_FAULT + u32(op.Fault_Kind.Divide_Error):
		return "division by zero"
	case op.STOP_CODE_FAULT + u32(op.Fault_Kind.Debug):
		return "debug trap"
	case op.STOP_CODE_FAULT + u32(op.Fault_Kind.Breakpoint):
		return "breakpoint"
	case op.STOP_CODE_FAULT + u32(op.Fault_Kind.Invalid_Opcode):
		return "invalid instruction"
	case op.STOP_CODE_FAULT + u32(op.Fault_Kind.Segment_Not_Present):
		return "segment not present"
	case op.STOP_CODE_FAULT + u32(op.Fault_Kind.Stack_Fault):
		return "stack fault"
	case op.STOP_CODE_FAULT + u32(op.Fault_Kind.General_Protection):
		return "protection fault"
	case op.STOP_CODE_FAULT + u32(op.Fault_Kind.Page_Fault):
		return "page fault"
	case op.STOP_CODE_FAULT + u32(op.Fault_Kind.X87_Floating_Point):
		return "x87 floating-point error"
	case op.STOP_CODE_FAULT + u32(op.Fault_Kind.Alignment_Check):
		return "alignment check"
	case op.STOP_CODE_FAULT + u32(op.Fault_Kind.Simd_Floating_Point):
		return "SIMD floating-point error"
	case op.STOP_CODE_NO_HANDLE:
		return "its last handle closed"
	case op.STOP_CODE_NOT_COMMITTED:
		return "page fault on a page that is not committed"
	case op.STOP_CODE_RETURN:
		return "the kernel cannot return to its thread"
	case op.STOP_CODE_FAULT_UNANSWERED:
		return "a fault that no thread can answer: its fault ring ended"
	}
	return code >= op.STOP_CODE_FAULT ? "fault" : "it stopped itself"
}

// call_isolated calls an export of a module in its call host. The arguments
// go in the call region as one argument record; one command record of the
// call ring names it; the completion record has the result.
// A module that faults stops alone: the console reports an error and
// continues. A call has no time limit: the input stops it with Escape,
// and the console then stops the call host. The next call starts a new
// call host.
call_isolated :: proc "contextless" (item: ^Command, arguments: []Value) -> Value {
	// From here to the return, Escape stops this call: outside a call,
	// Escape is a key of the next line.
	intrinsics.atomic_store(&work.call_stoppable, 1)
	defer intrinsics.atomic_store(&work.call_stoppable, 0)
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
	line_records_call_begins(sandbox.name)
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
	// input. Its places are reserved in the call region; the details come
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
	// The log records that the program writes show under the line while
	// the call runs: the console reads them at this interval, never before
	// the first look at the answer.
	records_due := system.time() + STATUS_INTERVAL
	for {
		if system.time() >= records_due {
			line_records_show_during(item.sandbox)
			records_due = system.time() + STATUS_INTERVAL
		}
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
					result := export_failure(item, &error, i64(completion.values[0]))
					if item.details_parameter != 0 {
						if problem, _ := isolated.error_details_return(item.file, item.function, encoded[:parameter_total], sandbox.region, offset); problem != .None {
							fail_note("the program ", sandbox.name, " gave a wrong count for the table of error details: the details are missing")
						} else {
							failure_details_set(details[:], encoded[item.details_parameter - 1].table.count)
						}
					}
					return result
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
			return fail("Escape stopped the call of ", item.name, sandbox.service ? ": the console closed the connection to " : ": the console stopped the program ", sandbox.name)
		}
		system.wait_records(&wait, &sandbox.ring.completions)
		system.wait_word(&wait, &work.cancel, 0)
		// The time only wakes the thread to read the log records again:
		// a call has no time limit.
		system.wait_end(&wait, records_due)
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

// request asks the root service to start or to stop a program. It gives
// nothing: a refusal is the error of the line, with the error record of the
// root service.
request :: proc "contextless" (kind: system.Root_Command, name: string) -> Value {
	completion, answered := request_record(kind, name)
	if !answered {
		return fail_no_answer()
	}
	if system.Status(completion.kind) != .Ok {
		return fail_root("", completion)
	}
	return {}
}

// grants gives what a program has from the root service, of the grants
// that the root service can revoke: one row for each grant that it holds,
// then one for each grant that it lost.
grants :: proc "contextless" (arguments: []Value) -> Value {
	name := arguments[0].text
	completion, answered := request_record(.Grants, name)
	if !answered {
		return fail_no_answer()
	}
	if system.Status(completion.kind) != .Ok {
		return fail_root("", completion)
	}
	columns := [5]Column{text_column("program", 32), text_column("grant", 24), text_column("state", 8), integer_column("principal"), text_column("principal_name", 32)}
	table, made := made_table("Grant", columns[:])
	if !made {
		return fail("grants: the line has no room for the description")
	}
	// Who the grants are for: the principal of the session of the program.
	principal_name := system.name_unpack({completion.values[3], completion.values[4], completion.values[5], completion.values[6]})
	for set, pass in ([2]system.Root_Grants{transmute(system.Root_Grants)completion.values[0], transmute(system.Root_Grants)completion.values[1]}) {
		for grant in system.Root_Grant {
			if grant not_in set {
				continue
			}
			row := made_row(&table)
			made_text(&table, row, 0, name)
			made_text(&table, row, 1, system.root_grant_names[grant])
			made_text(&table, row, 2, pass == 0 ? "held" : "lost")
			made_integer(&table, row, 3, i64(completion.values[2]))
			made_text(&table, row, 4, system.name_of(principal_name[:]))
		}
	}
	return made_value(&table, "grants")
}

// principal_create asks the root service for a new named principal. The
// passphrase is never a text of the console: the console keeps each line in
// its history, so the passphrase is typed in the window of unlock.
principal_create :: proc "contextless" (arguments: []Value) -> Value {
	completion, answered := request_record(.Principal_Create, arguments[0].text)
	if !answered {
		return fail_no_answer()
	}
	if system.Status(completion.kind) != .Ok {
		return fail_root("", completion)
	}
	return {}
}

// lock_session ends the session of the named principal that is unlocked,
// and gives the count of its programs that stopped.
lock_session :: proc "contextless" (arguments: []Value) -> Value {
	completion, answered := request_record(.Principal_Lock, "")
	if !answered {
		return fail_no_answer()
	}
	if system.Status(completion.kind) != .Ok {
		return fail_root("", completion)
	}
	return {kind = .Integer, integer = i64(completion.values[0])}
}

@(rodata)
principal_state_names := [system.Principal_State]string {
	.Absent   = "absent",
	.Machine  = "machine",
	.Locked   = "locked",
	.Unlocked = "unlocked",
	.Creating = "creating",
}

// first_bytes_hexadecimal writes 8 bytes, in their order in memory, as 16
// hexadecimal digits: the start of a key or of a measure as a reader
// compares it.
first_bytes_hexadecimal :: proc "contextless" (value: u64) -> (digits: [16]u8) {
	bytes := transmute([8]u8)value
	hexadecimal := "0123456789abcdef"
	for item, index in bytes {
		digits[2 * index] = hexadecimal[item >> 4]
		digits[2 * index + 1] = hexadecimal[item & 15]
	}
	return
}

// list_principals gives one row for each principal of the root service.
list_principals :: proc "contextless" (arguments: []Value) -> Value {
	columns := [5]Column{integer_column("number"), text_column("name", 32), text_column("state", 12), text_column("public_key_head", 16), text_column("measure_head", 16)}
	table, made := made_table("Principal", columns[:])
	if !made {
		return fail("principals: the line has no room for the description")
	}
	for number in u64(0) ..< 2 {
		completion, answered := request_record(.Principals, "", number)
		if !answered {
			return fail_no_answer()
		}
		if system.Status(completion.kind) != .Ok {
			continue // No record with this number.
		}
		state := completion.values[0] <= u64(max(system.Principal_State)) ? system.Principal_State(completion.values[0]) : .Absent
		principal_name := system.name_unpack({completion.values[1], completion.values[2], completion.values[3], completion.values[4]})
		row := made_row(&table)
		made_integer(&table, row, 0, i64(number))
		made_text(&table, row, 1, system.name_of(principal_name[:]))
		made_text(&table, row, 2, principal_state_names[state])
		if completion.values[5] != 0 {
			key_digits := first_bytes_hexadecimal(completion.values[5])
			made_text(&table, row, 3, string(key_digits[:]))
		}
		// The measure of the system belongs to the machine: principal 0.
		if number == 0 && completion.values[6] != 0 {
			measure_digits := first_bytes_hexadecimal(completion.values[6])
			made_text(&table, row, 4, string(measure_digits[:]))
		}
	}
	return made_value(&table, "principals")
}

// revoke asks the root service to end one grant of a program that runs,
// and gives the count of the holdings that ended.
revoke :: proc "contextless" (arguments: []Value) -> Value {
	name := arguments[0].text
	for grant in system.Root_Grant {
		if system.root_grant_names[grant] != arguments[1].text {
			continue
		}
		if grant == .Palette && name == "console" {
			palette_stop_before_revoke() // The table and the ring end with the grant.
		}
		completion, answered := request_record(.Revoke, name, u64(grant))
		if !answered {
			return fail_no_answer()
		}
		if system.Status(completion.kind) == .Ok {
			return {kind = .Integer, integer = i64(completion.values[0])}
		}
		return fail_root("", completion)
	}
	return fail("no grant has the name ", arguments[1].text, ": the grants are log, machine, image, log_records, store, network, acts_for_principal, history, debug, palette")
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
		return fail_no_answer()
	}
	#partial switch system.Status(completion.kind) {
	case .Ok:
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

// list_replacements gives the replacement table of the machine.
list_replacements :: proc "contextless" (arguments: []Value) -> Value {
	if replacement_table == nil {
		return fail("the console has no grant to read the replacement table")
	}
	columns := [4]Column{text_column("module", 32), text_column("by", 32), text_column("module_hash_head", 16), text_column("by_hash_head", 16)}
	table, made := made_table("Replacement", columns[:])
	if !made {
		return fail("replacements: the line has no room for the description")
	}
	for item in system.replacements_read(replacement_table, &replacement_records) {
		row := made_row(&table)
		from_head, to_head: [16]u8
		made_text(&table, row, 0, module_name_of(item.from))
		made_text(&table, row, 1, module_name_of(item.to))
		made_text(&table, row, 2, hash_head_text(&from_head, item.from))
		made_text(&table, row, 3, hash_head_text(&to_head, item.to))
	}
	return made_value(&table, "replacements")
}

start_program :: proc "contextless" (arguments: []Value) -> Value {
	// The log service can be the program that starts: the console tries
	// its connection again.
	line_records_try_again()
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

BYTES_MOST :: 4096 // The most bytes that one call of bytes copies.

// buffer_bytes copies bytes of a memory object into the memory of the
// line: the console maps the object for the time of the command. The value
// keeps the place of its first byte, for the view.
buffer_bytes :: proc "contextless" (arguments: []Value) -> Value {
	memory := system.Handle(arguments[0].integer)
	first, count := arguments[1].integer, arguments[2].integer
	kind, _, _ := system.handle_state(memory)
	if kind != .Memory {
		return fail("bytes: the handle names no memory object")
	}
	if count < 0 || count > BYTES_MOST {
		return fail("bytes: the count is ", count, "; it is 0 to ", i64(BYTES_MOST))
	}
	size := system.memory_size(memory) * system.PAGE_SIZE
	if first < 0 || u64(first) > size || u64(count) > size - u64(first) {
		return fail("bytes: the memory object has ", size, " bytes; it does not have ", count, " bytes from the byte ", first)
	}
	copied := table_bytes(int(count))
	if copied == nil && count > 0 {
		return fail("bytes: the line has no room for ", count, " bytes")
	}
	address, status := system.memory_map(memory, {})
	if status != .Ok {
		return fail("the console cannot map the memory object")
	}
	defer system.memory_unmap(address)
	copy(copied, ([^]u8)(address)[first:][:count])
	return {kind = .Bytes, integer = first, record = copied}
}

release :: proc "contextless" (arguments: []Value) -> Value {
	if kind, _, _ := system.handle_state(system.Handle(arguments[0].integer)); kind != .Memory {
		return fail("release closes a memory object that buffer made")
	}
	system.close(system.Handle(arguments[0].integer))
	return {}
}

// list_variables gives one row for each variable: its name, its type, and
// its value as a text.
list_variables :: proc "contextless" (arguments: []Value) -> Value {
	columns := [3]Column{text_column("name", VARIABLE_NAME_SIZE), text_column("type", 64), text_column("value", 128)}
	table, made := made_table("Variable", columns[:])
	if !made {
		return fail("variables: the line has no room for the description")
	}
	for &variable in variables {
		if variable.name_count == 0 {
			continue
		}
		value := variable.value
		row := made_row(&table)
		type_buffer: [64]u8
		type_writer := system.Writer {
			buffer = type_buffer[:],
		}
		system.write_type(&type_writer, value.file, module.Type(value.kind), value.detail)
		value_buffer: [128]u8
		value_writer := system.Writer {
			buffer = value_buffer[:],
		}
		#partial switch value.kind {
		case .Integer:
			system.write_part(&value_writer, value.integer)
		case .Handle:
			system.write_part(&value_writer, u64(value.integer))
		case .Text:
			system.write_part(&value_writer, value.text)
		case .Record:
			record_fields_text(&value_writer, value)
		case .Table:
			if rows, ok := table_of(value); ok {
				system.write_part(&value_writer, i64(rows.rows))
				system.write_part(&value_writer, rows.rows == 1 ? " row" : " rows")
			}
		}
		made_text(&table, row, 0, string(variable.name[:variable.name_count]))
		made_text(&table, row, 1, system.written(&type_writer))
		made_text(&table, row, 2, system.written(&value_writer))
	}
	return made_value(&table, "variables")
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
