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
  - each `srcset` candidate names a file that the command wrote;
  - no page holds code or style of its own: each `<script>` has a `src` and nothing inside, but the one `<script type="application/ld+json">` of the page graph, whose text has no `<`; no `<style>` element and no `style` attribute exists.
- Then the command checks what other programs read (see "What other sites read"); a failure stops it in the same way.
- After the checks of the pages, the command makes the index of the search and checks it against the pages (see "The search"); a failure stops it in the same way.
- At its end the command prints: the pages and their bytes, the other files, the entries and the bytes of the index of the search and the bytes of the script, the guides, the news entries, the terms of the glossary, the commit and the release, the numbers that are not measured, the cells of the licenses that are not recorded, each part of a guide that the renderer did not understand, the parts that it did not write with no site address (or, with one, the parts that it wrote), and the count of the pictures of the repository that it compressed, with their bytes before and after.
- `kerneltool check` runs the host tests of the site (`tools/kerneltool/site_test.odin`, `site_render_test.odin`) and checks that each picture that `README.md` names is a file of the repository. It does not write the site.

## The pages

| Page | Generated from |
|---|---|
| `index.html`, the home | The mark (`support/mark`), the first sentence of the first paragraph of `README.md` as the tagline of the head, the three newest news entries, the rest of that paragraph in a section "What it is" after the news (the owner, 2026-11-12: "la tagline est trop longue"; after the news, so that the first screen of a phone holds the mark, the name, the tagline and the links only; the description of the home in its head, Open Graph, the manifest and the page graph stays the whole paragraph, cut at 160 bytes, because the tagline alone is too short to describe the system), the stages of the start from the lines `kernel: boot: ...` of `build/test_output.txt`, the tiles of the boot image (see "The tiles of the boot image"), the first three measured numbers, the pictures of `docs/screenshots` with the captions of `README.md`, the newest release of `CHANGELOG.md`, the count of steps of `docs/REVIEWS.md` |
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
| `releases.xml` | The feed of the releases, from `CHANGELOG.md`; see "What other sites read" |
| `site.webmanifest`, `llms.txt` | The name, the colors and the icons of the site; the pages with their descriptions in Markdown |
| `sitemap.xml`, `robots.txt` | Only with a site address; see "What other sites read" |
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
- Two things keep the script in step with the console. The tool writes the constants of `support/line_editor` (the points of each rule, the bounds) into the script. And one table of queries, names, scores and orders, `site_search_match_names` and `site_search_match_orders` in `tools/kerneltool/site_search.odin`, is run twice: by the host test `site_search_matcher_table` over the matcher of Odin, and by the script over its own matcher when the address of a page has `?selftest=1` (it prints one line in the console of the browser, "search self test: N of N cases pass" or the first case that fails, when the script runs during the load and again when the list opens; the same line is the attribute `data-search-self-test` of the root element and the first words under the box). A change of the rule in Odin fails the host test until the table has the new scores; the new table then fails the self test of the script until the script has the new rule. No program of the repository runs the script: the self test is run in a browser.

### The look

The box and the list are those of the console (the picture `docs/screenshots/console_completion.png`):

- The box is at the right of the bar, in the place of the clock of the bar of the desktop. `/` puts the focus in it when the focus is not in a field.
- Under the box, a line says how many entries match and how many are not shown, and the keys; then at most 8 rows, the best first; then the text of the chosen row. A row is the title with the matched characters in the accent color (`COLOR_BOOT_PROGRAM`, at half its light in the light form) and, at its right in the dim color, its kind and the title of its page. The chosen row has the band of the track and the blue line at its left.
- Up and Down choose a row, Enter opens it, Escape closes the list (a second Escape leaves the box). A click opens a row.
- The query is in the address as `?q=<query>`, so that a search can be linked: a page opened with `?q=` opens the list.
- The keyboard alone works. The box is a `combobox` with `aria-expanded`, `aria-controls` and `aria-activedescendant`; the list is a `listbox` of `option` rows with `aria-selected`; the line of the count is `aria-live`. The focus is visible.

With no script, the site is whole: every page is reachable by its links, and the box is not shown (it has the attribute `hidden`, and only the script takes it away).

## What other sites read

The owner asked for it on 2026-11-12: "we'll want a sitemap, json-ld, good seo (graph) etc". The structure follows a site of the owner that has these parts; no fact of that site is copied here. The code is `tools/kerneltool/site_metadata.odin`; its host tests are `site_metadata_test.odin`, with a site address and with none.

A canonical address, an address of Open Graph and an `@id` of JSON-LD must be absolute: a relative one is wrong for the program that receives it. So each part that needs one is written only with a site address (`GLOSSARY.md`), and the command lists the parts that it did not write.

| Part | With no site address | With a site address |
|---|---|---|
| `lang`, the viewport, the title, the description, a theme color for each color scheme, the icons (`favicon.ico`, the SVG icon and the icon of a phone; see "The icons"), the manifest, the links to the two feeds, `rel=prev` and `rel=next` between guides (the reading order of the page of the guides) | Written | Written |
| The canonical address (`GLOSSARY.md`) | No | `<site address>/<path>`; an index page by its folder (`<site address>/guides/`) |
| Open Graph: `og:type` (`article` for a guide, else `website`), `og:site_name`, `og:title`, `og:description`, `og:url`, `og:image` with its type, width, height and alt; `twitter:card` `summary_large_image`, which reads the rest from Open Graph | No | Written; the picture is `pictures/mark_card.png` |
| The page graph (`GLOSSARY.md`) | No | One `<script type="application/ld+json">` in the head |
| `sitemap.xml`, `robots.txt` | Not written | Written |
| `news.xml`, `releases.xml`, `llms.txt` | Relative links, no link `self` | Absolute links, a link `self` in each feed |

### The page graph

One `@graph` for each page, built from the data that the page shows; no value is typed for the graph. Each node has an `@id`; a field names another node as `{"@id": ...}`. The text goes through the JSON writer of the search index (`site_json_string`), which escapes `<`, `>`, `&`, U+2028 and U+2029: a title as `</script><!--` stays a text of the JSON, and the script element has no `<` inside.

| Node | Id | On | Fields |
|---|---|---|---|
| `WebSite` | `<site address>/#website` | Each page | `name`, `url`, `description` (of the home), `inLanguage`, `about` the system, `potentialAction`: a `SearchAction` with the `EntryPoint` `<site address>/?q={search_term_string}` and `query-input`, the form that the script of the search reads |
| `SoftwareApplication` | `#system` | Each page | `name`, `url`, `description`, `applicationCategory` "Operating system", `operatingSystem` "None: it is the operating system of the machine", `processorRequirements` "x86-64", `availableOnDevice` "QEMU on x86-64, with UEFI firmware and virtio devices" (`PROPERTIES.md`: the first machine), `softwareVersion` (the newest release), `license`, `image` |
| `SoftwareSourceCode` | `#source` | Each page | `name`, `codeRepository`, `programmingLanguage` (a `ComputerLanguage`, Odin), `license` (`https://spdx.org/licenses/<identifier>.html`, from line 1 of `LICENSE`), `version`, `targetProduct` the system |
| `ImageObject` | `#card` | Each page | The picture for other sites: `url`, `contentUrl`, `width`, `height`, `caption` |
| `ImageObject` | The address of the picture | A page that shows pictures | One for each `img` of the content of the page, read from the element itself: `contentUrl`, `width`, `height`, `caption` (its alt text) |
| `WebPage`, or `CollectionPage` for an index | `<canonical address>#page` | Each page | `url`, `name`, `description`, `inLanguage`, `isPartOf` the site, `primaryImageOfPage` the card, `breadcrumb`, `mainEntity`, `image` the pictures that it shows |
| `BreadcrumbList` | `#breadcrumb` | Each page below the home | A `ListItem` for each crumb of the line above the content, then the page |
| `TechArticle` | `#article` | A guide | `headline` (at most 110 bytes), `description`, `inLanguage`, `url`, `mainEntityOfPage`, `isPartOf`, `about`, `image`. No `dateModified` and no `datePublished`: the tool does not read the history of a document, and a false date is worse than none |
| `DefinedTermSet`, `DefinedTerm` | `#terms`; a term by its anchor `#term-<name>` | The glossary | Each term with its `name`, its definition as `description`, its `url` and `inDefinedTermSet` |
| `ItemList` | `#modules` | The index of the modules | `numberOfItems`, a `ListItem` for each module page with its `position`, `name` and `url` |
| `Blog`, `BlogPosting` | `#blog`; an entry by its anchor `#news-<file>` | The news | A `BlogPosting` for each entry: `headline`, `description` (its first sentence), `url`, `inLanguage`, `datePublished` and `dateModified` (the date of its head: an entry is never updated), `articleSection` (its kind), `isPartOf`, `mainEntityOfPage`, `about`, `image` (its picture, else the card) |

`BlogPosting`, not `NewsArticle`: a news entry is a dated report of the project, as a post of a blog. `NewsArticle` is for the articles of a publisher of news, and a search engine reads it as journalism.

Not verified against a validator of schema.org or the documents of a search engine, since this work runs with no network: the field `availableOnDevice` of `SoftwareApplication`; whether a search engine accepts a free text "Operating system" for `applicationCategory` (its list of categories has no operating system); whether the `SearchAction` is still read (one search engine stopped showing a box of search for it in 2024); the limit of 110 characters of a headline. The author (owner, 2026-11-12: "pour l'auteur du site évidemment tu peux mettre"): a `Person` node, `<site address>/#author`, on each page. Its `name` is the holder of the line `Copyright` of `LICENSE` (the words after `(c)` and the years), the one fact of an author that the repository holds; its `url` is the account that owns the repository (`SITE_REPOSITORY_ADDRESS` without its last part). It is the `author` of the `SoftwareApplication`, the `SoftwareSourceCode`, each `TechArticle` and each `BlogPosting`, and the `publisher` of the `WebSite`. Each page has `<meta name="author">`, also with no site address, and the two feeds name it in `<author>`. When `LICENSE` names no holder, there is no `Person`, no field names one, and the feeds name the system.

### The sitemap, robots.txt and the feeds

- `sitemap.xml` lists the canonical address of each page that the command writes, once, by path. A page has a `lastmod` only when the tool knows the date of its last change: `news.html` (the date of its newest entry) and `releases.html` (the date of its newest release). The other pages have none: each build changes their foot, and the tool does not read the history of their sources. A wrong `lastmod` teaches a search engine to ignore the field.
- `robots.txt` allows each page and gives the address of the sitemap. A crawler reads `robots.txt` only at the root of a host: when the site address has a path, the command says that the `robots.txt` of the root must have the line `Sitemap:`.
- `releases.xml` is the feed of the releases (Atom): one entry for each release of `CHANGELOG.md`, newest first, with its date (`published` and `updated`, at 00:00 UTC), its first change as its summary, and its changes in HTML. The id of an entry is `<repository>/blob/master/CHANGELOG.md#release-<number>`: a release is never renamed, so the id does not change when the site gets an address.
- `llms.txt` follows the form of llmstxt.org, as the site of the owner has one: the name, the lead of `README.md` as a quote, then a list of the pages for each section, each with its title and its description; the module pages are in the part `## Optional`.
- `site.webmanifest`: the name, the description (the whole first paragraph of `README.md`, cut at 160 bytes), `lang`, `start_url` and `scope` `./` (the root of the site, where the manifest is), the dark background as the background and theme color, and three icons: 192 and 512 with `"purpose": "any"`, and 512 with `"purpose": "maskable"`. Its addresses are relative to it.

### The pictures

Each `img` has `width`, `height` and an alt text (a check of the pages). The pictures below the first screen have `loading="lazy"` and `decoding="async"`: the pictures of the machine, of the news and of the guides. The mark of the home and the heron of the bar are on the first screen and load at once.

Each PNG file that the site copies from the repository (the screen pictures, the pictures of the news and of the guides, the icons) is written again through `site_png_compress` (`tools/kerneltool/site_pictures.odin`): it decodes the file and encodes the same pixels with the encoder of the standard library, `core:image/png` (a row filter chosen for each row, then the deflate of `core:compress/deflate` at its default level 5). The screen pictures of `docs/screenshots` are stored with no compression (`png_encode` of `tools/kerneltool/machine.odin`): 2 360 312 bytes for 1024 by 768. The command prints the count of the pictures and their bytes before and after. The output is the same bytes at each build: the encoder reads no clock, no random number and no thread, and its buffers start at zero; a host test encodes each picture twice and compares the bytes, and compares the pixels of the two files byte for byte. A picture of 16 bits a channel stops the command: the repository has none.

No picture is written at half its width. A browser takes a picture of 512 pixels from a `srcset` only when its place, times the density of the screen, is at most 512 pixels: the place of a picture of the home is 556 pixels on a wide screen, and a phone of density 2 or 3 needs more than 512 pixels for its whole width. So nearly no reader gets the half picture, and its 2 by 2 mean blurs the text of a screen picture. A build that wrote them measured about 60 000 bytes for each half picture; the compressed whole picture is expected near 150 000 bytes (the command prints the measure), so a half picture saves about 90 000 bytes, for that rare reader only. The rule: a version for `srcset` earns its place only when the common screens choose it and it saves at least half of the bytes; the half pictures fail the first part.

### The checks

After the checks of the pages, with a site address:

- each page has one canonical address, its own, and no two pages share one;
- each page has `og:url` (its canonical address), `og:type`, `og:title`, `og:description`, `og:site_name`, `og:image:alt`, and an `og:image` that is a PNG file that the command wrote, with the width and the height that the page states;
- each page has one page graph; it parses (`core:encoding/json`, strict JSON), its `@context` is `https://schema.org`, it has a `@graph`, and each `@id` that a field names is a node of the graph or the canonical address of a page of the site;
- the sitemap lists each page that the command writes once, and no other address.

With no site address: no page has a canonical address, Open Graph or a page graph, and there is no sitemap. A page with two `h1` fails the checks of the pages.

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

- the bar at the top, as the bar of the desktop: the heron at the left, the sections as buttons, the current one marked by a line in the blue of the title bar; under 720 pixels, the sections and the search are behind one menu button (see "The site menu");
- the news cards of the home, side by side on a wide screen: the title, the line of the kind and the date, the picture and the text of each card of a row start at the same height, whatever the length of a title. Each card takes four rows of the grid of the cards and shares them (`grid-template-rows: subgrid`); each part has its row, so a card with no picture keeps its text in line. The picture boxes have one ratio, 4 by 3, the ratio of the screen pictures; a picture of another ratio is shown whole in the box (`object-fit: contain`), not cut. A browser with no subgrid shows the cards as blocks, and a title keeps the room of two lines on a wide screen, so that the common case aligns. No title is cut. On a narrow screen (one column) nothing changes. The cards of the page News stand one under the other at every width: no row to align;
- cards with a border of 1 pixel in their accent and the bar of 4 x 16 pixels before their title, as the cards of the boot display;
- the colors of the concepts with their meaning in the system: the stages of the start take the color of who runs them (the firmware violet, the boot program orange, the kernel blue);
- the tables have the look of the tables of the system: the titles of the columns in the dim color, every second row on a band (`DESIGN.md`, section 10). Each column has the least width of its kind, and a table wider than the page scrolls sideways in its own box (see "The tables");
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
| Any | A column of a table of a document of `docs/` | 6 em, about 12 characters | At spaces; a cell that holds only a number or a date gets that kind |

The measured numbers are What (Prose), The line of the log (Line), Log, line, machine (Prose) and Written (Date): 13 + 30 + 13 em and the date, under the 1120 pixels of the column of the page, so the table does not scroll on a wide screen, and a line of a log takes two or three lines.

- The box: `<div class="table" role="region" tabindex="0" aria-label="...">`, the pattern for a table that scrolls: the keyboard reaches the box and scrolls it with the arrows, and a screen reader names it. The name is the name of the table that its writer gives, or the heading above a table of a document. The focus of the box is visible.
- The box scrolls sideways at every width (`overflow-x: auto`), when the sum of the least widths passes the width of the page; on a wide screen where the table fits, nothing scrolls.
- A sign that there is more: a line in the color of the line of a link at each edge of the box where more of the table is, tied to the place of the scroll of the box (a scroll timeline, `animation-timeline: scroll(self inline)`). It moves with the scroll, not with the time, so it is not an animation in the sense of `DESIGN.md`. A box that does not scroll has no line. A browser with no scroll timeline shows its scroll bar only.
- The first cell of each row stays in view while the table scrolls sideways (`position: sticky; left: 0`), on an opaque background of the color of its row.
- The head row does not stay at the top while the page scrolls. A box with `overflow-x: auto` is a scroll container for both axes, so a `position: sticky; top` of the head would stick inside the box, which does not scroll up and down: the rule would do nothing, so it is not written. The bar of the site does not stay at the top either.
- On a narrow screen a heading, a paragraph, an item, a caption and the breadcrumbs break a long word; a cell of a table does not, because its box scrolls.

### The site menu

The owner asked for it on 2026-11-12: "il manque un menu burger sur la version mobile du site".

- The sections and the search are in one `<details class="bar-menu">` of the bar: one list of links for every width, so a screen reader reads each section once. Its `<summary>` is the button: a square of 32 pixels with three lines of 16 by 2 pixels drawn by the style sheet, and the word "Menu" as its name, hidden by the style sheet. With no style sheet the word shows, and the button opens the list.
- Under 720 pixels: the heron and the name at the left, the button at the right. The open menu lies over the page under the bar, over the whole width: the sections one under the other, the current one marked by a line at its left, then the search over the whole width with its list under it. The open button has the border and the lines in the color of the line of a link. The focus is visible (the rule of the site). The button is a `summary`: Enter and Space open and close it with no script.
- On a wide screen the menu is open and its button is hidden, so it is the bar of today. A `details` that is closed in the file cannot be opened by a style sheet in every browser, so two ways meet:
  - A browser that has `::details-content` shows the content of the closed menu on a wide screen and hides the button (`@supports selector(::details-content)`), with no script.
  - `search.js`, loaded with `defer` on each page, opens the menu on a wide screen and closes it on a narrow one, when the width changes too (`matchMedia("(min-width: 720px)")`). On a narrow screen it also closes the menu at Escape (and puts the focus on the button) and at a click outside, and opens it for `/` and for an address with `?q=`.
  - With no script, a browser with no `::details-content` shows the button on a wide screen too, and the button opens the list: the page stays whole. With the script, such a browser shows the button for the time between the first paint and the run of the deferred script.
- The menu is closed in the file, not open: an open menu that the script closes on a narrow screen moves the page after its first paint on each load.
- At 360 pixels, no line is wider than the screen: a table and a block of code scroll in their own box (`.table`, `pre`); a heading, a paragraph, an item, a caption and the breadcrumbs break a long word or address (`overflow-wrap: anywhere`); the stages, the tiles and the pictures fit a column of 328 pixels.

## The mark on the site

The site draws its own pictures of the mark from `support/mark` (`tools/kerneltool/site_pictures.odin`), on a transparent background, at whole cell sizes, and the page shows each one at its own size:

| File | Cells | Size | Use |
|---|---|---|---|
| `pictures/mark_home.png`, `mark_home_light.png` | heron 8, name 6 | 198 x 250 | The head of the home, one file for each color scheme (`<picture>` and `prefers-color-scheme`) |
| `pictures/mark_bar.png`, `mark_bar_light.png` | heron 1 | 24 x 24 | The bar |
| `pictures/mark_card.png` | heron 16, name 12 | 1200 x 630 | The picture for other sites: on the dark background, because those sites show it on white. Open Graph and the page graph name it. The command stops when it is not opaque (a color type with no alpha and no `tRNS` chunk) or not 1200 x 630 |

The icons of the pages are drawn by the tool from the same table (see "The icons"); the site copies no icon of `resources/logo`. `kerneltool logo` also writes `resources/logo/modus_transparent.png` and `modus_light_transparent.png`, which the README shows in a `<picture>` for the two color schemes.

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
- Each link to an icon is relative, as every link of the site: `favicon.ico` from the home, `../favicon.ico` from a guide. The file is at the root of the site, so the default request `/favicon.ico` finds it when the site is at the root of its domain.

The checks, after the checks of the pages: `favicon.ico` is at the root, its directory reads back (each entry inside the file, a PNG file of the size of its entry) and it has a picture of 32 by 32; each icon of the head of each page and of the manifest is a file that the command wrote, with the size that the page or the manifest states; the icon of a phone and each maskable icon are opaque; the manifest has an icon of 192 and one of 512 for any use, and a maskable one of 512.

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
- (e) Done: what other sites read (`tools/kerneltool/site_metadata.odin`): the canonical address, Open Graph, the summary card, the page graph, the manifest, `sitemap.xml`, `robots.txt`, `releases.xml`, `llms.txt`, the pictures of the repository compressed, and their checks. See "What other sites read".
- The count of checks of `kerneltool check`: the tool prints each check that passed and keeps no count.
- An embedded font: Paper Mono is under the SIL OFL 1.1 with no Reserved Font Name (`resources/fonts/paper_mono.license`): its ASCII subsets can be copied into the site with `OFL.txt` and their `.license` files and declared with `@font-face`. The site uses the fonts of the reader's system.

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
| The documents, the news, the changelog, the code that the reference tables read, `flake.nix`, `flake.lock`, `LICENSE`, the pictures of `docs/screenshots` and `resources/logo` | Committed | Read |
| The pictures of the mark, the module pages and their signatures | The code of the tool (`support/mark`, `describe_package`); no module is built | Written |
| The commit | `.git` | Read |
| `build/boot.image` | `kerneltool build` | Written by the step before: the tiles of the home with their sizes and colors, the size of each module in its page, and the column "in the boot image" of the licenses. With no image these show the modules with no size, and "not recorded" |
| The logs of the machine tests, `build/test_output*.txt` | `kerneltool test`, `kerneltool measure` | Absent: each measured number says "Not measured in this build.", and so does the start of the machine on the home. The command does not fail |
| `build/reproducible_build.txt` | `kerneltool check` | Absent: "Not measured in this build." |

The time of the step `kerneltool build` on a runner of GitHub is not measured yet: the first run gives it.

The domain:

- The custom domain is a setting of the repository (Settings, Pages: the source "GitHub Actions", the custom domain `modus.froment.software`, "Enforce HTTPS"). With a deployment of an artifact, GitHub Pages ignores a `CNAME` file: the site has none.
- The record at Cloudflare: `modus.froment.software`, a `CNAME` to `sachahjkl.github.io`, through the proxy of Cloudflare (the owner accepted the proxy). Not verified here: GitHub Pages makes the certificate of a custom domain only when its check of the record sees GitHub, and the proxy hides it. The usual order: the record with no proxy until GitHub shows "Enforce HTTPS", then the proxy, with the TLS mode "Full (strict)" of Cloudflare.
- The branch `gh-pages` that served the first version by hand is no longer read once the source is "GitHub Actions".

The headers: GitHub Pages sends no header that a site chooses. The proxy of Cloudflare adds these to each answer for the host `modus.froment.software` (a rule that changes the headers of the response):

| Header | Value | Why |
|---|---|---|
| `Content-Security-Policy` | `default-src 'none'; style-src 'self'; img-src 'self' data:; script-src 'self'; connect-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'` | The style sheet, the pictures and the grid of points (`data:`), `search.js` and its fetch of `search.json`, the manifest; nothing else. The page graph is data that a browser does not run: `script-src` does not apply to it |
| `X-Content-Type-Options` | `nosniff` | A file is read as its type only |
| `Referrer-Policy` | `strict-origin-when-cross-origin` | Another host sees the host of the site, not the page |
| `X-Frame-Options` | `DENY` | `frame-ancestors` for a browser that does not read it |
| `Strict-Transport-Security` | `max-age=31536000` | The site is read over TLS only; no `includeSubDomains`, because the other hosts of the domain are not this site |
| `Permissions-Policy` | `camera=(), microphone=(), geolocation=()` | The site uses none of them |
| `Cross-Origin-Opener-Policy` | `same-origin` | A page of another host that opens the site gets no handle on its window |

A `<meta>` policy is not written: `frame-ancestors` has no effect there, and `'self'` does not work for a page opened from a file. The types of the files are those of GitHub Pages, from their extensions: `application/xml` for the two feeds, which feed readers read.

## What the owner must decide

1. The measured numbers of the site online. A clean checkout has no log of a machine test, so the site says "Not measured in this build." for each number. The choices: the workflow also runs `kerneltool test` (machines under QEMU on the runner, with the time of a test run), or each release commits the lines of the numbers in one file that the site reads.
2. The cache of the workflow: the cache of GitHub Actions (`magic-nix-cache-action`, now) or FlakeHub Cache (`flakehub-cache-action`, which needs a FlakeHub account for the repository).
3. The name in the title of `README.md` and in the `description` of `flake.nix`: both say "Next-Gen Kernel", the name of the project before `modus`. The site does not read either (it reads the lead of `README.md`). Not changed here.
