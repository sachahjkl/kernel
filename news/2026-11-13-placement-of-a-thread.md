title: A thread can be kept on chosen processors
date: 2026-11-13
release: next
picture: none
kind: Shown
guide: docs/SCHEDULING.md

Each thread now has a placement: the set of the processors that can run it. A thread with no placement runs on each processor, as before. A program can only narrow the set of its own threads. Only the machine handle with the right Schedule, which the system gives to the program `scheduler` only, writes any set, for any thread. That handle also writes a limit: the thread, and each thread and each program that it creates, then stay on the processors of the limit. So two programs whose limits share no processor never run on the same processor, which takes away the side channels of one processor between them. It does not take away all of them: the kernel does not know which processors are two halves of one core, and the cache that all the cores share stays shared. A thread that changes its queue for a placement keeps what it owes to the other threads. The program `scheduler` checks, on the 4 processors of the test machine, that a thread that keeps one processor is then reported only there, that the kernel refuses each write that widens a set, and that two groups of threads with no common processor stay apart in 200 reports.
