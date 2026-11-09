# RAD Linker and RDI study

Status: research note, 2026-11-09.

This note answers two questions from `MODULE_CONTRACT.md` (section 7 and decision 5):

1. Can the project adapt the RAD Linker to write the module format?
2. Can RDI be the debug information format of modules?

## Method and sources

- Source: `https://github.com/EpicGamesExt/raddebugger`, shallow clone, commit `5b0d5f67` of 2026-11-04.
- The clone was read only. Nothing from it was built or run.
- A path with no URL is a path in that repository.
- Line counts come from `wc -l` on all `.c`, `.h` and `.mdesk` files of a folder, recursive. They include comments and blank lines.
- UNVERIFIED marks a statement that no file or page confirmed.

## 1. Licence

- The `LICENSE` file is the MIT licence text, with "Copyright (c) Epic Games Tools". The file does not print the name "MIT".
- Each source file names it: "Licensed under the MIT license" (`src/lib_rdi/rdi.h:2`, `src/linker/thread_pool/thread_pool.h:2`).
- It is compatible with an MIT project. The project must keep the copyright notice and the permission notice in copies.
- `src/third_party` (96 929 lines) holds other code, for example BLAKE3 and radsort. Their licences are UNVERIFIED.
- An optional input compression path uses the Oodle SDK, which is not in the repository (`build.sh`, "Set up Oodle SDK"). The linker builds without it.

## 2. Size, language, build

### Line counts

| Folder | Lines | Role |
|---|---|---|
| `src/linker` | 46 046 | The linker. 11 294 of these are `tests/linker_tests.c`. 34 752 without tests |
| `src/linker/lnk.c` | 7 768 | Main file: inputs, symbol resolution, layout, image, entry point |
| `src/linker/lnk_debug_info.c` | 3 995 | CodeView merge, PDB and RDI output |
| `src/linker/pdb_ext` | 4 849 | PDB and MSF builders |
| `src/linker/lnk_config.c` | 3 361 | MSVC command line switches |
| `src/base` | 12 034 | Arenas, strings, threads, files |
| `src/linux` | 9 308 | Linux layer. `linux/base` is 2 270 lines |
| `src/win32` | 10 659 | Windows layer |
| `src/coff` | 5 176 | COFF parser, object writer, archive writer |
| `src/pe` | 5 014 | PE structures, import table, export table, debug directory |
| `src/codeview` | 7 890 | CodeView parser |
| `src/pdb` + `src/msf` | 2 379 | PDB and MSF parsers |
| `src/rdi` + `src/rdi_make` | 7 198 | Local wrappers of the RDI libraries |
| `src/rdi_from_codeview` + `rdi_from_pdb` + `rdi_from_coff` | 6 531 | Converters to RDI |
| `src/compression`, `src/msvc_crt`, `src/arch`, `src/llvm` | 2 697 | Small layers |
| `src/dwarf` | 10 845 | Only two headers and `dwarf_x64.c` are included |

- The include list is in `src/linker/lnk.c:15-136`.
- The linker and its layers are about 100 000 lines in one compilation.

### Language and build

- Language: C. The build is a unity build: one compiler call on `src/linker/lnk.c`, which includes every other file.
- Linux: `./build.sh radlink release` (`build.sh`, section "Build Everything"; `README.md`, "Linux x64"). It uses clang or gcc, and links `-lpthread -lm -lrt -ldl` and a BLAKE3 archive.
- The build first compiles and runs a code generator, `metagen` (`build.sh`, "Build & Run Metaprogram").
- Windows: `build radlink release` (`build.bat:201`).

### Linux state

- `build.sh` has a `radlink` target. `run_tests.sh:5` lists `radlink` as a test target.
- The linker has Linux code paths: `src/linker/lnk_io.c:124` (`#elif OS_LINUX`), `lnk_cmd_line.h:29`, `lnk_config.h:33`.
- The README says: "We are working on a Linux port of the linker". It gives no completion state.
- The output is PE only on every host. A Linux build is a cross linker.
- UNVERIFIED: that the linker builds and passes its tests on Linux today. This study did not build it.

## 3. Inputs and outputs

- Machine: x64, with partial x86. The switch is `/MACHINE:{X64|X86}` (`lnk_config.c:43`). Relocation patching reports "not implemented" for other machines (`lnk_resolve_reloc_value`, `lnk_obj.c`).
- Object inputs: COFF objects and COFF "big" objects (`COFF_DataType_Obj`, `COFF_DataType_BigObj`, `src/coff/coff_parse.h:157-160`).
- Archive inputs: regular and thin `.lib` archives (`COFF_Archive_Regular`, `COFF_Archive_Thin`, `coff_parse.h:165-167`).
- Import inputs: short import members of an import library (`COFF_DataType_Import`).
- Other inputs: `.res` resource files and manifests (`lnk.c:2608`), and a compressed object container, RADCOBJ (`src/linker/radcobj.h`).
- ELF input: none. The linker does not include `src/elf`. `src/elf` (1 813 lines) is a parser for the debugger.
- ELF output: none. The title is "RAD PE/COFF Linker" (`lnk.c:7`).
- Link-time optimization: none. The README says: "We don't yet have support for link-time-optimizations". `llvm_is_bitcode` is declared (`src/llvm/llvm.h`) and the linker does not call it.
- Outputs: PE image, PDB, RDI, import library, map file (`lnk_run_linker`, `lnk.c:6901`).

## 4. Architecture

### Stages

All names are in `src/linker/lnk.c` unless a file is given.

| Stage | Function | Notes |
|---|---|---|
| Configuration | `lnk_config.c` | MSVC switches |
| Input load | `lnk_load_inputs` (1451), `lnk_inputer_flush` (1054) | Inputs are memory maps (`lnk_io.c:183`) |
| Object parse | `lnk_obj.c` | One task per object |
| Symbol resolution | `lnk_link_inputs` (2121), `lnk_symbol_table.c` | Archive members are pulled until no symbol is undefined |
| Imports and exports | `lnk_link_image` (2400) | The linker generates COFF objects for the import table and the export table, then links them as inputs |
| Unused section removal | `lnk_opt_ref` (3354) | `/OPT:REF` |
| Identical code folding | `lnk_opt_icf` (4268) | `/OPT:ICF` |
| Section layout | `lnk_build_image` (5994) | Gather, sort, merge, assign offsets |
| Base relocations | `lnk_build_base_relocs` (5653) | Writes the PE `.reloc` block form |
| Header | `lnk_build_win32_header` (5746) | DOS header, PE header, section table |
| Fill | `lnk_image_fill_task` | Copies section data into one buffer |
| Relocation patch | `lnk_obj_reloc_patcher` (4931), `lnk_resolve_reloc_value` (`lnk_obj.c`) | One task per object |
| Directory patch | End of `lnk_build_image` (6340-6560) | Load config, exceptions, export, relocs, import, TLS, debug, resources, checksum, GUID |
| File write | `lnk_background_file_writer_*` | The image is one buffer, written in the background |
| Debug information | `lnk_build_pdb`, `lnk_p2r_worker` | After the image |

### Parallel model

- One thread pool: `src/linker/thread_pool/thread_pool.c` (294 lines).
- The only primitive is a parallel loop, `tp_for_parallel(pool, arena, task_count, func, data)`.
- Workers take the next task index from one atomic counter (`tp_run_tasks`, `thread_pool.c:17`). There is no work stealing and no task graph.
- A stage is a sequence of parallel loops, with barriers between them.
- Results are merged per worker: each worker fills its own list or hash table, and a serial step joins them (example: `lnk_build_base_relocs`).
- The default worker count is the core count. `/rad_workers` limits it (README).

### Memory model

- Arenas only. `TP_Arena` is one arena per worker (`thread_pool.h:11`).
- Temporary data uses scratch arenas with `temp_begin` and `temp_end`.
- Debug information uses one separate "huge" arena (`lnk_get_huge_arena`, `lnk.c:6998`).
- Nothing is freed during the link. A "fast exit" mode returns from a parent process while a child releases memory (`lnk.c:7604`).

### Where the output is written

- The PE image is built in `lnk_build_image` (`lnk.c:5994-6570`, about 580 lines) and its helpers.
- PE-specific helpers: `lnk_build_win32_header`, `lnk_build_base_relocs`, `pe_make_import_dll_obj_static` (`src/pe/pe_make_import_table.c`), `pe_make_edata_obj` (`src/pe/pe_make_export_table.c`).

### Isolation of the output stage

The output stage is not isolated. PE and COFF structures are the working data of the whole linker:

- Layout stores its result in the COFF section headers of each input object (`lnk_patch_virtual_offsets_and_sizes_in_obj_section_headers_task`, 5371).
- The image header is a section contribution like any other (`.rad_linker_image_header_section`, `lnk.c:6255`).
- The relocation patcher reads the image base and the section table back from the finished PE header (`pe_bin_info_from_data`, `lnk.c:6343`).
- The import table and the export table are generated as COFF objects with named symbols (`__imp_`, `__IMPORT_DESCRIPTOR_`, `__NULL_IMPORT_DESCRIPTOR`). The directory patch finds them by name.
- The PDB builder and the map writer take the PE image buffer as input.

### What a module writer must change

| Module part | Present code | Change |
|---|---|---|
| (a) Segments table | `lnk_build_win32_header` writes the PE section table from `LNK_SectionArray` | Write a new header and directory from the same array. Merge sections into three segments by protection. About 200 lines |
| (b) Slots bound by (module hash, export index) | `lnk_load_inputs` (1548-1615) reads short imports: DLL name, function name, ordinal. `pe_make_import_dll_obj_static` writes the PE import table and one 8-byte slot per import | Keep the slot symbols (`__imp_<name>`). Replace the PE descriptors with two tables: imports (hash) and slots (import index, export index). About 300 lines |
| (c) Rebase table | `lnk_gather_base_reloc_pages_task` (5489) collects each `ADDR64` location. `lnk_serialize_base_reloc_pages_task` (5590) writes PE blocks | Keep the gather. Replace the serializer with a RELR encoder. About 100 lines |
| (d) Export table | `lnk_resolved_exports_from_config` (2361), `pe_finalize_export_list`, `pe_make_edata_obj` | Write records (code offset, function description index) in place of the PE export directory. About 150 lines |
| Directory patch | `lnk.c:6340-6560` | Remove the PE directories. Keep the relocation patch |
| Debug information | `lnk_build_pdb`, `lnk_p2r_worker` take the PE image | Give them a section table without a PE header. Size UNVERIFIED |

- Estimate for a writer inside the linker: 800 to 1 500 new lines, plus edits in `lnk_build_image`, `lnk_link_image` and `lnk_run_linker`.
- The cost is the fork. `src/linker` received 30 commits between 2026-10-27 and 2026-11-02 (GitHub API, `commits?path=src/linker`). A fork of `lnk.c` must follow that rate.
- The module merge of `MODULE_CONTRACT.md` section 3 has no base here. The linker has no relaxation pass that rewrites a call through a slot into a direct call.

### An alternative with no change to the linker

A PE image already holds the four parts:

| Module part | PE part |
|---|---|
| Segments | Section table |
| Import of a module by hash | One import descriptor. Its DLL name is the hash as text |
| Slot (import, export index) | One import address table entry, imported by ordinal |
| Rebases | `.reloc` entries of kind `DIR64` |
| Exports | Export directory, by ordinal |

- A converter reads the PE image and writes a module. This is the same plan as the ELF converter of `MODULE_CONTRACT.md` section 7, with PE as the build-time format.
- The build tool writes one import library per module. `pe_make_import_lib` shows the form (called in `lnk_run_linker`, `lnk.c`).
- Limit: a PE ordinal is 16 bits (`hint_or_ordinal` in `COFF_ShortImport`). A module can then export at most 65 535 functions.
- Estimate: 400 to 700 lines of Odin for the converter, and 150 lines for the import library writer.

## 5. COFF x64 relocations and position-independent code

### Types handled

From `coff_pick_reloc_value_x64` (`src/coff/coff.c:219`):

| Type | Handled | Value |
|---|---|---|
| `IMAGE_REL_AMD64_ABSOLUTE` | Yes | No operation |
| `ADDR64` | Yes | Address. Produces a `DIR64` base relocation |
| `ADDR32` | Yes | 32-bit address. Produces a `HIGHLOW` base relocation. It is an error with large addresses (`lnk.c:5512`) |
| `ADDR32NB` | Yes | Offset from the image base. No base relocation |
| `REL32`, `REL32_1` to `REL32_5` | Yes | Offset from the instruction. No base relocation |
| `SECTION`, `SECREL` | Yes | Section number, offset in section. Used by debug information and thread-local data |
| `SECREL7`, `TOKEN`, `SREL32`, `PAIR`, `SSPAN32` | No | `NotImplemented` |

### Calls between images

- The compiler emits one of two forms for a function of another image.
- Form 1, declared as an import: `call qword ptr [rip + __imp_f]`, with a `REL32` relocation to the slot symbol `__imp_f`. This is `call [rip+slot]`.
- Form 2, not declared as an import: `call f`, with a `REL32` relocation to `f`. The linker then adds a thunk `jmp [rip + __imp_f]` (bytes `FF 25`, `pe_make_indirect_jump_thunk_x64`, `src/pe/pe_make_import_table.c:39`).
- The linker makes the thunk only when a reference needs it (`make_jump_thunk`, `lnk.c:1611`, `lnk_obj.c:548`; `CHANGELOG.md:486`).
- The slots are the import address table: one 8-byte entry per imported function, in a data section.
- The loader writes the slots only. No name lookup occurs when the import is by ordinal.

### Base relocations that remain

- Only `ADDR64` and `ADDR32` produce a base relocation (`coff_is_addr_reloc`, `coff.c:135`).
- x64 code reaches data and functions of its own image with `REL32`. These need no base relocation.
- `DIR64` entries come from addresses stored in data: tables of function addresses, addresses in initialized records.
- UNVERIFIED: that Odin and clang emit no `ADDR64` in a code section on a COFF x64 target. The large code model does emit them.

### Is this sufficient for the module design

- Yes for the loader rules. Slots and `DIR64` rebases map to "bind" and "rebase", and both are in data.
- The converter or the linker must reject a module with a base relocation inside an execute segment. This check enforces "code pages are never written".
- The linker has no interposition, no lazy binding by default, and no symbol search at load. This matches section 2 of the contract.
- Form 2 adds a thunk and one more jump. The project must make every compiler emit form 1. In C this is `__declspec(dllimport)`. For Odin the method is UNVERIFIED.

### Costs of the COFF target that the contract does not list

- **Calling convention**: A COFF x64 target uses the Windows x64 convention by default: 4 register parameters and a reserved stack area. The contract requires the System V assignment (section 4). Each export and each import then needs an explicit System V attribute. Its availability in Odin on this target is UNVERIFIED.
- **Unwinding**: COFF uses `.pdata` and `.xdata` tables, not `.eh_frame`. The linker sorts `.pdata` (`lnk.c:6370`).
- **Thread-local data**: COFF uses the `_tls_used` record and `SECREL` offsets (`lnk.c:6421`). The loader must implement the Windows model or forbid thread-local data.
- **Stack probes**: A COFF target calls `__chkstk` for large frames. The module must supply it. UNVERIFIED for Odin `freestanding_amd64_win64`.
- **ARM64**: The linker has no ARM64 relocation code. RDI has no ARM64 value (`RDI_Arch`: `X64`, `X86`, `src/lib_rdi/rdi.h:583`).

## 6. Performance

### Claims

- "In our test cases (where debug info is multiple gigabytes), we see 50% faster link times" (README).
- Large memory pages "reduce link time by another 25%", with `/rad_large_pages` (README). The README says that large pages are unreliable on Windows.
- The README shows one benchmark image, on a 64-core Threadripper with Windows. The numbers are in an image and are UNVERIFIED here.
- The stated use case is the compile and debug cycle of very large programs. Small links are not the target.

### Techniques in the source

- Every stage is a set of parallel loops over objects, sections or pages (`tp_for_parallel`, over 40 task functions in `lnk.c`).
- Inputs are memory maps, read in parallel (`lnk_io.c:183`; `CHANGELOG.md:474`).
- Arenas per worker remove allocator locks.
- Radix sort for section contributions (`lnk_sort_contribs_chunk_radix`, `lnk.c:4655`) and radsort elsewhere.
- Lock-free structures: `lf_hash_table.c`, atomic list operations (`lnk_reloc_ref_batch_list_pop_atomic`).
- BLAKE3 in parallel for the image hash and for type deduplication (`lnk_blake3_hash_parallel`, `lnk.c:183`).
- The image and the PDB are written by a background writer while the link continues.
- The process can exit without releasing memory (`/RAD_FAST_EXIT`, off by default).
- Recent commits improve data locality in the PDB stages ("group stage TPI and IPI stream build steps to improve data locality").
- Most of the measured gain is in debug information. For a module of the project, with small inputs, the gain over `lld` is UNVERIFIED.

## 7. The RDI format

### Structure

From `src/lib_rdi/rdi.h` (1 485 lines):

- **Header** (`RDI_Header`, line 1146): `magic` (u64, "raddbg\0\0"), `encoding_version` (u32), `data_section_off` (u32), `data_section_count` (u32).
- **Version**: one number for the whole format. `RDI_ENCODING_VERSION` is 23 (line 70).
- **Section table**: an array of `RDI_Section` (line 1155), 32 bytes each: `encoding`, `pad`, `off`, `encoded_size`, `unpacked_size`.
- The position in the section table is the section kind. Position 0 is the null kind.
- A section has no record size field. The reader takes the record size from a compiled table, `rdi_section_element_size_table[44]` (`src/lib_rdi/rdi.c:13`).
- A section can be compressed: `encoding` is `Unpacked` or `LZB`.

### Tables

43 section kinds (`RDI_SectionKind_XList`, line 523). Sizes below are computed from the field lists, not measured with a compiler.

| Group | Sections | Record |
|---|---|---|
| Top | `TopLevelInfo` | Architecture, name, hash, GUID |
| Strings | `StringData`, `StringTable` | Bytes; u32 offsets |
| Index lists | `IndexRuns` | u32 |
| Image | `BinarySections` | Name, flags, address range, file range |
| Sources | `FilePathNodes` (20 bytes), `SourceFiles`, checksums, `Timestamps` | A tree of path parts |
| Lines | `LineTables` (20), `LineInfoVOffs` (u64), `LineInfoLines` (8), `LineInfoColumns` (4) | Parallel arrays, sorted by address |
| Source to address | `SourceLineMaps` (20) and three arrays | The reverse map |
| Units | `Units`, `UnitVMap` (16) | One compilation unit |
| Types | `TypeNodes`, `UDTs`, `Members`, `EnumMembers` (16) | See below |
| Scopes | `Scopes` (36), `ScopeVOffData` (u64), `ScopeVMap` (16), `InlineSites` (16) | A tree by indices |
| Symbols | `GlobalVariables`, `ThreadVariables`, `Constants`, `Procedures`, `LocalVariables` | All use `RDI_Symbol` |
| Locations | `LocationsBytecodeData`, `LocationsConstantData`, `LocationsSetElements` (24) | Byte streams and a table |
| Names | `NameMaps` (16), `NameMapBuckets` (8), `NameMapNodes` (12) | Hash tables stored in the file |
| Address maps | `UnitVMap`, `ScopeVMap`, `GlobalVMap` | Sorted (address, index) pairs for binary search |

### Strings and indices

- A string is a u32 index into `StringTable`. `StringTable` holds u32 offsets into `StringData`. The length is the difference to the next offset (`rdi_string_from_idx`, `src/lib_rdi/rdi_parse.c:341`). No terminator.
- A reference between tables is a u32 index. A child list is a pair (first index, count), for example `member_first`, `member_count` in `RDI_UDT`.
- A variable list of indices is a run in `IndexRuns`, for example the parameters of a function type (`param_idx_run_first`).
- **Index 0 is nil.** A lookup that finds nothing returns index 0 (`rdi_procedure_from_name`, `rdi_parse.c:743`). An index out of range returns a static all-zero record (`rdi_nil_element_union`, `rdi_parse.h:160`, `rdi_parse.c:232`). A reader never receives a null address.
- This is the ZII rule of the project (P13).

### Types

- `RDI_TypeNode` (line 1269): `kind`, `flags`, `byte_size`, then a union selected by the kind.
- Built-in: a name. Constructed (pointer, array, function, modifier): `direct_type_idx`, `count`, and a parameter run. User-defined: name, `udt_idx`. Bit-field: offset and size.
- `RDI_UDT`: the member range, the source location, the container.
- `RDI_Member`: `kind`, `name_string_idx`, `type_idx`, `off`. Kinds include data field, method, base, virtual base.
- 59 type kinds. Many are for C and C++: `Class`, `LRef`, `RRef`, `MemberPtr`, `Method`, `HResult`, `F80`, complex and decimal floats.
- Languages: `C`, `CPlusPlus`, `Masm` only (`RDI_Language_XList`, line 768).

### Procedures, scopes, locals, lines

- A procedure is an `RDI_Symbol`: name, flags, `location`, container, `type_idx`, `root_scope_idx`, link name.
- `RDI_Location` is a u64 with the kind in the top 8 bits (line 1108). Kinds: register plus offset, register, module offset, thread-local offset, constant data, bytecode stream, set.
- A set gives a different location per address range (`RDI_LocationSetElement`).
- The bytecode is a stack machine with 54 operations (`rdi_eval_op_ctrlbits_table[54]`).
- `RDI_Scope`: procedure, parent, first child, next sibling, a range into `ScopeVOffData`, a range of locals, an inline site.
- A local is an `RDI_Symbol` in `LocalVariables`.
- Line information is three parallel arrays per line table: addresses, (file, line) pairs, columns.

### Is it "flat tables of fixed-size records"

- Yes for 38 of the 43 kinds. Each is an array of one fixed-size record or one integer, and all references are indices.
- The 5 exceptions are streams with variable-length items: `StringData`, `IndexRuns`, `ScopeVOffData`, `LocationsBytecodeData`, `LocationsConstantData`.
- `RDI_TypeNode` has a fixed size and a union. Its meaning depends on `kind`.
- Three differences from the flat tables of the project:
  1. The record size is not in the file. A table cannot gain a field without a new format version.
  2. One version number covers all tables. A reader of version 23 cannot read version 24. There are no feature bits.
  3. A section can be compressed. A reader must then decompress before it can index.
- The README says: "The RDI format is currently specified in code". There is no written specification and no stability promise.

### Size and independence

- `src/lib_rdi`: 4 588 lines. `rdi.h` and `rdi.c` are 1 838 lines. The parser is 2 750 lines.
- `src/lib_rdi_make`: 3 611 lines. The README calls it "in-progress".
- `lib_rdi` does not depend on `base`. The README says that it "can be independently relocated to other codebases". It includes only `stdint.h`.
- `rdi.h` is generated from `src/rdi/rdi.mdesk` (1 571 lines) by `metagen`.

### Converters

| Converter | Lines | State |
|---|---|---|
| `rdi_from_pdb` + `rdi_from_codeview` | 6 446 | The main path. The debugger and the linker both use it |
| `rdi_from_dwarf` | 4 608 | Present, with a test file. 22 `TODO` or `NotImplemented` marks. The changelog reports that type deduplication from DWARF is "not working correctly" (`CHANGELOG.md`, v0.9.29, issue 959) |
| `rdi_from_elf` | 45 | Section table only. It has no symbols and no types |
| `rdi_from_coff` | 85 | Section table only |

- The tool is `radbin`: `./build.sh radbin` (`src/radbin/radbin.c`, 1 635 lines). It accepts PE, COFF, PDB, ELF and RDI inputs.
- For an ELF input, `radbin` reads DWARF and uses `rdi_from_dwarf` (`radbin.c:722-732`). It also reads DWARF inside a PE or COFF file.
- The linker writes RDI from its own PDB: it builds the PDB, then runs the PDB converter (`lnk_p2r_worker`, `lnk.c:7024-7033`). RDI output is selected by `config->rad_debug`.

### Which Odin path gives RDI today

| Odin target | Debug information | Path to RDI | State |
|---|---|---|---|
| COFF | CodeView in objects, PDB from the linker | PDB to RDI with `radbin`, or directly from the RAD Linker | The main, tested path of the RAD project |
| ELF | DWARF | `radbin` on the ELF file | Works in the "preliminary" Linux support of v0.9.29, with known defects |

- UNVERIFIED: the quality of the RDI that either path produces from Odin output. Odin types (slices, strings, unions, `any`) map to C-like records in both formats.
- `RDI_Language` has no value for Odin.
- The address fields are offsets from the image base (`voff`). A module converter that keeps the segment layout of the linked image keeps them valid. A converter that moves segments must rewrite the RDI file.

## 8. RDI and the description tables

The description tables of the contract are: types, fields, functions, parameters, strings.

| Description table | RDI table | Fit |
|---|---|---|
| Strings | `StringData` + `StringTable` | Same idea. RDI adds one indirection |
| Types | `TypeNodes` + `UDTs` | RDI has kind and size. It has no alignment. It has no slice, string, handle, variant, optional or flags kind |
| Fields | `Members` | Same fields: name, type, offset |
| Functions | `Procedures` + a `Function` type node | RDI has no export index, no help text, no flags |
| Parameters | None | RDI has no console data: required, allowed values, completion source |

Reasons against one shared set of tables:

- **Different owner.** RDI changes when the debugger needs it. The version was 23 at the time of this study. The description tables are a contract of the system and must change by added fields only.
- **Different identity.** The contract puts debug information in a separate object named by hash. The description tables are in the module, and the loader and the console read them. A console must not need the debug object.
- **Different content.** RDI describes every type and every local of the code. The description tables describe exports only.
- **Missing concepts.** Handles with rights, slices, variants and console data do not exist in RDI. Adding them means a fork of the format.
- **No growth rule.** RDI has no record size in the file (section 7).

Result: RDI is debug-only for this project. The description tables stay a format of the project.

What the project can take from RDI is the design, which it already shares: nil at index 0, (first, count) ranges, u32 indices, sorted address maps, and name maps stored as hash tables in the file.

## 9. Risks

- **Maturity**: The releases are named alpha (`CHANGELOG.md`: "v0.9.29-alpha"). The README says: "The debugger is currently in *ALPHA*".
- **Activity**: High. 30 commits in `src/linker` in 7 days. Many recent commits add bounds checks for corrupted input.
- **Stability of RDI**: None promised. Version 23, specified in code only.
- **Windows-centric linker**: The command line is MSVC. Entry point search, subsystems, manifests, resources, load config, guard tables, delay imports and the default libraries of the MSVC runtime are all in `lnk.c`. A module build must disable each one.
- **Linux**: The linker port is "in progress". The Linux debugger support is "preliminary".
- **One machine**: x64 only in the linker and in RDI. A second architecture needs work in both.
- **Coupling**: The output writer is not a separate stage (section 4). The debug path takes a PE image.
- **Debug path depends on PDB**: The linker makes RDI from the PDB that it builds. An RDI-only output still runs the PDB builder.
- **Build**: The unity build needs a generator step and the base layer. This does not fit the rule "automation is a command of the Odin tool" without a wrapper that calls a C compiler.
- **COFF target**: Windows calling convention by default, `.pdata` unwinding, Windows thread-local model (section 5).
- **No blocker in the licence.**

## Recommendation

- **Linker: do not adapt now.** Use the RAD Linker unchanged, as a candidate next to `lld`. Do not fork `lnk.c`: the output stage is not isolated and the file changes about 30 times a week.
- **Linker, format bridge**: Write the module converter so that its input is a linked image, PE or ELF. PE maps one-to-one: sections, import table by ordinal, `DIR64` entries, export directory.
- **Linker, first experiment**: Odin object for `freestanding_amd64_win64`, linked with `lld-link` (already available), then read the PE: count `DIR64` entries in code sections (must be 0), and confirm the call form `FF 15`. This needs no RAD code. About 150 lines of Odin.
- **Linker, second experiment**: Build `radlink` on Linux in a sandbox, link the same objects, compare the image with `lld-link` and measure the time. Adopt `radlink` only if it passes and is faster on the project's inputs.
- **Decide the target first**: The COFF path brings the Windows convention, `.pdata` and the Windows thread-local model. Verify that Odin can emit System V exports on a COFF target. If not, keep ELF and `lld`.
- **Linker, later**: If the project needs a writer inside a linker (for the merge of section 3), expect 800 to 1 500 lines in a fork, plus the maintenance of the fork.
- **RDI: adopt as the debug format, as an external object named by hash.** Use `lib_rdi` (4 588 lines, MIT, no dependency) unchanged for reading. Record the RDI version next to the hash.
- **RDI, production**: Run `radbin` as a build step on the linked image. With COFF the path is PDB to RDI, the tested one. With ELF the path is DWARF to RDI, which has known defects.
- **RDI, first experiment**: Build `radbin` on Linux, convert one Odin program by both paths, and dump both RDI files. Check procedures, line tables, and one record type. No code to write; one build command in the kernel tool.
- **RDI is not the description tables.** Keep types, fields, functions and parameters as a project format with a record size per table. Reuse the RDI conventions: nil at index 0, (first, count) ranges, u32 indices.
- **Expected code**: converter 400 to 700 lines of Odin, import library writer 150 lines, RDI integration under 100 lines. No C code of the project.
- **Open risks to track**: alpha state, no RDI stability promise, x64 only, Linux port of the linker not finished.
