# The intent of modus

This folder follows <https://srcmd.org>. It records why each part of the system has its form: the purpose, the constraints, the chosen form, each refused form with its reason, and the subtle points. It is written for a developer or an agent who starts work on a part.

Read this file first. Then read the file of the part that you change. Change that file before you change the code.

## What this folder is not

- It is not the documentation. A guide of `docs/` says what the system does and how to use it, and the site publishes it. An intent file links to a guide; it does not repeat it.
- It is not the record of the decisions. `docs/DECISIONS.md` says who decided what, when, and in which words.
- It is not a log of the work. `docs/FIRST_MILESTONE.md` holds the numbered choices of each step, and `docs/REVIEWS.md` the reviews.
- It is not a plan. A plan in progress goes in a folder `tmp/` that git ignores.

## The system on one page

modus is an operating system for x86-64, written in Odin, that runs on one fixed machine: QEMU with virtio devices, UEFI firmware and a TPM. The 21 properties of [`docs/PROPERTIES.md`](../../docs/PROPERTIES.md) are its rules. Each proposal is compared with them before any work.

**The kernel** (`kernel/`) is small and counted: 33 kernel operations. A program asks for an operation with a command record in a ring of shared memory, one ring for each thread. The one kernel entry runs the records of the ring, then waits. The kernel holds the handle tables, the memory objects, the page tables, the threads, the scheduler with a closed set of strategies, the budgets, the fault ring and the control of a thread. It holds no driver, no file system, no network code, no loader for imports and no text parser. It imports the contract packages only.

**The contracts** (`contract/`) are the records and the constants that two parties agree on: the kernel operations, the module format, the ring, the draw and block and frame records, the system description. A contract package holds no kernel operation call. **The support packages** (`support/`) are what a program compiles in to use the contracts: `system` (the kernel entry, the rings, the loader), `interface` and `graphics`, `tcp`, `quic`, `storage`, `sentence`.

**One code module** is the one format of compiled code. The same file is a program, a service, a library and a sandboxed program. A module describes each export in flat tables: the parameters, their types, their rights. From that description the console completes and checks a call, the manual shows a page, a call host isolates a call, and the loader checks a replacement. A module is named by the BLAKE3 hash of its file. An import names the hash of the imported file.

**The start.** The boot program (`boot/`, a UEFI application) checks the signed system description, measures into the TPM, loads the boot image and jumps to the kernel. The kernel starts one program, the root service (`programs/root`). The root service holds every grant at the start. It starts each other program with the grants of its role, serves the root ring (start, stop, connect, revoke, replace, debug), and keeps the table of the replacements.

**The programs** (`programs/`) are each one module in its own address space, with only the handles that it was given:

- Device services: `block`, `frame` (the network device), `input`. The code of a device is a program.
- Shared services: `storage` (one private store for each program, versions, no save action), `network` (the multiplexer of one network device), `settings`, `log`, `manual`, `debugger`, `remote` (calls from another machine over QUIC).
- The desktop: `compositor` (the surfaces, the input, the bar, the palette), `terminal` (the window of a program that writes text), `console` (the language: a command is a function, a result has a kind and a drawer).
- About fifty programs that each show one property: `rights`, `origin`, `budget`, `scheduler`, `fault_ring`, `tally`.

**Communication** between two programs is shared memory: a ring of records and, for bytes, a region. A call of a service is a record in a call ring with its arguments in a call region. No program parses the text of another.

**The tool** (`tools/kerneltool`) is the only automation: the build (incremental, in two steps for a module, reproducible), the machine tests under QEMU with a peer for the network, the checks of the sources, the site, the changelog, the news, the films. `kerneltool check` and `kerneltool screenshots` with `nix flake check` are the full check.

## The subtle points

These are the points that an agent gets wrong most often.

1. **Compare first, then build.** A proposal that contradicts a property or a decision is named as such before any work. Propose the nearest form that keeps the property. A property changes in the documents first, then in the code.
2. **The described export is the only border between two modules.** There is no second kind of import. A parameter that a description cannot carry (a slice by value, a record that holds an address, a seventh parameter) means that the border is in the wrong place. See [api/library_modules.md](api/library_modules.md).
3. **A new right for a program is the last answer.** First look for the program that already holds the grant, and give it a new face. The palette gives no program a new authority: see [features/palette.md](features/palette.md).
4. **The policy is outside the kernel, the mechanism inside.** No code of a program runs on the path of the scheduler. A write that a program chooses the moment and the direction of must change no history that a strategy keeps. See [features/scheduling_policy.md](features/scheduling_policy.md).
5. **A count, an offset or a length from another party is copied, then checked.** A value is never checked once and read again from memory that the other party can change. This holds for a table of another program, a file and a packet.
6. **No queue drops a record in silence.** A full queue stops its writer, or it has a stated capacity and counts each refusal on the log. See [features/key_path.md](features/key_path.md).
7. **A test checks a condition. A time in a test only ends a hang.** Never assert a speed, a duration or a rate: print it as a measure. Never wait a fixed delay for a state: wait for the state. See [`docs/TOOLS.md`](../../docs/TOOLS.md), "The bounds of the tests".
8. **The hash of a module is its identity, and many things change it.** A change of an import changes the hash of each importer. A path of a source file is in a debug object, not in a module. Debug information must not change the code. See [infrastructure/debug_information_and_code.md](infrastructure/debug_information_and_code.md).
9. **The kernel never imports a support package.** The kernel is freestanding: `"contextless"`, no allocator, no `fmt`. The build uses `-vet`: no shadowed local, no unused import. See [infrastructure/repository_layout.md](infrastructure/repository_layout.md).
10. **One term for one concept.** Define a term in `docs/GLOSSARY.md` before its first use, and never use a word of its "Do not use" list. A name in the code is long and of complete words.
11. **A document that says what the code no longer does is a fault.** A change of the code changes, in the same commit, the guide, the glossary, the README, the intent file and the working record that describe it.
12. **A comment in a source gives the reason in words.** It names no number of a property, a choice, a step, a review finding or a decision, and no date. A pointer to a guide names a heading that exists.
13. **No text over another text, and no cut text, in any picture or page.** A text has a box. Compute its width from the font before you place it.
14. **No backward compatibility.** Change a format in place and remove the old path.

## The rules of this folder

- **One file for one part.** `features/` holds a capability that a principal or a program sees. `data/` holds a format or a table. `api/` holds a border between two bodies of code. `infrastructure/` holds the build, the tests, the site and the layout of the repository. A folder exists only when it holds a file.
- **A file exists only when a design exists.** Do not write a file for a part that has no design to record.
- **Each file has a title of level 1**, then its purpose, its constraints, the chosen form with its reasons, the refused forms, the subtle points and the hazards, and a short state: what is built and what is left.
- **High signal.** Omit what the code shows. Keep a measured number only when it decided a choice. Do not keep a plan of work, a list of files to change, or the steps of an agent.
- **The form of today.** When a design changes, the file states the new form, with one line on what changed. It is not a history.
- **No name of a person and no role of the project.** No date, except in a pointer to a decision.
- **A pointer to a decision is allowed**, in this form: (`docs/DECISIONS.md`, D-236). A number of a choice, of a step or of a review finding is not allowed: those numbers belong to the log of the work, and an intent file states the reason itself.
- **A pointer to a guide** is a link with the path of the guide from the root as its text, then the heading in quotes: [`docs/CONSOLE.md`](../../docs/CONSOLE.md), "8. The palette provider". The tool checks that the heading exists.
- **A link between two intent files** is a relative link. The tool checks that the file exists.
- **The name of a file** has lower case letters, digits and `_`, and ends with `.md`.
- **Simplified Technical English**, with the terms of the glossary.
- `kerneltool check` runs the check `intent_index_check`: the file index below lists each other file of this folder exactly once, and names no file that does not exist.

## Where older intent lives

The intent of the parts that were built before this folder is in other documents. They stay where they are: the site links them, and the numbered choices point at them.

- [`docs/PROPERTIES.md`](../../docs/PROPERTIES.md): the 21 properties, each with what it forbids, what it costs and what is open.
- [`docs/FIRST_MILESTONE.md`](../../docs/FIRST_MILESTONE.md): the choices of each step, each with its reasons and its refused forms. It is intent in the form of a log.
- [`docs/DECISIONS.md`](../../docs/DECISIONS.md): the decisions, with their words.
- The design sections of the guides: [`docs/MODULE_CONTRACT.md`](../../docs/MODULE_CONTRACT.md), "Closed rules"; [`docs/SCHEDULING.md`](../../docs/SCHEDULING.md), "5. What this system refuses, and why"; [`docs/TOOLS.md`](../../docs/TOOLS.md), "The debugger: the design"; [`docs/INTERFACE.md`](../../docs/INTERFACE.md), "10. The decisions of this design"; [`docs/DESIGN.md`](../../docs/DESIGN.md), the design rules of the interface.
- `docs/research/`: the studies of prior art that came before a design.

## File Index

- [api/library_modules.md](api/library_modules.md): which shared library becomes a module that programs import, where the border goes, and why there is no second kind of import
- [features/foreign_systems.md](features/foreign_systems.md): why a foreign system runs whole inside a guest, and the forms of a Linux and an NT layer that were refused
- [features/gpu_access.md](features/gpu_access.md): the access to a GPU through a driver domain and one serialization of commands, and the forms that were refused
- [features/heron_program.md](features/heron_program.md): the program that plays the animations of the mark: one source of each rule in `support/mark`, a move on the grid against the free way, and why its window has two pictures
- [features/key_path.md](features/key_path.md): why no queue between the keyboard and a program drops a key in silence, and the two forms of a full queue
- [features/palette.md](features/palette.md): the palette as a panel of the compositor with the console as its provider, and why no program gets a new right
- [features/scheduling_policy.md](features/scheduling_policy.md): the placement of a thread in the kernel, the share for each program outside it, and the hazards that decided both
- [infrastructure/debug_information_and_code.md](infrastructure/debug_information_and_code.md): why a module is the same bytes with and without debug information, where the compiler and LLVM break it, and the choices that remain
- [infrastructure/network_data_path.md](infrastructure/network_data_path.md): what the network service does to the bytes of a packet, the constraint of one pair of queues, and the layers that take the service off the data path
- [infrastructure/repository_layout.md](infrastructure/repository_layout.md): one `src` folder for what becomes the system, one source library `modus` for a program of a third party, and the order of the move
