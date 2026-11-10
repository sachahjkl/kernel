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
4. Start `monitor`, `paint` and `plasma` from the menu of the bar. Choose colors and draw lines in `paint`.
5. Start `fault`. The kernel stops it on a page fault. The other programs continue.
6. Close `plasma` with its close button. Stop `paint` with `stop("paint")`.
7. Call `programs()` and `memory()`.
8. Call `gcd(84, 36)`: the console has no such command. Call `load("math")`, then `gcd(84, 36) + power(2, 10)`: the result is 1036.
9. Call `help()`.
10. Call `isolate("probe")`: the module runs in a call host. Call `count()`, `checksum("abc" + name)`, and `stop_machine` with three handle numbers: the kernel refuses each one.
11. Call `peek(0)`: the kernel stops the call host on a page fault, and the console reports an error. Call `count()`: a new call host gives 1.
12. Call `spin()`, which never returns, then type `count() + gcd(84, 36)` during the call: the console keeps the keys. Press Escape: the console closes the handle of the call host, and the kernel stops it. The line that waited then runs: an isolated call and a direct call in one expression.
13. Start `temple` from the menu of the bar.
14. Start `rings` from the menu of the bar: six programs pass records through six rings. Add three records. Stop node 4: all the records wait in the ring before it. Start node 4 again.
15. Start `threads` from the menu of the bar: one program, five threads. A thread adds the numbers to 1000 and ends; the first thread reads 500500. Four threads draw one Julia set each in the surface of the program. Key `3` stops thread 3, then starts it again. `programs()` shows 5 threads.
16. Start `workers` from the menu of the bar. Four threads add to one number for 150 ms each: with the lock no addition is lost; with no lock, millions are lost. Then four threads take 140 tiles from one queue and compute a picture.
17. Start `rights` from the menu of the bar. The program holds the machine with the right Inspect and the boot image with the right Read. It asks the kernel for nine operations. The kernel does four and refuses five with the status `No_Right`: create a device handle, stop the machine, map the boot image to write, map it to execute, give it to the compositor. The log has "rights: ok, 4 allowed, 5 refused".
18. Start `budget` from the menu of the bar. The program creates memory objects of 64 pages until the kernel answers `No_Budget`, then closes them: its budget has the first number of pages again. It does the same with threads. It takes 256 pages for a new budget, creates 200 pages with it, and closes the new budget: its own budget then pays for the 200 pages. The log has "budget: ok, 10 memory objects then no budget, 3 threads then no budget, each page returned".
19. Start `processors` from the menu of the bar. The machine of the test has four processors. Five threads of the program compute, and the program asks the kernel what each processor runs: the log has "processors: ok, 4 processors ran the program at the same time". Then 1, 2 and 4 threads compute the same picture, and the log has the three times: "processors: the picture took 404 ms with 1 thread, 198 ms with 2 threads, 148 ms with 4 threads" in one run. The test does not check the times.
20. Start `boot` from the menu of the bar. The window shows the boot display: the seven stages of the start on one line of time, the memory that the firmware gave, the machine, the modules of the boot image, the programs. The log has "boot: ok, 7 stages, N memory ranges, N programs".
21. Start `pages` from the menu of the bar. The window shows what the page tables give, as the kernel reads it from the tables: the direct map, the kernel module, the kernel stacks, and the half of the program. The log has "0 write and execute, 48 guard pages of 48", "pages: ok, the page tables keep the rules" and "pages: the processor refuses the memory of programs to the kernel".
22. Start `log` from the menu of the bar. The window shows the records of the log: the time, the program, the channel and the text of each one, and the count of records of each channel. The log has "log: the kernel wrote 7 records in the channel boot" and "log: ok, N records, 0 lost, N channels".
23. Call `memory()`. The console prints "budgets N pages: all the free pages": after all the starts and stops of the test, each page is free or paid. It also prints the number of processors, and the times that a processor waited for the kernel lock.
24. Call `shutdown()`. The machine stops with code 0.
25. A second machine starts with a boot image that has no compositor. The root service cannot start the compositor: the boot display stays on the screen with "the start failed: cannot start the compositor: status 1", and the machine does not stop. The log has "root: the boot display shows the failure". The test runs this machine first.
26. Six more machines start, each with one test of the kernel on itself. The kernel does one thing that its page tables must refuse: it uses more than its stack, it writes to its code, it writes to its code through the direct map, it executes its data, it reads the memory of a program outside a copy, it executes the code of a program. Each time the processor refuses, the kernel reports the fault with its reason ("the kernel stack of the processor is full", "write to a read-only page", ...), and the machine stops with code 2.

## The path from power to desktop

1. The firmware starts the boot program (`boot/`), a PE file.
2. The boot program reads the kernel module and the boot image from the boot volume. It loads the kernel with the code of `module/`. It collects the memory map and the framebuffer in a `Boot_Info` record, leaves the firmware, and jumps to the kernel.
3. The kernel (`kernel/`) takes the memory, builds its tables, sets the processor tables, the interrupt controller and the timer. It reads the list of the processors in the ACPI tables and starts each one.
4. The kernel loads one program from the boot image: the root service. It gives it three handles: the machine, the framebuffer, the boot image.
5. The root service (`programs/root`) loads the other programs in user space with `system.program_start`. It starts the input service, the compositor and the console.
   The boot display (`bootscreen/`) is on the screen from step 2 to step 5. The boot program draws it with what it knows. The root service draws it again before each start, with the records of the kernel. The compositor then takes the screen.
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
37. **The boot display is one picture of the records of the kernel.** Owner decision of 2026-11-10: the start of the machine must show a rich, coloured and documented display, with all the facts that help to find a fault, and not a terminal of an old machine. `bootscreen/` draws one record (`bootscreen.Data`) at the full resolution of the framebuffer. Each panel names the kernel record that it shows. A record that is all zero is valid: its panel says "not known yet". Three programs draw it: the boot program, the root service, and the program `boot` in a window. The kernel does not draw.
38. **The boot record.** `Inspect` has a new kind, `Boot`, with the record `Boot_Report`: the stages with their times, the memory ranges of the firmware, the firmware, the framebuffer, the sizes, the frequencies of the cycle counter and of the timer. The kernel reads the cycle counter of the processor at the end of each stage. The counter is 0 when the machine starts, so the time before the boot program is the stage "firmware". The kernel measures the frequency of the counter with the wait that already measures the timer. `Program_Report` has `start_time`, and `Processor_Report` has `apic_id`. The kernel also writes each stage on the log ("kernel: boot: ...").
39. **A start that fails keeps the display.** Before, the root service stopped the machine when a start failed. Now it stops the compositor if it runs, draws the boot display with the failure in red, and waits. A person reads the display and stops the machine. The kernel tool builds a second boot image with no compositor, and a second boot volume, and the machine test checks this path (`scenario_fails`).
40. **No pause for the eye.** With a start that succeeds, the boot display is on the screen for about 20 ms under QEMU: the system does not wait so that a person can read it. The program `boot` shows the same display at any time.
41. **The launcher and large windows.** The buttons of the launcher have 4 pixels of padding and 2 of gap (6 and 4 before), for the names (15 now). The compositor moves a new window up and left until the screen shows all of it.
42. **Paging protects the kernel from itself.** Owner decision of 2026-11-10: paging is a design tool. `kernel/paging.odin` gives the kernel half of the addresses three parts. The direct map is data: no address of it is executable. The kernel module has each segment with its own protection, and its code and constants are read-only in the direct map too. The kernel stacks are in their own region. No page of the kernel or of a program is both writable and executable: `Memory_Map` refuses the two flags together.
43. **Guard pages around each kernel stack.** Each processor has a slot of 32 pages of addresses: a guard page, the kernel stack of 16 pages, a guard page, the stack of the double fault of 4 pages, and guard pages to the end. A guard page has no memory. A stack that is full gives a page fault, then a double fault on its own stack, and the kernel reports "the kernel stack of the processor is full". Before, the stack was in the processor record, and a full stack wrote on the record. The first processor leaves the stack of the boot program before it runs the first thread.
44. **The kernel uses the memory of a program in one place.** `user_copy` (in `kernel/processor.asm`) is the one place where the kernel reads or writes at the addresses of a program. If the processor has the guards (SMEP and SMAP), the kernel sets them: any other use, and any jump to the code of a program, is a page fault. The kernel copies the parameters of an operation to its own memory before it uses them. The QEMU machine has `-cpu max` so that the test has the guards.
45. **The kernel reads its own tables.** `Inspect` has a new kind, `Mappings`, with the record `Mapping_Report`: the runs of pages with one protection, the counts, the guard pages. At the start, the kernel reads its half and stops the machine if a page is writable and executable or if a guard page is missing. The program `pages` shows the same record.
46. **Tests of the kernel on itself.** A test that the kernel survives proves nothing about a protection: the test must do the thing that is refused. The boot record has a field `self_test`. The kernel tool builds one boot program for each test (`-define:SELF_TEST=`), and the machine test checks the report of each fault. A normal boot program has the value 0.
47. **The launcher is a menu.** The bar had one button for each program, and 15 names filled it. The bar now has one button, "programs". It opens a menu with one line for each program. A press on a line starts the program, and any press closes the menu. `programs/launcher` still holds the one table of the names and the places: the compositor draws from it, and the machine test clicks from it. The buttons of choices 35 and 41 do not exist any more.
48. **The log is records in channels.** Owner decision of 2026-11-10. A log record (`Log_Record`, 256 bytes) has a number, a time, a program, a thread, a level, a channel and a text. A long text takes several records. The operation `Log` takes a level and a channel; `system.log_in(channel, level, ...)` writes one, and `system.log(...)` writes with no channel and the level Info. The serial port receives the same record as one line: "[program] text", or "[program:channel] text".
49. **The kernel is the one writer of the log.** The first design (in `HANDOFF.md`) had a log service in user space. The implementation has none. The kernel must set the program and the thread of a record, or a program could write a record of another program. With one writer, the log is one memory object with a counter: the last 1023 records. A reader maps it with the right Read and waits on the counter with the word wait. The kernel does no work for a reader: no copy, no operation. A reader that is late knows how many records it lost. A service that keeps or filters records can be a reader later.
50. **Who reads the log.** The root service receives the memory object of the log with Read (`ROOT_LOG_RECORDS`) and gives it to the program `log` (`GRANT_LOG_RECORDS`). No other program has it. The kernel writes its stages in the channel "boot", its page tables in "paging", and a program that stops by a fault in "fault" with the level Warning. The root service writes in "programs", the compositor in "surfaces".
51. **No standard input and no standard output.** Owner decision of 2026-11-10. A program has no ambient stream of bytes: its context has no place "input", "output" or "error". The input of a command is its typed parameters and its output is its typed result (property 19). A flow of data in time is a ring of records. The log is not an output: it is for the person who looks for a fault.

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
- Paging does not yet give pages on first use, and two programs that run the same module do not share its code.
- The 16 pages of the stack of the boot program stay in use after the kernel leaves that stack.
- With a processor that has no SMEP or SMAP, the kernel runs without these two guards. `pages` and the log say so.
- The log has no limit of rate: a program can write records until the records of the other programs leave the memory object. A reader with the grant reads the records of all the programs and all the channels: a grant for one channel does not exist.
- The boot display does not show the records of the log. A long text is cut at 80 characters in the `log` window.
- The boot display needs 976 x 700 pixels. On a smaller screen it is cut.
- A thread that stops with a lock held keeps the lock: the other threads wait with no end.
- No storage, no network, no document service, no principals, no TPM, no Secure Boot.

Performance:

- The compositor keeps at most 8 damage rectangles and draws only these for each frame. With `plasma` open it uses about 7 % of the processor under QEMU (60 % before, with a full redraw). A program cannot give the part of its surface that changed: `Present` damages the full surface.
- The kernel saves and restores the floating-point state on every entry.
- `display.open` repeats `Handle_Give` until the compositor maps the ring.

Input:

- The keyboard layout is US only.

## Next steps

1. A call of an export of a program that runs, through a ring (the order is in Review 3 of `REVIEWS.md`).
2. Paging, second part: pages on first use, and read-only code that programs share.
3. Damage rectangles in the compositor.
3. A block device service (virtio), then the storage service.
