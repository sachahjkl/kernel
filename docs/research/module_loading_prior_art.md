# Module loading prior art: research report

Status: research note, 2026-11-09. Sources were fetched on that date unless marked UNVERIFIED.

Sources were fetched in this session unless marked UNVERIFIED. UNVERIFIED items come from memory and need a check before you rely on them.

## 1. ELF on x86-64

**What the loader maps**
- The kernel maps each `PT_LOAD` segment. For `ET_DYN`, it picks a base and places later segments relative to the first `p_vaddr`. https://fuchsia.dev/fuchsia-src/concepts/process/program_loading
- If `PT_INTERP` exists, the kernel also loads the interpreter and starts it. The interpreter finds the main program through the auxiliary vector. (same URL)

**Dynamic relocations**
- `R_X86_64_RELATIVE` does `*(base+r_offset) += base + addend`. It needs no symbol. https://maskray.me/blog/2021-10-31-relative-relocations-and-relr
- Relative relocations are typically 90% of dynamic relocations in a PIE, and up to 99% in a mostly static PIE. (same URL)
- Their sources are data pointers: `void *p = &foo`, string pointer arrays, C++ vtables, and non-preemptible GOT entries. (same URL)
- A preemptible GOT entry gets `R_*_GLOB_DAT`. A PLT slot in `.got.plt` gets `R_*_JUMP_SLOT`. Both need a symbol lookup. https://maskray.me/blog/2021-08-29-all-about-global-offset-table and https://maskray.me/blog/2021-09-19-all-about-procedure-linkage-table
- A `RELA` record is 24 bytes. On Arch Linux `/usr/bin`, relative relocations take 7.9% of total file size. https://maskray.me/blog/2021-10-31-relative-relocations-and-relr

**RELR**
- An even entry is an address. An odd entry is a bitmap of up to 63 following words. The decoder is about 12 lines of C. (same URL)
- RELR typically encodes the same information in under 3% of the `.rela.dyn` space. (same URL)
- glibc supports it from 2.36, musl from 2022-08. Android, Fuchsia and FreeBSD use it. (same URL)
- An old glibc segfaults on a RELR object with no diagnostic. The format had no "loader must understand this" field. (same URL)

**Lazy and eager binding**
- Lazy binding sends the first call through a PLT trampoline to the resolver, which writes the address into `.got.plt`. https://maskray.me/blog/2021-09-19-all-about-procedure-linkage-table
- `-z now` sets `DF_1_NOW` and binds eagerly. Eager binding also reports missing symbols at load time. (same URL)
- `-fno-plt` inlines the PLT entry as one instruction, `call *foo@GOTPCREL(%rip)`. This binds eagerly through a GOT slot. (same URL)
- glibc 2.39 added the tunable `glibc.cpu.plt_rewrite`. With non-lazy binding, the loader rewrites indirect PLT branches into direct branches. https://raw.githubusercontent.com/bminor/glibc/master/NEWS

**Symbol lookup**
- The cost model is O(R + n·r·log s): R relative relocations, n libraries, r named relocations, s symbols. Each candidate also costs a `strcmp`. https://fzakaria.com/2024/05/03/speeding-up-elf-relocations-for-store-based-systems.html
- In that test, 1 million symbols took nearly 4.5 s to relocate under musl. Over 60% of cycles were in `find_sym`. (same URL)
- `DT_GNU_HASH` adds a Bloom filter, a better hash, and omits symbols that are never looked up. Its 2006 patch thread claims about 50% improvement. https://maskray.me/blog/2022-08-21-glibc-and-dt-gnu-hash
- With direct binding, unsuccessful lookups mostly vanish and the Bloom filter is not needed. (same URL)

**Interposition**
- The executable is first in the search list. Any default-visibility global symbol in a shared object can be replaced by an earlier definition. https://maskray.me/blog/2021-05-16-elf-interposition-and-bsymbolic
- GCC `-fpic` therefore does not inline or optimize across such functions. CPython measured up to 30% loss. https://maskray.me/blog/2021-05-09-fno-semantic-interposition
- `-Bsymbolic` binds a library's own symbols at link time. It is "very similar to `-pie`". https://maskray.me/blog/2021-05-16-elf-interposition-and-bsymbolic
- A clang built `-fPIC` runs 15% faster with `-Bsymbolic-functions` on libLLVM and libclang-cpp. (same URL)
- `-Bsymbolic` breaks pointer equality: a function address differs inside and outside the library. (same URL)
- Protected visibility also blocks preemption, but it conflicts with copy relocations in non-PIC executables. (same URL)
- PE/COFF has no interposition. Mach-O needs an explicit opt-in. https://maskray.me/blog/2021-05-09-fno-semantic-interposition
- Solaris direct binding records which object each symbol binds to, and avoids the search. https://docs.oracle.com/cd/E23824_01/html/819-0690/aehzq.html

**Static-PIE minimum**
- A static PIE loads at any address and has no interpreter. glibc supports it from 2.27. https://raw.githubusercontent.com/bminor/glibc/master/NEWS
- The start code must find its own base and `_DYNAMIC`, then apply relative relocations (REL, RELA, RELR) before it touches any relocated data. UNVERIFIED in detail; this matches the Genode `init_rtld` description in section 6.
- No symbol table, hash table, GOT lookup or PLT is needed.

**Line counts (musl, fetched files)**
- `ldso/dlstart.c`, the self-relocation stage: 164 lines. https://git.musl-libc.org/cgit/musl/plain/ldso/dlstart.c
- `crt/rcrt1.c`, the static-PIE entry: 15 lines, and it reuses `dlstart.c`. https://git.musl-libc.org/cgit/musl/plain/crt/rcrt1.c
- `ldso/dynlink.c`, the full dynamic linker: 2455 lines. https://git.musl-libc.org/cgit/musl/plain/ldso/dynlink.c

## 2. PE/COFF

All facts in this section are from https://learn.microsoft.com/en-us/windows/win32/debug/pe-format unless another URL is given.

- **Headers.** Data directories are fixed-index (RVA, size) pairs in the optional header: export, import, base relocation, IAT, delay import and others. Section headers are fixed 40-byte records.
- **Base relocations.** `.reloc` is split into blocks, one per 4K page. Each block has an 8-byte header and 16-bit entries (4-bit type, 12-bit offset). The x64 type is `IMAGE_REL_BASED_DIR64`.
- The loader skips base relocations when the image loads at its preferred `ImageBase`.
- This format is denser than ELF REL/RELA and less dense than RELR. https://maskray.me/blog/2021-10-31-relative-relocations-and-relr
- **Imports.** Each imported DLL has one import directory entry with a lookup table and an import address table (IAT). The loader overwrites IAT entries with addresses.
- The compiler calls through the slot `__imp_Function`. If the compiler did not know the function was imported, the linker adds a stub `jmp [__imp_Function]`. https://devblogs.microsoft.com/oldnewthing/20060721-06/?p=30433
- **Ordinal or name.** The top bit of a lookup entry selects a 16-bit ordinal. An ordinal is an index into the export address table, so no string search occurs.
- An import by name carries a hint, an index into the export name table. The loader tries the hint, then does a binary search on the sorted names.
- **Forwarders.** An export RVA that points inside the export section is a string such as `MYDLL.expfunc` or `MYDLL.#27`. The loader resolves it in the other DLL.
- **Bound imports.** A bind step writes final addresses into the IAT and records the DLL timestamp. The loader skips resolution if the timestamp matches and the DLL is at its preferred base. https://devblogs.microsoft.com/oldnewthing/20100318-00/?p=14563
- Binding saves load time and copy-on-write pages. (same URL)
- Binding depends on fixed bases, so ASLR defeats it. UNVERIFIED for current Windows behaviour.
- **Delay-load.** A separate directory holds a module handle slot, a delay IAT, a name table, and optional bound and unload tables. Helper code resolves on first call.

**Simpler than ELF**
- Imports name a (DLL, symbol) pair. There is no global search and no interposition.
- The code calls through a slot. The loader patches data only, never code.
- Ordinals give lookup by index.

**Worse than ELF**
- The preferred base is an identity leak: binding and relocation-skip depend on it.
- Timestamps act as weak identity for bound imports.
- Forwarders are strings parsed at load time.
- Four parallel import mechanisms exist: normal, bound, delay, delay-bound.
- Ordinals are stable only by convention. A new DLL version can renumber them.

## 3. Mach-O and dyld

- **Two-level namespace.** The static linker records which dylib each symbol was found in. dyld resolves directly in that dylib. https://keith.github.io/xcode-man-pages/ld.1.html
- With `-flat_namespace`, dyld searches all images in load order and takes the first definition. (same URL)
- Interposition is opt-in: `-interposable` makes exported symbols go through a stub. Without it, calls inside a dylib are direct and are not interposed. (same URL)
- **Prebinding** (Mac OS X 10.0). The system assigned fixed addresses to every dylib and rewrote the binaries with precomputed addresses. https://asciiwwdc.com/2017/sessions/413
- Apple dropped it because it edited binaries on launch, which is bad for security and code signing. (same URL)
- **Shared cache** (iOS 3.1, Snow Leopard) replaced prebinding. It merges system dylibs into one image and prebuilds dyld and Objective-C data structures. (same URL)
- **dyld 3** (2017). A launch closure holds everything needed to launch an app. Symbol lookups are computed out of process, in a daemon, and written to disk. (same URL)
- The talk gives no single headline number in the text I fetched. Published dyld 3 gains: UNVERIFIED.
- **dyld 4.** It returned closure building to the process, with prebuilt loaders as an optional cache. UNVERIFIED.
- **Chained fixups** (`LC_DYLD_CHAINED_FIXUPS`). Metadata stores only the first fixup offset per data page, plus an import table. https://developer.apple.com/videos/play/wwdc2022/110362/
- Each 64-bit slot holds the offset to the next fixup, a bind/rebase bit, and either an import index or a target offset. (same URL)
- Layout of `dyld_chained_ptr_64_rebase`: target 36 bits, high8 8 bits, reserved 7, next 12 bits (4-byte stride), bind 1 bit. https://raw.githubusercontent.com/apple-oss-distributions/dyld/main/include/mach-o/fixup-chains.h
- The header has `starts_offset`, `imports_offset`, `symbols_offset`, `imports_count`, `imports_format`. Each segment has a `page_start[]` array of 16-bit values, with `0xFFFF` for "no fixups". (same URL)
- **Page-in linking** (2022). The kernel applies fixups to a data page when it faults in. This requires chained fixups. (same URL as WWDC22)
- Result: less dirty memory, and `DATA_CONST` pages stay clean and evictable. Apple's example is TextEdit: 15 ms launch, 1 ms for fixups. (same URL)
- Page-in linking applies only at launch, not to later `dlopen`. (same URL)

## 4. Prelinking and content-addressed prior art

**Linux prelink**
- prelink assigned each library a fixed address and stored the relocation results in the files. https://lwn.net/Articles/341244/
- It conflicts with per-process library ASLR. Fedora and RHEL reran it every two weeks with random addresses, which stayed fixed in between. (same URL)
- PIE executables ignore prelinking on RHEL and Fedora. https://en.wikipedia.org/wiki/Prelink
- It also modified installed binaries, which broke checksums and caused unbootable-system bugs. https://lwn.net/Articles/341244/
- glibc announced the removal of prelink support, including `LD_TRACE_PRELINKING` and `LD_USE_LOAD_BIAS`. https://raw.githubusercontent.com/bminor/glibc/master/NEWS
- The notice appears in the 2.36 release notes. Exact version: UNVERIFIED.

**Android**
- Android removed its own prelink tool around Android 4.0 for ASLR. UNVERIFIED.
- Bionic refuses text relocations from API level 23. 64-bit never supported them. https://android.googlesource.com/platform/bionic/+/refs/heads/main/android-changes-for-ndk-developers.md
- Bionic supports GNU hash from API 23 and RELR. Its earlier "packed relocations" format is unrelated to RELR. (same URL)
- maskray calls that earlier format "somewhat over-engineered". https://maskray.me/blog/2021-10-31-relative-relocations-and-relr
- Zygote is one process that starts at boot. Every app process is a fork of it. https://source.android.com/docs/core/runtime/zygote
- The fork shares already-relocated library pages copy-on-write, so relocation cost is paid once. UNVERIFIED as a stated design goal.

**Nix and Guix search paths**
- Emacs in Guix has 39 RUNPATH directories and 80+ libraries. `emacs --version` made 3,325 syscalls, and 2,227 failed (67%). https://guix.gnu.org/blog/2021/taming-the-stat-storm-with-a-loader-cache/
- Guix fixed this with a per-package loader cache. (same URL)
- In Nix, emacs has 36 RUNPATH entries and 103 dependencies, up to about 3,600 probes. https://fzakaria.com/2022/03/14/shrinkwrap-taming-dynamic-shared-objects.html
- Shrinkwrap writes absolute paths into `DT_NEEDED`. It measured a 36x reduction in these syscalls. (same URL)
- The cause is name-based lookup. The build already knew the exact file.

**Stable linking and relocation caches (Farid Zakaria)**
- Idea: in a store-based system the library set is immutable. Resolve symbols once and save which object satisfies each relocation, without fixing addresses. https://fzakaria.com/2024/05/03/speeding-up-elf-relocations-for-store-based-systems.html
- This differs from prelink: it caches the resolution, not the address, so ASLR still works. (same URL)
- The prototype is on musl and stores the cache in a `.reloc.cache` section. It measured a 7.5x speedup on the 1-million-symbol case. (same URL)
- The paper "Stable Linking" argues that the benefits credited to dynamic linking are benefits of shared libraries. https://arxiv.org/abs/2501.06716

**Guix grafts**
- A graft replaces a dependency without rebuilding dependents. It patches store paths inside files, including binaries. https://guix.gnu.org/manual/devel/en/html_node/Security-Updates.html
- The replacement name and version string must have the same length. The library must keep the same SONAME and be binary compatible. (same URL)
- Grafting is recursive and takes time proportional to package size. (same URL)

**Nix content-addressed outputs**
- The address depends only on the store object, not on how it was built. https://nix.dev/manual/nix/latest/store/derivation/outputs/content-address
- Fixed content-addressed outputs cannot have references, including self-references. Floating content addressing is still experimental. (same URL)
- Self-references are the hard case: the hash must be computed with the own path masked. (same URL)

**Unison**
- Each definition is identified by a hash of its syntax tree (512-bit SHA3). Names are separate metadata and do not affect the hash. https://www.unison-lang.org/docs/the-big-idea/
- This is the closest prior art to "import by content hash". It works at function level and not on machine code.

## 5. Position independence on x86-64

**What remains to relocate**
- On x86-64, PIC has no text size penalty against non-PIC. The remaining cost is relative relocations in data. https://maskray.me/blog/2021-10-31-relative-relocations-and-relr
- Data that holds absolute addresses needs a relocation: pointers in globals, string tables, vtables. (same URL)
- A constant written as a difference (`.quad target - .`) is a link-time constant and needs no relocation. (same URL)
- Clang has `-fexperimental-relative-c++-abi-vtables`: 32-bit PC-relative vtable entries, read-only vtables, no relocation. Fuchsia uses it. (same URL)
- Jai and Odin offer relative pointers, which avoid relative relocations in global data. (same URL)
- Jump tables: compilers emit 32-bit table-relative offsets in PIC mode, so no relocation is needed. UNVERIFIED.

**Cross-module call sequences**

| Sequence | Encoding | Load-time work | Text shared |
|---|---|---|---|
| `call foo@PLT`, lazy | 5-byte call, then `jmp *slot` | none up front; resolver on first call | yes |
| `call *slot(%rip)` (`-fno-plt`, PE IAT) | 6 bytes, one indirect call | write one 8-byte slot | yes |
| Direct `call rel32` patched by loader | 5 bytes | write into text | no |

- Encoding sizes: UNVERIFIED in this session; they are standard x86-64 encodings (`E8 rel32`, `FF 15 disp32`).
- The PLT path costs a direct call plus an indirect jump. The slot path costs one indirect call. https://maskray.me/blog/2021-09-19-all-about-procedure-linkage-table

**Same sequence for merged and mapped modules**
- The psABI defines `R_X86_64_GOTPCRELX` and `R_X86_64_REX_GOTPCRELX` for `call *name@GOTPCREL(%rip)`, `jmp *`, `mov` and binary ops. https://raw.githubusercontent.com/hjl-tools/x86-psABI/master/object-files.tex
- The linker can turn a GOT-indirect call into a direct call when the target is in the same output. https://maskray.me/blog/2021-08-29-all-about-global-offset-table
- The relaxed form is `addr32 call foo` or `call foo; nop`, which keeps 6 bytes. UNVERIFIED.
- So one compiler output serves both cases. The compiler always emits "call through import slot". The merge step rewrites it to a direct call and deletes the slot.
- This rewrite runs at merge time on a private copy. It is not a text relocation.

**Text relocations**
- A relocation into a read-only segment forces the loader to write to code pages. Android rejects such files from API 23. https://android.googlesource.com/platform/bionic/+/refs/heads/main/android-changes-for-ndk-developers.md
- A patched page is private to the process and needs a writable-then-executable transition. This conflicts with page sharing and W^X.
- glibc's PLT rewrite is the only mainstream load-time code patch. It is limited to PLT pages and is opt-in. https://raw.githubusercontent.com/bminor/glibc/master/NEWS

## 6. User-space loaders in capability systems

### Fuchsia / Zircon

Facts are from https://fuchsia.dev/fuchsia-src/concepts/process/program_loading unless another URL is given.

- The kernel does not load programs. It provides VMOs, VMARs, processes and threads. A user-space program loader builds the new process.
- Zircon supports only PIE (`ET_DYN`). It has no fixed-address executables.
- The loader takes a VMO handle for the executable, not a file name. Filesystems are not part of the lower layers.
- The loader maps the segments, a stack VMO and the vDSO, each at a random address. It then creates a thread and a bootstrap channel.
- `zx_process_start(entry, stack, arg1, arg2)` starts the thread. `arg1` is the bootstrap channel handle. `arg2` is the vDSO base. All other registers are zero. https://fuchsia.dev/reference/syscalls/process_start
- The entry point is `noreturn void _start(zx_handle_t bootstrap_channel, uintptr_t vdso_base)`.
- A process started with an invalid `arg1` has no handles and can never get any. https://fuchsia.dev/reference/syscalls/process_start

**vDSO**
- The vDSO is the only way to enter the kernel. The kernel checks that each syscall comes from the proper vDSO code. The raw `syscall` instruction is not ABI. https://fuchsia.dev/fuchsia-src/concepts/kernel/vdso
- The vDSO is an ELF image supplied by the kernel as a VMO. A process needs that VMO handle (`PA_VMO_VDSO`) to map it into its children.

**Dynamic linker and loader service**
- If the executable has `PT_INTERP`, the program loader asks the loader service for that name and loads the interpreter in place of the executable.
- The bootstrap channel then holds two messages. The first is for the dynamic linker: the executable VMO and the loader service channel. The second is the main message.
- The dynamic linker consumes the first message and passes the channel to the main entry point.
- The loader service is a channel protocol. `LOAD_OBJECT` maps a name to a VMO. `CONFIG` selects a variant such as `asan`. The default implementation maps names to files under `lib/`.
- The dynamic linker starts on a one-page stack and switches to the real stack itself.

**userboot**
- The kernel embeds `userboot` and the vDSO. It maps both with a fixed layout, so it parses no ELF at boot. It needs three constants: two segment sizes and the entry point. https://fuchsia.dev/fuchsia-src/concepts/process/userboot
- The kernel sends `userboot` a normal `processargs` message. The kernel command line becomes the environment strings. (same URL)
- `userboot` decompresses BOOTFS, contains a full ELF loader, starts the first real process, serves a minimal loader service, then exits. (same URL)

**`processargs` message layout**

Source: https://fuchsia.googlesource.com/fuchsia/+/refs/heads/main/zircon/system/public/zircon/processargs.h

A channel message has a byte part and a handle part. The byte part starts with this header of nine `uint32_t` fields:

| Field | Meaning |
|---|---|
| `protocol` | `0x4150585d` ("MXPA") |
| `version` | `0x0001000` |
| `handle_info_off` | offset to an array of one `uint32_t` per handle in the message |
| `args_off`, `args_num` | offset and count of argument strings |
| `environ_off`, `environ_num` | offset and count of environment strings |
| `names_off`, `names_num` | offset and count of namespace name strings |

- All offsets are from the start of the message. Strings are NUL-terminated UTF-8, packed one after the other.
- Handle `i` in the handle part is described by entry `i` of the handle info array.
- A handle info entry is `type | (arg << 16)`: 8-bit type, 16-bit argument.
- For `PA_NS_DIR`, the argument is an index into the name table. For `PA_FD`, the argument is the file descriptor number.
- Handle types:
  - Core: `PA_PROC_SELF 0x01`, `PA_THREAD_SELF 0x02`, `PA_JOB_DEFAULT 0x03`, `PA_VMAR_ROOT 0x04`, `PA_VMAR_LOADED 0x05`.
  - Loader: `PA_LDSVC_LOADER 0x10`, `PA_VMO_VDSO 0x11`, `PA_VMO_STACK 0x13`, `PA_VMO_EXECUTABLE 0x14`.
  - Boot: `PA_VMO_BOOTDATA 0x1A`, `PA_VMO_BOOTFS 0x1B`.
  - Environment: `PA_NS_DIR 0x20`, `PA_FD 0x30`, `PA_LIFECYCLE 0x3A`, `PA_DIRECTORY_REQUEST 0x3B`, `PA_CLOCK_UTC 0x40`.
  - Free use: `PA_USER0..2 0xF0..0xF2`.
- The protocol is one-way. The creator usually writes the message and closes its end before the child runs.
- The decoder runs with no heap and no libraries, so the format is hand-decodable.
- The process learns its stack bounds from the size of the `PA_VMO_STACK` VMO and the initial SP.
- Fuchsia calls the protocol "ad hoc" and plans an IDL-based replacement. It still carries `argv` and `environ` as strings.

### Genode

Source: https://genode.org/documentation/genode-foundations/23.05/under_the_hood/Dynamic_linker.html

- The parent inspects the ELF program headers. For a dynamic program, it starts the dynamic linker and keeps the program's dataspace.
- The linker is a normal component. It requests the program as a ROM session named "binary", and each shared library as a ROM session, from its parent.
- The parent therefore controls which library a child receives, by session routing.
- The linker relocates itself first in `init_rtld`, called from the assembly startup code. Global data is unusable before that.
- The linker reserves a "linker area" region map, because loading one ELF object needs several attach operations that must stay contiguous.

### seL4

- The kernel starts one initial thread, the root task, which sets up the rest of the system. https://docs.sel4.systems/Tutorials/hello-world.html
- The kernel has no program loader. User libraries (`sel4utils`) or the capDL loader build other processes. UNVERIFIED in detail.

### Redox

- Redox binaries use ELF. https://doc.redox-os.org/book/programs-libraries.html
- In 2022 Redox moved `fork` and `execve` from the kernel into relibc (`userspace_fexec`, `userspace_clone`). initfs moved to user space too. https://www.redox-os.org/news/drivers-and-kernel-7/
- The current working directory is passed to the new program through auxiliary vectors. (same URL)
- Without on-demand copy-on-write `mmap`, the user-space `execve` and `ld.so` loaded ELF segments slowly. (same URL)

## Design lessons for a new format

1. **Bind to a named module, never search.** Record (import module hash, export index) per import. This removes the hash table, the Bloom filter, `strcmp`, and the search-path probes (67% failed syscalls in Guix).
2. **Forbid interposition by construction.** ELF pays up to 30% for it and PE never had it. If replacement is needed, make it an explicit import substitution in the start context.
3. **Import by index, with the hash as the validity check.** PE ordinals and hints fail because the DLL can change. A content hash makes a stored export index permanently correct, so no name lookup is needed at load time.
4. **Never store addresses in the module file.** Prelink, prebinding and PE bound imports all died from ASLR, code signing, or file mutation. Cache the resolution (which module, which export), as stable linking does.
5. **Use one call sequence: call through an import slot.** Emit `call *slot(%rip)` for every cross-module call. The merge step rewrites it to a direct call, as GOTPCRELX relaxation does. The loader then writes data slots only.
6. **No load-time writes to code pages.** Text stays shared and W^X holds. Android rejects text relocations; follow that rule from day one.
7. **Keep only two fixup kinds: rebase and bind.** Mach-O chained fixups show this is enough. Rebase adds the module base. Bind writes an import address.
8. **Encode rebases compactly.** RELR uses under 3% of the RELA size with a 12-line decoder and fits a fixed-record table. Chained fixups are denser still and enable lazy per-page fixing, but they put metadata inside data pages and break the "valid when all zero" rule.
9. **Group all loader-written data in one contiguous region.** Import slots and relocated pointers then dirty few pages, and the region can become read-only after load. Apple measured clean `DATA_CONST` pages as a memory gain.
10. **Reduce relocations at the source.** Use relative pointers and offset tables for vtables, jump tables and string tables. Odin already has relative pointers. A module with zero rebases maps fully shared.
11. **Bind eagerly, or lazily per page; never per call.** Lazy PLT binding adds a resolver, an extra jump, and late failures. With index-based binding, eager binding costs one table walk.
12. **Add a "must understand" version field in the header.** RELR objects crash old loaders without a diagnostic because ELF has no such field.
13. **Start a process with a structured context, not `argv`.** Copy `processargs`: a fixed header with offsets and counts, typed handle entries (type + argument), decodable with no heap. Avoid its two weaknesses: string `environ`, and names resolved by a loader service.
14. **Pass the loader a capability to a module store keyed by hash.** Fuchsia and Genode pass library names to a parent service. Asking for a hash removes the naming policy and makes the reply verifiable.
15. **Make the first-stage loader a self-relocating module with fixed layout.** musl does self-relocation in 164 lines. Zircon's kernel maps `userboot` from three constants and parses no file format. The hash must cover the file with no self-reference, which is the hard case in Nix; imports go in by hash, so cyclic imports are impossible.
