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
| Replacement | A record `{hash, hash}` that the starter of a program gives to the loader: where a module imports the first module, the loader loads the second one, after it checked that the descriptions of the used exports are equal | override, shim, LD_PRELOAD, DLL redirection |
| Replacement table | The replacements of the machine. The root service holds it, and gives its records to the loader of each program that it starts. A program that loads modules reads it with a grant Read. A program cannot change it: a program with the role Replace asks the root service | override list, LD_PRELOAD, redirection table |
| Loader | The user-space code that builds a program from a module and its imports | linker, dynamic linker |
| Prepared module | The memory objects that hold the segments of a module that do not change after the load, copied from the file, in two parts: the code (the segments that the loader never writes, the same at each base) and the fixed part (the segments that are read-only after the load, rebased and bound for one base and one binding). The program that starts programs keeps them in a table, by the hash of the module, while a program maps them | shared library, image cache, page cache |
| Shared code | The pages of a prepared module that each program of the module maps without Write: its code, its constants, and its data that is read-only after the rebase. Each program has its own copy of the writable segments | text segment, shared object |
| Slot | 8 bytes of data of a module that the loader writes with the address of one export of an import. A call to another module is one indirect call through a slot | GOT entry, import address, stub |
| Load source | What a loader can read: the files that the program was granted, each named by its hash, and the replacements that the starter of the program gives. The loader finds an import only there (P20) | search path, library path, module store (for this) |
| Module space | The modules that a loader put in one program. Each module is in it one time: two modules that import a third one call the same copy. A module leaves when no module of the space and no load of the caller uses it | link map, address space (for this) |
| Load error | The record of a load that failed (`module.Load_Error`): the stage, the module that was being loaded, the import, a replacement on the path, the export, and the two descriptions that differ. The caller owns it. Zero is no error. It is the error record of the loader, larger because it holds names | exception, errno, error message |
| Stop report | The record that the kernel keeps of a program that stopped on a fault: the stop code, the instruction, the address, the module record of the module that ran, and the stack trace. The holder of the program handle reads it | core dump, crash report, signal info |
| Error record | The record that a call that failed gives back to its caller (`errors.Error_Record`, 56 bytes, seven Integer fields): the error kind, the unit, the operation or export, the number of the argument, the value that it had, the limit, and what the system found. A kernel operation gives it in its completion record, and so does a ring of a service (the values of a completion whose status is not 0); an export writes it at an address that the caller gives. It holds values only. Zero is no error (`MODULE_CONTRACT.md`, section 8) | errno, exception, error code, detail record, error message |
| Error detail | One thing that a call that failed has to say, as one record of the error form of the call: an error record for an export, a load error for the loader. A call gives its error details in a table of error details that the caller gives; the error record of the call is the first error detail (`MODULE_CONTRACT.md`, section 8, "The table of error details") | sub-error, cause, inner error, error list, diagnostic |
| Table of error details | An optional Append table parameter of error details, in memory of the caller: the last parameter of an export that has an error record, with the record of the error record. With no table (`nil`) the call gives its error record only; the count of the table is the count of all the error details, also those that did not fit | error list, error buffer, error stack, error chain |
| Error kind | What an error record says is wrong: an empty argument, a handle that was revoked, a budget that cannot pay, ... (`errors.Kind`). The documentation of an export names the kinds that it gives | error code, errno value, exception type |
| Frame pointer | The register `rbp` of a function: the address of the frame of the function on the stack, where the frame pointer and the return address of its caller are. Each module keeps it (rule 8 of `MODULE_CONTRACT.md`) | base pointer, frame record |
| Stack trace | The return addresses of the calls that led to the instruction of a fault, from the frame pointers, each with the module record that holds it. Part of a stop report | backtrace, call stack (for this), unwind |
| Module record | What the kernel keeps of one module in a program: its addresses, its hash, and the hash that a replacement put it in place of. The loader writes it; the kernel does not read the module. The module records of a program that runs are its identity | link map entry, loaded image list |
| Table | Records of one record description that follow each other in memory, and their count. A Table result is written by the callee in memory of the caller, with the count of the full table (P12, P19). The console holds a table as one value | list, array (for this), result set, rowset, data frame |
| Table parameter | A parameter of an export of the type Table: a table of records of one description in memory of the caller, with a direction. The callee works in that memory in a direct call; an isolated call carries the records in the call region or in a lent memory object (`MODULE_CONTRACT.md`, "Tables and bytes as parameters") | array argument, buffer argument, list parameter |
| Bytes | A parameter type: bytes with no description (not only UTF-8), in memory of the caller, with a direction. It is a table parameter whose record is one byte. A Text is the read-only form for a person | blob, buffer, byte array, binary |
| Direction | What the callee does with the memory of a table parameter or of a Bytes parameter: Read (it reads the count records), Change (it reads and writes the count records, the count stays), Append (it writes after the count, and gives the new count). The rights of a lent memory object are the direction: Read, or Read and Write | mode, access, in/out, intent |
| Table place | The record of 24 bytes `{address, count, capacity}` in memory of the caller that names the memory of a table parameter or of a Bytes parameter in a direct call; the callee receives its address. Count and capacity are in records (in bytes for Bytes) | descriptor, span, fat pointer, buffer record (for this) |
| Information function | A function that reads the flat tables of modules, the module records of the kernel or the replacement table, and fills a table in memory of the caller (`support/information`). It allocates nothing and keeps no state (P12) | query, reflection API, introspection |
| Catalog | The input of an information function: the modules that a program can see, and the replacements of the machine. Today: the boot image that the program was granted, and the records of the replacement table | registry, repository, package database, index |
| Problem | The error value that a reader of input that nobody checked gives for a rule that the input breaks: the kind, where (the table and the record of a module, or the layer of a frame), the byte, the bad value and its limit. An information function gives one for a module (`information.Problem`); the network service gives one for a frame (`datagram.Problem`) | exception, errno, error code |
| Boot image | The one block of data that the boot program loads with the kernel. It holds the modules of the first programs, each with its name | initrd, ramdisk |
| Position-independent | Code that runs correctly at any address with no change to its bytes | relocatable, PIC, PIE |
| Scalar form | The form of a procedure that computes one value with one instruction, in the general registers. It is the reference of each vector form of the same procedure, and the code of a target with no vectors (`docs/SIMD.md`) | plain C version, fallback (for this), slow path |
| Vector form | A form of a procedure that computes several values with one instruction, in the 128-bit registers of SSE2, and gives the same bytes as its scalar form for every input (`docs/SIMD.md`) | SIMD version, kernel (for this), fast path, intrinsics version |

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
| Stage | One part of the start of the machine, with a start time and a duration: the firmware, two of the boot program, four of the kernel | phase |
| Step of the start | One point on the path of the start that the boot display shows (`bootscreen.Step`): ten points, from the firmware to the desktop. The program that draws says which step the machine does now. A step has no time: a stage is a part with a measured time | phase, progress |
| Card | The frame of one subject in a display: a title in its accent, a caption that names its record, and its content (`docs/DESIGN.md`) | panel, box, widget |
| Tile | A rectangle that stands for one thing of a set, with its name inside; its width can be a size (`docs/DESIGN.md`) | chip, badge |
| Accent | The color of the concept that a card is about (`docs/DESIGN.md`) | theme color |
| Boot record | The record that the kernel keeps of how the machine started (`Boot_Report`): the stages, the memory ranges of the firmware, the firmware, the framebuffer | boot log, dmesg |
| Guard page | A page of addresses with no memory, next to a stack: a use of it is a page fault, not a write on other memory | red zone, canary |
| Direct map | The part of the kernel half of the addresses that shows all physical memory. It is never executable | physmap, identity map |
| Run | Pages that follow each other in a page table with one protection (`Mapping_Run`) | extent, VMA |
| Self test | A boot of the machine where the kernel does one thing that its page tables must refuse, to prove that the processor refuses it | negative test, lkdtm |
| Log record | One entry of the log: a number, a time, a program, a thread, a level, a channel and a text (`Log_Record`). The kernel sets all but the last three | log line, message |
| Channel | The short name that a program gives to a log record, to group records of one subject | facility, tag, category, logger |
| Level | How much a log record matters: Info, Debug, Warning or Error | severity, priority |
| Lock of the kernel | A word that one processor holds at a time, to change one kind of kernel data. Each kind has a place in the lock order (`ARCHITECTURE.md`, "Locks of the kernel"). Not the lock of a program, which is a word of the program | spinlock, mutex (for this) |
| Lock order | The order of the kinds of locks of the kernel: control, program, origin, region, frame, cache, log, wait, run. A processor takes a lock only if it holds no lock of a later kind, so no deadlock exists | lock hierarchy, lock ranking |
| Control lock | The one lock of the kernel for the paths that cross programs or end objects that several programs name: start, stop, give to another program, revoke. Not on the paths of the work of a program | big kernel lock, giant lock, kernel lock |
| Program lock | The lock of one program: its handles, its mappings and its page table | address space lock, mmap lock |
| Frame lock | The lock of the page frames, the reserved pages, the pages of the budgets and the slots of the memory objects | zone lock, page allocator lock |
| Run queue | The threads that are ready and that no processor runs, of one processor: its home threads. Its run lock protects it and the scheduling state of these threads | runqueue, ready list |
| Strategy | The rule that orders the ready threads of each run queue: a table of six functions of the kernel (ready, pick, tick, stopping, wake preemption, move) over fixed fields of the thread record and of the run queue. The machine has one strategy at a time: round robin, fair or EEVDF. A program with the right Schedule on the machine changes it while the system runs (`Strategy_Set`, `docs/SCHEDULING.md`) | scheduler class, policy, scheduling algorithm, governor |
| Turn | The time that a thread runs on a processor from its pick to the moment when it leaves: it waits, its budget has no time, or its strategy ends the turn | quantum, timeslice (for this) |
| Time slice | The longest turn under each strategy: 10 ticks. At its end the processor passes through the balance between the processors. Under round robin each turn has this length | quantum |
| Weight | A number from 1 to 1024 of a thread: its share of a processor against the other threads of its queue, under a strategy with weights. 0 at the creation is 1024, the full weight. A program can only lower it (P20) | priority, nice value, shares |
| Virtual time | The run time of a thread in weighted cycles: a run of c cycles adds c * 1024 / weight. The strategies with weights run the thread whose virtual time is least, or eligible | vruntime, virtual runtime |
| Queue clock | The virtual time of a run queue that never goes back: the least virtual time of its ready threads, as the kernel last saw it. A thread that wakes or moves is placed against it | min_vruntime |
| Lag | Under EEVDF: the average virtual time of the queue minus the virtual time of a thread: what the thread is owed. It is kept across a wait, within a bound | debt, credit |
| Eligible | Under EEVDF: a thread whose lag is zero or more. Only an eligible thread can be picked, when one exists | runnable (for this) |
| Request | The processor time that a thread asks for at each turn under EEVDF, in microseconds: 1 to 100 000, 0 is 3000. It sets the virtual deadline, not the share | slice (for this), quantum |
| Virtual deadline | Under EEVDF: the virtual time of a thread plus its request in weighted cycles. Among the eligible threads, the one with the earliest virtual deadline runs | deadline (alone: the deadline of a wait) |
| Wake preemption | The end of the turn of the thread that runs on a processor because a thread that woke must run first, by the rule of the strategy. On another processor, the waker sends an interrupt | wakeup preemption, preempt-on-wake |
| Spinner | A thread of the program `scheduler` that computes with no end, and counts its work | busy loop, hog, load generator |
| Serial | A number of a slot of a kernel table (a thread, a program, a memory object) that changes for each new object in the slot. A path that names a slot across a wait for a lock checks it: the slot can hold another object after the wait | generation (for handles only), epoch, version |
| Wait table | The threads that wait on words, in buckets chosen by the physical address of the word, each with a wait lock | futex hash table |
| Locker | A program that the program `locks` starts several times. It works only on its own objects, so a locker waits for another one only when the kernel makes it wait. The measures of the locks of the kernel count what the lockers do | load generator, stress worker |
| Frame cache | The stack of at most 256 free page frames of one processor, in its processor record, with its cache lock. A page on first use takes its frame there; the end of a memory object puts its frames there; the stack takes and gives frames to the frame table by batches of 128, under the frame lock | per-CPU page list, magazine, pcp list |
| Cache lock | The lock of the frame cache of one processor. Its processor takes it at each take and each put; another processor takes it only to read or empty the stack. It comes after the frame lock in the lock order | per-CPU lock |
| Lock count | What the kernel counts for one kind of lock, on all the processors: the times that a processor took it, and the times that it had to wait for it (`Lock_Count` in `System_Report`) | lock statistics, contention counter |
| Thread area | The memory that the kernel makes for one thread: the thread record, then the kernel ring of the thread | |
| Service | A program that other programs call through rings. A service has no special privilege | daemon, server, driver |
| Device service | A service that owns the queues of one device class (P7) | driver |
| Input service | The device service of the keyboard and the mouse. It sends key and pointer events to the compositor | input driver |
| Root service | The first program. It receives every handle that exists at boot and gives them out | init, PID 1, system manager |
| Context | The one typed record that a program receives when it starts: arguments, granted handles, rings. It is defined by the system, not by a language (P19) | argv, argc, environment, arguments |
| Kernel | The code that runs with processor privilege. It holds five systems: handle table, memory, scheduler, rings and wait, device grant | core, supervisor |
| Kernel operation | One request that a program makes to the kernel (P1) | system call, syscall |
| Boot program | The UEFI program that loads and measures the system, then starts the kernel (P17) | boot loader, bootloader |
| Fixed range | An address and a span of the address space of a program where the system places one mapping that it gives: the settings page, a glyph cache, the date page, the files of a module. Each is one member of the enumeration `Fixed_Range` of `contract/fixed_addresses`, one slot of the band from `BAND_START`, so no two overlap; a mapping that a program places by its own choice is outside the band, from `OWN_CHOICE_START` | well-known address, fixed mapping |

## Access

| Term | Definition | Do not use |
|---|---|---|
| Handle | An index and a generation in the handle table of a program. It names one object with a set of rights. Handle 0 names no object (P2) | file descriptor, capability, token, reference |
| Memory object | Pages that the kernel names by handle. Each page has a page frame, or gets one at its first use. Programs map it; two programs that map the same one share it | region, shared memory segment, buffer |
| Page on first use | A page of a memory object that gets its page frame at the first read or write, by a program (a page fault) or by the kernel. The frame is all zero. The budget paid for the page when the memory object was created | lazy allocation, demand paging, demand-zero page |
| Uncommitted object | A memory object made with the flag `Uncommitted`: its budget pays only its frame list; each page is paid when it is committed. Its mapping holds a range of addresses with no memory behind it | reserved object, reservation, VirtualAlloc(MEM_RESERVE), mmap(PROT_NONE) |
| Committed page | A page of a memory object that its budget paid for: it gets a frame at its first use. Each page of an object that is not uncommitted is committed | committed memory |
| Decommit | The act of `Memory_Commit` with the flag `Decommit`: the pages of an uncommitted object are no longer paid; their frames and their pages return at once; the addresses stay reserved, and a page committed again is zero | madvise(DONTNEED), VirtualFree(MEM_DECOMMIT), discard |
| Page protection | What a page of a mapping lets a program do: read, read and write, read and execute, or nothing (`No_Access`). `Memory_Protect` can only take away what the mapping has | mprotect, page rights |
| Shoot-down | The step where each other processor that uses the page table of a program forgets its old translations (`processor_sync`), after the kernel cleared or reduced page table entries | TLB flush, TLB shootdown (for this) |
| Large page | A page of 2 MiB: one entry of the second level of a page table. Only for an object made with `Large_Pages` | huge page, superpage |
| Fault ring | A ring where the kernel writes a fault of a thread of a program, for another thread that commits or protects and lets it continue (designed, not built) | signal, SIGSEGV handler, userfaultfd, exception handler |
| Reserved page | A page that a budget paid for and that has no page frame yet. The kernel keeps one free frame for each reserved page, so an access never fails for lack of memory | overcommit |
| Frame list | The record of the page frames of one memory object: in the kernel record of the object for at most 4 pages, else in list pages that the budget pays for | page list, radix tree |
| Right | One permitted kind of operation on the object of a handle. The rights are Give, Read, Write, Execute, Control, Inspect, Devices, Stop, Spend, Physical, Schedule and Commit (pay pages of an object that the budget already pays for, and nothing else). A grant can remove rights and cannot add one | permission, privilege, mode |
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
| Real-time clock | The clock of the machine that keeps the date when the machine is off (on a PC: the CMOS clock, ports 0x70 and 0x71). The program `date` reads it at its start and each 10 s | RTC (in text), hardware clock, BIOS clock |
| Date | The count of milliseconds since 1970-01-01 00:00:00 UTC. Leap seconds are not counted: a day has 86400 seconds | timestamp, wall clock, epoch time, Unix time (in text) |
| Date page | One page that the root service creates and maps read-only into each program that it starts. The program `date` writes there the date of the time 0 of the system, so a program reads the date with no kernel entry: that date plus the milliseconds of the time page | wall-clock page, vDSO, clock page |
| Terminal ring | The ring between a program and its terminal. In the command queue, a record from the program has a kind (text, status, clear, edit line, hint line, completion list), a count of bytes and a style. It has no place on the screen. In the completion queue, a record from the terminal is a key record | escape sequence, control character, stream |
| Key record | A record from a terminal to its program: the code of one key that the person pressed, its character, and the modifiers that the person held (Shift, Control) | standard input, character device, raw mode, cooked mode |
| Edit line | The one line that a program changes: the line of input of the person with a cursor, or a line that says what the program does now. The program sends its text and the place of the cursor; the terminal shows it after the last line. The program owns the editing | line discipline, readline, cursor addressing, prompt |
| Line editor | The procedures of `support/line_editor` that change an edit line with keys: the caret, a character at the caret, Backspace, Delete. They have no state of their own: the line is a record of the program | readline, line discipline |
| Hint line | One dim line that a program shows under its edit line: the signature of the call at the caret, or how to use the list that is open. A new one replaces the one before | tooltip, status (for this), echo area |
| Completion list | The names that can take the place of the name at the caret, best first, with one chosen row. The program gives the rows; its terminal draws them over its text, at the edit line | dropdown, popup, autocomplete menu, suggestions |
| Fuzzy match | A match where the characters of a query appear in a name in their order, with gaps allowed, lower and upper case equal. A score orders the names that match (`docs/CONSOLE.md`, section 3) | fuzzy search, subsequence search, filter (for this) |
| Line history | The lines that the person entered in the console, in a ring of bytes in its memory, the newest first | history (alone), scrollback, command log |
| History search | The completion list over the line history: Control-R opens it, and the fuzzy match orders the lines, the newest first for equal scores | reverse-i-search, incremental search |
| Text region | The shared memory beside a terminal ring where the program writes the bytes of its text, in order. A record gives only a count of bytes: the terminal keeps its own place | scrollback (for this), pipe buffer |
| Run | Bytes of text that have one style. A line is a list of runs | span, segment, chunk |
| Style | What a run is, and how to show it: a tone, flags (end of the line, own color, reverse) and a color | attribute, SGR, escape code |
| Tone | What a run of text means: plain, dim, good, warning, bad, accent, number. The terminal chooses the color of each tone | color code, severity (for text) |
| Status | One line that a program replaces at any time, with a value and a total. The terminal shows it out of the lines: no line is drawn again | progress bar hack, carriage return |
| Direct call | A call of an export in the address space of the caller. The arguments are in registers (the call form) | in-process call, local call |
| Isolated call | A call of an export of a module that runs in another program. The arguments travel in a ring (P19) | remote call, RPC, IPC call |
| Record description | The part of the description of a module that gives the name, the size and the fields of one record that an export receives or gives. A field is an Integer, a Handle, or a Text of a fixed size. Two record descriptions that are equal name the same record, in one module or in two | struct type, schema, class |
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

## Devices

| Term | Definition | Do not use |
|---|---|---|
| Physical address | The number that the memory and the devices use for a byte of memory, before the page tables. A program uses virtual addresses only; a device uses physical addresses only | real address, bus address |
| Device memory | A memory object over the registers of a device: physical addresses that are not memory of the kernel. A mapping of it uses no cache. The root service makes it with the right Devices | MMIO region, BAR mapping |
| Message interrupt | An interrupt that a device sends as a write of a value to an address of the interrupt controller of a processor (MSI-X). The kernel gives each one a vector of its own, and an Interrupt object | MSI, vector |
| Bus | The PCI bus of the machine: each device has a place on it (bus, device, function) and a configuration. Only the root service reads and writes the configuration | PCI tree |
| Disk | A device that keeps blocks when the machine stops. The machine of the test has three: the boot volume, the data disk, and the disk of the measures | drive, volume (except the boot volume), LUN |
| Block | 4096 bytes of a disk, at a number from 0. The unit of the block contract | sector, page (for a disk) |
| Block service | The device service of one disk. It serves read, write and flush of blocks to one client, through a block ring (`contract/block`) | disk driver, block layer |
| Block ring | The ring between a block service and its client. One command record is one request; many are in flight; a completion has the tag of its command and a status | I/O queue, submission queue |
| Data region | The memory object of the client of a block service where the device reads and writes the bytes of the blocks, with no copy. It is contiguous (`Memory_Create` with `Contiguous`). A request names a place in it, never an address | DMA buffer, bounce buffer |
| Data disk | The disk of the storage service | data drive, home disk |
| Disk of the measures | A disk that holds no data that a program keeps: the program `disk` measures the block service on it | scratch disk, test disk |
| Network device | A device that sends and receives frames on a link. The machine of the test has one virtio network device at the place 18 of the bus | NIC, network card, network adapter |
| Frame | One Ethernet frame: from the destination hardware address to the end of the data, with no check sequence. 1514 bytes at most | packet (for this), datagram (for this), message |
| Hardware address | The 6 bytes that name a network device on its link | MAC address, physical address (for this) |
| Frame service | The device service of one network device. It sends and receives frames for one client, through a frame ring (`contract/frame`). It does not read a frame | NIC driver, network driver |
| Frame ring | The ring between a frame service and its client. One command record is the Send of one frame, or a Receive: a place for one frame that arrives. Many are in flight | TX queue, RX queue, descriptor ring (for this) |
| Frame region | The memory of the client of a frame service where the device reads and writes the frames, with no copy. It is contiguous. A request names a place in it, never an address | DMA buffer, skb, mbuf |
| Virtio | The standard of devices in shared queues that the first machine uses (P7). `support/virtio` holds what each device service of a virtio device does the same way | paravirtual device |

## Network

| Term | Definition | Do not use |
|---|---|---|
| Network service | The one client of the frame service. It speaks Ethernet, ARP, IPv4, ICMP echo and UDP with the protocol library `support/network`, checks TCP segments against their grant, and gives each program with the grant one endpoint. It keeps no state of a TCP connection. It starts when the first such program starts | network stack, TCP/IP stack, netd, network daemon |
| Endpoint | What a program holds to send and receive datagrams or segments: a datagram ring and a datagram region, with a grant. The grant of a datagram endpoint names one remote, and the network service gives its local UDP port. A segment endpoint has a client grant or a listen grant. The program does not choose a remote that its grant does not name (P20). With the right Inspect of its grant, it also reads the facts of the network of the machine: the frames that no endpoint owns, the kernel entries of the two services | socket, port (for this), connection (for this) |
| Datagram | The data of one UDP datagram and its remote: what a program sends and receives through an endpoint. 1472 bytes at most: one frame, no fragment | packet, message |
| Remote | The IPv4 address and the UDP port or TCP port at the other end of a datagram or of a connection | peer (for this), destination, host |
| UDP port | The 16-bit number of UDP that names an endpoint at an address. It is not the Ports object of the kernel | port (alone), socket number |
| TCP port | The 16-bit number of TCP that names one end of a connection at an address. It is not the Ports object of the kernel, and not a UDP port | port (alone), socket number |
| Segment | One TCP segment: its header, its options and its data, 1480 bytes at most (one frame, no fragment). What a program sends and receives through a segment endpoint | packet, TCP packet, message |
| Segment endpoint | An endpoint whose grant has the protocol TCP. The program writes and reads whole segments; the network service writes the IPv4 header and keeps no state of a connection | TCP socket, listening socket |
| Client grant | The grant of a segment endpoint that reaches one remote, from a block of 64 local TCP ports that the network service chooses | outbound rule, connect permission |
| Listen grant | The grant of a segment endpoint that receives on one local TCP port that the root service names, from any remote, and answers only the admitted remotes | listening socket, bind permission, server socket |
| Admitted remote | A remote that sent a segment to the port of a listen grant. The network service keeps 64 for each listen grant, until the program releases one | connection tracking entry, conntrack, NAT entry |
| Connection | The state of one TCP connection in the program that owns it: one fixed-size record of the TCP library (`tcp.Connection`), with a send buffer and a receive buffer of the caller | socket, TCB (in this system), session |
| Web page | An object of the private store of `server` that it serves by its name, at `/name`. A person puts one with `server.put` from the console | file (for this), static file, asset |
| Access record | The record of one request that `server` answered: the remote, the method, the target, the status, the bytes and the time. The window shows the last ones, and the log channel `requests` has one for each request | access log line, hit |
| Connection table | The records of the connections of one program, the memory of their buffers, and what is common to them: the local address, the listen port, the secret of the initial sequence numbers. `tcp.step` works on one table | socket table, connection pool |
| Datagram ring | The ring between a program and the network service for one endpoint (`contract/datagram`). A command is a Send, a Receive, or a question (Info, Resolve, Echo, Statistics, Problems) | socket, channel |
| Datagram region | The memory of an endpoint where the program writes the data of a datagram to send, and where the network service writes the data of a datagram that arrives. The root service makes it with the datagram ring | socket buffer, send buffer, receive buffer |
| Neighbor | An address of the link and its hardware address, that the network service learned from an answer to its own ARP request. The network service keeps 16 | ARP cache entry, neighbour entry |
| Gateway | The machine of the link that carries IPv4 packets to other networks: 10.0.2.2 on the first machine | router, default route |
| Peer | The part of the kernel tool that is the gateway and the echo server of the network of the test machine, and a TCP client that the tool drives. QEMU gives it each frame as a UDP datagram on the loopback of the host. It reads each frame with its own code. It can drop, reorder and repeat the frames of TCP. It also carries the call requests of the host to the remote service, and their call answers back | mock, fake server, simulator |
| Host | The computer that runs QEMU and the kernel tool. The system does not run on it. For the network of the machine, the host is at the address of the gateway, 10.0.2.2 | build machine (for this), remote (for this) |
| Remote service | The program `remote`. It holds one endpoint whose grant names the host, and the connections to the services that the root service lets it call. It receives call requests, makes each one as an isolated call, and sends the call answer. It does not read the descriptions of the exports: it checks places and sizes only (`programs/remote`, `contract/remote`) | RPC server, debug agent, gdbstub |
| Call request | One datagram from the host to the remote service: a fixed header (`remote.Request`) that names the service, the hash of its module, the export, the places of the result and of the error record, then the bytes of the call region from offset 0 | RPC request, message, packet |
| Call answer | The datagrams of the remote service for one call request: each one has a fixed header (`remote.Answer`) with the status, the integer result and the error record, then a part of the bytes of the result | response, reply |
| Developer tool | A program that shows a person how the system runs: what a program holds in memory and how its threads run (`docs/TOOLS.md`). It reads reports of the kernel with a grant; it changes nothing | debugger (for this), profiler, task manager |
| Sample | One read of all the reports that a developer tool shows, at one time. The tool takes a sample a few times in one second, and measures its cost | snapshot (for this), poll, frame (for this) |
| Folded gap | The part of the band of an address space between two mappings that has no mapping: the band draws it with a fixed width and lines at an angle, because its size has no measure on the scale of the band | ellipsis, break |
| Near export | The export of a module with the highest address at or below an address: a reader names the address "module + offset, near name". The module names its exports only, so a function that is not an export has the name of the export before it | symbol (for this), nearest symbol |
| Confirmed place | A place of the pointer that the test tool read from the compositor (`compositor.pointer()`, through the remote service) before a press: the tool moves the pointer again until the compositor has it at the place that the step wants | pointer sync, warp |
| Request number | The number that the host gives to a call request; each datagram of its call answer has it. A call request with the number of the last call answer gets that call answer again: the call does not run two times. 0 is no request | sequence number, request id, transaction id |

## Storage

| Term | Definition | Do not use |
|---|---|---|
| Object | One named piece of stored data with its versions, held by the storage service and reached by handle (P9) | file, blob, inode |
| Version | The state of one object at one commit: its bytes, its size, the generation and the time of that commit. Each commit that changes an object keeps the state before it as a version, in the version index of the object. The storage service keeps versions (P9) | snapshot (when it means one object), backup, revision, undo step |
| Current version | The state of an object that its last commit made: what a read gives. It is not in the version index | head, working copy, latest revision |
| Version index | The blocks of one object that list its versions: an index block, which names leaf blocks, which hold the version entries, the oldest first | history file, journal, log |
| Shared block | A block that two lists or two versions name: an unchanged block of an object, or the blocks of a clone. The storage service counts it one time in the blocks of the store | deduplicated block, extent reference |
| Reference count | For each block in use, the count of what names it: list entries for a block of data, versions and objects for a list. The storage service frees a block when its count goes to 0 | link count, refcount (in text) |
| Thinning | A commit that removes versions of an object: by the retention rule, or the oldest version of the store when a change does not fit in the limit of the store. Its blocks that no other version names become free | garbage collection, pruning, cleanup, compaction |
| Retention rule | Which versions the storage service keeps: each version for 10 minutes, then one for each hour for one day, then one for each day | backup policy, history limit |
| Clone | A new object whose list is the list of another object: the two share each block until one of them changes (P9) | copy (for this), hard link, reflink |
| Restore | A commit that makes a version the current version again. The current version before it becomes a version: nothing is lost | revert, rollback, undo |
| Time since the format | The milliseconds of the storage service since the format of the disk: the root block keeps it at each commit. It is the time of a version until the system has a date | uptime, timestamp |
| Snapshot | The state of a whole private store at one time | checkpoint, backup |
| Private store | The set of objects that belongs to one program. No other program sees it (P8, P9) | home directory, app data, container |
| Document | An object that belongs to the person and not to one program. The document service grants it (P8) | file, user file |
| Module store | The set of all modules and system data, each identified by content hash (P11) | package store, repository, the Nix store |
| System description | The list of hashes that defines one version of the whole system (P11) | image, generation, manifest, profile |
| Distinct result | One content of one output of a build (a module, its LLVM IR, its object, the boot program) among the contents that several builds of the same source gave. One source must give one distinct result for each output (P11). `kerneltool repeat` counts them, and `check` and `repeat` keep each one in `build/different_builds/` | variant (except in the names of the kept files), version |
| Storage service | The service that owns the block device and gives objects, versions and private stores (P9) | file system |
| Root block | The block of the data disk that names the private stores. The disk has two places for it; the storage service takes the valid one with the highest generation | superblock, uberblock, meta page |
| Commit | One change of the stores: the storage service writes new blocks, then a new root block. A commit is on the disk completely or not at all | transaction (for this), save, sync |
| Generation | The number of a commit. Each commit has the generation of the one before plus 1 | epoch, transaction id, version (for this) |
| Damaged object | An object with a block that a valid root block names and that does not have its check. The storage service does not give its bytes; a write or a remove replaces it. A private store with such a table is a damaged store | corrupt file, bad sector |
| Check | The first 8 bytes of the BLAKE3 hash of a block, kept in the block that names it. A block that does not have its check is wrong, and the storage service does not use it | checksum, CRC, digest |

## Desktop

| Term | Definition | Do not use |
|---|---|---|
| Surface | A region of shared memory that one program draws into and the compositor displays (P18) | window buffer, framebuffer (reserved for the UEFI one) |
| Picture | One complete image in the memory of a surface. A surface has one picture or two. With two, the program draws one while the compositor reads the other | back buffer, front buffer, swap chain |
| Compositor | The service that owns the display, combines surfaces and routes input to the program with focus. In the first milestone it is also the desktop shell | window manager, display server |
| Damage rectangle | A rectangle of the screen that changed. The compositor draws again only the damage rectangles of a frame | dirty region, invalid area |
| Boot display | The picture of how the machine started, drawn from the boot record and the other records of the kernel. The boot program and the root service draw it on the screen; the program `boot` draws it in a window | splash screen, boot log, POST screen |
| Console | A normal program that calls commands in a real programming language (P19). It has a terminal and no surface: it writes text records, and reads key records | TTY, shell |
| Desktop shell | The program that starts programs and shows surfaces and grants to the person | window manager |
| Focus | The state of the window in front: its program receives the keys, and the pointer events over its surface. Its title bar is blue | active window, keyboard owner |
| Title bar | The top part of the frame of a window: the title and the close button. The title bar of the window that has the focus goes from blue to a darker blue toward the right; the others are quiet (`docs/DESIGN.md`, section 9) | header, caption, decoration |
| Bar | The line at the top of the screen that the compositor draws: the name of the system, the buttons of the two menus, the key of the launcher, the time since the start. `support/bar` holds its places and the table of the names of the programs | task bar, panel, dock |
| Menu of the programs | The menu of the bar with one line for each name of the table `bar.names`. A press on a line starts the program | launcher, start menu |
| Menu of the windows | The menu of the bar with one line for each window. A press on a line brings the window to the front and gives it the focus | task bar, window list, switcher |
| Launcher | The panel in the middle of the screen that the key super opens. The person types a part of a name, and the list has the names of `bar.names` that contain it, the names that start with it first. Enter starts the chosen program, as the menu of the programs does | run dialog, command palette, menu of the programs |
| Interface package | `support/interface`: the code that builds the window of a program as a draw table each frame, lays it out on the grid, takes the pointer and the keys, finds the damage and draws (`docs/INTERFACE.md`) | toolkit, widget library, UI framework |
| Draw record | One thing to draw, 40 bytes: a rectangle, a gradient, a run of text or a clip, with its place and its colors (`docs/INTERFACE.md`, section 2.1) | draw command, display list item, primitive |
| Draw table | The draw records of one frame of a window, and the bytes of their texts, in the memory of the program | display list, command buffer, render tree |
| Text grid | A grid of text cells of a program (a character, reverse, a color), drawn by one draw record; the difference compares its cells and damages only the rows spans that changed (`docs/INTERFACE.md`, section 2.4) | character matrix, screen buffer |
| Picture record | A draw record that shows the pixels of a picture of the program, with a generation that changes when the pixels change | image node, bitmap item |
| Line record | A draw record of a straight line between two points, with a thickness and a color; a line and its reverse are one record (`docs/INTERFACE.md`, section 2.5) | stroke, path, polyline |
| Element | A part of a window that one call of the interface package draws: a card, a line of a label and a value, a bar, a table, a button, a list with a choice, a text input | widget, control, component, view |
| Element identity | A number that names one element from one frame to the next, made from a text: the focus and the pointer state follow it | id, key, handle (reserved for the kernel) |
| Interface state | What the interface package keeps between frames, in the memory of the program: the element with the focus, the element under the pointer, the pressed element, the order of the focus | UI context, retained state |
| Damage by difference | The damage rectangles that the interface package finds by a comparison of the draw table of this frame with the draw table of the frame before | dirty tracking, invalidation |
| Pointer | The mark on the screen that the pointing device moves. Its place is a point of the screen: a press acts there. The compositor draws it with the pointer picture of the pointer shape that it chose. Not the caret | cursor, mouse cursor, mouse pointer |
| Pointer shape | What the pointer shows, as one name of the system (`pointer_pictures.Pointer_Shape`): `arrow`, `text`, `move`, `wait`, ... The compositor chooses it from what is under the pointer; a program asks for one over its own surface (`docs/POINTERS.md`) | cursor type, cursor name, cursor kind |
| Pointer picture | One image of one pointer shape at one nominal size, for one frame of an animation: its width, height, hot spot, delay and pixels with premultiplied alpha | cursor image, sprite, icon |
| Hot spot | The pixel of a pointer picture that the compositor puts at the place of the pointer | click point, hotspot, anchor |
| Nominal size | The size in pixels that a theme gives to a pointer picture, to choose among its sizes. The width and the height of the picture can differ from it | cursor size |
| Pointer theme | The pointer pictures of each pointer shape, with a name, a license and an attribution. The system has its own theme in the repository; the theme of the owner comes from a build input | cursor theme, icon theme |
| Pointer theme file | One pointer theme in the format of the system (`contract/pointer_pictures`): a header, a table of shapes, a table of pictures, the pixels. A program maps it and reads it with no parse, after one validation | cursor file, .cur, Xcursor file (for this) |
| Pointer manifest | A text file of the repository that says how the tool makes a pointer theme file: for each pointer shape, the files of an Xcursor theme or grids of squares, and the adjustments (`docs/POINTERS.md`, "The manifest") | config, recipe, index.theme |
| Premultiplied alpha | A form of a pixel whose red, green and blue are already multiplied by its alpha. A blend is then `result = source + destination * (255 - alpha) / 255` for each channel | straight alpha (for this) |
| Resource | A file of the boot image that is not a module: a pointer theme file or the glyph cache of the vector font. It has a name and the hash of its bytes, in the resource table of the boot image. The root service gives a program a read-only mapping of it | asset, data file, blob |
| Caret | The mark in a text input of the place where the next typed character goes. Not the pointer | cursor, text cursor, insertion point |
| Picker | The surface of the document service where the person chooses a document. Its result is a grant | file dialog, powerbox |

## Text

| Term | Definition | Do not use |
|---|---|---|
| Font | A set of glyphs of one design, with the measures that place them. The system has two: the vector font of the glyph cache (the default) and Spleen 8x16 (the fallback) (`docs/FONTS.md`) | typeface (for this), font face |
| Glyph | The form of one character in one font | character (for the form), symbol |
| Outline | The closed contours of line segments and quadratic curves that bound a glyph, in units of its font (TrueType `glyf`) | path, vector shape, Bézier |
| Coverage | The part of a pixel, or of a third of a pixel, that a glyph covers: 0 to 255 | alpha (for this), opacity, mask |
| Subpixel band | One of the three color stripes of a pixel of the screen, red, green and blue, side by side; the vector font has a coverage for each one | subpixel, ClearType, LCD stripe |
| Grid fit | The move of the baseline, the x-height and the cap height of a font onto whole pixels, so that the tops of the letters are sharp. The system has no other hinting | hinting (alone), autohint |
| Glyph cache | The glyphs of one font already drawn, for each character 32 to 126 and each scale of the grid: words of coverage, in one file (`contract/glyph_cache`). The kernel tool makes it at build time; it is a resource of the boot image | atlas, texture cache, glyph bitmap |
| Proportional cache | A glyph cache with `FLAG_PROPORTIONAL`: each character has its own advance, each glyph is the box of its ink at each subpixel position, and the cache has the pair adjustments. A cache with no such flag is monospace: one position, each glyph inside its cell, no pair (`contract/glyph_cache`, `validate`) | proportional font cache |
| Setting | One choice of the person that changes how the system works for each program: the font, the order of the subpixel bands. The program `settings` changes it | preference, option, configuration |
| Settings page | The one page of the settings of the person (`contract/settings`): the root service creates it; the program `settings` writes it; each program with a surface reads it | registry, config file, dconf |
| Monospace font | A font whose characters all have one advance, so that a text is a row of equal cells: Paper Mono, and Spleen 8x16. The font of the terminal, the console, and each text that a person compares character by character (`docs/FONTS.md`, section 12.6) | fixed-width font (for this), terminal font |
| Interface font | The proportional font of the titles, the labels, the buttons, the menus and the bar: B612 (designed, not built; `docs/FONTS.md`, section 12) | UI font, system font (for this), sans |
| Advance | The distance from the origin of a glyph to the origin of the next one, before any pair adjustment | width (for this), pitch |
| Pair adjustment | The change of the advance that a font gives for one pair of glyphs that follow each other (`kern` format 0, or a pair lookup of `GPOS`) | kerning pair (for this) |
| Text shaping | The step that turns the characters of a text into placed glyphs with a font: here the advances and the pair adjustments only; no ligature, no other script (`docs/FONTS.md`, section 12.3) | layout (for this), typesetting |
| Placed glyph | A record of 16 bytes that text shaping gives for one character: the glyph, its x from the origin of the run and its advance, in 1/64 of a pixel | positioned glyph, glyph run entry |
| Subpixel position | The fraction of a pixel where a glyph starts. The glyph cache of a proportional font keeps each glyph at three: 0, 1/3 and 2/3 of a pixel | subpixel offset, bucket |
| Spacing | The advances of the characters 32 to 126 and the pair adjustments of one font at one scale, in 1/64 of a pixel: the two tables that text shaping reads, from a glyph cache (`support/text_shaping`, `Spacing`) | metrics (for this), kerning data |
| Text range | A record that names one text in a table of bytes by its first byte and its count, with its width, which the measure writes (`text_shaping.Text_Range`) | span (for this), slice |
| Boot pass | The start of the program `settings` that the root service makes at boot, with no window: it reads the settings kept in its private store, writes the settings page, and stops | init script, startup hook |
| Blend table | The results of the blend in linear light of one text color over one pixel color, for each coverage of each channel, kept in the memory of a program (`graphics.Blend_Tables`) | lookup table (alone), LUT |

## Randomness

| Term | Definition | Do not use |
|---|---|---|
| Random seed | 32 bytes from which a random generator starts. The starter of a program writes the seed of the program in its context values 9 to 12; the root service gathers its own (`docs/RANDOMNESS.md`) | entropy (for this), salt |
| Random generator | The record of fixed size in the memory of a program that gives it random bytes: ChaCha20 with fast key erasure (`support/random`). A draw makes no kernel entry and no call | RNG, PRNG, CSPRNG (for this), /dev/urandom |
| Entropy report | What the root service found when it gathered the seed of the system: the sources (rdseed, rdrand, the cycle counter), their good and refused values, and the seed strength | entropy estimate |
| Seed strength | The strongest source that gave all its values to the seed of the system: entropy (rdseed), processor (rdrand), or weak (the cycle counter only, counted as 0 bits) | security level |
| Cryptography module | The module `cryptography`: the primitives that the system took from Odin's `core:crypto`, as exports with the memory of the caller and error records (`docs/CRYPTOGRAPHY.md`) | crypto library, libcrypto |
| Not authentic | The error kind of a sealed text whose tag, or of a message whose signature, does not verify. The call gives no byte | MAC failure, bad tag |
| Compatibility layer | The packages of `support/cryptography` that give the code taken from Odin the helpers of its origin, over the primitives of this system (`docs/CRYPTOGRAPHY.md`) | shim, polyfill |

## QUIC

| Term | Definition | Do not use |
|---|---|---|
| Connection identifier | The bytes (0 to 20) by which a QUIC endpoint names a connection in each packet, independent of the addresses (RFC 9000, section 5.1). Each side chooses the identifiers that the other side sends to it | connection ID (in prose), CID |
| Packet protection | The AEAD that encrypts the payload of a QUIC packet and authenticates its header, with the key and the iv of one direction of one encryption level (RFC 9001, section 5.3) | encryption (for this), record protection |
| Header protection | The mask that hides the low bits of the first byte and the packet number of a QUIC packet, made from a sample of the protected payload (RFC 9001, section 5.4) | header encryption |
| Encryption level | One of the sets of keys of a QUIC connection: Initial (from the connection identifier), Handshake, 0-RTT and 1-RTT (from TLS). Each packet type uses one level | epoch, key phase (for this) |
| Packet number space | The sequence of packet numbers that one encryption level uses (Initial, Handshake, application data); a packet number is unique in its space | sequence number (for this) |
| Initial packet | The first packets of a QUIC connection, protected with keys that any observer can compute from the connection identifier: they carry the start of the TLS handshake | handshake packet (for this) |
| Raw public key | A public key that a TLS peer sends in its Certificate message alone, with no certificate around it: the SubjectPublicKeyInfo of the key (RFC 7250). The other side trusts it when it is the key that its caller pinned | self-signed certificate (for this) |
| Pinned key | The one public key that the caller of a TLS client gives it as the key of the server: any other key is refused | trust anchor, root certificate |
| Transcript | The handshake messages of TLS, in order, whose hash the key schedule and the Finished messages use | handshake hash (for the bytes) |
| Key schedule | The secrets of TLS 1.3, each one from the one before with HKDF and a transcript hash: early, handshake, master, and the traffic secrets of each side (RFC 8446, section 7.1) | key derivation (for the whole) |
| Alert | The reason of a failure of TLS, one byte (RFC 8446, section 6). QUIC sends it as the error code 0x100 + alert | TLS error (for this) |
| Frame | One unit of the payload of a QUIC packet: a type, then its fields (RFC 9000, section 19). A packet carries one frame or more | message (for this), chunk |
| Ack-eliciting packet | A packet with a frame other than PADDING, ACK and CONNECTION_CLOSE: the peer must acknowledge it | reliable packet |
| Probe timeout | The time after which a side that has no acknowledgement sends one or two probe packets, from the round-trip time and its variation (RFC 9002, section 6.2). It doubles at each timeout without an acknowledgement | retransmission timeout, RTO (for this) |
| Congestion window | The most bytes of ack-eliciting packets that a side has in flight. This layer keeps it fixed at 12 000 bytes | send window (for this) |
| Flow control limit | The largest offset of data that a side allows the peer to send, for one stream (MAX_STREAM_DATA) and for the connection (MAX_DATA). Data past it closes the connection with FLOW_CONTROL_ERROR | receive window (for this) |
| Anti-amplification limit | A server that did not validate the address of a client sends at most 3 times the bytes that it received from it (RFC 9000, section 8.1) | |
| Address validation | The proof that a client receives at its address: here, a Handshake packet of the client, which needs the keys of the server's flight | |
| Handshake confirmed | The point after which a side drops its Handshake keys: a server when the handshake completes, a client when HANDSHAKE_DONE comes (RFC 9001, section 4.1.2) | handshake done (for the state) |
| Handshake deadline | The time after which a connection whose handshake did not complete ends: 10 s from the start of a client, or from the first authentic Initial at a server | handshake timeout (for the value) |
| Packet number floor | The packet number below which a side refuses each packet of a space, because its set of received numbers forgot those ranges | replay window |
| Idle timeout | The time with no packet of the peer after which a side ends a connection with no packet: the smaller of the two that the sides give, and 3 probe timeouts at least | keep-alive |
| Closing state | The state of a side that sent CONNECTION_CLOSE: it answers each packet with it, for 3 probe timeouts | |
| Draining state | The state of a side that received CONNECTION_CLOSE: it sends nothing, for 3 probe timeouts | |
| Transport parameters | The values that each side of QUIC gives the other in the handshake of TLS: its limits, its timeouts, and the connection identifiers that it used (RFC 9000, section 18) | settings |
| Retry packet | A packet of a server that asks the client to send its Initial packet again with a token, to prove its address; its integrity tag uses a fixed key | redirect |

## Project

| Term | Definition | Do not use |
|---|---|---|
| Changelog | The file `CHANGELOG.md`: the releases of the system, newest first, in the format of Keep a Changelog 1.1.0. Each entry says what the system does since that release, for a reader of the system | release notes (for the file), history, news |
| Release | One section of the changelog: a release number, a date, and the entries of the changes, in the parts Added, Changed, Deprecated, Removed, Fixed and Security. The merge of step N on `master` is one release | version (a stored object has versions), tag, build |
| Release number | The number of a release, `<major>.<minor>.<patch>`: `0.N.0` for step N, `0.N.1` for a correction after it. `RELEASE_NUMBER` in `contract/release` is the newest one | version number, version |
| Fragment | One file of `changelog.d/` with one change that is not in a release yet: its type and the text of its entry. `kerneltool changelog release` moves the fragments into a release | changeset, news file, entry (for the file) |

## Terms that the system does not have

These words name concepts that the system removed. Use them only to describe other systems.

file, path, directory, pipe, socket (as an object), signal, fork, environment variable, `argv`, standard input and output, user, group, root, installer, driver (in the kernel), system call table, TTY, shell script, save.
