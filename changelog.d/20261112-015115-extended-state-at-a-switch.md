type: Changed

**A kernel entry no longer saves the vector registers of a program**: the kernel saves and restores the x87, SSE and AVX registers of a thread only when a processor leaves it for another thread, and the kernel itself has no instruction that uses them, which the build proves on each kernel that it makes. One kernel entry takes 120 to 124 ns where it took 176 to 178 ns (the machine of the test, two runs each), and one hand-over between two threads takes 125 to 133 ns with the registers saved and restored.
