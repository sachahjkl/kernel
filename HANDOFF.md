# Hand-off: kernel design research

Written 2026-11-09 for whichever agent picks this up next. Nothing in this
repo is code yet; the work so far is research toward a design.

## What the owner wants

A new kernel that breaks with current designs while keeping the proven ideas
of Linux, NT (and its native layer), and others. Starting point: the OS and
kernel ideas Jonathan Blow has described in streams and interviews. Central
theme: data-oriented design, meaning full awareness of the CPU/memory speed
gap and optimisation for cache lines. End goal: a desktop environment and
user programs.

**The owner's first request, before any design or code: a very clear plan of
the properties the kernel is built on.** That plan has not been written yet.
It is the next deliverable.

### Properties the owner has stated so far

1. **Sandboxing by default.** A program can reach nothing it was not
   explicitly given.
2. **Kernel off the hot path.** Avoid going through the kernel for operations
   such as talking to the network interface.
3. **Simple, maximal inter-process communication.** Simplify and lean hard on
   the IPC mechanism.
4. **No global, mutable, shared filesystem** as a concept programs rely on.
5. **A proper storage engine underneath.** Either fork bcachefs or take
   strong inspiration from it. Open issue: bcachefs is GPL-2.0 and this repo
   is MIT, so a fork forces a licence decision that belongs to the owner.
6. **Uniform position-independent code units.** One binary/code format, all
   position-independent, so that static and dynamic linking stop being
   different things: any piece of code can be swapped whether it was bundled
   or bound at load time.
7. **Data-oriented throughout** (cache lines, batching, flat tables over
   pointer chasing).

The owner ended the list with "etc., etc.", so it is not closed. Additional
properties drawn from the research should be offered as proposals for the
owner to accept or reject, not presented as decided.

Open design questions already raised with the owner on property 6:
where cross-unit inlining/LTO is allowed (it destroys replaceability);
whether the loader patches inter-unit calls into direct calls (faster, but
pages stop being shared between processes); whether units are identified by
content hash (gives sharing without a global library directory).

## Rules from the owner

- **Never commit under an AI identity.** No AI author, committer,
  `Co-Authored-By`, or session trailer. Commits carry the owner's identity
  only (same as the initial commit). The container's default git identity is
  an AI one, so override both author and committer explicitly.
- **Deliverables in English.** The owner writes in French.
- Work on branch `ccr-9f9d1e64-odx4pm`. No pull request unless asked.

## State of the research

Notes live in `research_notes/Jonathan Blow OS et kernel data oriented/`.

| Thread | File | State |
|---|---|---|
| Blow's own OS/kernel statements | `blow_os_kernel.md` | Done |
| Handmade sphere (Muratori, Fleury, Essence, Serenum, allocators) | `handmade_sphere_os.md` | Done |
| Data-oriented and cache-conscious kernel patterns | `data_oriented_kernel.md` | Was still running at hand-off; absent unless a later commit added it |
| Good ideas from Linux, NT, and radical alternatives | `existing_kernels_good_ideas.md` | Same |
| bcachefs and storage design (fork vs port vs reimplement) | `bcachefs_storage.md` | Same |

No research was commissioned on executable formats, linkers and loaders
(property 6). That is a gap.

### Caveats on what was found

- **No video was read directly.** YouTube, transcript sites and X were
  blocked in the research environment. Blow's concrete design list rests on
  one third-party set of viewing notes (paritybit.ca) for two clips:
  - "Jonathan Blow on how an operating system should work":
    https://www.youtube.com/watch?v=k0uE_chSnV8
  - "Jonathan Blow on Drivers":
    https://www.youtube.com/watch?v=xXSIs4aTqhI

  Their content is unverified and there are no timestamps. Someone watching
  those two clips would turn the secondary items into verified ones.
- **Attributed to Blow (secondary):** no drivers in the kernel; a minimal
  kernel interface; processes communicating through mapped memory instead of
  syscalls; processes "super-sandboxed" by default; a TCP stack as a
  per-process library; no installation, registry or PATH; all code
  position-independent with a single library type.
- **Not attested for Blow:** explicit per-program filesystem views, any
  scheduler design, any data-oriented kernel internals, a new executable
  format. Those parts of the plan are the owner's own design.
- Blow has never announced an OS project of his own.
- In the Handmade notes, the mapping from allocator design (arenas,
  caller-supplied memory) to syscall design is the researcher's inference,
  labelled as such. "Dawn" as a Handmade OS project and "the OS as a
  library" as a Muratori phrase could not be confirmed; do not attribute
  them.

## Next steps

1. Check whether the three missing note files exist; rerun those threads if
   not.
2. Write the properties plan the owner asked for, in English. For each
   property: precise definition, what it forbids, what it costs, precedents
   (Blow, NT, Linux, research systems), and tensions with the other
   properties. Mark sourced claims versus design reasoning.
3. Then a full synthesis report at
   `reports/Jonathan Blow OS et kernel data oriented.md` (planned, not
   written).
4. Get the owner's decisions on: the licence question for bcachefs, and the
   three open questions on property 6.
