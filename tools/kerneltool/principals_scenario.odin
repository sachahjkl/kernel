package kerneltool

// The machines of the principals (docs/PRINCIPALS.md): two machines with
// one data disk.
//
// The first one starts from a new disk, with no named principal: the
// machine runs as principal 0, `unlock` finds no file and stops. A note of
// `notes` that the console starts belongs to principal 0. The console
// creates the principal "alice"; its passphrase is typed two times in the
// window of `unlock`, and its session starts. `notes` started from the menu
// runs in the session: its store is another store, new, and its note stays
// there. The console connects to the storage service acting for principal
// 0, not for principal 1: it was started outside the session. The lock
// stops the programs of the session; a wrong passphrase opens nothing; the
// right one starts the session again, and `notes` finds the note of alice.
// A revocation still ends a grant of a program of the session.
//
// The second one starts on the same disk: `unlock` finds the file, the
// passphrase starts the session, and the note of alice is there again.

TEST_PRINCIPALS_DISK :: BUILD_FOLDER + "/test_principals_disk.img"
TEST_OUTPUT_PRINCIPALS :: BUILD_FOLDER + "/test_output_principals_%d.txt"

PRINCIPAL_PASSPHRASE :: "correct horse battery"

scenario_principals_first := [?]Step {
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	// The machine has no TPM: principal 0 has no measure.
	{kind = .Wait, text = "root: principal 0 is the machine: the system is not measured; its key, the attestation key of the TPM, is not built", any_order = true},
	{kind = .Wait, text = "unlock: no named principal: the machine runs as principal 0, with no unlock", any_order = true},
	{kind = .Wait, text = "root: unlock stopped with code 0"},
	{kind = .Type, text = "principals()"},
	{kind = .Wait, text = "[console]      0  machine  machine"},
	// A note of principal 0: the console starts notes in its own session.
	{kind = .Type, text = "start(\"notes\")"},
	{kind = .Wait, text = "root: started notes"},
	{kind = .Wait, text = "notes: a new store: no note, the count 0", any_order = true},
	{kind = .Wait, text = "compositor: surface notes"},
	{kind = .Front, text = "notes"},
	{kind = .Type, text = "of the machine"},
	{kind = .Wait, text = "notes: the note is \"of the machine\", generation "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "grants(\"notes\")"},
	{kind = .Wait, text = "[console] notes    log    held           0  machine"},
	{kind = .Type, text = "stop(\"notes\")"},
	{kind = .Wait, text = "root: notes stopped with code "},
	// The creation: the name in the console, the passphrase in the window
	// of unlock, never in the console, which keeps its lines.
	{kind = .Type, text = "principal_create(\"alice\")"},
	{kind = .Wait, text = "root: started unlock"},
	{kind = .Wait, text = "compositor: surface unlock"},
	{kind = .Front, text = "unlock"},
	{kind = .Type, text = PRINCIPAL_PASSPHRASE},
	{kind = .Type, text = PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = "root: principal 1 \"alice\" is recorded, its public key ", any_order = true},
	{kind = .Wait, text = "unlock: principal 1 \"alice\" is created: its keys are sealed in the store of unlock under a key of Argon2id, 19456 KiB and 2 passes, derived in ", any_order = true},
	{kind = .Wait, text = "root: the session of principal 1 \"alice\" starts: the desktop starts each program in it"},
	{kind = .Wait, text = "root: unlock stopped with code 0"},
	// notes from the menu: in the session, with a store of its own.
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "root: started notes, in the session of principal 1 \"alice\""},
	{kind = .Wait, text = "notes: a new store: no note, the count 0", any_order = true},
	{kind = .Wait, text = "compositor: surface notes"},
	{kind = .Type, text = "of alice"},
	// The generation of the last commit of the note: the current version.
	{kind = .Generation, text = "notes: the note is \"of alice\", generation "},
	// A count too: notes takes a store with a note and no count for a
	// damaged one ("the 3 blocks of the count do not agree") at its next
	// start, after the lock.
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "notes: count 1000, stopped: 1000 commits in "},
	// The grant records name the principal.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "grants(\"notes\")"},
	{kind = .Wait, text = "[console] notes    log    held           1  alice"},
	{kind = .Wait, text = "[console] notes    store  held           1  alice"},
	{kind = .Type, text = "grants(\"console\")"},
	{kind = .Wait, text = "  held           0  machine"},
	// The console was started outside the session: it acts for principal
	// 0, never for principal 1.
	{kind = .Type, text = "connect(\"storage\")"},
	{kind = .Wait, text = "root: connected console to the service storage, acting for principal 0"},
	// A caller that acts for principal N sees and opens the stores of
	// principal N only (docs/PRINCIPALS.md, "The store of a principal"):
	// the console acts for principal 0, so the store of notes of alice is
	// neither listed nor opened.
	{kind = .Type, text = "storage.open_store(\"notes.principal.1\")"},
	{kind = .Wait, text = "[console] error: storage.open_store: the caller has no grant for this: to act for the principal (-10)"},
	{kind = .Type, text = "storage.stores()"},
	{kind = .Wait, text = "[console] console.history: ", any_order = true},
	// The lines of stores() all come before the answer of the next line: a
	// line of the store of alice there would end the wait as a failure.
	{kind = .Type, text = "principals()"},
	{kind = .Wait, text = "[console]      1  alice    unlocked  ", fails_on = "[console] notes.principal.1: "},
	// The lock: the programs of the session stop, and unlock asks again.
	{kind = .Type, text = "lock()"},
	{kind = .Wait, text = "root: the session of principal 1 \"alice\" ends: 1 programs stopped"},
	{kind = .Wait, text = "root: notes stopped with code ", any_order = true},
	{kind = .Wait, text = "unlock: principal 1 \"alice\" is locked: its passphrase opens its session", any_order = true},
	{kind = .Wait, text = "[console] 1", any_order = true},
	{kind = .Wait, text = "compositor: surface unlock"},
	// A wrong passphrase opens nothing.
	{kind = .Front, text = "unlock"},
	{kind = .Type, text = "wrong passphrase"},
	{kind = .Wait, text = "unlock: the passphrase of principal 1 \"alice\" is wrong: the seal does not open, nothing is unlocked (1 in all)"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "principals()"},
	{kind = .Wait, text = "[console]      1  alice    locked   "},
	// The right one: the dots in the window, then Enter.
	{kind = .Front, text = "unlock"},
	{kind = .Keys, text = PRINCIPAL_PASSPHRASE},
	{kind = .Shot, text = "principals_unlock"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "unlock: the passphrase of principal 1 \"alice\" opens its seal; the secret keys are erased: nothing uses them yet"},
	{kind = .Wait, text = "root: the session of principal 1 \"alice\" starts: the desktop starts each program in it"},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "notes: restored the note \"of alice\" and the count 1000, its 3 blocks agree", any_order = true},
	{kind = .Wait, text = "compositor: surface notes"},
	// A revocation ends a grant of a program of the session.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "revoke(\"notes\", \"store\")"},
	{kind = .Wait, text = "root: revoked the grant store of notes, connections changed: 1"},
	{kind = .Type, text = "grants(\"notes\")"},
	{kind = .Wait, text = "[console] notes    store  lost           1  alice"},
	// The session runs: no window of unlock opens after the console came
	// to the front, so the last line goes to the console.
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

scenario_principals_second := [?]Step {
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "root: principal 1 \"alice\" is recorded, its public key ", any_order = true},
	{kind = .Wait, text = "unlock: principal 1 \"alice\" is locked: its passphrase opens its session", any_order = true},
	{kind = .Wait, text = "compositor: surface unlock"},
	{kind = .Front, text = "unlock"},
	{kind = .Type, text = PRINCIPAL_PASSPHRASE},
	{kind = .Wait, text = "root: the session of principal 1 \"alice\" starts: the desktop starts each program in it"},
	{kind = .Launch, text = "notes"},
	{kind = .Wait, text = "root: started notes, in the session of principal 1 \"alice\""},
	{kind = .Wait, text = "notes: restored the note \"of alice\" and the count 1000, its 3 blocks agree", any_order = true},
	{kind = .Wait, text = "compositor: surface notes"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "lock()"},
	{kind = .Wait, text = "root: the session of principal 1 \"alice\" ends: 1 programs stopped"},
	// The lock starts unlock again, and its window takes the front: the
	// console comes back to the front after that window, so the last line
	// goes to the console and not to unlock as a passphrase.
	{kind = .Wait, text = "compositor: surface unlock"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

principals_tests_run :: proc() -> bool {
	disk_prepare(TEST_PRINCIPALS_DISK, DATA_DISK_SIZE, true) or_return
	machine_test(scenario_principals_first[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_PRINCIPALS, 1), MACHINE_STOP_OK, TEST_PRINCIPALS_DISK) or_return
	return machine_test(scenario_principals_second[:], BOOT_VOLUME, self_test_file(TEST_OUTPUT_PRINCIPALS, 2), MACHINE_STOP_OK, TEST_PRINCIPALS_DISK)
}
