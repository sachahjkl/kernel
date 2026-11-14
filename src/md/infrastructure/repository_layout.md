# The layout of the repository

Everything that becomes the system is in one folder, `src`. A program of a third party imports the packages of the system through one source library, `modus`. This file is the design of that layout and of the move that reaches it. It is written before the move: it is the brief of the agent that moves the code.

The term source library is in [`docs/GLOSSARY.md`](../../../docs/GLOSSARY.md), "Source library". The flag of the compiler for a source library is `-collection`.

## The layout of today

The sources of the system are seven folders at the root, beside the folders that are not the system:

- `kernel`, `boot`, `runtime`, `programs`, `modules`: the kernel, the boot program, the memory procedures in assembly, the programs, the modules that are not programs.
- `contract`, `support`: the two source libraries. A source imports `"contract:ring"` and `"support:system"`. The tool gives the compiler `-collection:contract=contract -collection:support=support`. The kernel gets the first flag only, so an import of a support package from the kernel does not compile.
- `tools`, `docs`, `news`, `changelog.d`, `resources`, `flake.nix`.

Two faults of this layout:

1. A reader cannot tell what becomes the system from what builds it, tells it and checks it. A new folder at the root must be added to several lists of the tool and to the file set of the flake, and one that is forgotten is not checked.
2. A program outside the repository has no name for the library of the system. `contract` and `support` are common words: they can be the names of the source libraries of that program. And it needs two flags that point at two folders.

## The layout to reach

```
src/
  md/            the intent of each part (this folder)
  kernel/        the kernel
  boot/          the boot program
  runtime/       the memory procedures in assembly
  modus/         the source library `modus`
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
| **B. One source library `modus`, in `src/modus`** | `"modus:contract/ring"`, `"modus:support/system"` | One: `-collection:modus=src/modus` | Held by the tool |
| C. The two source libraries of today, under one folder | `"contract:ring"`, `"support:system"`, as today | Two | Held by the compiler |
| D. `modus` for programs, and `contract` kept for the kernel and for the contract packages | `"contract:ring"` in the kernel and inside `contract`; `"modus:contract/ring"` in each other file | Two for a program | Held by the compiler |

### The chosen form: B

- One name, `modus`, and one folder that holds the library and nothing else. A source library is a named folder of source packages; `src/modus` is exactly that.
- One flag, and one entry in the settings of a language server.
- The import line says what the package is: `modus:contract/ring` is a contract, `modus:support/system` is support.
- One spelling for one package, in the kernel, in a program of the system and in a program of a third party.

Why not the others:

- **A** makes the kernel, the boot program and each program importable packages of the library. A third party points at a folder that holds the whole system.
- **C** keeps the two common names, and gives a third party nothing that says `modus`.
- **D** keeps the refusal by the compiler. It was refused because one package then has two import lines, and a writer must know which one a file takes. A contract package that is copied into a program, or a program file that moves into the kernel, changes its imports. It also needs two flags for each program.

### What form B gives up, and how the rule is kept

With one source library, `"modus:support/system"` compiles in the kernel. The refusal by the compiler is lost. The tool takes its place, with one rule and one reader:

- **The rule**: each import of each source file of `src/kernel` and of `src/modus/contract` names a package of the base library or of the core library of the compiler, or a package under `modus:contract/`. Each other import is refused, and a relative import too.
- **Why this is complete**: if no file of the two folders imports outside that list, no chain of imports from the kernel reaches a support package.
- **The reader** is the parser of the compiler's own library, which the tool already uses for the declaration index. It reads each file of the two folders, also a file that a build tag leaves out: the check is stricter than the compiler, never looser.
- **When**: at the start of each build, not only in `kerneltool check`. A writer who adds the import gets a build that stops with the file and the line, as the compiler stops today.
- It replaces the loop of `kerneltool check` that compiles each contract package with the contract library only.

**The test that breaks this design on its first day**: a source file of the kernel that imports `modus:support/sentence`, and a contract package that imports a support package through a relative path. The build must stop and name each file. A host test of the tool holds both cases, on a small tree.

This is the least sure point of the design. If a refusal by the compiler is required, form D is the nearest form that keeps it.

### What a third party types

- In a source: `import "modus:support/system"` and `import operation "modus:contract/operation"`.
- For a language server and for `odin check`: one source library, `modus`, at `<the repository of modus>/src/modus`.
- To build a module: the tool. The converter that makes a module file from a linked file is a part of the tool, and the compile needs about fifteen flags that only the tool knows. A build with no tool is not a path that the project supports.
- Not designed: how the tool builds a module whose source is outside the repository (a module table of the third party, and where the tool finds `src/modus` and `src/runtime`). The import lines and the one flag are fixed now, so that this later design changes no source.

The words "SDK" and "collection" are not terms of the system: the term is source library, and `-collection` is only the name of the flag.

## The hazards of the move

1. **The lists of folders in the tool.** The paths are text in many places: the two library flags and the list of the contract packages, the table of the modules (88 rows with a source), the folders of the incremental build, of the rule on comments, of the fixed addresses, of the text cut, of the declaration index and of the pointers, the list of the test folders of `kerneltool check`, the memory procedures, the boot program and its assembly file, the manifest of the origin of the cryptography, the source of the release number that the changelog command writes. A path that is missed is a folder that a check no longer reads, with no error. So the first step gives each path one named constant, before any file moves.
2. **The build keys.** A path is an input of a build key, and a build record lists files by path. Each key changes at the move, and the build is whole one time. This costs time only.
3. **The modules must keep their bytes.** A module is compiled with the file names of the sources and not their paths, and an import line is not in the output. So each module file is expected to have the hash of before. This is the proof of a move with no change of behaviour: compare the hash of each module before and after each step. It is not sure: the compiler can order packages by their path. A hash that changes is not a failure of the system, but each picture and each document that shows it changes.
4. **The debug objects change.** A debug object holds the path of each source from the root of the repository. Each path changes, so each debug object, the debug image and each boot volume change.
5. **The log lines and the pictures that show a path.** A stop report, a stack trace and the debugger show `programs/fault/main.odin:34`. Each becomes four bytes longer. The scenarios of the tool wait for some of these lines. A window that draws a path in a box of a fixed width can cut it or draw over a text: view each picture that shows a path.
6. **The pointers of the documents.** A code span of a guide that names a file of the repository is a link on the site. A path that no longer exists stays as plain code, with no error: the link is lost in silence. So the rule is to rewrite, in the same commit as the move of a folder:
   - each path in the guides, the glossary, the README, `AGENTS.md`, this folder, and the choices of `docs/FIRST_MILESTONE.md`. That record says where each thing is, and a reader opens the file that a choice names;
   - each path in a comment of a source and in a message of the tool.
   Not rewritten: the news entries, the released sections of the changelog, the words of a decision, the reviews. They are records of their time.
   A check comes first, so that the rewrite can be proven: each code span of a guide, of the glossary, of the README and of this folder that starts with the name of a source folder names a file or a folder that exists. Run it before the move, to find the paths that are stale today.
7. **A rewrite by prefix is not safe at any place.** `boot/` is also in `build/boot/`, `modules/` is also in `docs/reference/modules/` and `build/modules/`, `kernel` is the start of `kerneltool`, and `support` and `contract` are words of prose. Rewrite a path only where it starts: after a code mark, a quote, a parenthesis or a space, never after a `/`.
8. **The addresses of the site.** The page of a module has the name of the module, and the page of a guide the name of the guide: no address of a page holds a source folder, so no redirect page is needed. Verify it with the host test of the addresses. The links from a page to a source file follow the commit. A link from another site to a source file of the main branch breaks; that is accepted.
9. **The relative paths that exist.** A few files hold a relative path: the tool and two tests import the cryptography module by a relative import, and two packages name the assembly file of the host tests. `src/modus` is one level deeper than `contract` and `support` were, so the count of `..` changes for a file under it.
10. **The files of another origin.** A file of the cryptography that is taken from the library of the compiler is proven to be its origin with listed changes only, and its first line names the manifest by its path. A change of its imports is a change that the check must list.
11. **The flake.** The file set of the check names each source folder. After the move it names `./src` whole. The command of the tool in the flake holds the library flags.
12. **The history.** Move with `git mv`, in a commit that changes no line of a moved file. Git then finds each move as a whole rename, and the history of a file follows it. The change of the import lines is another commit.
13. **The branches of other agents.** A branch that was made before the move adds its new files at the old paths. The move runs when no other branch is in flight, and each worktree is made again after it.
14. **The fixtures of the host tests.** The tests of the tool build small trees whose folders have the names `contract` and `support`, and name source paths in their expected texts.
15. **The record of the decision.** The decision on the layout of the repository names `boot/` and the two libraries. It is amended first, and the glossary term of the source library says that the project has one.

## The order of the move

Each step is one commit that builds and passes its tests. A step that only moves files proves itself by the hashes of the modules.

1. **The decision and the checks.** Amend the decision on the layout. Add the check of the source paths in the documents (hazard 6). Record the hash of each module of the build.
2. **One constant for each path of the tool.** No file moves. Each folder of the system has one named constant, and each list is made from them. The hashes of the modules are those of step 1.
3. **Move the folders that few documents name**: `runtime`, `boot`, `kernel`, to `src/`. With `git mv`, the constants, the file set of the flake, the paths of the documents and of the comments for these three, the expected lines of the scenarios. The hashes of the modules are those of step 1; the debug objects change.
4. **Move `modules` and `programs`** to `src/`, in the same way. Most of the pointers of the documents are here. View the pictures that show a path.
5. **Move `contract` and `support`** to `src/modus/`. The two flags stay, with their new folders: `-collection:contract=src/modus/contract -collection:support=src/modus/support`. No import line changes, so the compiler still holds the rule of the kernel. Correct the relative paths of hazard 9.
6. **One source library.** In one commit: the check of the imports of the kernel and of the contract packages, with its host test; the one flag `-collection:modus=src/modus` in the tool and in the flake; each import line (`"contract:` becomes `"modus:contract/`, `"support:` becomes `"modus:support/`: about 1300 lines in about 400 files); the end of the two old flags and of the contract-only compile. The check and the loss of the refusal by the compiler are in the same commit, so the rule is held at each commit. The hashes of the modules are those of step 1.
7. **The documents of the library**: the glossary term, the guide of the module contract where it names the libraries, the README, and one example program that is built from a copy outside `src`, as the proof of the second constraint.

The full check runs after step 6 and after step 7.
