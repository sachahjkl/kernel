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
- The test saves seven pictures of the screen. `kerneltool screenshots` copies them to `docs/screenshots/`.
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
12. Call `spin()`: after 2000 ms the console closes the handle of the call host, and the kernel stops it. Call `count() + gcd(84, 36)`: an isolated call and a direct call in one expression.
13. Start `temple` from the bar.
14. Start `rings` from the bar: six programs pass records through six rings. Add three records. Stop node 4: all the records wait in the ring before it. Start node 4 again.
15. Start `threads` from the bar: one program, five threads. A thread adds the numbers to 1000 and ends; the first thread reads 500500. Four threads draw one Julia set each in the surface of the program. Key `3` stops thread 3, then starts it again. `programs()` shows 5 threads.
16. Start `workers` from the bar. Four threads add to one number for 150 ms each: with the lock no addition is lost; with no lock, millions are lost. Then four threads take 140 tiles from one queue and compute a picture.
17. Call `shutdown()`. The machine stops with code 0.

## The path from power to desktop

1. The firmware starts the boot program (`boot/`), a PE file.
2. The boot program reads the kernel module and the boot image from the boot volume. It loads the kernel with the code of `module/`. It collects the memory map and the framebuffer in a `Boot_Info` record, leaves the firmware, and jumps to the kernel.
3. The kernel (`kernel/`) takes the memory, builds its tables, sets the processor tables, the interrupt controller and the timer.
4. The kernel loads one program from the boot image: the root service. It gives it three handles: the machine, the framebuffer, the boot image.
5. The root service (`programs/root`) loads the other programs in user space with `system.program_start`. It starts the input service, the compositor and the console.
6. From this point, the kernel only executes kernel operations, schedules, and turns interrupts into wakes.

## Kernel

| Subject | Now |
|---|---|
| Entry | One entry point: the `syscall` instruction. `rdi` is 0, a deadline in milliseconds, or `WAIT_FOREVER`. `rax` returns the time |
| Kernel operations | 21 command kinds in the kernel ring of each thread. `kernel/operation/operation.odin` is the full list |
| Objects | Memory, Program, Thread, Interrupt, Ports, Machine |
| Tables | Flat and fixed: 2048 memory objects, 64 programs, 256 threads, 128 handles and 128 mappings per program, 32 threads per program |
| Threads | A thread is a register state and a thread area: the thread record and the kernel ring of the thread. `Thread_Create(entry, stack, parameter)` adds a thread to the caller. The threads of a program share its memory and its handles. A program with no thread stops with code 0 |
| Memory | A memory object is a run of contiguous page frames with a reference count. `Memory_Map` maps it in a program |
| Wait and wake | `Wake(memory)` wakes the other threads of all programs that map this memory. A thread wait is per thread. Each thread has a wake-pending flag, so no wake is lost |
| Word wait | `Word_Wait(address, value)` and `Word_Wake(address, count)`. The kernel names a word by its page frame, so the word can be in memory that two programs share. One entry can wait on 4 words. `system.Lock` is built on it |
| Scheduler | One processor. Round-robin over the threads, with preemption. A time slice is 10 ms. The timer runs at 1000 Hz. Idle is `hlt` |
| Devices | A Ports object opens a port range in the port bitmap of the program. An Interrupt object counts interrupts and wakes its owner |
| Faults | A fault in a thread stops its program with a code. The kernel wakes each program that holds its handle |
| Life of a program | A program runs while a handle names it. When its last handle closes, the kernel stops it. Only the root service has no handle |
| Inspect | The Machine handle gives `System_Report` and `Program_Report` records, and stops the machine |

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
3. **Wake by memory.** `Wake` and `Handle_Give` take a memory handle to name "the other side of this ring". The kernel has no ring object: a ring is a memory object with a layout that the two programs agree on.
4. **The kernel loads the root service only.** The loader of all other programs is user-space code in `system/load.odin`. This closes open question 2 of `ARCHITECTURE.md` in the direction "minimal loader in the kernel, for one program".
5. **Fixed addresses.** A program module is at `0x40_0000`. The stack, the context and the kernel ring have fixed addresses. No random base address.
6. **The compositor is also the desktop shell.** The glossary defines them as two programs. One program holds both roles now.
7. **Grants by program name.** The root service decides the handles of a program from its name, in code. No grant record, no revoke.
8. **Commands of two origins.** The system commands (`programs`, `start`, `shutdown`...) are compiled into the console. `load("math")` loads a module of the boot image: each export becomes a command. The console reads the name, the types and the help of an export from the function table of the module, and calls the export with the call form. `load` checks the hash of the module first.
   **The person chooses the trust.** `load` gives direct calls: the module has the memory and the handles of the console. `isolate` gives isolated calls: the module runs in a call host. The description and the way to type a call are the same.
9. **Font.** Spleen 8x16, BSD 2-Clause, converted from its BDF file by `kerneltool font`.
10. **Types of the description.** `Integer` (64 bits, in a register) and `Text` (the address of a slice record). At most 6 parameters. For a Text result, the caller gives one more argument: the address of a buffer record `{address, capacity}`. The export writes what fits and gives the count of bytes of the full text. In an isolated call the buffer is the free part of the call region. The kernel tool holds the description of each export in its module table; no tool checks it against the source.

11. **Isolated call.** `MODULE_CONTRACT.md` section 4, "The isolated call, as implemented", lists these choices: one call host per module, the argument record in the call region, the status numbers, the limit of 2000 ms, a call region of 16 pages, one call at a time per call host.
12. **The caller starts the call host.** The console creates the program with `system.program_start`; the root service takes no part. Any program can create a program: the new program has only the handles that its creator gives.
13. **A program runs while a handle names it.** The kernel stops a program when its last handle closes (stop code `0x200`). Reason: nobody can stop a program that no handle names. A fault gives stop code `0x100` plus the exception number.
14. **The context has no text.** The 256 bytes of text of the context are removed: no program used them, and property 19 forbids them.
15. **One kernel ring per thread.** With one ring per program, a thread that the timer interrupts can get the completion of another thread. Each thread has a thread area that the kernel makes: the thread record (one page), then the kernel ring. `THREAD_AREA_BASE` is the address of the first one; a program has at most 32.
16. **The `gs` register holds the address of the thread record.** `system.call` must find the kernel ring of the thread that runs, on any stack. This amends rule 7 of the module contract: see there.
17. **A wake is for all the threads of a program.** `Wake(memory)`, an interrupt, the end of a thread and the stop of a program wake each thread of the programs concerned. A thread that wakes for another reason reads its queues and waits again. The kernel keeps no list of who waits for what.
18. **A thread ends alone or by its handle.** `Thread_Stop(0)` ends the caller. `Thread_Stop(thread)` ends another thread of the program at any instruction: the caller is responsible for the data that this thread was changing. `Thread_State` and the wake at the end of a thread make `system.thread_wait`.
19. **Order in the machine test.** Two programs print in an order that the system does not fix. A `Wait` step with `any_order` does not move the place in the log.
20. **The word wait.** Property 6 proposed "a futex-like wait on a ring counter". `Word_Wait` is a command of the entry that waits: the kernel compares the word and records the wait in one step, so no wake is lost. A word wait ends only by `Word_Wake` on one of its words or by the deadline. A wake of `Wake(memory)` stays pending for the next wait with no word: a lock never takes the wake of a ring. The word is 32 bits on all machines, the size of a ring counter.
21. **The lock is a library.** `system.Lock` is one word with three values (free, held, held with a thread that waits). The kernel has no lock object. A free lock costs one atomic instruction and no kernel entry.
22. **The boot volume is a file that the tool writes.** `tools/kerneltool/volume.odin` writes a FAT32 volume of 64 MiB with the boot program, and the machine gets it as a virtio block device. Before, QEMU made a FAT disk from a folder, on its SATA controller. With KVM, about 1 boot in 10 then stopped in the firmware, in a read of the disk, until an event came to QEMU (measured: 7 of 80 boots with a plain image on SATA, 0 of 160 on virtio). This was the intermittent failure of step 1 of the machine test. A test reads the volume back with a separate reader.

## Gaps

Against the properties and the module contract:

- Handles have no rights. A program can give any of its handles onward.
- The Machine handle gives inspect and stop together.
- Property 19 is not complete: the description has no records, no floats, no handles and no grants. A module with imports cannot be loaded by a program.
- The console waits during an isolated call: it draws nothing and reads no key until the call ends or the limit passes.
- Each program can create memory objects and programs with no limit, and can write on the log of the kernel.
- Frame pointers are not enforced. An import call goes through a stub that the linker adds.
- The test "a C program calls an Odin module" does not exist.
- One processor.
- `Wake(memory)` is still the wake of a ring, and it goes to all the threads of the programs that map the memory. The word wait can replace it: the reader waits on the `write` counter of the queue. Then `Wake(memory)` and the wake-pending flag can go (rule "one mechanism").
- A thread that stops with a lock held keeps the lock: the other threads wait with no end.
- A thread handle can go to another program, which can then stop the thread (no rights on handles).
- No storage, no network, no document service, no principals, no TPM, no Secure Boot.

Performance:

- The compositor keeps at most 8 damage rectangles and draws only these for each frame. With `plasma` open it uses about 7 % of the processor under QEMU (60 % before, with a full redraw). A program cannot give the part of its surface that changed: `Present` damages the full surface.
- The kernel saves and restores the floating-point state on every entry.
- `display.open` repeats `Handle_Give` until the compositor maps the ring.

Input:

- The keyboard layout is US only.

## Next steps

1. Descriptions made from the source (property 19).
2. Rights on handles, and a split of the Machine handle.
3. Damage rectangles in the compositor.
4. A block device service (virtio), then the storage service.
5. Several processors.
