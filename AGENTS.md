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

## Work

- One term for one concept. Define a term in `docs/GLOSSARY.md` before its first use.
- Each step adds one capability to a system that works. Each step is a tested commit on `master`.
- All automation is a command of `tools/kerneltool`. Run it with `nix develop -c kerneltool <command>`.
- Record each decision in `docs/DECISIONS.md`, with the next free identifier, at the end of its group. The guide of its subject states the rule with no who.
- A guide never names a person or a role of the project, a step, a choice or a date of a decision (owner, 2026-11-12; D-069). That record is `docs/DECISIONS.md`.
- A news entry never says "the owner" (owner, 2026-11-12; D-070). It states the fact.
- The order of the next steps is in `docs/FIRST_MILESTONE.md`, section "Next steps".
- Names (owner, 2026-11-11): no esoteric, over-compressed name of a type, a function, a field or a file. Use long, descriptive names of complete words (`copy_bytes_without_overlap`, not `memcpy`).
- Pictures (owner, 2026-11-11): each picture that you produce and view goes in `~/Projects/kernel-devlog`, in a dated folder. Never delete a folder of the devlog.
- A full check is `kerneltool screenshots` AND `nix flake check` (the flake sees only the folders that `flake.nix` names: a new top-level folder must be added there).
- Comments in code (owner, 2026-11-11): a comment in a source file gives the reason itself, in plain words. It names no number of a property, a choice, a step or a review finding, and no date of a decision. Those stay in the documents. A pointer to a document is allowed ("docs/MODULE_CONTRACT.md, section 4").
- Forms (owner, 2026-11-11): rectangular forms are the preference, not an absolute rule. Lines at an angle are allowed; any geometry can be drawn, sparingly. Avoid a look where everything is a rounded blob.
- Subagents (owner, 2026-11-11): a subagent that writes code only writes code. The coordinator reviews, builds, tests, commits and merges.
- Never commit under an AI identity.
- Changelog (owner, 2026-11-11): a branch adds one fragment in `changelog.d/` for each change that a reader notices (`kerneltool changelog new`; read `changelog.d/README.md`). Never edit `CHANGELOG.md` or `contract/release/release.odin`: `kerneltool changelog release` writes them.
