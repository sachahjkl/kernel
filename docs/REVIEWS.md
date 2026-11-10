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
