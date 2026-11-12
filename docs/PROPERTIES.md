# Kernel properties

This document gives the properties on which the kernel is built.

## How to read this document

Each property has a status:

- **Decided**: it is a rule of the system.
- **Proposed**: it comes from the research or from design reasoning. It is a direction, not a rule of the system.

Each property gives the same fields:

- **Rule**: what the system does.
- **Forbids**: what the system must never contain.
- **Cost**: what the rule makes harder.
- **Reuse**: existing work that fits.
- **Open**: what is not decided.

Sources are marked as follows:

- `[Blow …]`: a statement of Jonathan Blow, with its reference in
  `research/blow_verified_statements.md`.
- `[Notes …]`: a file in `research/`.
- No mark: design reasoning written for this document.

## Objective

Build a kernel, then a desktop environment and user programs, that keep the functions of a current system with a small fraction of its code.

The measure of success is the amount of code and of mechanisms that the system does not need.
Adoption is not the objective. [Blow §1]

Three rules apply to every decision:

1. **One mechanism for one concept.** If two mechanisms do the same work, delete one.
2. **Reuse proven software where it fits.** Do not write again what is small, correct and permissively licensed.
3. **No compatibility goal.** The system does not implement POSIX, Win32, or the Linux system call interface.

## Assumptions

- **64 bits only.** An address is 64 bits on every machine of the system. The system has no 32-bit target and runs no 32-bit program. The targets are x86-64 first, and ARM64 at best.
- **Result**: an address, a count, a handle and a register value have one size: 8 bytes. A record has one layout on all machines. The call form passes each scalar in one register. No contract has a second form for a smaller machine.
- **Forbids**: a type whose size depends on the machine, a 32-bit variant of a record, a compatibility mode for 32-bit code.

## Summary

| # | Property | Status |
|---|---|---|
| 1 | Small kernel with a small, counted interface | Decided |
| 2 | Sandbox by default: a program reaches only what it was given | Decided |
| 3 | No "everything is a file": each resource type has its own interface | Decided |
| 4 | Base interface is a non-blocking command buffer in shared memory | Decided |
| 5 | Kernel off the data path | Decided |
| 6 | One communication mechanism between programs: shared memory | Decided |
| 7 | No drivers in the kernel, and fixed hardware first | Decided |
| 8 | No global, mutable, shared file system | Decided |
| 9 | A storage engine with one private store per program | Decided: new engine under MIT |
| 10 | One code module: position-independent, static and dynamic are the same | Decided |
| 11 | Reproducible system: modules identified by content hash | Decided |
| 12 | Module metadata in flat tables, read through functions | Decided |
| 13 | Data-oriented kernel internals | Decided |
| 14 | Memory is supplied by the caller | Decided |
| 15 | Isolation inside a program for untrusted code | Decided |
| 16 | Removed concepts | Decided |
| 17 | Trusted boot: UEFI program, Secure Boot, TPM | Decided (detail proposed) |
| 18 | One graphics interface: WebGPU with WGSL | Decided (detail proposed) |
| 19 | A command is a function: no text between programs | Decided (detail proposed) |
| 20 | No ambient access: the other holes to close | Decided |
| 21 | Principals: who acts, without users | Decided (layers 1 and 2); direction for the rest |

## 1. Small kernel with a small, counted interface

Status: Decided.

- **Rule**: The kernel does four things: it isolates address spaces, it schedules processors, it owns the table of handles, and it grants access to memory and devices. All other work runs in user space. [Blow §2]
- **Rule**: The kernel interface has a budget. The proposal is a hard limit on the number of kernel operations, written in this document, and changed only by a change of this document.
- **Forbids**: file systems, network protocols, device drivers, window management and text formats in the kernel.
- **Cost**: Each service that leaves the kernel needs a user-space home and a fast path to reach it. Properties 4, 5 and 6 pay this cost.
- **Reuse**: seL4 and Zircon show that a kernel of this scope ships. NT shows that one handle table for every kernel resource scales to a full system. [Notes `existing_kernels_good_ideas.md` §1, §3]
- **Open**: the limit itself. A first target is 32 operations or fewer.

## 2. Sandbox by default

Status: Decided.

- **Rule**: A new program starts with no access. It holds only the handles that its parent or the user gave to it. [Blow §7]
- **Rule**: A handle is an index and a generation into a table that belongs to the process. Each entry holds an object index and a set of rights. A program can reduce rights and pass a handle. It cannot create rights.
- **Rule**: The sandbox is the base model. No operation exists that works without a handle.
- **Forbids**: global names that any program can open, user identifiers as the access model, access control lists on a shared namespace, a "root" user.
- **Cost**: The desktop must give access through user actions. A file picker that runs outside the program and returns a handle is the standard solution. Programs that need broad access, such as a backup tool or a file manager, need an explicit grant model.
- **Reuse**: Zircon handles with rights. Capsicum. The "powerbox" file picker pattern. [Notes `existing_kernels_good_ideas.md` §3, §4]
- **Revocation**: the kernel keeps the origin of each handle and each mapping. `Handle_Revoke` ends what came from a handle, through each chain of gifts.
- **Open**: how the person sees and revokes grants on the desktop. The console has `grants` and `revoke`. No window shows the grants. Blow gives no design for the desktop part. [Blow §7]

## 3. No "everything is a file"

Status: Decided.

- **Rule**: A stored object, a network connection, a device queue, a timer and a memory region are different types. Each type has its own small set of operations. [Blow §4]
- **Rule**: The handle table is uniform. The operations are not. A handle has a type, and the kernel rejects an operation that does not belong to the type.
- **Forbids**: a universal `read`/`write`/`ioctl` interface, a `/dev` tree, a `/proc` tree, pipes as the composition mechanism, sockets as the network interface, text as the format of system state.
- **Cost**: Generic tools that work on "any stream" do not exist. Composition between programs uses typed data in shared memory (property 6) and callable modules (property 10).
- **Reuse**: NT object types. Zircon object types.
- **Note**: This rule does not conflict with one handle table. NT keeps uniform naming and lifetime with typed operations. Unix makes the operations uniform, and that is the part that is rejected.

## 4. Base interface: non-blocking command buffers

Status: Decided. It is the interface that Blow describes. [Blow §3]

- **Rule**: A program asks for work by writing command records into a submission ring in memory that it shares with the receiver. It reads results from a completion ring. The receiver is the kernel or another program.
- **Rule**: No operation blocks at this level. One kernel operation exists to wait: "sleep until one of these rings has entries".
- **Rule**: A blocking call is a library function above the rings.
- **Rule**: Data is not copied through the kernel. A command refers to memory that both sides map.
- **Forbids**: one kernel entry per operation as the normal path, blocking kernel operations, hidden copies.
- **Cost**: Asynchronous code is harder to write than blocking code. The base library must make the blocking form one call. Ring formats become a stable binary contract, and they need a version rule.
- **Reuse**: The io_uring ring layout is proven and documented. Virtio queues and NVMe queue pairs use the same pattern. FlexSC measured the gain of batched kernel entry. [Notes `data_oriented_kernel.md` §3]
- **Why it matters**: The dominant cost of a kernel entry is cache pollution and not the mode switch. Batches reduce the number of entries. [Notes `data_oriented_kernel.md` §2]
- **Open**: one ring format for kernel, devices and programs, or one format per use. The proposal is one format.

## 5. Kernel off the data path

Status: Decided.

- **Rule**: The kernel is the control plane. It checks the right one time and maps the device queue or the shared ring into the program. After that, data moves without a kernel entry. [Blow §5]
- **Rule**: The network stack is a library in the program that uses the network. [Blow §5]
- **Note, UDP**: the first layer of the network does not have this form. The network device of the first machine has one pair of queues. So the network service is the user-space multiplexer of the cost line below. It reads each frame, checks it against the grant of an endpoint, writes the headers of UDP and IPv4 and copies each datagram one time. The kernel carries no data. TCP and QUIC stay libraries in the program.
- **Note, TCP**: the same holds for TCP, for the same reason (one pair of queues). The protocol of TCP is a library in the program (`support/tcp`): its connections, windows, timers and retransmissions. The network service is still on the data path. It reads each frame, checks the TCP checksum and the ports against the grant of an endpoint, writes the IPv4 header and copies each segment one time. It keeps only the ports and, for a listen grant, the remotes that came to it (`docs/NETWORK.md`, "The note of property 5").
- **Forbids**: a kernel network stack, a kernel block layer, a kernel entry per packet or per block.
- **Cost**: Two programs that use one device need the device to give separate queues, or they need a user-space multiplexer. Direct device access is safe only with an IOMMU, or with a device that the hypervisor isolates. A program can no longer rely on the kernel to keep a connection alive when the program stops.
- **Reuse**: Arrakis and IX prove the model. DPDK and SPDK are production examples of user-space network and NVMe access. A small permissive TCP library such as lwIP or smoltcp can be the first stack. [Notes `existing_kernels_good_ideas.md` §3] [Notes `bcachefs_storage.md` §5]
- **Open**: the multiplexer for devices with one queue. The rule for a shared network identity, because several programs share one address and one port space.

## 6. One communication mechanism between programs

Status: Decided.

- **Rule**: Two programs communicate through memory that both map. The kernel creates the mapping and transfers handles. It does not carry the data. [Blow §8]
- **Rule**: The mapping uses the ring format of property 4. A call to a service and a call to the kernel look the same.
- **Rule**: Data in the mapping is binary structures with a fixed layout. It is not serialized text.
- **Forbids**: pipes, signals, message queues, sockets between local programs, a second mechanism "for small messages".
- **Cost**: A receiver must treat shared memory as hostile: the sender can change it during the read. The rule is "copy, then validate". Layouts must be versioned. A program that waits on a dead peer needs a kernel notification.
- **Reuse**: L4 and seL4 show how few cache lines a fast path needs. [Notes `data_oriented_kernel.md` §3]
- **Wake-up**: the wake-up primitive is the word wait (`Word_Wait`, `Word_Wake`). Each ring waits on it: the system has one wait.
- **Open**: How a handle moves through a ring.

## 7. No drivers in the kernel, and fixed hardware first

Status: Decided. The rules follow Blow. [Blow §5, §6]

- **Rule**: The kernel contains no device driver. The code that knows a device is a library or a user-space program.
- **Rule**: The system targets one fixed machine at a time. The first machine is virtual: QEMU on x86-64 with virtio devices, UEFI firmware (OVMF) and a TPM 2.0 (property 17).
- **Position**: Hardware support is not the main problem of the project. The design of the system is.
- **Rule**: Each device class has one standard queue protocol. Virtio is that protocol for the first machine. Real hardware that differs gets a user-space translator, with no kernel access.
- **Why virtio**: It is a published standard for network, block, console, input and display. Each device is a set of queues in shared memory. This is the "standard packet format over DMA" that Blow asks for, and it exists today. [Blow §5]
- **Forbids**: loadable kernel modules, vendor code in the kernel, support for hardware that nobody on the project owns.
- **Cost**: The system runs on few real machines for a long time. This is accepted. [Blow §6]
- **Graphics**: See property 18.
- **Reuse**: Virtio specification. UEFI firmware for boot (property 17).
- **Open**: the second machine. A single-board computer with documented hardware is the usual choice. The processor architecture after x86-64.

## 8. No global, mutable, shared file system

Status: Decided.

- **Why**: This is a security requirement, not a preference. A shared tree that every program can read and write is a source of many security defects. A security model that fits the present time cannot keep it.
- **Rule**: No tree of names exists that all programs see and can change. A program sees its own store and the objects that it received by handle. [Blow §7]
- **Rule**: System code and system data are immutable and identified by content hash (property 11).
- **Forbids**: `PATH`, a registry, installers, shared configuration directories that programs write, hidden files in a home directory. [Blow §9]
- **Cost**: Sharing a document between two programs is an explicit act. The user needs one place to see "my documents" that is not owned by one program. The proposal is a document store service that the desktop owns and that grants objects by handle.
- **Open**: the user-visible model of documents. Blow allows read access to common configuration and to a user folder; the proposal here is stricter. [Blow §7]

## 9. A storage engine with one private store per program

Status: Decided. The engine is new, under MIT, and reuses ideas of bcachefs. It is not a fork of bcachefs.

The engine is the storage service in Odin, about 800 lines. It writes by copy on write, keeps two places for the root block, and checks each block in the pointer that names it. The system holds no SQLite. One rule below is not done: objects have names in a store, not identifiers. Each commit keeps the state before it as a version, with a retention rule and thinning at the limit of the store. Clones share their blocks. A snapshot is the versions of a store at one generation.

- **Rule**: Storage is a transactional object store in user space. Objects have identifiers, not paths. A directory is an optional index, not the base structure.
- **Rule**: Each program gets a private store. A copy-on-write clone is the way to give a copy of an object. A snapshot gives versions of a store.
- **Rule**: The storage service reaches the disk through the queues of property 5.
- **Recommendation**: Do not fork bcachefs. It is GPL-2.0, more than 100,000 lines of Linux-specific code, and it has one maintainer. Write a small engine that takes its best ideas: the cache-line-aware search inside a B-tree node, and buckets with generation numbers. [Notes `bcachefs_storage.md` §3, §7]
- **Recommendation**: Take the structure from Fuchsia Fxfs: user-space, object identifiers, directories optional. [Notes `bcachefs_storage.md` §5]
- **Cost**: A new storage engine is the largest reliability risk in the project. The answer is its tests of a stop in the machine test, not a borrowed engine.
- **Licence**: the engine is under MIT and reimplements the ideas. The other option, upstream bcachefs as a separate GPL user-space service, is not taken.

### Persistence: no save action, and versions for all programs

Status: Decided.

- **Rule**: A program sends each change of a document to the storage service when the change occurs. The document in storage is always current. The system has no "save" action.
- **Rule**: The storage service keeps the earlier versions of each object. A program or the person can read an object as it was at an earlier time.
- **Guarantee**: A document is never lost and never half written. A power loss or a program failure loses at most the change that was in progress.
- **Interface that this requires from storage**: "apply this change atomically" and "give me this object at time T". Not "replace the whole object".
- **Why it is cheap**: A copy-on-write store writes new blocks and keeps the old ones. The earlier versions exist already. The system exposes them and does not discard them.
- **Result**: Protection against lost work and a history are supplied one time, by the system, to all programs. A program writes no code for them.
- **Cost**: Disk space. A retention rule deletes old versions, for example: keep all versions for one day, then one per hour, then one per day.
- **Open**: who sets the retention rule (the service applies one fixed rule: each version for 10 minutes, then one an hour for a day, then one a day). How a program groups small changes into one step that the person can undo. A later option above this model is a program whose full state returns after a restart.

## 10. One code module

Status: Decided.

- **Rule**: All code is position-independent. One module format exists. [Blow §9]
- **Rule**: "Static" and "dynamic" are link-time choices on the same module. A module that was bundled keeps its identity inside the bundle, so a tool can find and replace it. [Blow §9]
- **Rule**: A program and a library are the same thing. A module exports functions. A module that exports an entry function can be started. The `grep` program is the `grep` module with an entry function. [Blow §9]
- **Forbids**: separate archive and shared-object formats, a global library directory, symbol lookup by search order, a C library that the system imposes.
- **Cost**: Inlining across modules removes the ability to replace a module. Patching calls at load time makes pages private to a process.
- **Reuse**: The object formats of today already contain position-independent code. The project can use an existing compiler back end and define only the container and the loader.
- **Open**:
  1. Where inlining across modules is allowed. Proposal: only inside a bundle, and the bundle records it.
  2. If the loader patches calls between modules. Proposal: no; calls go through a table per module, so code pages stay shared and identical to the file.
  3. The calling convention between modules. It is a permanent contract. [Blow, `6zQzNpjgbAY` 15:15]

## 11. Reproducible system

Status: Decided. The detail below is proposed.

- **Rule**: The identity of a module is the hash of its content. A module refers to another module by hash, never by path or by name.
- **Rule**: A system is a list of hashes. Two machines with the same list run the same code.
- **Rule**: An upgrade writes a new list. A rollback selects an old list. Both are atomic.
- **Why property 10 makes this cheaper**: Nix reaches the same goal on Linux, and it must fix the store at one absolute path, because binaries contain absolute paths. Modules that are relocatable and that refer by hash contain no path. The store can be at any location, and a module needs no patch after a copy.
- **Consequence**: "Install" becomes "the store contains the hash". This matches "no installs". [Blow §9] Identical modules are stored one time and their pages are shared, with no global library directory.
- **Consequence**: A security fix is a query: "which bundles contain the hash of the bad module". [Blow §9]
- **Cost**: A build must be deterministic for the hash to mean something. The compiler and the linker must not write times, host names or random identifiers. Old modules need garbage collection.
- **Reuse**: The Nix store model and its closure concept. Content-addressed derivations in Nix.
- **Open**: the hash function. BLAKE3 is the proposal. How names for people map to hashes; the proposal is a signed table in the system description.
- **State**: the build is deterministic for the compiler of the flake: the release `dev-2026-11a` of Odin, with no patch, on all its threads (`docs/REPRODUCIBLE_BUILD.md`). Measured on 2026-11-11: with the release `dev-2026-05` and a patch that gives it one thread, 100 builds of each of the 61 modules and of the boot program, under a host load of 9.5 to 62, gave one module, one LLVM IR file and one object each; with `dev-2026-11a` and no patch, 20 builds of each of 64 modules gave the same. The stock `dev-2026-05` with `-thread-count:1` runs two threads, and a rare build with it gives other code. Each full check builds everything two times and compares the three.

## 12. Module metadata in flat tables, read through functions

Status: Decided. The system holds no SQLite: no base library and no index over the tables of the modules.

- **Rule**: The metadata of a module is a set of flat tables inside the module: arrays of fixed-size records at known offsets, valid when zero. They hold the symbols, the interfaces, the dependencies, the origin of each bundled module and the debug information. The flat tables are the source of truth, and the only format.
- **Rule**: The loader reads the flat tables directly.
- **Rule**: A rich and descriptive set of functions gives the information of the modules: clear functions with documentation, that a program and the console call. A question across many modules is a function that reads the tables in a line. The results are tables of records, so that the functions combine. A table also goes into a function as a parameter (property 19, "State"). No query language exists in the system.
- **Why**: A language and an engine to maintain cost far more than good functions. The tables of a machine are small, and a linear read of flat tables is the data-oriented way (P13). One format has no copy to keep equal to its source.
- **Cost**: A new kind of question needs a new function, or a combination of functions in the console.
- **Not forbidden**: a program can bring SQLite as its own module. The system does not need it and does not serve it.

## 13. Data-oriented kernel internals

Status: Decided.

- **Rule**: Kernel state is flat tables. A reference is an index with a generation, not a pointer.
- **Rule**: Each table is split by access: fields that the fast path reads are together, cold fields are in a second table.
- **Rule**: State that a processor changes often is per processor. No cache line is written by two processors on a fast path.
- **Rule**: Each fast path has a budget in cache lines, written in the code and checked by a test.
- **Rule**: The kernel processes batches. A function takes an array of work, not one item.
- **Rule**: The cache line size is a build parameter. It is 64 bytes on x86-64 and can be 128 bytes on other machines. [Notes `data_oriented_kernel.md` §2]
- **Forbids**: linked lists and pointer trees on fast paths, a reference count per object that every reader writes, tables of function pointers on fast paths.
- **Cost**: Fixed tables need sizes. A table that grows needs a reserve of address space (property 14).
- **Reuse**: The research found no kernel that applies these rules to its whole object model. Linux, seL4 and others apply them to single paths. This part is new work. [Notes `data_oriented_kernel.md` §3, §5]

### Zero is initialization (ZII)

Status: Decided as a principle. The detail below is proposed. The name comes from Casey Muratori.

- **Rule**: A record that is all zero bytes is a valid record with a defined meaning. No record needs a constructor.
- **Rule**: This applies to every contract of the system: the context of property 19, ring records, module metadata, kernel tables.
- **Consequences**:
  1. Memory from the kernel is zero pages, so new memory is already initialized (property 14).
  2. Handle 0 is the "no object" handle. An operation on it fails in a defined way and does no damage. Index 0 of each table is a reserved empty entry, so a zero index never points to a live object.
  3. A zero field in a command record means "default". A caller fills only the fields that it needs.
  4. A new field at the end of a record is zero for old callers. This gives a rule for the growth of contracts with no version number per record.
  5. Lookups return the empty entry and not an error path. Code has fewer branches.
- **Fits**: the rule that no contract depends on a language feature (property 19). Zero bytes mean the same thing in every language.
- **Cost**: Each enumeration must reserve 0 for "none" or "default". A real value that is 0 (an offset, a count) cannot also mean "absent"; such fields need a separate flag.

## 14. Memory is supplied by the caller

Status: Decided.

- **Rule**: A kernel operation writes its result into memory that the caller gives. The kernel does not allocate hidden state per call.
- **Rule**: "Reserve address space" and "commit pages" are two cheap operations. Programs build arenas on them.
- **Rule**: The memory that a kernel object uses is charged to the program that created it.
- **Forbids**: a kernel heap that a program can fill, a global user-space heap that the system imposes. [Blow §12]
- **Reuse**: The arena conventions of Odin, Zig and Jai. The seL4 model, where user space supplies the memory of kernel objects. [Notes `handmade_sphere_os.md` §4]
- **Open**: the accounting model.

## 15. Isolation inside a program

Status: Decided. Blow names it as an unsolved problem. [Blow §11]

- **Problem**: A program wants to run a plugin that it does not trust, share data structures with it, and survive its crash. Today this needs a second process and serialization.
- **Proposal**: A process can contain several protection domains. A domain is a set of page rights inside one address space. A switch between domains costs less than a process switch. A domain can be destroyed alone.
- **Cost**: The hardware support differs by processor. The x86-64 memory protection keys give 16 domains and do not stop all attacks by themselves. Shared lock-free state stays the problem that Blow describes.
- **Alternative**: A standard sandboxed bytecode for untrusted code, in the role of WebAssembly. [Blow §11]
- **Recommendation**: Do not design this now. Keep the handle table and the module format free of assumptions that prevent it. Decide after the first desktop program exists.

## 16. Removed concepts

Status: Decided.

| Concept | Replacement |
|---|---|
| Everything is a file (Decided) | Typed handles (property 3) |
| Global file system (Decided) | Private stores and grants (properties 8, 9) |
| `fork` | Create an empty process, then give it modules and handles |
| Signals | Completion records in a ring |
| Pipes and terminals | Shared memory with typed data; a terminal is a normal program |
| Sockets | A network library with connect, send, receive, disconnect [Blow §4] |
| `ioctl` | Typed commands per resource type |
| Users, groups, root | Handles and grants |
| Installers, package scripts | The store contains the hash (property 11) |
| `PATH`, registry, environment as configuration | The system description and per-program stores |
| Shell scripts as system glue | Programs that call modules [Blow §9] |
| Kernel modules | User-space device code (property 7) |
| Hundreds of background processes | Services start when a program asks for them [Blow §2] |

## 17. Trusted boot: UEFI program, Secure Boot, TPM

Status: Decided. The detail below is proposed.

- **Rule**: The boot stage is a UEFI program. It uses the firmware services before it gives control to the kernel: it reads the modules from the boot volume, gets the memory map, gets the framebuffer, gets random numbers, and talks to the TPM. The project writes no boot loader and no boot-time disk or display code.
- **Rule**: Secure Boot verifies the boot program. The key of the person who owns the machine signs it. The firmware refuses a boot program that is not signed.
- **Rule**: The boot is measured. The boot program extends a TPM register with the hash of the system description of property 11, before the kernel starts.
- **Why property 11 makes this cheap**: A system is one list of hashes. One measurement of that list covers every module of the system. Current systems must measure a kernel, an initial disk image, a command line and many files separately.
- **Uses of the TPM**:
  1. Seal the storage encryption key to the measured state. A changed system cannot read the disk.
  2. Hold the key that signs the name table of property 11, or the key that verifies it.
  3. Prove to a remote party which system list runs (attestation).
  4. Give a hardware source of random numbers at boot.
- **Rule**: After boot, the TPM is a device like the others. A user-space service owns its queue. Programs reach it by handle (properties 2 and 7).
- **Forbids**: an unsigned code path from firmware to kernel, a boot loader with a configuration language, kernel arguments as free text.
- **Cost**: A key that is sealed to exact measurements becomes unreadable after each upgrade. The standard solution is to seal to a signed policy in place of exact values: the TPM releases the key to any system list that the key of the person who owns the machine signed. A rollback to an old signed list with a known defect must be prevented by a counter in the TPM.
- **Cost**: The system needs a key management story for the person who owns the machine: creation, enrolment in the firmware, backup, loss.
- **Reuse**: UEFI firmware services. OVMF and a software TPM under QEMU give Secure Boot and a TPM 2.0 on the first machine. The TCG TPM 2.0 specification. A small permissive TPM command library, to be selected.
- **Open**: the exact meaning of "rich boot". This text reads it as "do as much boot work as possible with UEFI services in a UEFI program". How much the boot program does before it leaves firmware services. Which registers hold which measurements.

## 18. One graphics interface: WebGPU with WGSL

Status: Decided. The detail below is proposed.

- **Rule**: Programs draw through one interface: WebGPU. They write shaders in one language: WGSL. The system exposes no other graphics interface.
- **Why it fits**:
  1. WebGPU is a published standard with more than one implementation. It removes the "which graphics interface" problem that Blow describes for Linux. [Blow §9]
  2. WebGPU was designed for untrusted code. Every call is validated, and a program cannot reach undefined behaviour of the device. This matches the sandbox of property 2.
  3. WebGPU is a command buffer interface: a program records commands and submits them to a queue. This is the shape of property 4.
  4. WGSL is a text format with a full specification, so the shader that a program ships means the same thing on every machine.
- **Rule**: The compositor of the desktop uses the same interface as programs.
- **Layers** (grow in this order):
  1. A software implementation that draws into the UEFI framebuffer. It makes the interface work on the first machine with no device code. Blow starts in the same place. [Blow §10]
  2. A virtio-gpu back end under QEMU.
  3. A back end for one real graphics device.
- **Forbids**: OpenGL, vendor shader languages as a program-facing format, a window system protocol that carries drawing commands. [Blow §10]
- **Cost**: A WebGPU implementation is large. The existing ones, wgpu and Dawn, sit on Vulkan, Metal or Direct3D, which this system does not have. The project must write a back end for each device, or bring up a Vulkan driver in user space. This is the largest piece of device work in the plan.
- **Cost**: WebGPU lacks some features of the native interfaces. This is accepted: one mechanism for one concept.
- **Tension with property 7**: Blow wants a very thin graphics driver. A WebGPU back end for a real device is not thin. The software back end and virtio-gpu delay this problem; they do not remove it.
- **Reuse**: the WebGPU and WGSL specifications. An existing WGSL compiler front end (Naga, Tint) if its language fits the project. The WebGPU conformance test suite, to test the implementation.
- **Rule**: The project writes the WebGPU implementation from nothing. It does not port wgpu or Dawn. Graphical code is a program of this system and uses no existing toolkit.
- **Order**: No GPU at first. First: the boot program passes the UEFI framebuffer; a surface is a shared memory region of pixels with a "present" command that names the changed rectangles; the compositor copies surfaces to the framebuffer; programs draw on the CPU. Second: the first WebGPU subset with a software back end that renders into the same surfaces. Third: virtio-gpu. Fourth: one real GPU. A surface is the way to share pixels, not a second drawing interface. See `research/webgpu_from_nothing_study.md`.
- **Open**: The role of the kernel: the proposal is none beyond the mapping of device queues (property 5). How the compositor shares surfaces with programs; shared memory of property 6 is the proposal.

## 19. A command is a function: no text between programs

Status: Decided. The detail below is proposed.

- **Rule**: Programs do not exchange text that the receiver must parse. The system has no command line arguments as strings, no text pipes, no standard input and output streams, and no environment variables.
- **Rule**: A command line program and a library are the same thing. Both are a module that exports functions (property 10). A command is one exported function.
- **Rule**: The metadata of a module (property 12) describes each exported function completely: its name, the name and type of each parameter, the type of each result, and a text for the person. This description is sufficient to call the function with no other knowledge of the module.
- **Rule**: A started program receives no `argc` and no `argv`. At the minimum, it receives one structured context: a typed record with a fixed layout.
- **Content of the context** (proposed): the typed arguments of the called function, the handles that the caller grants (property 2), and the rings to the caller and to the kernel (property 4). The context holds no strings that the program must parse.
- **Rule**: No contract of the system depends on a feature of one programming language. The context, the module format, the calling convention, the type description and the ring layouts are defined as memory layouts and numbers. A program in any language that can read and write memory at fixed offsets can use them.
- **Consequence**: The context is a plain record of the system. It is not the implicit `context` of Odin or Jai. A language binding can copy its fields into a language feature; the system does not know about it.
- **Consequences**:
  1. The console reads the metadata and calls the function directly, with typed values. Completion, help and argument checks come from the metadata, not from code in each program.
  2. A program calls the same function as a library call. The person and the program use one interface.
  3. The output of a function is typed data: records and tables. The console displays it. The next function receives it with no parsing.
  4. Other front ends can be generated from the same metadata: a form in the desktop, a remote call, a test.
- **Why**: Text between programs forces each program to write a parser and a printer, and each pair of programs to agree on a format that no tool checks. Errors appear at run time and in the data. Blow's "a program is a library" gives the mechanism. [Blow §3]
- **Forbids**: `argv`, `stdin`, `stdout`, exit codes as the only result, a shell script language, formats that are defined only by the output of a tool.
- **Depends on**: the contract between modules (property 10). The type description must be independent of the implementation language, so that a module in one language can call a module in another.
- **Isolation**: A call from the console to an untrusted module starts the module as a sandboxed program, and the arguments travel as records in a ring (properties 2 and 4). A call to a trusted module can be a direct call in the same address space. The metadata is the same in both cases.
- **Cost**: The type description becomes a permanent contract of the system. Its design must come before the first modules.
- **Cost**: Streams of data with no known end (logs, audio, large results) need a typed stream form above rings, not one return value.
- **Prior art to study**: PowerShell (objects in pipelines), Nushell (typed tables), Lisp machines and Oberon (commands are exported procedures), COM and WinRT metadata, the WebAssembly component model (language-independent interface types).
- **State**: a table of records and a range of bytes are parameters, each with a direction (Read, Change, Append), in memory of the caller (P14). One description serves a direct call with no copy, a call host and a service. A table too large for the call region goes in a lent memory object whose rights are the direction (P20). The program `tables` shows the same answers in the three ways; `MODULE_CONTRACT.md`, "Tables and bytes as parameters".
- **Open**: the set of base types (no float, no record in a record). How a function declares the handles that it needs (property 2), so that the console can ask the person before the call. Versioning of a function whose description changes.

## 20. No ambient access: the other holes to close

Status: Decided.

Ambient access is access that a program has because it runs, and not because it received a handle.
The shared file system (property 8) is one case. This property lists the other cases. Each one gets the same answer: the resource is reached only by a handle that a person or a parent granted.

| # | Hole in current systems | Rule in this system |
|---|---|---|
| 1 | A program lists and inspects all other programs | A program sees no other program. It sees only the programs that it started |
| 2 | A program debugs or reads the memory of another program of the same user | Debug access is a handle to one program. The person grants it |
| 3 | Any program opens network connections to any host | No network at start. A grant names the hosts or the ports. Name resolution is a part of the grant |
| 4 | Any program listens on the local machine, and local services trust local callers | No shared "localhost". Two programs talk only through a ring that someone gave to both |
| 5 | Any program reads the clipboard | The clipboard belongs to the compositor. A program receives the content only at a paste action of the person |
| 6 | Any program reads the screen or the windows of other programs | A program sees only its own surfaces. Screen capture is a grant, with a visible indicator |
| 7 | Any program reads all keyboard input, or sends false input | Input goes only to the program that has focus. Synthetic input is a grant |
| 8 | A program draws a false system dialog (picker, password prompt) | The compositor marks trusted surfaces in a way that a program cannot copy. One key combination always goes to the system |
| 9 | Camera, microphone, location, USB devices are open to every program | Each one is a device queue behind a grant, with a visible indicator while in use |
| 10 | A child program inherits everything from its parent: open objects, environment, working directory | A child receives only the context of property 19. Nothing is inherited by default |
| 11 | Global names: named pipes, shared memory names, temporary directories, ports | No global name exists. Names are local to a handle |
| 12 | A program with access acts for a program without access (confused deputy) | A service acts only on handles that the caller sends with the request. It does not combine its own access with a name from the caller |
| 13 | Access is for ever once given | Each grant is recorded, visible, and can be revoked. A grant can have an end time |
| 14 | A library or plugin gets all the access of its host program | Isolation inside a program (property 15). An untrusted module runs as its own program |
| 15 | An update or an installer runs code with full access | No installer. A module is data identified by hash. It runs only in the sandbox (properties 8, 11) |
| 16 | A program consumes all memory, processor time or storage | Each resource is a handle with a limit. A program divides its limit among its children |
| 17 | Precise clocks and shared caches leak data between programs (side channels) | Not solved by handles. Reduce: a precise clock is a grant; the scheduler can keep two programs off the same core |
| 18 | One administrator account can do everything | No root. The root service holds all handles at boot and gives them out. The person, present at the machine, is the only source of new grants |

- **Test for every new interface**: "Can a program with zero handles use it?" If yes, the interface is a defect.
- **Cost**: The person receives more requests for access. Too many requests train the person to accept all of them. The design must prefer grants that follow from an action (the person chooses a document, the person pastes) over questions.
- **Cost**: Programs that manage the system (task manager, backup, debugger, screen reader) need broad grants. These grants must be rare, visible and revocable.
- **Open**: line 17. Blow says that isolation of untrusted code inside one program is not solved. [Blow §7] Side channels between programs are a similar limit.

## 21. Principals: who acts, without users

Status: Decided for layers 1 and 2: they are the design. Layers 3 to 5 are a direction, not a design.

- **Rule**: The kernel has no concept of "who executes". The answer is always: a program, with the handles that it holds.
- **Rule**: A principal is a key pair and the root handles that the key unlocks: documents, grant records, settings. A principal exists in the root service and in storage. The kernel does not know it.
- **Rule**: A session is the tree of programs that started from the root handles of one principal. "Who did this" is a fact that the grant records give. It is not a check.
- **Rule**: A human, a scheduled job, a remote caller and an automation agent are the same thing: a program tree that received handles from a principal. No separate concept exists for each.

The "user" of current systems does six jobs. This system splits them:

| Job of the user in current systems | In this system |
|---|---|
| Subject of access checks | Removed. Handles do this (property 2) |
| Owner of data | A root handle to a set of documents |
| Proof that a human is present | Unlock of a key |
| Identity across machines | A public key |
| Accounting and limits | Limits on the handle tree (property 20, line 16) |
| Audit | The grant records |

- **Defects of current systems that this removes**:
  1. Every program that a user starts has all the rights of that user. Here a program does not inherit the principal. The desktop shell holds the root handles and gives narrow ones.
  2. `root`, `sudo` and setuid change identity to gain access. Here no identity exists to change to. More access is always a received handle.
  3. Privileged code compares a password with a database. Here the unlock is cryptographic: the TPM seals the key of the principal behind a PIN or a hardware key (property 17). Without the key, the documents cannot be read.
  4. An administrator role. Here the principal that holds the handle to the system description can change the system. This is one handle. It can be delegated.
  5. Groups, access lists, and identifiers that differ between machines. Here sharing is a grant. A grant to another principal is a signed record that names its public key.
  6. Removal of a user leaves data behind. Here the root handle is dropped and the whole tree goes with it.
- **Layers** (grow in this order; the zero case follows ZII):
  1. No principal. The root service is the only source of grants.
  2. Principal 0 is the machine. Its key is in the TPM. It signs the system description. A dedicated machine stops here: no login, and the TPM unlocks storage at boot.
  3. One human principal. The unlock decrypts its documents. The lock discards the key.
  4. Several principals on one machine: disjoint handle trees, no kernel change.
  5. One principal on several machines, and sharing between principals: the principal key signs each machine key; signed grants carry access between machines.
- **Usability**: A desktop that ordinary people can use needs concessions on security. This is accepted. It must not ruin the security model.
- **Proposed rule for concessions**: A concession is made in the desktop shell, as a default grant that is data: visible, recorded, and revocable. A concession is never made in the kernel, in a contract, or as a new form of ambient access. The base system stays strict; the desktop chooses how much it grants without a question.
- **Forms of concession** (proposed; some doors can stay open so that the system is not painful to use):
  1. A remembered grant: the system asks one time, then renews the grant with no question.
  2. A grant that follows from an action: the person opens, drops or pastes a document. No question is shown.
  3. A default set of grants for a kind of program, given at first start.
  4. A broad grant for a trusted program, such as a document manager or a backup program.
  In each form, the grant is still a record that the principal can see and revoke.
- **Cost**: No administrator can reset a key. A lost key is lost data. Layer 3 needs recovery from its first version: a second device or a printed recovery key.
- **Cost**: A signed grant that left the machine cannot be revoked at once. It needs a short lifetime or a revocation list.
- **Cost**: Work that runs while the principal is locked needs a key that stays available. This must be a narrow and visible grant.
- **Prior art to study**: SPKI/SDSI, object-capability systems (KeyKOS, seL4, Fuchsia), macaroons and UCAN for signed delegation, passkeys for the unlock.

## Tensions between properties

- **Sandbox (2) against direct device access (5)**: Direct access is safe only when the hardware isolates queues. On the first machine the hypervisor does this. On real hardware an IOMMU is a requirement.
- **Per-program network stack (5) against shared network identity**: Several programs share one address. A small user-space service must assign ports and steer packets to queues. It stays off the data path.
- **Replaceable modules (10) against speed**: Calls through a table cost one indirect call. The bundle is the place where a developer trades replaceability for inlining.
- **No global file system (8) against the desktop**: A person thinks in documents, not in programs. The document store service must exist before the first real desktop program.
- **Small interface (1) against typed resources (3)**: Types multiply operations. The ring of property 4 solves this: the kernel has few entry operations, and the typed commands are records in a ring.
- **New storage engine (9) against reliability**: The engine is small and each commit is tested against a stop of the machine. SQLite is not used.

## Reuse list

| Need | Candidate | Licence |
|---|---|---|
| Boot | UEFI firmware services; OVMF under QEMU | Standard, no code imported |
| Trust | Secure Boot, TPM 2.0; software TPM under QEMU | Standard, no code imported |
| First machine | QEMU with virtio devices | Standard, no code imported |
| Graphics interface | WebGPU and WGSL specifications; conformance test suite | Standard |
| WGSL front end | Naga or Tint | MIT or Apache-2.0 / BSD-3-Clause |
| Ring layout | io_uring design | Design only |
| TCP library | lwIP or smoltcp | BSD-3-Clause / 0BSD |
| Hash | BLAKE3 | CC0 or Apache-2.0 |
| Store and system description model | Nix concepts | Design only |
| Storage ideas | bcachefs node search and buckets, Fxfs object model | Design only |
| Software rendering and UI | `gui_toolkit`, a separate library, if its back end can target a framebuffer | Same copyright holder as this system |

Licences in this table come from memory. Verify each one before the code is imported.

## Open decisions

1. **Module contract**: the open questions of `MODULE_CONTRACT.md`.

Fixed choices: implementation language (Odin), storage licence (new engine under MIT), properties 4, 7, 14, 15 and 16 (decided), kernel entry (kernel ring only), threads (several threads per program), call form (registers, `MODULE_CONTRACT.md` section 4), graphics implementation (written from nothing, no port of wgpu or Dawn), kernel operation limit (the kernel tool counts the kinds of kernel operation; no fixed limit yet).

## First milestone

The first milestone is the smallest end-to-end system that shows the model:

1. A UEFI program starts under QEMU with OVMF, loads the kernel and two modules, and starts the kernel. The kernel prints on the serial port.
2. The kernel loads two modules from a boot image, each in its own address space, with an empty handle table.
3. The kernel gives both programs one shared ring.
4. Program A sends a typed record to program B through the ring. Program B prints it through a console ring.

This milestone uses properties 1, 2, 4, 6, 10, 13 and 17 in their smallest form. It needs no storage, no network and no graphics.
Secure Boot and the TPM measurement come after it, because they need only the boot program.
Each later step adds one capability to a system that already works.
