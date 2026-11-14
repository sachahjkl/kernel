# Changelog

All the changes of the system that a reader notices. The format is [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).

The project has steps, not separate releases. The merge of step N on `master` is the release `0.N.0`, with the date of that merge. A correction between two steps is `0.N.1`, `0.N.2`. The release `0.0.0` is the first milestone, before step 1. The number of the newest release is `RELEASE_NUMBER` in `contract/release/release.odin`; `kerneltool release_number` prints it.

What is not in a release yet is in `changelog.d/`, one fragment for each change. `kerneltool changelog release` writes a release from the fragments. Nobody edits this file by hand.

## [0.92.0] - 2026-11-14

### Added

- **The boot verifies a signed system description and measures it**: before the kernel starts, the boot program verifies the Ed25519 signature of the system description, the list of the kernel and of each module and resource with its BLAKE3 hash, then compares each file with it. One changed byte or a wrong signature stops the boot, with the file and both hashes on the boot display. The firmware then extends PCR 11 of the TPM with the SHA-256 hash of the description, and the root service checks the boot image again before the first program starts. The boot display says which key signed the system, and says "not trusted" for the test signing key of the repository. Nothing verifies the boot program itself until Secure Boot is built. `kerneltool key new` writes a signing key outside the repository; `kerneltool test trusted_boot` runs four machines, two of them with a software TPM.
- **Secure Boot verifies the boot program**: the build signs the boot program with a firmware signing key, an RSA key and its certificate, because the firmware cannot verify Ed25519. With Secure Boot on and that certificate enrolled, the firmware starts only the signed boot program, and the boot display says "verified by: the firmware (Secure Boot), then the boot program". A signed boot program with one changed byte, and an unsigned one, never start. `kerneltool key new` now also makes the firmware signing key. Beside each boot volume, a file says which key signed it, and that a volume signed by the test keys must not be installed on a real machine.
- **The console colors its code**: the line that the person types, the line that it writes back, and the signatures in the completion list show functions, types, texts, numbers and punctuation in the colors of code of the site, from one table of the system. A name that the console does not know is marked quietly once the person typed past it, and a text with no end quote keeps the color of a text while it is typed.
- **The foot of each page names the maker**: "modus · by Froment Software", with a link to its site.
- **Every fault kind of a thread can go to the fault ring**: a fault handler names the kinds that it takes (divide error, invalid opcode, protection fault, breakpoint, the floating-point errors, and page faults), and a fault of such a kind becomes a record with its kind and its error code in place of a stop. A breakpoint answered Resume goes on after its int3; Resume after a fault other than a page fault is refused, so a handler cannot make a thread fault again forever, and Stop gives the report of the fault. A handler that asks for nothing gets page faults only, as before. A program with no handler that runs int3 now stops on a breakpoint, not on a protection fault.
- **A program stops one of its threads, reads and writes its registers, and resumes it**: the new kernel operation `Thread_Control` (33) has six commands: `Stop`, `Resume`, `Read_Registers`, `Write_Registers`, `Read_Extended_State` and `Write_Extended_State`. A stop is a count: two stops need two resumes. A thread of another program needs a thread handle with `Inspect` to stop, resume and read it, and with `Inspect` and `Write` to write it; `Control`, the right to end a thread, gives neither. The kernel refuses a written frame with the code selector of the kernel, an I/O privilege level, interrupts off, an instruction address that is not canonical, or an extended state that the processor would refuse, and nothing changes. `Thread_State` gives the stop count and the size of the extended state area. After a write, `Fault_Answer` accepts `Resume` for every fault kind: a handler can skip a divide error. The kernel has 33 operations.
- **Principals: the machine, one named principal, its unlock and its session**: principal 0 is the machine, with the measure of the system. `principal_create("name")` in the console creates a named principal whose passphrase is typed in the window of `unlock`; Argon2id derives the key that seals its keys, a wrong passphrase opens nothing, and `lock()` stops the programs of its session. A program that the desktop starts during the session has stores of its own, and `grants` names the principal of each program. The seal by the TPM, recovery and the encryption of the stores are not built (`docs/PRINCIPALS.md`).
- **Code spans link to the declarations of the sources**: a procedure, a type, a constant or a global variable that a guide, a news entry or a source comment names links to its line or its module page, with the icon of its kind and a card that shows its line of Odin and its comment; a span that is a fragment of Odin is colored.
- **A stop report names its procedures and its source lines**: the build writes a debug object for each module (its procedures and its line table, made from the DWARF of the compiler) and puts them in a debug image beside the boot program, not in the boot image. The console, `errors` and `inspect` now show a frame as `fault::three + 0x8 in fault (programs/fault/main.odin:15)`; the module bytes are the same with and without debug information, and `kerneltool check` proves it with a third build.
- **The module graph on the site**: a page of the reference draws each module and program of the build as a bar as long as its bytes, and each import as a line, in columns by the depth of the imports; a pointer or the focus on a module marks its imports and its importers and shows its identity card, and a table under the picture gives every import. Each module page shows its identity card and a figure of what it imports and what imports it.
- **The imports of what runs**: `manual.edges()` gives one row for each module of each program that runs, with the module of the same program that imports it and the module that a replacement put it in place of; the console combines it with `where` and `columns`.
- **The log shows each value in the color of its kind**: a log record keeps where each number, size, time, module, hash and status of its text is, and the program `log` draws each one in the color that the site gives its kind, with a legend, and without the start of a text that repeats its program and channel. `log.value_runs(after)` gives these runs as a table. The text of a record and the serial port do not change; a record now has 152 bytes of text, and the operation `Log` takes the runs in its seventh value.
- **The reference pages render the source comments as Markdown**: bold, italics, lists, examples in code and links to operations, exports, declarations, terms and guides. A link that names nothing stops the build of the site. The 33 kernel operations, `manual`, `cryptography` and the exports of `storage` have a full text: arguments, results, statuses and the rights in bold. A module carries the same text with the marks removed, so `manual` and the help of the console show plain lines as before.
- **The debug object of a module describes its variables and its types**: beside the names of the procedures and the source lines, it now holds the types, the global variables, and the parameters and the local variables of each procedure, each with its range of instructions and where its value is (a register, or memory at the frame pointer, the stack pointer or another register plus an offset; "not readable" when the compiler gives no such location). It also holds the BLAKE3 hash of the content of each source file at the build, so a reader shows a source line only from the same version of the file, and it is used only for the module whose hash it names. The module file does not change, and two builds give the same debug object.
- **A program sets the weight and the request of a thread that runs**: `Thread_Control` has two new commands, `Read_Schedule` and `Write_Schedule`, with the record `Thread_Schedule` (weight, request, weight limit). A program lowers the weight and the request of its own threads, and never raises them; a thread handle reads with Inspect and lowers with Control; the machine handle with Schedule and Inspect names any thread by its machine number, which the thread report now gives (`Thread_Report.machine_number`; the record grows from 72 to 80 bytes), and it alone raises a weight or a request (a raised thread starts again as a new thread for its strategy) and writes the weight limit of a thread: the thread and the threads that it creates then stay at or under that weight. `Thread_Create` refuses a weight above the weight limit of the calling thread. The kernel still has 33 operations.
- **The kernel parts of a debugger**: a program with the right `Debug` on the handle of another program becomes its debugger. It receives the debug exceptions and the breakpoints of that program, sets four breakpoints for each thread (an instruction, or bytes that the thread writes or reads) with no write to the shared code, runs a thread one instruction at a time, and reads the memory of the program, one page at most in each read. When the debugger ends or detaches, the kernel gives the program back each thread that the debugger held. The kernel still has 33 operations. The commands of the console are not built yet.
- **The placement of a thread on the processors**: each thread has a set of the processors that can run it, which `Thread_Control` reads and writes while the thread runs (`Read_Placement`, `Write_Placement`; no new kernel operation). A program only narrows the set of its own threads. The holder of the machine handle with `Schedule` and `Inspect` writes any set and a limit, which a new thread and a started program get from their creator: two programs whose limits share no processor never run on the same processor. A thread that never gets a placement is scheduled as before.
- **The debugger: a service, and its commands in the console**: `debug("clock")` attaches the service `debugger` to a program, and `break_at`, `watch`, `threads`, `hold`, `resume`, `continue_all`, `registers`, `stack`, `locals`, `value`, `source`, `step`, `step_line`, `debug_memory`, `events`, `wait_stop` and `detach` give tables with the procedures, the lines, the types and the variables of the debug objects. The root service gives the debug access by one rule over grants, with no name of a program: the caller acts for the principal of the program, and holds each grant that the program holds; a program with no grant can be debugged, and a service, a device service and a program with a private store, a terminal or an endpoint of the network cannot. A revocation of a grant of the caller ends a debugging that the rule no longer gives. The same exports are called from the host through `remote` (`kerneltool call <key> "debugger.stack(0)"`), and the tool prints the source line from the repository when the file has the hash of the build. The kernel did not change.
- **A news entry can show a film**: an entry names a film with the line `film: docs/films/<name>.webm`, and the page of the news plays it when the reader starts it, with the picture of the entry in its place before that. `kerneltool film <name>` now writes a WebM file with AV1 beside its MP4 file, and puts it in the repository when an entry names it: for the film of the palette, 36.8 s of the whole screen, 1 572 784 bytes, half of the MP4 file. The entry of the palette has its film; the feed `news.xml` names it as an enclosure.
- **Each row of the palette has the icon of its kind**: a window, a program, a command, an export, a setting and an entry that destroys each have their own picture of 12 by 12 pixels at the left of the row, and the word of the kind stays at the right. The color of the icon says one fact, as the square mark did: a program that has a window is green and one that has none is dim, the window that has the focus is blue, the value of a setting in use is in the text color. The candidates of a field of a form have the icon of a module or of a grant. The icons are one table of cells, `support/kind_icons`, that the site draws too: a module or a command has the same picture on the site and on the desktop.
- **The program `heron` plays the animations of the mark**: start it from the menu of the programs or with `start("heron")`. The heron stands in its water in a window and plays its fifteen animations by the rule of the home of the site: each one once in a round, in an order of chance, still for about 40 % of the time. In the dash it leaves the window by the right and comes back by the left. A squash, a stretch and a travel are in whole square cells; the key `g` draws them in a free way to compare. The keys `1` to `9` and `a` to `f` play one animation, Space pauses, `.` shows the next frame, `s` plays slower, `l` shows the lines of the cells and the cells that a frame changes, `z` changes the cell size. The exports `heron.play("dash")`, `heron.animations()` and `heron.grid(1)` do the same from the console.
- **The site has a gallery, and the home a carousel**: the page Gallery shows 109 pictures of the screen in 11 groups, each with a caption of one sentence and a link to its guide; a picture opens at its full size. The home shows 8 of them in one row, one picture in view, with a numbered link to each; it works with no script and never changes its picture by itself. A picture of `docs/screenshots` that the table of the gallery does not name stops `kerneltool site`.
- **The program `heron` has a film**: `kerneltool film heron` films the heron while it plays, the dash at full speed and four times slower, the dash frame by frame with the changed cells outlined, one frame in the free way and on the grid, and the three cell sizes. The news entry of the program shows the film.
- **One generator for the pictures of the mark**: `kerneltool mark` writes the still mark, a frame of an animation, a tile map or its table, in the smooth variant (each pixel takes the gradient at its own place) or in the cells variant (each cell is one color), at a cell size and in a color scheme that the command names. The head of the home of the site and the window of the program `heron` keep the smooth variant; the bar and the icon of a tab are the cells variant, one pixel for a cell. The files of the mark of the repository and of the site are now one table, which `kerneltool mark uses` prints, and each PNG file of the mark is written at the smallest size that loses no pixel. A request with no sense, as the smooth variant at one pixel for a cell, is refused with a sentence.
- **The roadmap**: the planned work of the system is one file, `ROADMAP.md`, in three sections: what is in work now, what comes next, and what comes later. Each entry says what the work gives the user. The site shows it on the new page Roadmap, beside the page Releases, and the search finds each entry by its summary. `kerneltool roadmap check` checks the form of the file, and `kerneltool check` runs it.

### Changed

- **`remote` over QUIC**: the calls of the host go to `remote` over QUIC, one stream for each call, up to 8 at one time, with the public key of `remote` pinned by the host; its own datagrams are gone. Its listen grant admits the address of the host only, and a Retry proves that address, where one forged datagram made a call before. `kerneltool call` now takes the public key that the window of `remote` shows, and gives the call to the peer of the tool on a socket that only its user reaches.
- **The bar of the site stays at the top.** On every page of the site, the bar with the sections and the search stays at the top of the window while the page scrolls. A link to a heading or a symbol lands under the bar, not behind it.
- **References to documents on the site**: a comment of the source that names a document, as `(docs/ARCHITECTURE.md, "Kernel systems")`, is now a link with the title of the guide and the heading ("Architecture: Kernel systems") in a line "See:" after the text, with an icon of its own; code in backticks in a comment is shown as code; a guide that names another guide links to the heading too; the page of `kernel_without_return_check` says that it is the kernel built with a test setting; and `kerneltool site` stops on a pointer whose heading does not exist.
- **The tables of the site have their natural width, and a link goes to its anchor at once.** A table is as wide as its content needs, so a column of numbers or of names no longer holds empty room. The page no longer scrolls by itself to an anchor: it is there at once, also after a reload.
- **A chosen row keeps 4.5 to 1**: the chosen line of the completion list, of the menus of the bar, of the launcher and of the lists of the interface is now a slightly darker blue, where its white text has 4.67 to 1 in place of 4.29. A matched character on a chosen row of the completion list is drawn as the chosen blue on a white cell.
- **One Docs section on the site**: the bar names Docs, Status, News and Releases; the guides are now at /docs/guides/ and the reference at /docs/reference/, and each old address, in the .html form or the folder form, sends the reader to the new page. The new page /docs/ is the home of the docs: a large search field over the whole site, what the search knows, a card for the guides and a card for the reference with their counts. The bar of that page has no search field; every other page keeps the field of its bar.
- **A chart of what the search finds on /docs/**: the paragraph of counts under the search field is gone. Under the cards of the guides and of the reference, a bar chart gives the count of each kind of entry of the search, the largest first, each with the icon and the color that the list of results now shows for it, and a link to the page that lists the kind. While the field holds a text, each row shows how many entries of its kind match, and a press on a row keeps the list of results to that kind.
- **The cards of /docs/ list everything**: the card of the guides shows every guide with one line that says what it holds, and the card of the reference every reference table with its count. The chart of the search is under the reference, and no card has an empty part.
- **The card of the boot image names its files**: a size strip shows the bytes of each file by kind, and one row for each kind (programs, modules with no entry, resources) gives its count, its bytes and the whole names of its largest files; the boot image of the last build shows 12 names, where the grid of tiles showed 2. A line "check" counts the verified files, or names the file that failed its hash whole and in red, also in the strip and on its tile.
- **No test depends on the speed of the computer that runs it**: a time in a test only ends a test that hangs, with one generous bound (120 s for each step of a machine test, 60 s in the checks of a program, a stall of 60 s with no progress for a long case), and a number of speed is printed, never checked. The idle end of a QUIC connection and the bounds of a call stream of `remote` now check only that the end came no earlier than its bound, and print how late it came; `scheduler` checks that a wake ends turns under EEVDF and none under round robin, and prints how many times as often EEVDF woke as a measure.
- **A store holds trees of entries, and a program can give a part of it**: a store names one tree, and a tree holds objects and trees inside it, each tree a B+ tree on the disk with no limit of entries but the disk (the table of 39 objects is gone; the disk format is `STORAGE3`). Each export of the storage service takes a place (0 is the root of the connection) and a name of one step: `..`, `.` and `/` are refused. New exports: `open`, `close`, `add` (256 entries in one commit), `list` (a page in the order of the names), `rename`, `share` and `unshare`, `open_store` (the exports of versions take a place of it in place of the name of a store) (a connection rooted at a tree, read only or not, revoked by the kernel), `usage`; `remove` of a tree frees its blocks in steps after its commit; `objects` is gone. The program `hierarchy` makes 100000 objects in 1100 trees and checks them after a new start (`docs/STORAGE.md`).
- **The grant person is acts_for_principal**: `revoke("remote", "acts_for_principal")` in place of `revoke("remote", "person")`; `isolated.CALLER_PERSON` is `CALLER_ACTS_FOR_PRINCIPAL`, and the grant of a connection carries the number of the principal of the caller in bits 48 to 62. A refusal says "to act for the principal". `flood` writes "flood: Space: ...", and the console "error: Escape stopped the call of ...".
- **The chart of the search is under the search field of the docs home**: one bar of colored segments and one row of chips, one for each kind of entry, over the whole width, so the reader sees it change while typing; the list of results opens under it.
- **The scroll bars of the site have the form of those of the system**: a button with a triangle at each end, a square thumb with a grip, blue under the pointer, in both color schemes; Firefox shows their colors.
- **An object of a store is a tree of blocks, written by ranges**: an object can hold 4 TiB, and a block of zero bytes is a hole that costs no block (an object of 8 GiB from three writes holds 13 blocks; the limit of 32 blocks and the format `STORAGE3` are gone, the disk format is `STORAGE4`). New exports of the storage service: `read_range`, `write_range` and `set_size` (pending changes of the connection, with no commit and no hash) and `commit` (one commit of the pending changes, with the counts of the blocks that it hashed and wrote). A commit hashes the blocks that it changed and the nodes above them, never the whole object: 1000 writes spread over an object of 8 GiB hash 1001 blocks and 1018 object nodes. The check of a block of data is its BLAKE3 chaining value at its place, and the hash of an object comes from those values; a hole counts as zero in it. `write` and `read` of a whole object use the same mechanism. The program `ranges` and `kerneltool test ranges` test it, and a third loss of power comes in a loop of range commits (`docs/STORAGE.md`, "Large objects").
- **The glossary explains each term**: a term is an entry with a short definition that stands alone, then what it is for, how a program gets and uses it, what it is not, an example and a reference to its design. The groups Code, Running code, Access and Communication are written this way (201 terms), and a link to a term on another page shows its short definition as a tooltip.
- **The glossary is one page for each group, with an index from A to Z**: the single page had passed 1 MB. The index lists every term with its group and its short definition; each link to a term opens the page of its group, and an old address of an entry at the index goes on to it.
- **A table of the site is readable on a phone**: under 720 pixels of width a row is a block, with its first cell as its title and each other cell under the name of its column. A table no longer scrolls sideways there, and no column is squeezed to a few words a line.
- **A command of the console gives a result, and the console draws it by its kind**: no built-in command prints. `help`, `programs`, `modules`, `grants`, `principals`, `replacements`, `variables` and five more give a table that `where`, `sort` and `columns` take; `memory`, `load`, `isolate`, `connect` and `unload` give a record; an error shows its sentence, then the values of its error record. One drawer for each kind (number, text, record, table, handle, bytes, error) colors each value by its value kind, draws 20 rows of a table and says how many it does not show, and cuts no value. The log records of the programs that a line calls show under the line, read from the service `log`. `programs()` is now the export `monitor.programs()`. An integer of a line that does not fit in 64 bits is an error, not a wrapped number. New commands: `describe`, `program_modules`, `locks`, `loaded`, `bytes`, `skip`.
- **The manual reads the Markdown of the documentation of a module**: the program `manual` shows a bold word in the bold weight, a word in italics with a thin line under it, code in the font of the cells, a list item with its mark and its indentation, an example as a block, and a link as a colored name. A click on a link to a module or to an export of the boot image shows that page. A module now carries its documentation text with the marks of its comment; the line of help of an export stays plain, so `help()` in the console prints the same lines. A new library, `support/source_comment_markdown`, reads that part of Markdown with no allocator.
- **A program checks by count in a test and measures by time in a measure run**: `clock`, `flow`, `crowd`, `disk`, `locks` and `scheduler` no longer measure a rate for a fixed time at each start. Their windows and their log lines show the counts of their checks (for example "200000 records read in order, 0 lost"), and the rates in one second are in a measure run: `kerneltool measure`, `kerneltool measure scheduler` and the new `kerneltool measure clock|crowd|disk|flow|limits`. A measure run uses the same modules as the test; the value 22 of the context tells a program that it runs for a measure.
- **The console holds 256 commands**: the command table of the console has 256 places, where it had 192, for the 20 commands of the debugger and the exports of the service `debugger`.
- **The machine test takes a picture when the screen is settled**: the fixed time of 400 ms before each picture is gone. The compositor has the export `screen()`, and each row of `windows()` says how many pictures its program sent and whether one waits for a frame.
- **The site writes the name of the system in the letters of the mark**: the bar, the foot and the title of the home show "modus" as text in a font made from the cells of the mark (`resources/logo/modus_mark.ttf`, written by `kerneltool logo`). The pictures of the mark on a page are the heron alone, and the heron of the home plays an animation each 2.4 s on average, in place of each 4.7 s.
- **The trees of the site show tree lines**: in the documentation tree and in "On this page", a line of 1 pixel runs down from each parent and a branch goes to each item under it, as in a file tree, in place of indentation alone. The lines from the top of the tree to the current page are in the color of a link. "On this page" now puts each heading of level 3 and each symbol under its heading of level 2.
- **The network service computes no checksum of UDP or TCP, and reads each byte of a datagram or a segment one time**: the program checks the checksum of what it receives (`support/tcp` for a segment, `network.udp_data_read` for a datagram) and writes the UDP header and the checksum of what it sends (`network.udp_header_write`), so a `Send` and a `Receive` of a datagram endpoint now name the whole datagram, with its header of 8 bytes, 1480 bytes at most. The network service still refuses, in its own copy of the header, a source port that is not a local port of the endpoint and a remote that the grant does not name; a datagram or a segment with a wrong checksum now reaches the endpoint of its port, and the program drops it and counts it. When an endpoint ends, the log has the passes of the network service over its bytes: one on receive and one on send, where the passes were two on receive, and two on send for UDP.
- **The palette replaces the launcher**: the key super opens one panel that lists the programs and the windows in one ranked list, with the fuzzy match of the console and each matched character marked. Enter starts the chosen program or brings the chosen window to the front; the close of a window asks for a second Enter. The input band is the top of the panel, flush with its top, left and right edges, and the typed part is at twice the size of the font. The pointer chooses and runs a row too. The commands of the console are in the list too: a command with no parameter runs from the panel, which shows an Integer, a Text of one line, a Record or an error, and a Table brings the console to the front; a command with parameters gets a form in the input band, one typed field for each parameter, with the candidates that the console gives (programs, modules, grants); each value of each setting is an entry ("set font to spleen"); a first character restricts the list (`>` commands, `@` windows, `:` settings, `?` the manual); `shutdown`, `lock` and `history_clear` ask for a second Enter. The console has a new grant, `palette`: `revoke("console", "palette")` leaves the programs and the windows in the palette. The field `launcher` of `compositor.pointer()` is now `palette`, the state of the panel as a number, and the hint of the bar is "palette: super".
- **The drawing of a window is a module**: 23 programs with a window no longer hold a copy of the code that finds the damage of a frame and draws its records, its text and its blends. They import the module `drawing`, which has two exports, `damage_of_draw_table_7` and `execute_draw_table_7`: a window calls them two times for a frame, with its draw tables and the pixels of its surface by address, with no copy. The elements, the layout and the input stay in each program. The hash of each of these programs changed, and the module graph has one edge from each of them to `drawing`. The module `interface_module` keeps its six element exports and lost its two drawing exports. The build now refuses a `foreign` declaration of an import that does not agree with the description of the export: before, it built with no error. In a build of two programs alone, the file of `clock` went from 92 112 to 72 864 bytes and the file of `monitor` from 114 688 to 94 208 bytes (one build, QEMU with KVM for the times: the draw time of `clock` stayed inside the spread of two runs of the same code).
- **The heron of the home of the site has fifteen animations and moves most of the time**: eight animations are new: a dash in which the heron runs out of the window by its right edge and comes back by its left edge, with a squash at its start and at its stop; a hop; a fish that jumps in front of it; a doze; a stretch; the wind in its crest; a change of the leg it stands on; a flap of its wing. The heron is still for about 40 % of the time. Each animation plays once before one plays again, in an order of chance, and a visit keeps what was played from one page to the next. A reader who asks for reduced motion sees a heron that does not move.
- **The heron of the home squashes and stretches on its grid**: a cell of the heron is now a square of one size in every picture. Before, the dash, the hop, the stretch and the flap made the whole picture wider or higher, so the cells became rectangles. Now a squashed or a stretched heron is another drawing in whole cells (ten forms, from 20 to 32 columns and from 19 to 26 rows; the head, the eye and the beak are the same in each), and the heron travels by whole cells. The times of the animations did not change.
- **The bar of the site has three buttons and one menu**: Docs, Gallery and News are buttons, and a button "Project" opens a panel with Status, Releases and Roadmap. The six sections fit one line from a window of 720 pixels, with the search field. The gallery is one click from each page. The menu opens and closes with no script; under 720 pixels its three sections are lines of the site menu.
- **The scroll bar has arrow buttons, a thumb with a grip, and the pointer**: each scroll bar of the system is one element, 17 pixels thick, with an arrow button at each end, a track and a thumb with a border, a gradient, an inner line and a grip. The bar takes blue tones under the pointer. In a terminal and in `manual`, a press on an arrow button moves the view by one line and repeats while it is held, a press on the track moves it by one page, and the thumb follows the pointer. The scroll bars of the site have the same sizes and colors, from the same table, in the dark and in the light form.
- **The same module with and without debug information**: the build asks the compiler for a kind of debug information that adds no instruction to the code, `-debug-info:same-code`, an option of the fork of Odin that the flake pins. Each of the 89 modules is the same bytes with and without debug information, so the full check passes again. A debugger loses little: for `inspect`, the locations of the local variables cover 0.3 % fewer bytes.
- **The home of the site shows a line of time, charts and a release band, and every control shows its state**: the start of the machine is a line of time with two bars, each on a scale that the page states, a row with the name and the time of each stage, and a card for each stage that says what it does, which code runs it and where its guide is. The measures of the home are bar charts of one unit (the kernel entries with 1, 2 and 4 programs, the time of one glyph); a measure that is not such a chart is on the page of the measured numbers only. The newest release is a band with its number, its counts and its first changes as links. A news card with no picture has its text at its top. A click, a tap, Enter or Space on the heron plays an animation at once. Each button, door, numbered link and line of a menu shows the pointer, the focus and a press, in the colors of the desktop.

### Fixed

- **The search of the site finds the types.** A type of the contract, such as `Time_Record`, is now an entry of the search, and the result opens its card on the page of the types.
- **The tiles of the boot image show whole names.** On the home of the site, a tile of a small module was narrower than its name, and the name was cut. A tile is now at least as wide as its name.
- **Typing in the search of the site no longer scrolls the page.** Each key in the search field moved the page up a little.
- **The published site shows the measured numbers**: the page of the numbers and the start of the machine on the home said "Not measured in this build." for every number, because the site is built on a clean checkout with no machine test. They now come from the measure record that the last full check commits, and each row says which full check and which commit measured it.
- **The measure record names its commit.** The first record held bytes of a screen in place of the commit that it was measured on.
- **A refused measure is said, and the boot display shows whole names**: when the TPM refuses to measure the system description, the boot program tries 4 times, then the boot display says "TPM refused the measure" in red and the root service writes a warning, where before the display said "not measured" as for a machine with no TPM. The tiles of the boot image show the whole name of each module or no name, never a cut name, and the trust record takes one line under them. No text of the boot program lies over the boot display any more.
- **The icons of the values show with the page**: the style sheet now holds the 16 icons of the kinds of values, so a page asks for no file to draw them. Before, a browser asked for each icon alone after the style sheet, and on /docs/ an icon arrived up to 635 ms after the start, after the first paint.
- **An unmap gives back the page tables that it empties**: a page table that a mapping made returns to the budget that paid for it when the last mapping in it ends, at each level of the table. Before, it stayed until the program ended: a program that mapped at many addresses lost one page for each 2 MiB that it ever used, and a parent was one page short after its first child. An Uncommitted object of 1 GiB now keeps 0 pages after its unmap, where it kept 513.
- **The reference pages of the site show a list of names as a list, never as source code**: on the page of the grants, each grant of a program is a link to its row and the column of the reasons keeps its place; the imports of the modules, the edges of the module graph, the statuses of an operation, the parameters of a command and the gaps of a property wrap between their names. No page shows the bare name of a document any more, and a page that a cache kept from an older build says so, with a button that reloads it.
- **Faults of the QUIC library**: a server gives the remote of each connection that ended, also when the caller has few places for them; the handshake gives no packet keys after its secrets are erased; the bytes of the streams are erased when their connection ends; a server that names its preferred groups in EncryptedExtensions is accepted; a ClientHello with a session identifier closes with PROTOCOL_VIOLATION; a `preferred_address` that is malformed is a TRANSPORT_PARAMETER_ERROR; a connection closes for reserved bits only on a packet that proved authentic; and each error record names the argument at fault with the value that it had.
- **Small faults that a reading of the code found**: `Memory_Map` refuses a flag that the kernel does not know with `Bad_Operation` and a record `Bad_Flags`, as the other memory operations do; `kerneltool test <word>` refuses a word that is not a part, lists the parts and ends with the exit code 2, where it ran the whole test; a virtio device that does not finish its reset stops its device service with "the device did not finish its reset" after 1 000 000 reads of its status, where the service waited with no end; `life.glider` refuses a negative column or row, `paint.write` refuses a place that is not on the paper (x 0 to 479, y 0 to 295), and `math.gcd` refuses the most negative integer, each with an error record; the help of `settings.set` and `settings.get` says "a setting of the system".
- **A `Stop` and a `Resume` of `Thread_Control` no longer forgive what a thread owes**: a thread that a `Stop` took out of its run queue came back as a new thread, so a thread that had run more than its share ran again before the threads that waited. It now leaves the queue as a thread that starts to wait, and comes back as a woken thread.
- **The program `clock` no longer fails when its thread leaves its processor between two reads of the time**: it checked that a kernel entry and a read of the time page were at most 1 ms apart, which a busy machine does not give. It now checks that the time of a kernel entry is between two reads of the page around it.
- **A queue of threads that cannot run no longer keeps the other processors idle**: a processor that looks for work tried only the busiest other run queue. When that queue held only threads whose budget had no processor time left, the processor took nothing and went idle while threads waited in a third queue. It now tries the next busiest queue, each queue one time.
- **Keys typed while a line of the console runs keep their meaning**: a line ends when its result is drawn, and the save of the line history no longer holds the keys after it. Escape typed during a line that is in no call of a sandboxed program or of a service now waits in order with the other keys and acts on the edit line; before, it was taken out of order as a stop of the line, so a list that the keys before it opened stayed open.
- **A damaged TCP segment no longer ends a connection of `server`**: a segment from the remote of a live connection with a wrong checksum or a malformed option made `server` ask the network service to forget that remote, and the connection ended by a timeout. `server` now releases a remote only when no connection has it. The network service also keeps a listen port taken after a revocation until its endpoint is removed, and ends a Send that waits for the answer of ARP when the grant of its endpoint changes.
- **No key is lost in silence**: four queues between the keyboard and a program dropped a key with no count and no log line when they were full, and a typed line was lost once in a machine test. The input service now leaves the bytes in the keyboard controller while its ring to the compositor is full. The compositor keeps 256 records for a window whose ring is full and sends them in order. The console leaves the keys in its terminal ring while 128 keys wait for the end of a line. Where a writer cannot wait, each lost record is counted, and the log has one line when the loss begins and one with the count when it ends; `compositor.pointer()` and `compositor.windows()` give the counts (`keys_refused`, 0 on a system that works).
- **A refused debug access names the grant**: `debug("notes")` in the console, and `debugger.attach` from the host, now print "the debug access to this program: the grant Store of the program refuses it". Before, the sentence gave a number ("the grant 7 of the root service") that changed when a grant was added, and only the log of the root service gave the name. The list of the start grants and their names is now a contract, `contract/start_grant`, which the root service and the reader of an error record both read; the number of a start grant no longer changes.
- **The window of the program `heron` no longer shows a half-drawn heron**: during a fast move, one picture of the screen could show the head of the heron and none of its body, which a reader sees as a flicker. The program now draws a picture that the screen does not read, and the screen takes it when it is complete. Each key of the program also writes one line on the log: the pause, the speed, the cell size, and the frame that the window holds.

### Security

- **A program no longer reads where the kernel placed its tables**: on a processor with UMIP, `sgdt`, `sidt`, `sldt`, `smsw` and `str` of a program give a protection fault, where they gave the addresses of the segment table and of the interrupt table of the kernel; the kernel now writes its own control registers on each processor (an x87 error and an alignment check are faults of the thread on every machine, no breakpoint of the firmware stays on), and a boot line says whether UMIP is on.
- **A debug trap at the entry of the kernel no longer runs on a stack or with a gs that a program chose**: a program that runs `mov ss` or `pop ss` with the trap flag set, just before `syscall`, `int3`, `int1` or an instruction that faults, could, on a processor that gives the held trap at the first instruction of the kernel, make the processor push the frame of the trap on the stack of the program at privilege 0, or run the kernel with the gs of the program: the machine stopped, or values that the program chose went to an address of the kernel that it chose. The debug exception, the non-maskable interrupt and the machine check now have their own stack on each processor. The kernel drops each such trap with no code that reads gs; after `int1` the frame of the program is lost, and the kernel stops that program with the stop code of a debug exception. An NMI, a machine check or a double fault runs with the gs of the kernel and stops the machine with its line.
- **A program no longer sees the data selectors of the program before it**: the kernel did not keep `ds`, `es`, `fs` and `gs` for a thread, so a value that one program loaded stayed for the next program on that processor, a channel of a few bits between programs. Each return to a program now loads the null selector in each.

## [0.91.0] - 2026-11-12

### Added

- **The site shows the state and the reference of the system**: a status page gives each property with its status, the evidence and the gaps that name it, then every gap and the next steps; reference tables list the kernel operations, the context, the error kinds and units, the grants, the fixed ranges and the commands of the console, each row read from the file that defines it; each module has a page with its documentation and the signatures of its exports; the home shows the tiles of the boot image.
- **The documentation of the system as a site**: `kerneltool site` writes static pages in `build/site`: a home that shows the system, a guide for each document of `docs/`, reference tables (the glossary, the commands of the tool, the measured numbers, the licenses) and every release. Each page names the files and the commit that it comes from; the command checks every link, title and picture before it writes a page.
- **The mark on a transparent background**: `kerneltool logo` also writes `resources/logo/modus_transparent.png` and `modus_light_transparent.png`, and the README shows the one that fits the color scheme of the reader.
- **The news of the system**: a dated report in prose of each thing that a person can now see or use, one file of `news/` for each, beside the technical list of the changelog. `kerneltool news new` and `kerneltool news check` write and check them; the site shows them on its page News, the three newest on the home, a link from each release, and the feed `news.xml`. Eleven entries tell what the system shows from the vector font to the QUIC server.
- **A search on the site**: a box at the right of the bar finds a page, a module, an export, a kernel operation, an error kind, a command, a term, a section of a guide, a news entry or a release with the fuzzy match and the order of the console of the system, with no server and no request to another host. Up, Down, Enter and Escape work as in the console, `/` puts the focus in the box, and a search can be linked with `?q=`. With no script, the box is not shown and every page is reachable by its links.
- **What other sites read of the site**: `kerneltool site --address https://<host>/<path>` gives each page its canonical address, Open Graph with the picture of the mark, and one JSON-LD graph built from the page (the system, its source code, the guides as articles, the glossary as defined terms, the modules as a list, the news as posts), and writes `sitemap.xml` and `robots.txt`; the command checks all of them. With no address it writes none of them and says so. Each page also names a manifest, the new feed of the releases `releases.xml` and the guides before and after it, the site has an `llms.txt`, and the site writes each picture of the repository compressed, with the same pixels: a screen picture of the repository is stored with no compression.
- **The site on a phone, its author, and its publication**: under 720 pixels the sections and the search of the site are behind one square menu button, with one list of links and no inline script; the news cards of the home line up their titles, pictures and texts in a row; each page names its author from the line `Copyright` of `LICENSE`, in its head, in its JSON-LD graph and in the feeds; a GitHub workflow builds the site with `kerneltool` and publishes it on GitHub Pages at each push to `master`; the head of the home shows one short tagline, with the rest of the first paragraph of `README.md` lower on the page; and the site has a `favicon.ico` at its root, an SVG icon, an icon for a phone and a maskable icon, each drawn from the cells of the heron at a whole scale; and each table of the site gives each column the least width of what it holds (a date never breaks, a line of a log has room for about 60 characters), keeps the first column in view, and scrolls sideways in its own box, which the keyboard reaches, when it is wider than the page.
- **The heron of the home moves**: the large mark of the home of the site and the icon of its tab play seven small idle animations (a blink, a look, the raised leg, a ripple of the water, a dip of the neck, a preen of the back, a scratch of the ground) between still times of 2.2 to 5.5 seconds. Nothing moves for a person who asks for reduced motion, and nothing runs in a hidden tab. `kerneltool logo` writes `build/mark_animations.png` with every frame.
- **A program can repair its own page faults**: a program names one of its threads as its fault handler (`Fault_Handler_Set`); a page fault of another thread then does not stop the program but becomes a record in the thread record of the handler, and the thread waits until a thread of the program answers (`Fault_Answer`: resume, or stop with the report of today). Guard pages, a stack that grows and memory committed at its first touch need no policy in the kernel. The kernel has 31 operations; a full ring, a fault of the handler itself, and the end or the change of the handler while a thread waits stop the program, with a report. Only the program of a thread can answer for it.
- **The kernel records its own work for a program that has the grant**: a program with the new right Events on the machine gives the kernel a table of up to 16 rules (`Events_Set`, the 32nd operation of the kernel). The kernel then writes one 64-byte record into a ring for each processor for each operation of a kernel entry, switch of threads, fault or wait for a kernel lock that a rule accepts, filtered by program, detail, least duration or one in N. A full ring counts the records that it loses; the table ends with the program that gave it, or when its right is revoked; the address of a page fault is given only for a rule that names the program. With no rule, each event point costs one branch. The program `kernel_events` checks the exact counts.
- **The types of the site have a card, and the code has colors**: the new reference page Types shows each type of the contract, each wire form of the module contract, each record of a module and the basic types, with the size, the alignment, the fields with their offsets and padding, or the members with their values, all from the compiler. Each type in a signature, a declaration, a fact or a table of the reference opens its short card with a click, a tap, the keyboard or a pointer that rests on it. The declarations, the signatures and the Odin blocks of the guides are colored by the tokenizer of the Odin compiler when the site is built, with no script. The scroll bars, the selection, the focus and the marks of the site follow the palette of the system in both color schemes.

### Changed

- **The kernel runs its small instructions in place**: the ports, the model-specific registers, the control registers, `invlpg`, the read of the record of the processor and the copy of `user_copy` are instruction templates of Odin, which the compiler puts in the code of each caller with no call and no return; the code that owns the stack or the frame stays in the assembler file.
- **Shorter addresses on the site**: each page is now at a folder, as `https://modus.froment.software/reference/licenses/` in place of `.../reference/licenses.html`; each old address of a page opens a small page that sends the browser to the new address, so that links from before keep working; a site written with no address keeps links that a browser opens from a disk.
- **The documentation of the site has the layout of a documentation site**: each guide, reference page and module page uses the whole window, with the tree of the documentation at the left, the text in the middle and "On this page" at the right, which marks the part in view. Each kernel operation, command and export of a module is documented on its own with its signature, the text of its source comment and a link to its source line. The working record `FIRST_MILESTONE.md` is no longer a guide, and a new build never shows an old style sheet behind the cache of the proxy. Each technical value of the reference, the module pages and the status page (a handle, a number, a status, a type, a module, a file and the others) is in the monospace font, in the color of its kind, with a small pixel icon of its kind; the reference index has the legend of the kinds.
- **The pictures of the screen are compressed PNG files**: the kernel tool writes each PNG file with the encoder of the Odin standard library, so a picture of 1024 by 768 pixels is no longer 2.36 MB of stored data. The same pixels give the same bytes. `kerneltool screenshots compress` converts the pictures that are not compressed yet, with no machine, and checks each pixel of each converted file.

### Security

- **A program can no longer stop the machine at the return from the kernel**: a `syscall` in the last two bytes below the half of a program (its return address 2^47 is not canonical), or the flag nested task set with `popfq` before a `syscall`, made the processor fault in the kernel at its return, and the kernel stopped the machine. The kernel now checks the frame of each thread before it returns to it and stops that thread's program as its own fault, with the stop code 0x400 and the refused address in its stop report; it clears nested task at each `syscall`; and a fault at the return instruction itself is a fault of the thread.

## [0.86.0] - 2026-11-12

### Changed

- **The desktop names things in B612 too.** The buttons of the bar, its menus, the titles of the windows and the launcher are in the interface font B612, and the clock, the date and what the person types stay in Paper Mono; the buttons are as wide as their names in that font. The display of the boot, after its first screen, has its titles and names in B612 too.

## [0.85.0] - 2026-11-12

### Fixed

- **A QUIC server frees the connection of a client that went silent at its idle timeout**: a client that vanished while the server had data in flight kept its connection, and its place in the table of `quic_echo`, for about two hours, because each unanswered probe pushed the idle timeout further. It now ends after 30 s, whatever the probes. A replayed packet can no longer keep a silent connection alive, a server can no longer be started with no idle timeout, and `quic_echo` logs how long each idle end took against its bound.

## [0.84.0] - 2026-11-12

### Fixed

- **No text of the system is cut in silence**: a log line longer than 512 bytes was cut with no sign, and so was each text that a program formats in a buffer too small; the log now takes a text whole, in several lines, and a text that a place cannot hold ends with "... and N bytes more". The console refuses a program name longer than 31 bytes, which the root service cut before.

## [0.83.0] - 2026-11-12

### Added

- **The console keeps its line history across a stop**: after each line, the history goes to a store of its own in the storage service (4 blocks, apart from the store of the person), and at the next start Up and Control-R find the lines of before, also after a stop of the machine. history_clear() forgets it, in memory and on the disk.

### Fixed

- **The console prints a long result whole**: a result of more than 256 bytes was cut in the terminal and in the log with no sign, and a line of more than 192 bytes was cut in the log; the console now prints each result at any length.

## [0.82.0] - 2026-11-12

### Changed

- **Windows name things in B612.** The titles, captions, labels, buttons and lists of every window drawn with the interface package are in the interface font B612, and their values (numbers, typed text, tables, terminals) stay in Paper Mono; a window with no interface font draws everything in Paper Mono with the same layout.

## [0.81.0] - 2026-11-12

### Added

- **Programs can use AVX and AVX-512**: the kernel saves the extended state of each thread with `xsaveopt` (x87, SSE, AVX, and AVX-512 when the processor has it; one save writes at most 832 bytes with AVX and 2688 with AVX-512, and each thread entry of the kernel holds an area of 2688 bytes), sets `CR4` and `XCR0` itself on each processor, and logs what it saves at boot. A processor without `xsave` keeps the save with `fxsave`. A program reads what it can use with `support/instruction_sets`, and the program `extended_state` shows that each register of each thread is kept.

### Changed

- **A kernel entry no longer saves the vector registers of a program**: the kernel saves and restores the x87, SSE and AVX registers of a thread only when a processor leaves it for another thread, and the kernel itself has no instruction that uses them, which the build proves on each kernel that it makes. One kernel entry takes 120 to 124 ns where it took 176 to 178 ns (the machine of the test, two runs each), and one hand-over between two threads takes 125 to 133 ns with the registers saved and restored.

### Fixed

- **A program that used AVX no longer gets the high halves of its ymm registers from another thread**: before, the kernel saved only 512 bytes with `fxsave` and kept the `XCR0` that the firmware left, so AVX could work with wrong values and no error. Now a register state component is enabled only when the kernel saves it.
- **A reset QUIC stream no longer closes the whole connection**: when a stream was reset while flow control still held back some of its bytes, the reset named the bytes written instead of the bytes sent, and a correct peer closed the connection. The bytes of a stream are now erased from memory when the stream ends.

## [0.80.0] - 2026-11-12

### Added

- **Several streams in one QUIC connection**: a client of `quic_echo` can open 4 streams at once, and each one is echoed on its own, with its own flow control and its own reset; a lost datagram of one stream no longer holds the others. `kerneltool test quic` runs one client with 4 streams.

### Security

- **A QUIC server can no longer be stopped by a few dozen real addresses**: the budget of Initial checks of each address can no longer be renewed by addresses that take turns, so 33 hosts no longer stop every new client of `quic_echo`. A new address gets no check while the table of 1024 addresses is busy, and `quic_echo` counts it.

## [0.79.0] - 2026-11-12

### Added

- **The interface font is drawn.** The program `interface_font` shows B612 Regular and Bold placed with their pairs at a third of a pixel: a paragraph, three pairs with and without their adjustment, one word at the three positions of a pixel, the digits in columns, and the time of one line.

### Changed

- **The zero of the system is slashed.** Every window, the console and the terminal draw the character 0 as the slashed zero of Paper Mono, which its feature zero gives, so a 0 no longer looks like the capital O.
- **The caches of the interface font come with the system.** The two glyph caches of B612 are in the boot image, checked once by the root service and shared read-only by every program with a window, and a program learns which shared ranges it received from one value of its context; the program `interface_font` no longer builds its own caches.

## [0.78.0] - 2026-11-12

### Added

- **The time of one key of the completion list is measured**: measure_completion() in the console gives the collect, the rank and the rows of one key, for the names of the console and for 512 names of 128 bytes; in the quotes of connect and stop, a key no longer reads the programs that run again.

### Changed

- **The text of the console no longer moves when the line under the input comes or goes**: the terminal keeps one free row under the edit line, and draws the hint there; a hint that is too long for the window shows its short form.

### Fixed

- **The status line of a terminal names the lines of the text in view**: after a clear it said "line 738 of 737", because it counted the edit line as a line of the text; it now says "lines 709 to 736 of 737", or "none in view".
- **An export that fails in a sandboxed program or a service no longer changes a table of the console**: the console copied back the rows that a failed export wrote in a Change table; it now copies back only the table of error details, as the contract says.
- **A completion list shows only the rows that its program gave for it**: a list with no rows of its own showed the rows of the list before; when more names exist than the list reads, the line under the input says so.
- **A failed isolated call keeps the reason of its failure**: when the table of error details came back wrong, the error record of the export was replaced by a record about the table; it now stays, and a separate status says that the details are missing.

### Security

- **Long names of one length no longer slow each key of the console**: the order of two names in the completion list read whole names, up to 64 times for each name, so a service with long export names of one length made each key slow; it now reads at most 256 bytes of a name, and one key has a fixed bound.

## [0.77.0] - 2026-11-12

### Added

- **The mark in the system**: the heron is at the left of the bar of the desktop, in the place of the word "kernel", and the heron with the name modus is in the head of the boot display. Both are drawn from the data of `support/mark`, with no picture file in the boot image.

### Security

- **The program `settings` can no longer make the keys of the person get lost.** A new count of changes on the settings page with the same values made the compositor send one record into the ring of each window, the ring that also carries the keys and the pointer; it now tells the windows only when the values differ from the values that it told last.

## [0.76.0] - 2026-11-12

### Added

- **A QUIC server on the network**: `quic_echo` listens on the UDP port 4433 with QUIC in the program, writes back each stream, shows its public key, its connections and what it refused in its window, and makes no key when the random seed of the program is weak; `kerneltool test quic` runs a client of the host against it through the network service, with loss, many clients and a flood of forged packets.
- **A program can listen on a UDP port**: the network service gives a listen grant of UDP, which answers only the remotes that sent a datagram of 1200 bytes at least to the port, as the listen grant of TCP does for a SYN.
- **A test of QUIC against OpenSSL**: `kerneltool test quic-real` connects `openssl s_client -quic` of the host to `quic_echo` through QEMU user networking, pins the key that the machine printed, and checks the echo; the development shell has OpenSSL.

### Changed

- **`kerneltool test quic-real` reaches the machine through the peer of the tool**: QEMU user networking dropped every UDP datagram of the machine, so OpenSSL never received the Retry. The test now goes through a UDP relay of the peer on the loopback of the host, and on a failure prints each datagram that the relay carried and the close of the connection.
- **`quic_echo` logs why a connection ended**: the error code and the frame type of the close, and the reason phrase that the client gave.
- **`quic_echo` resists a flood of new connections better**: one host with a valid token can no longer stop the new clients of others, each token of a Retry takes a connection once, and the budgets of work for new connections refill continuously, so a burst at the turn of a second no longer gets twice the budget. Its log and its window count the Initials over the budget of one address and the tokens used again.

### Fixed

- **Two datagrams of a new QUIC connection that arrive together are both taken**: `quic_echo` lost the second one, and the client waited for its probe timeout. A connection whose client came back just after the server released it is now validated by the network service, so it is no longer held to 3 times the bytes that its client sent.

### Security

- **A QUIC server keeps nothing for a client that did not prove its address**: `quic_echo` answers a first Initial with a Retry and takes a connection only for a client that came back with its token, so forged source addresses no longer hold its handshake places; the work of new connections has a budget in each second.
- **The network service limits what a UDP listen grant sends to an unproven address**: at most 3 times the bytes that came from the remote, until the program marks it validated with the new command `Validate`; a send no longer keeps a remote admitted.

## [0.75.0] - 2026-11-12

### Added

- **The mark of the system**: a heron of square cells with one gradient in each part, and the name modus under it. `kerneltool logo` writes its files in `resources/logo` from the data of `support/mark`, at 1024 pixels on a dark and on a light background and at the sizes 24 to 768.

### Changed

- **Text over a gradient or a picture is drawn with the SSE2 blend.** The text of every window over a title bar or a picture takes the SSE2 form of the blend, with the same pixels as before.

### Security

- **No program chooses where another program reads its glyph caches.** The program `settings` could write the address and the size of the glyph caches on the settings page, and so make each program that started later read and draw memory that `settings` controlled; the caches are now at fixed addresses with their sizes in the context that the root service writes, mapped read-only for every program. A program also no longer waits for ever on a settings page left in the middle of a change.
- **A hostile font file no longer stops the reader.** A glyph made of thousands of empty parts made the font reader run for an unbounded time; the reader now stops at 64 parts, and a glyph cache whose monospace glyphs leave their cells, or whose header has unknown flags or a name with no end, is refused.

## [0.74.0] - 2026-11-11

### Added

- **The pointer theme and the grid fit are settings.** The window `settings` and `settings.set("pointer_theme", "system")` or `settings.set("grid_fit", "off")` change them while every program runs.
- **Settings survive a stop.** The font, the order of the color stripes, the pointer theme and the grid fit of the text are kept in the store of the program `settings` and come back at the next boot; a loss of power gives the old settings or the new ones, never a mix.
- **A module of text shaping, and the interface font B612 as data.** The module `text_shaping` places the characters of a text with the advances and the pair adjustments of a proportional font, and measures many texts in one call; the build makes the glyph caches of B612 Regular and Bold, which no window draws yet.

### Changed

- **The titles of the cards are bold.** Each card of a window and of the boot display draws its title in the SemiBold weight of the font of the system.
- **Text on cards and in the console draws faster.** A glyph of the vector font over a plain background costs 109 ns in place of 181 ns on the host (the least of many runs), with the same pixels.
- **Paper Mono is the font of the system.** The console, the terminal and every window draw their text in Paper Mono on the same grid of 8 x 16 pixels, in place of JetBrains Mono, and the titles of the cards in Paper Mono SemiBold.

## [0.73.0] - 2026-11-11

### Added

- **A caret in the line of the console**: Left, Right, Home, End, Delete and Backspace edit the line at the caret, and a character goes in at the caret.
- **A completion list in the console**: while the person types, a list under the line shows the commands, the exports, the services, the variables and the modules that match by a fuzzy match (`mcnt` finds `monitor.count`), the matched letters lit, each name with its signature; Tab or Enter takes one, and the line under the input shows the signature of the call at the caret.
- **A longer line history in the console, with a search**: 256 lines in place of 8; Control-R opens a search over them with the same fuzzy match, Control-R and Control-S move to an older and a newer line, and Enter puts the line in the input.

### Changed

- **A terminal gives its program the modifiers of each key**, so that Control with a key reaches the console; a cell of the text grid of the interface package can have a fill color (draw record version 5).

## [0.72.0] - 2026-11-11

### Changed

- **BLAKE3 hashes four chunks at a time**: in an input of more than 4096 bytes, the four chunks of each subtree of four chunks are compressed side by side in the SSE2 registers, with the same hash as before. The root service checks the hash of each module and resource at its start with it.
- **The text of the vector font is blended four pixels at a time**: the blend of a glyph over a pixel, in linear light with the three subpixel bands, runs in the SSE2 registers and gives the same pixels as before.
- **The pointer picture is blended four pixels at a time**, in the SSE2 registers, with the same pixels as before.

## [0.71.0] - 2026-11-11

### Added

- **A table of error details**: an export can give each thing that went wrong, not only the first, in an optional table of error records that the caller gives. A caller with no table gets the one error record of before. `monitor.counts_named` names each row that names no count, and the console and `kerneltool call` print each detail on its own line after the error.
- **A load names each missing import**: when `load` in the console fails because a module is missing or has the wrong hash, it prints a line for each import of the whole graph that is missing or wrong, not only the first.

### Changed

- **The call request of `remote` has 112 bytes**: it names the place of the table of error details, and the answer of a failed call carries the details and their count. The remote service refuses a request of a tool built before this change.

## [0.70.0] - 2026-11-11

### Added

- **A cryptography module**: the module `cryptography` gives ChaCha20-Poly1305, AES-128-GCM, SHA-256, HMAC, HKDF, X25519 and Ed25519 to each program, from the code of Odin's `core:crypto` with a check that proves each changed line; a tag or a signature that does not verify is an error with no byte given, and the program `cryptography_vectors` runs the published vectors through it and shows the speed of each primitive.
- **QUIC packet protection**: the library `support/quic` reads QUIC version 1 packet headers as hostile input, derives the Initial keys of a connection, and seals and opens packets with header protection, with AES-128-GCM or ChaCha20-Poly1305 from the module `cryptography`; it gives the packets of RFC 9001 appendix A byte for byte.
- **A program chooses how strong its random seed must be**: a key drawn with `random.fill_for_a_key` names the least seed strength that the program accepts (weak, processor or entropy), and a weaker seed gives the error "the random seed of this program has the strength ..." with nothing made; QUIC and TLS ask for processor at least.
- **TLS 1.3 for QUIC with raw public keys**: `support/quic` runs the handshake of TLS 1.3 for a client and a server, with X25519, Ed25519 and ChaCha20-Poly1305, and a client accepts the server only when it proves the public key that its caller pinned; no certificate authority and no X.509 are used.
- **A QUIC connection over memory**: `support/quic` runs one connection of QUIC with acknowledgements, loss detection, the probe timeout, flow control, one bidirectional stream, the idle timeout, the anti-amplification limit and the close, with the TLS 1.3 handshake inside; a test sends 1 MiB each way through a channel that loses 5 % of the datagrams.

### Changed

- **The context of a program has 24 values**: the values 16 to 23 are for the roles that the system fixes for every program, and the strength of the random seed is the value 16. The 16 values before were full, and two roles wanted one number.
- **TLS for QUIC refuses a configuration that would accept a weak seed or that pins no key, and takes a large ClientHello**: a least seed strength under processor, or a client pinned key of zeros, stops the start with an error; the transcript holds 8192 bytes; handshake bytes left at a level whose keys were replaced close the connection.

### Fixed

- **A QUIC packet no longer stops the program with its header protection sample**: a ChaCha20 sample that starts with `ff ff ff ff` gives its mask, and an Initial packet with a token of up to 2008 bytes is sealed and opened.
- **A thread with a short stack stops at its guard page**: the erasure of the stack after a cryptographic call writes from the top down, so no memory under the stack is written first; a thread that calls the module `cryptography` or draws random bytes needs 24 KiB of stack.
- **A QUIC connection no longer stops for ever when its data has many holes, and a forged Initial no longer takes a server**: data that had no place is not acknowledged, so the peer sends it again; a server takes a client only with an Initial that opens, and a handshake that does not complete within 10 s ends; an old packet whose number was forgotten is refused; a peer cannot move a timer into the past.

### Security

- **One datagram could stop a program that uses ChaCha20 for QUIC header protection**: the ChaCha20 code taken from Odin refused the block with the last counter, and the sender of a packet chooses that counter. The taken file has the correction as listed adjustments, and the correction is offered to Odin. No program used this path yet.

## [0.69.0] - 2026-11-11

### Added

- **A line in the draw table**: a straight line between two points with a thickness of 1 to 32 pixels. `rings`, `threads`, `workers` and `processors` now draw through the interface package.

### Fixed

- The window of `crowd` has the same margin at its right as at its left.
- **A dragged window stays reachable**: a window dragged to an edge of the screen keeps 8 pixels of its title on the screen, so a person can always take it again. Before, a drag to the right or bottom edge could put the whole window off the screen. A window wider than the screen now opens with its close button on the screen.
- **A new font reaches every window**: after a change of the font in `settings`, the terminal, the console and the manual draw their whole window again. Before, these windows mixed the old font and the new one.
- **The status line of a terminal stays readable**: in a terminal with no rates, the keys hint no longer runs over the status of the program, and a status with a very large total no longer gives a wrong bar.
- **No old pixels after a full command ring**: when a window cannot send its picture to the compositor, its next picture is drawn whole, so the screen never keeps the old pixels of that part.

### Security

- **The compositor takes only a surface that the program gave**: a program could name, in its command to create a surface, a handle that the compositor holds for another program. The compositor then showed the memory of the other program and closed its handle. The compositor now asks the kernel to prove that the handle came through the ring of the program, and closes each handle that it was given, also when it refuses the command.

## [0.68.0] - 2026-11-11

### Fixed

- A build in an empty folder could fail: two module processes of the parallel build made the same folder at the same time, and one of them stopped with "cannot create ... Exist".
- The report of a fault of the kernel no longer reads through the `gs` register (with the `gs` of a program that read faulted again, with no end and no report), a fault inside the report stops the machine with one line, and the wait for a line of another processor is bounded in time, not in loops.

### Security

- **One program could stop the machine**: a thread made with a first instruction that is not an address of a program made the processor fault in the kernel when the thread first ran, and the kernel stopped the machine. The kernel now refuses such a thread, and such a stack.

## [0.67.0] - 2026-11-11

### Added

- **Every program gets versions of its data.** The storage service keeps the state of an object before each change, with no save action and no code in the program: a program, or the person through the console or the host, lists the versions of an object, reads one, compares two, restores one (the state before the restore stays a version) and clones an object, which shares its blocks until one side changes. Each version is kept for 10 minutes, then one an hour for a day, then one a day, by the smaller of its age by the date and its age in running time, so a clock that was wrong on one start thins nothing; at the limit of a store the oldest versions go first, and a change that cannot fit with no version is refused. A version that a damaged block makes unreadable is dropped at the next change of its object, which still works. A disk of the earlier format is not read.
- **Undo to any earlier note in notes.** Up and Down step through the versions of the note, with the date of each, Enter restores the version shown, and Escape goes back to the current note.
- **The system knows the date.** The bar shows the date and the time of day in UTC, the HTTP server sends the field Date, and each version keeps the date of its change. The date comes from the clock of the machine, read again each 10 seconds; the service date gives it to a caller with now(). The clock gives the years 2020 to 2099; a clock with an empty battery, or a reading that is not a date, gives no date, and the bar then shows the time since the start.

## [0.66.0] - 2026-11-11

### Added

- **A program drives its own virtual memory**: a memory object made `Uncommitted` holds a range of addresses (1 GiB in one mapping) and its budget pays only for the pages that the program commits; `Memory_Commit` commits and decommits tables of ranges, and a decommit gives the pages back to the budget at once; `Memory_Protect` changes the protection of pages, with `No_Access` for a guard page; an object made `Large_Pages` is mapped with pages of 2 MiB. The program `address_space` shows each case with its numbers.
- **A test of the real shortage of page frames**: a machine of the test gives one program nearly all the memory; its four threads take every frame, the kernel takes back the frames that sit in the stacks of the processors, and every frame returns.

### Changed

- **Two new kernel operations and a narrow right on budgets**: the kernel has 29 operations (`Memory_Commit` 28, `Memory_Protect` 29). A commit names the budget that pays for the object; the new right `Commit` on a budget handle lets another program commit pages of that object and nothing else, so a program can let another one grow its object without letting it create objects on its budget.

### Fixed

- **A program that maps and unmaps no longer grows its page tables**: a mapping with no address takes the first free range between the mappings of the program; before, each such mapping took a new range and new page tables until the budget refused (a call host refused its 61st call).

## [0.65.0] - 2026-11-11

### Added

- **Tables and bytes as parameters**: an export takes a table of records or a run of bytes, to read, to change or to append to, in memory of the caller. The same description works in a direct call, in a call host and in a service; the console, `kerneltool call` and `remote` take a table as an argument. A table of 65536 records can pass as a memory object, with no copy.
- **The interface package as a module**: `interface_module` gives the elements of the interface through exports that append to the draw table of the caller, and `interface_through_module` draws its window with it.

### Fixed

- A picture or a text grid that changed its index in the draw table, with the same size, was not drawn again.

## [0.64.0] - 2026-11-11

### Changed

- **The compiler runs on all its threads, with no patch**: with the release dev-2026-11a of Odin, the same source gives the same module for any count of compiler threads (20 builds of each of the 64 modules, one result each). The patch of 0.59.0 and the option `-thread-count:1` are removed.

## [0.63.0] - 2026-11-11

### Changed

- **The compiler is Odin dev-2026-11a**, pinned by the flake itself: the system used the release of May through Nixpkgs. The instructions `rdrand` and `rdseed` are `asm` templates of the new compiler, inline in the code, and the copied ChaCha20 is taken again from the new release.

## [0.62.0] - 2026-11-11

### Added

- **The changelog**: `CHANGELOG.md` lists what each release of the system brings, from the first milestone (0.0.0) to step 59 (0.59.0). A branch adds one fragment in `changelog.d/` for each change; `kerneltool changelog new`, `check`, `assemble`, `release` and `notes` write, check and release them, and `kerneltool release_number` prints the release number.

### Changed

- **`kerneltool build` builds the modules in parallel**: one process of the tool for each module, each with one compiler on one thread, as many at once as the processors. The modules and the boot image are the same bytes as with one process.

### Fixed

- **The kernel reports its own fault as whole lines**: the report took no lock, and a line of another processor arrived mixed with it on the serial port, so nobody could read the fault. The processor that reports is now the only writer.
- The machine test lost typed keys on a loaded host (`start("fetch")` arrived as `start("ETCH")`). The tool now sends a key only after the compositor received the key before it.

## [0.61.0] - 2026-11-11

### Added

- `kerneltool measure windows` starts each window of the interface package alone and prints the time of its pictures with the load of the host; above a load of 8 it says that the table is not valid.

### Changed

- **The compositor draws its screen as one draw table** of the interface package: the frame of each window, its surface, the bar and the menus. The terminal draws its view as one text grid, and `paint`, `plasma`, `temple` and the boot display use the package too.
- **Windows sit on the grid of 8 pixels**: a new window, and a window that the person moves, has its corner on the grid.

### Fixed

- The terminal showed rows of two frames: with two pictures, a frame presented only its difference with its own picture, and the screen showed the other one.
- A card cuts its caption to the room between its title and its count, and the boot display cuts a fact after its last whole word.

## [0.60.0] - 2026-11-11

### Added

- **Each program has a random generator**: ChaCha20 with fast key erasure, in the memory of the program. A draw makes no kernel entry and no call. The starter of a program writes its seed of 32 bytes in the context values 9 to 12, and a start with a seed of zeros is refused.
- **The seed of the system**: the root service gathers it at its start from `rdseed`, `rdrand` and samples of the cycle counter, mixed with BLAKE3, and logs its strength: "entropy", "processor" or "weak". A machine with neither instruction starts and says "weak". The program `randomness` shows these facts.
- **ChaCha20 from `core:crypto` of Odin**, copied into `support/cryptography` with only its imports changed. `kerneltool cryptography-origin`, which the check runs, proves that each copied file is its origin, pinned by its hash, with the listed changes only.

## [0.59.0] - 2026-11-11

### Added

- `kerneltool repeat all <count>` builds every module and the boot program again and again, and gives one row for each: the count of distinct modules, LLVM IR files and objects. `kerneltool check` and `kerneltool repeat` keep each distinct result beside the first one.

### Changed

- The rewrite of the LLVM IR of 0.53.0, which fixed the names of static variables, is removed: the cause is corrected.

### Fixed

- **One source gives one module**: the Odin compiler started one worker thread beside its main thread also with `-thread-count:1`, and the two threads changed the order of the declarations. A module could differ from one build to the next (`host` in 1 build of 12 to 39, `console` with 3 distinct LLVM IR files in 60 builds). The flake applies a patch of 91 lines to the compiler: with `-thread-count:1` the main thread runs each task. `kerneltool repeat all 100` gave one module, one LLVM IR file and one object for each of the 61 modules and the boot program.

## [0.58.0] - 2026-11-11

### Added

- **A vector font is the text of the system**: every window, the console, the terminal and the boot display draw JetBrains Mono (SIL OFL 1.1) with subpixel bands, blended in linear light. The font is monospace on the grid of 8 by 16 pixels, so no window changes its size; the scales 2 and 3 are drawn from the outline.
- **A glyph cache in the boot image**: the build draws each character 32 to 126 at three scales, in fixed point, into one file of 390 624 bytes. The root service checks its hash once and maps it read-only into each program. One glyph from the cache takes 309 ns, against 35 ns for Spleen 8x16 (in the machine of the test).
- **The program `settings`**: the person chooses the font (the vector font or Spleen 8x16) and the order of the subpixel bands (`rgb`, `bgr`, `none`), and every window draws again while it runs. `settings.set("font", ...)` does the same from the console. The setting is not kept across a stop of the machine.
- **`kerneltool vector_fonts`** makes ASCII subsets of six candidate fonts (14 to 21 KB each, with their licenses in `resources/fonts`) and a picture that compares them.

### Changed

- **The default font is the vector font** (owner, 2026-11-11). Spleen 8x16 is the fallback and a choice of the person. The value 13 of the context of each program with a surface names the settings page.
- The rasterizer of the vector font works in fixed point. It replaces the prototype in floating point of 0.51.0.

## [0.57.0] - 2026-11-11

### Added

- **A loss of power, tested**: the kernel tool serves the data disk over NBD and sees each write and each flush. At a loss of power during the commits of `notes`, it builds the 306 images that a real disk can hold (72 with a torn write) and opens each one on the host: 227 give the last durable commit, 79 the commit in flight, none a mix. A second machine starts on a hard image, and `notes` restores its text. `kerneltool test power` runs it.
- **Error records in the other calls**: a ring completion that fails holds an error record (the block, frame, datagram, network control and root rings), and the wrappers `display.open`, `terminal.open` and `system.ring_open` take one. `start`, `stop`, `connect` and `revoke` in the console write the cause of a refusal of the root service.
- `errors` has 25 cases on two pages: one case for each family of calls.

### Changed

- `paint.line`, `paint.write` and `tally.add` refuse with an error record what they cut or dropped with no word before.

### Fixed

- `log.records` (0.47.0) left places of its result empty. It fills each place now, and a long text comes in two rows with a continuation mark.

## [0.56.0] - 2026-11-11

### Changed

- `server` accepts the absolute form of a target, reads HTTP/1.2 as HTTP/1.1, and ignores two empty lines before the request line (RFC 9112). Each answer says `X-Content-Type-Options: nosniff`, and an answer to HTTP/1.0 with keep-alive says `Connection: keep-alive`.

### Fixed

- The body of a request that is not `/sink` was read as the next request. The server now ends that connection after its answer.
- A refused `server.put` changed the bytes that the server served, and a refused `server.remove` gave 404. Both now ask the store first.

### Security

- **One segment held a connection record of `server` for ever**: a whole request and one more byte. 24 such connections from each of two addresses took the 48 records. The bytes left after an answer now start the time limit of the next head: 408 after 10 s.
- **A `server.put` or `server.remove` while a remote read that page** made the server read past the page and stop, or serve mixed bytes. Each page has a generation now, and an answer whose page changed ends with a RST.
- A connection that the server had closed had no time limit. The limits now run until its last byte leaves.

## [0.55.0] - 2026-11-11

### Added

- **Pointer pictures**: the compositor draws the pointer from a theme file, with its hot spot, and chooses the shape from what is under the pointer. A program asks for a shape over its own surface (`display.pointer_shape_set`). The program `pointers` shows each shape of a theme.
- **Posy's Cursor is the default pointer theme.** The build converts it from an input of the flake; no file of it is in the repository, because its license is CC BY-NC 4.0. The theme of the system, 15 shapes as grids of squares, is the fallback.
- **Resources of the boot image**: a file with a name and a hash, which the root service checks and gives read-only to one program. The pointer themes are the first ones.
- **`kerneltool pointers`** converts a text manifest (`resources/pointers/*.manifest`) and a folder of Xcursor files to a pointer theme file. It reads the Xcursor files as hostile input.

### Changed

- The log keeps 2047 records (1023 before).

## [0.54.0] - 2026-11-11

### Added

- Draw records version 2: `Folded_Gap`, and `Picture` (the pixels of a picture of the program, with a generation that the damage sees). `life` draws its board as one picture, and a frame with no change draws nothing.

### Changed

- **The interface package draws the windows of 19 more programs**: `inspect`, `scheduler`, `manual`, `life`, and `locks`, `net`, `errors`, `monitor`, `budget`, `rights`, `origin`, `limits`, `frames`, `imports`, `flow`, `crowd`, `disk`, `tally`, `notes`. None of them has a direct drawing call left.

### Fixed

- In a text input, Enter after typed characters now activates the text so far, and the keys after Enter in the same frame are not taken.
- A frame with more than 16 keys lost the keys after the 16th. They now wait for the next frame.
- A `Present` of the whole surface from a place of its own damaged the screen past the window. It damages the window only.
- The prototype of the vector font wrote a cell outside its row for a vertical edge on the last column.

## [0.53.0] - 2026-11-11

### Added

- **A cache of free page frames on each processor**: a stack of at most 256 frames under its own lock, so a page on first use takes its frame with no frame lock. With 4 programs that work at once, the waits on the frame lock fell from 303 382 to 405 521 to under 2 000, and pages on first use rose from 4.79 to 6.49 million to 7.3 to 8.1 million in one second (`locks`, the machine of the test).
- **`kerneltool measure scheduler N`** runs the program `scheduler` alone N times. `kerneltool measure without_checks` and `kerneltool run without_checks` build the kernel with no check of the lock order and of the sums of the frames.

### Changed

- The test build checks the sums of the frames at each report; the measure build has none of the checks of the kernel. The checks cost about 30 % of the rate of system reports.

### Fixed

- The name of a static variable changed from one build to the next, so two builds of one source could give two `kernel.module` files. It is the same now.

## [0.52.0] - 2026-11-11

### Added

- **An HTTP/1.1 server**: `server` keeps connections open, answers pipelined requests in order, answers `HEAD`, and gives the statuses 400, 404, 405, 408, 413, 414, 431, 501 and 505. Its pages are in its private store: `server.put` and `server.remove` change them from the console, for a caller that acts for the person. `PUT` and `DELETE` over the network give 405, because the network has no authentication. No TLS, no chunked body, no ranges.
- `web.request_read` reads a request head as hostile input (8192 bytes, 64 fields, 1024 bytes of target at most), with host tests of each bound and of 50 000 damaged heads.
- The window of `server` has a table of the last requests, and each request has a log record.

### Fixed

- `GET /hello` from `fetch` took 43 ms: `fetch` waited for its own ACK timer of 40 ms. It takes 2.7 ms.
- A full command ring lost places in `server` and `fetch`. A command that the ring does not take now waits for the next pass.
- A simultaneous open never ended, and a passive open that a RST ended gave no event.
- A SYN to a full table of connections now takes the oldest record in TIME-WAIT at once. With a new connection for each request, `server` answers 239 to 250 requests in one second, against 4 before.

### Security

- **A listen port could be closed for good**: any segment admitted its sender, so a bare RST from 64 source ports took the 64 places of the admitted remotes. Now a remote is admitted only on a SYN, when a Receive waits, from an address that can answer. A place with no segment for 60 s serves again.
- **32 silent connections from one host filled `server`**: it never freed a connection that made no progress. It now ends one after 10 s, and one address holds at most 24 of its 48 records.
- A RST with data was accepted after the cut, zero-window probes never gave up, and a half-open connection held a record for about 243 s. Each is closed; 18 host tests cover the hostile cases, and 15 of them failed before their correction.

## [0.51.0] - 2026-11-11

### Added

- **The interface package** (`support/interface`): a program describes each frame as a table of draw records of 40 bytes in its own memory. The damage is the difference of two tables, the layout is one pass on the grid, and Tab, Enter and the arrows reach each element. `clock`, the window of `remote` and the launcher use it: `clock` draws one picture in 12 to 14 us, against 109 us before.
- **The program `interface_elements`** shows each element of the package live, the draw table of the last frame, and the damage of each frame.
- `display.present_rectangle`: a program names the part of its surface that changed, and the compositor draws only that part again.
- **A prototype of a vector font**, as research: the program `vector_glyphs` shows DejaVu Sans Mono at 13, 16 and 32 pixels beside Spleen 8x16, from a reader of a TrueType subset that checks each read.

### Changed

- **The close button of a window is a deep red** (`0xB82232`), brighter under the pointer and quiet on a window that is not in front: the color of the concept "stop a program" (owner, 2026-11-11).

## [0.50.0] - 2026-11-11

### Added

- **The developer tool `inspect`** shows one program live: its address space as a band with folded gaps, its mappings with the pages that have a frame, its modules with their hashes, its threads with the fields of the scheduler, the stop report of a stopped program as `module + offset`, and a hex view of its own memory. It reads no byte of another program. A sample takes 34 to 63 us.
- Four reports of the kernel for the right Inspect: `Program_Mappings`, `Threads`, `Stop` and `Pages`. The exports `inspect.mappings`, `inspect.threads` and `inspect.modules` give the same facts to `kerneltool call`.
- `errors` keeps its stopped program `fault` until the next run of its case, so that a developer tool can show its stop report.

## [0.49.0] - 2026-11-11

### Added

- **The system has its own copy and fill of memory** (`runtime/memory.asm`) in every module, in the kernel and in the boot program: `copy_bytes_without_overlap`, `copy_bytes_with_overlap` and `fill_bytes_with_value`, with forms chosen by measure. A copy of 4096 bytes takes 34 ns in the machine, against 1170 ns with the loop of 0.45.0. The first use of a page went from 830 ns to about 700 ns.

### Changed

- 20 programs take the colors of the design rules from `support/graphics`.

## [0.48.0] - 2026-11-11

### Added

- **TCP, as a library in the program** (`support/tcp`): an open from each side, reassembly, the retransmission timer of RFC 6298, Reno with NewReno, zero-window probes, the FIN states, RST, and the challenge ACKs of RFC 5961. A connection is one record of 400 bytes in the memory of the program, and one call `tcp.step` serves a batch.
- **A segment endpoint** in the network service, with a client grant (one remote, 64 local ports) or a listen grant (one port, and the remotes that send to it). The network service checks the TCP checksum and the ports of each segment, and keeps no state of a connection.
- **The programs `server` and `fetch`**: a small HTTP server (`GET /`, `GET /large`, `POST /sink`) and a client with eight cases. The TCP of the host fetches 1 MiB from `server` through QEMU user networking (libslirp), a stack that this project did not write.
- The test runs a TCP client in the kernel tool against `server`, with seeded loss, reorder and duplicates. 1 MiB from `server` took 52.9 ms in one run, under load.

### Changed

- The network service is also on the data path of TCP segments (one copy, the IPv4 header, the checksum, the grant). The note of property 5 says so.

## [0.47.0] - 2026-11-11

### Added

- **The compositor is a service**: `compositor.pointer()` and `compositor.windows()` give the place of the pointer, the windows, the focus, the keys, the open menu and the launcher. The kernel tool reads the pointer before each press of the test, and moves it again until it is at the place of the step.
- **`log.records(after)`** gives the log as a table of typed records. The test reads 11 of its checks through it.
- `monitor.counts()` gives the scheduling strategy and its changes.

### Changed

- `kerneltool call` reads and hashes each module file one time: a call that confirms the place of the pointer takes 0.3 ms, not 3.7 ms.
- `monitor` writes no log line for each call, and `remote` writes one sentence for a refusal.

## [0.46.0] - 2026-11-11

### Added

- **Three scheduling strategies** behind one interface of six functions: round robin, fair (the idea of CFS: a virtual time and weights) and EEVDF. A program with the right `Schedule` changes the strategy while the machine runs (`Strategy_Set`, operation 27).
- **Wake preemption**, also on another processor: a woken thread no longer waits for the end of a slice of 10 ms when each processor is busy.
- A thread has a weight and a request, given at `Thread_Create`. A program can only lower its weight.
- **The program `scheduler`** measures four cases under each strategy and changes the strategy 100 times under load. Two threads that wake each other beside a spinner on each processor: round robin 80 to 84, fair 461 732 to 498 800, EEVDF 313 601 to 332 954 wakes in one second (three runs, while other tests ran on the host).
- `docs/SCHEDULING.md`: the research note on CFS, EEVDF and `sched_ext`.

### Changed

- **EEVDF is the strategy at boot.**
- The machine handle has one more right, `Schedule`. The kernel has 27 operations.

## [0.45.0] - 2026-11-11

### Added

- **The launcher**: the left Super key opens a panel, each typed key narrows the list of programs, the arrows move the choice, Enter starts the program, and Escape closes it.
- The title bar of the window in front goes from the blue `0x3F7CC4` to a darker blue at its right.

### Changed

- **The desktop follows the design rules**: the bar, the menus as cards, the window frame, the pointer and the background are rectangles on the grid, in the colors of one table (`support/graphics/rules.odin`). The close button is no longer red, because red means "failed" in the rules.
- `support/launcher` is now `support/bar`.

### Fixed

- `graphics.copy` called the `memcpy` of the freestanding Odin runtime, which copies one byte at a time. A full frame with 15 windows took 26.6 ms; it takes 2.1 ms.

## [0.44.0] - 2026-11-11

### Added

- **A call from the host**: `kerneltool call "monitor.programs()"` calls an export of a service of the machine that `kerneltool run` started, and prints the typed result. The program `remote` relays the call to the services that its grant names (`manual`, `monitor`, `storage`), and refuses a call for another module hash. The calls go over UDP with no authentication: while `remote` runs, a program of the host that sends to its port acts for the person.
- **`monitor` is a service**: `programs()`, `counts()`, `count()` and `served()`.
- The person starts `remote` from the menu, and `revoke("remote", "person")` cuts its right to act for the person.
- The test step `Call` checks typed results in place of lines of the log.

## [0.43.0] - 2026-11-11

### Added

- `system.nanoseconds()` gives a fine time from the cycle counter, with no kernel entry. The time page has the cycle counter at the time 0.

### Fixed

- The milliseconds of the time page lost the ticks that came late on a loaded host. They now come from the cycle counter: `clock` shows the page 0 to 3 ms behind it.

## [0.42.0] - 2026-11-11

### Added

- **Errors that diagnose**: a kernel operation that fails gives an error record of 56 bytes in its completion record: the kind, the operation, the number of the argument, its value, the limit, and what the kernel found. An export gives one through its last parameter. There is no global last error, and a call that succeeds runs none of this code.
- **A fault gives a stack trace** from the frame pointers, one line for each frame (`module + offset`).
- The storage service, the manual and `math` give error records, and the console writes each record as a sentence.
- **The program `errors`**: 19 cases, each one an error made for real, with the sentence of its record.
- `kerneltool repeat <module> <count>` builds one module again and again and compares each build with the first.

### Changed

- Each module is compiled through LLVM IR and `llc`, to keep the frame pointers. A call through a slot takes 4.1 to 4.8 ns, against 3.6 to 3.7 ns before.

## [0.41.0] - 2026-11-10

### Added

- **The program `locks`** measures kernel entries, pages on first use and the word wait with 1, 2 and 4 programs that work on their own objects, then stops 120 programs under stress. `kerneltool measure` runs it with only the desktop. `memory()` and `monitor` show the takes and the waits of each kind of lock.

### Changed

- **The kernel lock is split by data**: eight kinds of lock in one order that the kernel checks at each take, a lock for each program, and a run queue for each processor. No kernel entry takes a lock for all the kernel; the control lock serves only the paths that cross programs. With 4 programs at once, kernel entries went from 2.78 to 3.25 million to 6.68 to 7.24 million in one second, and pages on first use from 1.62 to 1.82 million to 3.32 to 3.63 million (three runs, only the desktop).
- An idle processor, or one with less load, takes a waiting thread from the queue of another processor.

## [0.40.0] - 2026-11-10

### Added

- **The first layer of the network**: a frame service drives the virtio network device, and the network service speaks Ethernet, ARP, IPv4, ICMP echo and UDP. A program gets an endpoint whose grant names one remote. The kernel has no network code.
- **The program `net`** shows ten cases with their answers, and its measures: the round trip of a datagram of 64 bytes in 60 to 88 us at least, and 57 886 to 81 733 datagrams in one second with 64 in flight, 0 lost (ten runs).
- A frame from the wire never faults the network service: a malformed frame is a refused row of an endpoint or of the machine, which `net` reads with the right Inspect.
- `revoke("net", "network")` ends the endpoint of a program that runs.
- The time page has the frequency of the cycle counter.

## [0.39.0] - 2026-11-10

### Added

- `docs/DESIGN.md`: the design rules, taken from the boot display. Each thing on the screen is a fact of a record, each form is a rectangle, one color is one concept, one font in three sizes, a grid of 8 pixels.

### Changed

- **A new boot display**: a path of ten steps of the start, the stages as one tube on a line of time, cards, and a tile for each module of the boot image in the color of its hash. No form has a round corner.

## [0.38.0] - 2026-11-10

### Fixed

- **One build gives one hash**: the threads of the compiler changed the order of the functions, and 13 of 48 modules differed between two builds in one folder. The compiler now runs on one thread, and 0 differed in three builds. `kerneltool check` builds the modules two times and compares them.

## [0.37.0] - 2026-11-10

### Changed

- The format of the data disk is a contract (`contract/store`), which the storage service and the kernel tool read.

### Fixed

- **A wrong block under a valid root damages one object, not the storage service.** Before, it stopped the service for every program. The service takes the root before the newest one when only the newest names a wrong block.
- A damaged object is never read as an empty object: `size` answers -8, and the client gives the status `Damaged`. Before, `notes` wrote over its note after a disk error.
- A data disk whose first format a stop cut is formatted again. Before, the service refused it for good.

### Security

- A program could change the name of an object in the call region between the check of the storage service and its use. The service now copies the name one time, then checks and uses the copy.

## [0.36.0] - 2026-11-10

### Added

- **Functions that give the information of the modules**: the manual serves tables of the modules, their exports, their imports, who imports a module, the replacements, and what runs, read from the flat tables and from the module records of the kernel. All 45 modules and their 65 exports take about 150 us. The system has no SQLite.
- **The console combines tables** with `where`, `sort`, `join` and `columns`.
- A description can have a Table result, and Text fields of a fixed size in a record.
- A malformed module gives a `Problem` with its sentence, never a fault.

## [0.35.0] - 2026-11-10

### Added

- **The code of an imported module is one copy** for all the programs that one starter starts, at any base. The program `imports` starts two programs that import `calendar` at two places.

## [0.34.0] - 2026-11-10

### Added

- **Replacement of an import**: after `replace("calendar", "calendar_fixed")`, each next load uses the corrected module in place of the faulty one, and the module that imports it does not change. The loader checks the description of each export that a slot uses, and refuses a module whose description changed.
- The kernel keeps the module records of each program (`Program_Module`, operation 26), and the stop report names the module that ran.
- The program `imports` shows the loader in its cases: a call through an import slot takes 3.5 ns.

### Changed

- The kernel has 26 operations.

## [0.33.0] - 2026-11-10

### Added

- **A program loads a module with imports**: the loader finds each import by its hash in the files that the program was granted, loads each module one time, and binds its slots. The console loads `agenda`, which imports `calendar`.
- A failed load gives a record with its detail (`Load_Error`): the stage, the module, the import, and the hash that the load source does not have.

## [0.32.0] - 2026-11-10

### Added

- **A persistent program**: `notes` keeps a note and a count in its private store across a restart of the machine; each key is one commit. The test runs four machines on one data disk: a clean stop, an end of QEMU during 1000 commits, and a cut root block.

## [0.31.0] - 2026-11-10

### Added

- **The storage service**: each program has a private store on the data disk, named by the root service, with a limit in blocks. The engine is new: copy on write, two places for the root block, and a check in each pointer.
- The storage service starts at the first connection. `storage.stores()` lists the stores for the person, and `revoke(name, "store")` cuts the grant of a program.

## [0.30.0] - 2026-11-10

### Added

- **A block service**: a program drives a virtio disk through device memory, a message interrupt, and memory with a physical address. The root service finds the device on the bus and gives it.
- The program `disk` measures it: with 32 requests in flight, 165 000 to 300 000 blocks read in one second, with one kernel entry for 10 to 20 requests (two runs).
- `Memory_Physical` (operation 25) gives the physical address of a memory object to a holder of the right Physical.

### Changed

- `Device_Create` makes device memory and message interrupts. The kernel has 25 operations.

### Fixed

- A Ports handle that a program received while its ports were open on the processor did not open its ports, and the program stopped on a protection fault.

## [0.29.0] - 2026-11-10

### Added

- **Shared code**: the programs of one module map the same pages of code and constants with no Write, each with its own writable data. Four programs `twin` use 311 pages in place of 320.
- The programs `frames` and `twin` show ten cases of pages on first use and of shared code, each with the answer of the kernel.

## [0.28.0] - 2026-11-10

### Changed

- **Pages on first use**: a memory object reserves its pages in its budget at its creation, and gets each page frame at its first use. There is no overcommit. An object of 8192 pages is ready in 74 us, against 2 560 us with all its frames at once; the first use of a page takes 722 ns.
- The frames of a memory object are in a frame list, not contiguous. The reports and `memory()` show the reserved pages.

## [0.27.0] - 2026-11-10

### Added

- **The menu of the windows** in the bar: a press on the title of a window brings it to the front.

### Fixed

- The kernel tool read lines of the log that QEMU had not finished. It was a cause of a machine test that failed sometimes.

## [0.26.0] - 2026-11-10

### Added

- **Limits of a budget**: a limit of processor time and a limit of log records for each second. The kernel counts processor time with the cycle counter and applies the limit in each period of 100 ms. A limit counts in each budget above.
- `thread_start` takes a budget. The program `limits` runs three threads at 5 %, 20 % and 60 % of one processor.

## [0.25.0] - 2026-11-10

### Added

- **Revocation of a grant**: the kernel keeps the origin of each handle and each mapping, and `Handle_Revoke` (operation 24) ends all that came from a handle. A lent handle is revoked after its call.
- The root service records its grants: `grants` and `revoke` in the console. The program `origin` shows twelve cases.
- `Handle_Give` with the target 0 copies a handle in the same program.

### Changed

- The kernel has 24 operations. A lent handle costs its caller 5 kernel entries and 2000 ns (2 entries before).

### Fixed

- The compositor wrote past its table of windows when it removed a window with 17 programs open, and stopped on a bounds check.

## [0.24.0] - 2026-11-10

### Added

- **Records and handles in a description**: an export takes a Record (bytes with described fields) and a Handle, which is lent with the rights of the description and ends with its call. The console has Record and Handle values: `Rectangle(1, 2, 30, 4)`, `buffer(1)`, `byte(b, 4095)`.
- `Handle_State` (operation 23) proves where a handle came from.
- The module `sample` shows a record and a lent handle in an isolated call.

### Changed

- The kernel has 23 operations.

## [0.23.0] - 2026-11-10

### Changed

- **The console runs in a terminal** and has no surface. The terminal sends key records to its program, and the program owns its edit line. The root service starts a program and its terminal together.
- A terminal draws after a change only.

## [0.22.0] - 2026-11-10

### Added

- The command `kerneltool` in the development shell.

### Changed

- **Two source libraries**: `contract:` (what two parties agree on; the kernel compiles with it only) and `support:` (what a program compiles in). An import names its library; no relative import is left.

## [0.21.0] - 2026-11-10

### Added

- **One module in each role**: `tally` runs as a program, as a service, as a library in the console and as a sandboxed program, with the same hash.
- **A module carries its documentation**, and the program `manual` shows it: the exports, their parameters, and the ways to use the module.
- `unload` in the console removes a module.

## [0.20.0] - 2026-11-10

### Added

- **The time page**: the kernel writes the time in one page that each program reads, so `system.time()` does not enter the kernel. `clock` reads it 879 to 1 491 million times in one second, against 1.9 to 2.4 million with a kernel entry (four runs).

## [0.19.0] - 2026-11-10

### Added

- **A shared queue**: several writers and several readers with no lock, and an event that several threads wait on. `crowd` moves 33.9 million records in one second with 1 writer and 1 reader, with 2 to 6 kernel entries for one million records (alone in the machine).

## [0.18.0] - 2026-11-10

### Added

- **The terminal**: a program sends typed records of text with a style, with no escape sequence. A reader thread and a drawer thread show them, and the display does not slow the program: `flood` writes 1.7 to 3.0 million lines in one second (five runs).
- A surface can have two pictures.
- `kerneltool film` films the terminal.

### Fixed

- A ring of 0.17.0 could lose a wake.

## [0.17.0] - 2026-11-10

### Added

- **A ring has a capacity, chosen at its creation**: one wake serves many records, and `wait_spin` spins a short time before it waits. `flow` moves 29.8 million records in one second with a capacity of 1024 and `wait_spin`, with 56 kernel entries for one million records (one run).

### Changed

- A full ring slows its writer to the speed of its reader: a ring does not grow.

## [0.16.0] - 2026-11-10

### Added

- **A program that runs serves its own exports**: `connect("paint")` in the console, then `paint.line(...)`. The root service makes each connection, and a call has the same description and the same form as the call of a module. `paint` and `life` serve exports.

## [0.15.0] - 2026-11-10

### Added

- **The log is records in channels**: each record has a time, a program, a thread, a level, a channel and a text. The kernel is the one writer; a reader maps the records with the right Read. The program `log` shows them.

## [0.14.0] - 2026-11-10

### Changed

- **The launcher is a menu**: one button in the bar opens one line for each program.

## [0.13.0] - 2026-11-10

### Added

- **Paging protects the kernel from itself**: guard pages around each kernel stack, no page writable and executable, the direct map not executable, SMEP and SMAP, and one place where the kernel uses the memory of a program (`user_copy`).
- Six tests of the kernel on itself: each one does a thing that the page tables refuse, and checks the report of the fault. The program `pages` shows what the page tables give.

## [0.12.0] - 2026-11-10

### Added

- **The boot display**: a boot record with the stages of the start, drawn by the boot program, then by the root service, then by the program `boot`. A start that fails keeps the display, with its cause.

## [0.11.0] - 2026-11-10

### Added

- **Several processors**: the kernel runs on each processor under one kernel lock, with a processor record and a timer for each. `processors` shows four processors that run one program: a picture takes 404 ms with 1 thread and 148 ms with 4 (one run).

## [0.10.0] - 2026-11-10

### Added

- **Budgets**: no kernel operation creates an object from nothing. A memory object, a program and a thread take a budget handle with the right Spend. `Budget_Create` and `Budget_Read` are operations 21 and 22. The program `budget` shows each page come back.
- The log is an object: `Log` takes a Log handle with the right Write.

### Changed

- The kernel has 22 operations.

## [0.9.0] - 2026-11-10

### Added

- **Rights on handles**: each handle has a set of rights, `Handle_Give` copies a handle with fewer rights, and an operation without its right gives `No_Right`. The machine is one object with the rights Inspect, Devices and Stop. In the program `rights` the kernel does four operations and refuses five.

## [0.8.0] - 2026-11-10

### Changed

- **Descriptions come from the source**: the kernel tool reads the name of each parameter and the help from the comment of each export, and the test checks them.

## [0.7.0] - 2026-11-10

### Added

- **The console runs a line in a second thread**: it keeps the keys during a call, and Escape stops an isolated call.

### Removed

- The limit of 2000 ms of an isolated call. The person decides with Escape.

## [0.6.0] - 2026-11-10

### Changed

- **One wait**: rings wait on words, and each thread has an event word.

### Removed

- The operation `Wake(memory)`. The kernel has 20 operations.

## [0.5.0] - 2026-11-10

### Added

- **The word wait and a lock**: `Word_Wait` and `Word_Wake` (operations 19 and 20) on a word in shared memory, and `system.Lock` as a library over them. `workers` shows four threads on one number, and one queue of 140 tiles.
- The kernel tool writes the boot volume itself.

### Changed

- The kernel has 21 operations.

## [0.4.0] - 2026-11-10

### Added

- **Several threads in a program**, each with its own kernel ring: `Thread_Create`, `Thread_Stop` and `Thread_State`. `threads` draws one square from each of five threads.

### Changed

- The kernel has 19 operations.

## [0.3.0] - 2026-11-10

### Added

- **Text results**: an export writes text into a buffer of the caller and gives a count of bytes.

## [0.2.0] - 2026-11-10

### Added

- **The program `rings`**: six programs pass records through six rings, drawn live from the shared memory. A stopped program takes no record: the records wait in its ring.

## [0.1.0] - 2026-11-10

### Added

- **The isolated call**: `isolate("probe")` in the console runs a module in a call host, a sandboxed program with no handle, and calls its exports through a ring. A module that faults or loops stops alone.

## [0.0.0] - 2026-11-10

### Added

- **The system boots under QEMU to a desktop**: a UEFI boot program loads the kernel module and the boot image. The kernel has one entry point and runs the operations of the kernel ring of each thread (16 operations). The root service starts the other programs in user space and grants their handles.
- **The console**: integers, texts, variables, arithmetic and typed commands. `load("math")` makes the exports of a module commands.
- **The desktop**: the compositor with a bar, a clock, windows, focus, drag and close; it draws only the damaged rectangles. The programs `monitor`, `plasma`, `life`, `paint` and `temple`; `fault` shows that a fault stops one program only.
- **The module format**: a module is named by the BLAKE3 hash of its content. The kernel tool converts a linked ELF image to a module, builds the boot image, and tests the machine under QEMU.
