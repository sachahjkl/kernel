# Decisions

This file is the record of the decisions of the project: who decided what, when, and in which words. Read it first. `PROPERTIES.md` holds the 21 properties. `GLOSSARY.md` defines the terms.

## How to read and write this file

- Each decision has an identifier `D-nnn`. An identifier never changes and is never used again.
- Each entry gives the date, who decided, the decision, the words of the owner, the state and where the decision is carried out.
- "The owner" is the owner of the project. "The coordinator" is the agent session that reviews, merges and keeps the documents. "An agent" is a session that writes code on a branch.
- A decision of the coordinator or of an agent holds until the owner reverses it. The entry says so.
- The words of the owner stay in their language and are exact. `[...]` marks a cut. A reading of a dictated or garbled phrase is in square brackets.
- The state is one of: in force; done; not done yet; replaced by D-nnn; open (see "Open questions for the owner").
- "Where" names the guide and its section, the choices of `FIRST_MILESTONE.md` by number, and the step of `REVIEWS.md`. The technical detail is in the guide. The story of the work is in `REVIEWS.md`.
- A decision that a later one replaced stays here, marked "replaced by", with the pointer.
- To record a new decision: give it the next free identifier, put it at the end of its group, and write the rule in the guide of its subject with no name of a person, a role, a step or a date.
- Older records cite "HANDOFF item N". The table "Old HANDOFF numbers" at the end gives the identifier for each such number.

## Groups

1. [The principles, the properties and the contracts](#1-the-principles-the-properties-and-the-contracts): D-001 to D-039, D-191
2. [The way of working](#2-the-way-of-working): D-040 to D-070, D-190
3. [The kernel](#3-the-kernel): D-071 to D-083
4. [Memory](#4-memory): D-084 to D-088
5. [The scheduler](#5-the-scheduler): D-089 to D-091
6. [Storage](#6-storage): D-092 to D-095
7. [The network and QUIC](#7-the-network-and-quic): D-096 to D-100
8. [Cryptography and randomness](#8-cryptography-and-randomness): D-101 to D-105
9. [The interface, the fonts, the mark and the design](#9-the-interface-the-fonts-the-mark-and-the-design): D-106 to D-141, D-192, D-193
10. [The console and the tools](#10-the-console-and-the-tools): D-142 to D-148
11. [The build and the compiler](#11-the-build-and-the-compiler): D-149 to D-162
12. [The site and the publication](#12-the-site-and-the-publication): D-163 to D-185, D-194, D-195
13. [The name and the repository](#13-the-name-and-the-repository): D-186 to D-189
14. [Open questions for the owner](#open-questions-for-the-owner)
15. [Conflicts](#conflicts)
16. [Old HANDOFF numbers](#old-handoff-numbers)

## 1. The principles, the properties and the contracts

### D-001 The goal of the project
- 2026-11-09. Decided by: the owner.
- Decision: build a new kernel that breaks with current designs and keeps the proven ideas of Linux, NT and others. The start is the set of ideas that Jonathan Blow described on stream. The central theme is data-oriented design. The end goal is a desktop environment and user programs. Reuse existing software where it fits.
- Words: none recorded.
- State: in force.
- Where: `PROPERTIES.md`, "Objective".

### D-002 The 21 properties
- 2026-11-09. Decided by: the owner.
- Decision: the 21 properties of `PROPERTIES.md` are accepted. Properties 4, 7, 14, 15 and 16 are accepted as written.
- Words: none recorded.
- State: in force. Later changes of a property are dated in the property itself.
- Where: `PROPERTIES.md`.

### D-003 Performance is a criterion at every level
- 2026-11-09. Decided by: the owner.
- Decision: performance is a criterion at every level, the build tools too. Slow software is rejected.
- Words: none recorded.
- State: in force.
- Where: each guide gives its measures; `kerneltool measure`.

### D-004 "Everything is a file" is rejected
- 2026-11-09. Decided by: the owner.
- Decision: the system does not use the model "everything is a file".
- Words: none recorded.
- State: in force.
- Where: `PROPERTIES.md`, property 8.

### D-005 No shared file system, as a security requirement
- 2026-11-09. Decided by: the owner.
- Decision: the removal of the shared file system is a security requirement, not a preference. The list of the other cases of ambient access in property 20 is accepted whole.
- Words: none recorded.
- State: in force.
- Where: `PROPERTIES.md`, properties 8 and 20.

### D-006 Principals and sessions, no users
- 2026-11-09. Decided by: the owner.
- Decision: the kernel has no concept of who executes. Principals and sessions define it.
- Words: none recorded.
- State: in force. Principals are not built. The research on identity across machines is not done yet.
- Where: `PROPERTIES.md`, property 21; `FIRST_MILESTONE.md`, "Next steps", item 12.

### D-007 Usability concessions for the desktop
- 2026-11-09. Decided by: the owner.
- Decision: concessions for usability are accepted on the desktop. They must not ruin the security model.
- Words: none recorded.
- State: in force.
- Where: `PROPERTIES.md`, property 20.

### D-008 Zero is initialization
- 2026-11-09. Decided by: the owner (the owner named it "ZII").
- Decision: an all-zero record is valid in every system contract.
- Words: none recorded.
- State: in force.
- Where: `PROPERTIES.md`, property 13.

### D-009 64 bits only
- 2026-11-10. Decided by: the owner.
- Decision: an address is 64 bits. The system has no 32-bit target and no 32-bit program. The targets are x86-64 first, and ARM64 at best. An address, a count and a register value have one size, and a record has one layout.
- Words: none recorded.
- State: in force.
- Where: `PROPERTIES.md`, "Assumptions"; `MODULE_CONTRACT.md`.

### D-010 The first machine is QEMU with virtio
- 2026-11-09. Decided by: the owner.
- Decision: the first machine is QEMU with virtio devices. Hardware is not the main problem.
- Words: none recorded.
- State: in force.
- Where: `PROPERTIES.md`, property 7.

### D-011 A dedicated machine, with no compatibility at first
- 2026-11-09. Decided by: the owner.
- Decision: the first use is a dedicated machine. The system has no compatibility layer at first. POSIX and Win32/NT layers are possible later, above the base interface.
- Words: none recorded.
- State: in force.
- Where: `PROPERTIES.md`, "Objective".

### D-012 The TPM, UEFI programs and Secure Boot
- 2026-11-09. Decided by: the owner.
- Decision: the system uses the TPM, UEFI programs ("rich boot") and Secure Boot.
- Words: none recorded.
- State: not done yet (trusted boot is in the list of next work).
- Where: `PROPERTIES.md`; `FIRST_MILESTONE.md`, "Next steps", item 12.

### D-013 The ARM64 port is not a priority
- 2026-11-11. Decided by: the owner.
- Decision: do not start the ARM64 port unless the owner asks for it.
- Words: none recorded.
- State: in force.
- Where: this file.

### D-014 No system contract depends on a feature of one language
- 2026-11-09. Decided by: the owner.
- Decision: Odin is the implementation language, not a part of the interface. Contracts are memory layouts and numbers.
- Words: none recorded.
- State: in force.
- Where: `MODULE_CONTRACT.md`.

### D-015 A command is a function
- 2026-11-09. Decided by: the owner.
- Decision: no `argv`, no text pipes and no parsing between programs. A command line program and a library are the same module. The metadata makes each export callable from the console. A started program receives a structured context.
- Words: none recorded.
- State: in force.
- Where: `PROPERTIES.md`, property 19.

### D-016 No standard input and no standard output
- 2026-11-10. Decided by: the owner (confirmed the answer of the coordinator).
- Decision: a program has no ambient stream of bytes. The input of a command is its typed parameters; its output is its typed result. A flow of data in time is a ring of records with a description, given as a grant. The context has no place "input", "output" or "error".
- Words: none recorded.
- State: in force.
- Where: `PROPERTIES.md`, properties 6, 19 and 20.

### D-017 One module is all of them
- 2026-11-10. Decided by: the owner.
- Decision: a command line program, a library and a dynamic library are the same module. One program exports its capabilities with the metadata of their documentation, and one program shows the documentation of any module, with the names and types of the parameters.
- Words: none recorded.
- State: done (programs `tally` and `manual`).
- Where: `FIRST_MILESTONE.md`, choices 82 to 86.

### D-018 Relocatable modules give reproducibility
- 2026-11-09. Decided by: the owner.
- Decision: relocatable modules also give reproducibility, in the manner of NixOS. One build gives one hash.
- Words: none recorded.
- State: done; each full check checks it.
- Where: `PROPERTIES.md`, properties 10 and 11; `REPRODUCIBLE_BUILD.md`; `FIRST_MILESTONE.md`, choice 189 (step 38).

### D-019 The module contract is a proposal
- 2026-11-09. Decided by: the owner (a first reaction).
- Decision: `MODULE_CONTRACT.md` is the proposal for the contract between modules. The first reaction of the owner is positive. Its four decisions are not confirmed.
- Words: none recorded.
- State: open (question Q-02).
- Where: `MODULE_CONTRACT.md`.

### D-020 The closed rules of the module contract
- 2026-11-09. Decided by: the owner.
- Decision: no intermediate form of code; private module data and no code before the entry; one level of nested data across a ring; no thread-local data in the contract; no unwinding, and frame pointers are required; the kernel is a module.
- Words: none recorded.
- State: in force.
- Where: `MODULE_CONTRACT.md`, "Closed rules".

### D-021 The call form: registers
- 2026-11-09. Decided by: the coordinator (the owner delegated the choice). The owner can reverse it.
- Decision: the call form is a scalar-only subset of the register assignment of the machine.
- Words: none recorded.
- State: in force.
- Where: `MODULE_CONTRACT.md`, section 4.

### D-022 Exports are functions; a stream is a handle
- 2026-11-09. Decided by: the owner.
- Decision: an export is a function and nothing else. A stream is a handle.
- Words: none recorded.
- State: in force.
- Where: `MODULE_CONTRACT.md`; `ARCHITECTURE.md`.

### D-023 The loader reads flat tables
- 2026-11-09. Decided by: the owner.
- Decision: the loader reads flat tables. On 2026-11-10 the flat tables became the only format of the module metadata, with no index (D-024).
- Words: none recorded.
- State: in force.
- Where: `PROPERTIES.md`, property 12.

### D-024 No SQLite; functions that give the information of the modules
- 2026-11-10. Decided by: the owner.
- Decision: SQLite is removed from the system. In its place, a rich API of documented functions gives the information of the modules, for a program and for the console. The results are tables of records that the console combines with no query language.
- Words: recorded in English only: "a thousand times simpler than a language to manage".
- State: done (step 36).
- Where: `PROPERTIES.md`, properties 9 and 12; `FIRST_MILESTONE.md`, choices 172 to 182.

### D-025 The interfaces push to data-oriented programs
- 2026-11-10. Decided by: the owner (the principle); the coordinator (the four consequences).
- Decision: the interfaces of the system make data-oriented programs the easy path. Each interface gives and takes tables of fixed-size records in memory of the caller, many in one call. Tables pass as parameters. Memory tools serve tables and arenas. A program can read the counters of the processor for its own threads.
- Words: none recorded.
- State: in force. Done: tables as parameters (D-030), the memory tools (D-085). Not done yet: the processor counters for a program.
- Where: `MODULE_CONTRACT.md`; `ARCHITECTURE.md`.

### D-026 The replacement of an import
- 2026-11-10. Decided by: the owner, with two conditions of the coordinator that keep properties 11 and 19.
- Decision: the system can force the module that a program receives for an import. The loader checks the compatibility from the descriptions and does not trust a claim. The replacement is a visible fact of the program that runs.
- Words: none recorded.
- State: done (steps 33 to 35).
- Where: `MODULE_CONTRACT.md`, "Replacement of an import"; `FIRST_MILESTONE.md`, choices 160 to 171.

### D-027 No exceptions in the contracts
- 2026-11-10. Decided by: the owner.
- Decision: no contract of the system uses an exception to tell an error. An error is a value that the call gives back; a fault stops the program. No exception leaves a function of a module. No global `errno`. Errors are robust, descriptive and informative.
- Words: none recorded.
- State: in force.
- Where: `MODULE_CONTRACT.md`, rule 8.

### D-028 System errors that diagnose
- 2026-11-10. Decided by: the owner (the requirement); the coordinator (the design).
- Decision: a refusal is never a short code with no context. A failed call gives a detail record: the operation, the parameter, the handle and its kind, the missing right or the limit, and the origin of the handle. A record never gives a fact that the caller has no right to see. Modules first: load, bind, replace, unload and run each explain a failure.
- Words: none recorded.
- State: done (step 42; error records in the rings and services at step 57). Not done yet: the error records of some other services.
- Where: `MODULE_CONTRACT.md`; `FIRST_MILESTONE.md`, choices 227 to 248 and 379 to 389.

### D-029 A program that shows the errors
- 2026-11-10. Decided by: the owner.
- Decision: a program with a window has one button for each case of error. A press makes the error for real, inside a module, and the window shows the report of the system. The cases: a refused right, a revoked handle, a budget with no pages, a failed load, a fault with its stack trace.
- Words: none recorded.
- State: done (the program `errors`, step 42).
- Where: `FIRST_MILESTONE.md`, choices 227 to 248.

### D-030 Tables and bytes as parameters of an export
- 2026-11-11. Decided by: the owner.
- Decision: an export takes a table of records or a run of bytes, to read, to change or to append to, in memory of the caller. One description serves a direct call, an isolated call and a service.
- Words: "ok bah on le fait alors ? y'a une complexité de mise en forme de l'api que je dois t'aider à résoudre ? sinon go."; then "go".
- State: done (step 65).
- Where: `MODULE_CONTRACT.md`, "Tables and bytes as parameters"; `FIRST_MILESTONE.md`, choices 417 to 430.

### D-031 The count of an Append table across calls
- 2026-11-11. Decided by: the coordinator, after an independent read. The owner can reverse it.
- Decision: the count of an Append table is the count of the full answer across calls.
- Words: none.
- State: in force.
- Where: `MODULE_CONTRACT.md`, "Tables and bytes as parameters".

### D-032 An optional table of error details
- 2026-11-11. Decided by: the owner.
- Decision: a caller can give a table of error details in its own memory. The receiver appends one detail record (the seven integers of an error record) for each thing to say. The count is the count of the full answer. A caller with no table pays nothing. No text and no address in a detail.
- Words: "on est d'accord que maintenant les erreurs elles fournissent un code et du contexte qui peut être flexible"; then "l'idée d'une table de détails c'est exactement ce que j'avais en tête c'est optionnel du coup mais ce serait la manière la plus gracieuse je pense de genre sans faire exploser les performances de fournir du détail sur les erreurs".
- State: done for the exports (step 71). The kernel operations: see D-033.
- Where: `MODULE_CONTRACT.md`, "The table of error details"; `FIRST_MILESTONE.md`, choice 470.

### D-033 Error details for the kernel operations wait for a measure
- 2026-11-11. Decided by: the coordinator. The owner decides after a measure.
- Decision: the design for the kernel operations is one bit of the kind of a command. It costs one instruction on every command, so it is not built before a measure and the answer of the owner.
- Words: none.
- State: open (question Q-06).
- Where: `MODULE_CONTRACT.md`, "The table of error details".

### D-034 The context of a program has 24 values
- 2026-11-11. Decided by: the coordinator. The owner can reverse it.
- Decision: the context of a program has 24 values. The values 16 to 23 are the roles that the system fixes for every program. A new role takes a number there.
- Words: none.
- State: done (step 70).
- Where: `FIRST_MILESTONE.md`, choices 460 to 469; the reference table of the roles on the site.

### D-035 No size of a cache goes through the context
- 2026-11-12. Decided by: the coordinator. The owner can reverse it.
- Decision: one context value is the set of the fixed ranges that the starter mapped. A cache states its size in its header. The settings page and the date page use the same set. The values 13, 15, 21, 22 and 23 have no role.
- Words: none.
- State: done (step 79).
- Where: `FONTS.md`; `FIRST_MILESTONE.md`, choices 533 to 540.

### D-036 One table of fixed addresses
- 2026-11-11. Decided by: the coordinator, after two collisions.
- Decision: one table holds the fixed addresses of the mappings that the system gives a program (`contract/fixed_addresses`). A check at compile time refuses two ranges that overlap.
- Words: none.
- State: done (step 74).
- Where: `FIRST_MILESTONE.md`, choices 488 to 499.

### D-037 The settings page holds a look and nothing else
- 2026-11-11. Decided by: an agent, after an independent read; the coordinator accepted it.
- Decision: a program that holds the settings chooses a look and nothing else. The settings page holds no address and no size of a cache.
- Words: none.
- State: done (step 74).
- Where: `FIRST_MILESTONE.md`, choices 500 to 504.

### D-038 A text is never cut in silence
- 2026-11-12. Decided by: the coordinator, from the rule of the owner that an error informs (D-027, D-028).
- Decision: no helper of the system cuts a text without saying so. A text that does not fit is written whole in parts, or ends with the one cut mark of the system, or is refused with an error. A text cut to its box on the screen is not this fault.
- Words: none.
- State: done (step 84). Not done yet: the other callers of `name_pack`.
- Where: `ARCHITECTURE.md`, "A text is never cut in silence"; `FIRST_MILESTONE.md`, choices 565 to 569.

### D-039 A fault of a program never stops the machine
- 2026-11-11. Decided by: the coordinator, from property 2, after Review 10.
- Decision: a program cannot stop the machine. A thread entry or a stack that is not an address of a program is refused. A fault at the return to a program is a fault of that program.
- Words: none.
- State: done (step 68 for the first cause; the refused return in choices 590 to 592).
- Where: `ARCHITECTURE.md`, "The return to a program"; `FIRST_MILESTONE.md`, choices 590 to 592.

### D-191 No backward compatibility
- 2026-11-11. Decided by: the owner (the global rules of the owner).
- Decision: obsolete paths are removed. No compatibility layer, fallback or migration is added for an older format of the system.
- Words: "Do not preserve backward compatibility" (the global rules of the owner).
- State: in force (applied in D-095 and in the formats of `MODULE_CONTRACT.md`).
- Where: `AGENTS.md`; `MODULE_CONTRACT.md`, "The format".

## 2. The way of working

### D-040 Do not go too fast
- 2026-11-09. Decided by: the owner.
- Decision: architecture and key systems come before any code.
- Words: none recorded.
- State: replaced by D-042 for the order of the work. `ARCHITECTURE.md` was written before the code.
- Where: `ARCHITECTURE.md`.

### D-041 More research before design or code
- 2026-11-09. Decided by: the owner.
- Decision: the next step was more research before design or code.
- Words: none recorded.
- State: done, then replaced by D-042.
- Where: `docs/research/`.

### D-042 Work to the end, with no pause, and a review after each five steps
- 2026-11-10. Decided by: the owner.
- Decision: do the planned steps and the steps that follow from the properties, with no question to the owner between steps. After each five steps, review the work against the properties and the rule "no bad compromise", and write the result in `REVIEWS.md`.
- Words: "I want everything." (recorded in English).
- State: in force.
- Where: `REVIEWS.md`.

### D-043 The review of the choices by the owner
- 2026-11-10. Decided by: the coordinator (a proposal).
- Decision: the owner reviews the numbered choices of `FIRST_MILESTONE.md`.
- Words: none.
- State: open (question Q-01).
- Where: `FIRST_MILESTONE.md`, "Choices made during the implementation".

### D-044 The direction of the work
- 2026-11-10. Decided by: the owner.
- Decision: continue the fundamental mechanisms of the kernel and the desktop programs that use them. Programs supply base services to other programs. Show persistent programs. Each mechanism has a scenario in the machine test; a server is a good scenario. The network stack (UDP, TCP, QUIC) is very important.
- Words: none recorded.
- State: in force.
- Where: `FIRST_MILESTONE.md`, "Next steps"; `NETWORK.md`.

### D-045 Show the concepts
- 2026-11-10. Decided by: the owner.
- Decision: add the interfaces for communication between programs and for several threads, and show each one with a picture.
- Words: none recorded.
- State: done (`rings`, `threads`, `workers`; steps 2, 4 and 5).
- Where: `DEMONSTRATIONS.md`.

### D-046 No bad compromise
- 2026-11-10. Decided by: the owner.
- Decision: the isolated call, and each later step, is built with no bad compromise. Each review looks for bad compromises.
- Words: "no bad compromise" (recorded in English).
- State: in force. The isolated call is done (step 1).
- Where: `MODULE_CONTRACT.md`, section 4; `REVIEWS.md`.

### D-047 Push back
- 2026-11-10. Decided by: the owner.
- Decision: if a proposal of the owner contradicts a property or a recorded decision, say so before any work, name it, and propose the nearest form that keeps it. The owner decides. A kept proposal changes the documents first.
- Words: none recorded.
- State: in force.
- Where: `AGENTS.md`, "Push back".

### D-048 The order of the steps
- 2026-11-10. Decided by: the owner (the coordinator gave the order on 2026-11-10; the owner accepted the lists on 2026-11-11 and 2026-11-12).
- Decision: the order is the list "Next steps" of `FIRST_MILESTONE.md`. A new subject goes in this list. The step in progress ends first. WebGPU is last.
- Words: "Ok avec la liste, webgpu en dernier." (2026-11-11); "yes" (2026-11-12, to the list: xsave, the measures on a quiet host, text shaping, the mark, the console history, QUIC, the kernel items, Review 10, the rename, the site then the film, trusted boot, WebGPU last).
- State: in force.
- Where: `FIRST_MILESTONE.md`, "Next steps".

### D-049 Never commit under an AI identity
- 2026-11-09. Decided by: the owner.
- Decision: no AI author, committer, `Co-Authored-By` or session trailer. Commits carry the identity of the owner only.
- Words: none recorded.
- State: in force.
- Where: `AGENTS.md`.

### D-050 English for the deliverables and the conversation
- 2026-11-09. Decided by: the owner.
- Decision: the deliverables are in English. The conversation is in English, to keep one term for one concept. The owner writes in French.
- Words: none recorded.
- State: in force.
- Where: `AGENTS.md`.

### D-051 The glossary defines the terms
- 2026-11-09. Decided by: the owner.
- Decision: `GLOSSARY.md` defines the terms. Use each term as defined and no synonym. Add a term before its first use. The code format is a "module", not a "unit".
- Words: none recorded.
- State: in force.
- Where: `GLOSSARY.md`; `AGENTS.md`.

### D-052 Nothing goes upstream and no pull request without the owner
- 2026-11-10. Decided by: the owner.
- Decision: no pull request unless the owner asks. Nothing is opened upstream without the owner.
- Words: none recorded.
- State: in force. One exception at the request of the owner: D-105.
- Where: this file.

### D-053 Agents in parallel
- 2026-11-10. Decided by: the owner.
- Decision: agents with the model Opus 5.5 can work on steps at the same time. Each agent works in its own git worktree on its own branch and does not push. The coordinator reviews each branch, merges one branch at a time onto `master` with the full check, numbers the choices and writes the row of the review.
- Words: none recorded.
- State: in force; see D-054.
- Where: `REVIEWS.md`.

### D-054 A subagent that writes code only writes code
- 2026-11-11. Decided by: the owner (the global rules of the owner).
- Decision: a subagent that writes code does not build, test, lint, commit or merge. The coordinator reviews, or sends the review to a new review subagent, then builds, tests, commits and merges. A problem starts a new round.
- Words: none recorded.
- State: in force.
- Where: `AGENTS.md`.

### D-055 A brief quotes the rule word for word
- 2026-11-10. Decided by: the coordinator, after a wrong rule in a brief ("Odin standard library only" was a rule for the kernel tool only).
- Decision: a brief for an agent quotes the recorded rule word for word.
- Words: none.
- State: in force.
- Where: `REVIEWS.md`, Review 6.

### D-056 An independent read before the merge of hard code
- 2026-11-11. Decided by: the coordinator. The owner can reverse it.
- Decision: concurrent kernel code and code that reads the network get an independent read before the merge. Two reads after a merge found blocking faults.
- Words: none.
- State: in force.
- Where: `REVIEWS.md`, Review 8 and step 56.

### D-057 A test that fails once is read to its cause
- 2026-11-12. Decided by: the coordinator, after a wrong reading of a QUIC failure.
- Decision: a test that fails once under load is read to its cause before it is called a flake.
- Words: none.
- State: in force.
- Where: `REVIEWS.md`, step 85.

### D-058 Long, descriptive names
- 2026-11-11. Decided by: the owner.
- Decision: no esoteric, over-compressed name of a type, a function, a field or a file. Use long, descriptive names of complete words. The rule applies to new names. `memcpy`, `memmove` and `memset` stay only as the names that the compiler calls.
- Words: "justement, je suis pas sûr de vouloir garder les noms memcpy/memove et memset. on peut fournir des alias/wrapper dans un layer de compat mais je préferais un clean break au niveau des nommages. à inscire: ne PAS faire des noms de types/functions ésotoriques surcompressés (eg. memcpy), au contraire, ne pas avoir peur d'avoir des noms LONGS et descriptifs (à la jon blow) !"
- State: in force.
- Where: `AGENTS.md`.

### D-059 Comments in code give the reason in plain words
- 2026-11-11. Decided by: the owner (accepted the rule of the coordinator).
- Decision: a comment gives the reason itself. It names no number of a property, a choice, a step or a review finding, and no date of a decision. A pointer to a document is allowed. The ChaCha20 code copied from Odin is not touched.
- Words: "euh ne pas mentionner nos \"propriétés\" dans les commentaires non ? exemple \"(property 10)\""; then "je suis okay avec ta suggestion".
- State: in force for new code. Not done yet: the cleanup of the whole code and the check in `kerneltool check` (56 lines with "(property N" remain in the sources on 2026-11-12).
- Where: `AGENTS.md`.

### D-060 A development log out of the repository
- 2026-11-10. Decided by: the owner.
- Decision: keep all the screenshots in a folder out of the repository. `kerneltool screenshots` copies the pictures of each run to a new folder of `../kernel-devlog`, named with the time in UTC. The rule of the posts (D-183) applies to these pictures.
- Words: none recorded.
- State: in force; extended by D-061.
- Where: `TOOLS.md`.

### D-061 Each picture that is viewed goes to the devlog
- 2026-11-11. Decided by: the owner.
- Decision: each picture that the coordinator or an agent produces and views goes in `~/Projects/kernel-devlog`, in a dated folder (`<date>_<time>` for `master`, `<date>_<time>_branch_<name>` for a branch, in UTC). No folder of the devlog is deleted.
- Words: "Quand tu produits une image et que la lis, ne la supprime pas. Met la dans le dossier de devlog."
- State: in force.
- Where: `AGENTS.md`.

### D-062 A changelog
- 2026-11-11. Decided by: the owner (the changelog); the coordinator and an agent (the forms, which the owner can reverse).
- Decision: `CHANGELOG.md` in the format of Keep a Changelog 1.1.0. The release number is `0.N.0` for the merge of step N and `0.N.1` for a correction between two steps; the first milestone is `0.0.0`. The term is "release", not "version". The constant is `RELEASE_NUMBER` in `contract/release`. No git tag.
- Words: "J'ai oublié de te dire mais j'aimerai qu'on tienne un changelog, comme mes autres projets".
- State: done.
- Where: `changelog.d/README.md`; `CHANGELOG.md`.

### D-063 The changelog is made of fragments
- 2026-11-11. Decided by: the owner.
- Decision: each change that a reader notices is one fragment file in `changelog.d/`, so that two branches never change the same lines. The release command writes `CHANGELOG.md`. The global rules of the owner follow the same rule.
- Words: "Update the readme to fit the fragment rule, it's better", then "The global agents.md,* sorry".
- State: in force.
- Where: `changelog.d/README.md`; `AGENTS.md`.

### D-064 The first wait of a test machine is 180 s
- 2026-11-11. Decided by: the coordinator. The owner can reverse it.
- Decision: the first wait of each machine of the test (its boot) has a bound of 180 s, because a boot that is slow under the load of the host says nothing of the system. Every other step keeps 20 s.
- Words: none.
- State: in force.
- Where: `TOOLS.md`.

### D-065 The checks of the lock order and of the frame sums
- 2026-11-11. Decided by: the coordinator. The owner can ask for the checks in every build.
- Decision: the checks are on for `check`, `test`, `screenshots`, `measure` and `run`. They are off for `measure without_checks` and `run without_checks`.
- Words: none.
- State: in force.
- Where: `FIRST_MILESTONE.md`, choices 347 to 358.

### D-066 Several steps under one full check
- 2026-11-12. Decided by: the owner.
- Decision: several steps can be merged under one full check.
- Words: "pour l'étape 11 ça me va" [item 11 of the questions of the coordinator: several steps under one full check].
- State: in force.
- Where: `REVIEWS.md`.

### D-067 The record of the decisions replaces the handoff
- 2026-11-11. Decided by: the owner (accepted the proposal of the coordinator).
- Decision: `docs/DECISIONS.md` is the record of the decisions and what an agent reads first. The step reports stay in `REVIEWS.md` and `CHANGELOG.md`. The things to do go to "Next steps" of `FIRST_MILESTONE.md`. `AGENTS.md` points to `DECISIONS.md`.
- Words: "et le handoff faut peut-être qu'on s'en sépare voilà au bout d'un moment"; then "oui vas-y".
- State: done (2026-11-12). The proposal said "one line for each decision"; an entry here is a few lines (conflict C-11).
- Where: this file; `AGENTS.md`.

### D-068 The site publishes only the guides that explain the system
- 2026-11-12. Decided by: the owner.
- Decision: the guides that the site publishes are the documents that explain the system. The working records are not published.
- Words: "oui évidemment".
- State: in force.
- Where: `SITE.md`, "The pages".

### D-069 A guide never names who decided
- 2026-11-12. Decided by: the owner.
- Decision: a guide never names a person or a role of the project, a step, a choice or a date of a decision. It states the rule. Who decided, when and in which words is in this file.
- Words: "go le faire mtnt" [rewrite the guides now with no who].
- State: in force; the guides are being rewritten.
- Where: `AGENTS.md`.

### D-070 A news entry never says "the owner"
- 2026-11-12. Decided by: the owner.
- Decision: a text of the site and a news entry never say "the owner". They state the fact.
- Words: « "The owner chose the slashed zero of Paper Mono." ces phrases à la con "the owner" bof »
- State: in force.
- Where: `news/README.md`; `AGENTS.md`.

### D-190 A measure under a high load of the host is not valid
- 2026-11-11. Decided by: the coordinator. The owner can reverse it.
- Decision: a speed measured at a host load above 8 is not valid as a speed. It is valid only one against the other in the same run.
- Words: none.
- State: in force. The measures on a quiet host are in the list of next work.
- Where: `MODULE_CONTRACT.md`, "Measures"; `REVIEWS.md`.

## 3. The kernel

### D-071 The kernel ring is the only kernel entry
- 2026-11-09. Decided by: the owner.
- Decision: the kernel ring is the only entry into the kernel.
- Words: none recorded.
- State: in force.
- Where: `PROPERTIES.md`, property 4; `ARCHITECTURE.md`.

### D-072 The kernel tool counts the kernel operations
- 2026-11-09. Decided by: the owner.
- Decision: the kernel tool counts the kinds of kernel operation, with no fixed limit.
- Words: none recorded.
- State: replaced by D-073 for the limit. The count stays.
- Where: `PROPERTIES.md`, property 1.

### D-073 The target of 32 kernel operations
- 2026-11-12. Decided by: the coordinator (the owner delegated it). The owner can reverse it.
- Decision: 32 operations is the first target of property 1. The coordinator raises the target when an operation needs it, and records the reason.
- Words: "fait ce qui est judicieux je pense que oui" [the coordinator decides].
- State: in force. The kernel has 32 operations (`Events_Set` is 32). The next operation past 32 is open (question Q-11).
- Where: `PROPERTIES.md`, property 1; `FIRST_MILESTONE.md`, choices 595 and 603.

### D-074 Several plain threads in each program
- 2026-11-09. Decided by: the owner (the rule); the coordinator (the form).
- Decision: do what Blow would do and do not complicate the execution model. A program has several plain threads.
- Words: recorded in English only: "do what Blow would do; do not complicate the execution model".
- State: done (step 4).
- Where: `ARCHITECTURE.md`, open question 6.

### D-075 All processors, with no single lock
- 2026-11-10. Decided by: the owner.
- Decision: the kernel runs on all processors, with no single lock as the final design. The split of the kernel lock by data is its own measured step.
- Words: none recorded.
- State: done (several processors with one lock at step 11, choices 30 to 34; the split at step 41, choices 210 to 226).
- Where: `ARCHITECTURE.md`.

### D-076 Full queues and speed
- 2026-11-10. Decided by: the owner (accepted all the proposals of the coordinator).
- Decision: a full queue slows the writer to the speed of the reader; a queue does not grow while it is in use. A ring takes its capacity at its creation; batches on both sides; a short spin before a wait; more readers before a larger queue; large data stays in shared memory; one lock for each kind of data. Each writer chooses: wait, drop or refuse.
- Words: none recorded.
- State: done (steps 17, 19 and 41).
- Where: `ARCHITECTURE.md`; `FIRST_MILESTONE.md`, choices 57 to 60 and 70 to 77.

### D-077 The log is records in channels
- 2026-11-10. Decided by: the owner (channels); the coordinator (no log service).
- Decision: the facts of the start go to the log in channels. A log record has a time, a program, a thread, a level, a channel and a text. The kernel is the one writer, because it sets the program of each record.
- Words: none recorded.
- State: done (choices 48 to 50). Not done yet: a limit of rate, a grant for one channel, the records on the boot display.
- Where: `ARCHITECTURE.md`; `FIRST_MILESTONE.md`, choices 48 to 50.

### D-078 Rights on handles, budgets and revocation
- 2026-11-10. Decided by: the coordinator, to carry out property 20.
- Decision: a handle carries rights. No kernel operation creates an object without a budget handle. A budget has limits of pages, processor time and log records. The kernel keeps the origin of each handle, and a revocation ends what came from it.
- Words: none.
- State: done (steps 9, 10, 25 and 26).
- Where: `GLOSSARY.md`, "Budget"; `FIRST_MILESTONE.md`, choices 27 to 29 and 105 to 124.

### D-079 Kernel events with a table of rules
- 2026-11-11. Decided by: the owner (accepted the proposal of the coordinator as a thing to do).
- Decision: no bytecode, no verifier and no compiler in the kernel. The kernel has fixed event points. A program with a grant gives a table of rules; the kernel applies it in bounded time and writes records in a ring.
- Words: "un truc comme ebpf est-ce qu'il y a des leçons en tirer pour nous ou est-ce que c'est un non sujet ou est-ce que on a déjà les facilités qui sont nécessaires pour mettre quelque chose en place d'équivalent"; then "ça me paraît intéressant je pense qu'on peut le mettre en tant que chose à faire".
- State: done (choices 603 to 615).
- Where: `ARCHITECTURE.md`, "Kernel events".

### D-080 The kernel saves the extended state with xsave
- 2026-11-11. Decided by: the owner.
- Decision: the kernel saves and restores the extended state of the processor with `xsave` and sets its control registers itself. Programs can use AVX and what else the processor has and the kernel saves.
- Words: "Nah évidemment qu'il faut donc ajouter le support mdrr. On va pas se faire artificiellement limiter par fxsave".
- State: done; the moment of the save is replaced by D-081.
- Where: `ARCHITECTURE.md`, "The extended state of the processor".

### D-081 The extended state is saved at a switch of threads only
- 2026-11-12. Decided by: the owner (accepted the redesign of the coordinator).
- Decision: the kernel saves and restores the extended state only when a processor leaves a thread for another. The kernel is built with no vector instruction, and a check of the tool refuses one outside the three procedures that save and restore.
- Words: "yes" (to "xsave: accept the redesign (item 6)? Yes.").
- State: done (step 81).
- Where: `ARCHITECTURE.md`, "The extended state of the processor"; `FIRST_MILESTONE.md`, choices 546 to 549.

### D-082 AMX waits for a program that needs it
- 2026-11-11. Decided by: the coordinator. The owner can reverse it.
- Decision: AMX is not enabled. It comes with a grant when a program needs it.
- Words: none.
- State: in force.
- Where: `SIMD.md`.

### D-083 The time and the date
- 2026-11-11. Decided by: the coordinator and an agent.
- Decision: the milliseconds of the time page come from the cycle counter, and a program reads a fine time with no kernel entry. A program `date` reads the clock of the machine and writes a date page that each program maps read-only.
- Words: none.
- State: done (steps 43 and 67). Not done yet: a read-only grant of the clock port for `date`.
- Where: `ARCHITECTURE.md`, "The date"; `FIRST_MILESTONE.md`, choices 249 to 251 and 445 to 457.

## 4. Memory

### D-084 Paging and virtual memory are design tools
- 2026-11-10. Decided by: the owner.
- Decision: page protection is a design tool of the kernel and of the system. Use read-only mappings, no-execute pages, guard pages and pages on first use where they make a rule physical.
- Words: "do leverage paging, virtual memory, read-only memory".
- State: done (the kernel at step 13; pages on first use and shared code at steps 28 and 29).
- Where: `ARCHITECTURE.md`; `FIRST_MILESTONE.md`, choices 42 to 46 and 128 to 141.

### D-085 A program drives its own virtual memory
- 2026-11-10. Decided by: the owner (an idea); the coordinator (the rule).
- Decision: each action goes through handles. A program acts on its own address space, or on a program for which it holds a handle with Control, and maps only the memory objects that it holds. No page is writable and executable at any instant. The kernel never waits for a pager.
- Words: none recorded.
- State: done (step 66; the fault ring in choices 594 to 602). Not done yet: a pager for another program.
- Where: `ARCHITECTURE.md`; `FIRST_MILESTONE.md`, choices 431 to 444.

### D-086 Who pays a commit
- 2026-11-11. Decided by: the owner (budget delegation); the coordinator (the narrow right).
- Decision: `Memory_Commit` takes a budget handle. The right Write on an object does not spend the budget of its creator. A program delegates with a child budget. The narrow right `Commit` pays pages of an object of that budget and nothing else.
- Words: "on peut pas avoir de la délégation de budget"; then "il faut réfléchir aux cas de figure".
- State: done (step 66).
- Where: `ARCHITECTURE.md`; `FIRST_MILESTONE.md`, choices 431 to 444.

### D-087 The system has its own copy and fill of memory
- 2026-11-11. Decided by: the owner.
- Decision: the system does not use the copy and fill of the freestanding Odin runtime. It has its own, chosen by measure, in every module, the kernel and the boot program.
- Words: "Did we provide proper kernel facilities for memory manipulation actions ? Cause using a dumb odin provided memcpy implementation is not the way. We got to let go of these ancient functions and provided are own, appropriate ones."
- State: done (step 49).
- Where: `MODULE_CONTRACT.md`; `FIRST_MILESTONE.md`, choices 310 to 315.

### D-088 A cache of free frames for each processor
- 2026-11-11. Decided by: the coordinator.
- Decision: each processor keeps a stack of at most 256 free frames under its own lock. A page on first use takes its frame with no frame lock.
- Words: none.
- State: done (step 53).
- Where: `ARCHITECTURE.md`; `FIRST_MILESTONE.md`, choices 347 to 358.

## 5. The scheduler

### D-089 Scheduling strategies that change while the machine runs
- 2026-11-10. Decided by: the owner.
- Decision: study CFS, EEVDF and `sched_ext` and take ideas from them. The system can change from one strategy to another while it runs.
- Words: the message ended with "alterner entre les" [change between the strategies].
- State: done (step 46: round robin, fair, EEVDF).
- Where: `SCHEDULING.md`; `FIRST_MILESTONE.md`, choices 269 to 285.

### D-090 EEVDF is the strategy at boot
- 2026-11-11. Decided by: an agent; the coordinator kept it. The owner can reverse it.
- Decision: EEVDF is the strategy at boot.
- Words: none.
- State: in force.
- Where: `SCHEDULING.md`.

### D-091 No strategy that a program supplies
- 2026-11-11. Decided by: the coordinator. The owner can reverse it.
- Decision: a program cannot supply a strategy (the idea of `sched_ext`). It needs a verifier or an isolated path, and the kernel does not run code that it did not check.
- Words: none.
- State: in force. A share for each budget is not done yet.
- Where: `SCHEDULING.md`.

## 6. Storage

### D-092 No save action; versions for all programs
- 2026-11-09. Decided by: the owner.
- Decision: a program has no save action. Storage keeps versions for all programs.
- Words: none recorded.
- State: done (persistent programs at step 32; versions at step 67).
- Where: `PROPERTIES.md`, property 9; `ARCHITECTURE.md`, "Versions"; `FIRST_MILESTONE.md`, choices 142 to 159 and 445 to 457.

### D-093 A new storage engine under MIT
- 2026-11-09. Decided by: the owner.
- Decision: the storage engine is new and under the MIT license. It is not a fork of bcachefs.
- Words: none recorded.
- State: done.
- Where: `ARCHITECTURE.md`; `docs/research/bcachefs_storage.md`.

### D-094 The engine written in Odin stays
- 2026-11-10. Decided by: the owner.
- Decision: the small storage engine written in Odin stays, and SQLite leaves the system (D-024).
- Words: none recorded.
- State: done.
- Where: `FIRST_MILESTONE.md`, choices 142 to 159 and 183 to 188.

### D-095 A disk of an older format is not read
- 2026-11-11. Decided by: an agent, from the rule of the owner "no compatibility layer"; the coordinator accepted it.
- Decision: the disk format is `STORAGE2`. A disk of the first format is not read.
- Words: none.
- State: in force.
- Where: `ARCHITECTURE.md`, "Versions".

## 7. The network and QUIC

### D-096 The protocols are libraries in the program
- 2026-11-10. Decided by: the owner (the network and its order); the coordinator (the form).
- Decision: the network comes in this order: a virtio device service, then UDP, TCP and QUIC, with a server as the scenario. TCP and QUIC are libraries in the program, over an endpoint with a grant.
- Words: none recorded.
- State: done (steps 40, 48, 70, 76 and 80).
- Where: `NETWORK.md`; `QUIC.md`.

### D-097 The network service on the data path
- 2026-11-10. Decided by: the owner for UDP ("keep going" to the objection); open for TCP.
- Decision: the network service is on the data path for UDP, against the rule of property 5; the property has a dated note. It is also on the data path for TCP segments, because the device has one pair of queues.
- Words: "keep going" (recorded in English).
- State: in force for UDP; open for TCP (question Q-03).
- Where: `PROPERTIES.md`, property 5; `NETWORK.md`.

### D-098 The service `remote`
- 2026-11-11. Decided by: the owner (accepted the proposal of an agent).
- Decision: a service with a grant on one network endpoint to the host lets the tool call an export and read typed records. A screenshot serves only what is visual. A person starts `remote`; it does not start with the system.
- Words: "vas-y".
- State: done (steps 44 and 47). Not done yet: `remote` over QUIC.
- Where: `MODULE_CONTRACT.md`; `TOOLS.md`; `FIRST_MILESTONE.md`, choices 252 to 262 and 286 to 294.

### D-099 A simple HTTP/1.1 server
- 2026-11-11. Decided by: the owner; the coordinator read "simple".
- Decision: `server` speaks HTTP/1.1 with persistent connections, pipelining and `HEAD`. Pages are in the private store of `server`. `PUT` and `DELETE` over HTTP give 405 while the network is not authenticated. No TLS, no chunked body, no ranges.
- Words: "faudra faire un simple server http 1.1 après".
- State: done (step 52).
- Where: `NETWORK.md`; `FIRST_MILESTONE.md`, choices 334 to 346 and 372 to 378.

### D-100 A QUIC server under load
- 2026-11-12. Decided by: the coordinator and the agents of QUIC.
- Decision: a server keeps nothing before a client proved its address (Retry). The work for unknown clients has budgets. What a flood can still do is written plainly in the guide. Before `quic_echo` listens on a real network: the measure of the costs, and a read of the last corrections.
- Words: none.
- State: in force (steps 76, 80 and 85).
- Where: `QUIC.md`, sections 5 and 6; `FIRST_MILESTONE.md`, choices 506 to 517, 541 to 544 and 570 to 571.

## 8. Cryptography and randomness

### D-101 BLAKE3
- 2026-11-09. Decided by: the owner.
- Decision: the hash of the system is BLAKE3.
- Words: none recorded.
- State: done.
- Where: `PROPERTIES.md`, property 11.

### D-102 Do not write cryptography from nothing
- 2026-11-11. Decided by: the owner.
- Decision: existing, proven, permissively licensed code is copied into the repository with its arithmetic unchanged, and adapted to the primitives of the system: a module with exports, memory of the caller, error records, batches over tables. A check proves the origin of each copied file.
- Words: "don't write cryptography from nothing, but maybe incorporate existing stuff and adjust it/provide wrappers functions/compat, so that they use OUR kernel primitives (tables, modules, shit like that)".
- State: done (steps 60 and 70).
- Where: `CRYPTOGRAPHY.md`; `FIRST_MILESTONE.md`, choices 403 to 406 and 460 to 469.

### D-103 A generator in each program
- 2026-11-11. Decided by: the coordinator (a seed for each program, not a kernel operation for each draw). The owner has not reviewed it.
- Decision: each program has its own ChaCha20 generator in its own memory. The starter writes a seed of 32 bytes in the context; a seed of zeros is refused. The root service builds the seed of the system and logs its strength.
- Words: none.
- State: done (step 60). Not done yet: the `virtio-rng` device.
- Where: `RANDOMNESS.md`.

### D-104 The caller chooses the least seed strength
- 2026-11-11. Decided by: the owner.
- Decision: a procedure that makes a key takes the least seed strength that the caller accepts (entropy, processor, weak). When the seed is weaker, the call gives an error and makes nothing. QUIC asks for "processor" at least.
- Words: "si les trucs là que tu dis qui peuvent manquer dans le cas de week bah dans ce cas-là je pense que les fonctions qu'on expose devrait permettre de choisir ce que le programme tolère et dans le cas où les requis que le programme attend ne sont pas satisfaits et ben dans ce cas là c'est une erreur c'est pas grave" ["week" reads "weak"].
- State: done (step 70).
- Where: `RANDOMNESS.md`; `CRYPTOGRAPHY.md`.

### D-105 A correction offered to Odin
- 2026-11-11. Decided by: the owner.
- Decision: a correction of the ChaCha20 counter limit goes to Odin as a pull request from the account of the owner: https://github.com/odin-lang/Odin/pull/8329. Until Odin takes it, the copied file keeps the same correction as a listed adjustment.
- Words: "tu peux faire un petit correctif et [...] une PR [...] qui fait pas IA [...] une bonne description un exemple [...] comment le reproduire [...] dans un sous-agent".
- State: done (the pull request is open).
- Where: `CRYPTOGRAPHY.md`.

## 9. The interface, the fonts, the mark and the design

### D-106 WebGPU and WGSL are the graphics stack
- 2026-11-09. Decided by: the owner.
- Decision: the target graphics stack is WebGPU and WGSL.
- Words: none recorded.
- State: not done yet; last in the order (D-048).
- Where: `PROPERTIES.md`, property 18; `docs/research/webgpu_from_nothing_study.md`.

### D-107 WebGPU written from nothing
- 2026-11-09. Decided by: the owner.
- Decision: the WebGPU implementation is written from nothing.
- Words: none recorded.
- State: not done yet.
- Where: `PROPERTIES.md`, property 18.

### D-108 No GPU at first
- 2026-11-09. Decided by: the owner.
- Decision: the UEFI framebuffer, surfaces in shared memory and drawing by the processor come first. Then WebGPU in software, then virtio-gpu, then a real GPU, on a desktop that works.
- Words: none recorded.
- State: in force.
- Where: `PROPERTIES.md`, property 18.

### D-109 Never use `gui_toolkit`
- 2026-11-09. Decided by: the owner.
- Decision: `gui_toolkit` is not made for a kernel. Graphical code is written from nothing, as programs of this system.
- Words: none recorded.
- State: replaced by D-110.
- Where: `INTERFACE.md`.

### D-110 Read `gui_toolkit` for ideas, use none of its code
- 2026-11-11. Decided by: the owner.
- Decision: the system can take ideas from `gui_toolkit` and adapt them to its own rules. It uses none of its code.
- Words: "Also, for slug/text/gui it's fine to LOOK AT gui_toolkit, not USE IT..the idea with slug was just to try and \"adapt\"/backport things INTO our kernel design rules !"
- State: in force.
- Where: `INTERFACE.md`; `FONTS.md`.

### D-111 An interface package with damage and layout
- 2026-11-11. Decided by: the owner (the request; the owner let the agent decide); the coordinator (its own step, design first, written from nothing).
- Decision: the system has a well-framed layer for the interface: damage, layout and text. It is immediate mode over a table of draw records in memory of the program.
- Words: "faudrait anticiper à faire les choses \"bien\" et avoir (un module ?) de la logique bien cadrée pour le Ui rendering, avec le \"damage\", le layouting, etc etc [...] we need to lay good, robust, featurful foudations early rather than late".
- State: done (steps 51, 54, 61 and 69). The model, the module form and the order of the conversions are open (question Q-04).
- Where: `INTERFACE.md`; `FIRST_MILESTONE.md`, choices 325 to 333, 407 to 413 and 458 to 459.

### D-112 Spleen 8x16 at its native size
- 2026-11-10. Decided by: the owner.
- Decision: no enlarged low-resolution font. Use a bitmap font of good quality at its native size: Spleen 8x16 (BSD 2-Clause).
- Words: none recorded.
- State: replaced by D-113 for the default font, and by D-115 for the fallback.
- Where: `FONTS.md`.

### D-113 The default font is a vector font
- 2026-11-11. Decided by: the owner.
- Decision: the default font of the system is a vector font. Spleen 8x16 stays as the fallback and as an option of the settings.
- Words: "on peut garder spleen comme fallbach ou comme option dans un menu de paramétrage par exemple mais par défaut il faut une police vectorielle".
- State: done (step 58).
- Where: `FONTS.md`; `FIRST_MILESTONE.md`, choices 390 to 399.

### D-114 Subpixel bands
- 2026-11-11. Decided by: the owner.
- Decision: the vector font is drawn with bands of color for each subpixel, not in grayscale.
- Words: "Bandes sous-pixel".
- State: done (step 58). The grid fit and the default order of the stripes are open (question Q-05).
- Where: `FONTS.md`.

### D-115 Spleen as the fallback can be enlarged
- 2026-11-12. Decided by: the owner.
- Decision: "no enlarged low-resolution font" holds for the default font. Spleen 8x16, as the fallback or as a choice of the settings, draws each pixel as a square at the scales 2 and 3.
- Words: "yeah that's fine".
- State: in force.
- Where: `FONTS.md`.

### D-116 A font with the look of a modern system
- 2026-11-11. Decided by: the owner.
- Decision: the font of the system changes. JetBrains Mono, which an agent chose, is too basic; the look is that of a modern operating system.
- Words: "J'aimerais changer de police par contre, dejavu c'est trop basique. Roboto ? Autre ? Un truc \"os moderne\"" ["dejavu" names the font of that day, JetBrains Mono].
- State: done by D-117 and D-118.
- Where: `FONTS.md`.

### D-117 Paper Mono is the monospace font
- 2026-11-11. Decided by: the owner.
- Decision: Paper Mono (SIL OFL 1.1) is the monospace font of the system, in the place of JetBrains Mono.
- Words: "Paper mono très bien pour monospace mais pr l'interface aucune m'a convaincu".
- State: done (step 74).
- Where: `FONTS.md`; `FIRST_MILESTONE.md`, choices 488 to 499.

### D-118 B612 is the interface font, with text shaping
- 2026-11-11. Decided by: the owner.
- Decision: B612 (SIL OFL 1.1) is the font of the interface. A proportional font needs a text shaping module: advances, kerning, positions under a pixel.
- Words: "J'hesite entre airbus, overpass et Atkinson (pas les monos)"; "Il nous faudra un module de text shaping/kerning"; "Go b612".
- State: done (steps 74, 79, 82 and 86).
- Where: `FONTS.md`, section 12.

### D-119 The slashed zero
- 2026-11-12. Decided by: the owner.
- Decision: the zero of the system is the slashed zero of Paper Mono.
- Words: "yes" (to "The zero of Paper Mono: Take the slashed zero."); then "le zéro barré il est très bien".
- State: done (step 79).
- Where: `FONTS.md`; `FIRST_MILESTONE.md`, choices 533 to 540.

### D-120 The rule of the two fonts
- 2026-11-12. Decided by: the coordinator (the reading); the owner confirmed it.
- Decision: the interface font draws each text that names or explains. The font of the cells draws each value and each text that a person compares or copies.
- Words: "pour la règle des polices ça me va".
- State: done (steps 82 and 86).
- Where: `DESIGN.md`, section 5; `FIRST_MILESTONE.md`, choices 550 to 552 and 572 to 574.

### D-121 The first screen of the boot stays in Spleen
- 2026-11-12. Decided by: an agent (the rule); the owner confirmed it.
- Decision: the boot program draws its first screen in Spleen 8x16, because it holds no glyph cache. The root service then redraws it in the two fonts.
- Words: "l'écran de démarrage que ça reste en spleen ça me va vu que on va pas charger des polices à l'étape de enfin c'est ce que fait tous les os le rendering au démarrage il doit être simple".
- State: in force.
- Where: `DESIGN.md`, section 5; `FIRST_MILESTONE.md`, choice 573.

### D-122 The glyph cache stays built ahead
- 2026-11-12. Decided by: the owner.
- Decision: the glyph cache is an atlas filled whole at build time. An atlas filled on demand by a font service is noted for later.
- Words: "shouldn't the text rendering keep an atlas and render on demande or some shit ?"; then "yes that's fine for now, but note it".
- State: in force. The font service is designed only.
- Where: `FONTS.md`.

### D-123 Latin-1 later
- 2026-11-12. Decided by: the owner.
- Decision: the subset of the fonts stays ASCII for now. The accents of French come later.
- Words: "les accents français on verra plus tard".
- State: not done yet.
- Where: `FONTS.md`.

### D-124 Floating point and posits
- 2026-11-11. Decided by: nobody yet (raised by the owner).
- Decision: floating point is not forbidden when it is needed. Rule 7 of `DESIGN.md` (integers for a display) stays, because the tests compare bytes. Posits have no hardware on x86.
- Words: "pour moi c'est pas interdit si on a besoin [...] j'expose ça peut être intéressant la notion de posit".
- State: open (question Q-07).
- Where: `DESIGN.md`, rule 7.

### D-125 A rich boot display
- 2026-11-10. Decided by: the owner.
- Decision: the start of the machine shows a rich, documented and colored display with as many facts as possible to find a fault. No display that is limited on purpose. The facts also go to the log.
- Words: none recorded.
- State: done.
- Where: `DESIGN.md`; `FIRST_MILESTONE.md`, choices 37 to 41.

### D-126 An original boot display
- 2026-11-10. Decided by: the owner (the request); the coordinator (the limit).
- Decision: the boot display is original, not a low-technology text screen. It shows true data of the boot and does not make the boot slower without a measured number.
- Words: "sexy".
- State: done.
- Where: `DESIGN.md`.

### D-127 No round corners in the boot display
- 2026-11-10. Decided by: the owner.
- Decision: each form of the boot display is a rectangle.
- Words: none recorded.
- State: replaced by D-129.
- Where: `DESIGN.md`.

### D-128 The design rules come from the boot display
- 2026-11-10. Decided by: the owner.
- Decision: the design of the boot display is the model. Its rules are written in `DESIGN.md` and apply to the desktop.
- Words: "j'adore".
- State: done (step 39; the desktop since step 45).
- Where: `DESIGN.md`; `FIRST_MILESTONE.md`, choice 190.

### D-129 Rectangular forms are a preference
- 2026-11-11. Decided by: the owner.
- Decision: rectangular forms are the preference. Lines at an angle are allowed. Any geometry can be drawn, sparingly. Avoid a look where everything is a rounded blob.
- Words: "Un arrondi peut être ok dans certains cas, enfin, c'est pas un interdit absolu, mais c'est juste que l'esthétique du design c'est d'avoir des choses rectangulaires. En revanche, oui, évidemment, les traits obliques c'est autorisé. [...] Je veux pas que tout soit un blob arrondi en fait."
- State: in force.
- Where: `DESIGN.md`; `AGENTS.md`.

### D-130 A richer look: a gradient and a launcher
- 2026-11-10. Decided by: the owner; the coordinator read the unclear points. The owner can reverse the readings.
- Decision: a gradient from the current blue to a darker blue toward the right, then a launcher as an experiment. Readings: the blue is that of the title bar of the window in front; the launcher is a panel that a key opens, where the person types a part of a name.
- Words: "purely by vanity" (recorded in English).
- State: done (step 45).
- Where: `DESIGN.md`; `FIRST_MILESTONE.md`, choices 263 to 268.

### D-131 A red close button
- 2026-11-11. Decided by: the owner (the request); the coordinator (the nearest form).
- Decision: the close button is a deep red, the color of a new concept "stop a program", because red alone means "failed".
- Words: "et ce serait bien que les x de fermeture soit rouge, riche".
- State: done (step 51).
- Where: `DESIGN.md`; `FIRST_MILESTONE.md`, choices 325 to 333.

### D-132 A format of the system for the pointer pictures
- 2026-11-11. Decided by: the owner.
- Decision: the pointer pictures have a format of the system, a simple text manifest and a tool that packs them. Posy's Cursor is imported and adjusted.
- Words: "si on peut faire notre propre format de stockage pour les curseurs un truc qui est simple à manager au packager [...] importer migrer ajuster les posies curseur [...] un format de manifeste simple le format texte qui est facile à parcer [...] ou même binaire d'ailleurs mais je te laisse choisir" ["posies curseur" reads "Posy's Cursor"].
- State: done (step 55).
- Where: `POINTERS.md`; `FIRST_MILESTONE.md`, choices 360 to 371.

### D-133 Posy's Cursor is a build input and the default theme
- 2026-11-11. Decided by: the owner.
- Decision: Posy's Cursor (CC-BY-NC-4.0) is a build input; no file of it enters the repository. It is the default theme when the input is present. The theme of the system is the fallback.
- Words: none recorded.
- State: done (step 55).
- Where: `POINTERS.md`.

### D-134 The pictures of the repository show Posy's Cursor
- 2026-11-11. Decided by: the owner ("Capture avec posy"); the coordinator (`pointers.png` stays in the devlog).
- Decision: the screenshots of the repository show the pointer theme of the owner. The picture of every pointer of Posy's Cursor stays in the devlog; the repository shows the pointers of the system theme.
- Words: "Capture avec posy."
- State: in force; the second part waits for the owner (question Q-08).
- Where: `POINTERS.md`.

### D-135 SIMD for batches, one vector form
- 2026-11-11. Decided by: the owner (the direction); the coordinator (the forms).
- Decision: vector forms serve rendering and batch work. Each form gives the same bytes as the scalar form. SSE2 is the one vector form. An AVX2 form comes back when it wins by measure on the machine.
- Words: "on est d'accord que y'a un gain potentiel pour le rendering et les opérations de \"lot\" (ce qui marche bien avec notre approche orientée data ?)".
- State: done (step 72).
- Where: `SIMD.md`; `FIRST_MILESTONE.md`, choices 471 to 476.

### D-136 The temple of Jon
- 2026-11-10. Decided by: the owner.
- Decision: a demo for fun, in the spirit of Jai: a portrait of Jonathan Blow that turns. The portrait is a public domain picture.
- Words: none recorded.
- State: done (`programs/temple`). Its use in a post is open (question Q-09).
- Where: `DEMONSTRATIONS.md`.

### D-137 The mark of modus
- 2026-11-12. Decided by: the owner.
- Decision: the mark is a heron in pixels (a grid of 24 by 24, each part one smooth gradient from top left to bottom right, no drawn shade, no edge). The name is "modus" in letters of square cells. The mark is data of the system, and the tool writes its pictures from it.
- Words: "fais moi des propales de logo/mascotte pour modus stp"; "généré de manière programmatique plutot"; "le heron A n°1 est le meilleur, nickel cest simple ! + le logo \"modus\" comme t'as fait super cool".
- State: done (step 75).
- Where: `DESIGN.md`, "The mark"; `FIRST_MILESTONE.md`, choice 505.

### D-138 The mark in the bar and at the boot
- 2026-11-12. Decided by: the owner (in the list of next work).
- Decision: the heron is at the left of the bar, and the heron with the name is at the head of the boot display, drawn from the data of the mark.
- Words: "yes" (to the list of next work).
- State: done (step 77).
- Where: `DESIGN.md`, "The mark"; `FIRST_MILESTONE.md`, choices 518 and 519.

### D-139 The branch of the logo proposals is deleted
- 2026-11-12. Decided by: the owner.
- Decision: the branch of the logo proposals, which used code of `gui_toolkit`, is deleted.
- Words: "agree".
- State: done.
- Where: none.

### D-140 The mark on a transparent background
- 2026-11-12. Decided by: the owner.
- Decision: the tool also writes the mark on a transparent background, for a dark and a light color scheme.
- Words: none recorded.
- State: done.
- Where: `SITE.md`, "The mark on the site"; `FIRST_MILESTONE.md`, choice 578.

### D-141 The rendering of the fonts in the pictures
- 2026-11-11. Decided by: an agent; the coordinator accepted it.
- Decision: the vertical metrics are fitted to the grid, and the default order of the stripes is `rgb`.
- Words: none.
- State: open (question Q-05).
- Where: `FONTS.md`.

### D-192 hyprcursor as a possible format of pointers
- 2026-11-11. Decided by: the owner (an option given to the agent).
- Decision: the agent could take the format of hyprcursor if it is simple; Xcursor is the form to leave. The system took its own format (D-132). A reader of `.hlc` files waits for a theme that exists only in that form.
- Words: "je sais que hyprland a son propre format de curseur qui est pas trop mal, s'il est simple à parser mais simple à implémenter [...] tu peux y aller [...] parce que bon Xcursor voilà quoi".
- State: not taken.
- Where: `POINTERS.md`, section 1.

### D-193 A new decoration needs the owner
- 2026-11-10. Decided by: the coordinator, with the design rules.
- Decision: the design rules list every decoration of the system. A new decoration needs a decision of the owner.
- Words: none.
- State: in force.
- Where: `DESIGN.md`, section 8.

## 10. The console and the tools

### D-142 The console is a normal program with a real language
- 2026-11-09. Decided by: the owner.
- Decision: the console is a normal program with a real language. The system has no TTY concept.
- Words: none recorded.
- State: in force.
- Where: `CONSOLE.md`.

### D-143 The terminal shows typed records
- 2026-11-10. Decided by: the owner.
- Decision: the console is a central entry point and is very fast. No escape characters and no escape sequences. A program sends typed, structured records to a terminal. The program that produces and the terminal that shows are separate. A demonstration shows that the display does not slow the throughput, and it is filmed.
- Words: none recorded.
- State: done (`programs/terminal`, `programs/flood`, `kerneltool film`).
- Where: `CONSOLE.md`; `FIRST_MILESTONE.md`, choices 61 to 69.

### D-144 The terminal starts no program
- 2026-11-10. Decided by: the owner (accepted the design).
- Decision: the root service starts a program and its terminal. Input is key records in the terminal ring. The program owns its edit line. The terminal keeps Page Up and Page Down; each other key goes to the program.
- Words: "continue".
- State: done (step 23).
- Where: `CONSOLE.md`; `FIRST_MILESTONE.md`, choices 88 to 95.

### D-145 The console edits its line and completes names
- 2026-11-11. Decided by: the owner.
- Decision: the console has a caret, a completion list with a fuzzy match and the matched characters lit, and a search of the history with Control-R and Control-S.
- Words: "Le programme console fait de l'autocompletion ? (Tab) ?"; "Go faire tout ça pour la console, avec fuzzy filtering/matching+match highlight dropdown result. Un truc stylé quoi"; "Ctrl+R/ctrl+s".
- State: done (steps 73 and 78).
- Where: `CONSOLE.md`; `FIRST_MILESTONE.md`, choices 477 to 487 and 520 to 532.

### D-146 The history of the console in a store of its own
- 2026-11-12. Decided by: the coordinator; the owner then accepted it.
- Decision: the console keeps its line history across a stop in a second store for the history only, given by the root service with no grant to act for the person. `history_clear()` removes it.
- Words: "pour l'historique ça me va ce que tu as dit".
- State: done (step 83).
- Where: `CONSOLE.md`, section 6; `FIRST_MILESTONE.md`, choices 556 to 564.

### D-147 One kernel tool, no scripts
- 2026-11-09. Decided by: the owner.
- Decision: all project automation is a command of one Odin tool, `kerneltool`: build, conversion to modules, the boot image, QEMU, tests, and every call to a third-party tool. No shell, Python or other script.
- Words: none recorded.
- State: in force.
- Where: `AGENTS.md`; `TOOLS.md`.

### D-148 Tools that show memory and execution
- 2026-11-10. Decided by: the owner (the tools); an agent and the coordinator (the limit).
- Decision: the system has graphical tools for a developer that inspect memory and execution. A tool inspects a program only with a handle that has the right to inspect. `inspect` reads no byte of another program.
- Words: none recorded.
- State: done (step 50). Not done yet: the counters of the processor; a stronger right to read another program.
- Where: `TOOLS.md`; `FIRST_MILESTONE.md`, choices 316 to 324.

## 11. The build and the compiler

### D-149 Odin is the implementation language
- 2026-11-09. Decided by: the owner.
- Decision: Odin is the implementation language. It is final.
- Words: "odin ok".
- State: in force.
- Where: `ARCHITECTURE.md`.

### D-150 The Nix flake supplies the tools
- 2026-11-09. Decided by: the owner.
- Decision: a Nix flake at the root supplies the compiler, the linker, QEMU and the firmware. The kernel tool runs inside it. `nix flake check` runs the hooks and the machine test.
- Words: none recorded.
- State: in force.
- Where: `flake.nix`; `AGENTS.md`.

### D-151 The layout of the repository
- 2026-11-09. Decided by: the owner.
- Decision: documents in `docs/`, research notes in `docs/research/`, the boot program in `boot/`, the kernel tool in `tools/kerneltool/`, build output in `build/`, which git ignores. Code is in named Odin libraries, with no relative import.
- Words: none recorded.
- State: in force (the libraries since 2026-11-10, choice 87).
- Where: `README.md`; `FIRST_MILESTONE.md`, choice 87.

### D-152 Do not write a linker
- 2026-11-09. Decided by: the owner.
- Decision: reuse an existing linker. Modules are built on the ELF target with `lld`, and the module converter takes a linked image. The RAD Linker is not adapted now.
- Words: none recorded.
- State: in force.
- Where: `MODULE_CONTRACT.md`, section 7; `docs/research/rad_linker_rdi_study.md`.

### D-153 ELF only at build time
- 2026-11-09. Decided by: the owner.
- Decision: ELF is an intermediate format of the build only. It never reaches the running system.
- Words: none recorded.
- State: in force.
- Where: `MODULE_CONTRACT.md`.

### D-154 RDI as the debug format
- 2026-11-09. Decided by: the owner.
- Decision: RDI is the format of the debug information.
- Words: none recorded.
- State: replaced by D-155 the same day.
- Where: `docs/research/rad_linker_rdi_study.md`.

### D-155 DWARF in a separate object; COFF for the boot program
- 2026-11-09. Decided by: the owner.
- Decision: RDI is not required. Debug information is DWARF in a separate object. Only the boot program uses the COFF target, because UEFI needs a PE file.
- Words: none recorded.
- State: in force.
- Where: `MODULE_CONTRACT.md`.

### D-156 The kernel tool uses only the Odin standard library
- 2026-11-09. Decided by: the owner.
- Decision: the kernel tool uses only the Odin standard library. The rule is about the tool, not about the system.
- Words: none recorded.
- State: in force.
- Where: `TOOLS.md`.

### D-157 Modules through LLVM IR, to keep the frame pointers
- 2026-11-11. Decided by: an agent; the coordinator accepted it.
- Decision: each module is compiled through LLVM IR and `llc`, so that the frame pointers stay.
- Words: none.
- State: in force.
- Where: `REPRODUCIBLE_BUILD.md`; `FIRST_MILESTONE.md`, choices 227 to 248.

### D-158 The parallel build
- 2026-11-11. Decided by: the owner (accepted the answer of the coordinator).
- Decision: `kerneltool build` runs one compiler for each module, as many at once as the machine has processors, and assembles the boot image in the fixed order of the module table.
- Words: "Pourquoi on est obligé de faire du monothread ? Avec pas moyen de faire du multithread, collect, order ?"; then "Ah oui c'est bien ça".
- State: done (step 62). The compiler on one thread is replaced by D-160.
- Where: `REPRODUCIBLE_BUILD.md`; `FIRST_MILESTONE.md`, choice 414.

### D-159 A wider patch of the compiler
- 2026-11-11. Decided by: the owner.
- Decision: a patch of the compiler that fixes the order of what it generates, to offer upstream if it works well.
- Words: "faire un patch plus large pour \"cadrer\" les ordres de génération et permettre du vrai parallélisme. Et on pourra même l'upstream si on y arrive bien".
- State: closed with no patch: the release of November gives the same bytes (D-160).
- Where: `REPRODUCIBLE_BUILD.md`.

### D-160 No patch of the compiler, all its threads
- 2026-11-11. Decided by: the owner.
- Decision: the stock compiler runs with all its threads, with no patch and no `-thread-count:1`. A repeat of every build proves one result for each module.
- Words: "Letsgo !!".
- State: done (step 64).
- Where: `REPRODUCIBLE_BUILD.md`; `FIRST_MILESTONE.md`, choice 416.

### D-161 The newest Odin compiler, pinned
- 2026-11-11. Decided by: the owner.
- Decision: the flake pins the newest Odin release (`dev-2026-11a`) by its tag and its hash. No fork. Its assembly and SIMD features are used: the small instructions of the kernel are `asm` templates.
- Words: "il faut qu'on s'en serve donc peut-être soit on fait notre force de Odin qu'on maintiendra à jour soit tu te débrouilles pour utiliser la dernière version mais ça ne va pas qu'on utilise celle de mai"; "j'ai vu que pour faire du langage assemblage [...] est devenu extrêmement puissant et pour faire du simd aussi" ["force" reads "fork"].
- State: done (step 63; the templates in choice 593).
- Where: `REPRODUCIBLE_BUILD.md`; `ARCHITECTURE.md`, "The instructions of the kernel"; `FIRST_MILESTONE.md`, choices 415 and 593.

### D-162 LLVM 22 is its own step
- 2026-11-11. Decided by: the coordinator.
- Decision: LLVM stays 18. A move to LLVM 22 is its own step, with a measure.
- Words: none.
- State: not done yet.
- Where: `REPRODUCIBLE_BUILD.md`.

## 12. The site and the publication

### D-163 A technical site
- 2026-11-10. Decided by: the owner.
- Decision: a technical site presents modus, in the manner of https://libernt.com/fr/. The site is a command of `kerneltool` and shows the pictures and the measured numbers of the machine test.
- Words: none recorded.
- State: done (`kerneltool site`).
- Where: `SITE.md`.

### D-164 A rich, generated documentation in the look of the system
- 2026-11-12. Decided by: the owner.
- Decision: the site has a rich documentation generated from the sources, with a search and a page for each module. Its look takes the design of the desktop and of the boot display, with nothing kitsch.
- Words: "et tu peux dire que le site doit avoir une doc riche et auto générée, avec recherche, modules, etc."; "et aussi, le site doit reprendre les éléments de design du desktop/boot sequence, etc, sans etre trop KITCH pour autant."
- State: done. The reading "no animation" is replaced by D-180 for the large mark.
- Where: `SITE.md`; `FIRST_MILESTONE.md`, choices 576 and 579 to 584.

### D-165 The licenses are a table
- 2026-11-12. Decided by: the owner.
- Decision: one row for each thing that has a license, each cell read from a file of the repository.
- Words: "for the license part, be more \"table oriented ;)\"".
- State: done.
- Where: `SITE.md`, "The licenses"; `FIRST_MILESTONE.md`, choice 577.

### D-166 Several pages, made for search engines
- 2026-11-12. Decided by: the owner; the coordinator added that no personal detail of the owner's own site goes into this one.
- Decision: the site has several pages, a sitemap, JSON-LD and a page graph.
- Words: "and don't be afraid to split into multiple pages. we'll want a sitemap, json-ld, good seo (graph) etc etc shit like that."
- State: done.
- Where: `SITE.md`, "What other sites read"; `FIRST_MILESTONE.md`, choice 585.

### D-167 The site address is an empty setting
- 2026-11-12. Decided by: the coordinator.
- Decision: the site address is one setting, empty until a host and a domain are chosen.
- Words: none.
- State: replaced by D-176.
- Where: `SITE.md`.

### D-168 The news beside the changelog
- 2026-11-12. Decided by: the owner.
- Decision: no page holds a description that a person must remember to update. A second record, the news, holds dated entries in prose for a reader who is not a developer, one file for each entry.
- Words: "\"What runs today\" watch out cause it'll be a nightmare to udate the description. we could have a \"parallel changelog\" (changelog is very technical/list-like) which would be like a \"status report\" or like \"News\"".
- State: done.
- Where: `SITE.md`, "The news"; `news/README.md`; `FIRST_MILESTONE.md`, choice 583.

### D-169 The site is documentation first
- 2026-11-12. Decided by: the owner.
- Decision: the home does the tour. Every other page is documentation. The current state is reference tables generated from the system, never a narrative.
- Words: "Fine to present features, but I'm just wary how we present \"the current state\" and information. we need to be more \"doc like\", even though it's obviously fine to have a landing page that kinda does the house tour and shows off :D".
- State: done.
- Where: `SITE.md`; `FIRST_MILESTONE.md`, choices 576, 579 to 581.

### D-170 A GitHub workflow publishes the site
- 2026-11-12. Decided by: the owner.
- Decision: a GitHub workflow builds and publishes the site at each push to `master`.
- Words: "pour la publication du site je préfère un workflow GitHub évidemment".
- State: done (`.github/workflows/site.yml`). Its cache and the machine tests in it are open (questions Q-12 and Q-13).
- Where: `SITE.md`, "How the site is published".

### D-171 The proxy of Cloudflare
- 2026-11-12. Decided by: the owner.
- Decision: the site is behind the proxy of Cloudflare, which adds the security headers.
- Words: "tu peux passer derrière le proxy cloud flare c'est OK".
- State: in force. The token for the rules is open (question Q-10).
- Where: `SITE.md`, "How the site is published".

### D-172 The site names its author
- 2026-11-12. Decided by: the owner.
- Decision: the site names its author.
- Words: "pour l'auteur du site évidemment tu peux mettre".
- State: done.
- Where: `FIRST_MILESTONE.md`, choice 586.

### D-173 A menu button on a small screen
- 2026-11-12. Decided by: the owner.
- Decision: on a small screen the sections of the site are behind a menu button.
- Words: "il manque un menu burger sur la version mobile du site".
- State: done.
- Where: `SITE.md`, "The site menu"; `FIRST_MILESTONE.md`, choice 586.

### D-174 The news cards are aligned
- 2026-11-12. Decided by: the owner.
- Decision: the pictures of the news cards on the home are aligned.
- Words: "les images elles sont pas alignées [...] ça fait dommage".
- State: done.
- Where: `FIRST_MILESTONE.md`, choice 586.

### D-175 A short tagline
- 2026-11-12. Decided by: the owner.
- Decision: the head of the home holds one short line. An explanation goes in a paragraph below, not at the start.
- Words: "la tagline est trop longue si tu veux faire de l'explication tu fais dans un paragraphe en dessous mais pas dès le début du site".
- State: done.
- Where: `FIRST_MILESTONE.md`, choice 587.

### D-176 The host and the domain
- 2026-11-12. Decided by: the owner.
- Decision: the site is at `https://modus.froment.software/`, on GitHub Pages, with the domain at Cloudflare.
- Words: "si tu peux mettre le site en ligne sous le domaine Modus point froment point software tu as accès à la ligne de commande cloud fleur pour récupérer le domaine et le reste tu sais déjà faire" [modus.froment.software; Cloudflare].
- State: done.
- Where: `SITE.md`, "How the site is published".

### D-177 The icons of the site
- 2026-11-12. Decided by: the owner.
- Decision: the favicon and the other icons are configured well, each drawn from the heron.
- Words: "la favicon faut qu'elle soit bien configurée".
- State: done.
- Where: `SITE.md`, "The icons"; `FIRST_MILESTONE.md`, choice 587.

### D-178 A wide table scrolls in its own box
- 2026-11-12. Decided by: the owner.
- Decision: a wide table scrolls sideways in its own box, and each column has a least width by its kind.
- Words: "tableau pas ouf, si possible de faire un tableau scrollable ? pck la colonne compressée".
- State: done.
- Where: `SITE.md`, "The tables"; `FIRST_MILESTONE.md`, choice 588.

### D-179 Addresses as folders
- 2026-11-12. Decided by: the owner.
- Decision: each page is the `index.html` of its own folder, so its address is a folder (`/reference/licenses/`). Each old address redirects.
- Words: "j'aimerais des urls genre /reference/licenses au lieu de license.html".
- State: done.
- Where: `SITE.md`, "The addresses of the pages"; `FIRST_MILESTONE.md`, the choice on the addresses (not numbered yet).

### D-180 The animated mark
- 2026-11-12. Decided by: the owner.
- Decision: the large mark on the home and the favicon play idle animations, several in a cycle. They respect the choice of the reader about motion. The mark in the header does not move.
- Words: "le Pixel art, le logo, on pourrait même en faire une version animée, en mode idle quoi [...] plusieurs animations parmi lesquelles on cyclerait [...] le favicone soit animé. Évidemment, il faudrait que ça respecte les choix de l'utilisateur au niveau des animations [...] Pas à tous les endroits, pas dans le header, mais seulement le gros logo sur la page d'accueil".
- State: done (five animations).
- Where: `SITE.md`, "The mark on the site"; `FIRST_MILESTONE.md`, choice 589.

### D-181 A shorter cycle, and two scratching animations
- 2026-11-12. Decided by: the owner.
- Decision: the interval of the cycle of the animations is a little shorter. Two animations are added: the heron bends its neck and scratches its body; the heron scratches the ground with its foot.
- Words: "le cycle d'intervalle des animations, pour moi, il est trop large, mais de pas beaucoup [...] j'aurais aimé deux animations en particulier. Genre, une où il se gratte [...] son cou, il se plie et il se gratte le corps. Et une autre où il fait gratte-gratte sur le sol avec sa patte avant."
- State: not done yet.
- Where: `SITE.md`, "The mark on the site".

### D-182 A documentation in the form of the Odin site
- 2026-11-12. Decided by: the owner.
- Decision: the documentation has a sidebar of the pages, the technical text in the center, and the symbols of the page at the right, in the manner of the Odin documentation.
- Words: "la doc est nulle à chier [...] je veux un vrai truc de doc, comme Odin par exemple, où ils ont une sidebar, il y a des documentations techniques au centre, il y a les symboles à droite".
- State: not done yet.
- Where: `SITE.md`.

### D-183 Posts on X
- 2026-11-10. Decided by: the owner.
- Decision: posts about the project on X (@survotreson) are permitted. Short; the post shows the thing; no tag of a person; a picture does the work. The first rule "no tweet" was removed the same day. The first post: https://x.com/survotreson/status/2120119925322727909.
- Words: none recorded.
- State: in force. The tone is conflict C-10. The temple of Jon in a post is open (question Q-09).
- Where: this file.

### D-184 The post of the site waits for the site
- 2026-11-12. Decided by: the owner.
- Decision: the post that shows the site goes out once the site is online.
- Words: "pour le tweet tu le fais une fois que le site est actif".
- State: done (then redone, D-185).
- Where: this file.

### D-185 A post never assumes that the reader knows modus
- 2026-11-12. Decided by: the owner.
- Decision: the first post of the site is redone. A post says what modus is; it does not assume that the reader knows it.
- Words: "le tweet sur Modus fait comme si les gens connaissaient déjà Modus il est pas bien refais-le".
- State: in force.
- Where: this file.

### D-194 The site shows the numbers of the last full check
- 2026-11-12. Decided by: the owner, on the published page of the numbers; the form was given by the coordinator.
- Decision: the published site shows the measured numbers of the last full check of the commit that it is built from. The pass that commits the pictures (`kerneltool screenshots`) also commits the measure record, `docs/measures/measures.txt`. The site reads `build/` when its logs are newer than the record, else the record. This settles Q-12.
- Words: "0 of 14 numbers are measured in this build" (the page that the owner saw); "The published site must show the numbers of the last full check of the commit that it is built from."
- State: in force.
- Where: `docs/SITE.md`, "The measure record"; `tools/kerneltool/measure_record.odin`.

### D-195 A pointer of a comment to a document is a reference on the site
- 2026-11-12. Decided by: the owner, on the page of the module `kernel_without_return_check`; the form was given by the coordinator.
- Decision: a pointer of a source comment to a document (`docs/ARCHITECTURE.md, "Kernel systems"`) is shown on the site as a link with the title of the document and of the heading, in a style of its own, not as the path and a label. A pointer whose label names no heading stops `kerneltool site`.
- Words: "qu'est-ce que ça fout là ce genre d'infos ? ça devrait pas etre genre un "tag" ou une "référence" ? genre un lien, affiché avec un style pour architecture.md ?"
- State: in force.
- Where: `docs/SITE.md`, "The references to documents"; `tools/kerneltool/site_document_references.odin`.

## 13. The name and the repository

### D-186 The name is modus
- 2026-11-10. Decided by: the owner.
- Decision: the kernel and the system are named `modus`. The rename of the code, the tool, the bar and the README is one step of its own.
- Words: "I think that we will call this kernel modus" (recorded in English).
- State: in force. The bar and the README show the mark; the title of `README.md` is "modus" in the rewrite of the guides. Not done yet: the description of `flake.nix` still says "Next-Gen Kernel".
- Where: `FIRST_MILESTONE.md`, "Next steps", item 11.

### D-187 The repository is renamed modus
- 2026-11-12. Decided by: the owner.
- Decision: the repository on GitHub is renamed `modus` now.
- Words: "pour le renommage tu peux y aller maintenant".
- State: done (the remote is `github.com/sachahjkl/modus`).
- Where: `README.md`.

### D-188 The pictures of the repository are compressed
- 2026-11-12. Decided by: the owner.
- Decision: the PNG files are compressed with one encoder, the one of the Odin standard library. The pixels do not change.
- Words: "oui compresse les images parce que ça fait beaucoup".
- State: done.
- Where: `FIRST_MILESTONE.md`, choice 575.

### D-189 The history holds no stored picture
- 2026-11-12. Decided by: the owner.
- Decision: the history of the repository is rewritten to remove the large stored pictures. Every commit identifier changed. A backup of the old history is kept outside GitHub.
- Words: "fait un amendement au commit et force push pour retirer ces images qui ont été publiées qui sont beaucoup trop grosses 193 mégaoctets c'est trop"; then, after the coordinator said that an amend removes nothing: "et fait la technique qui réécrit l'historique".
- State: done. Commit identifiers in older records name the old history.
- Where: `REVIEWS.md`.

## Open questions for the owner

Each question waits for an answer of the owner. The proposal is what holds until then.

- **Q-01 The numbered choices.** The owner has not reviewed the choices of `FIRST_MILESTONE.md` (D-043). Proposal: the choices hold as written.
- **Q-02 The module contract.** Its four decisions are "not confirmed" (D-019), while its rules are closed (D-020). Proposal: the contract as written.
- **Q-03 Property 5 and TCP.** The network service is on the data path for TCP segments too (D-097). Proposal: the dated note in property 5.
- **Q-04 The interface package.** The model, a `support` package or a module first, and the order of the next conversions (D-111). Proposal: `INTERFACE.md` and the order of `FIRST_MILESTONE.md`, "Next steps", item 13.
- **Q-05 The rendering of the vector font.** The grid fit of the vertical metrics and the default order of the stripes (D-141). Proposal: on, and `rgb`.
- **Q-06 Error details for the kernel operations.** One instruction on every command (D-033). Proposal: a measure first, then the owner decides.
- **Q-07 Floating point and posits.** (D-124). Proposal: floating point is allowed when it is needed; integers for a display; posits are research.
- **Q-08 The picture of every pointer of Posy's Cursor.** It stays in the devlog (D-134). Proposal: as now.
- **Q-09 The temple of Jon in a post.** Until the owner decides, it is not posted (D-136, D-183).
- **Q-10 The token of Cloudflare.** The rules of the headers and the purge of the cache need a token with the rights "Transform Rules: Edit" and "Cache Purge" (D-171).
- **Q-11 The next kernel operation past 32.** (D-073). Proposal: the coordinator raises the target with a recorded reason, as the owner delegated.
- **Q-12 The machine tests in the site workflow.** Settled by D-194: the full check commits its numbers in the measure record; the workflow runs no machine test.
- **Q-13 The cache of the site workflow.** The cache of GitHub Actions now, or FlakeHub Cache (D-170).
- **Q-14 The tone of the posts.** See conflict C-10.

## Conflicts

A later decision of the owner holds unless the owner said otherwise. A conflict that is not settled is an open question.

- **C-01 The module contract: closed or not confirmed.** D-019 against D-020. Not settled: Q-02.
- **C-02 A table of named roles of the context.** A gap of step 67 asked for one; D-034 then fixed the roles at 16 to 23, and the site reads them as a reference table. Holds: D-034, because it is later and gives each role a fixed name.
- **C-03 Which list of steps.** The order of 2026-11-10 against the lists that the owner accepted later. Holds: D-048 (2026-11-12).
- **C-04 The picture of every pointer.** "Capture avec posy" against the choice to keep that picture in the devlog. Holds: D-134; the second part is Q-08.
- **C-05 "No index exists".** D-023 against the index of the storage engine. Holds: D-023 is about the metadata of modules; the storage engine has its own index. This is a reading of the coordinator.
- **C-06 Go slow, or work to the end.** D-040 against D-042. Holds: D-042 (later).
- **C-07 Error details for the kernel operations.** D-032 plans them; D-033 makes them wait for a measure. Not settled: Q-06.
- **C-08 Error records in the other services.** A gap of step 42 against step 57. Not a conflict of decisions: D-028 holds; some services remain to do.
- **C-09 Spleen enlarged.** D-112 against the fallback at three scales. Holds: D-115 (the owner, later).
- **C-10 The tone of the posts.** D-183 ("a little cryptic and opaque") against the global rules of the owner ("purposeful and natural", say what the thing is). Holds: the global rules, because D-185 (later) asks that a post say what modus is. The owner can confirm: Q-14.
- **C-11 The form of this file.** D-067 says "one line for each decision"; an entry here has up to eight lines. Holds: this form, from the brief of the coordinator. The owner can ask for one line.
- **C-12 `gui_toolkit` in the reuse list.** `PROPERTIES.md` lists `gui_toolkit` for rendering, and the global rules of the owner move shared code into it. Holds: D-110 for this project. The reuse list is not up to date.
- **C-13 SQLite: decided or open.** `REVIEWS.md` (Review 6) says the question is open. Holds: D-024 (later).
- **C-14 The TCP library in the reuse list.** `PROPERTIES.md` names lwIP or smoltcp. Holds: D-096 (a library of the system).
- **C-15 The model of the agents.** D-053 names Opus 5.5; the global rules of the owner add a model for builds. Not a conflict: D-054 gives the builds to the coordinator.
- **C-16 The head of `PROPERTIES.md`.** It says that no code exists and that each property waits for the owner. Holds: D-002. The head is not up to date.
- **C-17 An animation on the site.** D-164 was read as "no animation"; D-180 asks for an animated mark. Holds: D-180, for the large mark and the favicon only.
- **C-18 The logo through `gui_toolkit`.** The owner allowed `gui_toolkit` for the logo proposals, against D-110. Holds: D-110; the mark is data of the system and the tool uses no code of another project (D-137, D-139).
- **C-19 Who changes the limit of kernel operations.** Property 1 said that the limit changes only by a decision of the owner; D-073 gives the choice to the coordinator. Holds: D-073, because the owner delegated it later.

## Old HANDOFF numbers

Older records cite the old `docs/HANDOFF.md`. Its list "Rules from the owner" had no numbers: `B<n>` is the n-th rule. Its list "Next steps" had numbers: "item N" is that number. Before 2026-11-11, some records cited a rule by its line in the file: "item 94" was B71 and "items 93 to 95" were B70 to B72. A citation of "item 94" in a record of 2026-11-10 means B71; a later one means item 94.

### The rules from the owner

| Rule | Subject | Identifiers |
|---|---|---|
| B1 | Never commit under an AI identity | D-049 |
| B2 | Deliverables in English | D-050 |
| B3 | "Everything is a file" is rejected | D-004 |
| B4 | Relocatable modules give reproducibility | D-018 |
| B5 | QEMU with virtio | D-010 |
| B6 | TPM, UEFI programs, Secure Boot | D-012 |
| B7 | WebGPU and WGSL | D-106 |
| B8 | Odin, "odin ok" | D-149 |
| B9 | A dedicated machine | D-011 |
| B10 | The console, no TTY | D-142 |
| B11 | Do not go too fast | D-040 |
| B12 | A command is a function | D-015 |
| B13 | One module is all of them | D-017 |
| B14 | Coherent Odin libraries | D-151 |
| B15 | No contract depends on one language | D-014 |
| B16 | No shared file system | D-005 |
| B17 | Zero is initialization | D-008 |
| B18 | No save action, versions | D-092 |
| B19 | Conversation in English | D-050 |
| B20 | The glossary | D-051 |
| B21 | Flat tables | D-023, D-024 |
| B22 | Principals and sessions | D-006 |
| B23 | Usability concessions | D-007 |
| B24 | Odin is final | D-149 |
| B25 | One kernel tool | D-147 |
| B26 | Performance | D-003 |
| B27 | The linker | D-152 |
| B28 | ELF at build time | D-153 |
| B29 | `MODULE_CONTRACT.md` | D-019 |
| B30 | Properties accepted; the engine; the kernel ring | D-002, D-093, D-071 |
| B31 | Call form: registers | D-021 |
| B32 | Threads | D-074 |
| B33 | The Nix flake | D-150 |
| B34 | Layout of the repository | D-151 |
| B35 | Commands | D-150 |
| B36 | Never use `gui_toolkit`; the tool and the standard library | D-109, D-156 |
| B37 | WebGPU from nothing; `lld`; RDI; streams; BLAKE3; exports; the count of operations | D-107, D-152, D-154, D-022, D-101, D-072 |
| B38 | More research first | D-041 |
| B39 | Graphics order | D-108 |
| B40 | The RAD Linker and RDI study | D-152, D-155 |
| B41 | Module contract rules closed | D-020 |
| B42 | Goal of the first milestone | D-044 |
| B43 | Font: Spleen 8x16 | D-112 |
| B44 | Temple of Jon | D-136 |
| B45 | Direction | D-044, D-096 |
| B46 | Full queues and speed | D-076 |
| B47 | The terminal | D-143 |
| B48 | The terminal, first part | D-143 |
| B49 | The terminal, second part | D-144 |
| B50 | The scheduler | D-089 |
| B51 | Multi-threaded and multi-core | D-075 |
| B52 | Tweets | D-183 |
| B53 | The isolated call | D-046 |
| B54 | Development log | D-060 |
| B55 | Show the concepts | D-045 |
| B56 | Work to the end | D-042 |
| B57 | 64 bits only | D-009 |
| B58 | Paging and virtual memory | D-084 |
| B59 | A rich boot display | D-125, D-077 |
| B60 | No standard input or output | D-016 |
| B61 | The log in channels | D-077 |
| B62 | Several processors | D-075 |
| B63 | Push back | D-047 |
| B64 | Replacement of an import | D-026 |
| B65 | Step order | D-048 |
| B66 | The name | D-186 |
| B67 | No exceptions | D-027 |
| B68 | Errors that diagnose | D-028 |
| B69 | A program that shows the errors | D-029 |
| B70 | A program drives its virtual memory | D-085 |
| B71 | The interfaces push to data-oriented programs | D-025 |
| B72 | Tools that show memory and execution | D-148 |
| B73 | No SQLite | D-024 |
| B74 | A technical site | D-163 |
| B75 | Agents in parallel | D-053 |
| B76 | A richer look | D-130 |
| B77 | An original boot display | D-126 |
| B78 | No round corners | D-127 |
| B79 | Design rules | D-128 |
| B80 | No pull request | D-052 |

The head of the old file: the goal is D-001; "all 21 properties accepted" is D-002; "the next step is the review of the owner" is D-043.

### The numbered items

A "step report" item recorded work. It maps to the decision that the work carried out.

| Item | Subject | Identifiers |
|---|---|---|
| 1 | The review of the choices | D-043 |
| 2 | Descriptions, text results, the isolated call (step report) | D-015, D-046 |
| 3 | Rights on handles, budgets (step report) | D-078 |
| 4 | Services, rings, terminal, queue, time page (step report) | D-076, D-143, D-083 |
| 5 | Revocation of a grant (step report) | D-078 |
| 6 | Limits of a budget (step report) | D-078 |
| 7 | The menu of the windows (step report) | D-130 |
| 8 | Paging, second part (step report) | D-084 |
| 9 | Storage; the engine in Odin; SQLite | D-092, D-094, D-055 |
| 10 | Imports and replacement (step report) | D-026 |
| 11 | Information of the modules | D-024 |
| 12 | Corrections of storage (step report) | D-094 |
| 13 | One build gives one hash | D-018 |
| 14 | Boot display and design rules | D-128 |
| 15 | The first layer of the network | D-096, D-097 |
| 16 | The kernel lock split | D-075, D-056 |
| 17 | Errors that diagnose; LLVM IR | D-028, D-157 |
| 18 | The time from the cycle counter (step report) | D-083 |
| 19 | The service `remote` | D-098 |
| 20 | ARM64 not a priority | D-013 |
| 21 | The night of 2026-11-11; the readings of the look | D-130 |
| 22 | The desktop to the design rules | D-130, D-131 |
| 23 | The scheduling strategies | D-089, D-090, D-091 |
| 24 | The pictures to the devlog | D-061 |
| 25 | Four messages: interface, memory copy, names, close button | D-111, D-087, D-110, D-058, D-131 |
| 26 | TCP as a library | D-096, D-097 |
| 27 | The read of step 48 (step report) | D-056 |
| 28 | HTTP/1.1 | D-099 |
| 29 | Copy and fill of memory | D-087 |
| 30 | `inspect` | D-148 |
| 31 | The interface package, red button, vector font prototype | D-111, D-131, D-113 |
| 32 | The pointer pictures | D-132, D-133 |
| 33 | Four decisions: Posy, theme, vector font, subpixel | D-133, D-113, D-114, D-141 |
| 34 | The read of the HTTP server; the read before merge | D-056, D-099 |
| 35 | Cryptography | D-102 |
| 36 | A table as a parameter | D-030 |
| 37 | A frame cache; the build switches | D-088, D-065 |
| 38 | The interface package carries the windows (step report) | D-111 |
| 39 | The pointer pictures done | D-133, D-134 |
| 40 | The disk that loses writes; error records (step report) | D-092, D-028 |
| 41 | The first wait of 180 s | D-064 |
| 42 | Who pays a commit | D-086 |
| 43 | The threads of the compiler; the bonus patch | D-158, D-159, D-052 |
| 44 | Randomness | D-103, D-102 |
| 45 | Shapes | D-129 |
| 46 | Floating point and posits | D-124 |
| 47 | Subagent work | D-054 |
| 48 | Comments in code | D-059 |
| 49 | The compositor through the interface package (step report) | D-111 |
| 50 | A changelog | D-062 |
| 51 | Step 62 (step report) | D-158, D-062 |
| 52 | The fragment rule | D-063 |
| 53 | Kernel events | D-079 |
| 54 | The handoff goes | D-067 |
| 55 | A weak seed | D-104 |
| 56 | The newest Odin | D-161, D-162 |
| 57 | The threads measured | D-160 |
| 58 | No patch, all threads | D-160, D-159 |
| 59 | Tables and bytes as parameters | D-030, D-031 |
| 60 | A correction offered to Odin | D-105, D-052 |
| 61 | A program drives its virtual memory | D-085, D-086 |
| 62 | Versions and the date | D-092, D-095, D-083 |
| 63 | Review 10, first part | D-039 |
| 64 | A table of error details | D-032 |
| 65 | The context and the roles | D-034 |
| 66 | A line in the draw table (step report) | D-129, D-111 |
| 67 | AVX | D-080 |
| 68 | SIMD; AMX | D-135, D-082 |
| 69 | The cryptography module, QUIC (step report) | D-102, D-096, D-034 |
| 70 | The list; Posy in the pictures; a new font | D-048, D-134, D-116 |
| 71 | Paper Mono, B612, text shaping | D-117, D-118 |
| 72 | To do from the reads | D-081, D-039, D-067, D-059 |
| 73 | Error details for the exports | D-032, D-033 |
| 74 | SSE2 | D-135 |
| 75 | "Go b612"; the zero; the console | D-118, D-119, D-145 |
| 76 | The console edits and completes | D-145 |
| 77 | Paper Mono; fixed addresses; the settings page | D-117, D-036, D-037 |
| 78 | The mark | D-137, D-139 |
| 79 | Spleen enlarged as the fallback | D-115 |
| 80 | QUIC on the network | D-100, D-006 |
| 81 | The mark in the system | D-138 |
| 82 | Three answers: xsave, the zero, the list, the logo branch | D-081, D-119, D-048, D-139 |
| 83 | xsave not merged | D-081 |
| 84 | The glyph cache; Latin-1 | D-122, D-123 |
| 85 | The console after use; the history question | D-145, D-146 |
| 86 | The slashed zero; B612 drawn; the context | D-119, D-118, D-035 |
| 87 | QUIC streams (step report) | D-100 |
| 88 | The extended state at a switch | D-081 |
| 89 | The site | D-164 to D-169 |
| 90 | The interface in two fonts | D-120 |
| 91 | The console history | D-146 |
| 92 | A text never cut in silence | D-038 |
| 93 | The QUIC idle bound; a test read to its cause | D-100, D-057 |
| 94 | The compositor in B612; the boot display | D-120, D-121 |
| 95 | Research on identity; the licences of the reuse list | D-006, D-001 |

### The decisions of 2026-11-12 that were not in the old file

| Words | Identifier |
|---|---|
| "oui compresse les images" | D-188 |
| "workflow GitHub" | D-170 |
| "proxy cloud flare" | D-171 |
| "l'auteur du site" | D-172 |
| "la règle des polices" | D-120 |
| "l'écran de démarrage [...] en spleen" | D-121 |
| "le zéro barré" | D-119 |
| "les accents français" | D-123 |
| "pour l'historique" | D-146 |
| "fait ce qui est judicieux" (32 operations) | D-073 |
| "pour l'étape 11" | D-066 |
| "pour le renommage" | D-187 |
| "pour le tweet" | D-184 |
| "le domaine Modus point froment point software" | D-176 |
| The first post redone | D-185 |
| The news cards | D-174 |
| The history rewritten | D-189 |
| The tagline | D-175 |
| The favicon | D-177 |
| The scrollable tables | D-178 |
| The addresses as folders | D-179 |
| The animated mark | D-180 |
| The cycle and two scratching animations | D-181 |
| "the owner" in texts | D-070 |
| The published guides; the guides with no who | D-068, D-069 |
| A documentation like Odin's | D-182 |
| The burger menu | D-173 |
| The mark on a transparent background | D-140 |

### What the guides held

The rewrite of the guides on 2026-11-12 removed the history and the names of who decided. Each removed decision is an entry above. Four were not in the old file: D-190 (the measures under load), D-191 (no backward compatibility), D-192 (hyprcursor) and D-193 (a new decoration). The rest of the removed text is the story of the work: it is in `REVIEWS.md` and in the choices of `FIRST_MILESTONE.md`.
