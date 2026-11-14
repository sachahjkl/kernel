title: A stop report names the procedure and the line
date: 2026-11-13
release: 0.92.0
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

When a program stops on a fault, the console, the test program `errors` and the developer tool `inspect` now name each frame of its stack trace with its procedure and its source line: `fault::three + 0x8 in fault (programs/fault/main.odin:15)`, where they showed `fault + 0x1478`. The names come from a debug object that the build writes for each module, a small table of procedures and lines that a program reads with a binary search. The debug objects are one file on the boot volume, beside the boot program: the boot image does not grow, and a module has the same bytes, so the same hash, with and without them. The kernel still writes offsets on its log. A debugger in the console is designed, not built.
