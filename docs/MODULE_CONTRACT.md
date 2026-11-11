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
4. The loader reads flat tables. They are the only format of the metadata; functions give the information of the modules from them (P12, changed on 2026-11-10: no SQLite). The functions are `support/information`; section 4, "Tables", gives the form of their results.
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
- **Shared code** (choice 136 of `FIRST_MILESTONE.md`): a prepared module has two parts. The code is the segments with no Write: the loader never writes them (a rebase and a slot are in a segment with Write, and the loader checks it), so their pages are the same at each base and with each binding, and the table keys them by the hash of the module only. Two programs that import one module at two places map one copy of its code. The fixed part is the segments that are read-only after the load: the loader writes their rebases and their slots, so the table keys them by the hash, the base, and the hash and the base of the module of each import. A writable segment, with its slots, is bound in the copy of each program.
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
- **What the record does not explain**: the first failure only: a load stops at the first stage that fails. It does not say which part of a Record differs (only that the two records differ, and their names). It does not say why a file is in the load source or not. A replacement nearer to the failure hides one farther on the path: the record holds one replacement. A fault report gives the stack trace (section 8): a fault in B2 that a call from A caused names B2, then A. The record of a call host comes from another program: the console checks its values, and cannot prove them.

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
| Errors | A function that can fail gives a negative integer result, and writes an error record at an address that the caller gives (section 8) |

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
| Table result | One more argument: the address of a buffer record `{address, capacity in records}`; the integer result is the count of records of the full table | One more field: the buffer `{offset, capacity in records}`, the rest of the call region from a multiple of 8 |
| Table or Bytes parameter (2026-11-11) | The address of a table place `{address, count, capacity}` in memory of the caller | 32 bytes: `{start, count, capacity, memory}`: the records in the call region, or in a lent memory object (section "Tables and bytes as parameters") |

- **Record description**: The tables Records and Fields. A record has a name, a size (256 bytes at most) and fields. A field has a name, an offset and a type: Integer (8 bytes), Handle (4 bytes), or Text with its size in the detail (1 to 256 bytes: UTF-8, zero bytes after the text; added on 2026-11-10 for the information of the modules). A record holds values only. The loader code checks each description before a use: each field is inside the record.
- **A record is copied one time**: The receiver copies the bytes of the record from the call region to private memory, then gives the address of the copy to the export. The caller cannot change the record while the export reads it.
- **A handle is lent**: The description has the rights that the export needs. The caller gives a copy of its handle to the receiver, with these rights only, through the call ring: the kernel operation `Handle_Give`, with the memory object of the call ring as the target. The receiver closes the copy when the export returns. The caller keeps its handle.
- **The receiver proves each handle**: The number of the handle is in memory that the caller writes. The receiver asks the kernel if this handle came through the call ring (`Handle_State`), and if it has each right of the description. If not, the status of the call is 3, "bad handle", and the export does not run. Without this proof a caller names a handle that the receiver holds for itself.
- **The caller takes back what it lent** (step 25): the caller gives a handle that comes from a copy of its own handle, and revokes the copy after the call (`system.lend`, `system.lend_end`, the kernel operation `Handle_Revoke`). The handle of the receiver ends, and each mapping that the export made with it. An export that keeps a mapping for a later call stops its program on a page fault at the first use. If the caller cannot give each handle, it revokes those that it gave and sends no record.
- **Limits**: 16 handles for one call. A result record has no handle. An export with a Record result has 5 parameters at most.
- **A Table result** (added on 2026-11-10, property 12; `GLOSSARY.md`, "Table"): records of one description that follow each other, in memory of the caller. The callee writes the records that fit and gives the count of the full table, as a Text result gives its count of bytes; a count larger than the capacity means "the table did not fit", and a negative count is an error that the documentation of the export names. A record of a Table has no Handle. The caller reads `min(count, capacity)` records: it trusts neither number (`isolated.result_table`). This is the form of HANDOFF item 94 (1) for a result: many records in one call, in memory of the caller, never a list of pointers. A table as a parameter (item 94 (2)) is done on 2026-11-11: section "Tables and bytes as parameters".
- **In Odin**: `^Name` is a Record, `result: ^Name` as the last parameter is a Record result, `result: ^[]Name` as the last parameter is a Table result, `^system.Table_To_Read(Name)` (and `_Change`, `_Append`) is a Table parameter, `^system.Bytes_To_Read` (and `_Change`, `_Append`) is Bytes, a field `[N]u8` is a Text of N bytes, a field `u8`, `i32`, `u32`, ... or an `enum u8` is an Integer of its size, and `system.Lent({.Read, .Write})` is a Handle. `Name` can be a struct of the package or of a package of `support:` or `contract:` that the file imports (`^information.Module`). The tool reads them in the source (`kerneltool`, `describe.odin`). A module in another language writes the same tables.
- **Tests**: `odin test` of `contract/isolated` has a round trip with a record, a handle and a record result, and the refused cases. The machine test calls `modules/sample` in a call host and in the console.

### Tables and bytes as parameters

Status: decided by the owner on 2026-11-11 ("ok bah on le fait alors ? [...] sinon go"; `HANDOFF.md`, item 94 (2)). Designed and implemented on 2026-11-11. The owner has not reviewed the choices below.

A table goes into a call, with no copy in a direct call. Two users need it: the interface package (a table of draw records and a table of text bytes that each call appends to) and the cryptography module (seal or open N packets in one call, over a table of packet records and the bytes of the packets).

#### What the two users pass

| Use | The table | What the callee does |
|---|---|---|
| Sum a field, draw a draw table, check a list | N records | Reads them |
| Open or seal N packets | N packet records; the bytes of the packets | Writes a status and a length in each record; changes the bytes in place |
| An element of the interface | The draw table and the text table of the frame | Appends records and bytes after those of the calls before |
| The Table result of today | A buffer of records | Fills it from the start, and gives the count of the full table |

A record can name bytes outside itself: a draw record names a run of the text table (`text_start`, `text_count`), a packet record names its bytes. Such a field is an offset into another parameter of the same call. It is data, not an address: the contract keeps "a record holds values only". The callee checks each offset against the count of the other parameter, and gives an error record when it is outside: never a fault.

#### The forms

Two parameter types, one direction for each parameter:

| Type | Detail | Meaning |
|---|---|---|
| Table (5) | The index of the description of the record | Records of one description that follow each other. A record of a table parameter has no Handle field |
| Bytes (6) | 0 | Bytes with no description, with a direction. A Text stays the read-only form of UTF-8 for a person |

| Direction | Value | The callee | The count |
|---|---|---|---|
| Read | 0 | Reads the records `0 ..< count`. Writes nothing | Stays |
| Change | 1 | Reads and writes the records `0 ..< count` | Stays |
| Append | 2 | Writes the records `count ..< capacity`. Reads none of the records before `count` | The callee sets it to the count of the full answer: the count on entry plus the records that it appended, also those that did not fit |

- **Read is 0**: a zero direction is the one with the least power (P13).
- **Append covers fill and append.** Fill is Append with a count of 0. The Table result is the special case "the last parameter is a table that the export appends to from 0, and the new count is its integer result": it stays as it is.
- **Did not fit**: a new count larger than the capacity means that the answer did not fit, as for a Text result. The callee writes only the records below the capacity. The caller reads `min(count, capacity)` records, and trusts neither number. A count on entry larger than the capacity is refused: the caller keeps its count at most at the capacity.
- **A capacity of 0** is valid: the callee writes nothing and gives the count of the full answer.
- **No capacity rule in the description.** The caller chooses the capacity; the count says how much the full answer needs, as the Text result does.
- **Refused**: a table of tables, a table in a record, a record that holds an address, a Handle field in a record of a table (one call lends at most 16 handles), a direction on a parameter that is not a Table or Bytes, a "write only" direction (Append is it), more than one table in one register.

#### One description, three ways to call

The description is the same in the three ways (P10, P19). The source of the export does not change. Only the code of the caller and of the receiver differs, and `support/system` holds it.

**(i) A direct call** (the module is in the address space of the caller: `load("sample")`, an import). A Table or Bytes parameter takes one integer register: the address of a table place in memory of the caller.

| Offset | Field | Type | Meaning |
|---|---|---|---|
| 0 | `address` | u64 | The first record. Aligned on the alignment of the record (the largest alignment of its fields, at most 8); Bytes: no alignment |
| 8 | `count` | u64 | Records (Bytes: bytes) |
| 16 | `capacity` | u64 | Records (Bytes: bytes) that the memory at `address` holds |

- The callee writes only the records that its direction names, and only `count` of an Append place.
- **The size of a record** is the size of its description. No size travels with the place. The caller and the callee have the same description: an import names the exact module by hash, and the check of a replacement compares each record of each parameter, with its direction (`module.functions_compare`). A record of a parameter has no versions: the rule of the table directory ("a reader that knows a shorter record") is for the tables of the file. A caller that is not bound by the loader, the console, compares the record of its value with the description before it calls (`module.records_equal`).
- **What a module in C writes** (no other language feature is used):
  ```c
  struct table_place { void *address; uint64_t count; uint64_t capacity; };
  struct reading { int64_t sensor; int64_t value; };
  int64_t sum_values(const struct table_place *readings);              // Read
  int64_t scale_values(struct table_place *readings, int64_t factor);  // Change
  int64_t readings_above(const struct table_place *readings, int64_t limit, struct table_place *result); // Read, Append
  ```
  Its description is the same tables: the Functions record has the type Table, the index of the record `reading`, and the direction of each parameter. The kernel tool reads the Odin source; a module in C gives a small description file (section 7).
- **In Odin**: `readings: ^system.Table_To_Read(Reading)`, `^system.Table_To_Change(Reading)`, `^system.Table_To_Append(Reading)`, and `^system.Bytes_To_Read`, `^system.Bytes_To_Change`, `^system.Bytes_To_Append`. Each is a struct `{records: [^]Reading, count, capacity: u64}` with the layout of the table place: the name of the type is the direction, and the kernel tool reads it.

**(ii) An isolated call** (a call host or a service: another address space). The field of the argument record has 32 bytes:

| Offset | Field | Meaning |
|---|---|---|
| 0 | `start` | The offset of the records: in the call region, or in the memory object of `memory` |
| 8 | `count` | As the table place |
| 16 | `capacity` | As the table place |
| 24 | `memory` | 0: the records are in the call region. Else: a lent memory object, as the receiver names it: form (iii) |

- **The caller** (`isolated.encode`) copies the records `0 ..< count` of a Read or Change table into the call region, after the bytes of the other arguments, at a multiple of 8. For an Append table it reserves `capacity - count` records and copies none. A table that does not fit refuses the call: `encode` gives the place that was missing, and the caller writes "the table readings has 65536 records of 40 bytes: 2621440 bytes; the call region has 64992 bytes free; lend a memory object" (form (iii)).
- **The receiver** (`isolated.decode`) copies the argument record once, then checks each table field: `start` is a multiple of 8, the bytes of the records are inside the call region with no overflow, `count <= capacity` for Append, and no count or capacity times the size of a record passes `TABLE_SPAN` (finding F1 of the hostile read). It refuses two ranges of the call region that overlap when one of them is written: a Change or Append table, a result, the error record, and the argument record, whose counts it writes back (finding W3); two Read ranges can overlap. Each refusal of the receiver is an error record in the values of the completion record (Bad_Arguments, Bad_Handle): the number of the argument, the kind, the value and the limit (finding W8); the console and `system.call_isolated` give its sentence, for example "sum_values: the argument readings has 1099511627776 records; it can have at most 429496729 records". It gives the export a table place in its own memory: the caller cannot change `count` or `capacity` while the export runs. For an Append place in the call region, `address` is such that record `count` is the first reserved byte: the records before `count` are not in the call, and an export that reads them reads its own memory, never the memory of the caller.
- **After the export** the receiver writes the count of each Append place back into the field of the argument record (`isolated.counts_store`). The caller (`isolated.tables_return`) copies back, into its own memory: the records `0 ..< count` of a Change table, and the records `count ..< min(new count, capacity)` of an Append table. A new count smaller than the count on entry is an error of the callee: the caller checks each answer before it copies, so it keeps each count and copies nothing (finding W7). When the export fails (a negative result with an error record), the caller copies nothing back from the call region; a table in a memory object keeps what the callee wrote before it failed: the callee wrote the memory of the caller (N7). The caller never writes its memory at or after the capacity: a callee that writes the whole call region changes nothing of the caller after the capacity (a host test proves it with a guard pattern).
- **The call region is shared. Rule: an export copies a record before it checks it**, and uses only the copy. The caller can change the records while the export reads them, as for a Text (choice 186). The copy is one volatile load of the whole record (`intrinsics.volatile_load(&record)` in Odin, a `volatile` read in C): with a plain read, the compiler can read the field again after the check. `sample.sum_words` is the model; its host test changes the record from another thread during 2 000 000 calls (finding W2 of the hostile read: before, a start read two times made a slice that stopped the service). The table place itself is a private copy of the receiver. An Integer field from an isolated caller can hold any value of its size, also a value that is not a name of an `enum` of the source: the export checks it as each value.

**(iii) A table in a memory object** (a table too large for the call region, or a table that the caller keeps in a memory object). The caller lends the handle of the memory object with the rights of the direction: Read for Read, Read and Write for Change and Append (P20: the rights of the lent handle are the direction). The field has `memory_handle` set and `start` is the offset of the records in the object.

- **A call host only. A service refuses a table in a memory object** (finding W1 of the hostile read): another thread of the caller can revoke the lent copy while the export runs; the kernel then removes the mapping of the receiver, and the fault of the export stops the program. A call host serves one caller, which stops only its own call; a service serves each caller, and one caller must not stop it. `export_serve` takes `memory_objects_allowed`: true in a call host, false in a service, which refuses with Bad_Arguments and an error record of the argument. A table larger than the call region goes to a call host.

- The receiver proves the handle as each lent handle (`Handle_State`: it came through the call ring, with each right), checks that it names a memory object (N3), checks that the records are inside the object, maps only the pages that hold the records for the time of the export (`Memory_Map`, Write only for Change and Append; N8), and gives the export a table place at the mapping. After the export it unmaps the object, writes the count of an Append place back, and closes the handle. The caller revokes its copy after the call (`lend_end`): a mapping that the export kept ends.
- No copy: the export works in the pages of the caller. The caller reads its own memory after the call.
- **The granularity is the memory object.** A callee with Write can write each byte of the object while the call runs, also after the capacity. A caller that lends only the table puts the table in an object of its own.
- **The address of the mapping**: the receiver maps only the pages of the records, at `isolated.TABLE_ADDRESS + n * TABLE_SPAN` for parameter n (16 GiB for each parameter), the same addresses at each call. This is a work-around of a fault of the kernel, found by the measure: the kernel gives each mapping that does not choose its address a new range (`Program.next_address` only grows, "a mapping with no chosen address never reuses a range"), and each new range costs page tables that the budget of the receiver pays; a call host of 512 pages refused the 61st call of a table of 640 pages. The fault is given to the agent of `work/scheduler`; the work-around stays until its correction is in `master`. The records reach at most `TABLE_SPAN` less one page from the first page, so the pages of one parameter never enter the span of the next (N2).
- **The seam**: `system.call_isolated` (`support/system/calls.odin`) chooses the form of each table argument that names a memory object: the call region when the records fit there, the memory object only when they do not. The measures below give the call region the lower cost at each size that fits. `keep_memory_objects` lends each memory object as given (the measure uses it). The export does not know which form ran: `system.call_direct`, `system.call_isolated` and `export_serve` take the same `isolated.Argument` records, and the program `tables` checks the same answers in the three ways.

#### The format

- `Function.parameter_directions` (6 bytes, one for each parameter) is added at the end of the Functions record: 96 bytes become 104, by the growth rule of the table directory. A reader of a file with 96-byte records reads each direction as 0, Read. No version and no feature bit change: each module is built again with the system (owner, "Do not preserve backward compatibility"), and the growth rule keeps a smaller record readable.
- `Type.Bytes = 6`.
- **Integer fields of 1, 2, 4 or 8 bytes** (the draw record has `u8`, `i32` and `u32` fields): `Field.detail` of an Integer is its size in bytes, 0 for 8 (the fields of today); `Field.unsigned` (a byte of the field that was reserved) is 1 for an unsigned integer. An Integer field is at an offset that is a multiple of its size. `module.field_integer` reads one as an i64. Odin `u8`, `i8`, `u16`, `i16`, `u32`, `i32`, `u64`, `i64`, and an `enum` with such a backing type, are Integer fields.
- **The checks**: the loader does not read descriptions (section 2); each reader checks what it uses. `module.record_type` checks the size and the alignment of each Integer field. `isolated.record_size` refuses a direction out of the enumeration, a direction on a parameter that is not a Table or Bytes, a Table whose record is not valid or has a Handle field, Bytes with a detail. `information.check` gives a `Problem` with the byte of the file for each of them (`manual.check`).
- **The check of a replacement** compares the directions: `Difference.Parameter_Direction`, with the sentence "export sum of sample_fixed: parameter 1 is Table(Reading, Change), sample has Table(Reading, Read)".

#### The callers

- **The console**: a Table value is an argument where the description takes a Table of an equal record (`module.records_equal`), with the direction Read or Change; a Text value is an argument of Bytes with the direction Read. A Change table changes the memory of the value: a variable holds the changed rows after the call. An export with an Append table parameter, or Bytes with Change or Append, is not a command of the console: the language has no second result. `columns` and `where` give tables that go into a call.
- **`kerneltool call`**: a Table argument is a literal of rows, each row the values of its fields in order: `monitor.counts_named([("programs"), ("processors")])`; a Bytes argument with the direction Read is a text. The answer of `remote` has one result place: an export with an Append table parameter is refused with a sentence.
- **The text of a signature**, one form in the manual, the console, the errors and `help()`: `sum_values(readings: Table(Reading, Read)) -> Integer`, `seal(packets: Table(Packet, Change), bytes: Bytes(Change), key: Key) -> Integer`.

#### What the cryptography module uses (to the agent of `work/tcp`)

Seal or open N packets in one call:

```odin
Packet :: struct {
	bytes_start:   u32, // The first byte of the packet in the parameter `bytes`.
	bytes_count:   u32, // Its bytes. Seal: the plain text in; open: the sealed text in.
	result_count:  u32, // Written by the export: the bytes after the operation.
	status:        u32, // Written by the export: 0 sealed or opened; else a reason (a tag that differs, outside the bytes).
	number:        u64, // The packet number of the nonce.
}
// seal seals each packet in place. The bytes of each packet need 16 more bytes after it, for the tag.
@(export, link_name = "seal")
seal :: proc "c" (packets: ^system.Table_To_Change(Packet), bytes: ^system.Bytes_To_Change, key: ^Key, error: ^errors.Error_Record) -> i64
```

- The record names its bytes by offset in `bytes`; the export copies each packet record once (the rule above), checks `bytes_start + bytes_count + 16 <= bytes.count` on the copy, writes `status` for a packet outside, and goes on with the next one. Two packets whose bytes overlap: the export reads the bytes of each packet only after the packet before is sealed; the caller does not give overlapping packets (the receiver checks overlap of parameters, not of the records inside one parameter).
- Direct call: no copy. Isolated call: the records and the bytes of a batch up to the call region (64 KiB with the argument record) are copied; a larger batch is a memory object (form (iii)), with Read and Write.
- `Key` is a Record (at most 256 bytes); a key in a record is copied once by the receiver. A key that the caller must not give to the module stays outside it: that is a service that holds the key, not a parameter.

#### Measures

The program `tables` measures `sample.sum_values` (it reads 8 bytes of each record of 40 bytes), the least time of several runs, in ns for one call (QEMU with KVM, 4 processors; the load of the host was 32 to 48 during the run: other machine tests ran; a measure at a load above 8 is not valid by the rule of the coordinator, and these are the numbers of that run):

| The way | 64 rows (2.5 KiB) | 1024 rows (40 KiB) | 65536 rows (2.5 MiB) |
|---|---|---|---|
| Direct call | 12 | 250 | 26 284 |
| Call host, call region (ii) | 6 671 | 8 787 | does not fit |
| Call host, lent memory object (iii) | 12 500 | 13 146 | 76 422 |
| Service, call region (ii) | 3 327 | 8 217 | does not fit |

- A direct call costs what the loop costs: no copy.
- An isolated call costs a wake of the other program and its answer, 3 to 12 us under this load; the copy of 40 KiB into the call region adds about 2 us.
- (iii) adds the lend of the handle, its proof, the map and the unmap, and the revocation: about 6 us more than (ii) at 64 and 1024 rows. It wins only when the table does not fit in the call region: then it is the one way, and 2.5 MiB cost 76 us, 50 us more than the direct call.
- **The interface package as a module** (`programs/interface_through_module`): one frame of 31 draw records and 448 bytes of text in 25 element calls, 523 ns through the module against 283 ns with the package compiled in: about 10 ns more for each element call (an import slot and a frame of the package made over the two tables at each call). The damage and the drawing of the window through the module: 9.7 us (the third frame, its damage only). The two draw tables are equal, record for record and byte for byte.

### A call from the host

Status: asked by the owner on 2026-11-11 (`HANDOFF.md`, item 19). Implemented on 2026-11-11. The owner has not reviewed the choices below.

The test tool and a developer read the state of the running system as typed records, through a call of an export with a description (P19), and not by a search of text in the log. `kerneltool call "monitor.programs()"` calls an export of a service in the machine from the host.

- **The host encodes, the remote service relays.** The host has the module files (`build/modules/<name>.module`), so it has the description of each export. The tool parses the text of the call, checks each argument against the description, and writes the argument record with `isolated.encode`, as a caller program does. The remote service does not read a description: it copies the bytes, makes the isolated call through its connection, and sends back the bytes of the places that the request names. The service checks the call region, as for each caller (`isolated.decode`).
- **The path.** The tool sends the call request to the peer, on the loopback of the host. The peer writes it in a UDP frame from 10.0.2.2, port `remote.HOST_PORT`, to the endpoint of the remote service, and gives the datagrams of the call answer back to the tool. The remote service sends one call answer with the status Started when it starts: the peer learns the local port of its endpoint from it.
- **The format** (`contract/remote`): fixed headers, little-endian, no text, no field that a language defines. A call request is a `remote.Request` of 104 bytes, then the first bytes of the call region: the argument record at offset 0 and the bytes of its Texts and Records. A call answer is one or more datagrams, each a `remote.Answer` of 128 bytes, then a part of the result: `total` is the bytes of the whole result, `offset` the place of this part, `count` its bytes. A part has 1344 bytes at most (1472, the data of one datagram, less the header): a result of the call region (64 KiB) is 49 datagrams.
- **What the result is.** The request names the place of the result in the call region and the bytes of one unit of the integer result there: 1 for a Text, the size of a record for a Table, 0 for a Record (the whole place). The remote service sends `min(integer result, count / unit) * unit` bytes: the integer result of the export is a count that the remote service does not trust.
- **The error record.** A failure of the export (a negative integer result of an export with an error record) gives the record of the service in `Answer.error`. A refusal of the remote service itself (the status Refused) gives its own record in the same field: `argument` is the number of the field of the request that is wrong, from 1 (`remote.REQUEST_FIELD_NAMES`), and the sentence is "remote: the argument result_count has 70000 bytes; it can have at most 65536 bytes". No call runs after a refusal.
- **The checks of the remote service** (`remote.request_check`): the size of the datagram, the kind, the number, the name of the service, the count of the bytes of the arguments against the bytes of the datagram, the argument record inside them, the place of the result and of the error record inside the call region, the error record aligned on 8. Then the service: a connection that the root service gives (else Absent), and the hash of its module equal to the hash of the request (else Bad_Value; the answer has the hash that runs, so the tool says which build the machine runs).
- **A lost datagram.** The tool sends the request again with the same request number after 300 ms with no complete answer. The remote service keeps the last call answer: a request with its number gets it again, and the call does not run two times. A call of an export that changes something (`storage.write`) is then made one time. The tool reads at most 64 KiB and checks each part: its place inside the total, the total inside the call region.
- **Who can be called.** The root service decides: the remote service holds a ring to the root service that serves `Connect` and `Disconnect` only, to the services that `callable_of("remote")` names: `manual`, `monitor` and `storage`. It connects at the first call to a service, and again after a stop of the service.
- **The person.** The remote service acts for the person (`isolated.CALLER_PERSON`): `manual.running()`, `monitor.programs()` and `storage.stores()` give it what the person sees. Reason: the call comes from the developer at the host, who is the person of this machine, and the purpose is to read the state of the system; a grant of less makes the tool see less than the console. The grant is a line of the root service (`grants_of`), and `revoke("remote", "person")` in the console ends it: the root service tells each service of the remote service that the grant of its connection changed, and the next call is refused with its error record.
- **What it does not protect** (property 20): UDP has no authentication. A machine on the link of the machine that sends a datagram with the address 10.0.2.2 and the port of the grant makes a call with the grant of the remote service, and reads its answer if it sees the frames. The grant of one remote filters the address, it does not prove it. QUIC, a later step, gives authentication. This step adds no password: a secret in a datagram with no encryption protects nothing.
- **A machine that runs outside the test.** `kerneltool run` starts the machine with a window, and the peer with its port of call requests at 127.0.0.1, UDP port 7101 (`CALL_PORT` of the tool). Start `remote` from the menu of the bar, or `start("remote")` in the console. Then, in another terminal of the development shell: `kerneltool call "monitor.programs()"`. The tool reads the module files of `build/modules`: the machine must run the boot image of the same build, else the remote service refuses the hash. In the machine test the peer takes a port that the system chooses, and the step `Call` uses the same code.
- **The monitor** is the first service of inspection: `programs()` (a Table of `Program`: slot, name, state, pages, mapped pages, handles, threads, processor time, kernel entries, start time, from `op.Program_Report`), `counts()` (a Table of `Count`: name, value, unit, from `op.System_Report`), `count(name)` (one count as an Integer) and `served()` (a Record of the calls of the monitor itself). The first three give facts of other programs and of the machine: only to a caller that acts for the person, else `No_Grant`. The monitor already reads these facts with the machine and the right Inspect for its window, so the exports need no new grant; the remote service does not get the machine.
- **The second layer** (2026-11-11). Each one is a new export with a description; the request and the answer did not change.
  - **A lost datagram and another hash, tested.** The peer drops the datagram of an answer when the step asks it (`lose`): the tool sends the request again, `remote` sends the answer that it kept, and `monitor.served()` shows that the monitor ran the call one time. A request with a changed hash (`wrong_hash`) is refused, and the tool names the hash that runs and the hash that it sent.
  - **The compositor is a service**: `pointer()` (one row of `Pointer`: x, y, buttons, the pointer records that arrived, the menu of the bar that is open, whether the launcher is open) and `windows()` (a Table of `Window`: title, place, size, order from the front, focus, whether the keys go to it). They are facts of the screen of the person, so they need the caller to act for the person. `pointer()` is a Table of one row and not a Record: a Record result cannot refuse (this section, "Records and handles"). The root service gives the compositor a service ring and its own file at the values 4 and 5 of its context (0 to 3 are the screen).
  - **The confirmed place of the pointer.** Before each press of a step `Click`, `Drag`, `Launch`, `Move`, `Close` or `Front`, the tool reads `compositor.pointer()` and moves the pointer again from the place that the compositor has, until it is the place of the step (6 tries; a failure names the two places). Before `remote` runs, the tool moves the pointer with no confirmation, as before.
  - **The log records as a table**: the program `log`, which holds the grant to read the log, serves `records(after)`: one row of `Record` for each log record from the number `after` (number, time, program, slot, level, channel, text, and in the first row the records that the kernel wrote over). The caller acts for the person: the log has facts of all programs. The step `Record` of the test waits for a record of a program, a channel and a level with a part of a text. The serial port stays the one path that works before `remote` runs and when the network does not: the machine test reads it for each other check.
  - **Arguments from the host**: Integers, Texts, and since 2026-11-11 tables to read: a literal of rows, `monitor.counts_named([("programs"), ("processors")])`, and a text for Bytes(Read). A Record argument has no text form yet: no export that `remote` reaches takes a Record. A Change or Append table is refused: the answer carries one result place, and the rows would not come back.
- **The three uses that come next, with no change of the format.** Done in the second layer, except the move of most `.Wait` checks. (1) Log records as binary records: an export of a service gives a Table of log records (`op.Log_Record` has a fixed size), and the tool prints it with its field names. (2) The `.Wait` checks of the machine test become `.Call` checks that compare fields of records. (3) The pointer place of the compositor: an export of the compositor gives a Record of the place, and the tool reads it before a click. Each one is a new export with a description; the request and the answer stay as they are.

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
- **The direction flag** is clear at each call and at each return, as the System V convention says. A module that sets it clears it before its next call or its return. The kernel does not trust a program for it: the `syscall` entry clears it (the mask of `MSR_SFMASK`, `kernel/processor.odin`), and each interrupt entry runs `cld` before its first call (`kernel/processor.asm`). `rep movsb` and `rep stosb` in `copy_bytes_without_overlap`, `copy_bytes_with_overlap` and `fill_bytes_with_value` (`runtime/memory.asm`) depend on this rule.
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
5. Every module, the kernel and the boot program link `runtime/memory.asm`: `copy_bytes_without_overlap`, `copy_bytes_with_overlap` and `fill_bytes_with_value`. The compiler calls them by the names of the C library (`memcpy`, `memmove`, `memset`): the file gives these names as aliases, in a part of its own, and the code of the system uses the long names. The kernel tool builds without `-no-crt`, so the Odin runtime does not give its own functions under these names (loops of one byte, two with no optimization). A module in another language links the same file.

This reuses the compiler, the linker and the debugger formats. The project writes one converter and one loader.

- **ELF is a build-time intermediate format only.** LLVM, which Odin and clang use, writes only ELF, COFF and Mach-O objects. ELF never reaches the running system.
- **Every step is a command of the kernel tool.** No script calls the compiler or the linker directly.

### The linker

Status: Decided by the owner on 2026-11-09, after the study in `research/rad_linker_rdi_study.md`.

- The project does not write a linker. It uses `lld` on the ELF target.
- The converter of the kernel tool takes the linked ELF file as input and writes the module.
- **RAD Linker**: not adapted. It reads COFF and writes x64 PE only. Its output stage is not separate from its core. A COFF target also brings the Windows x64 convention, which conflicts with section 4.
- **Later**: the merge tool of section 3 can replace `lld`. `mold` and `wild` are faster ELF linkers to compare if link time becomes a problem.

## 8. Errors that diagnose

Status: asked by the owner on 2026-11-10 (`HANDOFF.md`, "No exceptions in the contracts", "System errors that diagnose", "A program that shows the errors"). Designed and implemented on 2026-11-10. The owner has not reviewed the choices below.

### The rules

1. **The status stays the fast answer.** A kernel operation gives a `Status`, and an export gives its result. A call that succeeds writes no error record and reads none: the path of success has no added instruction in the kernel and no added copy in a service.
2. **A call that fails gives back an error record.** It is a value of the call, in memory that the caller owns (P14): no global state, no exception, no text.
3. **One form**: `errors.Error_Record` (`contract/errors`), 56 bytes, seven Integer fields. Zero is "no error" (P13).
4. **No ambient facts** (P20): a record describes what the caller gave and the handles of the caller. It names no other program and no object that the caller cannot see.
5. **A sentence comes from the record.** `system.error_text` writes one sentence from the record and the names of the operation and of the argument. The record holds no text: the caller has the text of each argument that it gave.

### The error record

| Field | What it holds |
|---|---|
| `kind` | An error kind (`errors.Kind`): what is wrong. 0: no error |
| `unit` | What `value`, `limit` and `found` count (`errors.Unit`): bytes, pages, blocks, handles, objects, ... |
| `operation` | The kernel operation (`op.Operation`), or the number of the export in the file of its module |
| `argument` | The number of the argument that is wrong, from 1. 0: the call as a whole |
| `value` | The value that the argument had: a number, the count of bytes of a text, a handle, an address |
| `limit` | What the argument must respect: a largest value, a size, the rights that the operation needs, the kind of object that it needs |
| `found` | What the system found: the rights of the handle, what a budget still holds, the kind of the object, how a handle ended |

The kinds, the meaning of `limit` and `found` for each kind, and the units are in `contract/errors/errors.odin`. Examples of sentences:

- `storage.write: the argument name is empty; it must have 1 to 39 bytes`
- `Memory_Map: the argument memory, handle 0x30004, has the rights Give Read; the operation needs Read Write`
- `Memory_Size: the argument memory, handle 0x20007, was revoked`
- `Memory_Create: the argument budget, handle 0x10009, cannot pay 66 pages: it holds 8 pages`

**Why 56 bytes**: it is the size of the values of a completion record. A kernel operation gives its record there, with no other memory.

**Why Integer fields only**: a record description has Integer, Handle and Text fields (section 4). Seven Integer fields make the record a described record: an export names it in its description, and the console and a program in any language read it with that description.

**Why no field for the source** (kernel, service, module, loader): the caller knows where it called. The `operation` field has its meaning from that place.

**Why no name in the record**: the name of a kernel operation and of its parameters is in the operation table (`op.OPERATIONS`); the name of an export and of its parameters is in its description. 56 bytes cannot hold them.

### The three places

**A kernel operation.** The completion record of a command that failed has the status in `kind` and the error record in `values`. A batch of commands that fails several times has one record for each failure. The kernel finds the record after the operation failed (`kernel/diagnose.odin`): it reads the form of each parameter in the operation table (a handle of a kind with rights, an address with a size, a count with a limit, flags), and checks the parameters in order, as the operation does. The operations themselves do not change. With an operation that the table does not explain, the record has the kind `Refused` with the status: an honest "no more detail".

- **Why the completion record, and not a record in the thread record**: the owner was told "a record for the thread, in memory of the thread". The completion record is in the kernel ring, which is memory of the thread. One record in the thread record holds one failure of a batch, and it is a value outside the call: the defect of `errno`. A completion record is the answer of one command.
- **In a program** (`support/system`): `system.call` gives zero results when the status is not Ok: a caller that tests a result and not the status reads 0, never the record as a value. `system.call_with_error(error, operation, ...)` writes the record at an address that the caller gives, and each wrapper (`memory_create`, `memory_map`, `give`, ...) takes the same `error` as its last parameter, `nil` by default. It is the rule of an export: the caller gives the memory, the callee writes it on a failure only, and no global state keeps the last error. A wrapper with no status (`memory_size`) gives 0 and writes the record: a caller that starts with a zero record (ZII) reads the kind.
- **A handle that ended**: the kernel keeps, in the handle slot that a close or a revocation emptied, how it ended. A handle of the generation before says "was closed" or "was revoked". An older handle says "names no handle".
- **When the state changes after the failure.** The kernel reads the state again after the operation failed. With one lock for each kind of data (`ARCHITECTURE.md`, "Locks of the kernel"), another thread can change it between the failure and the record: a thread of the program closes the handle, a revocation ends it, a budget pays for another object. What the record promises:
  1. It never contradicts the status. Each status has its kinds (Bad_Handle: Handle_Absent, Handle_Ended, Handle_Kind, No_Target; No_Right: Handle_Rights; No_Budget: Budget, Budget_Hidden, Over_Limit; Bad_Address: Bad_Address, Too_Long, Too_Small, Overlap, Absent; No_Slot: Full, Too_Long; Bad_State: State; Bad_Operation: Bad_Flags, Bad_Value, Too_Small, Too_Long, Unknown_Operation). A record of another kind becomes `Refused` with the status.
  2. When the cause is gone (the kernel finds no argument that is wrong now), the record is `Refused` with the status.
  3. Each value of the record comes from one copy of one table, read under the lock that protects it; two tables are not read at one instant. A record can describe a cause that came after the failure, if it explains the same status: for example a handle revoked after a refusal for a right is then Handle_Ended, and becomes Refused, because Handle_Ended does not explain No_Right.
  `kernel/diagnose.odin` reads each table in one procedure that takes its locks in the lock order of `ARCHITECTURE.md`, copies, and frees them. `diagnose` runs after `command_run` freed all the locks of the operation, and only on a failure; the test build stops the machine if it runs with a lock held. The handle table, the mappings, the module records and the page table of the caller (`read_handle`, `read_handle_find`, `read_free_handles`, `read_user`, `read_range`, `read_overlaps`, `read_mapping_at`, `read_own_full`, `read_word`, `read_threads`): the program lock of the caller. The log count (`read_log_count`): the program lock only; the handle with Read keeps the budget live, `program.budget` is an atomic word that changes only when that budget ends, and the limit of a live budget never changes. A budget (`read_budget_rights`, `read_budget`): the program lock; with Read, the frame lock for the pages, and the control lock first only for the programs, the threads and the limits (`Program_Create`, `Thread_Create`, `Budget_Create`, which take the control lock themselves). A memory object (`read_memory_pages`): the program lock, then the frame lock. The table of the memory objects (`read_regions_full`): the frame lock. The tables of programs, threads, budgets and message interrupts (`read_machine_full`): the control lock, on a `No_Slot` only. The state of another program (`read_program_state`): the control lock, the program lock of the caller, then the program lock of the other program. A read through a handle keeps the program lock of the caller while it reads the object: the reference of the handle keeps the slot of the object.
- **A kind is written only when its cause holds now.** Each branch checks its cause, one read under a lock that `diagnose` takes: a `Budget` record has `limit > found`; an `Over_Limit` record of `Log` has `value > limit` (else a budget above refused, or a new second started, and the record is `Refused`, so it shows nothing of a budget above); `Overlap`, `Absent` of `Memory_Unmap`, the `Bad_Address` of a range and of a word are read again; a `Full` table is named only when it is full now and is one cause that the state shows (`Thread_Create`: the thread areas of the program, then its mappings, then the memory objects, then the thread table). A cause in another program (its mappings, its module records) is not read: the record is `Refused`.
- **Without Read on a budget** the record depends on the operation alone: the unit Pages for `Memory_Create`, Programs for `Program_Create`, Threads for `Thread_Create`, no amount for `Budget_Create`, and the argument 1.
- **A handle of the generation 0xFFFF** that was closed gives `Handle_Ended`: the generation of its slot is 0 after the close.
- **P20**: the record gives the amounts of a budget only when the handle of the caller has the right Read, and the state of a program only when the handle has Read: the operations that read them need this right. The rule for each record: it gives no fact of another program, or of the machine, that the status and the facts of the caller do not already give. Reviewed on 2026-11-10, in `kernel/diagnose.odin`:
  - `Handle_Give` with `No_Slot`: the table of the target is full. It is the one cause of this status; the record adds the handle of the caller and a constant capacity.
  - A full table of the machine (memory objects, programs, budgets, message interrupts): the kernel names it only when the handle table of the caller has a free place, which the caller can count, and only for an operation where that table is the one cause that the status leaves. `Thread_Create` and `Program_Start` can fail on two tables of the machine (memory objects, threads): which one is full is a fact of the machine that the status does not give, so the record is `Refused`. The control lock is taken only for `Program_Create`, `Budget_Create` and `Device_Create`. The record adds a constant capacity, never a count of what other programs hold.
  - The log limit: the counts of the budget that paid for the program, only when the program holds that budget with Read (else `Budget_Hidden`). A budget above it is never described.
  - `No_Target`: one sentence for "no other program" and "two other programs": the record does not say which.
  - A program state (`State`) and a budget (`Budget`): only with Read.
  The storage service: a full disk (no place for one more store, no free block) is one record with no number; a full store (48 objects) is a fact of the store of the caller. The stack trace of a call host: the reader holds the program handle with Read, the right of `Program_State`, and the trace holds addresses and modules of that program only.
- **Cost**: on failure only. Measured by the program `errors`: see `FIRST_MILESTONE.md`.

**An export.** An export that can fail declares an error record: its last parameter is `error: ^errors.Error_Record`. The description has the index of the record description in `Function.error_record`.

- **Direct call**: one more argument, after the buffer of a result: the address of an error record of the caller.
- **Isolated call**: one more field of the argument record, after the field of a result: the offset of 56 bytes in the call region. The receiver gives the export the address of that place: the export only writes it, so no copy is needed. `isolated.encode` writes zero bytes there.
- **When**: the export writes the record when it fails, and only then. It fails when its integer result is negative. An export with a Record result has no integer result and no error record.
- **Documentation**: the text of the export names its error kinds: `manual` shows them.
- **Replacement**: the check of a replacement compares the error records of the two descriptions (`Difference.Error_Record`).
- **A service**: the storage service, the information functions of `manual` and the exports of `monitor` give it. The client library `support/storage` gives it to its program.

**The loader.** `module.Load_Error` stays. It is the same form of answer: a record of values and fixed texts that the caller owns, with no pointer, zero for no error. It is larger (288 bytes): it names modules by hash and by name, and the caller of a call host does not have these names. To fit 56 bytes it loses the names. `system.load_error_text` makes its sentences.

**A ring completion.** Asked on 2026-11-11 (the coordinator: "is there an error record form for ring completions?"). Yes, the form of the kernel: a completion record (`contract/ring`) has the status of the contract of its ring in its kind, and when that status is not 0, its seven values are an error record (`errors.completion_record`, `errors.ring_fail`). `operation` is the command; `argument` is the number of the value of the command, from 1, or 0 for the command as a whole. Each contract of a ring names its commands and their values for the sentence (`block.command_name`, `block.argument_name`, the same in `frame` and `datagram`, `datagram.control_name`, `system.root_command_name`), and `system.ring_error_text` writes it: "block.Read: the argument first reaches 8193 blocks, past the end: there are 8192 blocks". The status stays the fast answer: a completion that succeeds writes its results in the same values, as before.

- **Why the values of the completion, and not memory of the caller**: a completion is already 56 bytes of values that the receiver writes and the caller owns, as the completion of the kernel. One more place would be one more copy, and the address of a place of the caller means nothing in the receiver.
- **Why the record replaces the values of choice 199** (`FIRST_MILESTONE.md`): the network service gave the detail of a refusal in values with a layout for each status. The detail is now in the one form that `system.ring_error_text` and any program read. A remote and a port are one value (`errors.endpoint_pack`, the unit `Endpoint`). What the record does not hold: the local ports of the endpoint (the caller reads them with Info).
- **The receiver finds the cause after the refusal** where a refusal comes from several procedures (the root service, `refusal` in `programs/root/main.odin`), as `kernel/diagnose.odin` does: it reads the state again, and names a cause only when the state shows it now; else the record is `Refused` with the status.
- **P20**: a record names the argument of the caller and constants of the receiver. A table of the requests in flight of all the endpoints gives its capacity, not its count (`Busy`); the root service names no other program: "no program has this name" is what the status already says.

### The other calls

The calls that gave a status or a bool only, at the review of 2026-11-11, and the error record of each one now. A bool that is an answer, not a failure (an empty queue, no key, a canvas in use), stays a bool. No call keeps a last error in global state: each record is a value of its call, in memory of the caller or in its completion.

| Call | Before | The error record now |
|---|---|---|
| `display.open` (`support/display`) | `ok: bool` | Last parameter `error`. No_Grant `Display` (no ring to the compositor); Bad_Value of `width` or `height` (1 to 2048); Too_Long of `title` (31 bytes); else the record of the kernel operation that failed (ring, `Memory_Create`, `Memory_Map`, `Handle_Give`). `system.wrapper_error_text` writes "display.open: the argument width has the value 0, which the call refuses; it takes at most 2048" (`errors`, case v) |
| `display.present`, `present_rectangle` | no result | Not changed: a full ring keeps the Present for the next one; the compositor draws the last picture |
| `display.next_event`, `canvas_free`, `wait` | bool, time | Not changed: answers |
| `terminal.open` (`support/terminal`) | `ok: bool` | Last parameter `error`. No_Grant `Terminal`; Bad_Value of the pages of the text region; else the record of the kernel. "terminal.open: the caller has no grant for this: a terminal" (`errors`, case w) |
| `terminal.write`, `line`, `status`, `edit`, `clear`, `key` | no result, bool | Not changed: they wait for room and never fail; `key` false is "no key waits" |
| `system.ring_open` (`support/system`) | Status | Last parameter `error`: the record of `Memory_Size` or `Memory_Map`; Bad_Value of the pages; Malformed for a ring header that `ring.open` refuses |
| `system.send`, `receive` | bool | Not changed: a full or an empty queue is an answer |
| The block ring (`contract/block`, `programs/block`) | Status in the kind | The record in the values. Attach: Busy (requests in flight), Handle_Kind, Handle_Rights, Absent `Region` (not through the ring), Refused. Read, Write: Absent `Region`, Too_Small and Too_Long of `count`, Bad_Value of `place` (not a multiple of 4096), Out_Of_Range of `first` (Blocks) or of `place` (Bytes). The device: Unsupported, Device with its status. An unknown command: Unsupported. `disk` and the storage engine write the sentence |
| The frame ring (`contract/frame`, `programs/frame`) | Status in the kind | The record in the values: the same Attach; Absent `Region`; Out_Of_Range of `place`; Too_Small and Too_Long of `count`; Busy for the Receive places; Device with the length of a frame shorter than its header |
| The datagram ring (`contract/datagram`, `programs/network`) | Status and values of choice 199 | The record in the values: Not_Granted is No_Grant `Endpoint` (the remote of the request, the remote of the grant, the local port of a segment that is not a port of the endpoint); Too_Large is Too_Long; Out_Of_Range; No_Region is Absent `Region`; No_Answer; Link_Down; Busy (the capacity only); Bad_Command is Too_Small of a segment or Unsupported. "datagram.Send: the argument address, 10.0.2.2 port 9, is refused: the grant names 10.0.2.2 port 7 only" (`net`, `fetch`) |
| The control ring of the network service | Status in the kind | The record in the values: Bad_Value of a listen port in use, Full of the endpoints, the record of the region or of the ring, Absent of the ring, Bad_Value of a grant of another form. The root service writes the sentence on the log |
| `start`, `stop`, `connect`, `revoke` of the console (the root ring) | Status in the kind; the console guessed a text | The record in the values (`refusal` in the root service). Start: Absent `Modules`, Reserved (a program of the system). Stop: Absent `Programs`, Reserved. Connect: No_Grant `Connection`, Absent `Services`, Full of the connections. Revoke: Absent `Programs`, Bad_Value of `grant`, Absent `Grants`. Also Disconnect, Grants, Replace. The console writes "root.Stop: the argument name names a program of the system: ..." (`errors`, case x, for Connect) |
| `paint.line`, `paint.write` | no result: a wrong color was taken modulo 6, a place off the paper was dropped | Integer result and `error`: Bad_Value of `color` (0 to 5), of `x` (0 to 480), of `y` (0 to 320). "paint.line: the argument color has the value 9, which the call refuses; it takes at most 5" |
| `tally.add` | the count; a long note was cut | `error`: Too_Long of `note` (36 bytes), Too_Small of `amount` (the count never goes below 0, so a negative result is a failure), Bad_Value past the largest integer. "tally.add: the argument note has 40 bytes; it can have at most 36 bytes" (`errors`, case y) |
| `network.admitted_add`, `neighbor_find` and the tables of `support/network` | bool | Not changed: procedures inside the network service, whose refusals reach the caller as the records above |

### A fault: the stack trace

Rule 8 below requires frame pointers. The kernel walks them when a thread faults:

- Frame 0 is the instruction. For each next frame, `rbp` names 16 bytes of the stack: the `rbp` of the caller, then the return address. The walk stops at 16 frames, or at an `rbp` that is 0, not aligned on 8, not above the one before, or not memory of the program that it can read.
- Each frame of the stop report (`op.Stop_Frame`) has the address, and the base and the hash of the module record that holds it. A reader gives "module + offset".
- **Names of functions**: the module names its exports only. The names of the other functions are debug information, in a separate object (decision 5 below), which the system does not load yet. The kernel tool names each function from the linked file of the module (`build/modules/<name>/linked.elf`, where an offset is the address): the machine test checks the frames of `fault` this way.
- **Frame pointers**: Odin with `-o:speed` keeps no frame pointer in about half of the functions. The kernel tool now compiles each module in two steps: Odin writes LLVM IR, and `llc` of the same LLVM (18) compiles it with `--frame-pointer=all`. The cost is in `FIRST_MILESTONE.md`.
- **One source, one module** (property 11): the Odin compiler runs with `-thread-count:1`, and the flake patches the compiler so that this gives one thread (`tools/odin_compiler/thread_count_counts_the_main_thread.patch`, choice 400 of `FIRST_MILESTONE.md`). The stock compiler starts a second thread, and two threads change the order in which it checks the declarations, so a rare build gives other code. `kerneltool check` builds everything a second time and compares each module, its LLVM IR and its object, and the boot program.

### What the records do not explain

- The kernel finds the record after the operation, from the operation table: an operation that refuses for a reason that the table does not know gives `Refused` with the status.
- A record holds one failure: the first argument that is wrong.
- The record of an isolated call comes from another program: the caller checks the kind and the unit, and cannot prove the values.
- The stack trace has 16 frames at most, and a function that does not keep `rbp` (code that is not built by the kernel tool) cuts it.

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
8. **No unwinding. Frame pointers are required.** No exception crosses a module boundary. An error is a status value. A fault stops the program. Every module keeps frame pointers (`rbp` on x86-64), so that a debugger or a profiler walks the stack with no tables. The owner confirmed and widened this rule on 2026-11-10: no contract of the system uses an exception to tell an error. An exception makes a program fail at a place that the code does not show, and it needs a runtime that unwinds the stack to give the explanation. The system needs no such runtime. A language can have exceptions inside its own module, with its own runtime in that module: the system does not control that, and does not serve it. To read the stack is not forbidden: after a fault, a tool walks the frame pointers and names the calls, and no code of the program runs for that. Since 2026-11-10 the kernel tool builds each module with frame pointers, and the kernel walks them into the stop report (section 8).
9. **The kernel is a module.** The boot program contains the loader and loads the kernel as a module. The hash of the kernel module is the value that the TPM measures (P17).

## Open questions

1. **Initial data of a merged module.** Rule 3 gives each program one copy of the data of each module. The merge tool must keep this true when it merges two modules that both have data.
2. **Description tables.** Version 1 of the format has one function record per export: name, help text, up to 6 parameter types, result type. The types are `Integer` and `Text` only (`contract/module/format.odin`). The type, field and parameter tables are not yet specified at the level of bytes.
