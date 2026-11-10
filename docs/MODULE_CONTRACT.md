# Module contract

Status: draft 1, 2026-11-09. The owner closed its decisions on 2026-11-09. `module/format.odin` is version 1 of the format at the level of bytes; `FIRST_MILESTONE.md` lists the gaps.

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
4. The loader reads flat tables. SQLite is an index (P12).
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
- **Hash**: The identity of a module is the hash of the whole file. The file contains no reference to its own hash. Imports are hashes, so an import cycle cannot exist. [Load §4]

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
| Fields | One field of a record type: name, type, offset |
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
- **One generic entry routine**: Because every parameter is a scalar, one small routine loads up to 6 integer registers and 8 float registers from two arrays and calls the export. The receiving side of a ring and the console both use it. A library for foreign calls is not needed. It is `export_call` in `system/enter.asm`: 30 instructions.

### The isolated call, as implemented

Status: implemented on 2026-11-10 (`isolated/`, `programs/host`). The owner has not reviewed the choices below.

- **Call host**: The caller starts one program per module: the call host. The call host receives two memory objects: the call ring and the call region. Like each program, it also has its budget and, if the caller gives it, the log. It receives no other handle. The caller maps the file of the module in the call host, read-only, with no handle. The call host checks the file and loads the module.
- **Argument record**: One field per parameter, in order. A scalar is 8 bytes. A parameter that the direct call passes by address is the record itself: a Text is a slice of 16 bytes, `{offset, count}`. The offset is in the call region.
- **Where it travels**: The argument record is in the call region. The command record names it: `kind` is the export index, `values[0]` is the offset of the argument record, `values[1]` is its size. Reason: 6 integers and 8 floats are 112 bytes, and a record of a ring has 56 bytes of values. One place for all argument records needs no second path.
- **Completion record**: `kind` is a status: 0 is success, 1 is "no such export", 2 is "the argument record is not in the call region". `values[0]` and `values[1]` are the integer results; `values[2]` and `values[3]` are the float results.
- **The receiver checks**: The call host reads the types from the description in the module, not from the caller. It copies the argument record to private memory once. It checks the offset and the count of each slice against the size of the call region, with no overflow. Then it calls `export_call`.
- **The caller checks**: The caller reads a bounded number of completion records, and ignores each record whose tag is not the tag of the call.
- **Failure**: A fault in the module stops the call host only. The kernel wakes the caller, which holds the handle of the program. The caller reads the stop code. A call has no time limit. The caller ends a call when it closes the handle: the kernel stops a program that no handle names. The console does this when the person presses Escape. The next call starts a new call host.
- **Tests**: `odin test isolated` has a round trip, the refused cases at each limit, and 200 000 random argument records. The machine test calls a module that reads address 0, that loops with no end, and that tries to stop the machine.

### Growth

- A module imports another module by hash, with an export index. The caller and the callee are always the exact versions that were built together. A direct call cannot meet a changed signature.
- Growth by added fields (ZII) applies where two sides have separate versions: the records of rings between programs and services, and the records that a function receives by address.
- The signature of an export does not change inside one module hash. A new signature is a new module.

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

Now (`kernel/operation/operation.odin`): the context is 16 handles and 16 values of 64 bits. The index of a handle is its role. It has no header and no text. The kernel ring is at a fixed address. For a call host, the caller ring is the call ring (role 0), and the argument records arrive in the call region (role 1).

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
8. **No unwinding. Frame pointers are required.** No exception crosses a module boundary. An error is a status value. A fault stops the program. Every module keeps frame pointers (`rbp` on x86-64), so that a debugger or a profiler walks the stack with no tables.
9. **The kernel is a module.** The boot program contains the loader and loads the kernel as a module. The hash of the kernel module is the value that the TPM measures (P17).

## Open questions

1. **Initial data of a merged module.** Rule 3 gives each program one copy of the data of each module. The merge tool must keep this true when it merges two modules that both have data.
2. **Description tables.** Version 1 of the format has one function record per export: name, help text, up to 6 parameter types, result type. The types are `Integer` and `Text` only (`module/format.odin`). The type, field and parameter tables are not yet specified at the level of bytes.
