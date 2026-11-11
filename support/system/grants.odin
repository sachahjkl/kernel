package system

import "base:intrinsics"
import module "contract:module"

// The roles of the context of a program that the root service starts.
// A handle that the program was not granted is 0.
GRANT_DISPLAY :: 0 // Memory: the ring to the compositor.
GRANT_ROOT :: 1 // Memory: the ring to the root service, to start and stop programs.
GRANT_MACHINE :: 2 // The machine, with the rights of the role: Inspect, or Inspect and Stop.
GRANT_IMAGE :: 3 // Memory: the boot image, to list the modules.
GRANT_LOG_RECORDS :: 4 // Memory, with Read: the records of the log.
GRANT_SERVICE :: 5 // Memory: the service ring. The root service names each connection of a caller on it.
GRANT_REPLACEMENTS :: 10 // Memory, with Read: the replacement table of the machine (Replacement_Table). 6 to 9 are the terminal and the store (packages terminal, storage).
GRANT_VALUE_IMAGE_SIZE :: 0
GRANT_VALUE_FILE_ADDRESS :: 1 // A service: where the file of the program is, read-only (the descriptions of its exports).
GRANT_VALUE_FILE_SIZE :: 2

// The ring to the root service. The name of the program is in values[0..4].
// The completion record has the tag of the command, and a Status as kind.
Root_Command :: enum u32 {
	None       = 0,
	Start      = 1,
	Stop       = 2,
	// Connect makes a connection to a service that runs. The completion has
	// three handles of the caller: values[0] the program (right Read: its
	// state), values[1] the call ring, values[2] the call region. values[3..7]
	// is the hash of the file of the program: its exports are described there.
	Connect    = 3,
	Disconnect = 4, // End the connection to the service with this name.
	// Grants reads the grants of the program with this name. The completion
	// has two sets of Root_Grant (bit n: grant n): values[0] the grants that
	// the program has, values[1] the grants that were revoked.
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
}

// The replacement table of the machine. The root service writes it, and
// gives it with the right Read. It gives the records to each program that
// it starts (system.program_start); a program that loads modules reads the
// table before each load. version is odd while the root service writes.
REPLACEMENT_CAPACITY :: 32
Replacement_Table :: struct {
	version: u32,
	count:   u32,
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

// The grants that the root service records for each program, and that it
// can revoke while the program runs.
Root_Grant :: enum u32 {
	Log         = 0, // Write on the log.
	Machine     = 1, // The machine, with the rights of the role.
	Image       = 2, // Read the boot image.
	Log_Records = 3, // Read the records of the log.
	Store       = 4, // A private store in the storage service.
	Network     = 5, // An endpoint of datagrams in the network service, with one remote.
	Person      = 6, // To act for the person in each service that the program is connected to (isolated.CALLER_PERSON).
}
Root_Grants :: bit_set[Root_Grant;u64]

root_grant_names := [Root_Grant]string {
	.Log         = "log",
	.Machine     = "machine",
	.Image       = "image",
	.Log_Records = "log_records",
	.Store       = "store",
	.Network     = "network",
	.Person      = "person",
}

Name :: [32]u8

name_pack :: proc "contextless" (name: string) -> (values: [4]u64) {
	bytes: Name
	copy(bytes[:len(bytes) - 1], name)
	return transmute([4]u64)bytes
}

name_unpack :: proc "contextless" (values: [4]u64) -> Name {
	bytes := transmute(Name)values
	bytes[len(bytes) - 1] = 0
	return bytes
}
