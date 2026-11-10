# First milestone

Status: implemented on 2026-11-10. `nix flake check` passes.

This document describes what the code does now.
It lists the choices that were made during the implementation and that the owner has not reviewed.
It lists the gaps between the code and the documents.
`GLOSSARY.md` defines the terms.

## Evidence

- `kerneltool test` starts the machine under QEMU and acts as the person through the QEMU monitor: keys, pointer moves, clicks.
- Each step of the scenario waits for a text in the log of the kernel. A step that does not see its text in 20 seconds fails the test.
- The scenario is a table in `tools/kerneltool/machine.odin`.
- The test saves ten pictures of the screen. `kerneltool screenshots` copies them to `docs/screenshots/`.
- `nix flake check` runs the same test in the Nix sandbox.

The scenario does these actions:

1. Wait for the kernel, the root service, the input service, the compositor and the console.
2. Type expressions and commands in the console: `1 + 2 * 3`, a variable, `length`, `hash("abc")`, a type error, `modules()`.
3. Start `life` from the console with `start("life")`. Drag its window.
4. Start `monitor`, `paint` and `plasma` from the bar. Choose colors and draw lines in `paint`.
5. Start `fault`. The kernel stops it on a page fault. The other programs continue.
6. Close `plasma` with its close button. Stop `paint` with `stop("paint")`.
7. Call `programs()` and `memory()`.
8. Call `gcd(84, 36)`: the console has no such command. Call `load("math")`, then `gcd(84, 36) + power(2, 10)`: the result is 1036.
9. Call `help()`.
10. Call `isolate("probe")`: the module runs in a call host. Call `count()`, `checksum("abc" + name)`, and `stop_machine` with three handle numbers: the kernel refuses each one.
11. Call `peek(0)`: the kernel stops the call host on a page fault, and the console reports an error. Call `count()`: a new call host gives 1.
12. Call `spin()`, which never returns, then type `count() + gcd(84, 36)` during the call: the console keeps the keys. Press Escape: the console closes the handle of the call host, and the kernel stops it. The line that waited then runs: an isolated call and a direct call in one expression.
13. Start `temple` from the bar.
14. Start `rings` from the bar: six programs pass records through six rings. Add three records. Stop node 4: all the records wait in the ring before it. Start node 4 again.
15. Start `threads` from the bar: one program, five threads. A thread adds the numbers to 1000 and ends; the first thread reads 500500. Four threads draw one Julia set each in the surface of the program. Key `3` stops thread 3, then starts it again. `programs()` shows 5 threads.
16. Start `workers` from the bar. Four threads add to one number for 150 ms each: with the lock no addition is lost; with no lock, millions are lost. Then four threads take 140 tiles from one queue and compute a picture.
17. Start `rights` from the bar. The program holds the machine with the right Inspect and the boot image with the right Read. It asks the kernel for nine operations. The kernel does four and refuses five with the status `No_Right`: create a device handle, stop the machine, map the boot image to write, map it to execute, give it to the compositor. The log has "rights: ok, 4 allowed, 5 refused".
18. Start `budget` from the bar. The program creates memory objects of 64 pages until the kernel answers `No_Budget`, then closes them: its budget has the first number of pages again. It does the same with threads. It takes 256 pages for a new budget, creates 200 pages with it, and closes the new budget: its own budget then pays for the 200 pages. The log has "budget: ok, 10 memory objects then no budget, 3 threads then no budget, each page returned".
19. Start `processors` from the bar. The machine of the test has four processors. Five threads of the program compute, and the program asks the kernel what each processor runs: the log has "processors: ok, 4 processors ran the program at the same time". Then 1, 2 and 4 threads compute the same picture, and the log has the three times: "processors: the picture took 404 ms with 1 thread, 198 ms with 2 threads, 148 ms with 4 threads" in one run. The test does not check the times.
20. Call `memory()`. The console prints "budgets N pages: all the free pages": after all the starts and stops of the test, each page is free or paid. It also prints the number of processors, and the times that a processor waited for the kernel lock.
21. Call `shutdown()`. The machine stops with code 0.

## The path from power to desktop

1. The firmware starts the boot program (`boot/`), a PE file.
2. The boot program reads the kernel module and the boot image from the boot volume. It loads the kernel with the code of `module/`. It collects the memory map and the framebuffer in a `Boot_Info` record, leaves the firmware, and jumps to the kernel.
3. The kernel (`kernel/`) takes the memory, builds its tables, sets the processor tables, the interrupt controller and the timer. It reads the list of the processors in the ACPI tables and starts each one.
4. The kernel loads one program from the boot image: the root service. It gives it three handles: the machine, the framebuffer, the boot image.
5. The root service (`programs/root`) loads the other programs in user space with `system.program_start`. It starts the input service, the compositor and the console.
6. From this point, the kernel only executes kernel operations, schedules, and turns interrupts into wakes.

## Kernel

| Subject | Now |
|---|---|
| Entry | One entry point: the `syscall` instruction. `rdi` is 0, a deadline in milliseconds, or `WAIT_FOREVER`. `rax` returns the time |
| Kernel operations | 22 command kinds in the kernel ring of each thread. `kernel/operation/operation.odin` is the full list |
| Objects | Memory, Program, Thread, Interrupt, Ports, Machine, Budget, Log |
| Budget | A budget holds pages, programs and threads. `Memory_Create`, `Program_Create` and `Thread_Create` take a budget handle with the right Spend. The budget pays for memory objects, thread areas, page tables and slots. `Budget_Create` moves a part of a budget to a new budget. What an object used returns to the budget that paid. A budget with no handle ends: what it holds returns to its parent, and its parent pays for its objects. The kernel creates one budget at boot, for the root service: all the free pages and all the slots. The sum of the pages of all budgets is always the count of free pages; `System_Report` gives both numbers |
| Log | `Log` takes a Log handle with the right Write. The root service gives it to each program that it starts |
| Rights | Each handle slot holds a set of rights: Give, Read, Write, Execute, Control, Inspect, Devices, Stop. The handle of a new object has each right of its kind. `Handle_Give(target, handle, Rights)` copies a handle with the rights that are in both sets. No operation adds a right. An operation on a handle without the needed right gives `No_Right` |
| Tables | Flat and fixed: 2048 memory objects, 64 programs, 256 threads, 128 handles and 128 mappings per program, 32 threads per program |
| Threads | A thread is a register state and a thread area: the thread record and the kernel ring of the thread. `Thread_Create(entry, stack, parameter)` adds a thread to the caller. The threads of a program share its memory and its handles. A program with no thread stops with code 0 |
| Memory | A memory object is a run of contiguous page frames with a reference count. `Memory_Map` maps it in a program |
| Wait | A thread waits for a time, or on words (the word wait). The kernel has no other wake. For an interrupt, the stop of a held program and the end of another thread, the kernel adds 1 to the event word of each thread of the program, and wakes the threads that wait on that word |
| Word wait | `Word_Wait(address of Word records, count)` and `Word_Wake(address, count)`. The kernel names a word by its page frame, so the word can be in memory that two programs share. One entry can wait on 64 words. `system.Lock` and the wait of a ring are built on it |
| Scheduler | Round-robin over one flat table of threads, with preemption. Each processor takes the next thread that is ready and that no processor runs. A time slice is 10 ms. Idle is `hlt`: a processor that makes a thread ready wakes one idle processor with an interrupt |
| Processors | At most 64. Each processor has a processor record: its kernel stack, its task state with the port bitmap, its segment table, its current thread. One kernel lock: one processor at a time runs kernel code. Each processor has its own timer at 1000 Hz (local APIC); the first processor counts the time. The 16 device lines stay on the 8259 and interrupt the first processor |
| Address translations | Before the kernel frees a memory object, a page table or a thread, each other processor that uses it enters the kernel and forgets it (`processor_sync`) |
| Devices | A Ports object opens a port range in the port bitmap of the program. An Interrupt object counts interrupts and wakes its owner |
| Faults | A fault in a thread stops its program with a code. The kernel wakes each program that holds its handle |
| Life of a program | A program runs while a handle names it. When its last handle closes, the kernel stops it. Only the root service has no handle |
| Machine | One Machine object with three rights. Inspect: read `System_Report`, `Program_Report` and `Processor_Report` records. Devices: create device handles. Stop: stop the machine. The root service keeps Devices. `monitor` receives Inspect. The console receives Inspect and Stop |

The kernel contains no code for a device, except the timer, the interrupt controller and the serial port of its log.

## User space

| Part | Role |
|---|---|
| `system/` | Wrappers of the kernel operations, text formatting, the loader, the grant roles |
| `ring/` | Command queue and completion queue in one memory object |
| `display/` | The protocol of the compositor (create a surface, present, key and pointer events) and the client code |
| `graphics/` | Canvas, fill, line, copy, text. The font is Spleen 8x16 at its native size |
| `programs/root` | Root service: starts programs, grants by name, answers Start and Stop, reclaims stopped programs |
| `programs/input` | Input service: PS/2 keyboard and mouse through granted ports and interrupts |
| `programs/compositor` | Compositor and desktop shell: bar, clock, windows, focus, drag, close, pointer |
| `programs/console` | Console: integers, texts, variables, arithmetic, typed commands |
| `programs/monitor` | System tool: memory, kernel entries, interrupts, pages and processor share of each program |
| `programs/plasma`, `life`, `paint` | Demos: animation, simulation, pointer and key input |
| `programs/temple` | Demo, for fun: a portrait of Jonathan Blow turns about its vertical axis, with perspective. The processor draws it |
| `programs/fault` | A program that writes to an address that it does not own |
| `programs/rings`, `programs/node`, `relay/` | Demo of communication between programs: six `node` programs in a circle, one ring from each node to the next. `rings` starts them, and draws the real content of each ring from the shared memory. A node has four memory objects and no other handle |
| `isolated/` | The isolated call: the layout of the argument record, `encode` for the caller, `decode` with the checks for the receiver |
| `programs/host` | The call host: it loads one module and executes the isolated calls of its exports |
| `modules/math` | A module of commands: `gcd`, `power`, `fibonacci`, `next_prime`, `number` |
| `modules/probe` | A module of commands that tests the sandbox: it reads any address, loops with no end, tries to stop the machine |

Grants by the root service:

| Program | Handles |
|---|---|
| `input` | Ports and interrupts of the keyboard and mouse; a ring to the compositor |
| `compositor` | The framebuffer; the input ring; a control ring to the root service |
| `console` | A display ring; a ring to the root service; the machine; the boot image |
| `monitor` | A display ring; the machine |
| `rings` | A display ring; the boot image, to start its `node` programs |
| all others | A display ring only |

The console starts each call host. A call host receives a call ring and a call region only.

A program with only a display ring can draw in its surface and read its own input events. It can do nothing else.

## Choices made during the implementation

The owner did not review these. Each one can change.

1. **Export numbers.** The kernel tool holds an ordered export list per module. The export index is the position in that list. Imports resolve by name at build time only.
2. **Entry instruction.** `syscall`, with the full register state saved per program and a return by `iretq`. The kernel is not preemptible and has one stack.
3. **Give by memory.** `Handle_Give` takes a memory handle to name "the other side of this ring". The kernel has no ring object: a ring is a memory object with a layout that the two programs agree on.
4. **The kernel loads the root service only.** The loader of all other programs is user-space code in `system/load.odin`. This closes open question 2 of `ARCHITECTURE.md` in the direction "minimal loader in the kernel, for one program".
5. **Fixed addresses.** A program module is at `0x40_0000`. The stack, the context and the kernel ring have fixed addresses. No random base address.
6. **The compositor is also the desktop shell.** The glossary defines them as two programs. One program holds both roles now.
7. **Grants by program name.** The root service decides the handles of a program from its name, in code. No grant record, no revoke.
8. **Commands of two origins.** The system commands (`programs`, `start`, `shutdown`...) are compiled into the console. `load("math")` loads a module of the boot image: each export becomes a command. The console reads the name, the types and the help of an export from the function table of the module, and calls the export with the call form. `load` checks the hash of the module first.
   **The person chooses the trust.** `load` gives direct calls: the module has the memory and the handles of the console. `isolate` gives isolated calls: the module runs in a call host. The description and the way to type a call are the same.
9. **Font.** Spleen 8x16, BSD 2-Clause, converted from its BDF file by `kerneltool font`.
10. **Types of the description.** `Integer` (64 bits, in a register) and `Text` (the address of a slice record). At most 6 parameters. For a Text result, the caller gives one more argument: the address of a buffer record `{address, capacity}`. The export writes what fits and gives the count of bytes of the full text. In an isolated call the buffer is the free part of the call region. The kernel tool makes the description of each export from the source (choice 26).

11. **Isolated call.** `MODULE_CONTRACT.md` section 4, "The isolated call, as implemented", lists these choices: one call host per module, the argument record in the call region, the status numbers, no time limit (choice 25), a call region of 16 pages, one call at a time per call host.
12. **The caller starts the call host.** The console creates the program with `system.program_start`; the root service takes no part. Any program can create a program: the new program has only the handles that its creator gives.
13. **A program runs while a handle names it.** The kernel stops a program when its last handle closes (stop code `0x200`). Reason: nobody can stop a program that no handle names. A fault gives stop code `0x100` plus the exception number.
14. **The context has no text.** The 256 bytes of text of the context are removed: no program used them, and property 19 forbids them.
15. **One kernel ring per thread.** With one ring per program, a thread that the timer interrupts can get the completion of another thread. Each thread has a thread area that the kernel makes: the thread record (one page), then the kernel ring. `THREAD_AREA_BASE` is the address of the first one; a program has at most 32.
16. **The `gs` register holds the address of the thread record.** `system.call` must find the kernel ring of the thread that runs, on any stack. This amends rule 7 of the module contract: see there.
17. **An event is for all the threads of a program.** An interrupt, the end of a thread and the stop of a held program add 1 to the event word of each thread of the program concerned. A thread that waits on its event word wakes, reads the state, and waits again. The kernel keeps no list of who waits for what event.
18. **A thread ends alone or by its handle.** `Thread_Stop(0)` ends the caller. `Thread_Stop(thread)` ends another thread of the program at any instruction: the caller is responsible for the data that this thread was changing. `Thread_State` and the event at the end of a thread make `system.thread_wait`.
19. **Order in the machine test.** Two programs print in an order that the system does not fix. A `Wait` step with `any_order` does not move the place in the log.
20. **The word wait.** Property 6 proposed "a futex-like wait on a ring counter". `Word_Wait` is a command of the entry that waits: the kernel compares the word and records the wait in one step, so no wake is lost. A word wait ends only by `Word_Wake` on one of its words, by an event if the event word is in the list, or by the deadline. The word is 32 bits on all machines, the size of a ring counter.
21. **The lock is a library.** `system.Lock` is one word with three values (free, held, held with a thread that waits). The kernel has no lock object. A free lock costs one atomic instruction and no kernel entry.
22. **The boot volume is a file that the tool writes.** `tools/kerneltool/volume.odin` writes a FAT32 volume of 64 MiB with the boot program, and the machine gets it as a virtio block device. Before, QEMU made a FAT disk from a folder, on its SATA controller. With KVM, about 1 boot in 10 then stopped in the firmware, in a read of the disk, until an event came to QEMU (measured: 7 of 80 boots with a plain image on SATA, 0 of 160 on virtio). This was the intermittent failure of step 1 of the machine test. A test reads the volume back with a separate reader.
23. **One wait.** The word wait is the one way to wait for something else than a time. `Wake(memory)` and the wake-pending flag are deleted. A queue has two words more, `reader_waits` and `writer_waits`. The reader of a queue sets `reader_waits`, then waits on the `write` counter while the queue is empty. `system.send` writes a record, and enters the kernel to wake the reader only if `reader_waits` is set. `system.receive` does the same for a writer that waits for room. A `system.Wait` is a list of at most 64 words: the compositor waits on the queues of all its clients in one entry. Measured in the machine test: the picture of `rings` and the logs do not change.
24. **The event word.** The thread record has an `events` word. The kernel adds 1 to it for each event of the program (choice 17). A thread reads the word (`system.wait_begin`), reads the state, then waits on the word with the value that it read: an event between the read and the wait ends the wait at once. This replaces the wake-pending flag with the rule of the word wait.
25. **The console runs a line in a second thread.** The first thread reads the keys and draws. The second thread runs each line. The two threads share one `Work` record and wait on its words. During a line, the first thread keeps at most 128 keys, shows the time of the line in a status line, and sets the `cancel` word on Escape. An isolated call waits on the completion queue and on the `cancel` word in one entry. The limit of 2000 ms is deleted: the person decides. Escape does not stop a direct call or a command of the console: that code runs in the console itself, and choice 18 says that a thread stopped from outside can hold a lock.
26. **Descriptions come from the source.** `tools/kerneltool/describe.odin` reads each Odin package with `core:odin/parser`. An export is a procedure with `@(export)` and the calling convention "c". `i64` is an Integer, `^string` is a Text, and a last parameter `^[]u8` is the buffer of a Text result. The description holds the name of the export, the name and the type of each parameter, the result, and the first sentence of the comment as the help. Another type, a missing comment or an export of data is a build error: the tool does not guess. The module table has no description. A function record is 56 bytes. The test reads each module file and compares its descriptions with the source. The kernel exports functions only: its two words that the assembly reads are now in `processor.asm`. The rules are those of the Odin binding; the description in the module file does not depend on Odin.
27. **Rights on handles.** A right is one bit of a 32-bit set in the handle slot. There are 8 rights for 6 kinds of object; the table in `kernel/operation/operation.odin` says what each right permits for each kind. `Memory_Map` needs Read, and Write or Execute when the flags ask for them. An operation on another program needs Control on its handle. `Handle_Give` needs Give on the given handle, and Control when the target is a program handle. The copy has the intersection of the rights of the handle and of the mask: a grant never adds a right. `system.program_start` takes grants: a handle and its rights. Each caller names the rights; there is no default "all rights". The boot image handle of the root service has no Write and no Execute. A surface goes to the compositor with Read only. The Machine handle is not split in three kinds: one kind with three rights uses the one mechanism. A thread handle can go to another program with Read only: that program reads the state and cannot stop the thread.
28. **Budgets: no operation creates an object from nothing.** Property 20, line 16, says: "each resource is a handle with a limit; a program divides its limit among its children". A budget is that handle. Three other designs were refused. A limit per program that is only a ceiling does not conserve: the children of a program multiply it. A count per program with no object cannot be given or divided by the handle rules. A budget as a field of the program record makes a second mechanism beside handles. With a budget object, the rights apply (Give, Read, Spend), and the end of a program returns all: `system.program_start` makes a new budget for the program, pays for all that it creates with it, gives the one handle to the program, and closes its own. Two indexes of the context are fixed by the system for each program: `CONTEXT_LOG` (14) and `CONTEXT_BUDGET` (15); `system.log` and `system.memory_create` read them there, so no program has code before its entry. The page tables of a program are paid by the budget that paid for the program. The kernel has no pool of its own after boot: `free pages = sum of the budgets` is the invariant, and the test reads it. The root service chooses each budget by name (`budget_of`).
29. **The log is an object.** The log of the kernel was the last operation that any program could use. It is now a handle with the right Write. The root service gives it with Write; the console and `rings` also receive Give, because they start programs. A program with no log handle logs nothing: `system.log` returns.
30. **Several processors, one kernel lock.** A processor takes the lock at each kernel entry and frees it when it returns to a program or waits for an interrupt. Interrupts are off in the kernel. Property 3 puts the kernel off the hot path: a program enters the kernel to wait, not to work. So the lock is held for a short time, and finer locks add states that nothing needs yet. The kernel counts each acquisition that had to wait (`lock_waits` in `System_Report`), so the cost is a number that `memory()` prints. In one run of the test: 1.7 million kernel entries, 0.6 million waits, most of them during `rings`, where six programs do nothing but wake each other. Review 2 planned one run queue per processor. It is not done: the thread table is flat and the lock covers it, so a queue per processor adds a second structure with no gain while there is one lock.
31. **The processor record.** In the kernel, the `gs` register holds the address of the record of the processor; in a program, it holds the address of the thread record. `swapgs` exchanges the two at each entry and each return. The kernel has no global "current thread". Each processor has its own kernel stack, because a kernel entry starts at the top of the stack and never continues an earlier entry.
32. **`processor_sync`.** The caller holds the kernel lock. It sends an interrupt to a set of processors and waits until each one is in the kernel. Such a processor reloads its page table, then waits for the lock. Two uses. After `Memory_Unmap` and at the stop of a program, no other processor keeps an address translation to memory that returns to the page frames. When a thread on another processor is stopped, the kernel writes 0 in `current` of that processor, then waits: after the answer, that processor does not use the thread, and its entry is not an entry of a thread.
33. **Start of a processor.** The boot program gives the address of the ACPI root record in `Boot_Info`. The kernel reads the processor list (MADT). It copies the start code, less than one page, to the page 0x8000 and starts one processor at a time (INIT, then SIPI). The start code goes from 16 bits to 64 bits with a temporary page table. If the machine has no ACPI tables, or no free low page, the kernel runs with one processor and says it in the log.
34. **The timer is the local APIC.** The kernel measures it against the 8254 once. An idle processor stops its timer, except the first processor. The device lines stay on the 8259: the system has two device interrupts (keyboard, mouse), and a new device class will send its interrupts as messages to a local APIC (MSI), so the kernel needs no I/O APIC code.
35. **One table for the launcher.** `programs/launcher` holds the names and the place of each button. The compositor draws from it and the kernel tool clicks from it: the test step is `Launch` with a name, not a click at a number.
36. **A failure of the check that came sometimes: found.** The flake check of step 11 failed once with "runtime assertion: import" in a unit test of the tool. The tokenizer of the Odin library (`core:odin/tokenizer`) fills its table of keywords at its first use, and its test of "already filled" is outside its lock. The test runner gives each test a thread: two tests that parse Odin source at the same time fill the table twice, and the second stops on an assertion. The tool itself has one thread and is not affected. `tools/kerneltool/describe_test.odin` now fills the table before the threads start.

## Gaps

Against the properties and the module contract:

- Property 19 is not complete: the description has no records, no floats, no handles and no grants. A module with imports cannot be loaded by a program.
- A budget has no processor time. A program with the log can write on it with no limit of rate.
- `Memory_Unmap` does not free a page table that became empty: the budget of the program pays for it until the program stops.
- A memory object is a run of contiguous page frames: `Memory_Create` can give `No_Memory` when the budget can pay.
- Frame pointers are not enforced. An import call goes through a stub that the linker adds.
- The test "a C program calls an Odin module" does not exist.
- A thread has no preferred processor: it can change processor at each time slice.
- When each processor runs a thread, a thread that becomes ready waits for the end of a time slice (10 ms at most) or for a thread that waits.
- Paging protects programs from each other, but the kernel does not yet use it on itself: the kernel image is not split in read-only and no-execute parts, and a kernel stack has no guard page. Owner decision of 2026-11-10: see `HANDOFF.md`.
- A thread that stops with a lock held keeps the lock: the other threads wait with no end.
- No storage, no network, no document service, no principals, no TPM, no Secure Boot.

Performance:

- The compositor keeps at most 8 damage rectangles and draws only these for each frame. With `plasma` open it uses about 7 % of the processor under QEMU (60 % before, with a full redraw). A program cannot give the part of its surface that changed: `Present` damages the full surface.
- The kernel saves and restores the floating-point state on every entry.
- `display.open` repeats `Handle_Give` until the compositor maps the ring.

Input:

- The keyboard layout is US only.

## Next steps

1. Paging as a design tool: guard pages, read-only and no-execute parts of the kernel, pages on first use.
2. Damage rectangles in the compositor.
3. A block device service (virtio), then the storage service.
