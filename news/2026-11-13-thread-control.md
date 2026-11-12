title: A program stops a thread and writes its registers
date: 2026-11-13
release: next
picture: none
kind: Shown
guide: docs/ARCHITECTURE.md

A program can now stop one of its threads, read and write its registers, and resume it. A debugger, a garbage collector, a sampling profiler and the program that runs a guest need this. A stop is a count: two stops need two resumes. A thread of another program can be stopped only with a thread handle that the program received. The kernel checks each write: a frame of the kernel, interrupts off, an address that is not canonical, or an extended state that the processor would refuse is refused, and the thread runs on unchanged. A fault handler can now move a thread past the instruction that faulted: the test skips a divide error, and the thread goes on with the result that the handler wrote. The test program `fault_ring` has 33 cases.
