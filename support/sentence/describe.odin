package sentence

import module "contract:module"
import op "contract:operation"

// The text of a description: what a program shows to a person about the
// types of an export (module.Function).

@(rodata)
right_names := [op.Right]string {
	.Give    = "Give",
	.Read    = "Read",
	.Write   = "Write",
	.Execute = "Execute",
	.Control = "Control",
	.Inspect = "Inspect",
	.Devices = "Devices",
	.Stop    = "Stop",
	.Spend   = "Spend",
	.Physical = "Physical",
}

@(rodata)
object_names := [op.Object_Kind]string {
	.None      = "no object",
	.Memory    = "Memory",
	.Program   = "Program",
	.Interrupt = "Interrupt",
	.Ports     = "Ports",
	.Machine   = "Machine",
	.Thread    = "Thread",
	.Budget    = "Budget",
	.Log       = "Log",
}

// write_rights writes the names of rights, with a text between two names.
write_rights :: proc "contextless" (writer: ^Writer, rights: op.Rights, between: string) {
	first := true
	for right in op.Right {
		if right in rights {
			write_part(writer, first ? "" : between)
			write_part(writer, right_names[right])
			first = false
		}
	}
}

// write_type writes the type of a parameter, of a result or of a field:
// "Integer", "Text", "Text(32)" for a Text field of 32 bytes, the name of a
// record, "Table(Name)" for a table of records, or "Handle(Read, Write)"
// with the rights that the callee needs. file is the module of the
// description.
write_type :: proc "contextless" (writer: ^Writer, file: []u8, type: module.Type, detail: u32) {
	switch type {
	case .None:
	case .Integer:
		write_part(writer, "Integer")
	case .Text:
		write_part(writer, "Text")
		if detail != 0 {
			write_part(writer, "(")
			write_part(writer, u64(detail))
			write_part(writer, ")")
		}
	case .Table:
		write_part(writer, "Table(")
		write_type(writer, file, .Record, detail)
		write_part(writer, ")")
	case .Record:
		if described, ok := module.record_type(file, detail); ok {
			write_part(writer, module.string_at(file, described.name_offset, described.name_count))
		} else {
			write_part(writer, "Record")
		}
	case .Handle:
		write_part(writer, "Handle")
		if rights := transmute(op.Rights)detail; rights != {} {
			write_part(writer, "(")
			write_rights(writer, rights, ", ")
			write_part(writer, ")")
		}
	case:
		write_part(writer, "?")
	}
}
