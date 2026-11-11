# The line of the console

Status: built on 2026-11-11, except section 6 (a design).

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
- One ranking reads at most 4096 names (`CANDIDATE_SCAN_LIMIT`), and keeps the best 64 (`RANKED_CAPACITY`). One key costs at most 4096 x 320 steps, about 1.3 million. The console reads at most 512 names today (`CANDIDATE_CAPACITY`: 128 commands, 8 services, 16 variables, the modules of the boot image, 64 programs), so 10 000 exports of one service never reach the list: the console refuses a service whose commands do not fit in its table.
- The console measures each ranking with the cycle counter, and writes the longest one on the log when Tab opens a list ("one ranking takes N us at most, over K keys").
- A name of 0 bytes is not a name. A byte of a name under 32 or over 126 is drawn as `?` by the terminal; a line takes only the bytes 32 to 126, so such a name cannot go in a line.

## 5. Who draws the list

The console knows the names; the terminal owns the cells and the keys. The console sends the rows to show (`terminal.List_Row`: the name, what it is, the places that matched) and then the list (`terminal.List`: the count of rows, the chosen row, the place of the first row in all the names and their count, and the byte of the edit line where the name starts). The terminal lays it out: under the edit line and its hint line when the rows below hold it, above the edit line if not, at the column of the start of the name, as wide as the longest row and cut to the terminal. It has at most 8 rows, and a scroll mark at the right when there are more names.

So no record has a place on the screen, and the terminal stays a program with no knowledge of the language of the console. The rows go through the text region of the console and its terminal: no third program reads it, and the terminal already shows each name that `help()` prints.

The look follows `docs/DESIGN.md`: the cells of the list have the card color, the chosen row the blue of the title bar, the matched characters the accent, what a name is the dim color at the right of its row; a border of one pixel in the color of the kernel, as the menus of the bar; no shadow, no round corner. A cell of the text grid has a fill color for this (`interface.Text_Grid_Cell.filled` and `background`, draw record version 5): a cell is 12 bytes in place of 8, and the damage by difference redraws only the rows of the list that change. The border is four records after all the others, so the records before keep their places when the list opens or closes.

## 6. The line history across a stop (a design, not built)

Today the history lives in the memory of the console: 256 lines at most in a ring of 16 384 bytes (`line_editor.History`), and fewer when the lines are long (81 lines of 200 bytes). A line never wraps at the end of the ring, so each line is one slice of it. The same line two times in a row is kept one time.

The design that keeps it across a stop:

- The console holds the grant `Store` (the root service gives it). It writes the `History` record as one object of its private store, `line_history`, at most once each 10 s while lines are entered, and at `shutdown()`. One write is one commit: a loss of power keeps the old history or the new one, never a part.
- At its start, the console reads the object into its `History` record. The record is data that the console did not write in this run: `history_line` checks each start and each length before it reads a byte, and `line_set` makes each byte that is not printable a `?`.
- Nothing runs on load. A line of the history goes into the input only when the person takes it (Up, or Enter in the search), and runs only at the next Enter of the person. A hostile line in the store (a damaged disk, an older console) can show wrong text; it cannot run.
- A line can hold a secret that the person typed. The history needs a command that empties it and its object (`history_clear()`), and the store keeps versions (property 9): the clear removes the object, which ends its versions too.
- Without the grant `Store`, the console keeps the history in memory only, and says it once on its log.
