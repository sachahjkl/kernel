# The palette

The palette is one panel that a key opens. It reaches every operation that the principal of the session can do: start a program, bring a window to the front, close a window, run a command of the console with its arguments, set a setting. It replaced the launcher, and the term launcher left the system (`docs/DECISIONS.md`, D-236).

What the panel looks like and what each key does is in [`docs/DESIGN.md`](../../../docs/DESIGN.md), "Palette". The provider is in [`docs/CONSOLE.md`](../../../docs/CONSOLE.md), "8. The palette provider". This file records why the palette has this form.

## The problem

Before the palette, two programs held every operation. The compositor held the windows and the start of a program. The console held all the rest: the root ring, the calls of the services, the settings, the principals, the grants, the debugger, the shutdown. "Every operation from one panel" asks for a panel that reaches both sets.

The language of the console is not a set of operations. `where` and `columns` have no meaning alone, and a form with one field for each parameter cannot give a Table. So "every operation" is each act, and one step to the console for a composed line.

## The constraints

- **No ambient access.** A broad grant is rare, visible and revocable. A second program with every grant, beside the console, doubles the richest target of the system.
- **The typed text reaches no program that does not need it, and no program can draw a false palette.** Only the compositor keeps both: it keeps the key super, and it draws over each window.
- **No text between programs.** If the compositor builds the text `revoke("net", "network")` and the console parses it, one program prints and another parses.
- **The loop of the compositor waits for no program**, and does no work in proportion to a table that another program wrote.

## The chosen form: a panel and a provider

The palette is two parts with one ring between them.

- **The panel** is in the compositor. It owns the keys, the pixels, the list and the fuzzy match. It holds no new right. Two kinds of entries are its own, from tables that it already has: the programs and the windows. They work with no console.
- **The palette provider** is the console. It already holds each grant that a command needs. It writes the entry table, a memory object that the compositor maps read-only: one entry for each row of its command table, with the parameters as data. On a choice, it runs the command as a typed line: the line is echoed in its terminal, the drawers draw the result, and the line goes in the line history.
- **The grant** is `Palette`, a grant of the console. `grants("console")` shows it. `revoke("console", "palette")` ends the ring and the mapping, and the palette keeps the programs and the windows.

Why this gives no program a new authority: the compositor already routes each key to the console, so it can already type `shutdown()` there. The ring adds a face, not a power.

- A compromised compositor gains nothing. It already owns each key and each pixel.
- A compromised console can show an entry whose name lies. It needs no palette to do harm: it holds the grants. The compositor, not the provider, draws the confirmation of an entry that destroys.
- A program without the grant gains nothing. The table and the ring are handles that the root service gives to two programs only.

How a program adds its operations: it exports a described function and is a service. It writes no table and no code for the palette. The description of an export is the one source of each front end.

## The refused forms

- **A palette program with its own grants.** It is a second program with every right. It also needs a second command table, a second checker of arguments and a second set of drawers.
- **The compositor dispatches entries that each service contributes.** The compositor must then hold a connection to each service and act for the principal: the program that reads each hostile surface gets the rights of the principal. Or the root service calls an export for a caller, which makes it a deputy. The good part of this form is kept: an entry is data from a described export, and the panel only dispatches.
- **The compositor sends the text of a line.** Refused by the rule of no text between programs. The compositor sends an index and typed values. The console builds its own line.
- **A border of 1 pixel around the whole panel.** The request was an input that is flush with the top, the left and the right edges. The band has no border on those three sides; its fill and the line under it are its edge. The rest of the panel keeps a border, because the design rules allow no shadow and no scrim, and a card on a dark window has too little contrast without an edge.
- **Groups in a ranked list.** A group header takes a row, and the best match must be the first row. Groups exist only when nothing is typed.
- **A record or a table drawn in the panel in the first form.** A table opens in the console: the drawers, the scroll and the line to compose are there. A reader of hostile descriptions in the compositor was not worth one saved step. A Record is now shown in the panel as the runs that the drawer of the console wrote.
- **A store for the recent choices of the compositor.** The recent commands survive a stop through the line history of the console, with no new store and no new grant. The recent programs and windows live in the memory of the compositor.

## The subtle points

- **The palette runs the row that is drawn.** The command table of the console changes (`load`, `unload`, `connect`). A choice carries the change count of the table that the panel showed, the index, and the hash of the name of the entry. The console checks the three against its own copy, and refuses a choice that names another entry. A list that arrives late does not move the choice. This was the test designed to break the form on its first day: Enter before the table moves.
- **The table is hostile input.** The compositor copies the table, then checks the copy: the count of entries, each length, each kind, and a change count that never becomes even. A table that fails gives the programs and the windows only, with one line of the log.
- **The values go as records with kinds, not as a line.** An Integer goes as a number, a Text as bytes. The console checks each value again before the call, as for a typed line. A parameter of the kind Record, Table, Handle or Bytes has no field: the entry opens the console.
- **The confirmation belongs to the compositor.** An entry that destroys asks for a second Enter on a row that says the act in full. The provider cannot skip it. An export of a service has no such fact in its description, so only the built-in commands of the console have the flag.
- **A mark says a fact, never a kind alone.** The kind of a row is in words at its right and in the form of its icon; a color never stands alone for a fact.
- **The ranking of a few hundred entries from another program does not run in the loop of the compositor.** A second thread of the compositor copies the table and ranks. The loop gives it the query with a number, waits on a word in its one wait, and adopts only the list of the newest number.
- **The panel opens with no animation**, in the next frame, and has a fixed height: the input line never moves when the list changes.
- **A locked principal.** The console runs in the session of the machine. With a named principal locked, the palette offers what the console offers. This is a fact of the console, not a new hole of the palette; it is a question for the design of the principals.
- **When the console does not run**, the palette lists the programs and the windows and says that the commands are absent. `console` is a program of the list, so the palette starts it.

## The film

A film of the palette needed a change of the tool: the old step that took pictures stopped the scenario, so a film had no key during its pictures. A worker thread now takes the pictures while the scenario types and waits for its conditions. The capture stays the screendump of QEMU: another capture path needs a display server of the host, and a window can open. See [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The film".

## State

Built: the panel with the programs and the windows; the provider with the commands of the console, their arguments and their candidates; the settings; the four prefixes; the kind icons; the film.

Left:

- The scheduling strategy is reachable by no command. The program `scheduler` exports only its entry. It needs to serve an export that sets the strategy.
- A Table result is not drawn in the panel: it opens in the console.
- A second provider (a service that runs its own entries) waits for a real need.
