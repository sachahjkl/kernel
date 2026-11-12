package sentence

import "contract:errors"
import module "contract:module"
import op "contract:operation"

// The sentence of an error record (docs/MODULE_CONTRACT.md, section 8). The
// record holds values only: the names come from the operation table of the
// kernel, or from the description of the export. The record can come from
// another program: a value out of an enumeration is written as a number.

// rights_text writes a set of rights from a field of an error record.
@(private = "file")
rights_text :: proc "contextless" (writer: ^Writer, value: i64) {
	rights := transmute(op.Rights)u32(value)
	if rights == {} {
		write_part(writer, "no right")
	} else {
		write_rights(writer, rights, " ")
	}
}

@(private = "file")
object_name :: proc "contextless" (value: i64) -> string {
	return value >= 0 && value <= i64(max(op.Object_Kind)) ? op.OBJECT_KIND_NAMES[op.Object_Kind(value)] : "an unknown kind of object"
}

// error_text writes the sentence of an error record.
//   operation: the name of the operation or of the export ("Memory_Map", "storage.write").
//   argument:  the name of the argument that the record names; "" when it has none.
error_text :: proc "contextless" (writer: ^Writer, record: ^errors.Error_Record, operation: string, argument: string) {
	write_part(writer, operation)
	write_part(writer, ": ")
	unit := errors.unit_known(record.unit) ? errors.UNIT_NAMES[errors.Unit(record.unit)] : "units"
	subject :: proc "contextless" (writer: ^Writer, record: ^errors.Error_Record, argument: string) {
		if record.argument == 0 {
			write_part(writer, "the call")
		} else if argument != "" {
			write_part(writer, "the argument ")
			write_part(writer, argument)
		} else {
			write_part(writer, "argument ")
			write_part(writer, record.argument)
		}
	}
	// "the argument budget, handle 0x10009,"
	handle :: proc "contextless" (writer: ^Writer, record: ^errors.Error_Record, argument: string) {
		subject(writer, record, argument)
		write_part(writer, ", handle ")
		write_number(writer, u64(record.value))
		write_part(writer, ",")
	}
	amount :: proc "contextless" (writer: ^Writer, value: i64, unit: string) {
		write_part(writer, value)
		if unit != "" {
			write_part(writer, " ")
			write_part(writer, unit)
		}
	}
	if !errors.kind_known(record.kind) {
		write_part(writer, "an error of the kind ")
		write_part(writer, record.kind)
		write_part(writer, ", which this program does not know")
		return
	}
	switch errors.Kind(record.kind) {
	case .None:
		write_part(writer, "no error")
	case .Empty:
		subject(writer, record, argument)
		write_part(writer, " is empty; it must have 1 to ")
		amount(writer, record.limit, unit)
	case .Too_Long:
		subject(writer, record, argument)
		write_part(writer, " has ")
		amount(writer, record.value, unit)
		write_part(writer, "; it can have at most ")
		amount(writer, record.limit, unit)
	case .Too_Small:
		subject(writer, record, argument)
		write_part(writer, " has ")
		amount(writer, record.value, unit)
		write_part(writer, "; it must have at least ")
		amount(writer, record.limit, unit)
	case .Bad_Value:
		subject(writer, record, argument)
		if errors.Unit(record.unit) == .Trees {
			write_part(writer, " is inside the tree that moves: a tree cannot move inside itself")
			return
		}
		write_part(writer, " has the value ")
		write_part(writer, record.value)
		write_part(writer, ", which the call refuses")
		if record.found != 0 {
			write_part(writer, " in its part ")
			write_part(writer, record.found)
		}
		if record.limit != 0 {
			write_part(writer, "; it takes at most ")
			write_part(writer, record.limit)
		}
	case .Bad_Flags:
		subject(writer, record, argument)
		write_part(writer, " has the flags ")
		write_number(writer, u64(record.value))
		write_part(writer, "; the call knows the flags ")
		write_number(writer, u64(record.limit))
	case .Bad_Byte:
		subject(writer, record, argument)
		write_part(writer, " has the byte ")
		write_part(writer, record.found)
		write_part(writer, " at offset ")
		write_part(writer, record.value)
		write_part(writer, ", which it must not have")
	case .Bad_Address:
		subject(writer, record, argument)
		write_part(writer, ", the address ")
		write_number(writer, u64(record.value))
		write_part(writer, " with ")
		amount(writer, record.limit, "bytes")
		write_part(writer, record.found != 0 ? ", is not memory that this program can write" : ", is not memory that this program can read")
	case .Handle_Absent:
		subject(writer, record, argument)
		write_part(writer, ", ")
		write_number(writer, u64(record.value))
		if errors.Unit(record.unit) == .Lent_Handles {
			write_part(writer, ", names no handle that the caller lent for this call through the call ring")
		} else {
			write_part(writer, ", names no handle of this program")
		}
	case .Handle_Ended:
		handle(writer, record, argument)
		switch errors.End(record.found) {
		case .Closed:
			write_part(writer, " was closed")
		case .Revoked:
			write_part(writer, " was revoked")
		case .Unknown:
			write_part(writer, " ended, and its place has a newer handle")
		case:
			write_part(writer, " ended")
		}
	case .Handle_Kind:
		handle(writer, record, argument)
		write_part(writer, " names a ")
		write_part(writer, object_name(record.found))
		write_part(writer, " object; the call needs a ")
		write_part(writer, object_name(record.limit))
	case .Handle_Rights:
		handle(writer, record, argument)
		write_part(writer, " has the rights ")
		rights_text(writer, record.found)
		write_part(writer, "; the call needs ")
		rights_text(writer, record.limit)
	case .Budget:
		handle(writer, record, argument)
		write_part(writer, " cannot pay ")
		amount(writer, record.limit, unit)
		write_part(writer, ": it holds ")
		amount(writer, record.found, unit)
	case .Budget_Hidden:
		if record.argument == 0 {
			write_part(writer, "the budget of the program cannot pay ")
			amount(writer, record.limit, unit)
			write_part(writer, "; the program holds it with no right Read, so the budget is not described")
			return
		}
		handle(writer, record, argument)
		if record.unit == 0 {
			write_part(writer, " cannot pay what the call asks")
		} else {
			write_part(writer, " cannot pay ")
			amount(writer, record.limit, unit)
		}
		write_part(writer, "; the handle has no right Read, so the budget is not described")
	case .Over_Limit:
		write_part(writer, "the call needs ")
		amount(writer, record.value, unit)
		write_part(writer, errors.Unit(record.unit) == .Blocks ? " in all, with no earlier version kept; the limit is " : " in all; the limit is ")
		amount(writer, record.limit, unit)
	case .Full:
		if errors.Unit(record.unit) == .Commit_Blocks {
			write_part(writer, "the call needs more blocks in one commit than one commit can change: ")
			write_part(writer, record.limit)
			return
		}
		if record.unit == 0 {
			write_part(writer, "no free place for the call")
		} else {
			write_part(writer, "no free place: the table has its ")
			amount(writer, record.limit, unit)
		}
	case .State:
		handle(writer, record, argument)
		state := record.found >= 0 && record.found <= i64(max(op.Program_State)) ? op.STATE_NAMES[op.Program_State(record.found)] : "in an unknown state"
		write_part(writer, " names a program that is ")
		write_part(writer, state)
		if record.limit != 0 {
			write_part(writer, "; the call needs a program that is created, and not started")
		}
	case .Absent:
		if errors.Unit(record.unit) == .Region {
			write_part(writer, "the ring has no data region: send Attach first, with a memory handle that came through the ring")
			return
		}
		if record.found > 0 {
			write_part(writer, "row ")
			write_part(writer, record.found)
			write_part(writer, " of ")
		}
		subject(writer, record, argument)
		if errors.Unit(record.unit) == .Bytes {
			write_part(writer, ", ")
			write_number(writer, u64(record.value))
			write_part(writer, ", names nothing that the program has")
		} else if errors.Unit(record.unit) == .Objects {
			write_part(writer, ": the store has no object with this name")
		} else if errors.Unit(record.unit) == .Places {
			write_part(writer, ": the place is not a place of this connection, or its tree was removed or renamed")
		} else if errors.Unit(record.unit) == .Trees {
			write_part(writer, ": the tree has no tree with this name")
		} else if errors.Unit(record.unit) == .Versions {
			write_part(writer, ": the object has no version of the generation ")
			write_part(writer, record.value)
		} else if record.unit != 0 {
			write_part(writer, " names none of the ")
			write_part(writer, unit)
		} else {
			write_part(writer, " names nothing that exists")
		}
	case .Damaged:
		if errors.Unit(record.unit) == .Counts {
			write_part(writer, "the counts of the blocks of the private store are not trusted after a fault of the storage service: it makes no change in the store until its next start; its objects can still be read")
			return
		}
		if errors.Unit(record.unit) == .Stores {
			write_part(writer, "the private store is damaged: a node of one of its trees, or its store block, has a wrong check")
		} else {
			write_part(writer, "the object of ")
			subject(writer, record, argument)
			write_part(writer, " is damaged: a block of it has a wrong check")
		}
	case .Device:
		write_part(writer, "the device reported an error")
		if record.found != 0 {
			write_part(writer, ": the status ")
			write_part(writer, record.found)
		}
	case .No_Grant:
		if errors.Unit(record.unit) == .Endpoint && record.found != 0 {
			write_part(writer, "the local port ")
			write_part(writer, record.found)
			write_part(writer, " of the segment is not a port of this endpoint")
			return
		}
		if errors.Unit(record.unit) == .Endpoint {
			subject(writer, record, argument)
			write_part(writer, ", ")
			endpoint_text(writer, record.value)
			if record.limit == 0 {
				write_part(writer, ", is refused: the grant names no remote (it was revoked, or the remote is not admitted)")
			} else {
				write_part(writer, ", is refused: the grant names ")
				endpoint_text(writer, record.limit)
				write_part(writer, " only")
			}
			return
		}
		write_part(writer, "the caller has no grant for this: ")
		write_part(writer, unit)
	case .Malformed:
		write_part(writer, "the module of ")
		subject(writer, record, argument)
		write_part(writer, " breaks a rule of the module format: problem ")
		write_part(writer, record.value)
		write_part(writer, " at byte ")
		write_part(writer, record.found)
	case .No_Target:
		handle(writer, record, argument)
		write_part(writer, " names memory that no one other program maps or holds: the handle has no program to go to")
	case .Overlap:
		subject(writer, record, argument)
		if errors.Unit(record.unit) == .Region {
			// An isolated call: an offset in the call region (isolated.decode).
			write_part(writer, ": the bytes from offset ")
			write_part(writer, record.value)
			write_part(writer, " of the call region, ")
			amount(writer, record.limit, "bytes")
			write_part(writer, ", overlap another argument of the call, and one of the two is written")
		} else {
			write_part(writer, ": the addresses from ")
			write_number(writer, u64(record.value))
			write_part(writer, ", ")
			amount(writer, record.limit, "bytes")
			write_part(writer, ", overlap what the program has")
		}
	case .Unknown_Operation:
		write_part(writer, "the kernel has no operation ")
		write_part(writer, record.value)
	case .No_Answer:
		write_part(writer, "no answer")
		if record.value != 0 {
			write_part(writer, " from ")
			address_text(writer, u32(record.value))
		}
		write_part(writer, " in ")
		write_part(writer, record.limit)
		write_part(writer, " ms")
		switch record.found {
		case 1:
			write_part(writer, ": its hardware address is not known (ARP)")
		case 2:
			write_part(writer, ": no echo came back")
		case 3:
			write_part(writer, ": the device did not answer")
		}
	case .Unsupported:
		write_part(writer, "the receiver does not do the command ")
		write_part(writer, record.value)
	case .Seed_Too_Weak:
		write_part(writer, "the random seed of this program has the strength ")
		write_part(writer, seed_strength_name(record.value))
		write_part(writer, ", and the call asks for ")
		write_part(writer, seed_strength_name(record.limit))
		write_part(writer, " at least: it made nothing")
	case .Exists:
		if record.found > 0 {
			write_part(writer, "row ")
			write_part(writer, record.found)
			write_part(writer, " of ")
		}
		subject(writer, record, argument)
		write_part(writer, ": the tree has an entry with this name already")
	case .Not_Authentic:
		subject(writer, record, argument)
		write_part(writer, " is not authentic: its tag or its signature does not verify, and the call gives no byte of it")
	case .Reserved:
		subject(writer, record, argument)
		write_part(writer, " names a program of the system: it starts at boot, or it is a device service, and the call does not act on it")
	case .Link_Down:
		write_part(writer, "the link of the network device is down")
	case .Busy:
		if record.value != 0 {
			write_part(writer, record.value)
			write_part(writer, " requests of this kind are in flight; the receiver takes at most ")
		} else {
			write_part(writer, "too many requests of this kind are in flight; the receiver takes at most ")
		}
		write_part(writer, record.limit)
	case .Out_Of_Range:
		if record.found > 0 {
			write_part(writer, "record ")
			write_part(writer, record.found)
			write_part(writer, " of ")
		}
		subject(writer, record, argument)
		write_part(writer, " reaches ")
		amount(writer, record.value, unit)
		write_part(writer, ", past the end: there are ")
		amount(writer, record.limit, unit)
	case .Not_Payer:
		handle(writer, record, argument)
		write_part(writer, " is not the budget that pays for the memory object; the call needs the budget of the object, with the right Commit or Spend")
	case .Object_Shared:
		if record.value != 0 {
			handle(writer, record, argument)
		} else {
			subject(writer, record, argument)
		}
		write_part(writer, " names a memory object that another program or another mapping also names; the call needs an object that only this program names, with one mapping at most")
	case .Object_Marked:
		handle(writer, record, argument)
		write_part(writer, " names a memory object with ")
		write_part(writer, record.found)
		write_part(writer, " pages with a protection of their own: it is not mapped again and not given until they have the protection of their mapping")
	case .Not_Multiple:
		subject(writer, record, argument)
		write_part(writer, " has the value ")
		write_part(writer, record.value)
		write_part(writer, ", which is not a multiple of ")
		write_part(writer, record.limit)
		if record.unit != 0 {
			write_part(writer, " ")
			write_part(writer, unit)
		}
	case .Whole_Only:
		subject(writer, record, argument)
		write_part(writer, ", ")
		write_number(writer, u64(record.value))
		write_part(writer, " with ")
		write_part(writer, record.limit)
		write_part(writer, " bytes, is a part of a mapping whose protection changes only whole (device memory, large pages), or of a thread area")
	case .Refused:
		write_part(writer, "refused with the status ")
		write_part(writer, record.found)
		write_part(writer, ", and no more detail")
	}
}

// address_text writes an IPv4 address: "10.0.2.2".
@(private = "file")
address_text :: proc "contextless" (writer: ^Writer, address: u32) {
	for shift := 24; shift >= 0; shift -= 8 {
		write_part(writer, u64(address >> uint(shift) & 0xFF))
		if shift != 0 {
			write_part(writer, ".")
		}
	}
}

// endpoint_text writes a remote (errors.Unit.Endpoint): "10.0.2.2 port 9",
// or "10.0.2.3" when the port is 0 (an echo names no port).
@(private = "file")
endpoint_text :: proc "contextless" (writer: ^Writer, value: i64) {
	address, port := errors.endpoint_unpack(value)
	address_text(writer, address)
	if port != 0 {
		write_part(writer, " port ")
		write_part(writer, u64(port))
	}
}

// ring_error_text writes the sentence of the error record of a completion
// of a ring (errors.completion_record).
//   contract: the name of the contract of the ring ("block", "datagram").
//   command:  the name of the command; argument: the name of its value.
ring_error_text :: proc "contextless" (writer: ^Writer, record: ^errors.Error_Record, contract: string, command: string, argument: string) {
	buffer: [64]u8
	error_text(writer, record, format(buffer[:], contract, ".", command), argument)
}

// wrapper_error_text writes the sentence of the error record of a wrapper
// of a library (display.open, terminal.open): the record of the kernel
// operation that failed in it (its operation is not 0), or the record that
// the wrapper wrote (operation 0).
//   name:      the name of the wrapper ("display.open").
//   arguments: the names of its arguments, from the argument 1.
wrapper_error_text :: proc "contextless" (writer: ^Writer, record: ^errors.Error_Record, name: string, arguments: []string) {
	if record.operation != 0 {
		write_part(writer, name)
		write_part(writer, ": ")
		kernel_error_text(writer, record)
		return
	}
	argument := record.argument >= 1 && record.argument <= i64(len(arguments)) ? arguments[record.argument - 1] : ""
	error_text(writer, record, name, argument)
}

// kernel_error_text writes the sentence of the error record of a kernel
// operation: the names come from the operation table.
kernel_error_text :: proc "contextless" (writer: ^Writer, record: ^errors.Error_Record) {
	name := "an unknown operation"
	argument := ""
	if record.operation > 0 && record.operation <= i64(max(op.Operation)) {
		form := &op.OPERATIONS[op.Operation(record.operation)]
		name = form.name
		if record.argument >= 1 && record.argument <= len(form.parameters) {
			argument = form.parameters[record.argument - 1].name
		}
	}
	if errors.Kind(record.kind) == .Refused && record.found >= 0 && record.found <= i64(max(op.Status)) {
		write_part(writer, name)
		write_part(writer, ": refused with the status ")
		write_part(writer, op.STATUS_NAMES[op.Status(record.found)])
		write_part(writer, ", and no more detail")
		return
	}
	error_text(writer, record, name, argument)
}

// The table of error details (docs/MODULE_CONTRACT.md, section 8, "The table
// of error details"): an error detail is an error record, so each sentence
// above writes it. A reader writes one line for each detail:
//
//   detail 2 of 3: monitor.counts_named: the argument names, row 3 of it, names nothing that exists
//
// error_detail_number_text writes the start of such a line. count is the
// count of the full answer.
error_detail_number_text :: proc "contextless" (writer: ^Writer, number: u64, count: u64) {
	write_part(writer, "detail ")
	write_part(writer, number)
	write_part(writer, " of ")
	write_part(writer, count)
	write_part(writer, ": ")
}

// export_error_detail_text writes the line of one error detail of an export,
// number from 1.
export_error_detail_text :: proc "contextless" (writer: ^Writer, file: []u8, export: u32, prefix: string, number: u64, count: u64, detail: ^errors.Error_Record) {
	error_detail_number_text(writer, number, count)
	export_error_text(writer, file, export, prefix, detail)
}

// error_details_rest_text writes the sentence of the error details that did
// not fit in the table of the caller: shown is the count that the caller
// read, count the count of the full answer. It writes nothing when each
// detail fit.
error_details_rest_text :: proc "contextless" (writer: ^Writer, shown: u64, count: u64) {
	if count <= shown {
		return
	}
	write_part(writer, count - shown)
	write_part(writer, count - shown == 1 ? " more error detail did not fit in the table of error details" : " more error details did not fit in the table of error details")
}

// export_error_text writes the sentence of the error record of an export:
// the names come from its description. prefix: the name of the service, or
// "" for a module in this program.
export_error_text :: proc "contextless" (writer: ^Writer, file: []u8, export: u32, prefix: string, record: ^errors.Error_Record) {
	function, described := module.function(file, export)
	buffer: [96]u8
	name := "an export"
	argument := ""
	if described {
		export_name := module.string_at(file, function.name_offset, function.name_count)
		name = prefix == "" ? format(buffer[:], export_name) : format(buffer[:], prefix, ".", export_name)
		if record.argument >= 1 && record.argument <= i64(function.parameter_count) {
			number := record.argument - 1
			argument = module.string_at(file, function.parameter_names[number], u32(function.parameter_name_counts[number]))
		}
	}
	error_text(writer, record, name, argument)
}

// seed_strength_name gives the name of a strength of a random seed
// (support/random, Seed_Strength), for a sentence.
@(private)
seed_strength_name :: proc "contextless" (strength: i64) -> string {
	switch strength {
	case 1:
		return "weak (the cycle counter only)"
	case 2:
		return "processor (rdrand)"
	case 3:
		return "entropy (rdseed)"
	}
	return "none"
}
