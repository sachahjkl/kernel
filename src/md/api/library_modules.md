# Shared libraries as modules: where the border goes

A package that many programs compile in is a bundle with no record of what it holds. The libraries that each program compiled into its own file become modules, loaded one time and imported (`docs/DECISIONS.md`, D-237). This file records how the border of such a module is chosen.

The rules that a writer of a library module follows are in [`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "A library as a module". The first library module, the drawing of a window, is in [`docs/INTERFACE.md`](../../../docs/INTERFACE.md), section 7.

## What was measured first

- **The border of a module is not the cost.** A call through an import slot costs 2.4 ns. A direct call passes addresses of memory of the caller and copies nothing.
- **An adapter is the cost.** One element of the interface through a module that adapts each element cost about 100 ns more than the element compiled in. The adapter builds the element in its own frame and copies the records to the table of the caller.
- **A few procedures hold most of the bytes.** In a typical program, three symbols of the drawing code held about 23 KB: the execution of a draw table with the blends and the glyphs inlined in it, the drawing of a glyph, and the damage by difference. A window calls them two times for each frame. The elements are small and are called 30 to 200 times for each frame.
- **The drawing group was about a third of all the code of the boot image**, in copies that no table names.

## The chosen form: a split, with a coarse border

The cut is not "one package, one module". The part that is large and called a few times goes behind the module. The part that is small and called many times stays compiled into each program.

- An export does a whole piece of work on tables of the caller: "find the damage of this frame", "draw this draw table into these pixels".
- The code that needs slices, an address of a frame of the caller and inlining is the small, hot code. It is the code that must stay in the program in any case: to inline across two bodies of code, compile their sources into one module.
- Two programs with the drawing through a module lost 18 % and 21 % of their file. The draw time of one frame stayed inside the spread between two runs of the same code.

## The refused form: a second kind of import

A "library import" with no description and the calling convention of the language removes the limits of a description: a slice by value, a procedure value, a record that holds an address, a seventh parameter.

It was refused for three reasons.

- The metadata of a module describes each export completely. An export with no description is a function that the console, the manual and a call host cannot call.
- No contract depends on a feature of one programming language. The calling convention of the language is such a feature.
- The check of a replacement compares descriptions. An import with no description cannot be checked, so a replacement of a library has no check at all.

A parameter that the description cannot carry is a sign that the border is in the wrong place.

## What stays compiled in, and why

| Code | Reason |
|---|---|
| The elements, the layout and the input of the interface | Many calls for each frame, state of the caller |
| The wrappers of a kernel entry and of a ring | A few instructions; the loader cannot be loaded by itself |
| The loader, the isolated call and the hash, in a starter | They are the machinery that loads a module |
| A small, hot state of the program (the random generator) | A call for each use costs more than the code |
| All that the root service, the boot program and the call host use | They import nothing: the kernel starts the root service with no loader for imports, and it must not get one |

The last row is a bundle with no table of what it holds yet. A fault in the text code is corrected in the drawing module and stays in the root service until the root service is built again. A replacement does not reach it.

## The subtle points

- **The hash of a program does not stay the same when its library changes.** An import is the hash of the file of the library, written in the importer. What stays the same is the code of the program. The one way to change the library and keep the hash of a program is a replacement. The refused alternative is an import by the hash of a description: it is a new rule of identity, and it weakens "the hash names exactly the code that runs".
- **The build had to change first.** The build key of an importer held the file of each import, so a change of a library built each importer again, whole. The build of a module now has two steps with two keys: the compile step reads no import, and only the conversion does. A change inside a library compiles one module and converts its importers. See [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The incremental build".
- **A description proves the types, not the meaning.** A new version of a record with the same fields passes the check of a replacement and draws wrong pixels. So the version of a record whose values have a meaning is in the name of each export that reads it. Another version is another name, and fails the check by name.
- **The declaration of an import is written by hand, so the tool compares it.** The compiler trusts the types of the declaration, and the linked file holds a name and no type. See [`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "The declaration of an import is checked".
- **The state of a library is data of the module.** The loader gives each program its own copy of each writable segment, so a module variable is data of one program with no new mechanism. The text state of the drawing is a cache of a fixed size, not a result: the caller still supplies each table and the pixels. A work parameter at each call was refused: it costs one of the six parameters for no gain.
- **A cache with no lock has a rule for its callers**: one thread of a program at a time calls the execution of a draw table.
- **A library module has no segment that the loader writes and that is read-only after the load.** Such a segment holds addresses for one base, and a library is at another address in each importer. Each importer would take one place of the table of prepared modules of the root service.
- **A whole-screen picture cannot prove "the same pixels".** Moving a library changes the hash of each program, and the screen shows hashes. The proof is the bytes of a canvas: a fixed set of draw tables, executed by the package and through the module, compared.
- **A replacement of a library reaches almost every program with a window.** It puts code of another origin into each importer, with all the memory and all the handles of each. The check proves the description of each export and nothing of the behaviour. So a replacement of a library module is for a test until the replacement table carries a signature of a principal.
- **A program that starts a child of its own file** gives the child a load source that holds the library, else the load of the child fails.

## The gains, in their true size

- The bytes: about 20 KB for each converted program, less than a tenth of the module files. It is not the reason to do the work.
- The build: a change of the drawing code builds one module, where it built about fifty.
- The module graph says which programs run which drawing code. Before, each program held a copy that no table named.
- A renderer can be replaced with no build of a program.

## What is left, and what blocks it

- **The Picture.** A Picture record names a canvas by its index in a list of addresses. A description cannot carry addresses. The form of a Picture in a description (offsets into one range of bytes, or lent memory objects) is a change of the contract with a design of its own. The programs that draw pictures, the terminal and the compositor wait for it.
- **The cell text** of the programs that draw text themselves: one more export of the drawing module, for one run of cells, not for one glyph. Count the calls of a full terminal first.
- **The error sentences**: a record in, a text out, a cold path.
- **The network libraries**: two users each. The gain is the graph and the replacement of a protocol stack, not the bytes.

Two findings are outside this design and stay open: the formatting of a log line is inlined at each call site, and the failure paths of the bounds checks are a large part of all the code. Neither needs a module.
