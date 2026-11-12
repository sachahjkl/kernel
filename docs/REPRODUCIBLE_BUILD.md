# One source, one module: the build and the threads of the compiler

Property 11 makes the hash of a module its identity, so one source must give one module. The flake pins the release `dev-2026-11a` of Odin, with no patch, and the compiler runs on all its threads (section 7). Sections 1 to 5 give the fault of the release `dev-2026-05` with `-thread-count:1`, its correction by a patch, and the measures.

## 1. The cause

The analysis below is of the tag `dev-2026-05` of Odin; the line numbers are of that source. The release `dev-2026-11a` is in sections 6 and 7.

- `src/main.cpp`, `init_global_thread_pool`: `worker_count = thread_count; // +1`. So `-thread-count:1` gives the main thread and one worker. A count of `/proc/PID/task` during a build gave 2 threads.
- `src/checker.cpp`, `check_collect_entities_all`: one pool task for each file. Each task calls `add_entity_and_decl_info`, which adds the entities of its file to the shared queue `info.entity_queue` (`mpsc_enqueue`). The worker steals tasks of the main thread, so the order of that queue changes from one build to the next.
- `check_add_entities_from_queues` turns that queue into `info.entities`. `check_all_global_entities` and `check_unchecked_bodies` walk the declarations in that order. That order sets the order of the instances of polymorphic procedures and of the types in the LLVM module. The inliner of `-o:speed` works in that order, so the machine code changes too.
- `global_entity_id` (`src/entity.cpp`) gives each entity its number in the order of creation. The name of a static variable of a procedure carries that number (`lb_build_static_variables`, `src/llvm_backend_stmt.cpp`): so that name changes from one build to another.
- `-no-threaded-checker` changes only `check_procedure_bodies`. The other phases use the pool.

Measured with the stock compiler and the flags of the tool, the process pinned to one processor: `console` gave 3 distinct LLVM IR files in 60 builds (49, 10, 1), and `host` gave 2 (56, 4).

## 2. The correction

For `dev-2026-05`, the patch `thread_count_counts_the_main_thread.patch` corrects the compiler. With the patch, `-thread-count:N` means N threads in all, as the backend of the compiler already counts. With `-thread-count:1` no worker exists, and the main thread runs each task in one order. A thread that waits for the fields of an `#soa` type with no worker runs the tasks of its own queue.

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

The parallelism is one level up: `kerneltool build` runs one compiler process for each module, several at once, and assembles the boot image in the fixed order of the module table.

Measured with one compiler thread for each process, the whole `kerneltool build` in alternation, host load 20 to 46: one module process at a time (`build 1`) 171 s and 99 s; 16 at once 82 s and 58 s. The load was above 8, so these numbers are not a valid measure of speed: they show the order of the gain only.

## 6. What is proved, and what is not

Proved:
- `kerneltool repeat all 100` with the patched compiler, under a host load of 9.5 to 62: one module, one LLVM IR file and one object for each of 61 modules, and one boot program and one object.
- Each full check builds everything two times and compares the module, the IR and the object of each module, the pointer theme files and the boot program.

Not proved:
- Another version of the Odin compiler or of LLVM. A new version needs `repeat all` again.
- Another host, or another count of processors.
- The wait for an `#soa` type with no worker. No small program of the tests reached that case, and two of them crash the stock compiler too.
- The tool `kerneltool` itself. With the default count of threads, 6 builds gave 6 distinct files. It is not a module, and property 11 does not cover it.

## 6. The release dev-2026-11a of the compiler

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

Limits: one host, one release, 20 builds of each module. `kerneltool repeat all 100` on a quiet host is not done.

