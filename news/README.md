# news

This folder holds the news of the system: one file for each news entry (`docs/GLOSSARY.md`, "News entry"). The site shows them on the page News, the three newest on the home, and in the feed `news.xml` (`docs/SITE.md`, "The news").

The changelog and the news are two records:

- `CHANGELOG.md` is a technical list for each release: every change, for a developer of the system.
- A news entry is a dated report in prose of one thing that a reader can now see or use, for a reader who is not a developer of the system: a few sentences, one picture, the measured number when there is one, a link to its release and to its guide.

## When to write one

- A step adds one entry when a person can see or use something new: a program, a window, a command, a measured number, a choice of design that a person sees.
- A step with nothing to show adds none. A correction inside the code, a refactoring, a document only: no entry.
- One thing, one entry. Two things that a person sees separately are two entries.
- An entry is never moved, never merged with another, and not changed after its step, but to correct a fact that is wrong. A later change of the same thing is a new entry.

## The form

`kerneltool news new <subject>` writes `news/<yyyy-mm-dd>-<subject>.md` with the date of the host. The subject has only the lowercase letters a to z, the digits and `-`, at most 48 bytes.

```
title: The console completes names
date: 2026-11-11
release: 0.73.0
picture: docs/screenshots/console_completion.png
kind: Shown
guide: docs/CONSOLE.md

The text, in the Markdown of the site: a few sentences, one fact in each.
```

The head has the six keys, each once, one line `key: value` each, then an empty line, then the text:

| Key | Value |
|---|---|
| `title` | Plain text, at most 80 bytes, with no `` ` ``, `*`, `[`, `]`, `<`, `>`. No two entries have the same title |
| `date` | The date of the entry, `yyyy-mm-dd`: the date of the file name |
| `release` | A release number of `CHANGELOG.md`, or `next` when the thing is not released yet. The page of the releases links to the entry |
| `picture` | A PNG file of `docs/screenshots/` or `resources/logo/`, or `none` |
| `kind` | One of the four kinds below |
| `guide` | A document of `docs/` (`docs/<NAME>.md`) that explains the thing, or `none` |

The kinds, the colored mark of the card of the entry:

| Kind | What the entry reports |
|---|---|
| `Shown` | A reader can now see or use a new thing in the running system |
| `Measured` | A number about a thing that exists is measured, with its conditions |
| `Decided` | A choice of design that a reader sees: a name, a mark, a font. The text says what the thing is now, not who chose it |
| `Fixed` | A thing that a reader saw fail now works |

The text: at most 1200 bytes; no heading (the title is the heading); no line of HTML. Write in the simplified technical English of the repository: one fact in each sentence, no promotion, no adjective that is not measured, each number with the conditions that its document gives. A longer report belongs in the guide that the entry names. Never write "the owner": a reader of the site does not know that word; say what the thing is now.

## The commands

| Command | What it does |
|---|---|
| `kerneltool news new <subject>` | Writes a new entry with the date of the host, `release: next`, no title and no text: `news check` fails until a person writes them |
| `kerneltool news check` | Checks each entry: the head is well formed, each key known and present, the date a date of the calendar and the date of the file name, the picture a PNG file of the repository, the release a release of `CHANGELOG.md` or `next`, the guide a file, the text not empty and at most 1200 bytes, no two titles the same. `kerneltool check` runs it |
| `kerneltool site` | Writes the page of the news, the three newest entries on the home, the feed `news.xml`, and a link from each release to its entries |
