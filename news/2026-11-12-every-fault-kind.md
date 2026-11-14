title: A fault handler gets every kind of fault, not page faults only
date: 2026-11-12
release: 0.92.0
picture: docs/screenshots/fault_ring.png
kind: Shown
guide: docs/ARCHITECTURE.md

A program can name a fault handler thread for the kinds of fault that it wants: a divide error, an invalid opcode, a protection fault, a breakpoint, a floating-point error, a page fault. A fault of such a kind of another thread becomes a record with its kind and its error code, and the thread waits for an answer. After a breakpoint, the answer Resume lets the thread go on after the int3. After a fault other than a page fault, the kernel refuses Resume: the thread would run the same instruction again and fault again forever. The answer Stop stops the program with the report of the fault. A handler that names no kind gets page faults only. The test program fault_ring has 19 cases now, each in its own child program.
