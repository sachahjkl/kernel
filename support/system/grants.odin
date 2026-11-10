package system

// The roles of the context of a program that the root service starts.
// A handle that the program was not granted is 0.
GRANT_DISPLAY :: 0 // Memory: the ring to the compositor.
GRANT_ROOT :: 1 // Memory: the ring to the root service, to start and stop programs.
GRANT_MACHINE :: 2 // The machine, with the rights of the role: Inspect, or Inspect and Stop.
GRANT_IMAGE :: 3 // Memory: the boot image, to list the modules.
GRANT_LOG_RECORDS :: 4 // Memory, with Read: the records of the log.
GRANT_SERVICE :: 5 // Memory: the service ring. The root service names each connection of a caller on it.
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
}

// The grants that the root service records for each program, and that it
// can revoke while the program runs.
Root_Grant :: enum u32 {
	Log         = 0, // Write on the log.
	Machine     = 1, // The machine, with the rights of the role.
	Image       = 2, // Read the boot image.
	Log_Records = 3, // Read the records of the log.
}
Root_Grants :: bit_set[Root_Grant;u64]

root_grant_names := [Root_Grant]string {
	.Log         = "log",
	.Machine     = "machine",
	.Image       = "image",
	.Log_Records = "log_records",
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
