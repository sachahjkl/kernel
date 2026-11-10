# Reviews

The owner asked for a review after each five steps (2026-11-10). A review compares the work with `PROPERTIES.md` and with the rule "no bad compromise". It lists each concession and what removes it.

A step is one tested commit that adds one capability.

| Step | Commit | Capability |
|---|---|---|
| 1 | `7305ad2` | Isolated call |
| 2 | `71ca9ec` | `rings`: communication between programs, shown |
| 3 | `ba67b95` | Text results |
| 4 | `e8cbcb5` | Threads: several per program, shown by `threads` |
| 5 | `44d2973` | The word wait and the lock, shown by `workers` |
| 6 | `887f23b` | One wait: rings wait on words, `Wake(memory)` deleted, the event word |
| 7 | `6d900bc` | The console runs a line in a second thread: keys during a call, Escape stops an isolated call |
| 8 | `ec91461` | Descriptions come from the source: parameter names, help from the comment, checked by the test |
| 9 | `07c1b00` | Rights on handles: `Handle_Give` takes a mask, `No_Right`, one Machine object with Inspect, Devices and Stop, shown by `rights` |
| 10 | `6b6346f` | Budgets and the Log handle: no operation creates an object from nothing, shown by `budget` |
| 11 | `61b8661` | Several processors: one kernel lock, a processor record, `processor_sync`, shown by `processors` |
| 12 | `f71ea23` | The boot display: a boot record with stages, drawn by the boot program, the root service and `boot`; a start that fails keeps the display |
| 13 | `06b7df7` | Paging on the kernel itself: guard pages, no page writable and executable, SMEP and SMAP with one `user_copy`, six self tests, shown by `pages`; owner decision "no standard input, no standard output" recorded |
| 14 | `89e315b` | The launcher is a menu: one button in the bar, one line for each program, the same table for the compositor and the test |
| 15 | `4e5cc8a` | The log is records in channels: the kernel is the one writer, readers map the records, shown by `log` |
| 16 | `bed545a` | A program that runs serves its own exports: connections made by the root service, the same description and the same call form as a module, shown by `paint` and `life` |
| 17 | `6bc4898` | A ring has a capacity chosen at creation; one wake for many records; `wait_spin`; measured by `flow` |
| 18 | `eef9227` | The terminal: typed records of text with a style, no escape sequence; a reader thread and a drawer; a surface with two pictures; the lost wake of step 17 removed; shown by `terminal` and `flood`, filmed by `kerneltool film` |
| 19 | `c538baa` | A shared queue: several writers and several readers with no lock; an event that several threads wait on; a wake for one thread that does not enter the kernel for each record; the scenario reads the place of each window; measured by `crowd` |
| 20 | `f3bdf49` | The time page: the kernel writes the time in one page that each program reads; `system.time()` does not enter the kernel; measured by `clock` |
| 21 | `1b92079` | One module in each role (`tally`: program, service, library, sandboxed program); a module carries its documentation; `manual` shows it; `unload` in the console |
| 22 | `48f1eee` | Two source libraries, `contract:` and `support:`; no relative import; the kernel compiles with the contract library only; the command `kerneltool` |
| 23 | `1898531` | The console has a terminal and no surface; key records from the terminal to its program; the edit line; the root service wires a program and its terminal; a terminal draws after a change only; the step kind `Close` |
| 24 | `4a28242` | Descriptions with records and handles: the tables Records and Fields; a Record goes as bytes; a Handle is lent with the rights of the description and ends with its call; the kernel operation `Handle_State` proves where a handle came from; Record and Handle values in the console; the module `sample` |

## Review 1: steps 1 to 5 (2026-11-10)

### What the five steps added

- A module can run in a sandboxed program, and the same description serves the direct call and the isolated call (P2, P19).
- An export can give text of any size with no allocator in the contract (P13, P19).
- A program can have several threads. Each thread has its own kernel ring (P4, architecture decision 6).
- A thread can wait on a word of memory, in one program or between two programs (P6, the open point is closed).
- Three programs show the concepts with the real state of the system: `rings`, `threads`, `workers`.
- The machine test has 3 new parts. Each step passed `nix flake check` before its commit.

### Against the properties

| Property | State after step 5 |
|---|---|
| P1 small counted interface | 21 kernel operations, one entry point. 5 were added in these steps: 3 for threads, 2 for the word wait |
| P2 sandbox by default | Holds. The call host has no handle. A thread adds no right: it has the handles of its program |
| P4 command buffers | Holds, and is now per thread |
| P6 one communication mechanism | **Not clean.** Two wake mechanisms exist: `Wake(memory)` and `Word_Wake`. See concession 1 |
| P13 ZII | Holds. A zero `Lock` is a free lock. A zero thread slot is a free slot |
| P19 command is a function | Not complete: descriptions are written by hand and not checked against the source |
| P20 no ambient access | Not complete: `Log`, `Memory_Create`, `Program_Create` and `Thread_Create` need no handle and have no limit |

### Concessions, and what removes each one

1. **Two wake mechanisms.** `Wake(memory)` wakes all the threads of all the programs that map a memory object. The word wait is exact. Remove: make each ring reader wait on the `write` counter of its queues with `Word_Wait` (4 words per wait; the compositor needs more, so the count must grow or the compositor must use one shared counter). Then delete `Wake`, the wake-pending flag and `maps_region`. This is the next step. **Removed in step 6**: one entry waits on 64 words; `Wake` and the wake-pending flag are deleted. `maps_region` stays for `Handle_Give` only.
2. **The `gs` register.** Rule 7 of the module contract said that code passes the thread record explicitly. The kernel ring per thread made this too costly: each call of `system` needs the ring. The amendment is narrow (one register, one word, no module data), but it is an amendment of a closed rule. The owner saw it before the code.
3. **A fault in a thread stops the program.** This is the decision, not a concession: the threads share all their memory.
4. **`Thread_Stop` on another thread is not safe for locks.** The thread can hold a lock. Remove: nothing in the kernel. The rule for programs is "ask the thread to end; stop it only when its data is lost anyway".
5. **The console waits during an isolated call.** Threads now permit the removal: the call runs in a second thread of the console. **Removed in step 7.**
6. **Text result: at most 5 parameters.** Accepted limit of the call form, written in the contract.
7. **One processor.** The thread code has no assumption of one processor in its contracts, but the kernel has one stack and no lock. Remove: the step "several processors".
8. **Descriptions by hand.** Remove: the step "descriptions from the source". **Removed in step 8.**
9. **The machine test depended on the order of two programs and on the speed of the firmware.** The order: removed in step 4 (`any_order`). The failure of step 1 was not the firmware: QEMU lost a disk event on its SATA controller with KVM. Removed with step 5: the tool writes the boot volume, on a virtio block device (0 slow boots of 160).

### Bad compromises found

None that needs a later replacement of a contract. Concession 1 is the nearest: it is two mechanisms for one concept, and rule 1 of the objective forbids that. It must not stay.

### Order of the next steps

1. Rings wait on words; delete `Wake(memory)`.
2. The console runs an isolated call in a thread.
3. Descriptions made from the source.
4. Rights on handles, split of the Machine handle, limits for the operations with no handle.
5. Several processors.

## Review 2: steps 6 to 10 (2026-11-10)

### What the five steps added

- Step 6 deleted a mechanism: one wait (the word wait) for rings, events and locks.
- Step 7 used threads in a real program: the console reads keys while a line runs.
- Step 8 removed the descriptions written by hand: the tool reads the source.
- Step 9 added rights to handles. The Machine handle is one object with three rights.
- Step 10 added budgets and the Log handle. No kernel operation creates an object without a handle.

The kernel has 22 operations (21 after step 5: 1 deleted, 2 added). The test has 73 checks and 12 pictures.

### Against the properties

| Property | State after step 10 |
|---|---|
| P1 small counted interface | 22 kernel operations, one entry point. Step 6 deleted `Wake`. Step 10 added `Budget_Create` and `Budget_Read` |
| P2 sandbox by default | Holds, with rights. "No operation exists that works without a handle" is now true for each operation that creates or reaches an object. The operations with no handle act only on the caller: stop, unmap, word wait, word wake, time |
| P4 command buffers | Holds |
| P6 one communication mechanism | Clean. One wait. Concession 1 of Review 1 is removed |
| P13 ZII | Holds. A zero budget slot is not live. A zero right set permits nothing. Handle 0 in the context means "not granted" |
| P19 command is a function | The description comes from the source and the test checks it. Not complete: no records, floats, handles or grants in a description |
| P20 no ambient access | Line 16 (resources) holds for memory, programs and threads. Line 1 holds: a program inspects other programs only with the right Inspect. Not done: processor time, the rate of the log, line 13 (a grant can be revoked) |

### Concessions, and what removes each one

1. **A grant cannot be revoked.** `Handle_Give` copies. The giver cannot take the copy back. Property 2 names this as open. Remove: a design for revocation (a step of its own, before the document service).
2. **A budget has no processor time.** A program with one thread can use a full processor. The scheduler is round-robin, so the other programs still run. Remove: with the scheduler of several processors, a share per budget.
3. **Empty page tables stay until the program stops.** The budget of the program pays for them, so the invariant holds. Remove: count the entries of each table and free a table at 0. Not urgent: bounded by the mappings of the program.
4. **Contiguous memory objects.** `Memory_Create` needs one run of frames. Remove: a memory object as a list of runs. Do it when a test shows a refusal that the budget could pay.
5. **`Thread_Stop` on a thread that holds a lock** (Review 1, concession 4). Still true. The rule stays "ask the thread to end".
6. **One processor** (Review 1, concession 7). The next step.
7. **The root service chooses budgets by name.** `budget_of` and `grants_of` are tables in the code of the root service. This is the first version of a policy that the desktop shell and the person will own (property 20, line 13). It is not a contract: no program depends on it.

### Bad compromises found

One, found and removed inside step 10: a first design gave each program a ceiling ("at most N pages") with no object. It did not conserve, and it was a second mechanism beside handles. The budget object replaced it before any code.

The intermittent failure of the boot test (Review 1, concession 9) did not come back: the flake check passed at each of the steps 6 to 10 with the boot volume on `virtio-blk-pci`.

### Order of the next steps

1. Several processors: one kernel stack and one run queue per processor, a lock for the kernel, shown by a program whose threads run at the same time.
2. Communication between programs: a call of an export of another program through a ring with the same description as a module (the isolated call, for a program that already runs).
3. Multi-threading: a queue for several writers and several readers on the word wait; an event that several threads wait for.
4. Descriptions with records and handles.
5. Revocation of a grant.

## Review 3: steps 11 to 15 (2026-11-10)

### What the five steps added

- Step 11 made the kernel run on several processors, with one lock.
- Step 12 made the start of the machine visible: a boot record, and one display that three programs draw. A start that fails keeps the display.
- Step 13 used paging on the kernel itself, and added tests where the kernel does what its page tables must refuse.
- Step 14 replaced the buttons of the bar by a menu. It added no capability to the kernel: the bar was full.
- Step 15 made the log a set of records in channels.

The kernel has 22 operations: none added since step 10. `Inspect` has two more kinds (`Boot`, `Mappings`) and `Log` has two more parameters. The test has 114 checks, 18 pictures and 8 machines (1 normal start, 1 start that fails, 6 self tests).

### Against the properties

| Property | State after step 15 |
|---|---|
| P1 small counted interface | 22 operations. Three steps added records to read, and no operation |
| P2 sandbox by default | Holds. New: the kernel cannot execute the memory of a program, and uses it only in `user_copy` (SMEP, SMAP). The records of the log are a grant |
| P3, P5 kernel off the hot path | One kernel lock: `Processor_Report` counts the waits. A reader of the log costs the kernel nothing. A writer of the log enters the kernel for each record |
| P6 one communication mechanism | Holds. The log uses the word wait, and adds no way to wait |
| P13 ZII, data-oriented | Holds. A boot record that is all zero draws "not known yet". A log record with a channel that is all zero has no channel. Level 0 is Info |
| P16 removed concepts | New, by decision of the owner: no standard input, no standard output, no standard error |
| P17 trusted boot | Not started. The boot display shows the firmware and the stages; it measures nothing for trust |
| P19 command is a function | Not changed since step 10: no records, floats, handles or grants in a description |
| P20 no ambient access | Not changed for lines 13 and 16: a grant cannot be revoked, and a budget has no processor time. New hole, small: the log has no limit of rate |

### Concessions, and what removes each one

1. **A grant cannot be revoked** (Review 2, concession 1). Still true.
2. **A budget has no processor time** (Review 2, concession 2). Still true, and now also for the log: a program can push the records of the others out of the 1023 places. Remove: a share of time and a share of records for each budget.
3. **One kernel lock.** Two processors cannot be in the kernel together. Remove: when `lock_waits` shows a cost in a real program, split the lock by table.
4. **A reader of the log reads all of it.** A grant for one channel or one program does not exist. Remove: a service that reads the log and gives a part of it, as a ring.
5. **The boot display needs 976 x 700 pixels, and does not show the log.** Remove: a layout by the size of the screen, with the last records.
6. **The stack of the boot program** (16 pages) stays in use after the kernel leaves it. Remove: free it in the first thread run.
7. **No SMEP or SMAP: no guard.** The kernel says it and continues. This is a choice: old processors still start.
8. Review 2, concessions 3, 4, 5 and 7 are still true (empty page tables, contiguous memory objects, a stopped thread that holds a lock, budgets by name).

### Bad compromises found

Three, all removed inside their step.

- Step 12: the root service stopped the machine when a start failed, so the screen was lost at the moment when a person needs it. The display now stays.
- Step 13: the kernel stack was inside the processor record. A full stack wrote on the record with no fault. The stack now has guard pages, and a test proves the fault.
- Step 15: the first design of the log had a service in user space beside the log of the kernel: two writers and two formats. One writer and one record replaced it before any code.

One change of design that the owner must know: the log has no log service (choice 49).

### Order of the next steps

1. Communication between programs: a call of an export of a program that runs, through a ring, with the same description as a module.
2. Multi-threading: a queue for several writers and several readers on the word wait; an event that several threads wait for.
3. Descriptions with records and handles.
4. Revocation of a grant.
5. Processor time and log records in budgets.
6. Paging, second part: pages on first use, read-only code that programs share.

## Review 4: steps 16 to 20 (2026-11-10)

### What the five steps added

- Step 16 made a program that runs serve its own exports. The root service makes each connection.
- Step 17 gave each ring a capacity, one wake for many records, and a short read of the counters before a wait.
- Step 18 made the terminal: typed records of text, no escape sequence, and a surface with two pictures.
- Step 19 made the shared queue and the event: several threads on one queue with no lock.
- Step 20 put the time in a page that each program reads.

The kernel has 22 operations: none added since step 10. Steps 17 to 20 changed only memory layouts and the library `system`, except the time page (one mapping at the creation of a program). The test has 150 checks, 25 pictures and 8 machines. The tool has one more command, `film`.

### Against the properties

| Property | State after step 20 |
|---|---|
| P1 small counted interface | 22 operations. A service, a queue for several threads, an event and the time are not operations |
| P2 sandbox by default | Holds. A connection to a service is made by the root service only. The time page is read-only, and a program cannot remove it |
| P3, P5 kernel off the hot path | Measured at each step. A ring: 20 million records in one second with 53 to 590 kernel entries for one million. A shared queue: 13 to 37 million with 29 to 16 464. The time: 0 kernel entries. Still one kernel lock |
| P4, P6 one communication mechanism | Holds. A service, the terminal, the shared queue and the event all wait with the word wait. No second way to wait exists |
| P13 ZII, data-oriented | Holds. Memory that is all zero is an empty ring, an empty shared queue, an event that never happened and the time 0 |
| P16 removed concepts | The terminal has no escape sequence and no stream of bytes. The console does not use it yet |
| P19 command is a function | A service and a module have the same description and the same call form. Not changed: no records, floats, handles or grants in a description. The description has one line of help for each export and nothing for the module |
| P20 no ambient access | Not changed: a grant cannot be revoked, and a budget has no processor time. The root service has no list of who can call which service |

### Concessions, and what removes each one

1. **The threads of a shared queue trust each other** (choice 75). A thread that stops in the middle of a write stops the queue. Remove: this is the contract of a shared queue; between programs that do not trust each other, the way is one ring for each pair. A kernel that tells the other threads "a thread of this queue stopped" is possible with the event word, when a program needs it.
2. **`workers` does not use the shared queue.** Its tiles still come from a queue with a lock. Remove: change `workers` when the scheduler work measures it.
3. **The time has a resolution of one millisecond**, and no date. Remove: the cycle counter and its frequency in the time page; a clock device service for the date.
4. **The console draws its own text.** The terminal ring has one user, `flood`. Remove: the console writes through the terminal ring, and a terminal gives input records.
5. **Only `terminal` has two pictures.** Remove: each program that draws a full picture at each change opens its window with two pictures.
6. **A call that never returns stops the one thread of a service** (step 16). Remove: a service with one thread for each connection, or a limit of time for a call, with processor time in budgets.
7. **The measures change from run to run** in the test machine (a factor of 2 for some rows of `crowd`): the scenario has 20 programs open. The test asserts no speed. The film machine gives the stable numbers.
8. Review 3, concessions 1 to 8 are still true, except the cost of the time (concession 3 named the kernel lock: each read of the time took it; it does not now).

### Bad compromises found

Four, all removed.

- Step 17: a reader could miss the wake of a writer (a lost wake, about one run in five). Step 18 removed it: a `waits` word is a word of the wait.
- Step 19: the first wake of the shared queue entered the kernel for each record when one reader slept (346 099 kernel entries for one million records). Three rules in `wake_one` removed it inside the step.
- Step 19: the scenario dragged each window from fixed coordinates. A new window moved the others, and the test failed for a reason that was not in the system. The step `Move` reads the place in the log.
- Step 20: the first time page was taken from memory after the first budget counted it. The check "budgets N pages: all the free pages" failed in the test. The page is now taken before the first budget.

### Order of the next steps

1. One module in each role, with its documentation (owner, 2026-11-10): a module carries the text of its documentation; one program shows the documentation of any module; one module is shown as a program, as a library in the memory of its caller, in a sandboxed program, and as a service.
2. The console writes through the terminal ring; a terminal gives input records to its program.
3. Descriptions with records and handles.
4. Revocation of a grant; processor time and log records in budgets.
5. Paging, second part: pages on first use, read-only code that programs share.
6. The kernel lock split by data; scheduling strategies that the system can change while it runs.
7. Storage (virtio block device) with a program that keeps its data; then the network.
