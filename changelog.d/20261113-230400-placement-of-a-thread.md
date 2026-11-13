type: Added

**The placement of a thread on the processors**: each thread has a set of the processors that can run it, which `Thread_Control` reads and writes while the thread runs (`Read_Placement`, `Write_Placement`; no new kernel operation). A program only narrows the set of its own threads. The holder of the machine handle with `Schedule` and `Inspect` writes any set and a limit, which a new thread and a started program get from their creator: two programs whose limits share no processor never run on the same processor. A thread that never gets a placement is scheduled as before.
