# Module contract

Status: draft 1, 2026-11-09. Proposal for review by the owner. Nothing here is decided or implemented.

This document proposes the contract between modules: the module format, the loader, the call form, the type description, and the context.
`GLOSSARY.md` defines the terms. `PROPERTIES.md` gives the rules; (P10) points to a property.

The facts come from two research notes, with sources:

- `research_notes/Jonathan Blow OS et kernel data oriented/module_loading_prior_art.md` (cited as [Load §n])
- `research_notes/Jonathan Blow OS et kernel data oriented/interface_types_prior_art.md` (cited as [Types §n])

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

Proposal: every export has one form.

```
status = export(arguments, results)
```

- `arguments` is the address of one record that the caller filled.
- `results` is the address of one record that the caller owns and the callee fills.
- `status` is a 32-bit number. Zero is success.

Reasons:

1. **Language independence**: Two addresses in two registers is a form that every language can produce. The rules for records passed by value differ between the System V and the Windows conventions, and between compilers. This form does not use them. [Types §7]
2. **One description, two paths**: An isolated call puts the same argument record in a command record of a ring, and the same result record in a completion record. A direct call passes the two addresses. No second encoding exists. [Types §3, §4]
3. **Growth**: A new field at the end of the argument record is zero for old callers (ZII). The export does not change. COM needs a new interface for each change. [Types §2]
4. **Console**: The console builds the argument record from the description, and displays the result record from the description.

- **Cost**: A call through this form writes its arguments to memory. For a small function that is called very often, this is slower than registers.
- **Answer to the cost**: This form is for calls between modules. Calls inside a module use any convention. Merge (section 3) can turn a call between modules into a call inside a module.
- **Memory**: The caller owns all memory. The callee never allocates in the caller. For a result of unknown size, the caller gives a buffer with a capacity and receives a count, or receives a handle and reads later. The WebAssembly component model lets the callee allocate, and reports this as a main defect. [Types §1]

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

- It holds no strings that the program must parse, no environment, no names.
- A program reads it with no memory allocator and no library.
- **Prior art**: The `processargs` message of Fuchsia has a fixed header, offsets, and one typed entry per handle. It still carries `argv` and environment strings; this design does not. [Load §6]
- A program that starts with an all-zero context has no handles. It can compute and stop. It can reach nothing (P2).

## 7. How to build modules with existing tools

Proposal: do not write a compiler or a linker.

1. Odin and clang produce normal ELF object files, position-independent.
2. The existing linker (`lld`) links one module into one ELF file.
3. A tool of the project converts that ELF file into a module: it writes the flat tables, converts relocations to rebases and slots, and computes the hash.
4. The description tables come from the source: from Odin type information for Odin, from a small description file for C.

This reuses the compiler, the linker and the debugger formats. The project writes one converter and one loader.

- **ELF is a build-time intermediate format only.** LLVM, which Odin and clang use, writes only ELF, COFF and Mach-O objects. ELF never reaches the running system.
- **Every step is a command of the kernel tool.** No script calls the compiler or the linker directly.

### The linker (direction from the owner, 2026-11-09)

- The project does not write a linker from nothing. It reuses or adapts an existing linker that is well written and fast, and adds the module format as an output.
- **Candidate: the RAD Linker**, from the RAD Debugger project. Verified in its README: it generates x64 PE/COFF binaries only, its command line is compatible with MSVC, it is built for speed on very large programs (50% faster link times in their cases), and a Linux port is in progress. The same repository has layers that parse and write COFF and PE, and that parse ELF. Its licence is not verified here.
- **Fit**: Odin can emit COFF objects (`freestanding_amd64_win64`, checked in this project). So a path exists with no ELF: Odin, COFF objects, an adapted RAD Linker, module. The cost is the weaker position-independent model of COFF; this must be studied before a choice.
- **Other candidates to compare**: `lld` (already in the Nix closure of Odin), `mold` (fast, ELF), `wild` (fast, ELF, Rust).
- **Criteria**: link speed, size of the code to adapt, support for the "call through a slot" sequence, licence.

## Decisions for the owner

1. **Own format, built by conversion from ELF** (section 7). The alternative is to use ELF as the module format and to forbid most of its features.
2. **One call form** with two records (section 4). The alternative is the C convention of the machine with typed parameters in registers. It is faster for small functions, and it needs a second encoding for rings.
3. **Stream as a handle**, not as a type (section 5).
4. **Hash function**: BLAKE3 is proposed. Its licence is not verified here.

## Open questions

1. **Inlining across modules.** A merged module can inline only if the modules carry an intermediate form of the code. This form would become a part of the contract.
2. **Data exports.** This proposal exports functions only. A module that exports a table of data needs a rule.
3. **Module state.** Two programs that map one module share its code. Each program has its own copy of its data. A rule is needed for the initial data of a module that is merged.
4. **Debug information.** The proposal is a separate object, named by hash in the module, so that a module stays small.
5. **Description of nested data.** A record that holds a slice of records that hold slices. The check of all offsets on receipt must have a bounded cost. Cap'n Proto sets a traversal limit. [Types §4]
6. **Kernel operations.** Fuchsia gives each program a kernel-supplied module as the only way to enter the kernel. [Load §6] This fits "a kernel operation is a call to an export". It competes with the kernel ring of `ARCHITECTURE.md` (K4).
7. **Thread-local data and unwinding.** Not studied.
