// The error record: what a call that failed gives back to its caller
// (docs/MODULE_CONTRACT.md, section 8).
//
// A kernel operation that fails gives the record in the values of its
// completion record. An export that can fail has a last parameter
// `error: ^errors.Error_Record`: it writes the record there when it fails,
// and only then; it fails when its integer result is negative.
//
// The record holds values only: no text, no address. Its seven fields are
// Integers, so an export describes it as any record (module.Record), and a
// program in any language reads it. Zero is "no error".
//
// Who uses it: the kernel (each failed operation), every service (the
// completion of a ring command that fails), every module (an export that
// fails), and every program that reports a failure: the console and the
// library `support/sentence` turn a record into one sentence of English.
//
// The parts of the package:
//
// - `Error_Record`: the seven values.
// - `Kind`: what is wrong, and what `value`, `limit` and `found` hold for it.
// - `Unit`: what those values count.
// - `End`: how a handle ended, for `Handle_Ended`.
// - `error_make`, `fail`, `ring_fail`: write a record.
// - `completion_record`, `completion_values`: read and write a record as
//   the seven values of a completion.
// - `endpoint_pack`, `endpoint_unpack`: one remote of the network as one
//   value.
//
// The design is in (docs/MODULE_CONTRACT.md, "8. Errors that diagnose"). See
// [error record](term:error-record).
package errors

// The error record: what a call that failed says about why, as seven
// integers.
//
// The callee writes it, and only when the call fails; the caller reads it.
// A record from another program is a claim of that program: a reader shows
// it, and checks a kind or a unit that it does not know (`kind_known`,
// `unit_known`) before it indexes a table with it. 56 bytes: the seven
// values of a completion record.
//
// Example: `Memory_Create` of 16 pages, with a budget handle with **Read**
// whose budget holds 10 pages, fails with `{kind = .Budget, unit = .Pages,
// argument = 1, value = <the budget handle>, limit = 17, found = 10}`: the
// object costs its 16 pages and one list page (`operation.memory_cost`).
Error_Record :: struct {
	kind:      i64, // A Kind. 0: no error.
	unit:      i64, // A Unit: what value, limit and found count.
	operation: i64, // A kernel operation (op.Operation), or the number of the export in the file of its module.
	argument:  i64, // The number of the argument that is wrong, from 1. 0: the call as a whole.
	value:     i64, // The value that the argument had: see Kind.
	limit:     i64, // What the argument must respect: see Kind.
	found:     i64, // What the system found: see Kind.
}
#assert(size_of(Error_Record) == 56) // The values of a completion record.

// What is wrong. The meaning of value, limit and found for each kind:
//
// A kind names the class of the mistake, and the unit names what the values
// count. The comment of each member gives what `value`, `limit` and `found`
// hold, and which calls give it. A kind that is not in this list is
// "unknown" to a reader (`kind_known`). The page "Error kinds and units" of
// the site shows this table.
Kind :: enum i64 {
	None              = 0, // No error: the record of a call that did not fail is all zero.
	Empty             = 1, // A text argument has no byte. limit: the most that it can have.
	// Given by the storage service and by the HTTP server (`programs/server`) for an empty name, and by QUIC.
	Too_Long          = 2, // value: the size of the argument; limit: the most that it can have.
	// The unit names what the size counts: `Words` for a word wait, `Bytes` for a name of the storage service or a
	// frame of the frame service.
	Too_Small         = 3, // value: the size of the argument; limit: the least that it must have.
	// The kernel gives it for a report buffer below the size of its report (`Inspect`), and for a count of 0 where
	// one is needed. The block, frame and network services give it for a buffer too small for one block or frame.
	Bad_Value         = 4, // value: a value that the call refuses; limit: the largest value that it takes, or 0 when the sentence gives no range;
	// found: 0, or the part of the argument that the call refuses, as the call numbers its parts (Thread_Control:
	// op.Thread_Write_Refusal).
	//
	// The general kind for a number out of its range or with no meaning: a level of the log, a weight of a
	// thread, a setting that names no value, a command of the terminal ring.
	Bad_Flags         = 5, // value: the flags; limit: the flags that the call knows.
	// The kernel gives it for `Memory_Create`, `Memory_Map`, `Memory_Commit`, `Memory_Protect` and `Fault_Handler_Set` with a
	// flag or a kind that it does not know, or with two flags that do not go together.
	Bad_Byte          = 6, // value: the offset of the byte in the text; found: the byte.
	// A name or a text holds a byte that the call refuses: the storage service for a byte 0 or `/` in a name, or a
	// name `.` or `..`, the HTTP server for a byte that a name of a page cannot hold.
	Bad_Address       = 7, // value: the address; limit: the count of bytes; found: 1 when the call writes there.
	// The kernel gives it with the status `Bad_Address`: the program cannot read, or write, the bytes that an
	// argument names.
	Handle_Absent     = 8, // value: a number that names no handle of the caller.
	// With the unit `Lent_Handles`: in an isolated call, the handle did not come through the call ring.
	Handle_Ended      = 9, // value: the handle; found: an End.
	// The handle named an object once: it was closed or revoked. The kernel gives it with `Bad_Handle`.
	Handle_Kind       = 10, // value: the handle; limit: the kind of object that the call needs; found: the kind of its object (op.Object_Kind).
	// The kernel gives it with `Bad_Handle`: for example a memory handle given to `Program_Start`.
	Handle_Rights     = 11, // value: the handle; limit: the rights that the call needs; found: the rights of the handle (op.Rights).
	// The kernel gives it with `No_Right`. Both sets are `op.Rights` as integers.
	Budget            = 12, // value: the handle of the budget; limit: what the call asks; found: what the budget holds.
	// The kernel gives it with `No_Budget` when the handle has **Read**. The unit names the amount: `Pages`,
	// `Programs`, `Threads`, `Processor` or `Log_Records`.
	Budget_Hidden     = 13, // value: the handle of the budget; limit: what the call asks. The handle has no right Read: the budget is not described.
	// The kernel gives it with `No_Budget`. The record depends on the call alone, so it tells nothing of a budget
	// that another program shares.
	Over_Limit        = 14, // value: what the call makes; limit: the limit. Unit Blocks (the storage service): the blocks of the current objects with the change, with no earlier version kept.
	// The kernel gives it for `Log` above the records of the second (`Log_Records`). The network service gives it
	// with `Bytes` when a send passes the limit of the address check; the remote service with `Milliseconds` when
	// a call passes its time limit.
	Full              = 15, // A table has no free place. limit: its capacity.
	// The unit names the table: `Handles`, `Mappings`, `Threads`, `Modules`, `Interrupts`, `Places`,
	// `Connections`, `Principals`, `Commit_Blocks`. Another try can pass after a place frees.
	State             = 16, // value: the handle; found: the op.Program_State of its object, or 0 when the handle has no right Read.
	// The kernel gives it with `Bad_State`: the program is stopped, or not started yet. A service gives it for a
	// connection or a stream that is not in the state of the command.
	Absent            = 17, // No object has the name or the number of the argument. found: 0, or the number from 1 of the row of a table argument that names it.
	// The unit names what is absent: `Objects` or `Trees` (a name of the storage service), `Places`, `Versions`,
	// `Principals`, `Region`, a setting, a host of the network.
	Damaged           = 18, // The object of the argument exists, and a block of it has a wrong check.
	// The storage service gives it when a block of an object or of a tree does not match its hash. With the unit
	// `Counts`: the counts of the blocks are not trusted after a fault of the service.
	Device            = 19, // A device reported an error. found: the status of the device.
	// The storage service gives it when the block service failed a read or a write.
	No_Grant          = 20, // The caller has no grant for this call: the unit says which grant.
	// Given by a service: the storage service (`Store`, `Changes`), the root service (`Root_Commands`,
	// `Acts_For_Principal`), the compositor (`Display`), the terminal (`Terminal`), the network service
	// (`Endpoint`, `Connection`). The fix is a grant from the starter of the program, not another call.
	Malformed         = 21, // The module of the argument breaks a rule of the module format. value: the kind of the problem; found: the byte of the file.
	// Given by the loader of `support/system` and by the program `manual`. Also by `system.ring_open` with
	// argument 1: the header of a ring is not one that `ring.open` takes.
	No_Target         = 22, // value: the handle of a memory object that names no one other program to receive the handle.
	// The kernel gives it for `Handle_Give` whose target is a memory object that no one other program maps or
	// holds.
	Overlap           = 23, // value: an address, or with the unit Region an offset in the call region of an isolated call; limit: the count of bytes. They overlap something that the program has, or another argument of the call that is written.
	// The kernel gives it for `Memory_Map` at an address that another mapping holds, for `Program_Module` over
	// another module record, and for `Memory_Commit` with ranges that overlap.
	Unknown_Operation = 24, // value: the number of the operation.
	// The kernel gives it for a command record whose kind is 0 or above the last `op.Operation`; limit is the
	// last operation.
	Refused           = 25, // The call refused, and gives no more detail. found: the status (op.Status for the kernel).
	// The last resort of a callee that has no better kind: a reader shows the status.
	No_Answer         = 26, // No answer before the time limit. value: the IPv4 address that did not answer, or 0; limit: the milliseconds waited; found: what did not answer: 1 its hardware address (ARP), 2 the echo, 3 the device.
	// The network service gives it, with the unit `Milliseconds`.
	Unsupported       = 27, // The receiver does not do this command. value: the command, or the field that it does not do.
	// Given by the block and frame services for a command that the device does not have, by the network
	// service, the root service and QUIC.
	Link_Down         = 28, // The link of the network device is down.
	// The network service gives it for a send while the device reports no link.
	Busy              = 29, // Too many requests are in flight. value: the requests in flight, or 0 when the receiver does not count them; limit: the most.
	// The block, frame and network services give it, with the unit `Requests`. Another try can pass after a
	// completion.
	Out_Of_Range      = 30, // The argument names units past the end. value: the end of what it names (its first unit and its count); limit: the units that exist; found: 0, or the number from 1 of the record of a table argument that names them (a record that names bytes of another argument by an offset, docs/MODULE_CONTRACT.md, "Tables and bytes as parameters").
	// The services of rings give it for a place and a count past the end of their data region (the unit `Bytes`),
	// and the storage service for a range past the end of an object.
	Reserved          = 31, // The argument names a program of the system that the call does not act on: it starts at boot, or it is a device service.
	// The root service gives it for `Start` or `Stop` of such a program.
	Not_Payer         = 32, // value: the handle of a budget that does not pay for the memory object of the call. It says nothing of the budget.
	// The kernel gives it for `Memory_Commit` with a budget that is not the budget of the object.
	Object_Shared     = 33, // value: the handle of a memory object, or 0; the call needs an object that only this program names, with one mapping at most.
	// The kernel gives it for a decommit (`Memory_Commit`) and for `Memory_Protect` on an object that another
	// handle or another mapping names.
	Object_Marked     = 34, // value: the handle of a memory object; found: its pages with a protection of their own. The object is not mapped again and not given.
	// The kernel gives it for `Memory_Map` and `Handle_Give` of an object that `Memory_Protect` changed.
	Whole_Only        = 35, // value: an address; limit: the bytes of the range. The range is a part of a mapping whose protection changes only whole (device memory, large pages), or of an area that the system keeps (a thread area).
	// The kernel gives it for `Memory_Protect`.
	Not_Multiple      = 36, // value: the argument; limit: the number that it must be a multiple of; found: the rest.
	// The kernel gives it for `Memory_Create` with `Large_Pages` and a count that is not a multiple of 512.
	Not_Authentic     = 37, // The bytes of the argument do not prove what they must: the tag of a sealed text, or a signature, does not verify. No byte of the result is given.
	// The cryptography module gives it for an open of a sealed text, and QUIC for a packet or a handshake that
	// does not verify. See [not authentic](term:not-authentic).
	Seed_Too_Weak     = 38, // The random seed of the program is weaker than the least strength that the caller accepts. value: the strength of the seed; limit: the least strength asked (1 weak, 2 processor, 3 entropy). Nothing is made.
	// `random.fill_for_a_key` gives it when the seed of the generator has a lower `Seed_Strength` than the call
	// asks. A plain draw (`random.fill`) never gives it.
	Exists            = 39, // The name of the argument names something that exists already, and the call makes a new one. found: 0, or the number from 1 of the row of a table argument that names it.
	// The storage service gives it for a new tree or object at a name in use.
}

// What value, limit and found count.
//
// With the kinds `No_Grant`, `Absent`, `Damaged` and `Handle_Absent` the
// unit names instead the grant, the table or the thing that the kind is
// about: the comment of each member says so. `UNIT_NAMES` gives the words
// that a sentence uses for each unit.
Unit :: enum i64 {
	None        = 0, // The values are plain numbers, or the kind gives them their meaning.
	Bytes       = 1, // Bytes of memory, of a file or of a text.
	Pages       = 2, // Pages of 4096 bytes.
	Blocks      = 3, // Blocks of a disk or of a store.
	Objects     = 4, // Objects of a store.
	Stores      = 5, // Stores of the storage service.
	Programs    = 6, // Program slots of a budget.
	Threads     = 7, // Thread slots of a budget, or the threads of a program.
	Handles     = 8, // The handle table of a program.
	Mappings    = 9, // The mappings of a program (`op.MAPPING_REPORT_CAPACITY`).
	Modules     = 10, // Module records of a program.
	Words       = 11, // The words of one word wait.
	Log_Records = 12, // Log records in one second.
	Processor   = 13, // Microseconds of processor time in one second.
	Budgets     = 14, // Budgets of the kernel.
	Interrupts  = 15, // Message interrupts (`op.MESSAGE_CAPACITY`).
	Memory      = 16, // Memory objects of the machine.
	Store       = 17, // No_Grant: a private store.
	Acts_For_Principal = 18, // No_Grant: to act for the principal whose session the caller belongs to.
	Records     = 19, // Records of a table argument: ranges, rules, rows.
	Connection  = 20, // No_Grant: a connection to the service.
	Milliseconds = 21, // A time: a time limit or a time waited.
	Connections = 22, // The records of a TCP connection table (support/tcp).
	Tcp_Ports   = 23, // The local TCP ports of a client grant.
	Requests    = 24, // Requests in flight.
	Endpoint    = 25, // A remote of the network: an IPv4 address and a port, in one value (endpoint_pack). No_Grant: value the remote that the call names, limit the remote of the grant (0: none), found the local port when it is not a port of the endpoint.
	Region      = 26, // Absent: the data region of a ring. Overlap: bytes of the call region of an isolated call; value is their offset, limit their count.
	Root_Commands = 27, // No_Grant: the commands of the root ring that change other programs.
	Services    = 28, // Services that run.
	Grants      = 29, // The grants of a program (system.Root_Grant).
	Display     = 30, // No_Grant: a surface on the screen (the ring to the compositor).
	Terminal    = 31, // No_Grant: a terminal (the terminal ring and the text region).
	Lent_Handles = 32, // Handle_Absent: the handle did not come through the call ring for this call (an isolated call).
	Versions    = 33, // Absent: the versions of an object (value: the generation that the argument named).
	Counts      = 34, // Damaged: the counts of the blocks of a store are not trusted after a fault of the service; it makes no change in the store.
	References  = 35, // Over_Limit: the names of one block, which a count holds.
	Commit_Blocks = 36, // Full: the blocks that one commit can change or write.
	Principals  = 37, // The named principals of the root service (docs/PRINCIPALS.md). Full: limit the named principals that it holds; Absent: no such principal, or no session runs.
	Places      = 38, // The places of a connection to the storage service (docs/STORAGE.md): Absent, the number names no place of the connection, or the tree of the place was removed or renamed; Full, the table of places.
	Trees       = 39, // Absent: the name names no tree. Bad_Value: a tree would move inside itself.
	Changes     = 40, // No_Grant: a change of a store; the connection reads only.
	Pending     = 41, // The pending changes of an object in the storage service (docs/STORAGE.md, "Ranges"). Full: limit the blocks that the service holds for them. Absent: the object has no pending change on this connection; found 1: another change of the object came first, and its pending changes are dropped.
}

// How a handle ended (Handle_Ended).
//
// The kernel keeps, in each slot of the handle table, how its last handle
// ended, so that `Handle_Ended` tells a closed handle from a revoked one.
End :: enum i64 {
	Unknown = 0, // The kernel no longer knows how: the slot served again for a later handle since.
	Closed  = 1, // Its program closed it.
	Revoked = 2, // A revocation ended it (Handle_Revoke).
}

// error_make gives a record. Each field that is not given is zero.
//
// It does not set `operation`: the kernel, `ring_fail` and a module set it
// when they know it.
//
// Example: `errors.error_make(.Too_Long, .Bytes, 2, i64(len(name)), 255)`
// says that the argument 2 has `len(name)` bytes and can have 255.
error_make :: proc "contextless" (kind: Kind, unit: Unit = .None, argument: i64 = 0, value: i64 = 0, limit: i64 = 0, found: i64 = 0) -> Error_Record {
	return {kind = i64(kind), unit = i64(unit), argument = argument, value = value, limit = limit, found = found}
}

// fail writes a record for the caller of an export, and gives its result: a
// negative number. error can be nil: the caller asked for no record.
//
// It is the last line of each failing path of an export:
//
// ```odin
// if len(name) == 0 {
// 	return errors.fail(error, ERROR_NAME, .Empty, .Bytes, 1, 0, NAME_LIMIT)
// }
// ```
fail :: proc "contextless" (error: ^Error_Record, result: i64, kind: Kind, unit: Unit = .None, argument: i64 = 0, value: i64 = 0, limit: i64 = 0, found: i64 = 0) -> i64 {
	if error != nil {
		error^ = error_make(kind, unit, argument, value, limit, found)
	}
	return result
}

// The text of a kind and of a unit, for a sentence. A value out of the
// enumeration has no text: the reader says "unknown".
//
// kind_known says if a kind from a record is a member of `Kind` other than
// `None`. A reader calls it before it indexes a table with the kind: a
// record from another program can hold any value.
kind_known :: proc "contextless" (kind: i64) -> bool {
	return kind > 0 && kind <= i64(max(Kind))
}

// unit_known says if a unit from a record is a member of `Unit`, `None`
// included. A reader calls it before it indexes `UNIT_NAMES`.
unit_known :: proc "contextless" (unit: i64) -> bool {
	return unit >= 0 && unit <= i64(max(Unit))
}

// The words of each unit in a sentence: "the budget holds 10 pages". `None`
// has no words.
@(rodata)
UNIT_NAMES := [Unit]string {
	.None        = "",
	.Bytes       = "bytes",
	.Pages       = "pages",
	.Blocks      = "blocks",
	.Objects     = "objects",
	.Stores      = "stores",
	.Programs    = "programs",
	.Threads     = "threads",
	.Handles     = "handles",
	.Mappings    = "mappings",
	.Modules     = "modules",
	.Words       = "words",
	.Log_Records = "log records in one second",
	.Processor   = "microseconds of processor time in one second",
	.Budgets     = "budgets",
	.Interrupts  = "interrupts",
	.Memory      = "memory objects",
	.Store       = "a private store",
	.Acts_For_Principal = "to act for the principal",
	.Records     = "records",
	.Connection  = "a connection to this service",
	.Milliseconds = "milliseconds",
	.Connections = "connections",
	.Tcp_Ports   = "local TCP ports",
	.Requests    = "requests in flight",
	.Endpoint    = "a remote address and port",
	.Region      = "a data region",
	.Root_Commands = "the commands of the root ring that change other programs",
	.Services    = "services that run",
	.Grants      = "grants of the program",
	.Display     = "a surface on the screen",
	.Terminal    = "a terminal",
	.Lent_Handles = "handles lent for this call",
	.Versions    = "versions of the object",
	.Counts      = "the counts of the blocks of the store",
	.References  = "names of one block",
	.Commit_Blocks = "blocks that one commit can change",
	.Principals  = "named principals",
	.Places      = "places of the connection",
	.Trees       = "trees",
	.Changes     = "a change of the store (the connection reads only)",
	.Pending     = "pending changes of the object",
}

// A ring completion (contract/ring) has the status of the contract of its
// ring in its kind. When the status is not 0, its seven values are an error
// record: the same 56 bytes as the values of a completion of the kernel.
// operation: the command; argument: the number of the value of the command
// that is wrong, from 1, or 0 for the command as a whole.
completion_record :: proc "contextless" (values: [7]u64) -> Error_Record {
	return transmute(Error_Record)values
}

// completion_values gives the seven values of a completion that carry a
// record: the reverse of `completion_record`.
completion_values :: proc "contextless" (record: Error_Record) -> [7]u64 {
	return transmute([7]u64)record
}

// ring_fail gives the values of a completion that fails: a record with
// `operation` set to the command. A service returns it with a status that is
// not 0.
//
// Example: `errors.ring_fail(u32(command), .Busy, .Requests, 0, in_flight,
// LIMIT)`.
ring_fail :: proc "contextless" (command: u32, kind: Kind, unit: Unit = .None, argument: i64 = 0, value: i64 = 0, limit: i64 = 0, found: i64 = 0) -> [7]u64 {
	record := error_make(kind, unit, argument, value, limit, found)
	record.operation = i64(command)
	return completion_values(record)
}

// endpoint_pack gives the value of a remote (Unit.Endpoint): the IPv4
// address in the bits 16 to 47 and the port in the bits 0 to 15, so that one
// value of a record names both.
//
// Example: `endpoint_pack(0x0A00_0202, 443)` is `0x0A00_0202_01BB`.
endpoint_pack :: proc "contextless" (address: u32, port: u16) -> i64 {
	return i64(address) << 16 | i64(port)
}

// endpoint_unpack gives the address and the port of a value that
// `endpoint_pack` made.
endpoint_unpack :: proc "contextless" (value: i64) -> (address: u32, port: u16) {
	return u32(u64(value) >> 16), u16(u64(value))
}
