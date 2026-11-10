# Module contract

Status: draft 1, 2026-11-09. The owner closed its decisions on 2026-11-09. `contract/module/format.odin` is version 1 of the format at the level of bytes; `FIRST_MILESTONE.md` lists the gaps.

This document proposes the contract between modules: the module format, the loader, the call form, the type description, and the context.
`GLOSSARY.md` defines the terms. `PROPERTIES.md` gives the rules; (P10) points to a property.

The facts come from two research notes, with sources:

- `research/module_loading_prior_art.md` (cited as [Load §n])
- `research/interface_types_prior_art.md` (cited as [Types §n])

## Requirements

These come from decisions of the owner.

1. One format of code. A library and an executable are the same module (P10).
2. Static linking and dynamic linking are one mechanism (P10).
3. A module is identified by the hash of its content, and imports other modules by hash (P11).
4. The loader reads flat tables. They are the only format of the metadata; functions give the information of the modules from them (P12, changed on 2026-11-10: no SQLite).
5. An all-zero record is valid (P13, ZII).
6. No contract depends on a feature of one language (P19).
7. A command is an export. The module metadata is sufficient to call it (P19).
8. A program receives one context and no `argv` (P19).
9. The same description serves a direct call and an isolated call through a ring (P19).
10. Test: a C program with no library calls a module written in Odin, and the reverse.
11. 64 bits only (owner, 2026-11-10): an address is 8 bytes on every machine. The targets are x86-64 and ARM64. No table, record or call form has a 32-bit variant.

## 1. The module file

A module is one file:

```
+--------------------+
| header             |  fixed size
+--------------------+
| table directory    |  one entry per table: offset, count, record size
+--------------------+
| flat tables        |  segments, imports, exports, slots, rebases,
|                    |  types, fields, functions, parameters, strings
+--------------------+
| segment data       |  code, read-only data, data
+--------------------+
```

- **Header**: magic number, format version, a set of "the loader must understand this" feature bits, target machine.
- **Feature bits**: A loader that does not know a set bit refuses the module with a clear error. ELF has no such field, and old loaders crash on new files. [Load §1]
- **Table directory**: Each entry gives the record size of its table. A table can gain fields at the end of its record. A reader that knows a shorter record ignores the rest. A reader that knows a longer record reads the missing fields as zero. [Types §4, §5]
- **Index 0** of each table is the empty entry (ZII).
- **Hash**: The identity of a module is the hash of the whole file. The file contains no reference to its own hash. Imports are hashes, so an import cycle cannot exist in the files. [Load §4] A replacement can make one (section "Replacement of an import"): the loader refuses it.

### Loader tables

| Table | One record describes |
|---|---|
| Segments | A range of the file, its size in memory, and its protection: execute, read, or read and write |
| Imports | One imported module: its hash |
| Slots | One import slot: the import index and the export index in that module |
| Exports | One exported function: the offset of its code and the index of its function description |
| Rebases | The locations in data that hold an address inside the module |

### Description tables

| Table | One record describes |
|---|---|
| Types | One type: kind, size, alignment, range of fields |
| Records | One record that an export receives or gives: name, size, range of fields (implemented on 2026-11-10) |
| Fields | One field of a record: name, offset, type, and the rights of a handle (implemented on 2026-11-10) |
| Functions | One export: name, argument record type, result record type, help text, flags |
| Parameters | Console data for one field of an argument record: required, allowed values, completion source, accepts piped input |
| Strings | The bytes of all names and help texts |
| Documentation | Record 1: the documentation of the module, one line and a text (implemented on 2026-11-10) |

The documentation is part of the file, so it has the hash of the module: a text cannot describe another version of the code. A record of the Functions table also names the documentation text of its export. A documentation text is UTF-8 bytes. A line feed ends a line. A line is a paragraph: the reader breaks it at the width that it has. A line that starts with a space stays as it is. An empty line separates two paragraphs. No loader reads these records.

The model is the BTF format of Linux, changed so that all records have a fixed size. [Types §5]

## 2. Loading

The loader does five steps:

1. Map each segment at a random base address.
2. Get each imported module from the module store by hash. Load it if it is not mapped.
3. Rebase: add the base address to each location of the rebase table.
4. Bind: for each slot, write the address of the export `(import, export index)`.
5. Make the slot region read-only. Call the entry export.

Status of the loader in user space (`support/system/load.odin`), implemented on 2026-11-10:

- **The load source**: the loader finds a module only in its load source: the files that the program was granted, each named by its hash, and the replacements that the starter of the program gives. The loader checks the hash and the tables of each file before it uses it. It has no search path and no ambient store (P20). The root service and the console give the boot image. A call host receives a list of files from the console, on one page in the form of the boot image: the module, its imports, and the modules of the replacements.
- **The module space**: the modules that a loader put in one program. Each module is in it one time: two modules that import a third one call the same copy. A module that another module of the space uses stays when the caller unloads it; a module with no use leaves, and its imports lose one use.
- **Refusals**: a missing import, an import cycle, a bad file, a replacement that fails its check, a slot that cannot be bound, no room, a kernel operation that fails. On a failure, the space is as it was before the load, and the caller has a load error (below).
- **Shared code** (choice 136 of `FIRST_MILESTONE.md`): the pages that do not change after the load hold the bound slots, so a prepared module is for one base and one binding of its slots. The table of prepared modules keys it by the hash of the module, its base, and the hash and the base of the module of each import. A writable segment that holds a slot is bound in the copy of each program.
- **Addresses**: the module of a program is at `PROGRAM_BASE`, and its imports follow it, with one page with no memory between two modules. The addresses are fixed (choice 5 of `FIRST_MILESTONE.md`): step 1 of this section, the random base, is not done.
- **Module records**: after it mapped a module, the loader writes its module record in the kernel (operation `Program_Module`): its addresses, its hash, and the hash that a replacement put it in place of. The kernel does not read the module: the record is what the loader asserts. It names the module of the address of a fault with it, and `Inspect` gives the records of a program.

### The error of a load

Status: asked by the owner on 2026-11-10 ("errors that are robust, descriptive and informative"), implemented the same day. The owner has not reviewed the choices below.

No exception and no global error state: an error is a value that the call gives back. A load that fails gives `false`, and fills a record that the caller owns: `module.Load_Error` (`contract/module/error.odin`). Zero is "no error". The record is data, not text, in the contract library: a program in another language reads it, and a call host gives it to its caller in the call region.

| Field | What it holds |
|---|---|
| `stage` | The stage that failed: Find (no file of the load source has the hash), Read (the file does not have its hash, or its tables are not valid), Cycle, Check (a replacement), Bind (a slot), Map (a kernel operation), Room, Unmap (the removal of a module) |
| `status`, `file_error` | Map and Unmap: the status of the kernel. Read: what is not valid in the file (`module.Error`), or None when the hash differs |
| `module` | The hash and the name of the module that was being loaded: the importer, when the stage concerns one of its imports |
| `imported` | The hash and the name of the import concerned, as the file of `module` names it |
| `replaced`, `replacement` | A replacement on the path of the load: where a module imported `replaced`, the loader gave `replacement`. It says who decided: the party that gave the replacements, for the console the replacement table of the machine |
| `export`, `slot` | Check and Bind: the name of the export, in the module that the import names, and the number of the slot |
| `difference`, `parameter`, `expected`, `found` | Check: what differs (no export with the name, the count of parameters, the type or the detail of parameter n, the type or the detail of the result), and the two sides: a type, its detail (the rights of a Handle, or a count) and the name of a Record |

A name is 32 bytes, from the load source: the loader reads it in the entries of the boot image. A hash that the load source does not name has no name; the text then shows the hash.

- **Text for a person**: `system.load_error_text` writes the record as lines, with no other data. The console prints each line after "error: ", for example "error: agenda imports calendar, and its replacement calendar_changed fails the check" and "error: export days_in_month of calendar_changed: 3 parameters, calendar has 2". The root service writes the lines on the log when a start fails.
- **A call host**: its first completion has the tag 0: Ok when it loaded its module, or `Load_Failed` with the record at the start of the call region. The console waits for it in `isolate`, copies the record, and reads it as values: a value out of an enumeration is shown as unknown, and a name is read up to its 32 bytes.
- **Unload**: `module_space_release` gives `false` and the stage Unmap when the kernel refuses to remove a module.
- **A fault in a module**: the kernel keeps a stop report for each program (`op.Stop_Report`): the stop code, the instruction, the address, and the module record of the module of the instruction, that is the module that ran (B2, not B). The holder of the program handle reads it with `Program_State`. The console prints "error: the instruction is at offset ... of calendar_fixed ..." and "error: calendar_fixed ... runs in place of calendar ...". The log of the kernel has the same facts.
- **What the record does not explain**: the first failure only: a load stops at the first stage that fails. It does not say which part of a Record differs (only that the two records differ, and their names). It does not say why a file is in the load source or not. A replacement nearer to the failure hides one farther on the path: the record holds one replacement. A fault report does not give the stack of calls, so a fault in B2 that a call from A caused names B2 only. The record of a call host comes from another program: the console checks its values, and cannot prove them.

What this design removes, compared with ELF:

| ELF mechanism | Here | Why |
|---|---|---|
| Search of a symbol by name in all libraries | An export index in a module named by hash | The hash fixes the content, so a stored index is always correct. No hash table, no string compare. [Load §1, §2] |
| Library search paths | A hash | Guix measured 67% failed system calls at program start from path search. [Load §4] |
| Symbol interposition | Not possible | It costs up to 30% in ELF, because the compiler cannot optimize across functions. [Load §1] |
| Lazy binding, PLT | Eager binding | With an index, binding is one table walk. Errors appear at load, not at the first call. [Load §1] |
| Text relocations | Forbidden | The loader writes data only. Code pages stay shared and never writable. [Load §5] |
| Stored addresses (prelink, bound imports) | Never | Every such design failed against address randomization or signing. [Load §2, §3, §4] |

- **Two kinds of fixup only**: rebase and bind. Mach-O shows that this is sufficient. [Load §3]
- **Rebase encoding**: the RELR form, one bitmap per run of words. It uses under 3% of the classic size and its decoder is about 12 lines. [Load §1]
- **Fewer rebases at the source**: Tables of offsets in place of tables of addresses. A module with no rebase is fully shared between programs. [Load §5]
- **Size**: The self-relocation stage of musl is 164 lines; its full dynamic linker is 2455 lines. [Load §1] The target for this loader is a few hundred lines.
- **Shared code, as implemented** (paging, second part): a program that starts programs keeps a table of prepared modules (`system.Prepared_Modules`), by the hash of the module file. A prepared module is one memory object with the segments that do not change after the load (code, constants, and the data that is read-only after the rebase), copied from the file and rebased at the program base. Each program of the module maps these pages with the protection of their segment, and receives a new memory object for each writable segment: the bytes of the file, rebased for that segment only (`module.rebase_range`). The table keeps the handle without the right Write, so no program writes the prepared module, and a write of a program to its code is a page fault. The kernel learns nothing of the module format: it maps a memory object with the rights of a handle. The code is the same in all the programs because each program has its module at the fixed address `PROGRAM_BASE` (choice 5 of `FIRST_MILESTONE.md`). With a random base for each program, the data that is read-only after the rebase differs between programs, and only the code and the constants stay shared.

## 3. Static is dynamic

- **One call sequence**: A call to another module is always an indirect call through a slot: `call *slot(%rip)`. This is the sequence of `-fno-plt` in ELF and of the import table in PE. [Load §2, §5]
- **Merge**: A build tool can merge a module and some of its imports into one new module. It rewrites each call through a slot into a direct call, and removes the slot. Linkers already do this rewrite (`GOTPCRELX` relaxation). [Load §5]
- **Result**: The compiler output is the same in both cases. "Static" is "merged before load". "Dynamic" is "bound at load". The choice is made after compilation, per import.
- **Provenance**: A merged module keeps a table of the hashes of the modules that it contains. [Blow §3] The system can still answer "which programs contain this module".
- **Cost**: A merged module has a new hash. Two programs that merge the same module do not share its pages.

## 4. The call form

Status: Chosen on 2026-11-09. The owner prefers registers, doubts that the C convention is the right one to reuse, and delegated the choice.

### The choice

A call between modules passes values in registers. It uses the register assignment of the machine's main convention, limited to a small subset.
On x86-64 this is the System V AMD64 assignment:

| Item | Rule |
|---|---|
| Parameters | Scalars only: an integer of 64 bits or less, a `f32` or `f64`, an address, a handle |
| Integer parameters | Up to 6, in `rdi`, `rsi`, `rdx`, `rcx`, `r8`, `r9`, in order |
| Float parameters | Up to 8, in `xmm0` to `xmm7`, in order |
| Results | Up to 2 integers in `rax`, `rdx`, and up to 2 floats in `xmm0`, `xmm1` |
| A record, a slice, a string, a variant | Passed as the address of memory that the caller owns. Never by value |
| More parameters than registers | Not permitted. Use a record |
| Variable parameter lists | Not permitted |
| Errors | A function that can fail declares a status result: an enumeration, 0 is success |

### Why this subset and not the whole C convention

The C conventions have real defects. The subset avoids each one:

| Defect of the C conventions | Subset |
|---|---|
| The rules for a record passed by value are complex, differ between System V and Windows, and differ between compilers in edge cases [Types §7] | No record by value |
| Variable parameter lists need special rules | Not permitted |
| Types with a size that depends on the system (`long`, bare `enum`, `long double`) | Only the base types of section 5 |
| Parameters on the stack have alignment and order rules | No parameter on the stack |
| Windows x64 has 4 register parameters and a reserved stack area | Not used. One assignment per machine architecture |

- **Why not a new convention**: A new convention needs a change in each compiler. Every language can already produce this subset: `proc "c"` in Odin, `extern "C"` in C, Rust and Zig. This satisfies the rule that no contract depends on one language (P19).
- **Why registers and not two records**: Speed. A call between modules costs the same as a normal function call. The owner sets performance as a criterion at every level.

### One description, two paths

The description of a function is its list of parameters and results, each with a base type or a reference to a described record.

- **Direct call**: the values go in registers, as above.
- **Isolated call**: the argument record is derived by rule: one field per parameter, in order. The results travel in a completion record. The derivation is mechanical; nobody writes a second encoding.
- **One generic entry routine**: Because every parameter is a scalar, one small routine loads up to 6 integer registers and 8 float registers from two arrays and calls the export. The receiving side of a ring and the console both use it. A library for foreign calls is not needed. It is `export_call` in `support/system/enter.asm`: 30 instructions.

### The isolated call, as implemented

Status: implemented on 2026-11-10 (`contract/isolated/`, `programs/host`). The owner has not reviewed the choices below.

- **Call host**: The caller starts one program per module: the call host. The call host receives two memory objects: the call ring and the call region. Like each program, it also has its budget and, if the caller gives it, the log. It receives no other handle. The caller maps the file of the module in the call host, read-only, with no handle. The call host checks the file and loads the module.
- **Argument record**: One field per parameter, in order. A scalar is 8 bytes. A parameter that the direct call passes by address is the record itself: a Text is a slice of 16 bytes, `{offset, count}`. The offset is in the call region.
- **Where it travels**: The argument record is in the call region. The command record names it: `kind` is the export index, `values[0]` is the offset of the argument record, `values[1]` is its size. Reason: 6 integers and 8 floats are 112 bytes, and a record of a ring has 56 bytes of values. One place for all argument records needs no second path.
- **Completion record**: `kind` is a status: 0 is success, 1 is "no such export", 2 is "the argument record is not in the call region". `values[0]` and `values[1]` are the integer results; `values[2]` and `values[3]` are the float results.
- **The receiver checks**: The call host reads the types from the description in the module, not from the caller. It copies the argument record to private memory once. It checks the offset and the count of each slice against the size of the call region, with no overflow. Then it calls `export_call`.
- **The caller checks**: The caller reads a bounded number of completion records, and ignores each record whose tag is not the tag of the call.
- **Failure**: A fault in the module stops the call host only. The kernel wakes the caller, which holds the handle of the program. The caller reads the stop code. A call has no time limit. The caller ends a call when it closes the handle: the kernel stops a program that no handle names. The console does this when the person presses Escape. The next call starts a new call host.
- **Tests**: `odin test isolated` has a round trip, the refused cases at each limit, and 200 000 random argument records. The machine test calls a module that reads address 0, that loops with no end, and that tries to stop the machine.

### Records and handles, as implemented

Status: implemented on 2026-11-10 (step 24). The owner has not reviewed the choices below.

| Type | Direct call: the register has | Isolated call: the field of the argument record has |
|---|---|---|
| Integer | The value | 8 bytes: the value |
| Text | The address of a slice record | 16 bytes: `{offset, count}` in the call region |
| Record | The address of the record | 8 bytes: the offset of the bytes of the record in the call region |
| Handle | The handle of the caller | 8 bytes: the handle, as the receiver names it |
| Record result | One more argument: the address of the memory of the result | One more field: the offset of the place of the result |

- **Record description**: The tables Records and Fields. A record has a name, a size (256 bytes at most) and fields. A field has a name, an offset and a type: Integer (8 bytes) or Handle (4 bytes). A record holds values only. The loader code checks each description before a use: each field is inside the record.
- **A record is copied one time**: The receiver copies the bytes of the record from the call region to private memory, then gives the address of the copy to the export. The caller cannot change the record while the export reads it.
- **A handle is lent**: The description has the rights that the export needs. The caller gives a copy of its handle to the receiver, with these rights only, through the call ring: the kernel operation `Handle_Give`, with the memory object of the call ring as the target. The receiver closes the copy when the export returns. The caller keeps its handle.
- **The receiver proves each handle**: The number of the handle is in memory that the caller writes. The receiver asks the kernel if this handle came through the call ring (`Handle_State`), and if it has each right of the description. If not, the status of the call is 3, "bad handle", and the export does not run. Without this proof a caller names a handle that the receiver holds for itself.
- **The caller takes back what it lent** (step 25): the caller gives a handle that comes from a copy of its own handle, and revokes the copy after the call (`system.lend`, `system.lend_end`, the kernel operation `Handle_Revoke`). The handle of the receiver ends, and each mapping that the export made with it. An export that keeps a mapping for a later call stops its program on a page fault at the first use. If the caller cannot give each handle, it revokes those that it gave and sends no record.
- **Limits**: 16 handles for one call. A result record has no handle. An export with a Record result has 5 parameters at most.
- **In Odin**: `^Name` is a Record, `result: ^Name` as the last parameter is a Record result, and `system.Lent({.Read, .Write})` is a Handle. The tool reads them in the source (`kerneltool`, `describe.odin`). A module in another language writes the same tables.
- **Tests**: `odin test` of `contract/isolated` has a round trip with a record, a handle and a record result, and the refused cases. The machine test calls `modules/sample` in a call host and in the console.

### Growth

- A module imports another module by hash, with an export index. The caller and the callee are always the exact versions that were built together. A direct call cannot meet a changed signature.
- Growth by added fields (ZII) applies where two sides have separate versions: the records of rings between programs and services, and the records that a function receives by address.
- The signature of an export does not change inside one module hash. A new signature is a new module.

### Replacement of an import

Status: asked by the owner on 2026-11-10. Implemented on 2026-11-10. The owner has not reviewed the choices below.

A module names each import by its hash. The party that starts a program can give the loader a replacement table: records `{hash of B, hash of B2}`. When module A imports B, the loader loads B2 in its place. The file of A does not change, so its hash does not change.

- **Use**: B has a security fault. B2 has the correction. Each program that imports B receives B2, with no new build of the program.
- **Who decides**: the party that starts the program, with a grant. The root service holds the table of the machine. A program cannot refuse a replacement and cannot ask for one: the table is not ambient (P20).
- **The loader checks, it does not trust**: for each slot of A in B, the loader finds in B2 the export with the same name. The description of that export must be equal in B and in B2: the same parameters, the same result, the same records and the same rights of each handle. If one differs, the load fails. A replacement cannot change a signature.
- **Bind by name, one time**: the slot of A holds an export index of B. The loader translates it to the index in B2 at load. The call stays one indirect call through a slot.
- **What the check cannot prove**: that B2 behaves as B. The party that writes the table asserts it. Later, a signature of the table by a principal carries this assertion (P9).
- **Visible**: the identity of a program that runs is the hash of its module and the replacements that the loader applied. `programs()` and the manual show them. A report of a fault names B2, not B.
- **Cost**: "the exact versions that were built together" is then true only for a program with no replacement. This is the purpose: the owner of the machine, not the author of A, has the last word on the code that runs.

#### As implemented

- **The table**: one page that the root service writes (`system.Replacement_Table`, 32 records of 64 bytes, `module.Replacement`). A count of versions lets a reader copy the records while the root service writes. The root service gives the records to the loader of each program that it starts. The console and the manual receive the page with the right Read (`GRANT_REPLACEMENTS`): the console reads it before each `load` and each `isolate`, and gives the records to a call host with its files.
- **Who changes it**: a program with the role Replace (the console) asks the root service with `Root_Command.Replace`: the name of B, and the number of the entry of B2 in the boot image (two names of 32 bytes do not fit in the 56 bytes of values of a ring record). The console has `replace("calendar", "calendar_fixed")`, `replace("calendar", "")` to remove it, and `replacements()` to list the table.
- **One step**: the loader applies one record to one import. The root service refuses a chain: a module that replaces is not replaced, and a replaced module does not replace.
- **The check** (`module.bind`, `module.functions_compare`): for each slot whose import was replaced, the loader reads the name of the export in the file of B, finds the export with that name in B2, and compares the two descriptions: the count and the type of each parameter, the rights of each Handle, the description of each Record (`module.records_equal`), the result. The names of the parameters and the help are for a person: they can differ. The loader checks only the exports that a slot of A uses. A missing name or another description refuses the load: the load error has the export, the two modules and the first difference (section "The error of a load"). The slot receives the address of the export of B2: the call is the same indirect call.
- **The replacement is in place of an import only**: `load("calendar")` loads calendar. The table applies to each import of a load, at each level.
- **A table that changes applies to the loads that follow.** A program that runs keeps the modules that it has. The root service does not start a program again.
- **Visible**: the module records of the kernel (operation `Program_Module`). `programs()` in the console shows the modules of each program that has more than its module, with "in place of" for each replacement. The manual shows the imports of a module, and the replacement of the machine for each one. When a thread faults, the kernel writes the hash of the module of the instruction, its offset, and the hash that the module replaces: "in module 5d8ff6e736fda684 at offset 00000000000019c0, which replaces b1f1b875df9992f8".
- **What differs from the plan**: the plan did not say where the identity is kept. The kernel keeps it, as it keeps the name of a program: the fault report and `Inspect` are in the kernel, and the loader of a program is in the program that started it, or in the program itself. A cycle of imports is possible with a replacement, and the loader refuses it.
- **Measured** (program `imports`, QEMU with KVM, in the machine test, the least of 5 runs): a call through an import slot, 1 000 000 calls: 3.5 ns to calendar, 2.7 ns to calendar_fixed in its place (the two are the same instruction; the bodies of the two exports differ). The bind of agenda: 372 ns with a direct import, 891 ns with the check of the replacement (one slot). The load of agenda and its import: 117 us and 154 us, with the hash of each file. Over five runs, the bind took 216 to 377 ns and 857 to 904 ns.

### Memory

The caller owns all memory. The callee never allocates in the caller (P14). For a result of unknown size, the caller gives a buffer with a capacity and receives a count, or receives a handle and reads later.

Implemented for the Text result (2026-11-10): after the parameters, the caller gives the address of a buffer record `{address, capacity}`. The callee writes the bytes that fit. Its integer result is the count of bytes of the full text; a count larger than the capacity means that the text did not fit. In an isolated call, the buffer is the part of the call region after the arguments: the callee writes where the caller reads. The caller reads `min(count, capacity)` bytes: it does not trust the count. The WebAssembly component model lets the callee allocate, and reports this as a main defect. [Types §1]

### Cost

- A function with a large set of inputs passes the address of a record. This is one memory access more than registers.
- The registers that a callee can change are those of the System V convention. All `xmm` registers are in that set, so a caller that keeps float values across a call must save them.
- A second machine architecture needs its own table. For ARM64 it is the same subset on the AAPCS64 assignment.

## 5. The types

### Base types

| Type | Size | Zero means |
|---|---|---|
| `u8` `u16` `u32` `u64` | 1, 2, 4, 8 bytes | 0 |
| `i8` `i16` `i32` `i64` | 1, 2, 4, 8 bytes | 0 |
| `f32` `f64` | 4, 8 bytes | 0.0 |
| `bool` | 1 byte, value 0 or 1 | false |

Excluded: types whose size depends on the machine or the compiler (`long`, `size_t`, `enum` with no width), bit-fields, characters as a type. [Types §7]

### Built types

| Type | Layout | Zero means |
|---|---|---|
| Record | Fields in declared order, natural alignment, little-endian, padding is zero | Each field is zero |
| Enumeration | An integer of declared width | Value 0 is "none" or "default" |
| Flags | An integer of declared width, one bit per flag | No flag |
| Slice | `{u64 address or offset, u64 count}` | Empty |
| String | A slice of UTF-8 bytes. No terminator | Empty |
| Handle | `{u32 index, u32 generation}`, with the object type and the rights in the description | No object |
| Variant | `{u32 tag, payload of the size of the largest case}` | Tag 0 is "none" |
| Optional | No added tag when zero can mean "absent" (handle, slice, enumeration). Otherwise a `present` byte | Absent |

- This layout is identical in C, in an Odin `struct`, in a Rust `repr(C)` struct and in a Zig `extern struct`. [Types §7]
- **Handles in the description**: A function declares the object type and the rights of each handle that it needs. The console can ask for the grants before the call (P2, P20). Fuchsia FIDL does this. [Types §3]
- **References across a ring**: In a direct call, a slice holds an address. In an isolated call, the same field holds an offset in a shared region. The description marks these fields. The receiver checks the bounds.
- **Streams**: A stream is not a type. It is a handle to a ring that carries batches of records. WASI 0.3 put streams in the type system, and this brought a scheduler into the contract. [Types §1]

## 6. The context

A program starts with one call: `entry(context)`.
The context is one record in memory that the loader prepared:

| Part | Content |
|---|---|
| Header | Size of the context, format version |
| Handle table | One entry per granted handle: the handle, its role (a number), and one argument |
| Kernel ring | The ring for kernel operations |
| Caller ring | The ring to the program that started this one |
| Arguments | The argument record of the called export, with its type index |

Now (`contract/operation/operation.odin`): the context is 16 handles and 16 values of 64 bits. The index of a handle is its role. It has no header and no text. The kernel ring is at a fixed address. For a call host, the caller ring is the call ring (role 0), and the argument records arrive in the call region (role 1).

- It holds no strings that the program must parse, no environment, no names.
- A program reads it with no memory allocator and no library.
- **Prior art**: The `processargs` message of Fuchsia has a fixed header, offsets, and one typed entry per handle. It still carries `argv` and environment strings; this design does not. [Load §6]
- A program that starts with an all-zero context has no handles. It can compute and stop. It can reach nothing (P2).

## 7. How to build modules with existing tools

Proposal: do not write a compiler or a linker.

1. Odin and clang produce normal ELF object files, position-independent.
2. The existing linker (`lld`) links one module into one ELF file.
3. A tool of the project converts that ELF file into a module: it writes the flat tables, converts relocations to rebases and slots, and computes the hash.
4. The description tables come from the source: from the Odin source for Odin (implemented: `tools/kerneltool/describe.odin` reads the syntax tree), from a small description file for C.

This reuses the compiler, the linker and the debugger formats. The project writes one converter and one loader.

- **ELF is a build-time intermediate format only.** LLVM, which Odin and clang use, writes only ELF, COFF and Mach-O objects. ELF never reaches the running system.
- **Every step is a command of the kernel tool.** No script calls the compiler or the linker directly.

### The linker

Status: Decided by the owner on 2026-11-09, after the study in `research/rad_linker_rdi_study.md`.

- The project does not write a linker. It uses `lld` on the ELF target.
- The converter of the kernel tool takes the linked ELF file as input and writes the module.
- **RAD Linker**: not adapted. It reads COFF and writes x64 PE only. Its output stage is not separate from its core. A COFF target also brings the Windows x64 convention, which conflicts with section 4.
- **Later**: the merge tool of section 3 can replace `lld`. `mold` and `wild` are faster ELF linkers to compare if link time becomes a problem.

## Decisions of the owner

Closed on 2026-11-09:

1. **Call form**: registers, scalar-only subset (section 4).
2. **Stream**: a handle to a ring that carries batches of records. It is not a type (section 5).
3. **Hash function**: BLAKE3. Its licence must be verified.
4. **Exports are functions only.** A module does not export data. Data is reached through a function.
5. **Debug information**: a separate object that the module names by hash. The format is DWARF, as the compiler writes it on an ELF target. RDI is not required (owner, 2026-11-09). RDI stays a candidate for later; see `research/rad_linker_rdi_study.md`.
6. **Linker**: `lld`. The study of the RAD Linker is done: the project does not adapt it. It writes x64 PE only, and its output stage is not separate from its core.
7. **Build-time intermediate format**: ELF, chosen by the owner on 2026-11-09. It matches the System V register assignment of the call form (section 4). It never reaches the running system. The boot program is the one exception: UEFI requires a PE file, so `boot/` stays on the COFF target.
8. **Kernel entry**: the kernel ring only.

## Rules closed on 2026-11-09

The owner closed the open questions of draft 1:

1. **No intermediate form of code.** A module holds machine code only. Merge rewrites a call through a slot into a direct call, and no more. To inline across two bodies of code, compile their sources into one module. The contract depends on no compiler.
2. **Exports are functions only.**
3. **Module state: private data, no hidden start code.** A module can have global data. Each program gets its own copy, taken from the file. No code runs before the entry: the format has no constructors and no static initializers. A module that needs setup exports a function for it, and the caller calls it.
4. **Debug information**: DWARF, in a separate object named by hash.
5. **Nested data across a ring: one level only.** A record that goes through a ring can hold slices of flat records. A flat record holds no slice. The receiver checks all offsets in one pass with no recursion. Deeper data goes through a handle to a shared region or a stream.
6. **Kernel entry**: the kernel ring only.
7. **Thread-local data is not in the contract.** The loader has no support for thread-local segments. Each thread starts with the address of its thread record. The `gs` register of the thread also holds this address: the first word of the thread record is its own address, so `mov rax, [gs:0]` gives it on any stack. The kernel ring of the thread is one page after the thread record. This is the only use of `gs` (amended on 2026-11-10, with threads: one kernel ring per thread needs a way to find the ring that does not depend on the call chain). The thread record holds no data of a module, and the loader has no thread-local segment. The `fs` register is free for the private use of a program.
8. **No unwinding. Frame pointers are required.** No exception crosses a module boundary. An error is a status value. A fault stops the program. Every module keeps frame pointers (`rbp` on x86-64), so that a debugger or a profiler walks the stack with no tables. The owner confirmed and widened this rule on 2026-11-10: no contract of the system uses an exception to tell an error. An exception makes a program fail at a place that the code does not show, and it needs a runtime that unwinds the stack to give the explanation. The system needs no such runtime. A language can have exceptions inside its own module, with its own runtime in that module: the system does not control that, and does not serve it. To read the stack is not forbidden: after a fault, a tool walks the frame pointers and names the calls, and no code of the program runs for that.
9. **The kernel is a module.** The boot program contains the loader and loads the kernel as a module. The hash of the kernel module is the value that the TPM measures (P17).

## Open questions

1. **Initial data of a merged module.** Rule 3 gives each program one copy of the data of each module. The merge tool must keep this true when it merges two modules that both have data.
2. **Description tables.** Version 1 of the format has one function record per export: name, help text, up to 6 parameter types, result type. The types are `Integer` and `Text` only (`contract/module/format.odin`). The type, field and parameter tables are not yet specified at the level of bytes.
