# changelog.d

## For an agent on a branch

- Your branch adds one fragment for each change that a reader of the system notices.
- Write it with `nix develop -c kerneltool changelog new <type> <subject> - < text.md`: the text comes from the standard input. If the text has no `` ` ``, no `$` and no quote, `"<text>"` in place of `-` also works. The command `kerneltool` runs through `odin run`, which gives the arguments to a shell: the shell runs a `` `...` `` of an argument.
- Never edit `CHANGELOG.md` or `contract/release/release.odin`. `kerneltool changelog release` writes them when the coordinator releases a step.
- If a change has no effect that a reader notices (a document, a comment, a rename inside one file), it has no fragment.

## The fragments

This folder holds the fragments: one file for each change that is not in a release yet. `CHANGELOG.md` holds the releases. Two branches never change the same lines of `CHANGELOG.md`, because they add fragments only.

A fragment is `changelog.d/<yyyymmdd-hhmmss>-<subject>.md`. The time is the time of the host when the fragment was written. The subject has only the lowercase letters a to z, the digits and `-`, at most 48 bytes.

```
type: Added

**The thing**: what the system does now, for a reader, in one or two sentences.
```

- Line 1 is `type: <type>`. The type is one of the parts of [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/):
  - `Added`: a capability that is new.
  - `Changed`: a behavior or a contract that is different (a count of kernel operations, a default).
  - `Deprecated`: a capability that a next release removes.
  - `Removed`: a capability that is gone.
  - `Fixed`: a fault of an earlier release that is corrected.
  - `Security`: a fault that a hostile caller or a hostile input can use, now closed. Name the fault plainly.
- Line 2 is empty.
- The text is one entry, as it reads in the release: one paragraph, on one or more lines, with no empty line, no heading, no `- ` at the start of a line, no space at the start or at the end of a line, no tab.
- One change, one fragment. Two fragments can have the same subject: the time keeps them apart.

## How to write the text

- Write for a person who uses or reads the system: what it does now. Not a commit message, not a list of files.
- One or two plain sentences. A bold lead (`**...**`) helps a reader who scans the list.
- Give a measured number when it matters, with its condition ("on the machine of the test, one run").
- No marketing words.

## The commands

| Command | What it does |
|---|---|
| `kerneltool changelog new <type> <subject> "<text>"`, or `-` in place of the text to read it from the standard input | Writes one fragment with the time of the host. It refuses a type that is not known, a bad subject and a text that is not one entry |
| `kerneltool changelog check` | Checks each fragment, the structure of `CHANGELOG.md`, that no fragment repeats an entry of a release, and that `RELEASE_NUMBER` is the newest release. `kerneltool check` runs it |
| `kerneltool changelog assemble` | Prints what the next release brings |
| `kerneltool changelog release <release number>` | Writes the release `## [<release number>] - <date>` from the fragments, sets `RELEASE_NUMBER`, and deletes the fragments |
| `kerneltool changelog notes <release number>` | Prints one release |
| `kerneltool release_number` | Prints the release number of the system |

In a release, the parts are in the order Added, Changed, Deprecated, Removed, Fixed, Security. Inside a part, the entries are in the order of the times of their fragments.
