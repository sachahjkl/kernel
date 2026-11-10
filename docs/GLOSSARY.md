# Glossary

Status: draft 2, 2026-11-09. The owner accepted the terms on 2026-11-09, with "module" in place of "unit". "Person" is provisional.

This file is the one place that defines the terms of the project.
Each concept has one term. Documents, code and conversation use that term and no synonym.
The "Do not use" column lists the words that this term replaces.
References such as (P10) point to a property in `PROPERTIES.md`.

## Code

| Term | Definition | Do not use |
|---|---|---|
| Module | The one format of compiled code. A module is position-independent, exports functions, and is identified by the hash of its content. A library and an executable are both modules (P10) | unit, library, executable, binary, package, DLL, shared object. "Kernel module" names the Linux concept only |
| Export | A function that a module makes callable from outside the module | symbol, entry |
| Import | A reference from one module to another module by content hash, with the exports that it uses | dependency, link |
| Command | An export that a person can call from the console. A command is not a separate kind of thing (P19) | CLI program, tool, script |
| Module metadata | The description of a module: segments, imports, exports with the type of each parameter and result, origin, debug information (P12) | headers, manifest, symbol table |
| Flat table | An array of fixed-size records at a known offset. The form of the module metadata inside a module. The loader reads this form (P12, P13) | section, blob |
| Index | A SQLite database that is built from flat tables and can be rebuilt from them. It answers queries across many modules. It is never the source of truth (P12) | registry, catalogue, cache |
| Replacement | A record `{hash, hash}` that the starter of a program gives to the loader: where a module imports the first module, the loader loads the second one, after it checked that the descriptions of the used exports are equal | override, shim, LD_PRELOAD, DLL redirection |
| Loader | The user-space code that builds a program from a module and its imports | linker, dynamic linker |
| Prepared module | A memory object that holds the segments of a module that do not change after the load, copied from the file and rebased at the program base. The program that starts programs keeps it in a table, by the hash of the module, while a program maps it | shared library, image cache, page cache |
| Shared code | The pages of a prepared module that each program of the module maps without Write: its code, its constants, and its data that is read-only after the rebase. Each program has its own copy of the writable segments | text segment, shared object |
| Boot image | The one block of data that the boot program loads with the kernel. It holds the modules of the first programs, each with its name | initrd, ramdisk |
| Position-independent | Code that runs correctly at any address with no change to its bytes | relocatable, PIC, PIE |

## Running code

| Term | Definition | Do not use |
|---|---|---|
| Program | A running module with its own address space and its own handle table | process, task, application, app |
| Thread | One flow of execution inside a program: a register state and a kernel ring. The threads of a program share its memory and its handles | fiber, task |
| Thread record | The record that a thread can read about itself: its own address, the parameter of its entry, its number, its event word. The `gs` register of the thread holds its address | thread-local storage, TLS, TEB |
| Word wait | A thread waits while a 32-bit word of memory holds a value. Another thread changes the word, then wakes the threads that wait on it | futex |
| Lock | One word of memory that one thread holds at a time. A thread enters the kernel only to wait for it | mutex, critical section, semaphore |
| Event word | A word of the thread record. The kernel adds 1 to it when an interrupt of the program arrives, when a held program stops, and when another thread of the program ends. A thread waits on it with the word wait | signal, notification |
| Processor | One unit of the machine that executes instructions. A machine has several. Each one runs one thread at a time | core, CPU, hart |
| Processor record | The record that the kernel keeps for one processor: its kernel stack, its current thread, its page table | per-CPU data |
| Stage | One part of the start of the machine, with a start time and a duration: the firmware, two of the boot program, four of the kernel | phase, boot step |
| Boot record | The record that the kernel keeps of how the machine started (`Boot_Report`): the stages, the memory ranges of the firmware, the firmware, the framebuffer | boot log, dmesg |
| Guard page | A page of addresses with no memory, next to a stack: a use of it is a page fault, not a write on other memory | red zone, canary |
| Direct map | The part of the kernel half of the addresses that shows all physical memory. It is never executable | physmap, identity map |
| Run | Pages that follow each other in a page table with one protection (`Mapping_Run`) | extent, VMA |
| Self test | A boot of the machine where the kernel does one thing that its page tables must refuse, to prove that the processor refuses it | negative test, lkdtm |
| Log record | One entry of the log: a number, a time, a program, a thread, a level, a channel and a text (`Log_Record`). The kernel sets all but the last three | log line, message |
| Channel | The short name that a program gives to a log record, to group records of one subject | facility, tag, category, logger |
| Level | How much a log record matters: Info, Debug, Warning or Error | severity, priority |
| Kernel lock | The one lock of the kernel: one processor at a time runs kernel code | big kernel lock, giant lock |
| Thread area | The memory that the kernel makes for one thread: the thread record, then the kernel ring of the thread | |
| Service | A program that other programs call through rings. A service has no special privilege | daemon, server, driver |
| Device service | A service that owns the queues of one device class (P7) | driver |
| Input service | The device service of the keyboard and the mouse. It sends key and pointer events to the compositor | input driver |
| Root service | The first program. It receives every handle that exists at boot and gives them out | init, PID 1, system manager |
| Context | The one typed record that a program receives when it starts: arguments, granted handles, rings. It is defined by the system, not by a language (P19) | argv, argc, environment, arguments |
| Kernel | The code that runs with processor privilege. It holds five systems: handle table, memory, scheduler, rings and wait, device grant | core, supervisor |
| Kernel operation | One request that a program makes to the kernel (P1) | system call, syscall |
| Boot program | The UEFI program that loads and measures the system, then starts the kernel (P17) | boot loader, bootloader |

## Access

| Term | Definition | Do not use |
|---|---|---|
| Handle | An index and a generation in the handle table of a program. It names one object with a set of rights. Handle 0 names no object (P2) | file descriptor, capability, token, reference |
| Memory object | Pages that the kernel names by handle. Each page has a page frame, or gets one at its first use. Programs map it; two programs that map the same one share it | region, shared memory segment, buffer |
| Page on first use | A page of a memory object that gets its page frame at the first read or write, by a program (a page fault) or by the kernel. The frame is all zero. The budget paid for the page when the memory object was created | lazy allocation, demand paging, demand-zero page |
| Reserved page | A page that a budget paid for and that has no page frame yet. The kernel keeps one free frame for each reserved page, so an access never fails for lack of memory | overcommit |
| Frame list | The record of the page frames of one memory object: in the kernel record of the object for at most 4 pages, else in list pages that the budget pays for | page list, radix tree |
| Right | One permitted kind of operation on the object of a handle. The rights are Give, Read, Write, Execute, Control, Inspect, Devices and Stop. A grant can remove rights and cannot add one | permission, privilege, mode |
| Budget | An object that holds pages, programs and threads, and that has two limits: processor time and log records. It pays for each object that a program creates. A program moves a part of its budget to a new budget. What ends returns to the budget that paid (P20) | quota, limit, cgroup, job |
| Limit | A property of a budget for time: the microseconds of processor time, or the log records, that the budget can use in each second. A limit holds for the budget and for each budget that came from it. A limit does not move as pages do: a new budget has a limit that is not above the limit of the budget that it came from (P20) | quota, cap, bandwidth, rate limit |
| Period | The 100 ms in which the kernel applies the processor limit of a budget. A thread of a budget that used its part of the period does not run until the next period | window, slice |
| Grant | The act that gives a handle to a program, and the record of that act. A grant is visible and can be revoked (P20) | permission, authorization, consent |
| Holding | A handle or a mapping of a program: one thing that the program has of an object (P2) | reference, capability |
| Origin | The handle that a holding came from. A handle that `Handle_Give` made came from the handle that was given. A mapping came from the memory handle that was mapped. A holding that the kernel made has no origin. When a handle closes, what came from it comes from its own origin | parent, derivation, delegation chain |
| Revocation | The act that ends each holding that came from a handle, in one program or in each program (the kernel operation `Handle_Revoke`). The handle stays. The program that lost a holding cannot refuse (P2, P20) | recall, invalidation |
| Lent handle | A handle that a caller gives for the time of one call. The caller makes a copy of its handle with the rights of the description, gives a handle that comes from the copy, and revokes the copy after the call | borrowed handle, loan |
| Ambient access | Access that a program has because it runs, and not because it received a handle. The system has none (P20) | ambient authority |
| Sandbox | The state of every program: it can reach only the objects of its handles (P2) | jail, container |
| Principal | A key pair and the root handles that the key unlocks: documents, grant records, settings. The kernel does not know it. Principal 0 is the machine (P21) | user, account, owner, root, administrator, executor |
| Session | The tree of programs that started from the root handles of one principal (P21) | login, user session |
| Person | A human who acts in a session. The word has no meaning to the system; it is used only to describe actions at the desktop, such as "the person chooses a document" | user |

## Communication

| Term | Definition | Do not use |
|---|---|---|
| Ring | A pair of queues in shared memory between two programs, or between a program and the kernel: one for command records, one for completion records (P4, P6) | pipe, socket, channel, port, message queue |
| Capacity | The count of records of each queue of a ring: a power of two, chosen when the ring is created, never changed after. It comes from the size of the memory of the ring | buffer size, queue depth, backlog |
| Terminal | A program that shows the text records of one other program, keeps its lines, and gives the keys of the person to it. The root service starts a program and its terminal, and gives the terminal ring and the text region to the two. The kernel has no such concept | TTY, pty, terminal emulator, standard output, standard input |
| Shared queue | One queue of records in shared memory that several threads write and several threads read, with no lock. Each record has a turn word that says if a writer or a reader can use it. Use a ring for one writer and one reader | MPMC queue, channel, work queue, mailbox |
| Event | A count in memory that several threads wait on. A thread adds 1 to it and wakes all the threads that wait | condition variable, semaphore, signal, barrier |
| Source library | A named folder of source packages that a module compiles in. An import names the library and the package: `contract:ring`. The project has two: `contract` (what two parties agree on; no kernel operation) and `support` (what a program compiles in to use the contracts). A source library is not a module: it has no file and no hash of its own | collection, SDK, libc, static library |
| Documentation | The text that a module carries in its file for a person: one line that says what the module is, a text for the module, and a text for each export. The build tool takes it from the source. With the description of each export, it is all that a person needs to use the module | man page, help file, docstring, README |
| Time page | One page that the kernel writes and that each program can only read, at a fixed address. It holds the milliseconds since boot. A program reads the time with one load from memory, with no kernel entry | vDSO, vsyscall, clock system call |
| Terminal ring | The ring between a program and its terminal. In the command queue, a record from the program has a kind (text, status, clear, edit line), a count of bytes and a style. It has no place on the screen. In the completion queue, a record from the terminal is a key record | escape sequence, control character, stream |
| Key record | A record from a terminal to its program: the code of one key that the person pressed, and its character | standard input, character device, raw mode, cooked mode |
| Edit line | The one line that a program changes: the line of input of the person with a cursor, or a line that says what the program does now. The program sends its text and the place of the cursor; the terminal shows it after the last line. The program owns the editing | line discipline, readline, cursor addressing, prompt |
| Text region | The shared memory beside a terminal ring where the program writes the bytes of its text, in order. A record gives only a count of bytes: the terminal keeps its own place | scrollback (for this), pipe buffer |
| Run | Bytes of text that have one style. A line is a list of runs | span, segment, chunk |
| Style | What a run is, and how to show it: a tone, flags (end of the line, own color, reverse) and a color | attribute, SGR, escape code |
| Tone | What a run of text means: plain, dim, good, warning, bad, accent, number. The terminal chooses the color of each tone | color code, severity (for text) |
| Status | One line that a program replaces at any time, with a value and a total. The terminal shows it out of the lines: no line is drawn again | progress bar hack, carriage return |
| Direct call | A call of an export in the address space of the caller. The arguments are in registers (the call form) | in-process call, local call |
| Isolated call | A call of an export of a module that runs in another program. The arguments travel in a ring (P19) | remote call, RPC, IPC call |
| Record description | The part of the description of a module that gives the name, the size and the fields of one record that an export receives or gives. A field is an Integer or a Handle. Two record descriptions that are equal name the same record, in one module or in two | struct type, schema, class |
| Lent handle | A handle that the caller of an export gives for the time of one call. The description of the export names the rights that the export needs. In an isolated call, the receiver has a copy with these rights only, and closes it when the export returns. The caller keeps its handle | borrowed handle, passed capability, inherited descriptor |
| Call host | The program that loads one module and executes the isolated calls of its exports. It has no handle but its call ring, its call region, its budget and the log | worker, helper process, server |
| Call ring | The ring between a caller and a call host. One command record is one isolated call | channel, pipe |
| Call region | The memory object that a caller and a call host share. The caller writes the argument record and the bytes of its slices in it | shared buffer, arena |
| Connection | One call ring and one call region between one caller and one service that serves its own exports. The root service makes it and ends it | session, socket, channel |
| Service ring | The ring between the root service and a service that serves its own exports. One command record names one connection that starts or ends | control channel, accept queue |
| Argument record | The record that holds the arguments of one isolated call: one field per parameter, in order. It is derived from the description of the export | message, payload, marshalled arguments |
| Kernel ring | The ring between a program and the kernel. Each kernel operation is a command record in it (P1) | system call table |
| Record | A fixed-layout block of bytes with typed fields. An all-zero record is valid (P13) | struct, message, packet, object |
| Command record | A record that asks the other side of a ring for one operation | request, message, call |
| Completion record | A record that reports the result of one command record | response, reply, event |
| Device queue | The queue that a device defines for its own commands, for example a virtio queue. The kernel maps it into one program (P5) | ring (reserved for program-to-program) |
| Zero is initialization (ZII) | The rule that all-zero bytes are a valid value with a defined meaning, for every record of the system (P13) | default constructor |

## Storage

| Term | Definition | Do not use |
|---|---|---|
| Object | One named piece of stored data with its versions, held by the storage service and reached by handle (P9) | file, blob, inode |
| Version | The content of an object at one earlier time. The storage service keeps versions (P9) | snapshot (when it means one object), backup, revision |
| Snapshot | The state of a whole private store at one time | checkpoint, backup |
| Private store | The set of objects that belongs to one program. No other program sees it (P8, P9) | home directory, app data, container |
| Document | An object that belongs to the person and not to one program. The document service grants it (P8) | file, user file |
| Module store | The set of all modules and system data, each identified by content hash (P11) | package store, repository, the Nix store |
| System description | The list of hashes that defines one version of the whole system (P11) | image, generation, manifest, profile |
| Storage service | The service that owns the block device and gives objects, versions and private stores (P9) | file system |

## Desktop

| Term | Definition | Do not use |
|---|---|---|
| Surface | A region of shared memory that one program draws into and the compositor displays (P18) | window buffer, framebuffer (reserved for the UEFI one) |
| Picture | One complete image in the memory of a surface. A surface has one picture or two. With two, the program draws one while the compositor reads the other | back buffer, front buffer, swap chain |
| Compositor | The service that owns the display, combines surfaces and routes input to the program with focus. In the first milestone it is also the desktop shell | window manager, display server |
| Damage rectangle | A rectangle of the screen that changed. The compositor draws again only the damage rectangles of a frame | dirty region, invalid area |
| Boot display | The picture of how the machine started, drawn from the boot record and the other records of the kernel. The boot program and the root service draw it on the screen; the program `boot` draws it in a window | splash screen, boot log, POST screen |
| Console | A normal program that calls commands in a real programming language (P19). It has a terminal and no surface: it writes text records, and reads key records | TTY, shell |
| Desktop shell | The program that starts programs and shows surfaces and grants to the person | launcher, window manager |
| Menu of the windows | The menu of the bar with one line for each window. A press on a line brings the window to the front and gives it the focus | task bar, window list, switcher |
| Picker | The surface of the document service where the person chooses a document. Its result is a grant | file dialog, powerbox |

## Terms that the system does not have

These words name concepts that the system removed. Use them only to describe other systems.

file, path, directory, pipe, socket (as an object), signal, fork, environment variable, `argv`, standard input and output, user, group, root, installer, driver (in the kernel), system call table, TTY, shell script, save.
