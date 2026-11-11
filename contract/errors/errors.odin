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
package errors

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
Kind :: enum i64 {
	None              = 0,
	Empty             = 1, // A text argument has no byte. limit: the most that it can have.
	Too_Long          = 2, // value: the size of the argument; limit: the most that it can have.
	Too_Small         = 3, // value: the size of the argument; limit: the least that it must have.
	Bad_Value         = 4, // value: a value that the call refuses; limit: the largest value that it takes, or 0 when the sentence gives no range.
	Bad_Flags         = 5, // value: the flags; limit: the flags that the call knows.
	Bad_Byte          = 6, // value: the offset of the byte in the text; found: the byte.
	Bad_Address       = 7, // value: the address; limit: the count of bytes; found: 1 when the call writes there.
	Handle_Absent     = 8, // value: a number that names no handle of the caller.
	Handle_Ended      = 9, // value: the handle; found: an End.
	Handle_Kind       = 10, // value: the handle; limit: the kind of object that the call needs; found: the kind of its object (op.Object_Kind).
	Handle_Rights     = 11, // value: the handle; limit: the rights that the call needs; found: the rights of the handle (op.Rights).
	Budget            = 12, // value: the handle of the budget; limit: what the call asks; found: what the budget holds.
	Budget_Hidden     = 13, // value: the handle of the budget; limit: what the call asks. The handle has no right Read: the budget is not described.
	Over_Limit        = 14, // value: what the call makes; limit: the limit. Unit Blocks (the storage service): the blocks of the current objects with the change, with no earlier version kept.
	Full              = 15, // A table has no free place. limit: its capacity.
	State             = 16, // value: the handle; found: the op.Program_State of its object, or 0 when the handle has no right Read.
	Absent            = 17, // No object has the name or the number of the argument.
	Damaged           = 18, // The object of the argument exists, and a block of it has a wrong check.
	Device            = 19, // A device reported an error. found: the status of the device.
	No_Grant          = 20, // The caller has no grant for this call: the unit says which grant.
	Malformed         = 21, // The module of the argument breaks a rule of the module format. value: the kind of the problem; found: the byte of the file.
	No_Target         = 22, // value: the handle of a memory object that names no one other program to receive the handle.
	Overlap           = 23, // value: an address; limit: the count of bytes. They overlap something that the program has.
	Unknown_Operation = 24, // value: the number of the operation.
	Refused           = 25, // The call refused, and gives no more detail. found: the status (op.Status for the kernel).
	No_Answer         = 26, // No answer before the time limit. value: the IPv4 address that did not answer, or 0; limit: the milliseconds waited; found: what did not answer: 1 its hardware address (ARP), 2 the echo, 3 the device.
	Unsupported       = 27, // The receiver does not do this command. value: the command, or the field that it does not do.
	Link_Down         = 28, // The link of the network device is down.
	Busy              = 29, // Too many requests are in flight. value: the requests in flight, or 0 when the receiver does not count them; limit: the most.
	Out_Of_Range      = 30, // The argument names units past the end. value: the end of what it names (its first unit and its count); limit: the units that exist.
	Reserved          = 31, // The argument names a program of the system that the call does not act on: it starts at boot, or it is a device service.
}

// What value, limit and found count.
Unit :: enum i64 {
	None        = 0,
	Bytes       = 1,
	Pages       = 2,
	Blocks      = 3,
	Objects     = 4, // Objects of a store.
	Stores      = 5,
	Programs    = 6,
	Threads     = 7,
	Handles     = 8, // The handle table of a program.
	Mappings    = 9,
	Modules     = 10, // Module records of a program.
	Words       = 11, // The words of one word wait.
	Log_Records = 12, // Log records in one second.
	Processor   = 13, // Microseconds of processor time in one second.
	Budgets     = 14,
	Interrupts  = 15,
	Memory      = 16, // Memory objects of the machine.
	Store       = 17, // No_Grant: a private store.
	Person      = 18, // No_Grant: to act for the person.
	Records     = 19,
	Connection  = 20, // No_Grant: a connection to the service.
	Milliseconds = 21,
	Connections = 22, // The records of a TCP connection table (support/tcp).
	Tcp_Ports   = 23, // The local TCP ports of a client grant.
	Requests    = 24, // Requests in flight.
	Endpoint    = 25, // A remote of the network: an IPv4 address and a port, in one value (endpoint_pack). No_Grant: value the remote that the call names, limit the remote of the grant (0: none), found the local port when it is not a port of the endpoint.
	Region      = 26, // Absent: the data region of a ring.
	Root_Commands = 27, // No_Grant: the commands of the root ring that change other programs.
	Services    = 28, // Services that run.
	Grants      = 29, // The grants of a program (system.Root_Grant).
	Display     = 30, // No_Grant: a surface on the screen (the ring to the compositor).
	Terminal    = 31, // No_Grant: a terminal (the terminal ring and the text region).
	Versions    = 32, // Absent: the versions of an object (value: the generation that the argument named).
	Counts      = 33, // Damaged: the counts of the blocks of a store are not trusted after a fault of the service; it makes no change in the store.
	References  = 34, // Over_Limit: the names of one block, which a count holds.
	Commit_Blocks = 35, // Full: the blocks that one commit can change or write.
}

// How a handle ended (Handle_Ended).
End :: enum i64 {
	Unknown = 0,
	Closed  = 1, // Its program closed it.
	Revoked = 2, // A revocation ended it (Handle_Revoke).
}

// error_make gives a record. Each field that is not given is zero.
error_make :: proc "contextless" (kind: Kind, unit: Unit = .None, argument: i64 = 0, value: i64 = 0, limit: i64 = 0, found: i64 = 0) -> Error_Record {
	return {kind = i64(kind), unit = i64(unit), argument = argument, value = value, limit = limit, found = found}
}

// fail writes a record for the caller of an export, and gives its result: a
// negative number. error can be nil: the caller asked for no record.
fail :: proc "contextless" (error: ^Error_Record, result: i64, kind: Kind, unit: Unit = .None, argument: i64 = 0, value: i64 = 0, limit: i64 = 0, found: i64 = 0) -> i64 {
	if error != nil {
		error^ = error_make(kind, unit, argument, value, limit, found)
	}
	return result
}

// The text of a kind and of a unit, for a sentence. A value out of the
// enumeration has no text: the reader says "unknown".
kind_known :: proc "contextless" (kind: i64) -> bool {
	return kind > 0 && kind <= i64(max(Kind))
}

unit_known :: proc "contextless" (unit: i64) -> bool {
	return unit >= 0 && unit <= i64(max(Unit))
}

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
	.Person      = "to act for the person",
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
	.Versions    = "versions of the object",
	.Counts      = "the counts of the blocks of the store",
	.References  = "names of one block",
	.Commit_Blocks = "blocks that one commit can change",
}

// A ring completion (contract/ring) has the status of the contract of its
// ring in its kind. When the status is not 0, its seven values are an error
// record: the same 56 bytes as the values of a completion of the kernel.
// operation: the command; argument: the number of the value of the command
// that is wrong, from 1, or 0 for the command as a whole.
completion_record :: proc "contextless" (values: [7]u64) -> Error_Record {
	return transmute(Error_Record)values
}

completion_values :: proc "contextless" (record: Error_Record) -> [7]u64 {
	return transmute([7]u64)record
}

// ring_fail gives the values of a completion that fails.
ring_fail :: proc "contextless" (command: u32, kind: Kind, unit: Unit = .None, argument: i64 = 0, value: i64 = 0, limit: i64 = 0, found: i64 = 0) -> [7]u64 {
	record := error_make(kind, unit, argument, value, limit, found)
	record.operation = i64(command)
	return completion_values(record)
}

// endpoint_pack gives the value of a remote (Unit.Endpoint).
endpoint_pack :: proc "contextless" (address: u32, port: u16) -> i64 {
	return i64(address) << 16 | i64(port)
}

endpoint_unpack :: proc "contextless" (value: i64) -> (address: u32, port: u16) {
	return u32(u64(value) >> 16), u16(u64(value))
}
