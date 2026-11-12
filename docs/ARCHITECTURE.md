# Architecture

This document names the key systems and shows how they connect.
It does not design the inside of each system.
`PROPERTIES.md` gives the rules that each system must obey. References such as (P4) point to a property number.

## Vocabulary

`GLOSSARY.md` defines every term of this document.

## The whole system

```mermaid
flowchart TB
  subgraph programs["Programs: sandboxed, no access at start"]
    app1["Program"]
    app2["Program"]
    shell["Desktop shell"]
  end

  subgraph services["Services: user space, reached through rings"]
    compositor["Compositor"]
    documents["Document service"]
    storage["Storage service"]
    network["Network steering service"]
    unitstore["Module store and loader"]
    root["Root service"]
  end

  subgraph devices["Device services: user space, one per device class"]
    blk["Block"]
    net["Network card"]
    gpu["Display"]
    input["Input"]
    tpm["TPM"]
  end

  subgraph kernel["Kernel: control plane only"]
    handles["Handle table"]
    memory["Memory"]
    sched["Scheduler"]
    rings["Rings and wait"]
    devgrant["Device grant and interrupts"]
  end

  subgraph machine["Machine: QEMU, virtio, UEFI, TPM 2.0"]
    hw["virtio queues, framebuffer, timers"]
  end

  programs -- "rings (shared memory)" --> services
  services -- "rings (shared memory)" --> devices
  devices -- "device queues, mapped once" --> hw
  programs -. "few kernel operations" .-> kernel
  services -. "few kernel operations" .-> kernel
  devices -. "few kernel operations" .-> kernel
  kernel --> hw
```

Solid arrows carry data. They do not enter the kernel (P5, P6).
Dotted arrows are kernel operations. They set up mappings, transfer handles, and wait.

The same picture in text:

```
 Programs            program   program   desktop shell
                        |         |           |
                  ======|=========|===========|======  rings in shared memory
 Services          compositor  documents  storage  network  module store  root
                        |         |           |
                  ======|=========|===========|======  rings in shared memory
 Device services     display    block    network card   input   TPM
                        |         |           |
                  ======|=========|===========|======  device queues, mapped once
 Machine             virtio queues, framebuffer, timers

 Kernel (at the side of every layer, not between the layers):
   handle table | memory | scheduler | rings and wait | device grant and interrupts
```

## Kernel systems

The kernel has five systems. Each one owns a small set of flat tables (P13).

### K1. Handle table

- **Does**: Keeps, per program, the table of handles. Checks the type and the rights of each handle that a kernel operation receives. Moves and copies handles between programs.
- **Owns**: one object table per object type; one handle table per program.
- **Object types**: memory region, address space, program, thread, ring, device queue, interrupt source, timer.
- **Does not**: know names, paths, users or files.

### K2. Memory

- **Does**: Tracks physical page frames. Builds address spaces. Gives "reserve address space", "commit pages", and "map this region in that program" (P14).
- **As implemented**: `Memory_Create` reserves: the budget pays for each page, and each page gets its page frame at its first use, by the program (a page fault) or by the kernel. The flag `Frames_Now` gives all the frames at creation. Map is a separate operation. No access fails for lack of memory: a reserved page always has a free frame. A page table lives while a mapping holds an entry in it, and returns to the budget that paid for it with the unmap that empties it.
- **Owns**: the page frame table; one address space record per program; the frame list of each memory object.
- **Does not**: page to disk, cache files, or allocate hidden memory for a caller.

### K3. Scheduler

- **Does**: Chooses which thread runs on each processor. Keeps time. Wakes threads.
- **As implemented** (`docs/SCHEDULING.md`): three strategies behind one table of six functions (round robin, fair, EEVDF), one for the whole machine, which a program with the right Schedule changes while the system runs (`Strategy_Set`). Wake preemption, also on another processor. A weight and a request for each thread, at its creation.
- **Owns**: one run queue per processor; the thread table, split in a hot part and a cold part.
- **Does not**: know about priorities of services by name. Policy is data that the root service sets.

### K4. Rings and wait

- **Does**: Creates a ring as a memory region with a fixed layout. Gives the one blocking operation of the system: "wait until one of these rings has entries". Executes the commands that programs put in their kernel ring.
- **Owns**: the ring table; the wait table.
- **Note**: A program has one ring to the kernel. All kernel operations except "enter and wait" are records in that ring. This keeps the count of kernel entry points near one (P1, P4).

### K5. Device grant and interrupts

- **Does**: Maps the queues and registers of one device into one device service. Turns each interrupt into a completion record in a ring. Programs the IOMMU so that a device reaches only the memory of its service.
- **Implemented**: device memory over the registers of a device (`Device_Create`, kind `Memory`), message interrupts (kind `Message`), and the physical address of a memory object for a holder of the right Physical (`Memory_Physical`). The root service finds the devices on the bus, not the kernel. Not done: the IOMMU.
- **Owns**: the device table; the interrupt routing table.
- **Does not**: contain code for any device (P7).

### What the kernel does not contain

File systems, network protocols, device drivers, the module loader, the module store, graphics, the TPM protocol, names, users.

## User-space systems

### U1. Boot program

A UEFI program (P17). It runs before the kernel. It holds the kernel module, the boot image and the public key of the signing key.

- Verifies the description signature, then compares the kernel module and each module and resource of the boot image with the system description (`docs/TRUSTED_BOOT.md`). A failed check stops the boot: the boot display shows the file and the two hashes, and the kernel does not start.
- Asks the firmware to measure the system description into PCR 11 of the TPM, and reads the register back.
- Loads the kernel module.
- Collects the memory map, the framebuffer and the device list.
- Gives all of this to the kernel in one fixed structure, with the trust record, then leaves the firmware.
- Nothing verifies the boot program itself until Secure Boot is built: its checks find a damaged or swapped file, not an attacker who can write the boot volume.

### U2. Root service

The first program. The kernel gives it every handle that exists at boot.

- Starts the other services and gives each one only the handles that it needs.
- Holds the system description and the grant records. Before it starts the first program, it checks each module and resource of the boot image against the system description that the boot program verified (`docs/TRUSTED_BOOT.md`, claim 5).
- Is the only program that can create access from nothing. All other access is a handle that came from it, directly or through a chain.
- Holds the records of the principals, and records for each program that it starts the principal of its session; it names that principal in each connection, in the name of each store and in the grants of the program (`docs/PRINCIPALS.md`).

### U2b. Resources of the boot image

A resource is a file of the boot image that is not a module: data that a program reads in place, such as a pointer theme file (`docs/POINTERS.md`). This section is the one description of the mechanism; each kind of resource has its own format and its own document.

- **In the image** (`contract/boot_info`): after the table of the modules (`Image_Header.count` entries), a second table of `Image_Header.resource_count` entries of the same record, `Image_Entry`: a name of 31 bytes at most, the BLAKE3 hash of the bytes, the offset and the size. Each file starts on a page. A reader of modules reads the first table only, so a resource is never taken for a module; an image with `resource_count` 0 has no resource.
- **Identity** (P11): the hash of the bytes, as for a module. The name is for people and for the code that chooses.
- **The build** (`tools/kerneltool/modules.odin`, `build_boot_image`): a command of the tool makes each resource in `build/` (`kerneltool pointers` today), and `build` puts it in the image with its hash. The same input gives the same bytes: `kerneltool check` builds each resource two times and compares them.
- **The grant** (P8, P20): no program reads the resource table by itself. The root service finds a resource by its name, checks the hash of its bytes against the entry, and gives it to one program as a read-only mapping of the pages of the image at an address of the context, with its size in a value of the context (`programs/root/resources.odin`, `resource_mapping`; the log has "root: the resource pointers_posy (883008 bytes, its hash checked in 1395 us) is given to compositor, read-only"). The program validates the bytes with the reader of its format: the root service checks the identity, not the format. A program with the grant `Image` (the whole image, read-only) finds resources with `system.image_resources` and `system.image_resource_find`.
- **Users**: the compositor (the pointer theme file, `programs/compositor/pointer_picture.odin`) and the program `pointers` (all pointer theme files, through the grant `Image`). The glyph caches of the vector font and of the interface font (`docs/FONTS.md`, section 5): the root service checks the hash and the format of each one once at start and maps it into each program with a surface, each terminal and the compositor, with the settings page, at their fixed ranges (`programs/root/text_settings.odin`). The size of a cache is in its own header; the context says only which ranges are mapped ("The fixed ranges that a program receives", below).

### U3. Module store and loader

- **Store**: keeps modules by content hash. Answers "give me the module with this hash". It has no separate index: functions read the flat tables of the modules (P11, P12).
- **Loader**: builds a new program. It asks the kernel for an empty address space, maps the segments of the module and of the modules that it imports, and starts it.
- The loader is in user space. The kernel only maps memory.
- The first modules are loaded by the boot program, because the store does not run yet.

### U4. Device services

One service per device class: block, network card, display, input, TPM.

- Each one owns the queues of its device. It translates between the device protocol and the ring protocol of its class.
- For virtio, this translation is thin, because a virtio device is already a set of queues.
- A program with a granted device queue talks to the device with no service in the path (P5).

### U5. Storage service

- Owns the block device queues. Gives transactional object stores (P9).
- Creates one private store per program. Gives versions and clones; a snapshot is the versions of a store at one generation.
- **Implemented** (`programs/storage`): a native engine, with no SQLite. Copy on write with two places for the root block and a check of each block in the block that names it. The storage service is a service with exports; the root service names the private store of each connection and its limit of blocks. The format of the disk is the contract `store`. A block with a wrong check damages its object only: the service serves the others, and does not give the bytes of a damaged object. The open of the disk (`support/storage_mount`) is the same code in the service and in the kernel tool, which checks on the host each image of the disk that a loss of power can leave: the tool serves the data disk with the Network Block Device protocol and knows each write and each flush.

#### Versions (property 9, "no save action, and versions for all programs")

The terms are in `GLOSSARY.md`, section Storage.

- **What a version is.** The state of one object at one commit: its size, its list (and through it its blocks of data), the generation and the time of that commit. A version of a whole private store (a snapshot) is not kept apart: the state of a store at a generation G is, for each object, its version with the highest generation at or below G. So one structure serves both, and a program asks for the versions of the object that the person sees.
- **Who makes it.** Each commit that changes an object: the program makes no call for it. The state before the commit goes into the version index of the object; the new state is the current version. A damaged state (a block with a wrong check) is not kept as a version: the change replaces it. A remove ends the object and its versions (an explicit act of the program).
- **Where it is on the disk** (`contract/store`). The object entry names a version index (one block: up to 254 leaf blocks); a leaf holds 85 version entries of 48 bytes (generation, time, date, size, list). Up to 21590 versions for each object. A commit rewrites the index and the leaf that it changes: 2 blocks, copy on write as each other block. The entry of an object is 104 bytes (72 without the version index): a table has 39 objects (48 with entries of 72 bytes).
- **What a version costs.** Nothing more for its bytes: the blocks of the state before a commit are on the disk already, and copy on write never wrote over them. A commit keeps them in place of making them free. A block of data whose bytes did not change is not written again: the new list names the old block (a shared block), so a change of one block of an object of 32 blocks costs 1 block of data, 1 list, the leaf and the index (and the table and the root, as before). The version holds the blocks that only it names: its list and its changed blocks. The extra writes of each commit: the index and the leaf (2 blocks), and one read of each.
- **The accounting.** The blocks of a store are its distinct blocks: a shared block is counted one time (the reference count of each block, in the memory of the service, made again by the open from the disk). The limit of the store (the grant of the root service) counts the versions too: a program cannot fill the disk with versions (P20, and the rule of the budget: each thing is paid by its owner).
- **Thinning.** The retention rule: each version is kept 10 minutes; after that, one version for each hour (the newest of the hour) until it is one day old; after that, one for each day. The service applies it to an object at a commit of that object, at most one time each minute (a full read of its leaves). At the limit of the store, a change that does not fit thins the oldest versions of the store (the lowest generations, in any object of the store), in the same commit as the change, until it fits: a commit is still one change, and a loss of power never keeps a thinning without its change. The order is the generation: the version that the change itself makes can go too, when each other version of the store is newer. A change that does not fit with every earlier version thinned is refused before any thinning, so a refused change destroys no history: Over_Limit, with the blocks that the current objects need with the change and the limit, and the sentence says "with no earlier version kept". The count of the current objects counts a block that two clones share two times: such a refusal can come early.
- **The time of a version.** Each version keeps the time since the format of the disk (the root block keeps it at each commit; the service adds its own time since its start) and the date (seconds since 1970, UTC; 0 when the system had no date). The age of a version for the retention rule is the smaller of its age by the date and its age by the time since the format (`storage_retention.age`): the date counts the time when no machine ran, but a clock can be wrong on one start (an empty battery) and right on the next, and then the versions of the wrong start would look years old; the time since the format never makes a version older than it is. A date at or after the year 10000 is no date. The generation orders the versions in all cases.
- **The exports** (P19, each with a description and error records). `versions(store, name)`: a Table of the versions (generation, time, date, bytes, the blocks that only this version holds). `version(store, name, generation)`: the bytes. `restore(store, name, generation)`: a commit whose current version has the list of that version (no block of data is written); the current version before it becomes a version. `compare(store, name, first, second)`: a Table of the byte ranges that differ: two equal pointers are equal bytes, so only the blocks that differ are read. `clone(store, name, new_name)`: a new object with the same list. The argument `store` is empty for the store of the caller; another store needs a caller that acts for the principal (the console, `remote` for the host): No_Grant Acts_For_Principal else.
- **The open and the checks.** The open walks the versions too: each list once, each block of data once, and it counts the names of each block (32 bits: a disk that the engine wrote cannot pass 39 objects of 21590 versions in a store; a count that would pass 2^32 - 1 refuses its commit with Over_Limit, unit References). A count that the format does not permit is damage, as a wrong check: an index of more than 254 leaves, a leaf of 0 or more than 85 entries, a state whose size needs more than 32 blocks. The count of each store is its recount by the open: the blocks under a wrong block are not counted, and they are free in memory too, so they leave the limit of the store (a root whose count is not the recount, in a store with no damage, is a fault of the engine that wrote it: the log says it, and the open takes the recount). A block of a table, an index or a leaf named two times, a block named from two stores, or a count that passes its type, is a fault of the engine: the service makes no change in those stores until its next start (Damaged, unit Counts), and it gives their objects. A commit that would take a count below 0 is refused in the same way: that is a fault of the engine too.
- **Damaged versions.** A version index or a leaf with a wrong check, or with a count that the format does not permit, does not lock its object: the next commit of the object drops those versions (they are not known) and writes no block in their place; its lists are not released, because the open did not count them. A write or a remove of the object works, and thinning at the limit skips them. `versions`, `version` and `restore` of that object give Damaged until then. A list that goes wrong while the service runs keeps its blocks in use until the next start, which counts again: the safe direction, as no block in use is given to another name.
- **Compaction.** The retention rule leaves a few versions in each leaf. When the index has its 254 leaves and the last one is full, the commit moves the versions to the first leaves, in their order (`storage_mount.version_leaves_compact`), and writes them again: up to 254 reads and 254 writes, one time in many commits. At 21590 versions the oldest goes first.
- **The capacities of one commit.** One commit changes the names of at most 65536 blocks and writes at most 1024. A commit that needs more is refused with Full, unit Commit_Blocks, not with a full disk. No store can reach them today: the largest limit is 4500 blocks.
- **The disk format** is `STORAGE2`: the counts of names change no byte of the disk; the counts of names are in memory only, and the open makes them again from the disk. A disk of `STORAGE1` is not read.

#### The date

- **Who reads the clock.** A small service, `date`, not the kernel and not the root service: a driver is a program (P7), and the root service gives `date` the two ports of the real-time clock (0x70, 0x71) and the date page with Write, and nothing else. `date` reads the clock at its start, then each 10 s: it waits for the clock to change its second, so the date of the time 0 of the system is exact to about one millisecond (the clock gives whole seconds). Each read has a bound: a clock that never ends an update, or whose registers change at each read, gives no date. Each field is checked in its mode (two decimal digits, or binary; 12 or 24 hours) and its range (`calendar.clock_seconds`, host tests).
- **The year.** The clock gives two digits. The century register is not read: only the ACPI table FADT says if a machine has one, and where, and `date` does not read that table. The two digits give 2020 to 2099; 00 to 19 give no date, because a clock with an empty battery starts again at 2000.
- **The cost of the grant.** The processor gives a program a port, not a value of a port, and not a read alone: the port bitmap of the kernel (`ports_allow`) lets `date` write any index to 0x70 and read or write any byte of the memory of the clock, the settings of the firmware and their check included, and set bit 7 of the index (the mask of the non-maskable interrupt). A narrower grant needs a change of the kernel (a kernel operation that reads named registers of the clock for its caller, or a trap of each access to the two ports); none is written.
- **Where the date lives.** The date page (`contract/date`), on the model of the settings page: one page that the root service creates, with one writer, mapped read-only at a fixed address into each program that the root service starts (its bit in the context value 20 says that it is mapped). It holds the date of the time 0 of the system, in milliseconds since 1970 UTC. The date of now is that plus `system.time()`: no kernel entry and no call. A change of the page is guarded by an even and odd counter, as the settings page. A reader of the page gives up after 64 reads of a page that changes, or that a writer left in the middle of a change (a writer stopped between its two stores): it gives no date then, and never waits on another program. A date that is not from 1970 to 9999 is no date.
- **The fixed ranges that a program receives** (`contract/fixed_addresses`; the value 20 of the context, `CONTEXT_VALUE_FIXED_RANGES_MAPPED`). The value is a set of bits: bit n for the member n of `Fixed_Range`. The starter sets the bit of each fixed range that it maps for the program; a program reads nothing at a range whose bit is clear. A bit is the statement of the starter: a starter that sets a bit with no mapping makes its child fault at its first read there, and a program trusts its starter, which already chooses its grants and its budget. What each range uses today to say "mapped":

| Range | How the program knows that it is mapped |
|---|---|
| The settings page, the date page | Their bits |
| The five glyph caches | Their bits; each cache states its size in its header (`glyph_cache.validate_at`, bounded by the span of the range) |
| The pointer themes | The values 6 and 7, 18 and 19 of the compositor: an address and a size each. A value, not a bit: the size is needed, and the theme file does not state it in a header that the reader trusts before its validation |
| The storage file | The value 3 of the storage service: its size. A value, not a bit: the size is needed |
| The files of a module | The values 0 to 3 of `contract:isolated` (address, size, the replacements): values, not bits, because the sizes are needed |
| The tables of an export | Mapped by the receiver itself for the time of one call, from the call region: no starter, no bit |

- **What a program does with it.** `support/calendar` gives the year, the month, the day, the time of day and the weekday from seconds since 1970, and back (the algorithm of eras of 400 years), the text of ISO 8601 and the date of HTTP (RFC 9110, IMF-fixdate). Host tests check known dates, the leap years 2000 and 2024, the year 2100 (no leap year), dates before 1970, and each day from 1900 to 2500.
- **The time zone**: a setting of the person, in the page (`zone_offset_seconds`), but no program sets it: the settings service has no such setting yet. The date is in UTC, and the bar says nothing more.
- **Leap seconds** are ignored: a day has 86400 seconds, as in POSIX time and in the real-time clock.
- **Drift.** Between two reads the date follows the time of the system (the cycle counter, with the frequency that the kernel measured at boot). That time drifts: in a full check on a loaded host it ran 22 s behind the clock in 5 minutes. So `date` reads the clock again each 10 s and corrects the page: the date can move by the drift of one interval, forward or back. No network time.
- **Who reads it now.** The bar of the compositor shows the date and the time of day; the HTTP server sends the field Date (RFC 9110, 6.6.1); the storage service keeps the date of each commit and each version, and ages the versions by their date for the retention rule; `date.now()` gives it to a caller, with the remote service for the host.

### U6. Document service

- Owns the objects that belong to the person and not to one program.
- Shows the picker that lets the person choose a document. Returns a handle to the program that asked (P2, P8).
- Records each grant, so that the person can list and revoke them.

### U7. Network steering service

- Owns the network identity of the machine: address, ports.
- Gives a program a network queue and a port range, then leaves the data path.
- The TCP stack is a library inside each program (P5).
- **Implemented, first layer** (`programs/frame`, `programs/network`, `contract/frame`, `contract/datagram`, `support/network`): the frame service drives the virtio network device; the network service is its one client and gives each program with the grant one endpoint of UDP datagrams, with a grant of one remote. This differs from the lines above: the virtio device of QEMU has one pair of queues, so the network service is on the data path (one copy) and writes the headers of UDP and IPv4 that it must check anyway. TCP and QUIC are libraries in the program.
- **TCP** (`support/tcp`, `programs/server`, `programs/fetch`): the design is in `NETWORK.md`. TCP is a library in the program; the network service checks each segment against a client grant or a listen grant, and keeps no state of a connection.

### U7b. The remote service

- The calls of the host: the program `remote` holds an endpoint whose grant names the host, and connections to the services that the root service names for it. The tool encodes an isolated call with the description of the export; `remote` relays it and sends the typed result back. See `MODULE_CONTRACT.md`, section 4, "A call from the host".

### U8. Graphics: WebGPU library and compositor

- **WebGPU library**: the one graphics interface, linked into each program that draws. It has one back end per display type. The first back end is software (P18).
- **Compositor**: a service that owns the display. Each program draws into a surface in shared memory. The compositor combines the surfaces and sends input events to the program that has focus.

### U9. Base library

A set of modules that most programs use. It is not a C library and no program is forced to use it.

- Ring access, with blocking functions built above the rings.
- Arena allocators above reserve and commit.
- Functions that give the information of the modules from their flat tables (P12).
- The TCP library.

### U10. Desktop shell

The program that the person sees: starts programs, shows windows, shows grants. It is a normal program with handles from the root service.

### A text is never cut in silence

No helper of the system cuts a text without saying so. A text that does not fit in its place is one of three:

- **Written whole, in several parts.** The log takes a text of any length: `system.log_in` and `system.log` write the parts of a text in a buffer of 512 bytes, and send it to the kernel as one line each time it is full, after a whole character; the text continues on the next line. `system.log_text` sends lines of 4096 bytes, the text of one Log call. The kernel writes the text of one Log call in as many log records (176 bytes each) as it needs, chained by `more`: no byte of a call is lost. A terminal writes a run in as many records as it needs.
- **Cut with the cut mark.** The start of the text, after a whole character, then "... and N bytes more" (`contract:cut_mark`, the one form; the kernel and the programs share it). The writer of `support/sentence` counts the bytes that its buffer does not hold (`Writer.dropped`), and `written` ends its text with the mark: each sentence, each `format`, each text that a program builds with it. The kernel ends a record of its own that passes its 352 bytes with the mark. A Text field of a record of the information functions (`information.text_put`) ends with it. A line that a terminal record holds whole (the edit line, the status) ends with it past 256 bytes.
- **Refused, with an error that the caller takes.** An export with a Text result gives the count of the whole text: a caller whose buffer is smaller sees it and says so ("the result of ... has N bytes: it does not fit"). The storage service and `settings.get` give that count. The console refuses a name longer than the 31 bytes of a name of the root ring, because a cut name can be the name of another program. The kernel refuses a Log call of more than 4096 bytes.

A text cut to the box where it is drawn is not this fault: the eye sees where the box ends. The ring of the log keeps its last 1023 records; a reader that comes late counts the records that it did not read, and says it (the program `log`: "N lost").

The tool checks a part of the rule on the sources (`text_cut_check` in `kerneltool check`): outside `support/sentence`, no source sets the count of a variable `writer` by hand, and none reads its buffer by hand. It reads text, not types: a writer of another name escapes it.

## Locks of the kernel

The kernel runs on all processors with no single lock: no kernel entry takes a lock for all the kernel. The code follows this section. A lock protects data: a table, or a part of a table. It does not protect a code path.

### The data of the kernel

Paths: **op** a kernel operation; **tick** the timer of a processor; **dev** a device interrupt; **fault** a processor exception of a program; **wake** a word wake, an event or a deadline; **revoke** `Handle_Revoke`; **stop** the stop of a program or of a thread.

| Data | Read by | Written by | Protection | Ties to other data |
|---|---|---|---|---|
| `processors`, `processor_count`, `gates`, `kernel_table`, `frame_count`, `cycle_frequency`, `timer_count`, APIC addresses, `boot_record`, `stage_cycles`, `time_region`, `log_head`; the tables of the strategies (`STRATEGIES`) and their lengths in cycles (`fair_latency`, `fair_least_turn`, `fair_wake`, `fair_credit`, `tick_cycles`) | all paths | boot only | none: read-only after boot | |
| Processor record: `slice_left`, `charged_from`, `turn_start`, `busy_time`, `record_thread`, the counts of entries, interrupts, faults and locks, the counts of the scheduler (`picks`, `preemptions`, `moves`, `pick_cycles`), the report buffers, the log text buffer | its processor; reports read the counts (`Processor_Report`, volatile loads) | its processor only | none: data of one processor | |
| Processor record: `current` | its processor; a strategy of its run queue (`eevdf_average`, `thread_ready_held`) on any processor, under the run lock; with no lock: `busiest_queue` (a hint), `Processor_Report`, `kernel_interrupt` of its processor, `processors_with_table` and `sync_acknowledge` (atomic loads) | its processor, in `queue_pick` and `schedule` | run lock of the processor (a running thread has this processor as its home) | `current` names a thread whose `processor` is this one |
| Processor record: `look_first` | its processor (`schedule_pick`) | a waker that wakes it from idle (`kick`); its processor clears it | atomic | a hint: a lost or old value gives the pick of before |
| Processor record: `preempted_at` | a waker of a thread whose home is this processor (`thread_ready_held`) | the same | run lock of the processor | at most one wake preemption by another program in each millisecond |
| Processor record: `preempt_from`, `interrupt_preemptions`, `preempt_cycles` | its processor; `Processor_Report` reads the counts | its processor only | none: data of one processor | |
| Processor record: `table` | `unmap`, the cleanup of a program (which processors to synchronize) | its processor only | atomic store and load, ordered with the page table writes | the page table in `cr3` |
| Processor record: `pending`, `idle`, `preempt` | its processor | another processor sets them (`preempt`: `kick`, after a strategy said that a woken thread preempts); its processor clears them | atomic | `processor_sync`, the wake of an idle processor, wake preemption |
| Processor record: `observed_kinds` | each event point of its processor (an acquire load) | **op** `Events_Set`, **stop** (the end of the table of a program that ends) | control lock; atomic store and load | 0, or the kinds of the rules of the event table ("Kernel events", section 8) |
| Processor record: its ring of kernel events (`event_ring`, `event_records`, `event_capacity`, `event_written`, `event_read_seen`, `event_lost`); `event_table`; the counts of "one in N" | each event point of its processor | its processor at an event point (the counts: atomic additions); the control path only while `observed_kinds` of each processor is 0 and after a `processor_sync` to the others | control lock and that rule ("Kernel events", section 8) | the memory object of the rings has one reference of the kernel while the table exists |
| Processor record: port bitmap, `ports_loaded`, `ports_serial` | the processor (hardware) | its processor only, in `run` | none: data of one processor | the Ports handles of the program that runs; `program.ports_serial` |
| Run queue of a processor: head, tail, count, `weight` (the sum of the weights in the list) | its processor, a processor that takes work from it, a strategy; reports read `count` (atomic) | **op** thread create, **wake**, **tick** (end of a turn), **stop** | run lock of the processor | a thread is in one queue at most |
| Run queue: `strategy`, `virtual` (the queue clock) | the strategy functions, `queue_pick`; reports read `strategy` (atomic) | `strategy`: the first processor at boot (`strategy_start`, before the other processors start), then **op** `Strategy_Set` (`queue_convert`); `virtual`: the strategy functions | run lock of the processor | the strategy fields of each thread whose home is this queue are zero or belong to `strategy` |
| `strategy_chosen`, `strategy_changes` | **op** `Strategy_Set`, reports | **op** `Strategy_Set` | atomic | each queue converts to the value that it reads under its run lock |
| Thread: `state`, `processor`, `home`, queue links, `wait_serial`, `woken`, deadline | **wake**, scheduler, `Thread_State`, reports | **op** (wait), **wake**, scheduler, **stop** | run lock of `home` | Ready and not on a processor: in the queue of `home`. A thread leaves its queue and gets its processor in one section of the run lock |
| Thread: the strategy fields `virtual`, `virtual_deadline`, `lag`, `placed` | the strategy of the queue of `home` (**wake**, **tick**, scheduler, **op** `Strategy_Set`) | the same | run lock of `home` | zero, or the state of the strategy of the queue of `home` |
| Thread: `weight`, `request` | the strategies, `queue_push` and `queue_remove` (`Run_Queue.weight`) | **op** thread create, before the thread enters a list | none: written once, before any other processor reads them | |
| Thread: `program`, `events`, `finished`, `serial` | **dev** and **stop** (`program_event`), scheduler | **op** (create, under the program lock and the control lock), **stop** (`thread_finish`) | program lock of `program`; `serial` changes for each new thread in the slot | a finished thread has `program` 0 and `events` nil, so `program_event` of its old program never reads the slot again |
| Thread: frame, extended state area, kernel ring, `in_enter`, `run_time`, `words` | its processor while it runs; a waker reads `words` of a thread that waits | the processor that runs it | the rule of the owner (below) | |
| Thread: `stop_requested` | the processor that runs it | **stop** | atomic | |
| Thread: `record_in_kernel`, `fault_waits`, `fault_serial`, `fault_address`; program: `fault_handler`, `fault_handler_serial`, `fault_written`, `fault_full`, `fault_serial` | **fault** (`fault_deliver`), **op** (`Fault_Handler_Set`, `Fault_Answer`), **stop** (`thread_finish`) | the same | program lock of the program; `thread.state` and `deadline` of a thread that starts to wait, under its run lock too | a thread with `fault_waits` is `Waiting` with no deadline and has no entry in the table of words; `fault_handler` names a live thread of the program, or 0 |
| Program: `fault_kinds` | **fault** (`fault_deliver`: first with no lock, then under the program lock) | **op** (`Fault_Handler_Set`), **stop** (`thread_finish` of the handler) | written under the program lock with an atomic store; the read with no lock is a filter only | 0 when `fault_handler` is 0 |
| Thread: `references`, `budget` | **op**, **tick** (budget) | **op**, budget end | `references` atomic (a copy of a handle in its own program adds 1 with no control lock); `budget` written under the frame lock | |
| Wait table: buckets of entries (word, thread, serial) | **wake** | **op** (`Word_Wait`), the start of the next entry, **stop** | wait lock of the bucket | an entry is valid while its serial is the `wait_serial` of its thread |
| Program: `handles`, `mappings`, `next_address`, the lower half of its page table, `thread_areas`, `thread_count`, `mapped_pages`, `modules`, `stop`, `state`, `code`, `has_ports` | **op**, **fault**, **revoke**, **stop**, reports | **op**, **fault**, **revoke**, **stop** | program lock | a mapping names a memory object with one reference; a handle names an object with one reference |
| Program: `references` | **op** | **op**, **revoke**, **stop** | atomic; the change to 0 under the control lock | the program runs while a handle names it |
| Program: `holds` | scheduler, **stop**, `stop_wait` | scheduler, **stop** | atomic | the processors that run a thread of it, plus the stop in progress |
| Program: `cleaned`, `serial` | `program_free`, `stop_wait` | `program_cleanup`, `program_create` | control lock; `serial` read with no lock | the slot is free only when `cleaned` and no handle names the program |
| Program: `entries`, `run_time` | reports | **op**, **tick** | atomic | |
| Program: `budget` | **op** (page tables, `Log`, the error record of a refused `Log`) | budget end | frame lock; an atomic store and load. A reader that holds a handle to that budget under the program lock reads it with no frame lock: it changes only when that budget ends | |
| Memory object (region): slot (`page_count`), `serial`, `budget` | all paths that hold a handle or a mapping | **op** (create), the last release | frame lock | free frames, reserved pages, pages of budgets |
| Memory object: frame list, `present` | **fault**, **op** (`user_range`, map), **revoke** | **fault**, **op** | region lock of the object | a page with a frame keeps it until the object ends, or until a decommit |
| Memory object: the state bits of a slot (`SLOT_COMMITTED`, `SLOT_DENY_WRITE`, `SLOT_DENY_EXECUTE`, `SLOT_NO_ACCESS`) | **fault** (`page_give`, `region_frame`), **op** (map, `user_range`, diagnose with no lock: atomic loads) | **op** `Memory_Commit` (commit: region lock and frame lock; decommit: program lock, region lock, frame lock, cache lock), `Memory_Protect` (program lock, region lock); `region_frame` keeps them when it writes a frame | region lock; each slot is one atomic word | a page that is not committed has no frame; the bits of protection only take away from the bits of the mapping |
| Memory object: `uncommitted`, `large_pages` | all paths that hold a handle or a mapping | **op** (create) | frame lock (written before the object has a handle) | |
| Memory object: `committed` | reports (with no lock: one word), the release | **op** `Memory_Commit` | region lock and frame lock | the count of the slots with `SLOT_COMMITTED` (checked at the release in the test build) |
| Mapping: `bits`, `protected` | **fault** (`page_give`), **op**, reports | **op** (map, `Memory_Protect`) | program lock | `bits` is the protection of the mapping now; 0 is no access |
| Mapping: `limit_bits`, `large` | **op** (`Memory_Protect`, unmap), reports | **op** (map) | program lock | `bits` never has more than `limit_bits` |
| Memory object: `marked_pages` | **op** (map, `Handle_Give`, diagnose: atomic loads) | **op** `Memory_Protect` | region lock; atomic | the count of the slots with a mark; not 0: the object is mapped once and not given |
| Processor record: `range_table` | its processor, in `Memory_Commit` and `Memory_Protect` | its processor | none: data of one processor | |
| Memory object: `references` | | **op**, **revoke**, **stop** | atomic; the one that makes it 0 frees the object | |
| Frame table: `frame_bits`, `frame_hint`, `free_frames`, `reserved_pages` | **op**, **fault**, reports | **op**, **fault**, **stop** | frame lock | `free_frames` + the frames of the stacks = pages of all budgets + `reserved_pages` - the `taken` of the stacks |
| Processor record: the frame cache (`frames`, `count`, `taken`) | its processor (**fault**, the end of a memory object); a drain and `System_Report` on any processor | its processor; a drain on any processor | cache lock of the stack; a change of `count + taken` also holds the frame lock | each frame of a stack has its bit set in `frame_bits` and is in no memory object |
| Processor record: the counts of the frame cache (`batches_taken`, `batches_given`, `drains`, `refills`) | `Processor_Report` (with no lock) | under the cache lock of the stack | cache lock | |
| Budget: `amounts.pages`, `live` | **op** | **op**, budget end | frame lock | the same invariant |
| Budget: `parent`, `amounts.programs`, `amounts.threads`, limits | **op**, **tick** (`parent`) | **op** (create, end) | control lock; `parent` read with no lock (below). The limits are written only when the budget is made: a reader that holds a handle to the budget reads them with no lock | |
| Budget: `references` | **op** | **op** (copy, close) | atomic; the change to 0 under the control lock | the budget ends when no handle names it |
| Budget: `spent`, `spent_total`, `logged`, `refused` | **tick**, **op** (`Log`) | **tick**, **op** | atomic | |
| Origin table, `revoke_lost`, `revoking` | **op**, **revoke**, **stop** | **op** (map, unmap, give, close), **revoke**, **stop** | origin lock | each holding with links is a live holding |
| Interrupt objects: `interrupt_owner`, `interrupt_references` | **dev** | **op** (create, close) | control lock; **dev** reads `interrupt_owner` with no lock | |
| Interrupt objects: `interrupt_pending` | **op** (`Interrupt_Read`) | **dev** | atomic | |
| `time_milliseconds`, the time page; `period_time` (the first processor only) | all paths | the tick of the first processor | atomic | |
| Log: the serial port, the log records, `written` | readers in programs | **op** (`Log`), kernel messages | log lock | |
| `machine_stopping` | all processors | `machine_stop` | atomic | |

### The locks, in their order

A processor takes locks only in this order. It takes a lock of a kind only if it holds no lock of a later kind. The kernel checks the order at each take, and stops the machine with a report if it is broken (`TEST_BUILD_CHECKS_LOCK_ORDER`). A cycle of waits needs a processor that waits for an earlier kind while it holds a later one: the order forbids it, so no deadlock exists.

1. **Control lock** (one). The paths that change the relations between programs or the life of an object that several programs name: create, start and stop a program; create and stop a thread; give a handle to another program; map or unmap in another program; revoke; close a handle of a program, a thread, a budget, an interrupt or ports; create a budget; create a device object; read the state of another program or thread; the record of a module in another program; the stop of a program on a fault. It is not a temporary lock. These paths touch an unbounded set of programs (a revocation follows the origins through any program; a stop closes handles that stop other programs). One order among them makes each one atomic for the others, with no cycle. They are rare: a program does them when it starts, stops, or gives access, not in its work (property 3). The measures show that the hot paths do not take it.
2. **Program lock** (one for each program). Two at a time only under the control lock, so the order between two program locks does not matter: one processor at most holds two.
3. **Origin lock** (one).
4. **Region lock** (one for each memory object). One at a time.
5. **Frame lock** (one).
6. **Cache lock** (one for each processor: its stack of free frames). One at a time.
7. **Log lock** (one).
8. **Wait lock** (one for each bucket of the wait table). One at a time.
9. **Run lock** (one for each processor). Two at a time only to move a thread from a queue to another, in the order of the processor index.

Interrupts are off in the kernel, so a processor never takes a lock again in an interrupt. A processor that waits for a lock answers `processor_sync` while it waits.

### Rules that keep each path correct

- **The owner of a running thread.** A thread that runs on a processor belongs to that processor: only it reads and writes the frame, the extended state area, the kernel ring and the word list of the thread. Another processor that stops the thread sets `stop_requested` and sends an interrupt. The processor ends the thread itself, at its next pass in the kernel. No processor takes a thread away from another one.
- **Three rules against three forms of error.** (1) A state that is true only between two sections of one lock is a state that another processor sees: a thread is taken from its queue and given to a processor in one section of the run lock (`queue_pick`). (2) A slot named by its index across a wait for a lock can serve another object when the wait ends: a path that names a thread or a program across such a wait also keeps its serial and checks it (`thread_finish`, `stop_wait`), or holds a lock that keeps the slot (`program_free` only after `cleaned`). (3) A state checked before a work must mean that the work is done: Stopped means that the threads were marked, not that the program was cleaned up (`cleaned`); a new thread is refused in a program that is not Created or Ready.
- **A program ends after its last thread leaves its processor.** `holds` counts the processors that run a thread of the program. A stop adds 1, marks the program Stopped, marks each thread (a thread that waits or is in a queue ends at once; a thread on a processor gets `stop_requested`), then subtracts 1 and sets the bit Stopped in the same atomic addition. The one subtraction that leaves exactly the bit Stopped does the cleanup: unmap, close the handles, free the page tables. So no processor uses the page table or the mappings of a program while they are freed, and the cleanup runs one time. The slot of the program is free (`program_free`) only after the cleanup: by the cleanup if no handle names the program, else when the last handle closes.
- **A stop returns after the threads left their processors.** `Thread_Stop` and `Program_Stop` mark the threads under their locks; the operation then frees all its locks and waits until each marked thread that ran on another processor left it (`stop_wait`): after the operation, no thread of what stopped runs an instruction. A stop of a program that another stop already marked waits in the same way: the state Stopped does not say that the threads left. A wait inside the locks could wait for a thread that waits for these locks. The wait ends at once if the thread that waits is stopped too: two threads that stop each other do not wait for each other.
- **The page tables of a program change under its program lock.** `user_range` and the `user_copy` that follows run under the program lock: no unmap runs between them. An entry that becomes present needs no message to other processors. An entry that becomes 0 (`unmap`, and the undo of a `map_region` that failed on a later page) is followed by `processor_sync` to each processor whose `table` is the table of the program, before the memory object can free a frame, and before a page table that the unmap emptied returns to the frame table ("The page tables of a program"). A processor answers `processor_sync` at each kernel entry, in idle, and while it waits for a lock: then it reloads `cr3`, so it keeps no old translation. It keeps its table only if that table is the one of the program of its current thread; else (no thread, or a thread picked before `run` loaded its table) it loads the kernel table, so a program that ends can free a table that the processor named. Two processors that synchronize each other at one time do not wait for ever: each answers while it waits.
- **The frame caches** (`kernel/memory.odin`, "The frame cache of each processor"). Each processor has a stack of at most 256 free frames in its processor record, with its own cache lock (kind Cache, after Frame in the order). A first use takes a frame from the stack of its processor under the cache lock only, and counts it in `taken` of the stack: a reserved page that the stack served. An empty stack takes one frame for the page and a batch of 128 for the stack in one section of the frame lock, and subtracts `taken` from `reserved_pages` there. The end of a memory object puts its frames on the stack of its processor (the frame lock is held there for the budget); a full stack gives a batch of 128 back to the frame table in the same section. The invariant, true whenever the frame lock and the cache locks are free: `free_frames + the frames of all stacks = the pages of all budgets + reserved_pages - the taken of all stacks`. Each step keeps it: a take from a stack moves 1 from the frames of the stack to `taken` (the two in one section of the cache lock); a batch and a give back move frames between `free_frames` and a stack under the frame lock and the cache lock; the fold of `taken` moves it to `reserved_pages` under the two. So the sum of each stack (frames + taken) changes only under the frame lock: `System_Report` holds the frame lock and reads each stack under its cache lock, one after the other, and gets the exact difference free pages - reserved pages, with no stop of the other processors. The free pages alone and the reserved pages alone are not values of one instant: a take from a stack after the report read it is in neither sum, a take before is in both. The leak check of the console ("budgets N pages: all the free pages") and the checks of `locks` compare the pages of the budgets with that difference only. When the frame table has no free frame for a take that cannot fail (a reserved page, a list page, a page table) or for a contiguous object, the taker, under the frame lock, takes each cache lock in turn and moves the frames of each stack to the frame table (`caches_drain`), then takes again. No frame can stay in a stack while a take fails: a stack is never touched under a cache lock that waits for the frame lock (the order is frame, then cache), so the drain always gets each stack. Frames on a stack are not zero: a frame gets its zeros when a page takes it, as before, after the locks are free (P20: a program never sees the old content of a frame).
- **Pages.** Each move of pages between a budget, the reserved pages and the frame table is one section under the frame lock. So `free_frames` = pages of all budgets + `reserved_pages` holds at each moment that the lock is free, and `System_Report` reads it under the lock. A page fault takes the region lock (to give the frame of one page one time), then the frame lock. The zero fill of a frame is done after the frame lock is free.
- **References.** A reference count is an atomic count. A holder adds 1 only while it holds a handle or a mapping of the object, so a count never goes from 0 to 1. The processor that subtracts the last 1 frees the object: no other processor can name it.
- **Budgets and the tick.** The tick adds the processor time to the budget of the thread and each budget above, with atomic additions, and with no lock. When a budget ends, its objects and its children move to its parent (control lock and frame lock), and its slot is used again only after `processor_sync` to all processors: a tick that walked through the old budget has finished its walk. The log limit uses one word with the second and the count: a record is accepted only if each budget of the chain accepted it; a refusal takes back the counts that it added, in the same second only.
- **The word wait.** A word is named by its physical address. A thread registers each word in the bucket of the word, under the wait lock of the bucket, after it compared the value: a waker changes the word before it enters the kernel, so either the waker finds the entry, or the thread finds the new value. The waker then takes the run lock of the thread: a thread that waits becomes Ready; a thread that still registers (in its own entry) gets `woken` and does not wait. An entry carries the `wait_serial` of its thread; the serial changes when the wait ends, so a late waker of an old wait does not count a thread that runs as woken. A thread removes its entries at its next kernel entry.
- **Revocation.** It holds the control lock. It sets `revoking` and lists the holdings that came from the handle, under the origin lock. While `revoking` is set, a path that adds a holding to the origin tree without the control lock stops and runs again under the control lock, after the revocation. Then the revocation ends each holding under its program lock, after it checks under the origin lock that the tree did not change since it chose the holding: the count of changes travels from the choice of the first holding (`revoke`) through each step (`revoke_under`). If another processor changed the tree, it looks again from the handle: a slot that a close freed can hold a new handle.
- **The kernel half of the page tables** changes only at boot, on one processor. A report reads it and never makes a table (`kernel_entry` with no create).
- **Ports.** A processor changes only its own port bitmap, in `run`, when the program that runs or its `ports_serial` changed. A change of the Ports handles of a program adds 1 to `ports_serial`, then synchronizes all processors: each one checks again before it returns to a program.
- **The scheduler.** Each processor has a run queue. A new thread goes to the queue of the processor that created it; a woken thread goes to the queue of its `home`. If the processor of that queue is idle, the waker sends it an interrupt; else the waker sends one to another idle processor, which takes the thread. When a processor chooses its next thread (after a wait, at the end of a turn, or idle), it takes a thread from the queue of another processor whose load (the threads in its queue, plus 1 if it runs one) is above the count of threads in its own queue. So the ready threads move to the processors that have less, as with one queue for all. The order inside a queue is the strategy of the queue (`kernel/strategy.odin`, `docs/SCHEDULING.md`): six functions that run under the run lock of the queue (`move` under the two run locks of a move). The time slice (10 ticks) is the longest turn under each strategy, so each processor passes through the balance at least each 10 ms while it has a thread.
- **Wake preemption.** If the home of the woken thread is busy and another processor is idle, the waker wakes that processor and stores the home in its `look_first`, after the exchange of `idle` (the order of the idle protocol does not change); its next pick takes from that queue first. With no idle processor, the waker asks the strategy of the home queue, in the same section of its run lock as the wake, if the woken thread preempts the thread of the home (`processors[home].current`, under the same lock). A thread of another program than the thread of the home preempts that processor at most once in each millisecond (`preempted_at`, under the same run lock). If yes, it ends the turn of its own thread when the home is its processor, else it sets `preempt` of the home and sends an interrupt; the home processor ends the turn of its thread when the interrupt comes from a program. The decision is made under the lock and acted on after it: if the home runs another thread then, that thread loses its turn (one more pass through `schedule`), or the woken thread waits for the end of the turn (at most the time slice). No state is wrong in either case: a turn is not a state of a thread. Interrupts are off in the kernel, so the interrupt arrives either when the processor returns to a program, where it ends the turn, or while it waits idle with no thread, where it clears the flag and the processor picks a thread anyway.
- **The change of strategy** (`Strategy_Set`, `strategy_change`, `queue_convert`). The operation writes `strategy_chosen` (atomic), then for each processor in turn takes its run lock, converts its queue to the value of `strategy_chosen` that it reads under the lock, and frees the lock. It holds the program lock of the caller (`execute_locked`) and one run lock at a time: program before run, so the lock order holds (the test build checks it on each take; the full check ran 104 changes, no report). A conversion changes no list, no `state`, no `home`, no `processor`: no thread leaves a queue or a processor, so no thread is lost. It clears the strategy fields of each thread whose home is the queue and that is in the list, on the processor, or Waiting, sets `strategy`, and places each thread of the list with `ready(New)`, in the order of the list. The invariant: the strategy fields of a thread are zero or belong to the strategy of the queue of its home. The interleavings, step by step:
  1. **The tick of the processor of the queue.** `strategy_tick` takes the same run lock. Before the conversion: the old strategy charges the thread, then the conversion clears its fields. After: the thread is not placed; `strategy_tick` places it with the new strategy (`ready(New)`), then charges it. The strategy word and the fields change in one section, so the tick never sees one without the other.
  2. **A wake on another processor.** The waker takes `run_lock(thread)`, which is the lock of the home (it reads `home` again under the lock). Before the conversion: the thread enters the list, placed by the old strategy; the conversion then clears and places it again (it is in the list). After: the conversion cleared the thread (it was Waiting with this home), and `ready(Woken)` of the new strategy sees it not placed and places it as new. The decision of preemption is made in the same section, with the strategy that the queue has in that section.
  3. **A move.** `queue_move` holds the run locks of the two queues. If the two have the same strategy, its `move` keeps the virtual time or the lag. If they differ (the change visited one queue and not yet the other), `queue_pick` clears the fields of the thread: it runs on its new home not placed, and the strategy of that queue places it at its next tick or when it leaves. After the move, its home is the new queue and its fields are zero: the invariant holds.
  4. **A new thread.** `thread_create` writes the thread record with no run lock, while the thread is Ready, in no list and on no processor, and `home` holds the home of the last thread of the slot. The conversion skips such a thread, so it never writes a record that a creation writes. `thread_queue` then takes the run lock of its processor, stores `home`, and places the thread with the strategy that this queue has in that section; its fields are zero, which is valid for each strategy.
  5. **A stop.** `thread_stop` and `program_stop` take the thread out of its list under the run lock of its home, and `schedule` ends a thread that its processor ran under the same lock: each is one section, before or after a conversion.
  6. **Two changes at one time.** Let B be the operation whose write of `strategy_chosen` is the last one. B visits each queue after its write, and at its visit the word holds the value of B, so the queue gets it; a later visit of another operation reads the same value. So when the last operation returns, each queue has the strategy of the word.

## The virtual memory of a program

A program drives its own virtual memory: paging and virtual memory are a design tool for the program. The terms are in `GLOSSARY.md`: uncommitted object, committed page, decommit, page protection, shoot-down, large page, fault ring.

### What a program can do, and with which operation

| Need | Form | Why this form |
|---|---|---|
| Reserve a range of addresses with no memory behind it | `Memory_Create` with the flag `Uncommitted`, then `Memory_Map` | An uncommitted object pays only its frame list; its pages are paid when they are committed. The reservation of addresses is the mapping of it: one mapping for a range of any size, so the 128 mappings of a program are not spent by parts of an arena or of a table. No new operation: an object with pages that are not paid yet is a kind of memory object |
| Commit and decommit pages | the operation `Memory_Commit` (memory, address of a table of `Page_Range`, count, flags): the flag `Decommit` takes pages back | A new operation: the existing ones create an object, map it, unmap it; none changes what the budget pays for some pages of an object that lives. One operation for the two ways, as `Handle_Give` and `Handle_Close` are not one: here the two ways change the same three counts (budget, reserved pages, frames) in opposite directions over the same table |
| Change the protection of pages | the operation `Memory_Protect` (address of a table of `Address_Range`, count, `Map_Flags`) | The protection of a mapping is set by `Memory_Map` for all its pages; changing it for some pages of a mapping that lives is a new act. `Map_Flags` has the flag `No_Access` for it |
| Large pages | `Memory_Create` with the flag `Large_Pages` (contiguous, a whole number of 2 MiB, aligned on 2 MiB); `Memory_Map` uses large pages for each 2 MiB that is aligned in the mapping | No new operation: the program asks for an object whose frames can be large pages; the kernel uses them where the mapping allows it |
| A fault that the program answers | the fault ring (below): `Fault_Handler_Set` and `Fault_Answer` | |
| What the program reads about itself | `Program_Mapping` gives the committed pages and the flags `Uncommitted`, `Large`, `Protected` | |

Batches: `Memory_Commit` and `Memory_Protect` take a table of ranges in memory of the caller, at most 256 ranges, in one command. The kernel ring already batches 32 commands in one entry, but each command takes the program lock again, checks its handle again, and a protection change does its own shoot-down; a table of ranges in one command takes the lock once, checks the handle once, and does one shoot-down for all the ranges (property 13: many records in one call; property 14: the table is memory of the caller).

### The state of a page

The frame list of an object that is not contiguous has one slot of 8 bytes for each page. A frame is aligned on 4096 bytes, so the low 12 bits of a slot are free; the kernel keeps there the state of the page that is not a frame:

- bit 0, `committed`: only for an uncommitted object. A page of an uncommitted object is committed when its budget paid for it; a page of another object is always committed. A page that is not committed has no frame, and an access to it is a fault.
- bit 1, `deny write`, and bit 2, `deny execute`: the protection of the page is the protection of its mapping less what these bits deny.
- bit 3, `no access`: any access is a fault.

The frame of the slot is `slot & PAGE_ADDRESS`; 0 is no frame. A slot changes under the region lock of the object (a first use) or under the program lock and the region lock (commit, decommit, protection); the frame lock is held where frames or budgets move.

### Who pays a commit

`Memory_Commit` takes a budget handle as its second argument, and that budget must be the budget of the object: one payer for each object, and the pages of a decommit go back to it. The right Write on the object does not spend the budget of its maker. The handle needs the right `Commit` (pay pages of an object that this budget already pays for, and nothing else) or `Spend`. `Spend` is wide: it also makes objects, threads, programs and budgets; so a program that lets another one commit gives it the narrow right `Commit`. Delegation uses what exists: A makes a child budget, makes the uncommitted object on it, and gives B the object and the child budget with `Commit` only. A decommit reads no budget handle: it gives pages back to the payer, and it needs an object that only this program names, so B cannot take pages from an object that A uses. The cases, each shown by `address_space` with two programs and its error record:

1. B commits up to the child budget, then one more page: `No_Budget`; the record does not describe the budget, since B's handle has no right Read.
2. B has the object with Write and no budget handle: it reads and writes the committed pages; a commit gives `Bad_Handle` (no handle).
3. B makes an object with the `Commit` handle: `No_Right` (the call needs `Spend`).
4. B presents a budget that does not pay for the object: `Bad_Handle`, kind `Not_Payer`: the record says nothing of that budget.
5. A revokes B's budget handle: B commits no more (`Handle_Ended`, revoked); the committed pages stay committed and paid by the child budget.
6. A takes the pages back while B maps the object: A revokes B's object handle (the kernel unmaps B and wakes its waiters), then decommits with no mapping of its own. A cannot decommit under a live B: the pages have entries in B's page table, and the decommit holds one program lock and shoots down one page table.
7. B decommits pages of an object that A holds too: `Bad_State`, kind `Object_Shared`.
8. The child budget ends while the object lives (A closes it after the revocation): the object moves to the parent budget (`budget_release`); a commit then needs the parent's handle; the old handle names nothing.
9. B gives its `Commit` handle on: only with the right `Give`, which A did not give (`No_Right`); a revocation by A reaches each copy through the origin chain.
10. A service that receives an object of a client cannot be made to pay for it (the budget must be the object's), and cannot spend the client's budget without a handle to it.

A limit of revocation: a revocation of a budget handle ends the holdings that came from it (handles and mappings), not the objects that were made with it. An object that B made with a `Spend` handle lives on after A revokes the handle, paid by A's budget, and A has no handle to end it (case 10 of the program shows it). This is why the delegation uses `Commit`.

### Commit and decommit

- **Commit** of a range of an uncommitted object: under the program lock of the caller, the region lock of the object and the frame lock, in one section for the table: the budget of the object pays one page for each page that is not committed, `reserved_pages` grows by as much, the bit `committed` is set. A budget that cannot pay the whole table refuses the whole table (`No_Budget`, its error record names the range): no table is half done.
- **Decommit**: the same locks. For each committed page: the bit is cleared; a page with a frame loses its page table entry (the shoot-down below), its frame goes to the frame cache of this processor (in the section of the frame lock, as the end of an object does), `present` of the object falls by one; a page with no frame gives back its reserved page; the budget receives one page for each page. The content of a page that is committed again is zero (a new frame at its first use: P20, ZII).
- Decommit and a protection change of a part of a mapping need an object that only this program names, with one mapping at most (the references of the object are the handles of this program to it and its mapping): its pages have no page table entry in another program, so the shoot-down is the one of this program. Another object gives `Bad_State`, kind `Object_Shared`.
- A thread of the program that waits on a word of a page that is decommitted wakes before the frame returns (its wait names the frame: a later wake through a new frame would not reach it, and the next owner of the frame could wake it).
- One call changes at most `RANGE_TABLE_PAGE_LIMIT` (65 536) pages: each page is walked with interrupts off. A whole protection change of a mapping of 4 KiB pages counts its present pages (it changes only those, and its walk stops after the last of them); a large page counts one. The longest decommit call measured in `address_space` is logged.
- A revocation and a decommit wake the threads with a word in a frame that leaves with one sorted search: the words (at most 256) are sorted, then the slots are read in order with a binary search for each frame, and the walk stops at the last frame of the object. `unmap` walks one table of the last level at a time: it reads the entries until the last present entry, and subtracts the pages of the mapping from the count of each table ("The page tables of a program"); the release of an object stops after its last frame. What stays: an object whose last page has a frame is one pass over its slots (2 MiB for 1 GiB, read in order), with interrupts off.
- The sums of the frames (`TEST_BUILD_CHECKS_FRAME_SUMS`) hold at each step: a commit moves pages from a budget to `reserved_pages`, a decommit moves them back, or moves a frame to a stack and a page to the budget.

### Protection and the shoot-down

`Memory_Protect` sets, for each page of each range, the protection of the page: Read only, Read and Write, Read and Execute, or `No_Access`. A part of a mapping takes away from the protection of its mapping now, as marks in the slots of its pages; a part that gets the protection of its mapping has no mark, and a whole mapping clears the marks of its pages. While an object has marks (`marked_pages`), it is not mapped again and not given (`Bad_State`, kind `Object_Marked`): the marks are of the object, so they would reach another mapping. The other form, the marks in each mapping (a table of ranges in the mapping), lets an object with parts protected be shared; it costs a table in each of the 128 mappings of each program, or a second table to allocate, for a case that no program needs now; the count is one word and keeps the slots as the one place of the state of a page. It can only take away what the mapping was made with: a range of a mapping made without Write cannot become writable (the handle was checked for the rights of the mapping). Write and Execute together are refused (no page is both). For an object with a frame list, the state is in the slots (above): a page that gets its frame later gets the protection of its slot. For a contiguous object (device memory, large pages) the protection is of the whole mapping: a range must cover the mapping. The page table entries that exist are rewritten; then one `processor_sync` to the processors whose page table is the one of the program, for all the ranges of the call. A processor answers it at its next kernel entry, its idle wait or its wait for a lock, and reloads its page table: it keeps no old translation. The cost is measured with 1, 2 and 4 processors running threads of the program.

### Large pages

An object made with `Large_Pages` takes its frames in one run aligned on 2 MiB (`frames_take_aligned`). A mapping of it uses a large page for each 2 MiB of the mapping whose address and first page are aligned: one entry of the second level, with the bit `PAGE_LARGE`; other parts use 4 KiB pages. The walk of the page table (`page_entry`) gives the entry of the second level for an address in a large page; each path that reads or writes entries knows it: the end of a mapping clears the large entries and releases them as held entries of the table of the second level, a large entry never has a count, the reports count 512 present pages for a large entry. A protection change of a part of a large page is refused (a range must cover the mapping); a decommit of such an object is refused (it is contiguous). The benefit is measured: random reads over 64 MiB, with large pages and with 4 KiB pages of the same object; under QEMU with KVM the numbers are those of the processor of the host, with the nested page tables of the host.

### The addresses that the kernel chooses

A mapping with no address takes the lowest address from `CHOSEN_BASE` where its pages fit with one page with no mapping before and after them: the first gap between the mappings of the program (`chosen_address`, at most 129 passes over the 128 mappings). So the range of a mapping that ended serves again: a program that maps and unmaps at each call uses the same few addresses. `address_space` maps and unmaps one object 100 000 times and its budget is the same after as after the first time.

### The page tables of a program

`map_region` makes each page table that a new mapping needs, and the budget of the program pays one page for each: a page fault never needs a table. The mapping holds its entries while it lives: each page of it, present or not, and each large page. An entry that names a table is held while that table holds an entry. The top table lives as long as the program.

- **The count.** Each table, except the top table, has a count of its held entries: in the bits 52 to 62 of the entry that names it. The processor ignores those bits in an entry that names a table, and the kernel keeps no record for each frame (a frame is one bit of the frame table), so the count costs no memory and ends with the table. The count changes with an atomic addition: a processor that walks the table sets the bit Accessed of the same entry with a locked write. The program lock orders the writers.
- **The release.** `unmap`, and the undo of a `map_region` that failed, clear the entries of the mapping, then subtract from each table of the last level the pages of the mapping in it: one subtraction for each 2 MiB (`page_entries_release`). A table whose count falls to 0 leaves: the entry that names it becomes 0, and its parent loses one held entry, up to the top table.
- **The order.** First the entries that name the freed tables become 0. Then the shoot-down: `processor_sync` to each other processor whose page table is the one of the program, and each one reloads `cr3`. Then this processor reloads `cr3` if it uses the table. Then the frames return to the frame table and the budget of the program receives one page for each table. A processor can keep an entry of an upper level in its paging-structure caches, also when no page under it is present (Intel SDM volume 3A, "Invalidation of TLBs and Paging-Structure Caches"); the flush of one page (`invlpg`) runs only for the present pages, so a mapping with no present page runs none. A write of `cr3` removes every such entry of the address space with no condition. It runs once for each unmap that freed a table.
- **The cost.** A map holds the pages of a mapping with one walk of the upper levels and one atomic addition for each 2 MiB of the mapping, and makes the tables that are missing. An unmap that leaves each table in use does one walk of the upper levels and one atomic subtraction for each 2 MiB of the mapping, and no other work. An unmap that frees tables adds one reload of `cr3` on this processor and one section of the frame lock; the shoot-down is the one that the unmap makes anyway.
- **No reserve.** A freed table returns to the frame table. A map, an unmap and a map at the same address take a frame again, fill it with zero, and pay it again. A reserve of freed tables for each program would hold pages that no budget sees.
- **A decommit keeps the tables.** A decommit clears entries, and the mapping still holds its range: the tables stay, and a later commit and first use need no table. They return with the unmap.
- **The checks.** The machine stops with a line of the log if a count falls below 0, if a walk of an unmap finds no table where its mapping holds entries, if a table is held where a large page goes, or if the top table of a program that ends still has a present entry in its program half. The test build also checks that no entry of a freed table is present. The checks read the bit Present only: an entry that is not present names nothing, whatever its other bits hold.

### The interleavings

The locks: a commit holds the program lock of the caller (the operation), then the region lock of the object, then the frame lock; a decommit also the cache lock of its processor; a protection change the program lock, then for a part the region lock. The order is program, region, frame, cache: the order of the locks of the kernel.

1. **A commit and a first use on another processor.** The first use of a page of the object runs `region_frame`, which reads the slot, then takes the region lock and reads it again. A commit sets `SLOT_COMMITTED` under the region lock. A first use that read the slot before the commit sees a page that is not committed and gives no frame: the program faults, as it accessed a page that was not committed at that moment. A first use after it takes a frame. A commit never takes a frame: there is no frame to lose.
2. **A decommit and a first use.** A decommit holds the program lock for the whole operation, and the program of the object is this one (the object is named only here): each first use of a page of the object comes from a thread of this program, through `page_fault` or `user_range`, which take this program lock. So no frame of the object is given between the first step (the entries are cleared, the shoot-down) and the second (the frames return). The shoot-down comes before the frames go to the frame cache: no processor can write a frame after it is free.
3. **A decommit and a report or a drain.** The frames go to the frame cache of this processor under the frame lock and its cache lock, in the section where the budget and `reserved_pages` change: the sums of the frames hold whenever these locks are free.
4. **A protection change and a thread that runs on another processor.** The entries are rewritten under the program lock; then the shoot-down: each processor whose page table is the one of the program reloads it at its next kernel entry, its idle wait, or its wait for a lock, and the operation returns after each of them did. A thread that used an old entry before that moment used the protection of before; after it returns, no thread does. A page with no entry takes its protection at its first use, under the program lock.
5. **A large page and the free of a table.** A table of the last level never stays with no held entry: the unmap that empties it frees it, after its shoot-down ("The page tables of a program"). So the place of a large page is always empty when a mapping of large pages is made there; a present entry in that place is a mistake of the kernel, and the machine stops with a line of the log. A processor that kept the entry of the upper level that named a freed table forgot it in the shoot-down, before the table was free.
6. **Another program that names the object.** Decommit and the protection of a part need the references of the object to be this one mapping and the handles of this program: another program that holds a handle to it counts in the references, so it cannot have an entry of a page of the object while the decommit runs.

### The fault ring

Without a fault handler, a processor exception of a program that the kernel does not serve itself (a page fault that `page_give` cannot serve, a divide error, an invalid opcode, ...) stops the program, with a stop report. The terms are in `GLOSSARY.md`: fault handler, fault ring, fault record, fault kind, fault class. The code is `kernel/fault_ring.odin`, the two operations in `kernel/enter.odin`, the case of `kernel_interrupt`, and `thread_finish`; the kinds and their classes are in `contract/operation` (`Fault_Kind`, `fault_kind_class`, `fault_kind_resumes`, `fault_kinds_of_argument`, with host tests); the test is the program `fault_ring` (`kerneltool test fault_ring`).

A program names one of its threads as its fault handler (`Fault_Handler_Set`, operation 30), with the fault kinds that the handler takes (`op.Fault_Kinds`, the third argument; 0 is page faults only). Then a fault of such a kind of another thread of the program, which would stop the program, is a fault record in the fault ring, and the thread waits. A page fault is delivered only at an address below `THREAD_AREA_BASE`. A thread of the program repairs with the operations above (`Memory_Commit`, `Memory_Protect`) and answers (`Fault_Answer`, operation 31): `Resume` lets the thread continue at the instruction of its record; `Stop` stops the program with the stop code and the stop report of the fault, as with no handler. A program uses it for guard pages, a stack that grows, memory committed at the first touch, the barriers of a collector, and a debugger that sets breakpoints; the kernel holds no policy. No signal (property 16): a fault is a record in memory of the program, and the answer is an operation.

**The fault kinds.** A fault kind is the processor exception, named by its vector. Its fault class says where the thread continues: a fault did not run its instruction, and the frame holds the address of that instruction; a trap ran its instruction, and the frame holds the address of the next one. The record gives that address (`instruction`), the kind and the error code of the processor.

| Vector | Kind | Class | Resume with no write | Error code |
|---|---|---|---|---|
| 0 | `Divide_Error` (`div` or `idiv` by 0, or a quotient too large) | fault | refused | none (0) |
| 1 | `Debug` (the trap flag after an instruction, `int1`) | trap | accepted | none (0) |
| 3 | `Breakpoint` (`int3`, `int 3`) | trap | accepted | none (0) |
| 6 | `Invalid_Opcode` (`ud2`, an instruction that the processor does not have) | fault | refused | none (0) |
| 11 | `Segment_Not_Present` | fault | refused | the selector |
| 12 | `Stack_Fault` (a stack address that is not canonical) | fault | refused | 0 or the selector |
| 13 | `General_Protection` (a privileged instruction, an address that is not canonical, `int n` for a vector other than 3, `sgdt`, `sidt`, `sldt`, `smsw` and `str` with UMIP) | fault | refused | 0, the selector, or `(n << 3) + 2` for `int n` (0x72 for `int 14`) |
| 14 | `Page_Fault` | fault | accepted | the bits of the access (also in `access`) |
| 16 | `X87_Floating_Point` (at the next x87 instruction; CR0.NE is set) | fault | refused | none (0) |
| 17 | `Alignment_Check` (an access that is not aligned with the flag AC set; CR0.AM is set) | fault | refused | 0 |
| 19 | `Simd_Floating_Point` | fault | refused | none (0) |

`Debug` is a trap only: a `Debug` exception is a fault only for an instruction breakpoint of a debug register, and the kernel sets no debug register for a program (it clears DR7 at the start of each processor). After a trap, `instruction` is the next instruction, so the length of the one that trapped is not in the record: `int3` (CC) and `int1` (F1) are one byte, `int 3` (CD 03) two. A debugger that wrote CC subtracts 1. `int n` for another vector never arrives as the exception n: its gate has the privilege level 0, so the processor gives a `General_Protection` with the error code `(n << 3) | 2`. The gate of the vector 3 has the privilege level 3, so that `int3` of a program is a `Breakpoint`; with 0, the processor gives a `General_Protection` in its place. Every other gate keeps 0: no `int n` of a program acts as an exception or an interrupt. With no handler, `int3` stops its program with the code `STOP_CODE_FAULT` + 3.

**The rule of Resume.** `Fault_Answer` accepts `Resume` for a trap (the thread continues after its instruction) and for a page fault (the handler changes what the instruction finds with `Memory_Commit` and `Memory_Protect`). For every other fault it accepts `Resume` only when `Thread_Control` wrote the registers or the extended state of the waiting thread since its fault ("The control of a thread"): the handler moved the instruction address past the instruction, or changed the register or the control word that faulted. With no such write it refuses `Resume` with `Bad_State`, and the thread still waits: `Stop` ends it with its report. Such a fault runs the same instruction on the same registers again, and faults again with no end; to accept `Resume` and charge each new record to the budget would make a loop of records that never ends and that no line of the log names. With a write, a fault that comes again is a new record that the handler reads and answers: each turn of such a loop is an operation of the handler, paid by its budget, and never a silent loop of the kernel. The mark of a write is per fault: `fault_deliver` clears it, so a write before a fault does not count for it. The refusal is visible to the handler at its first answer.

**Where the ring is.** In the thread record of the handler, after its fields (`op.Thread_Record`: `fault_written`, `fault_read`, `fault_full`, and `fault_records`, 16 records of 64 bytes). The kernel already writes that page (the event word) through the direct map, and the budget of the program paid for it with the thread. So the ring needs no new memory object, no mapping, and no count of references: it lives as long as the handler. `fault_read` is memory of the program; the kernel indexes the records with its own count (`Program.fault_written`), so it never writes outside `fault_records`, and a difference with `fault_read` that is not below the capacity is a full ring. A false value of `fault_read` harms only its own program: a value above the count makes the ring full (the next fault stops the program), and a value a little below the count lets the kernel write over records that the program did not read yet (their threads wait until the program answers them, or stops).

**The rules**:

- **Who registers**: the program itself, for one of its own threads (a thread handle with Control, or the calling thread). A pager that serves the faults of another program needs a fault ring that the pager reads and a right on the program handle: it is not built.
- **Which faults**: each fault of a kind that the handler asked for. For page faults: every page fault that `page_give` does not serve (no frame and not committed, no mapping, or an access that the protection refuses), at an address below `THREAD_AREA_BASE`. No flag of a mapping (such as `Faults_To_Ring`) selects the faults: a program that wants only some ranges answers `Stop` for the others.
- **The kinds of a handler**: the third argument of `Fault_Handler_Set` is a set of fault kinds, bit n for the vector n (`op.Fault_Kinds`). 0 is page faults only: a handler that repairs pages never gets a divide error that it would answer as a page. A fault of a kind that the handler did not ask for stops the program as with no handler. A bit of a vector that the kernel never delivers refuses the whole argument (`Bad_Operation`, with the error record `Bad_Flags` and the mask `FAULT_KINDS_DELIVERED`), and so do kinds with the end of the delivery (`end` 1). The kinds are one word of the program (`Program.fault_kinds`), written under the program lock; a fault reads it first with no lock, so a fault that is not delivered takes no lock and does no more work than with no handler. A delivery needs the check under the program lock too. The read with no lock alone decides a stop: a fault at the same time as the `Fault_Handler_Set` that adds its kind can read the old word and stop the program. That fault counts as one before the operation; a fault that starts after the operation returned reads the new word.
- **What is never delivered**: the vectors that are not fault kinds: the non-maskable interrupt (2), the double fault (8) and the machine check (18), which are not faults of an instruction of a thread (each one stops the machine with a line, also when a program ran: a double fault is a mistake of the kernel, a machine check an error of the machine, and the kernel sends no non-maskable interrupt, so one reports the machine); overflow (4) and bound (5), whose instructions are invalid in 64-bit mode and give `Invalid_Opcode`; device not available (7) and invalid task state (10), mistakes of the kernel, which keeps the extended state and the task state of each processor; the reserved vectors and those of modes that the kernel does not use. Also: a page fault with the reserved bit of the error code (an entry of a page table with a reserved bit: only the kernel writes those entries, so the machine stops with a line of the log, as at an exception in the kernel; a handler never sees it, so a repair cannot hide it in a loop of faults); a fault of the handler thread itself, of any kind (it would wait for its own answer: no fault of a fault); a fault of a program that stops (its state is `Stopped`, under the program lock); a page fault at or above `THREAD_AREA_BASE` (the thread areas, which hold the ring; the time page; the kernel half); a fault in the kernel, also on behalf of a program (the machine stops; `user_copy` checks the range first with `user_range`, so an operation with a bad address fails with its status); a fault of the `iretq` of a return to a program (a refused return, "The return to a program"). Each of these stops the program as with no handler, stops the machine, or fails the operation.
- **A full ring**: the fault stops the program as with no handler, with the report of the fault; the kernel adds 1 to `fault_full` and writes a line of the log. The thread never waits for a place.
- **The ring ends while a thread waits**: the handler thread ends, or `Fault_Handler_Set` names another handler (or the same one again: its ring starts empty) or ends the delivery (`end` 1). The record of the waiting thread is then in a ring that no thread will read: the program stops with the stop code `STOP_CODE_FAULT_UNANSWERED` (0x500), the same rule for the three. Without a waiting thread, each of them only ends the delivery or changes the handler: a later fault stops the program as with no handler, or goes to the new ring.
- **The program stops while a thread waits**: `program_stop` ends the waiting thread as any thread that is on no processor. A waiting thread holds its thread and nothing else: no record of the kernel, no lock, no page.
- **No time bound**: a thread waits until the answer or the end of its program. Property 4 has one wait with a deadline, for a program that wants one; the fault handler of the program decides how long the repair takes, and a handler that never answers holds only threads of its own program, which its budget paid. The program, or the person, stops it.
- **Who answers**: any thread of the program. The record names the thread by its number and the serial of the fault; `Fault_Answer` finds a thread of the program with that number that waits for the fault of that serial, and refuses any other (`Bad_State`): an answer for a thread that ended and whose number serves again is refused, and so are a second answer, an answer for an earlier fault of the same thread, and an answer from another program. `Resume` for a kind that does not resume by itself, with no write of `Thread_Control` since the fault, is refused with `Bad_State` too, and leaves the thread waiting (the rule of Resume, above).
- **The serial of a fault**: a count of the program (`Program.fault_serial`, 1 for the first fault that goes to a ring), not the serial of the kernel's slot of the thread. All programs share those slots: a serial of a slot in a record would tell a program how many threads the other programs made in its slots.

**The states of a faulting thread**, each change under the locks named:

- **Running, then waiting** (`fault_deliver`, from `kernel_interrupt`): under the program lock, the thread first leaves the table of words (`wait_unregister`). The entries of its last word wait stay there until its next kernel entry, and a fault is not one: without this, a `Word_Wake` on such a word, or a decommit or a revocation of its page (`thread_words_wake`), ends the wait with no answer, and the thread faults again. `thread_words_wake` also skips a thread with `fault_waits`; its two callers (`memory_commit` from `execute`, and `holding_end`) hold the program lock. So a thread that waits for an answer is in no table of words, and only `Fault_Answer`, the end of the ring, or the stop of its program ends its wait. Then, under the run lock of its home, the thread becomes `Waiting` with the deadline `WAIT_FOREVER` and `fault_waits` true, before its record is published (`fault_written`, then a wake of that word). So an answer always finds it waiting. It is still on its processor: `kernel_interrupt` calls `schedule`, which saves its extended state as for any thread that leaves a processor (nothing new for the extended state), and puts it in no queue. No word ends this wait (the thread registered none), and no deadline does.
- **Waiting, then ready** (`Fault_Answer` with `Resume`): under the program lock, `fault_waits` becomes false; then `thread_wake` makes it `Ready` under the run lock, as the end of a word wait does. If the thread is still on its processor, `schedule` puts it in a queue when it leaves (the rule of `thread_ready_held`). A thread that a stop of `Thread_Control` holds becomes `Ready` and enters no queue until its last `Resume`.
- **Waiting, then stopped** (`Fault_Answer` with `Stop`, `program_stop`, the end of the handler): `program_stop` ends it.

**The return.** A thread resumed after an answer returns through `run`, so its frame passes `return_frame_prepare` as each return does ("The return to a program"). The frame is the one that the processor gave at the fault, or the one that `Thread_Control` wrote: after a page fault the instruction runs again; after a trap the thread continues at the next instruction. A frame that `Thread_Control` writes is checked whole when it is written, and `return_frame_prepare` checks it again at the return.

**The answer `Stop`** writes the stop report from the frame of the waiting thread and the address of its fault (`program_fault_report`, the same code as a fault with no handler: the stop code `STOP_CODE_FAULT` plus the vector, the vector, the instruction, the address of a page fault), with the stack trace of the waiting thread: the answering thread is of the same program, so the page table of its processor is the one of the program.

**The kernel operations**: 30 `Fault_Handler_Set` and 31 `Fault_Answer`. With `Events_Set` (32, "Kernel events") and `Thread_Control` (33, "The control of a thread"), the kernel has 33 operations.

**The address of a fault** is read from `cr2` once, at the start of `kernel_interrupt`, and each path of the page fault (`page_fault`, `fault_deliver`, `program_fault`) takes that value. For another kind the address is 0.

**The kernel event of a fault** (`Fault`, "Kernel events") has the vector in its detail for each kind, and the outcome `Fault_Ring` for a fault that went to the ring.

**Not built**: a pager for another program; a flag of a mapping; a fault of a thread of the kernel on behalf of a program.

### The control of a thread

A program stops one of its threads, reads and writes its registers, and resumes it (`Thread_Control`, operation 33). A debugger, a garbage collector that reads the roots of each thread, a sampling profiler and the program that runs a guest use it. The code is `kernel/thread_control.odin`; the checks of a write are `op.thread_registers_refusal` and `op.extended_state_refusal` in `contract/operation`, with host tests; the test is the program `fault_ring` (`kerneltool test fault_ring`, the cases 20 to 28). The terms are in `GLOSSARY.md`: thread control, stop count, held thread, register image.

**The operation.** One operation with a command (`op.Thread_Control_Command`): `Stop`, `Resume`, `Read_Registers`, `Write_Registers`, `Read_Extended_State`, `Write_Extended_State`. Its reason: no operation of the kernel stops a thread without its end, or gives its registers, and a guest needs both; one operation with a command keeps the count of operations lower than four. The arguments: a thread handle with the right `Control`, or 0 and the number of a thread of the calling program (`Thread_Record.number`, the `thread` of a fault record); the command; the address and the size of a register image or of an extended state area.

**Who can act on a thread.** A program acts on its own threads, by their number or by a handle. A thread of another program needs a thread handle with `Control` that this program received (`Handle_Give`): no number, no program handle and no other right names it (property 20, line 2). A handle without `Control` gives `No_Right`.

**The stop count.** A stop is a count, not a state: two holders that each stop a thread each resume it, and the thread runs only after the last `Resume`. `Resume` at 0 gives `Bad_State`; the count has a limit of `THREAD_STOP_COUNT_LIMIT`. The count does not change the wait of the thread: a thread in a word wait stays in it, and its wait ends as before; a thread that waits for an answer of the fault ring still waits for it. A thread whose count is above 0 enters no run queue. The three places where a thread enters a queue check the count under the run lock of its home: the end of a wait (`thread_ready_held`), the processor that leaves the thread (`schedule`), and the end of a kernel entry (`kernel_interrupt`). The `Resume` that makes the count 0 puts a `Ready` thread in the queue of its home. `Thread_State` gives `Ready` for a stopped thread whose wait ended, and the count in its second result.

**The stop of a thread on another processor.** `Stop` sends an interrupt to that processor; the thread enters the kernel, and the end of the entry does not continue it. The operation returns only after the thread left its processor (`stop_wait`, as for `Thread_Stop`), so its registers are complete when the caller reads them. A thread that stops itself stops at the end of its kernel entry. Two threads that stop each other do not wait for each other: the wait ends when the caller itself is stopped.

**A held thread.** The registers are complete only while no processor runs the thread: the frame of its last kernel entry, and the extended state that `schedule` saved. So the four commands of the registers need a held thread: its stop count is above 0, or it waits for an answer of the fault ring, and it is on no processor. Else `Bad_State`, and for the calling thread. A thread that waits for an answer can still be on its way out of its processor (its record is published before): the operation waits for it, because that way takes no program lock. Both holds last while the program lock of the thread is held, which the operation holds: the count goes down and `fault_waits` ends only under it. For a thread of another program, the operation takes the control lock, then the program lock of that program.

**The register image** (`op.Thread_Registers`, 176 bytes): the 16 general registers, `rip`, `rflags`, `cs`, `ss`, and `in_kernel_entry`, which says that the thread is held inside a kernel entry (a wait). At the return of such an entry `rax` is the time, as after each entry, so a write of `rax` there is lost.

**The check of a write.** The kernel copies the image once into its own memory, checks it whole, and changes nothing if one field is refused (`Bad_Operation`; the error record gives the refused value):

| Field | Accepted |
|---|---|
| `cs` | the code selector of a program, 0x23 (not the one of the kernel) |
| `ss` | the stack selector of a program, 0x1B |
| `rflags` | interrupts on and bit 1 set; no I/O privilege level, no nested task, no virtual-8086 and no virtual interrupt flag; the trap flag, the alignment check flag and the resume flag are allowed (a program can set them itself with `popfq`) |
| `rip` | below `USER_END`: canonical, and in the half of a program |
| `rsp` | canonical |

The kernel returns to a program only with `iretq`, never with `sysret`, so the fault of `sysret` with an instruction address that is not canonical does not exist; `iretq` refuses such an address in the kernel, and the check of `rip` keeps that fault away ("The return to a program"). `return_frame_prepare` checks the frame again at each return.

**The extended state.** The area of a thread is the area of the processor: the standard form of `xsave` (the 512 bytes of the legacy area, the header of 64 bytes, then each component at the offset that `CPUID` leaf 0xD gives), or the 512 bytes of `fxsave` on a processor with no `xsave`. `Thread_State` gives its size, its components (the bits of XCR0) and its form; `Read_Extended_State` writes that many bytes. A hostile area would make `xrstor` or `fxrstor` fault in the kernel at the next restore of the thread, where the fault would stop the machine. So a write is checked, not caught: `MXCSR` has no bit outside the mask of the processor (measured at boot with `fxsave`), `XSTATE_BV` names no component outside XCR0, and the other 56 bytes of the header are 0 (the standard form; an area that a save wrote has them 0). The area is copied once into a buffer of the processor, checked there, then copied to the thread.

**Resume after a fault.** A write of the registers or of the extended state of a thread that waits for an answer makes `Resume` valid for every fault kind ("The fault ring", the rule of Resume). A handler that skips a divide error adds the length of the `div` to `rip`, writes the result in `rax`, and answers `Resume`.

**Not built**: a stop of all the threads of a program in one operation; a register image of the debug registers (the kernel sets none for a program); the base of `fs` (the kernel does not keep one for a thread).

## The extended state of the processor

The kernel saves each state component that it enables, not only x87 and SSE, and writes `CR4` and `XCR0` itself. A kernel that saves only 512 bytes with `fxsave64` (x87 and SSE) and keeps the `CR4` and `XCR0` of the firmware has a fault: a program that uses AVX on a firmware that enabled it gets the high halves of its ymm registers from another thread, with no error.

The kernel saves and restores the extended state only at a switch of threads, and has no vector code (sections 3 and 3a). A save at each kernel entry makes each entry 29 to 41 % slower (section 3).

The terms are in `GLOSSARY.md`: extended state, state component, extended state area, start state, switch of threads, usable instruction set. The code is `kernel/extended_state.odin`, the save and the restore in `kernel/processor.asm`, the switch in `kernel/schedule.odin`, the check of the build in `tools/kerneltool/vector_check.odin`, and `support/instruction_sets`. The test is the program `extended_state`.

### 1. The state components that the kernel enables

The rule: a bit of `XCR0` is set only if the kernel saves its component. The kernel writes `CR4` and `XCR0` itself on each processor; it does not keep what the firmware left.

| Component | `XCR0` bit | Offset and size in the area (standard form) | Enabled |
|---|---|---|---|
| x87 | 0 | 0, 160 (in the legacy area of 512 bytes) | always |
| SSE (xmm0 to xmm15, `MXCSR`) | 1 | 160, 256 (in the legacy area) | always |
| header (`XSTATE_BV`, `XCOMP_BV`) | none | 512, 64 | with `xsave` |
| AVX (high halves of ymm0 to ymm15) | 2 | 576, 256 | when the processor has AVX |
| MPX (`BNDREGS`, `BNDCSR`) | 3, 4 | 960, 128 | no: MPX is removed from the processors and from the compilers |
| AVX-512 opmask (k0 to k7) | 5 | 1088, 64 | when the processor has AVX-512 F |
| AVX-512 `ZMM_Hi256` (high halves of zmm0 to zmm15) | 6 | 1152, 512 | with the opmask |
| AVX-512 `Hi16_ZMM` (zmm16 to zmm31) | 7 | 1664, 1024 | with the opmask |
| PKRU | 9 | 2688, 8 | no: the kernel does not use protection keys (`CR4.PKE` stays clear) |
| AMX `XTILECFG`, `XTILEDATA` | 17, 18 | 2752, 64 and 2816, 8192 | no: out of scope |

One save therefore writes at most 512 bytes (`fxsave`), 576 (`xsave` with x87 and SSE), 832 (with AVX) or 2688 (with AVX-512). The area of each thread entry is 2688 bytes in every case (section 2). The boot log says both: "kernel: extended state: x87, SSE, AVX; one save writes at most 832 bytes, in an area of 2688 bytes in each thread entry; saved at a switch of threads with xsaveopt". The offsets of the table are those of the processors of Intel and AMD; the kernel does not trust them: after it writes `XCR0`, it reads the size that the processor needs (`CPUID` leaf `0xD`, subleaf 0, `EBX`). If that size is more than the area of a thread, the kernel drops AVX-512 and tries again; x87 and SSE with `xsave` need 576 bytes, which always fit.

Why AVX-512 is in: it costs 1856 more bytes in each thread entry of the thread table of the kernel, and nothing at an entry of a program that does not use it (section 3). Why AMX is out: its tile data is 8 KiB for each thread, and its use needs a permission model (Linux asks each program to request it), and the tile configuration has rules of its own. A program that executes an AMX instruction gets an invalid opcode and stops.

On each processor, the kernel sets `CR4.OSFXSR` (bit 9) and `CR4.OSXMMEXCPT` (bit 10). It sets `CR4.OSXSAVE` (bit 18) and writes `XCR0` when the processor has `xsave` and `xsaveopt`, and clears `CR4.OSXSAVE` when it does not. The first processor chooses the components. Each other processor checks that it has the same components with the same offsets and sizes, and sets the same `XCR0`. A processor that does not have them stays stopped, and the kernel logs a line for it: the machine runs on the other processors. The reason: the area of a thread is restored on any processor, so the format must be the same on all. The reason against a lower common choice: the first processor chose before the others started, and the processors of one machine report the same components (Intel and AMD give the same `CPUID` leaf `0xD` on the cores of a hybrid processor).

### 2. Where the area of a thread lives

The area is a fixed field of 2688 bytes, aligned on 64 bytes, in the entry of each thread in the thread table of the kernel (`Thread.extended_state`), as the frame of the general registers is. It is not pages that the budget of the thread pays. The reasons:

- The thread table is already a fixed table of 256 entries. A budget pays for a thread with its `threads` amount: the slot, its frame and its area. The area is a part of the slot, as the frame is.
- Pages of the budget would cost 4096 bytes for each thread for 832 bytes of use, a refusal path in `Thread_Create`, a free in the end of a thread, and a pointer in place of a field.
- The cost: 256 x 2688 bytes = 672 KiB of kernel memory, against 128 KiB with 512 bytes: 544 KiB more, the same on every machine, before any program starts. The processor records do not have an area: a save always goes to the area of the thread that the processor leaves (section 3).

The kernel writes an area at one time only: `Thread_Create` writes the start state. The start state is the bytes of a zero area with the x87 control word `0x037F` (offset 0), `MXCSR` `0x1F80` (offset 24), and, with `xsave`, `XSTATE_BV` = 3 (offset 512): x87 and SSE come from the area, and every other component starts in its init state (zero). With `fxsave`, the header is not read. A new thread therefore never sees a register of another thread.

### 3. When the kernel saves and restores: at a switch of threads only

The rule: **the kernel saves the extended state of a thread only when a processor leaves it for another thread, and restores it only when a processor takes a thread from a run queue. A kernel entry, an interrupt, and the return to the same thread neither save nor restore.** Between a restore and the next save, the registers of the thread stay live through every entry, because no code of the kernel changes an x87, MMX, SSE, AVX or opmask register (section 3a).

The reason is measured (2026-11-12). `kerneltool measure` gave one kernel entry of `locks` in 177 ns with `fxsave64` at each entry and `fxrstor64` at each resume (two runs within 0.4 %). With `xsaveopt64` at each entry from a program and `xrstor64` at each resume, it gave 229 and 249 ns: 29 to 41 % more. On the host (AMD Ryzen 7 5800X, one pinned core, the least of 200 batches, in cycles): `fxsave64` 72, `fxrstor64` 167, `xsaveopt64` 101, `xrstor64` 327, `vzeroupper` 2; the pair is 227 cycles with `fxsave64`, 430 with `xsaveopt64`, and 446 with `xsave64`. The instructions themselves are the cost: the pair `fxsave64` and `fxrstor64` is about 60 ns of the 177 ns of an entry. Other kernels save at a switch of threads for the same reason.

The places, all in `kernel/schedule.odin`:

- **A processor leaves a thread** (`schedule`, at the start of the part for the current thread): `extended_state_save` into the area of the thread. This one place covers each way to leave a thread: the end of a time slice (the timer), a wake preemption (the interrupt of another processor), a wait (the word wait, a deadline, a wait for a ring), a stop of the thread or of its program, and a fault of the program. The save comes before the thread can reach another processor: a thread on a processor is in no run queue (`thread_ready_held` only marks it Ready while its `processor` is not 0), it enters a queue only later in `schedule` (`queue_ready`, under the run lock), and the release of the run lock orders the save before the pick of the other processor. An ended thread is saved too; its slot is freed after the save (`thread_finish`), so the save never writes the area of a new thread.
- **A processor takes a thread** (`schedule`, after `schedule_pick`): `extended_state_restore` from the area of the thread, just before `run`. This covers a new thread (its start state), a thread that moved from another processor, and a thread that comes back. It also restores a thread that the processor took just after it left it: a restore costs little at a switch, and the alternative needs a rule of who owns the registers (below).
- **A thread continues after an entry** (`kernel_interrupt` calls `run` for the same thread): nothing. Its registers are live.
- **The idle wait**: nothing. The registers keep the state of the last thread, whose area is complete already.

Not done: a processor that takes again the thread whose state its registers still hold could skip the restore. That needs a field of the processor, "the thread whose state is in the registers, and its serial", set at each restore, and a field of the thread, "the processor whose registers hold its state", set by the processor that restores it, so that a thread that ran elsewhere in between is restored. It saves one restore when a processor runs one thread alone; it needs a measure.

The instructions: `xsaveopt64` and `xrstor64` with `EDX:EAX` = all ones (every component that `XCR0` enables); with no `xsave` or no `xsaveopt` on the first processor, `fxsave64` and `fxrstor64`. The first processor chooses the form at boot (`extended_state_form`); the scheduler passes it to the two procedures of `kernel/processor.asm`. No `vzeroupper`: the kernel has no SSE code, so no high half of a ymm register can slow an instruction of the kernel.

Why `xsaveopt64` (Intel SDM, volume 1, sections 13.6 and 13.9): the init optimization (a component in its init state is not written, and `xrstor` sets it to its init state without a read), and the modified optimization (a component that did not change since the last `xrstor` of this processor from this same address is not written). On the host the gain over `xsave64` is small (430 against 446 cycles for the pair); it costs nothing.

The trap of the modified optimization: if another writer changes an area between the `xrstor` of a processor from it and the next `xsaveopt` of that processor into it, the `xsaveopt` can skip a component, and the area keeps the bytes of the other writer. The kernel never makes this case:

- A processor saves a thread only in `schedule`, and that thread is the one that it restored last: it restored it when it took it, and it restores no other area until it leaves it. Between the two, only that thread and the kernel run on the processor, and the kernel restores nothing.
- No other processor writes the area while the thread is on this processor: a thread runs on one processor at a time, and the kernel writes an area only at `Thread_Create`, for a slot whose thread runs nowhere.
- The proofs at boot restore their own areas; the first thread on the first processor is restored before it runs.

A future operation that writes the extended state of a thread (a debugger) writes it only while the thread is on no processor: its area is complete then, and the next restore reads the new bytes. An operation that writes the area of a thread while its state is live on a processor breaks the rule, and must not exist. An operation that reads the extended state of a thread reads it only while the thread is on no processor: while it runs, the area is old.

Why not `xsavec` or `xsaves`: they write the compacted form, whose offsets depend on the components in use; `xsaves` also saves supervisor components (`IA32_XSS`) that the kernel does not use. The standard form has fixed offsets: the start state and the test read them directly.

A processor without `xsave` (a processor of x86-64 before about 2011, the default processor `qemu64` of QEMU, or `-cpu max,-xsave`): the kernel keeps `fxsave64` as its one other form, chosen once at start, and logs it. A processor with `xsave` but no `xsaveopt` (the first AMD processors with AVX, family 15h) gets the `fxsave64` form too.

### 3a. The kernel has no vector code

**A rule of the kernel**: no code that runs in the kernel executes an instruction that reads or changes an x87, MMX, SSE, AVX or opmask register, or `MXCSR`, except the three procedures of `kernel/processor.asm` that save and restore a thread (`extended_state_save`, `extended_state_restore`) and read the registers in the proof at boot (`extended_state_restore_and_read`). An interrupt handler runs kernel code while the registers of the interrupted program are live: the rule holds for it too, with no exception. So do the fault report, the idle wait and each kernel operation.

How the build keeps the rule:

- **The compiled code.** Odin writes the kernel as LLVM IR, and `llc` makes the object (`tools/kerneltool/modules.odin`). The IR has no target features on its functions, so the features of `llc` hold for all of it: `-mattr=-x87,-mmx,-sse,-sse2,-sse3,-ssse3,-sse4.1,-sse4.2,-avx,-avx2,-avx512f,+soft-float` (`KERNEL_TARGET_FEATURES`), the flags that the Linux kernel uses in the form of `llc`. The IR has vector types that the optimizer of Odin made (`<2 x i64>` for loops of copies): `llc` splits them into general registers. Copies of records become moves of general registers, or calls of the copy procedures.
- **Floating point.** The x86-64 calling convention passes `f32` and `f64` values in xmm registers; with no SSE, `+soft-float` passes them in general registers and makes their arithmetic calls of procedures. The kernel has no floating-point value of its own (`grep` of `f16`, `f32`, `f64`, `float` and `core:simd` in `kernel/` finds none). The IR has four procedures of the Odin runtime with floating point, the conversions of `f16` (`__extendhfsf2`, `__gnu_h2f_ieee`, `__truncsfhf2`, `__truncdfhf2`); no code of the kernel calls them, and the link drops them (`--gc-sections`).
- **The copies of memory.** `runtime/memory.asm` has a kernel form (`WITHOUT_VECTOR_REGISTERS`): 17 to 64 bytes in general registers, every read before the first write; more with `rep movsb` and `rep stosb`; a copy down in blocks of 8 bytes. Programs and the boot program keep the form with xmm0 to xmm4. The host tests of the kernel form are in `runtime/without_vector_registers`.
- **The instruction templates.** The small instructions of the kernel (ports, model-specific registers, control registers, `invlpg`, `lidt`, `ltr`, `xsetbv`, the copy of `user_copy`) are instruction templates in `kernel/instructions.odin` ("The instructions of the kernel", below). Each names its registers itself, and none names an x87, MMX, SSE, AVX or opmask register. The compiler puts them in the code of their callers, so the proof below reads them there.
- **The proof.** After the link of the kernel, the build disassembles it (`llvm-objdump -d`, AT&T syntax) and refuses it when an instruction outside the three procedures names `%xmm`, `%ymm`, `%zmm`, `%tmm`, `%st`, `%mm` or `%k0` to `%k7`, or is an x87, VEX, EVEX, AMX or opmask instruction, `wait` (the name that the disassembler gives to `fwait`), `emms`, `ldmxcsr`, `stmxcsr`, `xsave` or `xrstor` (`tools/kerneltool/vector_check.odin`, with its host tests). Each of the three procedures ends with a label `<name>_end` in `kernel/processor.asm`: the check allows the instructions of a procedure up to that label only, and refuses a kernel where another name follows the procedure. A check that reads nothing proves nothing, so the check also fails when it reads fewer than 10 000 instructions (the kernel has 31 145), when one of the three procedures is not in the listing, or when it sees no vector instruction in one of them, where one must be. Before `llc`, the build refuses kernel IR whose functions have target features of their own, which would take the place of the features of `llc`. The start code of the other processors is in the data section and is not disassembled: its `fninit` and `ldmxcsr` run once, at the start of a processor, before it runs a thread, and the first thread of that processor is restored.
- **Modules.** No module of a program runs in the kernel: the kernel is one module, `kernel = true` in the module table, and only that module is built with these features and checked. A module that would run in the kernel gets the same features and the same check.

### 4. The cost

Measured on 2026-11-12 with `kerneltool measure`: the test machine under KVM (4 processors) on the host of the tests (AMD Ryzen 7 5800X), two runs of each build, one machine at a time, a host load of 6.4 to 8.7 before each run (the limit for a valid measure is 8, so these runs are at its edge).

| | A save at each entry (`fxsave64` at each entry, `fxrstor64` at each resume) | This design (save and restore at a switch of threads) |
|---|---|---|
| Kernel entries in one second, one locker of `locks` (an entry that returns to the same thread) | 5 669 546 and 5 613 013: 176 and 178 ns for each entry | 8 063 360 and 8 359 466: 124 and 120 ns for each entry |
| Kernel entries in one second, 4 lockers | 20 326 826 and 20 503 040 | 26 945 066 and 27 561 173 |
| One hand-over between two threads by the word wait (a wake, a wait, a save and a restore) | | 128 and 125 ns with x87 and SSE in use; 133 and 127 ns with the ymm high halves in use |
| One empty kernel entry of the program `extended_state` | | 90 ns with xmm in use, 78 ns with ymm in use (one run) |

The reason for the design is the cost of the instructions themselves, measured on the host (one pinned core, the least of 200 batches, in cycles): `fxsave64` 72, `fxrstor64` 167, `xsaveopt64` 101, `xrstor64` 327, `vzeroupper` 2. The pair `fxsave64` and `fxrstor64` at each entry is 227 cycles, about 60 ns of an entry of 177 ns; the pair `xsaveopt64` and `xrstor64` at each entry is 430 cycles and makes an entry 229 to 249 ns. With this design an entry pays no pair, and each switch pays the pair of 430 cycles once.

| | What a switch saves and restores |
|---|---|
| A thread that never used AVX | x87 and SSE: the AVX component stays in its init state, so `xsaveopt` writes nothing of it and `xrstor` reads nothing of it |
| A thread that uses the ymm high halves | + 256 bytes in the save and the restore |
| A thread that uses AVX-512 | up to + 1600 bytes (the opmask and the two parts of zmm); not measured: the host has no AVX-512 |

The lines of `kerneltool measure`:

- `locks: kernel entries in one second, each locker on its own objects: ...`: entries with no switch.
- `locks: word wait, two threads wake each other: ...`: each wake is a switch.
- `extended_state: a hand-over between two threads by the word wait (...): ...`: one switch with x87 and SSE in use, then with the ymm high halves in use.
- `extended_state: the parts of a save and a restore, each alone in this program, ...` and `each instruction alone ...`: the cycles of each instruction of the save and the restore, measured by the program on its own area (`fxsave`, `xsave`, `xsaveopt` and `xrstor` are not privileged).
- `extended_state: an empty kernel entry, 100000 times: ...`: with xmm, ymm or zmm in use.

### 5. A hostile program

- **Can a program write its own area?** No. The area is in the thread table of the kernel, in the kernel half of the address space, whose pages no program maps (the page tables of the kernel half have no user bit, and the paging audit of each boot proves it). The processor writes the area at a switch; the kernel writes the start state; no kernel operation copies bytes of a program into an area.
- **A bad header.** `xrstor` faults (general protection) when a bit of `XSTATE_BV` is set for a component that `XCR0` does not enable, or when bytes 8 to 23 of the header (`XCOMP_BV` at offset 520, and the 8 bytes after it) are not zero in the standard form (Intel SDM, volume 1, section 13.8.1). Such a fault in `schedule` is a fault of the kernel and stops the machine. The kernel never makes such a header: the start state has `XSTATE_BV` = 3 and zeros after it, and an `xsaveopt` writes only bits of `XCR0`, which is the same on each processor that runs threads. The first processor runs two proofs at boot, before any program, and stops the machine with a sentence if one fails. First it restores an area with an x87 control word (`0x027F`), an `MXCSR` (`0x3F80`), the low half of xmm0 and, with AVX, the high half of ymm0 that are not their init state, and reads the registers back in the same routine: so the processor reads these values where the kernel writes them. Then it restores the start state and saves it again: this shows only that the start state does not fault and that the header of a save has no bit outside `XCR0`, because x87 and SSE in the start state are their init state, which `xsaveopt` does not write.
- **`MXCSR`.** `fxrstor` and `xrstor` fault if a reserved bit of `MXCSR` is set. `MXCSR` in an area comes from the start state (`0x1F80`) or from a save of the register. A program sets the register only with `ldmxcsr`, `fxrstor` or `xrstor` of its own memory, and these fault in the program (the program stops) when a reserved bit is set. So the register never holds a reserved bit, and a save never writes one.
- **The state of the program in the kernel.** The kernel runs with the registers, the `MXCSR` and the x87 control word of the program that entered. It never uses them (section 3a), so no value of a program can make the kernel fault, and the kernel cannot change a register of a program.

### 6. How a program knows what it can use

With no kernel operation: the processor tells it. `CPUID` leaf 1 gives `OSXSAVE` (`ECX` bit 27), which is the bit `CR4.OSXSAVE` that the kernel set; with it, `xgetbv` with `ECX` = 0 reads `XCR0`, the components that the kernel saves. An instruction set is usable when the processor has it (`CPUID` leaves 1 and 7) and when the kernel saves its registers. `support/instruction_sets` reads both once (`cpuid` and `xgetbv` as `asm` templates) and gives a `bit_set` of usable instruction sets: SSE to SSE4.2, POPCNT, AES, PCLMULQDQ; AVX, F16C, FMA, AVX2 when `XCR0` has x87, SSE and AVX; AVX-512 F, DQ, CD, BW, VL when `XCR0` also has the three AVX-512 components; BMI1 and BMI2, which use general registers. A program reads it once at its start: `CPUID` is slow in a virtual machine (an exit to the host). A program that uses an instruction that is not usable stops with an invalid opcode, its own fault.

### 7. The other parts

- **The other processors**: the start code of a processor sets `CR4` to `0x620` (PAE, `OSFXSR`, `OSXMMEXCPT`) before the kernel runs there; `processor_entry` writes the `CR4` of the first processor without `OSXSAVE`, then the extended state setup of section 1.
- **The idle wait**: a processor with no thread saves and restores nothing: it saved the last thread when it left it.
- **The boot program** (UEFI): not changed. It runs before the kernel, with the `CR4` of the firmware, and uses no AVX.
- **The faults of the kernel**: an interrupt or a fault of the kernel saves nothing, and the report of a fault of the kernel reads no extended state.
- **The readers of the state of a thread**: none. `Thread_State`, the reports of `Inspect` and the stop report of a program give no register of the extended state; the area is read only by the restore. A future reader (a debugger) reads a thread that is on no processor (section 3).
- **A thread that ends**: it is saved when its processor leaves it, then its slot is freed; the next thread of the slot gets the start state.

## The return to a program

A fault at the return to a program is a fault of that program, not of the kernel. Without the checks of this section, a thread whose saved state the processor refuses at `iretq` makes the processor fault in the kernel, and the kernel stops the machine: one program can stop the machine (property 2). The term is in `GLOSSARY.md`: refused return. The code is `kernel/return_to_program.odin`, `resume` and `interrupt_common` in `kernel/processor.asm`, `run` in `kernel/schedule.odin`; the test is the program `return_fault` (`kerneltool test return_fault`).

### 1. The frame of a thread, and who writes it

The kernel returns to a thread with `iretq`, from the frame of 22 values that it keeps for the thread (`Thread.frame`: 15 registers, the vector, the error code, then `rip`, `cs`, `rflags`, `rsp`, `ss`). `iretq` refuses, with a fault in the kernel, an `rip` that is not canonical, a selector that is not valid for the return, and, with the flag nested task set in the flags of the kernel, any return (in 64-bit mode). In 64-bit mode `iretq` does not touch the stack of the program: an `rsp` with no memory behind it faults later, in the program, at its first use of the stack.

| Writer of the frame | Fields | Can a program make `iretq` refuse it? |
|---|---|---|
| An interrupt or an exception from a program: the processor pushes the state of the program, and `kernel_interrupt` copies it | all | Yes. `rip` is `USER_END` (2^47, not canonical) when an interrupt comes after an instruction that ends at the last byte below `USER_END`: a program can map executable memory at the last page (`Memory_Map` refuses only an address at or above `USER_END`). `rsp` is any value that the program put in it, also one that is not canonical. `cs` and `ss` are the selectors of programs: the table of descriptors has no other descriptor that a program can load. |
| `syscall` (`kernel_enter`): `rip` is the return address that the processor wrote in `rcx`, `rflags` the flags that it wrote in `r11` | all | Yes, every time: a `syscall` in the last two bytes below `USER_END` gives the return address `USER_END`. `rsp` as above. |
| The flags of the kernel at `syscall`: the flags of the program less the mask of `MSR_SFMASK` | the flags of `iretq` itself | Yes, if the mask does not clear nested task, which a program sets with `popfq`: the kernel then runs with it, and its `iretq` faults. `MSR_SFMASK` clears it (section 2). |
| `Thread_Create` and `Program_Start` (`thread_create`) | `rip`, `rsp`, `cs`, `ss`, `rflags` | No: an entry at or above `USER_END` and a stack above `USER_END` or below 8 are refused (`Bad_Address`); `cs`, `ss` and the flags are constants. |
| `run`: `rax` after a kernel entry (the time) | `rax` | No: a general register. |
| Another writer (a debugger, a restart, a fault handler that changes `rip`) | | None exists. A future one writes the frame only through the rules of section 2, and the frame is checked again before each return. |

### 2. The first layer: the frame is made safe before each return

`run` is the one procedure that calls `resume`, and `resume` is the one place where the kernel returns to a program. At the start of `run`, `return_frame_prepare` makes these hold, each one a line of the code:

- `cs` is the code selector of programs and `ss` their data selector.
- `rflags` keeps from the program only the bits of `RETURN_FLAGS_OF_A_PROGRAM` (carry, parity, adjust, zero, sign, trap, direction, overflow, resume, alignment check, identification), and has the interrupt flag and the reserved bit 1 set: IOPL 0, no nested task, no virtual-8086 flag, interrupts on.
- `rip` is below `USER_END`: canonical, and in the half of a program. Else the return is refused, with the field "instruction address".
- `rsp` is canonical. Else the return is refused, with the field "stack address". A program that keeps an address that is not canonical in `rsp` is stopped at its next return: it cannot use it as a stack, and a processor can refuse it at `iretq` (the manuals of Intel and AMD differ on this check; the kernel does not depend on either).

A refused return stops the program of the thread, as a fault of that program (`program_return_refused`): the stop code `STOP_CODE_RETURN`, the instruction address in `instruction`, the refused value in `address`, the module of the instruction, and one line of the log, "kernel: program ... stopped: the kernel cannot return to its thread: ...". Then the processor continues in `schedule` at the top of its kernel stack (`schedule_on_a_fresh_stack`, as `first_run` does), which ends the thread and runs another one. The invariant: after a refused return, every frame on the kernel stack is dead (`run` and `resume` never return), so a chain of refusals in a row uses the stack of one `schedule` and one `run`, whatever its length.

Two more ways into the same check:

- **A stack address that is not canonical at a `syscall`.** `kernel_enter` stores the `rsp` of the program at `gs:8` and pushes it in the frame; it reads and writes nothing through it, and it loads the kernel stack before any push. So the entry takes it, and the return refuses it, as after an interrupt.
- **The trap flag at a `syscall`.** `MSR_SFMASK` clears TF for the kernel, and the frame gives it back to the program (it is a bit of `RETURN_FLAGS_OF_A_PROGRAM`). The trap then comes in the program, after its first instruction after the return: a debug exception from a program (vector 1), which `kernel_interrupt` gives to `program_fault`, so the program stops with the code `STOP_CODE_FAULT + 1` and its report. The text of the manuals does not tell, for sure, that no single-step trap of the `syscall` itself is delivered at privilege 0, at the first instruction of `kernel_enter`; such a trap would be a fault of the kernel there. The test case "the trap flag at a syscall" shows it: the machine goes on, and the child stops on its own trap.

`MSR_SFMASK` is `0x44700`: `syscall` clears interrupt, trap, direction, user access and nested task. An interrupt gate already clears nested task, trap and interrupt; `interrupt_common` clears user access (`clac`) and direction (`cld`). So the kernel never runs with a flag of the program that changes `iretq`.

### 3. The second layer: a fault of the `iretq` of `resume` is a fault of the thread

After the first layer, no cause is known for which the processor refuses the `iretq` of `resume`. The second layer makes an unknown cause a fault of the thread too, and not of the kernel. Each fact at the instant of that `iretq`, from the code:

- **The stack.** `resume` copies the frame of the thread to the top 22 * 8 bytes of the kernel stack of the processor (`[gs:0] - 176`), sets `rsp` there, and pops it. At the `iretq`, `rsp` is `[gs:0] - 40`: the five values `rip`, `cs`, `rflags`, `rsp`, `ss`. Nothing below it lives: a kernel entry starts at the top of the stack and never continues an earlier one, and `resume` never returns. The top 176 bytes are where each entry from a program puts its frame, so the copy writes over a frame that `kernel_interrupt` already copied to the thread.
- **The fault frame.** A fault of `iretq` comes at privilege 0, with no change of stack (no gate of the vectors 11, 12, 13 has a stack of its own). The processor pushes its frame below `rsp`, aligned on 16, over the part of the copy that the pops already read and below it. The thread table is not written. (A `resume` that returns from the frame in the thread table lets such a push write over the thread table.)
- **gs.** `resume` ran `swapgs` before the `iretq`: the gs base is the one of the program (the thread record, or what the program loaded), and the base of the processor record is in `MSR_KERNEL_GS_BASE`. The saved `cs` is the kernel's, so the test "did the interrupt come from a program" is false. `interrupt_common` therefore tests the saved `rip`: equal to `resume_return` (the label of the `iretq`), and the vector 11, 12 or 13 (segment not present, stack fault, general protection: the faults of `iretq`), it runs `swapgs`. At that one instruction no other instruction of the kernel runs with the gs of a program, and interrupts are off: the only other interrupts there are an NMI and a machine check, which come between two instructions (vector 2 or 18). They get no `swapgs`, the kernel stops the machine for them, and its report reads nothing through gs.
- **The registers.** The general registers are those of the program (the pops ran); the stub saves them in the fault frame. The frame of the thread in the thread table is unchanged: the report uses it. The extended state of the thread is live in the registers, as at each return.
- **The thread.** It is the current thread of the processor: `run` runs only for `cpu.current`.

`kernel_interrupt` makes the same test first (`resume_return`, vector 11 to 13, from the kernel) and calls `return_refused_by_the_processor`: the stop of the program with the field "the processor refused the return" and the vector in the stop report, then `schedule` on a fresh stack, which saves the extended state of the thread and ends it.

No program can make this layer run on the kernel of the system. One machine of the test runs it on purpose: the module `kernel_without_return_check` is the same kernel, built with the setting `TEST_BUILD_SKIPS_THE_INSTRUCTION_ADDRESS_CHECK` (a `-define` of that one module in the module table, `tools/kerneltool/modules.odin`), which skips the check of the instruction address. Its boot volume is `boot_volume_without_return_check.img`, which only the second machine of `kerneltool test return_fault` boots; there the child of the instruction address reaches the `iretq`, the processor refuses it, and this layer stops the child. A reader knows that the kernel of the system does not have the setting: the module "kernel" of the table has no define, so the constant is `false` and the `when` keeps the check; a kernel with the setting writes "kernel: TEST BUILD: the check of the instruction address before a return to a program is skipped" at boot, and `machine_test` fails every machine that is not of that volume and whose log has that line.

The cost: the copy of 176 bytes at each return, on a line of the stack that the entry wrote; `return_frame_prepare` is three stores, two compares and one mask. The copy is 11 pairs of moves of 8 bytes in general registers. Measured on 2026-11-12 (`kerneltool measure`, QEMU with KVM on a Ryzen 7 5800X, `locks: kernel entries in one second` with one locker, a host load of 7 to 14 before each run, so the numbers hold one against the other): with the moves 8 267 093, 8 273 493 and 8 351 786; with `rep movsq` in their place 7 401 813 and 7 513 813. The kernel before the copy made 8 063 360 and 8 359 466. The copy by moves costs nothing that this measure sees, and `rep movsq` costs a tenth, so the kernel has only the moves.

### 4. What stays

- An NMI or a machine check at any instruction between the `swapgs` of `resume` and its `iretq` (the 15 pops, the add, the `iretq`) arrives with the gs of the program and is not recognised: the kernel stops the machine, with a report that reads nothing through gs. A program cannot cause it: the kernel sends no NMI, and a machine check is a fault of the hardware.
- The fault of `kernel_enter` between its `swapgs` and the switch of the stack cannot come: the instructions there touch only the processor record. An NMI there stops the machine, as above.

## The control registers of a processor

The kernel writes its own control registers on each processor, the first one and the others, in `processor_setup` (`kernel/processor.odin`). It keeps no bit that the firmware set for its own reasons: such a bit would decide what a program sees. The values are constants with asserts of their bits. The first processor writes one line at boot: "kernel: control registers: cr0 ..., cr4 ...", with UMIP on or not.

**CR0** is one value, `0x80050033`:

| Bit | Name | Why |
|---|---|---|
| 0 | protected mode | needed for long mode |
| 1 | monitor coprocessor | `wait` obeys the flag task switched, which stays clear |
| 4 | extension type | always 1 on a 64-bit processor |
| 5 | numeric error | an x87 error is `X87_Floating_Point` of the thread. Without it, the error goes out on line 13 of the interrupt controller: a device interrupt of the program that owns that line, and no record |
| 16 | write protect | the kernel obeys read-only pages |
| 18 | alignment mask | a program that sets the flag AC gets `Alignment_Check` for an access that is not aligned, on every machine. It acts at level 3 only: the kernel, and its `stac` and `clac`, are not changed. Without it `Alignment_Check` would be a kind that the kernel lists and never delivers |
| 31 | paging | needed for long mode |

Clear: emulation (2) and task switched (3), so device not available never comes (the kernel keeps the extended state of the thread in the registers while it runs); not write-through (29) and cache disabled (30), so the caches work. The start code of the other processors loads the CR0 of the first processor, read after its setup, then `processor_setup` writes the value again.

**CR4** keeps four bits of its value before `processor_setup`: the physical address extension (5), which long mode needs, and `OSFXSR` (9), `OSXMMEXCPT` (10) and `OSXSAVE` (18), which the setup of the extended state set just before ("The extended state of the processor"). The bit of the fifth level of the page table (12) is 0 and stays 0: the boot program loads tables of four levels and does not change CR4, the count of levels cannot change in 64-bit mode, and each walk of the kernel has four levels. It adds, when `CPUID` has them:

| Bit | Name | `CPUID` | Why |
|---|---|---|---|
| 6 | machine check | leaf 1, `EDX` bit 7 | a machine check is the exception 18, which stops the machine with a line; without it the processor shuts down with no line |
| 11 | UMIP | leaf 7, `ECX` bit 2 | `sgdt`, `sidt`, `sldt`, `smsw` and `str` of a program give `General_Protection`, so a program reads no address of a table of the kernel |
| 20 | SMEP | leaf 7, `EBX` bit 7 | the kernel does not execute the memory of programs |
| 21 | SMAP | leaf 7, `EBX` bit 20 | the kernel uses the memory of programs only in `user_copy` |

Every other bit is cleared, among them the global pages, the time stamp disable, the base registers of `fs` and `gs` for programs, and the process context identifiers.

**With no UMIP**, a program reads with `sgdt` the address and the limit of the segment table of its processor (in the record of the processor), with `sidt` the address of the interrupt table of the kernel, and with `smsw` the low 16 bits of CR0. `sldt` gives 0 (the kernel has no local table) and `str` the selector of the task state. These are addresses of the kernel half, which a program cannot read or write; they tell where the kernel placed its tables, nothing else.

**DR7** is 0x400 (no breakpoint on) and **DR6** 0xFFFF0FF0 (no status) on each processor: no breakpoint of the firmware stays on. A debug exception in the kernel stops the machine, and the entry of `syscall` runs a few instructions on the stack of the program before it takes its own.

**A non-maskable interrupt, a double fault or a machine check** stops the machine with a line, also when a program ran: none is a fault of an instruction of that program, and to stop only that program would hide the fault of the machine or of the kernel.

## The instructions of the kernel

The small instructions of the kernel (ports, MSR, `cr3`) are `asm` templates; the cycle counter and the copy and fill of memory have the forms of sections 2 and 4. No measure of this form is recorded (section 6). The term is in `GLOSSARY.md`: instruction template. The code is `kernel/instructions.odin`; what stays in assembler is in `kernel/processor.asm`.

### 1. What a template is

An instruction template is an `asm` procedure of Odin (release `dev-2026-11a`). Its parameters and results are values in registers. The specification block between `[` and `]` pins a parameter to a register (`port = %dx`), ties an input to an output in one register (`count -> count_left = %rcx`), and declares the effects: `#volatile` (the compiler never removes the template, never merges two calls, and keeps their order) and `#clobber memory` (the compiler keeps each load and store on its side). The compiler checks each instruction against its table of the forms of x86-64, and writes the template into the LLVM IR as inline assembler at each call. So a template costs no call, no return, and no move of its arguments into the registers of the calling convention.

The syntax comes from the tests of the compiler (`tests/internal/test_asm_*.odin` in the source of the release) and from its checker (`src/check_asm.cpp`), and from the templates of other packages: `rdrand` and `rdseed` (`support/random/entropy.odin`), `cpuid` and `xgetbv` (`support/instruction_sets`).

### 2. The templates of the kernel

| Template | Instruction | Where the kernel runs it often |
|---|---|---|
| `port_write_8`, `port_read_8` | `out`, `in` (8 bits) | each byte of the log on the serial port (a read of the status and a write), the end of a line interrupt of the 8259 |
| `model_specific_register_read`, `model_specific_register_write` | `rdmsr`, `wrmsr` | each register of the interrupt controller in x2APIC mode (the end of an interrupt, the timer, the interrupt to another processor), and the gs base of the program at a switch of threads |
| `control_register_3_read`, `control_register_3_write` | `mov` from and to `cr3` | each switch to a thread of another program, and the answer to `processor_sync` |
| `control_register_0_read`, `control_register_0_write`, `control_register_2_read`, `control_register_4_read`, `control_register_4_write` | `mov` from and to `cr0`, `cr2`, `cr4` | `cr2` at each page fault; the others at the start of a processor |
| `debug_register_6_write`, `debug_register_7_write` | `mov` to `dr6`, `dr7` | once, at the start of a processor |
| `page_flush` | `invlpg` | each page of an unmap, a decommit or a change of protection |
| `processor_self` | `mov` from `[gs:16]` | many times in each kernel entry: each lock, each operation |
| `interrupt_table_load`, `task_register_load` | `lidt`, `ltr` | once, at the start of a processor |
| `extended_control_register_write` | `xsetbv` | at the start of a processor |
| `user_copy` | `stac`, `rep movsb`, `clac` | each kernel operation that reads or writes the memory of the caller |

Each template is `#volatile` and has `#clobber memory`: the meaning is that of the call that it replaces, which the compiler could not move and which could change any memory. The instructions with two halves (`rdmsr`, `wrmsr`, `xsetbv`) are templates with two values of 32 bits, and a procedure with `#force_inline` joins or splits the 64 bits. `in` and `out` have no operand in a template: the pinned registers `dx` and `al` are their operands, and their widths choose the form. The table of the compiler (`src/asm_tables_amd64.cpp`) lists no read and no write of a register for these two, so the checker would refuse an input that is only pinned (as unused, with `-vet`) and an output that no instruction writes. Each register is therefore an input tied to an output, and a procedure with `#force_inline` drops the outputs; `in` gets 0 as the first value of `al`, as the `xor eax, eax` of an assembler form. `user_copy` chooses between the copy with `stac` and `clac` and the copy without them by a test of `user_access_guard`, because `stac` and `clac` exist only on a processor with SMAP.

The names are complete words (`model_specific_register_write`, not `msr_write`). `port_write_8`, `port_read_8`, `page_flush`, `processor_self` and `user_copy` keep their names: the system library has `port_write_8` and `port_read_8` for programs, and one concept keeps one name.

Already in the code of their callers through intrinsics, so not templates: the cycle counter (`intrinsics.read_cycle_counter`, `rdtsc`), `cpuid` (`intrinsics.x86_cpuid`), `pause` (`intrinsics.cpu_relax`) and the memory barriers (`intrinsics.atomic_thread_fence`). The kernel has no `rdtscp`. `swapgs` is only in the entries and in `resume`, which stay in the assembler file.

### 3. What stays in `kernel/processor.asm`, and why

A template is an expression: it takes values and gives values, and the compiler owns the stack and the registers around it. Code that owns the stack or the frame cannot be one.

- `interrupt_common`, the 80 stubs, `kernel_enter`: they build the frame of an entry on a stack that they choose, and `swapgs` there depends on where the entry came from.
- `resume` and `resume_return`: they replace `rsp`, pop the frame and end with `iretq`; they never return to the compiled code.
- `stack_switch`: it replaces `rsp` and jumps.
- `gdt_load`: it reloads `cs` with a far return that uses its own return address.
- `extended_state_save`, `extended_state_restore`, `extended_state_restore_and_read`: the only code of the kernel that names a vector register. The check of the build allows vector instructions only between the start of each and its end label (`<name>_end`); a template inlined into compiled code has no such label.
- `idle_wait` (`sti`, `hlt`, `cli`) and `processor_stop` (`cli`, then `hlt` in a loop): the checker of the compiler takes `hlt` as an instruction after which the flow ends, so it refuses a template that continues after `hlt`. A template marked as one that never returns (`-> !`) is accepted, but a `hlt` continues after an interrupt or an NMI, and the compiled code after such a template is code that the compiler took as unreachable. Both procedures wait: the cost of a call does not matter there.
- The start code of the other processors (`ap_start_begin` to `ap_start_end`): 16-bit and 32-bit code that the kernel copies to a fixed page.

### 4. The copy and the fill of memory

`runtime/memory.asm` stays an assembler file, in its two forms (the form with xmm registers for programs and the boot program; the form with general registers, `WITHOUT_VECTOR_REGISTERS`, for the kernel). Reasons:

- LLVM calls `memcpy`, `memmove` and `memset` by these names for the copies of records and for `intrinsics.mem_copy` and `mem_zero`. These calls stay calls whatever the body is: a template cannot be the target of a call. The kernel calls the copies only that way.
- The forms are chosen by size at run time (under 16 bytes, 16 to 64, the string instructions, the loop of 64 bytes). A template with the same instructions is not faster; inlined at each call, it makes the code larger.
- The host tests (`runtime/memory_test.odin`, `runtime/without_vector_registers`) assemble the same file with `HOST` defined, and so test the code that the system runs.

The copy of `user_copy` is a template (`rep movsb`), not a call by name: it is the one copy of the kernel with that form.

### 5. The proof that the kernel has no vector instruction

A template is compiled code: the check of the build (`tools/kerneltool/vector_check.odin`) disassembles the linked kernel and reads each template in the code of its callers. No template of the kernel names a vector register, so the check passes. The kernel imports the contract library only; the templates with vector registers of other packages (for programs) are not in its build.

### 6. The measure

`kerneltool measure`, with the templates and with calls in their place, two runs of each build, with the load of the host:

- "locks: kernel entries in one second", with one locker and with 4 lockers (8 063 360 and 8 359 466 with one locker with calls). Each entry runs `processor_self` several times (each lock) and `user_copy` for its arguments. Expected: more entries, from the call and the return saved at each.
- "clock: the time page": its reads do not enter the kernel; expected: no change. It shows the noise of the run.
- The measure of the copy and the fill at the start of the compositor ("compositor: copy_bytes_without_overlap, ns for ..."): `runtime/memory.asm` did not change; expected: no change.

No number of this measure is recorded yet.

## Kernel events

The kernel has fixed event points (kernel entry, thread switch, fault, lock take). A program with a grant gives the kernel a table of rules (kind of event, program, threshold); the kernel applies them in bounded time and writes the records in a ring. The terms are in `GLOSSARY.md`: kernel event, event point, observed kinds, event rule, event table, event ring, event record, lost count, performance counter. The code is `kernel/events.odin`, the event points in `kernel/enter.odin`, `kernel/schedule.odin`, `kernel/program.odin` (`kernel_interrupt`) and `kernel/lock.odin`, the operation `Events_Set`; the test is the program `kernel_events` (`kerneltool test kernel_events`).

### 1. What it is, and what it is not

The kernel has four fixed event points. A program with the right `Events` on the machine gives the kernel an event table: at most 16 rules, and a memory object for the records. At an event point, the kernel tests the rules of the kind of the event; when a rule accepts the event, the kernel writes one event record into the event ring of its processor. The program reads the rings with no kernel entry.

No bytecode, no verifier and no compiler: a rule is a record of fixed fields that the kernel compares, and its cost has a bound that does not depend on the rule (at most 16 tests of a few fields). Property 1: one operation, `Events_Set`, number 32. Property 13: the rules are a table, the records are fixed records in a ring for each processor. Property 20: a grant, and a program handle for each named program.

### 2. The kinds of kernel events

| Kind | Event point | Program and thread of the record | detail | value_0 | value_1 |
|---|---|---|---|---|---|
| `Operation` | each command of a kernel entry (`enter`): the start and the end of `command_run` | the caller | the `Operation` | its cycles, from its start to its end, waits for locks included | its `Status` |
| `Switch` | a processor takes a thread from a run queue (`schedule`, after the restore of its extended state) | the thread taken | 0 | the program slot of the thread that the processor left just before (0: none) | the number of that thread |
| `Fault` | an exception of a thread of a program (`kernel_interrupt`), after the kernel acted on it | the faulting thread | the vector | the address of a page fault, only for a rule that names the program (section 5a), else 0 | `Event_Fault_Outcome`: first use, fault ring, or stopped |
| `Lock_Wait` | a lock of the kernel taken after a wait (`lock_take`) | the current thread of the processor (0: none) | the `Lock_Kind` | the cycles of the wait | 0 |

The time of a record is the cycle counter at the event point (the end of an operation or of a wait). The event of a kernel entry is "the operation number and its duration": a kernel entry runs up to 32 commands of its kernel ring, so the event is one command, which has one operation number. A wait of the word wait is a `Switch` when the thread runs again; the `Operation` of `Word_Wait` itself returns before the wait.

### 3. The rule and the record

The rule (`op.Event_Rule`, 64 bytes): the kind; the flag `Match_Detail` and a detail (an operation number, a vector, a lock kind); a program (a program handle of the caller with Read, or 0 for every program and the kernel itself); a least duration in nanoseconds (Operation and Lock_Wait; at most 1 s; the kernel converts it to cycles once, when the table is given); "one in N" (0 and 1: each). A rule accepts an event when its tests pass: kind, program, detail, least duration; then "one in N" over the events that passed the other tests of this rule since the table was given. A count, never a random source in the kernel. An event that one rule or more accept is one record.

The record (`op.Event_Record`, 64 bytes): the cycle counter, the kind, the processor, the program slot and its serial, the thread number, the detail, two values, one reserved word.

### 4. The operation

`Events_Set` (32): (machine with Events, memory or 0, address of a table of `Event_Rule`, count, records in each ring) -> the bytes of one ring, the count of processors.

- With a memory handle: the memory object is `Contiguous`, with the right Write, not device memory, and holds one ring of `EVENT_RING_HEAD_BYTES` (128) + records * 64 bytes for each processor. records is a power of two, 16 to 2^20. Else `Bad_Operation`. More than 16 rules: `No_Slot` (its error record: Too_Long, Records). A rule that is not valid (an unknown kind or flag, a reserved word not 0, a duration for Switch or Fault, a detail for Switch, a duration above 1 s, a bad program handle): `Bad_Operation` or `Bad_Handle`.
- The table of the caller is replaced; the table of another program is refused (`Bad_State`): the machine has one table, and one observer does not end the observation of another one in silence.
- With memory 0: the caller takes its table away (`Bad_State` if it has none). When the operation returns, no processor writes in the old memory object.
- The table also ends when the program that gave it ends (`program_cleanup`, before its handles close): the owner of the table is that program; the kernel forgets the rules and releases the memory object.
- **The table lives while its right lives.** When the last machine handle of the owner with `Events` closes or is revoked, the table ends (`handle_close` calls `event_right_closed` for a machine handle with `Events`; a `Handle_Close` and a revocation both reach it, and the cleanup of a program too). Without this, a revocation would not take back what the right gives: the kernel would go on writing the work of every program into the memory of a program that lost the right. `Handle_Close` of a machine handle with `Events` asks for the control lock, under which the table changes; a revocation holds it already. The kernel writes a line for each end that the owner did not ask for: "kernel: the event table of program ... ended: its program stopped; ..." or "...: its right Events ended; ...". It writes the line of a given table once for each program, so a program that replaces its own table many times does not fill the log.

### 5. The grant

The right `Events` on the machine handle, beside `Inspect` and `Schedule` (the right of `Strategy_Set`). Why not `Inspect`: `Inspect` gives counts and states; `Events` gives the order and the duration of the work of each program, to the cycle: a precise clock over other programs (property 20, line 17). A program that reads the reports must not get it as a side effect. The root service gives it by name (the grant `Events`); today only to `kernel_events`, with no `Give`: a program of the system cannot pass `Events` on. The person can revoke it (`revoke("kernel_events", "machine")` in the console), and the table ends with it (section 4). A rule that names a program needs a program handle with Read; a rule for every program needs only the right on the machine.

### 5a. What a record shows of another program

A holder of `Events` sees the work of other programs. Each field, what it shows, and when the kernel gives it:

| Kind | Field | What it shows of another program | Given |
|---|---|---|---|
| All | time, processor, program slot and serial, thread number | when and where a thread of the program runs in the kernel, to the cycle: the precise clock of property 20, line 17 | always: it is what the right `Events` is for |
| Operation | detail | the operation number (`Operation`): what kind of request the program makes. No argument of the operation: no handle, no address, no count, no byte of its memory | always |
| Operation | value_0 | the cycles of the operation, waits for locks included: the duration can follow the size of the work (the pages of a commit, the ranges of a protection) | always |
| Operation | value_1 | the `Status` of the operation | always |
| Switch | program and thread, value_0, value_1 | which thread a processor took, and which program and thread it left: the order of the work of the programs | always |
| Fault | detail | the vector | always |
| Fault | value_0 | the address of a page fault. The order of the pages that a program touches for the first time can show data that the program never gives (a table read at an index that is a secret): the "controlled channel" of the attacks on enclaves | only when a rule that names the program accepted the event; a rule for every program gets 0 |
| Fault | value_1 | the outcome: first use, fault ring, or stopped: the count of the pages that a program touches, in time | always |
| Lock_Wait | detail, value_0 | the kind of the lock and the cycles of the wait of the current thread of the processor: how the work of other programs contends with it | always |

Why Read is the right that gives the address of a fault: a program handle with Read gives `Program_State` with the stop report of the program, which holds the address of its fault and its stack trace (the reports of `Inspect` hide them: the right `Inspect` alone does not give them). So a rule that names a program gives nothing that its handle does not give already, but in time. `Events_Set` checks Read on each program handle of a rule.

### 6. Where the records go

One event ring for each processor, in one contiguous memory object that the caller made and its budget paid (property 14). The ring of processor p starts at p times the bytes of one ring. A ring has a head of two lines (the line that the kernel writes: `written`, `lost`, the capacity and the processor; the line that the program writes: `read`), then the records.

- **One ring for each processor**: the event point of a processor writes only its own ring and its own processor record, so it takes no lock, and no line is written by two processors (property 13).
- **Memory of the caller, not pages that the kernel owns and maps read-only.** The hazard of memory that a program writes is a value that the kernel reads and trusts. The kernel reads one word of a ring, `read`, and trusts it for nothing: it indexes with its own counts (`event_written`, a capacity that is a power of two), so it never writes outside the ring; a false `read` loses records of the program, or lets the kernel write over records that the program did not read: nothing else. It never reads a record back. A ring that the program can only read still needs a word that the program writes (what it consumed), or an operation for each read, which is the cost that a ring removes; so the read-only form adds a mapping that the kernel makes, and its own lifetime rule, and removes no hazard. The fault ring made the same choice for another reason (it needed no new memory: 16 records in the thread record); that reason does not hold here (a ring of 8192 records is 512 KiB), so the choice comes from the reading above.
- **The lifetime**: the kernel holds one reference to the memory object while the table exists. A close of the handle of the program, an unmap, a revocation or a decommit end holdings of programs, not the reference of the kernel: the frames stay until the kernel releases them, after the synchronization of section 8. A contiguous object has all its frames from its creation; they do not move; the direct map gives each one at a fixed offset. So an event point writes through the direct map, never through an address of a program: no fault, no page table of a program, no `user_copy`.
- **Device memory** (`Device_Create` of kind Memory) is refused: the kernel would write into the registers of a device.
- The cost of the reference: the object counts one more reference. That changes nothing for a contiguous object, whose decommit and the protection of a part are refused anyway.

**A full ring.** The kernel keeps its own count of written records and the last `read` that it loaded. When the difference reaches the capacity, it loads `read` once more; if the ring is still full, it drops the record and adds 1 to its lost count, which it stores in the head (`lost`). Never a wait, never a silent loss, never a write over a record that is not read.

### 7. The work at an event point

- **With no rule of its kind**: one load of `observed_kinds`, a word in the first line of the processor record (the line that each kernel entry reads already: `current`), and one branch. No call, no lock, no other memory. The event points of an operation and of a lock wait read the cycle counter at the start only when the event is wanted; their end tests a local value (0: no start).
- **With a rule of its kind for other programs only**: after the first branch, one load of the set of the program slots of the kind (`Event_Table.programs`, one word for each kind: bit n for the program slot n, bit 0 for a rule for every program; the machine has 64 program slots), a mask (`1 | 1 << program`), and one branch. No read of the cycle counter, no call (`event_wanted`). The set is a part of the table, published with it under the rule of section 8: it is read only after the acquire load of the word said that the kind has a rule. The event point of a lock wait finds its program through `current` and its thread only after the first branch.
- **With rules**: a call of `event_record`. It loads the word again (a wait for a lock between the start and the end answers `processor_sync`: section 8), tests the rules (at most 16, each a few compares; a rule with "one in N" adds 1 to its count with an atomic addition and divides), and writes one record of 64 bytes and the count `written` of its ring. No lock, no wait, no call of the scheduler, no address of a program.
- **"One in N" is exact across processors**: one count for each rule, in its own line, with an atomic addition. This is the one place where two processors can write one line on an event point: only for a rule with "one in N", and only when the events of that rule come on two processors at one time. A count for each processor would keep the lines apart, but "one in N" would then mean one in N on each processor, and N events of one thread that moves between processors would not give N / 10 records.

What an event point never does: fault (the frames of the ring are mapped by the direct map and held by the kernel), take a lock (the interrupted path can hold any lock: an event point is inside `lock_take`), wait, call the scheduler, answer `processor_sync`, use an address of a program.

### 8. How the table changes while other processors read it

The event table, the ring fields of each processor record and the counts of "one in N" change only under the control lock, and only while the observed kinds of every processor are 0 and every other processor answered a `processor_sync` since they became 0 (`event_table_end`, `event_table_give`).

1. To end a table: store 0 in the observed kinds of each processor, then `processor_sync` to every other processor, then release the memory object.
2. To give a table: end the table that exists (as in 1), write the new table, the ring fields of each processor record and the heads of the rings, then store the observed kinds of each processor last (an atomic store; the event point loads it with an acquire).

Why it is correct: a processor answers `processor_sync` only at a kernel entry, in its idle wait, and while it waits for a lock; `event_record` contains none of these. So a processor that read its word as not 0 ends its use of the table before its next answer. A processor that answered loads its word as 0 after: the store of 0 and the store of `pending` that it saw are two atomic stores of one processor, which x86-64 keeps in order, and its load of `pending` comes before its load of the word. After the synchronization, no processor reads the old table or writes the old rings: the frames can go.

Why not a generation word: a generation tells a reader that the table changed during its read, but the reader can have written into memory that the change released; the release needs a moment after which no reader runs, and `processor_sync` gives it. Why not a stop of each processor at a safe point: `processor_sync` is that in its smallest form; each processor passes one point, none stops. The cost is one synchronization for each change of the table: an operation of an observing tool, rare.

The locks: `Events_Set` holds the program lock of the caller and the control lock (it asks for it); the end of a table takes the log lock (one line) and the frame lock (`region_release`), both after them in the order. The end of a table in `program_cleanup` holds the control lock and no program lock.

### 9. The fault ring and the fault event

The fault ring is a separate mechanism with its own operations; kernel events do not change it. A fault event is an observation: a record that a program with the right `Events` reads later; nothing waits for it, and a full event ring loses it. A record of the fault ring is a delivery: the faulting thread waits until its own program answers, and a full fault ring stops the program. The event point of a fault comes after the kernel acted, so its record says what the kernel did: `First_Use` (a page on first use was given), `Fault_Ring` (the fault went to the fault ring), `Stopped` (the program stops).

### 10. The processor counters

An event record carries the cycle counter only (its time, and the durations of `Operation` and `Lock_Wait`). The kernel detects the performance counters at boot and writes one line of the log; it programs none and has no `rdpmc`.

- **Intel**: the architectural performance monitoring is `CPUID` leaf `0xA` (its version, its general counters and their width, its fixed counters: instructions retired, cycles).
- **AMD**: leaf `0xA` is an Intel leaf. AMD has 4 legacy core counters, 6 with the core counter extension (`CPUID` `0x80000001`, `ECX` bit 23), and the monitoring version 2 from Zen 4 (`CPUID` `0x80000022`). The host of the tests is an AMD Ryzen 7 5800X (Zen 3): no version 2.
- **The test machine**: QEMU with `-cpu max`, KVM first and TCG when KVM is absent (`tools/kerneltool/main.odin`). Its first boot line: "kernel: performance counters (a guest of a hypervisor): AMD, core counter extension yes, monitoring version 2 no, 0 core counters in CPUID 0x80000022". TCG has no performance counters. KVM gives a guest a virtual PMU when its module has `enable_pmu` and QEMU asks for it (the CPU property `pmu`); whether `-cpu max` asks for it by default is not verified. The line of the boot says what the guest sees: "kernel: performance counters (a guest of a hypervisor): ...".
- So no test reaches the counters reliably: the code for their registers is not written. That code needs a test machine whose boot line shows the counters, and a test that compares a count of instructions retired with a known loop.

### 11. The measure

The load child of `kernel_events` measures its own kernel entries for 300 ms, four times: one operation `Memory_Size` in each entry, as the lockers of `locks`, with its own count of the loop and its own time (`system.nanoseconds`, no kernel entry). The rate is the count times 10^9 divided by the time. The four tables:

1. No rule.
2. One rule that names another program: `Operation`, the program handle of the child that faults. That child stopped at its fault; the parent keeps its handle until after the measure, so its slot keeps its program and its serial, and it makes no operation.
3. One rule for every program that matches nothing: an `Operation` rule for `Machine_Stop`.
4. One rule that accepts each operation of the loop: `Operation`, `Match_Detail` `Memory_Size`, the program handle of the load child.

The table lives from before the round to after it, and the child makes no other operation `Memory_Size` in that time; the four rounds have the same time, and the thread of the parent that empties the rings each millisecond runs in each of them; its kernel entries are waits with no command. So the events that rule 4 accepts are exactly the count of the loop: the case checks that the records written plus the records lost, summed over the heads of all the rings after the table ended, equal that count, and that they are 0 with rules 2 and 3. The line of the log gives each number, in the order of the rounds: "kernel_events: kernel entries in one second of the load child (its own count and time): no rule R (C operations in T ns); a rule that names another program R (C operations in T ns; W records + L lost, of 0); a rule for every program that matches nothing R (...; W records + L lost, of 0); a rule that accepts each of its operations R (C operations in T ns; W records + L lost = S, of C)". A measure whose numbers do not agree fails the case. The window shows the four rates.

| Round | Kernel entries in one second (run 1) | Run 2 | What the event point of an operation does on this path |
|---|---|---|---|
| No rule | ___ | ___ | one load of the observed kinds and one branch |
| A rule that names another program | ___ | ___ | the same load and branch, then one load of the set of the program slots of the kind, a shift, an or, a test and a branch: no read of the cycle counter, no call |
| A rule for every program that matches nothing | ___ | ___ | the two loads and branches, two reads of the cycle counter, a call of `event_record`, a third load of the observed kinds, and the test of one rule |
| A rule that accepts each operation | ___ | ___ | all of the row above, then one record of 64 bytes and the store of the count `written` of the ring |

A run of two rounds, at a host load near 8, one run: no rule 8 194 476 entries in one second (the kernel without event points: 8 267 093 to 8 351 786 in the same hour: an event point with no rule costs nothing that this measure sees); one rule that matches nothing 7 992 904, about 3.1 ns more for each entry (1 / 7 992 904 - 1 / 8 194 476 s). Those 3 ns are the work before any rule is tested: the cycle counter read at the start and at the end of the operation, the call of `event_record`, the second load of the observed kinds; the test of one rule is a few compares. A run of three rounds without the set of the program slots (one run, with another check on the host): no rule 8 580 014; a rule for every program that matches nothing 7 920 332; a rule that accepts each operation 7 633 594. It did not show the set of the program slots: its rule that matches nothing is for every program, so the load child took the path that reads the cycle counter. The table above takes the four rounds, two runs; its numbers are not recorded yet.

A rule for another program is nearly free for this one (the set of program slots of section 7). The paths of the event point of an operation, without and with the set:

| Path | Before the set | With the set |
|---|---|---|
| No rule of the kind | load the word, test, branch | the same: load the word, test, branch |
| A rule of the kind for another program | load, test, branch; `rdtsc`; the operation; `rdtsc`; call `event_record`; load the word again; the loop over the rules (compare the kind, the detail, the least duration, the program); return | load, test, branch; load the set of the kind; shift, or, test, branch; the operation |
| A rule that can accept the event | as above, then the record | load, test, branch; load the set; test, branch; `rdtsc`; the operation; `rdtsc`; call `event_record`, as without the set |

To test the program of a rule before its kind in the loop would save nothing: the 3 ns come before the loop. A mask of kinds in the record of each program is the other form: it adds a load to the path with no rule, and a second set of words to keep under section 8; the set in the table adds a load only after the first branch. The second row of the table above measures it.

"One in N" stays a count with an atomic addition and a division (one division for each event that passed the other tests of a rule with N above 1, some tens of cycles). A countdown is not exact in a few lines: a subtraction and a reset at 0 lose a count when more than N - 1 events come on other processors between the two (a virtual processor that the host stops there), and the sampling then stops for ever; a compare-and-exchange loop is exact, but its retries have no bound under contention, and an event point must have one.

### 12. Not built

- The counters of the processor (section 10).
- A rule on a range of operation numbers, or on a thread: a rule names one detail and one program.
- A table for each observer: the machine has one table.
- An event of the interrupts of devices, of the tick, of a wake: four kinds only.
- A wake of the reader: the program reads its rings by itself; no word of a ring is woken (a wake at each record would make each event point a call of the scheduler path). A reader waits with a deadline.

## How the systems depend on each other

```mermaid
flowchart LR
  boot["U1 Boot program"] --> kernel["Kernel K1 to K5"]
  kernel --> root["U2 Root service"]
  root --> loader["U3 Module store and loader"]
  root --> devs["U4 Device services"]
  devs --> storage["U5 Storage"]
  storage --> loader
  storage --> docs["U6 Documents"]
  devs --> netsvc["U7 Network steering"]
  devs --> comp["U8 Compositor"]
  loader --> shell["U10 Desktop shell"]
  comp --> shell
  docs --> shell
```

An arrow means "must exist before". This is also the order of construction.

## Three flows

### Boot

```mermaid
sequenceDiagram
  participant FW as UEFI firmware
  participant BP as Boot program
  participant TPM
  participant K as Kernel
  participant R as Root service
  FW->>BP: start (Secure Boot verifies the boot program: not built)
  BP->>BP: verify the description signature, then the hash of the kernel and of each file of the boot image
  BP->>TPM: extend PCR 11 with the SHA-256 hash of the system description (through the firmware), read it back
  BP->>BP: load the kernel module
  BP->>K: boot structure (memory map, framebuffer, devices, boot image, trust record)
  K->>K: build tables, start processors
  K->>R: start, with all boot handles and the boot image read-only
  R->>R: check the boot image against the system description
  R->>R: start device services, storage, loader, compositor, shell
```

### A program opens a document

```mermaid
sequenceDiagram
  participant P as Program
  participant D as Document service
  participant U as Person
  participant S as Storage service
  P->>D: ring: "I want a document of type X"
  D->>U: show the picker
  U->>D: choose one document
  D->>S: ring: "make a handle for this object, read only"
  S->>D: handle
  D->>P: completion, with the handle
  P->>S: ring: read commands on the handle
  S->>P: data in shared memory
```

The program never sees a path or a list of other documents.
The kernel takes part only to move the handle and to wake the programs.

### A program sends data on the network

```mermaid
sequenceDiagram
  participant P as Program (TCP library inside)
  participant N as Network steering service
  participant K as Kernel
  participant C as Network card queue
  P->>N: ring: "I want to connect to host H, port 443"
  N->>N: check the grant, choose a local port
  N->>K: map a card queue into P, filtered to that port
  K->>P: queue mapped
  P->>C: packets, written directly to the queue
  C->>P: packets, read directly from the queue
```

After the mapping, the kernel and the service are not in the path.

## Direction

Status: Decided.

- **First use**: a dedicated machine. The system is not a general replacement for an existing desktop at first.
- **Compatibility**: none at first. The project defines a small, fundamental interface that shows its concepts. Later layers are built above it. A POSIX layer and a Win32/NT layer are possible later, as layers above the interface and not as parts of it.
- **Console**: a normal program. It has a terminal: it writes text records and reads key records. A terminal is a normal program too. The system has no terminal concept in the kernel and no equivalent of the Linux TTY.
- **Composition of programs**: the console uses a real programming language. A person calls the exported functions of modules directly, with typed data. The system has no pipes of text and no shell script language.
- **Concepts to research first**: the contract between modules; identity and several machines.
- **Other concepts** (program distribution, failures and quotas, observability, guaranteed latency): the answers come from the design as it grows. They are not researched ahead of need.
- **Persistence**: no save action. Each change goes to storage when it occurs, and storage keeps earlier versions for all programs. See property 9.

## Open questions about the architecture

1. **Kernel ring or direct operations.** Closed: kernel ring only. Every kernel operation is a record in the kernel ring, plus one "enter and wait" entry point.
2. **Loader location.** U3 puts the loader in user space. The first programs then need the boot program to load them. The alternative is a minimal loader in the kernel.
3. **Queue filtering for the network.** A program must receive only its own packets. This needs a card with several queues and filters, or a software switch in the network card service. virtio-net under QEMU needs the second form.
4. **Compositor and the WebGPU library.** Which side owns the display device: the compositor alone, or each program through the library.
5. **Root service size.** It holds all power at boot. It must stay small enough to read completely.
6. **Threads.** Closed. The choice is the one that Blow would make, with no complication of the execution model: a program can have several threads in one address space. A thread is a plain kernel object: a stack and a register state. The system has no `fork`, no signals, no asynchronous runtime, and no thread state hidden in a language runtime. Blow reasons in threads and asks for a thread with limited write permission. [Blow, STAG-2026 00:00] This choice is an inference from his statements, not a quotation. Implemented (`kernel/program.odin`, `system.thread_start`): the kernel operations `Thread_Create`, `Thread_Stop` and `Thread_State`. Each thread has its own kernel ring, so a completion never goes to another thread. The stack is memory of the program: the kernel does not know it. A fault in one thread stops the program, because the threads share all their memory.

## Order of construction

Each step adds one system to a system that already works.

1. U1 boot program, and a kernel that prints.
2. K2 memory, K1 handles, K3 scheduler: two programs run, isolated.
3. K4 rings: the two programs exchange a record.
4. U2 root service: programs get handles from it and not from the kernel.
5. K5 and one device service: the console, then block.
6. U3 module store and loader, then U5 storage.
7. U8 software graphics and compositor, then input.
8. U6 documents, U10 shell.
9. U7 network.
10. Secure Boot and TPM measurement, on the boot program of item 1.
