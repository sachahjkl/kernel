title: The same source gives the same bytes on all threads of the compiler
date: 2026-11-11
release: 0.64.0
picture: none
kind: Measured
guide: docs/REPRODUCIBLE_BUILD.md

The hash of a module is its identity, so one source must give one module. In the release 0.59.0, the threads of the compiler changed the order of the declarations, and a module could differ from one build to the next; a patch of the compiler corrected it. With the release dev-2026-11a of Odin, the compiler runs on all its threads with no patch. `kerneltool repeat all 20` built each module 20 times, with one compiler thread for each of the 16 processors of the host, at a host load of 24 to 42. Each of the 64 modules gave one module, one LLVM IR file and one object, and the boot program gave one file. Each `kerneltool check` builds everything two times and compares the bytes.
