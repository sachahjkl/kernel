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
| Error record | The record that a call that failed gives back to its caller (`errors.Error_Record`, 56 bytes, seven Integer fields): the error kind, the unit, the operation or export, the number of the argument, the value that it had, the limit, and what the system found. A kernel operation gives it in its completion record; an export writes it at an address that the caller gives. It holds values only. Zero is no error (`MODULE_CONTRACT.md`, section 8) | errno, exception, error code, detail record, error message |
| Error kind | What an error record says is wrong: an empty argument, a handle that was revoked, a budget that cannot pay, ... (`errors.Kind`). The documentation of an export names the kinds that it gives | error code, errno value, exception type |
| Frame pointer | The register `rbp` of a function: the address of the frame of the function on the stack, where the frame pointer and the return address of its caller are. Each module keeps it (rule 8 of `MODULE_CONTRACT.md`) | base pointer, frame record |
| Stack trace | The return addresses of the calls that led to the instruction of a fault, from the frame pointers, each with the module record that holds it. Part of a stop report | backtrace, call stack (for this), unwind |
| Module record | What the kernel keeps of one module in a program: its addresses, its hash, and the hash that a replacement put it in place of. The loader writes it; the kernel does not read the module. The module records of a program that runs are its identity | link map entry, loaded image list |
| Table | Records of one record description that follow each other in memory, and their count. A Table result is written by the callee in memory of the caller, with the count of the full table (P12, P19). The console holds a table as one value | list, array (for this), result set, rowset, data frame |
| Information function | A function that reads the flat tables of modules, the module records of the kernel or the replacement table, and fills a table in memory of the caller (`support/information`). It allocates nothing and keeps no state (P12) | query, reflection API, introspection |
| Catalog | The input of an information function: the modules that a program can see, and the replacements of the machine. Today: the boot image that the program was granted, and the records of the replacement table | registry, repository, package database, index |
| Problem | The error value that a reader of input that nobody checked gives for a rule that the input breaks: the kind, where (the table and the record of a module, or the layer of a frame), the byte, the bad value and its limit. An information function gives one for a module (`information.Problem`); the network service gives one for a frame (`datagram.Problem`) | exception, errno, error code |
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
| Lock order | The order of the kinds of locks of the kernel: control, program, origin, region, frame, log, wait, run. A processor takes a lock only if it holds no lock of a later kind, so no deadlock exists | lock hierarchy, lock ranking |
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

## Access

| Term | Definition | Do not use |
|---|---|---|
| Handle | An index and a generation in the handle table of a program. It names one object with a set of rights. Handle 0 names no object (P2) | file descriptor, capability, token, reference |
| Memory object | Pages that the kernel names by handle. Each page has a page frame, or gets one at its first use. Programs map it; two programs that map the same one share it | region, shared memory segment, buffer |
| Page on first use | A page of a memory object that gets its page frame at the first read or write, by a program (a page fault) or by the kernel. The frame is all zero. The budget paid for the page when the memory object was created | lazy allocation, demand paging, demand-zero page |
| Reserved page | A page that a budget paid for and that has no page frame yet. The kernel keeps one free frame for each reserved page, so an access never fails for lack of memory | overcommit |
| Frame list | The record of the page frames of one memory object: in the kernel record of the object for at most 4 pages, else in list pages that the budget pays for | page list, radix tree |
| Right | One permitted kind of operation on the object of a handle. The rights are Give, Read, Write, Execute, Control, Inspect, Devices, Stop, Spend and Physical. A grant can remove rights and cannot add one | permission, privilege, mode |
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
| Confirmed place | A place of the pointer that the test tool read from the compositor (`compositor.pointer()`, through the remote service) before a press: the tool moves the pointer again until the compositor has it at the place that the step wants | pointer sync, warp |
| Request number | The number that the host gives to a call request; each datagram of its call answer has it. A call request with the number of the last call answer gets that call answer again: the call does not run two times. 0 is no request | sequence number, request id, transaction id |

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
| Picker | The surface of the document service where the person chooses a document. Its result is a grant | file dialog, powerbox |

## Terms that the system does not have

These words name concepts that the system removed. Use them only to describe other systems.

file, path, directory, pipe, socket (as an object), signal, fork, environment variable, `argv`, standard input and output, user, group, root, installer, driver (in the kernel), system call table, TTY, shell script, save.
