title: The console debugs a program
date: 2026-11-13
release: next
picture: none
kind: Shown
guide: docs/TOOLS.md

The console can now debug a program that runs. The command debug with the name of a program attaches the debugger. A breakpoint is set at a procedure by its name, or at a line of a source file. When a thread stops there, the console shows the frames of its stack with the procedure and the line of each one, its local variables with their types and their values, and one variable by a path such as `pair.next^.first`. A thread runs one instruction, or one source line, at a time. A watch stops a thread at the instruction that writes some bytes. Each result is a table, so the commands of the console filter it as any table. The debugger is a service of the system, not code of the console: a developer on another machine calls the same commands with `kerneltool call`, and reads the source line from the repository. Not each program can be debugged: a program with no grant can, and a service cannot, because a debugger gets each access of the program that it debugs.
