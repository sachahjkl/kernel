# The line of the console

This guide describes the line that is typed at the console: the language that the line is written in, the result that a line gives and how the console draws it, the log records that show under a line while it runs, the keys that edit the line, the completion list that opens while it is typed, the line history that survives a stop, and the colors of its code.

## About this guide

**The idea in plain words.** The console is the program in which the principal calls the functions of the system directly, with typed values, in place of a shell that passes text to programs. Each name that it can call comes from the description of a module, so the console can complete every name and show the signature of every call while the line is typed, with no code in the called program.

**For whom.** A reader who uses the console, and a reader who changes `programs/console`, `support/line_editor` or `support/terminal`.

**Read before.** `PROPERTIES.md`, "19. A command is a function: no text between programs". The terms edit line, line editor, hint line, free row, completion list, chosen row, fuzzy match, line history, history search, terminal, result drawer and short name of an export are in `GLOSSARY.md`, group Communication; log record and value run are in the group Running code.

**The map of this guide.**

| Section | What it says |
|---|---|
| "The language of the console" | What a line can say: values and their kinds, calls, variables, records, tables as values, how a line composes, and its errors |
| "Results and their drawers" | The one result of a line, the drawer of each kind of result, and the result of each built-in command |
| "The log records of a line" | Which log records show under a line while it runs, and how the console reads them |
| "The built-in commands and the services" | Which built-in commands are exports of a service, and which stay in the console |
| "1. The keys" | What each key does, with the list closed, the completion list open, or the history search open |
| "2. What the console completes" | Which names come where the caret is, and from which table |
| "3. The fuzzy match" | How a query matches a name, and the score that orders the list |
| "4. The bounds, and the cost of one key" | The limits that keep one key fast against a hostile description |
| "5. Who draws the list, and the line under the edit line" | What the console sends and what the terminal lays out |
| "6. The line history across a stop" | The store of the history, its load, its save and who can read it |
| "7. The colors of the code" | The kinds of the parts of a line, their colors, and the records that carry them |

**An example.** Type `mcnt`: the completion list opens with `monitor.count` first, its matched characters in the accent color. Tab takes the name and adds `(`; the hint line under the edit line then shows `count(name: Text) -> Integer` with the parameter at the caret marked.

![The completion list of the console, open under the edit line](screenshots/console_completion.png)

![The history search of the console: Control-R and a part of a line](screenshots/console_history_search.png)

## What the console owns

The console owns the line that the input edits: its bytes, the caret, the line history, and the completion list. The terminal draws them and gives the keys. The procedures that change the line are in `support/line_editor`: they have no state of their own and make no kernel call, so host tests run each key (`support/line_editor/line_editor_test.odin`). The console uses them in `programs/console/main.odin` and `programs/console/completion.odin`.

## The language of the console

A line of the console is one expression of a small language, or a variable that takes the value of one. The console reads the line, calls the functions that it names with typed values, and draws the one result that comes back: a value, or an error. No program receives the text of the line: the text stops at the console, and only typed values go to the functions (`PROPERTIES.md`, "19. A command is a function: no text between programs").

The code is `programs/console/language.odin` (the parser and the values), `programs/console/commands.odin` (the commands and the calls), `programs/console/tables.odin` (the commands of tables), `programs/console/results.odin` (the result of a line and its drawing), `programs/console/line_records.odin` (the log records of a line) and `support/console_results` (the drawers).

### The form of a line

```
line       = name "=" expression | expression
expression = term { ("+" | "-") term }
term       = factor { ("*" | "/" | "%") factor }
factor     = "-" factor | integer | "text" | name | name "(" arguments ")" | "(" expression ")"
```

- **A name** starts with a letter or `_`, and goes on with letters, digits, `_` and `.`: `monitor.count` and `r.value` are one name each.
- **An integer** is decimal digits. It has 64 bits with a sign. A number that is larger than 9223372036854775807 is an error of the line. A result of `+`, `-`, `*` or `/` that does not fit is an error of the line too: no result wraps. The checks are `number_value`, `integer_add`, `integer_subtract`, `integer_multiply`, `integer_negate` and `integer_divide` of `support/console_language`. The least integer has no literal: write `-9223372036854775807 - 1`.
- **A text** is the bytes between two quotes. A text has no escape, so it cannot hold a quote.
- **The operators**: `+`, `-`, `*`, `/` and `%` on two integers, with the usual order; `-` before an integer; `+` on two texts joins them. A division by zero is an error. So is the one division whose result does not fit: the least integer by `-1`.

Examples:

```
> 6 * 7
42
> "abc" + "def"
abcdef
> length(repeat("ab", 3))
6
```

### Values and their kinds

Each value has one kind. The kinds are those of the module contract (`MODULE_CONTRACT.md`), so an export of a module takes and gives the same values as a command of the console.

| Kind | What it holds | How the console draws it |
|---|---|---|
| `Integer` | A whole number of 64 bits | `42` |
| `Text` | Bytes | The bytes, one line for each line of the text |
| `Record` | The bytes of one record, with the description of its record in a module | The name of the record, then one line for each field: its name and its value |
| `Handle` | A handle that the console holds | `Handle 65541: Memory (Give, Read, Write)`: the kind of the object and the rights, which the console asks of the kernel |
| `Table` | Records of one description, one after the other | A line of the names of the fields, a line for each row, then the count: `2 rows of Import` |
| `Bytes` | Bytes with no description | Rows of 16 bytes: the place of the row, the bytes in hexadecimal, their characters; then the count |

A parameter of the kind `Bytes` takes a `Text` value as its argument. A built-in command can have a parameter of the kind `Value`, which takes a value of any kind; the command checks it itself (the third parameter of `where`).

A command gives a result and never prints. A command that does something and has nothing to give has no result: `start`, `stop`, `clear`. `help()` shows this in each signature: a command with `->` gives a value of that kind, and a command with no `->` gives nothing. The section "Results and their drawers" has the result of each built-in command.

### Calls

A call is `name(argument, ...)`, with at most 6 arguments. Each argument is an expression: a number, a text, a variable, an operation, or another call.

**Where a command comes from.** A name can be called when the command table of the console has it. A command comes from one of three places:

- **The console itself**: the built-in commands. They exist before any module is loaded.
- **A module of the boot image**, after `load("sample")` or `isolate("sample")`: each export becomes a command with the name of the export, and each record of the description of the module becomes a command that makes a record from its fields.
- **A service that runs**, after `connect("monitor")`: each export becomes a command named `service.export`, as `monitor.count`.

When two commands have one name, the command added last runs.

**The check before the call.** The console checks the count of the arguments and the kind of each one against the description of the parameters, before the call. A record or a table argument must have a description equal to the description of the parameter: equal records of two modules agree. A wrong argument is refused with its number and the two types, and the call does not run:

```
> sum_values(columns(t, "sensor value"))
error: sum_values: argument 1 is Table(Reading, Read), not Table(Reading)
```

Here `columns` made a table of another record, with fewer fields, so the export of `sample`, which reads the whole record, refuses it.

**How the call runs.** A built-in command runs in the console. An export of a module that `load` added is a direct call in the memory of the console. An export of a module that `isolate` added is an isolated call to a sandboxed program, and an export of a service is a call to that service; the arguments and the results go through the call region (`MODULE_CONTRACT.md`, section 4). A record argument is a copy: the export can write in it, and the variable that gave it does not change.

### Variables

`name = expression` keeps a value under a name for the lines after it. A name alone gives the value back; `name.field` gives one field of a record variable.

```
> t = readings(4)
> sum_values(where(t, "sensor", 2))
210
> r = row(t, 1)
> r.value
```

The bounds:

- 16 variables. A new name takes a free slot; a name that exists takes its new value.
- A name of 16 bytes at most, and a text value of 96 bytes at most.
- A table of 32 KiB of rows at most (`TABLE_KEPT`).
- No `Bytes` value: "error: a variable keeps no Bytes value".
- An expression with no value (a call of a command with no result) cannot be kept: "error: the expression has no value".

`variables()` gives them as a table: the name, the type and the value as a text. A variable lives in the memory of the console: it does not survive a stop of the console.

### Records

A record is a group of named fields, as a module describes it. The command with the name of a record makes one from its fields, in the order of its description. `variable.field` reads one field: an integer, a text or a handle.

### Tables as values

A table is the records of one description, one after the other. An export with a `Table` result gives one, and the console holds it as one value: it passes the table to the next call with no parsing. Eight built-in commands work on a table of any record, because each one reads only the description of the records. A table that a built-in command gives (`grants`, `modules`, `help`) is such a table: the console writes the description of its record in the format of the module contract.

| Command | Gives |
|---|---|
| `where(table, field, value)` | The rows whose field has the value: an `Integer` for an integer or handle field, a `Text` for a text field |
| `sort(table, field)` | The rows in the increasing order of a field: integers by value, texts byte by byte. Rows with one value keep their order, so two sorts give an order by two fields |
| `join(left, right, field)` | One row for each pair of rows with one value of the field. The new record has the fields of the left record, then the fields of the right one that the left one does not have, at most 40; its name is `<left>_<right>` |
| `columns(table, "a b c")` | The rows with only the fields that the text names, in its order. The record keeps its name |
| `first(table, count)` | The first rows, at most the count |
| `skip(table, count)` | The rows after the first rows |
| `rows(table)` | The count of rows, as an `Integer` |
| `row(table, number)` | One row as a `Record`, from 1 |

`join` and `columns` make a new record description. The console writes it in the format of the module contract, so the next command reads it as it reads the description of a module. A command that gives a table gives a new table; the table of its argument does not change.

The tables of one line share 256 KiB (`TABLE_ARENA`). The console draws a table with no cut inside a value ("Results and their drawers").

![Tables as parameters: one description, three ways to call](screenshots/tables.png)

### How a line composes

A line composes by calls in calls. The console evaluates each argument before its call, from left to right, and the innermost call runs first. Each step takes a typed value and gives one:

```
> connect("manual")
> columns(where(manual.running(), "module", "calendar_fixed"), "program slot module replaces")
> join(columns(manual.running(), "program hash"), columns(manual.modules(), "hash name code exports"), "hash")
> rows(manual.exports("")) - rows(manual.exporters("show"))
```

The first line lists the programs that run a module, keeps the rows of one module, and shows four of their fields. The second joins two tables of the service `manual` on the hash of a module. The third subtracts two counts.

**The built-in commands compose too.** A built-in command that lists things gives a table, so a line filters, sorts and counts it as it does the table of an export:

```
> where(grants("notes"), "state", "held")
> sort(where(programs(), "state", "waiting"), "name")
> rows(where(help(), "name", "repeat"))
> columns(where(loaded(), "call", "direct"), "module imported_by in_place_of")
```

### Errors

A line that fails has one result: its error. The first error ends the line: the rest of the line does not run. A command never prints its error: it makes the line fail, and the console draws the error after the line ("Results and their drawers", "The drawer of an error"). The first line of a drawn error starts with `error: ` and holds one sentence.

| When | The sentence |
|---|---|
| No command has the name | `error: no command has the name x; try help()` |
| A command named with no parentheses | `error: help is a command: write help(...)` |
| No variable has the name | `error: no variable has the name x` |
| A record variable has no such field | `error: Reading has no field x` |
| The count of the arguments is wrong | `error: length takes 1 arguments, not 2` |
| An argument has the wrong kind | `error: sum_values: argument 1 is Table(Reading, Read), not Table(Reading)` |
| An operator on the wrong kinds | `error: "-" does not take Text and Text` |
| A division by zero | `error: division by zero` |
| A result that does not fit in an integer | `error: "+" of 9223372036854775807 and 1 does not fit in an Integer: an Integer has 64 bits with a sign` |
| A number that does not fit in an integer | `error: the number 9223372036854775808 does not fit in an Integer: the largest is 9223372036854775807` |
| A text with no end quote | `error: the text has no end quote` |
| A field that the records do not have | `error: where: the records ... have no field x; their fields are ...` |
| A value of the wrong kind for a field | `error: where: the field code is Integer, the value is Text` |
| An export that fails | `error: manual.exports: the argument name names none of the modules (-1)`: the sentence of its error record (`MODULE_CONTRACT.md`, section 8), then the values of the record |
| The root service refuses | `error: root.Stop: the argument name names a program of the system: ...`: the sentence of the error record of the root ring, then its values |
| A call in an isolated program that faults | `error: the program agenda stopped: invalid instruction`, then the instruction and the frames of its stop report, each after `error: ` |

An overflow has an error record of the kind `Over_Limit`: `value` is the left value, `found` the right value, and `limit` the largest integer.

A call that runs before the error keeps its effect: in `length(start("life"))`, `start` runs, then `length` refuses its argument. The line draws only its error.

## Results and their drawers

A line has one result, and the console draws it by its kind. No command writes to the terminal: a command gives a value, or makes the line fail. So each fact that a command gives is a value that the next call can take, and the look of a result is decided in one place.

### The drawers

One drawer exists for each kind of result. A drawer knows no command: it reads the value, and for a record or a table the description of its record. The drawers are in `support/console_results`: they have no state, call no allocator and make no kernel call, and host tests draw each kind into a text (`support/console_results/console_results_test.odin`). A drawer writes parts of a line to the console with what each part is; the console chooses the color.

| Kind | What the drawer writes |
|---|---|
| Integer | The decimal text |
| Text | The bytes, one line for each line of the text. An empty text is one empty line |
| Record | The name of the record, then one line for each field: two spaces, the name of the field, and its value. The values start at one column |
| Table | A line with the names of the fields, a line for each row, a line with the count of rows and the name of the record. Each column has the least width that holds its head and its values, with two spaces between two columns. A number is at the right of its column, a text at the left |
| Handle | `Handle`, its number, the kind of its object, and its rights in parentheses. A handle that names no object: `Handle 7: no object` |
| Bytes | Rows of 16 bytes: the place of the first byte of the row in 8 hexadecimal digits, the bytes in hexadecimal, their characters (a byte that is no character is `.`). The last line is the count of bytes |
| An error | "The drawer of an error", below |

```
> where(grants("notes"), "state", "held")
program  grant  state  principal  principal_name
notes    log    held           0  machine
notes    store  held           0  machine
2 rows of Grant
> memory()
Memory
  memory_mebibytes            256
  free_mebibytes              201
  ...
```

**The colors.** A value has the color of its value kind, from the one table that the window of the log and the site read (`support/graphics/value_colors.odin`; `docs/DESIGN.md`, "The colors of values"): an Integer is a number, a handle a handle, the name of a record and the kind of an object a type, an error kind a status, the operation of an error an operation. The name of a field, the head of a column and a line about the result (the count of rows) are dim. A text value is plain: the drawer has only the type of a field, and no text is classified by its look.

**No value is cut.** The terminal draws no byte past its last column. The console starts a new row when a line reaches the last column of its window (`WINDOW_COLUMNS`, 96), so a long value goes on in the next row, under the start of its column when that column starts in the left half of the window. The log has the line whole. A text that a command writes in a field of a fixed size, and that is longer than the field, ends with the cut mark and the count of the missing bytes (`GLOSSARY.md`, "Cut mark"): the help of a command in `help()`; `describe(name)` gives it whole.

**The bounds.** The console draws the first 20 rows of a table (`RESULT_ROW_LIMIT`), then one line that says how many rows it does not show, then the count of all the rows. The widths of the columns are those of the rows that it draws. `first(table, count)` and `skip(table, count)` choose other rows, and `where` chooses by a value. The console draws the first 256 bytes of a `Bytes` value (`RESULT_BYTE_LIMIT`), then how many it does not show. A cut is always between two rows, never inside a value.

### The drawer of an error

The first line is `error: ` and the sentence. When a call gave an error record (`MODULE_CONTRACT.md`, section 8), the lines after it give the record as values, so a reader sees what the sentence was made from:

```
> add(1, "a note of forty bytes, four more than 36")
error: add: the argument note has 40 bytes; it can have at most 36 bytes (-1)
  kind       Too_Long
  operation  add
  argument   2 note
  values     value 40, limit 36, found 0, unit bytes
```

- `kind`: the error kind, by its name in `contract/errors`. A kind that the contract does not have, from another program: "an unknown kind" and its number.
- `operation`: the export, or `root.` and the command of the root ring.
- `argument`: the number of the argument that is wrong, from 1, and its name. The line is absent when the record names no argument.
- `values`: `value`, `limit` and `found` of the record, and its unit when it has one.

When the export has a table of error details and wrote more than one detail, one line for each detail follows, each after `error: `, then the count of the details that the table of the console did not hold (16 places). An error of the console itself (a wrong kind of argument, an unknown name) has no record: its sentence is all of it. A load that fails, and a program that stops on a fault, add their lines after the sentence, each after `error: `.

### The result of each built-in command

| Command | Result | What it gives |
|---|---|---|
| `help()` | Table of `Command` | One row for each command: `name`, `signature`, `about` |
| `describe(name)` | Text | The signature and the whole help of one command |
| `programs()` | Table of `Program` | The export `monitor.programs()` ("The built-in commands and the services") |
| `debug(program)`, `detach()` | Table | One row: the exports `debugger.attach()` and `debugger.detach()` ("The commands of the debugger") |
| `threads()`, `hold(thread)`, `resume(thread)`, `continue_all()`, `step(thread)`, `step_line(thread)` | Table of `Thread_Row` | The threads of the debugged program: `thread`, `state`, `instruction`, `module`, `procedure`, `offset`, `file`, `line` |
| `registers(thread)` | Table of `Register_Row` | `name`, `value`, `about` |
| `stack(thread)` | Table of `Frame_Row` | `frame`, `module`, `procedure`, `offset`, `file`, `line`, `frame_pointer`, `return_address` |
| `locals(thread, frame)` | Table of `Variable_Row` | `name`, `role`, `type`, `value`, `location` |
| `value(thread, frame, path)` | Table of `Value_Row` | `name`, `type`, `value`, `address` |
| `source(thread, frame)` | Table of `Source_Row` | `line`, `mark`, `text`, `path`, `hash` |
| `break_at(place)`, `watch(place, length)`, `breaks()`, `break_remove(number)` | Table of `Break_Row` | `number`, `kind`, `address`, `length`, `place` |
| `debug_memory(place, count)` | Table of `Memory_Row` | `address`, `bytes`, `text` |
| `events()`, `wait_stop(milliseconds)` | Table of `Event_Row` | `thread`, `kind`, `instruction`, `module`, `procedure`, `offset`, `file`, `line` |
| `program_modules()` | Table of `Program_Module` | One row for each module of each program: `slot`, `program`, `module`, `replaces`, `hash_head` |
| `memory()` | Record `Memory` | The memory of the machine and the counters of the kernel. `free_pages_no_budget_holds` is 0 when each page is free or paid |
| `locks()` | Table of `Lock` | One row for each kind of kernel lock: `lock`, `waits`, `takes` |
| `modules()` | Table of `Module` | One row for each module of the boot image: `name`, `bytes`, `hash_head` |
| `load(name)`, `isolate(name)`, `connect(name)` | Record `Loaded` | `module`, `commands`, `call` (`direct`, `isolated` or `service`), `hash_head` |
| `unload(name)` | Record `Unloaded` | `module`, `commands`, `memory`: what became of the memory of the module |
| `loaded()` | Table of `Loaded_Module` | The modules and the services whose exports are commands, and the imports of the modules: `module`, `call`, `imported_by`, `in_place_of`, `hash_head` |
| `start(name)`, `stop(name)` | none | |
| `grants(name)` | Table of `Grant` | One row for each grant that the program has or lost: `program`, `grant`, `state` (`held` or `lost`), `principal`, `principal_name` |
| `revoke(name, grant)` | Integer | The holdings that ended |
| `principal_create(name)` | none | The window of unlock opens |
| `lock()` | Integer | The programs of the session that stopped |
| `principals()` | Table of `Principal` | `number`, `name`, `state` (`machine`, `locked`, `unlocked`, `creating`), `public_key_head`, `measure_head` |
| `replace(name, by)` | none | |
| `replacements()` | Table of `Replacement` | `module`, `by`, `module_hash_head`, `by_hash_head` |
| `time()` | Integer | Milliseconds since the machine started |
| `hash(text)` | Text | 64 hexadecimal digits |
| `length(text)` | Integer | |
| `text(integer)` | Text | |
| `repeat(text, count)` | Text | |
| `buffer(pages)` | Handle | A new memory object |
| `byte(memory, place)` | Integer | |
| `bytes(memory, first, count)` | Bytes | At most 4096 bytes of a memory object |
| `release(memory)` | none | |
| `variables()` | Table of `Variable` | `name`, `type`, `value` |
| `clear()`, `shutdown()` | none | |
| `history_clear()` | Integer | The lines that the history forgot |
| `measure_completion()` | Table of `Completion_Measure` | Two rows, in nanoseconds; the same measure goes to the log in microseconds |
| `where`, `sort`, `join`, `columns`, `first`, `skip` | Table | "Tables as values" |
| `rows(table)` | Integer | |
| `row(table, number)` | Record | |

A `hash_head` is the head of a BLAKE3 hash: its first 8 bytes, as 16 hexadecimal digits. `manual.modules()` gives the whole hash of a module.

**How a built-in command makes a table.** It gives the name of its record and its columns (`made_table` in `programs/console/results.odin`), then adds rows. The console writes the description of the record in the format of the module contract (`console_results.description_write`), in the memory of the tables of the line: a table of a command and a table of an export are one kind of value.

## The log records of a line

While a line calls an export, the console shows under the line the log records that the called program writes, so the effect of a call is visible where the call was typed.

```
> server.put("hello.txt", "kept in the store of server")
  server
    server: the page /hello.txt is in the store: 27 bytes
27
```

- **Which records.** The records that a program called by the line wrote, from the first call of the line on: a service, a sandboxed program of `isolate`, and the console itself for a module that `load` put in it. A line follows 4 programs at most. A program that `start` starts is not followed: the line ends before the program writes.
- **By channel.** The records of one program and one channel follow one head line: the name of the program, in the color of a module, and the channel. A record of another channel starts a new group.
- **The value runs.** Each value run of a record is in the color of its value kind, as in the window of the log (`docs/TOOLS.md`, "The log"). A record of the level error is in the color of a failure.
- **While the line runs.** During an isolated call or a call of a service, the console reads the new records each 100 ms (`STATUS_INTERVAL`), and once more when the line ends, before it draws the result. During a direct call the console waits in the module: the records show when the call returns.
- **To the terminal only.** These lines do not go to the log: the records are in the log already.

**How the console reads the records.** The console has no grant to read the memory of the log (the grant `log_records`), and gets none. It reads the records as any caller that acts for the principal: it calls the exports `records(after)` and `value_runs(after)` of the service `log`, through a connection that the root service gives. The console asks for that connection itself, at the first line that calls a program; the connection adds no command, until `connect("log")` asks for the commands. The console reads the rows with the description of their record, by the names of the fields, and trusts no count of the service.

**When there is no record.** With no service `log`, or when the root service refuses the connection, a line shows no record; the console asks again after a line with `start` or `connect`. A service that does not answer in one second (`LINE_RECORD_ANSWER_LIMIT`) is not asked again in that line. A line that calls the service `log` itself shows no record: the console does not use a connection while a call runs on it.

**The bounds.** One read draws at most 32 records, and reads at most 8 answers: a program that writes faster keeps its records in the log, where `log.records(after)` gives them.

## The built-in commands and the services

A fact that a service holds is an export of that service, and the console calls it as any export. A built-in name can stay as a short name of such an export: the command connects to the service when the console has no connection to it yet, then calls the export through the connection (`bound_call` in `programs/console/commands.odin`).

| Built-in command | Where the fact comes from |
|---|---|
| `programs()` | The export `monitor.programs()`. With no service `monitor`, or when `monitor` lost its grant, the line fails with the error of the connection or of the export |
| `debug`, `detach`, `threads`, `hold`, `resume`, `continue_all`, `registers`, `stack`, `locals`, `value`, `source`, `break_at`, `watch`, `breaks`, `break_remove`, `step`, `step_line`, `debug_memory`, `events`, `wait_stop` | The exports of the service `debugger`, which the root service starts when the console connects to it ("The commands of the debugger") |
| `start`, `stop`, `grants`, `revoke`, `principal_create`, `lock`, `principals`, `replace`, `connect` | A command of the root ring, with typed values and an error record. The root service serves no exports: it has a ring of its own commands, and these built-in commands are its callers |
| `modules()` | The boot image that the root service granted to the console. `manual.modules()` gives the same modules with more fields, when the program `manual` runs |
| `replacements()` | The replacement table that the root service granted to the console, read-only. `manual.replacements()` gives it too, when `manual` runs |
| `program_modules()`, `memory()`, `locks()` | The reports of the kernel, with the grant of the console to inspect the machine. `manual.running()` gives the modules of the programs, and `monitor.counts()` the counts, when those programs run |
| `load`, `isolate`, `unload`, `loaded`, `buffer`, `byte`, `bytes`, `release` | The console itself: its command table, its modules, its handles |
| `help`, `describe`, `variables`, `where`, `sort`, `join`, `columns`, `first`, `skip`, `rows`, `row`, `time`, `hash`, `length`, `text`, `repeat`, `clear`, `history_clear`, `measure_completion`, `shutdown` | The language and the console itself |

`modules`, `replacements`, `program_modules`, `memory` and `locks` stay in the console because the programs that serve the same facts (`manual`, `monitor`) do not run at each boot, and these commands must work with no other program. The stores are a fact of the storage service: the console has no built-in command for them, and calls `storage.stores()` and `storage.usage()`.

### The commands of the debugger

The debugger is the service `debugger` (`TOOLS.md`, "The debugger"). The console holds no state of a debugging and has no code that draws one: each command of the debugger is a short name of one export of the service, and the drawers draw the table that the export gives. So a table of the debugger composes as each other table: `columns(stack(0), "frame procedure line")`, `where(locals(0, 1), "name", "total")`.

| Command | Export of `debugger` |
|---|---|
| `debug(program)` | `attach` |
| `detach()` | `detach` |
| `threads()` | `threads` |
| `hold(thread)` | `hold` |
| `resume(thread)` | `release` |
| `continue_all()` | `continue_all` |
| `registers(thread)` | `registers` |
| `stack(thread)` | `stack` |
| `locals(thread, frame)` | `locals` |
| `value(thread, frame, path)` | `value` |
| `source(thread, frame)` | `source` |
| `break_at(place)` | `break_at` |
| `watch(place, length)` | `watch` |
| `breaks()` | `breaks` |
| `break_remove(number)` | `break_remove` |
| `step(thread)` | `step` |
| `step_line(thread)` | `step_line` |
| `debug_memory(place, count)` | `memory` |
| `events()` | `events` |
| `wait_stop(milliseconds)` | `wait_stop` |

Three short names are not the name of their export, because the console has a command with that name: `resume` (`release` closes a handle of the console), `debug_memory` (`memory` gives the memory of the machine), and `debug`, the word for the act. The command that holds one thread is `hold`: `stop` stops a whole program by its name. No command of the debugger takes the name of a command that the console had.

**A loaded module can take a short name.** When two commands have one name, the command added last runs ("Calls"). `load` and `isolate` add each export of a module under its own name, with no prefix: a module with an export `debug`, `threads` or `stack` takes that name from the debugger, as it takes `programs` or `time`, until `unload`. `help()` then has two rows with the name, and `describe` gives the one that runs. The full name is never taken: `connect` adds the exports of a service as `service.export`, and a module cannot export a name with a period, so `debugger.attach(...)` always calls the service.

After `connect("debugger")`, each export is also a command with its full name: `debugger.threads()`. Escape during `wait_stop` closes the connection to the service, which ends the debugging.

## 1. The keys

The keys edit one line, as in a text field. The same key does a different thing in three states: with no list open, with the completion list open, and with the history search open. The table gives each key in each state.

| Key | List closed | Completion list open | History search open |
|---|---|---|---|
| A character | Goes in at the caret; opens the list at the first character of a name | Goes in at the caret; the list follows | Goes in the search |
| Left, Right, Home, End | Move the caret | Move the caret; the list follows | Nothing |
| Backspace, Delete | Remove the byte before, after the caret | The same; the list follows | Backspace removes a byte of the search |
| Tab | Opens the list (one name: it goes in at once) | Takes the chosen name | Takes the chosen line |
| Enter | Runs the line | Takes the chosen name; if the name is already the name at the caret, runs the line | Takes the chosen line: it goes in the input, and does not run |
| Up, Down | An older, a newer line of the history; after the newest, the line that was typed | The choice moves | The choice moves |
| Control-R | Opens the history search | The choice moves down (an older line in the search) | The choice moves down: the next older line of equal score |
| Control-S | Nothing: no line is newer than the line that is typed | The choice moves up | The choice moves up |
| Escape | Nothing | Closes the list; the next character opens it again | Closes the search; the line stays as it was typed |

Control-R and Control-S: the console tests the character of the key (`r`, `s`) with the modifier Control, not the code of the key. The input service gives the character of the US layout from the table of the Shift state, and gives it also when Control is held: the machine test sends `ctrl-r` and `ctrl-s` through QEMU and they work. With Shift also held the character is `R`, and the console takes the key as no search. The system has only the US layout today; with another layout, the input service gives the character of that layout, so Control-R follows the letter R wherever the layout puts it, as it is printed on the key. A test of the code follows the place of the key instead, and breaks with such a layout.

### When a line ends, and the keys typed during a line

A line ends when its result is drawn. The console then takes the keys again. What the console does after the result holds no key: the save of the line history (section 6) runs after the end of the line, in the thread that runs the lines.

While a line runs, each key waits, in order, and the edit line shows them (`|` Enter, `<` Backspace, `>` Tab, `^` a key with no character; Escape is `^`). At the end of the line the console acts on them in their order, as if they came then: a key that waited means what it means when typed slowly. At most 128 keys wait; a key after them is lost.

Escape has one more meaning, and only in one state: while the line waits in a call of a sandboxed program or of a service, Escape stops that call at once, also when keys wait. While the line is in no such call (a built-in command, a direct call, the drawing of the result), Escape waits as each key, and then closes the list that the keys before it opened. So `clear()`, then `mcnt`, Escape and Tab typed before `clear()` ended, give what they give when typed slowly: the list opens at `m`, Escape closes it, Tab opens it again.

The rule is `line_editor.running_key_action` (`support/line_editor/running_keys.odin`), with its host test. A direct call that does not return cannot be stopped: the module runs in the thread of the lines; `isolate` such a module.

A chosen name replaces the whole name at the caret, also its part after the caret, up to a dot. A command or an export gets its `(`, unless a `(` follows; a name in quotes gets its closing quote, unless one follows.

## 2. What the console completes

The console completes the name at the caret from what it knows at that moment: its command table, its variables, the modules of the boot image, and the programs that run. Which of these it offers depends on where the caret is.

| Where the caret is | The names | From |
|---|---|---|
| A name with no dot | Each command (with its full name: `monitor.count`), each connected service, each variable | The command table: the commands of the console, and the exports of the modules and services, from their descriptions |
| After the name of a service and a dot (`storage.`) | The exports of that service | The commands whose name starts with that name and a dot. If none does, the whole name is matched against all the names |
| Inside the quotes of the first argument of `load`, `isolate`, `start`, `replace` | The modules of the boot image | The image that the root service granted |
| Inside the quotes of `connect`, `stop`, `grants`, `revoke` | The programs that run | `Inspect` on the machine, with the grant that the console holds. The root service has no command that lists its services: the console asks for none, and gets no new grant. With no grant to inspect, the list names the services whose exports are commands of the console |
| Inside the quotes of `unload` | The modules that `load` and `isolate` added | The table of the console |

Not completed: the second argument of a call (the grant names of `revoke`), the fields of a record variable (`r.x`), the common start of several names (the list replaces it).

When the call at the caret is open, the line under the edit line shows its signature, dim, from the description, and marks the parameter at the caret: `write(name: Text, data: Text) -> Integer`.

## 3. The fuzzy match

A few characters of a name are enough to find it: the console finds each name that holds the typed characters in their order, and puts first the names where they fall at the start of a word.

The characters of the query appear in the name in their order, with gaps allowed: `mcnt` matches `monitor.count`, `stwr` matches `storage.write`. Lower and upper case are equal. The match finds the first place where the whole query has matched (a pass forward), then the latest start before it (a pass back): the shortest window that ends there. The places of that window give the score, and the list draws the same places in the accent color.

| Rule | Points | Why |
|---|---|---|
| Each matched character | +16 | A longer query that matches says more |
| A match at the first byte of the name | +32 | Names are typed from their start |
| A match right after `.` or `_` | +24 | The start of a part of the name |
| A match right after the match before | +16 | A run that was typed, held as one run |
| A gap between two matches | -3, and -1 for each byte of the gap after its first | A spread match is less likely what the typed text means |
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

The names in the list come from descriptions that other programs wrote, and a hostile description can hold very many or very long names. Each bound below keeps the work of one key below a fixed count of steps, whatever the names are.

Each bound holds against a description that another program wrote:

- The match reads at most the first 128 bytes of a name (`NAME_SCAN_LIMIT`): two passes of 128 and 64 places of score, at most 320 steps for a name. A longer name matches only in its start.
- A query of more than 64 bytes matches nothing.
- One ranking reads at most 4096 names (`CANDIDATE_SCAN_LIMIT`), and keeps the best 64 (`RANKED_CAPACITY`). The place of a name in the kept ones is a binary search: at most 7 orders of two names. An order reads at most 256 bytes of the names (`NAME_COMPARE_LIMIT`, a whole line of the history); after them the shorter name comes first, and two names of one length are equal. The search of the history skips a line equal to a kept one: at most 64 compares of 256 bytes for each line. So one key costs at most 4096 x (320 + 1792 + 64) steps, about 8.9 million, and one key of the search at most 256 x (320 + 1792 + 64 + 16 384), about 4.8 million. Before, an order read whole names: long names of one length with a long common start made a key cost names x 64 x their length. The console reads at most 512 names today (`CANDIDATE_CAPACITY`: 128 commands, 8 services, 16 variables, the modules of the boot image, 64 programs), so 10 000 exports of one service never reach the list: the console refuses a service whose commands do not fit in its table.
- The console measures each ranking with the cycle counter, and writes the longest one on the log when Tab opens a list ("one ranking takes N us at most, over K keys").
- When the names are more than the console reads (512), the line under the edit line says it: "N names match, and more names than the list reads: type more characters" (short form: "N names and more").
- A name of 0 bytes is not a name. A byte of a name under 32 or over 126 is drawn as `?` by the terminal; a line takes only the bytes 32 to 126, so such a name cannot go in a line.
- In the quotes of `connect`, `stop`, `grants` and `revoke`, the console reads the names of the programs that run once, when the quote opens (up to 64 `Inspect` calls), and keeps them while the caret stays in that quote and no line runs. A key in the quote makes no kernel call.

The measure: the command `measure_completion()` times the four parts of one key with the list open, for the query `mcnt`: the collect (the table of names), the rank (the match of each name, and the best 64), the rows (the text of the 8 rows that the terminal receives), the colors (the runs of code of an edit line of 200 bytes with more parts than 64 runs hold, and of the 8 rows: section 7). Each number is the least of 20 batches of 10 keys, in microseconds. It writes two lines: one for the names of the console as they are, one for the worst case, 512 names of 128 bytes whose matched characters are far apart, so that the two passes read each whole name:

```
console: one key with the completion list: the collect N us, the rank N us, the rows N us, the colors N us, over K names (the names of this console, the least of 20 batches of 10)
console: one key with the completion list: the collect N us, the rank N us, the rows N us, the colors N us, over 512 names (512 names of 128 bytes, the least of 20 batches of 10)
```

The main machine and `kerneltool measure` (the machine with only the desktop and `locks`) run it. The command runs in the second thread, with its own table of names: the list of the first thread stays as it is.

## 5. Who draws the list, and the line under the edit line

The console knows the names; the terminal owns the cells and the keys. The console sends the rows to show (`terminal.List_Row`: the name, what it is, the places that matched) and then the list (`terminal.List`: the count of rows, the chosen row, the place of the first row in all the names and their count, and the byte of the edit line where the name starts). The terminal lays it out: under the edit line and its hint line when the rows below hold it, above the edit line if not, at the column of the start of the name, as wide as the longest row and cut to the terminal. It has at most 8 rows, and a scroll mark at the right when there are more names.

So no record has a place on the screen, and the terminal stays a program with no knowledge of the language of the console. The rows go through the text region of the console and its terminal: no third program reads it, and the terminal already shows each name that `help()` gives.

The look follows `docs/DESIGN.md`: the cells of the list have the card color, the chosen row the chosen blue `COLOR_CHOSEN` with its text in white, the matched characters the accent (on the chosen row: the chosen blue on a white cell), what a name is at the right of its row, in the colors of its code (section 7); a border of one pixel in the color of the kernel, as the menus of the bar; no shadow, no round corner. A cell of the text grid has a fill color for this (`interface.Text_Grid_Cell.filled` and `background`, draw record version 5): a cell is 12 bytes in place of 8, and the damage by difference redraws only the rows of the list that change. The border is four records after all the others, so the records before keep their places when the list opens or closes.

The line under the edit line (the hint line) and the list are drawn over the grid. The terminal keeps one free row under the edit line at all times, with or without a hint: the hint is drawn in that row. So the text never moves by one row when a hint comes or goes. When the view follows the text, the free row is the last row of the view, and the edit line the row above it. The list opens under the free row when the rows below hold it; when the edit line is near the bottom, it opens above the edit line, over the text.

A hint line has two forms: a long one, and a short one for a terminal that is too narrow (`terminal.hint_form_choose`): the long form when it has no more bytes than the columns; if not, the short form when the program gave one; the form chosen is cut to the columns. The console gives a short form for the list ("12 names. Tab: take. Esc: close") and for the search ("search: leng  2 lines. ^R ^S Enter Esc"); a signature has one form, cut at the right.

The status line of the terminal names the lines of the text that the view shows: "lines 709 to 736 of 737", or "lines none in view of 737" when the view shows no line of the text. The edit line and the free row are not lines of the text. After `clear()`, the terminal forgets its lines and the first row of the view is the edit line: a status that named the first row of the view would say "line 738 of 737".

## 6. The line history across a stop

The console remembers the lines that were entered, and keeps them in a small store of its own, so they come back after a stop of the console or of the machine. Up and Down walk through them; Control-R searches them.

The history lives in the memory of the console: 256 lines at most in a ring of 16 384 bytes (`line_editor.History`), and fewer when the lines are long (81 lines of 200 bytes). A line never wraps at the end of the ring, so each line is one slice of it. The same line two times in a row is kept one time. It also survives a stop of the console and a stop of the machine.

**Why a store of its own.** The history is the state of the console, not a file of the principal; a grant for one purpose with a small limit is what property 20 asks for; the store of the principal and its checks stay as they are.

**The history store.** The root service gives the console a second connection to the storage service, for its history only (`Root_Command.Connect_History`, the role `History_Store`, the grant `history`):

- The store is named after the console with `.history` (`console.history`): the storage service names the store of a connection by the name that the root service sends with it, and no module of the boot image has a dot in its name.
- Its limit is 4 blocks. One object of one block takes 3 blocks of a store (its store block, the leaf of its tree, and its block of data, which the entry names with no object node), as the store of the principal shows ("3 of 4 blocks" for 20 bytes); a change needs one block more for its new data, in the commit that thins the version before. 2 blocks cannot hold the file. At its limit each commit thins the version before; the storage service says it once in a run.
- The connection has no grant to act for the principal: the store of the history and no other one. A hostile console can fill 4 blocks, as its private store lets it fill 4.
- The form: a connection that the console asks for through its root ring, at its start, as `connect("storage")` but with its own command. Not a boot pass: the console runs the whole time, it reads its history at its start. Not a connection in its context at the start: the places of the context of the store connection (7, 8, 9) are the places of the terminal of the console, and the storage service starts at boot after the console (the boot pass of `settings` starts it); a connection in the context needs the storage service before the console, which changes the order of the boot. The root service handles the root ring of the console only after the boot pass has started, so the storage service runs when the request comes: the order of the starts is the order of before.
- The root service keeps the connection apart: `Disconnect` of the service `storage` does not end it, a revocation of the grant `store` does not change it, and a revocation of `acts_for_principal` gives it its limit only. `revoke("console", "history")` ends it: the console keeps its history in its memory. A second connection of one program to one service is refused as before, for each kind.

**The load.** At its start, before it reads a key, the console asks for the connection (it waits 30 s at most: the storage service mounts the disk at boot) and reads the object `line_history`. The second thread runs no line yet, so the history has one user. One log line says what came: "console: the line history: N lines kept from before the stop", or "no line history kept", or that the file is damaged, cannot be read, has more than 4096 bytes, or is refused by a check of `history_file_read` (with its name: "its hash is wrong", "a line has a byte that is not a character", ...). Each of these gives an empty history. A line of the file goes through the bounds of a typed line (200 bytes, the bytes 32 to 126), and nothing of the file runs: a line runs only when the input takes it (Up, or Enter in the search) and presses Enter.

**The save, and its bound.** The second thread writes the file after each line that the history added, after the line ended: the save holds no key. The first thread can add the next line meanwhile, so the save writes a copy of the history, made under a lock that is held for the copy only. The second thread runs the next line after the save: the commits keep the order of the lines. One commit for each line added. A held Enter adds one line at most: an empty line and the newest line again add nothing. So the commits follow the lines that are typed, about 4 ms each (one commit of `notes` in the machine test). `shutdown()` and `stop("console")` save before they act: their save after the line never comes. A stop that the console does not see (a close of its window, a fault, a loss of power) loses the line that runs then and the line whose save is in flight, and no line before them. A save that fails writes one log line in a run, and the history stays in memory.

Why after each line and not at most one write in a second: a generation counts the commits of the whole disk, of each store, and the machine tests check generations. A rule of time makes the count of commits depend on the speed of the host; a rule of lines makes it a fact of the scenario. The steps of the tool now count the generations from a base near them (the step `Generation`, `{generation+N}`), so that a line of the console before them moves nothing.

**What the history holds, and who reads it.** Each line that was entered, as typed: a line with a secret in it (a text that was given to a command) is in it, in the memory of the console and in its store, with the versions that the storage service keeps of the object until the next commits thin them. Who can read it: the console; and a program that acts for the principal, through the exports of the storage service that name another store (`storage.stores()` lists the store; `place = storage.open_store("console.history")` gives a place on it, then `storage.versions(place, "line_history")` and `storage.version(...)` give its states). Today those are the console itself and `remote` (the host, through the principal). No other program reaches it. `history_clear()` empties the history in the memory of the console and removes its object from the store, with each of its versions; the line `history_clear()` goes too.

**The machine tests.** The main machine: the connection and "no line history kept" at its start; the steps of the storage service count from the generation of the first write of the principal. The persistence: the first machine types `length("kept across a stop")`, then `shutdown()`; the second one finds 4 lines ("storage: ok, generation 1027: 3 stores, 4 objects"), Up and Up give the line, Enter runs it (18), and Control-R `kept` finds it. A loss of power during the save: the settings case of `kerneltool test power` checks each object of each image after the loss, the line history with them, and gives the durable state or the state in flight, never a mix; the loss falls in the commits of `settings.repeat(1000)`, not in a commit of the history: a case that falls in a commit of the history is not built (one commit for each line makes such a case slow to reach).

## 7. The colors of the code

The console colors each part of a line by what it is: a function name, a type, a number or a text. The console decides the kind of each part; the terminal decides its color, so one table sets the colors of every terminal.

The edit line, the line that the console writes back when Enter is pressed, and the rows of the completion list are colored by what each part is in the language of the console. One scanner reads them: `support/console_language`. The parser of the console reads its names, numbers and texts with the same procedures (`space_end`, `name_end`, `number_end`, `text_end`), so the colors and the parser agree on where a token starts and ends. The scanner calls no allocator, keeps no state, and never stops at a fault: a byte that the language does not take is one token of the kind Unknown.

**The kinds.** The console sends kinds, not colors (`terminal.Code_Kind`). The terminal maps each kind to a class of the colors of code (`terminal.code_kind_classes`), and each class to a color of the design rules (`support/graphics/code_colors.odin`, the table that the site reads too: `docs/DESIGN.md`, section 4). One table changes the colors of every terminal.

| Kind | What | Class | Color | On the background `0x0B1018` | On the card `0x17212E` |
|---|---|---|---|---|---|
| Function | The name of a command or an export, in a call or at the start of a row | Name | `0x58D878` | 10.45 | 8.90 |
| Module | A module or a service, before the dot of its export | none: the text color | | | |
| Type | `Integer`, `Text`, `Table`, `Bytes`, `Handle`, a record, and what the parentheses of a type hold | Type | `0x9E8FCB` | 6.58 | 5.60 |
| Parameter | The name of a parameter, before its `:` | none | | | |
| Variable | A variable, also before `=` and before `.field` | none | | | |
| Number, Text, Text_Unfinished | A number; a text in quotes; a text with no end quote yet | Literal | `0x38C0B0` | 8.47 | 7.22 |
| Operator, Arrow | `+ - * / % = ( ) , : . { }`, and `->` | Punctuation | `0xB0B8C1` | 9.51 | 8.10 |
| Words | The words of a row that are not code: "export of", "command", "3 lines ago" | Comment | `0x9CA6B2` | 7.73 | 6.58 |
| Unknown | A name that is no command, module or variable; a byte that the language does not take | Comment | `0x9CA6B2` | 7.73 | 6.58 |

A part with no class has the color of the text around it: the tone of the line, or the text color `0xDCE4EC` in a row of the list (14.84 and 12.64). A host test computes each contrast on the background and on both colors of the card; the bound is 4.5 (`support/terminal/code_runs_test.odin`).

**A line that is typed.** The console makes the runs of the edit line at each key that changes it, before it sends the line:

- A name that is a command, an export, a record, a module or a variable has its kind at once, while it is typed.
- A name that the console does not know is Unknown only when a byte follows it. A name that ends at the caret or at the end of the line is still being typed: it has no run, and the color of the line. So a name does not change to the quiet mark and back at each key.
- A text with no end quote is Text_Unfinished. It has the color of a text, not the color of an error: it is still being typed. The error comes when the line runs ("the text has no end quote").
- `name = ...` at the start of a line names a variable: the name is a Variable before it exists.
- An Unknown part is quiet (the dim class), never red: the line is not run yet.

**The rows of the list.** The name has the kind of what it is: a command or an export is a Function, with its module and its dot when its name has one (`monitor.count`); a record is a Type; a service is a Module; a module or a program in quotes is a Text; a line of the history is read as a line of code. What the name is, at the right, is read as a signature: the words before the parentheses are Words, the word after "of" is the Module; in the parentheses a name before `:` is a Parameter; after `:` or `->` each name is a Type, also in the parentheses of the type (`Table(Count_Name, Read)`). The alignment of the rows does not change: the runs give colors, never places.

**The marks over the colors.** The caret of the edit line is drawn over its byte, as before. A matched character of the list, and of the search of the history, has the accent over the color of its kind: the match is what was typed. The line editor has no selection of text. The hint line stays dim, with its mark on the parameter at the caret.

**The chosen row.** The chosen row is on `COLOR_CHOSEN` `0x3C76BB` (`docs/DESIGN.md`, section 10). White has 4.67 to 1 there, and no color of a kind keeps 4.5. The chosen row draws each part in white: the kinds show on the other rows. A matched character of the chosen row is the reverse, the chosen blue on a white cell: 4.67 to 1. The host test holds 4.5 for both.

**The records** (`support/terminal`, record version 2):

- `Code_Runs` (kind 8): the runs of the next Edit record, or of the next List_Row record of one row. Its bytes are in the text region: 4 bytes for each run (start, length, kind, a reserved byte), at most `CODE_RUN_LIMIT` (64) runs. The program sends it just before the record that it colors, so the terminal never shows a new text with the runs of the text before it. A record with no `Code_Runs` before it is plain.
- `Style.code`: the kind of a Text record, in the byte that was the first byte of `Style.reserved`. The echoed line is runs of text with a kind each: the lines that the terminal keeps have a style for each run, and each cell of its grid has its own color, so the echo needs no new form of the grid.
- A row has at most 256 bytes, so a byte holds the start of a run. A part of one kind longer than 255 bytes is two runs.

**The bound, and a hostile list.** A row has at most 64 runs: a line with more parts keeps its first 64 runs, and the text after them is whole, in the plain color. The text is never cut by the runs: only the color stops. The terminal checks the runs against the row that takes them: each run inside the row, after the run before it, with at least one byte and a kind that exists. One run that fails, or bytes that are not a whole count of runs, or a target that takes no runs: the row is plain, its text whole, and the terminal counts it and writes once on the log "terminal: console sent runs of code that do not fit their row: the row is drawn plain, its text whole".

**The cost.** The runs of the edit line are made only when its text or its caret changes, on at most 202 bytes, with one look in the tables of names (256 commands, 16 variables, 12 services, the loaded modules) for each name. `measure_completion()` gives the time of the runs of one key in its fourth part (section 4). When Tab opens the list, the log line says the count of the runs of the first row ("...; its first row has 13 runs of code"), so that a test checks the colors with no pixel.
