type: Changed

**A kernel entry no longer saves the vector registers of a program**: the kernel saves and restores the x87, SSE and AVX registers of a thread only when a processor leaves it for another thread, and the kernel itself has no instruction that uses them, which the build proves on each kernel that it makes. Before, each entry saved the registers with `fxsave` and each return restored them with `fxrstor`: 227 cycles of the 177 ns of an entry on the host of the tests.
