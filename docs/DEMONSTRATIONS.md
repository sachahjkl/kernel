# The demonstration of each property

This document gives, for each of the 21 properties of `PROPERTIES.md`, what the machine test shows today, the picture, and what no test shows yet. It is a map, not a second source: the evidence is the list "Evidence" of `FIRST_MILESTONE.md` (the numbers in brackets are its items), and the gaps are its section "Gaps".

Written on 2026-11-11, after step 47. A row changes when a step changes what the test shows.

## How to read a state

- **Shown**: the machine test does the thing for real and checks the result. A picture exists.
- **Shown in part**: the test shows the core of the property. A named part has no test.
- **Not shown**: the system does not have the thing, or no test runs it.

## The table

| # | Property | State | What the test shows | Picture | What no test shows |
|---|---|---|---|---|---|
| 1 | Small kernel with a small, counted interface | Shown | The kernel has 32 operations, the first target of property 1, and an unknown operation gives an error record that says so [34, case j]. `rights` asks for nine operations and reads each answer [18] | `rights`, `errors` | No check counts the operations against a number in a document: a new operation fails no test |
| 2 | Sandbox by default | Shown | `probe` in a call host asks for the machine with three handle numbers: the kernel refuses each one [10]. `rights`: five refusals with `No_Right` [18]. `fault` stops alone [5] | `isolated`, `rights` | A program that tries each of the 27 operations with no grant |
| 3 | No "everything is a file" | Shown in part | Each resource has its own handle kind: a handle of another kind is refused with the kind that the call needs [34, case d] | `errors` | The property is an absence. No test can show that no file interface exists |
| 4 | Non-blocking command buffers | Shown | `rings`: six programs pass records through six rings [15]. `flow`: the records of one second and the kernel entries for one million records [20] | `rings`, `flow` | A full ring under a writer that never waits |
| 5 | Kernel off the data path | Shown in part | `flow` and `clock`: 0 kernel entries for one million reads of the time page [28]. `net`: 0.22 kernel entries for each datagram [40] | `flow`, `clock`, `network` | The network service copies each UDP datagram (the dated note of the property). TCP as a library is on a branch |
| 6 | One communication mechanism: shared memory | Shown | Every service call of the test is a ring and a call region: `connect("paint")`, `tally`, `manual`, `storage`, `monitor`, `remote` [24, 29, 30, 33, 41] | `services`, `remote` | — |
| 7 | No drivers in the kernel | Shown | The block service, the frame service and the input service are programs. `disk` measures the block service [32]; `net` the frame service [40] | `disk`, `network` | Fixed hardware only: virtio under QEMU. No real machine, no IOMMU |
| 8 | No global, mutable, shared file system | Shown in part | `storage.size("note")` from `remote` is refused: the caller has no grant for a private store [41] | `storage` | An absence, as property 3 |
| 9 | One private store per program | Shown | Eight machines with one data disk: `notes` keeps its text across restarts, a damaged block is found, a crash loses nothing that was flushed [38]. A store limit is an error record [34, case q] | `notes`, `notes_crash`, `notes_damaged`, `storage` | Versions for all programs. A device that drops the writes after the last flush |
| 10 | One code module | Shown | `tally` is one module in three roles: a program, a service, a library in the console [29]. `load("math")` then a direct call [8]. `sample` is a library, a call host and a service with one description [48]; the interface package as a module gives the same draw table as the package compiled in [48] | `roles`, `modules`, `tables`, `interface_module` | — |
| 11 | Reproducible system, identity by hash | Shown | Each full check builds two times and compares each module, its LLVM IR and its object, and the boot program. `kerneltool repeat all 100`: 1 distinct result for each output of 61 modules and of the boot program, under a host load of 9.5 to 62 (400). A replacement of an import by its hash [31]. `remote` refuses a call that names another module hash [41] | `replacement`, `imports` | Proved for one compiler (Odin `dev-2026-05` with the patch of the flake) on one host. The rare differing builds came from a second thread of the stock compiler (400) |
| 12 | Module metadata in flat tables | Shown | `manual`: 45 modules and 65 exports listed, who imports `calendar`, the console combines the tables [31]. `kerneltool call "manual.modules()"`: 53 rows in 9 datagrams [41] | `module_information`, `manual` | — |
| 13 | Data-oriented kernel internals | Shown in part | `locks`: the counts of each lock kind, one run queue for each processor [21]. `scheduler`: one pick reads the first 64 bytes of each thread record, 43 to 86 ns [21] | `locks`, `scheduler` | No test measures cache misses. The claim "one line for each thread in a pick" is by the layout assertion, not by a counter of the processor |
| 14 | Memory is supplied by the caller | Shown in part | `budget`: memory objects until `No_Budget`, then all pages back [19]. The call region of an isolated call is memory of the caller [13] | `budget`, `limits` | The libraries (`support/*`) are not checked for an allocation; the rule holds by reading |
| 15 | Isolation inside a program | Shown | `isolate("probe")`: the module runs in a call host; `peek(0)` stops the host and the console continues, with the stack trace [10, 11]; Escape ends a call that never returns [12] | `isolated` | — |
| 16 | Removed concepts | Shown in part | No standard input or output: `flood` writes to a terminal that the root service gave it [26]. No global last error: an error is a record in the answer [34] | `terminal`, `errors` | An absence for the rest of the list (signals, fork, environment) |
| 17 | Trusted boot | Not shown | The boot program is a UEFI program and the boot display shows the seven stages [22] | `boot`, `boot_fails` | Secure Boot, TPM measures, signatures of the modules: not built |
| 18 | One graphics interface: WebGPU with WGSL | Not shown | The compositor draws with the processor into shared surfaces; a full frame takes 1 to 3 ms [step 45] | `desktop` | WebGPU and WGSL: not built. The graphics of today is the software path only |
| 19 | A command is a function | Shown | The console types and checks each call from the description of the module [8, 13]. The host calls an export and prints a typed table [41]. The test reads log records as typed records (11 checks) [42]. A table goes into a call: in the console, from the host, and in three ways with the same answers (2026-11-11) [48] | `console`, `records`, `remote`, `tables`, `table_argument`, `manual_tables` | Most checks of the scenario still read text lines of the serial log |
| 20 | No ambient access | Shown in part | A grant names one remote of the network [40]. `revoke("remote", "person")` cuts the calls that need the person [41]. A thread can only lower its weight [21]. A budget record without the right Read says nothing of the budget [34] | `revocation`, `network`, `rights` | **UDP has no authentication**: while `remote` runs, a program of the host that sends to the port of the peer acts for the person |
| 21 | Principals | Shown in part | Layer 1: a caller acts for the person or not (`CALLER_PERSON`), a line of the root service that the person revokes [41] | `revocation` | Layer 2 and the rest: named principals, identity across machines |

## Counts

- Shown: 11 properties (1, 2, 4, 6, 7, 9, 10, 11, 12, 15, 19).
- Shown in part: 8 properties (3, 5, 8, 13, 14, 16, 20, 21).
- Not shown: 2 properties (17, 18).

## What removes each "in part" and each "not shown"

1. Property 5: TCP as a library in the program (branch `work/tcp`), then a device queue for each endpoint.
2. Property 9: versions in the document service; a block device in the test that drops writes after the last flush.
3. Property 13: processor counters for a program (cache misses of a pick, of a ring pass).
4. Property 14: a check of the tool that a `support` package calls no allocator.
5. Property 17: signatures of the modules first (the hash exists), then the measures of the TPM, then Secure Boot.
6. Property 18: a WebGPU service. It is the largest missing piece, and no step is planned yet: it needs a decision of the owner on the order.
7. Property 20: QUIC for `remote`.
8. Property 21: the research on identity across machines (HANDOFF).
9. Properties 3, 8, 16 are absences. A test shows them only by a refusal of the nearest wrong use; each row names the one that exists.
10. Property 1: a check that compares the count of `op.Operation` with the number written in `PROPERTIES.md`.
