# Next-Gen Kernel

A new kernel and operating system, written in Odin.
The system boots under QEMU to a graphical desktop with a console, a system tool and demo programs.

![The desktop: console, monitor, plasma, life and paint](docs/screenshots/desktop.png)

![The launcher: the menu of the bar that starts the programs](docs/screenshots/launcher.png)

| | |
|---|---|
| ![The console](docs/screenshots/console.png) | ![The commands of the console](docs/screenshots/tools.png) |

![An isolated call: a module that faults or loops stops alone](docs/screenshots/isolated.png)

![A record and a lent handle in an isolated call: the module has the rights of the description, for the time of the call](docs/screenshots/records.png)

![A line runs in the second thread of the console: the console keeps the keys, and Escape stops the call](docs/screenshots/running.png)

| | |
|---|---|
| ![Six programs pass records through six rings](docs/screenshots/rings.png) | ![A stopped program takes no record: the records wait in the ring](docs/screenshots/rings_stopped.png) |

![One program, five threads: each square is drawn by its own thread](docs/screenshots/threads.png)

![One queue of tiles, one lock, four threads: each tile has the tint of the thread that computed it](docs/screenshots/workers.png)

![A program with a part of the rights of two handles: the kernel does four operations and refuses five](docs/screenshots/rights.png)

![A budget pays for each page and each thread; the kernel refuses when it cannot pay, and each page returns](docs/screenshots/budget.png)

![The boot display: the stages of the start on a line of time, the memory, the machine, the boot image, the programs](docs/screenshots/boot.png)

![A start that fails: the boot display stays, with the failure](docs/screenshots/boot_fails.png)

![The page tables as the kernel reads them: the direct map, the kernel stacks between guard pages, the kernel module, the half of a program](docs/screenshots/pages.png)

![A service serves its own exports while it runs: the console draws in the window of paint with isolated calls](docs/screenshots/services.png)

![The log: records with a time, a program, a channel and a level](docs/screenshots/log.png)

![One ring between two threads: the records of one second and the kernel entries that they cost, for two capacities and two ways to wait](docs/screenshots/flow.png)

![One module in each role: the file of tally is a program, a service, a library in the console and a sandboxed program](docs/screenshots/roles.png)

![The manual shows the documentation that each module carries in its file](docs/screenshots/manual.png)

![One queue for several writers and several readers, with no lock: the records of one second and the kernel entries, against a queue with a lock](docs/screenshots/crowd.png)

![The time is a page that each program reads: the reads of one second from the page and with a kernel entry](docs/screenshots/clock.png)

![A terminal with no escape sequence: flood writes millions of styled lines in one second, the terminal draws only the view](docs/screenshots/terminal.png)

![The person holds the view while the program continues to write](docs/screenshots/terminal_held.png)

![A key is a record from the terminal to its program: flood stops its lines at the key Space, and shows it in its edit line](docs/screenshots/terminal_keys.png)

![The program stopped: its terminal stays, with the lines that the program wrote](docs/screenshots/terminal_stopped.png)

![Four processors run the threads of one program at the same time; the same picture with 1, 2 and 4 threads](docs/screenshots/processors.png)

![The temple of Jon: a portrait of Jonathan Blow that turns](docs/screenshots/temple.png)

`kerneltool screenshots` makes these pictures from the running machine.

## What works

- A UEFI boot program loads the kernel module and the boot image, then leaves the firmware.
- The kernel has one entry point. Each kernel operation is a command record in the kernel ring.
- Each program has its own address space and its own handle table. A program reaches only the objects of its handles.
- The root service loads all other programs in user space and grants their handles.
- The input service reads the keyboard and the mouse through granted ports and interrupts.
- The compositor owns the framebuffer. Each program draws into a surface in shared memory.
- The console is a normal program. A command is a typed function: `hash("abc")`, `start("life")`, `programs()`.
- `load("math")` loads a module: its exports become commands. The module describes them: the tool makes each description from the source (parameter names, types, help).
- `isolate("probe")` runs a module in a sandboxed program with no handle. The same calls go through a ring. A module that faults, loops or tries to stop the machine does not harm the console.
- `rings` shows communication between programs: six programs pass records through six rings in shared memory. Stop one program: its records wait in the ring. Start it again: they continue.
- `threads` shows several threads in one program: four threads draw in one surface, each with its own kernel ring. The kernel preempts them. Key `3` stops one thread.
- `rights` shows the rights on handles: the program holds the machine with Inspect and the boot image with Read, and the kernel refuses each operation that needs another right.
- `budget` shows the budgets: no object comes from nothing. The program creates memory and threads until its budget cannot pay, and each page returns when it frees them. `memory()` shows that the budgets hold all the free pages.
- `processors` shows several processors: the kernel says that four processors run threads of one program at the same time, and the same picture takes less time with 2 and 4 threads.
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
| `docs/GLOSSARY.md` | The terms of the project. One term per concept |
| `docs/HANDOFF.md` | Current state, rules of the owner, next steps |
| `docs/research/` | Research notes with sources, and video transcripts |

## Code

| Folder | Content |
|---|---|
| `boot/` | The boot program (UEFI) |
| `kernel/` | The kernel. It compiles with the contract library only |
| `contract/` | The source library `contract:`: what two parties agree on. `operation` (the kernel operations), `boot_info` (the record from the boot program to the kernel), `module` (the module format and the loader code), `blake3` (the hash), `ring` (two queues in shared memory, and the shared queue), `isolated` (the isolated call) |
| `support/` | The source library `support:`: what a program compiles in. `system` (kernel operations, text, loader, grants, services), `graphics`, `display` (the protocol of the compositor), `terminal` (the terminal ring), `bootscreen`, `launcher` (the menu of the bar), `relay` (the records of the `rings` demonstration) |
| `programs/` | `root`, `input`, `compositor`, `console`, `host`, `monitor`, `plasma`, `life`, `paint`, `fault`, `temple`, `rings`, `node`, `threads`, `workers`, `rights`, `budget`, `processors`, `boot`, `pages`, `log`, `flow`, `crowd`, `clock`, `tally`, `manual`, `terminal`, `flood`, and the table `launcher` |
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
| `check` | `odin check -vet` and `odin test` of the host code, then `test` |

`nix flake check` runs the formatting hooks and `check`.

In the machine, type `help()` in the console. The button "programs" of the bar opens the menu that starts programs.

## Licences

The font is Spleen 8x16 by Frederic Cambus, BSD 2-Clause. See `support/graphics/FONT_LICENSE`.

The portrait of the `temple` program is a public domain picture from Wikimedia Commons. See `programs/temple/PORTRAIT_LICENSE`.
