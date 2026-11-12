title: Programs can use AVX, and a kernel entry is faster
date: 2026-11-12
release: 0.81.0
picture: docs/screenshots/extended_state.png
kind: Measured
guide: docs/ARCHITECTURE.md

The kernel now saves the vector registers of a program with `xsave`, so a program can use AVX. The kernel saves and restores them only when a processor changes thread. The kernel itself holds no vector instruction, and the build disassembles the kernel to prove it. Measured under QEMU with KVM on a Ryzen 7 5800X, one thread that enters the kernel in a loop, two runs: 8 063 360 and 8 359 466 entries in one second. The step before made 5 669 546 and 5 613 013. AVX-512 is not tested: the host has none.
