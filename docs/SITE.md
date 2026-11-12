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
  - each `href`, `src` and `srcset` that is not an address of another host names a page or a file that the command wrote (a link that ends with `/` names the `index.html` of the folder, and the query of a file version is ignored), and its anchor is an `id` of that page;
  - a link to a page has the form of the build (see "The addresses of the pages"): with a site address it names the folder, with none the `index.html`;
  - each redirect page (`GLOSSARY.md`) is at a path that no page and no file of the site has, and its refresh and its link name a page that the command writes;
  - each `srcset` candidate names a file that the command wrote;
  - a page of the documentation layout has one documentation tree and one list "On this page", and each link of the list names an id of the page; a page of the presentation layout has neither (see "The two layouts");
  - no page holds code or style of its own: each `<script>` has a `src` and nothing inside, but the one `<script type="application/ld+json">` of the page graph, whose text has no `<`; no `<style>` element and no `style` attribute exists.
- Then the command checks what other programs read (see "What other sites read"); a failure stops it in the same way.
- After the checks of the pages, the command makes the index of the search and checks it against the pages (see "The search"); a failure stops it in the same way.
- At its end the command prints: the pages and their bytes, the count of the redirect pages, the other files, the entries and the bytes of the index of the search and the bytes of the script, the guides, the news entries, the terms of the glossary, the commit and the release, the numbers that are not measured, the cells of the licenses that are not recorded, each part of a guide that the renderer did not understand, the parts that it did not write with no site address (or, with one, the parts that it wrote), and the count of the pictures of the repository that it compressed, with their bytes before and after.
- `kerneltool check` runs the host tests of the site (`tools/kerneltool/site_test.odin`, `site_render_test.odin`) and checks that each picture that `README.md` names is a file of the repository. It does not write the site.

## The pages

A page named by a folder (`news/`) is the `index.html` of that folder (see "The addresses of the pages").

| Page | Generated from |
|---|---|
| `index.html`, the home | The mark (`support/mark`), the first sentence of the first paragraph of `README.md` as the tagline of the head, the three newest news entries, the rest of that paragraph in a section "What it is" after the news (the owner, 2026-11-12: "la tagline est trop longue"; after the news, so that the first screen of a phone holds the mark, the name, the tagline and the links only; the description of the home in its head, Open Graph, the manifest and the page graph stays the whole paragraph, cut at 160 bytes, because the tagline alone is too short to describe the system), the stages of the start from the lines `kernel: boot: ...` of `build/test_output.txt`, the tiles of the boot image (see "The tiles of the boot image"), the first three measured numbers, the pictures of `docs/screenshots` with the captions of `README.md`, the newest release of `CHANGELOG.md`, the count of steps of `docs/REVIEWS.md` |
| `guides/index.html` | The table "Documents" of `README.md`, then the other documents of `docs/` by name |
| `guides/<name>/` | Each document of `docs/` but the working records `HANDOFF.md`, `REVIEWS.md`, `SITE.md` and `FIRST_MILESTONE.md` (`SITE_WORKING_RECORDS`), which stay out of the site: only the guides that explain the system are published. A link of a page to a working record names the file in the repository. The glossary is a page of the reference |
| `reference/index.html` | The list of the reference tables below |
| `reference/glossary/` | `docs/GLOSSARY.md`: each row of a table whose first column is "Term" has the anchor `term-<name>` |
| `reference/commands/` | `COMMANDS` in `tools/kerneltool/main.odin`: the name and the text of each command |
| `reference/numbers/` | The list `site_measures` and the logs of `build/` |
| `reference/licenses/` | See "The licenses" |
| `releases/` | All of `CHANGELOG.md`, newest first; each release has the anchor `release-<number>`, and a line with a link to each news entry that names it |
| `news/`, `news.xml` | The files of `news/`; see "The news" |
| `search.json`, `search.js` | The index of the search and its script; see "The search" |
| `releases.xml` | The feed of the releases, from `CHANGELOG.md`; see "What other sites read" |
| `site.webmanifest`, `llms.txt` | The name, the colors and the icons of the site; the pages with their descriptions in Markdown |
| `sitemap.xml`, `robots.txt` | Only with a site address; see "What other sites read" |
| `status/` | See "The status page" |
| `reference/operations/`, `context/`, `errors/`, `grants/`, `fixed-ranges/`, `console/` | See "The reference tables" |
| `reference/modules/index.html`, `reference/modules/<name>/` | See "The module pages" |
| `reference/types/` | See "The types" |

Each page has the bar (the heron and the name at the left, the sections as buttons: Guides, Reference, Status, News, Releases; a section appears when its page exists), breadcrumbs on each page below the home, and a foot that names the commit, the release and the time of the build, and the files that the page comes from, as links to the repository at that commit. A reference table names the files that it is read from.

The tool reads the commit from the files of git (`.git`, `HEAD`, the reference, `packed-refs`), with no program. When it cannot, the foot says so and the links to files of the repository go to `master`.

## The addresses of the pages

The owner asked for it on 2026-11-12: "j'aimerais des urls genre /reference/licenses au lieu de licenses.html (possible avec index.html dans dossier".

- Each page is the `index.html` of its own folder: `reference/licenses/index.html`, `guides/NETWORK/index.html`, `news/index.html`. The home is `index.html` at the root. `site_page_file` in `tools/kerneltool/site_frame.odin` gives the file of a page from its folder; no other code writes the path of a page.
- The address of a page is its folder with a final slash: `/reference/licenses/`. GitHub Pages serves the `index.html` of a folder at that address, and it redirects the address with no final slash to it.
- `site_page_link` writes each link from a page to a page, in one of two forms:
  - With a site address (the published site): the folder, `../../reference/licenses/`, and `./` for the home from the home.
  - With no site address (the site opened from a disk): the file, `../../reference/licenses/index.html`. A browser shows a folder of a disk as a list of its files, not as its `index.html`.
- A link to a file that is not a page (the style sheet, the script, a picture, an icon, a feed, the manifest) is relative in the same way, one `../` for each folder of the page.
- The canonical address, Open Graph, the `@id`s of the page graph, the sitemap, `llms.txt` and the two feeds name the folder of each page. With no site address, `llms.txt` and the feeds name the `index.html` from the root.
- `search.json` holds the link of each page from the root of the site, in the form of the build. The script joins it to its own folder and applies no rule of its own.

### The redirect pages

The old addresses (`reference/licenses.html`) were public from the first publication to this change. The command writes a redirect page (`GLOSSARY.md`) at the old path of each page that is not an index page. The four index pages (the home, `guides/`, `reference/`, `reference/modules/`) keep their old path, so they have none.

- A redirect page has a title, `<meta name="robots" content="noindex">`, a refresh with a delay of 0 to the new address (relative), and one visible link to it. It has no script, no bar, no `h1` and no description.
- With a site address it also names the new address as its canonical address. With none it has no canonical address, as no page has one.
- It is not a page of the site: it is not in the sitemap, the index of the search, `llms.txt` or the feeds, and the checks of the pages, of the page graph and of the search do not apply to it.
- The check: its path is not the path of a page or of a file of the site, and its refresh and its link name a page that the command writes.
- The command prints their count: the count of the pages less the four index pages.

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

Each guide has the documentation layout (see "The two layouts"): its headings of levels 2 and 3 are in "On this page". It links to the guides before and after it.

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
- `news/`: each entry, newest first, as a card with the color of its kind, its date, a link to its release and to its guide, its picture, and a link to its file. Its anchor is `news-<the name of its file>`. One renderer renders all the entries of the page, so the ids stay unique and each term of the glossary links once.
- The home shows the three newest entries: the title, the kind, the date, the picture and the first sentence.
- `releases/`: under each release, a link to each entry that names it. An entry with `release: next` is in no release yet.
- `news.xml`: the feed, Atom (RFC 4287), newest first; each entry has its title, its date (`published` and `updated`, at 00:00 UTC), its kind as a `category`, its first sentence as its `summary`, and its text and picture as HTML in its `content`. The id of the feed and of each entry is the address of its file in the repository on `master` (`<repository>/blob/master/news/<file>`): a file of `news/` is never moved, so the id stays the same when the site gets an address. Each page names the feed in its head (`<link rel="alternate" type="application/atom+xml">`), so that a browser and a feed reader find it.

What a feed reader needs, and what is missing with no address:

- A reader subscribes to the address of the feed and resolves each relative link against it. With no address (`SITE_ADDRESS` is empty), the links of the feed are relative to the root of the site (`news/index.html#news-...`, `pictures/...`): they work for a reader that fetched the feed from the host of the site.
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
| The canonical address (`GLOSSARY.md`) | No | `<site address>/<folder of the page>/`, as `<site address>/reference/licenses/`; the home is `<site address>/` |
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

- `sitemap.xml` lists the canonical address of each page that the command writes, once, by path. A page has a `lastmod` only when the tool knows the date of its last change: `news/` (the date of its newest entry) and `releases/` (the date of its newest release). The other pages have none: each build changes their foot, and the tool does not read the history of their sources. A wrong `lastmod` teaches a search engine to ignore the field.
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

- each page has one canonical address, its own (the folder of the page, with a final slash), and no two pages share one;
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

Prose is in the reading font of the reader's system, at most 72 characters a line on a presentation page and 80 on a documentation page; code, signatures, numbers and identifiers are in its monospace font. No animation, no shadow, no round corner. The light form follows `prefers-color-scheme`. A print form hides the bar and the navigation.

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

### The two layouts

The owner asked for it on 2026-11-12: "la doc, je veux un vrai truc de doc, comme Odin par exemple, où ils ont une sidebar, il y a des documentations techniques au centre, il y a les symboles à droite". The code is `tools/kerneltool/site_documentation.odin`.

The writer of each page states its layout (`Site_Page.layout`); the tool does not guess it from a path.

| Layout | Pages | Form |
|---|---|---|
| Presentation | The home, the news, the releases | One centred column of at most 1152 pixels |
| Documentation (`GLOSSARY.md`) | Each guide, each reference page, the glossary, each module page, the status, and the index pages of the guides, the reference and the modules | The documentation tree, the text, "On this page", over the whole width of the window |

The documentation tree (`GLOSSARY.md`) is one `<nav class="tree" aria-label="Documentation">`: "Guides" with each guide in the reading order of the page of the guides, "Reference" with each reference page in the order of its index, "Modules" with a `details` for each group (Kernel, Programs, Modules), open when it holds the current page, and "Status". The current page has `aria-current="page"`. It is written once in each page, inside the site menu, after the search: under 720 pixels it is under the sections in the open menu, which scrolls on its own; from 720 pixels the style sheet fixes it at the left of the window (`position: fixed`, its own `overflow-y`), so a long tree never moves the page. With no script, a browser with no `::details-content` shows the tree when the button of the menu opens it, as the sections.

"On this page" (`GLOSSARY.md`) is one `<details class="outline">` at the start of `main`: the title of the page (a link to `#content`), then each heading h2 and h3 with an id, then each element that states a symbol with `data-outline`, in the order of the page. From 1100 pixels it is a column at the right of the text, sticky, with its own scroll, and open (`::details-content`, or `search.js`); under 1100 pixels it is closed above the text, and its summary "On this page" opens it. The script marks the link of the part in view with `aria-current="location"`: an `IntersectionObserver` reports each heading and symbol that enters or leaves the top 40 % of the window; nothing runs each frame. With no script it is a correct list of links.

The text keeps a measure of 80 characters (`80ch`) for paragraphs, items, headings and quotes; a table, a block of code and a figure take the whole middle column, and a table still scrolls in its own box.

| Width of the window | Columns | The grid |
|---|---|---|
| Under 720 pixels (360) | The text only; the tree is in the menu; "On this page" is closed above the text | `main`: `grid-template-columns: minmax(0, 1fr)` |
| 720 to 1099 pixels (768, 1024) | The tree, fixed, 256 pixels; the text | `body`: `padding-left: 256px`; `main`: `grid-template-columns: minmax(0, 1fr)` |
| From 1100 pixels (1440, 1920, 2560) | The tree, 256 pixels; the text; "On this page", 240 pixels | `body`: `padding-left: 256px`; `main`: `grid-template-columns: minmax(0, 1fr) 240px` |

No column has a fixed least width but the tree and "On this page", and each grid item of the text has `min-width: 0`: no line is wider than the window at 360, 768, 1024, 1440, 1920 and 2560 pixels. At 768 pixels the text column is 480 pixels; at 1100 pixels, 540.

Print shows the middle column only: the bar, the tree, "On this page", the breadcrumbs and the links to the guides before and after are hidden.

### The kinds of values

The owner asked for it on 2026-11-12: "que les valeurs techniques, comme par exemple le fait de dire handle ou les valeurs numériques, soient affichées en monospace, qu'elles aient une couleur [...] accompagnées d'un icône". The rule of the two fonts of the desktop holds (`DESIGN.md`, "Two fonts"): a name or an explanation in the reading font, a value in the monospace font. The code is `tools/kerneltool/site_values.odin`.

One table, `site_value_kinds`, gives each value kind (`GLOSSARY.md`) its class `value-<name>`, its icon (12 by 12 cells, `#` a cell), an accent of `support/graphics/rules.odin` with a `graphics.shade` for each color scheme, and its meaning. The contrast is that of the text of a value on the two surfaces of a table: the background and the band of every second row (dark: `0x0B1018`, `0x17212E`; light: `0xF4F6F8`, white). A host test computes each one.

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
| Version, release, commit, hash | A tag with a hole | Boot program | 8.42 / 7.17 | 4.66 / 5.05 |
| Yes: a state that holds | A filled square | Program | 10.45 / 8.90 | 4.72 / 5.12 |
| No: a state that does not hold | An empty square | Dim | 5.40 / 4.60 | 4.60 / 4.99 |

The firmware violet at 100 % is 4.50 on the band of a row, at the bound: the type kind takes it at 115 %.

The markup: a value is `<code class="value value-<name>">`, written by one procedure (`site_value`), in the monospace font and the color of its kind, with a rule of 2 pixels at its left and no filled background. A color is never the only sign: the monospace font, the icon in the head of its column or before the label of its fact, and the text carry the kind too.

Who states the kind: the writer of each table gives the kind of each column (`site_table_start`, its last argument), and the writer of a symbol gives the kind of each fact (`Site_Symbol_Fact.kind`). No cell is classified by its text. The one rule of the column itself: a column of the kind Number is of the number kind, and a column of the kind Date of the time kind; their writers already state what they hold.

Where it shows:

- the reference tables: the statuses and the error kinds (status), the grants (grant), the operations (operation), the commands of the console and of the tool (command), the context roles (number; handle or value in each cell), the fixed ranges (number), the programs and their grants (module, grant), the licenses (file, version), the index of the guides and of the reference (file), the measured numbers (the date: time; a quoted line of a log stays as the log has it);
- the module pages: the index (module, number, yes or no in each cell, the imports), the facts of a module (file, yes or no, size), the facts of each export (type);
- the facts of each symbol: its number, its statuses, its parameters and its result, its source line (file);
- the status page: the status of each property (status), the gaps and the next steps (number);
- not the guides and not the glossary: a document of `docs/` keeps its code spans as Markdown marks them, and no kind is guessed in prose.

The restraint:

- At most one icon for each value, and the same kind always has the same color and the same icon.
- A column whose cells are all of one kind shows the icon once, in its head, and its cells keep the font and the color only. A fact shows the icon once, before its label. A value has its own icon only in a column of mixed kinds (handle or value, yes or no) or in a cell of facts of several kinds.
- No icon and no colored value in a heading (a check of the pages: `site_heading_value_problem`), and none in running prose.

The icons: each one is an SVG file, `pictures/values/<name>.svg`, written by the tool from its cells (one `rect` for each run of cells of a row, `shape-rendering="crispEdges"`). The style sheet draws an icon as the `::before` of the element: a box of 12 by 12 pixels in the color of the kind, with the file as its `mask`. A mask is an image of the style sheet: `img-src 'self'` covers it, and the style sheet is `style-src 'self'`, so the Content-Security-Policy of the host does not change. One sprite with an external `<use href="...#handle">` was refused: whether `img-src` or `default-src` governs the fetch of an external `<use>` is not the same in each browser, and `default-src` is `'none'`. The icon has no text and no name: it is decoration, and the head, the label or the text says the kind.

The legend: the reference index ends with the section "The kinds of values", a table of the icon, the kind and its meaning, from the same table.

### The versions of the files

The site is behind a proxy that keeps a file for hours. Each link to a file whose bytes change between builds carries its file version (`GLOSSARY.md`): `style.css?v=<16 hexadecimal digits>`, the first 8 bytes of the BLAKE3 hash of its bytes (`contract/blake3`). The files: `style.css`, `search.js`, `mark_animation.js` and `search.json` (`SITE_VERSIONED_FILES`). The same bytes give the same address. The index of the search is written before the pages, so that each page names its version: `search.js` reads it from the attribute `data-index` of its own `script` element, relative to its folder, with no inline script. The check of the links ignores the query. The icons and the pictures carry no version: their bytes come from the mark and the repository and change rarely.

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
- Each link to an icon is relative, as every link of the site: `favicon.ico` from the home, `../../favicon.ico` from a guide. The file is at the root of the site, so the default request `/favicon.ico` finds it when the site is at the root of its domain.

The checks, after the checks of the pages: `favicon.ico` is at the root, its directory reads back (each entry inside the file, a PNG file of the size of its entry) and it has a picture of 32 by 32; each icon of the head of each page and of the manifest is a file that the command wrote, with the size that the page or the manifest states; the icon of a phone and each maskable icon are opaque; the manifest has an icon of 192 and one of 512 for any use, and a maskable one of 512.

## The status page

`status/` gives the state of the system with no sentence of its own: each cell is a part of `PROPERTIES.md` or of `FIRST_MILESTONE.md`.

| Table | Read from, and the form the reader relies on |
|---|---|
| Properties | `PROPERTIES.md`: the number and the title of each section `## <n>. <title>`, and the column "Status" of the table `## Summary` (the reader of the first layer). The title links to the heading in the guide |
| Its evidence items | `FIRST_MILESTONE.md`: the numbered items under `## Evidence`, each a link to its line in the repository (the file is a working record, not a page of the site). An item names a property when its text says `property <n>` (no regard to case) or `P<n>` (a capital P), as a whole word; `properties 3 and 4` names none |
| Its gaps | The items `- <text>` under `## Gaps`, and the lines that continue them (they start with a space), by the same rule. A line of text between the items (`Performance:`) is the group of the items after it |
| Gaps | Each gap, with its number (`gap-<n>` on the page, from 1 in the order of the file, with a link to its line), its group and its text |
| Next steps | The numbered items under `## Next steps`, each with a link to its line in the repository |

The page renders `PROPERTIES.md` again to read the ids of its headings: the renderer gives the same ids to the same text, so the links reach the guide. It renders `FIRST_MILESTONE.md` for its numbered items and their lines only, and drops the HTML. The status page has the documentation layout; its property rows and its gap rows are symbols of "On this page".

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

Each page starts with what the thing is: the comment above its declaration in the source (`site_comment_above`), when the source has one, as a quote that names its file. Then the table.

The kernel operations, the commands of the console, the commands of the tool and the exports of each module are documented symbols (`GLOSSARY.md`), under the table of their page, as on a package page of a programming language. A symbol shows:

- its name, as a heading with its id (`operation-<name>`, `command-<name>`, `tool-command-<name>`, `export-<name>`), which "On this page" lists; the name in the table is a link to it;
- its signature in a block of code: an operation as `Name(<parameters>) -> <result>` from the start of its comment (none when the comment does not start with `(`), a command as `help()` prints it, a command of the tool as `nix develop -c kerneltool <name>`, an export as the console prints it;
- the text of its source comment, one paragraph a line; nothing when the source has none;
- its facts: the number of an operation and the statuses that its comment names (links to the table of statuses); the parameters and the result of a command; the parameters, the result and the error record of an export (the rule of the build: it fails with a negative result and writes the record);
- its source line, a link to `<repository>/blob/<commit>/<file>#L<line>`.

The command prints the count of the symbols and of those with no comment in their source (each `entry` of a module has none: the build gives it no text). The rows of the other tables that have an id (a status, an error kind, a unit, a role, a grant, a fixed range, a license, a measured number, a property, a gap) state a symbol too (`data-outline`), so "On this page" lists them.

What the tables cannot show:

- The values 13 and 15 of the context (the settings page and the date page) have a comment in `contract/operation` and no constant: they are not in the table.
- A heading comment inside an enumeration (as "The word wait" before `Word_Wait`) shows under the member before it: the form cannot tell it from a comment that continues.
- The limits of processor time and of log records of a program come from `budget_of`, a computation: the page names it and does not show its values.

## The module pages

`reference/modules/index.html` lists each module of `module_builds` (`tools/kerneltool/modules.odin`) in its group, one table and one heading for each: Kernel (a module that runs in kernel mode), Programs (its source is in `programs/`), Modules (the others). The documentation tree has the same groups. A row gives its name, whether it is in the boot image, its count of exports, its imports and its purpose. `reference/modules/<name>/` gives:

- its documentation: the comment before `package` in its source, the text that the build writes into the module (`describe_package` of `tools/kerneltool/describe.odin`); its purpose is the first sentence;
- its source folder, its size in the boot image of the last build (or that the image is not built), its imports and the modules that import it;
- its kind (its group);
- its exports, a table then each one as a documented symbol (see "The reference tables"), each with its signature as the console prints it (`write(name: Text, data: Text) -> Integer`, `Handle(Read, Write)`, `Table(Rectangle, Change)`) and its line of help. They come from the same reader as the build: no module needs to be built;
- for a program, its grants and its budget (pages, programs, threads) from `grants_of` and `things_of` of the root service, with the comments of those lines.

## The types

The owner asked for it on 2026-11-12: "Si c'était possible sur les différents data types, d'avoir un tool type qui explique le type. Genre sa carte d'identité, sa taille, des informations techniques. Sa taille, son alignement, les trucs normaux qu'on aimerait savoir quand on vient sur cette doc." The code is `tools/kerneltool/site_types.odin`; its host tests are `site_types_test.odin`.

### What a type card holds

Each type has a type card (`GLOSSARY.md`). The facts come from the compiler, never from a number typed by hand: the tool imports the contract packages, and `type_info_of(T)` gives the size, the alignment, each field with its name, type and offset, each member of an enum with its value, the element and the underlying type of a bit set, the base of a distinct type, and the variants of a union. The declaration (its source text), its comment and its line come from the parser of Odin (`core:odin/parser`), as the descriptions of the modules do.

| Kind | Rows | The card |
|---|---|---|
| Struct | Each type of `contract/operation`, `contract/errors`, `contract/fixed_addresses`, `contract/module` (`SITE_TYPE_PACKAGES`) | Size, alignment, the padding in all; a table of the fields (name, type, offset, size) with a row "padding" for each run of unused bytes; the sizes of the rows add up to the size |
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

The tool is built for the host; the system for x86-64 with no operating system. Each type of the four packages has the same layout on both today: an address, `int` and `uintptr` are 8 bytes on x86-64 and on a host of 64 bits, and the rules of a struct of Odin are the same (each field at a multiple of its alignment, the size a multiple of the largest alignment). Two things keep this true:

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

The check of each page (`site_type_cards_problem`): each `popovertarget` and each `aria-describedby` names an id of the page, and no two cards have one id.

What is not done: the types are not entries of the search; a type of a guide (a code span) is not a reference.

## The colors of the code

The owner asked for it on 2026-11-12: "Un peu dommage aussi qu'on ait pas de coloration du code, peut-être avec Shiki, on peut, parce que là je vois du Odin qui est pas coloré." The code is `tools/kerneltool/site_code.odin`; its host tests are `site_code_test.odin`.

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

The fenced blocks of `docs/*.md` on 2026-11-12: 15 blocks; 9 with no language, 5 `mermaid`, 1 `odin`. No block is marked `asm`, `sh`, `console`, `nix` or `yaml`, so the tool has no other lexer: a lexer for a language that no block names is code with no use. The 5 mermaid blocks stay plain, as before. The one block of Odin (`MODULE_CONTRACT.md`, the export `seal`) is colored.

The size: the declarations of the page of the types are 963 lines, 53 KB of text, about 7 900 tokens; their spans and references add about 100 KB to that page (estimated, not measured). The guide of the module contract grows by about 1.5 KB; the other guides do not change.

## The polish of the browser's parts

The owner asked for it on 2026-11-12: "si tu peux styliser les scroll-bars, s'il te plaît, ce serait cool. Tu as tous les trucs de peaufinage en CSS là que tu peux mettre, genre la couleur de highlight, enfin tout ce bordel." In the design of the system: square, the colors of the palette, both color schemes, and nothing more. The rules are `SITE_POLISH_RULES` in `tools/kerneltool/site_style.odin`, after the colors, so that print and the forced colors win over them.

- Scroll bars: `scrollbar-color` (the dim color on the track color) and `scrollbar-width: thin` on the page, the tree, "On this page", the table boxes, the blocks of code, the open menu, the list of the search and the cards of the types. The parts `::-webkit-scrollbar` only inside `@supports not (scrollbar-color: auto)`: a browser that has both ignores the standard one when the parts are styled. A square thumb of 8 pixels, the line color on hover. `scrollbar-gutter: stable` on the page.
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
- The card of a type has no veil: `::backdrop` is transparent; a card is not a modal.
- Forced colors (`@media (forced-colors: active)`): the icons of the values in `CanvasText`, the marks of the values in `CanvasText`, the focus in `Highlight`, the border of a card in `CanvasText`.
- Print: black text, no color of code or of a value, no card of a type, a block of code wraps.

A host test checks that the style sheet holds each of these rules, has no `outline: none` and no `outline: 0`, and that each `border-radius` is 0.

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
