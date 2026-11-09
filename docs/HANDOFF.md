# Hand-off: kernel design

Updated 2026-11-10. The first milestone is implemented: the system boots under QEMU to a desktop with a console, a system tool and demos. See `FIRST_MILESTONE.md`.

## What the owner wants

A new kernel that breaks with current designs and keeps the proven ideas of Linux, NT and others.
The starting point is the set of ideas that Jonathan Blow described on stream.
The central theme is data-oriented design. The end goal is a desktop environment and user programs.

The owner wants help to collect separate ideas, develop them, and make them concrete.
Reuse existing software where it fits.

## Current deliverable

The code of the first milestone, with its test under QEMU (`kerneltool test`, `nix flake check`).
`FIRST_MILESTONE.md` describes what the code does, the choices that the owner has not reviewed, and the gaps.
The next step is the owner's review of that file.

`PROPERTIES.md` is the plan of the properties on which the kernel is built. It lists 21 properties, all accepted.

## Rules from the owner

- **Never commit under an AI identity.** No AI author, committer, `Co-Authored-By` or session trailer. Commits carry the owner's identity only.
- **Deliverables in English.** The owner writes in French.
- **"Everything is a file" is rejected.** Decided on 2026-11-09.
- **Relocatable modules must also give reproducibility**, in the manner of NixOS. Decided on 2026-11-09.
- **First machine: QEMU with virtio.** Decided on 2026-11-09. The owner does not see hardware as the main problem.
- **Use the TPM, UEFI programs ("rich boot") and Secure Boot.** Decided on 2026-11-09.
- **Target WebGPU and WGSL as the graphics stack.** Decided on 2026-11-09.
- **Implementation language: Odin.** Accepted by the owner on 2026-11-09 ("odin ok"). The owner checks if they have access to the Jai beta. A UEFI program in Odin was proven to start under QEMU with OVMF.
- **First use: a dedicated machine. No compatibility at first.** Decided on 2026-11-09. POSIX and Win32/NT layers are possible later, above the base interface.
- **The console is a normal program with a real language. No TTY concept.** Decided on 2026-11-09.
- **Do not go too fast.** The owner asked for architecture and key systems before any code. See `ARCHITECTURE.md`.
- **A command is a function. No text between programs.** Decided on 2026-11-09. No `argv`, no text pipes, no parsing. A command line program and a library are the same module; the metadata makes each exported function callable from the console. A started program receives a structured context, never `argc` and `argv`. See property 19.
- **No system contract depends on a feature of one language.** Decided on 2026-11-09. Odin is the implementation language, not part of the interface. Contracts are memory layouts and numbers.
- **The removal of the shared file system is a security requirement**, not a preference (owner, 2026-11-09). Property 20 lists the other cases of ambient access to close. The owner accepted the whole list.
- **Zero is initialization (ZII).** Named by the owner on 2026-11-09. An all-zero record is valid in every system contract. See property 13.
- **Persistence: no save action; storage keeps versions for all programs.** Decided on 2026-11-09. See property 9.
- **Conversation in English** from 2026-11-09, at the owner's request, to keep one term per concept.
- **`GLOSSARY.md` defines the terms.** Use each term as defined and no synonym. Add a term there before using it. The code format is a "module" (the owner's choice over "unit"). "Who executes" is defined by principals and sessions (property 21).
- **The loader reads flat tables; SQLite is an index.** Accepted on 2026-11-09. See property 12.
- **Principals and sessions, no users.** Decided on 2026-11-09. The kernel has no concept of who executes. See property 21.
- **Usability concessions are accepted for the desktop**, but must not ruin the security model (owner, 2026-11-09).
- **Odin is the implementation language.** Final, 2026-11-09.
- **One kernel tool, no scripts.** Decided on 2026-11-09. All project automation is a command of one Odin tool: build, convert to modules, make the boot image, start QEMU, run tests (also the tests that do not fit a unit test suite), and every call to a third-party tool. Run it with `odin run tools/<tool> -- <command>`. The tool fixes in advance how third-party tools are run. Do not add shell, Python or other scripts.
- **Performance is a criterion at every level**, also for the build tools. The owner rejects slow software.
- **Linker: do not write one from nothing.** Reuse or adapt a well-written existing linker, and connect the project's module output to it. The owner names the RAD Linker as a candidate. See `MODULE_CONTRACT.md` section 7.
- **ELF is accepted as a build-time intermediate format only.** It never reaches the running system.
- **`MODULE_CONTRACT.md`** is the proposal for the contract between modules. The owner's first reaction is positive; its four decisions are not yet confirmed.
- **Accepted on 2026-11-09**: properties 4, 7, 14, 15 and 16 as written; a new storage engine under MIT (no bcachefs fork); the kernel ring as the only kernel entry.
- **Call form: registers.** The owner delegated the choice. Chosen: a scalar-only subset of the machine's register assignment. See `MODULE_CONTRACT.md` section 4.
- **Threads: do what Blow would do; do not complicate the execution model.** Chosen: several plain threads per program. See `ARCHITECTURE.md`, open question 6.
- **Nix flake at the root supplies all build tooling**: compiler, linker, QEMU, firmware. The kernel tool runs inside it.
- **Layout of the repository** (2026-11-09): documents are in `docs/`, research notes in `docs/research/`, the boot program in `boot/`, the kernel tool in `tools/kerneltool/`. Build output goes to `build/`, which git ignores.
- **Commands**: `nix develop`, then `odin run tools/kerneltool -out:build/kerneltool -- help`. `nix flake check` runs the hooks and the boot test under QEMU.
- **Never use `gui_toolkit` in this project.** Decided on 2026-11-09. It is not made for a kernel. Graphical code is written from nothing, as a program of this system. The kernel tool uses only the Odin standard library.
- **Decided on 2026-11-09**: WebGPU implementation written from nothing; `lld` now and a study of the RAD Linker next; RDI as the debug information format; a stream is a handle; BLAKE3; exports are functions only; the kernel tool counts kernel operations, with no fixed limit yet.
- **Next step chosen by the owner: more research before design or code.**
- **Graphics order (decided on 2026-11-09)**: no GPU at first. UEFI framebuffer, surfaces in shared memory, CPU drawing. WebGPU comes later on a working desktop. See property 18.
- **RAD Linker and RDI study done** (2026-11-09, `research/rad_linker_rdi_study.md`; nothing was built or run, so build and runtime facts are unverified). Result: do not adapt the RAD Linker now; write the module converter with a linked image as input; RDI fits as the debug format but not as the description tables. Decided by the owner on 2026-11-09: modules are built on the ELF target with `lld`; RDI is not required, and debug information is DWARF in a separate object. Only the boot program uses the COFF target, because UEFI requires a PE file.
- **Module contract rules closed on 2026-11-09**: no intermediate form of code; private module data and no code before the entry; one level of nested data across a ring; no thread-local data in the contract; no unwinding and required frame pointers; the kernel is a module. See `MODULE_CONTRACT.md`, "Rules closed".
- **Goal of the first milestone (owner, 2026-11-09)**: a booted system with a working console and a basic graphical desktop, with demos and system tools that show what the system can do. Done on 2026-11-10.
- **Font (owner, 2026-11-10)**: no enlarged low-resolution font. Use a bitmap font of good quality at its native size. Chosen: Spleen 8x16, BSD 2-Clause.
- **Temple of Jon (owner, 2026-11-10)**: a demo, for fun, in the spirit of Jai: a portrait of Jonathan Blow that turns. Done as `programs/temple`: a flat card with perspective, drawn by the processor. The portrait is a public domain picture (`programs/temple/PORTRAIT_LICENSE`).
- No pull request unless the owner asks.

## Research

Notes are in `research/`.

| Subject | File | State |
|---|---|---|
| Blow, statements read at the source | `blow_verified_statements.md` | Done. 17 design clips read. Use this file for citations |
| Blow, transcripts | `transcripts/` | 36 videos, automatic captions, index in `transcripts/README.md` |
| Blow, first survey from secondary sources | `blow_os_kernel.md` | Superseded for design items. Still useful for tweets, critiques and rebuttals |
| Handmade community | `handmade_sphere_os.md` | Done |
| Data-oriented kernel patterns | `data_oriented_kernel.md` | Done. [V] is verified, [R] is recalled |
| Ideas from Linux, NT and research kernels | `existing_kernels_good_ideas.md` | Done. About 40% of URLs verified |
| bcachefs and storage | `bcachefs_storage.md` | Done |

### Limits of the research

- Transcripts are automatic captions. Check the video before you publish a quote as exact.
- All 36 transcripts are now read. `research/blow_remaining_transcripts.md` holds the statements from the 21 that were read last.
- Upload dates are known. Stream dates are not, except `bQnB6eI8DU4` (2026-04-11).
- The "On the Metal" podcast episode with Blow (2020) was not transcribed. It discusses microkernels and dynamic linking.
- No research exists on executable formats, linkers and loaders. Property 10 needs it.
- DBOS details and the licences in the reuse list of `PROPERTIES.md` come from memory.

## Next steps

1. Get the owner's review of the choices in `FIRST_MILESTONE.md`.
2. Isolated call of an export through a ring; Text results; descriptions made from the source (property 19).
3. Rights on handles, and a split of the Machine handle.
4. Damage rectangles in the compositor.
5. A block device service (virtio), then the storage service.
6. Research on identity across machines; check of the licences in the reuse list of `PROPERTIES.md`.
