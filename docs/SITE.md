# The site

Status: started on 2026-11-12, at the request of the owner (`HANDOFF.md`, "A technical site"). The owner has not reviewed the choices below.

The site (`GLOSSARY.md`) is the documentation of the system `modus`. The home is its front door: the one page that shows the system. Every other page is documentation: a guide (a document of `docs/`, how a part is designed and why) or a reference table (what exists in this build, generated from the code and the files that define it). The owner asked for this order on 2026-11-12: "we need to be more \"doc like\", even though it's obviously fine to have a landing page that kinda does the house tour and shows off".

No page holds a text that a person must remember to update: each page is generated from files of the repository and from the logs of the last machine tests. The news entries are the one text that a person writes for the site: each one is written once, in the step that made its thing, and is not updated after (see "The news").

## The command

`kerneltool site` writes the site in `build/site/`. The folder is not committed. `kerneltool site --address https://<host>/<path>` sets the address of the site for one run (see "What the owner must decide").

- One style sheet for all pages, one small script for the search (see "The search"), no request to another server: the pages work from a file, from a folder of a host and from the root of a domain. Each link inside the site is relative. Each page is whole with no script.
- Before it writes a page, the command checks all the pages. A failure stops the command with the page and the reason, and no page is written:
  - each page has one `h1`, a title and a description of at most 160 bytes; no two pages share a title or a description;
  - each `img` has an `alt` attribute (empty for a picture that only decorates a text beside it, as the heron of the bar), a `width` and a `height`;
  - each `href`, `src` and `srcset` that is not an address of another host names a page or a file that the command wrote, and its anchor is an `id` of that page;
  - no page holds code or style of its own: each `<script>` has a `src` and nothing inside, and no `<style>` element and no `style` attribute exists.
- After the checks of the pages, the command makes the index of the search and checks it against the pages (see "The search"); a failure stops it in the same way.
- At its end the command prints: the pages and their bytes, the other files, the entries and the bytes of the index of the search and the bytes of the script, the guides, the news entries, the terms of the glossary, the commit and the release, the numbers that are not measured, the cells of the licenses that are not recorded, and each part of a guide that the renderer did not understand.
- `kerneltool check` runs the host tests of the site (`tools/kerneltool/site_test.odin`, `site_render_test.odin`) and checks that each picture that `README.md` names is a file of the repository. It does not write the site.

## The pages

| Page | Generated from |
|---|---|
| `index.html`, the home | The mark (`support/mark`), the first paragraph of `README.md`, the three newest news entries, the stages of the start from the lines `kernel: boot: ...` of `build/test_output.txt`, the tiles of the boot image (see "The tiles of the boot image"), the first three measured numbers, the pictures of `docs/screenshots` with the captions of `README.md`, the newest release of `CHANGELOG.md`, the count of steps of `docs/REVIEWS.md` |
| `guides/index.html` | The table "Documents" of `README.md`, then the other documents of `docs/` by name |
| `guides/<name>.html` | Each document of `docs/` but `HANDOFF.md` and `REVIEWS.md`, which are working records of the project and stay out of the site; the glossary is a page of the reference |
| `reference/index.html` | The list of the reference tables below |
| `reference/glossary.html` | `docs/GLOSSARY.md`: each row of a table whose first column is "Term" has the anchor `term-<name>` |
| `reference/commands.html` | `COMMANDS` in `tools/kerneltool/main.odin`: the name and the text of each command |
| `reference/numbers.html` | The list `site_measures` and the logs of `build/` |
| `reference/licenses.html` | See "The licenses" |
| `releases.html` | All of `CHANGELOG.md`, newest first; each release has the anchor `release-<number>`, and a line with a link to each news entry that names it |
| `news.html`, `news.xml` | The files of `news/`; see "The news" |
| `search.json`, `search.js` | The index of the search and its script; see "The search" |
| `status.html` | See "The status page" |
| `reference/operations.html`, `context.html`, `errors.html`, `grants.html`, `fixed-ranges.html`, `console.html` | See "The reference tables" |
| `reference/modules/index.html`, `reference/modules/<name>.html` | See "The module pages" |

Each page has the bar (the heron and the name at the left, the sections as buttons: Guides, Reference, Status, News, Releases; a section appears when its page exists), breadcrumbs on each page below the home, and a foot that names the commit, the release and the time of the build, and the files that the page comes from, as links to the repository at that commit. A reference table names the files that it is read from.

The tool reads the commit from the files of git (`.git`, `HEAD`, the reference, `packed-refs`), with no program. When it cannot, the foot says so and the links to files of the repository go to `master`.

## The Markdown that the site renders

The renderer (`tools/kerneltool/site_render.odin`) knows the Markdown that the documents of `docs/` use:

- headings `#` to `######`, each with an id from its text (lowercase letters and digits, `-` between words; `-2`, `-3` for a repeated id);
- paragraphs, joined lines;
- lists `- ` and `* `, nested by their indentation, with the lines that continue an item and the fences inside an item;
- ordered items with their own label, as the documents write them (`12.`, `34b.`): a top-level item has the id `<id of the heading of level 2 above it>-<label>`, so that a page can link to an evidence item or a choice of `FIRST_MILESTONE.md`;
- tables with a line of dashes, `\|` for a `|` in a cell;
- block quotes `>`;
- fenced code, with or without a language;
- code spans, bold, links and pictures.

Links:

- A code span or a link that names a document of `docs/` becomes a link to its page. The anchor of a link to another file is dropped: the ids of the site are not the anchors of the host of the repository.
- A code span that names a file or a folder of the repository (from the root or from the folder of the document, also `file.odin:34`) becomes a link to that file at the commit of the build. The folder `build/` is not in the repository.
- A link to an address of another host stays a link.
- A code span that names a row of a reference table becomes a link to the row. The rule: the whole text of the span, with its case, is the name of one kernel operation (`Memory_Map`), one error kind (`No_Grant`) or one module (`math`); or the span is a call of a built-in command of the console (`load("math")`, `help()`). A name that two tables have links nowhere: `Bad_Address` is a status and an error kind. A status, a unit and a grant are not linked: their names (`Pages`, `Store`, `Person`) are also common words of the code. A document of `docs/` comes first, then a row, then a file of the repository.
- The first use of each term of the glossary on a page links to the term. The rule: the letters of the term with no regard to case, a whole word, or the word with an `s`; outside code, links and headings; the longest terms first; once for each term on a page.

What it does not render, shown as text and listed by the command: a mermaid diagram (shown as its code), a line of HTML, a table with no line of dashes, a fence with no end, a link to a file that is not in the repository. A single `*` or `_` is text: the documents use no italics.

Each guide has its table of contents (the headings of levels 2 and 3, beside the text on a wide screen) and links to the guides before and after it.

## The news

The owner asked for it on 2026-11-12: "\"What runs today\" watch out cause it'll be a nightmare to udate the description. we could have a \"parallel changelog\" (changelog is very technical/list-like) which would be like a \"status report\" or like \"News\"".

A news entry (`GLOSSARY.md`) is one file of `news/`, `news/<yyyy-mm-dd>-<subject>.md`, never moved or merged: a head of six lines `key: value` (`title`, `date`, `release`, `picture`, `kind`, `guide`), an empty line, then the text in the Markdown of this document. `news/README.md` gives the form, the four kinds and when a step writes an entry. The text is at most 1200 bytes (`NEWS_TEXT_LIMIT`): a few sentences for a reader; a longer report belongs in the guide that the entry names.

| Kind | What the entry reports | Its mark |
|---|---|---|
| Shown | A person can now see or use a new thing in the running system | The color of a program |
| Measured | A number about a thing that exists is measured, with its conditions | The color of memory |
| Decided | The owner chose a thing that a person sees: a name, a mark, a font | The color of the kernel |
| Fixed | A thing that a person saw fail now works | The color of the machine |

- `kerneltool news new <subject>` writes an entry with the date of the host, `release: next`, and no title and no text, so that the check fails until a person writes them. `kerneltool news check` checks each entry: the head, each key known and present once, the date a date of the calendar and the date of the file name, the picture a PNG file of `docs/screenshots/` or `resources/logo/`, the release a release of `CHANGELOG.md` or `next`, the guide a document of `docs/` that is a page of the site, the text not empty, at most 1200 bytes, with no heading and no line of HTML, and no two titles the same. `kerneltool check` runs it, and `kerneltool site` stops on the same faults.
- `news.html`: each entry, newest first, as a card with the color of its kind, its date, a link to its release and to its guide, its picture, and a link to its file. Its anchor is `news-<the name of its file>`. One renderer renders all the entries of the page, so the ids stay unique and each term of the glossary links once.
- The home shows the three newest entries: the title, the kind, the date, the picture and the first sentence.
- `releases.html`: under each release, a link to each entry that names it. An entry with `release: next` is in no release yet.
- `news.xml`: the feed, Atom (RFC 4287), newest first; each entry has its title, its date (`published` and `updated`, at 00:00 UTC), its kind as a `category`, its first sentence as its `summary`, and its text and picture as HTML in its `content`. The id of the feed and of each entry is the address of its file in the repository on `master` (`<repository>/blob/master/news/<file>`): a file of `news/` is never moved, so the id stays the same when the site gets an address. Each page names the feed in its head (`<link rel="alternate" type="application/atom+xml">`), so that a browser and a feed reader find it.

What a feed reader needs, and what is missing with no address:

- A reader subscribes to the address of the feed and resolves each relative link against it. With no address (`SITE_ADDRESS` is empty), the links of the feed are relative to the root of the site (`news.html#news-...`, `pictures/...`): they work for a reader that fetched the feed from the host of the site.
- Missing with no address: the link `rel="self"` (the feed cannot name its own place), absolute links (a reader that receives the feed as a file, or copies an entry elsewhere, cannot resolve them), and the discovery of the feed from another site. `kerneltool site --address https://...` writes absolute links and the link `self`. The command says so when the site has no address.

## The search

The owner asked for it on 2026-11-12: "une doc riche et auto générée, avec recherche, modules, etc.". The search needs no server and makes no request to another host.

### The index

`search.json` is one file that the command writes after it checks the pages:

```
{"kinds": ["page", "module", ...],
 "pages": [["<path>", "<title>"], ...],
 "entries": [["<title>", <page>, "<anchor>", <kind>, "<text>"], ...]}
```

- An entry has a title (what the match reads), its page (an index of `pages`), an anchor (an id of the page, or empty for the page itself), a kind (an index of `kinds`) and a text (the line under the list for the chosen row).
- The kinds, in their tie order: page, module, program, export, operation, error kind, console command, term, guide section, property, news, release, gap, license row. Each page of the site is an entry. The others come from the same data as their page: the modules and their exports (`module.export`, with the signature as the console prints it), the kernel operations, the error kinds, the commands of the console, the terms of the glossary with their definition, the headings of levels 2 and 3 of each guide with their first paragraph, the properties with their status, the news entries, the releases with their date and their first change, the gaps, and the rows of the two tables of licenses (each row has the id `license-<what it is>`).
- The bounds: a title has at most 128 bytes (`NAME_SCAN_LIMIT` of the match: it reads no more); a text has at most 120 bytes, cut at the start of a character; the index has at most 4096 entries (`CANDIDATE_SCAN_LIMIT`: one ranking of the console reads no more names, and the script reads them all only under that count) and at most 1 MiB. The command prints the count of entries and of bytes, and stops over a bound.
- The checks: each page of the site has at least one entry, and each entry names a page that the command writes and an id of that page.
- The JSON escapes each character that can end a string or a line of a script: the quote, the backslash, the control characters, `<`, `>`, `&` (so no `</script>`), U+2028 and U+2029. A byte that is not UTF-8 becomes U+FFFD.

### The script

`search.js` is written by the tool: plain JavaScript, no library and no build step, about 250 lines, loaded with `defer` by each page.

- On the first key in the box, it fetches `search.json` from the folder of the script. A page opened from a file cannot read another file in the browsers of today: the script then says so under the box, and the site stays whole by its links.
- The match and the order are those of the completion list of the console (`CONSOLE.md`, section 3; `support/line_editor/fuzzy_match.odin`): `lower`, `fuzzy_match`, `ranked_before` and `rank_candidates`, ported rule for rule on the UTF-8 bytes of the query and of the title. The tie order is the kind: of two entries with one score, a module comes before a guide section that has its name.
- Two things keep the script in step with the console. The tool writes the constants of `support/line_editor` (the points of each rule, the bounds) into the script. And one table of queries, names, scores and orders, `site_search_match_names` and `site_search_match_orders` in `tools/kerneltool/site_search.odin`, is run twice: by the host test `site_search_matcher_table` over the matcher of Odin, and by the script over its own matcher when the address of a page has `?selftest=1` (it prints "search self test: pass" or "FAIL" with each wrong case in the console of the browser). A change of the rule in Odin fails the host test until the table has the new scores; the new table then fails the self test of the script until the script has the new rule. No program of the repository runs the script: the self test is run in a browser.

### The look

The box and the list are those of the console (the picture `docs/screenshots/console_completion.png`):

- The box is at the right of the bar, in the place of the clock of the bar of the desktop. `/` puts the focus in it when the focus is not in a field.
- Under the box, a line says how many entries match and how many are not shown, and the keys; then at most 8 rows, the best first; then the text of the chosen row. A row is the title with the matched characters in the accent color (`COLOR_BOOT_PROGRAM`, at half its light in the light form) and, at its right in the dim color, its kind and the title of its page. The chosen row has the band of the track and the blue line at its left.
- Up and Down choose a row, Enter opens it, Escape closes the list (a second Escape leaves the box). A click opens a row.
- The query is in the address as `?q=<query>`, so that a search can be linked: a page opened with `?q=` opens the list.
- The keyboard alone works. The box is a `combobox` with `aria-expanded`, `aria-controls` and `aria-activedescendant`; the list is a `listbox` of `option` rows with `aria-selected`; the line of the count is `aria-live`. The focus is visible.

With no script, the site is whole: every page is reachable by its links, and the box is not shown (it has the attribute `hidden`, and only the script takes it away).

## The numbers

Each number is a line that a program printed in the log of a machine test, quoted whole: the line gives its own conditions. The table also gives the log, the line number, the machine that wrote the log, and the time of the log. No number is typed by hand. When the log or its line is absent, the row says "Not measured in this build." and the command lists it.

| Number | Log in `build/` | Text of the line |
|---|---|---|
| Kernel entries in one second, 1, 2 and 4 lockers | `test_output_measure.txt`, else `test_output.txt` | `locks: kernel entries in one second` |
| Reads of the time page in one second | `test_output.txt` | `clock: the time page:` |
| Wakes in one second under EEVDF | `test_output.txt` | `scheduler: EEVDF: two threads that wake each other` |
| One glyph of the vector font | `test_output.txt` | `vector_glyphs: one glyph from its outline` |
| A full frame of the compositor (the last line) | `test_output.txt` | `compositor: a full frame of` |
| Blocks read in one second, 32 in flight | `test_output.txt` | `disk: read, 1 block in each request, 32 in flight` |
| 1000 commits to a private store | `test_output_persist_1.txt` | `notes: count 1000, stopped` |
| The headers and the checksum of a UDP datagram | `test_output_network.txt` | `network: the headers and the checksum of a datagram` |
| The round trip of a UDP datagram | `test_output_network.txt` | `net: the round trip of one datagram` |
| UDP datagrams in one second, 64 in flight | `test_output_network.txt` | `net: a burst with 64 datagrams in flight` |
| TCP, 1 MiB received from the host | `test_output_tcp_real.txt` | `fetch: GET /large:` |
| TCP, 1 MiB sent to the host | `test_output_tcp_real.txt` | `fetch: POST /sink, 1 MiB` |
| ChaCha20-Poly1305 on 1200 bytes | `test_output_cryptography.txt` | `cryptography_vectors: seal ChaCha20-Poly1305` |
| The same bytes after a second build | `reproducible_build.txt` | `the same bytes after a second build` |

`kerneltool check` writes `build/reproducible_build.txt` after its comparison of two builds.

## The licenses

Two tables: what the system holds, and what builds and tests it and is not a part of it (the tools of the development shell and the UEFI firmware of the test machine). The columns: what, where it is in the repository, its license, its author or origin, its version or pinned source, and whether it is in the boot image. Each cell comes from a file:

| Rows | Files and the form the reader relies on |
|---|---|
| The system | `LICENSE`: line 1 names the license, a line `Copyright ...` |
| The vector fonts | The lists `vector_font_candidates`, `vector_font_emphasis` and `vector_font_interface` of `tools/kerneltool/vector_fonts.odin`; for each, `resources/fonts/<name>.license`: line 1 the copyright, with the address of the source in parentheses at its end; a line `... carries the name "<family>".`; a line `License of the source: <words>.` In the boot image: the default font and its emphasis, as glyph caches |
| Spleen | `support/graphics/FONT_LICENSE`: line 1 `... comes from Spleen 8x16 <version>`, line 2 `(<address>).`, a line `Copyright ...`. The file holds the text of the license, not its name: "not recorded" |
| The pointer themes | `resources/pointers/system.manifest` and `posy.manifest`: the lines `theme <name>`, `license <SPDX identifier>`, `attribution <text>` |
| The cryptography | `support/cryptography/LICENSE.odin.txt` (`(zlib)`, `tag <release>`, `(https://...)`), `LICENSE.fiat-crypto.txt` (`(BSD-1-Clause)`), the count of the lines of `origin.manifest` |
| The portrait of `temple` | `programs/temple/PORTRAIT_LICENSE`: a line `https://...`, a line `Author: ...`, the words `as public domain` |
| Versions and pins | `flake.nix`: `odinRelease = "<release>";` then `owner`, `repo`, `hash`; `buildTools = [...];`; `config.allowUnfreePredicate = ... == "<name>";`; a fetcher `<name> = name: hash:` and its line `url = "https://raw.githubusercontent.com/<owner>/<repository>/<commit>/..."`; the font sources `"<font>=${<fetcher> "<file>" "<hash>"}"` or `"<font>=${pkgs.<package>}/..."`; `OVMF_CODE = "${pkgs.<package>.fd}/..."`; `FONT_SOURCE = "${pkgs.<package>}/..."`. `flake.lock`: the first `"rev": "<commit>"` after the line `"nixpkgs": {` |
| In the boot image | The table of `build/boot.image` of the last build; "not recorded" when the image is not built |

The license column gives the SPDX identifier when the words of the file name one of the table `site_spdx_names` (a translation of recorded words: `SIL OFL 1.1` is `OFL-1.1`); else the words of the file.

The cells that no file records are listed by the command. They are the licenses of Spleen and of the tools of the build and of the firmware. The README section "Licences" is prose; the site does not read facts from it. Proposed: one table file, `LICENSES.md` at the root, with the columns above, that the README links to and the site reads, for the facts that only prose holds now.

## The look

The site follows `DESIGN.md`, with the colors of `support/graphics/rules.odin` and `support/mark`: the style sheet repeats no color of the rules as its own number. The elements of the system carry information where they appear:

- the bar at the top, as the bar of the desktop: the heron at the left, the sections as buttons, the current one marked by a line in the blue of the title bar;
- cards with a border of 1 pixel in their accent and the bar of 4 x 16 pixels before their title, as the cards of the boot display;
- the colors of the concepts with their meaning in the system: the stages of the start take the color of who runs them (the firmware violet, the boot program orange, the kernel blue);
- the tables have the look of the tables of the system: the titles of the columns in the dim color, every second row on a band (`DESIGN.md`, section 10). The cells wrap; a name (an identifier, a path, a signature) stays on one line. A table scrolls sideways only on a screen under 720 pixels;
- the grid of points of the desktop is on the home only.

Prose is in the reading font of the reader's system, at most 72 characters a line; code, signatures, numbers and identifiers are in its monospace font. No animation, no shadow, no round corner. The light form follows `prefers-color-scheme`. A print form hides the bar and the navigation.

The contrast of the text (WCAG 2 ratio), from the colors of the rules:

| Text | On | Ratio |
|---|---|---|
| Text `0xDCE4EC` | background `0x0B1018` / card top `0x17212E` / track `0x1C2633` | 14.84 / 12.64 / 11.90 |
| Dim `0x7C8A99` | background / card top / card bottom `0x111822` | 5.40 / 4.60 / 5.05 |
| Kernel `0x4A9CF0`, program `0x58D878`, memory `0x38C0B0`, machine `0xD070B0`, as titles | card top | 5.65 / 8.90 / 7.22 / 5.12 |
| Text `0x0B1018` (light) | background `0xF4F6F8` / white / track `0xD6DBE0` | 17.60 / 19.06 / 13.68 |
| A matched character of the search `0xE0A040` | card bottom `0x111822` | 7.93 |
| A matched character of the search, light, `graphics.shade(0xE0A040, 50)`, about `0x705020` | card bottom (light) / white | about 7.7 / 8.0 |
| Dim `0x4A525B` (light) | background / white | 7.32 / 7.93 |

Code takes the text color, because the dim color on the track is 4.33. The colors of the firmware (4.50 on a card) and of the boot program are used for marks, not for text.

## The mark on the site

The site draws its own pictures of the mark from `support/mark` (`tools/kerneltool/site_pictures.odin`), on a transparent background, at whole cell sizes, and the page shows each one at its own size:

| File | Cells | Size | Use |
|---|---|---|---|
| `pictures/mark_home.png`, `mark_home_light.png` | heron 8, name 6 | 198 x 250 | The head of the home, one file for each color scheme (`<picture>` and `prefers-color-scheme`) |
| `pictures/mark_bar.png`, `mark_bar_light.png` | heron 1 | 24 x 24 | The bar |
| `pictures/mark_card.png` | heron 16, name 12 | 1200 x 630 | The picture for other sites: on the dark background, because those sites show it on white. Written now; the head of a page does not name it yet |

The icons of the pages are the files `heron_24.png` to `heron_192.png` of `resources/logo`. `kerneltool logo` also writes `resources/logo/modus_transparent.png` and `modus_light_transparent.png`, which the README shows in a `<picture>` for the two color schemes.

## The status page

`status.html` gives the state of the system with no sentence of its own: each cell is a part of `PROPERTIES.md` or of `FIRST_MILESTONE.md`.

| Table | Read from, and the form the reader relies on |
|---|---|
| Properties | `PROPERTIES.md`: the number and the title of each section `## <n>. <title>`, and the column "Status" of the table `## Summary` (the reader of the first layer). The title links to the heading in the guide |
| Its evidence items | `FIRST_MILESTONE.md`: the numbered items under `## Evidence`, with their ids `evidence-<label>` in the guide. An item names a property when its text says `property <n>` (no regard to case) or `P<n>` (a capital P), as a whole word; `properties 3 and 4` names none |
| Its gaps | The items `- <text>` under `## Gaps`, and the lines that continue them (they start with a space), by the same rule. A line of text between the items (`Performance:`) is the group of the items after it |
| Gaps | Each gap, with its number (`gap-<n>` on the page, from 1 in the order of the file, with a link to its line), its group and its text |
| Next steps | The numbered items under `## Next steps`, each with a link to its id `next-steps-<label>` in the guide |

The page renders `FIRST_MILESTONE.md` and `PROPERTIES.md` again to read the ids: the renderer gives the same ids to the same text, so the links reach the guide.

## The reference tables

Each table is read from the text of the file that defines the thing (`tools/kerneltool/site_source_readers.odin`): the comments of a contract are its documentation, and the compiler drops them. Each row links to its line in the file, at the commit of the build. Under each table, the page names the file. Each reader knows one form; when a file loses it, the command stops with the file and the line.

| Page | Read from | The form |
|---|---|---|
| Kernel operations | `Operation` and `Status` in `contract/operation/operation.odin` | An enumeration: a line `<Name> :: enum <type> {`, one member a line (`<Name> = <decimal>,` or `<Name>,`, with a comment `// ...` or not), a line `}`. A line that is only a comment continues the comment of the member above it. The comment of an operation is `(<parameters>) -> <result>. <text>` or `(<parameters>): <text>`: the parameters and the result exist only as these words, and the table shows them |
| The context of a program | The constants `CONTEXT_...` and `ROOT_...` of `contract/operation/operation.odin` from the line `CONTEXT_HANDLES ::`, and `GRANT_...` of `support/system/grants.odin` | `<NAME> :: <decimal>`, with the comment lines just above it and the comment of its line. `CONTEXT_HANDLES` and `CONTEXT_VALUES` are the sizes, and a name that ends in `_COUNT` is a count: not roles. A name with `_VALUE_` is a value, another a handle |
| Error kinds and units | `Kind`, `Unit` and `UNIT_NAMES` in `contract/errors/errors.odin` | Enumerations; a table `UNIT_NAMES := [Unit]string {` of lines `.<Name> = "<text>",` |
| Grants of the root service | `Grant` and the procedure `grants_of` in `programs/root/main.odin`; `Root_Grant` and `root_grant_names` in `support/system/grants.odin` | Enumerations and a table of names; in `grants_of`, lines `case "<name>", ...:`, comment lines or not, then `return <value>`; the last `return` of the procedure is the value of each other program |
| Fixed ranges | `Fixed_Range` in `contract/fixed_addresses/fixed_addresses.odin` | An enumeration. The address is `fixed_addresses.range_of` of the compiled contract |
| Commands of the console | `programs/console/commands.odin`, `programs/console/tables.odin` | Lines `command("<name>", {.<Kind>, ...}, .<Kind>, "<help>", <procedure>)`; the signature as `help()` prints it, `Value` for the kind None of a parameter |

What the tables cannot show:

- The values 13 and 15 of the context (the settings page and the date page) have a comment in `contract/operation` and no constant: they are not in the table.
- A heading comment inside an enumeration (as "The word wait" before `Word_Wait`) shows under the member before it: the form cannot tell it from a comment that continues.
- The limits of processor time and of log records of a program come from `budget_of`, a computation: the page names it and does not show its values.

## The module pages

`reference/modules/index.html` lists each module of `module_builds` (`tools/kerneltool/modules.odin`): its name, its kind, whether it is in the boot image, its count of exports, its imports and its purpose. A module whose source is in `programs/` is a program; the others are modules. `reference/modules/<name>.html` gives:

- its documentation: the comment before `package` in its source, the text that the build writes into the module (`describe_package` of `tools/kerneltool/describe.odin`); its purpose is the first sentence;
- its source folder, its size in the boot image of the last build (or that the image is not built), its imports and the modules that import it;
- its exports, each with its signature as the console prints it (`write(name: Text, data: Text) -> Integer`, `Handle(Read, Write)`, `Table(Rectangle, Change)`) and its line of help. They come from the same reader as the build: no module needs to be built;
- for a program, its grants and its budget (pages, programs, threads) from `grants_of` and `things_of` of the root service, with the comments of those lines.

## The tiles of the boot image

The home shows one tile for each module of `build/boot.image`, as the boot display draws them (`support/bootscreen`): the width from the size of the module (5 rows of 1088 pixels for all, at least 48 pixels), the color from the first byte of its hash (`graphics.hue_color`, one rule for the boot display and the site). Each tile links to its module page. The colors and the widths are rules of the style sheet, because the pages hold no inline style. When the image is not built, the tiles are the modules of `module_builds` that it holds, with no size and no color, and the home says so.

## Not done yet

The work is in layers; each layer adds pages to a site that works.

- (a) Done: the pages, the bar, the transparent mark, the renderer, the guides; also the tables of the licenses.
- (b) Done: the status page, the reference tables generated from the code, the module pages, the tiles of the boot image on the home, the links from the code spans of the guides to the rows.
- The metadata for other sites goes into the head of `site_page_html`, which writes every page.
- (c) Done: the news (`news/`, `kerneltool news`), its page, its door on the home, its feed and its links from the releases.
- (d) Done: the search: its index, its script, its box in the bar.
- (e) Not done: Open Graph, JSON-LD, `sitemap.xml`, `robots.txt`, a feed of the releases, `llms.txt`, `site.webmanifest`, the checks of the JSON-LD, the smaller pictures for `srcset`. Their places: the metadata of a page goes into the head that `site_page_html` writes (after the link to the feed); `sitemap.xml` and `robots.txt` need the address of the site and are written next to `news.xml` in `site_build`; a feed of the releases is a second `site_*_feed` beside `site_news_feed`, from `site.changelog`, linked from the head as the feed of the news is. The search adds each new page to its index by itself: a page is an entry.
- The count of checks of `kerneltool check`: the tool prints each check that passed and keeps no count.
- An embedded font: Paper Mono is under the SIL OFL 1.1 with no Reserved Font Name (`resources/fonts/paper_mono.license`): its ASCII subsets can be copied into the site with `OFL.txt` and their `.license` files and declared with `@font-face`. The site uses the fonts of the reader's system.

## What the owner must decide

1. The address of the site: `SITE_ADDRESS` in `tools/kerneltool/site_frame.odin`, empty. With no address the pages have relative links only, and the command writes no canonical address, no sitemap and no absolute address, and says so. `--address` sets it for one run.
2. The host: a branch that GitHub Pages serves, a static host with a deploy key, or a server reached by `rsync`; the key stays outside the repository. A later `kerneltool site publish` builds the site, stops when a check fails, and sends `build/site/` to the host, from `master` at a release.
3. The domain, and whether the host serves it with TLS.
4. The headers that the host sends. Proposed: `Content-Security-Policy: default-src 'none'; style-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'` (`data:` for the grid of points of the style sheet). With the search: `script-src 'self'; connect-src 'self'`, for the script and for its fetch of `search.json`. The pages hold no inline script and no inline style. A `<meta>` policy is not written: `frame-ancestors` has no effect there, and `'self'` does not work for a page opened from a file.
