# Rules for an agent that works on this repository

Read `docs/DECISIONS.md` first. It holds the decisions of the project: who decided what, when, and in which words. `docs/PROPERTIES.md` holds the 21 properties: the fundamental concepts of the system.

## Push back

The owner asked for this rule on 2026-11-10 (D-047).

- Compare each proposal of the owner with `docs/PROPERTIES.md` and with the decisions in `docs/DECISIONS.md`, before any work on it.
- If a proposal contradicts a property or a decision, say so first. Name the property or the decision, and state the contradiction in one or two sentences.
- Do not implement the proposal in silence, and do not bend it in silence into something else.
- Propose the nearest form of the idea that keeps the properties, if one exists. If none exists, say that.
- The owner decides. If the owner keeps the proposal after the objection, change the property or the decision in the documents first, with the date, then implement.
- A proposal that agrees with the properties needs no objection. Do not invent one.
- Apply the same test to your own ideas.

## Intent

The owner asked for this rule on 2026-11-14.

- This project follows <https://srcmd.org>, with the Markdown in `src/md`, as the standard suggests. Read `src/md/README.md` first.
- A file of `src/md` is an intent file (`docs/GLOSSARY.md`): it records the intent of a part of the system: its purpose, its design, the forms that were refused and why, its subtle points. It is not a guide: a guide of `docs/` says what the system does and how to use it, and the site shows it. It is not the record of who decided what: that is `docs/DECISIONS.md`.
- A design goes in `src/md` before its code. A change of design changes its intent file in the same commit as the code.
- Never write a design in a folder outside the repository. A review, a log and a measure of one run are process documents: they do not go in `src/md`.
- `src/md/README.md` has the section `## File Index`. It lists and links every other file of the folder, one line each, with paths relative to `src/md`. `kerneltool check` checks it (`intent_index_check`).
- The rules of the form of an intent file are in `src/md/README.md`, "The rules of this folder".
- The folder `src` holds everything that becomes the system. The design of that layout, and the order of the move of the code into it, is `src/md/infrastructure/repository_layout.md`.

## Roadmap

The owner asked for this rule on 2026-11-14.

- `ROADMAP.md`, at the root of the repository, next to `CHANGELOG.md`, holds the planned work of this project. It is the one place of the plans: do not keep a plan in `docs/FIRST_MILESTONE.md`, in `docs/HANDOFF.md`, in a guide or in a to-do file outside the repository.
- The file is plain Markdown that a reader understands without a tool: no YAML, no front matter, no metadata field, no HTML.
- Its shape: the title `# Roadmap`, then the sections `## Now`, `## Next` and `## Later`, in this order. Each section is a list. `Now` is the work in progress, `Next` the work that is decided and comes after, `Later` the work that is wanted and has no order. Give no dates.
- A roadmap entry (`docs/GLOSSARY.md`) is `- **<summary>.** <one or two sentences>`: a short bold summary, then what the work gives the user of the system, or the developer who builds on it. Do not say how the code changes. Name no person and no decision.
- If an intent file holds the design of the work, end the entry with its design link: `[Design](src/md/<file>.md)`.
- When you plan a work, add its entry. When a work starts or is decided, move its entry to its section.
- When a work is done, the agent or the coordinator who commits it removes its entry in the same commit as its changelog fragment. Give that fragment the summary of the entry as its bold summary: `kerneltool roadmap check` then fails until the entry is removed. If a part of the work is left, keep an entry whose summary names that part.
- `kerneltool roadmap check` checks the format of the file, as `kerneltool changelog check` checks the changelog. `kerneltool check` runs it. The rules are in `docs/TOOLS.md`, "The roadmap".
- The site shows the file on the page Roadmap, beside the page Releases (`docs/SITE.md`, "The roadmap"). `kerneltool site` stops on a fault of the form of the file.

## Work

- One term for one concept. Define a term in `docs/GLOSSARY.md` before its first use.
- A term of the glossary is a heading of level 3 in its group: a short definition of one sentence that stands alone, then an explanation (what it is for, how it is used, what it is not, an example, a reference to its design), then "Do not use:" (`docs/SITE.md`, "The glossary").
- Each step adds one capability to a system that works. Each step is a tested commit on `master`.
- All automation is a command of `tools/kerneltool`. Run it with `nix develop -c kerneltool <command>`.
- Keep the documentation up to date (owner, 2026-11-12): a change of the code changes, in the same commit, each document that describes it: the guide of its subject, the glossary, `README.md`, `docs/FIRST_MILESTONE.md`, the changelog fragment and the news entry when a person sees the change. A document that says what the code no longer does is a fault, as a failing test is.
- Features first (owner, 2026-11-12): write several features in parallel. A merge needs its build and the test of its own part; kernel code keeps its independent review before the merge. The full check, the release and the publication of the site run once, at the end of a batch.
- Record each decision in `docs/DECISIONS.md`, with the next free identifier, at the end of its group. The guide of its subject states the rule with no who.
- A guide never names a person or a role of the project, a step, a choice or a date of a decision (owner, 2026-11-12; D-069). That record is `docs/DECISIONS.md`.
- A news entry never says "the owner" (owner, 2026-11-12; D-070). It states the fact.
- The planned work and its order are in `ROADMAP.md` (the section "Roadmap" above). `docs/FIRST_MILESTONE.md` keeps the record of what is done.
- Names (owner, 2026-11-11): no esoteric, over-compressed name of a type, a function, a field or a file. Use long, descriptive names of complete words (`copy_bytes_without_overlap`, not `memcpy`).
- Pictures (owner, 2026-11-11): each picture that you produce and view goes in `~/Projects/kernel-devlog`, in a dated folder. Never delete a folder of the devlog.
- A test never depends on the speed of the hardware (owner, 2026-11-12): a test checks a condition, and a time in it only ends a hang. Use the one hang bound (`HANG_BOUND` in the tool, `system.TEST_HANG_BOUND_MILLISECONDS` in a program), on a stall where the case can count its progress. Never assert a speed, a duration or a rate: print it as a measure. A behaviour in time is checked by order and by the clock of the system, with no upper bound but the hang bound. Read `docs/TOOLS.md`, "The bounds of the tests".
- A full check is `kerneltool screenshots` AND `nix flake check` (the flake sees only the folders that `flake.nix` names: a new top-level folder must be added there).
- Comments in code (owner, 2026-11-11): a comment in a source file gives the reason itself, in plain words. It names no number of a property, a choice, a step or a review finding, and no date of a decision. Those stay in the documents. A pointer to a document is allowed ("docs/MODULE_CONTRACT.md, section 4").
- Forms (owner, 2026-11-11): rectangular forms are the preference, not an absolute rule. Lines at an angle are allowed; any geometry can be drawn, sparingly. Avoid a look where everything is a rounded blob.
- Subagents (owner, 2026-11-11): a subagent that writes code only writes code. The coordinator reviews, builds, tests, commits and merges.
- Never commit under an AI identity.
- Changelog (owner, 2026-11-11): a branch adds one fragment in `changelog.d/` for each change that a reader notices (`kerneltool changelog new`; read `changelog.d/README.md`). Never edit `CHANGELOG.md` or `src/library/contract/release/release.odin`: `kerneltool changelog release` writes them.
