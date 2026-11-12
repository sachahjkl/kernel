# Principals

A principal is a key pair and the root handles that the key unlocks (`PROPERTIES.md`, property 21; `GLOSSARY.md`, "Principal"). The kernel has no concept of who executes: a program acts with the handles that it holds. The root service holds the records of the principals, and names the principal of each program that it starts. Storage holds the data of a principal.

This guide says what is built, how it works, and what is not built.

## 1. The layers, and what is built

| Layer | What it is | State |
|---|---|---|
| 1 | No principal: the root service is the only source of grants. A caller acts for the principal or not (`acts_for_principal`) | Built |
| 2 | Principal 0 is the machine: its record holds the measure of the system | Built in part: the record and the measure. Its key, the attestation key of the TPM, is not built |
| 3 | One named principal: a passphrase unlocks its session, and the lock ends it | Built in part: the record, the unlock, the session, the stores, the lock. Not built: the seal by the TPM, the encryption of its stores, recovery |
| 4 | Several named principals on one machine | Not built: design in section 9 |
| 5 | One principal on several machines; signed grants between principals | Not built: design in section 9 |

With no named principal, the system runs as principal 0 only, with no unlock: the behavior of layer 2.

## 2. Principal 0: the machine

The root service makes the record of principal 0 at each boot, before the first program starts, from the trust record of the boot program (`TRUSTED_BOOT.md`). The record holds:

- the name `machine`;
- the measure of the system: the value of PCR 11, when the boot program measured the system description into the TPM;
- no key. The key of principal 0 is the attestation key of the TPM. It is not built: the two test machines with a software TPM are opt-in, and their answers are not reliable.

The log says which: "root: principal 0 is the machine: the system is measured, PCR 11 = ..." or "root: principal 0 is the machine: the system is not measured; its key, the attestation key of the TPM, is not built".

The programs of the system belong to principal 0: the services, the console, and each program that the console starts. The stores of the system (the settings, the line history of the console) are stores of principal 0, and keep their names.

The key that signs the system description is the key of a principal like any other: the principal that signs the system. It is not principal 0, and it is not in the TPM.

## 3. A named principal

A named principal has the number 1. The root service holds two records: principal 0 and one named principal.

### The keys

| Key | Algorithm | Use |
|---|---|---|
| The signing key | Ed25519 | Signs the grants of the principal. No signed grant is built yet |
| The unlock key | X25519 | Unlocks the documents of the principal. No store is encrypted yet |

The program `unlock` makes the two secret keys from its random generator, which the root service seeded from the sources of the processor (`RANDOMNESS.md`). A seed weaker than the generator of the processor is refused, and no principal is made.

### The file of the principal

The program `unlock` keeps the record in its private store (a store of principal 0), as the object `principal`. Its format is in `support/principals`. Each number is little-endian.

| Offset | Bytes | Field |
|---|---|---|
| 0 | 8 | `PRINCIPL` |
| 8 | 4 | The format: 1 |
| 12 | 4 | The KiB of Argon2id: 19456 |
| 16 | 4 | The passes of Argon2id: 2 |
| 20 | 1 | The bytes of the name: 1 to 23 |
| 21 | 23 | The name: letters, digits, `-`, `_`, `.`; zero bytes after it |
| 44 | 32 | The public signing key |
| 76 | 32 | The public unlock key |
| 108 | 16 | The salt of Argon2id |
| 124 | 12 | The nonce of the seal |
| 136 | 80 | The two secret keys (64 bytes) sealed with ChaCha20-Poly1305, and the tag |

The additional data of the seal is each byte before the sealed keys. So a change of the name, of a public key, of the salt or of a parameter makes the open fail.

The file is data from the disk. `file_decode` copies it once and checks the copy: the size, the magic, the format, the name, and the zero bytes after it. A file with other parameters of Argon2id is refused: a file cannot ask for a cheaper derivation, or for more memory than the program has.

### The key derivation

The key of the seal is Argon2id (RFC 9106) of the passphrase and the salt: 19456 KiB (19 MiB) of blocks, 2 passes, 1 lane, a key of 32 bytes. These are the first parameters of the OWASP password storage cheat sheet. The code is the Argon2id of Odin's `core:crypto`, taken by the rule of the cryptography (`CRYPTOGRAPHY.md`), and the module `cryptography` exports it as `argon2id`. The caller supplies the blocks: `unlock` holds them in one memory object of 4864 pages.

A wrong passphrase gives another key, and the open of the seal fails with `Not_Authentic`. No passphrase and no hash of a passphrase is kept or compared.

**The strength.** With no seal by the TPM, the strength of the record is the strength of the passphrase against Argon2id with 19 MiB and 2 passes, for an attacker with a copy of the disk. A passphrase of 8 bytes is the least that `unlock` accepts; it is not a strong passphrase. The seal by the TPM, behind a PIN, limits the tries; it is not built.

### The passphrase

A passphrase has 8 to 128 bytes of the printable characters (32 to 126). It is typed in the window of `unlock` only, and shows as dots. It is never a text of the console: the console keeps each line in its history and in its store.

## 4. The unlock and the lock

The root service starts `unlock` at boot, after the boot pass of `settings`.

- With no file, `unlock` stops at once: "unlock: no named principal: the machine runs as principal 0, with no unlock".
- With a file, `unlock` gives the public part of the record to the root service (`Principal_Record`), opens its window, and asks for the passphrase.
- When the seal opens, `unlock` checks that the two secret keys give the two public keys of the file, erases them, tells the root service (`Principal_Unlock`), and stops. The root service starts the session.

**The keys are not kept after the unlock.** No part of the system uses the secret keys yet: no store is encrypted, and no grant is signed. A key that is held with no use is only a target. When storage encrypts the stores of a principal, the unlock gives the unlock key to the storage service, and the lock erases it there.

**The lock** (`lock()` in the console): the root service stops each program of the session and its terminals, marks the principal locked, and starts `unlock` again. The programs stop; they are not frozen: a frozen program needs a kernel operation that does not exist. A program that keeps its state in its store at each change (`notes`) loses nothing.

**The creation** (`principal_create("name")` in the console): the root service checks the name, and starts `unlock` with it. The passphrase is typed two times. `unlock` makes the keys, derives the key of the seal, seals the secret keys, writes the file, gives the record to the root service, and starts the session.

The root service trusts `unlock` for the record and for the unlock, as the one program with the grant `Principals`, as it trusts `settings` as the one writer of the settings page. No other program can send these two commands.

## 5. The session

The root service records, for each program that it starts, the principal whose session the program belongs to:

| Who asks for the start | The principal of the program |
|---|---|
| The root service itself (the services, the console, the boot passes) | 0, the machine |
| A service that starts on demand (`storage`, `sample`) | 0 |
| The desktop: the menu or the launcher of the compositor | The named principal that is unlocked, else 0 |
| A program, through its ring to the root service (`start("name")` in the console) | The principal of the program that asks |
| The terminal of a program | The principal of that program |

So a program that the console starts belongs to principal 0, and a program that the desktop starts during a session belongs to the named principal. The log says it: "root: started notes, in the session of principal 1 "alice"".

**The grant of a connection.** The root service gives each caller of a service a grant, in the Connect and Grant commands of the service ring (`contract/isolated`, values[6]):

| Bits | Field |
|---|---|
| 0 to 47 (`CALLER_AMOUNT_MASK`) | An amount: the limit of blocks of a store |
| 48 to 62 (`CALLER_PRINCIPAL_MASK`) | The number of the principal of the session of the caller |
| 63 (`CALLER_ACTS_FOR_PRINCIPAL`) | The caller acts for that principal |

A caller acts for the principal when its role has the grant `acts_for_principal` (the console, `remote`) and the grant was not revoked. It acts for the principal of its own session only. So the console, started at boot, acts for principal 0, never for principal 1: "root: connected console to the service storage, acting for principal 0".

**The grant records name the principal.** `grants("notes")` in the console gives the grants of a program, then "notes runs for principal 1 "alice"". `revoke` works on a program of a session as on any other program.

## 6. The store of a principal

The storage service names a store by the name that the root service gives to the connection. The root service builds that name in one procedure, `principals.store_name_write`, from the principal and the name of the program:

| Principal | Program | Store |
|---|---|---|
| 0 | `notes` | `notes` |
| 0 | `console`, its line history | `console.history` |
| 1 | `notes` | `notes.principal.1` |
| 1 | `console`, its line history | `console.history.principal.1` |

So two principals that run one program have two stores, and the stores of the system keep their names. A name that does not fit in 31 bytes is refused, never cut: a cut name can be the name of another store. The identity of the package of a program (the key of the principal that signs the package, and its name) enters in the same procedure when storage attaches data to it.

## 7. The commands

**The root ring** (`support/system`, `Root_Command`):

| Command | Who sends it | What it does |
|---|---|---|
| `Principal_Create` | A program with the grant `Root_Ring` | Starts `unlock` to create the principal with the name of values[0..4] |
| `Principal_Lock` | A program with the grant `Root_Ring` | Ends the session that runs; values[0] of the completion is the count of the programs stopped |
| `Principals` | A program with the grant `Root_Ring` | Reads the record of the principal values[4]: its state, its name, the first 8 bytes of its public key; for principal 0 the first 8 bytes of the measure |
| `Principal_Record` | `unlock` only | Gives the public key (values[0..3]) and the name (values[4..6]) of the named principal; the completion has its number |
| `Principal_Unlock` | `unlock` only | Starts the session of the principal values[4] |
| `Grants` | A program with the grant `Root_Ring` | Also gives the number (values[2]) and the name (values[3..6]) of the principal of the program |

A refusal is an error record with the unit `Principals`: a second named principal ("no free place: the table has its 1 named principals"), a lock with no session, a number with no record.

**The console:** `principal_create("name")`, `lock()`, `principals()`, and `grants("name")`.

## 8. The tests

- `odin test support/principals`: the names of the stores, a name that does not fit, the names and the passphrases, a round trip of the file, and ten hostile files.
- `odin test support/cryptography/vectors`: BLAKE2b of RFC 7693 and Argon2id of RFC 9106, section 5.3; the blocks are erased after the derivation, and a supply of blocks that is too small gives `Out_Of_Memory`.
- `kerneltool test principals`: two machines on one data disk. The first one: no named principal; a note of `notes` started by the console belongs to principal 0; the creation of `alice` in the window of `unlock`; `notes` from the menu has a new store, `notes.principal.1`; the grants name the principal; the console connects acting for principal 0, and still reads the note of principal 1 (the gap of section 9, as a line of the log); the lock stops `notes`; a wrong passphrase opens nothing; the right one starts the session again and `notes` finds the note and the count of alice; a revocation of the store of `notes`. The second machine, on the same disk: the passphrase starts the session, and the note of alice is there. Picture: `principals_unlock`.

## 9. Not built

- **The seal by the TPM.** The TPM seals the key of the principal to the measure of the system (PCR 11), behind a PIN. With it, a copy of the disk does not allow tries without limit.
- **The key of principal 0**: the attestation key of the TPM.
- **The encryption of the stores of a principal** with its unlock key. Today the data of a principal is on the disk in clear, as each store.
- **The limit of acting for a principal in storage.** The storage service checks only the flag `CALLER_ACTS_FOR_PRINCIPAL`, not the principal of the grant. So the console, which acts for principal 0, reads the stores of principal 1 through `stores()`, `versions()`, `version()` and the other exports that name a store. The rule that the storage service must apply, from bits 48 to 62 of the grant of each connection:
  - A caller that acts for principal N sees the stores of principal N only: `stores()` lists them, and an export that names another store is refused with `No_Grant`.
  - Principal 0 sees the stores of principal 0 only. It does not see the stores of a named principal: the machine is not an administrator.
  - A caller that does not act for a principal sees its own store only, as now.
  - The machine test shows the gap as a line of the log: in `kerneltool test principals`, the console calls `storage.version("notes.principal.1", "note", ...)` and the log has "[console] of alice". When the rule is built, that step waits for the refusal.
- **Recovery.** A lost passphrase is a lost principal: no administrator can reset it. Property 21 asks for recovery from the first version of layer 3: a second device or a printed recovery key. It is not built.
- **The desktop while locked.** The desktop stays: programs of principal 0 run and can be started. A desktop that shows only `unlock` while a named principal is locked is not built.
- **Several named principals (layer 4).** The design: one record for each principal in the root service; one file for each in the store of `unlock`; one session at a time on the desktop, or one desktop for each session. Each principal has disjoint stores by the name of the store, and disjoint grants by the principal of each program. No kernel change.
- **One principal on several machines (layer 5).** The design: the signing key of the principal signs the key of each machine (principal 0 of that machine, its attestation key); a grant to another principal is a record that names its public key and that the signing key signs, with a short lifetime or a revocation list; a store of the principal on another machine is opened with its unlock key, given to that machine through a grant.
