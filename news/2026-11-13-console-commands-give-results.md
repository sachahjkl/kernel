title: A command of the console gives a result
date: 2026-11-13
release: 0.92.0
picture: none
kind: Shown
guide: docs/CONSOLE.md

No command of the console prints text now. A command gives a result, and the console draws the result by its kind: a number, a text, a record, a table, a handle, bytes or an error.

A command that lists things gives a table. So one line filters the grants of a program, as it filters the table of any service: `where(grants("notes"), "state", "held")`. The same works for `help()`, `programs()`, `modules()`, `principals()` and `variables()`.

Each kind has one drawer. A value has the color of its kind, as in the window of the log. The console draws 20 rows of a table, then says how many rows it does not show. No value is cut in its middle.

An error shows its sentence, then the values that the sentence was made from: the kind, the operation, the argument.

While a line calls a program, the log records of that program show under the line.

A number that does not fit in 64 bits is now an error of the line.
