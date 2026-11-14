# The site

Status: started on 2026-11-12, at the request of the owner (`DECISIONS.md`, D-163). The owner has not reviewed the choices below.

The site (`GLOSSARY.md`) is the documentation of the system `modus`. The home is its front door: the one page that shows the system. The docs (`GLOSSARY.md`) are the documentation: a guide (a document of `docs/`, how a part is designed and why) or a reference table (what exists in this build, generated from the code and the files that define it), under one section with a home of its own, the docs home (`GLOSSARY.md`). The status, the news and the releases are sections of their own. The owner asked for this order on 2026-11-12: "we need to be more \"doc like\", even though it's obviously fine to have a landing page that kinda does the house tour and shows off".

No page holds a text that a person must remember to update: each page is generated from files of the repository and from the logs of the last machine tests. The news entries are the one text that a person writes for the site: each one is written once, in the step that made its thing, and is not updated after (see "The news").

## The command

`kerneltool site` writes the site in `build/site/`. The folder is not committed. `kerneltool site --address https://<host>/<path>` sets the address of the site for one run (see "What the owner must decide").

- One style sheet for all pages, one small script for the search (see "The search") and a few small scripts of one page each (the animations of the mark and the carousel on the home, the module graph, the index of the glossary), no request to another server: the pages work from a file, from a folder of a host and from the root of a domain. Each link inside the site is relative. Each page is whole with no script.
- Before it writes a page, the command checks all the pages. A failure stops the command with the page and the reason, and no page is written:
  - each page has one `h1`, a title and a description of at most 160 bytes; no two pages share a title or a description;
  - each `img` has an `alt` attribute (empty for a picture that only decorates a text beside it, as the heron of the bar), a `width` and a `height`;
  - each `href`, `src` and `srcset` that is not an address of another host names a page or a file that the command wrote (a link that ends with `/` names the `index.html` of the folder, and the query of a file version is ignored), and its anchor is an `id` of that page;
  - a link to a page has the form of the build (see "The addresses of the pages"): with a site address it names the folder, with none the `index.html`;
  - each redirect page (`GLOSSARY.md`) is at a path that no page and no file of the site has, and its refresh and its link name a page that the command writes, never another redirect page; no two pages have one old path;
  - each page has exactly one search field (`GLOSSARY.md`): in the bar, but on the docs home, where it is in the page and the bar has none (`site_search_field_problem`);
  - each `srcset` candidate names a file that the command wrote;
  - a page of the documentation layout has one documentation tree and one list "On this page", and each link of the list names an id of the page; a page of the presentation layout has neither (see "The two layouts");
  - each list under an item of a list, inside a `nav` element, is a list of tree lines (see "The tree lines");
  - no page holds code or style of its own: each `<script>` has a `src` and nothing inside, but the one `<script type="application/ld+json">` of the page graph, whose text has no `<`; no `<style>` element and no `style` attribute exists;
  - no page names a document of the repository as bare text (see "The count and the check").
- Then the command checks what other programs read (see "What other sites read"); a failure stops it in the same way.
- After the checks of the pages, the command makes the index of the search and checks it against the pages (see "The search"); a failure stops it in the same way.
- At its end the command prints: the pages and their bytes, the count of the redirect pages and the count of each generation of old addresses, the other files, the bytes of the style sheet and the count of the icons inside it, the entries and the bytes of the index of the search and the bytes of the script, the bytes of each page of the glossary with its bound (see "The glossary"), the guides, the news entries, the terms of the glossary, the commit and the release, the numbers that are not measured, the cells of the licenses that are not recorded, the count of the document references and the first three whose labels found no heading (see "The references to documents"), the count of the declarations of the sources and of the files that the parser refused, and the count of the code spans that link to a declaration, that are ambiguous and that name no declaration, with the first five of the last two (see "The declarations of the sources"), the counts of the module graph and its modules with no entry that no module imports (see "The module graph"), each part of a guide that the renderer did not understand, the parts that it did not write with no site address (or, with one, the parts that it wrote), and the count of the pictures of the repository that it compressed, with their bytes before and after, and the count and the bytes of the thumbnails of the gallery, with the bytes of the same pictures at full size.
- Before any of these, the command checks the gallery table against the folder `docs/screenshots` (see "The gallery table"); a picture that the table does not name stops it.
- `kerneltool check` runs the host tests of the site (`tools/kerneltool/site_test.odin`, `site_render_test.odin`) and checks that each picture that `README.md` names is a file of the repository. It does not write the site.

## The pages

A page named by a folder (`news/`) is the `index.html` of that folder (see "The addresses of the pages").

| Page | Generated from |
|---|---|
| `index.html`, the home | The mark (`support/mark`), the first sentence of the first paragraph of `README.md` as the tagline of the head, the three newest news entries, the rest of that paragraph in a section "What it is" after the news (the owner, 2026-11-12: "la tagline est trop longue"; after the news, so that the first screen of a phone holds the mark, the name, the tagline and the links only; the description of the home in its head, Open Graph, the manifest and the page graph stays the whole paragraph, cut at 160 bytes, because the tagline alone is too short to describe the system), the line of time of the start from the lines `kernel: boot: ...` of `build/test_output.txt` or of the measure record (see "The measure record"), the tiles of the boot image (see "The tiles of the boot image"), the charts of the measures, the carousel of the pictures of the gallery table that the home shows (see "The carousel of the home"), the band of the newest release of `CHANGELOG.md`, with the count of steps of `docs/REVIEWS.md`; see "The home" |
| `gallery/`, the gallery | The gallery table and the pictures of `docs/screenshots`; see "The gallery" |
| `pictures/thumbnails/<name>.png` | The thumbnail of each picture of the gallery; see "The thumbnails" |
| `docs/`, the docs home | See "The docs home" |
| `docs/guides/` | The table "Documents" of `README.md`, then the other documents of `docs/` by name |
| `docs/guides/<name>/` | Each document of `docs/` but the working records `HANDOFF.md`, `REVIEWS.md`, `SITE.md` and `FIRST_MILESTONE.md` (`SITE_WORKING_RECORDS`), which stay out of the site: only the guides that explain the system are published. A link of a page to a working record names the file in the repository. The intent files of `src/md` are not in `docs/` and are not pages either. The glossary is a page of the reference |
| `docs/reference/` | The list of the reference tables below |
| `docs/reference/glossary/` | The index of `docs/GLOSSARY.md`: every term from A to Z, each row with the anchor `term-<name>` (see "The glossary") |
| `docs/reference/glossary/<group>/` | One group of `docs/GLOSSARY.md`, by the slug of its heading: each term of the group is an entry with the anchor `term-<name>` |
| `docs/reference/commands/` | `COMMANDS` in `tools/kerneltool/main.odin`: the comment above `COMMANDS ::` (what the tool is and how to run a command) at the top; for each command its name, the comment lines just above its entry as its documentation (the first sentence is the cell "What it does"), and its help, the line that `kerneltool help` prints |
| `docs/reference/numbers/` | The list `site_measures`, the measure record `docs/measures/measures.txt` and the logs of `build/` that are newer than it |
| `docs/reference/licenses/` | See "The licenses" |
| `releases/` | All of `CHANGELOG.md`, newest first; each release has the anchor `release-<number>`, each of its changes the anchor `release-<number>-change-<its place in the release, from 1>`, and a line with a link to each news entry that names it |
| `roadmap/` | All of `ROADMAP.md`: the planned work, in the sections Now, Next and Later; see "The roadmap" |
| `news/`, `news.xml` | The files of `news/`; see "The news" |
| `search.json`, `search.js` | The index of the search and its script; see "The search" |
| `version.json` | The commit and the time of the build; see "A page of an older build" |
| `fonts/modus_mark.ttf` | The font of the name of the mark, from `support/mark`; see "The name of the mark" |
| `releases.xml` | The feed of the releases, from `CHANGELOG.md`; see "What other sites read" |
| `site.webmanifest`, `llms.txt` | The name, the colors and the icons of the site; the pages with their descriptions in Markdown |
| `sitemap.xml`, `robots.txt` | Only with a site address; see "What other sites read" |
| `status/` | See "The status page" |
| `docs/reference/operations/`, `context/`, `errors/`, `grants/`, `fixed-ranges/`, `console/` | See "The reference tables" |
| `docs/reference/modules/`, `docs/reference/modules/<name>/` | See "The module pages" |
| `docs/reference/module-graph/` | See "The module graph" |
| `docs/reference/types/` | See "The types" |

Each page has the bar (the heron and the name at the left, then the sections: three buttons, Docs, Gallery and News, and the project menu, whose panel holds Status, Releases and Roadmap, see "The buttons and the menu of the bar"; a section appears when its page exists; on a guide or a page of the reference, Docs is the current one), breadcrumbs on each page below the home (Home / Docs / Guides / <guide>; Home / Docs / Reference / <page>; Home / Docs / Reference / Modules / <module>; Home / Status), and a foot that first names the maker ("modus · by Froment Software": the name of the system in the font of the name of the mark, the mark of the maker at 16 pixels, `resources/site/froment_software.png`, and its name as a link to its site, on one line), then names the commit, the release and the time of the build, and the files that the page comes from, as links to the repository at that commit. A reference table names the files that it is read from.

The tool reads the commit from the files of git (`.git`, `HEAD`, the reference, `packed-refs`), with no program. When it cannot, the foot says so and the links to files of the repository go to `master`.

## The addresses of the pages

The owner asked for it on 2026-11-12: "j'aimerais des urls genre /reference/licenses au lieu de licenses.html (possible avec index.html dans dossier". Then, of the two sections Guides and Reference: "pourquoi \"reference\" et pas \"docs\" ? ça parle plus aux gens ?", and "on garde une page d'index sur docs avec un sous chemin reference et guides ?".

- Each page is the `index.html` of its own folder: `docs/reference/licenses/index.html`, `docs/guides/NETWORK/index.html`, `news/index.html`. The home is `index.html` at the root. `site_page_file` in `tools/kerneltool/site_frame.odin` gives the file of a page from its folder; no other code writes the path of a page.
- The folders come from one place: `SITE_DOCS_FOLDER` (`docs`), `SITE_GUIDE_FOLDER` and `SITE_REFERENCE_FOLDER` under it, the folder of each reference table under the reference, and `site_section_folders` for the page of each section. A change of these lines moves the pages, the links, the canonical addresses, the sitemap, the page graphs, the feeds, `llms.txt` and the index of the search together.
- The address of a page is its folder with a final slash: `/docs/reference/licenses/`. GitHub Pages serves the `index.html` of a folder at that address, and it redirects the address with no final slash to it.
- `site_page_link` writes each link from a page to a page, in one of two forms:
  - With a site address (the published site): the folder, `../../../docs/reference/licenses/`, and `./` for the home from the home.
  - With no site address (the site opened from a disk): the file, `../../../docs/reference/licenses/index.html`. A browser shows a folder of a disk as a list of its files, not as its `index.html`.
- A link to a file that is not a page (the style sheet, the script, a picture, an icon, a feed, the manifest) is relative in the same way, one `../` for each folder of the page.
- The canonical address, Open Graph, the `@id`s of the page graph, the sitemap, `llms.txt` and the two feeds name the folder of each page. With no site address, `llms.txt` and the feeds name the `index.html` from the root.
- `search.json` holds the link of each page from the root of the site, in the form of the build. The script joins it to its own folder and applies no rule of its own.

### The sections

The bar names the six sections under the home (`site_section_parents`): Docs, Gallery and News as buttons, and Status, Releases and Roadmap as the lines of the project menu (see "The buttons and the menu of the bar"). Releases and Roadmap stand side by side in the menu: the work that is done, then the work that is planned. The guides and the reference are the two parts of the docs: their pages are under `docs/`, their breadcrumbs pass through the docs home, and the bar marks Docs on each of their pages. The word of the section and of its page is "Docs" (`GLOSSARY.md`): "Documentation" is already the term for the text that a module carries. "Guides" and "Reference" stay the names of the two parts.

The status page stays at `status/`, a section of its own, in the project menu of the bar: it reports the state of the properties and the gaps, not how the system works. The planned work is on the page of the roadmap. The tree of the reference still lists it, as before.

The gallery is a section under the home, and a button of the bar; the home has its door too (see "The page of the gallery"). Its breadcrumbs are Home / Gallery.

### The redirect pages

The old addresses were public. Two generations of them exist, and each old address of each page keeps a redirect page (`GLOSSARY.md`) straight to the address of today:

| Generation | Example | Public | Which pages |
|---|---|---|---|
| The `.html` files (`.Html_Files`) | `guides/NETWORK.html`, `reference/licenses.html`, `news.html` | From the first publication to the addresses as folders | Each page that is not an index page: an index page had the `index.html` of its folder already |
| The folders before the docs (`.Folders_Before_Docs`) | `guides/NETWORK/`, `reference/licenses/`, `reference/modules/console/`, `guides/` | From the addresses as folders to the move under `docs/` | Each page under `docs/`: the guides, the reference and their index pages |

- `site_old_page_paths` gives every old path of a page by rule from its path of today, not from a typed list: the folder of the page without `docs/` in front gives the old folder, then `<old folder>.html` for a page that is not an index page. The home was always the root, and the docs home is new: neither has an old path. The status, the news and the releases did not move: they have the `.html` path only.
- `site_redirects_make` writes one redirect page at each old path, to the page of today: a redirect page never names another redirect page. Two pages with one old path stop the command.
- A redirect page has a title, `<meta name="robots" content="noindex">`, a refresh with a delay of 0 to the new address (relative), and one visible link to it. It has no script, no bar, no `h1` and no description.
- With a site address it also names the new address as its canonical address. With none it has no canonical address, as no page has one.
- It is not a page of the site: it is not in the sitemap, the index of the search, `llms.txt` or the feeds, and the checks of the pages, of the page graph and of the search do not apply to it.
- The check (`site_check_redirects`): its path is not the path of a page or of a file of the site, and its refresh and its link name a page that the command writes, never another redirect page.
- The command prints the count of the redirect pages, and the count of each generation. With the pages of today (17 guides, 12 reference pages that are not index pages, 81 module pages, the three index pages of the guides, the reference and the modules, and the status, the news and the releases), it expects 113 of each: 226 redirect pages, and two more for the page of each group of the glossary (14 groups: 254), and one more of the `.html` files for the gallery (`gallery.html`). The page of the module graph, the pages of the groups of the glossary and the gallery have the redirect pages of the rule, though their old addresses were never public: the rule has no exception. The index of the glossary is not an index page in this sense: it keeps its old path `reference/glossary.html`. A redirect page has no script, so it does not keep the anchor of an old address: `reference/glossary.html#term-<name>` opens the index at its top.
- The host test `site_addresses_of_every_page` checks, with a site address and with none: every old path of both generations has its redirect page, which names its page; no old path is a page; a redirect to a page that is not written, to another redirect, or at the path of a file or a page fails the check; two pages with one old path fail; and the sitemap, the index of the search, `llms.txt` and the two feeds name no old address.

## The Markdown that the site renders

The renderer (`tools/kerneltool/site_render.odin`) knows the Markdown that the documents of `docs/` use:

- headings `#` to `######`, each with an id from its text (lowercase letters and digits, `-` between words; `-2`, `-3` for a repeated id);
- paragraphs, joined lines;
- lists `- ` and `* `, nested by their indentation, with the lines that continue an item and the fences inside an item;
- ordered items with their own label, as the documents write them (`12.`, `34b.`): a top-level item has the id `<id of the heading of level 2 above it>-<label>`, so that a page can link to an evidence item or a choice of `FIRST_MILESTONE.md`;
- tables with a line of dashes, `\|` for a `|` in a cell;
- block quotes `>`;
- fenced code, with or without a language;
- code spans, bold, italics (`*words*`: a star with a space after it, or between two letters, is a star), links and pictures.

Links:

- A code span that names a document of `docs/` (`ARCHITECTURE.md`, `docs/FONTS.md`, `FIRST_MILESTONE.md`), with the labels of a place after it (`ARCHITECTURE.md`, "The fault ring"; `docs/FONTS.md`, section 12.4), is a document reference (see "The references to documents"). In a heading it stays code.
- A link that names a document of `docs/` becomes a link to its page, with its own text. The anchor of a link to another file is dropped: the ids of the site are not the anchors of the host of the repository.
- A code span that names a file or a folder of the repository (from the root or from the folder of the document, also `file.odin:34`) becomes a link to that file at the commit of the build. The folder `build/` is not in the repository.
- A link to an address of another host stays a link.
- A code span that names a row of a reference table becomes a link to the row. The rule: the whole text of the span, with its case, is the name of one kernel operation (`Memory_Map`), one error kind (`No_Grant`) or one module (`math`); or the span is a call of a built-in command of the console (`load("math")`, `help()`). A name that two tables have links nowhere: `Bad_Address` is a status and an error kind. A status, a unit and a grant are not linked: their names (`Pages`, `Store`, `Person`) are also common words of the code. A document of `docs/` comes first, then a row, then a file of the repository.
- A code span that names a declaration of the sources (`blend_coverage_row_in_order`, `graphics.mix`, `layout_place()`) is a link to it, with a declaration card; a code span that is a fragment of Odin (`square_root[(d * d) >> 12]`) is colored as a block of code. A document, a row and a file come first. See "The declarations of the sources".
- The first use of each term of the glossary on a page links to the term, with its short definition as the tooltip of the link. The rule: the letters of the term with no regard to case, a whole word, or the word with an `s`; outside code, links and headings; the longest terms first; once for each term on a page. The link names the entry on the page of the group of the term, never the index of the glossary. On the page of a group the rule holds inside each entry, and an entry never links its own term. The index of the glossary links no term in its text: each row is the link to its term.

What it does not render, shown as text and listed by the command: a mermaid diagram (shown as its code), a line of HTML, a table with no line of dashes, a fence with no end, a link to a file that is not in the repository. A `_` is text.

The same renderer writes the source comments, in its mode for comments (see "The Markdown of a source comment").

Each guide has the documentation layout (see "The two layouts"): its headings of levels 2 and 3 are in "On this page". It links to the guides before and after it.

## The glossary

The glossary (`docs/GLOSSARY.md`) is one source, read by one reader: `glossary_read` (`tools/kerneltool/glossary.odin`). The pages of the glossary, the links to a term on the other pages, the entries of the search, the page graph, the references to a term and the check of the tool all take the terms that it gives.

### The form of an entry

- A group is a heading of level 2. The text under it, before its first term, is its introduction.
- A term is a heading of level 3 in its group. Its name is the text of the heading, with no code marks. Its anchor is `term-<name>`, the name as the rule of the ids gives it; a second term of the same name gets `-2`, as a heading does.
- The first paragraph under the heading is the short definition: one sentence that stands alone, with no document reference. The site shows it alone: as the tooltip (`title`) of each link to the term on another page, in a result of the search, and as the `description` of the term in the page graph.
- The paragraphs after it are the explanation, in the Markdown of the guides: what the term is for, how a program gets and uses it, its neighbours, what it is not, an example from the system, and a document reference to its full design.
- The last paragraph starts with "Do not use: " and lists the words that the term replaces. It is optional.

`glossary_read` refuses a table of terms (the form before this one), two groups whose headings have one slug (each group is a page, named by its slug), a term before the first group, a term with no short definition or whose first paragraph is a list, a table, a quote or a fence, a heading of level 4 or more inside an entry, and a line "Do not use" that is not the last paragraph of its entry. `kerneltool check` and `kerneltool site` stop on each of them, with the line.

### The terms with no explanation

`kerneltool check` prints the count of the terms that have a short definition and no explanation, and their names by group, as a warning: a short definition alone is the summary that a reader of another system cannot use. The warning becomes a failure when every group has its explanations.

### The pages

The glossary is one page for each group and an index. A single page of every entry passed 1 MB before compression: a browser lays out the whole page before it shows the entry of a link. No page of the glossary passes 1 MB (`SITE_GLOSSARY_PAGE_BYTE_LIMIT`), and the command prints the bytes of each one with that bound.

The page of a group, `docs/reference/glossary/<group>/` (the slug of the heading of the group):

- Its `h1` is the name of the group, with the slug as its id. A line under it names the glossary and the count of the terms of the group. The text under the heading of the group in the file follows.
- Each term is a `<div class="term-entry">`: its heading `<h2 id="term-<name>">`, its short definition in `<p class="term-definition">` (a rule at its left, in bold), its explanation, then `<p class="term-avoided">` with the label "Do not use" and the words, dim. A word in code marks stays code; no word links.
- Inside an entry, the first use of each other term links to its entry: `#term-<name>` for a term of the same group, the page of its group for another. The short definition links too. The words to avoid never link.
- The list "On this page" holds each term of the group.
- At its end, the links to the groups before and after it, in the order of the file.
- Its title is "Glossary: <group>". Its breadcrumbs pass through the index of the glossary.

The index, `docs/reference/glossary/`, keeps the address of the single page of before:

- The title and the introduction of the file, then a paragraph that says how to find a term: its word in the list from A to Z, or the search.
- "The groups": each group as a link to its page, with the count of its terms.
- "The terms from A to Z": a line of the letters, then a heading `h3` for each letter (`letter-<letter>`; `letter-signs` for a name that does not start with a letter) and a `<dl class="glossary-index">`. A reader looks for a word, so the order is the order of the words, with no regard to case; two terms of one name keep the order of the file.
- Each term is one row: `<div id="term-<name>" data-group-page="<the page of its group>">`, then the name as a link to its entry, its group as a dim label, and its short definition. Every term of the file has its row, a name of two letters too, which no other page links.

The anchors of the old addresses: a link `…/glossary/#term-<name>`, from another site, a page in a cache or a search engine, named the single page. The site has no rules of a server, so the index keeps each anchor:

- With no script, the address shows the row of the term, at the same anchor, with its definition and the link to its entry.
- The script of the index (`glossary.js`, a file of the site: no script is in a page) reads the anchor `#term-<name>` of the address, at the load and at each change of the anchor. It finds the row of that id and goes to the page that its attribute `data-group-page` names, with the same anchor. It replaces the address in the history, so "back" does not come again to the index. The table of the term to its page is the rows of the page itself: the script needs no second file.
- The entry on the page of the group has the same id as the row of the index: one fragment works on both pages. Two terms of one name in two groups keep their two anchors (`term-frame`, `term-frame-2`), each on the page of its group and both at the index.

Every link to a term goes straight to the page of its group, never through the index: the term links of the pages, the links `term:` of the comments, the references to a term of the glossary, the results of the search and the ids of the page graph. A link `docs/GLOSSARY.md#<id>` of a comment names the page of the group that holds the id.

The check of the command (`site_glossary_problems`), on the pages that it writes: each page of the glossary is written and has at most 1 MB; the index has each id of a term once, in a row that names the page of the group of the term; the page of each group has the entry of each of its terms once. The host tests `site_glossary_pages_split_by_group` and `site_glossary_pages_of_the_repository` run the check on a small glossary, on damaged pages and on the glossary of the repository.

The documentation tree lists the groups under the glossary, each with the count of its terms.

## The news

The owner asked for it on 2026-11-12: "\"What runs today\" watch out cause it'll be a nightmare to udate the description. we could have a \"parallel changelog\" (changelog is very technical/list-like) which would be like a \"status report\" or like \"News\"".

A news entry (`GLOSSARY.md`) is one file of `news/`, `news/<yyyy-mm-dd>-<subject>.md`, never moved or merged: a head of six lines `key: value` (`title`, `date`, `release`, `picture`, `kind`, `guide`), one more line `film` in an entry that has a film, an empty line, then the text in the Markdown of this document. `news/README.md` gives the form, the four kinds and when a step writes an entry. The text is at most 1200 bytes (`NEWS_TEXT_LIMIT`): a few sentences for a reader; a longer report belongs in the guide that the entry names.

| Kind | What the entry reports | Its mark |
|---|---|---|
| Shown | A reader can now see or use a new thing in the running system | The color of a program |
| Measured | A number about a thing that exists is measured, with its conditions | The color of memory |
| Decided | The owner chose a thing that a reader sees: a name, a mark, a font | The color of the kernel |
| Fixed | A thing that a reader saw fail now works | The color of the machine |

- `kerneltool news new <subject>` writes an entry with the date of the host, `release: next`, and no title and no text, so that the check fails until a person writes them. `kerneltool news check` checks each entry: the head, each key known and present once, the date a date of the calendar and the date of the file name, the picture a PNG file of `docs/screenshots/` or `resources/logo/`, the release a release of `CHANGELOG.md` or `next`, the guide a document of `docs/` that is a page of the site, the film a WebM file of `docs/films/` under its size bound in an entry that has a picture ("The film of a news entry"), the text not empty, at most 1200 bytes, with no heading and no line of HTML, and no two titles the same. `kerneltool check` runs it, and `kerneltool site` stops on the same faults.
- `news/`: each entry, newest first, as a card with the color of its kind, its date, a link to its release and to its guide, its picture or its film, and a link to its file. Its anchor is `news-<the name of its file>`. One renderer renders all the entries of the page, so the ids stay unique and each term of the glossary links once.
- The home shows the three newest entries: the title, the kind, the date, the picture and the first sentence. The picture of an entry with a film has the mark "film" and links to the entry.
- `releases/`: under each release, a link to each entry that names it. An entry with `release: next` is in no release yet.
- `news.xml`: the feed, Atom (RFC 4287), newest first; each entry has its title, its date (`published` and `updated`, at 00:00 UTC), its kind as a `category`, its first sentence as its `summary`, and its text and picture as HTML in its `content`. An entry with a film has one more link, `<link rel="enclosure" type="video/webm" href="..." length="<bytes>"/>`, the element of Atom for a file that goes with an entry, and a link to the film at the end of its `content`. The id of the feed and of each entry is the address of its file in the repository on `master` (`<repository>/blob/master/news/<file>`): a file of `news/` is never moved, so the id stays the same when the site gets an address. Each page names the feed in its head (`<link rel="alternate" type="application/atom+xml">`), so that a browser and a feed reader find it.

What a feed reader needs, and what is missing with no address:

- A reader subscribes to the address of the feed and resolves each relative link against it. With no address (`SITE_ADDRESS` is empty), the links of the feed are relative to the root of the site (`news/index.html#news-...`, `pictures/...`): they work for a reader that fetched the feed from the host of the site.
- Missing with no address: the link `rel="self"` (the feed cannot name its own place), absolute links (a reader that receives the feed as a file, or copies an entry elsewhere, cannot resolve them), and the discovery of the feed from another site. `kerneltool site --address https://...` writes absolute links and the link `self`. The command says so when the site has no address.

### The film of a news entry

An entry can name a film: `film: docs/films/<name>.webm` in its head. The command `kerneltool film <name>` writes the file (`TOOLS.md`, "The film of a document"), and the repository holds it. The site copies it to `films/<name>.webm` as it is: `kerneltool site` runs no encoder.

**The file.** WebM with AV1, 30 pictures in one second, no sound, at most 4 MiB (`FILM_DOCUMENT_SIZE_LIMIT`). Each version of the file stays in the history of the repository, and a reader loads it on a phone. Measured on the film of the palette (36.8 s, 2048 by 1536 pixels): H.264 in MP4 3 169 392 bytes, VP9 in WebM 3 019 142 bytes, AV1 in WebM 1 572 784 bytes, with the text of the screen sharp in the AV1 file. The site holds one file for a film, and no second source in another format.

**The checks.** `kerneltool news check` reads the file: it starts with an EBML header (the bytes `1A 45 DF A3`) of the document type `webm`, it is under the size bound, and its tracks state the width and the height of its pictures. The entry has a picture. `kerneltool site` stops on the same faults.

**The page of the news.** An entry with a film shows it under its text, over the width of the card, at most 1024 pixels wide: the width of the screen of the system. In the column of a picture (384 pixels) the text of a film of the whole screen is not readable. On a screen narrower than 720 pixels the film takes the width of the column.

```
<figure class="news-film">
<video controls preload="metadata" playsinline muted loop poster="../pictures/<picture>.png" width="2048" height="1536">
<source src="../films/<name>.webm" type='video/webm; codecs="av01.0.12M.08"'>
<a href="../films/<name>.webm"><img src="../pictures/<picture>.png" width="1024" height="768" loading="lazy" decoding="async" alt="..."></a>
</video>
<figcaption>Film: <a href="../films/<name>.webm"><name>.webm</a>, WebM with AV1, 1.5 MiB.</figcaption>
</figure>
```

| Part | Why |
|---|---|
| No `autoplay` | A film starts when the reader starts it. The site has no animation that a reader did not ask for ("The look") |
| `controls` | The player of the browser: the site adds no script for a film |
| `preload="metadata"` | Before the reader starts the film, a browser loads its head only, not the whole file |
| `poster` | The picture of the entry stands in the place of the film until it plays |
| `width`, `height` | The size of the pictures of the film, read from the file. The style sheet sets the width to that of the column; the two numbers give the ratio, so the page keeps the room of the film before a byte of it came |
| `playsinline` | On a phone the film plays in the page, not over the whole screen |
| `muted` | A film has no sound; a browser then shows no control of the sound that does nothing |
| `loop` | A film shows one act, of about half a minute: it starts again at its end, as the act can be done again |
| `type` with `codecs` | A browser that does not play AV1 knows it from the page and never asks for the file |
| The `img` inside `video` | For a browser with no `video` element: the picture, as a link to the file |
| The caption | The name of the file as a link, its format and its size: a reader chooses whether to load it, and can keep the file |

**The codec text**, `av01.0.12M.08`: AV1 (`av01`), the main profile (`0`), the level 5.0 (`12`), the main tier (`M`), 8 bits a channel (`08`). The level is the one that the encoder writes in the file for this size: a picture of 2048 by 1536 has 3 145 728 pixels and 1536 lines, more than the levels 4.0 and 4.1 hold (2 228 224 pixels, 1152 lines); the level 5.0 is the first that holds it (8 912 896 pixels, 2176 lines). `ffprobe` gives `profile=Main`, `level=12` and `pix_fmt=yuv420p` for a file of the encoder of the tool. The text is a constant (`SITE_FILM_CODEC`): a film of another size of screen, or of 10 bits a channel, needs another text.

**A browser that does not play AV1** (a Safari on a device with no AV1 decoder, an older browser) shows the picture of the entry, the `poster`, in the place of the film, and plays nothing. The caption still links to the file.

**The home** shows no film. A card of the home is a third of the width of the page: a film of the whole screen is not readable there, its controls cover a part of it, and three players on the first page each ask for a part of their file. The card shows the picture of the entry. A mark is in the lower left corner of the picture: a rectangle of 24 pixels with the one word "film", on the surface of a card, with a line of 1 pixel at its top and at its right. The picture links to the entry on the page of the news, where the film is. The word is not cut at any width: the mark takes the width of its word.

**The feed** names the film as an enclosure, with its type and its count of bytes, and its `content` ends with a link to the file. The `content` has no `video` element: many feed readers remove one.

**The host of the site** must allow the film: `media-src 'self'` in the header `Content-Security-Policy` ("How the site is published"). With `default-src 'none'` and no `media-src`, a browser refuses the film and shows the picture.

Not done: the page graph of the news names no `VideoObject` for a film.

## The roadmap

The owner asked for it on 2026-11-14: "j'aimerais [...] qu'on [la] rende visible sur le site, la roadmap, joliment, tout simplement, parallèle au changelog".

`roadmap/` shows `ROADMAP.md`, the planned work of the system (`GLOSSARY.md`, "Roadmap"). It is the other half of `releases/`: the releases list the work that is done, the roadmap the work that is planned. The form of the file and its check are in `TOOLS.md`, "The roadmap"; the code of the page is `tools/kerneltool/site_roadmap.odin`.

- `kerneltool site` reads the file with the reader of `kerneltool roadmap check` (`roadmap_read`), before it writes a page. A fault of form stops the command with the line of the fault, and no page is written. The site does not apply the rule of the changelog summaries: that rule is for a commit, not for a page.
- The page adds no sentence to an entry. Its first paragraphs say what the three sections are and where the work that is done is; a line names the file.
- The three sections are three columns from 960 pixels, and one column under 960 pixels, in the same order. Why columns: Now, Next and Later are one line of time, read from the left to the right, and a reader sees at once how much is in each. Why 960 and not 720: three columns of a window of 720 pixels are about 220 pixels each, about 28 characters a line. Why not three groups one under the other at every width: a wide window has the room for the three side by side, and under the two others the section Later, the longest, starts far below the first screen. The columns start at the same height and end where their cards end (`align-items: start`): no card is stretched to fill a column.
- A section has a heading (`now`, `next`, `later` as its id), the count of its entries in the dim color, and one line that says what it holds. A section with no entry says "No entry.".
- An entry is a card of the site (`.card`): the border of 1 pixel and the bar of 4 by 16 pixels before its title. The title is the summary; the text is the sentences, rendered by the renderer of the guides, so a term of the glossary links once on the page. An entry with a design link has a last line "Design", a link to the intent file in the repository at the commit of the build.
- The state of an entry is the accent of its card, a color that the site already has: **Now** has the color of a program, the color of what runs (the color of the kind Shown of a news entry); **Next** has the color of the kernel (the color of the kind Decided); **Later** has no accent: its bar and its border take the dim color and the track (`.roadmap-later`). The page has no new color, no new form and no mark of its own. The heading of the column says the state in a word, so the color is never the only sign.
- No text is cut: a card takes the height of its text, a summary and a sentence break inside a long word (`overflow-wrap: anywhere`), and a column is never narrower than its grid cell allows (`minmax(0, 1fr)`).
- The id of an entry is `roadmap-<the summary, as a slug>`. The check refuses two entries whose summaries give one slug, so no two entries share an id.

Where a reader finds it:

| Place | What it shows |
|---|---|
| The bar | The line "Roadmap" of the project menu, after "Releases": two clicks from each page, and one line of the site menu under 720 pixels (see "The buttons and the menu of the bar") |
| `releases/` | One line after the first paragraphs: "What is planned: the roadmap", with the count of each section |
| The home | A door "Roadmap" in its head, with the doors of the other sections, and the same line, under the newest release. The home has no section for the roadmap: it shows what runs |
| `status/` | The same line, under the heading "What is planned", in the place of the table of the next steps |
| The search | Each entry, by its summary (the kind "roadmap entry", with the look of a status) |
| `llms.txt`, `sitemap.xml` | The page, as each page |

The roadmap has no feed: an entry is not an event with a date, and it leaves the file when its work is done. A reader who follows the system follows the news or the releases.

## The search

The owner asked for it on 2026-11-12: "une doc riche et auto générée, avec recherche, modules, etc.". The search needs no server and makes no request to another host.

### The index

`search.json` is one file that the command writes after it checks the pages:

```
{"kinds": [["page", "guide"], ["module", "module"], ...],
 "pages": [["<path>", "<title>"], ...],
 "entries": [["<title>", <page>, "<anchor>", <kind>, "<text>"], ...]}
```

- An entry has a title (what the match reads), its page (an index of `pages`), an anchor (an id of the page, or empty for the page itself), a kind (an index of `kinds`) and a text (the line under the list for the chosen row).
- A kind is its name and the name of its value kind (see "The kinds of values"), whose icon and color the list shows. One table, `site_search_kinds`, gives each kind its name, its value kind and the folder of the one page that lists every entry of the kind (none for the pages and the exports).
- The kinds, in their tie order: page, module, program, export, operation, error kind, console command, term, guide section, property, news entry, release, gap, license row, type, roadmap entry. Each page of the site is an entry. The others come from the same data as their page: the modules and their exports (`module.export`, with the signature as the console prints it), the kernel operations, the error kinds, the commands of the console, the terms of the glossary with their short definition (at the entry on the page of the group), the headings of levels 2 and 3 of each guide with their first paragraph, the properties with their status, the news entries, the releases with their date and their first change, the gaps, the rows of the two tables of licenses (each row has the id `license-<what it is>`), and the entries of the roadmap, each by its summary, with its section and its sentences as its text.
- The bounds: a title has at most 128 bytes (`NAME_SCAN_LIMIT` of the match: it reads no more); a text has at most 120 bytes, cut at the start of a character; the index has at most 4096 entries (`CANDIDATE_SCAN_LIMIT`: one ranking of the console reads no more names, and the script reads them all only under that count) and at most 1 MiB. The command prints the count of entries and of bytes, and stops over a bound.
- The checks: each page of the site has at least one entry, and each entry names a page that the command writes and an id of that page.
- The JSON escapes each character that can end a string or a line of a script: the quote, the backslash, the control characters, `<`, `>`, `&` (so no `</script>`), U+2028 and U+2029. A byte that is not UTF-8 becomes U+FFFD.

### The script

`search.js` is written by the tool: plain JavaScript, no library and no build step, about 250 lines, loaded with `defer` by each page.

- On the first key in the box, it fetches `search.json` from the folder of the script. A page opened from a file cannot read another file in the browsers of today: the script then says so under the box, and the site stays whole by its links.
- The match and the order are those of the completion list of the console (`CONSOLE.md`, section 3; `support/line_editor/fuzzy_match.odin`): `lower`, `fuzzy_match`, `ranked_before` and `rank_candidates`, ported rule for rule on the UTF-8 bytes of the query and of the title. The tie order is the kind: of two entries with one score, a module comes before a guide section that has its name.
- Two things keep the script in step with the console. The tool writes the constants of `support/line_editor` (the points of each rule, the bounds) into the script. And one table of queries, names, scores and orders, `site_search_match_names` and `site_search_match_orders` in `tools/kerneltool/site_search.odin`, is run twice: by the host test `site_search_matcher_table` over the matcher of Odin, and by the script over its own matcher when the address of a page has `?selftest=1` (it prints one line in the console of the browser, "search self test: N of N cases pass" or the first case that fails, when the script runs during the load and again when the list opens; the same line is the attribute `data-search-self-test` of the root element and the first words under the box). A change of the rule in Odin fails the host test until the table has the new scores; the new table then fails the self test of the script until the script has the new rule. No program of the repository runs the script: the self test is run in a browser.
- The chart of the docs home counts the matches of each kind (see "The docs home"). One more table, `site_search_kind_cases`, holds its cases: a query over a group of names, the tie order that the list keeps (a tie order stands for a kind), the count of the matches of each tie order, the count that the list keeps and its first name. The empty query is the field with no text, and gives the counts of the whole group. The host test `site_search_kind_cases_table` runs it over the matcher of the console, and the self test of the script runs it over its own.
- A third table, `site_search_segment_cases`, holds the segments of the bar of that chart: the counts of the kinds, and the start and the width of each segment in thousandths of the bar. The host test `site_search_segment_cases_table` runs it over `site_search_chart_segments`, and the self test of the script over its own segments. The tool writes the least share of a segment into the rule of the script (`leastShare`).

### The look

The box and the list are those of the console (the picture `docs/screenshots/console_completion.png`):

- A page has one search field (`GLOSSARY.md`), in one of two places (`Site_Search_Place`): at the right of the bar, in the place of the clock of the bar of the desktop, on every page but one; in the middle of the docs home, as a large field, on that page, whose bar has none. The owner, 2026-11-12, when asked whether the bar keeps its field beside the large one: "non c'est redondant. autant ne l'avoir que sur toutes les autres pages (exclusivité mutuelle)".
- One markup for both places (`site_search_field_html`): the same ids, so the script finds the field of the page by its id; the class of its box and its placeholder differ. One script serves both: it opens the site menu for the field only when the menu holds it.
- `/` puts the focus in the field of the page when the focus is not in a field.
- Under the box, a line says how many entries match and how many are not shown, and the keys; then at most 8 rows, the best first; then the text of the chosen row. A row is the title with the matched characters in the accent color (`COLOR_BOOT_PROGRAM`, at half its light in the light form) and, at its right in the dim color, its kind, after the icon of its kind in the color of its kind, and the title of its page. The chosen row has the band of the track and the blue line at its left.
- Up and Down choose a row, Enter opens it, Escape closes the list (a second Escape leaves the box). A click opens a row.
- The query is in the address as `?q=<query>`, so that a search can be linked: a page opened with `?q=` opens the list under the field that the page has. The address that the page graph gives for a search is the docs home, `docs/?q=<query>`.
- The keyboard alone works. The box is a `combobox` with `aria-expanded`, `aria-controls` and `aria-activedescendant`; the list is a `listbox` of `option` rows with `aria-selected`; the line of the count is `aria-live`. The focus is visible.

With no script, the site is whole: every page is reachable by its links, and the field is not shown (its box has the attribute `hidden`, and only the script takes it away). The docs home is then its cards and its doors.

## The docs home

The owner asked for it on 2026-11-12: "on garde une page d'index sur docs avec un sous chemin reference et guides ? avec une belle \"page d'accueil de docs\" avec une searchbar, qui cherche parmi tout ?". The code is `tools/kerneltool/site_docs_home.odin`.

`docs/` is a door to the docs, not a list: the presentation layout (one centred column, no tree, no "On this page"), the title "Docs", and from the top:

1. The heading and one sentence: what the guides and the reference are.
2. The search field of the page, large, in the middle (see "The search"): the same index, the same list of results and the same script as the field of the bar. The bar of this page has no field. With no script the field stays hidden, and the chart and the cards under it carry the page.
3. The chart of what the search finds, directly under the field, over the whole width of the page (see "The chart of what the search finds"). The field and the chart are one box (`.docs-search`): the list of results opens under the chart, over the cards, at every width. So the field, the chart and the list are in view while the reader types, in that order.
4. Two columns from 900 pixels, one under it (`.docs-parts`). A card takes the height of its own rows, so no card shows an empty part:
   - The first column: the card of the guides. Every guide, in the reading order of the page of the guides, one row each: its number, its title as a link, and under it its one line of description, dim. The description is the row of the guide in the table "## Documents" of `README.md`; the command fails for a guide with no row there. The heading of the card is the link to the page of the guides.
   - The second column: the card of the reference. Every reference table (`site.reference_entries`), one row each: the icon of the kind of what the table lists, its name as a link on one line, its count at the right as a Number value, and under the name what it holds, dim. The heading of the card is the link to the index of the reference.
   - One row form for the two cards (`.docs-row`, `site_docs_row`): a lead (a number or an icon), the name, a description, and a count in a column of one width with no rule at its left, so that the counts align. The description is always under the name: beside it, the rows of a card would each break at a different place.
5. The page has no row of doors and no link "All ...": the bar gives the other sections, and the cards give every guide and every table.

The text of the page needs the entries of the index, and the index has an entry for each page: the command records the page with its title and its description first (`site_docs_home_add`), makes the index, then writes the text (`site_docs_home_fill`) before it writes the pages.

### The chart of what the search finds

The owner asked for it on 2026-11-12, of the paragraph that gave the counts under the field: "Un truc visuel, parce que là, juste l'espèce de boum, gros cube de texte, ça n'a aucun intérêt en dessous de la barre de recherche, ça prend juste de la place.", then "Et tant qu'à mettre un histogramme, autant le rendre dynamique." Then, of its place in the column of the reference, under the cards: "pas ouf le placement sur le site de l'histogramme (alors qu'il est trop cool !) genre on le voit quasi pas c'est dommage." Its point is that it moves while the reader types: it is under the field, in a compact form that does not push the cards away. The code is `site_search_chart` in `tools/kerneltool/site_docs_home.odin`, and the part of `search.js` that follows the field.

With no script, the chart is whole and static:

- One bar of 12 pixels over the width of the page, and at its right the total: the count of the entries of the index ("1834 entries"), a number value, the sum of the counts. Every count is computed from the index; none is typed.
- The bar: one segment for each kind that has entries, in the tie order of the kinds (the order of `search.json`), side by side from the left: a rectangle with square corners in the color of the value kind of the kind (`site_search_kinds`, the color that the list of results shows), with a line of 1 pixel of the background between two segments. The width of a segment: a least share of 8 thousandths of the bar (`SITE_SEARCH_CHART_LEAST_SHARE`, about 9 pixels at 1152 pixels and 3 at 360), so that a count of 1 among 1000 still shows a mark; the rest of the bar in proportion to the counts, rounded down; the last segment takes what the rounding left, so that the segments fill the bar (`site_search_chart_segments`). A kind with no entry has no segment and no chip.
- Under the bar, one row of chips that wraps, a chip for each kind in the same order: the icon of the kind, its name for many entries ("terms", "news entries"), and its count as a number value, right-aligned in a width of four figures (the index holds at most 4096 entries). The name stays the name for many entries at every count: a chip keeps its width while the reader types, so the row does not break at another place and the cards under it do not move.
- A chip whose kind has a page that lists every entry of the kind is a link to that page: the modules and the programs to the index of the modules, the operations, the error kinds, the commands of the console, the terms (the glossary), the license rows and the types to their reference pages, the guide sections to the index of the guides, the properties and the gaps to the status page, the news entries to the news, the releases to the releases. The pages and the exports have no page of their own: their chips are not links.
- The names and the counts are the text of the chart, for a reader with no picture and for a screen reader. The bar and the icons are `aria-hidden`. The heading "What the search finds" names the section for a screen reader; it is not shown: it is a line of text in the place that the owner wants free.
- The height at 1420 pixels: the line of the bar (24 pixels) and two rows of chips of 24 pixels, about 3 lines. On a narrow screen the chips wrap on more rows; nothing scrolls sideways.

Why an SVG rectangle: a page holds no style attribute, so a width cannot be a `width` of the style of an element. An inline `<svg>` with no `viewBox` takes the width of its box from the style sheet, and a `<rect x="12.3%" width="4.5%">` is a part of that width: the place and the width are attributes, they scale with the page, and the style sheet needs no rule for each width.

With the script, the chart follows the field:

- While the field holds a text, each chip shows the count of the entries of its kind that match it: the match of the list, over every match, not only over the rows that the list shows. Each segment takes its share of the matches by the same rule. A kind with no match stays in its place: its chip dim with 0, its segment with no width. The chips and the segments keep their order while the reader types. The total reads "N of T match".
- With no text in the field, the chart shows the counts of the whole index again.
- While the field holds a text, a chip is a button (`role="button"`, `tabindex="0"`, `aria-pressed`): a click, Enter or Space keeps the list of results to its kind, and the line of the count of the list says "Only <kind>.". A second press gives every kind back. One kind at a time. The kind that the list keeps has the band of the track and the line at its left, as the chosen row of the list. The focus returns to the field, whose list shows the result and takes the keys. A click on a segment does what its chip does; a segment is a target of the pointer only, and the chips are the targets of the keyboard and of a screen reader. With no text in the field, a chip is again what its markup is (a link opens its page), and a click on a segment opens the page of its chip.
- The list of results is in the box of the field and the chart (`.docs-search`, `position: relative`): it is placed at the bottom of the box (`position: absolute; top: 100%`), under the chart and over the cards, at most 720 pixels wide, in the middle. Under 720 pixels too: the rule that puts the list of the bar in the flow of the open menu does not apply to this box.
- The markup says what the script needs: each chip `data-kind` (the index of the kind in `search.json`), `data-count` (its count in the index) and `data-plural` (its name); the list of chips has the id `search-chart`; the bar has the id `search-chart-bar`, and each segment `data-kind`. The script writes the `x` and `width` attributes of each segment in the form that the tool writes ("74.6%", `site_search_chart_percent`), with the least share of the rule of the script.
- The movement: a segment changes its place and its width in 150 ms (`transition: x 150ms ease-out, width 150ms ease-out`, on the segments only), and at once under `prefers-reduced-motion: reduce`. Nothing moves when the page loads: a transition plays only when the script changes an attribute. The `x` and `width` attributes of a `rect` are properties of the style sheet in SVG 2, so the transition applies where a browser maps the attribute to the property; a browser that does not changes the segment at once, which is correct. A style that the script sets is a style attribute in the page: it is not used.

## The home

The owner looked at the home on 2026-11-14 and asked for six changes: the text of a news card with no picture at its top; a line of time in the place of the boxes of the start ("Soit on affiche une timeline [...] avec des informations riches, mais là l'espèce de boîte c'est nul"); a chart or nothing for the measures ("Soit on fait des rapports de statistiques qu'on affiche sur un graphe ou des histogrammes [...], soit on n'affiche rien"); a newest release that is worth a look ("le texte tout plat comme ça, c'est pas très aguicheur [...] il y a un manque d'emphase sur les mots"); an animation at a click on the heron; and the states of the buttons ("The states of a control"). The code is `tools/kerneltool/site_home.odin`; its host tests are `site_home_test.odin`; the intent is `src/md/features/site_home.md`.

The home does the tour: it shows the system. From its top: the head (the heron, the name, the tagline, the doors), the news, "What it is", the line of time of the start, the tiles of the boot image, the charts of the measures, the carousel, the band of the newest release.

### The rule of a card

The content of a card starts at its top, and a card has no empty room between two of its parts. The fault that the rule removes: on the home, each news card gave its text the fourth row of a shared grid, and the third row had the height of the picture of another card; a card with no picture then showed its text at its bottom, under an empty third row. A card with no picture now puts its text in the third row, over the two last rows.

- A grid whose cards do not share their rows gives each card its own height (`align-items: start`): the two cards of the docs home, the columns of the roadmap, the charts of the home.
- No rule of the style sheet pushes a part of a card to its bottom (`margin-top: auto`, `align-self: end`, `align-content: end` or `space-between`): the host test `site_card_content_starts_at_the_top` refuses them.
- The figures of the gallery and the cards of the reference have their parts from the top already.

### The line of time of the start

The line of time of the start (`GLOSSARY.md`) shows the stages that the kernel logged, from the start of the machine to the first program. It replaces seven boxes of one size, which said nothing of the times.

**Two bars, each on one scale that the page states.** The firmware takes 1516.6 of 1662.0 ms in the run of the measure record: on one scale the six stages of the system are 8.8 % of the bar, 26 pixels on a phone.

| Bar | What it shows | Scale |
|---|---|---|
| The first | Every stage, from the start of the machine | One scale: the width of a stage is its time, in hundredths of a percent of the bar, with no least width. The sentence above it gives the whole time and says "One scale: a width is a time." |
| The second | The stages after the first one | The same times, wider: the sentence under it gives their time and how many times wider the bar is ("11.4 times wider"). A stage has at least 2 % of the bar (`SITE_BOOT_SYSTEM_LEAST_SHARE`), and the sentence says so |

Two lines at an angle, between the bars, go from the part of the first bar that the second one shows to the two ends of the second bar. A segment has the color of who runs its stage. The bars are `aria-hidden`: the rows under them are the text.

Refused: a logarithmic scale. Its axis has no zero, and the length of a segment on it is not a time: two stages of the same time have two lengths, by their place. A reader compares lengths. Refused too: one bar with a least width for each stage: the firmware then looks shorter than it is, and the page lies about the one stage that takes most of the start.

**The rows.** Under the bars, one row for each stage: a square in its color, who runs it in the dim color, its name, and its time at the right as a Time value. A reader with no pointer reads every name and every time. A name wraps between its words; nothing is cut. The room of a name, counted at 9 pixels a character with a time of 9 characters:

| Width of the window | The column of the rows | The box of a name |
|---|---|---|
| 360 pixels | 294 pixels | 169 pixels: the longest name takes 3 lines; the longest word, "program:", 72 pixels |
| 720 pixels | 654 pixels | 529 pixels: one line |
| 1200 pixels | 535 pixels: the rows at the left, the cards at the right, from 900 pixels | 410 pixels: one line |

**The cards.** Each stage has a card: its name and its time, what the stage does in two or three sentences, the code that runs it, the line of the log that it is measured from, and a link to the heading of its guide. The texts are one table of the tool, `site_boot_stage_texts`, keyed by the name of the stage; each sentence states a fact of the guide that the entry names or of the source of the boot program and of the kernel. A stage with no entry has a card with its time and its line.

- One card shows at a time, in one place: at the right of the rows from 900 pixels, under them on a narrower window. Every card is in one cell of a grid, so the cell has the height of the tallest card, and nothing moves when the card changes. A card that is not shown is hidden, not removed.
- Which card shows, with no script: the card of the stage whose row has the focus (a row has `tabindex="0"`; a tap gives it the focus); else the card of the row or of the segment under the pointer; a card under the pointer stays, so the pointer can go from a row to the link of its card. With none of them, the card of the hint shows: how to choose a stage, and where the times come from.
- The rules are written inside `:where()`, which has no weight: the order of the rules alone decides, so exactly one card shows (`site_boot_card_rules`). The rules name a stage by its place; the style sheet has them for 12 stages (`SITE_BOOT_STAGE_RULE_COUNT`).
- The segment of the stage of a row has a line around it, and the row of the stage of a segment has the band of the track.
- A browser with no `:has()` shows every card, one under the other, and no hint.
- A row names its card for a screen reader (`aria-describedby`).

**The source of the times** is in the card of the hint, not in a sentence under the bars: one line `kernel: boot: ...` for each stage, one run of the main machine test under QEMU, the full check or the work tree that measured it, and a link to the page of the measured numbers, which states the run.

### The charts of the measures

The rule: **a chart or nothing**. The home shows a measure only as a chart whose bars have one unit and one scale from zero. A measure that is not such a chart is not on the home: it is a row of the page of the measured numbers, where a number is a record.

A measure chart (`GLOSSARY.md`) is an entry of `site_measure_charts`: the pattern of its measure in `site_measures`, a title, its one unit, the value kind of its numbers, one or two sentences, and at most 5 bars, each with its label and the words of the line of the log that come just before its number.

| Chart | Bars | Unit |
|---|---|---|
| Kernel entries in one second, by the count of programs | 1, 2 and 4 programs | Kernel entries in one second |
| The time to draw one glyph | From its outline at the scales 1, 2 and 3; from the glyph cache; the bitmap font | Nanoseconds |

- The tool reads each number from the line of the log that the measure quotes (`site_chart_values`). A chart is drawn only when the line holds every number of the chart, each followed by the unit of the chart where the log writes one. So a chart never shows a part of its bars and never a number of another unit.
- A bar is an SVG rectangle whose width is an attribute, in thousandths of the longest bar of its chart; a number above zero has at least 4 thousandths. The fill is the accent of the measure. The number is text at the right of its bar, as a value of its kind, with a space between each group of three digits.
- Under the bars: the unit in words and "Each bar starts at zero.", then the sentences, and a link to the row of the measure on the page of the measured numbers.
- From 900 pixels the charts are two columns; under 720 pixels the bar of a row is under its label and its number.
- With no chart that can be drawn (no log and no measure record), the home has no section "Measured" and no heading for it.

What left the home: the three cards that each quoted one whole line of a log. What is not a chart today: a number alone (a full frame, 1000 commits, the reads of the time page), a line whose numbers have several units (the scheduler), and two numbers of two measures (the two directions of TCP).

No history: the measure record holds the numbers of one run, the last full check, and each run replaces it. A chart of a measure over the releases needs a record that keeps the numbers of each release. It is an entry of the roadmap, and the home draws no history until the record has one.

### The band of the newest release

One card in the color of a version: the number of the release as its one large value (32 pixels, the value kind Version), then on the same line its date, the count of its changes and the count of the steps, the numbers in the text color and the monospace font, the words in the dim color. Then its first 4 changes (`SITE_RELEASE_BAND_CHANGE_COUNT`), each with its type in the dim color and its bold summary as a link to the change on the page of the releases (`release-<number>-change-<place>`). Then "And N more changes in this release.", a link to all the releases, and the line of the roadmap.

The summary of a change is the bold words at its start (`site_change_summary`); a change with none gives its first sentence.

### A press on the heron

A click, a tap, Enter or Space on the large heron plays one animation at once.

- The page holds the box of the heron, `<div class="mark-box">`. The script of the mark makes it a control: `role="button"`, `tabindex="0"`, the name "Play an animation of the heron", and the class `mark-control`, which gives the pointer of a control. The focus has the outline of the site.
- The first press of a view of the page plays the dash, the animation that crosses the window: a reader who presses wants to see something happen. Each next press plays the next animation of the rule of the choice ("The rhythm of the animations"), so repeated presses walk the round and never play the animation that was played just before. A first press right after a dash follows the rule too.
- The animation of the first press is a constant of the tool, `SITE_MARK_FIRST_PRESS_ANIMATION`, which the tool writes into the table of the script: the script holds no number and no name of an animation.
- A press plays in the place of the still time. A press during an animation does nothing: the animation ends first. A press that waited would play at a moment that the reader no longer expects, and a cut animation would leave the heron in the middle of a move.
- A press before the tile maps arrived plays when they arrive.
- For a reader who asks for reduced motion nothing moves, so the box is not a control: it has no role, no place in the order of the keyboard and no pointer of a control. It stays the box of a picture.
- With no script the box is the box of a picture.
- The self test of the script (`?selftest=1`) has four cases for the presses: the first press names an animation and plays it; over 45 presses none plays the animation before it; a first press after the dash plays another one. The host test `site_home_heron_press` checks the table and the parts of the script.

## The gallery

The owner asked for it on 2026-11-14, of the program `heron`: "faudra évidemment le rendre visible dans les captures du site parce que c'est super sympa. D'ailleurs je veux pas mettre trop de captures sur la page d'accueil [...] idéalement avoir [un] carrousel et une page galerie". The code is `tools/kerneltool/site_gallery.odin`; its host tests are `site_gallery_test.odin`.

Before it, the home showed 20 pictures in 7 groups, from a list of its own, and a picture that the list did not name was on no page: 91 of the 111 pictures of `docs/screenshots` were not on the site.

### The gallery table

The gallery table (`GLOSSARY.md`) is the one source of the pictures of the screen that the site shows: `site_gallery_rows`. A row is:

| Field | What it holds |
|---|---|
| `file` | The name of a PNG file of `docs/screenshots` |
| `group` | One of the groups of the gallery (`Site_Gallery_Group`); the rows of one group are on the page in the order of the table |
| `caption` | One sentence of plain text that says what the picture shows, at most 160 bytes (`SITE_GALLERY_CAPTION_LIMIT`), with a period at its end and no mark of Markdown. It is also the alt text of the picture |
| `guide` | The document of `docs/` that explains the subject; it is a page of the site, never a working record |
| `home` | The carousel of the home shows the picture |
| `film` | A film of `docs/films`, or none: the gallery then shows the film in the place of the thumbnail |

The rule: **each PNG file of `docs/screenshots` is in one row of the table, or in one line of the excluded files (`site_gallery_excluded`) with its reason.** `kerneltool site` stops, and the host test `site_gallery_table_names_every_picture` fails, on a file that neither names, on a file that both name, on a row or an excluded line whose file is gone, and on an excluded line with no reason. So a new picture of a machine test cannot be forgotten: the step that adds it writes its row.

A caption is written for the table: it is not the file name with spaces, and it is not the caption of `README.md`, which can be several sentences for the reader of the repository. A caption states what the picture shows; the writer of a row looks at the picture.

The groups (`site_gallery_groups`), each with a title and one sentence:

| Group | Pictures |
|---|---|
| The desktop and the palette | 20 |
| The console and the terminal | 12 |
| The mark and the graphics | 3 |
| Rights, grants and faults | 13 |
| Modules | 9 |
| Memory, threads and time | 15 |
| The developer tools | 4 |
| The interface and the fonts | 10 |
| The network, the cryptography and the randomness | 10 |
| The storage | 7 |
| The boot and the trusted boot | 7 |

110 rows. The excluded files:

| File | Reason |
|---|---|
| `notes_crash.png` | The picture was taken while the window of `notes` drew its note: the text of the note is cut |
| `vector_glyphs.png` | An older picture of the prototype of the vector font: its bar has the words of the system before the mark and the palette |

A picture of the table has the size of the screen of the system, 1024 by 768 pixels (`SITE_SCREEN_PICTURE_WIDTH`, `SITE_SCREEN_PICTURE_HEIGHT`): the command stops on another size. The style sheet names the two widths at which a picture is shown, and they come from these constants.

### The page of the gallery

`gallery/` is the gallery (`GLOSSARY.md`): every picture of the table, in its groups. It has the presentation layout.

- From the top: the heading, the count of the pictures and of the groups, one paragraph, then the links to the groups (the squares of the doors of the home, `.doors`), then each group.
- A group is a `<section>` with its heading (`group-<slug of its title>`), its sentence with the count of its pictures, and its pictures in two columns from 720 pixels, one under it.
- A picture is a `<figure id="picture-<name>">`: the thumbnail as a link to the picture at its full size, then the caption and the link to the guide ("Guide: <title of the guide>").
- The caption is the alt text of the thumbnail, so its text in the `figcaption` is `aria-hidden`: a screen reader reads it once. The link to the guide is not hidden.
- Each thumbnail has `width`, `height`, `loading="lazy"` and `decoding="async"`: a browser asks for a thumbnail when the reader comes near it, and the page keeps the room of each one.
- A row with a film shows the film over the whole width of the group, by the procedure of the news (`site_news_film`; "The film of a news entry"): `controls`, `preload="metadata"`, the picture as its `poster`, no `autoplay`. Its caption is a paragraph under it, read as it is.

Where the gallery is linked. It is a button of the bar, "Gallery", after "Docs": one click from each page ("The buttons and the menu of the bar"). The home has a door to it in its head, beside the other sections (`site_section_under_home`), and the link "All N pictures, in the gallery" under the carousel. The docs home has no link to it: that page has no row of doors ("The docs home"). The search finds the page, and the sitemap and `llms.txt` list it.

The gallery is not an index page: by the rule of the redirect pages it has the redirect page `gallery.html`, though that address was never public.

### The thumbnails

The page of the gallery shows 109 pictures (the row with a film shows its film); the measure below was made with 108. A browser loads a picture when the reader comes near it, so the bytes of the page are the bytes of what the reader scrolls past. Two forms were measured on 12 pictures of the table, with the encoder of ImageMagick at its level 5 (the tool prints the bytes of its own encoder at each build):

| Form | One picture, mean | The 108 pictures |
|---|---|---|
| The picture at its full size, scaled by the style sheet | 157 511 bytes | about 17.0 MB |
| A thumbnail at one half, 512 by 384 | 59 637 bytes | about 6.4 MB |

The tool writes a thumbnail for each picture, `pictures/thumbnails/<name>.png` (`site_thumbnail_encode`). It saves 62 % of the bytes for every reader of the page, because the `src` of the element is the thumbnail: the rule of "The pictures" for a second version of a picture (the common screens choose it, and it saves at least half of the bytes) holds here, where it did not hold for a `srcset` on the home.

- The divisor is whole, 2 (`SITE_THUMBNAIL_DIVISOR`): each pixel of the thumbnail is one square of 2 by 2 pixels of the picture. A divisor that is not whole mixes parts of pixels.
- The filter is the mean of the square, for each channel, rounded to the nearest (`site_thumbnail_pixels`). A picture of the screen is text and lines of 1 pixel. The mean keeps a line as a line of half its tone, and a letter keeps its form: the titles and the large text of a window stay readable, the small text is a grey texture. One pixel taken from each square (nearest) drops every second row and column: a line of 1 pixel is whole or gone, and each letter loses half of its strokes. So the mean is the filter.
- A thumbnail is for a first look: its text is not meant to be read. The link opens the picture at one pixel of the picture for one pixel of the screen of the system.
- A thumbnail is never shown wider than its 512 pixels (`max-width`): on a window of 1100 pixels or more it is shown at one pixel for one pixel, in a column of 538 pixels. On a narrower window it takes the width of its column.
- The encoder is the one of the pictures of the repository (`png_encode`): the same pixels give the same bytes at each build. The command prints the count of the thumbnails, their bytes, and the bytes of the same pictures at full size.
- The repository holds no thumbnail: the site is the one place that needs them, and the tool writes them from the pictures.

### The carousel of the home

The home shows a carousel (`GLOSSARY.md`) in the place of its 20 pictures: the rows of the table with `home`, at most 8 (`SITE_HOME_PICTURE_LIMIT`), in the order of the table. Today: the desktop, the palette, the completion list of the console, the program `heron`, the rights, the developer tool, the HTTP server and the boot display. The code is `site_carousel_write`.

The form works with no script:

- A row (`.carousel-track`) holds every picture, each a `<figure class="carousel-slide" id="picture-<name>">` as wide as the row. The row scrolls sideways and stops at a picture (`overflow-x: auto`, `scroll-snap-type: x mandatory`, `scroll-snap-align: start`): one picture is in view.
- Above the row, a list of numbered links, one for each picture (`.carousel-controls`): squares of 32 pixels, 4 pixels apart, each a link to the id of its picture. A link scrolls the row to its picture. Its name for a screen reader is "Picture 3 of 8:" and the caption.
- Every picture is in the page: nothing is hidden from a reader with no script. That reader reaches each picture by its numbered link, by the scroll bar of the row, by a swipe, or by the arrows when the row has the focus (the row is a region with `tabindex="0"`).
- Under each picture, its caption: its place ("3 of 8"), the sentence of its row, and the link to its guide. The picture is a link to its file at full size.
- Under the row, the link "All N pictures, in the gallery".

What the script adds (`carousel.js`, a file of the site that the home alone loads, with `defer` and a file version; about 70 lines, no library):

- A numbered link shows its picture with no move of the page: the script sets the place of the scroll of the row. With no script the browser also moves the page, so that the picture is under the bar; the room above a picture (`scroll-margin-top`) then keeps the numbered links in view.
- The keys Left, Right, Home and End change the picture while the row has the focus.
- The link of the picture in view is marked (`aria-current="true"`: the line color around it), also after a scroll by hand.
- The script sets no style, stores nothing, asks for no file and starts no timer.

Nothing moves that the reader did not ask for: the carousel never changes its picture by itself, and a change is a jump, not a slide (the site has no `scroll-behavior: smooth`). So a reader who asks for reduced motion sees the same page, and no rule is needed for `prefers-reduced-motion`.

No layout shift:

- Each `img` has its `width` and its `height`, and the style sheet gives it a width (the whole width of its box, at most 1024 pixels), so the browser knows its height before the picture came.
- The row has the height of its tallest picture and caption, because its pictures are the items of one flex line. A change of picture changes nothing under the row.
- The script adds no element.

No cut text, no text over a text:

- A caption is text of the flow in its `figcaption`: it wraps at spaces, and under 720 pixels a long word breaks. No rule gives it a fixed height, hides its overflow or keeps it on one line (the host test `site_carousel_rules_and_script` refuses those rules).
- At 360 pixels the column is 328 pixels and the box of the caption 310: about 43 characters a line at 14 pixels. The longest caption, 160 bytes, takes four lines, with the place and the link to the guide on lines of their own.
- The 8 numbered links take 8 × 32 + 7 × 4 = 284 pixels: one line at 360 pixels. The list wraps if a narrower window needs it.

The sizes of a picture of the carousel:

| Width of the window | The picture |
|---|---|
| From about 1090 pixels | 1024 by 768: one pixel of the picture for one pixel of the page |
| Under it | The width of the column: the picture is scaled, and its small text is not readable |
| 360 pixels | 310 pixels wide |

On a narrow screen the home did the same before the carousel: a picture took the width of its column, and the link opened it at its full size. That rule is kept: the home has no second file for a narrow screen and no control of the scale. On a wide screen the picture is now at its full size, where it was 538 pixels wide in a column of two.

The bytes of the home: 8 pictures of about 157 500 bytes, 1.3 MB if the reader passes each one, where the 20 pictures of before were 3.1 MB. Each is loaded when the reader comes near it (`loading="lazy"` also holds inside a row that scrolls sideways).

Refused:

- **Autoplay**: a picture that changes by itself is motion that the reader did not ask for, and it takes a picture away while the reader looks at it.
- **A carousel that needs its script**: pictures hidden by the style sheet until a script shows them are lost for a reader with no script, and for a search engine.
- **Radio inputs with the `:checked` rule**: the form works with no script, but each hidden picture is `display: none`, a browser cannot find its text, and the state is lost at each load. The row that scrolls keeps every picture in the page.
- **Buttons "previous" and "next" that the script adds**: they change the width of the line of the numbered links after the first paint. The keys and the numbered links do the same work.
- **A caption over the picture**: a text over a picture of a screen full of text is a text over a text.
- **Captions from the file names**, and captions of `README.md`: see "The gallery table".

Not done: the page graph names no `ImageGallery` for the page; the script has no self test (`?selftest=1`), so no program of the repository runs it.

## What other sites read

The owner asked for it on 2026-11-12: "we'll want a sitemap, json-ld, good seo (graph) etc". The structure follows a site of the owner that has these parts; no fact of that site is copied here. The code is `tools/kerneltool/site_metadata.odin`; its host tests are `site_metadata_test.odin`, with a site address and with none.

A canonical address, an address of Open Graph and an `@id` of JSON-LD must be absolute: a relative one is wrong for the program that receives it. So each part that needs one is written only with a site address (`GLOSSARY.md`), and the command lists the parts that it did not write.

| Part | With no site address | With a site address |
|---|---|---|
| `lang`, the viewport, the title, the description, a theme color for each color scheme, the icons (`favicon.ico`, the SVG icon and the icon of a phone; see "The icons"), the manifest, the links to the two feeds, `rel=prev` and `rel=next` between guides (the reading order of the page of the guides) | Written | Written |
| The canonical address (`GLOSSARY.md`) | No | `<site address>/<folder of the page>/`, as `<site address>/docs/reference/licenses/`; the home is `<site address>/` |
| Open Graph: `og:type` (`article` for a guide, else `website`), `og:site_name`, `og:title`, `og:description`, `og:url`, `og:image` with its type, width, height and alt; `twitter:card` `summary_large_image`, which reads the rest from Open Graph | No | Written; the picture is `pictures/mark_card.png` |
| The page graph (`GLOSSARY.md`) | No | One `<script type="application/ld+json">` in the head |
| `sitemap.xml`, `robots.txt` | Not written | Written |
| `news.xml`, `releases.xml`, `llms.txt` | Relative links, no link `self` | Absolute links, a link `self` in each feed |

### The page graph

One `@graph` for each page, built from the data that the page shows; no value is typed for the graph. Each node has an `@id`; a field names another node as `{"@id": ...}`. The text goes through the JSON writer of the search index (`site_json_string`), which escapes `<`, `>`, `&`, U+2028 and U+2029: a title as `</script><!--` stays a text of the JSON, and the script element has no `<` inside.

| Node | Id | On | Fields |
|---|---|---|---|
| `WebSite` | `<site address>/#website` | Each page | `name`, `url`, `description` (of the home), `inLanguage`, `about` the system, `potentialAction`: a `SearchAction` with the `EntryPoint` `<site address>/docs/?q={search_term_string}` (the docs home, whose own field is the search) and `query-input`, the form that the script of the search reads |
| `SoftwareApplication` | `#system` | Each page | `name`, `url`, `description`, `applicationCategory` "Operating system", `operatingSystem` "None: it is the operating system of the machine", `processorRequirements` "x86-64", `availableOnDevice` "QEMU on x86-64, with UEFI firmware and virtio devices" (`PROPERTIES.md`: the first machine), `softwareVersion` (the newest release), `license`, `image` |
| `SoftwareSourceCode` | `#source` | Each page | `name`, `codeRepository`, `programmingLanguage` (a `ComputerLanguage`, Odin), `license` (`https://spdx.org/licenses/<identifier>.html`, from line 1 of `LICENSE`), `version`, `targetProduct` the system |
| `ImageObject` | `#card` | Each page | The picture for other sites: `url`, `contentUrl`, `width`, `height`, `caption` |
| `ImageObject` | The address of the picture | A page that shows pictures | One for each `img` of the content of the page, read from the element itself: `contentUrl`, `width`, `height`, `caption` (its alt text) |
| `WebPage`, or `CollectionPage` for an index | `<canonical address>#page` | Each page | `url`, `name`, `description`, `inLanguage`, `isPartOf` the site, `primaryImageOfPage` the card, `breadcrumb`, `mainEntity`, `image` the pictures that it shows |
| `BreadcrumbList` | `#breadcrumb` | Each page below the home | A `ListItem` for each crumb of the line above the content, then the page |
| `TechArticle` | `#article` | A guide | `headline` (at most 110 bytes), `description`, `inLanguage`, `url`, `mainEntityOfPage`, `isPartOf`, `about`, `image`. No `dateModified` and no `datePublished`: the tool does not read the history of a document, and a false date is worse than none |
| `DefinedTermSet`, `DefinedTerm` | `#terms`; a term by the address of its entry, `<page of its group>#term-<name>` | The index of the glossary (every term) and the page of each group (its terms) | Each term with its `name`, its short definition as `description`, its `url` (its entry) and `inDefinedTermSet`. A term has one id on both pages |
| `ItemList` | `#modules` | The index of the modules | `numberOfItems`, a `ListItem` for each module page with its `position`, `name` and `url` |
| `Blog`, `BlogPosting` | `#blog`; an entry by its anchor `#news-<file>` | The news | A `BlogPosting` for each entry: `headline`, `description` (its first sentence), `url`, `inLanguage`, `datePublished` and `dateModified` (the date of its head: an entry is never updated), `articleSection` (its kind), `isPartOf`, `mainEntityOfPage`, `about`, `image` (its picture, else the card) |

`BlogPosting`, not `NewsArticle`: a news entry is a dated report of the project, as a post of a blog. `NewsArticle` is for the articles of a publisher of news, and a search engine reads it as journalism.

Not verified against a validator of schema.org or the documents of a search engine, since this work runs with no network: the field `availableOnDevice` of `SoftwareApplication`; whether a search engine accepts a free text "Operating system" for `applicationCategory` (its list of categories has no operating system); whether the `SearchAction` is still read (one search engine stopped showing a box of search for it in 2024); the limit of 110 characters of a headline. The author (owner, 2026-11-12: "pour l'auteur du site évidemment tu peux mettre"): a `Person` node, `<site address>/#author`, on each page. Its `name` is the holder of the line `Copyright` of `LICENSE` (the words after `(c)` and the years), the one fact of an author that the repository holds; its `url` is the account that owns the repository (`SITE_REPOSITORY_ADDRESS` without its last part). It is the `author` of the `SoftwareApplication`, the `SoftwareSourceCode`, each `TechArticle` and each `BlogPosting`, and the `publisher` of the `WebSite`. Each page has `<meta name="author">`, also with no site address, and the two feeds name it in `<author>`. When `LICENSE` names no holder, there is no `Person`, no field names one, and the feeds name the system.

### The sitemap, robots.txt and the feeds

- `sitemap.xml` lists the canonical address of each page that the command writes, once, by path. A page has a `lastmod` only when the tool knows the date of its last change: `news/` (the date of its newest entry) and `releases/` (the date of its newest release). The other pages have none: each build changes their foot, and the tool does not read the history of their sources. A wrong `lastmod` teaches a search engine to ignore the field.
- `robots.txt` allows each page and gives the address of the sitemap. A crawler reads `robots.txt` only at the root of a host: when the site address has a path, the command says that the `robots.txt` of the root must have the line `Sitemap:`.
- `releases.xml` is the feed of the releases (Atom): one entry for each release of `CHANGELOG.md`, newest first, with its date (`published` and `updated`, at 00:00 UTC), its first change as its summary, and its changes in HTML. The id of an entry is `<repository>/blob/master/CHANGELOG.md#release-<number>`: a release is never renamed, so the id does not change when the site gets an address.
- `llms.txt` follows the form of llmstxt.org, as the site of the owner has one: the name, the lead of `README.md` as a quote, then a list of the pages for each section, each with its title and its description; the module pages are in the part `## Optional`.
- `site.webmanifest`: the name, the description (the whole first paragraph of `README.md`, cut at 160 bytes), `lang`, `start_url` and `scope` `./` (the root of the site, where the manifest is), the dark background as the background and theme color, and three icons: 192 and 512 with `"purpose": "any"`, and 512 with `"purpose": "maskable"`. Its addresses are relative to it.

### The pictures

Each `img` has `width`, `height` and an alt text (a check of the pages). The pictures below the first screen have `loading="lazy"` and `decoding="async"`: the pictures of the carousel of the home, the thumbnails of the gallery, the pictures of the news and of the guides. The mark of the home and the heron of the bar are on the first screen and load at once. A film of a news entry is a `video` element with its `width`, its `height` and a `poster` ("The film of a news entry"); the check of the links of a page reads `poster` as it reads `href`, `src` and `srcset`.

Each PNG file that the site copies from the repository (the screen pictures, the pictures of the news and of the guides, the icons) is written again through `site_png_compress` (`tools/kerneltool/site_pictures.odin`): it decodes the file and encodes the same pixels with the encoder of the standard library, `core:image/png` (a row filter chosen for each row, then the deflate of `core:compress/deflate` at its default level 5). The screen pictures of `docs/screenshots` are stored with no compression (`png_encode` of `tools/kerneltool/machine.odin`): 2 360 312 bytes for 1024 by 768. The command prints the count of the pictures and their bytes before and after. The output is the same bytes at each build: the encoder reads no clock, no random number and no thread, and its buffers start at zero; a host test encodes each picture twice and compares the bytes, and compares the pixels of the two files byte for byte. A picture of 16 bits a channel stops the command: the repository has none.

No picture is written at half its width as a second candidate of a `srcset`. The thumbnails of the gallery are another case: a thumbnail is the `src` of its element, so every reader gets it, and the picture at its full size is behind its link (see "The thumbnails"). A browser takes a picture of 512 pixels from a `srcset` only when its place, times the density of the screen, is at most 512 pixels: the place of a picture of the home was 556 pixels on a wide screen, and a phone of density 2 or 3 needs more than 512 pixels for its whole width. So nearly no reader gets the half picture, and its 2 by 2 mean blurs the text of a screen picture. A build that wrote them measured about 60 000 bytes for each half picture; the compressed whole picture is expected near 150 000 bytes (the command prints the measure), so a half picture saves about 90 000 bytes, for that rare reader only. The rule: a version for `srcset` earns its place only when the common screens choose it and it saves at least half of the bytes; the half pictures fail the first part.

### The checks

After the checks of the pages, with a site address:

- each page has one canonical address, its own (the folder of the page, with a final slash), and no two pages share one;
- each page has `og:url` (its canonical address), `og:type`, `og:title`, `og:description`, `og:site_name`, `og:image:alt`, and an `og:image` that is a PNG file that the command wrote, with the width and the height that the page states;
- each page has one page graph; it parses (`core:encoding/json`, strict JSON), its `@context` is `https://schema.org`, it has a `@graph`, and each `@id` that a field names is a node of the graph or the canonical address of a page of the site;
- the sitemap lists each page that the command writes once, and no other address.

With no site address: no page has a canonical address, Open Graph or a page graph, and there is no sitemap. A page with two `h1` fails the checks of the pages.

## The numbers

Each number is a line that a program printed in the log of a machine test, quoted whole: the line gives its own conditions. The table also gives the log, the line number, the machine that wrote the log, where the line comes from (the full check of the measure record, with its date and its commit, or a log of this work tree), and the time of the log or of the record. No number is typed by hand. When neither a log nor the measure record has the line, the row says "Not measured." with the reasons, and the command lists it.

The first paragraph of the page states the run of the measure record: its time, its commit and whether its tree had changes that were not committed, its release, its host and its count of checks that passed. When the release of the record is not the newest release of the changelog, a paragraph says that the numbers were measured before the release that the site shows. With no measure record, a paragraph says so.

A rate over a duration comes from a measure run (`docs/TOOLS.md`, "A check by count, a measure by time"): the test checks by count and writes no rate. `kerneltool screenshots` runs these measure runs after the test, so their logs are in `build/` when it writes the measure record.

| Number | Log in `build/` | Text of the line | Required |
|---|---|---|---|
| Kernel entries in one second, 1, 2 and 4 lockers | `test_output_measure.txt` | `locks: kernel entries in one second` | yes |
| Reads of the time page in one second | `test_output_measure_clock.txt` | `clock: the time page:` | yes |
| Wakes in one second under EEVDF | `test_output_scheduler_1.txt` | `scheduler: EEVDF: two threads that wake each other` | yes |
| One glyph of the vector font | `test_output.txt` | `vector_glyphs: one glyph from its outline` | yes |
| A full frame of the compositor (the last line) | `test_output.txt` | `compositor: a full frame of` | no |
| Blocks read in one second, 32 in flight | `test_output_measure_disk.txt` | `disk: read, 1 block in each request, 32 in flight` | yes |
| 1000 commits to a private store | `test_output_persist_1.txt` | `notes: count 1000, stopped` | yes |
| The header and the checksum of a UDP datagram, in the program that sends it | `test_output_network.txt` | `net: the header and the checksum of a datagram` | yes |
| The round trip of a UDP datagram | `test_output_network.txt` | `net: the round trip of one datagram` | yes |
| UDP datagrams in one second, 64 in flight | `test_output_network.txt` | `net: a burst with 64 datagrams in flight` | yes |
| TCP, 1 MiB received from the host | `test_output_tcp_real.txt` | `fetch: GET /large:` | yes |
| TCP, 1 MiB sent to the host | `test_output_tcp_real.txt` | `fetch: POST /sink, 1 MiB` | yes |
| ChaCha20-Poly1305 on 1200 bytes | `test_output_cryptography.txt` | `cryptography_vectors: seal ChaCha20-Poly1305` | yes |
| The same bytes after a second build | `reproducible_build.txt` | `the same bytes after a second build` | yes |

`kerneltool check` and `kerneltool screenshots` write `build/reproducible_build.txt` after their comparison of two builds.

Under the table, the section "How to read each number" says that a number is one run on the host of the record, that no test asserts it, and then, for each number, the text `reading` of its entry in `site_measures`: what the program does to measure it, and what the number does not say.

A required number is a line that a scenario of `kerneltool test` waits for (a step `Wait`), or the line of the second build: a run that passed holds it. A host test checks that each required number is such a line. A full frame of the compositor is not required: the compositor prints it when a frame redraws the whole screen, and no step waits for it. The lock measure of `kerneltool measure` (`test_output_measure.txt`) comes first when it is newer, but the full check does not run it: the full check takes the same line from `test_output.txt`.

## The measure record

The site workflow builds the site on a clean checkout and runs no machine test: the logs of `build/` are absent there. So the pass that commits the pictures also commits the numbers. `kerneltool screenshots` runs the machine tests (`kerneltool test`) and the second build, then writes `docs/measures/measures.txt` before it copies the pictures. The file is in the repository.

The form, one line for each fact, a key, one space and a value:

```
measure record 1
time 2026-11-12 02:09 UTC
release 0.91.0
commit <40 hexadecimal digits, or unknown>
tree clean | changed | unknown
host <processor model>, <n> logical processors; QEMU with KVM
checks <count of checks that passed>
number <the sentence of site_measures>
log build/test_output.txt
line <line number in the log>
matching <count of lines with the text>
machine <the machine that wrote the log>
text <the whole line of the log, with its label>
number <a sentence of a number that the run did not give>
absent <why>
boot kernel: boot: firmware: 1031293 us
end
```

- The numbers are in the order of `site_measures`, the lines `boot` in the order of the log of the main machine. The same run gives the same bytes but for the measured values, the time and the count.
- The commit and the tree are read when the pass starts, before it writes into the tree. The commit is the commit of the tree that ran: the commit that holds the record comes after it.
- `time` is the time when the record was written, in UTC. `checks` counts each line `kerneltool: test passed: ...` of the process.
- A log written before the start of the run is of another run: the pass does not read it.
- The pass fails, and does not write the record, when a required number has no line in the logs of the run. A number that is not required and has no line gets a line `absent`.
- The pass reads the record back before it writes it. The site refuses a record that does not have this form, and stops.

What the record never holds, and how the pass removes it from each value:

- A path in the repository becomes relative to it: `<repository>/build/x` becomes `build/x`, the repository folder alone becomes `.`.
- The home folder becomes `~`.
- The user name (`USER`) becomes `<user>`, and the host name (`/proc/sys/kernel/hostname`) becomes `<host>`, when they have 3 bytes or more: a shorter name matches parts of common words.
- The host line holds the model of the processor (`/proc/cpuinfo`), the count of logical processors, and "QEMU with KVM" when `/dev/kvm` exists, else "QEMU with TCG".

How the site chooses, for each number and for the stages of the start:

- A log of `build/` that has the line and is newer than the record (the time of the files in the work tree): the log. A person who just ran the tests sees their numbers. The row says "Measured in this work tree".
- Else the record, when it holds the line. The row says "Measured in the full check of <date>, on the tree of <commit>".
- Else "Not measured.", with the reasons: no log, a log older than the record, no record, or the reason of the run.
- A checkout writes the record at the time of the checkout: the logs of an older run lose.

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

- the bar at the top, as the bar of the desktop: the heron at the left, then the name of the system in the font of the name of the mark, three sections as buttons and the others in one menu under its button, as a menu of the bar of the desktop (see "The buttons and the menu of the bar"), the current one marked by a line in the blue of the title bar; under 720 pixels, the sections and the search are behind one menu button (see "The site menu");
- the news cards of the home, side by side on a wide screen: the title, the line of the kind and the date, and the picture of each card of a row start at the same height, whatever the length of a title. Each card takes four rows of the grid of the cards and shares them (`grid-template-rows: subgrid`): the title, the line of the kind, the picture, the text. The content of a card starts at its top, with no empty room between two of its parts (see "The home", "The rule of a card"): a card with no picture has its text in the row of the pictures, right under its line of the kind (`.news-card-without-picture`). The picture boxes have one ratio, 4 by 3, the ratio of the screen pictures; a picture of another ratio is shown whole in the box (`object-fit: contain`), not cut. A browser with no subgrid shows the cards as blocks, and a title keeps the room of two lines on a wide screen, so that the common case aligns. No title is cut. On a narrow screen (one column) nothing changes. The cards of the page News stand one under the other at every width: no row to align;
- cards with a border of 1 pixel in their accent and the bar of 4 x 16 pixels before their title, as the cards of the boot display;
- the colors of the concepts with their meaning in the system: the stages of the line of time of the start take the color of who runs them (the firmware violet, the boot program orange, the kernel blue);
- the tables have the look of the tables of the system: the titles of the columns in the dim color, every second row on a band (`DESIGN.md`, section 10). Each column has the least width of its kind, and a table wider than the page scrolls sideways in its own box (see "The tables");
- the grid of points of the desktop is on the home only.

Prose is in the reading font of the reader's system, at most 72 characters a line on a presentation page and 80 on a documentation page; code, signatures, numbers and identifiers are in its monospace font. The site holds one font file: the font of the name of the mark, for the name of the system where it stands as the mark (see "The name of the mark"). No animation, no shadow, no round corner; two exceptions. A control shows its state at once, with no transition (see "The states of a control"). A segment of the bar of the chart of the docs home changes its place and its width in 150 ms when the search changes its count, never at the load of a page, and at once for a reader who asks for reduced motion (see "The chart of what the search finds"). The large heron of the home plays the animations of the mark, and not at all for a reader who asks for reduced motion (see "The rhythm of the animations" and "The moves of the heron"). The light form follows `prefers-color-scheme`. A print form hides the bar and the navigation.

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

### The tables

The owner asked for it on 2026-11-12, of the measured numbers at a width of 1630 pixels: "tableau pas ouf, si possible de faire un tableau scrollable ? pck la colonne compressée".

The writer of each generated table states the kind of each column (`Site_Column_Kind` in `tools/kerneltool/site_pages.odin`), because it knows what the column holds. `site_table_start` writes the class of the kind on each header cell, and `site_table_end` writes it on each cell of the body, by the place of the cell in its row. The style sheet gives each kind its least width as a `width` on the header cell: in the automatic layout of a table, that width is a least width, and a table with more room shares it in proportion to those widths.

| Kind | Holds | Least width | Wraps |
|---|---|---|---|
| Name | An identifier, a path, a signature | Its text | Never |
| Short | A few words: a kind, a status, a version | 6 em, about 12 characters | At spaces |
| Prose | Sentences | 13 em, about 28 characters of the reading font | At spaces |
| Line | A quoted line of a log or of code | 30 em, about 57 characters of the monospace font at 14 pixels | At spaces; a long word breaks only when it is wider than the cell |
| Date | A date and a time, `2026-11-12 02:09 UTC`, in a `<time datetime="2026-11-12T02:09Z">` element | Its text | Never |
| Number | A number | Its text | Never; aligned right, with figures of one width |
| List | Several names: modules, grants, statuses, labels | 8 em, and at least its longest name | Between its names, never inside one |
| Any | A column of a table of a document of `docs/` | 6 em, about 12 characters | At spaces; a cell that holds only a number or a date gets that kind |

A list of names is not a name. On 2026-11-13 the table of the grants of each program showed each set of grants as its Odin literal, on one line that pushed the column of the reasons out of its box, and a row of several programs started lines with a comma. A cell or a fact that holds several names is a list of values (`site_value_list`): a `<ul class="value-list">` with one value in each item, each item on one line, the list wrapping between its items, with no brace, no period before a member and no comma. A screen reader reads the count of the items. Its least width is its longest name, so a column of lists never pushes the column of prose out of the box. The writers that use it: the programs and the grants of the page of the grants (each grant a link to its row in the table "What a program receives at its start", with its name and no period), the grants and the budget of a program on its module page, the imports of the index of the modules, the imports, the importers and the build settings of a module page, the table of the edges of the module graph, the statuses that the text of an operation names, the parameters of a command of the console and of an export, the types that a wire form names, the variants of a union and the places that name a type, and the evidence items and the gaps of each property on the status page. A value of a source is never shown as its literal: a set of grants of the root service is read as its members (see "The reference tables").

The measured numbers are What (Prose), The line of the log (Line), Log, line, machine (Prose) and Written (Date): 13 + 30 + 13 em and the date, under the 1120 pixels of the column of the page, so the table does not scroll on a wide screen, and a line of a log takes two or three lines.

- The box: `<div class="table" role="region" tabindex="0" aria-label="...">`, the pattern for a table that scrolls: the keyboard reaches the box and scrolls it with the arrows, and a screen reader names it. The name is the name of the table that its writer gives, or the heading above a table of a document. The focus of the box is visible.
- From 720 pixels of width, the box scrolls sideways (`overflow-x: auto`) when the sum of the least widths passes the width of the page; where the table fits, nothing scrolls.
- Under 720 pixels a table does not scroll and has no columns: a row is a block. The first cell of the row is its title, in bold. Each other cell is under it, with the head of its column above it in the dim color (the attribute `data-label` of the cell, which `site_table_end` and the renderer of a document write; the style sheet shows it with `content: attr(data-label)`). An empty cell is not shown. The head row is kept for a screen reader and is not shown. A column squeezed to two words a line, or a table that hides its columns to the right of a phone, is the fault that this rule removes.
- A sign that there is more: a line in the color of the line of a link at each edge of the box where more of the table is, tied to the place of the scroll of the box (a scroll timeline, `animation-timeline: scroll(self inline)`). It moves with the scroll, not with the time, so it is not an animation in the sense of `DESIGN.md`. A box that does not scroll has no line. A browser with no scroll timeline shows its scroll bar only.
- From 720 pixels, the first cell of each row stays in view while the table scrolls sideways (`position: sticky; left: 0`), on an opaque background of the color of its row.
- The head row does not stay at the top while the page scrolls. A box with `overflow-x: auto` is a scroll container for both axes, so a `position: sticky; top` of the head would stick inside the box, which does not scroll up and down: the rule would do nothing, so it is not written. The bar of the site does not stay at the top either.
- On a narrow screen a heading, a paragraph, an item, a caption and the breadcrumbs break a long word; a cell of a table does too, because its row is a block.

### The site menu

The owner asked for it on 2026-11-12: "il manque un menu burger sur la version mobile du site".

- The sections and the search field are in one `<details class="bar-menu">` of the bar (on the docs home, the sections only: its field is in the page): one list of links for every width, so a screen reader reads each section once. Its `<summary>` is the button: a square of 32 pixels with three lines of 16 by 2 pixels drawn by the style sheet, and the word "Menu" as its name, hidden by the style sheet. With no style sheet the word shows, and the button opens the list.
- Under 720 pixels: the heron and the name at the left, the button at the right. The open menu lies over the page under the bar, over the whole width: the sections one under the other, the current one marked by a line at its left, then the search over the whole width with its list under it. The open button has the border and the lines in the color of the line of a link. The focus is visible (the rule of the site). The button is a `summary`: Enter and Space open and close it with no script.
- On a wide screen the menu is open and its button is hidden, so it is the bar of today. A `details` that is closed in the file cannot be opened by a style sheet in every browser, so two ways meet:
  - A browser that has `::details-content` shows the content of the closed menu on a wide screen and hides the button (`@supports selector(::details-content)`), with no script.
  - `search.js`, loaded with `defer` on each page, opens the menu on a wide screen and closes it on a narrow one, when the width changes too (`matchMedia("(min-width: 720px)")`). On a narrow screen it also closes the menu at Escape (and puts the focus on the button) and at a click outside, and opens it for `/` and for an address with `?q=` when the menu holds the search field. On the docs home the large field is in the page, also on a narrow screen, and the menu holds the sections only.
  - With no script, a browser with no `::details-content` shows the button on a wide screen too, and the button opens the list: the page stays whole. With the script, such a browser shows the button for the time between the first paint and the run of the deferred script.
- The menu is closed in the file, not open: an open menu that the script closes on a narrow screen moves the page after its first paint on each load.
- At 360 pixels, no line is wider than the screen: a table and a block of code scroll in their own box (`.table`, `pre`); a heading, a paragraph, an item, a caption and the breadcrumbs break a long word or address (`overflow-wrap: anywhere`); the line of time of the start, the charts, the tiles and the pictures fit a column of 328 pixels.

### The buttons and the menu of the bar

The owner decided it on 2026-11-14, on the fact that six sections do not fit the one line of the bar near 720 pixels: "Regrouper certains trucs dans un dropdown et voilà". The code is `tools/kerneltool/site_bar.odin`; its host tests are `site_bar_test.odin`; the intent is `src/md/features/site_bar.md`.

The bar is one line of 41 pixels, and the parts under it are placed by that height ("The polish of the browser's parts"). Six sections stand under the home. The bar names them all:

| Part | Sections | Table |
|---|---|---|
| Buttons | Docs, Gallery, News | `site_bar_buttons` |
| The project menu (`GLOSSARY.md`): a button "Project" and a panel under it | Status, Releases, Roadmap | `site_project_menu_sections` |

**The rule that decides what is a button.** A button is what a first reader looks for: what the system is and how it works (Docs), what it looks like (Gallery), what is new (News). The project menu holds the pages that report how the project goes: what is built and what is missing, what each release brought, what is planned. The pictures are one click from each page; the roadmap is two clicks. The word of the button is the name of the group "Project" of the glossary. A section under the home is in one of the two tables: a host test fails for a section in neither or in both.

**The width.** The numbers are those of the style sheet; a text is counted at about 8 pixels a character, at 16 pixels in the fonts of the common systems.

| Part | Pixels |
|---|---|
| The padding of the bar, left and right | 32 |
| The heron (24), its gap (8), the name (66) | 98 |
| The gap before the sections, the gap before the search field | 48 |
| The search field | 224 |
| Docs, Gallery, News: the text and 16 of padding each (48, 72, 48), and 8 after each | 192 |
| Project: the text (56), 16 of padding, 12 for its mark | 84 |
| The whole bar | 678 |

A window of 720 pixels with a scroll bar of 17 pixels has 703. The host test `site_bar_fits_one_line_at_720_pixels` computes the bar at 9 pixels a character: 700. With a button for each of the six sections the bar needs 826 pixels at 8 pixels a character: it breaks into two lines up to that width.

**The menu works with no script.**

- It is one `<details class="project-menu">`, the last item of the list of the sections, closed in the file. Its `<summary class="project-menu-button">` is its button: a rectangle as a button of a section, the word "Project", and a square of 6 pixels as its mark, dim when the menu is closed and in the line color when it is open. A click, Enter or Space opens and closes it.
- Its panel (`.project-menu-panel`) is a card under the button, as a menu of the bar of the desktop: a border of 1 pixel in the line color, one row of 32 pixels for each section. A row is a link; the pointer over a row gives it the track color. The panel is not a list under an item of the list: such a list of a navigation is a list of tree lines ("The tree lines"), and three links are not a tree.
- The panel lies over the page and moves nothing: it is placed under the bar (`position: absolute`, 8 pixels under its button, which is the bottom of the bar), in the stacking of the bar, which is over the page (`z-index: 30`), and over the list of the search (`z-index: 20` against 10).
- Its width is definite, 176 pixels (`SITE_PROJECT_MENU_PANEL_WIDTH`): its longest line, "Releases", has room at twice the usual width of a character, so no line is cut. It starts at the left edge of its button, which is at the left of the search field: on a window of 720 pixels it ends near 520 pixels. It cannot pass the right edge of the window.
- **The current mark.** On a page of Status, Releases or Roadmap, the button "Project" has the line of a current button (`.project-menu-current`), and the link of the section in the panel has `aria-current="page"` and a line at its left. On each other page, the button of the section has the line, as before.
- **The keyboard.** Tab reaches the button, then each link of the open panel, in the order of the page. The `summary` says by itself, to a screen reader, whether the menu is open.

What `search.js` adds, on a window of 720 pixels or more: Escape closes the menu and puts the focus on its button; a click outside closes it; a focus that leaves it closes it. The script adds no element and no style.

**Under 720 pixels** the sections are already one under the other in the site menu ("The site menu"). The project menu is then not a menu: the word "Project" is a dim line of the list, and its three sections are the lines under it, 16 pixels to the right. So the site menu names all six sections, and a section of the project menu is one tap away, as each other. The two ways of the site menu make it so, in the other direction: a browser that has `::details-content` shows the content of the closed element, and the word takes no click; in another browser `search.js` sets the element open and refuses the click that would close it. With neither, the word is a button that opens its three lines.

Refused: a second line of the bar; smaller text; icons with no word; one menu button at every width; a menu that opens when the pointer passes. The reasons are in the intent file.

### The states of a control

The owner asked for it on 2026-11-14: "les boutons [...] manquent d'un état visuel au survolage et actif." The code is `tools/kerneltool/site_controls.odin`; the intent is `src/md/features/site_bar.md`.

A site control (`GLOSSARY.md`) is a part of a page that a reader presses. Before this rule a button had no sign of the pointer: a link under the pointer takes the track color, and a button is already a rectangle of the track.

One table, `site_controls`, names every control with its selector and its form. One procedure writes the rules of its states (`site_control_rules`), at the end of the style sheet, so a state wins over the look at rest. No control has rules of states of its own.

| Form | Controls | Pointer over it, or focus | Pressed | Current, open or chosen |
|---|---|---|---|---|
| Button | A button of a section of the bar, the button of the project menu, the button of the site menu, a door of the home, a link to a group of the gallery, a numbered link of the carousel, a letter of the index of the glossary, the button of the line of an older build | The blue of the title bar at 60 %, `0x254A75` | The blue of a chosen row, `0x3C76BB`, with a white label | The line of 2 pixels in the line color that the control has at rest in a clear color; the button of the open project menu has the colors of a pressed button |
| Menu line | A line of the panel of the project menu | A chosen row: `0x3C76BB`, white label | The same | The line at its left |
| Row | A row of the list of the search, a chip of the chart of the search, a line of the documentation tree and of "On this page", a row of a stage of the line of time of the start | The band of the track | The band, and the line at its left in the line color | The band and the line |

The colors are those of a button and of a line of a menu of the desktop (`DESIGN.md`, section 10, the row "Button"; `DESIGN.md`, "Menus"): the site and the desktop are one design. The focus also keeps the outline of 2 pixels of the site: a state never removes it.

- **No layout shift.** A state changes a background, the color of a text, or the color of a border that the control has at rest. No state adds a border, a padding or a weight of the text.
- **No transition.** A state shows at once.
- **A tap.** `:active` holds while a finger is on the control, so a phone shows the press; the tap highlight of the browser stays too.
- **A link of a text** takes the band of the track under the pointer and while it is pressed.
- **The mark of the button of the project menu** takes the color of the label in each state: the dim color has too little contrast on the blue.

The contrast of the text in each state (WCAG 2 ratio):

| State | Dark form | Light form |
|---|---|---|
| A button at rest: the text on the track | `0xDCE4EC` on `0x1C2633`: 11.90 | `0x0B1018` on `0xD6DBE0`: 13.68 |
| The pointer over a button, or the focus | `0xDCE4EC` on `0x254A75`: 7.06 | white on `0x254A75`: 9.07 |
| A pressed or an open button; a line of a menu under the pointer | white on `0x3C76BB`: 4.67 | white on `0x3C76BB`: 4.67 |
| A row under the pointer or pressed | 11.90 | 13.68 |

The host test `site_controls_have_their_states` checks, for each control of the table: its rule at rest, a rule for the pointer, for the focus and for a press; that the rules of the states hold no size, no transition and no rule that removes an outline; that they are the end of the style sheet; and each contrast above, at 4.5 to 1.

### The two layouts

The owner asked for it on 2026-11-12: "la doc, je veux un vrai truc de doc, comme Odin par exemple, où ils ont une sidebar, il y a des documentations techniques au centre, il y a les symboles à droite". The code is `tools/kerneltool/site_documentation.odin`.

The writer of each page states its layout (`Site_Page.layout`); the tool does not guess it from a path.

| Layout | Pages | Form |
|---|---|---|
| Presentation | The home, the docs home, the news, the releases, the roadmap, the gallery | One centred column of at most 1152 pixels |
| Documentation (`GLOSSARY.md`) | Each guide, each reference page, the index and the page of each group of the glossary, each module page, the status, and the index pages of the guides, the reference and the modules | The documentation tree, the text, "On this page", over the whole width of the window |

The documentation tree (`GLOSSARY.md`) is one `<nav class="tree" aria-label="Documentation">`. Its first link is the docs home, "Docs", the way back to the door of the docs. Then, on a guide: "Guides" with each guide in the reading order of the page of the guides, "Reference" with each reference page in the order of its index (under the glossary, each of its groups with the count of its terms), "Modules" with a heading for each group (Kernel, Programs, Modules) and the modules of the group under it, and "Status". The tree is whole: it has no `details`, and no part of it is folded. Each list under an item is a list of tree lines (see "The tree lines"). The current page has `aria-current="page"`. It is written once in each page, inside the site menu, after the search: under 720 pixels it is under the sections in the open menu, which scrolls on its own; from 720 pixels the style sheet fixes it at the left of the window (`position: fixed`, its own `overflow-y`), so a long tree never moves the page. With no script, a browser with no `::details-content` shows the tree when the button of the menu opens it, as the sections.

"On this page" (`GLOSSARY.md`) is one `<details class="outline">` at the start of `main`: the title of the page (a link to `#content`), then each heading h2 and h3 with an id, and each element that states a symbol with `data-outline`, in the order of the page. It is a tree of two levels: the title and each heading h2 are the items of its first list; a heading h3 or a symbol is a branch of the item before it, in a list of tree lines (see "The tree lines"), so a symbol with no heading h2 before it is a branch of the title. From 1100 pixels it is a column at the right of the text, sticky, with its own scroll, and open (`::details-content`, or `search.js`); under 1100 pixels it is closed above the text, and its summary "On this page" opens it. The script marks the link of the part in view with `aria-current="location"`: an `IntersectionObserver` reports each heading and symbol that enters or leaves the top 40 % of the window; nothing runs each frame. With no script it is a correct list of links.

The text keeps a measure of 80 characters (`80ch`) for paragraphs, items, headings and quotes; a table, a block of code and a figure take the whole middle column, and a table still scrolls in its own box.

| Width of the window | Columns | The grid |
|---|---|---|
| Under 720 pixels (360) | The text only; the tree is in the menu; "On this page" is closed above the text | `main`: `grid-template-columns: minmax(0, 1fr)` |
| 720 to 1099 pixels (768, 1024) | The tree, fixed, 256 pixels; the text | `body`: `padding-left: 256px`; `main`: `grid-template-columns: minmax(0, 1fr)` |
| From 1100 pixels (1440, 1920, 2560) | The tree, 256 pixels; the text; "On this page", 240 pixels | `body`: `padding-left: 256px`; `main`: `grid-template-columns: minmax(0, 1fr) 240px` |

No column has a fixed least width but the tree and "On this page", and each grid item of the text has `min-width: 0`: no line is wider than the window at 360, 768, 1024, 1440, 1920 and 2560 pixels. At 768 pixels the text column is 480 pixels; at 1100 pixels, 540.

Print shows the middle column only: the bar, the tree, "On this page", the breadcrumbs and the links to the guides before and after are hidden.

### The tree lines

A navigation of the site that is a tree shows its levels by tree lines (`GLOSSARY.md`), as a file tree does, not by its indentation alone. The rule is one for every tree: each list under an item of another list, inside a `nav` element, has the class `tree-lines` (`SITE_TREE_LINES_LIST_OPEN` in `tools/kerneltool/site_documentation.odin`), and the style sheet draws the lines of each item of such a list. No tree has a rule of its own for the indentation of a level.

The trees of the site:

| Tree | Written by | Levels |
|---|---|---|
| The documentation tree | `site_tree_html` | 3: a part ("Guides", "Reference", "Modules"); its pages, or the groups of the modules; the groups of the glossary under the glossary, or the modules under their group |
| "On this page" | `site_outline_html` | 2: the title and the headings h2; the headings h3 and the symbols |

The sections of the bar, the breadcrumbs, the letters of the glossary and the links to the pages before and after are lists of one level: they have no line. A list of the text of a page is not a navigation: it keeps its square marks.

The numbers, in CSS pixels, on the grid of 8 pixels:

- A row is 24 pixels high: a line of text of 20 pixels and 2 pixels above and under it. The name of a group of modules has the same row as a link.
- A level is 16 pixels to the right of the level above it: the list starts 8 pixels from the left edge of the row of its parent (`margin-left: 8px`), and the row of each item starts 8 pixels further (`padding-left: 8px`). The text of a row starts 10 pixels from the left edge of its row (a border of 2 pixels, which marks the current row, and a padding of 8 pixels), so the vertical line is 2 pixels to the left of the first letter of the parent.
- The vertical line is 1 pixel wide, at the left edge of the list. It starts at the bottom of the row of the parent.
- The branch of an item is 1 pixel high and 8 pixels long, from the vertical line to the left edge of the row of the item, 12 pixels under the top of the item: the middle of its first line.
- The corners are square. No line has a round end.

How an item draws its lines: two parts with no text (`::before` and `::after`, `content: ""`), with borders of 1 pixel, so a screen reader reads the lists as before and the lines stay in a forced-colors mode.

- The corner (`::before`): a box of 8 by 13 pixels at the top of the item, with a left border and a bottom border: the vertical line from the top of the item to its branch, and the branch.
- The rest (`::after`): a left border from 13 pixels under the top of the item to its bottom: the vertical line beside the rest of the item and beside its own branches. The last item of a list has none (`li:last-child`).
- So the vertical line of a list stops at the branch of its last item, and not at the bottom of the branches of that item. An item whose name takes two lines keeps its branch at the middle of the first one, and its second line starts under the first, at the right of the line.

The colors:

- A tree line is `--tree-line`: the dim color at 40 % on the track (`color-mix(in srgb, var(--dim) 40%, var(--track))`), about `0x424E5C` in the dark form and `0x9EA4AB` in the light form. On the surface of the tree its contrast is 2.10 (dark) and 2.43 (light). The track alone is 1.17 and 1.35 there: a line of 1 pixel in it does not show. The dim color alone is the color of a text.
- The lines from the first list to the current item are in the line color, the color of the line under a link: the corner of each item that holds the current item, and the vertical line beside each item before it in its list. So the way from a part to the current page reads at once. The current item is the link with `aria-current`: `page` in the documentation tree, `location` in "On this page", where the script moves it as the page scrolls. The rule uses `:has()`; a browser with no `:has()` draws every line in the color of a tree line.
- The current row keeps its look: the line of 2 pixels at its left in the line color, and in the documentation tree the band of the track. A row of "On this page" that is not the current one has no line of its own at its left: the tree lines are its only lines.

What the lines do not touch:

- The band of a row under the pointer starts at the left edge of the row, where the branch ends.
- The outline of the focus is 2 pixels wide, 2 pixels from the row, so it crosses the branch of its row and the top of the line of its branches. A link of a tree that has the focus is drawn over the lines (`position: relative; z-index: 1`), so no line cuts its outline.
- The lines take no events of the pointer.

The widths: the column of the tree is 256 pixels, with 8 pixels of padding at each side. The text of the deepest level starts 42 pixels from the left edge of the lists and has 190 pixels, or 174 when the tree scrolls and shows its scroll bar of 16 pixels; a longer name breaks and continues under its own start (`overflow-wrap: anywhere`). The text of a branch of "On this page" has 206 pixels of its 240. In the open menu of a narrow screen the tree has the same lines and the width of the screen less 32 pixels.

Print hides the tree and "On this page", so it has no tree line. The lines do not move: a reader who asks for reduced motion sees the same page.

The host tests: `site_documentation_tree_has_tree_lines` (each list under an item of the documentation tree has the class, to the deepest level), `site_documentation_outline_is_a_tree`, `site_documentation_tree_lines_check` (the check of the pages, `site_tree_lines_problem`, on good and damaged pages) and `site_documentation_tree_lines_in_the_style_sheet` (the rules above, and no rule of the indentation of one tree).

### The kinds of values

The owner asked for it on 2026-11-12: "que les valeurs techniques, comme par exemple le fait de dire handle ou les valeurs numériques, soient affichées en monospace, qu'elles aient une couleur [...] accompagnées d'un icône". The rule of the two fonts of the desktop holds (`DESIGN.md`, "Two fonts"): a name or an explanation in the reading font, a value in the monospace font. The code is `tools/kerneltool/site_values.odin`.

The value kinds (`GLOSSARY.md`) are one enumeration of the system, `value_kinds.Value_Kind` (`contract/value_kinds`), with the name of each kind (`VALUE_KIND_NAMES`, the class `value-<name>`): a log record of the system keeps the same kinds. The color of each kind is one table of the system, `support/graphics/value_colors.odin`: an accent of `support/graphics/rules.odin` with a `graphics.shade` for each color scheme (`DESIGN.md`, "The colors of values"); the program `log` reads the same table. The icon of each kind is its kind icon (`GLOSSARY.md`), one table of the system too, `support/kind_icons` (12 by 12 cells, `#` a cell; `DESIGN.md`, "The icons of the kinds"): the palette of the desktop draws the same cells. The table of the site, `site_value_kinds`, gives each kind what only the site shows: its title and its meaning. The contrast is that of the text of a value on the two surfaces of a table: the background and the band of every second row (dark: `0x0B1018`, `0x17212E`; light: `0xF4F6F8`, white). A host test computes each one.

| Kind | Icon | Accent | Dark: color, contrast | Light: shade, color, contrast |
|---|---|---|---|---|
| Number: a count, a place, an index, an address | A hash sign | Memory | `0x38C0B0`, 8.47 / 7.22 | 65 %, `0x247C71`, 4.62 / 5.00 |
| Size: bytes or pages | Three stacked bars | Memory | 8.47 / 7.22 | 4.62 / 5.00 |
| Time: a duration, a date, a time | A square with two hands | Boot program | `0xE0A040`, 8.42 / 7.17 | 65 %, `0x906729`, 4.66 / 5.05 |
| Handle | A square ring on a stem | Kernel | `0x4A9CF0`, 6.63 / 5.65 | 73 %, `0x3571AF`, 4.69 / 5.08 |
| Value: a value of the context, not a handle | One small square | Memory | 8.47 / 7.22 | 4.62 / 5.00 |
| Grant | A check mark in steps | Machine | `0xD070B0`, 6.02 / 5.12 | 78 %, `0xA15688`, 4.61 / 5.00 |
| Status: a status, an error kind, the state of a property | A flag | Failed | `0xF06060`, 5.94 / 5.06 | 78 %, `0xBA4A4A`, 4.65 / 5.04 |
| Type: of the contract, a wire form, a record of a module, a basic type | Angle brackets `< >` | Firmware, at 115 % | `0x9E8FCB`, 6.58 / 5.60 | 83 %, `0x7566A1`, 4.65 / 5.03 |
| Operation of the kernel | An arrow into a box | Kernel | 6.63 / 5.65 | 4.69 / 5.08 |
| Command of the console or of the tool | A prompt `>_` | Program | `0x58D878`, 10.45 / 8.90 | 58 %, `0x327C45`, 4.72 / 5.12 |
| Module | A block with a notch | Program | 10.45 / 8.90 | 4.72 / 5.12 |
| File or folder of the repository | A page with a corner of steps | Dim | `0x7C8A99`, 5.40 / 4.60 | 82 %, `0x65717D`, 4.60 / 4.99 |
| Guide: a document of the site and a heading of it, in a document reference | A page with three lines of text | Text | `0xDCE4EC`, 14.84 / 12.64 | 20 %, `0x2C2D2F`, 12.72 / 13.78 |
| Version, release, commit, hash | A tag with a hole | Boot program | 8.42 / 7.17 | 4.66 / 5.05 |
| Yes: a state that holds | A filled square | Program | 10.45 / 8.90 | 4.72 / 5.12 |
| No: a state that does not hold | An empty square | Dim | 5.40 / 4.60 | 4.60 / 4.99 |
| Procedure: a procedure of the declaration index | Two parentheses | Kernel | 6.63 / 5.65 | 4.69 / 5.08 |
| Constant: a constant of the declaration index | A lock | Memory | 8.47 / 7.22 | 4.62 / 5.00 |
| Global variable: a variable at the top of a package of the declaration index | A cross of two diagonals | Boot program | 8.42 / 7.17 | 4.66 / 5.05 |

The firmware violet at 100 % is 4.50 on the band of a row, at the bound: the type kind takes it at 115 %.

The markup: a value is `<code class="value value-<name>">`, written by one procedure (`site_value`), in the monospace font and the color of its kind, with a rule of 2 pixels at its left and no filled background. A color is never the only sign: the monospace font, the icon in the head of its column or before the label of its fact, and the text carry the kind too.

Who states the kind: the writer of each table gives the kind of each column (`site_table_start`, its last argument), and the writer of a symbol gives the kind of each fact (`Site_Symbol_Fact.kind`). No cell is classified by its text. The one rule of the column itself: a column of the kind Number is of the number kind, and a column of the kind Date of the time kind; their writers already state what they hold.

Where it shows:

- the reference tables: the statuses and the error kinds (status), the grants (grant), the operations (operation), the commands of the console and of the tool (command), the context roles (number; handle or value in each cell), the fixed ranges (number), the programs and their grants (module, grant; each a list of values, see "The tables"), the licenses (file, version), the index of the guides and of the reference (file), the measured numbers (the date: time; a quoted line of a log stays as the log has it);
- the module pages: the index (module, number, yes or no in each cell, the imports), the facts of a module (file, yes or no, size), the facts of each export (type);
- the facts of each symbol: its number, its statuses, its parameters and its result, its source line (file);
- the status page: the status of each property (status), the gaps and the next steps (number);
- the code spans of the guides, the glossary, the news and the source comments that name a declaration of the sources (see "The declarations of the sources"): the kind comes from the declaration index, never from the look of the span; another code span of a document keeps the look that Markdown gives it;
- the kind Guide is not a value: a document reference is a name in the reading font, and takes only the color and the icon of the kind (see "The references to documents"). It shows in the prose of a guide and of a source comment.

The restraint:

- At most one icon for each value, and the same kind always has the same color and the same icon.
- A column whose cells are all of one kind shows the icon once, in its head, and its cells keep the font and the color only. A fact shows the icon once, before its label. A value has its own icon only in a column of mixed kinds (handle or value, yes or no) or in a cell of facts of several kinds.
- No icon and no colored value in a heading (a check of the pages: `site_heading_value_problem`). In running prose, only a declaration reference: the span itself was code, and the icon says what the link opens.

The icons: the source of each one is the cells of its kind icon in `support/kind_icons` (`site_value_icon_cells`); the tool draws it as an SVG picture (one `rect` for each run of cells of a row, `shape-rendering="crispEdges"`, `site_value_icon_svg`). The style sheet holds each picture once, as a data address (`--value-icon: url("data:image/svg+xml,...")` in the rule of the kind, `site_value_icon_address`); the light form changes the color of a kind, not its icon. One procedure, `site_svg_data_address`, writes each data address of the style sheet, the icons and the grid of points of the home: it percent-encodes `%`, `<`, `>` and `#`, makes each double quote single, and drops the line feeds. The style sheet draws an icon as the `::before` of the element: a box of 12 by 12 pixels in the color of the kind, with the picture as its `mask`. A mask is an image of the style sheet: `img-src 'self' data:` covers it, and the style sheet is `style-src 'self'`, so the Content-Security-Policy of the host does not change. The command prints the bytes of the style sheet and the count of icons inside it.

Why inside the style sheet: the icons were 16 files of `pictures/values/`, 9 801 bytes in all, that the style sheet named. A browser learns of such a file only when it reads the style sheet, then asks for each one alone; each took 220 to 290 ms when the edge of the host did not hold it. Measured on the published site in a browser with an empty cache: on `/docs/` the icon of numbers arrived 349 to 635 ms after the start, after the first paint at 408 ms, so the icons appeared late. Inside the style sheet, an icon comes with the rules that draw it, and the compression of the style sheet takes most of the bytes that the files had. Nothing else names an icon, so the files are not written.

An icon and a segment of the chart of the docs home are graphics: their bound is 3 to 1 (WCAG 2.1, 1.4.11). The host test `site_value_graphics_contrast` checks the color of the value kind of each kind of search entry, in both forms, on the background, the two colors of a card and the track (the band of the chosen row). One sprite with an external `<use href="...#handle">` was refused: whether `img-src` or `default-src` governs the fetch of an external `<use>` is not the same in each browser, and `default-src` is `'none'`. The icon has no text and no name: it is decoration, and the head, the label or the text says the kind.

The legend: the reference index ends with the section "The kinds of values", a table of the icon, the kind and its meaning, from the same table.

### The versions of the files

The site is behind a proxy that keeps a file for hours. Each link to a file whose bytes change between builds carries its file version (`GLOSSARY.md`): `style.css?v=<16 hexadecimal digits>`, the first 8 bytes of the BLAKE3 hash of its bytes (`contract/blake3`). The files: `style.css`, `search.js`, `mark_animation.js`, `module_graph.js`, `glossary.js`, `carousel.js` and `search.json` (`SITE_VERSIONED_FILES`). The same bytes give the same address. The index of the search is written before the pages, so that each page names its version: `search.js` reads it from the attribute `data-index` of its own `script` element, relative to its folder, with no inline script. The check of the links ignores the query. The icons, the pictures and the font of the name of the mark carry no version: their bytes come from the mark and the repository and change rarely. One exception: the sprite sheets of the animations of the mark change with each new frame, and `mark_animation.js` cuts them by the places of its own table, so the script names each sheet with the version of its bytes.

### A page of an older build

A version in the address works for a file that a page names; it cannot work for the page itself, whose address is the one that a reader types or follows. The host serves each page with `max-age=600`, and the site cannot set the headers of its host. So a browser can show a page of an older build for 10 minutes after a publication, and the edge of the host for as long as it keeps it. On 2026-11-13 the owner saw a page whose code was not colored and a bare name of a document; the site served with an empty cache had neither: his browser or the edge had kept the older page.

What the site does:

- Each page names the commit of its build in its head: `<meta name="build-commit" content="<commit>">`. With no commit (the tool cannot read it), the page has no such line.
- `version.json`, at the root of the site, names the commit and the time of the build: `{"commit": "<commit>", "built": "2026-11-13 10:00 UTC"}`. The commit is empty when the tool cannot read it.
- `search.js`, which each page loads, asks for `version.json` once in each view of a page, with `cache: "no-store"` (past the cache of the browser) and a query `?at=<time in milliseconds>` (an address that no cache of the edge holds). It never asks again in the same view.
- When the page and the file both name a commit and the two differ, the script puts one line under the bar: "This page is from an older build: reload", where "reload" is a button that calls `location.reload()`. The line has `role="status"`, the dim color, and no style attribute (`.build-notice` in the style sheet). The page never reloads by itself.
- Nothing is shown when the commits are equal, when the page or the file names no commit, when the fetch fails or answers with an error, or when its text is not JSON: a page opened from a file shows nothing.
- The rule is one function of the script (`olderBuild`). The self test of the script (`?selftest=1`) runs it over the table `site_build_notice_cases` of `tools/kerneltool/site_search.odin`; the host test `site_older_build_notice` checks the file, the table and the parts of the script.

What it cannot do:

- It cannot make the browser fetch the new page: it tells the reader, who reloads. A reload asks the browser to check the page with the host, but an edge that still holds the older page serves it again until it lets it go; a second reload later then shows the new page.
- A page of a build from before this line has no `<meta name="build-commit">` and no such script: it never says that it is older.
- Two builds of one commit (a build of a tree with changes that are not committed) have one commit: the line does not tell them apart.
- With no script, nothing is shown.

## The mark on the site

The site asks the generator of the pictures of the mark for its pictures (`tools/kerneltool/mark_pictures.odin`; `TOOLS.md`, "The pictures of the mark"). The list is the rows of the site of the table of the uses of the mark (`DESIGN.md`, "The variants of the mark"); the site holds no number of a picture of its own:

| File | Variant, cells | Size | Use |
|---|---|---|---|
| `pictures/mark_home.png`, `mark_home_light.png` | smooth, heron 8 | 192 x 192 | The heron alone on a transparent background, in the head of the home, one file for each color scheme (`<picture>` and `prefers-color-scheme`) |
| `pictures/mark_bar.png`, `mark_bar_light.png` | cells, heron 1 | 24 x 24 | The heron alone in the bar of each page, one file for each color scheme |
| `pictures/mark_animation_home.png`, `mark_animation_home_light.png` | smooth, heron 8 | 3072 x 992 | The tile maps of the animations of the home: see "The moves of the heron" |
| `pictures/mark_animation_icon.png` | cells, heron 1 | 384 x 72 | The tile map of the icon of the tab, in the light scheme |
| `pictures/mark_card.png` | smooth, heron 16, name 12 | 1200 x 630 | The picture for other sites: on the dark background, because those sites show it on white. Open Graph and the page graph name it. The command stops when it is not opaque (a color type with no alpha and no `tRNS` chunk) or not 1200 x 630 |

The pixels of each picture are made by the tool. The page shows each picture of the mark at its own size, and the browser computes no color of the heron:

- The head of the home is a picture: the smooth variant, 8 pixels for a cell. Each pixel has the gradient of its part at its own place. The still picture and the tiles of the tile maps of the home have the same pixels, so the heron does not change when the script starts.
- The bar is a small icon: the cells variant, one pixel for a cell, 24 by 24 pixels, shown at 24 by 24.
- Each size of the rules of the mark is written in pixels, as a count of cells times the pixels of a cell of the still picture of the home, which the table of the uses gives. No size is a percentage or a part of the window. The size is the same at every width of the window: the heron of the home is 192 pixels wide, which a phone of 360 pixels holds.
- The `img` of the home has `width="192"` and `height="192"`, the size of its file: the page keeps the place of the picture before the file arrives.
- On a screen of density 2 or 3 the browser shows a pixel of a picture as a square of 2 or 3 pixels of the screen, with no smoothing: the pictures of the mark and the canvases of the stage have `image-rendering: pixelated`, and the canvases also the older word `crisp-edges`.

The icons of the pages are drawn by the tool from the same table (see "The icons"); the site copies no icon of `resources/logo`. `kerneltool logo` also writes `resources/logo/modus_transparent.png` and `modus_light_transparent.png`, which the README shows in a `<picture>` for the two color schemes.

Which pictures hold the name of the mark:

| Picture | The name | Why |
|---|---|---|
| The head of the home, the bar, the tile maps of the animations | No: the heron alone | The name is text beside the heron, in the font of the name of the mark |
| The icons (`favicon.ico`, `icon.svg`, the icons of the manifest) | No: the heron alone | An icon is too small for the name |
| `pictures/mark_card.png` | Yes | Another site shows this one file, with no page and no font of this site around it |
| `resources/logo/modus*.png`, in the README | Yes | The host of the repository shows a README with no font of the repository: the picture is the one way to show the letters there |
| The picture of a news entry that names a file of `resources/logo` | As the file | A news entry is not changed after its step |

The alt text of the heron of the home is the description of the mark of `README.md`, up to its words about the name under the heron (`site_heron_description`).

### The name of the mark

Where the site shows the name of the system as the mark, the name is text in the font of the name of the mark (`GLOSSARY.md`; `DESIGN.md`, "The font of the name"). The code is `tools/kerneltool/site_mark_name.odin`.

- The places: the bar (after the heron), the foot (before "· by"), and the title of the home (the `h1`, beside the heron). The name in a sentence stays in the reading font: "the documentation of modus" is prose, not the mark.
- The markup, one constant (`SITE_MARK_NAME_HTML`): `<span class="mark-name">modus</span>`. The text is `SITE_SYSTEM_NAME`. It is real text: a reader selects it, a search of the page finds it, and a screen reader says "modus".
- The file: `fonts/modus_mark.ttf`. `kerneltool site` builds it from `support/mark` and `LICENSE`, as `kerneltool logo` does: the bytes of `resources/logo/modus_mark.ttf`. A TrueType file: each browser reads it as it is, and the tool needs no compressor.
- The style sheet declares it once: `@font-face` with the family "modus mark", `format("truetype")`, `font-weight: 100 900` and `font-display: block`. The class `.mark-name` names the family, then the monospace font. It sets `font-weight: 400` and `font-synthesis: none`: the font answers to each weight, so a browser never thickens the squares of a name inside a bold link.
- Each page asks for the font in its head, before it reads the style sheet: `<link rel="preload" href="fonts/modus_mark.ttf" as="font" type="font/ttf" crossorigin>`. The bar shows the name on the first screen of each page. The address of the preload and of the style sheet is the same, with no version.
- No text jumps. The box of the name has the size of the name in cells (`display: inline-block`, a width and a height in pixels, `overflow: hidden`), whatever font draws the text. While the font loads, the text is not shown (`font-display: block`): it never shows in another font first. When the font arrives, nothing beside the name moves. A browser that cannot load the font shows the name in the monospace font in the same box.
- The sizes. One em of the font is 8 cells, so the font size is 8 times the cell:

| Place | Cell | Font size | The name | A cell on a screen of density 1 / 1.5 / 2 |
|---|---|---|---|---|
| The bar, the foot | 2 pixels | 16 pixels | 66 x 14 pixels | 2 / 3 / 4 pixels of the screen |
| The title of the home | 6 pixels | 48 pixels | 198 x 42 pixels | 6 / 9 / 12 pixels of the screen |

- The cell of the home is the cell that the name had in the picture of the home. The cell of the bar is twice the cell of its heron (24 pixels, cells of 1): at cells of 1 pixel the name is 7 pixels high, too small to read.
- A cell is a whole count of pixels of the screen at each whole density, and at 1.5 because both cells are even. At another density (1.25, or a zoom of the browser) the edges of the squares are smoothed.
- The box is 8 cells high: the 7 rows of the name and the row under the baseline. It is moved down by that row (`vertical-align`), so the letters stand on the baseline of the text beside them in the foot.
- The colors: the name takes the color of the text of its place (the link of the bar, the title of the home), and the text color in the foot. In the light form the text color is the dark color of the name of the mark on a light background.
- A page opened from a file: some browsers refuse a font of another folder of the disk. The name is then in the monospace font.
- The host must allow the font: the header `Content-Security-Policy` needs `font-src 'self'` (see "How the site is published"). With `default-src 'none'` and no `font-src`, a browser refuses the font and shows the name in the monospace font.

### The rhythm of the animations

The animations of the mark (`DESIGN.md`, "The animations") play on the large heron of the home and on the icon of its tab. `support/mark` holds the 15 animations as frames of cells, and the rule of the choice and of the still times (`support/mark/play.odin`): the program `heron` of the system plays by the same rule. `mark_animation.js` runs the rule on the page, and `tools/kerneltool/site_mark_schedule.odin` ties the script to it.

The choice of the next animation:

- The script keeps a memory of the animations that were played: one bit for each, and the animation played last.
- The next animation is one of those that the memory does not hold. Each of them has the same chance.
- When the memory holds every animation, the script empties it and starts a new round. In the first choice of a round, the animation played last is left out. So each animation plays once in a round of 15, the order of a round is an order of chance, and no animation follows itself, also from one round to the next.
- The memory lasts for the visit. The script writes it in the storage of the tab (`sessionStorage`, the key `modus.mark.played`) each time an animation starts, and reads it when the home loads. A reader who leaves the home and comes back sees the animations that the round still has, not the same first one. The browser drops the memory when the tab closes: that is its one rule of expiry. A memory of another count of animations is a memory of another build: the script does not use it. A browser that refuses the storage keeps the memory as long as the page.
- The site stores nothing else in the browser, and sends the memory nowhere.

The still times:

- The heron is still for 40 % of a long play, and moves for 60 % (`mark.STILL_SHARE_PERCENT`).
- The mean still time follows from the times of the animations: it is the mean time of an animation, times the still share, over the moving share. `mean still = (sum of the times of the animations / count) × 40 / 60`.
- A still time is a whole number of milliseconds from half the mean to one and a half times the mean. Each number has the same chance, so the mean of the still times is the mean still time.

| | Value |
|---|---|
| The animations | 15, each once in a round |
| The time of the animations of a round | 19.31 s; the mean time of an animation is 1.29 s |
| The mean still time | 858 ms |
| A still time | 429 to 1287 ms |
| A round, on average | 32.2 s: 12.9 s still, 19.3 s of animations |

- A change of an animation changes the still times: the tool computes them from the frames at each build.
- A frame lasts 150 to 1000 ms. The steps of the run of the dash are the one exception: 70 ms each.
- The heron of the bar does not move, on any page. A page of the documentation is read: a picture that moves at the top of a text takes the eye from it. On the home the heron is what the page shows. No other page loads the script.
- Nothing moves for a reader who asks for reduced motion: the script plays nothing, and the style sheet shows the still picture under `prefers-reduced-motion: reduce` also when a script put the stage in the page.
- Nothing runs in a hidden tab. Nothing plays while the focus is in a field (the search): the still picture is back as soon as the reader enters the field, and the play starts again when the focus leaves it.
- With no script the page shows the still picture.
- A press on the heron plays one animation at once (see "A press on the heron").

How the script and the system agree on the rule. The rule is written two times: in Odin in `support/mark/play.odin` (`next_animation`, `still_time`, `play_step`), which the host tests of `support/mark` run and the program `heron` calls, and in the script, which the page runs. One list ties them: the tool runs the rule of `support/mark` with a generator of a fixed seed (`mark.Number_Generator`) and writes its first 33 steps (two rounds and three steps) into the table of the script. The self test of the script (`?selftest=1`) runs the rule of the script with the same generator and compares each step. The generator is the same arithmetic on both sides: `state = state × 1664525 + 1013904223` in 32 bits, and the number is the upper 16 bits modulo the bound. The page itself takes its numbers from `Math.random`.

The tests:

| Test | What it checks |
|---|---|
| `choice_plays_each_animation_once_in_a_round` (`support/mark`) | 400 rounds for each of 5 seeds: each animation once in a round, none follows itself, the rounds do not all have one order |
| `choice_takes_any_number_of_chance` (`support/mark`) | The rule holds for the smallest and the largest numbers of 32 bits, which a program gives from its random generator |
| `choice_goes_on_from_a_kept_memory` (`support/mark`) | A memory with 4 animations played: the 11 others play first, then the memory is emptied |
| `heron_is_still_for_its_share` (`support/mark`) | The bounds of a still time; over 6000 steps of the rule, for each of 4 seeds, the still share is 40 % within one point |
| `generator_wraps_at_32_bits` (`support/mark`) | The numbers of the generator |
| `site_mark_check_steps_follow_the_rule` | The list of the steps does not change from one call to the next, and follows the rule |
| `site_mark_animation_table_parses` | The table of the script: the animations, the moves, the bounds, the list of the steps; the script and the style sheet name the same classes |
| The self test of the script, `?selftest=1` | The table; the rule of the script against the list of the model; a long play of 200 rounds: no animation follows itself, each plays once in a round, the still share is 40 % within one point. The line is in the console and in the attribute `data-mark-animation-self-test` of the root element |

A development aid: `#heron=<name>` at the end of the address of the home plays one animation again and again, with the shortest still time between two plays: `index.html#heron=dash`. The names are those of `DESIGN.md`, "The animations". The memory does not change during that play. A reader who asks for reduced motion still sees no move.

### The moves of the heron

An animation of `support/mark` changes cells. On the home, four animations also move the heron: the dash, the hop, the stretch and the flap. The rule of a move is data of `support/mark` (`DESIGN.md`, "The moves"): the forms of the heron, each drawn in whole cells, and the keys of each move, in whole cells. The site holds no rule of its own: the generator of the pictures of the mark writes the tile maps and their table (`tools/kerneltool/mark_tile_map.odin`).

The rule of the site: a cell of the heron is always a square of 8 pixels of the page at a place of the grid. Each picture and each canvas of the home has 8 pixels for a cell, and the page shows each at its own size (see "The mark on the site"). No transform changes the size of a picture of the heron. A squashed or a stretched heron is a drawing in whole cells that the tool made; a move puts the heron at a whole count of cells from its place: in pixels of the page, a multiple of 8.

- The stage. While the script plays, the still picture is replaced by a stage of the same box, 192 by 192 pixels. It holds one canvas for the two rows of the water, which stays, and one canvas for the heron above the water. A canvas has the pixels of its tiles: 192 by 16 pixels for the water (24 by 2 cells) and 256 by 208 for the heron (32 by 26 cells), and the style sheet shows each at that size. The canvas of the heron is the box of a form: it passes the stage by 6 cells at its left, 2 at its right and 4 above, the room of the widest and of the highest form. It takes no place in the page.
- The drawn forms. The tool draws each form that a move shows, for each frame that plays in that form, into the two tile maps of the home, under the sprites of the frames: 19 drawings, each in a box of 256 by 208 pixels (32 by 26 cells), 12 in a row. A drawing has the gradient of its cells at their place, as a frame has. The script copies one drawing, or the upper part of the sprite of a frame, onto the canvas of the heron, pixel for pixel: a copy has the same size at its source and at its place.
- The steps. For each animation the tool writes the steps of its play: a time, the sprite of a frame, and a drawn form or none. A step starts where a frame starts or where a key gives another form. The script shows the steps; it computes no form. Each step ends at its time from the start of the animation, so the pictures stay in step with the place of the heron.
- The place. The script gives the places of the keys to the animations of the browser (`Element.animate`) as translations of whole cells. From a key to the next one the heron goes cell by cell: the way has as many even steps as it has cells (`steps(n, end)`), so the heron is never between two cells. That is the rule of `mark.move_pose`. A fast way is many cells for each picture of the screen: on a window of 1920 pixels the dash goes more than 10 cells for each picture of a screen of 60 pictures a second.
- No key moves the heron while a foot is in the rows of the water: in such a frame only the form changes, and the column of the standing leg and the line of the water keep their place in every form. `kerneltool site` stops on a table that breaks this rule (`mark.move_keys_fault`).
- The dash, 1780 ms. The heron gathers (26 by 21 cells), then crouches (28 by 19) until 380 ms. With the first step of its run it takes the form of the run (32 by 20, with lines of speed of 10 and 9 cells) and leaves to the right: 4 cells in 70 ms, 10 more in the next 70 ms, then at one speed to a place past the right edge of the window, which it reaches 350 ms after its start. It stays outside for 280 ms. Then it is past the left edge at once, comes in at one speed in 350 ms, and goes 3 cells past its place. It brakes there for 100 ms (20 by 23, a long neck), slides back in 120 ms (22 by 21), rebounds on its legs (26 by 20) and stands.
- "Past an edge" is a place that the script computes from the window, as a whole count of cells: the heron, in its widest form, is outside the window at that side.
- No scroll bar and no layout shift. The stage keeps the box of the picture, and a place is a translation: nothing beside the heron moves. While an animation with a key past an edge plays, the root element has the class `mark-travel`, and the style sheet cuts the page at the sides of the window (`overflow-x: clip`): a heron outside the window adds no width to the page.
- What moves takes no pointer (`pointer-events: none`) and no focus: a press goes to the box of the heron, which does not move. The heron of the dash passes over the tagline and the links of the head for less than 350 ms at each crossing; a click during that time goes to the link under it. The heron passes under the bar: the bar is above it (`z-index`).
- The script sets no style. It sets classes, and it gives the places to the animations of the browser. The header `Content-Security-Policy` of the host (`style-src 'self'`) refuses neither. A browser with no `Element.animate` shows the frames and the forms with the heron in its place.
- The hop: the heron gathers and crouches, is tall in the air (22 by 24), 4 cells up and down again, crouches on the water, rebounds, and stands. The flap: 3 cells up while the wing beats, then a rebound. The stretch: the neck 2 rows longer, then 4 (24 by 26) for 420 ms, then a shake: wide, thin, wide, thin.
- The icon of the tab shows the frames of each animation, with no form and no move. It has a tile map of its own, `mark_animation_icon.png`: the frames in the cells variant, one pixel for a cell, in the colors of the light scheme, as the icon of 32 pixels of `favicon.ico`. The script copies each frame from it into a canvas of 32 by 32 pixels, 4 empty pixels from each edge.
- The host test `site_mark_script_and_style_scale_nothing` refuses a script or a rule of the mark that holds a scale, a matrix, a rotation, a zoom, or a copy of a picture at another size. The host test `site_mark_animation_rules_keep_the_page` checks that each size of the rules of the mark is a count of pixels that the pixels of a cell divide, that no size is a percentage, and that the canvases have no smoothing. The host test `site_mark_animation_sheets_read_back` checks the size of each tile map and that the first tile of a tile map of the home is the still picture of the home, pixel for pixel. The host test `mark_generator_serves_each_kind_of_request` checks the color of each pixel of a tile of the cells variant against `support/mark`. The self test of the script (`?selftest=1`) checks that each number of a key is whole, that the steps of each animation add up to its time and show its frames in their order, and that only a move shows a drawn form.

The tile maps. Each of the three tile maps holds 43 sprites: the still heron and 42 distinct frames, in rows of 16 (`MARK_TILE_MAP_COLUMNS`). In a tile map of the home, one for each color scheme, a sprite is 192 by 192 pixels: the sprites take 3072 x 576 pixels, and under them are the 19 drawn forms in two rows of 208 pixels, so a tile map is 3072 x 992 pixels. The tile map of the icon of the tab is 384 x 72 pixels, with no form. No side is longer than the 8192 pixels that a browser decodes.

The bytes of a tile map. Its pixels are red, green, blue and alpha, 8 bits each, and the file loses none. The generator writes it with the encoder of the Odin standard library at the highest level of its deflate, once with each of its row filters, and keeps the smallest file (`mark_pixels_png`); the pixels are the same in each. `kerneltool site` prints the count of the sprites and the bytes of each tile map and of the script. The script names each tile map with the version of its bytes (`?v=`, see "The versions of the files"): a script never cuts the tile map of another build that a cache kept.

### The icons

The owner asked for it on 2026-11-12: "la favicon faut qu'elle soit bien configurée". The code is `tools/kerneltool/site_icons.odin`.

The heron is pixels: each raster icon is the drawing of `support/mark` at a whole cell size, centred with an even margin, never scaled by a filter.

| File | Size | Cells | Margin | Background | Named by |
|---|---|---|---|---|---|
| `favicon.ico`, at the root | 32 and 48 | 1 and 2 | 4 and 0 | Transparent, the light form | The head, first: `<link rel="icon" href="favicon.ico" sizes="32x32">`; and a browser or a search engine that asks for `/favicon.ico` |
| `pictures/icon.svg` | 24 by 24 cells | One `rect` for each run of cells of one part in a row | 0 | Transparent | The head, second: `type="image/svg+xml"` |
| `pictures/icon_180.png` | 180 | 7 (168) | 6 | Opaque: the dark background, the dark form | The head, third: `apple-touch-icon`, `sizes="180x180"` |
| `pictures/icon_192.png` | 192 | 8 | 0 | Transparent, the light form | The manifest, `"purpose": "any"`; the `icon` of the two feeds |
| `pictures/icon_512.png` | 512 | 21 (504) | 4 | Transparent, the light form | The manifest, `"purpose": "any"` |
| `pictures/icon_512_maskable.png` | 512 | 12 (288) | 112 | Opaque: the dark background, the dark form | The manifest, `"purpose": "maskable"` |

- No icon of 16 pixels: 16 pixels cannot hold the 24 cells of the heron, and the table has no smaller drawing. A browser scales the 32 of `favicon.ico` for a tab of 16 pixels, as it does for most sites. A reduced table would be a new drawing of the mark, which only the owner can decide.
- The tab of a browser is light or dark. A transparent icon takes the light form of the mark: its neck (`0x9FB2C8`) reads on a light and on a dark tab, where the pale neck of the dark form disappears on white.
- The icon of a phone and the maskable icon are opaque, because iOS fills a transparent part and Android cuts the icon to a shape. The maskable drawing fits inside the circle of 80 percent of the icon: its corners are at 203.6 pixels from the centre (144 times the square root of 2), under 204.8.
- `favicon.ico` is the ICO container with PNG entries: a header of 6 bytes, an entry of 16 bytes for each picture (its width and height, 1 plane, 32 bits, its bytes and its offset, little endian), then the PNG files. The tool writes it (`site_ico_encode`) and reads its directory back (`site_ico_read`).
- The SVG icon: each part of the heron is filled with an SVG gradient along the diagonal of its box, in cells (`gradientUnits="userSpaceOnUse"`, from the top left corner of the box to its bottom right corner), whose two ends are the colors that `support/mark` computes at the two ends (a channel `c` is `0.7 c + 76.5` at the start and `0.7 c` at the end). The eye is one flat color. `shape-rendering="crispEdges"` keeps the edges of the cells sharp. The colors in the attributes are those of the light form; a rule `@media (prefers-color-scheme: dark)` in a `<style>` element of the file gives the dark form to the parts whose two forms differ (the neck). A browser that does not apply the rule shows the light form, which reads on both.
- Each link to an icon is relative, as every link of the site: `favicon.ico` from the home, `../../favicon.ico` from a guide. The file is at the root of the site, so the default request `/favicon.ico` finds it when the site is at the root of its domain.

The checks, after the checks of the pages: `favicon.ico` is at the root, its directory reads back (each entry inside the file, a PNG file of the size of its entry) and it has a picture of 32 by 32; each icon of the head of each page and of the manifest is a file that the command wrote, with the size that the page or the manifest states; the icon of a phone and each maskable icon are opaque; the manifest has an icon of 192 and one of 512 for any use, and a maskable one of 512.

## The status page

`status/` gives the state of the system with no sentence of its own but the paragraph that says how to read it. It stays a section of its own, outside the docs (see "The sections"): each cell is a part of `PROPERTIES.md`, of `DEMONSTRATIONS.md` or of `FIRST_MILESTONE.md`.

| Table | Read from, and the form the reader relies on |
|---|---|
| Properties | `PROPERTIES.md`: the number and the title of each section `## <n>. <title>`, and the column "Status" of the table `## Summary` (the reader of the first layer). The title links to the heading in the guide |
| Its evidence items | `FIRST_MILESTONE.md`: the numbered items under `## Evidence`, each a link to its line in the repository (the file is a working record, not a page of the site). An item names a property when its text says `property <n>` (no regard to case) or `P<n>` (a capital P), as a whole word; `properties 3 and 4` names none |
| Its gaps | The items `- <text>` under `## Gaps`, and the lines that continue them (they start with a space), by the same rule. A line of text between the items (`Performance:`) is the group of the items after it |
| Gaps | Each gap, with its number (`gap-<n>` on the page, from 1 in the order of the file, with a link to its line), its group and its text |
| What is planned | No table: one line with a link to the page of the roadmap and the count of its entries. The planned work has one place, `ROADMAP.md` (see "The roadmap") |
| What each property promises, and what runs today | For each property, a section `state-<n>`: its promise, the first sentence of its first rule in `PROPERTIES.md`; then the row of the property in the table `## The table` of `DEMONSTRATIONS.md` (`| <n> | <property> | <state> | <what the test shows> | <pictures> | <what no test shows> |`, the pictures as code spans separated by commas): its state and what the test shows, each picture as a link to `docs/screenshots/<name>.png` in the repository, and what no test shows ("—": nothing); then each numbered item of the section `## What removes ...` that names the property, by the rule of the evidence items. A row with another count of cells stops the command with its line |

Under the heading, a paragraph says what a property, its status and its state are. The page renders `PROPERTIES.md` again to read the ids of its headings: the renderer gives the same ids to the same text, so the links reach the guide. It renders `FIRST_MILESTONE.md` for its numbered items and their lines only, and drops the HTML. The status page has the documentation layout; its property rows and its gap rows are symbols of "On this page".

## The reference tables

Each table is read from the text of the file that defines the thing (`tools/kerneltool/site_source_readers.odin`): the comments of a contract are its documentation, and the compiler drops them. Each row links to its line in the file, at the commit of the build. Under each table, the page names the file. Each reader knows one form; when a file loses it, the command stops with the file and the line.

| Page | Read from | The form |
|---|---|---|
| Kernel operations | `Operation` and `Status` in `contract/operation/operation.odin` | An enumeration: a line `<Name> :: enum <type> {`, one member a line (`<Name> = <decimal>,` or `<Name>,`, with a comment `// ...` or not), a line `}`. A line that is only a comment continues the comment of the member above it. The comment of an operation is `(<parameters>) -> <result>. <text>` or `(<parameters>): <text>`: the parameters and the result exist only as these words, and the table shows them |
| The context of a program | The constants `CONTEXT_...` and `ROOT_...` of `contract/operation/operation.odin` from the line `CONTEXT_HANDLES ::`, and `GRANT_...` of `support/system/grants.odin` | `<NAME> :: <decimal>`, with the comment lines just above it and the comment of its line. `CONTEXT_HANDLES` and `CONTEXT_VALUES` are the sizes, and a name that ends in `_COUNT` is a count: not roles. A name with `_VALUE_` is a value, another a handle. Three tables: the roles that the system fixes for each program, the roles of the first program (`ROOT_...`), and the roles of a program that the root service starts. The page starts with the comment above `CONTEXT_HANDLES` (what the context is, and why a program finds each thing at a fixed place); the comment above `CONTEXT_VALUES` (how the values are numbered) heads the first table |
| Error kinds and units | `Kind`, `Unit` and `UNIT_NAMES` in `contract/errors/errors.odin` | Enumerations; a table `UNIT_NAMES := [Unit]string {` of lines `.<Name> = "<text>",` |
| Grants of the root service | `Grant` in `contract/start_grant/start_grant.odin` (each member has its number: `<Name> = <number>,`); the procedures `grants_of` and `things_of` in `programs/root/main.odin`; `Root_Grant` and `root_grant_names` in `support/system/grants.odin` | Enumerations and a table of names. `grants_of` and `things_of` are read by the parser of Odin (`site_name_switch_read`): the body is a switch on the name, then one `return`, the value of each other program; each case names programs by strings, and its body is one `return` of a literal with no type: a set of members (`{.Inspect, .Image}`) or a record of integer fields (`{pages = 2048, ...}`). The comment of a case is the comment of each of its lines. Any other form (a constant, a typed literal, an expression, a default case, a case with no return) stops the command with its line, and so does a member of a set that `Grant` does not have |
| Fixed ranges | `Fixed_Range` in `contract/fixed_addresses/fixed_addresses.odin` | An enumeration. The address is `fixed_addresses.range_of` of the compiled contract. The page starts with the comment of the package (why an address is fixed, and the band), then the start of the band and the size of a slot from the compiled contract |
| Commands of the console | `programs/console/commands.odin`, `programs/console/tables.odin` | Lines `command("<name>", {.<Kind>, ...}, .<Kind>, "<help>", <procedure>)`; the signature as `help()` prints it, `Value` for the kind None of a parameter. The comment lines just above a line `command(` are the documentation of the command: the text of its symbol, and the first sentence of it is the cell "What it does"; the help is a fact of the symbol, "What help() prints". The page starts with the comment above `Command :: struct` (what a command is, and how commands compose), and the section "The commands of tables" with the comment above `tables_start` |

Each page starts with what the thing is: the comment above its declaration in the source (`site_comment_above`), when the source has one, as a quote that names its file, with its document references (see "The references to documents"). Then the table. A cell that holds a comment of the source (a member of an enumeration, a role, a grant, a range, the comment of a case of the root service) has its document references too.

The kernel operations, the commands of the console, the commands of the tool and the exports of each module are documented symbols (`GLOSSARY.md`), under the table of their page, as on a package page of a programming language. A symbol shows:

- its name, as a heading with its id (`operation-<name>`, `command-<name>`, `tool-command-<name>`, `export-<name>`), which "On this page" lists; the name in the table is a link to it;
- its signature in a block of code: an operation as `Name(<parameters>) -> <result>` from the start of its comment (none when the comment does not start with `(`), a command as `help()` prints it, a command of the tool as `nix develop -c kerneltool <name>`, an export as the console prints it;
- the text of its source comment, as Markdown (see "The Markdown of a source comment"), then its document references; nothing when the source has none;
- its facts: the number of an operation and the statuses that its comment names (links to the table of statuses); the parameters and the result of a command; the parameters, the result and the error record of an export (the rule of the build: it fails with a negative result and writes the record);
- its source line, a link to `<repository>/blob/<commit>/<file>#L<line>`.

The command prints the count of the symbols and of those with no comment in their source (each `entry` of a module has none: the build gives it no text). The rows of the other tables that have an id (a status, an error kind, a unit, a role, a grant, a fixed range, a license, a measured number, a property, a gap) state a symbol too (`data-outline`), so "On this page" lists them.

What the tables cannot show:

- The values 13 and 15 of the context (the settings page and the date page) have a comment in `contract/operation` and no constant: they are not in the table.
- A heading comment inside an enumeration shows under the member before it: the form cannot tell it from a comment that continues. The kernel operations have none: the text of each operation is under its own member.
- The limits of processor time and of log records of a program come from `budget_of`, a computation: the page names it and does not show its values.

## The module pages

`docs/reference/modules/` lists each module of `module_builds` (`tools/kerneltool/modules.odin`) in its group, one table and one heading for each: Kernel (a module that runs in kernel mode), Programs (its source is in `programs/`), Modules (the others). The documentation tree has the same groups. A row gives its name, whether it is in the boot image, its count of exports, its imports and its purpose. `docs/reference/modules/<name>/` gives:

- its documentation: the comment before `package` in its source, the text that the build writes into the module (`describe_package` of `tools/kerneltool/describe.odin`), then its document references; its purpose is the first sentence, with no pointer;
- for a module that is a build of the source of another module with settings of its own (`defines` of its row of `module_builds`), a first paragraph before the documentation: "The module `kernel` built with the setting `TEST_BUILD_SKIPS_THE_INSTRUCTION_ADDRESS_CHECK=true`", then the comment above its row in `module_builds`, which says why it exists. The documentation after it is the comment of the shared source, which describes the other module. Its description for other sites names its source and its settings;
- its source folder, its size in the boot image of the last build (or that the image is not built), its build settings (the `defines` of its row, or "none"), its imports and the modules that import it;
- its kind (its group);
- its exports, a table then each one as a documented symbol (see "The reference tables"), each with its signature as the console prints it (`write(name: Text, data: Text) -> Integer`, `Handle(Read, Write)`, `Table(Rectangle, Change)`) and its line of help. They come from the same reader as the build: no module needs to be built;
- for a program, its grants and its budget (pages, programs, threads) from `grants_of` and `things_of` of the root service, with the comments of those lines: each grant a link to its row on the page of the grants, each field of the budget its name and its value, both lists of values;
- its identity card (`GLOSSARY.md`), after its documentation: the same markup as on the page of the module graph (see "The module graph");
- its neighbours, after its facts: a figure of the module, the modules that it imports at its left and the modules that import it at its right, drawn by the layout of the module graph on that part of the graph. The module itself is not a link. A module with no edge has one sentence, with a link to its row on the page of the graph.

The index of the modules links to the page of the module graph.

## The module graph

The owner asked for it on 2026-11-12: "et on a de quoi faire du déboggage de modules ? (et pourquoi pas un outil de visualisation des \"dépendances\"/carte d'identité module(s) ?". The code is `tools/kerneltool/site_module_graph.odin`; its host tests are `site_module_graph_test.odin`. The same facts for what runs now are `manual.edges()` (`MODULE_CONTRACT.md`, "Replacement of an import").

`docs/reference/module-graph/` draws the module graph (`GLOSSARY.md`) of the build. The reference index, the card of the reference of the docs home and the tree list it after the modules, and the index of the modules links to it.

### What a node and an edge are

- A node is a module of `module_builds`: each module and each program, the kernel and its test build too. A resource of the boot image is not a module: it imports nothing and no module imports it, so it is not a node.
- An edge is an import of `module_builds`: the build writes the hash of the imported module into the import table of the importer, and a loader puts the imported module in the program of the importer. The direction is "A imports B".
- An edge is not a library of `contract` or `support`: the build compiles it into each module, and no import names it. It is not a module that a program loads by its name (the console with `load`, the program `imports` with its own loader), not a connection to a service, and not a replacement: the machine decides a replacement when a program starts, and the build does not know it.
- Imports are hashes, so the files of a build cannot hold a cycle, and `module_builds` lists each module after its imports. The layout still refuses a cycle, an import that names no module of the build, a module that imports itself and an import named twice: the command stops before any page with the reason (`site_reference_read`).

### The layout

`site_graph_layout` places every node and every edge in whole pixels, with no randomness and no clock: the same build gives the same picture, byte for byte.

- The layer of a node is the depth of its imports: 0 for a module that imports nothing, else one more than the deepest of its imports. A layer is a column; the layer 0 is at the left. So each importer is at the right of each module that it imports, and a program is at the right of its imports.
- A node with no edge is not in a layer: it is in the band under the layers, by kind (the kernel, the programs, the modules with no entry), then in the order of the build, in 2 columns, column by column. Most nodes of today have no edge: the band keeps the layers small.
- In a layer, the nodes start in the order of the build. One pass from the left orders each layer by the mean place of the imports of its nodes; one pass from the right orders each layer by the mean place of their importers. A mean is a whole number in 1024ths of a row. A node with no such neighbour keeps its place, and two equal means keep their order. There is no other step against crossings.
- A node is a rectangle of 16 pixels high, the bar, as long as the bytes of the module: 96 pixels for the largest module, 4 for the smallest, in proportion between. The name is at the right of the bar, whole, in the monospace font at 12 pixels. A column is as wide as the longest bar and the longest name, at 8 pixels for each character: no name is cut, and no name runs into the next column in a monospace font that advances up to 0.66 em.
- The size and the hash come from the boot image of the last build; a module that is not in the image (the kernel, the test modules) takes them from its module file in `build/modules`. A module that is not built has an empty bar and no hash.
- An edge is three straight segments: from the left end of the bar of the importer across to the gap at the right of the column of the imported module, then up or down, then across to the end of its name. Each edge has a lane of its own in that gap, 6 pixels apart, in the order of the place of the imported module, then of the importer; the gap is at least 48 pixels and grows with its lanes. An edge over more than one layer passes over the row of its importer in the columns between: no node of today has such an edge.
- The color of a node is its kind, the kinds of the card of the boot image: a program (a module with an entry) in the color of a program, a module with no entry in the color of `COLOR_NO_ENTRY`, the kernel in the color of the kernel. Each color is a variable of the style sheet in each form, with a shade in the light form; a host test checks a contrast of 3 to 1 on the background and on the two colors of a card.
- Each column has a heading in the dim color: "depth 0: imports none", "depth 1", ...; the band has "no edge: imports none, imported by none (N)".

The command prints the count of the nodes, of the edges, the depth, the count of the nodes with no edge, and the modules with no entry that no module imports. The page lists them too. Such a module is not dead by itself: a program can load it by its name, or a replacement can put it in place of an import. The list is for a reader to check.

### The page

- The picture is an inline `<svg>` with its `width`, `height` and `viewBox` in pixels, in a box that scrolls sideways (`.graph-box`, a region that the keyboard reaches, as a table box): the picture keeps its pixels, so a name is never smaller than 12 pixels. No color, no style and no font is an attribute: the style sheet gives them by class.
- Each node is a link to the page of its module (`<a>` of SVG), with the name, the kind and the size as its `aria-label`. Each line has `data-from` and `data-to`; each node has `data-card` (the id of its identity card) and `data-neighbours` (the names of the other ends of its edges, which the tool computes).
- Under the picture, its legend: the color of each kind, what a line is, what a bar is.
- The identity cards: one for each module, in one box (`#graph-cards`) with the attribute `hidden`.
- Then the table "The edges": each module, its kind, what it imports and what imports it, each name a link to its page. It is the whole graph for a reader with no picture and for a screen reader.
- Then the modules with no entry that no module imports.

With no script the page is whole: the picture, its links, its legend and the table. The cards stay hidden.

With the script (`module_graph.js`, loaded with `defer` by this page only, `Site_Page.script`):

- A pointer on a node, or the focus of the keyboard, marks the node, its neighbours and its edges: the other nodes and edges take a quarter of their opacity, and a marked edge takes the color and the width of the line of a link. Nothing moves.
- The identity card of the node shows in a box fixed at the bottom right of the window, 384 pixels wide. The script takes away the attribute `hidden` of the box and of the one card; a style is never set.
- The pointer that leaves the node (when the node has no focus), the focus that leaves it, or Escape, takes the marks away and hides the card. A click opens the page of the module.
- With `?selftest=1` in the address, the script checks each node: the other ends of its lines are the names of `data-neighbours`, and its card exists. It prints "module graph self test: N of N nodes agree" in the console of the browser, and sets the same line as the attribute `data-module-graph-self-test` of the root element. The host test `site_graph_markup` checks that the tool writes the neighbours of each node from its edges.

### The identity card

The identity card (`GLOSSARY.md`) of a module: its name (a link to its page, but on its own page), its kind, its hash (64 hexadecimal digits), its size, the count of its exports (the entry is not counted), of its imports and of the modules that import it, its license, and the first sentence of its documentation with no reference. Its license: the license of the system, then each row of the licenses whose place is in the source folder of the module (the portrait of `temple`), each a link to its row on the page of the licenses. One procedure writes it on the page of the graph and on the page of the module (`site_module_card_write`); one procedure gathers its facts (`site_module_card_of`).

## The references to documents

The owner asked for it on 2026-11-12, of the page of a module that started with "The kernel (docs/ARCHITECTURE.md, systems K1 to K5).": "ça devrait pas etre genre un \"tag\" ou une \"référence\" ? genre un lien, affiché avec un style pour architecture.md ? je comprends pas ce texte en fait. K1 to K5 ?". The code is `tools/kerneltool/site_document_references.odin`; its host tests are `site_document_references_test.odin`.

A comment of the source names a document for a person who reads the code: a document pointer (`GLOSSARY.md`). The rule of the comments allows it. On a page, the path and a label such as "U3" or "section 8" mean nothing: the site writes a document reference (`GLOSSARY.md`) in its place.

### The forms of a pointer

`site_document_pointers` reads each `docs/<NAME>.md` of a text (capital letters, digits and `_`; not a part of a longer path or word), then the labels after it:

| Form | Example | What the pointer takes |
|---|---|---|
| A whole parenthesis | `(docs/ARCHITECTURE.md, "Kernel systems")` | The parenthesis and the space before it |
| A part of a parenthesis, after other words and ", " | `(support/cryptography/origin.manifest, docs/CRYPTOGRAPHY.md)` | ", " and the part: `(support/cryptography/origin.manifest)` stays |
| A part of a parenthesis, after or before "; " | `(property 19; docs/MODULE_CONTRACT.md, sections 4 and 5)` | The part and one "; " |
| After "see" | `..., see docs/DESIGN.md, section 3.` | "see", the path and the labels, and ", " before them |
| A word of its sentence | `The colors of docs/DESIGN.md: a name is dim.` | The path and the labels after it |

- The labels of a part of a parenthesis are its parts after the path, split at ", " outside quotes: `"Did not fit, across calls"` is one label.
- After a path in running text, a label follows ", ": a heading in quotes, `section <n>`, `sections <n> and <m>`, `property <n>`, `choice <n>`, `decision <n>`, `item <n>`, or a label that starts with a capital letter (`U3`, `K1`, `D-163`). A bare number after a comma is a word of the sentence.
- The first three forms are asides. A path of the last form is a word of its sentence.

### The place that a pointer names

`site_document_targets` finds the place of each label, in the order of the labels; each label after the first looks inside the part of the heading of the label before it (`"Kernel events", section 5a`).

- A heading in quotes: the heading whose text gives the same id by the rule of the ids (`site_slug`), with or without the label of its section ("11. The mark" for `"The mark"`); else the one heading whose text starts with those words.
- `section <n>`, `property <n>`, a label as `U3` and the identifier of a decision (`D-163`): the first heading whose text starts with the label and then ". " or a space ("12. The interface font" for 12; "12.4 The glyph cache" for 12.4, not for 12).
- `choice <n>`, `decision <n>`, `item <n>`: the one top-level item of an ordered list with that number, inside the part of the heading "Choices ..." or "Decisions ..." when the document has one. The reference shows its words in bold, else its first sentence.
- A quoted label that no heading has, as the last label: the words in bold at the start of a line (`- **The frame caches** ...`) of the part. The reference shows them and links to the heading above them.
- `sections 4 and 5`: two references.
- The glossary: a quoted label is first a term: its entry, at the anchor `term-<name>` on the page of its group; else the heading of a group: the page of the group.

A pointer whose labels do not all find their place names the document alone: the reference shows the title, never the label, and the command counts the pointer as not resolved. A path that names no document of `docs/` is not a pointer: its text stays.

The headings of a guide are those of its rendered page, with their ids: `site_guides_add` renders every guide once for its headings and its items before it writes any page, so a guide refers to a guide after it. A working record (`SITE_WORKING_RECORDS`) is not a page: its reference links to the line of the heading or the item in the file at the commit, and says "in the repository". An intent file (`GLOSSARY.md`, "Intent file") is a working record by its path: a pointer names it by its whole path from the root, `src/md/features/palette.md`, because its file name alone can be the name of another file. A pointer to an intent file that the folder does not have stops the command.

### The markup, and where the references go

A reference is `<a class="document-reference value-guide value-icon" href="...">Architecture: Kernel systems</a>`: the title of the document (the `#` heading of the file), then ": " and the text of the heading without the label of its section. It takes the color and the icon of the value kind Guide (see "The kinds of values"), in the reading font: the name of a document is a name, not a value.

One form for every page: the text of the comment, then one line "See:" with the references of its asides, each once. In a paragraph form (a description, a symbol, the quote at the start of a reference page) the line is a paragraph `<p class="document-references">`; in a cell of a table it is a `<span>` after the text. Why: a reference inside a sentence breaks it, as the parenthesis did, and several references in one paragraph are hard to tell apart; after the text, the sentence reads as one ("The kernel: ... the interrupts."), and the reader finds the documents of a text in one place. The text on the two sides of an aside joins: no space before a period, and no "()". A path that is a word of its sentence ("the rules of docs/DESIGN.md") is the one exception: the sentence needs it, so its reference takes its place.

`site_source_comment` writes every source comment that a page shows, as Markdown (see "The Markdown of a source comment"): the description of a module, the text of each symbol (an operation, a command of the console or of the tool, an export, a type), the comment above a declaration, and each cell of a reference table that holds a comment. A summary (the purpose of a module in the index, the first column of a table of exports or commands, the description of a page, the text of an entry of the search, the first line of a type card) has no reference: `site_source_comment_plain` takes the asides out, a path that is a word of its sentence becomes the title of its document, and the marks of Markdown go. The page of the thing shows the whole text with its references.

A code span of a guide, of the glossary or of a news entry that names a document is a reference of the same markup (see "The Markdown that the site renders"): one look for a reference to a document on every page.

### The count and the check

The command prints "N document references, M with no heading found: <the first three>": N is the count of the different pointers of the pages and of the code spans of the guides that name a document, M those whose labels found no place.

Before it writes a page, the command checks every pointer, also those of a comment that no page shows: each comment of each source file of `kernel`, `programs`, `modules`, `support`, `contract`, `runtime` and `boot` (the lines of comment that follow each other are one text), and each code span that names a document in the guides, the glossary, the news, `FIRST_MILESTONE.md` and the intent files. In an intent file, a link to a guide with the heading of a place after it is a pointer too (`TOOLS.md`, "The intent folder"). A pointer whose labels do not all find their place stops the command, with its file and its line: a stale pointer or a label that names no heading (a free text) cannot come back. The tool is not read: its tests hold stale pointers on purpose. The target of a link `[text](docs/X.md#id)` is not a pointer; the same pass checks each link of the comments (see "The links of a comment"). A guide names no working record of `docs/` and no decision; it can name an intent file, which holds the reasons of a design. A working record names a decision by its identifier (`DECISIONS.md`, D-163), which is a label.

The owner asked for the check of the pages on 2026-11-13: "il reste des références là, par exemple docs/TOOLS.md. Alors, soit on met une référence vers quelque chose de réel, soit on met un lien, soit on l'enlève, mais on peut pas laisser ça comme ça." Before it writes a page, the command reads the text of each page, outside a link, a code element, a block of code, a script and a style, and stops on a name of a document there (`site_document_name_problem`), with the page and the words around the name. A name of a document is `docs/<NAME>.md` (by its form, also when no such file exists), or `<NAME>.md` for a guide, a working record, `README.md`, `CHANGELOG.md` or `AGENTS.md` (`site_document_names`), as a whole word: a `/` can come before it (`news/README.md`), a letter, a digit or a period cannot. An attribute is not text. No text is an exception: a document that a page names is a reference, a link or code. The form of each source: in a guide, a code span (`` `DESIGN.md`, section 5 ``), also in a cell of a table, which the renderer writes as prose; in a source comment, the pointer `(docs/DESIGN.md, section 5)`; in the text of a command of the tool, a code span, which the page of the commands writes as code in its table and as a link to the file under it. The host test `site_document_names_are_never_bare` holds the cases.

## The Markdown of a source comment

The owner asked for it on 2026-11-13: "I suppose you extract text from the code BUT it lacks emphasis (bold, italics, lists, shit like that) and makes the paragraphs displayed in the docs look very plain and boring to read. we could use markdown for this (and have []() references to symbols and stuff if that's not already done". The code is `tools/kerneltool/comment_markdown.odin`, `site_comment_links.odin` and the mode for comments of `site_render.odin`; the host tests are `comment_markdown_test.odin`. The reader of the same part for the programs of the system is `support/source_comment_markdown` (see "The reader of the system"). `docs/TOOLS.md`, "The form of a documented comment", is the rule for the author of a comment.

A source comment is Markdown in a small part, written by the renderer of the guides (`Site_Renderer.comment`): one renderer, and a mode that refuses what a comment does not have.

| Construct | In a comment | Why |
|---|---|---|
| Paragraphs, joined lines, an empty line `//` between two | Yes | |
| Bold, italics, code spans | Yes | A code span takes the path of the code spans of the guides: a row of a reference table, a file, a declaration, a fragment of Odin. A comment names no folder around its spans |
| Lists `- ` and `1. `, nested by two spaces | Yes | A line right after an item continues it, as the comment wraps where its width ends. An item of a comment has no id |
| A fence with `odin` or no language | Colored as Odin | The comment is in an Odin source. A fence of another language is plain |
| Lines that start with a space, outside a list | A block of code, not colored | The form that the documentation of a module keeps; these lines are often words aligned in columns |
| Links `[text](target)` | Yes, to a place of the site (see "The links of a comment") | |
| Headings, tables, quotes, lines of HTML, pictures | No: words of a paragraph | A comment sits under the heading of its symbol, in a page or in a cell of a table: a heading would break "On this page", and a table does not fit a cell |
| Terms of the glossary | Only as a link `term:` | Each comment of a page is rendered alone: the rule "the first use on the page" would link each term in each comment |

In a cell of a table (`.Line`), a comment of one paragraph is one line with no `<p>`, as before; a comment with a list or an example writes its blocks in the cell. A comment with no mark renders as before. The summary of a comment (`site_source_comment_plain`: the purpose of a module, the description of a page, the text of an entry of the search, the first line of a card) has no mark and no link.

The readers of the reference tables keep the lines of a comment: a line `//` alone is an empty line, and the indentation after `// ` stays (`markdown_comment_line`). The form of an operation, `(parameters) -> result.`, is on the line of its member and can run over two lines; its text is the Markdown after it.

### The links of a comment

A code span that names a thing links to it by itself: it stays the usual form of a name. `[text](target)` is for a link whose text is not the name. The target (`site_comment_link_target`):

| Target | Example | What it names |
|---|---|---|
| An address of another host | `https://www.rfc-editor.org/rfc/rfc8439` | That address |
| `term:` and a term | `term:handle` | The entry of the term on the page of its group of the glossary, by its name with no regard to case, from the terms that the reader of the glossary gives: a link of the class `term`, with its short definition as its `title`, as a term that a guide links |
| A guide, or its heading by the id of the heading | `docs/ARCHITECTURE.md#the-fault-ring` | The page of the guide, at that heading. A working record is not a page: it is refused |
| A name of a row | `Memory_Map`, `No_Grant`, `math`, `load()` | The row, by the rule of the code spans |
| A module and its export | `manual.edges` | The export on the page of its module |
| A declaration | `fault_deliver`, `operation.Fault_Record`, `system.word_wait` | The declaration, with its card; a type of the contract opens its type card. A name that several packages declare, or a common word, takes its package |

There is no short form `[name]`: the code span is that form.

The check: before it writes a page, the command reads every comment of the sources, as it does for the pointers (see "The count and the check"), and stops on a link whose target names nothing, with its file and its line, outside the code spans. A link is a claim of its author; a code span that names nothing is not.

### The text that a module carries

The documentation of a module is the same comments (`describe_package`). The module carries each comment as its author wrote it, with its marks, in the form of `contract/module/format.odin`, `Documentation`. The one line of a module and the help of an export are the first sentence of the comment with the marks removed (`documentation_text_of_markdown`, `about_of`): the console prints that line, so it has no mark. The description keeps the Markdown too (`Module_Description.markdown`, `Export_Description.markdown`): the site renders it.

### The reader of the system

The part of Markdown of a comment has two readers, and one rule: the table of this section. The site has the renderer of the guides in its mode for comments. The programs of the system have `support/source_comment_markdown`: a library with no allocator, which the program `manual` uses for the documentation text of a module.

The library reads the text once and gives it in order, as Markdown blocks and Markdown spans (`GLOSSARY.md`), to two procedures of its caller (`read`) or into two tables of its caller (`read_into_table`). A block and a span are ranges of bytes of the text: nothing is copied.

| Part | What the library gives |
|---|---|
| A paragraph | One block; its spans are its words with their styles. A line feed inside a span is one space |
| A list item | One block with its mark (`-`, or the label of a number) and its depth; a line right after it continues it |
| A fenced block | One block with the word after its opening fence; each span is one line, as it is. Inside a list item, the lines lose the indentation of the fence |
| An example | One block; each span is one line with no shared indentation |
| Bold, italics, a code span | A style of a span. A span can have several |
| A link | The spans of its text have the style of a link and the range of its target |
| A heading, a table, a quote, a line of HTML, a picture | Words of a paragraph, as on the site |

The host tests of the library (`source_comment_markdown_test.odin`) read the inputs of the tests of the site (`comment_markdown_test.odin`) and expect the same structure. The two readers differ in four cases, all outside the form that `TOOLS.md` gives to an author:

- A mark of two stars with no end is text in the library, with its stars. The site makes the rest of the paragraph bold.
- The target of a link can hold pairs of parentheses in the library (`load()`), and has at most 256 bytes. On the site a target ends at its first `)`.
- The text of a link has its italics in the library. On the site it has its bold and its code only.
- A fenced block inside a list item is at its place in the library: the text of the item after it is a paragraph inside the item. The site writes all the text of the item, then its blocks.

The text of a module can come from a file that another party wrote. The library checks each index against the length of the text. Its work is in proportion to the length of the text: a search for the end of a mark does not read the same bytes again for each mark that has no end.

What `manual` does with the blocks and the spans:

- The words of a documentation text are in the interface font, and the bold words in its bold weight. A code span, a fenced block and an example are in the font of the cells, in the color of code (`DESIGN.md`, section 5: a text that explains, and a text that a reader copies).
- The system has no italic face. A word in italics has a line of 1 pixel under it, in the dim color: the color of the word does not change, so the sign is not a color alone.
- A list item has its mark in the dim color, and its text starts after the mark. An item inside an item is 2 cells to the right.
- A fenced block and an example have a band behind their rows, from their indentation to the end of the text.
- A link is a name in the color of a link. A link whose target is a module of the boot image, or a module and one of its exports (`manual.show`), also has a line of 1 pixel under it: a click on it shows the page of that module, from the signature of that export. A term, a guide, a declaration and a kernel operation have no page in the system: their links are colored names only.
- A row is broken between two words, at the width of the text, with the width of each word in the font that draws it. Two spans with no space between them, as a bold word and the comma after it, are one word. Only a word that is longer than a row is cut. A text longer than the window scrolls.
- When the font setting changes, `manual` makes the rows of its page again, at the same place: the widths of the words changed.

When it starts, `manual` checks the page of its own module, whose comments have each mark, and writes one line on the log: "manual: the Markdown of its page: bold, italics, code, list items and links that open a page; no mark is left and no row passes the window: as it must". The machine test waits for it.

## The types

The owner asked for it on 2026-11-12: "Si c'était possible sur les différents data types, d'avoir un tool type qui explique le type. Genre sa carte d'identité, sa taille, des informations techniques. Sa taille, son alignement, les trucs normaux qu'on aimerait savoir quand on vient sur cette doc." The code is `tools/kerneltool/site_types.odin`; its host tests are `site_types_test.odin`.

### What a type card holds

Each type has a type card (`GLOSSARY.md`). The facts come from the compiler, never from a number typed by hand: the tool imports the contract packages, and `type_info_of(T)` gives the size, the alignment, each field with its name, type and offset, each member of an enum with its value, the element and the underlying type of a bit set, the base of a distinct type, and the variants of a union. The declaration (its source text), its comment and its line come from the parser of Odin (`core:odin/parser`), as the descriptions of the modules do.

| Kind | Rows | The card |
|---|---|---|
| Struct | Each type of `contract/operation`, `contract/errors`, `contract/fixed_addresses`, `contract/module`, `contract/start_grant` (`SITE_TYPE_PACKAGES`) | Size, alignment, the padding in all; a table of the fields (name, type, offset, size) with a row "padding" for each run of unused bytes; the sizes of the rows add up to the size |
| Enum | The same packages | Its base type; a table of the members, with each value in decimal and in hexadecimal (a negative value as the bytes of its base hold it) |
| Bit set | The same packages; each one of the contract is an alias | Its enum, its underlying type, the type that the alias names; a table of the bits and their masks |
| Distinct | The same packages | Its base |
| Wire form (`GLOSSARY.md`) | The members of `Type` of `contract/module` but None | The comment of the member in `contract/module/format.odin`; one register of a call (`PARAMETER_CAPACITY`); the types of the module contract that the comment names (`Table_Place`, `Function`); for Handle, the size of `Handle` in a record; a link to the guide of the module contract. A fact that only the guide states is not copied |
| Record of a module | Each record of `Module_Description.records` of each module | The size and the offsets of the description that the build writes; the size of a field from its wire form (an Integer of its detail, 8 for 0; a Handle of `size_of(Handle)`; a Text of its detail); the alignment is the largest of its fields |
| Basic | `u8` to `i64`, `int`, `bool`, `rawptr`, `uintptr`, `string`, `[]u8` (`site_basic_types`) | Its size and alignment, and one line of what it is |

Each card also says where the type is named: the types whose fields, base or element it is, the kernel operations whose words name it, the modules whose exports take or give it, and the commands of the console.

### The table and its check

`site_contract_type_rows` holds one row for each type of the documented packages: its package, its name and its type information, `{"operation", "Rights", type_info_of(op.Rights)}`. The name is stated in the row because the bit sets of the contract are aliases (`Rights :: bit_set[Right; u32]`): the type information of an alias is the type that it names, with no name. The contract is not changed for the site. `kerneltool site` reads each declaration of a type of those packages with the parser (`Name :: struct`, `enum`, `bit_set`, `union`, `distinct`, `bit_field`, or an array type) and stops when:

- a declaration has no row: a new type of the contract cannot be forgotten;
- a row names no declaration, or a type has two rows, or a row has no type information;
- a row whose type is named has another name or package than the compiler gives it: a wrong row of a named type is caught. The row of an alias is checked against the declarations only.

An alias has the kind of what it names (a bit set), and its card says "An alias of `bit_set[Right; u32]`". A field whose type is that bit set finds the card of the alias.

A type that a page shows and that has no card (an array as `[16]u8`, the kind `Value` of the console, a record that the description does not hold) is written as a value of the kind Type with no reference, and the command prints the count: "N type names with no card".

The host test `site_types_table_is_complete` runs the same check on the repository.

### The machine of the tool and the target

The tool is built for the host; the system for x86-64 with no operating system. Each type of the five packages has the same layout on both today: an address, `int` and `uintptr` are 8 bytes on x86-64 and on a host of 64 bits, and the rules of a struct of Odin are the same (each field at a multiple of its alignment, the size a multiple of the largest alignment). Two things keep this true:

- A size that the contract asserts (`#assert(size_of(Fault_Record) == 64)`) is checked when the tool is built and when the system is built. The host test `site_types_sizes_agree_with_the_asserts` reads each assert with a number in the four packages and compares it with the card.
- A type that holds an address, a slice, a string, `int` or `uintptr` says so on its card, with the machine that made the page (`ODIN_OS_STRING`, `ODIN_ARCH_STRING`): `Parameter_Form` and `Operation_Form` (a string), `Bound_Import` (a slice of bytes and a `uintptr`). Its size follows the size of an address of the target.

### The reference and its card

One procedure, `site_type_reference`, writes a type wherever a page shows it:

- the signature of each kernel operation (each word of its comment that names a type of the package operation), of each export (the wire form and the record, from the description, not from the text of the signature), and of each command of the console (each kind that is a wire form);
- the facts of each export and command (parameters, result, error record), and the columns "Parameters" and "Result" of the table of the operations;
- on the page of the types: the type of each field, the base, the element, and the types that a wire form names.

The markup: `<button type="button" class="type-reference" popovertarget="card-<id>" popovertargetaction="show" aria-describedby="card-<id>-summary">Name</button>`. The card is `<div class="type-card" id="card-<id>" popover>`: the name as a link to the page of the types, a first line (the kind, the size, the alignment, the padding, the first sentence of the comment), at most 8 fields, members or bits, then "and N more", and the note of the target. A page holds the card of each type that it names once, at the end of its text, in the order of the first reference (`site_type_cards_html`); every reference to that type on the page opens it.

Why this form:

- A card inside the reference, shown by `:hover` and `:focus`, is cut by the box of a table that scrolls (`overflow-x: auto`), and a touch screen has no hover.
- A card placed by the script with `position: fixed` needs the script for its content.
- A popover is in the top layer, so no box cuts it. A click, a tap, Enter or Space opens it with no script; Escape and a click outside close it. `popovertargetaction="show"` keeps an open card open at a second click.
- On a touch screen, a tap opens the card, and a tap on its title goes to the page of the types.
- `search.js` adds the rest: a mouse that rests 400 ms on a reference opens its card, which closes 300 ms after the mouse leaves the reference and the card; the focus of the keyboard (`:focus-visible`) opens it and the focus that goes to another element closes it. With no script, a click is needed.
- A screen reader reads the first line of the card with the button (`aria-describedby`): the summary is in the page, also when the card is closed.
- With anchor positioning (`position-area`), the card is under its reference and flips above it near the bottom of the window. A browser with no anchor positioning puts it in the middle of the window, the default place of a popover. A browser with no popover shows the cards as a list at the end of the text.

The check of each page (`site_type_cards_problem`): each `popovertarget`, each `data-declaration-card` and each `aria-describedby` names an id of the page, and no two cards of a type or of a declaration have one id.

A code span of a guide, of a news entry or of a source comment that names a type of the contract is a reference to its card, through the declaration index (see "The declarations of the sources").

## The colors of the code

The owner asked for it on 2026-11-12: "Un peu dommage aussi qu'on ait pas de coloration du code, peut-être avec Shiki, on peut, parce que là je vois du Odin qui est pas coloré." The code is `tools/kerneltool/site_code.odin`; its host tests are `site_code_test.odin`. The colors of the classes are the table of the colors of code of the system (`support/graphics/code_colors.odin`, `docs/DESIGN.md`, section 4), which the terminal of the system reads too: a type has one color on the site and in the console.

The tool colors the code when it writes the pages: static markup, no script, no request, nothing new in the Content-Security-Policy. Not Shiki: it is a library of Node, and the automation of the repository is commands of the Odin tool, with no script of another language. Odin is read by the tokenizer of the compiler itself (`core:odin/tokenizer`), not by a grammar of regular expressions: a token is what the compiler sees.

- `site_code_odin` writes each token in a `<span class="c-<class>">`, and each byte between two tokens (spaces, line feeds) as it is: the text of the output with its tags removed and its escapes undone is the source, byte for byte. The tokenizer gives the comments as tokens. Two tokens of one class with only spaces between share one span.
- A text that the tokenizer refuses (an illegal character, a string or a comment with no end) is written plain, and `kerneltool site` prints "N code blocks not colored, the first: <place>". A fragment that is not a declaration is still tokens and is colored: the tokenizer does not parse.

| Class | What | Accent of the design rules | Dark: shade, contrast on the block of code `0x1C2633` | Light: shade, contrast on the block of code `0xD6DBE0` |
|---|---|---|---|---|
| `c-k` | A keyword of the tokenizer | Kernel | 115 %, `0x64AAF2`, 6.24 | 55 %, `0x285583`, 5.55 |
| `c-t` | A built-in type; a name with a capital in the place of a type; a reference to a card, in a block of code | Firmware | 115 %, `0x9E8FCB`, 5.27 | 60 %, `0x554A75`, 5.75 |
| `c-l` | A number, a string, a rune, `true`, `false`, `nil`, a name in capitals, `.Member`, a member of an enum body | Memory | 100 %, `0x38C0B0`, 6.79 | 50 %, `0x1B5F57`, 5.34 |
| `c-n` | A name before `::`: the name at its declaration | Program | 100 %, `0x58D878`, 8.37 | 45 %, `0x276035`, 5.36 |
| `c-d` | `#` and the name after it, `@` and the first name of its attribute, a file tag | Machine | 115 %, `0xD785BB`, 5.79 | 55 %, `0x723D60`, 5.90 |
| `c-c` | A comment | Dim | 125 %, `0x9CA6B2`, 6.19 | 60 %, `0x4A525B`, 5.69 |
| `c-p` | An operator or punctuation: the quiet class | Dim | 140 %, `0xB0B8C1`, 7.62 | 50 %, `0x3D444C`, 7.08 |

A host test computes each contrast; the bound is 4.5, as for the value kinds. A person who prints gets black text.

The rule for the names of types, from the tokens only:

- a name of the package of the text (the package of a declaration of the page of the types) that is a type of the contract, and `package.Name` of a documented package anywhere, is a reference to its card (see "The types");
- a built-in type (`u64`, `bool`, `string`, `rawptr`, ...) is `c-t`;
- another name with a capital is `c-t` only in the place of a type: after `:` (not `::`), `^`, `]`, `->` or `distinct`, or after `qualifier.` in that place. Elsewhere (`size_of(Pair)`, `in Kinds`) it stays plain: the tool does not guess.

Where it applies: only a block that the tool knows to be Odin.

- The declaration of each type on the page of the types, with each type of the contract inside it as a reference: this closes "the declaration has no references inside it".
- The signatures of the kernel operations, of the exports and of the commands of the console: they are built from their parts, so each part takes its class with no tokenizer: the name `c-n`, the punctuation and the arrow `c-p`, each type a reference. The parameters of an operation are words of a comment, and stay plain.
- The fenced blocks of the guides marked `odin`. A block with no language stays plain: the language is not guessed.
- A code span of a text that is a fragment of Odin by the test of "The declarations of the sources": a span is short, and the test refuses each form of a command, a path and a log, so a span is colored only when it can be nothing but code.

The fenced blocks of `docs/*.md` on 2026-11-12: 15 blocks; 9 with no language, 5 `mermaid`, 1 `odin`. No block is marked `asm`, `sh`, `console`, `nix` or `yaml`, so the tool has no other lexer: a lexer for a language that no block names is code with no use. The 5 mermaid blocks stay plain, as before. The one block of Odin (`MODULE_CONTRACT.md`, the export `seal`) is colored.

The size: the declarations of the page of the types are 963 lines, 53 KB of text, about 7 900 tokens; their spans and references add about 100 KB to that page (estimated, not measured). The guide of the module contract grows by about 1.5 KB; the other guides do not change.

## The declarations of the sources

The owner asked for it on 2026-11-12, of a paragraph of a guide with code spans that name procedures and files and hold an expression: "dans ce genre de texte, ce serait cool d'avoir des références vers les fonctions/symboles/etc mentionnées + de la coloration syntactique, meme dans les inline snippets, si possible". The code is `tools/kerneltool/site_declarations.odin`; its host tests are `site_declarations_test.odin`.

### The declaration index

`kerneltool site` reads the declaration index (`GLOSSARY.md`) before it renders any guide (`site_declarations_read`): each source file of `kernel`, `boot`, `contract`, `support`, `modules` and `programs` (`SITE_DECLARATION_FOLDERS`; not the tests and not the tool), with the parser of Odin (`core:odin/parser`), as the types and the exports are read. Each declaration at the top of a file, and inside a `when` there, gives one entry:

- its name, its package (the name after `package`), its folder, its file and its line;
- its kind, from its value: a mutable declaration is a global variable; a procedure literal or a group of procedures is a procedure; a type expression (`struct`, `enum`, `union`, `bit_set`, `distinct`, an array, a pointer...) is a type; a name with a capital and lowercase letters given another name is an alias of a type; any other value is a constant;
- its one line of Odin: the text of the declaration up to the body of a procedure, or up to the first `{` of another value, which becomes `{...}`; its tokens with no comment and single spaces; the line is whole, and it wraps in the card;
- the first sentence of its comment (the comment above it, or the comment of its line).

The tree of the parser of each file lives in an arena of its own, freed before the next file. A file that the parser refuses is counted, and the command names the first one; it does not stop: the build of the system checks its sources.

### What a code span names

The code spans of the guides, the glossary, the news entries and the source comments (the descriptions of the modules, the text of each symbol, each cell of a reference table that holds a comment) take one path, after the document references, the rows of the reference tables and the files of the repository. A code span of a heading stays code.

1. A span whose whole text is a name (`blend_coverage_row_in_order`), `name()`, `package.name` or `package.name()` is looked for in the index. A file name with a known extension (`boot.image`, `flake.nix`), a keyword and a built-in type are not names. A span `value.field` whose first part is no package of the index is a field, not a name: it goes to the next step.
2. The resolution (`site_declaration_resolve`): the declarations with that name; with `package.`, those of that package (its name or the last part of its folder); with `()`, the procedures. If one of them is in a folder that the text around the span names (the heading of level 2, the heading of level 3, the paragraph: `support/graphics`, or a file under it as `support/graphics/blend.odin`), that one. Else, when one declaration is left, that one; but a common word (lowercase letters only: `count`, `build`) needs `package.`, `()` or a folder of the text. Else the span stays code, and is counted as ambiguous. A source comment names no folder around its spans.
3. A span that is not a name and that is a fragment of Odin is colored by the tokenizer and the classes of the blocks of code (`site_code_odin`), in a `<code class="code-inline">`. Each name in it that the index resolves by the same rule is a link, with no card: the link is enough inside an expression. A name of fewer than 3 letters is a local of the example (`a`, `d`) and does not link.
4. Any other span stays code.

The test of a fragment of Odin (`site_code_span_is_odin`) leaves a span plain when it is unsure. It refuses:

- a text that the tokenizer refuses, or of one token;
- a command of a shell: its first word is a known command (`kerneltool`, `nix`, `git`, `odin`, `qemu-system-x86_64`, `cd`, ...), or it has `--`, `$`, `\` or `~/`, or it starts with `./` or `/`;
- a path: a `/` with no space on either side; a file name: a name, a period and a known extension;
- a setting of a command or of the environment: an `=` with no space on either side (`NAME=true`);
- a line of a log or of prose: two names or values side by side with no operator between (`test return_fault`, `1031293 us`), or two labels `name: ` in one span (`kernel: boot: firmware`);
- names joined by operators alone (`Ctrl+C`, `a + b`): a fragment holds one part that only code has: a keyword, a literal, a bracket, `:`, `::`, `->`, `^`, a period between names, `..<`, `<<`, `>>`, `==`, `=`, `#` or `@`.

What stays plain: commands of the shell and of the tool, paths and file names, settings `NAME=value`, lines of a log, key names and their combinations, single words that are not a declaration, a single number, an expression of names and `+` or `-` alone, and a text with a comment or a backslash.

### The markup

- A declaration that is a type of the contract is the reference to its type card (see "The types"), as a value of the kind Type.
- Another declaration: `<a class="declaration-reference" href="..." data-declaration-card="declaration-<n>" aria-describedby="declaration-<n>-summary"><code class="value value-procedure value-icon">name</code></a>`: a link in the color and with the icon of its value kind (procedure, type, constant, global variable; see "The kinds of values"). The link goes to the page of its module when it is an export of a module of the build (`#export-<name>`), else to its line in the repository at the commit of the build.
- A name inside a fragment: `<a class="declaration-link" href="...">`, in the class of its token.
- The declaration card (`GLOSSARY.md`): `<div class="declaration-card" id="declaration-<n>" popover>`: the name as the link, with the icon of its kind; its kind and its package; its one line of Odin, colored; the first sentence of its comment (`id="declaration-<n>-summary"`), or "A procedure with no comment in its source."; its file and line as a link. A page holds the card of each declaration that it links to once, at the end of its text, in the order of the first link (`site_declaration_cards_html`); the type cards come after the declaration cards are known, because a one line of Odin can name a type of the contract (`site_cards_html`).
- The script opens a card as it opens a type card: a mouse that rests 400 ms on the link, or the focus of the keyboard; it closes 300 ms after the pointer leaves the link and the card. With no script the link works and no card opens; a browser with no popover shows the cards as a list at the end of the text.

### The size

A card is written once in each page that links to its declaration, as the type cards are; the cards do not come from a file that the script loads at the first hover. The bytes, estimated from the counts of the guides (not measured; the command prints the bytes of the pages):

- `ARCHITECTURE.md` has 1545 code spans, 714 of them different, 574 of the form of a name. If 40 % of those link: about 230 cards of about 750 bytes (the address of the repository at the commit twice, the colored line, the sentence), 170 KB, and about 600 links of about 260 bytes instead of 25, 140 KB. Its page grows from about 260 KB to about 570 KB, before compression; the addresses repeat, and the compression of the host takes most of them.
- The page of the types (about 780 KB, the largest page) shows the comments of the contract: 61 code spans, most of them common words that stay code. It grows by a few KB and stays the largest page.
- A file of cards for the whole index would hold every declaration of the sources (several thousand), whatever the page; a file for each page is one more request and one more script path. So the cards are in the page, as the type cards.

If a measure shows a guide too heavy, the first saving is the address of the repository in the card (the title links to the same line as the place).

### The count

The command prints the declarations of the index by kind, the files that the parser refused, then "N code spans name a declaration and link to it, M are ambiguous, K name no declaration", with the first five spans of the last two and their files: a stale name in a guide is then seen. A span that names no declaration does not stop the command: many spans are words of a log, of a command or of a field. A document that a page renders again (the status page renders `PROPERTIES.md` and `FIRST_MILESTONE.md` for their ids) is not counted twice, and the first pass over the guides, for their headings, is not counted.

## The polish of the browser's parts

The owner asked for it on 2026-11-12: "si tu peux styliser les scroll-bars, s'il te plaît, ce serait cool. Tu as tous les trucs de peaufinage en CSS là que tu peux mettre, genre la couleur de highlight, enfin tout ce bordel." In the design of the system: square, the colors of the palette, both color schemes, and nothing more. The rules are `SITE_POLISH_RULES` in `tools/kerneltool/site_style.odin`, after the colors, so that print and the forced colors win over them.

- Scroll bars: see "The scroll bars". `scrollbar-gutter: stable` on the page.
- `color-scheme: dark light` on the root; each page already has `<meta name="color-scheme" content="dark light">`.
- `::selection`: the line color at 70 % (`0x2B5688`) under white text, 7.53 to 1, the same in both schemes (a host test). It is one rule for every element, so it holds in the blocks of code and on the values.
- `accent-color` and `caret-color`: the line color. The placeholder of the search: the dim color at 115 % in the dark form (5.40 on the field; the dim color itself is 4.33), the dim color of the light form there (5.69).
- The focus: a square outline of 2 pixels in the line color, offset 2 pixels, on links, buttons, summaries, fields and each element with `tabindex` (the table boxes). No rule removes an outline (a host test).
- The marks of the lists: a square, in the dim color; the marks of a `summary` in the dim color. The bar menu has its own button and no mark.
- `text-wrap: balance` on the headings and `pretty` on the paragraphs, the items, the definitions and the quotes; `tab-size: 4` in code; the links keep their thickness and offset. `hanging-punctuation` is not written: one browser has it, and it moves the first letter of a quote.
- No `scroll-behavior: smooth`: a link to an anchor, and a page loaded with an anchor, go there at once.
- The bar of the site stays at the top of the window on every page (`position: sticky`), with a fixed height of 41 pixels (`--bar-height`). The column "On this page" starts under it. On a narrow screen the open menu scrolls on its own under the bar.
- The jump to an anchor: `scroll-margin-top` of each target is the height of the bar and 16 pixels, so the bar does not hide the target. The page has no `scroll-padding-top`: with one, a browser takes the search field of the bar as hidden and scrolls the page at each key. A heading, an item or a paragraph that is the target has a line of 2 pixels at its left; a row of a table has the band of the track. No fade: the design rules have no animation.
- `overscroll-behavior: contain` on the tree, "On this page" and the open menu; `touch-action: manipulation` on links, buttons and summaries; the tap highlight in the line color at 30 %; `text-size-adjust: 100%`.
- `image-rendering: pixelated` on the mark of the home and the heron of the bar (already); the icons of the values are masks drawn at their size. The screen pictures are not pixelated: they are shown smaller than their pixels.
- The card of a type and the card of a declaration have no veil: `::backdrop` is transparent; a card is not a modal.
- Forced colors (`@media (forced-colors: active)`): the icons of the values in `CanvasText`, the marks of the values in `CanvasText`, the focus in `Highlight`, the border of a card in `CanvasText`.
- Print: black text, no color of code or of a value, no card of a type, a block of code wraps.

A host test checks that the style sheet holds each of these rules, has no `outline: none` and no `outline: 0`, and that each `border-radius` is 0.

### The scroll bars

The scroll bars of the site are the scroll bar of the system (`DESIGN.md`, "The scroll bar"), written from the same table: `support/graphics/scroll_bar.odin` holds the sizes, the stops of each gradient and the colors of the dark and of the light form. The system draws from it; the kernel tool writes the variables of the style sheet from it. A change of a number of the table changes both. The rules are `SITE_SCROLL_RULES` and `site_scroll_variables` in `tools/kerneltool/site_style.odin`. They apply to every part that scrolls: the page, the tree, "On this page", the table boxes, the blocks of code, the open menu, the list of the search, the cards of the types and of the declarations, and the row of the carousel of the home.

The form, 17 pixels wide, all rectangular:

- At each end an arrow button of 17 by 17 pixels with a solid triangle of four rows (1, 3, 5 and 7 pixels), on the gradient of the track. With the pointer over it: the blue border, the blue fill and the light triangle. While it is pressed: the stronger blue fill.
- The track: a gradient across it of three stops (0, 50 and 100 %), with a border of 1 pixel at its two long sides.
- The thumb: a border of 1 pixel; a gradient across it of four stops (0, 45, 55 and 100 %); an inner line of 1 pixel inside the border, white at 12 % in the dark form and at 40 % in the light form (an inset shadow); in its middle a grip of four lines of 7 by 1 pixels, 1 pixel apart. With the pointer over it: the blue border, the blue fill and the light grip. While it is dragged: the stronger blue fill. A thumb is at least 21 pixels long: a style sheet cannot remove the grip of a short thumb, and the system draws a grip only on a thumb longer than 20 pixels.
- The corner where two bars meet: the middle color of the track.

What differs from the scroll bar of the system, because a style sheet cannot say it:

- The system lights the whole bar when the pointer is over any part of it. A style sheet reaches a part only under the pointer: on the site the thumb is blue when the pointer is over the thumb, and a button when the pointer is over that button. An arrow button of the site has no "lit" state between rest and hot.
- The system draws the inner line as an opaque color. The site gives the browser a translucent white, which the browser blends: the same pixels.
- The least length of the thumb is 21 pixels on the site; in the system it is 8 % of the track, and 8 pixels at least.

The rules hold no size and no color. `site_scroll_variables` writes, for each form, from the table: the sizes (`--scroll-thickness: 17px`, `--scroll-border: 1px`, `--scroll-thumb-least: 21px`); the flat colors (the borders, the middle of the track); the inner line; each gradient in both directions (`to right` for a vertical bar, `to bottom` for a horizontal one) for the track, the thumb at rest, hot and pressed, and an arrow button hot and pressed. A data address cannot read a variable of the style sheet: the procedure writes each triangle (4 directions) and each grip (2 directions), at rest and with the pointer, as a data address in the colors of each form, through `site_svg_data_address`: 12 addresses for each form. The colors of the scroll bar do not come from the colors of the page: the dark form of the site has the colors of the system, and the light form has the light colors of the table.

What each engine shows:

| Engine | Means | What it shows |
|---|---|---|
| Chromium (Chrome, Edge) and WebKit (Safari) | `::-webkit-scrollbar`, `-button:single-button` with `:vertical`/`:horizontal` and `:decrement`/`:increment`, `-track`, `-thumb` with `:hover` and `:active`, `-corner`, inside `@supports selector(::-webkit-scrollbar)` | The whole form: the arrow buttons, the track, the thumb with its gradient, its inner line and its grip, the colors with the pointer and while a part is pressed |
| Gecko (Firefox) | `scrollbar-color` (the border color of the thumb at rest on the middle color of the track) and `scrollbar-width: auto`, inside `@supports not selector(::-webkit-scrollbar)` | Two flat colors only. It loses the arrow buttons of the form, each gradient, each border, the inner line, the grip and the blue tones: the operating system of the reader draws the form of the bar and its own color under the pointer |

Chromium, since version 121, draws the standard scroll bar of an element that has `scrollbar-color` or `scrollbar-width`, and ignores the parts `::-webkit-scrollbar` of that element. So the two standard properties are written only for an engine with no such parts: each engine takes its own rules. A Chromium that does not accept a pseudo-element in `@supports selector()` takes the standard colors, which is correct.

The host test `site_style_sheet_scroll_bars` checks: the rules of both engines; the two standard properties written once, inside the test of the engines with no parts of WebKit; no color, no gradient and no size in pixels in the rules themselves; the variables of both forms with the numbers of the table (the sizes, the gradients of the track, of the thumb and of an arrow button); in each form, 12 data addresses, each an SVG picture with no character that ends the address and one color of the scroll bars of its form; the rectangles of a triangle and of a grip; a contrast of 3 to 1 of each part that the pointer lights: the blue border on the track, a triangle on the track and on the fill of its button, the light grip on the blue thumb. At rest the form is quiet: the border of the thumb has 2.1 to 1 on the track (2.5 in the light form) and the grip 1.7 to 1 on the thumb (2.7). The test prints these two as a measure.

## The tiles of the boot image

The home shows one tile for each module of `build/boot.image`: the width from the size of the module (5 rows of 1088 pixels for all, at least 48 pixels), the color from the first byte of its hash (`graphics.hue_color`). Each tile links to its module page. The colors and the widths are rules of the style sheet, because the pages hold no inline style. When the image is not built, the tiles are the modules of `module_builds` that it holds, with no size and no color, and the home says so.

## Not done yet

The work is in layers; each layer adds pages to a site that works.

- (a) Done: the pages, the bar, the transparent mark, the renderer, the guides; also the tables of the licenses.
- (b) Done: the status page, the reference tables generated from the code, the module pages, the tiles of the boot image on the home, the links from the code spans of the guides to the rows.
- The metadata for other sites goes into the head of `site_page_html`, which writes every page.
- (c) Done: the news (`news/`, `kerneltool news`), its page, its door on the home, its feed and its links from the releases.
- (d) Done: the search: its index, its script, its box in the bar.
- (e) Done: what other sites read (`tools/kerneltool/site_metadata.odin`): the canonical address, Open Graph, the summary card, the page graph, the manifest, `sitemap.xml`, `robots.txt`, `releases.xml`, `llms.txt`, the pictures of the repository compressed, and their checks. See "What other sites read".
- Done: the module graph, the identity card and the neighbours of each module (see "The module graph").
- (f) Done: one section Docs in the bar, the guides and the reference under `docs/`, the docs home with its own search field, and the redirect pages of the two generations of old addresses. See "The sections", "The redirect pages" and "The docs home".
- The count of checks of `kerneltool check` on the site: the measure record counts the checks of `kerneltool screenshots` only (the machine tests and the second build), not the host tests of `kerneltool check`.
- An embedded font for the text: Paper Mono is under the SIL OFL 1.1 with no Reserved Font Name (`resources/fonts/paper_mono.license`): its ASCII subsets can be copied into the site with `OFL.txt` and their `.license` files and declared with `@font-face`. The site uses the fonts of the reader's system for its text; its one font file is the font of the name of the mark.

## How the site is published

The owner chose it on 2026-11-12: "pour la publication du site je préfère un workflow GitHub évidemment". The site is at `https://modus.froment.software/` (`SITE_ADDRESS` in `tools/kerneltool/site_frame.odin`). `kerneltool site --address https://<host>/<path>` writes it for another address for one run (see "What other sites read").

The site workflow (`GLOSSARY.md`), `.github/workflows/site.yml`, runs at each push to `master` and by hand (`workflow_dispatch`). It holds no logic: each step calls the tool or an action, and each action is pinned by a version tag.

| Job | Step | What it does |
|---|---|---|
| build | `actions/checkout@v7.0.1` | The repository at the pushed commit, with its `.git`: `HEAD` is the commit, which the foot of each page names |
| build | `DeterminateSystems/nix-installer-action@v23` | Nix, for the flake and its FlakeHub inputs |
| build | `DeterminateSystems/magic-nix-cache-action@v15` | The store paths of the development shell, kept in the cache of GitHub Actions between runs |
| build | `nix develop -c kerneltool build` | The modules and `build/boot.image` |
| build | `nix develop -c kerneltool site` | The site in `build/site`; a failed check stops the run, and the site of the last run stays online |
| build | `actions/upload-pages-artifact@v5.0.0` | `build/site` as the artifact of GitHub Pages |
| deploy | `actions/deploy-pages@v5.0.1` | The artifact online, in the environment `github-pages` |

- The permissions: `contents: read`, `pages: write`, `id-token: write` (the deployment proves its run to GitHub Pages with a token of the run).
- `concurrency: pages`, not cancelled: two runs do not deploy at the same time, and a deployment that started ends.
- The wrapper `kerneltool` of the flake makes `build/` before it runs the tool.

What a clean checkout gives to `kerneltool site`:

| What the site reads | Made by | In the workflow |
|---|---|---|
| The documents, the news, the changelog, the code that the reference tables read, `flake.nix`, `flake.lock`, `LICENSE`, the pictures of `docs/screenshots` and `resources/logo`, the films of `docs/films` | Committed | Read |
| The pictures of the mark, the module pages and their signatures | The code of the tool (`support/mark`, `describe_package`); no module is built | Written |
| The commit | `.git` | Read |
| `build/boot.image` | `kerneltool build` | Written by the step before: the tiles of the home with their sizes and colors, the size of each module in its page, and the column "in the boot image" of the licenses. With no image these show the modules with no size, and "not recorded" |
| The measure record, `docs/measures/measures.txt` | `kerneltool screenshots` | Committed: the measured numbers, the second build and the stages of the start of the last full check, with its date, its commit and its host |
| The logs of the machine tests, `build/test_output*.txt` | `kerneltool test`, `kerneltool measure` | Absent: the site reads the measure record. With no record, each number says "Not measured.", and so does the start of the machine on the home. The command does not fail |
| `build/reproducible_build.txt` | `kerneltool check`, `kerneltool screenshots` | Absent: the line of the measure record |

The time of the step `kerneltool build` on a runner of GitHub is not measured yet: the first run gives it.

The domain:

- The custom domain is a setting of the repository (Settings, Pages: the source "GitHub Actions", the custom domain `modus.froment.software`, "Enforce HTTPS"). With a deployment of an artifact, GitHub Pages ignores a `CNAME` file: the site has none.
- The record at Cloudflare: `modus.froment.software`, a `CNAME` to `sachahjkl.github.io`, through the proxy of Cloudflare (the owner accepted the proxy). Not verified here: GitHub Pages makes the certificate of a custom domain only when its check of the record sees GitHub, and the proxy hides it. The usual order: the record with no proxy until GitHub shows "Enforce HTTPS", then the proxy, with the TLS mode "Full (strict)" of Cloudflare.
- The branch `gh-pages` that served the first version by hand is no longer read once the source is "GitHub Actions".

The headers: GitHub Pages sends no header that a site chooses. The proxy of Cloudflare adds these to each answer for the host `modus.froment.software` (a rule that changes the headers of the response):

| Header | Value | Why |
|---|---|---|
| `Content-Security-Policy` | `default-src 'none'; style-src 'self'; img-src 'self' data:; media-src 'self'; font-src 'self'; script-src 'self'; connect-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'` | The style sheet, the pictures and the grid of points (`data:`), the films of the news (`media-src`), the font of the name of the mark (`font-src`), `search.js` and its fetch of `search.json`, the manifest; nothing else. The page graph is data that a browser does not run: `script-src` does not apply to it |
| `X-Content-Type-Options` | `nosniff` | A file is read as its type only |
| `Referrer-Policy` | `strict-origin-when-cross-origin` | Another host sees the host of the site, not the page |
| `X-Frame-Options` | `DENY` | `frame-ancestors` for a browser that does not read it |
| `Strict-Transport-Security` | `max-age=31536000` | The site is read over TLS only; no `includeSubDomains`, because the other hosts of the domain are not this site |
| `Permissions-Policy` | `camera=(), microphone=(), geolocation=()` | The site uses none of them |
| `Cross-Origin-Opener-Policy` | `same-origin` | A page of another host that opens the site gets no handle on its window |

A `<meta>` policy is not written: `frame-ancestors` has no effect there, and `'self'` does not work for a page opened from a file. The types of the files are those of GitHub Pages, from their extensions: `application/xml` for the two feeds, which feed readers read.

## What the owner must decide

1. Done: the measured numbers of the site online come from the measure record (see "The measure record").
2. The cache of the workflow: the cache of GitHub Actions (`magic-nix-cache-action`, now) or FlakeHub Cache (`flakehub-cache-action`, which needs a FlakeHub account for the repository).
3. The name in the title of `README.md` and in the `description` of `flake.nix`: both say "Next-Gen Kernel", the name of the project before `modus`. The site does not read either (it reads the lead of `README.md`). Not changed here.
