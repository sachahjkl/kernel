package root

import "contract:system_description"
import "support:principals"
import "support:system"

// The principals in the root service (docs/PRINCIPALS.md).
//
// The kernel knows no principal: a program acts with the handles that it
// holds. This service holds one record for each principal, and records for
// each program that it starts the principal whose session the program
// belongs to. It names that principal in each connection (the grant of the
// Connect command), in the name of the store of the program, and in the
// grants of the program.
//
// Principal 0 is the machine: its record exists at each boot, from the
// trust record of the boot program, and its session needs no unlock. With
// no named principal the system runs as principal 0 only.
//
// One named principal: the program `unlock` keeps its record in its own
// store, with its secret keys sealed under a key that Argon2id derives from
// its passphrase. `unlock` gives this service the public part of the record
// (Principal_Record), and tells it when the passphrase opened the seal
// (Principal_Unlock). This service trusts `unlock` for both, as the one
// holder of the grant Principals, as it trusts `settings` as the one writer
// of the settings page. The seal by the TPM is not built.

Principal_Record :: struct {
	state:       system.Principal_State,
	name:        [principals.NAME_LIMIT]u8,
	name_length: int,
	public_key:  [32]u8, // Ed25519: the key that signs the grants of the principal. Principal 0: none in this system yet.
	measured:    bool, // Principal 0: the boot program measured the system into PCR 11.
	measure:     [32]u8, // Principal 0: the value of PCR 11.
}

principal_records: [principals.PRINCIPAL_CAPACITY]Principal_Record

// What start() gives to the next start of `unlock`: to create the principal
// with this name, or to unlock the principal of its file.
unlock_create: bool
unlock_name: [principals.NAME_LIMIT]u8
unlock_name_length: int

principal_name :: proc "contextless" (number: u64) -> string {
	if number >= principals.PRINCIPAL_CAPACITY {
		return ""
	}
	record := &principal_records[number]
	return string(record.name[:record.name_length])
}

// desktop_principal gives the principal of a program that the desktop
// starts (the menu, the launcher): the named principal whose session runs,
// else the machine.
desktop_principal :: proc "contextless" () -> u64 {
	for &record, number in principal_records {
		if number != principals.MACHINE && record.state == .Unlocked {
			return u64(number)
		}
	}
	return principals.MACHINE
}

// principals_start makes the record of principal 0 from the trust record
// that the boot program wrote (trust.odin read it).
principals_start :: proc "contextless" () {
	machine_record := &principal_records[principals.MACHINE]
	machine_record^ = {state = .Machine, name_length = len(principals.MACHINE_NAME)}
	copy(machine_record.name[:], principals.MACHINE_NAME)
	trust := &trust_boot_report.trust
	if trust.measure == .Measured {
		machine_record.measured = true
		machine_record.measure = trust.measure_value
		digits := system_description.hexadecimal(trust.measure_value)
		system.log("root: principal 0 is the machine: the system is measured, PCR ", trust.measure_register, " = ", string(digits[:]), "; its key, the attestation key of the TPM, is not built")
	} else {
		system.log("root: principal 0 is the machine: the system is not measured; its key, the attestation key of the TPM, is not built")
	}
}

// unlock_start starts `unlock`: at boot to read its file (with no file it
// stops at once, and the machine runs as principal 0 only), after a lock,
// or to create a principal.
unlock_start :: proc "contextless" (create: bool, name: string) -> system.Status {
	unlock_create = create
	unlock_name_length = copy(unlock_name[:], name)
	status := start("unlock")
	unlock_create = false
	unlock_name_length = 0
	unlock_name = {}
	if status != .Ok {
		system.log_in("programs", .Warning, "root: unlock did not start (status ", u64(status), "): no named principal can be created or unlocked")
	}
	return status
}

// principal_create starts `unlock` to create a named principal.
principal_create :: proc "contextless" (name: string) -> system.Status {
	if principals.name_problem(name) != .None {
		return .Bad_Operation
	}
	if principal_records[1].state != .Absent || find("unlock") != nil {
		return .Bad_State
	}
	system.log_in("programs", .Info, "root: the principal \"", name, "\" is created in the window of unlock")
	status := unlock_start(true, name)
	unlock_creating = status == .Ok
	return status
}

// principal_record takes the public part of the record of a named
// principal from `unlock`: values[0..3] its public key, values[4..6] its
// name. The values are a copy in this service: `unlock` cannot change them.
principal_record :: proc "contextless" (values: [7]u64, completion: ^[7]u64) -> system.Status {
	public_key := transmute([32]u8)([4]u64{values[0], values[1], values[2], values[3]})
	name, name_length := principals.name_unpack({values[4], values[5], values[6]})
	if principals.name_problem(string(name[:name_length])) != .None {
		return .Bad_Operation
	}
	record := &principal_records[1]
	if record.state != .Absent {
		// The same record again (a second start of `unlock`) has the same
		// number; another one has no place.
		if record.public_key != public_key || string(record.name[:record.name_length]) != string(name[:name_length]) {
			return .No_Slot
		}
		completion^[0] = 1
		return .Ok
	}
	record^ = {state = .Locked, name = name, name_length = name_length, public_key = public_key}
	unlock_creating = false
	completion^[0] = 1
	digits := system_description.hexadecimal(public_key)
	system.log_in("programs", .Info, "root: principal 1 \"", principal_name(1), "\" is recorded, its public key ", string(digits[:16]), "...; its session is locked")
	return .Ok
}

// principal_unlock starts the session of a named principal: from now on the
// desktop starts each program in it.
principal_unlock :: proc "contextless" (number: u64) -> system.Status {
	if number == principals.MACHINE || number >= principals.PRINCIPAL_CAPACITY || principal_records[number].state == .Absent {
		return .Bad_Handle
	}
	if principal_records[number].state != .Locked {
		return .Bad_State
	}
	principal_records[number].state = .Unlocked
	system.log_in("programs", .Info, "root: the session of principal ", number, " \"", principal_name(number), "\" starts: the desktop starts each program in it")
	return .Ok
}

// principal_lock ends the session that runs: each program of the session
// stops (a frozen program needs a kernel operation that does not exist),
// and `unlock` starts again. completion[0] is the count of the programs
// stopped.
principal_lock :: proc "contextless" (completion: ^[7]u64) -> system.Status {
	number := desktop_principal()
	if number == principals.MACHINE {
		return .Bad_State
	}
	count: u64
	for &item in started {
		if item.program != 0 && item.principal == number {
			system.call(.Program_Stop, u64(item.program), 0)
			if !item.is_terminal {
				count += 1
			}
		}
	}
	principal_records[number].state = .Locked
	completion^[0] = count
	system.log_in("programs", .Info, "root: the session of principal ", number, " \"", principal_name(number), "\" ends: ", count, " programs stopped")
	unlock_start(false, "")
	return .Ok
}

// principal_read gives a record: values[0] its state, values[1..4] its
// name, values[5] the first 8 bytes of its public key, values[6] for
// principal 0 the first 8 bytes of the measure of the system (0: not
// measured).
principal_read :: proc "contextless" (number: u64, completion: ^[7]u64) -> system.Status {
	if number >= principals.PRINCIPAL_CAPACITY {
		return .Bad_Handle
	}
	record := &principal_records[number]
	state := record.state
	if state == .Absent && number != principals.MACHINE && find("unlock") != nil && unlock_creating {
		state = .Creating
	}
	if state == .Absent {
		return .Bad_Handle
	}
	packed := system.name_pack(string(record.name[:record.name_length]))
	key := transmute([4]u64)record.public_key
	measure := transmute([4]u64)record.measure
	completion^ = {u64(state), packed[0], packed[1], packed[2], packed[3], key[0], record.measured ? measure[0] : 0}
	return .Ok
}

// Set while `unlock` runs to create a principal: a reader of the records
// sees the state Creating.
unlock_creating: bool
