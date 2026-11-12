# The demonstration of each property

This document gives, for each of the 21 properties of `PROPERTIES.md`, what the machine test shows, the picture, and what no test shows. A row changes when the system changes what the test shows.

## How to read a state

- **Shown**: the machine test does the thing for real and checks the result. A picture exists.
- **Shown in part**: the test shows the core of the property. A named part has no test.
- **Not shown**: the system does not have the thing, or no test runs it.

## The table

| # | Property | State | What the test shows | Picture | What no test shows |
|---|---|---|---|---|---|
| 1 | Small kernel with a small, counted interface | Shown | The kernel has 33 operations: the first target of property 1 was 32, and the control of a thread added one. An unknown operation gives an error record that says so. `rights` asks for nine operations and reads each answer | `rights`, `errors` | No check counts the operations against a number in a document: a new operation fails no test |
| 2 | Sandbox by default | Shown | `probe` in a call host asks for the machine with three handle numbers: the kernel refuses each one. `rights`: five refusals with `No_Right`. `fault` stops alone | `isolated`, `rights` | A program that tries each of the 27 operations with no grant |
| 3 | No "everything is a file" | Shown in part | Each resource has its own handle kind: a handle of another kind is refused with the kind that the call needs | `errors` | The property is an absence. No test can show that no file interface exists |
| 4 | Non-blocking command buffers | Shown | `rings`: six programs pass records through six rings. `flow`: the records of one second and the kernel entries for one million records | `rings`, `flow` | A full ring under a writer that never waits |
| 5 | Kernel off the data path | Shown in part | `flow` and `clock`: 0 kernel entries for one million reads of the time page. `net`: 0.22 kernel entries for each datagram | `flow`, `clock`, `network` | The network service copies each UDP datagram and each TCP segment (the note of the property; `docs/NETWORK.md`) |
| 6 | One communication mechanism: shared memory | Shown | Every service call of the test is a ring and a call region: `connect("paint")`, `tally`, `manual`, `storage`, `monitor`, `remote` | `services`, `remote` | — |
| 7 | No drivers in the kernel | Shown | The block service, the frame service and the input service are programs. `disk` measures the block service; `net` the frame service | `disk`, `network` | Fixed hardware only: virtio under QEMU. No real machine, no IOMMU |
| 8 | No global, mutable, shared file system | Shown in part | `storage.size("note")` from `remote` is refused: the caller has no grant for a private store | `storage` | An absence, as property 3 |
| 9 | One private store per program | Shown | Eight machines with one data disk: `notes` keeps its text across restarts, a damaged block is found, a crash loses nothing that was flushed. A store limit is an error record | `notes`, `notes_crash`, `notes_damaged`, `storage` | Versions for all programs. A device that drops the writes after the last flush |
| 10 | One code module | Shown | `tally` is one module in three roles: a program, a service, a library in the console. `load("math")` then a direct call. `sample` is a library, a call host and a service with one description; the interface package as a module gives the same draw table as the package compiled in | `roles`, `modules`, `tables`, `interface_module` | — |
| 11 | Reproducible system, identity by hash | Shown | Each full check builds two times and compares each module, its LLVM IR and its object, and the boot program. `kerneltool repeat all 100`: 1 distinct result for each output of 61 modules and of the boot program, under a host load of 9.5 to 62. A replacement of an import by its hash. `remote` refuses a call that names another module hash | `replacement`, `imports` | Proved for one compiler (Odin `dev-2026-05` with the patch of the flake) on one host. The rare differing builds came from a second thread of the stock compiler |
| 12 | Module metadata in flat tables | Shown | `manual`: 45 modules and 65 exports listed, who imports `calendar`, the console combines the tables. `kerneltool call <key> "manual.modules()"`: 53 rows on one QUIC stream | `module_information`, `manual` | — |
| 13 | Data-oriented kernel internals | Shown in part | `locks`: the counts of each lock kind, one run queue for each processor. `scheduler`: one pick reads the first 64 bytes of each thread record, 43 to 86 ns | `locks`, `scheduler` | No test measures cache misses. The claim "one line for each thread in a pick" is by the layout assertion, not by a counter of the processor |
| 14 | Memory is supplied by the caller | Shown in part | `budget`: memory objects until `No_Budget`, then all pages back. The call region of an isolated call is memory of the caller | `budget`, `limits` | The libraries (`support/*`) are not checked for an allocation; the rule holds by reading |
| 15 | Isolation inside a program | Shown | `isolate("probe")`: the module runs in a call host; `peek(0)` stops the host and the console continues, with the stack trace; Escape ends a call that never returns | `isolated` | — |
| 16 | Removed concepts | Shown in part | No standard input or output: `flood` writes to a terminal that the root service gave it. No global last error: an error is a record in the answer | `terminal`, `errors` | An absence for the rest of the list (signals, fork, environment) |
| 17 | Trusted boot | Shown in part | The boot program verifies the description signature and the hash of the kernel and of each file of the boot image before the kernel starts; the root service checks the boot image again. One byte of `console` changed, or one bit of the signature changed: the boot stops with the file and both hashes on the boot display, and the kernel does not start. A changed kernel, a boot image with no description and a stated hash that differs are refused too. With a software TPM, PCR 11 holds the value that the tool computes from the system description, and another system gives another value. With Secure Boot on, the signed boot program starts and says that the firmware verified it; a signed boot program with one byte changed, and an unsigned one, never start (`test trusted_boot`; the two machines of the TPM run with `test trusted_boot tpm` only) | `boot_measured`, `boot_secure_boot`, `boot_fails_changed_module`, `boot_fails_changed_kernel`, `boot_fails_wrong_signature`, `boot_fails` | The test keys only: no real machine with the keys of a person. No sealed key, no remote attestation, no counter against an older signed system; PCR 4 and PCR 7 are read by nothing |
| 18 | One graphics interface: WebGPU with WGSL | Not shown | The compositor draws with the processor into shared surfaces; a full frame takes 1 to 3 ms | `desktop` | WebGPU and WGSL: not built. The graphics of today is the software path only |
| 19 | A command is a function | Shown | The console types and checks each call from the description of the module. The host calls an export and prints a typed table. The test reads log records as typed records (11 checks). A table goes into a call: in the console, from the host, and in three ways with the same answers | `console`, `records`, `remote`, `tables`, `table_argument`, `manual_tables` | Most checks of the scenario still read text lines of the serial log |
| 20 | No ambient access | Shown in part | A grant names one remote of the network. `revoke("remote", "acts_for_principal")` cuts the calls that act for the principal. A thread can only lower its weight. A budget record without the right Read says nothing of the budget | `revocation`, `network`, `rights` | **UDP has no authentication**: while `remote` runs, a program of the host that sends to the port of the peer acts for the principal |
| 21 | Principals | Shown in part | Layer 1: a caller acts for the principal of its session or not (`CALLER_ACTS_FOR_PRINCIPAL`), a grant of the root service that the console revokes. Layer 2: principal 0 is the machine, with the measure of the system. Layer 3: `principal_create("alice")` in the console, the passphrase typed two times in the window of `unlock` (dots); `notes` from the menu runs in the session of principal 1 and has a store of its own (`notes.principal.1`), apart from the store of `notes` of principal 0; the grants name the principal; the console acts for principal 0 only; `lock()` stops the programs of the session; a wrong passphrase opens nothing; the right one starts the session again, and the note is there after a restart of the machine (`test principals`) | `principals_unlock`, `revocation` | No seal by the TPM: the passphrase alone protects the keys, against tries on a copy of the disk. The stores of a principal are not encrypted. The storage service does not limit a caller that acts for principal 0 to the stores of principal 0: the console reads the note of principal 1, and the test shows it as a line of the log. No recovery of a lost passphrase. Several principals, identity across machines: not built |

## Counts

- Shown: 11 properties (1, 2, 4, 6, 7, 9, 10, 11, 12, 15, 19).
- Shown in part: 9 properties (3, 5, 8, 13, 14, 16, 17, 20, 21).
- Not shown: 1 property (18).

## What removes each "in part" and each "not shown"

1. Property 5: a device queue for each endpoint. TCP and QUIC are libraries in the program (`docs/NETWORK.md`, `docs/QUIC.md`).
2. Property 9: versions in the document service; a block device in the test that drops writes after the last flush.
3. Property 13: processor counters for a program (cache misses of a pick, of a ring pass).
4. Property 14: a check of the tool that a `support` package calls no allocator.
5. Property 17: a key sealed to the measure, and a counter in the TPM against an older signed system.
6. Property 18: a WebGPU service. It is the largest missing piece, and it is not planned.
7. Property 20: QUIC for `remote`.
8. Property 21: the research on identity across machines.
9. Properties 3, 8, 16 are absences. A test shows them only by a refusal of the nearest wrong use; each row names the one that exists.
10. Property 1: a check that compares the count of `op.Operation` with the number written in `PROPERTIES.md`.
