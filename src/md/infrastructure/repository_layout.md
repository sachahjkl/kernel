# The layout of the repository

Everything that becomes the system is in one folder, `src`. A program of a third party imports the packages of the system through one source library, `modus`. This file is the design of that layout and of the move that reaches it. The folders are moved. The one source library is not built yet: "The order of the move" says what is built and what is left.

The term source library is in [`docs/GLOSSARY.md`](../../../docs/GLOSSARY.md), "Source library". The flag of the compiler for a source library is `-collection`.

## The layout before the move, and its two faults

The sources of the system were seven folders at the root, beside the folders that are not the system:

- `kernel`, `boot`, `runtime`, `programs`, `modules`: the kernel, the boot program, the memory procedures in assembly, the programs, the modules that are not programs.
- `contract`, `support`: the two source libraries. A source imports `"contract:ring"` and `"support:system"`. The tool gave the compiler `-collection:contract=contract -collection:support=support`. The kernel gets the first flag only, so an import of a support package from the kernel does not compile.
- `tools`, `docs`, `news`, `changelog.d`, `resources`, `flake.nix`.

Two faults of that layout:

1. A reader cannot tell what becomes the system from what builds it, tells it and checks it. A new folder at the root must be added to several lists of the tool and to the file set of the flake, and one that is forgotten is not checked.
2. A program outside the repository has no name for the library of the system. `contract` and `support` are common words: they can be the names of the source libraries of that program. And it needs two flags that point at two folders.

The first fault is removed: the seven folders are under `src`, in the layout below. The second fault stays until the one source library is built: the two libraries keep their two names, and the flags are `-collection:contract=src/library/contract -collection:support=src/library/support`.

## The layout to reach

```
src/
  md/            the intent of each part (this folder)
  kernel/        the kernel
  boot/          the boot program
  runtime/       the memory procedures in assembly
  library/       the source library `modus`
    contract/    what two parties agree on
    support/     what a program compiles in to use the contracts
  programs/      the programs of the system
  modules/       the modules that are not programs
tools/           the tool that builds, tests and publishes
docs/            the guides, the working records, the research, the pictures
news/  changelog.d/  CHANGELOG.md
resources/       the sources of the resources of the boot image, with their licenses
flake.nix  flake.lock  AGENTS.md  README.md  LICENSE
build/           the output, which git ignores
```

### What stays at the root, and why

- **`tools/`.** The tool is not a part of the system: it is a program of the host that builds the system. It must build before anything of `src` does. The command of each project is `odin run tools/<tool>`.
- **`docs/`.** The guides are the documentation, and the site publishes them at addresses made from their names. The working records, the research and the pictures are records of the project.
- **`news/`, `changelog.d/`, `CHANGELOG.md`.** They report the project to a reader.
- **`resources/`.** A resource is not written here: the tool converts it from a source of another party (a font, a pointer theme) or from the mark, and each has its license. The site and the README read the same files.
- **`flake.nix`, `AGENTS.md`, `README.md`, `LICENSE`.** The entry points of a repository are at its root.

`src/md` is under `src` because the intent is kept near the code that it explains.

## The source library `modus`

### The constraints

- A program of a third party writes no relative import, and names the library of the system by one name.
- A program inside the repository imports with the same lines as a program outside it. An example program that is copied out still builds.
- The kernel imports the contract packages only. A contract package imports no support package. This rule is held by the compiler today, not by a convention.
- One spelling for one package: an import line of a package is the same in each file that imports it.
- No relative import in `src`.

### The forms

| Form | Import lines | Flags | The rule of the kernel |
|---|---|---|---|
| A. One source library whose folder is `src` | `"modus:contract/ring"`, `"modus:support/system"` | One: `-collection:modus=src` | Held by the tool. `"modus:kernel"` and `"modus:programs/clock"` are imports too |
| **B. One source library `modus`, in `src/library`** | `"modus:contract/ring"`, `"modus:support/system"` | One: `-collection:modus=src/library` | Held by the tool |
| C. The two source libraries of today, under one folder | `"contract:ring"`, `"support:system"`, as today | Two | Held by the compiler |
| D. `modus` for programs, and `contract` kept for the kernel and for the contract packages | `"contract:ring"` in the kernel and inside `contract`; `"modus:contract/ring"` in each other file | Two for a program | Held by the compiler |

### The chosen form: B

- One name, `modus`, and one folder that holds the library and nothing else. A source library is a named folder of source packages; `src/library` is exactly that.
- The name of the library and the name of its folder are two things. The name is `modus`: it is what a source writes before the `:` of an import. The folder is `library`: it says what the folder is among the parts of `src`.
- One flag, and one entry in the settings of a language server.
- The import line says what the package is: `modus:contract/ring` is a contract, `modus:support/system` is support.
- One spelling for one package, in the kernel, in a program of the system and in a program of a third party.

Why not the others:

- **A** makes the kernel, the boot program and each program importable packages of the library. A third party points at a folder that holds the whole system.
- **C** keeps the two common names, and gives a third party nothing that says `modus`.
- **D** keeps the refusal by the compiler. It was refused because one package then has two import lines, and a writer must know which one a file takes. A contract package that is copied into a program, or a program file that moves into the kernel, changes its imports. It also needs two flags for each program.
- **The folder named `modus`** (`src/modus`, with the flag `-collection:modus=src/modus`). The system modus is the whole of `src`: the kernel, the boot program and the programs are modus as much as the library is. A folder `src/modus` beside `src/kernel` reads as if the kernel were not a part of modus. The import name stays `modus`, because a program of a third party names the system there, not a part of it.

### What form B gives up, and how the rule is kept

With one source library, `"modus:support/system"` compiles in the kernel. The refusal by the compiler is lost. The tool takes its place, with one rule and one reader:

- **The rule**: each import of each source file of `src/kernel` and of `src/library/contract` names a package of the base library or of the core library of the compiler, or a package under `modus:contract/`. Each other import is refused, and a relative import too.
- **Why this is complete**: if no file of the two folders imports outside that list, no chain of imports from the kernel reaches a support package.
- **The reader** is the parser of the compiler's own library, which the tool already uses for the declaration index. It reads each file of the two folders, also a file that a build tag leaves out: the check is stricter than the compiler, never looser.
- **When**: at the start of each build, not only in `kerneltool check`. A writer who adds the import gets a build that stops with the file and the line, as the compiler stops today.
- It replaces the loop of `kerneltool check` that compiles each contract package with the contract library only.

**The test that breaks this design on its first day**: a source file of the kernel that imports `modus:support/sentence`, and a contract package that imports a support package through a relative path. The build must stop and name each file. A host test of the tool holds both cases, on a small tree.

This is the least sure point of the design. If a refusal by the compiler is required, form D is the nearest form that keeps it.

### What a third party types

- In a source: `import "modus:support/system"` and `import operation "modus:contract/operation"`.
- For a language server and for `odin check`: one source library, `modus`, at `<the repository of modus>/src/library`.
- To build a module: the tool. The converter that makes a module file from a linked file is a part of the tool, and the compile needs about fifteen flags that only the tool knows. A build with no tool is not a path that the project supports.
- Not designed: how the tool builds a module whose source is outside the repository (a module table of the third party, and where the tool finds `src/library` and `src/runtime`). The import lines and the one flag are fixed now, so that this later design changes no source.

The words "SDK" and "collection" are not terms of the system: the term is source library, and `-collection` is only the name of the flag.

## The hazards of the move

1. **The lists of folders in the tool.** The paths were text in many places. A path that is missed is a folder that a check no longer reads, with no error. So each folder of the sources has one named constant, in one file of the tool, and each path of the tool is made from them. A host test of the tool checks that each constant, each source of the table of the modules and each folder of a host test names something. The move of a folder is a change of one constant. What was found, beyond the lists that a reader expects (the library flags, the table of the modules, the folders of each check):
   - the files that the site reads from the sources: the license files, the sources of the reference tables, the packages of the type cards, the commands of the console;
   - the files that a command writes into the sources: the font, the portrait, the release number;
   - the paths in the messages of the tool, in the first line that the tool writes into a file of the cryptography, in the script of the search of the site, and in one text of a picture for a developer;
   - the lines that a scenario waits for, and the command with a path that a scenario types;
   - the relative path from the folder of the boot program to the root, in three settings of its compile. The tool now counts the parts of the folder.
2. **The build keys.** A path is an input of a build key, and a build record lists files by path. Each key changes at the move, and the build is whole one time. This costs time only.
3. **The modules must keep their bytes.** A module is compiled with the file names of the sources and not their paths, and an import line is not in the output. So each module file is expected to have the hash of before. This is the proof of a move with no change of behaviour: compare the hash of each module before and after each step ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The hashes of the modules of two builds"). It is not sure: the compiler can order packages by their path. A hash that changes is not a failure of the system, but each picture and each document that shows it changes.
   **A text in a source is not a comment.** Four sources hold the path of a package in a text that the program draws or prints: the card of the program `interface_elements`, a line of the program `manual`, a fact of the program `server`, and a message of the compatibility layer of the cryptography. A rewrite of such a text changes the bytes of its module, and the width of a text in a window. So a step that is proved by the hashes rewrites the comments only. These four texts change with the documents of the library, where a hash can change, and the pictures of the three windows are viewed then.
4. **The debug objects change.** A debug object holds the path of each source from the root of the repository. Each path changes, so each debug object, the debug image and each boot volume change.
5. **The log lines and the pictures that show a path.** A stop report, a stack trace and the debugger show the path of a source with a line. Each becomes four bytes longer. The scenarios of the tool wait for three of these lines, type one command with a path two times, and wait for one line of the debugger: each is made from a constant of the tool. A window that draws a path in a box of a fixed width can cut it or draw over a text: view each picture that shows a path. The pages of the reference of the site show the path of each declaration: the search index and the page of the glossary have a limit of bytes that longer paths can reach.
6. **The pointers of the documents.** A code span of a guide that names a file of the repository is a link on the site. A path that no longer exists stays as plain code, with no error: the link is lost in silence. So the rule is to rewrite, in the same commit as the move of a folder:
   - each path in the guides, the glossary, the README, `AGENTS.md` and this folder. The check below proves this part;
   - each path in the choices of `docs/FIRST_MILESTONE.md`. That record says where each thing is, and a reader opens the file that a choice names. The check does not read it: a choice of the past can name a file that was removed later, and six of its 400 spans name nothing today. The proof of this part is that count: it is the same after the rewrite;
   - each path in a comment of a source.
   Not rewritten: the news entries, the released sections of the changelog, the words of a decision, the reviews. They are records of their time.
   The check ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The source paths in the documents") reads about 660 spans, and found no stale path in the documents that it reads. It refuses a span that starts with the name that a folder had at the root. So after the move of a folder, a span that names a package by its old short path is refused too, and is written from the root. This file names old paths as examples in its hazards: they are reworded with the move of their folder.
7. **A rewrite by prefix is not safe at any place.** The name of a source folder is also a part of a longer path, under the folder of the build and under the folder of the reference pages. `kernel` is the start of `kerneltool`, and `support` and `contract` are words of prose. Rewrite a path only where it starts: after a code mark, a quote, a parenthesis or a space, never after a `/`.
8. **The addresses of the site.** The page of a module has the name of the module, and the page of a guide the name of the guide: no address of a page holds a source folder, so no redirect page is needed. Verify it with the host test of the addresses. The links from a page to a source file follow the commit. A link from another site to a source file of the main branch breaks; that is accepted.
9. **The relative paths that exist.** More files hold a relative path than a search for imports finds. Each one changes when its own folder or its target gets deeper:
   - the tool (two files) and one test of the QUIC package import the cryptography module by a relative import;
   - two packages of the library name the assembly file of the host tests by a relative foreign import;
   - the two assembly files of the host tests include the memory procedures by a path from the root, where the assembler runs;
   - 31 lines in 14 files read a font of `resources` with `#load` and a relative path: one program (7 lines), two tests of modules, and eleven tests of the support packages. A file under `src/library` is two levels deeper than it was, and a file of a program or of a module one level;
   - the three `#load` of the boot program have a default path to the folder of the build. The tool gives each path as a setting, so the default is only what a build with no tool reads.
   One relative import stays as it is: a file of the cryptography imports the folder beside it, and both move together.
   Two rules read these paths, and one chain uses both. The compiler reads the path of a `#load`, of a relative import and of a foreign import from the folder of the file that holds it. The assembler reads the path of an include from the folder where it runs, the root of the repository. So a foreign import of the assembly file of the host tests counts the folders up from its package, and the include inside that file names the memory procedures from the root.
10. **The files of another origin.** A file of the cryptography that is taken from the library of the compiler is proven to be its origin with listed changes only. Three things hold a path:
   - the first line of each of the 40 taken files names the manifest by its path. The tool writes that line from its constant, so the check asks for the new line in each file at the move of the library;
   - each line of the two manifests starts with the path of a file from the root;
   - the list of the system files holds the hash of each file that the project wrote. A file of that list whose line changes (a relative path, an import line, a comment that names a path) gets a new hash, which the command of the system hashes prints. Until then its line holds the word that the tool refuses in place of a hash. The hash of each other file of the list stays: it is the proof that the file kept its bytes.
   A comment of a taken file that names a path cannot be rewritten: the file is its origin with the listed changes and nothing else. No taken file holds such a comment below its first line.
   The list of the import changes in the tool names the support library: it changes with the import lines.
11. **The flake.** The file set of the check names each of the seven source folders. After the move it names `./src` whole. The command of the tool in the flake holds the two library flags on one line.
12. **The history.** Move with `git mv`. Git finds a move as a rename when the file keeps most of its lines, so a step is one commit: the move, and the few lines that the move breaks (a relative path, an include). A commit that only moves does not build, and each step must build. The change of the import lines is another step.
13. **The branches of other agents.** A branch that was made before the move adds its new files at the old paths. The move runs when no other branch is in flight, and each worktree is made again after it.
14. **The fixtures of the host tests.** The tests of the tool that build a small tree with the two libraries, or with a boot program, place them at the folders of the constants: the tool looks for them there. The tests that read a real file of the sources name it by its constant. The tests that only hold a path as a text of a fixture (a row of a line table, a path of a debug object) do not follow the layout, and stay.
15. **The record of the decision.** The decision on the layout of the repository names the folder of the boot program and the two libraries. It is amended first, and the glossary term of the source library says that the project has one.

## The order of the move

Each step is one commit that builds and passes its tests. A step that only moves files proves itself by the hashes of the modules.

1. **The decision and the checks.** Built. The decision on the layout is amended. The check of the source paths in the documents runs in `kerneltool check` (hazard 6). The command `module-hashes` records the hash of each module of a build, and compares a build with a record.
2. **One constant for each path of the tool.** Built. No file moved. Each folder of the system has one named constant, and each path of the tool is made from them (hazard 1). The value of each constant is the path of before, so each command and each build key is the same text: the hashes of the modules are those of step 1.
3. **Move the folders that few documents name**: `runtime`, `boot`, `kernel`, to `src/`. Built. With `git mv`, the three constants, the file set of the flake, the paths of the documents and of the comments for these three. With the move of `runtime`: the include of the two assembly files of the host tests, and the two relative foreign imports of the library. With the move of `boot`: the default paths of its three `#load`. The expected lines of the scenarios follow the constants. The hashes of the modules are those of step 1; the debug objects change.
4. **Move `modules` and `programs`** to `src/`, in the same way. Built. Most of the pointers of the documents are here. With it: the three relative imports of the cryptography module, and the relative `#load` of a font in one program and in two tests of modules. No text that a program draws changes (hazard 3). View the pictures that show a path: a stop report, a stack trace, the debugger.
5. **Move `contract` and `support`** to `src/library/`. Built. The two flags stay, with their new folders: `-collection:contract=src/library/contract -collection:support=src/library/support`. No import line changes, so the compiler still holds the rule of the kernel. With it: the relative `#load` of a font in the tests of the support packages, the two relative foreign imports again, the first line of each taken file of the cryptography, the two manifests and the hashes of the system files (hazards 9 and 10).
6. **One source library.** In one commit: the check of the imports of the kernel and of the contract packages, with its host test; the one flag `-collection:modus=src/library` in the tool and in the flake; each import line (`"contract:` becomes `"modus:contract/`, `"support:` becomes `"modus:support/`: 1328 lines in 411 files, the tool among them); the list of the import changes of the cryptography and the hashes of its system files; the end of the two old flags and of the contract-only compile. In the tool, the two libraries of the constants become one, whose folder is `src/library`. The check and the loss of the refusal by the compiler are in the same commit, so the rule is held at each commit. The hashes of the modules are those of step 1.
7. **The documents of the library**: the glossary term, the guide of the module contract where it names the libraries, the README, the four texts of the sources that name a package (hazard 3), and one example program that is built from a copy outside `src`, as the proof of the second constraint. The hashes of the modules that hold one of the four texts change here.

The full check runs after step 6 and after step 7.

## What the move of the folders showed

- **The constants held.** In the tool, the move of the seven folders is seven lines of one file. One text was left outside them: a sentence of the page of the modules of the site named the folder of the programs. It is made from the constant now.
- **A folder named with no `/` is not a path for the check.** Five sentences of the guides listed the folders of a check or of the site by their names alone. The check of the source paths reads a span that starts with a name and a `/`, so it cannot see them: they were found by a search for each name as a whole span.
- **A comment can be a text of a page.** The comments of the contract packages and of the kernel become pages of the reference of the site. Their paths are longer on those pages.
- **An example of a log line is a path too.** The guides, the glossary and the comments quote a stop report and a command of a breakpoint with the path of a source. Each quote changes with the move, in a fence of code also: the system prints the new path.
- **A fixture is not a pointer.** The host tests of the tool hold paths as texts of their own small trees, in strings and in the comments that explain those strings. They stay. A rewrite of the tests of the tool reads only the lines that are whole comments, and never the test of the check of the source paths.
- **The count of a rewrite.** The proof of a batch is the count of the lines that match before, and no match after. The count of the changed lines of the whole change is smaller than the sum of the batches: a line that names a folder of two steps changes two times and counts one time.
- **The record of the choices keeps what is gone.** Five spans of the working record name a file or a folder that was removed before the move. They keep their old text: a new path there names nothing either, and says that the thing was once under `src`.
