# The line of the console

Status: built on 2026-11-11. Section 6: the file form is built and tested; the console does not write it yet (section 6 says why).

The console owns the line that the person edits: its bytes, the caret, the line history, and the completion list. The terminal draws them and gives the keys. The procedures that change the line are in `support/line_editor`: they have no state of their own and make no kernel call, so host tests run each key (`support/line_editor/line_editor_test.odin`). The console uses them in `programs/console/main.odin` and `programs/console/completion.odin`.

## 1. The keys

| Key | List closed | Completion list open | History search open |
|---|---|---|---|
| A character | Goes in at the caret; opens the list at the first character of a name | Goes in at the caret; the list follows | Goes in the search |
| Left, Right, Home, End | Move the caret | Move the caret; the list follows | Nothing |
| Backspace, Delete | Remove the byte before, after the caret | The same; the list follows | Backspace removes a byte of the search |
| Tab | Opens the list (one name: it goes in at once) | Takes the chosen name | Takes the chosen line |
| Enter | Runs the line | Takes the chosen name; if the name is already the name at the caret, runs the line | Takes the chosen line: it goes in the input, and does not run |
| Up, Down | An older, a newer line of the history; after the newest, the line that the person typed | The choice moves | The choice moves |
| Control-R | Opens the history search | The choice moves down (an older line in the search) | The choice moves down: the next older line of equal score |
| Control-S | Nothing: no line is newer than the line that the person types | The choice moves up | The choice moves up |
| Escape | Nothing | Closes the list; the next character opens it again | Closes the search; the line stays as the person typed it |

Control-R and Control-S: the console tests the character of the key (`r`, `s`) with the modifier Control, not the code of the key. The input service gives the character of the US layout from the table of the Shift state, and gives it also when Control is held: the machine test sends `ctrl-r` and `ctrl-s` through QEMU and they work. With Shift also held the character is `R`, and the console takes the key as no search. The system has only the US layout today; with another layout, the input service gives the character of that layout, so Control-R follows the letter R wherever the layout puts it, as the person reads it on the key. A test of the code follows the place of the key instead, and breaks with such a layout.

While a line runs, each key but Escape waits, in order, and the edit line shows them (`|` Enter, `<` Backspace, `>` Tab, `^` a key with no character). Escape stops an isolated call, as before.

A chosen name replaces the whole name at the caret, also its part after the caret, up to a dot. A command or an export gets its `(`, unless a `(` follows; a name in quotes gets its closing quote, unless one follows.

## 2. What the console completes

| Where the caret is | The names | From |
|---|---|---|
| A name with no dot | Each command (with its full name: `monitor.count`), each connected service, each variable | The command table: the commands of the console, and the exports of the modules and services, from their descriptions |
| After `owner.` | The exports of that service | The commands that start with `owner.`. If none does, the whole name is matched against all the names |
| Inside the quotes of the first argument of `load`, `isolate`, `start`, `replace` | The modules of the boot image | The image that the root service granted |
| Inside the quotes of `connect`, `stop`, `grants`, `revoke` | The programs that run | `Inspect` on the machine, with the grant that the console holds. The root service has no command that lists its services: the console asks for none, and gets no new grant. With no grant to inspect, the list names the services that the console is connected to |
| Inside the quotes of `unload` | The modules that `load` and `isolate` added | The table of the console |

Not completed: the second argument of a call (the grant names of `revoke`), the fields of a record variable (`r.x`), the common start of several names (the list replaces it).

When the call at the caret is open, the line under the edit line shows its signature, dim, from the description, and marks the parameter at the caret: `write(name: Text, data: Text) -> Integer`.

## 3. The fuzzy match

The characters of the query appear in the name in their order, with gaps allowed: `mcnt` matches `monitor.count`, `stwr` matches `storage.write`. Lower and upper case are equal. The match finds the first place where the whole query has matched (a pass forward), then the latest start before it (a pass back): the shortest window that ends there. The places of that window give the score, and the list draws the same places in the accent color.

| Rule | Points | Why |
|---|---|---|
| Each matched character | +16 | A longer query that matches says more |
| A match at the first byte of the name | +32 | The person types names from their start |
| A match right after `.` or `_` | +24 | The start of a part of the name |
| A match right after the match before | +16 | A run that the person typed, held as one run |
| A gap between two matches | -3, and -1 for each byte of the gap after its first | A spread match is less likely what the person means |
| A tie | The smaller tie order, then the shorter name, then the order of the bytes | The history gives the age as the tie order: the newest line first |

The tests pin these orders on real names of the system (the exports of `monitor`, `storage`, `manual`, `compositor`, `settings`, `date`):

| Query | Order |
|---|---|
| `mcnt` | monitor.count (123), monitor.counts (123), monitor.counts_named (123), manual.replacements (94) |
| `cnt` | monitor.count (84), monitor.counts, monitor.counts_named, compositor.pointer (81), manual.replacements (59) |
| `set` | settings.get (112), settings.set (112), storage.stores (69), storage.write (67), storage.restore (67), storage.objects (65), manual.segments (64) |
| `mod` | manual.modules (104), monitor.served (65), monitor.counts_named (59), compositor.windows (34) |
| `stwr` | storage.write (144) |

The pass back takes the latest place of each character: `set` in `manual.segments` takes the second `e`, not the `e` beside the `s`. A search of the best window costs more work for each name; the order above is the result of the bounded rule.

## 4. The bounds, and the cost of one key

Each bound holds against a description that another program wrote:

- The match reads at most the first 128 bytes of a name (`NAME_SCAN_LIMIT`): two passes of 128 and 64 places of score, at most 320 steps for a name. A longer name matches only in its start.
- A query of more than 64 bytes matches nothing.
- One ranking reads at most 4096 names (`CANDIDATE_SCAN_LIMIT`), and keeps the best 64 (`RANKED_CAPACITY`). The place of a name in the kept ones is a binary search: at most 7 orders of two names. An order reads at most 256 bytes of the names (`NAME_COMPARE_LIMIT`, a whole line of the history); after them the shorter name comes first, and two names of one length are equal. The search of the history skips a line equal to a kept one: at most 64 compares of 256 bytes for each line. So one key costs at most 4096 x (320 + 1792 + 64) steps, about 8.9 million, and one key of the search at most 256 x (320 + 1792 + 64 + 16 384), about 4.8 million. Before, an order read whole names: long names of one length with a long common start made a key cost names x 64 x their length. The console reads at most 512 names today (`CANDIDATE_CAPACITY`: 128 commands, 8 services, 16 variables, the modules of the boot image, 64 programs), so 10 000 exports of one service never reach the list: the console refuses a service whose commands do not fit in its table.
- The console measures each ranking with the cycle counter, and writes the longest one on the log when Tab opens a list ("one ranking takes N us at most, over K keys").
- When the names are more than the console reads (512), the line under the edit line says it: "N names match, and more names than the list reads: type more characters" (short form: "N names and more").
- A name of 0 bytes is not a name. A byte of a name under 32 or over 126 is drawn as `?` by the terminal; a line takes only the bytes 32 to 126, so such a name cannot go in a line.
- In the quotes of `connect`, `stop`, `grants` and `revoke`, the console reads the names of the programs that run once, when the quote opens (up to 64 `Inspect` calls), and keeps them while the caret stays in that quote and no line runs. A key in the quote makes no kernel call.

The measure: the command `measure_completion()` times the three parts of one key with the list open, for the query `mcnt`: the collect (the table of names), the rank (the match of each name, and the best 64), the rows (the text of the 8 rows that the terminal receives). Each number is the least of 20 batches of 10 keys, in microseconds. It writes two lines: one for the names of the console as they are, one for the worst case, 512 names of 128 bytes whose matched characters are far apart, so that the two passes read each whole name:

```
console: one key with the completion list: the collect N us, the rank N us, the rows N us, over K names (the names of this console, the least of 20 batches of 10)
console: one key with the completion list: the collect N us, the rank N us, the rows N us, over 512 names (512 names of 128 bytes, the least of 20 batches of 10)
```

The main machine and `kerneltool measure` (the machine with only the desktop and `locks`) run it. The command runs in the second thread, with its own table of names: the list of the first thread stays as it is.

## 5. Who draws the list, and the line under the edit line

The console knows the names; the terminal owns the cells and the keys. The console sends the rows to show (`terminal.List_Row`: the name, what it is, the places that matched) and then the list (`terminal.List`: the count of rows, the chosen row, the place of the first row in all the names and their count, and the byte of the edit line where the name starts). The terminal lays it out: under the edit line and its hint line when the rows below hold it, above the edit line if not, at the column of the start of the name, as wide as the longest row and cut to the terminal. It has at most 8 rows, and a scroll mark at the right when there are more names.

So no record has a place on the screen, and the terminal stays a program with no knowledge of the language of the console. The rows go through the text region of the console and its terminal: no third program reads it, and the terminal already shows each name that `help()` prints.

The look follows `docs/DESIGN.md`: the cells of the list have the card color, the chosen row the blue of the title bar, the matched characters the accent, what a name is the dim color at the right of its row; a border of one pixel in the color of the kernel, as the menus of the bar; no shadow, no round corner. A cell of the text grid has a fill color for this (`interface.Text_Grid_Cell.filled` and `background`, draw record version 5): a cell is 12 bytes in place of 8, and the damage by difference redraws only the rows of the list that change. The border is four records after all the others, so the records before keep their places when the list opens or closes.

The line under the edit line (the hint line) and the list are drawn over the grid. The terminal keeps one free row under the edit line at all times, with or without a hint: the hint is drawn in that row. So the text never moves by one row when a hint comes or goes. When the view follows the text, the free row is the last row of the view, and the edit line the row above it. The list opens under the free row when the rows below hold it; when the edit line is near the bottom, it opens above the edit line, over the text.

A hint line has two forms: a long one, and a short one for a terminal that is too narrow (`terminal.hint_form_choose`): the long form when it has no more bytes than the columns; if not, the short form when the program gave one; the form chosen is cut to the columns. The console gives a short form for the list ("12 names. Tab: take. Esc: close") and for the search ("search: leng  2 lines. ^R ^S Enter Esc"); a signature has one form, cut at the right.

The status line of the terminal names the lines of the text that the view shows: "lines 709 to 736 of 737", or "lines none in view of 737" when the view shows no line of the text. The edit line and the free row are not lines of the text. Before, it named the first row of the view as a line: after `clear()`, the terminal forgets its lines and the first row of the view is the edit line, so it said "line 738 of 737".

## 6. The line history across a stop

The history lives in the memory of the console: 256 lines at most in a ring of 16 384 bytes (`line_editor.History`), and fewer when the lines are long (81 lines of 200 bytes). A line never wraps at the end of the ring, so each line is one slice of it. The same line two times in a row is kept one time.

**The file form is built** (`support/line_editor/history_file.odin`, host tests in `line_editor_test.odin`). Version 1, numbers in little-endian order: `LHST`, the version, the count of lines, the count of bytes of the lines, then the lines, the oldest first, each one a byte with its length and its bytes, and at the end the BLAKE3 hash of each byte before it. `history_file_write` keeps the newest lines that fit in one block of the storage service (4096 bytes: 20 lines of 200 bytes, about 120 lines of 30 bytes). `history_file_read` empties the history first, then checks the size, the magic, the version, the hash, the count of lines, the count of bytes, the length and each byte of each line, and the count of lines against the bytes, before it adds any line. A file that fails a check gives an empty history and the name of the check, for one log line. A line from the file goes into the input only when the person takes it (Up, or Enter in the search), and runs only at the next Enter of the person: nothing runs on load.

**The console does not write the file yet.** It holds what it needs: the root service gives it the grant `Store`, and its private store comes with a connection to the service `storage` (`connect("storage")`, through the root ring: the console has the role `Person`, so the root service makes no store connection at its start). Three facts of the system stand in the way, and each one needs a decision of the owner:

1. **The store of the console is the store that shows the limit.** The root service gives the console 4 blocks, "a small limit: the test reaches it", and the main machine checks its exact state: "the call needs 5 blocks in all", "1 objects, 0 versions, 3 of 4 blocks". A history object takes blocks of the same 4, so each of these checks changes, and a write of the history at the limit fails.
2. **The storage service starts on demand.** A write of the history at the first line entered starts the storage service and the block service at the start of the console, not at `connect("storage")`. The main machine checks those starts as log records much later ("root: started block for the device at the place 16 of the bus"); the ring of the log has lost them by then.
3. **Each commit advances the generation of the disk.** Each check that names a generation moves: "[console] 2" and "[console] 3" for the writes of the person, the generations of `notes`, and "storage: ok, generation 1022" in the machines of persistence, where the console types `shutdown()`.

Two forms keep the properties; each one changes the checks above one time, and the coordinator runs the machines that show the new numbers:

- **A second store for the console, for its history only** (a store named for its use, with a limit of 2 blocks: the file and the version before it). The store that the person fills keeps its 4 blocks and its checks. It is a new grant of the root service: property 20 asks for a grant for each resource, so it is a decision of the owner.
- **The store of the console, with a larger limit**, and the check of the limit moved to a program that has no other use of its store (`errors` already has a limit of 2 blocks). No new grant; the history and the objects of the person share one store, and `storage.objects()` shows the history.

In both, the storage service starts with the first line entered, and the checks of its start and of the generations move. With either one, the plan stays: write the file at most once each 10 s while lines are entered, and at `shutdown()`; read it at the start; `history_clear()` empties it and removes the object (its versions end with it). Without the grant `Store`, the console keeps the history in memory only, and says it once on its log.
