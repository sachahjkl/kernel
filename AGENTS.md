# Rules for an agent that works on this repository

Read `docs/HANDOFF.md` first. It holds the decisions of the owner. `docs/PROPERTIES.md` holds the 21 properties: the fundamental concepts of the system.

## Push back

The owner asked for this rule on 2026-11-10.

- Compare each proposal of the owner with `docs/PROPERTIES.md` and with the decisions in `docs/HANDOFF.md`, before any work on it.
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
- Record each decision of the owner in `docs/HANDOFF.md` and in the document of its subject.
- The order of the next steps is in `docs/FIRST_MILESTONE.md`, section "Next steps".
- Never commit under an AI identity.
