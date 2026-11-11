type: Fixed

**A program that used AVX no longer gets the high halves of its ymm registers from another thread**: before, the kernel saved only 512 bytes with `fxsave` and kept the `XCR0` that the firmware left, so AVX could work with wrong values and no error. Now a register state component is enabled only when the kernel saves it.
