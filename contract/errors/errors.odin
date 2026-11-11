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
	Bad_Value         = 4, // value: a value that the call refuses; limit: the largest value that it takes, or 0.
	Bad_Flags         = 5, // value: the flags; limit: the flags that the call knows.
	Bad_Byte          = 6, // value: the offset of the byte in the text; found: the byte.
	Bad_Address       = 7, // value: the address; limit: the count of bytes; found: 1 when the call writes there.
	Handle_Absent     = 8, // value: a number that names no handle of the caller.
	Handle_Ended      = 9, // value: the handle; found: an End.
	Handle_Kind       = 10, // value: the handle; limit: the kind of object that the call needs; found: the kind of its object (op.Object_Kind).
	Handle_Rights     = 11, // value: the handle; limit: the rights that the call needs; found: the rights of the handle (op.Rights).
	Budget            = 12, // value: the handle of the budget; limit: what the call asks; found: what the budget holds.
	Budget_Hidden     = 13, // value: the handle of the budget; limit: what the call asks. The handle has no right Read: the budget is not described.
	Over_Limit        = 14, // value: what the call makes; limit: the limit.
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
}
