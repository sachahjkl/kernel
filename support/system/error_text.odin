package system

import "contract:errors"
import module "contract:module"
import op "contract:operation"

// The sentence of an error record (docs/MODULE_CONTRACT.md, section 8). The
// record holds values only: the names come from the operation table of the
// kernel, or from the description of the export. The record can come from
// another program: a value out of an enumeration is written as a number.

// write_number writes a number in hexadecimal with "0x", and no zero before
// the first digit.
write_number :: proc "contextless" (writer: ^Writer, value: u64) {
	digits := 1
	for digits < 16 && value >> uint(4 * digits) != 0 {
		digits += 1
	}
	write_part(writer, "0x")
	write_hex(writer, value, digits)
}

// rights_text writes a set of rights from a field of an error record.
@(private = "file")
rights_text :: proc "contextless" (writer: ^Writer, value: i64) {
	rights := transmute(Rights)u32(value)
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
		write_part(writer, " has the value ")
		write_part(writer, record.value)
		write_part(writer, ", which the call refuses")
		if record.limit != 0 {
			write_part(writer, "; it takes 1 to ")
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
		write_part(writer, ", names no handle of this program")
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
		handle(writer, record, argument)
		write_part(writer, " cannot pay ")
		amount(writer, record.limit, unit)
		write_part(writer, "; the handle has no right Read, so the budget is not described")
	case .Over_Limit:
		write_part(writer, "the call needs ")
		amount(writer, record.value, unit)
		write_part(writer, " in all; the limit is ")
		amount(writer, record.limit, unit)
	case .Full:
		write_part(writer, "no free place: the table has its ")
		amount(writer, record.limit, unit)
	case .State:
		handle(writer, record, argument)
		state := record.found >= 0 && record.found <= i64(max(op.Program_State)) ? op.STATE_NAMES[op.Program_State(record.found)] : "in an unknown state"
		write_part(writer, " names a program that is ")
		write_part(writer, state)
		if record.limit != 0 {
			write_part(writer, "; the call needs a program that is created, and not started")
		}
	case .Absent:
		subject(writer, record, argument)
		if errors.Unit(record.unit) == .Bytes {
			write_part(writer, ", ")
			write_number(writer, u64(record.value))
			write_part(writer, ", names nothing that the program has")
		} else if errors.Unit(record.unit) == .Objects {
			write_part(writer, ": the store has no object with this name")
		} else if record.unit != 0 {
			write_part(writer, " names none of the ")
			write_part(writer, unit)
		} else {
			write_part(writer, " names nothing that exists")
		}
	case .Damaged:
		if errors.Unit(record.unit) == .Stores {
			write_part(writer, "the table of the private store is damaged: a block of it has a wrong check")
		} else {
			write_part(writer, "the object of ")
			subject(writer, record, argument)
			write_part(writer, " is damaged: a block of it has a wrong check")
		}
	case .Device:
		write_part(writer, "the device reported an error")
	case .No_Grant:
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
		write_part(writer, ": the addresses from ")
		write_number(writer, u64(record.value))
		write_part(writer, ", ")
		amount(writer, record.limit, "bytes")
		write_part(writer, ", overlap what the program has")
	case .Unknown_Operation:
		write_part(writer, "the kernel has no operation ")
		write_part(writer, record.value)
	case .Refused:
		write_part(writer, "refused with the status ")
		write_part(writer, record.found)
		write_part(writer, ", and no more detail")
	}
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

// call_error gives the error record of a kernel operation that failed: the
// values of its completion record. Zero when the status is Ok.
call_error :: proc "contextless" (results: [7]u64, status: Status) -> errors.Error_Record {
	if status == .Ok {
		return {}
	}
	return transmute(errors.Error_Record)results
}

// frame_text writes one frame of a stack trace: "probe + 0x1a2", with the
// name of the module in the boot image, or the start of its hash. A frame
// that no module record holds is its address.
frame_text :: proc "contextless" (writer: ^Writer, image: []u8, frame: ^op.Stop_Frame) {
	if frame.base == 0 {
		write_number(writer, frame.address)
		return
	}
	if entry := image_entry_of(image, frame.hash); entry != nil {
		write_part(writer, name_of(entry.name[:]))
	} else {
		write_hash(writer, frame.hash)
	}
	write_part(writer, " + ")
	write_number(writer, frame.address - frame.base)
}
