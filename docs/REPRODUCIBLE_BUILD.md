# One source, one module: the build and the threads of the compiler

A module of this system is named by the hash of its bytes, so one source must give one module: the same bytes at each build. This document says how the build keeps that rule, how the tool proves it, and what was found when the compiler broke it.

**Why it matters.** A module is named by the hash of its bytes, and a system is a list of such hashes (`PROPERTIES.md`, "11. Reproducible system"). If one source can give two different modules, the hash names a build, not a source: a third party cannot build the system again and compare, and the signed list of the system (`TRUSTED_BOOT.md`) proves less. So a nondeterministic compiler is a fault of the system, found and closed here.

**The state of today, in short.**

- The flake pins the release `dev-2026-11a` of Odin, with no patch (`flake.nix`, `odinRelease`).
- The compiler runs on all its threads: no build passes `-thread-count` (section 7).
- Each full check builds everything two times and compares every output, then builds every module a third time with no debug information (sections 6 and 8).
- A usual build keeps a module whose inputs are the same as at its last build ("The incremental build and the same bytes"). Each build of a check is a whole build.
- Sections 1 to 5 are the record of a fault of the older release `dev-2026-05`, its correction by a patch, and the measures. That patch is no longer applied, and its file is no longer in the repository.

**The commands.**

| Command | What it does | When to use it |
|---|---|---|
| `kerneltool check` | Builds the modules and the boot program a second time and compares each output with the first build, byte for byte. The two builds are whole builds | At each full check (`kerneltool screenshots` runs the same second build): it catches a compiler that lost the rule |
| `kerneltool repeat <module> <count>` | Builds one module `count` times, with no machine, and counts the distinct results of each output | After a change of one module that looks nondeterministic |
| `kerneltool repeat all <count> [processes]` | The same for every module and the boot program, one row each | After a change of the compiler, of its flags or of LLVM |

**What a build is not.** The rule covers the modules, their intermediate outputs, the resources and the boot program. It does not cover the tool `kerneltool` itself, which is not a module (section 6).

**For whom.** A reader who changes the compiler, its flags or the tool that builds the modules.

**The map of this document.** "The outputs that the tool compares" and "What the build does to give the same bytes": the mechanism of today. "The incremental build and the same bytes": why a build can keep an output. "1. The cause" to "5. The parallelism of the tool": the fault of the old release and its patch. "6. What is proved, and what is not". "6a. The release dev-2026-11a of the compiler" and "7. The compiler with no patch, on all its threads": the compiler of today. "8. The debug information": why `-debug` does not change the identity of a module.

## The outputs that the tool compares

The tool compares each output of a build, not only the module. A difference in the LLVM IR or in the object is the early sign: an object can differ while the module made from it is still the same bytes, and the next change of the source then makes the module differ.

| Output | File | Who makes it |
|---|---|---|
| The module | `build/modules/<name>.module` | the converter of the tool, from the linked file |
| Its LLVM IR | `build/modules/<name>/<name>.ll` | the Odin compiler |
| Its object | `build/modules/<name>/objects/<name>.o` | `llc`, from the LLVM IR |
| Its debug object | `build/modules/<name>.debug` | the tool, from the DWARF of the linked file |
| Each pointer theme file | `build/pointers/*.pointers` | the tool (`docs/POINTERS.md`); compared by `check` only |
| The boot program and its object | `build/boot/BOOTX64.EFI`, `build/boot/boot.obj` | `lld-link`, the Odin compiler |

When an output differs:

- Each distinct content stays in `build/different_builds/<owner>/` (the name of the module, `pointers` or `boot`), as `<file name>.variant_1`, `.variant_2`, and so on. No build resets this folder; each `check` and each `repeat` empties it first.
- The tool prints where the first difference is: the line of an LLVM IR file with the two lines, the part of a module file, the byte of another file.
- `check` fails with the line `kerneltool: test failed: the <kind> <path> is not the same bytes after a second build`.

When no output differs, `check` prints one line with the counts, for example "84 modules, their LLVM IR, their objects and their debug objects, 2 pointer theme files, and the boot program and its object are the same bytes after a second build". It writes the same line in `build/reproducible_build.txt`, which the site quotes.

`repeat` prints one summary for each output, in the form `1 distinct in 30 builds`, or `3 distinct in 30 builds: 27, 2, 1` with the count of builds of each distinct result. `repeat all` prints a table: the module, the builds, then the distinct files, LLVM IR files, objects and debug objects. Its count is 2 or more. Its exit status is a failure when one output has more than one distinct content.

## What the build does to give the same bytes

A deterministic compiler is necessary and not sufficient: the build itself must put no fact of the host in an output. `build_module` (`tools/kerneltool/modules.odin`) does this:

- **No path of the build folder.** The compiler gets `-source-code-locations:filename`: a message of a check holds the file name and the line, not the full path. So the hash of a module does not depend on the folder of the build.
- **No build identifier.** The linker gets `--build-id=none`.
- **An empty folder for each build.** The tool resets the folder of the objects and the folder of the LLVM IR before it compiles, so no file of an earlier build enters the link.
- **A fixed order.** The boot image holds the modules in the order of the module table (`module_builds`), not in the order in which the processes end.
- **A pinned compiler.** The flake pins the release of Odin by its tag and its hash, and `llc` comes from the LLVM of that compiler (18). `flake.lock` pins the other tools.
- **No path of the host in a debug object.** A source path in a debug object is from the root of the repository or of the Odin installation. The tool refuses to write a debug object that holds an absolute path or the folder of the build (section 8).

## The incremental build and the same bytes

The rule of this document is that the same inputs give the same bytes. The incremental build uses the rule in the other direction: when the inputs of a module are the same as at its last build, its output of that build is the output that a new build would give, so the tool keeps it and starts no compiler. `TOOLS.md`, "The incremental build", says what an input is and when a module is kept.

Three facts keep the two rules apart:

- **The proof never rests on a kept output.** A check that compares two builds must run the compiler two times. `check`, `screenshots` and `repeat` build whole, and the procedures of the second build (`outputs_same_after_second_build`, `modules_same_without_debug_information`) set the whole build themselves. A build that kept its outputs would compare a file with itself.
- **A kept output is as sound as the list of the inputs.** The rule of the same bytes says nothing about an input that the build key does not hold. So the key holds each file that the compiler lists, every file of the folder of each package, the commands with each flag, the programs of the build and the sources of the tool, and the tool builds in every case of doubt.
- **A compiler that loses the rule is still caught.** With a compiler that is not deterministic, a kept module is one of the distinct results of its inputs: a valid module, with a valid hash, and each module that imports it names that hash. The next full check builds whole two times and finds the difference.

The LLVM IR and the object of a kept module stay from the build that made the module. No step of a usual build reads them; the checks that read them build whole first.

## 1. The cause

The analysis below is of the tag `dev-2026-05` of Odin; the line numbers are of that source. The release `dev-2026-11a` is in sections 6 and 7.

- `src/main.cpp`, `init_global_thread_pool`: `worker_count = thread_count; // +1`. So `-thread-count:1` gives the main thread and one worker. A count of `/proc/PID/task` during a build gave 2 threads.
- `src/checker.cpp`, `check_collect_entities_all`: one pool task for each file. Each task calls `add_entity_and_decl_info`, which adds the entities of its file to the shared queue `info.entity_queue` (`mpsc_enqueue`). The worker steals tasks of the main thread, so the order of that queue changes from one build to the next.
- `check_add_entities_from_queues` turns that queue into `info.entities`. `check_all_global_entities` and `check_unchecked_bodies` walk the declarations in that order. That order sets the order of the instances of polymorphic procedures and of the types in the LLVM module. The inliner of `-o:speed` works in that order, so the machine code changes too.
- `global_entity_id` (`src/entity.cpp`) gives each entity its number in the order of creation. The name of a static variable of a procedure carries that number (`lb_build_static_variables`, `src/llvm_backend_stmt.cpp`): so that name changes from one build to another.
- `-no-threaded-checker` changes only `check_procedure_bodies`. The other phases use the pool.

Measured with the stock compiler and the flags of the tool, the process pinned to one processor: `console` gave 3 distinct LLVM IR files in 60 builds (49, 10, 1), and `host` gave 2 (56, 4).

## 2. The correction

For `dev-2026-05`, the patch `thread_count_counts_the_main_thread.patch` corrected the compiler. The flake applied it until the release `dev-2026-11a` made it needless (section 7). With the patch, `-thread-count:N` means N threads in all, as the backend of the compiler already counts. With `-thread-count:1` no worker exists, and the main thread runs each task in one order. A thread that waits for the fields of an `#soa` type with no worker runs the tasks of its own queue.

Two other forms do not correct it:
- A flag or an environment variable of the stock compiler: none gives one thread.
- `-o:none` IR, a sort by the tool, then `opt -O3`: this changes the code of each module and leaves the cause in the compiler.

## 3. The compile time

One module, the stock compiler (`-thread-count:1 -no-threaded-checker`, 2 threads) against the patched compiler (`-thread-count:1`, 1 thread). Each value is the least of 5 runs. The runs of the two compilers alternate. The host load was 13 (`uptime`, 16:03).

| Module | Stock | Patched |
|---|---|---|
| `console` | 2.27 s | 2.35 s |
| `kernel` | 1.23 s | 1.23 s |

The Odin step of all 61 modules, the two compilers one after the other on each module, at a load of 17 to 28: 39.2 s against 40.3 s, then 32.9 s against 34.1 s. The processor time was equal (36.5 s against 36.3 s, then 32.4 s against 32.4 s). The second thread of the stock compiler saves about 3 % of the wall time. The parallel build of the tool (section 5) gives more.

## 4. A deterministic order inside the compiler

A compiler that uses several threads gives one result only with a fixed order at each place where the threads meet. The places in `dev-2026-05`:

- **Parser** (`src/parser.cpp`): `parser_add_package` gives `pkg->id` in the order in which the parse tasks end. The files of a package are sorted by name later (`sort_file_by_name`, `src/checker.cpp`), but the packages are not: the order of the file names of the source locations changed in `kernel.module` between two builds.
- **Checker queues** (`src/checker.cpp`, `src/check_decl.cpp`, `src/check_type.cpp`):
  - `info.entity_queue` (`add_entity_and_decl_info`) and `info.definition_queue`.
  - `pkg->exported_entity_queue`, a queue with several readers (`check_export_entities`).
  - `info.all_procedures_queue` (`check_procedure_later`) and `procs_to_check`.
  - `soa_types_to_complete`, `global_untyped_queue`, `required_global_variable_queue` and the other queues of `check_decl.cpp`.
- **Counters that become names**:
  - `global_entity_id` (`src/entity.cpp`): the names of static variables.
  - `m->global_array_index.fetch_add` (`src/llvm_backend_general.cpp`, `src/llvm_backend_const.cpp`, `src/llvm_backend_proc.cpp`): the names of constant globals.
  - `name_id.fetch_add` (`src/llvm_backend_general.cpp`): the names `$anon-N`.
- **Backend** (`src/llvm_backend.cpp`): `m->procedures_to_generate` and `m->generated_procedures`. `llvm_global_entity_cmp` sorts the first global procedures and types by their place in the source. The instances that the backend makes later keep the order of the queue.

A sort of the output after the fact is not enough. The order and the names exist before the LLVM optimization. The inliner works in the order of the call graph that it receives, and one inline decision changes the cost of the next one. A sort of the optimized IR cannot give back the code that another order gave. So each merge of a queue must sort by a stable key (the file path, then the offset in the file), and each counter must give its numbers after that sort.

This patch is not written. The estimate: several hundred lines in about 8 files, against the 91 lines of the patch file for `dev-2026-05` (31 lines of code changed, the rest is its reason). For the upstream project, offer the small fix first: `-thread-count:1` that gives two threads is a fault with a small, clear fix. Offer the wide patch only after `kerneltool repeat all` proves it with several threads.

## 5. The parallelism of the tool

The parallelism is one level up: `kerneltool build` runs one compiler process for each module, several at once, and assembles the boot image in the fixed order of the module table (`tools/kerneltool/parallel_build.odin`).

- **One process for each module.** Each module is built by its own process of the tool (the command `module`), which runs one compiler. The tool runs as many processes at once as the host has processors; `kerneltool build <processes>` and `repeat all <count> <processes>` set another count.
- **Levels.** A module needs the files of its imports at its conversion: their hashes go into its import table. So a module with no import is in level 0, and a module is in the level after the highest level of its imports. Each level starts after the level before it ended.
- **No shared file.** Each module writes only in its own folder and its own `<name>.module`, so two processes never write one file.
- **One order of the output.** The tool keeps the output of each process and prints it whole, in the order of the module table.

Measured with one compiler thread for each process, the whole `kerneltool build` in alternation, host load 20 to 46: one module process at a time (`build 1`) 171 s and 99 s; 16 at once 82 s and 58 s. The load was above 8, so these numbers are not a valid measure of speed: they show the order of the gain only.

## 6. What is proved, and what is not

Proved:
- `kerneltool repeat all 100` with the patched compiler, under a host load of 9.5 to 62: one module, one LLVM IR file and one object for each of 61 modules, and one boot program and one object.
- Each full check builds everything two times and compares the module, the LLVM IR, the object and the debug object of each module, the pointer theme files, and the boot program and its object (`outputs_same_after_second_build` in `tools/kerneltool/repeat.odin`). The module table has 84 modules today; the counts 61 and 64 in this document are those of the day of each measure.

Not proved:
- Another version of the Odin compiler or of LLVM. A new version needs `repeat all` again.
- Another host, or another count of processors.
- The wait for an `#soa` type with no worker. No small program of the tests reached that case, and two of them crash the stock compiler too.
- The tool `kerneltool` itself. With the default count of threads, 6 builds gave 6 distinct files. It is not a module: no program of the system names it by its hash, so the rule does not cover it.

## 6a. The release dev-2026-11a of the compiler

`flake.nix` pins the release `dev-2026-11a` itself, by its tag and its hash; on 2026-11-11 Nixpkgs was six releases behind.

What changed in the compiler for this subject, read in its release notes and in its source:

- The fault of section 1 is still there: `init_global_thread_pool` makes `thread_count` workers beside the main thread. The patch for this release is one line (`worker_count = thread_count - 1`).
- `wait_signal_until_available` has no caller left in the compiler, so the second part of the patch for `dev-2026-05` (a thread that waits runs the tasks of its own queue) is not needed.
- The release notes of `dev-2026-10` say: the whole semantic checker runs on several threads, the check of the globals gives an order of the code that does not depend on the threads, and the polymorphic procedures were rewritten with corrections of races. The queues of the checker are one queue for each thread. So the question of section 4 (a deterministic order with several threads) has a better start: it must be measured with `kerneltool repeat all` and more than one thread before any wide patch is written.

## 7. The compiler with no patch, on all its threads

Two measures, on 2026-11-11, with the release `dev-2026-11a`:

- 30 builds each of `console`, `host`, `root` and `compositor` with `-thread-count` 1, 4 and 16, the patch of one line applied: one LLVM IR for each module, and the same one for the three counts (90 builds, 1 hash, four times).
- `kerneltool repeat all 20` with the compiler as its release gives it (no patch), with no `-thread-count` (the compiler takes one thread for each processor, 16 here), one module process for each processor, a host load of 24 to 42: 64 modules with 1 distinct module, 1 distinct LLVM IR and 1 distinct object each, and the boot program with 1 distinct file and 1 distinct object.

So the flake applies no patch, and no build passes `-thread-count`. Sections 1 to 5 describe the fault of the release `dev-2026-05`. The check of each full check stays: it builds two times and compares each output, so a compiler that loses this property is caught at the next check.

**After a change of the release of the compiler**, run `kerneltool repeat all <count>` before the change is merged: two builds of a full check find a fault that shows in half of the builds, and can miss one that shows in one build of sixty (section 1 has such a case: 49, 10 and 1).

Limits: one host, one release, 20 builds of each module. `kerneltool repeat all 100` on a quiet host is not done.

## 8. The debug information

The tool compiles each module with `-debug`, for the line table of its debug object (`MODULE_CONTRACT.md`, "Debug information"). A debug object says which line of the source an address of the module belongs to; it is a separate file, named by the hash of its module. The identity of a module must not depend on it: a module built with `-debug` and the same module built without it must be the same bytes.

- The converter copies the segments of the linked file only: the sections `.debug_*` are not in the module.
- The base library and the support library of the modules do not read `ODIN_DEBUG`, the constant that `-debug` sets (no `when ODIN_DEBUG` in `base`, `contract`, `support`, `modules` or `programs`). LLVM does not let a debug location change the code that it emits.
- The proof is a build: after the second build, `kerneltool check` builds every module a third time with no `-debug`, in `build/modules_without_debug_information`, and compares each module byte for byte with the module of the build. A difference fails the check and names the part of the module where it is.
- The debug object is an output of the build like the others: the second build compares it too, and `kerneltool repeat` counts its distinct contents in a column of its own. A source path in it is from the root of the repository or of the Odin installation, never absolute: the tool refuses to write a debug object with an absolute path of a file or with the folder of the build in its bytes, so it does not depend on the folder or the host of the build.
