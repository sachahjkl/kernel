# Hand-off: kernel design

Updated 2026-11-09. This repository contains no kernel code yet.

## What the owner wants

A new kernel that breaks with current designs and keeps the proven ideas of Linux, NT and others.
The starting point is the set of ideas that Jonathan Blow described on stream.
The central theme is data-oriented design. The end goal is a desktop environment and user programs.

The owner wants help to collect separate ideas, develop them, and make them concrete.
Reuse existing software where it fits.

## Current deliverable

`PROPERTIES.md` is the plan of the properties on which the kernel is built. It is draft 2.
It lists 20 properties, their status (decided or proposed), their costs, the tensions between them, and six decisions for the owner.
The next step is the owner's review of that file.

## Rules from the owner

- **Never commit under an AI identity.** No AI author, committer, `Co-Authored-By` or session trailer. Commits carry the owner's identity only.
- **Deliverables in English.** The owner writes in French.
- **"Everything is a file" is rejected.** Decided on 2026-11-09.
- **Relocatable units must also give reproducibility**, in the manner of NixOS. Decided on 2026-11-09.
- **First machine: QEMU with virtio.** Decided on 2026-11-09. The owner does not see hardware as the main problem.
- **Use the TPM, UEFI programs ("rich boot") and Secure Boot.** Decided on 2026-11-09.
- **Target WebGPU and WGSL as the graphics stack.** Decided on 2026-11-09.
- **Implementation language: Odin.** Accepted by the owner on 2026-11-09 ("odin ok"). The owner checks if they have access to the Jai beta. A UEFI program in Odin was proven to start under QEMU with OVMF.
- **First use: a dedicated machine. No compatibility at first.** Decided on 2026-11-09. POSIX and Win32/NT layers are possible later, above the base interface.
- **The console is a normal program with a real language. No TTY concept.** Decided on 2026-11-09.
- **Do not go too fast.** The owner asked for architecture and key systems before any code. See `ARCHITECTURE.md`.
- **A command is a function. No text between programs.** Decided on 2026-11-09. No `argv`, no text pipes, no parsing. A command line program and a library are the same unit; the metadata makes each exported function callable from the console. A started program receives a structured context, never `argc` and `argv`. See property 19.
- **No system contract depends on a feature of one language.** Decided on 2026-11-09. Odin is the implementation language, not part of the interface. Contracts are memory layouts and numbers.
- **The removal of the shared file system is a security requirement**, not a preference (owner, 2026-11-09). Property 20 lists the other cases of ambient access to close. The owner accepted the whole list.
- **Zero is initialization (ZII).** Named by the owner on 2026-11-09. An all-zero record is valid in every system contract. See property 13.
- **Persistence: no save action; storage keeps versions for all programs.** Decided on 2026-11-09. See property 9.
- **Conversation in English** from 2026-11-09, at the owner's request, to keep one term per concept.
- **`GLOSSARY.md` defines the terms.** Use each term as defined and no synonym. Add a term there before using it.
- **The loader reads flat tables; SQLite is an index.** Accepted on 2026-11-09. See property 12.
- No pull request unless the owner asks.

## Research

Notes are in `research_notes/Jonathan Blow OS et kernel data oriented/`.

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
- 19 of the 36 transcripts were not read. Their subjects are Windows defects and general programming.
- Upload dates are known. Stream dates are not, except `bQnB6eI8DU4` (2026-04-11).
- The "On the Metal" podcast episode with Blow (2020) was not transcribed. It discusses microkernels and dynamic linking.
- No research exists on executable formats, linkers and loaders. Property 10 needs it.
- DBOS details and the licences in the reuse list of `PROPERTIES.md` come from memory.

## Next steps

1. Get the owner's decisions listed at the end of `PROPERTIES.md`.
2. Research executable formats, linkers and loaders for property 10.
3. Write the design of the first milestone in `PROPERTIES.md`: boot, two isolated units, one shared ring.
4. Set up the build as commands of an Odin tool, if the owner accepts Odin.
