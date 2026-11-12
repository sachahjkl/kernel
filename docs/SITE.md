# The site

Status: started on 2026-11-12, at the request of the owner (`HANDOFF.md`, "A technical site"). The owner has not reviewed the choices below.

The site (`GLOSSARY.md`) is the documentation of the system `modus`. The home is its front door: the one page that shows the system. Every other page is documentation: a guide (a document of `docs/`, how a part is designed and why) or a reference table (what exists in this build, generated from the code and the files that define it). The owner asked for this order on 2026-11-12: "we need to be more \"doc like\", even though it's obviously fine to have a landing page that kinda does the house tour and shows off".

No page holds a text that a person must remember to update: each page is generated from files of the repository and from the logs of the last machine tests.

## The command

`kerneltool site` writes the site in `build/site/`. The folder is not committed. `kerneltool site --address https://<host>/<path>` sets the address of the site for one run (see "What the owner must decide").

- One style sheet for all pages, no script, no request to another server: the pages work from a file, from a folder of a host and from the root of a domain. Each link inside the site is relative.
- Before it writes a page, the command checks all the pages. A failure stops the command with the page and the reason, and no page is written:
  - each page has one `h1`, a title and a description of at most 160 bytes; no two pages share a title or a description;
  - each `img` has an `alt` attribute (empty for a picture that only decorates a text beside it, as the heron of the bar), a `width` and a `height`;
  - each `href`, `src` and `srcset` that is not an address of another host names a page or a file that the command wrote, and its anchor is an `id` of that page.
- At its end the command prints: the pages and their bytes, the other files, the guides, the terms of the glossary, the commit and the release, the numbers that are not measured, the cells of the licenses that are not recorded, and each part of a guide that the renderer did not understand.
- `kerneltool check` runs the host tests of the site (`tools/kerneltool/site_test.odin`, `site_render_test.odin`) and checks that each picture that `README.md` names is a file of the repository. It does not write the site.

## The pages

| Page | Generated from |
|---|---|
| `index.html`, the home | The mark (`support/mark`), the first paragraph of `README.md`, the stages of the start from the lines `kernel: boot: ...` of `build/test_output.txt`, the first three measured numbers, the pictures of `docs/screenshots` with the captions of `README.md`, the newest release of `CHANGELOG.md`, the count of steps of `docs/REVIEWS.md` |
| `guides/index.html` | The table "Documents" of `README.md`, then the other documents of `docs/` by name |
| `guides/<name>.html` | Each document of `docs/` but `HANDOFF.md` and `REVIEWS.md`, which are working records of the project and stay out of the site; the glossary is a page of the reference |
| `reference/index.html` | The list of the reference tables below |
| `reference/glossary.html` | `docs/GLOSSARY.md`: each row of a table whose first column is "Term" has the anchor `term-<name>` |
| `reference/commands.html` | `COMMANDS` in `tools/kerneltool/main.odin`: the name and the text of each command |
| `reference/numbers.html` | The list `site_measures` and the logs of `build/` |
| `reference/licenses.html` | See "The licenses" |
| `releases.html` | All of `CHANGELOG.md`, newest first; each release has the anchor `release-<number>` |

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
- The first use of each term of the glossary on a page links to the term. The rule: the letters of the term with no regard to case, a whole word, or the word with an `s`; outside code, links and headings; the longest terms first; once for each term on a page.

What it does not render, shown as text and listed by the command: a mermaid diagram (shown as its code), a line of HTML, a table with no line of dashes, a fence with no end, a link to a file that is not in the repository. A single `*` or `_` is text: the documents use no italics.

Each guide has its table of contents (the headings of levels 2 and 3, beside the text on a wide screen) and links to the guides before and after it.

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
- the tables have the look of the tables of the system: the titles of the columns in the dim color, every second row on a band (`DESIGN.md`, section 10);
- the grid of points of the desktop is on the home only.

Prose is in the reading font of the reader's system, at most 72 characters a line; code, signatures, numbers and identifiers are in its monospace font. No animation, no shadow, no round corner. The light form follows `prefers-color-scheme`. A print form hides the bar and the navigation.

The contrast of the text (WCAG 2 ratio), from the colors of the rules:

| Text | On | Ratio |
|---|---|---|
| Text `0xDCE4EC` | background `0x0B1018` / card top `0x17212E` / track `0x1C2633` | 14.84 / 12.64 / 11.90 |
| Dim `0x7C8A99` | background / card top / card bottom `0x111822` | 5.40 / 4.60 / 5.05 |
| Kernel `0x4A9CF0`, program `0x58D878`, memory `0x38C0B0`, machine `0xD070B0`, as titles | card top | 5.65 / 8.90 / 7.22 / 5.12 |
| Text `0x0B1018` (light) | background `0xF4F6F8` / white / track `0xD6DBE0` | 17.60 / 19.06 / 13.68 |
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

## Not done yet

The work is in layers; each layer adds pages to a site that works.

- (a) Done: the pages, the bar, the transparent mark, the renderer, the guides; also the tables of the licenses.
- (b) Not done: the Status page (each property with its state in the words of `PROPERTIES.md`, its evidence items and the gaps that name it; the gaps and the next steps as tables), and the reference tables generated from the code: the kernel operations, the context values, the error kinds and units, the grants of the root service, the fixed ranges, the console commands, and the modules with their exports and signatures, with the tiles of the boot image on the home.
- (c) Not done: the news (`news/`, `kerneltool news`), its page and its feed.
- (d) Not done: the search.
- (e) Not done: Open Graph, JSON-LD, `sitemap.xml`, `robots.txt`, the feeds, `llms.txt`, `site.webmanifest`, the checks of the JSON-LD, the smaller pictures for `srcset`.
- The count of checks of `kerneltool check`: the tool prints each check that passed and keeps no count.
- An embedded font: Paper Mono is under the SIL OFL 1.1 with no Reserved Font Name (`resources/fonts/paper_mono.license`): its ASCII subsets can be copied into the site with `OFL.txt` and their `.license` files and declared with `@font-face`. The site uses the fonts of the reader's system.

## What the owner must decide

1. The address of the site: `SITE_ADDRESS` in `tools/kerneltool/site_frame.odin`, empty. With no address the pages have relative links only, and the command writes no canonical address, no sitemap and no absolute address, and says so. `--address` sets it for one run.
2. The host: a branch that GitHub Pages serves, a static host with a deploy key, or a server reached by `rsync`; the key stays outside the repository. A later `kerneltool site publish` builds the site, stops when a check fails, and sends `build/site/` to the host, from `master` at a release.
3. The domain, and whether the host serves it with TLS.
4. The headers that the host sends. Proposed: `Content-Security-Policy: default-src 'none'; style-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'` (`data:` for the grid of points of the style sheet; `script-src 'self'` comes with the search). The pages hold no inline script and no inline style. A `<meta>` policy is not written: `frame-ancestors` has no effect there, and `'self'` does not work for a page opened from a file.
