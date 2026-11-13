# Glossary

This file is the one place that defines the terms of the project. Each concept has one term. Documents, code and conversation use that term and no synonym.

Each term is a heading of level 3 in its group. The first paragraph under it is its short definition: one sentence that stands alone, because the site shows it alone in a tooltip, in a search result and in the page graph. The paragraphs after it explain the term: what it is for, how a program gets it and uses it, its neighbours, what it is not, an example from the system, and where its full design is. The last paragraph starts with "Do not use:" and lists the words that the term replaces. `kerneltool check` refuses an entry that does not have this form, and lists the terms that have no explanation yet.

## Code

### Module

A module is the one format of compiled code in the system: a file of position-independent machine code that exports functions and is named by the hash of its bytes.

A module solves the problem of the many code formats of other systems. Linux has executables, static archives, shared objects and kernel modules; each one has its own rules of search, link and load. Here a library, a program, a service, a command and the kernel are all modules of one format. A module that exports an entry function can start as a program; the same module can be loaded into another program and called as a library.

The identity of a module is the BLAKE3 hash of the whole file. A module names each import by that hash, never by a name or a path. So a module always meets the exact code that it was built with, unless a replacement changes it in a visible way. The file holds a header, a table directory, the flat tables of the module metadata (segments, imports, exports, slots, rebases, descriptions, documentation), then the bytes of the segments.

A program gets a module from its load source: the boot image that it was granted, or the files that its starter gives. The loader maps the segments, rebases them, binds each slot, and writes a module record in the kernel. Example: `load("calendar")` in the console loads the module `calendar` into the console and calls its exports directly; `isolate("calendar")` starts it as its own program, a call host.

A module is not a "package" of a source language, and not a source library: `contract` and `support` are compiled into modules and have no hash of their own. A kernel module of Linux runs with kernel privilege; a module here never does, except the one module that is the kernel.

The design: `docs/MODULE_CONTRACT.md`, "The module file", and `docs/PROPERTIES.md`, "One code module".

Do not use: unit, library, executable, binary, package, DLL, shared object. "Kernel module" names the Linux concept only.

### Export

An export is a function that a module makes callable from outside the module, with a description of its parameters and its result.

An export is the only thing that a module offers: a module exports no data, and a reader reaches data through a function. Each export has a record in the Functions table of the module metadata: its name, the offset of its code, the type of each parameter, its result, its error record and its documentation. With this description, a caller needs no other knowledge of the module.

One export serves three callers with no change: a direct call through a slot, an isolated call through a call ring, and a command of the console. Example: `sample.sum_values(readings: Table(Reading, Read)) -> Integer` is one export; the console, the program `tables` and a call host all call it.

An export is not a symbol of an object file: no search by name happens at run time, and a slot holds the index of the export in the module that the import names.

The design: `docs/MODULE_CONTRACT.md`, "The call form".

Do not use: symbol, entry.

### Import

An import is the name of another module inside a module: its hash, with the exports that the importing module calls.

An import replaces the library search path of other systems. The Imports table names each imported module by its BLAKE3 hash; the Slots table names, for each call, the import and the index of the export in it. So the loader does not search: it finds the module with that hash in its load source, or the load fails with the stage Find.

An import fixes the exact code. A module with another hash is another module, and only a replacement can put it in the place of the import, after a check of the descriptions. Imports by hash cannot form a cycle in the files; a replacement can make one, and the loader refuses it.

Example: the module `agenda` imports `calendar`; `manual.edges()` shows that edge, and `replace("calendar", "calendar_fixed")` makes the loader give `calendar_fixed` in its place.

The design: `docs/MODULE_CONTRACT.md`, "Loading".

Do not use: dependency, link.

### Module graph

The module graph is the set of modules as nodes and their imports as edges: one edge goes from the module that imports to the module that it imports.

The module graph answers two questions: which modules a program contains, and which programs a bad module reaches. Only an import by hash is an edge. A source library compiled into a module, a load by name, a connection to a service and a replacement are not edges.

The system gives two views. The site draws the module graph of the build, from the files. `manual.edges()` gives the module graph of the programs that run: one row for each import edge of each program, from the module records of the kernel, with the replacements that the loader applied. Example: `columns(where(manual.edges(), "replaces", "calendar"), "imported_by module replaces program")` shows the program `imports`, whose module imports `calendar_fixed` in place of `calendar`.

The design: `docs/MODULE_CONTRACT.md`, "Replacement of an import".

Do not use: dependency graph, call graph, link map.

### Command

A command is an export that the console can call: it is not a separate kind of thing.

In other systems a command is a program that parses text arguments and writes text. Here no program parses text from another program. The console reads the description of an export, completes its name and its arguments, checks the type of each argument, calls the export, and shows its typed result. So help, completion and argument checks come from the module metadata and from no code in each program.

An export is a command when the console can give each of its parameters: an export with an Append table parameter, for example, is not a command, because the console language has no second result. Example: `monitor.programs()` in the console is a call of the export `programs` of the module `monitor`, and gives a table.

The rule: `docs/PROPERTIES.md`, "A command is a function: no text between programs".

Do not use: CLI program, tool, script.

### Module metadata

The module metadata is the description of a module inside its own file: its segments, imports, exports with the type of each parameter and result, origin and documentation.

The module metadata is the one source of facts about a module. The loader reads its loader tables. The console, the manual and the information functions read its description tables. No separate manifest, header file or index exists, so no copy can disagree with the module. The metadata is a set of flat tables, valid when zero, at the offsets that the table directory gives.

The metadata is part of the bytes that the hash covers: a description cannot describe another version of the code. Example: `manual.check` reads the metadata of a module file and gives a problem with the byte of the file for each rule that it breaks.

The design: `docs/MODULE_CONTRACT.md`, "The module file", and `docs/PROPERTIES.md`, "Module metadata in flat tables, read through functions".

Do not use: headers, manifest, symbol table.

### Flat table

A flat table is an array of records of a fixed size at a known offset: the form of the module metadata inside a module.

A flat table needs no parser: a reader takes the offset, the count and the record size from the table directory, and reads a record by its index. Index 0 is the empty record. A table can grow: a record can gain fields at its end, and a reader that knows a shorter record ignores them, while a reader that knows a longer record reads the missing fields as zero.

The form follows the data-oriented rule of the kernel: a question across many modules is one linear read of small tables, not a query in a database. The system holds no SQLite and no index over the tables.

The rules: `docs/PROPERTIES.md`, "Module metadata in flat tables, read through functions", and `docs/PROPERTIES.md`, "Data-oriented kernel internals".

Do not use: section, blob.

### Replacement

A replacement is a record `{hash, hash}` that the starter of a program gives to the loader: where a module imports the first module, the loader loads the second one.

A replacement lets the publisher of the system fix a module in every program that imports it, with no new build of the programs. Example: module B has a security fault, and B2 has the correction; a replacement `{B, B2}` makes each import of B load B2. The file of the importing module does not change, so its hash stays.

The loader does not trust a replacement. For each slot that the importing module uses, it finds the export of the same name in B2 and compares the two descriptions: the parameters, the result, each record and the rights of each handle. One difference refuses the load, with a load error that names the export and the difference. The loader applies one record to one import: a module that replaces is not replaced.

A replacement is visible: the module record of B2 holds the hash that it replaces, and a fault report says "which replaces ...". A program cannot ask for a replacement and cannot refuse one.

The design: `docs/MODULE_CONTRACT.md`, "Replacement of an import".

Do not use: override, shim, LD_PRELOAD, DLL redirection.

### Replacement table

The replacement table is the list of the replacements of the machine, which the root service holds and gives to the loader of each program that it starts.

The table is one page of 32 records of 64 bytes (`system.Replacement_Table`). A count of versions lets a reader copy the records while the root service writes them. A program that loads modules, such as the console or the manual, receives the page with the right Read and reads it before each load.

A program cannot change the table. A program with the role Replace (the console) asks the root service: `replace("calendar", "calendar_fixed")` adds a record, `replace("calendar", "")` removes it, and `replacements()` lists the table. A change applies to the loads that follow; a program that runs keeps its modules.

The design: `docs/MODULE_CONTRACT.md`, "Replacement of an import".

Do not use: override list, LD_PRELOAD, redirection table.

### Loader

The loader is the code in user space that builds a program or a module space from a module and its imports (`support/system/load.odin`).

The kernel loads no module: it only maps memory objects and records what the loader asserts. The loader does five steps: it finds each module by hash in its load source and checks it, maps each segment, rebases the addresses inside the module, binds each slot to the address of an export, and records each module in the kernel (`Program_Module`). On a failure, the module space is as it was before the load, and the caller receives a load error.

The loader runs in the program that starts another program (the root service, the console), or in the program that loads a module for itself. It has no search path and no ambient store: it sees only its load source. The boot program contains a loader too, which loads the kernel module.

The design: `docs/MODULE_CONTRACT.md`, "Loading", and `docs/ARCHITECTURE.md`, "Module store and loader".

Do not use: linker, dynamic linker.

### Prepared module

A prepared module is the set of memory objects that hold the parts of a module that do not change after the load, kept by the program that starts programs, by the hash of the module.

A prepared module lets many programs share the pages of one module. It has two parts. The code is the segments that the loader never writes: their pages are the same at each base and with each binding, so the table keys them by the hash alone. The fixed part is the segments that are read-only after the load: the loader writes their rebases and slots, so the table keys them by the hash, the base, and the hash and base of each import.

The table (`system.Prepared_Modules`) keeps each handle without the right Write: no program writes a prepared module, and a write of a program to its code is a page fault. The kernel learns nothing of the module format: it maps memory objects with the rights of their handles.

The design: `docs/MODULE_CONTRACT.md`, "Loading".

Do not use: shared library, image cache, page cache.

### Shared code

Shared code is the pages of a prepared module that each program of the module maps without Write: its code, its constants and its data that is read-only after the rebase.

Shared code is why one module in many programs costs its pages once. Each program still has its own copy of each writable segment, made from the bytes of the file. Shared code needs code that the loader never writes: a call to another module goes through a slot in data, so the code pages stay identical to the file.

A merge of two modules into one makes a new hash, and two programs that merge the same module do not share its pages.

The design: `docs/MODULE_CONTRACT.md`, "Loading".

Do not use: text segment, shared object.

### Slot

A slot is 8 bytes of data of a module that the loader writes with the address of one export of an import.

A call to another module is one indirect call through a slot: `call *slot(%rip)`. The code never changes with the place of the other module, so code pages stay shared. After the bind the loader makes the slots read-only. A merge of two modules can rewrite a call through a slot into a direct call and remove the slot.

A slot is bound once, at load: no lazy binding, so a missing export fails the load and never a later call. Measured: a call through a slot costs about 3.5 ns in the program `imports`.

The design: `docs/MODULE_CONTRACT.md`, "Static is dynamic".

Do not use: GOT entry, import address, stub.

### Load source

The load source is what a loader can read: the files that its program was granted, each named by its hash, and the replacements that the starter of the program gives.

The load source closes the hole of a global library directory. A loader finds an import only in its load source, and checks the hash and the tables of each file before it uses it. The root service and the console give the boot image. A call host receives a list of files from the console, on one page in the form of the boot image: the module, its imports and the modules of the replacements.

A file that the load source does not hold gives the load error Find; a file whose bytes do not have their hash gives the load error Read.

The rule: `docs/PROPERTIES.md`, "No ambient access: the other holes to close".

Do not use: search path, library path, module store (for this).

### Module space

A module space is the set of modules that a loader put in one program, each module one time.

Two modules that import a third one call the same copy of it: the module space counts the uses of each module. A module that another module of the space uses stays when its caller unloads it; a module with no use leaves, and its imports lose one use. `system.module_space_release` removes a module; when the kernel refuses the removal, the load error has the stage Unmap.

The design: `docs/MODULE_CONTRACT.md`, "Loading".

Do not use: link map, address space (for this).

### Load error

A load error is the record of a load that failed (`module.Load_Error`, 288 bytes): the stage, the module that was being loaded, the import, a replacement on the path, the export, and the two descriptions that differ.

A load error is the error record of the loader. It is larger than an error record because it names modules by hash and by name: the caller of a call host does not have these names. Zero is "no error". The caller owns the record; no global state keeps the last error.

The stages are Find, Read, Cycle, Check, Bind, Map, Room and Unmap. `system.load_error_text` writes the record as sentences, for example "error: agenda imports calendar, and its replacement calendar_changed fails the check". A caller can give a table of error details, and receives one load error for each import that is missing or has the wrong hash.

The design: `docs/MODULE_CONTRACT.md`, "The error of a load".

Do not use: exception, errno, error message.

### Stop report

A stop report is the record that the kernel keeps of a program that stopped on a fault (`op.Stop_Report`): the stop code, the instruction, the address, the module record of the module that ran, and the stack trace.

A stop report replaces a core dump. It is small and typed, and the kernel writes it at the moment of the fault, from what it knows: the frame of the thread, its frame pointers and the module records of the program. The holder of the program handle with the right Read reads it with `Program_State`.

The stop code says why the program stopped: `STOP_CODE_FAULT` plus the vector of the exception (0x10E for a page fault), `STOP_CODE_RETURN` for a refused return, `STOP_CODE_FAULT_UNANSWERED` when its fault ring ended with a waiting thread. Example: the console prints "error: the instruction is at offset ... of calendar_fixed ...".

The design: `docs/MODULE_CONTRACT.md`, "A fault: the stack trace".

Do not use: core dump, crash report, signal info.

### Refused return

A refused return is a return of the kernel to a thread that the processor refuses at `iretq`: the kernel stops the program of the thread, as its own fault, with the stop code `STOP_CODE_RETURN`.

The kernel returns to a program only with `iretq`. Before each return it checks the frame: an instruction address at or above `USER_END`, or a stack address that is not canonical, cannot pass. A fault of the `iretq` itself is a fault of the thread, not of the kernel. In each case the stop report has the address that the processor refused, and the machine goes on.

A refused return can come from a frame that a program wrote with thread control. Thread control checks the frame when it is written; the check at the return is the second layer.

The design: `docs/ARCHITECTURE.md`, "The return to a program".

Do not use: bad iret, iret fault.

### Error record

An error record is the record of 56 bytes that a call that failed gives back to its caller (`errors.Error_Record`): what is wrong, which argument, the value that it had, the limit, and what the system found.

An error record replaces `errno`, exceptions and error texts. A status or a negative result stays the fast answer; the error record explains it. It is a value of the call, in memory that the caller owns: no global state, no last error, no text. Its seven Integer fields are the kind, the unit, the operation or export, the number of the argument, the value, the limit and what the system found. Zero is no error.

The record has three places. A kernel operation gives it in the values of its completion record. A ring of a service gives it in the values of a completion whose status is not 0. An export writes it at an address that the caller gives, as its last parameter. A record names only what the caller gave and what the caller can see: no fact of another program.

`system.error_text` writes one sentence from the record, for example "Memory_Map: the argument memory, handle 0x30004, has the rights Give Read; the operation needs Read Write".

The design: `docs/MODULE_CONTRACT.md`, "The error record".

Do not use: errno, exception, error code, detail record, error message.

### Error detail

An error detail is one thing that a call that failed has to say, as one record of the error form of the call: an error record for an export, a load error for the loader.

An error record holds one failure: the first argument that is wrong. A caller that wants each failure gives a table of error details, and the callee appends one detail for each thing that it finds, in order. The error record of the call is the first detail, so a caller with no table receives the same first answer.

Example: the console gives a table of 16 details to each command, and prints each detail after the error when there is more than one.

The design: `docs/MODULE_CONTRACT.md`, "The table of error details".

Do not use: sub-error, cause, inner error, error list, diagnostic.

### Table of error details

A table of error details is an optional Append table parameter of error details, in memory of the caller: the last parameter of an export that has an error record.

The table follows the rules of each Append table: the callee writes the details that fit, and the count is the count of all the details, also those that did not fit. With no table (`nil` in a direct call, the capacity 0 in an isolated call) the call gives its error record only. On success the callee does not touch the table, so the path of success costs nothing.

In Odin the parameter is `details: ^system.Table_To_Append(errors.Error_Record)`. A reader finds it with `module.error_details_parameter`.

The design: `docs/MODULE_CONTRACT.md`, "The table of error details".

Do not use: error list, error buffer, error stack, error chain.

### Error kind

An error kind is the first field of an error record: what is wrong (`errors.Kind`).

Examples of kinds: an empty argument, a handle that was revoked (`Handle_Ended`), a handle without a right (`Handle_Rights`), a budget that cannot pay (`Budget`), a value out of range (`Bad_Value`), a table that is full (`Full`). Each kind fixes the meaning of the fields `limit` and `found`. Each status of the kernel has its kinds; a kind that does not explain the status becomes `Refused`, an honest "no more detail".

The documentation of an export names the kinds that it gives, and `manual` shows them.

The list: `contract/errors/errors.odin`.

Do not use: error code, errno value, exception type.

### Frame pointer

A frame pointer is the register `rbp` of a function: the address of its frame on the stack, where the frame pointer and the return address of its caller are.

Every module keeps frame pointers, so that the kernel, a debugger or a profiler walks the stack with no unwind tables and runs no code of the program. The kernel tool compiles each module through LLVM with `--frame-pointer=all`. The cost, measured: the code of `console` is 0.45 % larger, and a call through a slot is about 0.4 ns slower.

The rule: `docs/MODULE_CONTRACT.md`, "Closed rules".

Do not use: base pointer, frame record.

### Stack trace

A stack trace is the list of the return addresses of the calls that led to a fault, from the frame pointers, each with the module record that holds it.

The kernel writes the stack trace into the stop report: frame 0 is the instruction, and each next frame is a return address. The walk stops at 16 frames, or at a frame pointer that is 0, not aligned, not above the one before, or not memory of the program. A reader names each frame "module + offset"; the kernel tool names the function from the linked file of the module.

The design: `docs/MODULE_CONTRACT.md`, "A fault: the stack trace".

Do not use: backtrace, call stack (for this), unwind.

### Module record

A module record is what the kernel keeps of one module in a program (`op.Module_Record`, 80 bytes): its base address, its size, its hash, and the hash that a replacement put it in place of.

The loader writes the record with `Program_Module` after it mapped the module. The kernel does not read the module: the record is what the loader asserts. The kernel uses it to name the module of a fault address and of each frame of a stack trace, and `Inspect` gives the records of a program. A program has at most 16 module records.

The module records of a program that runs are its identity: `manual.running()` and `manual.edges()` read them.

The design: `docs/MODULE_CONTRACT.md`, "Loading".

Do not use: link map entry, loaded image list.

### Table

A table is a set of records of one record description that follow each other in memory, with their count.

The table is the unit of data of the system. An information function gives a table; the console holds a table as one value and passes it to the next function with no parsing. A Table result is written by the callee in memory of the caller, with the count of the full table: a count above the capacity means that the table did not fit. A record of a table holds values only, and no Handle field.

Example: `monitor.programs()` gives a table of `Program` records, and `where(...)` and `columns(...)` in the console take and give tables.

The rules: `docs/PROPERTIES.md`, "Module metadata in flat tables, read through functions", and `docs/PROPERTIES.md`, "A command is a function: no text between programs".

Do not use: list, array (for this), result set, rowset, data frame.

### Table parameter

A table parameter is a parameter of an export of the type Table: records of one description in memory of the caller, with a direction.

A table parameter lets a call work on many records at once with no copy in a direct call. In a direct call the callee receives the address of a table place and works in the memory of the caller. In an isolated call the caller copies the records into the call region, or lends a memory object when they do not fit; the receiver checks every offset and count before the export runs.

Example: the cryptography module seals N packets in one call: `seal(packets: Table(Packet, Change), bytes: Bytes(Change), key: Key)`.

The design: `docs/MODULE_CONTRACT.md`, "Tables and bytes as parameters".

Do not use: array argument, buffer argument, list parameter.

### Bytes

Bytes is a parameter type: bytes with no description, in memory of the caller, with a direction.

Bytes is a table parameter whose record is one byte. The bytes need not be UTF-8: they can be the bytes of packets or of a picture. A Text is the read-only form of UTF-8 for a reader; Bytes is the form for data. In Odin the types are `^system.Bytes_To_Read`, `^system.Bytes_To_Change` and `^system.Bytes_To_Append`.

The design: `docs/MODULE_CONTRACT.md`, "Tables and bytes as parameters".

Do not use: blob, buffer, byte array, binary.

### Direction

A direction says what the callee does with the memory of a table parameter or of a Bytes parameter: Read, Change or Append.

- Read (0): the callee reads the records from 0 to the count, and writes nothing.
- Change (1): the callee reads and writes the records from 0 to the count; the count stays.
- Append (2): the callee writes after the count, up to the capacity, and gives the count of the full answer, also the records that did not fit.

Read is 0 because the zero direction has the least power. A lent memory object gets the rights of the direction: Read for Read, Read and Write for Change and Append. A replacement whose export has another direction fails its check.

The design: `docs/MODULE_CONTRACT.md`, "Tables and bytes as parameters".

Do not use: mode, access, in/out, intent.

### Table place

A table place is the record of 24 bytes `{address, count, capacity}` in memory of the caller that names the memory of a table parameter or of a Bytes parameter in a direct call.

The callee receives the address of the table place in one register. Count and capacity are in records (in bytes for Bytes). No record size travels with the place: the caller and the callee have the same description, because the import names the exact module. In an isolated call the field of the argument record has 32 bytes in its place: the start, the count, the capacity and a lent memory object or 0.

The design: `docs/MODULE_CONTRACT.md`, "Tables and bytes as parameters".

Do not use: descriptor, span, fat pointer, buffer record (for this).

### Information function

An information function is a function that reads the flat tables of modules, the module records of the kernel or the replacement table, and fills a table in memory of the caller (`support/information`).

The information functions replace a database of modules. They allocate nothing and keep no state; each one reads the tables in a line and gives records. The manual service exports them, so the console can combine them: `manual.running()`, `manual.edges()`, `manual.check()`. A new kind of question is a new function, or a combination of functions in the console.

The rule: `docs/PROPERTIES.md`, "Module metadata in flat tables, read through functions".

Do not use: query, reflection API, introspection.

### Catalog

A catalog is the input of an information function: the modules that a program can see, and the replacements of the machine.

Today a catalog is the boot image that the program was granted and the records of the replacement table. An information function sees nothing else: a program with no grant of the boot image has an empty catalog.

Do not use: registry, repository, package database, index.

### Problem

A problem is the error value that a reader of input that nobody checked gives for a rule that the input breaks: the kind, the place, the byte, the bad value and its limit.

A problem is the error record of a parser of hostile bytes. An information function gives one for a module file (`information.Problem`): the table and the record of the module, and the byte of the file. The network service gives one for a frame (`datagram.Problem`): the layer of the frame and the byte. Example: `manual.check` gives a problem for a Table parameter whose record has a Handle field.

Do not use: exception, errno, error code.

### Boot image

The boot image is the one block of data that the boot program loads with the kernel: the modules of the first programs and the resources, each with its name and its hash.

The boot image starts the system with no file system. Its header has a table of modules, then a table of resources (`contract/boot_info`): a name of 31 bytes at most, the BLAKE3 hash of the bytes, the offset and the size. Each file starts on a page. The boot program checks each entry against the system description before the kernel starts; the root service checks them again before the first program starts.

The root service is the load source of the first programs. A program receives the boot image only by a grant (the grant `Image`); the console and the manual have it.

The design: `docs/ARCHITECTURE.md`, "Resources of the boot image".

Do not use: initrd, ramdisk.

### Position-independent

Position-independent code runs correctly at any address with no change to its bytes.

All code of the system is position-independent: a module reaches its own data relative to the instruction, and another module through a slot. The loader writes only data (the rebases and the slots), never code. So code pages stay shared and never writable.

The rule: `docs/PROPERTIES.md`, "One code module".

Do not use: relocatable, PIC, PIE.

### Scalar form

The scalar form of a procedure computes one value with one instruction, in the general registers.

The scalar form is the reference of each vector form of the same procedure, and the code of a target with no vectors. A host test compares the two forms for every input that it can reach: they must give the same bytes.

The rule: `docs/SIMD.md`, "The rule of the same bytes".

Do not use: plain C version, fallback (for this), slow path.

### Instruction template

An instruction template is an `asm` procedure of Odin: instructions of the processor, with parameters and results in registers that it names, that the compiler puts in the code of each caller with no call and no return.

The kernel writes its small instructions this way: ports, model-specific registers and control registers. Code that owns the stack or the frame stays in the assembler file `kernel/processor.asm`.

The design: `docs/ARCHITECTURE.md`, "The instructions of the kernel".

Do not use: inline assembly, intrinsic (for this), asm helper.

### Vector form

A vector form of a procedure computes several values with one instruction, in the 128-bit registers of SSE2, and gives the same bytes as its scalar form for every input.

The system has one vector width, SSE2, which every x86-64 processor has, so a vector form needs no test of the processor. An AVX2 form was measured and lost to the SSE2 form for the blend of a glyph and for BLAKE3, so the system has none. The kernel has no vector code at all.

The design: `docs/SIMD.md`, "One form: SSE2".

Do not use: SIMD version, kernel (for this), fast path, intrinsics version.

### Debug object

The file of the names of the procedures of one module and of the source lines of its code: a procedure table, a file table, a line table and strings, in fixed records (`contract/debug_object`). It names its module by the hash of the module file; the module names nothing, so its bytes are the same with and without it. The kernel tool writes it from the DWARF of the linked file; the system reads no DWARF (`MODULE_CONTRACT.md`, "Debug information")

Do not use: symbol file, PDB, dSYM, debug info (for the file), symbols

### Procedure table

The table of a debug object that gives, for each procedure of the module, its start and its size in the memory of the module and its name with its package (`fault::three`), by their start

Do not use: symbol table, function table

### Line table

The table of a debug object that gives, for each range of the code of the module, the source file and the line, by their offset. A row with no file says that the code after it has no line

Do not use: line program (the form of DWARF that the tool reads), line info

### Debug image

The debug objects of the modules of a build in one file, in the form of a boot image. The tool writes it on the boot volume beside the boot program (`DEBUG/OBJECTS.IMG`), the boot program reads it, and the root service maps it read-only into each program with its grant. It is not in the boot image

Do not use: symbol server, debug archive


## Running code

### Program

A program is a running module with its own address space and its own handle table.

A program is the unit of isolation: its memory and its handles are its own, and it reaches nothing else. A new program starts with no memory and no handle. Its starter makes it with `Program_Create` (a budget pays for its slot, its page tables and its first thread), maps the memory of its module into it, gives it handles, and starts its first thread with `Program_Start`. The starter keeps the program handle: with the right Control it stops the program, and with Read it reads its state and its stop report.

A program runs while a handle names it: when its last handle closes, the kernel stops it (the stop code `STOP_CODE_NO_HANDLE`). A program with no thread stops too. Its kernel objects end with it, and what they cost returns to the budget that paid.

A program is not a "process" of Unix: it inherits nothing from its starter (no open files, no environment, no working directory), and receives one context. It sees no other program but those whose handles it holds. Example: the console starts `notes` through the root service; the root service holds its program handle and its terminal.

The design: `docs/ARCHITECTURE.md`, "Handle table", and `docs/PROPERTIES.md`, "Sandbox by default".

Do not use: process, task, application, app.

### Thread

A thread is one flow of execution inside a program: a register state, a thread record and a kernel ring.

The threads of a program share its memory and its handles. A program has at most 32 threads (`THREAD_CAPACITY`), and the machine at most 256. `Thread_Create` makes a thread: a budget pays for its slot and its thread area, and the call gives the entry address, the stack, one parameter, a weight and a request. The thread starts at the entry with the parameter in its first register, and with its thread record in its `gs` register.

A thread asks the kernel for work through its own kernel ring, and waits with the word wait. It ends with `Thread_Stop`, by its own return or by a stop of its program. A thread handle with Control ends it from another thread; thread control holds it and reads its registers with other rights.

The design: `docs/ARCHITECTURE.md`, "Scheduler".

Do not use: fiber, task.

### Thread record

The thread record is the page that a thread can read about itself (`op.Thread_Record`): its own address, the parameter of its entry, its number, its event word, and the fault ring when the thread is a fault handler.

The `gs` register of the thread holds the address of the record, and the first word of the record is that address, so `mov rax, [gs:0]` gives it on any stack. The kernel ring of the thread is one page after the record. The kernel writes the record when the thread starts; after that it only adds to the event word and writes the fault ring.

The record holds no data of a module: the system has no thread-local storage, and `fs` is free for the program.

The rule: `docs/MODULE_CONTRACT.md`, "Closed rules".

Do not use: thread-local storage, TLS, TEB.

### Word wait

The word wait is the one way for a thread to wait for something else than a time: the thread waits while each 32-bit word of a list holds a given value.

`Word_Wait` takes a list of up to 64 words, each with the value that it holds while the thread waits, and a deadline. Another thread changes a word, then calls `Word_Wake` on it. If a word does not hold its value when the thread enters the wait, the wait ends at once, so no wake is lost. The kernel names a word by its physical page frame, so two programs that map one memory object wait on one word.

Every wait of the system uses it: a ring waits on its counters, a lock and an event on their words, a thread on its event word. `support/system/wait.odin` builds a list from these words.

The design: `docs/ARCHITECTURE.md`, "Rings and wait".

Do not use: futex.

### Lock

A lock is one word of memory that one thread holds at a time (`system.Lock`).

A lock takes no kernel entry when it is free: one compare-and-exchange takes it. A thread enters the kernel only to wait for a lock that another thread holds, with the word wait, and the thread that frees it wakes one waiter. A zero lock is free. A lock in shared memory works between two programs.

A lock of a program is not a lock of the kernel: the kernel has its own locks, which are words of the kernel that one processor holds.

Do not use: mutex, critical section, semaphore.

### Event word

The event word is a word of the thread record that the kernel adds 1 to when an event of the thread arrives.

The events are: an interrupt of the program, the stop of a program whose handle the program holds, and the end of another thread of the program. The thread reads the word, reads the state that it needs, then waits on the word with the value that it read first: an event between the read and the wait ends the wait at once. `system.wait_begin` starts each wait list with the event word.

An event word replaces signals: the kernel never runs code of the program in the middle of other code.

Do not use: signal, notification.

### Processor

A processor is one unit of the machine that executes instructions, and runs one thread at a time.

A machine has several processors. The kernel keeps one processor record and one run queue for each, and its locks are made so that the processors work in parallel. The first machine is QEMU with 4 processors in the machine test.

Do not use: core, CPU, hart.

### Processor record

The processor record is the record that the kernel keeps for one processor: its kernel stack, its current thread, its page table, its frame cache, its counts and its observed kinds.

Most fields of a processor record are written only by its own processor, so they need no lock. Other processors read some fields with atomic loads, and set a few flags (`pending`, `preempt`) to ask the processor for work.

The design: `docs/ARCHITECTURE.md`, "The data of the kernel".

Do not use: per-CPU data.

### Switch of threads

A switch of threads is the moment when a processor leaves one thread and takes another one, or the same one again, from a run queue (`schedule`).

A processor leaves a thread when the thread waits, when its turn ends, at a preemption or at a stop. The kernel saves the extended state of the thread that it leaves and restores the extended state of the thread that it takes there, and nowhere else: a kernel entry saves no vector register, because the kernel has no vector code. A kernel event `Switch` records each switch for a program with the right Events.

The design: `docs/ARCHITECTURE.md`, "The extended state of the processor".

Do not use: context switch, task switch.

### Extended state

The extended state is the registers of a thread that are not general registers and that the processor saves and restores as a block: the x87 registers, the SSE registers and `MXCSR`, and, when the kernel enables them, the AVX and AVX-512 registers.

The kernel saves each state component that it enables, and writes `CR4` and `XCR0` itself: a kernel that keeps the setting of the firmware lets a program read the AVX registers of another thread. The save uses `xsaveopt`, or `fxsave` on a processor with no `xsave`. The boot log says what one save writes, for example "one save writes at most 832 bytes, in an area of 2688 bytes in each thread entry".

Thread control reads and writes the extended state of a held thread, and checks a written area before the kernel can restore it.

The design: `docs/ARCHITECTURE.md`, "The extended state of the processor".

Do not use: FPU state, floating-point state, vector state, XSAVE state.

### State component

A state component is one part of the extended state that one bit of `XCR0` enables and that the processor saves as one unit.

The kernel enables x87 (bit 0) and SSE (bit 1) always, AVX (bit 2) when the processor has it, and the three parts of AVX-512 (bits 5 to 7: the opmask registers, the high halves of zmm0 to zmm15, and zmm16 to zmm31) when the processor has AVX-512 F. It enables no component that it does not save: MPX, PKRU and AMX stay off. Every processor of the machine must have the same components at the same offsets, else it stays stopped.

The design: `docs/ARCHITECTURE.md`, "The extended state of the processor".

Do not use: XSAVE feature, xfeature.

### Extended state area

The extended state area is the memory where the kernel saves the extended state of one thread: a fixed field of 2688 bytes, aligned on 64 bytes, in the entry of the thread in the thread table of the kernel.

The area is complete while the thread is on no processor; while the thread runs, its state is in the registers. Only the kernel reads and writes it, and no program maps it. It is part of the slot of the thread, which the budget pays with its `threads` amount: 256 slots cost 672 KiB of kernel memory.

The design: `docs/ARCHITECTURE.md`, "The extended state of the processor".

Do not use: FPU area, XSAVE area, save area.

### Usable instruction set

A usable instruction set is a group of instructions of the processor (SSE4.2, AVX2, AVX-512 F, BMI2, ...) that the processor has and whose registers the kernel saves.

A program reads the sets once with `support/instruction_sets`, from `CPUID` and `XCR0`, with no kernel operation. A set that the processor has but whose state the kernel does not save is not usable: an instruction of it stops the program with an invalid opcode.

Do not use: CPU feature, ISA extension.

### Start state

The start state is the content of the extended state area of a new thread: the x87 control word `0x037F`, `MXCSR` `0x1F80`, every register zero, and a header that says that only x87 and SSE are in the area.

A new thread receives no state of the thread that had its slot before: the kernel writes the start state at each creation.

Do not use: init state (for this), initial FPU state.

### Stage

A stage is one part of the start of the machine, with a start time and a duration: the firmware, two parts of the boot program, and four parts of the kernel.

The boot record holds the stages; the boot display and the card of the start show them with their measured time.

Do not use: phase.

### Step of the start

A step of the start is one point on the path of the start that the boot display shows (`bootscreen.Step`): ten points from the firmware to the desktop.

The steps are Firmware, Kernel_Module, Boot_Image, Memory_Map, Kernel, Processors, Root, Input, Compositor and Desktop. The program that draws says which step the machine does now. A step has no time; a stage is a part with a measured time.

Do not use: phase, progress.

### Card

A card is the frame of one subject in a display: a title in its accent, a caption that names its record, and its content.

The boot display, the monitor and the site draw their facts in cards, so that each subject has one place and one color.

The rules: `docs/DESIGN.md`, "Elements".

Do not use: panel, box, widget.

### Tile

A tile is a rectangle that stands for one thing of a set, with its name inside; its width can show a size.

Example: the card of the boot image shows a tile for each file of the image.

The rules: `docs/DESIGN.md`, "The card of the boot image".

Do not use: chip, badge.

### Size strip

A size strip is a bar of one row in which each file of a set is a part as wide as its share of the bytes, with a least width.

The parts fill the bar exactly and carry no name. The card of the boot image starts with one, so the eye sees at once which files are large.

The rules: `docs/DESIGN.md`, "The card of the boot image".

Do not use: treemap, histogram, size bar.

### Accent

An accent is the color of the concept that a card is about.

One concept keeps one accent on every display, so a reader finds the same subject by its color.

The rules: `docs/DESIGN.md`, "Color".

Do not use: theme color.

### Boot record

The boot record is the record that the kernel keeps of how the machine started (`op.Boot_Report`): the stages, the memory ranges, the firmware, the framebuffer, the sizes of the kernel and of the boot image, and the trust record of the boot program.

A program with the machine handle and the right Inspect reads it. The boot display and the monitor show it.

Do not use: boot log, dmesg.

### Guard page

A guard page is a page of addresses with no memory, next to a stack: a use of it is a page fault, not a write on other memory.

The kernel puts a guard page before and after each kernel stack and each interrupt stack. The loader leaves one page with no memory between two modules. A stack that overflows into a guard page stops at once, at the instruction that overflowed.

Do not use: red zone, canary.

### Interrupt stack

An interrupt stack is a stack of one processor that the processor loads itself for one exception, from the task state, at any privilege.

The double fault, the debug exception, the non-maskable interrupt and the machine check each have one, between guard pages. These exceptions can come when the kernel stack is full, or when the stack pointer is still the one of a program: a known good stack is then the one safe place.

Do not use: IST, exception stack, NMI stack.

### Direct map

The direct map is the part of the kernel half of the addresses that shows all physical memory.

The kernel reads and writes any frame through it: a thread record, an event ring, a page table. It is never executable, so no write of data can become code of the kernel.

Do not use: physmap, identity map.

### Run

A run is a set of pages that follow each other in a page table with one protection (`Mapping_Run`).

The report `Inspect` of kind `Mappings` (`op.Mapping_Report`) gives the runs of the kernel half or of the half of the program that asks: one record for each run, not one for each page, so its size follows the mappings and not the memory.

Do not use: extent, VMA.

### Self test

A self test is a boot of the machine in which the kernel does one thing that its page tables must refuse, to prove that the processor refuses it.

The tests are a stack overflow, a write to the code of the kernel and to its view in the direct map, a run of data, and a read and a run of memory of a program from the kernel. The expected fault stops the machine with its report, and the machine test checks that report.

Do not use: negative test, lkdtm.

### Log record

A log record is one entry of the log of the kernel (`op.Log_Record`, 256 bytes): a number, a time, a program, a thread, a level, a channel, a text and the value runs of the text.

A program writes a record with the kernel operation `Log` and a log handle with Write. The kernel sets the number, the time, the program and the thread, so a program cannot write a record in the name of another one. The text has 152 bytes at most per record; a longer text continues in the next record. The serial port prints the text only. The budget of the program limits its log records in each second.

A program with the grant to read the log serves the records as a table: `log.records(after)`, and their value runs: `log.value_runs(after)`.

The design: `docs/TOOLS.md`, "The log".

Do not use: log line, message.

### Value run

A value run is a part of the text of a log record that is one value: a start, a length and its value kind.

A writer states the kind of each part of a line of the log (`system.Size`, `system.Duration`, `system.Module_Name`, a number...), and the record keeps the runs beside its text, at most 8 per record. A reader draws each run in the color of its kind; a reader that ignores the runs reads the same text. A run gives a color, never text: runs that do not fit their text leave the record plain, and its text whole. It is not a run of code: a run of code is a part of a line of the console, with a code kind.

The design: `docs/TOOLS.md`, "The log".

Do not use: span (for this), token, highlight range.

### Cut mark

A cut mark is the end of a text that a place of a fixed size does not hold: the start of the text, cut after a whole character, then "... and N bytes more" (`contract:cut_mark`).

N counts each byte that the place does not hold, so the reader knows what is missing. It is the one form of a cut text in the system: a text is written whole, cut with this mark, or refused; never cut in silence. `kerneltool check` refuses a source that sets the count of a writer by hand.

The rule: `docs/ARCHITECTURE.md`, "A text is never cut in silence".

Do not use: ellipsis, truncation, "..." (alone).

### Channel

A channel is the short name of 16 bytes at most that a program gives to a log record, to group the records of one subject.

A record with no channel has 16 zero bytes there. A reader of the log, such as the step `Record` of the machine test, chooses records by program, channel and level.

Do not use: facility, tag, category, logger.

### Level

A level says how much a log record matters: Info, Debug, Warning or Error.

Info is 0, the default. Debug is for the reader who looks for a fault.

Do not use: severity, priority.

### Lock of the kernel

A lock of the kernel is a word that one processor holds at a time, to change one kind of data of the kernel.

The kernel has no lock for the whole kernel: each lock protects a table or a part of a table, and each kind of lock has its place in the lock order. Interrupts are off in the kernel, so a processor never takes a lock again in an interrupt. A processor that waits for a lock answers `processor_sync` while it waits. The lock count of each kind is in the system report, and a kernel event `Lock_Wait` records each wait.

A lock of the kernel is not the lock of a program, which is a word of the program.

The design: `docs/ARCHITECTURE.md`, "Locks of the kernel".

Do not use: spinlock, mutex (for this).

### Lock order

The lock order is the order of the kinds of locks of the kernel: control, program, origin, region, frame, cache, log, wait, run.

A processor takes a lock only if it holds no lock of a later kind. A cycle of waits needs a processor that waits for an earlier kind while it holds a later one, which the order forbids: so no deadlock exists. The test build checks the order at each take and stops the machine with a report if it is broken.

The design: `docs/ARCHITECTURE.md`, "The locks, in their order".

Do not use: lock hierarchy, lock ranking.

### Control lock

The control lock is the one lock of the kernel for the paths that cross programs or end objects that several programs name: start, stop, give to another program, revoke.

These paths touch a set of programs with no bound: a revocation follows the origins through any program, and a stop closes handles that stop other programs. One lock makes each of them atomic for the others. They are rare (a program does them when it starts, stops or gives access, not in its work), and the measures show that the hot paths do not take it.

The design: `docs/ARCHITECTURE.md`, "The locks, in their order".

Do not use: big kernel lock, giant lock, kernel lock.

### Program lock

The program lock is the lock of one program: its handles, its mappings and its page table.

A kernel operation of a program takes its own program lock, so two programs work in parallel. A processor holds two program locks only under the control lock.

The design: `docs/ARCHITECTURE.md`, "The locks, in their order".

Do not use: address space lock, mmap lock.

### Frame lock

The frame lock is the lock of the page frames, the reserved pages, the pages of the budgets and the slots of the memory objects.

Each move of pages between a budget, the reserved pages and the frame table is one section under the frame lock, so the sum of the frames holds whenever it is free. The frame cache of each processor keeps most first uses away from it.

The design: `docs/ARCHITECTURE.md`, "Rules that keep each path correct".

Do not use: zone lock, page allocator lock.

### Run queue

A run queue is the threads that are ready and that no processor runs, of one processor: its home threads.

Its run lock protects it and the scheduling state of these threads. A new thread goes to the queue of the processor that created it; a woken thread goes to the queue of its home. A processor with less work takes threads from a queue with more, so the ready threads spread over the processors. The strategy of the machine orders each queue.

The design: `docs/ARCHITECTURE.md`, "Rules that keep each path correct", and `docs/SCHEDULING.md`, "What this system takes".

Do not use: runqueue, ready list.

### Strategy

A strategy is the rule that orders the ready threads of each run queue: a table of six functions of the kernel over fixed fields of the thread and of the run queue.

The six functions are ready, pick, tick, stopping, wake preemption and move. The machine has one strategy at a time: round robin, fair or EEVDF. A strategy owns no memory: its state is fields of the thread and of the queue, zero when the strategy has not placed the thread.

A program with the right Schedule on the machine changes the strategy while the system runs (`Strategy_Set`): each queue converts under its run lock, and no thread stops or is lost. The root service gives that right only to the program `scheduler`. The limit of a budget is not a strategy: it holds under each one.

The design: `docs/SCHEDULING.md`, "What this system takes".

Do not use: scheduler class, policy, scheduling algorithm, governor.

### Turn

A turn is the time that a thread runs on a processor from its pick to the moment when it leaves: it waits, its budget has no time, or its strategy ends the turn.

A turn is not a state of a thread: a wake preemption ends a turn, and the thread stays ready.

Do not use: quantum, timeslice (for this).

### Time slice

The time slice is the longest turn under each strategy: 10 ticks.

At the end of a time slice the processor passes through the balance between the processors. So each processor that has a thread looks at the other queues at least each 10 ms. Under round robin each turn has this length.

The design: `docs/SCHEDULING.md`, "The time slice is the longest turn".

Do not use: quantum.

### Weight

A weight is a number from 1 to 1024 of a thread: its share of a processor against the other threads of its queue, under a strategy with weights.

The weight is set when the thread is created. 0 is 1024, the full weight, so a program that gives no weight gets the most. A program can only lower or split its own share, never raise it above a thread with no weight. The processor limit of the budget stays above any weight: a strategy only orders the time that the budget gives.

The design: `docs/SCHEDULING.md`, "Weights and requests: a field at thread creation".

Do not use: priority, nice value, shares.

### Virtual time

The virtual time of a thread is its run time in weighted cycles: a run of c cycles adds c * 1024 / weight.

The fair strategy runs the thread whose virtual time is least; EEVDF runs an eligible thread with the earliest virtual deadline. A thread with half the weight gains virtual time twice as fast, so it runs half as much. Two virtual times are compared by the sign of their difference, so the counter can wrap.

The design: `docs/SCHEDULING.md`, "Integer arithmetic and the overflow argument".

Do not use: vruntime, virtual runtime.

### Queue clock

The queue clock is the virtual time of a run queue that never goes back: the least virtual time of its ready threads, as the kernel last saw it.

A thread that wakes or moves is placed against it. The kernel keeps each queued thread within a bound under the clock, so a thread that did not run for a while does not take the processor for a long time when it comes back.

Do not use: min_vruntime.

### Lag

The lag of a thread, under EEVDF, is the average virtual time of its queue minus its own virtual time: what the thread is owed.

A positive lag makes the thread eligible. The lag is kept across a wait, within a bound of two requests (at least one tick), so a thread that slept is neither punished nor paid for its sleep without limit.

Do not use: debt, credit.

### Eligible

A thread is eligible, under EEVDF, when its lag is zero or more.

Only an eligible thread can be picked, when one exists: a thread that ran more than its share waits until the others caught up.

Do not use: runnable (for this).

### Request

A request is the processor time that a thread asks for at each turn under EEVDF, in microseconds: 1 to 100 000, and 0 is 3000.

The request sets the virtual deadline, not the share: a short request makes the thread run sooner and more often, for shorter turns. Its cost, more switches, is in the time of the thread, which its budget pays.

The design: `docs/SCHEDULING.md`, "Weights and requests: a field at thread creation".

Do not use: slice (for this), quantum.

### Virtual deadline

The virtual deadline of a thread, under EEVDF, is its virtual time plus its request in weighted cycles.

Among the eligible threads, the one with the earliest virtual deadline runs. A thread with a short request gets an early deadline, and so a short delay.

Do not use: deadline (alone: the deadline of a wait).

### Wake preemption

A wake preemption is the end of the turn of the thread that runs on a processor because a thread that woke must run first, by the rule of the strategy.

When the processor of the woken thread is the waker's own, the waker ends the turn itself. On another processor, the waker sets a flag of that processor and sends it an interrupt. A thread of another program preempts one processor at most once in each millisecond: without this limit, a program with threads that wake each other makes other programs pay for the interrupts. Round robin has no wake preemption.

The design: `docs/SCHEDULING.md`, "Wake preemption, also on another processor".

Do not use: wakeup preemption, preempt-on-wake.

### Spinner

A spinner is a thread of the program `scheduler` that computes with no end, and counts its work.

The program `scheduler` runs spinners with different weights and requests, and compares their counts under each strategy.

Do not use: busy loop, hog, load generator.

### Serial

A serial is a number of a slot of a kernel table (a thread, a program, a memory object) that changes for each new object in the slot.

A slot serves many objects in time. A path that names a slot across a wait for a lock keeps the serial and checks it after the wait: the slot can hold another object then. The kernel events and the reports give the serial of a program with its slot, so a reader does not mix two programs of one slot. The generation of a handle is the same idea for the handles of one program.

The design: `docs/ARCHITECTURE.md`, "Rules that keep each path correct".

Do not use: generation (for handles only), epoch, version.

### Wait table

The wait table is the threads that wait on words, in buckets chosen by the physical address of the word, each bucket with its wait lock.

A thread registers each word of its wait in the bucket of the word, after it compared the value. A waker changes the word before it enters the kernel, so either the waker finds the entry, or the thread finds the new value.

The design: `docs/ARCHITECTURE.md`, "Rules that keep each path correct".

Do not use: futex hash table.

### Locker

A locker is a program that the program `locks` starts several times, to measure the locks of the kernel.

A locker works only on its own objects, so it waits for another locker only when the kernel makes it wait. The lock counts of the kernel then count what the lockers do.

Do not use: load generator, stress worker.

### Frame cache

The frame cache is the stack of at most 256 free page frames of one processor, in its processor record, with its cache lock.

A page on first use takes its frame from the frame cache of its processor, under the cache lock only. The end of a memory object puts its frames there. The stack takes and gives frames to the frame table by batches of 128, under the frame lock. So most first uses do not take the frame lock that all processors share.

The design: `docs/ARCHITECTURE.md`, "Rules that keep each path correct".

Do not use: per-CPU page list, magazine, pcp list.

### Cache lock

The cache lock is the lock of the frame cache of one processor.

Its processor takes it at each take and each put; another processor takes it only to read or empty the stack. It comes after the frame lock in the lock order.

Do not use: per-CPU lock.

### Lock count

A lock count is what the kernel counts for one kind of lock, on all the processors: the times that a processor took it, and the times that it had to wait for it (`Lock_Count` in the system report).

The program `locks` reads the counts, so a measure shows which lock the work waits for.

Do not use: lock statistics, contention counter.

### Thread area

A thread area is the memory that the kernel makes for one thread in its program: the thread record, the kernel ring of the thread, and one page with no memory.

The areas are at fixed addresses from `THREAD_AREA_BASE`, 4 pages each. The budget pays for each area with the thread. A page fault in a thread area is never given to a fault handler.

### Kernel event

A kernel event is a fact of the kernel that the kernel writes as an event record when a rule of the event table accepts it: one kernel operation with its duration, a switch of threads, a fault of a program, or a wait for a lock of the kernel.

Kernel events let a program see the work of the kernel as it happens, with no code of the program in the kernel. A rule is data, not code: the kernel compares fixed fields, so the cost of a rule has a bound. With no rule, an event point costs one branch. The records go into one event ring for each processor, and the program reads them with no kernel entry.

A program needs the right Events on the machine, because the records show the order and the duration of the work of other programs: a precise clock over them. Today the root service gives it only to `kernel_events`.

The design: `docs/ARCHITECTURE.md`, "Kernel events".

Do not use: tracepoint, probe, perf event, eBPF program.

### Event point

An event point is a fixed place in the code of the kernel where a kernel event can be recorded.

The kernel has four: each command of a kernel entry, the switch of threads, a fault of a program, and a lock taken after a wait. With no rule of its kind, an event point costs one load of the observed kinds and one branch. An event point never faults, takes no lock, never waits and uses no address of a program.

Do not use: hook, probe, tracepoint, instrumentation point.

### Observed kinds

The observed kinds are a word of the processor record: the set of the kinds of kernel events that have a rule in the event table now.

An event point reads it first. It is 0 when no event table exists. The kernel changes it only under the control lock, and synchronizes the other processors before it frees an old table.

Do not use: trace mask, enabled events.

### Event rule

An event rule is one record of the event table (`op.Event_Rule`, 64 bytes): a kind of kernel event, a program or every program, a detail to match, a least duration, and "one in N".

The kernel applies the rule; it is data, not code. A rule that names a program needs a program handle with Read; a rule for every program needs only the right Events. "One in N" is a count, not a random choice.

Do not use: filter, predicate, eBPF program.

### Event table

The event table is the rules (at most 16) that one program with the right Events gave to the kernel with `Events_Set`, with the memory object of its event rings.

The machine has one event table at most. The program that gave it owns it: the table ends when that program ends, when it gives the memory 0, or when its last machine handle with Events closes or is revoked. So a revocation takes back what the right gave.

Do not use: trace session, perf session, ftrace instance.

### Event ring

An event ring is the part of the memory object of the event table that belongs to one processor: a head that the kernel writes, a word that the program writes, and the event records.

Only the kernel of that processor writes its records, so it takes no lock. The kernel indexes with its own counts and reads only the word `read` of the program: a false word loses records of that program and nothing else. A full ring drops the record and adds 1 to the lost count.

Do not use: trace buffer, perf ring buffer, per-CPU buffer.

### Event record

An event record is one record of an event ring (`op.Event_Record`, 64 bytes): the cycle counter, the kind, the processor, the program and its serial, the thread, a detail and two values.

For an operation the detail is the operation number and the first value its duration in cycles. For a fault the address of a page fault is given only to a rule that names the program.

Do not use: trace record, sample.

### Lost count

The lost count is the count of the records of one event ring that the kernel did not write because the ring was full.

The kernel never waits for a place and never writes over a record that the program did not read: a full ring loses the record, and the count says so.

Do not use: dropped events, overrun count.

### Performance counter

A performance counter is a register of the processor that counts cycles or retired instructions.

The kernel detects the counters at boot and writes one line of the log. It programs none yet: an event record carries the cycle counter only.

Do not use: PMC, PMU counter.

### Service

A service is a program that other programs call through rings, and that has no privilege of its own.

A service is not part of the kernel and is not trusted more than another program: it has the handles that the root service gave it. A caller reaches a service through a connection that the root service makes. A service acts only on the handles that the caller sends with the request, never on its own access in the name of the caller. Examples: the storage service, the network service, the manual, the monitor, the compositor.

The design: `docs/ARCHITECTURE.md`, "The whole system".

Do not use: daemon, server, driver.

### Device service

A device service is a service that owns the queues of one device class: block, network card, display, input.

The kernel contains no device code. It maps the registers and the queues of a device into one device service, and turns each interrupt into an event. The service translates between the protocol of the device and the ring of its class; for virtio this translation is thin.

The design: `docs/ARCHITECTURE.md`, "Device services", and `docs/PROPERTIES.md`, "No drivers in the kernel, and fixed hardware first".

Do not use: driver.

### Input service

The input service is the device service of the keyboard and the mouse.

It reads the virtio input devices and sends key and pointer events to the compositor, which gives them to the window that has the focus.

Do not use: input driver.

### Root service

The root service is the first program: the kernel gives it every handle that exists at boot, and it gives them out.

The root service is the only program that creates access from nothing: every other handle came from it, directly or through a chain. It checks the boot image against the system description, starts the services and gives each one only the handles that it needs, holds the replacement table, the grant records and the records of the principals, and makes the connections between callers and services. A program asks it for a start or a connection through its root ring; the console has `start`, `stop`, `connect`, `grants` and `revoke`.

The root service has no privilege in the kernel: its power is the handles that it holds.

The design: `docs/ARCHITECTURE.md`, "Root service".

Do not use: init, PID 1, system manager.

### Context

The context is the one typed record that a program receives when it starts: 16 handles and 24 values of 64 bits (`op.Context`).

The context replaces `argv`, the environment and inherited files. The address of the context is the parameter of the entry. The index of each handle is its role, which the starter fixes; the system fixes the roles of the log handle and of some values (the seed of the program, the mapped ranges). It holds no text: a program has nothing to parse. A program that starts with an all-zero context has no handle: it can compute and stop, and reach nothing.

Example: a call host receives its call ring at role 0 and its call region at role 1.

The design: `docs/MODULE_CONTRACT.md`, "The context", and `docs/PROPERTIES.md`, "A command is a function: no text between programs".

Do not use: argv, argc, environment, arguments.

### Kernel

The kernel is the code that runs with processor privilege: it isolates the programs, schedules the processors, owns the handle tables and grants access to memory and devices.

The kernel has five systems: the handle table, memory, the scheduler, rings and wait, and the device grant. It has no file system, no network protocol, no device driver, no loader and no names. It is a module, which the boot program checks against the system description and loads. Its interface is a short list of kernel operations, counted in `docs/PROPERTIES.md`.

The kernel is the control plane: it checks a right once and maps memory, and data then moves between programs with no kernel entry.

The design: `docs/ARCHITECTURE.md`, "Kernel systems", and `docs/PROPERTIES.md`, "Small kernel with a small, counted interface".

Do not use: core, supervisor.

### Kernel operation

A kernel operation is one request that a program makes to the kernel: a command record in the kernel ring of its thread.

The kernel has 33 operations (`op.Operation`), a counted limit that only a change of `docs/PROPERTIES.md` changes. A thread writes up to 32 commands in its kernel ring, then enters the kernel once with `syscall`; the kernel runs them in order and writes one completion record for each: a status, and the results or an error record. The entry can also wait until a wake or a time.

A kernel operation needs a handle for each object that it acts on: no operation works without one.

The design: `docs/ARCHITECTURE.md`, "Rings and wait", and `docs/PROPERTIES.md`, "Small kernel with a small, counted interface".

Do not use: system call, syscall.

### Boot program

The boot program is the UEFI program that checks, measures and loads the system, then starts the kernel.

It holds the kernel module, the boot image and the public key of the publisher of the system. It verifies the signature of the system description, compares each module and resource with it, asks the firmware to measure the description into the TPM, loads the kernel module, and gives the kernel the memory map, the framebuffer and the trust record in one record. A failed check stops the boot with the file and the two hashes on the screen.

The design: `docs/ARCHITECTURE.md`, "Boot program", and `docs/PROPERTIES.md`, "Trusted boot: UEFI program, Secure Boot, TPM".

Do not use: boot loader, bootloader.

### Fixed range

A fixed range is an address and a span of the address space of a program where the system places one mapping that it gives: the settings page, a glyph cache, the date page, the files of a module.

Each fixed range is one member of the enumeration `Fixed_Range` of `contract/fixed_addresses`, one slot of 1 TiB of the band from `BAND_START`. So no two ranges overlap, and the compiler checks that the band holds every member. A mapping that a program places by its own choice is outside the band, from `OWN_CHOICE_START`. `kerneltool check` refuses an address of the band written another way.

Do not use: well-known address, fixed mapping.

### Mapped ranges

The mapped ranges are the fixed ranges that the starter of a program mapped for it: a set of bits, bit n for the member n of `Fixed_Range`, in the value 20 of its context.

A program reads nothing at a range whose bit is clear (`fixed_addresses.ranges_mapped`).

Do not use: mapping flags, present mask.

## Access

### Handle

A handle is a number that a program holds to name one kernel object with a set of rights: a program can act only on the objects of its handles.

A handle removes ambient authority. In Unix a program reaches resources by global names (a path, a process number, a port), and the kernel checks who runs the program: each program of a user can open each file of that user. Here no global name exists. A kernel operation names each object that it acts on by a handle, and the kernel checks two things: the kind of the object, and the rights of the handle. A wrong handle gives `Bad_Handle`; a missing right gives `No_Right`.

A handle is 32 bits: the low 16 bits are the index of a slot in the handle table of the program (1 to 127), and the high 16 bits are the generation of that slot. The slot holds the kind of the object, its index in the table of the kernel, and the rights. Handle 0 names no object: an operation on it fails in a defined way and does no damage. The kinds are Memory, Program, Thread, Budget, Interrupt, Ports, Machine and Log.

A program gets a handle in three ways: in its context at its start, from its starter; as the result of an operation that makes an object (`Memory_Create` gives a memory handle with each right of its kind); or from another program, with `Handle_Give`, which copies a handle with a part of its rights and never adds one. A program that receives a handle number in a ring proves with `Handle_State` that the other side gave it through that ring.

A handle ends with `Handle_Close`, or with a revocation of a handle that it came from. The slot then takes the next generation: the old number names nothing, and an error record says "was closed" or "was revoked".

A handle is not a file descriptor: no child inherits it, it carries rights, and each kind has its own operations, with no `read` and `write` for everything. It is the "capability" of the research systems; the system uses one word for it. Example of an error record: "Memory_Map: the argument memory, handle 0x30004, has the rights Give Read; the operation needs Read Write": the slot 4, the generation 3.

The design: `docs/ARCHITECTURE.md`, "Handle table", and `docs/PROPERTIES.md`, "Sandbox by default".

Do not use: file descriptor, capability, token, reference.

### Memory object

A memory object is a set of pages that the kernel names by a handle; programs map it, and two programs that map the same one share its pages.

A memory object is the one form of memory in the system: the memory of a program, a ring, a call region, a framebuffer, the registers of a device. `Memory_Create` makes one: a budget pays for each page at once, and each page gets its page frame at its first use, or at once with the flag `Frames_Now`. So an access never fails for lack of memory. Its pages are zero. `Memory_Map` maps it into a program with the rights of the handle: Read, Write, Execute.

A memory object lives while a handle or a mapping names it. Its pages return to the budget that paid when the last one ends. It has at most 1 GiB of pages. The flags `Uncommitted`, `Large_Pages` and `Contiguous` give the other forms.

A memory object is not anonymous memory of one process: it has no owner but its handles, and it moves between programs by `Handle_Give`.

The design: `docs/ARCHITECTURE.md`, "Memory", and `docs/ARCHITECTURE.md`, "The virtual memory of a program".

Do not use: region, shared memory segment, buffer.

### Page on first use

A page on first use is a page of a memory object that gets its page frame at its first read or write, from a program (a page fault) or from the kernel.

The frame is all zero. The budget paid for the page when the memory object was created, so the kernel keeps a free frame for it at all times: the first use never fails. A page that nobody touches costs no frame and no zeroing. A kernel event `Fault` with the outcome "first use" records it.

Do not use: lazy allocation, demand paging, demand-zero page.

### Uncommitted object

An uncommitted object is a memory object made with the flag `Uncommitted`: its budget pays only its frame list, and each page is paid when it is committed.

An uncommitted object reserves a range of addresses with no memory behind it: its mapping is the reservation. A program commits the pages that it needs with `Memory_Commit`, and gives them back with a decommit. An access to a page that is not committed is a fault: with no fault handler it stops the program with `STOP_CODE_NOT_COMMITTED`; with one, the handler can commit the page and answer Resume. A program builds arenas, stacks that grow and sparse tables this way.

The design: `docs/ARCHITECTURE.md`, "The virtual memory of a program".

Do not use: reserved object, reservation, VirtualAlloc(MEM_RESERVE), mmap(PROT_NONE).

### Committed page

A committed page is a page of a memory object that its budget paid for: it gets a frame at its first use.

Each page of an object that is not uncommitted is committed. A page of an uncommitted object is committed after `Memory_Commit`; the kernel keeps it as one bit in the slot of the page.

The design: `docs/ARCHITECTURE.md`, "The state of a page".

Do not use: committed memory.

### Decommit

A decommit is the act of `Memory_Commit` with the flag `Decommit`: the pages of an uncommitted object are no longer paid.

Their frames and their pages return to the budget of the object at once; the addresses stay reserved, and a page committed again is zero. A decommit needs an object that only this program names, with one mapping at most, so the shoot-down is the one of this program.

The design: `docs/ARCHITECTURE.md`, "Commit and decommit".

Do not use: madvise(DONTNEED), VirtualFree(MEM_DECOMMIT), discard.

### Page protection

A page protection is what a page of a mapping lets a program do: read, read and write, read and execute, or nothing (`No_Access`).

`Memory_Map` sets the protection of a whole mapping from the rights of the handle. `Memory_Protect` changes it for ranges of pages, and can only take away what the mapping has: write and execute together are refused. A guard page, a read-only table after its build, and a collector that traps writes use it.

The design: `docs/ARCHITECTURE.md`, "Protection and the shoot-down".

Do not use: mprotect, page rights.

### Held entry

A held entry is an entry of a page table of a program that a mapping covers: a page of the mapping, present or not, a large page, or an entry that names a table with held entries.

A table with no held entry is freed, and its page returns to the budget that paid for it. So a program that maps and unmaps memory does not keep page tables that no budget sees.

The design: `docs/ARCHITECTURE.md`, "The page tables of a program".

Do not use: used entry, reference of a table.

### Shoot-down

A shoot-down is the step where each other processor that uses the page table of a program forgets its old translations, after the kernel cleared or reduced entries.

The kernel sends `processor_sync` to each processor whose page table is the one of the program; each one reloads its page table at its next kernel entry, its idle wait or its wait for a lock. The operation returns after each of them did, so no thread uses an old entry afterwards. A table of ranges in one command makes one shoot-down for all its ranges.

Do not use: TLB flush, TLB shootdown (for this).

### Large page

A large page is a page of 2 MiB: one entry of the second level of a page table.

Only an object made with `Large_Pages` uses them: it is contiguous, aligned on 2 MiB, and a whole number of large pages. A mapping uses a large page for each 2 MiB that is aligned in it. One entry then covers 512 pages, so random reads over a large object miss the translation cache less.

The design: `docs/ARCHITECTURE.md`, "Large pages".

Do not use: huge page, superpage.

### Fault kind

A fault kind is a processor exception that the kernel can give to a fault handler, named by its vector (`op.Fault_Kind`).

The kinds are divide error, debug, breakpoint, invalid opcode, segment not present, stack fault, general protection, page fault, x87 floating point, alignment check and SIMD floating point. A handler asks for a set of them (`op.Fault_Kinds`); 0 is page faults only. The non-maskable interrupt, the double fault and the machine check are never given: they are not faults of an instruction of a thread.

The design: `docs/ARCHITECTURE.md`, "The fault ring".

Do not use: signal number, exception code, trap number.

### Fault class

A fault class says where a thread continues after a fault kind: a fault did not run its instruction, which runs again; a trap ran it, and the thread continues at the next one.

Debug and breakpoint are traps; the other fault kinds are faults. The class decides the rule of Resume: a trap and a page fault resume by themselves, and another fault resumes only after thread control wrote the registers or the extended state of the thread: without that write, the same instruction faults again with no end.

Do not use: exception class, exception type, abort (for this).

### Fault handler

A fault handler is the thread of a program that `Fault_Handler_Set` named, with the fault kinds that it takes: the faults of these kinds of the other threads of the program become records in its thread record.

A fault handler lets a program decide what a fault means: a guard page, a stack that grows, memory committed at the first touch, the barrier of a collector, a breakpoint of a debugger. The kernel holds no policy. A program has one handler at most. The fault of the handler itself stops the program, and so does a fault of a kind that the handler did not ask for.

A fault handler is not a signal handler: no code of the program runs in the middle of the thread that faulted. That thread waits; another thread reads a record and answers with an operation.

The design: `docs/ARCHITECTURE.md`, "The fault ring".

Do not use: signal handler, exception handler, pager (for this).

### Fault ring

The fault ring is the records of the faults of a program that the kernel gives to its fault handler, in place of a stop: a part of the thread record of the handler.

When a thread faults, the kernel writes a fault record, adds 1 to `fault_written`, and wakes the threads that wait on that word; the faulting thread waits, as a held thread. A thread of the program repairs (with `Memory_Commit`, `Memory_Protect` or thread control) and answers with `Fault_Answer`: Resume or Stop. The ring has 16 records; a fault that finds it full stops the program.

The ring needs no new memory: the budget paid for the thread record with the thread. If the ring ends while a thread waits (the handler ends or is replaced), the program stops with `STOP_CODE_FAULT_UNANSWERED`.

The design: `docs/ARCHITECTURE.md`, "The fault ring".

Do not use: signal, SIGSEGV handler, userfaultfd, exception port.

### Fault record

A fault record is one record of the fault ring (`op.Fault_Record`, 64 bytes): the number of the faulting thread, the serial of the fault, the address and the kind of access of a page fault, the address where the thread continues, the fault kind and the error code of the processor.

`Fault_Answer` names the thread number and the serial, so an answer for an earlier fault, or for an ended thread whose number serves again, is refused. The serial is a count of the program, so it shows nothing of other programs.

Do not use: siginfo, fault message.

### Thread control

Thread control is the operation `Thread_Control`: stop a thread, read and write its registers and its extended state, and resume it.

A debugger, a collector that reads the roots of each thread, a sampling profiler and the program that runs a guest need it. A program acts on its own threads by number. A thread of another program needs a thread handle with the right of the command: Inspect for each command, and Write too for a write, because a write lets its holder choose the code that the thread runs. Control, the right to end a thread, gives none of these.

A write is copied once, checked whole, and refused whole if one field is wrong: a thread never gets a frame that the processor refuses.

The design: `docs/ARCHITECTURE.md`, "The control of a thread".

Do not use: ptrace, debug API, SuspendThread, thread_suspend (for this).

### Stop count

The stop count of a thread is the count of the stops of thread control that hold it: each `Stop` adds 1, each `Resume` takes 1, and the thread runs only at 0.

Two holders that each stop a thread each resume it. The count does not change the wait of the thread: a thread in a word wait stays in it.

Do not use: suspend count, freeze.

### Held thread

A held thread is a thread whose stop count is above 0, or that waits for an answer of the fault ring, and that no processor runs.

Only a held thread has complete registers in the kernel: the frame of its last entry and its saved extended state. So thread control reads and writes the registers of a held thread only.

Do not use: stopped thread, suspended thread (for this).

### Register image

A register image is the general registers, the instruction address, the flags and the two selectors of a held thread (`op.Thread_Registers`, 176 bytes), as thread control reads and writes them.

A write that a thread of a program cannot hold changes nothing: a code selector of the kernel, an instruction address in the kernel half, flags of privilege. The error record names the refused field.

Do not use: register context, CONTEXT, user_regs_struct.

### Reserved page

A reserved page is a page that a budget paid for and that has no page frame yet.

The kernel keeps one free frame for each reserved page, so an access never fails for lack of memory, and the system never takes memory back from a program that paid.

Do not use: overcommit.

### Frame list

A frame list is the record of the page frames of one memory object: in the kernel record of the object for at most 4 pages, else in list pages that the budget pays for.

Each slot of the list is 8 bytes: the frame, and in its low bits the state of the page (committed, deny write, deny execute, no access). 0 is a page with no frame yet.

The design: `docs/ARCHITECTURE.md`, "The state of a page".

Do not use: page list, radix tree.

### Right

A right is one kind of operation that a handle permits on its object.

The rights are Give, Read, Write, Execute, Control, Inspect, Devices, Stop, Spend, Physical, Schedule, Commit and Events. Each one means something for each kind of object: Read on a memory object is a mapping that reads, Read on a program is the reading of its state, Control on a program starts and stops it. A new object has each right of its kind. `Handle_Give` copies a handle with a part of its rights; no operation adds a right.

Narrow rights let a program give exactly what another needs: Commit is the part of Spend that pays pages of an object, and Inspect on a thread holds and reads it without Write.

The list: `contract/operation/operation.odin`.

Do not use: permission, privilege, mode.

### Budget

A budget is an object that holds pages, program slots and thread slots, and has two limits in time: processor time and log records; it pays for each object that a program creates.

A budget makes every cost visible and bounded. No operation creates an object from nothing: `Memory_Create`, `Program_Create` and `Thread_Create` take a budget handle with the right Spend, and the budget pays. When an object ends, what it used returns to the budget that paid. A program moves a part of its budget to a new budget with `Budget_Create`, and gives that one to a child: the child can never use more.

The kernel gives one budget to the root service: all the free memory and all the slots. When the last handle to a budget closes, what it holds returns to the budget that it came from, which then pays for its objects. `Budget_Read` with the right Read gives what the budget can still pay and what it used.

A budget is not a quota on a user, and not a group of processes: it is a handle like each other, and a program divides it among its children.

The design: `contract/operation/operation.odin` (`Budget_Amounts`), and `docs/PROPERTIES.md`, "No ambient access: the other holes to close".

Do not use: quota, limit, cgroup, job.

### Limit

A limit is a property of a budget for time: the microseconds of processor time, or the log records, that the budget can use in each second.

Time does not return, so it does not move as pages do. A limit holds for the budget and for each budget that came from it: what a thread uses counts in its budget and in each budget above. A new budget has a limit that is not above the limit of the budget that it came from. With the limit 0 a budget has no time: its threads do not run.

Do not use: quota, cap, bandwidth, rate limit.

### Period

The period is the 100 ms in which the kernel applies the processor limit of a budget.

A thread of a budget that used its part of the period does not run until the next period.

Do not use: window, slice.

### Grant

A grant is the act that gives a handle to a program, and the record of that act.

A grant is the one way that access grows. The root service records each grant that it makes, by the name of the grant and the program, at the start of the program or at a connection. The console shows the grants of a program (`grants("notes")`) and revokes one (`revoke("kernel_events", "machine")`).

A grant is not a permission in a list that a check reads: once given, the handle is the access, and a revocation ends it.

The rules: `docs/PROPERTIES.md`, "No ambient access: the other holes to close".

Do not use: permission, authorization, consent.

### Guest

A guest is a machine that a program of the system runs on the processor, with its own kernel and its own programs; it is not built yet.

A guest holds only what its program was granted. A foreign system (Linux) runs in a guest, and its concepts stay inside it. Thread control gives the registers and the extended state that such a program needs.

The direction: `docs/PROPERTIES.md`, "Objective".

Do not use: virtual machine, VM, container.

### Driver domain

A driver domain is a guest that owns one device and serves it to the system; it is not built yet.

The device reaches only the memory of that guest, so a driver of another system can serve a device with no access to the rest.

Do not use: passthrough, driver VM.

### Holding

A holding is a handle or a mapping of a program: one thing that the program has of an object.

The kernel keeps the origin of each holding, so that a revocation reaches each handle and each mapping that came from a handle, in any program.

Do not use: reference, capability.

### Origin

The origin of a holding is the handle that it came from.

A handle that `Handle_Give` made came from the handle that was given. A mapping came from the memory handle that was mapped. A holding that the kernel made has no origin. When a handle closes, what came from it comes from its own origin, so the chain stays whole. The kernel keeps the origins in one table under the origin lock.

Do not use: parent, derivation, delegation chain.

### Revocation

A revocation is the act that ends each holding that came from a handle, in one program or in each program (`Handle_Revoke`).

A revocation makes a grant temporary: what a program gave, it can take back, through each chain of gifts. The handle that revokes stays. A program that lost a holding gets an event and cannot refuse; a thread that uses memory that its program lost stops its program on a page fault. Example: `revoke("kernel_events", "machine")` in the console ends the machine handle of `kernel_events`, and its event table ends with it.

A revocation ends holdings, not objects: an object that a program made with a budget handle lives on after the handle is revoked.

The design: `docs/ARCHITECTURE.md`, "Rules that keep each path correct".

Do not use: recall, invalidation.

### Lent handle

A lent handle is a handle that a caller gives to a callee for the time of one call.

The description of an export names the rights that it needs on each Handle parameter. The caller makes a copy of its handle with these rights only, gives the callee a handle that comes from the copy (`Handle_Give` through the call ring), and revokes the copy after the call (`system.lend`, `system.lend_end`). The callee proves the handle with `Handle_State` before it uses it. The caller keeps its own handle. A mapping that the export kept for later ends with the revocation, and its next use stops the program of the callee.

A table too large for the call region goes in a lent memory object, whose rights are the direction of the table.

The design: `docs/MODULE_CONTRACT.md`, "Records and handles, as implemented".

Do not use: borrowed handle, loan, passed capability, inherited descriptor.

### Ambient access

Ambient access is access that a program has because it runs, and not because it received a handle.

The system has none: a program with no handle can compute and stop, and reach nothing. Each new interface passes one test: "can a program with zero handles use it?" If yes, the interface is a defect.

The rule: `docs/PROPERTIES.md`, "No ambient access: the other holes to close".

Do not use: ambient authority.

### Sandbox

A sandbox is the state of every program: it can reach only the objects of its handles.

The sandbox is not a mode that a program enters: it is how each program starts, with the handles of its context only.

The rule: `docs/PROPERTIES.md`, "Sandbox by default".

Do not use: jail, container.

### Principal

A principal is a key pair and the root handles that the key unlocks: documents, grant records, settings.

A principal answers "for whom does this run" without users. The kernel does not know it: the answer to "who executes" is always a program with its handles. The root service holds one record for each principal and names it by its number, and records the principal of the session of each program that it starts. The storage service gives each principal its own stores.

Principal 0 is the machine: the programs of the system belong to it, and it is not an administrator: it does not see the stores of a named principal. A named principal (number 1 today) unlocks its session with a passphrase.

The design: `docs/PRINCIPALS.md`, "Principal 0: the machine", and `docs/PROPERTIES.md`, "Principals: who acts, without users".

Do not use: user, account, owner, root, administrator, executor, person, publisher.

### Named principal

A named principal is a principal with a number of 1 or more: a name for display, an Ed25519 key to sign grants, an X25519 key to unlock documents, and a passphrase.

The program `unlock` keeps its record in its own store; the two secret keys are sealed with ChaCha20-Poly1305 under a key that Argon2id derives from the passphrase. `principal_create("name")` in the console makes one.

The design: `docs/PRINCIPALS.md`, "A named principal".

Do not use: user account, login.

### Session

A session is the tree of programs that started from the root handles of one principal.

The root service records the principal of each program that it starts: 0 for the programs of the system, the named principal that is unlocked for a program that the desktop starts, the principal of the asking program for a program that a program starts. The log says it: "root: started notes, in the session of principal 1 "alice"". The principal of the session names the stores of the program.

The design: `docs/PRINCIPALS.md`, "The session".

Do not use: login, user session.

### Unlock

The unlock is the act that starts the session of a named principal: Argon2id derives a key from its passphrase, and that key opens the seal of its secret keys.

A wrong passphrase gives another key, and the seal does not open: no passphrase and no hash of a passphrase is kept or compared. After the unlock the program `unlock` erases the secret keys and tells the root service, which starts the session.

The design: `docs/PRINCIPALS.md`, "The unlock and the lock".

Do not use: login, sign in, authentication.

### Lock of a session

The lock of a session is the act that ends the session of a named principal: each program of the session stops, and an unlock is needed again (`lock()` in the console).

The programs stop; they are not frozen. A program that keeps its state in its store at each change loses nothing. The lock of a session is not a lock of memory.

Do not use: log out, sign out.

### Passphrase

A passphrase is the text that derives the key of the seal of a named principal: 8 to 128 printable bytes.

It is typed in the window of `unlock` only, shown as dots, and kept nowhere. It is never a text of the console, which keeps each line in its history.

The design: `docs/PRINCIPALS.md`, "The passphrase".

Do not use: password, PIN.

### Acts for the principal

Acts for the principal is a grant of the root service (`acts_for_principal`): in each service that the program is connected to, it sees what the service holds for all callers, for the principal of its session.

Without it, a caller of a service sees only its own data. The console and the remote service have it; `revoke("remote", "acts_for_principal")` ends it, and the next call is refused. The grant travels in bit 63 of the grant of each connection (`isolated.CALLER_ACTS_FOR_PRINCIPAL`).

The design: `docs/PRINCIPALS.md`, "The session".

Do not use: superuser, privileged, person.

### Input

Input is the keys and the pointer, as the system receives them.

A text that describes an act at the desktop names the input or the act ("Space is pressed"), not who acts: the system knows programs and principals, not people.

Do not use: user, person.

## Communication

### Ring

A ring is a pair of queues of fixed records in shared memory, between two programs or between a program and the kernel: one queue carries command records, the other carries completion records.

A ring is the one way that two programs communicate, and the base interface of the kernel. One side writes commands and reads completions; the other side does the opposite. Each queue has one writer and one reader, so no queue operation takes a lock or enters the kernel: the writer advances a counter, the reader advances another, and each counter is in its own cache line. Data does not pass through the kernel. A side that must wait (an empty queue, a full queue) waits on the counter with the word wait, and the other side enters the kernel to wake it only when a flag says that it waits.

A ring is one memory object: page 0 holds the counters, then come the command records, then the completion records (`contract/ring`). A record is 64 bytes: a kind, a tag and seven values. All-zero memory is an empty ring. A side never trusts the numbers of the other side: it computes the capacity from the size that the kernel gives, and a place is a count modulo the capacity.

A program gets a ring from the program that made it, as a memory handle; the root service makes the rings between a program and a service. Examples: the kernel ring of each thread, the call ring of a call host, the terminal ring, the block ring of the disk service.

A ring is not a pipe or a socket: it carries typed records, not a stream of bytes, and the receiver of a record checks it as hostile data, because the sender can change shared memory at any time.

The design: `docs/ARCHITECTURE.md`, "Rings and wait", and `docs/PROPERTIES.md`, "Base interface: non-blocking command buffers".

Do not use: pipe, socket, channel, port, message queue.

### Capacity

The capacity of a ring is the count of records of each of its queues: a power of two, fixed when the ring is created.

The capacity comes from the size of the memory of the ring: a ring of 1 + capacity / 32 pages, from 32 to 65536 records. It is not written in the shared memory, so the other side cannot lie about it. Choose it for the largest burst of the writer: a full queue slows the writer to the speed of the reader.

Do not use: buffer size, queue depth, backlog.

### Terminal

A terminal is a program that shows the text records of one other program, keeps its lines, and gives its keys to that program.

The root service starts a program and its terminal, and gives the two a terminal ring and a text region. The terminal holds a surface, these two memory objects, and a handle that reads the state of the program; it starts no program. The terminal reads records as fast as the program writes them and draws at the rate of the screen, so the display does not slow the program. The kernel has no concept of a terminal.

A terminal is not a TTY: no escape sequence and no line discipline exist. The program edits its own line and sends records with a kind and typed fields.

The contract: `support/terminal/terminal.odin`.

Do not use: TTY, pty, terminal emulator, standard output, standard input.

### Shared queue

A shared queue is one queue of records in shared memory that several threads write and several threads read, with no lock.

Each record has a turn word that says whose turn it is on it. A writer takes a count with one compare-and-exchange, writes the record, then changes the turn word; a reader does the same. So two writers never have the same count, and a reader never reads a record before its writer completed it. Use a shared queue when several threads take work from one place; use a ring for one writer and one reader.

The contract: `contract/ring/shared.odin`.

Do not use: MPMC queue, channel, work queue, mailbox.

### Event

An event is a count in memory that several threads wait on (`system.Event`): a thread adds 1 to it and wakes all the threads that wait.

A waiter reads the count, reads the state that the event changes, then waits while the count holds the value that it read: an event between the read and the wait ends the wait at once. The zero value is an event that never happened. An event in shared memory works between programs.

Do not use: condition variable, semaphore, signal, barrier.

### Source library

A source library is a named folder of source packages that a module compiles in.

An import of the source names the library and the package: `contract:ring`. The project has two: `contract` (what two parties agree on, with no kernel operation) and `support` (what a program compiles in to use the contracts). A source library is not a module: it has no file and no hash of its own, and it is not an edge of the module graph.

Do not use: collection, SDK, libc, static library.

### Documentation

The documentation of a module is the text that the module carries in its file for a reader: one line that says what the module is, a text for the module, and a text for each export.

The build tool takes it from the comments of the source. It is part of the file, so it has the hash of the module: a text cannot describe another version of the code. With the description of each export, it is all that a reader needs to use the module: `help()` in the console and the pages of the site show it.

The design: `docs/MODULE_CONTRACT.md`, "The module file".

Do not use: man page, help file, docstring, README.

### Time page

The time page is one page that the kernel writes and that each program can only read, at a fixed address (`TIME_ADDRESS`).

It holds the milliseconds since boot, the frequency of the cycle counter and the cycle counter at the time 0. A program reads the time with one load from memory, with no kernel entry; a finer time comes from the cycle counter.

Do not use: vDSO, vsyscall, clock system call.

### Real-time clock

The real-time clock is the clock of the machine that keeps the date when the machine is off.

On a PC it is the CMOS clock, at the ports 0x70 and 0x71. The program `date` reads it at its start and each 10 s, and writes the date page.

Do not use: RTC (in text), hardware clock, BIOS clock.

### Date

A date is a count of milliseconds since 1970-01-01 00:00:00 UTC.

Leap seconds are not counted: a day has 86400 seconds.

Do not use: timestamp, wall clock, epoch time, Unix time (in text).

### Date page

The date page is one page that the root service creates and maps read-only into each program that it starts, at its fixed range.

The program `date` writes there the date of the time 0 of the system. So a program reads the date with no kernel entry: that date plus the milliseconds of the time page.

Do not use: wall-clock page, vDSO, clock page.

### Terminal ring

The terminal ring is the ring between a program and its terminal.

In the command queue, a record from the program has a kind (text, status, clear, edit line, hint line, completion list, runs of code), a count of bytes in the text region and a style; it has no place on the screen. In the completion queue, a record from the terminal is a key record. When the queue of keys is full, the newest keys are lost: the terminal never waits for a program.

The contract: `support/terminal/terminal.odin`.

Do not use: escape sequence, control character, stream.

### Key record

A key record is a record from a terminal to its program: the code of one key that was pressed, its character, and the modifiers that were held (Shift, Control).

The program decides what a key does. The terminal keeps Page Up and Page Down for its own view.

Do not use: standard input, character device, raw mode, cooked mode.

### Edit line

The edit line is the one line that a program changes: its line of input with a cursor, or a line that says what the program does now.

The program sends the text and the place of the cursor; the terminal draws it after the last line. The program owns the editing, so the terminal needs no knowledge of a line of input.

Do not use: line discipline, readline, cursor addressing, prompt.

### Line editor

The line editor is the procedures of `support/line_editor` that change an edit line with keys: the caret, a character at the caret, Backspace, Delete.

They have no state of their own: the line is a record of the program.

Do not use: readline, line discipline.

### Hint line

A hint line is one dim line that a program shows under its edit line: the signature of the call at the caret, or how to use the list that is open.

It has a long form and a short form; the terminal shows the long one when it fits in its columns. The terminal draws it in the free row. A new one replaces the one before.

The design: `docs/CONSOLE.md`, "Who draws the list, and the line under the edit line".

Do not use: tooltip, status (for this), echo area.

### Free row

The free row is the row of the view of a terminal under the edit line, which the terminal keeps free at all times.

The hint line is drawn in it, so the text does not move when a hint comes or goes.

Do not use: spacer, padding line.

### Completion list

A completion list is the names that can take the place of the name at the caret, best first, with one chosen row.

The program gives the rows, at most 8 at a time; its terminal draws them over its text, at the edit line. In the console the fuzzy match orders the names.

The design: `docs/CONSOLE.md`, "Who draws the list, and the line under the edit line".

Do not use: dropdown, popup, autocomplete menu, suggestions.

### Chosen row

The chosen row is the one line of a list, a menu or a completion list that Enter or a press takes.

It is drawn in the chosen blue `COLOR_CHOSEN` with its text in white, on every display of the system.

The rules: `docs/DESIGN.md`, "The chosen row".

Do not use: selection (for this), highlight, focused item.

### Fuzzy match

A fuzzy match is a match where the characters of a query appear in a name in their order, with gaps allowed, lower and upper case equal.

A score orders the names that match: a match at the first byte of the name, after `.` or `_`, or right after the match before scores more, and a gap scores less. Example: `stwr` matches `storage.write`.

The design: `docs/CONSOLE.md`, "The fuzzy match".

Do not use: fuzzy search, subsequence search, filter (for this).

### Line history

The line history is the lines that were entered in the console, in a ring of bytes in its memory, the newest first.

The console keeps it in its store, so it survives a stop of the console.

The design: `docs/CONSOLE.md`, "The line history across a stop".

Do not use: history (alone), scrollback, command log.

### Line history file

The line history file is the line history as bytes, kept in the history store: a version, the lines, and a BLAKE3 hash (`support/line_editor/history_file.odin`).

A file that fails a check gives an empty history: a damaged file never stops the console.

Do not use: history dump, .bash_history.

### History search

The history search is the completion list over the line history: Control-R opens it, and the fuzzy match orders the lines.

The age of a line is its tie order: for equal scores the newest line comes first. Enter puts the chosen line in the edit line, where it can be changed before it runs.

The design: `docs/CONSOLE.md`, "The keys".

Do not use: reverse-i-search, incremental search.

### Text region

The text region is the shared memory beside a terminal ring where the program writes the bytes of its text, in order (4 MiB).

A record gives only a count of bytes: the terminal keeps its own place, so a program cannot make the terminal read another place. The terminal has the right Read only on it.

Do not use: scrollback (for this), pipe buffer.

### Run

A run of text is a set of bytes of text that have one style: a line is a list of runs.

One text record of the terminal ring is one run, of 256 bytes at most. The record with the flag End_Line ends the line.

Do not use: span, segment, chunk.

### Style

A style says what a run of text is and how to show it (8 bytes): a tone, flags (end of the line, own color, reverse), a code kind and a color.

The zero style is plain text. The color of a run is its own color with the flag Color; else the color of its code kind, when it has one; else the color of its tone.

Do not use: attribute, SGR, escape code.

### Tone

A tone is what a run of text means: default, dim, strong, good, warning, bad, accent or number.

The program gives the meaning; the terminal chooses the color of each tone, so one table changes the colors of every program.

Do not use: color code, severity (for text).

### Token

A token is the smallest part of a line of the console: a name, a number, a text, an operator, the arrow `->`, or one byte of no other token.

One scanner (`support/console_language`) gives them to the parser of the console and to its colors, so the colors never disagree with the parser.

Do not use: lexeme, word (for this).

### Code kind

A code kind is what a part of a line of the console or of a row of its list is: a function, a module, a type, a parameter, a variable, a number, a text, an unfinished text, an operator, the arrow, words that are not code, or unknown.

A program sends kinds, not colors; the terminal maps each kind to a code class (`support/terminal/code_runs.odin`).

The design: `docs/CONSOLE.md`, "The colors of the code".

Do not use: token type, syntax class, highlight group.

### Code class

A code class is one of the seven classes of the colors of code: keyword, type, literal, name, directive, comment and punctuation.

One table gives each class its color, for the site and for the terminal, so code has the same colors everywhere.

The rules: `docs/DESIGN.md`, "The colors of code".

Do not use: theme color, scope, highlight group.

### Run of code

A run of code is a part of one row with one code kind: a start, a length and the kind (4 bytes).

A row has at most 64 runs. A run gives a color, never text: a run that is refused, or a row with too many runs, leaves the text whole and plain.

Do not use: span (for this), highlight range.

### Status

A status is one line that a program replaces at any time, with a value and a total.

The terminal shows it apart from the lines: no line is drawn again. A program shows its progress this way, with no carriage return in a stream.

Do not use: progress bar hack, carriage return.

### Direct call

A direct call is a call of an export of a module that is in the address space of the caller.

The arguments are in registers, by the call form: up to 6 integers and 8 floats; a record, a text or a table goes as the address of memory of the caller. A direct call costs what a call of a function costs: a call through a slot of an import took 3.5 ns. The callee runs with all the access of the caller, so a direct call is for a module that the caller trusts.

The design: `docs/MODULE_CONTRACT.md`, "The call form".

Do not use: in-process call, local call.

### Isolated call

An isolated call is a call of an export of a module that runs in another program: the arguments travel in a ring.

An isolated call lets a program call a module that it does not trust. The module runs in a call host, or in a service, with no handle but those that the call lends. The caller writes the argument record in the call region and a command record in the call ring; the receiver copies the record once, checks every offset, count and handle, and calls the export; the results come back in the completion record. The same description serves the direct call and the isolated call: the source of the export does not change.

A fault of the module stops the call host only, and the caller reads its stop report. An isolated call costs a wake of the other program and its answer: 3 to 12 us in the measures of the program `tables`.

The design: `docs/MODULE_CONTRACT.md`, "The isolated call, as implemented", and `docs/PROPERTIES.md`, "A command is a function: no text between programs".

Do not use: remote call, RPC, IPC call.

### Record description

A record description is the part of the description of a module that gives the name, the size and the fields of one record that an export receives or gives.

A field is an Integer (1, 2, 4 or 8 bytes), a Handle (4 bytes, with the rights that the export needs), or a Text of a fixed size. A record has 256 bytes at most and holds values only, never an address. Two record descriptions that are equal name the same record, in one module or in two: the check of a replacement and the console compare them field by field.

The design: `docs/MODULE_CONTRACT.md`, "Records and handles, as implemented".

Do not use: struct type, schema, class.

### Call host

A call host is the program that loads one module and executes the isolated calls of its exports (`programs/host`).

The caller starts one call host for each module. The call host has no handle but its call ring, its call region, its budget and the log. It checks the file of the module, loads it, and answers a first completion: Ok, or `Load_Failed` with its load error. A call has no time limit: the caller ends it by closing the program handle, and the next call starts a new call host. Example: `isolate("sample")` in the console.

The design: `docs/MODULE_CONTRACT.md`, "The isolated call, as implemented".

Do not use: worker, helper process, server.

### Call ring

A call ring is the ring between a caller and a call host or a service: one command record is one isolated call.

The kind of the command is the index of the export, its first value the offset of the argument record in the call region. A lent handle travels through it, so the receiver can prove that the handle came from the caller.

Do not use: channel, pipe.

### Call region

A call region is the memory object that a caller and a call host or a service share: the caller writes the argument record and the bytes of its texts and tables in it.

A record result, a Table result and the error record come back in it. Each side treats it as hostile memory: the receiver copies the argument record once before it checks it.

Do not use: shared buffer, arena.

### Connection

A connection is one call ring and one call region between one caller and one service that serves its own exports.

The root service makes it and ends it, and gives the service the grant of the caller with it: the principal of its session, an amount, and whether it acts for the principal. Example: "root: connected console to the service storage, acting for principal 0".

Do not use: session, socket, channel.

### Service ring

A service ring is the ring between the root service and a service that serves its own exports.

One command record names one connection that starts or ends, with the grant of the caller. A service has no other way to receive a caller: it cannot be reached by a name.

Do not use: control channel, accept queue.

### Argument record

An argument record is the record that holds the arguments of one isolated call: one field for each parameter, in order.

It is derived from the description of the export: an Integer is 8 bytes, a Text is `{offset, count}` in the call region, a table is 32 bytes. Nobody writes a second encoding.

The design: `docs/MODULE_CONTRACT.md`, "The isolated call, as implemented".

Do not use: message, payload, marshalled arguments.

### Kernel ring

A kernel ring is the ring between one thread and the kernel: each kernel operation is a command record in it.

Each thread has its own kernel ring, one page after its thread record, with 32 places. A thread writes several commands, then enters the kernel once with `syscall`; the kernel runs them in order and writes one completion record for each. So a batch of operations costs one entry.

The design: `docs/ARCHITECTURE.md`, "Rings and wait".

Do not use: system call table.

### Record

A record is a block of bytes of a fixed layout with typed fields, in which all-zero bytes are a valid value.

All data between programs, and between a program and the kernel, is records: a ring record, a context, an error record, a row of a table. A record holds no address that the other side must follow, and no text that it must parse. A new field at the end is zero for an old writer.

The rule: `docs/PROPERTIES.md`, "Zero is initialization (ZII)".

Do not use: struct, message, packet, object.

### Command record

A command record is a record that asks the other side of a ring for one operation.

Its kind names the operation, its tag lets the caller match the completion, and its seven values are the arguments.

Do not use: request, message, call.

### Completion record

A completion record is a record that reports the result of one command record.

Its kind is a status (0 is success) and its tag is the tag of the command. When the status is not 0, its seven values are an error record; else they are the results.

Do not use: response, reply, event.

### Device queue

A device queue is the queue that a device defines for its own commands, such as a virtio queue.

The kernel maps it into one program, and is then off the path of the data: the program and the device exchange records with no kernel entry.

The rule: `docs/PROPERTIES.md`, "Kernel off the data path".

Do not use: ring (reserved for program-to-program).

### Zero is initialization (ZII)

Zero is initialization is the rule that all-zero bytes are a valid value with a defined meaning, for every record of the system.

Memory from the kernel is zero, so it is already initialized. Handle 0 names no object, index 0 of each table is empty, a zero field of a command means "default", and a zero error record means "no error". A new field at the end of a record is zero for old writers, so records grow with no version number.

The rule: `docs/PROPERTIES.md`, "Zero is initialization (ZII)".

Do not use: default constructor.

## Devices

### Physical address

A physical address is the number that the memory and the devices use for a byte of memory, before the page tables translate anything.

A program sees only virtual addresses: the page tables of its program translate each one to a physical address, and the program never learns the result. A device sees only physical addresses: it reads and writes memory by itself (direct memory access), with no page table of a program between. So a device service must know the physical address of the memory that it gives to its device, and nothing else in the system needs one.

A device service gets a physical address with the kernel operation `Memory_Physical`. It needs the machine handle with the right **Physical**, which the root service gives to each device service and to no other program. The memory object must have pages that follow each other in physical memory and do not move: an object made with the flag `Contiguous` or `Large_Pages`, or device memory. An object whose pages get their frames at their first use gives `Bad_Operation`: its pages are anywhere, and a page can still have no frame. Example: the block service gives the device the physical address of the data region of its client, plus the place that a request names.

A physical address is not a handle and gives no access to a program: a program that knows one cannot map it. The kernel does not yet program the IOMMU, so a device can today reach any physical address; the device services are trusted for that reason only.

The design: `docs/ARCHITECTURE.md`, "K5. Device grant and interrupts".

Do not use: real address, bus address.

### Device memory

Device memory is a memory object over the registers of a device, at physical addresses that are not memory of the kernel, and mapped with no cache.

A device service drives its device by reads and writes of its registers. Device memory gives it these registers as an ordinary memory object, with a handle and the rights of a handle, so a device service needs no special access and can reach only the registers of its own device.

The root service makes it with `Device_Create`, the kind `Memory`, a physical address (a multiple of 4096) and a count of pages. This needs the machine handle with the right **Devices**, which only the root service holds. The kernel refuses a range that meets memory that the firmware gave as free or as loaded, so device memory never reaches the memory of a program or of the kernel. The result is a memory handle with **Give**, **Read** and **Write**. The root service reads the base address registers of the device on the bus, makes one device memory object for each of them, and gives each to the device service in its context (the roles `GRANT_BAR + n` of `support/pci`). A mapping of it uses no cache, because a read of a register has an effect and must reach the device each time.

Device memory is not the memory that a device reads and writes for data: that is ordinary memory made `Contiguous`, such as the data region or the memory of the queues. It pays nothing from a budget, because it is not memory.

The design: `docs/ARCHITECTURE.md`, "K5. Device grant and interrupts".

Do not use: MMIO region, BAR mapping.

### Message interrupt

A message interrupt is an interrupt that a device sends as a write of a value to an address of the interrupt controller of a processor (MSI-X).

A device signals that it has done work by an interrupt. The old interrupt lines are few and shared between devices; a message interrupt belongs to one device, so the kernel knows which device signalled with no question to it. The kernel gives each message interrupt a vector of its own on the first processor; it has 16 (`MESSAGE_CAPACITY`).

The root service makes one with `Device_Create`, the kind `Message`, with the machine handle and the right **Devices**. The results are an interrupt handle with **Give** and **Read**, the address that the device must write, and the value that it must write there. The root service writes the address and the value in the table of the device on the bus, enables the table, and gives the interrupt handle to the device service with the right **Read**. The device service never writes the configuration of its device.

When the device writes the value, the kernel adds 1 to the count of the interrupt and to the `events` word of each thread of the program that holds the handle, and wakes them. The device service reads and resets the count with `Interrupt_Read`, then reads its queues.

A message interrupt is not a vector: the vector is the number that the kernel chose for it inside the processor, and a program never sees it. The kernel does no work of the device at an interrupt: it counts and wakes.

The design: `docs/ARCHITECTURE.md`, "K5. Device grant and interrupts".

Do not use: MSI, vector.

### Bus

The bus is the PCI bus of the machine: each device has a place on it (bus, device, function) and a configuration of 256 bytes or more.

The configuration of a device says what it is (its vendor and its device numbers), where its registers are (its base address registers), and how it interrupts. A program that can write the configuration of any device can make any device read or write any memory. For that reason only the root service holds the two ports of the configuration (`0xCF8` and `0xCFC`), as a ports handle that it makes with `Device_Create`.

The root service reads the configuration at a fixed place, checks that the device there is the expected virtio device, enables it, gives it the right to use memory (bus master), sets its message interrupt, and starts its device service. The service gets a copy of the first 256 bytes of the configuration, read only (`GRANT_CONFIGURATION`), the device memory of its registers and one message interrupt. On the first machine the places are fixed: the data disk at device 16 (`0x10`), the disk of the measures at 17, the network device at 18. If no device of the right kind is at the place, the root service logs "root: no virtio device for block at the place 16 of the bus" and starts no service.

The bus is not a tree that the kernel walks: the kernel does not read it at all. The code of the bus is `support/pci`.

The design: `docs/ARCHITECTURE.md`, "K5. Device grant and interrupts", and `docs/ARCHITECTURE.md`, "U4. Device services".

Do not use: PCI tree.

### Disk

A disk is a device that keeps blocks when the machine stops.

A disk is the one place where data survives a stop of the machine. The system reads and writes a disk only through the block service of that disk, as a row of blocks numbered from 0; no program but the storage service and the program `disk` is a client of one.

The test machine has three disks, three virtio block devices:

- the boot volume: the FAT volume that the firmware reads to start the boot program. No block service serves it.
- the data disk: the disk of the storage service, 64 MiB on the test machine.
- the disk of the measures: the disk where the program `disk` measures the block service.

A disk is not a volume with a file system: the system puts no partition table and no file system on the data disk; the storage service writes its own format on the whole disk.

The design: `docs/ARCHITECTURE.md`, "U4. Device services", and `docs/STORAGE.md`, "3. The format on the disk".

Do not use: drive, volume (except the boot volume), LUN.

### Block

A block is 4096 bytes of a disk at a number from 0: the unit of each read and write of the block contract.

A block is the unit that a block service reads and writes (`BLOCK_SIZE` in `contract/block`). A request names its first block, a count of blocks and a place in the data region; a device that has smaller sectors still serves whole blocks. The storage service builds everything that it writes from blocks: a node, an object node, a block of data, a root block.

A block is the same size as a page of memory, so one block fits one page of the data region, but a block is on the disk and a page is in memory: the two words are not exchangeable.

The design: `contract/block`, and `docs/STORAGE.md`, "3.1 The blocks".

Do not use: sector, page (for a disk).

### Block service

A block service is the device service of one disk: it serves read, write and flush of blocks to one client through a block ring.

A block service keeps the code that knows a disk device out of the kernel and out of the storage service. The first one is the program `block`, for a virtio block device; a service for another class of device (NVMe) can serve the same contract, `contract/block`, and its client does not change.

The root service starts one block service for each disk that a program needs, with exactly one device: the device memory of its registers, one message interrupt, memory for its queues, the machine handle with the right **Physical** only, and a copy of its configuration. It makes the block ring, and gives it to the service and to its one client. The client sends `Attach` with its data region, then `Info`, `Read`, `Write`, `Flush` and `Statistics`. The service turns each request into a request of the device, and the device moves the bytes to and from the data region with no copy and no kernel entry. The service enters the kernel only to wait and to wake its client; one entry serves many requests.

The service takes a command only when the completion queue has room: a client that does not read its completions stops only its own requests. A write is on the disk only after a `Flush` that the client sent after the completion of that write.

Example: on the disk of the measures, its first line is "block: ok, 8192 blocks of 4096 bytes, a queue of ...", then the size of the queue of the device, the most requests in flight, and whether the disk has a cache that `Flush` empties.

A block service is not a block layer: it has no cache, no scheduler of requests and no partition. It does not know what a block holds.

The design: `docs/ARCHITECTURE.md`, "U4. Device services", and `contract/block`.

Do not use: disk driver, block layer.

### Block ring

The block ring is the ring between a block service and its one client: one command record is one request on blocks, and its completion record has the tag of the command and a status.

The block ring carries each request of a client to its disk with no kernel entry for each request. It has a capacity of 256 records (`RING_CAPACITY` of `contract/block`). The root service makes it; it is the role 0 in the context of the block service and the role 6 in the context of the client.

A command record has a kind (`Attach`, `Info`, `Read`, `Write`, `Flush`, `Statistics`), a tag of the client and values. For `Read` and `Write`: the first block, the count of blocks, and the place in the data region in bytes, a multiple of 4096. Many requests are in flight at once, and the device does them in any order: a client that needs an order waits for the completion of the first request. The status of a completion is `Ok`, `Bad_Command`, `Out_Of_Range`, `No_Region`, `Device_Error` or `Unsupported`; when it is not `Ok`, the values are an error record, so the client can say which value was wrong.

The handle of the data region goes through the ring with `Handle_Give` in the command `Attach`, and the service proves with `Handle_State` that it came through this ring.

A block ring is not a queue of the device: the device has its own queues, which only the block service sees.

The design: `contract/block`, and `docs/ARCHITECTURE.md`, "Rings and wait".

Do not use: I/O queue, submission queue.

### Data region

The data region is the memory object of the client of a block service where the device reads and writes the bytes of the blocks, with no copy.

The device moves the bytes of a block directly to and from memory of the client, so no program copies them. For this the region must be contiguous: the client makes it with `Memory_Create` and the flag `Contiguous`, and the block service reads its physical address with `Memory_Physical`. The storage service makes a region of 64 blocks; the program `disk` makes one of 1 MiB.

The client gives the region to the block service with the command `Attach`. A request names a place in the region in bytes, never an address: the service checks that each byte of the request is in the region (`Out_Of_Range`), so a client cannot make the device write outside its own memory. A new `Attach` replaces the region; a client sends it when no request is in flight.

The data region is not a cache: the client decides what it holds and when, and it must not change a place while a request on that place is in flight. The frame region is the same idea for a frame service.

The design: `contract/block`.

Do not use: DMA buffer, bounce buffer.

### Data disk

The data disk is the disk of the storage service: it holds the private stores of each program.

The data disk is the one disk whose content the system keeps. The root service starts its block service (the device at place 16 of the bus) when the storage service starts, and gives the block ring to the storage service only. The storage service writes its own format on the whole disk: two places for the root block, then the blocks of the trees, the objects and the versions. The kernel tool makes a disk of 64 MiB for a run and a new one for each machine test.

The data disk is not a home disk or a disk of the user: no program reads it but the storage service, and a program sees only its own private store.

The design: `docs/STORAGE.md`, "3. The format on the disk".

Do not use: data drive, home disk.

### Disk of the measures

The disk of the measures is a disk that holds no data that a program keeps: the program `disk` measures the block service on it.

A measure of the block service writes blocks. A measure on the data disk destroys the stores. So the test machine has a second disk for it, the device at place 17 of the bus, and the root service gives its block ring only to the program `disk`.

The program reads and writes the first 4096 blocks (16 MiB) for one second in each measure, with one request in flight and then with 32, and counts the blocks and the kernel entries of the two programs for each request. Then it writes a pattern, flushes, reads the pattern back and compares. It shows the result in its window.

The disk of the measures is not a disk for tests of the storage service: the storage service never uses it.

The design: `programs/disk`.

Do not use: scratch disk, test disk.

### Network device

A network device is a device that sends and receives frames on a link.

The test machine has one virtio network device, at place 18 of the bus, with the hardware address 52:54:00:12:34:56. Its link is the user network of QEMU, where the peer of the kernel tool is the gateway.

The root service starts the frame service of the device when the first program that needs the network starts. The frame service is the only program that touches the device, and the network service is the only client of the frame service. So no program but these two can send a frame.

A network device is not an interface with an address: the device has a hardware address only. The IPv4 address 10.0.2.15 belongs to the network service.

The design: `docs/ARCHITECTURE.md`, "U4. Device services", and `docs/NETWORK.md`, "The parts".

Do not use: NIC, network card, network adapter.

### Frame

In the group Devices, a frame is one Ethernet frame: the bytes from the destination hardware address to the end of the data, with no check sequence, 1514 bytes at most.

A frame is the unit that a network device sends and receives, and the unit of the frame contract (`FRAME_LIMIT` in `contract/frame`): 14 bytes of header and 1500 bytes of data. The device adds the check sequence when it sends and removes it when it receives. The device pads a frame shorter than 60 bytes with zero bytes.

The network service builds each frame that it sends and reads each frame that it receives, with `support/network`. A datagram of 1472 bytes or a segment of 1480 bytes fits one frame, so the system never fragments.

A frame is not a datagram and not a packet of IPv4: those are the content of a frame. It is also not the frame of QUIC, the unit inside a packet of QUIC, which has its own entry in the group QUIC.

The design: `contract/frame`.

Do not use: packet (for this), datagram (for this), message.

### Hardware address

A hardware address is the 6 bytes that name a network device on its link.

A frame names its destination and its source by hardware addresses. The network service learns the hardware address of its own device from the completion of the command `Info` of the frame ring, and learns the hardware address of each other machine of the link by ARP, as a neighbor. The device of the test machine has 52:54:00:12:34:56.

A hardware address has meaning on one link only: it is not an address of IPv4 and it does not cross the gateway.

The design: `contract/frame`.

Do not use: MAC address, physical address (for this).

### Frame service

A frame service is the device service of one network device: it sends and receives frames for one client through a frame ring, and it does not read a frame.

The frame service keeps the code that knows a network device out of the kernel and out of the network service. The first one is the program `frame`, for a virtio network device; a service for another class of device can serve the same contract, `contract/frame`.

The root service starts it with exactly one device, as for a block service: device memory of its registers, one message interrupt, memory for its queues, the machine handle with the right **Physical** only, and a copy of the configuration. Its one client is the network service. The client sends `Attach` with its frame region, then `Send` for each frame to send and `Receive` for each place where a frame can arrive. The device reads and writes the frames in the frame region with no copy.

The service checks no address and computes no check: the client builds and checks each frame. If no `Receive` waits when a frame arrives, the device drops the frame. Example of its first line: "frame: ok, the hardware address 52:54:00:12:34:56, the link is up, ...", then the sizes of its two queues of the device and the count of places for frames that arrive.

A frame service is not a network stack: it knows no protocol.

The design: `docs/ARCHITECTURE.md`, "U4. Device services", and `contract/frame`.

Do not use: NIC driver, network driver.

### Frame ring

The frame ring is the ring between a frame service and its one client: one command record is the send of one frame, or a place for one frame that arrives.

The frame ring has a capacity of 256 records (`RING_CAPACITY` of `contract/frame`); it is role 0 of the frame service and role 6 of its client. Its commands:

- `Attach`: the handle of the frame region.
- `Info`: the hardware address, whether the link is up, the most bytes of a frame, the most `Receive` and `Send` in flight.
- `Send`: a place in the frame region and a count of bytes, from 14 to 1514.
- `Receive`: a place and its room. Its completion comes only when a frame arrives there, with the count of bytes of the frame.
- `Statistics`: the frames and bytes sent and received, the kernel entries and the interrupts of the service.

Many requests are in flight. A `Receive` can stay in flight for a long time: the client gives the places before the frames arrive, so the service allocates no memory for a frame. More `Receive` in flight than the device has places gives `Too_Many`; a frame of more than 1514 bytes gives `Too_Large`.

A frame ring is not one queue for each direction: one ring carries both, and the tag of the command says which request completed.

The design: `contract/frame`.

Do not use: TX queue, RX queue, descriptor ring (for this).

### Frame region

The frame region is the memory object of the client of a frame service where the device reads and writes the frames, with no copy.

It is the data region of the frame contract: contiguous, so that the device uses one physical address for each place, and given to the service with `Attach` through the frame ring. A request names a place in the region in bytes, never an address; the service refuses a byte outside it with `Out_Of_Range`. A place for a frame that arrives has 2048 bytes (`PLACE_SIZE`): less room than 1514 bytes can lose a frame.

The network service owns the frame region. It copies the data of each datagram one time, between the datagram region of a program and the frame region.

A frame region is not a socket buffer: a program with an endpoint never sees it.

The design: `contract/frame`.

Do not use: DMA buffer, skb, mbuf.

### Virtio

Virtio is the standard of devices that work through queues in shared memory, which the first machine uses for its disks and its network device.

Virtio makes the first device services short: a virtio device is already a set of queues in memory, so a device service translates between these queues and a ring with little code. The system uses virtio 1 over PCI, the "modern" interface, with no older interface (`disable-legacy=on` in the command of QEMU).

`support/virtio` holds what each virtio device service does the same way: it reads the virtio capabilities in the copy of the configuration, agrees on the features with the device, and drives split queues. A queue takes three pages of the memory of the queues: the descriptors, what the driver gives, what the device used. The block service and the frame service use it.

Virtio is not a part of the kernel: the kernel has no code for any device. Virtio is the first class of devices because the system starts on fixed hardware; a device of another class gets its own device service with the same contract.

The design: `docs/ARCHITECTURE.md`, "U4. Device services", and `docs/PROPERTIES.md`, "No drivers in the kernel, and fixed hardware first".

Do not use: paravirtual device.

## Network

### Network service

The network service is the one client of the frame service: it gives each program with a network grant one endpoint, and it checks each datagram and segment against that grant.

Only one program can read the frames of the device of the first machine, because the device has one pair of queues. The network service is that program. It is also the place where the grant of each program is enforced: a program reaches only the remote that its grant names, so no program has ambient access to the network.

The network service speaks Ethernet, ARP, IPv4, ICMP echo and UDP with the protocol library `support/network`. It has one static address, 10.0.2.15/24, and the gateway 10.0.2.2. For TCP it checks the headers, the TCP checksum and the ports of each segment, writes the IPv4 header, and keeps no state of a connection: the protocol of TCP is a library in the program (`support/tcp`). It copies the data of each datagram or segment one time, between the datagram region of the program and its own frame region. It has one thread, which waits on the frame ring, on the control ring of the root service and on the command queue of each endpoint.

The root service starts it when the first program with a network grant starts, and adds each endpoint with the command `Endpoint_Add` of its control ring. Example of its first line: "network: ok, the address 10.0.2.15/24 52:54:00:12:34:56, the gateway 10.0.2.2, the link is up, ..."; then, for each endpoint, a line such as "network: an endpoint for server: TCP, the listen port 80, the remotes that send to it".

The network service is not a network stack in the sense of Linux: it has no sockets, no connection, no retransmission and no routing table. A frame that it refuses becomes a problem row of the endpoint, or of the machine, with the layer, the field and the rule.

The design: `docs/NETWORK.md`, "The parts", and `docs/ARCHITECTURE.md`, "U7. Network steering service".

Do not use: network stack, TCP/IP stack, netd, network daemon.

### Endpoint

An endpoint is what a program holds to send and receive datagrams or segments: a datagram ring and a datagram region, with a grant that names what it can reach.

An endpoint replaces the socket of other systems, with one difference: the program does not choose the address. The root service names the grant, the network service enforces it, and a request to another remote fails with `Not_Granted` and the remote of the grant in its error record. A datagram or a segment from a remote that the grant does not name never reaches the program.

The kinds of endpoint:

- a datagram endpoint (UDP) with a client grant: one remote address and one remote UDP port; the network service gives the local UDP port and writes the UDP header.
- a datagram endpoint with a listen grant: one local UDP port; the program answers the admitted remotes only.
- a segment endpoint (TCP), with a client grant or a listen grant.

A program gets its endpoint at its start: the root service makes the datagram ring and the datagram region, gives them to the program (the roles 11 and 13 of its context) and to the network service. A program has one endpoint. With the right **Inspect** of its grant, the program also reads the facts of the machine: the frames that no endpoint owns, the kernel entries of the network service and of the frame service. The console shows the grant with `grants("server")` and ends it with `revoke`; a revocation sets the grant to none, and each later request that names a remote gives `Not_Granted`.

An endpoint is not a connection: a segment endpoint carries the segments of all the TCP connections of its program.

The design: `contract/datagram`, and `docs/PROPERTIES.md`, "No ambient access: the other holes to close".

Do not use: socket, port (for this), connection (for this).

### Datagram

A datagram is the data of one UDP datagram and its remote: what a program sends and receives through a datagram endpoint, 1472 bytes at most.

1472 bytes is the data of one Ethernet frame after the IPv4 header (20 bytes) and the UDP header (8 bytes): the system never fragments, so a datagram is one frame (`DATA_LIMIT` of `contract/datagram`). A larger `Send` fails with `Too_Large`.

A program sends a datagram with the command `Send` of its datagram ring: the place of the data in the datagram region, its count of bytes, and the remote address and port. The completion comes when the network service has copied the data: the place is then free again. A program gives a place for a datagram that arrives with `Receive`; its completion carries the place, the count of bytes and the remote. Example: QUIC is a library in the program over datagrams; `quic_echo` and `remote` send and receive each datagram of QUIC through their datagram endpoint.

A datagram is not a frame and not a segment: the frame is the whole Ethernet unit, and a segment is the unit of a segment endpoint, with its TCP header.

The design: `contract/datagram`.

Do not use: packet, message.

### Remote

A remote is the IPv4 address and the UDP port or TCP port at the other end of a datagram or of a connection.

A grant names remotes: a client grant names one, and a listen grant admits the remotes that came to it. A command of the datagram ring names a remote in two values (address and port); an error record of `Not_Granted` packs the remote that a request named and the remote of the grant. Example: the remote of the client grant of `fetch` on the test network is 10.0.2.100 port 80; the remote service admits the address of the host, 10.0.2.2, with any port.

A remote is not a host: the host is the computer that runs QEMU, and a remote is any address and port. It is not a peer either: the peer is one part of the kernel tool.

The design: `contract/datagram`.

Do not use: peer (for this), destination, host.

### UDP port

A UDP port is the 16-bit number of UDP that names one endpoint at an address.

A datagram has a source UDP port and a destination UDP port. The network service finds the endpoint of a datagram that arrives by its destination port: the local UDP port of the endpoint. A program does not choose its local port with a client grant: the network service gives it, and the command `Info` returns it. A listen grant names its port: the remote service listens on the UDP port 7100, `quic_echo` on 4433.

A UDP port is not the Ports object of the kernel (a handle to ports of input and output of the processor), and not a TCP port: the same number is two different ports in UDP and in TCP.

The design: `contract/datagram`.

Do not use: port (alone), socket number.

### TCP port

A TCP port is the 16-bit number of TCP that names one end of a connection at an address.

A segment has a source TCP port and a destination TCP port. The network service reads the ports of each segment to find the endpoint and to check the grant: a client grant has a block of 64 local TCP ports, and a listen grant has one local TCP port. Unlike a UDP port, the TCP port is in the header that the program writes, so the network service checks the local port of each segment that the program sends against its block or its listen port, in its own copy of the segment. Example: `server` has the listen grant of the TCP port 80.

A TCP port is not the Ports object of the kernel, and not a UDP port.

The design: `docs/NETWORK.md`, "The grant of a segment endpoint".

Do not use: port (alone), socket number.

### Segment

A segment is one TCP segment: its header, its options and its data, 1480 bytes at most, what a program sends and receives through a segment endpoint.

1480 bytes is the room of one Ethernet frame after the IPv4 header, so a segment is one frame and never a fragment (`SEGMENT_LIMIT` of `contract/datagram`). A segment has 20 bytes at least, a TCP header with no option (`SEGMENT_LEAST`); a shorter one fails with `Bad_Command`.

The TCP library of the program writes each segment directly in a place of the datagram region, with its checksum, and the program sends it with `Send`. The network service copies it to a frame, reads its ports from the copy, checks them against the grant, and writes the IPv4 header. For a segment that arrives, the network service checks the TCP checksum before the program sees it.

A segment is not a datagram and not a packet: the program sees no IPv4 header.

The design: `docs/NETWORK.md`, "The segment endpoint".

Do not use: packet, TCP packet, message.

### Segment endpoint

A segment endpoint is an endpoint whose grant has the protocol TCP: the program writes and reads whole segments, and the network service keeps no state of a connection.

A segment endpoint puts TCP in the program. The program owns each connection, each window and each timer in its own memory, and can read each field; the network service only checks the grant and copies the bytes. The ring, the region, the commands and the error records are those of a datagram endpoint. Two things differ: a `Send` names a whole segment, header included, and the grant names TCP ports.

A segment endpoint has a client grant (one remote, a block of 64 local TCP ports) or a listen grant (one local TCP port). The program drives it with the TCP library: `tcp.step` takes the segments that arrived and writes the segments to send in the places of the datagram region. Examples: `server` has a segment endpoint with a listen grant of the TCP port 80; `fetch` has one with a client grant.

A segment endpoint is not a TCP socket: it is not one connection, and it does not accept or connect. The program does both, with the library.

The design: `docs/NETWORK.md`, "The segment endpoint".

Do not use: TCP socket, listening socket.

### Client grant

A client grant is the grant of an endpoint that reaches one remote: one remote address and one remote port.

A client grant lets a program reach exactly one server and nothing else. The network service refuses a request to another remote with `Not_Granted`, and drops what another remote sends.

A client grant exists for both endpoints:

- a datagram endpoint: one remote address and UDP port; the network service gives one local UDP port.
- a segment endpoint: one remote address and TCP port; the network service gives a block of 64 local TCP ports (`PORT_BLOCK`). The program chooses one port of its block for each connection, because a closed connection stays in TIME-WAIT and one local port serves one connection at a time to one remote.

The root service names the grant by the name of the program. Examples from the root service: `net` has a UDP client grant of 10.0.2.2 port 7, the echo server of the peer; `fetch` has a TCP client grant of 10.0.2.100 port 80. The network service logs the second one as "network: an endpoint for fetch: TCP, the local ports ", the first and the last port of the block, then ", the grant 10.0.2.100 port 80".

A client grant is not a rule of a firewall that a check reads: it is the only remote that the endpoint can name.

The design: `docs/NETWORK.md`, "The grant of a segment endpoint".

Do not use: outbound rule, connect permission.

### Listen grant

A listen grant is the grant of an endpoint that receives on one local TCP or UDP port that the root service names, from any remote, and answers only the admitted remotes.

A server must receive from remotes that it does not know in advance, but must not reach a machine that did not come to it. The listen grant gives exactly that: the program answers, but it does not reach. A send to a remote that is not admitted fails with `Not_Granted`, and the commands `Resolve` and `Echo` are refused.

The network service keeps the admitted remotes of each listen grant, 64 at most. A UDP listen grant can also name one remote address: then only that address is admitted, whatever the size of its datagram. The remote service uses that form, with the address of the host. A UDP listen grant also limits what the program sends to a remote that it did not validate: at most 3 times the bytes that came from it (status `Amplification`), until the command `Validate`.

Examples: `server` has the listen grant of the TCP port 80; `quic_echo` the UDP port 4433; `remote` the UDP port 7100, for the address 10.0.2.2 only.

A listen grant is not a listening socket: it accepts nothing, and the program has no new object for each connection.

The design: `docs/NETWORK.md`, "The grant of a segment endpoint", and `docs/NETWORK.md`, "The listen grant of UDP".

Do not use: listening socket, bind permission, server socket.

### Admitted remote

An admitted remote is a remote that came to the port of a listen grant, and that the program can therefore answer.

A remote becomes admitted when it sends a SYN (with no ACK and no RST) to the TCP port of a listen grant, or a datagram of 1200 bytes at least to its UDP port, while a `Receive` of the endpoint waits. 1200 bytes is the least first datagram of a QUIC client, so a stray small datagram of an unknown remote takes no place. The remote must have an address that can answer: not 0, not a broadcast or multicast address, not the local address.

The network service keeps 64 admitted remotes for each listen grant (`ADMITTED_CAPACITY`), each with the time of its last segment or datagram in or out. The program releases one with the command `Release` when its connection ended. When the table is full, the oldest place with no traffic for 120 s serves again; with none, the new remote is dropped and counted as the problem `Full`. This table is the one state of TCP in the network service: addresses and ports, with no sequence number and no window.

An admitted remote is not an entry of connection tracking: the network service does not follow the state of a connection. An admitted remote is one address and one port; another port of the same address must be admitted on its own.

The design: `docs/NETWORK.md`, "The grant of a segment endpoint".

Do not use: connection tracking entry, conntrack, NAT entry.

### Connection

In the group Network, a connection is the state of one TCP connection in the program that owns it: one record of fixed size of the TCP library, `tcp.Connection`.

TCP is a library in the program, so the state of each connection is in the memory of the program, not in a service. The record has 400 bytes: the state, the sequence numbers, the windows, the timers, the round trip estimate and the counts. The program can read each field with no call; `server` draws them in its window.

The program does not make a connection record: the records are the rows of its connection table. `tcp.connect` opens one actively; a SYN to the listen port opens one passively, at the next `tcp.step`. `tcp.write`, `tcp.read`, `tcp.close` and `tcp.abort` change one record; the segments that follow come at the next `step`. The step reports what happened as events: the index of a connection and a set of kinds (`Opened`, `Accepted`, `Readable`, `Writable`, `Peer_Closed`, `Closed`, `Reset`, `Timed_Out`, `Refused`). Each connection has a send buffer and a receive buffer at a place that its index gives.

A TCP connection is not the connection of the group Communication (a call ring and a call region between a caller and a service), and not a socket: no handle names it, and no other program sees it.

The design: `docs/NETWORK.md`, "The TCP library".

Do not use: socket, TCB (in this system), session.

### Web page

A web page is an object of the private store of `server` that `server` serves by its name, at the target `/name`.

`server` shows that a program reaches only what it was granted: its pages come from its own private store, not from a shared folder. The principal changes them from the console through the exports of `server`, functions with typed parameters:

- `server.put("hello.html", "a text")`: a new or a changed page.
- `server.remove("hello.html")`.
- `server.pages()`: the table of the pages.
- `server.served()`: the counts of the server.

`server` keeps at most 16 pages. It reads them into its memory at its start and serves them from there, so a request never waits for the storage service. `put` and `remove` write the store first. A page that changes while an answer of it goes out ends that connection with a RST. PUT and DELETE over HTTP are refused with 405, because the network is not authenticated.

A web page is not a file of a web root: no path, no folder, and no other program reaches it.

The design: `docs/NETWORK.md`, "The HTTP server".

Do not use: file (for this), static file, asset.

### Access record

An access record is the record of one request that `server` answered: the remote, the method, the target, the status, the bytes of the body and the time.

The access records let the principal see the traffic of the server with no text log to parse. `server` keeps the last 18 in its window (`ACCESS_HISTORY`), and writes one log record for each request on the log channel `requests`. The time runs from the first byte of the head to the last byte of the answer in the send buffer, in microseconds. Example of the line: "server: GET /hello.html 200, 12 bytes, 157 us, 10.0.2.2 port 49200" (the values depend on the request).

An access record is not a line of an access log in a common format: it is a record of fixed size (`Access_Record`), and its log line has value runs for its numbers.

The design: `programs/server`.

Do not use: access log line, hit.

### Connection table

A connection table is the connection records of one program, the memory of their buffers, and what is common to them: the local address, the listen port, the block of local ports and the secret of the initial sequence numbers.

The TCP library allocates nothing: the caller gives the table (`tcp.Table`) with its records and one block of memory for all the buffers. Each connection has a send buffer and a receive buffer at a place that its index gives. One call, `tcp.step`, works on one whole table: it takes all the segments that arrived, runs the timers, writes the segments to send, and gives the deadline of the next timer. A table with one place in its table of events for each connection is enough.

The table also counts what no connection took: the RSTs sent, the SYNs refused because no record was free, and the records in TIME-WAIT that a SYN took. `remote_limit` limits the open connections of one remote address. Example: `server` has one table of 48 connections and serves all of them from one thread.

A connection table is not a pool of sockets in a kernel: it is memory of the program.

The design: `docs/NETWORK.md`, "The form of the interface".

Do not use: socket table, connection pool.

### Datagram ring

The datagram ring is the ring between a program and the network service for one endpoint.

Its commands, in `contract/datagram`:

- `Send`: a datagram, or a whole segment for a segment endpoint.
- `Receive`: a place for a datagram or a segment that arrives.
- `Info`: the local address and port, the gateway, the hardware address, the link, the grant.
- `Resolve`: ask the hardware address of an address again (ARP).
- `Echo`: send an echo request (ICMP) and wait for its reply.
- `Statistics`: the counts of the endpoint, and the facts of the machine with the right **Inspect**.
- `Problems`: the problem rows of the frames refused for this endpoint.
- `Release`, `Validate`: for a listen grant.

The capacity is 256 records. Many requests are in flight; a `Receive` stays in flight until a datagram arrives, and the network service drops a datagram when no place waits. A refused request has an error record in its completion: the request, and the limit or the grant that refused it. The program finds the ring in the role 11 of its context.

A datagram ring is not a socket: it carries typed requests, and a request names a place in the datagram region, never an address of memory.

The design: `contract/datagram`.

Do not use: socket, channel.

### Datagram region

The datagram region is the memory of an endpoint, 512 KiB, where the program writes the data to send and the network service writes the data that arrives.

The root service makes the datagram region with the datagram ring and gives it to the program and to the network service (the role 13 of the context of the program). A program does not give a region of its own: if the program gave it, a revocation of that memory by the program stops the network service on a page fault, for all programs. A request names a place in the region in bytes; a byte outside it gives `Out_Of_Range`. The network service copies each datagram one time between the region and a frame, and computes no header and no checksum over bytes that the program can still change.

The program organizes the region itself. Example: `server` divides it into 256 places of 2048 bytes, and its TCP library writes each segment directly in one place.

A datagram region is not a socket buffer of a kernel: no data waits in it for a read call, and the program decides which place serves which request.

The design: `contract/datagram`.

Do not use: socket buffer, send buffer, receive buffer.

### Neighbor

A neighbor is an address of the link and its hardware address, which the network service learned from an answer to its own ARP request.

A frame needs the hardware address of the next machine on the link. The network service asks it by ARP and keeps the answer in a table of 16 neighbors (`ARP_CAPACITY` of `support/network`). It learns only an address that one of its own requests asked, so an ARP frame that nobody asked for changes nothing, not even the entry of the gateway. When the table is full, the answer replaces the oldest entry that no waiting request uses. A program asks the network service to resolve an address again with the command `Resolve`.

A neighbor is not an entry of a cache that each ARP frame of the link can change.

The design: `support/network`.

Do not use: ARP cache entry, neighbour entry.

### Gateway

The gateway is the machine of the link that carries IPv4 packets to other networks: 10.0.2.2 on the first machine.

The network service sends each datagram whose address is not on its link (10.0.2.0/24) to the hardware address of the gateway. On the test machine with the network of the tests, the gateway is the peer of the kernel tool; with the user network of QEMU, it is libslirp. The address of the gateway is also the address from which the host reaches the machine, so the listen grant of the remote service admits that address only.

The gateway is not a routing table: the network service has one route, to the gateway, and no other.

The design: `docs/NETWORK.md`, "The parts".

Do not use: router, default route.

### Peer

The peer is the part of the kernel tool that is the gateway and the echo server of the network of the test machine, a TCP client that the tool drives, and the QUIC client of the remote service.

The peer makes the network tests closed and repeatable: no frame leaves the host, and each run has the same answers. QEMU gives it each frame of the network device as one UDP datagram on the loopback of the host (`-netdev dgram`). It reads each frame with its own code, not with `support/network`, so a fault of the network service in a checksum or a length is a fault that the peer sees. It answers ARP, an echo request and a datagram to port 7. It sends frames that the network service must refuse, and can drop, reorder and repeat the frames of TCP with a generator that each case seeds. It carries each call of the tool to the remote service on a call stream, and the call answer back.

The peer is not a simulator of a network: it speaks the real protocols, with the TCP library and the QUIC library of the system. It is in `tools/kerneltool/peer.odin` and `tools/kerneltool/peer_remote.odin`.

The design: `docs/NETWORK.md`, "With the controlled peer", and `docs/QUIC.md`, "7. `remote` over QUIC (built)".

Do not use: mock, fake server, simulator.

### Host

The host is the computer that runs QEMU and the kernel tool; the system does not run on it.

The host builds the system, starts the machine, and drives the tests. For the network of the machine, the host is at the address of the gateway, 10.0.2.2: the peer of the tool answers for it, and each call of the tool to the remote service comes from that address.

The host is not the machine: the machine is the computer, real or emulated, that runs the system. The host is not a remote either: a remote is any address and port at the other end of a datagram.

The design: `docs/QUIC.md`, "7. `remote` over QUIC (built)".

Do not use: build machine (for this), remote (for this).

### Remote service

The remote service is the program `remote`: a QUIC server that takes each call of the host on a call stream, makes it as an isolated call of an export of a service, and writes the call answer on the same stream.

The remote service lets the kernel tool on the host call an export of a running service, for tests and for the console of the developer, with the same descriptions and checks as a call inside the system.

It has a UDP listen grant on the port 7100 that admits the address of the host only. It makes an Ed25519 key at its start and logs it ("remote: the public key of this service: " and 64 hexadecimal digits); the tool pins that key. It holds the connections to the services that the root service lets it call. It has 2 connection records of 8 streams each, so 8 calls can wait at once on one connection, and it makes one isolated call at a time. It does not read the descriptions of the exports: it checks the places and the sizes of each request against the bytes of the stream and the size of the call region (`remote.request_check`), and the service checks the argument record, as for each caller.

The remote service is not a debug agent: it does not read or change the memory of a program, and it calls only exports. It does not know who the client is: whoever holds the address 10.0.2.2 can call as the principal.

The design: `docs/QUIC.md`, "7. `remote` over QUIC (built)", and `docs/MODULE_CONTRACT.md`, "A call from the host".

Do not use: RPC server, debug agent, gdbstub.

### Call socket

The call socket is the Unix socket where the peer of the kernel tool takes the calls of the tool to the remote service, one connection of the socket for each call.

The call socket keeps the calls on the host to one user. It is in `$XDG_RUNTIME_DIR/kerneltool`, or in `/tmp/kerneltool-<user number>` when that variable is not set; the tool makes that folder with the mode 0700 and uses it only when it is a folder of this user with no right for the group and the others. `kerneltool run` takes the socket `calls-run.socket` and prints its path; `kerneltool call` finds it by the same rule; a machine test takes a socket of its own.

On a connection, the tool writes a header with a fixed mark, the key to pin and the count of the bytes, then the call request, then the end of its sending; the peer writes the outcome and the bytes of the call answer. If the peer does not answer, the call fails with "the peer of the tool does not answer at <path>: does `kerneltool run` run?".

The call socket is not a port of the network: no program of another user and no other machine reaches it.

The design: `docs/QUIC.md`, "7. `remote` over QUIC (built)".

Do not use: call port, loopback port (for this).

### Call stream

A call stream is one bidirectional QUIC stream of a connection to the remote service that carries one call: the call request from the host, then the call answer from the remote service.

The stream names the call: no number in a header matches an answer to its request. The host opens the stream, writes the call request and ends its direction; the remote service reads until the end, makes the call, writes the call answer and ends its direction. The stream ends when both ends were read and acknowledged; the server then gives the host one more stream. QUIC sends a lost datagram again, so the host never sends a call again: a call whose answer did not come can have run, and the tool says so.

A call that fails before its answer ends its stream with RESET_STREAM and a stream error code, never with a close of the connection, so the other calls go on.

A call stream is not a channel that carries many calls: one stream, one call.

The design: `docs/QUIC.md`, "7. `remote` over QUIC (built)".

Do not use: RPC channel, request stream (for this).

### Stream error code

A stream error code is the application error code of a RESET_STREAM, a STOP_SENDING or a CONNECTION_CLOSE of the remote service: a value of `remote.Stream_Error`, which the tool prints by its name.

The values:

- `Too_Large` (1): the request has more than `REQUEST_LIMIT` bytes; the remote service stops the stream before any call.
- `Timeout` (2): a bound of time passed: a request not whole 10 s after its stream came, an answer that the host did not take 10 s after the call, or a reset stream that the host did not end 10 s later.
- `Cancelled` (3): the host reset its stream or sent STOP_SENDING before the call. A call that ran keeps its effects.

A request that does not pass its check does not get a stream error code: it gets a call answer with the status Refused and its error record.

A stream error code is not a status of a call and not an error number: it says why the transport of one call ended.

The design: `docs/QUIC.md`, "7. `remote` over QUIC (built)".

Do not use: status (for this), error number.

### Call request

A call request is the bytes of a call stream from the host to the remote service: a fixed header, `remote.Request`, then the bytes of the call region from offset 0.

The header has 104 bytes: the kind (`Call`), the name of the service, the BLAKE3 hash of the module of the service that the host read, the index of the export, the count of the bytes that follow, the size of the argument record, the places of the result and of the error record, and the end of the table of error details. The host encodes the arguments with the description of the export (`isolated.encode`), as a call inside the system does. A request has at most `REQUEST_LIMIT` bytes: its header and a whole call region (65 640 bytes).

The remote service trusts nothing in a request: `remote.request_check` checks each count and each place against the bytes of the stream and the size of the call region. A refusal is a call answer with the status Refused, such as "the call has 20 bytes; it must have at least 104 bytes".

A call request is not a message of a protocol of remote procedures with names in text: it names the export by its index and the module by its hash, and has no field whose size depends on a language or a machine.

The design: `contract/remote`, and `docs/MODULE_CONTRACT.md`, "A call from the host".

Do not use: RPC request, message, packet.

### Call answer

A call answer is the bytes of a call stream from the remote service to the host: a fixed header, `remote.Answer`, then the bytes of the result.

The header has 112 bytes: the status, the integer result, the error record, and the count of the bytes of the result that follow (`total`). The host trusts nothing in it: `remote.answer_check` checks that the bytes are exactly a header and its total. The host decodes the result with the description of the export and prints it, as the console does. A call answer has at most a header and a whole call region (`ANSWER_LIMIT`).

The answers come back in any order; the host matches each one to its call by its stream.

A call answer is not a response of HTTP: it has no headers of text, and its status is a status of the call.

The design: `contract/remote`.

Do not use: response, reply.

### Developer tool

A developer tool is a program that shows how the system runs: what a program holds in memory and how its threads run; it reads reports of the kernel with a grant and changes nothing.

A developer tool makes the state of the kernel visible without a debugger attached. Each tool reads reports with the operation `Inspect`, with the machine handle and the right **Inspect**; the scheduler also needs **Schedule**. A program without the right sees no other program. The tools:

- `monitor`: the counts of the system and of each program.
- `pages`: its own page table and the kernel half.
- `processors`: the report of each processor.
- `locks`: the locks of the kernel.
- `scheduler`: the run queues and the strategy.
- `manual`: the flat tables of each module.
- `log`: the log records.
- `inspect`: the address space, the modules, the threads and the stop report of one program that the principal chooses.

Each tool also serves its facts as exports, so the console reads them as tables: `inspect.mappings()`, `monitor.programs()`.

A developer tool is not a debugger: it does not stop a thread, read the bytes of another program, or change anything.

The design: `docs/TOOLS.md`, "What each tool reads".

Do not use: debugger (for this), profiler, task manager.

### Sample

A sample is one read of all the reports that a developer tool shows, at one time.

A developer tool reads several reports, and the system runs between two reads. A sample groups them so that the window shows one state. `inspect` takes a sample each 250 ms, and shows the time of one sample and its kernel entries, so the cost of the tool is visible. Each report has the serial of its program: a sample whose reports have two serials (a program ended, and a new one took its slot between two reports) is dropped, and the window keeps the sample before. A value that changed since the last sample is drawn in another color for one sample; the key space freezes the sample.

A sample is not a snapshot of the store, and not a frame of the screen.

The design: `docs/TOOLS.md`, "The program `inspect`".

Do not use: snapshot (for this), poll, frame (for this).

### Folded gap

A folded gap is the part of the band of an address space between two mappings that has no mapping: the band draws it with a fixed width and lines at an angle.

An address space of a program has small mappings far apart. On a scale by address, the mappings are invisible lines. `inspect` folds each gap, so each mapping keeps a readable width, and draws lines at an angle on the gap to show that it has no measure on the scale.

A folded gap is not an ellipsis of a text: it is a part of a drawn band, and its width says nothing of its size.

The design: `docs/TOOLS.md`, "The program `inspect`", and `docs/DESIGN.md`, "2. Forms".

Do not use: ellipsis, break.

### Near export

A near export is the export of a module with the highest address at or below an address: a reader names the address "module + offset, near name".

A module names its exports only. With no debug image, a frame of a stack trace in a function that is not an export has no name of its own. The near export gives it the name of the export before it, as a hint, with the offset from the module. With a debug image, a frame has the name of its procedure and its source line instead: "fault::three + 0x8 in fault (programs/fault/main.odin:15)".

A near export is not a symbol: it is an export, the only name that a module carries, and it can be far from the real function.

The design: `docs/TOOLS.md`, "Names and lines".

Do not use: symbol (for this), nearest symbol.

### Confirmed place

A confirmed place is a place of the pointer that the kernel tool read from the compositor before a press, through the remote service.

A loaded host can lose a move of the pointer that the tool sends through the monitor of QEMU, and a press then lands elsewhere. So, in a machine test, the tool calls `compositor.pointer()` before each press and moves the pointer again until the compositor has it at the place that the step wants, 6 tries at most (`POINTER_TRIES`). Before the remote service runs, the tool moves the pointer with no confirmation.

A confirmed place is not a move of the pointer by the system: the compositor only reports where the pointer is.

The design: `pointer_confirm` in `tools/kerneltool/machine.odin`.

Do not use: pointer sync, warp.

### Request number

A request number was the number that the host gave to a call request in the protocol of datagrams of the remote service, before QUIC; no part of the system uses it now.

With that protocol, each datagram of a call answer carried the number of its request, and a request with the number of the last call answer got that answer again, so a call did not run two times. The remote service now runs over QUIC: a call stream names the call, a header of `contract/remote` has no request number, and QUIC sends a lost datagram again.

The design: `docs/QUIC.md`, "7. `remote` over QUIC (built)".

Do not use: sequence number, request id, transaction id.

## Storage

### Object

An object is bytes that never change, named by their hash: a new content is a new object.

The object is the unit of stored data in the model of the system. A module, a font, a picture and the text of a note are the same thing: bytes and their hash. Because the bytes never change, a hash names them for certain, a cache of objects needs no trust, and a version costs nothing more than keeping the old object.

Today an object exists as an entry of kind object in a tree: the entry holds the size, the hash of the object, the root of its block tree, and its version index. A program writes an object with `storage.write(place, name, data)` (one commit, up to 64 KiB), or by ranges with `write_range` and `commit`; it reads it with `read` or `read_range`. A write does not change the bytes of the object of before: it gives the entry a new state, and the state of before becomes a version. The hash is kept in the entry, but the blocks are still found through the entry, not by the hash: two entries with the same bytes still hold two block trees, and the index from a hash to its blocks is a later step.

An object is not a file: it has no path, no owner and no permission bits, and it is never changed in place. A program reaches it only through a place of its own connection.

The design: `docs/STORAGE.md`, "1. The model", and `docs/PROPERTIES.md`, "A storage engine with one private store per program".

Do not use: file, blob, inode.

### Tree

A tree is an object that names other objects and trees, each by an entry with a name.

A tree replaces the folder of other systems, and is the only kind of folder. A tree holds trees, so in the model the hash of a tree fixes each byte under it, and a system or a package is one tree. A handle on a tree reaches what is under it and nothing above it.

On the disk, each tree is its own B+ tree of nodes: a tree inside a tree is an entry whose pointer names the root node of the inner tree. The entries are in the order of the bytes of their names, and a tree has no limit of entries but the disk. A program makes a tree with `storage.add` (up to 256 entries in one commit, each an empty object or an empty tree), opens it with `storage.open(place, name)`, which gives a new place, and lists it by pages with `storage.list(place, after, ...)`, so a tree of a million entries is never given whole. Example: the machine test of `hierarchy` makes 100000 entries in trees inside trees.

A tree is not a directory with a link to its parent: an entry is always one step down, and no name reaches the tree above. Today a tree that changes has no hash: the entry of a tree holds a zero hash, because the form of a B+ tree depends on the order of the changes.

The design: `docs/STORAGE.md`, "1. The model", and `docs/STORAGE.md`, "3.2 An entry".

Do not use: directory, folder, list (for this), manifest, catalog (for this).

### Entry

An entry is one name of a tree and what it names: an object or a tree.

An entry is the only link between a name and data. It holds, in 104 bytes (`Entry` of `contract/store`): the kind, the size (the bytes of an object, the entries of a tree), the generation, the time and the date of its last change, the hash of an object, the pointer of the root of its block tree or of the root node of its tree, and the version index of an object.

A name has 1 to 64 bytes, no zero byte, no byte `/`, and is not `.` or `..`. So a name is one step down, never up, and a name that a program looks up under a place never reaches a node outside it. The service refuses a bad name with the byte that breaks the rule. A rename moves an entry, with its versions, inside one store.

An entry is not a path and not a hard link: a program never names an entry by a path, only by a place and one name.

The design: `docs/STORAGE.md`, "3.2 An entry".

Do not use: directory entry, link, file name, path.

### Node

A node is one block of the B+ tree of a tree: a leaf of up to 24 entries, or a branch of up to 50 children.

A node keeps a tree of any size in blocks of 4096 bytes, with a search in a few reads. A leaf holds records of a name (64 bytes) and its entry (104 bytes); a branch holds records of a name and the pointer of a child. A B+ tree has at most 8 levels. Each node starts with a header with its level, its count and the mark "TREE", so a block of another kind is damage.

A commit never writes over a node that the root on the disk names: it writes each changed node to a free block, then the node above it, up to the root node of the store (copy on write). The open of the disk walks each node once and checks it; a node that breaks a rule of its format is damage of its store.

A node is not an object node: an object node is a block of the block tree of one object. It is not a page of memory either.

The design: `docs/STORAGE.md`, "3.1 The blocks", and `contract/store`.

Do not use: page (for this), bucket, inode.

### Store

A store is a cell that names one tree now: the one thing of storage that changes.

The store is the unit of access and of accounting. A grant of the root service gives a program a connection to one store, with a limit of blocks; a commit moves the store to another tree in one atomic step, and the versions are its history.

On the disk, the root block has one store entry for each store (60 at most): its name, its limit of blocks, the blocks that it uses, and the pointer of its store block. The store block holds the root node of the tree of the store, the root node of its removal queue, and its counts (objects, trees, the blocks of the current objects, the nodes). A program sees the counts of its store with `storage.usage()`. Example: "storage: ok, generation 1027: 3 stores, 4 objects, ..." at the start of the storage service.

A store is not a volume, a file system or a mount: a program never names a store by a path, and sees no other store unless it acts for the principal of that store. It is not a head of a version control system either: a store holds no history of its own tree today; the versions are kept for each object.

The design: `docs/STORAGE.md`, "1. The model", and `docs/STORAGE.md`, "3.1 The blocks".

Do not use: reference (for this), volume, file system, mount, head.

### Place

A place is a number that a connection to the storage service holds: the names of a path from the root of the connection, and the right to change or read only.

A place lets a program name a tree under the root of its connection with no path in a call. Each export that names an entry takes a place and one name: `storage.write(place, name, data)`. The place 0 is the root of the connection, with no call. `storage.open(place, name)` gives the place of the tree `name` under `place`; `storage.close(place)` frees it. A place on the root of another store comes from `storage.open_store(store)`, for a caller that can name that store: such a place reads, restores and clones only.

A place follows the names, not the bytes: if a program with a wider place renames a tree above the path, the place names what is at the path now. A place has at most 32 trees on its path. A place is valid on its connection only: a call that names a place of another connection gets `Absent` with the unit `Places`.

A place is not a file descriptor and not a working directory: it is not a handle of the kernel, it cannot leave its connection, and it never reaches above its root.

The design: `docs/STORAGE.md`, "4.1 Places", and `docs/STORAGE.md`, "4.2 No way up".

Do not use: file descriptor, directory handle, working directory, path.

### Share

A share is a connection to the storage service that the service itself makes for a caller, whose root is a tree of the store of the caller, with or without the right to change.

A share is the way to give another program a part of a store, and only that part. `storage.share(place, read_only)` gives the caller two handles: the call ring and the call region of the new connection. The caller gives them to the other program with `Handle_Give`. The other program reaches the tree of the place and what is under it, and nothing above; a share made with `read_only` refuses each change with `No_Grant`, unit `Changes`. `storage.unshare(share)` revokes the two handles in each program (`Handle_Revoke`), and a later call gives `Gone`. When the grant of the store of the maker ends, each of its shares ends too, at its next call.

A share is not a mount and not a bind: it adds no name to any tree, and the program that receives it sees a connection with its own place 0.

The design: `docs/STORAGE.md`, "4.3 Read only, and revocation".

Do not use: mount, bind, export (for this), link.

### Removal queue

The removal queue is the trees of a store that a remove took out of their tree and whose blocks the storage service has not freed yet.

A remove of a tree with a million entries must not be one huge commit. So `storage.remove(place, name)` of a tree is one commit: the entry leaves its tree, and the tree goes into the removal queue of the store. The name is gone at that commit. The storage service then frees the queue in steps, when no call waits: each step is one commit that removes up to 64 entries of the first tree of the queue, and an inner tree goes into the queue in its turn. The queue is a tree on the disk (its root node is in the store block), so a loss of power loses no step. `storage.usage()` gives the trees in the queue (`removing`), and the blocks under them stay counted in the store until they are free.

The removal queue is not a trash: nothing in it can come back, and no program can read it.

The design: `docs/STORAGE.md`, "4.4 The removal of a tree".

Do not use: trash, bin, garbage list.

### Version

A version is the state of one object at one commit: its size, the root of its block tree, and the generation, the time and the date of that commit.

Versions remove the save action: a program never asks to keep a state, and each commit that changes an object keeps the state before it as a version, in the version index of the object. A version costs only the blocks that only it names: the blocks of the state of before are already on the disk, and the new state names each block that did not change.

A program reads versions with exports of the storage service:

- `versions(place, name)`: a table of the versions: generation, time, date, bytes, and the blocks that only this version holds.
- `version(place, name, generation)`: the bytes of one version.
- `compare(place, name, first, second)`: the ranges of bytes that differ between two states.
- `restore(place, name, generation)` and `clone(place, name, new_name)`.

An object has at most 21590 versions; the retention rule and the thinning at the limit remove versions. A remove ends the object and its versions. A rename keeps them. A damaged state is not kept as a version: the change replaces it.

A version is not a backup on another disk, and not a revision that a program makes on purpose. It is kept for each object, not for the store: the history of a store is a later step.

The design: `docs/ARCHITECTURE.md`, "U5. Storage service", and `docs/STORAGE.md`, "Versions, thinning and the limit".

Do not use: snapshot (when it means one object), backup, revision, undo step.

### Current version

The current version is the state of an object that its last commit made: what a read gives.

The entry of the object names the current version directly: its size, its hash and the root of its block tree. It is not in the version index. A commit makes a new current version, and the current version of before becomes a version. A pending change of a connection is not yet the current version: the connection sees it on its reads, and each other connection sees the current version.

The current version is not a working copy: it is on the disk, at the commit that made it.

The design: `docs/STORAGE.md`, "3.2 An entry".

Do not use: head, working copy, latest revision.

### Version index

The version index is the blocks of one object that list its versions: an index block that names leaf blocks, which hold the version entries, the oldest first.

The entry of an object points to its version index. The index names up to 254 leaves; a leaf holds 85 version entries of 48 bytes (generation, size, time, date, and the root of the block tree of the state). So an object has at most 21590 versions. The index also keeps the time of the last application of the retention rule to the object. A commit that changes the object rewrites the index and the leaf that it changes: 2 blocks, copy on write. When the 254 leaves are full, a commit moves the remaining versions to the first leaves (a compaction).

A version index with a wrong check does not lock its object: the next commit of the object drops those versions, and until then `versions`, `version` and `restore` give `Damaged`.

A version index is not a journal: it records states, not operations, and nothing replays it.

The design: `docs/ARCHITECTURE.md`, "U5. Storage service", and `contract/store`.

Do not use: history file, journal, log.

### Shared block

A shared block is a block that two states, two objects or two nodes name: a block that a change did not touch, or a block of a clone.

Copy on write makes shared blocks: a commit writes new blocks only on the paths that it changes, and the new state names each other object node and block of data of the state before. A clone names the root of the block tree of its source, so the two share each block until one of them changes. A store counts each distinct block one time in its blocks in use. Example: after 1000 writes in an object of 8 GiB, the version before them holds 4 blocks of its own, and its other blocks are shared. The start line of the storage service gives the count of shared blocks.

One exception: the count of the current objects (`current_blocks`) counts a block that two clones share two times, so a change at the limit of a store can be refused early.

A shared block is not a deduplicated block: the service does not search for equal bytes; it shares only what a commit did not change, and what a clone names.

The design: `docs/STORAGE.md`, "Versions, thinning and the limit".

Do not use: deduplicated block, extent reference.

### Reference count

A reference count is, for each block in use, the count of what names it: the nodes that name it, and the entries and versions that name it as a root.

The reference count lets the storage service free a block at the commit that drops its last name, with no walk of the disk. A release of a state takes one name from its root; a node with no name left gives one name less to each of its children. A block is free when its count goes to 0. The counts are in the memory of the service only: the open of the disk makes them again by a walk of each node and each block tree. A count is 32 bits; a commit that passes 2^32 - 1 is refused with `Over_Limit`, unit `References`. A commit that takes a count below 0 is refused as a fault of the engine, and the service then changes nothing in that store until its next start.

A store block, a node, a version index and a version leaf are named one time; only object nodes and blocks of data can have a count above 1.

A reference count is not a link count of a file: no program sees it, and no name of a path is counted.

The design: `docs/STORAGE.md`, "Versions, thinning and the limit".

Do not use: link count, refcount (in text).

### Thinning

Thinning is the removal of versions of an object in a commit, by the retention rule or at the limit of the store; its blocks that no other state names become free.

Thinning keeps the versions from filling the disk with no action of a program. It has two causes:

1. The retention rule: the service applies it to an object at a commit of that object, at most one time each minute.
2. The limit of the store: a change that does not fit thins the oldest versions of the store (the lowest generations, in any object), in the same commit as the change, until it fits. The version that the change itself makes can go too.

A change that does not fit even with each earlier version thinned is refused before any thinning, with `Over_Limit` and the sentence "with no earlier version kept": a refused change destroys no history. A thinning and its change are one commit, so a loss of power never keeps one without the other. The service writes a line for each thinning.

Thinning is not a collection of garbage: it removes versions by a rule, and the reference count frees the blocks at once, with no walk.

The design: `docs/ARCHITECTURE.md`, "U5. Storage service".

Do not use: garbage collection, pruning, cleanup, compaction.

### Retention rule

The retention rule is which versions the storage service keeps: each version for 10 minutes, then the newest of each hour until it is one day old, then the newest of each day.

The rule keeps many versions of a recent state and few of an old one, with no setting. Its code is pure and has host tests (`support/storage_retention`). The hours and the days are counted from the format of the disk, so the buckets do not move from one application to the next, and a version that the rule keeps stays kept until it changes zone. The age of a version is the smaller of its age by the date and its age by the time since the format, so a wrong clock on one start never makes a version look older than it is.

The retention rule is not a policy that a program sets: it is the same for each store. The limit of the store can still thin a version that the rule keeps.

The design: `docs/ARCHITECTURE.md`, "U5. Storage service".

Do not use: backup policy, history limit.

### Clone

A clone is a new entry that names the block tree of another object: the two share each block until one of them changes.

A clone copies an object of any size in one commit that writes no block of data. `storage.clone(place, name, new_name)` makes `new_name` under the same place name the root of the block tree of `name`. A state of `new_name` before the clone becomes a version. After the clone, a change of either object writes new blocks on its own paths only.

A clone is not a copy of the bytes, not a hard link (a change of one does not change the other), and not a reflink of a file system: it is the normal sharing of the block tree.

The design: `docs/ARCHITECTURE.md`, "U5. Storage service".

Do not use: copy (for this), hard link, reflink.

### Restore

A restore is a commit that makes a version of an object its current version again; the current version before it becomes a version, so nothing is lost.

`storage.restore(place, name, generation)` writes no block of data: the entry names the root of the block tree of the version. The result is the generation of the commit. Because the state of before becomes a version, a restore can itself be undone by another restore.

A restore is not a rollback of the store: it changes one object, and each other object keeps its current version.

The design: `docs/ARCHITECTURE.md`, "U5. Storage service".

Do not use: revert, rollback, undo.

### Time since the format

The time since the format is the milliseconds of the storage service since the format of the data disk: the root block keeps it at each commit.

A version needs a time that never goes back, also when the machine has no date. The root block keeps the time since the format at each commit; at its start, the service takes it from the root and adds its own time since its start. Each entry and each version keeps it beside the date. The retention rule counts its hours and days from it, and takes the age of a version as the smaller of its age by the date and its age by the time since the format.

The time since the format is not the time since the start of the machine, and not a date: it does not count the time when no machine ran.

The design: `docs/ARCHITECTURE.md`, "U5. Storage service".

Do not use: uptime, timestamp.

### Snapshot

A snapshot is the tree that a store named at one commit; the system does not keep it apart.

The state of a store at a generation G is, for each object, its version with the highest generation at or below G. So the versions of each object hold each snapshot, with no structure of its own. In the model, the versions of a store will be the trees that it named; that history of a store is a later step.

A snapshot is not a copy and not a backup.

The design: `docs/STORAGE.md`, "1.3 Where the model does not hold as it was first stated".

Do not use: checkpoint, backup.

### Private store

A private store is the store of one program: the root service names it after the program and gives it a limit of blocks, and no other program sees it.

The private store replaces the shared file system: a program keeps its data where no other program can read or damage it. The root service gives a program with the grant `Store` a connection to the storage service whose store is named after the program: the name of the program for principal 0, `<program>.principal.<number>` for a named principal, so two principals that run one program have two stores. The limit of blocks counts the nodes, the object nodes, the blocks of data and the versions, so a program cannot fill the disk with versions. Examples: `notes` keeps its notes there; `server` keeps its web pages.

Another program reaches a part of a private store only through a share. A program that acts for a principal (the console, `remote` for the host) can open a place on the stores of that principal with `open_store`.

A private store is not a home folder of a user and not a container: it belongs to one program, and holds no file of another.

The design: `docs/PROPERTIES.md`, "No global, mutable, shared file system", and `docs/STORAGE.md`, "4.2 No way up".

Do not use: home directory, app data, container.

### Document

A document is an object that belongs to the principal and not to one program, which a program reaches only through a grant of the document service.

A document solves what the private store does not: data that several programs open, such as a text or a picture. In the design, the document service owns the documents, shows the picker where the principal chooses one, returns a handle to the program that asked, and records each grant so that it can be listed and revoked. The document service is not built: no program serves documents today.

A document is not a file of a shared file system: a program cannot list or open the documents by itself.

The design: `docs/ARCHITECTURE.md`, "U6. Document service", and `docs/PROPERTIES.md`, "No global, mutable, shared file system".

Do not use: file, user file.

### Module store

The module store is the set of all modules and system data, each named by the hash of its content.

In the model, the module store is the objects of the tree of the system: the root service loads each module, font and pointer theme by its hash, and an object can come by any channel because its hash proves it. It is not built: today the boot image is the one source of modules and resources, and modules are not in the storage service. The hash of a module is the BLAKE3 hash of its file, the same function that names an object.

The module store is not a store of the storage service, and not a repository of packages with versions by name.

The design: `docs/STORAGE.md`, "5. Not built: the next steps", and `docs/PROPERTIES.md`, "Reproducible system".

Do not use: package store, repository, the Nix store.

### System description

The system description is the list of hashes that defines one version of the whole system: the kernel, then each module and each resource of the boot image, with its kind, its size and its BLAKE3 hash.

The system description makes the system reproducible and verifiable: two machines with the same description run the same bytes. Its file (`contract/system_description`) has a header of 16 bytes and one entry of 80 bytes for each part, in the order of the boot image, and no other byte. The signing key of the machine signs its hash (`docs/TRUSTED_BOOT.md`, "5. The signing key"). The boot program verifies the signature and each hash before it starts the kernel, and the root service checks the boot image against it again before it starts the first program. The boot image holds the description and its signature as its last two resources, which the description does not list, because a file cannot hold its own hash.

The system description is not the boot image (which carries the bytes) and not a generation of the storage service. In the model it becomes the tree of the system, signed by its publisher.

The design: `docs/TRUSTED_BOOT.md`, "3. The system description", and `docs/PROPERTIES.md`, "Reproducible system".

Do not use: image, generation, manifest, profile, system list.

### Distinct result

A distinct result is one content of one output of a build (a module, its LLVM IR, its object, the boot program) among the contents that several builds of the same source gave.

The identity of a module is the hash of its content, so a build must be deterministic: one source must give one distinct result for each output. `kerneltool check` builds everything a second time and compares; `kerneltool repeat` builds again and again with no machine. Each compares each output, not only the module: a difference in the LLVM IR or in the object is an early sign. When an output differs, each distinct result stays in `build/different_builds/<owner>/<file name>.variant_<n>`, and the tool prints where the first difference is.

A distinct result is not a version of a module: it is a fault of the build to correct.

The design: `docs/REPRODUCIBLE_BUILD.md`, "6. What is proved, and what is not", and `docs/PROPERTIES.md`, "Reproducible system".

Do not use: variant (except in the names of the kept files), version.

### Storage service

The storage service is the service that keeps the stores, their trees, their objects and their versions on the data disk, through the block service of that disk.

The storage service is the one program that writes the data disk. Each other program reaches its own store through a connection that the root service gives, with a limit of blocks; each change is one commit, on the disk when the call returns. The service writes the format `STORAGE4` of `contract/store`, with copy on write and two places for the root block, so a stop of the machine never shows a part of a commit.

At its start, it opens the disk: it reads both root blocks, takes the valid one with the highest generation, walks each node and each block tree once, checks each block, and counts the names of each block. Its line says what it found: "storage: ok, generation 1027: 3 stores, 4 objects, ...", or "storage: ok, a new disk: generation 1, 16384 blocks" on an empty disk. Its exports include `open`, `close`, `add`, `write`, `read`, `read_range`, `write_range`, `set_size`, `commit`, `list`, `rename`, `remove`, `share`, `unshare`, `usage`, `stores`, `open_store`, `versions`, `version`, `restore`, `clone` and `compare`.

The storage service is not a file system: it has no paths, no mount, and no global tree of names that a program can walk.

The design: `docs/STORAGE.md`, "4. The interface of the service", and `docs/ARCHITECTURE.md`, "U5. Storage service".

Do not use: file system.

### Root block

The root block is the block of the data disk that names each store, with the generation of the last commit; the disk has two places for it.

The root block makes a commit atomic. A commit writes each new block to a free block, asks the disk to keep it (`Flush`), then writes the root block in the place of the older of the two roots. The root has its own check. At the start, the storage service takes the valid root with the highest generation: a root that a stop of the machine cut is not valid, and the root before it names blocks that no commit changed.

The root block (`Root` of `contract/store`) holds the mark `STORAGE4`, the generation, the count of blocks of the disk, the time since the format, the date, and one store entry for each of up to 60 stores. Blocks 0 and 1 are its two places. Example of a log line: "storage: the newest root names a block with a wrong check, and the root before it names none: the root before it is used".

The root block is not a superblock that a program can read: only the storage service and the kernel tool read it.

The design: `docs/STORAGE.md`, "3.3 The commit and the open", and `contract/store`.

Do not use: superblock, uberblock, meta page.

### Commit

A commit is one change of the stores that is on the disk completely or not at all: new blocks first, then a new root block.

The commit is the unit of change and the unit of history: each commit that changes an object makes a version, and each commit has its own generation. Each export that changes something is one commit, on the disk when the call returns: `write`, `add`, `rename`, `remove`, `restore`, `clone`, and `commit` for pending changes. A commit plans its work in memory first (the blocks to write, the counts to change, the versions to thin); a refusal drops the plan and changes nothing.

A commit has fixed capacities (the blocks whose names it changes, the blocks that it writes); a commit that needs more is refused with `Full`, unit `Commit_Blocks`, not with a full disk. Example: the export `commit` gives a row with the generation and the measure of the commit: the blocks changed, hashed and written, and the time.

A commit is not a save that a program asks for, and not a transaction that holds several calls open.

The design: `docs/STORAGE.md`, "3.3 The commit and the open".

Do not use: transaction (for this), save, sync.

### Generation

A generation is the number of a commit: each commit has the generation of the commit before it plus 1, on the whole disk.

The generation orders every state on the disk. The root block keeps it, so the start takes the root with the highest valid one. Each entry keeps the generation of its last change, and each version the generation of its commit; `version`, `restore` and `compare` name a version by its generation. Many exports give the generation of their commit as their result.

A generation counts the commits of the whole disk, not of one store: a commit of another program, or of the line history of the console, takes a number too. So a test cannot predict an absolute generation; it reads a base of the generations.

A generation is not a version of an object and not a time.

The design: `docs/STORAGE.md`, "3.3 The commit and the open".

Do not use: epoch, transaction id, version (for this).

### History store

The history store is the store of the line history of the console in the storage service, apart from its private store.

The line history must survive a stop, but the console must not need the grant of its private store, or the grant to act for the principal, for it. So the root service gives the console a second connection (`Root_Command.Connect_History`, the grant `history`): its store is named after the console with `.history` (for example `console.history`), its limit is 4 blocks (`HISTORY_STORE_LIMIT`), and the connection does not act for the principal. One object of one block takes 3 blocks, and a change of it needs one more block in the commit that thins the version before: 4 is the least limit with which the history can change.

The history store is not a file of a shell in a home folder: no other program reads it, and `revoke("console", "history")` ends it.

The design: `docs/CONSOLE.md`, "6. The line history across a stop".

Do not use: shell history file, profile directory.

### Base of the generations

The base of the generations is, in a machine test, the generation of one commit that a step `Generation` reads from the log, so that the steps after it name the generations that they wait for as the base and a count.

A generation counts the commits of the whole disk, and the console commits its line history after each line: an absolute generation in a test changes with each line before it. So a step `Generation` waits for a line of the log and keeps the number in it; a later step names `{generation}` or `{generation+4}` in its text or its expected text. A step that names `{generation}` before any step `Generation` stops the test.

The base of the generations is not an offset of a file: it is a number of the kernel tool, not of the system.

The design: the step `Generation` of `tools/kerneltool/machine.odin`.

Do not use: offset, delta.

### Damaged object

A damaged object is an object whose state names a block with a wrong check under a valid root block: the storage service does not give its bytes.

Damage is a change on the disk that the service did not make. The open of the disk checks each block that a root names. A wrong object node or a wrong block of data damages the state of the object that names it only: a read gives `Damaged`, and the other objects of the store are served. A write or a remove of the object replaces the damaged state; it is not kept as a version. A wrong node or a wrong store block damages its whole store: the service gives nothing of that store and changes nothing in it. Example of the line: "storage: 1 blocks have a wrong check: 1 objects and 0 stores are damaged; the service serves the others".

A damaged object is not a bad sector: the device reported no error, and the check found the damage.

The design: `docs/STORAGE.md`, "3.3 The commit and the open".

Do not use: corrupt file, bad sector.

### Check

A check is 8 bytes of a hash of a block, kept in the pointer that names the block: a block that does not have its check is not used.

The check finds each change of a block that the storage service did not make, and each block that a cut commit left. A pointer is a block number and a check. The check of a block of data is the first 8 bytes of its value; the check of each other block is the first 8 bytes of the BLAKE3 hash of its 4096 bytes. The root block has its own check, over the bytes before it. The open reads each block that a root names and compares its check.

A check is not a checksum of the device, and not a CRC: it is a cryptographic hash, and it is kept in the block above, not in the block itself.

The design: `docs/STORAGE.md`, "3.1 The blocks".

Do not use: checksum, CRC, digest.

### Block tree

A block tree is the blocks of one state of an object: its blocks of data, where the block n holds the bytes from n × 4096, and the object nodes above them.

The block tree makes a large object cheap to change: a commit of K changed blocks writes those K blocks and the object nodes on their paths, and names each other block of the state before. An object holds up to 4 TiB, five levels of object nodes of 64 children. The level of the root comes from the size: level 0 when the object has at most one block, and then the root is that block of data; else the least level whose node covers each block. A block of zero bytes is a hole and is not in the tree. An entry with each byte zero names no block at all.

A program never sees the block tree: it reads and writes bytes and ranges. The entry of an object and each version name the root of a block tree; two states share the blocks that neither changed. Example: an object of 8 GiB written by three range writes holds 13 blocks.

A block tree is not an extent tree: it names each block of data by its place, with no runs of blocks.

The design: `docs/STORAGE.md`, "The block tree".

Do not use: extent tree, block map, list of blocks.

### Object node

An object node is one block of a block tree above the blocks of data: 64 children, each an object node of the level below, a block of data, or a hole.

Each child holds its block number, its check, the count of blocks under it (itself included), and its value. 64 is a power of two, so an object node covers a whole subtree of the BLAKE3 tree of the bytes, and its value is the parent of the values of its children. An object node starts with the mark "BLOB". A child whose blocks start at or past the size is a hole, and a node with no child is a hole too. The open checks an object node by its check, by the rules of its format, and by the counts and the values of its children.

An object node is not a node: a node is a block of the B+ tree of a tree, and holds entries. It is not an indirect block of a file system either: it carries the value of each child, so the hash of the object comes from the nodes.

The design: `docs/STORAGE.md`, "The block tree".

Do not use: indirect block, extent node, node (for this: a node is of a tree).

### Hole

A hole is a part of an object whose bytes are all zero: nothing names it, it costs no block, and it reads as zero bytes.

Holes let an object have a large size and few blocks. The service never writes a block of zero bytes: a write that leaves one makes a hole, so the blocks of a state come from its bytes alone, and the open takes a block of data of zero bytes for damage. A hole has the value zero, and two halves of value zero give zero, so a hole costs nothing in the hash of the object either. A hole counts no block in the limit of the store. Example: `read_range` across a hole gives zero bytes; an object of 8 GiB with three blocks of data counts 13 blocks.

A hole is not a reserved area: a write in a hole takes new blocks at its commit.

The design: `docs/STORAGE.md`, "The block tree".

Do not use: sparse region, gap, zero block (for this).

### Value

A value is the BLAKE3 chaining value of a part of an object, as a subtree of the BLAKE3 tree of its bytes, with zero bytes past its size; a hole has the value zero.

Values let the storage service compute the hash of an object from the blocks that a commit changed, not from the whole object. The value of a block of data is the chaining value of its 4 chunks of 1 KiB at its place in the object: its first 8 bytes are the check of the block. The value of an object node is the parent of the values of its children, two by two, and each object node keeps the value of each child. A value is 32 bytes (`Block_Value` of `contract/store`).

A value is not a hash of a block alone: BLAKE3 puts the place of each chunk in its compression, so the same bytes at two places have two values.

The design: `docs/STORAGE.md`, "The block tree", and `docs/STORAGE.md`, "The hash of an object".

Do not use: digest, checksum, fingerprint.

### Hash of an object

The hash of an object is its name: the BLAKE3 hash of its bytes, except that a hole before its last block counts with the value zero.

The hash comes from the values on the path of the last block and the bytes of the last block, so a commit never hashes the whole object: at most 64 parent compressions for each level, and the bytes of the last block. For an object of at most 4096 bytes, or with no hole before its last block, the hash is exactly the BLAKE3 hash of its bytes; the host tests compute the official vectors of BLAKE3 through the block tree. With a hole before the last block, the hash differs from the BLAKE3 hash of the bytes. It is still a function of the bytes alone, because a block of zero bytes is always a hole. The entry of the object keeps it.

The hash of an object is not always the hash of a module: a module file with an aligned block of 4096 zero bytes before its last block has another hash as an object. Which of the two names a module in the store is not decided.

The design: `docs/STORAGE.md`, "The hash of an object".

Do not use: content id, checksum (for this).

### Range

A range is a count of bytes from an offset of an object.

Ranges let a program read and change a part of a large object with no copy of the rest. `storage.read_range(place, name, offset, result)` reads the bytes from `offset` up to the end or the room of the result, with the pending changes of the connection; a hole reads as zero bytes. `storage.write_range(place, name, offset, data)` changes one range as a pending change; `storage.set_size` changes the size the same way. `storage.compare` gives the ranges that differ between two states. The data of one call is at most the call region, 64 KiB. Example: the program `ranges` makes 1000 writes of 16 bytes at scrambled places of an object of 8 GiB, then one commit.

A range is not an extent of the disk: it is a part of the bytes of an object, and says nothing of its blocks.

The design: `docs/STORAGE.md`, "Ranges".

Do not use: extent (for this), segment, slice (for this).

### Pending change

A pending change is a range write or a change of size that the storage service keeps for one connection until its commit: not on the disk, and not hashed.

Pending changes group many small writes into one commit, which is one version. The service keeps a copy of each changed block as the connection sees it. A read of the connection sees its pending changes; another connection sees the last commit. `storage.commit(place, name)` makes the pending changes of the connection on the object one commit. The pending changes of all the connections hold at most 1024 blocks (4 MiB) and 16 objects; a range write past that is refused with `Full`, unit `Pending`, and the caller commits first.

Another change of the object before the commit (a write, a restore, a remove, a rename, or a commit of another connection) comes first: the commit is then refused with `Absent`, unit `Pending`, and the pending changes are dropped. A loss of power loses the pending changes and nothing else. The end of a connection drops them.

A pending change is not a dirty page of a cache that the system writes later by itself: only a commit of the program writes it.

The design: `docs/STORAGE.md`, "Ranges".

Do not use: dirty page, write buffer, uncommitted write, transaction (for this).

## Desktop

### Surface

A surface is a memory object that one program draws into and the compositor shows as the content of a window.

A surface keeps the pixels out of the kernel and out of the rings: the program writes pixels in its own memory, and the compositor reads the same memory. No pixel goes through a ring or through the kernel.

A program opens a surface with `display.open(ctx, width, height, title, two_pictures)`. This needs the grant of the display, a ring to the compositor in its context; without it the call fails with `No_Grant`. A width or a height is 1 to 2048 pixels (`SURFACE_LIMIT`). The call makes a memory object for one picture or two, maps it, gives the compositor a handle with **Read** only through the ring, and sends `Surface_Create`. Then the program draws a picture and sends `Present` with the rectangle that changed. The compositor sends the input of the window back as completion records of the same ring: keys, pointer events, and `Settings_Changed`.

A surface is not a framebuffer: the framebuffer is the memory of the screen that the firmware gave, and only the compositor writes it. A program cannot write another program's surface or the screen.

The design: `docs/DESIGN.md`, "3. Surfaces", and `docs/ARCHITECTURE.md`, "U8. Graphics: WebGPU library and compositor".

Do not use: window buffer, framebuffer (reserved for the UEFI one).

### Picture

A picture is one complete image in the memory of a surface; a surface has one picture or two.

With one picture, the compositor can read the picture while the program draws, and the screen can show a part of the new image with a part of the old one. With two pictures, the program draws one while the compositor reads the other, and `Present` names the picture that is complete; the next frame draws in the other one. A program asks for two pictures with the argument `two_pictures` of `display.open`. The interface package keeps one draw table for each picture, because the picture that a frame draws holds the frame of two frames before.

A picture is not a picture resource or a picture record: a picture record shows pixels of a picture that the program holds in its own memory, inside its surface.

The design: `support/display`, and `docs/INTERFACE.md`, "2.2 Damage by difference".

Do not use: back buffer, front buffer, swap chain.

### Compositor

The compositor is the service that owns the display: it combines the surfaces of the programs into the framebuffer and routes the input to the program that has the focus.

The compositor is the one program that writes the screen. The root service gives it the framebuffer, a ring to the input service, and a ring to each program with a surface (`Client_Add`). It draws the background, the bar, each window (a title bar over the surface of its program, with a border), the two menus of the bar, the launcher and the pointer. It draws again only the damage rectangles of a frame. It sends each key to the program in front, and each pointer event over a surface to the program of that surface, in the coordinates of the surface.

In the first version, it is also the desktop shell: it starts a program from its menus or the launcher by the command `Start` to the root service, and it stops a program when its window closes. It serves exports, such as `compositor.pointer()`, which the machine tests read through the remote service.

The compositor is not a window manager that another program can replace, and not a display server with a protocol of drawing: a program gives it pixels, never commands to draw.

The design: `docs/ARCHITECTURE.md`, "U8. Graphics: WebGPU library and compositor", and `docs/DESIGN.md`, "9. The desktop".

Do not use: window manager, display server.

### Damage rectangle

A damage rectangle is a rectangle of the screen or of a surface that changed and that the next frame draws again.

To draw only what changed costs much less than to draw the whole screen. The compositor keeps up to 8 damage rectangles (`DAMAGE_CAPACITY`): a rectangle that touches another joins it, and with no room left a new rectangle joins the first one. A program sends the rectangle that changed in its picture with `display.present_rectangle`, and the compositor draws again only that part of the window. The interface package finds the damage rectangles of a window itself, by damage by difference.

A damage rectangle is never too small: if a rule cannot say what changed, the damage is larger, and only the time grows.

The design: `docs/INTERFACE.md`, "2.2 Damage by difference".

Do not use: dirty region, invalid area.

### Boot display

The boot display is the picture of how the machine started, drawn from the boot record and the other records of the kernel.

The boot display shows each stage of the start and its time, the memory that the firmware gave, the firmware, the framebuffer, the processors, the programs and the modules of the boot image. Three programs draw it with one package, `support/bootscreen`: the boot program before the kernel exists; the root service while it starts the first programs, so that a failure of the start stays on the screen with its cause; and the program `boot`, in a window at any time. A record that is all zero is valid: its card shows that the fact is not known yet.

The boot display is not a splash screen and not a log of text: it is made of cards with measures, and it follows the design rules.

The design: `docs/DESIGN.md`, "12. The card of the boot image", and `docs/ARCHITECTURE.md`, "U1. Boot program".

Do not use: splash screen, boot log, POST screen.

### Console

The console is a normal program that calls commands, functions with typed parameters and a typed result, in a small programming language.

The console replaces the shell: a command is an export of a module, not a program that parses text, so its arguments and its result are typed values. The console has a terminal and no surface: it writes text records to the terminal ring, and reads key records from it. It owns the edit line, the line history, and the completion list; the terminal draws them. It has two threads: one reads the keys, the other runs the lines, so the input can type during a line and Escape stops an isolated call. Examples: `grants("notes")` shows the grants of a program; `load("calendar")` loads a module into the console and calls its exports directly; `isolate("calendar")` starts it as its own program.

The console acts for the principal of its session. It is not a TTY and not a shell: it starts no program by a path, passes no text between programs, and has no pipe.

The design: `docs/CONSOLE.md`, "1. The keys", and `docs/PROPERTIES.md`, "A command is a function: no text between programs".

Do not use: TTY, shell.

### Desktop shell

The desktop shell is the program that starts programs and shows their windows to the principal.

In the first version, the compositor is the desktop shell: its bar has the menu of the programs and the menu of the windows, the launcher starts a program by a key, and the close button of a window stops its program. The compositor starts a program by the command `Start` to the root service, with the name of the program, and has no other power: the root service decides the grants of the program. The design also gives the desktop shell the list of the grants of each program; today the console shows them, with `grants`.

The desktop shell is not a window manager with rules of placement: the compositor places new windows at fixed steps on the grid.

The design: `docs/ARCHITECTURE.md`, "U10. Desktop shell".

Do not use: window manager.

### Focus

The focus is the state of the window in front: its program receives the keys, and its title bar shows it in blue.

The focus decides where each key goes. A press on a window brings it to the front and gives it the focus; a line of the menu of the windows does the same. The compositor sends the keys only to the program that has the focus, and sends a pointer event to the program of the surface under the pointer. While the launcher is open, no program receives a key or a pointer event. The key super never reaches a program: the compositor keeps it.

Inside a window, the interface package has a focus of its own: the element that takes the keys, which Tab and Shift+Tab move. The two are different: the focus of the compositor chooses a window, the focus of the interface state chooses an element in it.

The focus is not an active window that a program can take: no program can give itself the focus.

The design: `docs/DESIGN.md`, "Windows", and `docs/INTERFACE.md`, "4. Input and focus".

Do not use: active window, keyboard owner.

### Title bar

The title bar is the top part of the frame of a window, 24 pixels high: the title and the close button.

The title bar says which window has the focus. The title bar of the window that has the focus goes from the blue `0x3F7CC4` at its left to a darker blue at its right, and its title is white. The title bar of another window is quiet: a dark grey gradient and a dim title. The close button is a square of 24 pixels at its right end, with the character `x` in a deep red, the color of the concept "stop a program"; a press on it stops the program of the window. A press on the title bar and a move drag the window, and the pointer shape over it is `move`.

The title bar is drawn by the compositor, not by the program: a program cannot draw its own title bar or hide the close button.

The design: `docs/DESIGN.md`, "Windows".

Do not use: header, caption, decoration.

### Bar

The bar is the line at the top of the screen that the compositor draws: the mark of the system, the buttons of the two menus, the key of the launcher, and the time since the start.

The bar is the fixed place of the desktop where the input starts a program or finds a window. It is 32 pixels high. From the left: the mark of the system, the button `programs`, the button `windows`; at the right, "launcher: super" and the time since the start of the machine. A press on a button opens its menu under it. `support/bar` holds the places of the buttons and of each line of the menus, and the table of the names of the programs, `bar.names`: the compositor draws from it, and the kernel tool presses the same places in the machine tests.

The bar is not a task bar with an icon for each program, and not a dock: it holds two menus and no state of a program.

The design: `docs/DESIGN.md`, "Background and bar".

Do not use: task bar, panel, dock.

### Bar layout

The bar layout is the widths of the texts of the bar, measured in the font that draws them, from which come the place of each button and of each line of a menu.

The names of the bar are in the interface font, which has proportional widths. If the places came from a fixed width, a press can land beside the entry that the eye sees. So the compositor measures `bar.Layout` (the width of `programs`, of `windows`, and of the widest name) once, and again when the font changes. It writes which font it used in its log, such as "compositor: the bar is in the interface font: programs ... pixels, windows ..., the widest name ...", or "compositor: the bar is in the font of the cells". The kernel tool measures the same layout from the same glyph cache, so it presses the right places.

The bar layout is not a set of constants: it depends on the font in use.

The design: `support/bar`, and `docs/DESIGN.md`, "Background and bar".

Do not use: bar geometry, bar metrics.

### Menu of the programs

The menu of the programs is the menu of the bar with one line for each name of the table `bar.names`: a press on a line starts that program.

The menu is the way of the pointer to start a program. It is a card under the button `programs`, in two columns, with the caption `bar.names` and the count of its lines. The line under the pointer is a chosen row. A press sends `Start` with the name to the root service, which decides the grants of the program.

The menu of the programs is not the launcher: the launcher lists the same names but is opened by a key and narrows as the input types. It is not a start menu with folders: it has one flat table.

The design: `docs/DESIGN.md`, "Menus".

Do not use: launcher, start menu.

### Menu of the windows

The menu of the windows is the menu of the bar with one line for each window: a press on a line brings the window to the front and gives it the focus.

The menu lists the windows in the order of the client table of the compositor. The window that has the focus has a square of 8 pixels before its title, and its title is white. The menu lets the input reach a window that other windows cover. It does not move a window: a window that a drag put far away comes back by a drag of its title bar, which the compositor always keeps on the screen.

The menu of the windows is not a task switcher with pictures of the windows, and not a task bar.

The design: `docs/DESIGN.md`, "Menus".

Do not use: task bar, window list, switcher.

### Launcher

The launcher is the panel in the middle of the screen that the key super opens, where the input types a part of a name and starts the chosen program.

The launcher is the way of the keyboard to start a program. While it is open it takes each key: a character adds to the typed part, Backspace removes the last one, up and down move the choice, Enter starts the chosen program, Escape closes it. The list has the names of `bar.names` that contain the typed part, without the case of the letters: the names that start with it first, then the others, 10 lines at once, and the count "6 of 31". With no match, the list says `no program has "xyz" in its name`. Enter sends `Start` to the root service, as the menu of the programs does; the launcher has no other power.

The launcher is not a run dialog: it starts only the names of the table, never a path or a command line. It is not the menu of the programs, which the pointer opens from the bar.

The design: `docs/DESIGN.md`, "Launcher".

Do not use: run dialog, command palette, menu of the programs.

### Interface package

The interface package is `support/interface`: the code that builds the window of a program as a draw table at each frame, lays it out on the grid, takes the pointer and the keys, finds the damage, and draws.

The interface package gives each program one way to draw its window by the design rules, with no retained tree of widgets. It works in immediate mode: at each frame, the program calls an element procedure for each part of its window (`card`, `label_value_line`, `button`, `list_with_choice`, `text_input`). Each call appends draw records to the draw table and gives back what the input did to that element: pressed, has the focus, changed. Then `damage_by_difference` finds what changed, and `execute_in_rectangles` draws it.

The package allocates nothing: the program gives the draw tables, the text tables and the interface state. An error is a value: a full table keeps the flag `full`, and the next frame of that picture is drawn whole. Its core makes no kernel call. Example: the programs `disk`, `inspect` and `monitor`, and the launcher of the compositor, are drawn with it.

The interface package is not a toolkit with objects, callbacks and a tree; its state is the state of the program.

The design: `docs/INTERFACE.md`, "2. The model: an immediate pass over flat tables".

Do not use: toolkit, widget library, UI framework.

### Draw record

A draw record is one thing to draw, in 40 bytes: a rectangle, a gradient, a run of text, a clip, a picture, a text grid or a line, with its place and its colors.

Records of one fixed size make the output of a frame plain data: a table that can be compared, measured, drawn again in a part, or tested. A record holds its kind, the rectangle in pixels of the surface, two colors, a range of bytes in the text table (or an index of a picture or of a grid), and the low 32 bits of the element identity that wrote it. A `Clip` sets the rectangle that the next records are cut to, with no stack. The format has a version, `DRAW_RECORD_VERSION` (7 today); a new kind or field is a new version. The execution checks each record of a hostile caller: a range outside the text table, or a value past its limit, draws nothing.

A draw record is not a command to a graphics processor: the interface package executes it on the processor, in the memory of the program.

The design: `docs/INTERFACE.md`, "2.1 Draw record (format version 7)".

Do not use: draw command, display list item, primitive.

### Draw table

A draw table is the draw records of one frame of a window, the bytes of their texts, and the pictures and text grids that they name, in the memory of the program.

The draw table is what a frame produces. The program owns it (`Draw_Table` of `support/interface`) and keeps the table of the frame before, one for each picture of its surface, so that the next frame can find the damage by difference. A table that is full stops taking records and sets `full`; a record that names a picture or a grid that the table does not have sets `refused`. Example: `interface_elements` draws a window of 68 records.

A draw table is not a tree: its order is the order of the drawing, and two tables compare record by record at the same index.

The design: `docs/INTERFACE.md`, "2.1 Draw record (format version 7)".

Do not use: display list, command buffer, render tree.

### Text grid

A text grid is a grid of text cells of a program (a character, reverse, a color, or a fill), drawn by one draw record.

A terminal changes many cells many times in one second. One record for each cell makes a large table; one text grid record names the whole grid, up to 104 by 32 cells for the terminal. Its 40 bytes do not change when its cells change, so the difference compares the cells: in each row, the span from the first changed cell to the last one is damaged. Each draw table keeps its own copy of the cells that its picture shows. The execution draws the cells of one color that follow each other as one text. The console draws no pixels: its records go into the terminal, so the text grid of the terminal is also the drawing of the console.

A text grid is not a screen buffer of a text mode: it is memory of the program, drawn into its surface.

The design: `docs/INTERFACE.md`, "2.4 Text grid".

Do not use: character matrix, screen buffer.

### Picture record

A picture record is a draw record that shows the pixels of a picture of the program, with a generation that changes when the pixels change.

A program that computes its own pixels, such as `life`, `paint`, `plasma` or `temple`, puts its image in a draw table as one record. The record names the index of the picture in the pictures of the draw table and its generation. The program raises the generation when its pixels change; with the same generation the record compares equal and damages nothing. The compositor draws the surface of each window as a picture record too.

A picture record is not a picture of a surface: it shows a canvas that the program holds, inside its surface.

The design: `docs/INTERFACE.md`, "2.1 Draw record (format version 7)".

Do not use: image node, bitmap item.

### Line record

A line record is a draw record of a straight line between two points, with a thickness of 1 to 32 pixels and one color.

A line record draws the lines at an angle that the design rules allow, sparingly: a folded gap, a chart. `draw_line(table, from_x, from_y, to_x, to_y, thickness, color)` writes it, the left end first, so a line and its reverse are one record and draw the same pixels. The pixels follow the line of Bresenham with a square of the thickness at each point, so the execution in a damage rectangle draws the same pixels as a whole frame. Its damage is the rectangle that holds the whole path. A thickness of 0 or less, or an end past 32768 pixels, gives no record.

A line record has no rounded ends, no antialiasing and no dashes. It is not a path with curves.

The design: `docs/INTERFACE.md`, "2.5 Line".

Do not use: stroke, path, polyline.

### Element

An element is a part of a window that one call of the interface package draws: a card, a line of a label and a value, a bar, a table, a button, a list with a choice, or a text input.

An element is a call, not an object: the program calls it at each frame with its area and its data, and gets back an `Element_Result` (pressed, has the focus, changed). An element that takes input also takes an element identity, so the interface state can follow it from one frame to the next. Example: `button(frame, area, identity("start"), "start")` draws a button and says if the input pressed it in this frame.

An element is not a widget: it does not live between frames, has no callback, and holds no copy of the data of the program.

The design: `docs/INTERFACE.md`, "2. The model: an immediate pass over flat tables", and `docs/DESIGN.md`, "10. Elements".

Do not use: widget, control, component, view.

### Element identity

An element identity is a number that names one element from one frame to the next, made from a text: the focus and the state of the pointer follow it.

In immediate mode no object lives between frames, so the interface state needs a stable name for each element that takes input. `identity("launcher list")` gives the 64-bit FNV-1a hash of the text. Two elements with one text have one identity; `identity_with(base, row)` and `identity_in(parent, name)` make them two, and `Frame.identity_collisions` counts the elements of a frame that repeat an identity. Each draw record keeps the low 32 bits of the identity that wrote it, so a tool can say which element changed.

An element identity is not a handle: it names nothing in the kernel and gives no access.

The design: `docs/INTERFACE.md`, "4. Input and focus".

Do not use: id, key, handle (reserved for the kernel).

### Interface state

The interface state is what the interface package keeps between frames, in the memory of the program: the element with the focus, the element under the pointer, the pressed element, and the order of the focus.

The interface state is the only state of the package, about 2 KiB, and the program owns it. With it, a press and a release on one element press that element, and Tab and Shift+Tab move the focus in the order of the elements of the last frame. The order holds 64 elements (`FOCUS_ORDER_CAPACITY`); an element after them takes a press but not Tab, and `Frame.focus_overflow` counts them.

The interface state is not a retained tree of the window: it holds element identities only, and no copy of the data that the window shows.

The design: `docs/INTERFACE.md`, "4. Input and focus".

Do not use: UI context, retained state.

### Damage by difference

Damage by difference is the damage rectangles that the interface package finds by a comparison of the draw table of this frame with the draw table of the frame before.

Immediate mode has no tree whose nodes know what changed. The difference gives that back: `damage_by_difference` compares the two tables record by record at the same index. Two equal records (the same 40 bytes and the same bytes of text) damage nothing; two different records damage the old rectangle and the new one; the records after the end of the shorter table are damaged. The program never tracks damage by hand. A record added in the middle moves the records after it, so the damage is too large, never too small. Example of a measure of `interface_elements`: on 68 records, the difference takes about 1 us.

Damage by difference is not an invalidation that a program calls: no call says what changed.

The design: `docs/INTERFACE.md`, "2.2 Damage by difference".

Do not use: dirty tracking, invalidation.

### Pointer

The pointer is the mark on the screen that the pointing device moves: a press acts at its place.

The compositor draws the pointer last, with the pointer picture of the pointer shape that it chose for the place, and puts the hot spot of the picture at the place of the pointer. It sends each pointer event to the program of the surface under the pointer, in the coordinates of the surface. In a machine test, `compositor.pointer()` gives the place and the shape of the pointer, so the kernel tool can confirm a place before a press.

The pointer is not the caret, which marks a place in a text. The system does not use the word "cursor" for either one.

The design: `docs/DESIGN.md`, "Pointer", and `docs/POINTERS.md`.

Do not use: cursor, mouse cursor, mouse pointer.

### Pointer shape

A pointer shape is what the pointer shows, as one name of the system: `arrow`, `text`, `pointing_hand`, `move`, `wait`, and ten more.

One list of names lets any theme serve each program: a program asks for a name, and the theme gives the pictures. The 15 shapes are `Pointer_Shape` of `contract/pointer_pictures`; zero is `arrow`, so a zero record asks for the default. The compositor chooses the shape from what is under the pointer: `move` over a title bar, `pointing_hand` over a button, `text` over the input line of the launcher. A program asks for a shape over its own surface with `display.pointer_shape_set`; the compositor shows it only while the pointer is over that surface and that surface is in front there, so a program cannot change the pointer over another program, the bar or a frame. A number outside the list is ignored.

A pointer shape is not a file name of a theme: the manifest of a theme maps each shape to its sources.

The design: `docs/POINTERS.md`, "The pointer shapes".

Do not use: cursor type, cursor name, cursor kind.

### Pointer picture

A pointer picture is one image of one pointer shape at one nominal size, for one frame of an animation: its width, height, hot spot, delay and pixels with premultiplied alpha.

A pointer theme file holds the pictures of each shape: the frames of the smallest size, then of the next. A picture is 1 to 256 pixels wide and high, and its hot spot is inside it. An animated shape has 1 to 256 frames with a delay of 1 to 60000 ms each; `wait` in the theme of the system has 4 frames of 250 ms. The compositor blends the picture over the screen with premultiplied alpha.

A pointer picture is the one picture of the desktop that is not made of rectangles: the pictures of the Posy theme have smooth edges and transparency.

The design: `docs/POINTERS.md`, "3. The format of the system: one pointer theme file".

Do not use: cursor image, sprite, icon.

### Hot spot

The hot spot is the pixel of a pointer picture that the compositor puts at the place of the pointer.

A press acts at the place of the pointer, so the hot spot is the pixel that "points": the top left square of the arrow, the centre of a crosshair. Each pointer picture has its own hot spot, inside its width and its height. A manifest gives it with `hot` in pixels of the smallest size, or in squares for a grid; the tool multiplies it for the other sizes.

The hot spot is not the top left corner of the picture, except for the arrow.

The design: `docs/POINTERS.md`, "3. The format of the system: one pointer theme file".

Do not use: click point, hotspot, anchor.

### Nominal size

A nominal size is the size in pixels that a theme gives to a pointer picture, to choose among its sizes.

A theme has 1 to 8 sizes for each shape, in increasing order: the theme of the system has 24 and 48, the Posy theme 32 and 64. The frames of one size share one nominal size. The width and the height of a picture can differ from its nominal size.

A nominal size is not the width of a picture, and not a scale of the screen.

The design: `docs/POINTERS.md`, "3. The format of the system: one pointer theme file".

Do not use: cursor size.

### Pointer theme

A pointer theme is the pointer pictures of each pointer shape, with a name, a license and an attribution.

The system has two themes:

- the theme of the system (`resources/pointers/system.manifest`): the 15 shapes as grids of squares of 2 pixels, in the style of the arrow of the design rules. It is always in the boot image, as the resource `pointers_system`.
- the Posy theme, "Posy's Cursor", from the build input `posy-cursors`: the tool converts it at each build into the resource `pointers_posy`. No file of it is in the repository.

The Posy theme is the default when the build has its input; the theme of the system is the fallback. The setting `pointer_theme` chooses one of them.

A pointer theme is not an icon theme: it holds the pictures of the pointer only.

The design: `docs/POINTERS.md`, "5. The two themes".

Do not use: cursor theme, icon theme.

### Pointer theme file

A pointer theme file is one pointer theme in the format of the system: a header, a table of shapes, a table of pictures, then the pixels.

One file for a whole theme lets a program map it read-only and read it in place, with no parse at run time. The format is `contract/pointer_pictures`: a header of 512 bytes (the mark "POINTERS", the version, the counts, the name, the license, the attribution), one shape entry of 16 bytes for each shape, one picture entry of 32 bytes for each picture, then the pixels. One function, `pointer_pictures.validate`, checks every field once; the tool and the compositor run it, and the compositor does not trust the file even from the root service. A failure gives a `Problem` with the table, the index, the field, the value and its limit.

A pointer theme file is not an Xcursor file or a `.cur` file: the tool reads those formats only to make this one.

The design: `docs/POINTERS.md`, "3. The format of the system: one pointer theme file".

Do not use: cursor file, .cur, Xcursor file (for this).

### Pointer manifest

A pointer manifest is a text file of the repository that says how the tool makes a pointer theme file: for each pointer shape, the files of an Xcursor theme or grids of squares, and the adjustments.

The manifest keeps the choices about a theme in text that a reader can review, with no JSON and no general parser. It has the statements `theme`, `license`, `attribution`, `sizes`, `shape`, `frame`, and lines of a grid that start with `|`. A shape has sources or a grid, not both. `kerneltool pointers` reads it and writes the pointer theme file. An error gives the file, the line, the column and what was expected: `resources/pointers/posy.manifest:12:7: expected a pointer shape name such as "arrow"; found "arow"`.

A pointer manifest is not the `index.theme` of an icon theme: the system reads no file of a theme at run time.

The design: `docs/POINTERS.md`, "4. The manifest".

Do not use: config, recipe, index.theme.

### Premultiplied alpha

Premultiplied alpha is a form of a pixel whose red, green and blue are already multiplied by its alpha.

With premultiplied alpha, a blend is one multiplication for each channel: `result = source + destination * (255 - alpha) / 255`. Straight alpha needs three more multiplications for each pixel. The pixels of a pointer theme file are `0xAARRGGBB` with premultiplied alpha, the form of an Xcursor file, so the tool converts nothing. The validation refuses a pixel with a channel above its alpha.

Premultiplied alpha is not straight alpha: a straight pixel with alpha 0 can hold any color, and a premultiplied one is all zero.

The design: `docs/POINTERS.md`, "3. The format of the system: one pointer theme file".

Do not use: straight alpha (for this).

### Resource

A resource is a file of the boot image that is not a module: data that a program reads in place, named by the hash of its bytes.

The resources are the pointer theme files, the glyph caches of the vector font and of the interface font, and the system description with its signature. Each one has a name of 31 bytes at most and the BLAKE3 hash of its bytes in the resource table of the boot image, after the table of the modules, so a reader of modules never takes a resource for a module. No program reads the resource table by itself: the root service finds a resource by its name, checks its hash, and gives one program a read-only mapping of it. Example of the log: "root: the resource pointers_posy (883008 bytes, its hash checked in 1395 us) is given to compositor, read-only". A program with the grant `Image` finds resources with `system.image_resource_find`.

A resource is not an asset that a program loads by a path: it has no path, and the program validates its bytes with the reader of its format.

The design: `docs/ARCHITECTURE.md`, "U2b. Resources of the boot image".

Do not use: asset, data file, blob.

### Caret

The caret is the mark in a text input of the place where the next typed character goes.

The caret shows where the keys act. In the launcher it is a bar of 2 by 16 pixels in the blue of the title bar; in the edit line of the console the line editor keeps its place. A text input shows the caret only when it has the focus.

The caret is not the pointer: the pointer follows the pointing device, the caret follows the keys. The system does not use the word "cursor" for either one.

The design: `docs/DESIGN.md`, "Launcher".

Do not use: cursor, text cursor, insertion point.

### Picker

The picker is the surface of the document service where the principal chooses a document; its result is a grant to the program that asked.

The picker makes the choice of the principal the grant: a program cannot list documents, and gets a handle to the one document that the principal chose. The document service records each grant, so that the principal can list and revoke it. The document service and its picker are not built.

The picker is not a file dialog that a program draws: it is the surface of another program, so the program that asks sees only the result.

The design: `docs/ARCHITECTURE.md`, "U6. Document service".

Do not use: file dialog, powerbox.

## Text

### Font

A set of glyphs of one design, with the measures that place them. The system has two: the vector font of the glyph cache (the default) and Spleen 8x16 (the fallback) (`docs/FONTS.md`).

Do not use: typeface (for this), font face.

### Glyph

The form of one character in one font.

Do not use: character (for the form), symbol.

### Outline

The closed contours of line segments and quadratic curves that bound a glyph, in units of its font (TrueType `glyf`).

Do not use: path, vector shape, Bézier.

### Coverage

The part of a pixel, or of a third of a pixel, that a glyph covers: 0 to 255.

Do not use: alpha (for this), opacity, mask.

### Subpixel band

One of the three color stripes of a pixel of the screen, red, green and blue, side by side; the vector font has a coverage for each one.

Do not use: subpixel, ClearType, LCD stripe.

### Grid fit

The move of the baseline, the x-height and the cap height of a font onto whole pixels, so that the tops of the letters are sharp. The system has no other hinting.

Do not use: hinting (alone), autohint.

### Glyph cache

The glyphs of one font already drawn, for each character 32 to 126 and each scale of the grid: words of coverage, in one file (`contract/glyph_cache`). The kernel tool makes it at build time; it is a resource of the boot image.

Do not use: atlas, texture cache, glyph bitmap.

### Proportional cache

A glyph cache with `FLAG_PROPORTIONAL`: each character has its own advance, each glyph is the box of its ink at each subpixel position, and the cache has the pair adjustments. A cache with no such flag is monospace: one position, each glyph inside its cell, no pair (`contract/glyph_cache`, `validate`).

Do not use: proportional font cache.

### Setting

One choice of the person that changes how the system works for each program: the font, the order of the subpixel bands. The program `settings` changes it.

Do not use: preference, option, configuration.

### Settings page

The one page of the settings of the person (`contract/settings`): the root service creates it; the program `settings` writes it; each program with a surface reads it.

Do not use: registry, config file, dconf.

### Monospace font

A font whose characters all have one advance, so that a text is a row of equal cells: Paper Mono, and Spleen 8x16. The font of the terminal, the console, and each text that a person compares character by character (`docs/FONTS.md`, section 12.6).

Do not use: fixed-width font (for this), terminal font.

### Interface font

The proportional font of the titles, the labels, the buttons, the menus and the bar: B612 (designed, not built; `docs/FONTS.md`, section 12).

Do not use: UI font, system font (for this), sans.

### Interface text

A text that a table draws in the interface font: the draw record `Interface_Text` (version 7), whose rectangle holds its ink margin and whose origin is at a third of a pixel. A text of the font of the cells is the record `Text`.

Do not use: proportional text record.

### Font in use

The font that draws a text of a table: the interface font when the table has it, the setting is the vector font and the text has at most 256 bytes; else the font of the cells. A text is measured in its font in use (`interface.font_in_use`).

Do not use: effective font.

### Advance

The distance from the origin of a glyph to the origin of the next one, before any pair adjustment.

Do not use: width (for this), pitch.

### Pair adjustment

The change of the advance that a font gives for one pair of glyphs that follow each other (`kern` format 0, or a pair lookup of `GPOS`).

Do not use: kerning pair (for this).

### Font feature

A named choice of glyph forms that a font offers in its table `GSUB`, by a tag of four letters: `zero` (the slashed zero), `ss01` (a stylistic set), `numr` (numerators).

Do not use: OpenType feature (for this), font option.

### Single substitution

A lookup of the table `GSUB` that puts one glyph in the place of another (lookup type 1): the feature `zero` of Paper Mono puts the glyph 304 in the place of the glyph 294 of the character 0.

Do not use: glyph swap, alternate.

### Slashed zero

A zero with a stroke at an angle inside it, so that it does not look like the capital O. The character 0 of the system is the slashed zero of Paper Mono (`docs/FONTS.md`, section 6).

Do not use: crossed zero, zero with a slash.

### Text shaping

The step that turns the characters of a text into placed glyphs with a font: here the advances and the pair adjustments only; no ligature, no other script (`docs/FONTS.md`, section 12.3).

Do not use: layout (for this), typesetting.

### Placed glyph

A record of 16 bytes that text shaping gives for one character: the glyph, its x from the origin of the run and its advance, in 1/64 of a pixel.

Do not use: positioned glyph, glyph run entry.

### Ink margin

How far the ink of a text of a proportional font can pass the box that its measure gives, on each side: 2 pixels at scale 1 for B612 (`graphics.PROPORTIONAL_INK_MARGIN`). The damage of a text widens its measured box by it.

Do not use: bleed, overhang (for this).

### Subpixel position

The fraction of a pixel where a glyph starts. The glyph cache of a proportional font keeps each glyph at three: 0, 1/3 and 2/3 of a pixel.

Do not use: subpixel offset, bucket.

### Spacing

The advances of the characters 32 to 126 and the pair adjustments of one font at one scale, in 1/64 of a pixel: the two tables that text shaping reads, from a glyph cache (`support/text_shaping`, `Spacing`).

Do not use: metrics (for this), kerning data.

### Text range

A record that names one text in a table of bytes by its first byte and its count, with its width, which the measure writes (`text_shaping.Text_Range`).

Do not use: span (for this), slice.

### Boot pass

The start of the program `settings` that the root service makes at boot, with no window: it reads the settings kept in its private store, writes the settings page, and stops.

Do not use: init script, startup hook.

### Blend table

The results of the blend in linear light of one text color over one pixel color, for each coverage of each channel, kept in the memory of a program (`graphics.Blend_Tables`).

Do not use: lookup table (alone), LUT.

## Randomness

### Random seed

32 bytes from which a random generator starts. The starter of a program writes the seed of the program in its context values 9 to 12; the root service gathers its own (`docs/RANDOMNESS.md`).

Do not use: entropy (for this), salt.

### Random generator

The record of fixed size in the memory of a program that gives it random bytes: ChaCha20 with fast key erasure (`support/random`). A draw makes no kernel entry and no call.

Do not use: RNG, PRNG, CSPRNG (for this), /dev/urandom.

### Entropy report

What the root service found when it gathered the seed of the system: the sources (rdseed, rdrand, the cycle counter), their good and refused values, and the seed strength.

Do not use: entropy estimate.

### Seed strength

The strongest source that gave all its values to the seed of the system: entropy (rdseed), processor (rdrand), or weak (the cycle counter only, counted as 0 bits).

Do not use: security level.

### Cryptography module

The module `cryptography`: the primitives that the system took from Odin's `core:crypto`, as exports with the memory of the caller and error records (`docs/CRYPTOGRAPHY.md`).

Do not use: crypto library, libcrypto.

### Not authentic

The error kind of a sealed text whose tag, or of a message whose signature, does not verify. The call gives no byte.

Do not use: MAC failure, bad tag.

### Compatibility layer

The packages of `support/cryptography` that give the code taken from Odin the helpers of its origin, over the primitives of this system (`docs/CRYPTOGRAPHY.md`).

Do not use: shim, polyfill.

## QUIC

### Connection identifier

The bytes (0 to 20) by which a QUIC endpoint names a connection in each packet, independent of the addresses (RFC 9000, section 5.1). Each side chooses the identifiers that the other side sends to it.

Do not use: connection ID (in prose), CID.

### Packet protection

The AEAD that encrypts the payload of a QUIC packet and authenticates its header, with the key and the iv of one direction of one encryption level (RFC 9001, section 5.3).

Do not use: encryption (for this), record protection.

### Header protection

The mask that hides the low bits of the first byte and the packet number of a QUIC packet, made from a sample of the protected payload (RFC 9001, section 5.4).

Do not use: header encryption.

### Encryption level

One of the sets of keys of a QUIC connection: Initial (from the connection identifier), Handshake, 0-RTT and 1-RTT (from TLS). Each packet type uses one level.

Do not use: epoch, key phase (for this).

### Packet number space

The sequence of packet numbers that one encryption level uses (Initial, Handshake, application data); a packet number is unique in its space.

Do not use: sequence number (for this).

### Initial packet

The first packets of a QUIC connection, protected with keys that any observer can compute from the connection identifier: they carry the start of the TLS handshake.

Do not use: handshake packet (for this).

### Raw public key

A public key that a TLS peer sends in its Certificate message alone, with no certificate around it: the SubjectPublicKeyInfo of the key (RFC 7250). The other side trusts it when it is the key that its caller pinned.

Do not use: self-signed certificate (for this).

### Pinned key

The one public key that the caller of a TLS client gives it as the key of the server: any other key is refused.

Do not use: trust anchor, root certificate.

### Transcript

The handshake messages of TLS, in order, whose hash the key schedule and the Finished messages use.

Do not use: handshake hash (for the bytes).

### Key schedule

The secrets of TLS 1.3, each one from the one before with HKDF and a transcript hash: early, handshake, master, and the traffic secrets of each side (RFC 8446, section 7.1).

Do not use: key derivation (for the whole).

### Alert

The reason of a failure of TLS, one byte (RFC 8446, section 6). QUIC sends it as the error code 0x100 + alert.

Do not use: TLS error (for this).

### Frame

One unit of the payload of a QUIC packet: a type, then its fields (RFC 9000, section 19). A packet carries one frame or more.

Do not use: message (for this), chunk.

### Ack-eliciting packet

A packet with a frame other than PADDING, ACK and CONNECTION_CLOSE: the peer must acknowledge it.

Do not use: reliable packet.

### Probe timeout

The time after which a side that has no acknowledgement sends one or two probe packets, from the round-trip time and its variation (RFC 9002, section 6.2). It doubles at each timeout without an acknowledgement.

Do not use: retransmission timeout, RTO (for this).

### Congestion window

The most bytes of ack-eliciting packets that a side has in flight. This layer keeps it fixed at 12 000 bytes.

Do not use: send window (for this).

### QUIC stream

One ordered flow of bytes in each direction inside a QUIC connection, named by a stream identifier (RFC 9000, section 2). A connection carries several at once; the bytes of one never wait for a loss of another.

Do not use: channel (for this), substream.

### Stream record

One `quic.Stream` in the table that the caller of a QUIC connection gives: the state and the buffers of one open QUIC stream. Their count bounds the streams that are open at one time.

Do not use: stream slot.

### Limit of streams

The count of QUIC streams that one side allows the other to open since the start of the connection (MAX_STREAMS). A server of this system raises it by one each time a stream of the client ended.

Do not use: stream credit, concurrency limit (for this).

### Implicit open

The open of a QUIC stream by a frame of the peer that names it, or a higher stream of the same kind, before the peer sent anything on it (RFC 9000, section 3.2).

### Flow control limit

The largest offset of data that a side allows the peer to send, for one stream (MAX_STREAM_DATA) and for the connection (MAX_DATA). Data past it closes the connection with FLOW_CONTROL_ERROR.

Do not use: receive window (for this).

### Anti-amplification limit

A server that did not validate the address of a client sends at most 3 times the bytes that it received from it (RFC 9000, section 8.1).

### Address validation

The proof that a client receives at its address: here, a Handshake packet of the client, which needs the keys of the server's flight.

### Handshake confirmed

The point after which a side drops its Handshake keys: a server when the handshake completes, a client when HANDSHAKE_DONE comes (RFC 9001, section 4.1.2).

Do not use: handshake done (for the state).

### Connection record

One `quic.Connection` in a table of a server: all the state of one connection, about 214 KiB, in a mapping of the program.

Do not use: session (for this), socket.

### Version Negotiation packet

The packet with the version 0 that a server sends to a client whose long header names a version that the server does not speak: it lists the versions that the server speaks (RFC 9000, section 17.2.1).

Do not use: version error.

### Retry token

The value that a server gives in a Retry packet and that a client sends back in its next Initial: it proves that the client receives datagrams at its address. This system seals it with a key of the server, over the address and port of the client, its identifiers and a time.

Do not use: cookie (for this), address token (for the token of NEW_TOKEN).

### Validated remote

An admitted remote of a UDP listen grant that the program marked with the command Validate, because it proved its address: the network service then sends to it with no limit of 3 times the bytes that came from it.

Do not use: trusted remote, whitelisted address.

### Stateless reset

A packet that ends a connection whose state a side lost, proven by a token that the side gave before (RFC 9000, section 10.3). Not built.

Do not use: reset (for this).

### Handshake deadline

The time after which a connection whose handshake did not complete ends: 10 s from the start of a client, or from the first authentic Initial at a server.

Do not use: handshake timeout (for the value).

### Packet number floor

The packet number below which a side refuses each packet of a space, because its set of received numbers forgot those ranges.

Do not use: replay window.

### Idle timeout

The time with no packet of the peer after which a side ends a connection with no packet: the smaller of the two that the sides give, and 3 probe timeouts at least.

Do not use: keep-alive.

### Closing state

The state of a side that sent CONNECTION_CLOSE: it answers each packet with it, for 3 probe timeouts.

### Draining state

The state of a side that received CONNECTION_CLOSE: it sends nothing, for 3 probe timeouts.

### Transport parameters

The values that each side of QUIC gives the other in the handshake of TLS: its limits, its timeouts, and the connection identifiers that it used (RFC 9000, section 18).

Do not use: settings.

### Retry packet

A packet of a server that asks the client to send its Initial packet again with a token, to prove its address; its integrity tag uses a fixed key.

Do not use: redirect.

### Table of address budgets

The table of a QUIC server that holds a budget of Initial checks for each address whose token opened. A place moves to a new address only when its bucket is full again, so the table gives at most the sum of its buckets.

Do not use: address cache.

### Budget of work

The most pieces of one kind of work that a QUIC server does for datagrams of unknown identifiers (Retries, token checks, Initial checks), as a token bucket. Over it, a datagram is dropped before any cryptography. Not a budget of memory of the kernel.

Do not use: rate limit (for this), quota.

### Token bucket

A count of units that grows by a rate in each second up to a depth, and from which each piece of work takes one unit: a burst takes the depth, then the rate. The tokens of a bucket are not the tokens of Retry.

Do not use: leaky bucket, fixed window.

### UDP relay

The part of the peer of the tool that carries UDP datagrams between a program of the host, on a socket of the loopback, and the UDP port 4433 of the machine, as frames from 10.0.2.2 with a port for each client of the host.

Do not use: port forward, proxy, hostfwd (for this).

## Trusted boot

### Publisher

Who builds a system and signs its system description: the maker of a release, or anyone who builds a system of their own and enrols their key in their machine. A machine starts only a system of a publisher whose key it holds (`docs/PROPERTIES.md`, "Trusted boot: UEFI program, Secure Boot, TPM").

Do not use: vendor, owner, person, administrator.

### Signing key

The Ed25519 key pair of the publisher of the system, that signs the system description (`docs/PROPERTIES.md`, "Trusted boot: UEFI program, Secure Boot, TPM"). The private key is a file outside the repository, which the environment variable `SYSTEM_SIGNING_KEY` names; the boot program holds the public key.

Do not use: owner key, master key, release key, platform key (PK is a term of Secure Boot).

### Test signing key

The signing key of the tests: the key pair of RFC 8032, section 7.1, TEST 1, in `resources/keys`. Its private key is published, so a system that it signs is not trusted, and the boot display says so.

Do not use: development key, demo key.

### Signed message

The 64 bytes that the signing key signs for one system description: the label `system description signature 1`, with zero bytes to 32 bytes, then the BLAKE3 hash of the description.

Do not use: payload, digest (for this).

### Description signature

The Ed25519 signature, 64 bytes, of the signed message of a system description: the resource `system_description_signature` of the boot image.

Do not use: certificate, manifest signature.

### Trust record

The record `boot_info.Boot_Trust` that the boot program writes: what verified the system description, with which public key, the BLAKE3 hash of the description, and the measure. The kernel copies it into the boot record; the root service and the boot display read it.

Do not use: attestation, security state.

### Measure

The extension of a register of the TPM with the SHA-256 hash of the system description, which the firmware does at the request of the boot program, before the kernel starts (`docs/PROPERTIES.md`, "Trusted boot: UEFI program, Secure Boot, TPM").

Do not use: attestation (for this), seal, measurement log (for this).

### Measure register

PCR 11 of the TPM: the register that holds the measure.

Do not use: slot, PCR (alone, for this register).

### Firmware signing key

The RSA-2048 key and its X.509 certificate of the publisher of the system, that sign the boot program for Secure Boot. The firmware keeps the certificate in its variable `db`.

Do not use: db key (for the pair), Secure Boot key.

### Test firmware signing key

The firmware signing key of the tests, in `resources/keys`. Its private key is published, so a boot program that it signed is not trusted.

Do not use: development certificate.

## Project

### Changelog

The file `CHANGELOG.md`: the releases of the system, newest first, in the format of Keep a Changelog 1.1.0. Each entry says what the system does since that release, for a reader of the system.

Do not use: release notes (for the file), history, news.

### Release

One section of the changelog: a release number, a date, and the entries of the changes, in the parts Added, Changed, Deprecated, Removed, Fixed and Security. The merge of step N on `master` is one release.

Do not use: version (a stored object has versions), tag, build.

### Release number

The number of a release, `<major>.<minor>.<patch>`: `0.N.0` for step N, `0.N.1` for a correction after it. `RELEASE_NUMBER` in `contract/release` is the newest one.

Do not use: version number, version.

### Fragment

One file of `changelog.d/` with one change that is not in a release yet: its type and the text of its entry. `kerneltool changelog release` moves the fragments into a release.

Do not use: changeset, news file, entry (for the file).

### News entry

A dated report in prose, for a reader who is not a developer of the system, of one thing that a person can see or use, with its picture and its measured number: one file of `news/`, never moved or merged (`news/README.md`). The changelog lists every change for a developer; a news entry reports one thing for a person.

Do not use: news item, post, announcement, blog post, changelog entry.

### Feed

A file of the site in the Atom format (RFC 4287), for a program that follows a site: `news.xml` has the news entries and `releases.xml` the releases, newest first.

Do not use: RSS (for these files), stream, channel.

### Search index

The file `search.json` of the site: one entry for each page, and for each row or section of a page that a person looks for (a module, an export, a term, a heading of a guide...), with its title, its page, its id, its kind and a short text. The search field of a page filters it with the fuzzy match of the console.

Do not use: search database, catalog, sitemap.

### Search field

The one field of a page of the site where a person types a search: in the site menu of each page, but on the docs home, where it is a large field in the page and the bar has none. One script, `search.js`, serves both places.

Do not use: search box, search bar, omnibox.

### Mark

The picture that stands for the system: a heron on a grid of 24 by 24 square cells, each part filled with one gradient. `support/mark` holds it as data; `kerneltool logo` writes its files in `resources/logo` (`docs/DESIGN.md`, section 11).

Do not use: logo, icon, emblem, mascot.

### Name of the mark

The word "modus" in letters of square cells, 5 columns by 7 rows each, under the heron in the files of the mark that have a name.

Do not use: wordmark, logotype.

### Still heron

The heron of the mark with no animation: the 24 rows of `heron_rows` in `support/mark`. It is the frame 0 of each animation.

Do not use: rest pose, idle frame, base frame (a base frame is another thing: see Animation of the mark).

### Animation of the mark

A short list of frames in which a few cells of the still heron change: a cell takes the letter of another part, or becomes empty. Each frame has a duration in milliseconds, and starts from the still heron or from an earlier frame of the same animation (its base frame). After its last frame the heron is still again. `support/mark/animation.odin`.

Do not use: idle animation, clip, tween.

### Order of play

The fixed list of the steps of the animations of the mark: a still time, then one animation. It repeats. The weight of an animation is how many times it is in the order.

Do not use: playlist, random choice, schedule.

### Sprite sheet

One PNG file of the site that holds each distinct frame of the animations of the mark side by side, from the left; the first sprite is the still heron.

Do not use: atlas, film strip.

### Site

The documentation of the system as static pages, their style sheet and their pictures, that `kerneltool site` writes in `build/site` from the files of the repository and the logs of the machine tests (`docs/SITE.md`). Its home is the one page that shows the system.

Do not use: website, homepage, landing page.

### Docs

The section of the site that holds the guides and the reference, its two parts: the bar names it "Docs", and the addresses of its pages start with /docs/. Its first page is the docs home. The status page is not a part of it.

Do not use: documentation (for this: Documentation is the text of a module), manual, help center.

### Docs home

The first page of the docs, at the address /docs/ of the site: a large search field in the middle, the one search field of that page, the chart of what the search finds under it, then a card for the guides and a card for the reference with their counts. It has the presentation layout.

Do not use: docs landing page, portal, hub.

### Guide

A page of the site made from a document of `docs/`: how a part of the system is designed, and why.

Do not use: article, tutorial (for this).

### Reference table

A page of the site that the tool generates from the code or the files that define a thing: what exists in this build, each row with its source.

Do not use: API docs, listing.

### Module page

A reference table of the site for one module of `module_builds`: its documentation, its exports as the console prints them, its imports, and for a program its grants and its budget.

Do not use: API page, package page.

### Status page

The page of the site that gives the state of each property in the words of `PROPERTIES.md`, the evidence items and the gaps of `FIRST_MILESTONE.md` that name it, then the gaps and the next steps. What is not done is on it as plainly as what is done.

Do not use: roadmap, progress page, "what runs today".

### Site address

The absolute address where a host serves the site, as `https://<host>/<path>`: `SITE_ADDRESS`, or `kerneltool site --address` for one run. With no site address the pages have relative links only, and the site has no canonical address, no Open Graph, no page graph and no sitemap.

Do not use: base URL, domain (for this), root.

### Canonical address

The one absolute address of a page that the page names in its head (`<link rel="canonical">`): the site address and the folder of the page, with a final slash.

Do not use: permalink, URL (for this).

### Redirect page

A small file of the site at an old path of a page: the `.html` file from before each page became the `index.html` of its own folder (`reference/licenses.html`), or the folder from before the guides and the reference moved under the docs (`reference/licenses/`). A refresh straight to the address of today and one link, with no script. It is not a page of the site: it is in no sitemap, no index of the search and no feed.

Do not use: redirect, alias, forward (for this).

### Page graph

The JSON-LD of one page: one `@graph` of schema.org nodes (the site, the system, its source code, the page, its breadcrumbs, and what the page is about), built from the data that the page shows, whose nodes name each other by their `@id`.

Do not use: structured data (for this), schema, rich snippet.

### Sitemap

The file `sitemap.xml` of the site: the canonical address of each page, for a search engine.

Do not use: site index, page list.

### Site menu

The menu of the bar of the site: one `details` element that holds the sections and the search field (on the docs home, the sections only). Under 720 pixels it is a square button with three lines; on a wide screen it is open and shows as the bar.

Do not use: burger menu, hamburger, drawer.

### Documentation layout

The layout of each guide, reference page, module page, the status and the index pages of the guides, the reference and the modules: the documentation tree at the left of the window, the text in the middle, "On this page" at the right. The writer of a page states it. The home, the docs home, the news and the releases have the presentation layout: one centred column.

Do not use: docs theme, sidebar layout.

### Documentation tree

The list of the documentation pages of one part of the docs, generated from the pages that exist: a link to the docs home at its top, then the guides, or the reference pages, the modules in their groups and the status. One `nav` on each documentation page, in the site menu: at the left of the window on a wide screen.

Do not use: sidebar, navigation tree, table of contents (for this).

### On this page

The list of the headings and the symbols of one documentation page, each a link to its id: at the right of the text on a wide screen, a `details` above the text on a narrower one.

Do not use: table of contents (for this), outline, minitoc.

### Symbol

One documented thing of a reference page or a module page: a kernel operation, a command of the console or of the tool, an export of a module, or a row of a reference table with an id. A documented symbol shows its signature, the text of its source comment, its facts and its source line.

Do not use: entry, item, API (for this).

### Value kind

A value kind is what a technical value is, for a reader: a number, a size, a time, a handle, a value of the context, a grant, a status, a type, an operation, a command, a module, a file, a guide, a version, yes or no, a procedure, a constant or a global variable.

One enumeration gives the kinds to the site and to the system (`contract/value_kinds`), and one table gives each kind its color in each color scheme (`support/graphics/value_colors.odin`). The site adds a class, a title and an icon to each kind (`site_value_kinds`); a log record keeps the kind of each value of its text (a value run). The writer of a table, a symbol or a line of the log states the kind of each value: no text is classified by its look.

Do not use: value type, badge, chip, tag (for this).

### Declaration index

The list that `kerneltool site` reads with the parser of Odin from the sources of the system (`kernel`, `boot`, `contract`, `support`, `modules`, `programs`): each procedure, type, constant and global variable declared at the top of a package, with its package, its file and line, its kind, its one line of Odin and the first sentence of its comment. A code span of a guide, a news entry or a source comment that names one of them links to it.

Do not use: symbol table, symbol index (a symbol is a documented thing of a reference page), ctags.

### Declaration card

The short card of one declaration of the declaration index: its name, its kind and its package, its one line of Odin colored, the first sentence of its comment, its file and line. A page holds the card of each declaration that it links to once; the script opens it when the pointer rests on the link or the focus reaches it. With no script the link works and no card opens.

Do not use: tooltip, hover card (for this).

### Type card

What the site states of one type: its kind, its size, its alignment, its fields with their offsets and the padding, or its members with their values, its base, where it is named, and its source line. The size, the alignment, the offsets and the values come from the compiler that builds the tool (`type_info_of`). The page of the types holds the whole card; a page that names the type holds a short card that its name opens.

Do not use: tooltip, type info, hover card (for this).

### Identity card

What the site states of one module: its name, its kind, its hash, its size, the counts of its exports, of its imports and of the modules that import it, its license, and the first sentence of its documentation. The page of the module shows it; the page of the module graph shows it for the node under the pointer or the focus.

Do not use: tooltip, hover card, module info (for this).

### Document pointer

A part of a source comment that names a document of `docs/` for a person who reads the code: its path, and the labels of a place in it, as `(docs/ARCHITECTURE.md, "Kernel systems")` or `docs/FONTS.md, section 12.4`.

Do not use: doc link, citation (for this).

### Comment breach

A comment of a source that names a property, a choice, a step, a review or a decision by its number, its label or its date, in place of the reason. `kerneltool check` fails on each one (`docs/TOOLS.md`, "The comments of the sources").

Do not use: violation, lint error (for this).

### Document reference

What a page of the site writes for a document pointer, and for a code span of a guide that names a document: a link with the title of the document and the text of the heading that the labels name, in the color and with the icon of the value kind Guide. A reference to a working record links to the file in the repository, and says so.

Do not use: tag, badge, cross-reference (for this).

### Wire form

One of the types of the call form of the module contract, a member of `Type` of `contract/module`: Integer, Text, Record, Handle, Table, Bytes. It says how a call carries a parameter or a result: one register, and what that register holds or points to.

Do not use: marshalling type, ABI type.

### File version

The first 8 bytes of the BLAKE3 hash of a file of the site that changes between builds (the style sheet, the scripts, the index of the search), in hexadecimal, as `?v=<version>` in each link to it: a proxy that keeps a file never serves an old one with a new page.

Do not use: cache buster, fingerprint, hash suffix.

### Site workflow

The workflow of GitHub Actions `.github/workflows/site.yml`: at each push to `master` it builds the boot image and the site with `kerneltool`, then GitHub Pages serves the site.

Do not use: pipeline, CI job, deploy script.

### Full check

`kerneltool screenshots` and `nix flake check`, both passed: the machine tests, the second build and the pictures on the host, and the host tests and `kerneltool check` in the sandbox of Nix.

Do not use: CI run, test suite, full test.

### Measure record

The file `docs/measures/measures.txt`: the measured numbers of the last full check, each as the whole line of its log, with the facts of its run (its time, its commit, the state of its tree, its release, its host, the count of checks that passed) and the stages of the start. `kerneltool screenshots` writes it; the site reads it when the logs of `build/` are not newer (`docs/SITE.md`, "The measure record").

Do not use: benchmark results, metrics file, numbers cache.

### Hang bound

The one time in a test: it ends a test that waits for ever, and checks nothing about speed. Generous and the same for each wait that has no reason of its own: 120 s for a step of a machine test, 60 s for the checks of a program (`docs/TOOLS.md`, "The bounds of the tests").

Do not use: timeout (for a test), deadline (for a test), time limit.

### Stall

A case that writes a count of its progress, and whose count did not grow for the hang bound. The test bounds a stall, not the whole run of such a case.

Do not use: freeze, no progress timeout, watchdog.

### Tagline

The one line under the name in the head of the home of the site: the first sentence of the first paragraph of `README.md`. The rest of that paragraph is a section lower on the home.

Do not use: slogan, subtitle, hero text.

## Terms that the system does not have

These words name concepts that the system removed. Use them only to describe other systems.

file, path, directory, pipe, socket (as an object), signal, fork, environment variable, `argv`, standard input and output, user, group, root, installer, driver (in the kernel), system call table, TTY, shell script, save.
