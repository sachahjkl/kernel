# Next-Gen Kernel

A new kernel and operating system, written in Odin.
The system boots under QEMU to a graphical desktop with a console, a system tool and demo programs.

![The desktop: console, life, monitor and plasma. The title bar of the window in front goes from blue to a darker blue; the others are quiet](docs/screenshots/desktop.png)

![The launcher: the key super opens it, the list narrows at each typed key, Enter starts the chosen program](docs/screenshots/launcher.png)

![The menu of the programs: the button of the bar opens it](docs/screenshots/menu.png)

![The menu of the windows: a press on a line brings the window to the front](docs/screenshots/windows.png)

| | |
|---|---|
| ![The console](docs/screenshots/console.png) | ![The commands of the console](docs/screenshots/tools.png) |

![An isolated call: a module that faults or loops stops alone](docs/screenshots/isolated.png)

![A record and a lent handle in an isolated call: the module has the rights of the description, for the time of the call](docs/screenshots/records.png)

![Revocation: the console takes back what it lent, and the root service ends the machine grant of a program that runs](docs/screenshots/revocation.png)

![A line runs in the second thread of the console: the console keeps the keys, and Escape stops the call](docs/screenshots/running.png)

| | |
|---|---|
| ![Six programs pass records through six rings](docs/screenshots/rings.png) | ![A stopped program takes no record: the records wait in the ring](docs/screenshots/rings_stopped.png) |

![One program, five threads: each square is drawn by its own thread](docs/screenshots/threads.png)

![One queue of tiles, one lock, four threads: each tile has the tint of the thread that computed it](docs/screenshots/workers.png)

![A program with a part of the rights of two handles: the kernel does four operations and refuses five](docs/screenshots/rights.png)

![The origin of a handle: twelve cases of copies, gifts and revocations, with the answer of the kernel](docs/screenshots/origin.png)

![A budget pays for each page and each thread; the kernel refuses when it cannot pay, and each page returns](docs/screenshots/budget.png)

![The limits of a budget: three threads that compute with no end use 5 %, 20 % and 60 % of one processor, and the kernel refuses 60 of 100 log records](docs/screenshots/limits.png)

![The boot display: the stages of the start on a line of time, the memory, the machine, the boot image, the programs](docs/screenshots/boot.png)

![A start that fails: the boot display stays, with the failure](docs/screenshots/boot_fails.png)

![The page tables as the kernel reads them: the direct map, the kernel stacks between guard pages, the kernel module, the half of a program](docs/screenshots/pages.png)

![Pages on first use and shared code: ten cases with the answer of the kernel, and the measures](docs/screenshots/frames.png)

![A service serves its own exports while it runs: the console draws in the window of paint with isolated calls](docs/screenshots/services.png)

![The log: records with a time, a program, a channel and a level](docs/screenshots/log.png)

![One ring between two threads: the records of one second and the kernel entries that they cost, for two capacities and two ways to wait](docs/screenshots/flow.png)

![One module in each role: the file of tally is a program, a service, a library in the console and a sandboxed program](docs/screenshots/roles.png)

![The manual shows the documentation that each module carries in its file](docs/screenshots/manual.png)

![The replacement of an import: agenda imports calendar, which has a fault; the loader gives calendar_fixed in its place after it compared the description of each export that agenda uses](docs/screenshots/imports.png)

![The console sets a replacement through the root service; programs() shows the modules of each program and the replacements that the loader applied](docs/screenshots/replacement.png)

![The information of the modules: the manual shows the table of all the modules, read from their flat tables, with who imports each one and the programs that run it; the console combines the same tables with where, sort and join](docs/screenshots/modules.png)

![One queue for several writers and several readers, with no lock: the records of one second and the kernel entries, against a queue with a lock](docs/screenshots/crowd.png)

![The time is a page that each program reads: the reads of one second from the page and with a kernel entry](docs/screenshots/clock.png)

![A terminal with no escape sequence: flood writes millions of styled lines in one second, the terminal draws only the view](docs/screenshots/terminal.png)

![The person holds the view while the program continues to write](docs/screenshots/terminal_held.png)

![A key is a record from the terminal to its program: flood stops its lines at the key Space, and shows it in its edit line](docs/screenshots/terminal_keys.png)

![The program stopped: its terminal stays, with the lines that the program wrote](docs/screenshots/terminal_stopped.png)

![Four processors run the threads of one program at the same time; the same picture with 1, 2 and 4 threads](docs/screenshots/processors.png)

![The locks of the kernel: kernel entries and pages on first use of 1, 2 and 4 programs, two threads that wake each other, and the waits of each lock](docs/screenshots/locks.png)

![The scheduling strategies: round robin, fair and EEVDF side by side, with the wakes, the delay of a wake, the shares of spinners with weights, and the strategy that the machine uses now](docs/screenshots/scheduler.png)

![The block service: a virtio disk in a program, a ring, and the data in the memory of the client; blocks in one second and kernel entries for each request](docs/screenshots/disk.png)

![The storage service: the private store of the console, its limit of blocks, the stores that the person sees, and a grant that the person revokes](docs/screenshots/storage.png)

![A persistent program after a restart of the machine: notes finds its note and its count of 1000 commits in its private store](docs/screenshots/notes.png)

![A block of the note changed on the disk outside the storage service: the service serves the count, and notes says that the note is damaged](docs/screenshots/notes_damaged.png)

![The network: a virtio network device in a program, a network service with ARP, IPv4, ICMP echo and UDP, and an endpoint with a grant of one remote; ten cases with their answers, and the measures](docs/screenshots/network.png)

![A call from the host: kerneltool call "monitor.programs()" reaches the program remote through its endpoint, which makes the isolated call and sends the typed result back; the counts, the connections that the root service made, and the last calls](docs/screenshots/remote.png)

![TCP in the program: server holds a listen grant on the port 80 and serves one table of connections from one thread; the peer of the test drops, reorders and repeats frames, resets a connection and opens 16 at once; the table shows the state, the bytes, the round trip and the congestion window of each connection](docs/screenshots/server.png)

![A developer tool: the address space of the console as a band scaled by pages, with each gap folded, the table of its mappings with the pages that have a frame, its modules, its threads with the state of the scheduler; a sample each 250 ms with its cost](docs/screenshots/inspect.png)

![The same tool on a program that stopped on a fault: the stack trace as module + offset, near the export before it](docs/screenshots/inspect_stopped.png)

![Errors that diagnose: each case makes an error for real, and the line under it is the sentence of the error record that the kernel, the loader, a module or a service gave; the stack trace of a fault three calls deep](docs/screenshots/errors.png)

![The temple of Jon: a portrait of Jonathan Blow that turns](docs/screenshots/temple.png)

`kerneltool screenshots` makes these pictures from the running machine.

## What works

- A UEFI boot program loads the kernel module and the boot image, then leaves the firmware.
- The kernel has one entry point. Each kernel operation is a command record in the kernel ring.
- Each program has its own address space and its own handle table. A program reaches only the objects of its handles.
- The root service loads all other programs in user space and grants their handles.
- The input service reads the keyboard and the mouse through granted ports and interrupts.
- A block service drives a virtio disk with device memory and a message interrupt; its client gives the memory that the device reads and writes.
- The storage service keeps a private store for each program on the data disk: each change is one commit, and a stop of the machine never shows a part of one. `notes` finds its state after a restart of the machine, after QEMU was ended during its commits, and after its last root block was cut.
- The network: a frame service drives a virtio network device, and the network service gives a program an endpoint of UDP datagrams that reaches only the remote of its grant. The kernel has no network code.
- `kerneltool call "monitor.programs()"` calls an export of a service of the running machine from the host, and prints the typed result: a table with its field names, a record, a text, or the sentence of its error record. The program `remote` relays the call; the root service decides which services it reaches, and the person revokes its grant with `revoke("remote", "person")`. The test reads the place of the pointer from the compositor before each press, and waits for log records with typed fields through `log.records()`.
- `inspect` shows one program live: its address space, its modules, its threads with the state of the scheduler, the stop report of a program that faulted, and the bytes of its own memory, from reports of the kernel that give no byte of another program.
- The compositor owns the framebuffer. Each program draws into a surface in shared memory.
- The console is a normal program. A command is a typed function: `hash("abc")`, `start("life")`, `programs()`.
- `load("math")` loads a module: its exports become commands. The module describes them: the tool makes each description from the source (parameter names, types, help).
- `isolate("probe")` runs a module in a sandboxed program with no handle. The same calls go through a ring. A module that faults, loops or tries to stop the machine does not harm the console.
- `rings` shows communication between programs: six programs pass records through six rings in shared memory. Stop one program: its records wait in the ring. Start it again: they continue.
- `threads` shows several threads in one program: four threads draw in one surface, each with its own kernel ring. The kernel preempts them. Key `3` stops one thread.
- `rights` shows the rights on handles: the program holds the machine with Inspect and the boot image with Read, and the kernel refuses each operation that needs another right.
- `origin` shows revocation: the kernel keeps the handle that each handle and each mapping came from, and a program takes back what came from a handle that it holds. `revoke("monitor", "machine")` in the console ends one grant of a program that runs.
- `budget` shows the budgets: no object comes from nothing. The program creates memory and threads until its budget cannot pay, and each page returns when it frees them. `memory()` shows that the budgets hold all the free pages.
- `frames` shows paging as a tool of the system: a page gets its page frame at its first use, and the budget paid at creation, so no access fails; programs of one module map one memory object for its code, and a write to it is a page fault.
- `limits` shows the limits of a budget: processor time and log records for each second. The kernel counts the time with the cycle counter and stops a thread at the limit of its budget.
- `processors` shows several processors: the kernel says that four processors run threads of one program at the same time, and the same picture takes less time with 2 and 4 threads.
- `locks` shows the locks of the kernel, split by data: four programs that work on their own objects enter the kernel 3.5 times as often as one, and the window gives the waits of each lock.
- `scheduler` shows the scheduling strategies, which the machine changes while it runs: two threads that wake each other on a busy machine make about 80 wakes in one second under round robin and more than 300 000 under EEVDF, and the weights 1, 2 and 4 give shares of about 4, 7.5 and 13.5 %.
- `workers` shows the lock and the word wait: four threads take tiles from one queue. Four threads add to one number: with the lock no addition is lost, with no lock millions are lost.
- A program that faults stops alone. The system continues.

`docs/FIRST_MILESTONE.md` gives the details, the design choices and the gaps.

## Documents

| File | Content |
|---|---|
| `docs/PROPERTIES.md` | The properties that the system is built on |
| `docs/ARCHITECTURE.md` | The key systems and how they connect |
| `docs/MODULE_CONTRACT.md` | The module format, the loader and the call form |
| `docs/FIRST_MILESTONE.md` | What the code does now, the choices made, the gaps |
| `docs/TOOLS.md` | The developer tools, and what each one reads |
| `docs/GLOSSARY.md` | The terms of the project. One term per concept |
| `docs/DESIGN.md` | The design rules: how a program of the system looks. The boot display is the model |
| `docs/DEMONSTRATIONS.md` | For each of the 21 properties: what the machine test shows, the picture, and what no test shows yet |
| `docs/HANDOFF.md` | Current state, rules of the owner, next steps |
| `docs/research/` | Research notes with sources, and video transcripts |

## Code

| Folder | Content |
|---|---|
| `boot/` | The boot program (UEFI) |
| `kernel/` | The kernel. It compiles with the contract library only |
| `runtime/` | `memory.asm`: the copy and the fill of every module, of the kernel and of the boot program (`copy_bytes_without_overlap`, `copy_bytes_with_overlap`, `fill_bytes_with_value`), with its host tests |
| `contract/` | The source library `contract:`: what two parties agree on. `operation` (the kernel operations), `boot_info` (the record from the boot program to the kernel), `module` (the module format and the loader code), `store` (the format of the data disk), `blake3` (the hash), `ring` (two queues in shared memory, and the shared queue), `isolated` (the isolated call) |
| `support/` | The source library `support:`: what a program compiles in. `system` (kernel operations, text, loader, grants, services), `graphics` (drawing, and the table of the design rules), `display` (the protocol of the compositor), `terminal` (the terminal ring), `bootscreen`, `bar` (the names of the programs and the places of the bar, its menus and the filter of the launcher), `relay` (the records of the `rings` demonstration), `twins` (the modes of the program `twin`) |
| `programs/` | `root`, `input`, `compositor`, `console`, `host`, `monitor`, `plasma`, `life`, `paint`, `fault`, `temple`, `rings`, `node`, `threads`, `workers`, `rights`, `origin`, `budget`, `limits`, `processors`, `locks`, `locker`, `scheduler`, `boot`, `pages`, `frames`, `twin`, `log`, `flow`, `crowd`, `clock`, `tally`, `manual`, `terminal`, `flood` |
| `modules/` | Modules of commands (`math`, `probe`) and the test modules of the host load test |
| `tools/kerneltool/` | The kernel tool: all the automation of the project |

## Use

The Nix flake supplies the compiler, the linker, the assembler, QEMU and the UEFI firmware.

```
nix develop
kerneltool run
```

| Command | Action |
|---|---|
| `build` | Build the modules, the boot image and the boot program |
| `run` | Build, then start the machine under QEMU, with the log of the kernel on the terminal of the host |
| `test` | Build, start the machine, act as the person (keys, pointer), check the log, save pictures |
| `screenshots` | `test`, then copy the pictures to `docs/screenshots/` |
| `film` | Build, start the machine, film the terminal, write `build/film/terminal.mp4` (not a test) |
| `font` | Convert the BDF file of the font to `support/graphics/font.odin` |
| `portrait` | Convert `programs/temple/portrait.jpg` to `programs/temple/portrait.pixels` |
| `repeat` | `repeat <module> <count>`: build one module again and again and compare the module, the LLVM IR and the object with the first build |
| `check` | `odin check -vet` and `odin test` of the host code, then `test` |

`nix flake check` runs the formatting hooks and `check`.

In the machine, type `help()` in the console. The button "programs" of the bar opens the menu that starts programs.

## Licences

The font is Spleen 8x16 by Frederic Cambus, BSD 2-Clause. See `support/graphics/FONT_LICENSE`.

The portrait of the `temple` program is a public domain picture from Wikimedia Commons. See `programs/temple/PORTRAIT_LICENSE`.
