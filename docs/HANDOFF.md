# Hand-off

This file is no longer the record of the decisions. Each thing that it held is now in one of these places:

- The decisions, with their words, dates and state: `DECISIONS.md`. Its table "Old HANDOFF numbers" maps each "HANDOFF item N" and each old rule to its identifier.
- The reports of the steps: `REVIEWS.md` and `CHANGELOG.md`.
- The order of the next steps: `FIRST_MILESTONE.md`, "Next steps".
- The two parts below have no other home yet.

## Work that is not yet in "Next steps"

Each item is the "not done yet" of a decision. Move it to `FIRST_MILESTONE.md`, "Next steps", when it is ordered.

1. The measures on a quiet host: the windows, `flood`, the calls, the SIMD forms on the machine, the costs of QUIC (D-190, D-100).
2. The cleanup of the comments in the code, and its check in `kerneltool check` (D-059).
3. The research on identity across machines (D-006).
4. A check of the licences in the reuse list of `PROPERTIES.md`, which also names `gui_toolkit` and a TCP library that the system does not use (C-12, C-14).
5. The animations of the mark: a shorter cycle and two scratching animations (D-181).
6. A documentation in the form of the Odin site (D-182).
7. LLVM 22, with a measure (D-162).

## Research

Notes are in `research/`.

| Subject | File | State |
|---|---|---|
| Blow, statements read at the source | `blow_verified_statements.md` | Done. 17 design clips read. Use this file for citations |
| Blow, transcripts | `transcripts/` | 36 videos, automatic captions, index in `transcripts/README.md` |
| Blow, first survey from secondary sources | `blow_os_kernel.md` | Superseded for design items. Still useful for posts, critiques and rebuttals |
| Handmade community | `handmade_sphere_os.md` | Done |
| Data-oriented kernel patterns | `data_oriented_kernel.md` | Done. [V] is verified, [R] is recalled |
| Ideas from Linux, NT and research kernels | `existing_kernels_good_ideas.md` | Done. About 40% of URLs verified |
| bcachefs and storage | `bcachefs_storage.md` | Done |
| RAD Linker and RDI | `rad_linker_rdi_study.md` | Done. Nothing was built or run |

Limits of the research:

- Transcripts are automatic captions. Check the video before you publish a quote as exact.
- All 36 transcripts are read. `blow_remaining_transcripts.md` holds the statements from the 21 that were read last.
- Upload dates are known. Stream dates are not, except `bQnB6eI8DU4` (2026-04-11).
- The "On the Metal" podcast episode with Blow (2020) was not transcribed. It discusses microkernels and dynamic linking.
- No research exists on executable formats, linkers and loaders beyond the RAD Linker study. Property 10 needs it.
- DBOS details and the licences in the reuse list of `PROPERTIES.md` come from memory.
- The author of Slug disclaimed the rest of the term of its patent on 2026-03-17. An agent read his post and two reports, not the record of the patent office.
