# Glossary

The glossary defines each term of the system. Each concept has one term, and one term names one concept: the documents, the code and the names of the programs use that term and no synonym. A reader who knows another system finds here the word that this system uses, and why it does not use the word that he expects.

An entry starts with one sentence that says what the term is. The paragraphs after it explain it: what it is for, how a program gets it and uses it, the terms next to it, what it is not, an example from the system, and where its full design is. The last line, "Do not use", lists the words of other systems that the term replaces here.

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

A replacement lets the principal that signs the system fix a module in every program that imports it, with no new build of the programs. Example: module B has a security fault, and B2 has the correction; a replacement `{B, B2}` makes each import of B load B2. The file of the importing module does not change, so its hash stays.

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

A load error is the record of a load that failed (`module.Load_Error`, 392 bytes): the stage, the module that was being loaded, the import, a replacement on the path, the export, and the two descriptions that differ.

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

A debug object is the file that names the procedures, the source lines, the types and the variables of the code of one module, so that a reader can turn an address of the module into a name and a line, and a debugger can show a variable.

A module names only its exports. A stop report with only the module and an offset ("fault + 0x1478") tells a reader little. The debug object fills that gap: with it, the same frame reads "fault::three + 0x8 in fault (programs/fault/main.odin:15)". It is a separate file, `build/modules/<name>.debug`, in the format `contract/debug_object`.

The file has ten parts, all numbers little-endian:

- a header of 88 bytes: the magic `DEBUGOBJ`, the version, the BLAKE3 hash of the module file, and the count of each table;
- the procedure table;
- the file table: the path of each source file from the root of the repository (`programs/fault/main.odin`), or with the library of the compiler as a prefix (`base:runtime/print.odin`), and the BLAKE3 hash of the content of the file at the build; the file 0 is "no file";
- the line table;
- the type table, with the field table and the enumeration value table;
- the global table;
- the variable table, with the variable range table;
- the strings: the bytes of the names and of the paths.

The kernel tool writes the debug object at the build, from the linked ELF file of the module: the procedure table from its symbol table, the line table from the line program of its DWARF, the types and the variables from the entries of its DWARF. The system itself reads no DWARF. A parser of DWARF is a large parser of hostile input; the tool runs it once on its own output, and a program reads only sorted tables of fixed records, with a binary search and no allocator. `debug_object.check` refuses every other form before the first lookup, and `debug_object.place_of` gives the procedure, the offset in it, the file and the line of an offset.

The debug object names its module by the hash of the module file. The module names nothing: its bytes are the same with and without its debug object, and `kerneltool check` proves it by a third build with no `-debug`. The hash proves only that the tool wrote the object for that module, not that the names are true. A reader shows the names; no decision of the system uses them. A reader uses a debug object only for a loaded module whose file has that hash (`debug_object.describes_module`): the tables of another build are wrong for it.

The file table ties each line to one version of its source: a reader shows the text of a line only from a file whose BLAKE3 hash is the hash of the table (`debug_object.source_line_of`), and says so when the hash differs.

A debug object is not the whole debug information of the compiler. A variable location that the compiler gives as an expression to compute is "not readable" in it: a debugger of the host reads those in the DWARF of `build/modules/<name>/linked.elf`.

The design: `docs/MODULE_CONTRACT.md`, "Debug information".

Do not use: symbol file, PDB, dSYM, debug info (for the file), symbols.

### Procedure table

The procedure table is the table of a debug object that gives, for each procedure of the module, its start, its size and its name with its package.

A record has 16 bytes: the offset of the first instruction in the memory of the module, the size in bytes, and the name in the strings of the object (`fault::three`), with the count of the bytes of its package (`fault`). The records are sorted by their start and never overlap, so a reader finds the procedure that holds an offset with one binary search. A name with no package is an export or a procedure of an assembler file. A name holds only visible ASCII characters (0x21 to 0x7E): a hostile name cannot change or forge a line of the log or of a terminal.

The tool fills the table from the function symbols of the symbol table of the linked file. Code that the compiler inlined has the name of the procedure that holds it. A module has at most 2^20 procedures; the console module of today has about 210.

It is not the Functions table of the module metadata: that table describes the exports only, for callers; the procedure table names every procedure, for a reader of a stop report.

The design: `docs/MODULE_CONTRACT.md`, "The debug object".

Do not use: symbol table, function table.

### Line table

The line table is the table of a debug object that gives, for each range of the code of a module, the source file and the line that the code comes from.

A row has 8 bytes: an offset in the memory of the module, then one word with the file in its high 12 bits and the line in its low 20 bits. The code from the offset of a row up to the offset of the next row comes from that line. The rows are sorted by their offset, so a reader finds the line of an instruction with one binary search. A row with the file 0 says that the code after it has no source line: the end of a procedure, or the padding between two procedures. The last row always has the file 0.

The tool writes the table from the line program of `.debug_line` (DWARF 2 to 5) of the linked file. The optimizer gives the line 0 to an instruction that it merged from two lines; the tool writes no row for it, and the instruction takes the line of the row before it. Two rows in a row with the same file and line are one row. The rows are most of the bytes of a debug object, which is why the file and the line share one word.

Example: the machine test checks that the stack of `fault` names the lines 15 and 20 of `programs/fault/main.odin`. For a return address, the reader looks up the byte before it, so the line is that of the call.

The design: `docs/MODULE_CONTRACT.md`, "The debug object".

Do not use: line program (the form of DWARF that the tool reads), line info.

### Type table

The type table is the table of a debug object that gives, for each type that a variable of the module uses, its name, its size, its kind, and what it is made of.

A debugger needs the type of a variable to show its bytes as a value: an integer, a record with its fields, the name of an enumeration value. A record has 28 bytes: the name, the size in bytes, the kind, an element type, a count, and the first of its fields or values. The kinds are: signed integer, unsigned integer, boolean, float, pointer, array, slice, string, record, union, enumeration, procedure address, and "other", a type of which only the size and the name are true. The fields of the records are in the field table (name, offset, type, and the bits of a field of bits); the named values of the enumerations are in the enumeration value table.

The type 0 is "no type". A typedef is a copy of its type with its own name. A type can name itself through a pointer, so a reader bounds the depth that it follows. The tool sorts the types by their content, and two types with the same content are one: two builds give the same table. `debug_object.type_by_index` and `debug_object.field_of_type` read it.

It is not the Records table of the module metadata: that table describes the records of the exports, for callers; the type table describes the types of every variable, for a debugger.

The design: `docs/MODULE_CONTRACT.md`, "The types and the variables".

Do not use: type info, type section, DWARF types.

### Global table

The global table is the table of a debug object that gives, for each global variable of the module, its name, its address in the memory of the module, and its type.

A record has 16 bytes. The address is an offset from the address where the module is mapped. The name has its package (`errors::UNIT_NAMES`). The records are sorted by their address, then by their name. A static variable of a procedure is in the table; a variable of a thread and a variable that the link dropped are not. `debug_object.global_by_name` finds a global with one pass over the table.

The design: `docs/MODULE_CONTRACT.md`, "The types and the variables".

Do not use: data symbols, static table.

### Variable table

The variable table is the table of a debug object that gives, for each parameter and each local variable of a procedure, its name, its type, a range of instructions, and its variable location in that range.

A record has 16 bytes: the name, the role, the type, and the first of the ranges of the variable in the variable range table. A range has 12 bytes: its start, its size, and the variable location in it. A variable that the compiler moves has one range for each variable location. The variables are sorted by their procedure, so a reader finds the variables of the procedure of an instruction with binary searches (`debug_object.variable_range_of_offset`), then takes for each one the range that holds the instruction (`debug_object.variable_at`). A range that is "not readable" says where the variable is visible; a variable that is readable nowhere has one such range. A variable of a procedure that the compiler put inside its caller is a variable of the procedure that holds its instructions, and has its readable ranges only.

Example: at the first instruction of `fault::three`, the parameter `address` is a `uintptr` in the register 5 (`rdi`).

The design: `docs/MODULE_CONTRACT.md`, "The types and the variables".

Do not use: locals table, scope table, symbol table.

### Variable location

A variable location is where the value of a variable is in one range of instructions: in a register, or in memory at a register plus an offset.

A range of a variable has one of five kinds: in memory at the frame pointer plus an offset; in memory at the stack pointer plus an offset; in a register; in memory at another register plus an offset; and "not readable". The registers have the order of the register image: `rax` 0, `rbx` 1, `rcx` 2, `rdx` 3, `rsi` 4, `rdi` 5, `rbp` 6, `rsp` 7, `r8` to `r15`, then `rip` 16.

"Not readable" is a kind of its own: the debug information of the compiler gives no register and no address that the table describes (the compiler removed the variable, keeps a known value, splits the variable over two registers, or computes its address). The tool never guesses a location, and a debugger shows "not readable".

A variable location is true for the innermost frame, when the next instruction of the thread is in the range. For a frame of a caller only the frame pointer is known, so only a location from the frame pointer is readable there.

It is not a place of the storage service, and not the place (procedure, file, line) that `debug_object.place_of` gives for an offset.

The design: `docs/MODULE_CONTRACT.md`, "The types and the variables".

Do not use: place (for a variable), location expression (the form of DWARF that the tool reads), storage (for a variable).

### Debug image

The debug image is one file that holds the debug object of each module of a build, in the form of a boot image, so that the programs of a machine can name the procedures and lines of every module.

The kernel tool writes it as `build/debug.image`: a header, one entry for each object (the name of the module, the hash of the object, its offset and its size), and each object on a page. It copies it to the boot volume as `DEBUG/OBJECTS.IMG`, beside the boot program.

The path of the image through the start:

1. The boot program reads the file, if the volume has it, after its last allocation that can stop the start, and does not verify it: no code comes from it. A file that is absent, empty, over 32 MiB or that fails to read gives a start with no names.
2. The kernel checks the range of pages, reads none of its bytes, and gives it to the root service as a memory object with Read. A refused range is one line of the log, never a stop.
3. The root service maps it read-only at the fixed range `Debug_Image` in each program with the grant `Debug_Image`: today `console`, `inspect`, `errors` and `debugger`. A program finds it with `system.debug_image_of`, and the object of a module with `system.debug_object_of`.

The debug image is not part of the boot image. So the boot image, the system description and the measures of the trusted boot are the same bytes with and without it, and a change of a debug object changes no signature and no measure. Its pages are memory of the boot: no budget pays for them, and they stay taken for the whole run of the machine.

The design: `docs/MODULE_CONTRACT.md`, "Where the debug objects are".

Do not use: symbol server, debug archive.

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

An interrupt stack is a stack of one processor that the processor itself loads for one kind of exception, at any privilege, from the task state.

Some exceptions can come when no stack is safe: the kernel stack is full (a double fault after a stack overflow), or the stack pointer is still the one that a program chose (a debug trap or an NMI at the first instruction of a kernel entry). If the processor pushed its frame there, the kernel would write where a program decided, or fault again. So the gate of each such exception names an interrupt stack in the task state, and the processor switches to it on each such exception, also when it already runs at privilege 0.

Each processor has four, besides its kernel stack, each between guard pages:

- the double fault: 4 pages;
- the debug exception, the non-maskable interrupt and the machine check: 2 pages each.

The stub of a debug trap from a program moves the frame to the top of the kernel stack before any compiled code, because the handling can switch threads and the next trap reuses the interrupt stack. An NMI, a machine check and a double fault stay on their stacks: they stop the machine.

The design: `docs/ARCHITECTURE.md`, "The return to a program".

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

A strategy is the rule that orders the ready threads of each run queue: six procedures of the kernel over fixed fields of the thread and of the run queue.

The six procedures are ready, pick, tick, stopping, wake preemption and move. The kernel calls them through a `switch` on the strategy of the queue, with a direct call in each case: the strategies are a closed set, and the kernel keeps no table of procedure addresses for them. The machine has one strategy at a time: round robin, fair or EEVDF. A strategy owns no memory: its state is fields of the thread and of the queue, zero when the strategy has not placed the thread.

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

The weight is set when the thread is created: 0 is the weight limit of the creating thread, which is 1024, the full weight, unless it was lowered, so a program that gives no weight gets the most. A write of the thread schedule changes it while the thread lives. A program only lowers the weight of a thread that lives; only the holder of the right **Schedule** on the machine raises it. The processor limit of the budget stays above any weight: a strategy only orders the time that the budget gives.

The design: `docs/SCHEDULING.md`, "Weights and requests: a field at thread creation" and "The schedule of a live thread".

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

The request sets the virtual deadline, not the share: a short request makes the thread run sooner and more often, for shorter turns. Its cost, more switches, is in the time of the thread, which its budget pays. A write of the thread schedule changes it while the thread lives: a program only lowers it, and the holder of the right **Schedule** on the machine also raises it.

The design: `docs/SCHEDULING.md`, "Weights and requests: a field at thread creation".

Do not use: slice (for this), quantum.

### Thread schedule

A thread schedule is the weight, the request and the weight limit of one thread: the values that are set for it for the scheduling strategies (`op.Thread_Schedule`).

It is the policy of scheduling that a program holds: the program chooses the values, at a slow rate, and the kernel applies them at each tick with its own strategy. No code of a program runs when the kernel picks a thread. `Thread_Create` gives the first thread schedule; thread control reads it (`Read_Schedule`) and writes it (`Write_Schedule`) while the thread lives, also while it runs.

Who can read and write it:

- a program, for its own threads, by number: its write only lowers the weight and the request;
- the holder of a thread handle: **Inspect** reads, **Control** writes, and that write only lowers too, because a holder that can end a thread can also give it a smaller share;
- the holder of the machine handle with **Schedule** and **Inspect**, for any thread, by its machine number. Only this holder raises a weight or a request, and only it writes the weight limit.

A write that lowers leaves the place of the thread in its queue as it is. A raise starts the thread again as a new thread for its strategy: what it owed and what it was owed are gone. A program chooses the moment of its writes, so with a raise it could keep a place that it got under a small weight; with one direction only, no sequence of writes gets back what a write gave up. It is not the thread placement, which is the set of the processors that can run the thread, and not a share for a budget, which the kernel does not have.

Example: `{weight = 256, request = 500}` gives a thread a quarter of the share of a thread of the full weight, and turns of 500 microseconds under EEVDF.

The design: `docs/SCHEDULING.md`, "The schedule of a live thread".

Do not use: scheduling parameters, scheduling attributes, priority.

### Weight limit

A weight limit is the most that the weight of one thread can be: a number from 1 to 1024, and 1024, the full weight, for a thread that nobody limited.

It makes a lowered weight last across the creation of threads. A program only lowers the weight of a thread that lives, but a new thread starts with a weight of its own: without a limit, a program leaves a lowered weight by a new thread. Only a write of the thread schedule through the machine handle with **Schedule** and **Inspect** sets the limit; a weight above the new limit becomes the limit in the same write. A write of a program for its own thread, or through a thread handle, does not read the limit of the record; it only lowers the weight, so it never passes the limit. A new thread gets the weight limit of the thread that creates it, and the first thread of a new program gets the limit of the thread that starts it: a program does not leave a limit by a new thread. The limit is a value of each thread: a thread created just before a write of the limit keeps the old one until the holder writes it too.

It is not a share for a program: a program under a limit that creates more threads has more threads of that weight.

Example: the machine handle writes `{weight_limit = 256}` for a thread; the thread then has the weight 256, its own write of the weight 1024 is refused, and a thread that it creates with the weight 0 has the weight 256.

The design: `docs/SCHEDULING.md`, "The schedule of a live thread", "The weight limit".

Do not use: maximum priority, weight cap, ceiling.

### Thread placement

A thread placement is the set of the processors that can run one thread, and the limit of that set (`op.Thread_Placement`).

A set of processors is a `u64`: bit `n` is the processor `n` of the processor report. A thread that never got a placement has every processor of the machine in its set and in its limit, and is scheduled as a thread of a system with no placement. It is the second part of the policy of scheduling that a program holds, after the thread schedule: the program chooses the set, at a slow rate, and the kernel applies it at each pick. Thread control reads it (`Read_Placement`) and writes it (`Write_Placement`) while the thread lives, also while it runs.

Who can read and write it:

- a program, for its own threads, by number: its write only narrows the set;
- the holder of a thread handle: **Inspect** reads, **Control** writes, and that write only narrows too;
- the holder of the machine handle with **Schedule** and **Inspect**, for any thread, by its machine number. Only this holder widens a set, and only it writes the limit.

The limit is the most that the set can be. A new thread, and the first thread of a program that a thread starts, get the limit of their creator as their set and as their limit, so a program stays inside a limit that the holder wrote. A set with no processor of the machine is refused: a thread with no processor is a stopped thread, and `Stop` has its own right.

A thread in a run queue whose processor left the set moves at the write. A thread that runs on a processor that left the set leaves it at the end of its turn at the latest. The move is the one of the balance: nothing that the thread owes is forgiven.

The holder uses it to keep two programs off the same processors, against side channels: two programs whose limits share no processor never run on the same processor. It is not a knowledge of the cores: the kernel does not know which processors are siblings of one core, and the cache that all the cores share stays shared. It is not a share of processor time.

Example: `{processors = 0b0100}` keeps a thread on the processor 2; the machine handle writes `{processors_limit = 0b0011}` to each thread of a program, and the program then runs on the processors 0 and 1 only.

The design: `docs/SCHEDULING.md`, "The placement of a thread".

Do not use: affinity, affinity mask, CPU set, pinning, cpuset.

### Machine number

A machine number is the number that names one thread among all the threads of the machine (`op.Thread_Report.machine_number`).

A thread number names a thread inside its program only, and a thread handle names one thread that its program gave. The machine handle with **Schedule** needs a name for any thread: the thread report of `Inspect` gives the machine number of each thread, and thread control takes it for the two commands of the thread schedule. The low 32 bits are the place of the thread in the thread table of the kernel; the high 32 bits change for each new thread in that place. So the machine number of a thread that ended names no later thread: the kernel gives `Bad_State` for it.

It is not a handle: it gives no right. Only the holder of the machine handle with **Inspect** reads it, and only the machine handle with **Schedule** and **Inspect** makes the kernel take it.

The design: `docs/SCHEDULING.md`, "The schedule of a live thread".

Do not use: thread identifier, TID, global thread number.

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

A thread area is the memory that the kernel makes for one thread in the address space of its program: the thread record, the kernel ring of the thread, and one page with no memory.

Each thread needs a place where the kernel and the program share its state with no call: the thread record, which the program reads, and the kernel ring, through which the thread sends its kernel operations. The areas are at fixed addresses from `THREAD_AREA_BASE`, `THREAD_AREA_PAGES` (4) pages each, one for each of the at most 32 threads of a program, so a thread finds its own area from its number. The last page has no memory: a write past the ring faults.

The budget pays for each area with its thread, and the area ends with the thread. A page fault in a thread area is never given to a fault handler: it is a fault of the program, and the kernel stops it.

The design: `docs/ARCHITECTURE.md`, "Kernel systems".

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

It holds the kernel module, the boot image and the public key of the principal that signs the system. It verifies the signature of the system description, compares each module and resource with it, asks the firmware to measure the description into the TPM, loads the kernel module, and gives the kernel the memory map, the framebuffer and the trust record in one record. A failed check stops the boot with the file and the two hashes on the screen.

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

Debug and breakpoint are traps; the other fault kinds are faults. One debug exception is a fault: an execute breakpoint of the thread, which stops it before its instruction. The class decides the rule of Resume: a trap and a page fault resume by themselves, and another fault resumes only after thread control wrote the registers or the extended state of the thread: without that write, the same instruction faults again with no end.

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

Thread control is the kernel operation `Thread_Control`: it stops a thread, reads and writes its registers and its extended state, and resumes it.

No other operation stops a thread without ending it, or gives its registers. A debugger, a garbage collector that reads the roots of each thread, a sampling profiler and the program that runs a guest need both. One operation with a command (`op.Thread_Control_Command`) keeps the count of kernel operations low: `Stop`, `Resume`, `Read_Registers`, `Write_Registers`, `Read_Extended_State`, `Write_Extended_State`. Two more commands read and write the thread schedule of a thread that is not held, with their own rights: `Read_Schedule` and `Write_Schedule`. Two more do the same for its thread placement: `Read_Placement` and `Write_Placement`. Three more serve a debugger: `Read_Breakpoints` and `Write_Breakpoints` for the breakpoints of a held thread, and `Read_Memory` for the bytes of the program of a thread.

Who can act on a thread:

- a program acts on its own threads, by number or by handle;
- a thread of another program needs a thread handle that the program received with `Handle_Give`, with **Inspect** for a hold and for each read, and **Inspect** and **Write** for a write of the registers, because such a write lets its holder choose the code that the thread runs;
- the debugger of a program names a thread of that program by its number, with the program handle that has **Debug**;
- **Control**, the right to end a thread, gives none of these: a handle given so that another program can end a thread does not become a grant to read it. It gives only the write of the thread schedule, which only lowers, and the write of the thread placement, which only narrows.

The four commands of the registers need a held thread, else `Bad_State`. A write is copied once into the kernel, checked whole, and refused whole if one field is wrong (`Bad_Operation`, with the refused field in the error record): a thread never gets a frame that the processor refuses.

It is not ptrace: no program becomes the parent or the tracer of another, no signal exists, and the rights of a handle decide everything.

The design: `docs/ARCHITECTURE.md`, "The control of a thread".

Do not use: ptrace, debug API, SuspendThread, thread_suspend (for this).

### Stop count

The stop count of a thread is the count of the stops of thread control that hold it: each `Stop` adds 1, each `Resume` takes 1, and the thread runs only at 0.

A stop is a count, not a state, so two holders that each stop a thread each resume it, and neither releases the hold of the other. The stops of the debugger of the program are counted apart: the debugger takes back only its own, and the end of the debugging takes back those and no others. `Resume` at 0 gives `Bad_State`, and the count has a limit (`THREAD_STOP_COUNT_LIMIT`). When `Stop` returns, the thread runs no instruction: a thread on another processor left it, after an interrupt that the stop sent. The count does not change the wait of the thread: a thread in a word wait stays in it, and its wait ends as before, but the thread does not run until its count is 0.

The design: `docs/ARCHITECTURE.md`, "The control of a thread".

Do not use: suspend count, freeze.

### Held thread

A held thread is a thread that no processor runs and that stays off every processor: its stop count is above 0, or it waits for an answer of the fault ring.

Only a held thread has complete registers in the kernel: the frame of its last kernel entry, and the extended state that the switch of threads saved. A thread that runs has its registers in a processor, where no other thread can read them. So thread control reads and writes the registers of a held thread only, and gives `Bad_State` for any other. A thread that waits for the answer of its fault handler is held too: the handler reads its registers, corrects them and answers.

The design: `docs/ARCHITECTURE.md`, "The control of a thread".

Do not use: stopped thread, suspended thread (for this).

### Register image

A register image is the general registers, the instruction address, the flags and the two selectors of a held thread, as thread control reads and writes them (`op.Thread_Registers`, 176 bytes).

It holds the 16 general registers, `rip`, `rflags`, `cs`, `ss`, and `in_kernel_entry`: 1 when the last kernel entry of the thread is a `syscall` that has not returned yet. The names are the names of the registers of the processor. A write that a thread of a program cannot hold changes nothing:

- `cs` and `ss` must be the selectors of a program (0x23 and 0x1B), never those of the kernel;
- `rip` must be below `USER_END`, in the half of a program;
- `rflags` must have interrupts on, and no privilege, nested task or virtual-8086 bit.

The error record names the refused field and value. The extended state (vector registers) has its own commands and its own area.

The design: `docs/ARCHITECTURE.md`, "The control of a thread".

Do not use: register context, CONTEXT, user_regs_struct.

### Debugger

A debugger is a program that holds the handle of another program with the right **Debug**, and that made one of its own threads the debug handler of that program.

It receives the debug exceptions and the breakpoints of that program, names each of its threads by its number with the same handle, holds them, reads and writes their registers and their breakpoints, and reads the memory of the program. A program has one debugger at a time, and a program does not debug itself. Debug access is a handle to one program, never to the machine. Two holders have it: the caller that the root service gives it to on the command `Debug` of the root ring (a caller that acts for the principal whose session runs the program, and that holds each grant of that program itself), and the program that created the program, on the handle that the creation gave it. The root service gives it to no program at its start. A debugger acts with each handle of the program that it debugs.

The debugging ends when the debugger detaches, when its debug handler thread ends, when its last handle with Debug closes or is revoked, and when the program stops. The kernel then removes the breakpoints, clears the trap flag that the debugger wrote, takes back its stops and resumes each thread that waits for its answer: a debugger that ends never holds and never stops the program.

It is not a developer tool, which reads reports and never the bytes of a program. It is not ptrace: no program becomes the parent or the tracer of another, and no signal exists.

The design: `docs/ARCHITECTURE.md`, "The debugger of a program"; `docs/TOOLS.md`, "The debugger".

Do not use: tracer, attach to a process.

### Debugger service

The debugger service is the program `debugger`: the one debugger of the system for the programs that the root service starts, whose exports are the commands of a debugger.

It asks the root service for the debug access to a program on behalf of one of its callers, becomes the debugger of that program for the kernel, and gives each fact of the debugging as a table: the threads, the registers, the frames of the stack, the variables, the breakpoints, the stops. The console calls its exports under short names (`debug("clock")`, `stack(0)`), a window can call the same exports, and a developer on another machine calls them through the service `remote`. It debugs one program at a time, for one caller.

It is not the program `debugged`, which is the test of the contract of the kernel and debugs its own children. It is not a developer tool: a developer tool reads reports and never the bytes of a program.

Example: `kerneltool call <key> "debugger.attach(\"debug_target\")"`, then `"debugger.threads()"`.

The design: `docs/TOOLS.md`, "The debugger".

Do not use: debug server, debug agent, gdbserver, debug stub.

### Debug access

The debug access is the handle of one program with the right **Debug**, which the root service gives to the debugger service on behalf of a caller.

The root service gives it by one rule over grants, with no name of a program: the caller acts for the principal whose session runs the program; each grant that the program received at its start is a grant that the caller holds and that was not revoked from it; and a grant refuses for each caller when what it reaches belongs to that one program (a service, a private store, a terminal, an endpoint of the network, a list of services to connect to, a device). So a program with no grant can be debugged, and a service or a program with a private store cannot. The access is the grant `debug` of the caller in `grants()`: `revoke` ends it, and so do the end of the connection of the caller to the debugger service and a revocation of another grant after which the rule no longer gives the access.

It is not the right Debug of the creator of a program, which the kernel gives on the handle of the creation.

Example: `debug("storage")` in the console is refused with `No_Grant`, `Debug_Access`: the grant Serve of the program refuses it.

The design: `docs/TOOLS.md`, "Who can debug which program".

Do not use: debug permission, ptrace scope, debug privilege.

### Watch

A watch is a data breakpoint that the debugger service sets on 1, 2, 4 or 8 bytes of the debugged program: a thread that writes one of them stops after the instruction of the write.

It takes one of the four breakpoints of the debugger, as an execute breakpoint does. It names its bytes by an address or by the path of a global. It does not see an access that the kernel makes for the program.

Example: `watch("debug_target::rounds", 8)`, then `wait_stop(3000)` gives a row with the kind `watch 0` and the procedure that wrote the count.

The design: `docs/TOOLS.md`, "The exports of the service".

Do not use: watchpoint, data watch, memory breakpoint.

### Value path

A value path is the text that names one value of a debugged program: the name of a variable or of a global, then steps to one of its parts.

A step is `.field` (a field of a record), `[number]` (an element of an array or of a slice, from 0) or `^` (the value that a pointer points to). The name is a variable that is visible at the instruction of a frame, else a global; a global has its package in its name, and then needs no held thread. As in the language, the field of a pointer to a record is the field of the record. A path has 8 steps at most.

Example: `pair.next^.first`, `table[3]`, `debug_target::shape.size`.

The design: `docs/TOOLS.md`, "The variables and the types".

Do not use: expression, watch expression, selector, accessor.

### Debug handler

A debug handler is the thread of a debugger whose fault ring receives the faults of the kinds Debug and Breakpoint of the debugged program.

The debugger names it with `Fault_Handler_Set` and its program handle with Debug. Those faults go to it before the fault handler of the program itself, and only the debugger answers them (`Fault_Answer` with the same handle, `Resume` only). The ring is in the thread record of the debug handler, so the debugger pays for it. A thread is the debug handler of one program, and it is not the fault handler of its own program: one ring has one role.

The design: `docs/ARCHITECTURE.md`, "The debugger of a program".

Do not use: tracer thread, exception port.

### Breakpoint

A breakpoint is one of the four places where a thread stops with a fault of the kind Debug: an instruction that it reaches, or bytes that it writes or reads.

It is a debug register of the processor, not a byte written in the code: the code of a module is shared by each program that maps it. Thread control reads the breakpoints of a held thread, and only the debugger of its program writes them (`op.Thread_Breakpoints`: `Read_Breakpoints`, `Write_Breakpoints`). An execute breakpoint stops the thread before its instruction; a data breakpoint (1, 2, 4 or 8 bytes) stops it after its access. The kernel refuses an address that is not below `USER_END`, so no breakpoint is ever at an address of the kernel. A breakpoint belongs to one thread: the processor that takes the thread loads it, and the processor that leaves the thread turns it off.

It is not the fault kind `Breakpoint`, which is the instruction `int3` that a program runs itself.

The design: `docs/ARCHITECTURE.md`, "The debugger of a program".

Do not use: watchpoint.

### Debug status

The debug status is the error code of a fault record of the kind Debug: it says what made the debug exception.

Bit n is the breakpoint n of the thread (`op.DEBUG_STATUS_BREAKPOINTS`); bit 14 is a single step, one instruction that ran with the trap flag set (`op.DEBUG_STATUS_STEP`); 0 is the instruction `int1` of the program. The kernel reads it from the status register of the processor at each debug exception, clears that register, and keeps only the breakpoints that the thread has on.

The design: `docs/ARCHITECTURE.md`, "The debugger of a program".

Do not use: trap reason, debug cause.

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

The rights are Give, Read, Write, Execute, Control, Inspect, Devices, Stop, Spend, Physical, Schedule, Commit, Events and Debug. Each one means something for each kind of object: Read on a memory object is a mapping that reads, Read on a program is the reading of its state, Control on a program starts and stops it. A new object has each right of its kind. `Handle_Give` copies a handle with a part of its rights; no operation adds a right.

Narrow rights let a program give exactly what another needs: Commit is the part of Spend that pays pages of an object, and Inspect on a thread holds and reads it without Write. Debug on a program makes its holder the debugger of that one program.

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

The build tool takes it from the comments of the source. It is part of the file, so it has the hash of the module: a text cannot describe another version of the code. With the description of each export, it is all that a reader needs to use the module: `help()` in the console and the pages of the site show it. The one line of the module and the line of help of an export are plain text. A documentation text keeps the Markdown of its comment, and the program `manual` reads it: bold, italics, code, lists, examples and links.

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

### Back pressure

Back pressure is the rule of a queue whose writer waits while the queue is full, so that no record is lost.

It is the first form of the rule of the path of a key: the input service takes no byte of the keyboard from the controller while the input ring has no room, and the console takes no key from the terminal ring while 128 keys wait for the end of a line. The writer waits with `system.wait_room`; the reader wakes it when half of the queue is free. A writer that cannot wait (the compositor for a window, the terminal for its program) uses the second form: a stated capacity, and a loss period for each refusal. The design: `ARCHITECTURE.md`, "The path of a key".

Do not use: writer stall, push back.

### Loss period

A loss period is the time from the first record that a full queue refuses to the moment when the queue takes a record again.

A writer that cannot wait counts each record that it loses, and writes two lines in the log for one period: one when the loss begins, one with the count when it ends. It writes no line for each record: a queue that refuses 1000 keys must not fill the log. The compositor has one for each window, the terminal one for its program, the console one for the keys that wait during a line. The code: `key_path.Loss_Period` (`support/key_path`). The design: `ARCHITECTURE.md`, "The path of a key".

Do not use: drop window, loss burst.

### Terminal ring

The terminal ring is the ring between a program and its terminal.

In the command queue, a record from the program has a kind (text, status, clear, edit line, hint line, completion list, runs of code), a count of bytes in the text region and a style; it has no place on the screen. In the completion queue, a record from the terminal is a key record. The queue of keys holds 4096 keys: the keys typed ahead. The terminal never waits for a program: when the queue is full, a new key is lost, the terminal counts it, and the log has a line when the loss begins and a line with the count when it ends (a loss period).

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

### Result drawer

A result drawer is the one procedure of the console that draws the results of one kind: an Integer, a Text, a Record, a Table, a Handle, Bytes or an error.

A command of the console gives a result and never writes to the terminal; the console draws the one result of a line with the drawer of its kind. A drawer knows no command: for a record or a table it reads the description of the record, so one drawer serves each table of each service and of each built-in command. It writes parts of a line with what each part is (a number, a type, a label), and the console gives a value the color of its value kind. The drawers have no state and make no kernel call (`support/console_results`). It is not a formatter of one command, and it is not the terminal: the terminal draws the cells that the console sends.

The design: `docs/CONSOLE.md`, "Results and their drawers".

Do not use: printer, formatter, renderer, pretty-printer.

### Short name of an export

A short name of an export is a built-in name of the console that calls one export of a service: `programs()` calls `monitor.programs()`.

The fact that the command gives is a fact of the service, and the console holds no copy of it. The command connects to the service when the console has no connection to it yet, then calls the export through the connection, as any call of `service.export`. When the service does not run, the line fails with the error of the connection. It is not a second implementation of the command in the console.

The design: `docs/CONSOLE.md`, "The built-in commands and the services".

Do not use: alias, shortcut, wrapper command.

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

`support/virtio` holds what each virtio device service does the same way: it reads the virtio capabilities in the copy of the configuration, agrees on the features with the device, and drives split queues. A queue takes three pages of the memory of the queues: the descriptors, what the driver gives, what the device used. The block service and the frame service use it. A start asks the device for a reset and reads its status until it is 0, at most 1 000 000 times: a device that does not finish its reset makes the device service write "the device did not finish its reset" on the log and stop.

Virtio is not a part of the kernel: the kernel has no code for any device. Virtio is the first class of devices because the system starts on fixed hardware; a device of another class gets its own device service with the same contract.

The design: `docs/ARCHITECTURE.md`, "U4. Device services", and `docs/PROPERTIES.md`, "No drivers in the kernel, and fixed hardware first".

Do not use: paravirtual device.

## Network

### Network service

The network service is the one client of the frame service: it gives each program with a network grant one endpoint, and it checks each datagram and segment against that grant.

Only one program can read the frames of the device of the first machine, because the device has one pair of queues. The network service is that program. It is also the place where the grant of each program is enforced: a program reaches only the remote that its grant names, so no program has ambient access to the network.

The network service speaks Ethernet, ARP, IPv4 and ICMP echo with the protocol library `support/network`. It has one static address, 10.0.2.15/24, and the gateway 10.0.2.2. For UDP and TCP it checks the lengths and the ports of the header of each datagram and each segment, writes the IPv4 header, and keeps no state of a connection: the protocol of TCP is a library in the program (`support/tcp`), and the program writes and checks the header and the checksum of UDP (`support/network`). It copies each datagram or segment one time, between the datagram region of the program and its own frame region, and computes no checksum of it: it is on the control path of each one, and on the data path for that one copy. It has one thread, which waits on the frame ring, on the control ring of the root service and on the command queue of each endpoint.

The root service starts it when the first program with a network grant starts, and adds each endpoint with the command `Endpoint_Add` of its control ring. Example of its first line: "network: ok, the address 10.0.2.15/24 52:54:00:12:34:56, the gateway 10.0.2.2, the link is up, ..."; then, for each endpoint, a line such as "network: an endpoint for server: TCP, the listen port 80, the remotes that send to it".

The network service is not a network stack in the sense of Linux: it has no sockets, no connection, no retransmission and no routing table. A frame that it refuses becomes a problem row of the endpoint, or of the machine, with the layer, the field and the rule.

The design: `docs/NETWORK.md`, "The parts", and `docs/ARCHITECTURE.md`, "U7. Network steering service".

Do not use: network stack, TCP/IP stack, netd, network daemon.

### Data path

The data path is the code that reads or writes the bytes of the data that a program sends or receives through a device.

The term sorts the parts of the system by one question: does this code touch the bytes? The kernel is off the data path: it maps a ring or a device queue one time, and no kernel entry carries data after that. A service of user space can be on it. One read or one write of each byte by one program is a pass: a copy is a pass, and a sum for a checksum is a pass. The fewer passes outside the program that uses the data, the nearer the system is to its rule.

Example: the network service is on the data path of a datagram and of a segment for one pass in each direction, the copy between its frame region and the datagram region of the program. It computes no checksum, so it makes no second pass. It counts its passes for each endpoint, and writes them on the log when the endpoint ends. The frame service is not on the data path: it gives places of the frame region to the device and reads no frame.

The data path is not the control path of a packet: code that reads only the headers and decides where the bytes go is not on the data path.

The rule: `docs/PROPERTIES.md`, "Kernel off the data path". The hops: `docs/NETWORK.md`, "The path of a datagram and of a segment".

Do not use: fast path, hot path (for this).

### Control path of a packet

The control path of a packet is the code that reads the headers of a datagram or a segment and decides where it goes, and that reads no byte of its data.

A packet, in this term only, is the IPv4 packet that a frame carries: one datagram or one segment with its headers. The term names the work that one program must do for each of them when several programs share one device: read the ports, find the endpoint, check the grant. This work costs code for each packet, and no pass over the data.

Example: the network service is on the control path of each datagram and each segment, in both directions. For one that arrives, it reads the headers of Ethernet, IPv4 and UDP or TCP, finds the endpoint by the local port and checks the remote against the grant. For one that leaves, it reads the two ports in its own copy of the header and checks them against the endpoint and the grant. A device with a receive queue for each endpoint and a filter by port takes this work for the frames that arrive.

The control path of a packet is not the data path: the copy that the network service makes is on the data path, and its checks of the header are on the control path. It is not the control plane of the kernel either: the kernel sets up access one time and runs no code for a packet.

The design: `docs/NETWORK.md`, "The path of a datagram and of a segment".

Do not use: slow path, packet path.

### Endpoint

An endpoint is what a program holds to send and receive datagrams or segments: a datagram ring and a datagram region, with a grant that names what it can reach.

An endpoint replaces the socket of other systems, with one difference: the program does not choose the address. The root service names the grant, the network service enforces it, and a request to another remote fails with `Not_Granted` and the remote of the grant in its error record. A datagram or a segment from a remote that the grant does not name never reaches the program.

The kinds of endpoint:

- a datagram endpoint (UDP) with a client grant: one remote address and one remote UDP port; the network service gives the local UDP port, and the program writes the UDP header of each datagram.
- a datagram endpoint with a listen grant: one local UDP port; the program answers the admitted remotes only.
- a segment endpoint (TCP), with a client grant or a listen grant.

A program gets its endpoint at its start: the root service makes the datagram ring and the datagram region, gives them to the program (the roles 11 and 13 of its context) and to the network service. A program has one endpoint. With the right **Inspect** of its grant, the program also reads the facts of the machine: the frames that no endpoint owns, the kernel entries of the network service and of the frame service. The console shows the grant with `grants("server")` and ends it with `revoke`; a revocation sets the grant to none, and each later request that names a remote gives `Not_Granted`.

An endpoint is not a connection: a segment endpoint carries the segments of all the TCP connections of its program.

The design: `contract/datagram`, and `docs/PROPERTIES.md`, "No ambient access: the other holes to close".

Do not use: socket, port (for this), connection (for this).

### Datagram

A datagram is one UDP datagram: its header of 8 bytes and its data, 1472 bytes of data at most, what a program sends and receives through a datagram endpoint.

1472 bytes is the data of one Ethernet frame after the IPv4 header (20 bytes) and the UDP header (8 bytes): the system never fragments, so a datagram is one frame (`DATA_LIMIT` of `contract/datagram`; `DATAGRAM_LIMIT`, 1480 bytes, counts the header). A larger `Send` fails with `Too_Large`.

The program writes the whole datagram in a place of the datagram region: the data, then the header and its checksum with `network.udp_header_write`. It sends it with the command `Send` of its datagram ring: the place, the count of bytes with the header, and the remote address. The network service copies the datagram, reads the ports in its copy and checks them against the endpoint and the grant, and computes no checksum. The completion comes when the network service has copied the datagram: the place is then free again. A program gives a place for a datagram that arrives with `Receive`; its completion carries the place, the count of bytes and the remote. The program reads the data with `network.udp_data_read`, which checks the checksum when the program asks for it. Example: QUIC is a library in the program over datagrams; `quic_echo` and `remote` send and receive each datagram of QUIC through their datagram endpoint.

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

A datagram has a source UDP port and a destination UDP port. The network service finds the endpoint of a datagram that arrives by its destination port: the local UDP port of the endpoint. A program does not choose its local port with a client grant: the network service gives it, and the command `Info` returns it. The program writes that port as the source port of each datagram that it sends, and the network service refuses a datagram with another source port, in its own copy of the header. A listen grant names its port: the remote service listens on the UDP port 7100, `quic_echo` on 4433.

A UDP port is not the Ports object of the kernel (a handle to ports of input and output of the processor), and not a TCP port: the same number is two different ports in UDP and in TCP.

The design: `contract/datagram`.

Do not use: port (alone), socket number.

### TCP port

A TCP port is the 16-bit number of TCP that names one end of a connection at an address.

A segment has a source TCP port and a destination TCP port. The network service reads the ports of each segment to find the endpoint and to check the grant: a client grant has a block of 64 local TCP ports, and a listen grant has one local TCP port. As a UDP port, the TCP port is in the header that the program writes, so the network service checks the local port of each segment that the program sends against its block or its listen port, in its own copy of the segment. Example: `server` has the listen grant of the TCP port 80.

A TCP port is not the Ports object of the kernel, and not a UDP port.

The design: `docs/NETWORK.md`, "The grant of a segment endpoint".

Do not use: port (alone), socket number.

### Segment

A segment is one TCP segment: its header, its options and its data, 1480 bytes at most, what a program sends and receives through a segment endpoint.

1480 bytes is the room of one Ethernet frame after the IPv4 header, so a segment is one frame and never a fragment (`SEGMENT_LIMIT` of `contract/datagram`). A segment has 20 bytes at least, a TCP header with no option (`SEGMENT_LEAST`); a shorter one fails with `Bad_Command`.

The TCP library of the program writes each segment directly in a place of the datagram region, with its checksum, and the program sends it with `Send`. The network service copies it to a frame, reads its ports from the copy, checks them against the grant, and writes the IPv4 header. For a segment that arrives, the network service checks the lengths and the ports of the header; the TCP library of the program checks the TCP checksum, and drops a segment with a wrong one.

A segment is not a datagram and not a packet: the program sees no IPv4 header.

The design: `docs/NETWORK.md`, "The segment endpoint".

Do not use: packet, TCP packet, message.

### Segment endpoint

A segment endpoint is an endpoint whose grant has the protocol TCP: the program writes and reads whole segments, and the network service keeps no state of a connection.

A segment endpoint puts TCP in the program. The program owns each connection, each window and each timer in its own memory, and can read each field; the network service only checks the grant and copies the bytes. The ring, the region, the commands and the error records are those of a datagram endpoint, and the two take the same path through the network service: a `Send` names a whole segment, or a whole datagram, header included. One thing differs: the grant names TCP ports, and a client grant has a block of them.

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

The root service makes the datagram region with the datagram ring and gives it to the program and to the network service (the role 13 of the context of the program). A program does not give a region of its own: if the program gave it, a revocation of that memory by the program stops the network service on a page fault, for all programs. A request names a place in the region in bytes; a byte outside it gives `Out_Of_Range`. The network service copies each datagram or segment one time between the region and a frame. It checks the ports of what the program sends in that copy, never in the region, which the program can still change; it computes no checksum.

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

A press must land where the step wants it, and the tool does not trust its own count of the moves that it sent to the virtual mouse of QEMU. So, in a machine test, the tool calls `compositor.pointer()` before each press: after the packets of a move, it reads the place until the pointer is there or until the compositor received each packet, and it moves the pointer again from the place that the compositor gives, 6 tries at most (`POINTER_TRIES`). Before the remote service runs, the tool moves the pointer with no confirmation, and waits until the system read each packet.

A confirmed place is not a move of the pointer by the system: the compositor only reports where the pointer is.

The design: `pointer_confirm` in `tools/kerneltool/machine_input.odin`; `docs/TOOLS.md`, "How the tool sends input and waits".

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

A font is a set of glyphs of one design, with the measures that place them side by side.

The system draws all its text from fonts, and a program never reads a font file at run time. The kernel tool reads each font file at the build, subsets it to the characters 32 to 126, and draws it into a glyph cache: the program reads the cache only. So a parser of font files, which reads hostile input, runs once on the host and never in a program.

The system has three fonts:

- **Paper Mono**, the monospace font of the cells: the console, the terminal, values, hashes, code. Its SemiBold is the bold weight of the titles in the font of the cells. It is the default of the setting `font` (`vector`).
- **B612**, the interface font: titles, labels, buttons, menus, the bar. It is proportional, with a Regular and a Bold weight.
- **Spleen 8x16**, a bitmap font: the fallback when a program has no valid glyph cache, and the other value of the setting `font` (`spleen`). The boot program draws in it, because it holds no glyph cache.

The default vector font is one line of the tool, `DEFAULT_VECTOR_FONT`. A font here is one file of one weight: "Paper Mono SemiBold" is a font of its own, with its own cache.

The design: `docs/FONTS.md`, "6. The font file".

Do not use: typeface (for this), font face.

### Glyph

A glyph is the form of one character in one font.

The character is the number (the byte 0x30 is the character `0`); the glyph is the drawing of it. One character can have several glyphs in one font: Paper Mono has a plain zero (glyph 294) and a slashed zero (glyph 304), and a font feature chooses between them. A glyph has an outline and an advance; in a glyph cache it is a box of words of coverage.

The system draws glyphs for the characters 32 to 126 only. A byte outside that range draws nothing in a text of cells, and is placed as `?` by text shaping, so that the reader sees that the font does not draw it.

The design: `docs/FONTS.md`, "5. The glyph cache".

Do not use: character (for the form), symbol.

### Outline

An outline is the set of closed contours of line segments and quadratic curves that bound a glyph, in units of its font.

The outline is what a TrueType font stores in its table `glyf`: points in units of the font (1000 to one em for Paper Mono, 2000 for B612), each on or off the curve. The renderer of `support/vector_font` cuts each quadratic curve into 1 to 16 segments, each at most 1/8 of a pixel from the curve, scales the points to the grid, applies the grid fit, and accumulates the coverage of each pixel in fixed point, with no floating point. The sum of the coverage of a closed outline is exactly the area of the polygon of its cut points.

Only the kernel tool reads outlines: it draws them once into a glyph cache at the build. A glyph made of glyphs (`i` and `j` in Paper Mono) is made a simple outline in the subset. Outlines of CFF (cubic curves) are not read.

The design: `docs/FONTS.md`, "4. Fixed point".

Do not use: path, vector shape, Bézier.

### Coverage

Coverage is the part of a pixel, or of a third of a pixel, that a glyph covers, from 0 (none) to 255 (all).

The renderer computes the coverage of each third of each pixel from the outline. The glyph cache keeps, for each pixel, one word 0xGGRRGGBB: the coverage of the red, green and blue subpixel band after the filter, and in the high byte the coverage of the whole pixel for grayscale. The blend then mixes the color of the text with the pixel under it, channel by channel, in linear light: coverage 0 keeps the pixel, 255 gives the color of the text.

Coverage is not an alpha of a picture. An alpha is one value for the whole pixel and is premultiplied in the pictures of the system; coverage has one value for each band, and it is the result of the geometry of the outline, not a property of a color.

The design: `docs/FONTS.md`, "3. Subpixel bands".

Do not use: alpha (for this), opacity, mask.

### Subpixel band

A subpixel band is one of the three color stripes of a pixel of the screen, red, green and blue side by side, for which the vector font has a coverage of its own.

A screen pixel is three narrow stripes. If the renderer gives each stripe its own coverage, an edge of a glyph can sit on a third of a pixel, and a stem looks sharp at small sizes. The renderer draws the outline three times wider than the cell, then spreads each third over its neighbours with the weights 8, 77, 86, 77, 8 of 256, so that a side of a stem does not show one color alone.

The order of the stripes is the setting `subpixel_order`: `rgb` (the default), `bgr` (red and blue swapped at the blend) or `none` (grayscale, the high byte of each word). The system cannot read the order of the panel. Enlarged, a screenshot shows orange and blue edges on each letter: that is the bands at work, not a fault.

The design: `docs/FONTS.md`, "3. Subpixel bands".

Do not use: subpixel, ClearType, LCD stripe.

### Grid fit

Grid fit is the move of the baseline, the x-height and the cap height of a font onto whole pixels, so that the tops of the letters are sharp.

At 13 to 14 pixels to the em, the tops of the lowercase letters and of the capitals fall between two rows, and a row of half coverage under each top makes the text soft. The grid fit puts the baseline on a whole pixel, moves the x-height and the cap height to the nearest whole pixel, and scales the points between them to fit (`vector_font.place_y`). So the horizontal stems of `n`, `e`, `t`, `E`, `H` are sharp. The vertical stems need no fit: the subpixel bands place them in thirds of a pixel.

The system has no other hinting: no interpreter of TrueType instructions, and no fit of each stem. The grid fit is the setting `grid_fit` (`on`, the default, or `off`); the boot image carries the two glyph caches of the default font, with and without it, and the header flag `FLAG_GRID_FIT` says which one a cache is.

The design: `docs/FONTS.md`, "Grid fit (the hinting of this system)".

Do not use: hinting (alone), autohint.

### Glyph cache

A glyph cache is a file that holds the glyphs of one font already drawn, as words of coverage, for each character 32 to 126 at each scale of the grid.

A glyph cache moves all the work of a font out of the programs. The kernel tool builds it at the build (`vector_font.glyph_cache_build`) and puts it in the boot image as a resource. The root service checks its hash once at the start, and maps it read-only at a fixed range in each program with a surface, each terminal and the compositor. A program validates it once (`glyph_cache.validate`: about 7 µs), then each draw reads the words of a glyph with no other check. A glyph from the cache costs about 109 ns at scale 1 over a flat color on the host.

The format is `contract/glyph_cache`, version 2: a header of 128 bytes, an entry for each scale (1, 2, 3), an entry of 12 bytes for each glyph at each position and scale, the advance of each character, the pairs of each scale, then the words. A glyph keeps only its rows with ink. All zero is valid: a program with no cache draws Spleen 8x16.

The cache has a fixed capacity and holds every glyph that the grid can draw, so it never fills on demand and never evicts. It is not an atlas of a GPU and not a cache that a program fills: no program writes it, and its address and its size never come from another program.

The design: `docs/FONTS.md`, "5. The glyph cache", and "Who can write a cache".

Do not use: atlas, texture cache, glyph bitmap.

### Proportional cache

A proportional cache is a glyph cache of a proportional font: each character has its own advance, each glyph is the box of its ink at each subpixel position, and the cache holds the pair adjustments.

The header flag `FLAG_PROPORTIONAL` marks it. One format serves both kinds of font, and the flag says which rules `validate` applies:

| | A monospace cache (Paper Mono) | A proportional cache (B612) |
|---|---|---|
| Positions of each scale | 1 | 3 at scale 1, 1 at the scales 2 and 3 |
| A glyph | its full cell | the box of its ink, `left` can be negative |
| The advance | the width of the cell | the advance of the font, in 1/64 of a pixel |
| Pairs | none | sorted pairs, in 1/64 of a pixel |

A text of cells refuses a proportional cache (`graphics.cell_cache_problem`, the problem `Proportional`): its glyphs pass their cells, and the damage of a grid of text cells would leave stale pixels. The two caches of B612 are the resources `interface_glyph_cache` and `interface_glyph_cache_bold`; `display.interface_font_open` validates them and requires the flag.

The design: `docs/FONTS.md`, "12.4 The glyph cache with subpixel positions".

Do not use: proportional font cache.

### Setting

A setting is one choice of the principal of the machine that changes how each program draws: the font, the order of the subpixel bands, the pointer theme or the grid fit.

A setting is one value of the settings page, with 0 as its default:

- `font`: `vector` (Paper Mono) or `spleen`;
- `subpixel_order`: `rgb`, `bgr` or `none`;
- `pointer_theme`: `owner` or `system`;
- `grid_fit`: `on` or `off`.

The program `settings` is the one writer. It shows each setting as a row of buttons, and it exports `settings.set(name, value)` and `settings.get(name)`, so the console and `kerneltool call` change a setting too. A caller that does not act for the principal gets `No_Grant`. A change takes effect while programs run: the compositor sees it, draws its screen again and sends `Settings_Changed` to each window. The values survive a stop: `settings` keeps them as one record in its private store, and its boot pass writes them on the page at the start.

A setting is not a configuration file of one program: one value applies to every program with a surface. The scheduling strategy is not a setting: the right `Schedule` belongs to the program `scheduler`.

The design: `docs/FONTS.md`, "7. The setting".

Do not use: preference, option, configuration.

### Settings page

The settings page is the one page of memory that holds the current value of each setting, which each program with a surface reads.

The root service creates the page at the start. The program `settings` receives it with Write; each program with a surface, each terminal and the compositor receive it read-only at a fixed address, with its address in the value 13 of their context. The page holds the choices only: a change count and one value for each setting. It holds no address, no size and no hash of a glyph cache, because a writer that chose them could point every later program at memory that it controls.

A write makes the change count odd while it lasts; a reader reads again until it sees one even count (`settings.read`), and after 64 reads takes the defaults. The compositor waits on the change count as a word wait. A value that the page does not know reads as 0: the worst that a writer can do to another program is to change a look.

It is not a registry and not a file: it is shared memory with one writer, and its record in the private store of `settings` is the copy that survives a stop.

The design: `docs/FONTS.md`, "7. The setting", and "Who can write a cache".

Do not use: registry, config file, dconf.

### Monospace font

A monospace font is a font whose characters all have one advance, so that a text is a row of equal cells.

The system has two: Paper Mono (an advance of 606 units, which the grid maps to 8 pixels at scale 1) and Spleen 8x16. The font of the cells is monospace because the grid of the system is cells of 8 x 16 pixels: the terminal fills one cell and draws one character, and a glyph never leaves its cell.

A text stays monospace when it is a grid of cells (the terminal, the console, `Text_Grid` records), or when a reader compares it character by character or copies it: hashes, addresses, names of exports, code, the text of a log record, the columns of a table whose values align by character. A text that names or explains is in the interface font.

The design: `docs/FONTS.md`, "12.6 Which text stays monospace".

Do not use: fixed-width font (for this), terminal font.

### Interface font

The interface font is the proportional font of the titles, the labels, the buttons, the menus and the bar: B612.

B612 has an em of 2000 units and 19 different advances in ASCII. At scale 1 its cap height is 10 rows of the grid. Its digits are all 1300 units wide, so a column of numbers aligns in it too. Its Bold weight has scale 1 only, for titles.

A program uses it through `support/interface`: an element that names or explains draws an `Interface_Text` record, and the table measures and draws it with text shaping and a proportional cache. The compositor draws the bar, the menus, the title bars and the launcher in it, and the root service draws the titles of the boot display in it. If the caches are absent or refused, or if the setting `font` is `spleen`, each element draws in the font of the cells with the same rules.

The design: `docs/FONTS.md`, "12. The interface font and the text shaping module".

Do not use: UI font, system font (for this), sans.

### Interface text

An interface text is a text that a draw table draws in the interface font: the draw record `Interface_Text`.

The record came with version 7 of the draw records. Its rectangle is the measured box of the text widened by the ink margin on each side, so the damage of the record covers every pixel of its ink. Its origin is at `x` plus the margin plus `text_origin_thirds` thirds of a pixel (0, 1 or 2), so a label can start between two pixels. When the table runs the record, it shapes the text and draws its placed glyphs with `graphics.text_proportional`.

A text in the font of the cells is the record `Text`. If the table has no interface font, an `Interface_Text` record is drawn in the font of the cells, cut to its rectangle: the font in use decides.

The design: `docs/FONTS.md`, "12.5 What changes in `support/interface`".

Do not use: proportional text record.

### Font in use

The font in use is the font that actually draws a text of a draw table: the interface font when the table can draw it, else the font of the cells.

A text asks for the interface font, but three things make it fall back: the table has no interface font (an isolated call: the call host maps no glyph cache), the setting `font` is `spleen`, or the text is longer than 256 bytes (`INTERFACE_TEXT_LIMIT`). `interface.font_in_use` decides, and both the measure and the draw call it. So a text is always measured in the font that draws it, and an element never passes its box in either font.

The design: `docs/FONTS.md`, "12.5 What changes in `support/interface`".

Do not use: effective font.

### Advance

The advance of a glyph is the distance from its origin to the origin of the next glyph, before any pair adjustment.

In a monospace font the advance is one constant: 8 pixels at scale 1. In a proportional font each character has its own: in B612, the space is 700 units, `i` 600, `M` 1800. The glyph cache keeps the advance of each character at each scale in 1/64 of a pixel, rounded to the nearest integer: `A` in B612 is 1300 units, so 555/64 of a pixel at scale 1.

The advance is not the width of the ink: a glyph can have ink before its origin or past its advance (`j` in B612 starts 61 units left of its origin). The ink margin covers that difference.

The design: `docs/FONTS.md`, "12.4 The glyph cache with subpixel positions".

Do not use: width (for this), pitch.

### Pair adjustment

A pair adjustment is the change of the advance that a font gives for one pair of glyphs that follow each other.

Some pairs look too far apart with their advances alone: `T` before `o` leaves a gap under the bar of the T. The font then states a negative adjustment for that pair. B612 has 232 pairs of ASCII characters in Regular and 239 in Bold, from -1.33 to +0.67 pixel at scale 1: "To", "LT" and "Ty" are -100 units, "LV" -150. "AV" has no pair in B612.

The tool reads the pairs from the table `kern` (format 0) and writes them, sorted, in 1/64 of a pixel, into the proportional cache. Text shaping adds the rounded advance and the rounded adjustment: "T" before "o" is 512 - 43 = 469/64 of a pixel. A monospace cache has no pairs.

The design: `docs/FONTS.md`, "12.1 What B612 has, read in its files".

Do not use: kerning pair (for this).

### Font feature

A font feature is a named choice of glyph forms that a font offers in its table `GSUB`, by a tag of four letters.

Examples: `zero` (the slashed zero), `ss01` (a stylistic set), `numr` (numerators). A feature leads to one or more lookups, and each lookup changes glyphs. The system uses one feature today, `zero` of Paper Mono, and it uses it at the build: the tool reads the feature with `vector_font.single_substitution` and draws its glyph for the character `0` in the subset. The subset then holds no `GSUB`, and no program reads features at run time.

The reader of `GSUB` (`support/vector_font/substitution.odin`) reads hostile input with bounds: 16 features of one tag, 64 lookups, 64 subtables.

The design: `docs/FONTS.md`, "Paper Mono, the font of the system".

Do not use: OpenType feature (for this), font option.

### Single substitution

A single substitution is a lookup of the table `GSUB` that puts one glyph in the place of another (lookup type 1).

It is the simplest lookup: a coverage table lists the glyphs that it changes, and a delta or a list gives the substitute of each one. The feature `zero` of Paper Mono is one: the lookup 158 puts the glyph 304 (`zero.zero`) in the place of the glyph 294 of the character `0`. The reader also takes a lookup of type 7 (an extension) that holds a type 1, and checks that the substitute is a glyph of the font.

The system reads no other kind of lookup: no ligature, no contextual form.

The design: `docs/FONTS.md`, "Paper Mono, the font of the system".

Do not use: glyph swap, alternate.

### Slashed zero

The slashed zero is a zero with a stroke at an angle inside it, so that it does not look like the capital O.

The plain zero of Paper Mono has the same contours as its capital O, and a reader of a hash or an address cannot tell `0` from `O`. So the character `0` of the system is the slashed zero of Paper Mono: the kernel tool reads the font feature `zero` and draws its substitute for `0` in the subset. Each picture of the system with a 0 shows it. JetBrains Mono, the reference font of the tests of the renderer, keeps its own zero, so the golden hashes of the renderer did not change.

The design: `docs/FONTS.md`, "Paper Mono, the font of the system".

Do not use: crossed zero, zero with a slash.

### Text shaping

Text shaping is the step that turns the characters of a text into placed glyphs, with the advances and the pair adjustments of one font.

A proportional text needs it: the x of each glyph is the sum of the advances and adjustments before it. The package `support/text_shaping` does it for a direct call, and the module `text_shaping` exports the same work:

- `shape_text`: the advances, the pairs and the text in, the placed glyphs out (an Append table), with the count of placed glyphs as the result;
- `measure_texts`: many text ranges of one table of bytes in one call, each with its width written in it.

The module holds no font and no state: the caller passes the spacing of one scale of its glyph cache. Every input is hostile: each advance, pair, byte and range is read once and kept in its limits at that read, so a caller that changes its tables during the call gets wrong numbers, never a read outside a table.

Text shaping here does advances and pairs only: no ligature, no other script, no line break. The contract (characters in, placed glyphs out, with a cluster number) takes a full shaper later.

The design: `docs/FONTS.md`, "12.3 The text shaping module".

Do not use: layout (for this), typesetting.

### Placed glyph

A placed glyph is a record of 16 bytes that text shaping gives for one character: the glyph, its x from the origin of the run, and its advance.

The fields of `text_shaping.Placed_Glyph`:

- `glyph`: the index of the character in the glyph cache (the character minus 32);
- `x`: the origin of the glyph from the origin of the text, in 1/64 of a pixel;
- `advance`: its advance with the pair adjustment that follows it, in 1/64 of a pixel;
- `cluster`: 0 today; a shaper with ligatures will give there the first byte of the characters of a glyph.

`graphics.text_proportional` draws a table of placed glyphs: it rounds each x to the nearest subpixel position. The x keeps the exact sum, so the rounding of one glyph never moves the next one.

The design: `docs/FONTS.md`, "12.3 The text shaping module".

Do not use: positioned glyph, glyph run entry.

### Ink margin

The ink margin is how far the ink of a text of a proportional font can pass the box that its measure gives, on each side: 2 pixels at scale 1 for B612.

A measure gives the sum of the advances, but ink can start left of the first origin (`j`) and pass the last advance (`K` in Bold), and the subpixel filter spreads it by two thirds of a pixel. The damage of an `Interface_Text` record is its measured box widened by `graphics.PROPORTIONAL_INK_MARGIN`, so the damage covers every pixel of ink and a frame drawn in its damage equals a whole frame. The host test `the_ink_lies_inside_the_measured_box` draws 200 texts and counts the pixels outside the box and its margin.

The margin is a bound measured for B612. Another interface font needs its own.

The design: `docs/FONTS.md`, "12.8 The parts, each one working".

Do not use: bleed, overhang (for this).

### Subpixel position

A subpixel position is the fraction of a pixel where a glyph starts: 0, 1/3 or 2/3 of a pixel in the glyph cache of a proportional font.

A glyph of a proportional font rarely starts on a whole pixel. With subpixel bands, the finest step that the screen shows is one third of a pixel, so a proportional cache keeps each glyph at scale 1 drawn at three positions. The draw rounds the x of each placed glyph to the nearest third (`glyph_cache.position_of`): the error is at most 1/6 of a pixel and does not add up along a text. At the scales 2 and 3, the cache keeps one position: there a glyph is at most half a pixel from its place in a glyph of 26 to 40 pixels.

A monospace cache has one position: each glyph starts on its cell.

The design: `docs/FONTS.md`, "12.4 The glyph cache with subpixel positions".

Do not use: subpixel offset, bucket.

### Spacing

The spacing is the two tables that text shaping reads for one font at one scale: the advances of the characters 32 to 126 and the pair adjustments, in 1/64 of a pixel.

`text_shaping.spacing_of` takes them from a validated glyph cache: 95 advances and the sorted pairs (`glyph_cache.Pair_Entry`). The caller then passes them to `shape_text` or `measure_texts` as tables. So the module of text shaping holds no font, and an isolated call receives the spacing in its call region like the text.

The design: `docs/FONTS.md`, "12.3 The text shaping module".

Do not use: metrics (for this), kerning data.

### Text range

A text range is a record that names one text in a table of bytes by its first byte and its count, with its width, which the measure writes.

`text_shaping.Text_Range` has 16 bytes: `start`, `count` (at most `TEXT_LIMIT`) and `width` in 1/64 of a pixel. A window passes all its labels as one table of bytes and one table of ranges to `measure_texts`, which writes the width of each range: one call measures a whole frame (the direction Change of a table parameter). `interface.texts_measure` measures the lines of a list this way.

The design: `docs/FONTS.md`, "12.3 The text shaping module".

Do not use: span (for this), slice.

### Boot pass

The boot pass is the start of the program `settings` that the root service makes at the start of the machine, with no window, to put the kept settings on the settings page.

The settings survive a stop as one record of 48 bytes (`Kept_Settings`) in the private store of `settings`. The root service cannot read the store itself, so it starts `settings` with the value 1 at `VALUE_BOOT_PASS` of its context. The program reads the record, writes the page, wakes the compositor and stops. A record of another version, or none, gives the defaults. The log has one line, for example `settings: the boot pass: ...; in N us`. The boot pass takes about 23 ms in the machine test with a new disk.

Until the boot pass ends, the boot display and the first frames use the defaults. Then the compositor sees the change of the page and each window draws again.

The design: `docs/FONTS.md`, "7. The setting".

Do not use: init script, startup hook.

### Blend table

A blend table is the results of the blend in linear light of one text color over one pixel color, for each coverage of each channel, kept in the memory of a program.

The blend of a partial pixel costs two squares, a sum, a shift and a load of a square root for each channel. But for one text color over one background color, each channel of the result depends on its coverage only: 3 x 256 values. A program keeps 8 such tables (`graphics.Blend_Tables`, 24 KiB), replaced in turn, and fills a value on first use with the formula of the reference blend. A row of a glyph whose two end pixels have one color uses the table of that color: three loads and a store for each pixel. Any other row takes the SSE2 or the scalar form.

The result is the same bytes as the reference blend: the host test `fast_blend_is_the_reference` finds 0 pixels that differ. A glyph from the cache over a flat color costs 109 ns with the tables against 181 ns with the reference, on the host.

The design: `docs/FONTS.md`, "Where the time goes, and the fast blend".

Do not use: lookup table (alone), LUT.

### Markdown block

A Markdown block is one unit of the Markdown of a source comment that stands on its own rows: a paragraph, a list item, a fenced block or an example.

The reader of the system (`support/source_comment_markdown`) gives the blocks of a documentation text in the order of the text. A block is a range of bytes of that text, with its kind. A list item has its mark and its depth: 0 for an item of the list, 1 for an item inside it. A fenced block has the word after its opening fence. A block says whether an empty line is before it, so a reader can keep that row. The Markdown spans of a block follow it. Example: the program `manual` starts a row for each block, and draws a band behind the rows of a fenced block and of an example. It is not a block of storage.

The design: `docs/SITE.md`, "The reader of the system".

Do not use: element, node (for this).

### Markdown span

A Markdown span is a run of bytes of a Markdown block with one set of styles: bold, italic, code, link.

A span has no mark: the stars, the backticks and the brackets are outside its range. A span can have several styles: a bold word in the text of a link has two. A span of a link names the bytes of its target. In a paragraph and in a list item, a span can hold a line feed, which a reader shows as one space. In a fenced block and in an example, a span is one line, kept as it is. Example: `manual` draws a bold span in the bold weight, a code span in the font of the cells, and a span of a link in the color of a link.

The design: `docs/SITE.md`, "The reader of the system".

Do not use: run (alone), token, inline.

## Randomness

### Random seed

A random seed is the 32 bytes from which a random generator starts.

Each program needs unpredictable bytes (keys, nonces, the secret of the TCP sequence numbers), and the kernel gives none. So each program receives a seed at its start: its starter writes 32 bytes of its own random stream in the context values 9 to 12 (`op.CONTEXT_VALUE_SEED`), and the strength of the seed of the system in the value 16. The program reads it once with `random.generator_from_context`, which erases it in the context. `system.program_start` refuses a start whose seed is 32 zero bytes, so a starter cannot forget it.

The root service has no starter. It gathers the seed of the system from the sources of the processor at its start, before it starts any program, and writes an entropy report. Every other seed descends from that one through the streams of the starters.

A starter knows the seed of its child: a child has no secret from its starter, which already chooses its code and its grants. Two programs of one starter do not know the streams of each other.

The design: `docs/RANDOMNESS.md`, "1. Where a program gets random bytes".

Do not use: entropy (for this), salt.

### Random generator

A random generator is a record of fixed size in the memory of a program that gives it random bytes, with no kernel entry and no call.

The generator is `random.Generator` in `support/random`: ChaCha20 with fast key erasure. Each refill runs ChaCha20 with the key of the generator for 13 blocks (832 bytes): the first 32 bytes become the next key, and the other 800 are served in order. The key that made a refill is overwritten at once, and each byte is erased when it is served, so a copy of the state after a draw does not give the bytes before it. The stack below the draw is erased after each refill too.

A program uses it in three ways:

- `random.fill` draws bytes with no requirement;
- `random.fill_for_a_key(generator, output, least_strength, error)` draws bytes for a secret only if the seed strength is at least `least_strength`, else gives `Seed_Too_Weak` and writes no byte;
- `random.seed_for_a_child` gives the seed of a child program or of a second thread.

One generator belongs to one thread: two draws that overlap would give the same bytes, so the second one stops the program with "random: two threads drew from one generator at once ...". A zero generator is not seeded, and a draw from it stops the program. 4 MiB take 12 to 39 ms in the program `randomness`.

It is not a kernel device and not a service: a kernel entry or a call for each draw is a cost on a hot path (QUIC draws for each handshake), and a shared pool is one shared state for all programs.

The design: `docs/RANDOMNESS.md`, "2. The generator".

Do not use: RNG, PRNG, CSPRNG (for this), /dev/urandom.

### Entropy report

The entropy report is the record of what the root service found when it gathered the seed of the system: which sources it read, how many of their values it took and refused, and the seed strength.

`random.Entropy_Report` holds, for `rdseed` and `rdrand`, whether the processor has it and its good and refused values (a value with the carry clear, all ones, or equal to one before it is refused), and for the cycle counter its samples and the count of distinct low bytes of their deltas: a sign of life, not a measure. The root service writes it on the log, never the seed:

```
root: the random seed of the system, strength entropy (rdseed): rdseed present, N good values, N refused; rdrand present, N good, N refused; the cycle counter, N samples, N distinct low bytes
```

It also gives the facts to the program `randomness` in its context values 0 to 7, which shows them in its window.

The report says what the sources gave. It does not estimate the entropy of the bytes: the system does not test the output of `rdseed` or `rdrand` for quality.

The design: `docs/RANDOMNESS.md`, "3. The seed of the system, and what is claimed".

Do not use: entropy estimate.

### Seed strength

The seed strength is the strongest source that gave all its values to the seed of the system: `entropy` (rdseed), `processor` (rdrand) or `weak` (the cycle counter only).

The strength is what the system claims about its seed, and no more:

| Strength | Source | Claim |
|---|---|---|
| `entropy` (3) | `rdseed` | the entropy source of the processor, by its specification |
| `processor` (2) | `rdrand` | the generator of the processor, which the processor reseeds |
| `weak` (1) | the cycle counter | 0 bits: the system does not measure the jitter |

Each program knows the strength of its seed: the starter writes it in the context value 16, and `random.seed_strength(generator)` gives it. A child has the strength of its starter, because its seed comes from that stream. A program states the least strength that it accepts with `random.fill_for_a_key`: QUIC and TLS ask for `processor`, so on a machine with no `rdrand` and no `rdseed` a handshake does not start, and the caller gets the error `Seed_Too_Weak`. The system never refuses for the program: each program still starts and draws.

`kerneltool test random` runs a machine with no `rdrand` and no `rdseed`: its log and its window say "weak (the cycle counter only)" in the color of a failure.

The design: `docs/RANDOMNESS.md`, "3. The seed of the system, and what is claimed".

Do not use: security level.

### Cryptography module

The cryptography module is the module `cryptography`: the cryptographic primitives that the system took from Odin's `core:crypto`, as exports that use the memory of the caller and give error records.

The system does not write cryptography from nothing: it takes proven code and changes only its shell. The arithmetic and the constant-time code stay as they are; `kerneltool cryptography-origin` proves that each file is its origin with listed changes. The module `modules/cryptography` then gives the system forms:

- AEAD seal and open with ChaCha20-Poly1305 and AES-128-GCM;
- SHA-256, HMAC-SHA-256, HKDF extract and expand;
- X25519, and Ed25519 (public key, sign, verify);
- Argon2id, which `unlock` uses to derive the key of a passphrase;
- the two masks of QUIC header protection.

The caller supplies each byte, and the module reads each byte of the caller once: an input that the code of the origin reads two times is first copied into the module, so another thread cannot change it between two reads. Each export erases its copies of a key and the 16 KiB of stack below it, so a thread that calls it needs 24 KiB of stack. A failure is an error record: a tag or a signature that does not verify is `Not_Authentic`. The exports draw no random byte: the caller passes each key and nonce.

A program imports it by hash, as `agenda` imports `calendar`, and the console can call it. One call through an import slot costs 4 to 12 ns. The boot program links the Ed25519 code directly, because no loader runs before the kernel.

The design: `docs/CRYPTOGRAPHY.md`, "6. The module `cryptography`".

Do not use: crypto library, libcrypto.

### Not authentic

Not authentic is the error kind of a sealed text whose tag does not verify, or of a message whose signature does not verify.

`Not_Authentic` (`contract/errors`) tells a caller that the bytes are forged, damaged or from another key, and it is the one answer: the call says nothing about which byte was wrong. An open that gives it leaves no byte of the text in the result (it erases what it wrote), and its count is negative, so a caller cannot take a failed open for a success. `ed25519_verify` gives it for a signature that does not verify, and the boot program stops on it for the description signature.

A point of small order given to `x25519` is `Bad_Value`, not `Not_Authentic`: it is a point that shares no secret, not a forged text.

The design: `docs/CRYPTOGRAPHY.md`, "6. The module `cryptography`".

Do not use: MAC failure, bad tag.

### Compatibility layer

The compatibility layer is the packages of `support/cryptography` that give the code taken from Odin the helpers that it expects from its origin, over the primitives of this system.

The code of `core:crypto` imports helpers of the library of Odin: `zero_explicit`, `compare_constant_time`, little-endian loads, `rotate_left32`, `add_u64`, the `zero` of `core:mem`. The system does not change that code. It changes only the import lines, so that they name `compatibility_crypto`, `compatibility_endian`, `compatibility_bits`, `compatibility_bytes` and `compatibility_memory`, each imported under the name of its origin as alias. Those packages implement the helpers with the primitives of the system: the compatibility `zero_explicit` calls `erase_secret_bytes` of `runtime/memory.asm`, which the compiler cannot remove.

The files of the layer are listed in `system_files.manifest` with their hashes, so a change of one of them fails `kerneltool check` until its new hash is written and reviewed.

The design: `docs/CRYPTOGRAPHY.md`, "3. The layout".

Do not use: shim, polyfill.

## QUIC

### Connection identifier

A connection identifier is the 0 to 20 bytes by which a QUIC endpoint names a connection in each packet, independent of the addresses.

UDP gives no connection: a datagram has only addresses and ports, and those can change on the path. So each QUIC packet carries a Destination Connection ID, and the receiver finds its connection by it. Each side chooses the identifiers that the other side sends to it. A client of this system chooses 8 bytes; the OpenSSL client chooses 0 bytes, and the server then sends it packets with an empty identifier.

The identifier also seeds the Initial keys: they come from the Destination Connection ID of the first Initial packet of the client. A server of this system (`quic.Server`) finds the connection record by the identifier and the remote together: the same identifier from another address or port is dropped, because the server sends `disable_active_migration`. `header_read` refuses an identifier over 20 bytes for every version.

The design: `docs/QUIC.md`, "6. QUIC on the network (the fourth layer, built, with Retry and the budgets of work)".

Do not use: connection ID (in prose), CID.

### Packet protection

Packet protection is the AEAD that encrypts the payload of a QUIC packet and authenticates its header, with the key and the iv of one direction of one encryption level.

Each QUIC packet is sealed on its own. The nonce is the iv with the packet number in its last 8 bytes; the additional data is the header without header protection. Initial packets use AES-128-GCM, as RFC 9001 asks; after the handshake this system prefers ChaCha20-Poly1305, whose portable code is 4.6 times faster than the portable AES here. The seal and the open are exports of the cryptography module (`packet_seal`, `packet_payload_open` in `support/quic`).

`quic.datagram_take` copies each datagram once into private memory of the program; the header reading, the removal of header protection and the open in place work on that copy only. A tag that does not verify gives `Not_Authentic`, and the frames are erased. Reserved bits that are not 0 are checked only after the open, so a packet that is not authentic cannot close a connection.

It is not the record layer of TLS over TCP: QUIC carries the handshake in CRYPTO frames and protects whole packets.

The design: `docs/QUIC.md`, "3. Packet protection (the first layer, built)".

Do not use: encryption (for this), record protection.

### Header protection

Header protection is the mask that hides the low bits of the first byte and the packet number of a QUIC packet, made from a sample of the protected payload.

Without it, an observer reads the packet numbers and the key phase of every packet. The mask is 5 bytes, from AES or ChaCha20 over a 16-byte sample taken 4 bytes after the start of the packet number. The cryptography module exports the two masks (`header_protection_mask_with_aes_128`, `header_protection_mask_with_chacha20`), and `support/quic` applies them: 4 bits of the first byte of a long header, 5 of a short one, and the packet number.

The receiver removes it first (`header_protection_remove`), with the header protection key only, which does not change at a key update: it then reads the key phase and chooses the keys for the open.

A peer chooses the sample, so it chooses the counter of ChaCha20 in the mask: a correction of the ChaCha20 code of the origin lets the last block (`ff ff ff ff`) through instead of stopping the program.

The design: `docs/QUIC.md`, "3. Packet protection (the first layer, built)".

Do not use: header encryption.

### Encryption level

An encryption level is one of the sets of keys of a QUIC connection: Initial, Handshake or Application.

The handshake moves through the levels, and each packet type uses one level:

| Level | Keys from | Carries |
|---|---|---|
| Initial | the connection identifier: any observer can compute them | the ClientHello and the ServerHello |
| Handshake | the handshake secrets of TLS | the rest of the flight of the server, the Finished of the client |
| Application (1-RTT) | the application traffic secrets of TLS | the streams |

`quic.Encryption_Level` names the three; the CRYPTO frames of each level carry their own sequence of handshake bytes. Bytes of the handshake at a level that the side left, or of an earlier level that come later, fail the handshake with PROTOCOL_VIOLATION. The Initial keys go when the client sends its first Handshake packet; the Handshake keys go when the handshake is confirmed. This system has no 0-RTT level: it builds no session resumption.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: epoch, key phase (for this).

### Packet number space

A packet number space is the sequence of packet numbers that one encryption level uses: Initial, Handshake or application data.

Each space has its own packet numbers, its own acknowledgements, its own set of received numbers and its own packets in flight. A packet number is unique in its space and never used again. An ACK frame acknowledges numbers of the space of its packet only. The packet number floor of a space refuses numbers that the set of received numbers forgot.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: sequence number (for this).

### Initial packet

An Initial packet is one of the first packets of a QUIC connection, protected with keys that any observer can compute from the connection identifier, which carries the start of the TLS handshake.

The keys of an Initial packet authenticate nothing: they come from a public value with a fixed salt of version 1. So anyone can make an authentic Initial. A server of this system therefore takes a client only after the client came back with the token of a Retry packet, and each authentic Initial that does not complete its handshake ends at the handshake deadline.

A datagram with a client Initial is padded to 1200 bytes, and a server drops a client Initial in a smaller datagram or with a Destination Connection ID under 8 bytes: so a server never answers more than it received. The network service admits a new remote of a UDP listen grant only on a datagram of 1200 bytes at least.

The design: `docs/QUIC.md`, "3. Packet protection (the first layer, built)".

Do not use: handshake packet (for this).

### Raw public key

A raw public key is a public key that a TLS peer sends in its Certificate message alone, with no certificate around it.

The server sends the SubjectPublicKeyInfo of its Ed25519 key: 12 fixed bytes and the 32 bytes of the key, 44 bytes in all. The client offers `server_certificate_type` with the one type RawPublicKey, and the server answers with that type. No other DER is read and no X.509 certificate is read: a parser of certificates is a large parser of hostile input, and the system has no certificate authority, no name and no date to check.

The client trusts the key only when it is the pinned key, and CertificateVerify proves that the server holds its private key, over the transcript. `quic_echo` and `remote` make a new Ed25519 key at each start and write the public key on the log ("remote: the public key of this service: " and 64 hexadecimal digits). The OpenSSL client of the host speaks to `quic_echo` with `-enable_server_rpk`.

The design: `docs/QUIC.md`, "4. TLS 1.3 for QUIC (the second layer, built)".

Do not use: self-signed certificate (for this).

### Pinned key

The pinned key is the one public key that the caller of a TLS client gives it as the key of the server: the client refuses any other key.

`Tls_Configuration.server_public_key` holds it. A server that presents another key fails the handshake with the alert bad_certificate, and `tls_start` refuses a client whose pinned key is 32 zero bytes (no key was pinned). The peer of the kernel tool pins the key that `remote` wrote on its log (the step Remote_Key), or the key that `kerneltool call <key> "..."` names. A pin belongs to one start of the server: each start makes a new key.

A pinned key is not a trust anchor: it vouches for no other key and names no one. It proves only that the client speaks to the holder of that private key.

The design: `docs/QUIC.md`, "4. TLS 1.3 for QUIC (the second layer, built)".

Do not use: trust anchor, root certificate.

### Transcript

The transcript is the handshake messages of TLS, in order, whose hash the key schedule and the Finished messages use.

Each message of each side goes into the transcript as it comes. The key schedule hashes it at fixed points to derive the secrets, CertificateVerify signs its hash, and each Finished is an HMAC of it. So a change of one byte of one message by the path makes the two sides disagree and the handshake fail. The transcript holds 8192 bytes: a ClientHello of up to 4092 bytes and the flight of the server.

The design: `docs/QUIC.md`, "4. TLS 1.3 for QUIC (the second layer, built)".

Do not use: handshake hash (for the bytes).

### Key schedule

The key schedule is the chain of the secrets of TLS 1.3, each one derived from the one before with HKDF and a transcript hash: early, handshake, master, and the traffic secrets of each side.

The X25519 shared secret enters at the handshake secret; the hash of the transcript at each point binds the secrets to the messages. QUIC takes its packet keys from the traffic secrets: `tls_packet_keys` gives the Handshake and the Application keys through `packet_keys_from_secret`, with the labels "quic key", "quic iv" and "quic hp". The code is `support/quic/tls_key_schedule.odin`, tested against the trace "Simple 1-RTT Handshake" of RFC 8448. The secrets of TLS are erased once the 1-RTT keys are installed.

The design: `docs/QUIC.md`, "4. TLS 1.3 for QUIC (the second layer, built)".

Do not use: key derivation (for the whole).

### Alert

An alert is the reason of a failure of TLS, as one byte.

The handshake of this system writes the alert in `Tls_Handshake.alert` and in the `found` field of its error record. QUIC has no alert messages: it closes the connection with the error code 0x100 + alert. Examples: bad_certificate (42) for a key that is not the pinned key, unexpected_message for a message of the wrong type at its level, no_application_protocol for another ALPN.

The design: `docs/QUIC.md`, "4. TLS 1.3 for QUIC (the second layer, built)".

Do not use: TLS error (for this).

### Frame

A frame is one unit of the payload of a QUIC packet: a type, then its fields.

A packet carries one frame or more: STREAM frames with the data of a QUIC stream, ACK frames, CRYPTO frames with the bytes of the handshake, MAX_DATA and MAX_STREAMS for flow control, CONNECTION_CLOSE, and others. Each frame is read as hostile input, with each length checked first: a frame that is cut, a length past the packet or an unknown type is FRAME_ENCODING_ERROR, and a frame at a level where it may not go is PROTOCOL_VIOLATION. A packet of this system carries one STREAM frame at most.

It is not the frame of the network device (an Ethernet frame), which the group "Devices" defines: a QUIC frame lives inside a protected packet inside a UDP datagram.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: message (for this), chunk.

### Ack-eliciting packet

An ack-eliciting packet is a packet with a frame other than PADDING, ACK and CONNECTION_CLOSE, which the peer must acknowledge.

Only ack-eliciting packets count for loss detection, the probe timeout and the congestion window: a packet of ACK frames alone is never acknowledged and never sent again. In the 1-RTT space this side sends an ACK after 2 ack-eliciting packets or 25 ms. The first ack-eliciting packet sent after a receive moves the bound of the idle timeout.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: reliable packet.

### Probe timeout

The probe timeout is the time after which a side that received no acknowledgement sends one or two probe packets, computed from the round-trip time and its variation.

The base probe timeout is the smoothed round trip, 4 times its variation (1 ms at least) and the max_ack_delay of the peer: about 28 to 45 ms on a fast network, about 1 s before any sample. A probe carries the data of the oldest packets in flight, or a PING, and goes past the congestion window. The timeout doubles at each probe that nothing answers.

The idle timeout and the closing and draining states use the base value with no doubling (`probe_timeout_base`). Without that rule, the doubling of the probes moved the idle bound with no end, and a server kept the record of a vanished client for about 2 hours.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: retransmission timeout, RTO (for this).

### Congestion window

The congestion window is the most bytes of ack-eliciting packets that a side has in flight at one time.

It stops a sender from filling the path faster than the path drains. This layer keeps it fixed at 12 000 bytes (`CONGESTION_WINDOW`), the initial window of RFC 9002: it does not grow and does not shrink after a loss (no NewReno, no pacing). Probes go past it.

It is not the flow control limit: the congestion window protects the path, and the flow control limit protects the buffers of the receiver.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: send window (for this).

### QUIC stream

A QUIC stream is one ordered flow of bytes in each direction inside a QUIC connection, named by a stream identifier.

A connection carries several streams at once, and the bytes of one never wait for a loss of another, which is what TCP cannot give. This system has bidirectional streams only, and only the client opens them. A stream ends when both directions ended: this side's last byte acknowledged (or its reset acknowledged), and the end of the peer read by the application. Its identifier then never names a stream again.

A program uses `stream_open`, `stream_write`, `stream_read`, `stream_reset` and `stream_stop_sending`; each stream lives in a stream record. `remote` maps one call to one stream: the call request goes up the stream, the call answer comes back on it, and an error of one call resets its stream only.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: channel (for this), substream.

### Stream record

A stream record is one `quic.Stream` in the table that the caller of a QUIC connection gives: the state and the buffers of one open QUIC stream.

The caller allocates the table, in its own memory, with the connection: a record has two buffers of 64 KiB and about 2 KiB of state, about 130 KiB. Their count bounds the streams that are open at one time, and a server gives the client a limit of streams equal to its records. When a stream ends, its record is free again and its buffers are written with zeros. A program must read each stream to its end: a stream that it never reads keeps its record for the life of the connection.

`quic_echo` gives 4 stream records to each connection record; `remote` gives 8 (`remote.CALLS_AT_ONCE`).

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: stream slot.

### Limit of streams

The limit of streams is the count of QUIC streams that one side allows the other to open since the start of the connection (MAX_STREAMS).

It is a count since the start, not a count of open streams. A server of this system gives the client a limit equal to its stream records in the transport parameters, then raises it by one with a MAX_STREAMS frame each time a stream of the client ended. So the limit never promises a stream that has no record. A client that reaches the limit sends STREAMS_BLOCKED and waits; a frame for a stream past the limit is STREAM_LIMIT_ERROR, before any record is taken.

Example: `remote` has 8 stream records; a host that opens a 9th stream waits for the MAX_STREAMS that comes when one of the 8 ends.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: stream credit, concurrency limit (for this).

### Implicit open

An implicit open is the open of a QUIC stream by a frame of the peer that names it, or names a higher stream of the same kind, before the peer sent anything on it.

Streams of one kind open in order, so a frame for client stream 8 also opens the client streams 0 and 4 that are not open yet. The limit of streams bounds that count: a stream far ahead within the limit takes records that exist, and one past it is STREAM_LIMIT_ERROR. The program finds the streams that the peer opened by a walk of `connection.streams`.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

### Flow control limit

A flow control limit is the largest offset of data that a side allows the peer to send, for one stream (MAX_STREAM_DATA) or for the whole connection (MAX_DATA).

It protects the buffers of the receiver: a side never receives more than it has room for. Here each stream has 64 KiB, moved forward when the application read half of it; the connection has the buffers of every stream record (256 KiB for 4), moved forward the same way. Data past a limit closes the connection with FLOW_CONTROL_ERROR; a final size that changes is FINAL_SIZE_ERROR. A reset counts its final size, and the bytes that the application never read give their room back to the connection.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: receive window (for this).

### Anti-amplification limit

The anti-amplification limit is the rule that a server sends at most 3 times the bytes that it received from a client whose address it did not validate.

An attacker can forge the source address of a datagram. Without the limit, one small forged datagram can make a server send a large answer to a victim. The limit is held twice:

- by `support/quic` in the program, until the address validation of the connection; this side counts only the datagrams that it processed;
- by the network service, which knows no QUIC: for each admitted remote of a UDP listen grant it counts the bytes in and out and refuses a Send past 3 times (the status `Amplification`), until the program sends the command `Validate`.

A Retry packet (113 bytes at most) answers a datagram of 1200 bytes, so a reflection carries less than a tenth of what the attacker sent.

The design: `docs/QUIC.md`, "6. QUIC on the network (the fourth layer, built, with Retry and the budgets of work)".

### Address validation

Address validation is the proof that a client receives datagrams at the address that it claims.

Until it, a server holds the anti-amplification limit. A connection of this system validates the address of the client in two ways: a Handshake packet of the client, which needs the keys of the server's flight; or, at the server of several connections, an Initial that carries the retry token of that address. Each record of `quic.Server` is validated at its start, because a record needs a token. The program then sends `Validate` to the network service for that remote, which makes it a validated remote.

The design: `docs/QUIC.md`, "6. QUIC on the network (the fourth layer, built, with Retry and the budgets of work)".

### Handshake confirmed

Handshake confirmed is the point after which a side drops its Handshake keys: a server when its handshake completes, a client when HANDSHAKE_DONE comes.

Before it, a side can still need the Handshake keys to send the flight again. After it, those keys are erased, and a Handshake packet is dropped. A server sends HANDSHAKE_DONE in its first 1-RTT packet after the Finished of the client; a server that receives one gets PROTOCOL_VIOLATION.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: handshake done (for the state).

### Connection record

A connection record is one `quic.Connection` in memory of the program: all the state of one QUIC connection.

The record holds the three packet number spaces, the keys, the handshake of TLS, the timers and the connection identifiers: no allocation and no kernel call happen behind it. Its streams are in a separate table of stream records. A record goes in global memory or in a mapping of the program, never on a stack: a stack of 256 KiB leaves too little room for the cryptography module and the 16 KiB that it erases. A server holds a table of records in one mapping; each time a record is taken it gets a new generation.

`quic_echo` has 16 records of about 85 KiB with 4 stream records each, about 10.8 MiB in one mapping. Its log line "listening on the UDP port 4433" prints the real sizes.

It is not a socket: the network service sees only datagrams of an endpoint, and the program holds the whole connection.

The design: `docs/QUIC.md`, "6. QUIC on the network (the fourth layer, built, with Retry and the budgets of work)".

Do not use: session (for this), socket.

### Version Negotiation packet

A Version Negotiation packet is the packet with the version 0 that a server sends to a client whose long header names a version that the server does not speak: it lists the versions that the server speaks.

A server of this system speaks version 1 only. It answers a long header of another version in a datagram of 1200 bytes at least, with one packet of 51 bytes at most, and 16 in one second at most. The packet has no authentication; a client of this system speaks version 1 only and never needs one.

The design: `docs/QUIC.md`, "6. QUIC on the network (the fourth layer, built, with Retry and the budgets of work)".

Do not use: version error.

### Retry token

A retry token is the value that a server gives in a Retry packet and that the client sends back in its next Initial packet, to prove that it receives datagrams at its address.

This system seals the token with ChaCha20-Poly1305, under a key of 32 bytes that the server makes at its start: it seals the original Destination Connection ID of the client, the identifier of the Retry and the time, with the remote address and port as additional data. The token has 62 bytes. It does not open for another address or port, after a change of one byte, after another start of the server, or more than 10 s after the Retry (`RETRY_TOKEN_LIFETIME`).

A token takes a record once: the server keeps the counter of each token that took a record, 64 of them for 10 s. A replay can come only from the address and port of the client, within 10 s.

It is not the token of NEW_TOKEN, which a server gives for a later connection: a client of this system keeps none. It is not a token of a token bucket.

The design: `docs/QUIC.md`, "6. QUIC on the network (the fourth layer, built, with Retry and the budgets of work)".

Do not use: cookie (for this), address token (for the token of NEW_TOKEN).

### Validated remote

A validated remote is an admitted remote of a UDP listen grant that the program marked with the command `Validate`, because it proved its address.

The network service then sends to it with no limit of 3 times the bytes that came from it. `quic_echo` and `remote` validate a remote when its client came back with the token of a Retry. A record asks the program to validate its remote at each datagram until a `Validate` for its generation gives 1, because a `Validate` that came after a `Release` changes nothing.

A program that validates every remote lifts the limit for each address that sent it a datagram: it can then send any volume to an address whose name came in one forged datagram, for 120 s. The principal revokes the grant of such a program.

The design: `docs/QUIC.md`, "6. QUIC on the network (the fourth layer, built, with Retry and the budgets of work)".

Do not use: trusted remote, whitelisted address.

### Stateless reset

A stateless reset is a packet that ends a connection whose state a side lost, proven by a token that the side gave before.

It is not built. A server of this system that restarts forgets its connections, and their clients end at their idle timeout. A connection drops a datagram of this kind.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: reset (for this).

### Handshake deadline

The handshake deadline is the time after which a connection whose handshake did not complete ends: 10 s from the start of a client, or from the first authentic Initial at a server.

Anyone can make an authentic Initial packet, so without a deadline a few packets could hold records of a server for the whole idle timeout. `HANDSHAKE_TIME_LIMIT` ends such a record whatever the idle timeout. A client has the same limit: a client that a server over a limit ignores ends at its own deadline. The deadline counts time of the machine: in `remote`, isolated calls count in it too.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: handshake timeout (for the value).

### Packet number floor

The packet number floor is the packet number below which a side refuses each packet of a space, because its set of received numbers forgot those ranges.

The set of received packet numbers keeps 32 ranges. When it drops its lowest range, it can no longer tell whether a number below it came before, so it raises the floor to the end of that range (`packet_number_floor` of a space). A packet below the floor is refused before its open, so that no packet is processed two times.

It is not a replay window of a fixed width: it moves only when the set loses a range.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: replay window.

### Idle timeout

The idle timeout is the time with no activity of the peer after which a side ends a QUIC connection with no packet: the smaller of the values that the two sides give, and 3 base probe timeouts at least.

It frees the record of a peer that vanished. The activity that moves its bound is a packet received, processed and recorded, and the first ack-eliciting packet sent after it; a datagram that does not authenticate, or a replay, moves nothing. A server of this system always has one: `server_init` refuses an idle timeout of 0. `quic_echo` uses 30 s, and logs at each idle end whether the end held its bound:

```
the idle end held its bound
```

It is not a keep-alive: this side sends nothing to keep a connection open.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: keep-alive.

### Closing state

The closing state is the state of a side that sent CONNECTION_CLOSE: for 3 base probe timeouts, it answers datagrams of the connection with its close.

The close can be lost, so the side answers again when the peer sends more. A record of this system answers the 1st, 2nd, 4th, 8th... datagram, not each one, and does not open them: a third party that knows the identifier makes at most a few packets of about 50 bytes.

The design: `docs/QUIC.md`, "6. QUIC on the network (the fourth layer, built, with Retry and the budgets of work)".

### Draining state

The draining state is the state of a side that received CONNECTION_CLOSE: it sends nothing for 3 base probe timeouts, then ends the connection.

It lets the packets of the peer that are still on the path arrive and be dropped, with no answer.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

### Transport parameters

The transport parameters are the values that each side of QUIC gives the other inside the TLS handshake: its limits, its timeouts and the connection identifiers that it used.

They ride in the extension `quic_transport_parameters`, so the handshake authenticates them. Examples: the flow control limits, the limit of streams, the idle timeout, max_ack_delay, `disable_active_migration`, and `original_destination_connection_id` and `retry_source_connection_id` after a Retry. Each value of the peer is checked: a repeated parameter, a value out of its range, a parameter that only a server sends, or an identifier that is not the one of the packets gives TRANSPORT_PARAMETER_ERROR.

They are not settings of the system: they belong to one connection.

The design: `docs/QUIC.md`, "5. The transport of one connection (the third layer, built)".

Do not use: settings.

### Retry packet

A Retry packet is a packet of a server that asks the client to send its Initial packet again with a retry token, to prove its address.

A server of this system answers each Initial with an unknown identifier and no token with a Retry, and keeps nothing: no record, no key, no open of the Initial. Its integrity tag is AES-128-GCM with a fixed key of version 1 over the Retry Pseudo-Packet: it proves to the client only that the Retry answers its own Initial. A client takes one Retry, before any Initial of the server, then derives its Initial keys from the identifier of the Retry and sends its ClientHello again with the token.

A Retry has 113 bytes at most, and its budget of work is 20 000 in one second.

The design: `docs/QUIC.md`, "6. QUIC on the network (the fourth layer, built, with Retry and the budgets of work)".

Do not use: redirect.

### Table of address budgets

The table of address budgets is the table of a QUIC server that holds a budget of Initial checks for each address whose retry token opened.

A host with one real address can take one Retry and then send many Initials with its valid token that do not open. Each costs about 30 µs of cryptography, so each address gets its own token bucket: 4 checks at once, then 1 in each second. The table has 1024 places (32 KiB in `quic.Server`). A new address takes a place only when the place holds no information: free, or its bucket full again. So the table gives at most the sum of its buckets: 4096 checks once, then 1024 in each second, half of the shared budget. When no place can move, the new address gets no check (`address_table_full` counts it).

The design: `docs/QUIC.md`, "6. QUIC on the network (the fourth layer, built, with Retry and the budgets of work)".

Do not use: address cache.

### Budget of work

A budget of work is the most pieces of one kind of work that a QUIC server does for datagrams of unknown identifiers, as a token bucket.

The work of a datagram of an unknown identifier is cryptography for a sender that nobody checked yet. The server has three shared budgets:

| Work | Rate | Depth | Cost of one |
|---|---|---|---|
| Retries | 20 000 in one second | 2000 | about 10 µs |
| Token checks | 30 000 in one second | 3000 | about 3 µs |
| Initial checks with a valid token | 2000 in one second | 200 | about 30 µs |

A datagram over a budget is dropped before any cryptography. When a flood spends every budget, the work of new identifiers takes about 350 ms of each second of one processor. The datagrams of known records have no budget and come first. A flood above a shared budget still stops new clients while it lasts: a forged Initial and the first Initial of a real client look the same until the Retry comes back.

It is not a budget of the kernel: a budget of memory pays for kernel objects. A budget of work bounds time spent by one program.

The design: `docs/QUIC.md`, "6. QUIC on the network (the fourth layer, built, with Retry and the budgets of work)".

Do not use: rate limit (for this), quota.

### Token bucket

A token bucket is a count of units that grows by a rate in each second up to a depth, and from which each piece of work takes one unit.

A burst takes the depth at once, then the rate: no boundary of a window lets a burst get the budget of two seconds in one millisecond, as a fixed window of one second did. `quic.Work_Bucket` counts millionths of a unit, so a rate per second adds its value in each microsecond, and a bucket that was never used starts full. The budgets of work and the table of address budgets are token buckets.

The tokens of a bucket are units of work, not retry tokens.

The design: `docs/QUIC.md`, "6. QUIC on the network (the fourth layer, built, with Retry and the budgets of work)".

Do not use: leaky bucket, fixed window.

### UDP relay

The UDP relay is the part of the peer of the kernel tool that carries UDP datagrams between a program of the host, on a socket of the loopback, and the UDP port 4433 of the machine.

QEMU user networking with `restrict=on` drops each UDP datagram that the machine sends, so a UDP forward of the host cannot reach `quic_echo`. The relay replaces it: a datagram of a client of the host becomes a frame from 10.0.2.2 to 10.0.2.15 port 4433, from a port that the relay gives that client (42000 plus its place in a table of 16), and the answers go back the same way. A datagram over 1472 bytes is dropped and counted. `kerneltool test quic-real` uses it to run the OpenSSL QUIC client of the host against `quic_echo`.

The design: `docs/QUIC.md`, "6. QUIC on the network (the fourth layer, built, with Retry and the budgets of work)".

Do not use: port forward, proxy, hostfwd (for this).

## Trusted boot

### Signing key

The signing key is the Ed25519 key pair of the principal that signs the system: its private key signs the system description, and the boot program holds its public key.

The signing key answers one question at each start: is this the system that its signer built, byte for byte? The build signs the system description, which names each module and resource by its hash; the boot program verifies the signature before the kernel starts, then compares each file with the description. A changed module, a module of another build, or a description changed without the private key stops the start.

How a principal gets and uses one:

1. `nix develop -c kerneltool key new <folder>`, with a folder outside the repository, writes `signing_key` (64 hexadecimal digits, readable by its owner only) and `signing_key.public`, then the firmware signing key beside them.
2. `SYSTEM_SIGNING_KEY=<folder>/signing_key` before each build names the private key. The tool refuses a path inside the repository and a file that the group or the others can read.
3. The build puts the public key in the boot program and signs the description of each boot volume. `kerneltool key show` prints the public key that the build uses.

With no variable, the build signs with the test signing key. A lost key signs nothing new; a stolen key signs a system that the boot program accepts, and no list of revoked keys exists: make a new key and a new boot program at once.

The signing key is not a key of the TPM: the TPM measures the description, seals keys and keeps the key of the machine, and it signs nothing at the start. It is not the platform key of Secure Boot: Secure Boot verifies the boot program with the firmware signing key, an RSA key.

The design: `docs/TRUSTED_BOOT.md`, "5. The signing key".

Do not use: owner key, master key, release key, platform key (PK is a term of Secure Boot).

### Test signing key

The test signing key is the signing key of the tests: a key pair whose private key is published, so that a system that it signs is never trusted.

The key pair is the one of RFC 8032, section 7.1, TEST 1, in `resources/keys/test_signing_key`. Each build with no `SYSTEM_SIGNING_KEY` uses it: the test builds and the pictures of the site do. Anyone can sign a system with it, so:

- the trust record has the key kind `Test`;
- the boot display shows "the TEST key: its private key is public" in red;
- the root service writes a warning on the log;
- the tool writes beside the boot volume a file `<volume>.signed_by` that says "do not install this volume on a real machine".

The design: `docs/TRUSTED_BOOT.md`, "5. The signing key".

Do not use: development key, demo key.

### Signed message

The signed message is the 64 bytes that the signing key signs for one system description: a fixed label padded with zero bytes to 32 bytes, then the BLAKE3 hash of the description.

The label `system description signature 1` (`SIGNATURE_LABEL` of `contract/system_description`) binds the signature to this one use: a signature that the key makes for another purpose is never a valid description signature. The number in the label names the version of the form. `system_description.signed_message` builds the bytes. The measure puts the same 64 bytes in the event log of the firmware, so the log names the system by its BLAKE3 identity.

The design: `docs/TRUSTED_BOOT.md`, "1. The claims".

Do not use: payload, digest (for this).

### Description signature

The description signature is the Ed25519 signature, 64 bytes, of the signed message of a system description.

The boot image holds it as its last resource, `system_description_signature`, after the resource `system_description`. The description does not list these two resources, because a file cannot hold its own hash. At each start, before the kernel starts, the boot program verifies it with the public key that it holds, with the Ed25519 code of `support/cryptography/ed25519` linked into it. A signature that does not verify stops the start with the line:

```
boot program: the signature of the system description is wrong
```

It is not a certificate: it names no one and has no date. The boot program accepts each description that the key signed, an older one too: no counter refuses it yet.

The design: `docs/TRUSTED_BOOT.md`, "3. The system description".

Do not use: certificate, manifest signature.

### Trust record

The trust record is the record `boot_info.Boot_Trust` that the boot program writes to say what verified the system description, with which key, and what the TPM holds.

Its fields:

- `verifier`: `Boot_Program` (the firmware did not verify the boot program) or `Firmware_And_Boot_Program` (Secure Boot was on);
- `key_kind` and `public_key`: the test signing key or another key, and the public key that verified the description signature;
- `description_hash` and `entry_count`: the BLAKE3 hash and the entries of the system description;
- `measure`, `measure_register`, `measure_value`, `measure_status`, `measure_tries`: `Measured`, `No_Tpm`, `Refused` or `Not_Read`, the register, its value read back, and the tries.

The kernel copies it into the boot record. The root service takes the system description of the boot image only if its hash is `description_hash`, and puts the measure in the record of principal 0, the machine. The boot display draws its line "trust" from it: the key, what verified, and the measure.

It is not an attestation: it is what the boot program says about itself, and a replaced boot program can write a false one. Only Secure Boot makes it come from a verified boot program.

The design: `docs/TRUSTED_BOOT.md`, "4. What a failure shows".

Do not use: attestation, security state.

### Measure

The measure is the extension of a register of the TPM with the SHA-256 hash of the system description, which the firmware does at the request of the boot program before the kernel starts.

A TPM register can only be extended, never set: after a reset, PCR 11 then holds `SHA-256(32 zero bytes || SHA-256(description))`, and no code that runs later can set it back. So a key sealed to that value, or a remote party that reads it, can depend on which system started. The system seals no key to it and answers no remote party yet.

The path: after its checks, the boot program calls `HashLogExtendEvent` of the TCG2 protocol of the firmware, with an event `EV_IPL` whose data is the signed message, then reads PCR 11 back and writes the value in the trust record. The boot program has no TPM driver. It tries 4 times, 0.5 s apart. If every try fails, the boot continues: the trust record says `Refused`, and the boot display says "TPM refused the measure" in red.

The measure is as honest as the boot program that asks for it: a replaced boot program can extend PCR 11 with the hash of a correct description and start other code. The TPM measures and seals; it does not verify and does not sign the description.

The design: `docs/TRUSTED_BOOT.md`, "6. The measure".

Do not use: attestation (for this), seal, measurement log (for this).

### Measure register

The measure register is PCR 11 of the TPM: the register that holds the measure.

The rules of the TCG for PC firmware leave PCR 8 to 15 to the operating system, and the conventions of Linux give PCR 11 to the whole system image that a boot stage measures before the kernel. The firmware of the test machine does not write it. `boot_info.MEASURE_REGISTER` is 11. The firmware extends it in each active bank; the trust record keeps the value of the SHA-256 bank, and `kerneltool` computes the same value from the description and compares.

The system reads no other register: PCR 4 (where the firmware measures the boot program) and PCR 7 (the Secure Boot state) are read by nothing.

The design: `docs/TRUSTED_BOOT.md`, "6. The measure".

Do not use: slot, PCR (alone, for this register).

### Firmware signing key

The firmware signing key is the RSA-2048 key and its self-signed X.509 certificate with which the principal that signs the system signs the boot program for Secure Boot.

UEFI Secure Boot verifies Authenticode signatures with RSA keys and X.509 certificates, and cannot verify Ed25519. So a second key closes the gap of the first: without Secure Boot, anyone who can write the boot volume can replace the boot program, its public key and its checks. `kerneltool key new` makes the pair with `openssl` beside the signing key (`firmware_signing_key.pem`, `firmware_signing_key.crt`). The build signs the boot program with `sbsign` and keeps the unsigned copy. The firmware keeps the certificate in its variable `db`, which a principal present at the machine enrols in the setup of the firmware.

With Secure Boot on, the trust record says `Firmware_And_Boot_Program`. A machine whose `db` also holds the certificates of a vendor starts each boot program that the vendor signed.

The design: `docs/TRUSTED_BOOT.md`, "7. Secure Boot".

Do not use: db key (for the pair), Secure Boot key.

### Test firmware signing key

The test firmware signing key is the firmware signing key of the tests, whose private key is published, so that a boot program that it signed is never trusted.

The pair is `resources/keys/test_firmware_signing_key.pem` and `.crt`; `kerneltool key test-firmware-new` wrote it once. The variable store of the test machines of Secure Boot has its certificate as PK, KEK and the one entry of `db`. `kerneltool test trusted_boot` checks with it that the signed boot program starts, and that a boot program with one byte changed, or unsigned, does not.

The design: `docs/TRUSTED_BOOT.md`, "7. Secure Boot".

Do not use: development certificate.

## Project

The words of this group name how the project is run and published: the documents that hold its rules and its state, the units of the work, and the site, the changelog and the news that report it.

### Property

A property is one of the 21 fundamental concepts of the system, each with its rule, its reasons and its costs, in `docs/PROPERTIES.md`.

The properties are the reference against which every proposal is measured: a proposal that contradicts one is named as such before any work on it, and only the owner of the project can change a property. Each property has a number and a title ("10. One code module", "17. Trusted boot: UEFI program, Secure Boot, TPM"), and a status in the summary table of the document. The status page of the site shows each property with its status, the evidence items and the gaps that name it.

A comment in a source never names a property by its number: it states the reason in words, or points to the heading of a guide. `kerneltool check` refuses "(property 14)" and "(P20)" as a comment breach.

The design: `docs/PROPERTIES.md`.

Do not use: principle (for this), requirement, axiom.

### Decision

A decision is one entry of `docs/DECISIONS.md`: who decided what, when, and in which words, under an identifier `D-nnn` that never changes.

The file is the record of the project, and the first document to read. Each entry gives the date, who decided (the owner of the project, the coordinator, or an agent), the decision, the exact words of the owner in their language, its state (in force, done, not done yet, replaced by another, open) and where it is carried out. A decision of the coordinator or of an agent holds until the owner reverses it. A new decision takes the next free identifier, at the end of its group, and the guide of its subject states the rule with no name, no role and no date.

A guide and a comment never name a decision: they state the rule. The record of who chose it stays in `docs/DECISIONS.md`.

The design: `docs/DECISIONS.md`, "How to read and write this file".

Do not use: ADR, ruling, resolution.

### Step

A step is one tested commit on `master` that adds one capability to a system that works.

The project grows in steps: each step leaves the system whole, built and tested, with its documents up to date in the same commit. `docs/REVIEWS.md` lists each step with its commit and its capability ("1, `7305ad2`, Isolated call"). The home of the site shows the count of steps. Several features can be written at once on branches; each merge still needs its build and the test of its own part.

A step is not a stage of the start of the machine (the "Step of the start" of the group "Running code"), and not a step of a machine test, which waits for one line of the log.

The design: `docs/REVIEWS.md`.

Do not use: iteration, sprint, milestone (for this).

### Choice

A choice is a decision made during the implementation that the owner has not reviewed, numbered in the section "Choices made during the implementation" of `docs/FIRST_MILESTONE.md`.

Writing code needs many small decisions that no property or decision settles: a format, an order, a limit. Each one is recorded as a numbered choice with its reason ("1. **Export numbers.** The kernel tool holds an ordered export list per module..."), so that the owner can read it and reverse it. A choice can change at any time.

A comment never names a choice by its number; the site writes a pointer `choice <n>` of a guide as a link to its item.

The design: `docs/FIRST_MILESTONE.md`, "Choices made during the implementation".

Do not use: decision (for this: a decision is an entry of `docs/DECISIONS.md`), design note.

### Review

A review is a read of the work against the properties and the rule "no bad compromise", which lists each concession and what removes it.

The project asks for one after each five steps; the record of each is in `docs/REVIEWS.md`. Kernel code also has an independent review before each merge: a fresh read of the change, often by a new agent session. A finding of a review has a label, and its correction refers to the finding in the record, never in a comment of the code.

The design: `docs/REVIEWS.md`.

Do not use: audit, code review (for the whole), retrospective.

### Evidence item

An evidence item is one numbered item of the section "Evidence" of `docs/FIRST_MILESTONE.md`: an action of the machine test that shows that a part of the system works.

The machine test starts the machine under QEMU, acts as the input through the QEMU monitor (keys, pointer moves, clicks) and waits for a text of the log at each step. Each evidence item says what that scenario does and what it proves ("Start `fault`. The kernel stops it on a page fault. The other programs continue."). The status page shows, for each property, the evidence items that name it.

The design: `docs/FIRST_MILESTONE.md`, "Evidence".

Do not use: proof, test case (for this), demo.

### Gap

A gap is one item of the section "Gaps" of `docs/FIRST_MILESTONE.md`: a difference between the code and the documents, or a part that is not built, not run or not measured.

The project states what is not done as plainly as what is done. A gap names the part, what is missing, and often who must act ("The coordinator fills the three numbers of the measure..."). The status page lists each gap with its number and its group, and shows under each property the gaps that name it. A document that says what the code no longer does is itself a fault, as a failing test is: it is corrected, not listed as a gap.

The design: `docs/FIRST_MILESTONE.md`, "Gaps".

Do not use: issue, bug (for this), todo, known limitation.

### Working record

A working record is a document of `docs/` that records the work, not the system: `HANDOFF.md`, `REVIEWS.md`, `SITE.md` and `FIRST_MILESTONE.md`.

A guide explains how a part of the system is designed and why; a working record holds steps, choices, gaps, reviews and the state of the work. So the site publishes the guides and not the working records (`SITE_WORKING_RECORDS`): a link of a page to a working record names the file in the repository, and says so. `docs/DECISIONS.md` is the record of the decisions.

The design: `docs/SITE.md`, "The pages".

Do not use: internal document, notes.

### Changelog

The changelog is the file `CHANGELOG.md`: the releases of the system, newest first, each with the changes that a reader of the system notices.

It follows the format of Keep a Changelog 1.1.0 and semantic version numbers. Each entry starts with a short bold summary, then says what the system does now, for a reader, not how the code changed. No one edits the file by hand: a branch adds a fragment for each change, and `kerneltool changelog release` moves the fragments into a new release. So two branches never change the same lines. The site shows the whole file at `releases/` and in the feed `releases.xml`.

The changelog lists every change for a developer of the system; a news entry reports one thing for a reader who is not a developer.

The design: `docs/SITE.md`, "The pages".

Do not use: release notes (for the file), history, news.

### Release

A release is one section of the changelog: a release number, a date, and the entries of its changes, in the parts Added, Changed, Deprecated, Removed, Fixed and Security.

A release marks a state of `master` that passed its checks. `kerneltool changelog release` makes it: it moves the fragments of `changelog.d/` into a new section `## [<number>] - <date>`, deletes them, and writes the release number in `contract/release`. Example: `## [0.91.0] - 2026-11-12`. On the site each release has the anchor `release-<number>` and links to each news entry that names it.

It is not a version: a stored object of the system has versions. It is not a git tag, and not a build: many builds come between two releases.

The design: `docs/SITE.md`, "The pages".

Do not use: version (a stored object has versions), tag, build.

### Release number

The release number is the number of a release, in the form `<major>.<minor>.<patch>`.

The project is before its first major release, so a release number is `0.N.0` for a release of new work and `0.N.1` for a correction after it. `RELEASE_NUMBER` in `contract/release` holds the newest one (today `"0.91.0"`); the foot of each page of the site and the page graph name it. The tool writes it; no one edits it by hand.

The design: `docs/SITE.md`, "The pages".

Do not use: version number, version.

### Fragment

A fragment is one file of `changelog.d/` that holds one change that is not in a release yet: its type and the text of its entry.

A branch adds one fragment for each change that a reader notices, in the same commit as the change: `kerneltool changelog new <type> <subject> - < text.md` writes `changelog.d/<yyyymmdd-hhmmss>-<subject>.md`. Line 1 is `type: <type>` (Added, Changed, Deprecated, Removed, Fixed or Security), line 2 is empty, then one paragraph:

```
type: Added

**The thing**: what the system does now, for a reader, in one or two sentences.
```

A change with no effect that a reader notices (a document, a comment) has no fragment. `kerneltool changelog release` moves the fragments into a release and deletes them.

The design: `changelog.d/README.md`.

Do not use: changeset, news file, entry (for the file).

### News entry

A news entry is a dated report in prose, for a reader who is not a developer of the system, of one thing that the reader can see or use, with its picture.

Each entry is one file of `news/`, `news/<yyyy-mm-dd>-<subject>.md`, never moved or merged: a head of six lines (`title`, `date`, `release`, `picture`, `kind`, `guide`), an empty line, then at most 1200 bytes of text. Its kind is one of four:

- **Shown**: a new thing can now be seen or used in the running system;
- **Measured**: a number about a thing that exists, with its conditions;
- **Decided**: a choice that a reader sees, such as a name, a mark or a font;
- **Fixed**: a thing that failed now works.

`kerneltool news new <subject>` writes an empty entry, and `kerneltool news check` refuses it until a title and a text are written. The site shows each entry as a card on `news/`, the three newest on the home, and each in the feed `news.xml`. An entry states the fact; it never says who decided.

The changelog lists every change for a developer; a news entry reports one thing, in a few sentences, and names the guide that explains it.

The design: `docs/SITE.md`, "The news".

Do not use: news item, post, announcement, blog post, changelog entry.

### Feed

A feed is a file of the site in the Atom format (RFC 4287), for a program that follows a site: `news.xml` has the news entries and `releases.xml` the releases, newest first.

A feed reader subscribes to the address of the file and shows each new entry. Each page names both feeds in its head, so a browser finds them. The id of each entry is the address of its file in the repository on `master`, so it does not change when the site gets an address. With no site address the links of a feed are relative and it has no link `self`.

The design: `docs/SITE.md`, "The news", and "The sitemap, robots.txt and the feeds".

Do not use: RSS (for these files), stream, channel.

### Search index

The search index is the file `search.json` of the site: one entry for each page, and for each thing of a page that a reader looks for, with its title, its page, its anchor, its kind and a short text.

The kinds are, in their order: page, module, program, export, operation, error kind, console command, term, guide section, property, news entry, release, gap, license row and type. Each entry comes from the same data as its page: a term has its short definition, an export its signature as the console prints it. The search field filters the index in the browser with the fuzzy match of the console, ported rule for rule, so the site needs no server for its search. The index has at most 4096 entries and 1 MiB; the command checks that each entry names a page and an id that exist.

It is not the sitemap: the sitemap lists pages for a search engine; the search index lists things inside pages for the search field.

The design: `docs/SITE.md`, "The index".

Do not use: search database, catalog, sitemap.

### Search field

The search field is the one field of a page of the site where a reader types a search.

On each page it is in the site menu of the bar; on the docs home it is a large field in the page, and the bar has none. One script, `search.js`, serves both places: it loads the search index at the first key, and shows at most 8 rows in the look of the completion list of the console. `/` puts the focus in it; Up, Down, Enter and Escape work as in the console. The query is in the address as `?q=<query>`, so a search can be linked. With no script, the field is hidden and the site stays whole by its links.

The design: `docs/SITE.md`, "The search".

Do not use: search box, search bar, omnibox.

### Mark

The mark is the picture that stands for the system: a heron on a grid of 24 by 24 square cells, each part filled with one gradient.

`support/mark` holds it as data: the rows of the still heron, the colors of each part and the animations of the mark. Every picture of the mark comes from that one table: `kerneltool logo` writes the files of `resources/logo`, the site draws its own pictures and its icons, and the system draws it on the boot display. The squares follow the design of the system: rectangular forms, no rounded blob.

The design: `docs/DESIGN.md`, "11. The mark".

Do not use: logo, icon, emblem, mascot.

### Name of the mark

The name of the mark is the word "modus" drawn in letters of square cells, 5 columns by 7 rows each, under or beside the heron.

It is drawn from the same cells as the heron, so the files of the mark with a name keep one grid. A picture holds it only where one file must carry the heron and the name: the files `resources/logo/modus*.png` and the picture of the site for other sites. On a page of the site the picture is the heron alone, and the name is text in the font of the name of the mark. The boot display draws it at the right of the heron.

The design: `docs/DESIGN.md`, "11. The mark".

Do not use: wordmark, logotype.

### Font of the name of the mark

The font of the name of the mark is a font file whose glyphs are the cells of the letters of the name of the mark.

It lets a page write the name as text and show the letters of the mark: a reader selects the text, and a screen reader says it. `kerneltool logo` writes it from `mark.name_letters` as `resources/logo/modus_mark.ttf`, a TrueType file, and `kerneltool check` compares its bytes. It has the letters m, o, d, u and s, their capitals with the same glyphs, and the space; it is not a font for a text. One em is 8 cells, so a font size that is a multiple of 8 pixels draws whole cells. Example: the bar of the site shows the heron as a picture of 24 pixels, then "modus" in this font at 16 pixels: cells of 2 pixels.

The design: `docs/DESIGN.md`, "The font of the name".

Do not use: logo font, wordmark font, pixel font.

### Still heron

The still heron is the heron of the mark with no animation: the 24 rows of `heron_rows` in `support/mark`.

Each animation starts from it and ends on it, and it is the frame 0 of each one. A picture that does not move (a file of `resources/logo`, an icon, the boot display) shows it.

The design: `docs/DESIGN.md`, "11. The mark".

Do not use: rest pose, idle frame, base frame (a base frame is another thing: see Animation of the mark).

### Animation of the mark

An animation of the mark is a short list of frames in which a few cells of the still heron change.

In a frame a cell takes the letter of another part, or becomes empty. Each frame has a duration in milliseconds, and starts from the still heron or from an earlier frame of the same animation, its base frame. After its last frame the heron is still again. The animations are data in `support/mark/animation.odin`, and the order of play chooses which one comes next. On the site, `mark_animation.js` plays them from the sprite sheet.

The design: `docs/DESIGN.md`, "11. The mark".

Do not use: idle animation, clip, tween.

### Order of play

The order of play is the fixed list of the steps of the animations of the mark: each step a still time, then one animation; the list repeats.

The weight of an animation is how many times it is in the order (`animation_weight`). A fixed order makes each play the same, with no random choice: the same page shows the same heron at the same time after its load.

The design: `docs/DESIGN.md`, "11. The mark".

Do not use: playlist, random choice, schedule.

### Sprite sheet

The sprite sheet is one PNG file of the site that holds each distinct frame of the animations of the mark side by side, from the left, with the still heron first.

The script of the mark shows one sprite at a time by its place in the file, so the page loads one picture for all the animations. A frame that two animations share is in the file once.

The design: `docs/SITE.md`, "The mark on the site".

Do not use: atlas, film strip.

### Site

The site is the documentation of the system as static pages, with their style sheet and their pictures, that `kerneltool site` writes in `build/site` from the files of the repository and the logs of the machine tests.

Every fact of the site comes from a file: the guides from `docs/`, the reference tables from the sources, the numbers from the logs or the measure record, the news from `news/`. The command checks every page before it writes one, and stops on a fault with the page and the reason: a broken link, a missing alt text, two pages with one title, a document named as bare text. Each page is whole with no script and makes no request to another host. The site workflow publishes it at `https://modus.froment.software/`. Its home is the one page that shows the system: the mark, the tagline, the news, the stages of the start and the pictures of the machine.

The design: `docs/SITE.md`, "The command".

Do not use: website, homepage, landing page.

### Docs

The docs is the section of the site that holds the guides and the reference: the bar names it "Docs", and the addresses of its pages start with `/docs/`.

Its first page is the docs home. The guides explain how each part of the system is designed and why; the reference lists what exists in this build, from the sources. The status page is not a part of it: it reports the state of the work.

The word "Docs" names the section because "Documentation" is already the term for the text that a module carries.

The design: `docs/SITE.md`, "The sections".

Do not use: documentation (for this: Documentation is the text of a module), manual, help center.

### Docs home

The docs home is the first page of the docs, at `/docs/`: a large search field, the chart of what the search finds, then a card for the guides and a card for the reference.

It is a door, not a list. Its search field is the one field of the page, and the bar has none. Under it, the chart shows one segment and one chip for each kind of the search index, with its count; while a text is in the field, the counts follow the matches, and a chip keeps the results to its kind. The card of the guides lists each guide with its one line of description; the card of the reference lists each reference table with its count. It has the presentation layout.

The design: `docs/SITE.md`, "The docs home".

Do not use: docs landing page, portal, hub.

### Guide

A guide is a page of the site made from a document of `docs/`: how a part of the system is designed, and why.

Examples: `docs/ARCHITECTURE.md`, `docs/QUIC.md`, `docs/FONTS.md`. A guide states each rule with no name of a person or a role, no step, no choice and no date: that record is `docs/DECISIONS.md`. The working records are not guides and are not published. On the site a guide has the documentation layout, and its code spans link to the declarations and documents that they name.

The design: `docs/SITE.md`, "The pages".

Do not use: article, tutorial (for this).

### Reference table

A reference table is a page of the site that the tool generates from the code or the files that define a thing: what exists in this build, each row with a link to its source line.

The tables: the kernel operations, the context of a program, the error kinds, the grants of the root service, the fixed ranges, the commands of the console and of the tool, the types, the licenses, the numbers, the modules and the module graph. Each one reads one form of its source file; when a file loses that form, the command stops with the file and the line. A row with an id is a symbol.

The design: `docs/SITE.md`, "The reference tables".

Do not use: API docs, listing.

### Module page

A module page is the reference page of the site for one module of the build: its documentation, its exports, its imports and, for a program, its grants and its budget.

The page `docs/reference/modules/<name>/` gives the documentation of the module (the comment before `package` in its source), its identity card, its source folder, its size in the boot image, its imports and the modules that import it, a figure of its neighbours in the module graph, and each export as a symbol with its signature as the console prints it (`write(name: Text, data: Text) -> Integer`). For a program it lists the grants and the budget that the root service gives it. The pages come from the same reader as the build: no module needs to be built.

The design: `docs/SITE.md`, "The module pages".

Do not use: API page, package page.

### Status page

The status page is the page of the site that gives the state of each property, with its evidence items and its gaps, then all the gaps and the next steps.

It writes no sentence of its own: each cell is a part of `docs/PROPERTIES.md` or of `docs/FIRST_MILESTONE.md`. An evidence item or a gap belongs to a property when its text names it. What is not done is on it as plainly as what is done. It is a section of the bar of its own, outside the docs.

The design: `docs/SITE.md`, "The status page".

Do not use: roadmap, progress page, "what runs today".

### Site address

The site address is the absolute address where a host serves the site, in the form `https://<host>/<path>`.

`SITE_ADDRESS` holds it (`https://modus.froment.software/`), and `kerneltool site --address` sets another for one run. Some parts of a page must be absolute to be right for the program that reads them, so they exist only with a site address: the canonical address, Open Graph, the page graph and the sitemap. With no site address the pages have relative links only, and work from a folder of a disk.

The design: `docs/SITE.md`, "What other sites read".

Do not use: base URL, domain (for this), root.

### Canonical address

The canonical address of a page is its one absolute address, which the page names in its head with `<link rel="canonical">`: the site address and the folder of the page, with a final slash.

A page can be reached at several addresses (with `index.html`, through a redirect page); the canonical address tells a search engine which one is the page. Example: `https://modus.froment.software/docs/reference/licenses/`. The command checks that each page has its own and that no two pages share one.

The design: `docs/SITE.md`, "What other sites read".

Do not use: permalink, URL (for this).

### Redirect page

A redirect page is a small file of the site at an old address of a page, which sends the reader straight to the address of today.

The addresses of the site changed twice, and the old ones were public: first `.html` files (`reference/licenses.html`), then folders before the move under the docs (`reference/licenses/`). A rule gives each old path from the path of today, and a redirect page is written at each one: a refresh with a delay of 0 and one visible link, with no script. It is not a page of the site: it is in no sitemap, no search index and no feed, and it never names another redirect page.

The design: `docs/SITE.md`, "The redirect pages".

Do not use: redirect, alias, forward (for this).

### Page graph

The page graph is the JSON-LD of one page: one `@graph` of schema.org nodes, built from the data that the page shows, whose nodes name each other by their `@id`.

It tells a search engine what the page is: the site with its search, the system as a `SoftwareApplication`, its source code, the page and its breadcrumbs, and what the page is about (a `TechArticle` for a guide, a `DefinedTermSet` for the glossary, a `Blog` for the news). No value is typed for the graph. It exists only with a site address, and the command parses each graph and checks that each `@id` that it names exists.

The design: `docs/SITE.md`, "The page graph".

Do not use: structured data (for this), schema, rich snippet.

### Sitemap

The sitemap is the file `sitemap.xml` of the site: the canonical address of each page, for a search engine.

It lists each page that the command writes, once, and no redirect page. A page has a `lastmod` only when the tool knows the date of its last change (the news and the releases): a wrong date teaches a search engine to ignore the field. `robots.txt` names it. Both exist only with a site address.

The design: `docs/SITE.md`, "The sitemap, robots.txt and the feeds".

Do not use: site index, page list.

### Site menu

The site menu is the menu of the bar of the site: one `details` element that holds the sections and the search field.

One list of links serves every width, so a screen reader reads each section once. Under 720 pixels it is a square button with three lines, and the open menu lies over the page. On a wide screen it is open and its button hidden, so it reads as the bar. On the docs home it holds the sections only. With no script, the button still opens it.

The design: `docs/SITE.md`, "The site menu".

Do not use: burger menu, hamburger, drawer.

### Documentation layout

The documentation layout is the layout of a page of the docs: the documentation tree at the left, the text in the middle, "On this page" at the right.

Each guide, reference page, module page, the glossary, the status page and the index pages use it. The home, the docs home, the news and the releases have the presentation layout: one centred column of at most 1152 pixels. The writer of each page states its layout; the tool does not guess it from a path. Under 1100 pixels "On this page" folds above the text; under 720 pixels the tree moves into the site menu.

The design: `docs/SITE.md`, "The two layouts".

Do not use: docs theme, sidebar layout.

### Documentation tree

The documentation tree is the list of the documentation pages of the docs, generated from the pages that exist, at the left of each documentation page.

Its first link is the docs home. Then come the guides in their reading order, the reference pages, the modules in their groups (Kernel, Programs, Modules) and the status. It is one `nav` on each page, in the site menu on a narrow screen. Tree lines show its levels.

The design: `docs/SITE.md`, "The two layouts".

Do not use: sidebar, navigation tree, table of contents (for this).

### On this page

"On this page" is the list of the headings and the symbols of one documentation page, each a link to its id.

It lists the headings of levels 2 and 3 and each symbol, in the order of the page: on a module page, each export. A heading of level 3 or a symbol is a branch of the heading of level 2 before it, with a tree line. From 1100 pixels it is a column at the right of the text with its own scroll; on a narrower screen it is a `details` above the text.

The design: `docs/SITE.md`, "The two layouts".

Do not use: table of contents (for this), outline, minitoc.

### Tree line

A tree line is a line of 1 pixel that joins an item of a navigation of the site to the item above it in the tree.

A vertical line runs down from under a parent, beside its branches, and a short horizontal line, the branch, goes from it to each item. The vertical line stops at the branch of the last item. The documentation tree and "On this page" have tree lines at each level under their first list; the lines that lead to the current item are in the color of the line under a link. A list of the text of a page has none.

The design: `docs/SITE.md`, "The tree lines".

Do not use: guide line, indent guide, connector.

### Symbol

A symbol is one documented thing of a reference page or a module page: a kernel operation, a command of the console or of the tool, an export of a module, or a row of a reference table with an id.

A symbol shows its name as a heading with an id (`operation-<name>`, `export-<name>`), its signature in a block of code, the text of its source comment as Markdown, its facts (the statuses of an operation, the parameters and error record of an export) and a link to its source line. "On this page" lists it. The first sentence of the comment of an export is also its help in the console.

It is not a symbol of an object file: a module exports by index, and a name is looked up only at build time. A declaration of the sources is in the declaration index, not a symbol.

The design: `docs/SITE.md`, "The reference tables".

Do not use: entry, item, API (for this).

### Value kind

A value kind is what a technical value is for a reader, such as a number, a size, a time, a handle, a status or a module, so that every place that shows the value can give it one look.

The kinds are one enumeration of the system, `value_kinds.Value_Kind` (`contract/value_kinds`): number, size, time, handle, value of the context, grant, status, type, operation, command, module, file, guide, version, yes or no, procedure, constant and global variable. One table gives each kind its color in each color scheme (`support/graphics/value_colors.odin`). The site adds a class `value-<name>`, a title and an icon to each kind; the system uses the same kinds in a log record, where each value run keeps the kind of its part of the text, so the log draws a size and a module name in their colors.

The writer of a table, a symbol or a line of the log states the kind of each value: no text is classified by its look. A value is in the monospace font; a name or an explanation in the reading font.

It is not a type of a language: `Size` and `Number` can both be an `int`. A value kind says what the value means to a reader.

The design: `docs/SITE.md`, "The kinds of values".

Do not use: value type, badge, chip, tag (for this).

### Declaration index

The declaration index is the list of every top-level declaration of the sources of the system, which `kerneltool site` reads with the parser of Odin so that a code span can link to what it names.

It reads each source file of `kernel`, `boot`, `contract`, `support`, `modules` and `programs` (not the tests and not the tool). For each procedure, type, constant and global variable it keeps its package, its file and line, its kind, its one line of Odin and the first sentence of its comment. A code span of a guide, a news entry, the glossary or a source comment whose whole text is a name (`blend_coverage_row`, `graphics.text_proportional`) then becomes a link with a declaration card. When several declarations share the name, the folder that the text around the span names chooses one.

It is not a symbol table of an object file, and its entries are not symbols: a symbol is a documented thing of a reference page.

The design: `docs/SITE.md`, "The declaration index".

Do not use: symbol table, symbol index (a symbol is a documented thing of a reference page), ctags.

### Declaration card

A declaration card is the short card of one declaration of the declaration index, which opens over a link that names it.

It shows the name, the kind and the package, the one line of Odin colored, the first sentence of the comment ("A procedure with no comment in its source." when there is none), and the file and line as a link. A page holds the card of each declaration that it links to once. The script opens it when the pointer rests 400 ms on the link or the focus reaches it; with no script the link works and no card opens.

The design: `docs/SITE.md`, "The declarations of the sources".

Do not use: tooltip, hover card (for this).

### Type card

A type card is what the site states of one type of the contract: its kind, its size, its alignment, its fields with their offsets and the padding, or its members with their values, where it is named, and its source line.

The size, the alignment, the offsets and the values come from the compiler that builds the tool (`type_info_of`), so they are the numbers of the build, not a reading of the text. The page of the types holds each whole card; a page that names a type holds a short card that its name opens. A reader of a record of a ring sees with it where each byte is.

The design: `docs/SITE.md`, "The types".

Do not use: tooltip, type info, hover card (for this).

### Identity card

An identity card is what the site states of one module: its name, its kind, its hash, its size, the counts of its exports, its imports and the modules that import it, its license, and the first sentence of its documentation.

It answers "what is this module?" in one box: the hash is its identity (64 hexadecimal digits), the counts place it in the module graph, and the license comes from the license rows of its source folder. The module page shows it after the documentation; the page of the module graph shows it for the node under the pointer or the focus.

The design: `docs/SITE.md`, "The identity card".

Do not use: tooltip, hover card, module info (for this).

### Document pointer

A document pointer is a part of a source comment that names a document of `docs/` and a place in it, for a reader of the code.

Examples: `(docs/ARCHITECTURE.md, "Kernel systems")`, `docs/FONTS.md, section 12.4`. A pointer is how a comment stays short: the comment gives the reason in a few words and points to the guide for the rest. `kerneltool site` checks every pointer of every source file: a label that finds no heading stops the command. On a page, the site writes a document reference in its place.

The design: `docs/SITE.md`, "The forms of a pointer".

Do not use: doc link, citation (for this).

### Comment breach

A comment breach is a comment of a source that names a property, a choice, a step, a review, a finding or a decision by its number, its label or its date, in place of the reason.

A number means nothing to a reader of the code, and it goes stale when the record changes. So a comment states the reason in plain words, or points to a heading of a guide. `kerneltool check` reads every comment of the sources and fails on each breach, with its file, its line and its form: "(property 14)", "(P20)", "choice 186", "D-047", "HANDOFF item 53".

The design: `docs/TOOLS.md`, "The comments of the sources".

Do not use: violation, lint error (for this).

### Document reference

A document reference is what a page of the site writes for a document pointer, or for a code span that names a document: a link with the title of the document and the text of the heading that the pointer names.

Example: the pointer `(docs/ARCHITECTURE.md, "Kernel systems")` becomes the link "Architecture: Kernel systems", in the color and with the icon of the value kind Guide. A comment shows its references on one line "See:" after its text, so no reference breaks a sentence. A reference to a working record links to the file in the repository, and says so. The command prints the count of references and those whose labels found no heading.

The design: `docs/SITE.md`, "The references to documents".

Do not use: tag, badge, cross-reference (for this).

### Wire form

A wire form is one of the types of the call form of the module contract, a member of `Type` of `contract/module`: Integer, Text, Record, Handle, Table or Bytes.

It says how a call carries a parameter or a result: in one register, and what that register holds or points to. An Integer is the value; a Text, a Record, a Table and Bytes are an address of memory of the caller with a header; a Handle is a handle number. Because each parameter has a wire form in the description of an export, one export serves a direct call, an isolated call and the console with no glue code.

The design: `docs/MODULE_CONTRACT.md`, "5. The types".

Do not use: marshalling type, ABI type.

### File version

A file version is the first 8 bytes of the BLAKE3 hash of a file of the site, in hexadecimal, added as `?v=<version>` to each link to that file.

A proxy in front of the site keeps a file for hours. The style sheet, the scripts and the search index change between builds, so each link names their bytes: `style.css?v=<16 hexadecimal digits>`. A new build gives a new address, and no proxy serves an old file with a new page. The same bytes give the same address. A page itself cannot carry a version; the line "This page is from an older build: reload" covers that case.

The design: `docs/SITE.md`, "The versions of the files".

Do not use: cache buster, fingerprint, hash suffix.

### Site workflow

The site workflow is the workflow of GitHub Actions `.github/workflows/site.yml`, which builds the site at each push to `master` and gives it to GitHub Pages.

It holds no logic: each step calls `kerneltool` or an action pinned by its version tag. It builds the boot image (`kerneltool build`) and the site (`kerneltool site`), then deploys `build/site`. A failed check of the site stops the run, and the site of the last run stays online. It runs no machine test: the numbers come from the measure record.

The design: `docs/SITE.md`, "How the site is published".

Do not use: pipeline, CI job, deploy script.

### Full check

A full check is `kerneltool screenshots` and `nix flake check`, both passed.

`kerneltool screenshots` runs the machine tests, the second build and the pictures on the host, and writes the measure record. `nix flake check` runs the host tests and `kerneltool check` in the sandbox of Nix; it sees only the folders that `flake.nix` names. A full check runs once at the end of a batch of features, before the release and the publication of the site; each merge before it needs only its build and the test of its own part.

The design: `docs/TOOLS.md`, "What each tool reads".

Do not use: CI run, test suite, full test.

### Incremental build

An incremental build is a build that keeps each output of an earlier build whose inputs are the same, and builds only the others.

It rests on the rule of the reproducible build: the same inputs give the same bytes, so the output of an earlier build with the same inputs is the output of this build. `kerneltool build` keeps a module when the build record of each of its two steps has the build key of its inputs as they are now and each output has its recorded hash; it runs the conversion alone when only the file of an import changed; it keeps each boot volume by the same rule, and builds only the boot volumes that the command boots. The tool builds in every case of doubt: no record, a damaged record, an input or an output that changed or is gone. It prints the count of the modules that it kept.

It is not a cache of the compiler and holds no second copy of an output: the kept output is the file of the build folder itself.

The design: `docs/TOOLS.md`, "The incremental build", and `docs/REPRODUCIBLE_BUILD.md`, "The incremental build and the same bytes".

Do not use: build cache, cached build, partial build.

### Build key

A build key is one BLAKE3 hash over the inputs of the build of one thing (one step of a module, or one boot volume), in a fixed order.

A module has two keys, one for each step of its build. The inputs of its compile step: each source file that the compiler lists, with the files of `#load`; every other file of the folder of each of these packages; its assembly files; the commands of the compiler and of `llc` with each flag; the programs of the build; and the sources of the tool. The inputs of its conversion: the key of the compile step, the linked file, the module file of each import with the order of the imports, and the sources of the tool. The inputs of a boot volume: the boot image and the kernel that its boot program holds, the debug image, the public key of the system, the sources of the boot program, the commands with each flag, and the tool. Two builds with the same key had the same inputs. A key is complete only when each input can be read; the tool never records and never compares a key that is not complete.

It is not the hash of a module, which names the output, and it is not a signing key.

The design: `docs/TOOLS.md`, "The incremental build".

Do not use: cache key, fingerprint, input hash (for the whole key).

### Build record

A build record is the small text file that the tool writes after it built one thing: its build key, the hash of each output, and the list of the files that the compiler read.

A module has one for each step of its build, `build/modules/<name>.compile.build_record` and `build/modules/<name>.convert.build_record`; a boot volume has `build/boot/<name>.build_record`. At the next build, the tool computes the build key again from the files of the recorded list as they are now, and keeps the outputs when the key is the same and each output has its recorded hash. A record that is absent or damaged is no record: the tool builds, with no error. The tool writes no record when it cannot prove that the hash and the compiler read the same bytes of each input.

It is not the measure record and not the line of the reproducible build that the site quotes.

The design: `docs/TOOLS.md`, "The incremental build".

Do not use: cache entry, stamp, manifest (for this).

### Compile step

The compile step is the first of the two steps of the build of a module: the compiler, `llc`, the assembler and the link, which give the linked file of the module.

It reads the sources of the module and no file of an import: a source declares an export of an import in a `foreign` block, and the link leaves that symbol not defined. So its build key holds no import, and a change inside an import does not run it. The tool runs it when a source, a command, a program of the build or the tool changed, or when the linked file is gone.

It is not the whole build of a module: the conversion follows it.

The design: `docs/TOOLS.md`, "The incremental build".

Do not use: compile phase, compiler stage, object step.

### Conversion

The conversion is the second of the two steps of the build of a module: the tool writes the module file from the linked file, with the description of the exports and the hash of the file of each import, then the debug object.

It is the one step that reads the file of an import, and it runs no compiler. When the file of an import changed and the sources of the importer did not, the tool runs the conversion alone: the module is converted, not built. A converted module has a new hash, so each module that imports it is converted too. Example: a change of the body of an export of a library builds the library and converts each of its importers.

It is not a link: no code of the import enters the module.

The design: `docs/TOOLS.md`, "The incremental build", and `docs/MODULE_CONTRACT.md`, "The steps of one module, as implemented".

Do not use: relink, repackage, packaging step.

### Whole build

A whole build is a build that ignores every build record: it builds each module and each boot volume, and writes new records.

`kerneltool build whole` asks for one. The commands that prove the build are always whole builds: `check`, `screenshots` and `repeat` compare the results of two runs of the compiler, and a kept output would be compared with itself. `nix flake check` builds in an empty folder, so its build has no record to read.

The design: `docs/TOOLS.md`, "The incremental build".

Do not use: clean build, fresh build, full build.

### Measure record

The measure record is the file `docs/measures/measures.txt`: the measured numbers of the last full check, each as the whole line of its log, with the facts of its run.

The site workflow runs no machine test, so the pass that commits the pictures also commits the numbers. `kerneltool screenshots` writes the record: one line `key value` for each fact (its time, its release, its commit, the state of its tree, its host, the count of checks that passed), then each number with its log, its line and its machine, and the stages of the start. The site reads it when the logs of `build/` are not newer. A number of speed is a measure: it is printed and recorded, and never makes a test fail.

The design: `docs/SITE.md`, "The measure record".

Do not use: benchmark results, metrics file, numbers cache.

### Measure run

A measure run is a machine whose boot image holds the resource `measure_run`, in which each program measures its rates over a duration.

A rate (records in one second, reads in one second) needs a duration. In a test, a program runs its checks only: each one ends after a count of work, and the program writes no rate. In a measure run, the root service writes 1 in the value 22 of the context of each program that it starts (`CONTEXT_VALUE_MEASURE_RUN`); a program reads it with `system.measure_run()`, runs the same work for a fixed duration, and writes its rates. The modules of a measure run are the modules of the test, byte for byte: only the boot image has one resource more. `kerneltool measure` starts a measure run; `kerneltool test` never does.

It is not the measure build, which is a build of the kernel with no check. A measure run can use the test build or the measure build. Example: `kerneltool measure clock` prints "clock: the time page: N reads in one second, 0 kernel entries for one million reads".

The design: `docs/TOOLS.md`, "A check by count, a measure by time".

Do not use: benchmark mode, benchmark run, performance mode.

### Settled screen

A settled screen is a screen that shows the last picture of each window: each program sent the picture of its last change, and the compositor drew each picture that it received.

The machine test takes a picture only of a settled screen. When it can call the compositor, it reads the state of the programs from `monitor.programs()` before and after it reads `compositor.windows()` and `compositor.screen()`: a program that is in a wait in the two reads, with the same count of kernel entries, did not run between them, and a window with no picture that waits for a frame is on the screen as its program sent it. When it cannot call, it takes pictures until two in a row are the same. A window that draws with no end has no last picture, and the condition leaves it out.

It is not a fixed time before a picture: the hang bound ends a wait for a screen that never settles, as a failure that names the window.

The design: `docs/TOOLS.md`, "When the tool takes a picture".

Do not use: idle screen, stable frame, quiescent.

### Hang bound

The hang bound is the one time in a test: it ends a test that waits for ever, and checks nothing about speed.

A test checks a condition: a value, a state, a line of the log. A time in it has one role, to end a hang, so it is generous and the same for each wait that has no reason of its own: `HANG_BOUND`, 120 s, for a step of a machine test, and `system.TEST_HANG_BOUND_MILLISECONDS`, 60 s, for the checks of a program, so that the program reports its own hang before the tool ends the machine. A bound of its own needs a named constant with its reason, and `kerneltool check` refuses a number in the field `seconds` of a step.

It is not a timeout that a test asserts: no test fails because the host is slow. A duration is printed as a measure.

The design: `docs/TOOLS.md`, "The bounds of the tests".

Do not use: timeout (for a test), deadline (for a test), time limit.

### Stall

A stall is a case that writes a count of its progress and whose count did not grow for the hang bound.

A long case (the fault ring under load, for example) can take any time on a slow host and still be right. So the test bounds a stall, not the whole run: it ends the case when the count stays still for `system.TEST_HANG_BOUND_MILLISECONDS`, or after 600 s in all. The report names the step where the count stopped, which tells a lost wake from a slow host.

The design: `docs/TOOLS.md`, "The bounds of the tests".

Do not use: freeze, no progress timeout, watchdog.

### Tagline

The tagline is the one line under the name in the head of the home of the site: the first sentence of the first paragraph of `README.md`.

The rest of that paragraph is a section "What it is" lower on the home, after the news, so the first screen of a phone holds the mark, the name, the tagline and the links. The description of the home in its head and in the page graph stays the whole paragraph, cut at 160 bytes. Like every description of the project, it says what the system does for its user, and names no technical part.

The design: `docs/SITE.md`, "The pages".

Do not use: slogan, subtitle, hero text.

## Terms that the system does not have

These words name concepts that the system removed. Use them only to describe other systems.

file, path, directory, pipe, socket (as an object), signal, fork, environment variable, `argv`, standard input and output, user, group, root, installer, driver (in the kernel), system call table, TTY, shell script, save.
