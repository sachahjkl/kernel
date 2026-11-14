# The roadmap: one file, its check, its page

## Purpose

The planned work of the system has one place: `ROADMAP.md`, at the root, next to `CHANGELOG.md`. The changelog says what is done. The roadmap says what is planned. A reader of the repository reads it with no tool. A reader of the site reads the same entries on the page of the roadmap, beside the page of the releases.

The form of the file and each rule of its check are in [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The roadmap". The page is in [`docs/SITE.md`](../../../docs/SITE.md), "The roadmap".

## Constraints

- Plain Markdown: no front matter, no metadata field, no HTML. The file must read well in a terminal and on a forge.
- A fixed shape: `# Roadmap`, then `## Now`, `## Next`, `## Later`. Each section is a list.
- An entry says what the work gives the user, in one or two sentences after a short bold summary. It does not say how the code changes.
- No date. A planned date that passed is a false sentence that nothing corrects.
- No name of a person and no identifier of a decision. That record is `docs/DECISIONS.md`.
- A work that is done leaves the file in the commit of its changelog fragment.
- The tool checks the format, as it checks the changelog.

## The chosen form

- **An entry is `- **Summary.** Sentences.`** The period is inside the bold, so the line reads as a run-in heading in plain text. The page and the search remove the period.
- **The section is the state.** An entry has no state field. It moves between sections by hand.
- **The design link is the last part of an entry**: `[Design](src/md/<file>.md)`. It is the only link of an entry. The page shows it as a line of its own, and the check proves that the file exists.
- **The summary is the identity of an entry.** Its slug is the id of the card on the page and the key of the comparison with the changelog. Two entries with one slug are refused.
- **A sentence ends at `.`, `?` or `!` outside a code span, before a space or the end.** The rule is short, and it is exact for the controlled language of the project. It counts `0.5` and a code span with a period correctly.
- **One reader for the tool and the site.** The parser is pure and has host tests. The reader of the file adds the test that each design file exists. The site calls the same reader and stops on any problem.
- **The page is three columns from 960 pixels, one column under.** The sections are one line of time, read from the left to the right. The cards are the cards of the site. The accent of a section is a color that the site already gives a meaning: the color of a program for what is in work, the color of the kernel for what is decided, the dim color for what has no order.

## The rule "remove the entry with the fragment"

The tool cannot know that a work is done. It can know that an entry of the changelog has the summary of a roadmap entry. The check refuses that.

The convention that makes the rule useful: the fragment that ends a planned work takes the summary of its entry as its bold summary. The check then fails until the entry is removed, in the same commit. A fragment with another summary is not seen. The rule helps the writer who follows it, and it proves nothing about the others.

The check reads the fragments and the releases, because a fragment becomes an entry of a release.

## Refused forms

- **A state "done" in the file.** A done work is an entry of the changelog. Two places would disagree.
- **An identifier for each entry, named by a fragment.** It is a metadata field, and the file must stay plain Markdown.
- **Dates or quarters.** See the constraint on dates.
- **The plans in the working record of the steps, or on the status page.** That record holds the past, and the status page reports what is built. One place for the plans means that no other file lists work to come.
- **Three groups one under the other at every width.** A wide window has room for the three side by side, and the longest section would start far below the first screen.
- **A feed.** An entry is not an event with a date, and it leaves the file when its work is done.
- **The site applies the changelog rule.** That rule belongs to a commit, not to a page. A site that is built between two commits must not fail for it.

## Subtle points

- A gap is not a roadmap entry. A gap is a difference between the code and the documents. It becomes planned work only when an entry names it.
- A work that is done in part keeps an entry whose summary names the part that is left. Else the check refuses it when a fragment has its summary.
- A year alone is not refused as a date: `2048 pixels` is a count.
- The preamble is free text, but it obeys the same rules on dates, HTML, decisions and persons.
- An empty section is valid. The page then says "No entry.".
- The flake reads only the files that `flake.nix` names. `ROADMAP.md` is in its file set, else the check of the flake does not see the file.
- A design link names a file of this folder. A rename of an intent file must change the roadmap in the same commit, or the check fails.

## State

Built: the file, the command `kerneltool roadmap check` with its host tests, the page, its line in the menu of the bar ([site_bar.md](site_bar.md)), the line on the page of the releases, on the home and on the status page, and the search entries.

Left: no command writes or moves an entry.
