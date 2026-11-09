# Type descriptions and call contracts: prior art

Status: research note, 2026-11-09. Sources were fetched on that date unless marked UNVERIFIED.

Each bullet ends with a source key from this table. `UNVERIFIED` marks a fact I did not confirm in a fetched source. "Inference" marks my own deduction from verified facts.

| Key | URL |
|---|---|
| CABI | https://github.com/WebAssembly/component-model/blob/main/design/mvp/CanonicalABI.md |
| WIT | https://github.com/WebAssembly/component-model/blob/main/design/mvp/WIT.md |
| CM1 | https://bytecodealliance.org/articles/the-road-to-component-model-1-0 |
| WASI3 | https://wasi.dev/releases/wasi-p3 |
| WRT | https://learn.microsoft.com/en-us/uwp/winrt-cref/winrt-type-system |
| WINMD | https://learn.microsoft.com/en-us/uwp/winrt-cref/winmd-files |
| HSTR | https://learn.microsoft.com/en-us/windows/win32/winrt/hstring |
| TLB | https://learn.microsoft.com/en-us/windows/win32/midl/com-dcom-and-type-libraries |
| HRES | https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-erref/0642cb2f-2075-4469-918c-4441e69c548a |
| APIC | https://learn.microsoft.com/en-us/windows/uwp/debug-test-perf/version-adaptive-code |
| FWIRE | https://fuchsia.dev/fuchsia-src/reference/fidl/language/wire-format |
| FLANG | https://fuchsia.dev/fuchsia-src/reference/fidl/language/language |
| CAPN | https://capnproto.org/encoding.html |
| CAPNL | https://capnproto.org/language.html |
| FB | https://flatbuffers.dev/internals/ |
| FBE | https://flatbuffers.dev/evolution/ |
| SBE | https://github.com/aeron-io/simple-binary-encoding/wiki/Message-Versioning |
| SBED | https://github.com/aeron-io/simple-binary-encoding/wiki/Design-Principles |
| RKYV | https://rkyv.org/format.html |
| RKYVZ | https://rkyv.org/zero-copy-deserialization.html |
| RKYVP | https://rkyv.org/architecture/relative-pointers.html |
| BTF | https://docs.kernel.org/bpf/btf.html |
| DEDUP | https://nakryiko.com/posts/btf-dedup/ |
| CTF | https://ctfstd.org/ctf-spec/Overview.html |
| CTFH | https://ctfstd.org/ctf-spec/CTF-header.html |
| PSP | https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_functions_advanced_parameters |
| PSPL | https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_pipelines |
| PSC | https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/cmdlet-overview |
| PSH | https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_comment_based_help |
| NUSIG | https://docs.rs/nu-protocol/latest/nu_protocol/struct.Signature.html |
| NUPL | https://www.nushell.sh/contributor-book/plugin_protocol_reference.html |
| NUPIPE | https://www.nushell.sh/book/pipelines.html |
| OBL | https://online.oberon.org/oberon_en |
| OBW | https://en.wikipedia.org/wiki/Oberon_(operating_system) |
| GEN | https://bitsavers.org/pdf/symbolics/software/genera_8/Programming_the_User_Interface.pdf |
| GENW | https://en.wikipedia.org/wiki/Genera_(operating_system) |
| P9 | https://9p.io/sys/doc/9.html |
| MS64 | https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention |
| MSSW | https://learn.microsoft.com/en-us/cpp/build/x64-software-conventions |
| MSBF | https://learn.microsoft.com/en-us/cpp/c-language/c-bit-fields |
| SYSV | https://gitlab.com/x86-psABIs/x86-64-ABI/-/blob/master/x86-64-ABI/low-level-sys-info.tex |
| RUSTL | https://doc.rust-lang.org/reference/type-layout.html |
| RUSTX | https://doc.rust-lang.org/reference/items/external-blocks.html |
| ZIG | https://ziglang.org/documentation/master/ |
| ODIN | https://odin-lang.org/docs/overview/ |
| SWLE | https://www.swift.org/blog/library-evolution/ |
| SWABI | https://github.com/swiftlang/swift/blob/main/docs/ABIStabilityManifesto.md |
| GSW | https://faultlore.com/blah/swift-abi/ |
| GC | https://faultlore.com/blah/c-isnt-a-language/ |

## 1. WebAssembly Component Model

**Type set (WIT)**
- Primitive types are `bool`, `s8`–`s64`, `u8`–`u64`, `f32`, `f64`, `char`, `string`. [WIT]
- Compound types are `list`, `option`, `result`, `tuple`, `record`, `variant`, `enum`, `flags`, `resource` with `own`/`borrow` handles, `stream`, `future`. [WIT]
- Parameters must have names. A function has at most one result type. [WIT]
- The ABI reduces `tuple`, `enum`, `option` and `result` to `record` and `variant`. Only `string` and `flags` have their own representation. [CABI]
- `flags` is a packed bit-vector with at most 32 labels. It uses the smallest integer that fits. [CABI]

**Canonical ABI**
- The specification is Python pseudo-code that defines "lift" (memory to value) and "lower" (value to memory). An engine can fuse both into one direct copy. [CABI]
- A string is two pointer-sized values: pointer and code-unit count. Encodings are UTF-8, UTF-16 and `latin1+utf16`. Maximum byte length is `2^28 - 1`. [CABI]
- "Flattening" puts values in core parameters. The limits are 16 flat parameters and 1 flat result. Above the limit, the caller passes one pointer to a tuple in memory. [CABI]
- The result limit exists because the C ABI cannot express multi-value returns. [CABI]
- To lower a non-flat value, the engine calls the receiver's exported `realloc(old, old_size, align, new_size)`. Out of memory is a trap. [CABI]
- A handle is an `i32` index into a per-instance table. Index 0 is reserved. A task traps if it returns with live borrows. [CABI]

**Async (WASI 0.3)**
- WASI 0.3.0 was released on June 11, 2026. It moves async from the `wasi:io` package into the Component Model. [WASI3]
- New primitives are `async func`, `stream<T>` and `future<T>`. A stream is a value that crosses component boundaries. [WASI3]
- WASI 0.2 used `pollable` resources. Wake-ups did not compose across a chain A → B → host. [WASI3]

**Versioning**
- Packages have the form `ns:name@semver`. Items carry `@since(version=…)`, `@unstable(feature=…)` and `@deprecated(version=…)` gates. [WIT]
- Adding a variant case is a breaking change today. [WIT]
- Adding a parameter, record field or variant case today needs a new function or a breaking change. Function subtyping is planned to fix this. [CM1]

**Status and criticism (2026)**
- Component Model 1.0 is not released. It needs native implementation in two browser engines. [CM1]
- `cabi_realloc` causes heap fragmentation, poor handling of large allocation failures, one host-to-guest call per list element, and trouble with custom allocators. [CM1]
- The planned fix is "lazy value handles". The callee returns opaque indices. The caller copies the value to an address that it selects. [CM1]
- Async task bookkeeping adds about 3.5x overhead to synchronous cross-component calls, per a measurement by Nick Fitzgerald. [CM1]
- The 1.0 specification will keep only "the good parts" of the P3 specification, to reduce implementation cost. [CM1]
- Stream splicing without an intermediate copy did not ship in 0.3.0. [CM1]

## 2. COM, type libraries, WinRT

- A type library (`.tlb`) is a binary file. It lets a program find an object's interfaces and call its methods at run time, across languages. [TLB]
- WinRT metadata (`.winmd`) uses the ECMA-335 physical file format, with different validity rules. System `.winmd` files are pure metadata. [WINMD]
- WinRT fundamental types are `Int16/32/64`, `UInt8/16/32/64`, `Single`, `Double`, `Char16`, `Boolean` (8 bits), `String`, `Guid`. There is no signed 8-bit type. [WRT]
- Enums are `Int32` or `UInt32` only. `UInt32` enums are flags. [WRT]
- Struct fields are limited to primitives, enums, structs, strings and `IReference<T>`. [WRT]
- Every method returns `HRESULT`. The real result is a final `[out, retval]` parameter. Parameters are `in` or `out` only, never both. [WRT]
- `HRESULT` is 32 bits: a severity bit, an 11-bit facility and a code. A clear severity bit means success. [HRES]
- Arrays exist only as parameters, as a `UInt32` size followed by a pointer. Three styles exist: PassArray, FillArray, ReceiveArray. [WRT]
- `HSTRING` is an immutable string handle. The `NULL` handle is the empty string. A "fast-pass" string reference avoids a heap copy. [HSTR]
- Every interface requires `IInspectable`, which requires `IUnknown`. `GetRuntimeClassName` lets a projection find the type in metadata. [WRT]
- System structs, delegates and interfaces are immutable once defined. Enums and classes grow by addition: new enum values, new interfaces on a class. [WRT]
- Every type carries a `Version` attribute. [WRT]
- Programs test for API presence at run time with `ApiInformation` and API contracts. [APIC]
- Third parties cannot define parameterized interfaces or custom attributes. [WRT]
- Lessons (inference):
  - A binary metadata file that all languages read works at OS scale.
  - Immutable interfaces produce `IFoo2`, `IFoo3` chains.
  - ECMA-335 metadata needs a large reader. This conflicts with flat tables.
  - `HRESULT` plus an out-parameter result maps badly to languages with multiple results.

## 3. Fuchsia FIDL

- A message is a fixed-size primary object plus out-of-line objects in depth-first order, all 8-byte aligned. The format is not self-describing. [FWIRE]
- Encoded and decoded forms have the same size. Decode is in place: presence markers become pointers. [FWIRE]
- A string or vector is a 16-byte record: `u64` count plus `u64` data pointer. A string is UTF-8 bytes. [FWIRE]
- A handle is 32 bits. On the wire, handles move to a separate handle vector. The inline value is `0` (absent) or `UINT32_MAX` (present). [FWIRE]
- Struct fields keep their declared order. Adding or removing a struct field breaks ABI. [FWIRE] [FLANG]
- A table is 16 bytes: count plus pointer to an array of 8-byte envelopes, indexed by ordinal. An all-zero envelope means absent. [FWIRE]
- An envelope stores payloads of 4 bytes or less inline. It records byte and handle counts, so a reader can skip unknown fields. [FWIRE]
- A union is a `u64` ordinal plus an envelope. Ordinal 0 means absent. [FWIRE]
- Padding must be zero. The decoder verifies it. Maximum nesting depth is 32. [FWIRE]
- The IDL declares handle type and rights: `zx.Handle:<H, R, optional>`. The system checks type and minimum rights and removes excess rights. [FLANG]
- A type that contains handles needs the `resource` modifier. [FLANG]
- `strict`/`flexible` controls whether unknown enum, bits, union members and methods are errors. Protocols are `closed`, `ajar` or `open`. [FLANG]
- A method ordinal is 8 bytes of the SHA-256 of the qualified name. `@selector` permits a rename. [FLANG]
- Size bounds such as `string:40` are validation constraints, not layout. [FLANG]
- The guidance for error values is "Avoid 0 in errors as it may be confused with success". [FLANG]

## 4. Zero-copy fixed-layout formats

| Format | All-zero bytes valid? | How a record grows |
|---|---|---|
| Cap'n Proto | Yes. "A default struct is always all-zeros". Fields are stored XOR default. A null pointer is the default. [CAPN] | New fields get higher numbers. The struct pointer carries data and pointer section sizes. [CAPN] [CAPNL] |
| FlatBuffers table | No (inference). A table needs a vtable offset. Absent fields are vtable entries of 0. [FB] | Add fields at the end of the table. Old readers ignore them. New readers get the default. [FBE] |
| FlatBuffers struct | Yes (inference). It is plain fixed-layout scalars. [FB] | No growth. Structs have no versioning. [FB] |
| SBE | `UNVERIFIED`. Null uses a per-type sentinel value, so zero is not "absent". [SBE] | Append optional fields to the end of a block. The header carries `blockLength` and `version`; fields carry `sinceVersion`. [SBE] |
| rkyv | Not a design goal (inference). Layout is `#[repr(C)]` Rust structs with relative pointers. [RKYV] [RKYVP] | No schema evolution mechanism found. `UNVERIFIED`. |

- Cap'n Proto: a new parameter must go at the end of the list and have a default. [CAPNL]
- Cap'n Proto: `Bool` is 1 bit. Enums are 16 bits. `Text` is NUL-terminated UTF-8. [CAPN]
- Cap'n Proto: a capability pointer is an index into a per-message capability table. [CAPN]
- Cap'n Proto: readers must validate pointers. Defaults are a 64 MiB traversal limit and a depth limit of 64. [CAPN]
- FlatBuffers: each field read goes through a 16-bit vtable entry. Offsets are 32-bit. Strings have a 32-bit length prefix and are NUL-terminated. [FB]
- FlatBuffers: a union is an enum tag plus an offset. Tag 0 is `NONE`. [FB]
- SBE: a decoder compares the acting block length to return null for fields that an old writer did not send. [SBE]
- SBE: a `composite` type cannot grow without a new schema. [SBE]
- SBE: fields are native types at fixed offsets. No intermediate buffer and no allocation are used. [SBED]
- rkyv: access is a pointer offset and a cast. Relative pointers stay valid at any load address. [RKYVZ] [RKYVP]

## 5. Flat-table type descriptions

- BTF has a header with magic, version, `hdr_len`, and offsets and lengths of a type section and a string section. [BTF]
- Each BTF type starts with a 12-byte `struct btf_type`, followed by kind-specific data. Records have variable length. Type ids come from parse order. [BTF]
- Type id 0 is `void`. String offset 0 is the empty string. [BTF]
- `BTF_KIND_FUNC_PROTO` holds the return type and a list of `btf_param {name_off, type}`. Parameter names are present. [BTF]
- `BTF_KIND_DECL_TAG` attaches a string to a declaration, member or argument. [BTF]
- BTF has no help-text field. A decl tag is the closest hook (inference). [BTF]
- Related tables pass their record size explicitly (`func_info_rec_size`), so records can grow. [BTF]
- Kernel type data is 121.31 MB of DWARF descriptors plus 2.68 MB of strings. After deduplication, BTF is 0.97 MB of descriptors plus 0.63 MB of strings. [DEDUP]
- Before deduplication, BTF is 101.7 MB. The gain comes from deduplication, not from the encoding. [DEDUP]
- CTF "compactly describes C types and the association between function and data symbols and types". It can reuse the ELF string table. [CTF]
- CTF has a header with a section table. A child dictionary can refer to types in one parent. [CTFH] [CTF]
- DWARF is a tree of debug entries with attribute encodings, built for debuggers. `UNVERIFIED`.
- Fit for a loader and console (inference):
  - The BTF model fits: type ids, a string table, function prototypes with named parameters.
  - Variable-length records do not fit flat tables. Split each kind into its own fixed-record table with index ranges.
  - BTF describes C types only. It has no slice, string, optional, variant or handle.

## 6. Typed shells

**PowerShell**
- A cmdlet is a .NET class. Public properties with attributes are its parameters. [PSC]
- The `Parameter` attribute declares `Mandatory`, `Position`, `ValueFromPipeline`, `HelpMessage`. Validation attributes include `ValidateSet`. `ArgumentCompleter` supplies completions. [PSP]
- Parameters take pipeline input `ByValue` (type match) or `ByPropertyName` (property with the parameter's name). [PSPL]
- The pipeline sends objects one at a time. [PSPL]
- Help comes from structured comments or XML files, read by `Get-Help`. [PSH]

**Nushell**
- A command `Signature` holds:
  - `name`, `description`, `extra_description`, `search_terms`
  - `required_positional`, `optional_positional`, `rest_positional`
  - `named` flags
  - `input_output_types` as (input, output) pairs
  - `category`. [NUSIG]
- Each positional has a name, a syntax shape and a description. [NUSIG]
- A plugin is a separate process. The engine sends a `Call` with an id. The plugin answers with a `CallResponse`. Stream messages carry stream ids. [NUPL]
- Data sent to an external command is converted to a string. [NUPIPE]

**Oberon**
- A command is any exported procedure with no parameters, written `Module.Command`. [OBL] [OBW]
- The procedure must scan its own parameters from the text. No checks occur. [OBW]
- Oberon proves "exported procedure = command". It has no typed arguments.

**Genera**
- A presentation type classifies an output object and defines the translation between the object and its printed form. [GEN]
- The same object can display as different presentation types. Output stays linked to the object, so it is mouse-sensitive as input. [GEN]
- Dynamic Windows gives a presentation-based user interface. [GENW]
- Command Processor commands declare arguments with presentation types, which drive prompts and completion. `UNVERIFIED`.

**Plan 9 (contrast)**
- Resources are files from file servers, such as `/dev/mouse` and `/dev/cons`. Programs use byte streams on standard input and output. [P9]
- Composition is by text and file names, not by typed values (inference).

**Arcan**
- No source fetched. `UNVERIFIED`.

**Metadata a typed console needs (inference from the above)**
- Per function: name, summary, long help, category.
- Per parameter: name, type, required or optional, help text.
- Per parameter: allowed values or range, and a completion source.
- Per parameter: a mark for "accepts piped input".
- Per result: type, and whether it is one value or a stream of records.

## 7. C ABI as lingua franca

**Unambiguous on x86-64**
- `_Bool` is 1 byte. `char` 1, `short` 2, `int` 4, `long long` 8, `float` 4, `double` 8, pointers 8, each at natural alignment. [SYSV] [MSSW]
- A struct of these types at natural alignment has the same layout under both ABIs (inference). [SYSV] [MSSW]

**Problem areas**
- `long` is 8 bytes on LP64 and 4 bytes on Windows. [SYSV] [MSSW]
- `enum` size: `int` by default; the type grows when values do not fit. Rust calls its `repr(C)` enum size "a best guess". [SYSV] [RUSTL]
- Bit-fields: allocation order and straddling are implementation choices. MSVC and the psABI define different rules. [MSBF] [SYSV]
- Struct by value, Win64: an argument that is not 1, 2, 4 or 8 bytes goes by reference. One argument never spans two registers. [MS64]
- Struct by value, SysV: structs up to 16 bytes can go in two registers. Larger ones go in memory. `UNVERIFIED` in this session; see [SYSV].
- Win64 uses `RCX`, `RDX`, `R8`, `R9` for integer arguments. Variadic calls have extra rules. [MS64]
- A survey lists 176 target triples and no machine-readable ABI definition. Languages hardcode C type sizes. [GC]

**Language support**
- Rust: `repr(C)` gives C layout. Default layout has almost no guarantees. `bool` is 1 byte. [RUSTL]
- Rust: `repr(C)` on an enum with fields is a tag plus a union of structs. [RUSTL]
- Rust: `extern "C"`, `"sysv64"` and `"win64"` select the convention. [RUSTX]
- Zig: "An `extern struct` has in-memory layout matching the C ABI for the target". A plain `struct` has no layout guarantee. [ZIG]
- Zig: `packed struct` has the ABI of its backing integer. `c_long` and similar types exist only for C compatibility. [ZIG]
- Odin: the default `"odin"` convention adds an implicit `context` pointer and can promote values to pointers. [ODIN]
- Odin: `proc "c"` is the C convention. `"contextless"` is Odin without the context pointer. [ODIN]
- Odin: `#packed`, `#align(N)` and `#raw_union` control layout. Slices are normal structures with pointer fields. [ODIN]

**Swift stable ABI**
- A stable ABI persists for the platform lifetime. Inefficiencies at declaration time persist too. [SWABI]
- By default, a library type has "resilient" layout. Clients ask a value witness table at run time for size, alignment and copy/destroy functions. [GSW]
- `@frozen` exposes layout for performance and removes future flexibility. [SWLE]
- Library evolution changes performance characteristics. Turning it on is itself a binary-incompatible change. [SWLE]
- Lesson (inference): Swift pays run-time indirection to let types change. A contract of fixed records with append-only growth avoids that cost.

## Design lessons

1. **Base types.** Use `u8`–`u64`, `i8`–`i64`, `f32`, `f64`, and `bool` as one byte with value 0 or 1. WIT, FIDL and WinRT agree on this set. Exclude `long`, `size_t`, `char`, bit-fields, `long double` and bare `enum`.
2. **Layout rule.** Fields keep declared order at natural alignment, little-endian. Padding is explicit and zero, as in FIDL. This layout is identical in C, Odin `struct`, Rust `repr(C)` and Zig `extern struct`.
3. **Enums and flags.** Give each a declared integer width. Reserve 0 for "none" or "unspecified". For error enums, 0 means success.
4. **Slice and string.** Use one 16-byte record `{u64 pointer_or_offset, u64 count}`. A string is a UTF-8 byte slice, with no NUL terminator in the contract. All-zero is the empty slice.
5. **Optional.** Do not add a tag when a zero value can mean absent: zero handle, zero-count slice, enum 0. Otherwise use a `present` byte before the value. All-zero then reads as absent.
6. **Variant.** Use `{u32 tag, padding, payload sized to the largest case}` with tag 0 = none. This matches FIDL ordinal 0, FlatBuffers `NONE` and Rust `repr(C)` enums.
7. **Handle.** Use a fixed record `{u32 index, u32 generation}` with all-zero invalid. Declare object type and required rights in the parameter description, as FIDL does. The ring transport checks and reduces rights. A direct call trusts them.
8. **One calling form.** Give each function one arguments record and one results record. The direct call passes two pointers. The ring call puts the same two records in the command and completion entries. One convention removes the SysV/Win64 struct-by-value difference and the Canonical ABI flattening rules.
9. **Pointers across the ring.** In direct calls, a slice holds an address. In ring calls, the same field holds an offset into a shared region. The description marks which fields are references. Validate bounds on receipt. This is the FIDL presence-marker idea without a re-encode.
10. **Caller owns memory.** Never let the callee allocate in the caller, as `cabi_realloc` does. Use caller-supplied buffers with a capacity and a returned count (WinRT FillArray), or a result handle that the caller reads later (lazy lowering).
11. **Growth.** Store record size in the description. Old callers send short records. The receiver treats missing bytes as zero, as SBE `blockLength` and BTF `rec_size` do. Never reorder or reuse fields. This avoids `IFoo2` chains and WIT's breaking changes.
12. **Metadata tables.** Use the BTF model with fixed-size records: a type table, a field table, a function table, a parameter table and a string table. Index 0 is the null entry in each. Reference by index and range, never by parse order.
13. **Console fields.** Add to each function and parameter record: help string offset, required flag, value constraint, completion source, "accepts piped input" flag, and a "result is a stream" flag. PowerShell and Nushell show that these fields are sufficient.
14. **Streams.** Model a stream as a handle that yields batches of fixed records through the same ring. Do not add `stream<T>` to the type set. WASI 0.3 shows that the type-level form pulls a scheduler into the ABI.
15. **Avoid.** No language runtime in the contract (Odin `context`, Swift witness tables). No self-describing encodings or vtables per record. No non-zero null sentinels (SBE). No string-encoding options. No C headers as the source of truth.
