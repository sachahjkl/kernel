package system

import "base:intrinsics"
import module "contract:module"

// The roles of the context of a program that the root service starts.
// A handle that the program was not granted is 0.

// The handle 0: the display ring to the compositor, a memory object with
// **Read** and **Write**. A program with a window sends its commands there,
// and receives its input as completion records (`support/display`).
GRANT_DISPLAY :: 0 // Memory: the ring to the compositor.
// The handle 1: the root ring, a memory object with **Read** and **Write**,
// for a program with the grant Root_Ring, as the console.
// It sends `Root_Command` records on it: start, stop, connect, grants,
// revoke, replace, and the commands of the principals. The root service
// checks each command against the grants of the sender.
GRANT_ROOT :: 1 // Memory: the ring to the root service, to start and stop programs.
// The handle 2: the machine, with only the rights of the grants of the
// program: **Inspect** to read the reports of the programs and of the
// kernel, **Stop** to stop the machine, **Schedule** to change the
// scheduling strategy.
GRANT_MACHINE :: 2 // The machine, with the rights of the role: Inspect, or Inspect and Stop.
// The handle 3: the memory of the boot image, with **Read**, for a program
// with the grant Image: it lists the modules, loads them, and reads the
// descriptions of their exports. Its size is the value 0.
GRANT_IMAGE :: 3 // Memory: the boot image, to list the modules.
// The handle 4: the memory of the records of the log of the kernel, with
// **Read** only, for a program with the grant Log_Records: it reads the
// lines of every program, and writes none.
GRANT_LOG_RECORDS :: 4 // Memory, with Read: the records of the log.
// The handle 5: the service ring of a service, a memory object with
// **Read** and **Write**. The root service names each new connection of a
// caller on it, with the call ring and the call region of that caller
// (`support/system/service.odin`). The file of the service is at the
// value 1.
GRANT_SERVICE :: 5 // Memory: the service ring. The root service names each connection of a caller on it.
// The handle 10: the replacement table of the machine, with **Read**
// only, for a program that loads modules by itself: its loader reads the
// table before each load, so a replacement reaches the loads that follow.
GRANT_REPLACEMENTS :: 10 // Memory, with Read: the replacement table of the machine (Replacement_Table). 6 to 9 are the terminal and the store (packages terminal, storage).
// The value 0: the size in bytes of the boot image of the handle 3.
GRANT_VALUE_IMAGE_SIZE :: 0
// The value 1, for a service: the address where the root service mapped
// the file of the program, read-only. The service reads the descriptions
// of its exports there, to check each call; the value 2 is its size.
GRANT_VALUE_FILE_ADDRESS :: 1 // A service: where the file of the program is, read-only (the descriptions of its exports).
// The value 2, for a service: the size in bytes of its file at the address
// of the value 1.
GRANT_VALUE_FILE_SIZE :: 2

// The ring to the root service. The name of the program is in values[0..4].
// The completion record has the tag of the command, and a Status as kind.
// When the status is not Ok, its values are an error record
// (errors.completion_record): the argument 1 is the name.
//
// A program with the grant of the root ring (`GRANT_ROOT`) writes these
// commands; the root service checks the role of the program for each one.
//
// ```odin
// name := system.name_pack("clock")
// system.send(&root.commands, {kind = u32(system.Root_Command.Start), tag = 1, values = {name[0], name[1], name[2], name[3], 0, 0, 0}})
// ```
Root_Command :: enum u32 {
	None       = 0, // Refused.
	Start      = 1, // Start the program of the boot image with this name. A program of the system (root, input, compositor, terminal, block, frame) is refused with `Reserved`; a name with no module with `Absent`.
	Stop       = 2, // Stop the program with this name. The compositor and the terminal are refused with `Reserved`; a name that runs no program with `Absent`.
	// Connect makes a connection to a service that runs. The completion has
	// three handles of the caller: values[0] the program (right Read: its
	// state), values[1] the call ring, values[2] the call region. values[3..7]
	// is the hash of the file of the program: its exports are described there.
	Connect    = 3,
	Disconnect = 4, // End the connection to the service with this name.
	// Grants reads the grants of the program with this name. The completion
	// has two sets of Root_Grant (bit n: grant n): values[0] the grants that
	// the program has, values[1] the grants that were revoked. values[2] is
	// the number of the principal whose session the program belongs to (0:
	// the machine), and values[3..6] the name of that principal, 31 bytes at
	// most, zero bytes after it (docs/PRINCIPALS.md).
	Grants     = 5,
	// Revoke ends one grant of the program with this name: values[4] is the
	// Root_Grant. The kernel ends each handle and each mapping that came
	// from the grant, in that program and in the programs that it gave them
	// to. values[0] of the completion is their count.
	Revoke     = 6,
	// Replace sets the replacement of the module with this name, in the
	// replacement table of the machine: values[4] is the number, from 1, of
	// the entry of the boot image of the module that replaces it. 0 removes
	// the replacement. The root service refuses it to a program that does
	// not have the role, and refuses a chain: a module that replaces is not
	// replaced. The completion has Bad_State for a chain, No_Slot for a
	// full table.
	Replace    = 7,
	// Connect_History makes the connection of the caller to the store of
	// its line history in the storage service (docs/CONSOLE.md, section 6).
	// The name of the command is "storage". It is a second connection to
	// the storage service, apart from the private store of the caller: a
	// store of its own, named after the caller with ".history", with a
	// small limit of blocks and no grant to act for the principal, so it
	// reaches that store and no other one. The completion is the completion
	// of Connect. The root service refuses it to a program that does not
	// have the role, and after a revocation of the grant History.
	Connect_History = 8,
	// The commands of the principals (docs/PRINCIPALS.md). The root service
	// takes Principal_Create, Principal_Lock and Principals from a program
	// with the grant Root_Ring, and Principal_Record and Principal_Unlock
	// from the program `unlock` only.
	//
	// Principal_Create records a new named principal: the name is in
	// values[0..4]. The root service starts `unlock`, which asks for the
	// passphrase in its window, makes the keys and keeps them sealed in its
	// store. The completion comes at once: the creation ends in `unlock`.
	Principal_Create = 9,
	// Principal_Lock ends the session of the named principal that is
	// unlocked: each program of the session stops, and `unlock` starts
	// again. values[0] of the completion is the count of the programs
	// stopped.
	Principal_Lock = 10,
	// Principals reads the record of the principal with the number
	// values[4]: values[0] the state (Principal_State), values[1..4] its
	// name, zero bytes after it, values[5] the first 8 bytes of its public
	// key (0: none), values[6] for principal 0 the first 8 bytes of the
	// measure of the system in PCR 11 (0: not measured). A number with no
	// record is refused with Bad_Handle.
	Principals = 11,
	// Principal_Record gives the record of a named principal that `unlock`
	// keeps in its store: values[0..3] its public key (Ed25519, 32 bytes),
	// values[4..6] its name (1 to 23 bytes, zero bytes after it). The
	// completion has its number in values[0]: the same record gives the
	// same number, and a second record is refused with No_Slot.
	Principal_Record = 12,
	// Principal_Unlock starts the session of the principal with the number
	// values[4]: `unlock` opened its sealed keys with the passphrase.
	Principal_Unlock = 13,
}

// The state of a principal in the root service.
Principal_State :: enum u64 {
	Absent   = 0, // No record has this number.
	Machine  = 1, // Principal 0: always there; its session has no unlock.
	Locked   = 2, // A named principal with no session.
	Unlocked = 3, // A named principal whose session runs.
	Creating = 4, // `unlock` asks for the passphrase of a new principal; no record yet.
}

// The replacement table of the machine. The root service writes it, and
// gives it with the right Read. It gives the records to each program that
// it starts (system.program_start); a program that loads modules reads the
// table before each load. version is odd while the root service writes.
//
// A reader copies the table with `replacements_read`, which reads again
// while the version changes; `replacements_write` is for the root service.
// See [replacement table](term:replacement-table).
REPLACEMENT_CAPACITY :: 32 // The replacements of one machine. `Replace` gives No_Slot for one more.
Replacement_Table :: struct {
	version: u32, // Odd while the root service writes; one more at each start and each end of a write.
	count:   u32, // The records in use.
	records: [REPLACEMENT_CAPACITY]module.Replacement,
}
#assert(size_of(Replacement_Table) <= PAGE_SIZE)

// replacements_read copies the records of a replacement table that another
// program writes. It reads again while the table changes.
replacements_read :: proc "contextless" (table: ^Replacement_Table, records: ^[REPLACEMENT_CAPACITY]module.Replacement) -> []module.Replacement {
	if table == nil {
		return nil
	}
	for {
		version := intrinsics.atomic_load_explicit(&table.version, .Acquire)
		if version & 1 != 0 {
			continue
		}
		count := min(intrinsics.volatile_load(&table.count), REPLACEMENT_CAPACITY)
		intrinsics.mem_copy_non_overlapping(records, &table.records, size_of(table.records))
		intrinsics.atomic_thread_fence(.Acquire)
		if intrinsics.atomic_load_explicit(&table.version, .Relaxed) == version {
			return records[:count]
		}
	}
}

// replacements_write changes a replacement table: it sets the record of
// `from`, or removes it when `to` is zero. The one writer is the root
// service.
replacements_write :: proc "contextless" (table: ^Replacement_Table, from, to: [32]u8) -> Status {
	place := -1
	for index in 0 ..< int(table.count) {
		if table.records[index].from == from {
			place = index
		}
	}
	if to == {} && place < 0 {
		return .Bad_Handle
	}
	if to != {} && place < 0 && table.count == REPLACEMENT_CAPACITY {
		return .No_Slot
	}
	intrinsics.atomic_store_explicit(&table.version, table.version + 1, .Release)
	intrinsics.atomic_thread_fence(.Release)
	switch {
	case to == {}:
		table.records[place] = table.records[table.count - 1]
		table.records[table.count - 1] = {}
		table.count -= 1
	case place < 0:
		table.records[table.count] = {from = from, to = to}
		table.count += 1
	case:
		table.records[place].to = to
	}
	intrinsics.atomic_store_explicit(&table.version, table.version + 1, .Release)
	return .Ok
}

// The names of the commands of the root ring and of their values, for the
// sentence of the error record of a completion that failed: the value 1 is
// the name (values[0..4]), the value 2 is values[4].
@(rodata)
root_command_names := [Root_Command]string {
	.None       = "None",
	.Start      = "Start",
	.Stop       = "Stop",
	.Connect    = "Connect",
	.Disconnect = "Disconnect",
	.Grants     = "Grants",
	.Revoke     = "Revoke",
	.Replace    = "Replace",
	.Connect_History = "Connect_History",
	.Principal_Create = "Principal_Create",
	.Principal_Lock = "Principal_Lock",
	.Principals = "Principals",
	.Principal_Record = "Principal_Record",
	.Principal_Unlock = "Principal_Unlock",
}

// root_command_name gives the name of a command of the root ring, or "an
// unknown command" for a number out of `Root_Command`: the number comes from
// an error record.
root_command_name :: proc "contextless" (command: i64) -> string {
	return command >= 0 && command <= i64(max(Root_Command)) ? root_command_names[Root_Command(command)] : "an unknown command"
}

// root_argument_name gives the name of an argument of a command of the root
// ring, as an error record numbers it: 1 is the name, 2 is values[4]. An
// empty text: the command has no such argument.
root_argument_name :: proc "contextless" (command: i64, argument: i64) -> string {
	switch argument {
	case 1:
		return "name"
	case 2:
		#partial switch Root_Command(command) {
		case .Revoke:
			return "grant"
		case .Replace:
			return "by"
		case .Principals, .Principal_Unlock:
			return "number"
		}
	}
	return ""
}

// The grants that the root service records for each program, and that it
// can revoke while the program runs (the command `Revoke`). Each grant is a
// handle of the context, or a connection that the root service made; a
// revocation ends each handle and each mapping that came from it.
Root_Grant :: enum u32 {
	Log         = 0, // Write on the log.
	Machine     = 1, // The machine, with the rights of the role.
	Image       = 2, // Read the boot image.
	Log_Records = 3, // Read the records of the log.
	Store       = 4, // A private store in the storage service.
	Network     = 5, // An endpoint of datagrams in the network service, with one remote.
	Acts_For_Principal = 6, // To act for the principal of its session in each service that the program is connected to (isolated.CALLER_ACTS_FOR_PRINCIPAL).
	History     = 7, // The store of the line history of the console in the storage service (Root_Command.Connect_History).
}
// A set of grants: bit n is the grant n. The completion of `Grants` holds
// two of them.
Root_Grants :: bit_set[Root_Grant;u64]

// The name of each grant, as the console and the log write it.
root_grant_names := [Root_Grant]string {
	.Log         = "log",
	.Machine     = "machine",
	.Image       = "image",
	.Log_Records = "log_records",
	.Store       = "store",
	.Network     = "network",
	.Acts_For_Principal = "acts_for_principal",
	.History     = "history",
}

// A name of a program in a command of the root ring: 31 bytes at most, zero
// bytes after it.
Name :: [32]u8

// name_pack gives the four values of a name, as a command of the root ring
// carries it. A name longer than 31 bytes is cut.
name_pack :: proc "contextless" (name: string) -> (values: [4]u64) {
	bytes: Name
	copy(bytes[:len(bytes) - 1], name)
	return transmute([4]u64)bytes
}

// name_unpack gives the name of four values. Its last byte is always zero,
// whatever the values hold: a reader takes the bytes before the first zero.
name_unpack :: proc "contextless" (values: [4]u64) -> Name {
	bytes := transmute(Name)values
	bytes[len(bytes) - 1] = 0
	return bytes
}
